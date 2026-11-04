"""`sert coverage [FILE] [--min N]`: summarize `luau --coverage` (LCOV) output.

Duplicate SF: records merge by union: a line is covered if any record hit it.
"""

from __future__ import annotations

import base64
import colorsys
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile

from sert import config as config_mod
from sert.release import ZERO, identity_env
from sert.util import FAILED, SertError, as_list, git, note, posix, step_summary, write_atomic

STAGE_PREFIX = ".sert/stage/files/"
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
    except (OSError, subprocess.SubprocessError):
        return {}
    if proc.returncode != 0:
        return {}
    return parse_diff_lines(proc.stdout, root=root)


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


def norm(name: str, root: Path | None = None) -> str:
    clean = name.replace("\\", "/")
    if root is not None and (clean.startswith("/") or _DRIVE_RE.match(clean) or os.path.isabs(name)):
        try:
            resolved, base = Path(name).resolve(), Path(root).resolve()
            if os.path.normcase(os.path.commonpath([resolved, base])) == os.path.normcase(str(base)):
                clean = os.path.relpath(resolved, base).replace(os.sep, "/")
        except (OSError, ValueError):
            pass
    return clean.removeprefix("./").removeprefix(STAGE_PREFIX)


def parse(path, root: Path | None = None) -> dict[str, dict[int, bool]]:
    files: dict[str, dict[int, bool]] = {}
    current = None
    with open(path, encoding="utf-8", errors="replace") as handle:
        for line in handle:
            if line.startswith("SF:"):
                current = files.setdefault(norm(line[3:].strip(), root), {})
            elif line.startswith("DA:") and current is not None:
                number, hits = line[3:].split(",")[:2]
                num = int(number)
                current[num] = current.get(num, False) or int(hits) > 0
    return files


def included(name: str, include: list[str]) -> bool:
    return any(name == prefix or name.startswith(prefix.rstrip("/") + "/") for prefix in include)


def chosen_files(files, include: list[str], exclude: list[str] = ()) -> dict[str, dict[int, bool]]:
    return {name: lines for name, lines in files.items() if included(name, include) and not included(name, list(exclude)) and lines}


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


def summarize(files, include: list[str], out=None, exclude: list[str] = (), *, uncovered: bool = False, root: Path | None = None) -> float:
    out = sys.stderr if out is None else out
    chosen = chosen_files(files, include, exclude)
    if not files:
        raise SertError("coverage: the LCOV file holds no records (did the spec run?)")
    if not chosen:
        raise SertError(f"coverage: no records under {', '.join(include)}: set [coverage].include to your source directories")
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


def _git_auth_args(root: Path, remote: str = "origin") -> list[str]:
    token = os.environ.get("GITHUB_TOKEN", "").strip()
    if not token:
        return []
    url = git(root, "config", "--get", f"remote.{remote}.url", check=False).strip()
    if not url.startswith("https://github.com/"):
        return []
    if git(root, "config", "--get", "http.https://github.com/.extraheader", check=False).strip():
        return []
    basic = base64.b64encode(f"x-access-token:{token}".encode("utf-8")).decode("ascii")
    return ["-c", f"http.https://github.com/.extraheader=AUTHORIZATION: basic {basic}"]


