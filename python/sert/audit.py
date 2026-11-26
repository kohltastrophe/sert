"""Anti-reward-hacking quality audit and uncovered export radar for sert."""

from __future__ import annotations

import argparse
from dataclasses import dataclass
import io
import math
import os
from pathlib import Path
import re
import sys

from sert import agent
from sert import config as config_mod
from sert import coverage as coverage_mod
from sert import graph as graph_mod
from sert import luau_lex
from sert import markers as markers_mod
from sert import run as run_mod
from sert import util

_EQ_METHODS = frozenset({"eq", "equals", "equal", "deepEq", "deepEqual", "strictEq"})
_NE_METHODS = frozenset({"ne", "notEq", "notEqual"})
_OK_METHODS = frozenset({"ok", "truthy"})
_ASSERT_RECEIVERS = frozenset({"sert", "t", "expect", "assert"})
_THROWS_METHODS = frozenset({"throws", "throwsAsync", "rejects"})
_DOES_NOT_THROW_METHODS = frozenset({"doesNotThrow", "notThrows"})
_REMOTE_EVENT_TOKENS = frozenset({"fuzzRemote", "remotePayload", "FireServer", "OnServerEvent"})
_REMOTE_INVOKE_TOKENS = frozenset({"fuzzRemote", "remotePayload", "InvokeServer", "OnServerInvoke"})
_REMOTE_COVER_TOKENS = _REMOTE_EVENT_TOKENS | _REMOTE_INVOKE_TOKENS
_GENERIC_NAMES = frozenset({"remote", "event", "func", "function", "rf", "re", "self", "script", "remotes"})
_REQ_TAIL_RE = re.compile(r"([A-Za-z0-9_.-]+)$")
_EXPORT_LINE_RE = re.compile(r"^(.*?)(?::L\d+-L\d+)?$")


@dataclass(slots=True)
class ExportSpan:
    """Source span of an exported Luau module function."""

    name: str
    file: str
    start_line: int
    end_line: int

    @property
    def span(self) -> str:
        return f"{self.file}:L{self.start_line}-L{self.end_line}"

    def to_dict(self) -> dict[str, object]:
        return {
            "name": self.name,
            "file": self.file,
            "start_line": self.start_line,
            "end_line": self.end_line,
            "span": self.span,
        }


def _sig_tokens(source: str) -> list[luau_lex.Token]:
    return [tok for tok in luau_lex.tokenize(source, include_comments=False) if tok.kind != "COMMENT"]


def _split_call_args(tokens: list[luau_lex.Token], open_idx: int, close_idx: int) -> list[list[luau_lex.Token]]:
    args: list[list[luau_lex.Token]] = []
    cur: list[luau_lex.Token] = []
    paren = bracket = brace = 0
    for tok in tokens[open_idx + 1 : close_idx]:
        if tok.kind == "OP":
            if tok.value == "(":
                paren += 1
            elif tok.value == ")":
                paren = max(0, paren - 1)
            elif tok.value == "[":
                bracket += 1
            elif tok.value == "]":
                bracket = max(0, bracket - 1)
            elif tok.value == "{":
                brace += 1
            elif tok.value == "}":
                brace = max(0, brace - 1)
            elif tok.value == "," and paren == 0 and bracket == 0 and brace == 0:
                args.append(cur)
                cur = []
                continue
        cur.append(tok)
    if cur or args:
        args.append(cur)
    return args


def _strip_outer_parens(expr: list[luau_lex.Token]) -> list[luau_lex.Token]:
    out = list(expr)
    while len(out) >= 2 and out[0].kind == "OP" and out[0].value == "(":
        close = luau_lex.matching_close(out, 0)
        if close == len(out) - 1:
            out = out[1:-1]
        else:
            break
    return out


def _expr_sig(expr: list[luau_lex.Token]) -> tuple[tuple[str, str], ...]:
    stripped = _strip_outer_parens(expr)
    return tuple((tok.kind, tok.value) for tok in stripped)


def _is_nil_literal(expr: list[luau_lex.Token]) -> bool:
    stripped = _strip_outer_parens(expr)
    return len(stripped) == 1 and stripped[0].kind == "KEYWORD" and stripped[0].value == "nil"


def _is_non_nil_literal(expr: list[luau_lex.Token]) -> bool:
    stripped = _strip_outer_parens(expr)
    if not stripped:
        return False
    if len(stripped) == 1:
        tok = stripped[0]
        if tok.kind in ("NUMBER", "STRING", "INTERP_FULL"):
            return True
        if tok.kind == "KEYWORD" and tok.value in ("true", "false"):
            return True
        return False
    first, last = stripped[0], stripped[-1]
    if first.kind == "INTERP_BEGIN" and last.kind == "INTERP_END":
        return True
    if first.kind == "OP" and first.value == "{" and luau_lex.matching_close(stripped, 0) == len(stripped) - 1:
        return True
    if first.kind == "KEYWORD" and first.value == "function" and last.kind == "KEYWORD" and last.value == "end":
        return True
    if first.kind == "OP" and first.value in ("-", "#"):
        return _is_non_nil_literal(stripped[1:])
    if first.kind == "KEYWORD" and first.value == "not":
        return len(stripped) > 1
    return False


def _extract_callee(tokens: list[luau_lex.Token], open_paren_idx: int) -> tuple[list[str], int] | None:
    if open_paren_idx <= 0:
        return None
    idx = open_paren_idx - 1
    if tokens[idx].kind != "IDENT":
        return None
    parts = [tokens[idx].value]
    pos = idx - 1
    while pos >= 1 and tokens[pos].kind == "OP" and tokens[pos].value in (".", ":") and tokens[pos - 1].kind == "IDENT":
        parts.append(tokens[pos - 1].value)
        pos -= 2
    if pos >= 0 and tokens[pos].kind == "KEYWORD" and tokens[pos].value == "function":
        return None
    parts.reverse()
    return parts, pos + 1


