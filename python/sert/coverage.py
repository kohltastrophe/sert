"""`sert coverage [FILE] [--min N]`: summarize `luau --coverage` (LCOV) output.

Duplicate SF: records merge by union: a line is covered if any record hit it.
"""

from __future__ import annotations

import colorsys
import io
import json
import os
from pathlib import Path
import re
import subprocess
import sys

from sert import config as config_mod, luau_lex
from sert.util import FAILED, SertError, annotate, as_list, on_github_actions, step_summary, write_atomic

STAGE_PREFIXES = (
    ".sert/stage/lexical/",
    ".sert/stage/files/",
    ".sert/stage/specs/",
    ".sert/mutate/overlay/",
)
_DRIVE_RE = re.compile(r"^[a-zA-Z]:[\\/]")
_HUNK_RE = re.compile(r"^@@ -\d+(?:,\d+)? \+(\d+)(?:,(\d+))? @@")


def _uncovered_ranges(lines: dict[int, int] | dict[int, bool], max_ranges: int = 6) -> str:
    missed = sorted(ln for ln, hits in lines.items() if not hits)
    if not missed:
        return ""
    ranges: list[str] = []
    start = end = missed[0]
    for ln in missed[1:]:
        if ln == end + 1:
            end = ln
        else:
            ranges.append(f"L{start}" if start == end else f"L{start}-L{end}")
            start = end = ln
    ranges.append(f"L{start}" if start == end else f"L{start}-L{end}")
    if max_ranges and len(ranges) > max_ranges:
        return ", ".join(ranges[:max_ranges]) + ", ..."
    return ", ".join(ranges)


def git_diff_lines(root: Path, rev: str = "HEAD") -> dict[str, set[int]]:
    modified: dict[str, set[int]] = {}
    try:
        proc = subprocess.run(
            ["git", "-c", "diff.mnemonicPrefix=false", "diff", "-U0", rev],
            cwd=root,
            capture_output=True,
            text=True,
            encoding="utf-8",
            errors="replace",
            timeout=15,
        )
        if proc.returncode == 0:
            modified = parse_diff_lines(proc.stdout, root=root)
    except (OSError, subprocess.SubprocessError):
        pass

    # Include untracked `.luau` / `.lua` files so newly added modules are covered under `--diff`.
    try:
        untracked = subprocess.run(
            ["git", "ls-files", "--others", "--exclude-standard", "--", "*.luau", "*.lua"],
            cwd=root,
            capture_output=True,
            text=True,
            encoding="utf-8",
            errors="replace",
            timeout=15,
        )
        if untracked.returncode == 0:
            for raw in untracked.stdout.splitlines():
                rel = norm(raw.strip(), root)
                if not rel:
                    continue
                target = Path(root) / rel
                if target.is_file():
                    try:
                        count = len(target.read_text(encoding="utf-8", errors="replace").splitlines())
                    except OSError:
                        continue
                    if count > 0:
                        modified.setdefault(rel, set()).update(range(1, count + 1))
    except (OSError, subprocess.SubprocessError):
        pass

    return modified


def parse_diff_lines(diff_text: str, root: Path | None = None) -> dict[str, set[int]]:
    modified: dict[str, set[int]] = {}
    current_file: str | None = None
    for line in diff_text.splitlines():
        if line.startswith("+++ "):
            target = line[4:].strip()
            if target == "/dev/null":
                current_file = None
            else:
                current_file = norm(target.removeprefix("b/"), root)
        elif current_file is not None and (m := _HUNK_RE.match(line)):
            start = int(m.group(1))
            count = int(m.group(2)) if m.group(2) is not None else 1
            if count > 0:
                modified.setdefault(current_file, set()).update(range(start, start + count))
    return modified


def filter_diff_files(files: dict[str, dict[int, bool]], diff_lines: dict[str, set[int]]) -> dict[str, dict[int, bool]]:
    if not diff_lines:
        return {}
    filtered: dict[str, dict[int, bool]] = {}
    for name, lines in files.items():
        if name in diff_lines:
            sub = {ln: hit for ln, hit in lines.items() if ln in diff_lines[name]}
            if sub:
                filtered[name] = sub
    return filtered


_NON_EXEC_ONLY = frozenset({"end", "else", "do", "then", ")", "}", "]", ";", ","})


