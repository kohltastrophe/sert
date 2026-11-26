"""`sert lint [--fix] [--dry-run] [--skip CHECK] [--only CHECK]`: run configured static checks."""

from __future__ import annotations

import argparse
from concurrent.futures import ThreadPoolExecutor
import hashlib
import json
import os
from pathlib import Path
import pkgutil
import re
import shutil
import subprocess
import sys
import tempfile

from sert import agent, config as config_mod
from sert.util import FAILED, SertError, annotate, as_list, expand_globs, need, note, posix, supported_kwargs, write_atomic

CHECKS = ("sourcemap", "analyze", "types", "stylua", "selene", "extra", "stub")
SOLVERS = {"new": True, "old": False}
LOCATION = re.compile(r"^(?P<path>[^(\n]+?\.luau)\((?P<line>\d+),\d+\): ")
_CATEGORY = re.compile(r"^([A-Z][A-Za-z0-9]*): ")
CHATTER = ("[INFO] Loading definitions file", "[WARN] client does not allow didChangeWatchedFiles")
MARK = "-- expect-error"


def solvers(values) -> list[str]:
    out = [str(v) for v in as_list(values)] or ["new"]
    for solver in out:
        if solver not in SOLVERS:
            raise SertError(f"unknown solver {solver!r} (use new and/or old)")
    return out


def lint_project(cfg: config_mod.Config) -> str | None:
    project = cfg.get("lint.project")
    if project is False:
        return None
    if project:
        return str(project)
    return "default.project.json" if (cfg.root / "default.project.json").is_file() else None


_SOURCEMAP_SKIP_DIRS = frozenset({".git", ".sert", "node_modules", "__pycache__", ".venv", "venv"})


def _sourcemap_fingerprint(root: Path, project: str, rojo_bin: str) -> str:
    h = hashlib.sha256()
    h.update(f"v1|{rojo_bin}|{project}".encode("utf-8"))
    for cand in (Path(rojo_bin), root / project):
        try:
            st = cand.stat()
            h.update(f"|{cand.name}:{st.st_mtime_ns}:{st.st_size}".encode("utf-8"))
        except OSError:
            h.update(f"|{cand.name}:missing".encode("utf-8"))
    for cur, dirs, files in os.walk(root):
        dirs[:] = sorted(d for d in dirs if d not in _SOURCEMAP_SKIP_DIRS)
        cur_path = Path(cur)
        for name in sorted(files):
            if name.endswith((".luau", ".lua", ".project.json", ".meta.json")):
                fp = cur_path / name
                try:
                    st_f = fp.stat()
                    h.update(f"|F:{fp.relative_to(root).as_posix()}:{st_f.st_mtime_ns}:{st_f.st_size}".encode("utf-8"))
                except OSError:
                    continue
    return h.hexdigest()


class Workspace:
    def __init__(self, cfg: config_mod.Config, dry_run: bool = False, *, err=None):
        self.cfg = cfg
        self.dry_run = dry_run
        self._err = err
        self._tmp = tempfile.TemporaryDirectory(prefix="sert-lsp-")
        self.dir = Path(self._tmp.name)
        self.sourcemap: Path | None = None
        self._built: tuple[list[str], bool] | None = None

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        self._tmp.cleanup()

    def settings(self, solver: str) -> Path:
        path = self.dir / f"{solver}-solver.json"
        if not path.exists():
            path.write_text(json.dumps({"luau-lsp.fflags.enableNewSolver": SOLVERS[solver]}), encoding="utf-8")
        return path

    def project(self) -> str | None:
        return lint_project(self.cfg)

    def build_sourcemap(self) -> tuple[list[str], bool]:
        if self._built is None:
            self._built = self._build_sourcemap()
        return self._built

    def _build_sourcemap(self) -> tuple[list[str], bool]:
        project = self.project()
        if project is None:
            return [], True
        target = self.dir / "sourcemap.json"
        rojo_bin = "rojo" if self.dry_run else need("rojo", self.cfg.root)
        command = [rojo_bin, "sourcemap", project, "--absolute", "--include-non-scripts", "--output", str(target)]
        if not self.dry_run:
            cache_sm = self.cfg.root / ".sert" / "sourcemap.json"
            cache_meta = self.cfg.root / ".sert" / "sourcemap-meta.json"
            fp = _sourcemap_fingerprint(self.cfg.root, project, rojo_bin)
            try:
                meta = json.loads(cache_meta.read_text(encoding="utf-8")) if cache_meta.is_file() else {}
            except (OSError, ValueError):
                meta = {}
            if isinstance(meta, dict) and meta.get("fingerprint") == fp and meta.get("project") == project and cache_sm.is_file():
                try:
                    shutil.copyfile(cache_sm, target)
                    self.sourcemap = target
                    return [], True
                except OSError:
                    pass
            result = subprocess.run(
                command,
                cwd=self.cfg.root,
                capture_output=True,
                text=True,
                encoding="utf-8",
                errors="replace",
                timeout=300,
            )
            if result.returncode != 0:
                note(result.stdout + result.stderr, err=self._err)
                return command, False
            self.sourcemap = target
            try:
                if target.is_file():
                    write_atomic(cache_sm, target.read_bytes())
                    write_atomic(
                        cache_meta,
                        (json.dumps({"project": project, "fingerprint": fp}, separators=(",", ":")) + "\n").encode("utf-8"),
                    )
            except OSError:
                pass
            return command, True
        self.sourcemap = target
        return command, True

    def analyze_command(
        self,
        solver: str,
        defs: Path | None,
        files,
        ignore=(),
        platform: str | None = None,
        definitions=(),
        sourcemap: bool = True,
    ) -> list[str]:
        lsp = "luau-lsp" if self.dry_run else need("luau-lsp", self.cfg.root)
        command = [lsp, "analyze", f"--settings={self.settings(solver)}"]
        if defs is not None:
            command.append(f"--defs={defs}")
        command += [f"--defs={extra}" for extra in definitions]
        if platform:
            command.append(f"--platform={platform}")
        if sourcemap and self.sourcemap is not None:
            command.append(f"--sourcemap={self.sourcemap}")
        command += [f"--ignore={glob}" for glob in ignore]
        return command + [str(f) for f in files]


