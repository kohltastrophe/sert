"""`sert mutate [paths...]`: mutation testing over the headless specs."""

from __future__ import annotations

import argparse
from concurrent.futures import ThreadPoolExecutor, as_completed
from dataclasses import dataclass
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

from sert import config as config_mod, coverage as coverage_mod, fetch, run as run_mod
from sert.util import FAILED, SertError, as_list, interrupt, load_json, step_summary

LONG_OPEN = re.compile(r"\[(=*)\[")


def scan_lines(text: str, keep_strings: bool = False) -> tuple[list[str], list[str], list[bool]]:
    """Return (clean_lines, same_len_masked_lines, multiline_span_flags) for Luau source text."""
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
                    interp_depth += (1 if ch == "{" else -1 if ch == "}" else 0)
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


ALL_OPERATORS = ("stmt_del", "ret_val", "cond_inv", "rel_flip", "arith_op", "logic_op", "math_fn")
SWITCH = "(_G :: any).__SERT_MUTANT"

_REL_RE = re.compile(r" (<=|>=|~=|==|<|>) ")
_FLIP_MAP = {"<=": ">=", ">=": "<=", "<": ">", ">": "<", "==": "~=", "~=": "=="}
_ARITH_RE = re.compile(r" (\+|-|\*|/) ")
_ARITH_MAP = {"+": "-", "-": "+", "*": "/", "/": "*"}
_LOGIC_RE = re.compile(r"\b(and|or)\b")
_LOGIC_MAP = {"and": "or", "or": "and"}
_MATH_FN_RE = re.compile(r"\bmath\.(min|max|floor|ceil)\(")
_MATH_FN_MAP = {"min": "max", "max": "min", "floor": "ceil", "ceil": "floor"}
_NON_VALUE_WORD_RE = re.compile(r"\b(?:return|local|if|elseif|then|else|and|or|not|in|do|while|until|repeat|function)$")
_SKIP_PREFIXES = ("export ", "type ", "local type ", "--")
_SKIP_SUFFIXES = (
    ",", "{", "(", "[", "=", "..", "and", "or", "not", "+", "-", "*", "/", "%", "^", "::", "->", ":", ".",
    "do", "repeat", "else", "function",
)
_BLOCK_OPEN_SUFFIXES = ("do", "repeat", "else", "function")
_PREV_CONT_SUFFIXES = tuple(s for s in _SKIP_SUFFIXES if s not in _BLOCK_OPEN_SUFFIXES) + (
    "==", "~=", "<=", ">=", "<", ">", "return", "if", "elseif", "then", "while", "until", "local",
)
_NEXT_CONT_PREFIXES = (
    ",", ")", "}", "]", "..", "and ", "or ", "+", "-", "*", "/", "%", "^", "==", "~=", "<=", ">=", "<", ">",
    "::", "->", ".", ":", "(", "[", "then", "do", "else",
)
_FORBIDDEN_STMT_START = re.compile(
    r"^(?:local|return|break|continue|if|elseif|else|end|for|while|repeat|until|do|function|export|type)\b"
)
_PROP_ASSIGN_MASK_RE = re.compile(
    r"^(\s*)([A-Za-z_][A-Za-z0-9_.\[\]\"' ]*(?:\.[A-Za-z_][A-Za-z0-9_]*|\[[^\]]+\])[A-Za-z0-9_.\[\]\"' ]*)\s*=(?!=)\s*(.+?)\s*$"
)
_COMPOUND_ASSIGN_MASK_RE = re.compile(
    r"^(\s*)([A-Za-z_][A-Za-z0-9_.\[\]\"' ]*(?:\.[A-Za-z_][A-Za-z0-9_]*|\[[^\]]+\])[A-Za-z0-9_.\[\]\"' ]*)\s*(?:\+=|-=|\*=|/=|\.\.=)\s*(.+?)\s*$"
)
_VOID_CALL_MASK_RE = re.compile(
    r"^(\s*)(?:table\.(?:insert|remove|clear|move)|rawset|[A-Za-z_][A-Za-z0-9_.\[\]]*:[A-Za-z_][A-Za-z0-9_]*|[A-Za-z_][A-Za-z0-9_.]*\.[A-Za-z_][A-Za-z0-9_]*)\s*\(.*\)\s*$"
)
_BENIGN_CALL_RE = re.compile(
    r"^\s*(?:task\.(?:wait|spawn|defer|delay|cancel)|(?:Util\.)?Defer\.wait|warn|print|debug\.[A-Za-z_]+|"
    r"(?:Util\.)?(?:log|Logger\.[A-Za-z_]+)|table\.(?:sort|clear)|"
    r"[A-Za-z0-9_.]*Messaging(?:Service)?:(?:Publish|Subscribe)Async|"
    r"[A-Za-z0-9_.\[\]]+:(?:Disconnect|DisconnectAll|Destroy|ClearAllChildren|MakeJoints|BreakJoints|"
    r"MoveTo|PivotTo|SetPrimaryPartCFrame|Play|Stop|Pause|Resume|CaptureFocus|ReleaseFocus|"
    r"SetCore|SetCoreGuiEnabled|ApplyDescription|ApplyDescriptionReset))\s*\("
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
_LOCAL_ASSIGN_MASK_RE = re.compile(r"^(\s*)local\s+([A-Za-z_][A-Za-z0-9_]*)\s*=(?!=)\s*(.+?)\s*$")
_SCOPE_TOKEN_RE = re.compile(r"[(){}\[\]]|\b(?:function|do|if|repeat|until|end)\b")


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


_PREV_PLAIN_SUFFIXES = tuple(s for s in _PREV_CONT_SUFFIXES if s != "then" and not s[-1].isalnum())
_PREV_WORD_SUFFIX_RE = re.compile(
    r"\b(?:" + "|".join(re.escape(s) for s in _PREV_CONT_SUFFIXES if s != "then" and s[-1].isalnum()) + r")$"
)
_PREV_THEN_SUFFIX_RE = re.compile(r"\bthen$")
_PREV_IF_HEADER_RE = re.compile(r"^(?:if|elseif|then)\b")
_NEXT_PLAIN_PREFIXES = tuple(p for p in _NEXT_CONT_PREFIXES if not p[-1].isalnum())
_NEXT_WORD_PREFIX_RE = re.compile(
    r"^(?:" + "|".join(re.escape(p) for p in _NEXT_CONT_PREFIXES if p[-1].isalnum()) + r")\b"
)


def _ends_with_continuation(code: str) -> bool:
    return (
        code.endswith(_PREV_PLAIN_SUFFIXES)
        or bool(_PREV_WORD_SUFFIX_RE.search(code))
        or bool(_PREV_THEN_SUFFIX_RE.search(code) and not _PREV_IF_HEADER_RE.match(code))
    )


def _starts_with_continuation(code: str) -> bool:
    return code.startswith(_NEXT_PLAIN_PREFIXES) or bool(_NEXT_WORD_PREFIX_RE.match(code))


def _find_rel_flip(clean_expr: str, mask_expr: str, skip_simple_eq: bool = False) -> str | None:
    if skip_simple_eq and re.search(r"\b(?:and|or)\b", mask_expr):
        return None
    for match in _REL_RE.finditer(mask_expr):
        op = match.group(1)
        if skip_simple_eq and op in ("==", "~="):
            continue
        return clean_expr[: match.start()] + f" {_FLIP_MAP[op]} " + clean_expr[match.end() :]
    return None


def _find_arith_op(clean_expr: str, mask_expr: str, raw_line: str = "") -> str | None:
    if "--" in raw_line or ".." in clean_expr or ".." in mask_expr:
        return None
    if any(clean_expr.count(tok) != mask_expr.count(tok) for tok in (" + ", " - ", " * ", " / ")):
        return None
    for match in _ARITH_RE.finditer(mask_expr):
        prefix = mask_expr[: match.start()].rstrip()
        if not prefix or not (prefix[-1].isalnum() or prefix[-1] in "_)]}") or _NON_VALUE_WORD_RE.search(prefix):
            continue
        op = match.group(1)
        return clean_expr[: match.start()] + f" {_ARITH_MAP[op]} " + clean_expr[match.end() :]
    return None


def _find_logic_op(clean_expr: str, mask_expr: str) -> str | None:
    match = _LOGIC_RE.search(mask_expr)
    if match is None:
        return None
    op = match.group(1)
    return clean_expr[: match.start()] + _LOGIC_MAP[op] + clean_expr[match.end() :]


def _find_math_fn(clean_expr: str, mask_expr: str) -> str | None:
    match = _MATH_FN_RE.search(mask_expr)
    if match is None:
        return None
    fn = match.group(1)
    return clean_expr[: match.start()] + f"math.{_MATH_FN_MAP[fn]}(" + clean_expr[match.end() :]


def _update_scope_stack(scope_stack: list[str], mask_line: str, prev_code: str) -> None:
    for match in _SCOPE_TOKEN_RE.finditer(mask_line):
        tok = match.group(0)
        if tok in ("(", "{", "["):
            scope_stack.append("delim")
        elif tok in (")", "}", "]"):
            for i in range(len(scope_stack) - 1, -1, -1):
                if scope_stack[i] == "delim":
                    del scope_stack[i:]
                    break
        elif tok == "function":
            prefix = mask_line[: match.start()].rstrip()
            suffix = mask_line[match.end() :].lstrip()
            is_named = bool(re.match(r"^[A-Za-z_]", suffix))
            is_field_or_assign = prefix.endswith("=") or (prefix == "" and prev_code.endswith("="))
            is_module_fn = prefix == "return" and (not scope_stack or "," in suffix.split(")")[0])
            scope_stack.append("func" if (is_named or is_field_or_assign or is_module_fn) else "anon_func")
        elif tok == "do":
            scope_stack.append("block")
        elif tok == "repeat":
            scope_stack.append("repeat")
        elif tok == "until":
            for i in range(len(scope_stack) - 1, -1, -1):
                if scope_stack[i] == "repeat":
                    del scope_stack[i:]
                    break
        elif tok == "if":
            if scope_stack and scope_stack[-1] not in ("func", "anon_func", "block", "repeat"):
                continue
            prefix, suffix = mask_line[: match.start()].strip(), mask_line[match.end() :]
            if re.search(r"\belse\b", suffix) and not re.search(r"\bend\b|\bthen\s*$", suffix):
                continue
            if (prefix == "" and not (prev_code and _ends_with_continuation(prev_code))) or re.search(
                r"(?:;|\b(?:do|repeat))\s*$", prefix
            ) or (re.search(r"\b(?:then|else)\s*$", prefix) and bool(re.search(r"\bend\b|\bthen\s*$", suffix))):
                scope_stack.append("block")
        elif tok == "end":
            for i in range(len(scope_stack) - 1, -1, -1):
                if scope_stack[i] in ("func", "anon_func", "block"):
                    del scope_stack[i:]
                    break


def _line_neighbors(mask_lines: list[str]) -> tuple[list[str], list[str]]:
    stripped_codes = [m.strip() for m in mask_lines]
    n = len(stripped_codes)
    prev_non_empty: list[str] = [""] * n
    last_code = ""
    for idx, sc in enumerate(stripped_codes):
        prev_non_empty[idx] = last_code
        if sc:
            last_code = sc
    next_non_empty: list[str] = [""] * n
    upcoming_code = ""
    for idx in range(n - 1, -1, -1):
        next_non_empty[idx] = upcoming_code
        if stripped_codes[idx]:
            upcoming_code = stripped_codes[idx]
    return prev_non_empty, next_non_empty


def _is_mutable_line(
    code: str,
    clean_line: str,
    prev_code: str,
    next_code: str,
    outside_delims: bool,
    is_multiline: bool,
) -> bool:
    return not (
        is_multiline
        or not outside_delims
        or not code
        or not clean_line.strip()
        or any(code.startswith(p) for p in _SKIP_PREFIXES)
        or any(code.endswith(s) for s in _SKIP_SUFFIXES)
        or "::" in code
        or ";" in code
        or "`" in clean_line
        or bool(re.search(r"\bfunction\b", code))
        or (bool(prev_code) and _ends_with_continuation(prev_code))
        or (bool(next_code) and _starts_with_continuation(next_code))
    )


def _mutate_statement(
    clean_line: str,
    mask_line: str,
    code: str,
    indent: str,
    stmt_clean: str,
    prev_code: str,
    next_code: str,
    ops: set[str],
    room,
    add,
    extra_benign_res: list[re.Pattern[str]],
    extra_cosmetic_re: re.Pattern[str] | None,
    raw_line: str = "",
) -> str | None:
    if_mask_m = re.match(r"^(\s*)(if|elseif)\s+(.+?)\s+then\s*$", mask_line)
    if_clean_m = re.match(r"^(\s*)(if|elseif)\s+(.+?)\s+then\s*$", clean_line)
    if if_mask_m and if_clean_m:
        kw, cond_clean, cond_mask = if_clean_m.group(2), if_clean_m.group(3), if_mask_m.group(3)
        if (
            len(re.findall(r"\bthen\b", code)) == 1
            and len(re.findall(rf"\b{kw}\b", code)) == 1
            and not re.search(r"\b(?:else|end|do|repeat)\b", code)
        ):
            line_mutants: list[tuple[str, str, str]] = []
            has_cond_inv = False
            if "cond_inv" in ops and room(len(line_mutants)):
                has_cond_inv = True
                line_mutants.append(("cond_inv", f"not ({cond_clean})", f"{kw} not ({cond_clean}) then"))
            if "rel_flip" in ops and room(len(line_mutants)):
                flipped_cond = _find_rel_flip(cond_clean, cond_mask, skip_simple_eq=has_cond_inv)
                if flipped_cond is not None:
                    line_mutants.append(("rel_flip", f"({flipped_cond})", f"{kw} {flipped_cond} then"))
            if "logic_op" in ops and room(len(line_mutants)):
                logic_cond = _find_logic_op(cond_clean, cond_mask)
                if logic_cond is not None:
                    line_mutants.append(("logic_op", f"({logic_cond})", f"{kw} {logic_cond} then"))
            if "arith_op" in ops and room(len(line_mutants)):
                arith_cond = _find_arith_op(cond_clean, cond_mask, raw_line)
                if arith_cond is not None:
                    line_mutants.append(("arith_op", f"({arith_cond})", f"{kw} {arith_cond} then"))
            if "math_fn" in ops and room(len(line_mutants)):
                math_cond = _find_math_fn(cond_clean, cond_mask)
                if math_cond is not None:
                    line_mutants.append(("math_fn", f"({math_cond})", f"{kw} {math_cond} then"))
            if line_mutants:
                branches = [
                    f"{'if' if i == 0 else 'elseif'} {SWITCH} == {add(op_name, desc)} then {expr}"
                    for i, (op_name, expr, desc) in enumerate(line_mutants)
                ]
                return f"{indent}{kw} ({' '.join(branches)} else ({cond_clean})) then"
        return None

    if code.endswith("then"):
        return None

    ret_bool_m = re.match(r"^(\s*)return\s+(true|false)(?:\s*,\s*(.+?))?\s*$", clean_line)
    ret_bool_mask_m = re.match(r"^(\s*)return\s+(true|false)(?:\s*,\s*(.+?))?\s*$", mask_line)
    if ret_bool_m and ret_bool_mask_m:
        if "ret_val" in ops:
            val, rest_clean, rest_mask = ret_bool_m.group(2), ret_bool_m.group(3), ret_bool_mask_m.group(3)
            if rest_mask is None or not re.search(r"\b(?:then|do|repeat|end|function)\b", rest_mask):
                inv = "false" if val == "true" else "true"
                mid = add("ret_val", f"return {inv}")
                return (
                    f"{indent}return if {SWITCH} == {mid} then {inv} else {val}"
                    if rest_clean is None
                    else f"{indent}if {SWITCH} == {mid} then return {inv} end return {val}, {rest_clean}"
                )
        return None

    ret_mask_m = re.match(r"^(\s*)return\s+(.+?)\s*$", mask_line)
    ret_clean_m = re.match(r"^(\s*)return\s+(.+?)\s*$", clean_line)
    if ret_mask_m and ret_clean_m:
        rhs_clean, rhs_mask = ret_clean_m.group(2), ret_mask_m.group(2)
        if (
            rhs_mask != "nil"
            and not re.match(r"^nil\s*,", rhs_mask)
            and not rhs_mask.startswith("if ")
            and not re.search(r"\b(?:then|do|repeat|end)\b", rhs_mask)
        ):
            flipped = _find_rel_flip(rhs_clean, rhs_mask, skip_simple_eq=False) if "rel_flip" in ops else None
            math_flipped = _find_math_fn(rhs_clean, rhs_mask) if "math_fn" in ops else None
            logic_flipped = _find_logic_op(rhs_clean, rhs_mask) if "logic_op" in ops else None
            arith_flipped = _find_arith_op(rhs_clean, rhs_mask, raw_line) if "arith_op" in ops else None
            is_early_guard = prev_code.endswith("then") and next_code in ("end", "else")
            is_benign_tail = (
                rhs_mask.startswith(('"', "'"))
                or bool(_BENIGN_CALL_RE.match(rhs_clean))
                or bool(re.search(r"(?:^select\s*\(\s*2\s*,|:(?:Connect|Once|Wait|Fire|Destroy)\s*\(|\bcleanup\s*\()", rhs_clean))
            )
            ret_mut = None
            if room():
                if flipped is not None:
                    ret_mut = ("rel_flip", f"return {flipped}")
                elif math_flipped is not None:
                    ret_mut = ("math_fn", f"return {math_flipped}")
                elif logic_flipped is not None:
                    ret_mut = ("logic_op", f"return {logic_flipped}")
                elif "ret_val" in ops and not is_early_guard and not is_benign_tail:
                    ret_mut = ("ret_val", "return nil")
                elif arith_flipped is not None:
                    ret_mut = ("arith_op", f"return {arith_flipped}")
            if ret_mut is not None:
                mid = add(ret_mut[0], ret_mut[1])
                return f"{indent}if {SWITCH} == {mid} then {ret_mut[1]} end return {rhs_clean}"
        return None

    loc_mask_m = _LOCAL_ASSIGN_MASK_RE.match(mask_line)
    if loc_mask_m:
        lhs = clean_line[loc_mask_m.start(2) : loc_mask_m.end(2)]
        rhs_clean = clean_line[loc_mask_m.start(3) : loc_mask_m.end(3)]
        rhs_mask = loc_mask_m.group(3)
        if not re.search(r"\b(?:if|then|else|end|do|repeat)\b", rhs_mask):
            expr_muts: list[tuple[str, str]] = []
            for op_name, fn in (
                ("rel_flip", lambda: _find_rel_flip(rhs_clean, rhs_mask, skip_simple_eq=False)),
                ("arith_op", lambda: _find_arith_op(rhs_clean, rhs_mask, raw_line)),
                ("logic_op", lambda: _find_logic_op(rhs_clean, rhs_mask)),
                ("math_fn", lambda: _find_math_fn(rhs_clean, rhs_mask)),
            ):
                if op_name in ops and room(len(expr_muts)):
                    mut_rhs = fn()
                    if mut_rhs is not None:
                        expr_muts.append((op_name, mut_rhs))
            if expr_muts:
                branches = [
                    f"{'if' if i == 0 else 'elseif'} {SWITCH} == {add(op_name, f'local {lhs} = {mut_rhs}')} then ({mut_rhs})"
                    for i, (op_name, mut_rhs) in enumerate(expr_muts)
                ]
                return f"{indent}local {lhs} = {' '.join(branches)} else ({rhs_clean})"
        return None

    if _FORBIDDEN_STMT_START.match(code):
        return None

    prop_mask_m = _PROP_ASSIGN_MASK_RE.match(mask_line)
    if prop_mask_m:
        lhs_clean = clean_line[prop_mask_m.start(2) : prop_mask_m.end(2)].strip()
        rhs_clean = clean_line[prop_mask_m.start(3) : prop_mask_m.end(3)].strip()
        rhs_mask = prop_mask_m.group(3).strip()
        if not re.search(r"\b(?:if|then|else|end|do|repeat)\b", rhs_mask):
            flipped_rhs = _find_rel_flip(rhs_clean, rhs_mask, skip_simple_eq=False) if "rel_flip" in ops else None
            expr_op = "rel_flip"
            if flipped_rhs is None and "arith_op" in ops:
                flipped_rhs, expr_op = _find_arith_op(rhs_clean, rhs_mask, raw_line), "arith_op"
            if flipped_rhs is None and "logic_op" in ops:
                flipped_rhs, expr_op = _find_logic_op(rhs_clean, rhs_mask), "logic_op"
            if flipped_rhs is None and "math_fn" in ops:
                flipped_rhs, expr_op = _find_math_fn(rhs_clean, rhs_mask), "math_fn"
            do_delete = (
                "stmt_del" in ops
                and not _COSMETIC_PROP_RE.search(lhs_clean)
                and not (extra_cosmetic_re and extra_cosmetic_re.search(lhs_clean))
                and room()
            )
            do_flip = flipped_rhs is not None and room(1 if do_delete else 0)
            flipped_stmt = f"{lhs_clean} = {flipped_rhs}" if flipped_rhs is not None else ""
            if do_delete and do_flip:
                mid_del, mid_rel = add("stmt_del", "-- deleted statement"), add(expr_op, flipped_stmt)
                return f"{indent}if {SWITCH} == {mid_rel} then {flipped_stmt} elseif {SWITCH} ~= {mid_del} then {stmt_clean} end"
            if do_delete:
                return f"{indent}if {SWITCH} ~= {add('stmt_del', '-- deleted statement')} then {stmt_clean} end"
            if do_flip:
                return f"{indent}if {SWITCH} == {add(expr_op, flipped_stmt)} then {flipped_stmt} else {stmt_clean} end"
        return None

    if "stmt_del" in ops:
        is_compound = bool(_COMPOUND_ASSIGN_MASK_RE.match(mask_line))
        is_void_call = (
            bool(_VOID_CALL_MASK_RE.match(mask_line))
            and not bool(_BENIGN_CALL_RE.match(mask_line))
            and not any(r.search(clean_line) for r in extra_benign_res)
        )
        if (is_compound or is_void_call) and not re.search(r"\b(?:if|then|else|end|do|repeat)\b", code):
            return f"{indent}if {SWITCH} ~= {add('stmt_del', '-- deleted statement')} then {stmt_clean} end"
    return None


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
    cov_map = {ln: True for ln in covered_lines} if isinstance(covered_lines, set) else dict(covered_lines)
    ops = set(operators)
    extra_benign_res = [re.compile(p) for p in benign_calls if p]
    extra_cosmetic_re = (
        re.compile(r"\.(?:" + "|".join(re.escape(p) for p in cosmetic_props if p) + r")\b") if cosmetic_props else None
    )
    raw_lines = source_text.split("\n")
    clean_lines, mask_lines, multiline_flags = scan_lines(source_text, keep_strings=True)
    has_functions = bool(re.search(r"\bfunction\b", "\n".join(mask_lines)))
    prev_non_empty, next_non_empty = _line_neighbors(mask_lines)

    out_lines = list(raw_lines)
    mutants: list[Mutant] = []
    next_id = start_id
    scope_stack: list[str] = []

    def room(pending: int = 0) -> bool:
        return max_mutants is None or len(mutants) + pending < max_mutants

    def add(op: str, mutated: str) -> int:
        nonlocal next_id
        mid = next_id
        next_id += 1
        mutants.append(Mutant(mid, file_path, line_no, op, stmt_clean, mutated, spec_filter))
        return mid

    for idx in range(len(raw_lines)):
        line_no = idx + 1
        clean_line = clean_lines[idx].rstrip()
        mask_line = mask_lines[idx][: len(clean_line)]
        code = mask_line.strip()
        innermost_func = next((s for s in reversed(scope_stack) if s in ("func", "anon_func")), None)
        in_stmt_scope = (not scope_stack or scope_stack[-1] in ("func", "block", "repeat")) and (
            not has_functions or innermost_func == "func"
        )
        outside_delims = (
            in_stmt_scope
            and code.count("(") == code.count(")")
            and code.count("{") == code.count("}")
            and code.count("[") == code.count("]")
        )
        _update_scope_stack(scope_stack, mask_line, prev_non_empty[idx])

        if (
            (max_mutants is not None and len(mutants) >= max_mutants)
            or not cov_map.get(line_no, False)
            or not _is_mutable_line(
                code, clean_line, prev_non_empty[idx], next_non_empty[idx], outside_delims, multiline_flags[idx]
            )
        ):
            continue

        indent_match = re.match(r"^(\s*)", clean_line)
        indent = indent_match.group(1) if indent_match else ""
        if indent == "" and has_functions:
            continue
        stmt_clean = clean_line.strip()
        mutated_line = _mutate_statement(
            clean_line, mask_line, code, indent, stmt_clean, prev_non_empty[idx], next_non_empty[idx],
            ops, room, add, extra_benign_res, extra_cosmetic_re, raw_lines[idx],
        )
        if mutated_line is not None:
            out_lines[idx] = mutated_line

    return "\n".join(out_lines), mutants


_ENV_G_BRIDGE = (
    'if type(_G) == "table" and not table.isfrozen(_G) and getmetatable(_G) == nil and getfenv ~= nil then '
    "setmetatable(_G, { __index = (getfenv(0) :: any)._G }) end "
)
DETECTED = ("KILLED", "TIMEOUT")
BATCH_TIMEOUT_FACTOR = 16.0


def _guard_inside(work_root: Path, path: Path) -> Path:
    try:
        base, target = os.path.normcase(str(Path(work_root).resolve())), os.path.normcase(str(Path(path).resolve()))
        inside = os.path.commonpath([base, target]) == base and target != base
    except (OSError, ValueError):
        inside = False
    if not inside:
        raise SertError(f"mutate: refusing to write {path}: it resolves outside the mutation copy {work_root}")
    return path


def wrap_staged_source(instrumented_source: str) -> str:
    return run_mod.wrap_luau_source(instrumented_source, _ENV_G_BRIDGE)


def _run_process(
    cmd: list[str], *, cwd: Path | None = None, timeout: float, capture_output: bool = False
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


def _check_staged_compiles(luau_bin: str, staged_path: Path, runner: str = "luau") -> bool:
    is_lute = runner == "lute" or Path(str(luau_bin)).stem.lower() == "lute"
    cmd = [str(luau_bin), "run", str(staged_path)] if is_lute else [str(luau_bin), str(staged_path)]
    try:
        return _run_process(cmd, timeout=5).returncode == 0
    except subprocess.TimeoutExpired:
        return False


def _direct_source(src: str) -> str:
    return src.replace(SWITCH, "((if getfenv ~= nil then (getfenv(0) :: any)._G else _G) :: any).__SERT_MUTANT")


def compile_and_stage_file(
    luau_bin: str, original_source: str, instrumented_source: str, mutants: list[Mutant], staged_path: Path, *, wrap: bool = True, runner: str = "luau"
) -> list[Mutant]:
    staged_path.parent.mkdir(parents=True, exist_ok=True)
    staged_path.write_text(wrap_staged_source(instrumented_source), encoding="utf-8")
    if _check_staged_compiles(luau_bin, staged_path, runner=runner):
        if not wrap:
            staged_path.write_text(_direct_source(instrumented_source), encoding="utf-8")
        return mutants

    orig_lines, inst_lines = original_source.split("\n"), instrumented_source.split("\n")
    working_lines = list(orig_lines)
    valid_lines: set[int] = set()
    for line_no in sorted({m.line for m in mutants}):
        idx = line_no - 1
        candidate = working_lines[idx]
        working_lines[idx] = inst_lines[idx]
        staged_path.write_text(wrap_staged_source("\n".join(working_lines)), encoding="utf-8")
        if _check_staged_compiles(luau_bin, staged_path, runner=runner):
            valid_lines.add(line_no)
        else:
            working_lines[idx] = candidate

    final_source = "\n".join(working_lines)
    staged_path.write_text(wrap_staged_source(final_source) if wrap else _direct_source(final_source), encoding="utf-8")
    return [m for m in mutants if m.line in valid_lines]


def resolve_spec_filter(rel_path: str, specs_map: dict[str, str]) -> str | None:
    best_prefix, best_filter, norm_path = "", None, coverage_mod.norm(rel_path)
    for raw_prefix, filter_str in specs_map.items():
        prefix = coverage_mod.norm(str(raw_prefix)).rstrip("/")
        if (norm_path == prefix or norm_path.startswith(prefix + "/")) and len(prefix) > len(best_prefix):
            best_prefix, best_filter = prefix, str(filter_str)
    return best_filter


def _selector_command(
    runner: str, luau_bin: str, entry: str, selector: str, spec_filter: str | None, codegen: bool, program_args: list[str] | tuple[str, ...]
) -> list[str]:
    arg = f"{selector}:{spec_filter}" if spec_filter else selector
    return run_mod.entry_command(runner, str(luau_bin), str(entry), [*program_args, arg], coverage=False, codegen=codegen)


def _mutant_command(
    runner: str, luau_bin: str, entry: str, mutant_id: int, spec_filter: str | None, codegen: bool = False, program_args: list[str] | tuple[str, ...] = ()
) -> list[str]:
    return _selector_command(runner, luau_bin, entry, f"--mutant={mutant_id}", spec_filter, codegen, program_args)


def _mutant_batch_command(
    runner: str, luau_bin: str, entry: str, mutant_ids: list[int], spec_filter: str | None, codegen: bool = False, program_args: list[str] | tuple[str, ...] = ()
) -> list[str]:
    return _selector_command(runner, luau_bin, entry, f"--mutants={','.join(str(mid) for mid in mutant_ids)}", spec_filter, codegen, program_args)


def _evaluate_one_mutant(
    mutant: Mutant, root: Path, runner: str, luau_bin: str, entries: list[str], timeout_sec: float, codegen: bool = False, program_args: list[str] | tuple[str, ...] = ()
) -> str:
    for entry in entries:
        cmd = _mutant_command(runner, luau_bin, entry, mutant.id, mutant.spec_filter, codegen=codegen, program_args=program_args)
        try:
            res = _run_process(cmd, cwd=root, timeout=timeout_sec)
        except subprocess.TimeoutExpired:
            return "TIMEOUT"
        if res.returncode != 0:
            return "KILLED"
    return "SURVIVED"


_BATCH_LINE_RE = re.compile(r"^\[sert-mutant\]\s*(\d+)=(KILLED|SURVIVED)\s*$")


def _evaluate_mutant_batch(
    batch: list[Mutant], root: Path, runner: str, luau_bin: str, entries: list[str], timeout_sec: float, codegen: bool = False, program_args: list[str] | tuple[str, ...] = ()
) -> None:
    if len(entries) != 1 or len(batch) <= 1:
        for m in batch:
            m.status = _evaluate_one_mutant(m, root, runner, luau_bin, entries, timeout_sec, codegen, program_args)
        return
    cmd = _mutant_batch_command(runner, luau_bin, entries[0], [m.id for m in batch], batch[0].spec_filter, codegen=codegen, program_args=program_args)
    try:
        res = _run_process(cmd, cwd=root, timeout=timeout_sec * min(len(batch), BATCH_TIMEOUT_FACTOR), capture_output=True)
        out_str = res.stdout or ""
    except subprocess.TimeoutExpired as exc:
        out_str = exc.stdout.decode("utf-8", errors="replace") if isinstance(exc.stdout, bytes) else (exc.stdout or "")
    status_by_id = {int(m.group(1)): m.group(2) for line in out_str.splitlines() if (m := _BATCH_LINE_RE.match(line.strip()))}
    remaining: list[Mutant] = []
    for m in batch:
        if m.id in status_by_id:
            m.status = status_by_id[m.id]
        else:
            remaining.append(m)
    if remaining:
        remaining[0].status = _evaluate_one_mutant(remaining[0], root, runner, luau_bin, entries, timeout_sec, codegen, program_args)
        if len(remaining) > 1:
            _evaluate_mutant_batch(remaining[1:], root, runner, luau_bin, entries, timeout_sec, codegen, program_args)


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

    print(f"{'file':{width}} {'score%':>6}  detected/total", file=out)
    for name in sorted(by_file):
        file_muts = by_file[name]
        detected, tot = sum(1 for m in file_muts if m.status in DETECTED), len(file_muts)
        total_detected += detected
        print(f"{name:{width}} {100 * detected / tot:5.1f}%  {detected}/{tot}{timeouts(file_muts)}", file=out)
    score = 100.0 * total_detected / total
    print("-" * (width + 24), file=out)
    print(f"{'TOTAL':{width}} {score:5.1f}%  {total_detected}/{total}{timeouts(mutants)}", file=out)

    file_cache: dict[str, list[str]] = {}
    for status, heading in (("TIMEOUT", "Timed-out mutants ({n}, counted as detected):"), ("SURVIVED", "Surviving mutants ({n}):")):
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
BATCH_SIZE = 32
BASELINE_TIMEOUT_FACTOR = 4.0
BASELINE_TIMEOUT_FLOOR = 30.0
WORK_DIR = Path(".sert") / "mutate"
_SKIP_ANYWHERE = frozenset({".git", ".hg", ".svn", "node_modules", "__pycache__"})
_SKIP_IN_SERT = frozenset({"mutate", "bin"})
_DRIVE_RE = coverage_mod._DRIVE_RE
BASELINE_FACTOR = 2.0


def add_parser(subparsers) -> None:
    parser = subparsers.add_parser("mutate")
    parser.add_argument("paths", nargs="*", help="files or directory prefixes to mutate (default: [mutate].include)")
    parser.add_argument("-j", "--jobs", type=int, help="parallel worker count (default: cpu count)")
    parser.add_argument("--timeout", type=float, help=f"per-mutant timeout in seconds (default: [mutate].timeout or {DEFAULT_TIMEOUT:g})")
    parser.add_argument("--min", type=float, help="fail below this mutation score percentage (default: [mutate].min)")
    parser.add_argument("--max-mutants", type=int, metavar="N", help="cap on total mutants evaluated (default: [mutate].max_mutants)")
    parser.add_argument(
        "--operators",
        help="comma-separated subset of stmt_del,ret_val,cond_inv,rel_flip (default: all)",
    )
    parser.add_argument("--diff", nargs="?", const="HEAD", default=None, metavar="REV", help="only mutate lines modified in git diff since REV (default: HEAD)")
    parser.add_argument("--coverage-file", metavar="FILE", help="LCOV file (default: coverage.out)")
    parser.add_argument("--no-coverage-run", action="store_true", help="do not run `sert run --coverage` automatically if coverage.out is missing")
    parser.add_argument("-a", dest="program_args", nargs=argparse.REMAINDER, default=[], help="arguments for the suite, as `sert run -a`")
    parser.set_defaults(func=main)


def copy_tree(root: Path) -> Path:
    root = Path(os.path.abspath(root))
    work = root / WORK_DIR / "tree"
    shutil.rmtree(work, ignore_errors=True)
    sert_dir = root / ".sert"

    def ignore(directory: str, names: list[str]) -> set[str]:
        here = Path(directory)
        skipped = {name for name in names if name in _SKIP_ANYWHERE}
        if here == root:
            skipped |= {name for name in names if name.startswith(".") and name != ".sert" and (here / name).is_dir()}
        elif here == sert_dir:
            skipped |= {name for name in names if name in _SKIP_IN_SERT}
        return skipped

    try:
        shutil.copytree(root, work, ignore=ignore, symlinks=True)
    except (OSError, shutil.Error) as err:
        shutil.rmtree(work, ignore_errors=True)
        raise SertError(f"mutate: cannot copy the project into {work}: {err}")
    retarget_luaurc_aliases(root, work)
    return work


def _retarget(value: str, root: Path, work: Path, luaurc_dir: Path | None = None) -> str:
    if not os.path.isabs(value):
        base_dir = root if luaurc_dir is None else luaurc_dir
        try:
            target = (base_dir / value).resolve()
        except OSError:
            return value
        return value if coverage_rel_path(str(target), root) is not None else str(target)
    try:
        if os.path.normcase(str(Path(value).resolve())) == os.path.normcase(str(Path(root).resolve())):
            return str(work)
    except OSError:
        return value
    rel = coverage_rel_path(coverage_mod.norm(value), root)
    return value if rel is None or not (work / rel).exists() else str(work / rel)


def retarget_luaurc_aliases(root: Path, work: Path) -> None:
    for directory, dirs, files in os.walk(work):
        dirs[:] = [name for name in dirs if name not in _SKIP_ANYWHERE]
        if ".luaurc" not in files:
            continue
        path = Path(directory) / ".luaurc"
        if path.is_symlink():
            continue
        data = load_json(path)
        aliases = data.get("aliases") if isinstance(data, dict) else None
        if not isinstance(aliases, dict):
            continue
        orig_dir = root / Path(directory).relative_to(work)
        moved = {key: _retarget(value, root, work, orig_dir) if isinstance(value, str) else value for key, value in aliases.items()}
        if moved != aliases:
            data["aliases"] = moved
            path.write_text(json.dumps(data, indent=2) + "\n", encoding="utf-8")


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
    runner: str, luau_bin: str, entry: str, spec_filter: str | None, work_root: Path, timeout_sec: float, codegen: bool = False, program_args: list[str] | tuple[str, ...] = ()
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
    if elapsed > timeout_sec:
        raise SertError(f"mutate: the unmutated baseline run of {entry} (filter={spec_filter!r}) took {elapsed:.2f}s, longer than the {timeout_sec:g}s per-mutant timeout" + hint)
    return elapsed


def main(args) -> int:
    cfg = config_mod.from_args(args)
    table, cov_table = cfg.table("mutate"), cfg.table("coverage")
    codegen = bool(cfg.get("test.codegen", False))
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

    include_raw = args.paths or as_list(table.get("include")) or as_list(cov_table.get("include")) or ["src"]
    include = [coverage_mod.norm(str(p)).rstrip("/") for p in include_raw]
    exclude = [coverage_mod.norm(str(p)).rstrip("/") for p in as_list(table.get("exclude"))]
    timeout_sec = float(args.timeout if args.timeout is not None else table.get("timeout", DEFAULT_TIMEOUT))
    minimum = args.min if args.min is not None else table.get("min")
    max_mutants_raw = args.max_mutants if args.max_mutants is not None else table.get("max_mutants")
    max_mutants = int(max_mutants_raw) if max_mutants_raw is not None else None
    jobs = int(args.jobs if args.jobs is not None else (table.get("jobs") or os.cpu_count() or 4))
    specs_map = table.get("specs") if isinstance(table.get("specs"), dict) else {}
    program_args = [str(arg) for arg in (getattr(args, "program_args", None) or [])]

    fetch.refresh_overrides(cfg)
    fetch.ensure_fetched(cfg)
    cov_path = cfg.root / str(args.coverage_file or "coverage.out")
    need_cov_run = not cov_path.is_file() and not args.no_coverage_run
    entries, runner = run_mod.resolve_entries(cfg), run_mod.runner_of(cfg, coverage=need_cov_run)
    stage_spec = cfg.get("test.stage")
    if stage_spec:
        run_mod.stage_project(cfg.root, str(stage_spec))

    luau_bin = run_mod.luau_command(cfg.root, runner)
    if os.sep in luau_bin or (os.altsep and os.altsep in luau_bin):
        luau_bin = os.path.abspath(luau_bin)

    if not cov_path.is_file():
        if args.no_coverage_run:
            raise SertError(f"mutate: cannot read {cov_path}: file not found")
        cov_path.parent.mkdir(parents=True, exist_ok=True)
        coverage_out = cfg.root / "coverage.out"
        prior_coverage = coverage_out.read_bytes() if (cov_path != coverage_out and coverage_out.is_file()) else None
        try:
            baseline = run_mod.run_entries(cfg, entries, runner=runner, coverage=True, echo=False, markers=False, program_args=program_args)
            if baseline.status != 0:
                detail = "\n".join(run.output.strip() for run in baseline.entries if run.code != 0 and run.output.strip())
                raise SertError(f"mutate: the baseline `sert run --coverage` failed (status {baseline.status}); the unmutated suite must pass before mutants can be scored" + (f"\n{detail[-4000:]}" if detail else ""))
            if cov_path != coverage_out and coverage_out.is_file():
                cov_path.write_text(coverage_out.read_text(encoding="utf-8", errors="replace"), encoding="utf-8")
        finally:
            if cov_path != coverage_out:
                if prior_coverage is not None:
                    coverage_out.write_bytes(prior_coverage)
                elif coverage_out.is_file():
                    coverage_out.unlink()
        if not cov_path.is_file():
            raise SertError("mutate: baseline `sert run --coverage` did not produce coverage.out")

    try:
        cov_files = root_relative_coverage(coverage_mod.parse(cov_path), cfg.root)
    except OSError as err:
        raise SertError(f"mutate: cannot read {cov_path}: {err}")

    diff_rev = getattr(args, "diff", None)
    if diff_rev:
        diff_lines = coverage_mod.git_diff_lines(cfg.root, str(diff_rev))
        cov_files = coverage_mod.filter_diff_files(cov_files, diff_lines)

    chosen = coverage_mod.chosen_files(cov_files, include, exclude)
    target_files = [rel for rel in sorted(chosen) if (cfg.root / rel).is_file() and any(chosen[rel].values())]
    if not target_files:
        if diff_rev:
            print("mutate: no covered lines modified in diff; skipping")
            return 0
        raise SertError(f"mutate: no covered files under {', '.join(include)}")

    wrap_staged = bool(stage_spec)
    all_mutants: list[Mutant] = []
    next_id = 1
    work_root = copy_tree(cfg.root)
    stage_files_dir = (work_root / ".sert" / "stage" / "files") if stage_spec else work_root
    prev_sigterm = signal.signal(signal.SIGTERM, interrupt) if threading.current_thread() is threading.main_thread() else None

    try:
        for rel_path in target_files:
            if max_mutants is not None and len(all_mutants) >= max_mutants:
                break
            src_path = _guard_inside(work_root, work_root / rel_path)
            staged_path = _guard_inside(work_root, stage_files_dir / rel_path)
            source_text = (cfg.root / rel_path).read_text(encoding="utf-8", errors="replace")
            remaining = (max_mutants - len(all_mutants)) if max_mutants is not None else None
            instrumented, file_mutants = instrument_source(
                source_text, cov_files[rel_path], file_path=rel_path, start_id=next_id, operators=operators,
                max_mutants=remaining, spec_filter=resolve_spec_filter(rel_path, specs_map),
                benign_calls=benign_calls, cosmetic_props=cosmetic_props,
            )
            if not file_mutants:
                continue
            extra_kw = {"runner": runner} if runner != "luau" else {}
            valid_mutants = compile_and_stage_file(luau_bin, source_text, instrumented, file_mutants, staged_path, wrap=wrap_staged, **extra_kw)
            if wrap_staged and valid_mutants:
                if len(valid_mutants) == len(file_mutants):
                    merged_source = instrumented
                else:
                    valid_lines = {m.line for m in valid_mutants}
                    orig_lines, inst_lines = source_text.split("\n"), instrumented.split("\n")
                    merged_source = "\n".join(inst_lines[idx] if (idx + 1) in valid_lines else orig_lines[idx] for idx in range(len(orig_lines)))
                _guard_inside(work_root, src_path).write_text(_direct_source(merged_source), encoding="utf-8")
            all_mutants.extend(valid_mutants)
            next_id = file_mutants[-1].id + 1

        if not all_mutants:
            raise SertError(f"mutate: no mutable covered statements found under {', '.join(include)}")

        by_filter: dict[str, list[Mutant]] = {}
        for m in all_mutants:
            by_filter.setdefault(m.spec_filter or "", []).append(m)

        pool = ThreadPoolExecutor(max_workers=max(1, jobs))
        try:
            baseline_futures = {
                (filt, entry): pool.submit(baseline_run, runner, luau_bin, entry, filt or None, work_root, timeout_sec, codegen, program_args)
                for filt in sorted(by_filter)
                for entry in entries
            }
            baseline_by_filter: dict[str, float] = {}
            for (filt, _entry), fut in baseline_futures.items():
                elapsed = fut.result()
                baseline_by_filter[filt] = max(baseline_by_filter.get(filt, 0.0), elapsed)

            timeout_by_filter = {
                filt: max(timeout_sec, BASELINE_FACTOR * elapsed)
                for filt, elapsed in baseline_by_filter.items()
            }
            batches = [
                (filt_mutants[i : i + BATCH_SIZE], timeout_by_filter[filt])
                for filt, filt_mutants in sorted(by_filter.items(), key=lambda kv: -baseline_by_filter.get(kv[0], 0.0))
                for i in range(0, len(filt_mutants), BATCH_SIZE)
            ]
            futures = [
                pool.submit(_evaluate_mutant_batch, batch, work_root, runner, luau_bin, entries, filt_timeout, codegen, program_args)
                for batch, filt_timeout in batches
            ]
            for future in as_completed(futures):
                future.result()
        except BaseException:
            pool.shutdown(wait=True, cancel_futures=True)
            raise
        else:
            pool.shutdown(wait=True)
    finally:
        if prev_sigterm is not None:
            signal.signal(signal.SIGTERM, prev_sigterm)
        shutil.rmtree(work_root, ignore_errors=True)

    score = summarize(all_mutants, out=sys.stderr, root=cfg.root)
    print(f"{score:.1f}")
    if minimum is not None and score < float(minimum):
        print(f"mutate: {score:.1f}% is below the {float(minimum):g}% floor", file=sys.stderr)
        return FAILED
    return 0


cmd_mutate = main
