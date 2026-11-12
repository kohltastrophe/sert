--!strict
local format = require("../src/core/format")
local sert = require("../src")

sert.describe("format.repr", function()
	sert.test("formats primitives, signed zero, NaN, control chars, and buffers", function()
		sert.eq(format.repr(nil), "nil")
		sert.eq(format.repr(true), "true")
		sert.eq(format.repr(false), "false")
		sert.eq(format.repr(0), "0")
		sert.eq(format.repr(-0.0), "-0")
		sert.eq(format.repr(0 / 0), "nan")
		sert.eq(format.repr(42), "42")
		sert.contains(format.repr('a\nb\0c"d'), "a")

		local emptyBuf = buffer.create(0)
		sert.eq(format.repr(emptyBuf), "buffer(0)")

		local smallBuf = sert.bytes.fromHex("0102ff")
		sert.eq(format.repr(smallBuf), "buffer(3) 01 02 ff")

		local largeBuf = buffer.create(36)
		buffer.writeu8(largeBuf, 0, 0xaa)
		buffer.writeu8(largeBuf, 35, 0xbb)
		local largeText = format.repr(largeBuf)
		sert.contains(largeText, "buffer(36) aa ")
		sert.contains(largeText, "… 4 more")
	end)

	sert.test("formats nested tables, deterministic key order, and truncation limits", function()
		sert.eq(format.repr({}), "{}")
		sert.eq(format.repr({ 10, 20, 30 }), "{ 10, 20, 30 }")
		sert.eq(format.repr({ b = 2, a = 1 }), "{ a = 1, b = 2 }")
		sert.eq(format.repr({ ["not-id"] = true, [1] = "first" }), '{ "first", ["not-id"] = true }')

		local deep = { a = { b = { c = { d = { e = 1 } } } } }
		sert.contains(format.repr(deep, 2), "{…}")
		sert.contains(format.repr({ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10 }), "…")
	end)

	sert.test("marks true ancestor cycles as <cycle> without mislabeling diamond DAGs", function()
		local cyclic: { [string]: any } = { name = "loop" }
		cyclic.self = cyclic
		local cyclicText = format.repr(cyclic)
		sert.contains(cyclicText, "<cycle>")

		local shared = { leaf = 7 }
		local diamond = { left = shared, right = shared }
		local diamondText = format.repr(diamond)
		sert.eq(diamondText, "{ left = { leaf = 7 }, right = { leaf = 7 } }")
		sert.eq(string.find(diamondText, "<cycle>", 1, true), nil)
	end)

	sert.test("survives throwing __tostring, custom __iter, and strict __index metatables", function()
		local badString = setmetatable({ x = 1 }, {
			__tostring = function(): string error("__tostring exploded", 0) end,
		})
		sert.eq(format.repr(badString), "<table>")

		local badKey = setmetatable({}, {
			__tostring = function(): string error("key __tostring exploded", 0) end,
		})
		local otherKey = setmetatable({}, {
			__tostring = function(): string error("other key exploded", 0) end,
		})
		local withBadKeys: { [any]: number } = { [badKey] = 1, [otherKey] = 2 }
		local renderedBadKeys = format.repr(withBadKeys)
		sert.contains(renderedBadKeys, "[<table>] = ")

		local badIter = setmetatable({ a = 1, b = 2 }, {
			__iter = function() error("__iter exploded", 0) end,
		})
		sert.eq(format.repr(badIter), "{ a = 1, b = 2 }")

		local strictTbl = setmetatable({ present = 10 }, {
			__index = function(_self: any, k: any): never error(`strict missing {tostring(k)}`, 0) end,
		})
		sert.eq(format.repr(strictTbl), "{ present = 10 }")
	end)
end)

