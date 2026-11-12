"""Unit tests for `sert fetch` and `sert init`: SHA-256 + `sert.lock` verification, JSONC `.luaurc`, private-repo API, and archive safety."""

from __future__ import annotations

import functools
import http.server
import json
import os
import pathlib
import shutil
import threading
import tomllib
import unittest
import urllib.parse
import urllib.request
import zipfile
from unittest import mock

from helpers import REPO, Case, copy_sert_src, git_repo, have, sha, truncating_handler, zip_bytes
from sert import LUAU_LSP, VERSION, config, fetch, lock, luau_lex, util
from sert.util import SertError, write_atomic

SERT_ZIP = zip_bytes({"default.project.json": b"{}", "src/init.luau": b"return {}\n"})
SERT_PYZ = b"#!/usr/bin/env python3\nPK-not-really\n"
TYPES_BYTES = b"declare class Instance\nend\n"


class FetchAndHttpTest(Case):
    def setUp(self):
        super().setUp()
        fetch._RELEASE_ASSETS_CACHE.clear()
        self.server = self.release_server()
        self.zip_sha = self.publish(self.server, "kohltastrophe/sert", "v0.1.0", "sert-0.1.0.zip", SERT_ZIP)
        self.pyz_sha = self.publish(self.server, "kohltastrophe/sert", "v0.1.0", "sert-0.1.0.pyz", SERT_PYZ)
        sums_body = f"{self.pyz_sha}  sert-0.1.0.pyz\n{self.zip_sha}  sert-0.1.0.zip\n".encode("utf-8")
        self.publish(self.server, "kohltastrophe/sert", "v0.1.0", "SHA256SUMS", sums_body)
        self.types_sha = self.publish_raw(self.server, "JohnnyMorganz/luau-lsp", LUAU_LSP, "scripts/globalTypes.d.luau", TYPES_BYTES)

    def test_fetch_lock_verification_and_offline_cache(self):
        root = self.project('[sert]\nversion = "0.1.0"\n')
        (root / "rokit.toml").write_text(f'[tools]\nluau-lsp = "JohnnyMorganz/luau-lsp@{LUAU_LSP}"\n', encoding="utf-8")
        code, out, err = self.sert("fetch", "--root", root)
        self.assertEqual(code, 0, out + err)
        self.assertEqual((root / ".sert/sert/src/init.luau").read_bytes(), b"return {}\n")
        self.assertEqual((root / ".sert/types/globalTypes.d.luau").read_bytes(), TYPES_BYTES)
        self.assertTrue((root / "sert.lock").is_file())

        written_lock = lock.load_lock(root)
        assert written_lock is not None
        self.assertEqual(written_lock["version"], "0.1.0")
        self.assertEqual(written_lock["assets"]["sert.pyz"]["sha256"], self.pyz_sha)
        self.assertEqual(written_lock["assets"]["sert.zip"]["sha256"], self.zip_sha)
        self.assertEqual(written_lock["assets"]["globalTypes.d.luau"]["sha256"], self.types_sha)
        self.assertEqual(written_lock["assets"]["globalTypes.d.luau"]["lsp_version"], LUAU_LSP)

        # Offline fetch succeeds from cache + sert.lock even when release server is removed
        shutil.rmtree(self.server)
        code_off, _, err_off = self.sert("fetch", "--root", root, "--offline")
        self.assertEqual(code_off, 0, err_off)

        # Offline fetch into an empty cache fails cleanly
        self.setenv("SERT_CACHE", str(self.tmp / "empty-cache"))
        self.assertEqual(self.sert("fetch", "--root", root, "--offline")[0], 2)

    def test_tamper_rejection_in_fetch(self):
        # Tamper with sert-0.1.0.zip on the server so it disagrees with SHA256SUMS
        self.publish(self.server, "kohltastrophe/sert", "v0.1.0", "sert-0.1.0.zip", SERT_ZIP + b"corrupted")
        root = self.project('[sert]\nversion = "0.1.0"\n', name="tamper")
        code, _, err = self.sert("fetch", "--root", root, "--only", "sert")
        self.assertEqual((code, "SHA-256 verification failed" in err), (2, True), err)

        # Restore valid zip, write a mismatched sert.lock, and verify fetch refuses it
        self.publish(self.server, "kohltastrophe/sert", "v0.1.0", "sert-0.1.0.zip", SERT_ZIP)
        root2 = self.project('[sert]\nversion = "0.1.0"\n', name="mismatch")
        lock.write_lock(
            root2,
            "0.1.0",
            "kohltastrophe/sert",
            {
                "sert.pyz": {"name": "sert-0.1.0.pyz", "url": "https://x/p", "sha256": self.pyz_sha},
                "sert.zip": {"name": "sert-0.1.0.zip", "url": "https://x/z", "sha256": "f" * 64},
            },
        )
        code2, _, err2 = self.sert("fetch", "--root", root2, "--only", "sert")
        self.assertEqual((code2, "SHA-256 mismatch" in err2), (2, True), err2)

    def test_private_repo_github_token_release_api_and_redirect_auth_stripping(self):
        sums_body = f"{self.pyz_sha}  sert-0.1.0.pyz\n{self.zip_sha}  sert-0.1.0.zip\n".encode("utf-8")
        seen_requests: list[tuple[str, str | None, str | None]] = []

        class PrivateReleaseHandler(http.server.BaseHTTPRequestHandler):
            def do_GET(self):
                parsed = urllib.parse.urlsplit(self.path)
                seen_requests.append((parsed.path, self.headers.get("Authorization"), self.headers.get("Accept")))
                base = f"http://127.0.0.1:{self.server.server_port}"
                if parsed.path == "/repos/org/priv-sert/releases/tags/v0.1.0":
                    payload = {
                        "assets": [
                            {"name": "SHA256SUMS", "url": f"{base}/api-assets/sums"},
                            {"name": "sert-0.1.0.pyz", "url": f"{base}/api-assets/pyz"},
                            {"name": "sert-0.1.0.zip", "url": f"{base}/api-assets/zip"},
                        ]
                    }
                    raw = json.dumps(payload).encode("utf-8")
                    self.send_response(200)
                    self.send_header("Content-Length", str(len(raw)))
                    self.end_headers()
                    self.wfile.write(raw)
                elif parsed.path == "/api-assets/sums":
                    self.send_response(200)
                    self.send_header("Content-Length", str(len(sums_body)))
                    self.end_headers()
                    self.wfile.write(sums_body)
                elif parsed.path == "/api-assets/pyz":
                    self.send_response(200)
                    self.send_header("Content-Length", str(len(SERT_PYZ)))
                    self.end_headers()
                    self.wfile.write(SERT_PYZ)
                elif parsed.path == "/api-assets/zip":
                    self.send_response(200)
                    self.send_header("Content-Length", str(len(SERT_ZIP)))
                    self.end_headers()
                    self.wfile.write(SERT_ZIP)
                else:
                    self.send_response(404)
                    self.end_headers()

            def log_message(self, *args):
                pass

        api_base = self.serve(PrivateReleaseHandler)
        self.setenv("GITHUB_TOKEN", "ghs_private_token")
        self.setenv("SERT_GITHUB_API_URL", api_base)
        self.addCleanup(self.setenv, "SERT_GITHUB_API_URL", None)

        priv_root = self.project('[sert]\nrepo = "org/priv-sert"\nversion = "0.1.0"\n', name="priv-fetch")
        code, _, err = self.sert("fetch", "--root", priv_root)
        self.assertEqual(code, 0, err)
        self.assertIn(("/repos/org/priv-sert/releases/tags/v0.1.0", "Bearer ghs_private_token", "application/vnd.github+json"), seen_requests)
        self.assertIn(("/api-assets/zip", "Bearer ghs_private_token", "application/octet-stream"), seen_requests)
        self.assertEqual((priv_root / ".sert/types/globalTypes.d.luau").read_bytes(), TYPES_BYTES)

        redirected = fetch._DropAuthOnHostChange().redirect_request(
            urllib.request.Request("https://api.github.com/repos/a/b/releases/assets/1", headers={"Authorization": "Bearer secret"}),
            None,
            302,
            "Found",
            {},
            "https://objects.githubusercontent.com/blob",
        )
        assert redirected is not None
        self.assertFalse(redirected.has_header("Authorization"))

    def test_jsonc_luaurc_updating_preserves_comments_and_trailing_commas(self):
        root = self.project('[sert]\nversion = "0.1.0"\n', name="jsonc")
        jsonc_content = (
            "// Project Luau configuration\n"
            "{\n"
            '  "languageMode": "strict",\n'
            "  /* Keep existing package aliases */\n"
            '  "aliases": {\n'
            '    "pkg": "./Packages",\n'
            "  },\n"
            "}\n"
        )
        (root / ".luaurc").write_text(jsonc_content, encoding="utf-8")
        code, _, err = self.sert("fetch", "--root", root, "--only", "sert")
        self.assertEqual(code, 0, err)
        updated_raw = (root / ".luaurc").read_text(encoding="utf-8")
        self.assertIn("// Project Luau configuration", updated_raw)
        self.assertIn("/* Keep existing package aliases */", updated_raw)
        parsed = util.load_json(root / ".luaurc")
        self.assertEqual(parsed["aliases"]["pkg"], "./Packages")
        self.assertEqual(parsed["aliases"]["sert"], "./.sert/sert/src")

    def test_overrides_archive_safety_truncation_and_write_atomic(self):
        sert_checkout = self.tmp / "sert-checkout"
        (sert_checkout / "src").mkdir(parents=True)
        (sert_checkout / "src/init.luau").write_text("return 'local-sert'\n", encoding="utf-8")
        (sert_checkout / "default.project.json").write_text("{}", encoding="utf-8")

        root = self.project('[sert]\nversion = "0.1.0"\n', '[override]\nsert = "../sert-checkout"\n', name="ov")
        cfg = config.load(root)
        self.assertEqual(fetch.refresh_overrides(cfg), 1)
        self.assertEqual((root / ".sert/sert/src/init.luau").read_text(encoding="utf-8"), "return 'local-sert'\n")

        self.setenv("CI", "true")
        with self.assertRaisesRegex(SertError, r"CI=true"):
            fetch.refresh_overrides(cfg)
        with self.assertRaisesRegex(SertError, r"CI=true"):
            fetch.ensure_fetched(cfg)
        self.setenv("CI", None)

        # Path traversal & symlink rejection in extract_archive
        evil_zip = self.tmp / "evil.zip"
        evil_zip.write_bytes(zip_bytes({"../escape.txt": b"nope"}))
        with self.assertRaisesRegex(SertError, r"climbs out of destination"):
            fetch.extract_archive(evil_zip, self.tmp / "evil-out")

        symlink_zip = self.tmp / "symlink.zip"
        with zipfile.ZipFile(symlink_zip, "w") as zf:
            info = zipfile.ZipInfo("link.txt")
            info.external_attr = 0o120777 << 16
            zf.writestr(info, "/etc/passwd")
        with self.assertRaisesRegex(SertError, r"refusing symlink"):
            fetch.extract_archive(symlink_zip, self.tmp / "sym-out")

        # IncompleteRead detection on truncated HTTP streams
        handler = truncating_handler(b"x" * 1000)
        turl = self.serve(handler) + "/a.zip"
        with self.assertRaisesRegex(SertError, r"IncompleteRead"):
            fetch.download(turl, self.tmp / "trunc.zip")
        with self.assertRaisesRegex(SertError, r"IncompleteRead"):
            fetch.read_url(turl)

        target = self.tmp / "dir/tool"
        write_atomic(target, b"new", 0o755)
        self.assertEqual(target.read_bytes(), b"new")
        with mock.patch.object(os, "replace", side_effect=OSError("busy")), self.assertRaises(OSError):
            write_atomic(target, b"newer")
        self.assertEqual([p.name for p in target.parent.iterdir()], ["tool"])


