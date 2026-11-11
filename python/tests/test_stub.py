"""Tests for `tools/sert.py` bootstrapper: SERT_SOURCE, [override].sert, SHA-256 + sert.lock verification, private-repo API, and setup action."""

from __future__ import annotations

import contextlib
import functools
import http.server
import importlib.util
import io
import json
import os
from pathlib import Path
import runpy
import shutil
import signal
import subprocess
import sys
import tempfile
import textwrap
import threading
import unittest
import urllib.parse
import zipfile
from unittest import mock

import helpers
from helpers import REPO, Case, sha, truncating_handler
from sert import VERSION, lock
from sert.lint import shipped_stub, stub_problem

PYZ = f"sert-{VERSION}.pyz"


def _load_pack():
    spec = importlib.util.spec_from_file_location("sert_pack", REPO / "scripts" / "pack.py")
    assert spec is not None and spec.loader is not None
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


pack = _load_pack()


class ReleaseHandler(http.server.SimpleHTTPRequestHandler):
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
        environment = {k: v for k, v in os.environ.items() if k not in ("SERT_SOURCE", "PYTHONPATH", "SERT_ROOT", "CI", "GITHUB_TOKEN")}
        environment.update(env or {})
        return subprocess.run(
            [sys.executable, str(root / "tools/sert.py"), *argv],
            capture_output=True,
            text=True,
            env=environment,
            cwd=root,
        )

    def http_release(self, sums=True, tamper_pyz=False):
        server_dir = self.tmp / f"http-{sums}-{tamper_pyz}"
        release = server_dir / "kohltastrophe/sert/releases/download" / f"v{VERSION}"
        release.mkdir(parents=True, exist_ok=True)
        if tamper_pyz:
            (release / PYZ).write_bytes((self.dist / PYZ).read_bytes() + b"tampered")
        else:
            shutil.copy(self.dist / PYZ, release)
        if sums:
            shutil.copy(self.dist / "SHA256SUMS", release)
        server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), functools.partial(ReleaseHandler, directory=str(server_dir)))
        threading.Thread(target=server.serve_forever, args=(0.01,), daemon=True).start()
        self.addCleanup(server.server_close)
        self.addCleanup(server.shutdown)
        return {"SERT_GITHUB_URL": f"http://127.0.0.1:{server.server_port}", "SERT_CACHE": str(self.tmp / "cache")}

    def test_stub_constraints_sources_and_toml_errors(self):
        text = (REPO / "tools/sert.py").read_text(encoding="utf-8")
        self.assertNotIn("import sert", text)
        self.assertEqual(shipped_stub(), (REPO / "tools/sert.py").read_bytes())
        with zipfile.ZipFile(self.dist / PYZ) as archive:
            self.assertEqual(archive.read(pack.STUB_ENTRY), (REPO / "tools/sert.py").read_bytes())

        root = self.consumer('[sert]\nversion = "9.9.9"\n', '[override]\nsert = "../nowhere"\n')
        self.assertEqual(self.stub(root, "--version", env={"SERT_SOURCE": str(REPO)}).stdout.strip(), f"sert {VERSION}")
        self.assertEqual(
            self.stub(root, "--version", env={"HOME": str(REPO.parent), "USERPROFILE": str(REPO.parent), "SERT_SOURCE": f"~/{REPO.name}"}).stdout.strip(),
            f"sert {VERSION}",
        )
        self.assertEqual(self.stub(root, "--version", env={"SERT_SOURCE": str(self.tmp / "nowhere")}).returncode, 2)
        self.assertEqual(self.stub(self.consumer(local='[override]\nsert = "../nowhere"\n', name="loc"), "--version").returncode, 2)

        for path in (REPO / "tools/sert.py", REPO / "python/sert/__main__.py"):
            err = io.StringIO()
            with (
                mock.patch.object(sys, "version_info", (3, 10, 4)),
                mock.patch.object(sys, "version", "3.10.4 (x)"),
                contextlib.redirect_stderr(err),
                self.assertRaises(SystemExit) as caught,
            ):
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
        p1 = subprocess.Popen(
            [sys.executable, str(root / "tools/sert.py"), str(m_int)],
            env=env,
            cwd=root,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            start_new_session=True,
        )
        self.addCleanup(p1.kill)
        self.assertEqual(p1.stdout.readline().strip(), "python3")
        os.killpg(p1.pid, signal.SIGINT)
        p1.communicate(timeout=10)
        self.assertEqual((p1.returncode, m_int.read_text()), (130, "stopped"))

        m_term = self.tmp / "terminated"
        p2 = subprocess.Popen(
            [sys.executable, str(root / "tools/sert.py"), str(m_term)],
            env=env,
            cwd=root,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            start_new_session=True,
        )
        self.addCleanup(lambda: p2.poll() is None and os.killpg(p2.pid, signal.SIGKILL))
        self.assertEqual(p2.stdout.readline().strip(), "python3")
        os.kill(p2.pid, signal.SIGTERM)
        p2.communicate(timeout=10)
        self.assertEqual((p2.returncode, m_term.read_text()), (0, "terminated"))

        res_die = subprocess.run([sys.executable, str(root / "tools/sert.py"), "die"], env=env, cwd=root, capture_output=True, text=True)
        self.assertEqual(res_die.returncode, 128 + signal.SIGKILL)

        env_repo = {**env, "SERT_SOURCE": str(REPO)}
        p3 = subprocess.Popen(
            [sys.executable, "sert.py", "--version"],
            env=env_repo,
            cwd=root / "tools",
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            start_new_session=True,
        )
        stdout, _ = p3.communicate(timeout=10)
        self.assertEqual(stdout.strip(), f"sert {VERSION}")

    def test_pyz_sha256_lock_verification_and_private_api(self):
        # Truncated HTTP download rejected via IncompleteRead
        sums_text = f"{sha(b'x' * 2000)}  {PYZ}\n".encode()

        class TruncSumsHandler(http.server.BaseHTTPRequestHandler):
            def do_GET(self):
                if self.path.endswith("SHA256SUMS"):
                    self.send_response(200)
                    self.send_header("Content-Length", str(len(sums_text)))
                    self.end_headers()
                    self.wfile.write(sums_text)
                else:
                    self.send_response(200)
                    self.send_header("Content-Length", "2000")
                    self.end_headers()
                    self.wfile.write(b"x" * 1000)
                    self.close_connection = True

            def log_message(self, *args):
                pass

        base = self.serve(TruncSumsHandler)
        root_t = self.consumer(f'[sert]\nversion = "{VERSION}"\n', name="trunc")
        res_t = self.stub(root_t, "--version", env={"SERT_GITHUB_URL": base, "SERT_CACHE": str(self.tmp / "c1")})
        self.assertEqual((res_t.returncode, "IncompleteRead" in res_t.stderr), (2, True), res_t.stderr)

        # Valid download + SHA256SUMS verification + offline reuse
        http_env = self.http_release(sums=True)
        root = self.consumer(f'[sert]\nversion = "{VERSION}"\n')
        self.assertEqual(self.stub(root, "--version", env=http_env).stdout.strip(), f"sert {VERSION}")
        self.assertEqual(
            self.stub(root, "--version", env={**http_env, "SERT_OFFLINE": "1", "SERT_GITHUB_URL": "http://127.0.0.1:9"}).stdout.strip(),
            f"sert {VERSION}",
        )

        # Tampered pyz rejected immediately
        tamper_env = {**self.http_release(sums=True, tamper_pyz=True), "SERT_CACHE": str(self.tmp / "tamper_cache")}
        res_tamper = self.stub(self.consumer(f'[sert]\nversion = "{VERSION}"\n', name="tamper"), "--version", env=tamper_env)
        self.assertEqual((res_tamper.returncode, "SHA-256 verification failed" in res_tamper.stderr), (2, True))

        # Missing SHA256SUMS rejected immediately
        no_sums_env = {**self.http_release(sums=False), "SERT_CACHE": str(self.tmp / "no_sums_cache")}
        self.assertEqual(self.stub(self.consumer(f'[sert]\nversion = "{VERSION}"\n', name="nosums"), "--version", env=no_sums_env).returncode, 2)

        # sert.lock mismatch against SHA256SUMS rejected immediately
        mismatch_root = self.consumer(f'[sert]\nversion = "{VERSION}"\n', name="mismatch")
        lock.write_lock(
            mismatch_root,
            VERSION,
            "kohltastrophe/sert",
            {"sert.pyz": {"name": PYZ, "url": "https://example.com/" + PYZ, "sha256": "0" * 64}},
        )
        res_lock_bad = self.stub(mismatch_root, "--version", env={**http_env, "SERT_CACHE": str(self.tmp / "lock_bad_c")})
        self.assertEqual((res_lock_bad.returncode, "SHA-256 mismatch" in res_lock_bad.stderr), (2, True))

        # Private-repo GITHUB_TOKEN Releases API asset download (`Accept: application/octet-stream`)
        pyz_bytes = (self.dist / PYZ).read_bytes()
        sums_bytes = (self.dist / "SHA256SUMS").read_bytes()
        api_seen: list[tuple[str, str | None, str | None]] = []

        class PrivateApiHandler(http.server.BaseHTTPRequestHandler):
            def do_GET(self):
                parsed = urllib.parse.urlsplit(self.path)
                auth = self.headers.get("Authorization")
                accept = self.headers.get("Accept")
                api_seen.append((parsed.path, auth, accept))
                base_url = f"http://127.0.0.1:{self.server.server_port}"
                if parsed.path == f"/repos/private/sert/releases/tags/v{VERSION}":
                    body = json.dumps(
                        {
                            "assets": [
                                {"name": "SHA256SUMS", "url": f"{base_url}/repos/private/sert/releases/assets/1"},
                                {"name": PYZ, "url": f"{base_url}/repos/private/sert/releases/assets/2"},
                            ]
                        }
                    ).encode()
                    self.send_response(200)
                    self.send_header("Content-Length", str(len(body)))
                    self.end_headers()
                    self.wfile.write(body)
                elif parsed.path == "/repos/private/sert/releases/assets/1":
                    self.send_response(200)
                    self.send_header("Content-Length", str(len(sums_bytes)))
                    self.end_headers()
                    self.wfile.write(sums_bytes)
                elif parsed.path == "/repos/private/sert/releases/assets/2":
                    self.send_response(200)
                    self.send_header("Content-Length", str(len(pyz_bytes)))
                    self.end_headers()
                    self.wfile.write(pyz_bytes)
                else:
                    self.send_response(404)
                    self.end_headers()

            def log_message(self, *args):
                pass

        api_url = self.serve(PrivateApiHandler)
        priv_root = self.consumer(f'[sert]\nrepo = "private/sert"\nversion = "{VERSION}"\n', name="priv")
        res_priv = self.stub(
            priv_root,
            "--version",
            env={
                "GITHUB_TOKEN": "ghp_secret",
                "SERT_GITHUB_API_URL": api_url,
                "SERT_CACHE": str(self.tmp / "priv_cache"),
            },
        )
        self.assertEqual((res_priv.returncode, res_priv.stdout.strip()), (0, f"sert {VERSION}"), res_priv.stderr)
        self.assertIn((f"/repos/private/sert/releases/tags/v{VERSION}", "Bearer ghp_secret", "application/vnd.github+json"), api_seen)
        self.assertIn(("/repos/private/sert/releases/assets/2", "Bearer ghp_secret", "application/octet-stream"), api_seen)


