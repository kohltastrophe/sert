"""sert.toml loading: `<root>/sert.toml` deep-merged with the optional, gitignored `<root>/sert.local.toml`."""

from __future__ import annotations

import copy
import difflib
import os
from pathlib import Path
import subprocess
import tomllib

from sert.util import SertError, command

CONFIG = "sert.toml"
LOCAL = "sert.local.toml"


def _git_toplevel(start: Path) -> Path | None:
    try:
        result = subprocess.run(
            ["git", "-C", str(start), "rev-parse", "--show-toplevel"],
            capture_output=True,
            text=True,
            encoding="utf-8",
            errors="replace",
            timeout=5,
        )
    except (OSError, subprocess.SubprocessError):
        return None
    top = result.stdout.strip() if result.returncode == 0 else ""
    return Path(top).resolve() if top else None


def root_of(path: str | os.PathLike | None = None) -> Path:
    where = Path(path or os.getcwd()).resolve()
    start = where if where.is_dir() else where.parent
    if top := _git_toplevel(start):
        return top
    for parent in (start, *start.parents):
        if (parent / CONFIG).is_file():
            return parent
    return where


def find_root(explicit: str | os.PathLike | None = None) -> Path:
    if explicit:
        return Path(explicit).resolve()
    if env := os.environ.get("SERT_ROOT"):
        return Path(env).resolve()
    return root_of(None)


def merge(base: dict, over: dict) -> dict:
    out = copy.deepcopy(base)
    for key, value in over.items():
        out[key] = (
            merge(out[key], value)
            if isinstance(value, dict) and isinstance(out.get(key), dict)
            else copy.deepcopy(value)
        )
    return out


def read_toml(path: Path) -> dict:
    try:
        return tomllib.loads(path.read_text(encoding="utf-8-sig"))
    except (tomllib.TOMLDecodeError, UnicodeDecodeError) as err:
        raise SertError(f"{path}: {err}") from err


class Config(dict):
    def __init__(self, root: Path, data: dict, shared: dict, exists: bool):
        super().__init__(data)
        self.root, self.shared, self.exists = root, shared, exists

    def get(self, dotted: str, default=None):
        if dotted in self:
            return dict.__getitem__(self, dotted)
        node = self
        for part in dotted.split("."):
            if not isinstance(node, dict) or part not in node:
                return default
            node = node[part]
        return node

    def table(self, dotted: str) -> dict:
        value = self.get(dotted, {})
        if not isinstance(value, dict):
            raise SertError(f"{CONFIG}: [{dotted}] must be a table")
        return value

    @property
    def overrides(self) -> dict[str, Path]:
        return {name: (self.root / str(value)).resolve() for name, value in self.table("override").items()}


ANY = "any"
STUDIO_KEYS = {
    "out": str,
    "project": str,
    "mode": (list, str),
    "specs": (list, str),
    "runner": (list, str),
    "config": (list, str),
    "hooks": str,
    "timeout": (int, float),
    "launcher": str,
    "list_command": (list, str),
    "sides": (list, str),
    "drift": [{"dir": str, "project": str, "tree": list}],
    "run_level": str,
    "device": str,
    "clients": int,
    "warm": bool,
    "studio": str,
    "capture": (bool, str),
}
GROUP_KEYS = {"name", "paths", "ignore", "platform", "defs", "definitions", "sourcemap", "solvers"}
SCHEMA = {
    "sert": {"version", "repo"},
    "override": {"*": str},
    "release": ANY,
    "test": {
        "entries": (list, str),
        "specs": (list, str),
        "setup": str,
        "runner": str,
        "codegen": bool,
        "stage": str,
        "jobs": int,
        "globals": str,
        "allow_focused": bool,
        "timeout": (int, float),
        "repeat": int,
        "slowest": int,
    },
    "studio": {**STUDIO_KEYS, "suites": {"*": {**STUDIO_KEYS, "default": bool}}},
    "cloud": {
        "project": str,
        "script": str,
        "specs": (list, str),
        "shards": list,
        "shard_limit": (int, float),
        "jobs": int,
        "max_workers": int,
        "timeout": (int, float),
    },
    "lint": {
        "paths": (list, str),
        "project": (str, bool),
        "solvers": (list, str),
        "ignore": (list, str),
        "selene": bool,
        "stylua": bool,
        "stub": bool,
        "extra": list,
        "analyze": [GROUP_KEYS, dict],
    },
    "types": {"pass": (list, str), "fail": (list, str), "solvers": (list, str)},
    "coverage": {
        "include": (list, str),
        "exclude": (list, str),
        "min": (int, float),
        "badge": (bool, str),
    },
    "mutate": {
        "include": (list, str),
        "exclude": (list, str),
        "timeout": (int, float),
        "min": (int, float),
        "max_mutants": int,
        "jobs": int,
        "operators": (list, str),
        "benign_calls": (list, str),
        "cosmetic_props": (list, str),
        "specs": {"*": str},
    },
}


