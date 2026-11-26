"""Unit and end-to-end tests for `sert fuzz`: instrumentation, dictionary extraction, greybox driver, corpus, and regressions."""

from __future__ import annotations

import argparse
import contextlib
import io
import json
import subprocess
import tomllib
import unittest
from pathlib import Path

from helpers import REPO, Case, copy_sert_src, have
from sert import cli, fuzz, mutate


def _run_fuzz_cli(*argv: str) -> tuple[int, str, str]:
    parser, sub = cli._base_parser()
    fuzz.add_parser(sub)
    cli._add_root(parser)
    args = parser.parse_args(["fuzz", *argv])
    out_buf, err_buf = io.StringIO(), io.StringIO()
    with contextlib.redirect_stdout(out_buf), contextlib.redirect_stderr(err_buf):
        code = fuzz.main(args)
    return code, out_buf.getvalue(), err_buf.getvalue()


class FuzzCorpusTest(Case):
    def test_v1_token_codec_and_regressions_toml_roundtrip(self):
        self.assertEqual(fuzz.encode_v1_token(42, 40, []), "v1:42:40:")
        self.assertEqual(fuzz.encode_v1_token(99, 10, [0, 1, 0xFFFFFFFF]), "v1:99:10:0000000000000001ffffffff")
        self.assertEqual(fuzz.decode_v1_token("v1:99:10:0000000000000001FFFFFFFF"), (99, 10, [0, 1, 0xFFFFFFFF]))
        self.assertEqual(fuzz.decode_v1_token("v1:7:40:"), (7, 40, []))
        self.assertEqual(fuzz.decode_v1_token("v1:42:40:0,12,7"), (42, 40, [0, 12, 7]))
        for bad in ("", "v2:1:2:", "v1:abc:2:00000000", "v1:1:2:0000", "v1:1:2:zzzzzzzz"):
            self.assertIsNone(fuzz.decode_v1_token(bad), bad)

        root = self.tmp / "reg_proj"
        root.mkdir()
        self.assertEqual(fuzz.load_regressions_toml(root), {})

        tok1 = fuzz.encode_v1_token(1, 40, [0, 123456])
        tok2 = fuzz.encode_v1_token(2, 40, [1, 7])
        self.assertTrue(fuzz.save_regression_token(root, 'prop "A"\\line\n1', "test/a.spec.luau", tok1))
        # Exact duplicate returns False and does not duplicate
        self.assertFalse(fuzz.save_regression_token(root, 'prop "A"\\line\n1', "test/a.spec.luau", tok1))
        self.assertTrue(fuzz.save_regression_token(root, "prop B", "test/b.spec.luau", tok2))

        toml_path = root / "test" / ".sert-regressions.toml"
        self.assertTrue(toml_path.is_file())
        parsed = tomllib.loads(toml_path.read_text(encoding="utf-8"))
        self.assertEqual(len(parsed["regression"]), 2)
        loaded = fuzz.load_regressions_toml(root)
        self.assertEqual(loaded['prop "A"\\line\n1'], [tok1])
        self.assertEqual(loaded["prop B"], [tok2])

    def test_line_preserving_instrumentation_and_dictionary_extraction(self):
        source = "\n".join(
            [
                "--!strict",
                "type Pair<T> = { a: T, b: T }",
                "local M = {}",
                'local MAGIC = "OPEN_SESAME"',
                "local SHORT = 'x'",
                'local DEP = "@sert"',
                "function M.check<T>(x: number, y: number, s: string, flag: boolean): boolean",
                "\tlocal pick = if flag then 1 else 2",
                "\tif x > 10 and (y == 123456 or y == -999) then",
                "\t\treturn true",
                "\telseif s == MAGIC then",
                "\t\treturn true",
                "\tend",
                "\tlocal acc = pick",
                "\twhile acc < 0xCAFE do",
                "\t\tacc += 1",
                "\tend",
                "\tfor i = 1, 5 do",
                "\t\tacc += i",
                "\tend",
                "\trepeat",
                "\t\tacc -= 1",
                "\tuntil acc <= 0",
                "\treturn (x < y) == true",
                "end",
                "return M",
            ]
        )
        inst, meta = fuzz.instrument_fuzz_source(source, file_path="src/Gate.luau")
        self.assertEqual(len(inst.splitlines()), len(source.splitlines()))
        self.assertEqual(meta["edges"], 5)  # if, elseif, while, for, repeat (NOT ternary `if flag then 1 else 2`!)
        self.assertGreaterEqual(meta["cmps"], 7)

        inst_lines = inst.splitlines()
        # Line 8 ternary MUST NOT contain __SERT_FUZZ_EDGE
        self.assertNotIn("__SERT_FUZZ_EDGE", inst_lines[7])
        for line_num in (9, 11, 15, 18, 21):
            self.assertIn("__SERT_FUZZ_EDGE", inst_lines[line_num - 1], f"line {line_num}: {inst_lines[line_num - 1]}")
        for line_num in (9, 11, 15, 23, 24):
            self.assertIn("__SERT_FUZZ_CMP", inst_lines[line_num - 1], f"line {line_num}: {inst_lines[line_num - 1]}")

        # Dictionary: captures len 2..64 non-import strings and non-trivial numeric constants
        self.assertIn("OPEN_SESAME", meta["strings"])
        self.assertNotIn("x", meta["strings"])
        self.assertNotIn("@sert", meta["strings"])
        self.assertIn(123456, meta["numbers"])
        self.assertIn(-999, meta["numbers"])
        self.assertIn(0xCAFE, meta["numbers"])
        self.assertNotIn(1, meta["numbers"])
        self.assertNotIn(2, meta["numbers"])
        self.assertNotIn(0, meta["numbers"])

        if have("luau"):
            chk_dir = self.tmp / "chk"
            chk_dir.mkdir()
            validated, val_meta = fuzz.instrument_and_validate(
                "luau",
                source,
                file_path="src/Gate.luau",
                start_edge_id=1,
                start_cmp_id=1,
                check_dir=chk_dir,
            )
            self.assertTrue(fuzz._check_luau_compiles("luau", validated, chk_dir))
            self.assertEqual(val_meta["edges"], 5)
            self.assertGreaterEqual(val_meta["cmps"], 7)

            # Verify runtime fallback behavior when `_G.__SERT_FUZZ` is nil
            runner = self.tmp / "run_fallback.luau"
            runner.write_text(validated + "\n", encoding="utf-8")
            probe = self.tmp / "call_fallback.luau"
            probe.write_text(
                f'local M = require("./run_fallback")\n'
                'assert(M.check(15, 123456, "", false) == true)\n'
                'assert(M.check(0, 0, "OPEN_SESAME", true) == true)\n',
                encoding="utf-8",
            )
            res = subprocess.run(["luau", "--codegen", str(probe)], capture_output=True, text=True)
            self.assertEqual(res.returncode, 0, res.stderr + res.stdout)

    @unittest.skipUnless(have("luau"), "luau not fetched or on PATH")
    def test_greybox_afl_buckets_magic_integer_and_string_discovery(self):
        root = self.project(
            '[test]\nspecs = ["test/**/*.spec.luau"]\n[coverage]\ninclude = ["src"]\n',
            name="fuzz_discover",
        )
        copy_sert_src(root / ".sert/repo/src")
        (root / ".luaurc").write_text('{"aliases": {"sert": "./.sert/repo/src", "lib": "./src"}}\n')
        (root / "src").mkdir()
        gate_src = "\n".join(
            [
                "--!strict",
                "local Gate = {}",
                "function Gate.checkNumber(a: number, b: number): boolean",
                "\tif a > 10 then",
                "\t\tif b == 123456 then",
                '\t\t\tif (a + b) == 123500 then',
                "\t\t\t\treturn false",
                "\t\t\tend",
                "\t\tend",
                "\tend",
                "\treturn true",
                "end",
                'function Gate.checkSecret(s: string): boolean',
                '\tif s == "OPEN_SESAME" then',
                "\t\treturn false",
                "\tend",
                "\treturn true",
                "end",
                "function Gate.safeAdd(x: number, y: number): number",
                "\treturn x + y",
                "end",
                "return Gate",
            ]
        ) + "\n"
        (root / "src/Gate.luau").write_text(gate_src, encoding="utf-8")
        (root / "test").mkdir()
        (root / "test/gate.spec.luau").write_text(
            "\n".join(
                [
                    'local sert = require("@sert")',
                    'local Gate = require("@lib/Gate")',
                    'sert.prop("safe commutativity", function(g)',
                    "\tlocal a = g:int(-100, 100)",
                    "\tlocal b = g:int(-100, 100)",
                    "\tsert.eq(Gate.safeAdd(a, b), Gate.safeAdd(b, a))",
                    "end)",
                    'sert.prop("deep numeric guard", function(g)',
                    "\tlocal a = g:int(-1000, 1000)",
                    "\tlocal b = g:int(-1000000, 1000000)",
                    '\tg:note("a=" .. tostring(a) .. " b=" .. tostring(b))',
                    '\tsert.ok(Gate.checkNumber(a, b), "hit magic gate")',
                    "end)",
                    'sert.prop("magic string guard", function(g)',
                    "\tlocal s = g:string()",
                    '\tg:note("s=" .. s)',
                    '\tsert.ok(Gate.checkSecret(s), "hit secret")',
                    "end)",
                    "return {}",
                ]
            )
            + "\n"
        )

        # 1. Passing subset via `--filter` + `--format json` + `--runs`
        code_ok, out_ok, err_ok = _run_fuzz_cli("--root", str(root), "--filter", "safe commutativity", "--runs", "40", "--seed", "7", "--format", "json")
        self.assertEqual(code_ok, 0, err_ok + out_ok)
        env_ok = json.loads(out_ok)
        self.assertEqual((env_ok["command"], env_ok["status"], env_ok["summary"]["passed"], env_ok["summary"]["failed"]), ("fuzz", "ok", 1, 0))
        self.assertEqual(env_ok["summary"]["iterations"], 40)
        # Overlay cleaned up and original src untouched
        self.assertFalse((root / ".sert/fuzz/overlay").exists())
        self.assertEqual((root / "src/Gate.luau").read_text(encoding="utf-8"), gate_src)
        self.assertTrue((root / ".sert/fuzz/dict.json").is_file())
        dict_data = json.loads((root / ".sert/fuzz/dict.json").read_text(encoding="utf-8"))
        self.assertIn("OPEN_SESAME", dict_data["strings"])
        self.assertIn(123456, dict_data["numbers"])

        # 2. `--no-save-regressions` finds BOTH `123456` magic number bug AND `"OPEN_SESAME"` magic string bug in --agent mode!
        code_ns, out_ns, err_ns = _run_fuzz_cli(
            "--root", str(root), "--filter", "deep numeric guard", "--budget", "3.0", "--seed", "42", "--no-save-regressions", "--agent"
        )
        self.assertEqual(code_ns, 1, err_ns + out_ns)
        self.assertIn("FAIL fuzz", out_ns)
        self.assertIn("a=44 b=123456", out_ns)
        self.assertIn('regressions = { "v1:', out_ns)
        self.assertFalse((root / "test/.sert-regressions.toml").exists())

        # 3. Normal run saves regression tokens for both deep numeric & magic string guards, AND persists corpus seeds
        code_fail, out_fail, err_fail = _run_fuzz_cli(
            "--root", str(root), "--budget", "4.0", "--seed", "123", "--format", "json"
        )
        self.assertEqual(code_fail, 1, err_fail + out_fail)
        env_fail = json.loads(out_fail)
        self.assertEqual(env_fail["status"], "failed")
        self.assertGreaterEqual(env_fail["summary"]["failed"], 2)
        self.assertGreater(env_fail["summary"]["edges_covered"], 0)
        reg_map = fuzz.load_regressions_toml(root)
        self.assertIn("deep numeric guard", reg_map)
        self.assertIn("magic string guard", reg_map)
        corpus_files = list((root / ".sert/fuzz/corpus").rglob("*.json"))
        self.assertGreater(len(corpus_files), 0)

        # 4. Subsequent run loads existing corpus seeds + custom `--dict`
        extra_dict = self.tmp / "extra_dict.json"
        extra_dict.write_text(json.dumps({"strings": ["EXTRA_KEY"], "numbers": [424242]}))
        code_replay, out_replay, err_replay = _run_fuzz_cli(
            "--root", str(root), "test/gate.spec.luau", "--filter", "magic string guard", "--dict", str(extra_dict), "--budget", "2.0", "--seed", "1"
        )
        self.assertEqual(code_replay, 1, err_replay + out_replay)
        self.assertIn("FAIL magic string guard", out_replay)
        self.assertIn("v1:", out_replay)

    @unittest.skipUnless(have("luau"), "luau not fetched or on PATH")
    def test_fuzz_ctrl_afl_buckets_cmp_protocol_and_grep_file_entries(self) -> None:
        # Part A: `[test].entries` fallback + direct `_G.__SERT_FUZZ` / `fuzzCtrl` AFL hit-bucket & cmp protocol
        ent_root = self.project('[test]\nentries = ["test/entry.client.luau"]\n', name="entries_proj")
        copy_sert_src(ent_root / ".sert/repo/src")
        (ent_root / ".luaurc").write_text('{"aliases": {"sert": "./.sert/repo/src"}}\n')
        (ent_root / "src").mkdir()
        (ent_root / "test").mkdir()
        (ent_root / "test/entry.client.luau").write_text(
            "\n".join(
                [
                    'local sert = require("@sert")',
                    'local okRt, rt: any = pcall(require, "@__SERT_FUZZ")',
                    'assert(okRt and type(rt) == "table" and type(rt.ctrl) == "table", "missing @__SERT_FUZZ.ctrl")',
                    "local ctrl = rt.ctrl",
                    'assert(type(ctrl.edge) == "function" and type(ctrl.cmp) == "function")',
                    'assert(type(ctrl.score) == "function" and type(ctrl.bestCmp) == "function")',
                    'assert(type(ctrl.reset) == "function" and type(ctrl.step) == "function")',
                    'assert(type(ctrl.dict) == "table")',
                    "ctrl.reset()",
                    "local function hitNTimes(edgeId: number, n: number): (boolean, boolean)",
                    "\tfor i = 1, n do ctrl.edge(edgeId) end",
                    "\treturn ctrl.step()",
                    "end",
                    "-- Verify exact AFL buckets: 1, 2, 3, 4-7, 8-15, 16-31, 32+",
                    'local c1, _ = hitNTimes(777, 1); assert(c1 == true, "bucket 1")',
                    'local c2, _ = hitNTimes(777, 2); assert(c2 == true, "bucket 2")',
                    'local c3, _ = hitNTimes(777, 3); assert(c3 == true, "bucket 3")',
                    'local c4, _ = hitNTimes(777, 4); assert(c4 == true, "bucket 4-7 start")',
                    'local c5, _ = hitNTimes(777, 5); assert(c5 == false, "bucket 4-7 same bucket")',
                    'local c7, _ = hitNTimes(777, 7); assert(c7 == false, "bucket 4-7 upper bound")',
                    'local c8, _ = hitNTimes(777, 8); assert(c8 == true, "bucket 8-15")',
                    'local c16, _ = hitNTimes(777, 16); assert(c16 == true, "bucket 16-31")',
                    'local c32, _ = hitNTimes(777, 32); assert(c32 == true, "bucket 32+")',
                    'assert(ctrl.score() == 1, "one edge tracked")',
                    "-- Verify comparison distance monotonicity and bestCmp",
                    'assert(ctrl.cmp(888, "==", 10, 15) == false)',
                    "local _, d1 = ctrl.step(); assert(d1 == true)",
                    'assert(ctrl.cmp(888, "==", 10, 12) == false)',
                    "local _, d2 = ctrl.step(); assert(d2 == true)",
                    'assert(ctrl.cmp(888, "==", 10, 14) == false)',
                    "local _, d3 = ctrl.step(); assert(d3 == false)",
                    "assert(ctrl.bestCmp() >= 1)",
                    "ctrl.reset()",
                    "assert(ctrl.score() == 0 and ctrl.bestCmp() == 0)",
                    'sert.prop("entry prop", function(g)',
                    "\tlocal x = g:int(-10, 10)",
                    "\tsert.ok(x + 0 == x)",
                    "end)",
                    "sert.run()",
                ]
            )
            + "\n"
        )
        code_ent, out_ent, err_ent = _run_fuzz_cli("--root", str(ent_root), "--runs", "10", "--seed", "5")
        self.assertEqual(code_ent, 0, err_ent + out_ent)
        self.assertIn("fuzz: OK", out_ent)
        self.assertIn("iterations=10", out_ent)

        # Part B: `--grep` and `--file` selection across multiple spec files
        mf_root = self.project('[test]\nspecs = ["test/**/*.spec.luau"]\n', name="multifile_proj")
        copy_sert_src(mf_root / ".sert/repo/src")
        (mf_root / ".luaurc").write_text('{"aliases": {"sert": "./.sert/repo/src"}}\n')
        (mf_root / "src").mkdir()
        (mf_root / "test").mkdir()
        (mf_root / "test/alpha.spec.luau").write_text(
            'local sert = require("@sert")\n'
            'sert.prop("alpha safe", function(g)\n'
            "\tsert.ok(g:int(0, 5) >= 0)\n"
            "end)\n"
            'sert.prop("alpha bad", function(_g)\n'
            '\tsert.ok(false, "boom alpha")\n'
            "end)\n"
            "return {}\n"
        )
        (mf_root / "test/beta.spec.luau").write_text(
            'local sert = require("@sert")\n'
            'sert.prop("beta bad", function(_g)\n'
            '\tsert.ok(false, "boom beta")\n'
            "end)\n"
            "return {}\n"
        )
        code_f, out_f, err_f = _run_fuzz_cli(
            "--root", str(mf_root), "--file", "test/alpha.spec.luau", "--grep", "^alpha safe$", "--runs", "12", "--seed", "9", "--format", "json"
        )
        self.assertEqual(code_f, 0, err_f + out_f)
        env_f = json.loads(out_f)
        self.assertEqual((env_f["status"], env_f["summary"]["passed"], env_f["summary"]["failed"]), ("ok", 1, 0))
        self.assertEqual(env_f["summary"]["iterations"], 12)

        # Part C: lossless v2 (53-bit) and negative-seed tape token round-trips
        big_tape = [0, 0xFFFFFFFF, 0x1_0000_0000, 9007199254740991]
        tok_v2 = fuzz.encode_tape_token(-42, 64, big_tape)
        self.assertTrue(tok_v2.startswith("v2:-42:64:"))
        self.assertEqual(fuzz.decode_tape_token(tok_v2), (-42, 64, big_tape))
        self.assertEqual(fuzz.decode_tape_token("v1:-7:10:00000005"), (-7, 10, [5]))

    def test_fuzz_regression_helpers_share_run_toml_store_and_create_parent(self) -> None:
        from sert import run as run_mod

        root = self.tmp / "shared_reg"
        root.mkdir()
        # Note: `test/` does not exist yet — `save_regression_token` creates parent directory cleanly.
        tok = fuzz.encode_v1_token(7, 40, [1, 2])
        self.assertTrue(fuzz.save_regression_token(root, "prop X", "test/sub/X.spec.luau", tok))
        self.assertTrue((root / "test/.sert-regressions.toml").is_file())
        self.assertEqual(run_mod.load_regressions_by_test(root), {"prop X": [tok]})
        self.assertEqual(fuzz.load_regressions_toml(root), {"prop X": [tok]})


if __name__ == "__main__":
    unittest.main()