def without_chatter(output: str) -> str:
    return "".join(line for line in output.splitlines(keepends=True) if not line.startswith(CHATTER))


def run_analyze(cfg: config_mod.Config, command: list[str]) -> tuple[int, str]:
    result = subprocess.run(
        command,
        cwd=cfg.root,
        capture_output=True,
        text=True,
        encoding="utf-8",
        errors="replace",
        timeout=300,
    )
    return result.returncode, without_chatter(result.stdout + result.stderr)


def diagnostics(cfg: config_mod.Config, output: str) -> list[tuple[str, int, str]]:
    found = []
    root = cfg.root.resolve()
    for text in output.splitlines():
        if not (match := LOCATION.match(text)):
            continue
        path = Path(match["path"])
        name = (posix(path, root) if path.is_absolute() else path.as_posix()).removeprefix("./")
        found.append((name, int(match["line"]), text[match.end() :].strip()))
    return found


def is_lint(message: str) -> bool:
    match = _CATEGORY.match(message)
    return bool(match) and not match[1].endswith("Error")


def error_lines(cfg: config_mod.Config, output: str, errors_only: bool = False) -> dict[str, set[int]]:
    lines: dict[str, set[int]] = {}
    for name, line, message in diagnostics(cfg, output):
        if not (errors_only and is_lint(message)):
            lines.setdefault(name, set()).add(line)
    return lines


def expected_lines(text: str) -> set[int]:
    return {number for number, line in enumerate(text.split("\n"), 1) if MARK in line}


def probe_files(cfg: config_mod.Config) -> tuple[list[Path], list[Path]]:
    table = cfg.table("types")
    passing, failing = [], []
    for key, glob_pat, target in (("pass", "*.luau", passing), ("fail", "**/*.luau", failing)):
        for directory in as_list(table.get(key)):
            path = cfg.root / str(directory)
            if not path.is_dir():
                raise SertError(f"[types].{key}: {directory} is not a directory")
            target += expand_globs(cfg.root, [f"{posix(path, cfg.root)}/{glob_pat}"], files=True)
    return passing, failing


def compare(name: str, expected: set[int], found: set[int], solver: str) -> str | None:
    if not expected:
        return f"error: {name} is in [types].fail but has no `{MARK}` lines"
    if expected == found:
        return None
    return f"error: under the {solver} solver, {name} should fail to type-check on lines {sorted(expected)}, but failed on {sorted(found)}"


def _prepare_type_probe_commands(
    cfg: config_mod.Config,
    ws: Workspace,
    defs: Path,
    passing: list[Path],
    failing: list[Path],
    chosen: list[str],
) -> list[tuple[str, str, list[str]]]:
    pass_ignores = default_ignores(cfg)
    fail_ignores = [".sert/**", *[str(g) for g in as_list(cfg.get("lint.ignore"))]]
    tasks: list[tuple[str, str, list[str]]] = []
    for solver in chosen:
        ws.settings(solver)
        if passing:
            cmd = ws.analyze_command(solver, defs, [posix(p, cfg.root) for p in passing], ignore=pass_ignores)
            tasks.append((solver, "pass", cmd))
        if failing:
            cmd = ws.analyze_command(solver, defs, [posix(p, cfg.root) for p in failing], ignore=fail_ignores)
            tasks.append((solver, "fail", cmd))
    return tasks


