"""Complete linear-time Luau tokenizer with nested string interpolations and generic call disambiguation."""

from __future__ import annotations

from dataclasses import dataclass
import re

RESERVED_KEYWORDS = frozenset(
    {
        "and",
        "break",
        "do",
        "else",
        "elseif",
        "end",
        "false",
        "for",
        "function",
        "if",
        "in",
        "local",
        "nil",
        "not",
        "or",
        "repeat",
        "return",
        "then",
        "true",
        "until",
        "while",
    }
)

STATEMENT_BOUNDARY_OPS = frozenset({";", "do", "then", "else", "repeat", "{"})

_HEX_NUM_RE = re.compile(r"0[xX](?:[0-9a-fA-F][0-9a-fA-F_]*(?:\.[0-9a-fA-F_]*)?|\.[0-9a-fA-F][0-9a-fA-F_]*)(?:[pP][+-]?[0-9_]+)?")
_BIN_NUM_RE = re.compile(r"0[bB][01_]+")
_DEC_NUM_RE = re.compile(r"(?:[0-9][0-9_]*(?:\.(?!\.)[0-9_]*)?|\.[0-9][0-9_]*)(?:[eE][+-]?[0-9_]+)?")
_IDENT_RE = re.compile(r"[A-Za-z_][A-Za-z0-9_]*")

THREE_CHAR_OPS = frozenset({"...", "..=", "//="})
TWO_CHAR_OPS = frozenset({"::", "->", "..", "+=", "-=", "*=", "/=", "%=", "^=", "//", "==", "~=", "<=", ">="})
SINGLE_CHAR_OPS = frozenset("+-*/%^#<>=( ){ }[ ];:,.&|?".replace(" ", ""))


@dataclass(slots=True, frozen=True)
class Token:
    kind: str
    value: str
    start: int
    end: int
    line: int
    col: int
    is_type_angle: bool = False

    @property
    def end_line(self) -> int:
        return self.line + self.value.count("\n")


def _match_long_open(source: str, pos: int) -> int | None:
    """If `source[pos:]` starts with `[=*[`, return the count of `=`; otherwise None."""
    n = len(source)
    if pos >= n or source[pos] != "[":
        return None
    idx = pos + 1
    while idx < n and source[idx] == "=":
        idx += 1
    if idx < n and source[idx] == "[":
        return idx - pos - 1
    return None


def _scan_long_bracket(source: str, pos: int, eq_count: int) -> int:
    """Scan past `[==[ ... ]==]` starting at `pos` (`[`), returning end index."""
    closer = "]" + ("=" * eq_count) + "]"
    found = source.find(closer, pos + eq_count + 2)
    return len(source) if found < 0 else found + len(closer)


def _advance_line_col(source: str, start: int, end: int, line: int, col: int) -> tuple[int, int]:
    nl_count = source.count("\n", start, end)
    if nl_count == 0:
        return line, col + (end - start)
    last_nl = source.rfind("\n", start, end)
    return line + nl_count, end - last_nl


def _scan_quoted_string(source: str, pos: int, quote: str) -> int:
    n = len(source)
    idx = pos + 1
    while idx < n:
        ch = source[idx]
        if ch == quote:
            return idx + 1
        if ch == "\\":
            idx += 1
            if idx < n and source[idx] == "z":
                idx += 1
                while idx < n and source[idx] in " \t\r\n\f\v":
                    idx += 1
                continue
            if idx < n and source[idx] == "\r" and idx + 1 < n and source[idx + 1] == "\n":
                idx += 2
                continue
            idx += 1
            continue
        if ch in "\r\n":
            return idx
        idx += 1
    return n


def _scan_interp_segment(source: str, pos: int) -> tuple[int, str]:
    """Scan an interpolated string segment starting after `` ` `` or `}`.
    Returns `(end_index, stopper)` where `stopper` is ``"`"``, `"{"`, or `""` (unterminated).
    """
    n = len(source)
    idx = pos
    while idx < n:
        ch = source[idx]
        if ch == "`":
            return idx + 1, "`"
        if ch == "{":
            return idx + 1, "{"
        if ch == "\\":
            idx += 1
            if idx < n and source[idx] == "z":
                idx += 1
                while idx < n and source[idx] in " \t\r\n\f\v":
                    idx += 1
                continue
            if idx < n and source[idx] == "\r" and idx + 1 < n and source[idx + 1] == "\n":
                idx += 2
                continue
            idx += 1
            continue
        if ch in "\r\n":
            return idx, ""
        idx += 1
    return n, ""


