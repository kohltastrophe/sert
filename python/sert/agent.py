"""Token-minimal agent output formatters, mode detection, and JSON envelopes."""

from __future__ import annotations

import difflib
import json
import os
from pathlib import Path
from typing import Any, Mapping, Sequence

from sert import coverage as coverage_mod
from sert import markers as markers_mod
from sert.markers import SKIP_REASONS

VALID_FORMATS = ("human", "agent", "json")
_TRUTHY = ("1", "true", "yes", "on")


def _get_field(obj: Any, name: str, default: Any = None) -> Any:
    if obj is None:
        return default
    if isinstance(obj, Mapping):
        return obj.get(name, default)
    return getattr(obj, name, default)


def output_format(args: Any = None, *, env: Mapping[str, str] | None = None) -> str:
    """Resolve output mode: ``"human" | "agent" | "json"``.

    Defaults to ``"human"`` unless ``--format=agent|json``, ``--json``,
    ``--agent``, or ``SERT_AGENT=1`` is set.
    """
    fmt = _get_field(args, "format", None)
    if isinstance(fmt, str):
        normed = fmt.strip().lower()
        if normed in ("human", "agent", "json"):
            return normed

    if bool(_get_field(args, "json", False)):
        return "json"
    if bool(_get_field(args, "agent", False)):
        return "agent"

    env_map = os.environ if env is None else env
    raw_env = str(env_map.get("SERT_AGENT", "")).strip().lower()
    if raw_env in _TRUTHY:
        return "agent"
    return "human"


def is_agent_mode(args: Any = None, *, env: Mapping[str, str] | None = None) -> bool:
    """Return ``True`` when the active output format is ``"agent"``."""
    return output_format(args, env=env) == "agent"


def json_envelope(
    command: str,
    status: str | int,
    *,
    summary: dict[str, Any] | None = None,
    errors: list[Any] | None = None,
    data: dict[str, Any] | None = None,
    exit_code: int | None = None,
) -> dict[str, Any]:
    """Build a uniform machine-readable JSON envelope for CLI commands."""
    if isinstance(status, int) and not isinstance(status, bool):
        resolved_code = status if exit_code is None else exit_code
        resolved_status = "ok" if status == 0 else ("failed" if status == 1 else "error")
    else:
        resolved_status = str(status)
        if exit_code is not None:
            resolved_code = exit_code
        elif resolved_status == "ok":
            resolved_code = 0
        elif resolved_status in ("fail", "failed"):
            resolved_status = "failed"
            resolved_code = 1
        else:
            resolved_code = 2

    return {
        "version": 1,
        "command": command,
        "status": resolved_status,
        "exit_code": resolved_code,
        "summary": dict(summary or {}),
        "errors": list(errors or []),
        "data": dict(data or {}),
    }


def json_dumps_compact(payload: Any) -> str:
    return json.dumps(payload, separators=(",", ":"), default=str)


def _trim(text: str, limit: int = 240) -> str:
    cleaned = " ".join(text.splitlines()) if "\n" not in text else text
    if len(cleaned) <= limit:
        return cleaned
    return cleaned[: limit - 3] + "..."


def _snippet_lines(root: Path | None, file_path: str | None, line: int | None, cache: dict[Path, list[str]]) -> list[str]:
    if root is None or not file_path or not isinstance(line, int) or line <= 0:
        return []
    rel = coverage_mod.norm(str(file_path).lstrip("@="), root)
    if not rel:
        return []
    candidate = (Path(root) / rel).resolve()
    try:
        if not candidate.is_relative_to(Path(root).resolve()) or not candidate.is_file():
            return []
    except OSError:
        return []

    lines = cache.get(candidate)
    if lines is None:
        try:
            lines = candidate.read_text(encoding="utf-8", errors="replace").splitlines()
        except OSError:
            lines = []
        cache[candidate] = lines
    if not lines or line > len(lines):
        return []

    start = max(1, line - 1)
    end = min(len(lines), line + 1)
    width = len(str(end))
    rendered: list[str] = []
    for ln in range(start, end + 1):
        marker = ">" if ln == line else " "
        src_line = lines[ln - 1]
        if len(src_line) > 140:
            src_line = src_line[:137] + "..."
        rendered.append(f"  {marker} {ln:>{width}} | {src_line}")
    return rendered


