import io, itertools, json, os, shutil, signal, subprocess, sys, tempfile, threading, types, unittest
from unittest import mock

import helpers  # noqa: F401
from sert import util
from sert.studio import runscript
from sert.util import SertError, luau_string


class DriverAndOptionsTest(unittest.TestCase):
    def test_generated_driver_public_names_and_options(self):
        source = runscript.build_driver(runscript.Options("p.rbxl", "play", args_json='{"a":1}'))
        for want in ('local SENTINEL = "[sert-verdict]"', 'local ARGS_JSON = "{\\"a\\":1}"', "local PRELUDE = nil",
                     "ExecutePlayModeAsync", "task.wait(2)", 'pcall(workspace.SetAttribute, workspace, "sert_Args", ARGS_JSON)',
                     'pcall(workspace.SetAttribute, workspace, "sert_Args", nil)', "task.wait(1)", "the session's value is not JSON-encodable"):
            self.assertIn(want, source)
        run_src = runscript.build_driver(runscript.Options("p.rbxl", "run", prelude="workspace.Gravity = 0"))
        self.assertTrue("ExecuteRunModeAsync" in run_src and 'local PRELUDE = "workspace.Gravity = 0"' in run_src)
        script = 'print("[sert-verdict] {\\"passed\\":true}")\n'
        self.assertEqual(runscript.build_driver(runscript.Options("p.rbxl", "edit", script=script)), script)

        for name in ("reports_failure", "run", "strip_echo", "last_result_line", "creator_output", "collect_output", "run_attempt", "stop_run", "Outcome"):
            self.assertTrue(hasattr(runscript, name), name)
        for name in ("main", "build_parser", "DEFAULT_SENTINEL", "SCRIPT_TEMPLATE"):
            self.assertFalse(hasattr(runscript, name), name)

        done = subprocess.run([sys.executable, "-m", "sert.studio.runscript", "--help"], capture_output=True, text=True, env=dict(os.environ, PYTHONPATH=str(helpers.PYTHON)))
        self.assertEqual(done.stdout, "")

        for given, message in (
            ({"mode": "debug"}, "unknown mode 'debug'"), ({"mode": "edit"}, "edit mode runs a script"),
            ({"mode": "play", "script": "x"}, "edit mode runs a script"), ({"mode": "play", "timeout": 0}, "--timeout must be finite and positive"),
            ({"mode": "play", "timeout": float("inf")}, "--timeout must be finite and positive"),
            ({"mode": "play", "args": {"budget": float("nan")}}, "the request is not JSON"),
            ({"mode": "play", "launcher": "   "}, "--launcher is empty"), ({"mode": "play", "launcher": '"unclosed'}, "--launcher:"),
        ):
            kw = {"script": None, "args": None, "prelude": None, "timeout": 300.0, "keep": False, "launcher": None, **given}
            mode = kw.pop("mode")
            with self.assertRaisesRegex(SertError, message):
                runscript.options("p.rbxl", mode, **kw)
            with self.assertRaisesRegex(SertError, message):
                runscript.run("p.rbxl", mode=mode, report="r.json", **kw)
        opts = runscript.options("p.rbxl", "run", script=None, args={"k": 1}, prelude=None, timeout=5.0, keep=True, launcher="studio")
        self.assertEqual((opts.mode, opts.args_json, opts.timeout, opts.keep), ("run", '{"k": 1}', 5.0, True))
        self.assertEqual(runscript.options("p.rbxl", "play", script=None, args=None, prelude=None, timeout=1.0, keep=False, launcher=None).args_json, "{}")

        f = runscript.reports_failure
        for v in (False, {"ok": False}, {"failed": 2}, {"passed": 0, "failed": 0}, {"passed": 1.5, "failed": 0},
                  {"ok": True, "value": {"value": {"passed": False}}},
                  {"ok": True, "value": {"passed": False, "failed": 0, "counts": {"passed": 0, "failed": 0}}},
                  {"ok": True, "value": {"passed": True, "failed": 1}}):
            self.assertTrue(f(v))
        for v in ({"ok": True, "value": {"passed": 3, "failed": 0}}, {"passed": True},
                  {"ok": True, "value": {"passed": True, "failed": 0, "counts": {"passed": 3, "failed": 0}}}, "anything"):
            self.assertFalse(f(v))


