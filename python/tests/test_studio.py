"""Unit tests for `sert.studio`: markers, single-launch `--grep`, `--device` presets, `--clients`, `--warm`, `--help` hook isolation, and zero-boilerplate Rojo overlay."""

from __future__ import annotations

import argparse
import contextlib
import io
import json
import os
import pathlib
import re
import shlex
import shutil
import sys
import tempfile
import unittest
from unittest import mock

import helpers
from helpers import REPO
from sert import cli, luau_lex, util
from sert.studio import driver, flake, markers, runscript, suites
from sert.util import SertError

CATALOGUE = [
    {"file": "Button", "name": "button · clicks"},
    {"file": "Button", "name": "button · hover"},
    {"file": "Menu", "name": "menu · opens submenu"},
    {"file": "client/Users", "name": "client · users list"},
    {"file": "server/Users", "name": "server · users load"},
]


def test_line(name, status, file="F", ms=1, **extra):
    return "[sert-test] " + json.dumps({"name": name, "file": file, "status": status, "ms": ms, **extra})


def listing(tests=CATALOGUE):
    return [f"[sert-list] {t['file']}|{t['name']}" for t in tests] + [f"[sert-list] end {len(tests)}"]


def selection(**fields):
    picked = driver.Selection()
    for key, value in fields.items():
        setattr(picked, key, value)
    return picked


class SplitAndParseTest(unittest.TestCase):
    def test_kinds_catalogue_verdicts_and_failure(self):
        self.assertEqual(markers.split("[sert-list] A|b"), ("list", None, "A|b"))
        self.assertEqual(markers.split("[sert-x:wait] 12 a|b"), ("x", "wait", "12 a|b"))
        self.assertEqual(markers.split("  [sert-done] {}"), ("done", None, "{}"))
        self.assertIsNone(markers.split("print [sert-list] x"))

        parsed = markers.parse("[sert-list] Button|a\n[sert-list] Menu|b · c\n[sert-list] end 2\n")
        self.assertEqual(parsed.catalogue, [{"file": "Button", "name": "a"}, {"file": "Menu", "name": "b · c"}])

        verdict = {
            "runId": "r",
            "passed": False,
            "failed": 1,
            "counts": {"passed": 2, "failed": 1, "skipped": 0, "total": 3},
            "seeds": {"p": 9},
            "seed": 4,
            "reason": None,
        }
        p_v = markers.parse("\n".join(['[sert-done] {"passed": 2, "failed": 0, "total": 2}', test_line("p", "fail"), "[sert-verdict] " + json.dumps(verdict)]))
        self.assertEqual((p_v.verdict["runId"], p_v.seeds, p_v.tests[0]["seed"], p_v.run_seed), ("r", {"p": 9}, 9, 4))
        self.assertEqual(markers.failure({"passed": 0, "failed": 0}), "no tests executed")
        self.assertIsNone(markers.failure({"passed": True, "failed": 0, "counts": {"passed": 3, "failed": 0, "skipped": 0, "total": 3}}))


