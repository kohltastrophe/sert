"""`sert release`: dist branch publishing (`dist`) and asset packing (`pack`)."""

from __future__ import annotations

import os
from pathlib import Path
import re
import subprocess
import tempfile
import tomllib
import zipfile

from sert import config as config_mod
from sert.fetch import sha256_file
from sert.util import SertError, as_list, git

ZERO = "0" * 40

ZIP_TIME = (1980, 1, 1, 0, 0, 0)
SHEBANG = b"#!/usr/bin/env python3\n"
PACKAGE = ["LICENSE.txt", "default.project.json", "src"]
STUB_ENTRY = "sert/_stub/sert.py"
LICENSE = "LICENSE.txt"
LICENSE_ENTRY = "sert/LICENSE.txt"


def resolve_version(cfg: config_mod.Config, rev: str, explicit_version: str | None = None) -> str:
    if explicit_version:
        return explicit_version
    if explicit := cfg.get("dist.version"):
        return str(explicit)
    result = subprocess.run(
        ["git", "-C", str(cfg.root), "show", f"{rev}:wally.toml"],
        capture_output=True,
        text=True,
        encoding="utf-8",
        errors="replace",
        timeout=60,
    )
    if result.returncode == 0:
        try:
            ver = tomllib.loads(result.stdout).get("package", {}).get("version")
            if isinstance(ver, str) and ver:
                return ver
        except tomllib.TOMLDecodeError:
            pass
    return git(cfg.root, "describe", "--tags", "--always", rev)


def identity_env(root: Path) -> dict | None:
    env = dict(os.environ)
    for role in ("AUTHOR", "COMMITTER"):
        if subprocess.run(["git", "-C", str(root), "var", f"GIT_{role}_IDENT"], capture_output=True, text=True, encoding="utf-8", errors="replace", timeout=60).returncode != 0:
            env.setdefault(f"GIT_{role}_NAME", "sert")
            env.setdefault(f"GIT_{role}_EMAIL", "sert@localhost")
    return env


def build_tree(root: Path, rev: str, paths: list[str]) -> str:
    with tempfile.TemporaryDirectory(prefix="sert-dist-") as scratch:
        env = dict(os.environ, GIT_INDEX_FILE=str(Path(scratch) / "index"))
        git(root, "read-tree", "--empty", env=env)
        for path in paths:
            clean = path.strip("/")
            entries = [line for line in git(root, "ls-tree", rev, "--", clean).splitlines() if line.split("\t", 1)[-1] == clean]
            if not entries:
                raise SertError(f"dist: {clean} is not in {rev}")
            mode, kind, sha = entries[0].split("\t", 1)[0].split()
            if kind == "tree":
                git(root, "read-tree", f"--prefix={clean}/", sha, env=env)
            else:
                git(root, "update-index", "--add", "--cacheinfo", f"{mode},{sha},{clean}", env=env)
        return git(root, "write-tree", env=env)


def main_dist(args) -> int:
    cfg = config_mod.from_args(args, require=True)
    table = cfg.table("dist")
    paths = [str(p) for p in as_list(table.get("paths"))]
    if not paths:
        raise SertError("sert.toml: [dist].paths is required")
    branch, name = table.get("branch", "dist"), table.get("name", cfg.root.name)
    ref = f"refs/heads/{branch}"
    source = git(cfg.root, "rev-parse", "--verify", f"{args.rev}^{{commit}}")
    tree = build_tree(cfg.root, source, paths)
    tip = git(cfg.root, "rev-parse", "--verify", "--quiet", f"{ref}^{{commit}}", check=False) or None
    if tip and git(cfg.root, "rev-parse", f"{tip}^{{tree}}") == tree:
        print(f"dist: {branch} is up to date ({tip[:12]}, tree {tree[:12]})")
        return 0
    message = f"dist: {name} {resolve_version(cfg, source, getattr(args, 'version', None))} (from {source})"
    if args.dry_run:
        print(f"dist (dry run): would commit tree {tree[:12]} to {branch} {'on ' + tip[:12] if tip else 'as the first commit'}: {message}")
        return 0
    command = ["commit-tree", tree, *(["-p", tip] if tip else []), "-m", message]
    commit = git(cfg.root, *command, env=identity_env(cfg.root))
    git(cfg.root, "update-ref", "-m", message, ref, commit, tip or ZERO)
    print(f"dist: {branch} -> {commit[:12]}: {message}")
    return 0