class SetupActionTest(Case):
    def step(self, name: str) -> str:
        text = (REPO / "actions/setup/action.yml").read_text(encoding="utf-8")
        return textwrap.dedent(text.split(f"- name: {name}\n", 1)[1].split("      run: |\n", 1)[1].split("\n\n", 1)[0])

    def test_setup_action_steps(self):
        script = self.step("Hash the pins").split("<<'PY'\n", 1)[1].rsplit("PY", 1)[0]
        root = self.project('[sert]\nversion = "0.1.0"\n')
        (root / "rokit.toml").write_text('[tools]\nluau = "luau-lang/luau@0.724"\nluau-lsp = "JohnnyMorganz/luau-lsp@1.70.0"\n', encoding="utf-8")
        lock.write_lock(
            root,
            "0.1.0",
            "kohltastrophe/sert",
            {"sert.pyz": {"name": "sert-0.1.0.pyz", "url": "https://x/y", "sha256": "a" * 64}},
        )
        plain = subprocess.run([sys.executable, "-c", script], cwd=root, capture_output=True, text=True)
        (root / "sert.toml").write_bytes(b"\xef\xbb\xbf" + (root / "sert.toml").read_bytes())
        bom = subprocess.run([sys.executable, "-c", script], cwd=root, capture_output=True, text=True)
        self.assertEqual((bom.returncode, bom.stdout), (0, plain.stdout))
        self.assertRegex(bom.stdout, r"^hash=[0-9a-f]{32}$")

        # Changing sert.lock or rokit.toml changes the pin hash
        lock.write_lock(
            root,
            "0.1.0",
            "kohltastrophe/sert",
            {"sert.pyz": {"name": "sert-0.1.0.pyz", "url": "https://x/y", "sha256": "b" * 64}},
        )
        changed = subprocess.run([sys.executable, "-c", script], cwd=root, capture_output=True, text=True)
        self.assertNotEqual(changed.stdout, plain.stdout)

        bash = shutil.which("bash")
        if bash:
            server = self.release_server()
            self.publish_raw(server, "JohnnyMorganz/luau-lsp", "1.70.0", "scripts/globalTypes.d.luau", b"declare class Instance\nend\n")
            line = next(l for l in self.step("Fetch sert and the pinned deps").splitlines() if "-m sert fetch" in l)
            (root / "sert.py").write_text("raise SystemExit('the workspace sert.py ran')\n")
            ref_dir = root / ".sert/sert-ref"
            ref_dir.parent.mkdir(exist_ok=True)
            try:
                ref_dir.symlink_to(REPO, target_is_directory=True)
            except OSError:
                helpers.copy_repo(ref_dir)
            env = {k: v for k, v in os.environ.items() if k not in ("PYTHONPATH", "SERT_ROOT", "SERT_SOURCE", "CI")}
            env.update(
                PY=sys.executable.replace("\\", "/"),
                WORKSPACE=root.as_posix(),
                SERT_GITHUB_URL=server.as_uri(),
                SERT_RAW_URL=server.as_uri(),
                SERT_CACHE=str(self.tmp / "act-cache"),
            )
            res = subprocess.run([bash, "-c", line.strip()], cwd=root, env=env, capture_output=True, text=True, timeout=30)
            self.assertEqual((res.returncode, "the workspace sert.py ran" in res.stderr), (0, False), res.stderr)


if __name__ == "__main__":
    unittest.main()