def _to_path(item: Path | str, root: Path) -> Path:
    p = item if isinstance(item, Path) else Path(item)
    return p if p.is_absolute() else (root / p)


def _has_call_token(expr: list[luau_lex.Token]) -> bool:
    for idx, tok in enumerate(expr):
        if tok.kind == "OP" and tok.value == "(" and idx > 0:
            prev = expr[idx - 1]
            if prev.kind == "IDENT" or (prev.kind == "OP" and prev.value in (")", "]", "}")):
                return True
        if tok.kind == "IDENT" and idx + 1 < len(expr):
            nxt = expr[idx + 1]
            if nxt.kind in ("STRING", "INTERP_FULL", "INTERP_BEGIN") or (nxt.kind == "OP" and nxt.value == "{"):
                return True
    return False


def _parse_luau_number(expr: list[luau_lex.Token]) -> float | None:
    stripped = _strip_outer_parens(expr)
    neg = False
    if len(stripped) == 2 and stripped[0].kind == "OP" and stripped[0].value == "-":
        neg = True
        stripped = stripped[1:]
    if len(stripped) != 1 or stripped[0].kind != "NUMBER":
        return None
    num = luau_lex.parse_number(stripped[0].value)
    if num is None:
        return None
    try:
        val = float(num)
    except OverflowError:
        return None
    if not math.isfinite(val):
        return None
    return -val if neg else val


_BINOP_OPS = frozenset({"==", "~=", "<", "<=", ">", ">=", "..", "+", "-", "*", "/", "//", "%", "^"})


def _has_top_binop(expr: list[luau_lex.Token]) -> bool:
    depth = 0
    for i, tok in enumerate(expr):
        if tok.kind == "INTERP_BEGIN":
            depth += 1
        elif tok.kind == "INTERP_END":
            depth = max(0, depth - 1)
        elif tok.kind == "OP" and not tok.is_type_angle:
            if tok.value in ("(", "[", "{"):
                depth += 1
            elif tok.value in (")", "]", "}"):
                depth = max(0, depth - 1)
            elif depth == 0 and tok.value in _BINOP_OPS:
                if tok.value == "-" and (i == 0 or (expr[i - 1].kind == "OP" and expr[i - 1].value in ("(", "[", "{", ","))):
                    continue
                return True
        elif depth == 0 and tok.kind == "KEYWORD" and tok.value in ("and", "or"):
            return True
    return False


def _is_truthy_literal(expr: list[luau_lex.Token]) -> bool:
    stripped = _strip_outer_parens(expr)
    if not stripped or _has_top_binop(stripped):
        return False
    if len(stripped) == 1:
        tok = stripped[0]
        if tok.kind in ("NUMBER", "STRING", "INTERP_FULL"):
            return True
        return tok.kind == "KEYWORD" and tok.value == "true"
    first, last = stripped[0], stripped[-1]
    if first.kind == "INTERP_BEGIN" and last.kind == "INTERP_END":
        return True
    if first.kind == "OP" and first.value == "{" and luau_lex.matching_close(stripped, 0) == len(stripped) - 1:
        return True
    if first.kind == "KEYWORD" and first.value == "function" and last.kind == "KEYWORD" and last.value == "end":
        return True
    if first.kind == "OP" and first.value == "#" and len(stripped) >= 2:
        return True
    if first.kind == "OP" and first.value == "-" and len(stripped) == 2 and stripped[1].kind == "NUMBER":
        return True
    return False


def _is_empty_fn_callback(expr: list[luau_lex.Token]) -> bool:
    stripped = _strip_outer_parens(expr)
    if len(stripped) < 4 or stripped[0].kind != "KEYWORD" or stripped[0].value != "function":
        return False
    if stripped[-1].kind != "KEYWORD" or stripped[-1].value != "end":
        return False
    p_idx = 1
    if p_idx < len(stripped) and stripped[p_idx].kind == "OP" and stripped[p_idx].value == "<":
        close_g = luau_lex.matching_close(stripped, p_idx)
        if close_g is None:
            return False
        p_idx = close_g + 1
    if p_idx >= len(stripped) or stripped[p_idx].kind != "OP" or stripped[p_idx].value != "(":
        return False
    close_p = luau_lex.matching_close(stripped, p_idx)
    if close_p is None:
        return False
    return close_p + 1 == len(stripped) - 1


