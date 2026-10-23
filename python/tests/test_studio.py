import argparse, contextlib, io, json, os, pathlib, re, shlex, sys, tempfile, unittest
from unittest import mock

import helpers  # noqa: F401
from sert import cli, util
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
    def test_kinds_and_tags(self):
        self.assertEqual(markers.split("[sert-list] A|b"), ("list", None, "A|b"))
        self.assertEqual(markers.split("[sert-x:wait] 12 a|b"), ("x", "wait", "12 a|b"))
        self.assertEqual(markers.split("  [sert-done] {}"), ("done", None, "{}"))
        self.assertIsNone(markers.split("print [sert-list] x"))
        self.assertIsNone(markers.split("✅ name · 3 ms"))

    def test_catalogue_and_pipes(self):
        parsed = markers.parse("[sert-list] Button|a\n[sert-list] Menu|b · c\n[sert-list] end 2\n")
        self.assertEqual(parsed.catalogue, [{"file": "Button", "name": "a"}, {"file": "Menu", "name": "b · c"}])
        self.assertIsNone(markers.parse("[sert-list] Button|a\n").catalogue)
        self.assertIsNone(markers.parse("[sert-list] Button|a\n[sert-list] end 3\n").catalogue)
        piped = markers.parse("[sert-list] F|a|b\n[sert-list] end 1\n[sert-seed] a|b|42\n")
        self.assertEqual((piped.catalogue, piped.seeds), ([{"file": "F", "name": "a|b"}], {"a|b": 42}))

    def test_tests_statuses_seeds_and_iterations(self):
        output = "\n".join([
            "[sert-seed] run 99", "[sert-seed] run 100",
            test_line("p", "pass"), test_line("q", "fail", error="boom"),
            test_line("r", "skip"), test_line("s", "todo"), "[sert-seed] q|1234",
        ])
        parsed = markers.parse(output)
        self.assertEqual((parsed.run_seed, [t["status"] for t in parsed.tests]), (99, ["pass", "fail", "skip", "todo"]))
        self.assertEqual((parsed.tests[1]["message"], parsed.tests[1]["seed"]), ("boom", 1234))
        self.assertNotIn("seed", parsed.tests[0])

        iters = markers.parse("\n".join([
            "[sert-iter] server 1 begin", test_line("server · a", "pass"),
            '[sert-iter] server 1 end {"passed":1,"failed":0,"skipped":0,"total":1}',
            "[sert-iter] server 2 begin", test_line("server · a", "fail"),
            '[sert-iter] server 2 end {"passed":0,"failed":1,"skipped":0,"total":1}',
            "[sert-iter] client 1 begin", test_line("client · b", "pass"),
            '[sert-iter] client 1 end {"passed":1,"failed":0,"skipped":0,"total":1}',
            "[sert-iter] client 2 begin", test_line("client · b", "pass"),
            '[sert-iter] client 2 end {"passed":1,"failed":0,"skipped":0,"total":1}',
        ]))
        self.assertEqual([[t["name"] for t in r] for r in iters.per_iteration()], [["server · a", "client · b"]] * 2)
        self.assertEqual([i["summary"] for i in iters.iterations], ["PASSED 2/2", "FAILED 1 of 2"])

    def test_list_per_place_and_file_sides(self):
        parsed = markers.parse("\n".join([
            "[sert-file] server|Users|12", "[sert-file] client|Toasts|3", "[sert-file] main|*|1",
            "[sert-list] Users|server · u", "[sert-list] end 1",
            "[sert-list] Toasts|client · t", "[sert-list] ?|loose", "[sert-list] end 2",
        ]))
        self.assertEqual(parsed.catalogue, [
            {"file": "Users", "name": "server · u", "side": "server"},
            {"file": "Toasts", "name": "client · t", "side": "client"},
            {"file": "?", "name": "loose"},
        ])
        self.assertEqual(parsed.files[0], {"side": "server", "file": "Users", "ms": 12})

        shared = markers.parse("\n".join([
            "[sert-file] server|Addons|1", "[sert-list] Addons|server test", "[sert-list] end 1",
            "[sert-file] client|Addons|1", "[sert-file] blocks|Chat|1",
            "[sert-list] Addons|client test", "[sert-list] Chat|blocks test", "[sert-list] end 2",
        ]))
        self.assertEqual(shared.catalogue, [
            {"file": "Addons", "name": "server test", "side": "server"},
            {"file": "Addons", "name": "client test", "side": "client"},
            {"file": "Chat", "name": "blocks test", "side": "blocks"},
        ])

    def test_verdict_frames_phases_and_outcomes(self):
        verdict = {"runId": "r", "passed": False, "failed": 1, "counts": {"passed": 2, "failed": 1, "skipped": 0, "total": 3},
                   "seeds": {"p": 9}, "seed": 4, "reason": None}
        parsed = markers.parse("\n".join([
            '[sert-done] {"passed": 2, "failed": 0, "total": 2}', test_line("p", "fail"),
            "[sert-verdict] " + json.dumps(verdict), '[sert-verdict] {"ok": true, "value": ' + json.dumps(verdict) + "}",
        ]))
        self.assertEqual((parsed.verdict["runId"], parsed.seeds, parsed.tests[0]["seed"], parsed.run_seed), ("r", {"p": 9}, 9, 4))
        self.assertEqual((parsed.results["passed"], parsed.results["failed"], parsed.results["total"]), (2, 1, 3))
        self.assertEqual(markers.parse('[sert-verdict] {"ok": true, "value": ' + json.dumps(verdict) + "}").verdict["runId"], "r")
        died = markers.parse('[sert-verdict] {"ok": false, "error": "test session ended without an EndTest result"}')
        self.assertEqual((died.verdict, died.results), (None, None))

        frames = markers.parse("[sert-frame] warm 16\n[sert-frame] run 8.5\n")
        self.assertEqual((frames.frames, frames.frame), ({"warm": 16, "run": 8.5}, 8.5))

        seen = []
        ph = markers.parse("\n".join([
            "[sert-phase] server named 1000", "[sert-phase] server named 2000", "[sert-frame] 16 ms",
            '[sert-done] {"passed": 3, "failed": 0, "skipped": 1, "total": 4}', '[sert-done] {"ok": true, "value": 1}',
            '[sert-x:device] {"mode": "phone"}', "[sert-x:wait] 300 test|what",
        ]), on_marker=lambda tag, payload: seen.append((tag, payload)))
        self.assertEqual((ph.phases, ph.frame, ph.results["total"]), ({"server.named": 1000}, 16, 4))
        self.assertEqual(seen, [("device", '{"mode": "phone"}'), ("wait", "300 test|what")])

        outcomes = markers.parse("\n".join([
            "[sert-list] end 3", '[sert-done] {"passed": 0, "failed": 0, "total": 3}',
            '[sert-done] {"passed": 3, "failed": 0, "total": 3}', "[sert-done] {bad",
            '[sert-verdict] {"passed": true, "failed": 0, "counts": {"passed": 3, "failed": 0}}',
        ]))
        self.assertEqual((len(outcomes.done), [o.get("passed") for o in outcomes.outcomes]), (3, [3, True]))


