"""Comprehensive unit & integration tests for `audit`, `check --changed`, `init --skill`, Wave-2 `run`/`studio`, and `--agent`/`--format` flags."""

from __future__ import annotations

import contextlib
import io
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
from unittest import mock

import helpers  # noqa: F401
from sert import audit, check, cli, fetch, graph, luau_lex, markers, run, studio, util


def _git(cwd: Path, *args: str) -> str:
    env = {
        **os.environ,
        "GIT_AUTHOR_NAME": "Test",
        "GIT_AUTHOR_EMAIL": "test@example.com",
        "GIT_COMMITTER_NAME": "Test",
        "GIT_COMMITTER_EMAIL": "test@example.com",
    }
    proc = subprocess.run(
        ["git", *args],
        cwd=cwd,
        env=env,
        capture_output=True,
        text=True,
        check=True,
    )
    if args and args[0] == "init":
        subprocess.run(
            ["git", "config", "diff.mnemonicPrefix", "false"],
            cwd=cwd,
            env=env,
            capture_output=True,
            text=True,
            check=True,
        )
    return proc.stdout


def _init_project(root: Path, *, with_real_src: bool = False, extra_toml: str = "") -> None:
    (root / "src").mkdir(parents=True, exist_ok=True)
    (root / "test").mkdir(parents=True, exist_ok=True)
    (root / "sert.toml").write_text(
        '[test]\nspecs = ["test/*.spec.luau"]\n\n[coverage]\ninclude = ["src"]\n' + extra_toml,
        encoding="utf-8",
    )
    if with_real_src:
        repo_src = Path(__file__).resolve().parents[2] / "src"
        shutil.copytree(repo_src, root / "src", dirs_exist_ok=True)


