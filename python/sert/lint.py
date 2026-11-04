"""`sert lint [--dry-run] [--skip CHECK] [--only CHECK]`: run every configured static check."""

from __future__ import annotations

import json
import os
from pathlib import Path
import pkgutil
import re
import subprocess
import sys
import tempfile

from sert import config as config_mod
from sert.util import FAILED, SertError, annotate, as_list, expand_globs, need, note, posix

CHECKS = ("sourcemap", "analyze", "types", "registration", "stylua", "selene", "extra", "stub")
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
    return str(project) if project else ("default.project.json" if (cfg.root / "default.project.json").is_file() else None)


class Workspace:
    def __init__(self, cfg: config_mod.Config, dry_run: bool = False):
        self.cfg = cfg
        self.dry_run = dry_run
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
        command = ["rojo", "sourcemap", project, "--absolute", "--include-non-scripts", "--output", str(target)]
        if not self.dry_run:
            command[0] = need("rojo", self.cfg.root)
            result = subprocess.run(command, cwd=self.cfg.root, capture_output=True, text=True, encoding="utf-8", errors="replace", timeout=300)
            if result.returncode != 0:
                note(result.stdout + result.stderr)
                return command, False
        self.sourcemap = target
        return command, True

    def analyze_command(self, solver: str, defs: Path | None, files, ignore=(), platform: str | None = None, definitions=(), sourcemap: bool = True) -> list[str]:
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
    result = subprocess.run(command, cwd=cfg.root, capture_output=True, text=True, encoding="utf-8", errors="replace", timeout=300)
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
    return None if expected == found else f"error: under the {solver} solver, {name} should fail to type-check on lines {sorted(expected)}, but failed on {sorted(found)}"


def check_types(cfg: config_mod.Config, ws: Workspace | None = None, defs: Path | None = None, out=print, err=None) -> int:
    if ws is None:
        from sert import fetch

        resolved_defs = defs or fetch.ensure_types(cfg)
        with Workspace(cfg) as own_ws:
            if not own_ws.build_sourcemap()[1]:
                raise SertError("rojo sourcemap failed")
            return check_types(cfg, own_ws, resolved_defs, out=out, err=err)
    if defs is None:
        from sert import fetch

        defs = fetch.types_path(cfg.root) if ws.dry_run else fetch.ensure_types(cfg)
    err = err or (lambda message: print(message, file=sys.stderr))
    passing, failing = probe_files(cfg)
    if not passing and not failing:
        return 0
    chosen = solvers(cfg.get("types.solvers", cfg.get("lint.solvers")))
    pass_ignores = default_ignores(cfg)
    fail_ignores = [".sert/**", *[str(g) for g in as_list(cfg.get("lint.ignore"))]]
    status = 0
    for solver in chosen:
        if passing:
            passing_names = {posix(p, cfg.root) for p in passing}
            command = ws.analyze_command(solver, defs, [posix(p, cfg.root) for p in passing], ignore=pass_ignores)
            if ws.dry_run:
                out("$ " + " ".join(command))
            else:
                code, output = run_analyze(cfg, command)
                lines = error_lines(cfg, output)
                reported = False
                for path in passing:
                    name = posix(path, cfg.root)
                    if lines.get(name):
                        err(f"error: {name} should analyze clean under the {solver} solver (lines {sorted(lines[name])})")
                        for line in sorted(lines[name]):
                            annotate("error", f"[types].pass: a type error under the {solver} solver", name, line, title="sert types")
                        err(output)
                        status, reported = FAILED, True
                outside = {k: v for k, v in lines.items() if k not in passing_names and v}
                if outside or (code != 0 and not reported):
                    for name, err_lns in sorted(outside.items()):
                        err(f"error: {name} reported errors during [types].pass under the {solver} solver (lines {sorted(err_lns)})")
                    if not outside:
                        err(f"error: luau-lsp analyze failed (exit {code}) during [types].pass under the {solver} solver")
                    if not reported:
                        err(output)
                    status = FAILED
        if failing:
            failing_names = {posix(p, cfg.root) for p in failing}
            command = ws.analyze_command(solver, defs, [posix(p, cfg.root) for p in failing], ignore=fail_ignores)
            if ws.dry_run:
                out("$ " + " ".join(command))
            else:
                code, output = run_analyze(cfg, command)
                lines = error_lines(cfg, output, errors_only=True)
                reported = False
                for path in failing:
                    name = posix(path, cfg.root)
                    expected = expected_lines(path.read_bytes().decode("utf-8"))
                    if problem := compare(name, expected, lines.get(name, set()), solver):
                        err(problem)
                        wrong = sorted(expected ^ lines.get(name, set()))
                        annotate("error", problem.removeprefix("error: "), name, wrong[0] if wrong else None, title="sert types")
                        err(output)
                        status, reported = FAILED, True
                if outside := {k: v for k, v in lines.items() if k not in failing_names and v}:
                    for name, err_lns in sorted(outside.items()):
                        err(f"error: {name} reported unexpected errors during [types].fail under the {solver} solver (lines {sorted(err_lns)})")
                    if not reported:
                        err(output)
                    status = FAILED
    if status == 0 and not ws.dry_run:
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