def compact_diff(expected: Any, actual: Any, *, max_lines: int = 12) -> list[str]:
    """Render a short path/line diff without flooding context."""
    if isinstance(expected, str) and isinstance(actual, str):
        if "\n" in expected or "\n" in actual:
            diff_lines = list(
                difflib.unified_diff(
                    expected.splitlines(),
                    actual.splitlines(),
                    fromfile="expected",
                    tofile="actual",
                    lineterm="",
                    n=1,
                )
            )
            if len(diff_lines) > max_lines:
                diff_lines = diff_lines[:max_lines] + [f"... (+{len(diff_lines) - max_lines} diff lines)"]
            return [f"  {ln}" for ln in diff_lines]
        return [f"  - {_trim(expected, 120)}", f"  + {_trim(actual, 120)}"]

    path_diffs = _find_path_diffs(expected, actual, limit=4)
    if path_diffs:
        return [f"  {line}" for line in path_diffs]
    return [f"  - {_trim(repr(expected), 120)}", f"  + {_trim(repr(actual), 120)}"]


def _find_path_diffs(expected: Any, actual: Any, prefix: str = "$", *, limit: int = 4) -> list[str]:
    if expected == actual:
        return []
    diffs: list[str] = []
    if isinstance(expected, Mapping) and isinstance(actual, Mapping):
        for key in sorted(set(expected) | set(actual), key=str):
            sub_path = f"{prefix}.{key}"
            if key not in expected:
                diffs.append(f"{sub_path}: missing -> +{actual[key]!r}")
            elif key not in actual:
                diffs.append(f"{sub_path}: -{expected[key]!r} -> missing")
            else:
                diffs.extend(_find_path_diffs(expected[key], actual[key], sub_path, limit=limit - len(diffs)))
            if len(diffs) >= limit:
                break
        return diffs[:limit]
    if isinstance(expected, list) and isinstance(actual, list):
        common = min(len(expected), len(actual))
        for idx in range(common):
            if expected[idx] != actual[idx]:
                diffs.extend(_find_path_diffs(expected[idx], actual[idx], f"{prefix}[{idx}]", limit=limit - len(diffs)))
            if len(diffs) >= limit:
                break
        if len(expected) != len(actual) and len(diffs) < limit:
            diffs.append(f"{prefix}.length: -{len(expected)} +{len(actual)}")
        return diffs[:limit]
    return [f"{prefix}: -{expected!r} +{actual!r}"]


def format_skipped_targets(skipped_by_reason: Mapping[str, int] | None) -> str | None:
    if not skipped_by_reason:
        return None
    parts: list[str] = []
    for reason in SKIP_REASONS:
        count = skipped_by_reason.get(reason, 0)
        if isinstance(count, int) and count > 0:
            parts.append(f"{reason}={count}")
    for reason in sorted(skipped_by_reason):
        if reason in SKIP_REASONS:
            continue
        count = skipped_by_reason[reason]
        if isinstance(count, int) and count > 0:
            parts.append(f"{reason}={count}")
    if not parts:
        return None
    return "SKIPPED_TARGETS " + " ".join(parts)


def format_regressions_block(tokens: Sequence[str]) -> list[str]:
    unique = list(dict.fromkeys(str(tok) for tok in tokens if tok))
    if not unique:
        return []
    if len(unique) == 1:
        return [f'regressions = {{ "{unique[0]}" }}']
    quoted = ", ".join(f'"{tok}"' for tok in unique)
    return [f"regressions = {{ {quoted} }}"]


