"""Unit tests for `sert lint` (`--fix`, type probes, analyze groups, stub), `sert coverage`, and Typed Lexical Staging + 0-return staging."""

from __future__ import annotations

import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import time
import unittest

from helpers import PYTHON, REPO, Case, copy_sert_src, have
from sert import VERSION, config, coverage, fetch, lint, mutate, run as run_mod
from sert.util import SertError, strip_jsonc

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


class ToolCase(Case):
    def fake_tools(self):
        bin_dir = self.tmp / "bin"
        bin_dir.mkdir(exist_ok=True)
        self.lsp_log = self.tmp / "lsp.log"
        self.stylua_log = self.tmp / "stylua.log"
        self.write_fake_tool(bin_dir / "luau-lsp", FAKE_LSP.format(python=sys.executable, log=str(self.lsp_log)))
        self.write_fake_tool(
            bin_dir / "stylua",
            f"import pathlib\npathlib.Path({str(self.stylua_log)!r}).write_text(' '.join(sys.argv[1:]) + '\\n', encoding='utf-8')\nsys.exit(0)\n",
        )
        self.write_fake_tool(bin_dir / "selene", "sys.exit(0)\n")
        self.setenv("PATH", f"{bin_dir}{os.pathsep}{os.environ['PATH']}")

    def defs(self, root: Path):
        path = root / ".sert/types/globalTypes.d.luau"
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(
            "declare class Instance\n\tName: string\n\tfunction Remove(self): ()\nend\n"
            "declare class GuiObject extends Instance\n\tPosition: UDim2\nend\n"
        )

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
        self.write(
            root,
            {
                "test/types/Good.luau": "local x = 1\n",
                "test/types/fail/Probe.luau": "local a = 1\nlocal b = BAD -- expect-error\n",
                "test/types/fail/Probe2.luau": "local c = BAD -- expect-error\n",
            },
        )
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

    def test_lint_fix_stub_dry_run_and_analyze_groups(self):
        self.fake_tools()
        root = self.project(
            '[lint]\npaths = ["src", "test"]\nproject = false\n'
            f'extra = [[{json.dumps(sys.executable)}, "-c", "raise SystemExit(0)"]]\n'
        )
        self.defs(root)
        self.write(root, {"src/init.luau": "return {}\n", "test/A.spec.luau": "return nil\n"})
        (root / "tools").mkdir()
        shutil.copy(REPO / "tools/sert.py", root / "tools/sert.py")

        # Default `sert lint` passes `--check` to stylua
        code, out, err = self.sert("lint", "--root", root)
        self.assertEqual((code, "lint: ok" in out), (0, True), out + err)
        self.assertEqual(self.stylua_log.read_text().strip(), "--check src test")

        # `sert lint --fix` invokes stylua WITHOUT `--check`!
        code_fix, out_fix, err_fix = self.sert("lint", "--fix", "--root", root)
        self.assertEqual((code_fix, "lint: ok" in out_fix), (0, True), out_fix + err_fix)
        self.assertEqual(self.stylua_log.read_text().strip(), "src test")

        # Tampered stub + analyze error both reported
        self.write(root, {"src/x.luau": "local y = BAD\n"})
        (root / "tools/sert.py").write_text("# edited\n")
        code_bad, _, err_bad = self.sert("lint", "--root", root)
        self.assertEqual(code_bad, 1)
        for want in ("tools/sert.py differs", "failed: analyze, stub"):
            self.assertIn(want, err_bad)

        dry = self.project('[lint]\npaths = ["src"]\nsolvers = ["new", "old"]\nselene = true\n[types]\nfail = "t/fail"\n', name="dry")
        code, out, _ = self.sert("lint", "--root", dry, "--dry-run", "--skip", "types")
        self.assertEqual((code, out.count("luau-lsp analyze")), (0, 2))
        for want in ("--ignore=**/t/fail/**", "stylua --check src", "selene src"):
            self.assertIn(want, out)

        dry_fix_code, dry_fix_out, _ = self.sert("lint", "--root", dry, "--dry-run", "--fix", "--only", "stylua")
        self.assertEqual(dry_fix_code, 0)
        self.assertIn("stylua src", dry_fix_out)
        self.assertNotIn("--check", dry_fix_out)

        self.lsp_log.write_text("")
        grp = self.project(
            '[lint]\npaths = ["core", "game"]\nproject = false\nsolvers = ["old", "new"]\nstub = false\n'
            '[[lint.analyze]]\nname = "portable"\nplatform = "standard"\ndefs = false\npaths = ["core", "gen/*/portable"]\nignore = ["core/skip/**"]\n'
            '[[lint.analyze]]\nname = "roblox"\npaths = ["game"]\ndefinitions = ["extra.d.luau"]\nsolvers = ["new"]\n',
            name="grp",
        )
        self.defs(grp)
        self.write(
            grp,
            {
                "core/a.luau": "return 1\n",
                "gen/b/portable/x.luau": "return 2\n",
                "gen/a/portable/y.luau": "return 3\n",
                "game/c.luau": "return 4\n",
                "extra.d.luau": "declare SHARD: any\n",
            },
        )
        code, out, err = self.sert("lint", "--root", grp)
        self.assertEqual(code, 0, out + err)
        portable_old, portable_new, roblox = self.lsp_log.read_text().splitlines()
        self.assertTrue("old-solver.json" in portable_old and "new-solver.json" in portable_new and "--defs" not in portable_old)
        self.assertTrue("--platform=standard" in portable_old and portable_old.endswith("core gen/a/portable gen/b/portable"))
        self.assertIn("--ignore=.sert/** --ignore=core/skip/**", portable_old)
        self.assertTrue("--defs=extra.d.luau" in roblox and "globalTypes.d.luau" in roblox and "--platform" not in roblox and roblox.endswith(" game"))