def _raw_tokenize(source: str, *, include_comments: bool = False) -> list[Token]:
    tokens: list[Token] = []
    n = len(source)
    pos = 0
    line = 1
    col = 1
    # Stack of brace depths for active backtick string interpolations; 0 means awaiting closing `}` of hole.
    interp_stack: list[int] = []

    while pos < n:
        ch = source[pos]

        # Whitespace
        if ch in " \t\r\n\f\v":
            end = pos + 1
            while end < n and source[end] in " \t\r\n\f\v":
                end += 1
            line, col = _advance_line_col(source, pos, end, line, col)
            pos = end
            continue

        # Comments: `--...` or `--[=[...]=]`
        if ch == "-" and pos + 1 < n and source[pos + 1] == "-":
            eq_count = _match_long_open(source, pos + 2)
            if eq_count is not None:
                end = _scan_long_bracket(source, pos + 2, eq_count)
            else:
                nl = source.find("\n", pos + 2)
                end = n if nl < 0 else nl
            if include_comments:
                tokens.append(Token("COMMENT", source[pos:end], pos, end, line, col))
            line, col = _advance_line_col(source, pos, end, line, col)
            pos = end
            continue

        # Long strings: `[=[...]=]`
        if ch == "[":
            eq_count = _match_long_open(source, pos)
            if eq_count is not None:
                end = _scan_long_bracket(source, pos, eq_count)
                tokens.append(Token("STRING", source[pos:end], pos, end, line, col))
                line, col = _advance_line_col(source, pos, end, line, col)
                pos = end
                continue

        # Quoted strings: `'...'` or `"..."`
        if ch in ("'", '"'):
            end = _scan_quoted_string(source, pos, ch)
            tokens.append(Token("STRING", source[pos:end], pos, end, line, col))
            line, col = _advance_line_col(source, pos, end, line, col)
            pos = end
            continue

        # Backtick string / interpolation start
        if ch == "`":
            end, stopper = _scan_interp_segment(source, pos + 1)
            if stopper == "{":
                tokens.append(Token("INTERP_BEGIN", source[pos:end], pos, end, line, col))
                interp_stack.append(0)
            else:
                tokens.append(Token("INTERP_FULL", source[pos:end], pos, end, line, col))
            line, col = _advance_line_col(source, pos, end, line, col)
            pos = end
            continue

        # Braces when inside an interpolated expression `{ ... }`
        if ch == "{" and interp_stack:
            interp_stack[-1] += 1
            tokens.append(Token("OP", "{", pos, pos + 1, line, col))
            pos += 1
            col += 1
            continue

        if ch == "}" and interp_stack:
            if interp_stack[-1] > 0:
                interp_stack[-1] -= 1
                tokens.append(Token("OP", "}", pos, pos + 1, line, col))
                pos += 1
                col += 1
                continue
            # Closing `}` of the current interpolation hole: resume scanning backtick text!
            end, stopper = _scan_interp_segment(source, pos + 1)
            if stopper == "{":
                tokens.append(Token("INTERP_MID", source[pos:end], pos, end, line, col))
                # interp_stack[-1] stays 0 for the next hole
            else:
                interp_stack.pop()
                tokens.append(Token("INTERP_END", source[pos:end], pos, end, line, col))
            line, col = _advance_line_col(source, pos, end, line, col)
            pos = end
            continue

        # Attributes: `@native`, `@checked`, `@[checked, deprecated]`
        if ch == "@":
            if pos + 1 < n and source[pos + 1] == "[":
                end = pos + 2
                bdepth = 1
                while end < n and bdepth > 0:
                    c = source[end]
                    if c in ("'", '"'):
                        end = _scan_quoted_string(source, end, c)
                        continue
                    if c == "[":
                        eq_attr = _match_long_open(source, end)
                        if eq_attr is not None:
                            end = _scan_long_bracket(source, end, eq_attr)
                            continue
                        bdepth += 1
                    elif c == "]":
                        bdepth -= 1
                    end += 1
                tokens.append(Token("ATTR", source[pos:end], pos, end, line, col))
                line, col = _advance_line_col(source, pos, end, line, col)
                pos = end
                continue
            m_attr = _IDENT_RE.match(source, pos + 1)
            if m_attr:
                end = m_attr.end()
                tokens.append(Token("ATTR", source[pos:end], pos, end, line, col))
                col += end - pos
                pos = end
                continue

        # Numbers
        if ch.isdigit() or (ch == "." and pos + 1 < n and source[pos + 1].isdigit()):
            m_num = None
            if ch == "0" and pos + 1 < n and source[pos + 1] in "xX":
                m_num = _HEX_NUM_RE.match(source, pos)
            elif ch == "0" and pos + 1 < n and source[pos + 1] in "bB":
                m_num = _BIN_NUM_RE.match(source, pos)
            if m_num is None:
                m_num = _DEC_NUM_RE.match(source, pos)
            if m_num:
                end = m_num.end()
                tokens.append(Token("NUMBER", source[pos:end], pos, end, line, col))
                col += end - pos
                pos = end
                continue

        # Identifiers & keywords (contextual keywords are refined in pass 2)
        m_ident = _IDENT_RE.match(source, pos)
        if m_ident:
            end = m_ident.end()
            word = source[pos:end]
            tokens.append(Token("IDENT", word, pos, end, line, col))
            col += end - pos
            pos = end
            continue

        # 3-char, 2-char, 1-char operators
        if pos + 3 <= n and source[pos : pos + 3] in THREE_CHAR_OPS:
            op = source[pos : pos + 3]
            tokens.append(Token("OP", op, pos, pos + 3, line, col))
            pos += 3
            col += 3
            continue
        if pos + 2 <= n and source[pos : pos + 2] in TWO_CHAR_OPS:
            op = source[pos : pos + 2]
            tokens.append(Token("OP", op, pos, pos + 2, line, col))
            pos += 2
            col += 2
            continue
        if ch in SINGLE_CHAR_OPS:
            tokens.append(Token("OP", ch, pos, pos + 1, line, col))
            pos += 1
            col += 1
            continue

        # Unknown single character fallback (preserves exact byte span without crashing)
        tokens.append(Token("UNKNOWN", ch, pos, pos + 1, line, col))
        pos += 1
        col += 1

    return tokens


