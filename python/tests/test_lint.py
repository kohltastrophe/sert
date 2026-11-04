"""types, audit, lint (registration, stub, fake luau-lsp), coverage, and run."""

import json, os, shutil, subprocess, sys, time, unittest
from pathlib import Path

from helpers import PYTHON, REPO, Case
from sert import VERSION, config, coverage, fetch, lint, mutate, run as run_mod
from sert.util import SertError, strip_trailing_commas


def registration_problems(root, entry):
    return [message for _, message in lint.registration_findings(root, entry)]


FAKE_LSP = r'''#!{python}
import json, os, sys
args = sys.argv[2:]
settings = next((a.split("=", 1)[1] for a in args if a.startswith("--settings=")), None)
new = json.load(open(settings))["luau-lsp.fflags.enableNewSolver"] if settings else True
open({log!r}, "a").write(" ".join(sys.argv[1:]) + "\n")
status = 0
for name in [a for a in args if not a.startswith("--")]:
    files = [name] if os.path.isfile(name) else [os.path.join(d, f) for d, _, fs in os.walk(name) for f in fs]
    for path in files:
        for number, line in enumerate(open(path).read().splitlines(), 1):
            if "OLDBAD" in line and new: continue
            if "BAD" in line:
                print(f"{{path}}({{number}},1): TypeError: bad")
                status = 1
sys.exit(status)
'''

LSP_SAMPLE = """\
[WARN] No definitions file provided by client
p.luau(1,1): TypeError: Expected this to be 'number', but got 'string'
p.luau(4,11): TypeError: Unknown global 'z'; consider assigning to it first
p.luau(2,7): LocalUnused: Variable 'unused' is never used; prefix with '_' to silence
p.luau(3,21): DuplicateLocal: Function parameter 'a' already defined on column 18
p.luau(7,13): SameLineStatement: A new statement is on the same line; add semi-colon on previous statement to silence
p.luau(7,19): LocalShadow: Variable 'q' shadows previous declaration at line 7
syn.luau(2,1): SyntaxError: Expected identifier when parsing expression, got <eof>
syn.luau(2,1): MultiLineStatement: Statement spans multiple lines; use indentation to silence
"""

HAS_LSP = shutil.which("luau-lsp") is not None


class ToolCase(Case):
    def fake_tools(self):
        bin_dir = self.tmp / "bin"
        bin_dir.mkdir(exist_ok=True)
        self.lsp_log = self.tmp / "lsp.log"
        self.write_fake_tool(bin_dir / "luau-lsp", FAKE_LSP.format(python=sys.executable, log=str(self.lsp_log)))
        for name, code in (("stylua", 0), ("selene", 0)):
            self.write_fake_tool(bin_dir / name, f"sys.exit({code})\n")
        self.setenv("PATH", f"{bin_dir}{os.pathsep}{os.environ['PATH']}")

    def defs(self, root: Path):
        path = root / ".sert/types/globalTypes.d.luau"
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text("declare class Instance\n\tName: string\n\tfunction Remove(self): ()\nend\n"
                        "declare class GuiObject extends Instance\n\tPosition: UDim2\nend\n")

    def write(self, root: Path, files: dict[str, str]):
        for name, text in files.items():
            path = root / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(text)


