"""`sert check`: lint, headless tests with coverage, coverage gate, and closed-loop audit/mutate/Studio verification."""

from __future__ import annotations

import argparse
from concurrent.futures import ThreadPoolExecutor
import contextlib
import io
from pathlib import Path
import sys

from sert import (
    agent,
    audit as audit_mod,
    config as config_mod,
    coverage,
    graph as graph_mod,
    lint,
    markers as markers_mod,
    run,
    util,
)

_ORIG_CMD_LINT = lint.cmd_lint
_ORIG_CMD_RUN = run.cmd_run
_ORIG_EXECUTE_RUN = run.execute_run


def _cfg_table(cfg, section: str) -> dict:
    if hasattr(cfg, "table"):
        val = cfg.table(section)
        return val if isinstance(val, dict) else {}
    if isinstance(cfg, dict):
        val = cfg.get(section)
        return val if isinstance(val, dict) else {}
    return {}


def _build_run_args(
    args,
    root: Path | None,
    cfg=None,
    *,
    affected: str | None = None,
    compact: bool | None = None,
) -> argparse.Namespace:
    fields = dict(vars(args)) if hasattr(args, "__dict__") else {}
    fields["coverage"] = True
    fields["compact"] = bool(getattr(args, "compact", False)) if compact is None else compact
    if affected is not None:
        fields["affected"] = affected
    if root is not None and not fields.get("root"):
        fields["root"] = str(root)
    if "codegen" not in fields and hasattr(cfg, "get"):
        fields["codegen"] = bool(cfg.get("test.codegen", True))
    return run.make_run_args(**fields)


def _call_with_optional_streams(fn, *pos_args, out=None, err=None) -> int:
    code_obj = getattr(fn, "__code__", None)
    if code_obj is not None and ("out" in code_obj.co_varnames or (code_obj.co_flags & 0x08)):
        return int(fn(*pos_args, out=out, err=err) or 0)
    with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
        return int(fn(*pos_args) or 0)


def _invoke_lint(args, root: Path | None, cfg, out_stream, err_stream) -> int:
    return _call_with_optional_streams(lint.cmd_lint, args, root, cfg, out=out_stream, err=err_stream)


def _invoke_stage1_run(
    run_args, root: Path | None, cfg, *, out=None, err=None
) -> tuple[int, run.RunResult, list[markers_mod.Parsed]]:
    out_stream = sys.stdout if out is None else out
    err_stream = sys.stderr if err is None else err
    if run.cmd_run is not _ORIG_CMD_RUN and run.execute_run is _ORIG_EXECUTE_RUN:
        code = _call_with_optional_streams(run.cmd_run, run_args, root, cfg, out=out_stream, err=err_stream)
        out_text = out_stream.getvalue() if isinstance(out_stream, io.StringIO) else ""
        parsed = markers_mod.parse(out_text)
        res = run.RunResult(status=code, entries=[], tests=parsed.tests)
        return code, res, [parsed]
    return run.execute_run(run_args, root, cfg, out=out_stream, err=err_stream)


def _invoke_coverage_stage(
    args, root: Path | None, cfg, diff_rev: str | None, *, force_uncovered: bool = False, stream_output: bool = False
) -> tuple[int, str]:
    cov_args = argparse.Namespace(**(vars(args) if hasattr(args, "__dict__") else {}))
    cov_args.diff = diff_rev
    cov_args.uncovered = bool(getattr(args, "uncovered", False)) or force_uncovered
    if not hasattr(cov_args, "file"):
        cov_args.file = None
    if not hasattr(cov_args, "min"):
        cov_args.min = None
    if getattr(cov_args, "root", None) is None and root is not None:
        cov_args.root = str(root)
    if stream_output:
        code = int(coverage.cmd_coverage(cov_args, root, cfg) or 0)
        return code, ""
    cov_args.agent = True
    cov_args.format = "agent"
    buf_out, buf_err = io.StringIO(), io.StringIO()
    with contextlib.redirect_stdout(buf_out), contextlib.redirect_stderr(buf_err):
        code = int(coverage.cmd_coverage(cov_args, root, cfg) or 0)
    return code, (buf_out.getvalue() + buf_err.getvalue()).strip()


