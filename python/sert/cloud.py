"""`sert cloud`: build the test place, upload it as a saved version, and run Luau specs in it as parallel Open Cloud Luau execution tasks."""

from __future__ import annotations

import argparse
from concurrent.futures import ThreadPoolExecutor
import datetime
import email.utils
import http.client
import io
import json
import os
from pathlib import Path
import re
import shutil
import sys
import tempfile
import threading
import time
import urllib.error
import urllib.parse
import urllib.request

from sert import config as sert_config, markers, util
from sert.util import (
    FAILED,
    INFRA,
    INTERRUPTED,
    OK,
    TIMEOUT,
    SertError,
    build_place,
    expand_globs,
    luau_string,
    note,
    worst,
)

DEFAULT_BASE_URL = "https://apis.roblox.com"
USER_AGENT = "sert-cloud/1"
ENV = (
    ("ROBLOX_API_KEY",),
    ("ROBLOX_UNIVERSE_ID", "ROBLOX_TEST_UNIVERSE_ID"),
    ("ROBLOX_PLACE_ID", "ROBLOX_TEST_PLACE_ID"),
)
TASK_LIMIT = 300
QUEUE_ALLOWANCE = 300
SHARD_LIMIT = 120
MAX_PARALLEL_SHARDS = 10
DEFAULT_JOBS = 8
MAX_SCRIPT_BYTES = 4 * 1024 * 1024
RATE_LIMIT_ATTEMPTS = 6
TRANSIENT_RETRIES = 3
IDEMPOTENT = frozenset({"GET", "HEAD", "PUT", "DELETE"})
MAX_RETRY_DELAY = 120.0
POLL_START, POLL_MAX = 2.0, 5.0
FINAL_STATES = frozenset({"COMPLETE", "FAILED", "CANCELLED"})
PLACE_CONTENT_TYPES = {".rbxl": "application/octet-stream", ".rbxlx": "application/xml"}
LOG_PREFIXES = {"WARNING": "!! [WARNING] ", "ERROR": "!! [ERROR] "}
DIRECTIVE = re.compile(r"^\s*--!")
DEFAULT_CLOUD_SPECS = ("test/**/*.spec.luau", "tests/**/*.spec.luau")

ZERO_BOILERPLATE_CLOUD_SCRIPT = """\
--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local lib = ReplicatedStorage:FindFirstChild("sert") or ReplicatedStorage:FindFirstChild("__sert_lib")
if lib == nil then
\terror("sert cloud: ReplicatedStorage.sert not found in place", 0)
end
local Runner = require(lib:WaitForChild("roblox"):WaitForChild("Runner")) :: any
local cfgMod = ReplicatedStorage:FindFirstChild("__sert_config")
local cfg = if cfgMod ~= nil and cfgMod:IsA("ModuleScript") then require(cfgMod) :: any else nil
if Runner.cloud ~= nil then
\treturn Runner.cloud(cfg)
end
return Runner.runOnce(cfg, {})
"""

SLEEP = time.sleep
CLOCK = time.monotonic
_TLS = threading.local()


def _out_stream():
    return getattr(_TLS, "out", None) or sys.stdout


def _err_stream():
    return getattr(_TLS, "err", None) or sys.stderr


def _task_limit() -> int:
    return int(getattr(_TLS, "task_timeout", None) or TASK_LIMIT)


def _advance_gate() -> None:
    cb = getattr(_TLS, "on_created", None)
    if cb is not None:
        _TLS.on_created = None
        cb()


class ApiError(SertError):
    def __init__(self, message, status=None):
        super().__init__(message, INFRA)
        self.status = status


class GiveUp(SertError):
    def __init__(self, message):
        super().__init__(message, TIMEOUT)


def lua_strings(values) -> str:
    return "{ " + ", ".join(luau_string(str(value)) for value in values) + " }"


SHARD_KEYS = ("name", "only", "except")


def _prefixes(shard: dict, key: str) -> list[str]:
    value = shard[key]
    if not isinstance(value, list) or not all(isinstance(prefix, str) and prefix for prefix in value):
        raise SertError(f"[cloud].shards: {shard['name']}.{key} must be a list of non-empty prefix strings")
    return list(value)


