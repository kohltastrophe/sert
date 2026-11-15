"""Unit and integration tests for `sert bench` baseline tracking and regression gating."""

from __future__ import annotations

import contextlib
import io
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
from unittest import mock

import helpers  # noqa: F401
from sert import bench, cli, markers, run, util


def _init_bench_project(root: Path, *, with_real_src: bool = False) -> None:
    (root / "src").mkdir(parents=True, exist_ok=True)
    (root / "test").mkdir(parents=True, exist_ok=True)
    (root / "sert.toml").write_text(
        '[test]\nspecs = ["test/*.spec.luau"]\ncodegen = false\n',
        encoding="utf-8",
    )
    if with_real_src:
        repo_src = Path(__file__).resolve().parents[2] / "src"
        shutil.copytree(repo_src, root / "src", dirs_exist_ok=True)


class BenchTest(unittest.TestCase):
    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.root = Path(self._tmp.name)

    def tearDown(self) -> None:
        self._tmp.cleanup()

    def _mock_bench_run(self, benchmarks: list[dict], *, captured_args: list | None = None):
        lines = ['[sert-file] shared|test/math.spec.luau|5']
        for b in benchmarks:
            lines.append("[sert-x:bench] " + json.dumps(b))
        lines.append('[sert-done] {"passed":1,"failed":0,"skipped":0,"total":1}')
        output = "\n".join(lines) + "\n"
        parsed = markers.parse(output)

        def fake_execute(args, root=None, cfg=None, *, out=None, err=None):
            if captured_args is not None:
                captured_args.append(args)
            res = run.RunResult(
                status=0,
                entries=[run.EntryRun(Path(self.root / "test/math.spec.luau"), 0, 0.01, output=output)],
                tests=[{"name": b["name"], "status": "pass", "ms": 1, "file": "test/math.spec.luau"} for b in benchmarks],
            )
            return 0, res, [parsed]

        return mock.patch.object(run, "execute_run", side_effect=fake_execute)

    def test_bench_save_compare_median_and_alloc_regressions(self) -> None:
        _init_bench_project(self.root)
        baseline_benches = [
            {
                "name": "vector sum",
                "file": "test/math.spec.luau",
                "iterations": 1000,
                "samples": 5,
                "medianNs": 1000.0,
                "iqrNs": 50.0,
                "opsPerSec": 1_000_000.0,
                "allocKb": 10.0,
            }
        ]
        captured: list = []
        with self._mock_bench_run(baseline_benches, captured_args=captured):
            out = io.StringIO()
            with contextlib.redirect_stdout(out):
                code = cli.main(["bench", "--root", str(self.root), "--save", "main", "--filter", "vector"])
        self.assertEqual(code, 0)
        self.assertTrue((self.root / ".sert/bench/main.json").is_file())
        self.assertTrue(captured[0].bench)
        self.assertTrue(captured[0].codegen)
        self.assertFalse(captured[0].coverage)
        self.assertIn("vector sum:", out.getvalue())

        # Within 20% tolerance -> pass
        within_tol = [{**baseline_benches[0], "medianNs": 1150.0, "allocKb": 11.0}]
        with self._mock_bench_run(within_tol):
            out = io.StringIO()
            with contextlib.redirect_stdout(out):
                code = cli.main(["bench", "--root", str(self.root), "--compare", "main", "--agent"])
        self.assertEqual(code, 0, out.getvalue())
        self.assertTrue(out.getvalue().startswith("OK benches=1 regressions=0"), out.getvalue())

        # Median ns/op regression > 20% -> fail exit 1 in agent + json
        slower = [{**baseline_benches[0], "medianNs": 1350.0, "allocKb": 10.0}]
        with self._mock_bench_run(slower):
            out = io.StringIO()
            with contextlib.redirect_stdout(out):
                code = cli.main(["bench", "--root", str(self.root), "--compare", "main", "--format", "json"])
        self.assertEqual(code, 1)
        env = json.loads(out.getvalue())
        self.assertEqual((env["command"], env["status"], env["exit_code"], env["summary"]["regressions"]), ("bench", "failed", 1, 1))
        self.assertEqual(env["data"]["regressions"][0]["metrics"][0]["metric"], "medianNs")

        # Alloc KB regression > threshold even when medianNs improved -> fail exit 1 + ALLOC_REGRESSION in agent mode
        alloc_heavy = [{**baseline_benches[0], "medianNs": 900.0, "allocKb": 15.0}]
        with self._mock_bench_run(alloc_heavy):
            out = io.StringIO()
            with contextlib.redirect_stdout(out):
                code = cli.main(
                    [
                        "bench",
                        "--root",
                        str(self.root),
                        "--compare",
                        "main",
                        "--fail-regression",
                        "20",
                        "--agent",
                    ]
                )
        self.assertEqual(code, 1, out.getvalue())
        self.assertIn("FAIL benches=1 regressions=1", out.getvalue())
        self.assertIn("ALLOC_REGRESSION", out.getvalue())

    def test_bench_alloc_from_zero_regression(self) -> None:
        _init_bench_project(self.root)
        zero_base = [
            {
                "name": "parse",
                "file": "test/math.spec.luau",
                "iterations": 500,
                "samples": 5,
                "medianNs": 100.0,
                "iqrNs": 2.0,
                "opsPerSec": 10_000_000.0,
                "allocKb": 0.0,
            }
        ]
        self.assertEqual(bench.evaluate_regressions(zero_base, zero_base), [])

        with self._mock_bench_run(zero_base):
            with contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(cli.main(["bench", "--root", str(self.root), "--save", "zero"]), 0)

        regressed = [{**zero_base[0], "allocKb": 1.5}]
        eval_regs = bench.evaluate_regressions(regressed, zero_base)
        self.assertEqual(len(eval_regs), 1)
        self.assertEqual(
            eval_regs[0]["metrics"][0],
            {"metric": "allocKb", "baseline": 0.0, "current": 1.5, "pct": 100.0, "fromZero": True},
        )

        with self._mock_bench_run(regressed):
            out_agent = io.StringIO()
            with contextlib.redirect_stdout(out_agent):
                code_a = cli.main(["bench", "--root", str(self.root), "--compare", "zero", "--agent"])
        self.assertEqual(code_a, 1)
        self.assertIn("FAIL benches=1 regressions=1", out_agent.getvalue())
        self.assertIn("ALLOC_REGRESSION +100.0% (0.0->1.5KB)", out_agent.getvalue())

        with self._mock_bench_run(regressed):
            out_json = io.StringIO()
            with contextlib.redirect_stdout(out_json):
                code_j = cli.main(["bench", "--root", str(self.root), "--compare", "zero", "--format", "json"])
        self.assertEqual(code_j, 1)
        env = json.loads(out_json.getvalue())
        self.assertEqual(env["summary"]["regressions"], 1)
        self.assertTrue(env["data"]["regressions"][0]["metrics"][0]["fromZero"])
        self.assertIn("0.0->1.5KB", env["errors"][0])

        with self._mock_bench_run(regressed):
            out_human = io.StringIO()
            with contextlib.redirect_stdout(out_human):
                code_h = cli.main(["bench", "--root", str(self.root), "--compare", "zero"])
        self.assertEqual(code_h, 1)
        self.assertIn("REGRESSION(allocKb 0.0->1.5KB (+100.0%))", out_human.getvalue())

    def test_bench_rejects_invalid_and_missing_baselines(self) -> None:
        _init_bench_project(self.root)
        with self.assertRaisesRegex(util.SertError, "invalid baseline name"):
            bench.load_baseline(self.root, "../escape")
        with self.assertRaisesRegex(util.SertError, "not found"):
            bench.load_baseline(self.root, "nonexistent")

    def test_bench_real_luau_codegen_execution(self) -> None:
        if util.which("luau") is None:
            self.skipTest("luau binary not available on PATH")

        _init_bench_project(self.root, with_real_src=True)
        (self.root / "test/perf.spec.luau").write_text(
            'local sert = require("../src")\n'
            'sert.describe("perf", function()\n'
            '    sert.bench("table sum", function()\n'
            "        local total = 0\n"
            "        for i = 1, 20 do\n"
            "            total += i\n"
            "        end\n"
            "        local _keep = total\n"
            "    end, { samples = 3, iterations = 20 })\n"
            "end)\n",
            encoding="utf-8",
        )

        # Spy on subprocess command line passed to real luau to confirm --codegen and --bench even with codegen = false in sert.toml
        seen_cmds: list[list[str]] = []
        real_popen = run.subprocess.Popen

        def spy_popen(cmd, *args, **kwargs):
            seen_cmds.append(list(cmd))
            return real_popen(cmd, *args, **kwargs)

        with mock.patch.object(run.subprocess, "Popen", side_effect=spy_popen):
            out = io.StringIO()
            with contextlib.redirect_stdout(out):
                code = cli.main(
                    ["bench", "--root", str(self.root), "--save", "base", "--agent"]
                )
        self.assertEqual(code, 0, out.getvalue())
        self.assertIn("OK benches=1", out.getvalue())
        self.assertIn("table sum:", out.getvalue())
        self.assertTrue(any("--codegen" in cmd and "--bench" in cmd for cmd in seen_cmds), seen_cmds)
        loaded = bench.load_baseline(self.root, "base")
        self.assertEqual(loaded[0]["name"], "perf > table sum")


if __name__ == "__main__":
    unittest.main()
