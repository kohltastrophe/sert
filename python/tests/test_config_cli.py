"""Unit tests for `sert.config`, `sert.cli` lazy dispatch, `sert.run` flags/failed/watch/runners, and `sert.mutate` overlay wiring."""

from __future__ import annotations

import argparse
import contextlib
import importlib.util
import io
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tokenize
import tomllib
import types
import unittest
from unittest import mock
from xml.etree import ElementTree

from helpers import REPO, Case, copy_sert_src
from sert import LUAU, LUAU_LSP, VERSION, cli, config, fetch, markers, mutate, run, util
from sert.studio import driver, suites
from sert.util import OK, SertError

FAKE_RUNNER = """import pathlib, sys
pathlib.Path("args.txt").write_text(" ".join(sys.argv[1:]) + "\\n", encoding="utf-8", newline="\\n")
sys.stdout.write('''plain output line
[sert-test] {"file":"Math","ms":2,"name":"adds","status":"pass"}
[sert-test] {"file":"Math","ms":5,"name":"divides","status":"fail","error":"test/Math.spec.luau:3: expected 2, got 3","seed":42}
[sert-test] {"file":"Other","ms":0,"name":"later","status":"skip"}
''')
sys.exit(1)
"""


class ConfigAndCliTest(Case):
    def test_config_loading_merging_and_0_1_0_schema_validation(self):
        root = self.project(
            '[lint]\npaths = ["src", "test"]\nsolvers = ["new"]\n[coverage]\nmin = 90\n',
            '[lint]\nsolvers = ["new", "old"]\n[override]\nsert = "../sert"\n',
        )
        cfg = config.load(root)
        self.assertEqual((cfg.get("lint.paths"), cfg.get("lint.solvers"), cfg.get("coverage.min")), (["src", "test"], ["new", "old"], 90))
        self.assertEqual(
            (cfg.overrides, "override" in cfg.shared, cfg.shared["lint"]["solvers"]),
            ({"sert": (root / "../sert").resolve()}, False, ["new"]),
        )
        self.assertEqual(
            config.merge({"a": {"b": 1, "c": [1, 2]}, "d": 1}, {"a": {"c": [3]}, "e": 2}),
            {"a": {"b": 1, "c": [3]}, "d": 1, "e": 2},
        )

        r_env = self.project("", name="env")
        self.setenv("SERT_ROOT", str(r_env))
        self.assertEqual((config.find_root(None), config.find_root(self.tmp)), (r_env.resolve(), self.tmp.resolve()))
        self.setenv("SERT_ROOT", None)

        cdict = config.load(self.project('[cloud]\nshard_limit = 3\n[studio]\nsides = ["client"]\n[[studio.drift]]\ndir = "x"\n', name="cdict"))
        self.assertEqual(
            (cdict.get("cloud"), cdict["studio"]["drift"], cdict.get("studio.sides"), cdict.get("missing")),
            ({"shard_limit": 3}, [{"dir": "x"}], ["client"], None),
        )

        nested = self.tmp / "outer/inner/deep"
        nested.mkdir(parents=True)
        (self.tmp / "outer/sert.toml").write_text("")
        self.assertEqual(config.root_of(nested), (self.tmp / "outer").resolve())
        repo = self.tmp / "repo"
        (repo / "sub").mkdir(parents=True)
        (repo / "other").mkdir(parents=True)
        subprocess.run(["git", "init", "-q", str(repo)], check=True)
        (repo / "sub/sert.toml").write_text("")
        self.assertEqual(config.root_of(repo / "sub"), (repo / "sub").resolve())
        self.assertEqual(config.root_of(repo / "other"), repo.resolve())
        schema_ok = config.load(
            self.project(
                '[coverage]\nfile = "cov.lcov"\n[mutate]\ncache = "strict"\n[studio]\nbridge = "bridge.py"\n',
                name="schema_extra",
            )
        )
        self.assertEqual((schema_ok.get("coverage.file"), schema_ok.get("mutate.cache"), schema_ok.get("studio.bridge")), ("cov.lcov", "strict", "bridge.py"))

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
            config.load(self.project("", "[coverage]\nminimum = 3\n", name="local"))

        # Valid 0.1.0 schema (including kohltastrophe/release `[release]` table)
        good_010 = (
            '[sert]\nversion = "0.1.0"\n'
            '[release]\nprefix = "v"\nversions = [{ file = "sert.toml", key = "sert.version" }]\n'
            '[test]\ncodegen = true\nrunner = "lune"\nglobals = "roblox"\njobs = 4\ntimeout = 10\nrepeat = 2\nslowest = 5\nallow_focused = false\n'
            '[studio]\nsides = ["client"]\ndevice = "Phone"\nclients = 2\nwarm = false\n'
            '[studio.suites.core]\ndefault = false\nmode = "edit"\ndevice = "Tablet"\nclients = 1\n'
            '[cloud]\nspecs = ["test/**/*.spec.luau"]\nmax_workers = 4\n'
            '[mutate.specs]\n"src/x.luau" = "x"\n'
            '[[lint.analyze]]\npaths = ["src"]\n'
        )
        self.assertEqual(config.problems_in(tomllib.loads(good_010)), [])

        # Removed 0.0.x tables/keys (`[tools]`, `[deps]`, `[dist]`, `[lint].registration`) are rejected!
        removed = (
            '[tools]\nluau = "0.724"\n'
            '[deps.flux]\nrepo = "a/b"\n'
            '[dist]\nbranch = "dist"\n'
            '[lint]\nregistration = { aggregator = "a", specs = "b" }\n'
        )
        problems = config.problems_in(tomllib.loads(removed))
        for want in (
            "unknown table [tools]",
            "unknown table [deps]",
            "unknown table [dist]",
            "unknown key [lint].registration",
        ):
            self.assertTrue(any(want in p for p in problems), (want, problems))

        bad_types = (
            '[test]\ncodegen = "false"\nspecs = 5\n'
            '[lint]\nstylua = "false"\nproject = 1\nanalyze = ["bad"]\n'
            '[coverage]\nmin = true\n'
        )
        self.assertEqual(
            sorted(config.problems_in(tomllib.loads(bad_types))),
            [
                "[coverage].min must be a number, not true",
                '[lint.analyze #1] must be a table, not the string "bad"',
                "[lint].project must be a string or true or false, not the number 1",
                '[lint].stylua must be true or false, not the string "false"',
                '[test].codegen must be true or false, not the string "false"',
                "[test].specs must be an array or a string, not the number 5",
            ],
        )

        bad_stage = self.project("", name="bad_stage")
        (bad_stage / "bad.project.json").write_text("{not json", encoding="utf-8")
        with self.assertRaisesRegex(SertError, r"\[test\]\.stage: .*bad\.project\.json"):
            run.stage_project(bad_stage, "bad.project.json")
        (bad_stage / "list.project.json").write_text("[1, 2, 3]", encoding="utf-8")
        with self.assertRaisesRegex(SertError, r"\[test\]\.stage: .*list\.project\.json: must be a JSON object"):
            run.stage_project(bad_stage, "list.project.json")

        rokit = tomllib.loads((REPO / "rokit.toml").read_text(encoding="utf-8"))["tools"]
        self.assertEqual(rokit["luau"].rsplit("@", 1)[1], LUAU)
        self.assertEqual(rokit["luau-lsp"].rsplit("@", 1)[1], LUAU_LSP)

    def test_cli_lazy_imports_argv_and_util_edges(self):
        # Verify lazy subcommand imports: `cli.build(["run"])` and `cli.build(["--help"])` do NOT import studio/cloud/mutate!
        imported: list[str] = []
        real_import = cli.importlib.import_module
        with mock.patch.object(cli.importlib, "import_module", side_effect=lambda name: (imported.append(name), real_import(name))[1]):
            cli.build(["--help"])
            self.assertEqual(imported, [])
            cli.build(["run"])
            self.assertEqual(imported, ["sert.run"])

        root = self.project()
        with mock.patch("sert.coverage.main", side_effect=RuntimeError("boom")):
            code, _, err = self.sert("coverage", "--root", root)
        self.assertEqual((code, "RuntimeError: boom" in err and "internal error in sert" in err), (2, True), err)

        parser = cli.build(["frobnicate"])
        choices = next(a.choices for a in parser._actions if a.dest == "command")
        for removed_cmd in ("release", "pack", "dist"):
            self.assertNotIn(removed_cmd, choices)
        self.assertIn("nearest parent with sert.toml", cli.ROOT_HELP)

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
        with self.assertRaisesRegex(SertError, r"nonexistent_tool_xyz_999 not found.*rokit install"):
            util.need("nonexistent_tool_xyz_999", root)

        rokit_dir = self.tmp / "fake_home" / ".rokit" / "bin"
        rokit_dir.mkdir(parents=True)
        aftman_dir = self.tmp / "fake_home" / ".aftman" / "bin"
        aftman_dir.mkdir(parents=True)
        mise_dir = self.tmp / "fake_home" / ".local" / "share" / "mise" / "shims"
        mise_dir.mkdir(parents=True)
        with (
            mock.patch.dict(os.environ, {"HOME": str(self.tmp / "fake_home"), "USERPROFILE": str(self.tmp / "fake_home"), "PATH": "/usr/bin"}),
            mock.patch.object(util.shutil, "which", return_value="/found/rojo") as mock_which,
        ):
            self.assertEqual(util.which("rojo"), "/found/rojo")
            which_path = mock_which.call_args.kwargs["path"]
            for expected_dir in (rokit_dir, aftman_dir, mise_dir):
                self.assertIn(str(expected_dir), which_path)

        # skill_schema() commands and flags stay in sync with cli.COMMANDS & argparse parsers
        from sert import skill

        schema = skill.skill_schema()
        real_commands = {k for k in cli.COMMANDS if k != "ghost"}
        self.assertEqual(set(schema["commands"].keys()), real_commands)
        cross_cutting = ("--format", "--agent", "--watch", "--shuffle", "--retry", "--junit")
        for cmd in real_commands:
            cmd_parser = next(a for a in cli.build([cmd])._actions if isinstance(a, argparse._SubParsersAction)).choices[cmd]
            real_opts = {opt for action in cmd_parser._actions for opt in action.option_strings}
            doc_flags = schema["commands"][cmd]["flags"]
            doc_tokens: set[str] = set()
            for entry in doc_flags:
                for piece in entry.split("/"):
                    tok = piece.strip().split()[0]
                    if tok.startswith("-"):
                        self.assertIn(tok, real_opts, f"skill_schema {cmd} documents unknown flag {tok!r}")
                        doc_tokens.add(tok)
            for req in cross_cutting:
                if req in real_opts:
                    self.assertIn(req, doc_tokens, f"skill_schema {cmd} is missing cross-cutting flag {req}")

        raw_cp1252 = io.BytesIO()
        cp1252_stream = io.TextIOWrapper(raw_cp1252, encoding="cp1252", errors="strict", newline="\n")
        util.guarded(cp1252_stream).write("✅ ok\n")
        cp1252_stream.flush()
        self.assertEqual(raw_cp1252.getvalue(), b"? ok\n")

        # Verify no os.dup2 FD clobbering anywhere in util.py
        self.assertNotIn("dup2", (REPO / "python/sert/util.py").read_text(encoding="utf-8"))

        if hasattr(tokenize, "FSTRING_START"):
            for py_path in sorted([*(REPO / "python").rglob("*.py"), *(REPO / "tools").rglob("*.py"), *(REPO / "scripts/pack.py",)]):
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
        body = (
            "import pathlib\n"
            'pathlib.Path("args.txt").write_text(" ".join(sys.argv[1:]) + "\\n", encoding="utf-8", newline="\\n")\n'
            f"sys.stdout.write({text + chr(10)!r})\n"
            f"sys.exit({code})\n"
        )
        self.write_fake_tool(root / ".sert/bin/luau", body)

    def test_junit_json_markers_selection_failed_watch_and_lune(self):
        root = self.runner_project()
        code, out, err = self.sert("run", "--root", root, "--junit", "out/junit.xml", "--json-out", "out/r.json")
        self.assertEqual((code, (root / "args.txt").read_text().strip()), (1, "--codegen a.luau -a --markers"), err)
        self.assertTrue("plain output line" in out and "[sert-test]" not in out)

        # Verify `.sert/last-failed.json` was written and `sert run --failed` replays the failed test + seed!
        last_failed = json.loads((root / ".sert/last-failed.json").read_text(encoding="utf-8"))
        self.assertEqual(last_failed["failed"], ["divides"])
        self.assertEqual(last_failed["seeds"], {"divides": 42})

        self.fake_output(root, '[sert-test] {"file":"Math","ms":1,"name":"divides","status":"pass"}\n[sert-done] {"passed":1,"failed":0,"total":1}')
        code_f, _, err_f = self.sert("run", "--root", root, "--failed")
        self.assertEqual(code_f, 0, err_f)
        self.assertEqual((root / "args.txt").read_text().strip(), "--codegen a.luau -a --filter=divides --replay=42 --markers")

        # Now last-failed has 0 failures, so `--failed` reports nothing to re-run
        self.assertEqual(self.sert("run", "--root", root, "--failed")[0], 2)

        # Test new 0.1.0 flags (`--no-codegen`, `-g`/`--grep`, `--exclude`, `--file`, `--repeat`, `--slowest`, `--test-timeout`, `--allow-focused`, `$CI`)
        self.setenv("CI", "true")
        self.sert(
            "run",
            "--root",
            root,
            "--no-codegen",
            "-g",
            "add.*",
            "--exclude",
            "slow",
            "--file",
            "Math",
            "--repeat",
            "2",
            "--slowest",
            "5",
            "--test-timeout",
            "1.5",
            "--allow-focused",
        )
        self.setenv("CI", None)
        forwarded_line = (root / "args.txt").read_text().strip()
        self.assertFalse(forwarded_line.startswith("--codegen"))
        for want_arg in ("--grep=add.*", "--exclude=slow", "--file=Math", "--repeat=2", "--slowest=5", "--test-timeout=1.5", "--allow-focused", "--ci"):
            self.assertIn(want_arg, forwarded_line)

        # Test `lune` runner command formatting (`lune run entry -- args`)
        self.assertEqual(
            run.entry_command("lune", "/bin/lune", "a.luau", ["--markers"], False),
            ["/bin/lune", "run", "a.luau", "--", "--markers"],
        )

        # Test `watch_loop` polling mtime changes without real sleep
        edits = [0]

        def fake_sleep(_interval):
            edits[0] += 1
            if edits[0] == 1:
                p = root / "test/Math.spec.luau"
                st = p.stat()
                p.write_text("-- edited\n", encoding="utf-8")
                os.utime(p, ns=(st.st_atime_ns, st.st_mtime_ns + 1_000_000))

        w_args = cli.build(["run"]).parse_args(["run", "--root", str(root)])
        with mock.patch("sert.run.time.sleep", side_effect=fake_sleep):
            rc_w = run.watch_loop(w_args, root, config.load(root), max_cycles=2, out=io.StringIO(), err=io.StringIO())
        self.assertEqual((rc_w, edits[0]), (0, 1))

        for argv, message in (
            (["--runs", "0"], "--runs takes a whole number from 1, got 0"),
            (["--replay=-1"], "--replay takes a whole number from 0, got -1"),
            (["--budget", "0"], "--budget takes a number of seconds above 0, got 0"),
            (["--repeat", "0"], "--repeat takes a whole number from 1, got 0"),
            (["--slowest", "0"], "--slowest takes a whole number from 1, got 0"),
            (["--test-timeout", "0"], "--test-timeout takes a number of seconds above 0, got 0"),
            (["--grep", "[bad"], "--grep: invalid pattern"),
            (["-a", "--silent"], "sert run: --silent hides the markers sert run reads its results from"),
            (["--entry", "a.luau", "test/Math.spec.luau"], "cannot pass both --entry and positional spec files"),
        ):
            code_v, _, err_v = self.sert("run", "--root", root, *argv)
            self.assertEqual((code_v, message in err_v), (2, True), (argv, err_v))

    def test_echo_timeout_crash_actions_and_xml_sanitization(self):
        root = self.runner_project()
        self.setenv("GITHUB_ACTIONS", "true")
        code, out, _ = self.sert("run", "--root", root)
        self.assertEqual(code, 1)
        self.assertIn("::error file=test/Math.spec.luau,line=3,title=sert run::divides: test/Math.spec.luau:3: expected 2, got 3", out)
        self.setenv("GITHUB_ACTIONS", None)

        res = run.run_entries(config.load(root), ["a.luau"], echo=False)
        self.assertEqual((res.status, res.counts["failed"], res.tests[0]["entry"]), (1, 1, "a.luau"))

        self.write_fake_tool(root / ".sert/bin/luau", "import time\ntime.sleep(5)\n")
        code, _, err = self.sert("run", "--root", root, "--timeout", "0.05")
        self.assertEqual((code, "a.luau: timed out after 0.05s" in err), (3, True))

        self.write_fake_tool(root / ".sert/bin/luau", "sys.stderr.write('boom: syntax error\\n')\nsys.exit(3)\n")
        self.assertEqual(self.sert("run", "--root", root, "--junit", "j.xml")[0], 1)
        case = ElementTree.parse(root / "j.xml").getroot().find("testsuite[@name='a.luau']/testcase")
        self.assertEqual((case.get("name"), case.find("failure") is not None), ("a.luau exited 3", True))

        from xml.dom import minidom

        self.fake_output(
            root,
            '[sert-test] {"file":"Ma\\u0001th","ms":1,"name":"a\\u0000b \\ud800","status":"fail","error":"\\u001b[31mexpected\\u001b[0m 2\\u0007, got \\ud83d\\ude00"}',
            code=1,
        )
        self.assertEqual(self.sert("run", "--root", root, "--junit", "j.xml", "--json-out", "r.json")[0], 1)
        doc = minidom.parse(str(root / "j.xml"))
        self.assertEqual(doc.getElementsByTagName("failure")[0].getAttribute("message"), "expected 2\ufffd, got \U0001F600")
        self.assertEqual(doc.getElementsByTagName("testcase")[0].getAttribute("name"), "a\ufffdb \ufffd")

        # Verify `--shuffle`, `--seed`, `--retry`, and negative `--retry` validation.
        sroot = self.runner_project(name="shuffle_retry")
        code_s, _, err_s = self.sert("run", "--root", sroot, "--shuffle", "--seed", "42", "--retry", "2")
        self.assertEqual(code_s, 1, err_s)
        forwarded_sr = (sroot / "args.txt").read_text(encoding="utf-8").strip()
        for arg in ("--shuffle", "--seed=42", "--retry=2"):
            self.assertIn(arg, forwarded_sr)
        code_bad_r, _, err_bad_r = self.sert("run", "--root", sroot, "--retry=-1")
        self.assertEqual(code_bad_r, 2)
        self.assertIn("--retry", err_bad_r)

        # Smart TIA watch + manifest cache in stage_project
        wroot = self.project('[test]\nspecs = ["test/*.spec.luau"]\n', name="smart_watch")
        (wroot / "src").mkdir()
        (wroot / "test").mkdir()
        (wroot / "src/ModA.luau").write_text("return 1\n", encoding="utf-8")
        (wroot / "src/Unrelated.luau").write_text("return 2\n", encoding="utf-8")
        (wroot / "test/Alpha.spec.luau").write_text('local A = require("../src/ModA")\nreturn {}\n', encoding="utf-8")
        (wroot / "test/Beta.spec.luau").write_text("return {}\n", encoding="utf-8")

        seen_specs: list[list[str]] = []

        def spy_cmd_run(run_a, root=None, cfg=None, out=None, err=None):
            seen_specs.append(list(getattr(run_a, "specs", None) or []))
            return 0

        sleep_tick = [0]

        def watch_sleep(_iv):
            sleep_tick[0] += 1
            if sleep_tick[0] == 1:
                p = wroot / "src/ModA.luau"
                st = p.stat()
                p.write_text("return 11\n", encoding="utf-8")
                os.utime(p, ns=(st.st_atime_ns, st.st_mtime_ns + 2_000_000))
            elif sleep_tick[0] == 2:
                p = wroot / "src/Unrelated.luau"
                st = p.stat()
                p.write_text("return 22\n", encoding="utf-8")
                os.utime(p, ns=(st.st_atime_ns, st.st_mtime_ns + 2_000_000))

        sw_err = io.StringIO()
        sw_args = cli.build(["run"]).parse_args(["run", "--root", str(wroot)])
        with (
            mock.patch.object(run, "cmd_run", side_effect=spy_cmd_run),
            mock.patch("sert.run.time.sleep", side_effect=watch_sleep),
        ):
            rc_sw = run.watch_loop(sw_args, wroot, config.load(wroot), max_cycles=3, out=io.StringIO(), err=sw_err)
        self.assertEqual(rc_sw, 0)
        self.assertEqual(seen_specs, [[], ["test/Alpha.spec.luau"]])
        self.assertIn("changed: src/ModA.luau", sw_err.getvalue())
        self.assertIn("0 affected spec(s); waiting", sw_err.getvalue())

        # stage_project writes `.sert/stage/manifest.json` and skips re-reading unchanged dest files
        stage_root = self.project('[test]\nstage = "default.project.json"\n', name="stage_manifest")
        (stage_root / "src").mkdir()
        (stage_root / "src/Lib.luau").write_text("return 1\n", encoding="utf-8")
        (stage_root / "default.project.json").write_text(
            json.dumps({"name": "StageManifest", "tree": {"$className": "DataModel", "ReplicatedStorage": {"Src": {"$path": "src"}}}}),
            encoding="utf-8",
        )
        run.stage_project(stage_root, "default.project.json")
        self.assertTrue((stage_root / ".sert/stage/manifest.json").is_file())
        staged_lib = stage_root / ".sert/stage/lexical/src/Lib.luau"
        orig_read_text = Path.read_text
        staged_reads: list[Path] = []

        def tracking_read(self_path: Path, *args, **kwargs):
            if self_path == staged_lib:
                staged_reads.append(self_path)
            return orig_read_text(self_path, *args, **kwargs)

        with mock.patch.object(Path, "read_text", tracking_read):
            run.stage_project(stage_root, "default.project.json")
        self.assertEqual(staged_reads, [])

    @unittest.skipUnless(util.which("luau", REPO), "luau not fetched or on PATH")
    def test_generated_luau_strings_zero_return_and_bad_specs(self):
        luau_bin = util.which("luau", REPO)
        assert luau_bin is not None
        text = 'x😀é\0"\\\n\t\x7fy'
        source = (
            f"local s = {run.luau_string(text)}\n"
            f"local t = {run._luau_literal({text: [text, 1.5, True, None]})}\n"
            "assert(t[s][1] == s)\n"
            "print(table.concat({s:byte(1, -1)}, ' '))\n"
        )
        script = self.tmp / "literal.luau"
        script.write_text(source, encoding="utf-8")
        done = subprocess.run([luau_bin, str(script)], cwd=self.tmp, capture_output=True, text=True, encoding="utf-8")
        self.assertEqual((done.returncode, done.stdout.split(), source.isascii()), (0, [str(b) for b in text.encode()], True))

        root = self.project('[test]\nspecs = ["test"]\n', name="load")
        copy_sert_src(root / ".sert/sert/src")
        (root / ".luaurc").write_text(json.dumps({"aliases": {"sert": "./.sert/sert/src"}}))
        (root / "test").mkdir()
        # 0-return spec SUCCEEDS via `.sert/stage/specs/` line-preserving staging!
        (root / "test/Ok.spec.luau").write_text('require("@sert").test("ok", function() end)\n')
        done_ok = subprocess.run([luau_bin, run.write_spec_runner(root, ["test"])], cwd=root, capture_output=True, text=True, encoding="utf-8")
        self.assertEqual(done_ok.returncode, 0, done_ok.stdout + done_ok.stderr)
        self.assertIn("✅ ok · ", done_ok.stdout)

        # Specs with runtime load errors or syntax errors fail cleanly without blocking Ok.spec.luau
        for src in ('error("boom")\nreturn {}\n', "local x =\nreturn {}\n"):
            (root / "test/Bad.spec.luau").write_text(src)
            done_bad = subprocess.run([luau_bin, run.write_spec_runner(root, ["test"])], cwd=root, capture_output=True, text=True, encoding="utf-8")
            self.assertTrue(
                done_bad.returncode != 0
                and "❌ test/Bad.spec.luau · " in done_bad.stdout
                and "failed to load test/Bad.spec.luau: " in done_bad.stdout
                and "✅ ok · " in done_bad.stdout,
                done_bad.stdout + done_bad.stderr,
            )


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
        (root / ".sert/stage/lexical/src").mkdir(parents=True)
        (root / ".sert/stage/init.luau").write_text("return {}\n")
        for skipped in (".git/objects", ".github", ".sert/bin", ".sert/mutate/overlay/stale", "node_modules/x"):
            (root / skipped).mkdir(parents=True)
            (root / skipped / "f").write_text("x")
        return root

    def test_mutate_overlay_wiring_subcommands_and_todo_status(self):
        root = self._fixture()
        work = mutate.prepare_overlay(root)
        self.assertEqual(work, root / ".sert/mutate/overlay")
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
            for m in batch:
                m.status = "KILLED"

        with (
            mock.patch.object(run, "luau_command", return_value="luau"),
            mock.patch("sert.mutate._run_process", fake_sub),
            mock.patch("sert.mutate._evaluate_mutant_batch", fake_batch),
            mock.patch(
                "sert.mutate.compile_and_stage_file",
                lambda luau, src, inst, muts, path, wrap: (path.unlink(missing_ok=True), path.write_text(mutate._direct_source(inst)), muts)[2],
            ),
        ):
            code, _, err = self.sert("mutate", "--root", str(root), "--no-coverage-run")
        self.assertEqual(
            (
                code,
                seen2["cwds"],
                "__SERT_MUTANT" in seen2["copy"],
                seen2["project"],
                (root / "src/A.luau").read_text(),
                (root / ".sert/mutate/overlay").exists(),
            ),
            (0, {root / ".sert/mutate/overlay"}, True, original, original, False),
            err,
        )

        summary = self.tmp / "summary.md"
        self.setenv("GITHUB_STEP_SUMMARY", str(summary))
        muts = [
            mutate.Mutant(id=1, file="src/A.luau", line=3, op="stmt_del", original="a.x = 1", mutated="--", status="KILLED"),
            mutate.Mutant(id=2, file="src/A.luau", line=4, op="stmt_del", original="a.y = b | c", mutated="--", status="SURVIVED"),
        ]
        self.assertAlmostEqual(mutate.summarize(muts, out=io.StringIO()), 50.0)
        self.assertIn("| `src/A.luau:4` | stmt_del | `a.y = b \\| c` |", summary.read_text())

        for command in cli.COMMANDS:
            cmd_p = next(a for a in cli.build([command])._actions if isinstance(a, argparse._SubParsersAction)).choices[command]
            for path, sub in _subparsers(cmd_p, (command,)):
                self.assertEqual(len([a for a in sub._actions if "--root" in a.option_strings]), 1, " ".join(path))

        out_todo = "\n".join(
            [
                '[sert-test] {"file":"A","name":"one","status":"pass","ms":1}',
                '[sert-test] {"file":"A","name":"later","status":"todo","ms":0}',
                '[sert-test] {"file":"A","name":"off","status":"skip","ms":0}',
                '[sert-done] {"passed":1,"failed":0,"skipped":1,"todo":1,"total":3}',
            ]
        )
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

    def test_strict_json_luaurc_multi_grep_luau_pattern_and_format_human_override(self):
        import argparse
        from sert import agent, graph

        self.assertEqual(agent.output_format(argparse.Namespace(format="human", agent=True), env={"SERT_AGENT": "1"}), "human")
        bad_rc = self.project("", name="bad_luaurc")
        (bad_rc / ".luaurc").write_text("{bad json\n", encoding="utf-8")
        with self.assertRaises(config.SertError):
            graph.load_luaurc_aliases(bad_rc)
        with self.assertRaises(config.SertError):
            run._sync_sert_luaurc(bad_rc)

        # Multi-`--grep` with Luau patterns (`%d+`) and `--exclude` works end-to-end.
        if shutil.which("luau") or (Path.home() / ".rokit/bin/luau").is_file():
            mroot = self.project('[test]\nspecs = ["test/*.spec.luau"]\n', name="multi_grep")
            copy_sert_src(mroot / ".sert/sert/src")
            (mroot / ".luaurc").write_text('{"aliases": {"sert": "./.sert/sert/src"}}\n', encoding="utf-8")
            (mroot / "test").mkdir()
            (mroot / "test/Grep.spec.luau").write_text(
                'local sert = require("@sert")\n'
                'sert.test("alpha_1", function() sert.ok(true) end)\n'
                'sert.test("beta_2", function() sert.ok(true) end)\n'
                'sert.test("beta_9", function() sert.ok(true) end)\n'
                'sert.test("gamma_3", function() sert.ok(true) end)\n',
                encoding="utf-8",
            )
            code, out, err = self.sert("run", "--root", mroot, "--grep", "alpha_%d+$", "--grep", "beta_%d+$", "--exclude", "beta_9$")
            self.assertEqual(code, 0, out + err)
            self.assertIn("2 passed · 0 failed", out)

        # `_format_failure_snippets` stops before subsequent passing tests / summary lines and skips core runner files
        snip_root = self.project("", name="snip_bounds")
        (snip_root / "test/unit").mkdir(parents=True)
        (snip_root / ".sert/sert/src/core").mkdir(parents=True)
        (snip_root / "test/unit/RealFail.spec.luau").write_text("-- line1\nsert.eq(1, 2)\n", encoding="utf-8")
        (snip_root / "test/unit/Util.spec.luau").write_text("-- line1\nerror('logged')\n", encoding="utf-8")
        (snip_root / ".sert/sert/src/core/runner.luau").write_text("-- runner\nerror('bad')\n", encoding="utf-8")
        raw_out = "\n".join(
            [
                "❌ real fail · 5 ms",
                "   ⚠️ test/unit/RealFail.spec.luau:2: values differ",
                "✅ Util · String > handled error · 1 ms",
                "String failed: test/unit/Util.spec.luau:2: logged",
                "2 passed · 1 failed · 0 skipped · 6 ms",
                ".sert/sert/src/core/runner.luau:2: 1 of 3 tests failed",
            ]
        )
        snips = run._format_failure_snippets(raw_out, snip_root)
        self.assertIn("test/unit/RealFail.spec.luau:2:", snips)
        self.assertNotIn("Util.spec.luau", snips)
        self.assertNotIn("runner.luau", snips)

        # `[coverage].file` works end-to-end across `sert run --coverage` and `sert coverage`
        if shutil.which("luau") or (Path.home() / ".rokit/bin/luau").is_file():
            cf_root = self.project(
                '[test]\nspecs = ["test/*.spec.luau"]\n[coverage]\ninclude = ["src"]\nfile = "build/lcov.info"\nmin = 100\n',
                name="custom_cov_file",
            )
            copy_sert_src(cf_root / ".sert/sert/src")
            (cf_root / ".luaurc").write_text('{"aliases": {"sert": "./.sert/sert/src"}}\n', encoding="utf-8")
            (cf_root / "src").mkdir()
            (cf_root / "test").mkdir()
            (cf_root / "src/A.luau").write_text("local M = {}\nfunction M.ok()\n\treturn 42\nend\nreturn M\n", encoding="utf-8")
            (cf_root / "test/A.spec.luau").write_text(
                'local sert = require("@sert")\nlocal M = require("../src/A")\nsert.test("ok", function() sert.eq(M.ok(), 42) end)\n',
                encoding="utf-8",
            )
            rc_cf, out_cf, err_cf = self.sert("run", "--root", cf_root, "--coverage")
            self.assertEqual(rc_cf, 0, out_cf + err_cf)
            self.assertTrue((cf_root / "build/lcov.info").is_file())
            self.assertFalse((cf_root / "coverage.out").exists())
            rc_cov, out_cov, err_cov = self.sert("coverage", "--root", cf_root)
            self.assertEqual((rc_cov, out_cov.strip()), (0, "100.0"), out_cov + err_cov)

        # `watch_loop` survives transient malformed `sert.toml` and recovers cleanly next cycle
        wl_root = self.project('[test]\nspecs = ["test/*.spec.luau"]\n', name="watch_transient")
        (wl_root / "test").mkdir()
        (wl_root / "test/A.spec.luau").write_text("return nil\n", encoding="utf-8")
        wl_cfg = config.load(wl_root)
        saved_wl_toml = (wl_root / "sert.toml").read_text(encoding="utf-8")
        wl_cycles = [0]

        def fake_wl_sleep(_iv):
            wl_cycles[0] += 1
            toml_p = wl_root / "sert.toml"
            st = toml_p.stat()
            if wl_cycles[0] == 1:
                toml_p.write_text("[broken\n", encoding="utf-8")
                os.utime(toml_p, ns=(st.st_atime_ns, st.st_mtime_ns + 2_000_000))
            elif wl_cycles[0] == 2:
                toml_p.write_text(saved_wl_toml, encoding="utf-8")
                os.utime(toml_p, ns=(st.st_atime_ns, st.st_mtime_ns + 4_000_000))

        wl_args = cli.build(["run"]).parse_args(["run", "--root", str(wl_root), "--watch"])
        wl_out, wl_err = io.StringIO(), io.StringIO()
        with (
            mock.patch.object(run, "cmd_run", return_value=0) as mock_wrun,
            mock.patch("sert.run.time.sleep", side_effect=fake_wl_sleep),
        ):
            rc_wl = run.watch_loop(wl_args, wl_root, wl_cfg, max_cycles=3, out=wl_out, err=wl_err)
        self.assertEqual((rc_wl, mock_wrun.call_count), (0, 2))
        self.assertIn("error:", wl_err.getvalue())


if __name__ == "__main__":
    unittest.main()
