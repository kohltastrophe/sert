"""Inline and `.snap` file snapshot readers and source-patching updaters."""

from __future__ import annotations

from pathlib import Path
import re

from sert import coverage as coverage_mod
from sert import luau_lex
from sert.util import luau_string, posix, write_atomic

_CONTROL_RE = re.compile(r"[\x00-\x08\x0b-\x1f\x7f]")
_SPEC_SUFFIX_RE = re.compile(r"(?:\.spec)?\.luau?$|\.spec$", re.IGNORECASE)


def format_luau_snapshot_literal(actual: str) -> str:
    """Serialize *actual* as a valid Luau string literal that round-trips losslessly.

    Multi-line strings (and strings starting with ``\\n``) without ``\\r`` or
    control characters use ``[=[\\n...]=]`` with the minimum ``k >= 0`` equal
    signs so ``]={k}]`` cannot close prematurely, prepending ``\\n`` because
    Luau's lexer discards a single leading newline immediately after ``[=[``.
    """
    if "\r" in actual or _CONTROL_RE.search(actual):
        return luau_string(actual)
    if "\n" not in actual:
        return luau_string(actual)

    eq_count = 0
    while True:
        eqs = "=" * eq_count
        closer = f"]{eqs}]"
        # Adding closer[:-1] catches both internal `]={k}]` and trailing `]={k}`.
        if closer not in (actual + closer[:-1]):
            return f"[{eqs}[\n{actual}{closer}"
        eq_count += 1


def _decode_luau_string_token(raw: str) -> str:
    decoded = luau_lex.unquote_string(raw)
    return raw if decoded is None else decoded


def _clean_path(raw: str) -> str:
    text = str(raw).strip().replace("\\", "/")
    while text.startswith(("@", "=")):
        text = text[1:]
    for prefix in ("./", "../", ".sert/fuzz/overlay/", "stage/lexical/", "stage/files/", "stage/specs/", "self/lexical/", "self/files/"):
        while text.startswith(prefix):
            text = text[len(prefix) :]
    return text


def _resolve_root_file(root: Path, raw_file: str, *, glob_tail: bool = True) -> Path | None:
    cleaned = _clean_path(raw_file)
    if not cleaned:
        return None
    root_resolved = root.resolve()

    def _safe(candidate: Path) -> Path | None:
        try:
            resolved = candidate.resolve()
        except OSError:
            return None
        if not resolved.is_relative_to(root_resolved):
            return None
        return resolved if resolved.is_file() else None

    raw_path = Path(cleaned)
    if raw_path.is_absolute():
        hit = _safe(raw_path)
        if hit is not None:
            return hit
        try:
            cleaned = posix(raw_path.resolve(), root_resolved)
        except ValueError:
            return None

    normed = coverage_mod.norm(cleaned, root_resolved)
    candidates = [normed] if normed else []
    if cleaned and cleaned not in candidates:
        candidates.append(cleaned)

    for rel in candidates:
        for variant in (
            rel,
            f"{rel}.luau",
            f"{rel}.lua",
            f"{rel}.spec.luau",
            f"test/{rel}",
            f"test/{rel}.luau",
            f"test/{rel}.spec.luau",
        ):
            hit = _safe(root_resolved / variant)
            if hit is not None:
                return hit

    if glob_tail and normed:
        tail = normed.rsplit("/", 1)[-1]
        for suffix in ("", ".luau", ".lua", ".spec.luau"):
            pattern = f"**/{tail}{suffix}"
            matches = [m for m in sorted(root_resolved.glob(pattern)) if ".sert/" not in posix(m, root_resolved)]
            if len(matches) == 1 and (hit := _safe(matches[0])) is not None:
                return hit
    return None


def _is_function_decl(tokens: list[luau_lex.Token], ident_idx: int) -> bool:
    idx = ident_idx - 1
    while idx >= 1 and tokens[idx].kind == "OP" and tokens[idx].value in (".", ":"):
        if tokens[idx - 1].kind != "IDENT":
            return False
        idx -= 2
    return idx >= 0 and tokens[idx].kind == "KEYWORD" and tokens[idx].value == "function"


