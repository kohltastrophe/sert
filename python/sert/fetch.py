"""`sert fetch` and `sert init`: everything sert.toml pins, into `<root>/.sert/`."""

from __future__ import annotations

from collections.abc import Callable
import contextlib
import functools
import hashlib
import http.client
import json
import os
from pathlib import Path, PurePosixPath
import platform
import shutil
import ssl
import stat
import sys
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request
import zipfile

from sert import LUAU, LUAU_LSP, VERSION, config as config_mod
from sert.util import SertError, as_list, is_ci, note, sert_alias, sert_alias_key, strip_trailing_commas, warn, write_atomic

SERT_REPO = "kohltastrophe/sert"
CHUNK = 1 << 16
LSP_KEY = "luau_lsp"
TYPES_ASSET = "globalTypes.d.luau"
RETRIES = 3
CERT_HINT = "Python may need its certificates installed (macOS: run Install Certificates.command) or SSL_CERT_FILE set"

TOOLS = {
    "luau": {
        "repo": "luau-lang/luau",
        "tag": "{version}",
        "assets": {
            "linux-x86_64": "luau-ubuntu.zip",
            "linux-aarch64": "luau-ubuntu.zip",
            "macos-x86_64": "luau-macos.zip",
            "macos-aarch64": "luau-macos.zip",
            "windows-x86_64": "luau-windows.zip",
        },
        "binaries": ["luau"],
    },
    "lute": {
        "repo": "luau-lang/lute",
        "tag": "v{version}",
        "assets": {
            "linux-x86_64": "lute-linux-x86_64.zip",
            "linux-aarch64": "lute-linux-aarch64.zip",
            "macos-aarch64": "lute-macos-aarch64.zip",
            "windows-x86_64": "lute-windows-x86_64.zip",
        },
        "binaries": ["lute"],
    },
}


def github_base() -> str:
    return os.environ.get("SERT_GITHUB_URL", "https://github.com").rstrip("/")


def raw_base() -> str:
    return os.environ.get("SERT_RAW_URL", "https://raw.githubusercontent.com").rstrip("/")


def release_url(repo: str, tag: str, asset: str) -> str:
    return f"{github_base()}/{repo}/releases/download/{tag}/{asset}"


def default_cache(platform_name: str | None = None, environ=None) -> Path:
    environ = os.environ if environ is None else environ
    platform_name = sys.platform if platform_name is None else platform_name
    if environ.get("SERT_CACHE"):
        return Path(environ["SERT_CACHE"])
    if platform_name == "win32":
        local = environ.get("LOCALAPPDATA")
        return Path(local) / "sert" if local else Path.home() / "AppData" / "Local" / "sert"
    if platform_name == "darwin":
        return Path.home() / "Library" / "Caches" / "sert"
    return Path.home() / ".cache" / "sert"


def cache_dir() -> Path:
    path = default_cache()
    path.mkdir(parents=True, exist_ok=True)
    return path


_OFFLINE = False


def offline() -> bool:
    return _OFFLINE or os.environ.get("SERT_OFFLINE", "").strip().lower() in ("1", "true", "yes")