def scan_spec_tautologies(spec_files: list[Path | str], root: Path) -> list[dict]:
    """Statically scan spec files for tautological assertions using `luau_lex`."""
    findings: list[dict] = []
    for raw in spec_files:
        path = _to_path(raw, root)
        try:
            text = path.read_text(encoding="utf-8", errors="replace")
        except OSError:
            continue
        rel = util.posix(path, root)
        tokens = _sig_tokens(text)
        throws_ranges: list[tuple[int, int]] = []
        for idx, tok in enumerate(tokens):
            if tok.kind != "OP" or tok.value != "(":
                continue
            callee_info = _extract_callee(tokens, idx)
            if callee_info is None:
                continue
            parts, _ = callee_info
            method = parts[-1]
            if method in _THROWS_METHODS and (len(parts) == 1 or parts[-2] in _ASSERT_RECEIVERS):
                end_idx = luau_lex.matching_close(tokens, idx)
                if end_idx is not None:
                    throws_ranges.append((idx, end_idx))

        def in_throws(token_index: int) -> bool:
            return any(lo < token_index < hi for lo, hi in throws_ranges)

        for idx, tok in enumerate(tokens):
            if tok.kind != "OP" or tok.value != "(":
                continue
            if in_throws(idx):
                continue
            callee_info = _extract_callee(tokens, idx)
            if callee_info is None:
                continue
            parts, callee_start = callee_info
            method = parts[-1]
            is_sert_receiver = len(parts) >= 2 and parts[-2] in _ASSERT_RECEIVERS
            is_assert_fn = len(parts) == 1 and method in ("assert", "sert")
            if not (is_sert_receiver or is_assert_fn):
                continue
            end_idx = luau_lex.matching_close(tokens, idx)
            if end_idx is None:
                continue
            args = _split_call_args(tokens, idx, end_idx)
            line = tokens[callee_start].line
            call_label = ".".join(parts)

            if is_sert_receiver and method in _EQ_METHODS and len(args) >= 2:
                sig0, sig1 = _expr_sig(args[0]), _expr_sig(args[1])
                same_span = bool(sig0) and sig0 == sig1 and not _has_call_token(args[0])
                num0, num1 = _parse_luau_number(args[0]), _parse_luau_number(args[1])
                same_num = num0 is not None and num1 is not None and num0 == num1
                if same_span or same_num:
                    lhs = text[args[0][0].start : args[0][-1].end].strip()
                    rhs = text[args[1][0].start : args[1][-1].end].strip()
                    findings.append(
                        {
                            "file": rel,
                            "line": line,
                            "kind": "tautology-eq",
                            "message": f"tautological {call_label}({lhs}, {rhs}) compares equivalent values",
                        }
                    )
            elif ((is_sert_receiver and method in _OK_METHODS) or is_assert_fn) and len(args) >= 1:
                value_consumed = callee_start > 0 and tokens[callee_start - 1].kind == "OP" and tokens[callee_start - 1].value in ("(", ",", "=", "{")
                if not value_consumed and _is_truthy_literal(args[0]):
                    lit = text[args[0][0].start : args[0][-1].end].strip()
                    findings.append(
                        {
                            "file": rel,
                            "line": line,
                            "kind": "tautology-ok",
                            "message": f"tautological {call_label}({lit}) always passes",
                        }
                    )
            elif is_sert_receiver and method in _DOES_NOT_THROW_METHODS and len(args) >= 1:
                if _is_empty_fn_callback(args[0]):
                    findings.append(
                        {
                            "file": rel,
                            "line": line,
                            "kind": "tautology-does-not-throw",
                            "message": f"tautological {call_label}(function() end) has an empty body",
                        }
                    )
            elif is_sert_receiver and method in _NE_METHODS and len(args) >= 2:
                if (_is_nil_literal(args[1]) and _is_non_nil_literal(args[0])) or (
                    _is_nil_literal(args[0]) and _is_non_nil_literal(args[1])
                ):
                    lhs = text[args[0][0].start : args[0][-1].end].strip()
                    rhs = text[args[1][0].start : args[1][-1].end].strip()
                    findings.append(
                        {
                            "file": rel,
                            "line": line,
                            "kind": "tautology-ne-nil",
                            "message": f"tautological {call_label}({lhs}, {rhs}) checks literal non-nil against nil",
                        }
                    )
    return findings


def _collect_source_files(root: Path, cfg, *, diff_files: set[str] | None = None) -> list[Path]:
    cov_table = config_mod.section_table(cfg, "coverage")
    spec_set = {_to_path(p, root).resolve() for p in graph_mod.discover_specs(root, cfg)}
    include_dirs = list(util.as_list(cov_table.get("include")) or ["src"])
    exclude = list(util.as_list(cov_table.get("exclude")))

    found: list[Path] = []
    seen: set[Path] = set()
    for pat in include_dirs:
        base = root / pat
        candidates = [base] if base.is_file() else sorted(base.rglob("*.luau")) if base.is_dir() else sorted(root.glob(pat))
        for path in candidates:
            if path.suffix != ".luau" or not path.is_file():
                continue
            resolved = path.resolve()
            if resolved in seen or resolved in spec_set:
                continue
            rel = util.posix(path, root)
            if exclude and not coverage_mod.chosen_files({rel: {}}, include_dirs, exclude):
                continue
            if diff_files is not None and rel not in diff_files:
                continue
            seen.add(resolved)
            found.append(path)
    return found


def _spec_coverage_index(root: Path, cfg) -> list[dict]:
    index: list[dict] = []
    spec_files: list[Path] = [_to_path(p, root) for p in graph_mod.discover_specs(root, cfg)]
    studio_cfg = cfg.get("studio") if hasattr(cfg, "get") else (cfg.get("studio") if isinstance(cfg, dict) else None)
    if isinstance(studio_cfg, dict) and studio_cfg.get("specs"):
        for raw_pat in util.as_list(studio_cfg["specs"]):
            for path in util.expand_globs(root, [raw_pat]):
                resolved = _to_path(path, root)
                if resolved.is_file() and resolved not in spec_files:
                    spec_files.append(resolved)

    for path in spec_files:
        try:
            text = path.read_text(encoding="utf-8", errors="replace")
        except OSError:
            continue
        tokens = _sig_tokens(text)
        idents = {tok.value for tok in tokens if tok.kind == "IDENT"}
        strings = {tok.value[1:-1] for tok in tokens if tok.kind == "STRING" and len(tok.value) >= 2}
        has_fuzz = ("fuzzRemote" in idents) or ("remotePayload" in idents)
        has_event_api = has_fuzz or bool(idents & _REMOTE_EVENT_TOKENS)
        has_invoke_api = has_fuzz or bool(idents & _REMOTE_INVOKE_TOKENS)
        has_remote_api = has_event_api or has_invoke_api
        req_stems: set[str] = set()
        for idx, tok in enumerate(tokens):
            if tok.kind == "IDENT" and tok.value == "require" and idx + 2 < len(tokens):
                for j in range(idx + 1, min(idx + 8, len(tokens))):
                    if tokens[j].kind == "STRING":
                        mod = tokens[j].value[1:-1].removesuffix(".luau").removesuffix(".lua")
                        m = _REQ_TAIL_RE.search(mod.replace("\\", "/"))
                        if m:
                            req_stems.add(m.group(1).lower())
                    elif tokens[j].kind == "OP" and tokens[j].value == ")":
                        break
        index.append(
            {
                "path": path,
                "stem": path.stem.removesuffix(".spec").lower(),
                "idents": idents,
                "idents_lower": {s.lower() for s in idents},
                "strings_lower": {s.lower() for s in strings},
                "has_fuzz": has_fuzz,
                "has_event_api": has_event_api,
                "has_invoke_api": has_invoke_api,
                "has_remote_api": has_remote_api,
                "req_stems": req_stems,
            }
        )
    return index