_NON_TYPE_KEYWORDS = frozenset(
    {
        "and",
        "break",
        "do",
        "else",
        "elseif",
        "end",
        "for",
        "if",
        "in",
        "local",
        "not",
        "or",
        "repeat",
        "return",
        "then",
        "until",
        "while",
    }
)
_CALL_ARG_START_KINDS = frozenset({"STRING", "INTERP_FULL", "INTERP_BEGIN"})
_DISALLOWED_INSIDE_GENERIC_CALL = frozenset(
    {";", "=", "+=", "-=", "*=", "/=", "//=", "%=", "^=", "..=", "+", "-", "*", "/", "//", "%", "^", "..", "==", "~=", "<=", ">=", "#"}
)


def _prev_sig_index(tokens: list[Token], idx: int) -> int:
    j = idx - 1
    while j >= 0 and tokens[j].kind == "COMMENT":
        j -= 1
    return j


def _next_sig_index(tokens: list[Token], idx: int) -> int:
    n = len(tokens)
    j = idx + 1
    while j < n and tokens[j].kind == "COMMENT":
        j += 1
    return j


def _is_statement_start(tokens: list[Token], idx: int) -> bool:
    p = _prev_sig_index(tokens, idx)
    if p < 0:
        return True
    prev = tokens[p]
    if prev.kind == "ATTR":
        return True
    if prev.kind == "OP" and prev.value in (";", "{", "}", ")"):
        # After `)` could be `if (cond) then` or `foo() const x = 1`
        return True
    if prev.kind == "KEYWORD" and prev.value in ("do", "then", "else", "repeat", "end", "break", "continue"):
        return True
    # Different line or after a statement-ending token (excluding binary operators / member dots / commas / parens)
    if prev.line < tokens[idx].line:
        if prev.kind == "OP" and prev.value in (
            ".",
            ":",
            ",",
            "(",
            "[",
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
        ):
            return False
        if prev.kind == "KEYWORD" and prev.value in ("local", "return", "if", "elseif", "while", "until", "for", "in", "and", "or", "not", "function"):
            return False
        return True
    # Same-line after a complete call/ident/literal statement (`foo() continue` or `x = 1 const y = 2`)
    if prev.kind in ("IDENT", "NUMBER", "STRING", "INTERP_FULL", "INTERP_END") or (
        prev.kind == "OP" and prev.value == "]"
    ):
        return True
    if prev.kind == "KEYWORD" and prev.value in ("true", "false", "nil"):
        return True
    return False


