"""Unit tests for `sert.studio.runscript`: Windows unmarked-PID safety, Flatpak Vinegar argv/Wine paths, fast readiness, and `--warm`."""

from __future__ import annotations

import io
import itertools
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import tempfile
import threading
import types
import unittest
from unittest import mock

import helpers  # noqa: F401
from sert import util
from sert.studio import runscript
from sert.util import SertError, luau_string


class DriverAndOptionsTest(unittest.TestCase):
    def test_generated_driver_no_sleep_warm_driver_and_options(self):
        source = runscript.build_driver(runscript.Options("p.rbxl", "play", args_json='{"a":1}'))
        for want in (
            'local SENTINEL = "[sert-verdict]"',
            'local ARGS_JSON = "{\\"a\\":1}"',
            "local PRELUDE = nil",
            "ExecutePlayModeAsync",
            "while not game:IsLoaded()",
            'pcall(workspace.SetAttribute, workspace, "sert_Args", ARGS_JSON)',
            'pcall(workspace.SetAttribute, workspace, "sert_Args", nil)',
            "the session's value is not JSON-encodable",
        ):
            self.assertIn(want, source)
        # Checklist 6a: unconditional `task.wait(2)` removed!
        self.assertNotIn("task.wait(2)", source)
        self.assertNotIn("getfenv", source)
        self.assertNotIn("setfenv", source)

        run_src = runscript.build_driver(runscript.Options("p.rbxl", "run", prelude="workspace.Gravity = 0"))
        self.assertTrue("ExecuteRunModeAsync" in run_src and 'local PRELUDE = "workspace.Gravity = 0"' in run_src)
        script = 'print("[sert-verdict] {\\"passed\\":true}")\n'
        self.assertEqual(runscript.build_driver(runscript.Options("p.rbxl", "edit", script=script)), script)

        warm_src = runscript.build_warm_driver(runscript.Options("p.rbxl", "play", args_json='{"runId":"r1"}', warm=True))
        self.assertIn("LogService.MessageOut:Connect", warm_src)
        self.assertNotIn("getfenv", warm_src)
        self.assertNotIn("setfenv", warm_src)

        for name in ("reports_failure", "run", "strip_echo", "last_result_line", "creator_output", "collect_output", "run_attempt", "stop_run", "Outcome", "execute_warm"):
            self.assertTrue(hasattr(runscript, name), name)

        done = subprocess.run(
            [sys.executable, "-m", "sert.studio.runscript", "--help"],
            capture_output=True,
            text=True,
            env=dict(os.environ, PYTHONPATH=str(helpers.PYTHON)),
        )
        self.assertEqual(done.stdout, "")

        for given, message in (
            ({"mode": "debug"}, "unknown mode 'debug'"),
            ({"mode": "edit"}, "edit mode runs a script"),
            ({"mode": "play", "script": "x"}, "edit mode runs a script"),
            ({"mode": "play", "timeout": 0}, "--timeout must be finite and positive"),
            ({"mode": "play", "timeout": float("inf")}, "--timeout must be finite and positive"),
            ({"mode": "play", "args": {"budget": float("nan")}}, "the request is not JSON"),
            ({"mode": "play", "launcher": "   "}, "--launcher is empty"),
            ({"mode": "play", "launcher": '"unclosed'}, "--launcher:"),
        ):
            kw = {"script": None, "args": None, "prelude": None, "timeout": 300.0, "keep": False, "launcher": None, **given}
            mode = kw.pop("mode")
            with self.assertRaisesRegex(SertError, message):
                runscript.options("p.rbxl", mode, **kw)
            with self.assertRaisesRegex(SertError, message):
                runscript.run("p.rbxl", mode=mode, report="r.json", **kw)

        opts = runscript.options("p.rbxl", "run", script=None, args={"k": 1}, prelude=None, timeout=5.0, keep=True, launcher="studio", warm=True, studio_id="s1")
        self.assertEqual((opts.mode, opts.args_json, opts.timeout, opts.keep, opts.warm, opts.studio_id), ("run", '{"k": 1}', 5.0, True, True, "s1"))