def _find_lparen(tokens: list[luau_lex.Token], ident_idx: int) -> int | None:
    idx = ident_idx + 1
    n = len(tokens)
    if idx < n and tokens[idx].is_type_angle and tokens[idx].value == "<":
        depth = 1
        idx += 1
        while idx < n and depth > 0:
            tok = tokens[idx]
            if tok.is_type_angle:
                if tok.value == "<":
                    depth += 1
                elif tok.value in (">", ">>", ">>>"):
                    depth -= len(tok.value)
            idx += 1
    if idx < n and tokens[idx].kind == "OP" and tokens[idx].value == "(":
        return idx
    return None


def _scan_call_args(tokens: list[luau_lex.Token], lparen_idx: int) -> tuple[list[tuple[int, int]], int] | None:
    """Return ``(args_token_ranges, rparen_idx)`` for a call starting at *lparen_idx*."""
    n = len(tokens)
    depth = 0
    angle_depth = 0
    args: list[tuple[int, int]] = []
    arg_start: int | None = None
    idx = lparen_idx + 1

    while idx < n:
        tok = tokens[idx]
        if depth == 0 and angle_depth == 0:
            if tok.kind == "OP" and tok.value == ")":
                if arg_start is not None:
                    args.append((arg_start, idx - 1))
                return args, idx
            if tok.kind == "OP" and tok.value == ",":
                if arg_start is not None:
                    args.append((arg_start, idx - 1))
                    arg_start = None
                idx += 1
                continue
            if arg_start is None:
                arg_start = idx

        if tok.kind == "INTERP_BEGIN" or (tok.kind == "OP" and tok.value in ("(", "[", "{")):
            depth += 1
        elif tok.kind == "INTERP_END" or (tok.kind == "OP" and tok.value in (")", "]", "}")):
            if depth > 0:
                depth -= 1
        elif tok.is_type_angle:
            if tok.value == "<":
                angle_depth += 1
            elif angle_depth > 0 and tok.value in (">", ">>", ">>>"):
                angle_depth = max(0, angle_depth - len(tok.value))

        idx += 1
    return None


def _inline_calls_by_line(tokens: list[luau_lex.Token]) -> dict[int, list[tuple[int, int, list[tuple[int, int]]]]]:
    """Map line -> list of ``(ident_idx, lparen_idx, args)`` for ``inlineSnapshot(...)`` calls."""
    by_line: dict[int, list[tuple[int, int, list[tuple[int, int]]]]] = {}
    for idx, tok in enumerate(tokens):
        if tok.kind != "IDENT" or tok.value != "inlineSnapshot":
            continue
        if _is_function_decl(tokens, idx):
            continue
        lparen_idx = _find_lparen(tokens, idx)
        if lparen_idx is None:
            continue
        scanned = _scan_call_args(tokens, lparen_idx)
        if scanned is None:
            continue
        args, _rparen_idx = scanned
        by_line.setdefault(tok.line, []).append((idx, lparen_idx, args))
    return by_line