def _extract_remote_bindings(tokens: list[luau_lex.Token], rel_path: str) -> list[dict]:
    bindings: list[dict] = []
    n = len(tokens)
    for idx in range(n - 2):
        tok = tokens[idx]
        if tok.kind != "OP" or tok.value != ".":
            continue
        prop = tokens[idx + 1]
        if prop.kind != "IDENT":
            continue
        # Walk receiver chain backwards from `.`: `a.b.remote`
        recv_parts: list[str] = []
        k = idx - 1
        while k >= 0 and tokens[k].kind == "IDENT":
            recv_parts.append(tokens[k].value)
            if k >= 2 and tokens[k - 1].kind == "OP" and tokens[k - 1].value in (".", ":"):
                k -= 2
            else:
                break
        recv_parts.reverse()
        remote_name = recv_parts[-1] if recv_parts else ""

        if prop.value == "OnServerEvent" and idx + 4 < n:
            if (
                tokens[idx + 2].kind == "OP"
                and tokens[idx + 2].value == ":"
                and tokens[idx + 3].kind == "IDENT"
                and tokens[idx + 3].value in ("Connect", "Once")
                and tokens[idx + 4].kind == "OP"
                and tokens[idx + 4].value == "("
            ):
                handler_name = ""
                if idx + 5 < n and tokens[idx + 5].kind == "IDENT":
                    handler_name = tokens[idx + 5].value
                bindings.append(
                    {
                        "file": rel_path,
                        "line": prop.line,
                        "kind": "OnServerEvent",
                        "remote": remote_name,
                        "handler": handler_name,
                    }
                )
        elif prop.value == "OnServerInvoke" and tokens[idx + 2].kind == "OP" and tokens[idx + 2].value == "=":
            if idx + 3 < n and tokens[idx + 3].kind == "KEYWORD" and tokens[idx + 3].value == "nil":
                continue
            handler_name = ""
            if idx + 3 < n and tokens[idx + 3].kind == "IDENT":
                handler_name = tokens[idx + 3].value
            bindings.append(
                {
                    "file": rel_path,
                    "line": prop.line,
                    "kind": "OnServerInvoke",
                    "remote": remote_name,
                    "handler": handler_name,
                }
            )
    return bindings


def _is_remote_covered(binding: dict, spec_index: list[dict], src_stem: str, *, handler_count: int = 1) -> bool:
    remote_low = binding["remote"].lower()
    handler_low = binding["handler"].lower()
    src_low = src_stem.lower()
    candidates: list[str] = []
    if remote_low and remote_low not in _GENERIC_NAMES:
        candidates.append(remote_low)
    if handler_low and handler_low not in _GENERIC_NAMES:
        candidates.append(handler_low)

    kind_flag = "has_event_api" if binding.get("kind") == "OnServerEvent" else "has_invoke_api"
    for spec in spec_index:
        if not spec.get(kind_flag, spec["has_remote_api"]):
            continue
        if candidates and any(c in spec["idents_lower"] or any(c in s for s in spec["strings_lower"]) for c in candidates):
            return True
        if (handler_count <= 1 or not candidates) and (
            src_low in spec["req_stems"] or src_low == spec["stem"] or src_low in spec["idents_lower"]
        ):
            return True
    return False


def scan_remote_handlers(root: Path, cfg, *, diff_files: set[str] | None = None) -> list[dict]:
    """Find `.OnServerEvent:Connect` / `.OnServerInvoke` handlers without fuzz/test coverage."""
    src_files = _collect_source_files(root, cfg, diff_files=diff_files)
    spec_index = _spec_coverage_index(root, cfg)
    findings: list[dict] = []
    for path in src_files:
        try:
            text = path.read_text(encoding="utf-8", errors="replace")
        except OSError:
            continue
        rel = util.posix(path, root)
        tokens = _sig_tokens(text)
        bindings = _extract_remote_bindings(tokens, rel)
        for binding in bindings:
            if not _is_remote_covered(binding, spec_index, path.stem, handler_count=len(bindings)):
                label = binding["remote"] or binding["kind"]
                findings.append(
                    {
                        "file": rel,
                        "line": binding["line"],
                        "kind": "unfuzzed-remote",
                        "remote": binding["remote"],
                        "handler": binding["handler"],
                        "message": (
                            f"unfuzzed {binding['kind']} handler for '{label}' "
                            "(add sert.roblox.fuzzRemote / sert.gen.remotePayload coverage or pass --allow-unfuzzed-remotes)"
                        ),
                    }
                )
    return findings


