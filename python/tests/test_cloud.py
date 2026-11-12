"""Unit tests for `sert.cloud`: parallel shards via ThreadPoolExecutor, `:cancel` cleanup on timeout/interrupt, log deduplication, and zero-boilerplate synthesis."""

from __future__ import annotations

import contextlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import io
import json
import os
import pathlib
import shutil
import subprocess
import sys
import tempfile
import threading
import time
import types
import unittest
import urllib.error
import urllib.parse
from unittest import mock

import helpers  # noqa: F401
from helpers import REPO
from sert import cli, cloud, util
from sert.util import SertError

KEY = "test-key-1234567890"
SHARDS = [{"name": "local", "only": ["parity.", "measure.json"]}, {"name": "store", "only": ["suite.store"]}, {"name": "rest"}]


class ShardAndClassifyTest(unittest.TestCase):
    def test_shards_inject_and_classify(self):
        shards = cloud.normalize_shards(SHARDS)
        self.assertEqual(
            cloud.shard_info(shards, 0, 120),
            {"name": "local", "index": 1, "count": 3, "runLimit": 120, "only": ["parity.", "measure.json"]},
        )
        self.assertEqual(cloud.shard_info(shards, 2, 120)["except"], ["parity.", "measure.json", "suite.store"])
        self.assertNotIn("except", cloud.shard_info(cloud.normalize_shards(["a", "b"]), 1, 60))

        for bad in (["a", "a"], [{"only": ["x"]}], [{"name": "a", "only": ["x"], "except": ["y"]}], [{"name": "a", "except": "x"}], [{"name": "a", "onyl": ["x"]}], "a"):
            with self.assertRaises(SertError):
                cloud.normalize_shards(bad)

        info = cloud.shard_info(shards, 2, 120)
        source = "--!strict\n--!optimize 2\n-- a comment\nlocal x = 1\nerror('line 5')\n"
        lines = cloud.inject_shard(source, info).split("\n")
        self.assertEqual((len(lines), lines[:2], lines[4]), (len(source.split("\n")), ["--!strict", "--!optimize 2"], "error('line 5')"))
        self.assertTrue('except = { "parity.", "measure.json", "suite.store" }' in lines[2] and lines[2].endswith('pcall(rawset, _G, "__SERT_SHARD", SERT_SHARD_INFO) -- a comment'))

        for task, logs, want in (
            ({"state": "COMPLETE"}, [], 0),
            ({"state": "COMPLETE", "output": {"results": [{"failed": 2}]}}, [], 1),
            ({"state": "COMPLETE"}, ['[sert-done] {"passed": 1, "failed": 1}'], 1),
            ({"state": "FAILED", "error": {"code": "SCRIPT_ERROR", "message": "x"}}, [], 1),
            ({"state": "FAILED", "error": {"code": "DEADLINE_EXCEEDED"}}, [], 3),
            ({"state": "FAILED", "error": {"code": "INTERNAL_ERROR"}}, [], 2),
            ({"state": "CANCELLED"}, [], 2),
        ):
            self.assertEqual(cloud.classify(task, logs)[0], want)

        self.assertAlmostEqual(
            cloud.task_seconds({"createTime": "2026-10-11T10:00:00.123456789Z", "updateTime": "2026-10-11T10:02:30.623Z"}),
            150.5,
            places=3,
        )


