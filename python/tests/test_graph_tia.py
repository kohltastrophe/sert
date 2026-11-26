"""Unit tests for extended marker parsing and hybrid static + dynamic TIA graph routing."""

from __future__ import annotations

import json
import os
from pathlib import Path
import subprocess
import unittest
from unittest import mock

import helpers
from sert import config, graph, markers


def _write(path: Path, text: str) -> Path:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text, encoding="utf-8")
    return path


class MarkersExtensionsTest(unittest.TestCase):
    def test_parse_collects_quality_and_extended_markers_with_verdict(self) -> None:
        seen_hooks: list[tuple[str, object]] = []
        stdout = "\n".join(
            [
                "[sert-file] local|test/math.spec.luau|4",
                '[sert-test] {"name":"adds","status":"pass","file":"test/math.spec.luau","line":5,"ms":2}',
                '[sert-x:snapshot] {"kind":"inline","file":"test/math.spec.luau","line":10,"ordinal":1,"actual":"42","previous":null}',
                '[sert-x:regression] {"token":"v1:99:16:AAAA","file":"test/fuzz.spec.luau","line":18,"name":"prop"}',
                '[sert-x:bench] {"name":"sort1k","file":"bench/sort.bench.luau","iterations":1000,"samples":20,"medianNs":12500,"iqrNs":400,"opsPerSec":80000,"allocKb":1.5}',
                '[sert-done] {"passed":1,"failed":0,"skipped":3,"skippedByReason":{"explicit":1,"roblox":2,"server":0,"client":0},"zeroAssertionTests":["empty case"],"tautologies":{}}',
                '[sert-verdict] {"status":"pass","counts":{"passed":2,"failed":0,"skipped":4},"skippedByReason":{"explicit":1,"roblox":2,"server":1,"client":0},"zeroAssertionTests":["test A","test B"],"tautologies":[{"file":"test/math.spec.luau","line":22,"kind":"sameExpr","message":"expect(x).toBe(x)"}]}',
            ]
        )
        parsed = markers.parse(stdout, on_marker=lambda name, payload: seen_hooks.append((name, payload)))

        self.assertEqual(parsed.files, [{"side": "local", "file": "test/math.spec.luau", "ms": 4}])
        self.assertEqual(len(parsed.tests), 1)
        self.assertEqual(parsed.tests[0]["status"], "pass")
        self.assertEqual(parsed.skipped_by_reason, {"explicit": 1, "roblox": 2, "server": 1, "client": 0})
        self.assertEqual(parsed.zero_assertion_tests, ["test A", "test B"])
        self.assertEqual(
            parsed.tautologies,
            [{"file": "test/math.spec.luau", "line": 22, "kind": "sameExpr", "message": "expect(x).toBe(x)"}],
        )
        self.assertEqual(len(parsed.snapshots), 1)
        self.assertEqual(parsed.snapshots[0]["actual"], "42")
        self.assertEqual(len(parsed.regressions), 1)
        self.assertEqual(parsed.regressions[0]["token"], "v1:99:16:AAAA")
        self.assertEqual(len(parsed.benchmarks), 1)
        self.assertEqual(parsed.benchmarks[0]["medianNs"], 12500)
        # Backwards compatibility: `[sert-x:<channel>]` and `on_marker` still fire as before.
        self.assertEqual([tag for tag, _ in parsed.x], ["snapshot", "regression", "bench"])
        self.assertEqual([tag for tag, _ in seen_hooks], ["snapshot", "regression", "bench"])

    def test_parse_aggregates_done_entries_when_no_verdict(self) -> None:
        stdout = "\n".join(
            [
                '[sert-done] {"passed":1,"failed":0,"skipped":1,"skippedByReason":{"explicit":1},"zeroAssertionTests":["z1"],"tautologies":[{"file":"a.spec.luau","line":3,"message":"t1"}]}',
                '[sert-done] {"passed":2,"failed":0,"skipped":2,"skippedByReason":{"explicit":1,"client":2},"zeroAssertionTests":["z2"],"tautologies":{}}',
            ]
        )
        parsed = markers.parse(stdout)
        self.assertEqual(parsed.skipped_by_reason, {"explicit": 2, "roblox": 0, "server": 0, "client": 2})
        self.assertEqual(parsed.zero_assertion_tests, ["z1", "z2"])
        self.assertEqual(parsed.tautologies, [{"file": "a.spec.luau", "line": 3, "message": "t1"}])

    def test_parse_unwraps_value_encoded_verdict(self) -> None:
        stdout = '[sert-verdict] {"ok":true,"value":{"counts":{"passed":1,"failed":0,"skipped":1,"skippedByReason":{"roblox":1}},"zeroAssertionTests":{"ok":true,"value":["z"]},"tautologies":{}}}'
        parsed = markers.parse(stdout)
        self.assertEqual(parsed.skipped_by_reason, {"explicit": 0, "roblox": 1, "server": 0, "client": 0})
        self.assertEqual(parsed.zero_assertion_tests, ["z"])
        self.assertEqual(parsed.tautologies, [])


