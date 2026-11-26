"""Hybrid static + dynamic Test Impact Analysis (TIA) and spec-routing dependency graph."""

from __future__ import annotations

from dataclasses import dataclass, field
import hashlib
import json
import os
from pathlib import Path
import re
import sys

from sert import config as config_mod, coverage as coverage_mod, luau_lex
from sert.util import as_list, expand_globs, load_json, load_json_strict, posix, write_atomic

COVERAGE_MAP_REL = ".sert/coverage-map.json"
GRAPH_CACHE_REL = ".sert/graph-cache.json"
_GRAPH_CACHE_VERSION = 1
DEFAULT_SPEC_GLOBS = ("test/**/*.spec.luau", "tests/**/*.spec.luau")
INIT_NAMES = (
    "init.luau",
    "init.lua",
    "init.server.luau",
    "init.server.lua",
    "init.client.luau",
    "init.client.lua",
)
INIT_NAME_SET = frozenset(INIT_NAMES)
SCRIPT_SUFFIXES = (
    ".server.luau",
    ".server.lua",
    ".client.luau",
    ".client.lua",
    ".luau",
    ".lua",
)
GLOBAL_INVALIDATION_NAMES = frozenset(
    {
        "sert.toml",
        "sert.local.toml",
        ".luaurc",
        "rokit.toml",
        ".config.luau",
        "init.config.luau",
        ".sert-regressions.toml",
    }
)
_SKIP_DIRS = frozenset({".git", ".sert", "node_modules", "__pycache__", ".venv", "venv", "dist", "build"})
_CONTAINER_SHORT_NAMES = ("ReplicatedStorage", "ServerScriptService", "ServerStorage")


def _cfg_get(cfg, dotted: str, default=None):
    if cfg is None:
        return default
    if isinstance(cfg, config_mod.Config):
        return cfg.get(dotted, default)
    if isinstance(cfg, dict):
        if dotted in cfg:
            return cfg[dotted]
        node = cfg
        for part in dotted.split("."):
            if not isinstance(node, dict) or part not in node:
                return default
            node = node[part]
        return node
    return default


def _norm_rel(path: Path | str, root: Path) -> str:
    normed = coverage_mod.norm(str(path), root)
    while normed.startswith("./"):
        normed = normed[2:]
    return normed


def _is_inside_root(candidate: Path, root_resolved: Path) -> bool:
    try:
        resolved = candidate.resolve()
        return resolved == root_resolved or resolved.is_relative_to(root_resolved)
    except OSError:
        return False


def _rel_if_inside(candidate: Path, root_resolved: Path) -> str | None:
    try:
        resolved = candidate.resolve()
        if not resolved.is_relative_to(root_resolved):
            return None
        rel = resolved.relative_to(root_resolved).as_posix()
        if rel == ".sert" or rel.startswith(".sert/"):
            return None
        return rel
    except OSError:
        return None


def _resolve_module_path(base: Path, root_resolved: Path) -> str | None:
    """Resolve a module path (with or without `.luau`/`.lua` or directory `init.luau`) inside `root_resolved`."""
    candidates: list[Path] = []
    if base.suffix in (".luau", ".lua"):
        candidates.append(base)
    else:
        base_str = str(base)
        candidates.extend(
            [
                Path(base_str + ".luau"),
                Path(base_str + ".lua"),
                base / "init.luau",
                base / "init.lua",
                base / "init.server.luau",
                base / "init.server.lua",
                base / "init.client.luau",
                base / "init.client.lua",
                base,
            ]
        )
    for cand in candidates:
        if cand.is_file() and cand.suffix in (".luau", ".lua"):
            if rel := _rel_if_inside(cand, root_resolved):
                return rel
    return None


def _load_luaurc_layers(rc_path: Path, visited: set[Path]) -> list[tuple[Path, dict[str, str]]]:
    resolved = rc_path.resolve()
    if resolved in visited or not resolved.is_file():
        return []
    visited.add(resolved)
    parsed = load_json_strict(resolved)
    if not isinstance(parsed, dict):
        return []
    layers: list[tuple[Path, dict[str, str]]] = []
    extends = parsed.get("extends")
    if isinstance(extends, str) and extends.strip():
        ext_spec = Path(extends.strip())
        ext_cand = ext_spec if ext_spec.is_absolute() else (resolved.parent / ext_spec)
        ext_rc = (
            ext_cand
            if (ext_cand.suffix == ".luaurc" or ext_cand.name == ".luaurc" or ext_cand.is_file())
            else (ext_cand / ".luaurc")
        )
        if ext_rc.is_file():
            layers.extend(_load_luaurc_layers(ext_rc, visited))
    aliases = parsed.get("aliases")
    if isinstance(aliases, dict):
        clean = {
            k: v.replace("\\", "/")
            for k, v in aliases.items()
            if isinstance(k, str) and isinstance(v, str)
        }
        if clean:
            layers.append((resolved.parent, clean))
    return layers