class FailureTest(unittest.TestCase):
    def test_reasons_verdicts_sharing_and_edges(self):
        from sert import cloud
        f = markers.failure
        for val, want in (
            (False, "false"), ({"ok": False}, "ok=false"), ({"success": False}, "success=false"),
            ({"failed": 2}, "failed=2"), ({"passed": 0, "failed": 0}, "no tests executed"),
            ({"passed": 1.5, "failed": 0}, "invalid test counts"), ({"passed": True, "failed": 0}, "invalid test counts"),
            ({"ok": True, "value": {"value": {"passed": False}}}, "passed=false"),
            ({"ok": True, "value": {"passed": 3, "failed": 0}}, None), ({"passed": True}, None), ("anything", None), (None, None),
        ):
            self.assertEqual(f(val), want)

        ok = {"passed": True, "failed": 0, "counts": {"passed": 3, "failed": 0, "skipped": 0, "total": 3}}
        none_ran = {"passed": True, "failed": 0, "counts": {"passed": 0, "failed": 0, "skipped": 2, "total": 2}}
        self.assertEqual((f(ok), f({"ok": True, "value": ok}), f(none_ran)), (None, None, "no tests executed"))
        self.assertIsNone(f({**none_ran, "listed": True, "reason": "listed 2"}))
        self.assertEqual(f({"passed": False, "failed": 0, "counts": {}}), "passed=false")

        self.assertIs(runscript.reports_failure, markers.reports_failure)
        self.assertFalse(hasattr(cloud, "result_failure"))
        value = {"passed": 1, "failed": 1}
        self.assertTrue(runscript.reports_failure(value))
        self.assertEqual(cloud.classify({"state": "COMPLETE", "output": {"results": [value]}}, [])[0], 1)

        deep = {"passed": False}
        for _ in range(80):
            deep = {"value": deep}
        self.assertEqual(f(deep), "result nested too deeply")

        bad = markers.parse("[sert-test] {not json\n[sert-done] nope\n")
        self.assertEqual((bad.tests, bad.done, bad.results), ([], [None], None))


class SelectionAndFlakeTest(unittest.TestCase):
    def names(self, picked):
        return [t["name"] for t in CATALOGUE if picked.matches(t)]

    def test_selection_matching_and_resolution(self):
        self.assertEqual(len(self.names(selection())), 5)
        self.assertEqual(self.names(selection(filters=["HOVER", "submenu"])), ["button · hover", "menu · opens submenu"])
        self.assertEqual(self.names(selection(filter="BUTTON")), ["button · clicks", "button · hover"])
        picked = selection(filter="Button", failed={"button · clicks", "BUTTON · gone", "menu · opens submenu"})
        picked.resolve(CATALOGUE)
        self.assertEqual(picked.names, {"button · clicks", "BUTTON · gone"})
        self.assertEqual(self.names(selection(filters=["hover"], patterns=[re.compile("^menu", re.I)])), ["button · hover", "menu · opens submenu"])
        self.assertEqual(self.names(selection(files=["Button.spec.luau"], filters=["clicks", "submenu"])), ["button · clicks"])
        self.assertEqual(self.names(selection(files=["client/Users"])), ["client · users list"])
        self.assertEqual(self.names(selection(files=["Users"])), ["client · users list", "server · users load"])
        self.assertEqual(self.names(selection(sides=["server"])), ["server · users load"])
        self.assertEqual(self.names(selection(excludes=["button"])), ["menu · opens submenu", "client · users list", "server · users load"])

        p_grep = selection(filters=["hover"], patterns=[re.compile("submenu")])
        self.assertTrue(p_grep.needs_catalogue)
        p_grep.resolve(CATALOGUE)
        req = p_grep.request()
        self.assertEqual((req["names"], "filters" in req), (["button · hover", "menu · opens submenu"], False))

        p_filt = selection(filters=["hover"], files=["Button.spec"], sides=["client"])
        self.assertFalse(p_filt.needs_catalogue)
        p_filt.resolve(None)
        self.assertEqual(p_filt.request(), {"filter": "", "filters": ["hover"], "files": ["Button"], "sides": ["client"]})

        p_ex = selection(excludes=["USERS"])
        self.assertTrue(p_ex.needs_catalogue)
        p_ex.resolve(CATALOGUE)
        self.assertEqual((p_ex.request()["excludes"], "names" in p_ex.request()), (["client · users list", "server · users load"], False))

        p_fail = selection(failed={"gone · test"})
        p_fail.resolve(None)
        self.assertEqual(p_fail.request()["names"], ["gone · test"])
        p_fail2 = selection(failed={"gone · test", "button · hover"}, files=["Button"])
        p_fail2.resolve(CATALOGUE)
        self.assertEqual(sorted(p_fail2.names), ["button · hover", "gone · test"])

        for kwargs, want in (
            ({"failed": {"button · clicks", "button · hover"}, "filter": "hover"}, {"button · hover"}),
            ({"failed": {"menu · opens submenu", "button · hover"}, "files": ["Button"]}, {"button · hover"}),
            ({"failed": {"gone · clicks", "gone · hover"}, "filter": "hover"}, {"gone · hover"}),
        ):
            s = selection(**kwargs)
            if "filter" in kwargs:
                self.assertTrue(s.needs_catalogue)
            s.resolve(CATALOGUE)
            self.assertEqual(s.names, want)

    def test_failed_flake_merge_relaunch_and_edit_driver(self):
        record = {
            "tests": [
                {"name": "client · a", "file": "client/A", "status": "fail", "seed": 11},
                {"name": "server · b", "file": "server/B", "status": "fail"},
                {"name": "client · c", "file": "client/C", "status": "pass"},
                {"name": "client · no script errors", "status": "fail"},
                {"name": "client · page perf", "file": "client/P", "status": "fail"},
                {"name": "client · reports", "file": "", "status": "fail", "runner": True},
                {"name": "server · Users.spec loads", "file": "", "status": "fail", "runner": True},
            ],
            "seeds": {"server · b": 22, "client · c": 33},
        }
        failed, run_level = driver.failed_tests(record, re.compile(suites.RUN_LEVEL_DEFAULT))
        self.assertEqual([t["name"] for t in failed], ["client · a", "server · b", "client · page perf"])
        self.assertEqual(run_level, ["client · no script errors", "client · reports", "server · Users.spec loads"])
        kept, left = driver.narrow_failed(failed, selection(sides=["client"], excludes=["perf"]), {})
        self.assertEqual((kept, len(left)), ({"client · a"}, 2))
        kept_all, _ = driver.narrow_failed(failed, selection(), {})
        self.assertEqual(driver.replay_seeds(failed, kept_all, record), {"client · a": 11, "server · b": 22})
        self.assertEqual(driver.narrow_failed(failed, selection(files=["B"]), {})[0], {"server · b"})

        found = flake.flakes([
            [{"name": "a", "file": "A", "status": "pass"}, {"name": "b", "file": "B", "status": "fail"}, {"name": "c", "file": "C", "status": "fail"}],
            [{"name": "a", "file": "A", "status": "fail"}, {"name": "b", "file": "B", "status": "fail"}, {"name": "c", "file": "C", "status": "pass"}],
            [{"name": "a", "file": "A", "status": "pass"}, {"name": "b", "file": "B", "status": "fail"}],
        ])
        self.assertEqual((found["iterations"], [(e["name"], e["failed"], e["ran"]) for e in found["flaky"]], [e["name"] for e in found["failedEvery"]]),
                         (3, [("a", 1, 3), ("c", 1, 2)], ["b"]))

        previous = [{"name": "a", "status": "fail"}, {"name": "b", "status": "fail"}, {"name": "gone", "status": "fail"},
                    {"name": "c", "status": "pass"}, {"name": "client · no script errors", "status": "fail"}]
        merged, carried = flake.merge_results(previous, [{"name": "a", "status": "pass"}, {"name": "b", "status": "skip"}],
                                              {"a", "b", "c"}, re.compile(suites.RUN_LEVEL_DEFAULT))
        by = {t["name"]: t for t in merged}
        self.assertEqual((by["a"]["status"], by["b"]["status"], by["b"]["earlier"], "gone" in by, by["c"]["earlier"],
                          "client · no script errors" in by, carried), ("pass", "fail", True, False, True, True, 2))

        died = {"result": {"ok": False, "error": driver.SESSION_DIED}, "output": "x"}
        self.assertTrue(driver.should_relaunch(1, died, markers.parse("")))
        self.assertTrue(driver.should_relaunch(2, {"result": None, "output": "boot\n", "message": "Studio quit without printing a result line"}, markers.parse("")))
        for code, rep, text in (
            (3, died, ""), (130, died, ""), (1, died, '[sert-done] {"passed": 1, "failed": 1, "total": 2}'),
            (2, {"result": None, "output": "", "message": "could not start"}, ""),
            (2, {"result": None, "output": "x", "message": "the result line is not JSON"}, ""),
            (1, {"result": {"ok": False, "error": "a test failed"}, "output": "x"}, ""),
        ):
            self.assertFalse(driver.should_relaunch(code, rep, markers.parse(text)))

        with tempfile.TemporaryDirectory() as root:
            settings = suites.Settings(root, {"studio": {"config": "ReplicatedStorage/Flux.unit/Config"}})
            source = driver.edit_driver(settings, {"filter": "", "names": ['a "quoted" · name'], "repeat": 2})
            for needle in ('local SENTINEL = "[sert-verdict]"', '[\\"ReplicatedStorage\\", \\"sert\\", \\"roblox\\", \\"Runner\\"]',
                           '[\\"ReplicatedStorage\\", \\"Flux.unit\\", \\"Config\\"]', "Runner.edit(require(find(CONFIG_PATH))", '\\"repeat\\": 2'):
                self.assertIn(needle, source)
            self.assertNotIn("{{", source)
            with self.assertRaisesRegex(SertError, r"\[studio\]\.config"):
                driver.edit_driver(suites.Settings(root, {"studio": {}}), {})