def normalize_shards(shards) -> list[dict]:
    if shards is not None and not isinstance(shards, list):
        raise SertError("[cloud].shards must be a list")
    out = []
    for shard in shards or []:
        if isinstance(shard, str) and shard:
            out.append({"name": shard})
        elif isinstance(shard, dict) and isinstance(shard.get("name"), str) and shard["name"]:
            if unknown := sorted(set(shard) - set(SHARD_KEYS)):
                raise SertError(
                    f"[cloud].shards: {shard['name']}: unknown key(s) {', '.join(unknown)} (known: {', '.join(SHARD_KEYS)})"
                )
            if shard.get("only") is not None and shard.get("except") is not None:
                raise SertError(f"[cloud].shards: {shard['name']} gives both `only` and `except`")
            entry = {"name": shard["name"]}
            for key in ("only", "except"):
                if shard.get(key) is not None:
                    entry[key] = _prefixes(shard, key)
            out.append(entry)
        else:
            raise SertError(f"[cloud].shards: not a name or a {{name, only?, except?}} table: {shard!r}")
    names = [shard["name"] for shard in out]
    if len(set(names)) != len(names):
        raise SertError(f"[cloud].shards: repeated names in {names}")
    return out


def shard_info(shards: list[dict], index: int, limit: float) -> dict:
    shard = shards[index]
    info = {"name": shard["name"], "index": index + 1, "count": len(shards), "runLimit": limit}
    if "only" in shard:
        info["only"] = list(shard["only"])
    elif "except" in shard:
        info["except"] = list(shard["except"])
    elif any("only" in other for other in shards):
        info["except"] = [prefix for other in shards if "only" in other for prefix in other["only"]]
    return info


def shard_statement(info: dict) -> str:
    fields = [
        f"name = {luau_string(info['name'])}",
        f"index = {info['index']}",
        f"count = {info['count']}",
        f"runLimit = {info['runLimit']:g}",
    ]
    for key in ("only", "except"):
        if key in info:
            fields.append(f"{key} = {lua_strings(info[key])}")
    return (
        f"local SERT_SHARD = {luau_string(info['name'])} "
        f"local SERT_SHARD_INFO = {{ {', '.join(fields)} }} "
        'pcall(rawset, _G, "__SERT_SHARD", SERT_SHARD_INFO) '
    )


def inject_shard(source: str, info: dict) -> str:
    statement = shard_statement(info)
    lines = source.split("\n")
    at = 0
    while at < len(lines) and DIRECTIVE.match(lines[at]):
        at += 1
    if at == len(lines):
        return source + ("" if source.endswith("\n") or not source else "\n") + statement.rstrip() + "\n"
    lines[at] = statement + lines[at]
    return "\n".join(lines)


def redact(text, secret) -> str:
    text = str(text)
    return text.replace(secret, "[REDACTED]") if secret else text


def checked_url(url: str):
    try:
        parts = urllib.parse.urlsplit(url)
        port = parts.port
    except ValueError:
        raise SertError("invalid endpoint URL") from None
    if (
        parts.scheme not in ("https", "http")
        or not parts.hostname
        or parts.username is not None
        or parts.password is not None
        or parts.fragment
        or (parts.scheme == "http" and parts.hostname not in ("localhost", "127.0.0.1", "::1"))
    ):
        raise SertError("endpoint must use HTTPS (HTTP only for loopback tests), without credentials or a fragment")
    return parts.scheme, parts.hostname, port or (443 if parts.scheme == "https" else 80)


def retry_after(value) -> float | None:
    if not value:
        return None
    try:
        seconds = float(value.strip())
    except ValueError:
        try:
            dt = email.utils.parsedate_to_datetime(value)
            if dt.tzinfo is None:
                dt = dt.replace(tzinfo=datetime.timezone.utc)
            seconds = dt.timestamp() - time.time()
        except (TypeError, ValueError, AttributeError, OverflowError):
            return None
    return None if seconds != seconds else min(max(seconds, 0.0), MAX_RETRY_DELAY)


def error_detail(body: bytes, secret=None) -> str:
    text = body.decode("utf-8", "replace").strip()
    try:
        data = json.loads(text)
    except ValueError:
        data = None
    if isinstance(data, dict):
        errors = data.get("errors")
        first = errors[0] if isinstance(errors, list) and errors and isinstance(errors[0], dict) else {}
        if message := next(
            (
                item
                for item in (data.get("message"), first.get("message"), data.get("error"))
                if isinstance(item, str) and item
            ),
            None,
        ):
            code = data.get("code")
            text = f"{code}: {message}" if isinstance(code, str) and code else message
    return redact(text, secret)[:500] or "(empty response body)"


class _NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