def load_luaurc_aliases(root: Path, directory: Path | None = None) -> dict[str, Path]:
    """Load `.luaurc` aliases (including `extends`) inherited from `root` down to `directory`."""
    root_resolved = Path(root).resolve()
    target_dir = root_resolved if directory is None else Path(directory).resolve()
    if not target_dir.is_relative_to(root_resolved):
        target_dir = root_resolved

    chain: list[Path] = []
    cur = target_dir
    while True:
        chain.append(cur)
        if cur == root_resolved or cur.parent == cur:
            break
        cur = cur.parent

    raw_aliases: dict[str, tuple[Path, str]] = {}
    lower_to_key: dict[str, str] = {}
    visited_rcs: set[Path] = set()
    for folder in reversed(chain):
        for base_dir, aliases in _load_luaurc_layers(folder / ".luaurc", visited_rcs):
            for key, val in aliases.items():
                prev_key = lower_to_key.get(key.lower())
                if prev_key is not None and prev_key != key:
                    raw_aliases.pop(prev_key, None)
                lower_to_key[key.lower()] = key
                raw_aliases[key] = (base_dir, val)

    resolved: dict[str, Path] = {}

    def resolve_alias(name: str, seen: set[str]) -> Path | None:
        canonical = lower_to_key.get(name.lower())
        if canonical is None or canonical in seen:
            return None
        if canonical in resolved:
            return resolved[canonical]
        base_dir, target_str = raw_aliases[canonical]
        if target_str.startswith("@"):
            sub_body = target_str[1:]
            head, _, tail = sub_body.partition("/")
            parent_target = resolve_alias(head, seen | {canonical})
            if parent_target is None:
                return None
            out = (parent_target / tail).resolve() if tail else parent_target
            resolved[canonical] = out
            return out
        cand = Path(target_str)
        out = cand.resolve() if cand.is_absolute() else (base_dir / cand).resolve()
        resolved[canonical] = out
        return out

    for key in list(raw_aliases):
        resolve_alias(key, set())
    return resolved


@dataclass(eq=False)
class _RojoNode:
    name: str
    file: str | None = None
    class_name: str = "Folder"
    children: dict[str, _RojoNode] = field(default_factory=dict)
    parent: _RojoNode | None = field(default=None, repr=False)


@dataclass
class RojoIndex:
    """Lookup tables built from one or more Rojo `*.project.json` trees."""

    paths: dict[tuple[str, ...], str] = field(default_factory=dict)
    file_nodes: dict[str, list[_RojoNode]] = field(default_factory=dict)

    def resolve_path(self, parts: list[str] | tuple[str, ...]) -> str | None:
        key = tuple(p for p in parts if p)
        return self.paths.get(key)

    def resolve_script_relative(self, from_rel: str, parts: list[str] | tuple[str, ...]) -> str | None:
        nodes = self.file_nodes.get(from_rel)
        if not nodes:
            return None
        for start in nodes:
            cur: _RojoNode | None = start
            ok = True
            for step in parts:
                if cur is None:
                    ok = False
                    break
                if step == "Parent":
                    cur = cur.parent
                else:
                    cur = cur.children.get(step)
            if ok and cur is not None and cur.file is not None:
                return cur.file
        return None


def _classify_script_name(name: str) -> str | None:
    for suffix in SCRIPT_SUFFIXES:
        if name.endswith(suffix):
            return name[: -len(suffix)]
    return None


def _merge_rojo_nodes(target: _RojoNode, override: _RojoNode) -> None:
    if override.file is not None:
        target.file = override.file
        target.class_name = override.class_name
    elif override.class_name != "Folder":
        target.class_name = override.class_name
    for child_name, child_node in override.children.items():
        if child_name in target.children:
            _merge_rojo_nodes(target.children[child_name], child_node)
        else:
            child_node.parent = target
            target.children[child_name] = child_node


def _parse_rojo_project_tree(proj_file: Path, root_resolved: Path) -> _RojoNode | None:
    active_projects: set[Path] = set()

    def walk_fs(fs_path: Path, name: str, explicit_class: str | None = None) -> _RojoNode | None:
        if not fs_path.exists():
            return None
        if fs_path.is_file():
            if fs_path.name.endswith(".project.json") and fs_path.resolve() not in active_projects:
                return parse_project(fs_path, override_name=name)
            if fs_path.suffix in (".luau", ".lua"):
                rel = _rel_if_inside(fs_path, root_resolved)
                return _RojoNode(name=name, file=rel, class_name=explicit_class or "ModuleScript")
            return None

        nested_proj = (fs_path / "default.project.json").resolve()
        if nested_proj.is_file() and nested_proj not in active_projects:
            return parse_project(nested_proj, override_name=name)

        node = _RojoNode(name=name, class_name=explicit_class or "Folder")
        for init_name in INIT_NAMES:
            cand = fs_path / init_name
            if cand.is_file():
                node.file = _rel_if_inside(cand, root_resolved)
                node.class_name = explicit_class or "ModuleScript"
                break

        try:
            entries = sorted(fs_path.iterdir(), key=lambda p: p.name)
        except OSError:
            entries = []
        for entry in entries:
            if entry.name.startswith(".") or entry.name in INIT_NAME_SET or entry.name.endswith(".meta.json"):
                continue
            if entry.is_dir():
                if (child := walk_fs(entry, entry.name)) is not None:
                    child.parent = node
                    node.children[entry.name] = child
            elif entry.is_file() and not entry.name.endswith(".project.json"):
                if (child_name := _classify_script_name(entry.name)) is not None:
                    if (child := walk_fs(entry, child_name)) is not None:
                        child.parent = node
                        node.children[child_name] = child
        return node

    def parse_tree_obj(tree: dict, base_dir: Path, name: str) -> _RojoNode:
        explicit_class = tree.get("$className") if isinstance(tree.get("$className"), str) else None
        path_spec = tree.get("$path")
        node = _RojoNode(name=name, class_name=explicit_class or "Folder")
        if isinstance(path_spec, str):
            walked = walk_fs((base_dir / path_spec).resolve(), name, explicit_class=explicit_class)
            if walked is not None:
                node = walked
        for key, value in sorted(tree.items()):
            if not key.startswith("$") and isinstance(value, dict):
                child = parse_tree_obj(value, base_dir, key)
                if key in node.children:
                    _merge_rojo_nodes(node.children[key], child)
                else:
                    child.parent = node
                    node.children[key] = child
        return node

    def parse_project(path: Path, override_name: str | None = None) -> _RojoNode | None:
        resolved = path.resolve()
        if resolved in active_projects:
            return None
        active_projects.add(resolved)
        try:
            data = load_json_strict(resolved)
        finally:
            active_projects.discard(resolved)
        if not isinstance(data, dict) or not isinstance(data.get("tree"), dict):
            return None
        proj_name = override_name or (str(data["name"]) if isinstance(data.get("name"), str) else resolved.stem)
        return parse_tree_obj(data["tree"], resolved.parent, proj_name)

    return parse_project(proj_file)


