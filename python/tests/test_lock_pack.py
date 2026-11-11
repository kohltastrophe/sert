"""Unit tests for `sert.lock` and `scripts/pack.py`: byte-reproducible archives and SHA-256 tamper rejection."""

from __future__ import annotations

import importlib.util
from pathlib import Path
import unittest
import zipfile

import helpers
from helpers import REPO, Case
from sert import VERSION, lock
from sert.util import SertError


def _load_pack():
    spec = importlib.util.spec_from_file_location("sert_pack", REPO / "scripts" / "pack.py")
    assert spec is not None and spec.loader is not None
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


pack = _load_pack()


class LockAndPackTest(Case):
    def test_pack_reproducibility_and_sha256sums(self) -> None:
        repo = helpers.copy_repo(self.tmp / "repo")
        out1 = self.tmp / "dist1"
        out2 = self.tmp / "dist2"
        hashes1 = pack.build(repo, out1)
        hashes2 = pack.build(repo, out2)
        self.assertEqual(hashes1, hashes2)

        zip_name = f"sert-{VERSION}.zip"
        pyz_name = f"sert-{VERSION}.pyz"
        for name in (zip_name, pyz_name, "SHA256SUMS"):
            self.assertEqual((out1 / name).read_bytes(), (out2 / name).read_bytes(), name)

        parsed = lock.parse_sha256sums((out1 / "SHA256SUMS").read_text(encoding="utf-8"))
        self.assertEqual(parsed, hashes1)
        for name, expected in hashes1.items():
            self.assertEqual(lock.verify_file(name, out1 / name, expected), expected)

        with zipfile.ZipFile(out1 / zip_name) as zf:
            names = [info.filename for info in zf.infolist()]
            self.assertEqual(names, sorted(names))
            for info in zf.infolist():
                self.assertEqual(info.date_time, (1980, 1, 1, 0, 0, 0))
                self.assertEqual(info.external_attr, 0o100644 << 16)
            self.assertIn("src/init.luau", names)
            self.assertIn("default.project.json", names)

        with zipfile.ZipFile(out1 / pyz_name) as zf:
            self.assertEqual(zf.read(pack.STUB_ENTRY), (REPO / "tools" / "sert.py").read_bytes())
            self.assertIn("__main__.py", zf.namelist())

    def test_lock_roundtrip_tamper_rejection_and_rokit_pin(self) -> None:
        root = self.project('[sert]\nversion = "0.1.0"\n')
        good_sha = "a" * 64
        other_sha = "b" * 64
        types_sha = "c" * 64
        assets = {
            "sert.pyz": {"name": "sert-0.1.0.pyz", "url": "https://example.com/sert-0.1.0.pyz", "sha256": good_sha},
            "sert.zip": {"name": "sert-0.1.0.zip", "url": "https://example.com/sert-0.1.0.zip", "sha256": other_sha},
            "globalTypes.d.luau": {
                "name": "globalTypes.d.luau",
                "url": "https://example.com/globalTypes.d.luau",
                "sha256": types_sha,
                "lsp_version": "1.70.0",
            },
        }
        written = lock.write_lock(root, "0.1.0", "kohltastrophe/sert", assets)
        self.assertTrue(written.is_file())
        loaded = lock.load_lock(root)
        assert loaded is not None
        self.assertEqual(loaded["version"], "0.1.0")
        self.assertEqual(loaded["assets"]["sert.pyz"]["sha256"], good_sha)
        self.assertEqual(loaded["assets"]["globalTypes.d.luau"]["lsp_version"], "1.70.0")

        with self.assertRaisesRegex(SertError, r"SHA-256 verification failed"):
            lock.verify_bytes("sert-0.1.0.pyz", b"tampered payload", good_sha)

        sample_file = self.tmp / "blob.bin"
        sample_file.write_bytes(b"authentic")
        real_sha = lock.sha256_bytes(b"authentic")
        self.assertEqual(lock.verify_file("blob.bin", sample_file, real_sha), real_sha)
        sample_file.write_bytes(b"corrupted")
        with self.assertRaisesRegex(SertError, r"SHA-256 verification failed"):
            lock.verify_file("blob.bin", sample_file, real_sha)

        for bad_lock in (
            'schema = 99\nversion = "0.1.0"\n[assets]\n',
            'schema = 1\nversion = ""\n[assets]\n',
            'schema = 1\nversion = "0.1.0"\n[assets."sert.pyz"]\nurl = "https://x"\nsha256 = "not-hex"\n',
        ):
            (root / "sert.lock").write_text(bad_lock, encoding="utf-8")
            with self.assertRaises(SertError):
                lock.load_lock(root)

        for bad_sums in ("", "not_a_sha  sert-0.1.0.pyz\n", f"{good_sha}\n"):
            with self.assertRaises(SertError):
                lock.parse_sha256sums(bad_sums)

        (root / "rokit.toml").write_text('[tools]\nluau-lsp = "JohnnyMorganz/luau-lsp@1.71.2"\n', encoding="utf-8")
        self.assertEqual(lock.read_rokit_lsp_version(root), "1.71.2")


if __name__ == "__main__":
    unittest.main()
