"""`sert run`: headless test runner with zero-return staging, typed lexical staging, and watch/failed modes."""

from __future__ import annotations

import argparse
from concurrent.futures import ThreadPoolExecutor
import contextlib
from dataclasses import dataclass, field
import json
import math
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import threading
import time
from xml.etree import ElementTree

from sert import config as config_mod, luau_lex, markers as markers_mod
from sert.util import (
    FAILED,
    INFRA,
    OK,
    TIMEOUT,
    OutputClosed,
    SertError,
    annotate,
    as_list,
    check_selection,
    expand_globs,
    guarded,
    has_glob,
    is_ci,
    load_json,
    luau_string,
    note,
    on_github_actions,
    posix,
    sert_alias,
    sert_alias_key,
    strip_jsonc,
    tool_search_path,
    which,
    write_atomic,
)

RUNNERS = ("luau", "lute", "lune")
DEFAULT_SPEC_GLOBS = ("test/**/*.spec.luau", "tests/**/*.spec.luau")
LAST_FAILED_REL = ".sert/last-failed.json"
STAGE_HEADER = "-- sert-stage-v4\n"
LEXICAL_MARKER = "return function(_ENV: any, ...: any): ...any"

ENV_GLOBAL_NAMES = (
    "Axes",
    "BrickColor",
    "CFrame",
    "CatalogSearchParams",
    "Color3",
    "ColorSequence",
    "ColorSequenceKeypoint",
    "DateTime",
    "Enum",
    "Faces",
    "FloatCurveKey",
    "Font",
    "Game",
    "Instance",
    "NumberRange",
    "NumberSequence",
    "NumberSequenceKeypoint",
    "OverlapParams",
    "PathWaypoint",
    "PhysicalProperties",
    "Random",
    "Ray",
    "RaycastParams",
    "Rect",
    "Region3",
    "TweenInfo",
    "UDim",
    "UDim2",
    "Vector2",
    "Vector2int16",
    "Vector3",
    "Vector3int16",
    "Workspace",
    "_G",
    "delay",
    "elapsedTime",
    "game",
    "os",
    "print",
    "require",
    "script",
    "shared",
    "spawn",
    "task",
    "tick",
    "time",
    "type",
    "typeof",
    "utf8",
    "wait",
    "warn",
    "workspace",
)
ENV_GLOBAL_SET = frozenset(ENV_GLOBAL_NAMES)

INIT_NAMES = (
    ("init.luau", "ModuleScript"),
    ("init.lua", "ModuleScript"),
    ("init.server.luau", "Script"),
    ("init.server.lua", "Script"),
    ("init.client.luau", "LocalScript"),
    ("init.client.lua", "LocalScript"),
)


def runner_of(cfg: config_mod.Config, runner: str | None = None, coverage: bool = False) -> str:
    chosen = runner or str(cfg.get("test.runner", "luau"))
    if chosen not in RUNNERS:
        raise SertError(f"[test].runner must be one of {', '.join(RUNNERS)}, not {chosen!r}")
    if coverage and chosen != "luau":
        raise SertError(f'--coverage requires runner = "luau" ({chosen} has no --coverage flag)')
    return chosen


def luau_command(root, runner: str = "luau") -> str:
    if found := which(runner, Path(root) if root is not None else None):
        return found
    raise SertError(f"{runner} not found on PATH or ~/.rokit/bin (run `rokit install` or place {runner} on PATH)")


def require_fetched(cfg: config_mod.Config, runner: str = "luau") -> None:
    from sert.fetch import unpinned_sert

    fetch_cmd = f"run `{config_mod.command('fetch')}`"
    alias = sert_alias(cfg.root)
    if isinstance(alias, str) and not alias.startswith("@"):
        target = Path(os.path.normpath(cfg.root / alias))
        fetched = Path(os.path.normpath(cfg.root / ".sert" / "sert"))
        if target.is_relative_to(fetched) and not (fetched / "src").is_dir():
            if problem := unpinned_sert(cfg):
                raise SertError(problem)
            raise SertError(f'.sert/sert is missing, which the .luaurc "sert" alias points into ({fetch_cmd})')


def entry_command(
    runner: str,
    binary: str,
    entry: str,
    program_args: list[str],
    coverage: bool,
    codegen: bool = True,
) -> list[str]:
    if runner == "lute":
        return [binary, "run", entry, *program_args]
    if runner == "lune":
        return [binary, "run", entry, *(["--", *program_args] if program_args else [])]
    flags = ["--coverage"] if coverage else (["--codegen"] if codegen else [])
    return [binary, *flags, entry, *(["-a", *program_args] if program_args else [])]


def wrap_luau_source(source: str, prelude: str = "") -> str:
    """Wrap a Luau module into a lexical `_ENV` factory (`function(_ENV, ...)`) with ZERO `setfenv`/`getfenv`,
    preserving all leading `--!` directives and keeping original line numbers `1..N` unchanged."""
    if source.startswith("#!"):
        source = "--" + source[2:]
    tokens = luau_lex.tokenize(source, include_comments=False)
    used = sorted(
        (luau_lex.referenced_identifiers(tokens) - luau_lex.type_function_identifiers(tokens)) & ENV_GLOBAL_SET
    )
    if used:
        lhs = ", ".join(used)
        rhs = ", ".join(f"_ENV.{name}" for name in used)
        binding = f"local {lhs} = {rhs}; "
    else:
        binding = ""
    wrapper_open = f"{LEXICAL_MARKER} {binding}{prelude}"
    offset = luau_lex.first_code_offset(source)
    if offset >= len(source):
        # Empty or comment-only module
        sep = "" if not source or source.endswith("\n") else "\n"
        return f"{source}{sep}{wrapper_open}return nil end\n"
    return f"{source[:offset]}{wrapper_open}{source[offset:]}\nend\n"


def _require_spec_for_lexical(rel_posix: str) -> str:
    if rel_posix in ("init.luau", "init.lua"):
        return "@self/lexical"
    for suffix in ("/init.luau", "/init.lua", ".luau", ".lua"):
        if rel_posix.endswith(suffix):
            return "@self/lexical/" + rel_posix[: -len(suffix)]
    return "@self/lexical/" + rel_posix


def _classify_script_file(path: Path) -> tuple[str, str] | None:
    name = path.name
    for suffix, class_name in (
        (".server.luau", "Script"),
        (".server.lua", "Script"),
        (".client.luau", "LocalScript"),
        (".client.lua", "LocalScript"),
        (".luau", "ModuleScript"),
        (".lua", "ModuleScript"),
    ):
        if name.endswith(suffix):
            return name[: -len(suffix)], class_name
    return None


def _luau_literal(value) -> str:
    if value is None:
        return "nil"
    if isinstance(value, bool):
        return "true" if value else "false"
    if isinstance(value, float) and not math.isfinite(value):
        return "(0 / 0)" if math.isnan(value) else ("math.huge" if value > 0 else "-math.huge")
    if isinstance(value, (int, float)):
        return repr(value)
    if isinstance(value, str):
        return luau_string(value)
    if isinstance(value, dict):
        return (
            "{ "
            + ", ".join(f"[{luau_string(str(k))}] = {_luau_literal(v)}" for k, v in sorted(value.items()))
            + " }"
        )
    if isinstance(value, list):
        return "{ " + ", ".join(_luau_literal(v) for v in value) + " }"
    raise TypeError(f"unsupported stage literal: {type(value)}")


def _apply_meta(node: dict, meta: dict, explicit_class: str | None = None) -> None:
    if "className" in meta and not explicit_class:
        node["className"] = meta["className"]
    for src_key, dst_key in ((("properties", "$properties"), "props"), (("attributes", "$attributes"), "attributes")):
        val = meta.get(src_key[0]) or meta.get(src_key[1])
        if isinstance(val, dict) and val:
            node[dst_key] = {**(node.get(dst_key) or {}), **val}


def _merge_rojo_nodes(target: dict, override: dict) -> None:
    if override.get("file") is not None:
        target["file"], target["className"] = override["file"], override["className"]
    elif override.get("className") and override["className"] != "Folder":
        target["className"] = override["className"]
    if "value" in override:
        target["value"] = override["value"]
    for key in ("props", "attributes"):
        if key in override:
            target[key] = {**(target.get(key) or {}), **override[key]}
    for child_key, child_val in override.get("children", {}).items():
        if child_key in target["children"]:
            _merge_rojo_nodes(target["children"][child_key], child_val)
        else:
            target["children"][child_key] = child_val


def _strip_luau_ext(rel_posix: str) -> str:
    for suffix in ("/init.luau", "/init.lua"):
        if rel_posix.endswith(suffix):
            return rel_posix[: -len(suffix)]
    if rel_posix.endswith(".luau"):
        return rel_posix[: -len(".luau")]
    if rel_posix.endswith(".lua"):
        return rel_posix[: -len(".lua")]
    return rel_posix


def _relative_luau_require(from_file: Path, target_module_file: Path) -> str:
    """Compute a Rojo+Luau compliant relative string require path from `from_file` to `target_module_file`."""
    # Inside `foo/init.luau`, `./bar` resolves to `foo/../bar` (sibling of `foo/`), while `@self/bar` resolves to `foo/bar`.
    is_init = from_file.name in ("init.luau", "init.lua")
    anchor_dir = from_file.parent.parent if is_init else from_file.parent
    target_no_ext = target_module_file
    if target_module_file.name in ("init.luau", "init.lua"):
        target_no_ext = target_module_file.parent
    else:
        for ext in (".luau", ".lua"):
            if target_module_file.name.endswith(ext):
                target_no_ext = target_module_file.with_name(target_module_file.name[: -len(ext)])
                break
    if is_init and target_no_ext.is_relative_to(from_file.parent) and target_no_ext != from_file.parent:
        sub = target_no_ext.relative_to(from_file.parent).as_posix()
        return f"@self/{sub}"
    rel = os.path.relpath(target_no_ext, anchor_dir).replace("\\", "/")
    if not rel.startswith(("./", "../")):
        rel = "./" + rel
    return rel