def _match_balanced_type_angles(tokens: list[Token], open_idx: int, *, require_call_suffix: bool) -> list[int] | None:
    """If `tokens[open_idx]` (`<`) opens balanced Luau `<...>` type arguments/parameters, return the indices of
    every `<` and `>` belonging to it (including nested `<...>`); otherwise return None."""
    n = len(tokens)
    depth = 0
    paren_depth = 0
    brace_depth = 0
    bracket_depth = 0
    angle_indices: list[int] = []
    idx = open_idx

    while idx < n:
        tok = tokens[idx]
        if tok.kind == "COMMENT":
            idx += 1
            continue
        if tok.kind in ("INTERP_BEGIN", "INTERP_MID", "INTERP_END"):
            return None
        if tok.kind == "KEYWORD" and tok.value in _NON_TYPE_KEYWORDS:
            return None
        if tok.kind == "OP":
            val = tok.value
            if val in _DISALLOWED_INSIDE_GENERIC_CALL:
                # Allow `=` ONLY as default type parameter `type Foo<T = number>` when not a call!
                if val == "=" and not require_call_suffix and paren_depth == 0 and brace_depth == 0 and bracket_depth == 0:
                    idx += 1
                    continue
                # Allow `-` ONLY before a number literal in singleton negative number types if ever used
                return None
            if val == "<" and paren_depth == 0 and brace_depth == 0 and bracket_depth == 0:
                depth += 1
                angle_indices.append(idx)
                idx += 1
                continue
            if val == ">" and paren_depth == 0 and brace_depth == 0 and bracket_depth == 0:
                depth -= 1
                angle_indices.append(idx)
                if depth == 0:
                    after = _next_sig_index(tokens, idx)
                    if not require_call_suffix:
                        return angle_indices
                    if after < n:
                        nxt = tokens[after]
                        if nxt.kind in _CALL_ARG_START_KINDS or (nxt.kind == "OP" and nxt.value in ("(", "{")):
                            return angle_indices
                    return None
                idx += 1
                continue
            if val == "(":
                paren_depth += 1
            elif val == ")":
                paren_depth -= 1
                if paren_depth < 0:
                    return None
            elif val == "{":
                brace_depth += 1
            elif val == "}":
                brace_depth -= 1
                if brace_depth < 0:
                    return None
            elif val == "[":
                bracket_depth += 1
            elif val == "]":
                bracket_depth -= 1
                if bracket_depth < 0:
                    return None
            # Nested `<...>` inside function types `(<T>(T) -> T)` or table types `{ a: Array<T> }`
            elif val == "<":
                nested = _match_balanced_type_angles(tokens, idx, require_call_suffix=False)
                if nested is None:
                    return None
                angle_indices.extend(nested)
                idx = nested[-1] + 1
                continue
        idx += 1
    return None