def _has_covered_modified_src(root: Path, cfg, cov_path: Path, diff_rev: str) -> bool:
    if not cov_path.is_file():
        return False
    diff_lines = coverage.git_diff_lines(root, diff_rev)
    if not diff_lines:
        return False
    cov_files = coverage.parse(cov_path, root=root)
    mut_table = _cfg_table(cfg, "mutate")
    cov_table = _cfg_table(cfg, "coverage")
    include = list(util.as_list(mut_table.get("include")) or util.as_list(cov_table.get("include")) or ["src"])
    exclude = list(util.as_list(cov_table.get("exclude")))
    chosen = coverage.chosen_files(cov_files, include, exclude)
    diff_cov = coverage.filter_diff_files(chosen, diff_lines)
    return any(hit for line_map in diff_cov.values() for hit in line_map.values())


def _invoke_mutate_stage(args, root: Path, cfg, cov_path: Path, diff_rev: str) -> dict:
    from sert import mutate

    mut_table = _cfg_table(cfg, "mutate")
    mut_args = argparse.Namespace(
        root=str(root),
        paths=[],
        jobs=getattr(args, "jobs", None),
        timeout=getattr(args, "timeout", None),
        min=mut_table.get("min"),
        max_mutants=None,
        operators=None,
        diff=diff_rev,
        coverage_file=str(cov_path),
        no_coverage_run=True,
        program_args=[],
        agent=True,
        format="agent",
    )
    buf_out, buf_err = io.StringIO(), io.StringIO()
    fn = getattr(mutate, "main", None) or getattr(mutate, "cmd_mutate", None)
    try:
        with contextlib.redirect_stdout(buf_out), contextlib.redirect_stderr(buf_err):
            code = int(fn(mut_args) or 0)
    except util.SertError as err:
        msg = str(err)
        if "no mutable covered statements" in msg.lower():
            return {"name": "mutate", "ok": True, "skipped": True, "output": msg}
        return {"name": "mutate", "ok": False, "output": msg}
    return {"name": "mutate", "ok": code == 0, "output": (buf_out.getvalue() + buf_err.getvalue()).strip()}


def _skipped_counts(root: Path, run_result, parsed_list: list[markers_mod.Parsed]) -> dict[str, int]:
    counts = {reason: 0 for reason in markers_mod.SKIP_REASONS}
    if parsed_list:
        telemetry = run._collect_telemetry(run_result, parsed_list)
        for k, v in (telemetry.get("skippedByReason") or {}).items():
            counts[k] = int(v or 0)
    if sum(counts.values()) == 0:
        tel_path = root / run.LAST_TELEMETRY_REL
        if tel_path.is_file():
            saved = util.load_json(tel_path)
            if isinstance(saved, dict) and isinstance(saved.get("skippedByReason"), dict):
                for k, v in saved["skippedByReason"].items():
                    counts[k] = int(v or 0)
    return counts


def _studio_follow_up_command(args, diff_rev: str | None) -> str:
    parts = ["sert", "studio"]
    if diff_rev is not None:
        parts.extend(["--affected", diff_rev])
    if getattr(args, "studio_id", None):
        parts.extend(["--studio", str(args.studio_id)])
    return " ".join(parts)


def _run_studio_invocation(argv: list[str]) -> tuple[int, str]:
    from sert import studio

    buf_out, buf_err = io.StringIO(), io.StringIO()
    try:
        settings, hooks, problem, *_ = studio.context(argv)
        parser = studio.build_parser(settings, hooks, load_suite_hooks=False)
        opts = parser.parse_args(argv)
        if problem and studio.main is getattr(studio, "_orig_main", studio.main):
            return util.INFRA, str(problem)
        with contextlib.redirect_stdout(buf_out), contextlib.redirect_stderr(buf_err):
            code = int(studio.main(opts) or 0)
    except util.SertError as err:
        return getattr(err, "code", util.INFRA), str(err)
    except SystemExit as exc:
        code = int(exc.code) if isinstance(exc.code, int) else util.INFRA
        return code, (buf_err.getvalue() or buf_out.getvalue()).strip()
    return code, (buf_out.getvalue() + buf_err.getvalue()).strip()