def _sync_sert_luaurc(root: Path, *, include_game: bool = False) -> None:
    """Write `.sert/.luaurc` re-anchoring all root `.luaurc` aliases so staged modules resolve `@sert`, `@game`, etc."""
    sert_dir = root / ".sert"
    sert_dir.mkdir(parents=True, exist_ok=True)
    root_luaurc = root / ".luaurc"
    data = load_json(root_luaurc) if root_luaurc.is_file() else {}
    raw_aliases = data.get("aliases") if isinstance(data, dict) and isinstance(data.get("aliases"), dict) else {}
    reanchored: dict[str, str] = {}
    for k, v in raw_aliases.items():
        if not isinstance(k, str) or not isinstance(v, str):
            continue
        target = (root / v).resolve()
        rel = os.path.relpath(target, sert_dir).replace("\\", "/")
        if not rel.startswith(("./", "../")):
            rel = "./" + rel
        reanchored[k] = rel
    if sert_alias_key(reanchored) is None:
        if (root / "src" / "init.luau").is_file() and (root / "python" / "sert").is_dir():
            reanchored["sert"] = "../src"
        elif (sert_dir / "sert" / "src").is_dir():
            reanchored["sert"] = "./sert/src"
        else:
            reanchored["sert"] = "../src"
    if include_game and "game" not in reanchored:
        reanchored["game"] = "./stage/game"
    payload = (json.dumps({"aliases": reanchored}, indent=2) + "\n").encode("utf-8")
    target_rc = sert_dir / ".luaurc"
    if not target_rc.is_file() or target_rc.read_bytes() != payload:
        write_atomic(target_rc, payload)


def _ensure_root_game_alias(root: Path) -> None:
    """Ensure `root / '.luaurc'` maps `@game` -> `./.sert/stage/game` without stripping JSONC comments."""
    rc_path = root / ".luaurc"
    target = "./.sert/stage/game"
    if rc_path.is_file():
        try:
            raw = rc_path.read_text(encoding="utf-8-sig")
            parsed = json.loads(strip_jsonc(raw))
        except (OSError, ValueError):
            return
        if not isinstance(parsed, dict):
            return
        aliases = parsed.get("aliases")
        if isinstance(aliases, dict) and any(isinstance(k, str) and k.lower() == "game" for k in aliases):
            return
        if "//" in raw or "/*" in raw:
            from sert.fetch import _insert_alias_preserving_jsonc

            # Reuse JSONC-preserving insertion by inserting `"game"` key
            token_re = re.compile(r'("(?:\\.|[^"\\])*")|//[^\r\n]*|/\*[\s\S]*?\*/|(\{)')
            pos = 0
            while m := token_re.search(raw, pos):
                pos = m.end()
                lit = m.group(1)
                if lit is None or json.loads(lit) != "aliases":
                    continue
                rest = raw[pos:]
                cb = re.match(r"^(?:\s|//[^\r\n]*|/\*[\s\S]*?\*/)*:(?:\s|//[^\r\n]*|/\*[\s\S]*?\*/)*\{", rest)
                if cb:
                    b_idx = pos + cb.end() - 1
                    entry_json = f'"game": {json.dumps(target)}'
                    after = raw[b_idx + 1 :]
                    empty_close = re.match(r"^(\s*)\}", after)
                    if empty_close:
                        updated = raw[: b_idx + 1] + f"\n    {entry_json}\n  " + raw[b_idx + 1 + len(empty_close.group(1)) :]
                    else:
                        ind_m = re.search(r'\n([ \t]+)"', after)
                        ind = ind_m.group(1) if ind_m else "    "
                        updated = raw[: b_idx + 1] + f"\n{ind}{entry_json}," + raw[b_idx + 1 :]
                    write_atomic(rc_path, updated.encode("utf-8"))
                    return
        if not isinstance(aliases, dict):
            aliases = {}
            parsed["aliases"] = aliases
        aliases["game"] = target
        write_atomic(rc_path, (json.dumps(parsed, indent=2) + "\n").encode("utf-8"))
    else:
        write_atomic(rc_path, (json.dumps({"aliases": {"game": target}}, indent=2) + "\n").encode("utf-8"))


def _sert_env_module_path(root: Path) -> Path | None:
    for candidate in (
        root / ".sert" / "sert" / "src" / "env" / "init.luau",
        root / ".sert" / "sert" / "src" / "env.luau",
        root / "src" / "env" / "init.luau",
        root / "src" / "env.luau",
    ):
        if candidate.is_file():
            return candidate.resolve()
    alias = sert_alias(root)
    if isinstance(alias, str) and not alias.startswith("@"):
        base = (root / alias).resolve()
        for sub in ("env/init.luau", "env.luau"):
            if (base / sub).is_file():
                return (base / sub).resolve()
    return None


def _write_typed_game_mirrors(root: Path, stage_dir: Path, root_tree: dict, file_map: dict[str, Path]) -> None:
    """Generate `--!strict` type-preserving mirror modules under `.sert/stage/game/` so `require("@game/...")`
    retains full static Luau types in `luau-lsp` AND delegates to the active `sert.env` instance when mounted."""
    game_dir = stage_dir / "game"
    desired: dict[Path, str] = {}
    env_mod = _sert_env_module_path(root)

    def emit_node(node: dict, rel_parts: tuple[str, ...], mount_parts: tuple[str, ...]) -> None:
        children = node.get("children") or {}
        file_rel = node.get("file")
        is_module = node.get("className") == "ModuleScript" and isinstance(file_rel, str) and file_rel in file_map
        if is_module:
            real_target = file_map[str(file_rel)]
            mirror_file = (
                game_dir.joinpath(*rel_parts, "init.luau")
                if children
                else game_dir.joinpath(*rel_parts[:-1], f"{rel_parts[-1]}.luau")
            )
            req_real = _relative_luau_require(mirror_file, real_target)
            mount_path = "/".join(mount_parts)
            if env_mod is not None:
                req_env = _relative_luau_require(mirror_file, env_mod)
                content = (
                    "--!strict\n"
                    f"local _env = require({luau_string(req_env)})\n"
                    f"type _Module = typeof(require({luau_string(req_real)}))\n"
                    "local _active: any = _env.active()\n"
                    f"local _inst = if _active ~= nil and type(_active._mountedByPath) == \"table\" then _active._mountedByPath[{luau_string(mount_path)}] else nil\n"
                    f"return (if _active ~= nil and _inst ~= nil then _active:require(_inst) else require({luau_string(req_real)})) :: _Module\n"
                )
            else:
                content = f"--!strict\nreturn require({luau_string(req_real)})\n"
            desired[mirror_file] = content

        for child_name, child_node in sorted(children.items()):
            emit_node(child_node, (*rel_parts, child_name), (*mount_parts, child_name))

    is_datamodel = root_tree.get("className") == "DataModel"
    top_children = root_tree.get("children") or {}
    if is_datamodel:
        for svc_name, svc_node in sorted(top_children.items()):
            emit_node(svc_node, (svc_name,), (svc_name,))
        # Also expose direct `@game/<Child>` aliases for children of ReplicatedStorage / ServerScriptService / ServerStorage
        # when `<Child>` does not collide with a top-level service name (enabling `require("@game/Shared/Foo")`).
        taken = set(top_children)
        for container_name in ("ReplicatedStorage", "ServerScriptService", "ServerStorage"):
            container = top_children.get(container_name)
            if not isinstance(container, dict):
                continue
            for short_name, short_node in sorted((container.get("children") or {}).items()):
                if short_name in taken:
                    continue
                taken.add(short_name)
                emit_node(short_node, (short_name,), (container_name, short_name))
    else:
        root_name = str(root_tree.get("name") or "Project")
        for child_name, child_node in sorted(top_children.items()):
            emit_node(child_node, (child_name,), (root_name, child_name))

    game_dir.mkdir(parents=True, exist_ok=True)
    for path, text in desired.items():
        if not path.is_file() or path.read_text(encoding="utf-8", errors="replace") != text:
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(text, encoding="utf-8")

    for existing in sorted(game_dir.rglob("*"), reverse=True):
        if existing.is_file() and existing not in desired:
            existing.unlink()
        elif existing.is_dir():
            try:
                existing.rmdir()
            except OSError:
                pass