class CoverageAndStagingTest(ToolCase):
    def test_coverage_stage_path_normalization_and_pipes(self):
        # Verify coverage normalizes both `.sert/stage/lexical/...` and `.sert/stage/specs/...` back to source paths!
        self.assertEqual(coverage.norm(".sert/stage/lexical/src/Data/Store.luau"), "src/Data/Store.luau")
        self.assertEqual(coverage.norm("./.sert/stage/lexical/src/init.luau"), "src/init.luau")
        self.assertEqual(coverage.norm(".sert/stage/specs/test/Math.spec.luau"), "test/Math.spec.luau")

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
        self.assertEqual(self.sert("run", "--root", root, "--timeout", "0.05", "-a", "slow")[0], 3)
        self.assertEqual(self.sert("run", "--root", root, "--entry", "missing.luau")[0], 2)

        # BrokenPipeError on stdout stops child and returns 130 (INTERRUPTED)
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
        proc = subprocess.Popen(
            [sys.executable, "-m", "sert", "run", "--root", str(root)],
            env=env,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
        )
        self.addCleanup(lambda: proc.poll() is None and proc.kill())
        self.assertEqual(proc.stdout.readline().rstrip(b"\r\n"), b"sert")
        proc.stdout.close()
        self.assertEqual(proc.wait(timeout=10), 130)

        # Multi-entry coverage merging
        mcov = self.project('[test]\nentries = ["a.luau", "b.luau"]\n[coverage]\ninclude = ["src"]\n', name="mcov")
        self.write(mcov, {"a.luau": "", "b.luau": ""})
        self.write_fake_tool(
            mcov / ".sert/bin/luau",
            "import pathlib\n"
            "args = ' '.join(sys.argv[1:])\n"
            "if 'a.luau' in args:\n"
            "    pathlib.Path('coverage.out').write_text('SF:.sert/stage/lexical/src/m.luau\\nDA:1,1\\nDA:2,0\\nend_of_record\\n', encoding='utf-8')\n"
            "elif 'b.luau' in args:\n"
            "    pathlib.Path('coverage.out').write_text('SF:src/m.luau\\nDA:1,0\\nDA:2,1\\nend_of_record\\n', encoding='utf-8')\n",
        )
        self.assertEqual(self.sert("run", "--root", mcov, "--coverage")[0], 0)
        self.assertEqual(self.sert("coverage", "--root", mcov)[:2], (0, "100.0\n"))

        # lute runner
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
        self.assertEqual(self.sert("run", "--root", lroot, "--coverage")[0], 2)

    @unittest.skipIf(sys.platform == "win32", "POSIX signals")
    def test_sigterm_stops_run_and_its_luau(self):
        root = self.project('[test]\nentries = ["a.luau"]\n', name="term")
        self.write(root, {"a.luau": ""})
        luau = root / ".sert/bin/luau"
        luau.parent.mkdir(parents=True)
        luau.write_text("#!/bin/sh\necho $$ > pid.txt\nexec sleep 30\n")
        luau.chmod(0o755)
        proc = subprocess.Popen(
            [sys.executable, "-m", "sert", "run", "--root", str(root)],
            env={**os.environ, "PYTHONPATH": str(PYTHON)},
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        self.addCleanup(lambda: proc.poll() is None and proc.kill())
        pid_file = root / "pid.txt"
        deadline = time.monotonic() + 5
        while not (pid_file.is_file() and pid_file.read_text().strip()) and time.monotonic() < deadline:
            time.sleep(0.01)
        pid = int(pid_file.read_text())
        self.addCleanup(lambda: subprocess.run(["kill", "-9", str(pid)], capture_output=True))
        proc.terminate()
        self.assertEqual(proc.wait(timeout=5), 130)
        deadline = time.monotonic() + 3
        while Path(f"/proc/{pid}").exists() and time.monotonic() < deadline:
            time.sleep(0.01)
        with self.assertRaises(ProcessLookupError):
            os.kill(pid, 0)

    def test_typed_lexical_staging_zero_setfenv_and_game_mirrors(self):
        for name, val in (("ext_a", "a"), ("ext_b", "b")):
            d = self.tmp / name
            d.mkdir(parents=True, exist_ok=True)
            (d / "init.luau").write_text(f"return '{val}'\n")

        root = self.project('[test]\nentries = ["a.luau"]\nstage = "default.project.json"\n')
        self.write(
            root,
            {
                ".luaurc": '// comment preserved\n{\n  "aliases": {\n    "sert": "../src",\n  },\n}\n',
                "default.project.json": (
                    '{"name": "Demo", "tree": {"$className": "DataModel", '
                    '"ReplicatedStorage": {"$className": "ReplicatedStorage", '
                    '"Shared": {"$path": "src", "$properties": {"Tags": ["RootTag"],}, '
                    '"$attributes": {"Version": 2,}, "Sub": {"$attributes": {"Extra": true},}}, '
                    '"ExtA": {"$path": "../ext_a"}, "ExtB": {"$path": "../ext_b"}}}}\n'
                ),
                "src/init.luau": "--!strict\nlocal v = Vector3.new(1, 2, 3)\nreturn { x = v }\n",
                "src/Sub.luau": "--!strict\nexport type Config = { retries: number }\nreturn { retries = 3 }\n",
                "src/Sub.meta.json": '{"properties": {"Archivable": false,}, "attributes": {"FromMeta": "yes",}}',
                "src/Note.txt": "  hello world  \r\n",
                "src/Stale.luau": "return 0\n",
            },
        )
        init_path = run_mod.stage_project(root, "default.project.json")
        init_text = init_path.read_text(encoding="utf-8")
        self.assertTrue(init_text.startswith("-- sert-stage-v4\n"))
        for want in (
            'require("@self/lexical/src")',
            'require("@self/lexical/src/Sub")',
            "__up__/ext_a/init.luau",
            "__up__/ext_b/init.luau",
            '["Tags"] = { "RootTag" }',
            '["FromMeta"] = "yes"',
            '["Extra"] = true',
            '["value"] = "  hello world  "',
        ):
            self.assertIn(want, init_text)

        # Verify lexical wrapper has ZERO `setfenv` / `getfenv`, keeps `--!strict` at top, and preserves line numbers!
        wrapped_init = (root / ".sert/stage/lexical/src/init.luau").read_text(encoding="utf-8")
        self.assertTrue(wrapped_init.startswith("--!strict\nreturn function(_ENV: any, ...: any): ...any local Vector3 = _ENV.Vector3; local v = Vector3.new(1, 2, 3)\n"))
        self.assertNotIn("setfenv", wrapped_init)
        self.assertNotIn("getfenv", wrapped_init)

        # Verify `--!strict` type-preserving `@game` mirrors were generated AND `@game` alias added to `.luaurc` preserving JSONC comments!
        mirror_sub = (root / ".sert/stage/game/Shared/Sub.luau").read_text(encoding="utf-8")
        self.assertTrue(mirror_sub.startswith("--!strict\n"))
        self.assertIn("src/Sub", mirror_sub)
        rc_raw = (root / ".luaurc").read_text(encoding="utf-8")
        self.assertIn("// comment preserved", rc_raw)
        self.assertEqual(json.loads(strip_jsonc(rc_raw))["aliases"]["game"], "./.sert/stage/game")

        # Stale files pruned & unchanged mtimes preserved
        (root / "src/Stale.luau").unlink()
        old_mtime = (root / ".sert/stage/lexical/src/init.luau").stat().st_mtime_ns
        run_mod.stage_project(root, "default.project.json")
        self.assertEqual(
            ((root / ".sert/stage/lexical/src/init.luau").stat().st_mtime_ns, (root / ".sert/stage/lexical/src/Stale.luau").exists()),
            (old_mtime, False),
        )

        # Healing mutated lexical file back to clean lexical wrapper
        staged_sub = root / ".sert/stage/lexical/src/Sub.luau"
        staged_sub.write_text(mutate.wrap_staged_source("if rawget(_G, '__SERT_MUTANT') == 1 then return nil end\nreturn 2\n"), encoding="utf-8")
        run_mod.stage_project(root, "default.project.json")
        self.assertNotIn("__SERT_MUTANT", staged_sub.read_text(encoding="utf-8"))

        # `wrap_luau_source` omits outer `local type = _ENV.type` when a Luau 0.724 `type function` calls `type(...)`
        wrapped_tf = run_mod.wrap_luau_source(
            "--!strict\nexport type function check(t)\n\tif type('a') == 'string' then return t end\n\treturn t\nend\nreturn Vector3.zero\n"
        )
        self.assertIn("Vector3 = _ENV.Vector3", wrapped_tf)
        self.assertNotIn("_ENV.type", wrapped_tf)

        # `stage_project(cfg)` leaves root `.luaurc` untouched when `[test].specs` + `[lint].project` use Rojo sourcemaps
        sm_root = self.project(
            '[test]\nspecs = ["tests/**/*.spec.luau"]\nstage = "default.project.json"\n[lint]\nproject = "default.project.json"\n',
            name="stage_sm",
        )
        (sm_root / ".luaurc").write_text('{"aliases": {"sert": "./.sert/sert/src"}}\n', encoding="utf-8")
        self.write(
            sm_root,
            {
                "default.project.json": '{"name": "Demo", "tree": {"$className": "DataModel", "ReplicatedStorage": {"$className": "ReplicatedStorage", "Shared": {"$path": "src"}}}}\n',
                "src/init.luau": "return 1\n",
            },
        )
        run_mod.stage_project(config.load(sm_root))
        self.assertNotIn("game", json.loads((sm_root / ".luaurc").read_text(encoding="utf-8"))["aliases"])
        self.assertEqual(json.loads((sm_root / ".sert/.luaurc").read_text(encoding="utf-8"))["aliases"]["game"], "./stage/game")

    @unittest.skipUnless(have("luau"), "luau not on PATH")
    def test_directory_config_discovery_and_zero_return_line_preservation(self):
        root = self.project("", name="autodisc")
        copy_sert_src(root / ".sert/sert/src")
        (root / ".luaurc").write_text('{"aliases": {"sert": "./.sert/sert/src"}}\n', encoding="utf-8")
        self.write(
            root,
            {
                "test/OrderLog.luau": "return { items = {} :: { string } }\n",
                "test/.config.luau": 'local Log = require("./OrderLog")\ntable.insert(Log.items, "outer")\n',
                "test/sub/.config.luau": 'local Log = require("../OrderLog")\ntable.insert(Log.items, "inner")\n',
                "test/sub/Helper.luau": "return function(x: number) return x * 2 end\n",
                "test/sub/Order.spec.luau": (
                    "--!strict\n"
                    'local sert = require("@sert")\n'
                    'local Log = require("../OrderLog")\n'
                    'local helper = require("./Helper")\n'
                    'sert.test("setup order, roblox globals, and relative require", function()\n'
                    '\tsert.eq(table.concat(Log.items, ","), "outer,inner")\n'
                    "\tsert.eq(helper(21), 42)\n"
                    "\tsert.eq((Vector3 :: any).new(1, 2, 3).Y, 2)\n"
                    "end)\n"
                ),
            },
        )
        cfg = config.load(root)
        # Auto-discovers `test/**/*.spec.luau` with zero `[test]` table in sert.toml!
        entries = run_mod.resolve_entries(cfg, roblox_globals=True)
        self.assertEqual(entries, [".sert/run.luau"])
        res = run_mod.run_entries(cfg, entries, echo=False)
        self.assertEqual((res.status, res.counts["passed"]), (0, 1))

    def test_workspace_diagnostics_and_edges(self):
        cfg = config.load(self.project(""))
        kinds = {(n, line, m.split(":", 1)[0]): lint.is_lint(m) for n, line, m in lint.diagnostics(cfg, LSP_SAMPLE)}
        self.assertEqual(
            kinds,
            {
                ("p.luau", 1, "TypeError"): False,
                ("p.luau", 4, "TypeError"): False,
                ("p.luau", 2, "LocalUnused"): True,
                ("p.luau", 3, "DuplicateLocal"): True,
                ("p.luau", 7, "SameLineStatement"): True,
                ("p.luau", 7, "LocalShadow"): True,
                ("syn.luau", 2, "SyntaxError"): False,
                ("syn.luau", 2, "MultiLineStatement"): True,
            },
        )
        self.assertEqual(lint.error_lines(cfg, LSP_SAMPLE, errors_only=True), {"p.luau": {1, 4}, "syn.luau": {2}})

        self.fake_tools()
        rojo = self.write_fake_tool(
            self.tmp / "bin/rojo",
            "import pathlib\npathlib.Path(sys.argv[-1]).write_text('{}\\n', encoding='utf-8')\n",
        )
        r_ws = self.project('[lint]\nproject = "custom.project.json"\n', name="ana-1")
        (r_ws / "custom.project.json").write_text("{}\n")
        cfg_ws = config.load(r_ws)
        with lint.Workspace(cfg_ws, dry_run=False) as ws:
            self.assertTrue(ws.build_sourcemap()[1] and ws.sourcemap.is_file())
        self.write_fake_tool(rojo, "sys.stderr.write('rojo failed\\n')\nsys.exit(1)\n")
        with lint.Workspace(cfg_ws, dry_run=False) as ws:
            self.assertEqual((ws.build_sourcemap()[1], ws.sourcemap), (False, None))

    @unittest.skipUnless(shutil.which("luau-lsp") is not None, "luau-lsp not on PATH")
    def test_real_lsp_probe_and_github_annotations(self):
        rokit_toml = (REPO / "rokit.toml").read_text(encoding="utf-8")
        root = self.project('[types]\nfail = "t/fail"\nsolvers = ["new", "old"]\n[lint]\npaths = ["src"]\nproject = false\nsolvers = ["new"]\nstylua = false\nstub = false\n', name="real1")
        (root / "rokit.toml").write_text(rokit_toml, encoding="utf-8")
        (root / ".sert/types").mkdir(parents=True, exist_ok=True)
        (root / ".sert/types/globalTypes.d.luau").write_text("declare FIXTURE: number\n")
        self.write(root, {"t/fail/P.luau": '--!strict\nlocal unused = 1\nlocal x: number = "s" -- expect-error\n'})
        code, out, err = self.sert("lint", "--only", "types", "--root", root)
        self.assertEqual((code, "0 clean and 1 failing probes hold under new and old" in out), (0, True), out + err)

        self.write(root, {"src/a.luau": '--!strict\nlocal unused = 1\nlocal n: number = "s"\nreturn n\n'})
        self.setenv("GITHUB_ACTIONS", "true")
        code2, out2, _ = self.sert("lint", "--only", "analyze", "--root", root)
        self.assertEqual((code2, "::warning file=src/a.luau,line=2," in out2, "::error file=src/a.luau,line=3," in out2), (1, True, True))


if __name__ == "__main__":
    unittest.main()
