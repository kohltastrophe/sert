"""`sert mutate [paths...]`: zero-copy token-stream mutation testing over headless specs."""

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

from sert import config as config_mod, coverage as coverage_mod, fetch, luau_lex, run as run_mod
from sert.util import FAILED, SertError, as_list, interrupt, load_json, strip_jsonc, step_summary

LONG_OPEN = re.compile(r"\[(=*)\[")

ALL_OPERATORS = ("stmt_del", "ret_val", "cond_inv", "rel_flip", "arith_op", "logic_op", "math_fn")
SWITCH = "_SERT_M.id"
STAGED_SWITCH = "_SERT_M.id"
MUTANT_PREAMBLE = (
    'local _SERT_OK, _SERT_RAW = pcall(require, "@__SERT_MUTANT"); '
    'local _SERT_M: any = if _SERT_OK and type(_SERT_RAW) == "table" then _SERT_RAW else { id = 0 }; '
)
DETECTED = ("KILLED",)
BATCH_TIMEOUT_FACTOR = 16.0

_FLIP_MAP = {"<=": ">=", ">=": "<=", "<": ">", ">": "<", "==": "~=", "~=": "=="}
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


def _skip_balanced(tokens: list[luau_lex.Token], idx: int, open_op: str, close_op: str) -> int:
    n = len(tokens)
    depth = 0
    while idx < n:
        tok = tokens[idx]
        if tok.kind == "OP":
            if tok.value == open_op:
                depth += 1
            elif tok.value == close_op:
                depth -= 1
                if depth <= 0:
                    return idx + 1
        idx += 1
    return n


def _skip_type_angles(tokens: list[luau_lex.Token], idx: int) -> int:
    n = len(tokens)
    if idx >= n or not (tokens[idx].kind == "OP" and tokens[idx].value == "<" and tokens[idx].is_type_angle):
        return idx
    depth = 0
    while idx < n:
        tok = tokens[idx]
        if tok.kind == "OP" and tok.is_type_angle:
            if tok.value == "<":
                depth += 1
            elif tok.value == ">":
                depth -= 1
                if depth <= 0:
                    return idx + 1
        idx += 1
    return n


def _consume_type_expr(tokens: list[luau_lex.Token], idx: int) -> int:
    """Consume a Luau type expression starting at `tokens[idx]`, returning the next non-type token index."""
    n = len(tokens)
    while idx < n and tokens[idx].kind == "OP" and tokens[idx].value in ("|", "&"):
        idx += 1

    while idx < n:
        tok = tokens[idx]
        # Generic function type `<T>(T) -> T`
        if tok.kind == "OP" and tok.value == "<" and tok.is_type_angle:
            idx = _skip_type_angles(tokens, idx)
            if idx < n and tokens[idx].kind == "OP" and tokens[idx].value == "(":
                idx = _skip_balanced(tokens, idx, "(", ")")
                if idx < n and tokens[idx].kind == "OP" and tokens[idx].value == "->":
                    idx = _consume_type_expr(tokens, idx + 1)
        elif tok.kind == "OP" and tok.value == "(":
            idx = _skip_balanced(tokens, idx, "(", ")")
            if idx < n and tokens[idx].kind == "OP" and tokens[idx].value == "->":
                idx = _consume_type_expr(tokens, idx + 1)
        elif tok.kind == "OP" and tok.value == "{":
            idx = _skip_balanced(tokens, idx, "{", "}")
        elif tok.kind == "STRING" or (tok.kind == "KEYWORD" and tok.value in ("nil", "true", "false")):
            idx += 1
        elif tok.kind == "OP" and tok.value == "...":
            idx += 1
            if idx < n and tokens[idx].kind == "IDENT":
                idx = _consume_type_expr(tokens, idx)
        elif tok.kind == "IDENT":
            if tok.value == "typeof" and idx + 1 < n and tokens[idx + 1].kind == "OP" and tokens[idx + 1].value == "(":
                idx = _skip_balanced(tokens, idx + 1, "(", ")")
            else:
                idx += 1
                while idx + 1 < n and tokens[idx].kind == "OP" and tokens[idx].value == "." and tokens[idx + 1].kind == "IDENT":
                    idx += 2
                idx = _skip_type_angles(tokens, idx)
                if idx < n and tokens[idx].kind == "OP" and tokens[idx].value == "...":
                    idx += 1
        else:
            break

        while idx < n and tokens[idx].kind == "OP" and tokens[idx].value == "?":
            idx += 1
        if idx < n and tokens[idx].kind == "OP" and tokens[idx].value == "->":
            idx += 1
            continue
        if idx < n and tokens[idx].kind == "OP" and tokens[idx].value in ("|", "&"):
            # Guard against multiline type alias followed on next line by something else? In Luau `|`/`&` always continues type.
            idx += 1
            continue
        break
    return idx


