"""Benchmark runner, baseline comparison, and regression detection for `sert bench`."""

from __future__ import annotations

import argparse
from collections.abc import Mapping
import io
import json
from pathlib import Path
import re
import sys

from sert import agent
from sert import config as config_mod
from sert import markers as markers_mod
from sert import run as run_mod
from sert import util

BENCH_DIR_REL = ".sert/bench"
DEFAULT_FAIL_REGRESSION_PCT = 20.0
_SAFE_NAME_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]*$")


def _baseline_path(root: Path, name: str) -> Path:
    if not _SAFE_NAME_RE.match(name) or ".." in name:
        raise util.SertError(f"bench: invalid baseline name '{name}' (use letters, digits, '.', '_', '-')")
    return root / BENCH_DIR_REL / f"{name}.json"


def load_baseline(root: Path, name: str) -> list[dict]:
    path = _baseline_path(root, name)
    if not path.is_file():
        raise util.SertError(f"bench: baseline '{name}' not found at {util.posix(path, root)}")
    data = util.load_json(path)
    if isinstance(data, dict) and isinstance(data.get("benchmarks"), list):
        return [dict(row) for row in data["benchmarks"] if isinstance(row, dict)]
    if isinstance(data, list):
        return [dict(row) for row in data if isinstance(row, dict)]
    raise util.SertError(f"bench: invalid baseline format in {util.posix(path, root)}")


def save_baseline(root: Path, name: str, benchmarks: list[dict]) -> Path:
    path = _baseline_path(root, name)
    payload = {"name": name, "benchmarks": benchmarks}
    util.write_atomic(path, (json.dumps(payload, indent=2) + "\n").encode("utf-8"))
    return path


def _baseline_index(baseline: list[dict] | Mapping[str, Mapping] | None) -> dict[str, dict]:
    index: dict[str, dict] = {}
    if baseline is None:
        return index
    if isinstance(baseline, Mapping):
        for key, row in baseline.items():
            if isinstance(row, Mapping):
                index[str(key)] = dict(row)
        return index
    for row in baseline:
        if isinstance(row, Mapping) and row.get("name"):
            name = str(row["name"])
            if row.get("file"):
                index[f"{row['file']}::{name}"] = dict(row)
            index.setdefault(name, dict(row))
    return index


def evaluate_regressions(
    benchmarks: list[dict],
    baseline: list[dict] | Mapping[str, Mapping] | None,
    *,
    fail_regression_pct: float = DEFAULT_FAIL_REGRESSION_PCT,
) -> list[dict]:
    """Compare measured `medianNs` and `allocKb` against `baseline`."""
    if baseline is None:
        return []
    threshold = max(0.0, float(fail_regression_pct)) / 100.0
    base_map = _baseline_index(baseline)
    findings: list[dict] = []

    for row in benchmarks:
        name = str(row.get("name", "(bench)"))
        file_name = str(row.get("file", ""))
        prev = (base_map.get(f"{file_name}::{name}") if file_name else None) or base_map.get(name)
        if prev is None:
            continue

        metrics: list[dict] = []
        for metric_key, label in (("medianNs", "medianNs"), ("allocKb", "allocKb")):
            cur_val = row.get(metric_key)
            prev_val = prev.get(metric_key)
            if (
                isinstance(cur_val, (int, float))
                and not isinstance(cur_val, bool)
                and isinstance(prev_val, (int, float))
                and not isinstance(prev_val, bool)
            ):
                if prev_val > 0:
                    ratio = (float(cur_val) - float(prev_val)) / float(prev_val)
                    if ratio > threshold:
                        metrics.append(
                            {
                                "metric": label,
                                "baseline": float(prev_val),
                                "current": float(cur_val),
                                "pct": ratio * 100.0,
                            }
                        )
                elif label == "allocKb" and prev_val == 0 and float(cur_val) > 0:
                    metrics.append(
                        {
                            "metric": "allocKb",
                            "baseline": 0.0,
                            "current": float(cur_val),
                            "pct": 100.0,
                            "fromZero": True,
                        }
                    )
        if metrics:
            findings.append(
                {
                    "name": name,
                    "file": file_name,
                    "metrics": metrics,
                }
            )
    return findings


def _format_reg_metric(m: Mapping) -> str:
    if m.get("fromZero"):
        return f"{m['metric']} 0.0->{float(m['current']):.1f}KB (+100.0%)"
    return f"{m['metric']} +{m['pct']:.1f}%"


