"""tools/sert.py, run as a consumer would: SERT_SOURCE, [override].sert, and the pinned pyz from a release."""

import contextlib, functools, http.server, io, os, runpy, shutil, signal, subprocess, sys, tempfile, textwrap, threading, unittest, zipfile
from pathlib import Path
from unittest import mock

import helpers
from helpers import REPO, Case, truncating_handler
from sert import VERSION, release as pack
from sert.lint import shipped_stub, stub_problem

PYZ = f"sert-{VERSION}.pyz"


class ReleaseHandler(http.server.SimpleHTTPRequestHandler):
    def send_head(self):
        if self.path.endswith("/releases/latest") and self.server.latest:
            self.send_response(302)
            self.send_header("Location", self.path.removesuffix("latest") + f"tag/v{self.server.latest}")
            self.end_headers()
            return None
        if "/releases/tag/" in self.path:
            self.send_response(200)
            self.send_header("Content-Length", "0")
            self.end_headers()
            return None
        return super().send_head()

    def log_message(self, *args):
        pass


class StubTest(Case):
    @classmethod
    def setUpClass(cls):
        cls._build = tempfile.TemporaryDirectory(prefix="sert-stub-")
        repo = helpers.copy_repo(Path(cls._build.name) / "sert-repo")
        cls.dist = Path(cls._build.name) / "dist"
        cls.hashes = pack.build(repo, cls.dist)

    @classmethod
    def tearDownClass(cls):
        cls._build.cleanup()

    def consumer(self, toml="", local=None, name="consumer"):
        root = self.project(toml, local, name=name)
        (root / "tools").mkdir(exist_ok=True)
        shutil.copy(REPO / "tools/sert.py", root / "tools/sert.py")
        return root

    def stub(self, root, *argv, env=None):
        environment = {k: v for k, v in os.environ.items() if k not in ("SERT_SOURCE", "PYTHONPATH", "SERT_ROOT", "CI")}
        environment.update(env or {})
        return subprocess.run([sys.executable, str(root / "tools/sert.py"), *argv], capture_output=True, text=True, env=environment, cwd=root)

    def http_release(self, latest=VERSION, sums=True):
        server_dir = self.tmp / "http"
        release = server_dir / "kohltastrophe/sert/releases/download" / f"v{VERSION}"
        release.mkdir(parents=True, exist_ok=True)
        shutil.copy(self.dist / PYZ, release)
        if sums:
            shutil.copy(self.dist / "SHA256SUMS", release)
        elif (release / "SHA256SUMS").exists():
            (release / "SHA256SUMS").unlink()
        server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), functools.partial(ReleaseHandler, directory=str(server_dir)))
        server.latest = latest
        threading.Thread(target=server.serve_forever, daemon=True).start()
        self.addCleanup(server.server_close)
        self.addCleanup(server.shutdown)
        return {"SERT_GITHUB_URL": f"http://127.0.0.1:{server.server_port}", "SERT_CACHE": str(self.tmp / "cache")}

    def test_stub_constraints_sources_and_toml_errors(self):
        text = (REPO / "tools/sert.py").read_text()
        self.assertTrue(len(text.splitlines()) <= 120 and "import sert" not in text)
        self.assertEqual(shipped_stub(), (REPO / "tools/sert.py").read_bytes())
        with zipfile.ZipFile(self.dist / PYZ) as archive:
            self.assertEqual(archive.read(pack.STUB_ENTRY), (REPO / "tools/sert.py").read_bytes())

        root = self.consumer('[sert]\nversion = "9.9.9"\n', '[override]\nsert = "../nowhere"\n')
        self.assertEqual(self.stub(root, "--version", env={"SERT_SOURCE": str(REPO)}).stdout.strip(), f"sert {VERSION}")
        self.assertEqual(self.stub(root, "--version", env={"HOME": str(REPO.parent), "USERPROFILE": str(REPO.parent), "SERT_SOURCE": f"~/{REPO.name}"}).stdout.strip(), f"sert {VERSION}")
        self.assertEqual(self.stub(root, "--version", env={"SERT_SOURCE": str(self.tmp / "nowhere")}).returncode, 2)
        self.assertEqual(self.stub(self.consumer(local='[override]\nsert = "../nowhere"\n', name="loc"), "--version").returncode, 2)

        for path in (REPO / "tools/sert.py", REPO / "python/sert/__main__.py"):
            err = io.StringIO()
            with mock.patch.object(sys, "version_info", (3, 10, 4)), mock.patch.object(sys, "version", "3.10.4 (x)"), contextlib.redirect_stderr(err), self.assertRaises(SystemExit) as caught:
                runpy.run_path(str(path))
            self.assertEqual((caught.exception.code, "needs Python 3.11 or newer" in err.getvalue()), (2, True))

        crlf = self.consumer(name="crlf")
        s_file = crlf / "tools/sert.py"
        s_file.write_bytes(s_file.read_bytes().replace(b"\r\n", b"\n").replace(b"\n", b"\r\n"))
        self.assertIsNone(stub_problem(crlf))
        s_file.write_bytes(s_file.read_bytes() + b"# edited\r\n")
        self.assertIn("differs from the stub", stub_problem(crlf))

        checkout = self.tmp / "sert-checkout"
        shutil.copytree(REPO / "python", checkout / "python", ignore=shutil.ignore_patterns("__pycache__"))
        ov_root = self.consumer('[coverage]\ninclude = ["src"]\n', '[override]\nsert = "../sert-checkout"\n', name="ov")
        (ov_root / "coverage.out").write_text("SF:src/a.luau\nDA:1,1\nend_of_record\n")
        self.assertEqual(self.stub(ov_root, "coverage").stdout.strip(), "100.0")

        self_root = self.consumer('[coverage]\ninclude = ["src"]\n', name="self_checkout")
        shutil.copytree(REPO / "python", self_root / "python", ignore=shutil.ignore_patterns("__pycache__"))
        self.assertEqual(self.stub(self_root, "--version").stdout.strip(), f"sert {VERSION}")

        bom = self.consumer(name="bom")
        (bom / "sert.local.toml").write_bytes(b"\xef\xbb\xbf" + f'[override]\nsert = "{REPO.as_posix()}"\n'.encode())
        self.assertEqual(self.stub(bom, "--version").stdout.strip(), f"sert {VERSION}")

        bad_t = self.consumer("[sert\n", name="bad_t")
        self.assertEqual(self.stub(bad_t, "--version").returncode, 2)
        (bad_t / "sert.toml").write_bytes(b'[sert]\nversion = "\xff"\n')
        self.assertEqual(self.stub(bad_t, "--version").returncode, 2)
        self.assertEqual(self.stub(self.consumer('[sert]\nversion = "1.0.0"\n', "[override\n", name="bad_l"), "--version").returncode, 2)

    @unittest.skipIf(sys.platform == "win32", "process groups and POSIX signals")
    def test_signals_and_cwd_shadowing(self):
        checkout = self.tmp / "fake-sert"
        (checkout / "python/sert").mkdir(parents=True)
        (checkout / "python/sert/__init__.py").write_text("")
        (checkout / "python/sert/__main__.py").write_text(
            "import os, pathlib, signal, sys, time\n"
            "if sys.argv[1] == 'die': os.kill(os.getpid(), signal.SIGKILL)\n"
            "signal.signal(signal.SIGTERM, lambda *_: (pathlib.Path(sys.argv[1]).write_text('terminated'), sys.exit(0)))\n"
            "try:\n    print(os.environ.get('SERT_PYTHON', 'ready'), flush=True)\n    time.sleep(30)\n"
            "except KeyboardInterrupt:\n    pathlib.Path(sys.argv[1]).write_text('stopped')\n    sys.exit(130)\n"
        )
        root = self.consumer()
        env = {k: v for k, v in os.environ.items() if k not in ("PYTHONPATH", "SERT_ROOT", "SERT_PYTHON", "CI")}
        env["SERT_SOURCE"] = str(checkout)

        m_int = self.tmp / "stopped"
        p1 = subprocess.Popen([sys.executable, str(root / "tools/sert.py"), str(m_int)], env=env, cwd=root, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, start_new_session=True)
        self.addCleanup(p1.kill)
        self.assertEqual(p1.stdout.readline().strip(), "python3")
        os.killpg(p1.pid, signal.SIGINT)
        p1.communicate(timeout=30)
        self.assertEqual((p1.returncode, m_int.read_text()), (130, "stopped"))

        m_term = self.tmp / "terminated"
        p2 = subprocess.Popen([sys.executable, str(root / "tools/sert.py"), str(m_term)], env=env, cwd=root, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, start_new_session=True)
        self.addCleanup(lambda: p2.poll() is None and os.killpg(p2.pid, signal.SIGKILL))
        self.assertEqual(p2.stdout.readline().strip(), "python3")
        os.kill(p2.pid, signal.SIGTERM)
        p2.communicate(timeout=30)
        self.assertEqual((p2.returncode, m_term.read_text()), (0, "terminated"))

        res_die = subprocess.run([sys.executable, str(root / "tools/sert.py"), "die"], env=env, cwd=root, capture_output=True, text=True)
        self.assertEqual(res_die.returncode, 128 + signal.SIGKILL)

        env_repo = {**env, "SERT_SOURCE": str(REPO)}
        p3 = subprocess.Popen([sys.executable, "sert.py", "--version"], env=env_repo, cwd=root / "tools", stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, start_new_session=True)
        stdout, _ = p3.communicate(timeout=20)
        self.assertEqual(stdout.strip(), f"sert {VERSION}")

    def test_pyz_downloads_cache_and_offline(self):
        handler = truncating_handler(b"x" * 1000)
        base = self.serve(handler)
        root_t = self.consumer(f'[sert]\nversion = "{VERSION}"\n', name="trunc")
        res_t = self.stub(root_t, "--version", env={"SERT_GITHUB_URL": base, "SERT_CACHE": str(self.tmp / "c1"), "SERT_RETRY_DELAY": "0"})
        self.assertEqual((res_t.returncode, "IncompleteRead" in res_t.stderr, handler.requests), (2, True, 4))

        server = self.release_server()
        self.publish(server, "kohltastrophe/sert", f"v{VERSION}", PYZ, (self.dist / PYZ).read_bytes())
        env = {"SERT_GITHUB_URL": server.as_uri(), "SERT_CACHE": str(self.tmp / "cache")}
        root = self.consumer(f'[sert]\nversion = "{VERSION}"\n')
        self.assertEqual(self.stub(root, "--version", env=env).stdout.strip(), f"sert {VERSION}")
        shutil.rmtree(server)
        self.assertEqual(self.stub(root, "--version", env=env).returncode, 0)

        http_env = self.http_release()
        no_toml = self.consumer(name="no_toml")
        (no_toml / "sert.toml").unlink()
        res_nt = self.stub(no_toml, "--version", env=http_env)
        self.assertEqual((res_nt.returncode, res_nt.stdout.strip()), (0, f"sert {VERSION}"))

        unp_env = self.http_release(latest=None)
        unp = self.consumer(f'[sert]\nversion = "{VERSION}"\n', name="unp")
        self.assertEqual(self.stub(unp, "--version", env=unp_env).stdout.strip(), f"sert {VERSION}")
        self.assertEqual(self.stub(unp, "--version", env={**unp_env, "SERT_OFFLINE": "1", "SERT_GITHUB_URL": "http://127.0.0.1:9"}).stdout.strip(), f"sert {VERSION}")

        off_env = {"SERT_OFFLINE": "1", "SERT_GITHUB_URL": "http://127.0.0.1:9", "SERT_CACHE": str(self.tmp / "empty_c")}
        self.assertEqual(self.stub(root, "--version", env=off_env).returncode, 2)
        self.assertEqual(self.stub(self.consumer(name="unv"), "--version", env=off_env).returncode, 2)

        bad_http = {**self.http_release(latest=None, sums=False), "SERT_CACHE": str(self.tmp / "bad_c")}
        self.assertEqual(self.stub(self.consumer(name="b1"), "--version", env=bad_http).returncode, 2)


