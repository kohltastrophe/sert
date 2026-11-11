"""Unit tests for coverage ranges/diff (including untracked files), badge JSON, mutation operators, failure snippets, and thread-safe `sert check`."""

from __future__ import annotations

import argparse
import io
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest import mock

import helpers  # noqa: F401
from sert import check, cli, coverage, lint, mutate, run


class AgentFeaturesTest(unittest.TestCase):
    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.root = Path(self._tmp.name)

    def tearDown(self) -> None:
        self._tmp.cleanup()

    def test_uncovered_ranges(self) -> None:
        self.assertEqual(coverage._uncovered_ranges({1: 1, 2: 1}), "")
        self.assertEqual(
            coverage._uncovered_ranges({10: 1, 12: 0, 13: 0, 14: 0, 15: 0, 20: 1, 28: 0}),
            "L12-L15, L28",
        )
        many = {i * 3: 0 for i in range(1, 10)}
        rendered = coverage._uncovered_ranges(many, max_ranges=6)
        self.assertTrue(rendered.endswith(", ..."))
        self.assertEqual(rendered.count("L"), 6)

    def test_coverage_uncovered_and_diff_including_untracked_luau(self) -> None:
        src_dir = self.root / "src"
        src_dir.mkdir(parents=True)
        (src_dir / "Foo.luau").write_text(
            "\n".join(
                [
                    "local Foo = {}",
                    "function Foo.add(a, b)",
                    "\treturn a + b",
                    "end",
                    "function Foo.sub(a, b)",
                    "\treturn a - b",
                    "end",
                    "return Foo",
                ]
            )
            + "\n",
            encoding="utf-8",
        )
        files = {"src/Foo.luau": {1: True, 2: True, 3: True, 5: True, 6: False, 8: True}}
        buf = io.StringIO()
        pct = coverage.summarize(files, ["src"], out=buf, uncovered=True, root=self.root)
        self.assertAlmostEqual(pct, 500.0 / 6.0)
        out_text = buf.getvalue()
        self.assertIn("[missed: L6]", out_text)
        self.assertIn("  L6: \treturn a - b", out_text)

        diff_text = "\n".join(
            [
                "diff --git a/src/Foo.luau b/src/Foo.luau",
                "--- a/src/Foo.luau",
                "+++ b/src/Foo.luau",
                "@@ -6,1 +6,1 @@",
                "-\treturn a",
                "+\treturn a - b",
            ]
        )
        diff_map = coverage.parse_diff_lines(diff_text, root=self.root)
        self.assertEqual(diff_map, {"src/Foo.luau": {6}})
        filtered = coverage.filter_diff_files(files, diff_map)
        self.assertEqual(filtered, {"src/Foo.luau": {6: False}})

        # Verify untracked .luau files are included in `git_diff_lines`
        repo = self.root / "git_cov"
        subprocess.run(["git", "init", "-q", "-b", "main", str(repo)], check=True)
        subprocess.run(["git", "-C", str(repo), "config", "user.name", "Test"], check=True)
        subprocess.run(["git", "-C", str(repo), "config", "user.email", "test@example.com"], check=True)
        (repo / "src").mkdir(parents=True)
        (repo / "src/Tracked.luau").write_text("return 1\n", encoding="utf-8")
        subprocess.run(["git", "-C", str(repo), "add", "-A"], check=True)
        subprocess.run(["git", "-C", str(repo), "commit", "-qm", "init"], check=True)
        (repo / "src/Untracked.luau").write_text("local x = 1\nlocal y = 2\nreturn x + y\n", encoding="utf-8")
        lines_in_diff = coverage.git_diff_lines(repo, "HEAD")
        self.assertEqual(lines_in_diff.get("src/Untracked.luau"), {1, 2, 3})

        (self.root / "sert.toml").write_text('[coverage]\ninclude = ["src"]\n', encoding="utf-8")
        (self.root / "coverage.out").write_text(
            "SF:src/Foo.luau\nDA:3,1\nDA:6,0\nend_of_record\n",
            encoding="utf-8",
        )
        with mock.patch("sert.coverage.git_diff_lines", return_value={"src/Foo.luau": {3}}):
            args = cli.build(["coverage"]).parse_args(["coverage", "--root", str(self.root), "--diff", "HEAD~1", "--uncovered"])
            stdout_buf, stderr_buf = io.StringIO(), io.StringIO()
            with mock.patch("sys.stdout", stdout_buf), mock.patch("sys.stderr", stderr_buf):
                code = coverage.cmd_coverage(args, root=self.root)
            self.assertEqual(code, 0)
            self.assertEqual(stdout_buf.getvalue().strip(), "100.0")

        self.assertEqual(coverage.filter_diff_files(files, {}), {})
        self.assertEqual(coverage.filter_diff_files(files, {"README.md": {1, 2}}), {})
        with mock.patch("sert.coverage.git_diff_lines", return_value={"README.md": {1, 2}}):
            args_non_luau = cli.build(["coverage"]).parse_args(["coverage", "--root", str(self.root), "--diff", "HEAD~1", "--min", "100"])
            stdout_buf, stderr_buf = io.StringIO(), io.StringIO()
            with mock.patch("sys.stdout", stdout_buf), mock.patch("sys.stderr", stderr_buf):
                code = coverage.cmd_coverage(args_non_luau, root=self.root)
            self.assertEqual(code, 0)
            self.assertEqual(stdout_buf.getvalue().strip(), "coverage: no covered lines modified in diff")

        (self.root / "test").mkdir(parents=True, exist_ok=True)
        (self.root / "test/spec.luau").write_text("return {}\n", encoding="utf-8")
        (self.root / "sert.toml").write_text(
            '[test]\nentries = ["test/spec.luau"]\n[coverage]\ninclude = ["src"]\n[mutate]\ninclude = ["src"]\n',
            encoding="utf-8",
        )
        with (
            mock.patch("sert.coverage.git_diff_lines", return_value={"README.md": {1, 2}}),
            mock.patch("sert.mutate.run_mod.luau_command", return_value="luau"),
        ):
            args_mut = cli.build(["mutate"]).parse_args(["mutate", "--root", str(self.root), "--no-coverage-run", "--diff", "HEAD~1"])
            stdout_buf, stderr_buf = io.StringIO(), io.StringIO()
            with mock.patch("sys.stdout", stdout_buf), mock.patch("sys.stderr", stderr_buf):
                code_mut = mutate.cmd_mutate(args_mut)
            self.assertEqual(code_mut, 0)
            self.assertEqual(stdout_buf.getvalue().strip(), "mutate: no covered lines modified in diff; skipping")

    def test_coverage_badge_json_without_git_plumbing(self) -> None:
        self.assertEqual(coverage.badge_color(30.0), coverage.badge_color(50.0))
        self.assertEqual(coverage.badge_color(95.0), coverage.badge_color(90.0))
        self.assertEqual(coverage.badge_color(50.0), "#b31a1a")
        self.assertEqual(coverage.badge_color(70.0), "#b3b31a")
        self.assertEqual(coverage.badge_color(90.0), "#1ab31a")
        self.assertEqual(
            coverage.badge_payload(94.25),
            {"schemaVersion": 1, "label": "coverage", "message": "94.2%", "color": "#1ab31a"},
        )

        # Ensure obsolete --badge-branch / --badge-push flags were removed
        cov_parser = cli.build(["coverage"])
        help_out = io.StringIO()
        with mock.patch("sys.stdout", help_out), self.assertRaises(SystemExit):
            cov_parser.parse_args(["coverage", "--help"])
        self.assertNotIn("--badge-branch", help_out.getvalue())
        self.assertNotIn("--badge-push", help_out.getvalue())

        (self.root / "src").mkdir()
        (self.root / "src/Foo.luau").write_text("return 1\n", encoding="utf-8")
        (self.root / "sert.toml").write_text('[coverage]\ninclude = ["src"]\n', encoding="utf-8")
        (self.root / "coverage.out").write_text("SF:src/Foo.luau\nDA:1,1\nDA:2,1\nDA:3,1\nDA:4,0\nend_of_record\n", encoding="utf-8")

        args_badge = cov_parser.parse_args(["coverage", "--root", str(self.root), "--min", "90", "--badge"])
        with mock.patch("sys.stdout", io.StringIO()), mock.patch("sys.stderr", io.StringIO()):
            self.assertEqual(coverage.cmd_coverage(args_badge, root=self.root), 1)
        self.assertEqual(json.loads((self.root / "coverage.json").read_text(encoding="utf-8"))["message"], "75.0%")

    def test_new_mutation_operators_and_surviving_context(self) -> None:
        self.assertIn("arith_op", mutate.ALL_OPERATORS)
        self.assertIn("logic_op", mutate.ALL_OPERATORS)
        self.assertIn("math_fn", mutate.ALL_OPERATORS)

        source = "\n".join(
            [
                "local M = {}",
                "function M.calc(a, b, ok)",
                "\tlocal sum = a + b",
                "\tlocal prod = a * b",
                "\tlocal both = ok and (a > 0)",
                "\tlocal clamped = math.min(a, b)",
                "\tlocal rounded = math.floor(a)",
                '\tlocal concat = "a + b" .. tostring(a)',
                "\tif a - b > 0 or ok then",
                "\t\treturn math.max(sum, prod)",
                "\tend",
                "\treturn clamped",
                "end",
                "return M",
            ]
        )
        inst, mutants = mutate.instrument_source(
            source,
            {i: True for i in range(1, 15)},
            file_path="src/Calc.luau",
            operators=("arith_op", "logic_op", "math_fn"),
        )
        self.assertEqual(len(inst.splitlines()), len(source.splitlines()))
        by_op = {m.op: [] for m in mutants}
        for m in mutants:
            by_op[m.op].append((m.line, m.mutated))

        self.assertIn((3, "local sum = a - b"), by_op["arith_op"])
        self.assertIn((4, "local prod = a / b"), by_op["arith_op"])
        self.assertIn((5, "local both = ok or (a > 0)"), by_op["logic_op"])
        self.assertIn((6, "local clamped = math.max(a, b)"), by_op["math_fn"])
        self.assertIn((7, "local rounded = math.ceil(a)"), by_op["math_fn"])
        self.assertFalse(any(m.line == 8 for m in mutants))
        self.assertIn((9, "if a + b > 0 or ok then"), by_op["arith_op"])
        self.assertIn((9, "if a - b > 0 and ok then"), by_op["logic_op"])
        self.assertIn((10, "return math.min(sum, prod)"), by_op["math_fn"])

        (self.root / "src").mkdir(parents=True, exist_ok=True)
        (self.root / "src/Calc.luau").write_text(source + "\n", encoding="utf-8")
        mutants[0].status = "SURVIVED"
        mutants[0].spec_filter = "Calc"
        for m in mutants[1:]:
            m.status = "KILLED"
        err_buf = io.StringIO()
        mutate.summarize(mutants, out=err_buf, root=self.root)
        err_out = err_buf.getvalue()
        self.assertIn("2 | function M.calc(a, b, ok)", err_out)
        self.assertIn("4 | \tlocal prod = a * b", err_out)
        self.assertIn('replay: python3 tools/sert.py run --filter "Calc"', err_out)

    def test_format_failure_snippets_and_rtest_guardrail(self) -> None:
        (self.root / "test").mkdir(parents=True, exist_ok=True)
        (self.root / "src").mkdir(parents=True, exist_ok=True)
        spec_lines = [f"-- line {i}" for i in range(1, 50)]
        spec_lines[40] = "\tlocal x = 1"
        spec_lines[41] = "\tsert.eq(x, 2)"
        spec_lines[42] = "end)"
        (self.root / "test/Math.spec.luau").write_text("\n".join(spec_lines) + "\n", encoding="utf-8")
        (self.root / "src/Math.luau").write_text("local M = {}\nfunction M.bad()\n\terror('boom')\nend\nreturn M\n", encoding="utf-8")

        failure_out = (
            "❌ math test · 1 ms\n"
            "   ⚠️ test/Math.spec.luau:42: expected 2, got 1\n"
            "   stack traceback:\n"
            "       src/Math.luau:3: in function bad\n"
            "       test/Math.spec.luau:42: in function\n"
        )
        snippets = run._format_failure_snippets(failure_out, self.root)
        self.assertIn("   41 | \tlocal x = 1", snippets)
        self.assertIn(" > 42 | \tsert.eq(x, 2)", snippets)
        self.assertIn("   43 | end)", snippets)
        self.assertIn(" > 3 | \terror('boom')", snippets)

        args_compact = cli.build(["run"]).parse_args(["run", "--compact", "--filter", "math"])
        self.assertIn("--compact", run.selection_args(args_compact))
        with mock.patch.dict(os.environ, {"SERT_COMPACT": "1"}):
            args_env = cli.build(["run"]).parse_args(["run"])
            self.assertIn("--compact", run.selection_args(args_env))

        (self.root / "sert.toml").write_text('[test]\nentries = ["test/Math.spec.luau"]\n', encoding="utf-8")
        fake_res = run.RunResult(
            status=0,
            entries=[
                run.EntryRun(
                    entry="test/Math.spec.luau",
                    code=0,
                    seconds=0.01,
                    output='0 passed · 0 failed · 2 skipped · 1 ms\n[sert-done] {"passed":0,"failed":0,"skipped":2,"total":2}\n',
                )
            ],
        )
        stderr_buf = io.StringIO()
        with (
            mock.patch("sert.fetch.refresh_overrides"),
            mock.patch("sert.fetch.ensure_fetched"),
            mock.patch("sert.run.run_entries", return_value=fake_res),
            mock.patch("sys.stderr", stderr_buf),
        ):
            code = run.cmd_run(args_compact, root=self.root)
        self.assertEqual(code, 1)
        self.assertIn(
            "sert run: all 2 matching tests were skipped (use 'python3 tools/sert.py studio' to run rtest engine specs)",
            stderr_buf.getvalue(),
        )

    def test_cmd_check_thread_safe_and_displays_lint_errors(self) -> None:
        parser = cli.build(["check"])
        args = parser.parse_args(["check", "--diff", "HEAD~1", "--compact", "--uncovered", "--studio"])
        self.assertEqual((args.diff, args.compact, args.uncovered, args.studio), ("HEAD~1", True, True, True))

        calls: list[str] = []
        with (
            mock.patch("sert.check.lint.cmd_lint", side_effect=lambda a, r, c, **kw: (calls.append("lint"), 0)[1]),
            mock.patch("sert.check.run.cmd_run", side_effect=lambda a, r, c, **kw: (calls.append(f"run:{a.coverage}:{a.compact}"), 0)[1]),
            mock.patch("sert.check.coverage.cmd_coverage", side_effect=lambda a, r, c: (calls.append(f"cov:{a.diff}:{a.uncovered}"), 0)[1]),
            mock.patch("sert.studio.main", side_effect=lambda a: (calls.append(f"studio:{a.check}"), 0)[1]),
        ):
            rc = check.cmd_check(args, self.root, {"studio": {"place": "place.rbxl"}})
        self.assertEqual(rc, 0)
        self.assertEqual(calls, ["lint", "run:True:True", "cov:HEAD~1:True", "studio:True"])

        # Parallel ThreadPoolExecutor path: when lint fails (`lint_code != 0`), its stdout/stderr diagnostics MUST be printed!
        def fake_lint_streams(ns, root=None, cfg=None, *, out=None, err=None):
            out.write("src/Bad.luau(3,1): TypeError: broken\n")
            err.write("lint: failed: analyze\n")
            return 1

        out_buf, err_buf = io.StringIO(), io.StringIO()
        with (
            mock.patch.object(lint, "cmd_lint_streams", side_effect=fake_lint_streams),
            mock.patch.object(run, "cmd_run", wraps=lambda a, r=None, c=None, **kw: 0),
            mock.patch("sys.stdout", out_buf),
            mock.patch("sys.stderr", err_buf),
        ):
            # Keep `run.cmd_run.__module__ == "sert.run"` by patching `run.run_entries` instead so `can_parallel` is True!
            pass

        out_buf, err_buf = io.StringIO(), io.StringIO()
        with (
            mock.patch.object(lint, "cmd_lint_streams", side_effect=fake_lint_streams),
            mock.patch("sert.fetch.refresh_overrides"),
            mock.patch("sert.fetch.ensure_fetched"),
            mock.patch("sert.run.resolve_entries", return_value=["e.luau"]),
            mock.patch("sert.run.run_entries", return_value=run.RunResult(0)),
            mock.patch("sys.stdout", out_buf),
            mock.patch("sys.stderr", err_buf),
        ):
            rc_fail = check.cmd_check(argparse.Namespace(), self.root, {})
        self.assertEqual(rc_fail, 1)
        self.assertIn("src/Bad.luau(3,1): TypeError: broken", out_buf.getvalue())
        self.assertIn("lint: failed: analyze", err_buf.getvalue())


if __name__ == "__main__":
    unittest.main()