def _executable_lines(source: str) -> set[int]:
    tokens = luau_lex.tokenize(source, include_comments=False)
    in_type = luau_lex.mark_type_tokens(tokens)
    exec_lines: set[int] = set()
    for idx, tok in enumerate(tokens):
        if in_type[idx]:
            continue
        if tok.kind in ("KEYWORD", "OP") and tok.value in _NON_EXEC_ONLY:
            continue
        exec_lines.add(tok.line)
    return exec_lines


def inject_uncovered_diff_files(
    filtered: dict[str, dict[int, bool]],
    all_cov_files: dict[str, dict[int, bool]],
    diff_lines: dict[str, set[int]],
    root: Path,
    include: list[str],
    exclude: list[str] = (),
) -> None:
    excl = list(exclude)
    for rel, mod_lines in diff_lines.items():
        if rel in all_cov_files or not mod_lines or Path(rel).suffix not in (".luau", ".lua"):
            continue
        if not (included(rel, include) and not included(rel, excl)):
            continue
        target = root / rel
        if not target.is_file():
            continue
        try:
            source = target.read_text(encoding="utf-8", errors="replace")
        except OSError:
            continue
        exec_lns = _executable_lines(source)
        uncovered = sorted(ln for ln in mod_lines if ln in exec_lns)
        if uncovered:
            filtered[rel] = {ln: False for ln in uncovered}


def norm(name: str, root: Path | None = None, *, _resolved_root: Path | None = None) -> str:
    clean = name.replace("\\", "/")
    if (root is not None or _resolved_root is not None) and (
        clean.startswith("/") or _DRIVE_RE.match(clean) or os.path.isabs(name)
    ):
        try:
            resolved = Path(name).resolve()
            base = _resolved_root if _resolved_root is not None else Path(root).resolve()  # type: ignore[arg-type]
            if os.path.normcase(os.path.commonpath([resolved, base])) == os.path.normcase(str(base)):
                clean = os.path.relpath(resolved, base).replace(os.sep, "/")
        except (OSError, ValueError):
            pass
    elif (root is not None or _resolved_root is not None) and clean.startswith("../"):
        try:
            base = _resolved_root if _resolved_root is not None else Path(root).resolve()  # type: ignore[arg-type]
            resolved = (base / clean).resolve()
            if os.path.normcase(os.path.commonpath([resolved, base])) == os.path.normcase(str(base)):
                clean = os.path.relpath(resolved, base).replace(os.sep, "/")
            else:
                cand = clean
                while cand.startswith("../"):
                    cand = cand[3:]
                    if cand and (base / cand).is_file():
                        clean = cand
                        break
        except (OSError, ValueError):
            pass
    clean = clean.removeprefix("./")
    for prefix in STAGE_PREFIXES:
        if clean.startswith(prefix):
            clean = clean[len(prefix) :]
            if "__dot_" in clean:
                clean = "/".join(("." + p[len("__dot_") :]) if p.startswith("__dot_") else p for p in clean.split("/"))
            break
    return clean


def parse(path, root: Path | None = None) -> dict[str, dict[int, bool]]:
    files: dict[str, dict[int, bool]] = {}
    current = None
    current_max_line: int | None = None
    resolved_root = Path(root).resolve() if root is not None else None
    norm_cache: dict[str, tuple[str, int | None]] = {}
    with open(path, encoding="utf-8", errors="replace") as handle:
        for line in handle:
            if line.startswith("SF:"):
                raw_sf = line[3:].strip()
                cached = norm_cache.get(raw_sf)
                if cached is None:
                    norm_sf = norm(raw_sf, root, _resolved_root=resolved_root)
                    max_ln: int | None = None
                    if resolved_root is not None and any(p in raw_sf.replace("\\", "/") for p in STAGE_PREFIXES):
                        real_file = resolved_root / norm_sf
                        if real_file.is_file():
                            try:
                                max_ln = len(real_file.read_text(encoding="utf-8", errors="replace").splitlines())
                            except OSError:
                                max_ln = None
                    cached = (norm_sf, max_ln)
                    norm_cache[raw_sf] = cached
                norm_sf, current_max_line = cached
                current = files.setdefault(norm_sf, {})
            elif line.startswith("DA:") and current is not None:
                number, hits = line[3:].split(",")[:2]
                num = int(number)
                if current_max_line is not None and num > current_max_line:
                    continue
                current[num] = current.get(num, False) or int(hits) > 0
    return files