def _index_rojo_tree(root_node: _RojoNode, index: RojoIndex) -> None:
    def record_subtree(node: _RojoNode, prefix: tuple[str, ...]) -> None:
        if node.file is not None and prefix:
            index.paths.setdefault(prefix, node.file)
        if node.file is not None:
            nodes = index.file_nodes.setdefault(node.file, [])
            if node not in nodes:
                nodes.append(node)
        for child_name, child_node in node.children.items():
            record_subtree(child_node, (*prefix, child_name))

    if root_node.class_name == "DataModel":
        for svc_name, svc_node in root_node.children.items():
            record_subtree(svc_node, (svc_name,))
        taken = set(root_node.children)
        for container_name in _CONTAINER_SHORT_NAMES:
            container = root_node.children.get(container_name)
            if container is None:
                continue
            for short_name, short_node in container.children.items():
                if short_name in taken:
                    continue
                taken.add(short_name)
                record_subtree(short_node, (short_name,))
    else:
        # Non-DataModel library project (e.g. root `default.project.json` with `tree: { $path: "src" }`).
        record_subtree(root_node, (root_node.name,))
        for child_name, child_node in root_node.children.items():
            record_subtree(child_node, (child_name,))


def load_rojo_trees(root: Path, cfg=None) -> RojoIndex:
    """Parse configured and standard Rojo `*.project.json` trees into a `RojoIndex`."""
    root_resolved = Path(root).resolve()
    candidates: list[str] = ["default.project.json", "test/roblox/default.project.json", "test/default.project.json"]
    for key in ("test.stage", "studio.project", "lint.project"):
        val = _cfg_get(cfg, key)
        if isinstance(val, str) and val.strip():
            candidates.append(val.strip())

    index = RojoIndex()
    seen_files: set[Path] = set()
    for rel in candidates:
        proj_path = Path(rel) if os.path.isabs(rel) else (root_resolved / rel)
        try:
            resolved = proj_path.resolve()
        except OSError:
            continue
        if resolved in seen_files or not resolved.is_file():
            continue
        seen_files.add(resolved)
        if (tree := _parse_rojo_project_tree(resolved, root_resolved)) is not None:
            _index_rojo_tree(tree, index)
    return index


def _parse_instance_chain(
    tokens: list[luau_lex.Token],
    start: int,
    end: int,
    bindings: dict[str, tuple[str, list[str]]],
) -> tuple[str, list[str]] | None:
    """Parse a chain like `game:GetService("ReplicatedStorage"):WaitForChild("Foo").Bar` or `script.Parent.Baz`."""
    idx = start
    while idx < end and tokens[idx].kind == "OP" and tokens[idx].value == "(":
        close = luau_lex.matching_close(tokens, idx, "(", ")")
        if close is None or close >= end:
            break
        if close == end - 1:
            idx += 1
            end -= 1
        else:
            break

    if idx >= end or tokens[idx].kind != "IDENT":
        return None
    head = tokens[idx].value
    if head == "game":
        root_kind, parts = "game", []
        idx += 1
    elif head == "workspace":
        root_kind, parts = "game", ["Workspace"]
        idx += 1
    elif head == "script":
        root_kind, parts = "script", []
        idx += 1
    elif head in bindings:
        root_kind, base_parts = bindings[head]
        parts = list(base_parts)
        idx += 1
    elif (
        idx + 2 < end
        and tokens[idx + 1].kind == "OP"
        and tokens[idx + 1].value == "."
        and tokens[idx + 2].kind == "IDENT"
        and tokens[idx + 2].value in ("game", "workspace")
    ):
        root_kind = "game"
        parts = [] if tokens[idx + 2].value == "game" else ["Workspace"]
        idx += 3
    elif (
        idx + 3 < end
        and tokens[idx + 1].kind == "OP"
        and tokens[idx + 1].value == ":"
        and tokens[idx + 2].kind == "IDENT"
        and tokens[idx + 2].value in ("GetService", "getService", "FindService")
        and tokens[idx + 3].kind == "OP"
        and tokens[idx + 3].value == "("
    ):
        close = luau_lex.matching_close(tokens, idx + 3, "(", ")")
        if close is None or close >= end or idx + 4 >= close or tokens[idx + 4].kind != "STRING":
            return None
        svc_name = luau_lex.unquote_string(tokens[idx + 4].value)
        if svc_name is None:
            return None
        root_kind, parts = "game", [svc_name]
        idx = close + 1
    else:
        return None
    while idx < end:
        tok = tokens[idx]
        if tok.kind == "OP" and tok.value == "::":
            break
        if tok.kind == "OP" and tok.value == "." and idx + 1 < end and tokens[idx + 1].kind == "IDENT":
            parts.append(tokens[idx + 1].value)
            idx += 2
            continue
        if (
            tok.kind == "OP"
            and tok.value == "["
            and idx + 2 < end
            and tokens[idx + 1].kind == "STRING"
            and tokens[idx + 2].kind == "OP"
            and tokens[idx + 2].value == "]"
        ):
            val = luau_lex.unquote_string(tokens[idx + 1].value)
            if val is None:
                return None
            parts.append(val)
            idx += 3
            continue
        if (
            tok.kind == "OP"
            and tok.value == ":"
            and idx + 2 < end
            and tokens[idx + 1].kind == "IDENT"
            and tokens[idx + 2].kind == "OP"
            and tokens[idx + 2].value == "("
        ):
            method = tokens[idx + 1].value
            close = luau_lex.matching_close(tokens, idx + 2, "(", ")")
            if close is None or close >= end:
                return None
            arg_idx = idx + 3
            if arg_idx < close and tokens[arg_idx].kind == "STRING":
                arg_str = luau_lex.unquote_string(tokens[arg_idx].value)
                if arg_str is None:
                    return None
                if method in ("GetService", "getService", "FindService") and root_kind == "game" and not parts:
                    parts.append(arg_str)
                elif method in ("WaitForChild", "FindFirstChild"):
                    parts.append(arg_str)
                else:
                    return None
                idx = close + 1
                continue
            return None
        return None
    return root_kind, parts


