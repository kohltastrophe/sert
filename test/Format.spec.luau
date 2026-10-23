--!nonstrict
-- Value formatting, structural diffs, JSON codec, and byte buffer helpers.

local sert = require("../src")
local format = require("../src/format")
local bytes = sert.bytes
local test = sert.test
local expect = sert

-- format.diff's message for two values that differ.
local function diffText(actual: any, expected: any, raw: boolean?): string
	local text = format.diff(actual, expected, raw)
	assert(text ~= nil, "the values differ")
	return text
end

test("format · repr sorts keys: numbers ascending, then strings, then the rest", function()
	sert.eq(
		format.repr({ b = 1, a = 2, [3] = "c", [1] = "a", [true] = 0 }),
		'{ "a", [3] = "c", a = 2, b = 1, [true] = 0 }'
	)
	sert.eq(format.repr({ [10] = 1, [-1] = 2, [2.5] = 3 }), "{ [-1] = 2, [2.5] = 3, [10] = 1 }")
	local wide = {}
	for index = 1, 20 do
		wide[`k{string.format("%02d", index)}`] = index
	end
	sert.eq(format.repr(wide), "{ k01 = 1, k02 = 2, k03 = 3, k04 = 4, k05 = 5, k06 = 6, k07 = 7, k08 = 8, … }")
end)

test("format · repr names a vector's type, so it does not read as array items", function()
	local nativeVector: any = vector
	if nativeVector == nil or (game :: any) ~= nil then return end
	sert.eq(format.repr({ v = nativeVector.create(1, 2, 3), w = 4 }), "{ v = vector(1, 2, 3), w = 4 }")
	sert.eq(
		diffText(nativeVector.create(1, 2, 3), nativeVector.create(1, 2, 4)),
		"expected vector(1, 2, 4), got vector(1, 2, 3)"
	)
	local proxy = newproxy(false)
	sert.eq(format.repr(proxy), tostring(proxy), "a plain userdata describes itself")
end)

test("format · repr prints a datatype double as the datatype it stands for", function()
	local Datatypes = require("../src/doubles/datatypes")
	sert.eq(format.repr(Datatypes.Vector3.new(1, 2, 3)), "Vector3(1, 2, 3)")
	sert.eq(format.repr({ size = Datatypes.UDim2.new(1, 2, 3, 4) }), "{ size = UDim2({1, 2}, {3, 4}) }")
	sert.eq(format.repr(Datatypes.Enum.KeyCode.A), "Enum.KeyCode.A")
	sert.eq(format.repr(Datatypes.Random.new(1)), "Random(Random)")
	local diff = diffText(Datatypes.Vector3.new(1, 2, 3), Datatypes.Vector3.new(1, 2, 4))
	sert.eq(diff, "expected Vector3(1, 2, 4), got Vector3(1, 2, 3)", "no rawEq hint for a datatype")
	local class = setmetatable({ x = 1 }, { __type = "Thing" })
	sert.eq(format.repr(class), "{ x = 1 }", "a __type without a __tostring is no datatype")
	local raising = setmetatable({ x = 1 }, {
		__type = "Thing",
		__tostring = function() error("boom", 0) end,
	})
	sert.eq(format.repr(raising), "{ x = 1 }", "a raising __tostring falls back to the fields")
end)

test("format · errorText never raises, whatever the error's __tostring does", function()
	local raising = setmetatable({}, {
		__tostring = function() error("boom in tostring", 0) end,
	})
	sert.eq(format.errorText(raising), "<table error; rendering it raised: boom in tostring>")
	local badKey = setmetatable({}, {
		__tostring = function() error({ code = 1 }) end,
	})
	-- repr sorts keys by tostring, so a raising key reaches the fallback too
	sert.eq(format.errorText({ [badKey] = 1, [{}] = 2 }), "<table error; rendering it raised: table>")
end)

test("format · diff is nil for values sert.eq accepts", function()
	expect(format.diff({ a = { 1, 2 }, b = "x" }, { b = "x", a = { 1, 2 } }) == nil, "records by structure")
	expect(format.diff(0 / 0, 0 / 0) == nil, "NaN equals NaN")
	expect(format.diff({ n = 0 / 0 }, { n = 0 / 0 }) == nil, "nested NaN")
	expect(format.diff(buffer.fromstring("ab"), buffer.fromstring("ab")) == nil, "buffers by content")
	local object = setmetatable({}, {})
	expect(format.diff({ object }, { object }) == nil, "the same object")
	local cycleA, cycleB = {}, {}
	cycleA.self, cycleB.self = cycleA, cycleB
	expect(format.diff(cycleA, cycleB) == nil, "cycles terminate")
	local eqMeta = {
		__eq = function() return true end,
	}
	expect(format.diff(setmetatable({ 1 }, eqMeta), setmetatable({ 2 }, eqMeta)) == nil, "__eq")
end)

