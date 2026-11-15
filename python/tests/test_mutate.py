"""Unit and end-to-end tests for `sert mutate`: token-stream mutator, blind-spot coverage, corruption regressions, zero-copy overlay, and TIMEOUT isolation."""

from __future__ import annotations

import contextlib
import io
import json
import os
import shutil
import subprocess
import sys
import unittest
from unittest import mock

from helpers import REPO, Case, copy_sert_src, have
from sert import cli, mutate
from sert.util import SertError


class MutateSchemaTest(Case):
    def test_operators_and_line_preservation(self):
        source = "\n".join(
            [
                "local M = {}",
                "function M.check(user, x, y)",
                "\tif x == y then",
                "\t\treturn true",
                "\telseif x < y then",
                "\t\treturn false",
                "\tend",
                "\tlocal ok = x >= 10",
                "\tuser.Verified = true",
                "\ttable.insert(user.Logs, ok)",
                "\tuser:Kick('bye')",
                "\treturn x + y",
                "end",
                "return M",
            ]
        )
        inst, mutants = mutate.instrument_source(source, {i: True for i in range(1, 15)}, file_path="src/M.luau")
        self.assertEqual(len(inst.splitlines()), len(source.splitlines()))
        # Zero `getfenv` / `setfenv` anywhere in generated code!
        self.assertNotIn("getfenv", inst)
        self.assertNotIn("setfenv", inst)
        self.assertNotIn("getfenv", mutate._direct_source(inst))
        self.assertNotIn("setfenv", mutate.wrap_staged_source(inst))

        ops: dict[int, list[str]] = {}
        for m in mutants:
            ops.setdefault(m.line, []).append(m.op)
        self.assertEqual(
            ops,
            {
                3: ["cond_inv"],
                4: ["ret_val"],
                5: ["cond_inv", "rel_flip"],
                6: ["ret_val"],
                8: ["rel_flip"],
                9: ["stmt_del"],
                10: ["stmt_del"],
                11: ["stmt_del"],
                12: ["arith_op", "ret_val"],
            },
        )

        src2 = "\n".join(
            [
                "--!strict",
                "export type Foo = {",
                "\tx: number,",
                "}",
                "--[[",
                "\treturn true",
                "]]",
                "local text = [[",
                "\treturn false",
                "]]",
                "local function f(a: any)",
                "\tlocal casted = (a :: any).value",
                "\tlocal tbl = {",
                "\t\ta:Method(),",
                "\t}",
                "\ta.Uncovered = 1",
                "\ta.Covered = 2 -- trailing comment",
                "\treturn true",
                "end",
                "return f",
            ]
        )
        inst2, muts2 = mutate.instrument_source(src2, {i: (i not in (16, 18)) for i in range(1, 21)}, file_path="src/F.luau")
        self.assertEqual((len(inst2.splitlines()), [(m.line, m.op) for m in muts2]), (len(src2.splitlines()), [(17, "stmt_del")]))
        self.assertIn("then a.Covered = 2 end", inst2.splitlines()[16])

    def test_blind_spots_eliminated_and_corruption_regressions_prevented(self):
        # 1. All former blind spots MUST generate mutants:
        #    - `--!strict` typed locals (`local x: number = a + b`)
        #    - `const` bindings (`const limit: number = a + b`)
        #    - `::` type casts (`local v = (a :: number) + 1`)
        #    - compound assignments (`+=` <-> `-=`, `*=` <-> `/=`)
        #    - `while` and `until` conditions
        #    - multi-return expressions (`return a + b, c`)
        #    - lines with trailing `--` comments
        #    - expressions inside single-line & multi-line anonymous closures/callbacks
        blind_spot_src = "\n".join(
            [
                "--!strict",
                "local M = {}",
                "function M.compute(a: number, b: number, items: { number })",
                "\tlocal typedSum: number = a + b -- trailing comment on typed local",
                "\tconst fixedLimit: number = a * b",
                "\tlocal casted = (a :: number) + 1",
                "\ttypedSum += 2",
                "\ttypedSum *= 3",
                "\twhile typedSum < fixedLimit do",
                "\t\ttypedSum += 1",
                "\tend",
                "\trepeat",
                "\t\ttypedSum -= 1",
                "\tuntil typedSum <= casted",
                "\ttable.sort(items, function(x: number, y: number) return x < y end)",
                "\tlocal mapped = (function()",
                "\t\treturn a + b",
                "\tend)()",
                "\treturn typedSum + mapped, items -- multi-return with trailing comment",
                "end",
                "return M",
            ]
        )
        inst_bs, muts_bs = mutate.instrument_source(blind_spot_src, set(range(1, 22)), file_path="src/Blind.luau")
        self.assertEqual(len(inst_bs.splitlines()), len(blind_spot_src.splitlines()))
        by_line: dict[int, list[mutate.Mutant]] = {}
        for m in muts_bs:
            by_line.setdefault(m.line, []).append(m)

        self.assertTrue(any(m.op == "arith_op" and "a - b" in m.mutated for m in by_line[4]))
        self.assertTrue(any(m.op == "arith_op" and "a / b" in m.mutated for m in by_line[5]))
        self.assertTrue(any(m.op == "arith_op" and "(a :: number) - 1" in m.mutated for m in by_line[6]))
        self.assertTrue(any(m.op == "arith_op" and "typedSum -= 2" in m.mutated for m in by_line[7]))
        self.assertTrue(any(m.op == "arith_op" and "typedSum /= 3" in m.mutated for m in by_line[8]))
        self.assertTrue(any(m.op == "cond_inv" for m in by_line[9]) and any(m.op == "rel_flip" for m in by_line[9]))
        self.assertTrue(any(m.op == "cond_inv" for m in by_line[14]) and any(m.op == "rel_flip" for m in by_line[14]))
        self.assertTrue(any(m.op == "rel_flip" and "return x > y" in m.mutated for m in by_line[15]))
        self.assertTrue(any(m.op == "arith_op" and "return a - b" in m.mutated for m in by_line[17]))
        self.assertTrue(any(m.op == "arith_op" and "typedSum - mapped" in m.mutated for m in by_line[19]))

        # 2. Corruption regressions MUST NEVER occur:
        #    - Multi-line table/string calls (`Builder\n{ count = 1 }`, `fmt\n"hello"`) never wrapped with `stmt_del` on line 1
        #    - `[[]]` raw strings inside backtick interpolations never corrupted
        #    - Generic calls `id<number>(x)` and generic declarations `function id<T>(x: T)` never flipped as `<` / `>`!
        tricky_src = "\n".join(
            [
                "--!strict",
                "local function id<T>(v: T): T",
                "\treturn v",
                "end",
                "local function Builder(t: any) return t end",
                "local function fmt(s: string) return s end",
                "local M = {}",
                "function M.run(x: number)",
                "\tBuilder",
                "\t\t{ count = 1 }",
                "\tfmt",
                '\t\t"hello"',
                "\tlocal s = `outer { [[raw < > + ` str]] } { id<number>(x) }`",
                "\tlocal g = id<number>(x)",
                "\treturn g + 1",
                "end",
                "return M",
            ]
        )
        inst_tricky, muts_tricky = mutate.instrument_source(tricky_src, set(range(1, 18)), file_path="src/Tricky.luau")
        self.assertEqual(len(inst_tricky.splitlines()), len(tricky_src.splitlines()))
        # Lines 2, 9, 11, 13, 14 must NOT have bogus rel_flip or broken multi-line call stmt_del
        self.assertFalse(any(m.line in (2, 9, 11, 13, 14) for m in muts_tricky), [(m.line, m.op, m.mutated) for m in muts_tricky])
        self.assertTrue(any(m.line == 15 and m.op == "arith_op" for m in muts_tricky))

        luau_bin = shutil.which("luau")
        if luau_bin:
            for idx, candidate in enumerate((mutate._direct_source(inst_bs), mutate._direct_source(inst_tricky))):
                p = self.tmp / f"valid_{idx}.luau"
                p.write_text(candidate, encoding="utf-8")
                cp = subprocess.run([luau_bin, str(p)], capture_output=True)
                self.assertEqual(cp.returncode, 0, cp.stderr.decode("utf-8", errors="replace"))

    def test_validation_edges_timeout_separation_and_batch_evaluation(self):
        custom_src = (
            "local M = {}\nfunction M.run(obj)\n\tMyFramework.cleanup(obj)\n"
            "\tUtil.Defer.wait()\n\tobj.CustomThemeTint = 1\n\tobj.RealState = 2\nend\nreturn M"
        )
        self.assertEqual([m.line for m in mutate.instrument_source(custom_src, set(range(1, 9)))[1]], [3, 5, 6])
        self.assertEqual(
            [m.line for m in mutate.instrument_source(custom_src, set(range(1, 9)), benign_calls=[r"MyFramework\.cleanup"], cosmetic_props=["CustomThemeTint"])[1]],
            [6],
        )

        for toml, flags, want in (
            ("[test]\nentries = []\n", (), "nothing to run:"),
            ('[test]\nentries = ["test/spec.luau"]\nrunner = "invalid"\n', (), "[test].runner must be one of"),
            ('[test]\nentries = ["test/spec.luau"]\n', ("--operators", "stmt_del,bogus_op"), "mutate: unknown operators bogus_op"),
            ('[test]\nentries = ["test/spec.luau"]\n', ("--no-coverage-run", "--coverage-file", "missing_cov.out"), "file not found"),
            ('[test]\nentries = ["test/spec.luau"]\nrunner = "lute"\n', (), '--coverage requires runner = "luau"'),
            ('[test]\nentries = ["test/spec.luau"]\n', (), "[test].entries: test/spec.luau not found"),
        ):
            r = self.project(toml, name=f"v{len(want)}")
            code, _, err = self.sert("mutate", "--root", r, *flags)
            self.assertEqual((code, want in err), (2, True), (want, err))

        # Verify TIMEOUT is classified separately from DETECTED so CPU contention NEVER inflates mutation score!
        # 1 KILLED + 1 TIMEOUT + 2 SURVIVED => 1 / (1 + 2) = 33.333% (NOT 2/4 = 50%!)
        muts = [
            mutate.Mutant(id=1, file="src/A.luau", line=10, op="stmt_del", original="a.x = 1", mutated="--", status="KILLED"),
            mutate.Mutant(id=2, file="src/A.luau", line=11, op="ret_val", original="return true", mutated="return false", status="TIMEOUT"),
            mutate.Mutant(id=3, file="src/A.luau", line=12, op="stmt_del", original="a.y = 2", mutated="--", status="SURVIVED"),
            mutate.Mutant(id=4, file="src/A.luau", line=13, op="stmt_del", original="a.z = 3", mutated="--", status="SURVIVED"),
        ]
        buf = io.StringIO()
        self.assertAlmostEqual(mutate.summarize(muts, out=buf, max_survived=1), 100.0 / 3.0)
        self.assertIn("Timed-out mutants (1, excluded from score):", buf.getvalue())
        self.assertTrue("Surviving mutants (2):" in buf.getvalue() and "... and 1 more" in buf.getvalue())

        # Verify batch evaluation retries a timed-out head mutant standalone before marking TIMEOUT!
        m1, m2, m3 = [
            mutate.Mutant(id=i, file="src/A.luau", line=i + 2, op="stmt_del", original="x=1", mutated="--", spec_filter="Spec")
            for i in (1, 2, 3)
        ]
        with mock.patch(
            "sert.mutate._run_process",
            side_effect=[
                # Batch stalls on m2 after m1=KILLED
                subprocess.TimeoutExpired(cmd=["luau"], timeout=5.0, output=b"[sert-mutant] 1=KILLED\n"),
                # Standalone retry of m2 succeeds (`exit 1` -> KILLED under CPU contention recovery!)
                subprocess.CompletedProcess(["luau"], 1, "", ""),
                # Remaining tail [m3] completes
                subprocess.CompletedProcess(["luau"], 0, "", ""),
            ],
        ) as run_mock:
            mutate._evaluate_mutant_batch([m1, m2, m3], self.tmp, "luau", "luau", ["test/spec.luau"], 1.0)
            self.assertEqual(len(run_mock.call_args_list), 3)
        self.assertEqual((m1.status, m2.status, m3.status), ("KILLED", "KILLED", "SURVIVED"))

    def test_paths_overlay_and_guard_inside(self):
        root = self.tmp / "proj"
        (root / "src").mkdir(parents=True)
        absolute = str((root / "src/A.luau").resolve())
        self.assertEqual(mutate.coverage_rel_path(absolute, root), "src/A.luau")
        self.assertEqual(mutate.coverage_rel_path(str((root / ".sert/stage/lexical/src/A.luau").resolve()), root), "src/A.luau")
        self.assertEqual(mutate.coverage_rel_path("src/sub/../A.luau", root), "src/A.luau")
        for bad in (str((self.tmp / "elsewhere/A.luau").resolve()), "../outside/A.luau", "src/../../outside/A.luau", str(root.resolve())):
            self.assertIsNone(mutate.coverage_rel_path(bad, root))

        err = io.StringIO()
        with contextlib.redirect_stderr(err):
            merged = mutate.root_relative_coverage(
                {absolute: {1: True, 2: False}, "src/A.luau": {2: True}, "/elsewhere/B.luau": {1: True}},
                root,
            )
        self.assertEqual((merged, "outside the project root: /elsewhere/B.luau" in err.getvalue()), ({"src/A.luau": {1: True, 2: True}}, True))

        wdir, real = self.tmp / "work", self.tmp / "real"
        (wdir / "src").mkdir(parents=True)
        real.mkdir()
        (real / "A.luau").write_text("return 1\n")
        self.assertEqual(mutate._guard_inside(wdir, wdir / "src/A.luau"), wdir / "src/A.luau")
        for bad_target in (wdir / str((real / "A.luau").resolve()), wdir / "src/../../real/A.luau", wdir):
            with self.assertRaisesRegex(SertError, r"outside the mutation overlay"):
                mutate._guard_inside(wdir, bad_target)
        if hasattr(os, "symlink"):
            os.symlink(real, wdir / "linked", target_is_directory=True)
            with self.assertRaisesRegex(SertError, r"outside the mutation overlay"):
                mutate._guard_inside(wdir, wdir / "linked/A.luau")

    def _alias_project(self, toml: str, target_src: str, spec_body: list[str], name: str = "alias"):
        root = self.project(toml, name=name)
        copy_sert_src(root / ".sert/repo/src")
        (root / ".luaurc").write_text('{"aliases": {"sert": "./.sert/repo/src", "lib": "./src"}}\n')
        (root / "src").mkdir(parents=True, exist_ok=True)
        (root / "src/Target.luau").write_text(target_src)
        (root / "test").mkdir(parents=True, exist_ok=True)
        (root / "test/spec.luau").write_text(
            "\n".join(['local sert = require("@sert")', 'local Target = require("@lib/Target")', "", *spec_body, "", "return sert.run(sert.parseCliArgs(...))", ""])
        )
        return root

    @unittest.skipUnless(have("luau"), "luau CLI required")
    def test_end_to_end_mutate_flows_and_multi_spec_batching(self):
        orig = "local M = {}\nfunction M.f(state)\n\tstate.valid = true\n\tstate.broken = true\n\treturn true\nend\nreturn M"
        inst, muts = mutate.instrument_source(orig, {1, 2, 3, 4, 5, 6, 7}, file_path="src/M.luau")
        inst_lines = inst.split("\n")
        inst_lines[3] = "\tif (( then state.broken = true end"
        corrupted = "\n".join(inst_lines)
        staged_w = self.tmp / "wrapped/M.luau"
        self.assertEqual([m.line for m in mutate.compile_and_stage_file("luau", orig, corrupted, muts, staged_w, wrap=True)], [3, 5])
        self.assertIn("return function(_ENV: any, ...: any): ...any", staged_w.read_text())
        self.assertNotIn("setfenv", staged_w.read_text())
        self.assertNotIn("getfenv", staged_w.read_text())

        target_src = "local Target = {}\nfunction Target.apply(state)\n\tstate.asserted = true\n\tstate.unasserted = true\n\treturn true\nend\nreturn Target\n"
        # Auto-discovered multi-spec project (0-return specs!) using `--mutants` batching!
        mroot = self.project('[coverage]\ninclude = ["src"]\n[mutate]\ninclude = ["src"]\noperators = ["stmt_del"]\n', name="multispec")
        copy_sert_src(mroot / ".sert/sert/src")
        (mroot / ".luaurc").write_text('{"aliases": {"sert": "./.sert/sert/src", "lib": "./src"}}\n')
        (mroot / "src").mkdir()
        (mroot / "src/Target.luau").write_text('local ZHelper = require("./ZHelper")\n' + target_src.replace("return true", "return ZHelper.ok()"))
        (mroot / "src/ZHelper.luau").write_text("local ZHelper = {}\nfunction ZHelper.ok()\n\treturn true\nend\nreturn ZHelper\n")
        (mroot / "test").mkdir()
        (mroot / "test/A.spec.luau").write_text(
            'local sert = require("@sert")\nlocal Target = require("@lib/Target")\n'
            'sert.test("asserts first field", function()\n\tlocal s = { asserted = false, unasserted = false }\n\tTarget.apply(s)\n\tsert.eq(s.asserted, true)\nend)\n'
        )
        (mroot / "test/B.spec.luau").write_text(
            'local sert = require("@sert")\nlocal Target = require("@lib/Target")\n'
            'sert.test("returns true", function()\n\tsert.eq(Target.apply({}), true)\nend)\n'
        )
        code, out, err = self.sert("mutate", "--root", mroot, "-j", "1")
        self.assertEqual((code, out.strip(), (mroot / ".sert/mutate/overlay").exists()), (0, "50.0", False), err)
        code_cap, out_cap, err_cap = self.sert("mutate", "--root", mroot, "--no-coverage-run", "--max-mutants", "1", "-j", "1")
        self.assertEqual((code_cap, out_cap.strip()), (0, "100.0"), err_cap)

        # Typed Lexical Staging project (`[test].stage`)
        sroot = self.project(
            '[test]\nentries = ["test/spec.client.luau"]\nstage = "default.project.json"\n'
            '[coverage]\ninclude = ["src"]\n[mutate]\ninclude = ["src"]\n[mutate.specs]\n"src/Target.luau" = "Target"\n',
            name="staged",
        )
        copy_sert_src(sroot / ".sert/repo/src")
        (sroot / ".luaurc").write_text('{"aliases": {"sert": "./.sert/repo/src", "stage": "./.sert/stage"}}\n')
        (sroot / "default.project.json").write_text('{"name": "MutateFixture", "tree": {"$path": "src"}}\n')
        (sroot / "src").mkdir()
        (sroot / "src/Target.luau").write_text(target_src)
        (sroot / "test").mkdir()
        (sroot / "test/spec.client.luau").write_text(
            "\n".join(
                [
                    'local sert = require("@sert")',
                    'local stage = require("@stage")',
                    'sert.test("Target", function()',
                    "\tlocal env = sert.env.new()",
                    "\tlocal Target = env:require(env:mount(stage):WaitForChild('Target'))",
                    "\tlocal state = {}",
                    "\tsert.eq(Target.apply(state), true)",
                    "\tsert.eq(state.asserted, true)",
                    "end)",
                    "return sert.run(sert.parseCliArgs(...))",
                ]
            )
        )
        code_s, out_s, err_s = self.sert("mutate", "--root", sroot, "-j", "2")
        self.assertEqual((code_s, out_s.strip(), "__SERT_MUTANT" in (sroot / ".sert/stage/lexical/src/Target.luau").read_text()), (0, "66.7", False), err_s)

    def test_cli_flags_and_commands(self):
        done = subprocess.run(
            [sys.executable, "-m", "sert", "mutate", "--help"],
            capture_output=True,
            text=True,
            env=dict(os.environ, PYTHONPATH=str(REPO / "python"), COLUMNS="200"),
        )
        self.assertEqual(done.returncode, 0)
        normalized_help = " ".join(done.stdout.split())
        for want in ("mutation testing", "stmt_del,ret_val,cond_inv,rel_flip,arith_op,logic_op,math_fn", "-a ..."):
            self.assertIn(want, normalized_help)
        args = cli.build(["mutate"]).parse_args(["mutate", "src", "-a", "Target", "--seed", "3"])
        self.assertEqual((args.paths, args.program_args), (["src"], ["Target", "--seed", "3"]))
        self.assertEqual(mutate._mutant_command("luau", "luau", "test/spec.luau", 4, "Spec", program_args=["Mine", "--seed=3"])[-3:], ["Mine", "--seed=3", "--mutant=4:Spec"])
        self.assertEqual(mutate._mutant_batch_command("luau", "luau", "test/spec.luau", [1, 2], None, program_args=["Mine"])[-2:], ["Mine", "--mutants=1,2"])
        self.assertEqual(mutate._mutant_command("luau", "luau", "e.luau", 1, None)[-2:], ["-a", "--mutant=1"])

    def test_new_operators_off_by_one_nil_guard_remote_guard(self):
        for op in ("off_by_one", "nil_guard", "remote_guard"):
            self.assertIn(op, mutate.ALL_OPERATORS)

        source = "\n".join(
            [
                "--!strict",
                "local M = {}",
                "function M.work(items: { number }, opts: { limit: number? }, flag: boolean, remote: any)",
                "\tlocal count = #items",
                "\tlocal limit = opts.limit or 10",
                "\tlocal total = 0",
                "\tfor i = 1, #items do",
                "\t\ttotal += items[i]",
                "\tend",
                "\tif flag or total > 0 then",
                "\t\ttotal += 1",
                "\tend",
                "\tif typeof(remote) ~= \"nil\" then",
                "\t\tremote.OnServerEvent:Connect(function(_player, payload)",
                "\t\t\tif typeof(payload) ~= \"string\" then",
                "\t\t\t\treturn",
                "\t\t\tend",
                "\t\t\tif type(payload) == \"string\" then",
                "\t\t\t\ttotal += #payload",
                "\t\t\tend",
                "\t\tend)",
                "\t\tremote.OnServerInvoke = function(_player, req)",
                "\t\t\tlocal bad = \"number\" ~= type(req)",
                "\t\t\treturn req or 0",
                "\t\tend",
                "\tend",
                "\treturn limit or total",
                "end",
                "return M",
            ]
        )
        inst, mutants = mutate.instrument_source(
            source,
            {i: True for i in range(1, 35)},
            file_path="src/Handlers.luau",
            operators=("off_by_one", "nil_guard", "remote_guard"),
        )
        self.assertEqual(len(inst.splitlines()), len(source.splitlines()))
        by_op: dict[str, list[tuple[int, str]]] = {"off_by_one": [], "nil_guard": [], "remote_guard": []}
        for m in mutants:
            by_op.setdefault(m.op, []).append((m.line, m.mutated))

        # off_by_one: `#items` -> `(#items - 1)` and `for i = 1, #items do` -> `for i = 1, #items - 1 do`
        self.assertIn((4, "local count = (#items - 1)"), by_op["off_by_one"])
        self.assertIn((7, "for i = 1, #items - 1 do"), by_op["off_by_one"])
        self.assertIn((19, "total += (#payload - 1)"), by_op["off_by_one"])

        # nil_guard: assignment RHS and return only, skipping boolean `if flag or total > 0 then`
        self.assertIn((5, "local limit = opts.limit"), by_op["nil_guard"])
        self.assertIn((24, "return req"), by_op["nil_guard"])
        self.assertIn((27, "return limit"), by_op["nil_guard"])
        self.assertFalse(any(line == 10 for line, _ in by_op["nil_guard"]))

        # remote_guard: inside OnServerEvent:Connect and OnServerInvoke only, NOT line 13 outside!
        self.assertFalse(any(line == 13 for line, _ in by_op["remote_guard"]))
        self.assertIn((15, "if false then"), by_op["remote_guard"])
        self.assertIn((18, "if true then"), by_op["remote_guard"])
        self.assertIn((23, "local bad = false"), by_op["remote_guard"])

        if have("luau"):
            staged = self.tmp / "Handlers.staged.luau"
            compiled = mutate.compile_and_stage_file("luau", source, inst, mutants, staged, wrap=False)
            self.assertEqual(len(compiled), len(mutants))

    @unittest.skipUnless(have("luau"), "luau not fetched or on PATH")
    def test_zero_config_routing_fast_first_and_short_circuit(self):
        root = self.project(
            '[test]\nspecs = ["test/**/*.spec.luau"]\n[coverage]\ninclude = ["src"]\n[mutate]\ninclude = ["src"]\n',
            name="routing",
        )
        copy_sert_src(root / ".sert/repo/src")
        (root / ".luaurc").write_text('{"aliases": {"sert": "./.sert/repo/src", "lib": "./src"}}\n')
        (root / "src").mkdir()
        (root / "src/Calc.luau").write_text(
            "\n".join(
                [
                    "local Calc = {}",
                    "function Calc.add(a: number, b: number): number",
                    "\treturn a + b",
                    "end",
                    "function Calc.onlySlow(x: number): number",
                    "\treturn x * 2",
                    "end",
                    "return Calc",
                ]
            )
            + "\n"
        )
        (root / "test").mkdir()
        (root / "test/fast.spec.luau").write_text(
            "\n".join(
                [
                    'local sert = require("@sert")',
                    'local Calc = require("@lib/Calc")',
                    'sert.test("add fast", function()',
                    "\tsert.eq(Calc.add(2, 3), 5)",
                    "end)",
                    "return {}",
                ]
            )
            + "\n"
        )
        (root / "test/slow.spec.luau").write_text(
            "\n".join(
                [
                    'local sert = require("@sert")',
                    'local Calc = require("@lib/Calc")',
                    'sert.test("calc slow", function()',
                    "\tsert.eq(Calc.add(4, 5), 9)",
                    "\tsert.eq(Calc.onlySlow(3), 6)",
                    "end)",
                    "return {}",
                ]
            )
            + "\n"
        )
        # Seed coverage-map.json where fast (5ms) + slow (500ms) both cover line 3, and only slow covers line 6
        (root / ".sert/coverage-map.json").write_text(
            json.dumps(
                {
                    "version": 1,
                    "specs": {
                        "test/fast.spec.luau": {"ms": 5, "files": {"src/Calc.luau": [3]}},
                        "test/slow.spec.luau": {"ms": 500, "files": {"src/Calc.luau": [3, 6]}},
                    },
                }
            )
        )
        (root / "coverage.out").write_text("SF:src/Calc.luau\nDA:3,1\nDA:6,1\nend_of_record\n")

        observed_calls: list[list[str]] = []
        orig_eval_batch = mutate._evaluate_mutant_batch
        orig_eval_one = mutate._evaluate_one_mutant

        def spy_batch(batch, *args, **kwargs):
            for m in batch:
                observed_calls.append([str(m.id), str(m.line), m.spec_filter or "", ",".join(m.covering_specs)])
            return orig_eval_batch(batch, *args, **kwargs)

        def spy_one(mutant, *args, **kwargs):
            observed_calls.append([str(mutant.id), str(mutant.line), mutant.spec_filter or "", ",".join(mutant.covering_specs)])
            return orig_eval_one(mutant, *args, **kwargs)

        with (
            mock.patch.object(mutate, "_evaluate_mutant_batch", side_effect=spy_batch),
            mock.patch.object(mutate, "_evaluate_one_mutant", side_effect=spy_one),
        ):
            code, out, err = self.sert("mutate", "--root", root, "--no-coverage-run", "--operators", "arith_op", "-j", "1")
        self.assertEqual((code, out.strip()), (0, "100.0"), err)

        # Mutant on line 3 (`Calc.add`) has covering_specs = ("test/fast.spec.luau", "test/slow.spec.luau"):
        # `fast` (5ms) runs first, kills it, and short-circuits (`slow` NEVER runs for line 3!).
        # Mutant on line 6 (`Calc.onlySlow`) is ordered fastest-first too, survives `fast`, and falls through to `slow` (500ms).
        line3_filters = [filt for _id, ln, filt, _cov in observed_calls if ln == "3"]
        self.assertTrue(any(f == "@file=test/fast.spec.luau" for f in line3_filters), observed_calls)
        self.assertFalse(any(f == "@file=test/slow.spec.luau" for f in line3_filters), observed_calls)
        line6_filters = [filt for _id, ln, filt, _cov in observed_calls if ln == "6"]
        self.assertIn("@file=test/fast.spec.luau", line6_filters, observed_calls)
        self.assertIn("@file=test/slow.spec.luau", line6_filters, observed_calls)
        self.assertLess(
            line6_filters.index("@file=test/fast.spec.luau"),
            line6_filters.index("@file=test/slow.spec.luau"),
            observed_calls,
        )

    @unittest.skipUnless(have("luau"), "luau not fetched or on PATH")
    def test_incremental_cache_hit_invalidation_no_cache_and_formats(self):
        root = self.project(
            '[test]\nspecs = ["test/**/*.spec.luau"]\n[coverage]\ninclude = ["src"]\n[mutate]\ninclude = ["src"]\n',
            name="cacheproj",
        )
        copy_sert_src(root / ".sert/repo/src")
        (root / ".luaurc").write_text('{"aliases": {"sert": "./.sert/repo/src", "lib": "./src"}}\n')
        (root / "src").mkdir()
        target = root / "src/Math.luau"
        target.write_text(
            "\n".join(
                [
                    "local M = {}",
                    "function M.op(a: number, b: number): number",
                    "\treturn a + b",
                    "end",
                    "function M.untested(a: number): number",
                    "\treturn a + 1",
                    "end",
                    "return M",
                ]
            )
            + "\n"
        )
        (root / "test").mkdir()
        (root / "test/math.spec.luau").write_text(
            "\n".join(
                [
                    'local sert = require("@sert")',
                    'local M = require("@lib/Math")',
                    'sert.test("op", function()',
                    "\tsert.eq(M.op(2, 3), 5)",
                    "end)",
                    "return {}",
                ]
            )
            + "\n"
        )
        (root / "coverage.out").write_text("SF:src/Math.luau\nDA:3,1\nDA:6,1\nend_of_record\n")

        # 1. Cold run populates `.sert/mutate/cache.json` (1 killed, 1 survived => 50.0%)
        code1, out1, err1 = self.sert("mutate", "--root", root, "--no-coverage-run", "--operators", "arith_op", "-j", "1")
        self.assertEqual((code1, out1.strip()), (0, "50.0"), err1)
        cache_file = root / ".sert/mutate/cache.json"
        self.assertTrue(cache_file.is_file())
        cache_data = json.loads(cache_file.read_text())
        self.assertEqual(len(cache_data["entries"]), 2)

        # 2. Warm run + comment-only change reuses cache with ZERO process evaluations
        target.write_text(target.read_text() + "-- trailing comment preserves token digest\n")
        with (
            mock.patch.object(mutate, "_evaluate_mutant_batch", side_effect=AssertionError("should hit cache")),
            mock.patch.object(mutate, "_evaluate_one_mutant", side_effect=AssertionError("should hit cache")),
        ):
            code_agent, out_agent, err_agent = self.sert(
                "mutate", "--root", root, "--no-coverage-run", "--operators", "arith_op", "--agent"
            )
            self.assertEqual(code_agent, 0, err_agent)
            self.assertIn("FAIL mutation_score=50.0% killed=1 survived=1", out_agent)
            self.assertIn("SURVIVED", out_agent)

            code_json, out_json, err_json = self.sert(
                "mutate", "--root", root, "--no-coverage-run", "--operators", "arith_op", "--format", "json"
            )
            self.assertEqual(code_json, 0, err_json)
            env = json.loads(out_json)
            self.assertEqual((env["command"], env["status"], env["summary"]["score"], env["summary"]["cached"]), ("mutate", "ok", 50.0, 2))
            self.assertEqual(len(env["data"]["survived"]), 1)

        # 3. `--no-cache` forces fresh evaluation
        eval_calls = 0
        orig_eval_batch = mutate._evaluate_mutant_batch

        def count_batch(*args, **kwargs):
            nonlocal eval_calls
            eval_calls += 1
            return orig_eval_batch(*args, **kwargs)

        with mock.patch.object(mutate, "_evaluate_mutant_batch", side_effect=count_batch):
            code_nc, out_nc, err_nc = self.sert(
                "mutate", "--root", root, "--no-coverage-run", "--operators", "arith_op", "--no-cache", "-j", "1"
            )
        self.assertEqual((code_nc, out_nc.strip()), (0, "50.0"), err_nc)
        self.assertGreater(eval_calls, 0)

        # 4. Editing target code invalidates cache and re-evaluates cleanly
        target.write_text(target.read_text().replace("return a + 1", "return a * 2"))
        eval_calls2 = 0

        def count_batch2(*args, **kwargs):
            nonlocal eval_calls2
            eval_calls2 += 1
            return orig_eval_batch(*args, **kwargs)

        with mock.patch.object(mutate, "_evaluate_mutant_batch", side_effect=count_batch2):
            code_inv, out_inv, err_inv = self.sert(
                "mutate", "--root", root, "--no-coverage-run", "--operators", "arith_op", "-j", "1"
            )
        self.assertEqual((code_inv, out_inv.strip()), (0, "50.0"), err_inv)
        self.assertGreater(eval_calls2, 0)

        # 5. Editing a transitive helper required by a spec invalidates the cache
        (root / "src/Math.luau").write_text(
            "local M = {}\nfunction M.op(a: number, b: number): number\n\treturn a + b\nend\nreturn M\n"
        )
        (root / "test/helpers").mkdir(parents=True, exist_ok=True)
        leaf_helper = root / "test/helpers/val_leaf.luau"
        leaf_helper.write_text("return function(v: number): boolean\n\treturn v == 5\nend\n")
        (root / "test/helpers/expect_val.luau").write_text(
            'local checkLeaf = require("./val_leaf")\nreturn function(v: number): boolean\n\treturn checkLeaf(v)\nend\n'
        )
        (root / "test/math.spec.luau").write_text(
            "\n".join(
                [
                    'local sert = require("@sert")',
                    'local M = require("@lib/Math")',
                    'local expectVal = require("./helpers/expect_val")',
                    'sert.test("op", function()',
                    "\tsert.ok(expectVal(M.op(2, 3)))",
                    "end)",
                    "return {}",
                ]
            )
            + "\n"
        )
        (root / "coverage.out").write_text("SF:src/Math.luau\nDA:3,1\nend_of_record\n")

        code_cold, out_cold, err_cold = self.sert(
            "mutate", "--root", root, "--no-coverage-run", "--operators", "arith_op", "-j", "1"
        )
        self.assertEqual((code_cold, out_cold.strip()), (0, "100.0"), err_cold)

        with (
            mock.patch.object(mutate, "_evaluate_mutant_batch", side_effect=AssertionError("should hit cache")),
            mock.patch.object(mutate, "_evaluate_one_mutant", side_effect=AssertionError("should hit cache")),
        ):
            code_warm, out_warm, err_warm = self.sert(
                "mutate", "--root", root, "--no-coverage-run", "--operators", "arith_op", "-j", "1"
            )
        self.assertEqual((code_warm, out_warm.strip()), (0, "100.0"), err_warm)

        # Modify ONLY the 2-hop transitive helper so baseline stays green (5) while mutant (-1) now survives.
        leaf_helper.write_text("return function(v: number): boolean\n\treturn v == 5 or v == -1\nend\n")
        trans_eval_calls = 0

        def count_trans(*args, **kwargs):
            nonlocal trans_eval_calls
            trans_eval_calls += 1
            return orig_eval_batch(*args, **kwargs)

        with mock.patch.object(mutate, "_evaluate_mutant_batch", side_effect=count_trans):
            code_trans, out_trans, err_trans = self.sert(
                "mutate", "--root", root, "--no-coverage-run", "--operators", "arith_op", "-j", "1"
            )
        self.assertEqual((code_trans, out_trans.strip()), (0, "0.0"), err_trans)
        self.assertGreater(trans_eval_calls, 0)


if __name__ == "__main__":
    unittest.main()