def _statement_end_for_assignment(tokens: list[luau_lex.Token], start: int) -> int:
    """Find the end token index (exclusive) of a simple RHS chain expression starting at `start`."""
    n = len(tokens)
    idx = start
    depth = 0
    while idx < n:
        tok = tokens[idx]
        if tok.kind == "OP":
            if tok.value in ("(", "[", "{"):
                depth += 1
            elif tok.value in (")", "]", "}"):
                if depth == 0:
                    break
                depth -= 1
            elif depth == 0 and tok.value in (";", ","):
                break
        elif depth == 0 and tok.kind == "KEYWORD":
            break
        elif depth == 0 and idx > start:
            prev = tokens[idx - 1]
            # Stop at a new statement on the next line unless continuing with `.`, `:`, `[`, `(`
            if tok.line > prev.end_line and not (
                (prev.kind == "OP" and prev.value in (".", ":", "::"))
                or (tok.kind == "OP" and tok.value in (".", ":", "[", "(", "::"))
            ):
                break
            # Same-line adjacent identifiers/calls mean the RHS finished (e.g. `local a = script.Parent local b = ...`)
            if prev.kind in ("IDENT", "STRING") or (prev.kind == "OP" and prev.value in (")", "]")):
                if tok.kind in ("IDENT", "KEYWORD", "NUMBER", "STRING"):
                    break
        idx += 1
    return idx


def extract_requires(source: str) -> tuple[list[str], list[tuple[str, list[str]]]]:
    """Extract `(string_requires, instance_chain_requires)` from Luau `source` via `luau_lex.tokenize`."""
    tokens = luau_lex.tokenize(source, include_comments=False)
    in_type = luau_lex.mark_type_tokens(tokens)
    n = len(tokens)
    str_reqs: list[str] = []
    chain_reqs: list[tuple[str, list[str]]] = []
    bindings: dict[str, tuple[str, list[str]]] = {}

    i = 0
    while i < n:
        tok = tokens[i]
        if in_type[i]:
            i += 1
            continue

        # Track simple `local X [: Type] = <chain>` bindings for `ReplicatedStorage:WaitForChild(...)` chains.
        if tok.kind == "KEYWORD" and tok.value in ("local", "const") and i + 1 < n and tokens[i + 1].kind == "IDENT":
            var_name = tokens[i + 1].value
            j = i + 2
            # Advance past optional type annotation `: ...` until `=` or statement boundary
            if j < n and tokens[j].kind == "OP" and tokens[j].value == ":":
                depth = 0
                j += 1
                while j < n:
                    t = tokens[j]
                    if t.kind == "OP":
                        if t.value in ("(", "[", "{") or (t.value == "<" and t.is_type_angle):
                            depth += 1
                        elif t.value in (")", "]", "}") or (t.value == ">" and t.is_type_angle):
                            depth = max(0, depth - 1)
                        elif depth == 0 and t.value in ("=", ";"):
                            break
                    elif depth == 0 and t.kind == "KEYWORD":
                        break
                    j += 1
            if j < n and tokens[j].kind == "OP" and tokens[j].value == "=":
                rhs_start = j + 1
                rhs_end = _statement_end_for_assignment(tokens, rhs_start)
                if rhs_end > rhs_start:
                    # Only record simple chains (not `require(...)` calls on RHS)
                    if not (tokens[rhs_start].kind == "IDENT" and tokens[rhs_start].value == "require"):
                        parsed = _parse_instance_chain(tokens, rhs_start, rhs_end, bindings)
                        if parsed is not None:
                            bindings[var_name] = parsed
                        else:
                            bindings.pop(var_name, None)

        if tok.kind == "IDENT" and tok.value == "require":
            prev = tokens[i - 1] if i > 0 else None
            nxt = tokens[i + 1] if i + 1 < n else None
            is_member = prev is not None and prev.kind == "OP" and prev.value == "."
            is_method_def = False
            if prev is not None and prev.kind == "OP" and prev.value == ":":
                scan = i - 2
                while scan >= 0 and tokens[scan].kind == "IDENT":
                    if scan >= 2 and tokens[scan - 1].kind == "OP" and tokens[scan - 1].value == ".":
                        scan -= 2
                    else:
                        if scan > 0 and tokens[scan - 1].kind == "KEYWORD" and tokens[scan - 1].value == "function":
                            is_method_def = True
                        break
            is_def = is_method_def or (prev is not None and prev.kind == "KEYWORD" and prev.value == "function")
            is_assign = nxt is not None and nxt.kind == "OP" and nxt.value == "="
            if not is_member and not is_def and not is_assign and nxt is not None:
                if nxt.kind == "STRING":
                    if (lit := luau_lex.unquote_string(nxt.value)) is not None:
                        str_reqs.append(lit)
                    i += 2
                    continue
                if nxt.kind == "OP" and nxt.value == "(":
                    close = luau_lex.matching_close(tokens, i + 1, "(", ")")
                    if close is not None and close > i + 2:
                        if close == i + 3 and tokens[i + 2].kind == "STRING":
                            if (lit := luau_lex.unquote_string(tokens[i + 2].value)) is not None:
                                str_reqs.append(lit)
                        else:
                            if (parsed := _parse_instance_chain(tokens, i + 2, close, bindings)) is not None:
                                chain_reqs.append(parsed)
                        i = close + 1
                        continue
                # Handle `pcall(require, ...)`
                if (
                    prev is not None
                    and prev.kind == "OP"
                    and prev.value == ","
                    and nxt.kind == "OP"
                    and nxt.value == ","
                    and i + 2 < n
                ):
                    arg_start = i + 2
                    if tokens[arg_start].kind == "STRING":
                        if (lit := luau_lex.unquote_string(tokens[arg_start].value)) is not None:
                            str_reqs.append(lit)
                        i = arg_start + 1
                        continue
                    # Find closing `,` or `)` of outer `pcall(...)`
                    depth = 0
                    arg_end = arg_start
                    while arg_end < n:
                        t = tokens[arg_end]
                        if t.kind == "OP":
                            if t.value in ("(", "[", "{"):
                                depth += 1
                            elif t.value in (")", "]", "}"):
                                if depth == 0:
                                    break
                                depth -= 1
                            elif t.value == "," and depth == 0:
                                break
                        arg_end += 1
                    if arg_end > arg_start:
                        if (parsed := _parse_instance_chain(tokens, arg_start, arg_end, bindings)) is not None:
                            chain_reqs.append(parsed)
                        i = arg_end
                        continue
        i += 1

    return str_reqs, chain_reqs