class FakeStudio:
    def __init__(self, respond):
        self.respond = respond
        self.requests, self.calls = [], []

    def __call__(self, place, *, mode, report, script=None, args=None, prelude=None, timeout, keep, launcher):
        self.calls.append({"place": place, "mode": mode, "prelude": prelude, "timeout": timeout, "keep": keep, "launcher": launcher})
        request = {"edit": True, "source": script} if mode == "edit" else json.loads(json.dumps(args))
        self.requests.append(request)
        code, output, result = self.respond(len(self.requests), request)
        with open(report, "w", encoding="utf-8") as handle:
            json.dump({"exitCode": code, "result": result, "output": output, "seconds": 1.0, "message": "fake"}, handle)
        return code


class EndToEndTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = self.tmp.name
        os.makedirs(os.path.join(self.root, "test", "unit"))
        for name in ("Button", "Menu"):
            with open(os.path.join(self.root, "test", "unit", f"{name}.spec.luau"), "w") as handle:
                handle.write(f"-- {name}\n")
        self.conf = {"studio": {"mode": "play", "specs": ["test/unit/*.spec.luau"], "out": "out"}}

    def tearDown(self):
        self.tmp.cleanup()

    def run_driver(self, fake, argv, hooks=None, conf=None, json_out=False):
        settings = suites.Settings(self.root, conf or self.conf)
        hooks = hooks or driver.Hooks()
        opts = driver.build_parser(settings, hooks).parse_args(argv)
        out = io.StringIO()
        with mock.patch.object(runscript, "run", fake), \
                mock.patch.object(driver, "build_place", lambda root, project, place, quiet=False: 0.5), \
                contextlib.redirect_stdout(out), contextlib.redirect_stderr(io.StringIO()):
            if json_out:
                opts.json_records = []
                code = driver.write_json_out(opts, driver.guarded(settings, hooks, opts))
            else:
                code = driver.guarded(settings, hooks, opts)
        return code, out.getvalue(), settings

    def last(self, settings):
        return suites.load_json(settings.last_path)

    def test_json_out(self):
        def respond(n, request):
            lines = [test_line("button · clicks", "pass", file="Button"), test_line("button · hover", "fail", file="Button", error="nope"),
                     '[sert-done] {"passed": 1, "failed": 1, "skipped": 0, "total": 2}']
            return 1, "\n".join(lines), {"ok": True, "value": {"passed": 1, "failed": 1}}

        report = os.path.join(self.root, "build", "verdicts.json")
        code, _, _ = self.run_driver(FakeStudio(respond), ["--json-out", report], json_out=True)
        self.assertEqual(code, 1)
        written = json.loads(pathlib.Path(report).read_text(encoding="utf-8"))
        self.assertEqual((set(written), written["exitCode"]), ({"exitCode", "tasks"}, 1))
        (task,) = written["tasks"]
        self.assertTrue({"label", "exit", "verdict", "seconds"} <= set(task))
        self.assertEqual((task["label"], task["mode"], task["exit"]), ("play", "play", 1))
        self.assertEqual(task["counts"], {"passed": 1, "failed": 1, "skipped": 0, "todo": 0, "total": 2})
        self.assertEqual(task["failures"], [{"name": "button · hover", "file": "Button", "message": "nope"}])

        blocker = os.path.join(self.root, "file")
        pathlib.Path(blocker).write_text("x")
        ok_resp = lambda n, r: (0, "\n".join([test_line("button · clicks", "pass", file="Button"), '[sert-done] {"passed": 1, "failed": 0, "total": 1}']), {"ok": True, "value": {"passed": 1, "failed": 0}})
        self.assertEqual(self.run_driver(FakeStudio(ok_resp), ["--json-out", os.path.join(blocker, "v.json")], json_out=True)[0], 2)

    def test_run_failed_replay_catalogue_and_stale(self):
        def first(n, request):
            lines = listing(CATALOGUE[:3]) + [
                "[sert-seed] run 5", test_line("button · clicks", "pass", file="?"), test_line("button · hover", "fail", file="?", error="nope"),
                test_line("menu · opens submenu", "pass", file="?"), "[sert-seed] button · hover|777",
                '[sert-done] {"passed": 2, "failed": 1, "skipped": 0, "total": 3}',
            ]
            return 1, "\n".join(lines), {"ok": True, "value": {"passed": 2, "failed": 1}}

        code, out, settings = self.run_driver(FakeStudio(first), [])
        self.assertEqual(code, 1)
        record = self.last(settings)["modes"]["play"]
        self.assertEqual((record["seed"], record["seeds"]), (5, {"button · hover": 777}))
        self.assertEqual([(t["name"], t["file"], t["seed"]) for t in record["tests"] if t["status"] == "fail"], [("button · hover", "Button", 777)])
        self.assertTrue(os.path.isfile(settings.catalogue_path))
        self.assertIn("FAIL Button: button · hover (seed 777)", out)

        def replay(n, request):
            self.assertEqual((request["names"], request["seeds"]), (["button · hover"], {"button · hover": 777}))
            return 0, "\n".join([test_line("button · hover", "pass"), '[sert-done] {"passed": 1, "failed": 0, "total": 1}']), {"ok": True, "value": {"passed": 1, "failed": 0}}

        code, out, _ = self.run_driver(FakeStudio(replay), ["--failed"])
        self.assertEqual(code, 0, out)
        self.assertIn("replaying button · hover with seed 777", out)
        record = self.last(settings)["modes"]["play"]
        self.assertEqual((record["seeds"], any(t["status"] == "fail" for t in record["tests"])), ({}, False))
        code, out, _ = self.run_driver(FakeStudio(replay), ["--failed"])
        self.assertEqual((code, "no failed tests" in out), (0, True))

        driver.store_catalogue(settings, CATALOGUE)
        fake = FakeStudio(lambda n, r: (0, "\n".join([test_line("menu · opens submenu", "pass"), '[sert-done] {"passed":1,"failed":0,"total":1}']), {"ok": True, "value": {}}))
        code, out, _ = self.run_driver(fake, ["--grep", "submenu$"])
        self.assertEqual((code, fake.requests[0]["names"]), (0, ["menu · opens submenu"]))
        code, out, _ = self.run_driver(FakeStudio(None), ["--list", "--file", "Button"])
        self.assertEqual((code, "2 test(s) match" in out), (0, True))

        suites.save_json(settings.catalogue_path, {"digest": "old", "tests": []})
        fake_stale = FakeStudio(lambda n, r: (0, "\n".join(listing()), {"ok": True, "value": {}}) if r.get("list") else (_ for _ in ()).throw(AssertionError()))
        code, out, _ = self.run_driver(fake_stale, ["--list", "--grep", "users"])
        self.assertEqual((code, fake_stale.requests[0]["list"], "2 test(s) match" in out), (0, True, True))

    def test_relaunch_repeat_nothing_ran_and_two_modes(self):
        fake = FakeStudio(lambda n, r: (1, "booting\n", {"ok": False, "error": driver.SESSION_DIED}) if n < 3 else (0, "\n".join([test_line("a", "pass"), '[sert-done] {"passed":1,"failed":0,"total":1}']), {"ok": True, "value": {}}))
        code, out, _ = self.run_driver(fake, [])
        self.assertEqual((code, len(fake.requests), out.count("launching again")), (0, 3, 2))

        fake_dead = FakeStudio(lambda n, r: (1, "x\n", {"ok": False, "error": driver.SESSION_DIED}))
        code, _, _ = self.run_driver(fake_dead, [])
        self.assertEqual((code, len(fake_dead.requests)), (2, driver.ATTEMPTS))

        def repeat_resp(n, request):
            self.assertEqual(request["repeat"], 2)
            delta = '{"passed":0,"failed":1,"skipped":0,"total":1}'
            lines = ["[sert-iter] server 1 begin", test_line("a", "pass"), test_line("b", "fail"), f"[sert-iter] server 1 end {delta}",
                     "[sert-iter] server 2 begin", test_line("a", "fail"), test_line("b", "fail"), f"[sert-iter] server 2 end {delta}",
                     '[sert-verdict] {"passed":false,"failed":3,"counts":{"passed":1,"failed":3,"skipped":0,"total":4},"iterations":2}']
            return 1, "\n".join(lines), {"ok": True, "value": {}}

        code, _, settings = self.run_driver(FakeStudio(repeat_resp), ["--repeat", "2"])
        fl = suites.load_json(settings.flake_path)
        self.assertEqual((code, fl["repeat"], [e["name"] for e in fl["modes"]["play"]["flaky"]], [e["name"] for e in fl["modes"]["play"]["failedEvery"]]),
                         (1, 2, ["a"], ["b"]))

        code, out, _ = self.run_driver(FakeStudio(lambda n, r: (0, '[sert-done] {"passed":0,"failed":0,"skipped":2,"total":2}', {"ok": True, "value": {}})), ["--filter", "zzz"])
        self.assertEqual((code, "no test ran" in out), (1, True))

        conf = {"studio": {"mode": ["edit", "run"], "config": "ReplicatedStorage/X/Config", "out": "out2", "specs": ["test/unit/*.spec.luau"]}}
        fake_two = FakeStudio(lambda n, r: (0, "\n".join([test_line("a", "pass"), '[sert-done] {"passed":1,"failed":0,"total":1}']), {"ok": True, "value": {}}))
        code, out, settings = self.run_driver(fake_two, ["--seed", "12", "--runs", "3"], conf=conf)
        self.assertEqual(code, 0, out)
        self.assertTrue(fake_two.requests[0]["edit"] and '\\"seed\\": 12' in fake_two.requests[0]["source"])
        self.assertEqual((fake_two.requests[1]["mode"], fake_two.requests[1]["seed"], fake_two.requests[1]["runs"], fake_two.calls[1]["mode"]), ("run", 12, 3, "run"))
        self.assertEqual(sorted(self.last(settings)["modes"]), ["edit", "run"])

    def test_hooks_sides_and_passes(self):
        seen = {}

        class Module:
            @staticmethod
            def add_arguments(parser):
                parser.add_argument("--profile", type=int)
            @staticmethod
            def request(args, req):
                req["profile"] = args.profile
            @staticmethod
            def prelude(args, mode):
                return "workspace.StreamingEnabled = true"
            @staticmethod
            def on_marker(tag, payload, state):
                seen.setdefault(tag, []).append(payload)
            @staticmethod
            def report(state):
                seen["exit"] = state["exit"]
                return 1 if state["x"].get("audit") else None

        fake = FakeStudio(lambda n, r: (0, "\n".join([test_line("a", "pass"), "[sert-x:audit] scene|cut|text", '[sert-done] {"passed":1,"failed":0,"total":1}']), {"ok": True, "value": {}}))
        code, _, _ = self.run_driver(fake, ["--profile", "250"], hooks=driver.Hooks(Module))
        self.assertEqual((fake.requests[0]["profile"], fake.calls[0]["prelude"], seen["audit"], seen["exit"], code),
                         (250, "workspace.StreamingEnabled = true", ["scene|cut|text"], 0, 1))

        class Refusal:
            @staticmethod
            def request(args, req):
                raise SystemExit("error: that selection runs only in a pass of its own")
        self.assertEqual(self.run_driver(FakeStudio(None), [], hooks=driver.Hooks(Refusal))[0], 2)
        self.assertEqual(self.run_driver(FakeStudio(None), ["--file", "Nope"])[0], 2)

        conf = {"studio": {**self.conf["studio"], "sides": ["client", "server"]}}
        settings = suites.Settings(self.root, conf)
        driver.store_catalogue(settings, CATALOGUE)
        suites.save_json(settings.last_path, {"modes": {"play": {"mode": "play", "runId": "r0", "exit": 1, "summary": "FAILED", "tests": [
            {"name": "client · users list", "file": "client/Users", "status": "fail"},
            {"name": "server · users load", "file": "server/Users", "status": "fail"},
        ]}}})
        fake_srv = FakeStudio(lambda n, r: (0, "\n".join(listing([CATALOGUE[4]]) + [test_line("server · users load", "pass"), '[sert-done] {"passed": 1, "failed": 0, "skipped": 0, "total": 1}']), {"ok": True, "value": {"passed": 1, "failed": 0}}))
        code, out, settings = self.run_driver(fake_srv, ["--side", "server"], conf=conf)
        self.assertEqual((code, fake_srv.requests[0].get("sides"), len(suites.load_json(settings.catalogue_path)["tests"])), (0, ["server"], len(CATALOGUE)))
        merged = {t["name"]: t for t in self.last(settings)["modes"]["play"]["tests"]}
        self.assertEqual((merged["server · users load"]["status"], merged["client · users list"]["status"]), ("pass", "fail"))

        os.remove(settings.catalogue_path)
        code, _, s_broken = self.run_driver(FakeStudio(lambda n, r: (1, "\n".join(listing(CATALOGUE[:2]) + ['[sert-verdict] {"passed": false, "failed": 1, "counts": {"passed": 0, "failed": 1, "skipped": 0, "total": 1}}']), {"ok": False, "error": "list crashed"})), ["--grep", "clicks"])
        self.assertEqual((code, os.path.isfile(s_broken.catalogue_path)), (2, False))

        s_miss = suites.Settings(self.root, self.conf)
        if os.path.exists(s_miss.catalogue_path):
            os.remove(s_miss.catalogue_path)
        suites.save_json(s_miss.last_path, {"modes": {"play": {"mode": "play", "runId": "r0", "exit": 1, "summary": "FAILED", "tests": [
            {"name": "button · hover", "file": "?", "status": "fail"},
            {"name": "menu · opens submenu", "file": "?", "status": "fail"},
        ]}}})
        fake_ref = FakeStudio(lambda n, r: (0, "\n".join(listing(CATALOGUE[:3])), {"ok": True, "value": {}}) if r.get("list") else (0, "\n".join([test_line("button · hover", "pass"), '[sert-done] {"passed": 1, "failed": 0, "total": 1}']), {"ok": True, "value": {"passed": 1, "failed": 0}}))
        code, _, _ = self.run_driver(fake_ref, ["--failed", "--file", "Button"])
        self.assertEqual((code, len(fake_ref.requests), fake_ref.requests[0].get("list"), fake_ref.requests[1].get("names")), (0, 2, True, ["button · hover"]))

        conf_er = {"studio": {"mode": ["edit", "run"], "config": "ReplicatedStorage/X/Config", "out": "out", "specs": ["test/unit/*.spec.luau"]}}
        fake_int = FakeStudio(lambda n, r: (util.INTERRUPTED, "", None))
        self.assertEqual((self.run_driver(fake_int, [], conf=conf_er)[0], len(fake_int.requests)), (util.INTERRUPTED, 1))

        calls = []
        class PassHooks:
            @staticmethod
            def passes(args):
                return None if getattr(args, "mode", None) else [["--mode", "play"], ["--mode", "run"]]
        with mock.patch.object(driver, "run", side_effect=lambda argv, records=None: (calls.append(argv), 130)[1]):
            self.assertEqual(self.run_driver(FakeStudio(None), [], hooks=driver.Hooks(PassHooks))[0], util.INTERRUPTED)
        self.assertEqual(calls, [["--root", self.root, "--mode", "play"]])

        class BadPassHooks:
            @staticmethod
            def passes(args):
                return [{"mode": "play"}]
        self.assertEqual(self.run_driver(FakeStudio(None), [], hooks=driver.Hooks(BadPassHooks))[0], 2)

        with self.assertRaisesRegex(SertError, r"invalid \[studio\]\.run_level regex"):
            suites.Settings(self.root, {"studio": {"run_level": "[unclosed"}})

        respond = FakeStudio(lambda n, r: (0, "\n".join([test_line("button · clicks", "pass", file="Button"), '[sert-done] {"passed": 1, "failed": 0, "total": 1}']), {"ok": True, "value": {"passed": 1, "failed": 0}}))
        report = os.path.join(self.root, "verdicts.json")
        with mock.patch.object(driver, "context", lambda argv: (suites.Settings(self.root, self.conf), driver.Hooks(PassHooks), None)):
            code, out, _ = self.run_driver(respond, ["--json-out", report], hooks=driver.Hooks(PassHooks), conf=self.conf, json_out=True)
        written = json.loads(pathlib.Path(report).read_text(encoding="utf-8"))
        self.assertEqual((code, [r.get("mode") for r in respond.requests], written["exitCode"], [t["label"] for t in written["tasks"]]),
                         (0, ["play", "run"], 0, ["play", "run"]))