def _format_ns(ns: int | float | None) -> str:
    if not isinstance(ns, (int, float)):
        return "0ns"
    if ns >= 1_000_000_000:
        return f"{ns / 1_000_000_000:.2f}s"
    if ns >= 1_000_000:
        return f"{ns / 1_000_000:.2f}ms"
    if ns >= 1_000:
        return f"{ns / 1_000:.2f}us"
    return f"{ns:.0f}ns"


def _collect_from_parsed(
    parsed: markers_mod.Parsed,
    failures: list[dict[str, Any]],
    skipped_by_reason: dict[str, int],
    zero_assertion_tests: list[str],
    tautologies: list[dict[str, Any]],
    regression_tokens: list[str],
    snapshots: list[dict[str, Any]],
    *,
    collect_tests: bool = True,
) -> tuple[int, int, int]:
    if collect_tests:
        for test in parsed.tests:
            if test.get("status") in ("fail", "error"):
                failures.append(test)
    for reason, count in getattr(parsed, "skipped_by_reason", {}).items():
        skipped_by_reason[reason] = skipped_by_reason.get(reason, 0) + int(count)
    zero_assertion_tests.extend(getattr(parsed, "zero_assertion_tests", ()))
    tautologies.extend(getattr(parsed, "tautologies", ()))
    snapshots.extend(getattr(parsed, "snapshots", ()))
    for reg in getattr(parsed, "regressions", ()):
        tok = reg.get("token") or reg.get("replay") if isinstance(reg, Mapping) else str(reg)
        if tok:
            regression_tokens.append(str(tok))

    summary = parsed.results or {}
    if summary:
        return (
            int(summary.get("passed", 0) or 0),
            int(summary.get("failed", 0) or 0),
            int(summary.get("skipped", 0) or 0),
        )
    passed = sum(1 for t in parsed.tests if t.get("status") in ("pass", "flaky"))
    f = sum(1 for t in parsed.tests if t.get("status") in ("fail", "error"))
    s = sum(1 for t in parsed.tests if t.get("status") == "skip")
    return passed, f, s