@dataclass
class DependencyGraph:
    root: Path
    forward: dict[str, set[str]] = field(default_factory=dict)
    reverse: dict[str, set[str]] = field(default_factory=dict)
    rojo: RojoIndex = field(default_factory=RojoIndex)

    def add_edge(self, src_rel: str, dst_rel: str) -> None:
        if not src_rel or not dst_rel or src_rel == dst_rel:
            return
        self.forward.setdefault(src_rel, set()).add(dst_rel)
        self.reverse.setdefault(dst_rel, set()).add(src_rel)

    def dependents(self, rel_file: str, *, transitive: bool = True) -> set[str]:
        norm_file = _norm_rel(rel_file, self.root)
        if not transitive:
            return set(self.reverse.get(norm_file, ()))
        visited: set[str] = set()
        stack = list(self.reverse.get(norm_file, ()))
        while stack:
            cur = stack.pop()
            if cur in visited:
                continue
            visited.add(cur)
            stack.extend(self.reverse.get(cur, ()))
        return visited

    def dependencies(self, rel_file: str, *, transitive: bool = True) -> set[str]:
        norm_file = _norm_rel(rel_file, self.root)
        if not transitive:
            return set(self.forward.get(norm_file, ()))
        visited: set[str] = set()
        stack = list(self.forward.get(norm_file, ()))
        while stack:
            cur = stack.pop()
            if cur in visited:
                continue
            visited.add(cur)
            stack.extend(self.forward.get(cur, ()))
        return visited


def _resolve_string_require(
    from_file: Path,
    spec_str: str,
    root_resolved: Path,
    aliases: dict[str, Path],
    rojo: RojoIndex,
) -> str | None:
    spec = spec_str.replace("\\", "/").strip()
    if not spec:
        return None
    if spec == "@self":
        return _rel_if_inside(from_file, root_resolved)
    if spec.startswith("@self/"):
        sub = spec[len("@self/") :]
        base_dir = from_file.parent if from_file.name in INIT_NAME_SET else from_file.with_suffix("")
        resolved = _resolve_module_path(Path(os.path.normpath(base_dir / sub)), root_resolved)
        if resolved is None and from_file.name not in INIT_NAME_SET:
            resolved = _resolve_module_path(Path(os.path.normpath(from_file.parent / sub)), root_resolved)
        return resolved
    if spec.startswith("@game/"):
        sub_parts = [p for p in spec[len("@game/") :].split("/") if p]
        if hit := rojo.resolve_path(sub_parts):
            return hit
        # Fall back to `@game` alias in `.luaurc` only when not pointing into generated `.sert/stage/game`
        game_alias = next((v for k, v in aliases.items() if k.lower() == "game"), None)
        if game_alias is not None and _is_inside_root(game_alias, root_resolved):
            return _resolve_module_path(Path(os.path.normpath(game_alias / "/".join(sub_parts))), root_resolved)
        return None
    if spec.startswith("@"):
        body = spec[1:]
        alias_name, _, sub = body.partition("/")
        alias_target = aliases.get(alias_name) or next(
            (v for k, v in aliases.items() if k.lower() == alias_name.lower()),
            None,
        )
        if alias_target is None:
            return None
        cand = alias_target / sub if sub else alias_target
        return _resolve_module_path(Path(os.path.normpath(cand)), root_resolved)
    if spec.startswith(("./", "../")) or spec in (".", ".."):
        is_init = from_file.name in INIT_NAME_SET
        anchor = from_file.parent if (not is_init or from_file.parent == root_resolved) else from_file.parent.parent
        return _resolve_module_path(Path(os.path.normpath(anchor / spec)), root_resolved)
    return None


