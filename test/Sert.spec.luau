--!strict
local bytesCore = require("../src/core/bytes")
local rngCore = require("../src/core/rng")
local sert = require("../src")
local utilCore = require("../src/core/util")

local EXPECTED_PUBLIC_KEYS: { string } = {
	"isRoblox",
	"gen",
	"laws",
	"model",
	"env",
	"sim",
	"roblox",
	"bytes",
	"test",
	"describe",
	"prop",
	"beforeAll",
	"afterAll",
	"beforeEach",
	"afterEach",
	"defer",
	"setup",
	"ok",
	"eq",
	"ne",
	"equals",
	"lt",
	"le",
	"gt",
	"ge",
	"near",
	"matches",
	"contains",
	"throws",
	"doesNotThrow",
	"fail",
	"waitFor",
	"any",
	"subset",
	"within",
	"matching",
	"exact",
	"spy",
	"called",
	"calledTimes",
	"calledWith",
	"print",
	"warn",
	"quiet",
	"capture",
	"run",
	"parseCliArgs",
}

local REMOVED_KEYS: { string } = {
	"expect",
	"extend",
	"check",
	"doubles",
	"fn",
	"todo",
	"neq",
	"rawEq",
	"fails",
	"rtest",
	"ptest",
	"ctest",
	"loaded",
	"current",
	"isolate",
	"shard",
	"shardSelects",
	"frames",
	"describeSkip",
	"describeFocus",
}

