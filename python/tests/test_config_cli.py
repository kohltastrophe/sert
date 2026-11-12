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
        with (
            mock.patch.dict(os.environ, {"HOME": str(self.tmp / "fake_home"), "USERPROFILE": str(self.tmp / "fake_home"), "PATH": "/usr/bin"}),
            mock.patch.object(util.shutil, "which", return_value="/found/rojo") as mock_which,
        ):
            self.assertEqual(util.which("rojo"), "/found/rojo")
            self.assertIn(str(rokit_dir), mock_which.call_args.kwargs["path"])

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


if __name__ == "__main__":
    unittest.main()