def format_run_agent(result: Any, *, root: Path | None = None) -> str:
    """Format test run results with failing tests, snippets, diffs, and skipped notices."""
    snippet_cache: dict[Path, list[str]] = {}
    passed = failed = skipped = 0
    duration_ms = 0
    failures: list[dict[str, Any]] = []
    flaky_tests: list[dict[str, Any]] = []
    runtime_errors: list[dict[str, Any]] = []
    skipped_by_reason: dict[str, int] = {}
    zero_assertion_tests: list[str] = []
    tautologies: list[dict[str, Any]] = []
    regression_tokens: list[str] = []
    snapshots: list[dict[str, Any]] = []

    if isinstance(result, Mapping):
        passed = int(result.get("passed", 0) or 0)
        failed = int(result.get("failed", 0) or 0)
        skipped = int(result.get("skipped", 0) or 0)
        duration_ms = int(result.get("duration_ms", round(float(result.get("wall_s", 0.0)) * 1000)))
        if "failures" in result:
            failures = list(result.get("failures") or ())
        else:
            failures = [t for t in (result.get("tests") or ()) if t.get("status") in ("fail", "error")]
        flaky_tests = [t for t in (result.get("tests") or ()) if t.get("status") == "flaky" or t.get("flaky")]
        runtime_errors = list(result.get("errors", ()))
        skipped_by_reason = {str(k): int(v) for k, v in (result.get("skipped_by_reason") or {}).items()}
        zero_assertion_tests = [str(x) for x in result.get("zero_assertion_tests", ())]
        tautologies = list(result.get("tautologies", ()))
        for reg in result.get("regressions", ()):
            tok = reg.get("token") or reg.get("replay") if isinstance(reg, Mapping) else str(reg)
            if tok:
                regression_tokens.append(str(tok))
        snapshots = list(result.get("snapshots", ()))
        exit_status = result.get("status", result.get("code", 0))
    elif isinstance(result, markers_mod.Parsed):
        passed, failed, skipped = _collect_from_parsed(
            result,
            failures,
            skipped_by_reason,
            zero_assertion_tests,
            tautologies,
            regression_tokens,
            snapshots,
        )
        flaky_tests = [t for t in result.tests if t.get("status") == "flaky" or t.get("flaky")]
        exit_status = 1 if failed > 0 or failures else 0
    else:
        entries = list(_get_field(result, "entries", ()) or ())
        result_tests = list(_get_field(result, "tests", ()) or ())
        if result_tests:
            failures.extend(t for t in result_tests if t.get("status") in ("fail", "error"))
            flaky_tests.extend(t for t in result_tests if t.get("status") == "flaky" or t.get("flaky"))
            counts = _get_field(result, "counts", {}) or {}
            passed = int(counts.get("passed", 0) or 0)
            failed = int(counts.get("failed", 0) or 0)
            skipped = int(counts.get("skipped", 0) or 0)

        entry_seconds = 0.0
        entry_skipped = 0
        for entry in entries:
            entry_seconds += float(_get_field(entry, "seconds", 0.0) or 0.0)
            parsed = _get_field(entry, "parsed", None)
            if parsed is None:
                output_text = _get_field(entry, "output", "")
                if output_text:
                    parsed = markers_mod.parse(output_text)
            if parsed is not None:
                ep, ef, es = _collect_from_parsed(
                    parsed,
                    failures,
                    skipped_by_reason,
                    zero_assertion_tests,
                    tautologies,
                    regression_tokens,
                    snapshots,
                    collect_tests=not result_tests,
                )
                if not result_tests:
                    flaky_tests.extend(t for t in parsed.tests if t.get("status") == "flaky" or t.get("flaky"))
                entry_skipped += es
                if not result_tests:
                    passed += ep
                    failed += ef
                    skipped += es
            if _get_field(entry, "timed_out", False):
                runtime_errors.append({"file": _get_field(entry, "entry", ""), "message": "timed out"})
            elif (code := _get_field(entry, "code", 0)) not in (0, None):
                entry_name = _get_field(entry, "entry", "")
                if not any(f.get("entry") == entry_name or f.get("file") == entry_name for f in failures):
                    runtime_errors.append({"file": entry_name, "message": f"exited with code {code}"})

        reason_total = sum(v for v in skipped_by_reason.values() if isinstance(v, int))
        skipped = max(skipped, entry_skipped, reason_total)
        wall_s = _get_field(result, "wall_s", None)
        duration_ms = round(float(wall_s if wall_s is not None else entry_seconds) * 1000)
        exit_status = _get_field(result, "status", _get_field(result, "code", 0))

    status = "FAIL" if (failed > 0 or failures or runtime_errors or exit_status not in (0, None)) else "OK"
    flaky_tag = f" flaky={len(flaky_tests)}" if flaky_tests else ""
    lines = [f"{status} passed={passed} failed={failed} skipped={skipped}{flaky_tag} duration={duration_ms}ms"]

    for fail in failures:
        name = fail.get("name") or fail.get("test") or "(unnamed)"
        raw_file = fail.get("file") or fail.get("source")
        line = fail.get("line")
        loc = f"{coverage_mod.norm(str(raw_file), root)}:{line}" if raw_file and line else (coverage_mod.norm(str(raw_file), root) if raw_file else "unknown")
        lines.append(f"FAIL {name} ({loc})")
        lines.extend(_snippet_lines(root, raw_file, line, snippet_cache))
        if "expected" in fail and "actual" in fail:
            lines.extend(compact_diff(fail["expected"], fail["actual"]))
        elif fail.get("message"):
            lines.append(f"  {_trim(str(fail['message']))}")
        if replay := (fail.get("replay") or fail.get("token")):
            regression_tokens.append(str(replay))

    for flaky_item in flaky_tests:
        fname = flaky_item.get("name") or "(unnamed)"
        attempts = flaky_item.get("attempts")
        att_text = f" (passed on attempt {attempts})" if attempts else " (passed on retry)"
        lines.append(f"FLAKY {fname}{att_text}")

    for err in runtime_errors:
        raw_file = err.get("file") or err.get("source")
        line = err.get("line")
        loc = f" ({coverage_mod.norm(str(raw_file), root)}:{line})" if raw_file and line else ""
        msg = err.get("message") or err.get("error") or str(err)
        lines.append(f"ERROR{loc}: {_trim(str(msg))}")
        lines.extend(_snippet_lines(root, raw_file, line, snippet_cache))

    for snap in snapshots:
        raw_file = snap.get("file") or ""
        loc = snap.get("line") or snap.get("key") or snap.get("ordinal") or ""
        norm_file = coverage_mod.norm(str(raw_file), root) if raw_file else "<unknown>"
        if snap.get("previous") != snap.get("actual"):
            lines.append(f"SNAPSHOT {norm_file}:{loc}")
            lines.extend(compact_diff(snap.get("previous"), snap.get("actual"), max_lines=10))

    lines.extend(format_regressions_block(regression_tokens))

    if skipped_notice := format_skipped_targets(skipped_by_reason):
        lines.append(skipped_notice)
    if zero_assertion_tests:
        preview = ", ".join(zero_assertion_tests[:6])
        suffix = f" (+{len(zero_assertion_tests) - 6} more)" if len(zero_assertion_tests) > 6 else ""
        lines.append(f"ZERO_ASSERTIONS {len(zero_assertion_tests)}: {preview}{suffix}")
    for taut in tautologies[:6]:
        t_file = coverage_mod.norm(str(taut.get("file", "")), root) if taut.get("file") else "?"
        t_line = taut.get("line", 0)
        lines.append(f"TAUTOLOGY {t_file}:{t_line} {_trim(str(taut.get('message') or taut.get('kind') or 'tautological assertion'))}")
    if len(tautologies) > 6:
        lines.append(f"... (+{len(tautologies) - 6} more tautologies)")

    return "\n".join(lines)