def stage_project(root: Path | config_mod.Config, project_rel: str | None = None) -> Path:
    cfg = root if isinstance(root, config_mod.Config) else None
    if cfg is not None:
        project_rel = project_rel or str(cfg.get("test.stage"))
        root = cfg.root
    if not project_rel:
        raise SertError("[test].stage: project file not set")
    root_resolved = root.resolve()
    project_path = (root / project_rel).resolve()
    if not project_path.is_file():
        raise SertError(f"[test].stage: project file {project_rel} not found")

    stage_dir = root / ".sert" / "stage"
    lexical_dir, init_path = stage_dir / "lexical", stage_dir / "init.luau"
    force_rewrite = not init_path.is_file() or not init_path.read_text(encoding="utf-8", errors="replace").startswith(
        STAGE_HEADER
    )
    lexical_dir.mkdir(parents=True, exist_ok=True)
    staged_files: dict[str, Path] = {}

    def register_file(file_path: Path) -> str:
        resolved = file_path.resolve()
        try:
            rel = resolved.relative_to(root_resolved).as_posix()
        except ValueError:
            rel = os.path.relpath(resolved, root_resolved).replace("\\", "/").replace("..", "__up__")
        if rel not in staged_files:
            staged_files[rel] = resolved
            dest = lexical_dir / rel
            needs_write = (
                force_rewrite or not dest.is_file() or dest.stat().st_mtime_ns < resolved.stat().st_mtime_ns
            )
            if not needs_write:
                head = dest.read_text(encoding="utf-8", errors="replace")[:1024]
                if LEXICAL_MARKER not in head or "setfenv" in head or "__SERT_MUTANT" in head:
                    needs_write = True
            if needs_write:
                dest.parent.mkdir(parents=True, exist_ok=True)
                dest.write_text(
                    wrap_luau_source(resolved.read_text(encoding="utf-8", errors="replace")),
                    encoding="utf-8",
                )
        return rel

    def load_meta(meta_path: Path) -> dict | None:
        data = load_json(meta_path) if meta_path.is_file() else None
        return data if isinstance(data, dict) else None

    active_projects: set[Path] = set()

    def walk_fs_path(fs_path: Path, name: str, explicit_class: str | None = None) -> dict | None:
        if not fs_path.exists():
            return None
        if fs_path.is_file():
            if fs_path.name.endswith(".project.json") and fs_path.resolve() not in active_projects:
                return parse_rojo_project(fs_path, override_name=name)
            if fs_path.name.endswith(".txt"):
                stem = fs_path.name[: -len(".txt")]
                node: dict = {
                    "name": name,
                    "className": explicit_class or "StringValue",
                    "value": fs_path.read_text(encoding="utf-8", errors="replace").rstrip("\r\n"),
                    "children": {},
                }
                if meta := load_meta(fs_path.parent / f"{stem}.meta.json"):
                    _apply_meta(node, meta, explicit_class)
                return node
            classified = _classify_script_file(fs_path)
            if classified is None:
                return None
            stem, class_name = classified
            node = {
                "name": name,
                "className": explicit_class or class_name,
                "file": register_file(fs_path),
                "children": {},
            }
            if meta := load_meta(fs_path.parent / f"{stem}.meta.json"):
                _apply_meta(node, meta, explicit_class)
            return node
        nested_project = (fs_path / "default.project.json").resolve()
        if nested_project.is_file() and nested_project not in active_projects:
            return parse_rojo_project(nested_project, override_name=name)

        class_name, file_rel = explicit_class or "Folder", None
        init_names = {entry[0] for entry in INIT_NAMES}
        for init_name, init_class in INIT_NAMES:
            candidate = fs_path / init_name
            if candidate.is_file():
                class_name, file_rel = explicit_class or init_class, register_file(candidate)
                break

        children: dict[str, dict] = {}
        for entry in sorted(fs_path.iterdir(), key=lambda p: p.name):
            if entry.name.startswith(".") or entry.name in init_names or entry.name.endswith(".meta.json"):
                continue
            if entry.is_dir():
                if (child_node := walk_fs_path(entry, entry.name)) is not None:
                    if meta := load_meta(fs_path / f"{entry.name}.meta.json"):
                        _apply_meta(child_node, meta)
                    children[entry.name] = child_node
            elif entry.is_file() and not entry.name.endswith(".project.json"):
                child_name = (
                    entry.name[: -len(".txt")]
                    if entry.name.endswith(".txt")
                    else (classified[0] if (classified := _classify_script_file(entry)) else None)
                )
                if child_name is not None and (child_node := walk_fs_path(entry, child_name)) is not None:
                    children[child_name] = child_node

        node = {"name": name, "className": class_name, "file": file_rel, "children": children}
        if init_meta := load_meta(fs_path / "init.meta.json"):
            _apply_meta(node, init_meta, explicit_class)
        return node

    def parse_rojo_tree(tree: dict, base_dir: Path, name: str) -> dict:
        explicit_class, path_spec = tree.get("$className"), tree.get("$path")
        node: dict = {"name": name, "className": explicit_class or "Folder", "file": None, "children": {}}
        if (
            isinstance(path_spec, str)
            and (walked := walk_fs_path((base_dir / path_spec).resolve(), name, explicit_class=explicit_class))
            is not None
        ):
            node = walked
        _apply_meta(node, tree, explicit_class)
        for key, value in sorted(tree.items()):
            if not key.startswith("$") and isinstance(value, dict):
                child_node = parse_rojo_tree(value, base_dir, key)
                if key in node["children"]:
                    _merge_rojo_nodes(node["children"][key], child_node)
                else:
                    node["children"][key] = child_node
        return node

    def parse_rojo_project(proj_file: Path, override_name: str | None = None) -> dict:
        resolved_proj = proj_file.resolve()
        active_projects.add(resolved_proj)
        try:
            try:
                data = json.loads(strip_jsonc(proj_file.read_text(encoding="utf-8-sig")))
            except (OSError, UnicodeDecodeError, json.JSONDecodeError) as err:
                raise SertError(f"[test].stage: {proj_file}: {err}") from err
            if not isinstance(data, dict) or not isinstance(data.get("tree", {}), dict):
                raise SertError(f"[test].stage: {proj_file}: must be a JSON object with a table tree")
            return parse_rojo_tree(data.get("tree", {}), proj_file.parent, override_name or data.get("name", proj_file.stem))
        finally:
            active_projects.discard(resolved_proj)

    root_tree = parse_rojo_project(project_path)
    for existing in sorted(lexical_dir.rglob("*"), reverse=True):
        if existing.is_file() and existing.relative_to(lexical_dir).as_posix() not in staged_files:
            existing.unlink()
        elif existing.is_dir():
            try:
                existing.rmdir()
            except OSError:
                pass

    _write_typed_game_mirrors(root_resolved, stage_dir, root_tree, staged_files)
    _sync_sert_luaurc(root_resolved, include_game=True)
    uses_sourcemap = (
        cfg is not None
        and not cfg.get("test.entries")
        and cfg.get("lint.project") is not False
        and bool(cfg.get("lint.project") or (root_resolved / "default.project.json").is_file())
    )
    if not uses_sourcemap:
        _ensure_root_game_alias(root_resolved)

    file_entries = [
        f"\t\t[{luau_string(rel)}] = function() return require({luau_string(_require_spec_for_lexical(rel))}) end,"
        for rel in sorted(staged_files)
    ]
    init_luau = (
        f"{STAGE_HEADER}-- Generated by `sert run` from [test].stage; do not edit.\nreturn {{\n"
        f"\troot = {_luau_literal(root_tree)},\n\tfiles = {{\n"
        + "\n".join(file_entries)
        + "\n\t},\n}\n"
    )
    if not init_path.is_file() or init_path.read_text(encoding="utf-8", errors="replace") != init_luau:
        init_path.write_text(init_luau, encoding="utf-8")
    return init_path


def _sert_require_target(root: Path) -> str:
    if sert_alias(root) is not None:
        return "@sert"
    if (root / "src" / "init.luau").is_file() and (root / "python" / "sert").is_dir():
        return "../src"
    return "./sert/src" if (root / ".sert" / "sert" / "src").is_dir() else "../src"


def _sert_datatypes_require_target(root: Path) -> str | None:
    for rel_cand, req_str in (
        (root / ".sert" / "sert" / "src" / "engine" / "datatypes.luau", "./sert/src/engine/datatypes"),
        (root / ".sert" / "sert" / "src" / "doubles" / "datatypes.luau", "./sert/src/doubles/datatypes"),
        (root / "src" / "engine" / "datatypes.luau", "../src/engine/datatypes"),
        (root / "src" / "doubles" / "datatypes.luau", "../src/doubles/datatypes"),
    ):
        if rel_cand.is_file():
            return req_str
    return None


def _rewrite_relative_requires_same_line(source: str, orig_file: Path, staged_file: Path) -> str:
    """Rewrite relative string `require("./...")` / `require("../...")` / `require("@self/...")` in a staged
    0-return spec file so they resolve to the exact original module without shifting any line numbers."""
    tokens = luau_lex.tokenize(source, include_comments=False)
    edits: list[tuple[int, int, str]] = []
    n = len(tokens)
    orig_is_init = orig_file.name in ("init.luau", "init.lua")
    orig_anchor = orig_file.parent.parent if orig_is_init else orig_file.parent
    staged_anchor = staged_file.parent

    for i, tok in enumerate(tokens):
        if tok.kind != "IDENT" or tok.value != "require":
            continue
        if i > 0 and tokens[i - 1].kind == "OP" and tokens[i - 1].value in (".", ":"):
            continue
        str_tok: luau_lex.Token | None = None
        if i + 1 < n and tokens[i + 1].kind == "STRING":
            str_tok = tokens[i + 1]
        elif (
            i + 3 < n
            and tokens[i + 1].kind == "OP"
            and tokens[i + 1].value == "("
            and tokens[i + 2].kind == "STRING"
            and tokens[i + 3].kind == "OP"
            and tokens[i + 3].value == ")"
        ):
            str_tok = tokens[i + 2]
        if str_tok is None or str_tok.line != tok.line:
            continue
        raw_lit = str_tok.value
        if len(raw_lit) < 2 or raw_lit[0] not in ('"', "'") or "\n" in raw_lit:
            continue
        inner = raw_lit[1:-1]
        if inner.startswith("@self/"):
            target = (orig_file.parent / inner[len("@self/") :]).resolve()
        elif inner.startswith(("./", "../")):
            target = (orig_anchor / inner).resolve()
        else:
            continue
        rel = os.path.relpath(target, staged_anchor).replace("\\", "/")
        if not rel.startswith(("./", "../")):
            rel = "./" + rel
        edits.append((str_tok.start, str_tok.end, luau_string(rel)))

    if not edits:
        return source
    parts: list[str] = []
    last = 0
    for start, end, repl in edits:
        parts.append(source[last:start])
        parts.append(repl)
        last = end
    parts.append(source[last:])
    return "".join(parts)


