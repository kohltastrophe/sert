"""`sert run`: the headless suite."""

from __future__ import annotations

import argparse
import contextlib
from dataclasses import dataclass, field
import json
import math
import os
from pathlib import Path
import re
import subprocess
import sys
import threading
import time
from xml.etree import ElementTree

from sert import config as config_mod
from sert.util import (
    FAILED, INFRA, OK, TIMEOUT, OutputClosed, SertError, annotate, as_list, check_selection, expand_globs,
    guarded, has_glob, load_json, luau_string, note, on_github_actions, posix, sert_alias, strip_trailing_commas, which,
)

RUNNERS = ("luau", "lute")


def runner_of(cfg: config_mod.Config, runner: str | None = None, coverage: bool = False) -> str:
    runner = runner or str(cfg.get("test.runner", "luau"))
    if runner not in RUNNERS:
        raise SertError(f"[test].runner must be one of {', '.join(RUNNERS)}, not {runner!r}")
    if coverage and runner != "luau":
        raise SertError('--coverage needs [test].runner = "luau" (lute has no coverage flag)')
    return runner


STAGE_HEADER = "-- sert-stage-v2\n"
INIT_NAMES = (
    ("init.luau", "ModuleScript"), ("init.lua", "ModuleScript"),
    ("init.server.luau", "Script"), ("init.server.lua", "Script"),
    ("init.client.luau", "LocalScript"), ("init.client.lua", "LocalScript"),
)


def luau_command(root, runner: str = "luau") -> str:
    if found := which(runner, root):
        return found
    raise SertError(f"{runner} not found: pin [tools].{runner} and run `{config_mod.command('fetch')}`, or put {runner} on PATH")


def require_fetched(cfg: config_mod.Config, runner: str = "luau") -> None:
    from sert.fetch import unpinned_sert

    fetch_cmd = f"run `{config_mod.command('fetch')}`"
    pinned = cfg.table("tools").get(runner)
    bin_dir = cfg.root / ".sert" / "bin"
    if pinned and not any((bin_dir / name).is_file() for name in (runner, f"{runner}.exe", f"{runner}.cmd", f"{runner}.bat")):
        raise SertError(f"{runner} {pinned} is pinned but .sert/bin/{runner} is missing ({fetch_cmd})")
    alias = sert_alias(cfg.root)
    if isinstance(alias, str) and not alias.startswith("@"):
        target = Path(os.path.normpath(cfg.root / alias))
        fetched = Path(os.path.normpath(cfg.root / ".sert" / "sert"))
        if target.is_relative_to(fetched) and not (fetched / "src").is_dir():
            if problem := unpinned_sert(cfg):
                raise SertError(problem)
            raise SertError(f'.sert/sert is missing, which the .luaurc "sert" alias points into ({fetch_cmd})')


def entry_command(runner: str, binary: str, entry: str, program_args: list[str], coverage: bool, codegen: bool = False) -> list[str]:
    if runner == "lute":
        return [binary, "run", entry, *program_args]
    flags = ["--coverage"] if coverage else (["--codegen"] if codegen else [])
    return [binary, *flags, entry, *(["-a", *program_args] if program_args else [])]


STAGE_WRAP_PREFIX = b"return function() return function(_ENV: any, ...: any): ...any setfenv(1, _ENV) "


def wrap_luau_source(source: str, prelude: str = "") -> str:
    if source.startswith("#!"):
        source = "--" + source[2:]
    return STAGE_WRAP_PREFIX.decode() + prelude + source + "\nend end\n"


def _require_spec_for_rel(rel_posix: str) -> str:
    if rel_posix in ("init.luau", "init.lua"):
        return "@self/files"
    for suffix in ("/init.luau", "/init.lua", ".luau", ".lua"):
        if rel_posix.endswith(suffix):
            return "@self/files/" + rel_posix[: -len(suffix)]
    return "@self/files/" + rel_posix


def _classify_script_file(path: Path) -> tuple[str, str] | None:
    name = path.name
    for suffix, class_name in (
        (".server.luau", "Script"), (".server.lua", "Script"),
        (".client.luau", "LocalScript"), (".client.lua", "LocalScript"),
        (".luau", "ModuleScript"), (".lua", "ModuleScript"),
    ):
        if name.endswith(suffix):
            return name[: -len(suffix)], class_name
    return None


def _luau_literal(value) -> str:
    if value is None:
        return "nil"
    if isinstance(value, bool):
        return "true" if value else "false"
    if isinstance(value, float) and not math.isfinite(value):
        return "(0 / 0)" if math.isnan(value) else ("math.huge" if value > 0 else "-math.huge")
    if isinstance(value, (int, float)):
        return repr(value)
    if isinstance(value, str):
        return luau_string(value)
    if isinstance(value, dict):
        return "{ " + ", ".join(f"[{luau_string(str(k))}] = {_luau_literal(v)}" for k, v in sorted(value.items())) + " }"
    if isinstance(value, list):
        return "{ " + ", ".join(_luau_literal(v) for v in value) + " }"
    raise TypeError(f"unsupported stage literal: {type(value)}")


def _apply_meta(node: dict, meta: dict, explicit_class: str | None = None) -> None:
    if "className" in meta and not explicit_class:
        node["className"] = meta["className"]
    for src_key, dst_key in ((("properties", "$properties"), "props"), (("attributes", "$attributes"), "attributes")):
        val = meta.get(src_key[0]) or meta.get(src_key[1])
        if isinstance(val, dict) and val:
            node[dst_key] = {**(node.get(dst_key) or {}), **val}


