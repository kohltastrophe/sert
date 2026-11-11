"""Cryptographic lockfile (`sert.lock`) and SHA256SUMS supply-chain verification."""

from __future__ import annotations

import hashlib
from pathlib import Path
import re
import tomllib

from sert.util import SertError, write_atomic

LOCK_FILE = "sert.lock"
LOCK_SCHEMA = 1
DEFAULT_LSP_VERSION = "1.70.0"
_SHA256_RE = re.compile(r"^[0-9a-fA-F]{64}$")
_SUMS_LINE_RE = re.compile(r"^([0-9a-fA-F]{64})\s+\*?([^\r\n]+)$")


def is_sha256(value: object) -> bool:
    return isinstance(value, str) and _SHA256_RE.fullmatch(value.strip()) is not None


def normalize_sha256(value: object, label: str = "sha256") -> str:
    if not isinstance(value, str) or not is_sha256(value):
        raise SertError(f"invalid SHA-256 digest for {label}: {value!r}")
    return value.strip().lower()


def sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    try:
        with open(path, "rb") as handle:
            while chunk := handle.read(1 << 20):
                digest.update(chunk)
    except OSError as err:
        raise SertError(f"cannot hash {path}: {err}") from err
    return digest.hexdigest()


def parse_sha256sums(text: str, source: str = "SHA256SUMS") -> dict[str, str]:
    digests: dict[str, str] = {}
    for lineno, raw_line in enumerate(text.splitlines(), 1):
        line = raw_line.strip()
        if not line or line.startswith("#"):
            continue
        match = _SUMS_LINE_RE.match(line)
        if not match:
            raise SertError(f"{source}:{lineno}: malformed SHA256SUMS line: {raw_line!r}")
        sha, name = match.group(1).lower(), Path(match.group(2).strip()).name
        if name in digests and digests[name] != sha:
            raise SertError(f"{source}:{lineno}: conflicting SHA-256 entries for {name}")
        digests[name] = sha
    if not digests:
        raise SertError(f"{source}: empty SHA256SUMS")
    return digests


def verify_bytes(label: str, data: bytes, expected_sha256: str) -> str:
    expected = normalize_sha256(expected_sha256, label)
    actual = sha256_bytes(data)
    if actual != expected:
        raise SertError(
            f"SHA-256 verification failed for {label}: expected {expected}, got {actual} "
            "(refusing tampered or corrupted download)"
        )
    return actual


def verify_file(label: str, path: Path, expected_sha256: str) -> str:
    expected = normalize_sha256(expected_sha256, label)
    actual = sha256_file(path)
    if actual != expected:
        raise SertError(
            f"SHA-256 verification failed for {label} ({path}): expected {expected}, got {actual} "
            "(refusing tampered or corrupted file)"
        )
    return actual


def read_rokit_lsp_version(root: Path, default: str = DEFAULT_LSP_VERSION) -> str:
    rokit_path = root / "rokit.toml"
    if not rokit_path.is_file():
        return default
    try:
        data = tomllib.loads(rokit_path.read_text(encoding="utf-8-sig"))
    except (OSError, tomllib.TOMLDecodeError, UnicodeDecodeError):
        return default
    tools = data.get("tools")
    if not isinstance(tools, dict):
        return default
    for key, spec in tools.items():
        if str(key).lower().replace("_", "-") == "luau-lsp" and isinstance(spec, str) and "@" in spec:
            ver = spec.rsplit("@", 1)[1].strip()
            if ver:
                return ver.lstrip("v")
    return default


def _toml_quote(text: str) -> str:
    escaped = text.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n").replace("\r", "\\r")
    return f'"{escaped}"'


def load_lock(root: Path) -> dict | None:
    path = root / LOCK_FILE
    if not path.is_file():
        return None
    try:
        data = tomllib.loads(path.read_text(encoding="utf-8-sig"))
    except (OSError, tomllib.TOMLDecodeError, UnicodeDecodeError) as err:
        raise SertError(f"{LOCK_FILE}: {err}") from err
    if not isinstance(data, dict):
        raise SertError(f"{LOCK_FILE}: expected a TOML table")
    if "schema" in data and (isinstance(data["schema"], bool) or data["schema"] != LOCK_SCHEMA):
        raise SertError(f"{LOCK_FILE}: unsupported schema {data['schema']!r} (expected {LOCK_SCHEMA})")
    version = data.get("version")
    if not isinstance(version, str) or not version.strip():
        raise SertError(f"{LOCK_FILE}: missing `version` string")
    assets = data.get("assets")
    if not isinstance(assets, dict):
        raise SertError(f"{LOCK_FILE}: missing `[assets]` table")
    normalized_assets: dict[str, dict[str, str]] = {}
    for key, entry in assets.items():
        if not isinstance(entry, dict):
            raise SertError(f"{LOCK_FILE}: [assets.{key!r}] must be a table")
        sha = normalize_sha256(entry.get("sha256"), f"{LOCK_FILE} [assets.{key!r}].sha256")
        url = entry.get("url")
        if not isinstance(url, str) or not url.strip():
            raise SertError(f"{LOCK_FILE}: [assets.{key!r}].url must be a non-empty string")
        clean = {"url": url.strip(), "sha256": sha}
        if isinstance(entry.get("name"), str) and entry["name"].strip():
            clean["name"] = entry["name"].strip()
        if isinstance(entry.get("lsp_version"), str) and entry["lsp_version"].strip():
            clean["lsp_version"] = entry["lsp_version"].strip()
        normalized_assets[str(key)] = clean
    out = {"version": version.strip(), "assets": normalized_assets}
    if isinstance(data.get("repo"), str) and data["repo"].strip():
        out["repo"] = data["repo"].strip()
    return out


def format_lock(version: str, repo: str, assets: dict[str, dict[str, str]]) -> str:
    lines = [
        "# Generated by sert; commit this file for cryptographic supply-chain verification.",
        f"schema = {LOCK_SCHEMA}",
        f"version = {_toml_quote(version)}",
        f"repo = {_toml_quote(repo)}",
    ]
    order = ("sert.pyz", "sert.zip", "globalTypes.d.luau")
    keys = [k for k in order if k in assets] + sorted(k for k in assets if k not in order)
    for key in keys:
        entry = assets[key]
        sha = normalize_sha256(entry.get("sha256"), f"assets[{key!r}]")
        url = str(entry.get("url", "")).strip()
        if not url:
            raise SertError(f"cannot write {LOCK_FILE}: missing URL for {key}")
        lines.append("")
        lines.append(f"[assets.{_toml_quote(key)}]")
        if name := entry.get("name"):
            lines.append(f"name = {_toml_quote(str(name))}")
        lines.append(f"url = {_toml_quote(url)}")
        lines.append(f"sha256 = {_toml_quote(sha)}")
        if lsp_ver := entry.get("lsp_version"):
            lines.append(f"lsp_version = {_toml_quote(str(lsp_ver))}")
    return "\n".join(lines) + "\n"


def write_lock(root: Path, version: str, repo: str, assets: dict[str, dict[str, str]]) -> Path:
    path = root / LOCK_FILE
    content = format_lock(version, repo, assets)
    write_atomic(path, content.encode("utf-8"))
    return path