def commit_badge(root: Path, branch: str, entry_name: str, data: bytes, pct: float, *, push: bool = False, remote: str = "origin") -> str | None:
    clean_entry = entry_name.replace("\\", "/").strip("/")
    if not clean_entry or clean_entry.startswith("../") or "/../" in f"/{clean_entry}/":
        clean_entry = Path(clean_entry or "coverage.json").name
    ref = f"refs/heads/{branch}"
    auth = _git_auth_args(root, remote) if push else []
    if push and git(root, *auth, "ls-remote", "--exit-code", "--heads", remote, branch, check=False):
        git(root, *auth, "fetch", "--no-tags", remote, f"+{ref}:{ref}")
    tip = git(root, "rev-parse", "--verify", "--quiet", f"{ref}^{{commit}}", check=False) or None
    with tempfile.TemporaryDirectory(prefix="sert-badge-") as scratch:
        env = dict(os.environ, GIT_INDEX_FILE=str(Path(scratch) / "index"))
        if tip:
            git(root, "read-tree", tip, env=env)
        else:
            git(root, "read-tree", "--empty", env=env)
        blob = git(root, "hash-object", "-w", "--stdin", env=env, input=data.decode("utf-8"))
        git(root, "update-index", "--add", "--cacheinfo", f"100644,{blob},{clean_entry}", env=env)
        tree = git(root, "write-tree", env=env)
    has_parent = bool(tip and git(root, "rev-parse", "--verify", "--quiet", f"{tip}^", check=False))
    if tip and git(root, "rev-parse", f"{tip}^{{tree}}") == tree and not has_parent:
        note(f"coverage: {branch} is up to date ({tip[:12]}, tree {tree[:12]})")
        return None
    message = f"badge: coverage {pct:.1f}%"
    commit = git(root, "commit-tree", tree, "-m", message, env=identity_env(root))
    git(root, "update-ref", "-m", message, ref, commit, tip or ZERO)
    note(f"coverage: {branch} -> {commit[:12]}: {message}")
    if push:
        git(root, *auth, "push", remote, f"+{ref}:{ref}")
    return commit


def _resolve_badge_path(root: Path, badge_arg, cfg_badge, want_branch: bool) -> Path | None:
    raw = badge_arg if badge_arg is not None else cfg_badge
    if raw is False:
        return None
    if raw is None:
        return (root / "coverage.json") if want_branch else None
    name = "coverage.json" if raw is True or str(raw).strip() == "" else str(raw)
    path = Path(name)
    return path if path.is_absolute() else (root / path)


def _resolve_badge_branch(branch_arg, cfg_branch, push: bool) -> str | None:
    raw = branch_arg if branch_arg is not None else cfg_branch
    if raw in (None, False, ""):
        return "badges" if push else None
    return "badges" if raw is True else str(raw)


def add_parser(subparsers) -> None:
    parser = subparsers.add_parser("coverage")
    parser.add_argument("file", nargs="?", help="LCOV file (default: <root>/coverage.out)")
    parser.add_argument("--min", type=float, help="fail below this percentage (default: [coverage].min)")
    parser.add_argument("--uncovered", action="store_true", help="print up to 15 missed source lines under each file")
    parser.add_argument("--diff", nargs="?", const="HEAD", default=None, metavar="REV", help="compute coverage over lines modified in git diff since REV (default: HEAD)")
    parser.add_argument("--badge", nargs="?", const=True, default=None, metavar="FILE", help="write Shields.io endpoint JSON (default: coverage.json or [coverage].badge)")
    parser.add_argument("--badge-branch", nargs="?", const=True, default=None, metavar="BRANCH", help="commit coverage.json onto BRANCH via git plumbing (default: badges or [coverage].badge_branch)")
    parser.add_argument("--badge-push", action="store_true", help="fetch and push origin <badge-branch> when committing the badge")
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
    branch_arg = getattr(args, "badge_branch", None)
    push_arg = bool(getattr(args, "badge_push", False))
    cfg_badge = None if diff_rev else table.get("badge")
    cfg_branch = None if diff_rev else table.get("badge_branch")
    branch = _resolve_badge_branch(branch_arg, cfg_branch, push_arg)
    badge_path = _resolve_badge_path(root, badge_arg, cfg_badge, branch is not None)
    badge_bytes = write_badge(badge_path, pct) if badge_path is not None else None
    if minimum is not None and pct < float(minimum):
        print(f"coverage: {pct:.1f}% is below the {float(minimum):g}% floor", file=sys.stderr)
        return FAILED
    if branch is not None:
        if badge_bytes is None:
            badge_bytes = (json.dumps(badge_payload(pct), indent=2) + "\n").encode("utf-8")
        entry_name = posix(badge_path, root) if badge_path is not None else "coverage.json"
        commit_badge(root, branch, entry_name, badge_bytes, pct, push=push_arg)
    return 0


def main(args) -> int:
    return cmd_coverage(args)
