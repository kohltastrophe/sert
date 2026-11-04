--!nonstrict
-- The test runner, hooks, modifiers, sharding, and Roblox session/runner lifecycle.
local RobloxRunner = require("../src/roblox/Runner")
local prop = require("../src/prop")
local sert = require("../src")
local Other = require("./fixtures/Other.spec")
local aggregator = require("./fixtures/aggregator")
local suite = require("./fixtures/suite")

local RobloxSession = RobloxRunner._session
local mutant = prop.mutant
local eq, expect, fails, test = sert.eq, sert, sert.fails, sert.test

local function run(register: () -> (), options: { [string]: any }?): (boolean, { string }, any)
	local ok, err
	local lines = sert.capture(function()
		ok, err = sert.isolate(function()
			register()
			return sert.run(options)
		end)
	end)
	return ok, lines, err
end

local function runMarked(register: () -> (), options: { [string]: any }?): (any, { string })
	local results
	local lines = sert.capture(function()
		local ok, value = sert.isolate(function()
			register()
			local opts = table.clone(options or {})
			opts.raise = false
			opts.markers = true
			return sert.run(opts)
		end)
		expect(ok, value)
		results = value
	end)
	return results, lines
end

local function find(lines: { string }, fragment: string): string?
	for _, line in lines do
		if string.find(line, fragment, 1, true) ~= nil then return line end
	end
	return nil
end

local function markers(lines: { string }, kind: string): { string }
	local out = {}
	for _, line in lines do
		local payload = string.match(line, `^%[sert%-{kind}%] (.*)$`)
		if payload ~= nil then table.insert(out, payload) end
	end
	return out
end