def parse_function_hits(path, root: Path | None = None) -> dict[str, dict[int, bool]]:
    """Parse LCOV ``FN:`` / ``FNDA:`` records into `{rel_file: {decl_line: called}}`."""
    files: dict[str, dict[int, bool]] = {}
    current_rel: str | None = None
    fn_lines: dict[str, int] = {}
    resolved_root = Path(root).resolve() if root is not None else None
    norm_cache: dict[str, str] = {}
    with open(path, encoding="utf-8", errors="replace") as handle:
        for line in handle:
            if line.startswith("SF:"):
                raw_sf = line[3:].strip()
                norm_sf = norm_cache.get(raw_sf)
                if norm_sf is None:
                    norm_sf = norm(raw_sf, root, _resolved_root=resolved_root)
                    norm_cache[raw_sf] = norm_sf
                current_rel = norm_sf
                fn_lines = {}
            elif line.startswith("end_of_record"):
                current_rel = None
                fn_lines = {}
            elif current_rel is None:
                continue
            elif line.startswith("FN:"):
                raw_ln, _, raw_name = line[3:].rstrip("\r\n").partition(",")
                if raw_name and raw_name != "<main>" and raw_ln.isdigit():
                    ln = int(raw_ln)
                    fn_lines[raw_name] = ln
                    files.setdefault(current_rel, {}).setdefault(ln, False)
            elif line.startswith("FNDA:"):
                raw_hits, _, raw_name = line[5:].rstrip("\r\n").partition(",")
                if raw_name and raw_name != "<main>":
                    hits = int(raw_hits) if raw_hits.isdigit() else 0
                    ln = fn_lines.get(raw_name)
                    if ln is None and ":" in raw_name:
                        tail = raw_name.rsplit(":", 1)[1]
                        if tail.isdigit():
                            ln = int(tail)
                    if ln is not None:
                        file_map = files.setdefault(current_rel, {})
                        file_map[ln] = file_map.get(ln, False) or hits > 0
    return files


def _matches_pattern(name: str, pattern: str) -> bool:
    clean_pat = pattern.rstrip("/")
    if not clean_pat:
        return False
    if "*" in clean_pat or "?" in clean_pat or "[" in clean_pat:
        # Support glob patterns such as `src/**/*.luau` in [coverage].include / exclude
        parts = re.escape(clean_pat).replace(r"\*\*/", "(?:.+/)?").replace(r"\*\*", ".*").replace(r"\*", "[^/]*").replace(r"\?", "[^/]")
        return re.fullmatch(parts, name) is not None
    return name == clean_pat or name.startswith(clean_pat + "/")


def included(name: str, include: list[str]) -> bool:
    return any(_matches_pattern(name, prefix) for prefix in include)


def chosen_files(files, include: list[str], exclude: list[str] = ()) -> dict[str, dict[int, bool]]:
    return {
        name: lines
        for name, lines in files.items()
        if included(name, include) and not included(name, list(exclude)) and lines
    }


def markdown(files, include: list[str], exclude: list[str] = (), minimum: float | None = None) -> str:
    chosen = chosen_files(files, include, exclude)
    total_cov = sum(sum(1 for hit in lines.values() if hit) for lines in chosen.values())
    total = sum(len(lines) for lines in chosen.values())
    pct = 100 * total_cov / total if total else 0.0
    floor = f" (minimum {minimum:g}%)" if minimum is not None else ""
    mark = "" if minimum is None else (" :white_check_mark:" if pct >= minimum else " :x:")
    rows = [f"### Coverage: {pct:.1f}%{floor}{mark}", "", "| File | Coverage | Lines |", "| --- | ---: | ---: |"]
    for name in sorted(chosen):
        cov = sum(1 for hit in chosen[name].values() if hit)
        rows.append(f"| `{name}` | {100 * cov / len(chosen[name]):.1f}% | {cov}/{len(chosen[name])} |")
    rows.append(f"| **Total** | **{pct:.1f}%** | **{total_cov}/{total}** |")
    return "\n".join(rows) + "\n"


