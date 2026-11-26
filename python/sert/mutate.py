"""`sert mutate [paths...]`: zero-copy token-stream mutation testing over headless specs."""

from __future__ import annotations

import argparse
from concurrent.futures import FIRST_COMPLETED, ThreadPoolExecutor, as_completed, wait
from dataclasses import dataclass
import hashlib
import io
import json
import os
from pathlib import Path
import posixpath
import re
import shutil
import signal
import subprocess
import sys
import threading
import time

from sert import VERSION, agent, config as config_mod, coverage as coverage_mod, fetch, graph, luau_lex, run as run_mod
from sert.util import FAILED, SertError, annotate, as_list, interrupt, load_json, on_github_actions, strip_jsonc, step_summary, write_atomic

LONG_OPEN = re.compile(r"\[(=*)\[")

ALL_OPERATORS = (
    "stmt_del",
    "ret_val",
    "cond_inv",
    "rel_flip",
    "arith_op",
    "logic_op",
    "math_fn",
    "off_by_one",
    "nil_guard",
    "remote_guard",
)
SWITCH = "_SERT_M.id"
STAGED_SWITCH = "_SERT_M.id"
MUTANT_PREAMBLE = (
    'local _SERT_OK, _SERT_RAW = pcall(require, "@__SERT_MUTANT"); '
    'local _SERT_M: any = if _SERT_OK and type(_SERT_RAW) == "table" then _SERT_RAW '
    'else { id = 0, h = function() return false end }; '
)
DETECTED = ("KILLED",)
BATCH_TIMEOUT_FACTOR = 16.0

_FLIP_MAP = {"<=": "<", ">=": ">", "<": ">", ">": "<", "==": "~=", "~=": "=="}
_ARITH_MAP = {"+": "-", "-": "+", "*": "/", "/": "*", "//": "*", "%": "*"}
_COMPOUND_FLIP_MAP = {"+=": "-=", "-=": "+=", "*=": "/=", "/=": "*=", "//=": "*=", "%=": "*="}
_COMPOUND_OPS = frozenset({"+=", "-=", "*=", "/=", "//=", "%=", "^=", "..="})
_LOGIC_MAP = {"and": "or", "or": "and"}
_MATH_FN_MAP = {"min": "max", "max": "min", "floor": "ceil", "ceil": "floor"}

_BENIGN_CALL_RE = re.compile(
    r"^\s*(?:task\.(?:wait|spawn|defer|delay|cancel)|(?:Util\.)?Defer\.wait|warn|print|debug\.[A-Za-z_]+|"
    r"(?:Util\.)?(?:log|Logger\.[A-Za-z_]+)|table\.(?:sort|clear)|"
    r"[A-Za-z0-9_.]*Messaging(?:Service)?:(?:Publish|Subscribe)Async|"
    r"[A-Za-z0-9_.\[\]]+:(?:Disconnect|DisconnectAll|Destroy|ClearAllChildren|MakeJoints|BreakJoints|"
    r"MoveTo|PivotTo|SetPrimaryPartCFrame|Play|Stop|Pause|Resume|CaptureFocus|ReleaseFocus|"
    r"SetCore|SetCoreGuiEnabled|ApplyDescription|ApplyDescriptionReset))\s*(?:\(|\{|\"|'|\[|`)"
)
_COSMETIC_PROP_RE = re.compile(
    r"\.(?:AnchorPoint|AutomaticSize|AutomaticCanvasSize|BackgroundColor3|BackgroundTransparency|BorderColor3|"
    r"BorderSizePixel|CanvasSize|ClipsDescendants|ElasticBehavior|FillDirection|Font|FontFace|"
    r"HorizontalAlignment|Image|ImageColor3|ImageRectOffset|ImageRectSize|ImageTransparency|LayoutOrder|Padding|"
    r"Position|RichText|Rotation|ScaleType|ScrollBarImageColor3|ScrollBarImageTransparency|ScrollBarThickness|"
    r"ScrollingDirection|Size|SliceCenter|SortOrder|TextColor3|TextScaled|TextSize|TextStrokeColor3|"
    r"TextStrokeTransparency|TextTransparency|TextTruncate|TextWrapped|TextXAlignment|TextYAlignment|"
    r"VerticalAlignment|ZIndex|BrickColor|Color|Material|Reflectance|CastShadow|Massless|"
    r"AssemblyLinearVelocity|AssemblyAngularVelocity|Velocity|RotVelocity|CFrame|Orientation|"
    r"SoundId|Volume|PlaybackSpeed|Looped|TimePosition|EmitterSize|RollOffMaxDistance|RollOffMinDistance|"
    r"Texture|TextureId|TextureID|MeshId|MeshType|Scale|Offset|Brightness|Range|Shadows|"
    r"LightEmission|LightInfluence|Lifetime|Rate|Speed|SpreadAngle|Drag|Acceleration|LockedToPart|CornerRadius)\b"
)

_BINARY_CONTINUATION_OPS = frozenset(
    {
        ".",
        ":",
        ",",
        "(",
        "[",
        "{",
        "=",
        "+",
        "-",
        "*",
        "/",
        "//",
        "%",
        "^",
        "..",
        "==",
        "~=",
        "<",
        "<=",
        ">",
        ">=",
        "::",
        "->",
        "&",
        "|",
    }
)
_NEXT_CONTINUATION_OPS = frozenset(
    {
        ",",
        ")",
        "}",
        "]",
        "..",
        "+",
        "-",
        "*",
        "/",
        "//",
        "%",
        "^",
        "==",
        "~=",
        "<=",
        ">=",
        "<",
        ">",
        "::",
        "->",
        ".",
        ":",
        "(",
        "{",
        "[",
        "&",
        "|",
    }
)
_OPERAND_END_OPS = frozenset({")", "]", "}"})


@dataclass
class Mutant:
    id: int
    file: str
    line: int
    op: str
    original: str
    mutated: str
    spec_filter: str | None = None
    status: str = "PENDING"
    covering_specs: tuple[str, ...] = ()
    line_key: int = 0
    top_level: bool = False
    test_indices: tuple[int, ...] = ()


def scan_lines(text: str, keep_strings: bool = False) -> tuple[list[str], list[str], list[bool]]:
    """Return `(clean_lines, same_len_masked_lines, multiline_span_flags)` for Luau source text."""
    clean_out: list[str] = []
    mask_out: list[str] = []
    multiline_flags: list[bool] = []
    clean_line: list[str] = []
    mask_line: list[str] = []
    i, n = 0, len(text)
    closer: str | None = None
    in_comment = False
    interp_depth = 0
    interp_quote: str | None = None
    interp_stack: list[int] = []
    comment_return: tuple[str, int] | None = None
    line_had_multiline = False

    def flush(had_multi: bool) -> None:
        nonlocal clean_line, mask_line, line_had_multiline
        clean_out.append("".join(clean_line))
        mask_out.append("".join(mask_line))
        multiline_flags.append(had_multi)
        clean_line, mask_line = [], []
        line_had_multiline = closer is not None

    while i < n:
        ch = text[i]
        if ch == "\n":
            if closer == "\n" and comment_return is not None:
                closer, interp_depth = comment_return
                in_comment, interp_quote, comment_return = False, None, None
            elif closer == "`" and interp_depth > 0:
                interp_quote = None
            elif closer in ("\n", '"', "'", "`"):
                closer, in_comment, interp_depth, interp_quote = None, False, 0, None
                interp_stack.clear()
            flush(line_had_multiline or (closer is not None))
            i += 1
            continue
        if closer is not None:
            if closer == "\n" and ch == "\r":
                if comment_return is not None:
                    closer, interp_depth = comment_return
                    in_comment, interp_quote, comment_return = False, None, None
                else:
                    closer, in_comment = None, False
                continue
            if closer in ('"', "'") or (closer == "`" and (interp_depth == 0 or interp_quote is not None)):
                if ch == "\\":
                    if i + 1 < n and text[i + 1] == "\n":
                        if keep_strings and not in_comment:
                            clean_line.append("\\")
                            mask_line.append(" ")
                        flush(True)
                        line_had_multiline = True
                        i += 2
                        continue
                    if i + 2 < n and text[i + 1 : i + 3] == "\r\n":
                        if keep_strings and not in_comment:
                            clean_line.append("\\\r")
                            mask_line.append("  ")
                        flush(True)
                        line_had_multiline = True
                        i += 3
                        continue
                    if i + 1 < n and text[i + 1] == "z":
                        if keep_strings and not in_comment:
                            clean_line.append("\\z")
                            mask_line.append("  ")
                        i += 2
                        while i < n and text[i] in " \t\r\n\v\f":
                            if text[i] == "\n":
                                flush(True)
                                line_had_multiline = True
                            elif keep_strings and not in_comment:
                                clean_line.append(text[i])
                                mask_line.append(" ")
                            i += 1
                        continue
                    if keep_strings and not in_comment:
                        clean_line.append(text[i : i + 2])
                        mask_line.append("  ")
                    i += 2
                    continue
            if closer == "`":
                if interp_quote is not None:
                    if interp_quote == "`" and ch == "{":
                        interp_stack.append(interp_depth)
                        interp_depth, interp_quote = 1, None
                        if not in_comment:
                            clean_line.append(ch)
                            mask_line.append(" ")
                        i += 1
                        continue
                    if ch == interp_quote:
                        interp_quote = None
                        if not in_comment:
                            clean_line.append(ch if keep_strings else " ")
                            mask_line.append(" ")
                    elif keep_strings and not in_comment:
                        clean_line.append(ch)
                        mask_line.append(" ")
                    i += 1
                    continue
                if interp_depth > 0:
                    if text.startswith("--", i):
                        match = LONG_OPEN.match(text, i + 2)
                        comment_return = ("`", interp_depth)
                        closer, in_comment = ("]" + match.group(1) + "]", True) if match else ("\n", True)
                        i = match.end() if match else i + 2
                        continue
                    if ch in ('"', "'", "`"):
                        interp_quote = ch
                        if not in_comment:
                            clean_line.append(ch if keep_strings else " ")
                            mask_line.append(" ")
                        i += 1
                        continue
                    if ch == "[":
                        match = LONG_OPEN.match(text, i)
                        if match:
                            long_end = text.find("]" + match.group(1) + "]", match.end())
                            end_pos = len(text) if long_end < 0 else long_end + len(match.group(1)) + 2
                            seg = text[i:end_pos]
                            for seg_idx, part in enumerate(seg.split("\n")):
                                if seg_idx > 0:
                                    flush(True)
                                    line_had_multiline = True
                                if keep_strings and not in_comment:
                                    clean_line.append(part)
                                    mask_line.append(" " * len(part))
                            i = end_pos
                            continue
                    interp_depth += 1 if ch == "{" else -1 if ch == "}" else 0
                    if not in_comment:
                        clean_line.append(ch)
                        mask_line.append(" ")
                    i += 1
                    continue
                if ch == "{":
                    interp_depth = 1
                    if not in_comment:
                        clean_line.append(ch)
                        mask_line.append(" ")
                    i += 1
                    continue
            if text.startswith(closer, i) and closer != "\n":
                if not in_comment:
                    clean_line.append(closer if keep_strings else " ")
                    mask_line.append(closer if (keep_strings and len(closer) == 1 and not interp_stack) else " " * len(closer))
                i += len(closer)
                if in_comment and comment_return is not None:
                    closer, interp_depth = comment_return
                    in_comment, interp_quote, comment_return = False, None, None
                elif closer == "`" and interp_stack:
                    interp_depth = interp_stack.pop()
                    interp_quote = None
                else:
                    closer, in_comment, interp_depth, interp_quote = None, False, 0, None
                continue
            if keep_strings and not in_comment:
                clean_line.append(ch)
                mask_line.append(" ")
            i += 1
            continue
        if text.startswith("--", i):
            match = LONG_OPEN.match(text, i + 2)
            closer, in_comment = ("]" + match.group(1) + "]", True) if match else ("\n", True)
            i = match.end() if match else i + 2
            continue
        match = LONG_OPEN.match(text, i)
        if match:
            closer, in_comment, token = "]" + match.group(1) + "]", False, match.group(0)
            clean_line.append(token if keep_strings else " ")
            mask_line.append((" " * len(token)) if keep_strings else " ")
            i = match.end()
            continue
        if ch in ('"', "'", "`"):
            closer, in_comment, interp_depth, interp_quote = ch, False, 0, None
            clean_line.append(ch if keep_strings else " ")
            mask_line.append(ch if keep_strings else " ")
            i += 1
            continue
        clean_line.append(ch)
        mask_line.append(ch)
        i += 1

    if closer in ("\n", '"', "'", "`"):
        closer, in_comment = None, False
    flush(line_had_multiline or (closer is not None))
    return clean_out, mask_out, multiline_flags


def source_lines(text: str) -> list[str]:
    return [line.removesuffix("\r") for line in text.split("\n")]


def code_lines(text: str, keep_strings: bool = False) -> list[str]:
    return scan_lines(text, keep_strings=keep_strings)[0]


# -- Token-stream type annotation & scope analysis -------------------------------------------------------------------


_skip_balanced = luau_lex._skip_balanced
_skip_type_angles = luau_lex._skip_type_angles
_consume_type_expr = luau_lex._consume_type_expr
_mark_type_tokens = luau_lex.mark_type_tokens


def _function_body_start(tokens: list[luau_lex.Token], fn_idx: int, in_type: list[bool]) -> int:
    """Given `tokens[fn_idx]` == `KEYWORD('function')`, return the token index of the first token in its body."""
    n = len(tokens)
    j = fn_idx + 1
    if j < n and tokens[j].kind == "IDENT":
        j += 1
        while j + 1 < n and tokens[j].kind == "OP" and tokens[j].value in (".", ":") and tokens[j + 1].kind == "IDENT":
            j += 2
    while j < n and in_type[j]:
        j += 1
    if j < n and tokens[j].kind == "OP" and tokens[j].value == "(":
        j = _skip_balanced(tokens, j, "(", ")")
    while j < n and in_type[j]:
        j += 1
    return j


def _can_continue_from_prev(tokens: list[luau_lex.Token], first_idx: int, in_type: list[bool]) -> bool:
    """Return True if `tokens[first_idx]` continues the expression from `tokens[first_idx - 1]` across lines."""
    p = first_idx - 1
    while p >= 0 and in_type[p]:
        p -= 1
    if p < 0:
        return False
    prev = tokens[p]
    cur = tokens[first_idx]
    if prev.kind == "OP" and (prev.value in _BINARY_CONTINUATION_OPS or prev.value in _COMPOUND_OPS):
        return True
    if prev.kind == "KEYWORD" and prev.value in (
        "local",
        "const",
        "return",
        "if",
        "elseif",
        "while",
        "until",
        "for",
        "in",
        "and",
        "or",
        "not",
        "function",
    ):
        return True
    # Postfix continuation across newline: `Builder\n{ ... }`, `f\n"str"`, `obj\n:Method()`, `fn\n(x)`
    prev_was_type_angle = first_idx > 0 and tokens[first_idx - 1].kind == "OP" and tokens[first_idx - 1].value == ">" and tokens[first_idx - 1].is_type_angle
    prev_is_callable = (
        prev_was_type_angle
        or prev.kind in ("IDENT", "STRING", "INTERP_FULL", "INTERP_END")
        or (prev.kind == "OP" and prev.value in (")", "]"))
    )
    if prev_is_callable:
        if cur.kind in ("STRING", "INTERP_FULL", "INTERP_BEGIN"):
            return True
        if cur.kind == "OP" and cur.value in ("(", "{", "[", ".", ":"):
            return True
    return False


def _continues_onto_next(tokens: list[luau_lex.Token], last_idx: int, in_type: list[bool], in_if_expr: bool = False) -> bool:
    """Return True if `tokens[last_idx]` continues onto `tokens[last_idx + 1]` across a newline (e.g. `Builder\n{ count = 1 }`)."""
    n = len(tokens)
    last = tokens[last_idx]
    if last.kind == "OP" and (last.value in _BINARY_CONTINUATION_OPS or last.value in _COMPOUND_OPS):
        return True
    if last.kind == "KEYWORD" and last.value in ("local", "const", "if", "elseif", "while", "until", "for", "in", "and", "or", "not", "function"):
        return True

    q = last_idx + 1
    if q < n and in_type[q]:
        # Trailing `:: Type` or `: Type` on the next line continues `last`!
        if tokens[q].kind == "OP" and tokens[q].value in ("::", ":", "->", "|", "&", "?"):
            return True
        while q < n and in_type[q]:
            q += 1
    if q >= n:
        return False
    nxt = tokens[q]
    if nxt.kind in ("STRING", "INTERP_FULL", "INTERP_BEGIN"):
        return True
    if nxt.kind == "OP" and (nxt.value in _NEXT_CONTINUATION_OPS or nxt.value in _COMPOUND_OPS):
        return True
    if nxt.kind == "KEYWORD":
        if nxt.value in ("and", "or", "in"):
            return True
        # `then` / `do` on a following line means a multi-line `if`/`while` condition
        if nxt.value in ("then", "do"):
            return True
        if in_if_expr and nxt.value in ("else", "elseif"):
            return True
    return False


def _match_close_bounded(tokens: list[luau_lex.Token], idx: int, hi: int, open_op: str, close_op: str) -> int:
    """Return token index immediately after matching `close_op` within `tokens[idx:hi]`, or -1 if unmatched."""
    if idx >= hi or tokens[idx].kind != "OP" or tokens[idx].value != open_op or tokens[idx].is_type_angle:
        return -1
    depth = 0
    k = idx
    while k < hi:
        tok = tokens[k]
        if tok.kind == "OP" and not tok.is_type_angle:
            if tok.value == open_op:
                depth += 1
            elif tok.value == close_op:
                depth -= 1
                if depth == 0:
                    return k + 1
        k += 1
    return -1


def _is_remote_handler_start(tokens: list[luau_lex.Token], fn_idx: int) -> bool:
    """Return True if `tokens[fn_idx]` (`function`) starts `.OnServerEvent:Connect(fn)` or `.OnServerInvoke = fn`."""
    if fn_idx >= 4 and tokens[fn_idx - 1].kind == "OP" and tokens[fn_idx - 1].value == "(":
        if (
            tokens[fn_idx - 2].kind == "IDENT"
            and tokens[fn_idx - 2].value in ("Connect", "Once")
            and tokens[fn_idx - 3].kind == "OP"
            and tokens[fn_idx - 3].value == ":"
            and tokens[fn_idx - 4].kind == "IDENT"
            and tokens[fn_idx - 4].value == "OnServerEvent"
        ):
            return True
    if fn_idx >= 3 and tokens[fn_idx - 1].kind == "OP" and tokens[fn_idx - 1].value == "=":
        if (
            tokens[fn_idx - 2].kind == "IDENT"
            and tokens[fn_idx - 2].value == "OnServerInvoke"
            and tokens[fn_idx - 3].kind == "OP"
            and tokens[fn_idx - 3].value == "."
        ):
            return True
    return False


def _find_nil_guard_rhs_end(tokens: list[luau_lex.Token], in_type: list[bool], rhs_lo: int, hi: int) -> int:
    """Find the inclusive token index ending the RHS operand of `or` starting at `rhs_lo`."""
    sub_d = 0
    sub_fn = 0
    sub_if = 0
    for r in range(rhs_lo, hi):
        if in_type[r]:
            continue
        rt = tokens[r]
        if rt.kind == "INTERP_BEGIN":
            sub_d += 1
        elif rt.kind == "INTERP_END":
            if sub_d == 0 and sub_fn == 0:
                return r - 1
            sub_d = max(0, sub_d - 1)
        elif rt.kind == "OP" and not rt.is_type_angle:
            if rt.value in ("(", "{", "["):
                sub_d += 1
            elif rt.value in (")", "}", "]"):
                if sub_d == 0 and sub_fn == 0:
                    return r - 1
                sub_d = max(0, sub_d - 1)
            elif rt.value in (",", ";") and sub_d == 0 and sub_fn == 0 and sub_if == 0:
                return r - 1
        elif rt.kind == "KEYWORD":
            if rt.value == "function":
                sub_fn += 1
            elif rt.value == "end":
                if sub_fn > 0:
                    sub_fn -= 1
                elif sub_d == 0:
                    return r - 1
            elif sub_fn == 0 and sub_d == 0:
                if rt.value == "if":
                    sub_if += 1
                elif rt.value == "else":
                    if sub_if > 0:
                        sub_if -= 1
                    else:
                        return r - 1
                elif rt.value in ("elseif", "then", "or") and sub_if == 0:
                    return r - 1
    return hi - 1


def _is_defensive_len_nonneg(tokens: list[luau_lex.Token], in_type: list[bool], k: int, lo: int, hi: int) -> bool:
    """Return True for defensive `#expr >= 0` or `0 <= #expr` length non-negativity checks."""
    val = tokens[k].value
    if val not in (">=", "<=") or k <= lo or k + 1 >= hi:
        return False

    def _lhs_tokens() -> list[luau_lex.Token]:
        out: list[luau_lex.Token] = []
        depth = 0
        pos = k - 1
        while pos >= lo:
            if not in_type[pos]:
                tk = tokens[pos]
                if tk.kind == "OP" and not tk.is_type_angle:
                    if tk.value in (")", "]", "}"):
                        depth += 1
                    elif tk.value in ("(", "[", "{"):
                        if depth == 0:
                            break
                        depth -= 1
                    elif depth == 0 and tk.value in (",", "=", ";"):
                        break
                elif tk.kind == "KEYWORD" and depth == 0 and tk.value in (
                    "if", "elseif", "then", "else", "while", "until", "do", "return", "and", "or", "not"
                ):
                    break
                out.append(tk)
            pos -= 1
        out.reverse()
        return out

    def _rhs_tokens() -> list[luau_lex.Token]:
        out: list[luau_lex.Token] = []
        depth = 0
        pos = k + 1
        while pos < hi:
            if not in_type[pos]:
                tk = tokens[pos]
                if tk.kind == "OP" and not tk.is_type_angle:
                    if tk.value in ("(", "[", "{"):
                        depth += 1
                    elif tk.value in (")", "]", "}"):
                        if depth == 0:
                            break
                        depth -= 1
                    elif depth == 0 and tk.value in (",", ";"):
                        break
                elif tk.kind == "KEYWORD" and depth == 0 and tk.value in (
                    "then", "else", "elseif", "do", "end", "and", "or"
                ):
                    break
                out.append(tk)
            pos += 1
        return out

    lhs, rhs = _lhs_tokens(), _rhs_tokens()
    if val == ">=":
        return bool(lhs) and lhs[0].kind == "OP" and lhs[0].value == "#" and len(rhs) == 1 and rhs[0].kind == "NUMBER" and rhs[0].value in ("0", "0.0")
    return len(lhs) == 1 and lhs[0].kind == "NUMBER" and lhs[0].value in ("0", "0.0") and bool(rhs) and rhs[0].kind == "OP" and rhs[0].value == "#"