test("hooks · global, file, aggregator, setup clearing, beforeEach/afterEach, and beforeAll/afterAll", function()
	local log = {}
	local ok, _, err = run(function()
		sert.setup({ beforeEach = function() table.insert(log, "replaced") end })
		sert.setup({
			beforeEach = function() table.insert(log, "G+") end,
			afterEach = function() table.insert(log, "G-") end,
		})
		sert.beforeEach(function() table.insert(log, "F+") end)
		sert.afterEach(function() table.insert(log, "F-") end)
		sert.test("a", function() table.insert(log, "a") end)
	end)
	expect(ok, err)
	eq(log, { "G+", "F+", "a", "F-", "G-" })

	table.clear(log)
	ok, _, err = run(function()
		sert.beforeEach(function() table.insert(log, "runner+") end)
		sert.test("mine", function() table.insert(log, "mine") end)
		Other(sert, log)
		sert.afterEach(function() table.insert(log, "runner-") end)
	end)
	expect(ok, err)
	eq(log, { "runner+", "mine", "runner-", "other+", "other", "other-" })

	table.clear(log)
	ok, _, err = run(function()
		aggregator(sert, function() table.insert(log, "agg+") end, function() table.insert(log, "agg-") end)
		sert.beforeEach(function() table.insert(log, "F+") end)
		sert.test("mine", function() table.insert(log, "mine") end)
		Other(sert, log)
	end)
	expect(ok, err)
	eq(log, { "agg+", "F+", "mine", "agg-", "agg+", "other+", "other", "other-", "agg-" })

	table.clear(log)
	ok, _, err = run(function()
		aggregator(sert, function() table.insert(log, "agg+") end, function() table.insert(log, "agg-") end)
		sert.setup({})
		sert.test("a", function() table.insert(log, "a") end)
	end)
	expect(ok, err)
	eq(log, { "a" })

	-- failing beforeEach skips the test and still runs afterEach
	table.clear(log)
	local okFail, linesFail = run(function()
		sert.beforeEach(function() error("setup broke") end)
		sert.afterEach(function() table.insert(log, "after") end)
		sert.test("never", function() table.insert(log, "body") end)
	end, { markers = true })
	expect(not okFail and find(linesFail, "beforeEach: ") ~= nil)
	eq(log, { "after" })

	-- beforeAll, afterAll, todo, and skip without body
	local events = {}
	local okAll, resAll = sert.isolate(function()
		sert.setup({
			beforeAll = function() table.insert(events, "global:beforeAll") end,
			afterAll = function() table.insert(events, "global:afterAll") end,
			beforeEach = function() table.insert(events, "global:beforeEach") end,
			afterEach = function() table.insert(events, "global:afterEach") end,
		})
		sert.beforeAll(function() table.insert(events, "file:beforeAll") end)
		sert.afterAll(function() table.insert(events, "file:afterAll") end)
		sert.describe("suite", function()
			sert.beforeAll(function() table.insert(events, "suite:beforeAll") end)
			sert.afterAll(function() table.insert(events, "suite:afterAll") end)
			sert.test("one", function() table.insert(events, "test:one") end)
			sert.test("two", function() table.insert(events, "test:two") end)
			sert.skip("skipped without body")
			sert.todo("todo without body")
		end)
		return sert.run({ silent = true })
	end)
	expect(okAll, resAll)
	eq({ resAll.passed, resAll.skipped, resAll.todo }, { 2, 1, 1 })
	eq(#events, 12)

	-- Failing beforeAll and failing afterAll (normal + failFast)
	local afterRan = false
	local _, resBAll = sert.isolate(function()
		sert.describe("broken", function()
			sert.beforeAll(function() error("setup exploded", 0) end)
			sert.afterAll(function() afterRan = true end)
			sert.test("never runs", function() end)
		end)
		return sert.run({ silent = true, raise = false })
	end)
	expect(resBAll.failed == 1 and afterRan)
	sert.contains(resBAll.failures[1], "beforeAll: setup exploded")

	local _, resAAll = sert.isolate(function()
		sert.describe("teardown-err", function()
			sert.afterAll(function() error("teardown exploded", 0) end)
			sert.test("passes body", function() end)
		end)
		return sert.run({ silent = true, raise = false })
	end)
	sert.contains(resAAll.failures[1], "afterAll: teardown exploded")

	local _, resFast = sert.isolate(function()
		sert.describe("fast-teardown", function()
			sert.afterAll(function() error("fast afterAll boom", 0) end)
			sert.test("first fails", function() error("first boom", 0) end)
			sert.test("second skipped by failFast", function() end)
		end)
		return sert.run({ silent = true, raise = false, failFast = true })
	end)
	eq(resFast.failed, 2)
	sert.contains(resFast.failures[2], "afterAll: fast afterAll boom")
end)

test("run · raise = false, excludes, seeds, each, coroutines, markers, list, check, and describe", function()
	local cases = {}
	local ok, lines, results = run(function()
		sert.test("keep", function() end)
		sert.test("drop me", function() end)
		sert.test("bad", function() error("no", 0) end)
		sert.prop("seeded", function(g) table.insert(cases, g.seed) end, { runs = 50 })
	end, { raise = false, excludes = { "drop me", "drop" }, seeds = { seeded = 1234 } })
	expect(ok and results.passed == 2 and results.failed == 1 and results.skipped == 1)
	eq(results.failures, { "bad: no" })
	eq(cases, { 1234 })
	expect(find(lines, "[sert-done]") ~= nil)

	-- each (default label + options.format)
	local seen = {}
	local okEach, linesEach = run(function()
		sert.each(
			"double",
			{ { name = "one", n = 1 }, { name = "two", n = 2 } },
			function(case, i) table.insert(seen, `{case.n}@{i}`) end
		)
		sert.each("plain", { 10 }, function(n) table.insert(seen, tostring(n)) end, {})
		sert.each("parse", { { input = "1" } }, function() end, {
			format = function(name, case, i) return `{name} [{i}] {case.input}` end,
		})
	end, { list = true })
	expect(okEach and #seen == 0)
	eq(
		markers(linesEach, "list"),
		{ "Runner|double · one", "Runner|double · two", "Runner|plain · 1", "Runner|parse [1] 1", "end 4" }
	)
	run(function()
		sert.each(
			"double",
			{ { name = "one", n = 1 }, { name = "two", n = 2 } },
			function(case, i) table.insert(seen, `{case.n}@{i}`) end
		)
	end)
	eq(seen, { "1@1", "2@2" })

	-- coroutine hang detection and per-test threads
	local clog, threads = {}, {}
	local okCo, linesCo = run(function()
		sert.afterEach(function() table.insert(clog, "after") end)
		sert.test("hangs", function() coroutine.yield() end)
		sert.test("next", function()
			table.insert(clog, "next")
			table.insert(threads, coroutine.running())
			local inner = coroutine.wrap(function()
				coroutine.yield(1)
				return 2
			end)
			eq({ inner(), inner() }, { 1, 2 })
		end)
	end, { markers = true, timeout = 0.05 })
	expect(not okCo and threads[1] ~= coroutine.running())
	eq(clog, { "after", "next", "after" })
	expect(find(markers(linesCo, "test"), '"name":"hangs"') ~= nil)

	-- [sert-test], [sert-done], and [sert-seed] markers
	local okMk, linesMk = run(function()
		sert.test("good", function() end)
		sert.test("bad", function() error("nope", 0) end)
		sert.skip("later", function() end)
		sert.test("filtered out", function() end)
	end, { markers = true, filters = { "good", "bad", "later" } })
	expect(not okMk and #markers(linesMk, "test") == 3 and #markers(linesMk, "done") == 1)
	local _, quietLines = run(function()
		sert.test("good", function() end)
	end)
	eq(markers(quietLines, "test"), {})

	local okSd, linesSd = run(function()
		sert.prop("small", function(g) expect(g:int(0, 100) < 50) end, { runs = 20 })
		sert.prop("fine", function(g) g:int(0, 1) end, { runs = 5 })
	end, { seed = 7 })
	expect(not okSd)
	local seeds = markers(linesSd, "seed")
	local seed = tonumber(string.match(seeds[2], "^small|(%d+)$"))
	expect(not sert.prop.run("small", function(g) expect(g:int(0, 100) < 50) end, { runs = 20 }, { replay = seed }).ok)

	-- check and describe
	local okCk, linesCk = run(function()
		sert.check(
			"sum is small",
			{ sert.gen.int(0, 1000), sert.gen.int(0, 1000) },
			function(a, b) expect(a + b < 1500) end
		)
		sert.check("one generator", sert.gen.bool(), function(flag) expect(type(flag) == "boolean") end, { runs = 10 })
	end)
	expect(not okCk and find(linesCk, "args: (") ~= nil and find(linesCk, "✅ one generator · ") ~= nil)

	local dlog = {}
	local okDesc, linesDesc = run(function()
		sert.beforeEach(function() table.insert(dlog, "F+") end)
		sert.afterEach(function() table.insert(dlog, "F-") end)
		sert.describe("Store", function()
			sert.beforeEach(function() table.insert(dlog, "S+") end)
			sert.afterEach(function() table.insert(dlog, "S-") end)
			sert.test("get", function() table.insert(dlog, "get") end)
			sert.describe("nested", function()
				sert.test("case", function() table.insert(dlog, "case") end)
			end)
		end)
		sert.describe("Path", function()
			sert.test("join", function() end)
		end, { separator = "/" })
		pcall(function()
			sert.describe("Broken", function()
				sert.test("one", function() end)
				error("registration broke")
			end)
		end)
	end, { filter = "e" })
	expect(okDesc and #dlog > 0 and linesDesc ~= nil)
end)

test(
	"run · requireTests, current, defer, waitFor, list filters, rtestOnly, isolate, singular reports, and shards",
	function()
		local ok, _, results = run(function()
			sert.test("present", function() end)
		end, { filter = "absent", requireTests = true, raise = false })
		expect(ok and results.failed == 1 and string.find(results.failures[1], "requireTests:", 1, true) ~= nil)
		expect(string.find(results.failures[1], "@file=", 1, true) == nil)
		for _, fileLikeFilter in { "Runner.spec", "Runner", "alpha|beta" } do
			local okHint, _, resHint = run(function()
				sert.test("present", function() end)
			end, { filter = fileLikeFilter, requireTests = true, raise = false })
			expect(
				okHint
					and resHint.failed == 1
					and string.find(resHint.failures[1], 'use --filter "@file=Name1,Name2"', 1, true) ~= nil
			)
		end
		local raised = run(function()
			sert.test("present", function() end)
		end, { names = { "nope" }, requireTests = true })
		expect(not raised)
		expect((run(function()
			sert.test("present", function() end)
		end, { filter = "pres", requireTests = true })))

		-- sert.current()
		local seen = {}
		local function note(where: string)
			local c = sert.current()
			table.insert(seen, if c then `{where} {c.name} {c.file} {c.last}` else `{where} nil`)
		end
		run(function()
			sert.setup({ beforeEach = function() note("+") end })
			sert.test("a1", function() note("in") end)
			Other(sert, {})
			sert.test("a2", function() note("in") end)
		end)
		eq(
			seen,
			{ "+ a1 Runner false", "in a1 Runner false", "+ other Other true", "+ a2 Runner true", "in a2 Runner true" }
		)

		-- defer LIFO and load-time spy/defer across list run
		local dlog = {}
		run(function()
			sert.afterEach(function() table.insert(dlog, "after") end)
			sert.test("passes", function()
				sert.defer(function() table.insert(dlog, "d1") end)
				sert.defer(function()
					table.insert(dlog, "d2")
					sert.defer(function() table.insert(dlog, "d2-nested") end)
				end)
				table.insert(dlog, "body")
			end)
			sert.test("fails", function()
				sert.defer(function() table.insert(dlog, "fail-d1") end)
				error("boom", 0)
			end)
		end, { raise = false })
		eq(dlog, { "body", "d2", "d2-nested", "d1", "after", "fail-d1", "after" })

		local mod = { f = function() return "real" end }
		local llog = {}
		run(function()
			sert.spy(mod, "f", function() return "stub" end)
			sert.defer(function() table.insert(llog, "defer") end)
			sert.test("sees stub", function() eq(mod.f(), "stub") end)
			sert.run({ list = true, silent = true })
		end, { raise = false })
		eq({ mod.f(), llog[1] }, { "real", "defer" })

		-- waitFor
		local attempts, steps = 0, 0
		eq(
			sert.waitFor(
				function()
					attempts += 1
					return if attempts >= 3 then "ready" else nil
				end,
				1,
				"ready check",
				function()
					steps += 1
				end
			),
			"ready"
		)
		fails(function()
			sert.waitFor(function() return nil end, 0, "never ready", function() end)
		end, "never ready after 0 s")

		-- list selection & rtestOnly
		local function sfn()
			sert.test("alpha one", function() end)
			sert.test("Alpha two", function() end)
			sert.test("beta", function() end)
			sert.skip("alpha skipped", function() end)
		end
		eq(
			markers(select(2, run(sfn, { list = true, filters = { "beta", "two" }, excludes = { "beta" } })), "list"),
			{ "Runner|Alpha two", "end 1" }
		)
		eq(markers(select(2, run(sfn, { list = true, names = { "beta" } })), "list"), { "Runner|beta", "end 1" })
		eq(markers(select(2, run(sfn, { list = true, filter = "@file=Other" })), "list"), { "end 0" })

		local rran = {}
		local _, rlines, rres = run(function()
			sert.test("pure", function() table.insert(rran, "pure") end)
			sert.rtest("roblox", function() table.insert(rran, "roblox") end)
			sert.skip("skipped", function() end)
		end, { rtestOnly = true, raise = false })
		eq({ #rran, rres.total, rres.skipped, #rlines > 0 }, { 0, 2, 2, true })

		-- nested run refused; isolate handles killed coroutine & no-inner-run spy/defer; singular report; not selected
		fails(function()
			sert.test("dynamic", function() end)
		end, "cannot register a new test inside a running test")
		local _, _, nres = run(function()
			sert.test("nested run", function() sert.run() end)
			sert.test("yields inside isolate", function()
				sert.isolate(function()
					sert.test("isolated", function() end)
					sert.spy(mod, "f", function() return "leaked" end)
					sert.capture(function() coroutine.yield() end)
				end)
			end)
			sert.test("isolates spy", function()
				sert.isolate(function()
					sert.spy(mod, "f", function() return "stub2" end)
				end)
				eq(mod.f(), "stub2")
			end)
		end, { raise = false, silent = true })
		local postCapLines = sert.capture(function() sert.print("after-yield-cap") end)
		eq({ nres.passed, nres.failed, mod.f(), postCapLines }, { 1, 2, "real", { "after-yield-cap" } })

		local _, slines = run(function()
			sert.prop("one draw", function(g)
				g:int(0, 1)
				error("always", 0)
			end, { runs = 1 })
		end, { raise = false })
		expect(find(slines, "sert · 1 test · ") ~= nil and find(slines, "tape: 1 draw → ") ~= nil)

		local _, nslines = run(function()
			sert.test("picked", function() end)
			sert.test("other", function() end)
		end, { filter = "picked" })
		expect(find(nslines, "1 not selected") ~= nil)

		-- sert.shard
		local shard = require("../src/core/runner").shard
		expect(sert.shard() == nil and sert.shardSelects("anything"))
		local function regShard()
			sert.test("suite.store a", function() end)
			sert.test("parity c", function() end)
		end
		shard.set({ name = "store", index = 1, count = 2, runLimit = 120, only = { "suite.store" } })
		expect(sert.shard() ~= nil and sert.shardSelects("suite.store x") and not sert.shardSelects("parity c"))
		local _, onlyLines = run(regShard, { markers = true })
		local _, offLines = run(regShard, { markers = true, shard = false })
		shard.set({ name = "rest", index = 2, count = 2, runLimit = 120, except = { "suite." } })
		local _, exceptLines = run(regShard, { markers = true })
		shard.set(nil)
		eq({ #markers(onlyLines, "test"), #markers(offLines, "test"), #markers(exceptLines, "test") }, { 1, 2, 1 })
	end
)

test("expect, fn/spy, deepEquals DAG/cycles, mutant runs, modifiers, file attribution, and argument checks", function()
	-- expect normal and .never matchers
	sert.expect(1).toBe(1)
	sert.expect(1).never.toBe(2)
	fails(function() sert.expect(1).toBe(2) end, "values differ")
	fails(function() sert.expect(1).never.toBe(1) end, "expected not 1")

	local metaA, metaB, metaC = setmetatable({ x = 1 }, {}), setmetatable({ x = 1 }, {}), setmetatable({ x = 2 }, {})
	sert.expect(metaA).toRawEqual(metaB)
	sert.expect(metaA).never.toRawEqual(metaC)
	sert.expect(metaA).never.toEqual(metaB)
	fails(function() sert.expect(metaA).toRawEqual(metaC) end, "values differ")
	fails(function() sert.expect(metaA).never.toRawEqual(metaB) end, "expected not")

	sert.expect(nil).toBeNil()
	sert.expect(1).never.toBeNil()
	fails(function() sert.expect(nil).never.toBeNil() end, "not to be nil")
	sert.expect(true).toBeTruthy()
	sert.expect(false).never.toBeTruthy()
	sert.expect(false).toBeFalsy()
	sert.expect(true).never.toBeFalsy()
	sert.expect(1.00001).toBeCloseTo(1, 3)
	sert.expect(2).never.toBeCloseTo(1, 3)

	sert.expect(function() error("kaboom") end).toThrow("kaboom")
	sert.expect(function() end).never.toThrow()
	sert.expect(function() error("other") end).never.toThrow("kaboom")
	fails(function()
		sert.expect(function() end).toThrow()
	end, "expected function to throw")
	fails(function()
		sert.expect(function() error("kaboom") end).never.toThrow()
	end, "not to throw")
	fails(function()
		sert.expect(function() error("kaboom") end).never.toThrow("kaboom")
	end, 'not to throw "kaboom"')

	sert.expect(0 / 0).toBeNaN()
	sert.expect(1).never.toBeNaN()
	fails(function() sert.expect(1).toBeNaN() end, "expected NaN")
	fails(function() sert.expect(0 / 0).never.toBeNaN() end, "not to be NaN")

	sert.expect(42).toBeFinite()
	sert.expect(math.huge).never.toBeFinite()
	fails(function() sert.expect(math.huge).toBeFinite() end, "expected finite")
	fails(function() sert.expect(42).never.toBeFinite() end, "expected not finite")

	sert.expect(5).toBeGreaterThan(3)
	sert.expect(3).never.toBeGreaterThan(5)
	fails(function() sert.expect(3).toBeGreaterThan(5) end, "expected > 5")
	fails(function() sert.expect(5).never.toBeGreaterThan(3) end, "expected not > 3")
	sert.expect(5).toBeGreaterThanOrEqual(5)
	sert.expect(3).never.toBeGreaterThanOrEqual(5)
	fails(function() sert.expect(3).toBeGreaterThanOrEqual(5) end, "expected >= 5")
	fails(function() sert.expect(5).never.toBeGreaterThanOrEqual(5) end, "expected not >= 5")
	sert.expect(3).toBeLessThan(5)
	sert.expect(5).never.toBeLessThan(3)
	fails(function() sert.expect(5).toBeLessThan(3) end, "expected < 3")
	fails(function() sert.expect(3).never.toBeLessThan(5) end, "expected not < 5")
	sert.expect(5).toBeLessThanOrEqual(5)
	sert.expect(6).never.toBeLessThanOrEqual(5)
	fails(function() sert.expect(6).toBeLessThanOrEqual(5) end, "expected <= 5")
	fails(function() sert.expect(5).never.toBeLessThanOrEqual(5) end, "expected not <= 5")

	local part = sert.doubles.Instance.new("Part")
	sert.expect("hi").toBeA("string")
	sert.expect(part).toBeA("BasePart")
	sert.expect(part).never.toBeA("TextLabel")
	fails(function() sert.expect(part).toBeA("TextLabel") end, "expected a TextLabel")
	fails(function() sert.expect(part).never.toBeA("BasePart") end, "not to be a BasePart")

	sert.expect("hello world").toContain("world")
	sert.expect({ { id = 1 }, { id = 2 } }).toContain({ id = 2 })
	sert.expect({ 1, 2 }).never.toContain(4)
	fails(function() sert.expect("abc").toContain("xyz") end, "to contain")
	fails(function() sert.expect("abc").never.toContain("b") end, "not to contain")
	fails(function() sert.expect(123).toContain("1") end, "expected string or table")

	sert.expect("v1.2.3").toMatch("^v%d+")
	sert.expect("abc").never.toMatch("%d+")
	fails(function() sert.expect("abc").toMatch("%d+") end, "to match pattern")
	fails(function() sert.expect("123").never.toMatch("%d+") end, "not to match pattern")

	sert.expect("abcd").toHaveLength(4)
	sert.expect({ 10, 20 }).toHaveLength(2)
	sert.expect(buffer.create(7)).toHaveLength(7)
	sert.expect("abcd").never.toHaveLength(2)
	fails(function() sert.expect("ab").toHaveLength(5) end, "expected length 5")
	fails(function() sert.expect("ab").never.toHaveLength(2) end, "not to be 2")
	fails(function() sert.expect(123).toHaveLength(1) end, "expected string, table, or buffer")

	-- fn and spy
	local fn = sert.fn(function(a: number, b: number) return a + b, a * b end)
	sert.expect(fn).never.toHaveBeenCalled()
	eq({ fn(3, 4) }, { 7, 12 })
	sert.expect(fn).toHaveBeenCalled()
	sert.expect(fn).toHaveBeenCalledTimes(1)
	sert.expect(fn).toHaveBeenCalledWith(3, 4)
	sert.expect(fn).never.toHaveBeenCalledWith(1, 2)
	for _, bad in
		{
			function() sert.expect(fn).never.toHaveBeenCalled() end,
			function() sert.expect(fn).toHaveBeenCalledTimes(2) end,
			function() sert.expect(fn).never.toHaveBeenCalledTimes(1) end,
			function() sert.expect(fn).toHaveBeenCalledWith(9, 9) end,
			function() sert.expect(fn).never.toHaveBeenCalledWith(3, 4) end,
			function() sert.expect("x").toHaveBeenCalled() end,
			function() sert.expect("x").toHaveBeenCalledTimes(1) end,
			function() sert.expect("x").toHaveBeenCalledWith(1) end,
		}
	do
		fails(bad)
	end
	fn:reset()
	fails(function() sert.expect(fn).toHaveBeenCalled() end, "expected spy to have been called")
	fn:mockReturnValue("fixed", 99)
	eq({ fn("ignored") }, { "fixed", 99 })
	fn:mockImplementation(function() error("spy boom", 0) end)
	fails(function() fn() end, "spy boom")
	sert.fn():restore()

	-- deepEquals DAG and cycles
	local shared = { a = 1, b = { 2, 3 } }
	eq({ first = shared, second = shared }, { first = { a = 1, b = { 2, 3 } }, second = { a = 1, b = { 2, 3 } } })
	local cycA: any, cycB1: any, cycB2: any = { tag = "x" }, { tag = "x" }, { tag = "x" }
	cycA.self, cycA.other = cycA, cycA
	cycB1.self, cycB1.other = cycB1, cycB2
	cycB2.self, cycB2.other = cycB2, cycB1
	eq(cycA, cycB1)

	-- mutant capMutant, ordering, and batch beforeAll/afterAll
	local outer = mutant.get()
	mutant.set(900020)
	local capped = prop.run("capped", function() end, { runs = 40 }, {}, true)
	local uncapped = prop.run("uncapped", function() end, { runs = 40 }, {})
	local failedCap = prop.run("unshrunk", function(g) sert(g:int(0, 1000) < 10) end, { runs = 40 }, {}, true)
	mutant.set(outer)
	eq({ capped.cases, uncapped.cases, failedCap.attempts }, { 15, 40, 0 })

	eq(sert.parseCliArgs({ "--mutants=1,2,3" }).mutants, { 1, 2, 3 })
	local mlog = {}
	local mlines = sert.capture(function()
		sert.isolate(function()
			sert.beforeAll(function() table.insert(mlog, "bAll") end)
			sert.afterAll(function() table.insert(mlog, "aAll") end)
			sert.prop("slow prop", function() table.insert(mlog, "prop") end, { runs = 1 })
			sert.test("unit", function()
				table.insert(mlog, "unit")
				if mutant.get() == 900002 then error("killed", 0) end
			end)
			sert.run({ mutants = { 900001, 900002 } })
			sert.run({ mutant = 900005, raise = false })
		end)
	end)
	eq(markers(mlines, "mutant"), { "900001=SURVIVED", "900002=KILLED" })
	eq({ mutant.get(), #mlog > 0 }, { nil, true })

	-- modifiers (describe.skip/focus, each/prop/check skip/focus, todo, timeout, case-insensitive filters, suite file)
	local resSkip = runMarked(function()
		sert.describe.skip("off", function()
			sert.test("a", function() end)
		end)
		sert.each("c", { 1 }, function() end, { skip = true })
		sert.prop("p", function() end, { skip = true })
		sert.check("k", sert.gen.int(1, 2), function() end, { skip = true })
		sert.test("t", function() end, { skip = true })
		sert.todo("write this")
		sert.test("runs", function() end, { timeout = 5 })
	end)
	eq({ resSkip.passed, resSkip.skipped, resSkip.todo }, { 1, 5, 1 })

	local resFocus = runMarked(function()
		sert.describe.focus("on", function()
			sert.test("a", function() end)
		end)
		sert.each("c", { 1 }, function() end, { focus = true })
		sert.prop("p", function() end, { focus = true, runs = 1 })
		sert.check("k", sert.gen.int(1, 2), function() end, { focus = true, runs = 1 })
		sert.test("unfocused", function() end)
	end)
	eq({ resFocus.passed, resFocus.skipped }, { 4, 1 })

	local sLog = {}
	local _, sLines = runMarked(function()
		suite(sert, sLog)
		sert.test("mine", function() table.insert(sLog, "mine") end)
		sert.test("wrapped", function() end, { file = "test/unit/Caller.spec.luau" })
		sert.describe("blk", function()
			sert.test("in", function() end)
		end, { file = "Block.spec" })
	end)
	eq(sLog, { "suite+", "suite", "mine" })
	sert.contains(table.concat(sLines, "\n"), '"file":"suite"')

	-- inline prop/check inside a running test
	local iRes = runMarked(function()
		sert.test("outer", function()
			sert.prop("from run", function(g) g:int(1, 10) end, { runs = 2 })
			sert.prop("own seed", function(g) g:int(1, 10) end, { runs = 2, seed = 42 })
			sert.check("checked", sert.gen.int(1, 10), function() end, { runs = 2 })
			sert.prop("breaks", function(g) sert(g:int(0, 9) < 5) end)
		end)
	end, { seed = 1 })
	eq(iRes.failed, 1)

	-- registration argument checks & sert.loaded
	local fn0 = function() end
	local okChecks, errChecks = sert.isolate(function()
		for _, call in
			{
				function() sert.prop("s", { runs = 10 } :: any, fn0 :: any) end,
				function() sert.test("s", { timeout = 1 } :: any, fn0 :: any) end,
				function() sert.test("n", nil :: any) end,
				function() sert.rtest(fn0 :: any, "s" :: any) end,
				function() (sert.todo :: any)("l", fn0) end,
				function() sert.focus("o", fn0, "fast" :: any) end,
				function() sert.prop("t", fn0, { run = 3 } :: any) end,
				function() sert.test("t", fn0, { runs = 3 } :: any) end,
				function() sert.skip("t", fn0, { only = true } :: any) end,
				function() sert.each("c", fn0 :: any, fn0) end,
				function() sert.each("c", { 1 }, fn0, { label = "x" } :: any) end,
				function() sert.check("s", fn0 :: any, { sert.gen.int(1, 2) } :: any) end,
				function() sert.check("f", { sert.gen.int(1, 2), 3 } :: any, fn0) end,
				function() sert.check("n", {}, fn0) end,
				function() sert.model("q", { init = fn0, commands = {} }, { steps = 4 } :: any) end,
				function() sert.model("q") end,
				function() sert.describe("b", { separator = "/" } :: any, fn0 :: any) end,
				function() sert.describe.skip("b", fn0, { sep = "/" } :: any) end,
				function() sert.beforeEach("notfn" :: any) end,
				function() sert.afterAll(nil :: any) end,
				function() sert.setup({ before = fn0 } :: any) end,
				function() sert.setup({ beforeEach = true } :: any) end,
			}
		do
			fails(call)
		end
	end)
	expect(okChecks, errChecks)
	fails(function() sert.defer(42 :: any) end, "sert.defer: expected a function")
	eq({ sert.loaded(nil), sert.loaded(fn0), sert.loaded("plain") }, { nil, fn0, "plain" })
	fails(
		function() sert.loaded("./test/Bad.spec.luau:1: Expected identifier when parsing expression, got '='") end,
		"failed to load a spec"
	)
end)

local function withEnv(options: { [string]: any }?, fn: (any, { string }) -> ())
	if (getfenv :: any) == nil then return end
	local e = sert.env.new(options or { isStudio = true })
	local logLines = {}
	local logService = e.game:GetService("LogService")
	logService.MessageOut:Connect(function(msg: string) table.insert(logLines, msg) end)
	local runnerEnvs: { any } = { getfenv(RobloxRunner.args), getfenv(RobloxSession.request) }
	local sertEnv: any = getfenv(sert.print)
	local keys = { "game", "workspace", "Instance", "DateTime", "Random", "task", "os", "require", "print", "warn" }
	local savedRunner = {}
	for i, rEnv in runnerEnvs do
		savedRunner[i] = {}
		for _, k in keys do
			savedRunner[i][k] = rawget(rEnv, k)
		end
	end
	local savedPrint, savedWarn = rawget(sertEnv, "print"), rawget(sertEnv, "warn")
	local function fireLog(...: any) logService.MessageOut:Fire(tostring(select(1, ...))) end
	for _, rEnv in runnerEnvs do
		rEnv.game, rEnv.workspace = e.game, e.workspace
		rEnv.Instance, rEnv.DateTime, rEnv.Random = e.globals.Instance, e.globals.DateTime, e.globals.Random
		rEnv.task, rEnv.os = e.globals.task, e.globals.os
		rEnv.require = function(target: any) return e:require(target) end
		rEnv.print = fireLog
		rEnv.warn = function(...: any)
			if e.globals.warn ~= nil then e.globals.warn(...) end
		end
	end
	sertEnv.print, sertEnv.warn = fireLog, fireLog
	local ok, err = sert.isolate(function() fn(e, logLines) end)
	for i, rEnv in runnerEnvs do
		for _, k in keys do
			rawset(rEnv, k, savedRunner[i][k])
		end
	end
	rawset(sertEnv, "print", savedPrint)
	rawset(sertEnv, "warn", savedWarn)
	if not ok then error(err, 0) end
end

test("roblox.Runner · marker, phase, request, sides, args, runHere, and edit/server/client lifecycles", function()
	withEnv({ isStudio = true }, function(e, logLines)
		RobloxRunner.marker("perf", "12ms")
		RobloxRunner.phase("server", "ready")
		expect(find(logLines, "[sert-x:perf] 12ms") ~= nil and find(logLines, "[sert-phase] server ready ") ~= nil)
		fails(function() RobloxRunner.phase("server", "world built") end, "one word each")
		fails(function() RobloxRunner.phase("", "ready") end, "one word each")

		local rs = e.game:GetService("RunService")
		rs._props.IsRunMode = true
		local reqRun = RobloxSession.request({
			runId = "r1",
			filter = "",
			filters = { "ui", 42 },
			names = { "n1", 2 },
			files = {},
			excludes = { "ex" },
			sides = { "server" },
			list = true,
			seed = 99,
			runs = 15,
			seeds = { propA = 123, bad = -1, frac = 1.5 },
			replay = 7,
			exhaustive = true,
			budget = 25,
			command = "custom-cmd",
			["repeat"] = 3,
			timeout = 12,
			deadline = 45,
			extraFlag = true,
		})
		eq({ reqRun.mode, reqRun.filter, reqRun.iterations }, { "run", nil, 3 })
		eq(
			{ reqRun.filters, reqRun.names, reqRun.seeds, reqRun.unknown },
			{ { "ui", "42" }, { "n1", "2" }, { propA = 123 }, { "extraFlag" } }
		)

		rs._props.IsRunMode, rs._props.IsRunning = false, true
		eq(RobloxSession.request({}).mode, "play")
		rs._props.IsRunning = false
		eq(RobloxSession.request({}).mode, "edit")
		eq(RobloxSession.request({ iterations = 3 }).unknown, { "iterations" })

		local explicit = RobloxSession.sides({ sides = { ui = {}, server = {}, client = { where = "server" :: any } } })
		eq({ explicit[1].name, explicit[2].name, explicit[3].name }, { "server", "client", "ui" })
		local ordered = RobloxSession.sides({ sides = { a = {}, server = {}, b = {} }, order = { "b", "server" } })
		eq({ ordered[1].name, ordered[2].name, ordered[3].name }, { "b", "server", "a" })
		local entryMod = e.Instance.new("ModuleScript")
		eq(RobloxSession.sides({ entry = entryMod })[1].name, "main")

		local rootFolder = e.Instance.new("Folder")
		local srvFolder = e.Instance.new("Folder", rootFolder)
		srvFolder.Name = "server"
		e.Instance.new("ModuleScript", srvFolder).Name = "Net.spec"
		local cliFolder = e.Instance.new("Folder", rootFolder)
		cliFolder.Name = "client"
		e.Instance.new("ModuleScript", cliFolder).Name = "Ui.spec"
		e.Instance.new("Folder", rootFolder).Name = "empty"
		eq(#RobloxSession.sides({ root = rootFolder }), 2)
		eq(RobloxSession.sides({ root = e.Instance.new("Folder") })[1].name, "main")

		local HttpService = e.game:GetService("HttpService")
		e.workspace:SetAttribute(
			RobloxSession.ARGS_ATTRIBUTE,
			HttpService:JSONEncode({ runId = "attr-1", mode = "run" })
		)
		eq((RobloxRunner.args(0.05) :: any).runId, "attr-1")
		e.workspace:SetAttribute(RobloxSession.ARGS_ATTRIBUTE, "{invalid-json")
		local sts = e.game:GetService("StudioTestService")
		sts._props.TestArgs = { runId = "sts-2" }
		eq((RobloxRunner.args(0.05) :: any).runId, "sts-2")
		e.workspace:SetAttribute(RobloxSession.ARGS_ATTRIBUTE, nil)
		sts._props.TestArgs = nil
		eq(RobloxRunner.args(0.05), nil)

		-- runHere on server root with passing/failing/broken specs, iterations, hooks, and scriptErrors
		local root = e.Instance.new("Folder")
		local alpha = e.Instance.new("ModuleScript", root)
		alpha.Name = "Runner.spec"
		rawset(alpha, "_factory", function()
			return function(s: any)
				s.test("alpha pass", function() end)
				s.todo("alpha later")
				s.prop("alpha prop fail", function(g: any)
					g:int(0, 5)
					error("prop failed", 0)
				end, { runs = 3 })
			end
		end)
		local beta = e.Instance.new("ModuleScript", root)
		beta.Name = "Other.spec"
		rawset(beta, "_factory", function()
			Other(sert, {})
			return nil
		end)
		local broken = e.Instance.new("ModuleScript", root)
		broken.Name = "Broken.spec"
		rawset(broken, "_factory", function() error("load explosion", 0) end)

		local cfg: any = {
			sert = sert,
			scriptErrors = true,
			context = function(ctx) return ctx.sert, ctx end,
			sides = {
				server = {
					root = root,
					filter = "alpha",
					setup = { beforeEach = function() end, afterEach = function() end },
					before = function()
						e.game:GetService("RunService").Heartbeat:Fire(0.02)
						e.game:GetService("ScriptContext").Error:Fire("script boom", "line1\nline2")
					end,
					after = function() error("after hook broke", 0) end,
				},
			},
		}
		local partial = RobloxSession.runHere(
			cfg,
			RobloxSession.request({ mode = "run", ["repeat"] = 2 }),
			"server",
			RobloxSession.sides(cfg),
			nil
		)
		eq(partial.counts, { passed = 2, failed = 6, skipped = 2, todo = 2, total = 12 })
	end)

	-- Client runHere: entry loading, list mode, hideChat, warmup, file filtering, handoff, and stubSert
	withEnv({ isStudio = true, isClient = true }, function(e)
		local tcs = e.game:GetService("TextChatService")
		local chatWin = e.Instance.new("Folder", tcs)
		chatWin.Name, chatWin._props.Enabled = "ChatWindowConfiguration", true
		local chatBar = e.Instance.new("Folder", tcs)
		chatBar.Name, chatBar._props.Enabled = "ChatInputBarConfiguration", true

		local entryOk = e.Instance.new("ModuleScript")
		entryOk.Name = "EntryOk.spec"
		rawset(entryOk, "_factory", function()
			sert.test("entry test", function() end)
			return nil
		end)
		local entryBad = e.Instance.new("ModuleScript")
		entryBad.Name = "EntryBad.spec"
		rawset(entryBad, "_factory", function() error("entry load broke", 0) end)

		local listCfg: any = {
			sert = sert,
			scriptErrors = true,
			sides = { client = { entry = entryOk }, broken = { entry = entryBad }, empty = {} },
		}
		local listPartial = RobloxSession.runHere(
			listCfg,
			RobloxSession.request({ mode = "play", list = true }),
			"server",
			RobloxSession.sides(listCfg),
			function() end
		)
		eq(listPartial.listed, 1)

		local warmCleaned = false
		local clientRoot = e.Instance.new("Folder")
		local modA = e.Instance.new("ModuleScript", clientRoot)
		modA.Name = "Runner.spec"
		rawset(modA, "_factory", function()
			return function(ctx: any)
				ctx.sert.test("modA test", function() end)
			end
		end)
		local clientCfg: any = {
			sert = sert,
			hideChat = true,
			warmup = function()
				e.task.spawn(function()
					for _ = 1, 5 do
						e.task.wait(0.03)
						e.game:GetService("RunService").Heartbeat:Fire(0.016)
					end
				end)
				return function() warmCleaned = true end
			end,
			sides = {
				skippedByFile = { root = clientRoot },
				matchedByFile = { root = clientRoot },
				beforeFails = { root = clientRoot, before = function() error("before hook exploded", 0) end },
			},
		}
		local cPartial = RobloxSession.runHere(
			clientCfg,
			RobloxSession.request({ mode = "play", files = { "matchedByFile/Runner", "beforeFails/Runner" } }),
			"client",
			RobloxSession.sides(clientCfg),
			nil
		)
		expect(not chatWin.Enabled and not chatBar.Enabled and warmCleaned and cPartial.sides.skippedByFile == nil)

		local orderLog = {}
		local stubSert = {
			setup = function() end,
			capture = function() error("no capture", 0) end,
			run = function(opts: any)
				if opts.list then return { total = 2 } end
				if opts.filter == "count-err" then error("1 of 2 tests failed", 0) end
				if opts.filter == "fatal-err" then error("fatal runner crash", 0) end
				return { passed = 1, failed = 0, skipped = 0, total = 1 }
			end,
		}
		local handoffCfg: any = {
			sert = stubSert,
			sides = {
				serialSide = {
					entry = entryOk,
					filter = "count-err",
					before = function() table.insert(orderLog, "serial") end,
				},
				concSide = {
					entry = entryOk,
					concurrent = true,
					filter = "fatal-err",
					before = function() table.insert(orderLog, "concurrent") end,
				},
			},
			order = { "serialSide", "concSide" },
		}
		RobloxSession.runHere(
			handoffCfg,
			RobloxSession.request({ mode = "play" }),
			"server",
			RobloxSession.sides(handoffCfg),
			function() table.insert(orderLog, "handoff") end
		)
		eq(orderLog, { "serial", "handoff", "concurrent" })
		eq(
			RobloxSession.runHere(
				handoffCfg,
				RobloxSession.request({ mode = "play", files = { "Runner" } }),
				"server",
				RobloxSession.sides(handoffCfg),
				nil
			).counts.passed,
			2
		)
	end)

	-- Runner.edit, Runner.server, and Runner.client lifecycles
	withEnv({ isStudio = true }, function(e)
		local mod = { f = function() return "real" end }
		local root = e.Instance.new("Folder")
		local specMod = e.Instance.new("ModuleScript", root)
		specMod.Name = "Runner.spec"
		rawset(specMod, "_factory", function()
			return function(ctx: any)
				ctx.sert.spy(mod, "f", function() return "stub" end)
				ctx.sert.test(`edit test {ctx.side}`, function() eq(mod.f(), "stub") end)
			end
		end)
		local cfg: any = { name = "EditSuite", sert = sert, root = root, randomSeed = true }
		local resPass = RobloxRunner.edit(cfg, { runId = "e-pass", ["repeat"] = 2, custom = 1 })
		expect(resPass.passed and resPass.seed ~= nil and mod.f() == "real")
		e.workspace:SetAttribute(
			RobloxSession.ARGS_ATTRIBUTE,
			e.game:GetService("HttpService"):JSONEncode({ runId = "e-list", list = true })
		)
		expect(RobloxRunner.edit(cfg).listed == true)
		expect(
			RobloxRunner.edit(
				{ sert = sert, root = root, scriptErrors = true },
				{ runId = "e-none", filter = "nothing" }
			).passed == false
		)
		expect(
			RobloxRunner.edit(
				{ sert = sert, root = root, scriptErrors = true },
				{ runId = "e-one", filter = "edit test" }
			).passed == true
		)

		local merged = RobloxSession.newPartial()
		RobloxSession.merge(merged, {
			counts = { passed = 1, failed = 0, skipped = 0, todo = 0, total = 1 },
			sides = {},
			failures = {},
			seeds = {},
			listed = 0,
			runnerPassed = 1,
		})
		expect(RobloxSession.verdict({}, RobloxSession.request({ mode = "play" }), merged).passed == false)

		local sts = e.game:GetService("StudioTestService")
		e.workspace:SetAttribute(RobloxSession.ARGS_ATTRIBUTE, nil)
		RobloxRunner.server({ sert = sert })
		expect(sts._props.EndedResult == nil)

		sts._props.TestArgs = { runId = "srv-run", mode = "run" }
		RobloxRunner.server({
			name = "SrvSuite",
			sert = sert,
			characters = false,
			randomSeed = true,
			sides = { server = { root = root }, client = { root = root } },
		})
		expect(sts._props.EndedResult.passed == true)

		sts._props.TestArgs = { runId = "srv-timeout", mode = "play", deadline = 0.02 }
		RobloxRunner.server({ sert = sert, sides = { server = { root = root }, client = { root = root } } })
		expect(sts._props.EndedResult.passed == false)

		local rs = e.game:GetService("ReplicatedStorage")
		e.Instance.new("StringValue", rs).Name = RobloxSession.REQUEST
		sts._props.TestArgs = { runId = "srv-play", mode = "play", deadline = 5 }
		rawset(sts, "_methods", {
			GetTestArgs = function(s: any) return s._props.TestArgs end,
			EndTest = function() error("EndTest rejected", 0) end,
		})
		RobloxRunner.server({
			sert = sert,
			sides = {
				server = {
					root = root,
					concurrent = true,
					after = function()
						rs:FindFirstChild(RobloxSession.RESULT).OnServerEvent:Fire(
							nil,
							"srv-play",
							e.game:GetService("HttpService"):JSONEncode({
								counts = { passed = 1, failed = 0, skipped = 0, total = 1 },
								sides = { client = { passed = 1, failed = 0, skipped = 0, total = 1, ms = 1 } },
								failures = {},
								seeds = { p = 1 },
								listed = 1,
								runnerPassed = 0,
							})
						)
					end,
				},
				client = { root = root },
			},
		})
		rawset(sts, "_methods", {
			GetTestArgs = function(s: any) return s._props.TestArgs end,
			EndTest = function(s: any, r: any) s._props.EndedResult = r end,
		})
		sts._props.TestArgs = { runId = "srv-bad-json", mode = "play", deadline = 5 }
		RobloxRunner.server({
			sert = sert,
			sides = {
				server = {
					root = root,
					concurrent = true,
					after = function()
						rs:FindFirstChild(RobloxSession.RESULT).OnServerEvent:Fire(nil, "srv-bad-json", "{not-json")
					end,
				},
				client = { root = root },
			},
		})
		expect(find(sts._props.EndedResult.failures, "undecodable client report") ~= nil)
	end)

	withEnv({ isStudio = false }, function() RobloxRunner.server({ sert = sert }) end)
	withEnv({ isStudio = false, isClient = true }, function() eq(RobloxRunner.client({ sert = sert }), nil) end)

	withEnv({ isStudio = true, isClient = true }, function(e)
		local root = e.Instance.new("Folder")
		local cliMod = e.Instance.new("ModuleScript", root)
		cliMod.Name = "Runner.spec"
		rawset(cliMod, "_factory", function()
			return function(ctx: any)
				ctx.sert.test("cli test", function() end)
			end
		end)
		local loaded = false
		local origGetService = e.game._methods.GetService
		rawset(e.game, "_methods", { IsLoaded = function() return loaded end, GetService = origGetService })
		e.task.spawn(function()
			e.task.wait(0.03)
			loaded = true
			e.game.Loaded:Fire()
		end)
		local player = e:addPlayer(1, "Alice")
		e.Players._props.LocalPlayer, e.LocalPlayer = player, player
		local rs = e.game:GetService("ReplicatedStorage")
		local reqVal = e.Instance.new("StringValue", rs)
		reqVal.Name = RobloxSession.REQUEST
		reqVal.Value =
			e.game:GetService("HttpService"):JSONEncode({ args = { runId = "c1" }, seed = 4242, command = "cmd" })
		local resEvent = e.Instance.new("RemoteEvent", rs)
		resEvent.Name = RobloxSession.RESULT
		local firedRunId
		resEvent.OnServerEvent:Connect(function(_plr: any, rId: any) firedRunId = rId end)
		e.workspace:SetAttribute(RobloxSession.RUN_ATTRIBUTE, "c1")
		RobloxRunner.client({
			sert = sert,
			hideChat = false,
			sides = { server = { root = root }, client = { root = root } },
		})
		eq(firedRunId, "c1")

		reqVal.Value = "{bad-json"
		local badPayload
		resEvent.OnServerEvent:Connect(function(_plr: any, _rId: any, payload: any) badPayload = payload end)
		RobloxRunner.client({
			sert = sert,
			sides = { client = { root = root } },
		})
		expect(badPayload ~= nil and string.find(badPayload, "invalid sert.Request JSON", 1, true) ~= nil)
	end)

	-- nested sert.quiet inside sert.capture preserves captureSink, and yielding/afterAll/list preserve spy lifecycle
	local nestedLines = sert.quiet(function()
		return sert.capture(function()
			sert.quiet(function() sert.print("muted") end)
			sert.print("captured-after-inner-quiet")
		end)
	end)
	eq(nestedLines, { "captured-after-inner-quiet" })

	local modTarget = { fn = function() return "orig" end }
	local seenInSecond: string? = nil
	local afterAllTarget = { fn = function() return "orig" end }
	local isoOk1, isoErr1 = sert.quiet(sert.isolate, function()
		sert.spy(modTarget, "fn", function() return "spied" end)
		local emptyList = sert.run({ list = true, silent = true })
		eq({ emptyList.total, modTarget.fn() }, { 0, "spied" })
		if (game :: any) == nil then sert.test("yields first", function() coroutine.yield() end) end
		sert.test("runs second with module spy intact", function() seenInSecond = modTarget.fn() end)
		sert.describe("failing afterAll scope", function()
			sert.beforeAll(function()
				sert.spy(afterAllTarget, "fn", function() return "scoped" end)
			end)
			sert.afterAll(function() error("afterAll boom") end)
			sert.test("scoped test", function() eq(afterAllTarget.fn(), "scoped") end)
		end)
		sert.run({ raise = false, silent = true })
	end)
	if not isoOk1 then error(isoErr1, 0) end
	eq({ seenInSecond, modTarget.fn(), afterAllTarget.fn() }, { "spied", "orig", "orig" })

	-- failFast with unselected tests does not produce negative skipped count
	local ffLines = sert.capture(function()
		local ffOk, ffErr = sert.isolate(function()
			sert.test("ff-a", function() error("boom", 0) end)
			sert.test("ff-b", function() end)
			sert.skip("ff-c", function() end)
			local ffRes = sert.run({ filter = "ff-a", failFast = true, raise = false })
			eq({ ffRes.passed, ffRes.failed, ffRes.skipped }, { 0, 1, 2 })
		end)
		if not ffOk then error(ffErr, 0) end
	end)
	expect(find(ffLines, "0 passed · 1 failed · 0 skipped · 2 not selected") ~= nil)

	-- sert.spy delegates to callable tables and stacked spies when impl is nil
	local callHolder: { [string]: any } = {
		fn = setmetatable({}, { __call = function(_, x: number) return x + 10 end }),
	}
	local isoOk2, isoErr2 = sert.quiet(sert.isolate, function()
		local s1 = sert.spy(callHolder, "fn")
		local s2 = sert.spy(callHolder, "fn")
		eq(callHolder.fn(5), 15)
		eq({ s1.callCount, s2.callCount }, { 1, 1 })
	end)
	if not isoOk2 then error(isoErr2, 0) end

	-- RobloxSession.runHere scopes same-named specs across sides
	withEnv({ isStudio = true }, function(e)
		local rootA = e.Instance.new("Folder")
		local modA = e.Instance.new("ModuleScript", rootA)
		modA.Name = "SharedName.spec"
		rawset(modA, "_factory", function()
			return function(ctx: any)
				ctx.sert.test("from sideA", function() end)
			end
		end)
		local rootB = e.Instance.new("Folder")
		local modB = e.Instance.new("ModuleScript", rootB)
		modB.Name = "SharedName.spec"
		rawset(modB, "_factory", function()
			return function(ctx: any)
				ctx.sert.test("from sideB", function() end)
			end
		end)
		local isoOk3, isoErr3 = sert.quiet(sert.isolate, function()
			local sameNameCfg: any = {
				sert = sert,
				sides = {
					sideA = { root = rootA, rtestOnly = false },
					sideB = { root = rootB },
				},
				order = { "sideA", "sideB" },
			}
			local part = RobloxSession.runHere(
				sameNameCfg,
				RobloxSession.request({ mode = "play", files = { "SharedName" } }),
				"server",
				RobloxSession.sides(sameNameCfg),
				nil
			)
			eq({ part.counts.passed, part.sides.sideA.passed, part.sides.sideB.passed }, { 2, 1, 1 })
		end)
		if not isoOk3 then error(isoErr3, 0) end
	end)
end)

return {}