class AuditTest(unittest.TestCase):
    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.root = Path(self._tmp.name)

    def tearDown(self) -> None:
        self._tmp.cleanup()

    def test_static_tautology_detection_and_ignore_valid_assertions(self) -> None:
        spec = self.root / "test/bad.spec.luau"
        spec.parent.mkdir(parents=True, exist_ok=True)
        spec.write_text(
            "local sert = require('../src')\n"
            "sert.describe('tautologies', function()\n"
            "    sert.test('bad', function()\n"
            "        local a = 1\n"
            "        local obj = { x = 2 }\n"
            "        sert.eq(a, a)\n"
            "        sert.eq(obj.x + 1, obj.x + 1)\n"
            "        sert.ok(true)\n"
            "        sert.ne('literal', nil)\n"
            "        sert.ne(nil, { 1, 2 })\n"
            "        sert.throws(function() sert.ne('neg', nil) end)\n"
            "        sert.eq(obj.x, 2)\n"
            "        sert.ne(obj, nil)\n"
            "    end)\n"
            "end)\n",
            encoding="utf-8",
        )
        findings = audit.scan_spec_tautologies([spec], self.root)
        kinds = [f["kind"] for f in findings]
        lines = [f["line"] for f in findings]
        self.assertEqual(
            kinds,
            ["tautology-eq", "tautology-eq", "tautology-ok", "tautology-ne-nil", "tautology-ne-nil"],
            findings,
        )
        self.assertEqual(lines, [6, 7, 8, 9, 10], findings)

    def test_remote_handler_radar_and_allow_waiver(self) -> None:
        _init_project(self.root)
        (self.root / "src/Combat.luau").write_text(
            "local M = {}\n"
            "local function onAttack(player, target) end\n"
            "function M.init(attackRemote, buyFunc)\n"
            "    attackRemote.OnServerEvent:Connect(onAttack)\n"
            "    buyFunc.OnServerInvoke = nil\n"
            "    buyFunc.OnServerInvoke = function(player, itemId) return true end\n"
            "end\n"
            "return M\n",
            encoding="utf-8",
        )
        (self.root / "test/Combat.spec.luau").write_text(
            "local Combat = require('../src/Combat')\n"
            "sert.ok(Combat ~= nil)\n",
            encoding="utf-8",
        )

        # Unfuzzed handlers fail exit 1 (note `.OnServerInvoke = nil` cleanup is ignored).
        code, report = audit.run_audit(self.root, skip_run=True)
        self.assertEqual(code, 1, report)
        self.assertEqual(len(report["unfuzzed_remotes"]), 2, report["unfuzzed_remotes"])
        self.assertEqual(
            [r["kind"] for r in report["unfuzzed_remotes"]],
            ["unfuzzed-remote", "unfuzzed-remote"],
        )
        self.assertEqual([r["remote"] for r in report["unfuzzed_remotes"]], ["attackRemote", "buyFunc"])

        # Waived via --allow-unfuzzed-remotes
        code_ok, report_ok = audit.run_audit(self.root, allow_unfuzzed_remotes=True, skip_run=True)
        self.assertEqual(code_ok, 0, report_ok)

        # Covered via fuzzRemote / remotePayload in spec
        (self.root / "test/Combat.spec.luau").write_text(
            "local Combat = require('../src/Combat')\n"
            "sert.roblox.fuzzRemote('attackRemote', function() end)\n"
            "sert.roblox.fuzzRemote('buyFunc', function() end)\n",
            encoding="utf-8",
        )
        code_fuzzed, report_fuzzed = audit.run_audit(self.root, skip_run=True)
        self.assertEqual(code_fuzzed, 0, report_fuzzed)

    def test_runtime_telemetry_zero_assertion_tautology_vacuous_and_exports(self) -> None:
        _init_project(self.root)
        (self.root / "src/Math.luau").write_text(
            "local M = {}\n"
            "function M.add(a, b)\n"
            "    return a + b\n"
            "end\n"
            "function M.unusedSecret(x)\n"
            "    local y = x * 2\n"
            "    return y\n"
            "end\n"
            "return M\n",
            encoding="utf-8",
        )
        (self.root / "coverage.out").write_text(
            "SF:src/Math.luau\n"
            "DA:2,1\n"
            "DA:3,5\n"
            "DA:5,1\n"
            "DA:6,0\n"
            "DA:7,0\n"
            "end_of_record\n",
            encoding="utf-8",
        )
        (self.root / "test/Math.spec.luau").write_text("local M = require('../src/Math')\n", encoding="utf-8")

        fake_output = "\n".join(
            [
                '[sert-test] {"file":"test/Math.spec.luau","name":"vac prop","status":"fail","message":"vacuous property: pre rejected all cases","ms":1}',
                '[sert-done] {"passed":1,"failed":1,"skipped":0,"total":2,"zeroAssertionTests":["empty test"],"tautologies":[{"test":"taut","kind":"eq","file":"test/Math.spec.luau","line":1}]}',
            ]
        )
        code, report = audit.run_audit(self.root, run_output=fake_output)
        self.assertEqual(code, 1)
        self.assertEqual(report["zero_assertion_tests"], ["empty test"])
        self.assertEqual(len(report["tautologies"]), 1)
        self.assertEqual(len(report["vacuous_properties"]), 1)
        self.assertEqual(len(report["uncovered_exports"]), 1)
        self.assertEqual(report["uncovered_exports"][0]["span"], "src/Math.luau:L5-L8")
        self.assertEqual(report["uncovered_exports"][0]["name"], "M.unusedSecret")

        agent_text = audit._format_audit_output("agent", code, report, root=self.root)
        self.assertIn("ZERO_ASSERTION empty test", agent_text)
        self.assertIn("TAUTOLOGY", agent_text)
        self.assertIn("UNCOVERED_EXPORT src/Math.luau:L5-L8 M.unusedSecret", agent_text)

        # Clean telemetry + uncovered export: exit 0 normally, exit 1 with --strict
        clean_out = '[sert-done] {"passed":1,"failed":0,"skipped":0,"total":1,"zeroAssertionTests":[],"tautologies":[]}'
        code_norm, rep_norm = audit.run_audit(self.root, run_output=clean_out)
        self.assertEqual(code_norm, 0, rep_norm)
        self.assertEqual(len(rep_norm["uncovered_exports"]), 1)
        code_strict, rep_strict = audit.run_audit(self.root, run_output=clean_out, strict=True)
        self.assertEqual(code_strict, 1, rep_strict)

    def test_audit_diff_scoping(self) -> None:
        _init_project(self.root)
        _git(self.root, "init")
        (self.root / "test/clean.spec.luau").write_text("sert.ok(1 == 1)\n", encoding="utf-8")
        (self.root / "test/untouched_bad.spec.luau").write_text("sert.ok(true)\n", encoding="utf-8")
        _git(self.root, "add", ".")
        _git(self.root, "commit", "-m", "init")

        # Without diff, untouched_bad fails
        code_all, _ = audit.run_audit(self.root, skip_run=True)
        self.assertEqual(code_all, 1)
        # With --diff HEAD and only clean.spec modified, untouched_bad is excluded
        (self.root / "test/clean.spec.luau").write_text("local x = 1\nsert.eq(x, 1)\n", encoding="utf-8")
        code_diff, rep_diff = audit.run_audit(self.root, diff="HEAD", skip_run=True)
        self.assertEqual(code_diff, 0, rep_diff)

    def test_real_luau_audit_zero_assertion_and_smoke(self) -> None:
        if util.which("luau") is None:
            self.skipTest("luau binary not available on PATH")

        _init_project(self.root, with_real_src=True)
        (self.root / "test/Smoke.spec.luau").write_text(
            'local sert = require("../src")\n'
            'sert.describe("audit smoke", function()\n'
            '    sert.test("smoke ok", function() end, { smoke = true })\n'
            '    sert.test("missing assertion", function() local _x = 1 + 1 end)\n'
            "end)\n",
            encoding="utf-8",
        )
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            code = cli.main(["audit", "--root", str(self.root), "--format", "json"])
        self.assertEqual(code, 1, out.getvalue())
        env = json.loads(out.getvalue())
        self.assertEqual(env["data"]["zero_assertion_tests"], ["audit smoke > missing assertion"])

    def test_extract_module_exports_ignores_nested_helper_functions(self) -> None:
        src = (
            "local M = {}\n"
            "function M.public(a: number): number\n"
            "\tlocal function helper(x: number): number\n"
            "\t\treturn x + 1\n"
            "\tend\n"
            "\tlocal sub = {}\n"
            "\tfunction sub.inner(): number\n"
            "\t\treturn 2\n"
            "\tend\n"
            "\treturn helper(a) + sub.inner()\n"
            "end\n"
            "return M\n"
        )
        exports = audit._extract_module_exports(luau_lex.tokenize(src), "src/Foo.luau")
        self.assertEqual([(e.name, e.start_line, e.end_line) for e in exports], [("M.public", 2, 11)])


