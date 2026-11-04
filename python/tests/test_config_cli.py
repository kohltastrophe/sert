import argparse, contextlib, importlib.util, io, json, os, re, shutil, subprocess, sys, tokenize, tomllib, types, unittest, urllib.error
from pathlib import Path
from unittest import mock
from xml.etree import ElementTree

from helpers import PYTHON, REPO, Case, sha, zip_bytes
from sert import LUAU, LUAU_LSP, VERSION, cli, config, fetch, mutate, run, util
from sert.studio import driver, markers, suites
from sert.util import OK, SertError

FAKE_RUNNER = """import pathlib, sys
pathlib.Path("args.txt").write_text(" ".join(sys.argv[1:]) + "\\n", encoding="utf-8", newline="\\n")
sys.stdout.write('''plain output line
[sert-test] {"file":"Math","ms":2,"name":"adds","status":"pass"}
[sert-test] {"file":"Math","ms":5,"name":"divides","status":"fail","error":"test/Math.spec.luau:3: expected 2, got 3"}
[sert-test] {"file":"Other","ms":0,"name":"later","status":"skip"}
''')
sys.exit(1)
"""


class ConfigAndCliTest(Case):
    def test_config_loading_merging_and_validation(self):
        root = self.project(
            '[lint]\npaths = ["src", "test"]\nsolvers = ["new"]\n[coverage]\nmin = 90\n',
            '[lint]\nsolvers = ["new", "old"]\n[override]\nsert = "../sert"\n',
        )
        cfg = config.load(root)
        self.assertEqual((cfg.get("lint.paths"), cfg.get("lint.solvers"), cfg.get("coverage.min")), (["src", "test"], ["new", "old"], 90))
        self.assertEqual((cfg.overrides, "override" in cfg.shared, cfg.shared["lint"]["solvers"]), ({"sert": (root / "../sert").resolve()}, False, ["new"]))
        self.assertEqual(config.merge({"a": {"b": 1, "c": [1, 2]}, "d": 1}, {"a": {"c": [3]}, "e": 2}), {"a": {"b": 1, "c": [3]}, "d": 1, "e": 2})

        r_env = self.project("", name="env")
        self.setenv("SERT_ROOT", str(r_env))
        self.assertEqual((config.find_root(None), config.find_root(self.tmp)), (r_env.resolve(), self.tmp.resolve()))
        self.setenv("SERT_ROOT", None)

        cdict = config.load(self.project('[cloud]\nshard_limit = 3\n[studio]\nsides = ["client"]\n[[studio.drift]]\ndir = "x"\n', name="cdict"))
        self.assertEqual((cdict.get("cloud"), cdict["studio"]["drift"], cdict.get("studio.sides"), cdict.get("missing")),
                         ({"shard_limit": 3}, [{"dir": "x"}], ["client"], None))

        nested = self.tmp / "outer/inner/deep"
        nested.mkdir(parents=True)
        (self.tmp / "outer/sert.toml").write_text("")
        self.assertEqual(config.root_of(nested), (self.tmp / "outer").resolve())
        repo = self.tmp / "repo"
        (repo / "sub").mkdir(parents=True)
        subprocess.run(["git", "init", "-q", str(repo)], check=True)
        (repo / "sub/sert.toml").write_text("")
        self.assertEqual(config.root_of(repo / "sub"), repo.resolve())

        bad_toml = self.project("[lint\n", name="bad_toml")
        self.assertEqual(self.sert("lint", "--root", bad_toml)[0], 2)
        bom = self.project(name="bom")
        (bom / "sert.toml").write_bytes(b'\xef\xbb\xbf[coverage]\ninclude = ["lib"]\n')
        self.assertEqual(config.load(bom).get("coverage.include"), ["lib"])
        (bom / "sert.toml").write_bytes(b'[coverage]\ninclude = ["l\xe9"]\n')
        code, _, err = self.sert("coverage", "--root", bom)
        self.assertEqual((code, "can't decode byte 0xe9" in err), (2, True))

        self.assertEqual(config.command("fetch"), "sert fetch")
        self.setenv("SERT_ROOT", str(self.tmp))
        self.assertEqual(config.command("fetch"), "python3 tools/sert.py fetch")
        with self.assertRaisesRegex(SertError, r"no sert\.toml in .* \(run `python3 tools/sert\.py init`\)"):
            config.load(self.tmp, require=True)
        self.setenv("SERT_ROOT", None)

        code, _, err = self.sert("coverage", "--root", self.project('[lint]\nsolver = ["new"]\n', name="ukey"))
        self.assertEqual((code, "sert.toml: unknown key [lint].solver (did you mean `solvers`?)" in err), (2, True))
        with self.assertRaisesRegex(SertError, r"unknown table \[lnt\] \(did you mean `lint`\?\)"):
            config.load(self.project("[lnt]\npaths = []\n", name="utbl"))
        with self.assertRaisesRegex(SertError, r"^sert\.local\.toml: unknown key \[coverage\]\.minimum"):
            config.load(self.project("", '[coverage]\nminimum = 3\n', name="local"))

        good = (
            '[tools]\nluau = "1"\nluau_lsp = "1"\n'
            '[deps.flux]\nrepo = "a/b"\ntag = "v1"\nasset = "f.zip"\npaths = ["src"]\n'
            '[studio]\nsides = ["client"]\n[studio.suites.core]\ndefault = false\nmode = "edit"\n'
            '[mutate.specs]\n"src/x.luau" = "x"\n[release.packages.core]\nversions = [{ file = "a", key = "b" }]\n'
            '[[lint.analyze]]\npaths = ["src"]\n[lint.registration]\naggregator = "a"\nspecs = "b"\n'
        )
        self.assertEqual(config.problems_in(tomllib.loads(good)), [])
        problems = config.problems_in(tomllib.loads('[deps.flux]\nrepos = "a"\n[studio]\nentry = "x"\n[release]\nversions = [{ file = "a", patern = "x" }]\n'))
        for want in ("unknown key [deps.flux].repos (did you mean `repo`?)", "unknown key [studio].entry", "unknown key [release.versions #1].patern (did you mean `pattern`?)"):
            self.assertIn(want, problems)

        bad_types = '[test]\ncodegen = "false"\nspecs = 5\n[lint]\nstylua = "false"\nproject = 1\nregistration = "src/init.luau"\nanalyze = ["bad"]\n[coverage]\nmin = true\n[dist]\nbranch = ["x"]\n'
        self.assertEqual(sorted(config.problems_in(tomllib.loads(bad_types))), [
            "[coverage].min must be a number, not true",
            "[dist].branch must be a string, not an array",
            '[lint.analyze #1] must be a table, not the string "bad"',
            "[lint].project must be a string or true or false, not the number 1",
            '[lint].registration must be a table, not the string "src/init.luau"',
            '[lint].stylua must be true or false, not the string "false"',
            '[test].codegen must be true or false, not the string "false"',
            "[test].specs must be an array or a string, not the number 5",
        ])
        self.assertEqual(config.problems_in(tomllib.loads('[test]\ncodegen = false\nspecs = "test"\n[lint]\nproject = false\n[coverage]\nmin = 90.5\n')), [])
        self.assertEqual(config.problems_in(tomllib.loads((REPO / "sert.toml").read_text())), [])
        self.assertEqual(config.problems_in(tomllib.loads('[release.versions]\nfile = "wally.toml"\nkey = "package.version"\n')), [
            "[release].versions must be a list of tables, not a table",
        ])
        self.assertEqual(config.problems_in(tomllib.loads('[[studio]]\nmode = "play"\n')), [
            "[studio] must be a table, not an array",
        ])
        bad_studio_cloud_mutate = (
            '[studio]\ntimeout = true\n[studio.suites.ui]\ndefault = "yes"\ntimeout = "slow"\n'
            '[cloud]\nshard_limit = false\nshards = "a"\n'
            '[mutate]\ntimeout = true\nmin = false\njobs = true\nmax_mutants = "ten"\n'
        )
        self.assertEqual(sorted(config.problems_in(tomllib.loads(bad_studio_cloud_mutate))), [
            "[cloud].shard_limit must be a number, not false",
            '[cloud].shards must be an array, not the string "a"',
            "[mutate].jobs must be an integer, not true",
            '[mutate].max_mutants must be an integer, not the string "ten"',
            "[mutate].min must be a number, not false",
            "[mutate].timeout must be a number, not true",
            '[studio.suites.ui].default must be true or false, not the string "yes"',
            '[studio.suites.ui].timeout must be a number, not the string "slow"',
            "[studio].timeout must be a number, not true",
        ])
        bad_stage = self.project("", name="bad_stage")
        (bad_stage / "bad.project.json").write_text("{not json", encoding="utf-8")
        with self.assertRaisesRegex(SertError, r"\[test\]\.stage: .*bad\.project\.json"):
            run.stage_project(bad_stage, "bad.project.json")
        (bad_stage / "list.project.json").write_text("[1, 2, 3]", encoding="utf-8")
        with self.assertRaisesRegex(SertError, r"\[test\]\.stage: .*list\.project\.json: must be a JSON object"):
            run.stage_project(bad_stage, "list.project.json")

    def test_cli_argv_and_util_edges(self):
        root = self.project()
        with mock.patch("sert.coverage.main", side_effect=RuntimeError("boom")):
            code, _, err = self.sert("coverage", "--root", root)
        self.assertEqual((code, "RuntimeError: boom" in err and "internal error in sert" in err), (2, True))

        parser = cli.build(["frobnicate"])
        choices = next(a.choices for a in parser._actions if a.dest == "command")
        self.assertTrue("pack" not in choices and "dist" in choices and "nearest parent with sert.toml" in cli.ROOT_HELP)

        code, out, _ = self.sert()
        self.assertEqual(code, 2)
        for name, (_, help_text) in cli.COMMANDS.items():
            self.assertEqual(f"    {name} " in out, help_text is not None)

        with self.assertRaises(SystemExit) as raised:
            self.sert("--version")
        self.assertEqual(raised.exception.code, 0)
        self.assertRegex(VERSION, r"^\d+\.\d+\.\d+")

        cli.COMMANDS["ghost"] = ("sert.ghost_module", "missing")
        self.addCleanup(cli.COMMANDS.pop, "ghost")
        code, _, err = self.sert("ghost")
        self.assertEqual((code, "module sert.ghost_module is missing" in err), (2, True))

        croot = self.project('[coverage]\ninclude = ["src"]\n', name="croot")
        (croot / "coverage.out").write_text("SF:src/a.luau\nDA:1,1\nDA:2,0\nend_of_record\n")
        for argv in (("--root", croot, "coverage"), ("coverage", "--root", croot)):
            code, out, _ = self.sert(*argv)
            self.assertEqual((code, out.strip()), (0, "50.0"))

        with self.assertRaisesRegex(SertError, r"\[scalar\] must be a table"):
            config.Config(root, {"scalar": 123}, {"scalar": 123}, True).table("scalar")
        empty = self.tmp / "empty-dir"
        empty.mkdir()
        with mock.patch.object(config.subprocess, "run", side_effect=OSError("no git")):
            self.assertEqual(config.root_of(empty), empty.resolve())
        with mock.patch.object(cli, "build", side_effect=KeyboardInterrupt):
            self.assertEqual(cli.main(["lint"]), 130)
        with mock.patch.object(cli.importlib, "import_module", side_effect=ModuleNotFoundError("No module named 'other_pkg'", name="other_pkg")):
            with self.assertRaisesRegex(ModuleNotFoundError, r"other_pkg"):
                cli.build(["lint"])
        with mock.patch.object(cli.importlib, "import_module", return_value=types.SimpleNamespace(add_parser=lambda sub: None)):
            with self.assertRaisesRegex(SertError, r"sert\.lint\.add_parser did not register `lint`"):
                cli.build(["lint"])
        with self.assertRaisesRegex(SertError, r"nonexistent_tool_xyz_999 not found"):
            util.need("nonexistent_tool_xyz_999", root)
        rokit_dir = self.tmp / "fake_home" / ".rokit" / "bin"
        rokit_dir.mkdir(parents=True)
        with mock.patch.dict(os.environ, {"HOME": str(self.tmp / "fake_home"), "USERPROFILE": str(self.tmp / "fake_home"), "PATH": "/usr/bin"}), \
                mock.patch.object(util.shutil, "which", return_value="/found/rojo") as mock_which:
            self.assertEqual(util.which("rojo"), "/found/rojo")
            self.assertIn(str(rokit_dir), mock_which.call_args.kwargs["path"])
        with self.assertRaisesRegex(SertError, r"git rev-parse HEAD failed"):
            util.git(empty, "rev-parse", "HEAD")
        self.assertEqual(util.posix(Path("/tmp/outside_file.luau"), root), "/tmp/outside_file.luau")
        raw_cp1252 = io.BytesIO()
        cp1252_stream = io.TextIOWrapper(raw_cp1252, encoding="cp1252", errors="strict", newline="\n")
        util.guarded(cp1252_stream).write("✅ ok\n")
        cp1252_stream.flush()
        self.assertEqual(raw_cp1252.getvalue(), b"? ok\n")

        seen = {}
        def add_parser(subparsers, argv=None):
            seen["argv"] = argv
            p = subparsers.add_parser("ghost")
            p.set_defaults(func=lambda args: 0)
            seen["parser"] = p
        mod = types.SimpleNamespace(add_parser=add_parser, __doc__="`sert ghost`: a module docstring.")
        with mock.patch.object(cli.importlib, "import_module", return_value=mod):
            cli.build(["--root", "x", "ghost", "--flag"])
        self.assertEqual((seen["argv"], seen["parser"].description), (["--root", "x", "ghost", "--flag"], "`sert ghost`: a module docstring."))
        self.assertTrue(any("--root" in a.option_strings for a in seen["parser"]._actions))

        if hasattr(tokenize, "FSTRING_START"):
            for py_path in sorted([*(REPO / "python").rglob("*.py"), *(REPO / "tools").rglob("*.py"), *(REPO / "scripts").rglob("*.py")]):
                fstack = []
                for tok in tokenize.generate_tokens(iter(py_path.read_text(encoding="utf-8").splitlines(keepends=True)).__next__):
                    if tok.type == tokenize.FSTRING_START:
                        fstack.append([tok.string.lstrip("fFrR"), 0])
                    elif tok.type == tokenize.FSTRING_END:
                        fstack.pop()
                    elif fstack and tok.type != tokenize.FSTRING_MIDDLE:
                        if tok.type == tokenize.OP and tok.string == "{":
                            fstack[-1][1] += 1
                        elif tok.type == tokenize.OP and tok.string == "}":
                            fstack[-1][1] -= 1
                        elif fstack[-1][1] > 0:
                            self.assertNotIn("\\", tok.string, f"{py_path}:{tok.start[0]}: backslash in f-string expression")
                            self.assertNotEqual(tok.type, tokenize.COMMENT, f"{py_path}:{tok.start[0]}: comment in f-string expression")

    def test_help_shows_the_module_docstring(self):
        out = io.StringIO()
        with mock.patch("sys.stdout", out), self.assertRaises(SystemExit):
            cli.main(["coverage", "--help"])
        self.assertIn("Duplicate SF: records", out.getvalue())

    def test_expand_globs_annotations_and_summaries(self):
        groot = self.tmp / "g"
        for name in ("src/b.luau", "src/a.luau", "src/sub/c.luau", "test/x.spec.luau"):
            (groot / name).parent.mkdir(parents=True, exist_ok=True)
            (groot / name).write_text("")
        missing = []
        found = util.expand_globs(groot, ["src/**/*.luau", "src/a.luau", "src", "nope/*", "gone.luau"], missing=missing)
        self.assertEqual(([util.posix(p, groot) for p in found], missing), (["src", "src/a.luau", "src/b.luau", "src/sub/c.luau"], ["nope/*", "gone.luau"]))
        self.assertEqual([util.posix(p, groot) for p in util.expand_globs(groot, ["src", "**/*.spec.luau"], files=True)], ["test/x.spec.luau"])

        out = io.StringIO()
        with mock.patch("sys.stdout", out):
            self.assertFalse(util.annotate("error", "x"))
            self.setenv("GITHUB_ACTIONS", "true")
            self.assertTrue(util.annotate("warning", "50% off\nnext", file="a,b:c.luau", line=4) and util.annotate("notice", "plain"))
        self.assertEqual(out.getvalue(), "::warning file=a%2Cb%3Ac.luau,line=4::50%25 off%0Anext\n::notice::plain\n")

        lroot = self.project('[lint]\nproject = false\nregistration = { aggregator = "test/run.luau", specs = "test/*.spec.luau" }\n', name="lroot")
        (lroot / "test").mkdir()
        (lroot / "test/run.luau").write_text("")
        (lroot / "test/A.spec.luau").write_text("")
        (lroot / ".sert/types").mkdir(parents=True)
        (lroot / ".sert/types/globalTypes.d.luau").write_text("")
        code, out, _ = self.sert("lint", "--root", lroot, "--skip", "stub", "--skip", "analyze", "--skip", "stylua", "--skip", "sourcemap")
        self.assertEqual((code, "::error file=test/A.spec.luau,title=sert lint%3A registration::test/A.spec.luau is not required by test/run.luau" in out), (1, True))

        sroot = self.project('[coverage]\ninclude = ["src"]\nexclude = ["src/gen"]\nmin = 40\n', name="sroot")
        (sroot / "coverage.out").write_text("SF:src/a.luau\nDA:1,1\nDA:2,0\nend_of_record\nSF:src/gen/b.luau\nDA:1,0\nend_of_record\n")
        summary = self.tmp / "summary.md"
        self.setenv("GITHUB_STEP_SUMMARY", str(summary))
        self.assertEqual(self.sert("coverage", "--root", sroot)[:2], (0, "50.0\n"))
        text = summary.read_text()
        self.assertTrue("### Coverage: 50.0% (minimum 40%)" in text and "| `src/a.luau` | 50.0% | 1/2 |" in text and "src/gen/b.luau" not in text)
        self.assertTrue(util.step_summary("more") and summary.read_text().endswith("more\n"))


