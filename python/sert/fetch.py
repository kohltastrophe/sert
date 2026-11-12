"""`sert fetch` and `sert init`: verified release package + globalTypes download with `sert.lock`."""

from __future__ import annotations

import hashlib
import http.client
import io
import json
import os
from pathlib import Path, PurePosixPath
import re
import shutil
import sys
import tempfile
import urllib.error
import urllib.parse
import urllib.request
import zipfile

from sert import VERSION, config as config_mod, lock as lock_mod
from sert.util import (
    OK,
    SertError,
    command,
    is_ci,
    note,
    posix,
    sert_alias_key,
    strip_jsonc,
    warn,
    write_atomic,
)

DEFAULT_REPO = "kohltastrophe/sert"
PARTS = ("sert", "types")


def cache_dir() -> Path:
    if env := os.environ.get("SERT_CACHE"):
        return Path(env)
    if sys.platform == "win32":
        base = Path(os.environ.get("LOCALAPPDATA") or (Path.home() / "AppData" / "Local"))
        return base / "sert"
    if sys.platform == "darwin":
        return Path.home() / "Library" / "Caches" / "sert"
    base = Path(os.environ.get("XDG_CACHE_HOME") or (Path.home() / ".cache"))
    return base / "sert"


def github_base() -> str:
    return os.environ.get("SERT_GITHUB_URL", "https://github.com").rstrip("/")


def raw_base() -> str:
    return os.environ.get("SERT_RAW_URL", "https://raw.githubusercontent.com").rstrip("/")


def github_api_base() -> str:
    return os.environ.get("SERT_GITHUB_API_URL", "").strip().rstrip("/")


def release_url(repo: str, tag: str, asset: str) -> str:
    return f"{github_base()}/{repo}/releases/download/{tag}/{asset}"


def types_url(lsp_version: str) -> str:
    return f"{raw_base()}/JohnnyMorganz/luau-lsp/{lsp_version}/scripts/globalTypes.d.luau"


