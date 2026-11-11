"""Unit tests for `sert.luau_lex`: linear-time Luau tokenizer, nested interpolations, and generic angle disambiguation."""

from __future__ import annotations

import unittest

import helpers  # noqa: F401
from sert import luau_lex


class LuauLexerTest(unittest.TestCase):
    def test_long_comments_long_strings_and_escapes(self) -> None:
        source = (
            "--[==[\n"
            "  multi-line comment with ]=] and return 99\n"
            "]==]\n"
            "local raw = [=[hello ]] ` {not_interp} ]=]\n"
            'local esc = "a\\nb\\z\n   c"\n'
            "return raw, esc\n"
        )
        tokens = luau_lex.tokenize(source)
        comments = [t for t in tokens if t.kind == "COMMENT"]
        strings = [t for t in tokens if t.kind == "STRING"]
        self.assertEqual(len(comments), 1)
        self.assertEqual((comments[0].line, comments[0].end_line), (1, 3))
        self.assertEqual(len(strings), 2)
        self.assertEqual(strings[0].line, 4)
        self.assertEqual((strings[1].line, strings[1].end_line), (5, 6))
        self.assertTrue(luau_lex.has_top_level_return(source))

    def test_arbitrarily_nested_interpolated_strings(self) -> None:
        source = (
            "local msg = `outer { `inner { [[raw ` } str]] .. tostring({ a = 1 }.a) }` } "
            "{ -- inline ` } comment\n"
            "  x + y }`\n"
        )
        tokens = luau_lex.tokenize(source)
        kinds = [t.kind for t in tokens]
        self.assertIn("INTERP_BEGIN", kinds)
        self.assertIn("INTERP_MID", kinds)
        self.assertIn("INTERP_END", kinds)
        # Ensure `[[raw ` } str]]` inside interpolation stayed a single STRING token and `{ a = 1 }` balanced braces
        raw_strings = [t.value for t in tokens if t.kind == "STRING"]
        self.assertEqual(raw_strings, ["[[raw ` } str]]"])
        idents = [t.value for t in tokens if t.kind == "IDENT"]
        for name in ("msg", "tostring", "a", "x", "y"):
            self.assertIn(name, idents)
        self.assertNotIn("not", idents)

    def test_numbers_casts_arrows_compound_ops_and_attributes(self) -> None:
        source = (
            "@native @[checked, deprecated]\n"
            "local function step(x: number, y: number): (number) -> number\n"
            "\tlocal hex = 0xFF_00 + 0x1.8p4\n"
            "\tlocal bin = 0b1010_0101 + 1_000_000.5e-2\n"
            "\tx += hex :: number\n"
            "\tx -= 1; x *= 2; x /= 3; x //= 2; x %= 5; x ^= 2\n"
            '\tlocal s = "a"; s ..= "b"\n'
            "\treturn function(z: number) return (x // 2) + z + bin end\n"
            "end\n"
        )
        tokens = luau_lex.tokenize(source)
        attrs = [t.value for t in tokens if t.kind == "ATTR"]
        self.assertEqual(attrs, ["@native", "@[checked, deprecated]"])
        numbers = [t.value for t in tokens if t.kind == "NUMBER"]
        self.assertEqual(numbers[:4], ["0xFF_00", "0x1.8p4", "0b1010_0101", "1_000_000.5e-2"])
        ops = [t.value for t in tokens if t.kind == "OP"]
        for expected_op in ("->", "::", "+=", "-=", "*=", "/=", "//=", "%=", "^=", "..=", "//"):
            self.assertIn(expected_op, ops)

    def test_contextual_keywords(self) -> None:
        source = (
            "export type Pair<T> = { a: T, type: string }\n"
            "const LIMIT: number = 10\n"
            "local type = 'custom'\n"
            "local export = { type = 1 }\n"
            "for i = 1, LIMIT do\n"
            "\tif i == 2 then continue end\n"
            "\tcontinue(i)\n"
            "end\n"
        )
        tokens = luau_lex.tokenize(source)
        kw_positions = [(t.line, t.value) for t in tokens if t.kind == "KEYWORD" and t.value in ("export", "type", "const", "continue")]
        self.assertIn((1, "export"), kw_positions)
        self.assertIn((1, "type"), kw_positions)
        self.assertIn((2, "const"), kw_positions)
        self.assertIn((6, "continue"), kw_positions)
        # `type: string` field, `local type =`, `local export =`, and `continue(i)` call are IDENT, not KEYWORD
        ident_positions = [(t.line, t.value) for t in tokens if t.kind == "IDENT"]
        self.assertIn((1, "type"), ident_positions)
        self.assertIn((3, "type"), ident_positions)
        self.assertIn((4, "export"), ident_positions)
        self.assertIn((7, "continue"), ident_positions)

    def test_generic_call_vs_comparison_disambiguation(self) -> None:
        source = (
            "export type Box<T = number> = { v: T }\n"
            "local function id<T>(v: T): T return v end\n"
            "local a = id<number>(42)\n"
            "local b = pkg.make<Map<string, Array<number>>>(x)\n"
            "local cmp = a < b and b > 0\n"
            "local tricky = f < g and h > (1)\n"
        )
        tokens = luau_lex.tokenize(source)
        angle_tokens = [(idx, t) for idx, t in enumerate(tokens) if t.kind == "OP" and t.value in ("<", ">")]
        by_line: dict[int, list[bool]] = {}
        for idx, tok in angle_tokens:
            by_line.setdefault(tok.line, []).append(luau_lex.is_type_angle(tokens, idx))
        self.assertEqual(by_line[1], [True, True])
        self.assertEqual(by_line[2], [True, True])
        self.assertEqual(by_line[3], [True, True])
        self.assertTrue(all(by_line[4]))
        self.assertEqual(by_line[5], [False, False])
        self.assertEqual(by_line[6], [False, False])

    def test_has_top_level_return(self) -> None:
        zero_return_spec = (
            "--!strict\n"
            'local sert = require("@sert")\n'
            'sert.test("inner return only", function()\n'
            "\tlocal function helper() return 123 end\n"
            "\tsert.eq(helper(), 123)\n"
            "\treturn\n"
            "end)\n"
        )
        self.assertFalse(luau_lex.has_top_level_return(zero_return_spec))
        self.assertTrue(luau_lex.has_top_level_return(zero_return_spec + "return {}\n"))
        self.assertTrue(luau_lex.has_top_level_return("if true then return 1 else return 2 end\n"))
        self.assertFalse(luau_lex.has_top_level_return("-- return {}\nlocal s = [[return {}]]\n"))

    def test_first_code_offset_and_referenced_identifiers(self) -> None:
        src = "--!strict\n--!native\n-- leading comment\nlocal x = Vector3.new(1, 2, 3)\nreturn x\n"
        offset = luau_lex.first_code_offset(src)
        self.assertTrue(src[offset:].startswith("local x = Vector3.new"))
        refs = luau_lex.referenced_identifiers("local t = { Vector3 = 1 }\nreturn CFrame.identity, t.Vector3\n")
        self.assertIn("CFrame", refs)
        self.assertNotIn("Vector3", refs)


if __name__ == "__main__":
    unittest.main()