def write_zip(destination: Path, entries, prefix: bytes = b"") -> None:
    with open(destination, "wb") as handle:
        handle.write(prefix)
        with zipfile.ZipFile(handle, "w") as archive:
            for name, data in sorted(entries):
                info = zipfile.ZipInfo(name, ZIP_TIME)
                info.create_system, info.external_attr, info.compress_type = 3, 0o100644 << 16, zipfile.ZIP_DEFLATED
                archive.writestr(info, data, compresslevel=9)


def _skipped(path: Path) -> bool:
    return "__pycache__" in path.parts or path.suffix == ".pyc" or path.name == ".DS_Store"


def tree_files(root: Path, paths) -> list[tuple[str, bytes]]:
    out = []
    for relative in paths:
        path = root / relative
        if not path.exists():
            raise SertError(f"pack: {relative} not found under {root}")
        for file in [path] if path.is_file() else sorted(path.rglob("*")):
            if file.is_file() and not _skipped(file.relative_to(root)):
                out.append((file.relative_to(root).as_posix(), file.read_bytes()))
    return sorted(out)


def version_of(root: Path) -> str:
    init = root / "python" / "sert" / "__init__.py"
    if not (match := re.search(r'^VERSION\s*=\s*"([^"]+)"', init.read_text(encoding="utf-8"), re.M) if init.is_file() else None):
        raise SertError(f'pack: no VERSION = "..." in {init}')
    return match.group(1)


def pyz_entries(root: Path) -> list[tuple[str, bytes]]:
    package = root / "python"
    entries = tree_files(package, ["sert"])
    if (stub := root / "tools" / "sert.py").is_file():
        entries.append((STUB_ENTRY, stub.read_bytes()))
    if not (license_file := root / LICENSE).is_file():
        raise SertError(f"pack: {LICENSE} not found under {root}")
    entries.append((LICENSE_ENTRY, license_file.read_bytes()))
    entries.append(("__main__.py", (package / "sert" / "__main__.py").read_bytes()))
    return entries


def build(root: Path, out: Path) -> dict[str, str]:
    version = version_of(root)
    out.mkdir(parents=True, exist_ok=True)
    names = {"zip": f"sert-{version}.zip", "pyz": f"sert-{version}.pyz"}
    write_zip(out / names["zip"], tree_files(root, PACKAGE))
    write_zip(out / names["pyz"], pyz_entries(root), prefix=SHEBANG)
    (out / names["pyz"]).chmod(0o755)
    hashes = {name: sha256_file(out / name) for name in sorted(names.values())}
    (out / "SHA256SUMS").write_text("".join(f"{digest}  {name}\n" for name, digest in hashes.items()), encoding="utf-8", newline="\n")
    return hashes


def main_pack(args) -> int:
    root = config_mod.find_root(getattr(args, "root", None))
    out = (root / args.out).resolve()
    hashes = build(root, out)
    print(f"sert {version_of(root)} release assets in {out}:")
    for name, digest in hashes.items():
        print(f"  {digest}  {name}")
    return 0


def _configure_dist_parser(parser) -> None:
    parser.add_argument("--from", dest="rev", default="HEAD", metavar="REV", help="source revision (default: HEAD)")
    parser.add_argument("--version", help="release version label for the dist commit message")
    parser.add_argument("--dry-run", action="store_true", help="print what would be committed; change nothing")
    parser.set_defaults(func=main_dist)


def _configure_pack_parser(parser) -> None:
    parser.add_argument("--out", default="dist", help="output directory, relative to the root (default: dist/)")
    parser.set_defaults(func=main_pack)


def add_parser(subparsers) -> None:
    parser = subparsers.add_parser("release")
    actions = parser.add_subparsers(dest="action", metavar="<action>", required=True)
    _configure_dist_parser(actions.add_parser("dist", help="commit the [dist].paths tree of a revision onto the dist branch"))
    _configure_pack_parser(actions.add_parser("pack", help="build sert's reproducible release assets (zip, pyz, SHA256SUMS)"))


def add_dist_parser(subparsers) -> None:
    _configure_dist_parser(subparsers.add_parser("dist"))


def add_pack_parser(subparsers) -> None:
    _configure_pack_parser(subparsers.add_parser("pack"))