class Client:
    def __init__(self, api_key: str, base_url: str = DEFAULT_BASE_URL):
        if not api_key or any(not 33 <= ord(char) <= 126 for char in api_key):
            raise SertError("ROBLOX_API_KEY is empty, or holds whitespace or non-ASCII characters")
        self.key = api_key
        self.base_url = base_url.rstrip("/")
        self.origin = checked_url(self.base_url)
        self.opener = urllib.request.build_opener(_NoRedirect)

    def request(
        self,
        method: str,
        path: str,
        *,
        json_body=None,
        data: bytes | None = None,
        content_type: str | None = None,
        timeout: float = 120,
    ) -> dict:
        url = path if path.startswith(("http://", "https://")) else self.base_url + path
        if checked_url(url) != self.origin:
            raise SertError("refusing to send the API key outside the configured API origin")
        headers = {"User-Agent": USER_AGENT, "Accept": "application/json", "x-api-key": self.key}
        if json_body is not None:
            data, content_type = json.dumps(json_body).encode("utf-8"), "application/json"
        if content_type:
            headers["Content-Type"] = content_type
        where = f"{method} {urllib.parse.urlsplit(url).path}"
        rate_limited = transient = 0
        while True:
            try:
                with self.opener.open(
                    urllib.request.Request(url, data=data, headers=headers, method=method), timeout=timeout
                ) as response:
                    body = response.read()
                break
            except urllib.error.HTTPError as error:
                status = error.code
                try:
                    body = error.read()
                except (OSError, http.client.HTTPException):
                    body = b""
                finally:
                    error.close()
                detail = error_detail(body, self.key)
                wait = retry_after(error.headers.get("Retry-After") if error.headers else None)
                if status == 429:
                    rate_limited += 1
                    if rate_limited >= RATE_LIMIT_ATTEMPTS:
                        raise ApiError(
                            f"{where} was rate limited (HTTP 429) {rate_limited} times: {detail} (429 also means the place already has 10 unfinished tasks)",
                            status,
                        )
                    delay = wait if wait is not None else min(2.0**rate_limited, MAX_RETRY_DELAY)
                elif status >= 500 and method in IDEMPOTENT:
                    transient += 1
                    if transient > TRANSIENT_RETRIES:
                        raise ApiError(
                            f"{where} failed with HTTP {status} after {transient} attempts: {detail}", status
                        )
                    delay = wait if wait is not None else 2.0 ** (transient - 1)
                else:
                    hint = (
                        " (check the API key, its permissions for this universe and place, and its IP allowlist)"
                        if status in (401, 403)
                        else ""
                    )
                    retried = "; not retried, since it may have been processed" if status >= 500 else ""
                    raise ApiError(f"{where} failed with HTTP {status}: {detail}{hint}{retried}", status)
                reason = f"HTTP {status}"
            except (urllib.error.URLError, OSError, http.client.HTTPException) as error:
                reason = redact(f"connection error ({getattr(error, 'reason', None) or error})", self.key)
                if "certificate verify failed" in reason:
                    raise SertError(f"{where}: {reason}; Python may need its certificates installed") from None
                if method not in IDEMPOTENT:
                    raise ApiError(f"{where} failed: {reason}; not retried, since it may have been processed") from None
                transient += 1
                if transient > TRANSIENT_RETRIES:
                    raise ApiError(f"{where} failed after {transient} attempts: {reason}") from None
                delay = 2.0 ** (transient - 1)
            note(f"{where}: {reason}; retrying in {delay:g} s", err=_err_stream())
            SLEEP(delay)
        if not body.strip():
            return {}
        try:
            result = json.loads(body)
        except ValueError:
            raise ApiError(f"{where} returned a response that is not JSON") from None
        if not isinstance(result, dict):
            raise ApiError(f"{where} returned JSON that is not an object")
        return result


def upload_place(client: Client, universe: str, place: str, path: str) -> int:
    extension = os.path.splitext(path)[1].lower()
    if extension not in PLACE_CONTENT_TYPES:
        raise SertError(f"the place must be a .rbxl or .rbxlx file: {path}")
    with open(path, "rb") as handle:
        body = handle.read()
    response = client.request(
        "POST",
        f"/universes/v1/{universe}/places/{place}/versions?versionType=Saved",
        data=body,
        content_type=PLACE_CONTENT_TYPES[extension],
        timeout=300,
    )
    version = response.get("versionNumber")
    if not isinstance(version, int) or isinstance(version, bool) or version < 1:
        raise ApiError("the upload response did not include a versionNumber")
    print(f"uploaded {len(body)} bytes as saved version {version}", flush=True)
    return version