def platform_key() -> str:
    system = {"Linux": "linux", "Darwin": "macos", "Windows": "windows"}.get(platform.system(), platform.system())
    machine = platform.machine().lower()
    arch = {"amd64": "x86_64", "x86_64": "x86_64", "arm64": "aarch64", "aarch64": "aarch64"}.get(machine, machine)
    return f"{system}-{arch}"


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for chunk in iter(lambda: handle.read(CHUNK), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _github_host(url: str) -> bool:
    host = urllib.parse.urlsplit(url).hostname or ""
    return host == "github.com" or host.endswith(".github.com") or host.endswith(".githubusercontent.com")


class _DropAuthOnHostChange(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        new = super().redirect_request(req, fp, code, msg, headers, newurl)
        if new is not None and urllib.parse.urlsplit(newurl).hostname != urllib.parse.urlsplit(req.full_url).hostname:
            new.remove_header("Authorization")
        return new


def open_url(url: str, timeout: float = 60):
    request = urllib.request.Request(url, headers={"User-Agent": "sert"})
    token = os.environ.get("GITHUB_TOKEN")
    if token and _github_host(url):
        request.add_header("Authorization", f"Bearer {token}")
    return urllib.request.build_opener(_DropAuthOnHostChange).open(request, timeout=timeout)


class NotFound(SertError):
    """A download whose URL names nothing: HTTP 404, or a missing file:// path."""


def retrying(url: str, attempt, sleep=None):
    if offline():
        raise SertError(f"offline: {url} is not in the cache")
    sleep = time.sleep if sleep is None else sleep
    delay = float(os.environ.get("SERT_RETRY_DELAY") or 1)
    for remaining in range(RETRIES, -1, -1):
        try:
            return attempt()
        except urllib.error.HTTPError as err:
            err.close()
            if remaining == 0 or not (err.code == 429 or err.code >= 500):
                raise (NotFound if err.code == 404 else SertError)(f"download failed: {url}: HTTP {err.code}") from err
            reason = f"HTTP {err.code}"
        except (urllib.error.URLError, OSError, http.client.HTTPException) as err:
            reason = getattr(err, "reason", err)
            if isinstance(err, urllib.error.URLError) and isinstance(reason, FileNotFoundError):
                raise NotFound(f"download failed: {url}: {reason}") from err
            if isinstance(reason, ssl.SSLCertVerificationError):
                raise SertError(f"download failed: {url}: {reason}; {CERT_HINT}") from err
            if remaining == 0:
                raise SertError(f"download failed: {url}: {reason}") from err
            reason = str(reason)
        warn(f"download failed: {url}: {reason}; retrying in {delay:g}s")
        sleep(delay)
        delay *= 2
    raise AssertionError("unreachable")


def read_url(url: str) -> bytes:
    def attempt() -> bytes:
        with open_url(url) as response:
            return response.read()

    return retrying(url, attempt)


def download(url: str, destination: Path) -> str:
    def attempt() -> str:
        digest = hashlib.sha256()
        with open_url(url) as response, open(destination, "wb") as out:
            for chunk in iter(lambda: response.read(CHUNK), b""):
                digest.update(chunk)
                out.write(chunk)
            if getattr(response, "length", None):
                raise http.client.IncompleteRead(b"", response.length)
        return digest.hexdigest()

    return retrying(url, attempt)


def fetch_blob(repo: str, tag: str, asset: str) -> Path:
    cache = cache_dir()
    target = cache / repo / tag / asset
    if target.is_file():
        return target
    if offline():
        raise SertError(f"offline: {asset} is not in the cache ({cache})")
    url = release_url(repo, tag, asset)
    target.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(dir=target.parent, prefix=f".{asset}.", delete=False) as handle:
        part = Path(handle.name)
    try:
        download(url, part)
        os.replace(part, target)
        return target
    finally:
        if part.exists():
            part.unlink()


def _safe_member(name: str, strip: str | None) -> str | None:
    path = PurePosixPath(name.replace("\\", "/"))
    if path.is_absolute() or ".." in path.parts or (path.parts and ":" in path.parts[0]):
        raise SertError(f"refusing unsafe zip entry {name!r}")
    parts = path.parts
    if strip:
        prefix = PurePosixPath(strip.strip("/")).parts
        if tuple(parts[: len(prefix)]) != prefix:
            return None
        parts = parts[len(prefix) :]
    return "/".join(parts) if parts else None


def extract_zip(archive: Path, destination: Path, strip: str | None = None) -> int:
    try:
        count = 0
        with zipfile.ZipFile(archive) as zipped:
            for info in zipped.infolist():
                if stat.S_ISLNK(info.external_attr >> 16):
                    raise SertError(f"{archive.name}: unsafe zip entry: {info.filename!r}")
                relative = _safe_member(info.filename, strip)
                if relative is None:
                    continue
                target = destination / relative
                if info.is_dir():
                    target.mkdir(parents=True, exist_ok=True)
                    continue
                target.parent.mkdir(parents=True, exist_ok=True)
                with zipped.open(info) as source, open(target, "wb") as out:
                    shutil.copyfileobj(source, out)
                if (info.external_attr >> 16) & 0o111:
                    target.chmod(target.stat().st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)
                count += 1
    except zipfile.BadZipFile as err:
        raise SertError(f"{archive.name} is not a valid zip archive: {err}") from err
    if strip and count == 0:
        raise SertError(f"{archive.name}: nothing under strip = {strip!r}")
    return count


def _remove(path: Path) -> None:
    if path.is_symlink() or path.is_file():
        path.unlink()
    elif path.is_dir():
        shutil.rmtree(path)


MARKER = ".sert-sha256"


def _installed(destination: Path, stamp: str) -> bool:
    if destination.is_symlink():
        return False
    try:
        return (destination / MARKER).read_text(encoding="utf-8", errors="replace").strip() == stamp
    except OSError:
        return False


def install_zip(archive: Path, stamp_id: str, destination: Path, strip: str | None = None) -> bool:
    stamp = f"{stamp_id} {strip or ''}".strip()
    if _installed(destination, stamp):
        return False
    destination.parent.mkdir(parents=True, exist_ok=True)
    staging = Path(tempfile.mkdtemp(dir=destination.parent, prefix=f".{destination.name}."))
    try:
        (staging / "new").mkdir()
        extract_zip(archive, staging / "new", strip)
        (staging / "new" / MARKER).write_text(stamp + "\n", encoding="utf-8")
        for attempt in range(RETRIES + 1):
            if _installed(destination, stamp):
                return False
            with contextlib.suppress(FileNotFoundError):
                os.replace(destination, staging / f"old{attempt}")
            try:
                os.replace(staging / "new", destination)
                return True
            except OSError as err:
                failure = err
        raise SertError(f"cannot install {archive.name} into {destination}: {failure}")
    finally:
        _remove(staging)


OVERRIDE_MARKER = ".override"
SERT_PATHS = ["default.project.json", "src"]
SKIPPED = {"__pycache__", ".git", ".DS_Store", ".sert"}


def _project_paths(project: Path) -> list[str]:
    try:
        data = json.loads(strip_trailing_commas(project.read_text(encoding="utf-8")))
    except (OSError, ValueError) as err:
        raise SertError(f"override: cannot read {project}: {err}")
    paths = [project.name]

    def walk(node):
        if isinstance(node, dict):
            if isinstance(node.get("$path"), str):
                cleaned = node["$path"].replace("\\", "/").strip("/")
                paths.append(cleaned or ".")
            for key, value in node.items():
                if not key.startswith("$") or key == "tree":
                    walk(value)

    walk(data.get("tree", {}))
    return sorted(set(p for p in paths if p))


def override_paths(name: str, source: Path, table: dict | None) -> list[str]:
    if explicit := (table or {}).get("paths"):
        return [str(p).strip("/") or "." for p in as_list(explicit)]
    if name == "sert":
        return SERT_PATHS
    project = source / "default.project.json"
    if not project.is_file():
        raise SertError(f"override {name}: {source} has no default.project.json; set [deps.{name}].paths")
    return _project_paths(project)


def _source_files(source: Path, paths: list[str]) -> dict[str, Path]:
    files: dict[str, Path] = {}
    for relative in paths:
        path = source / relative
        if path.is_file():
            files[relative] = path
        elif path.is_dir():
            for file in path.rglob("*"):
                rel = file.relative_to(source)
                if file.is_file() and not SKIPPED.intersection(rel.parts):
                    files[rel.as_posix()] = file
        else:
            raise SertError(f"override: {path} does not exist")
    return files


def mirror(source: Path, destination: Path, paths: list[str], full: bool = True) -> int:
    if not source.is_dir():
        raise SertError(f"override {source} does not exist")
    marker = destination / OVERRIDE_MARKER
    if (
        destination.is_symlink()
        or (destination.exists() and not marker.is_file())
        or (marker.is_file() and marker.read_text(encoding="utf-8", errors="replace").strip() != str(source))
    ):
        _remove(destination)
    destination.mkdir(parents=True, exist_ok=True)
    files = _source_files(source, paths)
    for path in sorted(destination.rglob("*"), key=lambda p: len(p.parts), reverse=True):
        relative = path.relative_to(destination).as_posix()
        if path.is_file() and relative not in files and relative != OVERRIDE_MARKER:
            path.unlink()
        elif path.is_dir() and (relative in files or not any(path.iterdir())):
            _remove(path)
    copied = 0
    for relative, file in files.items():
        target = destination / relative
        if target.is_dir():
            _remove(target)
        if not full and target.is_file():
            have, want = target.stat(), file.stat()
            if have.st_size == want.st_size and have.st_mtime_ns == want.st_mtime_ns:
                continue
        if target.parent.exists() and not target.parent.is_dir():
            target.parent.unlink()
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(file, target)
        copied += 1
    marker.write_text(f"{source}\n", encoding="utf-8")
    return copied


def override_targets(cfg: config_mod.Config) -> list[tuple[str, Path, Path, list[str]]]:
    out = []
    deps = cfg.table("deps")
    for name, source in sorted(cfg.overrides.items()):
        if name == "sert":
            destination = cfg.root / ".sert" / "sert"
        elif name in deps:
            destination = cfg.root / ".sert" / "pkg" / name
        else:
            raise SertError(f"[override].{name} names no [deps.{name}] (and is not sert)")
        table = deps.get(name) if isinstance(deps.get(name), dict) else None
        out.append((name, source, destination, override_paths(name, source, table)))
    return out


def _sert_source_env() -> Path | None:
    val = os.environ.get("SERT_SOURCE", "").strip()
    if not val:
        return None
    source = Path(val).expanduser().resolve()
    if not source.is_dir():
        raise SertError(f"SERT_SOURCE: {source} is not a directory")
    return source


def refresh_overrides(cfg: config_mod.Config) -> int:
    sert_source = _sert_source_env()
    if not cfg.overrides and sert_source is None:
        return 0
    check_overrides(cfg, quiet=True)
    copied = 0
    if sert_source is not None and "sert" not in cfg.overrides:
        copied += mirror(sert_source, cfg.root / ".sert" / "sert", override_paths("sert", sert_source, None), full=False)
    for _, source, destination, paths in override_targets(cfg):
        copied += mirror(source, destination, paths, full=False)
    return copied


def check_overrides(cfg: config_mod.Config, quiet: bool = False) -> dict[str, Path]:
    overrides = cfg.overrides
    if overrides and is_ci():
        raise SertError(f"[override] ({', '.join(sorted(overrides))}) is set but CI=true: overrides are for local work only")
    if not quiet:
        for name, path in sorted(overrides.items()):
            warn(f"override active: {name} -> {path}")
    return overrides


def sert_assets(cfg: config_mod.Config) -> tuple[str, str, str, str]:
    table = cfg.table("sert")
    version = table.get("version")
    if not version:
        raise SertError("sert.toml: [sert].version is required")
    return table.get("repo", SERT_REPO), f"v{version}", f"sert-{version}.zip", f"sert-{version}.pyz"


LAUNCHER = """#!/usr/bin/env python3
# Written by `sert fetch` for [override].sert: runs the sert checkout at {python}.
import os, sys
sys.path.insert(0, {python!r})
os.environ.setdefault("SERT_ROOT", {root!r})
from sert.cli import main
sys.exit(main())
"""


WINDOWS_CMD_SHIM = b'@echo off\r\npython "%~dp0sert" %*\r\n'


def _write_executable(path: Path, data: bytes) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    write_atomic(path, data, 0o755)


def write_launcher(target: Path, data: bytes) -> bool:
    changed = False
    if not target.is_file() or target.read_bytes() != data:
        _write_executable(target, data)
        changed = True
    if os.name == "nt":
        cmd = target.parent / "sert.cmd"
        if not cmd.is_file() or cmd.read_bytes() != WINDOWS_CMD_SHIM:
            write_atomic(cmd, WINDOWS_CMD_SHIM)
            changed = True
    return changed


def _sert_stamp(repo: str, tag: str) -> str:
    return f"{repo}@{tag}"


def _dep_stamp(repo: str, tag: str, asset: str) -> str:
    return f"{repo}@{tag}/{asset}"


def fetch_sert(cfg: config_mod.Config, overrides: dict[str, Path], out=print) -> None:
    dot = cfg.root / ".sert"
    source = _sert_source_env() or overrides.get("sert")
    if source is not None:
        copied = mirror(source, dot / "sert", override_paths("sert", source, None))
        write_launcher(dot / "bin" / "sert", LAUNCHER.format(python=str(source / "python"), root=str(cfg.root)).encode())
        out(f"sert: mirrored {source} ({copied} files)")
        return
    if not cfg.get("sert.version"):
        if problem := unpinned_sert(cfg):
            raise SertError(problem)
        return
    repo, tag, zip_name, pyz_name = sert_assets(cfg)
    table = cfg.table("sert")
    archive = fetch_blob(repo, tag, zip_name)
    changed = install_zip(archive, _sert_stamp(repo, tag), dot / "sert")
    pyz = fetch_blob(repo, tag, pyz_name)
    if write_launcher(dot / "bin" / "sert", pyz.read_bytes()):
        changed = True
    out(f"sert {table['version']}: {'installed' if changed else 'up to date'}")


def unpinned_sert(cfg: config_mod.Config) -> str | None:
    if cfg.get("sert.version") or "sert" in cfg.overrides or _sert_source_env() is not None:
        return None
    alias = sert_alias(cfg.root)
    if not isinstance(alias, str) or alias.startswith("@"):
        return None
    target = Path(os.path.normpath(cfg.root / alias))
    if not target.is_relative_to(Path(os.path.normpath(cfg.root / ".sert" / "sert"))):
        return None
    return f'sert.toml pins no [sert].version to fetch the .luaurc "sert" alias from: add version = "{VERSION}" to its [sert] table'


def dep_spec(name: str, table: dict) -> tuple[str, str, str]:
    missing = [key for key in ("repo", "tag", "asset") if not table.get(key)]
    if missing:
        raise SertError(f"sert.toml: [deps.{name}] needs {', '.join(missing)}")
    return table["repo"], table["tag"], table["asset"]


def fetch_deps(cfg: config_mod.Config, overrides: dict[str, Path]) -> None:
    for name in sorted(cfg.table("deps")):
        fetch_dep(cfg, name, overrides)


def fetch_dep(cfg: config_mod.Config, name: str, overrides: dict[str, Path], out=print) -> None:
    deps = cfg.table("deps")
    destination = cfg.root / ".sert" / "pkg" / name
    if name in overrides:
        table = deps[name] if isinstance(deps[name], dict) else None
        source = overrides[name]
        copied = mirror(source, destination, override_paths(name, source, table))
        out(f"{name}: mirrored {source} ({copied} files)")
        return
    table = deps[name]
    if not isinstance(table, dict):
        raise SertError(f"sert.toml: [deps.{name}] must be a table")
    repo, tag, asset = dep_spec(name, table)
    archive = fetch_blob(repo, tag, asset)
    destination.parent.mkdir(parents=True, exist_ok=True)
    changed = install_zip(archive, _dep_stamp(repo, tag, asset), destination, table.get("strip"))
    out(f"{name} {tag}: {'installed' if changed else 'up to date'}")


def tool_versions(cfg: config_mod.Config) -> dict[str, str]:
    return {name: str(value) for name, value in cfg.table("tools").items() if not isinstance(value, dict) and name != LSP_KEY}


def tool_asset(tool: str, version: str, key: str | None = None) -> tuple[str, str, str]:
    spec = TOOLS.get(tool)
    if spec is None:
        raise SertError(f"sert.toml: unknown tool {tool!r} in [tools] (known: {', '.join(sorted(TOOLS))})")
    key = key or platform_key()
    asset = spec["assets"].get(key)
    if asset is None:
        raise SertError(f"{tool} publishes no release for {key}")
    return spec["repo"], spec["tag"].format(version=version), asset


def fetch_tools(cfg: config_mod.Config) -> None:
    for tool, version in sorted(tool_versions(cfg).items()):
        fetch_tool(cfg, tool, version)


def fetch_tool(cfg: config_mod.Config, tool: str, version: str, out=print) -> None:
    repo, tag, asset = tool_asset(tool, version)
    archive = fetch_blob(repo, tag, asset)
    sha = sha256_file(archive)
    unpacked = cache_dir() / repo / tag / f"{asset}.unpacked"
    install_zip(archive, sha, unpacked)
    installed = False
    for binary in TOOLS[tool]["binaries"]:
        for candidate in (binary, f"{binary}.exe"):
            found = sorted(p for p in unpacked.rglob(candidate) if p.is_file())
            if found:
                target = cfg.root / ".sert" / "bin" / candidate
                data = found[0].read_bytes()
                if not target.is_file() or target.read_bytes() != data:
                    _write_executable(target, data)
                installed = True
    if not installed:
        raise SertError(f"{asset} holds no {'/'.join(TOOLS[tool]['binaries'])} binary")
    write_atomic(tool_stamp(cfg.root, tool), version.encode())
    out(f"{tool} {version}: .sert/bin")


def tool_stamp(root: Path, tool: str) -> Path:
    return root / ".sert" / "bin" / f".{tool}.version"


def installed_tool(root: Path, tool: str) -> str | None:
    try:
        return tool_stamp(root, tool).read_text(encoding="utf-8").strip()
    except OSError:
        return None


def lsp_pin(cfg: config_mod.Config) -> str | None:
    value = cfg.table("tools").get(LSP_KEY)
    return str(value) if value else lsp_version(cfg.root)


def types_url(version: str) -> str:
    return f"{raw_base()}/JohnnyMorganz/luau-lsp/{version}/scripts/{TYPES_ASSET}"


def lsp_version(root: Path) -> str | None:
    rokit = root / "rokit.toml"
    if not rokit.is_file():
        return None
    for name, value in config_mod.read_toml(rokit).get("tools", {}).items():
        if name.lower() == "luau-lsp" and isinstance(value, str) and "@" in value:
            return value.rsplit("@", 1)[1]
    return None


def types_path(root: Path) -> Path:
    return root / ".sert" / "types" / "globalTypes.d.luau"


def fetch_types(cfg: config_mod.Config, quiet: bool = False) -> Path | None:
    version = lsp_pin(cfg)
    if not version:
        if not quiet:
            note("types: no luau-lsp pinned in [tools] or rokit.toml; skipped globalTypes.d.luau")
        return None
    target = types_path(cfg.root)
    cached = cache_dir() / "luau-lsp" / version / TYPES_ASSET
    if not cached.is_file():
        url = types_url(version)
        if offline():
            raise SertError(f"offline: luau-lsp {version} {TYPES_ASSET} is not in the cache")
        data = read_url(url)
        cached.parent.mkdir(parents=True, exist_ok=True)
        write_atomic(cached, data)
    target.parent.mkdir(parents=True, exist_ok=True)
    data = cached.read_bytes()
    if not target.is_file() or target.read_bytes() != data:
        target.write_bytes(data)
    if not quiet:
        print(f"luau-lsp {version} definitions: .sert/types/globalTypes.d.luau")
    return target


def ensure_types(cfg: config_mod.Config) -> Path:
    target = types_path(cfg.root)
    if target.is_file():
        return target
    fetched = fetch_types(cfg, quiet=True)
    if fetched is None:
        raise SertError(f"no globalTypes.d.luau: pin luau-lsp in [tools].luau_lsp (or rokit.toml) and run `{config_mod.command('fetch')}`")
    return fetched


def _pinned_install(destination: Path, stamp_id: str, strip=None) -> bool:
    return _installed(destination, f"{stamp_id} {strip or ''}".strip())


def missing_parts(cfg: config_mod.Config) -> list[tuple[str, Callable]]:
    dot, overrides = cfg.root / ".sert", cfg.overrides
    parts: list[tuple[str, Callable]] = []
    table = cfg.table("sert")
    if table.get("version") and "sert" not in overrides and _sert_source_env() is None:
        repo, tag, _, _ = sert_assets(cfg)
        if not _pinned_install(dot / "sert", _sert_stamp(repo, tag)) or not (dot / "bin" / "sert").is_file():
            parts.append((f"sert {table['version']}", functools.partial(fetch_sert, cfg, {})))
    for name, dep in sorted(cfg.table("deps").items()):
        if name not in overrides:
            if not isinstance(dep, dict) or any(not dep.get(k) for k in ("repo", "tag", "asset")) or not _pinned_install(
                dot / "pkg" / name, _dep_stamp(dep["repo"], dep["tag"], dep["asset"]), dep.get("strip")
            ):
                parts.append((f"[deps.{name}]", functools.partial(fetch_dep, cfg, name, overrides)))
    for tool, version in sorted(tool_versions(cfg).items()):
        binaries = TOOLS.get(tool, {}).get("binaries", [tool])
        if not all((dot / "bin" / b).is_file() or (dot / "bin" / f"{b}.exe").is_file() for b in binaries) or installed_tool(cfg.root, tool) != version:
            parts.append((f"{tool} {version}", functools.partial(fetch_tool, cfg, tool, version)))
    return parts


def ensure_fetched(cfg: config_mod.Config) -> None:
    todo = missing_parts(cfg)
    if not todo:
        return
    (cfg.root / ".sert").mkdir(exist_ok=True)
    for what, fetch_part in todo:
        try:
            fetch_part(out=lambda line: note(f"fetch: {line}"))
        except SertError as err:
            raise SertError(f"cannot fetch {what} into .sert/: {err}\nrun `{config_mod.command('fetch')}` once it is reachable")


PARTS = ("sert", "deps", "tools", "types")


def add_parser(subparsers) -> None:
    parser = subparsers.add_parser("fetch")
    parser.add_argument("--only", action="append", choices=PARTS, help="fetch only these parts (repeatable)")
    parser.add_argument("--offline", action="store_true", help="use the download cache only; no network")
    parser.set_defaults(func=main)


def main(args) -> int:
    global _OFFLINE
    previous = _OFFLINE
    _OFFLINE = previous or bool(getattr(args, "offline", False))
    try:
        cfg = config_mod.from_args(args, require=True)
        parts = args.only or list(PARTS)
        overrides = check_overrides(cfg)
        override_targets(cfg)
        (cfg.root / ".sert").mkdir(exist_ok=True)
        if "sert" in parts:
            fetch_sert(cfg, overrides)
        if "deps" in parts:
            fetch_deps(cfg, overrides)
        if "tools" in parts:
            fetch_tools(cfg)
        if "types" in parts:
            fetch_types(cfg)
        return 0
    finally:
        _OFFLINE = previous


STARTER_TOML = f"""[sert]
version = "{VERSION}"

[tools]
luau = "{LUAU}"
luau_lsp = "{LUAU_LSP}"

[test]
specs = ["test/**/*.spec.luau"]

[coverage]
include = ["src"]
min = 90

[lint]
paths = ["src", "test"]
solvers = ["new", "old"]
"""

STARTER_SPEC = """--!strict
local sert = require("@sert")

sert.describe("example", function()
\tsert.test("arithmetic holds", function()
\t\tsert.eq(1 + 1, 2)
\t\tsert.expect(2 * 3).toBe(6)
\tend)

\tsert.prop("addition is commutative", function(g: sert.Gen)
\t\tlocal a = g:int(-100, 100)
\t\tlocal b = g:int(-100, 100)
\t\tsert.eq(a + b, b + a)
\tend)
end)

return {}
"""

GITIGNORE_ENTRIES = (".sert/", "sert.local.toml", "coverage.out", "coverage.json")
ALIAS = "./.sert/sert/src"


def alias_resolves(alias) -> bool:
    return isinstance(alias, str) and (alias.startswith(("./", "../", "/", "@")) or Path(alias).is_absolute())


def starter_toml(root: Path) -> str:
    text = STARTER_TOML if (root / "src").exists() else STARTER_TOML.replace('paths = ["src", "test"]', 'paths = ["test"]')
    return text.replace(f'luau_lsp = "{LUAU_LSP}"\n', "") if lsp_version(root) else text


def _update_luaurc(root: Path, force: bool, out=print) -> bool:
    path = root / ".luaurc"
    data: dict = {}
    if path.is_file():
        try:
            loaded = json.loads(strip_trailing_commas(path.read_text(encoding="utf-8")))
        except ValueError:
            out(f'init: .luaurc does not parse as JSON (luau allows comments); add "sert": "{ALIAS}" to its aliases')
            return False
        if isinstance(loaded, dict):
            data = loaded
    aliases = data.get("aliases")
    if not isinstance(aliases, dict):
        aliases = {}
        data["aliases"] = aliases
    key = sert_alias_key(aliases)
    if key is not None and aliases[key] == ALIAS and path.is_file():
        return False
    if key is None or force or not alias_resolves(aliases[key]):
        aliases[key or "sert"] = ALIAS
        path.write_text(json.dumps(data, indent="\t") + "\n", encoding="utf-8")
        return True
    return False


def _update_gitignore(root: Path) -> bool:
    path = root / ".gitignore"
    existing_text = path.read_text(encoding="utf-8") if path.is_file() else ""
    existing_lines = {line.strip().strip("/") for line in existing_text.splitlines() if line.strip()}
    missing = [entry for entry in GITIGNORE_ENTRIES if entry.strip("/") not in existing_lines]
    if not missing:
        return False
    prefix = "" if not existing_text or existing_text.endswith("\n") else "\n"
    path.write_text(existing_text + prefix + "\n".join(missing) + "\n", encoding="utf-8")
    return True


def init_project(root: Path, force: bool = False, out=print) -> list[str]:
    from sert.lint import shipped_stub

    root.mkdir(parents=True, exist_ok=True)
    touched: list[str] = []
    toml_path = root / "sert.toml"
    if not toml_path.is_file() or force:
        toml_path.write_text(starter_toml(root), encoding="utf-8")
        touched.append("sert.toml")
    if (stub_bytes := shipped_stub()) is not None:
        stub_path = root / "tools" / "sert.py"
        if not stub_path.is_file() or force or stub_path.read_bytes() != stub_bytes:
            stub_path.parent.mkdir(parents=True, exist_ok=True)
            stub_path.write_bytes(stub_bytes)
            stub_path.chmod(0o755)
            touched.append("tools/sert.py")
    if _update_luaurc(root, force, out):
        touched.append(".luaurc")
    if _update_gitignore(root):
        touched.append(".gitignore")
    existing_specs = list((root / "test").rglob("*.spec.luau")) if (root / "test").is_dir() else []
    starter_spec = root / "test" / "Example.spec.luau"
    if not existing_specs or (force and not starter_spec.is_file()):
        starter_spec.parent.mkdir(parents=True, exist_ok=True)
        starter_spec.write_text(STARTER_SPEC, encoding="utf-8")
        touched.append("test/Example.spec.luau")
    for item in touched:
        out(f"init: wrote {item}")
    out(f"init: next: `{config_mod.command('run')}`" if touched else "init: already initialized (pass --force to overwrite)")
    return touched


def add_init_parser(subparsers) -> None:
    parser = subparsers.add_parser("init")
    parser.add_argument("--force", action="store_true", help="also overwrite sert.toml and the .luaurc alias")
    parser.set_defaults(func=main_init)


def main_init(args) -> int:
    init_project(config_mod.find_root(getattr(args, "root", None)), force=bool(getattr(args, "force", False)))
    return 0