def _is_trivial_nil_guard_rhs(tokens: list[luau_lex.Token], in_type: list[bool], rhs_lo: int, rhs_hi: int) -> bool:
    """Return True when `or <rhs>` falls back only to literal `nil` or `false`."""
    clean = [tokens[idx] for idx in range(rhs_lo, rhs_hi + 1) if not in_type[idx]]
    while len(clean) >= 2 and clean[0].kind == "OP" and clean[0].value == "(":
        close = luau_lex.matching_close(clean, 0)
        if close == len(clean) - 1:
            clean = clean[1:-1]
        else:
            break
    return len(clean) == 1 and clean[0].kind == "KEYWORD" and clean[0].value in ("nil", "false")


def _is_balanced_if_expr(tokens: list[luau_lex.Token], in_type: list[bool], lo: int, hi: int) -> bool:
    """Return True when every Luau `if ... then ... else ...` expression in `[lo, hi)` closes cleanly."""
    fn_depth = 0
    if_depth = 0
    for k in range(lo, hi):
        if in_type[k]:
            continue
        tk = tokens[k]
        if tk.kind != "KEYWORD":
            continue
        if tk.value == "function":
            fn_depth += 1
        elif tk.value == "end":
            if fn_depth > 0:
                fn_depth -= 1
            else:
                return False
        elif fn_depth == 0:
            if tk.value == "if":
                if_depth += 1
            elif tk.value == "then":
                if if_depth <= 0:
                    return False
            elif tk.value == "else":
                if if_depth <= 0:
                    return False
                if_depth -= 1
            elif tk.value in ("do", "repeat", "until"):
                return False
    return if_depth == 0 and fn_depth == 0


def _expr_mutants(
    tokens: list[luau_lex.Token],
    in_type: list[bool],
    lo: int,
    hi: int,
    source: str,
    ops: set[str],
    *,
    skip_simple_eq: bool = False,
    allow_nil_guard: bool = False,
    in_remote: bool = False,
) -> list[tuple[str, str]]:
    """Generate `(op_name, mutated_expr_src)` pairs for expression slice `tokens[lo:hi]` using exact token spans."""
    if lo >= hi:
        return []
    expr_start = tokens[lo].start
    expr_end = tokens[hi - 1].end
    base_src = source[expr_start:expr_end]

    has_logic = False
    fn_depth = 0
    for k in range(lo, hi):
        if in_type[k]:
            continue
        tk = tokens[k]
        if tk.kind == "KEYWORD":
            if tk.value == "function":
                fn_depth += 1
            elif tk.value == "end" and fn_depth > 0:
                fn_depth -= 1
            elif fn_depth == 0 and tk.value in ("and", "or"):
                has_logic = True

    rel_muts: list[tuple[str, str]] = []
    cond_muts: list[tuple[str, str]] = []
    arith_muts: list[tuple[str, str]] = []
    logic_muts: list[tuple[str, str]] = []
    math_muts: list[tuple[str, str]] = []
    off_by_one_muts: list[tuple[str, str]] = []
    nil_guard_muts: list[tuple[str, str]] = []
    remote_guard_muts: list[tuple[str, str]] = []

    def replace_span(s_off: int, e_off: int, replacement: str) -> str:
        rel_s = s_off - expr_start
        rel_e = e_off - expr_start
        left = base_src[:rel_s]
        right = base_src[rel_e:]
        if not replacement:
            return left + right
        # Avoid merging tokens such as `--` comment or `..` if tight without whitespace
        if replacement.startswith("-") and right.startswith("-"):
            replacement = replacement + " "
        if replacement[0].isalpha() and left and (left[-1].isalnum() or left[-1] == "_"):
            replacement = " " + replacement
        if replacement[-1].isalpha() and right and (right[0].isalnum() or right[0] == "_"):
            replacement = replacement + " "
        return left + replacement + right

    fn_depth = 0
    ternary_cond_depth = 0
    for k in range(lo, hi):
        if in_type[k]:
            continue
        tok = tokens[k]
        if tok.kind == "KEYWORD":
            if tok.value == "function":
                fn_depth += 1
                continue
            if tok.value == "end" and fn_depth > 0:
                fn_depth -= 1
                continue
        if fn_depth > 0:
            continue
        if tok.kind == "KEYWORD":
            if tok.value in ("if", "elseif"):
                if "cond_inv" in ops and k + 1 < hi:
                    t_idx = k + 1
                    sub_fn = 0
                    sub_if = 0
                    found_then = -1
                    while t_idx < hi:
                        if not in_type[t_idx]:
                            ttk = tokens[t_idx]
                            if ttk.kind == "KEYWORD":
                                if ttk.value == "function":
                                    sub_fn += 1
                                elif ttk.value == "end" and sub_fn > 0:
                                    sub_fn -= 1
                                elif sub_fn == 0:
                                    if ttk.value == "if":
                                        sub_if += 1
                                    elif ttk.value == "else" and sub_if > 0:
                                        sub_if -= 1
                                    elif ttk.value == "then" and sub_if == 0:
                                        found_then = t_idx
                                        break
                        t_idx += 1
                    if found_then > k + 1:
                        c_start = tokens[k + 1].start
                        c_end = tokens[found_then - 1].end
                        c_txt = source[c_start:c_end].strip()
                        if c_txt not in ("true", "false"):
                            cond_muts.append(("cond_inv", replace_span(c_start, c_end, f"not ({c_txt})")))
                ternary_cond_depth += 1
            elif tok.value == "then" and ternary_cond_depth > 0:
                ternary_cond_depth -= 1

        # 1. Relational flip (`rel_flip`) — never touches `tok.is_type_angle` or defensive `#len >= 0`!
        if "rel_flip" in ops and tok.kind == "OP" and not tok.is_type_angle and tok.value in _FLIP_MAP:
            if not (skip_simple_eq and not has_logic and tok.value in ("==", "~=")) and not _is_defensive_len_nonneg(
                tokens, in_type, k, lo, hi
            ):
                rel_muts.append(("rel_flip", replace_span(tok.start, tok.end, _FLIP_MAP[tok.value])))

        # 2. Arithmetic flip (`arith_op`) — distinguishes binary `-` from unary `-`!
        if "arith_op" in ops and tok.kind == "OP" and tok.value in _ARITH_MAP:
            is_binary = True
            if tok.value == "-":
                if k == lo:
                    is_binary = False
                else:
                    prev = tokens[k - 1]
                    if in_type[k - 1]:
                        # `(x :: number) - 1` or `x :: number - 1`: `prev` ends a cast on an operand!
                        is_binary = True
                    elif prev.kind in ("IDENT", "NUMBER", "STRING", "INTERP_FULL", "INTERP_END"):
                        is_binary = True
                    elif prev.kind == "OP" and prev.value in _OPERAND_END_OPS:
                        is_binary = True
                    elif prev.kind == "KEYWORD" and prev.value in ("true", "false", "nil"):
                        is_binary = True
                    else:
                        is_binary = False
            if is_binary:
                arith_muts.append(("arith_op", replace_span(tok.start, tok.end, _ARITH_MAP[tok.value])))

        # 3. Logical operator flip (`logic_op`)
        if "logic_op" in ops and tok.kind == "KEYWORD" and tok.value in _LOGIC_MAP:
            logic_muts.append(("logic_op", replace_span(tok.start, tok.end, _LOGIC_MAP[tok.value])))

        # 4. Math function flip (`math_fn`)
        if (
            "math_fn" in ops
            and tok.kind == "IDENT"
            and tok.value == "math"
            and k + 3 < hi
            and tokens[k + 1].kind == "OP"
            and tokens[k + 1].value == "."
            and tokens[k + 2].kind == "IDENT"
            and tokens[k + 2].value in _MATH_FN_MAP
            and tokens[k + 3].kind == "OP"
            and tokens[k + 3].value == "("
        ):
            fn_tok = tokens[k + 2]
            math_muts.append(("math_fn", replace_span(fn_tok.start, fn_tok.end, _MATH_FN_MAP[fn_tok.value])))

        # 5. Off-by-one length operator (`off_by_one`): `#ident` -> `(#ident - 1)`
        if (
            "off_by_one" in ops
            and tok.kind == "OP"
            and tok.value == "#"
            and k + 1 < hi
            and not in_type[k + 1]
            and tokens[k + 1].kind == "IDENT"
            and (k == lo or not (tokens[k - 1].kind == "OP" and tokens[k - 1].value in (".", ":")))
        ):
            cur = k + 2
            unsafe = False
            while cur < hi and not in_type[cur]:
                nt = tokens[cur]
                if nt.kind == "OP" and not nt.is_type_angle and nt.value == "." and cur + 1 < hi and tokens[cur + 1].kind == "IDENT":
                    cur += 2
                    continue
                if nt.kind == "OP" and not nt.is_type_angle and nt.value == "[":
                    nxt = _match_close_bounded(tokens, cur, hi, "[", "]")
                    if nxt < 0:
                        unsafe = True
                        break
                    cur = nxt
                    continue
                if nt.kind == "OP" and not nt.is_type_angle and nt.value == "(":
                    nxt = _match_close_bounded(tokens, cur, hi, "(", ")")
                    if nxt < 0:
                        unsafe = True
                        break
                    cur = nxt
                    continue
                if (
                    nt.kind == "OP"
                    and not nt.is_type_angle
                    and nt.value == ":"
                    and cur + 2 < hi
                    and tokens[cur + 1].kind == "IDENT"
                    and tokens[cur + 2].kind == "OP"
                    and tokens[cur + 2].value == "("
                ):
                    nxt = _match_close_bounded(tokens, cur + 2, hi, "(", ")")
                    if nxt < 0:
                        unsafe = True
                        break
                    cur = nxt
                    continue
                if nt.kind == "OP" and not nt.is_type_angle and nt.value in (":", "{"):
                    unsafe = True
                elif nt.kind in ("STRING", "INTERP_FULL", "INTERP_BEGIN"):
                    unsafe = True
                break
            if not unsafe:
                target_src = source[tok.start : tokens[cur - 1].end]
                off_by_one_muts.append(("off_by_one", replace_span(tok.start, tokens[cur - 1].end, f"({target_src} - 1)")))

        # 6. Nil fallback deletion (`nil_guard`): `lhs or rhs` -> `lhs` on assignment RHS / `return`
        if (
            allow_nil_guard
            and "nil_guard" in ops
            and ternary_cond_depth == 0
            and tok.kind == "KEYWORD"
            and tok.value == "or"
            and k > lo
            and k + 1 < hi
        ):
            rhs_last = _find_nil_guard_rhs_end(tokens, in_type, k + 1, hi)
            if rhs_last >= k + 1 and not _is_trivial_nil_guard_rhs(tokens, in_type, k + 1, rhs_last):
                nil_guard_muts.append(("nil_guard", replace_span(tokens[k - 1].end, tokens[rhs_last].end, "")))

        # 7. Remote handler runtime type guard removal (`remote_guard`)
        if in_remote and "remote_guard" in ops:
            if (
                tok.kind == "IDENT"
                and tok.value in ("type", "typeof")
                and (k == lo or not (tokens[k - 1].kind == "OP" and tokens[k - 1].value in (".", ":")))
                and k + 1 < hi
                and tokens[k + 1].kind == "OP"
                and tokens[k + 1].value == "("
            ):
                after_p = _match_close_bounded(tokens, k + 1, hi, "(", ")")
                if after_p > k + 3 and after_p + 1 < hi:
                    op_tok = tokens[after_p]
                    rhs_tok = tokens[after_p + 1]
                    if (
                        op_tok.kind == "OP"
                        and not op_tok.is_type_angle
                        and op_tok.value in ("==", "~=")
                        and rhs_tok.kind == "STRING"
                        and (
                            after_p + 2 >= hi
                            or in_type[after_p + 2]
                            or not (
                                tokens[after_p + 2].kind == "OP"
                                and not tokens[after_p + 2].is_type_angle
                                and tokens[after_p + 2].value in (".", ":", "..", "^", "*", "/", "//", "%", "+", "-")
                            )
                        )
                    ):
                        rep = "true" if op_tok.value == "==" else "false"
                        remote_guard_muts.append(("remote_guard", replace_span(tok.start, rhs_tok.end, rep)))
            elif (
                tok.kind == "STRING"
                and (
                    k == lo
                    or in_type[k - 1]
                    or not (
                        tokens[k - 1].kind == "OP"
                        and not tokens[k - 1].is_type_angle
                        and tokens[k - 1].value in (".", ":", "..", "^", "*", "/", "//", "%", "+", "-")
                    )
                )
                and k + 4 < hi
                and tokens[k + 1].kind == "OP"
                and not tokens[k + 1].is_type_angle
                and tokens[k + 1].value in ("==", "~=")
                and tokens[k + 2].kind == "IDENT"
                and tokens[k + 2].value in ("type", "typeof")
                and tokens[k + 3].kind == "OP"
                and tokens[k + 3].value == "("
            ):
                after_p = _match_close_bounded(tokens, k + 3, hi, "(", ")")
                if after_p > k + 4 and (
                    after_p >= hi
                    or in_type[after_p]
                    or not (
                        tokens[after_p].kind == "OP"
                        and not tokens[after_p].is_type_angle
                        and tokens[after_p].value in (".", ":", "(", "[", "..", "^", "*", "/", "//", "%", "+", "-")
                    )
                ):
                    rep = "true" if tokens[k + 1].value == "==" else "false"
                    remote_guard_muts.append(("remote_guard", replace_span(tok.start, tokens[after_p - 1].end, rep)))

    return rel_muts + cond_muts + arith_muts + logic_muts + math_muts + off_by_one_muts + nil_guard_muts + remote_guard_muts


def _split_top_level_commas(tokens: list[luau_lex.Token], in_type: list[bool], lo: int, hi: int) -> list[tuple[int, int]]:
    """Split `tokens[lo:hi]` into `(seg_lo, seg_hi)` slices separated by depth-0 commas."""
    segments: list[tuple[int, int]] = []
    depth = 0
    fn_depth = 0
    cur_lo = lo
    for k in range(lo, hi):
        if in_type[k]:
            continue
        tk = tokens[k]
        if tk.kind == "KEYWORD":
            if tk.value in ("function", "do", "repeat") or (tk.value == "if" and luau_lex.is_if_statement(tokens, k, in_type)):
                fn_depth += 1
            elif tk.value in ("end", "until") and fn_depth > 0:
                fn_depth -= 1
        elif tk.kind in ("INTERP_BEGIN",):
            depth += 1
        elif tk.kind in ("INTERP_END",):
            depth = max(0, depth - 1)
        elif tk.kind == "OP" and not tk.is_type_angle:
            if tk.value in ("(", "{", "["):
                depth += 1
            elif tk.value in (")", "}", "]"):
                depth = max(0, depth - 1)
            elif tk.value == "," and depth == 0 and fn_depth == 0:
                if cur_lo < k:
                    segments.append((cur_lo, k))
                cur_lo = k + 1
    if cur_lo < hi:
        segments.append((cur_lo, hi))
    return segments


def _has_block_statements(tokens: list[luau_lex.Token], in_type: list[bool], lo: int, hi: int) -> bool:
    """Return True if `tokens[lo:hi]` contains block-level keywords (`do`, `repeat`, `end`) outside closures."""
    fn_depth = 0
    for k in range(lo, hi):
        if in_type[k]:
            continue
        tk = tokens[k]
        if tk.kind == "KEYWORD":
            if tk.value == "function":
                fn_depth += 1
            elif tk.value == "end":
                if fn_depth > 0:
                    fn_depth -= 1
                else:
                    return True
            elif fn_depth == 0 and tk.value in ("do", "repeat"):
                return True
    return False


def _wrap_trace(trace_key: int, stmt: str) -> str:
    return f"if {SWITCH} == -1 then _SERT_M.h({trace_key}) end {stmt}"


