"""`sert studio`: run a repo's suite in a fresh, unattended Roblox Studio and keep its results.

    sert studio                                    # every test, in [studio].mode (edit, play or run)
    sert studio --mode play --mode run             # play, then run mode
    sert studio --file Button --file client/Menu   # only these spec files (base name, or <dir>/<Name>)
    sert studio --filter toast --filter tooltip    # names containing either (case-insensitive)
    sert studio --grep '^device matrix · '         # names matching a regex (Python re, case-insensitive)
    sert studio --side server --exclude "page perf"
    sert studio --failed                           # the last run's failures; failed properties replay their seeds
    sert studio --list --file Menu                 # print what the selection picks; runs nothing
    sert studio --repeat 3                         # the selection 3 times in one session: <out>/flake.json
    sert studio --seed 1234 --runs 500             # property and model tests: base seed and cases
    sert studio --filter "queue · pops" --replay=3714881375  # one case of a property, by the seed its failure printed
    sert studio --exhaustive --budget 120          # only the bounded-exhaustive properties
    sert studio --check                            # no Studio: the place builds, drift and hook checks pass
    sert studio --suite ui                         # one of the [studio.suites.<name>] (default: every suite)

Exit status: 0 passed (or listed), 1 a test failed or none ran, 2 infrastructure or usage, 3 timeout, 130 interrupted.
"""

from __future__ import annotations

import argparse
import hashlib
import importlib.util
import json
import math
import os
from pathlib import Path
import random
import re
import subprocess
import sys
import tempfile
import threading
import time

from sert import config as sert_config
from sert.util import (
    INFRA,
    INTERRUPTED,
    SertError,
    build_place,
    check_selection,
    expand_globs,
    load_json,
    luau_string,
    worst,
    write_atomic,
)

# -- Markers (`[sert-<kind>] <payload>`) -----------------------------------------------------------------------------

MARKER = re.compile(r"^\s*\[sert-([a-z]+)(?::([^\]\s]+))?\] ?(.*)$")
LIST_END = re.compile(r"^end (\d+)$")
PHASE = re.compile(r"^(\S+) (\S+) (\d+)$")
ITER = re.compile(r"^(\S+) (\d+) (begin|end(?: (.*))?)$")
FRAME = re.compile(r"^(?:(\w+) )?(\d+(?:\.\d+)?)(?: ?ms)?$")
FILE = re.compile(r"^([^|]*)\|(.*)\|(\d+)$")
SEED_RUN = re.compile(r"^run (\d+)$")
SEED_TEST = re.compile(r"^(.*)\|(\d+)$")
VERDICT = "[sert-verdict]"


def split(line: str):
    """(kind, tag, payload) for a marker line, else None. `tag` is the `<tag>` of `[sert-x:<tag>]`, else None."""
    match = MARKER.match(line)
    return (match.group(1), match.group(2), match.group(3).rstrip("\r")) if match else None


def _json(payload: str):
    try:
        return json.loads(payload)
    except ValueError:
        return None


def is_wrapper(value) -> bool:
    """The runscript's generated-driver line, {ok, value?, error?}, rather than a verdict or sert's Results."""
    return isinstance(value, dict) and "ok" in value and set(value) <= {"ok", "value", "error"}


def normalize_test(value: dict) -> dict:
    test = dict(value)
    test["status"] = str(test.get("status", ""))
    if "error" in test and "message" not in test:
        test["message"] = test["error"]
    try:
        test["ms"] = int(test.get("ms") or 0)
    except (TypeError, ValueError):
        test["ms"] = 0
    return test


class Parsed:
    """Everything sert printed in one run's output."""

    def __init__(self):
        self.listed: list[dict] = []
        self.list_places: list[dict] = []
        self.list_total: int | None = None
        self.files: list[dict] = []
        self.tests: list[dict] = []
        self.run_seed: int | None = None
        self.seeds: dict[str, int] = {}
        self.phases: dict[str, int] = {}
        self.iterations: list[dict] = []
        self.frame: float | None = None
        self.frames: dict[str, float] = {}
        self.done: list = []
        self.verdicts: list = []
        self.x: list[tuple[str, str]] = []
        self.outcomes: list = []

    @property
    def catalogue(self) -> list[dict] | None:
        if self.list_total is None or self.list_total != len(self.listed):
            return None
        sides: dict[str, str] = {}
        for entry in self.files:
            if entry["file"] != "*":
                sides.setdefault(entry["file"], entry["side"])
        out = []
        for index, test in enumerate(self.listed):
            place = self.list_places[index] if index < len(self.list_places) else {}
            side = place.get(test["file"]) or sides.get(test["file"])
            out.append({**test, "side": side} if side is not None else dict(test))
        return out

    @property
    def verdict(self) -> dict | None:
        for value in reversed(self.verdicts):
            if isinstance(value, dict) and not is_wrapper(value):
                return value
        for value in reversed(self.verdicts):
            if is_wrapper(value) and isinstance(value.get("value"), dict) and "counts" in value["value"]:
                return value["value"]
        return None

    @property
    def results(self) -> dict | None:
        verdict = self.verdict
        if verdict is not None and isinstance(verdict.get("counts"), dict):
            counts = verdict["counts"]
            return {**{k: v for k, v in verdict.items() if k not in ("passed", "failed")},
                    **{k: counts.get(k, 0) for k in ("passed", "failed", "skipped", "todo", "total")},
                    "verdictPassed": verdict.get("passed")}
        for value in reversed(self.done):
            if isinstance(value, dict) and not is_wrapper(value):
                return value
        return None

    def per_iteration(self) -> list[list[dict]]:
        return [iteration["tests"] for iteration in self.iterations] if self.iterations else [self.tests]