class OutputProcessAndAttemptTest(unittest.TestCase):
    def test_output_staging_launcher_and_logs(self):
        self.assertEqual(runscript.last_result_line('[sert-verdict] {"a":1}\nnoise\n[sert-done] {"b":1}\n[sert-verdict] {"a":2}\n'), '{"a":2}')
        self.assertIsNone(runscript.last_result_line("[sert-done] {}\n"))
        self.assertEqual(runscript.strip_echo("before\n> print(1)\nprint(2)\n\nafter\n", "print(1)\nprint(2)\n"), "before\nafter\n")
        self.assertEqual(runscript.strip_echo("before\n> print(1)\nprint(2)\n\nafter\n", "print(1)   \nprint(2)   \n"), "before\nafter\n")
        self.assertEqual(runscript.strip_echo("no echo here\n", "print(1)\n"), "no echo here\n")
        self.assertEqual((luau_string('a"b\\\n\r\t'), luau_string("é")), ('"a\\"b\\\\\\n\\r\\t"', '"\\u{E9}"'))

        with tempfile.TemporaryDirectory() as tmp:
            buf = io.StringIO()
            with mock.patch("sys.stderr", buf):
                runscript.say("shown")
            self.assertEqual(buf.getvalue(), "sert studio: shown\n")

            opts_q = runscript.Options(os.path.join(tmp, "p.rbxl"), "play", args_json='{"x":1}', prelude="workspace.Gravity = 100\n")
            with open(opts_q.place, "wb") as fh: fh.write(b"place-bytes")
            place_out, driver_out, driver_src = runscript.stage_files(opts_q, os.path.join(tmp, "stage1"))
            self.assertTrue(os.path.isfile(place_out) and os.path.isfile(driver_out) and "workspace.Gravity = 100" in driver_src)
            self.assertEqual(runscript.launcher_prefix(opts_q), ["flatpak", "run", runscript.VINEGAR_APP])
            self.assertTrue(runscript.studio_path(opts_q, "/tmp/a/b").startswith("Z:\\") and runscript.VINEGAR_APP in runscript.stage_root(opts_q))

            exe_file = os.path.join(tmp, "My Studio.exe")
            open(exe_file, "w").close()
            opts_exe = types.SimpleNamespace(launcher=exe_file)
            self.assertEqual((runscript.launcher_prefix(opts_exe), runscript.studio_path(opts_exe, exe_file), runscript.vinegar_problem(opts_exe)),
                             ([exe_file], os.path.abspath(exe_file), None))
            self.assertIn("roblox-testing", runscript.stage_root(opts_exe))
            self.assertEqual(runscript.launcher_prefix(types.SimpleNamespace(launcher="xvfb-run -a studio")), ["xvfb-run", "-a", "studio"])
            with mock.patch.object(runscript.os, "name", "nt"):
                self.assertEqual(runscript.launcher_prefix(types.SimpleNamespace(launcher='"C:\\Program Files\\Studio.exe" --flag')), ["C:\\Program Files\\Studio.exe", "--flag"])
            with mock.patch("shutil.which", return_value=None):
                self.assertIn("flatpak is not installed", runscript.vinegar_problem(opts_q))
            with mock.patch("shutil.which", return_value="/usr/bin/flatpak"), mock.patch("os.path.isdir", return_value=False):
                self.assertIn("does not exist", runscript.vinegar_problem(opts_q))
            with mock.patch("shutil.which", return_value="/usr/bin/flatpak"), mock.patch("os.path.isdir", return_value=True):
                self.assertIsNone(runscript.vinegar_problem(opts_q))

            opts_v, opts_l = types.SimpleNamespace(launcher=None), types.SimpleNamespace(launcher="studio")
            with mock.patch.dict(os.environ, {"LOCALAPPDATA": tmp}), mock.patch("os.path.isdir", return_value=True):
                self.assertEqual(len(runscript.studio_log_dirs(opts_v)), 1)
                self.assertIn(os.path.join(tmp, "Roblox", "logs"), runscript.studio_log_dirs(opts_l))
            logs = os.path.join(tmp, "drive_c", "users", "jo", "AppData", "Local", "Roblox", "logs")
            os.makedirs(logs)
            with mock.patch.dict(os.environ, {"WINEPREFIX": tmp}), mock.patch("getpass.getuser", return_value="jo"), mock.patch.object(runscript, "platform_name", return_value="linux"):
                self.assertTrue(logs in runscript.studio_log_dirs(opts_l) and logs not in runscript.studio_log_dirs(opts_v))
            with mock.patch("getpass.getuser", side_effect=OSError("no user")):
                self.assertIsNone(runscript.wine_logs())

            self.assertEqual((runscript.read_text(os.path.join(tmp, "missing.txt")), runscript.file_size(os.path.join(tmp, "missing.txt"))), ("", 0))
            log_path = os.path.join(tmp, "studio_01.log")
            with open(log_path, "w", encoding="utf-8") as fh:
                fh.write("2026-01-01T00:00:00.000Z,0.1,100,6 [FLog::Output] Command line: run1 output.log\n"
                         "2026-01-01T00:00:01.000Z,1.1,100,6 [FLog::CreatorOutput] hello world\ncontinuation line\n"
                         "2026-01-01T00:00:01.500Z,1.5,100,6 [FLog::CreatorWarning] Warning: careful\n"
                         "2026-01-01T00:00:02.000Z,2.0,100,6 [FLog::CreatorError] bad error\n")
            self.assertEqual(runscript.find_studio_log([tmp, os.path.join(tmp, "no_dir")], ("run1", "output.log"), 0.0), log_path)
            self.assertFalse(runscript.clean_exit(log_path) or runscript.clean_exit(os.path.join(tmp, "missing.log")))
            tail = runscript.LogTail(log_path, b"[FLog::CreatorOutput] [sert-verdict] ")
            self.assertFalse(tail.found() or tail.found())
            with open(log_path, "a", encoding="utf-8") as fh:
                fh.write('2026-01-01T00:00:03.000Z,3.0,100,6 [FLog::CreatorOutput] [sert-verdict] {"ok":true}\n'
                         "2026-01-01T00:00:04.000Z,4.0,100,6 [FLog::Output] About to exit the application\n")
            self.assertTrue(tail.found() and runscript.clean_exit(log_path))
            self.assertIn('hello world\ncontinuation line\ncareful\nbad error\n[sert-verdict] {"ok":true}\n', runscript.creator_output(log_path))

            with mock.patch("sert.studio.runscript.file_size", side_effect=[10, 20, 20, 20, 20]), mock.patch("time.monotonic", side_effect=itertools.count(0.0, 0.4)), mock.patch("time.sleep"):
                runscript.settle(log_path, quiet=2.0, limit=10.0)
            out_path = os.path.join(tmp, "output.log")
            with open(out_path, "w", encoding="utf-8") as fh: fh.write("[sert-verdict] {truncated\n")
            with mock.patch("sert.studio.runscript.settle"), mock.patch("sys.stderr", io.StringIO()):
                self.assertEqual(runscript.last_result_line(runscript.collect_output(out_path, log_path, "print(1)\n")), '{"ok":true}')
            with open(os.path.join(tmp, "launcher.out"), "w", encoding="utf-8") as fh: fh.write("line 1\nline 2\n")
            self.assertIn("launcher output:\n  line 1\n  line 2", runscript.launcher_tail(tmp))

    def test_process_table_termination_and_run_attempt(self):
        self.assertIsInstance(runscript.process_table(), dict)
        with mock.patch.object(runscript.os, "name", "posix"), mock.patch("os.path.isdir", return_value=False), mock.patch("shutil.which", return_value="/bin/ps"):
            cp = subprocess.CompletedProcess(["ps"], 0, stdout="  101 RobloxStudioBeta.exe -task RunScript\n  102 bash\n", stderr="")
            with mock.patch("subprocess.run", return_value=cp):
                self.assertEqual(runscript.process_table(), {101: "RobloxStudioBeta.exe -task RunScript", 102: "bash"})
            with mock.patch("subprocess.run", side_effect=OSError("no ps")):
                self.assertIsNone(runscript.process_table())

        fake_table = {5001: "RobloxStudioBeta.exe Z:\\stage\\run1\\output.log", 5002: "RobloxStudioBeta.exe Z:\\stage\\other\\output.log", 5003: "python3"}
        self.assertEqual((runscript.studio_processes(fake_table), runscript.studio_processes(fake_table, ("run1", "output.log"))), ({5001, 5002}, {5001}))
        with mock.patch("os.kill", side_effect=OSError("no such process")):
            runscript.signal_pid(999999, signal.SIGTERM)

        child = mock.MagicMock(pid=6001)
        child.poll.side_effect = [None, None, None]
        child.wait.side_effect = subprocess.TimeoutExpired(cmd="studio", timeout=0.1)
        with mock.patch("sert.studio.runscript.process_table", return_value=fake_table), mock.patch("sert.studio.runscript.signal_pid"), mock.patch("time.monotonic", side_effect=itertools.count(0.0, 3.0)), mock.patch("time.sleep"):
            runscript.terminate([5001], ("run1",), child=child)
            self.assertTrue(child.terminate.called and child.kill.called)

        attempt = runscript.Attempt(child, ("run1", "output.log"), set())
        attempt.tracked.add(5001)
        child.poll.side_effect = None
        child.poll.return_value = None
        with mock.patch("sert.studio.runscript.process_table", return_value=fake_table), mock.patch("sert.studio.runscript.terminate"):
            self.assertEqual(runscript.stop(types.SimpleNamespace(launcher="studio"), attempt), ["Studio pid 5001", "launcher pid 6001"])

        opts_v = types.SimpleNamespace(launcher=None, timeout=300.0)
        marker = runscript.run_marker(opts_v, "/tmp/stage/run1")
        with mock.patch("sert.studio.runscript.process_table", return_value={7001: f"RobloxStudioBeta.exe {marker[0]}place.rbxl"}), mock.patch("sert.studio.runscript.terminate"), mock.patch("sys.stderr", io.StringIO()):
            self.assertEqual(runscript.stop_strays(opts_v, "/tmp/stage/run1"), ["Studio pid 7001"])

        with tempfile.TemporaryDirectory() as tmp, mock.patch("sys.stderr", io.StringIO()):
            opts = types.SimpleNamespace(launcher="studio", timeout=10.0)
            place, drv, out_log = os.path.join(tmp, "place.rbxl"), os.path.join(tmp, "driver.luau"), os.path.join(tmp, "output.log")
            with mock.patch("sert.studio.runscript.process_table", return_value={}), mock.patch("subprocess.Popen", side_effect=OSError("exec failed")):
                self.assertEqual(runscript.run_attempt(opts, tmp, "run1", place, drv, "print(1)\n").code, 2)

            fake_child = mock.MagicMock(pid=1234)
            fake_child.poll.return_value = 0
            for text, want_code, want_status in (
                ('[sert-verdict] {"ok":true,"value":{"passed":2,"failed":0}}\n', 0, "passed"),
                ("[sert-verdict] {not-json\n", 2, "error"),
            ):
                with open(out_log, "w", encoding="utf-8") as fh: fh.write(text)
                with mock.patch("sert.studio.runscript.process_table", return_value={}), mock.patch("subprocess.Popen", return_value=fake_child), mock.patch("sert.studio.runscript.find_studio_log", return_value=None), mock.patch("time.sleep"):
                    res = runscript.run_attempt(opts, tmp, "run1", place, drv, "print(1)\n")
                    self.assertEqual((res.code, res.status), (want_code, want_status))

            with open(out_log, "w", encoding="utf-8") as fh: fh.write("no verdict\n")
            crash_log = os.path.join(tmp, "crash.log")
            with open(crash_log, "w", encoding="utf-8") as fh: fh.write("started\n")
            with mock.patch("sert.studio.runscript.process_table", return_value={}), mock.patch("subprocess.Popen", return_value=fake_child), mock.patch("sert.studio.runscript.find_studio_log", return_value=crash_log), mock.patch("sert.studio.runscript.settle"), mock.patch("time.sleep"):
                self.assertIn("without its shutdown line", runscript.run_attempt(opts, tmp, "run1", place, drv, "print(1)\n").message)

            os.remove(out_log)
            running_child = mock.MagicMock(pid=2222)
            running_child.poll.return_value = None
            with mock.patch("sert.studio.runscript.process_table", return_value={}), mock.patch("subprocess.Popen", return_value=running_child), mock.patch("sert.studio.runscript.find_studio_log", return_value=None), mock.patch("sert.studio.runscript.stop", return_value=["launcher pid 2222"]), mock.patch("time.monotonic", side_effect=[0.0, 100.0, 101.0]), mock.patch("time.sleep"):
                self.assertEqual(runscript.run_attempt(opts, tmp, "run1", place, drv, "print(1)\n").code, 3)

            exited_child = mock.MagicMock(pid=3333)
            exited_child.poll.return_value = 1
            with mock.patch("sert.studio.runscript.process_table", return_value={}), mock.patch("subprocess.Popen", return_value=exited_child), mock.patch("sert.studio.runscript.find_studio_log", return_value=None), mock.patch("time.monotonic", side_effect=[0.0, 1.0, 20.0]), mock.patch("time.sleep"):
                self.assertIn("Studio did not start", runscript.run_attempt(opts_v, tmp, "run1", place, drv, "print(1)\n").message)

            slog = os.path.join(tmp, "studio_grace.log")
            with open(slog, "w", encoding="utf-8") as fh: fh.write('2026-01-01T00:00:01.000Z,1.0,100,6 [FLog::CreatorOutput] [sert-verdict] {"ok":true}\n')
            with mock.patch("sert.studio.runscript.process_table", side_effect=[{}, {8001: "RobloxStudioBeta.exe run1 output.log"}, {8001: "RobloxStudioBeta.exe run1 output.log"}]), mock.patch("subprocess.Popen", return_value=exited_child), mock.patch("sert.studio.runscript.find_studio_log", return_value=slog), mock.patch("sert.studio.runscript.stop", return_value=["Studio pid 8001"]), mock.patch("time.monotonic", side_effect=[0.0, 1.0, 70.0, 71.0, 72.0, 73.0]), mock.patch("sert.studio.runscript.settle"), mock.patch("time.sleep"):
                out7 = runscript.run_attempt(opts_v, tmp, "run1", place, drv, "print(1)\n")
                self.assertEqual((out7.code, "had not quit" in out7.message), (0, True))