class RunAndStudioIntegrationTest(unittest.TestCase):
    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.root = Path(self._tmp.name)

    def tearDown(self) -> None:
        self._tmp.cleanup()

    def test_run_affected_noop_and_diff_narrowing(self) -> None:
        _init_project(self.root)
        _git(self.root, "init")
        (self.root / "src/a.luau").write_text("return { x = 1 }\n", encoding="utf-8")
        (self.root / "src/b.luau").write_text("return { y = 2 }\n", encoding="utf-8")
        (self.root / "test/a.spec.luau").write_text("local A = require('../src/a')\n", encoding="utf-8")
        (self.root / "test/b.spec.luau").write_text("local B = require('../src/b')\n", encoding="utf-8")
        _git(self.root, "add", ".")
        _git(self.root, "commit", "-m", "init")

        # Clean tree + --affected -> no-op exit 0 without launching runner
        with mock.patch.object(run, "run_entries") as mock_entries:
            out_agent = io.StringIO()
            with contextlib.redirect_stdout(out_agent):
                code = cli.main(["run", "--root", str(self.root), "--affected", "--agent"])
            out_human = io.StringIO()
            err_human = io.StringIO()
            with contextlib.redirect_stdout(out_human), contextlib.redirect_stderr(err_human):
                code_h = cli.main(["run", "--root", str(self.root), "--affected"])
        self.assertEqual((code, code_h), (0, 0))
        self.assertIn("affected=0", out_agent.getvalue())
        self.assertIn("0 specs impacted", (out_human.getvalue() + err_human.getvalue()).lower())
        mock_entries.assert_not_called()

        # Modify src/a.luau -> narrows to a.spec.luau only
        (self.root / "src/a.luau").write_text("return { x = 2 }\n", encoding="utf-8")
        seen_runner_texts: list[str] = []

        def fake_entries(cfg_arg, entries, *, runner="luau", program_args=(), **kw):
            seen_runner_texts.append((self.root / entries[0]).read_text(encoding="utf-8"))
            return run.RunResult(
                status=0,
                entries=[run.EntryRun(entries[0], 0, 0.01, output='[sert-done] {"passed":1,"failed":0,"skipped":0,"total":1}\n')],
                tests=[{"name": "t1", "status": "pass", "ms": 1, "file": "test/a.spec.luau"}],
            )

        with mock.patch.object(run, "run_entries", side_effect=fake_entries):
            with mock.patch.object(run, "which", return_value="luau"):
                code = cli.main(["run", "--root", str(self.root), "--affected", "HEAD"])
        self.assertEqual(code, 0)
        self.assertIn("test/a.spec.luau", seen_runner_texts[0])
        self.assertNotIn("test/b.spec.luau", seen_runner_texts[0])

    def test_regression_toml_autoload_save_and_failed_tape_replay(self) -> None:
        _init_project(self.root)
        (self.root / "test/Prop.spec.luau").write_text("local x = 1\n", encoding="utf-8")
        reg_file = self.root / "test/.sert-regressions.toml"
        reg_file.write_text(
            '[[regression]]\ntest = "commutes"\nfile = "test/Prop.spec.luau"\ntoken = "v1:abc="\n',
            encoding="utf-8",
        )
        loaded = run.load_regressions_by_test(self.root)
        self.assertEqual(loaded, {"commutes": ["v1:abc="]})

        # Verify write_spec_runner embeds regressions + snapshots
        (self.root / "test/__snapshots__/Prop.snap").parent.mkdir(parents=True, exist_ok=True)
        (self.root / "test/__snapshots__/Prop.snap").write_text('exports["snap"] = "hello"\n', encoding="utf-8")
        runner_rel = run.write_spec_runner(self.root, ["test/Prop.spec.luau"])
        runner_src = (self.root / runner_rel).read_text(encoding="utf-8")
        self.assertIn("regressions", runner_src)
        self.assertIn("v1:abc=", runner_src)
        self.assertIn("snapshots", runner_src)

        # Save new regression tokens & tape into .sert/last-failed.json and replay via --failed
        reg_output = (
            '[sert-test] {"file":"test/Prop.spec.luau","name":"assoc","status":"fail","ms":1,"replay":"v1:deadbeef"}\n'
            '[sert-x:regression] {"test":"assoc","file":"test/Prop.spec.luau","token":"v1:deadbeef"}\n'
            '[sert-done] {"passed":0,"failed":1,"skipped":0,"total":1}\n'
        )
        parsed = markers.parse(reg_output)
        with mock.patch.object(
            run,
            "run_entries",
            return_value=run.RunResult(
                status=1,
                entries=[run.EntryRun(".sert/run.luau", 1, 0.01, output=reg_output)],
                tests=parsed.tests,
            ),
        ):
            with mock.patch.object(run, "which", return_value="luau"):
                code = cli.main(["run", "--root", str(self.root), "--save-regressions"])
        self.assertEqual(code, 1)
        self.assertEqual(run.load_regressions_by_test(self.root).get("assoc"), ["v1:deadbeef"])
        last_failed = json.loads((self.root / ".sert/last-failed.json").read_text(encoding="utf-8"))
        self.assertEqual(last_failed["tapes"], {"assoc": "v1:deadbeef"})

        # --failed replays stored v1: tape via --failed-replays
        seen_luau_args: list[list[str]] = []

        def fake_entries_replay(cfg_arg, entries, *, program_args=(), **kw):
            seen_luau_args.append(list(program_args))
            return run.RunResult(
                status=0,
                entries=[run.EntryRun(".sert/run.luau", 0, 0.01, output='[sert-done] {"passed":1,"failed":0,"skipped":0,"total":1}\n')],
                tests=[{"name": "assoc", "status": "pass", "ms": 1, "file": "test/Prop.spec.luau"}],
            )

        with mock.patch.object(run, "run_entries", side_effect=fake_entries_replay):
            with mock.patch.object(run, "which", return_value="luau"):
                code2 = cli.main(["run", "--root", str(self.root), "--failed"])
        self.assertEqual(code2, 0)
        self.assertTrue(
            any(
                a == "--replay=v1:deadbeef" or (a.startswith("--failed-replays=") and "v1:deadbeef" in a)
                for a in seen_luau_args[0]
            ),
            seen_luau_args,
        )

    def test_snapshot_updates_prune_and_ci_guard(self) -> None:
        _init_project(self.root)
        spec_path = self.root / "test/Snap.spec.luau"
        spec_path.write_text('sert.inlineSnapshot("a", "old")\n', encoding="utf-8")
        snap_dir = self.root / "test/__snapshots__"
        snap_dir.mkdir(parents=True, exist_ok=True)
        (snap_dir / "Snap.snap").write_text('exports["stale"] = "obsolete"\n', encoding="utf-8")

        # CI guard rejects -u under --ci or CI=true
        err_ci = io.StringIO()
        with contextlib.redirect_stderr(err_ci):
            code_ci = cli.main(["run", "--root", str(self.root), "-u", "--ci"])
        self.assertEqual(code_ci, 2)
        self.assertIn("cannot be used in CI mode", err_ci.getvalue())
        with mock.patch.dict(os.environ, {"CI": "true"}):
            ci_parser = cli.build(["run"])
            ci_args = ci_parser.parse_args(["run", "--root", str(self.root), "-u"])
            with self.assertRaisesRegex(util.SertError, "cannot be used in CI mode"):
                run.cmd_run(ci_args)

        snap_out = (
            '[sert-file] shared|test/Snap.spec.luau|2\n'
            '[sert-test] {"file":"test/Snap.spec.luau","name":"snap","status":"pass","ms":1}\n'
            '[sert-x:snapshot] '
            + json.dumps({"kind": "inline", "file": "test/Snap.spec.luau", "line": 1, "ordinal": 1, "actual": "new"})
            + "\n"
            '[sert-done] {"passed":1,"failed":0,"skipped":0,"total":1}\n'
        )
        with mock.patch.dict(os.environ, {"CI": ""}):
            with mock.patch.object(
                run,
                "run_entries",
                return_value=run.RunResult(
                    status=0,
                    entries=[run.EntryRun(".sert/run.luau", 0, 0.01, output=snap_out)],
                    tests=[{"name": "snap", "status": "pass", "ms": 1, "file": "test/Snap.spec.luau"}],
                ),
            ):
                with mock.patch.object(run, "which", return_value="luau"):
                    code = cli.main(["run", "--root", str(self.root), "-u", "--prune-snapshots"])
        self.assertEqual(code, 0)
        self.assertIn('"new"', spec_path.read_text(encoding="utf-8"))
        self.assertFalse((snap_dir / "Snap.snap").exists())

    def test_coverage_map_and_all_skipped_human_message_and_agent_json(self) -> None:
        _init_project(self.root)
        (self.root / "src/mod.luau").write_text("return {}\n", encoding="utf-8")
        spec_path = self.root / "test/Env.spec.luau"
        spec_path.write_text("local M = require('../src/mod')\n", encoding="utf-8")
        (self.root / "coverage.out").write_text("SF:src/mod.luau\nDA:1,1\nend_of_record\n", encoding="utf-8")

        skip_out = (
            '[sert-test] {"file":"test/Env.spec.luau","name":"rbx","status":"skip","reason":"roblox","ms":0}\n'
            '[sert-done] {"passed":0,"failed":0,"skipped":1,"total":1,"skippedByReason":{"explicit":0,"roblox":1,"server":0,"client":0}}\n'
        )
        with mock.patch.object(
            run,
            "run_entries",
            return_value=run.RunResult(
                status=0,
                entries=[run.EntryRun(".sert/run.luau", 0, 0.01, output=skip_out)],
                tests=markers.parse(skip_out).tests,
            ),
        ):
            with mock.patch.object(run, "which", return_value="luau"):
                err_buf = io.StringIO()
                out_buf = io.StringIO()
                with contextlib.redirect_stdout(out_buf), contextlib.redirect_stderr(err_buf):
                    code = cli.main(["run", "--root", str(self.root), "--coverage", "--filter", "rbx"])
        self.assertEqual(code, 1, err_buf.getvalue())
        self.assertIn("sert run: all 1 matching tests were skipped", err_buf.getvalue())
        self.assertTrue((self.root / ".sert/coverage-map.json").is_file())
        cov_map = graph.load_coverage_map(self.root)
        self.assertIn("src/mod.luau", cov_map["specs"]["test/Env.spec.luau"]["files"])

        # --format json and --agent
        pass_out = (
            '[sert-file] shared|test/Env.spec.luau|2\n'
            '[sert-test] {"file":"test/Env.spec.luau","name":"ok","status":"pass","ms":1}\n'
            '[sert-done] {"passed":1,"failed":0,"skipped":0,"total":1}\n'
        )
        with mock.patch.object(
            run,
            "run_entries",
            return_value=run.RunResult(
                status=0,
                entries=[run.EntryRun(".sert/run.luau", 0, 0.01, output=pass_out)],
                tests=markers.parse(pass_out).tests,
            ),
        ):
            with mock.patch.object(run, "which", return_value="luau"):
                json_buf = io.StringIO()
                with contextlib.redirect_stdout(json_buf):
                    code_j = cli.main(["run", "--root", str(self.root), "--format", "json"])
        self.assertEqual(code_j, 0)
        env = json.loads(json_buf.getvalue())
        self.assertEqual((env["command"], env["status"], env["exit_code"], env["summary"]["passed"]), ("run", "ok", 0, 1))

    def test_studio_build_request_forwarding_and_ci_guard(self) -> None:
        _init_project(
            self.root,
            extra_toml='\n[studio]\nproject = "default.project.json"\nspecs = ["test/**/*.spec.luau"]\n',
        )
        (self.root / "default.project.json").write_text('{"name":"Test","tree":{"$className":"DataModel"}}', encoding="utf-8")
        (self.root / "test/.sert-regressions.toml").write_text(
            '[[regression]]\ntest = "r1"\nfile = "test/S.spec.luau"\ntoken = "v1:tok"\n',
            encoding="utf-8",
        )
        (self.root / "test/__snapshots__/S.snap").parent.mkdir(parents=True, exist_ok=True)
        (self.root / "test/__snapshots__/S.snap").write_text('exports["s1"] = "val"\n', encoding="utf-8")

        settings = studio.Settings(self.root, studio.sert_config.load(self.root))
        parser = studio.build_parser(settings, studio.Hooks(), load_suite_hooks=False)

        with mock.patch.dict(os.environ, {"CI": ""}):
            opts = parser.parse_args(
                ["--root", str(self.root), "-u", "--strict-assertions", "--bench"]
            )
            req = studio.build_request(settings, opts, "run", studio.Selection(), "run-1")
        self.assertTrue(req["updateSnapshots"])
        self.assertTrue(req["strictAssertions"])
        self.assertTrue(req["bench"])
        self.assertEqual(req["regressions"], {"r1": ["v1:tok"]})
        self.assertEqual(req["snapshots"]["S"], {"s1": "val"})
        self.assertIn("--update-snapshots", req["args"])
        self.assertIn("--strict-assertions", req["args"])
        self.assertIn("--bench", req["args"])

        ci_opts = parser.parse_args(["--root", str(self.root), "-u", "--ci"])
        with self.assertRaisesRegex(util.SertError, "cannot be used in CI mode"):
            studio.build_request(settings, ci_opts, "run", studio.Selection(), "run-2")

    def test_sharded_entry_aggregates_skips_zero_assertions_and_tautologies(self) -> None:
        _init_project(self.root)
        cfg = studio.sert_config.load(self.root)

        shard_outputs = {
            "--shard=1/2": (
                '[sert-file] shared|test/A.spec.luau|2\n'
                '[sert-test] {"file":"test/A.spec.luau","name":"t1","status":"pass","ms":1}\n'
                '[sert-done] {"passed":1,"failed":0,"skipped":1,"total":2,"skippedByReason":{"explicit":1,"roblox":0},"zeroAssertionTests":["z1"],"tautologies":[{"file":"test/A.spec.luau","line":3,"message":"m1"}]}\n'
            ),
            "--shard=2/2": (
                '[sert-file] shared|test/B.spec.luau|3\n'
                '[sert-test] {"file":"test/B.spec.luau","name":"t2","status":"pass","ms":1}\n'
                '[sert-done] {"passed":1,"failed":0,"skipped":2,"total":3,"skippedByReason":{"roblox":2,"client":1},"zeroAssertionTests":["z2"],"tautologies":[{"file":"test/B.spec.luau","line":4,"message":"m2"}]}\n'
            ),
        }

        class FakeProc:
            def __init__(self, cmd: list[str], **_kwargs) -> None:
                shard_flag = next(a for a in cmd if a.startswith("--shard="))
                self.stdout = io.StringIO(shard_outputs[shard_flag])
                self.stderr = io.StringIO("")
                self.returncode = 0

            def poll(self) -> int:
                return self.returncode

            def wait(self, timeout=None) -> int:
                return self.returncode

        with mock.patch.object(run.subprocess, "Popen", side_effect=lambda cmd, **kw: FakeProc(cmd, **kw)):
            entry_run = run._run_sharded_entry(
                cfg,
                "luau",
                "luau",
                ".sert/run.luau",
                [],
                False,
                True,
                None,
                True,
                False,
                False,
                2,
            )

        self.assertEqual(entry_run.code, 0)
        parsed = markers.parse(entry_run.output)
        self.assertEqual(parsed.skipped_by_reason, {"explicit": 1, "roblox": 2, "server": 0, "client": 1})
        self.assertEqual(parsed.zero_assertion_tests, ["z1", "z2"])
        self.assertEqual(
            parsed.tautologies,
            [
                {"file": "test/A.spec.luau", "line": 3, "message": "m1"},
                {"file": "test/B.spec.luau", "line": 4, "message": "m2"},
            ],
        )


