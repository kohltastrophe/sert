--!nonstrict
-- sert.prop, parseCliArgs, spy lifecycle, focus, defer, and hooks.
local IS_ROBLOX = game ~= nil
local sert, mutant
if IS_ROBLOX then
	local ReplicatedStorage = game:GetService("ReplicatedStorage")
	sert = require(ReplicatedStorage:WaitForChild("sert")) :: any
	mutant = require(ReplicatedStorage.sert.core.registry).mutant :: any
else
	sert = require("../src") :: any
	mutant = require("../src/core/registry").mutant
end

local test = sert.test
local expect = sert

local function sum(list: { number }): number
	local total = 0
	for _, v in list do
		total += v
	end
	return total
end

local function recorder(seen: { string })
	return function(g)
		local list = g:list(function(g) return g:int(0, 9) end, 0, 6)
		table.insert(
			seen,
			`{g:pick({ "a", "b", "c" })}{g:weighted({ { 1, "x" }, { 3, "y" } })}{table.concat(list, "")}`
		)
	end
end

test("prop · determinism, domains, shrinking, notes, replay, exhaustive, and budget", function()
	local first, second, other, renamed = {}, {}, {}, {}
	expect(sert.prop.run("determinism", recorder(first), { runs = 50 }, {}).ok)
	expect(sert.prop.run("determinism", recorder(second), { runs = 50 }, {}).ok)
	expect(sert.prop.run("determinism", recorder(other), { runs = 50 }, { seed = 1234 }).ok)
	sert.prop.run("determinism 2", recorder(renamed), { runs = 50 }, {})
	sert.eq(first, second)
	expect(
		#first == 50
			and table.concat(first, "|") ~= table.concat(other, "|")
			and table.concat(first, "|") ~= table.concat(renamed, "|")
	)

	local domRes = sert.prop.run("domains", function(g)
		local n = g:int(-3, 3)
		expect(n >= -3 and n <= 3 and n == math.floor(n))
		expect(type(g:bool()) == "boolean" and g:bool(0) == false and g:bool(1) == true)
		expect(g:weighted({ { 0, "never" }, { 2, "always" } }) == "always")
		expect(#g:list(function(g) return g:bool() end) <= g.size)
		expect(#g:list(function(g) return g:int(1, 2) end, 2, 3) >= 2)
	end, { runs = 10, size = 5 }, { runs = 300 })
	expect(domRes.ok and domRes.cases == 300)

	local shrinkRes = sert.prop.run("every element < 10", function(g)
		local list = g:list(function(g) return g:int(0, 100) end)
		g:note("list %s", table.concat(list, ","))
		for _, v in list do
			expect(v < 10, `element {v}`)
		end
	end, {})
	expect(not shrinkRes.ok and #shrinkRes.shrunk <= #shrinkRes.tape)
	sert.eq(shrinkRes.shrunk, { 1, 10, 0 })
	sert.eq(shrinkRes.notes, { "list 10" })
	expect(string.find(shrinkRes.message, "element 10", 1, true) ~= nil)
	for _, needle in { `--replay={shrinkRes.seed}`, "   first failure:", "   trace:", "list 10" } do
		expect(string.find(shrinkRes.report, needle, 1, true) ~= nil)
	end

	local summed = sert.prop.run("sum < 10", function(g)
		expect(sum(g:list(function(g) return g:int(0, 100) end)) < 10)
	end, {})
	expect(not summed.ok and #summed.shrunk <= 5)
	local sList = {}
	for i = 2, #summed.shrunk, 2 do
		if summed.shrunk[i - 1] == 1 then table.insert(sList, summed.shrunk[i]) end
	end
	expect(sum(sList) == 10)

	local aligned = sert.prop.run("aligned", function(g)
		g:note("[header]\n  child\n\n  after a blank")
		error("first line\nsecond line", 0)
	end, { runs = 1 })
	expect(not aligned.ok)
	expect(string.find(aligned.report, 'property "aligned" failed: first line\n   second line\n', 1, true) ~= nil)
	expect(
		string.find(aligned.report, "   trace:\n      [header]\n        child\n\n        after a blank\n", 1, true)
			~= nil
	)

	local function sumProp(g) expect(g:int(0, 1000) + g:int(0, 1000) < 1500) end
	local failed = sert.prop.run("replay", sumProp, {})
	expect(not failed.ok and failed.seed ~= nil)
	local replayed = sert.prop.run("replay", sumProp, {}, { replay = failed.seed })
	expect(not replayed.ok and replayed.cases == 1)
	sert.eq(replayed.tape, failed.tape)
	sert.eq(replayed.shrunk, failed.shrunk)
	local firstSeed: number? = nil
	sert.prop.run(
		"replay",
		function(g) firstSeed = firstSeed or g.seed end,
		{ runs = 3, regressions = { failed.seed :: number } }
	)
	expect(firstSeed == failed.seed)

	local seen = {}
	local exh = sert.prop.run(
		"two ints",
		function(g) table.insert(seen, `{g:int(1, 3)}{g:int(1, 3)}`) end,
		{ exhaustive = { size = 4 } },
		{ exhaustive = true }
	)
	expect(exh.ok and exh.exhaustive and exh.cases == 9)
	sert.eq(seen, { "11", "12", "13", "21", "22", "23", "31", "32", "33" })

	local lists = sert.prop.run("bool lists", function(g)
		g:list(function(g) return g:bool() end, 0, 10)
	end, { exhaustive = { size = 2 } }, { exhaustive = true })
	expect(lists.cases == 7)

	local failingExh = sert.prop.run("finds the one bad program", function(g)
		local a, b = g:pick({ "x", "y" }), g:int(0, 4)
		expect(not (a == "y" and b == 3))
	end, { exhaustive = { size = 3 } }, { exhaustive = true })
	expect(not failingExh.ok and failingExh.cases == 9)
	sert.eq(failingExh.shrunk, { 1, 3 })
	sert.fails(function()
		sert.prop.run("no bound", function() end, {}, { exhaustive = true })
	end, "no exhaustive bound")

	local tooBig = sert.prop.run("too big", function(g)
		g:int(1, 1e6)
		g:int(1, 1e6)
	end, { exhaustive = { size = 4 } }, { exhaustive = true, budget = 0 })
	expect(not tooBig.ok and string.find(tooBig.report, "budget of 0 s exceeded", 1, true) ~= nil)

	local calls = 0
	local capped = sert.prop.run("always fails", function(g)
		calls += 1
		g:list(function(g) return g:int(0, 1e9) end, 200)
		error("boom")
	end, { size = 200 })
	expect(not capped.ok and capped.attempts <= 500 and calls == 1 + capped.attempts)
end)

sert.prop("prop · generated values stay in their domains", function(g)
	local items = g:list(function(g) return g:weighted({ { 2, "int" }, { 1, "pick" }, { 0, "none" } }) end)
	expect(#items <= g.size)
	for _, kind in items do
		g:note("%s", kind)
		if kind == "int" then
			local n = g:int(-1, 1)
			expect(n >= -1 and n <= 1)
		else
			expect(kind == "pick" and g:pick({ true, false }) ~= nil)
		end
	end
end, { runs = 100, exhaustive = { size = 3 } })

local function seedRecorder(seen: { number }, fails: boolean?)
	return {
		gen = function(g)
			table.insert(seen, g.seed)
			if fails then error("inline boom", 0) end
			return g:int(0, 9)
		end,
		encode = function(n) return n end,
		decode = function(n) return n end,
	}
end

test("prop · inline properties, forced bools, tapeText, hints, wide binary search", function()
	local prop = require("../src/prop")
	local seenSeeds = {}
	local ok, results = sert.isolate(function()
		sert.test(
			"enclosing inline test",
			function() sert.laws.codec("inner prop", seedRecorder(seenSeeds), { runs = 50, seed = 1 }) end
		)
		return sert.run({ silent = true, runs = 4, seed = 999 })
	end)
	expect(ok and results.passed == 1 and #seenSeeds == 4)
	sert.eq(seenSeeds[1], prop.caseSeed("enclosing inline test > inner prop", 1, 1))

	local first, second = {}, {}
	expect(sert.isolate(function()
		sert.test("two inline", function()
			sert.laws.codec("one", seedRecorder(first), { runs = 3 })
			sert.laws.codec("two", seedRecorder(second), { runs = 3 })
		end)
		return sert.run({ silent = true })
	end))
	sert.neq(first, second)

	local replaySeeds = {}
	local failRes
	local lines = sert.capture(function()
		local okFail
		okFail, failRes = sert.isolate(function()
			sert.test("inline fail test", function() sert.laws.codec("inner fail", seedRecorder(replaySeeds, true)) end)
			return sert.run({
				raise = false,
				seeds = { ["inline fail test > inner fail"] = 424242 },
				command = "custom-runner",
			})
		end)
		expect(okFail)
	end)
	expect(failRes.failed == 1 and replaySeeds[1] == 424242)
	sert.contains(failRes.failures[1], 'custom-runner --filter "inline fail test" --replay=424242')
	sert.eq(failRes.seeds["inline fail test > inner fail"], 424242)
	sert.contains(table.concat(lines, "\n"), "[sert-seed] inline fail test > inner fail|424242")

	local forcedGen = prop.gen(1, 10, { 1, 0 })
	local initRng = (forcedGen :: any)._s.rng
	expect(forcedGen:bool(0) == false and forcedGen:bool(1) == true)
	sert.eq((forcedGen :: any)._s.rng, initRng)
	sert.eq(prop.tape(forcedGen), { 0, 0 })

	local unforced1, unforced2 = prop.gen(42, 10), prop.gen(42, 10)
	unforced1:bool(0)
	unforced2:bool(0.5)
	sert.eq(unforced1:int(1, 10000), unforced2:int(1, 10000))

	local exhCases = 0
	local res = sert.prop.run("exhaustive bool bounds", function(g)
		exhCases += 1
		expect(g:bool(0) == false and g:bool(-1) == false and g:bool(1) == true and g:bool(2) == true)
		g:bool(0.5)
		g:weighted({ { 1, "a" }, { 2, "b" } })
	end, { exhaustive = { size = 4 } }, { exhaustive = true })
	expect(res.ok and exhCases == 4)

	local tape64, tape65 = {}, {}
	for i = 1, 64 do
		tape64[i], tape65[i] = i, i
	end
	tape65[65] = 65
	expect(
		string.find(prop.tapeText(tape64), "more", 1, true) == nil
			and string.find(prop.tapeText(tape64), "{ 1, 2, 3,", 1, true) ~= nil
	)
	expect(string.find(prop.tapeText(tape65), "… 1 more", 1, true) ~= nil)

	local hintAllRes = sert.prop.run("hint all", function(g)
		if g:int(0, 1) == 0 then
			g:int(0, 10)
			prop.hint(g, 1, 2, { 1 })
		end
		expect(false)
	end, { runs = 20 })
	sert.eq(hintAllRes.shrunk, { 1 })

	local hintOneRes = sert.prop.run("hint one fallback", function(g)
		local t1 = g:int(0, 1)
		if t1 == 0 then g:int(1, 10) end
		local s2 = #(g :: any)._s.out + 1
		local t2 = g:int(0, 1)
		if t2 == 0 then g:int(1, 10) end
		local e2 = #(g :: any)._s.out
		if t1 == 0 then prop.hint(g, 1, 2, { 1 }) end
		if t2 == 0 then prop.hint(g, s2, e2, { 1 }) end
		expect(t1 == 1 and t2 == 1)
	end, { runs = 20, shrinkBudget = { tries = 2 } })
	sert.eq(#hintOneRes.shrunk, 3)

	local res1 = sert.prop.run("shrink value 1", function(g) expect(g:int(0, 1) == 0) end, { runs = 20 })
	sert.eq(res1.attempts, 2)

	local wideTarget = 2 ^ 45 + 12345
	local wideRes = sert.prop.run(
		"wide binary search",
		function(g) expect(g:int(0, 2 ^ 50) < wideTarget) end,
		{ runs = 20 },
		{ seed = 1 }
	)
	sert.eq(prop.gen(1, 40, wideRes.shrunk):int(0, 2 ^ 50), wideTarget)

	local g = prop.gen(42, 40)
	expect(#g:string(nil, 24) >= 24)
	local callIdx = 0
	local nilList = g:list(function()
		callIdx += 1
		return if callIdx == 2 then "second" else nil
	end, 3, 3)
	sert(nilList[1] == nil and nilList[2] == "second" and nilList[3] == nil)
end)

test("cli, spy lifecycle, focus, defer, hooks, and parseCliArgs validation", function()
	local fromLute = sert.parseCliArgs("test/run.luau", "my_filter", "-x")
	sert(fromLute.filter == "my_filter" and fromLute.failFast == true)
	sert.eq(sert.parseCliArgs("tests.luau", "--markers"), { markers = true })
	sert.eq(sert.parseCliArgs("tests.lua", "MySpec.spec.luau").filter, "MySpec.spec.luau")

	local m1 = sert.parseCliArgs("--mutants=1,2", "--filter= target ")
	sert.eq({ m1.mutants, m1.filter }, { { 1, 2 }, " target " })
	local m2 = sert.parseCliArgs("positional_target", "--mutants", "3,4")
	sert.eq({ m2.mutants, m2.filter }, { { 3, 4 }, "positional_target" })
	local m3 = sert.parseCliArgs("--mutants=5:from flag")
	sert.eq({ m3.mutants, m3.filter, m3.failFast }, { { 5 }, "from flag", true })

	local seenMutants = {}
	expect(sert.quiet(sert.isolate, function()
		local cliOpts = sert.parseCliArgs("--mutant=900007")
		sert.eq({ cliOpts.mutant, mutant.get() }, { 900007, 900007 })
		sert.test("check mutant", function() table.insert(seenMutants, mutant.get() or "nil") end)
		sert.run(cliOpts)
		sert.eq(mutant.get(), nil)
	end))
	sert.eq(seenMutants, { 900007 })

	table.clear(seenMutants)
	expect(sert.quiet(sert.isolate, function()
		sert.test("batch zero", function() table.insert(seenMutants, tostring(mutant.get())) end)
		sert.run({ mutants = { 0, 900002 }, silent = true })
	end))
	sert.eq(seenMutants, { "nil", "900002" })

	local okFiles, fileRes = sert.isolate(function()
		sert.test("in Sert spec", function() end)
		return sert.run({ silent = true, files = { "test/Sert.spec.luau" } })
	end)
	expect(okFiles and fileRes.passed == 1)

	local strictCase = setmetatable({ value = 10 }, {
		__index = function(_, k) error(`strict metatable accessed {tostring(k)}`) end,
	})
	local ranStrict = 0
	expect(sert.isolate(function()
		sert.each("strict case", { strictCase }, function(c)
			ranStrict += c.value
		end)
		return sert.run({ silent = true })
	end) and ranStrict == 10)

	local function chunkSlice(s, max)
		local out = {}
		for i = 1, #s, max do
			table.insert(out, string.sub(s, i, i + max - 1))
		end
		return out
	end
	sert.laws.chunk("small maxSize chunk", {
		maxSize = 4,
		gen = function(g) return g:string(nil, 0, 10) end,
		chunk = chunkSlice,
		join = table.concat,
	}, { runs = 10 })
	sert.laws.chunk("large minSize chunk", {
		minSize = 512,
		gen = function(g) return g:string(nil, 0, 10) end,
		chunk = function(s) return if #s == 0 then {} else { s } end,
		join = table.concat,
	}, { runs = 10 })

	local target = {}
	local function original() return "original" end
	local function reset()
		for _, k in { "top", "first", "after", "each", "late" } do
			target[k] = original
		end
	end
	reset()
	local seen = {}
	local function look(label: string)
		local names = {}
		for _, k in { "top", "first", "after", "each", "late" } do
			if target[k] ~= original then table.insert(names, k) end
		end
		seen[label] = table.concat(names, ",")
	end
	local okSpy, spyRes = sert.quiet(sert.isolate, function()
		sert.spy(target, "top")
		sert.describe("first", function()
			sert.beforeAll(function() sert.spy(target, "first") end)
			sert.afterEach(function() sert.spy(target, "each") end)
			sert.afterAll(function()
				look("first:afterAll")
				sert.spy(target, "after")
			end)
			sert.test("one", function() look("first:one") end)
			sert.test("two", function() look("first:two") end)
		end, { file = "First.spec" })
		sert.describe("next", function()
			sert.beforeAll(function()
				sert.spy(target, "late")
				error("beforeAll boom", 0)
			end)
			sert.test("never runs", function() end)
		end, { file = "Next.spec" })
		sert.test("next file", function() look("next file") end, { file = "Last.spec" })
		return sert.run({ raise = false })
	end)
	expect(okSpy and spyRes.passed == 3 and spyRes.failed == 1)
	look("after run")
	sert.eq(seen, {
		["first:one"] = "top,first",
		["first:two"] = "top,first",
		["first:afterAll"] = "top,first",
		["next file"] = "top",
		["after run"] = "",
	})
	reset()

	local ranFocus = {}
	local focusLines = sert.capture(function()
		local ok, res = sert.isolate(function()
			sert.test("unfocused", function() table.insert(ranFocus, "unfocused") end)
			sert.focus("focused", function() table.insert(ranFocus, "focused") end)
			return sert.run()
		end)
		expect(ok and res.passed == 1 and res.skipped == 1)
	end)
	sert.eq(ranFocus, { "focused" })
	expect(string.find(table.concat(focusLines, "\n"), "FOCUS", 1, true) ~= nil)

	local loadLog = {}
	local okDeferOut, deferOutRes = sert.quiet(sert.isolate, function()
		sert.defer(function() table.insert(loadLog, "first") end)
		sert.defer(function() error("load defer boom", 0) end)
		sert.test("sees nothing run yet", function() sert.eq(loadLog, {}) end)
		return sert.run({ raise = false })
	end)
	expect(okDeferOut and deferOutRes.passed == 1 and deferOutRes.failed == 1)
	sert.eq(loadLog, { "first" })
	sert.eq(deferOutRes.failures, { "defer: load defer boom" })

	local okHooks, hookRes = sert.quiet(sert.isolate, function()
		sert.afterEach(function() error("after hook boom", 0) end)
		sert.test("defer fails", function()
			sert.defer(function() error("defer hook boom", 0) end)
		end)
		sert.test("after fails", function() end)
		return sert.run({ raise = false })
	end)
	expect(okHooks and hookRes.failed == 2)
	expect(string.find(hookRes.failures[1], "defer: defer hook boom", 1, true) ~= nil)
	expect(string.find(hookRes.failures[2], "afterEach: after hook boom", 1, true) ~= nil)

	expect(sert.frames(function() return true end, 3) == true)
	if not IS_ROBLOX then
		sert.fails(function()
			sert.frames(function() return false end, 2)
		end, "sert.frames: requires Roblox task scheduler")
	end
	local stepped = 0
	expect(sert.frames(function() return stepped >= 3 end, 5, nil, function()
		stepped += 1
	end) == true and stepped == 3)
	sert.fails(function()
		sert.frames(function() return false end, 2, "ready", function() end)
	end, "ready after 2 frames")

	local emptyLines = sert.capture(function()
		expect(sert.isolate(function()
			sert.fails(function() sert.run({ mutant = 900001 }) end, "sert.run: no tests registered")
			sert.eq(mutant.get(), nil)
			local empty = sert.run({ raise = false })
			sert.eq({ empty.failed, empty.total, empty.failures }, { 1, 0, { "sert.run: no tests registered" } })
		end))
	end)
	sert.eq(emptyLines[1], "❌ sert.run: no tests registered")
	sert.contains(emptyLines[2], '[sert-done] {"clock":0,"failed":1,')

	local okFileFilter, fileFilterRes = sert.isolate(function()
		sert.test("file filter target", function() end)
		return sert.run({ silent = true, filter = "@file=Sert, Other" })
	end)
	expect(okFileFilter and fileFilterRes.passed == 1)

	local seenMut = {}
	expect(sert.quiet(sert.isolate, function()
		sert.test("mut sub", function() table.insert(seenMut, mutant.get()) end)
		local r1 = sert.run(sert.parseCliArgs("--mutant=900002:mut sub", "--silent"))
		sert.eq(mutant.get(), nil)
		local r2 = sert.run({ mutant = 900002, silent = true })
		sert.eq({ mutant.get(), r1.passed, r1.failed, r2.passed, r2.failed }, { nil, 1, 0, 1, 0 })
	end))
	sert.eq(seenMut, { 900002, 900002 })

	expect(sert.isolate(function()
		mutant.set(900003)
		sert.parseCliArgs("--mutants=1,2")
		sert.eq(mutant.get(), 900003)
	end))

	local activeMutant = mutant.get()
	local flags = sert.parseCliArgs({
		123,
		"--list",
		"--exhaustive",
		"--markers",
		"--silent",
		"--fail-fast=false",
		"--seed=random",
		"--replay",
		"11",
		"--runs=7",
		"--budget=30",
		"--test-timeout=15",
		"--filter",
		"abc",
		"--mutant",
		"900004:ignored",
	})
	mutant.set(activeMutant)
	expect(flags.list and flags.exhaustive and flags.markers and flags.silent)
	expect(flags.replay == 11 and flags.runs == 7 and flags.budget == 30 and flags.timeout == 15)
	expect(flags.filter == "abc" and type(flags.seed) == "number" and flags.mutant == 900004)
	sert.eq(sert.parseCliArgs("--seed", "-5", "--runs", "3").seed, -5)
	sert.eq(sert.parseCliArgs("--filter=").filter, "")
	sert.eq(sert.parseCliArgs("--replay=0").replay, 0)

	for _, case in
		{
			{
				{ "--sed=5" },
				"unknown flag --sed (known: --filter, --seed, --replay, --runs, --budget, --test-timeout,",
			},
			{ { "--timeout=5" }, "unknown flag --timeout" },
			{ { "--failFast" }, "unknown flag --failFast" },
			{ { "-y" }, "unknown flag -y" },
			{ { "---" }, "unknown flag ---" },
			{ { "--seed=abc" }, '--seed expects a number or "random", got "abc"' },
			{ { "--runs", "ten" }, '--runs expects a number, got "ten"' },
			{ { "--runs=nan" }, '--runs expects a number, got "nan"' },
			{ { "--seed=inf" }, '--seed expects a number or "random", got "inf"' },
			{ { "--runs=0" }, '--runs expects a whole number from 1, got "0"' },
			{ { "--runs=-2" }, '--runs expects a whole number from 1, got "-2"' },
			{ { "--replay=1.5" }, '--replay expects a whole number from 0, got "1.5"' },
			{ { "--replay=-1" }, '--replay expects a whole number from 0, got "-1"' },
			{ { "--budget=0" }, '--budget expects a number above 0, got "0"' },
			{ { "--test-timeout=-1" }, '--test-timeout expects a number above 0, got "-1"' },
			{ { "--replay" }, "--replay expects a value" },
			{ { "--filter", "--list" }, "--filter expects a value" },
			{ { "--list=yes" }, '--list takes no value, got "yes"' },
			{ { "--fail-fast=no" }, '--fail-fast expects true or false, got "no"' },
			{ { "--mutant=abc" }, '--mutant expects a mutant id, got "abc"' },
			{ { "--mutants=1;2" }, '--mutants expects mutant ids, got "1;2"' },
			{ { "foo", "bar" }, 'one filter only, got "foo" and "bar" (quote a filter with spaces)' },
			{ { "--filter=a", "b" }, 'one filter only, got "a" and "b"' },
		}
	do
		sert.fails(function() sert.parseCliArgs(case[1]) end, `sert.parseCliArgs: {case[2]}`)
	end

	sert.fails(function() sert.expect(1).toBeNil() end, "expected nil, got 1")
	sert.fails(function() sert.expect(false).toBeTruthy() end, "expected truthy, got false")
	sert.fails(function() sert.expect(true).never.toBeTruthy() end, "expected not truthy, got true")
	sert.fails(function() sert.expect(true).toBeFalsy() end, "expected falsy, got true")
	sert.fails(function() sert.expect(false).never.toBeFalsy() end, "expected not falsy, got false")
	sert.fails(function() sert.expect(10).toBeCloseTo(1, 0) end, "expected 1 to 0 digits (± 0.5), got 10")
	sert.fails(function() sert.expect(1).never.toBeCloseTo(1, 0) end, "expected not 1 to 0 digits (± 0.5), got 1")
	sert.fails(function()
		sert.expect(function() error("wrong msg", 0) end).toThrow("expected msg")
	end, 'expected error containing "expected msg"')
end)

return {}