class TypesAndLintTest(ToolCase):
    def test_expected_lines_and_probes_under_both_solvers(self):
        self.assertEqual(lint.expected_lines("a\nb -- expect-error\nc\n-- expect-error: why\n"), {2, 4})
        self.assertIsNone(lint.compare("f", {2}, {2}, "new"))
        self.assertIn("lines [2], but failed on [3]", lint.compare("f", {2}, {3}, "new"))
        self.assertIn("has no `-- expect-error` lines", lint.compare("f", set(), set(), "new"))

        self.fake_tools()
        root = self.project('[types]\npass = "test/types"\nfail = "test/types/fail"\nsolvers = ["new", "old"]\n')
        self.defs(root)
        self.write(root, {
            "test/types/Good.luau": "local x = 1\n",
            "test/types/fail/Probe.luau": "local a = 1\nlocal b = BAD -- expect-error\n",
            "test/types/fail/Probe2.luau": "local c = BAD -- expect-error\n",
        })
        code, out, err = self.sert("lint", "--only", "types", "--root", root)
        self.assertEqual(code, 0, out + err)
        self.assertIn("1 clean and 2 failing probes hold under new and old", out)
        self.assertEqual(len(self.lsp_log.read_text().splitlines()), 4)

        for files, want, not_want in (
            ({"test/types/fail/Probe.luau": "local a = 1\nlocal b = 2 -- expect-error\n"}, "should fail to type-check on lines [2], but failed on []", None),
            ({"test/types/fail/Probe.luau": "local a = OLDBAD\nlocal b = BAD -- expect-error\n"}, "under the old solver", "under the new solver"),
            ({"test/types/fail/Probe.luau": "local b = BAD -- expect-error\n", "test/types/Good.luau": "local x = BAD\n"}, "test/types/Good.luau should analyze clean", None),
            ({"test/types/Good.luau": "local x = 1\n", "test/types/fail/Probe.luau": "local a = 1\n"}, "is in [types].fail but has no `-- expect-error` lines", None),
        ):
            self.write(root, files)
            code, _, err = self.sert("lint", "--only", "types", "--root", root)
            self.assertEqual(code, 1)
            self.assertIn(want, err)
            if not_want:
                self.assertNotIn(not_want, err)

        self.write_fake_tool(self.tmp / "bin/luau-lsp", "print('src/Other.luau(4,1): TypeError: broken')\nsys.exit(1)\n")
        self.write(root, {"test/types/fail/Probe.luau": "local b = BAD -- expect-error\n"})
        code, _, err = self.sert("lint", "--only", "types", "--root", root)
        self.assertEqual((code, "src/Other.luau" in err), (1, True))

    def test_registration_stub_dry_run_and_analyze_groups(self):
        self.fake_tools()
        root = self.project(
            '[lint]\npaths = ["src", "test"]\nproject = false\n'
            'registration = [{ aggregator = "test/unit/init.luau", specs = "test/unit/**/*.spec.luau" }]\n'
            f'extra = [[{json.dumps(sys.executable)}, "-c", "raise SystemExit(0)"]]\n'
        )
        self.defs(root)
        self.write(root, {
            "src/init.luau": "return {}\n",
            "test/unit/init.luau": 'require("./unit/A.spec")\nrequire("@self/sub/B.spec")\n',
            "test/unit/A.spec.luau": "",
            "test/unit/sub/B.spec.luau": "",
        })
        (root / "tools").mkdir()
        shutil.copy(REPO / "tools/sert.py", root / "tools/sert.py")
        code, out, err = self.sert("lint", "--root", root)
        self.assertEqual((code, "lint: ok" in out), (0, True), out + err)

        self.write(root, {
            "test/unit/init.luau": '-- require("./unit/A.spec")\nrequire("@self/sub/B.spec")\n',
            "test/unit/C.spec.luau": "",
            "src/x.luau": "local y = BAD\ntask.wait(1)\n",
        })
        (root / "tools/sert.py").write_text("# edited\n")
        code, _, err = self.sert("lint", "--root", root)
        self.assertEqual(code, 1)
        for want in ("test/unit/A.spec.luau is not required", "test/unit/C.spec.luau is not required", "tools/sert.py differs", "failed: analyze, registration, stub"):
            self.assertIn(want, err)

        dry = self.project('[lint]\npaths = ["src"]\nsolvers = ["new", "old"]\nselene = true\n[types]\nfail = "t/fail"\n', name="dry")
        code, out, _ = self.sert("lint", "--root", dry, "--dry-run", "--skip", "types")
        self.assertEqual((code, out.count("luau-lsp analyze")), (0, 2))
        for want in ("--ignore=**/t/fail/**", "stylua --check src", "selene src"):
            self.assertIn(want, out)

        self.fake_tools()
        self.lsp_log.write_text("")
        grp = self.project(
            '[lint]\npaths = ["core", "game"]\nproject = false\nsolvers = ["old", "new"]\nstub = false\n'
            '[[lint.analyze]]\nname = "portable"\nplatform = "standard"\ndefs = false\npaths = ["core", "gen/*/portable"]\nignore = ["core/skip/**"]\n'
            '[[lint.analyze]]\nname = "roblox"\npaths = ["game"]\ndefinitions = ["extra.d.luau"]\nsolvers = ["new"]\n',
            name="grp",
        )
        self.defs(grp)
        self.write(grp, {"core/a.luau": "return 1\n", "gen/b/portable/x.luau": "return 2\n", "gen/a/portable/y.luau": "return 3\n",
                         "game/c.luau": "return 4\n", "extra.d.luau": "declare SHARD: any\n"})
        code, out, err = self.sert("lint", "--root", grp)
        self.assertEqual(code, 0, out + err)
        portable_old, portable_new, roblox = self.lsp_log.read_text().splitlines()
        self.assertTrue("old-solver.json" in portable_old and "new-solver.json" in portable_new and "--defs" not in portable_old)
        self.assertTrue("--platform=standard" in portable_old and portable_old.endswith("core gen/a/portable gen/b/portable"))
        self.assertIn("--ignore=.sert/** --ignore=core/skip/**", portable_old)
        self.assertTrue("--defs=extra.d.luau" in roblox and "globalTypes.d.luau" in roblox and "--platform" not in roblox and roblox.endswith(" game"))
        self.write(grp, {"game/c.luau": "local x = OLDBAD\n"})
        self.assertEqual(self.sert("lint", "--root", grp)[0], 0)
        self.write(grp, {"gen/a/portable/y.luau": "local x = OLDBAD\n"})
        code, _, err = self.sert("lint", "--root", grp)
        self.assertEqual((code, "[[lint.analyze]] portable: luau-lsp analyze (old solver) reported problems" in err), (1, True))

        bad1 = self.project('[lint]\nproject = false\n[[lint.analyze]]\npaths = ["nothing/*"]\n', name="bad1")
        self.defs(bad1)
        code, _, err = self.sert("lint", "--root", bad1, "--skip", "stub")
        self.assertEqual((code, "[[lint.analyze]] 1: nothing/* matches nothing" in err), (1, True))
        bad2 = self.project('[lint]\n[[lint.analyze]]\npaths = ["x"]\nplatfrom = "standard"\n', name="typo")
        code, _, err = self.sert("lint", "--root", bad2, "--dry-run")
        self.assertEqual((code, "unknown key [lint.analyze #1].platfrom (did you mean `platform`?)" in err), (2, True))