def format_lint_agent(diagnostics: Sequence[Any], *, root: Path | None = None, limit: int = 30) -> str:
    """Format lint diagnostics (`(file, line, msg)` tuples or dicts) in compact agent form."""
    if not diagnostics:
        return "OK lint=0"
    snippet_cache: dict[Path, list[str]] = {}
    lines = [f"FAIL lint={len(diagnostics)}"]
    for item in diagnostics[:limit]:
        if isinstance(item, Mapping):
            raw_file = str(item.get("file", ""))
            line = int(item.get("line", 0) or 0)
            msg = str(item.get("message", ""))
            tool = item.get("tool") or item.get("rule")
            prefix = f"[{tool}] " if tool else ""
        else:
            raw_file, line, msg = item[0], int(item[1]), str(item[2])
            prefix = ""
        norm_file = coverage_mod.norm(raw_file, root) if raw_file else "<unknown>"
        loc = f"{norm_file}:{line}" if line > 0 else norm_file
        lines.append(f"{loc} {prefix}{_trim(msg, 180)}")
        lines.extend(_snippet_lines(root, raw_file, line, snippet_cache))
    if len(diagnostics) > limit:
        lines.append(f"... (+{len(diagnostics) - limit} more diagnostics)")
    return "\n".join(lines)


def format_coverage_agent(files: Mapping[str, Mapping[int, int | bool]], *, minimum: float | None = None) -> str:
    """Format coverage showing only files with uncovered lines."""
    total = 0
    covered = 0
    gaps: list[tuple[float, str, int, int, str]] = []
    for rel in sorted(files):
        line_map = files[rel]
        file_total = len(line_map)
        file_hit = sum(1 for v in line_map.values() if v)
        total += file_total
        covered += file_hit
        if file_total > 0 and file_hit < file_total:
            pct = 100.0 * file_hit / file_total
            gaps.append((pct, rel, file_hit, file_total, coverage_mod._uncovered_ranges(line_map)))

    overall = (100.0 * covered / total) if total else 100.0
    failed = minimum is not None and overall < minimum
    status = "FAIL" if failed else "OK"
    min_tag = f" min={minimum:.1f}%" if minimum is not None else ""
    lines = [f"{status} coverage={overall:.1f}% ({covered}/{total}){min_tag}"]
    if gaps:
        gaps.sort(key=lambda item: (item[0], item[1]))
        for pct, rel, hit, file_total, ranges in gaps[:25]:
            lines.append(f"  {rel} {pct:.1f}% ({hit}/{file_total}) uncovered: {ranges}")
        if len(gaps) > 25:
            lines.append(f"  ... (+{len(gaps) - 25} more files with gaps)")
    return "\n".join(lines)