def create_task(
    client: Client, universe: str, place: str, version: int | None, script: str, timeout: int = TASK_LIMIT
) -> dict:
    if len(script.encode("utf-8")) > MAX_SCRIPT_BYTES:
        raise SertError(f"the script is larger than the 4 MB limit ({MAX_SCRIPT_BYTES} bytes)")
    parent = f"/cloud/v2/universes/{universe}/places/{place}" + (f"/versions/{version}" if version is not None else "")
    task = client.request(
        "POST", parent + "/luau-execution-session-tasks", json_body={"script": script, "timeout": f"{int(timeout)}s"}
    )
    if not isinstance(task.get("path"), str):
        raise ApiError("the create task response did not include a task path")
    return task


def task_url(path: str) -> str:
    return "/cloud/v2/" + urllib.parse.quote(path.lstrip("/"), safe="/")


def cancel_task(client: Client, path: str) -> bool:
    """Cancels an incomplete Open Cloud Luau execution task so the 10-task per-place quota never leaks."""
    try:
        client.request("POST", task_url(path) + ":cancel", json_body={}, timeout=15)
        return True
    except SertError as err:
        note(f"warning: could not cancel task {path}: {redact(err, client.key)}", err=_err_stream())
        return False


def wait_for_task(client: Client, task: dict, give_up_after: float) -> dict:
    deadline, delay = CLOCK() + give_up_after, POLL_START
    while True:
        state = task.get("state")
        if state in FINAL_STATES:
            return task
        if state not in ("QUEUED", "PROCESSING"):
            raise ApiError(f"unexpected task state {state!r}")
        remaining = deadline - CLOCK()
        if remaining <= 0:
            raise GiveUp(f"task {task['path']} still {state} after {give_up_after:g} s; giving up on it")
        SLEEP(min(delay, remaining))
        delay = min(delay * 1.5, POLL_MAX)
        task = client.request("GET", task_url(task["path"]))


def get_logs(client: Client, path: str) -> list[dict]:
    base = task_url(path) + "/logs?view=STRUCTURED&maxPageSize=10000"
    messages, token, seen = [], "", set()
    while True:
        page = client.request("GET", base + (f"&pageToken={urllib.parse.quote(token, safe='')}" if token else ""))
        for entry in page.get("luauExecutionSessionTaskLogs") or []:
            if isinstance(entry, dict):
                # Prefer `structuredMessages` for typed severity while deduplicating matching texts in `messages`
                # so flat-only messages are preserved without emitting duplicates.
                seen_structured: dict[str, int] = {}
                for item in entry.get("structuredMessages") or []:
                    if isinstance(item, dict):
                        msg_text = str(item.get("message", ""))
                        seen_structured[msg_text] = seen_structured.get(msg_text, 0) + 1
                        messages.append(
                            {
                                "messageType": str(item.get("messageType") or "OUTPUT"),
                                "message": msg_text,
                            }
                        )
                for text in entry.get("messages") or []:
                    msg_text = str(text)
                    if seen_structured.get(msg_text, 0) > 0:
                        seen_structured[msg_text] -= 1
                    else:
                        messages.append({"messageType": "OUTPUT", "message": msg_text})
        token = page.get("nextPageToken") or ""
        if not isinstance(token, str) or token in seen:
            raise ApiError("invalid or repeated log page token")
        if not token:
            return messages
        seen.add(token)


def format_log(entry: dict) -> str:
    kind = entry.get("messageType") or "OUTPUT"
    message = str(entry.get("message", "")).replace("\r\n", "\n").rstrip("\n")
    prefix = LOG_PREFIXES.get(kind, "" if kind == "OUTPUT" else f"[{kind}] ")
    return prefix + message.replace("\n", "\n" + (" " * 4 if prefix else ""))


def task_seconds(task: dict) -> float | None:
    def parse_ts(stamp):
        if not (match := re.match(r"^(.*?T\d\d:\d\d:\d\d)(?:\.(\d+))?(Z|[+-]\d\d:\d\d)$", stamp or "")):
            return None
        fraction = (match.group(2) or "0")[:6].ljust(6, "0")
        zone = "+00:00" if match.group(3) == "Z" else match.group(3)
        return datetime.datetime.fromisoformat(f"{match.group(1)}.{fraction}{zone}")

    created, updated = parse_ts(task.get("createTime")), parse_ts(task.get("updateTime"))
    return (updated - created).total_seconds() if created and updated else None


def sert_results(lines: list[str]) -> list:
    return markers.parse("\n".join(lines)).outcomes