def _format_bench_human(
    benchmarks: list[dict],
    baseline: list[dict] | None,
    regressions: list[dict],
    saved_path: Path | None,
    root: Path,
) -> str:
    if not benchmarks:
        return "bench: no benchmarks executed"

    base_map = _baseline_index(baseline)
    reg_by_key = {(r["file"], r["name"]): r["metrics"] for r in regressions}
    lines: list[str] = []
    for row in benchmarks:
        name = str(row.get("name", "(bench)"))
        f_name = str(row.get("file", ""))
        median_ns = float(row.get("medianNs", 0) or 0)
        iqr_ns = float(row.get("iqrNs", 0) or 0)
        ops = float(row.get("opsPerSec", 0) or 0)
        alloc_kb = float(row.get("allocKb", 0) or 0)
        iters = int(row.get("iterations", 0) or 0)
        samples = int(row.get("samples", 0) or 0)

        suffix_parts: list[str] = []
        prev = (base_map.get(f"{f_name}::{name}") if f_name else None) or base_map.get(name)
        if prev is not None and isinstance(prev.get("medianNs"), (int, float)) and prev["medianNs"] > 0:
            pct = 100.0 * (median_ns - float(prev["medianNs"])) / float(prev["medianNs"])
            suffix_parts.append(f"time {pct:+.1f}%")
        if prev is not None and isinstance(prev.get("allocKb"), (int, float)):
            if prev["allocKb"] > 0:
                apct = 100.0 * (alloc_kb - float(prev["allocKb"])) / float(prev["allocKb"])
                suffix_parts.append(f"alloc {apct:+.1f}%")
            elif prev["allocKb"] == 0 and alloc_kb > 0:
                suffix_parts.append(f"alloc 0.0->{alloc_kb:.1f}KB")
        m_list = reg_by_key.get((f_name, name))
        if m_list:
            tags = ", ".join(_format_reg_metric(m) for m in m_list)
            suffix_parts.append(f"REGRESSION({tags})")

        extra = f" [{' | '.join(suffix_parts)}]" if suffix_parts else ""
        lines.append(
            f"{name}: median={agent._format_ns(median_ns)} iqr={agent._format_ns(iqr_ns)} "
            f"ops={ops:.0f}/s alloc={alloc_kb:.1f}KB iters={iters}x{samples}{extra}"
        )

    if saved_path is not None:
        rel = util.posix(saved_path, root)
        lines.append(f"saved benchmark baseline to {rel}")
    return "\n".join(lines)


def _extract_benchmarks(result: run_mod.RunResult, parsed_list: list[markers_mod.Parsed], root: Path) -> list[dict]:
    rows: list[dict] = []
    for idx, parsed in enumerate(parsed_list):
        default_file = ""
        if idx < len(result.entries):
            raw_entry = result.entries[idx].entry
            entry_path = raw_entry if isinstance(raw_entry, Path) else Path(raw_entry)
            if not entry_path.is_absolute():
                entry_path = root / entry_path
            default_file = util.posix(entry_path, root)
        for item in parsed.benchmarks:
            row = dict(item)
            if not row.get("file") and default_file:
                row["file"] = default_file
            rows.append(row)
    return rows