def format_mutate_agent(mutants: Sequence[Any], *, root: Path | None = None, limit: int = 20) -> str:
    """Format mutation testing showing score and SURVIVED mutants only."""
    snippet_cache: dict[Path, list[str]] = {}
    killed = survived = timeout = uncovered = equiv = total = 0
    survivors: list[Any] = []
    for m in mutants:
        total += 1
        status = str(_get_field(m, "status", "PENDING")).upper()
        if status in ("KILLED", "COMPILE_ERROR"):
            killed += 1
        elif status == "SURVIVED":
            survived += 1
            survivors.append(m)
        elif status == "TIMEOUT":
            timeout += 1
        elif status == "UNCOVERED":
            uncovered += 1
        elif status in ("EQUIVALENT", "SKIPPED"):
            equiv += 1

    killable = killed + survived + timeout + uncovered
    score = (100.0 * killed / killable) if killable else 100.0
    head_status = "FAIL" if survived > 0 else "OK"
    lines = [
        f"{head_status} mutation_score={score:.1f}% killed={killed} survived={survived} "
        f"timeout={timeout} uncovered={uncovered} total={total}"
    ]
    for m in survivors[:limit]:
        mid = _get_field(m, "id", "?")
        raw_file = str(_get_field(m, "file", ""))
        line = int(_get_field(m, "line", 0) or 0)
        op = _get_field(m, "op", "?")
        orig = _trim(str(_get_field(m, "original", "")), 60)
        mut = _trim(str(_get_field(m, "mutated", "")), 60)
        norm_file = coverage_mod.norm(raw_file, root) if raw_file else "<unknown>"
        lines.append(f"SURVIVED {mid} {norm_file}:{line} [{op}] `{orig}` -> `{mut}`")
        lines.extend(_snippet_lines(root, raw_file, line, snippet_cache))
    if len(survivors) > limit:
        lines.append(f"... (+{len(survivors) - limit} more survived mutants)")
    return "\n".join(lines)