def tokenize(source: str, *, include_comments: bool = True) -> list[Token]:
    """Tokenize Luau `source` in linear time with contextual keywords and `is_type_angle` disambiguation."""
    raw = _raw_tokenize(source, include_comments=include_comments)
    n = len(raw)
    if n == 0:
        return raw

    # Pass 1: classify reserved vs contextual keywords (`export`, `type`, `const`, `continue`).
    kinds = [tok.kind for tok in raw]
    for i, tok in enumerate(raw):
        if tok.kind != "IDENT":
            continue
        p = _prev_sig_index(raw, i)
        prev = raw[p] if p >= 0 else None
        is_member = prev is not None and prev.kind == "OP" and prev.value in (".", ":")
        if is_member:
            continue
        word = tok.value
        if word in RESERVED_KEYWORDS:
            kinds[i] = "KEYWORD"
            continue

    # Refine contextual keywords using resolved reserved keywords
    temp = [
        Token(kinds[i], raw[i].value, raw[i].start, raw[i].end, raw[i].line, raw[i].col)
        for i in range(n)
    ]
    for i, tok in enumerate(temp):
        if tok.kind != "IDENT":
            continue
        p = _prev_sig_index(temp, i)
        prev = temp[p] if p >= 0 else None
        if prev is not None and prev.kind == "OP" and prev.value in (".", ":"):
            continue
        word = tok.value
        nxt_idx = _next_sig_index(temp, i)
        nxt = temp[nxt_idx] if nxt_idx < n else None

        if word == "export":
            if nxt is not None and nxt.kind == "IDENT" and nxt.value == "type" and _is_statement_start(temp, i):
                kinds[i] = "KEYWORD"
        elif word == "type":
            from_export = prev is not None and kinds[p] == "KEYWORD" and prev.value == "export"
            if (from_export or _is_statement_start(temp, i)) and nxt is not None:
                if nxt.kind == "KEYWORD" and nxt.value == "function":
                    kinds[i] = "KEYWORD"
                elif nxt.kind == "IDENT":
                    after_name_idx = _next_sig_index(temp, nxt_idx)
                    after_name = temp[after_name_idx] if after_name_idx < n else None
                    if after_name is not None and after_name.kind == "OP" and after_name.value in ("=", "<"):
                        kinds[i] = "KEYWORD"
        elif word == "const":
            if _is_statement_start(temp, i) and nxt is not None:
                if (nxt.kind == "KEYWORD" and nxt.value == "function") or nxt.kind == "IDENT":
                    kinds[i] = "KEYWORD"
        elif word == "continue":
            if _is_statement_start(temp, i):
                if nxt is None or not (
                    (nxt.kind == "OP" and nxt.value in ("=", ",", "(", "{", "[", ".", ":", "+=", "-=", "*=", "/=", "//=", "%=", "^=", "..="))
                    or nxt.kind in _CALL_ARG_START_KINDS
                ):
                    kinds[i] = "KEYWORD"

    # Rebuild token list with finalized keyword kinds before generic angle disambiguation
    stage = [
        Token(kinds[i], raw[i].value, raw[i].start, raw[i].end, raw[i].line, raw[i].col)
        for i in range(n)
    ]

    # Pass 2: mark `is_type_angle = True` on `<` and `>` in type declarations, type annotations, and generic calls.
    type_angles: set[int] = set()
    i = 0
    while i < n:
        tok = stage[i]
        if tok.kind == "OP" and tok.value == "<" and i not in type_angles:
            p = _prev_sig_index(stage, i)
            prev = stage[p] if p >= 0 else None
            matched: list[int] | None = None

            if prev is not None:
                # 1. `function<T>(` or `function foo<T>(` or `function a.b:c<T>(`
                if prev.kind == "KEYWORD" and prev.value == "function":
                    matched = _match_balanced_type_angles(stage, i, require_call_suffix=False)
                elif prev.kind == "IDENT":
                    # Check if `prev` is the name of a `function` or `type` declaration, or a type name in an annotation, or a generic call!
                    q = _prev_sig_index(stage, p)
                    # Walk backwards past `.ident` / `:ident` chains for `function a.b:c<T>(` or `Module.Type<T>`
                    head = q
                    while head >= 0 and stage[head].kind == "OP" and stage[head].value in (".", ":"):
                        ident_before = _prev_sig_index(stage, head)
                        if ident_before < 0 or stage[ident_before].kind != "IDENT":
                            break
                        head = _prev_sig_index(stage, ident_before)
                    head_tok = stage[head] if head >= 0 else None
                    if head_tok is not None and head_tok.kind == "KEYWORD" and head_tok.value in ("function", "type"):
                        matched = _match_balanced_type_angles(stage, i, require_call_suffix=False)
                    elif head_tok is not None and head_tok.kind == "OP" and head_tok.value in (":", "::", "->", "|", "&", "="):
                        # Type annotation `: Array<T>`, cast `:: Array<T>`, return `-> Result<T, E>`, or type alias RHS `type X = Box<T>`
                        if head_tok.value != "=" or _is_in_type_alias_rhs(stage, head):
                            matched = _match_balanced_type_angles(stage, i, require_call_suffix=False)
                    if matched is None:
                        # Generic call in expression position: `f<number>(x)`, `a.b:c<T> { ... }`, `f<T> "str"`
                        matched = _match_balanced_type_angles(stage, i, require_call_suffix=True)
                elif prev.kind == "OP" and prev.value in (")", "]"):
                    # `(getFn())<number>(x)` or `fns[1]<number>(x)`
                    matched = _match_balanced_type_angles(stage, i, require_call_suffix=True)
                elif prev.kind == "OP" and prev.value in (":", "::", "->", "|", "&"):
                    # Anonymous generic function type `: <T>(T) -> T`
                    matched = _match_balanced_type_angles(stage, i, require_call_suffix=False)

            if matched:
                type_angles.update(matched)
        i += 1

    if not type_angles:
        return stage

    return [
        Token(tok.kind, tok.value, tok.start, tok.end, tok.line, tok.col, i in type_angles)
        for i, tok in enumerate(stage)
    ]