def classify(task: dict, lines: list[str]) -> tuple[int, str]:
    state = task.get("state")
    error = task.get("error") if isinstance(task.get("error"), dict) else {}
    if state == "COMPLETE":
        output = task.get("output")
        results = output.get("results") if isinstance(output, dict) else None
        first = results[0] if isinstance(results, list) and results else None
        if why := (
            markers.failure(first) or next((r for item in sert_results(lines) if (r := markers.failure(item))), None)
        ):
            return FAILED, f"COMPLETE, but the result reports failure ({why})"
        return OK, "COMPLETE"
    if state == "FAILED":
        code = error.get("code") or "UNKNOWN_ERROR"
        message = (str(error.get("message") or "").strip().splitlines() or ["(no message)"])[0]
        if code == "SCRIPT_ERROR":
            return FAILED, f"FAILED, {code}: {message}"
        if code == "DEADLINE_EXCEEDED":
            return TIMEOUT, f"TIMED OUT, {code}: {message}"
        return INFRA, f"FAILED, {code}: {message}"
    if state == "CANCELLED":
        return INFRA, "CANCELLED"
    return (
        INFRA,
        f"still {state} (gave up waiting)"
        if state in ("QUEUED", "PROCESSING")
        else f"unexpected task state {state!r}",
    )


def run_task(client: Client, universe: str, place: str, version: int | None, source: str, label: str) -> dict:
    out = _out_stream()
    err_out = _err_stream()
    limit_sec = _task_limit()
    task = create_task(client, universe, place, version, source, timeout=limit_sec)
    path = task["path"]
    _advance_gate()
    print(f"[{label}] task {path} created", file=out, flush=True)
    finished = task.get("state") in FINAL_STATES
    try:
        try:
            task = wait_for_task(client, task, limit_sec + QUEUE_ALLOWANCE)
            finished = task.get("state") in FINAL_STATES
        except GiveUp as err:
            note(f"[{label}] {err}", err=err_out)
            return {"label": label, "exit": TIMEOUT, "verdict": str(err), "seconds": None, "path": path}
    finally:
        if not finished:
            cancel_task(client, path)

    lines = [format_log(entry) for entry in get_logs(client, path)]
    for line in lines:
        print(line, file=out)
    seconds = task_seconds(task)
    if seconds is not None:
        print(
            f"[{label}] task took {seconds:.1f} s of its {limit_sec} s limit (budget {limit_sec // 2} s)",
            file=out,
        )
        if seconds > limit_sec / 2:
            slow = (
                f"Luau task {label} took {seconds:.0f} s, over half its {limit_sec} s limit:"
                " split its shard or speed it up before it times out"
            )
            if not util.annotate("warning", slow, out=out):
                print(f"warning: {slow}", file=out)
    code, verdict = classify(task, lines)
    print(f"[{label}] {verdict}", file=err_out if code else out, flush=True)
    return {"label": label, "exit": code, "verdict": verdict, "seconds": seconds, "path": path}


def add_arguments(parser: argparse.ArgumentParser) -> None:
    parser.add_argument("--project", help="Rojo project that builds the place (default [cloud].project)")
    parser.add_argument("--script", help="Luau file to run as the task (default [cloud].script, or synthesized)")
    parser.add_argument("--place", metavar="FILE", help="upload this .rbxl/.rbxlx instead of building the project")
    parser.add_argument(
        "--place-version", type=int, metavar="N", help="run against this uploaded place version; no build or upload"
    )
    parser.add_argument("--output", metavar="FILE", help="write the built place here and keep it")
    parser.add_argument(
        "--shard", action="append", default=[], metavar="NAME", help="only this shard of [cloud].shards; repeatable"
    )
    parser.add_argument(
        "-j",
        "--jobs",
        type=int,
        default=None,
        metavar="N",
        help=f"parallel shard tasks (default [cloud].jobs or {DEFAULT_JOBS}, max {MAX_PARALLEL_SHARDS})",
    )
    parser.add_argument(
        "--timeout",
        type=int,
        default=None,
        metavar="S",
        help=f"per-task Open Cloud timeout in seconds (default [cloud].timeout or {TASK_LIMIT})",
    )
    parser.add_argument("--json-out", metavar="FILE", help="write the tasks' verdicts as JSON")
    parser.add_argument("--unsharded", action="store_true", help="run the script once, unchanged, ignoring [cloud].shards")
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="build the place and print each shard's statement; no environment, no network",
    )
    parser.add_argument("--emit", metavar="DIR", help="with --dry-run: write each shard's script into DIR")