class FakeCloud:
    def __init__(self):
        self.scripts, self.uploads, self.fail_create, self.cancelled = [], [], [], []
        self.keys, self.polls, self.lock = set(), {}, threading.Lock()
        self.active_polls = 0
        self.max_concurrent_polls = 0

    def handle(self, handler, method):
        url = urllib.parse.urlsplit(handler.path)
        self.keys.add(handler.headers.get("x-api-key"))
        length = int(handler.headers.get("Content-Length") or 0)
        body = handler.rfile.read(length) if length else b""
        if method == "POST" and url.path == "/universes/v1/1/places/2/versions":
            self.uploads.append((url.query, handler.headers.get("Content-Type"), len(body)))
            return 200, {"versionNumber": 7}
        if method == "POST" and url.path == "/cloud/v2/universes/1/places/2/versions/7/luau-execution-session-tasks":
            with self.lock:
                if self.fail_create:
                    return self.fail_create.pop(0), {"message": f"nope {KEY}"}
                self.scripts.append(json.loads(body))
                number = len(self.scripts)
            return 200, {"path": f"universes/1/places/2/versions/7/luau-execution-sessions/s/tasks/t{number}", "state": "QUEUED"}
        if method == "POST" and url.path.endswith(":cancel"):
            with self.lock:
                self.cancelled.append(url.path)
            return 200, {"state": "CANCELLED"}
        prefix = "/cloud/v2/universes/1/places/2/versions/7/luau-execution-sessions/s/tasks/t"
        if method == "GET" and url.path.startswith(prefix):
            rest = url.path[len(prefix) :]
            number = int(rest.split("/")[0])
            script = self.scripts[number - 1]["script"]
            if rest.endswith("/logs"):
                if "pageToken" not in urllib.parse.parse_qs(url.query):
                    # Include BOTH `structuredMessages` AND duplicate `messages` to verify deduplication!
                    msg_text = f"ran {script.split(chr(10))[0][:40]}"
                    return 200, {
                        "luauExecutionSessionTaskLogs": [
                            {
                                "structuredMessages": [{"messageType": "OUTPUT", "message": msg_text}],
                                "messages": [msg_text, "extra-flat-only"],
                            }
                        ],
                        "nextPageToken": "p2",
                    }
                lines = ['[sert-done] {"passed": 1, "failed": 1}'] if ("FAILTEST" in script and '"store"' in script) else ['[sert-done] {"passed": 1, "failed": 0}']
                return 200, {
                    "luauExecutionSessionTaskLogs": [
                        {
                            "structuredMessages": [{"messageType": "WARNING", "message": "careful"}]
                            + [{"messageType": "OUTPUT", "message": line} for line in lines],
                            "messages": ["careful", *lines],
                        }
                    ]
                }
            path = f"universes/1/places/2/versions/7/luau-execution-sessions/s/tasks/t{number}"
            with self.lock:
                self.active_polls += 1
                self.max_concurrent_polls = max(self.max_concurrent_polls, self.active_polls)
                polls = self.polls[number] = self.polls.get(number, 0) + 1
            if "PARALLEL_CHECK" in script and polls == 1:
                time.sleep(0.02)
            with self.lock:
                self.active_polls -= 1
            if polls < 2:
                return 200, {"path": path, "state": "PROCESSING"}
            task = {"path": path, "state": "COMPLETE", "createTime": "2026-10-11T10:00:00Z", "updateTime": "2026-10-11T10:03:00Z"}
            if "SCRIPTERROR" in script and '"rest"' in script:
                task.update(state="FAILED", error={"code": "SCRIPT_ERROR", "message": "2 of 9 tests failed"})
            return 200, task
        return 404, {"message": "unknown " + url.path}