def registration_findings(root: Path, entry: dict) -> list[tuple[str | None, str]]:
    aggregator, specs = entry.get("aggregator"), entry.get("specs")
    if not aggregator or not specs:
        raise SertError("[lint].registration needs `aggregator` and `specs`")
    agg = root / str(aggregator)
    if not agg.is_file():
        return [(None, f"{aggregator} not found")]
    from sert.mutate import code_lines

    code_text = "\n".join(code_lines(agg.read_text(encoding="utf-8"), keep_strings=True))
    is_init = agg.stem == "init"
    base = agg.parent.parent if is_init else agg.parent
    problems = []
    for spec in expand_globs(root, specs, files=True):
        module = Path(os.path.relpath(spec, base)).as_posix().removesuffix(".luau")
        entries = [f"./{module}", module] if module.startswith("../") else [f"./{module}"]
        if is_init:
            entries.append(f"@self/{Path(os.path.relpath(spec, agg.parent)).as_posix().removesuffix('.luau')}")
        if not any(re.search(rf'(?<![A-Za-z0-9_])require\(\s*["\'](?<![A-Za-z0-9_./]){re.escape(e)}(?![A-Za-z0-9_])["\']\s*\)', code_text) for e in entries):
            problems.append((posix(spec, root), f"{posix(spec, root)} is not required by {aggregator}"))
    return problems


def expand(root: Path, entries) -> tuple[list[str], list[str]]:
    unmatched: list[str] = []
    return [posix(path, root) for path in expand_globs(root, entries, missing=unmatched)], unmatched


def analyze_groups(cfg: config_mod.Config) -> list[dict]:
    table = cfg.table("lint")
    groups = table.get("analyze")
    if groups is None:
        return [{"name": "", "paths": [str(p) for p in as_list(table.get("paths", ["src"]))]}]
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