def add_parser(subparsers) -> argparse.ArgumentParser:
    parser = subparsers.add_parser("cloud")
    add_arguments(parser)
    parser.set_defaults(func=main)
    return parser


def main(args, env=None) -> int:
    env = os.environ if env is None else env
    root = str(sert_config.find_root(getattr(args, "root", None)))
    try:
        cfg = sert_config.load(root)
        from sert import fetch

        fetch.refresh_overrides(cfg)
        fetch.ensure_fetched(cfg)
        return execute(root, cfg.get("cloud") or {}, args, env)
    except SertError as err:
        note(f"sert cloud: {redact(err, env.get('ROBLOX_API_KEY'))}")
        return err.code


def _discover_cloud_specs(root: str, conf: dict) -> list[str]:
    raw_specs = conf.get("specs")
    patterns = (
        [raw_specs]
        if isinstance(raw_specs, str)
        else (list(raw_specs) if isinstance(raw_specs, list) else list(DEFAULT_CLOUD_SPECS))
    )
    return [str(p) for p in expand_globs(Path(root), patterns, files=True)]


def _resolve_cloud_project(root: str, conf: dict, args) -> str | None:
    explicit = getattr(args, "project", None) or conf.get("project")
    if explicit:
        return explicit
    for candidate in ("test/default.project.json", "default.project.json"):
        if os.path.isfile(os.path.join(root, candidate)):
            return candidate
    return None


def built_place(root: str, conf: dict, args, *, synthesized_specs: list[str] | None = None):
    project = (
        _resolve_cloud_project(root, conf, args)
        if synthesized_specs
        else (getattr(args, "project", None) or conf.get("project"))
    )
    if not project:
        note("sert cloud: no project: pass --project or set [cloud].project (or pass --place or --place-version)")
        return INFRA
    output_arg = getattr(args, "output", None)
    temporary = tempfile.mkdtemp(prefix="sert-cloud-")
    place_file = os.path.join(root, output_arg) if output_arg else os.path.join(temporary, "place.rbxl")
    effective_project = project
    if synthesized_specs:
        from sert.studio import synthesize_rojo_overlay

        proj_abs = project if os.path.isabs(project) else os.path.join(root, project)
        overlay = synthesize_rojo_overlay(
            root,
            proj_abs,
            synthesized_specs,
            os.path.join(temporary, "studio-overlay"),
            include_runners=False,
        )
        if overlay is not None:
            effective_project = overlay[0]
    if build_place(root, effective_project, place_file) is None:
        shutil.rmtree(temporary, ignore_errors=True)
        return INFRA
    if output_arg:
        shutil.rmtree(temporary, ignore_errors=True)
        temporary = None
    return place_file, temporary


def dry_run(
    root: str,
    conf: dict,
    args,
    source: str,
    script_path: str,
    shards: list[dict],
    limit: float,
    synthesized_specs: list[str] | None = None,
) -> int:
    if args.place_version is None and not args.place:
        built = built_place(root, conf, args, synthesized_specs=synthesized_specs)
        if isinstance(built, int):
            return built
        place_file, temporary = built
        print(f"built {os.path.getsize(place_file)} bytes; not uploaded (--dry-run)", flush=True)
        if temporary:
            shutil.rmtree(temporary, ignore_errors=True)
    if len(source.encode("utf-8")) > MAX_SCRIPT_BYTES:
        note(f"sert cloud: the script is larger than the 4 MB limit ({MAX_SCRIPT_BYTES} bytes)")
        return INFRA
    tasks = (
        [(os.path.basename(script_path), None, source)]
        if not shards
        else [
            (shard["name"], info := shard_info(shards, index, limit), inject_shard(source, info))
            for index, shard in enumerate(shards)
            if not args.shard or shard["name"] in args.shard
        ]
    )
    emit_dir = os.path.join(root, args.emit) if args.emit else None
    if emit_dir:
        os.makedirs(emit_dir, exist_ok=True)
    for label, info, text in tasks:
        print(
            f"[{label}] runs unchanged (no [cloud].shards)"
            if info is None
            else f"[{label}] {shard_statement(info).rstrip()}"
        )
        if emit_dir:
            name = label if label.endswith(".luau") else f"{label}.luau"
            with open(os.path.join(emit_dir, name), "w", encoding="utf-8") as handle:
                handle.write(text)
    if args.json_out:
        json_path = os.path.join(root, args.json_out)
        os.makedirs(os.path.dirname(os.path.abspath(json_path)), exist_ok=True)
        with open(json_path, "w", encoding="utf-8") as handle:
            json.dump(
                {"dryRun": True, "tasks": [{"label": label, "shard": info} for label, info, _ in tasks]},
                handle,
                indent=1,
            )
            handle.write("\n")
    return OK