def _mutate_token_slice(
    tokens: list[luau_lex.Token],
    in_type: list[bool],
    lo: int,
    hi: int,
    source: str,
    ops: set[str],
    room,
    add_mutant,
    extra_benign_res: list[re.Pattern[str]],
    extra_cosmetic_re: re.Pattern[str] | None,
    *,
    is_early_guard: bool = False,
    in_remote: bool = False,
) -> str | None:
    """Mutate a single statement token slice `tokens[lo:hi]`, returning the replacement Luau statement text (without indent)."""
    if lo >= hi:
        return None
    first = tokens[lo]
    last = tokens[hi - 1]
    stmt_src = source[first.start : last.end]

    # Reject multi-statement semicolon lines
    depth = 0
    for k in range(lo, hi):
        if in_type[k]:
            continue
        tk = tokens[k]
        if tk.kind == "OP" and not tk.is_type_angle:
            if tk.value in ("(", "{", "["):
                depth += 1
            elif tk.value in (")", "}", "]"):
                depth = max(0, depth - 1)
            elif tk.value == ";" and depth == 0:
                return None

    # 1. `if <cond> then` / `elseif <cond> then` / `while <cond> do` / `until <cond>` (+ single-line `... end`)
    if first.kind == "KEYWORD" and first.value in ("if", "elseif", "while", "until"):
        kw = first.value
        if kw in ("if", "while") and last.kind == "KEYWORD" and last.value == "end" and hi - lo >= 5:
            expected_end = "do" if kw == "while" else "then"
            sep_idx = -1
            c_depth = 0
            if_expr_depth = 0
            bad_single = False
            for k in range(lo + 1, hi - 1):
                if in_type[k]:
                    continue
                tk = tokens[k]
                if tk.kind == "INTERP_BEGIN":
                    c_depth += 1
                elif tk.kind == "INTERP_END":
                    c_depth = max(0, c_depth - 1)
                elif tk.kind == "OP" and not tk.is_type_angle:
                    if tk.value in ("(", "{", "["):
                        c_depth += 1
                    elif tk.value in (")", "}", "]"):
                        c_depth = max(0, c_depth - 1)
                elif tk.kind == "KEYWORD" and c_depth == 0:
                    if tk.value == "if":
                        if_expr_depth += 1
                    elif tk.value == "else" and if_expr_depth > 0:
                        if_expr_depth -= 1
                    elif tk.value == expected_end and if_expr_depth == 0:
                        sep_idx = k
                        break
                    elif tk.value in ("then", "elseif") and if_expr_depth > 0:
                        continue
                    elif tk.value in ("then", "elseif", "else", "do", "end", "repeat", "function"):
                        bad_single = True
                        break
            body_lo = sep_idx + 1
            body_hi = hi - 1
            if (
                not bad_single
                and if_expr_depth == 0
                and c_depth == 0
                and sep_idx > lo + 1
                and body_lo < body_hi
                and not _has_block_statements(tokens, in_type, body_lo, body_hi)
            ):
                # Reject nested `else` / `elseif` inside the single-line body outside ternary expressions.
                has_top_branch = not _is_balanced_if_expr(tokens, in_type, body_lo, body_hi)
                if not has_top_branch:
                    cond_lo, cond_hi = lo + 1, sep_idx
                    cond_src = source[tokens[cond_lo].start : tokens[cond_hi - 1].end]
                    body_src = source[tokens[body_lo].start : tokens[body_hi - 1].end]
                    cond_muts: list[tuple[str, str, str]] = []
                    has_cond_inv = False
                    is_trivial_loop_const = kw == "while" and cond_src.strip() in ("true", "false")
                    if "cond_inv" in ops and not is_trivial_loop_const and room(len(cond_muts)):
                        has_cond_inv = True
                        desc = f"{kw} not ({cond_src}) {expected_end} {body_src} end"
                        cond_muts.append(("cond_inv", f"not ({cond_src})", desc))
                    for op_name, mut_expr in _expr_mutants(
                        tokens,
                        in_type,
                        cond_lo,
                        cond_hi,
                        source,
                        ops,
                        skip_simple_eq=has_cond_inv,
                        in_remote=in_remote,
                    ):
                        if not room(len(cond_muts)):
                            break
                        desc = f"{kw} {mut_expr} {expected_end} {body_src} end"
                        cond_muts.append((op_name, f"({mut_expr})", desc))

                    cond_expr_out = cond_src
                    if cond_muts:
                        trace_key: int | None = None
                        branches: list[str] = []
                        for idx, (op_name, expr, desc) in enumerate(cond_muts):
                            mid = add_mutant(op_name, stmt_src, desc, trace_key=trace_key)
                            if trace_key is None:
                                trace_key = mid
                            branches.append(f"{'if' if idx == 0 else 'elseif'} {SWITCH} == {mid} then {expr}")
                        cond_expr_out = f"({' '.join(branches)} elseif {SWITCH} == -1 and _SERT_M.h({trace_key}) then false else ({cond_src}))"

                    body_repl = _mutate_token_slice(
                        tokens,
                        in_type,
                        body_lo,
                        body_hi,
                        source,
                        ops,
                        room,
                        add_mutant,
                        extra_benign_res,
                        extra_cosmetic_re,
                        is_early_guard=(kw == "if"),
                        in_remote=in_remote,
                    )
                    if not cond_muts and body_repl is None:
                        return None
                    return f"{kw} {cond_expr_out} {expected_end} {body_repl or body_src} end"
            return None

        if kw in ("if", "elseif", "while"):
            expected_end = "do" if kw == "while" else "then"
            if last.kind != "KEYWORD" or last.value != expected_end or hi - lo < 3:
                return None
            cond_lo, cond_hi = lo + 1, hi - 1
            closer_suffix = f" {expected_end}"
        else:
            if hi - lo < 2:
                return None
            cond_lo, cond_hi = lo + 1, hi
            closer_suffix = ""

        # Ensure condition doesn't contain another top-level `then` / `do` / `else` / `end` outside parens/if-exprs
        c_depth = 0
        if_expr_depth = 0
        bad_cond = False
        for k in range(cond_lo, cond_hi):
            if in_type[k]:
                continue
            tk = tokens[k]
            if tk.kind in ("INTERP_BEGIN",):
                c_depth += 1
            elif tk.kind in ("INTERP_END",):
                c_depth = max(0, c_depth - 1)
            elif tk.kind == "OP" and not tk.is_type_angle:
                if tk.value in ("(", "{", "["):
                    c_depth += 1
                elif tk.value in (")", "}", "]"):
                    c_depth = max(0, c_depth - 1)
            elif tk.kind == "KEYWORD" and c_depth == 0:
                if tk.value == "if":
                    if_expr_depth += 1
                elif tk.value == "else" and if_expr_depth > 0:
                    if_expr_depth -= 1
                elif tk.value in ("then", "elseif") and if_expr_depth > 0:
                    continue
                elif tk.value in ("then", "do", "else", "end", "repeat", "function"):
                    bad_cond = True
                    break
        if bad_cond or if_expr_depth != 0:
            return None

        cond_src = source[tokens[cond_lo].start : tokens[cond_hi - 1].end]
        line_mutants: list[tuple[str, str, str]] = []
        has_cond_inv = False
        is_trivial_loop_const = kw in ("while", "until") and cond_src.strip() in ("true", "false")
        if "cond_inv" in ops and not is_trivial_loop_const and room(len(line_mutants)):
            has_cond_inv = True
            desc = f"{kw} not ({cond_src}){closer_suffix}"
            line_mutants.append(("cond_inv", f"not ({cond_src})", desc))

        for op_name, mut_expr in _expr_mutants(
            tokens,
            in_type,
            cond_lo,
            cond_hi,
            source,
            ops,
            skip_simple_eq=has_cond_inv,
            in_remote=in_remote,
        ):
            if not room(len(line_mutants)):
                break
            desc = f"{kw} {mut_expr}{closer_suffix}"
            line_mutants.append((op_name, f"({mut_expr})", desc))

        if not line_mutants:
            return None
        trace_key: int | None = None
        branches: list[str] = []
        for idx, (op_name, expr, desc) in enumerate(line_mutants):
            mid = add_mutant(op_name, stmt_src, desc, trace_key=trace_key)
            if trace_key is None:
                trace_key = mid
            branches.append(f"{'if' if idx == 0 else 'elseif'} {SWITCH} == {mid} then {expr}")
        return f"{kw} ({' '.join(branches)} elseif {SWITCH} == -1 and _SERT_M.h({trace_key}) then false else ({cond_src})){closer_suffix}"

    # 2. `return ...`
    if first.kind == "KEYWORD" and first.value == "return":
        if hi - lo <= 1 or _has_block_statements(tokens, in_type, lo + 1, hi):
            return None
        ret_segs = _split_top_level_commas(tokens, in_type, lo + 1, hi)
        if not ret_segs:
            return None
        first_seg_lo, first_seg_hi = ret_segs[0]
        first_seg_src = source[tokens[first_seg_lo].start : tokens[first_seg_hi - 1].end].strip()
        rhs_full_src = source[tokens[lo + 1].start : last.end]

        # `return nil` (or `return nil, ...`)
        if first_seg_src == "nil" and len(ret_segs) == 1:
            return None

        # `return true [, rest]` / `return false [, rest]`
        if first_seg_hi - first_seg_lo == 1 and tokens[first_seg_lo].kind == "KEYWORD" and tokens[first_seg_lo].value in ("true", "false"):
            val = tokens[first_seg_lo].value
            inv = "false" if val == "true" else "true"
            if len(ret_segs) == 1:
                if "ret_val" in ops and room():
                    mid = add_mutant("ret_val", stmt_src, f"return {inv}")
                    return _wrap_trace(mid, f"return if {SWITCH} == {mid} then {inv} else {val}")
                return None
            rest_src = source[tokens[ret_segs[1][0]].start : last.end]
            ret_branches: list[tuple[str, str]] = []
            if "ret_val" in ops and room():
                ret_branches.append(("ret_val", f"return {inv}"))
            for seg_idx in range(1, len(ret_segs)):
                s_lo, s_hi = ret_segs[seg_idx]
                for op_name, mut_e in _expr_mutants(
                    tokens, in_type, s_lo, s_hi, source, ops, allow_nil_guard=True, in_remote=in_remote
                ):
                    if not room(len(ret_branches)):
                        break
                    rebuilt = [
                        mut_e if j == seg_idx else source[tokens[r_lo].start : tokens[r_hi - 1].end]
                        for j, (r_lo, r_hi) in enumerate(ret_segs)
                    ]
                    ret_branches.append((op_name, f"return {', '.join(rebuilt)}"))
            if not ret_branches:
                return None
            if len(ret_branches) == 1 and ret_branches[0][0] == "ret_val":
                mid = add_mutant("ret_val", stmt_src, f"return {inv}")
                return _wrap_trace(mid, f"if {SWITCH} == {mid} then return {inv} end return {val}, {rest_src}")
            trace_key = None
            conds: list[str] = []
            for idx, (op_n, r_stmt) in enumerate(ret_branches):
                mid = add_mutant(op_n, stmt_src, r_stmt, trace_key=trace_key)
                if trace_key is None:
                    trace_key = mid
                conds.append(f"{'if' if idx == 0 else 'elseif'} {SWITCH} == {mid} then {r_stmt}")
            assert trace_key is not None
            return _wrap_trace(trace_key, f"{' '.join(conds)} end return {rhs_full_src}")

        # General single or multi-expression `return expr1, expr2, ...` (including inline `if ... then ... else ...`)
        if tokens[lo + 1].kind == "KEYWORD" and tokens[lo + 1].value == "if" and not _is_balanced_if_expr(tokens, in_type, lo + 1, hi):
            return None
        # Skip `return function(...) ... end` (its inner statements are mutated instead!)
        if len(ret_segs) == 1 and tokens[lo + 1].kind == "KEYWORD" and tokens[lo + 1].value == "function":
            return None

        ret_muts: list[tuple[str, str]] = []
        has_bool_expr_flip = False
        for seg_idx, (s_lo, s_hi) in enumerate(ret_segs):
            for op_name, mut_e in _expr_mutants(
                tokens, in_type, s_lo, s_hi, source, ops, allow_nil_guard=True, in_remote=in_remote
            ):
                if not room(len(ret_muts)):
                    break
                if op_name in ("rel_flip", "logic_op") and len(ret_segs) == 1:
                    has_bool_expr_flip = True
                rebuilt = [
                    mut_e if j == seg_idx else source[tokens[r_lo].start : tokens[r_hi - 1].end]
                    for j, (r_lo, r_hi) in enumerate(ret_segs)
                ]
                ret_muts.append((op_name, f"return {', '.join(rebuilt)}"))

        is_benign_tail = (
            tokens[lo + 1].kind in ("STRING", "INTERP_FULL", "INTERP_BEGIN")
            or bool(_BENIGN_CALL_RE.match(rhs_full_src))
            or bool(re.search(r"(?:^select\s*\(\s*2\s*,|:(?:Connect|Once|Wait|Fire|Destroy)\s*\(|\bcleanup\s*\()", rhs_full_src))
        )
        if (
            "ret_val" in ops
            and not is_early_guard
            and not is_benign_tail
            and not has_bool_expr_flip
            and first_seg_src != "nil"
            and room(len(ret_muts))
        ):
            ret_muts.append(("ret_val", "return nil"))

        if not ret_muts:
            return None
        trace_key = None
        conds = []
        for idx, (op_n, r_stmt) in enumerate(ret_muts):
            mid = add_mutant(op_n, stmt_src, r_stmt, trace_key=trace_key)
            if trace_key is None:
                trace_key = mid
            conds.append(f"{'if' if idx == 0 else 'elseif'} {SWITCH} == {mid} then {r_stmt}")
        assert trace_key is not None
        return _wrap_trace(trace_key, f"{' '.join(conds)} end return {rhs_full_src}")

    # 3. `local` / `const` variable bindings (`local x: number = a + b`, `const x = a + b`, `local a: T, b: U = e1, e2`)
    if first.kind == "KEYWORD" and first.value in ("local", "const"):
        if lo + 1 >= hi or tokens[lo + 1].kind == "KEYWORD":
            return None
        eq_idx = -1
        d = 0
        lhs_commas = 0
        for k in range(lo + 1, hi):
            if in_type[k]:
                continue
            tk = tokens[k]
            if tk.kind == "OP" and not tk.is_type_angle:
                if tk.value in ("(", "{", "["):
                    d += 1
                elif tk.value in (")", "}", "]"):
                    d = max(0, d - 1)
                elif tk.value == "," and d == 0:
                    lhs_commas += 1
                elif tk.value == "=" and d == 0:
                    eq_idx = k
                    break
        if eq_idx < 0 or eq_idx + 1 >= hi:
            return None
        if _has_block_statements(tokens, in_type, eq_idx + 1, hi):
            return None
        # Skip `local f = function(...)` and unbalanced multi-line `local v = if ...` expressions
        if tokens[eq_idx + 1].kind == "KEYWORD" and tokens[eq_idx + 1].value == "function":
            return None
        if tokens[eq_idx + 1].kind == "KEYWORD" and tokens[eq_idx + 1].value == "if" and not _is_balanced_if_expr(tokens, in_type, eq_idx + 1, hi):
            return None

        lhs_decl = source[first.start : tokens[eq_idx].start].rstrip()
        num_lhs = lhs_commas + 1
        rhs_segs = _split_top_level_commas(tokens, in_type, eq_idx + 1, hi)
        if not rhs_segs:
            return None

        if num_lhs == 1 and len(rhs_segs) == 1:
            r_lo, r_hi = rhs_segs[0]
            rhs_src = source[tokens[r_lo].start : tokens[r_hi - 1].end]
            expr_muts = _expr_mutants(
                tokens, in_type, r_lo, r_hi, source, ops, allow_nil_guard=True, in_remote=in_remote
            )
            chosen: list[tuple[str, str]] = []
            for op_name, mut_rhs in expr_muts:
                if not room(len(chosen)):
                    break
                chosen.append((op_name, mut_rhs))
            if not chosen:
                return None
            trace_key = None
            branches = []
            for idx, (op_name, mut_rhs) in enumerate(chosen):
                mid = add_mutant(op_name, stmt_src, f"{lhs_decl} = {mut_rhs}", trace_key=trace_key)
                if trace_key is None:
                    trace_key = mid
                branches.append(f"{'if' if idx == 0 else 'elseif'} {SWITCH} == {mid} then ({mut_rhs})")
            assert trace_key is not None
            return _wrap_trace(trace_key, f"{lhs_decl} = {' '.join(branches)} else ({rhs_src})")

        # Multi-RHS `local a: number, b: number = x + 1, y - 1`
        rebuilt_parts: list[str] = []
        pending_count = 0
        any_changed = False
        first_multi_id: int | None = None
        for seg_idx, (r_lo, r_hi) in enumerate(rhs_segs):
            seg_src = source[tokens[r_lo].start : tokens[r_hi - 1].end]
            # Do not parenthesize the final RHS expression if it must expand multiple return values into remaining LHS vars
            if seg_idx == len(rhs_segs) - 1 and num_lhs > len(rhs_segs):
                rebuilt_parts.append(seg_src)
                continue
            seg_muts = _expr_mutants(
                tokens, in_type, r_lo, r_hi, source, ops, allow_nil_guard=True, in_remote=in_remote
            )
            picked: list[tuple[str, str]] = []
            for op_name, mut_rhs in seg_muts:
                if not room(pending_count + len(picked)):
                    break
                picked.append((op_name, mut_rhs))
            if not picked:
                rebuilt_parts.append(seg_src)
                continue
            any_changed = True
            pending_count += len(picked)
            branches = []
            for idx, (op_name, mut_rhs) in enumerate(picked):
                preview_rhs = ", ".join(
                    mut_rhs if j == seg_idx else source[tokens[x_lo].start : tokens[x_hi - 1].end]
                    for j, (x_lo, x_hi) in enumerate(rhs_segs)
                )
                mid = add_mutant(op_name, stmt_src, f"{lhs_decl} = {preview_rhs}", trace_key=first_multi_id)
                if first_multi_id is None:
                    first_multi_id = mid
                branches.append(f"{'if' if idx == 0 else 'elseif'} {SWITCH} == {mid} then ({mut_rhs})")
            rebuilt_parts.append(f"({' '.join(branches)} else ({seg_src}))")

        if not any_changed:
            return None
        assert first_multi_id is not None
        return _wrap_trace(first_multi_id, f"{lhs_decl} = {', '.join(rebuilt_parts)}")

    # 3b. Numeric `for i = start, #x [, step] do` (`off_by_one`)
    if first.kind == "KEYWORD" and first.value == "for":
        if "off_by_one" not in ops or last.kind != "KEYWORD" or last.value != "do" or hi - lo < 7:
            return None
        eq_idx = -1
        for k in range(lo + 1, hi - 1):
            if in_type[k]:
                continue
            tk = tokens[k]
            if tk.kind == "KEYWORD" and tk.value == "in":
                return None
            if tk.kind == "OP" and not tk.is_type_angle and tk.value == "=":
                eq_idx = k
                break
        if eq_idx <= lo + 1 or eq_idx + 1 >= hi - 1:
            return None
        if _has_block_statements(tokens, in_type, eq_idx + 1, hi - 1):
            return None
        segs = _split_top_level_commas(tokens, in_type, eq_idx + 1, hi - 1)
        if len(segs) not in (2, 3):
            return None
        lim_lo, lim_hi = segs[1]
        if lim_lo >= lim_hi:
            return None
        lim_muts = _expr_mutants(tokens, in_type, lim_lo, lim_hi, source, {"off_by_one"})
        chosen_lim: list[tuple[str, str]] = []
        for op_name, mut_lim in lim_muts:
            if not room(len(chosen_lim)):
                break
            chosen_lim.append((op_name, mut_lim))
        if not chosen_lim:
            return None
        header_prefix = source[first.start : tokens[lim_lo].start]
        header_suffix = source[tokens[lim_hi - 1].end : last.end]
        lim_src = source[tokens[lim_lo].start : tokens[lim_hi - 1].end]
        branches: list[str] = []
        first_for_id: int | None = None
        for idx, (op_name, mut_lim) in enumerate(chosen_lim):
            preview_lim = (
                mut_lim[1:-1] if (mut_lim.startswith("(") and mut_lim.endswith(")") and lim_src.startswith("#")) else mut_lim
            )
            mid = add_mutant(op_name, stmt_src, f"{header_prefix}{preview_lim}{header_suffix}", trace_key=first_for_id)
            if first_for_id is None:
                first_for_id = mid
            branches.append(f"{'if' if idx == 0 else 'elseif'} {SWITCH} == {mid} then {mut_lim}")
        assert first_for_id is not None
        return _wrap_trace(first_for_id, f"{header_prefix}({' '.join(branches)} else ({lim_src})){header_suffix}")

    # Skip other control keywords (`do`, `repeat`, `end`, `else`, `break`, `continue`, `function`, `export`, `type`)
    if first.kind == "KEYWORD":
        return None

    # 4. Assignments (`lhs = rhs`) & Compound assignments (`lhs += rhs`, `-=`, `*=`, `/=`, `//=`, `%=`, `..=`)
    assign_idx = -1
    assign_op = ""
    d = 0
    for k in range(lo, hi):
        if in_type[k]:
            continue
        tk = tokens[k]
        if tk.kind in ("INTERP_BEGIN",):
            d += 1
        elif tk.kind in ("INTERP_END",):
            d = max(0, d - 1)
        elif tk.kind == "OP" and not tk.is_type_angle:
            if tk.value in ("(", "{", "["):
                d += 1
            elif tk.value in (")", "}", "]"):
                d = max(0, d - 1)
            elif d == 0 and (tk.value == "=" or tk.value in _COMPOUND_OPS):
                assign_idx = k
                assign_op = tk.value
                break

    if assign_idx > lo and assign_idx + 1 < hi:
        if _has_block_statements(tokens, in_type, assign_idx + 1, hi):
            return None
        if tokens[assign_idx + 1].kind == "KEYWORD" and tokens[assign_idx + 1].value == "function":
            return None
        if (
            tokens[assign_idx + 1].kind == "KEYWORD"
            and tokens[assign_idx + 1].value == "if"
            and not _is_balanced_if_expr(tokens, in_type, assign_idx + 1, hi)
        ):
            return None
        lhs_src = source[first.start : tokens[assign_idx].start].rstrip()
        rhs_lo, rhs_hi = assign_idx + 1, hi
        rhs_src = source[tokens[rhs_lo].start : last.end]
        is_cosmetic = bool(_COSMETIC_PROP_RE.search(lhs_src)) or bool(extra_cosmetic_re and extra_cosmetic_re.search(lhs_src))

        stmt_muts: list[tuple[str, str]] = []
        if assign_op in _COMPOUND_FLIP_MAP and "arith_op" in ops and room(len(stmt_muts)):
            flipped_op = _COMPOUND_FLIP_MAP[assign_op]
            stmt_muts.append(("arith_op", f"{lhs_src} {flipped_op} {rhs_src}"))

        rhs_segs = _split_top_level_commas(tokens, in_type, rhs_lo, rhs_hi)
        for seg_idx, (s_lo, s_hi) in enumerate(rhs_segs):
            for op_name, mut_e in _expr_mutants(
                tokens, in_type, s_lo, s_hi, source, ops, allow_nil_guard=True, in_remote=in_remote
            ):
                if not room(len(stmt_muts)):
                    break
                rebuilt_rhs = ", ".join(
                    mut_e if j == seg_idx else source[tokens[r_lo].start : tokens[r_hi - 1].end]
                    for j, (r_lo, r_hi) in enumerate(rhs_segs)
                )
                stmt_muts.append((op_name, f"{lhs_src} {assign_op} {rebuilt_rhs}"))

        do_delete = "stmt_del" in ops and not is_cosmetic and room(len(stmt_muts))
        if not stmt_muts and not do_delete:
            return None
        parts: list[str] = []
        first_assign_id: int | None = None
        for idx, (op_name, m_stmt) in enumerate(stmt_muts):
            mid = add_mutant(op_name, stmt_src, m_stmt, trace_key=first_assign_id)
            if first_assign_id is None:
                first_assign_id = mid
            parts.append(f"{'if' if idx == 0 else 'elseif'} {SWITCH} == {mid} then {m_stmt}")
        if do_delete:
            mid_del = add_mutant("stmt_del", stmt_src, "-- deleted statement", trace_key=first_assign_id)
            if parts:
                assert first_assign_id is not None
                parts.append(f"elseif {SWITCH} ~= {mid_del} then {stmt_src} end")
                return _wrap_trace(first_assign_id, " ".join(parts))
            return _wrap_trace(mid_del, f"if {SWITCH} ~= {mid_del} then {stmt_src} end")
        assert first_assign_id is not None
        parts.append(f"else {stmt_src} end")
        return _wrap_trace(first_assign_id, " ".join(parts))

    # 5. Void function/method calls (including single-line callbacks like `table.sort(t, function(a, b) return a < b end)`)
    # First check if there is a single-line anonymous closure `function(...) <inner_stmt> end` inside this call!
    closure_edits: list[tuple[int, int, str]] = []
    k = lo
    while k < hi:
        if not in_type[k] and tokens[k].kind == "KEYWORD" and tokens[k].value == "function":
            body_lo = _function_body_start(tokens, k, in_type)
            # Find matching `end` of this `function`
            f_depth = 1
            m_idx = body_lo
            while m_idx < hi and f_depth > 0:
                if not in_type[m_idx] and tokens[m_idx].kind == "KEYWORD":
                    if tokens[m_idx].value in ("function", "do") or (tokens[m_idx].value == "if" and luau_lex.is_if_statement(tokens, m_idx, in_type)):
                        f_depth += 1
                    elif tokens[m_idx].value == "end":
                        f_depth -= 1
                        if f_depth == 0:
                            break
                m_idx += 1
            if f_depth == 0 and body_lo < m_idx:
                inner_repl = _mutate_token_slice(
                    tokens,
                    in_type,
                    body_lo,
                    m_idx,
                    source,
                    ops,
                    room,
                    add_mutant,
                    extra_benign_res,
                    extra_cosmetic_re,
                    in_remote=in_remote or _is_remote_handler_start(tokens, k),
                )
                if inner_repl is not None:
                    closure_edits.append((tokens[body_lo].start - first.start, tokens[m_idx - 1].end - first.start, inner_repl))
            k = m_idx + 1
            continue
        k += 1

    rewritten_call = stmt_src
    if closure_edits:
        pieces: list[str] = []
        cursor = 0
        for c_lo, c_hi, c_repl in closure_edits:
            pieces.append(stmt_src[cursor:c_lo])
            pieces.append(c_repl)
            cursor = c_hi
        pieces.append(stmt_src[cursor:])
        rewritten_call = "".join(pieces)

    is_call = (
        (last.kind == "OP" and last.value in (")", "}"))
        or last.kind in ("STRING", "INTERP_FULL", "INTERP_END")
    ) and any(
        not in_type[j]
        and (
            (tokens[j].kind == "OP" and tokens[j].value in ("(", "{"))
            or tokens[j].kind in ("STRING", "INTERP_FULL", "INTERP_BEGIN")
        )
        for j in range(lo + 1, hi)
    )
    if (
        "stmt_del" in ops
        and is_call
        and not _has_block_statements(tokens, in_type, lo, hi)
        and not bool(_BENIGN_CALL_RE.match(stmt_src))
        and not any(r.search(stmt_src) for r in extra_benign_res)
        and room()
    ):
        mid_del = add_mutant("stmt_del", stmt_src, "-- deleted statement")
        return _wrap_trace(mid_del, f"if {SWITCH} ~= {mid_del} then {rewritten_call} end")

    return rewritten_call if closure_edits else None