class RunAndPlatformTest(unittest.TestCase):
    def test_run_platform_and_tasklist(self):
        with tempfile.TemporaryDirectory() as tmp:
            place, report = os.path.join(tmp, "test.rbxl"), os.path.join(tmp, "report.json")
            with open(place, "wb") as fh: fh.write(b"rbxl")
            seen = {}
            def fake_attempt(opts, stage, run_id, pl, drv, drv_src):
                seen.update(stage=stage, driver=drv_src, launcher=opts.launcher)
                return runscript.Outcome(0, "passed", "ok", result={"ok": True}, output="ok line\n")

            with mock.patch.object(runscript, "run_attempt", fake_attempt), mock.patch.object(runscript, "stop_strays", return_value=[]), mock.patch("sys.stdout", io.StringIO()), mock.patch("sys.stderr", io.StringIO()):
                self.assertEqual(runscript.run(place, mode="play", report=report, args={"k": 1}, launcher="echo", keep=True), 0)
            written = json.loads(runscript.read_text(report))
            self.assertEqual((written["exitCode"], written["status"], written["output"], written["stageDir"]), (0, "passed", "ok line\n", seen["stage"]))
            shutil.rmtree(written["stageDir"], ignore_errors=True)

            with mock.patch.object(runscript, "run_attempt", side_effect=KeyboardInterrupt), mock.patch.object(runscript, "stop_strays", return_value=[]), mock.patch.object(runscript, "stop_run", return_value=[]), mock.patch("sys.stderr", io.StringIO()):
                self.assertEqual(runscript.run(place, mode="run", report=report, launcher="echo"), 130)
            with self.assertRaises(KeyboardInterrupt):
                util.interrupt(signal.SIGTERM, None)

            with mock.patch.object(runscript, "vinegar_problem", return_value="no vinegar"), mock.patch.object(runscript, "default_launcher", return_value=(None, None)), mock.patch("sys.stderr", io.StringIO()):
                self.assertEqual(runscript.run(place, mode="play", report=report), 2)
            with mock.patch.object(runscript, "stop_strays", return_value=[]), mock.patch("sys.stderr", io.StringIO()):
                self.assertEqual(runscript.run(os.path.join(tmp, "missing.rbxl"), mode="play", report=report, launcher="echo"), 2)
            with mock.patch.object(runscript, "run_attempt", return_value=runscript.Outcome(0, "passed", "ok", result={"ok": True})), mock.patch.object(runscript, "stop_strays", return_value=[]), mock.patch("sys.stderr", io.StringIO()):
                self.assertEqual(runscript.run(place, mode="play", report=os.path.join(tmp, "no_dir/r.json"), launcher="echo"), 2)

            self.assertEqual([runscript.platform_name(p) for p in ("linux", "win32", "darwin", "freebsd14")], ["linux", "windows", "macos", "linux"])
            self.assertEqual(runscript.default_launcher("linux"), (None, None))
            self.assertIsNone(runscript.default_launcher("win32", local_appdata=tmp)[0])
            old = os.path.join(tmp, "Roblox", "Versions", "version-old", "RobloxStudioBeta.exe")
            new = os.path.join(tmp, "Roblox", "Versions", "version-new", "RobloxStudioBeta.exe")
            for idx, p in enumerate((old, new)):
                os.makedirs(os.path.dirname(p))
                open(p, "w").close()
                os.utime(p, (1000 + idx, 1000 + idx))
            self.assertEqual(runscript.default_launcher("win32", local_appdata=tmp), (new, None))
            with mock.patch("os.path.isfile", return_value=True):
                self.assertEqual(runscript.default_launcher("darwin"), (runscript.MAC_STUDIO, None))
            with mock.patch("os.path.isfile", return_value=False):
                self.assertIsNone(runscript.default_launcher("darwin")[0])

            with mock.patch.object(runscript, "default_launcher", return_value=("/Apps/Studio", None)), mock.patch.object(runscript, "run_attempt", fake_attempt), mock.patch.object(runscript, "stop_strays", return_value=[]), mock.patch("sys.stderr", io.StringIO()):
                self.assertEqual((runscript.run(place, mode="play", report=report), seen["launcher"]), (0, "/Apps/Studio"))

            before = signal.getsignal(signal.SIGTERM)
            with mock.patch.object(runscript, "vinegar_problem", return_value="no vinegar"), mock.patch.object(runscript, "default_launcher", return_value=(None, None)), mock.patch("sys.stderr", io.StringIO()):
                res_t = {}
                t = threading.Thread(target=lambda: res_t.update(code=runscript.run("p.rbxl", mode="play", report=report)))
                t.start()
                t.join()
            self.assertEqual((res_t["code"], signal.getsignal(signal.SIGTERM)), (2, before))

        sample = '"System Idle Process","0","Services","0","8 K"\r\n"RobloxStudioBeta.exe","4242","Console","1","812,004 K"\r\nINFO: noise\r\n'
        self.assertEqual((runscript.parse_tasklist(sample), runscript.parse_tasklist("")), ({0: "System Idle Process", 4242: "RobloxStudioBeta.exe"}, {}))
        cim_csv = (
            '"ProcessId","CommandLine"\r\n'
            '"4242","""C:\\Roblox\\RobloxStudioBeta.exe"" -task RunScript -outputFile C:\\stage\\run1\\output.log"\r\n'
            '"4243","""C:\\Roblox\\RobloxStudioBeta.exe"" -task RunScript -outputFile C:\\stage\\run2\\output.log"\r\n'
            '"4244",""\r\n'
        )
        with mock.patch.object(runscript.os, "name", "nt"):
            with mock.patch("subprocess.run", return_value=subprocess.CompletedProcess(["powershell"], 0, stdout=cim_csv, stderr="")):
                win_table = runscript.process_table()
            self.assertEqual(win_table[4244], "RobloxStudioBeta.exe")
            self.assertIn("run1\\output.log", win_table[4242])
            self.assertEqual(runscript.studio_processes(win_table, ("run1", "output.log")), {4242, 4244})
            self.assertEqual(runscript.studio_processes(win_table, ("run1", "output.log"), allow_unmarked=False), {4242})
            self.assertNotIn(4243, runscript.studio_processes(win_table, ("run1", "output.log")))
            with mock.patch("subprocess.run", side_effect=[
                subprocess.CompletedProcess(["powershell"], 1, stdout="", stderr="err"),
                subprocess.CompletedProcess(["tasklist"], 0, stdout=sample, stderr=""),
            ]):
                self.assertEqual(runscript.process_table()[4242], "RobloxStudioBeta.exe")
            with mock.patch("subprocess.run", side_effect=OSError("x")):
                self.assertIsNone(runscript.process_table())


if __name__ == "__main__":
    unittest.main()