class CoverageVersionRunTest(ToolCase):
    def test_coverage_and_check_version(self):
        root = self.project('[coverage]\ninclude = ["src"]\nmin = 60\n')
        abs_a = (root / "src/a.luau").resolve().as_posix()
        self.write(root, {"coverage.out": f"SF:./src/a.luau\nDA:1,1\nDA:2,0\nend_of_record\nSF:{abs_a}\nDA:2,3\nDA:3,0\nend_of_record\nSF:test/sert.luau\nDA:1,0\nend_of_record\n"})
        code, out, err = self.sert("coverage", "--root", root)
        self.assertEqual((code, out, "src/a.luau" in err, "sert.luau" in err), (0, "66.7\n", True, False))
        code, out, err = self.sert("coverage", "--root", root, "--min", "70")
        self.assertEqual((code, out, "below the 70% floor" in err), (1, "66.7\n", True))

    def test_run_exit_codes_pipes_lute_and_multi_entry_coverage(self):
        root = self.project('[test]\nentries = ["a.luau"]\n')
        self.write(root, {"a.luau": ""})
        luau = self.write_fake_tool(
            root / ".sert/bin/luau",
            "import pathlib, time\n"
            "args = ' '.join(sys.argv[1:])\n"
            "pathlib.Path('args.txt').write_text(args + '\\n', encoding='utf-8', newline='\\n')\n"
            "if 'fail' in args: sys.exit(1)\n"
            "if 'slow' in args: time.sleep(5)\n",
        )
        code, _, err = self.sert("run", "--root", root, "-a", "--filter", "x")
        self.assertEqual((code, (root / "args.txt").read_text().strip(), "$ " in err), (0, "--codegen a.luau -a --filter x --markers", False))
        self.assertEqual(self.sert("run", "--root", root, "-a", "fail")[0], 1)
        self.assertEqual(self.sert("run", "--root", root, "--timeout", "0.3", "-a", "slow")[0], 3)
        self.assertEqual(self.sert("run", "--root", root, "--entry", "missing.luau")[0], 2)

        self.write_fake_tool(
            luau,
            "try:\n"
            "    for _ in range(5000):\n"
            "        sys.stdout.write('sert\\n')\n"
            "        sys.stdout.flush()\n"
            "except OSError:\n"
            "    pass\n",
        )
        env = {**os.environ, "PYTHONPATH": str(PYTHON)}
        proc = subprocess.Popen([sys.executable, "-m", "sert", "run", "--root", str(root)], env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        self.addCleanup(lambda: proc.poll() is None and proc.kill())
        self.assertEqual(proc.stdout.readline().rstrip(b"\r\n"), b"sert")
        proc.stdout.close()
        self.assertEqual(proc.wait(timeout=10), 130)

        mcov = self.project('[test]\nentries = ["a.luau", "b.luau"]\n[coverage]\ninclude = ["src"]\n', name="mcov")
        self.write(mcov, {"a.luau": "", "b.luau": ""})
        mluau = self.write_fake_tool(
            mcov / ".sert/bin/luau",
            "import pathlib\n"
            "args = ' '.join(sys.argv[1:])\n"
            "if 'a.luau' in args:\n"
            "    pathlib.Path('coverage.out').write_text('SF:src/m.luau\\nDA:1,1\\nDA:2,0\\nend_of_record\\n', encoding='utf-8')\n"
            "elif 'b.luau' in args:\n"
            "    pathlib.Path('coverage.out').write_text('SF:src/m.luau\\nDA:1,0\\nDA:2,1\\nend_of_record\\n', encoding='utf-8')\n",
        )
        self.assertEqual(self.sert("run", "--root", mcov, "--coverage")[0], 0)
        self.assertEqual(self.sert("coverage", "--root", mcov)[:2], (0, "100.0\n"))
        self.write_fake_tool(
            mluau,
            "import pathlib\n"
            "if 'a.luau' in ' '.join(sys.argv[1:]):\n"
            "    pathlib.Path('coverage.out').write_text('SF:src/m.luau\\nDA:1,1\\nDA:2,0\\nend_of_record\\n', encoding='utf-8')\n",
        )
        self.assertEqual(self.sert("run", "--root", mcov, "--coverage")[0], 0)
        self.assertEqual((mcov / "coverage.out").read_text().count("SF:src/m.luau"), 1)

        lroot = self.project('[test]\nentries = ["a.luau"]\nrunner = "lute"\n', name="lute")
        self.write(lroot, {"a.luau": ""})
        self.write_fake_tool(
            lroot / ".sert/bin/lute",
            "import pathlib\n"
            "args = ' '.join(sys.argv[1:])\n"
            "pathlib.Path('args.txt').write_text(args + '\\n', encoding='utf-8', newline='\\n')\n"
            "if 'fail' in args: sys.exit(1)\n",
        )
        self.assertEqual(self.sert("run", "--root", lroot, "-a", "all", "--seeds", "5")[0], 0)
        self.assertEqual((lroot / "args.txt").read_text().strip(), "run a.luau all --seeds 5 --markers")
        self.assertEqual(self.sert("run", "--root", lroot, "-a", "fail")[0], 1)
        self.assertEqual(self.sert("run", "--root", lroot, "--coverage")[0], 2)
        (lroot / "sert.toml").write_text('[test]\nentries = ["a.luau"]\nrunner = "node"\n')
        self.assertEqual(self.sert("run", "--root", lroot)[0], 2)

    @unittest.skipIf(sys.platform == "win32", "POSIX signals")
    def test_sigterm_stops_run_and_its_luau(self):
        root = self.project('[test]\nentries = ["a.luau"]\n', name="term")
        self.write(root, {"a.luau": ""})
        luau = root / ".sert/bin/luau"
        luau.parent.mkdir(parents=True)
        luau.write_text("#!/bin/sh\necho $$ > pid.txt\nexec sleep 30\n")
        luau.chmod(0o755)
        proc = subprocess.Popen([sys.executable, "-m", "sert", "run", "--root", str(root)],
                                env={**os.environ, "PYTHONPATH": str(PYTHON)}, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        self.addCleanup(lambda: proc.poll() is None and proc.kill())
        pid_file = root / "pid.txt"
        deadline = time.monotonic() + 10
        while not (pid_file.is_file() and pid_file.read_text().strip()) and time.monotonic() < deadline:
            time.sleep(0.02)
        pid = int(pid_file.read_text())
        self.addCleanup(lambda: subprocess.run(["kill", "-9", str(pid)], capture_output=True))
        proc.terminate()
        self.assertEqual(proc.wait(timeout=10), 130)
        deadline = time.monotonic() + 5
        while Path(f"/proc/{pid}").exists() and time.monotonic() < deadline:
            time.sleep(0.02)
        with self.assertRaises(ProcessLookupError):
            os.kill(pid, 0)

    def test_stage_project_sert_source_and_lexer_edges(self):
        self.assertEqual(coverage.norm(".sert/stage/files/src/Data/Store.luau"), "src/Data/Store.luau")
        self.assertEqual(coverage.norm("./.sert/stage/files/src/init.luau"), "src/init.luau")

        for name, val in (("ext_a", "a"), ("ext_b", "b")):
            d = self.tmp / name
            d.mkdir(parents=True, exist_ok=True)
            (d / "init.luau").write_text(f"return '{val}'\n")

        root = self.project('[test]\nentries = ["a.luau"]\nstage = "default.project.json"\n')
        self.write(root, {
            "default.project.json": (
                '{"name": "Demo", "tree": {"$path": "src", "$properties": {"Tags": ["RootTag"],}, '
                '"$attributes": {"Version": 2,}, "Sub": {"$attributes": {"Extra": true},}, '
                '"ExtA": {"$path": "../ext_a"}, "ExtB": {"$path": "../ext_b"},}}\n'
            ),
            "src/init.luau": "--!strict\nreturn { x = 1 }\n",
            "src/Sub.luau": "return 2\n",
            "src/Sub.meta.json": '{"properties": {"Archivable": false,}, "attributes": {"FromMeta": "yes",}}',
            "src/Note.txt": "  hello world  \r\n",
            "src/Stale.luau": "return 0\n",
        })
        init_path = run_mod.stage_project(root, "default.project.json")
        init_text = init_path.read_text()
        self.assertTrue(init_text.startswith("-- sert-stage-v2\n"))
        for want in ('require("@self/files/src")()', 'require("@self/files/src/Sub")()', "__up__/ext_a/init.luau",
                     "__up__/ext_b/init.luau", '["Tags"] = { "RootTag" }', '["FromMeta"] = "yes"', '["Extra"] = true', '["value"] = "  hello world  "'):
            self.assertIn(want, init_text)
        wrapped_file = root / ".sert/stage/files/src/init.luau"
        self.assertTrue(wrapped_file.read_text().startswith("return function() return function(_ENV: any, ...: any): ...any setfenv(1, _ENV) --!strict\n"))

        (root / "src/Stale.luau").unlink()
        old_mtime = wrapped_file.stat().st_mtime_ns
        run_mod.stage_project(root, "default.project.json")
        self.assertEqual((wrapped_file.stat().st_mtime_ns, (root / ".sert/stage/files/src/Stale.luau").exists()), (old_mtime, False))

        padding = "-- " + ("x" * 350) + "\n"
        (root / "src/Sub.luau").write_text(padding + "return 2\n")
        run_mod.stage_project(root, "default.project.json")
        staged_sub = root / ".sert/stage/files/src/Sub.luau"
        staged_sub.write_text(mutate.wrap_staged_source(padding + "if (_G :: any).__SERT_MUTANT == 1 then return nil end return 2\n"))
        self.assertTrue(b"__SERT_MUTANT" not in staged_sub.read_bytes()[:256] and b"setmetatable(_G," in staged_sub.read_bytes()[:512])
        run_mod.stage_project(root, "default.project.json")
        healed = staged_sub.read_text()
        self.assertTrue("__SERT_MUTANT" not in healed and "setmetatable(_G," not in healed)

        staged_sub.write_text(padding + "return 2\n")
        run_mod.stage_project(root, "default.project.json")
        self.assertTrue(staged_sub.read_bytes().startswith(run_mod.STAGE_WRAP_PREFIX))

        dot_root = self.project('[test]\nentries = ["a.luau"]\nstage = "default.project.json"\n', name="dot-stage")
        self.write(dot_root, {
            "default.project.json": '{"name": "DotRoot", "tree": {"$path": "."}}\n',
            "init.luau": "return 'dot-root'\n",
            "Child.luau": "return 'child'\n",
        })
        dot_init = run_mod.stage_project(dot_root, "default.project.json").read_text()
        self.assertTrue('require("@self/files")()' in dot_init and 'require("@self/files/Child")()' in dot_init)

        sert_src = self.tmp / "sert-ref"
        (sert_src / "src").mkdir(parents=True)
        (sert_src / "src/init.luau").write_text("return { from = 'sert-ref' }\n")
        (sert_src / "default.project.json").write_text('{"name": "sert", "tree": {"$path": "src"}}')
        sroot = self.project('[sert]\nversion = "0.1.0"\n', name="sroot")
        self.setenv("CI", "true")
        self.setenv("SERT_SOURCE", str(sert_src))
        self.assertEqual(self.sert("fetch", "--root", sroot, "--only", "sert")[0], 0)
        self.assertEqual((sroot / ".sert/sert/src/init.luau").read_text(), "return { from = 'sert-ref' }\n")
        self.assertTrue((sroot / ".sert/bin/sert").is_file())
        (sert_src / "src/init.luau").write_text("return { from = 'sert-ref-updated' }\n")
        (sert_src / "src/Extra.luau").write_text("return 42\n")
        self.assertGreaterEqual(fetch.refresh_overrides(config.load(sroot)), 1)
        self.assertEqual((sroot / ".sert/sert/src/init.luau").read_text(), "return { from = 'sert-ref-updated' }\n")
        self.assertEqual((sroot / ".sert/sert/src/Extra.luau").read_text(), "return 42\n")

        source = 'local msg = `hello {foo("`")} world` -- comment\ntask.wait(1)'
        self.assertIn("task.wait(1)", mutate.code_lines(source, keep_strings=False)[1])
        self.assertEqual(mutate.code_lines(source, keep_strings=True), ['local msg = `hello {foo("`")} world` ', "task.wait(1)"])

        rroot = self.project("", name="rroot")
        self.write(rroot, {"test/unit/init.luau": 'require("./unit/FooBar.spec")\nrequire("./unit/AuthToken")\n',
                           "test/unit/Foo.spec.luau": "", "test/unit/FooBar.spec.luau": "", "test/unit/Auth.luau": "",
                           "test/unit/AuthToken.luau": "", "test/sibling/Sib.spec.luau": ""})
        self.assertEqual(registration_problems(rroot, {"aggregator": "test/unit/init.luau", "specs": "test/unit/*.spec.luau"}),
                         ["test/unit/Foo.spec.luau is not required by test/unit/init.luau"])
        self.assertEqual(registration_problems(rroot, {"aggregator": "test/unit/init.luau", "specs": "test/unit/Auth*.luau"}),
                         ["test/unit/Auth.luau is not required by test/unit/init.luau"])
        self.assertEqual(registration_problems(rroot, {"aggregator": "test/unit/init.luau", "specs": ["test/sibling/*.spec.luau", "test/unit/FooBar.spec.luau"]}),
                         ["test/sibling/Sib.spec.luau is not required by test/unit/init.luau"])


class DoctorAndEdgeCasesTest(ToolCase):
    def test_init_resolve_entries_and_require_fetched(self):
        target = self.tmp / "new-consumer"
        code, out, err = self.sert("init", "--root", target)
        self.assertEqual((code, "init: wrote sert.toml" in out), (0, True), out + err)
        for rel in ("sert.toml", "tools/sert.py", ".luaurc", ".gitignore", "test/Example.spec.luau"):
            self.assertTrue((target / rel).is_file(), rel)
        self.assertIn("already initialized", self.sert("init", "--root", target)[1])

        luaurc = '{ // project aliases\n\t"languageMode": "strict", "aliases": { "pkg": "./Packages" } }\n'
        (target / ".luaurc").write_text(luaurc)
        for flags in ((), ("--force",)):
            code, out, _ = self.sert("init", *flags, "--root", target)
            self.assertEqual((code, '.luaurc does not parse as JSON' in out, (target / ".luaurc").read_text()), (0, True, luaurc))
        (target / ".luaurc").write_text('{"aliases": {"sert": "./.sert/sert/src"}}')

        cfg = config.load(target)
        self.assertEqual(run_mod.resolve_entries(cfg), [".sert/run.luau"])
        generated = (target / ".sert/run.luau").read_text(encoding="utf-8")
        self.assertTrue('require("@sert")' in generated and 'require("../test/Example.spec")' in generated and "return sert.run(options)" in generated)
        self.assertNotIn("options.command", generated)

        setup_root = self.project('[test]\nspecs = ["test"]\nsetup = "test/setup.luau"\n', name="spec-dir-proj")
        self.write(setup_root, {"test/setup.luau": "return {}\n", "test/sub/One.spec.luau": "return {}\n"})
        cfg_setup = config.load(setup_root)
        self.assertEqual(run_mod.resolve_entries(cfg_setup), [".sert/run.luau"])
        gen_setup = (cfg_setup.root / ".sert/run.luau").read_text(encoding="utf-8")
        self.assertTrue('require("../test/setup")' in gen_setup and 'require("../test/sub/One.spec")' in gen_setup)
        self.assertEqual(run_mod.resolve_entries(cfg_setup, cli_specs=["test/sub/One.spec.luau"]), [".sert/run.luau"])
        with self.assertRaisesRegex(SertError, r"spec file test/Missing\.spec\.luau not found"):
            run_mod.resolve_entries(cfg_setup, cli_specs=["test/Missing.spec.luau"])
        with self.assertRaisesRegex(SertError, r"no spec files matched"):
            run_mod.resolve_entries(cfg_setup, cli_specs=["test/*.nomatch.luau"])

        froot = self.project('[tools]\nluau = "0.724"\n', name="fetched")
        with self.assertRaisesRegex(SertError, r"luau 0\.724 is pinned but \.sert/bin/luau is missing"):
            run_mod.require_fetched(config.load(froot))
        (froot / ".sert/bin").mkdir(parents=True)
        (froot / ".sert/bin/luau").write_text("")
        run_mod.require_fetched(config.load(froot))

        (froot / ".luaurc").write_text('{"aliases": {"sert": "./.sert/sert/src"}}')
        (froot / "sert.toml").write_text('[sert]\nversion = "0.1.0"\n')
        with self.assertRaisesRegex(SertError, r'\.sert/sert is missing, which the \.luaurc "sert" alias points into'):
            run_mod.require_fetched(config.load(froot))
        (froot / "sert.toml").write_text("")
        with self.assertRaisesRegex(SertError, rf'add version = "{VERSION}"'):
            run_mod.require_fetched(config.load(froot))
        (froot / ".sert/sert/src").mkdir(parents=True)
        run_mod.require_fetched(config.load(froot))

    def test_workspace_edges_and_diagnostics(self):
        self.assertEqual(strip_trailing_commas('{"a": "x,}", "b": [1, 2,],}'), '{"a": "x,}", "b": [1, 2]}')
        with self.assertRaisesRegex(SertError, r"solver"):
            lint.solvers(["invalid"])

        self.fake_tools()
        rojo = self.write_fake_tool(
            self.tmp / "bin/rojo",
            "import pathlib\npathlib.Path(sys.argv[-1]).write_text('{}\\n', encoding='utf-8')\n",
        )

        root = self.project('[lint]\nproject = "custom.project.json"\n', name="ana-1")
        (root / "custom.project.json").write_text("{}\n")
        cfg = config.load(root)
        with lint.Workspace(cfg, dry_run=True) as ws:
            self.assertEqual((ws.project(), ws.build_sourcemap()[1]), ("custom.project.json", True))
            self.assertIn(f"--sourcemap={ws.sourcemap}", ws.analyze_command("new", Path("defs.d.luau"), ["src"], ignore=["a/**"], platform="roblox", definitions=["extra.d.luau"]))
        with lint.Workspace(cfg, dry_run=False) as ws:
            self.assertTrue(ws.build_sourcemap()[1] and ws.sourcemap.is_file())
        self.write_fake_tool(rojo, "sys.stderr.write('rojo failed\\n')\nsys.exit(1)\n")
        with lint.Workspace(cfg, dry_run=False) as ws:
            self.assertEqual((ws.build_sourcemap()[1], ws.sourcemap), (False, None))

        root2 = self.project("", name="ana-2")
        with lint.Workspace(config.load(root2)) as ws:
            self.assertEqual((ws.project(), ws.build_sourcemap()), (None, ([], True)))
        (root2 / "default.project.json").write_text("{}\n")
        with lint.Workspace(config.load(root2)) as ws:
            self.assertEqual(ws.project(), "default.project.json")

        inside, outside = (root / "src/A.luau").resolve(), (self.tmp / "outside/B.luau").resolve()
        errs = lint.error_lines(cfg, f"not a location line\n{inside}(10,2): TypeError: x\n{outside}(20,1): TypeError: y\n./src/C.luau(5,1): TypeError: z\n")
        self.assertEqual((errs["src/A.luau"], errs["src/C.luau"], outside.as_posix() in errs), ({10}, {5}, True))

        empty_types = self.project('[types]\n[lint]\nproject = false\n', name="empty-types")
        self.defs(empty_types)
        self.assertEqual(lint.check_types(config.load(empty_types)), 0)
        for name, toml, msg in (
            ("no-types", "", "no [types] table"),
            ("bad-pass", '[types]\npass = "missing_dir"\n', "[types].pass: missing_dir is not a directory"),
            ("bad-fail", '[types]\nfail = "missing_fail"\n', "[types].fail: missing_fail is not a directory"),
        ):
            r = self.project(toml, name=name)
            self.defs(r)
            res = self.sert("lint", "--only", "types", "--root", r)
            self.assertEqual((res[0], msg in res[2]), (2, True))

        dry_types = self.project('[types]\npass = "tp"\nfail = "tf"\n', name="dry-types")
        (dry_types / "default.project.json").write_text("{}\n")
        self.write(dry_types, {"tp/A.luau": "return 1\n", "tf/B.luau": "local x = BAD -- expect-error\n"})
        code, out, _ = self.sert("lint", "--only", "types", "--root", dry_types, "--dry-run")
        self.assertEqual((code, "rojo sourcemap" in out and "luau-lsp analyze" in out), (0, True))
        no_defs_stub = self.project('[lint]\nstub = false\n', name="no-defs-stub")
        self.assertEqual(self.sert("lint", "--only", "stub", "--root", no_defs_stub)[0], 0)

        with self.assertRaisesRegex(SertError, r"aggregator"):
            registration_problems(empty_types, {"aggregator": "a.luau"})
        self.assertEqual(registration_problems(empty_types, {"aggregator": "missing.luau", "specs": "*.luau"}), ["missing.luau not found"])
        with self.assertRaisesRegex(SertError, r"paths"):
            lint.analyze_groups(config.load(self.project("[[lint.analyze]]\nname = 'x'\n", name="bad-group")))
        fail_extra = self.project(f'[lint]\nproject = false\nstylua = false\nstub = false\nextra = [["nonexistent_binary_xyz"], [{json.dumps(sys.executable)}, "-c", "raise SystemExit(1)"]]\n', name="fail-extra")
        self.defs(fail_extra)
        self.write(fail_extra, {"src/init.luau": "return 1\n"})
        code, _, err = self.sert("lint", "--root", fail_extra)
        self.assertEqual((code, "extra:" in err), (1, True))

        self.assertEqual(self.sert("coverage", "--root", empty_types)[0], 2)
        with self.assertRaisesRegex(SertError, r"no records under src"):
            coverage.summarize({"other/a.luau": {1: True}}, ["src"])
        with self.assertRaisesRegex(SertError, r"holds no records"):
            coverage.summarize({}, ["src"])

        self.assertTrue(run_mod.wrap_luau_source("#!/usr/bin/env luau\nreturn 1").startswith("return function()"))
        self.assertEqual([run_mod._require_spec_for_rel(p) for p in ("a/init.lua", "init.luau", "a/b.lua", "a/b.other")],
                         ["@self/files/a", "@self/files", "@self/files/a/b", "@self/files/a/b.other"])
        self.assertIsNone(run_mod._classify_script_file(Path("data.json")))
        with self.assertRaises(TypeError):
            run_mod._luau_literal(object())
        with self.assertRaisesRegex(SertError, r"project file not set"):
            run_mod.stage_project(empty_types, None)
        with self.assertRaisesRegex(SertError, r"missing\.project\.json not found"):
            run_mod.stage_project(empty_types, "missing.project.json")

        stage_root = self.project('[test]\nentries = ["e.luau"]\nstage = "default.project.json"\ncodegen = true\n', name="stage-edges")
        self.write(stage_root, {
            "default.project.json": (
                '{"name": "R", "tree": {"$className": "DataModel", "SubProj": {"$path": "sub.project.json"}, '
                '"SubDirProj": {"$path": "subdir"}, "Txt": {"$path": "hello.txt"}, "Txt.meta.json": "{\\"className\\": \\"StringValue\\"}", '
                '"Mod": {"$path": "Mod.client.luau"}, "Mod.meta.json": "{bad json", "JsonFile": {"$path": "ignore.json"}, '
                '"Missing": {"$path": "does_not_exist"}, "Dir": {"$path": "dir", "Child": {"$className": "Configuration", "$properties": {"Archivable": true}}}}}'
            ),
            "sub.project.json": '{"name": "Sub", "tree": {"$className": "Folder"}}',
            "subdir/default.project.json": '{"name": "SubDir", "tree": {"$className": "Folder"}}',
            "hello.txt": "hello\n", "Mod.client.luau": "return 1\n", "ignore.json": "{}\n",
            "dir/init.meta.json": '{"className": "Model"}', "dir/Child/init.server.luau": "return 2\n",
            "dir/Child.meta.json": '{"attributes": {"A": 1}}', "dir/Note.txt": "note\n",
            "dir/Note.meta.json": '{"attributes": {"N": 2}}', "e.luau": "return 0\n",
        })
        init_p = run_mod.stage_project(config.load(stage_root))
        staged_text = init_p.read_text()
        for token in ("SubProj", "SubDirProj", "StringValue", "hello", "LocalScript", "Archivable"):
            self.assertIn(token, staged_text)
        self.assertTrue((init_p.parent / "files/Mod.client.luau").is_file() and (init_p.parent / "files/dir/Child/init.server.luau").is_file())
        self.assertEqual(run_mod.entry_command("luau", "luau", "e.luau", [], False, codegen=True), ["luau", "--codegen", "e.luau"])
        self.assertEqual(self.sert("run", "--root", empty_types)[0], 2)

    def test_static_check_fixes_and_lexer(self):
        cfg = config.load(self.project(""))
        kinds = {(n, line, m.split(":", 1)[0]): lint.is_lint(m) for n, line, m in lint.diagnostics(cfg, LSP_SAMPLE)}
        self.assertEqual(kinds, {
            ("p.luau", 1, "TypeError"): False, ("p.luau", 4, "TypeError"): False,
            ("p.luau", 2, "LocalUnused"): True, ("p.luau", 3, "DuplicateLocal"): True,
            ("p.luau", 7, "SameLineStatement"): True, ("p.luau", 7, "LocalShadow"): True,
            ("syn.luau", 2, "SyntaxError"): False, ("syn.luau", 2, "MultiLineStatement"): True,
        })
        self.assertEqual((lint.is_lint("SomeFutureLint: x"), lint.is_lint("InternalError: x"), lint.is_lint("no category here")), (True, False, False))
        self.assertEqual(lint.error_lines(cfg, LSP_SAMPLE, errors_only=True), {"p.luau": {1, 4}, "syn.luau": {2}})
        self.assertEqual(lint.error_lines(cfg, LSP_SAMPLE)["p.luau"], {1, 2, 3, 4, 7})

        self.fake_tools()
        root = self.project('[lint]\npaths = ["src"]\nproject = false\nstub = false\n', name="chatter")
        self.defs(root)
        self.write(root, {"src/A.luau": "local x = BAD\n"})
        lsp = self.write_fake_tool(
            self.tmp / "bin/luau-lsp",
            "print('[INFO] Loading definitions file: @roblox')\n"
            "print('[WARN] client does not allow didChangeWatchedFiles registration', file=sys.stderr)\n"
            "print('src/A.luau(1,11): TypeError: Unknown global \\'BAD\\'')\nsys.exit(1)\n",
        )
        code, out, err = self.sert("lint", "--root", root, "--skip", "stylua", "--skip", "types")
        self.assertEqual(code, 1)
        self.assertIn("src/A.luau(1,11): TypeError: Unknown global 'BAD'", out)
        self.assertTrue("[INFO]" not in out + err and "didChangeWatchedFiles" not in out + err)

        proot = self.project('[types]\nfail = "t/fail"\n[lint]\nproject = false\n', name="fprobe")
        self.defs(proot)
        self.write(proot, {"t/fail/P.luau": "local x: any = 1 -- expect-error\n"})
        self.write_fake_tool(lsp, "print(\"t/fail/P.luau(1,7): LocalUnused: Variable 'x' is never used\")\nsys.exit(1)\n")
        code, _, err = self.sert("lint", "--only", "types", "--root", proot)
        self.assertEqual((code, "should fail to type-check on lines [1], but failed on []" in err), (1, True))

        text = 'local s = "abc\\z\n   task.wait(1)"\nprint(s)\n'
        code_l = mutate.code_lines(text)
        self.assertTrue("task.wait" not in code_l[1] and "print(s)" in code_l[2])
        self.assertEqual(mutate.code_lines(text, keep_strings=True)[:2], ['local s = "abc\\z', '   task.wait(1)"'])
        self.assertEqual(mutate.scan_lines(text)[2], [True, True, False, False])
        code_i = mutate.code_lines("local t = `a{\n1 + 2\n}b task.wait(2)`\nprint(t)\n")
        self.assertTrue("1 + 2" in code_i[1] and "task.wait" not in code_i[2] and "print(t)" in code_i[3])
        code_b = mutate.code_lines("x = [==[ ]] task.wait ]==] .. `a{`b{1}`}c` --[==[ ]] task.wait ]==] y = 1\n")
        self.assertTrue("task.wait" not in code_b[0] and "y = 1" in code_b[0])
        self.assertEqual(mutate.source_lines("a\r\nb\u2028c\n"), ["a", "b\u2028c", ""])
        self.assertEqual(mutate.code_lines("-- a\rtask.wait(3)\nx\n"), ["\rtask.wait(3)", "x", ""])

    @unittest.skipUnless(HAS_LSP, "luau-lsp not on PATH")
    def test_real_lsp_probes_and_annotations(self):
        rokit_toml = (REPO / "rokit.toml").read_text(encoding="utf-8")
        root = self.project('[types]\nfail = "t/fail"\nsolvers = ["new", "old"]\n[lint]\nproject = false\n', name="real1")
        (root / "rokit.toml").write_text(rokit_toml, encoding="utf-8")
        (root / ".sert/types").mkdir(parents=True, exist_ok=True)
        (root / ".sert/types/globalTypes.d.luau").write_text("declare FIXTURE: number\n")
        self.write(root, {"t/fail/P.luau": '--!strict\nlocal unused = 1\nlocal x: number = "s" -- expect-error\n'})
        code, out, err = self.sert("lint", "--only", "types", "--root", root)
        self.assertEqual((code, "0 clean and 1 failing probes hold under new and old" in out), (0, True), out + err)
        self.write(root, {"t/fail/P.luau": '--!strict\nlocal x: any = "s" -- expect-error\n'})
        code, _, err = self.sert("lint", "--only", "types", "--root", root)
        self.assertEqual((code, "under the new solver" in err and "under the old solver" in err), (1, True))

        root2 = self.project('[lint]\npaths = ["src"]\nproject = false\nsolvers = ["new", "old"]\nstylua = false\nstub = false\n', name="real2")
        (root2 / "rokit.toml").write_text(rokit_toml, encoding="utf-8")
        (root2 / ".sert/types").mkdir(parents=True, exist_ok=True)
        (root2 / ".sert/types/globalTypes.d.luau").write_text("declare FIXTURE: number\n")
        self.write(root2, {"src/a.luau": '--!strict\nlocal unused = 1\nlocal n: number = "s"\nreturn n\n'})
        self.setenv("GITHUB_ACTIONS", "true")
        code, out, _ = self.sert("lint", "--root", root2)
        self.assertEqual((code, out.count("::warning file=src/a.luau,line=2,"), out.count("::error file=src/a.luau,line=3,")), (1, 2, 2))
        self.assertNotIn("::error file=src/a.luau,line=2,", out)


if __name__ == "__main__":
    unittest.main()
