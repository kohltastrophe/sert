"""Shared CLI helpers: exit codes, errors, JSONC parsing, Rokit tool lookup, and path utilities."""

from __future__ import annotations

import errno
import json
import math
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import time

OK = 0
FAILED = 1
INFRA = 2
TIMEOUT = 3
INTERRUPTED = 130


class SertError(Exception):
    def __init__(self, message: str, code: int = INFRA):
        super().__init__(message)
        self.code = code


def warn(message: str, *, err=None) -> None:
    stream = sys.stderr if err is None else err
    print(f"warning: {message}", file=stream, flush=True)


def note(message: str, *, err=None) -> None:
    stream = sys.stderr if err is None else err
    print(message, file=stream, flush=True)


def is_ci() -> bool:
    return os.environ.get("CI", "").strip().lower() in ("1", "true", "yes")


def command(rest: str) -> str:
    if os.environ.get("SERT_ROOT"):
        return f"{os.environ.get('SERT_PYTHON') or 'python3'} tools/sert.py {rest}"
    return f"sert {rest}"


_JSONC_COMMENT_OR_STRING = re.compile(
    r'("(?:\\.|[^"\\])*")|//[^\r\n]*|/\*[\s\S]*?\*/',
)
_JSONC_TRAILING_COMMA = re.compile(r'("(?:\\.|[^"\\])*")|,(\s*[}\]])')


def strip_jsonc(text: str) -> str:
    """Strip JSONC // line comments, /* */ block comments, and trailing commas while preserving strings."""
    if text.startswith("\ufeff"):
        text = text[1:]

    def _replace_comment(match: re.Match[str]) -> str:
        if match.group(1) is not None:
            return match.group(1)
        # Preserve newline count so JSONDecodeError line numbers match the original file.
        newlines = match.group(0).count("\n")
        return "\n" * newlines if newlines else " "

    without_comments = _JSONC_COMMENT_OR_STRING.sub(_replace_comment, text)
    return _JSONC_TRAILING_COMMA.sub(
        lambda m: m.group(1) if m.group(1) is not None else m.group(2),
        without_comments,
    )


strip_trailing_commas = strip_jsonc


def load_json(path: str | Path):
    try:
        with open(path, encoding="utf-8-sig") as handle:
            return json.loads(strip_jsonc(handle.read()))
    except (OSError, ValueError):
        return None


def sert_alias_key(aliases: dict) -> str | None:
    return next((key for key in aliases if isinstance(key, str) and key.lower() == "sert"), None)


def sert_alias(root: Path):
    data = load_json(root / ".luaurc")
    aliases = data.get("aliases") if isinstance(data, dict) else None
    key = sert_alias_key(aliases) if isinstance(aliases, dict) else None
    return None if key is None else aliases[key]


_LUAU_ESCAPES = {"\\": "\\\\", '"': '\\"', "\n": "\\n", "\r": "\\r", "\t": "\\t"}


def luau_string(text: str) -> str:
    out = ['"']
    for char in text:
        code = ord(char)
        if char in _LUAU_ESCAPES:
            out.append(_LUAU_ESCAPES[char])
        elif code < 0x20 or code == 0x7F:
            out.append(f"\\{code:03d}")
        elif code < 0x80:
            out.append(char)
        else:
            out.append(f"\\u{{{0xFFFD if 0xD800 <= code <= 0xDFFF else code:X}}}")
    out.append('"')
    return "".join(out)


def rokit_bin_dirs() -> list[str]:
    dirs: list[str] = []
    if rokit_root := os.environ.get("ROKIT_ROOT"):
        candidate = os.path.join(os.path.expanduser(rokit_root), "bin")
        if os.path.isdir(candidate):
            dirs.append(candidate)
    default_rokit = os.path.expanduser(os.path.join("~", ".rokit", "bin"))
    if os.path.isdir(default_rokit) and default_rokit not in dirs:
        dirs.append(default_rokit)
    return dirs


def tool_search_path() -> str:
    parts = [p for p in [os.environ.get("PATH", ""), *rokit_bin_dirs()] if p]
    return os.pathsep.join(parts)


def which(name: str, root: Path | None = None) -> str | None:
    if root is not None:
        names = (f"{name}.exe", f"{name}.cmd", f"{name}.bat") if os.name == "nt" else (name, f"{name}.exe")
        for candidate_name in names:
            candidate = root / ".sert" / "bin" / candidate_name
            if candidate.is_file() and os.access(candidate, os.X_OK):
                return str(candidate)
    search_path = tool_search_path() or None
    if found := shutil.which(name, path=search_path):
        return found
    if name == "stylua":
        return shutil.which("StyLua", path=search_path)
    return None


def need(name: str, root: Path | None = None) -> str:
    if found := which(name, root):
        return found
    raise SertError(f"{name} not found on PATH or ~/.rokit/bin (run `rokit install` to install tools from rokit.toml)")


def git(root: Path, *args: str, env: dict | None = None, check: bool = True, input: str | None = None) -> str:
    result = subprocess.run(
        ["git", "-C", str(root), *args],
        capture_output=True,
        encoding="utf-8",
        errors="replace",
        env=env,
        input=input,
        timeout=120,
    )
    if check and result.returncode != 0:
        raise SertError(f"git {' '.join(args)} failed: {result.stderr.strip()}")
    return result.stdout.rstrip("\n")