def _resolve_chain_require(
    from_file: Path,
    from_rel: str,
    chain: tuple[str, list[str]],
    root_resolved: Path,
    rojo: RojoIndex,
) -> str | None:
    root_kind, parts = chain
    if root_kind == "game":
        return rojo.resolve_path(parts)
    if root_kind == "script":
        if hit := rojo.resolve_script_relative(from_rel, parts):
            return hit
        is_init = from_file.name in INIT_NAME_SET
        cur: Path = from_file.parent if is_init else from_file
        for idx, step in enumerate(parts):
            if step == "Parent":
                cur = cur.parent
            else:
                # If starting from a non-init file without hitting Parent first, `script.Child` is only Rojo-tree based
                if idx == 0 and not is_init:
                    return None
                cur = cur / step
        if not _is_inside_root(cur, root_resolved):
            return None
        return _resolve_module_path(cur, root_resolved)
    return None


def _iter_luau_files(root_resolved: Path) -> list[Path]:
    found: list[Path] = []
    for cur, dirs, files in os.walk(root_resolved):
        dirs[:] = sorted(d for d in dirs if d not in _SKIP_DIRS)
        cur_path = Path(cur)
        for name in sorted(files):
            if name.endswith((".luau", ".lua")):
                path = cur_path / name
                if path.is_file() and not path.is_symlink():
                    found.append(path)
    return found


def _load_graph_cache(root: Path) -> dict[str, dict]:
    data = load_json(root / GRAPH_CACHE_REL)
    if (
        not isinstance(data, dict)
        or data.get("version") != _GRAPH_CACHE_VERSION
        or not isinstance(data.get("files"), dict)
    ):
        return {}
    return data["files"]


def _save_graph_cache(root: Path, files_cache: dict[str, dict]) -> None:
    payload = {"version": _GRAPH_CACHE_VERSION, "files": files_cache}
    try:
        write_atomic(root / GRAPH_CACHE_REL, (json.dumps(payload, separators=(",", ":"), sort_keys=True) + "\n").encode("utf-8"))
    except OSError:
        pass


def build_graph(
    root: Path,
    cfg=None,
    files: list[Path] | None = None,
    *,
    use_cache: bool = True,
) -> DependencyGraph:
    """Build forward and reverse static Luau module dependency edges across `root`."""
    root_resolved = Path(root).resolve()
    rojo = load_rojo_trees(root_resolved, cfg)
    graph = DependencyGraph(root=root_resolved, rojo=rojo)
    alias_cache: dict[Path, dict[str, Path]] = {}

    files_cache = _load_graph_cache(root_resolved) if use_cache else {}
    cache_dirty = False
    seen_rels: set[str] = set()

    luau_files = _iter_luau_files(root_resolved) if files is None else [Path(f).resolve() for f in files]
    for file_path in luau_files:
        rel = _rel_if_inside(file_path, root_resolved)
        if rel is None:
            continue
        seen_rels.add(rel)
        graph.forward.setdefault(rel, set())
        graph.reverse.setdefault(rel, set())

        str_reqs: list[str]
        chain_reqs: list[tuple[str, list[str]]]
        cached = files_cache.get(rel) if use_cache else None
        st = None
        if use_cache:
            try:
                st = file_path.stat()
            except OSError:
                continue
        if (
            isinstance(cached, dict)
            and st is not None
            and cached.get("mtime_ns") == st.st_mtime_ns
            and cached.get("size") == st.st_size
            and isinstance(cached.get("str_reqs"), list)
            and isinstance(cached.get("chain_reqs"), list)
        ):
            str_reqs = [str(r) for r in cached["str_reqs"]]
            chain_reqs = [
                (str(c[0]), [str(p) for p in c[1]])
                for c in cached["chain_reqs"]
                if isinstance(c, (list, tuple)) and len(c) == 2 and isinstance(c[1], (list, tuple))
            ]
        else:
            try:
                source = file_path.read_text(encoding="utf-8", errors="replace")
            except OSError:
                continue
            str_reqs, chain_reqs = extract_requires(source)
            if use_cache and st is not None:
                files_cache[rel] = {
                    "mtime_ns": st.st_mtime_ns,
                    "size": st.st_size,
                    "str_reqs": list(str_reqs),
                    "chain_reqs": [[rk, list(parts)] for rk, parts in chain_reqs],
                }
                cache_dirty = True

        if not str_reqs and not chain_reqs:
            continue
        if str_reqs:
            folder = file_path.parent
            if folder not in alias_cache:
                alias_cache[folder] = load_luaurc_aliases(root_resolved, folder)
            aliases = alias_cache[folder]
            for req_lit in str_reqs:
                if dst := _resolve_string_require(file_path, req_lit, root_resolved, aliases, rojo):
                    graph.add_edge(rel, dst)
        for chain in chain_reqs:
            if dst := _resolve_chain_require(file_path, rel, chain, root_resolved, rojo):
                graph.add_edge(rel, dst)

    if use_cache and files is None and files_cache:
        stale_keys = [k for k in files_cache if k not in seen_rels]
        for stale in stale_keys:
            files_cache.pop(stale, None)
            cache_dirty = True
    if use_cache and cache_dirty:
        _save_graph_cache(root_resolved, files_cache)

    return graph


def load_coverage_map(root: Path) -> dict:
    """Load `.sert/coverage-map.json`, returning an empty v1 structure if missing or invalid."""
    path = Path(root) / COVERAGE_MAP_REL
    data = load_json(path)
    if not isinstance(data, dict) or data.get("version") != 1 or not isinstance(data.get("specs"), dict):
        return {"version": 1, "specs": {}}
    return data