def format_audit_agent(report: Mapping[str, Any] | Sequence[Any], *, root: Path | None = None) -> str:
    """Format test-quality audit findings (zero-assertion, tautologies, skips, stale snaps)."""
    snippet_cache: dict[Path, list[str]] = {}
    if not isinstance(report, Mapping):
        items = list(report)
        if not items:
            return "OK audit=0"
        lines = [f"FAIL audit_issues={len(items)}"]
        for item in items[:25]:
            raw_file = _get_field(item, "file", "")
            line = _get_field(item, "line", 0)
            msg = _get_field(item, "message", str(item))
            norm_file = coverage_mod.norm(str(raw_file), root) if raw_file else "?"
            lines.append(f"  {norm_file}:{line} {_trim(str(msg))}")
            lines.extend(_snippet_lines(root, str(raw_file), line if isinstance(line, int) else None, snippet_cache))
        return "\n".join(lines)

    zero_assert = list(report.get("zero_assertion_tests", ()))
    tautologies = list(report.get("tautologies", ()))
    stale_snaps = list(report.get("stale_snapshots", ()))
    issues = list(report.get("issues", ()))
    skipped_by_reason = report.get("skipped_by_reason") or {}
    issue_count = len(zero_assert) + len(tautologies) + len(stale_snaps) + len(issues)

    status = "FAIL" if issue_count > 0 else "OK"
    lines = [
        f"{status} audit_issues={issue_count} zero_assertion={len(zero_assert)} "
        f"tautologies={len(tautologies)} stale_snapshots={len(stale_snaps)}"
    ]
    for name in zero_assert[:15]:
        lines.append(f"ZERO_ASSERTION {name}")
    for taut in tautologies[:15]:
        raw_file = str(taut.get("file", ""))
        line = taut.get("line", 0)
        norm_file = coverage_mod.norm(raw_file, root) if raw_file else "?"
        lines.append(f"TAUTOLOGY {norm_file}:{line} {_trim(str(taut.get('message') or taut.get('kind') or ''))}")
        lines.extend(_snippet_lines(root, raw_file, line if isinstance(line, int) else None, snippet_cache))
    for stale in stale_snaps[:15]:
        lines.append(f"STALE_SNAPSHOT {stale}")
    for issue in issues[:15]:
        if isinstance(issue, Mapping):
            raw_file = str(issue.get("file", ""))
            line = issue.get("line", 0)
            norm_file = coverage_mod.norm(raw_file, root) if raw_file else "?"
            lines.append(f"ISSUE {norm_file}:{line} {_trim(str(issue.get('message', '')))}")
            lines.extend(_snippet_lines(root, raw_file, line if isinstance(line, int) else None, snippet_cache))
        else:
            lines.append(f"ISSUE {_trim(str(issue))}")
    if skipped_notice := format_skipped_targets(skipped_by_reason):
        lines.append(skipped_notice)
    return "\n".join(lines)


def format_verify_agent(report: Mapping[str, Any], *, root: Path | None = None) -> str:
    """Format multi-stage verification results, expanding only failed stages."""
    checks = report.get("checks", ())
    if isinstance(checks, Mapping):
        check_items = [{"name": k, **(v if isinstance(v, Mapping) else {"ok": bool(v)})} for k, v in checks.items()]
    else:
        check_items = list(checks)

    failed_checks = [c for c in check_items if not _get_field(c, "ok", _get_field(c, "exit_code", 0) == 0)]
    passed_names = [str(_get_field(c, "name", "?")) for c in check_items if c not in failed_checks]
    status = "FAIL" if failed_checks else "OK"
    lines = [f"{status} checks={len(check_items)} passed={len(passed_names)} failed={len(failed_checks)}"]
    if passed_names:
        lines.append("PASSED: " + ", ".join(passed_names))
    for chk in failed_checks:
        name = _get_field(chk, "name", "unknown")
        lines.append(f"--- FAILED {name} ---")
        if detail := _get_field(chk, "output", None) or _get_field(chk, "detail", None):
            lines.append(str(detail).rstrip())
        elif failures := _get_field(chk, "failures", None):
            lines.append(format_run_agent({"failed": len(failures), "failures": failures}, root=root))
    return "\n".join(lines)


def format_fuzz_agent(report: Mapping[str, Any], *, root: Path | None = None) -> str:
    """Format fuzz/property-testing output with shrunk counterexample and copy-paste regression token."""
    snippet_cache: dict[Path, list[str]] = {}
    iterations = int(report.get("iterations", report.get("runs", 0)) or 0)
    passed = int(report.get("passed", 0) or 0)
    failed = int(report.get("failed", 0) or 0)
    seed = report.get("seed")
    seed_part = f" seed={seed}" if seed is not None else ""
    failures = list(report.get("failures", ()))
    tokens: list[str] = [str(t) for t in report.get("regressions", ()) if t]

    status = "FAIL" if (failed > 0 or failures) else "OK"
    lines = [f"{status} fuzz iterations={iterations} passed={passed} failed={failed}{seed_part}"]
    for fail in failures:
        name = fail.get("name") or "(property)"
        raw_file = fail.get("file")
        line = fail.get("line")
        norm_file = coverage_mod.norm(str(raw_file), root) if raw_file else ""
        loc = f" ({norm_file}:{line})" if norm_file and line else (f" ({norm_file})" if norm_file else "")
        lines.append(f"FAIL {name}{loc}")
        lines.extend(_snippet_lines(root, raw_file, line, snippet_cache))
        if "counterexample" in fail:
            lines.append(f"  counterexample={_trim(repr(fail['counterexample']), 180)}")
        if "expected" in fail and "actual" in fail:
            lines.extend(compact_diff(fail["expected"], fail["actual"]))
        elif fail.get("message"):
            lines.append(f"  {_trim(str(fail['message']))}")
        if tok := (fail.get("replay") or fail.get("token")):
            tokens.append(str(tok))

    lines.extend(format_regressions_block(tokens))
    return "\n".join(lines)


