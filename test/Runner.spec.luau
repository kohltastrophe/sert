--!strict
local registerAggregator = require("./fixtures/aggregator")
local registerOther = require("./fixtures/Other.spec")
local registerSuite = require("./fixtures/suite")
local registry = require("../src/core/registry")
local runner = require("../src/core/runner")
local sert = require("../src")

local function runIsolated(register: () -> (), opts: sert.RunOptions?): sert.Results
	local sub = registry.newState()
	registry.isolateDepth += 1
	local ok, res = pcall(function(): sert.Results
		return registry.withState(sub, function(): sert.Results
			register()
			local merged: sert.RunOptions = if opts ~= nil then table.clone(opts) else {}
			if merged.quiet == nil and merged.silent == nil then merged.quiet = true end
			if merged.raise == nil then merged.raise = false end
			return sert.run(merged)
		end)
	end)
	registry.isolateDepth -= 1
	if not ok then error(res, 0) end
	return res
end

sert.describe("test and describe modifiers", function()
	sert.test("skip and focus select the expected subset of tests", function()
		local ran: { string } = {}
		local res = runIsolated(function()
			sert.test("unfocused", function() table.insert(ran, "unfocused") end)
			sert.test.focus("focused one", function() table.insert(ran, "focused one") end)
			sert.test.skip("skipped body", function() table.insert(ran, "skipped body") end)
			sert.test.skip("skipped without body")
			sert.describe.focus("focused block", function()
				sert.test("inside focus", function() table.insert(ran, "inside focus") end)
				sert.test.skip("skipped inside focus", function() table.insert(ran, "never") end)
			end)
			sert.describe.skip("skipped block", function()
				sert.test("inside skipped", function() table.insert(ran, "never") end)
			end)
			sert.describe.skip("skipped block without body")
		end, { ci = false })

		sert.eq(ran, { "focused one", "inside focus" })
		sert.eq(res.passed, 2)
		sert.eq(res.failed, 0)
	end)

	sert.test("roblox, server, and client targets skip in headless mode unless opted in", function()
		local ran: { string } = {}
		local headlessRes = runIsolated(function()
			sert.test("portable", function() table.insert(ran, "portable") end)
			sert.test.roblox("roblox test", function() table.insert(ran, "roblox") end)
			sert.test.server("server test", function() table.insert(ran, "server") end)
			sert.test.client("client test", function() table.insert(ran, "client") end)
			sert.describe.roblox("roblox group", function()
				sert.test("child inherits roblox", function() table.insert(ran, "child_roblox") end)
				sert.test.skip("roblox skip")
			end)
		end)

		if not sert.isRoblox then
			sert.eq(ran, { "portable" })
			sert.eq(headlessRes.passed, 1)
			sert.eq(headlessRes.skippedRoblox, 5)
		end

		table.clear(ran)
		local allRes = runIsolated(function()
			sert.test("portable", function() table.insert(ran, "portable") end)
			sert.test.roblox("roblox test", function() table.insert(ran, "roblox") end)
			sert.test.server("server test", function() table.insert(ran, "server") end)
			sert.test.client("client test", function() table.insert(ran, "client") end)
			sert.test.server.skip("server skipped")
		end, { allTargets = true })

		sert.eq(ran, { "portable", "roblox", "server", "client" })
		sert.eq(allRes.passed, 4)
		sert.eq(allRes.skipped, 1)

		table.clear(ran)
		local serverOnlyRes = runIsolated(function()
			sert.test("portable", function() table.insert(ran, "portable") end)
			sert.test.server("server only", function() table.insert(ran, "server") end)
			sert.test.client("client ignored", function() table.insert(ran, "client") end)
		end, { targets = { "server" :: sert.Target } })

		sert.eq(ran, { "server" })
		sert.eq(serverOnlyRes.passed, 1)
		sert.eq(serverOnlyRes.total, 1)
	end)

	sert.test("test.each passes rows without unpacking while test.eachTuple unpacks tuple columns", function()
		local singleArgs: { any } = {}
		local titles: { string } = {}
		local tupleCalls: { string } = {}

		local res = runIsolated(function()
			sert.test.each({ { 1, 2 }, { 3, 4 } })("pair %s", function(pair: { number }, ctx: sert.TestContext)
				sert.eq(type(pair), "table")
				sert.eq(#pair, 2)
				table.insert(singleArgs, pair)
				table.insert(titles, ctx.name)
			end)

			sert.test.each({ { name = "zero", val = 0 }, { name = "one", val = 1 } })(
				"named case",
				function(item: { name: string, val: number }, ctx: sert.TestContext)
					sert.ge(item.val, 0)
					table.insert(titles, ctx.name)
				end
			)

			sert.test.each({ 10, 20 })(
				function(val: number, idx: number): string return `custom #{idx} = {val}` end,
				function(_val: number, ctx: sert.TestContext) table.insert(titles, ctx.name) end
			)

			sert.test.eachTuple({
				{ 1, 2, 3 },
				{ 4, 5, 9 },
				table.pack(10, nil, 10),
			})("%s + %s = %s", function(a: number, b: number?, expected: number, ctx: sert.TestContext)
				sert.eq(a + (b or 0), expected)
				table.insert(tupleCalls, `{ctx.name}:{a}+{tostring(b)}={expected}`)
			end)

			sert.describe.each({ { 7, 8 } })("group %s", function(pair: { number })
				sert.eq(#pair, 2)
				sert.test("member", function() end)
			end)

			sert.describe.eachTuple({ { "left", "right" } })("%s->%s", function(lhs: string, rhs: string)
				sert.eq(lhs, "left")
				sert.eq(rhs, "right")
				sert.test("tuple member", function() end)
			end)
		end)

		sert.eq(res.failed, 0)
		sert.eq(singleArgs, { { 1, 2 }, { 3, 4 } })
		sert.contains(titles, "pair { 1, 2 }")
		sert.contains(titles, "named case · zero")
		sert.contains(titles, "custom #2 = 20")
		sert.eq(#tupleCalls, 3)
	end)
end)

sert.describe("lifecycle hooks, LIFO ordering, and error preservation", function()
	sert.test("runs beforeAll, beforeEach, defer, afterEach, and afterAll in strict LIFO teardown order", function()
		local events: { string } = {}
		local sharedObj = { mode = "orig" }

		local res = runIsolated(function()
			sert.setup({
				beforeAll = function() table.insert(events, "setup.beforeAll") end,
				afterAll = function() table.insert(events, "setup.afterAll") end,
				beforeEach = function() table.insert(events, "setup.beforeEach") end,
				afterEach = function() table.insert(events, "setup.afterEach") end,
			})

			sert.describe("outer", function()
				sert.beforeAll(function()
					table.insert(events, "outer.beforeAll.1")
					sert.spy(sharedObj, "mode", function(): string return "spied" end)
					sert.defer(function() table.insert(events, "outer.beforeAll.defer") end)
				end)
				sert.beforeAll(function() table.insert(events, "outer.beforeAll.2") end)
				sert.afterAll(function() table.insert(events, "outer.afterAll.1") end)
				sert.afterAll(function() table.insert(events, "outer.afterAll.2") end)

				sert.beforeEach(function() table.insert(events, "outer.beforeEach.1") end)
				sert.beforeEach(function() table.insert(events, "outer.beforeEach.2") end)
				sert.afterEach(function() table.insert(events, "outer.afterEach.1") end)
				sert.afterEach(function() table.insert(events, "outer.afterEach.2") end)

				sert.describe("inner", function()
					sert.beforeEach(function() table.insert(events, "inner.beforeEach") end)
					sert.afterEach(function() table.insert(events, "inner.afterEach") end)

					sert.test("first", function(ctx)
						-- Spy created in outer beforeAll must remain active across both tests!
						sert.eq((sharedObj.mode :: any)(), "spied")
						table.insert(events, "test.1")
						ctx:defer(function() table.insert(events, "defer.1") end)
						sert.defer(function() table.insert(events, "defer.2") end)
					end)

					sert.test("second", function()
						sert.eq((sharedObj.mode :: any)(), "spied")
						table.insert(events, "test.2")
					end)
				end)
			end)
		end)

		sert.eq(res.failed, 0)
		sert.eq(sharedObj.mode, "orig")
		sert.eq(events, {
			"setup.beforeAll",
			"outer.beforeAll.1",
			"outer.beforeAll.2",
			"setup.beforeEach",
			"outer.beforeEach.1",
			"outer.beforeEach.2",
			"inner.beforeEach",
			"test.1",
			"defer.2",
			"defer.1",
			"inner.afterEach",
			"outer.afterEach.2",
			"outer.afterEach.1",
			"setup.afterEach",
			"setup.beforeEach",
			"outer.beforeEach.1",
			"outer.beforeEach.2",
			"inner.beforeEach",
			"test.2",
			"inner.afterEach",
			"outer.afterEach.2",
			"outer.afterEach.1",
			"setup.afterEach",
			"outer.afterAll.2",
			"outer.afterAll.1",
			"outer.beforeAll.defer",
			"setup.afterAll",
		})
	end)

	sert.test(
		"skips afterEach/afterAll for scopes whose beforeEach/beforeAll failed and preserves dual errors",
		function()
			local log: { string } = {}
			local hookFailRes = runIsolated(function()
				sert.describe("outer ok", function()
					sert.beforeEach(function() table.insert(log, "outer.before") end)
					sert.afterEach(function() table.insert(log, "outer.after") end)

					sert.describe("inner broken beforeEach", function()
						sert.beforeEach(function()
							sert.defer(function() table.insert(log, "inner.defer_before_throw") end)
							error("inner beforeEach boom", 0)
						end)
						sert.afterEach(function() table.insert(log, "inner.after_must_not_run") end)
						sert.test("never runs body", function() table.insert(log, "body_must_not_run") end)
					end)
				end)

				sert.describe("broken beforeAll", function()
					sert.beforeAll(function()
						sert.defer(function() table.insert(log, "beforeAll.defer") end)
						error("beforeAll boom", 0)
					end)
					sert.afterAll(function() table.insert(log, "afterAll_must_not_run") end)
					sert.test("blocked by beforeAll", function() table.insert(log, "blocked_body") end)
				end)
			end)

			sert.eq(hookFailRes.failed, 2)
			sert.eq(log, {
				"outer.before",
				"inner.defer_before_throw",
				"outer.after",
				"beforeAll.defer",
			})

			local dualRes = runIsolated(function()
				sert.afterEach(function() error("afterEach secondary explosion", 0) end)
				sert.test("primary + defer + afterEach throw", function(ctx)
					ctx:defer(function() error("defer secondary explosion", 0) end)
					error("primary test body explosion", 0)
				end)
			end)

			sert.eq(dualRes.failed, 1)
			sert.eq(#dualRes.failures, 1)
			sert.contains(dualRes.failures[1], "primary test body explosion")
			sert.contains(dualRes.failures[1], "defer secondary explosion")
			sert.contains(dualRes.failures[1], "afterEach secondary explosion")
		end
	)

	sert.test("scopes file hooks per spec/suite file while coroutine-root hooks act globally", function()
		local log: { string } = {}
		local res = runIsolated(function()
			registerAggregator(
				sert,
				function() table.insert(log, "global+") end,
				function() table.insert(log, "global-") end
			)
			registerOther(sert, log)
			registerSuite(sert, log)
			sert.beforeEach(function() table.insert(log, "runner+") end)
			sert.afterEach(function() table.insert(log, "runner-") end)
			sert.test("local", function() table.insert(log, "local") end)
		end)

		sert.eq(res.passed, 3)
		sert.eq(log, {
			"global+",
			"other+",
			"other",
			"other-",
			"global-",
			"global+",
			"suite+",
			"suite",
			"global-",
			"global+",
			"runner+",
			"local",
			"runner-",
			"global-",
		})
	end)
end)

sert.describe("CI focus gate, filtering, sharding, and parseCliArgs", function()
	sert.test("enforces CI .focus gate unless allowFocused is enabled", function(ctx)
		local failCi = runIsolated(function()
			sert.test.focus("accidental focus", function() end)
			sert.test("sibling", function() end)
		end, { ci = true })
		sert.eq(failCi.passed, 1)
		sert.eq(failCi.failed, 1)
		sert.contains(failCi.failures[1], "focused test (.focus) ran while CI is enabled")

		local allowCi = runIsolated(function()
			sert.test.focus("allowed focus", function() end)
		end, { ci = true, allowFocused = true })
		sert.eq(allowCi.passed, 1)
		sert.eq(allowCi.failed, 0)

		local sharedG = registry.mutant._sharedG
		local prevCi = rawget(sharedG, "__SERT_CI")
		ctx:defer(function() rawset(sharedG, "__SERT_CI", prevCi) end)
		rawset(sharedG, "__SERT_CI", "true")

		local envCi = runIsolated(function()
			sert.test.focus("env focus", function() end)
		end)
		sert.eq(envCi.failed, 1)
		sert.contains(envCi.failures[1], "--allow-focused")
	end)

	sert.test(
		"supports filter, grep, exclude, file/files, names, repeatCount, slowest, markers, list, and shard",
		function()
			local function buildSuite()
				registerOther(sert, {})
				sert.test("alpha: fast_1", function() end)
				sert.test("alpha: fast_2", function() end)
				sert.test("beta: slow_item", function() end)
			end

			local byFilter = runIsolated(buildSuite, { filter = "alpha:" })
			sert.eq(byFilter.passed, 2)

			local byGrep = runIsolated(buildSuite, { grep = "fast_%d$" })
			sert.eq(byGrep.passed, 2)

			local byExclude = runIsolated(buildSuite, { filter = "alpha:", exclude = "fast_2" })
			sert.eq(byExclude.passed, 1)

			local byFile = runIsolated(buildSuite, { file = "Other.spec.luau" })
			sert.eq(byFile.passed, 1)

			local byAtFile = runIsolated(buildSuite, { filter = "@file=Other" })
			sert.eq(byAtFile.passed, 1)

			local byFiles = runIsolated(buildSuite, { files = { "Runner" }, names = { "beta: slow_item" } })
			sert.eq(byFiles.passed, 1)

			local runs = 0
			local slowLines = sert.capture(function()
				local repRes = runIsolated(function()
					sert.test("repeated", function()
						runs += 1
					end)
				end, { quiet = false, repeatCount = 3, slowest = 1, markers = true })
				sert.eq(repRes.passed, 3)
			end)
			sert.eq(runs, 3)
			local joined = table.concat(slowLines, "\n")
			sert.contains(joined, "slowest 1 test:")
			sert.contains(joined, "[sert-test]")
			sert.contains(joined, "[sert-done]")

			local listLines = sert.capture(function()
				local listRes = runIsolated(buildSuite, { quiet = false, list = true, filter = "alpha:" })
				sert.eq(listRes.total, 2)
			end)
			sert.contains(table.concat(listLines, "\n"), "[sert-list]")

			local shard1 = runIsolated(buildSuite, { shard = { name = "1/2", index = 1, count = 2 } })
			local shard2 = runIsolated(buildSuite, { shard = { name = "2/2", index = 2, count = 2 } })
			sert.eq(shard1.passed + shard2.passed, 4)

			local prefixShard = runIsolated(buildSuite, {
				shard = { name = "prefix", index = 1, count = 1, only = { "alpha:" }, except = { "alpha: fast_2" } },
			})
			sert.eq(prefixShard.passed, 1)
		end
	)

	sert.test("parseCliArgs parses all supported flags and rejects malformed CLI arguments", function()
		local opts = sert.parseCliArgs({
			"test/run.luau",
			"positional filter",
			"--grep=^math",
			"--exclude=flaky",
			"--file=Sert.spec.luau",
			"--file",
			"Assert.spec.luau",
			"--seed=42",
			"--replay=99",
			"--runs=25",
			"--budget=120",
			"--test-timeout=15",
			"--repeat=2",
			"--slowest=5",
			"--exhaustive",
			"--list",
			"--markers",
			"--quiet",
			"--compact",
			"--ci",
			"--allow-focused",
			"--all",
			"--no-sweep",
			"-x",
			"--shard=2/4",
		})
		sert.eq(opts.filter, "positional filter")
		sert.eq(opts.grep, "^math")
		sert.eq(opts.exclude, "flaky")
		sert.eq(opts.files, { "Sert.spec.luau", "Assert.spec.luau" })
		sert.eq(opts.seed, 42)
		sert.eq(opts.replay, 99)
		sert.eq(opts.runs, 25)
		sert.eq(opts.budget, 120)
		sert.eq(opts.testTimeout, 15)
		sert.eq(opts.repeatCount, 2)
		sert.eq(opts.slowest, 5)
		sert.eq(opts.exhaustive, true)
		sert.eq(opts.list, true)
		sert.eq(opts.markers, true)
		sert.eq(opts.quiet, true)
		sert.eq(opts.compact, true)
		sert.eq(opts.ci, true)
		sert.eq(opts.allowFocused, true)
		sert.eq(opts.allTargets, true)
		sert.eq(opts.sweep, false)
		sert.eq(opts.failFast, true)
		sert.eq(opts.shard, { name = "2/4", index = 2, count = 4, runLimit = 0 })

		local shortGrep = sert.parseCliArgs("-g", "pattern", "--seed=random", "--replay=tok_abc")
		sert.eq(shortGrep.grep, "pattern")
		sert.eq(type(shortGrep.seed), "number")
		sert.eq(shortGrep.replay, "tok_abc")

		sert.throws(function() sert.parseCliArgs("--unknown-flag") end, "unknown flag")
		sert.throws(function() sert.parseCliArgs("one", "two") end, "one filter only")
		sert.throws(function() sert.parseCliArgs("--shard=5/3") end, "--shard")
		sert.throws(function() sert.parseCliArgs("--runs=0") end, "--runs")
		sert.throws(function() sert.parseCliArgs("--quiet=yes") end, "takes no value")
	end)
end)

sert.describe("CLI flag edges, output modes, selection arrays, and chained modifiers", function()
	sert.test("parseCliArgs covers mutant/fail-fast/replay/silent forms and value validation errors", function(ctx)
		local prevMutant = registry.mutant.get()
		local prevParsed = registry.mutant.parsed
		ctx:defer(function()
			registry.mutant.parsed = prevParsed
			registry.mutant.set(prevMutant)
		end)

		local spaced = sert.parseCliArgs(
			"--filter",
			"alpha",
			"--grep",
			"beta",
			"--exclude",
			"gamma",
			"--silent",
			"--fail-fast=false",
			"--replay=0"
		)
		sert.eq(spaced.filter, "alpha")
		sert.eq(spaced.grep, "beta")
		sert.eq(spaced.exclude, "gamma")
		sert.eq(spaced.quiet, true)
		sert.eq(spaced.failFast, false)
		sert.eq(spaced.replay, 0)

		local negReplay = sert.parseCliArgs("--fail-fast=true", "--replay=-5")
		sert.eq(negReplay.failFast, true)
		sert.eq(negReplay.replay, "-5")

		local singleMut = sert.parseCliArgs("--mutant=900007:target_case")
		local observedMut = registry.mutant.get()
		registry.mutant.parsed = prevParsed
		registry.mutant.set(prevMutant)
		sert.eq(singleMut.mutant, 900007)
		sert.eq(singleMut.filter, "target_case")
		sert.eq(singleMut.failFast, true)
		sert.eq(observedMut, 900007)

		local batchMut = sert.parseCliArgs("--mutants=1,3,9:fast_suite")
		sert.eq(batchMut.mutants, { 1, 3, 9 })
		sert.eq(batchMut.filter, "fast_suite")
		sert.eq(batchMut.failFast, true)

		sert.throws(function() sert.parseCliArgs("--filter") end, "--filter expects a value")
		sert.throws(function() sert.parseCliArgs("--grep", "--quiet") end, "--grep expects a value")
		sert.throws(function() sert.parseCliArgs("--mutant=abc") end, "--mutant expects a mutant id")
		sert.throws(function() sert.parseCliArgs("--mutants=1,bad") end, "--mutants expects mutant ids")
		sert.throws(function() sert.parseCliArgs("--fail-fast=maybe") end, "--fail-fast expects true or false")
		sert.throws(function() sert.parseCliArgs("--no-sweep=1") end, "--no-sweep takes no value")
		sert.throws(function() sert.parseCliArgs("--compact=true") end, "--compact takes no value")
		sert.throws(function() sert.parseCliArgs("--budget=0") end, "--budget expects a number above 0")
		sert.throws(function() sert.parseCliArgs("--test-timeout=-2") end, "--test-timeout expects a number above 0")
		sert.throws(function() sert.parseCliArgs("--slowest=1.5") end, "--slowest expects a whole number from 1")
		sert.throws(function() sert.parseCliArgs("--seed=nope") end, '--seed expects a number or "random"')
	end)

	sert.test("formats list, compact, slowest 3, markers, seed banner, and filters/excludes arrays", function()
		local bodyRan = 0
		local listOut = sert.capture(function()
			local res = runIsolated(function()
				sert.test("item one", function()
					bodyRan += 1
				end)
				sert.test.roblox("item two", function()
					bodyRan += 1
				end)
				sert.test.skip("todo: pending item")
			end, { quiet = false, list = true })
			sert.eq(res.total, 3)
			sert.eq(res.skipped, 3)
			sert.eq(res.passed, 0)
		end)
		sert.eq(bodyRan, 0)
		local listText = table.concat(listOut, "\n")
		sert.contains(listText, "|item one|portable")
		sert.contains(listText, "|item two|roblox")
		sert.contains(listText, "[sert-list] end 3")
		sert.contains(listText, "[sert-done]")

		-- `--compact` suppresses `✅` pass lines while keeping failures, `--slowest 3`, and `--markers`.
		local compactOut = sert.capture(function()
			local res = runIsolated(function()
				sert.test("fast pass 1 [tag:core]", function() end)
				sert.test("fast pass 2 [tag:core]", function() end)
				sert.test("fast pass 3 [tag:net]", function() end)
				sert.test("broken case [tag:net]", function() error("compact failure reason", 0) end)
				sert.test.skip("todo: later feature")
			end, {
				quiet = false,
				compact = true,
				slowest = 3,
				markers = true,
				seed = 4242,
				runs = 5,
			})
			sert.eq(res.passed, 3)
			sert.eq(res.failed, 1)
			sert.eq(res.skipped, 1)
		end)
		local compactText = table.concat(compactOut, "\n")
		sert.eq(string.find(compactText, "✅ fast pass 1", 1, true), nil)
		sert.contains(compactText, "seed 4242 · 5 runs")
		sert.contains(compactText, "❌ broken case [tag:net]")
		sert.contains(compactText, "compact failure reason")
		sert.contains(compactText, "🟡 todo: later feature")
		sert.contains(compactText, "slowest 3 tests:")
		sert.contains(compactText, '"status":"pass"')
		sert.contains(compactText, '"status":"fail"')
		sert.contains(compactText, '"status":"skip"')
		sert.contains(compactText, "[sert-done]")

		-- `filters` (OR-list) and `excludes` (exact + case-insensitive substring tag exclusion).
		local function taggedSuite()
			sert.test("auth login [tag:auth]", function() end)
			sert.test("db query [tag:db]", function() end)
			sert.test("db migration [tag:db] [tag:slow]", function() end)
			sert.test("ui layout [tag:ui]", function() end)
		end

		local tagFiltered = runIsolated(taggedSuite, {
			filters = { "[tag:auth]", "[tag:db]" },
			excludes = { "TAG:SLOW" },
		})
		sert.eq(tagFiltered.passed, 2)

		local exactExcluded = runIsolated(taggedSuite, {
			excludes = { "auth login [tag:auth]", "ui layout [tag:ui]" },
		})
		sert.eq(exactExcluded.passed, 2)

		local noneMatched = runIsolated(taggedSuite, {
			filters = { "[tag:nonexistent]" },
		})
		sert.eq(noneMatched.passed, 0)
		sert.eq(noneMatched.skipped, 4)
	end)

	sert.test(
		"supports chained skip/focus namespaces, describe options, target checks, and setup validation",
		function()
			local ran: { string } = {}
			local chainedRes = runIsolated(function()
				local tSkip: any = sert.test.skip
				local tFocus: any = sert.test.focus
				local dSkip: any = sert.describe.skip
				local dFocus: any = sert.describe.focus

				tSkip.skip("t.skip.skip", function() table.insert(ran, "never") end)
				tFocus.skip("t.focus.skip")
				tSkip.focus("t.skip.focus", function() table.insert(ran, "t.skip.focus") end)
				tFocus.focus("t.focus.focus", function() table.insert(ran, "t.focus.focus") end)

				dSkip.skip("d.skip.skip", function()
					sert.test("child", function() table.insert(ran, "never") end)
				end)
				dFocus.skip("d.focus.skip")
				dSkip.focus("d.skip.focus", function()
					sert.test("child", function(ctx) table.insert(ran, ctx.name) end)
				end, { separator = " :: " })
				dFocus.focus("d.focus.focus", function()
					sert.describe("nested", function()
						sert.test("leaf", function(ctx) table.insert(ran, ctx.name) end)
					end)
				end, { separator = " / " })

				sert.describe("opt-skip", function()
					sert.test("hidden", function() table.insert(ran, "never") end)
				end, { skip = true })
				sert.describe("opt-focus", function()
					sert.test("shown", function(ctx) table.insert(ran, ctx.name) end)
				end, { focus = true, separator = " -> " })
			end, { ci = false })

			sert.eq(chainedRes.passed, 5)
			sert.eq(ran, {
				"t.skip.focus",
				"t.focus.focus",
				"d.skip.focus :: child",
				"d.focus.focus / nested / leaf",
				"opt-focus -> shown",
			})

			runIsolated(function()
				sert.throws(function()
					sert.test("bad target", function() end, { target = "browser" } :: any)
				end, "invalid target")
				sert.throws(function()
					sert.describe("bad target", function() end, { target = "mobile" } :: any)
				end, "invalid target")
				sert.throws(function() sert.setup("not_a_table" :: any) end, "expected a table of hooks")
				sert.throws(function()
					sert.setup({ unknownHook = function() end } :: any)
				end, "unknown hook")
				sert.throws(function() sert.setup({ beforeAll = 123 :: any }) end, "beforeAll must be a function")

				sert.test("cannot nest describe at runtime", function()
					sert.throws(function()
						sert.describe("illegal nested", function() end)
					end, "cannot open a describe block inside a running test")
				end)
			end)
		end
	)
end)

sert.describe("runner teardown, yield driver, mutant batches, and prop shrinking/replay", function()
	sert.test("preserves LIFO defer composite errors, failFast afterAll leftovers, and runner guards", function(ctx)
		-- 1) `ctx:defer` executes in strict LIFO order even when body AND multiple deferred callbacks throw.
		local deferOrder: { string } = {}
		local multiDeferRes = runIsolated(function()
			sert.test("body + two defers throw", function(tCtx)
				tCtx:defer(function()
					table.insert(deferOrder, "d1")
					error("defer_1_err", 0)
				end)
				tCtx:defer(function() table.insert(deferOrder, "d2_ok") end)
				tCtx:defer(function()
					table.insert(deferOrder, "d3")
					error("defer_3_err", 0)
				end)
				error("body_primary_err", 0)
			end)
		end)
		sert.eq(deferOrder, { "d3", "d2_ok", "d1" })
		sert.eq(multiDeferRes.failed, 1)
		local msg = multiDeferRes.failures[1]
		sert.contains(msg, "body_primary_err")
		sert.contains(msg, "teardown also failed")
		sert.contains(msg, "defer_3_err")
		sert.contains(msg, "defer_1_err")

		-- 2) `failFast` stops before the second test in scope and drains `afterAll` errors via `leftovers`.
		local afterAllRes = runIsolated(function()
			sert.describe("failFast scope", function()
				sert.afterAll(function() error("afterAll leftover failure", 0) end)
				sert.test("first fails", function() error("first boom", 0) end)
				sert.test("second skipped by failFast", function() end)
			end)
		end, { failFast = true })
		sert.eq(afterAllRes.failed, 2)
		sert.contains(afterAllRes.failures[1], "first boom")
		sert.contains(afterAllRes.failures[2], "afterAll: afterAll leftover failure")

		-- 3) `postTestHook` runs unless `sweep = false` (`--no-sweep`).
		local prevPost = registry.getPostTestHook()
		ctx:defer(function() registry.setPostTestHook(prevPost) end)
		registry.setPostTestHook(function() error("leak detected in postTest", 0) end)

		local sweptRes = runIsolated(function()
			sert.test("swept", function() end)
		end)
		sert.eq(sweptRes.failed, 1)
		sert.contains(sweptRes.failures[1], "postTest: leak detected in postTest")

		local noSweepRes = runIsolated(function()
			sert.test("unswept", function() end)
		end, { sweep = false })
		sert.eq(noSweepRes.passed, 1)
		sert.eq(noSweepRes.failed, 0)
		registry.setPostTestHook(prevPost)

		-- 4) Load-scope `sert.defer`, `runner.holdLoaded()`, nested `sert.run`, empty suite, and `requireTests` hint.
		local loadDeferRes = runIsolated(function()
			sert.defer(function() error("load-scope defer boom", 0) end)
			sert.test("ok test", function() end)
		end)
		sert.eq(loadDeferRes.passed, 1)
		sert.eq(loadDeferRes.failed, 1)
		sert.contains(loadDeferRes.failures[1], "load-scope defer boom")

		local heldCleaned = false
		local sub = registry.newState()
		registry.withState(sub, function()
			sert.defer(function() heldCleaned = true end)
			local releaseHeld = runner.holdLoaded()
			sert.eq(#sub.loaded, 0)
			sert.eq(heldCleaned, false)
			sert.eq(releaseHeld(1), nil)
			sert.eq(heldCleaned, true)
		end)

		local nestedRunRes = runIsolated(function()
			sert.test("calls sert.run inside test", function() sert.run({ quiet = true, raise = false }) end)
		end)
		sert.eq(nestedRunRes.failed, 1)
		sert.contains(nestedRunRes.failures[1], "cannot invoke runner inside a running test")

		local emptyRes = runIsolated(function() end)
		sert.eq(emptyRes.failed, 1)
		sert.contains(emptyRes.failures[1], "no tests registered")

		local shardedEmpty = runIsolated(function() end, {
			shard = { name = "1/2", index = 1, count = 2 },
		})
		sert.eq(shardedEmpty.failed, 0)

		local hintRes = runIsolated(function()
			sert.test("real test", function() end)
		end, { filter = "Runner.spec", requireTests = true })
		sert.eq(hintRes.failed, 1)
		sert.contains(hintRes.failures[1], "use --file <Spec> to filter by spec file")
	end)

	sert.test("drives yielding coroutines via YieldDriver and runs mutant batches", function(ctx)
		local prevDriver = registry.getYieldDriver()
		ctx:defer(function() registry.setYieldDriver(prevDriver) end)

		-- Without driver, yielding fails immediately.
		registry.setYieldDriver(nil)
		local noDrvRes = runIsolated(function()
			sert.test("yields bare", function() coroutine.yield() end)
		end)
		sert.eq(noDrvRes.failed, 1)
		sert.contains(noDrvRes.failures[1], "yielded")

		-- Driver resuming thread to completion passes; returning false, leaving suspended, or throwing fails cleanly.
		registry.setYieldDriver(function(thread: thread, _timeout: number): (boolean, any)
			local ok, err = coroutine.resume(thread)
			return ok, err
		end)
		local passDrv = runIsolated(function()
			sert.test("yields once", function() coroutine.yield() end)
		end)
		sert.eq(passDrv.passed, 1)

		registry.setYieldDriver(function(_thread: thread, _timeout: number): (boolean, any) return true, nil end)
		local hungDrv = runIsolated(function()
			sert.test("stays suspended", function() coroutine.yield() end, { timeout = 0.25 })
		end)
		sert.eq(hungDrv.failed, 1)
		sert.contains(hungDrv.failures[1], "test timed out after 0.25 s")

		registry.setYieldDriver(function(thread: thread, _timeout: number): (boolean, any)
			coroutine.resume(thread)
			return false, "driver reported failure"
		end)
		local falseDrv = runIsolated(function()
			sert.test("driver false", function() coroutine.yield() end)
		end)
		sert.eq(falseDrv.failed, 1)
		sert.contains(falseDrv.failures[1], "driver reported failure")

		registry.setYieldDriver(function(): (boolean, any) error("driver crashed", 0) end)
		local crashDrv = runIsolated(function()
			sert.test("driver throws", function() coroutine.yield() end)
		end)
		sert.eq(crashDrv.failed, 1)
		sert.contains(crashDrv.failures[1], "driver crashed")
		registry.setYieldDriver(prevDriver)

		-- Mutant batch (`opts.mutants`) tracks `lastKiller`/`fastKillers` and emits `[sert-mutant]` verdicts.
		local mutOut = sert.capture(function()
			local batchRes = runIsolated(function()
				sert.test("guard 1", function() sert.ne(registry.mutant.get(), 900001) end)
				sert.test("guard 2", function() sert.ne(registry.mutant.get(), 900002) end)
			end, { mutants = { 900001, 900002, 900003, 900001 } })
			sert.eq(batchRes.mutants, {
				{ id = 900001, killed = true },
				{ id = 900002, killed = true },
				{ id = 900003, killed = false },
				{ id = 900001, killed = true },
			})
		end)
		local mutText = table.concat(mutOut, "\n")
		sert.contains(mutText, "[sert-mutant] 900001=KILLED")
		sert.contains(mutText, "[sert-mutant] 900002=KILLED")
		sert.contains(mutText, "[sert-mutant] 900003=SURVIVED")
	end)

	sert.test("formats sert.prop shrinker reports, seeds/replay roundtrips, and exhaustive/budget edges", function()
		-- 1) Top-level `sert.prop` failure with changing message (`first failure:`), notes/tape truncation,
		-- `shrinkBudget` stop, `[sert-seed]` output, and `{ replay = ... }` / `{ seeds = ... }` roundtrip.
		local propSeed: number? = nil
		local propOut = sert.capture(function()
			local failProp = runIsolated(function()
				sert.prop("shrunk failure report", function(g: sert.GenContext)
					local xs: { number } = {}
					for i = 1, 70 do
						xs[i] = g:int(0, 50)
						if i <= 36 then g:note(`draw #{i} = {xs[i]}`) end
					end
					local sum = xs[1] + xs[2]
					sert.lt(sum, 10, `sum={sum} >= 10`)
				end, { seed = 101, runs = 30, shrinkBudget = { tries = 3 } :: sert.ShrinkBudget })
			end, { quiet = false })
			sert.eq(failProp.failed, 1)
			propSeed = failProp.seeds["shrunk failure report"]
			sert.ok(propSeed ~= nil)
			local rep = failProp.failures[1]
			sert.contains(rep, 'property "shrunk failure report" failed:')
			sert.contains(rep, "stopped by the shrink budget")
			sert.contains(rep, "trace:")
			sert.contains(rep, "more")
			sert.contains(rep, "--replay=")
		end)
		sert.contains(table.concat(propOut, "\n"), `[sert-seed] shrunk failure report|{propSeed}`)

		local replayCount = 0
		local replayRes = runIsolated(function()
			sert.prop("shrunk failure report", function(g: sert.GenContext)
				replayCount += 1
				local a: number = g:int(0, 50)
				local b: number = g:int(0, 50)
				sert.lt(a + b, 10)
			end, { seed = 101, runs = 30, shrinkBudget = { tries = 0 } :: sert.ShrinkBudget })
		end, { replay = tostring(propSeed) })
		sert.eq(replayRes.failed, 1)
		sert.eq(replayCount, 1)
		sert.contains(replayRes.failures[1], `replay · case seed {propSeed}`)

		-- 2) Inline `sert.prop` inside `sert.test` records `inlineSeeds` and replays via `opts.seeds`.
		local inlineRes = runIsolated(function()
			sert.test("host test", function()
				sert.prop("inline check", function(g: sert.GenContext)
					local n = g:int(1, 10000)
					if n >= 5 then error(`bad n={n}`, 0) end
				end, { seed = 55, runs = 25 })
			end)
		end)
		sert.eq(inlineRes.failed, 1)
		sert.contains(inlineRes.failures[1], "first failure:")
		local hostSeed = inlineRes.seeds["host test"]
		sert.ok(hostSeed ~= nil)

		local inlineReplayRuns = 0
		local inlineReplayed = runIsolated(function()
			sert.test("host test", function()
				sert.prop("inline check", function(g: sert.GenContext)
					inlineReplayRuns += 1
					local n = g:int(1, 10000)
					if n >= 5 then error(`bad n={n}`, 0) end
				end, { seed = 55, runs = 25, shrinkBudget = { tries = 0 } :: sert.ShrinkBudget })
			end)
		end, { seeds = { ["host test"] = hostSeed :: number } })
		sert.eq(inlineReplayed.failed, 1)
		sert.eq(inlineReplayRuns, 1)

		-- 3) `exhaustive` + `budget`, `regressions`, `g:assume` discard exhaustion, and vacuity.
		local exhOut = sert.capture(function()
			local exhRes = runIsolated(function()
				sert.prop("bounded bool pair", function(g: sert.GenContext)
					local a = g:bool()
					local b = g:bool()
					sert.eq(a and b, b and a)
				end, { exhaustive = { size = 4 } })
				sert.prop(
					"unbounded prop skipped in exhaustive",
					function(g: sert.GenContext) sert.ge(g:int(0, 5), 0) end
				)
			end, { quiet = false, exhaustive = true, budget = 30 })
			sert.eq(exhRes.passed, 1)
			sert.eq(exhRes.skipped, 1)
		end)
		local exhText = table.concat(exhOut, "\n")
		sert.contains(exhText, "exhaustive · budget 30 s")
		sert.contains(exhText, "4 programs")

		local budgetExceeded = runIsolated(function()
			sert.prop("huge space", function(g: sert.GenContext)
				local start = os.clock()
				local spins = 0
				while os.clock() - start < 0.003 do
					spins += 1
				end
				local drawn: number = g:int(0, 100)
				sert.ge(drawn + spins, 0)
			end, { exhaustive = { size = 10 } })
		end, { exhaustive = true, budget = 0.001 })
		sert.eq(budgetExceeded.failed, 1)
		sert.contains(budgetExceeded.failures[1], "exhaustive budget of 0.001 s exceeded")

		sert.throws(function()
			sert.prop.run(
				"no bound",
				function(g: sert.GenContext) sert.ge(g:int(0, 2), 0) end,
				{},
				{ exhaustive = true }
			)
		end, "no exhaustive bound")

		local regAndAssume = runIsolated(function()
			sert.prop(
				"regression seed fails",
				function(g: sert.GenContext) sert.lt(g:int(10, 20), 5) end,
				{ regressions = { 777 } }
			)
			sert.prop(
				"over-assumed",
				function(g: sert.GenContext) g:assume(false, "impossible precondition") end,
				{ runs = 5 }
			)
			sert.prop(
				"vacuous prop",
				function(g: sert.GenContext) sert.prop.vacuous(g, "empty domain") end,
				{ runs = 3 }
			)
		end)
		sert.eq(regAndAssume.failed, 3)
		sert.contains(regAndAssume.failures[1], "regression 1 · case seed 777")
		sert.contains(regAndAssume.failures[2], "impossible precondition (discarded")
		sert.contains(regAndAssume.failures[3], "empty domain in all 3 cases")
	end)
end)
