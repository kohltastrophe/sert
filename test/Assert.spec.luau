--!strict
local matchCore = require("../src/core/match")
local registry = require("../src/core/registry")
local sert = require("../src")
local utilCore = require("../src/core/util")

local V2 = sert.env.Vector2
local V3 = sert.env.Vector3
local CF = sert.env.CFrame
local C3 = sert.env.Color3
local UD = sert.env.UDim
local UD2 = sert.env.UDim2
local RectDt = sert.env.Rect
local NR = sert.env.NumberRange

sert.describe("procedural assertions", function()
	sert.test("ok, fail, eq, ne, and equals", function()
		sert.eq(sert.ok(123), 123)
		sert.eq(sert.ok("non-empty"), "non-empty")
		sert.throws(function() sert.ok(false, "expected truthy flag") end, "expected truthy flag")
		sert.throws(function() sert.ok(nil) end, "expected truthy value, got nil")

		sert.throws(function() sert.fail("boom here") end, "boom here")
		sert.throws(function() sert.fail() end, "explicit assertion failure")

		local nested = { a = { 1, 2, 3 }, buf = sert.bytes.fromHex("0a0b") }
		sert.eq(sert.eq(nested, { a = { 1, 2, 3 }, buf = sert.bytes.fromHex("0a0b") }), nested)
		sert.eq(sert.ne({ a = 1 }, { a = 2 }), { a = 1 })

		local eqErr = sert.throws(function() sert.eq({ count = 1 }, { count = 2 }, "mismatch label") end)
		sert.contains(eqErr, "mismatch label")
		sert.contains(eqErr, "at .count: expected 2, got 1")

		sert.throws(function() sert.ne({ x = 5 }, { x = 5 }, "unexpected match") end, "unexpected match")

		sert.eq(sert.equals({ a = 1, b = "ok" }, { a = 1, b = sert.matching("^ok$") }), true)
		sert.eq(
			sert.equals(14, sert.any(function(v: any): boolean return type(v) == "number" and v % 7 == 0 end)),
			true
		)
		sert.eq(
			sert.equals(15, sert.any(function(v: any): boolean return type(v) == "number" and v % 7 == 0 end)),
			false
		)
	end)

	sert.test("lt, le, gt, and ge compare numbers and strings and reject mismatched types", function()
		sert.eq(sert.lt(1, 2), 1)
		sert.eq(sert.le(2, 2), 2)
		sert.eq(sert.le(1, 2), 1)
		sert.eq(sert.gt(5, 3), 5)
		sert.eq(sert.ge(5, 5), 5)
		sert.eq(sert.ge(6, 5), 6)

		sert.eq(sert.lt("alpha", "beta"), "alpha")
		sert.eq(sert.le("alpha", "alpha"), "alpha")
		sert.eq(sert.gt("zeta", "alpha"), "zeta")
		sert.eq(sert.ge("zeta", "zeta"), "zeta")

		sert.throws(function() sert.lt(2, 2, "strictly less") end, "strictly less: expected 2 < 2")
		sert.throws(function() sert.le(3, 2) end, "expected 3 <= 2")
		sert.throws(function() sert.gt(1, 4) end, "expected 1 > 4")
		sert.throws(function() sert.ge("a", "b") end, 'expected "a" >= "b"')
		sert.throws(function() (sert.lt :: any)(1, "2") end, "expected two numbers or two strings")
		sert.throws(function() (sert.gt :: any)({}, {}) end, "expected two numbers or two strings")
	end)

	sert.test("near checks component-wise tolerance across numbers and Roblox datatypes", function()
		sert.near(0.1 + 0.2, 0.3)
		sert.near(10.04, 10.0, 0.05)
		sert.near(V2.new(1.0001, 2.0), V2.new(1.0, 2.0), 1e-3)
		sert.near(V3.new(1, 2, 3.0005), V3.new(1, 2, 3), 1e-3)
		sert.near(UD.new(0.5, 10), UD.new(0.5001, 10), 1e-3)
		sert.near(UD2.new(0.5, 10, 0.25, 20), UD2.new(0.5001, 10, 0.25, 20), 1e-3)
		sert.near(C3.new(0.2, 0.4, 0.6), C3.new(0.2001, 0.4, 0.6), 1e-3)
		sert.near(CF.new(1, 2, 3), CF.new(1.0001, 2, 3), 1e-3)
		sert.near(RectDt.new(0, 0, 10, 20), RectDt.new(0, 0, 10.0002, 20), 1e-3)
		sert.near(NR.new(1, 5), NR.new(1.0001, 4.9999), 1e-3)

		sert.throws(function() sert.near(1.0, 1.1, 0.01, "drift") end, "drift")
		sert.throws(function() sert.near(0 / 0, 0.0, 1.0) end, "values differ")
		sert.throws(function() sert.near(1.0, 1.0, -0.1) end, "non-negative")
	end)

	sert.test("matches and contains validate strings, arrays, maps, and asymmetric matchers", function()
		sert.eq(sert.matches("player_42", "^player_%d+$"), "player_42")
		sert.throws(function() sert.matches("guest", "^player_%d+$", "bad id") end, "bad id")
		sert.throws(function() sert.matches("abc", "[unclosed") end, "invalid pattern")

		sert.eq(sert.contains("hello world", "world"), "hello world")
		sert.eq(sert.contains("id=991", sert.matching("^id=%d+$")), "id=991")
		sert.throws(function() sert.contains("hello", "missing") end, "missing substring")

		local items = { { id = 1, tag = "a" }, { id = 2, tag = "b" } }
		sert.eq(sert.contains(items, { id = 2, tag = "b" }), items)
		sert.eq(sert.contains(items, sert.subset({ tag = "b" })), items)

		local map = { owner = "Ada", role = "admin" }
		sert.eq(sert.contains(map, "admin"), map)
		sert.throws(function() sert.contains(items, { id = 99 }) end, "missing element")
	end)

	sert.test("throws and doesNotThrow preserve errors and multiple return values", function()
		local text = sert.throws(function() error("permission denied: code 403", 0) end, "code %d+")
		sert.contains(text, "permission denied: code 403")

		sert.throws(function() error({ code = 429, retry = true }, 0) end, sert.subset({ code = 429 }))
		sert.throws(
			function() error({ status = 503 }, 0) end,
			function(err: any): boolean return type(err) == "table" and err.status == 503 end
		)

		sert.throws(function()
			sert.throws(function() end, nil, "should have thrown")
		end, "should have thrown")

		sert.throws(function()
			sert.throws(function() error("actual error", 0) end, "expected_other")
		end, "wrong error")

		local a, b, c = sert.doesNotThrow(function(): (number, string, boolean) return 7, "seven", true end)
		sert.eq(a, 7)
		sert.eq(b, "seven")
		sert.eq(c, true)

		sert.throws(function()
			sert.doesNotThrow(function() error("boom inside", 0) end, "must succeed")
		end, "must succeed")
	end)

	sert.test("waitFor succeeds immediately, steps active sert.env until ready, and times out cleanly", function(ctx)
		local immediate = sert.waitFor(function(): string? return "ready" end, 0.1)
		sert.eq(immediate, "ready")

		local env = sert.env.new()
		ctx:defer(function() env:destroy() end)

		local value: number? = nil
		env.task.delay(0.15, function() value = 99 end)
		local resolved = sert.waitFor(function(): number? return value end, 1.0, 0.05)
		sert.eq(resolved, 99)

		local timeoutErr = sert.throws(function()
			sert.waitFor(function(): boolean error("still booting", 0) end, 0.1, 0.05, "service ready")
		end)
		sert.contains(timeoutErr, "service ready after 0.1 s")
		sert.contains(timeoutErr, "still booting")
	end)
end)

