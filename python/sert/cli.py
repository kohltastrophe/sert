"""`sert <command>`: argparse dispatch over lazily imported command modules.

Every command module defines `add_parser(subparsers[, argv]) -> None` (or `add_<command>_parser`), whose parser sets
`func=main`, and `main(args) -> int`. Only the module of the command being run is imported; `--help` lists every
command from the table below without importing any.
"""

from __future__ import annotations

import argparse
import importlib
import signal
import sys
import threading
import traceback

from sert import VERSION
from sert.util import INFRA, INTERRUPTED, SertError, guarded, interrupt

# name -> (module, one-line help; None hides the command from --help). Order is the order `sert --help` lists them in.
COMMANDS: dict[str, tuple[str, str | None]] = {
    "init": ("sert.fetch", "scaffold sert.toml, tools/sert.py, .luaurc alias, .gitignore and a starter spec"),
    "fetch": ("sert.fetch", "fetch sert, the deps and the tools pinned in sert.toml into .sert/"),
    "check": ("sert.check", "run lint, headless tests with coverage and coverage check in one pass"),
    "run": ("sert.run", "run each headless [test].entries or [test].specs with the pinned luau"),
    "studio": ("sert.studio", "run the suite in a fresh, unattended Roblox Studio"),
    "cloud": ("sert.cloud", "run the suite with Open Cloud Luau Execution, in shards"),
    "lint": ("sert.lint", "luau-lsp, type probes, StyLua, selene, spec registration and stub drift"),
    "coverage": ("sert.coverage", "summarize luau --coverage (LCOV) output"),
    "mutate": ("sert.mutate", "run coverage-guided mutation testing against headless specs"),
    "release": ("sert.release", "dist branch publishing and asset packing (dist, pack)"),
    "pack": ("sert.release", None),
    "dist": ("sert.release", "commit the [dist].paths tree of a revision onto the dist branch"),
}
ROOT_HELP = "project root (default: $SERT_ROOT, else the git toplevel, else the nearest parent with sert.toml)"


def _base_parser() -> tuple[argparse.ArgumentParser, argparse._SubParsersAction]:
    parser = argparse.ArgumentParser(
        prog="sert",
        description=(
            "A test toolkit for Roblox and Luau. "
            "Exit codes: 0 ok, 1 failure, 2 infra or usage, 3 timeout, 130 interrupted."
        ),
    )
    parser.add_argument("--version", action="version", version=f"sert {VERSION}")
    parser.add_argument("--root", metavar="DIR", help=ROOT_HELP)
    subparsers = parser.add_subparsers(dest="command", metavar="<command>")
    return parser, subparsers


def _add_root(parser: argparse.ArgumentParser) -> None:
    """--root on `parser` and on every parser nested under its own subcommands (`release dist`, `release pack`)."""
    if not any("--root" in action.option_strings for action in parser._actions):
        parser.add_argument("--root", metavar="DIR", default=argparse.SUPPRESS, help=ROOT_HELP)
    for action in parser._actions:
        if isinstance(action, argparse._SubParsersAction):
            for child in set(action.choices.values()):
                _add_root(child)


class _Registrar:
    """The `subparsers` a command module sees: its add_parser call gets the table's help, the module docstring as
    the description and a formatter that keeps the docstring's layout (a module's own values win)."""

    def __init__(self, subparsers: argparse._SubParsersAction, help_text: str | None, description: str | None):
        self._subparsers = subparsers
        self._help = help_text
        self._description = description

    def add_parser(self, name: str, **kwargs) -> argparse.ArgumentParser:
        kwargs.pop("help", None)
        if self._help is not None:
            kwargs["help"] = self._help
        kwargs.setdefault("description", self._description)
        kwargs.setdefault("formatter_class", argparse.RawDescriptionHelpFormatter)
        return self._subparsers.add_parser(name, **kwargs)


def _command_of(argv: list[str]) -> str | None:
    skip = False
    for token in argv:
        if skip:
            skip = False
        elif token == "--root":
            skip = True
        elif not token.startswith("-"):
            return token
    return None


def build(argv: list[str]) -> argparse.ArgumentParser:
    parser, subparsers = _base_parser()
    wanted = _command_of(argv)
    for name, (module_name, help_text) in COMMANDS.items():
        if name != wanted:
            if help_text is not None:  # a hidden command stays out of argparse's "invalid choice" list too
                subparsers.add_parser(name, help=help_text)
            continue
        try:
            module = importlib.import_module(module_name)
        except ModuleNotFoundError as err:
            if err.name and (module_name == err.name or module_name.startswith(err.name + ".")):
                raise SertError(f"`sert {name}` is not available in this build: module {module_name} is missing")
            raise
        adder = getattr(module, f"add_{name}_parser", module.add_parser)
        registrar = _Registrar(subparsers, help_text, getattr(adder, "__doc__", None) or module.__doc__)
        code = getattr(adder, "__code__", None)
        if code is not None and code.co_argcount >= 2:
            adder(registrar, list(argv))
        else:
            adder(registrar)
        if name not in subparsers.choices:
            raise SertError(f"{module_name}.add_parser did not register `{name}`")
        _add_root(subparsers.choices[name])
    return parser


def main(argv: list[str] | None = None) -> int:
    """Runs the command in `argv`."""
    streams = sys.stdout, sys.stderr
    for stream in (sys.__stdout__, sys.__stderr__):
        if stream in streams and hasattr(stream, "reconfigure"):
            try:
                stream.reconfigure(encoding="utf-8", errors="replace")
            except (OSError, ValueError):
                pass
    sys.stdout, sys.stderr = guarded(sys.stdout), guarded(sys.stderr)
    on_term = hasattr(signal, "SIGTERM") and threading.current_thread() is threading.main_thread()
    previous = signal.signal(signal.SIGTERM, interrupt) if on_term else None
    try:
        code = _dispatch(list(sys.argv[1:] if argv is None else argv))
        sys.stdout.flush()
        sys.stderr.flush()
        return code
    except KeyboardInterrupt:
        return INTERRUPTED
    finally:
        sys.stdout, sys.stderr = streams
        if on_term:
            signal.signal(signal.SIGTERM, previous)


def _dispatch(argv: list[str]) -> int:
    try:
        parser = build(argv)
        args = parser.parse_args(argv)
        func = getattr(args, "func", None)
        if func is None:
            parser.print_help()
            return INFRA
        return int(func(args) or 0)
    except SertError as err:
        print(f"error: {err}", file=sys.stderr)
        return err.code
    except KeyboardInterrupt:
        return INTERRUPTED
    except Exception:  # a crash is an infrastructure fault, not a test failure (exit 1)
        traceback.print_exc()
        print("error: internal error in sert; please report it", file=sys.stderr)
        return INFRA
