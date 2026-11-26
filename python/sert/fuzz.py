"""`sert fuzz [specs...]`: coverage- and comparison-guided in-process Luau greybox fuzzer."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import time
import tomllib
from typing import Any

from sert import agent, config as config_mod, coverage as coverage_mod, fetch, graph, luau_lex, mutate, run as run_mod
from sert.util import FAILED, SertError, as_list, expand_globs, has_glob, luau_string, posix, strip_jsonc, write_atomic

FUZZ_DIR = Path(".sert") / "fuzz"
CORPUS_DEFAULT_REL = FUZZ_DIR / "corpus"
DICT_REL = FUZZ_DIR / "dict.json"
OVERLAY_REL = FUZZ_DIR / "overlay"
REGRESSIONS_REL = Path("test") / ".sert-regressions.toml"

_CMP_OPS = frozenset({"==", "~=", "<", "<=", ">", ">="})
_LHS_STOP_KEYWORDS = frozenset(
    {
        "and",
        "or",
        "if",
        "elseif",
        "then",
        "else",
        "while",
        "until",
        "do",
        "return",
        "local",
        "const",
        "in",
        "for",
        "function",
    }
)
_LHS_STOP_OPS = frozenset(
    {"=", "+=", "-=", "*=", "/=", "//=", "%=", "..=", ",", ";", "==", "~=", "<", "<=", ">", ">="}
)
_RHS_STOP_KEYWORDS = frozenset(
    {
        "and",
        "or",
        "then",
        "do",
        "else",
        "elseif",
        "until",
        "end",
        "return",
        "local",
        "const",
        "for",
        "while",
        "repeat",
        "break",
        "continue",
        "function",
    }
)
_RHS_STOP_OPS = frozenset({",", ";", "=", "==", "~=", "<", "<=", ">", ">="})
_TRIVIAL_NUMBERS = frozenset({0, 1, -1, 2})
_RE_V1_TOKEN = re.compile(r"^v1:(-?\d+):(\d+):(.*)$")
_RE_TAPE_TOKEN = re.compile(r"^v([12]):(-?\d+):(\d+):(.*)$")


def encode_v1_token(seed: int, size: int, tape: list[int]) -> str:
    """Encode `(seed, size, tape)` as a `v1:<seed>:<size>:<hex>` byte-tape token (4-byte BE per u32)."""
    hex_chunks = [f"{int(v) & 0xFFFFFFFF:08x}" for v in tape]
    return f"v1:{int(seed)}:{int(size)}:{''.join(hex_chunks)}"


def encode_tape_token(seed: int, size: int, tape: list[int]) -> str:
    """Encode `(seed, size, tape)` as `v1:` (u32) or `v2:` (u53) lossless tape token."""
    ints = [int(v) for v in tape]
    if any(v < 0 or v > 0xFFFFFFFF for v in ints):
        hex_chunks = [f"{max(0, v) & 0x1FFFFFFFFFFFFF:014x}" for v in ints]
        return f"v2:{int(seed)}:{int(size)}:{''.join(hex_chunks)}"
    return encode_v1_token(seed, size, ints)


def decode_tape_token(token: str) -> tuple[int, int, list[int]] | None:
    """Decode `v1:<seed>:<size>:<hex>` / `v2:<seed>:<size>:<hex>` (or legacy comma-int) into `(seed, size, tape)` or `None`."""
    if not isinstance(token, str):
        return None
    m = _RE_TAPE_TOKEN.match(token.strip())
    if not m:
        return None
    version = int(m.group(1))
    seed = int(m.group(2))
    size = int(m.group(3))
    rest = m.group(4)
    if not rest:
        return seed, size, []
    if version == 1 and "," in rest:
        tape: list[int] = []
        for part in rest.split(","):
            part = part.strip()
            if not part or not part.isdigit():
                return None
            tape.append(int(part) & 0xFFFFFFFF)
        return seed, size, tape
    width = 14 if version == 2 else 8
    if len(rest) % width != 0 or not all(ch in "0123456789abcdefABCDEF" for ch in rest):
        return None
    tape = [int(rest[i : i + width], 16) for i in range(0, len(rest), width)]
    if version == 2 and any(v > 0x1FFFFFFFFFFFFF for v in tape):
        return None
    return seed, size, tape


def decode_v1_token(token: str) -> tuple[int, int, list[int]] | None:
    """Decode `v1:<seed>:<size>:<hex>` (or legacy comma-u32) into `(seed, size, tape)` or `None`."""
    if not isinstance(token, str) or not _RE_V1_TOKEN.match(token.strip()):
        return None
    return decode_tape_token(token)


def load_regressions_toml(root: Path) -> dict[str, list[str]]:
    """Load `test/.sert-regressions.toml` returning `{ test_name: [token, ...] }`."""
    return run_mod.load_regressions_by_test(Path(root))


def save_regression_token(root: Path, test_name: str, spec_file: str, token: str) -> bool:
    """Persist `(test_name, spec_file, token)` into `test/.sert-regressions.toml` atomically, deduplicated and sorted."""
    root_path = Path(root)
    test = str(test_name or "").strip()
    tok = str(token or "").strip()
    if not test or not tok:
        return False
    added = run_mod.save_regression_tokens(
        root_path,
        [{"test": test, "file": str(spec_file or ""), "token": tok}],
    )
    return len(added) > 0


def _parse_luau_number(raw: str) -> int | float | None:
    return luau_lex.parse_number(raw)


def _is_unary_minus_prefix(tokens: list[luau_lex.Token], in_type: list[bool], k: int) -> bool:
    if k <= 0 or in_type[k - 1]:
        return False
    prev = tokens[k - 1]
    if prev.kind != "OP" or prev.value != "-":
        return False
    if k - 1 == 0:
        return True
    before = tokens[k - 2]
    if in_type[k - 2]:
        return False
    if before.kind in ("IDENT", "NUMBER", "STRING", "INTERP_FULL", "INTERP_END"):
        return False
    if before.kind == "OP" and before.value in (")", "]", "}", "..."):
        return False
    if before.kind == "KEYWORD" and before.value in ("true", "false", "nil"):
        return False
    return True


def _extract_dict_constants(tokens: list[luau_lex.Token], in_type: list[bool]) -> tuple[list[str], list[int | float]]:
    strings: list[str] = []
    numbers: list[int | float] = []
    seen_s: set[str] = set()
    seen_n: set[tuple[str, str]] = set()
    for i, tok in enumerate(tokens):
        if in_type[i]:
            continue
        if tok.kind == "STRING":
            val = luau_lex.unquote_string(tok.value)
            if val is not None and 2 <= len(val) <= 64 and not val.startswith(("@", "./", "../")):
                if val not in seen_s:
                    seen_s.add(val)
                    strings.append(val)
        elif tok.kind == "NUMBER":
            num = _parse_luau_number(tok.value)
            if num is None:
                continue
            if _is_unary_minus_prefix(tokens, in_type, i):
                num = -num
            if isinstance(num, int) and num in _TRIVIAL_NUMBERS:
                continue
            if isinstance(num, float) and num in (0.0, 1.0, -1.0, 2.0):
                continue
            key = (type(num).__name__, repr(num))
            if key not in seen_n:
                seen_n.add(key)
                numbers.append(num)
    return strings, numbers


def _find_cmp_lhs_start(tokens: list[luau_lex.Token], in_type: list[bool], op_idx: int) -> int:
    d = 0
    blk = 0
    k = op_idx - 1
    while k >= 0:
        if in_type[k]:
            k -= 1
            continue
        tk = tokens[k]
        if tk.kind == "INTERP_END":
            d += 1
        elif tk.kind == "INTERP_BEGIN":
            if d == 0 and blk == 0:
                return k + 1
            d -= 1
        elif tk.kind == "OP" and not tk.is_type_angle:
            if tk.value in (")", "}", "]"):
                d += 1
            elif tk.value in ("(", "{", "["):
                if d == 0 and blk == 0:
                    return k + 1
                d -= 1
            elif d == 0 and blk == 0 and tk.value in _LHS_STOP_OPS:
                return k + 1
        elif tk.kind == "KEYWORD":
            if tk.value == "end":
                blk += 1
            elif tk.value == "function":
                if blk > 0:
                    blk -= 1
                else:
                    return k + 1
            elif blk > 0 and tk.value in ("do",):
                blk -= 1
            elif blk > 0 and tk.value == "if" and luau_lex.is_if_statement(tokens, k, in_type):
                blk -= 1
            elif d == 0 and blk == 0 and tk.value in _LHS_STOP_KEYWORDS:
                return k + 1
        k -= 1
    return 0


def _find_cmp_rhs_end(tokens: list[luau_lex.Token], in_type: list[bool], op_idx: int) -> int:
    n = len(tokens)
    d = 0
    blk = 0
    tern = 0
    k = op_idx + 1
    while k < n:
        if in_type[k]:
            k += 1
            continue
        tk = tokens[k]
        if tk.kind == "INTERP_BEGIN":
            d += 1
        elif tk.kind == "INTERP_END":
            if d == 0 and blk == 0:
                return k
            d -= 1
        elif tk.kind == "OP" and not tk.is_type_angle:
            if tk.value in ("(", "{", "["):
                d += 1
            elif tk.value in (")", "}", "]"):
                if d == 0 and blk == 0:
                    return k
                d -= 1
            elif d == 0 and blk == 0 and tern == 0 and tk.value in _RHS_STOP_OPS:
                return k
        elif tk.kind == "KEYWORD":
            if blk > 0:
                if tk.value in ("function", "do") or (tk.value == "if" and luau_lex.is_if_statement(tokens, k, in_type)):
                    blk += 1
                elif tk.value == "end":
                    blk -= 1
            elif tk.value == "function":
                blk += 1
            elif d == 0:
                if tk.value == "if":
                    if luau_lex.is_if_statement(tokens, k, in_type):
                        return k
                    tern += 1
                elif tk.value == "else":
                    if tern > 0:
                        tern -= 1
                    else:
                        return k
                elif tk.value in ("elseif", "then") and tern > 0:
                    pass
                elif tk.value in _RHS_STOP_KEYWORDS:
                    return k
        k += 1
    return n


def _is_condition_comparison(tokens: list[luau_lex.Token], in_type: list[bool], op_idx: int) -> bool:
    """Return True if comparison is inside `if`/`elseif`/`while`/`until` condition OR a pure expression."""
    # Check assignment LHS misuse (cannot happen for `==`/`<`/etc. in valid Luau except malformed tokens)
    return not mutate._has_block_statements(tokens, in_type, max(0, op_idx - 1), min(len(tokens), op_idx + 2))


def instrument_fuzz_source(
    source_text: str,
    *,
    file_path: str = "<input>",
    start_edge_id: int = 1,
    start_cmp_id: int = 1,
    include_edges: bool = True,
    include_cmps: bool = True,
) -> tuple[str, dict[str, Any]]:
    """Apply line-preserving edge + relational comparison instrumentation and extract literal dictionary entries."""
    norm_path = file_path.replace("\\", "/")
    empty_meta = {
        "file": norm_path,
        "edges": 0,
        "cmps": 0,
        "next_edge_id": start_edge_id,
        "next_cmp_id": start_cmp_id,
        "strings": [],
        "numbers": [],
    }
    if norm_path.endswith(("core/mutant.luau", ".spec.luau", ".spec.lua")):
        return source_text, empty_meta

    tokens = luau_lex.tokenize(source_text, include_comments=False)
    if not tokens:
        return source_text, empty_meta
    in_type = mutate._mark_type_tokens(tokens)
    strings, numbers = _extract_dict_constants(tokens, in_type)

    # Identify branch block points and relational comparisons
    n = len(tokens)
    # List of `(offset, priority, text)` insertions/replacements `(start, end, text)`
    edits: list[tuple[int, int, int, str]] = []
    edge_id = start_edge_id
    cmp_id = start_cmp_id

    if include_edges:
        block_stack: list[str] = []
        fn_sig_until = -1
        for i, tok in enumerate(tokens):
            if in_type[i] or i < fn_sig_until:
                continue
            if tok.kind != "KEYWORD":
                continue
            val = tok.value
            if val == "function":
                fn_sig_until = mutate._function_body_start(tokens, i, in_type)
            elif val == "if":
                block_stack.append("if_stmt_cond" if luau_lex.is_if_statement(tokens, i, in_type) else "if_expr_cond")
            elif val == "elseif":
                if block_stack and block_stack[-1] == "if_stmt_body":
                    block_stack[-1] = "if_stmt_cond"
                elif not block_stack or block_stack[-1] != "if_expr_cond":
                    block_stack.append("if_stmt_cond")
            elif val == "then":
                if block_stack and block_stack[-1] == "if_stmt_cond":
                    block_stack[-1] = "if_stmt_body"
                    eid = edge_id
                    edge_id += 1
                    edits.append((tok.end, tok.end, 20, f" __SERT_FUZZ_EDGE({eid});"))
                elif block_stack and block_stack[-1] == "if_expr_cond":
                    block_stack[-1] = "if_expr_body"
            elif val == "else":
                if block_stack and block_stack[-1] == "if_expr_body":
                    block_stack.pop()
            elif val in ("while", "for"):
                block_stack.append("loop_cond")
            elif val == "do":
                if block_stack and block_stack[-1] == "loop_cond":
                    block_stack.pop()
                    eid = edge_id
                    edge_id += 1
                    edits.append((tok.end, tok.end, 20, f" __SERT_FUZZ_EDGE({eid});"))
            elif val == "repeat":
                eid = edge_id
                edge_id += 1
                edits.append((tok.end, tok.end, 20, f" __SERT_FUZZ_EDGE({eid});"))
            elif val == "end":
                for idx in range(len(block_stack) - 1, -1, -1):
                    if block_stack[idx] == "if_stmt_body":
                        del block_stack[idx:]
                        break

    if include_cmps:
        fn_sig_until = -1
        for i, tok in enumerate(tokens):
            if in_type[i]:
                continue
            if i < fn_sig_until:
                continue
            if tok.kind == "KEYWORD" and tok.value == "function":
                fn_sig_until = mutate._function_body_start(tokens, i, in_type)
                continue
            if tok.kind != "OP" or tok.is_type_angle or tok.value not in _CMP_OPS:
                continue
            lhs_lo = _find_cmp_lhs_start(tokens, in_type, i)
            rhs_hi = _find_cmp_rhs_end(tokens, in_type, i)
            if lhs_lo >= i or rhs_hi <= i + 1:
                continue
            if mutate._has_block_statements(tokens, in_type, lhs_lo, i) or mutate._has_block_statements(
                tokens, in_type, i + 1, rhs_hi
            ):
                continue
            if not _is_condition_comparison(tokens, in_type, i):
                continue
            cid = cmp_id
            cmp_id += 1
            lhs_start = tokens[lhs_lo].start
            rhs_end = tokens[rhs_hi - 1].end
            edits.append((lhs_start, lhs_start, 30, f'__SERT_FUZZ_CMP({cid}, "{tok.value}", '))
            edits.append((tok.start, tok.end, 10, ", "))
            edits.append((rhs_end, rhs_end, 5, ")"))

    edges_count = edge_id - start_edge_id
    cmps_count = cmp_id - start_cmp_id
    if edges_count == 0 and cmps_count == 0:
        return source_text, {
            "file": norm_path,
            "edges": 0,
            "cmps": 0,
            "next_edge_id": start_edge_id,
            "next_cmp_id": start_cmp_id,
            "strings": strings,
            "numbers": numbers,
        }

    first_off = luau_lex.first_code_offset(source_text)
    preamble = (
        'local _SF_OK, _SF_RT: any = pcall(require, "@__SERT_FUZZ"); '
        'local __SERT_F: any = if _SF_OK and type(_SF_RT) == "table" then _SF_RT '
        'elseif type(_G) == "table" then (_G :: any).__SERT_FUZZ else nil; '
        "local __SERT_FUZZ_EDGE: (number) -> () = if __SERT_F then __SERT_F.edge else function(_id: number) end; "
        "local __SERT_FUZZ_CMP: (number, string, any, any) -> boolean = if __SERT_F then __SERT_F.cmp else "
        'function(_id: number, op: string, a: any, b: any): boolean if op == "==" then return a == b '
        'elseif op == "~=" then return a ~= b elseif op == "<" then return a < b '
        'elseif op == "<=" then return a <= b elseif op == ">" then return a > b '
        'elseif op == ">=" then return a >= b end return false end; '
    )
    edits.append((first_off, first_off, 100, preamble))

    # Apply edits in descending offset order; at equal offset apply smaller priority last (so outer wrappers come before inner)
    edits.sort(key=lambda item: (item[0], item[1], -item[2]), reverse=True)
    buf = list(source_text)
    for start, end, _prio, text in edits:
        buf[start:end] = list(text)
    instrumented = "".join(buf)

    meta = {
        "file": norm_path,
        "edges": edges_count,
        "cmps": cmps_count,
        "next_edge_id": edge_id,
        "next_cmp_id": cmp_id,
        "strings": strings,
        "numbers": numbers,
    }
    return instrumented, meta


def _check_luau_compiles(luau_bin: str | None, source_text: str, check_dir: Path, wrap: bool = True) -> bool:
    if not luau_bin:
        return True
    wrapped = mutate.wrap_staged_source(source_text) if wrap else source_text
    probe = check_dir / "_fuzz_compile_probe.luau"
    probe.write_text(wrapped, encoding="utf-8")
    try:
        res = subprocess.run([luau_bin, str(probe)], capture_output=True, text=True, timeout=15.0)
        return res.returncode == 0
    except (OSError, subprocess.TimeoutExpired):
        return False
    finally:
        probe.unlink(missing_ok=True)


def instrument_and_validate(
    luau_bin: str | None,
    source_text: str,
    *,
    file_path: str,
    start_edge_id: int,
    start_cmp_id: int,
    check_dir: Path,
) -> tuple[str, dict[str, Any]]:
    """Instrument `source_text` and validate syntax via `luau`, falling back cleanly if an expression cannot wrap."""
    inst, meta = instrument_fuzz_source(
        source_text,
        file_path=file_path,
        start_edge_id=start_edge_id,
        start_cmp_id=start_cmp_id,
        include_edges=True,
        include_cmps=True,
    )
    if (meta["edges"] > 0 or meta["cmps"] > 0) and _check_luau_compiles(luau_bin, inst, check_dir):
        return inst, meta

    if meta["cmps"] > 0:
        inst_edges, meta_edges = instrument_fuzz_source(
            source_text,
            file_path=file_path,
            start_edge_id=start_edge_id,
            start_cmp_id=start_cmp_id,
            include_edges=True,
            include_cmps=False,
        )
        if _check_luau_compiles(luau_bin, inst_edges, check_dir):
            return inst_edges, meta_edges

    return source_text, {
        "file": file_path.replace("\\", "/"),
        "edges": 0,
        "cmps": 0,
        "next_edge_id": start_edge_id,
        "next_cmp_id": start_cmp_id,
        "strings": meta["strings"],
        "numbers": meta["numbers"],
    }


def _collect_target_files(cfg: config_mod.Config) -> list[str]:
    cov_inc = as_list(cfg.table("coverage").get("include"))
    mut_inc = as_list(cfg.table("mutate").get("include"))
    include_raw = cov_inc or mut_inc or ["src"]
    include = [coverage_mod.norm(str(p)).rstrip("/") for p in include_raw]
    exclude = [coverage_mod.norm(str(p)).rstrip("/") for p in as_list(cfg.table("mutate").get("exclude"))]

    found = expand_globs(cfg.root, [f"{p}/**/*.luau" if not has_glob(p) else p for p in include], files=True)
    rels: list[str] = []
    for path in found:
        rel = posix(path, cfg.root)
        if rel.endswith(("core/mutant.luau", "prop/fuzz.luau", ".spec.luau", ".spec.lua")):
            continue
        if any(rel == ex or rel.startswith(ex + "/") for ex in exclude):
            continue
        rels.append(rel)
    return sorted(set(rels))


def build_fuzz_overlay(root: Path, mutated_rels: set[str] | None = None) -> Path:
    """Create a zero-copy fuzz overlay under `.sert/fuzz/overlay` using hardlinks."""
    root = Path(os.path.abspath(root))
    work = root / OVERLAY_REL
    shutil.rmtree(work, ignore_errors=True)
    work.mkdir(parents=True, exist_ok=True)
    sert_dir = root / ".sert"
    mutated_set = set(mutated_rels or ())

    skip_anywhere = mutate._SKIP_ANYWHERE
    skip_root = mutate._SKIP_ROOT_DIRS
    skip_in_sert = frozenset({"mutate", "fuzz", "bin", "cache"})
    allowed_suffixes = mutate._LUAU_OVERLAY_SUFFIXES

    try:
        for directory, dirs, files in os.walk(root):
            here = Path(directory)
            if here == root:
                dirs[:] = [
                    d
                    for d in dirs
                    if d not in skip_anywhere and d not in skip_root and not (d.startswith(".") and d != ".sert")
                ]
            elif here == sert_dir:
                dirs[:] = [d for d in dirs if d not in skip_in_sert and d not in skip_anywhere]
            else:
                dirs[:] = [d for d in dirs if d not in skip_anywhere]

            rel_dir = here.relative_to(root)
            for fname in files:
                if fname != ".luaurc" and not fname.endswith(allowed_suffixes):
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
                    mutate._link_file(src_file, dst_file)
        for rel_mut in mutated_set:
            (work / rel_mut).parent.mkdir(parents=True, exist_ok=True)
    except OSError as err:
        shutil.rmtree(work, ignore_errors=True)
        raise SertError(f"fuzz: cannot create zero-copy overlay in {work}: {err}") from err

    mutate.retarget_luaurc_aliases(root, work)
    _install_fuzz_runtime_alias(work)
    return work


def _install_fuzz_runtime_alias(work: Path) -> None:
    """Install `.sert/__fuzz_rt.luau` and wire `@__SERT_FUZZ` in overlay `.luaurc` files."""
    rt_dir = work / ".sert"
    rt_dir.mkdir(parents=True, exist_ok=True)
    rt_path = rt_dir / "__fuzz_rt.luau"
    rt_code = (
        "--!nonstrict\n"
        "local M: any = { ctrl = nil }\n"
        "function M.edge(id: number)\n"
        "\tlocal c = M.ctrl\n"
        "\tif c ~= nil then c.edge(id) end\n"
        "end\n"
        "function M.cmp(id: number, op: string, a: any, b: any): boolean\n"
        "\tlocal c = M.ctrl\n"
        "\tif c ~= nil then return c.cmp(id, op, a, b) end\n"
        '\tif op == "==" then return a == b\n'
        '\telseif op == "~=" then return a ~= b\n'
        '\telseif op == "<" then return a < b\n'
        '\telseif op == "<=" then return a <= b\n'
        '\telseif op == ">" then return a > b\n'
        '\telseif op == ">=" then return a >= b\n'
        "\tend\n"
        "\treturn false\n"
        "end\n"
        "return M\n"
    )
    mutate._write_unlinked(rt_path, rt_code)
    rt_target = str((rt_dir / "__fuzz_rt").resolve())
    root_luaurc = work / ".luaurc"
    if not root_luaurc.exists():
        mutate._write_unlinked(root_luaurc, json.dumps({"aliases": {"__SERT_FUZZ": rt_target}}, indent=2) + "\n")
    for directory, dirs, files in os.walk(work):
        dirs[:] = [name for name in dirs if name not in mutate._SKIP_ANYWHERE]
        if ".luaurc" not in files:
            continue
        rc_path = Path(directory) / ".luaurc"
        if rc_path.is_symlink():
            continue
        try:
            data = json.loads(strip_jsonc(rc_path.read_text(encoding="utf-8-sig")))
        except (OSError, ValueError):
            continue
        if not isinstance(data, dict):
            continue
        aliases = data.get("aliases")
        if not isinstance(aliases, dict):
            aliases = {}
        if aliases.get("__SERT_FUZZ") != rt_target:
            aliases["__SERT_FUZZ"] = rt_target
            data["aliases"] = aliases
            mutate._write_unlinked(rc_path, json.dumps(data, indent=2) + "\n")


def _load_extra_dict(dict_path: Path) -> tuple[list[str], list[int | float]]:
    if not dict_path.is_file():
        raise SertError(f"fuzz: --dict file not found: {dict_path}")
    text = dict_path.read_text(encoding="utf-8", errors="replace")
    strings: list[str] = []
    numbers: list[int | float] = []
    try:
        raw = json.loads(text)
    except ValueError:
        for line in text.splitlines():
            s = line.strip()
            if not s or s.startswith("#"):
                continue
            num = _parse_luau_number(s)
            if num is not None:
                numbers.append(num)
            elif 1 <= len(s) <= 64:
                strings.append(s)
        return strings, numbers

    if isinstance(raw, dict):
        for s in raw.get("strings", ()):
            if isinstance(s, str) and s:
                strings.append(s)
        for n in raw.get("numbers", ()):
            if isinstance(n, (int, float)) and not isinstance(n, bool):
                numbers.append(n)
    elif isinstance(raw, list):
        for item in raw:
            if isinstance(item, str) and item:
                strings.append(item)
            elif isinstance(item, (int, float)) and not isinstance(item, bool):
                numbers.append(item)
    return strings, numbers


def _prop_slug(name: str) -> str:
    slug = re.sub(r"[^A-Za-z0-9._-]+", "_", name).strip("_.")
    digest = hashlib.sha256(name.encode("utf-8")).hexdigest()[:8]
    return f"{slug[:40] or 'prop'}_{digest}"


def _load_corpus(corpus_dir: Path) -> dict[str, list[dict[str, Any]]]:
    """Load saved interesting seeds from `corpus_dir/<prop>/*.json|*.tok` keyed by property name."""
    out: dict[str, list[dict[str, Any]]] = {}
    if not corpus_dir.is_dir():
        return out
    for entry in sorted(corpus_dir.rglob("*")):
        if not entry.is_file():
            continue
        if entry.suffix == ".json":
            try:
                data = json.loads(entry.read_text(encoding="utf-8"))
            except (OSError, ValueError):
                continue
            if not isinstance(data, dict):
                continue
            prop_name = str(data.get("prop") or "").strip()
            tok = str(data.get("token") or "").strip()
            decoded = decode_tape_token(tok)
            if prop_name and decoded is not None:
                seed, size, tape = decoded
                out.setdefault(prop_name, []).append({"seed": seed, "size": size, "tape": tape, "token": tok})
        elif entry.suffix == ".tok":
            try:
                lines = entry.read_text(encoding="utf-8").splitlines()
            except OSError:
                continue
            for line in lines:
                tok = line.strip()
                decoded = decode_tape_token(tok)
                if decoded is not None:
                    seed, size, tape = decoded
                    out.setdefault(entry.parent.name, []).append({"seed": seed, "size": size, "tape": tape, "token": tok})
    return out


def _save_corpus_seed(corpus_dir: Path, prop_name: str, token: str, *, edges: int, file_rel: str) -> Path:
    slug = _prop_slug(prop_name)
    prop_dir = corpus_dir / slug
    prop_dir.mkdir(parents=True, exist_ok=True)
    digest = hashlib.sha256(token.encode("utf-8")).hexdigest()[:16]
    seed_path = prop_dir / f"{digest}.json"
    if not seed_path.exists():
        payload = {"prop": prop_name, "file": file_rel, "token": token, "edges": edges}
        write_atomic(seed_path, (json.dumps(payload, sort_keys=True) + "\n").encode("utf-8"))
    return seed_path


def _resolve_fuzz_specs(cfg: config_mod.Config, args) -> tuple[list[str], list[str], list[str]]:
    """Return `(spec_rels, entry_rels, setup_rels)` to execute under the fuzz driver."""
    explicit_specs = [str(s) for s in (getattr(args, "specs", None) or []) if str(s).strip()]
    file_args = [str(f) for f in (getattr(args, "file", None) or []) if str(f).strip()]
    all_discovered = graph.discover_specs(cfg.root, cfg)

    entries = run_mod.resolve_entries(cfg)
    setup_rels: list[str] = []
    if setup_cfg := cfg.get("test.setup"):
        setup_path = cfg.root / str(setup_cfg)
        if not setup_path.is_file():
            raise SertError(f"[test].setup: {setup_cfg} not found")
        setup_rels.append(posix(setup_path, cfg.root))

    if explicit_specs:
        expanded: list[str] = []
        for pat in explicit_specs:
            p = cfg.root / pat
            if not has_glob(pat) and p.is_dir():
                expanded.append(pat.rstrip("/") + "/**/*.spec.luau")
            elif not has_glob(pat) and not p.is_file():
                raise SertError(f"fuzz: spec file not found: {pat}")
            else:
                expanded.append(pat)
        spec_rels = sorted({posix(p, cfg.root) for p in expand_globs(cfg.root, expanded, files=True)})
        if not spec_rels:
            raise SertError(f"fuzz: no spec files matched {', '.join(explicit_specs)}")
        for cfg_rel in run_mod.discover_directory_configs(cfg.root, spec_rels):
            if cfg_rel not in setup_rels:
                setup_rels.append(cfg_rel)
        return spec_rels, [], setup_rels

    if all_discovered:
        for cfg_rel in run_mod.discover_directory_configs(cfg.root, all_discovered):
            if cfg_rel not in setup_rels:
                setup_rels.append(cfg_rel)
        return sorted(all_discovered), [], setup_rels

    # Fall back to configured non-runner entries (`[test].entries = ["test/spec.client.luau"]`)
    usable_entries = [e for e in entries if e != ".sert/run.luau" and (cfg.root / e).is_file()]
    if not usable_entries:
        raise SertError("fuzz: no spec files or test entries found")
    return [], usable_entries, setup_rels


def _luau_number_literal(n: int | float) -> str:
    if isinstance(n, int):
        return str(n)
    return repr(float(n))


def _norm_spec_key(path: str) -> str:
    clean = path.strip().lstrip("@=")
    clean = clean.replace("\\", "/")
    if clean.startswith("./"):
        clean = clean[2:]
    clean = re.sub(r"\.luau?$", "", clean)
    clean = re.sub(r"\.spec$", "", clean)
    return clean.lower()


def _normalize_greps(grep: str | list[str] | tuple[str, ...] | None) -> list[str]:
    if not grep:
        return []
    if isinstance(grep, str):
        return [grep]
    return [str(g) for g in grep if str(g)]


def _estimate_prop_count(
    root: Path,
    rels: list[str],
    *,
    files: list[str],
    filt: str | None,
    grep: str | list[str] | tuple[str, ...] | None,
) -> int:
    greps = _normalize_greps(grep)
    wanted = [_norm_spec_key(f) for f in files if f.strip()]
    matched_rels: list[str] = []
    for rel in rels:
        if not wanted:
            matched_rels.append(rel)
            continue
        norm = _norm_spec_key(rel)
        base = norm.rsplit("/", 1)[-1]
        if any(norm == w or base == w or norm.endswith("/" + w) for w in wanted):
            matched_rels.append(rel)
    prop_variants = frozenset({"prop", "roblox", "server", "client", "focus"})
    count = 0
    for rel in matched_rels:
        p = root / rel
        if not p.is_file():
            continue
        try:
            tokens = luau_lex.tokenize(p.read_text(encoding="utf-8", errors="replace"))
        except OSError:
            continue
        for idx, tok in enumerate(tokens):
            if tok.kind != "IDENT" or tok.value != "prop":
                continue
            j = idx + 1
            while (
                j + 1 < len(tokens)
                and tokens[j].kind == "OP"
                and tokens[j].value == "."
                and tokens[j + 1].kind == "IDENT"
                and tokens[j + 1].value in prop_variants
            ):
                j += 2
            if j >= len(tokens) or tokens[j].kind != "OP" or tokens[j].value != "(":
                continue
            name_val: str | None = None
            if j + 1 < len(tokens) and tokens[j + 1].kind == "STRING":
                name_val = luau_lex.unquote_string(tokens[j + 1].value)
            if name_val is not None:
                if filt and filt.lower() not in name_val.lower():
                    continue
                if greps:
                    matched_any = False
                    for gpat in greps:
                        try:
                            lua_pat = re.sub(
                                r"%([a-zA-Z])",
                                lambda m: "\\" + m.group(1).lower() if m.group(1) in "dsSwW" else m.group(1),
                                gpat,
                            )
                            if gpat.lower() in name_val.lower() or re.search(lua_pat, name_val) is not None:
                                matched_any = True
                                break
                        except re.error:
                            if gpat.lower() in name_val.lower():
                                matched_any = True
                                break
                    if not matched_any:
                        continue
            count += 1
    return max(1, count)


def _render_fuzz_config(
    *,
    seed: int,
    budget_sec: float,
    max_runs: int | None,
    prop_count_hint: int,
    filt: str | None,
    grep: str | list[str] | tuple[str, ...] | None,
    files: list[str],
    dict_strings: list[str],
    dict_numbers: list[int | float],
    corpus_by_prop: dict[str, list[dict[str, Any]]],
    regressions_by_test: dict[str, list[str]],
    setup_requires: list[tuple[str, str]],
    spec_requires: list[tuple[str, str]],
    entry_requires: list[tuple[str, str]],
) -> str:
    greps = _normalize_greps(grep)
    lines = ["--!nonstrict", "-- Auto-generated by `sert fuzz`; do not edit.", "return {"]
    lines.append(f"\tseed = {seed},")
    lines.append(f"\tbudget = {budget_sec:.6f},")
    lines.append(f"\tmaxRuns = {str(max_runs) if max_runs is not None else 'nil'},")
    lines.append(f"\tpropCountHint = {max(1, int(prop_count_hint))},")
    lines.append(f"\tfilter = {luau_string(filt) if filt else 'nil'},")
    lines.append(f"\tgrep = {luau_string(greps[0]) if len(greps) == 1 else 'nil'},")
    lines.append("\tgreps = { " + ", ".join(luau_string(g) for g in greps) + " },")
    lines.append("\tfiles = { " + ", ".join(luau_string(f) for f in files) + " },")
    lines.append("\tdictStrings = { " + ", ".join(luau_string(s) for s in dict_strings) + " },")
    lines.append("\tdictNumbers = { " + ", ".join(_luau_number_literal(n) for n in dict_numbers) + " },")

    lines.append("\tcorpus = {")
    for prop_name, seeds in sorted(corpus_by_prop.items()):
        lines.append(f"\t\t[{luau_string(prop_name)}] = {{")
        for s_item in seeds:
            tape_lit = ", ".join(str(v) for v in s_item["tape"])
            lines.append(f"\t\t\t{{ seed = {s_item['seed']}, size = {s_item['size']}, tape = {{ {tape_lit} }} }},")
        lines.append("\t\t},")
    lines.append("\t},")

    lines.append("\tregressions = {")
    for test_name, toks in sorted(regressions_by_test.items()):
        lines.append(f"\t\t[{luau_string(test_name)}] = {{ " + ", ".join(luau_string(t) for t in toks) + " },")
    lines.append("\t},")

    lines.append("\tsetups = {")
    for rel, req_target in setup_requires:
        lines.append(f"\t\t{{ file = {luau_string(rel)}, load = function() return require({luau_string(req_target)}) end }},")
    lines.append("\t},")

    lines.append("\tspecs = {")
    for rel, req_target in spec_requires:
        lines.append(f"\t\t{{ file = {luau_string(rel)}, load = function() return require({luau_string(req_target)}) end }},")
    lines.append("\t},")

    lines.append("\tentries = {")
    for rel, req_target in entry_requires:
        lines.append(f"\t\t{{ file = {luau_string(rel)}, load = function() return require({luau_string(req_target)}) end }},")
    lines.append("\t},")

    lines.append("}")
    return "\n".join(lines) + "\n"


def _render_fuzz_driver(sert_require_target: str, datatypes_require_target: str | None, roblox_globals: bool) -> str:
    dt_lines = []
    if roblox_globals and datatypes_require_target:
        dt_lines.append(f"local _dt: any = require({luau_string(datatypes_require_target)})")
        dt_lines.append('if type(_dt) == "table" and type(_dt.installGlobals) == "function" then _dt.installGlobals() end')
    dt_block = "\n".join(dt_lines)
    fuzz_mod_target = f"{sert_require_target.rstrip('/')}/prop/fuzz"
    lines = [
        "--!nonstrict",
        "-- Auto-generated greybox evolutionary fuzzing bootstrap (`sert fuzz`).",
    ]
    if dt_block:
        lines.append(dt_block)
    lines.extend(
        [
            'local cfg: any = require("./fuzz_config")',
            f"local sert: any = require({luau_string(sert_require_target)})",
            f"local fuzzDriver: any = require({luau_string(fuzz_mod_target)})",
            "fuzzDriver.run(cfg, sert)",
        ]
    )
    return "\n".join(lines) + "\n"


def add_parser(subparsers) -> None:
    parser = subparsers.add_parser("fuzz")
    parser.add_argument("specs", nargs="*", help="optional spec files or directories to fuzz")
    parser.add_argument("--filter", metavar="SUBSTR", help="only run properties whose name contains SUBSTR or matches Lua pattern")
    parser.add_argument("-g", "--grep", action="append", default=[], metavar="PAT", help="only run properties matching Luau pattern PAT (repeatable)")
    parser.add_argument("--file", action="append", default=[], metavar="FILE", help="restrict fuzzing to specs matching FILE")
    parser.add_argument("--budget", type=float, default=5.0, metavar="SEC", help="total wall-clock fuzzing budget in seconds (default: 5.0)")
    parser.add_argument("--runs", type=int, default=None, metavar="N", help="fixed trial count per property instead of time budget")
    parser.add_argument("--seed", type=int, default=None, metavar="N", help="PRNG seed for deterministic fuzzing")
    parser.add_argument("--dict", metavar="FILE", help="additional dictionary file (JSON or line-separated tokens)")
    parser.add_argument("--corpus", metavar="DIR", help=f"corpus directory (default: {CORPUS_DEFAULT_REL.as_posix()})")
    parser.add_argument("--no-save-regressions", action="store_true", help="do not save failing replay tokens into test/.sert-regressions.toml")
    if not any("--agent" in action.option_strings for action in parser._actions):
        parser.add_argument("--agent", action="store_true", help="emit concise agent-friendly output")
    if not any("--format" in action.option_strings for action in parser._actions):
        parser.add_argument("--format", choices=("human", "agent", "json"), help="output format (human, agent, or json)")
    parser.set_defaults(func=main)


def main(args) -> int:
    fmt = agent.output_format(args)
    cfg = config_mod.from_args(args)
    fetch.refresh_overrides(cfg)
    fetch.ensure_fetched(cfg)

    budget_sec = float(args.budget if getattr(args, "budget", None) is not None else 5.0)
    if budget_sec <= 0:
        raise SertError("fuzz: --budget must be > 0")
    max_runs = getattr(args, "runs", None)
    if max_runs is not None and int(max_runs) < 1:
        raise SertError("fuzz: --runs must be >= 1")
    seed = int(args.seed) if getattr(args, "seed", None) is not None else 0x5EED

    corpus_arg = getattr(args, "corpus", None)
    corpus_dir = (cfg.root / corpus_arg) if corpus_arg else (cfg.root / CORPUS_DEFAULT_REL)
    corpus_dir = Path(os.path.abspath(corpus_dir))
    save_regressions = not bool(getattr(args, "no_save_regressions", False))

    stage_spec = cfg.get("test.stage")
    if stage_spec:
        run_mod.stage_project(cfg, str(stage_spec))
    spec_rels, entry_rels, setup_rels = _resolve_fuzz_specs(cfg, args)

    luau_bin = run_mod.luau_command(cfg.root, "luau")
    if os.sep in luau_bin or (os.altsep and os.altsep in luau_bin):
        luau_bin = os.path.abspath(luau_bin)

    target_files = _collect_target_files(cfg)
    dict_strings: list[str] = []
    dict_numbers: list[int | float] = []
    seen_strings: set[str] = set()
    seen_numbers: set[tuple[str, str]] = set()

    def add_dict_items(strs: list[str], nums: list[int | float]) -> None:
        for s in strs:
            if s not in seen_strings:
                seen_strings.add(s)
                dict_strings.append(s)
        for n in nums:
            nk = (type(n).__name__, repr(n))
            if nk not in seen_numbers:
                seen_numbers.add(nk)
                dict_numbers.append(n)

    if dict_arg := getattr(args, "dict", None):
        extra_path = Path(dict_arg) if Path(dict_arg).is_absolute() else (cfg.root / str(dict_arg))
        d_strs, d_nums = _load_extra_dict(extra_path)
        add_dict_items(d_strs, d_nums)

    # Instrument target files in memory first, validating against Luau compiler
    instrumented_by_rel: dict[str, str] = {}
    edge_id = 1
    cmp_id = 1
    total_edges_inst = 0
    total_cmps_inst = 0
    with tempfile.TemporaryDirectory(prefix="sert-fuzz-chk-") as tmp_chk:
        chk_dir = Path(tmp_chk)
        for rel in target_files:
            orig_src = (cfg.root / rel).read_text(encoding="utf-8", errors="replace")
            inst_src, meta = instrument_and_validate(
                luau_bin,
                orig_src,
                file_path=rel,
                start_edge_id=edge_id,
                start_cmp_id=cmp_id,
                check_dir=chk_dir,
            )
            edge_id = int(meta["next_edge_id"])
            cmp_id = int(meta["next_cmp_id"])
            total_edges_inst += int(meta["edges"])
            total_cmps_inst += int(meta["cmps"])
            add_dict_items(list(meta["strings"]), list(meta["numbers"]))
            instrumented_by_rel[rel] = inst_src

    # Persist extracted dictionary
    dict_path = cfg.root / DICT_REL
    dict_path.parent.mkdir(parents=True, exist_ok=True)
    write_atomic(
        dict_path,
        (json.dumps({"strings": dict_strings, "numbers": dict_numbers}, indent=2) + "\n").encode("utf-8"),
    )

    overlay_skip_rels = set(instrumented_by_rel)
    if stage_spec:
        overlay_skip_rels.update(f".sert/stage/lexical/{rel}" for rel in instrumented_by_rel)
    work_root = build_fuzz_overlay(cfg.root, overlay_skip_rels)
    try:
        for rel, inst_src in instrumented_by_rel.items():
            dst = mutate._guard_inside(work_root, work_root / rel)
            mutate._write_unlinked(dst, inst_src)
            if stage_spec:
                staged_dst = mutate._guard_inside(work_root, work_root / ".sert" / "stage" / "lexical" / rel)
                wrapped = mutate.wrap_staged_source(inst_src)
                mutate._write_unlinked(staged_dst, wrapped)
        mutate.retarget_luaurc_aliases(cfg.root, work_root)
        run_mod._sync_sert_luaurc(work_root, include_game=(work_root / ".sert" / "stage" / "game").is_dir())

        roblox_globals = str(cfg.get("test.globals", "")).lower() == "roblox"
        codegen = bool(cfg.get("test.codegen", True))
        sert_target = run_mod._sert_require_target(work_root)
        dt_target = run_mod._sert_datatypes_require_target(work_root) if roblox_globals else None

        setup_reqs = [(rel, run_mod.stage_zero_return_luau(work_root, rel)) for rel in setup_rels]
        spec_reqs = [(rel, run_mod.stage_zero_return_luau(work_root, rel)) for rel in spec_rels]
        entry_reqs = [(rel, run_mod.stage_zero_return_luau(work_root, rel)) for rel in entry_rels]

        corpus_by_prop = _load_corpus(corpus_dir)
        regressions_by_test = load_regressions_toml(cfg.root)
        file_filters = [str(f) for f in (getattr(args, "file", None) or ())]
        filt_arg = getattr(args, "filter", None)
        grep_arg = getattr(args, "grep", None)
        prop_count_hint = _estimate_prop_count(
            cfg.root,
            spec_rels + entry_rels,
            files=file_filters,
            filt=filt_arg,
            grep=grep_arg,
        )

        fuzz_cfg_luau = _render_fuzz_config(
            seed=seed,
            budget_sec=budget_sec,
            max_runs=int(max_runs) if max_runs is not None else None,
            prop_count_hint=prop_count_hint,
            filt=filt_arg,
            grep=grep_arg,
            files=file_filters,
            dict_strings=dict_strings,
            dict_numbers=dict_numbers,
            corpus_by_prop=corpus_by_prop,
            regressions_by_test=regressions_by_test,
            setup_requires=setup_reqs,
            spec_requires=spec_reqs,
            entry_requires=entry_reqs,
        )
        driver_luau = _render_fuzz_driver(sert_target, dt_target, roblox_globals)

        driver_dir = work_root / ".sert"
        driver_dir.mkdir(parents=True, exist_ok=True)
        (driver_dir / "fuzz_config.luau").write_text(fuzz_cfg_luau, encoding="utf-8")
        driver_path = driver_dir / "fuzz_driver.luau"
        driver_path.write_text(driver_luau, encoding="utf-8")

        cmd = run_mod.entry_command("luau", luau_bin, ".sert/fuzz_driver.luau", [], coverage=False, codegen=codegen)
        proc_timeout = max(budget_sec + 30.0, 30.0)
        try:
            proc = subprocess.run(cmd, cwd=work_root, capture_output=True, text=True, timeout=proc_timeout)
        except subprocess.TimeoutExpired as exc:
            raise SertError(f"fuzz: timed out after {proc_timeout:g}s") from exc

        failures: list[dict[str, Any]] = []
        saved_tokens: list[str] = []
        new_corpus_count = 0
        done_stats: dict[str, Any] = {}
        errors: list[str] = []

        for line in (proc.stdout or "").splitlines():
            sline = line.strip()
            if not sline.startswith("[sert-fuzz] "):
                continue
            try:
                ev = json.loads(sline[len("[sert-fuzz] ") :])
            except ValueError:
                continue
            if not isinstance(ev, dict):
                continue
            kind = ev.get("event")
            if kind == "corpus":
                tok = str(ev.get("token") or "")
                prop_name = str(ev.get("prop") or "property")
                file_rel = str(ev.get("file") or "")
                edges_seen = int(ev.get("edges") or 0)
                if tok:
                    _save_corpus_seed(corpus_dir, prop_name, tok, edges=edges_seen, file_rel=file_rel)
                    new_corpus_count += 1
            elif kind == "failure":
                tok = str(ev.get("token") or "")
                prop_name = str(ev.get("name") or "(property)")
                file_rel = str(ev.get("file") or "")
                failures.append(
                    {
                        "name": prop_name,
                        "file": file_rel,
                        "line": ev.get("line"),
                        "message": str(ev.get("message") or ""),
                        "counterexample": ev.get("counterexample"),
                        "replay": tok,
                        "seed": ev.get("seed"),
                    }
                )
                if save_regressions and tok:
                    if save_regression_token(cfg.root, prop_name, file_rel, tok):
                        saved_tokens.append(tok)
                    elif tok not in saved_tokens:
                        saved_tokens.append(tok)
            elif kind == "error":
                errors.append(str(ev.get("message") or "fuzz error"))
            elif kind == "done":
                done_stats = ev

        if proc.returncode != 0 and not done_stats:
            detail = (proc.stderr or proc.stdout or "").strip()
            raise SertError(f"fuzz: Luau fuzz driver failed (exit {proc.returncode})" + (f"\n{detail[-2000:]}" if detail else ""))

    finally:
        shutil.rmtree(work_root, ignore_errors=True)

    iterations = int(done_stats.get("iterations", 0) or 0)
    passed = int(done_stats.get("passed", 0) or 0)
    failed = int(done_stats.get("failed", len(failures) + len(errors)) or 0)
    edges_covered = int(done_stats.get("edges", 0) or 0)
    best_cmp = int(done_stats.get("bestCmp", 0) or 0)
    has_failure = failed > 0 or bool(failures) or bool(errors)
    exit_code = FAILED if has_failure else 0

    report: dict[str, Any] = {
        "iterations": iterations,
        "runs": iterations,
        "passed": passed,
        "failed": failed,
        "seed": seed,
        "edges_covered": edges_covered,
        "edges_total": total_edges_inst,
        "comparisons_total": total_cmps_inst,
        "best_cmp_improvements": best_cmp,
        "corpus_new": new_corpus_count,
        "failures": failures,
        "regressions": saved_tokens,
        "errors": errors,
    }

    if fmt == "agent":
        print(agent.format_fuzz_agent(report, root=cfg.root))
    elif fmt == "json":
        payload = agent.json_envelope(
            "fuzz",
            "failed" if has_failure else "ok",
            summary={
                "iterations": iterations,
                "passed": passed,
                "failed": failed,
                "seed": seed,
                "edges_covered": edges_covered,
                "edges_total": total_edges_inst,
                "corpus_new": new_corpus_count,
                "regressions_saved": len(saved_tokens),
            },
            errors=errors,
            data={
                "failures": failures,
                "regressions": saved_tokens,
                "dict": {"strings": len(dict_strings), "numbers": len(dict_numbers)},
            },
            exit_code=exit_code,
        )
        print(agent.json_dumps_compact(payload))
    else:
        status_word = "FAIL" if has_failure else "OK"
        print(
            f"fuzz: {status_word} iterations={iterations} passed={passed} failed={failed} "
            f"edges={edges_covered}/{total_edges_inst} corpus_new={new_corpus_count} seed={seed}"
        )
        for fail in failures:
            print(f"  FAIL {fail['name']} ({fail.get('file') or 'spec'}): {fail['message']}")
            if fail.get("counterexample") is not None:
                print(f"    counterexample: {fail['counterexample']}")
            if fail.get("replay"):
                print(f"    replay: {fail['replay']}")
        for err_msg in errors:
            print(f"  ERROR {err_msg}", file=sys.stderr)

    return exit_code


cmd_fuzz = main
