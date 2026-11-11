"""`sert check`: run lint, headless tests with coverage, and coverage check in a single thread-safe pass."""

from __future__ import annotations

import argparse
from concurrent.futures import ThreadPoolExecutor
import io
from pathlib import Path
import sys

from sert import config as config_mod, coverage, lint, run


def _default_cmd_lint(args, root: Path | None = None, cfg=None, *, out=None, err=None) -> int:
    ns = argparse.Namespace(
        root=str(root) if root is not None else getattr(args, "root", None),
        dry_run=getattr(args, "dry_run", False),
        fix=getattr(args, "fix", False),
        skip=list(getattr(args, "skip", None) or []),
        only=getattr(args, "only", None),
    )
    return int(lint.cmd_lint_streams(ns, root=root, cfg=cfg, out=out, err=err) or 0)


if not hasattr(lint, "cmd_lint"):
    lint.cmd_lint = _default_cmd_lint  # type: ignore[attr-defined]


def _build_run_args(args, root: Path | None) -> argparse.Namespace:
    run_args = argparse.Namespace(**(vars(args) if hasattr(args, "__dict__") else {}))
    run_args.coverage = True
    run_args.compact = bool(getattr(args, "compact", False))
    for attr, default in (
        ("codegen", False),
        ("no_codegen", False),
        ("runner", None),
        ("timeout", None),
        ("test_timeout", None),
        ("entry", None),
        ("junit", None),
        ("json_out", None),
        ("specs", []),
        ("filter", None),
        ("grep", []),
        ("exclude", []),
        ("file", []),
        ("failed", False),
        ("watch", False),
        ("repeat", None),
        ("slowest", None),
        ("allow_focused", False),
        ("roblox_globals", False),
        ("ci", False),
        ("fail_fast", False),
        ("list", False),
        ("seed", None),
        ("runs", None),
        ("replay", None),
        ("exhaustive", False),
        ("budget", None),
        ("program_args", []),
    ):
        if not hasattr(run_args, attr):
            setattr(run_args, attr, default)
    if getattr(run_args, "root", None) is None and root is not None:
        run_args.root = str(root)
    return run_args


def _invoke_lint(args, root: Path | None, cfg, out_stream, err_stream) -> int:
    fn = lint.cmd_lint
    code_obj = getattr(fn, "__code__", None)
    if code_obj is not None and ("out" in code_obj.co_varnames or (code_obj.co_flags & 0x08)):
        return int(fn(args, root, cfg, out=out_stream, err=err_stream) or 0)
    return int(fn(args, root, cfg) or 0)


def _invoke_run(run_args, root: Path | None, cfg, out_stream, err_stream) -> int:
    fn = run.cmd_run
    code_obj = getattr(fn, "__code__", None)
    if code_obj is not None and ("out" in code_obj.co_varnames or (code_obj.co_flags & 0x08)):
        return int(fn(run_args, root, cfg, out=out_stream, err=err_stream) or 0)
    return int(fn(run_args, root, cfg) or 0)


def cmd_check(args, root: Path | None = None, cfg: dict | None = None) -> int:
    if cfg is None:
        cfg = config_mod.from_args(args)
    if root is None:
        root = getattr(cfg, "root", None) or config_mod.find_root(getattr(args, "root", None))

    run_args = _build_run_args(args, root)
    can_parallel = (
        lint.cmd_lint is _default_cmd_lint
        and getattr(run.cmd_run, "__module__", "") == "sert.run"
        and not bool(getattr(args, "dry_run", False))
        and not bool(getattr(args, "fix", False))
    )
    if can_parallel:
        lint_out, lint_err = io.StringIO(), io.StringIO()
        run_out, run_err = io.StringIO(), io.StringIO()
        with ThreadPoolExecutor(max_workers=2) as pool:
            lint_fut = pool.submit(_invoke_lint, args, root, cfg, lint_out, lint_err)
            run_fut = pool.submit(_invoke_run, run_args, root, cfg, run_out, run_err)
            lint_code = int(lint_fut.result() or 0)
            if lint_out.getvalue():
                sys.stdout.write(lint_out.getvalue())
                sys.stdout.flush()
            if lint_err.getvalue():
                sys.stderr.write(lint_err.getvalue())
                sys.stderr.flush()
            if lint_code != 0:
                run_fut.cancel()
                return lint_code
            code = int(run_fut.result() or 0)
        if run_out.getvalue():
            sys.stdout.write(run_out.getvalue())
            sys.stdout.flush()
        if run_err.getvalue():
            sys.stderr.write(run_err.getvalue())
            sys.stderr.flush()
        if code != 0:
            return code
    else:
        code = _invoke_lint(args, root, cfg, sys.stdout, sys.stderr)
        if code != 0:
            return code
        code = _invoke_run(run_args, root, cfg, sys.stdout, sys.stderr)
        if code != 0:
            return code

    cov_args = argparse.Namespace(**(vars(args) if hasattr(args, "__dict__") else {}))
    cov_args.diff = getattr(args, "diff", None)
    cov_args.uncovered = bool(getattr(args, "uncovered", False))
    if not hasattr(cov_args, "file"):
        cov_args.file = None
    if not hasattr(cov_args, "min"):
        cov_args.min = None
    if getattr(cov_args, "root", None) is None and root is not None:
        cov_args.root = str(root)

    code = int(coverage.cmd_coverage(cov_args, root, cfg) or 0)
    if code != 0:
        return code

    want_studio = bool(getattr(args, "studio", False)) and not bool(getattr(args, "no_studio", False))
    if want_studio and isinstance(cfg, dict) and "studio" in cfg:
        from sert import studio

        studio_args = argparse.Namespace(**(vars(args) if hasattr(args, "__dict__") else {}))
        studio_args.check = True
        if getattr(studio_args, "root", None) is None and root is not None:
            studio_args.root = str(root)
        studio_fn = getattr(studio, "cmd_studio", None)
        if studio_fn is not None:
            code = int(studio_fn(studio_args, root, cfg) or 0)
        else:
            code = int(studio.main(studio_args) or 0)
        if code != 0:
            return code

    return 0


def add_parser(subparsers) -> None:
    parser = subparsers.add_parser("check")
    parser.add_argument("--diff", nargs="?", const="HEAD", default=None, metavar="REV", help="evaluate coverage over lines modified since REV (default: HEAD)")
    parser.add_argument("--compact", action="store_true", help="suppress passing ✅ lines during the test run")
    parser.add_argument("--uncovered", action="store_true", help="print missed source lines in the coverage summary")
    parser.add_argument("--fix", action="store_true", help="format files with StyLua before checking")
    parser.add_argument("--studio", action="store_true", help="also run `sert studio --check` when [studio] is configured")
    parser.add_argument("--no-studio", action="store_true", help="skip `sert studio --check`")
    parser.set_defaults(func=main)


def main(args) -> int:
    cfg = config_mod.from_args(args)
    return cmd_check(args, cfg.root, cfg)