def stage_zero_return_luau(root: Path, rel_posix: str) -> str:
    """Return the require path from `.sert/run.luau` for `rel_posix`. If the file has no top-level `return`
    or has a dotfile component (such as `.config.luau`) that Luau's string `require` refuses directly,
    stage a line-preserving copy under `.sert/stage/specs/`."""
    src_path = root / rel_posix
    source = src_path.read_text(encoding="utf-8", errors="replace")
    parts = [p for p in rel_posix.split("/") if p]
    has_dot = any(p.startswith(".") for p in parts)
    has_ret = luau_lex.has_top_level_return(source)
    if has_ret and not has_dot:
        return "../" + _strip_luau_ext(rel_posix)

    staged_rel = "/".join(("__dot_" + p[1:]) if p.startswith(".") else p for p in parts)
    staged_path = root / ".sert" / "stage" / "specs" / staged_rel
    rewritten = _rewrite_relative_requires_same_line(source, src_path.resolve(), staged_path.resolve())
    if has_ret:
        staged_text = rewritten
    else:
        sep = "" if rewritten.endswith("\n") else "\n"
        staged_text = f"{rewritten}{sep}return nil\n"
    if not staged_path.is_file() or staged_path.read_text(encoding="utf-8", errors="replace") != staged_text:
        staged_path.parent.mkdir(parents=True, exist_ok=True)
        staged_path.write_text(staged_text, encoding="utf-8")
    return "./stage/specs/" + _strip_luau_ext(staged_rel)


def discover_directory_configs(root: Path, spec_rels: list[str]) -> list[str]:
    """Discover `.config.luau` / `init.config.luau` files in ancestor directories of `spec_rels` (outermost first)."""
    root_resolved = root.resolve()
    found: dict[str, Path] = {}
    for rel in spec_rels:
        cur = (root / rel).resolve().parent
        chain: list[Path] = []
        while True:
            chain.append(cur)
            if cur == root_resolved or cur.parent == cur:
                break
            cur = cur.parent
        for folder in reversed(chain):
            for cfg_name in (".config.luau", "init.config.luau"):
                cand = folder / cfg_name
                if cand.is_file():
                    crel = posix(cand, root)
                    found.setdefault(crel, cand)
    return list(found.keys())


def write_spec_runner(
    root: Path,
    patterns: list[str],
    setup: str | None = None,
    *,
    roblox_globals: bool = False,
) -> str:
    expanded = []
    for pat in patterns:
        if not has_glob(pat) and (root / pat).is_dir():
            expanded.append(pat.rstrip("/") + "/**/*.spec.luau")
        elif not has_glob(pat) and not (root / pat).is_file():
            raise SertError(f'spec file {pat} not found (to run tests by name: run --filter "{pat}")')
        else:
            expanded.append(pat)
    spec_rels = [posix(path, root) for path in expand_globs(root, expanded, files=True)]
    if not spec_rels:
        raise SertError(f"no spec files matched {', '.join(patterns)}")

    _sync_sert_luaurc(root, include_game=(root / ".sert" / "stage" / "game").is_dir())

    lines = [
        "--!nonstrict",
        f"-- Generated by `sert run` (specs: {len(spec_rels)}); do not edit.",
    ]
    if roblox_globals:
        if dt_req := _sert_datatypes_require_target(root):
            lines.append(f"local _dt: any = require({luau_string(dt_req)})")
            lines.append('if type(_dt) == "table" and type(_dt.installGlobals) == "function" then _dt.installGlobals() end')

    lines += [
        f"local sert: any = require({luau_string(_sert_require_target(root))})",
        "local _rawArgs = { ... }",
        "local _coreArgs = {}",
        "local _extraOpts: { [string]: any } = {}",
        "local _greps = {}",
        "local _excludes = {}",
        "local _files = {}",
        "local _i = 1",
        "while _i <= #_rawArgs do",
        "\tlocal _a = _rawArgs[_i]",
        "\t_i += 1",
        '\tif type(_a) ~= "string" then continue end',
        '\tlocal _k, _v = string.match(_a, "^%-%-([%w%-]+)=(.*)$")',
        '\tif _k == "grep" then table.insert(_greps, _v)',
        '\telseif _k == "exclude" then table.insert(_excludes, _v)',
        '\telseif _k == "file" then table.insert(_files, _v)',
        '\telseif _k == "repeat" then _extraOpts.repeatCount = tonumber(_v)',
        '\telseif _k == "slowest" then _extraOpts.slowest = tonumber(_v)',
        '\telseif _k == "test-timeout" then local _n = tonumber(_v); _extraOpts.testTimeout = _n; _extraOpts.timeout = _n',
        '\telseif _a == "--allow-focused" then _extraOpts.allowFocused = true',
        '\telseif _a == "--ci" then _extraOpts.ci = true',
        '\telseif _k == "failed-names" then',
        "\t\tlocal _names = {}",
        '\t\tfor _item in string.gmatch(_v, "[^\\n]+") do table.insert(_names, _item) end',
        "\t\t_extraOpts.names = _names",
        "\telse table.insert(_coreArgs, _a) end",
        "end",
        "local options: any = sert.parseCliArgs(_coreArgs)",
        "for _ek, _ev in _extraOpts do options[_ek] = _ev end",
        "if #_greps == 1 then options.grep = _greps[1] elseif #_greps > 1 then options.grep = table.concat(_greps, \"|\") end",
        "if #_excludes == 1 then options.exclude = _excludes[1]; options.excludes = _excludes elseif #_excludes > 1 then options.exclude = table.concat(_excludes, \"|\"); options.excludes = _excludes end",
        "if #_files > 0 then options.file = _files[1]; options.files = _files end",
        "local function _normSpec(p: string): string",
        '\tlocal c = string.gsub(string.gsub(p, "^[@=]", ""), "%.luau?$", "")',
        '\tc = string.gsub(string.gsub(c, "\\\\", "/"), "^%./", "")',
        '\treturn string.lower((string.gsub(c, "%.spec$", "")))',
        "end",
        "local _wantedSpecs: { string }? = nil",
        'if options.files ~= nil or (type(options.filter) == "string" and string.sub(options.filter, 1, 6) == "@file=") then',
        "\tlocal _list: { string } = {}",
        "\tif options.files ~= nil then",
        "\t\tfor _, _f in options.files do table.insert(_list, _normSpec(_f)) end",
        "\tend",
        '\tif type(options.filter) == "string" and string.sub(options.filter, 1, 6) == "@file=" then',
        '\t\tfor _part in string.gmatch(string.sub(options.filter, 7), "[^,]+") do',
        '\t\t\tlocal _t = string.match(_part, "^%s*(.-)%s*$")',
        '\t\t\tif _t ~= nil and _t ~= "" then table.insert(_list, _normSpec(_t)) end',
        "\t\tend",
        "\tend",
        "\tif #_list > 0 then _wantedSpecs = _list end",
        "end",
        "local function _specMatches(file: string, wanted: { string }): boolean",
        "\tlocal norm = _normSpec(file)",
        '\tlocal base = string.match(norm, "[^/]+$") or norm',
        "\tfor _, w in wanted do",
        '\t\tif norm == w or base == w or string.sub(norm, -#w - 1) == "/" .. w then return true end',
        "\tend",
        "\treturn false",
        "end",
        "local shard = options.shard",
        "local shardIndex = if shard and shard.only == nil and shard.except == nil and (shard.count or 1) > 1 then shard.index else nil",
        "local shardCount = if shardIndex then shard.count else 1",
        f"local shardBySpec = shardIndex ~= nil and {len(spec_rels)} >= shardCount * 2 and options.filter == nil and options.grep == nil and options.files == nil and options.names == nil",
        "if shardBySpec then options.shard = nil; options._specSharded = true end",
        "local specIndex = 0",
        "local function spec(file: string, load: () -> any, isSetup: boolean?)",
        "\tif not isSetup and _wantedSpecs ~= nil and not _specMatches(file, _wantedSpecs) then return end",
        "\tif not isSetup and shardBySpec then",
        "\t\tspecIndex += 1",
        "\t\tif ((specIndex - 1) % shardCount) + 1 ~= shardIndex then return end",
        "\tend",
        "\tlocal ok, result = pcall(load)",
        '\tif ok and not (type(result) == "string" and string.match(result, "^.-:%d+: ")) then return end',
        "\tlocal message = `failed to load {file}: {result}`",
        "\tsert.test(file, function() error(message, 0) end, { file = file })",
        "end",
    ]

    seen_setups: set[str] = set()
    if setup:
        if not (root / setup).is_file():
            raise SertError(f"[test].setup: {setup} not found")
        srel = posix(root / setup, root)
        seen_setups.add(srel)
        req_s = stage_zero_return_luau(root, srel)
        lines.append(f"spec({luau_string(srel)}, function() return require({luau_string(req_s)}) end, true)")

    for cfg_rel in discover_directory_configs(root, spec_rels):
        if cfg_rel in seen_setups:
            continue
        seen_setups.add(cfg_rel)
        req_c = stage_zero_return_luau(root, cfg_rel)
        lines.append(f"spec({luau_string(cfg_rel)}, function() return require({luau_string(req_c)}) end, true)")

    for rel in spec_rels:
        req_spec = stage_zero_return_luau(root, rel)
        lines.append(f"spec({luau_string(rel)}, function() return require({luau_string(req_spec)}) end)")

    lines += ["return sert.run(options)", ""]
    runner_rel = ".sert/run.luau"
    runner_path = root / runner_rel
    runner_path.parent.mkdir(parents=True, exist_ok=True)
    runner_path.write_text("\n".join(lines), encoding="utf-8")
    return runner_rel


