#!/usr/bin/env python3
"""Build reproducible sert release archives (sert-<ver>.zip, sert-<ver>.pyz, SHA256SUMS)."""

from __future__ import annotations

import argparse
import hashlib
import io
import os
import re
import sys
import zipfile
from pathlib import Path

ZIP_TIME = (1980, 1, 1, 0, 0, 0)
REGULAR_ATTR = 0o100644 << 16
EXEC_ATTR = 0o100755 << 16
STUB_ENTRY = "sert/_stub/sert.py"
SKIP_NAMES = {"__pycache__", ".DS_Store", "Thumbs.db"}
SKIP_SUFFIXES = (".pyc", ".pyo")


def read_version(root: Path) -> str:
    init_py = root / "python" / "sert" / "__init__.py"
    text = init_py.read_text(encoding="utf-8")
    match = re.search(r'^VERSION\s*=\s*"([^"]+)"', text, re.MULTILINE)
    if not match:
        raise RuntimeError(f"could not find VERSION in {init_py}")
    version = match.group(1)
    env_ver = os.environ.get("VERSION", "").strip()
    if env_ver and env_ver != version:
        raise RuntimeError(f"VERSION={env_ver!r} does not match python/sert/__init__.py ({version!r})")
    return version


def _iter_files(directory: Path) -> list[Path]:
    found: list[Path] = []
    for cur, dirs, files in os.walk(directory):
        dirs[:] = sorted(d for d in dirs if d not in SKIP_NAMES and not d.startswith("."))
        for name in sorted(files):
            if name in SKIP_NAMES or name.startswith(".") or name.endswith(SKIP_SUFFIXES):
                continue
            path = Path(cur) / name
            if path.is_file() and not path.is_symlink():
                found.append(path)
    return found


def _write_deterministic_zip(entries: dict[str, bytes]) -> bytes:
    buf = io.BytesIO()
    with zipfile.ZipFile(buf, "w", compression=zipfile.ZIP_DEFLATED, compresslevel=9) as zf:
        for arcname in sorted(entries):
            info = zipfile.ZipInfo(filename=arcname, date_time=ZIP_TIME)
            info.compress_type = zipfile.ZIP_DEFLATED
            info.create_system = 3
            info.external_attr = REGULAR_ATTR
            zf.writestr(info, entries[arcname], compress_type=zipfile.ZIP_DEFLATED, compresslevel=9)
    return buf.getvalue()


def build_luau_zip(root: Path) -> bytes:
    entries: dict[str, bytes] = {}
    for top in ("LICENSE.txt", "default.project.json"):
        src = root / top
        if not src.is_file():
            raise RuntimeError(f"missing required package file: {src}")
        entries[top] = src.read_bytes()
    src_dir = root / "src"
    if not src_dir.is_dir():
        raise RuntimeError(f"missing src directory: {src_dir}")
    for path in _iter_files(src_dir):
        arcname = path.relative_to(root).as_posix()
        entries[arcname] = path.read_bytes()
    return _write_deterministic_zip(entries)


def build_pyz(root: Path) -> bytes:
    entries: dict[str, bytes] = {}
    pkg_dir = root / "python" / "sert"
    if not pkg_dir.is_dir():
        raise RuntimeError(f"missing python package directory: {pkg_dir}")
    for path in _iter_files(pkg_dir):
        rel = path.relative_to(root / "python").as_posix()
        entries[rel] = path.read_bytes()
    stub = root / "tools" / "sert.py"
    if not stub.is_file():
        raise RuntimeError(f"missing bootstrapper stub: {stub}")
    entries[STUB_ENTRY] = stub.read_bytes()
    license_file = root / "LICENSE.txt"
    if license_file.is_file():
        entries["sert/LICENSE.txt"] = license_file.read_bytes()
    entries["__main__.py"] = b"from sert.cli import main\nraise SystemExit(main())\n"
    return b"#!/usr/bin/env python3\n" + _write_deterministic_zip(entries)


def build(root: Path, out: Path) -> dict[str, str]:
    version = read_version(root)
    out.mkdir(parents=True, exist_ok=True)
    zip_name = f"sert-{version}.zip"
    pyz_name = f"sert-{version}.pyz"

    zip_bytes = build_luau_zip(root)
    pyz_bytes = build_pyz(root)

    zip_path = out / zip_name
    pyz_path = out / pyz_name
    zip_path.write_bytes(zip_bytes)
    pyz_path.write_bytes(pyz_bytes)
    os.chmod(pyz_path, 0o755)

    digests = {
        pyz_name: hashlib.sha256(pyz_bytes).hexdigest(),
        zip_name: hashlib.sha256(zip_bytes).hexdigest(),
    }
    sums_lines = [f"{digests[name]}  {name}\n" for name in sorted(digests)]
    (out / "SHA256SUMS").write_text("".join(sums_lines), encoding="utf-8", newline="\n")
    return digests


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Build reproducible sert release artifacts.")
    parser.add_argument("--out", default="dist", help="Output directory (default: dist)")
    parser.add_argument(
        "--root",
        default=str(Path(__file__).resolve().parents[1]),
        help="Repository root directory",
    )
    args = parser.parse_args(argv)
    try:
        digests = build(Path(args.root).resolve(), Path(args.out).resolve())
    except Exception as exc:
        print(f"pack: error: {exc}", file=sys.stderr)
        return 2
    for name in sorted(digests):
        print(f"{digests[name]}  {name}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