def parse(output: str, on_marker=None) -> Parsed:
    """Parses a run's output. `on_marker(tag, payload)` is called for each `[sert-x:<tag>]` line, in order."""
    parsed = Parsed()
    current_iter: dict | None = None
    place: dict[str, str] = {}
    by_n: dict[int, dict] = {}
    after_list_end = False

    for line in output.splitlines():
        found = split(line)
        listed, after_list_end = after_list_end, False
        if found is None:
            continue
        kind, tag, payload = found
        if kind == "list":
            end = LIST_END.match(payload)
            if end:
                after_list_end = True
                parsed.list_total = (parsed.list_total or 0) + int(end.group(1))
                place = {}
            elif "|" in payload:
                file, _, name = payload.partition("|")
                parsed.listed.append({"file": file, "name": name})
                parsed.list_places.append(place)
        elif kind == "file":
            match = FILE.match(payload)
            if match:
                parsed.files.append({"side": match.group(1), "file": match.group(2), "ms": int(match.group(3))})
                if match.group(2) != "*":
                    place = {**place, match.group(2): match.group(1)}
        elif kind == "test":
            value = _json(payload)
            if isinstance(value, dict) and "name" in value:
                test = normalize_test(value)
                if current_iter is not None:
                    test["iteration"] = current_iter["n"]
                    current_iter["tests"].append(test)
                parsed.tests.append(test)
        elif kind == "seed":
            run_m = SEED_RUN.match(payload)
            if run_m:
                if parsed.run_seed is None:
                    parsed.run_seed = int(run_m.group(1))
            elif match := SEED_TEST.match(payload):
                parsed.seeds[match.group(1)] = int(match.group(2))
        elif kind == "phase":
            if match := PHASE.match(payload):
                parsed.phases.setdefault(f"{match.group(1)}.{match.group(2)}", int(match.group(3)))
        elif kind == "iter":
            if match := ITER.match(payload):
                where, n, rest, delta = match.group(1), int(match.group(2)), match.group(3), match.group(4)
                if rest == "begin":
                    if n not in by_n:
                        by_n[n] = {"n": n, "summary": "", "tests": [], "deltas": {}}
                        parsed.iterations.append(by_n[n])
                    current_iter = by_n[n]
                else:
                    if (iteration := by_n.get(n)) is not None:
                        iteration["deltas"][where] = _json(delta or "")
                        iteration["summary"] = iteration_summary(iteration["deltas"])
                    current_iter = None
        elif kind == "frame":
            if match := FRAME.match(payload.strip()):
                number = float(match.group(2))
                number = int(number) if number.is_integer() else number
                key = match.group(1) or "run"
                parsed.frames[key] = number
                if key == "run":
                    parsed.frame = number
        elif kind in ("done", "verdict"):
            value = _json(payload)
            (parsed.done if kind == "done" else parsed.verdicts).append(value)
            if value is not None and not (kind == "done" and listed):
                parsed.outcomes.append(value)
        elif kind == "x" and tag:
            parsed.x.append((tag, payload))
            if on_marker is not None:
                on_marker(tag, payload)

    verdict = parsed.verdict
    if verdict is not None and isinstance(verdict.get("seeds"), dict):
        for name, seed in verdict["seeds"].items():
            if isinstance(seed, int) and not isinstance(seed, bool):
                parsed.seeds.setdefault(name, seed)
        if parsed.run_seed is None and isinstance(verdict.get("seed"), int):
            parsed.run_seed = verdict["seed"]
    for test in parsed.tests:
        if test["status"] == "fail" and test["name"] in parsed.seeds and "seed" not in test:
            test["seed"] = parsed.seeds[test["name"]]
    return parsed


def iteration_summary(deltas: dict) -> str:
    counts = {"passed": 0, "failed": 0, "skipped": 0, "todo": 0, "total": 0}
    for delta in deltas.values():
        if isinstance(delta, dict):
            for key in counts:
                value = delta.get(key)
                counts[key] += value if isinstance(value, int) and not isinstance(value, bool) else 0
    return f"FAILED {counts['failed']} of {counts['total']}" if counts["failed"] else f"PASSED {counts['passed']}/{counts['total']}"


def _number(value) -> bool:
    return isinstance(value, (int, float)) and not isinstance(value, bool)


def failure(value, depth: int = 0) -> str | None:
    """Why a result reports failure, else None."""
    if value is False:
        return "false"
    if not isinstance(value, dict):
        return None
    for key in ("ok", "success", "passed"):
        if value.get(key) is False:
            return f"{key}=false"
    failed = value.get("failed")
    if _number(failed) and failed > 0:
        return f"failed={json.dumps(failed)}"
    if isinstance(value.get("passed"), bool) and isinstance(value.get("counts"), dict):
        if not value.get("listed") and (why := failure(value["counts"], depth + 1)):
            return why
    elif "passed" in value and "failed" in value:
        counts = [value.get("passed"), value.get("failed")]
        if any(not _number(n) or (isinstance(n, float) and not math.isfinite(n)) or n < 0 or n % 1 != 0 for n in counts):
            return "invalid test counts"
        if sum(counts) == 0:
            return "no tests executed"
    if "value" in value:
        return "result nested too deeply" if depth >= 64 else failure(value["value"], depth + 1)
    return None


def reports_failure(value) -> bool:
    return failure(value) is not None


# -- Settings & Suites -----------------------------------------------------------------------------------------------

DEFAULT_OUT = "build/sert"
DEFAULT_SPECS = ("test/**/*.spec.luau",)
DEFAULT_RUNNER = "ReplicatedStorage/sert/roblox/Runner"
DEFAULT_TIMEOUT = 900.0
RUN_LEVEL_DEFAULT = r"^\w+ · (no script errors|reports|runs|after|.* (loads|ready))$"


def base(name: str) -> str:
    name = os.path.basename(name.replace("\\", "/"))
    for suffix in (".luau", ".lua", ".spec"):
        if name.endswith(suffix):
            name = name[: -len(suffix)]
    return name


def save_json(path: str, value) -> None:
    os.makedirs(os.path.dirname(path), exist_ok=True)
    write_atomic(Path(path), (json.dumps(value, indent=1, ensure_ascii=False) + "\n").encode("utf-8"), 0o644)


def instance_path(value, root: str | None = None, project: str | None = None) -> list[str]:
    if isinstance(value, list):
        return [str(part) for part in value]
    text = str(value)
    if root and project and (text.endswith((".luau", ".lua")) or os.path.exists(os.path.join(root, text))):
        tree = (load_json(project) or {}).get("tree")
        target = os.path.normpath(os.path.join(root, text))
        proj_dir = os.path.dirname(project)

        def walk(node, prefix: list[str]) -> list[str] | None:
            if not isinstance(node, dict):
                return None
            if isinstance(node_path := node.get("$path"), str):
                fs_path = os.path.normpath(os.path.join(proj_dir, node_path))
                if target == fs_path:
                    return prefix
                if target.startswith(fs_path + os.sep):
                    rel = os.path.relpath(target, fs_path).replace("\\", "/")
                    for suffix in ("/init.luau", "/init.lua", ".luau", ".lua"):
                        if rel.endswith(suffix):
                            rel = rel[: -len(suffix)]
                            break
                    return prefix + [p for p in rel.split("/") if p and p != "init"]
            for key, child in node.items():
                if not key.startswith("$") and (found := walk(child, prefix + [key])) is not None:
                    return found
            return None

        if resolved := walk(tree, []):
            return resolved
    return [part for part in text.split("/") if part]


class Settings:
    """[studio] of sert.toml (with sert.local.toml over it), resolved against the root."""

    def __init__(self, root: str, conf: dict, suite: str | None = None):
        studio = dict(conf.get("studio") or {})
        suites_tbl = studio.pop("suites", None) or {}
        if not isinstance(suites_tbl, dict) or not all(isinstance(v, dict) for v in suites_tbl.values()):
            raise SertError("[studio.suites] must hold one table per suite")
        self.suites = list(suites_tbl)
        self.default_suites = [name for name, own in suites_tbl.items() if own.get("default", True)]
        self.suite = suite
        out = studio.get("out", DEFAULT_OUT)
        if suite is not None:
            if suite not in suites_tbl:
                raise SertError(f"no [studio.suites.{suite}] (have: {', '.join(self.suites) or 'none'})")
            own = suites_tbl[suite]
            out = own.get("out", os.path.join(out, suite))
            studio = {**studio, **own}
        self.root, self.conf, self.studio = root, conf, studio
        self.project = os.path.join(root, studio.get("project", "test/default.project.json"))
        mode = studio.get("mode", "play")
        self.modes = list(mode) if isinstance(mode, list) else [mode]
        self.out = os.path.join(root, out)
        specs = studio.get("specs", list(DEFAULT_SPECS))
        self.specs = [specs] if isinstance(specs, str) else list(specs)
        self.runner_path = instance_path(studio.get("runner", DEFAULT_RUNNER), root, self.project)
        config = studio.get("config")
        self.config_path = instance_path(config, root, self.project) if config else None
        self.hooks = os.path.join(root, studio["hooks"]) if studio.get("hooks") else None
        self.timeout = float(studio.get("timeout", DEFAULT_TIMEOUT))
        self.launcher = studio.get("launcher")
        self.list_command = studio.get("list_command")
        self.sides = list(studio.get("sides", []))
        self.drift = list(studio.get("drift", []))
        raw_run_level = studio.get("run_level", RUN_LEVEL_DEFAULT)
        try:
            self.run_level = re.compile(raw_run_level)
        except re.error as err:
            raise SertError(f"invalid [studio].run_level regex {raw_run_level!r}: {err}") from err

    @property
    def pending_suites(self) -> bool:
        return bool(self.suites) and self.suite is None

    def suite_settings(self) -> list[Settings]:
        return [Settings(self.root, self.conf, name) for name in self.suites]

    @property
    def catalogue_path(self) -> str:
        return os.path.join(self.out, "catalogue.json")

    @property
    def last_path(self) -> str:
        return os.path.join(self.out, "last.json")

    @property
    def flake_path(self) -> str:
        return os.path.join(self.out, "flake.json")

    def spec_files(self) -> list[str]:
        return [os.path.join(self.root, *path.relative_to(Path(self.root)).parts)
                for path in expand_globs(Path(self.root), self.specs, files=True)]

    def spec_digest(self) -> str:
        digest = hashlib.sha256()
        for path in self.spec_files():
            digest.update(os.path.relpath(path, self.root).replace("\\", "/").encode() + b"\0")
            with open(path, "rb") as handle:
                digest.update(hashlib.sha256(handle.read()).digest())
        return digest.hexdigest()