SESSION = pathlib.Path(__file__).resolve().parents[2] / "src" / "roblox" / "Runner.luau"


def runner_keys() -> set[str]:
    block = re.search(r"session\.KEYS = table\.freeze\(\{(.*?)\}\)", SESSION.read_text(encoding="utf-8"), re.S)
    assert block is not None, "session.luau has no session.KEYS"
    return set(re.findall(r'"(\w+)"', block.group(1)))


class RequestKeysTest(unittest.TestCase):
    run_driver = EndToEndTest.run_driver
    tearDown = EndToEndTest.tearDown
    setUp = EndToEndTest.setUp

    @staticmethod
    def verdict(unknown, failed=0):
        return "[sert-verdict] " + json.dumps({"runId": "r", "name": "x", "mode": "play", "passed": failed == 0, "failed": failed,
                                               "counts": {"passed": 1 - failed, "failed": failed, "skipped": 0, "total": 1}, "unknown": unknown})

    def test_request_keys_forwarding_and_replay_commands(self):
        settings = suites.Settings(self.root, {**self.conf, "studio": {**self.conf["studio"], "sides": ["server"]}})
        every = ["--seed", "1", "--runs", "2", "--replay", "3", "--exhaustive", "--budget", "4", "--repeat", "2",
                 "--test-timeout", "5", "--deadline", "6", "--filter", "a", "--file", "Button", "--side", "server", "--exclude", "zzz"]
        opts = driver.build_parser(settings, driver.Hooks()).parse_args(every + ["needle"])
        picked = selection(filter="needle", filters=["a"], files=["Button"], sides=["server"], excludes=["zzz"], names=["n"], seeds={"n": 7})
        request = driver.build_request(settings, opts, "play", picked, "run-1")
        self.assertTrue({"replay", "exhaustive", "budget", "command", "seed", "runs", "repeat", "timeout", "deadline"} <= set(request))
        self.assertEqual((sorted(set(request) - runner_keys()), request["replay"], request["exhaustive"], request["budget"]), ([], 3, True, 4.0))
        self.assertTrue({"replay", "exhaustive", "budget", "command", "seed", "runs", "seeds"} <= runner_keys())

        call = re.search(r"results, problem = invoke\(sert, \{(.*?)\n\t+\}\)", SESSION.read_text(encoding="utf-8"), re.S)
        self.assertIsNotNone(call)
        options = set(re.findall(r"^\s*(\w+) = request\.\1,", call.group(1), re.M))
        run_options = (SESSION.parents[1] / "prop.luau").read_text(encoding="utf-8")
        for key in ("replay", "exhaustive", "budget", "command", "seed", "runs", "seeds", "timeout"):
            self.assertIn(key, options)
            self.assertRegex(run_options, rf"\n\t{key}: ")

        respond = lambda n, r: (0, "\n".join([test_line("a", "pass"), self.verdict([])]), {"ok": True, "value": {}})
        fake = FakeStudio(respond)
        self.assertEqual(self.run_driver(fake, ["queue · pops", "--replay=3714881375"])[0], 0)
        self.assertEqual((fake.requests[0]["filter"], fake.requests[0]["replay"], "exhaustive" in fake.requests[0]), ("queue · pops", 3714881375, False))
        fake2 = FakeStudio(respond)
        self.assertEqual(self.run_driver(fake2, ["--exhaustive", "--budget", "90"])[0], 0)
        self.assertEqual((fake2.requests[0]["exhaustive"], fake2.requests[0]["budget"]), (True, 90.0))

        fake3 = FakeStudio(respond)
        self.run_driver(fake3, [])
        self.assertEqual(fake3.requests[0]["command"], "sert studio --mode play")
        os.makedirs(os.path.join(self.root, "tools"))
        pathlib.Path(self.root, "tools", "sert.py").write_text("# stub\n", encoding="utf-8")
        fake4 = FakeStudio(respond)
        self.run_driver(fake4, ["--mode", "run"])
        self.assertEqual(fake4.requests[0]["command"], "python3 tools/sert.py studio --mode run")
        suite = suites.Settings(self.root, {"studio": {"suites": {"ui": {"mode": "play"}}}}, "ui")
        self.assertEqual(driver.replay_command(suite, "play"), "python3 tools/sert.py studio --mode play --suite ui")

        s_rep = suites.Settings(self.root, self.conf)
        parser = driver.build_parser(s_rep, driver.Hooks())
        for line, replay, exhaustive in (
            (driver.replay_command(s_rep, "play") + ' --filter "queue · pops" --replay=3714881375', 3714881375, False),
            (driver.replay_command(s_rep, "run") + ' --filter "queue · pops" --exhaustive', None, True),
        ):
            argv = shlex.split(line)
            self.assertEqual(argv[:3], ["python3", "tools/sert.py", "studio"])
            p_opts = parser.parse_args(argv[3:])
            self.assertEqual((p_opts.filters, p_opts.replay, p_opts.exhaustive), (["queue · pops"], replay, exhaustive))

        fake_ig = FakeStudio(lambda n, r: (0, "\n".join([test_line("a", "pass"), self.verdict(["replay", "target"])]), {"ok": True, "value": {}}))
        with contextlib.redirect_stderr(io.StringIO()):
            self.assertEqual(self.run_driver(fake_ig, ["--replay", "5"])[0], 2)

        class HookMod:
            @staticmethod
            def request(args, req):
                req["target"] = "x"
        fake_hk = FakeStudio(lambda n, r: (0, "\n".join([test_line("a", "pass"), self.verdict(["target"])]), {"ok": True, "value": {}}))
        self.assertEqual(self.run_driver(fake_hk, ["--replay", "5"], hooks=driver.Hooks(HookMod))[0], 0)
        self.assertEqual(driver.ignored_keys(markers.parse(self.verdict(["replay", "target"])), {"replay", "seed"}), ["replay"])
        self.assertEqual(driver.ignored_keys(markers.parse(test_line("a", "pass")), {"replay"}), [])


