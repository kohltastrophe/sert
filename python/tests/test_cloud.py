import contextlib, io, json, os, pathlib, shutil, subprocess, sys, tempfile, threading, types, unittest, urllib.error, urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from unittest import mock

import helpers  # noqa: F401
from sert import cli, cloud, util
from sert.studio import markers
from sert.util import SertError

KEY = "test-key-1234567890"
SHARDS = [{"name": "local", "only": ["parity.", "measure.json"]}, {"name": "store", "only": ["suite.store"]}, {"name": "rest"}]


class ShardAndClassifyTest(unittest.TestCase):
    def test_shards_inject_and_classify(self):
        shards = cloud.normalize_shards(SHARDS)
        self.assertEqual(cloud.shard_info(shards, 0, 120), {"name": "local", "index": 1, "count": 3, "runLimit": 120, "only": ["parity.", "measure.json"]})
        self.assertEqual(cloud.shard_info(shards, 2, 120)["except"], ["parity.", "measure.json", "suite.store"])
        self.assertNotIn("except", cloud.shard_info(cloud.normalize_shards(["a", "b"]), 1, 60))

        for bad in (["a", "a"], [{"only": ["x"]}], [{"name": "a", "only": ["x"], "except": ["y"]}], [{"name": "a", "except": "x"}], [{"name": "a", "onyl": ["x"]}], "a"):
            with self.assertRaises(SertError):
                cloud.normalize_shards(bad)

        explicit = cloud.normalize_shards([{"name": "local", "only": ["parity."]}, {"name": "rest", "except": ["parity.", "suite.extra"]}])
        self.assertIn('except = { "parity.", "suite.extra" }', cloud.shard_statement(cloud.shard_info(explicit, 1, 120)))
        self.assertIn('local SERT_SHARD = "we\\"ird"', cloud.shard_statement({"name": 'we"ird', "index": 1, "count": 1, "runLimit": 1}))

        info = cloud.shard_info(shards, 2, 120)
        source = "--!strict\n--!optimize 2\n-- a comment\nlocal x = 1\nerror('line 5')\n"
        lines = cloud.inject_shard(source, info).split("\n")
        self.assertEqual((len(lines), lines[:2], lines[4]), (len(source.split("\n")), ["--!strict", "--!optimize 2"], "error('line 5')"))
        self.assertTrue('except = { "parity.", "measure.json", "suite.store" }' in lines[2] and lines[2].endswith('pcall(rawset, _G, "__SERT_SHARD", SERT_SHARD_INFO) -- a comment'))
        self.assertEqual(cloud.inject_shard("--!strict", info).split("\n")[0], "--!strict")
        self.assertIn('SERT_SHARD = "rest"', cloud.inject_shard("", info))

        if shutil.which("luau"):
            with tempfile.TemporaryDirectory() as tmp:
                path = pathlib.Path(tmp, "s.luau")
                path.write_text(cloud.inject_shard("--!strict\nprint(SERT_SHARD, SERT_SHARD_INFO.index, #SERT_SHARD_INFO.only)\n", cloud.shard_info(shards, 0, 120)))
                done = subprocess.run(["luau", str(path)], capture_output=True, text=True, timeout=60)
                self.assertEqual((done.returncode, done.stdout.strip().split()), (0, ["local", "1", "2"]))

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

        ok_v = {"passed": True, "failed": 0, "counts": {"passed": 3, "failed": 0, "skipped": 0, "total": 3}}
        bad_v = {"passed": False, "failed": 0, "counts": {"passed": 0, "failed": 0, "skipped": 0, "total": 0}}
        zero_v = {"passed": True, "failed": 0, "counts": {"passed": 0, "failed": 0, "skipped": 2, "total": 2}}
        self.assertEqual(cloud.classify({"state": "COMPLETE", "output": {"results": [ok_v]}}, [])[0], 0)
        self.assertEqual(cloud.classify({"state": "COMPLETE", "output": {"results": [bad_v]}}, [])[0], 1)
        self.assertEqual(cloud.classify({"state": "COMPLETE", "output": {"results": [zero_v]}}, [])[0], 1)
        self.assertEqual(cloud.classify({"state": "COMPLETE"}, ["[sert-list] end 3", '[sert-done] {"passed": 0, "failed": 0, "skipped": 3, "total": 3}', '[sert-done] {"passed": 3, "failed": 0, "skipped": 0, "total": 3}', "[sert-verdict] " + json.dumps(ok_v)])[0], 0)
        self.assertEqual(cloud.classify({"state": "COMPLETE"}, ['[sert-done] {"passed": 1, "failed": 1}', '[sert-done] {"passed": 2, "failed": 0}'])[0], 1)
        self.assertAlmostEqual(cloud.task_seconds({"createTime": "2026-10-11T10:00:00.123456789Z", "updateTime": "2026-10-11T10:02:30.623Z"}), 150.5, places=3)
        self.assertIsNone(cloud.task_seconds({}))
        self.assertEqual([util.worst(x) for x in ([0, 1, 3], [1, 2, 3], [2, 130], iter([0, 0]), [])], [3, 2, 130, 0, 0])