def _invoke_studio_escalation(args, root: Path, diff_rev: str | None, fmt: str) -> dict:
    base_argv = ["--root", str(root)]
    if diff_rev is not None:
        base_argv.extend(["--affected", diff_rev])
    if getattr(args, "studio_id", None):
        base_argv.extend(["--studio", str(args.studio_id)])
    if fmt == "agent":
        base_argv.append("--agent")
    elif fmt == "json":
        base_argv.extend(["--format", "json"])

    warm_code, warm_out = _run_studio_invocation([*base_argv, "--warm"])
    if warm_code == 0:
        return {"name": "studio", "ok": True, "mode": "warm", "output": warm_out}
    if warm_code != util.INFRA:
        return {"name": "studio", "ok": False, "mode": "warm", "output": warm_out or f"warm studio exited {warm_code}"}

    cold_code, cold_out = _run_studio_invocation(base_argv)
    return {
        "name": "studio",
        "ok": cold_code == 0,
        "mode": "cold",
        "fallback_from": "warm",
        "output": cold_out or warm_out,
    }


def _invoke_studio_check(args, root: Path | None, cfg, *, capture: bool) -> tuple[int, dict | None]:
    from sert import studio

    studio_args = argparse.Namespace(**(vars(args) if hasattr(args, "__dict__") else {}))
    studio_args.check = True
    if capture:
        studio_args.agent = False
        studio_args.format = "human"
    if getattr(studio_args, "root", None) is None and root is not None:
        studio_args.root = str(root)
    studio_fn = getattr(studio, "cmd_studio", None)

    def _call() -> int:
        return int((studio_fn(studio_args, root, cfg) if studio_fn is not None else studio.main(studio_args)) or 0)

    if not capture:
        return _call(), None
    st_out, st_err = io.StringIO(), io.StringIO()
    with contextlib.redirect_stdout(st_out), contextlib.redirect_stderr(st_err):
        st_code = _call()
    return st_code, {"name": "studio", "ok": st_code == 0, "output": (st_out.getvalue() + st_err.getvalue()).strip()}


def _build_report(
    checks: list[dict],
    skipped_stages: list[dict],
    skipped_by_reason: dict[str, int],
    *,
    diff_rev: str | None,
    audit_report: dict | None = None,
    follow_up: str | None = None,
) -> dict:
    engine_skipped = sum(skipped_by_reason.get(r, 0) for r in ("roblox", "server", "client"))
    report: dict = {
        "checks": checks,
        "skipped_stages": skipped_stages,
        "skipped_by_reason": skipped_by_reason,
        "engine_skipped": engine_skipped,
        "diff": diff_rev,
    }
    if audit_report is not None:
        report["audit"] = audit_report
    if follow_up is not None:
        report["follow_up_command"] = follow_up
    return report


def _render_check_output(fmt: str, exit_code: int, report: dict, root: Path | None) -> str:
    if fmt == "json":
        checks = report.get("checks", [])
        passed = sum(1 for c in checks if c.get("ok"))
        errors = [f"{c['name']}: {c.get('output', '').strip() or 'failed'}" for c in checks if not c.get("ok")]
        return agent.json_dumps_compact(
            agent.json_envelope(
                "check",
                exit_code,
                summary={
                    "checks": len(checks),
                    "passed": passed,
                    "failed": len(checks) - passed,
                    "engine_skipped": report.get("engine_skipped", 0),
                },
                errors=errors,
                data=report,
            )
        )
    if fmt == "agent":
        text = agent.format_verify_agent(report, root=root)
        skipped_stages = report.get("skipped_stages") or []
        if skipped_stages and exit_code == 0:
            note = ", ".join(f"{s['name']} ({s['reason']})" for s in skipped_stages)
            text = f"{text}\nSKIPPED: {note}"
        return text

    lines: list[str] = []
    for chk in report.get("checks", []):
        status = "PASS" if chk.get("ok") else "FAIL"
        lines.append(f"[{status}] {chk['name']}")
        out_txt = (chk.get("output") or "").strip()
        if out_txt and (not chk.get("ok") or chk["name"] == "studio"):
            lines.append(out_txt)
    for st in report.get("skipped_stages", []):
        lines.append(f"[SKIP] {st['name']}: {st['reason']}")
    lines.append("check: ok" if exit_code == 0 else "check: failed")
    return "\n".join(lines)


def _want_closed_loop(args) -> tuple[bool, str | None, str | None, bool, bool]:
    changed_val = getattr(args, "changed", None)
    diff_val = getattr(args, "diff", None)
    diff_rev = changed_val if changed_val is not None else diff_val
    want_audit = (
        bool(getattr(args, "audit", False))
        or bool(getattr(args, "strict", False))
        or changed_val is not None
    ) and not bool(getattr(args, "no_audit", False))
    want_mutate = (
        bool(getattr(args, "mutate", False))
        or changed_val is not None
    ) and not bool(getattr(args, "no_mutate", False))
    closed_loop = bool(changed_val is not None or want_audit or want_mutate or getattr(args, "strict", False))
    return closed_loop, changed_val, diff_rev, want_audit, want_mutate