def _mark_type_tokens(tokens: list[luau_lex.Token]) -> list[bool]:
    """Return a boolean mask marking every token belonging to a Luau type declaration, annotation, cast, or generic."""
    n = len(tokens)
    in_type = [False] * n

    def mark(lo: int, hi: int) -> None:
        for k in range(max(0, lo), min(n, hi)):
            in_type[k] = True

    i = 0
    while i < n:
        tok = tokens[i]
        # 1. `[export] type ...` or `[export] type function ... end`
        if tok.kind == "KEYWORD" and tok.value == "export" and i + 1 < n and tokens[i + 1].kind == "KEYWORD" and tokens[i + 1].value == "type":
            mark(i, i + 1)
            i += 1
            tok = tokens[i]

        if tok.kind == "KEYWORD" and tok.value == "type":
            if i + 1 < n and tokens[i + 1].kind == "KEYWORD" and tokens[i + 1].value == "function":
                # `type function Name(...) ... end`
                depth = 0
                j = i + 1
                while j < n:
                    if tokens[j].kind == "KEYWORD":
                        if tokens[j].value in ("function", "if", "do"):
                            depth += 1
                        elif tokens[j].value == "end":
                            depth -= 1
                            if depth <= 0:
                                j += 1
                                break
                    j += 1
                mark(i, j)
                i = j
                continue
            # `type Name[<...>] = TypeExpr`
            j = i + 1
            if j < n and tokens[j].kind == "IDENT":
                j += 1
            j = _skip_type_angles(tokens, j)
            if j < n and tokens[j].kind == "OP" and tokens[j].value == "=":
                end_t = _consume_type_expr(tokens, j + 1)
                mark(i, end_t)
                i = end_t
                continue

        # 2. Generic `<...>` (`f<number>(x)`, `function foo<T>(...)`)
        if tok.kind == "OP" and tok.value == "<" and tok.is_type_angle and not in_type[i]:
            end_g = _skip_type_angles(tokens, i)
            mark(i, end_g)
            i = end_g
            continue

        # 3. Cast `:: TypeExpr`
        if tok.kind == "OP" and tok.value == "::":
            end_c = _consume_type_expr(tokens, i + 1)
            mark(i, end_c)
            i = end_c
            continue

        # 4. `local` / `const` / `for` binding `: TypeExpr`
        if tok.kind == "KEYWORD" and tok.value in ("local", "const", "for"):
            if i + 1 < n and not (tokens[i + 1].kind == "KEYWORD" and tokens[i + 1].value in ("function", "type")):
                j = i + 1
                while j < n:
                    if tokens[j].kind == "ATTR":
                        j += 1
                        if tokens[j - 1].value == "@[":
                            j = _skip_balanced(tokens, j - 1, "@[", "]")
                        continue
                    if tokens[j].kind != "IDENT":
                        break
                    j += 1
                    if j < n and tokens[j].kind == "OP" and tokens[j].value == ":":
                        end_ann = _consume_type_expr(tokens, j + 1)
                        mark(j, end_ann)
                        j = end_ann
                    if j < n and tokens[j].kind == "OP" and tokens[j].value == ",":
                        j += 1
                        continue
                    break
                i = j
                continue

        # 5. `function` signature parameter types & `: ReturnType`
        if tok.kind == "KEYWORD" and tok.value == "function":
            j = i + 1
            # Optional name `a.b:c`
            if j < n and tokens[j].kind == "IDENT":
                j += 1
                while j + 1 < n and tokens[j].kind == "OP" and tokens[j].value in (".", ":") and tokens[j + 1].kind == "IDENT":
                    j += 2
            # Optional `<T>`
            if j < n and tokens[j].kind == "OP" and tokens[j].value == "<" and tokens[j].is_type_angle:
                end_g = _skip_type_angles(tokens, j)
                mark(j, end_g)
                j = end_g
            # Parameter list `(...)`
            if j < n and tokens[j].kind == "OP" and tokens[j].value == "(":
                j += 1
                while j < n and not (tokens[j].kind == "OP" and tokens[j].value == ")"):
                    if tokens[j].kind == "IDENT" or (tokens[j].kind == "OP" and tokens[j].value == "..."):
                        j += 1
                        if j < n and tokens[j].kind == "OP" and tokens[j].value == ":":
                            end_p = _consume_type_expr(tokens, j + 1)
                            mark(j, end_p)
                            j = end_p
                    if j < n and tokens[j].kind == "OP" and tokens[j].value == ",":
                        j += 1
                    elif j < n and not (tokens[j].kind == "OP" and tokens[j].value == ")"):
                        j += 1
                if j < n and tokens[j].kind == "OP" and tokens[j].value == ")":
                    j += 1
                if j < n and tokens[j].kind == "OP" and tokens[j].value == ":":
                    end_ret = _consume_type_expr(tokens, j + 1)
                    mark(j, end_ret)
                    j = end_ret
                i = j
                continue

        i += 1
    return in_type