def apply_inline_updates(root: Path, events: list[dict]) -> list[dict]:
    """Patch ``inlineSnapshot(...)`` calls in source files from runner snapshot events.

    Edits are deduplicated on ``(resolved_path, line, ordinal)`` and applied in
    descending byte-offset order per file so earlier edits stay aligned.
    """
    root = Path(root)
    grouped: dict[Path, dict[tuple[int, int], dict]] = {}
    for ev in events:
        if not isinstance(ev, dict) or ev.get("kind") != "inline":
            continue
        raw_file = ev.get("file")
        line = ev.get("line")
        ordinal = ev.get("ordinal", 1)
        if not isinstance(raw_file, str) or not isinstance(line, int) or not isinstance(ordinal, int):
            continue
        if line <= 0 or ordinal <= 0 or "actual" not in ev:
            continue
        target = _resolve_root_file(root, raw_file)
        if target is None:
            continue
        grouped.setdefault(target, {})[(line, ordinal)] = ev

    records: list[dict] = []
    for path in sorted(grouped):
        source = path.read_bytes().decode("utf-8", errors="replace")
        tokens = luau_lex.tokenize(source, include_comments=False)
        calls_by_line = _inline_calls_by_line(tokens)
        rel_file = posix(path, root.resolve())

        edits: list[tuple[int, int, str, dict]] = []
        for (line, ordinal), ev in grouped[path].items():
            line_calls = calls_by_line.get(line)
            if not line_calls or ordinal > len(line_calls):
                continue
            _ident_idx, _lparen_idx, args = line_calls[ordinal - 1]
            if not args:
                continue

            actual = str(ev["actual"])
            previous = ev.get("previous")
            literal = format_luau_snapshot_literal(actual)

            if len(args) == 1:
                insert_at = tokens[args[0][1]].end
                span = (insert_at, insert_at)
                replacement = f", {literal}"
                action = "created"
            else:
                arg2_start = tokens[args[1][0]].start
                arg2_end = tokens[args[1][1]].end
                span = (arg2_start, arg2_end)
                replacement = literal
                arg2_is_nil = args[1][0] == args[1][1] and tokens[args[1][0]].value == "nil"
                action = "created" if previous is None or arg2_is_nil else "updated"

            record = {
                "kind": "inline",
                "file": rel_file,
                "line": line,
                "key_or_ordinal": ordinal,
                "previous": previous,
                "actual": actual,
                "action": action,
            }
            edits.append((span[0], span[1], replacement, record))

        if not edits:
            continue

        # Sort descending by (start, end) so earlier character offsets remain untouched.
        edits.sort(key=lambda item: (item[0], item[1]), reverse=True)
        patched = source
        last_start = len(patched) + 1
        for start, end, replacement, record in edits:
            if end > last_start:
                continue
            patched = patched[:start] + replacement + patched[end:]
            last_start = start
            records.append(record)

        if patched != source:
            write_atomic(path, patched.encode("utf-8"))

    records.sort(key=lambda r: (r["file"], r["line"], r["key_or_ordinal"]))
    return records


def spec_stem(file_path: str, root: Path | None = None) -> str:
    """Normalize a spec path to a safe, deterministic stem under ``test/__snapshots__/``."""
    cleaned = _clean_path(file_path)
    if root is not None:
        resolved_root = Path(root).resolve()
        try:
            p = Path(cleaned)
            if p.is_absolute():
                cleaned = posix(p.resolve(), resolved_root)
        except (OSError, ValueError):
            pass
    normed = coverage_mod.norm(cleaned, root) or cleaned
    normed = _clean_path(normed)
    for prefix in ("test/", "tests/"):
        if normed.startswith(prefix):
            normed = normed[len(prefix) :]
            break
    normed = _SPEC_SUFFIX_RE.sub("", normed)
    parts = [part for part in normed.split("/") if part and part not in (".", "..")]
    return "/".join(parts) if parts else "default"


def snapshot_path_for(root: Path, file_path: str) -> Path:
    stem = spec_stem(file_path, root)
    return Path(root) / "test" / "__snapshots__" / f"{stem}.snap"


def _parse_snap_file(path: Path) -> dict[str, str]:
    text = path.read_bytes().decode("utf-8", errors="replace")
    tokens = luau_lex.tokenize(text, include_comments=False)
    entries: dict[str, str] = {}
    i = 0
    n = len(tokens)
    while i < n:
        tok = tokens[i]
        # `exports["key"] = <literal>` or `snapshot "key" = <literal>`
        if (
            tok.kind == "IDENT"
            and tok.value == "exports"
            and i + 5 < n
            and tokens[i + 1].kind == "OP"
            and tokens[i + 1].value == "["
            and tokens[i + 2].kind == "STRING"
            and tokens[i + 3].kind == "OP"
            and tokens[i + 3].value == "]"
            and tokens[i + 4].kind == "OP"
            and tokens[i + 4].value == "="
            and tokens[i + 5].kind == "STRING"
        ):
            key = _decode_luau_string_token(tokens[i + 2].value)
            val = _decode_luau_string_token(tokens[i + 5].value)
            entries[key] = val
            i += 6
            continue
        if (
            tok.kind == "IDENT"
            and tok.value == "snapshot"
            and i + 3 < n
            and tokens[i + 1].kind == "STRING"
            and tokens[i + 2].kind == "OP"
            and tokens[i + 2].value == "="
            and tokens[i + 3].kind == "STRING"
        ):
            key = _decode_luau_string_token(tokens[i + 1].value)
            val = _decode_luau_string_token(tokens[i + 3].value)
            entries[key] = val
            i += 4
            continue
        i += 1
    return entries