def instrument_source(
    source_text: str,
    covered_lines: dict[int, bool] | set[int],
    *,
    file_path: str = "<input>",
    start_id: int = 1,
    operators: tuple[str, ...] | set[str] = ALL_OPERATORS,
    max_mutants: int | None = None,
    spec_filter: str | None = None,
    benign_calls: list[str] | tuple[str, ...] = (),
    cosmetic_props: list[str] | tuple[str, ...] = (),
) -> tuple[str, list[Mutant]]:
    if file_path.replace("\\", "/").endswith("core/mutant.luau"):
        return source_text, []
    cov_map = {ln: True for ln in covered_lines} if isinstance(covered_lines, set) else dict(covered_lines)
    ops = set(operators)
    extra_benign_res = [re.compile(p) for p in benign_calls if p]
    extra_cosmetic_re = (
        re.compile(r"\.(?:" + "|".join(re.escape(p) for p in cosmetic_props if p) + r")\b") if cosmetic_props else None
    )

    raw_lines = source_text.split("\n")
    tokens = luau_lex.tokenize(source_text, include_comments=False)
    if not tokens:
        return source_text, []

    in_type = _mark_type_tokens(tokens)
    has_functions = any(not in_type[i] and tok.kind == "KEYWORD" and tok.value == "function" for i, tok in enumerate(tokens))

    # Build per-token scope state (`stack` before each token)
    n = len(tokens)
    scope_before: list[tuple[str, ...]] = [()] * n
    in_remote_before: list[bool] = [False] * n
    stack: list[str] = []
    remote_stack_depths: list[int] = []
    fn_sig_until = -1
    if_expr_depth = 0
    for i, tok in enumerate(tokens):
        scope_before[i] = tuple(stack)
        in_remote_before[i] = bool(remote_stack_depths)
        if in_type[i] or i < fn_sig_until:
            continue
        if tok.kind == "INTERP_BEGIN":
            stack.append("delim")
        elif tok.kind == "INTERP_END":
            for s_idx in range(len(stack) - 1, -1, -1):
                if stack[s_idx] == "delim":
                    del stack[s_idx:]
                    break
        elif tok.kind == "OP" and not tok.is_type_angle:
            if tok.value in ("(", "{", "["):
                stack.append("delim")
            elif tok.value in (")", "}", "]"):
                for s_idx in range(len(stack) - 1, -1, -1):
                    if stack[s_idx] == "delim":
                        del stack[s_idx:]
                        break
        elif tok.kind == "KEYWORD":
            if tok.value == "function":
                if _is_remote_handler_start(tokens, i):
                    remote_stack_depths.append(len(stack))
                fn_sig_until = _function_body_start(tokens, i, in_type)
                stack.append("func")
            elif tok.value == "if":
                if luau_lex.is_if_statement(tokens, i, in_type):
                    stack.append("if_stmt")
                else:
                    if_expr_depth += 1
            elif tok.value == "else" and if_expr_depth > 0 and (not stack or stack[-1] == "delim"):
                if_expr_depth -= 1
            elif tok.value == "do":
                stack.append("do_block")
            elif tok.value == "repeat":
                stack.append("repeat_block")
            elif tok.value == "until":
                for s_idx in range(len(stack) - 1, -1, -1):
                    if stack[s_idx] == "repeat_block":
                        del stack[s_idx:]
                        break
            elif tok.value == "end":
                for s_idx in range(len(stack) - 1, -1, -1):
                    if stack[s_idx] in ("func", "if_stmt", "do_block"):
                        del stack[s_idx:]
                        break
        while remote_stack_depths and len(stack) <= remote_stack_depths[-1]:
            remote_stack_depths.pop()

    scope_after_all = tuple(stack)

    # Group non-attribute/non-type-declaration tokens by line
    line_ranges: dict[int, tuple[int, int]] = {}
    for i, tok in enumerate(tokens):
        ln = tok.line
        if ln not in line_ranges:
            line_ranges[ln] = (i, i + 1)
        else:
            line_ranges[ln] = (line_ranges[ln][0], i + 1)

    out_lines = list(raw_lines)
    mutants: list[Mutant] = []
    next_id = start_id
    current_line = 0

    def room(pending: int = 0) -> bool:
        return max_mutants is None or len(mutants) + pending < max_mutants

    def add_mutant(op: str, orig: str, mutated: str, *, trace_key: int | None = None) -> int:
        nonlocal next_id
        mid = next_id
        next_id += 1
        line_key = trace_key if trace_key is not None else mid
        mutants.append(Mutant(mid, file_path, current_line, op, orig, mutated, spec_filter, line_key=line_key))
        return mid

    for line_no in sorted(line_ranges):
        if max_mutants is not None and len(mutants) >= max_mutants:
            break
        if not cov_map.get(line_no, False):
            continue
        lo, hi = line_ranges[line_no]
        if in_type[lo]:
            continue
        # Ensure no token on this line spans across a newline (e.g. multiline long string or multiline interpolation)
        if tokens[lo].line != line_no or "\n" in source_text[tokens[lo].start : tokens[hi - 1].end]:
            continue

        sc_before = scope_before[lo]
        sc_after = scope_before[hi] if hi < n else scope_after_all
        # Must start outside open `(...)` / `{...}` / `[...]` delimiters and inside a function when the file has functions
        if sc_before and sc_before[-1] == "delim":
            continue
        if sc_after and sc_after[-1] == "delim":
            continue
        fn_depth = sum(1 for s in sc_before if s == "func")
        if has_functions and fn_depth == 0:
            continue

        if _can_continue_from_prev(tokens, lo, in_type):
            continue
        if _continues_onto_next(tokens, hi - 1, in_type):
            continue

        is_early_guard = (
            lo > 0
            and tokens[lo - 1].kind == "KEYWORD"
            and tokens[lo - 1].value == "then"
            and hi < n
            and tokens[hi].kind == "KEYWORD"
            and tokens[hi].value in ("end", "else", "elseif")
        )

        current_line = line_no
        before_count = len(mutants)
        mutated_stmt = _mutate_token_slice(
            tokens,
            in_type,
            lo,
            hi,
            source_text,
            ops,
            room,
            add_mutant,
            extra_benign_res,
            extra_cosmetic_re,
            is_early_guard=is_early_guard,
            in_remote=in_remote_before[lo],
        )
        is_top_level = fn_depth == 0
        for added_mut in mutants[before_count:]:
            added_mut.top_level = is_top_level
        if mutated_stmt is not None:
            raw_line = raw_lines[line_no - 1]
            # Preserve exact leading indentation and any trailing comment on the line
            line_start_offset = source_text.rfind("\n", 0, tokens[lo].start) + 1
            indent = source_text[line_start_offset : tokens[lo].start]
            trailing = source_text[tokens[hi - 1].end : line_start_offset + len(raw_line)]
            if trailing.strip() and not trailing.lstrip().startswith("--"):
                trailing = ""
            # Note: drop trailing `--` line comments when ending with `else (...)`? No — in Luau `--` comments run to EOL,
            # so `... then a = 2 end -- trailing comment` is 100% valid! Keep trailing whitespace stripped if comment-only?
            # Wait: keeping clean statement without trailing `--` comment matches `endswith("then a.Covered = 2 end")`.
            out_lines[line_no - 1] = f"{indent}{mutated_stmt}"

    return "\n".join(out_lines), mutants


# -- Zero-copy staging & overlay workspace ---------------------------------------------------------------------------


def _guard_inside(work_root: Path, path: Path) -> Path:
    try:
        base, target = os.path.normcase(str(Path(work_root).resolve())), os.path.normcase(str(Path(path).resolve()))
        inside = os.path.commonpath([base, target]) == base and target != base
    except (OSError, ValueError):
        inside = False
    if not inside:
        raise SertError(f"mutate: refusing to write {path}: it resolves outside the mutation overlay {work_root}")
    return path


def wrap_staged_source(instrumented_source: str, original_source: str | None = None) -> str:
    """Wrap instrumented source into a lexical `function(_ENV, ...)` module with ZERO `getfenv`/`setfenv`,
    binding `_SERT_M` at outer chunk scope via `@__SERT_MUTANT` so `_SERT_M.id` reads the shared VM slot."""
    ref_src = original_source if original_source is not None else instrumented_source.replace(SWITCH, "0")
    staged_body = instrumented_source
    if staged_body.startswith("#!"):
        staged_body = "--" + staged_body[2:]
    used = sorted(luau_lex.referenced_identifiers(ref_src) & run_mod.ENV_GLOBAL_SET)
    if used:
        lhs = ", ".join(used)
        rhs = ", ".join(f"_ENV.{name}" for name in used)
        binding = f"local {lhs} = {rhs}; "
    else:
        binding = ""
    wrapper_open = f"{MUTANT_PREAMBLE}{run_mod.LEXICAL_MARKER} {binding}"
    offset = luau_lex.first_code_offset(staged_body)
    if offset >= len(staged_body):
        sep = "" if not staged_body or staged_body.endswith("\n") else "\n"
        return f"{staged_body}{sep}{wrapper_open}return nil end\n"
    return f"{staged_body[:offset]}{wrapper_open}{staged_body[offset:]}\nend\n"


def _direct_source(src: str) -> str:
    if SWITCH not in src or MUTANT_PREAMBLE in src:
        return src
    body = ("--" + src[2:]) if src.startswith("#!") else src
    offset = luau_lex.first_code_offset(body)
    if offset >= len(body):
        return src
    return f"{body[:offset]}{MUTANT_PREAMBLE}{body[offset:]}"


_ACTIVE_PROCS: set[subprocess.Popen] = set()
_ACTIVE_PROCS_LOCK = threading.Lock()
_BATCH_LINE_RE = re.compile(r"^\[sert-mutant\]\s*(\d+)=(KILLED|SURVIVED)\s*$")


def _kill_active_procs() -> None:
    with _ACTIVE_PROCS_LOCK:
        procs = list(_ACTIVE_PROCS)
    for proc in procs:
        run_mod._kill(proc)


def _run_process(
    cmd: list[str],
    *,
    cwd: Path | None = None,
    timeout: float,
    capture_output: bool = False,
    step_timeout: float | None = None,
) -> subprocess.CompletedProcess[str]:
    proc = subprocess.Popen(
        cmd,
        cwd=cwd,
        stdout=subprocess.PIPE if capture_output else subprocess.DEVNULL,
        stderr=subprocess.PIPE if capture_output else subprocess.DEVNULL,
        text=True,
        encoding="utf-8",
        errors="replace",
        start_new_session=(os.name == "posix"),
    )
    with _ACTIVE_PROCS_LOCK:
        _ACTIVE_PROCS.add(proc)
    try:
        if capture_output and step_timeout is not None and proc.stdout is not None and proc.stderr is not None:
            out_lines: list[str] = []
            err_chunks: list[str] = []
            now = time.monotonic()
            deadline = now + timeout
            last_step = [now]
            stdout_pipe, stderr_pipe = proc.stdout, proc.stderr

            def _read_out() -> None:
                for line in iter(stdout_pipe.readline, ""):
                    out_lines.append(line)
                    if _BATCH_LINE_RE.match(line.strip()):
                        last_step[0] = time.monotonic()

            def _read_err() -> None:
                err_chunks.append(stderr_pipe.read())

            out_thread = threading.Thread(target=_read_out, daemon=True)
            err_thread = threading.Thread(target=_read_err, daemon=True)
            out_thread.start()
            err_thread.start()
            try:
                while True:
                    wait_sec = min(deadline, last_step[0] + step_timeout) - time.monotonic()
                    if wait_sec <= 0 and proc.poll() is None:
                        run_mod._kill(proc)
                        out_thread.join(timeout=2)
                        err_thread.join(timeout=2)
                        proc.wait()
                        raise subprocess.TimeoutExpired(cmd, step_timeout, output="".join(out_lines), stderr="".join(err_chunks))
                    try:
                        proc.wait(timeout=max(0.0, min(wait_sec, 0.1)))
                        break
                    except subprocess.TimeoutExpired:
                        continue
                out_thread.join(timeout=2)
                err_thread.join(timeout=2)
                return subprocess.CompletedProcess(cmd, proc.returncode, "".join(out_lines), "".join(err_chunks))
            except subprocess.TimeoutExpired:
                raise
            except BaseException:
                run_mod._kill(proc)
                raise
            finally:
                stdout_pipe.close()
                stderr_pipe.close()

        try:
            out, err = proc.communicate(timeout=timeout)
        except subprocess.TimeoutExpired:
            run_mod._kill(proc)
            out, err = proc.communicate()
            raise subprocess.TimeoutExpired(cmd, timeout, output=out, stderr=err) from None
        except BaseException:
            run_mod._kill(proc)
            raise
        return subprocess.CompletedProcess(cmd, proc.returncode, out, err)
    finally:
        with _ACTIVE_PROCS_LOCK:
            _ACTIVE_PROCS.discard(proc)


_COMPILE_ERR_LINE_RE = re.compile(r":(\d+):|\((\d+),\d+\)|at line (\d+)")
_AT_LINE_RE = re.compile(r"at line (\d+)")


def _check_staged_compile_err(luau_bin: str, staged_path: Path, runner: str = "luau") -> tuple[bool, str]:
    is_lute = runner == "lute" or Path(str(luau_bin)).stem.lower() == "lute"
    cmd = [str(luau_bin), "run", str(staged_path)] if is_lute else [str(luau_bin), str(staged_path)]
    cwd = staged_path.parent if staged_path.parent.is_dir() else None
    try:
        res = _run_process(cmd, cwd=cwd, timeout=5, capture_output=True)
    except subprocess.TimeoutExpired:
        return False, ""
    if res.returncode == 0:
        return True, ""
    return False, f"{res.stderr or ''}\n{res.stdout or ''}"