test("format · diff names the path to the first difference and both sides", function()
	local message = diffText(
		{ players = { { name = "x" }, { name = "y" }, { name = "a", hp = 3 } }, z = 1 },
		{ players = { { name = "x" }, { name = "y" }, { name = "b", hp = 3 } }, z = 1 }
	)
	sert.eq(
		message,
		table.concat({
			'at .players[3].name: expected "b", got "a"',
			'  expected: { players = { { name = "x" }, { name = "y" }, { hp = 3, name = "b" } }, z = 1 }',
			'  actual:   { players = { { name = "x" }, { name = "y" }, { hp = 3, name = "a" } }, z = 1 }',
		}, "\n")
	)
	sert.eq(diffText(1, 2), "expected 2, got 1", "a top-level difference has no path")
	sert.eq(diffText({}, { k = 1 }):match("^[^\n]*"), "at .k: expected 1, got nil", "a missing key")
	sert.eq(diffText({ k = 1 }, {}):match("^[^\n]*"), "at .k: expected nil, got 1", "an extra key")
	sert.eq(diffText({ ["a b"] = 1 }, { ["a b"] = 2 }):match("^[^\n]*"), 'at ["a b"]: expected 2, got 1')
	expect(
		string.find(
			diffText(buffer.fromstring("abc"), buffer.fromstring("abd")),
			"first different byte at offset 2",
			1,
			true
		),
		"a buffer names its first different byte"
	)
	expect(
		string.find(diffText(setmetatable({}, {}), setmetatable({}, {})), "identity or __eq", 1, true),
		"objects compare by identity"
	)
	expect(
		string.find(diffText(setmetatable({}, {}), setmetatable({}, {})), "sert.rawEq and toRawEqual", 1, true),
		"and the note names the raw comparison"
	)
	expect(format.diff(setmetatable({ 1 }, {}), setmetatable({ 1 }, {}), true) == nil, "raw compares fields")
	sert.eq(
		diffText(setmetatable({ 1 }, {}), setmetatable({ 2 }, {}), true):match("^[^\n]*"),
		"at [1]: expected 2, got 1",
		"raw walks into objects"
	)

	-- the path stays visible past the item and depth limits
	local long, other = {}, {}
	for index = 1, 40 do
		long[index], other[index] = index, index
	end
	other[37] = "x"
	local longMessage = diffText(long, other)
	expect(string.find(longMessage, '…, [37] = "x" }', 1, true), longMessage)
	local deep = diffText(
		{ a = { b = { c = { d = { e = { f = 1 } } } } } },
		{ a = { b = { c = { d = { e = { f = 2 } } } } } }
	)
	expect(string.find(deep, "at .a.b.c.d.e.f: expected 2, got 1", 1, true), deep)
	expect(string.find(deep, "{ f = 1 }", 1, true), deep)
end)

sert.test("format · repr and diff read tables with next, never calling __iter", function()
	local function boom(): any error("__iter called") end
	local wrapped = setmetatable({ value = 1 }, { __iter = boom })
	sert.eq(format.repr(wrapped), "{ value = 1 }")
	local endless = setmetatable({ 1, 2 }, {
		__iter = function()
			return function() return 1, 1 end
		end,
	})
	sert.eq(format.repr({ endless }), "{ { 1, 2 } }")
	sert.matches(diffText({ a = wrapped }, { a = 1 }), "at .a")
	sert(format.diff(wrapped, setmetatable({ value = 1 }, { __iter = boom }), true) == nil)
end)

test("bytes · hex and fromHex round-trip", function()
	local b = bytes.fromHex("00 ff 10\n7a")
	expect(buffer.len(b) == 4)
	sert.eq(bytes.hex(b), "00ff107a")
	sert.eq(bytes.hex(b, 1, 2), "ff10")
	sert.eq(bytes.hex(buffer.create(0)), "")
	sert.fails(function() bytes.fromHex("abc") end, "even length")
	sert.fails(function() bytes.fromHex("zz") end, "invalid hex at 1")
end)

test("bytes · equal and assertBytes", function()
	expect(bytes.equal(bytes.fromHex("0102"), bytes.fromHex("0102")))
	expect(not bytes.equal(bytes.fromHex("0102"), bytes.fromHex("010203")))
	expect(not bytes.equal(bytes.fromHex("0102"), bytes.fromHex("0103")))
	local b = bytes.fromHex("ABcd")
	sert.eq(bytes.assertBytes(b, "AB CD"), b)
	sert.eq(bytes.assertBytes(b, bytes.fromHex("abcd")), b)
	local message = sert.fails(function() bytes.assertBytes(bytes.fromHex("01"), "02", "header") end)
	expect(string.find(message, "header: expected 02, got 01", 1, true), message)
	local bufMessage = sert.fails(function() bytes.assertBytes(bytes.fromHex("01"), bytes.fromHex("02"), "buf") end)
	expect(string.find(bufMessage, "buf: expected 02, got 01", 1, true), bufMessage)
end)

test("format · json lenient mode handles cyclic, shared DAG, and deeply nested tables without overflowing", function()
	local cycObj: { [string]: any } = { a = 1 }
	cycObj.self = cycObj
	sert.eq(format.json(cycObj), '{"a":1,"self":null}')

	local cycArr: { any } = { 1 }
	cycArr[2] = cycArr
	sert.eq(format.json(cycArr), "[1,null]")

	local shared = { x = 2 }
	sert.eq(format.json({ a = shared, b = shared }), '{"a":{"x":2},"b":{"x":2}}')

	local deep: { [string]: any } = {}
	local cur = deep
	for _ = 1, 105 do
		cur.next = {}
		cur = cur.next
	end
	local encodedDeep = format.json(deep)
	expect(string.find(encodedDeep, ":null}", 1, true) ~= nil)
end)

test("waitFor · uses active env clock with custom step and raises without scheduler or step", function()
	if (task :: any) == nil then
		sert.fails(function()
			sert.waitFor(function() return false end, 1)
		end, "sert.waitFor: requires Roblox task scheduler (or a step function)")
	end

	local e = sert.env.new()
	local steps = 0
	local timedOut = sert.fails(function()
		sert.waitFor(function() return nil end, 1, "virtual timeout", function()
			steps += 1
			e:advance(0.4)
		end)
	end, "virtual timeout after 1 s")
	expect(string.find(timedOut, "virtual timeout after 1 s", 1, true) ~= nil and steps == 3)
	e:shutdown()
end)

return {}