class GraphTiaTest(helpers.Case):
    def setUp(self) -> None:
        super().setUp()
        self.root = self.tmp / "proj"
        self.root.mkdir()

    def _build_sample_repo(self) -> config.Config:
        _write(
            self.root / ".luaurc",
            """// JSONC config with trailing commas
{
  "aliases": {
    "core": "src/core", /* block comment */
    "lune": "~/.lune/typedefs",
  },
}
""",
        )
        _write(
            self.root / "src/nested/.luaurc",
            json.dumps({"aliases": {"localmod": "./helpers"}}),
        )
        _write(
            self.root / "default.project.json",
            json.dumps(
                {
                    "name": "Sample",
                    "tree": {
                        "$className": "DataModel",
                        "ReplicatedStorage": {
                            "Pkg": {"$path": "src"},
                        },
                    },
                }
            ),
        )
        _write(
            self.root / "sert.toml",
            '[test]\nspecs = ["test/**/*.spec.luau"]\n[studio]\nproject = "default.project.json"\n',
        )

        # Static dependency chains:
        # test/fast.spec.luau -> @core/math -> ./base -> ../shared/types
        # test/slow.spec.luau -> RS:WaitForChild("Pkg"):FindFirstChild("core").math
        # test/nested.spec.luau -> @self/fixture + src/nested/entry (@localmod/helper)
        # test/isolated.spec.luau -> independent (only linked dynamically if recorded)
        _write(self.root / "src/shared/types.luau", "return {}\n")
        _write(
            self.root / "src/core/base.luau",
            'local Types = require("../shared/types")\nreturn Types\n',
        )
        _write(
            self.root / "src/core/math.luau",
            'local Base = require("./base")\nlocal ok, opt = pcall(require, "./missing_opt")\nreturn Base\n',
        )
        _write(
            self.root / "src/core/init.luau",
            'local Math = require("@self/math")\nreturn Math\n',
        )
        _write(
            self.root / "src/nested/helpers/helper.luau",
            'local Base = require("../../core/base")\nreturn Base\n',
        )
        _write(
            self.root / "src/nested/entry.luau",
            'local Helper = require("@localmod/helper")\nlocal Sibling = require(script.Parent.helpers.helper)\nreturn { Helper, Sibling }\n',
        )
        _write(self.root / "test/fixture.luau", "return { x = 1 }\n")
        _write(
            self.root / "test/fast.spec.luau",
            'local Math = require("@core/math")\nlocal Dynamic = require(someVar)\nreturn Math\n',
        )
        _write(
            self.root / "test/slow.spec.luau",
            "\n".join(
                [
                    'local RS = game:GetService("ReplicatedStorage")',
                    'local Pkg = RS:WaitForChild("Pkg")',
                    'local Core = Pkg:FindFirstChild("core")',
                    "local Math = require(Core.math)",
                    "return Math",
                ]
            )
            + "\n",
        )
        _write(
            self.root / "test/nested.spec.luau",
            'local Fixture = require("@self/../fixture")\nlocal Entry = require("@game/ReplicatedStorage/Pkg/nested/entry")\nreturn { Fixture, Entry }\n',
        )
        _write(self.root / "test/isolated.spec.luau", "return function() end\n")
        _write(self.root / "src/unrelated.luau", "return true\n")
        return config.load(self.root)

    def test_luaurc_and_rojo_static_dependency_graph(self) -> None:
        cfg = self._build_sample_repo()
        dep_graph = graph.build_graph(self.root, cfg)

        # Direct + transitive forward dependencies of fast.spec.luau
        self.assertEqual(dep_graph.dependencies("test/fast.spec.luau", transitive=False), {"src/core/math.luau"})
        self.assertEqual(
            dep_graph.dependencies("test/fast.spec.luau", transitive=True),
            {"src/core/math.luau", "src/core/base.luau", "src/shared/types.luau"},
        )

        # Nested aliases + script.Parent + @game resolution + Roblox WaitForChild local tracking
        self.assertIn("src/nested/helpers/helper.luau", dep_graph.dependencies("src/nested/entry.luau", transitive=False))
        self.assertIn("src/core/math.luau", dep_graph.dependencies("test/slow.spec.luau", transitive=False))
        self.assertIn("src/nested/entry.luau", dep_graph.dependencies("test/nested.spec.luau", transitive=False))
        self.assertIn("test/fixture.luau", dep_graph.dependencies("test/nested.spec.luau", transitive=False))

        # Transitive reverse edges from leaf module `src/shared/types.luau`
        leaf_dependents = dep_graph.dependents("src/shared/types.luau", transitive=True)
        self.assertTrue(
            {
                "test/fast.spec.luau",
                "test/slow.spec.luau",
                "test/nested.spec.luau",
            }.issubset(leaf_dependents)
        )
        self.assertNotIn("test/isolated.spec.luau", leaf_dependents)

    def test_coverage_map_roundtrip_and_hybrid_affected_specs(self) -> None:
        cfg = self._build_sample_repo()

        # Record dynamic coverage linking `test/isolated.spec.luau` to `src/unrelated.luau` line 1
        # even though there is NO static require edge.
        graph.record_spec_coverage(
            self.root,
            "test/isolated.spec.luau",
            {"src/unrelated.luau": {1: True, 2: False}},
            ms=12,
        )
        cov_map = graph.load_coverage_map(self.root)
        self.assertEqual(cov_map["version"], 1)
        entry = cov_map["specs"]["test/isolated.spec.luau"]
        self.assertEqual(entry["ms"], 12)
        self.assertEqual(len(entry["sha256"]), 64)
        self.assertEqual(entry["files"], {"src/unrelated.luau": [1]})

        all_specs = graph.discover_specs(self.root, cfg)
        self.assertEqual(
            all_specs,
            ["test/fast.spec.luau", "test/isolated.spec.luau", "test/nested.spec.luau", "test/slow.spec.luau"],
        )

        # Static leaf edit triggers static specs but not isolated
        with mock.patch("sert.coverage.git_diff_lines", return_value={"src/shared/types.luau": {1}}):
            affected, mod_files = graph.affected_specs(self.root, cfg, "HEAD", all_specs)
        self.assertEqual(mod_files, {"src/shared/types.luau"})
        self.assertEqual(affected, ["test/fast.spec.luau", "test/nested.spec.luau", "test/slow.spec.luau"])

        # Dynamic-only line edit triggers `test/isolated.spec.luau`
        with mock.patch("sert.coverage.git_diff_lines", return_value={"src/unrelated.luau": {1}}):
            affected, _ = graph.affected_specs(self.root, cfg, "HEAD", all_specs)
        self.assertEqual(affected, ["test/isolated.spec.luau"])

        # Uncovered line in `src/unrelated.luau` returns nothing when static graph also has no link
        with mock.patch("sert.coverage.git_diff_lines", return_value={"src/unrelated.luau": {2}}):
            affected, _ = graph.affected_specs(self.root, cfg, "HEAD", all_specs)
        self.assertEqual(affected, [])

        # Global config change returns all specs
        for cfg_file in ("sert.toml", ".luaurc", "rokit.toml", "default.project.json", ".config.luau"):
            with mock.patch("sert.coverage.git_diff_lines", return_value={cfg_file: {1}}):
                affected, _ = graph.affected_specs(self.root, cfg, "HEAD", all_specs)
            self.assertEqual(affected, all_specs, msg=f"expected global invalidation for {cfg_file}")

    def test_affected_specs_includes_real_untracked_luau_files(self) -> None:
        cfg = self._build_sample_repo()
        subprocess.run(["git", "init", "-q"], cwd=self.root, check=True)
        subprocess.run(["git", "config", "user.email", "ci@example.com"], cwd=self.root, check=True)
        subprocess.run(["git", "config", "user.name", "CI"], cwd=self.root, check=True)
        subprocess.run(["git", "add", "."], cwd=self.root, check=True)
        subprocess.run(["git", "commit", "-q", "-m", "init"], cwd=self.root, check=True)

        # Untracked new spec file added after commit
        _write(self.root / "test/brand_new.spec.luau", "return function() end\n")
        affected, mod_files = graph.affected_specs(self.root, cfg, "HEAD")
        self.assertIn("test/brand_new.spec.luau", mod_files)
        self.assertEqual(affected, ["test/brand_new.spec.luau"])

    def test_covering_specs_for_line_orders_fastest_first(self) -> None:
        cfg = self._build_sample_repo()
        all_specs = [
            "test/slow.spec.luau",
            "test/fast.spec.luau",
            "test/nested.spec.luau",
            "test/isolated.spec.luau",
        ]
        # Give `slow` 250ms, `nested` 45ms, `fast` 8ms, and `isolated` 3ms (exact line hit on line 4).
        graph.record_spec_coverage(self.root, "test/slow.spec.luau", {"src/core/math.luau": {4: True}}, ms=250)
        graph.record_spec_coverage(self.root, "test/nested.spec.luau", {"src/shared/types.luau": {1: True}}, ms=45)
        graph.record_spec_coverage(self.root, "test/fast.spec.luau", {"src/core/math.luau": {2: True}}, ms=8)
        graph.record_spec_coverage(self.root, "test/isolated.spec.luau", {"src/core/math.luau": {4: True}}, ms=3)

        # Line 4 of `src/core/math.luau`:
        # - Exact coverage hits: `isolated` (3ms), `slow` (250ms)
        # - Static reverse edges: `fast` (8ms), `slow` (250ms)
        # Must deduplicate and sort fastest first: isolated (3ms) -> fast (8ms) -> slow (250ms).
        ordered = graph.covering_specs_for_line(self.root, cfg, "src/core/math.luau", 4, all_specs)
        self.assertEqual(
            ordered,
            ["test/isolated.spec.luau", "test/fast.spec.luau", "test/slow.spec.luau"],
        )

        # Uncached static dependent (`test/new_static.spec.luau`) sorts after cached ones
        _write(self.root / "test/new_static.spec.luau", 'local M = require("@core/math")\nreturn M\n')
        ordered_with_uncached = graph.covering_specs_for_line(
            self.root,
            cfg,
            "src/core/math.luau",
            4,
            all_specs + ["test/new_static.spec.luau"],
        )
        self.assertEqual(
            ordered_with_uncached,
            [
                "test/isolated.spec.luau",
                "test/fast.spec.luau",
                "test/slow.spec.luau",
                "test/new_static.spec.luau",
            ],
        )

    def test_load_rojo_trees_shared_mount_avoids_cyclic_node_eq_recursion(self) -> None:
        cfg = self._build_sample_repo()
        _write(
            self.root / "test/roblox/default.project.json",
            json.dumps(
                {
                    "name": "TestHarness",
                    "tree": {
                        "$className": "DataModel",
                        "ReplicatedStorage": {
                            "Pkg": {"$path": "../../src"},
                        },
                    },
                }
            ),
        )
        index = graph.load_rojo_trees(self.root, cfg)
        self.assertEqual(index.resolve_path(("ReplicatedStorage", "Pkg")), "src/init.luau" if (self.root / "src/init.luau").is_file() else None)
        self.assertEqual(index.resolve_path(("ReplicatedStorage", "Pkg", "core", "math")), "src/core/math.luau")
        dep_graph = graph.build_graph(self.root, cfg)
        self.assertIn("src/core/math.luau", dep_graph.dependencies("test/slow.spec.luau", transitive=False))

    def test_extract_requires_skips_type_only_typeof_require_references(self) -> None:
        cfg = self._build_sample_repo()
        _write(
            self.root / "test/Harness.luau",
            "\n".join(
                [
                    "--!strict",
                    'local RuntimeDep = require("../src/core/base")',
                    'export type MathMod = typeof(require("../src/core/math"))',
                    'type EntryMod = typeof(require("../src/nested/entry"))',
                    'local typedLocal: typeof(require("../src/unrelated"))? = nil',
                    'local castVal = (nil :: any) :: typeof(require("../src/core/init"))',
                    'local function useTypes(a: typeof(require("../src/shared/types"))): typeof(require("../src/nested/helpers/helper"))',
                    "\treturn a :: any",
                    "end",
                    "return { dep = RuntimeDep, typedLocal = typedLocal, castVal = castVal, useTypes = useTypes }",
                ]
            )
            + "\n",
        )
        dep_graph = graph.build_graph(self.root, cfg)
        direct = dep_graph.dependencies("test/Harness.luau", transitive=False)
        self.assertEqual(direct, {"src/core/base.luau"})

    def test_record_spec_coverage_exact_false_preserves_matching_exact_entry(self) -> None:
        cfg = self._build_sample_repo()
        spec = "test/fast.spec.luau"
        graph.record_spec_coverage(self.root, spec, {"src/core/math.luau": {2: True, 3: True}}, ms=45, exact=True)
        # Preserve extra metadata like `deps_sha256` across aggregate `sert run --coverage` (`exact=False`)
        cov_map = graph.load_coverage_map(self.root)
        cov_map["specs"][spec]["deps_sha256"] = "abc123"
        graph.save_coverage_map(self.root, cov_map)

        updated = graph.record_spec_coverage(
            self.root,
            spec,
            {"src/core/math.luau": {2: True}, "src/unrelated.luau": {1: True}},
            ms=52,
            exact=False,
        )
        entry = updated["specs"][spec]
        self.assertNotIn("exact", entry)
        self.assertEqual(entry["ms"], 52)
        self.assertEqual(entry["deps_sha256"], "abc123")
        self.assertEqual(entry["files"], {"src/core/math.luau": [2, 3]})
        self.assertEqual(cfg.root, self.root)

    def test_persistent_graph_cache_extends_env_chains_and_meta_snap_invalidation(self) -> None:
        cfg = self._build_sample_repo()
        # 1. Persistent `.sert/graph-cache.json`: second build skips `extract_requires` on unchanged files.
        with mock.patch("sert.graph.extract_requires", wraps=graph.extract_requires) as spy_extract:
            g1 = graph.build_graph(self.root, cfg)
            first_calls = spy_extract.call_count
        self.assertGreater(first_calls, 0)
        self.assertTrue((self.root / ".sert/graph-cache.json").is_file())

        with mock.patch("sert.graph.extract_requires", wraps=graph.extract_requires) as spy_extract2:
            g2 = graph.build_graph(self.root, cfg)
            self.assertEqual(spy_extract2.call_count, 0)
        self.assertEqual(g1.forward, g2.forward)

        # Edit one file -> only 1 file re-tokenized; delete a file -> pruned from cache
        math_path = self.root / "src/core/math.luau"
        st_before = math_path.stat()
        _write(math_path, 'local Base = require("./base")\n-- modified body\nreturn Base\n')
        os.utime(math_path, ns=(st_before.st_atime_ns, st_before.st_mtime_ns + 2_000_000))
        _write(self.root / "src/temp_ephemeral.luau", "return 1\n")
        graph.build_graph(self.root, cfg)
        (self.root / "src/temp_ephemeral.luau").unlink()

        with mock.patch("sert.graph.extract_requires", wraps=graph.extract_requires) as spy_extract3:
            _write(math_path, 'local Base = require("./base")\n-- modified again\nreturn Base\n')
            os.utime(math_path, ns=(st_before.st_atime_ns, st_before.st_mtime_ns + 4_000_000))
            graph.build_graph(self.root, cfg)
            self.assertEqual(spy_extract3.call_count, 1)
        cache_data = json.loads((self.root / ".sert/graph-cache.json").read_text(encoding="utf-8"))
        self.assertNotIn("src/temp_ephemeral.luau", cache_data["files"])

        # 2. `.luaurc` `extends` inheritance (relative parent + cycle safety) + headless `env.*` require resolution
        ext_root = self.tmp / "ext_repo"
        ext_root.mkdir()
        _write(ext_root / "base/.luaurc", json.dumps({"aliases": {"shared": "./lib", "overrideMe": "./lib"}}))
        _write(
            ext_root / ".luaurc",
            json.dumps({"extends": "base/.luaurc", "aliases": {"overrideMe": "custom"}}),
        )
        _write(ext_root / "base/lib/util.luau", "return 1\n")
        _write(ext_root / "custom/util.luau", "return 2\n")
        loaded_aliases = graph.load_luaurc_aliases(ext_root)
        self.assertEqual(loaded_aliases["shared"], (ext_root / "base/lib").resolve())
        self.assertEqual(loaded_aliases["overrideMe"], (ext_root / "custom").resolve())

        # Circular `extends` terminates cleanly
        _write(ext_root / "cyc_a/.luaurc", json.dumps({"extends": "../cyc_b/.luaurc", "aliases": {"a": "."}}))
        _write(ext_root / "cyc_b/.luaurc", json.dumps({"extends": "../cyc_a/.luaurc", "aliases": {"b": "."}}))
        cyc_aliases = graph.load_luaurc_aliases(ext_root, ext_root / "cyc_a")
        self.assertIn("a", cyc_aliases)
        self.assertIn("b", cyc_aliases)

        # Headless `env.game`, `env:getService(...)`, `env.workspace`, and `env:require(...)`
        _write(self.root / "src/WorldMod.luau", "return { ok = true }\n")
        _write(
            self.root / "default.project.json",
            json.dumps(
                {
                    "name": "Sample",
                    "tree": {
                        "$className": "DataModel",
                        "ReplicatedStorage": {"Pkg": {"$path": "src"}},
                        "Workspace": {"WorldMod": {"$path": "src/WorldMod.luau"}},
                    },
                }
            ),
        )
        _write(
            self.root / "test/headless_env.spec.luau",
            "\n".join(
                [
                    "local env = sert.env.new()",
                    'local RS = env.game:GetService("ReplicatedStorage")',
                    'local M1 = env:require(RS:WaitForChild("Pkg").core.math)',
                    'local M2 = require(env:getService("ReplicatedStorage"):WaitForChild("Pkg").core.base)',
                    "local W1 = env:require(env.workspace.WorldMod)",
                    "return { M1, M2, W1 }",
                ]
            )
            + "\n",
        )
        g_env = graph.build_graph(self.root, cfg)
        env_deps = g_env.dependencies("test/headless_env.spec.luau", transitive=False)
        self.assertEqual(env_deps, {"src/core/math.luau", "src/core/base.luau", "src/WorldMod.luau"})

        # 3. `.snap`, `Foo.meta.json`, `init.meta.json`, and `.sert-regressions.toml` invalidation
        all_specs = graph.discover_specs(self.root, cfg)
        snap_imp = graph.affected_specs_for_files(self.root, cfg, {"test/__snapshots__/fast.snap"}, all_specs=all_specs, dep_graph=g_env)
        self.assertEqual(snap_imp, ["test/fast.spec.luau"])

        meta_imp = graph.affected_specs_for_files(self.root, cfg, {"src/shared/types.meta.json"}, all_specs=all_specs, dep_graph=g_env)
        self.assertEqual(
            meta_imp,
            ["test/fast.spec.luau", "test/headless_env.spec.luau", "test/nested.spec.luau", "test/slow.spec.luau"],
        )

        init_meta_imp = graph.affected_specs_for_files(self.root, cfg, {"src/core/init.meta.json"}, all_specs=all_specs, dep_graph=g_env)
        self.assertIn("test/fast.spec.luau", init_meta_imp)
        self.assertNotIn("test/isolated.spec.luau", init_meta_imp)

        reg_imp = graph.affected_specs_for_files(self.root, cfg, {"test/.sert-regressions.toml"}, all_specs=all_specs, dep_graph=g_env)
        self.assertEqual(reg_imp, sorted(all_specs))


if __name__ == "__main__":
    unittest.main()