def _evaluate_type_probe_results(
    cfg: config_mod.Config,
    passing: list[Path],
    failing: list[Path],
    chosen: list[str],
    results_map: dict[tuple[str, str], tuple[int, str]],
    err,
    annot_out,
    *,
    diags: list[dict] | None = None,
    emit_annotations: bool = True,
) -> int:
    status = 0
    passing_names = {posix(p, cfg.root) for p in passing}
    failing_names = {posix(p, cfg.root) for p in failing}

    def _rec(solver: str, file: str, line: int | None, msg: str) -> None:
        if diags is not None:
            diags.append({"tool": f"types:{solver}", "file": file, "line": int(line or 0), "message": msg})

    def _report_outside(
        kind: str,
        solver: str,
        code: int,
        output: str,
        lines: dict[str, set[int]],
        allowed_names: set[str],
        reported: bool,
    ) -> bool:
        outside = {k: v for k, v in lines.items() if k not in allowed_names and v}
        if not (outside or (kind == "pass" and code != 0 and not reported)):
            return False
        for name, err_lns in sorted(outside.items()):
            msg = f"unexpected errors during [types].{kind} under the {solver} solver (lines {sorted(err_lns)})"
            err(f"error: {name} reported {'errors' if kind == 'pass' else 'unexpected errors'} during [types].{kind} under the {solver} solver (lines {sorted(err_lns)})")
            for line in sorted(err_lns):
                _rec(solver, name, line, msg)
        if kind == "pass" and not outside:
            msg = f"luau-lsp analyze failed (exit {code}) during [types].pass under the {solver} solver"
            err(f"error: {msg}")
            _rec(solver, "", 0, msg)
        if not reported:
            err(output)
        return True

    for solver in chosen:
        if passing:
            code, output = results_map[(solver, "pass")]
            lines = error_lines(cfg, output)
            reported = False
            for path in passing:
                name = posix(path, cfg.root)
                if lines.get(name):
                    err(f"error: {name} should analyze clean under the {solver} solver (lines {sorted(lines[name])})")
                    for line in sorted(lines[name]):
                        msg = f"[types].pass: a type error under the {solver} solver"
                        if emit_annotations:
                            annotate("error", msg, name, line, title="sert types", out=annot_out)
                        _rec(solver, name, line, msg)
                    err(output)
                    status, reported = FAILED, True
            if _report_outside("pass", solver, code, output, lines, passing_names, reported):
                status = FAILED
        if failing:
            code, output = results_map[(solver, "fail")]
            lines = error_lines(cfg, output, errors_only=True)
            reported = False
            for path in failing:
                name = posix(path, cfg.root)
                expected = expected_lines(path.read_bytes().decode("utf-8"))
                if problem := compare(name, expected, lines.get(name, set()), solver):
                    err(problem)
                    wrong = sorted(expected ^ lines.get(name, set()))
                    clean_msg = problem.removeprefix("error: ")
                    err_line = wrong[0] if wrong else None
                    if emit_annotations:
                        annotate("error", clean_msg, name, err_line, title="sert types", out=annot_out)
                    _rec(solver, name, err_line, clean_msg)
                    err(output)
                    status, reported = FAILED, True
            if _report_outside("fail", solver, 0, output, lines, failing_names, reported):
                status = FAILED
    return status