def save_coverage_map(root: Path, data: dict) -> Path:
    """Atomically persist `.sert/coverage-map.json`."""
    path = Path(root) / COVERAGE_MAP_REL
    payload = (json.dumps(data, indent=2, sort_keys=True) + "\n").encode("utf-8")
    write_atomic(path, payload)
    return path


def _file_sha256(path: Path) -> str:
    try:
        return hashlib.sha256(path.read_bytes()).hexdigest()
    except OSError:
        return ""


def record_specs_coverage(root: Path, updates: list[tuple[str, dict, int, bool]]) -> dict:
    """Batch-update `.sert/coverage-map.json` for multiple `(spec_rel, cov_files, ms, exact)` entries."""
    root_path = Path(root)
    cov_map = load_coverage_map(root_path)
    for spec_rel, cov_files, ms, exact in updates:
        norm_spec = _norm_rel(spec_rel, root_path)
        norm_files: dict[str, list[int]] = {}
        for src_name, raw_lines in cov_files.items():
            src_rel = _norm_rel(src_name, root_path)
            if not src_rel or src_rel.startswith(("/", "../")) or (len(src_rel) >= 2 and src_rel[1] == ":"):
                continue
            if isinstance(raw_lines, dict):
                hits = sorted({int(ln) for ln, hit in raw_lines.items() if hit})
            else:
                hits = sorted({int(ln) for ln in raw_lines})
            if hits:
                existing_hits = norm_files.get(src_rel)
                norm_files[src_rel] = sorted(set(existing_hits) | set(hits)) if existing_hits is not None else hits

        cur_sha = _file_sha256(root_path / norm_spec)
        prev_entry = cov_map["specs"].get(norm_spec)
        if (
            not exact
            and isinstance(prev_entry, dict)
            and prev_entry.get("exact") is not False
            and isinstance(prev_entry.get("files"), dict)
            and prev_entry.get("sha256") == cur_sha
        ):
            prev_entry["ms"] = max(0, int(round(ms)))
            continue
        spec_entry: dict = {
            "ms": max(0, int(round(ms))),
            "sha256": cur_sha,
            "files": norm_files,
        }
        if not exact:
            spec_entry["exact"] = False
        cov_map["specs"][norm_spec] = spec_entry
    save_coverage_map(root_path, cov_map)
    return cov_map


def record_spec_coverage(root: Path, spec_rel: str, cov_files: dict, ms: int, *, exact: bool = True) -> dict:
    """Update `.sert/coverage-map.json` for `spec_rel` from LCOV coverage (`cov_files`) and duration `ms`."""
    return record_specs_coverage(root, [(spec_rel, cov_files, ms, exact)])


def discover_specs(root: Path, cfg=None) -> list[str]:
    """Discover project spec files as sorted POSIX relative paths."""
    root_path = Path(root)
    patterns = [str(p) for p in as_list(_cfg_get(cfg, "test.specs"))]
    if not patterns:
        found_default = expand_globs(root_path, list(DEFAULT_SPEC_GLOBS), files=True)
        if found_default:
            return [posix(p, root_path) for p in found_default]
        patterns = [str(p) for p in as_list(_cfg_get(cfg, "test.entries"))]
    if not patterns:
        return []
    expanded: list[str] = []
    for pat in patterns:
        if "*" not in pat and "?" not in pat and "[" not in pat and (root_path / pat).is_dir():
            expanded.append(pat.rstrip("/") + "/**/*.spec.luau")
        else:
            expanded.append(pat)
    return [posix(p, root_path) for p in expand_globs(root_path, expanded, files=True)]


def _is_global_config_change(rel_file: str, cfg=None) -> bool:
    name = Path(rel_file).name
    if name in GLOBAL_INVALIDATION_NAMES or rel_file.endswith(".project.json"):
        return True
    setup = _cfg_get(cfg, "test.setup")
    if isinstance(setup, str) and setup.strip():
        norm_setup = setup.strip().replace("\\", "/").removeprefix("./")
        if rel_file == norm_setup:
            return True
    return False


def _specs_for_meta_change(
    mod_file: str,
    dep_graph: DependencyGraph,
    specs_cov: dict[str, dict],
    all_spec_set: set[str],
) -> set[str]:
    targets: set[str] = set()
    known_files = set(dep_graph.forward) | all_spec_set
    if Path(mod_file).name == "init.meta.json":
        dir_prefix = mod_file[: -len("init.meta.json")]
        for cand in known_files:
            if not dir_prefix or cand.startswith(dir_prefix):
                targets.add(cand)
    else:
        stem = mod_file[: -len(".meta.json")]
        init_prefix = f"{stem}/init."
        for cand in known_files:
            if cand.startswith(f"{stem}.") or cand.startswith(init_prefix):
                targets.add(cand)

    hit: set[str] = set()
    for target in targets:
        if target in all_spec_set:
            hit.add(target)
        hit.update(dep_graph.dependents(target, transitive=True) & all_spec_set)
        for norm_spec, spec_entry in specs_cov.items():
            if norm_spec not in all_spec_set:
                continue
            files_map = spec_entry.get("files")
            if isinstance(files_map, dict) and files_map.get(target):
                hit.add(norm_spec)
    return hit


