"""`sert <command>`: argparse dispatch over lazily imported command modules."""

from __future__ import annotations

import argparse
import importlib
import os
import signal
import sys
import threading
import traceback

from sert import VERSION
from sert.util import INFRA, INTERRUPTED, OutputClosed, SertError, guarded, interrupt

COMMANDS: dict[str, tuple[str, str | None]] = {
    "init": ("sert.fetch", "scaffold sert.toml, rokit.toml, tools/sert.py, .luaurc, .gitignore, and a starter spec"),
    "fetch": ("sert.fetch", "download and SHA-256 verify sert and globalTypes into .sert/ and sert.lock"),
    "check": ("sert.check", "run lint, headless tests with coverage, and coverage check in one pass"),
    "run": ("sert.run", "run headless Luau specs with luau, lute, or lune"),
    "studio": ("sert.studio", "run specs in Roblox Studio"),
    "cloud": ("sert.cloud", "run specs in parallel shards on Open Cloud Luau Execution"),
    "lint": ("sert.lint", "run luau-lsp, type probes, StyLua (--fix), selene, and stub checks"),
    "coverage": ("sert.coverage", "summarize luau --coverage (LCOV) output"),
    "mutate": ("sert.mutate", "run token-stream coverage-guided mutation testing"),
}
ROOT_HELP = "project root (default: $SERT_ROOT, else git toplevel, else nearest parent with sert.toml)"


def _base_parser() -> tuple[argparse.ArgumentParser, argparse._SubParsersAction]:
    parser = argparse.ArgumentParser(
        prog="sert",
        description=(
            "Testing and deterministic simulation toolkit for Roblox and Luau. "
            "Exit codes: 0 ok, 1 failure, 2 infra or usage, 3 timeout, 130 interrupted."
        ),
    )
    parser.add_argument("--version", action="version", version=f"sert {VERSION}")
    parser.add_argument("--root", metavar="DIR", help=ROOT_HELP)
    subparsers = parser.add_subparsers(dest="command", metavar="<command>")
    return parser, subparsers


def _add_root(parser: argparse.ArgumentParser) -> None:
    if not any("--root" in action.option_strings for action in parser._actions):
        parser.add_argument("--root", metavar="DIR", default=argparse.SUPPRESS, help=ROOT_HELP)
    for action in parser._actions:
        if isinstance(action, argparse._SubParsersAction):
            for child in set(action.choices.values()):
                _add_root(child)


class _Registrar:
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
            if help_text is not None:
                subparsers.add_parser(name, help=help_text)
            continue
        try:
            module = importlib.import_module(module_name)
        except ModuleNotFoundError as err:
            if err.name and (module_name == err.name or module_name.startswith(err.name + ".")):
                raise SertError(f"`sert {name}` is not available in this build: module {module_name} is missing")
            raise
        specific_attr = f"add_{name}_parser"
        attr_name = specific_attr if hasattr(module, specific_attr) else "add_parser"
        adder = getattr(module, attr_name, None)
        if adder is None:
            raise SertError(f"{module_name} has no parser registration function for `{name}`")
        registrar = _Registrar(subparsers, help_text, getattr(adder, "__doc__", None) or module.__doc__)
        code = getattr(adder, "__code__", None)
        if code is not None and code.co_argcount >= 2:
            # Some modules accept (subparsers, parents) (`fetch`), while `studio` accepts (subparsers, argv).
            varnames = code.co_varnames[: code.co_argcount]
            if len(varnames) >= 2 and varnames[1] == "parents":
                adder(registrar, [])
            else:
                adder(registrar, list(argv))
        else:
            adder(registrar)
        if name not in subparsers.choices:
            fn_label = attr_name if getattr(adder, "__name__", "<lambda>") == "<lambda>" else adder.__name__
            raise SertError(f"{module_name}.{fn_label} did not register `{name}`")
        _add_root(subparsers.choices[name])
    return parser


def main(argv: list[str] | None = None) -> int:
    argv = list(sys.argv[1:] if argv is None else argv)
    old_sigterm = None
    if threading.current_thread() is threading.main_thread() and hasattr(signal, "SIGTERM"):
        old_sigterm = signal.signal(signal.SIGTERM, interrupt)
    try:
        parser = build(argv)
        args = parser.parse_args(argv)
        if not getattr(args, "command", None):
            parser.print_help()
            return INFRA
        sys.stdout = guarded(sys.stdout)  # type: ignore[assignment]
        sys.stderr = guarded(sys.stderr)  # type: ignore[assignment]
        return int(args.func(args) or 0)
    except OutputClosed:
        return INTERRUPTED
    except KeyboardInterrupt:
        print("sert: interrupted", file=sys.stderr)
        return INTERRUPTED
    except SertError as err:
        print(f"sert: {err}", file=sys.stderr)
        return err.code
    except Exception as err:
        if os.environ.get("SERT_TRACEBACK"):
            traceback.print_exc()
        else:
            print(
                f"sert: internal error in sert ({type(err).__name__}: {err}); set SERT_TRACEBACK=1 for traceback",
                file=sys.stderr,
            )
        return INFRA
    finally:
        if old_sigterm is not None:
            signal.signal(signal.SIGTERM, old_sigterm)