class _DropAuthOnHostChange(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        redirected = super().redirect_request(req, fp, code, msg, headers, newurl)
        if redirected is not None and urllib.parse.urlparse(req.full_url).netloc != urllib.parse.urlparse(newurl).netloc:
            redirected.headers.pop("Authorization", None)
            redirected.unredirected_hdrs.pop("Authorization", None)
        return redirected


_RELEASE_ASSETS_CACHE: dict[tuple[str, str, str], dict[str, str]] = {}


def _resolve_private_asset_url(opener, api_base: str, repo: str, tag: str, asset: str, token: str) -> str:
    key = (api_base, repo, tag)
    if key not in _RELEASE_ASSETS_CACHE:
        meta_url = f"{api_base}/repos/{repo}/releases/tags/{tag}"
        req = urllib.request.Request(
            meta_url,
            headers={
                "User-Agent": f"sert/{VERSION}",
                "Accept": "application/vnd.github+json",
                "Authorization": f"Bearer {token}",
            },
        )
        try:
            with opener.open(req, timeout=60) as resp:
                payload = json.loads(resp.read().decode("utf-8"))
        except urllib.error.HTTPError as err:
            raise SertError(f"GitHub release lookup failed ({meta_url}): HTTP {err.code} {err.reason}") from err
        except (OSError, ValueError, urllib.error.URLError) as err:
            raise SertError(f"GitHub release lookup failed ({meta_url}): {err}") from err
        _RELEASE_ASSETS_CACHE[key] = {
            str(item["name"]): str(item["url"])
            for item in payload.get("assets", ())
            if isinstance(item, dict) and item.get("name") and item.get("url")
        }
    asset_url = _RELEASE_ASSETS_CACHE[key].get(asset)
    if not asset_url:
        raise SertError(f"asset {asset!r} not found in release {repo}@{tag}")
    return asset_url


def _open_asset_stream(url: str, *, repo: str | None = None, tag: str | None = None, asset: str | None = None):
    token = os.environ.get("GITHUB_TOKEN", "").strip()
    host = urllib.parse.urlparse(url).netloc.lower()
    api_override = github_api_base()
    opener = urllib.request.build_opener(_DropAuthOnHostChange)
    use_api = bool(token and repo and tag and asset and (host == "github.com" or bool(api_override)))
    if use_api:
        api_base = api_override or "https://api.github.com"
        target_url = _resolve_private_asset_url(opener, api_base, str(repo), str(tag), str(asset), token)
        req = urllib.request.Request(
            target_url,
            headers={
                "User-Agent": f"sert/{VERSION}",
                "Accept": "application/octet-stream",
                "Authorization": f"Bearer {token}",
            },
        )
    else:
        headers = {"User-Agent": f"sert/{VERSION}"}
        if token and host in ("github.com", "api.github.com"):
            headers["Authorization"] = f"Bearer {token}"
        req = urllib.request.Request(url, headers=headers)
    try:
        return opener.open(req, timeout=120)
    except urllib.error.HTTPError as err:
        raise SertError(f"download failed ({url}): HTTP {err.code} {err.reason}") from err
    except (OSError, urllib.error.URLError) as err:
        raise SertError(f"download failed ({url}): {err}") from err


def fetch_raw_bytes(
    url: str,
    *,
    repo: str | None = None,
    tag: str | None = None,
    asset: str | None = None,
) -> bytes:
    try:
        with _open_asset_stream(url, repo=repo, tag=tag, asset=asset) as resp:
            data = resp.read()
            cl = resp.headers.get("Content-Length") if hasattr(resp, "headers") and resp.headers else None
            if cl and cl.isdigit() and len(data) < int(cl):
                raise SertError(
                    f"download failed ({url}): {http.client.IncompleteRead(data, int(cl) - len(data))!r}"
                )
            return data
    except SertError:
        raise
    except (OSError, urllib.error.URLError, http.client.HTTPException) as err:
        raise SertError(f"download failed ({url}): {err}") from err


def offline() -> bool:
    return os.environ.get("SERT_OFFLINE", "").strip().lower() in ("1", "true", "yes")


def read_url(url: str) -> bytes:
    return fetch_raw_bytes(url)


def download(url: str, dest: Path, *, offline: bool = False, expected_sha256: str | None = None) -> Path:
    path, _ = download_verified(url, dest, offline=offline, expected_sha256=expected_sha256)
    return path


def download_verified(
    url: str,
    dest: Path,
    *,
    offline: bool = False,
    expected_sha256: str | None = None,
    repo: str | None = None,
    tag: str | None = None,
    asset: str | None = None,
    mode: int | None = None,
) -> tuple[Path, str]:
    label = asset or dest.name
    if dest.is_file():
        actual = lock_mod.sha256_file(dest)
        if expected_sha256 is not None:
            lock_mod.verify_file(label, dest, expected_sha256)
        return dest, actual
    if offline:
        raise SertError(f"not in cache (--offline): {url}")
    dest.parent.mkdir(parents=True, exist_ok=True)
    note(f"downloading {Path(urllib.parse.urlparse(url).path).name}")
    data = fetch_raw_bytes(url, repo=repo, tag=tag, asset=asset)
    if expected_sha256 is not None:
        actual = lock_mod.verify_bytes(label, data, expected_sha256)
    else:
        actual = lock_mod.sha256_bytes(data)
    write_atomic(dest, data, mode=mode)
    return dest, actual


def cache_key(url: str) -> str:
    tail = Path(urllib.parse.urlparse(url).path).name or "blob"
    digest = hashlib.sha256(url.encode("utf-8")).hexdigest()[:16]
    return f"{digest}-{tail}"


def _safe_rel(name: str, strip: int) -> Path | None:
    parts = [p for p in PurePosixPath(name).parts if p not in ("", "/")]
    if any(p == ".." for p in parts):
        raise SertError(f"archive entry climbs out of destination: {name}")
    trimmed = parts[strip:]
    return Path(*trimmed) if trimmed else None


def extract_archive(archive: Path, dest: Path, strip: int = 0) -> None:
    parent = dest.parent
    parent.mkdir(parents=True, exist_ok=True)
    staging = Path(tempfile.mkdtemp(dir=parent, prefix=f".{dest.name}."))
    try:
        with zipfile.ZipFile(archive) as zf:
            for info in zf.infolist():
                if info.is_dir():
                    continue
                if (info.external_attr >> 16) & 0o170000 == 0o120000:
                    raise SertError(f"refusing symlink in archive: {info.filename}")
                rel = _safe_rel(info.filename, strip)
                if rel is None:
                    continue
                out = staging / rel
                out.parent.mkdir(parents=True, exist_ok=True)
                with zf.open(info) as src, open(out, "wb") as dst:
                    shutil.copyfileobj(src, dst)
        if dest.exists():
            shutil.rmtree(dest)
        os.replace(staging, dest)
    except BaseException:
        shutil.rmtree(staging, ignore_errors=True)
        raise


def _mirror_tree(source: Path, dest: Path) -> None:
    if not source.is_dir():
        raise SertError(f"source directory not found: {source}")
    dest.parent.mkdir(parents=True, exist_ok=True)
    staging = Path(tempfile.mkdtemp(dir=dest.parent, prefix=f".{dest.name}."))
    try:
        shutil.rmtree(staging)
        shutil.copytree(source, staging, ignore=shutil.ignore_patterns(".git", ".sert", "__pycache__", "*.pyc"))
        if dest.exists():
            shutil.rmtree(dest)
        os.replace(staging, dest)
    except BaseException:
        shutil.rmtree(staging, ignore_errors=True)
        raise


def _marker(dest: Path) -> Path:
    return dest.parent / f".{dest.name}.stamp"


def _stamped(dest: Path, stamp: str) -> bool:
    marker = _marker(dest)
    return dest.exists() and marker.is_file() and marker.read_text(encoding="utf-8").strip() == stamp


def _write_stamp(dest: Path, stamp: str) -> None:
    _marker(dest).write_text(stamp + "\n", encoding="utf-8")


def _fetch_sert(
    cfg: config_mod.Config,
    existing_lock: dict | None,
    *,
    offline: bool,
) -> tuple[str | None, dict[str, dict[str, str]]]:
    overrides = cfg.overrides
    dest = cfg.root / ".sert" / "sert"
    if "sert" in overrides:
        warn(f"using [override].sert = {overrides['sert']}")
        return str(overrides["sert"]), {}
    if env_src := os.environ.get("SERT_SOURCE"):
        src_root = Path(env_src).resolve()
        warn(f"mirroring sert from SERT_SOURCE={src_root}")
        dest.mkdir(parents=True, exist_ok=True)
        _mirror_tree(src_root / "src", dest / "src")
        for extra in ("default.project.json", "LICENSE.txt"):
            if (src_root / extra).is_file():
                shutil.copy2(src_root / extra, dest / extra)
        return str(dest), {}
    sert_tbl = cfg.table("sert")
    version_raw = sert_tbl.get("version")
    if not version_raw:
        return None, {}
    version = str(version_raw).strip()
    repo = str(sert_tbl.get("repo") or DEFAULT_REPO).strip()
    tag = f"v{version}"

    pyz_name = f"sert-{version}.pyz"
    zip_name = f"sert-{version}.zip"
    pyz_url = release_url(repo, tag, pyz_name)
    zip_url = release_url(repo, tag, zip_name)
    sums_url = release_url(repo, tag, "SHA256SUMS")

    lock_matches = existing_lock is not None and existing_lock.get("version") == version
    locked_assets = existing_lock.get("assets", {}) if lock_matches and existing_lock else {}
    locked_pyz_sha = (locked_assets.get("sert.pyz") or {}).get("sha256")
    locked_zip_sha = (locked_assets.get("sert.zip") or {}).get("sha256")

    sums_cache = cache_dir() / "cli" / f"sert-{version}.SHA256SUMS"
    sums: dict[str, str] = {}
    if sums_cache.is_file():
        sums = lock_mod.parse_sha256sums(sums_cache.read_text(encoding="utf-8"), str(sums_cache))
    elif not offline:
        sums_bytes = fetch_raw_bytes(sums_url, repo=repo, tag=tag, asset="SHA256SUMS")
        sums = lock_mod.parse_sha256sums(sums_bytes.decode("utf-8", errors="replace"), sums_url)
        write_atomic(sums_cache, sums_bytes)
    elif not (locked_pyz_sha and locked_zip_sha):
        raise SertError(f"cannot verify sert {version} in --offline mode without sert.lock or cached SHA256SUMS")

    if sums:
        if pyz_name not in sums or zip_name not in sums:
            raise SertError(f"SHA256SUMS for {repo}@{tag} is missing {pyz_name} or {zip_name}")
        if locked_pyz_sha and locked_pyz_sha != sums[pyz_name]:
            raise SertError(
                f"SHA-256 mismatch for {pyz_name}: sert.lock has {locked_pyz_sha}, SHA256SUMS has {sums[pyz_name]}"
            )
        if locked_zip_sha and locked_zip_sha != sums[zip_name]:
            raise SertError(
                f"SHA-256 mismatch for {zip_name}: sert.lock has {locked_zip_sha}, SHA256SUMS has {sums[zip_name]}"
            )

    expected_pyz_sha = locked_pyz_sha or sums[pyz_name]
    expected_zip_sha = locked_zip_sha or sums[zip_name]

    pyz_dest = cache_dir() / "cli" / pyz_name
    _, pyz_sha = download_verified(
        pyz_url,
        pyz_dest,
        offline=offline,
        expected_sha256=expected_pyz_sha,
        repo=repo,
        tag=tag,
        asset=pyz_name,
        mode=0o755,
    )

    zip_cache = cache_dir() / "downloads" / cache_key(zip_url)
    archive, zip_sha = download_verified(
        zip_url,
        zip_cache,
        offline=offline,
        expected_sha256=expected_zip_sha,
        repo=repo,
        tag=tag,
        asset=zip_name,
    )

    stamp = f"{zip_url}#{zip_sha}"
    if not _stamped(dest, stamp):
        extract_archive(archive, dest, strip=0)
        _write_stamp(dest, stamp)

    assets = {
        "sert.pyz": {"name": pyz_name, "url": pyz_url, "sha256": pyz_sha},
        "sert.zip": {"name": zip_name, "url": zip_url, "sha256": zip_sha},
    }
    return str(dest), assets


def _fetch_types(
    cfg: config_mod.Config,
    existing_lock: dict | None,
    *,
    offline: bool,
) -> tuple[str, dict[str, dict[str, str]]]:
    lsp_version = lock_mod.read_rokit_lsp_version(cfg.root)
    asset = "globalTypes.d.luau"
    url = types_url(lsp_version)

    locked_types = ((existing_lock or {}).get("assets") or {}).get(asset)
    expected_sha: str | None = None
    if isinstance(locked_types, dict):
        locked_lsp = locked_types.get("lsp_version")
        if locked_lsp in (None, lsp_version):
            expected_sha = locked_types.get("sha256")

    cached, types_sha = download_verified(
        url,
        cache_dir() / "downloads" / cache_key(url),
        offline=offline,
        expected_sha256=expected_sha,
        asset=asset,
    )
    dest = cfg.root / ".sert" / "types" / asset
    if dest.is_file() and lock_mod.sha256_file(dest) == types_sha:
        pass
    else:
        write_atomic(dest, cached.read_bytes())

    return str(dest), {
        asset: {
            "name": asset,
            "url": url,
            "sha256": types_sha,
            "lsp_version": lsp_version,
        }
    }


def _insert_alias_preserving_jsonc(raw: str, alias_value: str) -> str | None:
    """Insert `"sert": "<alias_value>"` inside an existing `"aliases": { ... }` object without stripping comments."""
    # Find `"aliases"` outside comments/strings using a lightweight scan.
    token_re = re.compile(r'("(?:\\.|[^"\\])*")|//[^\r\n]*|/\*[\s\S]*?\*/|(\{)')
    pos = 0
    length = len(raw)
    while m := token_re.search(raw, pos):
        pos = m.end()
        lit = m.group(1)
        if lit is None or json.loads(lit) != "aliases":
            continue
        # Advance past whitespace/comments/`:` to `{`
        rest = raw[pos:]
        colon_brace = re.match(r"^(?:\s|//[^\r\n]*|/\*[\s\S]*?\*/)*:(?:\s|//[^\r\n]*|/\*[\s\S]*?\*/)*\{", rest)
        if not colon_brace:
            continue
        brace_idx = pos + colon_brace.end() - 1
        after_brace = raw[brace_idx + 1 :]
        empty_close = re.match(r"^(\s*)\}", after_brace)
        entry_json = f'"sert": {json.dumps(alias_value)}'
        if empty_close:
            return raw[: brace_idx + 1] + f"\n    {entry_json}\n  " + raw[brace_idx + 1 + len(empty_close.group(1)) :]
        indent_match = re.search(r"\n([ \t]+)\"", after_brace)
        indent = indent_match.group(1) if indent_match else "    "
        return raw[: brace_idx + 1] + f"\n{indent}{entry_json}," + raw[brace_idx + 1 :]
    return None


def _update_luaurc(root: Path, *, want_sert: bool) -> None:
    if not want_sert:
        return
    path = root / ".luaurc"
    target = "./.sert/sert/src"
    raw = ""
    if path.is_file():
        try:
            raw = path.read_text(encoding="utf-8-sig")
            data = json.loads(strip_jsonc(raw))
        except (OSError, ValueError) as err:
            raise SertError(f"{path}: invalid JSON/JSONC ({err})") from err
        if not isinstance(data, dict):
            raise SertError(f"{path}: expected a JSON object")
    else:
        data = {}

    aliases = data.get("aliases")
    if aliases is None:
        aliases = {}
        data["aliases"] = aliases
    elif not isinstance(aliases, dict):
        raise SertError(f"{path}: aliases must be a JSON object")

    key = sert_alias_key(aliases)
    if key is not None:
        if aliases[key] != target:
            warn(f".luaurc already sets aliases.{key} = {aliases[key]!r}; leaving it alone")
        return

    if raw and ("//" in raw or "/*" in raw):
        preserved = _insert_alias_preserving_jsonc(raw, target)
        if preserved is not None:
            json.loads(strip_jsonc(preserved))
            write_atomic(path, preserved.encode("utf-8"))
            return

    aliases["sert"] = target
    write_atomic(path, (json.dumps(data, indent=2) + "\n").encode("utf-8"))


def override_paths(cfg: config_mod.Config) -> dict[str, Path]:
    out = dict(cfg.overrides)
    if "sert" not in out and (env_src := os.environ.get("SERT_SOURCE")):
        out["sert"] = Path(env_src).resolve() / "src"
    return out


def sert_src(cfg: config_mod.Config) -> Path:
    overrides = override_paths(cfg)
    if "sert" in overrides:
        return overrides["sert"]
    self_src = cfg.root / "src"
    if not cfg.table("sert").get("version") and (self_src / "init.luau").is_file():
        return self_src
    return cfg.root / ".sert" / "sert" / "src"


def types_path(root: Path) -> Path:
    return Path(root) / ".sert" / "types" / "globalTypes.d.luau"


def ensure_types(cfg: config_mod.Config) -> Path:
    path = types_path(cfg.root)
    if path.is_file():
        return path
    _fetch_types(cfg, lock_mod.load_lock(cfg.root), offline=False)
    return path


def unpinned_sert(cfg: config_mod.Config) -> str | None:
    if (cfg.root / "src" / "init.luau").is_file() and (cfg.root / "python" / "sert").is_dir():
        return None
    if "sert" in override_paths(cfg):
        return None
    if not cfg.table("sert").get("version"):
        return f'sert.toml has no [sert].version (add [sert] version = "{VERSION}" and run `{command("fetch")}`)'
    return None


def refresh_overrides(cfg: config_mod.Config) -> int:
    overrides = cfg.overrides
    if overrides and is_ci():
        raise SertError("[override] cannot be active when CI=true")
    if "sert" in overrides:
        src_root = overrides["sert"]
        dest = cfg.root / ".sert" / "sert"
        _mirror_tree(src_root / "src" if (src_root / "src").is_dir() else src_root, dest / "src")
        for extra in ("default.project.json", "LICENSE.txt"):
            if (src_root / extra).is_file():
                shutil.copy2(src_root / extra, dest / extra)
        return 1
    if env_src := os.environ.get("SERT_SOURCE"):
        src_root = Path(env_src).resolve()
        if src_root != cfg.root.resolve() and (src_root / "src").is_dir():
            dest = cfg.root / ".sert" / "sert"
            _mirror_tree(src_root / "src", dest / "src")
            return 1
    return 0


def ensure_fetched(cfg: config_mod.Config) -> None:
    if cfg.overrides and is_ci():
        raise SertError("[override] cannot be active when CI=true")
    if cfg.table("sert").get("version") and "sert" not in override_paths(cfg):
        if not (cfg.root / ".sert" / "sert" / "src").is_dir():
            if offline():
                raise SertError(f"sert {cfg.table('sert').get('version')} is not fetched (run `{command('fetch')}`)")
            fetch(cfg, only={"sert"})


def fetch(
    cfg: config_mod.Config,
    *,
    only: set[str] | None = None,
    offline: bool | None = None,
    update_luaurc: bool = True,
) -> dict:
    is_offline = bool(os.environ.get("SERT_OFFLINE", "").strip().lower() in ("1", "true", "yes")) if offline is None else offline
    wanted = only or set(PARTS)
    unknown = wanted - set(PARTS)
    if unknown:
        raise SertError(f"--only: unknown category {', '.join(sorted(unknown))} (choose from {', '.join(PARTS)})")
    existing_lock = lock_mod.load_lock(cfg.root)
    result: dict = {}
    collected_assets: dict[str, dict[str, str]] = {}
    if existing_lock:
        collected_assets.update(existing_lock.get("assets", {}))

    if "sert" in wanted:
        sert_path, sert_assets = _fetch_sert(cfg, existing_lock, offline=is_offline)
        result["sert"] = sert_path
        collected_assets.update(sert_assets)
        if update_luaurc:
            _update_luaurc(cfg.root, want_sert=bool(cfg.table("sert").get("version")) and "sert" not in cfg.overrides)

    if "types" in wanted:
        types_path, types_assets = _fetch_types(cfg, existing_lock, offline=is_offline)
        result["types"] = types_path
        collected_assets.update(types_assets)

    sert_tbl = cfg.table("sert")
    version_raw = sert_tbl.get("version")
    if version_raw and not is_offline and "sert" not in cfg.overrides and not os.environ.get("SERT_SOURCE"):
        version = str(version_raw).strip()
        repo = str(sert_tbl.get("repo") or DEFAULT_REPO).strip()
        if "sert.pyz" in collected_assets and "sert.zip" in collected_assets:
            lock_path = lock_mod.write_lock(cfg.root, version, repo, collected_assets)
            result["lock"] = str(lock_path)

    return result


def stub_bytes() -> bytes:
    here = Path(__file__).resolve()
    repo_stub = here.parents[2] / "tools" / "sert.py"
    if repo_stub.is_file():
        return repo_stub.read_bytes()
    archive = here.parents[1]
    if archive.is_file() and zipfile.is_zipfile(archive):
        with zipfile.ZipFile(archive) as zf:
            return zf.read("sert/_stub/sert.py")
    embedded = here.parent / "_stub" / "sert.py"
    if embedded.is_file():
        return embedded.read_bytes()
    raise SertError("bundled tools/sert.py stub not found")


STARTER_TOML = """\
[sert]
version = "{version}"

[test]
specs = ["test/**/*.spec.luau"]

[coverage]
include = ["src/**/*.luau"]
min = 80

[lint]
paths = ["src", "test"]
"""

STARTER_ROKIT = """\
[tools]
luau = "luau-lang/luau@0.724"
rojo = "rojo-rbx/rojo@7.7.0"
selene = "Kampfkarren/selene@0.31.0"
StyLua = "JohnnyMorganz/StyLua@2.5.2"
luau-lsp = "JohnnyMorganz/luau-lsp@1.70.0"
"""

STARTER_SPEC = """\
--!strict
local sert = require("@sert")

sert.describe("starter", function()
\tsert.test("adds integers", function()
\t\tsert.eq(2 + 3, 5)
\tend)

\tsert.prop("addition commutes", function(g)
\t\tlocal a, b = g:int(-100, 100), g:int(-100, 100)
\t\tsert.eq(a + b, b + a)
\tend)
end)
"""

GITIGNORE_LINES = ("/.sert/", "/sert.local.toml", "/coverage.out")


def _ensure_gitignore(root: Path) -> bool:
    path = root / ".gitignore"
    existing = path.read_text(encoding="utf-8") if path.is_file() else ""
    have = {line.strip() for line in existing.splitlines()}
    missing = [line for line in GITIGNORE_LINES if line not in have]
    if not missing:
        return False
    sep = "" if not existing or existing.endswith("\n") else "\n"
    write_atomic(path, (existing + sep + "\n".join(missing) + "\n").encode("utf-8"))
    return True


def init(root: Path, *, force: bool = False, do_fetch: bool = False) -> list[str]:
    root = root.resolve()
    root.mkdir(parents=True, exist_ok=True)
    written: list[str] = []

    toml_path = root / config_mod.CONFIG
    if not toml_path.exists() or force:
        write_atomic(toml_path, STARTER_TOML.format(version=VERSION).encode("utf-8"))
        written.append(posix(toml_path, root))

    rokit_path = root / "rokit.toml"
    if not rokit_path.exists() or force:
        write_atomic(rokit_path, STARTER_ROKIT.encode("utf-8"))
        written.append(posix(rokit_path, root))

    stub_path = root / "tools" / "sert.py"
    if not stub_path.exists() or force:
        stub_path.parent.mkdir(parents=True, exist_ok=True)
        write_atomic(stub_path, stub_bytes(), mode=0o755)
        written.append(posix(stub_path, root))

    if _ensure_gitignore(root):
        written.append(".gitignore")

    luaurc = root / ".luaurc"
    if not luaurc.exists():
        write_atomic(luaurc, (json.dumps({"aliases": {"sert": "./.sert/sert/src"}}, indent=2) + "\n").encode("utf-8"))
        written.append(".luaurc")
    else:
        _update_luaurc(root, want_sert=True)

    has_specs = any(root.glob("test/**/*.spec.luau")) or any(root.glob("tests/**/*.spec.luau"))
    starter = root / "test" / "example.spec.luau"
    if not has_specs and (not starter.exists() or force):
        starter.parent.mkdir(parents=True, exist_ok=True)
        write_atomic(starter, STARTER_SPEC.encode("utf-8"))
        written.append(posix(starter, root))

    if do_fetch:
        fetch(config_mod.load(root))
    return written


def cmd_fetch(args) -> int:
    cfg = config_mod.from_args(args)
    only = {item.strip() for raw in (args.only or []) for item in raw.split(",") if item.strip()} or None
    result = fetch(cfg, only=only, offline=True if args.offline else None)
    if args.json:
        print(json.dumps(result, indent=2))
    else:
        if result.get("sert"):
            print(f"sert: {result['sert']}")
        if result.get("types"):
            print(f"types: {result['types']}")
        if result.get("lock"):
            print(f"lock: {result['lock']}")
    return OK


def cmd_init(args) -> int:
    root = config_mod.find_root(args.root)
    written = init(root, force=args.force, do_fetch=args.fetch)
    for rel in written:
        print(f"wrote {rel}")
    if not written:
        print("nothing to write (pass --force to overwrite)")
    if not args.fetch:
        print(f"next: run `rokit install` and `{command('fetch')}`")
    return OK


def add_fetch_parser(subparsers, parents) -> None:
    parser = subparsers.add_parser(
        "fetch",
        parents=parents,
        help="Download and SHA-256 verify the sert package and Luau globalTypes into .sert/ and sert.lock",
    )
    parser.add_argument("--only", action="append", metavar="PART", help="Comma-separated subset of: sert, types")
    parser.add_argument("--offline", action="store_true", help="Use cached downloads only; never touch the network")
    parser.add_argument("--json", action="store_true", help="Print resolved paths as JSON")
    parser.set_defaults(func=cmd_fetch)


def add_init_parser(subparsers, parents) -> None:
    parser = subparsers.add_parser(
        "init",
        parents=parents,
        help="Scaffold sert.toml, rokit.toml, tools/sert.py, .luaurc, .gitignore, and a starter spec",
    )
    parser.add_argument("--force", action="store_true", help="Overwrite existing sert.toml, rokit.toml, and tools/sert.py")
    parser.add_argument("--fetch", action="store_true", help="Run `sert fetch` right after writing the files")
    parser.set_defaults(func=cmd_init)