def run_check(args, root: Path | None = None, cfg=None) -> tuple[int, dict, bool]:
    """Execute `sert check` (fast 3-stage or closed-loop verification) and return `(exit_code, report, should_print)`."""
    if cfg is None:
        cfg = config_mod.from_args(args)
    if root is None:
        root = getattr(cfg, "root", None) or config_mod.find_root(getattr(args, "root", None))
    check_root = Path(root) if root is not None else None

    fmt = agent.output_format(args)
    closed_loop, changed_val, diff_rev, want_audit, want_mutate = _want_closed_loop(args)
    stream_human = fmt == "human" and not closed_loop
    capture_stage1 = not stream_human

    checks: list[dict] = []
    skipped_stages: list[dict] = []
    can_parallel = (
        lint.cmd_lint is _ORIG_CMD_LINT
        and run.cmd_run is _ORIG_CMD_RUN
        and run.execute_run is _ORIG_EXECUTE_RUN
        and not bool(getattr(args, "dry_run", False))
        and not bool(getattr(args, "fix", False))
    )

    run_args = _build_run_args(
        args,
        check_root,
        cfg,
        affected=changed_val,
        compact=True if closed_loop else None,
    )
    if capture_stage1:
        run_args.agent = True
        run_args.format = "agent"

    if can_parallel:
        lint_out, lint_err = io.StringIO(), io.StringIO()
        run_out, run_err = io.StringIO(), io.StringIO()
        with ThreadPoolExecutor(max_workers=2) as pool:
            lint_fut = pool.submit(_invoke_lint, args, check_root, cfg, lint_out, lint_err)
            run_fut = pool.submit(_invoke_stage1_run, run_args, check_root, cfg, out=run_out, err=run_err)
            lint_code = int(lint_fut.result() or 0)
            if stream_human:
                if lint_out.getvalue():
                    sys.stdout.write(lint_out.getvalue())
                    sys.stdout.flush()
                if lint_err.getvalue():
                    sys.stderr.write(lint_err.getvalue())
                    sys.stderr.flush()
                if lint_code != 0:
                    run_fut.cancel()
                    return lint_code, {"checks": checks}, False
                run_code, run_result, parsed_list = run_fut.result()
                if run_out.getvalue():
                    sys.stdout.write(run_out.getvalue())
                    sys.stdout.flush()
                if run_err.getvalue():
                    sys.stderr.write(run_err.getvalue())
                    sys.stderr.flush()
                if run_code != 0:
                    return run_code, {"checks": checks}, False
            else:
                checks.append({"name": "lint", "ok": lint_code == 0, "output": (lint_out.getvalue() + lint_err.getvalue()).strip()})
                if lint_code != 0:
                    run_fut.cancel()
                    report = _build_report(checks, skipped_stages, {r: 0 for r in markers_mod.SKIP_REASONS}, diff_rev=diff_rev)
                    return 1, report, True
                run_code, run_result, parsed_list = run_fut.result()
                checks.append({"name": "tests", "ok": run_code == 0, "output": (run_out.getvalue() + run_err.getvalue()).strip()})
                if run_code != 0:
                    skips = _skipped_counts(check_root, run_result, parsed_list) if check_root else {}
                    report = _build_report(checks, skipped_stages, skips, diff_rev=diff_rev)
                    return 1, report, True
    else:
        lint_out = sys.stdout if stream_human else io.StringIO()
        lint_err = sys.stderr if stream_human else io.StringIO()
        lint_code = _invoke_lint(args, check_root, cfg, lint_out, lint_err)
        if capture_stage1:
            checks.append({"name": "lint", "ok": lint_code == 0, "output": (lint_out.getvalue() + lint_err.getvalue()).strip()})
        if lint_code != 0:
            if stream_human:
                return lint_code, {"checks": checks}, False
            report = _build_report(checks, skipped_stages, {r: 0 for r in markers_mod.SKIP_REASONS}, diff_rev=diff_rev)
            return 1, report, True

        run_out = sys.stdout if stream_human else io.StringIO()
        run_err = sys.stderr if stream_human else io.StringIO()
        run_code, run_result, parsed_list = _invoke_stage1_run(run_args, check_root, cfg, out=run_out, err=run_err)
        if capture_stage1:
            checks.append({"name": "tests", "ok": run_code == 0, "output": (run_out.getvalue() + run_err.getvalue()).strip()})
        if run_code != 0:
            if stream_human:
                return run_code, {"checks": checks}, False
            skips = _skipped_counts(check_root, run_result, parsed_list) if check_root else {}
            report = _build_report(checks, skipped_stages, skips, diff_rev=diff_rev)
            return 1, report, True

    cov_code, cov_output = _invoke_coverage_stage(
        args,
        check_root,
        cfg,
        diff_rev,
        force_uncovered=closed_loop,
        stream_output=stream_human,
    )
    if stream_human and cov_code != 0:
        return cov_code, {"checks": checks}, False
    if capture_stage1:
        checks.append({"name": "coverage", "ok": cov_code == 0, "output": cov_output})
        if cov_code != 0 and not want_audit:
            skips = _skipped_counts(check_root, run_result, parsed_list) if check_root else {}
            report = _build_report(checks, skipped_stages, skips, diff_rev=diff_rev)
            return 1, report, True

    cov_path = (check_root / str(_cfg_table(cfg, "coverage").get("file") or "coverage.out")) if check_root else Path("coverage.out")
    audit_report: dict | None = None
    audit_code = 0
    if want_audit and check_root is not None:
        audit_specs = (
            graph_mod.affected_specs(check_root, cfg, diff_rev or "HEAD")[0]
            if changed_val is not None
            else list(graph_mod.discover_specs(check_root, cfg))
        )
        audit_code, audit_report = audit_mod.run_audit(
            check_root,
            cfg,
            diff=diff_rev,
            allow_unfuzzed_remotes=bool(getattr(args, "allow_unfuzzed_remotes", False)),
            strict=bool(getattr(args, "strict", False)),
            run_result=run_result,
            parsed_list=parsed_list,
            coverage_file=cov_path,
            specs=audit_specs,
            skip_run=True,
        )
        audit_output = audit_mod._format_audit_output("agent", audit_code, audit_report, root=check_root)
        checks.append({"name": "audit", "ok": audit_code == 0, "output": audit_output})

    skips = _skipped_counts(check_root, run_result, parsed_list) if check_root else {r: 0 for r in markers_mod.SKIP_REASONS}
    if cov_code != 0 or audit_code != 0:
        report = _build_report(checks, skipped_stages, skips, diff_rev=diff_rev, audit_report=audit_report)
        return 1, report, True

    if (want_mutate or getattr(args, "no_mutate", False)) and check_root is not None:
        mut_diff_rev = diff_rev or "HEAD"
        if getattr(args, "no_mutate", False):
            if changed_val is not None or bool(getattr(args, "mutate", False)):
                skipped_stages.append({"name": "mutate", "reason": "--no-mutate"})
        elif not _has_covered_modified_src(check_root, cfg, cov_path, mut_diff_rev):
            skipped_stages.append({"name": "mutate", "reason": "no covered modified src/ lines"})
        else:
            mut_check = _invoke_mutate_stage(args, check_root, cfg, cov_path, mut_diff_rev)
            if mut_check.get("skipped"):
                skipped_stages.append({"name": "mutate", "reason": mut_check.get("output", "skipped")})
            else:
                checks.append(mut_check)
                if not mut_check.get("ok"):
                    report = _build_report(checks, skipped_stages, skips, diff_rev=diff_rev, audit_report=audit_report)
                    return 1, report, True

    engine_skipped = sum(skips.get(r, 0) for r in ("roblox", "server", "client"))
    if changed_val is not None and engine_skipped > 0 and check_root is not None:
        follow_up = _studio_follow_up_command(args, diff_rev)
        if getattr(args, "no_studio", False):
            if getattr(args, "allow_skipped_targets", False):
                skipped_stages.append(
                    {
                        "name": "studio",
                        "reason": f"{engine_skipped} engine-targeted test(s) waived via --allow-skipped-targets; follow-up: {follow_up}",
                    }
                )
            else:
                checks.append(
                    {
                        "name": "studio",
                        "ok": False,
                        "output": (
                            f"{engine_skipped} engine-targeted test(s) skipped "
                            f"(roblox={skips.get('roblox', 0)} "
                            f"server={skips.get('server', 0)} "
                            f"client={skips.get('client', 0)}); "
                            f"run `{follow_up}` or pass --allow-skipped-targets"
                        ),
                    }
                )
                report = _build_report(
                    checks,
                    skipped_stages,
                    skips,
                    diff_rev=diff_rev,
                    audit_report=audit_report,
                    follow_up=follow_up,
                )
                return 1, report, True
        else:
            checks.append(_invoke_studio_escalation(args, check_root, diff_rev, fmt))
    else:
        want_studio = bool(getattr(args, "studio", False)) and not bool(getattr(args, "no_studio", False))
        has_studio_cfg = (isinstance(cfg, dict) and "studio" in cfg) or (
            hasattr(cfg, "raw") and isinstance(cfg.raw, dict) and "studio" in cfg.raw
        )
        if want_studio and has_studio_cfg:
            st_code, st_chk = _invoke_studio_check(args, check_root, cfg, capture=capture_stage1)
            if stream_human:
                return st_code, {"checks": checks}, False
            if st_chk is not None:
                checks.append(st_chk)

    if stream_human:
        return 0, {"checks": checks}, False

    exit_code = 0 if all(c.get("ok") for c in checks) else 1
    report = _build_report(checks, skipped_stages, skips, diff_rev=diff_rev, audit_report=audit_report)
    return exit_code, report, True