def check_types(
    cfg: config_mod.Config,
    ws: Workspace | None = None,
    defs: Path | None = None,
    out=print,
    err=None,
    *,
    annot_out=None,
) -> int:
    if ws is None:
        from sert import fetch

        resolved_defs = defs or fetch.ensure_types(cfg)
        with Workspace(cfg) as own_ws:
            if not own_ws.build_sourcemap()[1]:
                raise SertError("rojo sourcemap failed")
            return check_types(cfg, own_ws, resolved_defs, out=out, err=err, annot_out=annot_out)
    if defs is None:
        from sert import fetch

        defs = fetch.types_path(cfg.root) if ws.dry_run else fetch.ensure_types(cfg)
    err = err or (lambda message: print(message, file=sys.stderr))
    passing, failing = probe_files(cfg)
    if not passing and not failing:
        return 0
    chosen = solvers(cfg.get("types.solvers", cfg.get("lint.solvers")))
    probe_cmds = _prepare_type_probe_commands(cfg, ws, defs, passing, failing, chosen)
    if ws.dry_run:
        for _solver, _kind, command in probe_cmds:
            out("$ " + " ".join(command))
        return 0
    results_map: dict[tuple[str, str], tuple[int, str]] = {}
    if len(probe_cmds) == 1:
        s, k, cmd = probe_cmds[0]
        results_map[(s, k)] = run_analyze(cfg, cmd)
    else:
        with ThreadPoolExecutor(max_workers=min(4, len(probe_cmds))) as pool:
            futs = [((s, k), pool.submit(run_analyze, cfg, cmd)) for s, k, cmd in probe_cmds]
            for key, fut in futs:
                results_map[key] = fut.result()
    status = _evaluate_type_probe_results(cfg, passing, failing, chosen, results_map, err, annot_out)
    if status == 0:
        out(f"types: {len(passing)} clean and {len(failing)} failing probes hold under {' and '.join(chosen)} solver")
    return status


def shipped_stub() -> bytes | None:
    try:
        if (data := pkgutil.get_data("sert", "_stub/sert.py")) is not None:
            return data
    except OSError:
        pass
    source = Path(__file__).resolve().parents[2] / "tools" / "sert.py"
    return source.read_bytes() if source.is_file() else None


def stub_problem(root: Path) -> str | None:
    consumer = root / "tools" / "sert.py"
    if not consumer.is_file():
        return f"tools/sert.py is missing (run `{config_mod.command('init')}`)"
    shipped = shipped_stub()
    if shipped is None:
        return "this sert build carries no stub to compare tools/sert.py against"
    if consumer.read_bytes().replace(b"\r\n", b"\n") != shipped.replace(b"\r\n", b"\n"):
        return f"tools/sert.py differs from the stub this sert ships (run `{config_mod.command('init')}` to rewrite it)"
    return None


def expand(root: Path, entries) -> tuple[list[str], list[str]]:
    unmatched: list[str] = []
    return [posix(path, root) for path in expand_globs(root, entries, missing=unmatched)], unmatched


def _default_lint_paths(cfg: config_mod.Config) -> list[str]:
    raw_paths = cfg.table("lint").get("paths")
    if raw_paths is not None:
        return [str(p) for p in as_list(raw_paths)]
    if cfg.exists:
        return ["src"]
    return [d for d in ("src", "test", "tests") if (cfg.root / d).is_dir()] or ["."]


def _check_has_diag(fchk: str, diagnostics: list[dict]) -> bool:
    return any(
        d["tool"] == fchk
        or d["tool"].startswith(fchk + ":")
        or (fchk == "analyze" and str(d.get("tool", "")).startswith("luau-lsp:"))
        for d in diagnostics
    )


def analyze_groups(cfg: config_mod.Config) -> list[dict]:
    table = cfg.table("lint")
    groups = table.get("analyze")
    if groups is None:
        return [{"name": "", "paths": _default_lint_paths(cfg)}]
    out = []
    for index, group in enumerate(as_list(groups), 1):
        if not isinstance(group, dict) or not group.get("paths"):
            raise SertError(f"[[lint.analyze]] #{index} needs `paths`")
        out.append({**group, "name": str(group.get("name", index))})
    return out


def default_ignores(cfg: config_mod.Config) -> list[str]:
    ignores = [str(g) for g in as_list(cfg.get("lint.ignore"))]
    if ".sert/**" not in ignores:
        ignores.append(".sert/**")
    for directory in as_list(cfg.get("types.fail")):
        glob = f"**/{str(directory).strip('/')}/**"
        if glob not in ignores:
            ignores.append(glob)
    return ignores


_STYLUA_DIFF_RE = re.compile(r"^Diff in (.+?):$", re.MULTILINE)
_SELENE_HEADER_RE = re.compile(r"^(?:error|warning)\[[^\]]+\]:\s*(.+)$")
_SELENE_LOC_RE = re.compile(r"(?:\┌─|-->)\s*(.+?):(\d+):\d+")
_SELENE_INLINE_RE = re.compile(r"^(.+?):(\d+):\d+:\s*(.+)$")