def _is_num(val: Any) -> bool:
    return isinstance(val, (int, float)) and not isinstance(val, bool)


def format_bench_agent(
    benchmarks: Sequence[Mapping[str, Any]],
    *,
    baseline: Sequence[Mapping[str, Any]] | Mapping[str, Any] | None = None,
    regression_threshold: float = 0.15,
) -> str:
    """Format benchmark measurements (`[sert-x:bench]`) with optional baseline delta."""
    if not benchmarks:
        return "OK benches=0"

    base_map: dict[str, Mapping[str, Any]] = {}
    if isinstance(baseline, Mapping):
        for k, v in baseline.items():
            if isinstance(v, Mapping):
                base_map[str(k)] = v
    elif baseline is not None:
        for row in baseline:
            if isinstance(row, Mapping) and row.get("name"):
                key = f"{row.get('file', '')}::{row['name']}" if row.get("file") else str(row["name"])
                base_map[key] = row
                base_map.setdefault(str(row["name"]), row)

    regressions = 0
    rows: list[str] = []
    for b in benchmarks:
        name = str(b.get("name", "(bench)"))
        median_ns = b.get("medianNs", 0)
        iqr_ns = b.get("iqrNs", 0)
        ops = b.get("opsPerSec", 0)
        alloc_kb = b.get("allocKb", 0)
        iters = b.get("iterations", 0)
        samples = b.get("samples", 0)

        delta_tag = ""
        alloc_tag = ""
        reg_hit = False
        lookup_key = f"{b.get('file', '')}::{name}" if b.get("file") else name
        prev = base_map.get(lookup_key) or base_map.get(name)
        if prev:
            prev_med = prev.get("medianNs")
            if _is_num(prev_med) and prev_med > 0 and _is_num(median_ns):
                ratio = (float(median_ns) - float(prev_med)) / float(prev_med)
                pct = ratio * 100.0
                if ratio > regression_threshold:
                    reg_hit = True
                    delta_tag = f" REGRESSION +{pct:.1f}%"
                elif ratio < -regression_threshold:
                    delta_tag = f" FASTER {pct:.1f}%"
                else:
                    delta_tag = f" {pct:+.1f}%"
            prev_alloc = prev.get("allocKb")
            if _is_num(prev_alloc) and _is_num(alloc_kb):
                if prev_alloc > 0:
                    aratio = (float(alloc_kb) - float(prev_alloc)) / float(prev_alloc)
                    if aratio > regression_threshold:
                        reg_hit = True
                        alloc_tag = f" ALLOC_REGRESSION +{aratio * 100.0:.1f}%"
                elif prev_alloc == 0 and float(alloc_kb) > 0:
                    reg_hit = True
                    alloc_tag = f" ALLOC_REGRESSION +100.0% (0.0->{float(alloc_kb):.1f}KB)"
        if reg_hit:
            regressions += 1

        rows.append(
            f"  {name}: median={_format_ns(median_ns)} iqr={_format_ns(iqr_ns)} "
            f"ops={ops:.0f}/s alloc={alloc_kb:.1f}KB iters={iters}x{samples}{delta_tag}{alloc_tag}"
        )

    status = "FAIL" if regressions > 0 else "OK"
    return "\n".join([f"{status} benches={len(benchmarks)} regressions={regressions}", *rows])
