"""`sert check`: run lint, headless tests with coverage, and coverage check in a single pass."""

from __future__ import annotations

import argparse
from concurrent.futures import ThreadPoolExecutor
import contextlib
import io
from pathlib import Path
import sys

from sert import config as config_mod, coverage, lint, run, studio


def _default_cmd_lint(args, root: Path | None = None, cfg=None) -> int:
    ns = argparse.Namespace(
        root=str(root) if root is not None else getattr(args, "root", None),
        dry_run=getattr(args, "dry_run", False),
        skip=list(getattr(args, "skip", None) or []),
        only=getattr(args, "only", None),
    )
    return int(lint.main(ns) or 0)


def _default_cmd_studio(args, root: Path | None = None, cfg=None) -> int:
    ns = argparse.Namespace(**vars(args)) if hasattr(args, "__dict__") else argparse.Namespace()
    if root is not None and getattr(ns, "root", None) is None:
        ns.root = str(root)
    ns.check = True
    return int(studio.main(ns) or 0)


if not hasattr(lint, "cmd_lint"):
    lint.cmd_lint = _default_cmd_lint  # type: ignore[attr-defined]
if not hasattr(studio, "cmd_studio"):
    studio.cmd_studio = _default_cmd_studio  # type: ignore[attr-defined]


def _build_run_args(args, root: Path | None) -> argparse.Namespace:
    run_args = argparse.Namespace(**(vars(args) if hasattr(args, "__dict__") else {}))
    run_args.coverage = True
    run_args.compact = bool(getattr(args, "compact", False))
    for attr, default in (
        ("codegen", False),
        ("no_codegen", False),
        ("timeout", None),
        ("entry", None),
        ("junit", None),
        ("json_out", None),
        ("specs", []),
        ("filter", None),
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
    )
    if can_parallel:
        run_out, run_err = io.StringIO(), io.StringIO()

        def _run_buffered() -> int:
            with contextlib.redirect_stdout(run_out), contextlib.redirect_stderr(run_err):
                return int(run.cmd_run(run_args, root, cfg) or 0)

        with ThreadPoolExecutor(max_workers=2) as pool:
            lint_fut = pool.submit(lint.cmd_lint, args, root, cfg)
            run_fut = pool.submit(_run_buffered)
            lint_code = int(lint_fut.result() or 0)
            if lint_code != 0:
                run_fut.cancel()
                return lint_code
            code = int(run_fut.result() or 0)
        if run_out.getvalue():
            sys.stdout.write(run_out.getvalue())
        if run_err.getvalue():
            sys.stderr.write(run_err.getvalue())
        if code != 0:
            return code
    else:
        code = int(lint.cmd_lint(args, root, cfg) or 0)
        if code != 0:
            return code
        code = int(run.cmd_run(run_args, root, cfg) or 0)
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
        studio_args = argparse.Namespace(**(vars(args) if hasattr(args, "__dict__") else {}))
        studio_args.check = True
        if getattr(studio_args, "root", None) is None and root is not None:
            studio_args.root = str(root)
        code = int(studio.cmd_studio(studio_args, root, cfg) or 0)
        if code != 0:
            return code

    return 0


def add_parser(subparsers) -> None:
    parser = subparsers.add_parser("check")
    parser.add_argument("--diff", nargs="?", const="HEAD", default=None, metavar="REV", help="evaluate coverage over lines modified since REV (default: HEAD)")
    parser.add_argument("--compact", action="store_true", help="suppress passing ✅ lines during the test run")
    parser.add_argument("--uncovered", action="store_true", help="print missed source lines in the coverage summary")
    parser.add_argument("--studio", action="store_true", help="also run `sert studio --check` when [studio] is configured")
    parser.add_argument("--no-studio", action="store_true", help="skip `sert studio --check`")
    parser.set_defaults(func=main)


def main(args) -> int:
    cfg = config_mod.from_args(args)
    return cmd_check(args, cfg.root, cfg)