class SelectionAndZeroBoilerplateTest(unittest.TestCase):
    def test_single_launch_grep_device_presets_and_zero_boilerplate_overlay(self):
        # Checklist 6a: `--grep` and `--exclude` NEVER trigger a separate cold Studio launch (`needs_catalogue == False`)!
        p_grep = selection(patterns=[re.compile("submenu")], raw_patterns=["submenu"])
        self.assertFalse(p_grep.needs_catalogue)
        p_grep.resolve(None)
        self.assertEqual(p_grep.request()["grep"], "submenu")

        p_filt = selection(filters=["hover"], files=["Button.spec"], sides=["client"])
        self.assertFalse(p_filt.needs_catalogue)
        p_filt.resolve(None)
        self.assertEqual(
            p_filt.request(),
            {"filter": "", "filters": ["hover"], "file": "Button", "files": ["Button"], "side": "client", "sides": ["client"]},
        )

        # Device presets & custom WxH[@dpr]
        phone_spec = driver.parse_device_spec("Phone")
        self.assertEqual(phone_spec, {"width": 390, "height": 844, "dpr": 3.0, "form": "Phone", "preset": "Phone"})
        custom_spec = driver.parse_device_spec("1280x720@2")
        self.assertEqual((custom_spec["width"], custom_spec["height"], custom_spec["dpr"]), (1280, 720, 2.0))
        prelude = driver.device_prelude("Phone")
        self.assertIn("StudioDeviceSimulatorService", prelude)
        self.assertIn("SetDeviceAsync", prelude)
        with self.assertRaisesRegex(SertError, r"--device"):
            driver.parse_device_spec("NotADevice")

        # Zero-boilerplate Rojo overlay synthesis (`default.project.json` + `.spec.luau` files ONLY!)
        with tempfile.TemporaryDirectory() as tmp:
            root = pathlib.Path(tmp)
            shutil.copytree(REPO / "src", root / ".sert/sert/src")
            (root / "src").mkdir()
            (root / "src/Widget.luau").write_text("return { ok = true }\n", encoding="utf-8")
            (root / "default.project.json").write_text(
                json.dumps(
                    {
                        "name": "DemoGame",
                        "tree": {
                            "$className": "DataModel",
                            "ReplicatedStorage": {
                                "$className": "ReplicatedStorage",
                                "Shared": {"$path": "src"},
                            },
                        },
                    }
                ),
                encoding="utf-8",
            )
            (root / "test").mkdir()
            # 0-return spec file!
            (root / "test/Widget.spec.luau").write_text(
                "--!strict\nlocal ReplicatedStorage = game:GetService('ReplicatedStorage')\n"
                "local sert = require(ReplicatedStorage:WaitForChild('sert'))\n"
                'sert.rtest("mounts widget", function()\n\tsert.ok(true)\nend)\n',
                encoding="utf-8",
            )
            overlay_proj = driver.prepare_studio_project(root, str(root / "default.project.json"))
            self.assertTrue(os.path.isfile(overlay_proj))
            overlay_data = json.loads(pathlib.Path(overlay_proj).read_text(encoding="utf-8"))
            rs = overlay_data["tree"]["ReplicatedStorage"]
            self.assertIn("sert", rs)
            self.assertIn("__sert_specs", rs)
            self.assertIn("__sert_config", rs)
            self.assertIn("__sert_server", overlay_data["tree"]["ServerScriptService"])
            self.assertIn("__sert_client", overlay_data["tree"]["StarterPlayer"]["StarterPlayerScripts"])

            # Verify 0-return spec was staged with `return nil` while preserving line count
            staged_spec = (root / ".sert/studio-overlay/specs/test/Widget.spec.luau").read_text(encoding="utf-8")
            self.assertTrue(luau_lex.has_top_level_return(staged_spec))

    def test_help_never_executes_user_hooks(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = pathlib.Path(tmp)
            marker_file = root / "hook_ran.txt"
            (root / "hooks.py").write_text(f"import pathlib\npathlib.Path({str(marker_file)!r}).write_text('ran')\n", encoding="utf-8")
            (root / "sert.toml").write_text('[studio]\nhooks = "hooks.py"\n', encoding="utf-8")
            out = io.StringIO()
            with mock.patch("sys.stdout", out), self.assertRaises(SystemExit) as caught:
                cli.main(["studio", "--root", str(root), "--help"])
            self.assertEqual(caught.exception.code, 0)
            self.assertFalse(marker_file.exists(), "sert studio --help must NEVER execute hooks.py!")
            for flag in ("--device", "--clients", "--warm"):
                self.assertIn(flag, out.getvalue())


class FakeStudio:
    def __init__(self, respond):
        self.respond = respond
        self.requests, self.calls = [], []

    def __call__(self, place, *, mode, report, script=None, args=None, prelude=None, timeout, keep, launcher, warm=False, studio_id=None):
        self.calls.append(
            {
                "place": place,
                "mode": mode,
                "prelude": prelude,
                "timeout": timeout,
                "keep": keep,
                "launcher": launcher,
                "warm": warm,
                "studio_id": studio_id,
            }
        )
        request = {"edit": True, "source": script} if mode == "edit" else json.loads(json.dumps(args))
        self.requests.append(request)
        code, output, result = self.respond(len(self.requests), request)
        with open(report, "w", encoding="utf-8") as handle:
            json.dump({"exitCode": code, "result": result, "output": output, "seconds": 1.0, "message": "fake"}, handle)
        return code


class EndToEndStudioTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = self.tmp.name
        os.makedirs(os.path.join(self.root, "test", "unit"))
        for name in ("Button", "Menu"):
            with open(os.path.join(self.root, "test", "unit", f"{name}.spec.luau"), "w", encoding="utf-8") as handle:
                handle.write(f"-- {name}\nreturn nil\n")
        self.conf = {"studio": {"mode": "play", "specs": ["test/unit/*.spec.luau"], "out": "out"}}

    def tearDown(self):
        self.tmp.cleanup()

    def run_driver(self, fake, argv, hooks=None, conf=None, json_out=False):
        settings = suites.Settings(self.root, conf or self.conf)
        hooks = hooks or driver.Hooks()
        opts = driver.build_parser(settings, hooks).parse_args(argv)
        out = io.StringIO()
        with (
            mock.patch.object(runscript, "run", fake),
            mock.patch.object(driver, "build_place", lambda root, project, place, quiet=False: 0.1),
            contextlib.redirect_stdout(out),
            contextlib.redirect_stderr(io.StringIO()),
        ):
            if json_out:
                opts.json_records = []
                code = driver.write_json_out(opts, driver.guarded(settings, hooks, opts))
            else:
                code = driver.guarded(settings, hooks, opts)
        return code, out.getvalue(), settings

    def test_single_launch_grep_device_clients_warm_and_replay(self):
        # `--grep` runs in ONE Studio launch without needing a pre-existing catalogue!
        fake = FakeStudio(
            lambda n, r: (
                0,
                "\n".join([test_line("button · clicks", "pass", file="Button"), '[sert-done] {"passed":1,"failed":0,"total":1}']),
                {"ok": True, "value": {"passed": 1, "failed": 0}},
            )
        )
        code, _, _ = self.run_driver(fake, ["--grep", "clicks$", "--device", "Phone", "--clients", "2", "--warm", "--studio", "s42"])
        self.assertEqual(code, 0)
        self.assertEqual(len(fake.calls), 1)
        self.assertEqual(fake.requests[0]["grep"], "clicks$")
        self.assertEqual(fake.requests[0]["clients"], 2)
        self.assertIn("SetDeviceAsync", fake.calls[0]["prelude"])
        self.assertEqual((fake.calls[0]["warm"], fake.calls[0]["studio_id"]), (True, "s42"))

        # Replay failed seeds with `--failed`
        def first(n, request):
            lines = listing(CATALOGUE[:3]) + [
                "[sert-seed] run 5",
                test_line("button · clicks", "pass", file="?"),
                test_line("button · hover", "fail", file="?", error="nope"),
                "[sert-seed] button · hover|777",
                '[sert-done] {"passed": 1, "failed": 1, "skipped": 0, "total": 2}',
            ]
            return 1, "\n".join(lines), {"ok": True, "value": {"passed": 1, "failed": 1}}

        code1, out1, _ = self.run_driver(FakeStudio(first), [])
        self.assertEqual(code1, 1)
        self.assertIn("FAIL Button: button · hover (seed 777)", out1)

        def replay(n, request):
            self.assertEqual((request["names"], request["seeds"]), (["button · hover"], {"button · hover": 777}))
            return (
                0,
                "\n".join([test_line("button · hover", "pass"), '[sert-done] {"passed": 1, "failed": 0, "total": 1}']),
                {"ok": True, "value": {"passed": 1, "failed": 0}},
            )

        code2, out2, _ = self.run_driver(FakeStudio(replay), ["--failed"])
        self.assertEqual(code2, 0, out2)


RUNNER_LUAU = REPO / "src" / "roblox" / "Runner.luau"


def runner_request_keys() -> set[str]:
    text = RUNNER_LUAU.read_text(encoding="utf-8")
    block = re.search(r"export type Request = \{(.*?)\n\}", text, re.S)
    assert block is not None, "Runner.luau has no `export type Request`"
    keys = set(re.findall(r"^\s*(\w+)\s*:", block.group(1), re.M))
    keys.update(re.findall(r'^\s*\["(\w+)"\]\s*:', block.group(1), re.M))
    return keys


class RequestKeysContractTest(unittest.TestCase):
    def test_studio_driver_request_matches_runner_luau_type(self):
        with tempfile.TemporaryDirectory() as root:
            conf = {"studio": {"mode": "play", "specs": ["test/unit/*.spec.luau"], "sides": ["server"], "out": "out"}}
            os.makedirs(os.path.join(root, "test", "unit"))
            pathlib.Path(root, "test", "unit", "Button.spec.luau").write_text("return nil\n", encoding="utf-8")
            settings = suites.Settings(root, conf)
            every = [
                "--seed",
                "1",
                "--runs",
                "2",
                "--replay",
                "3",
                "--exhaustive",
                "--budget",
                "4",
                "--repeat",
                "2",
                "--test-timeout",
                "5",
                "--deadline",
                "6",
                "--filter",
                "a",
                "--grep",
                "btn",
                "--file",
                "Button",
                "--side",
                "server",
                "--exclude",
                "zzz",
                "--clients",
                "2",
            ]
            opts = driver.build_parser(settings, driver.Hooks()).parse_args(every + ["needle"])
            picked = selection(
                filter="needle",
                filters=["a"],
                raw_patterns=["btn"],
                files=["Button"],
                sides=["server"],
                excludes=["zzz"],
                names=["n"],
                seeds={"n": 7},
            )
            request = driver.build_request(settings, opts, "play", picked, "run-1")
            allowed = runner_request_keys()
            self.assertEqual(sorted(set(request) - allowed), [])
            self.assertEqual((request["replay"], request["exhaustive"], request["budget"], request["clients"]), (3, True, 4.0, 2))


if __name__ == "__main__":
    unittest.main()