def schema() -> dict:
    return dict(SCHEMA)


TYPE_NAMES = {
    bool: "true or false",
    str: "a string",
    int: "an integer",
    float: "a number",
    list: "an array",
    dict: "a table",
}


def _describe(value) -> str:
    if isinstance(value, str):
        return f'the string "{value}"'
    if isinstance(value, bool):
        return str(value).lower()
    if isinstance(value, (int, float)):
        return f"the number {value!r}"
    return TYPE_NAMES.get(type(value), type(value).__name__)


def _has_type(value, types: tuple) -> bool:
    return any(isinstance(value, kind) and not (kind in (int, float) and isinstance(value, bool)) for kind in types)


def _check(node, value, where: str, problems: list[str]) -> None:
    if node is None or node == ANY:
        return
    if isinstance(node, (type, tuple)):
        types = node if isinstance(node, tuple) else (node,)
        if not _has_type(value, types):
            table, _, key = where.rpartition(".")
            wanted = " or ".join(TYPE_NAMES[kind] for kind in types if not (kind is int and float in types))
            problems.append(f"[{table}].{key} must be {wanted}, not {_describe(value)}")
        return
    if isinstance(node, list):
        if isinstance(value, dict) and dict in node:
            _check(node[0], value, where, problems)
            return
        if not isinstance(value, list):
            table, _, key = where.rpartition(".")
            target = f"[{table}].{key}" if table else f"[{key}]"
            kind = "a table" if dict in node else "a list of tables"
            problems.append(f"{target} must be {kind}, not {_describe(value)}")
            return
        for index, item in enumerate(value, 1):
            if isinstance(item, dict):
                _check(node[0], item, f"{where} #{index}", problems)
            else:
                problems.append(f"[{where} #{index}] must be a table, not {_describe(item)}")
        return
    if not isinstance(value, dict):
        table, _, key = where.rpartition(".")
        target = f"[{table}].{key}" if table else f"[{key}]"
        problems.append(f"{target} must be a table, not {_describe(value)}")
        return
    known = node if isinstance(node, (set, frozenset)) else set(node)
    for key, child in value.items():
        if key in known:
            child_schema = node.get(key) if isinstance(node, dict) else None
        elif "*" in known:
            child_schema = node.get("*") if isinstance(node, dict) else None
        else:
            name = f"[{where}].{key}" if where else f"[{key}]"
            close = difflib.get_close_matches(key, sorted(k for k in known if k != "*"), n=1, cutoff=0.6)
            problems.append(
                f"unknown {'key' if where else 'table'} {name}"
                + (f" (did you mean `{close[0]}`?)" if close else "")
            )
            continue
        _check(child_schema, child, f"{where}.{key}" if where else key, problems)


def problems_in(data: dict, rules: dict | None = None) -> list[str]:
    problems: list[str] = []
    _check(rules if rules is not None else schema(), data, "", problems)
    return problems


def validate(data: dict, path: Path) -> None:
    if problems := problems_in(data):
        raise SertError(f"{path.name}: " + "; ".join(problems))


def load(root: str | os.PathLike | None = None, require: bool = False) -> Config:
    root_path = find_root(root)
    shared_path, local_path = root_path / CONFIG, root_path / LOCAL
    exists = shared_path.is_file()
    if require and not exists:
        raise SertError(f"no {CONFIG} in {root_path} (run `{command('init')}`)")
    shared = read_toml(shared_path) if exists else {}
    local = read_toml(local_path) if local_path.is_file() else {}
    validate(shared, shared_path)
    validate(local, local_path)
    return Config(root_path, merge(shared, local), shared, exists)


def from_args(args, require: bool = False) -> Config:
    return load(getattr(args, "root", None), require=require)
