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
		sert.contains(nestedDiff :: string, "actual.user.profile.score: expected 20, got 10")
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
		sert.contains(rawStrictDiff :: string, "actual.b: expected 2, got nil")

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
		sert.eq(
			format.json({ z = true, a = 'hi\0\n\t\1\31"\\' }),
			'{"a":"hi\\u0000\\n\\t\\u0001\\u001f\\"\\\\","z":true}'
		)

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

sert.describe("format.diff multi-leaf and format.snapshot", function()
	sert.test("collects up to 8 leaf differences and summarizes remaining differences", function()
		local priceDiff = format.diff(
			{ items = { { price = 1 }, { price = 2 }, { price = 19 } } },
			{ items = { { price = 1 }, { price = 2 }, { price = 20 } } }
		)
		sert.ok(priceDiff ~= nil)
		sert.contains(priceDiff :: string, "actual.items[3].price: expected 20, got 19")

		local eightA = { a1 = 1, a2 = 2, a3 = 3, a4 = 4, a5 = 5, a6 = 6, a7 = 7, a8 = 8 }
		local eightB = { a1 = 11, a2 = 12, a3 = 13, a4 = 14, a5 = 15, a6 = 16, a7 = 17, a8 = 18 }
		local eightDiff = format.diff(eightA, eightB)
		sert.ok(eightDiff ~= nil)
		for i = 1, 8 do
			sert.contains(eightDiff :: string, `actual.a{i}: expected {10 + i}, got {i}`)
		end
		sert.eq(string.find(eightDiff :: string, "more differences", 1, true), nil)

		local elevenA = {
			k01 = 1,
			k02 = 2,
			k03 = 3,
			k04 = 4,
			k05 = 5,
			k06 = 6,
			k07 = 7,
			k08 = 8,
			k09 = 9,
			k10 = 10,
			k11 = 11,
		}
		local elevenB = {
			k01 = 101,
			k02 = 102,
			k03 = 103,
			k04 = 104,
			k05 = 105,
			k06 = 106,
			k07 = 107,
			k08 = 108,
			k09 = 109,
			k10 = 110,
			k11 = 111,
		}
		local elevenDiff = format.diff(elevenA, elevenB)
		sert.ok(elevenDiff ~= nil)
		for i = 1, 8 do
			local key = string.format("k%02d", i)
			sert.contains(elevenDiff :: string, `actual.{key}: expected {100 + i}, got {i}`)
		end
		sert.eq(string.find(elevenDiff :: string, "actual.k09", 1, true), nil)
		sert.contains(elevenDiff :: string, "… and 3 more differences")
	end)

	sert.test("serializes sorted tables, buffers, cycles, functions, datatypes, and GuiBase2d trees", function()
		sert.eq(format.snapshot(nil), "nil")
		sert.eq(format.snapshot(true), "true")
		sert.eq(format.snapshot(-0.0), "-0")
		sert.eq(format.snapshot(0 / 0), "nan")
		sert.eq(format.snapshot(function() end), "<function>")
		sert.eq(format.snapshot({}), "{}")
		sert.eq(format.snapshot(buffer.create(0)), "buffer(0)")

		local bigBuf = buffer.create(40)
		buffer.writeu8(bigBuf, 0, 0x0a)
		buffer.writeu8(bigBuf, 39, 0xfe)
		local snapBuf = format.snapshot(bigBuf)
		sert.contains(snapBuf, "buffer(40) 0a")
		sert.contains(snapBuf, "fe")

		local objA = { zebra = 2, alpha = { 10, 20 }, ["space key"] = true }
		local objB = { ["space key"] = true, alpha = { 10, 20 }, zebra = 2 }
		sert.eq(format.snapshot(objA), format.snapshot(objB))
		sert.contains(
			format.snapshot(objA),
			'  alpha = {\n    10,\n    20,\n  },\n  ["space key"] = true,\n  zebra = 2,'
		)

		local cyc: { [string]: any } = { name = "root" }
		cyc.self = cyc
		sert.contains(format.snapshot(cyc), "  self = <cycle>,")

		local env = sert.env.new()
		local v2 = sert.env.Vector2.new(12, 34)
		local v3 = sert.env.Vector3.new(1, 2.5, -3)
		local ud2 = sert.env.UDim2.fromOffset(100, 50)
		local c3 = sert.env.Color3.new(1, 0.5, 0.25)
		local nr = sert.env.NumberRange.new(0, 10)
		sert.eq(format.snapshot(v2), "Vector2.new(12, 34)")
		sert.eq(format.snapshot(v3), "Vector3.new(1, 2.5, -3)")
		sert.eq(format.snapshot(ud2), "UDim2.new(0, 100, 0, 50)")
		sert.eq(format.snapshot(c3), "Color3.new(1, 0.5, 0.25)")
		sert.eq(format.snapshot(nr), "NumberRange.new(0, 10)")
		sert.eq(format.snapshot(sert.env.UDim.new(0.5, 12)), "UDim.new(0.5, 12)")
		sert.eq(format.snapshot(sert.env.Rect.new(1, 2, 3, 4)), "Rect.new(1, 2, 3, 4)")
		sert.contains(format.snapshot(sert.env.CFrame.new(1, 2, 3)), "CFrame.new(1, 2, 3,")
		sert.contains(
			format.snapshot(sert.env.Ray.new(v3, sert.env.Vector3.new(0, 1, 0))),
			"Ray.new(Vector3.new(1, 2.5, -3)"
		)
		sert.contains(
			format.snapshot(sert.env.Region3.new(sert.env.Vector3.new(0, 0, 0), sert.env.Vector3.new(2, 4, 6))),
			"Region3.new(Vector3.new(0, 0, 0), Vector3.new(2, 4, 6))"
		)
		sert.contains(format.snapshot(sert.env.ColorSequence.new(c3)), "ColorSequence.new(")
		sert.contains(format.snapshot(sert.env.NumberSequence.new(0, 1)), "NumberSequence.new(")
		sert.contains(format.snapshot(sert.env.TweenInfo.new(0.5)), "TweenInfo.new(0.5,")
		sert.contains(format.snapshot(sert.env.BrickColor.new("Bright red")), 'BrickColor.new("Bright red")')
		sert.contains(
			format.snapshot(sert.env.DateTime.fromUnixTimestampMillis(1000)),
			"DateTime.fromUnixTimestampMillis(1000)"
		)
		sert.contains(format.snapshot(sert.env.Enum.EasingStyle.Linear), "Enum.EasingStyle.Linear")
		sert.contains(
			format.snapshot(sert.env.Font.new("rbxasset://fonts/families/SourceSansPro.json")),
			'Font.new("rbxasset://fonts/families/SourceSansPro.json"'
		)

		local screen = env.Instance.new("ScreenGui")
		screen.Name = "HUD"
		screen.Parent = env.PlayerGui
		local panel = env.Instance.new("Frame")
		panel.Name = "Panel"
		panel.Position = sert.env.UDim2.fromOffset(10, 20)
		panel.Size = sert.env.UDim2.fromOffset(200, 80)
		panel.Visible = true
		panel.Parent = screen
		local label = env.Instance.new("TextLabel")
		label.Name = "Title"
		label.Position = sert.env.UDim2.fromOffset(4, 6)
		label.Size = sert.env.UDim2.fromOffset(120, 24)
		label.Visible = false
		label.Text = "Score: 100"
		label.Parent = panel

		local uiTree = format.snapshot(screen)
		sert.contains(uiTree, 'ScreenGui "HUD"')
		sert.contains(uiTree, '  Frame "Panel" [pos=(10, 20) size=(200, 80) visible=true]')
		sert.contains(uiTree, '    TextLabel "Title" [pos=(14, 26) size=(120, 24) visible=false text="Score: 100"]')
	end)
end)