def _render_snap_file(entries: dict[str, str]) -> str:
    lines = ["-- sert snapshot v1", ""]
    for key in sorted(entries):
        key_lit = luau_string(key)
        val_lit = format_luau_snapshot_literal(entries[key])
        lines.append(f"exports[{key_lit}] = {val_lit}")
        lines.append("")
    return "\n".join(lines).rstrip() + "\n"


def load_file_snapshots(root: Path) -> dict[str, dict[str, str]]:
    """Load all ``test/__snapshots__/**/*.snap`` files keyed by spec stem."""
    root = Path(root)
    snap_root = root / "test" / "__snapshots__"
    if not snap_root.is_dir():
        return {}
    result: dict[str, dict[str, str]] = {}
    for snap_file in sorted(snap_root.rglob("*.snap")):
        if not snap_file.is_file():
            continue
        rel = posix(snap_file, snap_root)
        stem = rel[:-5] if rel.endswith(".snap") else rel
        result[stem] = _parse_snap_file(snap_file)
    return result


def apply_file_updates(
    root: Path,
    events: list[dict],
    prune: set[tuple[str, str]] | None = None,
) -> list[dict]:
    """Create, update, or prune ``test/__snapshots__/<spec_stem>.snap`` entries."""
    root = Path(root)
    existing = load_file_snapshots(root)
    updated: dict[str, dict[str, str]] = {stem: dict(entries) for stem, entries in existing.items()}
    records: list[dict] = []
    touched_stems: set[str] = set()

    for ev in events:
        if not isinstance(ev, dict) or ev.get("kind") != "file":
            continue
        raw_file = ev.get("file")
        key = ev.get("key")
        if not isinstance(raw_file, str) or not isinstance(key, str) or "actual" not in ev:
            continue
        stem = spec_stem(raw_file, root)
        bucket = updated.setdefault(stem, {})
        actual = str(ev["actual"])
        previous = bucket.get(key, ev.get("previous"))
        action = "created" if key not in bucket and ev.get("previous") is None else "updated"
        bucket[key] = actual
        touched_stems.add(stem)
        records.append(
            {
                "kind": "file",
                "file": stem,
                "line": ev.get("line", 0),
                "key_or_ordinal": key,
                "previous": previous,
                "actual": actual,
                "action": action,
            }
        )

    if prune:
        normalized_prune: set[tuple[str, str]] = set()
        for raw_spec, snap_key in prune:
            normalized_prune.add((raw_spec, snap_key))
            normalized_prune.add((spec_stem(raw_spec, root), snap_key))
        for stem in sorted(updated):
            bucket = updated[stem]
            for snap_key in sorted(list(bucket)):
                if (stem, snap_key) in normalized_prune:
                    prev_val = bucket.pop(snap_key)
                    touched_stems.add(stem)
                    records.append(
                        {
                            "kind": "file",
                            "file": stem,
                            "line": 0,
                            "key_or_ordinal": snap_key,
                            "previous": prev_val,
                            "actual": None,
                            "action": "pruned",
                        }
                    )

    snap_root = root / "test" / "__snapshots__"
    for stem in sorted(touched_stems):
        snap_file = snap_root / f"{stem}.snap"
        bucket = updated.get(stem, {})
        if not bucket:
            if snap_file.exists():
                snap_file.unlink()
            continue
        write_atomic(snap_file, _render_snap_file(bucket).encode("utf-8"))

    return records