def _merge_rojo_nodes(target: dict, override: dict) -> None:
    if override.get("file") is not None:
        target["file"], target["className"] = override["file"], override["className"]
    elif override.get("className") and override["className"] != "Folder":
        target["className"] = override["className"]
    if "value" in override:
        target["value"] = override["value"]
    for key in ("props", "attributes"):
        if key in override:
            target[key] = {**(target.get(key) or {}), **override[key]}
    for child_key, child_val in override.get("children", {}).items():
        if child_key in target["children"]:
            _merge_rojo_nodes(target["children"][child_key], child_val)
        else:
            target["children"][child_key] = child_val


def stage_project(root: Path | config_mod.Config, project_rel: str | None = None) -> Path:
    if isinstance(root, config_mod.Config):
        project_rel = project_rel or str(root.get("test.stage"))
        root = root.root
    if not project_rel:
        raise SertError("[test].stage: project file not set")
    root_resolved = root.resolve()
    project_path = (root / project_rel).resolve()
    if not project_path.is_file():
        raise SertError(f"[test].stage: project file {project_rel} not found")

    stage_dir = root / ".sert" / "stage"
    files_dir, init_path = stage_dir / "files", stage_dir / "init.luau"
    force_rewrite = not init_path.is_file() or not init_path.read_text(encoding="utf-8", errors="replace").startswith(STAGE_HEADER)
    files_dir.mkdir(parents=True, exist_ok=True)
    staged_files: set[str] = set()

    def register_file(file_path: Path) -> str:
        resolved = file_path.resolve()
        try:
            rel = resolved.relative_to(root_resolved).as_posix()
        except ValueError:
            rel = os.path.relpath(resolved, root_resolved).replace("\\", "/").replace("..", "__up__")
        if rel not in staged_files:
            staged_files.add(rel)
            dest = files_dir / rel
            needs_write = force_rewrite or not dest.is_file() or dest.stat().st_mtime_ns < resolved.stat().st_mtime_ns
            if not needs_write:
                with dest.open("rb") as fh:
                    head = fh.read(512)
                    if not head.startswith(STAGE_WRAP_PREFIX) or b"setmetatable(_G," in head or b"__SERT_MUTANT" in head:
                        needs_write = True
            if needs_write:
                dest.parent.mkdir(parents=True, exist_ok=True)
                dest.write_text(wrap_luau_source(resolved.read_text(encoding="utf-8", errors="replace")), encoding="utf-8")
        return rel

    def load_meta(meta_path: Path) -> dict | None:
        data = load_json(meta_path) if meta_path.is_file() else None
        return data if isinstance(data, dict) else None

    active_projects: set[Path] = set()

    def walk_fs_path(fs_path: Path, name: str, explicit_class: str | None = None) -> dict | None:
        if not fs_path.exists():
            return None
        if fs_path.is_file():
            if fs_path.name.endswith(".project.json") and fs_path.resolve() not in active_projects:
                return parse_rojo_project(fs_path, override_name=name)
            if fs_path.name.endswith(".txt"):
                stem = fs_path.name[: -len(".txt")]
                node: dict = {"name": name, "className": explicit_class or "StringValue", "value": fs_path.read_text(encoding="utf-8", errors="replace").rstrip("\r\n"), "children": {}}
                if meta := load_meta(fs_path.parent / f"{stem}.meta.json"):
                    _apply_meta(node, meta, explicit_class)
                return node
            classified = _classify_script_file(fs_path)
            if classified is None:
                return None
            stem, class_name = classified
            node = {"name": name, "className": explicit_class or class_name, "file": register_file(fs_path), "children": {}}
            if meta := load_meta(fs_path.parent / f"{stem}.meta.json"):
                _apply_meta(node, meta, explicit_class)
            return node
        nested_project = (fs_path / "default.project.json").resolve()
        if nested_project.is_file() and nested_project not in active_projects:
            return parse_rojo_project(nested_project, override_name=name)

        class_name, file_rel = explicit_class or "Folder", None
        init_names = {entry[0] for entry in INIT_NAMES}
        for init_name, init_class in INIT_NAMES:
            candidate = fs_path / init_name
            if candidate.is_file():
                class_name, file_rel = explicit_class or init_class, register_file(candidate)
                break

        children: dict[str, dict] = {}
        for entry in sorted(fs_path.iterdir(), key=lambda p: p.name):
            if entry.name.startswith(".") or entry.name in init_names or entry.name.endswith(".meta.json"):
                continue
            if entry.is_dir():
                if (child_node := walk_fs_path(entry, entry.name)) is not None:
                    if meta := load_meta(fs_path / f"{entry.name}.meta.json"):
                        _apply_meta(child_node, meta)
                    children[entry.name] = child_node
            elif entry.is_file() and not entry.name.endswith(".project.json"):
                child_name = entry.name[: -len(".txt")] if entry.name.endswith(".txt") else (classified[0] if (classified := _classify_script_file(entry)) else None)
                if child_name is not None and (child_node := walk_fs_path(entry, child_name)) is not None:
                    children[child_name] = child_node

        node = {"name": name, "className": class_name, "file": file_rel, "children": children}
        if init_meta := load_meta(fs_path / "init.meta.json"):
            _apply_meta(node, init_meta, explicit_class)
        return node

    def parse_rojo_tree(tree: dict, base_dir: Path, name: str) -> dict:
        explicit_class, path_spec = tree.get("$className"), tree.get("$path")
        node: dict = {"name": name, "className": explicit_class or "Folder", "file": None, "children": {}}
        if isinstance(path_spec, str) and (walked := walk_fs_path((base_dir / path_spec).resolve(), name, explicit_class=explicit_class)) is not None:
            node = walked
        _apply_meta(node, tree, explicit_class)
        for key, value in sorted(tree.items()):
            if not key.startswith("$") and isinstance(value, dict):
                child_node = parse_rojo_tree(value, base_dir, key)
                if key in node["children"]:
                    _merge_rojo_nodes(node["children"][key], child_node)
                else:
                    node["children"][key] = child_node
        return node

    def parse_rojo_project(proj_file: Path, override_name: str | None = None) -> dict:
        resolved_proj = proj_file.resolve()
        active_projects.add(resolved_proj)
        try:
            try:
                data = json.loads(strip_trailing_commas(proj_file.read_text(encoding="utf-8")))
            except (OSError, UnicodeDecodeError, json.JSONDecodeError) as err:
                raise SertError(f"[test].stage: {proj_file}: {err}") from err
            if not isinstance(data, dict) or not isinstance(data.get("tree", {}), dict):
                raise SertError(f"[test].stage: {proj_file}: must be a JSON object with a table tree")
            return parse_rojo_tree(data.get("tree", {}), proj_file.parent, override_name or data.get("name", proj_file.stem))
        finally:
            active_projects.discard(resolved_proj)

    root_tree = parse_rojo_project(project_path)
    for existing in sorted(files_dir.rglob("*"), reverse=True):
        if existing.is_file() and existing.relative_to(files_dir).as_posix() not in staged_files:
            existing.unlink()
        elif existing.is_dir():
            try:
                existing.rmdir()
            except OSError:
                pass

    file_entries = [f"\t\t[{luau_string(rel)}] = function() return require({luau_string(_require_spec_for_rel(rel))})() end," for rel in sorted(staged_files)]
    init_luau = f"{STAGE_HEADER}-- Generated by `sert run` from [test].stage; do not edit.\nreturn {{\n\troot = {_luau_literal(root_tree)},\n\tfiles = {{\n" + "\n".join(file_entries) + "\n\t},\n}\n"
    if not init_path.is_file() or init_path.read_text(encoding="utf-8", errors="replace") != init_luau:
        init_path.write_text(init_luau, encoding="utf-8")
    return init_path