def _extract_module_exports(tokens: list[luau_lex.Token], rel_path: str) -> list[ExportSpan]:
    """Identify exported `M.foo` / `return { foo = ... }` functions and their Lx-Ly line spans."""
    n = len(tokens)
    block_stack: list[tuple[str, int, dict | None]] = []
    paren_depth = brace_depth = bracket_depth = 0

    named_exports: list[tuple[str, str, int, int]] = []  # (mod_var, fn_name, start_line, end_line)
    local_funcs: dict[str, tuple[int, int]] = {}
    alias_assigns: list[tuple[str, str, str]] = []  # (mod_var, export_name, target_local)
    return_tables: list[tuple[int, int]] = []
    returned_names: list[str] = []

    idx = 0
    while idx < n:
        tok = tokens[idx]
        if tok.kind == "OP":
            if tok.value == "(":
                paren_depth += 1
            elif tok.value == ")":
                paren_depth = max(0, paren_depth - 1)
            elif tok.value == "{":
                brace_depth += 1
            elif tok.value == "}":
                brace_depth = max(0, brace_depth - 1)
            elif tok.value == "[":
                bracket_depth += 1
            elif tok.value == "]":
                bracket_depth = max(0, bracket_depth - 1)
            idx += 1
            continue

        if tok.kind == "KEYWORD":
            if tok.value == "return" and not block_stack and paren_depth == 0 and brace_depth == 0:
                if idx + 1 < n and tokens[idx + 1].kind == "IDENT":
                    returned_names.append(tokens[idx + 1].value)
                elif idx + 1 < n and tokens[idx + 1].kind == "OP" and tokens[idx + 1].value == "{":
                    close = luau_lex.matching_close(tokens, idx + 1)
                    if close is not None:
                        return_tables.append((idx + 1, close))
                elif (
                    idx + 5 < n
                    and tokens[idx + 1].kind == "IDENT"
                    and tokens[idx + 2].kind == "OP"
                    and tokens[idx + 2].value == "."
                    and tokens[idx + 3].kind == "IDENT"
                    and tokens[idx + 4].kind == "OP"
                    and tokens[idx + 4].value == "("
                    and tokens[idx + 5].kind == "IDENT"
                ):
                    returned_names.append(tokens[idx + 5].value)

            if tok.value == "function":
                meta: dict | None = None
                if not block_stack and brace_depth == 0:
                    # Pattern 1: function M.foo(...) or function M:foo(...)
                    if (
                        idx + 3 < n
                        and tokens[idx + 1].kind == "IDENT"
                        and tokens[idx + 2].kind == "OP"
                        and tokens[idx + 2].value in (".", ":")
                        and tokens[idx + 3].kind == "IDENT"
                        and (idx + 4 < n and tokens[idx + 4].kind == "OP" and tokens[idx + 4].value in ("(", "<"))
                    ):
                        meta = {"kind": "export", "mod": tokens[idx + 1].value, "name": tokens[idx + 3].value, "start": tok.line}
                    # Pattern 2: local function helper(...)
                    elif (
                        idx >= 1
                        and tokens[idx - 1].kind == "KEYWORD"
                        and tokens[idx - 1].value == "local"
                        and idx + 1 < n
                        and tokens[idx + 1].kind == "IDENT"
                    ):
                        meta = {"kind": "local", "name": tokens[idx + 1].value, "start": tok.line}
                    # Pattern 3: M.foo = function(...)
                    elif (
                        idx >= 4
                        and tokens[idx - 1].kind == "OP"
                        and tokens[idx - 1].value == "="
                        and tokens[idx - 2].kind == "IDENT"
                        and tokens[idx - 3].kind == "OP"
                        and tokens[idx - 3].value == "."
                        and tokens[idx - 4].kind == "IDENT"
                    ):
                        meta = {
                            "kind": "export",
                            "mod": tokens[idx - 4].value,
                            "name": tokens[idx - 2].value,
                            "start": tokens[idx - 4].line,
                        }
                # Pattern 4: inside module-level table literal: foo = function(...)
                if (
                    meta is None
                    and not block_stack
                    and brace_depth > 0
                    and idx >= 2
                    and tokens[idx - 1].kind == "OP"
                    and tokens[idx - 1].value == "="
                    and tokens[idx - 2].kind == "IDENT"
                ):
                    meta = {
                        "kind": "table_fn",
                        "brace_depth": brace_depth,
                        "name": tokens[idx - 2].value,
                        "start": tokens[idx - 2].line,
                        "pos": idx - 2,
                    }
                block_stack.append(("function", tok.line, meta))
            elif tok.value == "do":
                block_stack.append(("do", tok.line, None))
            elif tok.value == "if":
                if luau_lex.is_if_statement(tokens, idx):
                    block_stack.append(("if", tok.line, None))
            elif tok.value == "repeat":
                block_stack.append(("repeat", tok.line, None))
            elif tok.value == "until":
                while block_stack:
                    kind, _, _ = block_stack.pop()
                    if kind == "repeat":
                        break
            elif tok.value == "end":
                if block_stack:
                    kind, start_line, meta = block_stack.pop()
                    if kind == "function" and meta is not None:
                        mkind = meta.get("kind")
                        if mkind == "export":
                            named_exports.append((str(meta["mod"]), str(meta["name"]), int(meta["start"]), tok.line))
                        elif mkind == "local":
                            local_funcs[str(meta["name"])] = (int(meta["start"]), tok.line)
                        elif mkind == "table_fn":
                            meta["end"] = tok.line
                            alias_assigns.append((f"__tbl__{meta['pos']}", str(meta["name"]), f"{meta['start']}:{tok.line}"))

        # Module-level alias: M.foo = localHelper
        if (
            not block_stack
            and brace_depth == 0
            and idx + 4 < n
            and tok.kind == "IDENT"
            and tokens[idx + 1].kind == "OP"
            and tokens[idx + 1].value == "."
            and tokens[idx + 2].kind == "IDENT"
            and tokens[idx + 3].kind == "OP"
            and tokens[idx + 3].value == "="
            and tokens[idx + 4].kind == "IDENT"
        ):
            alias_assigns.append((tok.value, tokens[idx + 2].value, tokens[idx + 4].value))

        idx += 1

    active_mods = set(returned_names)
    if not active_mods and named_exports:
        active_mods = {named_exports[0][0]}

    exports: list[ExportSpan] = []
    seen_spans: set[tuple[str, int, int]] = set()
    for mod, name, start_line, end_line in named_exports:
        if mod in active_mods and (name, start_line, end_line) not in seen_spans:
            seen_spans.add((name, start_line, end_line))
            exports.append(ExportSpan(f"{mod}.{name}", rel_path, start_line, end_line))

    for mod, name, target in alias_assigns:
        if mod in active_mods and target in local_funcs:
            s_ln, e_ln = local_funcs[target]
            if (name, s_ln, e_ln) not in seen_spans:
                seen_spans.add((name, s_ln, e_ln))
                exports.append(ExportSpan(f"{mod}.{name}", rel_path, s_ln, e_ln))

    # Extract returned table functions: return { foo = function(...) end, bar = localHelper }
    for open_idx, close_idx in return_tables:
        t_pos = open_idx + 1
        depth = 0
        while t_pos < close_idx:
            t = tokens[t_pos]
            if t.kind == "OP" and t.value == "{":
                depth += 1
            elif t.kind == "OP" and t.value == "}":
                depth = max(0, depth - 1)
            elif (
                depth == 0
                and t.kind == "IDENT"
                and t_pos + 2 < close_idx
                and tokens[t_pos + 1].kind == "OP"
                and tokens[t_pos + 1].value == "="
            ):
                rhs = tokens[t_pos + 2]
                if rhs.kind == "IDENT" and rhs.value in local_funcs:
                    s_ln, e_ln = local_funcs[rhs.value]
                    if (t.value, s_ln, e_ln) not in seen_spans:
                        seen_spans.add((t.value, s_ln, e_ln))
                        exports.append(ExportSpan(t.value, rel_path, s_ln, e_ln))
                elif rhs.kind == "KEYWORD" and rhs.value == "function":
                    for _, fn_name, enc_span in alias_assigns:
                        if _ == f"__tbl__{t_pos}" and fn_name == t.value and ":" in enc_span:
                            s_s, e_s = enc_span.split(":", 1)
                            s_ln, e_ln = int(s_s), int(e_s)
                            if (t.value, s_ln, e_ln) not in seen_spans:
                                seen_spans.add((t.value, s_ln, e_ln))
                                exports.append(ExportSpan(t.value, rel_path, s_ln, e_ln))
            t_pos += 1

    exports.sort(key=lambda item: (item.start_line, item.name))
    return exports