sert.describe("sert public surface", function()
	sert.test("exposes exact 0.1.0 public key set and omits removed draft APIs", function()
		local rawSert: { [string]: any } = sert :: any
		local wanted: { [string]: boolean } = {}
		for _, key in EXPECTED_PUBLIC_KEYS do
			wanted[key] = true
			sert.ok(rawget(rawSert, key) ~= nil, `missing public key sert.{key}`)
		end

		local actualCount = 0
		for key in next, rawSert do
			actualCount += 1
			sert.ok(wanted[key] == true, `unexpected public key sert.{tostring(key)}`)
		end
		sert.eq(actualCount, #EXPECTED_PUBLIC_KEYS)
		sert.eq(type(sert.isRoblox), "boolean")

		for _, key in REMOVED_KEYS do
			sert.eq(rawget(rawSert, key), nil, `removed API sert.{key} must be nil`)
		end

		local rawBytes: { [string]: any } = sert.bytes :: any
		sert.ok(table.isfrozen(rawBytes))
		sert.eq(rawBytes.assertBytes, nil)
		sert.eq(rawBytes.equal, nil)
	end)

	sert.test("callable sert(val, msg?) returns truthy values and raises on false or nil", function()
		sert.eq(sert(42), 42)
		sert.eq(sert("ok"), "ok")
		sert.eq(sert(0), 0)
		local tbl = { x = 1 }
		sert.eq(sert(tbl), tbl)

		local errFalse = sert.throws(function() sert(false, "custom false message") end, "custom false message")
		sert.contains(errFalse, "custom false message")

		local errNil = sert.throws(function() sert(nil) end, "expected truthy value, got nil")
		sert.contains(errNil, "expected truthy value, got nil")

		local okCall, callerErr = pcall(function() sert(false, "frame check") end)
		sert.eq(okCall, false)
		sert.contains(tostring(callerErr), "Sert.spec")
	end)
end)

sert.describe("sert.bytes", function()
	sert.test("hex and fromHex round-trip buffers, strings, slices, and whitespace", function()
		local empty = sert.bytes.fromHex("")
		sert.eq(buffer.len(empty), 0)
		sert.eq(sert.bytes.hex(empty), "")
		sert.eq(sert.bytes.hex(""), "")

		local parsed = sert.bytes.fromHex("de ad\tbe\nef 00 ff")
		sert.eq(buffer.len(parsed), 6)
		sert.eq(sert.bytes.hex(parsed), "deadbeef00ff")
		sert.eq(sert.bytes.hex(parsed, 1, 3), "adbeef")
		sert.eq(sert.bytes.hex(parsed, 0, 0), "")
		sert.eq(sert.bytes.hex("AB\0\255"), "414200ff")
		sert.eq(sert.bytes.hex("ABCD", 1, 2), "4243")

		local upper = sert.bytes.fromHex("CAFEBABE")
		sert.eq(sert.bytes.hex(upper), "cafebabe")
		sert.eq(sert.bytes.fromHex(sert.bytes.hex(parsed)), parsed)
	end)

	sert.test("rejects odd-length, non-hex, out-of-bounds, and invalid-type inputs", function()
		sert.throws(function() sert.bytes.fromHex("abc") end, "even")
		sert.throws(function() sert.bytes.fromHex("0g") end, "hex")
		sert.throws(function() sert.bytes.fromHex("zz") end, "hex")
		sert.throws(function() (sert.bytes.fromHex :: any)(123) end)
		sert.throws(function() (sert.bytes.hex :: any)(123) end)

		local buf = sert.bytes.fromHex("010203")
		sert.throws(function() bytesCore.hex(buf, -1, 1) end)
		sert.throws(function() bytesCore.hex(buf, 2, 5) end)
		sert.eq(bytesCore.equal(buf, sert.bytes.fromHex("010203")), true)
		sert.eq(bytesCore.equal(buf, sert.bytes.fromHex("010204")), false)
		sert.eq(bytesCore.diff(buf, sert.bytes.fromHex("010203")), "")
		sert.contains(bytesCore.diff(buf, sert.bytes.fromHex("01ff03")), "offset 1")
		sert.contains(bytesCore.diff(buf, sert.bytes.fromHex("0102")), "length")
	end)
end)

sert.describe("output sinks", function()
	sert.test("capture and quiet route print and warn cleanly and unwind on errors", function()
		local unprintable = setmetatable({}, {
			__tostring = function(): string error("broken tostring", 0) end,
		})

		local lines = sert.capture(function()
			sert.print("alpha", 1, true)
			sert.warn("beta", nil)
			sert.print(unprintable)
			local a, b = sert.quiet(function(x: number, y: string): (number, string)
				sert.print("suppressed print")
				sert.warn("suppressed warn")
				return x + 1, y .. "!"
			end, 41, "hi")
			sert.eq(a, 42)
			sert.eq(b, "hi!")
			sert.print("omega")
		end)

		sert.eq(lines, {
			"alpha 1 true",
			"beta nil",
			"<unprintable>",
			"omega",
		})

		local outer = sert.capture(function()
			sert.print("before")
			sert.throws(function()
				sert.capture(function()
					sert.print("discarded")
					error("sink boom", 0)
				end)
			end, "sink boom")
			sert.throws(function()
				sert.quiet(function()
					sert.print("quiet boom line")
					error("quiet boom", 0)
				end)
			end, "quiet boom")
			sert.print("after")
		end)
		sert.eq(outer, { "before", "after" })
	end)
end)

sert.describe("core rng and util invariants", function()
	sert.test("rng stream is deterministic and covers full negative float intervals", function()
		local r1 = rngCore.new(12345)
		local r2 = rngCore.new(12345)
		for _ = 1, 16 do
			sert.eq(r1:int(-50, 50), r2:int(-50, 50))
		end

		local sawBelowMinusThree = false
		local sawAboveMinusThree = false
		for _ = 1, 200 do
			local f = r1:float(-5, -1)
			sert.ge(f, -5)
			sert.lt(f, -1)
			if f < -3 then
				sawBelowMinusThree = true
			else
				sawAboveMinusThree = true
			end
		end
		sert.ok(sawBelowMinusThree, "expected rng:float(-5, -1) to sample [-5, -3)")
		sert.ok(sawAboveMinusThree, "expected rng:float(-5, -1) to sample [-3, -1)")

		local cloned = r1:clone()
		sert.eq(r1:next(), cloned:next())
		local forkA1 = rngCore.new(99):fork("alpha")
		local forkA2 = rngCore.new(99):fork("alpha")
		local forkB = rngCore.new(99):fork("beta")
		sert.eq(forkA1:next(), forkA2:next())
		sert.ne(forkA1:next(), forkB:next())

		local items = { 1, 2, 3, 4, 5 }
		sert.eq(#r1:shuffle(items), 5)
		sert.contains(items, r1:pick(items))
		sert.eq(type(r1:bool(0.5)), "boolean")
		sert.eq(buffer.len(r1:bytes(12, "mixed")), 12)
	end)

	sert.test("util.copy and sortedKeys ignore custom __iter metamethods", function()
		local iterTrap = setmetatable({ b = 2, a = 1, c = 3 }, {
			__iter = function() error("__iter must never run", 0) end,
		})
		sert.eq(utilCore.sortedKeys(iterTrap :: any), { "a", "b", "c" })

		local copied = utilCore.copy(iterTrap, { keepMetatables = false })
		sert.eq(getmetatable(copied), nil)
		sert.eq(copied, { a = 1, b = 2, c = 3 })
	end)
end)