class FakeCloud:
    def __init__(self):
        self.scripts, self.uploads, self.fail_create = [], [], []
        self.keys, self.polls, self.lock = set(), {}, threading.Lock()

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
        prefix = "/cloud/v2/universes/1/places/2/versions/7/luau-execution-sessions/s/tasks/t"
        if method == "GET" and url.path.startswith(prefix):
            rest = url.path[len(prefix):]
            number = int(rest.split("/")[0])
            script = self.scripts[number - 1]["script"]
            if rest.endswith("/logs"):
                if "pageToken" not in urllib.parse.parse_qs(url.query):
                    return 200, {"luauExecutionSessionTaskLogs": [{"structuredMessages": [{"messageType": "OUTPUT", "message": f"ran {script.split(chr(10))[0][:40]}"}]}], "nextPageToken": "p2"}
                lines = ['[sert-done] {"passed": 1, "failed": 1}'] if ("FAILTEST" in script and '"store"' in script) else ['[sert-done] {"passed": 1, "failed": 0}']
                return 200, {"luauExecutionSessionTaskLogs": [{"structuredMessages": [{"messageType": "WARNING", "message": "careful"}] + [{"messageType": "OUTPUT", "message": line} for line in lines]}]}
            path = f"universes/1/places/2/versions/7/luau-execution-sessions/s/tasks/t{number}"
            polls = self.polls[number] = self.polls.get(number, 0) + 1
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
                if status == 429: self.send_header("Retry-After", "0")
                self.end_headers()
                self.wfile.write(data)
            def do_GET(self): self.respond("GET")
            def do_POST(self): self.respond("POST")
            def log_message(self, *args): pass

        self.server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        threading.Thread(target=self.server.serve_forever, daemon=True).start()
        self.base = f"http://127.0.0.1:{self.server.server_address[1]}"
        self.tmp = tempfile.TemporaryDirectory()
        self.place = os.path.join(self.tmp.name, "place.rbxl")
        with open(self.place, "wb") as handle: handle.write(b"<roblox!" + b"\0" * 32)
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
        with open(self.script, "w") as handle: handle.write(source)
        opts = types.SimpleNamespace(**{"project": None, "script": "spec.luau", "place": "place.rbxl", "place_version": None, "output": None, "shard": [], "json_out": None, **args})
        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            try:
                code = cloud.execute(self.tmp.name, conf, opts, self.env())
            except SertError as error:
                print(cloud.redact(error, KEY), file=sys.stderr)
                code = error.code
        return code, out.getvalue(), err.getvalue()

    def test_cloud_runs_shards_retries_and_dry_run(self):
        code, out, err = self.run_cloud("--!strict\nprint('hi')\n", {})
        self.assertEqual((code, self.fake.uploads, self.fake.keys), (0, [("versionType=Saved", "application/octet-stream", 40)], {KEY}), out + err)
        self.assertTrue("!! [WARNING] careful" in out and '[sert-done] {"passed": 1, "failed": 0}' in out and "task took 180.0 s" in out)
        with mock.patch.dict(os.environ, {"GITHUB_ACTIONS": "true"}):
            self.assertIn("::warning::Luau task", self.run_cloud("--!strict\nprint('hi')\n", {})[1])

        json_out = os.path.join(self.tmp.name, "verdicts.json")
        code, _, err = self.run_cloud("-- spec FAILTEST SCRIPTERROR\nreturn nil\n", {"shards": SHARDS}, json_out=json_out)
        verdicts = json.loads(pathlib.Path(json_out).read_text())
        self.assertEqual((code, "failed shards: store, rest" in err, [t["exit"] for t in verdicts["tasks"]], verdicts["version"]), (1, True, [0, 1, 1], 7))

        self.assertEqual(self.run_cloud("print(1)\n", {"shards": SHARDS}, shard=["store"])[0], 0)
        self.assertEqual(self.run_cloud("print(1)\n", {"shards": SHARDS}, shard=["nope"])[0], 2)
        self.assertEqual(self.run_cloud("print(1)\n", {"shards": SHARDS}, unsharded=True)[0], 0)
        self.assertEqual(self.run_cloud("print(1)\n", {"shards": SHARDS}, unsharded=True, shard=["store"])[0], 2)

        self.fake.fail_create = [429]
        code, _, err = self.run_cloud("print(1)\n", {})
        self.assertEqual((code, "HTTP 429; retrying" in err), (0, True))

        self.fake.fail_create = [502]
        code, out, err = self.run_cloud("print(1)\n", {})
        self.assertEqual((code, "HTTP 502" in err and "not retried" in err and KEY not in err + out and "[REDACTED]" in err), (2, True))

        with contextlib.redirect_stderr(io.StringIO()):
            self.assertEqual(cloud.execute(self.tmp.name, {}, types.SimpleNamespace(script="spec.luau", shard=[], place_version=None, place=None, project=None), {"ROBLOX_API_KEY": KEY}), 2)
            self.assertEqual(cloud.execute(self.tmp.name, {}, types.SimpleNamespace(script="spec.luau", shard=[], place_version=None, place=None, project=None, dry_run=False, emit="x"), self.env()), 2)

        emit, dry_json = os.path.join(self.tmp.name, "emit"), os.path.join(self.tmp.name, "dry.json")
        with open(self.script, "w") as handle: handle.write("--!strict\nlocal SHARD = SERT_SHARD_INFO or {}\nreturn SHARD\n")
        opts = types.SimpleNamespace(project=None, script="spec.luau", place="place.rbxl", place_version=None, output=None, shard=["local", "rest"], json_out="sub/dry.json", dry_run=True, emit="sub/emit")
        with contextlib.redirect_stdout(io.StringIO()) as d_out:
            self.assertEqual(cloud.execute(self.tmp.name, {"shards": SHARDS, "shard_limit": 90}, opts, {}), 0)
        self.assertEqual((sorted(os.listdir(os.path.join(self.tmp.name, "sub/emit"))), json.loads(pathlib.Path(self.tmp.name, "sub/dry.json").read_text())["dryRun"]), (["local.luau", "rest.luau"], True))
        self.assertNotIn("[store]", d_out.getvalue())

    def test_place_building_api_errors_and_client_edges(self):
        with self.assertRaises(SertError):
            cloud.Client(KEY, "http://example.com")
        cloud.Client(KEY, "https://apis.roblox.com")

        with open(self.script, "w") as handle: handle.write("print(1)\n")
        opts = types.SimpleNamespace(project=None, script="spec.luau", place="place.rbxl", place_version=None, output=None, shard=[], json_out=None, dry_run=True, emit=None)
        with mock.patch.dict(os.environ, {"SERT_ROOT": self.tmp.name}), contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(cloud.main(opts, env=self.env()), 0)

        with mock.patch.object(cloud, "build_place", return_value=None):
            self.assertEqual(self.run_cloud("print(1)\n", {"project": "default.project.json"}, place=None, output=None)[0], 2)
        with mock.patch.object(cloud, "build_place", side_effect=lambda r, p, pf, quiet=False: pathlib.Path(pf).write_bytes(b"x" * 40) and 0.1):
            self.assertEqual(self.run_cloud("print(1)\n", {"project": "default.project.json"}, place=None, output="built.rbxl")[0], 0)
        self.assertTrue(os.path.isfile(os.path.join(self.tmp.name, "built.rbxl")))

        json_out = os.path.join(self.tmp.name, "verdicts.json")
        def fail_store(client, u, p, v, src, label):
            if label == "store": raise cloud.ApiError(f"GET /x failed with HTTP 503: {KEY}", 503)
            return {"label": label, "exit": 0, "verdict": "COMPLETE", "seconds": 1.0, "path": "p"}
        with mock.patch.object(cloud, "run_task", side_effect=fail_store):
            code, _, err = self.run_cloud("print(1)\n", {"shards": SHARDS}, json_out=json_out)
        self.assertEqual((code, KEY in err, [(t["label"], t["exit"]) for t in json.loads(pathlib.Path(json_out).read_text())["tasks"]]),
                         (2, False, [("local", 0), ("store", 2), ("rest", 0)]))

        def rate_lim(client, u, p, v, src, label):
            if label == "local": raise cloud.ApiError("POST /tasks was rate limited (HTTP 429) 6 times", 429)
            return {"label": label, "exit": 0, "verdict": "COMPLETE", "seconds": 1.0, "path": "p"}
        with mock.patch.object(cloud, "run_task", side_effect=rate_lim):
            self.assertEqual(self.run_cloud("print(1)\n", {"shards": SHARDS}, json_out=json_out)[0], 2)
        self.assertEqual([t["verdict"] for t in json.loads(pathlib.Path(json_out).read_text())["tasks"][1:]], ["not run: local was rate limited"] * 2)

        with self.assertRaises(SertError): cloud.checked_url("https://example.com:notaport")
        self.assertEqual((cloud.retry_after("5"), cloud.retry_after("not-a-date"), cloud.retry_after("nan")), (5.0, None, None))
        self.assertIsNotNone(cloud.retry_after("Wed, 21 Oct 2099 07:28:00 GMT"))
        self.assertEqual(cloud.error_detail(b'{"code": "BAD", "errors": [{"message": "oops secret"}]}', "secret"), "BAD: oops [REDACTED]")
        self.assertEqual(cloud.error_detail(b"plain text error"), "plain text error")
        self.assertIsNone(cloud._NoRedirect().redirect_request(None, None, 302, "Found", {}, "https://evil.com"))
        with self.assertRaises(SertError): cloud.Client("bad key with spaces")

        client = cloud.Client(KEY, self.base)
        with self.assertRaises(SertError): client.request("GET", "https://other.example.com/v1")
        self.fake.fail_create = [429] * cloud.RATE_LIMIT_ATTEMPTS
        self.assertEqual(self.run_cloud("print(1)\n", {})[0], 2)

        with mock.patch.object(client.opener, "open", side_effect=urllib.error.URLError("certificate verify failed")):
            with self.assertRaises(SertError): client.request("GET", "/test")
        with mock.patch.object(client.opener, "open", side_effect=urllib.error.URLError("connection reset")):
            with self.assertRaises(cloud.ApiError): client.request("POST", "/test")
            with self.assertRaises(cloud.ApiError): client.request("GET", "/test")

        class FakeResp:
            def __init__(self, data): self.data = data
            def __enter__(self): return self
            def __exit__(self, *a): pass
            def read(self): return self.data
        with mock.patch.object(client.opener, "open", return_value=FakeResp(b"   ")):
            self.assertEqual(client.request("GET", "/empty"), {})
        for raw in (b"not json", b"[1, 2]"):
            with mock.patch.object(client.opener, "open", return_value=FakeResp(raw)):
                with self.assertRaises(cloud.ApiError): client.request("GET", "/bad")

        with self.assertRaises(SertError): cloud.upload_place(client, "1", "2", "bad.txt")
        with mock.patch.object(client, "request", return_value={}):
            with self.assertRaises(cloud.ApiError): cloud.upload_place(client, "1", "2", self.place)
            with self.assertRaises(cloud.ApiError): cloud.create_task(client, "1", "2", 1, "print(1)")
        with self.assertRaises(SertError): cloud.create_task(client, "1", "2", 1, "x" * (cloud.MAX_SCRIPT_BYTES + 10))
        with self.assertRaises(cloud.ApiError): cloud.wait_for_task(client, {"path": "p", "state": "WEIRD"}, 10)
        with mock.patch.object(cloud, "CLOCK", side_effect=[0.0, 20.0]):
            with self.assertRaises(cloud.GiveUp): cloud.wait_for_task(client, {"path": "p", "state": "QUEUED"}, 10)
        with mock.patch.object(cloud, "create_task", return_value={"path": "p", "state": "QUEUED"}), mock.patch.object(cloud, "wait_for_task", side_effect=cloud.GiveUp("timed out")):
            self.assertEqual(cloud.run_task(client, "1", "2", 7, "print(1)", "shard1")["exit"], util.TIMEOUT)

        with mock.patch.object(client, "request", side_effect=[
            {"luauExecutionSessionTaskLogs": ["skip", {"messages": ["flat1"]}], "nextPageToken": "tok1"},
            {"luauExecutionSessionTaskLogs": [], "nextPageToken": "tok1"},
        ]):
            with self.assertRaisesRegex(cloud.ApiError, r"repeated log page token"): cloud.get_logs(client, "p")

        self.assertEqual((cloud.sert_results(["[sert-done] {bad json"]), cloud.classify({"state": "QUEUED"}, [])[0], cloud.classify({"state": "MYSTERY"}, [])[0]), ([], 2, 2))
        with mock.patch.object(cloud, "build_place", side_effect=lambda r, p, o: pathlib.Path(o).write_bytes(b"rbxl") and 0.1):
            self.assertEqual(self.run_cloud("print(1)\n", {"project": "default.project.json"}, place=None, dry_run=True, emit=os.path.join(self.tmp.name, "emit2"))[0], 0)
        for kw in ({"place": None, "dry_run": True}, {"script": None}, {"script": "missing_file.luau"}, {"shard": ["a"]}):
            self.assertEqual(self.run_cloud("print(1)\n", {}, **kw)[0], 2)

        out_b, err_b = io.StringIO(), io.StringIO()
        with mock.patch.dict(os.environ, {"SERT_ROOT": self.tmp.name, **self.env()}), contextlib.redirect_stdout(out_b), contextlib.redirect_stderr(err_b):
            self.assertEqual(cli.main(["cloud", "--root", self.tmp.name, "--script", "spec.luau", "--place", "place.rbxl", "--dry-run"]), 0)
            self.assertEqual(cloud.main(types.SimpleNamespace(root=self.tmp.name, dry_run=False, emit=None), env={**self.env(), "ROBLOX_API_KEY": "bad key"}), 2)
        test_env = {"ROBLOX_API_KEY": KEY, "ROBLOX_TEST_UNIVERSE_ID": "1", "ROBLOX_TEST_PLACE_ID": "2", "ROBLOX_CLOUD_BASE_URL": self.base}
        self.fake.fail_create = []
        with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
            self.assertEqual(cloud.main(types.SimpleNamespace(root=self.tmp.name, script="spec.luau", place="place.rbxl", place_version=7, output=None, shard=[], json_out=None, dry_run=False, emit=None), env=test_env), 0)

        parser = cli.build(["cloud"])
        self.assertEqual(parser.parse_args(["cloud", "--place-version", "42", "--root", "/tmp"]).place_version, 42)


if __name__ == "__main__":
    unittest.main()