def _is_in_type_alias_rhs(tokens: list[Token], eq_idx: int) -> bool:
    """Return True when `tokens[eq_idx]` (`=`) is the `=` of `[export] type Name[<...>] = ...`."""
    j = _prev_sig_index(tokens, eq_idx)
    if j < 0:
        return False
    # Skip optional `<...>` type parameter list on LHS of `type Foo<T> = ...`
    if tokens[j].kind == "OP" and tokens[j].value == ">":
        depth = 1
        j -= 1
        while j >= 0 and depth > 0:
            if tokens[j].kind == "OP":
                if tokens[j].value == ">":
                    depth += 1
                elif tokens[j].value == "<":
                    depth -= 1
            j -= 1
        j = _prev_sig_index(tokens, j + 1)
    if j >= 0 and tokens[j].kind == "IDENT":
        k = _prev_sig_index(tokens, j)
        if k >= 0 and tokens[k].kind == "KEYWORD" and tokens[k].value == "type":
            return True
    return False


def is_type_angle(tokens: list[Token], idx: int) -> bool:
    """Return True if `tokens[idx]` (`<` or `>`) belongs to generic type parameters/arguments rather than a comparison."""
    return 0 <= idx < len(tokens) and tokens[idx].is_type_angle


_EXPR_OPS = frozenset(
    {
        "=",
        "+=",
        "-=",
        "*=",
        "/=",
        "//=",
        "%=",
        "^=",
        "..=",
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
        "#",
        "(",
        "[",
        "{",
        ",",
    }
)
_EXPR_KEYWORDS = frozenset({"and", "or", "not", "return", "if", "elseif", "while", "until", "in"})