def cmd_check(args, root: Path | None = None, cfg: dict | None = None) -> int:
    if cfg is None:
        cfg = config_mod.from_args(args)
    if root is None:
        root = getattr(cfg, "root", None) or config_mod.find_root(getattr(args, "root", None))
    resolved_root = Path(root) if root is not None else None

    exit_code, report, should_print = run_check(args, resolved_root, cfg)
    if should_print:
        rendered = _render_check_output(agent.output_format(args), exit_code, report, resolved_root)
        sys.stdout.write(rendered + "\n")
        sys.stdout.flush()
    return exit_code


def add_parser(subparsers) -> None:
    parser = subparsers.add_parser("check")
    parser.add_argument(
        "--changed",
        nargs="?",
        const="HEAD",
        default=None,
        metavar="REV",
        help="run TIA-affected tests and closed-loop audit/mutate/Studio verification against REV (default: HEAD)",
    )
    parser.add_argument("--diff", nargs="?", const="HEAD", default=None, metavar="REV", help="evaluate coverage and audit over changes since REV (default: HEAD)")
    parser.add_argument("--audit", action="store_true", help="run anti-reward-hacking & uncovered export audit stage")
    parser.add_argument("--no-audit", action="store_true", help="skip audit stage even with --changed or --strict")
    parser.add_argument("--mutate", action="store_true", help="run incremental mutation testing over covered modified src/ lines")
    parser.add_argument("--no-mutate", action="store_true", help="skip incremental mutation testing")
    parser.add_argument("--strict", action="store_true", help="fail audit stage on uncovered public exports (implies --audit)")
    parser.add_argument("--allow-unfuzzed-remotes", action="store_true", help="waive missing remote fuzz coverage in audit")
    parser.add_argument("--allow-skipped-targets", action="store_true", help="allow --no-studio even when roblox/server/client targets were skipped")
    parser.add_argument("--compact", action="store_true", help="suppress passing ✅ lines during the test run")
    parser.add_argument("--uncovered", action="store_true", help="print missed source lines in the coverage summary")
    parser.add_argument("--fix", action="store_true", help="format files with StyLua before checking")
    parser.add_argument("--studio", action="store_true", help="also run `sert studio --check` when [studio] is configured")
    parser.add_argument("--no-studio", action="store_true", help="skip Studio execution")
    parser.add_argument("--studio-id", default=None, metavar="ID", help="target a specific warm Roblox Studio instance")
    parser.add_argument("--timeout", type=float, default=None, help="per-entry timeout in seconds")
    parser.add_argument("-j", "--jobs", type=int, default=None, help="max parallel entries")
    parser.add_argument("--ci", action="store_true", help="run in CI mode")
    parser.add_argument("--agent", action="store_true", help="token-efficient summary for AI agents")
    parser.add_argument(
        "--format",
        choices=("human", "agent", "json"),
        default=None,
        help="output format (default: human; or agent when SERT_AGENT=1)",
    )
    parser.set_defaults(func=main)


def main(args) -> int:
    cfg = config_mod.from_args(args)
    return cmd_check(args, cfg.root, cfg)