def _is_if_statement(tokens: list[luau_lex.Token], idx: int, in_type: list[bool]) -> bool:
    """Distinguish `if ... then ... end` statements from `if ... then ... else ...` expressions."""
    p = idx - 1
    while p >= 0 and in_type[p]:
        p -= 1
    if p < 0:
        return True
    prev = tokens[p]
    if prev.kind == "ATTR":
        return True
    if prev.kind == "OP":
        if prev.value in (";", "}"):
            return True
        if prev.value == ")":
            return True
        if prev.value in _BINARY_CONTINUATION_OPS or prev.value in _COMPOUND_OPS:
            return False
    if prev.kind == "KEYWORD":
        if prev.value in ("do", "repeat", "end", "break", "continue"):
            return True
        if prev.value in ("then", "else"):
            # Inside an `if`-expression (`if a then if b then 1 else 2 else 3`), `prev` is `then`/`else` of `if`-expr;
            # check if this `if` has an `else` on the same expression without an `end` or starts a block on a new line.
            return prev.line < tokens[idx].line
        if prev.value in ("local", "const", "return", "elseif", "while", "until", "for", "in", "and", "or", "not", "function"):
            return False
    return True


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


def _expr_mutants(
    tokens: list[luau_lex.Token],
    in_type: list[bool],
    lo: int,
    hi: int,
    source: str,
    ops: set[str],
    *,
    skip_simple_eq: bool = False,
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
    arith_muts: list[tuple[str, str]] = []
    logic_muts: list[tuple[str, str]] = []
    math_muts: list[tuple[str, str]] = []

    def replace_span(s_off: int, e_off: int, replacement: str) -> str:
        rel_s = s_off - expr_start
        rel_e = e_off - expr_start
        left = base_src[:rel_s]
        right = base_src[rel_e:]
        # Avoid merging tokens such as `--` comment or `..` if tight without whitespace
        if replacement.startswith("-") and right.startswith("-"):
            replacement = replacement + " "
        if replacement[0].isalpha() and left and (left[-1].isalnum() or left[-1] == "_"):
            replacement = " " + replacement
        if replacement[-1].isalpha() and right and (right[0].isalnum() or right[0] == "_"):
            replacement = replacement + " "
        return left + replacement + right

    fn_depth = 0
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

        # 1. Relational flip (`rel_flip`) — never touches `tok.is_type_angle`!
        if "rel_flip" in ops and tok.kind == "OP" and not tok.is_type_angle and tok.value in _FLIP_MAP:
            if not (skip_simple_eq and not has_logic and tok.value in ("==", "~=")):
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

    return rel_muts + arith_muts + logic_muts + math_muts


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
            if tk.value in ("function", "do", "repeat") or (tk.value == "if" and _is_if_statement(tokens, k, in_type)):
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

    # 1. `if <cond> then` / `elseif <cond> then` / `while <cond> do` / `until <cond>`
    if first.kind == "KEYWORD" and first.value in ("if", "elseif", "while", "until"):
        kw = first.value
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
            tokens, in_type, cond_lo, cond_hi, source, ops, skip_simple_eq=has_cond_inv
        ):
            if not room(len(line_mutants)):
                break
            desc = f"{kw} {mut_expr}{closer_suffix}"
            line_mutants.append((op_name, f"({mut_expr})", desc))

        if not line_mutants:
            return None
        branches = [
            f"{'if' if idx == 0 else 'elseif'} {SWITCH} == {add_mutant(op_name, stmt_src, desc)} then {expr}"
            for idx, (op_name, expr, desc) in enumerate(line_mutants)
        ]
        return f"{kw} ({' '.join(branches)} else ({cond_src})){closer_suffix}"

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
                    return f"return if {SWITCH} == {mid} then {inv} else {val}"
                return None
            rest_src = source[tokens[ret_segs[1][0]].start : last.end]
            ret_branches: list[tuple[str, str]] = []
            if "ret_val" in ops and room():
                ret_branches.append(("ret_val", f"return {inv}"))
            for seg_idx in range(1, len(ret_segs)):
                s_lo, s_hi = ret_segs[seg_idx]
                for op_name, mut_e in _expr_mutants(tokens, in_type, s_lo, s_hi, source, ops):
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
                return f"if {SWITCH} == {mid} then return {inv} end return {val}, {rest_src}"
            conds = [
                f"{'if' if idx == 0 else 'elseif'} {SWITCH} == {add_mutant(op_n, stmt_src, r_stmt)} then {r_stmt}"
                for idx, (op_n, r_stmt) in enumerate(ret_branches)
            ]
            return f"{' '.join(conds)} end return {rhs_full_src}"

        # General single or multi-expression `return expr1, expr2, ...`
        if tokens[lo + 1].kind == "KEYWORD" and tokens[lo + 1].value == "if":
            return None
        # Skip `return function(...) ... end` (its inner statements are mutated instead!)
        if len(ret_segs) == 1 and tokens[lo + 1].kind == "KEYWORD" and tokens[lo + 1].value == "function":
            return None

        ret_muts: list[tuple[str, str]] = []
        has_bool_expr_flip = False
        for seg_idx, (s_lo, s_hi) in enumerate(ret_segs):
            for op_name, mut_e in _expr_mutants(tokens, in_type, s_lo, s_hi, source, ops):
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
        conds = [
            f"{'if' if idx == 0 else 'elseif'} {SWITCH} == {add_mutant(op_n, stmt_src, r_stmt)} then {r_stmt}"
            for idx, (op_n, r_stmt) in enumerate(ret_muts)
        ]
        return f"{' '.join(conds)} end return {rhs_full_src}"

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
        # Skip `local f = function(...)` when single-line or multi-line closure
        if tokens[eq_idx + 1].kind == "KEYWORD" and tokens[eq_idx + 1].value in ("function", "if"):
            return None

        lhs_decl = source[first.start : tokens[eq_idx].start].rstrip()
        num_lhs = lhs_commas + 1
        rhs_segs = _split_top_level_commas(tokens, in_type, eq_idx + 1, hi)
        if not rhs_segs:
            return None

        if num_lhs == 1 and len(rhs_segs) == 1:
            r_lo, r_hi = rhs_segs[0]
            rhs_src = source[tokens[r_lo].start : tokens[r_hi - 1].end]
            expr_muts = _expr_mutants(tokens, in_type, r_lo, r_hi, source, ops)
            chosen: list[tuple[str, str]] = []
            for op_name, mut_rhs in expr_muts:
                if not room(len(chosen)):
                    break
                chosen.append((op_name, mut_rhs))
            if not chosen:
                return None
            branches = [
                f"{'if' if idx == 0 else 'elseif'} {SWITCH} == {add_mutant(op_name, stmt_src, f'{lhs_decl} = {mut_rhs}')} then ({mut_rhs})"
                for idx, (op_name, mut_rhs) in enumerate(chosen)
            ]
            return f"{lhs_decl} = {' '.join(branches)} else ({rhs_src})"

        # Multi-RHS `local a: number, b: number = x + 1, y - 1`
        rebuilt_parts: list[str] = []
        pending_count = 0
        any_changed = False
        for seg_idx, (r_lo, r_hi) in enumerate(rhs_segs):
            seg_src = source[tokens[r_lo].start : tokens[r_hi - 1].end]
            # Do not parenthesize the final RHS expression if it must expand multiple return values into remaining LHS vars
            if seg_idx == len(rhs_segs) - 1 and num_lhs > len(rhs_segs):
                rebuilt_parts.append(seg_src)
                continue
            seg_muts = _expr_mutants(tokens, in_type, r_lo, r_hi, source, ops)
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
                mid = add_mutant(op_name, stmt_src, f"{lhs_decl} = {preview_rhs}")
                branches.append(f"{'if' if idx == 0 else 'elseif'} {SWITCH} == {mid} then ({mut_rhs})")
            rebuilt_parts.append(f"({' '.join(branches)} else ({seg_src}))")

        return f"{lhs_decl} = {', '.join(rebuilt_parts)}" if any_changed else None

    # Skip other control keywords (`for`, `do`, `repeat`, `end`, `else`, `break`, `continue`, `function`, `export`, `type`)
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
        if tokens[assign_idx + 1].kind == "KEYWORD" and tokens[assign_idx + 1].value in ("function", "if"):
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
            for op_name, mut_e in _expr_mutants(tokens, in_type, s_lo, s_hi, source, ops):
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
        for idx, (op_name, m_stmt) in enumerate(stmt_muts):
            mid = add_mutant(op_name, stmt_src, m_stmt)
            parts.append(f"{'if' if idx == 0 else 'elseif'} {SWITCH} == {mid} then {m_stmt}")
        if do_delete:
            mid_del = add_mutant("stmt_del", stmt_src, "-- deleted statement")
            if parts:
                parts.append(f"elseif {SWITCH} ~= {mid_del} then {stmt_src} end")
                return " ".join(parts)
            return f"if {SWITCH} ~= {mid_del} then {stmt_src} end"
        parts.append(f"else {stmt_src} end")
        return " ".join(parts)

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
                    if tokens[m_idx].value in ("function", "do") or (tokens[m_idx].value == "if" and _is_if_statement(tokens, m_idx, in_type)):
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
        return f"if {SWITCH} ~= {mid_del} then {rewritten_call} end"

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
    stack: list[str] = []
    fn_sig_until = -1
    if_expr_depth = 0
    for i, tok in enumerate(tokens):
        scope_before[i] = tuple(stack)
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
                fn_sig_until = _function_body_start(tokens, i, in_type)
                stack.append("func")
            elif tok.value == "if":
                if _is_if_statement(tokens, i, in_type):
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

    def add_mutant(op: str, orig: str, mutated: str) -> int:
        nonlocal next_id
        mid = next_id
        next_id += 1
        mutants.append(Mutant(mid, file_path, current_line, op, orig, mutated, spec_filter))
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
        )
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