class RunReportTest(Case):
    def runner_project(self, name="run"):
        root = self.project('[test]\nentries = ["a.luau"]\n', name=name)
        (root / "a.luau").write_text("")
        (root / "test").mkdir()
        (root / "test/Math.spec.luau").write_text("-- 1\n-- 2\n-- 3\n")
        self.write_fake_tool(root / ".sert/bin/luau", FAKE_RUNNER)
        return root

    def fake_output(self, root, text, code=0):
        self.write_fake_tool(root / ".sert/bin/luau", f"sys.stdout.write({text + chr(10)!r})\nsys.exit({code})\n")

    def test_junit_json_markers_and_selection_flags(self):
        root = self.runner_project()
        code, out, err = self.sert("run", "--root", root, "--junit", "out/junit.xml", "--json-out", "out/r.json")
        self.assertEqual((code, (root / "args.txt").read_text().strip()), (1, "--codegen a.luau -a --markers"), err)
        self.assertTrue("plain output line" in out and "[sert-test]" not in out)
        tree = ElementTree.parse(root / "out/junit.xml").getroot()
        self.assertEqual((tree.tag, tree.get("tests"), tree.get("failures"), tree.get("skipped")), ("testsuites", "3", "1", "1"))
        suites_map = {s.get("name"): s for s in tree.findall("testsuite")}
        self.assertIn("expected 2, got 3", suites_map["Math"].find("testcase[@name='divides']/failure").get("message"))
        self.assertIsNotNone(suites_map["Other"].find("testcase/skipped"))
        report = json.loads((root / "out/r.json").read_text())
        self.assertEqual((report["counts"], report["entries"][0]["entry"], report["status"]),
                         ({"passed": 1, "failed": 1, "skipped": 1, "todo": 0, "total": 3}, "a.luau", 1))

        _, out_m, _ = self.sert("run", "--root", root, "-a", "--markers")
        self.assertIn("[sert-test]", out_m)

        self.sert("run", "--root", root, "--filter", "a b", "-x", "--list", "--exhaustive", "--seed", "random",
                  "--runs", "3", "--replay=7", "--budget", "1.5", "-a", "--test-timeout=5")
        self.assertEqual((root / "args.txt").read_text().strip(),
                         "--codegen a.luau -a --filter=a b --fail-fast --list --exhaustive --seed=random --runs=3 --replay=7 --budget=1.5 --test-timeout=5 --markers")
        for argv in (["--seed", "soon"], ["--filter", "a", "--filter", "b"]):
            with self.assertRaises(SystemExit) as raised, contextlib.redirect_stderr(io.StringIO()):
                cli.main(["run", "--root", str(root), *argv])
            self.assertEqual(raised.exception.code, 2)
        for argv, message in (
            (["--runs", "0"], "--runs takes a whole number from 1, got 0"),
            (["--replay=-1"], "--replay takes a whole number from 0, got -1"),
            (["--budget", "0"], "--budget takes a number of seconds above 0, got 0"),
            (["--budget", "inf"], "--budget takes a number of seconds above 0, got inf"),
            (["-a", "--silent"], "sert run: --silent hides the markers sert run reads its results from"),
            (["--entry", "a.luau", "test/Math.spec.luau"], "cannot pass both --entry and positional spec files"),
        ):
            code, _, err = self.sert("run", "--root", root, *argv)
            self.assertEqual((code, message in err), (2, True), argv)

    def test_echo_timeout_crash_actions_and_xml_sanitization(self):
        root = self.runner_project()
        self.setenv("GITHUB_ACTIONS", "true")
        code, out, _ = self.sert("run", "--root", root)
        self.assertEqual(code, 1)
        self.assertIn("::error file=test/Math.spec.luau,line=3,title=sert run::divides: test/Math.spec.luau:3: expected 2, got 3", out)
        self.setenv("GITHUB_ACTIONS", None)

        res = run.run_entries(config.load(root), ["a.luau"], echo=False)
        self.assertEqual((res.status, res.counts["failed"], res.tests[0]["entry"]), (1, 1, "a.luau"))

        self.write_fake_tool(
            root / ".sert/bin/luau",
            "sys.stderr.write('a warning\\n1 of 2 tests failed\\nstacktrace:\\n[C] function error\\n')\n"
            "sys.stderr.flush()\n"
            "sys.stdout.write('[sert-seed] run 5\\nthe report\\n"
            "[sert-test] {\"file\":\"Math\",\"ms\":5,\"name\":\"divides\",\"status\":\"fail\",\"error\":\"x\"}\\n"
            "[sert-done] {\"passed\":1,\"failed\":1,\"total\":2}\\n')\n"
            "sys.exit(1)\n",
        )
        code, out, err = self.sert("run", "--root", root, "--json-out", "r.json")
        self.assertEqual((code, "the report" in out, "[sert-" in out, "a warning" in err, "tests failed" in err), (1, True, False, True, False))
        self.write_fake_tool(root / ".sert/bin/luau", "sys.stderr.write('1 of 1 tests failed\\n')\nsys.exit(1)\n")
        self.assertIn("1 of 1 tests failed", self.sert("run", "--root", root)[2])

        self.write_fake_tool(root / ".sert/bin/luau", "import time\ntime.sleep(10)\n")
        code, _, err = self.sert("run", "--root", root, "--timeout", "0.3")
        self.assertEqual((code, "a.luau: timed out after 0.3s" in err), (3, True))

        self.write_fake_tool(root / ".sert/bin/luau", "sys.stderr.write('boom: syntax error\\n')\nsys.exit(3)\n")
        self.assertEqual(self.sert("run", "--root", root, "--junit", "j.xml")[0], 1)
        case = ElementTree.parse(root / "j.xml").getroot().find("testsuite[@name='a.luau']/testcase")
        self.assertEqual((case.get("name"), case.find("failure") is not None), ("a.luau exited 3", True))

        self.write_fake_tool(root / ".sert/bin/luau", "sys.stderr.write('test/Math.spec.luau:2: load error\\n')\nsys.exit(1)\n")
        code, _, err = self.sert("run", "--root", root, "--junit", "j.xml")
        self.assertIn("test/Math.spec.luau:2: load error", ElementTree.parse(root / "j.xml").getroot().find("testsuite[@name='a.luau']/testcase/failure").text)

        self.fake_output(root, '[sert-done] {"passed":0,"failed":0,"skipped":1,"total":1}')
        code, _, err = self.sert("run", "--root", root, "--json-out", "r.json")
        self.assertEqual((code, "no test ran" in err), (1, True))
        for status in ("skip", "todo"):
            self.fake_output(root, f'[sert-test] {{"file":"Math","ms":0,"name":"adds","status":"{status}"}}\n[sert-done] {{"passed":0,"failed":0,"skipped":1,"total":1}}')
            self.assertEqual(self.sert("run", "--root", root)[0], 1)
        self.fake_output(root, "[sert-list] Math|adds\n[sert-list] end 1\n" + '[sert-done] {"passed":0,"failed":0,"skipped":1,"total":1}')
        self.assertEqual(self.sert("run", "--root", root, "-a", "--list")[0], 0)
        self.fake_output(root, "plain script output")
        self.assertEqual(self.sert("run", "--root", root)[0], 0)
        code_spec, _, err_spec = self.sert("run", "--root", root, "--entry", "test/Math.spec.luau")
        self.assertEqual((code_spec, "--entry takes a runner script that calls sert.run()" in err_spec), (1, True))

        sert_self = self.tmp / "sert_self"
        (sert_self / "src").mkdir(parents=True)
        (sert_self / "src/init.luau").write_text("return {}\n")
        (sert_self / "python/sert").mkdir(parents=True)
        (sert_self / ".sert/sert/src").mkdir(parents=True)
        self.assertEqual(run._sert_require_target(sert_self), "../src")

        from xml.dom import minidom
        self.fake_output(root, '[sert-test] {"file":"Ma\\u0001th","ms":1,"name":"a\\u0000b \\ud800","status":"fail","error":"\\u001b[31mexpected\\u001b[0m 2\\u0007, got \\ud83d\\ude00"}', code=1)
        self.assertEqual(self.sert("run", "--root", root, "--junit", "j.xml", "--json-out", "r.json")[0], 1)
        doc = minidom.parse(str(root / "j.xml"))
        self.assertEqual(doc.getElementsByTagName("failure")[0].getAttribute("message"), "expected 2\ufffd, got \U0001F600")
        self.assertEqual(doc.getElementsByTagName("testcase")[0].getAttribute("name"), "a\ufffdb \ufffd")

    @unittest.skipUnless(util.which("luau", REPO), "luau not fetched or on PATH")
    def test_generated_luau_strings_and_bad_specs(self):
        luau_bin = util.which("luau", REPO)
        text = 'x😀é\0"\\\n\t\x7fy'
        source = f"local s = {run.luau_string(text)}\nlocal t = {run._luau_literal({text: [text, 1.5, True, None]})}\nassert(t[s][1] == s)\nprint(table.concat({{s:byte(1, -1)}}, ' '))\n"
        script = self.tmp / "literal.luau"
        script.write_text(source, encoding="utf-8")
        done = subprocess.run([luau_bin, str(script)], capture_output=True, text=True, encoding="utf-8")
        self.assertEqual((done.returncode, done.stdout.split(), source.isascii()), (0, [str(b) for b in text.encode()], True))

        root = self.project('[test]\nspecs = ["test"]\n', name="load")
        shutil.copytree(REPO / "src", root / ".sert/sert/src")
        (root / ".luaurc").write_text(json.dumps({"aliases": {"sert": "./.sert/sert/src"}}))
        (root / "test").mkdir()
        (root / "test/Ok.spec.luau").write_text('require("@sert").test("ok", function() end)\nreturn {}\n')
        for src, message in (
            ('require("@sert").test("x", function() end)\n', "test/Bad.spec.luau must return one value"),
            ('error("boom")\nreturn {}\n', "failed to load test/Bad.spec.luau: "),
            ("local x =\nreturn {}\n", "failed to load test/Bad.spec.luau: "),
        ):
            (root / "test/Bad.spec.luau").write_text(src)
            done = subprocess.run([luau_bin, run.write_spec_runner(root, ["test"])], cwd=root, capture_output=True, text=True, encoding="utf-8")
            self.assertTrue(done.returncode != 0 and "❌ test/Bad.spec.luau · " in done.stdout and message in done.stdout and "✅ ok · " in done.stdout)