def find_uncovered_exports(
    root: Path,
    cfg,
    coverage_files: dict[str, dict[int, bool]] | None,
    *,
    diff_files: set[str] | None = None,
    fn_hits: dict[str, dict[int, bool]] | None = None,
) -> list[ExportSpan]:
    """Return exported `src/` functions with zero covered body hits in `coverage_files`."""
    if coverage_files is None:
        return []
    src_files = _collect_source_files(root, cfg, diff_files=diff_files)
    uncovered: list[ExportSpan] = []
    for path in src_files:
        try:
            text = path.read_text(encoding="utf-8", errors="replace")
        except OSError:
            continue
        rel = util.posix(path, root)
        exports = _extract_module_exports(_sig_tokens(text), rel)
        if not exports:
            continue
        hits_map = coverage_files.get(rel)
        fn_map = fn_hits.get(rel) if fn_hits is not None else None
        if hits_map is None:
            uncovered.extend(exports)
            continue
        for exp in exports:
            if exp.start_line == exp.end_line and fn_map is not None and exp.start_line in fn_map:
                if not fn_map[exp.start_line]:
                    uncovered.append(exp)
                continue
            interior = [ln for ln in hits_map if exp.start_line < ln < exp.end_line]
            span_lines = interior if interior else [ln for ln in hits_map if exp.start_line <= ln <= exp.end_line]
            if not span_lines:
                # No lines inside an empty function: only treat as uncovered if no lines at all hit
                start_hit = hits_map.get(exp.start_line)
                if start_hit is False:
                    uncovered.append(exp)
                continue
            if not any(bool(hits_map[ln]) for ln in span_lines):
                uncovered.append(exp)
    return uncovered


def _load_recent_telemetry(root: Path) -> dict | None:
    path = root / run_mod.LAST_TELEMETRY_REL
    if not path.is_file():
        return None
    data = util.load_json(path)
    return data if isinstance(data, dict) else None


def _resolve_telemetry(
    root: Path,
    cfg,
    *,
    specs: list[Path] | None,
    run_output: str | None,
    run_result,
    parsed_list: list[markers_mod.Parsed] | None,
    skip_run: bool,
) -> tuple[dict, str | None]:
    if run_output is not None:
        parsed = markers_mod.parse(run_output)
        res = run_mod.RunResult(status=0, entries=[], tests=parsed.tests)
        return run_mod._collect_telemetry(res, [parsed]), None

    if parsed_list is not None:
        res = run_result if run_result is not None else run_mod.RunResult(status=0, entries=[], tests=[])
        return run_mod._collect_telemetry(res, parsed_list), None

    if skip_run:
        recent = _load_recent_telemetry(root)
        if recent is not None:
            return recent, None
        return {
            "skippedByReason": {reason: 0 for reason in markers_mod.SKIP_REASONS},
            "zeroAssertionTests": [],
            "tautologies": [],
            "vacuousProperties": [],
        }, None

    spec_arg = [str(p) for p in specs] if specs is not None else []
    run_args = run_mod.make_run_args(specs=spec_arg, coverage=True, root=str(root))
    out_buf, err_buf = io.StringIO(), io.StringIO()
    try:
        exit_code, result, parsed = run_mod.execute_run(run_args, root, cfg, out=out_buf, err=err_buf)
    except util.SertError as err:
        recent = _load_recent_telemetry(root)
        if recent is not None:
            return recent, None
        return {
            "skippedByReason": {reason: 0 for reason in markers_mod.SKIP_REASONS},
            "zeroAssertionTests": [],
            "tautologies": [],
            "vacuousProperties": [],
        }, str(err)

    telemetry = run_mod._collect_telemetry(result, parsed)
    run_err = None
    if exit_code != 0 and not (parsed and any(p.done or p.verdicts for p in parsed)):
        detail = (err_buf.getvalue() or out_buf.getvalue()).strip()
        run_err = detail or f"headless spec run exited with status {exit_code}"
    return telemetry, run_err