def _check_staged_compiles(luau_bin: str, staged_path: Path, runner: str = "luau") -> bool:
    is_lute = runner == "lute" or Path(str(luau_bin)).stem.lower() == "lute"
    cmd = [str(luau_bin), "run", str(staged_path)] if is_lute else [str(luau_bin), str(staged_path)]
    cwd = staged_path.parent if staged_path.parent.is_dir() else None
    try:
        return _run_process(cmd, cwd=cwd, timeout=5).returncode == 0
    except subprocess.TimeoutExpired:
        return False


def _write_unlinked(path: Path, content: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    if path.exists() or path.is_symlink():
        path.unlink()
    path.write_text(content, encoding="utf-8")


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
    _write_unlinked(staged_path, wrap_staged_source(instrumented_source, original_source))
    if _check_staged_compiles(luau_bin, staged_path, runner=runner):
        if not wrap:
            _write_unlinked(staged_path, _direct_source(instrumented_source))
        return mutants

    orig_lines, inst_lines = original_source.split("\n"), instrumented_source.split("\n")
    working_lines = list(orig_lines)
    valid_lines: set[int] = set()

    def _bisect(chunk: list[int]) -> None:
        if not chunk:
            return
        saved = [working_lines[ln - 1] for ln in chunk]
        for ln in chunk:
            working_lines[ln - 1] = inst_lines[ln - 1]
        _write_unlinked(staged_path, wrap_staged_source("\n".join(working_lines), original_source))
        if _check_staged_compiles(luau_bin, staged_path, runner=runner):
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

    final_source = "\n".join(working_lines)
    _write_unlinked(staged_path, wrap_staged_source(final_source, original_source) if wrap else _direct_source(final_source))
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


def _mutant_command(
    runner: str,
    luau_bin: str,
    entry: str,
    mutant_id: int,
    spec_filter: str | None,
    codegen: bool = False,
    program_args: list[str] | tuple[str, ...] = (),
) -> list[str]:
    return _selector_command(runner, luau_bin, entry, f"--mutant={mutant_id}", spec_filter, codegen, program_args)


def _mutant_batch_command(
    runner: str,
    luau_bin: str,
    entry: str,
    mutant_ids: list[int],
    spec_filter: str | None,
    codegen: bool = False,
    program_args: list[str] | tuple[str, ...] = (),
) -> list[str]:
    return _selector_command(runner, luau_bin, entry, f"--mutants={','.join(str(mid) for mid in mutant_ids)}", spec_filter, codegen, program_args)


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
) -> str:
    for entry in entries:
        cmd = _mutant_command(runner, luau_bin, entry, mutant.id, mutant.spec_filter, codegen=codegen, program_args=program_args)
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
) -> None:
    if len(batch) == 1:
        batch[0].status = _evaluate_one_mutant(batch[0], root, runner, luau_bin, [entry], timeout_sec, codegen, program_args)
        return
    cmd = _mutant_batch_command(runner, luau_bin, entry, [m.id for m in batch], batch[0].spec_filter, codegen=codegen, program_args=program_args)
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
    )
    if timed_out and head.status == "PENDING":
        head.status = "TIMEOUT"
    tail = remaining[1:]
    if tail:
        _evaluate_batch_on_entry(tail, root, runner, luau_bin, entry, timeout_sec, codegen, program_args)


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
) -> tuple[Mutant | None, list[Mutant]] | None:
    if not batch or not entries:
        return None, []
    if len(batch) == 1:
        batch[0].status = _evaluate_one_mutant(batch[0], root, runner, luau_bin, entries, timeout_sec, codegen, program_args)
        return None, []

    # Multi-entry batching: run `--mutants=...` on entry[0], then carry only SURVIVED mutants to entry[1], etc.
    alive = list(batch)
    for entry_idx, entry in enumerate(entries):
        if not alive:
            break
        if len(entries) == 1 and defer_remaining and len(alive) > 1:
            cmd = _mutant_batch_command(runner, luau_bin, entry, [m.id for m in alive], alive[0].spec_filter, codegen=codegen, program_args=program_args)
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

        _evaluate_batch_on_entry(alive, root, runner, luau_bin, entry, timeout_sec, codegen, program_args)
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
MIN_MUTANT_TIMEOUT = 1.0
BATCH_SIZE = 32
BASELINE_TIMEOUT_FACTOR = 4.0
BASELINE_TIMEOUT_FLOOR = 30.0
WORK_DIR = Path(".sert") / "mutate"
_SKIP_ANYWHERE = frozenset({".git", ".hg", ".svn", "node_modules", "__pycache__", ".venv", "venv"})
_SKIP_ROOT_DIRS = frozenset({"python", "docs", "dist", "build", "actions", ".github"})
_SKIP_IN_SERT = frozenset({"mutate", "bin", "cache"})
_LUAU_OVERLAY_SUFFIXES = (".luau", ".lua", ".json", ".txt", ".toml")
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
        help="comma-separated subset of stmt_del,ret_val,cond_inv,rel_flip,arith_op,logic_op,math_fn (default: all)",
    )
    parser.add_argument("--diff", nargs="?", const="HEAD", default=None, metavar="REV", help="only mutate lines modified in git diff since REV (default: HEAD)")
    parser.add_argument("--coverage-file", metavar="FILE", help="LCOV file (default: coverage.out)")
    parser.add_argument("--no-coverage-run", action="store_true", help="do not run `sert run --coverage` automatically if coverage.out is missing")
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
    codegen = bool(cfg.get("test.codegen", True))
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
    explicit_timeout = args.timeout is not None or "timeout" in table
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
                raise SertError(
                    f"mutate: the baseline `sert run --coverage` failed (status {baseline.status}); the unmutated suite must pass before mutants can be scored"
                    + (f"\n{detail[-4000:]}" if detail else "")
                )
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
    target_files = [
        rel
        for rel in sorted(chosen)
        if not rel.endswith("core/mutant.luau") and (cfg.root / rel).is_file() and any(chosen[rel].values())
    ]
    if not target_files:
        if diff_rev:
            print("mutate: no covered lines modified in diff; skipping")
            return 0
        raise SertError(f"mutate: no covered files under {', '.join(include)}")

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
            if max_mutants is not None and next_id - 1 >= max_mutants:
                if not src_path.exists():
                    _link_file(cfg.root / rel_path, src_path)
                continue
            staged_path = _guard_inside(work_root, stage_files_dir / rel_path)
            source_text = (cfg.root / rel_path).read_text(encoding="utf-8", errors="replace")
            remaining = (max_mutants - (next_id - 1)) if max_mutants is not None else None
            instrumented, file_mutants = instrument_source(
                source_text,
                cov_files[rel_path],
                file_path=rel_path,
                start_id=next_id,
                operators=operators,
                max_mutants=remaining,
                spec_filter=resolve_spec_filter(rel_path, specs_map),
                benign_calls=benign_calls,
                cosmetic_props=cosmetic_props,
            )
            if not file_mutants:
                # Ensure unmutated target file still exists in overlay if skipped
                if not src_path.exists():
                    _link_file(cfg.root / rel_path, src_path)
                continue
            staged_tasks.append((src_path, staged_path, source_text, instrumented, file_mutants))
            next_id = file_mutants[-1].id + 1

        # Refresh `.luaurc` aliases in overlay now that mutated target paths exist or will be written
        for src_path, _staged_path, source_text, _instrumented, _file_mutants in staged_tasks:
            if not src_path.exists():
                _write_unlinked(src_path, source_text)
        retarget_luaurc_aliases(cfg.root, work_root)

        pool = ThreadPoolExecutor(max_workers=max(1, jobs))
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
                raise SertError(f"mutate: no mutable covered statements found under {', '.join(include)}")

            by_filter: dict[str, list[Mutant]] = {}
            for m in all_mutants:
                by_filter.setdefault(m.spec_filter or "", []).append(m)

            baseline_futures = {
                (filt, entry): pool.submit(baseline_run, runner, luau_bin, entry, filt or None, work_root, timeout_sec, codegen, program_args)
                for filt in sorted(by_filter)
                for entry in entries
            }
            baseline_by_filter: dict[str, float] = {}
            for (filt, _entry), fut in baseline_futures.items():
                elapsed = fut.result()
                baseline_by_filter[filt] = max(baseline_by_filter.get(filt, 0.0), elapsed)

            mutant_floor = timeout_sec if explicit_timeout else min(timeout_sec, MIN_MUTANT_TIMEOUT)
            timeout_by_filter = {
                filt: max(mutant_floor, BASELINE_FACTOR * elapsed)
                for filt, elapsed in baseline_by_filter.items()
            }
            worker_count = max(1, jobs)
            dynamic_batch_size = max(1, min(BATCH_SIZE, (len(all_mutants) + worker_count - 1) // worker_count))
            batches = [
                (filt_mutants[i : i + dynamic_batch_size], timeout_by_filter[filt])
                for filt, filt_mutants in sorted(by_filter.items(), key=lambda kv: -baseline_by_filter.get(kv[0], 0.0))
                for i in range(0, len(filt_mutants), dynamic_batch_size)
            ]
            use_defer = len(entries) == 1
            pending = {
                pool.submit(_evaluate_mutant_batch, batch, work_root, runner, luau_bin, entries, filt_timeout, codegen, program_args, use_defer): filt_timeout
                for batch, filt_timeout in batches
            }
            while pending:
                done_fut = next(as_completed(pending))
                filt_timeout = pending.pop(done_fut)
                res = done_fut.result()
                if res is None:
                    continue
                head, tail = res
                if head is not None:
                    pending[
                        pool.submit(
                            _evaluate_single_mutant,
                            head,
                            work_root,
                            runner,
                            luau_bin,
                            entries,
                            filt_timeout,
                            codegen,
                            program_args,
                            retry_on_timeout=False,
                        )
                    ] = filt_timeout
                if len(tail) == 1:
                    pending[pool.submit(_evaluate_single_mutant, tail[0], work_root, runner, luau_bin, entries, filt_timeout, codegen, program_args)] = filt_timeout
                elif len(tail) > 1:
                    pending[pool.submit(_evaluate_mutant_batch, tail, work_root, runner, luau_bin, entries, filt_timeout, codegen, program_args, use_defer)] = filt_timeout
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

    score = summarize(all_mutants, out=sys.stderr, root=cfg.root)
    print(f"{score:.1f}")
    if minimum is not None and score < float(minimum):
        print(f"mutate: {score:.1f}% is below the {float(minimum):g}% floor", file=sys.stderr)
        return FAILED
    return 0


cmd_mutate = main