def known_sides(settings: Settings | None) -> list[str] | None:
    if settings is None:
        return None
    found = list(settings.sides)
    if settings.pending_suites:
        for suite in settings.suite_settings():
            found += [side for side in suite.sides if side not in found]
    return found or None


def run_suites(settings: Settings, opts, run_one) -> int:
    names = list(dict.fromkeys(getattr(opts, "suite", None) or settings.default_suites or settings.suites))
    codes, skipped = [], []
    for suite in (Settings(settings.root, settings.conf, name) for name in names):
        if opts.file and len(names) > 1:
            bases = {base(path).lower() for path in suite.spec_files()}
            if bases and not any(base(name).lower() in bases for name in opts.file):
                print(f"== suite {suite.suite}: no spec named {', '.join(opts.file)}; skipped", flush=True)
                skipped.append(suite.suite)
                continue
        print(f"== suite {suite.suite}", flush=True)
        code = run_one(suite, argparse.Namespace(**vars(opts)))
        if code == INTERRUPTED:
            return INTERRUPTED
        codes.append(code)
    if skipped and not codes:
        print(f"sert studio: --file: no spec named {', '.join(opts.file)} in any suite ({', '.join(skipped)})",
              file=sys.stderr, flush=True)
        return INFRA
    return worst(codes)


# -- Flake & last.json persistence -----------------------------------------------------------------------------------

def last_record(settings: Settings, mode: str) -> dict | None:
    last = load_json(settings.last_path)
    return (last.get("modes") or {}).get(mode) if isinstance(last, dict) else None


def flakes(runs: list[list[dict]]) -> dict:
    seen: dict[str, list[str]] = {}
    files: dict[str, str] = {}
    for tests in runs:
        for test in tests:
            seen.setdefault(test["name"], []).append(test["status"])
            files[test["name"]] = test.get("file", "?")
    flaky, broken = [], []
    for name, statuses in seen.items():
        if failed := statuses.count("fail"):
            entry = {"name": name, "file": files[name], "failed": failed, "ran": len(statuses)}
            (broken if failed == len(runs) and len(statuses) == len(runs) else flaky).append(entry)
    return {"iterations": len(runs), "flaky": flaky, "failedEvery": broken}


def merge_results(previous: list[dict] | None, tests: list[dict], known: set[str] | None,
                  run_level: re.Pattern) -> tuple[list[dict], int]:
    latest = {test["name"]: test for test in tests}
    merged, kept, carried = list(latest.values()), [], 0
    for old in previous or []:
        name = old["name"]
        new = latest.get(name)
        if new is not None and not (new["status"] == "skip" and old["status"] == "fail"):
            continue
        if new is None and known is not None and name not in known and not run_level.match(name):
            continue
        if new is not None:
            merged.remove(new)
        kept.append({**{k: v for k, v in old.items() if k != "earlier"}, "earlier": True})
        carried += old["status"] == "fail"
    return merged + kept, carried


def update_last(settings: Settings, mode: str, record: dict, tests: list[dict], seeds: dict[str, int],
                catalogue: list[dict] | None) -> tuple[dict, int]:
    last = load_json(settings.last_path) or {}
    modes = last.get("modes") if isinstance(last.get("modes"), dict) else {}
    previous = modes.get(mode) or {}
    known = {test["name"] for test in catalogue} if catalogue is not None else None
    merged, carried = merge_results(previous.get("tests"), tests, known, settings.run_level)
    seeds = {**(previous.get("seeds") or {}), **seeds}
    for test in tests:
        if test["status"] != "fail":
            seeds.pop(test["name"], None)
    failing = {test["name"] for test in merged if test["status"] == "fail"}
    modes[mode] = {"mode": mode, **record, "seeds": {n: s for n, s in seeds.items() if n in failing}, "tests": merged}
    save_json(settings.last_path, {"modes": modes})
    return modes[mode], carried


def start_flakes(settings: Settings, repeat: int) -> None:
    save_json(settings.flake_path, {"repeat": repeat, "modes": {}})


def update_flakes(settings: Settings, mode: str, run_id: str, repeat: int, runs: list[list[dict]],
                  error: str | None = None) -> dict:
    flake_data = load_json(settings.flake_path) or {"repeat": repeat, "modes": {}}
    flake_data.setdefault("modes", {})[mode] = {"runId": run_id, **flakes(runs)}
    if error:
        flake_data["modes"][mode]["error"] = error
    save_json(settings.flake_path, flake_data)
    return flake_data["modes"][mode]


def flake_lines(settings: Settings, mode: str, found: dict, iterations: int) -> list[str]:
    return [f"{mode}: {len(found['flaky'])} flaky, {len(found['failedEvery'])} failed every iteration"
            f" (of {iterations}; {os.path.relpath(settings.flake_path, settings.root)})",
            *(f"  flaky {e['failed']}/{e['ran']}  {e['file']}: {e['name']}" for e in found["flaky"])]


# -- Studio Driver ---------------------------------------------------------------------------------------------------

from sert.studio import runscript  # noqa: E402

MODES = runscript.MODES
ATTEMPTS = 3
SESSION_DIED = "test session ended without an EndTest result"

EDIT_DRIVER = """\
-- Generated by sert studio (edit mode); runs in the edit DataModel at command-bar permission level.
local HttpService = game:GetService("HttpService")
local ARGS = {request}
local RUNNER_PATH = HttpService:JSONDecode({runner_path})
local CONFIG_PATH = HttpService:JSONDecode({config_path})
local SENTINEL = {sentinel}

local function find(path)
	local node: Instance = game
	for index, name in path do
		local child = if index == 1 then game:FindService(name) or game:GetService(name) else node:WaitForChild(name, 10)
		if child == nil then
			error(`no {{name}} under {{node:GetFullName()}}`, 0)
		end
		node = child
	end
	return node
end

local ok, problem = pcall(function()
	local Runner = require(find(RUNNER_PATH)) :: any
	Runner.edit(require(find(CONFIG_PATH)) :: any, HttpService:JSONDecode(ARGS))
end)
if not ok then
	print(SENTINEL .. " " .. HttpService:JSONEncode({{
		passed = false,
		failed = 0,
		counts = {{ passed = 0, failed = 0, skipped = 0, todo = 0, total = 0 }},
		reason = "edit driver: " .. tostring(problem),
	}}))
end
"""