class Lint:
    def __init__(self, cfg: config_mod.Config, dry_run: bool, skip: set[str], only: set[str] | None = None):
        self.cfg, self.dry_run, self.skip, self.only = cfg, dry_run, skip, only
        self.failed: list[str] = []

    def say(self, message: str) -> None:
        print(message, flush=True)

    def _run_command(self, make_argv) -> tuple[list[str], subprocess.CompletedProcess | None, Exception | None]:
        try:
            argv = make_argv()
        except Exception as err:
            return [], None, err
        if self.dry_run:
            return argv, None, None
        try:
            res = subprocess.run(argv, cwd=self.cfg.root, timeout=300, capture_output=True, text=True, encoding="utf-8", errors="replace")
            return argv, res, None
        except (OSError, subprocess.TimeoutExpired) as err:
            return argv, None, err

    def _finish_command(self, name: str, argv: list[str], res: subprocess.CompletedProcess | None, err: Exception | None) -> None:
        if isinstance(err, Exception) and not isinstance(err, (OSError, subprocess.TimeoutExpired)):
            raise err
        self.say("$ " + " ".join(argv))
        if self.dry_run:
            return
        if err is not None:
            note(f"{name}: {err}")
            self.failed.append(name)
            return
        if res is not None:
            if res.stdout:
                print(res.stdout, end="" if res.stdout.endswith("\n") else "\n", flush=True)
            if res.stderr:
                print(res.stderr, end="" if res.stderr.endswith("\n") else "\n", file=sys.stderr, flush=True)
            if res.returncode != 0 and name not in self.failed:
                self.failed.append(name)

    def command(self, name: str, argv: list[str]) -> None:
        _, res, err = self._run_command(lambda: argv)
        self._finish_command(name, argv, res, err)

    def fail(self, name: str, message: str, file: str | None = None, line: int | None = None) -> None:
        print(f"error: {message}", file=sys.stderr, flush=True)
        annotate("error", message, file=file, line=line, title=f"sert lint: {name}")
        if name not in self.failed:
            self.failed.append(name)

    def wants(self, name: str) -> bool:
        return (name in self.only and name not in self.skip) if self.only else (name not in self.skip)

    def run(self) -> int:
        from concurrent.futures import ThreadPoolExecutor

        cfg, table = self.cfg, self.cfg.table("lint")
        paths = [str(p) for p in as_list(table.get("paths", ["src"]))]
        from sert import fetch

        if not self.dry_run:
            fetch.refresh_overrides(cfg)
            fetch.ensure_fetched(cfg)
        defs: Path | None = None

        def get_defs() -> Path:
            nonlocal defs
            if defs is None:
                defs = fetch.types_path(cfg.root) if self.dry_run else fetch.ensure_types(cfg)
            return defs

        want_reg = self.wants("registration")
        want_stylua = self.wants("stylua") and table.get("stylua", True)
        want_selene = self.wants("selene") and table.get("selene", (cfg.root / "selene.toml").is_file())
        want_extra = self.wants("extra")
        want_stub = self.wants("stub") and table.get("stub", True)

        with ThreadPoolExecutor(max_workers=4) as pool:
            reg_fut = pool.submit(
                lambda: [(file, problem) for entry in as_list(table.get("registration")) for file, problem in registration_findings(cfg.root, entry)]
            ) if (want_reg and not self.dry_run) else None
            stylua_fut = pool.submit(self._run_command, lambda: [self.tool("stylua"), "--check", *paths]) if want_stylua else None
            selene_fut = pool.submit(self._run_command, lambda: [self.tool("selene"), *paths]) if want_selene else None
            extra_futs = [
                (f"extra: {' '.join(argv)}", pool.submit(self._run_command, lambda a=argv: a))
                for raw in (as_list(table.get("extra")) if want_extra else [])
                for argv in [[str(a) for a in as_list(raw)]]
            ]
            stub_fut = pool.submit(stub_problem, cfg.root) if (want_stub and not self.dry_run) else None

            with Workspace(cfg, dry_run=self.dry_run) as ws:
                need_sourcemap = self.wants("sourcemap") or ((self.wants("analyze") or (self.wants("types") and bool(cfg.get("types")))) and "sourcemap" not in self.skip)
                if need_sourcemap:
                    command, ok = ws.build_sourcemap()
                    if command:
                        self.say("$ " + " ".join(command))
                    if not ok:
                        self.fail("sourcemap", "rojo sourcemap failed")
                if self.wants("analyze"):
                    for group in analyze_groups(cfg):
                        self.analyze(ws, group, get_defs() if group.get("defs", True) else None)
                if self.wants("types"):
                    if not cfg.get("types"):
                        if self.only and "types" in self.only:
                            raise SertError("sert.toml: no [types] table")
                    elif check_types(cfg, ws, get_defs(), out=self.say) != 0:
                        self.failed.append("types")
            if want_reg:
                findings = reg_fut.result() if reg_fut is not None else [
                    (file, problem) for entry in as_list(table.get("registration")) for file, problem in registration_findings(cfg.root, entry)
                ]
                for file, problem in findings:
                    self.fail("registration", problem, file=file)
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
        if self.dry_run:
            return 0
        if self.failed:
            print(f"lint: failed: {', '.join(self.failed)}", file=sys.stderr)
            return FAILED
        print("lint: ok")
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
                solver, defs if group.get("defs", True) else None, files, ignore,
                platform=group.get("platform"), definitions=[str(d) for d in as_list(group.get("definitions"))],
                sourcemap=group.get("sourcemap", True),
            )
            self.say("$ " + " ".join(argv))
            if not self.dry_run:
                code, output = run_analyze(cfg, argv)
                if output:
                    print(output, end="" if output.endswith("\n") else "\n", flush=True)
                for file, line, message in diagnostics(cfg, output):
                    annotate("warning" if is_lint(message) else "error", message, file=file, line=line, title=f"luau-lsp ({solver} solver)")
                if code != 0:
                    self.fail("analyze", f"{label}luau-lsp analyze ({solver} solver) reported problems")

    def tool(self, name: str) -> str:
        return name if self.dry_run else need(name, self.cfg.root)


def add_parser(subparsers) -> None:
    parser = subparsers.add_parser("lint")
    parser.add_argument("--dry-run", action="store_true", help="print the checks and commands; run nothing")
    parser.add_argument("--skip", action="append", default=[], choices=CHECKS, help="leave a check out (repeatable)")
    parser.add_argument("--only", action="append", default=[], choices=CHECKS, help="run only these checks (repeatable)")
    parser.set_defaults(func=main)


def main(args) -> int:
    cfg = config_mod.from_args(args, require=True)
    return Lint(cfg, args.dry_run, set(args.skip), only=set(args.only) if getattr(args, "only", None) else None).run()
