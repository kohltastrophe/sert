"""Shared fixtures for sert's unittest suite. Importing this puts python/ on sys.path."""

from __future__ import annotations

import contextlib
import hashlib
import http.server
import io
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import threading
import unittest
import zipfile

PYTHON = Path(__file__).resolve().parent.parent
REPO = PYTHON.parent
if str(PYTHON) not in sys.path:
    sys.path.insert(0, str(PYTHON))

from sert import cli  # noqa: E402


def sha(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def zip_bytes(entries: dict[str, bytes], modes: dict[str, int] | None = None) -> bytes:
    out = io.BytesIO()
    with zipfile.ZipFile(out, "w") as archive:
        for name, data in sorted(entries.items()):
            info = zipfile.ZipInfo(name, (1980, 1, 1, 0, 0, 0))
            info.external_attr = ((modes or {}).get(name, 0o100644)) << 16
            archive.writestr(info, data)
    return out.getvalue()


class Case(unittest.TestCase):
    """A temp dir per test, an isolated environment (cache, CI unset) and a `sert(...)` runner."""

    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory(prefix="sert-test-")
        self.tmp = Path(self._tmp.name).resolve()
        self.addCleanup(self._tmp.cleanup)
        shutil.copy2(REPO / "rokit.toml", self.tmp / "rokit.toml")
        self.env = {}
        self.setenv("SERT_CACHE", str(self.tmp / "cache"))
        self.setenv("CI", None)
        self.setenv("SERT_ROOT", None)
        self.setenv("SERT_PYTHON", None)
        self.setenv("SERT_SOURCE", None)
        self.setenv("GITHUB_TOKEN", None)
        self.setenv("GITHUB_ACTIONS", None)
        self.setenv("GITHUB_STEP_SUMMARY", None)
        self.setenv("SERT_OFFLINE", None)
        self.setenv("SERT_RETRY_DELAY", "0")
        self.setenv("SERT_GITHUB_URL", (self.tmp / "no-releases").as_uri())  # nothing reaches the network
        self.setenv("SERT_RAW_URL", (self.tmp / "no-raw").as_uri())

    def setenv(self, key: str, value: str | None) -> None:
        old = os.environ.get(key)
        if value is None:
            os.environ.pop(key, None)
        else:
            os.environ[key] = value

        def restore():
            if old is None:
                os.environ.pop(key, None)
            else:
                os.environ[key] = old

        self.addCleanup(restore)

    def project(self, toml: str = "", local: str | None = None, name: str = "proj") -> Path:
        root = self.tmp / name
        root.mkdir(parents=True, exist_ok=True)
        (root / "sert.toml").write_text(toml)
        if local is not None:
            (root / "sert.local.toml").write_text(local)
        return root

    def sert(self, *argv: str) -> tuple[int, str, str]:
        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            code = cli.main([str(a) for a in argv])
        return code, out.getvalue(), err.getvalue()

    def write_fake_tool(self, path: Path, body: str) -> Path:
        return write_fake_tool(path, body)

    def release_server(self) -> Path:
        """A directory served as SERT_GITHUB_URL and SERT_RAW_URL (file://)."""
        server = self.tmp / "server"
        server.mkdir(exist_ok=True)
        self.setenv("SERT_GITHUB_URL", server.as_uri())
        self.setenv("SERT_RAW_URL", server.as_uri())
        return server

    def publish(self, server: Path, repo: str, tag: str, asset: str, data: bytes) -> str:
        path = server / repo / "releases" / "download" / tag / asset
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data)
        return sha(data)

    def publish_raw(self, server: Path, repo: str, ref: str, rel_path: str, data: bytes) -> str:
        path = server / repo / ref / rel_path
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data)
        return sha(data)

    def serve(self, handler) -> str:
        """Serves `handler` (a BaseHTTPRequestHandler class) on 127.0.0.1 until the test ends; returns its base URL."""
        server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), handler)
        threading.Thread(target=server.serve_forever, args=(0.01,), daemon=True).start()
        self.addCleanup(server.server_close)
        self.addCleanup(server.shutdown)
        return f"http://127.0.0.1:{server.server_port}"


def truncating_handler(body: bytes, whole_after: int | None = None):
    """A handler that announces twice `body`'s length and closes after `body`, until `whole_after` requests have been
    cut short (never, when None); then it serves `body` whole. `.requests` counts the GETs."""

    class Handler(http.server.BaseHTTPRequestHandler):
        requests = 0

        def do_GET(self):
            Handler.requests += 1
            short = whole_after is None or Handler.requests <= whole_after
            self.send_response(200)
            self.send_header("Content-Length", str(len(body) * (2 if short else 1)))
            self.end_headers()
            self.wfile.write(body)
            self.close_connection = True

        def log_message(self, *args):
            pass

    return Handler


def git(root: Path, *args: str, env: dict | None = None) -> str:
    result = subprocess.run(["git", "-C", str(root), *args], capture_output=True, text=True, env=env, check=True)
    return result.stdout.strip()


def git_repo(root: Path) -> Path:
    root.mkdir(parents=True, exist_ok=True)
    git(root, "init", "-q", "-b", "main")
    git(root, "config", "user.name", "Test")
    git(root, "config", "user.email", "test@example.com")
    git(root, "config", "commit.gpgsign", "false")
    return root


def have(tool: str) -> bool:
    return shutil.which(tool) is not None


def write_fake_tool(path: Path, body: str) -> Path:
    path.parent.mkdir(parents=True, exist_ok=True)
    if body.startswith("#!"):
        body = body.split("\n", 1)[1] if "\n" in body else ""
    header = (
        f"#!{sys.executable}\n"
        "import io, os, sys\n"
        "if hasattr(sys.stdout, 'reconfigure'):\n"
        "    sys.stdout.reconfigure(encoding='utf-8', newline='\\n')\n"
        "    sys.stderr.reconfigure(encoding='utf-8', newline='\\n')\n"
    )
    path.write_text(header + body, encoding="utf-8", newline="\n")
    path.chmod(0o755)
    if os.name == "nt":
        cmd = path.with_suffix(".cmd")
        cmd.write_text(f'@"{sys.executable}" "{path}" %*\r\n', encoding="utf-8")
    return path


def copy_sert_src(dst: Path | str) -> Path:
    """Copy `REPO / 'src'` to temporary test directory `dst` without touching `REPO / 'src'`."""
    out = Path(dst)
    shutil.copytree(REPO / "src", out, ignore=shutil.ignore_patterns("__pycache__"))
    return out


def copy_repo(dst: Path | str) -> Path:
    root = Path(dst)
    root.mkdir(parents=True, exist_ok=True)
    copy_sert_src(root / "src")
    for part in ("python/sert", "tools"):
        shutil.copytree(REPO / part, root / part, ignore=shutil.ignore_patterns("__pycache__"))
    shutil.copy2(REPO / "default.project.json", root)
    shutil.copy2(REPO / "LICENSE.txt", root)
    return root