class SetupActionTest(Case):
    def step(self, name: str) -> str:
        text = (REPO / "actions/setup/action.yml").read_text(encoding="utf-8")
        return textwrap.dedent(text.split(f"- name: {name}\n", 1)[1].split("      run: |\n", 1)[1].split("\n\n", 1)[0])

    def test_setup_action_steps(self):
        script = self.step("Hash the pins").split("<<'PY'\n", 1)[1].rsplit("PY", 1)[0]
        root = self.project('[sert]\nversion = "0.1.0"\n')
        plain = subprocess.run([sys.executable, "-c", script], cwd=root, capture_output=True, text=True)
        (root / "sert.toml").write_bytes(b"\xef\xbb\xbf" + (root / "sert.toml").read_bytes())
        bom = subprocess.run([sys.executable, "-c", script], cwd=root, capture_output=True, text=True)
        self.assertEqual((bom.returncode, bom.stdout), (0, plain.stdout))
        self.assertRegex(bom.stdout, r"^hash=[0-9a-f]{32}$")

        candidates = []
        if os.name == "nt":
            for base in (os.environ.get("ProgramFiles"), os.environ.get("ProgramW6432"), r"C:\Program Files"):
                if base:
                    candidates.append(os.path.join(base, "Git", "bin", "bash.exe"))
        if found := shutil.which("bash"):
            candidates.append(found)
        bash = None
        for candidate in candidates:
            try:
                if os.path.isfile(candidate) and subprocess.run([candidate, "-c", "exit 0"], capture_output=True, timeout=5).returncode == 0:
                    bash = candidate
                    break
            except (OSError, subprocess.SubprocessError):
                pass
        if bash:
            line = next(l for l in self.step("Fetch sert and the pinned deps").splitlines() if "-m sert fetch" in l)
            (root / "sert.py").write_text("raise SystemExit('the workspace sert.py ran')\n")
            ref_dir = root / ".sert/sert-ref"
            ref_dir.parent.mkdir(exist_ok=True)
            try:
                ref_dir.symlink_to(REPO, target_is_directory=True)
            except OSError:
                helpers.copy_repo(ref_dir)
            env = {k: v for k, v in os.environ.items() if k not in ("PYTHONPATH", "SERT_ROOT", "SERT_SOURCE", "CI")}
            env.update(PY=sys.executable.replace("\\", "/"), WORKSPACE=root.as_posix())
            res = subprocess.run([bash, "-c", line.strip()], cwd=root, env=env, capture_output=True, text=True, timeout=60)
            self.assertEqual((res.returncode, "the workspace sert.py ran" in res.stderr), (0, False), res.stderr)


if __name__ == "__main__":
    unittest.main()