def summarize(
    files,
    include: list[str],
    out=None,
    exclude: list[str] = (),
    *,
    uncovered: bool = False,
    root: Path | None = None,
) -> float:
    out = sys.stderr if out is None else out
    chosen = chosen_files(files, include, exclude)
    if not files:
        raise SertError("coverage: the LCOV file holds no records (did the spec run?)")
    if not chosen:
        raise SertError(
            f"coverage: no records under {', '.join(include)}: set [coverage].include to your source directories"
        )
    width = max(28, *(len(name) for name in chosen))
    total_cov = total = 0
    print(f"{'file':{width}} {'cov%':>6}  covered/total", file=out)
    for name in sorted(chosen):
        cov, tot = sum(1 for hit in chosen[name].values() if hit), len(chosen[name])
        total_cov += cov
        total += tot
        missed_ranges = _uncovered_ranges(chosen[name]) if cov < tot else ""
        suffix = f"  [missed: {missed_ranges}]" if missed_ranges else ""
        print(f"{name:{width}} {100 * cov / tot:5.1f}%  {cov}/{tot}{suffix}", file=out)
        if uncovered and cov < tot and root is not None:
            src_path = Path(root) / name
            if src_path.is_file():
                try:
                    src_lines = src_path.read_text(encoding="utf-8", errors="replace").splitlines()
                except OSError:
                    src_lines = []
                missed_lns = sorted(ln for ln, hit in chosen[name].items() if not hit)
                for ln in missed_lns[:15]:
                    if 1 <= ln <= len(src_lines):
                        print(f"  L{ln}: {src_lines[ln - 1]}", file=out)
    pct = 100 * total_cov / total
    print("-" * (width + 22), file=out)
    print(f"{'TOTAL':{width}} {pct:5.1f}%  {total_cov}/{total}", file=out)
    return pct


def badge_color(pct: float, min_range: float = 50.0, max_range: float = 90.0) -> str:
    clamped = max(min_range, min(max_range, float(pct)))
    ratio = 1.0 if max_range <= min_range else (clamped - min_range) / (max_range - min_range)
    r, g, b = colorsys.hls_to_rgb(ratio * (120.0 / 360.0), 0.40, 0.75)
    return "#" + "".join(f"{int(round(c * 255, 6) + 0.5):02x}" for c in (r, g, b))


def badge_payload(pct: float, label: str = "coverage") -> dict[str, object]:
    return {
        "schemaVersion": 1,
        "label": label,
        "message": f"{pct:.1f}%",
        "color": badge_color(pct),
    }


def write_badge(path: Path, pct: float, label: str = "coverage") -> bytes:
    data = (json.dumps(badge_payload(pct, label), indent=2) + "\n").encode("utf-8")
    path.parent.mkdir(parents=True, exist_ok=True)
    write_atomic(path, data)
    return data


def _resolve_badge_path(root: Path, badge_arg, cfg_badge) -> Path | None:
    raw = badge_arg if badge_arg is not None else cfg_badge
    if raw in (None, False):
        return None
    name = "coverage.json" if raw is True or str(raw).strip() == "" else str(raw)
    path = Path(name)
    return path if path.is_absolute() else (root / path)


def output_path(cfg, root: Path | None = None, file_arg: str | Path | None = None) -> Path:
    """Resolve the active LCOV file path from an explicit arg, `[coverage].file`, or `coverage.out`."""
    raw = file_arg or config_mod.section_table(cfg, "coverage").get("file") or "coverage.out"
    path = Path(raw)
    if path.is_absolute():
        return path
    base = Path(root) if root is not None else (Path(cfg.root) if getattr(cfg, "root", None) else Path("."))
    return base / path


def add_parser(subparsers) -> None:
    parser = subparsers.add_parser("coverage")
    parser.add_argument("file", nargs="?", help="LCOV file (default: <root>/coverage.out)")
    parser.add_argument("--min", type=float, help="fail below this percentage (default: [coverage].min)")
    parser.add_argument("--uncovered", action="store_true", help="print up to 15 missed source lines under each file")
    parser.add_argument(
        "--diff",
        nargs="?",
        const="HEAD",
        default=None,
        metavar="REV",
        help="compute coverage over lines modified in git diff (and untracked .luau files) since REV (default: HEAD)",
    )
    parser.add_argument(
        "--badge",
        nargs="?",
        const=True,
        default=None,
        metavar="FILE",
        help="write local Shields.io endpoint JSON (default: coverage.json or [coverage].badge)",
    )
    parser.add_argument("--agent", action="store_true", help="token-minimal coverage summary for AI agents")
    parser.add_argument(
        "--format",
        choices=("human", "agent", "json"),
        default=None,
        help="output format (default: human; or agent when SERT_AGENT=1)",
    )
    parser.set_defaults(func=main)