sert.describe("format.diff", function()
	sert.test("produces path-focused diffs and returns nil when values match", function()
		sert.eq(format.diff({ a = { b = 1 } }, { a = { b = 1 } }), nil)
		sert.eq(format.diff(0 / 0, 0 / 0), nil)
		sert.eq(format.diff(-0.0, 0.0, false), nil)

		local signedDiff = format.diff(-0.0, 0.0, true)
		sert.ok(signedDiff ~= nil)
		sert.contains(signedDiff :: string, "signed zero mismatch")

		local nestedDiff = format.diff(
			{ user = { profile = { score = 10, name = "Ada" } } },
			{ user = { profile = { score = 20, name = "Ada" } } }
		)
		sert.ok(nestedDiff ~= nil)
		sert.contains(nestedDiff :: string, "at .user.profile.score: expected 20, got 10")
		sert.contains(nestedDiff :: string, "expected:")
		sert.contains(nestedDiff :: string, "actual:")

		local bufDiff = format.diff(sert.bytes.fromHex("010203"), sert.bytes.fromHex("01ff03"))
		sert.ok(bufDiff ~= nil)
		sert.contains(bufDiff :: string, "offset 1")
	end)

	sert.test("handles cyclic graphs, diamond DAGs, asymmetric matchers, and strict __index tables", function()
		local cycA: { [string]: any } = { v = 1 }
		cycA.loop = cycA
		local cycB: { [string]: any } = { v = 1 }
		cycB.loop = cycB
		sert.eq(format.diff(cycA, cycB), nil)

		local cycC: { [string]: any } = { loop = nil, tail = { wrong = 1 } }
		cycC.loop = cycC
		local cycD: { [string]: any } = { loop = nil, tail = { wrong = 2 } }
		cycD.loop = cycD
		local cycDiff = format.diff(cycC, cycD)
		sert.ok(cycDiff ~= nil)
		sert.contains(cycDiff :: string, ".tail.wrong")
		sert.contains(cycDiff :: string, "<cycle>")

		local leaf = { k = 1 }
		local dagActual = { a = leaf, b = leaf, c = 1 }
		local dagExpected = { a = { k = 1 }, b = { k = 1 }, c = 2 }
		local dagDiff = format.diff(dagActual, dagExpected)
		sert.ok(dagDiff ~= nil)
		sert.eq(string.find(dagDiff :: string, "<cycle>", 1, true), nil)

		local strictMt = {
			__index = function(_t: any, k: any): never error(`missing key {tostring(k)}`, 0) end,
		}
		local strictActual = setmetatable({ a = 1 }, strictMt)
		local strictExpected = setmetatable({ a = 1, b = 2 }, strictMt)

		local metaDiff = format.diff(strictActual, strictExpected, false)
		sert.ok(metaDiff ~= nil)
		sert.contains(metaDiff :: string, "sert.exact")

		local rawStrictDiff = format.diff(strictActual, strictExpected, true)
		sert.ok(rawStrictDiff ~= nil)
		sert.contains(rawStrictDiff :: string, "at .b: expected 2, got nil")

		local subsetStrictDiff = format.diff(strictActual, sert.subset({ a = 1, missing = 9 }), false)
		sert.ok(subsetStrictDiff ~= nil)
		sert.contains(subsetStrictDiff :: string, ".missing")

		local matcherDiff = format.diff({ count = "nope" }, { count = sert.any("number") })
		sert.ok(matcherDiff ~= nil)
		sert.contains(matcherDiff :: string, 'any("number")')
	end)
end)

sert.describe("format.json, format.jsonDecode, and format.errorText", function()
	sert.test("encodes and decodes arrays, sorted objects, escapes, surrogate pairs, and revivers", function()
		sert.eq(format.json({}), "{}")
		sert.eq(format.json(format.array({})), "[]")
		sert.eq(format.json({ 1, 2, 3 }), "[1,2,3]")
		sert.eq(format.json({ z = true, a = 'hi\n\t\1"\\' }), '{"a":"hi\\n\\t\\u0001\\"\\\\","z":true}')

		local emojiJson = '"\\ud83d\\ude80"'
		sert.eq(format.jsonDecode(emojiJson), "\240\159\154\128")

		local round = format.jsonDecode(format.json({
			arr = { 1, -2, 3.5 },
			flags = { ok = true, off = false },
			text = "line1\r\nline2\b\f",
		}))
		sert.eq(round, {
			arr = { 1, -2, 3.5 },
			flags = { ok = true, off = false },
			text = "line1\r\nline2\b\f",
		})

		local revived = format.jsonDecode('{"__vec":[3,4]}', {
			revive = function(obj: { [string]: any }): any
				if obj.__vec ~= nil then return { x = obj.__vec[1], y = obj.__vec[2] } end
				return obj
			end,
		})
		sert.eq(revived, { x = 3, y = 4 })

		local bufJson = format.json(sert.bytes.fromHex("cafe"), {
			buffer = function(b: buffer): string return `"{sert.bytes.hex(b)}"` end,
		})
		sert.eq(bufJson, '"cafe"')
	end)

	sert.test("enforces strict JSON rules on NaN, Inf, cycles, mixed keys, and malformed JSON text", function()
		sert.eq(format.json(0 / 0), "null")
		sert.eq(format.json(math.huge), "null")
		sert.throws(function() format.json(0 / 0, { strict = true }) end, "non-finite")
		sert.throws(function() format.json(math.huge, { strict = true }) end, "non-finite")
		sert.throws(function() format.json(-math.huge, { strict = true }) end, "non-finite")
		sert.throws(function() format.json({ [1] = "a", key = "b" }, { strict = true }) end, "mixed")
		sert.throws(function()
			format.json(function() end, { strict = true })
		end, "can't convert")

		local cyc: { [string]: any } = {}
		cyc.self = cyc
		sert.eq(format.json({ a = cyc }), '{"a":{"self":null}}')
		sert.throws(function() format.json(cyc, { strict = true }) end, "nesting too deep")

		sert.throws(function() format.jsonDecode('{"unterminated') end, "unterminated string")
		sert.throws(function() format.jsonDecode('"\\u12zz"') end, "invalid \\u escape")
		sert.throws(function() format.jsonDecode("123 extra") end, "trailing characters")
		sert.throws(function() format.jsonDecode("undefined") end, "invalid JSON")
	end)

	sert.test("formats error values safely even when __tostring throws", function()
		sert.eq(format.errorText("plain failure"), "plain failure")
		sert.eq(format.errorText({ code = 404 }), "{ code = 404 }")

		local customErr = setmetatable({}, {
			__tostring = function(): string return "custom error text" end,
		})
		sert.eq(format.errorText(customErr), "custom error text")

		local brokenErr = setmetatable({}, {
			__tostring = function(): string error("broken error tostring", 0) end,
		})
		sert.eq(format.errorText(brokenErr), "<table error>")
	end)
end)