def affected_specs_for_files(
    root: Path,
    cfg=None,
    modified_files: set[str] | list[str] | tuple[str, ...] = (),
    *,
    diff_lines: dict[str, set[int]] | None = None,
    all_specs: list[str] | None = None,
    dep_graph: DependencyGraph | None = None,
    cov_map: dict | None = None,
) -> list[str]:
    """Return sorted impacted spec files for an explicit set of changed repository files."""
    root_path = Path(root)
    specs_raw = discover_specs(root_path, cfg) if all_specs is None else list(all_specs)
    all_spec_set = {_norm_rel(s, root_path) for s in specs_raw}
    mod_set = {_norm_rel(f, root_path) for f in modified_files}
    if not mod_set:
        return []

    if any(_is_global_config_change(f, cfg) for f in mod_set):
        return sorted(all_spec_set)

    graph = build_graph(root_path, cfg) if dep_graph is None else dep_graph
    loaded_cov_map = load_coverage_map(root_path) if cov_map is None else cov_map
    raw_specs_cov = loaded_cov_map.get("specs") if isinstance(loaded_cov_map.get("specs"), dict) else {}
    specs_cov = {_norm_rel(k, root_path): v for k, v in raw_specs_cov.items() if isinstance(v, dict)}
    norm_diff_lines = (
        {_norm_rel(k, root_path): v for k, v in diff_lines.items()} if diff_lines is not None else {}
    )

    snap_lookup: dict[str, list[str]] | None = None
    affected: set[str] = set()
    for mod_file in mod_set:
        if mod_file.endswith(".snap"):
            if snap_lookup is None:
                from sert import snapshots as snapshots_mod

                snap_lookup = {}
                for spec in all_spec_set:
                    snap_rel = _norm_rel(snapshots_mod.snapshot_path_for(root_path, spec), root_path)
                    snap_lookup.setdefault(snap_rel, []).append(spec)
            affected.update(snap_lookup.get(mod_file, ()))
            continue

        if mod_file.endswith(".meta.json"):
            affected.update(_specs_for_meta_change(mod_file, graph, specs_cov, all_spec_set))
            continue

        if mod_file in all_spec_set:
            affected.add(mod_file)
        affected.update(graph.dependents(mod_file, transitive=True) & all_spec_set)
        mod_line_set = norm_diff_lines.get(mod_file) if diff_lines is not None else None
        for norm_spec, spec_entry in specs_cov.items():
            if norm_spec not in all_spec_set:
                continue
            files_map = spec_entry.get("files")
            if not isinstance(files_map, dict):
                continue
            covered_lines = files_map.get(mod_file)
            if isinstance(covered_lines, list) and covered_lines and (
                not mod_line_set or bool(set(covered_lines) & mod_line_set)
            ):
                affected.add(norm_spec)

    return sorted(affected)


def affected_specs(
    root: Path,
    cfg=None,
    base_rev: str = "HEAD",
    all_specs: list[str] | None = None,
    *,
    diff_lines: dict[str, set[int]] | None = None,
    dep_graph: DependencyGraph | None = None,
    cov_map: dict | None = None,
) -> tuple[list[str], set[str]]:
    """Return `(sorted_affected_specs, modified_files)` via hybrid static + dynamic TIA."""
    root_path = Path(root)
    resolved_diff = coverage_mod.git_diff_lines(root_path, base_rev) if diff_lines is None else diff_lines
    modified_files = {_norm_rel(f, root_path) for f in resolved_diff}
    if not modified_files:
        return [], set()
    affected = affected_specs_for_files(
        root_path,
        cfg,
        modified_files,
        diff_lines=resolved_diff,
        all_specs=all_specs,
        dep_graph=dep_graph,
        cov_map=cov_map,
    )
    return affected, modified_files


def covering_specs_for_line(
    root: Path,
    cfg,
    rel_file: str,
    line: int,
    all_specs: list[str],
    *,
    cov_map: dict | None = None,
    dep_graph: DependencyGraph | None = None,
) -> list[str]:
    """Return specs covering `(rel_file, line)` via coverage map + reverse static graph, fastest (`ms`) first."""
    root_path = Path(root)
    target_file = _norm_rel(rel_file, root_path)
    spec_norms: list[str] = []
    seen_specs: set[str] = set()
    for s in all_specs:
        ns = _norm_rel(s, root_path)
        if ns not in seen_specs:
            seen_specs.add(ns)
            spec_norms.append(ns)
    spec_set = set(spec_norms)

    cov_map = load_coverage_map(root_path) if cov_map is None else cov_map
    raw_specs_cov = cov_map.get("specs") if isinstance(cov_map.get("specs"), dict) else {}
    specs_cov = {_norm_rel(k, root_path): v for k, v in raw_specs_cov.items() if isinstance(v, dict)}
    exact_hits: set[str] = set()

    # 1. Exact dynamic `(rel_file, line)` hits from `.sert/coverage-map.json`
    for norm_spec, spec_entry in specs_cov.items():
        if norm_spec not in spec_set:
            continue
        files_map = spec_entry.get("files")
        if not isinstance(files_map, dict):
            continue
        covered_lines = files_map.get(target_file)
        if isinstance(covered_lines, list) and line in covered_lines:
            exact_hits.add(norm_spec)

    # 2. Reverse static import edges (transitive dependents)
    graph = build_graph(root_path, cfg) if dep_graph is None else dep_graph
    hits: set[str] = set(exact_hits)
    if target_file in spec_set:
        hits.add(target_file)
    hits.update(graph.dependents(target_file, transitive=True) & spec_set)

    def sort_key(spec_rel: str) -> tuple[int, int, int, str]:
        entry = specs_cov.get(spec_rel)
        is_exact = 0 if spec_rel in exact_hits else 1
        if isinstance(entry, dict) and isinstance(entry.get("ms"), (int, float)) and not isinstance(entry.get("ms"), bool):
            return (0, int(entry["ms"]), is_exact, spec_rel)
        return (1, sys.maxsize, is_exact, spec_rel)

    return sorted(hits, key=sort_key)