def _scan_scopes(tokens: list[Token]) -> tuple[bool, set[str]]:
    """Single-pass Luau scope scan returning `(has_top_level_return, type_function_identifiers)`.

    Distinguishes statement `if ... then ... end` (`"if_stmt"`, closed by `end`) from inline Luau
    `if ... then ... else ...` expressions (`"if_expr"`, closed by `else` with no `end`), and tracks
    `[export] type function ... end` bodies so callers can avoid shadowing globals inside Luau type functions.
    """
    stack: list[str] = []
    fn_depth = 0
    type_fn_depth = 0
    brace_depth = 0
    expr_pos = False
    top_return = False
    type_fn_idents: set[str] = set()
    n = len(tokens)

    for i, tok in enumerate(tokens):
        kind = tok.kind
        val = tok.value
        if kind == "COMMENT":
            continue
        if kind in ("INTERP_BEGIN", "INTERP_MID"):
            expr_pos = True
            continue
        if kind == "OP":
            if val == "{":
                brace_depth += 1
            elif val == "}" and brace_depth > 0:
                brace_depth -= 1
            if val == ";":
                expr_pos = brace_depth > 0
            elif val in ("<", ">") and tok.is_type_angle:
                expr_pos = False
            else:
                expr_pos = val in _EXPR_OPS
            continue
        if kind == "KEYWORD":
            if val == "function":
                p = _prev_sig_index(tokens, i)
                if p >= 0 and tokens[p].kind == "KEYWORD" and tokens[p].value == "type":
                    stack.append("type_fn")
                    type_fn_depth += 1
                else:
                    stack.append("fn")
                    fn_depth += 1
                expr_pos = False
            elif val == "if":
                stack.append("if_expr" if expr_pos else "if_stmt")
                expr_pos = True
            elif val == "then":
                expr_pos = bool(stack and stack[-1] == "if_expr")
            elif val == "else":
                if stack and stack[-1] == "if_expr":
                    stack.pop()
                    expr_pos = True
                else:
                    expr_pos = False
            elif val == "do":
                stack.append("do")
                expr_pos = False
            elif val == "end":
                while stack and stack[-1] == "if_expr":
                    stack.pop()
                if stack:
                    popped = stack.pop()
                    if popped == "fn":
                        fn_depth -= 1
                    elif popped == "type_fn":
                        type_fn_depth -= 1
                expr_pos = False
            elif val == "return":
                if fn_depth == 0 and type_fn_depth == 0:
                    top_return = True
                expr_pos = True
            else:
                expr_pos = val in _EXPR_KEYWORDS
            continue

        if type_fn_depth > 0 and kind == "IDENT":
            p = _prev_sig_index(tokens, i)
            skip = False
            if p >= 0 and tokens[p].kind == "OP":
                if tokens[p].value in (".", ":"):
                    skip = True
                elif brace_depth > 0 and tokens[p].value in ("{", ",", ";"):
                    nxt = _next_sig_index(tokens, i)
                    if nxt < n and tokens[nxt].kind == "OP" and tokens[nxt].value == "=":
                        skip = True
            if not skip:
                type_fn_idents.add(val)
        expr_pos = False

    return top_return, type_fn_idents


def has_top_level_return(source_or_tokens: str | list[Token]) -> bool:
    """Return True if the chunk has a `return` statement at top-level module scope (outside any `function ... end`)."""
    tokens = tokenize(source_or_tokens, include_comments=False) if isinstance(source_or_tokens, str) else source_or_tokens
    return _scan_scopes(tokens)[0]


def type_function_identifiers(source_or_tokens: str | list[Token]) -> set[str]:
    """Return all non-member, non-table-field-key identifier names referenced inside `[export] type function ... end` blocks."""
    tokens = tokenize(source_or_tokens, include_comments=False) if isinstance(source_or_tokens, str) else source_or_tokens
    return _scan_scopes(tokens)[1]


def first_code_offset(source: str) -> int:
    """Return the byte offset at the start of the first non-directive/non-comment line (or `len(source)` if none),
    preserving all leading `--!` hot comments (`--!strict`, `--!native`, `--!optimize`) at the top of the chunk."""
    tokens = tokenize(source, include_comments=False)
    if not tokens:
        return len(source)
    first_tok = tokens[0]
    line_start = source.rfind("\n", 0, first_tok.start)
    return 0 if line_start < 0 else line_start + 1


def referenced_identifiers(source_or_tokens: str | list[Token]) -> set[str]:
    """Return all non-member, non-table-field-key identifier names referenced anywhere in `source_or_tokens`."""
    tokens = tokenize(source_or_tokens, include_comments=False) if isinstance(source_or_tokens, str) else source_or_tokens
    names: set[str] = set()
    brace_depth = 0
    n = len(tokens)
    for i, tok in enumerate(tokens):
        if tok.kind == "OP":
            if tok.value == "{":
                brace_depth += 1
            elif tok.value == "}" and brace_depth > 0:
                brace_depth -= 1
            continue
        if tok.kind != "IDENT":
            continue
        p = _prev_sig_index(tokens, i)
        if p >= 0 and tokens[p].kind == "OP":
            if tokens[p].value in (".", ":"):
                continue
            if brace_depth > 0 and tokens[p].value in ("{", ",", ";"):
                nxt = _next_sig_index(tokens, i)
                if nxt < n and tokens[nxt].kind == "OP" and tokens[nxt].value == "=":
                    continue
        names.add(tok.value)
    return names