def resolve_entries(
    cfg: config_mod.Config,
    cli_entries: list[str] | None = None,
    cli_specs: list[str] | None = None,
    *,
    roblox_globals: bool = False,
) -> list[str]:
    if cli_entries and cli_specs:
        raise SertError("cannot pass both --entry and positional spec files")
    if cli_entries:
        return [str(e) for e in cli_entries]
    setup = cfg.get("test.setup")
    setup_str = str(setup) if setup else None
    want_globals = roblox_globals or str(cfg.get("test.globals", "")).lower() == "roblox"
    if cli_specs:
        return [write_spec_runner(cfg.root, [str(s) for s in cli_specs], setup=setup_str, roblox_globals=want_globals)]
    entries = [str(e) for e in as_list(cfg.get("test.entries", []))]
    if specs := [str(s) for s in as_list(cfg.get("test.specs", []))]:
        entries.append(write_spec_runner(cfg.root, specs, setup=setup_str, roblox_globals=want_globals))
    if not entries:
        # Auto-discover standard spec directories (`test/**/*.spec.luau`, `tests/**/*.spec.luau`)
        auto_specs = [posix(p, cfg.root) for p in expand_globs(cfg.root, list(DEFAULT_SPEC_GLOBS), files=True)]
        if auto_specs:
            entries.append(write_spec_runner(cfg.root, list(DEFAULT_SPEC_GLOBS), setup=setup_str, roblox_globals=want_globals))
    if not entries and not cfg.exists:
        raise SertError(f"no sert.toml in {cfg.root} (run `{config_mod.command('init')}`)")
    if not entries:
        raise SertError("nothing to run: add specs under test/**/*.spec.luau or set [test].entries / [test].specs in sert.toml")
    return entries


@dataclass
class EntryRun:
    entry: str
    code: int | None
    seconds: float
    timed_out: bool = False
    output: str = ""


@dataclass
class RunResult:
    status: int
    entries: list[EntryRun] = field(default_factory=list)
    tests: list[dict] = field(default_factory=list)

    @property
    def counts(self) -> dict:
        counts = {"passed": 0, "failed": 0, "skipped": 0, "todo": 0, "total": len(self.tests)}
        for test in self.tests:
            if key := {"pass": "passed", "fail": "failed", "skip": "skipped", "todo": "todo"}.get(test.get("status")):
                counts[key] += 1
        return counts

    @property
    def crashed(self) -> list[EntryRun]:
        failing = {test["entry"] for test in self.tests if test.get("status") == "fail"}
        return [run for run in self.entries if (run.timed_out or run.code) and run.entry not in failing]


HIDDEN_MARKERS = ("test", "seed", "done")


def _pump(stream, chunks: list[str], echo, hide_markers: bool, closed=None) -> None:
    echo = guarded(echo) if echo is not None else None
    for line in iter(stream.readline, ""):
        chunks.append(line)
        if echo is not None:
            found = markers_mod.split(line) if hide_markers else None
            if found is None or found[0] not in HIDDEN_MARKERS:
                try:
                    echo.write(line)
                    echo.flush()
                except OutputClosed:
                    echo = None
                    if closed is not None:
                        closed()


FAILED_RAISE = re.compile(r"^\d+ of \d+ tests failed$")


def _shown_stderr(stdout: str, stderr: str) -> str:
    if not any(isinstance(value, dict) and (value.get("failed") or 0) > 0 for value in markers_mod.parse(stdout).done):
        return stderr
    lines = stderr.splitlines(keepends=True)
    for index in range(len(lines) - 1, -1, -1):
        if FAILED_RAISE.match(lines[index].rstrip("\r\n")):
            return "".join(lines[:index])
    return stderr


def _kill(process: subprocess.Popen) -> None:
    if os.name == "posix":
        try:
            os.killpg(process.pid, 9)
        except OSError:
            process.kill()
    else:
        subprocess.run(
            ["taskkill", "/F", "/T", "/PID", str(process.pid)],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            timeout=10,
        )
        process.kill()
    process.wait()


_SPEC_COUNT_RE = re.compile(r"^-- Generated by `sert run` \(specs: (\d+)\)", re.M)
_SHARD_HEADER_RE = re.compile(r"^sert · \d+ tests? · ")
_SHARD_SUMMARY_RE = re.compile(r"^\d+ passed · \d+ failed · \d+ skipped")