def cmd_coverage(
    args,
    root: Path | None = None,
    cfg: config_mod.Config | dict | None = None,
    *,
    cov_files: dict[str, dict[int, int]] | None = None,
    diff_lines: dict[str, set[int]] | None = None,
) -> int:
    from sert import agent

    if cfg is None or not isinstance(cfg, config_mod.Config):
        cfg = config_mod.from_args(args)
    root = Path(root) if root is not None else cfg.root
    table = cfg.table("coverage")
    include = [norm(str(p)).rstrip("/") for p in as_list(table.get("include", ["src"]))]
    exclude = [norm(str(p)).rstrip("/") for p in as_list(table.get("exclude"))]
    min_arg = getattr(args, "min", None)
    minimum = min_arg if min_arg is not None else table.get("min")
    path = output_path(cfg, root, getattr(args, "file", None))
    if cov_files is not None:
        files = {k: dict(v) for k, v in cov_files.items()}
    else:
        if not path.is_file():
            raise SertError(f"coverage: {path} not found: run `{config_mod.command('run --coverage')}` first")
        try:
            files = parse(path, root=root)
        except OSError as err:
            raise SertError(f"coverage: cannot read {path}: {err}")
    fmt = agent.output_format(args)
    diff_rev = getattr(args, "diff", None)
    if diff_rev:
        resolved_diff_lines = git_diff_lines(root, str(diff_rev)) if diff_lines is None else diff_lines
        filtered = filter_diff_files(files, resolved_diff_lines)
        inject_uncovered_diff_files(filtered, files, resolved_diff_lines, root, include, exclude)
        files = filtered
        chosen = chosen_files(files, include, exclude)
        if sum(len(lines) for lines in chosen.values()) == 0:
            if fmt == "agent":
                print("OK coverage=100.0% (0/0) no covered lines modified in diff")
            elif fmt == "json":
                print(
                    agent.json_dumps_compact(
                        agent.json_envelope(
                            "coverage",
                            0,
                            summary={"pct": 100.0, "covered": 0, "total": 0, "diff": str(diff_rev)},
                            data={"files": {}, "no_covered_lines_in_diff": True},
                        )
                    )
                )
            else:
                print("coverage: no covered lines modified in diff")
            return 0
    uncovered = bool(getattr(args, "uncovered", False))
    chosen = chosen_files(files, include, exclude)
    min_float = float(minimum) if minimum is not None else None
    pct = summarize(
        files,
        include,
        out=(io.StringIO() if fmt != "human" else None),
        exclude=exclude,
        uncovered=uncovered,
        root=root,
    )
    step_summary(markdown(files, include, exclude, min_float))
    badge_arg = getattr(args, "badge", None)
    cfg_badge = None if diff_rev else table.get("badge")
    badge_path = _resolve_badge_path(root, badge_arg, cfg_badge)
    if badge_path is not None:
        write_badge(badge_path, pct)
    exit_code = FAILED if (min_float is not None and pct < min_float) else 0
    if fmt == "agent":
        print(agent.format_coverage_agent(chosen, minimum=min_float))
    elif fmt == "json":
        tot = sum(len(lines) for lines in chosen.values())
        cov = sum(1 for lines in chosen.values() for hit in lines.values() if hit)
        gaps = {
            rel: _uncovered_ranges(lines)
            for rel, lines in sorted(chosen.items())
            if any(not hit for hit in lines.values())
        }
        print(
            agent.json_dumps_compact(
                agent.json_envelope(
                    "coverage",
                    exit_code,
                    summary={
                        "pct": round(pct, 2),
                        "covered": cov,
                        "total": tot,
                        **({"min": min_float} if min_float is not None else {}),
                    },
                    errors=([f"coverage {pct:.1f}% below floor {min_float:g}%"] if exit_code else []),
                    data={"uncovered": gaps},
                )
            )
        )
    else:
        print(f"{pct:.1f}")
        if exit_code:
            print(f"coverage: {pct:.1f}% is below the {min_float:g}% floor", file=sys.stderr)
            if on_github_actions():
                annotate("error", f"coverage {pct:.1f}% is below the {min_float:g}% floor", title="sert coverage")
                emitted_files = 0
                for rel, line_map in sorted(chosen.items()):
                    missed = sorted(ln for ln, hit in line_map.items() if not hit)
                    if not missed:
                        continue
                    ranges = _uncovered_ranges(line_map)
                    annotate(
                        "error",
                        f"uncovered lines: {ranges}",
                        file=rel,
                        line=missed[0],
                        title="sert coverage",
                    )
                    emitted_files += 1
                    if emitted_files >= 20:
                        break
    return exit_code


def main(args) -> int:
    return cmd_coverage(args)