def file_matches(test_file: str, wanted: str) -> bool:
    wanted = wanted.replace("\\", "/")
    if base(test_file).lower() != base(wanted).lower():
        return False
    if "/" not in wanted:
        return True
    folder = wanted.rsplit("/", 1)[0].lower().strip("/")
    return ("/" + test_file.replace("\\", "/").lower()).rsplit("/", 1)[0].endswith("/" + folder)


def side_of(test: dict) -> str | None:
    if test.get("side"):
        return str(test["side"])
    name = test.get("name", "")
    return name.split(" · ", 1)[0] if " · " in name else None


class Hooks:
    """The optional [studio].hooks module; every hook is optional."""

    NAMES = ("add_arguments", "request", "on_marker", "report", "prelude", "monitor", "check", "passes")

    def __init__(self, module=None):
        self.module = module

    def has(self, name: str) -> bool:
        return self.module is not None and callable(getattr(self.module, name, None))

    def call(self, name: str, *args, default=None):
        return getattr(self.module, name)(*args) if self.has(name) else default


def load_hooks(path: str | None) -> Hooks:
    if not path:
        return Hooks()
    if not os.path.isfile(path):
        raise SertError(f"[studio].hooks: no such file {path}")
    folder = os.path.dirname(os.path.abspath(path))
    if folder not in sys.path:
        sys.path.insert(0, folder)
    spec = importlib.util.spec_from_file_location("sert_studio_hooks", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return Hooks(module)


def catalogue_fresh(settings: Settings, catalogue: dict | None) -> bool:
    return bool(catalogue) and catalogue.get("digest") == settings.spec_digest() and "tests" in catalogue


def store_catalogue(settings: Settings, tests: list[dict]) -> dict:
    catalogue = {"digest": settings.spec_digest(), "tests": tests}
    save_json(settings.catalogue_path, catalogue)
    return catalogue


class Selection:
    """What the options pick. `names` is None unless --grep or --failed resolved the name criteria to names."""

    def __init__(self):
        self.filter = ""
        self.filters: list[str] = []
        self.patterns: list[re.Pattern] = []
        self.files: list[str] = []
        self.sides: list[str] = []
        self.excludes: list[str] = []
        self.exclude_names: set[str] = set()
        self.failed: set[str] | None = None
        self.names: set[str] | None = None
        self.seeds: dict[str, int] = {}

    @property
    def needs_catalogue(self) -> bool:
        return bool(self.patterns or self.excludes or (self.failed is not None and (self.filter or self.filters)))

    def matches(self, test: dict) -> bool:
        name = test["name"]
        if (self.filter and self.filter.lower() not in name.lower()) or (
            self.files and not any(file_matches(test.get("file", ""), wanted) for wanted in self.files)
        ) or (self.sides and side_of(test) not in self.sides) or any(
            text.lower() in name.lower() for text in self.excludes
        ):
            return False
        if not (self.filters or self.patterns or self.failed is not None):
            return True
        return (any(text.lower() in name.lower() for text in self.filters)
                or any(pattern.search(name) for pattern in self.patterns)
                or (self.failed is not None and name in self.failed))

    def resolve(self, catalogue: list[dict] | None) -> None:
        if catalogue is not None and self.excludes:
            self.exclude_names = {test["name"] for test in catalogue
                                  if any(text.lower() in test["name"].lower() for text in self.excludes)}
        if not self.patterns and self.failed is None:
            return
        if catalogue is None:
            self.names = set(self.failed or ())
            return
        names = {test["name"] for test in catalogue if self.matches(test)}
        if self.failed is not None:
            known = {test["name"] for test in catalogue}
            names |= {name for name in self.failed
                      if name not in known
                      and (not self.filter or self.filter.lower() in name.lower())
                      and (not self.sides or side_of({"name": name}) in self.sides)
                      and not any(text.lower() in name.lower() for text in self.excludes)}
        self.names = names

    def request(self) -> dict:
        req: dict = {"filter": self.filter}
        if self.names is not None:
            req["names"] = sorted(self.names)
        elif self.filters:
            req["filters"] = list(self.filters)
        if self.files:
            req["files"] = [base(name) if "/" not in name.replace("\\", "/") else name for name in self.files]
        if self.sides:
            req["sides"] = list(self.sides)
        if self.exclude_names:
            req["excludes"] = sorted(self.exclude_names)
        if self.seeds:
            req["seeds"] = dict(self.seeds)
        return req

    def describe(self) -> str:
        parts = []
        if self.filter:
            parts.append(f'filter "{self.filter}"')
        if self.files:
            parts.append("files " + ", ".join(self.files))
        if self.sides:
            parts.append("sides " + ", ".join(self.sides))
        if self.filters:
            parts.append("filters " + " | ".join(self.filters))
        if self.patterns:
            parts.append("grep " + " | ".join(f"/{p.pattern}/" for p in self.patterns))
        if self.failed is not None:
            parts.append("the last run's failures")
        if self.excludes:
            parts.append("excluding " + " | ".join(self.excludes))
        if self.names is not None:
            parts.append(f"{len(self.names)} named")
        return ", ".join(parts) or "every test"


def failed_tests(record: dict, run_level: re.Pattern) -> tuple[list[dict], list[str]]:
    failed = [test for test in record.get("tests", []) if test.get("status") == "fail"]
    return ([t for t in failed if not (t.get("runner") or run_level.match(t["name"]))],
            [t["name"] for t in failed if t.get("runner") or run_level.match(t["name"])])


def narrow_failed(failed: list[dict], selection: Selection, owner: dict[str, str]) -> tuple[set[str], list[str]]:
    kept, left = set(), []
    for test in failed:
        name = test["name"]
        raw_file = test.get("file")
        file = raw_file if raw_file not in (None, "", "?") else owner.get(name)
        file = None if file == "?" else file
        if selection.sides and side_of(test) not in selection.sides:
            left.append(f"{name} [not on --side {'/'.join(sorted(selection.sides))}]")
        elif selection.files and not (file and any(file_matches(file, wanted) for wanted in selection.files)):
            left.append(f"{name} [{'in ' + file if file else 'in no file the catalogue knows'}, not a --file]")
        elif any(text.lower() in name.lower() for text in selection.excludes):
            left.append(f"{name} [--exclude]")
        else:
            kept.add(name)
    return kept, left


def replay_seeds(failed: list[dict], names: set[str], record: dict) -> dict[str, int]:
    known = dict(record.get("seeds") or {})
    seeds = {}
    for test in failed:
        if test["name"] in names:
            seed = test.get("seed", known.get(test["name"]))
            if isinstance(seed, int) and not isinstance(seed, bool):
                seeds[test["name"]] = seed
    return seeds


def summarize(parsed: Parsed, report: dict) -> str:
    verdict = parsed.verdict
    if isinstance(verdict, dict) and isinstance(verdict.get("counts"), dict):
        counts = verdict["counts"]
        text = (f"{'PASSED' if verdict.get('passed') else 'FAILED'} · {counts.get('passed', 0)} passed · "
                f"{counts.get('failed', 0)} failed · {counts.get('skipped', 0)} skipped"
                + (f" · {counts['todo']} todo" if counts.get("todo") else ""))
        return text + (f" · {verdict['reason']}" if verdict.get("reason") else "")
    results = parsed.results
    if isinstance(results, dict) and isinstance(results.get("total"), int):
        failed = results.get("failed") or 0
        return (f"{'FAILED' if failed else 'PASSED'} {results.get('passed', 0)}/{results.get('total')}"
                f" ({failed} failed, {results.get('skipped', 0)} skipped"
                + (f", {results['todo']} todo" if results.get("todo") else "") + ")")
    result = report.get("result")
    if isinstance(result, dict) and result.get("error"):
        return f"FAILED: {result['error']}"
    return report.get("message") or "no result"


def executed(parsed: Parsed) -> int:
    runner_passes = sum(1 for test in parsed.tests if test.get("runner") and test["status"] == "pass")
    results = parsed.results
    passed = results.get("passed") if isinstance(results, dict) else None
    if isinstance(passed, int) and not isinstance(passed, bool):
        return max(0, passed - runner_passes) + int(results.get("failed") or 0)
    return sum(1 for test in parsed.tests if test["status"] in ("pass", "fail")) - runner_passes


def failed_count(parsed: Parsed) -> int:
    counted = sum(1 for test in parsed.tests if test["status"] == "fail")
    results = parsed.results
    return max(counted, results["failed"]) if isinstance(results, dict) and isinstance(results.get("failed"), int) else counted


def should_relaunch(code: int, report: dict, parsed: Parsed) -> bool:
    if code in (0, 3, INTERRUPTED) or parsed.results is not None:
        return False
    result = report.get("result")
    if isinstance(result, dict) and result.get("error") == SESSION_DIED:
        return True
    message = str(report.get("message") or "")
    return (code == INFRA and result is None and bool((report.get("output") or "").strip())
            and "is not JSON" not in message and "could not start" not in message)


def phase_lines(mode: str, launched: float, built: float, seconds: float, parsed: Parsed,
                tests: list[dict], slowest: int) -> list[str]:
    lines = [f"timing ({mode}): build {built:.1f} s, Studio {seconds:.1f} s"]
    if marks := sorted(parsed.phases.items(), key=lambda item: item[1]):
        lines.append("  phases: " + ", ".join(f"{name} +{ms / 1000 - launched:.1f} s" for name, ms in marks))
    if parsed.frame is not None:
        lines.append(f"  steady frame {parsed.frame} ms")
    if tests:
        lines.append(f"  tests: {len(tests)} in {sum(t['ms'] for t in tests) / 1000:.1f} s")
        if slowest:
            per: dict[str, list[int]] = {}
            for test in tests:
                per.setdefault(test.get("file", "?"), []).append(test["ms"])
            top = sorted(per.items(), key=lambda item: -sum(item[1]))[:slowest]
            lines.append("  slowest files: " + ", ".join(f"{n} {sum(ms) / 1000:.1f} s ({len(ms)})" for n, ms in top))
            lines.append("  slowest tests:")
            for test in sorted(tests, key=lambda t: -t["ms"])[:slowest]:
                lines.append(f"    {test['ms']:6d} ms  {test.get('file', '?')}: {test['name']}")
    return lines


def edit_driver(settings: Settings, request: dict) -> str:
    if not settings.config_path:
        raise SertError("edit mode needs [studio].config (the instance path of the Runner.Config"
                         ' module, e.g. "ReplicatedStorage/Tests/Config")')
    return EDIT_DRIVER.format(
        request=luau_string(json.dumps(request, ensure_ascii=False)),
        runner_path=luau_string(json.dumps(settings.runner_path)),
        config_path=luau_string(json.dumps(settings.config_path)),
        sentinel=luau_string(VERDICT),
    )


class Attempt:
    def __init__(self, code: int, report: dict, launched: float):
        self.code, self.report, self.launched = code, report, launched


def launch(settings: Settings, opts, hooks: Hooks, mode: str, place: str, request: dict, work: str,
           label: str) -> Attempt:
    report_path = os.path.join(work, f"{label}.report.json")
    if os.path.exists(report_path):
        os.remove(report_path)
    script = edit_driver(settings, request) if mode == "edit" else None
    args = None if mode == "edit" else request
    prelude = None if mode == "edit" else (hooks.call("prelude", opts, mode) or None)
    done = threading.Event()
    monitor = None
    if hooks.has("monitor"):
        ctx = {"args": opts, "mode": mode, "request": request, "runId": request.get("runId"), "out": settings.out,
               "root": settings.root, "done": done}
        monitor = threading.Thread(target=hooks.call, args=("monitor", ctx), daemon=True)
        monitor.start()
    launched = time.time()
    try:
        code = runscript.run(place, mode=mode, report=report_path, script=script, args=args, prelude=prelude,
                             timeout=opts.timeout, keep=opts.keep, launcher=opts.launcher or settings.launcher)
    finally:
        done.set()
        if monitor is not None:
            monitor.join(timeout=30)
    return Attempt(code, load_json(report_path) or {}, launched)


def refresh_catalogue(settings: Settings, opts, hooks: Hooks, mode: str, work: str) -> list[dict] | None:
    print("catalogue: missing or older than a spec; listing the suite", flush=True)
    if settings.list_command:
        try:
            listed = subprocess.run(settings.list_command, cwd=settings.root, capture_output=True, text=True,
                                    encoding="utf-8", errors="replace", timeout=300)
        except (OSError, subprocess.TimeoutExpired) as err:
            print(f"catalogue: cannot run {settings.list_command}: {err}", file=sys.stderr)
            return None
        parsed_list = parse(listed.stdout)
        tests = parsed_list.catalogue if parsed_list.catalogue is not None else (parsed_list.listed or None)
        if listed.returncode != 0 or not tests:
            sys.stderr.write(listed.stdout[-2000:] + listed.stderr[-2000:])
            print("catalogue: the headless listing failed", file=sys.stderr)
            return None
        return store_catalogue(settings, tests)["tests"]
    place = os.path.join(work, "list.rbxl")
    if build_place(settings.root, settings.project, place, quiet=True) is None:
        return None
    request = {"runId": f"sert-list-{int(time.time())}", "mode": mode, "list": True, "filter": ""}
    attempt = launch(settings, opts, hooks, mode, place, request, work, "list")
    parsed = parse(attempt.report.get("output") or "")
    tests = parsed.catalogue
    if attempt.code != 0 or tests is None or (parsed.verdict and not parsed.verdict.get("passed", True)):
        print(f"catalogue: the list run failed (exit {attempt.code}): {attempt.report.get('message')}", file=sys.stderr)
        return None
    return store_catalogue(settings, tests)["tests"]


def drift(settings: Settings) -> list[str]:
    problems = []
    for entry in settings.drift:
        project = os.path.join(settings.root, entry.get("project") or os.path.relpath(settings.project, settings.root))
        node = load_json(project)
        if node is None:
            problems.append(f"drift: cannot read {project}")
            continue
        node = node.get("tree", {})
        for name in entry["tree"]:
            node = node.get(name) if isinstance(node, dict) else None
        if not isinstance(node, dict):
            problems.append(f"drift: {project} has no node {'.'.join(entry['tree'])}")
            continue
        folder = os.path.join(settings.root, entry["dir"])
        for name in sorted(os.listdir(folder)):
            if (name.endswith(".luau") and not name.endswith((".server.luau", ".client.luau"))
                    and name != "init.luau" and name[: -len(".luau")] not in node):
                problems.append(f"{entry['dir']}/{name} is not in {os.path.relpath(project, settings.root)}'s "
                                f"{'.'.join(entry['tree'])}")
    return problems


def check(settings: Settings, opts, hooks: Hooks) -> int:
    if problems := drift(settings) + list(hooks.call("check", opts, default=[]) or []):
        print("\n".join(problems))
        return INFRA
    with tempfile.TemporaryDirectory(prefix="sert-check-") as work:
        if build_place(settings.root, settings.project, os.path.join(work, "check.rbxl"), quiet=True) is None:
            return INFRA
    print(f"built {os.path.relpath(settings.project, settings.root)}; the checks pass")
    return 0


def replay_command(settings: Settings, mode: str) -> str:
    stub = os.path.join(settings.root, "tools", "sert.py")
    command = ("python3 tools/sert.py studio" if os.path.isfile(stub) else "sert studio") + f" --mode {mode}"
    return command + (f" --suite {settings.suite}" if settings.suite is not None else "")


def build_request(settings: Settings, opts, mode: str, selection: Selection, run_id: str) -> dict:
    request: dict = {"runId": run_id, "mode": mode, **selection.request(), "command": replay_command(settings, mode)}
    for attr, key in (("seed", "seed"), ("runs", "runs"), ("replay", "replay"), ("budget", "budget"),
                      ("test_timeout", "timeout"), ("deadline", "deadline")):
        if getattr(opts, attr) is not None:
            request[key] = getattr(opts, attr)
    if opts.exhaustive:
        request["exhaustive"] = True
    if opts.repeat > 1:
        request["repeat"] = opts.repeat
    return request


def ignored_keys(parsed: Parsed, sent: set[str]) -> list[str]:
    verdict = parsed.verdict
    unknown = verdict.get("unknown") if isinstance(verdict, dict) else None
    return sorted(sent & {key for key in unknown if isinstance(key, str)}) if isinstance(unknown, list) else []


def run_mode(settings: Settings, opts, hooks: Hooks, mode: str, selection: Selection, catalogue: list[dict] | None,
             work: str) -> int:
    place = os.path.join(work, f"{mode}.rbxl")
    built = build_place(settings.root, settings.project, place, quiet=True)
    if built is None:
        return INFRA
    run_id = f"sert-{mode}-{int(time.time())}-{os.getpid() % 1000:03d}"
    request = build_request(settings, opts, mode, selection, run_id)
    sent = set(request)
    if isinstance(changed := hooks.call("request", opts, request), dict):
        request = changed
    print(f"run {run_id}: {selection.describe()}", flush=True)

    died = False
    for attempt_number in range(1, ATTEMPTS + 1):
        attempt = launch(settings, opts, hooks, mode, place, request, work, mode)
        parsed = parse(attempt.report.get("output") or "")
        if not should_relaunch(attempt.code, attempt.report, parsed):
            break
        print(f"{mode}: attempt {attempt_number}: the session ended without its results (infrastructure)"
              + ("; launching again" if attempt_number < ATTEMPTS else ""), flush=True)
    else:
        died = True
    code = INFRA if died else attempt.code
    report = attempt.report
    output = report.get("output") or ""
    os.makedirs(settings.out, exist_ok=True)
    with open(os.path.join(settings.out, f"{mode}.log"), "w", encoding="utf-8") as handle:
        handle.write(output)
    save_json(os.path.join(settings.out, f"{mode}.report.json"), report)

    state = {"args": opts, "mode": mode, "request": request, "runId": run_id, "out": settings.out,
             "root": settings.root, "output": output, "report": report, "x": {}, "data": {}, "exit": code}

    def on_marker(tag, payload):
        state["x"].setdefault(tag, []).append(payload)
        hooks.call("on_marker", tag, payload, state)

    parsed = parse(output, on_marker=on_marker)
    listed = parsed.catalogue
    if listed is not None and not request.get("list") and not request.get("sides"):
        catalogue = store_catalogue(settings, listed)["tests"]
    known_tests = (catalogue or []) + (listed or []) if request.get("sides") else (catalogue or [])
    owner = {test["name"]: test.get("file", "?") for test in known_tests}
    side = {test["name"]: test.get("side") for test in known_tests if test.get("side")}
    for test in parsed.tests:
        if test.get("file") in (None, "", "?") and test["name"] in owner:
            test["file"] = owner[test["name"]]
        test.setdefault("file", "?")
        if test["name"] in side:
            test.setdefault("side", side[test["name"]])
    runs = parsed.per_iteration() if opts.repeat > 1 else [parsed.tests]
    tests = parsed.tests
    summary = summarize(parsed, report)

    stored, carried = update_last(settings, mode, {
        "runId": run_id, "exit": code, "summary": summary,
        "selection": {k: v for k, v in request.items() if k not in ("runId", "mode")},
        "seed": parsed.run_seed if parsed.run_seed is not None else opts.seed,
    }, tests, parsed.seeds, catalogue)

    if opts.repeat > 1:
        for iteration in parsed.iterations:
            print(f"{mode} iteration {iteration['n']}: {iteration['summary'] or 'no summary'}")
        found = update_flakes(settings, mode, run_id, opts.repeat, runs,
                              f"{SESSION_DIED} ({ATTEMPTS} attempts)" if died else None)
        for line in flake_lines(settings, mode, found, len(runs)):
            print(line)
    for test in tests:
        if test["status"] == "fail":
            prefix = f"[{test['iteration']}] " if opts.repeat > 1 and "iteration" in test else ""
            seed = f" (seed {test['seed']})" if "seed" in test else ""
            print(f"FAIL {prefix}{test.get('file', '?')}: {test['name']}{seed}\n   {test.get('message') or ''}")
    lines = phase_lines(mode, attempt.launched, built, float(report.get("seconds") or 0), parsed, tests, opts.slowest)
    save_json(os.path.join(settings.out, f"{mode}.timing.json"),
              {"build": round(built, 2), "studio": report.get("seconds"), "phases": parsed.phases,
               "frame": parsed.frame,
               "slowest": [{"name": t["name"], "ms": t["ms"]} for t in sorted(tests, key=lambda t: -t["ms"])
                           [: opts.slowest]]})
    for line in lines:
        print(line)
    print(f"{mode}: {summary}")
    if (seed := stored["seed"]) is not None:
        print(f"seed {seed} (property and model tests; replay with --seed {seed})")
    if carried:
        print(f"{carried} earlier failures this run did not run again are kept in last.json for --failed")

    if code == 0 and failed_count(parsed):
        code = 1
    if code in (0, 1) and parsed.results is None and not tests and report.get("result") is None:
        code = INFRA
    if code == 0 and executed(parsed) == 0 and (tests or parsed.results is not None):
        print("no test ran: nothing matched the selection, or only skips")
        code = 1
    if ignored := ignored_keys(parsed, sent):
        print(f"{mode}: the place's runner ignored request key(s) {', '.join(ignored)}: its sert "
              f"(src/roblox/Runner.luau) is older than this driver; fetch or rebuild it", file=sys.stderr)
        code = INFRA
    state.update({"parsed": parsed, "tests": tests, "results": parsed.results, "summary": summary, "exit": code})
    override = hooks.call("report", state)
    if isinstance(override, int) and not isinstance(override, bool):
        code = override
    record_task(opts, settings, mode, run_id, code, summary, report, parsed, tests)
    return code


def record_task(opts, settings: Settings, mode: str, run_id: str, code: int, summary: str, report: dict,
                parsed: Parsed, tests: list[dict]) -> None:
    if (records := getattr(opts, "json_records", None)) is None:
        return
    results = parsed.results if isinstance(parsed.results, dict) else {}
    failures = [{key: test[key] for key in ("name", "file", "message", "seed", "iteration") if key in test}
                for test in tests if test["status"] == "fail"]
    records.append({
        "label": f"{settings.suite}/{mode}" if settings.suite else mode,
        "suite": settings.suite, "mode": mode, "exit": code, "verdict": summary, "seconds": report.get("seconds"),
        "runId": run_id,
        "counts": {key: results.get(key, 0) for key in ("passed", "failed", "skipped", "todo", "total")},
        "failures": failures,
    })


def write_json_out(opts, code: int, root: str | None = None) -> int:
    if not (path := getattr(opts, "json_out", None)):
        return code
    target = os.path.join(root, path) if root and not os.path.isabs(path) else os.path.abspath(path)
    try:
        save_json(os.path.abspath(target), {"exitCode": code, "tasks": getattr(opts, "json_records", None) or []})
    except OSError as err:
        print(f"sert studio: cannot write {path}: {err}", file=sys.stderr)
        return code or INFRA
    return code


def add_arguments(parser: argparse.ArgumentParser, settings: Settings | None = None) -> None:
    sides = known_sides(settings)
    parser.add_argument("filter", nargs="?", default="", help="sert's own filter: names containing this (case-insensitive)")
    parser.add_argument("--mode", action="append", choices=MODES, default=None,
                        help="edit, play or run (default [studio].mode); repeat to run several in turn")
    parser.add_argument("--filter", dest="filters", action="append", default=[], metavar="TEXT",
                        help="names containing TEXT, case-insensitive; repeat for any of several")
    parser.add_argument("--grep", action="append", default=[], metavar="REGEX",
                        help="names matching REGEX (Python re, case-insensitive); repeatable")
    parser.add_argument("--exclude", action="append", default=[], metavar="TEXT",
                        help="leave out names containing TEXT (case-insensitive); repeatable")
    parser.add_argument("--file", action="append", default=[], metavar="SPEC",
                        help="only this spec file (Users, client/Users or Users.spec.luau); repeatable")
    parser.add_argument("--side", action="append", default=[], choices=sides, metavar="SIDE",
                        help="only this side's tests" + (f" ({', '.join(sides)})" if sides else "") + "; repeatable")
    parser.add_argument("--failed", action="store_true",
                        help="the tests that failed in the last run of the mode, replaying their property seeds")
    parser.add_argument("--list", action="store_true", help="print the tests the selection picks; run none")
    parser.add_argument("--repeat", type=int, default=1, metavar="N",
                        help="run the selection N times in one Studio session; writes flake.json")
    parser.add_argument("--seed", metavar="N|random", help="base seed for property and model tests")
    parser.add_argument("--runs", type=int, metavar="N", help="cases per property and model test")
    parser.add_argument("--replay", type=int, metavar="SEED",
                        help="run one case of each matching property: the case seed a failure printed (request.replay)")
    parser.add_argument("--exhaustive", action="store_true",
                        help="only the bounded-exhaustive properties, enumerating every case (request.exhaustive)")
    parser.add_argument("--budget", type=float, metavar="S",
                        help="seconds an exhaustive property may take before it fails (request.budget; default 600)")
    parser.add_argument("--test-timeout", type=float, metavar="S", help="seconds per test (request.timeout)")
    parser.add_argument("--deadline", type=float, metavar="S",
                        help="seconds the server waits for the client's report (request.deadline)")
    parser.add_argument("--slowest", type=int, default=10, metavar="N", help="list the N slowest tests and files")
    parser.add_argument("--timeout", type=float, default=None,
                        help=f"seconds per attempt before Studio is stopped (default [studio].timeout or {DEFAULT_TIMEOUT:g})")
    parser.add_argument("--keep", action="store_true", help="keep the runscript's staging directory")
    parser.add_argument("--launcher", metavar="CMD",
                        help="start Studio with CMD instead of the platform's Studio (default [studio].launcher)")
    parser.add_argument("--json-out", metavar="FILE", help="write each session's verdict as JSON (as `sert cloud`)")
    parser.add_argument("--check", action="store_true", help="build the place and run drift and hook checks; no Studio")
    suites_list = settings.suites if settings is not None and settings.suites else None
    parser.add_argument("--suite", action="append", default=[], choices=suites_list, metavar="NAME",
                        help="only this [studio.suites.<name>]" + (f" ({', '.join(suites_list)})" if suites_list else "")
                        + "; repeatable (default: every suite)")


def build_parser(settings: Settings | None, hooks: Hooks, parser: argparse.ArgumentParser | None = None):
    if parser is None:
        parser = argparse.ArgumentParser(prog="sert studio", description=__doc__,
                                         formatter_class=argparse.RawDescriptionHelpFormatter)
        parser.add_argument("--root", metavar="DIR", default=argparse.SUPPRESS,
                            help="project root (default: the git toplevel of cwd)")
    add_arguments(parser, settings)
    hooks.call("add_arguments", parser)
    if settings is not None and settings.pending_suites:
        seen = {os.path.abspath(settings.hooks)} if settings.hooks else set()
        for suite in settings.suite_settings():
            if suite.hooks and os.path.abspath(suite.hooks) not in seen:
                seen.add(os.path.abspath(suite.hooks))
                load_hooks(suite.hooks).call("add_arguments", parser)
    return parser


def prescan_root(argv: list[str]) -> str:
    scan = argparse.ArgumentParser(add_help=False)
    scan.add_argument("--root")
    known, _ = scan.parse_known_args(argv)
    return str(sert_config.find_root(known.root))


def context(argv: list[str]) -> tuple[Settings | None, Hooks, str | None, str | None]:
    root = None
    try:
        root = prescan_root(argv)
        settings = Settings(root, sert_config.load(root))
        hooks = load_hooks(settings.hooks)
        if settings.pending_suites:
            for suite in settings.suite_settings():
                if suite.hooks:
                    load_hooks(suite.hooks)
        return settings, hooks, None, root
    except (SystemExit, Exception) as err:
        return None, Hooks(), str(err), root


_LOADED: dict = {}


def add_parser(subparsers, argv: list[str] | None = None) -> argparse.ArgumentParser:
    argv = sys.argv[1:] if argv is None else argv
    in_studio = "studio" in argv
    settings, hooks, problem, root = (context(argv) if in_studio else (None, Hooks(), None, None))
    _LOADED.clear()
    _LOADED.update(settings=settings, hooks=hooks, problem=problem, root=root)
    parser = subparsers.add_parser("studio")
    build_parser(settings, hooks, parser)
    parser.set_defaults(func=main)
    return parser


def main(args) -> int:
    for stream in (sys.stdout, sys.stderr):
        if hasattr(stream, "reconfigure"):
            stream.reconfigure(errors="replace")
    cached = dict(_LOADED)
    _LOADED.clear()
    settings = cached.get("settings")
    hooks = cached.get("hooks") or Hooks()
    explicit_root = getattr(args, "root", None)
    root = str(sert_config.find_root(explicit_root)) if explicit_root or settings is None else settings.root
    try:
        if cached.get("problem") is not None and cached.get("root") == root:
            problem = cached["problem"]
            raise problem if isinstance(problem, BaseException) else SertError(str(problem))
        if settings is None or settings.root != root:
            cfg = sert_config.load(root)
            settings = Settings(root, cfg)
            hooks = load_hooks(settings.hooks)
        else:
            cfg = settings.conf if isinstance(settings.conf, sert_config.Config) else sert_config.load(root)
    except Exception as err:
        print(f"sert studio: {err}", file=sys.stderr)
        return getattr(err, "code", INFRA)
    from sert import fetch

    fetch.refresh_overrides(cfg)
    fetch.ensure_fetched(cfg)
    args.json_records = []
    return write_json_out(args, guarded(settings, hooks, args), root=settings.root)


def run_suite(settings: Settings, opts) -> int:
    return guarded(settings, load_hooks(settings.hooks), opts)


def guarded(settings: Settings, hooks: Hooks, opts) -> int:
    try:
        if settings.pending_suites:
            return run_suites(settings, opts, run_suite)
        if getattr(opts, "suite", None) and settings.suite not in opts.suite:
            raise SertError("--suite: sert.toml names no [studio.suites]")
        return execute(settings, hooks, opts)
    except SertError as err:
        print(f"sert studio: {err}", file=sys.stderr)
        return err.code
    except SystemExit as err:
        if isinstance(err.code, int) or err.code is None:
            raise
        print(err.code, file=sys.stderr)
        return INFRA


def execute(settings: Settings, hooks: Hooks, opts) -> int:
    if opts.repeat < 1:
        raise SertError("--repeat: N must be at least 1")
    check_selection(opts)
    if opts.seed is not None:
        if opts.seed == "random":
            opts.seed = random.randrange(2 ** 32)
            print(f"sert studio: --seed {opts.seed}")
        else:
            try:
                opts.seed = int(opts.seed, 0)
            except ValueError:
                raise SertError("--seed takes a whole number or 'random'") from None
            if not 0 <= opts.seed < 2 ** 32:
                raise SertError("--seed takes a whole number from 0 to 2^32 - 1")
    if opts.timeout is None:
        opts.timeout = settings.timeout
    modes = opts.mode or settings.modes
    if unknown_modes := [mode for mode in modes if mode not in MODES]:
        raise SertError(f"[studio].mode: unknown {', '.join(unknown_modes)}")

    if (passes := hooks.call("passes", opts)) is not None:
        if not isinstance(passes, (list, tuple)) or not all(
            isinstance(argv, (list, tuple)) and all(isinstance(item, str) for item in argv) for argv in passes
        ):
            raise SertError("[studio].hooks passes() must return a list of argument lists (list[list[str]])")
        if passes:
            codes = []
            for argv in passes:
                print(f"== pass: {' '.join(argv)}", flush=True)
                code = run(["--root", settings.root, *argv], records=getattr(opts, "json_records", None))
                if code == INTERRUPTED:
                    return INTERRUPTED
                codes.append(code)
            return worst(codes)

    if opts.check:
        return check(settings, opts, hooks)
    if problems := drift(settings):
        print("\n".join(problems))
        return INFRA

    selection = Selection()
    selection.filter = opts.filter or ""
    selection.filters = [value for value in opts.filters if value]
    selection.excludes = [value for value in opts.exclude if value]
    selection.files = list(opts.file)
    selection.sides = list(opts.side)
    try:
        selection.patterns = [re.compile(value, re.IGNORECASE) for value in opts.grep]
    except re.error as err:
        raise SertError(f"--grep: {err}") from None
    spec_bases = {base(path).lower() for path in settings.spec_files()}
    if (unknown := [name for name in selection.files if base(name).lower() not in spec_bases]) and spec_bases:
        raise SertError(f"--file: no spec named {', '.join(unknown)} under {', '.join(settings.specs)}")

    if opts.repeat > 1 and not opts.list:
        start_flakes(settings, opts.repeat)
    codes = []
    with tempfile.TemporaryDirectory(prefix="sert-studio-") as work:
        stored = load_json(settings.catalogue_path)
        catalogue = stored["tests"] if catalogue_fresh(settings, stored) else None

        def ensure_catalogue(mode):
            nonlocal catalogue
            if catalogue is None:
                catalogue = refresh_catalogue(settings, opts, hooks, mode, work)
            return catalogue

        for mode in modes:
            picked = Selection()
            picked.__dict__.update({k: (list(v) if isinstance(v, list) else v) for k, v in selection.__dict__.items()})
            if opts.failed:
                record = last_record(settings, mode)
                if record is None:
                    print(f"sert studio: --failed: no earlier {mode} run in {settings.last_path}", file=sys.stderr)
                    codes.append(INFRA)
                    continue
                failed, run_level = failed_tests(record, settings.run_level)
                if run_level:
                    print(f"not re-run on their own (run their side again): {', '.join(run_level)}")
                if not failed:
                    if not record.get("tests") and str(record.get("summary", "")).startswith("FAILED"):
                        print(f"sert studio: --failed: the last {mode} run failed before any test ran: "
                              f"{record.get('summary')}", file=sys.stderr)
                        codes.append(INFRA)
                    else:
                        print(f"{mode}: the last run has no failed tests to re-run")
                        codes.append(0)
                    continue
                if (picked.files or picked.sides) and catalogue is None and ensure_catalogue(mode) is None:
                    codes.append(INFRA)
                    continue
                owner = {t["name"]: t.get("file", "?") for t in (catalogue or [])}
                known_side = {t["name"]: side_of(t) for t in (catalogue or []) if side_of(t)}
                for t in failed:
                    if not t.get("side") and t["name"] in known_side:
                        t["side"] = known_side[t["name"]]
                names, left = narrow_failed(failed, picked, owner)
                if left:
                    print(f"{len(left)} of {len(failed)} failures left out of this run (kept for a later --failed):")
                    for line in left:
                        print(f"  {line}")
                picked.failed = names
                picked.seeds = replay_seeds(failed, names, record)
                for name, seed in sorted(picked.seeds.items()):
                    print(f"replaying {name} with seed {seed}")
            if (picked.needs_catalogue or opts.list) and ensure_catalogue(mode) is None:
                codes.append(INFRA)
                continue
            picked.resolve(catalogue)
            if opts.list:
                tests = [test for test in catalogue if picked.matches(test)]
                if picked.names is not None:
                    tests = [test for test in tests if test["name"] in picked.names]
                for test in tests:
                    print(f"{test.get('file', '?')}: {test['name']}")
                print(f"{len(tests)} test(s) match ({mode}; the catalogue: tests registered in Roblox)")
                codes.append(0)
                if len(modes) > 1 and catalogue is not None and not opts.failed:
                    break
                continue
            if picked.names is not None and not picked.names:
                print(f"{mode}: no test matches the selection; nothing to run")
                codes.append(0 if opts.failed and not picked.patterns else 1)
                continue
            code = run_mode(settings, opts, hooks, mode, picked, catalogue, work)
            if code == INTERRUPTED:
                return INTERRUPTED
            codes.append(code)
    return worst(codes)


def run(argv: list[str], records: list | None = None) -> int:
    settings, hooks, problem, *_ = context(argv)
    parser = build_parser(settings, hooks)
    opts = parser.parse_args(argv)
    if problem:
        print(f"sert studio: {problem}", file=sys.stderr)
        return INFRA
    if records is not None:
        opts.json_records = records
        return guarded(settings, hooks, opts)
    opts.json_records = []
    return write_json_out(opts, guarded(settings, hooks, opts), root=settings.root if settings is not None else None)


markers = suites = flake = driver = sys.modules[__name__]
