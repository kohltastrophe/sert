"""`sert coverage [FILE] [--min N]`: summarize `luau --coverage` (LCOV) output.

Duplicate SF: records merge by union: a line is covered if any record hit it.
"""

from __future__ import annotations

import colorsys
import json
import os
from pathlib import Path
import re
import subprocess
import sys

from sert import config as config_mod
from sert.util import FAILED, SertError, as_list, posix, step_summary, write_atomic

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
            ["git", "diff", "-U0", rev],
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
    parser.set_defaults(func=main)


def cmd_coverage(args, root: Path | None = None, cfg: config_mod.Config | dict | None = None) -> int:
    if cfg is None or not isinstance(cfg, config_mod.Config):
        cfg = config_mod.from_args(args)
    root = Path(root) if root is not None else cfg.root
    table = cfg.table("coverage")
    include = [norm(str(p)).rstrip("/") for p in as_list(table.get("include", ["src"]))]
    exclude = [norm(str(p)).rstrip("/") for p in as_list(table.get("exclude"))]
    min_arg = getattr(args, "min", None)
    minimum = min_arg if min_arg is not None else table.get("min")
    file_arg = getattr(args, "file", None)
    path = root / (file_arg or "coverage.out")
    if not path.is_file():
        raise SertError(f"coverage: {path} not found: run `{config_mod.command('run --coverage')}` first")
    try:
        files = parse(path, root=root)
    except OSError as err:
        raise SertError(f"coverage: cannot read {path}: {err}")
    diff_rev = getattr(args, "diff", None)
    if diff_rev:
        files = filter_diff_files(files, git_diff_lines(root, str(diff_rev)))
        chosen = chosen_files(files, include, exclude)
        if sum(len(lines) for lines in chosen.values()) == 0:
            print("coverage: no covered lines modified in diff")
            return 0
    uncovered = bool(getattr(args, "uncovered", False))
    pct = summarize(files, include, exclude=exclude, uncovered=uncovered, root=root)
    step_summary(markdown(files, include, exclude, float(minimum) if minimum is not None else None))
    print(f"{pct:.1f}")
    badge_arg = getattr(args, "badge", None)
    cfg_badge = None if diff_rev else table.get("badge")
    badge_path = _resolve_badge_path(root, badge_arg, cfg_badge)
    if badge_path is not None:
        write_badge(badge_path, pct)
    if minimum is not None and pct < float(minimum):
        print(f"coverage: {pct:.1f}% is below the {float(minimum):g}% floor", file=sys.stderr)
        return FAILED
    return 0


def main(args) -> int:
    return cmd_coverage(args)