class CheckChangedTest(unittest.TestCase):
    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.root = Path(self._tmp.name)

    def tearDown(self) -> None:
        self._tmp.cleanup()

    def _run_stage1_helper(self, skipped_by_reason: dict[str, int] | None = None, *, test_fail: bool = False):
        skips = skipped_by_reason or {"explicit": 0, "roblox": 0, "server": 0, "client": 0}
        status = 1 if test_fail else 0
        payload = {
            "passed": 1 if not test_fail else 0,
            "failed": 1 if test_fail else 0,
            "skipped": sum(skips.values()),
            "total": 1 + sum(skips.values()),
            "skippedByReason": skips,
        }
        line = "[sert-done] " + json.dumps(payload) + "\n"
        parsed = markers.parse(line)

        def fake_exec(run_args, root=None, cfg=None, *, out=None, err=None):
            if out is not None:
                out.write("OK passed=1 failed=0 skipped=0\n")
            res = run.RunResult(status=status, entries=[], tests=parsed.tests)
            return status, res, [parsed]

        return mock.patch.object(check, "_invoke_stage1_run", side_effect=fake_exec)

    def test_check_changed_clean_pipeline_runs_mutate_only_on_covered_diff(self) -> None:
        _init_project(self.root)
        _git(self.root, "init")
        (self.root / "src/a.luau").write_text("local M = {}\nfunction M.f() return 1 end\nreturn M\n", encoding="utf-8")
        (self.root / "test/a.spec.luau").write_text("local A = require('../src/a')\nsert.eq(A.f(), 1)\n", encoding="utf-8")
        _git(self.root, "add", ".")
        _git(self.root, "commit", "-m", "init")
        # Dirty covered line in src/a.luau
        (self.root / "src/a.luau").write_text("local M = {}\nfunction M.f() return 2 end\nreturn M\n", encoding="utf-8")
        (self.root / "coverage.out").write_text("SF:src/a.luau\nDA:1,1\nDA:2,1\nDA:3,1\nend_of_record\n", encoding="utf-8")

        mut_calls: list = []

        def fake_mutate(m_args):
            mut_calls.append(m_args)
            print("100.0")
            return 0

        with (
            mock.patch.object(check, "_invoke_lint", return_value=0),
            self._run_stage1_helper(),
            mock.patch("sert.mutate.main", side_effect=fake_mutate),
            mock.patch("sert.studio.main") as mock_studio,
        ):
            out = io.StringIO()
            with contextlib.redirect_stdout(out):
                code = cli.main(["check", "--changed", "--root", str(self.root), "--agent"])

        self.assertEqual(code, 0, out.getvalue())
        self.assertEqual(len(mut_calls), 1)
        self.assertEqual(mut_calls[0].diff, "HEAD")
        mock_studio.assert_not_called()
        self.assertIn("OK checks=5 passed=5 failed=0", out.getvalue())
        self.assertIn("PASSED: lint, tests, coverage, audit, mutate", out.getvalue())

    def test_check_changed_no_studio_guard_and_warm_cold_fallback(self) -> None:
        _init_project(
            self.root,
            extra_toml='\n[studio]\nproject = "default.project.json"\nspecs = ["test/**/*.spec.luau"]\n',
        )
        (self.root / "default.project.json").write_text('{"name":"T","tree":{"$className":"DataModel"}}', encoding="utf-8")
        (self.root / "coverage.out").write_text("", encoding="utf-8")
        skips = {"explicit": 0, "roblox": 2, "server": 1, "client": 0}

        # 1) --no-studio without --allow-skipped-targets -> exit 1 with exact `sert studio` command
        with (
            mock.patch.object(check, "_invoke_lint", return_value=0),
            self._run_stage1_helper(skips),
        ):
            out = io.StringIO()
            with contextlib.redirect_stdout(out):
                code = cli.main(["check", "--changed", "--root", str(self.root), "--no-mutate", "--no-studio", "--agent"])
        self.assertEqual(code, 1)
        self.assertIn("sert studio --affected HEAD", out.getvalue())
        self.assertIn("--- FAILED studio ---", out.getvalue())

        # 2) --no-studio + --allow-skipped-targets -> exit 0
        with (
            mock.patch.object(check, "_invoke_lint", return_value=0),
            self._run_stage1_helper(skips),
        ):
            out2 = io.StringIO()
            with contextlib.redirect_stdout(out2):
                code2 = cli.main(
                    [
                        "check",
                        "--changed",
                        "--root",
                        str(self.root),
                        "--no-mutate",
                        "--no-studio",
                        "--allow-skipped-targets",
                        "--format",
                        "json",
                    ]
                )
        self.assertEqual(code2, 0, out2.getvalue())
        env = json.loads(out2.getvalue())
        self.assertEqual(env["command"], "check")
        self.assertEqual(env["summary"]["engine_skipped"], 3)

        # 3) Studio enabled: tries --warm first, falls back to cold headless on INFRA (2)
        studio_calls: list[tuple[bool, str | None]] = []

        def fake_studio_main(opts):
            studio_calls.append((bool(getattr(opts, "warm", False)), getattr(opts, "studio_id", None)))
            return util.INFRA if getattr(opts, "warm", False) else 0

        with (
            mock.patch.object(check, "_invoke_lint", return_value=0),
            self._run_stage1_helper(skips),
            mock.patch("sert.studio.main", side_effect=fake_studio_main),
        ):
            out3 = io.StringIO()
            with contextlib.redirect_stdout(out3):
                code3 = cli.main(
                    ["check", "--changed", "--root", str(self.root), "--no-mutate", "--studio-id", "win-1", "--agent"]
                )
        self.assertEqual(code3, 0, out3.getvalue())
        self.assertEqual(studio_calls, [(True, "win-1"), (False, "win-1")])
        self.assertIn("studio", out3.getvalue())