def prepare(root: str, conf: dict, args):
    script = getattr(args, "script", None) or conf.get("script")
    synthesized_specs: list[str] | None = None
    if not script:
        discovered = _discover_cloud_specs(root, conf)
        if not discovered:
            note("sert cloud: no script: pass --script or set [cloud].script")
            return INFRA
        script_path = os.path.join(root, "cloud.luau")
        source = ZERO_BOILERPLATE_CLOUD_SCRIPT
        synthesized_specs = discovered
    else:
        script_path = os.path.join(root, script)
        try:
            with open(script_path, encoding="utf-8") as handle:
                source = handle.read()
        except (OSError, UnicodeDecodeError) as err:
            note(f"sert cloud: cannot read {script_path}: {err}")
            return INFRA
    shards = normalize_shards(conf.get("shards"))
    limit = float(conf.get("shard_limit", SHARD_LIMIT))
    if getattr(args, "unsharded", False):
        if args.shard:
            note("sert cloud: --shard and --unsharded exclude each other")
            return INFRA
        shards = []
    if args.shard:
        if not shards:
            note("sert cloud: --shard: [cloud].shards names no shards")
            return INFRA
        if unknown := sorted(set(args.shard) - {shard["name"] for shard in shards}):
            note(f"sert cloud: --shard: no shard named {', '.join(unknown)}")
            return INFRA
    return script_path, source, shards, limit, synthesized_specs


def _run_tasks_parallel(
    client: Client,
    universe: str,
    place: str,
    version: int | None,
    tasks: list[tuple[str, str]],
    *,
    key: str,
    jobs: int,
    task_timeout: int,
) -> list[dict]:
    if len(tasks) <= 1 or jobs <= 1:
        verdicts = []
        rate_limited = None
        old_timeout = getattr(_TLS, "task_timeout", None)
        _TLS.task_timeout = task_timeout
        try:
            for label, text in tasks:
                if rate_limited is not None:
                    verdicts.append(
                        {
                            "label": label,
                            "exit": INFRA,
                            "verdict": f"not run: {rate_limited} was rate limited",
                            "seconds": None,
                            "path": None,
                        }
                    )
                    continue
                try:
                    verdicts.append(run_task(client, universe, place, version, text, label))
                except SertError as err:
                    message = redact(err, key)
                    note(f"sert cloud: [{label}] {message}")
                    verdicts.append(
                        {"label": label, "exit": err.code, "verdict": message, "seconds": None, "path": None}
                    )
                    if isinstance(err, ApiError) and err.status == 429:
                        rate_limited = label
        finally:
            _TLS.task_timeout = old_timeout
        return verdicts

    workers = min(max(1, jobs), len(tasks), MAX_PARALLEL_SHARDS)
    cond = threading.Condition()
    next_to_create = 0
    rate_limited_by: str | None = None
    interrupted = False

    def worker(index: int, label: str, text: str) -> tuple[dict, str, str]:
        nonlocal next_to_create, rate_limited_by
        with cond:
            while index > next_to_create and rate_limited_by is None and not interrupted:
                cond.wait()
            if interrupted:
                return (
                    {"label": label, "exit": INTERRUPTED, "verdict": "interrupted", "seconds": None, "path": None},
                    "",
                    "",
                )
            if rate_limited_by is not None:
                return (
                    {
                        "label": label,
                        "exit": INFRA,
                        "verdict": f"not run: {rate_limited_by} was rate limited",
                        "seconds": None,
                        "path": None,
                    },
                    "",
                    "",
                )

        advanced = False

        def mark_created() -> None:
            nonlocal advanced, next_to_create
            if not advanced:
                advanced = True
                with cond:
                    next_to_create = max(next_to_create, index + 1)
                    cond.notify_all()

        out_buf, err_buf = io.StringIO(), io.StringIO()
        _TLS.out = out_buf
        _TLS.err = err_buf
        _TLS.task_timeout = task_timeout
        _TLS.on_created = mark_created
        try:
            verdict = run_task(client, universe, place, version, text, label)
            return verdict, out_buf.getvalue(), err_buf.getvalue()
        except SertError as err:
            message = redact(err, key)
            note(f"sert cloud: [{label}] {message}", err=err_buf)
            if isinstance(err, ApiError) and err.status == 429:
                with cond:
                    if rate_limited_by is None:
                        rate_limited_by = label
                    cond.notify_all()
            return (
                {"label": label, "exit": err.code, "verdict": message, "seconds": None, "path": None},
                out_buf.getvalue(),
                err_buf.getvalue(),
            )
        finally:
            mark_created()
            _TLS.out = None
            _TLS.err = None
            _TLS.task_timeout = None
            _TLS.on_created = None

    futures = []
    executor = ThreadPoolExecutor(max_workers=workers)
    try:
        for idx, (label, text) in enumerate(tasks):
            futures.append(executor.submit(worker, idx, label, text))
        results = [fut.result() for fut in futures]
    except KeyboardInterrupt:
        interrupted = True
        with cond:
            cond.notify_all()
        for fut in futures:
            fut.cancel()
        executor.shutdown(wait=True, cancel_futures=True)
        raise
    else:
        executor.shutdown(wait=True)

    verdicts: list[dict] = []
    for verdict, out_str, err_str in results:
        if out_str:
            sys.stdout.write(out_str)
            sys.stdout.flush()
        if err_str:
            sys.stderr.write(err_str)
            sys.stderr.flush()
        verdicts.append(verdict)
    return verdicts