class OfflineCacheRetryAndPinsTest(Case):
    def test_offline_cache_and_platform_cache(self):
        server = self.release_server()
        dep = zip_bytes({"src/init.luau": b"return 1\n"})
        self.publish(server, "o/dep", "v1", "dep.zip", dep)
        raw = self.tmp / "raw"
        defs = raw / "JohnnyMorganz/luau-lsp/1.70.0/scripts/globalTypes.d.luau"
        defs.parent.mkdir(parents=True)
        defs.write_text("declare class Instance\nend\n")
        self.setenv("SERT_RAW_URL", raw.as_uri())

        toml = '[deps.dep]\nrepo = "o/dep"\ntag = "v1"\nasset = "dep.zip"\n'
        root = self.project(toml + '[tools]\nluau_lsp = "1.70.0"\n')
        self.assertEqual(self.sert("fetch", "--root", root, "--offline", "--only", "deps")[0], 2)
        self.assertEqual(self.sert("fetch", "--root", root, "--offline", "--only", "types")[0], 2)
        self.assertEqual(self.sert("fetch", "--root", root)[0], 0)
        (server / "o/dep/releases/download/v1/dep.zip").unlink()
        defs.unlink()
        self.assertEqual((self.sert("fetch", "--root", root, "--offline")[0], fetch.offline()), (0, False))

        home = Path.home()
        spec = importlib.util.spec_from_file_location("sert_stub", REPO / "tools/sert.py")
        stub = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(stub)
        self.assertEqual(fetch.default_cache("win32", {}), home / "AppData/Local/sert")
        self.assertEqual(fetch.default_cache("darwin", {"SERT_CACHE": "/c"}), Path("/c"))
        self.setenv("SERT_CACHE", None)
        for platform, environ, want in (("win32", {"LOCALAPPDATA": "C:/L"}, Path("C:/L/sert")), ("darwin", {}, home / "Library/Caches/sert"), ("linux", {}, home / ".cache/sert")):
            with mock.patch.object(stub.sys, "platform", platform), mock.patch.dict(os.environ, environ):
                self.assertEqual((stub.cache_dir(), fetch.default_cache(platform)), (want, want))

    def test_retries_and_pinned_versions(self):
        with mock.patch.object(fetch, "warn") as warned:
            calls, sleeps = [], []
            def attempt():
                calls.append(1)
                if len(calls) < 3:
                    raise urllib.error.HTTPError("http://x", 503, "err", {}, io.BytesIO(b"")) if len(calls) == 1 else urllib.error.URLError("reset")
                return b"ok"
            self.setenv("SERT_RETRY_DELAY", "1")
            self.assertEqual((fetch.retrying("http://x", attempt, sleep=sleeps.append), sleeps), (b"ok", [1.0, 2.0]))
            self.assertIn("HTTP 503; retrying in 1s", warned.call_args_list[0].args[0])

            calls404 = []
            with self.assertRaisesRegex(SertError, "HTTP 404"):
                fetch.retrying("http://x", lambda: (calls404.append(1), (_ for _ in ()).throw(urllib.error.HTTPError("http://x", 404, "err", {}, io.BytesIO(b"")))), sleep=lambda s: None)
            self.assertEqual(len(calls404), 1)
            calls_down = []
            with self.assertRaisesRegex(SertError, "refused"):
                fetch.retrying("http://x", lambda: (calls_down.append(1), (_ for _ in ()).throw(urllib.error.URLError("refused"))), sleep=lambda s: None)
            self.assertEqual(len(calls_down), 1 + fetch.RETRIES)

        sroot = self.project('[sert]\nversion = "0.1.0"\n', name="stub")
        (sroot / "tools").mkdir()
        (sroot / "tools/sert.py").write_bytes((REPO / "tools/sert.py").read_bytes())
        env = {k: v for k, v in os.environ.items() if k not in ("SERT_SOURCE", "PYTHONPATH", "SERT_ROOT")}
        env.update(SERT_GITHUB_URL="http://127.0.0.1:9", SERT_RETRY_DELAY="0", SERT_CACHE=str(self.tmp / "c"))
        res = subprocess.run([sys.executable, str(sroot / "tools/sert.py"), "--version"], capture_output=True, text=True, env=env, cwd=sroot)
        self.assertTrue(res.returncode != 0 and "sert: download failed: http://127.0.0.1:9/" in res.stderr and "Traceback" not in res.stderr)

        own = tomllib.loads((REPO / "sert.toml").read_text())["tools"]
        rokit = tomllib.loads((REPO / "rokit.toml").read_text())["tools"]
        self.assertEqual((own["luau"], own["luau_lsp"], rokit["luau-lsp"].rsplit("@", 1)[1]), (LUAU, LUAU_LSP, LUAU_LSP))
        starter = tomllib.loads(fetch.STARTER_TOML)
        self.assertEqual((starter["tools"], starter["coverage"]["min"], config.problems_in(starter)), ({"luau": LUAU, "luau_lsp": LUAU_LSP}, 90, []))

        cfg = config.load(REPO)
        for source in cfg.get("release.versions"):
            match = re.search(source["pattern"], (REPO / source["file"]).read_text(encoding="utf-8"), re.M)
            self.assertIsNotNone(match, source["file"])
            self.assertEqual(match.group(1), cli.VERSION, source["file"])
            if not source["pattern"].startswith("^#"):
                self.assertFalse(match.group(0).lstrip().startswith("#"), source["file"])
        for path in [REPO / "README.md", REPO / "actions/setup/action.yml", *(REPO / "docs").glob("*.md"), *(REPO / ".github/workflows").glob("*.yml")]:
            name = path.relative_to(REPO).as_posix()
            patterns = [s["pattern"] for s in cfg.get("release.versions") if s["file"] == name]
            for line in path.read_text(encoding="utf-8").splitlines():
                if f"sert@v{cli.VERSION}" in line or f"sert/actions/setup@v{cli.VERSION}" in line:
                    self.assertTrue(any(re.search(p, line) for p in patterns), f"{name}: {line.strip()}")


