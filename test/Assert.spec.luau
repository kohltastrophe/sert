--!nonstrict
-- Assertions (sert, eq, rawEq, near, contains, fails), expect() matchers, spies/mocks, and output capture.
local sert = require("../src")
local test = sert.test
local expect = sert.expect
local D = sert.doubles.Datatypes
local nativeVector: any = vector

local function vec(x: number, y: number)
	return setmetatable({ x = x, y = y }, {
		__eq = function(a, b) return a.x == b.x end,
		__index = function() return "missing" end,
	})
end

test("eq, rawEq, near, contains, fails, neq, matches, frames, and errorText", function()
	sert.eq(buffer.fromstring("abc"), buffer.fromstring("abc"))
	sert.eq({ data = buffer.fromstring("\0\1") }, { data = buffer.fromstring("\0\1") })
	local bufMsg = sert.fails(
		function() sert.eq(buffer.fromstring("abc"), buffer.fromstring("abd")) end,
		"values differ"
	)
	sert(string.find(bufMsg, "buffer(3) 61 62 64", 1, true) ~= nil)
	sert.fails(function() sert.eq(buffer.fromstring("ab"), buffer.fromstring("abc")) end)
	sert.eq(0 / 0, 0 / 0)
	-- selene: allow(mixed_table)
	sert.eq({ 0 / 0, n = 0 / 0 }, { 0 / 0, n = 0 / 0 })
	sert.fails(function() sert.eq(0 / 0, 0) end)
	sert.fails(function() sert.eq("1", 1) end)

	local a, b, c = vec(1, 2), vec(1, 3), vec(2, 2)
	sert.eq(a, b)
	sert.fails(function() sert.eq(a, setmetatable({ x = 1, y = 2 }, {})) end, "values differ")
	sert.rawEq(a, setmetatable({ x = 1, y = 2 }, {}))
	sert.rawEq({ v = a, list = { c } }, { v = { x = 1, y = 2 }, list = { { x = 2, y = 2 } } })
	sert.fails(function() sert.rawEq(a, b) end, "values differ")
	sert.fails(function() sert.rawEq(a, { x = 1 }) end)
	sert.fails(function() sert.rawEq(c, vec(2, 3), "custom why") end, "custom why")
	sert.rawEq(buffer.fromstring("x"), buffer.fromstring("x"))
	sert.rawEq(0 / 0, 0 / 0)
	local cycle, other = setmetatable({}, {}), setmetatable({}, {})
	cycle.self, other.self = cycle, other
	sert.rawEq(cycle, other)
	sert(sert.rawEq(a, a) == a)

	local ok, results
	local lines = sert.capture(function()
		ok, results = sert.isolate(function()
			sert.test("table", function() error({ code = 7 }) end)
			sert.test("tostring", function()
				error(setmetatable({}, { __tostring = function() return "custom text" end }))
			end)
			sert.test("number", function() error(42, 0) end)
			sert.test("string", function() error("plain", 0) end)
			return sert.run({ raise = false })
		end)
	end)
	sert(ok and #lines > 0)
	sert.eq(results.failures, { "table: { code = 7 }", "tostring: custom text", "number: 42", "string: plain" })
	sert.eq(sert.format.errorText({ 1, "a" }), '{ 1, "a" }')
	local failedProp = sert.prop.run("thrown table", function() error({ reason = "bad" }) end, { runs = 1 })
	sert(not failedProp.ok and failedProp.message == '{ reason = "bad" }')

	local after = false
	local outer = sert.current()
	local ok2, res2 = sert.isolate(function()
		sert.test("raises in tostring", function()
			error(setmetatable({}, { __tostring = function() error("boom in tostring", 0) end }))
		end)
		sert.test("passes", function() end)
		sert.afterAll(function() after = true end)
		return sert.run({ raise = false, silent = true })
	end)
	sert(ok2 and res2.failed == 1 and res2.passed == 1 and after)
	sert.eq(sert.current(), outer)
	sert.eq(res2.failures, { "raises in tostring: <table error; rendering it raised: boom in tostring>" })

	local stepped = 0
	local fMsg = sert.fails(function()
		sert.frames(function() return false end, 3, nil, function()
			stepped += 1
		end)
	end)
	sert(string.find(fMsg, ": condition not met after 3 frames$") ~= nil and stepped == 3)
	if (game :: any) == nil then
		local e = sert.env.new()
		local ready = false
		e.task.delay(0.1, function() ready = true end)
		sert(sert.frames(function() return ready end, 30, "ready") == true)
		sert(e.now >= 0.1 - 1e-9 and e.now < 0.2)
	end

	sert.eq(sert.contains("a (b) c", "(b)"), "a (b) c")
	sert.contains(12345, "234")
	local cMsg = sert.fails(function() sert.contains("hello there", "bye", "greeting") end, "greeting")
	sert(string.find(cMsg, '"bye"', 1, true) ~= nil and string.find(cMsg, "hello there", 1, true) ~= nil)
	sert(string.find(cMsg, "Assert.spec", 1, true) ~= nil)
	sert.fails(function() sert.contains(nil, "x") end, "missing text")

	sert.eq(sert.fails(function() error({ code = 404 }) end, "{ code = 404 }"), "{ code = 404 }")
	expect(function() error({ status = "denied" }) end).toThrow('status = "denied"')
	expect(function() error({ status = "ok" }) end).never.toThrow('status = "denied"')
	local waitErr = sert.fails(function()
		sert.waitFor(function() error({ reason = "offline" }) end, 0, "connect", function() end)
	end, '{ reason = "offline" }')
	sert(string.find(waitErr, 'last error: { reason = "offline" }', 1, true) ~= nil)
	if (game :: any) == nil then
		local eWait = sert.env.new()
		local virtualFlag = false
		eWait.task.delay(0.05, function() virtualFlag = true end)
		sert.eq(sert.waitFor(function() return virtualFlag end, 1, "virtual wait"), true)
		local customSteps = 0
		sert.fails(function()
			sert.waitFor(function() return nil end, 0.01, "wall timeout with noop step", function()
				customSteps += 1
			end)
		end, "wall timeout with noop step after 0.01 s")
		sert(customSteps > 0 and eWait.now < 0.1)
	end

	sert.eq(sert(42, "truthy value"), 42)
	sert.fails(function() sert(false) end, "expected condition to be true")
	sert.fails(function() sert(nil, "custom callable why") end, "custom callable why")

	sert.eq(sert.near(1.0, 1.0000005), 1.0)
	sert.eq(sert.near(1.0, 1.05, 0.1, "close enough"), 1.0)
	sert.fails(function() sert.near(1.0, 2.0) end, "values differ: expected 2")
	sert.fails(
		function() sert.near(1.0, 2.0, 0.25, "custom near why") end,
		"custom near why: expected 2 ± 0.25, got 1"
	)
	sert.fails(function() sert.near(0 / 0, 1.0) end, "values differ")

	sert(sert.equals({ a = { 1, 2 } }, { a = { 1, 2 } }) == true)
	sert(sert.equals({ a = 1 }, { a = 2 }) == false)
	sert(sert.equals(0 / 0, 0 / 0) == true)
	sert(sert.equals(setmetatable({}, {}), setmetatable({}, {})) == false)

	sert.fails(function()
		sert.fails(function() end)
	end, "expected the call to error, but it succeeded")
	sert.fails(function()
		sert.fails(function() end, nil, "should have thrown")
	end, "should have thrown")
	sert.fails(function()
		sert.fails(function() error("actual boom", 0) end, "expected fragment")
	end, 'wrong error: expected error containing "expected fragment", got: actual boom')
	sert.fails(function()
		sert.fails(function() error("actual boom", 0) end, "expected fragment", "custom fragment why")
	end, 'custom fragment why: expected error containing "expected fragment", got: actual boom')

	local u1, u2, u3 = newproxy(true), newproxy(true), newproxy(false)
	local eqFn = function() return true end
	getmetatable(u1).__eq, getmetatable(u2).__eq = eqFn, eqFn
	sert.eq(u1, u2)
	sert.rawEq({ u = u1 }, { u = u2 })
	sert.fails(function() sert.rawEq({ u = u1 }, { u = u3 }) end, "values differ")
	sert.fails(function() sert.eq({ a = 1 }, { a = 1, b = 2 }, "extra key in b") end, "extra key in b")
	sert.fails(function() sert.rawEq({ a = 1 }, { a = 1, b = 2 }) end, "values differ")

	sert.eq(sert.neq(1, 2), 1)
	sert.eq(sert.neq({ a = 1 }, { a = 2 }), { a = 1 })
	sert.fails(function() sert.neq({ a = 1 }, { a = 1 }) end, "values equal: expected not { a = 1 }, got { a = 1 }")
	sert.fails(function() sert.neq(5, 5, "custom neq why") end, "custom neq why: expected not 5, got 5")

	sert.eq(sert.matches("item-42-ok", "^item%-%d+%-ok$"), "item-42-ok")
	sert.matches(9876, "%d+")
	local mMsg = sert.fails(
		function() sert.matches("abc", "%d+") end,
		'pattern mismatch: expected pattern "%d+" in "abc"'
	)
	sert(string.find(mMsg, "Assert.spec", 1, true) ~= nil)
	sert.fails(function() sert.matches("abc", "%d+", "bad id") end, 'bad id: expected pattern "%d+" in "abc"')

	sert.near(D.Vector3.new(1, 2, 3), D.Vector3.new(1, 2, 3 + 1e-8))
	sert.near(D.Vector2.new(1, 2), D.Vector2.new(1.05, 2), 0.1)
	sert.near(D.Color3.new(0.5, 0.25, 1), D.Color3.new(0.5, 0.25, 1 - 1e-9))
	sert.near(D.UDim.new(0.5, 10), D.UDim.new(0.5, 10))
	sert.near(D.UDim2.new(0.5, 10, 1, -4), D.UDim2.new(0.5, 10.05, 1, -4), 0.1)
	sert.near(D.CFrame.new(1, 2, 3), D.CFrame.new(1, 2, 3 + 1e-7))
	sert.fails(
		function() sert.near(D.Vector3.new(1, 2, 3), D.Vector3.new(1, 2, 4)) end,
		"expected Vector3(1, 2, 4) ± 0.000001, got Vector3(1, 2, 3)"
	)
	sert.fails(function() sert.near(D.Vector3.new(1, 2, 3), D.Vector2.new(1, 2) :: any) end, "values differ")
	sert.fails(function() sert.near(D.Vector3.new(0 / 0, 0, 0), D.Vector3.new(0, 0, 0)) end, "values differ")
	sert.fails(function() sert.near({} :: any, {}) end, "near: expected a number or a Roblox datatype")
	if nativeVector ~= nil and (game :: any) == nil then
		sert.near(nativeVector.create(1, 2, 3), nativeVector.create(1, 2, 3.0000001))
	end

	local err = sert.fails(
		function() error({ code = "E_LIMIT", limit = 3 }) end,
		function(e) return type(e) == "table" and e.code == "E_LIMIT" end
	)
	sert.contains(err, "E_LIMIT")
	sert.fails(function()
		sert.fails(function() error({ code = "E_OTHER" }) end, function(e) return e.code == "E_LIMIT" end)
	end, "wrong error: expected error matching the predicate")
	sert.fails(function()
		sert.fails(function() error("plain", 0) end, function(e) return e.code.x end)
	end, "matching the predicate (it raised: ")
	sert.fails(function() error("boom") end, function(e) return string.find(e, "boom") end)
end)

test("expect · Jest matchers, spies, custom matchers, and lazy messages", function()
	local t = { 1, { 2 } }
	expect(t).toBe(t)
	expect(0 / 0).toBe(0 / 0)
	expect({ 1, { 2 } }).never.toBe(t)
	sert.fails(function() expect({ 1, { 2 } }).toBe(t) end, "deep-equal, but not the same table: use toEqual")
	expect({ 1, { 2 } }).toEqual(t)
	expect({ a = 1 }).never.toEqual({ a = 1, b = 2 })
	local a, b = setmetatable({ x = 1 }, {}), setmetatable({ x = 1 }, {})
	expect(a).never.toEqual(b)
	expect(a).toRawEqual(b)
	sert.fails(function() expect({ x = 1 }).toRawEqual({ x = 2 }) end, "values differ\n   at .x: expected 2, got 1")

	local player = { name = "kohl", stats = { level = 3, xp = 10 }, tags = { "a", "b" } }
	expect(player).toMatchObject({ name = "kohl", stats = { level = 3 }, tags = { "a", "b" } })
	expect(player).never.toMatchObject({ tags = { "a" } })
	expect(player).never.toMatchObject({ stats = { level = 4 } })
	expect(5).never.toMatchObject({ x = 1 })
	sert.fails(function() expect(player).toMatchObject({ stats = { level = 4 } }) end, "to match object")
	sert.fails(function() expect(player).toMatchObject(5) end, "toMatchObject: expected a table to match, got number")

	local value = { a = { b = { { c = 5 } } }, flag = false }
	expect(value).toHaveProperty("a.b[1].c")
	expect(value).toHaveProperty("a.b[1].c", 5)
	expect(value).toHaveProperty({ "a", "b", 1, "c" }, 5)
	expect(value).toHaveProperty("flag", false)
	expect(value).never.toHaveProperty("a.missing")
	expect(value).never.toHaveProperty("a.b[1].c", 6)
	expect(5).never.toHaveProperty("x")
	sert.fails(function() expect(value).toHaveProperty("a.b[2]") end, 'expected property "a.b[2]"')
	sert.fails(
		function() expect(value).toHaveProperty("a.b[1].c", 6) end,
		'property "a.b[1].c" differs: expected 6, got 5'
	)
	sert.fails(function() expect(value).never.toHaveProperty("flag") end, 'expected no property "flag"')

	expect(D.Vector3.new(1, 2, 3)).toBeInstanceOf("Vector3")
	expect(5).toBeInstanceOf("number")
	local Base = {}
	Base.__index = Base
	local Sub = setmetatable({}, { __index = Base })
	Sub.__index = Sub
	local object = setmetatable({}, Sub)
	expect(object).toBeInstanceOf(Sub)
	expect(object).toBeInstanceOf(Base)
	expect(setmetatable({}, Base)).never.toBeInstanceOf(Sub)
	expect({}).never.toBeInstanceOf(Base)
	local part = sert.env.new().Instance.new("Part")
	expect(part).toBeInstanceOf("BasePart")
	expect(part).never.toBeInstanceOf("Model")
	sert.fails(function() expect(object).toBeInstanceOf(5) end, "toBeInstanceOf: expected a class name or table")
	sert.fails(function() expect({}).toBeInstanceOf(Base) end, "to be an instance of")

	expect(0.1 + 0.2).toBeCloseTo(0.3)
	expect(1.004).toBeCloseTo(1)
	expect(1.006).never.toBeCloseTo(1)
	expect(0.5 + 0.00004).toBeCloseTo(0.5, 4)
	expect(0.5 + 0.00006).never.toBeCloseTo(0.5, 4)
	expect(1.4).toBeCloseTo(1, 0)
	expect(1.6).never.toBeCloseTo(1, 0)
	expect(math.huge).toBeCloseTo(math.huge)
	expect(0 / 0).never.toBeCloseTo(0 / 0)
	expect(0.5).never.toBeCloseTo(0, 0)
	expect(1.5).never.toBeCloseTo(1, 0)
	sert.fails(function() expect(1.006).toBeCloseTo(1) end, "expected 1 to 2 digits (± 0.005), got 1.006")
	sert.fails(
		function() expect(1).toBeCloseTo("1" :: any) end,
		"toBeCloseTo: expected a number to compare with, got string"
	)

	sert.fails(function() expect("1").never.toBeCloseTo(1) end, "toBeCloseTo: expected a number, got string")
	sert.fails(function() expect(nil).never.toBeGreaterThan(5) end, "toBeGreaterThan: expected a number, got nil")
	sert.fails(
		function() expect(nil).never.toBeLessThanOrEqual(5) end,
		"toBeLessThanOrEqual: expected a number, got nil"
	)
	expect("x").never.toBeNaN()
	expect("x").never.toBeFinite()

	local e = expect(1)
	sert.fails(function() e:toBe(1) end, "expect(...).toBe: call matchers with '.', not ':'")
	sert.fails(function() e.never:toBe(2) end, "expect(...).toBe: call matchers with '.', not ':'")

	expect(1 + 1e-7).toBeNear(1)
	expect(1 + 1e-5).never.toBeNear(1)
	expect(D.Vector3.new(1, 2, 3)).toBeNear(D.Vector3.new(1, 2, 3.0000001))
	expect(D.Color3.new(1, 0, 0)).toBeNear(D.Color3.new(0.99, 0, 0), 0.02)
	expect(D.Color3.new(1, 0, 0)).never.toBeNear(D.Color3.new(0.9, 0, 0), 0.02)
	expect(D.UDim2.new(0, 10, 1, 0)).toBeNear(D.UDim2.new(0, 10.000001, 1, 0))
	expect(D.CFrame.new(1, 2, 3)).toBeNear(D.CFrame.new(1, 2, 3))
	expect(D.Vector2.new(1, 2)).never.toBeNear(D.Vector3.new(1, 2, 0))
	sert.fails(
		function() expect(D.Vector2.new(1, 2)).toBeNear(D.Vector2.new(1, 3)) end,
		"expected Vector2(1, 3) ± 0.000001, got Vector2(1, 2)"
	)
	sert.fails(function() expect(1).never.toBeNear({}) end, "toBeNear: near: expected a number or a Roblox datatype")

	local spy = sert.fn(function(x)
		if x == "bad" then error("bad input", 0) end
		return x * 2
	end)
	spy(1)
	spy(2)
	expect(spy).toHaveBeenNthCalledWith(1, 1)
	expect(spy).toHaveBeenNthCalledWith(2, 2)
	expect(spy).never.toHaveBeenNthCalledWith(3, 3)
	expect(spy).toHaveBeenLastCalledWith(2)
	expect(spy).never.toHaveBeenLastCalledWith(1)
	expect(spy).toHaveReturned()
	expect(spy).toHaveReturnedWith(4)
	expect(spy).never.toHaveReturnedWith(3)
	sert.fails(function() expect(spy).toHaveBeenLastCalledWith(1) end, "expected the last call to have been with")
	sert.fails(function() expect(spy).toHaveBeenNthCalledWith(5, 1) end, "no such call")
	sert.fails(
		function() expect(spy).toHaveReturnedWith(3) end,
		"expected spy to have returned (3); its 2 returns: (2), (4)"
	)
	local failing = sert.fn(function() error("always", 0) end)
	pcall(failing)
	expect(failing).never.toHaveReturned()
	sert.fails(function() expect(failing).toHaveReturned() end, "expected spy to have returned, but no call returned")
	sert.fails(
		function() expect(failing).toHaveReturnedWith() end,
		"expected spy to have returned (); no call returned"
	)
	sert.fails(function() expect({}).toHaveReturned() end, "toHaveReturned: expected a sert.fn or sert.spy")
	sert.fails(function() expect(5).never.toHaveBeenCalled() end, "toHaveBeenCalled: expected a sert.fn or sert.spy")

	local thrower = function() error({ code = 7 }) end
	expect(thrower).toThrow()
	expect(thrower).toThrow(function(err) return err.code == 7 end)
	expect(thrower).never.toThrow(function(err) return err.code == 8 end)
	sert.fails(function()
		expect(thrower).toThrow(function(err) return err.code == 8 end)
	end, "expected error matching the predicate")
	sert.fails(function() expect(5).toThrow() end, "toThrow: expected a function, got number")
	sert.fails(function() expect(setmetatable({}, {})).toThrow() end, "toThrow: expected a function, got table")
	sert.fails(function() expect(5).never.toThrow() end, "toThrow: expected a function, got number")
	expect(sert.fn(function() error("spied", 0) end)).toThrow("spied")

	sert.fails(function() expect(1, "player count").toBe(2) end, "player count: values differ: expected 2, got 1")
	sert.fails(function() expect(1, "player count").never.toBe(1) end, "player count: expected not 1, got 1")
	sert.fails(function() (expect(1) :: any).toBeShiny() end, "expect: no matcher named toBeShiny")
	sert.fails(function() local _ = (expect(1).never :: any).never end, ".never.never")

	sert.extend({
		toBeEven = function(actual: any)
			return {
				pass = type(actual) == "number" and actual % 2 == 0,
				message = `expected {actual} to be even`,
				negMessage = `expected {actual} not to be even`,
			}
		end,
		toBeBetween = function(actual: any, lo: number, hi: number)
			return { pass = actual >= lo and actual <= hi, message = `expected {actual} in [{lo}, {hi}]` }
		end,
	})
	local e4: any = expect(4)
	e4.toBeEven()
	e4.never.toBeBetween(5, 9)
	sert.fails(function() (expect(3) :: any).toBeEven() end, "expected 3 to be even")
	sert.fails(function() (expect(4, "turn") :: any).never.toBeEven() end, "turn: expected 4 not to be even")
	sert.fails(function() (expect(4) :: any).never.toBeBetween(1, 9) end, "not: expected 4 in [1, 9]")
	sert.fails(function()
		sert.extend({ never = function() end } :: any)
	end, "`never` is reserved")
	sert.fails(function() sert.extend({ toBeX = 5 } :: any) end, "matcher toBeX is not a function")

	local mSpy = sert.fn(function() return "default" end)
	sert.eq(mSpy.lastCall, nil)
	mSpy:mockReturnValueOnce("first"):mockImplementationOnce(function(x) return `second {x}` end)
	sert.eq(mSpy(), "first")
	sert.eq(mSpy("arg"), "second arg")
	sert.eq(mSpy(), "default")
	sert.eq(mSpy.lastCall, { n = 0 })
	mSpy("a", nil, "c")
	sert.eq(mSpy.lastCall, table.pack("a", nil, "c"))
	mSpy:mockReturnValue(1, 2)
	mSpy:mockReturnValueOnce(9)
	sert.eq(table.pack(mSpy()), table.pack(9))
	sert.eq(table.pack(mSpy()), table.pack(1, 2))
	mSpy:mockReturnValueOnce("queued")
	mSpy:reset()
	sert(mSpy.lastCall == nil and mSpy.callCount == 0)
	sert.eq(table.pack(mSpy()), table.pack(1, 2))
	local target = { f = function() end }
	local installed: any = sert.spy(target, "f")
	sert.eq(installed._setRestore, nil)
	installed:restore()
	sert(target.f ~= installed)

	local f = sert.fn()
	sert.fails(
		function() expect(f).toHaveBeenCalledWith(1) end,
		"expected spy to have been called with (1); it was never called"
	)
	f(1, 2)
	f("x", nil)
	sert.fails(
		function() expect(f).toHaveBeenCalledWith(1, 3) end,
		'expected spy to have been called with (1, 3); its 2 calls: (1, 2), ("x", nil)'
	)
	sert.fails(
		function() expect(f).never.toHaveBeenCalledWith(1, 2) end,
		"expected spy not to have been called with (1, 2)"
	)
	sert.fails(
		function() expect(f).toHaveBeenLastCalledWith(1) end,
		'expected the last call to have been with (1), got ("x", nil)'
	)
	sert.fails(
		function() expect(f).toHaveBeenNthCalledWith(1, 1) end,
		"expected call 1 to have been with (1), got (1, 2)"
	)
	for i = 1, 9 do
		f(i)
	end
	sert.fails(
		function() expect(f).toHaveBeenCalledWith(0) end,
		'its 11 calls: (1, 2), ("x", nil), (1), (2), (3), (4), (5), (6), … 3 more'
	)

	local Class = {}
	Class.__index = Class
	function Class.get(_self: any) return 1 end
	local obj = setmetatable({}, Class)
	local instSpy: any = sert.spy(obj, "get", function() return 2 end)
	sert.eq(obj:get(), 2)
	instSpy:restore()
	sert.eq(rawget(obj, "get"), nil)
	Class.get = function(_self: any) return "patched" end
	sert.eq(obj:get(), "patched")
	local own = { f = function() return "own" end }
	local original = own.f
	sert.spy(own, "f"):restore()
	sert.eq(rawget(own, "f"), original)
	local store = { f = original }
	local proxy = setmetatable({}, { __index = store, __newindex = store })
	local through: any = sert.spy(proxy, "f")
	sert.eq(store.f, through)
	through:restore()
	sert(store.f == original and rawget(proxy, "f") == nil)

	local endless = setmetatable({}, {
		__iter = function()
			local i = 0
			return function()
				i += 1
				return i, true
			end
		end,
	})
	expect(endless).toBeTruthy()
	expect(endless).toBe(endless)
	expect(endless).never.toBeNil()
	expect({ endless }).toContain(endless)
	local built = 0
	sert.extend({
		toBeLazy = function(actual: any)
			return {
				pass = actual == true,
				message = function()
					built += 1
					return "expected lazy"
				end,
				negMessage = "expected not lazy",
			}
		end,
	});
	(expect(true) :: any).toBeLazy()
	sert.eq(built, 0)
	sert.fails(function() (expect(false) :: any).toBeLazy() end, "expected lazy")
	sert.eq(built, 1)
	sert.fails(function() (expect(true) :: any).never.toBeLazy() end, "expected not lazy")
	sert.fails(function() expect(endless).toBeNil() end, "expected nil, got")
end)

test("output · capture, quiet, json, repr, and direct print/warn", function()
	local lines = sert.capture(function(name)
		sert.print("hello", name, 1, true)
		sert.warn("careful")
		sert.print()
	end, "world")
	sert.eq(lines, { "hello world 1 true", "careful", "" })

	local outer = sert.capture(function()
		local a, b = sert.quiet(function(x)
			sert.print("hidden")
			sert.warn("hidden too")
			return x, x * 2
		end, 21)
		sert.eq({ a, b }, { 21, 42 })
		sert.print("shown")
	end)
	sert.eq(outer, { "shown" })

	local nested = sert.capture(function()
		sert.eq(sert.capture(function() sert.print("inner") end), { "inner" })
		sert.eq(
			sert.fails(function()
				sert.capture(function()
					sert.print("lost")
					error("boom", 0)
				end)
			end, "boom"),
			"boom"
		)
		sert.print("outer")
	end)
	sert.eq(nested, { "outer" })

	sert.eq(
		sert.capture(function()
			sert.isolate(function()
				sert.test("a", function() end)
				return sert.run({ silent = true })
			end)
		end),
		{}
	)

	local json = sert.format.json
	sert(json(nil) == "null" and json(true) == "true" and json(3) == "3" and json(0.5) == "0.5")
	sert(json(0 / 0) == "null" and json(math.huge) == "null")
	sert.eq(json('a"b\\c\n\t\1'), '"a\\"b\\\\c\\n\\t\\u0001"')
	sert.eq(json({ 1, "two", { x = false } }), '[1,"two",{"x":false}]')
	sert.eq(json({ b = 1, a = { c = "d" } }), '{"a":{"c":"d"},"b":1}')
	sert.eq(json({ [true] = 1, [false] = "no" }), '{"false":"no","true":1}')
	sert.eq(json({}), "{}")
	sert.eq(json(sert.format.array({})), "[]")
	sert.eq(json("\b\f\r"), '"\\b\\f\\r"')

	sert.eq(sert.format.repr("x"), '"x"')
	-- selene: allow(mixed_table)
	sert.eq(sert.format.repr({ 1, 2, k = "v" }), '{ 1, 2, k = "v" }')
	sert.eq(sert.format.repr({ { { { 1 } } } }), "{ { { {…} } } }")
	sert.eq(sert.format.repr({ [2] = "two" }), '{ [2] = "two" }')
	sert.eq(sert.format.repr({ ["a-b"] = 1 }), '{ ["a-b"] = 1 }')
	sert.eq(sert.format.repr({ ["1x"] = 2 }), '{ ["1x"] = 2 }')
	sert.eq(sert.format.repr({ ["a-b"] = 1, ["1x"] = 2 }), '{ ["1x"] = 2, ["a-b"] = 1 }')
	sert.eq(sert.format.errorText("plain text"), "plain text")
	sert.eq(sert.format.errorText({ code = 7 }), "{ code = 7 }")
	sert.eq(sert.format.errorText(setmetatable({}, { __tostring = function() return "custom-err" end })), "custom-err")

	local co = coroutine.create(function() end)
	sert(string.find(sert.format.repr(co), "^thread:") ~= nil and string.find(json(co), '^"thread:') ~= nil)
	sert(string.find(sert.format.repr(buffer.create(40)), "… 8 more", 1, true) ~= nil)
	sert.eq(sert.format.repr(buffer.create(0)), "buffer(0)")
	sert(string.find(sert.format.repr({ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10 }), "…", 1, true) ~= nil)

	local gf: any = getfenv :: any
	if gf ~= nil then
		local fenv: any = gf(sert.print)
		local prevPrint, prevWarn = rawget(fenv, "print"), rawget(fenv, "warn")
		local printed, warned = {}, {}
		fenv.print = function(...: any) table.insert(printed, table.concat({ ... }, " ")) end
		fenv.warn = function(...: any) table.insert(warned, table.concat({ ... }, " ")) end
		sert.defer(function()
			rawset(fenv, "print", prevPrint)
			rawset(fenv, "warn", prevWarn)
		end)
		sert.print("direct print smoke")
		sert.warn("direct warn smoke")
		rawset(fenv, "print", prevPrint)
		rawset(fenv, "warn", prevWarn)
		sert.eq(printed, { "direct print smoke" })
		sert.eq(warned, { "direct warn smoke" })
	else
		sert.print("direct print smoke")
		sert.warn("direct warn smoke")
	end

	-- toMatchObject cyclic tables and throwing __index; toHaveProperty path validation and non-string keys
	local cycActual: { [string]: any } = { a = 1 }
	cycActual.self = cycActual
	local cycPartial: { [string]: any } = { a = 1 }
	cycPartial.self = cycPartial
	sert.expect(cycActual).toMatchObject(cycPartial)
	local throwingTable = setmetatable({}, { __index = function() error("no index", 0) end })
	sert.expect(throwingTable).never.toMatchObject({ a = 1 })
	sert.expect({ [true] = { x = 7 } }).toHaveProperty({ true, "x" }, 7)
	for _, badPath in { "", ".a", "a.", "a..b", "a[foo]", "a[]", "[]" } do
		sert.fails(function() sert.expect({ a = 1 }).toHaveProperty(badPath) end, "invalid property path")
	end
	sert.fails(function() sert.expect({ a = 1 }).toHaveProperty({}) end, "invalid property path")
	sert.fails(
		function() sert.expect({ a = 1 }).toHaveProperty(123 :: any) end,
		"expected a property path string or table"
	)
end)

return {}