def run_bench(
    args,
    root: Path | None = None,
    cfg=None,
    *,
    out=None,
    err=None,
) -> tuple[int, list[dict], list[dict]]:
    """Run benchmark specs, save/compare baselines, and return `(exit_code, benchmarks, regressions)`."""
    if cfg is None:
        cfg = config_mod.from_args(args)
    if root is None:
        root = getattr(cfg, "root", None) or config_mod.find_root(getattr(args, "root", None))
    root = Path(root)

    compare_name = getattr(args, "compare", None)
    save_name = getattr(args, "save", None)
    fail_pct = getattr(args, "fail_regression", DEFAULT_FAIL_REGRESSION_PCT)
    if fail_pct is None:
        fail_pct = DEFAULT_FAIL_REGRESSION_PCT
    baseline = load_baseline(root, compare_name) if compare_name else None
    if save_name:
        _baseline_path(root, save_name)

    bench_args = run_mod.make_run_args(
        specs=list(getattr(args, "specs", None) or []),
        filter=getattr(args, "filter", None),
        grep=getattr(args, "grep", None),
        tag=list(getattr(args, "tag", None) or []),
        exclude_tag=list(getattr(args, "exclude_tag", None) or []),
        file=list(getattr(args, "file", None) or []),
        timeout=getattr(args, "timeout", None),
        seed=getattr(args, "seed", None),
        jobs=getattr(args, "jobs", None),
        codegen=True,
        bench=True,
        ci=bool(getattr(args, "ci", False)),
        root=str(root),
        format="human",
        program_args=list(getattr(args, "program_args", None) or []),
    )

    cap_out = io.StringIO()
    cap_err = io.StringIO()
    run_code, result, parsed_list = run_mod.execute_run(bench_args, root, cfg, out=cap_out, err=cap_err)
    benchmarks = _extract_benchmarks(result, parsed_list, root)
    regressions = evaluate_regressions(benchmarks, baseline, fail_regression_pct=float(fail_pct))

    saved_path: Path | None = None
    if save_name and run_code == 0:
        saved_path = save_baseline(root, save_name, benchmarks)

    exit_code = run_code if run_code != 0 else (1 if regressions else 0)
    fmt = agent.output_format(args)
    out_stream = sys.stdout if out is None else out
    err_stream = sys.stderr if err is None else err

    if run_code != 0 and cap_err.getvalue() and fmt == "human":
        err_stream.write(cap_err.getvalue())

    if fmt == "json":
        errors: list[str] = []
        if run_code != 0:
            errors.append((cap_err.getvalue() or cap_out.getvalue() or f"benchmark run exited {run_code}").strip())
        for reg in regressions:
            desc = ", ".join(_format_reg_metric(m) for m in reg["metrics"])
            errors.append(f"regression in {reg['name']}: {desc}")
        out_stream.write(
            agent.json_dumps_compact(
                agent.json_envelope(
                    "bench",
                    exit_code,
                    summary={
                        "benches": len(benchmarks),
                        "regressions": len(regressions),
                        "fail_regression_pct": float(fail_pct),
                    },
                    errors=errors,
                    data={
                        "benchmarks": benchmarks,
                        "baseline": compare_name,
                        "saved": util.posix(saved_path, root) if saved_path else None,
                        "regressions": regressions,
                    },
                )
            )
            + "\n"
        )
    elif fmt == "agent":
        text = agent.format_bench_agent(
            benchmarks,
            baseline=baseline,
            regression_threshold=max(0.0, float(fail_pct)) / 100.0,
        )
        if run_code != 0 and not benchmarks:
            err_detail = (cap_err.getvalue() or cap_out.getvalue()).strip()
            text = f"FAIL benches=0\n{err_detail}" if err_detail else "FAIL benches=0"
        out_stream.write(text + "\n")
    else:
        if run_code != 0 and cap_out.getvalue():
            out_stream.write(cap_out.getvalue())
        text = _format_bench_human(benchmarks, baseline, regressions, saved_path, root)
        if text:
            out_stream.write(text + "\n")

    out_stream.flush()
    return exit_code, benchmarks, regressions


def add_parser(subparsers) -> argparse.ArgumentParser:
    parser = subparsers.add_parser(
        "bench",
        help="execute benchmarks with luau --codegen and compare baselines",
    )
    parser.add_argument("specs", nargs="*", help="optional benchmark spec files or directories")
    parser.add_argument("--filter", default=None, help="only run tests matching substring/pattern")
    parser.add_argument("-g", "--grep", default=None, help="regex filter on full test name")
    parser.add_argument("--save", metavar="NAME", default=None, help="save benchmark results under .sert/bench/NAME.json")
    parser.add_argument("--compare", metavar="NAME", default=None, help="compare against .sert/bench/NAME.json")
    parser.add_argument(
        "--fail-regression",
        type=float,
        default=DEFAULT_FAIL_REGRESSION_PCT,
        metavar="PCT",
        help="fail exit 1 when medianNs or allocKb regresses by more than PCT percent (default: 20)",
    )
    parser.add_argument("--timeout", type=float, default=None, help="per-entry timeout in seconds")
    parser.add_argument("-j", "--jobs", type=int, default=None, help="max parallel entries")
    parser.add_argument("--agent", action="store_true", help="compact AI-agent-friendly benchmark output")
    parser.add_argument("--format", choices=("human", "agent", "json"), default=None, help="output format")
    parser.set_defaults(func=cmd_bench)
    return parser


def cmd_bench(args, root: Path | None = None, cfg=None) -> int:
    code, _benches, _regs = run_bench(args, root, cfg)
    return code