def _strip_luau_ext(rel_posix: str) -> str:
    return rel_posix[: -len(".luau")] if rel_posix.endswith(".luau") else (rel_posix[: -len(".lua")] if rel_posix.endswith(".lua") else rel_posix)


def _sert_require_target(root: Path) -> str:
    if sert_alias(root) is not None:
        return "@sert"
    if (root / "src" / "init.luau").is_file() and (root / "python" / "sert").is_dir():
        return "../src"
    return "./sert/src" if (root / ".sert" / "sert" / "src").is_dir() else "../src"


def write_spec_runner(root: Path, patterns: list[str], setup: str | None = None) -> str:
    expanded = []
    for pat in patterns:
        if not has_glob(pat) and (root / pat).is_dir():
            expanded.append(pat.rstrip("/") + "/**/*.spec.luau")
        elif not has_glob(pat) and not (root / pat).is_file():
            raise SertError(f'spec file {pat} not found (to run tests by name: run --filter "{pat}")')
        else:
            expanded.append(pat)
    spec_rels = [posix(path, root) for path in expand_globs(root, expanded, files=True)]
    if not spec_rels:
        raise SertError(f"no spec files matched {', '.join(patterns)}")

    lines = [
        "--!nonstrict",
        f"-- Generated by `sert run` (specs: {len(spec_rels)}); do not edit.",
        f'local sert = require({luau_string(_sert_require_target(root))})',
        "local options: any = sert.parseCliArgs(...)",
        "local shard = options.shard",
        "local shardIndex = if shard and shard.only == nil and shard.except == nil and (shard.count or 1) > 1 then shard.index else nil",
        "local shardCount = if shardIndex then shard.count else 1",
        f"local shardBySpec = shardIndex ~= nil and {len(spec_rels)} >= shardCount * 2 and options.filter == nil and options.files == nil",
        "if shardBySpec then options.shard = nil; options._specSharded = true end",
        "local specIndex = 0",
        "local function spec(file: string, load: () -> any, isSetup: boolean?)",
        "\tif not isSetup and shardBySpec then",
        "\t\tspecIndex += 1",
        "\t\tif ((specIndex - 1) % shardCount) + 1 ~= shardIndex then return end",
        "\tend",
        "\tlocal ok, result = pcall(load)",
        '\tif ok and not (type(result) == "string" and string.match(result, "^.-:%d+: ")) then return end',
        '\tlocal message = if not ok and string.find(tostring(result), "module must return a single value", 1, true)',
        '\t\tthen file .. " must return one value (a spec ends with `return {}`)" else `failed to load {file}: {result}`',
        "\tsert.test(file, function() error(message, 0) end, { file = file })",
        "end",
    ]
    if setup and not (root / setup).is_file():
        raise SertError(f"[test].setup: {setup} not found")
    if setup:
        srel = posix(root / setup, root)
        lines.append(f"spec({luau_string(srel)}, function() return require({luau_string('../' + _strip_luau_ext(srel))}) end, true)")
    for rel in spec_rels:
        lines.append(f"spec({luau_string(rel)}, function() return require({luau_string('../' + _strip_luau_ext(rel))}) end)")
    lines += ["return sert.run(options)", ""]
    runner_rel = ".sert/run.luau"
    runner_path = root / runner_rel
    runner_path.parent.mkdir(parents=True, exist_ok=True)
    runner_path.write_text("\n".join(lines), encoding="utf-8")
    return runner_rel


def resolve_entries(cfg: config_mod.Config, cli_entries: list[str] | None = None, cli_specs: list[str] | None = None) -> list[str]:
    if cli_entries and cli_specs:
        raise SertError("cannot pass both --entry and positional spec files")
    if cli_entries:
        return [str(e) for e in cli_entries]
    setup = cfg.get("test.setup")
    setup_str = str(setup) if setup else None
    if cli_specs:
        return [write_spec_runner(cfg.root, [str(s) for s in cli_specs], setup=setup_str)]
    entries = [str(e) for e in as_list(cfg.get("test.entries", []))]
    if specs := [str(s) for s in as_list(cfg.get("test.specs", []))]:
        entries.append(write_spec_runner(cfg.root, specs, setup=setup_str))
    if not entries and not cfg.exists:
        raise SertError(f"no sert.toml in {cfg.root} (run `{config_mod.command('init')}`)")
    if not entries:
        raise SertError("nothing to run: set [test].entries or [test].specs in sert.toml")
    return entries