def posix(path: Path, root: Path) -> str:
    try:
        return path.resolve().relative_to(root.resolve()).as_posix()
    except ValueError:
        return path.as_posix()


def write_atomic(path: Path, data: bytes, mode: int | None = None) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    handle = tempfile.NamedTemporaryFile(dir=path.parent, prefix=f".{path.name}.", delete=False)
    try:
        with handle:
            handle.write(data)
        if mode is not None:
            os.chmod(handle.name, mode)
        os.replace(handle.name, path)
    except BaseException:
        try:
            os.unlink(handle.name)
        except OSError:
            pass
        raise


def as_list(value) -> list:
    return [] if value is None else (list(value) if isinstance(value, (list, tuple)) else [value])


def check_selection(opts) -> None:
    for flag, least in (("runs", 1), ("replay", 0)):
        if (value := getattr(opts, flag, None)) is not None and value < least:
            raise SertError(f"--{flag} takes a whole number from {least}, got {value}")
    if (budget := getattr(opts, "budget", None)) is not None and not 0 < budget < math.inf:
        raise SertError(f"--budget takes a number of seconds above 0, got {budget:g}")


def interrupt(signum, frame):
    raise KeyboardInterrupt


class OutputClosed(KeyboardInterrupt):
    pass


class Guarded:
    def __init__(self, stream):
        self.stream = stream
        self._silenced = False

    def write(self, text: str):
        try:
            return self._guard(self.stream.write, text)
        except UnicodeEncodeError:
            encoding = getattr(self.stream, "encoding", None) or "utf-8"
            safe = text.encode(encoding, errors="replace").decode(encoding, errors="replace")
            return self._guard(self.stream.write, safe)

    def flush(self) -> None:
        self._guard(self.stream.flush)

    def _guard(self, call, *args):
        try:
            return call(*args)
        except OSError as err:
            if not isinstance(err, BrokenPipeError) and not (os.name == "nt" and err.errno == errno.EINVAL):
                raise
            if self._silenced:
                return None
            self._silenced = True
            raise OutputClosed from None


def guarded(stream):
    return stream if isinstance(stream, Guarded) else Guarded(stream)


def worst(codes) -> int:
    codes = list(codes)
    for code in (INTERRUPTED, INFRA, TIMEOUT, FAILED):
        if code in codes:
            return code
    return max(codes or [OK])


def build_place(root, project: str | Path, output: str | Path, *, quiet: bool = False) -> float | None:
    env = dict(os.environ, PATH=tool_search_path())
    if not quiet:
        print(f"rojo build {project} -> {output}", flush=True)
    started = time.monotonic()
    try:
        rojo = need("rojo", Path(root))
        built = subprocess.run(
            [rojo, "build", str(project), "--output", str(output)],
            cwd=str(root),
            env=env,
            capture_output=quiet,
            encoding="utf-8" if quiet else None,
            errors="replace" if quiet else None,
            timeout=300,
        )
    except (SertError, OSError, subprocess.TimeoutExpired) as err:
        note(f"cannot run rojo: {err}")
        return None
    if built.returncode != 0:
        if quiet:
            sys.stderr.write((built.stdout or "") + (built.stderr or ""))
        note(f"rojo build {project} failed (exit {built.returncode})")
        return None
    return time.monotonic() - started


GLOB_CHARS = frozenset("*?[")


def has_glob(pattern: str) -> bool:
    return bool(GLOB_CHARS & set(pattern))


def expand_globs(root: Path, patterns, files: bool = False, missing: list | None = None) -> list[Path]:
    found: dict[str, Path] = {}
    for pattern in map(str, as_list(patterns)):
        pattern = pattern.replace("\\", "/")
        matches = (
            list(root.glob(pattern.rstrip("/")))
            if has_glob(pattern)
            else ([target] if (target := root / pattern).exists() else [])
        )
        if files:
            matches = [path for path in matches if path.is_file()]
        if not matches and missing is not None:
            missing.append(pattern)
        for path in matches:
            found.setdefault(posix(path, root), path)
    return [found[key] for key in sorted(found)]


def _escape_data(text: str) -> str:
    return text.replace("%", "%25").replace("\r", "%0D").replace("\n", "%0A")


def _escape_property(text: str) -> str:
    return _escape_data(text).replace(":", "%3A").replace(",", "%2C")


def on_github_actions() -> bool:
    return os.environ.get("GITHUB_ACTIONS", "").strip().lower() == "true"


def annotate(
    kind: str,
    message: str,
    file: str | None = None,
    line: int | None = None,
    title: str | None = None,
    *,
    out=None,
) -> bool:
    if not on_github_actions():
        return False
    props = []
    if file:
        norm_file = str(file).replace("\\", "/")
        props.append(f"file={_escape_property(norm_file)}")
        if line:
            props.append(f"line={int(line)}")
    if title:
        props.append(f"title={_escape_property(title)}")
    stream = sys.stdout if out is None else out
    print(f"::{kind}{' ' + ','.join(props) if props else ''}::{_escape_data(message)}", file=stream, flush=True)
    return True


def step_summary(markdown: str) -> bool:
    if not (path := os.environ.get("GITHUB_STEP_SUMMARY")):
        return False
    try:
        with open(path, "a", encoding="utf-8") as handle:
            handle.write(markdown if markdown.endswith("\n") else markdown + "\n")
    except OSError as err:
        warn(f"cannot write the step summary {path}: {err}")
        return False
    return True