class Lint:
    def __init__(
        self,
        cfg: config_mod.Config,
        dry_run: bool,
        skip: set[str],
        only: set[str] | None = None,
        *,
        fix: bool = False,
        skip_fetch: bool = False,
        fmt: str = "human",
        out=None,
        err=None,
    ):
        self.cfg, self.dry_run, self.skip, self.only = cfg, dry_run, skip, only
        self.fix = fix
        self.skip_fetch = skip_fetch
        self.fmt = fmt
        self.out = sys.stdout if out is None else out
        self.err = sys.stderr if err is None else err
        self.failed: list[str] = []
        self.diagnostics: list[dict] = []
        self.checks_run: list[str] = []

    def say(self, message: str) -> None:
        if self.fmt == "human":
            print(message, file=self.out, flush=True)

    def say_err(self, message: str) -> None:
        if self.fmt == "human":
            print(message, file=self.err, flush=True)

    def _record_diag(self, tool: str, message: str, *, file: str = "", line: int = 0) -> None:
        self.diagnostics.append({"tool": tool, "file": file, "line": int(line or 0), "message": message})

    def _parse_tool_diagnostics(self, name: str, text: str) -> None:
        if name == "stylua":
            diffs = [m.strip() for m in _STYLUA_DIFF_RE.findall(text)]
            if diffs:
                for raw_path in diffs:
                    p = Path(raw_path)
                    rel = (posix(p, self.cfg.root) if p.is_absolute() else raw_path).removeprefix("./")
                    self._record_diag("stylua", "formatting mismatch (run sert lint --fix)", file=rel, line=0)
                return
        elif name == "selene":
            recorded = 0
            pending_msg: str | None = None
            for ln_text in text.splitlines():
                if m_inline := _SELENE_INLINE_RE.match(ln_text.strip()):
                    p = Path(m_inline.group(1))
                    rel = (posix(p, self.cfg.root) if p.is_absolute() else m_inline.group(1)).removeprefix("./")
                    self._record_diag("selene", m_inline.group(3).strip(), file=rel, line=int(m_inline.group(2)))
                    recorded += 1
                    pending_msg = None
                elif m_hdr := _SELENE_HEADER_RE.match(ln_text.strip()):
                    pending_msg = m_hdr.group(1).strip()
                elif m_loc := _SELENE_LOC_RE.search(ln_text):
                    p = Path(m_loc.group(1).strip())
                    rel = (posix(p, self.cfg.root) if p.is_absolute() else m_loc.group(1).strip()).removeprefix("./")
                    self._record_diag("selene", pending_msg or "selene warning/error", file=rel, line=int(m_loc.group(2)))
                    recorded += 1
                    pending_msg = None
            if recorded:
                return
        first_line = next((line.strip() for line in text.splitlines() if line.strip()), f"{name} failed")
        self._record_diag(name, first_line)

    def _run_command(self, make_argv) -> tuple[list[str], subprocess.CompletedProcess | None, Exception | None]:
        try:
            argv = make_argv()
        except Exception as exc:
            return [], None, exc
        if self.dry_run:
            return argv, None, None
        try:
            res = subprocess.run(
                argv,
                cwd=self.cfg.root,
                timeout=300,
                capture_output=True,
                text=True,
                encoding="utf-8",
                errors="replace",
            )
            return argv, res, None
        except (OSError, subprocess.TimeoutExpired) as exc:
            return argv, None, exc

    def _finish_command(self, name: str, argv: list[str], res: subprocess.CompletedProcess | None, exc: Exception | None) -> None:
        if isinstance(exc, Exception) and not isinstance(exc, (OSError, subprocess.TimeoutExpired)):
            raise exc
        self.say("$ " + " ".join(argv))
        if self.dry_run:
            return
        if exc is not None:
            if self.fmt == "human":
                note(f"{name}: {exc}", err=self.err)
            else:
                self._record_diag(name, str(exc))
            if name not in self.failed:
                self.failed.append(name)
            return
        if res is not None:
            if self.fmt == "human":
                if res.stdout:
                    print(res.stdout, end="" if res.stdout.endswith("\n") else "\n", file=self.out, flush=True)
                if res.stderr:
                    print(res.stderr, end="" if res.stderr.endswith("\n") else "\n", file=self.err, flush=True)
            if res.returncode != 0:
                if self.fmt != "human":
                    self._parse_tool_diagnostics(name, (res.stdout or "") + "\n" + (res.stderr or ""))
                if name not in self.failed:
                    self.failed.append(name)

    def command(self, name: str, argv: list[str]) -> None:
        _, res, exc = self._run_command(lambda: argv)
        self._finish_command(name, argv, res, exc)

    def fail(self, name: str, message: str, file: str | None = None, line: int | None = None) -> None:
        self._record_diag(name, message, file=file or "", line=int(line or 0))
        if self.fmt == "human":
            print(f"error: {message}", file=self.err, flush=True)
            annotate("error", message, file=file, line=line, title=f"sert lint: {name}", out=self.out)
        if name not in self.failed:
            self.failed.append(name)

    def wants(self, name: str) -> bool:
        return (name in self.only and name not in self.skip) if self.only else (name not in self.skip)

    def run(self) -> int:
        cfg, table = self.cfg, self.cfg.table("lint")
        paths = _default_lint_paths(cfg)
        from sert import fetch

        if not self.dry_run and not self.skip_fetch:
            fetch.refresh_overrides(cfg)
            fetch.ensure_fetched(cfg)
        defs: Path | None = None

        def get_defs() -> Path:
            nonlocal defs
            if defs is None:
                defs = fetch.types_path(cfg.root) if self.dry_run else fetch.ensure_types(cfg)
            return defs

        want_stylua = self.wants("stylua") and table.get("stylua", True)
        want_selene = self.wants("selene") and table.get("selene", (cfg.root / "selene.toml").is_file())
        want_extra = self.wants("extra")
        want_stub = self.wants("stub") and table.get("stub", cfg.exists or (cfg.root / "tools" / "sert.py").is_file())

        if want_stylua:
            self.checks_run.append("stylua")
        if want_selene:
            self.checks_run.append("selene")

        # When `--fix` is set, format in place with StyLua BEFORE running selene / analyze so line numbers reflect fixes.
        if want_stylua and self.fix:
            self.command("stylua", [self.tool("stylua"), *paths])

        max_workers = min(8, (os.cpu_count() or 4) + 2)
        with ThreadPoolExecutor(max_workers=max_workers) as pool:
            stylua_fut = (
                pool.submit(self._run_command, lambda: [self.tool("stylua"), "--check", *paths])
                if (want_stylua and not self.fix)
                else None
            )
            selene_fut = pool.submit(self._run_command, lambda: [self.tool("selene"), *paths]) if want_selene else None
            extra_raw = as_list(table.get("extra")) if want_extra else []
            if extra_raw:
                self.checks_run.append("extra")
            extra_futs = [
                (f"extra: {' '.join(argv)}", pool.submit(self._run_command, lambda a=argv: a))
                for raw in extra_raw
                for argv in [[str(a) for a in as_list(raw)]]
            ]
            if want_stub:
                self.checks_run.append("stub")
            stub_fut = pool.submit(stub_problem, cfg.root) if (want_stub and not self.dry_run) else None

            with Workspace(cfg, dry_run=self.dry_run, err=(self.err if self.fmt == "human" else None)) as ws:
                need_sourcemap = self.wants("sourcemap") or (
                    (self.wants("analyze") or (self.wants("types") and bool(cfg.get("types"))))
                    and "sourcemap" not in self.skip
                )
                if need_sourcemap:
                    self.checks_run.append("sourcemap")
                    command, ok = ws.build_sourcemap()
                    if command:
                        self.say("$ " + " ".join(command))
                    if not ok:
                        self.fail("sourcemap", "rojo sourcemap failed")

                analyze_jobs: list[tuple[str, str, list[str], object]] = []
                if self.wants("analyze"):
                    self.checks_run.append("analyze")
                    for group in analyze_groups(cfg):
                        files, unmatched = expand(cfg.root, group["paths"])
                        label = f"[[lint.analyze]] {group['name']}: " if group["name"] else ""
                        for glob in unmatched:
                            self.fail("analyze", f"{label}{glob} matches nothing")
                        ignore = default_ignores(cfg) + [str(g) for g in as_list(group.get("ignore"))]
                        group_defs = get_defs() if group.get("defs", True) else None
                        for solver in solvers(group.get("solvers", cfg.get("lint.solvers"))):
                            ws.settings(solver)
                            argv = ws.analyze_command(
                                solver,
                                group_defs,
                                files,
                                ignore,
                                platform=group.get("platform"),
                                definitions=[str(d) for d in as_list(group.get("definitions"))],
                                sourcemap=group.get("sourcemap", True),
                            )
                            fut = None if self.dry_run else pool.submit(run_analyze, cfg, argv)
                            analyze_jobs.append((label, solver, argv, fut))

                type_passing: list[Path] = []
                type_failing: list[Path] = []
                type_chosen: list[str] = []
                type_jobs: list[tuple[str, str, list[str], object]] = []
                run_types_here = False
                if self.wants("types"):
                    if not cfg.get("types"):
                        if self.only and "types" in self.only:
                            raise SertError("sert.toml: no [types] table")
                    else:
                        run_types_here = True
                        self.checks_run.append("types")
                        type_defs = get_defs()
                        type_passing, type_failing = probe_files(cfg)
                        if type_passing or type_failing:
                            type_chosen = solvers(cfg.get("types.solvers", cfg.get("lint.solvers")))
                            for t_solver, t_kind, t_argv in _prepare_type_probe_commands(
                                cfg, ws, type_defs, type_passing, type_failing, type_chosen
                            ):
                                t_fut = None if self.dry_run else pool.submit(run_analyze, cfg, t_argv)
                                type_jobs.append((t_solver, t_kind, t_argv, t_fut))

                for label, solver, argv, fut in analyze_jobs:
                    self.say("$ " + " ".join(argv))
                    if fut is not None:
                        code, output = fut.result()  # type: ignore[attr-defined]
                        if output and self.fmt == "human":
                            print(output, end="" if output.endswith("\n") else "\n", file=self.out, flush=True)
                        parsed_diags = diagnostics(cfg, output)
                        for file, line, message in parsed_diags:
                            if self.fmt == "human":
                                annotate(
                                    "warning" if is_lint(message) else "error",
                                    message,
                                    file=file,
                                    line=line,
                                    title=f"luau-lsp ({solver} solver)",
                                    out=self.out,
                                )
                            else:
                                self._record_diag(f"luau-lsp:{solver}", message, file=file, line=line)
                        if code != 0:
                            if self.fmt == "human" or not parsed_diags:
                                self.fail("analyze", f"{label}luau-lsp analyze ({solver} solver) reported problems")
                            elif "analyze" not in self.failed:
                                self.failed.append("analyze")

                if run_types_here and (type_passing or type_failing):
                    if self.dry_run:
                        for _solver, _kind, t_argv, _fut in type_jobs:
                            self.say("$ " + " ".join(t_argv))
                    else:
                        results_map = {
                            (t_solver, t_kind): t_fut.result()  # type: ignore[attr-defined]
                            for t_solver, t_kind, _argv, t_fut in type_jobs
                        }
                        t_status = _evaluate_type_probe_results(
                            cfg,
                            type_passing,
                            type_failing,
                            type_chosen,
                            results_map,
                            self.say_err,
                            self.out,
                            diags=(self.diagnostics if self.fmt != "human" else None),
                            emit_annotations=(self.fmt == "human"),
                        )
                        if t_status != 0:
                            if "types" not in self.failed:
                                self.failed.append("types")
                        else:
                            self.say(
                                f"types: {len(type_passing)} clean and {len(type_failing)} failing probes hold under {' and '.join(type_chosen)} solver"
                            )

            if stylua_fut is not None:
                self._finish_command("stylua", *stylua_fut.result())
            if selene_fut is not None:
                self._finish_command("selene", *selene_fut.result())
            for extra_name, fut in extra_futs:
                self._finish_command(extra_name, *fut.result())
            if want_stub:
                self.say("$ compare tools/sert.py with the shipped stub")
                if not self.dry_run and (problem := (stub_fut.result() if stub_fut is not None else stub_problem(cfg.root))):
                    self.fail("stub", problem)
        exit_code = 0 if (self.dry_run or not self.failed) else FAILED
        if self.fmt == "json":
            errors = [
                f"{d['tool']}: {d['file']}:{d['line']}: {d['message']}"
                if d.get("file")
                else f"{d['tool']}: {d['message']}"
                for d in self.diagnostics
            ]
            for fchk in self.failed:
                if not _check_has_diag(fchk, self.diagnostics):
                    errors.append(f"{fchk} failed")
            envelope = agent.json_envelope(
                "lint",
                exit_code,
                summary={
                    "checks": len(self.checks_run),
                    "failed_checks": list(self.failed),
                    "diagnostics": len(self.diagnostics),
                    "dry_run": self.dry_run,
                },
                errors=errors,
                data={
                    "checks": list(self.checks_run),
                    "failed": list(self.failed),
                    "diagnostics": list(self.diagnostics),
                },
            )
            print(agent.json_dumps_compact(envelope), file=self.out, flush=True)
            return exit_code
        if self.fmt == "agent":
            if self.dry_run:
                print(f"OK lint=0 checks={len(self.checks_run)} dry_run=true", file=self.out, flush=True)
                return 0
            for fchk in self.failed:
                if not _check_has_diag(fchk, self.diagnostics):
                    self._record_diag(fchk, f"{fchk} failed")
            print(agent.format_lint_agent(self.diagnostics, root=cfg.root), file=self.out, flush=True)
            return exit_code
        if self.dry_run:
            return 0
        if self.failed:
            print(f"lint: failed: {', '.join(self.failed)}", file=self.err, flush=True)
            return FAILED
        print("lint: ok", file=self.out, flush=True)
        return 0

    def analyze(self, ws: Workspace, group: dict, defs: Path | None) -> None:
        cfg = self.cfg
        files, unmatched = expand(cfg.root, group["paths"])
        label = f"[[lint.analyze]] {group['name']}: " if group["name"] else ""
        for glob in unmatched:
            self.fail("analyze", f"{label}{glob} matches nothing")
        ignore = default_ignores(cfg) + [str(g) for g in as_list(group.get("ignore"))]
        for solver in solvers(group.get("solvers", cfg.get("lint.solvers"))):
            argv = ws.analyze_command(
                solver,
                defs if group.get("defs", True) else None,
                files,
                ignore,
                platform=group.get("platform"),
                definitions=[str(d) for d in as_list(group.get("definitions"))],
                sourcemap=group.get("sourcemap", True),
            )
            self.say("$ " + " ".join(argv))
            if not self.dry_run:
                code, output = run_analyze(cfg, argv)
                if output:
                    print(output, end="" if output.endswith("\n") else "\n", file=self.out, flush=True)
                for file, line, message in diagnostics(cfg, output):
                    annotate(
                        "warning" if is_lint(message) else "error",
                        message,
                        file=file,
                        line=line,
                        title=f"luau-lsp ({solver} solver)",
                        out=self.out,
                    )
                if code != 0:
                    self.fail("analyze", f"{label}luau-lsp analyze ({solver} solver) reported problems")

    def tool(self, name: str) -> str:
        return name if self.dry_run else need(name, self.cfg.root)