class OutputProcessAndAttemptTest(unittest.TestCase):
    def test_vinegar_flatpak_argv_wine_paths_and_logs(self):
        self.assertEqual(runscript.last_result_line('[sert-verdict] {"a":1}\nnoise\n[sert-done] {"b":1}\n[sert-verdict] {"a":2}\n'), '{"a":2}')
        self.assertIsNone(runscript.last_result_line("[sert-done] {}\n"))
        self.assertEqual(runscript.strip_echo("before\n> print(1)\nprint(2)\n\nafter\n", "print(1)\nprint(2)\n"), "before\nafter\n")
        self.assertEqual((luau_string('a"b\\\n\r\t'), luau_string("é")), ('"a\\"b\\\\\\n\\r\\t"', '"\\u{E9}"'))

        with tempfile.TemporaryDirectory() as tmp:
            # Explicit Flatpak Vinegar launcher string splits argv AND converts Linux paths to Wine `Z:\...`!
            opts_explicit_vin = runscript.Options(
                os.path.join(tmp, "p.rbxl"),
                "play",
                launcher="flatpak run org.vinegarhq.Vinegar run",
            )
            self.assertTrue(runscript.uses_vinegar(opts_explicit_vin))
            self.assertTrue(runscript.uses_wine_paths(opts_explicit_vin))
            self.assertEqual(runscript.launcher_prefix(opts_explicit_vin), ["flatpak", "run", "org.vinegarhq.Vinegar", "run"])
            self.assertTrue(runscript.studio_path(opts_explicit_vin, "/tmp/a/b").startswith("Z:\\"))

            opts_q = runscript.Options(os.path.join(tmp, "p.rbxl"), "play", args_json='{"x":1}', prelude="workspace.Gravity = 100\n")
            with open(opts_q.place, "wb") as fh:
                fh.write(b"place-bytes")
            place_out, driver_out, driver_src = runscript.stage_files(opts_q, os.path.join(tmp, "stage1"))
            self.assertTrue(os.path.isfile(place_out) and os.path.isfile(driver_out) and "workspace.Gravity = 100" in driver_src)
            self.assertEqual(runscript.launcher_prefix(opts_q), ["flatpak", "run", runscript.VINEGAR_APP])
            self.assertTrue(runscript.studio_path(opts_q, "/tmp/a/b").startswith("Z:\\") and runscript.VINEGAR_APP in runscript.stage_root(opts_q))

            exe_file = os.path.join(tmp, "My Studio.exe")
            open(exe_file, "w").close()
            opts_exe = types.SimpleNamespace(launcher=exe_file)
            self.assertEqual(
                (runscript.launcher_prefix(opts_exe), runscript.studio_path(opts_exe, exe_file), runscript.vinegar_problem(opts_exe)),
                ([exe_file], os.path.abspath(exe_file), None),
            )
            with mock.patch.object(runscript.os, "name", "nt"):
                self.assertEqual(
                    runscript.launcher_prefix(types.SimpleNamespace(launcher='"C:\\Program Files\\Studio.exe" --flag')),
                    ["C:\\Program Files\\Studio.exe", "--flag"],
                )

            log_path = os.path.join(tmp, "studio_01.log")
            with open(log_path, "w", encoding="utf-8") as fh:
                fh.write(
                    "2026-01-01T00:00:00.000Z,0.1,100,6 [FLog::Output] Command line: run1 output.log\n"
                    "2026-01-01T00:00:01.000Z,1.1,100,6 [FLog::CreatorOutput] hello world\ncontinuation line\n"
                    "2026-01-01T00:00:01.500Z,1.5,100,6 [FLog::CreatorWarning] Warning: careful\n"
                    "2026-01-01T00:00:02.000Z,2.0,100,6 [FLog::CreatorError] bad error\n"
                )
            self.assertEqual(runscript.find_studio_log([tmp, os.path.join(tmp, "no_dir")], ("run1", "output.log"), 0.0), log_path)
            tail = runscript.LogTail(log_path, b"[FLog::CreatorOutput] [sert-verdict] ")
            signin_tail = runscript.LogTail(log_path, runscript.SIGNIN_NEEDLE)
            self.assertFalse(tail.found())
            self.assertFalse(signin_tail.found())
            with open(log_path, "a", encoding="utf-8") as fh:
                fh.write(
                    "2026-01-01T00:00:02.500Z,2.5,100,6,Info [FLog::QuickSignInUtil] Starting awaitQuickSignIn via polling: code=ABCDEF\n"
                    '2026-01-01T00:00:03.000Z,3.0,100,6 [FLog::CreatorOutput] [sert-verdict] {"ok":true}\n'
                    "2026-01-01T00:00:04.000Z,4.0,100,6 [FLog::Output] About to exit the application\n"
                )
            self.assertTrue(signin_tail.found() and tail.found() and runscript.clean_exit(log_path))

    def test_windows_unmarked_studio_safety_and_warm_bridge(self):
        # Checklist 6a: unmarked Windows Studio processes (`4244`) MUST NEVER be matched or killed!
        cim_csv = (
            '"ProcessId","CommandLine"\r\n'
            '"4242","""C:\\Roblox\\RobloxStudioBeta.exe"" -task RunScript -outputFile C:\\stage\\run1\\output.log"\r\n'
            '"4243","""C:\\Roblox\\RobloxStudioBeta.exe"" -task RunScript -outputFile C:\\stage\\run2\\output.log"\r\n'
            '"4244",""\r\n'
        )
        with mock.patch.object(runscript.os, "name", "nt"):
            with mock.patch("subprocess.run", return_value=subprocess.CompletedProcess(["powershell"], 0, stdout=cim_csv, stderr="")):
                win_table = runscript.process_table()
            assert win_table is not None
            self.assertEqual(win_table[4244], "RobloxStudioBeta.exe")
            self.assertEqual(runscript.studio_processes(win_table, ("run1", "output.log")), {4242})
            self.assertNotIn(4244, runscript.studio_processes(win_table, ("run1", "output.log")))
            self.assertNotIn(4243, runscript.studio_processes(win_table, ("run1", "output.log")))

            # Verify child cleanup on Windows calls `taskkill /F /T /PID <child.pid>` on child only
            win_child = mock.MagicMock(pid=7777)
            win_child.poll.return_value = None
            with mock.patch("subprocess.run") as tk_mock:
                runscript._kill_child_tree(win_child)
            tk_mock.assert_called_once()
            self.assertEqual(tk_mock.call_args[0][0], ["taskkill", "/F", "/T", "/PID", "7777"])

        # Test `--warm` live Studio bridge execution
        with tempfile.TemporaryDirectory() as tmp:
            report = os.path.join(tmp, "warm_report.json")
            bridge = os.path.join(tmp, "studio_link.py")
            with open(bridge, "w", encoding="utf-8") as fh:
                fh.write("# fake bridge\n")

            fake_out = json.dumps(
                {
                    "ok": True,
                    "output": '[sert-done] {"passed":1,"failed":0,"total":1}\n',
                    "result": {"ok": True, "value": {"passed": 1, "failed": 0}},
                }
            )
            with (
                mock.patch.dict(os.environ, {"SERT_STUDIO_BRIDGE": bridge}),
                mock.patch("subprocess.run", return_value=subprocess.CompletedProcess(["py"], 0, stdout=fake_out, stderr="")) as bridge_run,
                mock.patch("sys.stdout", io.StringIO()),
                mock.patch("sys.stderr", io.StringIO()),
            ):
                rc = runscript.run("p.rbxl", mode="play", report=report, args={"runId": "r1"}, warm=True, studio_id="my-studio")
            self.assertEqual(rc, 0)
            cmd_called = bridge_run.call_args[0][0]
            self.assertIn("--studio", cmd_called)
            self.assertIn("my-studio", cmd_called)
            written = json.loads(Path(report).read_text(encoding="utf-8"))
            self.assertEqual((written["exitCode"], written["status"]), (0, "passed"))

            # Portable warm bridge resolution: never probes `~/.agents/...`, honors explicit bridge param.
            with (
                mock.patch.dict(os.environ, {}, clear=True),
                mock.patch("shutil.which", return_value=None),
            ):
                self.assertIsNone(runscript.find_studio_link())
                self.assertEqual(runscript.find_studio_link(bridge), [sys.executable, bridge])

            # Warm driver readiness handshake & verdict settle loop (edit + play)
            warm_play = runscript.build_warm_driver(
                runscript.Options("p.rbxl", "play", warm=True, runner_path=["ReplicatedStorage", "sert", "roblox", "Runner"])
            )
            self.assertIn("warm Studio readiness check failed", warm_play)
            self.assertIn("while not verdictSeen and os.clock() < settleDeadline", warm_play)
            warm_edit = runscript.build_warm_driver(runscript.Options("p.rbxl", "edit", script="print(1)", warm=True))
            self.assertIn("while not verdictSeen and os.clock() < settleDeadline", warm_edit)

            # Orphaned `roblox-testing/*` stage sweep preserves `.sert-kept` & active PIDs, deletes dead orphans
            stage_base = os.path.join(tmp, "roblox-testing")
            orphan = os.path.join(stage_base, "20260101-000000-999999-abcd")
            kept = os.path.join(stage_base, "20260101-000000-999998-ef01")
            live = os.path.join(stage_base, f"20260101-000000-{os.getpid()}-2345")
            for d in (orphan, kept, live):
                os.makedirs(d)
            with open(os.path.join(kept, ".sert-kept"), "w", encoding="utf-8") as fh:
                fh.write("kept\n")
            swept = runscript.sweep_orphaned_stages(stage_base, active_table={})
            self.assertEqual(swept, [orphan])
            self.assertFalse(os.path.exists(orphan))
            self.assertTrue(os.path.exists(kept) and os.path.exists(live))

            # Crash outcome includes 40-line launcher/Studio log tails
            crash_stage = os.path.join(tmp, "crash-stage")
            os.makedirs(crash_stage)
            crash_log = os.path.join(tmp, "crash_studio.log")
            with open(crash_log, "w", encoding="utf-8") as fh:
                fh.write("studio boom line\n")
            fake_child = mock.MagicMock(pid=42)
            fake_child.poll.return_value = 1

            def fake_popen(argv, **kwargs):
                log_fh = kwargs.get("stdout")
                if log_fh is not None:
                    log_fh.write(("\n".join(f"launch line {i}" for i in range(50)) + "\n").encode("utf-8"))
                    log_fh.flush()
                return fake_child

            opts_cold = runscript.Options(os.path.join(tmp, "p.rbxl"), "play", launcher="my-studio")
            with (
                mock.patch("subprocess.Popen", side_effect=fake_popen),
                mock.patch.object(runscript, "LAUNCH_ERROR_GRACE", 0.0),
                mock.patch.object(runscript, "process_table", return_value={}),
                mock.patch.object(runscript, "find_studio_log", return_value=crash_log),
            ):
                outcome = runscript.run_attempt(opts_cold, crash_stage, "run-c", opts_cold.place, "drv.luau", "")
            self.assertEqual(outcome.code, runscript.INFRA)
            self.assertIn("launch line 49", outcome.message)
            self.assertIn("launch line 10", outcome.message)
            self.assertNotIn("launch line 5\n", outcome.message)
            self.assertIn("studio boom line", outcome.message)

            # Linux native `vinegar` launcher detection & wine path support + Windows wmic fallback
            with (
                mock.patch.object(runscript.os.path, "isdir", return_value=False),
                mock.patch.object(runscript.shutil, "which", side_effect=lambda b: "/usr/bin/vinegar" if b == "vinegar" else None),
            ):
                nat_launcher, nat_err = runscript.default_launcher(platform="linux")
            self.assertEqual((nat_launcher, nat_err), ("vinegar studio run", None))
            self.assertTrue(runscript.uses_wine_paths(runscript.Options("p.rbxl", "play", launcher="vinegar studio run")))
            wmic_csv = "Node,CommandLine,ProcessId\r\nHOST,RobloxStudioBeta.exe -outputFile C:\\s\\out.log,5151\r\n"
            self.assertEqual(runscript.parse_wmic_processes(wmic_csv), {5151: "RobloxStudioBeta.exe -outputFile C:\\s\\out.log"})

            # Windows `_pid_alive` uses `_win_pid_alive` (not Studio-only `active_table` or `os.kill(pid, 0)`)
            win_base = os.path.join(tmp, "win-stages")
            win_live_py = os.path.join(win_base, "20260101-000000-44444-aaaa")
            win_dead_py = os.path.join(win_base, "20260101-000000-55555-bbbb")
            os.makedirs(win_live_py)
            os.makedirs(win_dead_py)
            with (
                mock.patch.object(runscript.os, "name", "nt"),
                mock.patch.object(runscript, "_win_pid_alive", side_effect=lambda p: p == 44444),
                mock.patch.object(runscript.os, "kill", side_effect=AssertionError("os.kill must not run on Windows")) as kill_mock,
            ):
                win_swept = runscript.sweep_orphaned_stages(win_base, active_table={})
            self.assertEqual(kill_mock.call_count, 0)
            self.assertEqual(win_swept, [win_dead_py])
            self.assertTrue(os.path.isdir(win_live_py))
            self.assertFalse(os.path.exists(win_dead_py))


if __name__ == "__main__":
    unittest.main()