@dataclass
class EntryRun:
    entry: str
    code: int | None
    seconds: float
    timed_out: bool = False
    output: str = ""


@dataclass
class RunResult:
    status: int
    entries: list[EntryRun] = field(default_factory=list)
    tests: list[dict] = field(default_factory=list)

    @property
    def counts(self) -> dict:
        counts = {"passed": 0, "failed": 0, "skipped": 0, "todo": 0, "total": len(self.tests)}
        for test in self.tests:
            if key := {"pass": "passed", "fail": "failed", "skip": "skipped", "todo": "todo"}.get(test.get("status")):
                counts[key] += 1
        return counts

    @property
    def crashed(self) -> list[EntryRun]:
        failing = {test["entry"] for test in self.tests if test.get("status") == "fail"}
        return [run for run in self.entries if (run.timed_out or run.code) and run.entry not in failing]


HIDDEN_MARKERS = ("test", "seed", "done")


def _pump(stream, chunks: list[str], echo, hide_markers: bool, closed=None) -> None:
    from sert.studio import markers

    echo = guarded(echo) if echo is not None else None
    for line in iter(stream.readline, ""):
        chunks.append(line)
        if echo is not None:
            found = markers.split(line) if hide_markers else None
            if found is None or found[0] not in HIDDEN_MARKERS:
                try:
                    echo.write(line)
                    echo.flush()
                except OutputClosed:
                    echo = None
                    closed()


FAILED_RAISE = re.compile(r"^\d+ of \d+ tests failed$")


def _shown_stderr(stdout: str, stderr: str) -> str:
    from sert.studio import markers

    if not any(isinstance(value, dict) and (value.get("failed") or 0) > 0 for value in markers.parse(stdout).done):
        return stderr
    lines = stderr.splitlines(keepends=True)
    for index in range(len(lines) - 1, -1, -1):
        if FAILED_RAISE.match(lines[index].rstrip("\r\n")):
            return "".join(lines[:index])
    return stderr


def _kill(process: subprocess.Popen) -> None:
    if os.name == "posix":
        try:
            os.killpg(process.pid, 9)
        except OSError:
            process.kill()
    else:
        subprocess.run(["taskkill", "/F", "/T", "/PID", str(process.pid)], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=10)
        process.kill()
    process.wait()


_SPEC_COUNT_RE = re.compile(r"^-- Generated by `sert run` \(specs: (\d+)\)", re.M)
_SHARD_HEADER_RE = re.compile(r"^sert · \d+ tests? · ")
_SHARD_SUMMARY_RE = re.compile(r"^\d+ passed · \d+ failed · \d+ skipped")


