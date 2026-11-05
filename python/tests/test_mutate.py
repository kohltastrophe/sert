"""Unit and end-to-end tests for `sert mutate` (coverage-guided mutant schemata)."""

from __future__ import annotations
import contextlib, io, json, os, shutil, subprocess, sys, unittest
from unittest import mock

from helpers import REPO, Case, have
from sert import cli, mutate
from sert.util import SertError


class MutateSchemaTest(Case):
    def test_operators_and_line_preservation(self):
        source = "\n".join([
            "local M = {}", "function M.check(user, x, y)", "\tif x == y then", "\t\treturn true",
            "\telseif x < y then", "\t\treturn false", "\tend", "\tlocal ok = x >= 10",
            "\tuser.Verified = true", "\ttable.insert(user.Logs, ok)", "\tuser:Kick('bye')",
            "\treturn x + y", "end", "return M",
        ])
        inst, mutants = mutate.instrument_source(source, {i: True for i in range(1, 15)}, file_path="src/M.luau")
        self.assertEqual(len(inst.splitlines()), len(source.splitlines()))
        ops = {}
        for m in mutants:
            ops.setdefault(m.line, []).append(m.op)
        self.assertEqual(ops, {3: ["cond_inv"], 4: ["ret_val"], 5: ["cond_inv", "rel_flip"], 6: ["ret_val"],
                               8: ["rel_flip"], 9: ["stmt_del"], 10: ["stmt_del"], 11: ["stmt_del"], 12: ["ret_val"]})

        src2 = "\n".join([
            "--!strict", "export type Foo = {", "\tx: number,", "}", "--[[", "\treturn true", "]]",
            "local text = [[", "\treturn false", "]]", "local function f(a: any)", "\tlocal casted = (a :: any).value",
            "\tlocal tbl = {", "\t\ta:Method(),", "\t}", "\ta.Uncovered = 1", "\ta.Covered = 2 -- trailing comment",
            "\treturn true", "end", "return f",
        ])
        inst2, muts2 = mutate.instrument_source(src2, {i: (i not in (16, 18)) for i in range(1, 21)}, file_path="src/F.luau")
        self.assertEqual((len(inst2.splitlines()), [(m.line, m.op) for m in muts2]), (len(src2.splitlines()), [(17, "stmt_del")]))
        self.assertTrue(inst2.splitlines()[16].endswith("then a.Covered = 2 end"))

        src3 = "\n".join([
            "return function(state)", '\tlocal label = `tag {fmt("`")}`',
            "\tlocal mode = if state.a then if state.b then 1 else 2 else 3",
            "\tlocal nextMode = if state.a then", "\t\tif state.b then 1 else 2", "\telse 3",
            "\tstate.updated = true", "\treturn true", "end",
        ])
        self.assertFalse(any(mutate.scan_lines(src3, keep_strings=True)[2]))
        _, muts3 = mutate.instrument_source(src3, {i: True for i in range(1, 10)}, file_path="src/Factory.luau")
        self.assertEqual([(m.line, m.op) for m in muts3], [(7, "stmt_del"), (8, "ret_val")])

        src4 = "\n".join([
            "local M = {}", "function M.run(state, items)", "\tif (if state.mode then state.a else state.b) then",
            "\t\tstate.in_if = true", "\t\tstate.in_if_done = true", "\telse", "\t\tif state.fallback then",
            "\t\t\tstate.in_else_if = true", "\t\tend", "\tend", "\tfor _, v in items do", "\t\tstate.loop_body = v",
            "\tend", "\trepeat", "\t\tstate.repeated = true", "\tuntil true", '\tstate["k=1"].flag = state.x < 10',
            "\treturn true", "end", "return M",
        ])
        _, muts4 = mutate.instrument_source(src4, {i: True for i in range(1, 21)}, file_path="src/M.luau")
        by_line = {}
        for m in muts4:
            by_line.setdefault(m.line, []).append(m)
        for ln in (4, 7, 8, 12, 15, 17, 18):
            self.assertIn(ln, by_line)
        self.assertNotIn(20, by_line)
        self.assertEqual([m.mutated for m in by_line[17] if m.op == "rel_flip"], ['state["k=1"].flag = state.x > 10'])

        src5 = "\n".join([
            "local M = {}",
            "function M.run(state)",
            "\tlocal msg = `outer {`inner {state.x}`} {-- comment with }`\n\t\tstate.y} {--[[long }`]] state.z}`",
            "\tif state.a then",
            "\t\tstate.branch = 1",
            "\telse if state.b then",
            "\t\tstate.branch = 2",
            "\t\tend",
            "\tend",
            "\treturn true",
            "end",
            "return M",
        ])
        clean5, mask5, multi5 = mutate.scan_lines(src5, keep_strings=True)
        self.assertTrue("comment with" not in clean5[2] and "long" not in clean5[3] and multi5[2] and multi5[3] and not multi5[4])
        _, muts5 = mutate.instrument_source(src5, set(range(1, 13)), file_path="src/M5.luau")
        self.assertEqual([m.line for m in muts5 if m.op == "ret_val"], [11])
        self.assertNotIn(13, [m.line for m in muts5])

    def test_validation_edges_and_batch_evaluation(self):
        custom_src = "local M = {}\nfunction M.run(obj)\n\tMyFramework.cleanup(obj)\n\tUtil.Defer.wait()\n\tobj.CustomThemeTint = 1\n\tobj.RealState = 2\nend\nreturn M"
        self.assertEqual([m.line for m in mutate.instrument_source(custom_src, set(range(1, 9)))[1]], [3, 5, 6])
        self.assertEqual([m.line for m in mutate.instrument_source(custom_src, set(range(1, 9)), benign_calls=[r"MyFramework\.cleanup"], cosmetic_props=["CustomThemeTint"])[1]], [6])

        for toml, flags, want in (
            ("[test]\nentries = []\n", (), "nothing to run: set [test].entries or [test].specs"),
            ('[test]\nentries = ["test/spec.luau"]\nrunner = "invalid"\n', (), "[test].runner must be one of"),
            ('[test]\nentries = ["test/spec.luau"]\n', ("--operators", "stmt_del,bogus_op"), "mutate: unknown operators bogus_op"),
            ('[test]\nentries = ["test/spec.luau"]\n', ("--no-coverage-run", "--coverage-file", "missing_cov.out"), "file not found"),
            ('[test]\nentries = ["test/spec.luau"]\nrunner = "lute"\n', (), '--coverage needs [test].runner = "luau"'),
            ('[test]\nentries = ["test/spec.luau"]\n', (), "[test].entries: test/spec.luau not found"),
        ):
            r = self.project(toml, name=f"v{len(want)}")
            code, _, err = self.sert("mutate", "--root", r, *flags)
            self.assertEqual((code, want in err), (2, True), err)

        r_cov = self.project('[test]\nentries = ["test/spec.luau"]\n', name="rcov")
        (r_cov / "coverage.out").write_text("SF:other/File.luau\nDA:1,1\nend_of_record\n")
        self.assertIn("no covered files under src", self.sert("mutate", "--root", r_cov, "--no-coverage-run")[2])
        (r_cov / "src").mkdir()
        (r_cov / "src/OnlyExport.luau").write_text("local M = {}\nfunction M.noop() end\nreturn M\n")
        (r_cov / "coverage.out").write_text("SF:src/OnlyExport.luau\nDA:1,1\nDA:2,1\nDA:3,1\nend_of_record\n")
        self.assertIn("no mutable covered statements", self.sert("mutate", "--root", r_cov, "--no-coverage-run")[2])

        prior_bytes = b"SF:src/Prior.luau\nDA:1,1\nend_of_record\n"
        (r_cov / "coverage.out").write_bytes(prior_bytes)
        custom_cov = "sub/dir/custom.out"
        new_cov = "SF:src/OnlyExport.luau\nDA:1,1\nDA:2,1\nDA:3,1\nend_of_record\n"
        with mock.patch("sert.mutate.run_mod.run_entries", side_effect=lambda cfg, *a, **kw: ((cfg.root / "coverage.out").write_text(new_cov), mock.MagicMock(status=0, entries=[]))[1]), \
             mock.patch("sert.mutate.run_mod.resolve_entries", return_value=["test/spec.luau"]), \
             mock.patch("sert.mutate.run_mod.luau_command", return_value="luau"):
            code_c, _, err_c = self.sert("mutate", "--root", r_cov, "--coverage-file", custom_cov)
        self.assertEqual((code_c, "no mutable covered statements" in err_c, (r_cov / custom_cov).read_text(), (r_cov / "coverage.out").read_bytes()), (2, True, new_cov, prior_bytes))

        self.assertEqual(mutate.scan_lines('local a = "hello \\\nworld"\nlocal b = "cr \\\r\nline \\"ok\\""\n', keep_strings=True)[2][:3], [True, True, True])
        src_edge = "local M = {}\nfunction M.edge(state, x, y)\n\tif x == y and state.ok then\n\t\treturn true, 'detail'\n\tend\n\tstate.count += 1\n\tstate.cmp = x < y\n\tif state.cmp then return x < y end\n\treturn nil\nend\nreturn M"
        _, muts_all = mutate.instrument_source(src_edge, set(range(1, 12)), file_path="src/Edge.luau")
        self.assertTrue(any(m.line == 4 and m.op == "ret_val" for m in muts_all) and any(m.line == 6 and m.op == "stmt_del" for m in muts_all) and not any(m.line == 9 for m in muts_all))
        self.assertEqual([(m.line, m.op, m.mutated) for m in mutate.instrument_source("local M = {}\nfunction M.f(x, y)\n\treturn x < y\nend\nreturn M\n", {1, 2, 3, 4, 5})[1]], [(3, "rel_flip", "return x > y")])
        inst_rel, muts_rel = mutate.instrument_source(src_edge, {7}, operators=("rel_flip",), max_mutants=1)
        self.assertEqual((len(muts_rel), muts_rel[0].op, "then state.cmp = x > y else state.cmp = x < y end" in inst_rel), (1, "rel_flip", True))

        specs = {"src": "All", "src/sub": "Sub", "src/sub/deep.luau": "Deep"}
        self.assertEqual([mutate.resolve_spec_filter(p, specs) for p in ("src/sub/deep.luau", "src/sub/other.luau", "src/top.luau", "other/file.luau")], ["Deep", "Sub", "All", None])
        with self.assertRaisesRegex(SertError, r"mutate: no mutants generated"):
            mutate.summarize([])
        muts = [
            mutate.Mutant(id=1, file="src/A.luau", line=10, op="stmt_del", original="a.x = 1", mutated="--", status="KILLED"),
            mutate.Mutant(id=2, file="src/A.luau", line=11, op="ret_val", original="return true", mutated="return false", status="TIMEOUT"),
            mutate.Mutant(id=3, file="src/A.luau", line=12, op="stmt_del", original="a.y = 2", mutated="--", status="SURVIVED"),
            mutate.Mutant(id=4, file="src/A.luau", line=13, op="stmt_del", original="a.z = 3", mutated="--", status="SURVIVED"),
        ]
        buf = io.StringIO()
        self.assertAlmostEqual(mutate.summarize(muts, out=buf, max_survived=1), 50.0)
        self.assertTrue("Surviving mutants (2):" in buf.getvalue() and "... and 1 more" in buf.getvalue())

        m1, m2, m3, m4_tail = [mutate.Mutant(id=i, file="src/A.luau", line=i + 2, op="stmt_del", original="x=1", mutated="--", spec_filter="Spec") for i in (1, 2, 3, 4)]
        with mock.patch("sert.mutate._run_process", side_effect=[
            subprocess.TimeoutExpired(cmd=["luau"], timeout=5.0, output=b"[sert-mutant] 1=KILLED\n"),
            subprocess.TimeoutExpired(cmd=["luau"], timeout=1.0),
            subprocess.CompletedProcess(["luau"], 0, "[sert-mutant] 3=SURVIVED\n[sert-mutant] 4=KILLED\n", ""),
        ]) as run_mock:
            mutate._evaluate_mutant_batch([m1, m2, m3, m4_tail], self.tmp, "luau", "luau", ["test/spec.luau"], 1.0)
            self.assertEqual(run_mock.call_args_list[0].kwargs["timeout"], 4.0)
            self.assertEqual(run_mock.call_args_list[0].kwargs["step_timeout"], 1.0)
            self.assertEqual(len(run_mock.call_args_list), 3)
        self.assertEqual((m1.status, m2.status, m3.status, m4_tail.status), ("KILLED", "TIMEOUT", "SURVIVED", "KILLED"))

        mh1, mh2 = [mutate.Mutant(id=i, file="src/A.luau", line=i + 2, op="stmt_del", original="x=1", mutated="--") for i in (1, 2)]
        with mock.patch("sert.mutate._run_process", side_effect=[
            subprocess.TimeoutExpired(cmd=["luau"], timeout=1.0, output=""),
            subprocess.CompletedProcess(["luau"], 0, "", ""),
        ]) as head_mock:
            mutate._evaluate_mutant_batch([mh1, mh2], self.tmp, "luau", "luau", ["test/spec.luau"], 1.0)
            self.assertEqual(len(head_mock.call_args_list), 2)
        self.assertEqual((mh1.status, mh2.status), ("TIMEOUT", "SURVIVED"))

        big_batch = [mutate.Mutant(id=i, file="src/A.luau", line=i, op="stmt_del", original="x=1", mutated="--") for i in range(1, 20)]
        with mock.patch("sert.mutate._run_process", return_value=subprocess.CompletedProcess(["luau"], 0, stdout="\n".join(f"[sert-mutant] {i}=KILLED" for i in range(1, 20)))) as big_mock:
            mutate._evaluate_mutant_batch(big_batch, self.tmp, "luau", "luau", ["test/spec.luau"], 2.0)
            self.assertEqual(big_mock.call_args.kwargs["timeout"], 2.0 * mutate.BATCH_TIMEOUT_FACTOR)

        with mock.patch("sert.mutate._run_process", return_value=subprocess.CompletedProcess(["lute"], 0)) as lute_mock:
            self.assertTrue(mutate._check_staged_compiles("/bin/lute", self.tmp / "s.luau", runner="lute"))
            self.assertEqual(lute_mock.call_args[0][0], ["/bin/lute", "run", str(self.tmp / "s.luau")])

        m4 = mutate.Mutant(id=4, file="src/A.luau", line=6, op="stmt_del", original="x=4", mutated="--")
        with mock.patch("sert.mutate._run_process", side_effect=[subprocess.TimeoutExpired(cmd=["luau"], timeout=1.0)]):
            mutate._evaluate_mutant_batch([m4], self.tmp, "luau", "luau", ["test/a.luau", "test/b.luau"], 1.0)
        self.assertEqual(m4.status, "TIMEOUT")

        fake_proc = mock.MagicMock(pid=9999, returncode=-9)
        fake_proc.communicate.side_effect = [subprocess.TimeoutExpired(["luau"], 1.0), ("partial", "err")]
        with mock.patch("sert.mutate.subprocess.Popen", return_value=fake_proc) as popen_mock, mock.patch("sert.mutate.run_mod._kill") as kill_mock:
            with self.assertRaises(subprocess.TimeoutExpired) as ctx:
                mutate._run_process(["luau", "s.luau"], timeout=1.0, capture_output=True)
            self.assertEqual(ctx.exception.stdout, "partial")
            kill_mock.assert_called_once_with(fake_proc)
            self.assertEqual(popen_mock.call_args.kwargs["start_new_session"], (os.name == "posix"))

    def test_paths_copy_and_guard_inside(self):
        root = self.tmp / "proj"
        (root / "src").mkdir(parents=True)
        absolute = str((root / "src/A.luau").resolve())
        self.assertEqual(mutate.coverage_rel_path(absolute, root), "src/A.luau")
        self.assertEqual(mutate.coverage_rel_path(str((root / ".sert/stage/files/src/A.luau").resolve()), root), "src/A.luau")
        self.assertEqual(mutate.coverage_rel_path("src/sub/../A.luau", root), "src/A.luau")
        for bad in (str((self.tmp / "elsewhere/A.luau").resolve()), "../outside/A.luau", "src/../../outside/A.luau", str(root.resolve())):
            self.assertIsNone(mutate.coverage_rel_path(bad, root))

        err = io.StringIO()
        with contextlib.redirect_stderr(err):
            merged = mutate.root_relative_coverage({absolute: {1: True, 2: False}, "src/A.luau": {2: True}, "/elsewhere/B.luau": {1: True}}, root)
        self.assertEqual((merged, "outside the project root: /elsewhere/B.luau" in err.getvalue()), ({"src/A.luau": {1: True, 2: True}}, True))

        (root / "src/A.luau").write_text("return 1\n")
        outside = str((self.tmp / "elsewhere").resolve())
        (root / ".packages/lib").mkdir(parents=True)
        luaurc = json.dumps({"languageMode": "strict", "aliases": {
            "lib": str((root / "src").resolve()), "top": str(root.resolve()), "far": outside, "rel": "./src",
            "up": "../elsewhere", "pkg": str((root / ".packages/lib").resolve())}})
        (root / ".luaurc").write_text(luaurc)
        work = mutate.copy_tree(root)
        try:
            copied = json.loads((work / ".luaurc").read_text())
            self.assertEqual(copied["aliases"], {"lib": str(work / "src"), "top": str(work), "far": outside, "rel": "./src", "up": outside, "pkg": str((root / ".packages/lib").resolve())})
        finally:
            shutil.rmtree(work)

        wdir, real = self.tmp / "work", self.tmp / "real"
        (wdir / "src").mkdir(parents=True)
        real.mkdir()
        (real / "A.luau").write_text("return 1\n")
        self.assertEqual(mutate._guard_inside(wdir, wdir / "src/A.luau"), wdir / "src/A.luau")
        for bad_target in (wdir / str((real / "A.luau").resolve()), wdir / "src/../../real/A.luau", wdir):
            with self.assertRaisesRegex(SertError, r"outside the mutation copy"):
                mutate._guard_inside(wdir, bad_target)
        if hasattr(os, "symlink"):
            os.symlink(real, wdir / "linked", target_is_directory=True)
            with self.assertRaisesRegex(SertError, r"outside the mutation copy"):
                mutate._guard_inside(wdir, wdir / "linked/A.luau")

    def _alias_project(self, toml: str, target_src: str, spec_body: list[str], alias_abs: bool = True, name: str = "alias"):
        root = self.project(toml, name=name)
        shutil.copytree(REPO / "src", root / ".sert/repo/src")
        lib = str((root / "src").resolve()) if alias_abs else "./src"
        (root / ".luaurc").write_text('{"aliases": {"sert": "./.sert/repo/src", "lib": ' + repr(lib).replace("'", '"') + "}}\n")
        (root / "src").mkdir(parents=True, exist_ok=True)
        (root / "src/Target.luau").write_text(target_src)
        (root / "test").mkdir(parents=True, exist_ok=True)
        (root / "test/spec.luau").write_text("\n".join(['local sert = require("@sert")', 'local Target = require("@lib/Target")', "", *spec_body, "", "return sert.run(sert.parseCliArgs(...))", ""]))
        return root

    @unittest.skipUnless(have("luau"), "luau CLI required")
    def test_end_to_end_mutate_flows(self):
        orig = "local M = {}\nfunction M.f(state)\n\tstate.valid = true\n\tstate.broken = true\n\treturn true\nend\nreturn M"
        inst, muts = mutate.instrument_source(orig, {1, 2, 3, 4, 5, 6, 7}, file_path="src/M.luau")
        inst_lines = inst.split("\n")
        inst_lines[3] = "\tif (( then state.broken = true end"
        corrupted = "\n".join(inst_lines)
        staged_w = self.tmp / "wrapped/M.luau"
        self.assertEqual([m.line for m in mutate.compile_and_stage_file("luau", orig, corrupted, muts, staged_w, wrap=True)], [3, 5])
        self.assertIn("setfenv(1, _ENV)", staged_w.read_text())
        staged_d = self.tmp / "direct/M.luau"
        self.assertEqual([m.line for m in mutate.compile_and_stage_file("luau", orig, corrupted, muts, staged_d, wrap=False)], [3, 5])
        self.assertNotIn("setfenv(1, _ENV)", staged_d.read_text())

        target_src = "local Target = {}\nfunction Target.apply(state)\n\tstate.asserted = true\n\tstate.unasserted = true\n\treturn true\nend\nreturn Target\n"
        root = self._alias_project(
            '[test]\nentries = ["test/spec.luau"]\n[coverage]\ninclude = ["src"]\n[mutate]\ninclude = ["src"]\noperators = ["stmt_del"]\n',
            target_src,
            ['sert.test("Direct Target", function()', "\tlocal state = { asserted = false, unasserted = false }", "\tsert.eq(Target.apply(state), true)", "\tsert.eq(state.asserted, true)", "end)"],
            alias_abs=True, name="direct",
        )
        code, out, err = self.sert("mutate", "--root", root, "-j", "1")
        self.assertEqual((code, out.strip(), (root / "src/Target.luau").read_text(), (root / ".sert/mutate/tree").exists()), (0, "50.0", target_src, False), err)

        sroot = self.project('[test]\nentries = ["test/spec.client.luau"]\nstage = "default.project.json"\n[coverage]\ninclude = ["src"]\n[mutate]\ninclude = ["src"]\n[mutate.specs]\n"src/Target.luau" = "Target"\n', name="staged")
        shutil.copytree(REPO / "src", sroot / ".sert/repo/src")
        (sroot / ".luaurc").write_text('{"aliases": {"sert": "./.sert/repo/src", "stage": "./.sert/stage"}}\n')
        (sroot / "default.project.json").write_text('{"name": "MutateFixture", "tree": {"$path": "src"}}\n')
        (sroot / "src").mkdir()
        (sroot / "src/Target.luau").write_text(target_src)
        (sroot / "test").mkdir()
        (sroot / "test/spec.client.luau").write_text("\n".join([
            'local sert = require("@sert")', 'local stage = require("@stage")',
            'sert.test("Target", function()', "\tlocal env = sert.env.new()", "\tlocal Target = env:require(env:mount(stage):WaitForChild('Target'))",
            "\tlocal state = {}", "\tsert.eq(Target.apply(state), true)", "\tsert.eq(state.asserted, true)", "end)",
            "return sert.run(sert.parseCliArgs(...))",
        ]))
        code, out, err = self.sert("mutate", "--root", sroot, "-j", "2")
        self.assertEqual((code, out.strip(), "__SERT_MUTANT" in (sroot / ".sert/stage/files/src/Target.luau").read_text()), (0, "66.7", False), err)
        code_m, out_m, err_m = self.sert("mutate", "--root", sroot, "--no-coverage-run", "--min", "80")
        self.assertEqual((code_m, out_m.strip(), "below the 80% floor" in err_m), (1, "66.7", True))

        slow = self._alias_project(
            '[test]\nentries = ["test/spec.luau"]\n[mutate]\ninclude = ["src"]\n',
            "local Target = {}\nfunction Target.apply(state)\n\tstate.a = true\nend\nreturn Target\n",
            ['sert.test("slow", function()', "\tlocal state = {}", "\tTarget.apply(state)", "\tlocal t = os.clock()", "\twhile os.clock() - t < 0.15 do end", "\tsert.eq(state.a, true)", "end)"],
            alias_abs=False, name="slow",
        )
        code_s, _, err_s = self.sert("mutate", "--root", slow, "-j", "1", "--timeout", "0.05")
        self.assertEqual((code_s, "raise --timeout" in err_s), (2, True))

        summary = self.tmp / "summary.md"
        self.setenv("GITHUB_STEP_SUMMARY", str(summary))
        hang = self._alias_project(
            '[test]\nentries = ["test/spec.luau"]\n[mutate]\ninclude = ["src"]\noperators = ["stmt_del"]\n',
            "local Target = {}\nfunction Target.count(state)\n\tstate.n = 0\n\twhile state.n ~= 3 do\n\t\tstate.n += 1\n\tend\n\tstate.extra = true\n\treturn state.n\nend\nreturn Target\n",
            ['sert.test("count", function()', "\tsert.eq(Target.count({}), 3)", "end)"],
            alias_abs=False, name="hang",
        )
        code_h, out_h, err_h = self.sert("mutate", "--root", hang, "-j", "2", "--timeout", "0.15")
        self.assertEqual((code_h, out_h.strip(), "Timed-out mutants (1, counted as detected):" in err_h), (0, "66.7", True))
        self.assertIn("(1 killed, 1 timed out, 1 survived, 3 total)", summary.read_text())

    def test_cli_flags_and_commands(self):
        done = subprocess.run([sys.executable, "-m", "sert", "mutate", "--help"], capture_output=True, text=True, env=dict(os.environ, PYTHONPATH=str(REPO / "python")))
        self.assertEqual(done.returncode, 0)
        for want in ("mutation testing", "stmt_del,ret_val,cond_inv,rel_flip (default: all)", "-a ..."):
            self.assertIn(want, done.stdout)
        args = cli.build(["mutate"]).parse_args(["mutate", "src", "-a", "Target", "--seed", "3"])
        self.assertEqual((args.paths, args.program_args), (["src"], ["Target", "--seed", "3"]))
        self.assertEqual(mutate._mutant_command("luau", "luau", "test/spec.luau", 4, "Spec", program_args=["Mine", "--seed=3"])[-3:], ["Mine", "--seed=3", "--mutant=4:Spec"])
        self.assertEqual(mutate._mutant_batch_command("luau", "luau", "test/spec.luau", [1, 2], None, program_args=["Mine"])[-2:], ["Mine", "--mutants=1,2"])
        self.assertEqual(mutate._mutant_command("luau", "luau", "e.luau", 1, None)[-2:], ["-a", "--mutant=1"])


if __name__ == "__main__":
    unittest.main()