def _subparsers(parser: argparse.ArgumentParser, path=()):
    yield path, parser
    for action in parser._actions:
        if isinstance(action, argparse._SubParsersAction):
            for name, child in action.choices.items():
                yield from _subparsers(child, (*path, name))


class WiringAndTodoTest(Case):
    def _fixture(self) -> Path:
        root = self.project('[test]\nentries = ["test/run.luau"]\n[mutate]\ninclude = ["src"]\n')
        (root / "src").mkdir()
        (root / "src/A.luau").write_text("local M = {}\nfunction M.f(t)\n\tt.x = 1\nend\nreturn M\n")
        (root / "test").mkdir()
        (root / "test/run.luau").write_text('local A = require("../src/A")\n')
        (root / ".luaurc").write_text("{}\n")
        (root / ".sert/stage/files/src").mkdir(parents=True)
        (root / ".sert/stage/init.luau").write_text("return {}\n")
        for skipped in (".git/objects", ".github", ".sert/bin", ".sert/mutate/tree/stale", "node_modules/x"):
            (root / skipped).mkdir(parents=True)
            (root / skipped / "f").write_text("x")
        return root

    def test_mutate_wiring_subcommands_and_todo_status(self):
        root = self._fixture()
        work = mutate.copy_tree(root)
        self.assertEqual(work, root / ".sert/mutate/tree")
        for kept in ("src/A.luau", "test/run.luau", ".luaurc", "sert.toml", ".sert/stage/init.luau"):
            self.assertTrue((work / kept).is_file(), kept)
        for skipped in (".git", ".github", ".sert/bin", ".sert/mutate", "node_modules"):
            self.assertFalse((work / skipped).exists(), skipped)

        seen = {}
        def fake_run_entries(cfg, entries, **kwargs):
            seen.update(kwargs, entries=entries)
            return run.RunResult(1, [run.EntryRun("test/run.luau", 1, 0.1, output="boom: spec failed")])
        with mock.patch.object(run, "run_entries", fake_run_entries), mock.patch.object(run, "luau_command", return_value="luau"):
            code, _, err = self.sert("mutate", "--root", str(root), "-a", "Only")
        self.assertEqual((code, seen["entries"], seen["coverage"], seen["echo"], seen["program_args"]), (2, ["test/run.luau"], True, False, ["Only"]))
        self.assertTrue("baseline `sert run --coverage` failed" in err and "boom: spec failed" in err)

        original = (root / "src/A.luau").read_text()
        (root / "coverage.out").write_text("SF:src/A.luau\nDA:1,1\nDA:2,1\nDA:3,1\nDA:5,1\nend_of_record\n")
        seen2 = {}
        def fake_sub(cmd, cwd=None, **kw):
            seen2.setdefault("cwds", set()).add(Path(cwd))
            seen2.update(copy=(Path(cwd) / "src/A.luau").read_text(), project=(root / "src/A.luau").read_text())
            return types.SimpleNamespace(returncode=0, stdout="", stderr="")
        def fake_batch(batch, work_root, *rest):
            seen2.setdefault("cwds", set()).add(Path(work_root))
            for m in batch: m.status = "KILLED"
        with mock.patch.object(run, "luau_command", return_value="luau"), \
                mock.patch("sert.mutate._run_process", fake_sub), \
                mock.patch("sert.mutate._evaluate_mutant_batch", fake_batch), \
                mock.patch("sert.mutate.compile_and_stage_file", lambda luau, src, inst, muts, path, wrap: (path.write_text(mutate._direct_source(inst)), muts)[1]):
            code, out, err = self.sert("mutate", "--root", str(root), "--no-coverage-run")
        self.assertEqual((code, seen2["cwds"], "__SERT_MUTANT" in seen2["copy"], seen2["project"], (root / "src/A.luau").read_text(), (root / ".sert/mutate/tree").exists()),
                         (0, {root / ".sert/mutate/tree"}, True, original, original, False))

        summary = self.tmp / "summary.md"
        self.setenv("GITHUB_STEP_SUMMARY", str(summary))
        muts = [mutate.Mutant(id=1, file="src/A.luau", line=3, op="stmt_del", original="a.x = 1", mutated="--", status="KILLED"),
                mutate.Mutant(id=2, file="src/A.luau", line=4, op="stmt_del", original="a.y = b | c", mutated="--", status="SURVIVED")]
        self.assertAlmostEqual(mutate.summarize(muts, out=io.StringIO()), 50.0)
        self.assertIn("| `src/A.luau:4` | stmt_del | `a.y = b \\| c` |", summary.read_text())

        sroot = self.project(name="sroot")
        for rel in ("test/a.spec.luau", "test/deep/b.spec.luau", "test/c.luau"):
            (sroot / rel).parent.mkdir(parents=True, exist_ok=True)
            (sroot / rel).write_text("")
        files = suites.Settings(str(sroot), {"studio": {"specs": ["test/**/*.spec.luau"]}}).spec_files()
        self.assertEqual([os.path.relpath(f, sroot).replace("\\", "/") for f in files], ["test/a.spec.luau", "test/deep/b.spec.luau"])

        for command in cli.COMMANDS:
            cmd_p = next(a for a in cli.build([command])._actions if isinstance(a, argparse._SubParsersAction)).choices[command]
            for path, sub in _subparsers(cmd_p, (command,)):
                self.assertEqual(len([a for a in sub._actions if "--root" in a.option_strings]), 1, " ".join(path))

        out_todo = "\n".join([
            '[sert-test] {"file":"A","name":"one","status":"pass","ms":1}',
            '[sert-test] {"file":"A","name":"later","status":"todo","ms":0}',
            '[sert-test] {"file":"A","name":"off","status":"skip","ms":0}',
            '[sert-done] {"passed":1,"failed":0,"skipped":1,"todo":1,"total":3}',
        ])
        parsed = markers.parse(out_todo)
        self.assertEqual(([t["status"] for t in parsed.tests], parsed.results["todo"], markers.failure(parsed.results)), (["pass", "todo", "skip"], 1, None))
        result = run.RunResult(OK, [run.EntryRun("test/run.luau", 0, 0.1)], [{**t, "entry": "test/run.luau"} for t in parsed.tests])
        self.assertEqual((result.counts["todo"], run.json_report(result)["counts"]["todo"]), (1, 1))
        xml = ElementTree.fromstring(run.junit_xml(result))
        cases = {c.get("name"): c for c in xml.iter("testcase")}
        self.assertEqual((xml.get("skipped"), cases["later"].find("skipped").get("message"), cases["off"].find("skipped").get("message")), ("2", "todo", None))
        self.assertEqual(driver.summarize(parsed, {}), "PASSED 1/3 (0 failed, 1 skipped, 1 todo)")
        verdict = markers.parse('[sert-verdict] {"passed":true,"counts":{"passed":1,"failed":0,"skipped":0,"todo":2,"total":3}}')
        self.assertEqual((verdict.results["todo"], driver.summarize(verdict, {})), (2, "PASSED · 1 passed · 0 failed · 0 skipped · 2 todo"))


if __name__ == "__main__":
    unittest.main()