def _entry_shard_count(root: Path, entry: str, args: list[str], coverage: bool, jobs: int | None) -> int:
    for arg in args:
        if arg in ("--list", "-x", "--fail-fast", "--exhaustive") or arg.startswith(("--replay", "--mutant", "--mutants", "--shard")):
            return 1
        if jobs is None and not (arg in ("--markers", "--compact") or arg.startswith(("--seed=", "--runs=", "--budget="))):
            return 1
    target = jobs if jobs is not None else min(os.cpu_count() or 4, 6)
    if target <= 1:
        return 1
    try:
        src = (root / entry).read_text(encoding="utf-8", errors="ignore")
    except OSError:
        return 1
    if m := _SPEC_COUNT_RE.search(src):
        spec_count = int(m.group(1))
        if spec_count <= 1 and jobs is None:
            return 1
        if jobs is None and spec_count >= 18:
            target = min(os.cpu_count() or 4, min(12, spec_count // 3))
        return min(target, spec_count) if spec_count >= target * 2 else target
    if jobs is not None or "parseCliArgs" in src:
        return target
    return 1


def _run_sharded_entry(
    cfg: config_mod.Config,
    runner: str,
    binary: str,
    entry: str,
    args: list[str],
    coverage: bool,
    codegen: bool,
    timeout: float | None,
    markers: bool,
    asked: bool,
    echo: bool,
    shards: int,
) -> EntryRun:
    from concurrent.futures import ThreadPoolExecutor
    import tempfile
    from sert.studio import markers as markers_mod

    started = time.monotonic()
    entry_arg = str((cfg.root / entry).resolve()) if coverage else entry

    def run_shard(index: int) -> tuple[int | None, bool, str, str, str]:
        command = entry_command(runner, binary, entry_arg, [*args, f"--shard={index}/{shards}"], coverage, codegen)
        with contextlib.ExitStack() as stack:
            shard_cwd = Path(stack.enter_context(tempfile.TemporaryDirectory(prefix="sert-cov-"))) if coverage else cfg.root
            try:
                process = subprocess.Popen(
                    command, cwd=shard_cwd, stdout=subprocess.PIPE, stderr=subprocess.PIPE if echo else subprocess.STDOUT,
                    text=True, encoding="utf-8", errors="replace", start_new_session=os.name == "posix",
                )
            except OSError as err:
                raise SertError(f"could not run {binary}: {err}", INFRA)
            out_chunks: list[str] = []
            err_chunks: list[str] = []
            pumps = [threading.Thread(target=_pump, args=(process.stdout, out_chunks, None, False), daemon=True)]
            if echo:
                pumps.append(threading.Thread(target=_pump, args=(process.stderr, err_chunks, None, False), daemon=True))
            for pump in pumps:
                pump.start()
            timed_out = False
            code: int | None = None
            try:
                code = process.wait(timeout=timeout)
            except subprocess.TimeoutExpired:
                _kill(process)
                timed_out = True
            except KeyboardInterrupt:
                _kill(process)
                raise
            for pump, stream in zip(pumps, (process.stdout, process.stderr)):
                pump.join(timeout=10)
                if not pump.is_alive() and stream is not None:
                    stream.close()
            cov_file = shard_cwd / "coverage.out"
            cov_text = cov_file.read_text(encoding="utf-8", errors="replace") if coverage and cov_file.is_file() else ""
            return code, timed_out, "".join(out_chunks), "".join(err_chunks), cov_text

    with ThreadPoolExecutor(max_workers=shards) as pool:
        shard_runs = list(pool.map(run_shard, range(1, shards + 1)))

    if coverage:
        cov_chunks = [cov_text for _, _, _, _, cov_text in shard_runs if cov_text]
        if cov_chunks:
            (cfg.root / "coverage.out").write_text("".join(cov_chunks), encoding="utf-8")

    wall_seconds = time.monotonic() - started
    run = EntryRun(entry, 0, wall_seconds)
    totals = {"passed": 0, "failed": 0, "skipped": 0, "skippedRtest": 0, "todo": 0, "total": 0}
    any_done = False
    seed_line: str | None = None
    body_lines: list[str] = []
    marker_lines: list[str] = []
    err_parts: list[str] = []

    for w_code, w_timeout, w_out, w_err, _ in shard_runs:
        if w_timeout:
            run.timed_out = True
        if w_code not in (None, 0) and run.code == 0:
            run.code = w_code
        elif w_code is None and run.code == 0:
            run.code = None
        if echo and w_err:
            err_parts.append(_shown_stderr(w_out, w_err))
        parsed = markers_mod.parse(w_out)
        for d in parsed.done:
            if isinstance(d, dict):
                any_done = True
                for k in totals:
                    totals[k] += int(d.get(k) or 0)
        lines = w_out.splitlines(keepends=True)
        for idx, line in enumerate(lines):
            found = markers_mod.split(line)
            if found is not None:
                kind = found[0]
                if kind == "seed":
                    if seed_line is None:
                        seed_line = line if line.endswith("\n") else line + "\n"
                elif kind != "done":
                    marker_lines.append(line if line.endswith("\n") else line + "\n")
                continue
            stripped = line.rstrip("\r\n")
            if _SHARD_HEADER_RE.match(stripped) or _SHARD_SUMMARY_RE.match(stripped):
                continue
            if stripped == "" and idx + 1 < len(lines) and _SHARD_SUMMARY_RE.match(lines[idx + 1].rstrip("\r\n")):
                continue
            body_lines.append(line if line.endswith("\n") else line + "\n")

    if not any_done:
        raw_out = "".join(w_out for _, _, w_out, _, _ in shard_runs)
        raw_err = "".join(w_err for _, _, _, w_err, _ in shard_runs)
        if echo and raw_out:
            guarded(sys.stdout).write(raw_out)
            guarded(sys.stdout).flush()
        if echo and err_parts:
            sys.stderr.write("".join(err_parts))
            sys.stderr.flush()
        run.output = raw_out + raw_err
        return run

    if totals["failed"] > 0 and run.code == 0:
        run.code = 1
    header = f"sert · {totals['total']} {'test' if totals['total'] == 1 else 'tests'} · Luau CLI · {shards} workers\n"
    rtest_note = f" ({totals['skippedRtest']} rtest — run 'python3 tools/sert.py studio' to execute engine tests)" if totals["skippedRtest"] > 0 else ""
    todo_note = f" · {totals['todo']} todo" if totals["todo"] > 0 else ""
    footer = f"\n{totals['passed']} passed · {totals['failed']} failed · {totals['skipped'] - totals.get('unselected', 0)} skipped{rtest_note}{todo_note} · {round(wall_seconds * 1000)} ms\n"
    done_payload = {**totals, "clock": round(wall_seconds, 6)}
    done_line = f"[sert-done] {json.dumps(done_payload, separators=(',', ':'))}\n"

    human_text = header + "".join(body_lines) + footer
    if echo:
        out_stream = guarded(sys.stdout)
        if markers and not asked:
            out_stream.write(human_text)
        else:
            out_stream.write(header + (seed_line or "") + "".join(body_lines) + "".join(marker_lines) + footer + done_line)
        out_stream.flush()
        if err_parts:
            sys.stderr.write("".join(err_parts))
            sys.stderr.flush()

    raw_err = "".join(w_err for _, _, _, w_err, _ in shard_runs)
    run.output = header + (seed_line or "") + "".join(body_lines) + "".join(marker_lines) + footer + done_line + raw_err
    return run


def run_entries(
    cfg: config_mod.Config,
    entries: list[str],
    *,
    runner: str | None = None,
    program_args=(),
    coverage: bool = False,
    codegen: bool = False,
    timeout: float | None = None,
    markers: bool = True,
    echo: bool = True,
    stop_on_timeout: bool = True,
    jobs: int | None = None,
) -> RunResult:
    from sert.studio import markers as markers_mod

    runner = runner_of(cfg, runner, coverage)
    for entry in entries:
        if not (cfg.root / entry).is_file():
            raise SertError(f"[test].entries: {entry} not found")
    require_fetched(cfg, runner)
    binary = luau_command(cfg.root, runner)
    args = [str(a) for a in program_args]
    asked = "--markers" in args
    if markers and not asked:
        args.append("--markers")
    coverage_out = cfg.root / "coverage.out"
    chunks: list[str] = []
    result = RunResult(OK)
    for entry in entries:
        if coverage:
            coverage_out.unlink(missing_ok=True)
        shards = _entry_shard_count(cfg.root, entry, args, coverage, jobs)
        if shards > 1:
            run = _run_sharded_entry(cfg, runner, binary, entry, args, coverage, codegen, timeout, markers, asked, echo, shards)
        else:
            command = entry_command(runner, binary, entry, args, coverage, codegen)
            started = time.monotonic()
            try:
                process = subprocess.Popen(
                    command, cwd=cfg.root, stdout=subprocess.PIPE, stderr=subprocess.PIPE if echo else subprocess.STDOUT,
                    text=True, encoding="utf-8", errors="replace", start_new_session=os.name == "posix",
                )
            except OSError as err:
                raise SertError(f"could not run {binary}: {err}", INFRA)
            run = EntryRun(entry, None, 0.0)
            out_chunks: list[str] = []
            err_chunks: list[str] = []
            closed = threading.Event()

            def stop(process=process):
                closed.set()
                _kill(process)

            pumps = [threading.Thread(target=_pump, args=(process.stdout, out_chunks, sys.stdout if echo else None, markers and not asked, stop), daemon=True)]
            if echo:
                pumps.append(threading.Thread(target=_pump, args=(process.stderr, err_chunks, None, False), daemon=True))
            for pump in pumps:
                pump.start()
            try:
                run.code = process.wait(timeout=timeout)
            except subprocess.TimeoutExpired:
                _kill(process)
                run.timed_out = True
            except KeyboardInterrupt:
                _kill(process)
                raise
            for pump, stream in zip(pumps, (process.stdout, process.stderr)):
                pump.join(timeout=10)
                if not pump.is_alive():
                    stream.close()
            if closed.is_set():
                raise OutputClosed
            run.output = "".join(out_chunks) + "".join(err_chunks)
            run.seconds = time.monotonic() - started
            if echo and err_chunks:
                sys.stderr.write(_shown_stderr("".join(out_chunks), "".join(err_chunks)))
                sys.stderr.flush()
        result.entries.append(run)
        for test in markers_mod.parse(run.output).tests:
            result.tests.append({**test, "entry": entry})
        if coverage and len(entries) > 1 and coverage_out.is_file():
            chunks.append(coverage_out.read_text(encoding="utf-8", errors="replace"))
        if run.timed_out:
            if echo:
                lost = not any(test["entry"] == entry for test in result.tests)
                note(f"{entry}: timed out after {timeout:g}s" + (f"; {runner}'s buffered output is lost on the kill, so no test result was read (find the hung test with --filter)" if lost else ""))
            result.status = TIMEOUT
            if stop_on_timeout:
                break
        elif run.code != 0:
            if echo:
                if snippets := _format_failure_snippets(run.output, cfg.root):
                    print(snippets, file=sys.stderr)
                note(f"{entry}: failed (exit {run.code}, {run.seconds:.1f}s)")
            if result.status == OK:
                result.status = FAILED
    if coverage and len(entries) > 1 and chunks:
        coverage_out.write_text("".join(chunks), encoding="utf-8")
    return result


LOCATION = re.compile(r"([\w@./\\-]+?)(?:\.luau|\.lua)?:(\d+):")
SNIPPET_LOC = re.compile(r"([\w@./\\-]+?\.(?:luau|lua)|[\w@./\\-]+?):(\d+)(?::|\b)")


def _resolve_root_file(root: Path, raw_name: str) -> Path | None:
    clean = raw_name.replace("\\", "/").lstrip("@")
    for prefix in ("./", "../", ".sert/stage/files/", "self/files/"):
        while clean.startswith(prefix):
            clean = clean[len(prefix) :]
    for candidate in (clean, clean + ".luau", clean + ".lua", raw_name):
        if not candidate:
            continue
        path = root / candidate
        if path.is_file():
            return path
    return None


def _format_failure_snippets(output_text: str, root: Path) -> str:
    if not output_text:
        return ""
    root = Path(root)
    blocks = output_text.split("❌ ")
    if len(blocks) > 1:
        failure_blocks = ["❌ " + b for b in blocks[1:]]
    elif "⚠️" in output_text or ".luau:" in output_text or ".lua:" in output_text:
        failure_blocks = [output_text]
    else:
        return ""

    rendered_blocks: list[str] = []
    for block in failure_blocks:
        seen: list[tuple[str, int, Path]] = []
        for line in block.splitlines():
            if "[sert-" in line:
                continue
            for match in SNIPPET_LOC.finditer(line):
                raw_name, line_str = match.group(1), match.group(2)
                path = _resolve_root_file(root, raw_name)
                if path is None:
                    continue
                rel = posix(path, root)
                if rel == ".sert/run.luau":
                    continue
                line_no = int(line_str)
                if not any(r == rel and ln == line_no for r, ln, _ in seen):
                    seen.append((rel, line_no, path))
                    if len(seen) >= 2:
                        break
            if len(seen) >= 2:
                break

        for rel, line_no, path in seen:
            try:
                src_lines = path.read_text(encoding="utf-8", errors="replace").splitlines()
            except OSError:
                continue
            if not (1 <= line_no <= len(src_lines)):
                continue
            start_ln = max(1, line_no - 1)
            end_ln = min(len(src_lines), line_no + 1)
            width = len(str(end_ln))
            snippet_lines = [f"   {rel}:{line_no}:"]
            for ln in range(start_ln, end_ln + 1):
                marker = " > " if ln == line_no else "   "
                snippet_lines.append(f"{marker}{ln:>{width}} | {src_lines[ln - 1]}")
            rendered_blocks.append("\n".join(snippet_lines))

    return "\n".join(rendered_blocks)


def failure_location(root: Path, test: dict) -> tuple[str | None, int | None]:
    message = str(test.get("message") or test.get("error") or "")
    for match in LOCATION.finditer(message):
        name = match.group(1).lstrip("@").removeprefix("./")
        for candidate in (name, name + ".luau", name + ".lua"):
            path = root / candidate
            if candidate and path.is_file():
                return posix(path, root), int(match.group(2))
    if name := str(test.get("file") or ""):
        found = [p for p in expand_globs(root, [f"**/{name}.luau", f"**/{name}.spec.luau"], files=True) if ".sert" not in p.relative_to(root).parts]
        if len(found) == 1:
            return posix(found[0], root), None
    return None, None


def annotate_failures(root: Path, result: RunResult) -> None:
    if not on_github_actions():
        return
    for test in result.tests:
        if test.get("status") == "fail":
            file, line = failure_location(root, test)
            annotate("error", f"{test.get('name')}: {test.get('message') or 'failed'}", file=file, line=line, title="sert run")
    for run in result.crashed:
        why = "timed out" if run.timed_out else f"exited {run.code}"
        annotate("error", f"{run.entry} {why} without a failed test", file=run.entry, title="sert run")


ANSI = re.compile(r"\x1b\[[0-9;?]*[ -/]*[@-~]")
XML_INVALID = re.compile("[^\t\n\r\x20-\ud7ff\ue000-\ufffd\U00010000-\U0010ffff]")


def xml_text(value) -> str:
    return XML_INVALID.sub("\ufffd", ANSI.sub("", str(value)))


def junit_xml(result: RunResult) -> bytes:
    suites: dict[str, list[dict]] = {}
    for test in result.tests:
        suites.setdefault(str(test.get("file") or test["entry"]), []).append(test)
    for run in result.crashed:
        why = "timed out" if run.timed_out else f"exited {run.code}"
        tail = run.output.strip().splitlines()[-20:]
        suites.setdefault(run.entry, []).append({"name": f"{run.entry} {why}", "status": "fail", "ms": int(run.seconds * 1000), "message": "\n".join(tail) or why, "entry": run.entry})
    counts = result.counts
    root = ElementTree.Element(
        "testsuites", name="sert", tests=str(sum(len(t) for t in suites.values())),
        failures=str(counts["failed"] + len(result.crashed)), skipped=str(counts["skipped"] + counts["todo"]),
        time=f"{sum(run.seconds for run in result.entries):.3f}",
    )
    for name in sorted(suites):
        tests = suites[name]
        suite = ElementTree.SubElement(
            root, "testsuite", name=xml_text(name), tests=str(len(tests)),
            failures=str(sum(1 for t in tests if t.get("status") == "fail")),
            skipped=str(sum(1 for t in tests if t.get("status") in ("skip", "todo"))),
            time=f"{sum(int(t.get('ms') or 0) for t in tests) / 1000:.3f}",
        )
        for test in tests:
            case = ElementTree.SubElement(suite, "testcase", name=xml_text(test.get("name")), classname=xml_text(name), time=f"{int(test.get('ms') or 0) / 1000:.3f}")
            if test.get("status") == "fail":
                message = xml_text(test.get("message") or "failed")
                failure = ElementTree.SubElement(case, "failure", message=message.splitlines()[0] if message else "")
                failure.text = message
            elif test.get("status") == "skip":
                ElementTree.SubElement(case, "skipped")
            elif test.get("status") == "todo":
                ElementTree.SubElement(case, "skipped", message="todo")
    ElementTree.indent(root)
    return ElementTree.tostring(root, encoding="utf-8", xml_declaration=True) + b"\n"


def json_report(result: RunResult) -> dict:
    return {
        "status": result.status,
        "counts": result.counts,
        "entries": [{"entry": run.entry, "code": run.code, "seconds": round(run.seconds, 3), "timedOut": run.timed_out} for run in result.entries],
        "tests": [{k: v for k, v in test.items() if k in ("name", "file", "status", "ms", "message", "seed", "entry")} for test in result.tests],
    }


def _unreported_spec_entry(result: RunResult) -> str | None:
    from sert.studio import markers as markers_mod

    for run in result.entries:
        if not run.entry.endswith((".spec.luau", ".spec.lua")) or run.timed_out or run.code != 0:
            continue
        parsed = markers_mod.parse(run.output)
        if parsed.list_total is not None or parsed.listed or parsed.tests or any(isinstance(v, dict) for v in parsed.done):
            continue
        return run.entry
    return None


def ran_nothing(result: RunResult) -> bool:
    from sert.studio import markers as markers_mod

    reported = False
    for run in result.entries:
        parsed = markers_mod.parse(run.output)
        if parsed.list_total is not None or parsed.listed:
            return False
        done = [value for value in parsed.done if isinstance(value, dict)]
        if parsed.tests or done:
            reported = True
        if any(t.get("status") in ("pass", "fail") for t in parsed.tests) or any(
            isinstance(value.get(key), (int, float)) and value[key] > 0 for value in done for key in ("passed", "failed")
        ):
            return False
    return reported or _unreported_spec_entry(result) is not None


def write_reports(root: Path, result: RunResult, junit: str | None = None, json_out: str | None = None) -> None:
    for target, data in ((junit, lambda: junit_xml(result)), (json_out, lambda: (json.dumps(json_report(result), indent=2) + "\n").encode())):
        if target:
            path = root / target
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(data())


def _seed(value: str) -> str:
    if value != "random":
        try:
            int(value)
        except ValueError:
            raise argparse.ArgumentTypeError(f"takes an integer or random, not {value!r}") from None
    return value


class _OneFilter(argparse.Action):
    def __call__(self, parser, namespace, value, option_string=None):
        if (old := getattr(namespace, self.dest, None)) is not None:
            parser.error(f'one filter only, got "{old}" and "{value}" (quote a filter with spaces)')
        setattr(namespace, self.dest, value)


_SUMMARY_COUNTS_RE = re.compile(r"(\d+)\s+passed\s+·\s+(\d+)\s+failed\s+·\s+(\d+)\s+skipped")


def _skipped_only_count(result: RunResult) -> int:
    from sert.studio import markers as markers_mod

    total_skipped = 0
    for run in result.entries:
        m = _SUMMARY_COUNTS_RE.search(run.output)
        if m is not None:
            if int(m.group(1)) == 0 and int(m.group(2)) == 0:
                total_skipped += int(m.group(3))
            continue
        parsed = markers_mod.parse(run.output)
        if parsed.tests:
            if all(t.get("status") == "skip" for t in parsed.tests):
                total_skipped += len(parsed.tests)
            continue
        for value in parsed.done:
            if isinstance(value, dict) and (value.get("passed") or 0) == 0 and (value.get("failed") or 0) == 0:
                total_skipped += int(value.get("skipped") or 0)
    return total_skipped


def selection_args(args) -> list[str]:
    tokens = [f"--filter={args.filter}"] if getattr(args, "filter", None) is not None else []
    for flag in ("fail_fast", "compact", "list", "exhaustive"):
        if getattr(args, flag, False) or (flag == "compact" and os.environ.get("SERT_COMPACT") == "1"):
            tokens.append("--" + flag.replace("_", "-"))
    for flag in ("seed", "runs", "replay", "budget"):
        if (value := getattr(args, flag, None)) is not None:
            tokens.append(f"--{flag}={value:g}" if isinstance(value, float) else f"--{flag}={value}")
    return tokens


def add_parser(subparsers) -> None:
    parser = subparsers.add_parser("run")
    parser.add_argument("--coverage", action="store_true", help="pass --coverage to luau (writes coverage.out)")
    parser.add_argument("--codegen", action="store_true", help="pass --codegen to luau (default)")
    parser.add_argument("--no-codegen", action="store_true", help="do not pass --codegen to luau")
    parser.add_argument("-j", "--jobs", type=int, metavar="N", help="worker processes for sharded suites")
    parser.add_argument("--timeout", type=float, metavar="S", help="seconds per entry before it counts as timed out (exit 3)")
    parser.add_argument("--entry", action="append", metavar="FILE", help="run only this entry (repeatable)")
    parser.add_argument("--junit", metavar="FILE", help="write a JUnit XML report (relative to the root)")
    parser.add_argument("--json-out", metavar="FILE", help="write the results as JSON (relative to the root)")
    parser.add_argument("specs", nargs="*", help="spec files, globs or directories to run instead of [test]")
    selection = parser.add_argument_group("selection (sent to every entry)")
    selection.add_argument("--filter", action=_OneFilter, metavar="NAME", help="run the tests whose name contains NAME")
    selection.add_argument("-x", "--fail-fast", action="store_true", help="stop at the first failure")
    selection.add_argument("--compact", action="store_true", help="suppress passing ✅ lines while keeping failures and summary")
    selection.add_argument("--list", action="store_true", help="print the catalogue; run nothing")
    selection.add_argument("--seed", type=_seed, metavar="N|random", help="base seed of every property")
    selection.add_argument("--runs", type=int, metavar="N", help="cases per property")
    selection.add_argument("--replay", type=int, metavar="N", help="run one case of the matching properties, by the seed a failure printed")
    selection.add_argument("--exhaustive", action="store_true", help="run only the bounded-exhaustive properties")
    selection.add_argument("--budget", type=float, metavar="S", help="seconds an exhaustive property may take")
    parser.add_argument("-a", dest="program_args", nargs=argparse.REMAINDER, default=[], help="anything else for every entry (sert.parseCliArgs flags)")
    parser.set_defaults(func=main)


def cmd_run(args, root: Path | None = None, cfg: config_mod.Config | dict | None = None) -> int:
    check_selection(args)
    program_args = getattr(args, "program_args", None) or []
    if "--silent" in program_args:
        raise SertError("sert run: --silent hides the markers sert run reads its results from; it is for hand-run entries")
    if cfg is None or not isinstance(cfg, config_mod.Config):
        cfg = config_mod.from_args(args)
    from sert import fetch

    coverage = bool(getattr(args, "coverage", False))
    runner = runner_of(cfg, coverage=coverage)
    codegen = (bool(cfg.get("test.codegen", True)) or getattr(args, "codegen", False)) and not getattr(args, "no_codegen", False)
    jobs_arg = getattr(args, "jobs", None)
    cfg_jobs = cfg.get("test.jobs")
    jobs = jobs_arg if jobs_arg is not None else (int(cfg_jobs) if cfg_jobs is not None else None)
    if jobs is not None and jobs < 1:
        raise SertError(f"--jobs takes a whole number from 1, got {jobs}")
    fetch.refresh_overrides(cfg)
    fetch.ensure_fetched(cfg)
    entries = resolve_entries(cfg, getattr(args, "entry", None), getattr(args, "specs", None))
    if stage_spec := cfg.get("test.stage"):
        stage_project(cfg.root, str(stage_spec))
    result = run_entries(cfg, entries, runner=runner, program_args=[*selection_args(args), *program_args], coverage=coverage, codegen=codegen, timeout=getattr(args, "timeout", None), jobs=jobs)
    if result.status == OK and ran_nothing(result):
        skipped_count = _skipped_only_count(result) if (getattr(args, "filter", None) or getattr(args, "specs", None)) else 0
        if spec_entry := _unreported_spec_entry(result):
            note(
                f"sert run: {spec_entry} exited without running any tests: "
                f"--entry takes a runner script that calls sert.run(), while spec files should be passed as positional arguments (sert run {spec_entry})"
            )
        elif skipped_count > 0:
            note(f"sert run: all {skipped_count} matching tests were skipped (use 'python3 tools/sert.py studio' to run rtest engine specs)")
        else:
            note("sert run: no test ran: the selection matched none of the tests")
        result.status = FAILED
    annotate_failures(cfg.root, result)
    write_reports(cfg.root, result, getattr(args, "junit", None), getattr(args, "json_out", None))
    return result.status


def main(args) -> int:
    return cmd_run(args)