def add_parser(subparsers) -> None:
    parser = subparsers.add_parser("lint")
    parser.add_argument("--fix", action="store_true", help="format files in place with StyLua")
    parser.add_argument("--dry-run", action="store_true", help="print checks and commands without running them")
    parser.add_argument("--skip", action="append", default=[], choices=CHECKS, help="skip a check (repeatable)")
    parser.add_argument("--only", action="append", default=[], choices=CHECKS, help="run only these checks (repeatable)")
    parser.add_argument("--agent", action="store_true", help="compact AI-agent-friendly lint output")
    parser.add_argument(
        "--format",
        choices=("human", "agent", "json"),
        default=None,
        help="output format (default: human; or agent when SERT_AGENT=1)",
    )
    parser.set_defaults(func=main)


def cmd_lint_streams(
    args,
    root: Path | None = None,
    cfg: config_mod.Config | None = None,
    *,
    skip_fetch: bool = False,
    out=None,
    err=None,
) -> int:
    fmt = agent.output_format(args)
    if cfg is None or not isinstance(cfg, config_mod.Config):
        cfg = config_mod.load(root, require=False) if root is not None else config_mod.from_args(args, require=False)
        if not cfg.exists:
            has_zero_config = (
                (cfg.root / "default.project.json").is_file()
                or any((cfg.root / name).is_dir() for name in ("src", "test", "tests"))
            )
            if not has_zero_config:
                raise SertError(
                    f"no {config_mod.CONFIG}, src/, test/, or default.project.json in {cfg.root} "
                    f"(run `{config_mod.command('init')}`)"
                )
    return Lint(
        cfg,
        bool(getattr(args, "dry_run", False)),
        set(getattr(args, "skip", None) or []),
        only=set(args.only) if getattr(args, "only", None) else None,
        fix=bool(getattr(args, "fix", False)),
        skip_fetch=skip_fetch,
        fmt=fmt,
        out=out,
        err=err,
    ).run()


def cmd_lint(
    args,
    root: Path | None = None,
    cfg: config_mod.Config | None = None,
    *,
    skip_fetch: bool = False,
    out=None,
    err=None,
) -> int:
    ns = argparse.Namespace(
        root=str(root) if root is not None else getattr(args, "root", None),
        dry_run=bool(getattr(args, "dry_run", False)),
        fix=bool(getattr(args, "fix", False)),
        skip=list(getattr(args, "skip", None) or []),
        only=getattr(args, "only", None),
        format="human",
        agent=False,
    )
    return cmd_lint_streams(ns, root=root, cfg=cfg, **supported_kwargs(cmd_lint_streams, skip_fetch=True if skip_fetch else None), out=out, err=err)


def main(args) -> int:
    try:
        return cmd_lint_streams(args)
    except SertError as err:
        if agent.output_format(args) == "json":
            print(agent.json_dumps_compact(agent.json_envelope("lint", err.code, errors=[str(err)])), flush=True)
            return err.code
        raise
