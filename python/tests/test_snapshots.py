"""Unit tests for inline/file snapshot updates, Luau long-bracket escaping, and agent formatters."""

from __future__ import annotations

import argparse
import binascii
import json
from pathlib import Path
import subprocess
import tempfile
import unittest

import helpers  # noqa: F401
from sert import agent, markers, mutate, run, snapshots, util


class SnapshotsTest(unittest.TestCase):
    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.root = Path(self._tmp.name)

    def tearDown(self) -> None:
        self._tmp.cleanup()

    def test_format_luau_literal_long_brackets_and_leading_newlines(self) -> None:
        # Single-line strings must NOT use `\n`-prepended brackets or inject leading `\n`.
        single = snapshots.format_luau_snapshot_literal("hello world")
        self.assertEqual(single, '"hello world"')

        # Multi-line gets `[[\n...]]`
        multi = snapshots.format_luau_snapshot_literal("line1\nline2")
        self.assertEqual(multi, "[[\nline1\nline2]]")

        # String starting with `\n` gets an extra `\n` so Luau's lexer discards only one.
        leading = snapshots.format_luau_snapshot_literal("\nfirst")
        self.assertEqual(leading, "[[\n\nfirst]]")
        only_nl = snapshots.format_luau_snapshot_literal("\n")
        self.assertEqual(only_nl, "[[\n\n]]")

        # Brackets inside payload escalate `k` to avoid premature closing.
        nested = snapshots.format_luau_snapshot_literal("a]]b\nc")
        self.assertEqual(nested, "[=[\na]]b\nc]=]")
        double_nested = snapshots.format_luau_snapshot_literal("a]=]b\n]]c")
        self.assertEqual(double_nested, "[==[\na]=]b\n]]c]==]")

        # Trailing `]` or `]]\n]=` also escalates `k`.
        trailing_bracket = snapshots.format_luau_snapshot_literal("x\n]")
        self.assertEqual(trailing_bracket, "[=[\nx\n]]=]")
        trailing_eq = snapshots.format_luau_snapshot_literal("x\n]]\n]=")
        self.assertEqual(trailing_eq, "[==[\nx\n]]\n]=]==]")

    def test_luau_vm_roundtrip_for_all_snapshot_payloads(self) -> None:
        luau_bin = util.which("luau")
        if luau_bin is None:
            self.skipTest("luau binary not installed")

        payloads = [
            "",
            "simple single line",
            'quotes "double" and \'single\' and \\backslash',
            "\n",
            "\nleading newline",
            "\n\ntwo leading newlines\ntrailing\n",
            "line 1\nline 2\nline 3",
            "has ]]\nand ]=]\nand ]==]",
            "ends with ]\n]",
            "ends with ]=\n]=",
            "crlf\r\nand nul\0000digit",
            "unicode: \u00e9 \u2603 \u2713\nsecond line",
        ]
        for idx, expected in enumerate(payloads):
            literal = snapshots.format_luau_snapshot_literal(expected)
            script = self.root / f"roundtrip_{idx}.luau"
            # Print hex bytes from Luau so no stdout newline normalization interferes.
            script.write_text(
                f"local actual = {literal}\n"
                'local hex = {}\n'
                'for i = 1, #actual do hex[i] = string.format("%02x", string.byte(actual, i)) end\n'
                'print(table.concat(hex))\n',
                encoding="utf-8",
            )
            proc = subprocess.run([luau_bin, str(script)], capture_output=True, text=True, check=True)
            got = binascii.unhexlify(proc.stdout.strip()).decode("utf-8")
            self.assertEqual(got, expected, msg=f"Luau roundtrip failed for literal: {literal!r}")

    def test_apply_inline_updates_nested_syntax_same_line_and_reverse_offsets(self) -> None:
        spec = self.root / "test" / "inline.spec.luau"
        spec.parent.mkdir(parents=True)
        spec.write_text(
            "\n".join(
                [
                    "local function inlineSnapshot(v, e, m) return v end",
                    "",
                    'it("multi edits", function()',
                    "\tinlineSnapshot(compute({ 1, 2 }, (a :: Box<K, V>))) -- keep comment",
                    "\tinlineSnapshot(`x={fn(1, 2)}, y={z}`); inlineSnapshot(b, 'old', \"hint\")",
                    "\tsert.inlineSnapshot(\n\t\tbuildTable({ k = 1 }),\n\t\tnil,\n\t\t\"third\"\n\t)",
                    "end)",
                    "",
                ]
            ),
            encoding="utf-8",
        )

        events = [
            {
                "kind": "inline",
                "file": ".sert/stage/specs/inline.spec.luau",
                "line": 4,
                "ordinal": 1,
                "actual": "\nfirst\n]]end]",
                "previous": None,
            },
            {
                "kind": "inline",
                "file": "test/inline.spec.luau",
                "line": 5,
                "ordinal": 1,
                "actual": "interp-val",
                "previous": None,
            },
            {
                "kind": "inline",
                "file": "test/inline.spec.luau",
                "line": 5,
                "ordinal": 2,
                "actual": "new-b",
                "previous": "old",
            },
            {
                "kind": "inline",
                "file": "test/inline.spec.luau",
                "line": 6,
                "ordinal": 1,
                "actual": "multi\nline\ntbl",
                "previous": None,
            },
        ]

        records = snapshots.apply_inline_updates(self.root, events)
        self.assertEqual(len(records), 4)
        self.assertEqual(
            [(r["line"], r["key_or_ordinal"], r["action"]) for r in records],
            [(4, 1, "created"), (5, 1, "created"), (5, 2, "updated"), (6, 1, "created")],
        )

        patched = spec.read_text(encoding="utf-8")
        # Line 1 helper definition must not be touched
        self.assertIn("local function inlineSnapshot(v, e, m)", patched)
        # Line 4 inserted long-bracket literal and kept trailing comment
        self.assertIn(
            'inlineSnapshot(compute({ 1, 2 }, (a :: Box<K, V>)), [=[\n\nfirst\n]]end]]=]) -- keep comment',
            patched,
        )
        # Line 5 updated BOTH calls cleanly despite same-line offset shifts and interpolation commas
        self.assertIn(
            'inlineSnapshot(`x={fn(1, 2)}, y={z}`, "interp-val"); inlineSnapshot(b, "new-b", "hint")',
            patched,
        )
        # Line 6 replaced `nil` arg2 while preserving `"third"` arg3
        self.assertIn(
            '\tsert.inlineSnapshot(\n\t\tbuildTable({ k = 1 }),\n\t\t[[\nmulti\nline\ntbl]],\n\t\t"third"\n\t)',
            patched,
        )

    def test_file_snapshots_roundtrip_create_update_and_prune(self) -> None:
        events = [
            {
                "kind": "file",
                "file": "test/unit/Button.spec.luau",
                "key": "renders :: 1",
                "actual": "line 1\nline 2\n]]",
                "previous": None,
            },
            {
                "kind": "file",
                "file": "test/unit/Button.spec.luau",
                "key": 'escapes "k" :: 2',
                "actual": "\nleading\r\ncrlf\0001",
                "previous": None,
            },
        ]
        created = snapshots.apply_file_updates(self.root, events)
        self.assertEqual([r["action"] for r in created], ["created", "created"])

        snap_file = self.root / "test" / "__snapshots__" / "unit" / "Button.snap"
        self.assertTrue(snap_file.is_file())

        loaded = snapshots.load_file_snapshots(self.root)
        self.assertEqual(
            loaded,
            {
                "unit/Button": {
                    'escapes "k" :: 2': "\nleading\r\ncrlf\x001",
                    "renders :: 1": "line 1\nline 2\n]]",
                }
            },
        )

        # Update one key and prune the other (via full spec path)
        updated = snapshots.apply_file_updates(
            self.root,
            [
                {
                    "kind": "file",
                    "file": "test/unit/Button.spec.luau",
                    "key": "renders :: 1",
                    "actual": "updated text",
                    "previous": "line 1\nline 2\n]]",
                }
            ],
            prune={("test/unit/Button.spec.luau", 'escapes "k" :: 2')},
        )
        self.assertEqual([(r["key_or_ordinal"], r["action"]) for r in updated], [("renders :: 1", "updated"), ('escapes "k" :: 2', "pruned")])
        self.assertEqual(snapshots.load_file_snapshots(self.root), {"unit/Button": {"renders :: 1": "updated text"}})

        # Pruning final key deletes the `.snap` file cleanly
        snapshots.apply_file_updates(self.root, [], prune={("unit/Button", "renders :: 1")})
        self.assertFalse(snap_file.exists())
        self.assertEqual(snapshots.load_file_snapshots(self.root), {})

    def test_spec_file_snapshot_info_ignores_local_function_snapshot(self) -> None:
        spec = self.root / "test" / "snap_decl.spec.luau"
        spec.parent.mkdir(parents=True, exist_ok=True)
        spec.write_text(
            "\n".join(
                [
                    "local function snapshot(v, _k) return v end",
                    "local H = {}",
                    "function H.snapshot() end",
                    "sert.snapshot(1, 'alpha')",
                    "snapshot(2, 'beta')",
                ]
            )
            + "\n",
            encoding="utf-8",
        )
        count, names = run._spec_file_snapshot_info(spec)
        self.assertEqual((count, names), (2, {"alpha", "beta"}))