class SuitesTest(unittest.TestCase):
    run_driver = EndToEndTest.run_driver
    tearDown = EndToEndTest.tearDown

    def setUp(self):
        EndToEndTest.setUp(self)
        os.makedirs(os.path.join(self.root, "ui", "test", "unit"))
        with open(os.path.join(self.root, "ui", "test", "unit", "Slider.spec.luau"), "w") as handle:
            handle.write("-- Slider\n")
        self.conf = {"studio": {"out": "out", "config": "ReplicatedStorage/Tests/Config", "suites": {
            "core": {"mode": "edit", "project": "test/default.project.json", "specs": ["test/unit/*.spec.luau"]},
            "ui": {"mode": ["play", "run"], "project": "ui/test/default.project.json", "specs": ["ui/test/unit/*.spec.luau"], "sides": ["client"]},
        }}}

    @staticmethod
    def respond(n, request):
        return 0, "\n".join([test_line("a", "pass"), '[sert-done] {"passed":1,"failed":0,"total":1}']), {"ok": True, "value": {}}

    def test_suites_execution_and_filtering(self):
        base = suites.Settings(self.root, self.conf)
        self.assertEqual((base.pending_suites, base.suites, suites.known_sides(base)), (True, ["core", "ui"], ["client"]))
        ui = suites.Settings(self.root, self.conf, "ui")
        self.assertEqual((ui.pending_suites, ui.modes, ui.out, ui.project, ui.config_path),
                         (False, ["play", "run"], os.path.join(self.root, "out", "ui"),
                          os.path.join(self.root, "ui/test/default.project.json"), ["ReplicatedStorage", "Tests", "Config"]))
        with self.assertRaises(SertError):
            suites.Settings(self.root, self.conf, "nope")

        fake = FakeStudio(self.respond)
        code, out, _ = self.run_driver(fake, [])
        self.assertEqual((code, [r.get("mode", "edit") if not r.get("edit") else "edit" for r in fake.requests]), (0, ["edit", "play", "run"]))
        self.assertTrue("== suite core" in out and "== suite ui" in out and os.path.isfile(os.path.join(self.root, "out", "core", "last.json")))
        self.assertEqual(sorted(suites.load_json(os.path.join(self.root, "out", "ui", "last.json"))["modes"]), ["play", "run"])

        fake_pick = FakeStudio(self.respond)
        code, out, _ = self.run_driver(fake_pick, ["--suite", "ui", "--mode", "run"])
        self.assertEqual((code, [r["mode"] for r in fake_pick.requests], "== suite core" in out), (0, ["run"], False))

        fake_file = FakeStudio(self.respond)
        code, out, _ = self.run_driver(fake_file, ["--file", "Slider"])
        self.assertEqual((code, "== suite core: no spec named Slider; skipped" in out, [r["files"] for r in fake_file.requests]),
                         (0, True, [["Slider"], ["Slider"]]))

        self.assertEqual(self.run_driver(FakeStudio(self.respond), ["--file", "Typo"])[0], 2)
        self.assertEqual(self.run_driver(FakeStudio(None), ["--suite", "ui"], conf={"studio": {"specs": ["test/unit/*.spec.luau"], "out": "out"}})[0], 2)

        fake_int = FakeStudio(lambda n, r: (util.INTERRUPTED, "", None))
        code, out, _ = self.run_driver(fake_int, [])
        self.assertEqual((code, len(fake_int.requests), "== suite core" in out, "== suite ui" in out), (util.INTERRUPTED, 1, True, False))