def execute(root: str, conf: dict, args, env) -> int:
    raw_jobs = getattr(args, "jobs", None)
    cfg_jobs = conf.get("jobs") if conf.get("jobs") is not None else conf.get("max_workers", DEFAULT_JOBS)
    jobs = int(raw_jobs if raw_jobs is not None else cfg_jobs)
    if jobs < 1:
        note("sert cloud: --jobs must be at least 1")
        return INFRA
    raw_timeout = getattr(args, "timeout", None)
    task_timeout = int(raw_timeout if raw_timeout is not None else conf.get("timeout", TASK_LIMIT))
    if task_timeout < 1:
        note("sert cloud: --timeout must be at least 1")
        return INFRA

    if getattr(args, "dry_run", False):
        prepared = prepare(root, conf, args)
        return (
            prepared
            if isinstance(prepared, int)
            else dry_run(
                root,
                conf,
                args,
                prepared[1],
                prepared[0],
                prepared[2],
                prepared[3],
                synthesized_specs=prepared[4],
            )
        )
    if getattr(args, "emit", None):
        note("sert cloud: --emit needs --dry-run")
        return INFRA
    resolved = [next((env.get(alias) for alias in aliases if env.get(alias)), None) for aliases in ENV]
    if missing := [aliases[0] for aliases, val in zip(ENV, resolved) if not val]:
        note(f"sert cloud: missing environment: {', '.join(missing)}")
        return INFRA
    key, universe, place = resolved
    client = Client(key, env.get("ROBLOX_CLOUD_BASE_URL") or DEFAULT_BASE_URL)
    prepared = prepare(root, conf, args)
    if isinstance(prepared, int):
        return prepared
    script_path, source, shards, limit, synthesized_specs = prepared

    version = args.place_version
    if version is None:
        place_file, temporary = (os.path.join(root, args.place), None) if args.place else (None, None)
        if place_file is None:
            built = built_place(root, conf, args, synthesized_specs=synthesized_specs)
            if isinstance(built, int):
                return built
            place_file, temporary = built
        try:
            version = upload_place(client, universe, place, place_file)
        finally:
            if temporary:
                shutil.rmtree(temporary, ignore_errors=True)

    tasks = (
        [
            (shard["name"], inject_shard(source, shard_info(shards, index, limit)))
            for index, shard in enumerate(shards)
            if not args.shard or shard["name"] in args.shard
        ]
        if shards
        else [(os.path.basename(script_path), source)]
    )
    try:
        verdicts = _run_tasks_parallel(
            client,
            universe,
            place,
            version,
            tasks,
            key=key,
            jobs=jobs,
            task_timeout=task_timeout,
        )
    except KeyboardInterrupt:
        note("sert cloud: interrupted")
        return INTERRUPTED

    if shards and (failed := [v["label"] for v in verdicts if v["exit"]]):
        note(f"failed shards: {', '.join(failed)}")
    code = worst([v["exit"] for v in verdicts])
    if args.json_out:
        json_path = os.path.join(root, args.json_out)
        os.makedirs(os.path.dirname(os.path.abspath(json_path)), exist_ok=True)
        with open(json_path, "w", encoding="utf-8") as handle:
            json.dump({"exitCode": code, "version": version, "tasks": verdicts}, handle, indent=1)
            handle.write("\n")
    return code