sert.describe("asymmetric matchers and custom __iter safety", function()
	sert.test("any, subset, within, and matching compose inside deep tables and Instances", function(ctx)
		local env = sert.env.new()
		ctx:defer(function() env:destroy() end)

		local part = env.Instance.new("Part")
		part.Name = "SpawnPad"
		part.Anchored = true
		part.Position = env.Vector3.new(10, 2.0001, -4)

		local payload = {
			id = "req_104",
			timestamp = 1700000123,
			origin = V3.new(1.0, 2.00001, 3.0),
			target = part,
			meta = {
				tags = { "fast", "reliable" },
				extra = true,
			},
		}

		sert.eq(payload, {
			id = sert.matching("^req_%d+$"),
			timestamp = sert.any("number"),
			origin = sert.within(V3.new(1, 2, 3), 1e-3),
			target = sert.any("BasePart"),
			meta = sert.subset({
				tags = { "fast", "reliable" },
			}),
		})

		sert.eq(part, sert.any("Instance"))
		sert.eq(part, sert.any("Part"))
		sert.ne(part, sert.any("ScreenGui"))
		sert.eq(
			part,
			sert.subset({
				Name = sert.matching("^Spawn"),
				Anchored = true,
				Position = sert.within(env.Vector3.new(10, 2, -4), 1e-2),
			})
		)

		sert.eq("non-nil", sert.any())
		sert.ne(nil, sert.any())
		sert.eq({ k = 1 }, sert.any("table"))

		local boomPred = sert.any(function(): boolean error("pred crash", 0) end)
		sert.ne(123, boomPred)

		local explained = matchCore.explain(
			{ items = { { pos = 1.0 }, { pos = 5.5 } } },
			{ items = { { pos = 1.0 :: any }, { pos = sert.within(2.0, 0.1) } } }
		)
		sert.ok(explained ~= nil)
		sert.contains(explained :: string, "$.items[2].pos")
	end)

	sert.test("exact distinguishes -0.0 vs +0.0, matches NaN, and walks raw fields past metatables", function()
		local negZero = -0.0
		local posZero = 0.0
		local nanVal = 0 / 0

		-- Plain Luau treats -0.0 == 0.0 as true and NaN == NaN as false.
		sert.ok(negZero == posZero)
		sert.ok(nanVal ~= nanVal)

		-- Plain `sert.eq` equates -0.0 with +0.0, while `sert.exact` distinguishes sign bits and matches NaN.
		sert.eq(negZero, posZero)
		sert.eq(negZero, sert.exact(-0.0))
		sert.eq(posZero, sert.exact(0.0))
		sert.ne(negZero, sert.exact(0.0))
		local signErr = sert.throws(function() sert.eq(negZero, sert.exact(0.0)) end)
		sert.contains(signErr, "signed zero")

		sert.eq(nanVal, sert.exact(0 / 0))
		sert.eq({ z = negZero, n = nanVal }, sert.exact({ z = -0.0, n = 0 / 0 }))
		sert.ne({ z = negZero }, sert.exact({ z = 0.0 }))

		local mt = { __index = { inherited = 99 } }
		local left = setmetatable({ rawField = 1 }, mt)
		local right = setmetatable({ rawField = 1 }, mt)
		sert.ne(left, right)
		sert.eq(left, sert.exact(right))
		sert.ne(left, sert.exact(setmetatable({ rawField = 2 }, mt)))
	end)

	sert.test("compares and copies tables with throwing __iter metamethods via next", function()
		local iterMt = {
			__iter = function(): never error("generalized __iter should never run", 0) end,
		}
		local plainA = { x = 1, y = { 2, 3 } }
		local guardedB = setmetatable({ x = 1, y = { 2, 3 } }, iterMt)

		sert.eq(plainA, sert.exact(setmetatable({ x = 1, y = { 2, 3 } }, {})))
		sert.ok(utilCore.equal(guardedB, setmetatable({ x = 1, y = { 2, 3 } }, iterMt), true))
		sert.eq(guardedB, sert.subset({ x = 1, y = { 2, 3 } }))

		local cloned = utilCore.copy(guardedB)
		sert.eq(cloned.x, 1)
		sert.eq(cloned.y, { 2, 3 })
	end)
end)