class InitSkillAndFormattingTest(unittest.TestCase):
    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.root = Path(self._tmp.name)

    def tearDown(self) -> None:
        self._tmp.cleanup()

    def test_init_skill_schema_stdout_install_and_agents(self) -> None:
        out_md = io.StringIO()
        with contextlib.redirect_stdout(out_md):
            code = cli.main(["init", "--stdout"])
        self.assertEqual(code, 0)
        md = out_md.getvalue()
        for token in (
            "sert check --changed --agent",
            "sert check --audit --agent",
            "sert audit",
            "sert fuzz",
            "sert.inlineSnapshot",
            "-u",
            "sert.env",
            "sert.sim.vopr",
            "linearizable",
            "sert.noAllocs",
            "sert.roblox.Layout",
            "conformance",
        ):
            self.assertIn(token, md)

        out_json = io.StringIO()
        with contextlib.redirect_stdout(out_json):
            code_j = cli.main(["init", "--json"])
        self.assertEqual(code_j, 0)
        schema = json.loads(out_json.getvalue())
        for expected_cmd in ("init", "check", "audit", "fuzz", "bench"):
            self.assertIn(expected_cmd, schema["commands"])
        self.assertNotIn("verify", schema["commands"])
        self.assertNotIn("skill", schema["commands"])

        # `--skill DIR` writes only SKILL.md without scaffolding sert.toml
        inst_dir = self.root / "custom-skill"
        out_i = io.StringIO()
        with contextlib.redirect_stdout(out_i):
            code_i = cli.main(["init", "--root", str(self.root), "--skill", str(inst_dir)])
        self.assertEqual(code_i, 0)
        self.assertTrue((inst_dir / "SKILL.md").is_file())
        self.assertFalse((self.root / "sert.toml").exists())

        # Bare `--skill` installs into `.agents/skills/sert/SKILL.md` without scaffolding sert.toml
        skill_root = self.root / "skill-only"
        skill_root.mkdir()
        out_def = io.StringIO()
        with contextlib.redirect_stdout(out_def):
            code_def = cli.main(["init", "--root", str(skill_root), "--skill"])
        self.assertEqual(code_def, 0)
        self.assertTrue((skill_root / ".agents/skills/sert/SKILL.md").is_file())
        self.assertFalse((skill_root / "sert.toml").exists())

        # Reject incompatible flag combinations
        for bad_args in (
            ["init", "--stdout", "--json"],
            ["init", "--skill", str(inst_dir), "--stdout"],
            ["init", "--skill", "--stdout"],
            ["init", "--skill", "--fetch"],
            ["init", "--json", "--agents"],
        ):
            err_buf = io.StringIO()
            with contextlib.redirect_stderr(err_buf):
                bad_code = cli.main(bad_args)
            self.assertEqual(bad_code, 2, f"expected exit 2 for {bad_args}, got stderr={err_buf.getvalue()!r}")

        proj = self.root / "proj"
        proj.mkdir()
        created = fetch.init(proj, agents=True)
        self.assertIn(".agents/skills/sert/SKILL.md", created)
        self.assertTrue((proj / ".agents/skills/sert/SKILL.md").is_file())

    def test_cli_commands_and_check_coverage_agent_formats(self) -> None:
        for cmd in ("init", "check", "fuzz", "audit", "bench"):
            self.assertIn(cmd, cli.COMMANDS)
        for removed in ("verify", "skill"):
            self.assertNotIn(removed, cli.COMMANDS)
            with contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit) as ctx:
                cli.build([removed]).parse_args([removed])
            self.assertEqual(ctx.exception.code, 2)

        _init_project(self.root)
        (self.root / "src/a.luau").write_text("return 1\n", encoding="utf-8")
        (self.root / "coverage.out").write_text("SF:src/a.luau\nDA:1,1\nend_of_record\n", encoding="utf-8")
        out_cov = io.StringIO()
        with contextlib.redirect_stdout(out_cov):
            code = cli.main(["coverage", "--root", str(self.root), "--format", "json"])
        self.assertEqual(code, 0)
        cov_env = json.loads(out_cov.getvalue())
        self.assertEqual(
            (cov_env["command"], cov_env["status"], cov_env["exit_code"], cov_env["summary"]["pct"]),
            ("coverage", "ok", 0, 100.0),
        )

        with (
            mock.patch.object(check.lint, "cmd_lint", return_value=0),
            mock.patch.object(check.run, "cmd_run", return_value=0),
        ):
            out_chk = io.StringIO()
            with contextlib.redirect_stdout(out_chk):
                code_c = cli.main(["check", "--root", str(self.root), "--agent"])
        self.assertEqual(code_c, 0, out_chk.getvalue())
        self.assertIn("OK checks=3 passed=3 failed=0", out_chk.getvalue())


if __name__ == "__main__":
    unittest.main()