HOOKS_SAMPLE = '''"""Example `sert studio` hooks."""
from __future__ import annotations
STREAMING_PRELUDE = "workspace.StreamingEnabled = true\\n"
def add_arguments(parser) -> None:
    parser.add_argument("--streaming", action="store_true")
def request(args, req):
    if args.streaming: req["streaming"] = True
    return req
def prelude(args, mode):
    return STREAMING_PRELUDE if args.streaming else None
def report(state):
    for payload in state["x"].get("perf", []): print(f"[perf] {payload}")
    return None
'''


class DriftWorstAndHooksTest(unittest.TestCase):
    def test_drift_worst_launch_and_edges(self):
        self.assertEqual([util.worst(x) for x in ([0, 1, 3], [1, 2], [0, 0], [])], [3, 2, 0, 0])
        with tempfile.TemporaryDirectory() as root:
            os.makedirs(os.path.join(root, "test", "runner"))
            for name in ("Listed.luau", "Missing.luau", "boot.server.luau", "init.luau"):
                open(os.path.join(root, "test", "runner", name), "w").close()
            with open(os.path.join(root, "test", "default.project.json"), "w") as handle:
                json.dump({"tree": {"ReplicatedStorage": {"KATest": {"runner": {"Listed": {}}}}}}, handle)
            problems = driver.drift(suites.Settings(root, {"studio": {"drift": [{"dir": "test/runner", "tree": ["ReplicatedStorage", "KATest", "runner"]}]}}))
            self.assertEqual(len(problems), 1)
            self.assertIn("Missing.luau", problems[0])

            settings = suites.Settings(root, {"studio": {"config": "ReplicatedStorage/Tests/Config"}})
            opts = driver.build_parser(settings, driver.Hooks()).parse_args([])
            opts.timeout = 120.0
            with mock.patch.object(runscript, "run", return_value=0) as inner:
                attempt = driver.launch(settings, opts, driver.Hooks(), "edit", "place.rbxl", {"runId": "r"}, root, "edit")
            self.assertEqual(attempt.code, 0)
            kw = inner.call_args.kwargs
            self.assertEqual((inner.call_args.args, kw["mode"], kw["args"], kw["timeout"], kw["report"]),
                             (("place.rbxl",), "edit", None, 120.0, os.path.join(root, "edit.report.json")))
            self.assertIn("Runner.edit", kw["script"])
            with mock.patch.dict(os.environ, {"SERT_ROOT": root}):
                self.assertEqual(driver.prescan_root([]), str(pathlib.Path(root).resolve()))

            self.assertEqual(suites.instance_path(["ReplicatedStorage", "Flux"]), ["ReplicatedStorage", "Flux"])
            self.assertEqual((driver.side_of({"side": "client"}), driver.side_of({"name": "no separator"})), ("client", None))
            with self.assertRaises(SertError):
                suites.Settings(root, {"studio": {"suites": "not-a-dict"}})
            with self.assertRaises(SertError):
                driver.load_hooks(os.path.join(root, "missing_hooks.py"))
            hooks_file = os.path.join(root, "my_hooks.py")
            pathlib.Path(hooks_file).write_text("def check(args):\n    return ['hook problem']\n")
            loaded = driver.load_hooks(hooks_file)
            self.assertTrue(loaded.has("check"))

            sel = selection(filter="f", files=["A"], sides=["client"], filters=["x"], patterns=[re.compile("y")], failed={"z"}, excludes=["ex"], names={"n"})
            self.assertIn("excluding ex", sel.describe())
            empty_parsed = markers.parse("")
            self.assertEqual(driver.summarize(empty_parsed, {"result": {"value": {"summary": "custom"}}}), "no result")
            self.assertEqual(driver.summarize(empty_parsed, {"result": {"error": "err1"}}), "FAILED: err1")
            self.assertEqual(driver.summarize(empty_parsed, {"message": "msg1"}), "msg1")
            self.assertEqual(driver.executed(markers.parse(test_line("a", "pass"))), 1)
            no_errors = test_line("edit · no script errors", "pass", file="", runner=True)
            self.assertEqual(driver.executed(markers.parse(no_errors)), 0)
            verdict = {"passed": False, "failed": 0, "counts": {"passed": 1, "failed": 0, "skipped": 0, "total": 1}, "reason": "no test ran: nothing matched the selection"}
            self.assertEqual(driver.executed(markers.parse(no_errors + "\n[sert-verdict] " + json.dumps(verdict))), 0)

            rich_parsed = markers.parse("[sert-phase] server boot 1500\n[sert-frame] run 16\n" + test_line("a", "pass", file="Button", ms=25))
            plines = "\n".join(driver.phase_lines("play", 1.0, 0.4, 2.1, rich_parsed, rich_parsed.tests, 5))
            for want in ("phases: server.boot +0.5 s", "steady frame 16 ms", "slowest files: Button", "slowest tests:"):
                self.assertIn(want, plines)

            s_v = suites.Settings(root, {"studio": {"launcher": "custom-vinegar"}})
            opts_k = driver.build_parser(s_v, driver.Hooks()).parse_args(["--keep"])
            opts_k.timeout = 30.0
            class Prelude:
                @staticmethod
                def prelude(args, mode): return "workspace.Gravity = 0"
            with mock.patch.object(runscript, "run", return_value=3) as inner:
                self.assertEqual(driver.launch(s_v, opts_k, driver.Hooks(Prelude), "play", "p.rbxl", {"runId": "r"}, root, "play").code, 3)
            self.assertEqual(inner.call_args.kwargs, {"mode": "play", "report": os.path.join(root, "play.report.json"), "script": None,
                                                      "args": {"runId": "r"}, "prelude": "workspace.Gravity = 0", "timeout": 30.0, "keep": True, "launcher": "custom-vinegar"})

            err_buf = io.StringIO()
            with mock.patch.object(util, "need", return_value="rojo"), mock.patch.object(util.subprocess, "run", side_effect=OSError("no rojo")), contextlib.redirect_stderr(err_buf):
                self.assertIsNone(util.build_place(root, settings.project, "p.rbxl", quiet=True))
            self.assertIn("cannot run rojo", err_buf.getvalue())
            err_buf = io.StringIO()
            with mock.patch.object(util, "need", side_effect=SertError("rojo not found")), contextlib.redirect_stderr(err_buf):
                self.assertIsNone(util.build_place(root, settings.project, "p.rbxl", quiet=True))
            self.assertIn("rojo not found", err_buf.getvalue())
            err_buf = io.StringIO()
            with mock.patch.object(util, "need", return_value="rojo"), mock.patch.object(util.subprocess, "run", return_value=mock.Mock(returncode=1, stdout="out", stderr="err")), contextlib.redirect_stderr(err_buf):
                self.assertIsNone(util.build_place(root, settings.project, "p.rbxl", quiet=True))
            self.assertTrue("rojo build" in err_buf.getvalue() and "outerr" in err_buf.getvalue())
            with mock.patch.object(util, "need", return_value="rojo") as mock_need, mock.patch.object(util.subprocess, "run", return_value=mock.Mock(returncode=0)) as mock_run:
                self.assertGreaterEqual(util.build_place(root, settings.project, "p.rbxl", quiet=True), 0.0)
                self.assertEqual(mock_need.call_args[0], ("rojo", pathlib.Path(root)))
                self.assertEqual(mock_run.call_args[0][0][:2], ["rojo", "build"])

            self.assertEqual(len(driver.drift(suites.Settings(root, {"studio": {"drift": [{"dir": "test", "project": "missing.project.json", "tree": ["A"]}]}}))), 1)
            pathlib.Path(root, "bad_tree.project.json").write_text('{"tree": {}}')
            self.assertEqual(len(driver.drift(suites.Settings(root, {"studio": {"drift": [{"dir": "test", "project": "bad_tree.project.json", "tree": ["MissingNode"]}]}}))), 1)
            out = io.StringIO()
            with contextlib.redirect_stdout(out):
                self.assertEqual(driver.check(settings, opts, loaded), 2)
                with mock.patch.object(driver, "build_place", return_value=0.1):
                    self.assertEqual(driver.check(settings, opts, driver.Hooks()), 0)
            self.assertTrue("hook problem" in out.getvalue() and "the checks pass" in out.getvalue())

            list_settings = suites.Settings(root, {"studio": {"list_command": [sys.executable, "-c", "import sys; sys.stdout.buffer.write(b'[sert-list] A|a \\xc2\\xb7 b\\n[sert-list] end 1\\n')"], "out": "out"}})
            with contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(driver.refresh_catalogue(list_settings, opts, driver.Hooks(), "play", root), [{"file": "A", "name": "a · b"}])
            bad_list = suites.Settings(root, {"studio": {"list_command": ["nonexistent_cmd_xyz"], "out": "out"}})
            with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
                self.assertIsNone(driver.refresh_catalogue(bad_list, opts, driver.Hooks(), "play", root))

            os.makedirs(os.path.join(root, "test", "unit"), exist_ok=True)
            pathlib.Path(root, "test", "unit", "A.spec.luau").write_text("-- A\n")
            exec_settings = suites.Settings(root, {"studio": {"specs": ["test/unit/*.spec.luau"], "out": "out"}})
            for bad_argv, expected_err in (
                (["--repeat", "0"], "--repeat: N must be at least 1"),
                (["--runs", "0"], "--runs takes a whole number from 1, got 0"),
                (["--replay", "-3"], "--replay takes a whole number from 0, got -3"),
                (["--budget", "nan"], "--budget takes a number of seconds above 0, got nan"),
                (["--seed", "notanumber"], "--seed takes a whole number or 'random'"),
                (["--seed", "-1"], "--seed takes a whole number from 0"),
                (["--grep", "[unclosed"], "--grep:"),
                (["--failed"], "--failed: no earlier"),
            ):
                p_opts = driver.build_parser(exec_settings, driver.Hooks()).parse_args(bad_argv)
                err_b = io.StringIO()
                with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(err_b):
                    self.assertEqual(driver.guarded(exec_settings, driver.Hooks(), p_opts), 2, bad_argv)
                self.assertIn(expected_err, err_b.getvalue())

            sub_p = argparse.ArgumentParser().add_subparsers()
            with mock.patch.object(driver, "prescan_root", wraps=driver.prescan_root) as mock_prescan:
                driver.add_parser(sub_p, ["studio", "--root", root])
                self.assertEqual(mock_prescan.call_count, 1)
            self.assertFalse(any("--root" in a.option_strings for a in sub_p.choices["studio"]._actions))
            studio_parser = cli.build(["studio", "--root", root])._subparsers._group_actions[0].choices["studio"]
            self.assertEqual(sum("--root" in a.option_strings for a in studio_parser._actions), 1)
            check_opts = driver.build_parser(exec_settings, driver.Hooks()).parse_args(["--check"])
            check_opts.root = root
            out = io.StringIO()
            with mock.patch.object(driver, "build_place", return_value=0.1), contextlib.redirect_stdout(out):
                self.assertEqual((driver.main(check_opts), driver.run(["--root", root, "--check"])), (0, 0))
            self.assertIn("the checks pass", out.getvalue())

            driver._LOADED.update(settings=None, hooks=driver.Hooks(), problem="stale cwd problem")
            with mock.patch.object(driver, "build_place", return_value=0.1), contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(driver.main(check_opts), 0)
            self.assertEqual(driver._LOADED, {})

            driver._LOADED.update(settings=None, hooks=driver.Hooks(), problem="cached hook error", root=str(pathlib.Path(root).resolve()))
            err_cached = io.StringIO()
            with mock.patch.object(driver, "load_hooks", side_effect=AssertionError("should not reload hooks")), contextlib.redirect_stderr(err_cached):
                self.assertEqual(driver.main(check_opts), 2)
            self.assertIn("cached hook error", err_cached.getvalue())
            self.assertEqual(driver._LOADED, {})

            hook_file = os.path.join(root, "studio_hooks.py")
            pathlib.Path(hook_file).write_text(HOOKS_SAMPLE, encoding="utf-8")
            hooks = driver.load_hooks(hook_file)
            h_parser = driver.build_parser(driver.Settings(root, {"studio": {"sides": ["server", "client"]}}), hooks)
            public = [n for n in vars(hooks.module) if callable(getattr(hooks.module, n)) and not n.startswith("_") and n.islower()]
            self.assertTrue(set(public) <= set(driver.Hooks.NAMES) and all(hooks.has(n) for n in ("add_arguments", "request", "prelude", "report")))
            plain, streaming = h_parser.parse_args([]), h_parser.parse_args(["--streaming"])
            self.assertEqual((hooks.call("prelude", plain, "play"), hooks.call("request", plain, {"filter": ""})), (None, {"filter": ""}))
            self.assertIn("StreamingEnabled = true", hooks.call("prelude", streaming, "play"))
            self.assertEqual(hooks.call("request", streaming, {"filter": ""}), {"filter": "", "streaming": True})
            with contextlib.redirect_stdout(io.StringIO()) as h_out:
                self.assertIsNone(hooks.call("report", {"x": {"perf": ["page open 12 ms"]}, "exit": 1}))
            self.assertIn("[perf] page open 12 ms", h_out.getvalue())


if __name__ == "__main__":
    unittest.main()