def run_audit(
    root: Path | None = None,
    cfg=None,
    *,
    diff: str | None = None,
    allow_unfuzzed_remotes: bool = False,
    strict: bool = False,
    run_output: str | None = None,
    run_result=None,
    parsed_list: list[markers_mod.Parsed] | None = None,
    coverage_file: str | Path | None = None,
    specs: list[Path] | None = None,
    skip_run: bool = False,
    diff_lines: dict[str, set[int]] | None = None,
    cov_files: dict[str, dict[int, int]] | None = None,
    dep_graph=None,
) -> tuple[int, dict]:
    """Execute static and runtime reward-hacking checks and return `(exit_code, report)`."""
    if root is None:
        root = getattr(cfg, "root", None) if cfg is not None else config_mod.find_root(None)
    root = Path(root)
    if cfg is None:
        cfg = config_mod.load(root)

    resolved_diff_lines: dict[str, set[int]] | None = None
    diff_files: set[str] | None = None
    if diff is not None:
        resolved_diff_lines = coverage_mod.git_diff_lines(root, diff) if diff_lines is None else diff_lines
        diff_files = set(resolved_diff_lines)

    all_specs: list[Path] = [_to_path(p, root) for p in (specs if specs is not None else graph_mod.discover_specs(root, cfg))]
    if diff_files is not None:
        all_spec_rels = [util.posix(p, root) for p in all_specs]
        if specs is not None:
            impacted_set = set(all_spec_rels) | diff_files
        else:
            impacted_rels = graph_mod.affected_specs_for_files(
                root,
                cfg,
                diff_files,
                diff_lines=resolved_diff_lines,
                all_specs=all_spec_rels,
                dep_graph=dep_graph,
            )
            impacted_set = set(impacted_rels) | diff_files
        target_specs = [p for p in all_specs if util.posix(p, root) in impacted_set]
    else:
        target_specs = all_specs

    static_tautologies = scan_spec_tautologies(target_specs, root)
    unfuzzed_remotes = [] if allow_unfuzzed_remotes else scan_remote_handlers(root, cfg, diff_files=diff_files)

    telemetry, run_error = _resolve_telemetry(
        root,
        cfg,
        specs=target_specs if diff is not None and target_specs else (specs if specs is not None else None),
        run_output=run_output,
        run_result=run_result,
        parsed_list=parsed_list,
        skip_run=skip_run,
    )

    cov_path = coverage_mod.output_path(cfg, root, coverage_file)
    resolved_cov = cov_files if cov_files is not None else (coverage_mod.parse(cov_path, root=root) if cov_path.is_file() else None)
    resolved_fn_hits = coverage_mod.parse_function_hits(cov_path, root=root) if cov_path.is_file() else None
    uncovered_exports = find_uncovered_exports(
        root, cfg, resolved_cov, diff_files=diff_files, fn_hits=resolved_fn_hits
    )

    zero_assertions = list(telemetry.get("zeroAssertionTests") or [])
    runtime_tautologies = list(telemetry.get("tautologies") or [])
    vacuous_props = list(telemetry.get("vacuousProperties") or [])
    skipped_by_reason = dict(telemetry.get("skippedByReason") or {})

    combined_tautologies = list(static_tautologies)
    seen_taut = {(str(t.get("file", "")), t.get("line"), str(t.get("message", ""))) for t in combined_tautologies}
    for rt in runtime_tautologies:
        entry = {
            "file": str(rt.get("file", "")),
            "line": rt.get("line", 0),
            "kind": str(rt.get("kind", "runtime-tautology")),
            "message": str(rt.get("message") or f"runtime tautology ({rt.get('kind', 'assertion')}) in {rt.get('test', '?')}"),
        }
        key = (entry["file"], entry["line"], entry["message"])
        if key not in seen_taut:
            seen_taut.add(key)
            combined_tautologies.append(entry)

    issues: list[dict] = []
    for vp in vacuous_props:
        issues.append(
            {
                "file": str(vp.get("file", "")),
                "line": vp.get("line") or 0,
                "kind": "vacuous-property",
                "message": f"vacuous property '{vp.get('name', '?')}': {vp.get('message', 'discarded cases')}",
            }
        )
    for rem in unfuzzed_remotes:
        issues.append(rem)
    if run_error:
        issues.append({"file": "", "line": 0, "kind": "runner-error", "message": run_error})
    explicit_skips = int(skipped_by_reason.get("explicit", 0) or 0) if strict else 0
    if strict:
        for exp in uncovered_exports:
            issues.append(
                {
                    "file": exp.file,
                    "line": exp.start_line,
                    "kind": "uncovered-export",
                    "message": f"uncovered export {exp.name} ({exp.span})",
                }
            )
        if explicit_skips > 0:
            issues.append(
                {
                    "file": "",
                    "line": 0,
                    "kind": "explicit-skip",
                    "message": f"{explicit_skips} explicit skipped test(s) (sert.test.skip) under --strict",
                }
            )

    reward_hack_count = len(zero_assertions) + len(combined_tautologies) + len(vacuous_props) + len(unfuzzed_remotes)
    fail_count = (
        reward_hack_count
        + (len(uncovered_exports) if strict else 0)
        + (1 if explicit_skips > 0 else 0)
        + (1 if run_error else 0)
    )
    exit_code = 1 if fail_count > 0 else 0

    report = {
        "zero_assertion_tests": zero_assertions,
        "tautologies": combined_tautologies,
        "vacuous_properties": vacuous_props,
        "unfuzzed_remotes": unfuzzed_remotes,
        "uncovered_exports": [exp.to_dict() for exp in uncovered_exports],
        "stale_snapshots": [],
        "issues": issues,
        "skipped_by_reason": skipped_by_reason,
        "strict": strict,
        "diff": diff,
    }
    return exit_code, report


def _render_audit_human(report: dict, exit_code: int) -> str:
    lines: list[str] = []
    for name in report.get("zero_assertion_tests", ()):
        lines.append(f"FAIL zero-assertion test (missing {{ smoke = true }}): {name}")
    for taut in report.get("tautologies", ()):
        lines.append(f"FAIL tautology {taut.get('file', '?')}:{taut.get('line', 0)}: {taut.get('message', '')}")
    for vp in report.get("vacuous_properties", ()):
        lines.append(f"FAIL vacuous property {vp.get('name', '?')}: {vp.get('message', '')}")
    for rem in report.get("unfuzzed_remotes", ()):
        lines.append(f"FAIL unfuzzed remote {rem.get('file', '?')}:{rem.get('line', 0)}: {rem.get('message', '')}")
    for exp in report.get("uncovered_exports", ()):
        lines.append(f"UNCOVERED_EXPORT {exp.get('span', '?')}: {exp.get('name', '?')}")
    if exit_code == 0 and not lines:
        lines.append("audit: ok (0 issues)")
    elif exit_code == 0:
        lines.append(f"audit: ok ({len(report.get('uncovered_exports', ()))} uncovered export warning(s))")
    return "\n".join(lines)


