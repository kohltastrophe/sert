"""Lightweight parser for `[sert-<kind>]` output markers (zero Studio/driver dependencies)."""

from __future__ import annotations

import json
import math
import re

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
    """Return `(kind, tag, payload)` for a `[sert-...]` marker line, or `None`."""
    match = MARKER.match(line)
    return (match.group(1), match.group(2), match.group(3).rstrip("\r")) if match else None


def _json(payload: str):
    try:
        return json.loads(payload)
    except ValueError:
        return None


def is_wrapper(value) -> bool:
    return isinstance(value, dict) and "ok" in value and set(value) <= {"ok", "value", "error"}


def normalize_test(value: dict) -> dict:
    test = dict(value)
    test["status"] = str(test.get("status", ""))
    if "message" not in test:
        if "error" in test:
            test["message"] = test["error"]
        elif "err" in test:
            test["message"] = test["err"]
    try:
        test["ms"] = int(round(float(test.get("ms") or 0)))
    except (TypeError, ValueError):
        test["ms"] = 0
    return test


class Parsed:
    """Structured markers parsed from one run's output."""

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
        self.run_ids: list[str] = []

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
        if verdict is not None:
            if isinstance(verdict.get("counts"), dict):
                counts = verdict["counts"]
                return {
                    **{k: v for k, v in verdict.items() if k not in ("passed", "failed")},
                    **{k: counts.get(k, 0) for k in ("passed", "failed", "skipped", "todo", "total")},
                    "verdictPassed": verdict.get("passed"),
                }
            if isinstance(verdict.get("passed"), int) and not isinstance(verdict.get("passed"), bool):
                return dict(verdict)
        for value in reversed(self.done):
            if isinstance(value, dict) and not is_wrapper(value):
                return value
        return None

    def per_iteration(self) -> list[list[dict]]:
        return [iteration["tests"] for iteration in self.iterations] if self.iterations else [self.tests]


def iteration_summary(deltas: dict) -> str:
    counts = {"passed": 0, "failed": 0, "skipped": 0, "todo": 0, "total": 0}
    for delta in deltas.values():
        if isinstance(delta, dict):
            for key in counts:
                value = delta.get(key)
                counts[key] += value if isinstance(value, int) and not isinstance(value, bool) else 0
    return f"FAILED {counts['failed']} of {counts['total']}" if counts["failed"] else f"PASSED {counts['passed']}/{counts['total']}"


def parse(output: str, on_marker=None) -> Parsed:
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
        elif kind in ("done", "verdict", "result"):
            value = _json(payload)
            (parsed.done if kind == "done" else parsed.verdicts).append(value)
            if value is not None and not (kind == "done" and listed):
                parsed.outcomes.append(value)
        elif kind == "run" and tag in ("start", "end"):
            if payload.strip():
                parsed.run_ids.append(payload.strip())
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
    for done_item in parsed.done:
        if isinstance(done_item, dict) and isinstance(done_item.get("seeds"), dict):
            for name, seed in done_item["seeds"].items():
                if isinstance(seed, int) and not isinstance(seed, bool):
                    parsed.seeds.setdefault(name, seed)
    for test in parsed.tests:
        if test["status"] == "fail" and test["name"] in parsed.seeds and "seed" not in test:
            test["seed"] = parsed.seeds[test["name"]]
    return parsed


def _number(value) -> bool:
    return isinstance(value, (int, float)) and not isinstance(value, bool)


def failure(value, depth: int = 0) -> str | None:
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