class CloudServerTest(unittest.TestCase):
    def setUp(self):
        fake = self.fake = FakeCloud()

        class Handler(BaseHTTPRequestHandler):
            def respond(self, method):
                status, payload = fake.handle(self, method)
                data = json.dumps(payload).encode()
                self.send_response(status)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(data)))
                if status == 429:
                    self.send_header("Retry-After", "0")
                self.end_headers()
                self.wfile.write(data)

            def do_GET(self):
                self.respond("GET")

            def do_POST(self):
                self.respond("POST")

            def log_message(self, *args):
                pass

        self.server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        threading.Thread(target=self.server.serve_forever, args=(0.01,), daemon=True).start()
        self.base = f"http://127.0.0.1:{self.server.server_address[1]}"
        self.tmp = tempfile.TemporaryDirectory()
        self.place = os.path.join(self.tmp.name, "place.rbxl")
        with open(self.place, "wb") as handle:
            handle.write(b"<roblox!" + b"\0" * 32)
        self.script = os.path.join(self.tmp.name, "spec.luau")
        self.patch = mock.patch.object(cloud, "SLEEP", lambda seconds: None)
        self.patch.start()

    def tearDown(self):
        self.patch.stop()
        self.server.shutdown()
        self.server.server_close()
        self.tmp.cleanup()

    def env(self):
        return {"ROBLOX_API_KEY": KEY, "ROBLOX_UNIVERSE_ID": "1", "ROBLOX_PLACE_ID": "2", "ROBLOX_CLOUD_BASE_URL": self.base}

    def run_cloud(self, source, conf, **args):
        if source is not None:
            with open(self.script, "w", encoding="utf-8") as handle:
                handle.write(source)
        opts = types.SimpleNamespace(
            **{
                "project": None,
                "script": "spec.luau" if source is not None else None,
                "place": "place.rbxl",
                "place_version": None,
                "output": None,
                "shard": [],
                "json_out": None,
                **args,
            }
        )
        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            try:
                code = cloud.execute(self.tmp.name, conf, opts, self.env())
            except SertError as error:
                print(cloud.redact(error, KEY), file=sys.stderr)
                code = error.code
        return code, out.getvalue(), err.getvalue()

    def test_parallel_shards_log_dedup_cancel_cleanup_and_zero_boilerplate(self):
        # 1. Parallel execution across 3 shards + log deduplication (`structuredMessages` vs `messages`)
        code, out, err = self.run_cloud("-- PARALLEL_CHECK\nreturn nil\n", {"shards": SHARDS})
        self.assertEqual(code, 0, out + err)
        self.assertGreaterEqual(self.fake.max_concurrent_polls, 2)
        # "!! [WARNING] careful" should appear once per shard (3 shards), NOT duplicated by `messages: ["careful"]`!
        self.assertEqual(out.count("!! [WARNING] careful"), 3)
        self.assertIn("extra-flat-only", out)

        # 2. Failure & rate-limit short-circuiting
        json_out = os.path.join(self.tmp.name, "verdicts.json")
        code, _, err = self.run_cloud("-- spec FAILTEST SCRIPTERROR\nreturn nil\n", {"shards": SHARDS}, json_out=json_out)
        verdicts = json.loads(pathlib.Path(json_out).read_text())
        self.assertEqual((code, "failed shards: store, rest" in err, [t["exit"] for t in verdicts["tasks"]], verdicts["version"]), (1, True, [0, 1, 1], 7))

        # 3. `:cancel` endpoint called in `finally` on BOTH timeout (`GiveUp`) and `KeyboardInterrupt`!
        client = cloud.Client(KEY, self.base)
        self.fake.cancelled.clear()
        with (
            mock.patch.object(cloud, "wait_for_task", side_effect=cloud.GiveUp("timed out")),
            contextlib.redirect_stdout(io.StringIO()),
        ):
            res_timeout = cloud.run_task(client, "1", "2", 7, "print(1)", "shard1")
        self.assertEqual(res_timeout["exit"], util.TIMEOUT)
        self.assertEqual(len(self.fake.cancelled), 1)
        self.assertTrue(self.fake.cancelled[0].endswith(":cancel"))

        self.fake.cancelled.clear()
        with (
            mock.patch.object(cloud, "wait_for_task", side_effect=KeyboardInterrupt),
            contextlib.redirect_stdout(io.StringIO()),
            self.assertRaises(KeyboardInterrupt),
        ):
            cloud.run_task(client, "1", "2", 7, "print(1)", "shard1")
        self.assertEqual(len(self.fake.cancelled), 1)
        self.assertTrue(self.fake.cancelled[0].endswith(":cancel"))

        # 4. Zero-boilerplate script + Rojo overlay synthesis when `[cloud].script` is omitted!
        zb_root = pathlib.Path(self.tmp.name) / "zb"
        shutil.copytree(REPO / "src", zb_root / ".sert/sert/src")
        (zb_root / "default.project.json").write_text('{"name": "ZB", "tree": {"$className": "DataModel"}}', encoding="utf-8")
        (zb_root / "test").mkdir(parents=True)
        (zb_root / "test/Cloud.spec.luau").write_text('print("cloud spec")\n', encoding="utf-8")

        built_projects: list[str] = []

        def fake_build_place(r, proj, out_rbxl, quiet=False):
            built_projects.append(str(proj))
            pathlib.Path(out_rbxl).write_bytes(b"<roblox!" + b"\0" * 32)
            return 0.05

        zb_opts = types.SimpleNamespace(
            project=None,
            script=None,
            place=None,
            place_version=None,
            output=None,
            shard=[],
            json_out=None,
            dry_run=True,
            emit="emitted",
        )
        with mock.patch.object(cloud, "build_place", side_effect=fake_build_place), contextlib.redirect_stdout(io.StringIO()):
            rc_zb = cloud.execute(str(zb_root), {}, zb_opts, {})
        self.assertEqual(rc_zb, 0)
        self.assertEqual(len(built_projects), 1)
        self.assertIn("studio-overlay", built_projects[0])
        emitted_luau = (zb_root / "emitted" / "cloud.luau").read_text(encoding="utf-8")
        self.assertIn("Runner.runOnce", emitted_luau)
        self.assertIn("__sert_config", emitted_luau)


if __name__ == "__main__":
    unittest.main()