def _entry_shard_count(root: Path, entry: str, args: list[str], coverage: bool, jobs: int | None) -> int:
    for arg in args:
        if arg in ("--list", "-x", "--fail-fast", "--exhaustive") or arg.startswith(
            ("--replay", "--mutant", "--mutants", "--shard", "--repeat=", "--slowest=", "--failed-names=")
        ):
            return 1
        if jobs is None and not (
            arg in ("--markers", "--compact", "--ci", "--allow-focused")
            or arg.startswith(("--seed=", "--runs=", "--budget=", "--test-timeout="))
        ):
            return 1
    target = jobs if jobs is not None else min(os.cpu_count() or 4, 6)
    if target <= 1:
        return 1
    try:
        src = (root / entry).read_text(encoding="utf-8", errors="ignore")
    except OSError:
        return 1
    if m := _SPEC_COUNT_RE.search(src):
        spec_count = int(m.group(1))
        if spec_count <= 1 and jobs is None:
            return 1
        if jobs is None and spec_count >= 18:
            target = min(os.cpu_count() or 4, min(12, spec_count // 3))
        return min(target, spec_count) if spec_count >= target * 2 else target
    if jobs is not None or "parseCliArgs" in src:
        return target
    return 1


def _run_sharded_entry(
    cfg: config_mod.Config,
    runner: str,
    binary: str,
    entry: str,
    args: list[str],
    coverage: bool,
    codegen: bool,
    timeout: float | None,
    markers: bool,
    asked: bool,
    echo: bool,
    shards: int,
    *,
    out=None,
    err=None,
) -> EntryRun:
    out_target = sys.stdout if out is None else out
    err_target = sys.stderr if err is None else err
    started = time.monotonic()
    entry_arg = str((cfg.root / entry).resolve()) if coverage else entry
    sub_env = dict(os.environ, PATH=tool_search_path())
    cov_tmp_dir = cfg.root / ".sert" / "cov"
    if coverage:
        cov_tmp_dir.mkdir(parents=True, exist_ok=True)

    def run_shard(index: int) -> tuple[int | None, bool, str, str, str]:
        command = entry_command(runner, binary, entry_arg, [*args, f"--shard={index}/{shards}"], coverage, codegen)
        with contextlib.ExitStack() as stack:
            shard_cwd = Path(stack.enter_context(tempfile.TemporaryDirectory(prefix="shard-", dir=cov_tmp_dir))) if coverage else cfg.root
            try:
                process = subprocess.Popen(
                    command,
                    cwd=shard_cwd,
                    env=sub_env,
                    stdout=subprocess.PIPE,
                    stderr=subprocess.PIPE if echo else subprocess.STDOUT,
                    text=True,
                    encoding="utf-8",
                    errors="replace",
                    start_new_session=os.name == "posix",
                )
            except OSError as exc:
                raise SertError(f"could not run {binary}: {exc}", INFRA)
            out_chunks: list[str] = []
            err_chunks: list[str] = []
            pumps = [threading.Thread(target=_pump, args=(process.stdout, out_chunks, None, False), daemon=True)]
            if echo:
                pumps.append(threading.Thread(target=_pump, args=(process.stderr, err_chunks, None, False), daemon=True))
            for pump in pumps:
                pump.start()
            timed_out = False
            code: int | None = None
            try:
                code = process.wait(timeout=timeout)
            except subprocess.TimeoutExpired:
                _kill(process)
                timed_out = True
            except KeyboardInterrupt:
                _kill(process)
                raise
            for pump, stream in zip(pumps, (process.stdout, process.stderr)):
                pump.join(timeout=10)
                if not pump.is_alive() and stream is not None:
                    stream.close()
            cov_file = shard_cwd / "coverage.out"
            cov_text = cov_file.read_text(encoding="utf-8", errors="replace") if coverage and cov_file.is_file() else ""
            return code, timed_out, "".join(out_chunks), "".join(err_chunks), cov_text

    try:
        with ThreadPoolExecutor(max_workers=shards) as pool:
            shard_runs = list(pool.map(run_shard, range(1, shards + 1)))
    finally:
        if coverage:
            with contextlib.suppress(OSError):
                cov_tmp_dir.rmdir()

    if coverage:
        cov_chunks = [cov_text for _, _, _, _, cov_text in shard_runs if cov_text]
        if cov_chunks:
            (cfg.root / "coverage.out").write_text("".join(cov_chunks), encoding="utf-8")

    wall_seconds = time.monotonic() - started
    run = EntryRun(entry, 0, wall_seconds)
    totals = {"passed": 0, "failed": 0, "skipped": 0, "skippedRtest": 0, "todo": 0, "total": 0}
    any_done = False
    seed_line: str | None = None
    body_lines: list[str] = []
    marker_lines: list[str] = []
    err_parts: list[str] = []

    for w_code, w_timeout, w_out, w_err, _ in shard_runs:
        if w_timeout:
            run.timed_out = True
        if w_code not in (None, 0) and run.code == 0:
            run.code = w_code
        elif w_code is None and run.code == 0:
            run.code = None
        if echo and w_err:
            err_parts.append(_shown_stderr(w_out, w_err))
        parsed = markers_mod.parse(w_out)
        for d in parsed.done:
            if isinstance(d, dict):
                any_done = True
                for k in totals:
                    totals[k] += int(d.get(k) or 0)
        lines = w_out.splitlines(keepends=True)
        for idx, line in enumerate(lines):
            found = markers_mod.split(line)
            if found is not None:
                kind = found[0]
                if kind == "seed":
                    if seed_line is None:
                        seed_line = line if line.endswith("\n") else line + "\n"
                elif kind != "done":
                    marker_lines.append(line if line.endswith("\n") else line + "\n")
                continue
            stripped = line.rstrip("\r\n")
            if _SHARD_HEADER_RE.match(stripped) or _SHARD_SUMMARY_RE.match(stripped):
                continue
            if stripped == "" and idx + 1 < len(lines) and _SHARD_SUMMARY_RE.match(lines[idx + 1].rstrip("\r\n")):
                continue
            body_lines.append(line if line.endswith("\n") else line + "\n")

    if not any_done:
        raw_out = "".join(w_out for _, _, w_out, _, _ in shard_runs)
        raw_err = "".join(w_err for _, _, _, w_err, _ in shard_runs)
        if echo and raw_out:
            guarded(out_target).write(raw_out)
            guarded(out_target).flush()
        if echo and err_parts:
            err_target.write("".join(err_parts))
            err_target.flush()
        run.output = raw_out + raw_err
        return run

    if totals["failed"] > 0 and run.code == 0:
        run.code = 1
    header = f"sert · {totals['total']} {'test' if totals['total'] == 1 else 'tests'} · Luau CLI · {shards} workers\n"
    rtest_note = (
        f" ({totals['skippedRtest']} rtest — run 'python3 tools/sert.py studio' to execute engine tests)"
        if totals["skippedRtest"] > 0
        else ""
    )
    todo_note = f" · {totals['todo']} todo" if totals["todo"] > 0 else ""
    footer = f"\n{totals['passed']} passed · {totals['failed']} failed · {totals['skipped'] - totals.get('unselected', 0)} skipped{rtest_note}{todo_note} · {round(wall_seconds * 1000)} ms\n"
    done_payload = {**totals, "clock": round(wall_seconds, 6)}
    done_line = f"[sert-done] {json.dumps(done_payload, separators=(',', ':'))}\n"

    human_text = header + "".join(body_lines) + footer
    if echo:
        out_stream = guarded(out_target)
        if markers and not asked:
            out_stream.write(human_text)
        else:
            out_stream.write(header + (seed_line or "") + "".join(body_lines) + "".join(marker_lines) + footer + done_line)
        out_stream.flush()
        if err_parts:
            err_target.write("".join(err_parts))
            err_target.flush()

    raw_err = "".join(w_err for _, _, _, w_err, _ in shard_runs)
    run.output = header + (seed_line or "") + "".join(body_lines) + "".join(marker_lines) + footer + done_line + raw_err
    return run


def run_entries(
    cfg: config_mod.Config,
    entries: list[str],
    *,
    runner: str | None = None,
    program_args=(),
    coverage: bool = False,
    codegen: bool = True,
    timeout: float | None = None,
    markers: bool = True,
    echo: bool = True,
    stop_on_timeout: bool = True,
    jobs: int | None = None,
    out=None,
    err=None,
) -> RunResult:
    out_target = sys.stdout if out is None else out
    err_target = sys.stderr if err is None else err
    runner = runner_of(cfg, runner, coverage)
    for entry in entries:
        if not (cfg.root / entry).is_file():
            raise SertError(f"[test].entries: {entry} not found")
    require_fetched(cfg, runner)
    binary = luau_command(cfg.root, runner)
    args = [str(a) for a in program_args]
    asked = "--markers" in args
    if markers and not asked:
        args.append("--markers")
    coverage_out = cfg.root / "coverage.out"
    chunks: list[str] = []
    result = RunResult(OK)
    sub_env = dict(os.environ, PATH=tool_search_path())

    for entry in entries:
        if coverage:
            coverage_out.unlink(missing_ok=True)
        shards = _entry_shard_count(cfg.root, entry, args, coverage, jobs)
        if shards > 1:
            run = _run_sharded_entry(
                cfg,
                runner,
                binary,
                entry,
                args,
                coverage,
                codegen,
                timeout,
                markers,
                asked,
                echo,
                shards,
                out=out_target,
                err=err_target,
            )
        else:
            command = entry_command(runner, binary, entry, args, coverage, codegen)
            started = time.monotonic()
            try:
                process = subprocess.Popen(
                    command,
                    cwd=cfg.root,
                    env=sub_env,
                    stdout=subprocess.PIPE,
                    stderr=subprocess.PIPE if echo else subprocess.STDOUT,
                    text=True,
                    encoding="utf-8",
                    errors="replace",
                    start_new_session=os.name == "posix",
                )
            except OSError as exc:
                raise SertError(f"could not run {binary}: {exc}", INFRA)
            run = EntryRun(entry, None, 0.0)
            out_chunks: list[str] = []
            err_chunks: list[str] = []
            closed = threading.Event()

            def stop(process=process):
                closed.set()
                _kill(process)

            pumps = [
                threading.Thread(
                    target=_pump,
                    args=(process.stdout, out_chunks, out_target if echo else None, markers and not asked, stop),
                    daemon=True,
                )
            ]
            if echo:
                pumps.append(threading.Thread(target=_pump, args=(process.stderr, err_chunks, None, False), daemon=True))
            for pump in pumps:
                pump.start()
            try:
                run.code = process.wait(timeout=timeout)
            except subprocess.TimeoutExpired:
                _kill(process)
                run.timed_out = True
            except KeyboardInterrupt:
                _kill(process)
                raise
            for pump, stream in zip(pumps, (process.stdout, process.stderr)):
                pump.join(timeout=10)
                if not pump.is_alive() and stream is not None:
                    stream.close()
            if closed.is_set():
                raise OutputClosed
            run.output = "".join(out_chunks) + "".join(err_chunks)
            run.seconds = time.monotonic() - started
            if echo and err_chunks:
                err_target.write(_shown_stderr("".join(out_chunks), "".join(err_chunks)))
                err_target.flush()

        result.entries.append(run)
        for test in markers_mod.parse(run.output).tests:
            result.tests.append({**test, "entry": entry})
        if coverage and len(entries) > 1 and coverage_out.is_file():
            chunks.append(coverage_out.read_text(encoding="utf-8", errors="replace"))
        if run.timed_out:
            if echo:
                lost = not any(test["entry"] == entry for test in result.tests)
                note(
                    f"{entry}: timed out after {timeout:g}s"
                    + (
                        f"; {runner}'s buffered output is lost on the kill, so no test result was read (find the hung test with --filter)"
                        if lost
                        else ""
                    ),
                    err=err_target,
                )
            result.status = TIMEOUT
            if stop_on_timeout:
                break
        elif run.code != 0:
            if echo:
                if snippets := _format_failure_snippets(run.output, cfg.root):
                    print(snippets, file=err_target)
                note(f"{entry}: failed (exit {run.code}, {run.seconds:.1f}s)", err=err_target)
            if result.status == OK:
                result.status = FAILED
    if coverage and len(entries) > 1 and chunks:
        coverage_out.write_text("".join(chunks), encoding="utf-8")
    return result


LOCATION = re.compile(r"([\w@./\\-]+?)(?:\.luau|\.lua)?:(\d+):")
SNIPPET_LOC = re.compile(r"([\w@./\\-]+?\.(?:luau|lua)|[\w@./\\-]+?):(\d+)(?::|\b)")
_STAGE_STRIP_PREFIXES = (
    "./",
    "../",
    ".sert/stage/lexical/",
    ".sert/stage/files/",
    ".sert/stage/specs/",
    "stage/lexical/",
    "stage/files/",
    "stage/specs/",
    "self/lexical/",
    "self/files/",
)


def _resolve_root_file(root: Path, raw_name: str) -> Path | None:
    clean = raw_name.replace("\\", "/").lstrip("@")
    changed = True
    while changed:
        changed = False
        for prefix in _STAGE_STRIP_PREFIXES:
            if clean.startswith(prefix):
                clean = clean[len(prefix) :]
                changed = True
    for candidate in (clean, clean + ".luau", clean + ".lua", raw_name):
        if not candidate:
            continue
        path = root / candidate
        if path.is_file():
            return path
    return None


def _format_failure_snippets(output_text: str, root: Path) -> str:
    if not output_text:
        return ""
    root = Path(root)
    blocks = output_text.split("❌ ")
    if len(blocks) > 1:
        failure_blocks = ["❌ " + b for b in blocks[1:]]
    elif "⚠️" in output_text or ".luau:" in output_text or ".lua:" in output_text:
        failure_blocks = [output_text]
    else:
        return ""

    rendered_blocks: list[str] = []
    for block in failure_blocks:
        seen: list[tuple[str, int, Path]] = []
        for line in block.splitlines():
            if "[sert-" in line:
                continue
            for match in SNIPPET_LOC.finditer(line):
                raw_name, line_str = match.group(1), match.group(2)
                path = _resolve_root_file(root, raw_name)
                if path is None:
                    continue
                rel = posix(path, root)
                if rel == ".sert/run.luau":
                    continue
                line_no = int(line_str)
                if not any(r == rel and ln == line_no for r, ln, _ in seen):
                    seen.append((rel, line_no, path))
                    if len(seen) >= 2:
                        break
            if len(seen) >= 2:
                break

        for rel, line_no, path in seen:
            try:
                src_lines = path.read_text(encoding="utf-8", errors="replace").splitlines()
            except OSError:
                continue
            if not (1 <= line_no <= len(src_lines)):
                continue
            start_ln = max(1, line_no - 1)
            end_ln = min(len(src_lines), line_no + 1)
            width = len(str(end_ln))
            snippet_lines = [f"   {rel}:{line_no}:"]
            for ln in range(start_ln, end_ln + 1):
                marker = " > " if ln == line_no else "   "
                snippet_lines.append(f"{marker}{ln:>{width}} | {src_lines[ln - 1]}")
            rendered_blocks.append("\n".join(snippet_lines))

    return "\n".join(rendered_blocks)


def failure_location(root: Path, test: dict) -> tuple[str | None, int | None]:
    message = str(test.get("message") or test.get("error") or test.get("err") or "")
    for match in LOCATION.finditer(message):
        resolved = _resolve_root_file(root, match.group(1))
        if resolved is not None:
            return posix(resolved, root), int(match.group(2))
    if name := str(test.get("file") or ""):
        if resolved := _resolve_root_file(root, name):
            return posix(resolved, root), None
        found = [
            p
            for p in expand_globs(root, [f"**/{name}.luau", f"**/{name}.spec.luau"], files=True)
            if ".sert" not in p.relative_to(root).parts
        ]
        if len(found) == 1:
            return posix(found[0], root), None
    return None, None


def annotate_failures(root: Path, result: RunResult, *, out=None) -> None:
    if not on_github_actions():
        return
    for test in result.tests:
        if test.get("status") == "fail":
            file, line = failure_location(root, test)
            annotate(
                "error",
                f"{test.get('name')}: {test.get('message') or 'failed'}",
                file=file,
                line=line,
                title="sert run",
                out=out,
            )
    for run in result.crashed:
        why = "timed out" if run.timed_out else f"exited {run.code}"
        annotate("error", f"{run.entry} {why} without a failed test", file=run.entry, title="sert run", out=out)


ANSI = re.compile(r"\x1b\[[0-9;?]*[ -/]*[@-~]")
XML_INVALID = re.compile("[^\t\n\r\x20-\ud7ff\ue000-\ufffd\U00010000-\U0010ffff]")


def xml_text(value) -> str:
    return XML_INVALID.sub("\ufffd", ANSI.sub("", str(value)))


def junit_xml(result: RunResult) -> bytes:
    suites: dict[str, list[dict]] = {}
    for test in result.tests:
        suites.setdefault(str(test.get("file") or test["entry"]), []).append(test)
    for run in result.crashed:
        why = "timed out" if run.timed_out else f"exited {run.code}"
        tail = run.output.strip().splitlines()[-20:]
        suites.setdefault(run.entry, []).append(
            {
                "name": f"{run.entry} {why}",
                "status": "fail",
                "ms": int(run.seconds * 1000),
                "message": "\n".join(tail) or why,
                "entry": run.entry,
            }
        )
    counts = result.counts
    root = ElementTree.Element(
        "testsuites",
        name="sert",
        tests=str(sum(len(t) for t in suites.values())),
        failures=str(counts["failed"] + len(result.crashed)),
        skipped=str(counts["skipped"] + counts["todo"]),
        time=f"{sum(run.seconds for run in result.entries):.3f}",
    )
    for name in sorted(suites):
        tests = suites[name]
        suite = ElementTree.SubElement(
            root,
            "testsuite",
            name=xml_text(name),
            tests=str(len(tests)),
            failures=str(sum(1 for t in tests if t.get("status") == "fail")),
            skipped=str(sum(1 for t in tests if t.get("status") in ("skip", "todo"))),
            time=f"{sum(int(t.get('ms') or 0) for t in tests) / 1000:.3f}",
        )
        for test in tests:
            case = ElementTree.SubElement(
                suite,
                "testcase",
                name=xml_text(test.get("name")),
                classname=xml_text(name),
                time=f"{int(test.get('ms') or 0) / 1000:.3f}",
            )
            if test.get("status") == "fail":
                message = xml_text(test.get("message") or "failed")
                failure = ElementTree.SubElement(case, "failure", message=message.splitlines()[0] if message else "")
                failure.text = message
            elif test.get("status") == "skip":
                ElementTree.SubElement(case, "skipped")
            elif test.get("status") == "todo":
                ElementTree.SubElement(case, "skipped", message="todo")
    ElementTree.indent(root)
    return ElementTree.tostring(root, encoding="utf-8", xml_declaration=True) + b"\n"


def json_report(result: RunResult) -> dict:
    return {
        "status": result.status,
        "counts": result.counts,
        "entries": [
            {"entry": run.entry, "code": run.code, "seconds": round(run.seconds, 3), "timedOut": run.timed_out}
            for run in result.entries
        ],
        "tests": [
            {k: v for k, v in test.items() if k in ("name", "file", "target", "status", "ms", "message", "seed", "entry")}
            for test in result.tests
        ],
    }


def save_last_failed(root: Path, result: RunResult) -> None:
    failed_names: list[str] = []
    failed_files: list[str] = []
    seeds: dict[str, int] = {}
    for test in result.tests:
        if test.get("status") != "fail":
            continue
        name = str(test.get("name") or "")
        if name and name not in failed_names:
            failed_names.append(name)
        file_name = str(test.get("file") or "")
        if file_name and file_name not in failed_files:
            failed_files.append(file_name)
        seed = test.get("seed")
        if name and isinstance(seed, int) and not isinstance(seed, bool):
            seeds[name] = seed
    payload = {
        "status": result.status,
        "failed": failed_names,
        "files": failed_files,
        "seeds": seeds,
    }
    target = Path(root) / LAST_FAILED_REL
    write_atomic(target, (json.dumps(payload, indent=2) + "\n").encode("utf-8"))


def load_last_failed(root: Path) -> dict:
    path = Path(root) / LAST_FAILED_REL
    data = load_json(path)
    if not isinstance(data, dict):
        raise SertError("sert run --failed: no previous run recorded in .sert/last-failed.json")
    failed = [str(x) for x in data.get("failed", ()) if x]
    if not failed:
        raise SertError("sert run --failed: the last recorded run had no failed tests")
    return data


def _unreported_spec_entry(result: RunResult) -> str | None:
    for run in result.entries:
        if not run.entry.endswith((".spec.luau", ".spec.lua")) or run.timed_out or run.code != 0:
            continue
        parsed = markers_mod.parse(run.output)
        if parsed.list_total is not None or parsed.listed or parsed.tests or any(isinstance(v, dict) for v in parsed.done):
            continue
        return run.entry
    return None


def ran_nothing(result: RunResult) -> bool:
    reported = False
    for run in result.entries:
        parsed = markers_mod.parse(run.output)
        if parsed.list_total is not None or parsed.listed:
            return False
        done = [value for value in parsed.done if isinstance(value, dict)]
        if parsed.tests or done:
            reported = True
        if any(t.get("status") in ("pass", "fail") for t in parsed.tests) or any(
            isinstance(value.get(key), (int, float)) and value[key] > 0 for value in done for key in ("passed", "failed")
        ):
            return False
    return reported or _unreported_spec_entry(result) is not None


def write_reports(root: Path, result: RunResult, junit: str | None = None, json_out: str | None = None) -> None:
    for target, data in (
        (junit, lambda: junit_xml(result)),
        (json_out, lambda: (json.dumps(json_report(result), indent=2) + "\n").encode()),
    ):
        if target:
            path = root / target
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(data())


def _seed(value: str) -> str:
    if value != "random":
        try:
            int(value)
        except ValueError:
            raise argparse.ArgumentTypeError(f"takes an integer or random, not {value!r}") from None
    return value


class _OneFilter(argparse.Action):
    def __call__(self, parser, namespace, value, option_string=None):
        if (old := getattr(namespace, self.dest, None)) is not None:
            parser.error(f'one filter only, got "{old}" and "{value}" (quote a filter with spaces)')
        setattr(namespace, self.dest, value)


_SUMMARY_COUNTS_RE = re.compile(r"(\d+)\s+passed\s+·\s+(\d+)\s+failed\s+·\s+(\d+)\s+skipped")


def _skipped_only_count(result: RunResult) -> int:
    total_skipped = 0
    for run in result.entries:
        m = _SUMMARY_COUNTS_RE.search(run.output)
        if m is not None:
            if int(m.group(1)) == 0 and int(m.group(2)) == 0:
                total_skipped += int(m.group(3))
            continue
        parsed = markers_mod.parse(run.output)
        if parsed.tests:
            if all(t.get("status") == "skip" for t in parsed.tests):
                total_skipped += len(parsed.tests)
            continue
        for value in parsed.done:
            if isinstance(value, dict) and (value.get("passed") or 0) == 0 and (value.get("failed") or 0) == 0:
                total_skipped += int(value.get("skipped") or 0)
    return total_skipped


def selection_args(args) -> list[str]:
    tokens = [f"--filter={args.filter}"] if getattr(args, "filter", None) is not None else []
    for grep_pat in as_list(getattr(args, "grep", None)):
        if grep_pat:
            tokens.append(f"--grep={grep_pat}")
    for ex_pat in as_list(getattr(args, "exclude", None)):
        if ex_pat:
            tokens.append(f"--exclude={ex_pat}")
    for file_pat in as_list(getattr(args, "file", None)):
        if file_pat:
            tokens.append(f"--file={file_pat}")
    for flag in ("fail_fast", "compact", "list", "exhaustive", "allow_focused", "ci"):
        if getattr(args, flag, False) or (flag == "compact" and os.environ.get("SERT_COMPACT") == "1"):
            tokens.append("--" + flag.replace("_", "-"))
    for flag, cli_name in (
        ("seed", "seed"),
        ("runs", "runs"),
        ("replay", "replay"),
        ("budget", "budget"),
        ("repeat", "repeat"),
        ("slowest", "slowest"),
        ("test_timeout", "test-timeout"),
    ):
        if (value := getattr(args, flag, None)) is not None:
            tokens.append(f"--{cli_name}={value:g}" if isinstance(value, float) else f"--{cli_name}={value}")
    return tokens


def _snapshot_luau_mtimes(root: Path) -> dict[str, int]:
    snap: dict[str, int] = {}
    for cur, dirs, files in os.walk(root):
        dirs[:] = [d for d in dirs if d not in (".git", ".sert", "node_modules", "__pycache__")]
        for name in files:
            if name.endswith((".luau", ".lua")) or name in ("sert.toml", "sert.local.toml"):
                full = Path(cur) / name
                try:
                    snap[str(full)] = full.stat().st_mtime_ns
                except OSError:
                    continue
    return snap


def watch_loop(
    args,
    root: Path,
    cfg: config_mod.Config,
    *,
    poll_interval: float = 0.25,
    max_cycles: int | None = None,
    out=None,
    err=None,
) -> int:
    out_stream = sys.stdout if out is None else out
    err_stream = sys.stderr if err is None else err
    single_args = argparse.Namespace(**vars(args))
    single_args.watch = False
    cycles = 0
    last_status = cmd_run(single_args, root=root, cfg=cfg, out=out_stream, err=err_stream)
    cycles += 1
    if max_cycles is not None and cycles >= max_cycles:
        return last_status
    prev = _snapshot_luau_mtimes(root)
    print("\nwatching .luau files for changes (Ctrl+C to stop)...", file=err_stream, flush=True)
    while True:
        time.sleep(poll_interval)
        cur = _snapshot_luau_mtimes(root)
        if cur != prev:
            prev = cur
            fresh_cfg = config_mod.load(root)
            last_status = cmd_run(single_args, root=root, cfg=fresh_cfg, out=out_stream, err=err_stream)
            cycles += 1
            if max_cycles is not None and cycles >= max_cycles:
                return last_status


def add_parser(subparsers) -> None:
    parser = subparsers.add_parser("run")
    parser.add_argument("--runner", choices=RUNNERS, help="runtime to execute entries with (default: [test].runner or luau)")
    parser.add_argument("--coverage", action="store_true", help="pass --coverage to luau (writes coverage.out)")
    parser.add_argument("--codegen", action="store_true", help="pass --codegen to luau (default)")
    parser.add_argument("--no-codegen", action="store_true", help="do not pass --codegen to luau")
    parser.add_argument("--roblox-globals", action="store_true", help="install standalone Roblox datatype globals before running specs")
    parser.add_argument("-j", "--jobs", type=int, metavar="N", help="worker processes for sharded suites")
    parser.add_argument("--timeout", type=float, metavar="S", help="seconds per entry before it counts as timed out (exit 3)")
    parser.add_argument("--entry", action="append", metavar="FILE", help="run only this entry (repeatable)")
    parser.add_argument("--watch", action="store_true", help="watch .luau files and re-run on edits")
    parser.add_argument("--junit", metavar="FILE", help="write a JUnit XML report (relative to the root)")
    parser.add_argument("--json-out", metavar="FILE", help="write the results as JSON (relative to the root)")
    parser.add_argument("specs", nargs="*", help="spec files, globs or directories to run instead of [test]")

    selection = parser.add_argument_group("selection & execution (sent to every entry)")
    selection.add_argument("--filter", action=_OneFilter, metavar="NAME", help="run tests whose name contains NAME")
    selection.add_argument("-g", "--grep", action="append", default=[], metavar="PATTERN", help="run tests matching pattern (repeatable)")
    selection.add_argument("--exclude", action="append", default=[], metavar="PATTERN", help="exclude tests matching pattern (repeatable)")
    selection.add_argument("--file", action="append", default=[], metavar="FILE", help="run tests from matching spec file (repeatable)")
    selection.add_argument("--failed", action="store_true", help="re-run only failed tests from .sert/last-failed.json")
    selection.add_argument("-x", "--fail-fast", action="store_true", help="stop at the first failure")
    selection.add_argument("--compact", action="store_true", help="suppress passing ✅ lines while keeping failures and summary")
    selection.add_argument("--list", action="store_true", help="print the catalogue; run nothing")
    selection.add_argument("--repeat", type=int, metavar="N", help="repeat selected tests N times")
    selection.add_argument("--slowest", type=int, metavar="N", help="report the N slowest tests")
    selection.add_argument("--test-timeout", type=float, metavar="S", help="per-test timeout in seconds")
    selection.add_argument("--allow-focused", action="store_true", help="allow .focus tests even in CI mode")
    selection.add_argument("--ci", action="store_true", help="enable strict CI checks (automatically set when $CI is truthy)")
    selection.add_argument("--seed", type=_seed, metavar="N|random", help="base seed of every property")
    selection.add_argument("--runs", type=int, metavar="N", help="cases per property")
    selection.add_argument("--replay", type=int, metavar="N", help="replay one failing property seed")
    selection.add_argument("--exhaustive", action="store_true", help="run only bounded-exhaustive properties")
    selection.add_argument("--budget", type=float, metavar="S", help="seconds an exhaustive property may take")
    parser.add_argument("-a", dest="program_args", nargs=argparse.REMAINDER, default=[], help="extra flags forwarded to every entry")
    parser.set_defaults(func=main)


def _validate_extra_flags(args) -> None:
    if (rep := getattr(args, "repeat", None)) is not None and rep < 1:
        raise SertError(f"--repeat takes a whole number from 1, got {rep}")
    if (slow := getattr(args, "slowest", None)) is not None and slow < 1:
        raise SertError(f"--slowest takes a whole number from 1, got {slow}")
    if (tt := getattr(args, "test_timeout", None)) is not None and not 0 < tt < math.inf:
        raise SertError(f"--test-timeout takes a number of seconds above 0, got {tt:g}")
    for grep_pat in as_list(getattr(args, "grep", None)):
        if grep_pat:
            try:
                re.compile(str(grep_pat))
            except re.error as exc:
                raise SertError(f"--grep: invalid pattern {grep_pat!r}: {exc}") from exc


def cmd_run(
    args,
    root: Path | None = None,
    cfg: config_mod.Config | dict | None = None,
    *,
    out=None,
    err=None,
) -> int:
    out_stream = sys.stdout if out is None else out
    err_stream = sys.stderr if err is None else err
    check_selection(args)
    _validate_extra_flags(args)
    program_args = list(getattr(args, "program_args", None) or [])
    if "--silent" in program_args:
        raise SertError("sert run: --silent hides the markers sert run reads its results from; it is for hand-run entries")
    if cfg is None or not isinstance(cfg, config_mod.Config):
        cfg = config_mod.load(root) if root is not None else config_mod.from_args(args)
    run_root = Path(root) if root is not None else cfg.root

    if getattr(args, "watch", False):
        return watch_loop(args, run_root, cfg, out=out_stream, err=err_stream)

    from sert import fetch

    coverage = bool(getattr(args, "coverage", False))
    runner = runner_of(cfg, getattr(args, "runner", None), coverage=coverage)
    codegen = (bool(cfg.get("test.codegen", True)) or getattr(args, "codegen", False)) and not getattr(
        args, "no_codegen", False
    )
    jobs_arg = getattr(args, "jobs", None)
    cfg_jobs = cfg.get("test.jobs")
    jobs = jobs_arg if jobs_arg is not None else (int(cfg_jobs) if cfg_jobs is not None else None)
    if jobs is not None and jobs < 1:
        raise SertError(f"--jobs takes a whole number from 1, got {jobs}")

    fetch.refresh_overrides(cfg)
    fetch.ensure_fetched(cfg)

    if stage_spec := cfg.get("test.stage"):
        stage_project(cfg, str(stage_spec))

    want_roblox_globals = bool(getattr(args, "roblox_globals", False)) or str(cfg.get("test.globals", "")).lower() == "roblox"
    entries = resolve_entries(
        cfg,
        getattr(args, "entry", None),
        getattr(args, "specs", None),
        roblox_globals=want_roblox_globals,
    )

    eff_args = argparse.Namespace(**vars(args)) if hasattr(args, "__dict__") else argparse.Namespace()
    if is_ci() and not getattr(eff_args, "ci", False):
        eff_args.ci = True
    if cfg.get("test.allow_focused") and not getattr(eff_args, "allow_focused", False):
        eff_args.allow_focused = True
    if getattr(eff_args, "test_timeout", None) is None and cfg.get("test.timeout") is not None:
        eff_args.test_timeout = float(cfg.get("test.timeout"))
    if getattr(eff_args, "repeat", None) is None and cfg.get("test.repeat") is not None:
        eff_args.repeat = int(cfg.get("test.repeat"))
    if getattr(eff_args, "slowest", None) is None and cfg.get("test.slowest") is not None:
        eff_args.slowest = int(cfg.get("test.slowest"))

    extra_failed_args: list[str] = []
    if getattr(eff_args, "failed", False):
        last_failed = load_last_failed(run_root)
        failed_names = last_failed["failed"]
        if len(entries) == 1 and entries[0] == ".sert/run.luau":
            extra_failed_args.append("--failed-names=" + "\n".join(failed_names))
        elif len(failed_names) == 1 and getattr(eff_args, "filter", None) is None:
            eff_args.filter = failed_names[0]
        seeds_map = last_failed.get("seeds") or {}
        if len(failed_names) == 1 and failed_names[0] in seeds_map and getattr(eff_args, "replay", None) is None:
            eff_args.replay = int(seeds_map[failed_names[0]])

    forwarded = [*selection_args(eff_args), *extra_failed_args, *program_args]
    result = run_entries(
        cfg,
        entries,
        runner=runner,
        program_args=forwarded,
        coverage=coverage,
        codegen=codegen,
        timeout=getattr(args, "timeout", None),
        jobs=jobs,
        out=out_stream,
        err=err_stream,
    )
    if result.status == OK and ran_nothing(result):
        has_sel = bool(
            getattr(eff_args, "filter", None)
            or getattr(eff_args, "grep", None)
            or getattr(eff_args, "file", None)
            or getattr(eff_args, "specs", None)
        )
        skipped_count = _skipped_only_count(result) if has_sel else 0
        if spec_entry := _unreported_spec_entry(result):
            note(
                f"sert run: {spec_entry} exited without running any tests: "
                f"--entry takes a runner script that calls sert.run(), while spec files should be passed as positional arguments (sert run {spec_entry})",
                err=err_stream,
            )
        elif skipped_count > 0:
            note(
                f"sert run: all {skipped_count} matching tests were skipped (use 'python3 tools/sert.py studio' to run rtest engine specs)",
                err=err_stream,
            )
        else:
            note("sert run: no test ran: the selection matched none of the tests", err=err_stream)
        result.status = FAILED

    if not getattr(eff_args, "list", False):
        save_last_failed(run_root, result)

    annotate_failures(run_root, result, out=out_stream)
    write_reports(run_root, result, getattr(args, "junit", None), getattr(args, "json_out", None))
    return result.status


def main(args) -> int:
    return cmd_run(args)