def _format_audit_output(fmt: str, exit_code: int, report: dict, *, root: Path | None = None) -> str:
    if fmt == "json":
        summary = {
            "zero_assertion": len(report.get("zero_assertion_tests", ())),
            "tautologies": len(report.get("tautologies", ())),
            "vacuous_properties": len(report.get("vacuous_properties", ())),
            "unfuzzed_remotes": len(report.get("unfuzzed_remotes", ())),
            "uncovered_exports": len(report.get("uncovered_exports", ())),
        }
        errors: list[str] = []
        for name in report.get("zero_assertion_tests", ()):
            errors.append(f"zero-assertion test: {name}")
        for taut in report.get("tautologies", ()):
            errors.append(f"tautology {taut.get('file', '?')}:{taut.get('line', 0)}: {taut.get('message', '')}")
        for issue in report.get("issues", ()):
            errors.append(f"{issue.get('file', '?')}:{issue.get('line', 0)}: {issue.get('message', '')}")
        return agent.json_dumps_compact(
            agent.json_envelope("audit", exit_code, summary=summary, errors=errors, data=report)
        )
    if fmt == "agent":
        text = agent.format_audit_agent(report, root=root)
        exports = report.get("uncovered_exports") or []
        if exports and not report.get("strict"):
            extra = [f"UNCOVERED_EXPORT {exp['span']} {exp['name']}" for exp in exports[:20]]
            text = f"{text}\n" + "\n".join(extra)
        return text
    return _render_audit_human(report, exit_code)


def add_parser(subparsers) -> argparse.ArgumentParser:
    parser = subparsers.add_parser(
        "audit",
        help="run static and runtime anti-reward-hacking checks and uncovered export radar",
    )
    parser.add_argument(
        "--diff",
        nargs="?",
        const="HEAD",
        default=None,
        metavar="REV",
        help="restrict static and export radar checks to files modified vs REV (default HEAD)",
    )
    parser.add_argument(
        "--allow-unfuzzed-remotes",
        action="store_true",
        help="waive missing fuzzRemote/remotePayload coverage on .OnServerEvent/.OnServerInvoke handlers",
    )
    parser.add_argument(
        "--strict",
        action="store_true",
        help="also fail exit 1 on uncovered public exports",
    )
    parser.add_argument("--no-run", action="store_true", help="use existing .sert/last-telemetry.json without executing specs")
    parser.add_argument("--run-output", default=None, help="inspect markers from a captured run output file")
    parser.add_argument("--coverage-file", default=None, help="override path to coverage.out")
    parser.add_argument("--agent", action="store_true", help="compact AI-agent-friendly audit output")
    parser.add_argument("--format", choices=("human", "agent", "json"), default=None, help="output format")
    parser.set_defaults(func=cmd_audit)
    return parser


def cmd_audit(args, root: Path | None = None, cfg=None) -> int:
    if cfg is None:
        cfg = config_mod.from_args(args)
    if root is None:
        root = getattr(cfg, "root", None) or config_mod.find_root(getattr(args, "root", None))

    run_output = None
    raw_out_path = getattr(args, "run_output", None)
    if raw_out_path:
        p = Path(raw_out_path)
        if not p.is_absolute():
            p = root / p
        if not p.is_file():
            raise util.SertError(f"audit: run output file not found: {p}")
        run_output = p.read_text(encoding="utf-8", errors="replace")

    exit_code, report = run_audit(
        root,
        cfg,
        diff=getattr(args, "diff", None),
        allow_unfuzzed_remotes=bool(getattr(args, "allow_unfuzzed_remotes", False)),
        strict=bool(getattr(args, "strict", False)),
        run_output=run_output,
        coverage_file=getattr(args, "coverage_file", None),
        skip_run=bool(getattr(args, "no_run", False)),
    )
    fmt = agent.output_format(args)
    rendered = _format_audit_output(fmt, exit_code, report, root=root)
    if rendered:
        sys.stdout.write(rendered + "\n")
        sys.stdout.flush()
    if fmt == "human" and util.on_github_actions():
        emitted = 0
        for name in report.get("zero_assertion_tests", ()):
            if emitted >= 25:
                break
            util.annotate("error", f"zero-assertion test (missing {{ smoke = true }}): {name}", title="sert audit")
            emitted += 1
        for taut in report.get("tautologies", ()):
            if emitted >= 25:
                break
            util.annotate(
                "error",
                str(taut.get("message") or "tautological assertion"),
                file=taut.get("file") or None,
                line=taut.get("line") or None,
                title="sert audit",
            )
            emitted += 1
        for vp in report.get("vacuous_properties", ()):
            if emitted >= 25:
                break
            util.annotate(
                "error",
                f"vacuous property '{vp.get('name', '?')}': {vp.get('message', '')}",
                file=vp.get("file") or None,
                line=vp.get("line") or None,
                title="sert audit",
            )
            emitted += 1
        for rem in report.get("unfuzzed_remotes", ()):
            if emitted >= 25:
                break
            util.annotate(
                "error",
                str(rem.get("message") or "unfuzzed remote handler"),
                file=rem.get("file") or None,
                line=rem.get("line") or None,
                title="sert audit",
            )
            emitted += 1
        strict_flag = bool(report.get("strict"))
        for exp in report.get("uncovered_exports", ()):
            if emitted >= 25:
                break
            util.annotate(
                "error" if strict_flag else "warning",
                f"uncovered export {exp.get('name', '?')} ({exp.get('span', '?')})",
                file=exp.get("file") or None,
                line=exp.get("start_line") or None,
                title="sert audit",
            )
            emitted += 1
    return exit_code