class InitTest(Case):
    def publish_current_release(self):
        server = self.release_server()
        tag = f"v{VERSION}"
        clean_src = copy_sert_src(self.tmp / "clean_src")
        files = {
            f"src/{p.relative_to(clean_src).as_posix()}": p.read_bytes()
            for p in sorted(clean_src.rglob("*"))
            if p.is_file()
        }
        files["default.project.json"] = (REPO / "default.project.json").read_bytes()
        zip_data = zip_bytes(files)
        pyz_data = b"#!/usr/bin/env python3\n"
        z_sha = self.publish(server, "kohltastrophe/sert", tag, f"sert-{VERSION}.zip", zip_data)
        p_sha = self.publish(server, "kohltastrophe/sert", tag, f"sert-{VERSION}.pyz", pyz_data)
        sums = f"{p_sha}  sert-{VERSION}.pyz\n{z_sha}  sert-{VERSION}.zip\n".encode("utf-8")
        self.publish(server, "kohltastrophe/sert", tag, "SHA256SUMS", sums)
        self.publish_raw(server, "JohnnyMorganz/luau-lsp", LUAU_LSP, "scripts/globalTypes.d.luau", TYPES_BYTES)

    def test_init_scaffolds_sert_toml_rokit_toml_stub_and_zero_return_spec(self):
        bare = self.tmp / "bare"
        written = fetch.init(bare)
        for expected in ("sert.toml", "rokit.toml", "tools/sert.py", ".gitignore", ".luaurc", "test/example.spec.luau"):
            self.assertIn(expected, written)
            self.assertTrue((bare / expected).is_file(), expected)

        cfg = config.load(bare)
        self.assertEqual((cfg.get("sert.version"), config.problems_in(cfg.shared)), (VERSION, []))
        rokit_tools = tomllib.loads((bare / "rokit.toml").read_text(encoding="utf-8"))["tools"]
        self.assertIn("luau", rokit_tools)
        self.assertIn("luau-lsp", rokit_tools)

        # Starter spec is 0-return (`has_top_level_return` is False)
        starter_src = (bare / "test/example.spec.luau").read_text(encoding="utf-8")
        self.assertFalse(luau_lex.has_top_level_return(starter_src))

        # Re-running init without --force writes nothing
        self.assertEqual(fetch.init(bare), [])

    @unittest.skipUnless(have("luau"), "luau not on PATH")
    def test_initialized_repo_fetches_and_runs_zero_return_starter_spec(self):
        self.publish_current_release()
        root = git_repo(self.tmp / "fresh")
        self.assertEqual(self.sert("init", "--root", root)[0], 0)
        self.setenv("SERT_OFFLINE", "1")
        self.assertEqual(self.sert("run", "--root", root)[0], 2)
        self.setenv("SERT_OFFLINE", None)
        code, out, err = self.sert("run", "--root", root)
        self.assertEqual(code, 0, out + err)
        self.assertIn("2 passed · 0 failed", out)


if __name__ == "__main__":
    unittest.main()