sert.describe("spies and spy assertions", function()
	sert.test("standalone spies support returns, returnsOnce chaining, throws, throwsOnce, calls, and reset", function()
		local emptySpy = sert.spy()
		sert.eq(emptySpy.called, false)
		sert.eq(emptySpy.callCount, 0)
		sert.eq(emptySpy("a", nil, "c"), nil)
		sert.eq(emptySpy.called, true)
		sert.eq(emptySpy.callCount, 1)
		sert.called(emptySpy)
		sert.calledTimes(emptySpy, 1)
		sert.calledWith(emptySpy, "a", nil, "c")
		sert.throws(function() sert.calledWith(emptySpy, "a") end, "called with")

		local fnSpy = sert.spy(function(a: number, b: number): number return a + b end)
		sert.eq(fnSpy(3, 4), 7)

		fnSpy:returns(100, nil, "tail")
		fnSpy:returnsOnce(1):returnsOnce(2)
		sert.eq(fnSpy(), 1)
		sert.eq(fnSpy(), 2)
		local r1, r2, r3 = fnSpy()
		sert.eq(r1, 100)
		sert.eq(r2, nil)
		sert.eq(r3, "tail")

		fnSpy:throwsOnce("transient error")
		sert.throws(function() fnSpy() end, "transient error")
		sert.eq(fnSpy.results[#fnSpy.results].ok, false)
		local afterOnce = fnSpy()
		sert.eq(afterOnce, 100)

		fnSpy:throws("permanent error")
		sert.throws(function() fnSpy() end, "permanent error")

		fnSpy.calls(fnSpy, function(x: number): number return x * 10 end)
		sert.eq(fnSpy(6), 60)

		local iterated = 0
		for _, call in fnSpy.calls do
			sert.ok(type(call.n) == "number")
			iterated += 1
		end
		sert.eq(iterated, fnSpy.callCount)

		fnSpy:reset()
		sert.eq(fnSpy.called, false)
		sert.eq(fnSpy.callCount, 0)
		sert.eq(#fnSpy.calls, 0)
		sert.eq(#fnSpy.results, 0)
		sert.eq(fnSpy.lastArgs, nil)
		sert.throws(function() sert.called(fnSpy) end, "spy not called")
		sert.throws(function() sert.calledTimes(fnSpy, 1) end, "spy call count mismatch")
	end)

	sert.test("calledWith matches trailing nil arguments and nested asymmetric matchers", function()
		local s = sert.spy()
		s("user_7", { score = 99.9999999, tags = { "vip", "beta" } }, nil)

		sert.calledWith(s, sert.matching("^user_%d+$"), sert.subset({ score = sert.within(100, 1e-4) }), nil)
		sert.throws(function() sert.calledWith(s, "user_7", sert.any("table")) end, "called with")
	end)

	sert.test("method spies install and restore via rawset across strict __newindex and inherited __index", function()
		local base = {
			inherited = function(_self: any, x: number): number return x + 1 end,
		}
		local newindexTrips = 0
		local strictObj: any = setmetatable({
			own = function(_self: any, x: number): number return x * 2 end,
		}, {
			__index = base,
			__newindex = function(): never
				newindexTrips += 1
				error("strict __newindex triggered", 0)
			end,
		})

		local ownOrig = rawget(strictObj, "own")
		local ownSpy = sert.spy(strictObj, "own")
		sert.eq(newindexTrips, 0)
		sert.eq(strictObj:own(5), 10)
		sert.calledTimes(ownSpy, 1)
		ownSpy:restore()
		sert.eq(newindexTrips, 0)
		sert.eq(rawget(strictObj, "own"), ownOrig)

		sert.eq(rawget(strictObj, "inherited"), nil)
		local inhSpy = sert.spy(strictObj, "inherited")
		sert.eq(newindexTrips, 0)
		sert.eq(strictObj:inherited(9), 10)
		sert.calledTimes(inhSpy, 1)
		inhSpy:restore()
		sert.eq(newindexTrips, 0)
		sert.eq(rawget(strictObj, "inherited"), nil)
		sert.eq(strictObj:inherited(9), 10)
	end)

	sert.test("auto-restores table spies in strict LIFO order when a test exits", function()
		local restoreOrder: { string } = {}
		local target: any = setmetatable({
			a = function(): string return "orig_a" end,
			b = function(): string return "orig_b" end,
		}, {
			__newindex = function(): never error("strict __newindex during LIFO restore", 0) end,
		})

		local sub = registry.newState()
		registry.isolateDepth += 1
		local ok, err = pcall(function()
			registry.withState(sub, function()
				sert.test("spies inside test", function(ctx)
					ctx:defer(function() table.insert(restoreOrder, "defer_first") end)
					local sa = sert.spy(target, "a", function(): string return "stub_a" end)
					ctx:defer(function() table.insert(restoreOrder, `between:{target.a()}:{target.b()}`) end)
					local sb = sert.spy(target, "b", function(): string return "stub_b" end)
					sert.eq(target.a(), "stub_a")
					sert.eq(target.b(), "stub_b")
					sert.calledTimes(sa, 1)
					sert.calledTimes(sb, 1)
				end)
				local res = sert.run({ quiet = true, raise = false })
				sert.eq(res.passed, 1)
				sert.eq(res.failed, 0)
			end)
		end)
		registry.isolateDepth -= 1
		if not ok then error(err, 0) end

		-- `sb` was created after `between`, so `sb` restored to `orig_b` before `between` ran, while `sa` was still `stub_a`!
		sert.eq(restoreOrder, { "between:stub_a:orig_b", "defer_first" })
		sert.eq(target.a(), "orig_a")
		sert.eq(target.b(), "orig_b")

		-- Exercise contains/throws matcher & predicate failure diagnostics + custom Signal:Wait yieldFn/timeout
		local containsAny: any = sert.contains
		local throwsAny: any = sert.throws
		sert.throws(function() containsAny("hello", 42) end, "string or matcher needle")
		sert.throws(function() containsAny("hello", "zzz") end, "missing substring")
		sert.throws(function() containsAny({ 1, 2 }, 99) end, "missing element")
		sert.throws(function() containsAny(42, 1) end, "string or table haystack")

		sert.throws(function()
			throwsAny(function() error("actual_err", 0) end, sert.matching("^expected_prefix"))
		end, "matching")
		sert.throws(function()
			throwsAny(function() error("actual_err", 0) end, function() return false end)
		end, "satisfying predicate")
		sert.throws(function()
			throwsAny(function() error("actual_err", 0) end, function() error("pred_boom", 0) end)
		end, "predicate raised")
		sert.throws(function()
			throwsAny(function() error("actual_err", 0) end, 123)
		end, "expected pattern string")

		local Signal = require("../src/engine/signal")
		local customSig: any = Signal.new()
		local polled = 0
		local waitedVal = customSig:Wait(function()
			polled += 1
			if polled == 2 then customSig:Fire("custom-yield") end
		end)
		sert.eq(waitedVal, "custom-yield")

		local stuckSig: any = Signal.new({
			wait = function() end,
			canStep = function() return false end,
		})
		sert.throws(function() stuckSig:Wait() end, "nothing scheduled")

		local timeoutSig: any = Signal.new({
			wait = function() end,
		})
		sert.throws(function() timeoutSig:Wait() end, "did not fire within")
	end)
end)