class AgentFormattingTest(unittest.TestCase):
    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.root = Path(self._tmp.name)

    def tearDown(self) -> None:
        self._tmp.cleanup()

    def test_output_format_and_is_agent_mode(self) -> None:
        self.assertEqual(agent.output_format(argparse.Namespace(), env={}), "human")
        self.assertFalse(agent.is_agent_mode(argparse.Namespace(), env={}))

        self.assertEqual(agent.output_format(argparse.Namespace(agent=True), env={}), "agent")
        self.assertTrue(agent.is_agent_mode(argparse.Namespace(agent=True), env={}))

        self.assertEqual(agent.output_format(argparse.Namespace(format="json"), env={}), "json")
        self.assertFalse(agent.is_agent_mode(argparse.Namespace(format="json"), env={}))

        self.assertEqual(agent.output_format(argparse.Namespace(format="agent"), env={}), "agent")
        self.assertEqual(agent.output_format(argparse.Namespace(), env={"SERT_AGENT": "1"}), "agent")

        env = agent.json_envelope("run", 1, summary={"passed": 3, "failed": 1}, errors=["boom"], data={"x": 1})
        self.assertEqual(env["version"], 1)
        self.assertEqual(env["status"], "failed")
        self.assertEqual(env["exit_code"], 1)
        decoded = json.loads(agent.json_dumps_compact(env))
        self.assertEqual(decoded["command"], "run")

    def test_format_run_agent_includes_snippets_diffs_regressions_snapshots_and_skips(self) -> None:
        spec = self.root / "test" / "calc.spec.luau"
        spec.parent.mkdir(parents=True)
        spec.write_text(
            "local function f()\n\texpect(a).toEqual(b)\n\treturn true\nend\n",
            encoding="utf-8",
        )
        stdout = "\n".join(
            [
                '[sert-test] {"name":"passes silently","status":"pass","file":"test/calc.spec.luau","line":1,"ms":1}',
                '[sert-test] {"name":"breaks cleanly","status":"fail","file":"test/calc.spec.luau","line":2,"expected":{"nested":{"v":1}},"actual":{"nested":{"v":2}},"replay":"v1:77:8:ABCD"}',
                '[sert-x:snapshot] {"kind":"inline","file":"test/calc.spec.luau","line":2,"ordinal":1,"previous":"old","actual":"new"}',
                '[sert-done] {"passed":1,"failed":1,"skipped":2,"skippedByReason":{"explicit":1,"roblox":1,"server":0,"client":0},"zeroAssertionTests":["empty test"],"tautologies":[{"file":"test/calc.spec.luau","line":3,"message":"always true"}]}',
            ]
        )
        parsed = markers.parse(stdout)
        result = run.RunResult(
            status=1,
            entries=[run.EntryRun(entry="test/calc.spec.luau", code=1, seconds=0.125, output=stdout)],
            tests=parsed.tests,
        )
        out = agent.format_run_agent(result, root=self.root)

        self.assertIn("FAIL passed=1 failed=1 skipped=2 duration=125ms", out)
        self.assertNotIn("passes silently", out)
        self.assertIn("breaks cleanly (test/calc.spec.luau:2)", out)
        self.assertIn("> 2 | \texpect(a).toEqual(b)", out)
        self.assertIn("$.nested.v: -1 +2", out)
        self.assertIn('regressions = { "v1:77:8:ABCD" }', out)
        self.assertIn("SNAPSHOT test/calc.spec.luau:2", out)
        self.assertIn("SKIPPED_TARGETS explicit=1 roblox=1", out)
        self.assertIn("ZERO_ASSERTIONS 1: empty test", out)
        self.assertIn("TAUTOLOGY test/calc.spec.luau:3 always true", out)

    def test_other_agent_formatters(self) -> None:
        src = self.root / "src" / "a.luau"
        src.parent.mkdir(parents=True)
        src.write_text("local x = 1\nlocal y = x + 2\nreturn y\n", encoding="utf-8")

        self.assertEqual(agent.format_lint_agent([]), "OK lint=0")
        lint_out = agent.format_lint_agent([("src/a.luau", 2, "unused var y")], root=self.root)
        self.assertIn("FAIL lint=1", lint_out)
        self.assertIn("src/a.luau:2 unused var y", lint_out)
        self.assertIn("> 2 | local y = x + 2", lint_out)

        cov_out = agent.format_coverage_agent(
            {
                "src/perfect.luau": {1: 2, 2: 1},
                "src/a.luau": {1: 1, 2: 0, 3: 0},
            },
            minimum=80.0,
        )
        self.assertIn("FAIL coverage=60.0% (3/5) min=80.0%", cov_out)
        self.assertNotIn("src/perfect.luau", cov_out)
        self.assertIn("src/a.luau 33.3% (1/3) uncovered: L2-L3", cov_out)

        mut_out = agent.format_mutate_agent(
            [
                mutate.Mutant(id=1, file="src/a.luau", line=1, op="add", original="+", mutated="-", status="KILLED"),
                mutate.Mutant(id=2, file="src/a.luau", line=2, op="add", original="+", mutated="-", status="SURVIVED"),
            ],
            root=self.root,
        )
        self.assertIn("FAIL mutation_score=50.0% killed=1 survived=1", mut_out)
        self.assertNotIn("KILLED", mut_out)
        self.assertIn("SURVIVED 2 src/a.luau:2 [add] `+` -> `-`", mut_out)

        audit_out = agent.format_audit_agent(
            {
                "zero_assertion_tests": ["noop"],
                "tautologies": [{"file": "src/a.luau", "line": 3, "message": "taut"}],
                "stale_snapshots": ["unused :: 1"],
                "skipped_by_reason": {"server": 2},
            },
            root=self.root,
        )
        self.assertIn("FAIL audit_issues=3", audit_out)
        self.assertIn("SKIPPED_TARGETS server=2", audit_out)

        verify_out = agent.format_verify_agent(
            {
                "checks": [
                    {"name": "lint", "ok": True},
                    {"name": "tests", "ok": False, "output": "FAIL x"},
                ]
            }
        )
        self.assertIn("FAIL checks=2 passed=1 failed=1", verify_out)
        self.assertIn("PASSED: lint", verify_out)
        self.assertIn("--- FAILED tests ---", verify_out)

        fuzz_out = agent.format_fuzz_agent(
            {
                "iterations": 200,
                "passed": 199,
                "failed": 1,
                "seed": 42,
                "failures": [
                    {
                        "name": "commutative",
                        "file": "src/a.luau",
                        "line": 2,
                        "counterexample": [1, 2],
                        "replay": "v1:42:5:ZZZZ",
                    }
                ],
            },
            root=self.root,
        )
        self.assertIn("FAIL fuzz iterations=200 passed=199 failed=1 seed=42", fuzz_out)
        self.assertIn('regressions = { "v1:42:5:ZZZZ" }', fuzz_out)

        bench_out = agent.format_bench_agent(
            [{"name": "parse", "file": "b.luau", "medianNs": 2000, "iqrNs": 100, "opsPerSec": 500000, "allocKb": 2.0, "iterations": 100, "samples": 10}],
            baseline=[{"name": "parse", "file": "b.luau", "medianNs": 1000}],
        )
        self.assertIn("FAIL benches=1 regressions=1", bench_out)
        self.assertIn("REGRESSION +100.0%", bench_out)


if __name__ == "__main__":
    unittest.main()