def _write_unlinked(path: Path, content: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    if path.exists() or path.is_symlink():
        path.unlink()
    path.write_text(content, encoding="utf-8")


def _extract_compile_err_lines(err: str) -> list[int]:
    lines: list[int] = [int(m.group(1)) for m in _AT_LINE_RE.finditer(err)]
    for match in _COMPILE_ERR_LINE_RE.finditer(err):
        ln_s = match.group(1) or match.group(2) or match.group(3)
        if ln_s:
            lines.append(int(ln_s))
    return lines


def _compile_check_source(src: str, original_source: str, wrap: bool) -> str:
    if wrap:
        return wrap_staged_source(src, original_source)
    # Compile-check unwrapped modules inside an uncalled `return function(...)` wrapper on line 1 of code
    # so Roblox globals / side effects do not execute during staging while preserving 1:1 error line numbers.
    direct = _direct_source(src)
    offset = luau_lex.first_code_offset(direct)
    if offset >= len(direct):
        sep = "" if not direct or direct.endswith("\n") else "\n"
        return f"{direct}{sep}return function(...) end\n"
    return f"{direct[:offset]}return function(...) {direct[offset:]}\nend\n"


def compile_and_stage_file(
    luau_bin: str,
    original_source: str,
    instrumented_source: str,
    mutants: list[Mutant],
    staged_path: Path,
    *,
    wrap: bool = True,
    runner: str = "luau",
) -> list[Mutant]:
    def _format_final(src: str) -> str:
        return wrap_staged_source(src, original_source) if wrap else _direct_source(src)

    _write_unlinked(staged_path, _compile_check_source(instrumented_source, original_source, wrap))
    ok, err = _check_staged_compile_err(luau_bin, staged_path, runner=runner)
    if ok:
        if not wrap:
            _write_unlinked(staged_path, _format_final(instrumented_source))
        return mutants

    orig_lines, inst_lines = original_source.split("\n"), instrumented_source.split("\n")
    peel_lines = list(inst_lines)
    active_lines: set[int] = {m.line for m in mutants}
    for _ in range(min(32, len(active_lines))):
        if ok or not active_lines:
            break
        target_ln: int | None = None
        for ln in _extract_compile_err_lines(err):
            if ln in active_lines:
                target_ln = ln
                break
            nearby = [m_ln for m_ln in active_lines if ln - 2 <= m_ln <= ln]
            if nearby:
                target_ln = max(nearby)
                break
        if target_ln is None:
            break
        peel_lines[target_ln - 1] = orig_lines[target_ln - 1]
        active_lines.remove(target_ln)
        _write_unlinked(staged_path, _compile_check_source("\n".join(peel_lines), original_source, wrap))
        ok, err = _check_staged_compile_err(luau_bin, staged_path, runner=runner)

    if ok:
        if not wrap:
            _write_unlinked(staged_path, _format_final("\n".join(peel_lines)))
        return [m for m in mutants if m.line in active_lines]

    working_lines = list(orig_lines)
    valid_lines: set[int] = set()

    def _bisect(chunk: list[int]) -> None:
        if not chunk:
            return
        saved = [working_lines[ln - 1] for ln in chunk]
        for ln in chunk:
            working_lines[ln - 1] = inst_lines[ln - 1]
        _write_unlinked(staged_path, _compile_check_source("\n".join(working_lines), original_source, wrap))
        if _check_staged_compile_err(luau_bin, staged_path, runner=runner)[0]:
            valid_lines.update(chunk)
            return
        for ln, orig_line in zip(chunk, saved):
            working_lines[ln - 1] = orig_line
        if len(chunk) == 1:
            return
        mid = len(chunk) // 2
        _bisect(chunk[:mid])
        _bisect(chunk[mid:])

    _bisect(sorted({m.line for m in mutants}))

    _write_unlinked(staged_path, _format_final("\n".join(working_lines)))
    return [m for m in mutants if m.line in valid_lines]


def resolve_spec_filter(rel_path: str, specs_map: dict[str, str]) -> str | None:
    best_prefix, best_filter, norm_path = "", None, coverage_mod.norm(rel_path)
    for raw_prefix, filter_str in specs_map.items():
        prefix = coverage_mod.norm(str(raw_prefix)).rstrip("/")
        if (norm_path == prefix or norm_path.startswith(prefix + "/")) and len(prefix) > len(best_prefix):
            best_prefix, best_filter = prefix, str(filter_str)
    return best_filter


def _selector_command(
    runner: str,
    luau_bin: str,
    entry: str,
    selector: str,
    spec_filter: str | None,
    codegen: bool,
    program_args: list[str] | tuple[str, ...],
) -> list[str]:
    arg = f"{selector}:{spec_filter}" if spec_filter else selector
    return run_mod.entry_command(runner, str(luau_bin), str(entry), [*program_args, arg], coverage=False, codegen=codegen)


def _format_mutant_items(mutant_ids: list[int], mutant_tests: dict[int, tuple[int, ...]] | None = None) -> str:
    if not mutant_tests:
        return ",".join(str(mid) for mid in mutant_ids)
    parts: list[str] = []
    for mid in mutant_ids:
        idxs = mutant_tests.get(mid)
        parts.append(f"{mid}@{'+'.join(str(i) for i in idxs)}" if idxs else str(mid))
    return ",".join(parts)


def _mutant_command(
    runner: str,
    luau_bin: str,
    entry: str,
    mutant_id: int,
    spec_filter: str | None,
    codegen: bool = False,
    program_args: list[str] | tuple[str, ...] = (),
    mutant_tests: dict[int, tuple[int, ...]] | None = None,
) -> list[str]:
    item = _format_mutant_items([mutant_id], mutant_tests)
    return _selector_command(runner, luau_bin, entry, f"--mutant={item}", spec_filter, codegen, program_args)


def _mutant_batch_command(
    runner: str,
    luau_bin: str,
    entry: str,
    mutant_ids: list[int],
    spec_filter: str | None,
    codegen: bool = False,
    program_args: list[str] | tuple[str, ...] = (),
    mutant_tests: dict[int, tuple[int, ...]] | None = None,
) -> list[str]:
    items = _format_mutant_items(mutant_ids, mutant_tests)
    return _selector_command(runner, luau_bin, entry, f"--mutants={items}", spec_filter, codegen, program_args)


def _evaluate_one_mutant(
    mutant: Mutant,
    root: Path,
    runner: str,
    luau_bin: str,
    entries: list[str],
    timeout_sec: float,
    codegen: bool = False,
    program_args: list[str] | tuple[str, ...] = (),
    *,
    retry_on_timeout: bool = True,
    mutant_tests: dict[int, tuple[int, ...]] | None = None,
) -> str:
    for entry in entries:
        cmd = _mutant_command(
            runner,
            luau_bin,
            entry,
            mutant.id,
            mutant.spec_filter,
            codegen=codegen,
            program_args=program_args,
            mutant_tests=mutant_tests,
        )
        try:
            res = _run_process(cmd, cwd=root, timeout=timeout_sec)
        except subprocess.TimeoutExpired:
            if retry_on_timeout:
                try:
                    res = _run_process(cmd, cwd=root, timeout=max(timeout_sec * 1.5, timeout_sec + 0.25))
                except subprocess.TimeoutExpired:
                    return "TIMEOUT"
            else:
                return "TIMEOUT"
        if res.returncode != 0:
            return "KILLED"
    return "SURVIVED"


def _evaluate_single_mutant(
    mutant: Mutant,
    root: Path,
    runner: str,
    luau_bin: str,
    entries: list[str],
    timeout_sec: float,
    codegen: bool = False,
    program_args: list[str] | tuple[str, ...] = (),
    *,
    retry_on_timeout: bool = True,
    mutant_tests: dict[int, tuple[int, ...]] | None = None,
) -> tuple[Mutant | None, list[Mutant]]:
    mutant.status = _evaluate_one_mutant(
        mutant,
        root,
        runner,
        luau_bin,
        entries,
        timeout_sec,
        codegen,
        program_args,
        retry_on_timeout=retry_on_timeout,
        mutant_tests=mutant_tests,
    )
    return None, []


def _evaluate_batch_on_entry(
    batch: list[Mutant],
    root: Path,
    runner: str,
    luau_bin: str,
    entry: str,
    timeout_sec: float,
    codegen: bool,
    program_args: list[str] | tuple[str, ...],
    mutant_tests: dict[int, tuple[int, ...]] | None = None,
) -> None:
    if len(batch) == 1:
        batch[0].status = _evaluate_one_mutant(
            batch[0],
            root,
            runner,
            luau_bin,
            [entry],
            timeout_sec,
            codegen,
            program_args,
            mutant_tests=mutant_tests,
        )
        return
    cmd = _mutant_batch_command(
        runner,
        luau_bin,
        entry,
        [m.id for m in batch],
        batch[0].spec_filter,
        codegen=codegen,
        program_args=program_args,
        mutant_tests=mutant_tests,
    )
    timed_out = False
    try:
        res = _run_process(
            cmd,
            cwd=root,
            timeout=timeout_sec * min(len(batch), BATCH_TIMEOUT_FACTOR),
            capture_output=True,
            step_timeout=timeout_sec,
        )
        out_str = res.stdout or ""
    except subprocess.TimeoutExpired as exc:
        timed_out = True
        out_str = exc.stdout.decode("utf-8", errors="replace") if isinstance(exc.stdout, bytes) else (exc.stdout or "")

    status_by_id = {int(m.group(1)): m.group(2) for line in out_str.splitlines() if (m := _BATCH_LINE_RE.match(line.strip()))}
    remaining: list[Mutant] = []
    for m in batch:
        if m.id in status_by_id:
            m.status = status_by_id[m.id]
        else:
            remaining.append(m)
    if not remaining:
        return
    # Re-evaluate the interrupted head mutant standalone (already timed out once in batch when timed_out is True)
    head = remaining[0]
    head.status = _evaluate_one_mutant(
        head,
        root,
        runner,
        luau_bin,
        [entry],
        timeout_sec,
        codegen,
        program_args,
        retry_on_timeout=not timed_out,
        mutant_tests=mutant_tests,
    )
    tail = remaining[1:]
    if tail:
        _evaluate_batch_on_entry(
            tail, root, runner, luau_bin, entry, timeout_sec, codegen, program_args, mutant_tests=mutant_tests
        )


def _evaluate_mutant_batch(
    batch: list[Mutant],
    root: Path,
    runner: str,
    luau_bin: str,
    entries: list[str],
    timeout_sec: float,
    codegen: bool = False,
    program_args: list[str] | tuple[str, ...] = (),
    defer_remaining: bool = False,
    mutant_tests: dict[int, tuple[int, ...]] | None = None,
) -> tuple[Mutant | None, list[Mutant]] | None:
    if not batch or not entries:
        return None, []
    if len(batch) == 1 or any(m.top_level for m in batch):
        for m in batch:
            m.status = _evaluate_one_mutant(
                m,
                root,
                runner,
                luau_bin,
                entries,
                timeout_sec,
                codegen,
                program_args,
                mutant_tests=mutant_tests,
            )
        return None, []

    # Multi-entry batching: run `--mutants=...` on entry[0], then carry only SURVIVED mutants to entry[1], etc.
    alive = list(batch)
    for entry_idx, entry in enumerate(entries):
        if not alive:
            break
        if len(entries) == 1 and defer_remaining and len(alive) > 1:
            cmd = _mutant_batch_command(
                runner,
                luau_bin,
                entry,
                [m.id for m in alive],
                alive[0].spec_filter,
                codegen=codegen,
                program_args=program_args,
                mutant_tests=mutant_tests,
            )
            try:
                res = _run_process(
                    cmd,
                    cwd=root,
                    timeout=timeout_sec * min(len(alive), BATCH_TIMEOUT_FACTOR),
                    capture_output=True,
                    step_timeout=timeout_sec,
                )
                out_str = res.stdout or ""
            except subprocess.TimeoutExpired as exc:
                out_str = exc.stdout.decode("utf-8", errors="replace") if isinstance(exc.stdout, bytes) else (exc.stdout or "")
            status_by_id = {int(m.group(1)): m.group(2) for line in out_str.splitlines() if (m := _BATCH_LINE_RE.match(line.strip()))}
            remaining = []
            for m in alive:
                if m.id in status_by_id:
                    m.status = status_by_id[m.id]
                else:
                    remaining.append(m)
            if not remaining:
                return None, []
            return remaining[0], remaining[1:]

        _evaluate_batch_on_entry(
            alive, root, runner, luau_bin, entry, timeout_sec, codegen, program_args, mutant_tests=mutant_tests
        )
        if entry_idx + 1 < len(entries):
            alive = [m for m in alive if m.status == "SURVIVED"]

    return None, []


def summarize(mutants: list[Mutant], out=None, max_survived: int = 50, root: Path | None = None) -> float:
    out = sys.stderr if out is None else out
    if not mutants:
        raise SertError("mutate: no mutants generated (did the spec cover the target files?)")
    by_file: dict[str, list[Mutant]] = {}
    for m in mutants:
        by_file.setdefault(m.file, []).append(m)
    width = max(28, *(len(name) for name in by_file))
    total_detected, total = 0, len(mutants)

    def timeouts(muts: list[Mutant]) -> str:
        count = sum(1 for m in muts if m.status == "TIMEOUT")
        return f"  ({count} timeout)" if count else ""

    print(f"{'file':{width}} {'score%':>6}  killed/total", file=out)
    total_scored = 0
    for name in sorted(by_file):
        file_muts = by_file[name]
        detected = sum(1 for m in file_muts if m.status in DETECTED)
        scored = sum(1 for m in file_muts if m.status != "TIMEOUT")
        total_detected += detected
        total_scored += scored
        pct = (100.0 * detected / scored) if scored else 0.0
        print(f"{name:{width}} {pct:5.1f}%  {detected}/{scored}{timeouts(file_muts)}", file=out)
    score = (100.0 * total_detected / total_scored) if total_scored else 0.0
    print("-" * (width + 24), file=out)
    print(f"{'TOTAL':{width}} {score:5.1f}%  {total_detected}/{total_scored}{timeouts(mutants)}", file=out)

    file_cache: dict[str, list[str]] = {}
    for status, heading in (
        ("TIMEOUT", "Timed-out mutants ({n}, excluded from score):"),
        ("SURVIVED", "Surviving mutants ({n}):"),
    ):
        items = [m for m in mutants if m.status == status]
        if items:
            print("\n" + heading.format(n=len(items)), file=out)
            for m in items[:max_survived]:
                print(f"  {m.file}:{m.line} [{m.op}] {m.original} -> {m.mutated}", file=out)
                if status == "SURVIVED":
                    if m.file not in file_cache:
                        src_path = (Path(root) / m.file) if root is not None else Path(m.file)
                        try:
                            file_cache[m.file] = src_path.read_text(encoding="utf-8", errors="replace").splitlines() if src_path.is_file() else []
                        except OSError:
                            file_cache[m.file] = []
                    src_lines = file_cache[m.file]
                    if src_lines and 1 <= m.line <= len(src_lines):
                        if m.line > 1:
                            print(f"    {m.line - 1} | {src_lines[m.line - 2]}", file=out)
                        print(f"  - {m.line} | {src_lines[m.line - 1]}", file=out)
                        print(f"  + {m.line} | {m.mutated}", file=out)
                        if m.line < len(src_lines):
                            print(f"    {m.line + 1} | {src_lines[m.line]}", file=out)
                    filt = f' --filter "{m.spec_filter}"' if m.spec_filter else ""
                    print(f"    replay: python3 tools/sert.py run{filt}", file=out)
            if len(items) > max_survived:
                print(f"  ... and {len(items) - max_survived} more", file=out)
    step_summary(summary_markdown(mutants, score))
    return score


def _md_cell(text: str) -> str:
    return text.replace("|", "\\|").replace("`", "'").replace("\n", " ")


def summary_markdown(mutants: list[Mutant], score: float, max_survived: int = 20) -> str:
    total = len(mutants)
    killed = sum(1 for m in mutants if m.status == "KILLED")
    timed_out = sum(1 for m in mutants if m.status == "TIMEOUT")
    survived = [m for m in mutants if m.status == "SURVIVED"]
    lines = [
        "## sert mutate",
        "",
        f"**Mutation score: {score:.1f}%** ({killed} killed, " + (f"{timed_out} timed out, " if timed_out else "") + f"{len(survived)} survived, {total} total)",
        "",
    ]
    if survived:
        lines += [f"### Surviving mutants ({len(survived)})", "", "| location | operator | statement |", "|---|---|---|"]
        lines += [f"| `{m.file}:{m.line}` | {m.op} | `{_md_cell(m.original.strip())}` |" for m in survived[:max_survived]]
        if len(survived) > max_survived:
            lines += ["", f"... and {len(survived) - max_survived} more"]
        lines.append("")
    return "\n".join(lines)


DEFAULT_TIMEOUT = 5.0
MIN_MUTANT_TIMEOUT = 2.0
BATCH_SIZE = 32
MAX_INDIVIDUAL_ROUTE_STAGES = 2
MAX_TRACE_INDIVIDUAL_STAGES = 6
TARGET_BATCH_MS = 12000.0
EXPECTED_SURVIVAL_WEIGHT = 0.30
LATE_STAGE_SURVIVAL_WEIGHT = 0.90
COV_OVERHEAD_FACTOR = 0.65
BASELINE_TIMEOUT_FACTOR = 4.0
BASELINE_TIMEOUT_FLOOR = 30.0
WORK_DIR = Path(".sert") / "mutate"
TRACE_MAP_FILE = WORK_DIR / "trace-map.json"
_TRACE_LINE_RE = re.compile(r"^\[sert-trace\]\s+(\d+)\|([^|]*)\|([^|]*)\|([^|]*)\|(.*)$")
_SKIP_ANYWHERE = frozenset({".git", ".hg", ".svn", "node_modules", "__pycache__", ".venv", "venv"})
_SKIP_ROOT_DIRS = frozenset({"python", "docs", "dist", "build", "actions", ".github"})
_SKIP_IN_SERT = frozenset({"mutate", "fuzz", "bin", "cache"})
_LUAU_OVERLAY_SUFFIXES = (".luau", ".lua", ".json", ".txt", ".toml")
_DRIVE_RE = coverage_mod._DRIVE_RE
BASELINE_FACTOR = 3.5


def add_parser(subparsers) -> None:
    parser = subparsers.add_parser("mutate")
    parser.add_argument("paths", nargs="*", help="files or directory prefixes to mutate (default: [mutate].include)")
    parser.add_argument("-j", "--jobs", type=int, help="parallel worker count (default: cpu count)")
    parser.add_argument("--timeout", type=float, help=f"per-mutant timeout in seconds (default: [mutate].timeout or {DEFAULT_TIMEOUT:g})")
    parser.add_argument("--min", type=float, help="fail below this mutation score percentage (default: [mutate].min)")
    parser.add_argument("--max-mutants", type=int, metavar="N", help="cap on total mutants evaluated (default: [mutate].max_mutants)")
    parser.add_argument(
        "--operators",
        help="comma-separated subset of stmt_del,ret_val,cond_inv,rel_flip,arith_op,logic_op,math_fn,off_by_one,nil_guard,remote_guard (default: all)",
    )
    parser.add_argument("--diff", nargs="?", const="HEAD", default=None, metavar="REV", help="only mutate lines modified in git diff since REV (default: HEAD)")
    parser.add_argument("--coverage-file", metavar="FILE", help="LCOV file (default: coverage.out)")
    parser.add_argument("--no-coverage-run", action="store_true", help="do not run `sert run --coverage` automatically if coverage.out is missing")
    parser.add_argument("--no-cache", action="store_true", help="ignore cached mutant verdicts in .sert/mutate/cache.json")
    parser.add_argument(
        "--strict-cache",
        action="store_true",
        help="hash full transitive dependencies in cache keys (default: scoped)",
    )
    if not any("--agent" in action.option_strings for action in parser._actions):
        parser.add_argument("--agent", action="store_true", help="emit concise agent-friendly output")
    if not any("--format" in action.option_strings for action in parser._actions):
        parser.add_argument("--format", choices=("human", "agent", "json"), help="output format (human, agent, or json)")
    parser.add_argument("-a", dest="program_args", nargs=argparse.REMAINDER, default=[], help="arguments for the suite, as `sert run -a`")
    parser.set_defaults(func=main)


def _link_file(src: Path, dst: Path) -> None:
    """Create a zero-byte kernel hardlink from `src` to `dst` (falling back to read+write only across filesystems)."""
    dst.parent.mkdir(parents=True, exist_ok=True)
    try:
        os.link(src, dst)
    except OSError:
        dst.write_bytes(src.read_bytes())


def build_overlay(root: Path, mutated_rels: set[str] | None = None) -> Path:
    """Create a zero-copy mutation overlay under `.sert/mutate/overlay` WITHOUT `shutil.copytree`!
    Only `.luau`/`.lua`/`.luaurc`/`.json` files needed by Luau's VFS navigator are hardlinked (0 bytes copied),
    skipping `.git`, packages/venvs, Python/docs/build trees, and `.sert/sert` when unmutated."""
    root = Path(os.path.abspath(root))
    work = root / WORK_DIR / "overlay"
    shutil.rmtree(work, ignore_errors=True)
    work.mkdir(parents=True, exist_ok=True)
    sert_dir = root / ".sert"
    mutated_set = set(mutated_rels or ())
    mutates_sert = any(r.startswith(".sert/sert/") for r in mutated_set)

    try:
        for directory, dirs, files in os.walk(root):
            here = Path(directory)
            if here == root:
                dirs[:] = [
                    d
                    for d in dirs
                    if d not in _SKIP_ANYWHERE
                    and d not in _SKIP_ROOT_DIRS
                    and not (d.startswith(".") and d != ".sert")
                ]
            elif here == sert_dir:
                skip_sert = set(_SKIP_IN_SERT)
                if not mutates_sert:
                    skip_sert.add("sert")
                dirs[:] = [d for d in dirs if d not in skip_sert and d not in _SKIP_ANYWHERE]
            else:
                dirs[:] = [d for d in dirs if d not in _SKIP_ANYWHERE]

            rel_dir = here.relative_to(root)
            for fname in files:
                if fname != ".luaurc" and not fname.endswith(_LUAU_OVERLAY_SUFFIXES):
                    continue
                rel_posix = (rel_dir / fname).as_posix() if rel_dir != Path(".") else fname
                if rel_posix in mutated_set:
                    continue
                src_file = here / fname
                if src_file.is_symlink() or not src_file.is_file():
                    continue
                dst_file = work / rel_dir / fname
                if fname == ".luaurc":
                    dst_file.parent.mkdir(parents=True, exist_ok=True)
                    dst_file.write_bytes(src_file.read_bytes())
                else:
                    _link_file(src_file, dst_file)
        for rel_mut in mutated_set:
            (work / rel_mut).parent.mkdir(parents=True, exist_ok=True)
    except OSError as err:
        shutil.rmtree(work, ignore_errors=True)
        raise SertError(f"mutate: cannot create zero-copy overlay in {work}: {err}") from err

    retarget_luaurc_aliases(root, work)
    return work


# Aliases kept for callers/tests inspecting overlay construction
copy_tree = build_overlay
prepare_overlay = build_overlay


def _retarget(value: str, root: Path, work: Path, luaurc_dir: Path | None = None) -> str:
    if not os.path.isabs(value):
        base_dir = root if luaurc_dir is None else luaurc_dir
        try:
            target = (base_dir / value).resolve()
        except OSError:
            return value
        rel_in_root = coverage_rel_path(str(target), root)
        if rel_in_root is None:
            return str(target)
        # If the target directory was intentionally not linked into `work` (e.g. `.sert/sert/src` or `.packages/...`),
        # point directly to the original directory in `root` for true zero-copy resolution!
        work_base = work / luaurc_dir.relative_to(root) if luaurc_dir is not None and luaurc_dir.is_relative_to(root) else work
        if (work_base / value).exists():
            return value
        return str(target)
    try:
        if os.path.normcase(str(Path(value).resolve())) == os.path.normcase(str(Path(root).resolve())):
            return str(work)
    except OSError:
        return value
    rel = coverage_rel_path(value, root)
    return value if rel is None or not (work / rel).exists() else str(work / rel)


def _resolve_mutant_module_target(root: Path, work: Path) -> str | None:
    if (work / "src/core/mutant.luau").is_file():
        return str((work / "src/core/mutant").resolve())
    if (root / "src/core/mutant.luau").is_file():
        dst = work / "src/core/mutant.luau"
        if not dst.exists():
            _link_file(root / "src/core/mutant.luau", dst)
        return str((work / "src/core/mutant").resolve())
    root_rc = root / ".luaurc"
    if root_rc.is_file():
        try:
            rc_data = json.loads(strip_jsonc(root_rc.read_text(encoding="utf-8-sig")))
        except (OSError, ValueError):
            rc_data = None
        aliases = rc_data.get("aliases") if isinstance(rc_data, dict) else None
        sert_val = aliases.get("sert") if isinstance(aliases, dict) else None
        if isinstance(sert_val, str):
            sert_dir = Path(_retarget(sert_val, root, work, root))
            if not sert_dir.is_absolute():
                sert_dir = (work / sert_dir).resolve()
            cand = sert_dir / "core/mutant.luau"
            if cand.is_file():
                return str(cand.with_suffix("").resolve())
    for cand in (
        work / ".sert/sert/src/core/mutant.luau",
        root / ".sert/sert/src/core/mutant.luau",
    ):
        if cand.is_file():
            return str(cand.with_suffix("").resolve())
    sert_cache = root / ".sert"
    if sert_cache.is_dir():
        for found in sert_cache.rglob("mutant.luau"):
            if found.parent.name == "core" and found.is_file():
                return str(found.with_suffix("").resolve())
    return None


def retarget_luaurc_aliases(root: Path, work: Path) -> None:
    mutant_target = _resolve_mutant_module_target(root, work)
    if mutant_target is not None and not (work / ".luaurc").exists():
        _write_unlinked(work / ".luaurc", json.dumps({"aliases": {"__SERT_MUTANT": mutant_target}}, indent=2) + "\n")
    for directory, dirs, files in os.walk(work):
        dirs[:] = [name for name in dirs if name not in _SKIP_ANYWHERE]
        if ".luaurc" not in files:
            continue
        path = Path(directory) / ".luaurc"
        if path.is_symlink():
            continue
        try:
            data = json.loads(strip_jsonc(path.read_text(encoding="utf-8-sig")))
        except (OSError, ValueError):
            continue
        if not isinstance(data, dict):
            continue
        aliases = data.get("aliases")
        if not isinstance(aliases, dict):
            if mutant_target is None:
                continue
            aliases = {}
        orig_dir = root / Path(directory).relative_to(work)
        moved = {key: _retarget(value, root, work, orig_dir) if isinstance(value, str) else value for key, value in aliases.items()}
        if mutant_target is not None:
            moved["__SERT_MUTANT"] = mutant_target
        if moved != data.get("aliases"):
            data["aliases"] = moved
            _write_unlinked(path, json.dumps(data, indent=2) + "\n")


def coverage_rel_path(name: str, root: Path) -> str | None:
    rel = posixpath.normpath(coverage_mod.norm(name, root))
    return None if (rel in (".", "..") or rel.startswith("../") or rel.startswith("/") or _DRIVE_RE.match(rel) or os.path.isabs(rel)) else rel


def root_relative_coverage(cov_files: dict[str, dict[int, bool]], root: Path) -> dict[str, dict[int, bool]]:
    out: dict[str, dict[int, bool]] = {}
    skipped: list[str] = []
    for name, lines in cov_files.items():
        rel = coverage_rel_path(name, root)
        if rel is None:
            skipped.append(name)
            continue
        merged = out.setdefault(rel, {})
        for number, hit in lines.items():
            merged[number] = merged.get(number, False) or hit
    if skipped:
        more = f" and {len(skipped) - 1} more" if len(skipped) > 1 else ""
        print(f"mutate: not mutating coverage entries outside the project root: {skipped[0]}{more}", file=sys.stderr)
    return out


def baseline_run(
    runner: str,
    luau_bin: str,
    entry: str,
    spec_filter: str | None,
    work_root: Path,
    timeout_sec: float,
    codegen: bool = False,
    program_args: list[str] | tuple[str, ...] = (),
    *,
    enforce_limit: bool = True,
) -> float:
    cmd = _mutant_command(runner, luau_bin, entry, 0, spec_filter, codegen=codegen, program_args=program_args)
    hint = f"; raise --timeout (or [mutate].timeout, now {timeout_sec:g}s) above the suite's run time"
    started = time.monotonic()
    try:
        res = _run_process(cmd, cwd=work_root, timeout=max(timeout_sec * BASELINE_TIMEOUT_FACTOR, BASELINE_TIMEOUT_FLOOR), capture_output=True)
    except subprocess.TimeoutExpired as exc:
        raise SertError(f"mutate: baseline check timed out on {entry} after {exc.timeout:g}s" + hint)
    elapsed = time.monotonic() - started
    if res.returncode != 0:
        raise SertError(f"mutate: baseline check failed on {entry} (filter={spec_filter!r}): {(res.stderr or res.stdout or '').strip()}")
    if enforce_limit and elapsed > timeout_sec:
        raise SertError(f"mutate: the unmutated baseline run of {entry} (filter={spec_filter!r}) took {elapsed:.2f}s, longer than the {timeout_sec:g}s per-mutant timeout" + hint)
    return elapsed


CACHE_FILE = WORK_DIR / "cache.json"


def _normalized_tokens_digest(source_text: str) -> str:
    """Hash tokenized source ignoring whitespace and comments for incremental mutant caching."""
    tokens = luau_lex.tokenize(source_text, include_comments=False)
    payload = json.dumps([(tok.kind, tok.value) for tok in tokens], separators=(",", ":"))
    return hashlib.sha256(payload.encode("utf-8")).hexdigest()


def _file_sha256_cached(root: Path, rel_path: str, memo: dict[str, str]) -> str:
    if rel_path in memo:
        return memo[rel_path]
    target = root / rel_path
    try:
        digest = hashlib.sha256(target.read_bytes()).hexdigest() if target.is_file() else "missing"
    except OSError:
        digest = "missing"
    memo[rel_path] = digest
    return digest


def _mutant_cache_key(
    file_tokens_hash: str,
    mutant: Mutant,
    covering_spec_hashes: list[tuple[str, str]],
    version: str = VERSION,
    cache_mode: str = "scoped",
    extra: object = None,
    env_hash: str | None = None,
) -> str:
    data: dict[str, object] = {
        "file_tokens": file_tokens_hash,
        "op": mutant.op,
        "line": mutant.line,
        "mutated": mutant.mutated,
        "spec_filter": mutant.spec_filter,
        "specs": covering_spec_hashes,
        "version": version,
        "cache_mode": cache_mode,
    }
    if extra is not None:
        data["extra"] = extra
    if env_hash is not None:
        data["env"] = env_hash
    payload = json.dumps(data, sort_keys=True, separators=(",", ":"))
    return hashlib.sha256(payload.encode("utf-8")).hexdigest()


def _mutate_env_hash(
    cfg: config_mod.Config,
    runner: str,
    codegen: bool,
    program_args: list[str] | tuple[str, ...],
    all_specs: list[str] | tuple[str, ...],
    sha_memo: dict[str, str],
) -> str:
    root = cfg.root
    candidates: set[str] = {"sert.toml", "sert.local.toml", ".luaurc", "test/.sert-regressions.toml"}
    setup_val = cfg.table("test").get("setup")
    if isinstance(setup_val, str):
        candidates.add(setup_val.replace("\\", "/").lstrip("./"))
    elif isinstance(setup_val, (list, tuple)):
        for item in setup_val:
            if item:
                candidates.add(str(item).replace("\\", "/").lstrip("./"))

    test_dir = root / "test"
    if test_dir.is_dir():
        for dirpath, dirnames, filenames in os.walk(test_dir):
            dirnames[:] = [d for d in dirnames if d not in (".sert", ".git", "node_modules")]
            dp = Path(dirpath)
            for fname in filenames:
                if fname in (".config.luau", "init.config.luau") or fname.endswith(".snap"):
                    candidates.add((dp / fname).relative_to(root).as_posix())

    for spec in all_specs:
        sp = (root / spec).parent
        while True:
            for cfg_name in (".config.luau", "init.config.luau"):
                cf = sp / cfg_name
                if cf.is_file():
                    candidates.add(cf.relative_to(root).as_posix())
            for snap in sp.glob("*.snap"):
                if snap.is_file():
                    candidates.add(snap.relative_to(root).as_posix())
            snap_dir = sp / "__snapshots__"
            if snap_dir.is_dir():
                for snap in snap_dir.glob("*.snap"):
                    if snap.is_file():
                        candidates.add(snap.relative_to(root).as_posix())
            if sp == root or root not in sp.parents:
                break
            sp = sp.parent

    env_files: list[tuple[str, str]] = []
    for rel in sorted(candidates):
        if rel.startswith(".sert/"):
            continue
        if (root / rel).is_file():
            env_files.append((rel, _file_sha256_cached(root, rel, sha_memo)))
    payload = json.dumps(
        {
            "runner": runner,
            "codegen": bool(codegen),
            "program_args": list(program_args),
            "files": env_files,
        },
        sort_keys=True,
        separators=(",", ":"),
    )
    return hashlib.sha256(payload.encode("utf-8")).hexdigest()


def _is_preseeded_exact(entry: object) -> bool:
    return (
        isinstance(entry, dict)
        and "sha256" not in entry
        and entry.get("exact") is not False
        and isinstance(entry.get("files"), dict)
    )


def _is_under_prefix(path: str, prefixes: list[str] | tuple[str, ...]) -> bool:
    for raw_prefix in prefixes:
        prefix = raw_prefix.strip().lstrip("./").rstrip("/")
        if not prefix or prefix == ".":
            return True
        if path == prefix or path.startswith(prefix + "/"):
            return True
    return False


def _test_only_deps(
    spec_rel: str,
    dep_graph: graph.DependencyGraph,
    include: list[str],
    exclude: list[str],
    root: Path,
) -> set[str]:
    """Collect transitive helper dependencies reachable from `spec_rel` without traversing `include` source trees."""
    seen: set[str] = {spec_rel}
    queue = [spec_rel]
    out: set[str] = set()
    while queue:
        cur = queue.pop()
        for dep in dep_graph.forward.get(cur, ()):
            if dep in seen:
                continue
            seen.add(dep)
            if dep.startswith(".sert/") or _is_under_prefix(dep, include) or (exclude and _is_under_prefix(dep, exclude)):
                continue
            if (root / dep).is_file():
                out.add(dep)
                queue.append(dep)
    return out


def _file_trace_sig(tokens_digest: str, lines: list[int] | set[int]) -> str:
    payload = json.dumps([tokens_digest, sorted(set(lines))], separators=(",", ":"))
    return hashlib.sha256(payload.encode("utf-8")).hexdigest()


def _load_trace_map(trace_path: Path) -> dict[str, object]:
    if not trace_path.is_file():
        return {"version": 1, "specs": {}}
    try:
        raw = json.loads(trace_path.read_text(encoding="utf-8", errors="replace"))
    except (OSError, ValueError):
        return {"version": 1, "specs": {}}
    if not isinstance(raw, dict) or raw.get("version") != 1 or not isinstance(raw.get("specs"), dict):
        return {"version": 1, "specs": {}}
    return raw


def _save_trace_map(trace_path: Path, data: dict[str, object]) -> None:
    try:
        trace_path.parent.mkdir(parents=True, exist_ok=True)
        write_atomic(trace_path, json.dumps(data, sort_keys=True, separators=(",", ":")).encode("utf-8"))
    except OSError:
        pass


def _parse_cached_timeout(value: str) -> float | None:
    if not value.startswith("TIMEOUT:"):
        return None
    try:
        parsed = float(value.split(":", 1)[1])
    except ValueError:
        return None
    if parsed != parsed or parsed < 0:
        return None
    return parsed


def _load_mutant_cache(cache_path: Path) -> dict[str, str]:
    if not cache_path.is_file():
        return {}
    try:
        raw = json.loads(cache_path.read_text(encoding="utf-8", errors="replace"))
    except (OSError, ValueError):
        return {}
    entries = raw.get("entries") if isinstance(raw, dict) else None
    if not isinstance(entries, dict):
        return {}
    return {
        str(k): str(v)
        for k, v in entries.items()
        if isinstance(v, str) and (v in ("KILLED", "SURVIVED") or _parse_cached_timeout(v) is not None)
    }


def _spec_deps_digest(
    root: Path,
    spec_rel: str,
    files_map: object,
    dep_graph: graph.DependencyGraph,
    sha_memo: dict[str, str],
) -> str:
    deps: set[str] = set(dep_graph.dependencies(spec_rel, transitive=True))
    if isinstance(files_map, dict):
        for raw_src in files_map:
            src_norm = graph._norm_rel(raw_src, root)
            if (root / src_norm).is_file():
                deps.add(src_norm)
    deps.discard(spec_rel)
    pairs = [(d, _file_sha256_cached(root, d, sha_memo)) for d in sorted(deps)]
    return hashlib.sha256(json.dumps(pairs, separators=(",", ":")).encode("utf-8")).hexdigest()


def _norm_spec_token(path_str: str) -> str:
    cleaned = path_str.strip().lstrip("@=").replace("\\", "/").lower()
    if cleaned.startswith("./"):
        cleaned = cleaned[2:]
    for suffix in (".luau", ".lua"):
        if cleaned.endswith(suffix):
            cleaned = cleaned[: -len(suffix)]
            break
    if cleaned.endswith(".spec"):
        cleaned = cleaned[:-5]
    return cleaned


def _specs_for_file_filter(spec_filter: str | None, all_specs_norm: list[str]) -> list[str]:
    if not isinstance(spec_filter, str) or not spec_filter.startswith("@file="):
        return []
    wanted = [_norm_spec_token(part) for part in spec_filter[6:].split(",")]
    wanted = [part for part in wanted if part]
    if not wanted:
        return []
    matched: list[str] = []
    for spec in all_specs_norm:
        norm = _norm_spec_token(spec)
        base = norm.rsplit("/", 1)[-1]
        if any(norm == item or base == item or norm.endswith("/" + item) for item in wanted):
            matched.append(spec)
    return matched


def _save_mutant_cache(cache_path: Path, entries: dict[str, str]) -> None:
    try:
        cache_path.parent.mkdir(parents=True, exist_ok=True)
        write_atomic(
            cache_path,
            json.dumps({"version": 1, "entries": entries}, sort_keys=True, separators=(",", ":")).encode("utf-8"),
        )
    except OSError:
        pass


_SPEC_STEM_STOPWORDS = frozenset({"and", "init", "shared", "src", "client", "server"})
_SPEC_TOKEN_RE = re.compile(r"[A-Z]?[a-z]+|[A-Z]+(?=[A-Z][a-z]|\d|\b)|[A-Z]+|\d+")


def _spec_stem_tokens(raw_stem: str) -> set[str]:
    tokens = {raw_stem.lower()}
    for tok in _SPEC_TOKEN_RE.findall(raw_stem):
        low = tok.lower()
        if low and low not in _SPEC_STEM_STOPWORDS:
            tokens.add(low)
    return tokens


def _spec_stem(rel_path: str) -> str:
    name = Path(rel_path).name
    for suffix in (".spec.luau", ".spec.lua", ".luau", ".lua"):
        if name.endswith(suffix):
            return name[: -len(suffix)]
    return Path(name).stem


def _prioritize_route_specs(
    rel_file: str,
    covering_specs: tuple[str, ...],
    dep_graph: graph.DependencyGraph,
    root: Path,
    specs_cov: dict[str, dict] | None = None,
) -> tuple[str, ...]:
    """Keep single covering spec as-is; otherwise front stem/token matches and direct 1-hop importers."""
    if len(covering_specs) <= 1:
        return covering_specs
    rel_norm = graph._norm_rel(rel_file, root)
    path_obj = Path(rel_norm)
    stem = (graph._classify_script_name(path_obj.name) or path_obj.stem).lower()
    stems: set[str] = set()
    if stem and stem != "init":
        stems.add(stem)
    for part in path_obj.parts[:-1]:
        low = part.lower()
        if low and low not in _SPEC_STEM_STOPWORDS:
            stems.add(low)
    direct = dep_graph.reverse.get(rel_norm, set())

    tier1: list[str] = []
    tier2: list[str] = []
    tier3: list[str] = []
    for spec in covering_specs:
        spec_tokens = _spec_stem_tokens(_spec_stem(spec))
        if spec_tokens & stems:
            tier1.append(spec)
        elif graph._norm_rel(spec, root) in direct:
            tier2.append(spec)
        else:
            tier3.append(spec)

    def _rank_tier(tier: list[str]) -> list[str]:
        if not specs_cov or len(tier) <= 1:
            return tier
        counts: dict[str, int] = {}
        for spec in tier:
            entry = specs_cov.get(graph._norm_rel(spec, root))
            fmap = entry.get("files") if isinstance(entry, dict) else None
            hits = fmap.get(rel_norm) if isinstance(fmap, dict) else None
            counts[spec] = len(hits) if isinstance(hits, list) else 0
        max_hits = max(counts.values(), default=0)
        if max_hits <= 0:
            return tier
        threshold = max_hits * 0.5
        indexed = list(enumerate(tier))
        indexed.sort(key=lambda pair: (0 if counts[pair[1]] >= threshold else 1, pair[0]))
        return [spec for _idx, spec in indexed]

    return tuple(_rank_tier(tier1) + _rank_tier(tier2) + _rank_tier(tier3))


def _resolve_probe_cov_rel(src_name: str, probe_dir: Path, work_root: Path, root: Path) -> str | None:
    rel = coverage_rel_path(src_name, work_root) or coverage_rel_path(src_name, root)
    if rel is None and not os.path.isabs(src_name):
        cand = str((probe_dir / src_name).resolve())
        rel = coverage_rel_path(cand, work_root) or coverage_rel_path(cand, root)
    if rel is not None and rel.startswith(".sert/mutate/overlay/"):
        rel = rel[len(".sert/mutate/overlay/") :]
    return rel


def _collect_per_spec_trace(
    root: Path,
    work_root: Path,
    luau_bin: str,
    entries: list[str],
    specs_to_probe: list[str],
    pool: ThreadPoolExecutor,
    timeout_sec: float,
    codegen: bool,
    program_args: list[str] | tuple[str, ...],
    key_to_file_line: dict[int, tuple[str, int]],
) -> dict[str, dict[str, object]]:
    """Run 1-pass per-spec LCOV + `--trace-mutants` probes in isolated `.sert/mutate/cov-*` dirs."""
    if not specs_to_probe or not entries:
        return {}
    probe_timeout = max(timeout_sec * BASELINE_TIMEOUT_FACTOR, BASELINE_TIMEOUT_FLOOR)

    def probe_one(idx: int, spec: str) -> tuple[str, dict[str, object] | None]:
        probe_dir = work_root.parent / f"cov-{idx}"
        shutil.rmtree(probe_dir, ignore_errors=True)
        probe_dir.mkdir(parents=True, exist_ok=True)
        try:
            run_targets = [spec] if spec in entries else list(entries)
            extra = [*program_args, *([] if spec in entries else [f"--filter=@file={spec}"]), "--trace-mutants", "--silent"]
            merged_hits: dict[str, set[int]] = {}
            traced_tests: list[dict[str, object]] = []
            got_cov = False
            all_ok = True
            started = time.monotonic()
            for entry in run_targets:
                cov_file = probe_dir / "coverage.out"
                cov_file.unlink(missing_ok=True)
                script_target = work_root / entry
                if not script_target.is_file():
                    script_target = root / entry
                cmd = run_mod.entry_command(
                    "luau",
                    luau_bin,
                    str(script_target.resolve()),
                    extra,
                    coverage=True,
                    codegen=codegen,
                )
                try:
                    res = _run_process(cmd, cwd=probe_dir, timeout=probe_timeout, capture_output=True)
                except (subprocess.TimeoutExpired, OSError):
                    all_ok = False
                    continue
                if res.returncode != 0:
                    all_ok = False
                for raw_line in (res.stdout or "").splitlines():
                    m = _TRACE_LINE_RE.match(raw_line.strip())
                    if not m:
                        continue
                    t_idx = int(m.group(1))
                    try:
                        t_ms = float(m.group(2)) if m.group(2) else 0.0
                    except ValueError:
                        t_ms = 0.0
                    keys_csv = m.group(3).strip()
                    t_name = m.group(5)
                    t_files: dict[str, set[int]] = {}
                    if keys_csv:
                        for raw_k in keys_csv.split(","):
                            raw_k = raw_k.strip()
                            if not raw_k.isdigit():
                                continue
                            mapped = key_to_file_line.get(int(raw_k))
                            if mapped is None:
                                continue
                            f_rel, ln = mapped
                            t_files.setdefault(f_rel, set()).add(ln)
                    traced_tests.append(
                        {
                            "idx": t_idx,
                            "name": t_name,
                            "ms": round(t_ms, 3),
                            "files": {f: sorted(lines) for f, lines in t_files.items() if lines},
                        }
                    )
                if cov_file.is_file():
                    got_cov = True
                    try:
                        parsed = coverage_mod.parse(cov_file)
                    except OSError:
                        continue
                    for src_name, lines_map in parsed.items():
                        src_rel = _resolve_probe_cov_rel(src_name, probe_dir, work_root, root)
                        if src_rel is None:
                            continue
                        hit_set = merged_hits.setdefault(src_rel, set())
                        for ln, hit in lines_map.items():
                            if hit:
                                hit_set.add(ln)
            if not got_cov and not traced_tests:
                return spec, None
            total_ms = max(0, int(round((time.monotonic() - started) * 1000)))
            cov_files_map = {src_rel: sorted(lines) for src_rel, lines in merged_hits.items() if lines}
            return spec, {
                "ms": total_ms,
                "ok": all_ok,
                "cov_files": cov_files_map,
                "tests": traced_tests,
            }
        finally:
            shutil.rmtree(probe_dir, ignore_errors=True)

    futs = [pool.submit(probe_one, idx, spec) for idx, spec in enumerate(specs_to_probe)]
    results: dict[str, dict[str, object]] = {}
    for fut in futs:
        spec, res = fut.result()
        if res is not None:
            results[spec] = res
    return results


def _pack_adaptive_batches(
    mutants: list[Mutant],
    est_ms_by_id: dict[int, float],
    worker_count: int,
    total_ready: int,
    target_ms: float = TARGET_BATCH_MS,
    max_batch: int = BATCH_SIZE,
    survival_weight: float = EXPECTED_SURVIVAL_WEIGHT,
    weight_by_id: dict[int, float] | None = None,
) -> list[tuple[list[Mutant], float]]:
    if not mutants:
        return []
    dyn_max = max(1, min(max_batch, (max(1, total_ready) + max(1, worker_count) - 1) // max(1, worker_count)))
    batches: list[tuple[list[Mutant], float]] = []
    cur: list[Mutant] = []
    cur_ms = 0.0
    for m in mutants:
        w = weight_by_id.get(m.id, survival_weight) if weight_by_id is not None else survival_weight
        m_ms = max(1.0, float(est_ms_by_id.get(m.id, 10.0)) * w)
        if cur and (len(cur) >= dyn_max or cur_ms + m_ms > target_ms):
            batches.append((cur, cur_ms))
            cur = []
            cur_ms = 0.0
        cur.append(m)
        cur_ms += m_ms
    if cur:
        batches.append((cur, cur_ms))
    return batches


@dataclass(slots=True)
class _MutateSettings:
    cfg: config_mod.Config
    cache_mode: str
    codegen: bool
    benign_calls: list[str]
    cosmetic_props: list[str]
    operators: tuple[str, ...]
    source_prefixes: list[str]
    include: list[str]
    exclude: list[str]
    explicit_timeout: bool
    timeout_sec: float
    minimum: float | int | None
    max_mutants: int | None
    jobs: int
    specs_map: dict[str, str]
    program_args: list[str]
    no_cache: bool


def _is_verified_cov(entry: object) -> bool:
    return isinstance(entry, dict) and entry.get("exact") is not False and "sha256" in entry


def _resolve_mutate_settings(args) -> _MutateSettings:
    no_cache = bool(getattr(args, "no_cache", False))
    strict_cache = bool(getattr(args, "strict_cache", False))
    cfg = config_mod.from_args(args)
    table, cov_table = cfg.table("mutate"), cfg.table("coverage")
    raw_cache_mode = table.get("cache", "scoped")
    cache_mode = "strict" if strict_cache else (str(raw_cache_mode).strip().lower() or "scoped")
    if cache_mode not in ("scoped", "strict"):
        raise SertError(f"mutate: invalid [mutate].cache={raw_cache_mode!r} (expected 'scoped' or 'strict')")
    codegen = bool(table.get("codegen", cfg.get("test.codegen", True)))
    benign_calls = [str(p) for p in as_list(table.get("benign_calls"))]
    cosmetic_props = [str(p) for p in as_list(table.get("cosmetic_props"))]

    raw_ops = args.operators or table.get("operators")
    if isinstance(raw_ops, str):
        operators = tuple(op.strip() for op in raw_ops.split(",") if op.strip())
    elif isinstance(raw_ops, list):
        operators = tuple(str(op).strip() for op in raw_ops if str(op).strip())
    else:
        operators = ALL_OPERATORS
    unknown_ops = [op for op in operators if op not in ALL_OPERATORS]
    if unknown_ops:
        raise SertError(f"mutate: unknown operators {', '.join(unknown_ops)} (expected {', '.join(ALL_OPERATORS)})")

    source_prefixes_raw = as_list(table.get("include")) or as_list(cov_table.get("include")) or ["src"]
    source_prefixes = [coverage_mod.norm(str(p)).rstrip("/") for p in source_prefixes_raw]
    include_raw = args.paths or source_prefixes_raw
    include = [coverage_mod.norm(str(p)).rstrip("/") for p in include_raw]
    exclude = [coverage_mod.norm(str(p)).rstrip("/") for p in as_list(table.get("exclude"))]
    explicit_timeout = args.timeout is not None or "timeout" in table
    timeout_sec = float(args.timeout if args.timeout is not None else table.get("timeout", DEFAULT_TIMEOUT))
    minimum = args.min if args.min is not None else table.get("min")
    max_mutants_raw = args.max_mutants if args.max_mutants is not None else table.get("max_mutants")
    max_mutants = int(max_mutants_raw) if max_mutants_raw is not None else None
    jobs = int(args.jobs if args.jobs is not None else (table.get("jobs") or os.cpu_count() or 4))
    specs_map = table.get("specs") if isinstance(table.get("specs"), dict) else {}
    program_args = [str(arg) for arg in (getattr(args, "program_args", None) or [])]
    return _MutateSettings(
        cfg=cfg,
        cache_mode=cache_mode,
        codegen=codegen,
        benign_calls=benign_calls,
        cosmetic_props=cosmetic_props,
        operators=operators,
        source_prefixes=source_prefixes,
        include=include,
        exclude=exclude,
        explicit_timeout=explicit_timeout,
        timeout_sec=timeout_sec,
        minimum=minimum,
        max_mutants=max_mutants,
        jobs=jobs,
        specs_map=specs_map,
        program_args=program_args,
        no_cache=no_cache,
    )


def _prepare_baseline_coverage(
    settings: _MutateSettings,
    args,
    entries: list[str],
    runner: str,
    cov_files: dict[str, dict[int, int]] | None,
) -> dict[str, dict[int, bool]]:
    cfg = settings.cfg
    cov_path = coverage_mod.output_path(cfg, cfg.root, args.coverage_file)
    if not cov_path.is_file():
        if args.no_coverage_run:
            raise SertError(f"mutate: cannot read {cov_path}: file not found")
        cov_path.parent.mkdir(parents=True, exist_ok=True)
        run_cov_target = coverage_mod.output_path(cfg, cfg.root)
        prior_cov = run_cov_target.read_bytes() if (cov_path != run_cov_target and run_cov_target.is_file()) else None
        try:
            baseline = run_mod.run_entries(
                cfg,
                entries,
                runner=runner,
                coverage=True,
                echo=False,
                markers=False,
                program_args=settings.program_args,
            )
            if baseline.status != 0:
                detail = "\n".join(run.output.strip() for run in baseline.entries if run.code != 0 and run.output.strip())
                raise SertError(
                    f"mutate: the baseline `sert run --coverage` failed (status {baseline.status}); the unmutated suite must pass before mutants can be scored"
                    + (f"\n{detail[-4000:]}" if detail else "")
                )
            if cov_path != run_cov_target and run_cov_target.is_file():
                cov_path.write_text(run_cov_target.read_text(encoding="utf-8", errors="replace"), encoding="utf-8")
        finally:
            if cov_path != run_cov_target:
                if prior_cov is not None:
                    run_cov_target.write_bytes(prior_cov)
                elif run_cov_target.is_file():
                    run_cov_target.unlink()
        if not cov_path.is_file():
            raise SertError(f"mutate: baseline `sert run --coverage` did not produce {cov_path.name}")

    if cov_files is not None:
        return root_relative_coverage(cov_files, cfg.root)
    try:
        return root_relative_coverage(coverage_mod.parse(cov_path), cfg.root)
    except OSError as err:
        raise SertError(f"mutate: cannot read {cov_path}: {err}")


def _resolve_trace_and_coverage_maps(
    cfg: config_mod.Config,
    work_root: Path,
    luau_bin: str,
    entries: list[str],
    staged_tasks: list[tuple[Path, Path, str, str, list[Mutant]]],
    all_mutants: list[Mutant],
    pool: ThreadPoolExecutor,
    *,
    runner: str,
    timeout_sec: float,
    codegen: bool,
    program_args: list[str],
    dep_graph,
):
    all_specs = graph.discover_specs(cfg.root, cfg)
    if dep_graph is None:
        dep_graph = graph.build_graph(cfg.root, cfg)
    cov_map = graph.load_coverage_map(cfg.root)
    trace_path = cfg.root / TRACE_MAP_FILE
    trace_map = _load_trace_map(trace_path)
    spec_sha_memo: dict[str, str] = {}
    all_specs_norm = [graph._norm_rel(s, cfg.root) for s in all_specs]
    raw_specs_cov = cov_map.get("specs") if isinstance(cov_map.get("specs"), dict) else {}
    specs_cov = {graph._norm_rel(k, cfg.root): v for k, v in raw_specs_cov.items() if isinstance(v, dict)}
    raw_trace_specs = trace_map.get("specs") if isinstance(trace_map.get("specs"), dict) else {}
    trace_specs = {graph._norm_rel(k, cfg.root): v for k, v in raw_trace_specs.items() if isinstance(v, dict)}

    tokens_digest_by_file: dict[str, str] = {
        file_muts[0].file: _normalized_tokens_digest(source_text)
        for _sp, _stp, source_text, _inst, file_muts in staged_tasks
        if file_muts
    }
    instr_lines_by_norm: dict[str, set[int]] = {}
    key_to_file_line: dict[int, tuple[str, int]] = {}
    for m in all_mutants:
        m_norm = graph._norm_rel(m.file, cfg.root)
        instr_lines_by_norm.setdefault(m_norm, set()).add(m.line)
        key_to_file_line[m.line_key] = (m_norm, m.line)
    file_trace_sig_by_norm: dict[str, str] = {}
    for _sp, _stp, _source_text, _inst, file_muts in staged_tasks:
        if not file_muts:
            continue
        f_raw = file_muts[0].file
        f_norm = graph._norm_rel(f_raw, cfg.root)
        file_trace_sig_by_norm[f_norm] = _file_trace_sig(
            tokens_digest_by_file[f_raw], instr_lines_by_norm.get(f_norm, set())
        )

    uses_file_override = any(
        isinstance(m.spec_filter, str) and m.spec_filter.startswith("@file=")
        for m in all_mutants
    )
    has_unfiltered = any(m.spec_filter is None for m in all_mutants)
    has_sert_specs = bool(cfg.get("test.specs")) or any(".spec." in s for s in all_specs_norm)
    should_probe = (
        runner == "luau"
        and len(all_specs_norm) >= 1
        and (len(all_specs_norm) > 1 or has_sert_specs)
        and (has_unfiltered or uses_file_override or len(all_specs_norm) == 1)
    )
    probed: dict[str, dict[str, object]] = {}
    if should_probe:
        map_specs = cov_map.setdefault("specs", {})
        t_map_specs = trace_map.setdefault("specs", {})
        stale_deleted = [k for k in list(map_specs) if not (cfg.root / graph._norm_rel(k, cfg.root)).is_file()]
        for dead_key in stale_deleted:
            del map_specs[dead_key]
        t_deleted = [k for k in list(t_map_specs) if not (cfg.root / graph._norm_rel(k, cfg.root)).is_file()]
        for dead_key in t_deleted:
            del t_map_specs[dead_key]
        if stale_deleted:
            specs_cov = {graph._norm_rel(k, cfg.root): v for k, v in map_specs.items() if isinstance(v, dict)}
        if t_deleted:
            trace_specs = {graph._norm_rel(k, cfg.root): v for k, v in t_map_specs.items() if isinstance(v, dict)}

        if has_unfiltered or len(all_specs_norm) == 1:
            candidate_specs = all_specs_norm
        else:
            cand_set: set[str] = set()
            for filt in {
                m.spec_filter
                for m in all_mutants
                if isinstance(m.spec_filter, str) and m.spec_filter.startswith("@file=")
            }:
                cand_set.update(_specs_for_file_filter(filt, all_specs_norm))
            candidate_specs = [s for s in all_specs_norm if s in cand_set] if cand_set else all_specs_norm

        stale_specs: list[str] = []
        for s in candidate_specs:
            c_entry = specs_cov.get(s)
            if _is_preseeded_exact(c_entry):
                continue
            cur_spec_sha = _file_sha256_cached(cfg.root, s, spec_sha_memo)
            if not isinstance(c_entry, dict) or c_entry.get("exact") is False or "sha256" not in c_entry:
                stale_specs.append(s)
                continue
            if c_entry.get("sha256") != cur_spec_sha:
                stale_specs.append(s)
                continue
            cur_deps_sha = _spec_deps_digest(cfg.root, s, c_entry.get("files"), dep_graph, spec_sha_memo)
            if c_entry.get("deps_sha256") != cur_deps_sha:
                stale_specs.append(s)
                continue
            t_entry = trace_specs.get(s)
            if (
                not isinstance(t_entry, dict)
                or t_entry.get("sha256") != cur_spec_sha
                or t_entry.get("deps_sha256") != cur_deps_sha
                or not isinstance(t_entry.get("files"), dict)
                or not isinstance(t_entry.get("tests"), list)
            ):
                stale_specs.append(s)
                continue
            c_files = c_entry.get("files")
            c_file_norms = {graph._norm_rel(raw_f, cfg.root) for raw_f in c_files} if isinstance(c_files, dict) else set()
            t_files = t_entry["files"]
            if any(t_norm in c_file_norms and t_files.get(t_norm) != t_sig for t_norm, t_sig in file_trace_sig_by_norm.items()):
                stale_specs.append(s)

        if stale_specs:
            probed = _collect_per_spec_trace(
                cfg.root,
                work_root,
                luau_bin,
                entries,
                stale_specs,
                pool,
                timeout_sec,
                codegen,
                program_args,
                key_to_file_line,
            )
            for s, pdata in probed.items():
                ms = int(pdata["ms"])  # type: ignore[arg-type]
                cov_files_map = pdata["cov_files"]  # type: ignore[assignment]
                spec_sha = _file_sha256_cached(cfg.root, s, spec_sha_memo)
                deps_sha = _spec_deps_digest(cfg.root, s, cov_files_map, dep_graph, spec_sha_memo)
                map_specs[s] = {"ms": ms, "sha256": spec_sha, "deps_sha256": deps_sha, "files": cov_files_map}
                old_t = trace_specs.get(s)
                new_tests = list(pdata["tests"])  # type: ignore[arg-type]
                if (
                    isinstance(old_t, dict)
                    and old_t.get("sha256") == spec_sha
                    and old_t.get("deps_sha256") == deps_sha
                    and isinstance(old_t.get("files"), dict)
                    and isinstance(old_t.get("tests"), list)
                ):
                    merged_files = dict(old_t["files"])
                    merged_files.update(file_trace_sig_by_norm)
                    old_by_key = {
                        (t.get("idx"), t.get("name")): dict(t) for t in old_t["tests"] if isinstance(t, dict)
                    }
                    merged_tests: list[dict[str, object]] = []
                    for nt in new_tests:
                        prev_t = old_by_key.get((nt.get("idx"), nt.get("name")))
                        if prev_t and isinstance(prev_t.get("files"), dict):
                            combined_f = {
                                f_k: f_v for f_k, f_v in prev_t["files"].items() if f_k not in file_trace_sig_by_norm
                            }
                            combined_f.update(nt.get("files") or {})  # type: ignore[arg-type]
                            merged_tests.append({**nt, "files": combined_f})
                        else:
                            merged_tests.append(nt)
                else:
                    merged_files = dict(file_trace_sig_by_norm)
                    merged_tests = new_tests
                t_map_specs[s] = {
                    "ms": ms,
                    "sha256": spec_sha,
                    "deps_sha256": deps_sha,
                    "files": merged_files,
                    "tests": merged_tests,
                }
            specs_cov = {graph._norm_rel(k, cfg.root): v for k, v in map_specs.items() if isinstance(v, dict)}
            trace_specs = {graph._norm_rel(k, cfg.root): v for k, v in t_map_specs.items() if isinstance(v, dict)}
        if probed or stale_deleted:
            graph.save_coverage_map(cfg.root, cov_map)
        if probed or t_deleted:
            _save_trace_map(trace_path, trace_map)

    has_verified_exact = len(all_specs_norm) > 1 and all(_is_verified_cov(specs_cov.get(s)) for s in all_specs_norm)
    exact_index: dict[tuple[str, int], list[str]] = {}
    ordered_specs = sorted(
        (s for s in all_specs_norm if _is_verified_cov(specs_cov.get(s))),
        key=lambda s: (
            int(specs_cov[s]["ms"])
            if isinstance(specs_cov[s].get("ms"), (int, float))
            and not isinstance(specs_cov[s].get("ms"), bool)
            else sys.maxsize,
            s,
        ),
    )
    for s in ordered_specs:
        files_map = specs_cov[s].get("files")
        if not isinstance(files_map, dict):
            continue
        for raw_src, hit_lines in files_map.items():
            if isinstance(hit_lines, list):
                src_norm = graph._norm_rel(raw_src, cfg.root)
                for ln in hit_lines:
                    exact_index.setdefault((src_norm, ln), []).append(s)

    trace_line_hits: dict[tuple[str, str, int], list[tuple[int, str, float]]] = {}
    spec_test_counts: dict[str, int] = {}
    for s, t_entry in trace_specs.items():
        tests_list = t_entry.get("tests")
        t_files = t_entry.get("files")
        if not isinstance(tests_list, list) or not isinstance(t_files, dict):
            continue
        traced_targets = {f for f, sig in file_trace_sig_by_norm.items() if t_files.get(f) == sig}
        if not traced_targets:
            continue
        spec_test_counts[s] = len(tests_list)
        for t_rec in tests_list:
            if not isinstance(t_rec, dict) or not isinstance(t_rec.get("idx"), int):
                continue
            t_idx, t_name, t_ms = int(t_rec["idx"]), str(t_rec.get("name", "")), float(t_rec.get("ms", 0.0) or 0.0)
            files_hit = t_rec.get("files")
            if not isinstance(files_hit, dict):
                continue
            for f_rel, hit_lines in files_hit.items():
                if f_rel in traced_targets and isinstance(hit_lines, list):
                    for ln in hit_lines:
                        trace_line_hits.setdefault((s, f_rel, int(ln)), []).append((t_idx, t_name, t_ms))

    line_cov_cache: dict[tuple[str, int], tuple[str, ...]] = {}
    allowed_specs_cache: dict[str, tuple[list[str], set[str], bool]] = {}
    if all_specs:
        for m in all_mutants:
            if m.spec_filter is None:
                ck = (m.file, m.line)
                if ck not in line_cov_cache:
                    m_norm = graph._norm_rel(m.file, cfg.root)
                    if has_verified_exact and (exact_hits := exact_index.get((m_norm, m.line))):
                        line_cov_cache[ck] = tuple(exact_hits)
                    else:
                        line_cov_cache[ck] = tuple(
                            graph.covering_specs_for_line(
                                cfg.root,
                                cfg,
                                m.file,
                                m.line,
                                all_specs,
                                cov_map=cov_map,
                                dep_graph=dep_graph,
                            )
                        )
                m.covering_specs = line_cov_cache[ck]
            elif m.spec_filter.startswith("@file="):
                allowed_tuple = allowed_specs_cache.get(m.spec_filter)
                if allowed_tuple is None:
                    allowed_list = _specs_for_file_filter(m.spec_filter, all_specs_norm)
                    allowed_verified = (
                        len(all_specs_norm) > 1
                        and bool(allowed_list)
                        and all(_is_verified_cov(specs_cov.get(s)) for s in allowed_list)
                    )
                    allowed_tuple = (allowed_list, set(allowed_list), allowed_verified)
                    allowed_specs_cache[m.spec_filter] = allowed_tuple
                allowed_list, allowed_set, allowed_verified = allowed_tuple
                if allowed_verified and allowed_list:
                    m_norm = graph._norm_rel(m.file, cfg.root)
                    exact_hits = exact_index.get((m_norm, m.line)) or []
                    intersected = [s for s in exact_hits if s in allowed_set]
                    m.covering_specs = (
                        tuple(intersected)
                        if intersected
                        else (tuple(exact_hits) if exact_hits else tuple(allowed_list))
                    )
                    m.spec_filter = None

    return (
        all_specs,
        all_specs_norm,
        dep_graph,
        specs_cov,
        probed,
        trace_line_hits,
        spec_test_counts,
        tokens_digest_by_file,
        spec_sha_memo,
    )


def _filter_mutant_cache(
    settings: _MutateSettings,
    runner: str,
    entries: list[str],
    all_specs: list[str],
    all_specs_norm: list[str],
    dep_graph,
    specs_cov: dict[str, dict],
    trace_line_hits: dict[tuple[str, str, int], list[tuple[int, str, float]]],
    tokens_digest_by_file: dict[str, str],
    spec_sha_memo: dict[str, str],
    all_mutants: list[Mutant],
):
    cfg = settings.cfg
    cache_path = cfg.root / CACHE_FILE
    cache_entries = _load_mutant_cache(cache_path)
    dep_refs_memo: dict[tuple[str, tuple[str, ...], str], list[str]] = {}
    cache_keys: dict[int, str] = {}
    uncached_mutants: list[Mutant] = []
    cached_count = 0
    fallback_specs = sorted(all_specs) if all_specs else list(entries)
    env_hash = _mutate_env_hash(cfg, runner, settings.codegen, settings.program_args, all_specs, spec_sha_memo)
    mutant_floor = settings.timeout_sec if settings.explicit_timeout else min(settings.timeout_sec, MIN_MUTANT_TIMEOUT)

    for m in all_mutants:
        m_norm = graph._norm_rel(m.file, cfg.root)
        if m.covering_specs:
            base_refs = list(m.covering_specs)
        elif matched := _specs_for_file_filter(m.spec_filter, all_specs_norm):
            base_refs = matched
        else:
            base_refs = fallback_specs
        memo_key = (m.file, tuple(base_refs), settings.cache_mode)
        spec_refs = dep_refs_memo.get(memo_key)
        if spec_refs is None:
            refs_set: set[str] = set(base_refs)
            for s in base_refs:
                s_norm = graph._norm_rel(s, cfg.root)
                if settings.cache_mode == "strict":
                    for dep in dep_graph.dependencies(s_norm, transitive=True):
                        if dep != m_norm and (cfg.root / dep).is_file():
                            refs_set.add(dep)
                    spec_entry = specs_cov.get(s_norm)
                    files_map = spec_entry.get("files") if isinstance(spec_entry, dict) else None
                    if isinstance(files_map, dict):
                        for raw_src in files_map:
                            src_norm = graph._norm_rel(raw_src, cfg.root)
                            if src_norm != m_norm and (cfg.root / src_norm).is_file():
                                refs_set.add(src_norm)
                else:
                    refs_set.update(_test_only_deps(s_norm, dep_graph, settings.source_prefixes, settings.exclude, cfg.root))
            if settings.cache_mode != "strict":
                for dep in dep_graph.dependencies(m_norm, transitive=True):
                    if dep != m_norm and not dep.startswith(".sert/") and (cfg.root / dep).is_file():
                        refs_set.add(dep)
            refs_set.discard(m_norm)
            spec_refs = sorted(refs_set)
            dep_refs_memo[memo_key] = spec_refs
        spec_hashes = [(s, _file_sha256_cached(cfg.root, s, spec_sha_memo)) for s in spec_refs]
        extra_trace: list[tuple[str, list[str]]] | None = None
        if not m.top_level:
            traced_pairs: list[tuple[str, list[str]]] = []
            for s_norm in sorted({graph._norm_rel(r, cfg.root) for r in base_refs}):
                hits = trace_line_hits.get((s_norm, m_norm, m.line))
                if hits:
                    traced_pairs.append((s_norm, sorted({name for _idx, name, _ms in hits})))
            if traced_pairs:
                extra_trace = traced_pairs
        ckey = _mutant_cache_key(
            tokens_digest_by_file[m.file],
            m,
            spec_hashes,
            VERSION,
            cache_mode=settings.cache_mode,
            extra=extra_trace,
            env_hash=env_hash,
        )
        cache_keys[m.id] = ckey
        cached_status = None if settings.no_cache else cache_entries.get(ckey)
        if cached_status in ("KILLED", "SURVIVED"):
            m.status = cached_status
            cached_count += 1
        elif (
            isinstance(cached_status, str)
            and (cached_t := _parse_cached_timeout(cached_status)) is not None
            and (
                (not settings.explicit_timeout and cached_t >= mutant_floor - 1e-6)
                or cached_t >= settings.timeout_sec - 1e-6
            )
        ):
            m.status = "TIMEOUT"
            cached_count += 1
        else:
            uncached_mutants.append(m)

    return cache_path, cache_entries, cache_keys, cached_count, uncached_mutants, mutant_floor


_RouteKey = tuple[str, tuple[str, ...], str | None]


def _spec_stage_cost(
    spec: str,
    mutant: Mutant,
    m_norm: str,
    specs_cov: dict[str, dict],
    trace_line_hits: dict[tuple[str, str, int], list[tuple[int, str, float]]],
) -> float:
    if not mutant.top_level:
        hits = trace_line_hits.get((spec, m_norm, mutant.line))
        if hits:
            seen_t: set[int] = set()
            cost = 0.0
            for t_idx, _t_nm, t_ms in hits:
                if t_idx not in seen_t:
                    seen_t.add(t_idx)
                    cost += max(1.0, t_ms)
            return cost
    s_entry = specs_cov.get(spec)
    return float(s_entry.get("ms", 1e9) or 1e9) if isinstance(s_entry, dict) else 1e9


class _MutantBatchDispatcher:
    def __init__(
        self,
        settings: _MutateSettings,
        work_root: Path,
        luau_bin: str,
        runner: str,
        entries: list[str],
        all_specs: list[str],
        all_specs_norm: list[str],
        dep_graph,
        specs_cov: dict[str, dict],
        probed: dict[str, dict[str, object]],
        trace_line_hits: dict[tuple[str, str, int], list[tuple[int, str, float]]],
        spec_test_counts: dict[str, int],
        uncached_mutants: list[Mutant],
        mutant_floor: float,
        pool: ThreadPoolExecutor,
    ) -> None:
        self.settings = settings
        self.work_root = work_root
        self.luau_bin = luau_bin
        self.runner = runner
        self.entries = entries
        self.all_specs = all_specs
        self.all_specs_norm = all_specs_norm
        self.dep_graph = dep_graph
        self.specs_cov = specs_cov
        self.trace_line_hits = trace_line_hits
        self.spec_test_counts = spec_test_counts
        self.uncached_mutants = uncached_mutants
        self.mutant_floor = mutant_floor
        self.pool = pool
        self.worker_count = max(1, settings.jobs)
        self.max_in_flight = 1 if self.worker_count == 1 else self.worker_count * 2
        self.baseline_cache: dict[tuple[str, str], float] = {}
        self.eff_timeout_by_id: dict[int, float] = {}
        self.orig_spec_filter: dict[int, str | None] = {m.id: m.spec_filter for m in uncached_mutants}
        self.stages_by_id: dict[int, list[_RouteKey]] = {}
        self.stage_of_id: dict[int, int] = {m.id: 0 for m in uncached_mutants}
        self.ready_by_route: dict[_RouteKey, list[Mutant]] = {}
        self.pending: dict[object, tuple] = {}

        if not settings.explicit_timeout:
            self._seed_baselines(probed)
        self._build_stages()
        for m in uncached_mutants:
            self.ready_by_route.setdefault(self.stages_by_id[m.id][0], []).append(m)

    def _seed_baselines(self, probed: dict[str, dict[str, object]]) -> None:
        entries = self.entries
        for s, pdata in probed.items():
            if not pdata.get("ok"):
                continue
            elapsed_s = (float(pdata.get("ms", 0) or 0) / 1000.0) * COV_OVERHEAD_FACTOR
            if s in entries:
                self.baseline_cache[("", s)] = elapsed_s
            else:
                for e in entries:
                    self.baseline_cache[(f"@file={s}", e)] = elapsed_s
        for s, s_entry in self.specs_cov.items():
            if not _is_verified_cov(s_entry):
                continue
            ms_val = s_entry.get("ms")
            if not isinstance(ms_val, (int, float)) or isinstance(ms_val, bool):
                continue
            elapsed_s = (float(ms_val) / 1000.0) * COV_OVERHEAD_FACTOR
            if s in entries:
                self.baseline_cache.setdefault(("", s), elapsed_s)
            else:
                for e in entries:
                    self.baseline_cache.setdefault((f"@file={s}", e), elapsed_s)

    def ensure_baselines(self, filter_entries_pairs: set[tuple[str, str]]) -> None:
        missing = sorted(pair for pair in filter_entries_pairs if pair not in self.baseline_cache)
        if not missing:
            return
        cfg_t = self.settings
        futs = {
            (filt, entry): self.pool.submit(
                baseline_run,
                self.runner,
                self.luau_bin,
                entry,
                filt or None,
                self.work_root,
                cfg_t.timeout_sec,
                cfg_t.codegen,
                cfg_t.program_args,
                enforce_limit=cfg_t.explicit_timeout,
            )
            for filt, entry in missing
        }
        for key, fut in futs.items():
            self.baseline_cache[key] = fut.result()

    def timeout_for(self, filt: str, stage_entries: tuple[str, ...] | list[str]) -> float:
        max_elapsed = max((self.baseline_cache.get((filt, e), 0.0) for e in stage_entries), default=0.0)
        return max(self.mutant_floor, BASELINE_FACTOR * max_elapsed)

    def _build_stages(self) -> None:
        root = self.settings.cfg.root
        entries_tuple = tuple(self.entries)
        single_spec_cache: dict[str, str | None] = {}
        for m in self.uncached_mutants:
            if m.spec_filter is not None or not m.covering_specs:
                filt = m.spec_filter or ""
                if filt not in single_spec_cache:
                    if m.spec_filter is None and len(self.all_specs_norm) == 1:
                        single_spec_cache[filt] = self.all_specs_norm[0]
                    elif filt.startswith("@file="):
                        matched = _specs_for_file_filter(filt, self.all_specs_norm)
                        single_spec_cache[filt] = matched[0] if len(matched) == 1 else None
                    else:
                        single_spec_cache[filt] = None
                self.stages_by_id[m.id] = [(filt, entries_tuple, single_spec_cache[filt])]
                continue

            plan = _prioritize_route_specs(m.file, m.covering_specs, self.dep_graph, root, specs_cov=self.specs_cov)
            if len(plan) > 2 and self.trace_line_hits:
                m_norm = graph._norm_rel(m.file, root)
                plan = (plan[0],) + tuple(
                    spec
                    for _cost, _i, spec in sorted(
                        (_spec_stage_cost(s, m, m_norm, self.specs_cov, self.trace_line_hits), i, s)
                        for i, s in enumerate(plan[1:])
                    )
                )
            plan_traced = any(s in self.spec_test_counts for s in plan)
            max_ind = MAX_TRACE_INDIVIDUAL_STAGES if plan_traced else MAX_INDIVIDUAL_ROUTE_STAGES
            m_stages: list[_RouteKey] = []
            for spec in plan[:max_ind]:
                s_entries = (spec,) if spec in entries_tuple else entries_tuple
                s_filter = "" if spec in entries_tuple else f"@file={spec}"
                m_stages.append((s_filter, s_entries, spec))
            if len(plan) > max_ind:
                tail = plan[max_ind:]
                if len(tail) == 1:
                    spec = tail[0]
                    s_entries = (spec,) if spec in entries_tuple else entries_tuple
                    s_filter = "" if spec in entries_tuple else f"@file={spec}"
                    m_stages.append((s_filter, s_entries, spec))
                elif all(s in entries_tuple for s in tail):
                    m_stages.append(("", tuple(tail), None))
                elif not any(s in entries_tuple for s in tail):
                    s_filter = "" if (len(tail) >= 8 and len(tail) * 2 >= len(self.all_specs)) else f"@file={','.join(tail)}"
                    m_stages.append((s_filter, entries_tuple, None))
                else:
                    m_stages.append(("", entries_tuple, None))
            self.stages_by_id[m.id] = m_stages

    def _tests_for_stage(self, m: Mutant, single_spec: str | None) -> tuple[tuple[int, ...] | None, float]:
        if single_spec is None:
            return None, 0.0
        s_entry = self.specs_cov.get(single_spec)
        fallback_ms = float(s_entry.get("ms", 10.0) or 10.0) if isinstance(s_entry, dict) else 10.0
        if m.top_level:
            return None, max(1.0, fallback_ms)
        m_norm = graph._norm_rel(m.file, self.settings.cfg.root)
        hits = self.trace_line_hits.get((single_spec, m_norm, m.line))
        if not hits:
            return None, max(1.0, fallback_ms)
        seen_idx: set[int] = set()
        ordered_idx: list[int] = []
        est_ms = 0.0
        for t_idx, _t_name, t_ms in sorted(hits, key=lambda item: (item[2], item[0])):
            if t_idx not in seen_idx:
                seen_idx.add(t_idx)
                ordered_idx.append(t_idx)
                est_ms += max(1.0, t_ms)
        if self.spec_test_counts.get(single_spec, 0) <= 1 and len(ordered_idx) <= 1:
            return None, max(1.0, est_ms)
        return tuple(ordered_idx), max(1.0, est_ms)

    def _advance_mutant(self, m: Mutant) -> None:
        m.spec_filter = self.orig_spec_filter[m.id]
        if m.status == "SURVIVED":
            nxt = self.stage_of_id[m.id] + 1
            m_stages = self.stages_by_id[m.id]
            if nxt < len(m_stages):
                self.stage_of_id[m.id] = nxt
                self.ready_by_route.setdefault(m_stages[nxt], []).append(m)

    def _submit_ready(self) -> None:
        slots = self.max_in_flight - len(self.pending)
        if slots <= 0 or not self.ready_by_route:
            return
        self.ensure_baselines({(rk[0], e) for rk in self.ready_by_route for e in rk[1]})
        total_ready = sum(len(ms) for ms in self.ready_by_route.values())
        candidates: list[tuple[float, int, _RouteKey, list[Mutant], dict[int, tuple[int, ...]] | None, dict[int, float]]] = []
        for rk, muts in self.ready_by_route.items():
            s_filter, s_entries, single_spec = rk
            est_ms_map: dict[int, float] = {}
            mt_all: dict[int, tuple[int, ...]] = {}
            default_ms = max(10.0, (self.timeout_for(s_filter, s_entries) / BASELINE_FACTOR) * 1000.0)
            for m in muts:
                t_idxs, est_ms = self._tests_for_stage(m, single_spec)
                est_ms_map[m.id] = est_ms if est_ms > 0.0 else default_ms
                if t_idxs is not None:
                    mt_all[m.id] = t_idxs
            for tm in (m for m in muts if m.top_level):
                candidates.append((est_ms_map[tm.id], 1, rk, [tm], None, est_ms_map))
            normal_muts = [m for m in muts if not m.top_level]
            if normal_muts:
                weight_map = {
                    m.id: (EXPECTED_SURVIVAL_WEIGHT if self.stage_of_id[m.id] == 0 else LATE_STAGE_SURVIVAL_WEIGHT)
                    for m in normal_muts
                }
                for chunk, chunk_ms in _pack_adaptive_batches(
                    normal_muts, est_ms_map, self.worker_count, total_ready, weight_by_id=weight_map
                ):
                    chunk_mt = {m.id: mt_all[m.id] for m in chunk if m.id in mt_all} or None
                    candidates.append((chunk_ms, len(chunk), rk, chunk, chunk_mt, est_ms_map))

        candidates.sort(key=lambda item: (-item[0], -item[1], item[2]))
        submitted_ids: dict[_RouteKey, set[int]] = {}
        for _cms, _clen, rk, chunk, chunk_mt, est_ms_map in candidates[:slots]:
            s_filter, s_entries, _single_spec = rk
            spec_timeout = self.timeout_for(s_filter, s_entries)
            if not self.settings.explicit_timeout and chunk_mt and len(chunk_mt) == len(chunk):
                max_chunk_est_s = max(est_ms_map[m.id] for m in chunk) / 1000.0
                filt_timeout = max(self.mutant_floor, min(spec_timeout, BASELINE_FACTOR * max_chunk_est_s * COV_OVERHEAD_FACTOR))
            else:
                filt_timeout = spec_timeout
            use_defer = len(s_entries) == 1
            for m in chunk:
                m.spec_filter = s_filter or None
                self.eff_timeout_by_id[m.id] = filt_timeout
            submitted_ids.setdefault(rk, set()).update(m.id for m in chunk)
            kw = {"mutant_tests": chunk_mt} if chunk_mt else {}
            fut = self.pool.submit(
                _evaluate_mutant_batch,
                chunk,
                self.work_root,
                self.runner,
                self.luau_bin,
                list(s_entries),
                filt_timeout,
                self.settings.codegen,
                self.settings.program_args,
                use_defer,
                **kw,
            )
            self.pending[fut] = ("batch", chunk, rk, filt_timeout, use_defer, chunk_mt)
        for rk, ids_done in submitted_ids.items():
            rem = [m for m in self.ready_by_route[rk] if m.id not in ids_done]
            if rem:
                self.ready_by_route[rk] = rem
            else:
                del self.ready_by_route[rk]

    def run(self) -> dict[int, float]:
        try:
            self._submit_ready()
            while self.pending:
                done_set, _ = wait(self.pending, return_when=FIRST_COMPLETED)
                for done_fut in done_set:
                    task = self.pending.pop(done_fut)
                    if task[0] == "single":
                        done_fut.result()
                        self._advance_mutant(task[1])
                        continue
                    _kind, batch, rk, filt_timeout, use_defer, batch_mt = task
                    res = done_fut.result()
                    head, tail = res if isinstance(res, tuple) and len(res) == 2 else (None, [])
                    deferred_ids = ({head.id} if head is not None else set()) | {tm.id for tm in tail}
                    for m in batch:
                        if m.id not in deferred_ids:
                            self._advance_mutant(m)
                    s_filter, s_entries, _single_spec = rk
                    s_entries_list = list(s_entries)
                    if head is not None:
                        self._submit_single(head, rk, s_filter, s_entries_list, filt_timeout, batch_mt, retry_on_timeout=False)
                    if len(tail) == 1:
                        self._submit_single(tail[0], rk, s_filter, s_entries_list, filt_timeout, batch_mt)
                    elif len(tail) > 1:
                        for tm in tail:
                            tm.spec_filter = s_filter or None
                        t_mt = {tm.id: batch_mt[tm.id] for tm in tail if batch_mt and tm.id in batch_mt} or None
                        tkw = {"mutant_tests": t_mt} if t_mt else {}
                        self.pending[
                            self.pool.submit(
                                _evaluate_mutant_batch,
                                tail,
                                self.work_root,
                                self.runner,
                                self.luau_bin,
                                s_entries_list,
                                filt_timeout,
                                self.settings.codegen,
                                self.settings.program_args,
                                use_defer,
                                **tkw,
                            )
                        ] = ("batch", tail, rk, filt_timeout, use_defer, t_mt)
                self._submit_ready()
        finally:
            for m in self.uncached_mutants:
                m.spec_filter = self.orig_spec_filter[m.id]
        return self.eff_timeout_by_id

    def _submit_single(
        self,
        m: Mutant,
        rk: _RouteKey,
        s_filter: str,
        s_entries_list: list[str],
        filt_timeout: float,
        batch_mt: dict[int, tuple[int, ...]] | None,
        *,
        retry_on_timeout: bool | None = None,
    ) -> None:
        m.spec_filter = s_filter or None
        m_mt = {m.id: batch_mt[m.id]} if batch_mt and m.id in batch_mt else None
        kw: dict = {}
        if retry_on_timeout is not None:
            kw["retry_on_timeout"] = retry_on_timeout
        if m_mt:
            kw["mutant_tests"] = m_mt
        self.pending[
            self.pool.submit(
                _evaluate_single_mutant,
                m,
                self.work_root,
                self.runner,
                self.luau_bin,
                s_entries_list,
                filt_timeout,
                self.settings.codegen,
                self.settings.program_args,
                **kw,
            )
        ] = ("single", m, rk)


def _report_mutate_results(
    settings: _MutateSettings,
    all_mutants: list[Mutant],
    cached_count: int,
    fmt: str,
) -> int:
    cfg = settings.cfg
    minimum = settings.minimum
    if fmt == "human":
        score = summarize(all_mutants, out=sys.stderr, root=cfg.root)
        below_min = minimum is not None and score < float(minimum)
        print(f"{score:.1f}")
        if below_min:
            print(f"mutate: {score:.1f}% is below the {float(minimum):g}% floor", file=sys.stderr)
        if on_github_actions():
            survived_muts = [m for m in all_mutants if m.status == "SURVIVED"]
            level = "error" if below_min else "warning"
            for m in survived_muts[:25]:
                annotate(
                    level,
                    f"[{m.op}] `{m.original}` -> `{m.mutated}` survived",
                    file=m.file,
                    line=m.line,
                    title="sert mutate",
                )
            if below_min:
                annotate("error", f"mutate: {score:.1f}% is below the {float(minimum):g}% floor", title="sert mutate")
        return FAILED if below_min else 0

    score = summarize(all_mutants, out=io.StringIO(), root=cfg.root)
    below_min = minimum is not None and score < float(minimum)
    exit_code = FAILED if below_min else 0
    if fmt == "agent":
        print(agent.format_mutate_agent(all_mutants, root=cfg.root))
    else:
        killed = sum(1 for m in all_mutants if m.status in DETECTED)
        timed_out = sum(1 for m in all_mutants if m.status == "TIMEOUT")
        survived = [m for m in all_mutants if m.status == "SURVIVED"]
        payload = agent.json_envelope(
            "mutate",
            "failed" if below_min else "ok",
            summary={
                "score": round(score, 2),
                "total": len(all_mutants),
                "killed": killed,
                "survived": len(survived),
                "timeout": timed_out,
                "cached": cached_count,
            },
            data={
                "cached": cached_count,
                "survived": [
                    {
                        "id": m.id,
                        "file": m.file,
                        "line": m.line,
                        "op": m.op,
                        "original": m.original,
                        "mutated": m.mutated,
                        "covering_specs": list(m.covering_specs),
                    }
                    for m in survived
                ],
            },
            errors=[f"mutate: {score:.1f}% is below the {float(minimum):g}% floor"] if below_min else [],
            exit_code=exit_code,
        )
        print(agent.json_dumps_compact(payload))
    return exit_code


def main(
    args,
    *,
    skip_fetch: bool = False,
    diff_lines: dict[str, set[int]] | None = None,
    cov_files: dict[str, dict[int, int]] | None = None,
    dep_graph=None,
) -> int:
    fmt = agent.output_format(args)
    settings = _resolve_mutate_settings(args)
    cfg = settings.cfg

    if not skip_fetch:
        fetch.refresh_overrides(cfg)
        fetch.ensure_fetched(cfg)
    cov_path = coverage_mod.output_path(cfg, cfg.root, args.coverage_file)
    if args.no_coverage_run and not cov_path.is_file():
        raise SertError(f"mutate: cannot read {cov_path}: file not found")
    need_cov_run = not cov_path.is_file() and not args.no_coverage_run
    entries, runner = run_mod.resolve_entries(cfg), run_mod.runner_of(cfg, coverage=need_cov_run)
    for entry in entries:
        if not (cfg.root / entry).is_file():
            raise SertError(f"[test].entries: {entry} not found")
    stage_spec = cfg.get("test.stage")
    if stage_spec:
        run_mod.stage_project(cfg, str(stage_spec))

    luau_bin = run_mod.luau_command(cfg.root, runner)
    if os.sep in luau_bin or (os.altsep and os.altsep in luau_bin):
        luau_bin = os.path.abspath(luau_bin)

    resolved_cov = _prepare_baseline_coverage(settings, args, entries, runner, cov_files)
    diff_rev = getattr(args, "diff", None)
    if diff_rev:
        resolved_diff_lines = coverage_mod.git_diff_lines(cfg.root, str(diff_rev)) if diff_lines is None else diff_lines
        resolved_cov = coverage_mod.filter_diff_files(resolved_cov, resolved_diff_lines)

    chosen = coverage_mod.chosen_files(resolved_cov, settings.include, settings.exclude)
    target_files = [
        rel
        for rel in sorted(chosen)
        if not rel.endswith("core/mutant.luau") and (cfg.root / rel).is_file() and any(chosen[rel].values())
    ]
    if not target_files:
        if diff_rev:
            if fmt == "json":
                payload = agent.json_envelope(
                    "mutate",
                    "ok",
                    summary={"score": 100.0, "total": 0, "killed": 0, "survived": 0, "timeout": 0, "cached": 0},
                    data={"mutants": [], "skipped": True, "reason": "no covered lines modified in diff"},
                    exit_code=0,
                )
                print(agent.json_dumps_compact(payload))
            elif fmt == "agent":
                print("OK mutation_score=100.0% killed=0 survived=0 timeout=0 uncovered=0 total=0")
            else:
                print("mutate: no covered lines modified in diff; skipping")
            return 0
        raise SertError(f"mutate: no covered files under {', '.join(settings.include)}")

    wrap_staged = bool(stage_spec)
    all_mutants: list[Mutant] = []
    next_id = 1
    work_root = build_overlay(cfg.root, set(target_files))
    stage_files_dir = (work_root / ".sert" / "stage" / "lexical") if stage_spec else work_root
    prev_sigterm = signal.signal(signal.SIGTERM, interrupt) if threading.current_thread() is threading.main_thread() else None

    try:
        staged_tasks: list[tuple[Path, Path, str, str, list[Mutant]]] = []
        for rel_path in target_files:
            src_path = _guard_inside(work_root, work_root / rel_path)
            if settings.max_mutants is not None and next_id - 1 >= settings.max_mutants:
                if not src_path.exists():
                    _link_file(cfg.root / rel_path, src_path)
                continue
            staged_path = _guard_inside(work_root, stage_files_dir / rel_path)
            source_text = (cfg.root / rel_path).read_text(encoding="utf-8", errors="replace")
            remaining = (settings.max_mutants - (next_id - 1)) if settings.max_mutants is not None else None
            instrumented, file_mutants = instrument_source(
                source_text,
                resolved_cov[rel_path],
                file_path=rel_path,
                start_id=next_id,
                operators=settings.operators,
                max_mutants=remaining,
                spec_filter=resolve_spec_filter(rel_path, settings.specs_map),
                benign_calls=settings.benign_calls,
                cosmetic_props=settings.cosmetic_props,
            )
            if not file_mutants:
                if not src_path.exists():
                    _link_file(cfg.root / rel_path, src_path)
                continue
            staged_tasks.append((src_path, staged_path, source_text, instrumented, file_mutants))
            next_id = file_mutants[-1].id + 1

        for src_path, _staged_path, source_text, _instrumented, _file_mutants in staged_tasks:
            if not src_path.exists():
                _write_unlinked(src_path, source_text)
        retarget_luaurc_aliases(cfg.root, work_root)

        pool = ThreadPoolExecutor(max_workers=max(1, settings.jobs))
        try:
            extra_kw = {"runner": runner} if runner != "luau" else {}
            if len(staged_tasks) == 1:
                src_path, staged_path, source_text, instrumented, file_mutants = staged_tasks[0]
                compiled_lists = [
                    compile_and_stage_file(luau_bin, source_text, instrumented, file_mutants, staged_path, wrap=wrap_staged, **extra_kw)
                ]
            else:
                stage_futs = [
                    pool.submit(compile_and_stage_file, luau_bin, source_text, instrumented, file_mutants, staged_path, wrap=wrap_staged, **extra_kw)
                    for _src_path, staged_path, source_text, instrumented, file_mutants in staged_tasks
                ]
                compiled_lists = [fut.result() for fut in stage_futs]

            for (src_path, _staged_path, source_text, instrumented, file_mutants), valid_mutants in zip(staged_tasks, compiled_lists):
                if wrap_staged and valid_mutants:
                    if len(valid_mutants) == len(file_mutants):
                        merged_source = instrumented
                    else:
                        valid_lines = {m.line for m in valid_mutants}
                        orig_lines, inst_lines = source_text.split("\n"), instrumented.split("\n")
                        merged_source = "\n".join(inst_lines[idx] if (idx + 1) in valid_lines else orig_lines[idx] for idx in range(len(orig_lines)))
                    _write_unlinked(_guard_inside(work_root, src_path), _direct_source(merged_source))
                all_mutants.extend(valid_mutants)

            if not all_mutants:
                raise SertError(f"mutate: no mutable covered statements found under {', '.join(settings.include)}")

            (
                all_specs,
                all_specs_norm,
                dep_graph,
                specs_cov,
                probed,
                trace_line_hits,
                spec_test_counts,
                tokens_digest_by_file,
                spec_sha_memo,
            ) = _resolve_trace_and_coverage_maps(
                cfg,
                work_root,
                luau_bin,
                entries,
                staged_tasks,
                all_mutants,
                pool,
                runner=runner,
                timeout_sec=settings.timeout_sec,
                codegen=settings.codegen,
                program_args=settings.program_args,
                dep_graph=dep_graph,
            )

            cache_path, cache_entries, cache_keys, cached_count, uncached_mutants, mutant_floor = _filter_mutant_cache(
                settings,
                runner,
                entries,
                all_specs,
                all_specs_norm,
                dep_graph,
                specs_cov,
                trace_line_hits,
                tokens_digest_by_file,
                spec_sha_memo,
                all_mutants,
            )

            if uncached_mutants:
                dispatcher = _MutantBatchDispatcher(
                    settings=settings,
                    work_root=work_root,
                    luau_bin=luau_bin,
                    runner=runner,
                    entries=entries,
                    all_specs=all_specs,
                    all_specs_norm=all_specs_norm,
                    dep_graph=dep_graph,
                    specs_cov=specs_cov,
                    probed=probed,
                    trace_line_hits=trace_line_hits,
                    spec_test_counts=spec_test_counts,
                    uncached_mutants=uncached_mutants,
                    mutant_floor=mutant_floor,
                    pool=pool,
                )
                eff_timeout_by_id = dispatcher.run()
                for m in uncached_mutants:
                    if m.id not in cache_keys:
                        continue
                    if m.status in ("KILLED", "SURVIVED"):
                        cache_entries[cache_keys[m.id]] = m.status
                    elif m.status == "TIMEOUT":
                        cache_entries[cache_keys[m.id]] = f"TIMEOUT:{eff_timeout_by_id.get(m.id, settings.timeout_sec):.2f}"
                _save_mutant_cache(cache_path, cache_entries)
        except BaseException:
            _kill_active_procs()
            pool.shutdown(wait=True, cancel_futures=True)
            raise
        else:
            pool.shutdown(wait=True)
    finally:
        if prev_sigterm is not None:
            signal.signal(signal.SIGTERM, prev_sigterm)
        shutil.rmtree(work_root, ignore_errors=True)

    return _report_mutate_results(settings, all_mutants, cached_count, fmt)


cmd_mutate = main
