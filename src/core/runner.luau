--!strict
-- Test runner (`core/runner`): test selection, hook execution, reporting, CLI argument parsing, and sharding.

local format = require("../format")
local prop = require("../prop")
local registry = require("./registry")

local mutant = registry.mutant
local output = registry.output

export type Shard = registry.Shard

local IS_ROBLOX = (game :: any) ~= nil
local DEFAULT_TIMEOUT = 30
local YIELDED = "test yielded and was never resumed"

type RunOptions = registry.RunOptions
type Test = registry.Test
type Hooks = registry.Hooks
type TestFn = registry.TestFn

export type Results = {
	passed: number,
	failed: number,
	skipped: number,
	skippedRtest: number,
	todo: number,
	total: number,
	clock: number,
	failures: { string },
	seeds: { [string]: number },
	mutants: { { id: number, killed: boolean } }?,
}

local errorText = format.errorText
local state = registry.state

local SHARD_KEY = "__SERT_SHARD"
local shardInfo = {}
local shardOverride: { value: Shard? }? = nil

function shardInfo.get(): Shard?
	local info = if shardOverride ~= nil then shardOverride.value else mutant._sharedG[SHARD_KEY]
	return if type(info) == "table" and type(info.name) == "string" then info :: Shard else nil
end

function shardInfo.set(info: Shard?, clear: boolean?)
	shardOverride = if info ~= nil or clear then { value = info } else nil
end

local function prefixed(name: string, prefixes: { string }): boolean
	for _, prefix in prefixes do
		if string.sub(name, 1, #prefix) == prefix then return true end
	end
	return false
end

function shardInfo.selects(name: string, info: Shard?): boolean
	local active = info or shardInfo.get()
	if active == nil then
		return true
	elseif active.only ~= nil and not prefixed(name, active.only) then
		return false
	elseif active.except ~= nil and prefixed(name, active.except) then
		return false
	end
	return true
end

local runner = { shard = shardInfo }

local function invoke(fn: () -> (), timeout: number): (boolean, any)
	local saved, depth, active, sinkDepth =
		table.clone(state), registry.isolateDepth, mutant.get(), registry.output.depth()
	local function restore()
		local outerDeferred = saved.deferred or saved.loaded
		if outerDeferred ~= nil then
			if state.loaded ~= nil and state.loaded ~= saved.loaded and state.loaded ~= outerDeferred then
				table.move(state.loaded, 1, #state.loaded, #outerDeferred + 1, outerDeferred)
			end
			if state.deferred ~= nil and state.deferred ~= saved.deferred and state.deferred ~= outerDeferred then
				table.move(state.deferred, 1, #state.deferred, #outerDeferred + 1, outerDeferred)
			end
		end
		registry.replaceState(saved)
		registry.isolateDepth = depth
		mutant.set(active)
		registry.output.trim(sinkDepth)
	end
	if not IS_ROBLOX then
		local thread = coroutine.create(fn)
		local ok, err = coroutine.resume(thread)
		if ok and coroutine.status(thread) ~= "dead" then
			coroutine.close(thread)
			restore()
			return false, YIELDED
		end
		return ok, err
	end
	local done, ok, err = false, false, nil
	local thread = task.spawn(function()
		ok, err = pcall(fn)
		done = true
	end)
	if not done then
		local deadline = os.clock() + timeout
		while not done and os.clock() < deadline do
			task.wait()
		end
		if not done then
			task.cancel(thread)
			restore()
			return false, `test timed out after {timeout} s`
		end
	end
	return ok, err
end

local function drain(list: { TestFn }, timeout: number): string?
	local failure: string? = nil
	while #list > 0 do
		local ok, err = invoke(table.remove(list) :: TestFn, timeout)
		if not ok and failure == nil then failure = `defer: {errorText(err)}` end
	end
	return failure
end

local function runTest(
	test: Test,
	chain: { Hooks },
	opts: RunOptions
): (string?, string?, number?, { [string]: number })
	local timeout = test.timeout or opts.timeout or DEFAULT_TIMEOUT
	local before, after = {}, {}
	for _, hooks in chain do
		table.move(hooks.before, 1, #hooks.before, #before + 1, before)
	end
	for index = #chain, 1, -1 do
		local hooks = chain[index]
		table.move(hooks.after, 1, #hooks.after, #after + 1, after)
	end

	local outerDeferred, outerSeeds = state.deferred, state.inlineSeeds
	local pendingDefer: { TestFn }, inlineSeeds: { [string]: number } = {}, {}
	state.deferred, state.inlineSeeds = pendingDefer, inlineSeeds
	local endEnvScope = registry.beginEnvScope()

	local failure: string?, detail: string?, seed: number? = nil, nil, nil
	for _, hook in before do
		local ok, err = invoke(hook, timeout)
		if not ok then
			failure = `beforeEach: {errorText(err)}`
			break
		end
	end
	if failure == nil then
		local property = test.prop
		if property ~= nil then
			local result: prop.PropResult? = nil
			local runOptions = table.clone(opts)
			local seeded = if opts.seeds then opts.seeds[test.name] else nil
			if seeded ~= nil then runOptions.replay = seeded end
			local ok, err = invoke(
				function()
					result =
						prop.run(property.name, property.fn, property.options, runOptions, registry.isolateDepth == 0)
				end,
				timeout
			)
			if not ok then
				failure = errorText(err)
			elseif result ~= nil and not result.ok then
				failure, seed = result.report or "property failed", result.seed
			elseif result ~= nil then
				local noun = if result.exhaustive then "program" else "case"
				detail = `{result.cases} {noun}{if result.cases == 1 then "" else "s"}`
			end
		else
			local ok, err = invoke(test.fn, timeout)
			if not ok then failure = errorText(err) end
		end
	end
	local deferErr = drain(pendingDefer, timeout)
	if failure == nil then failure = deferErr end
	for _, hook in after do
		local ok, err = invoke(hook, timeout)
		if not ok and failure == nil then failure = `afterEach: {errorText(err)}` end
	end
	deferErr = drain(pendingDefer, timeout)
	if failure == nil then failure = deferErr end
	state.deferred, state.inlineSeeds = outerDeferred, outerSeeds
	endEnvScope()
	return failure, detail, seed, inlineSeeds
end

type Outcome = {
	test: Test,
	index: number,
	failure: string?,
	detail: string?,
	seed: number?,
	inlineSeeds: { [string]: number },
	ms: number,
}

local function execute(
	order: { number },
	plan: { string }?,
	opts: RunOptions,
	withLast: boolean,
	report: (Outcome) -> boolean,
	pass: ((Test, string) -> ())?
): { string }
	local tests = state.tests
	local globals = registry.globalChain()
	local chains: { [number]: { Hooks } } = {}
	local first: { [Hooks]: number }, last: { [Hooks]: number } = {}, {}
	local lastOfFile: { [string]: number } = {}
	for position, index in order do
		if plan == nil or plan[index] == "run" then
			local test = tests[index]
			local chain = registry.chainOf(test, globals)
			chains[position] = chain
			for _, hooks in chain do
				first[hooks] = first[hooks] or position
				last[hooks] = position
			end
			lastOfFile[test.file] = position
		end
	end

	local timeout = opts.timeout or DEFAULT_TIMEOUT
	local started: { Hooks }, finished: { [Hooks]: boolean } = {}, {}
	local beforeAllErr: { [Hooks]: string }, deferred: { [Hooks]: { TestFn } } = {}, {}
	local function enter(hooks: Hooks)
		table.insert(started, hooks)
		local list = {}
		deferred[hooks], state.deferred = list, list
		for _, hook in hooks.beforeAll do
			local ok, err = invoke(hook, timeout)
			if not ok then
				beforeAllErr[hooks] = `beforeAll: {errorText(err)}`
				break
			end
		end
		state.deferred = nil
	end
	local function leave(hooks: Hooks): string?
		if finished[hooks] then return nil end
		finished[hooks] = true
		local list = deferred[hooks] :: { TestFn }
		state.deferred = list
		local firstErr: string? = nil
		for _, hook in hooks.afterAll do
			local ok, err = invoke(hook, timeout)
			if not ok and firstErr == nil then firstErr = `afterAll: {errorText(err)}` end
		end
		state.deferred = nil
		local deferErr = drain(list, timeout)
		return firstErr or deferErr
	end

	for position, index in order do
		local test = tests[index]
		local chain = chains[position]
		if chain == nil then
			if pass ~= nil and plan ~= nil then pass(test, plan[index]) end
			continue
		end
		for _, hooks in chain do
			if first[hooks] == position then enter(hooks) end
		end
		local failure: string? = nil
		for _, hooks in chain do
			if beforeAllErr[hooks] ~= nil then
				failure = beforeAllErr[hooks]
				break
			end
		end
		local clock = os.clock()
		local detail: string?, seed: number?, inlineSeeds: { [string]: number } = nil, nil, {}
		if failure == nil then
			state.running =
				{ name = test.name, file = test.file, last = withLast and lastOfFile[test.file] == position }
			failure, detail, seed, inlineSeeds = runTest(test, chain, opts)
			state.running = nil
		end
		for c = #chain, 1, -1 do
			local hooks = chain[c]
			if last[hooks] == position then
				local afterErr = leave(hooks)
				if afterErr ~= nil and failure == nil then failure = afterErr end
			end
		end
		if
			report({
				test = test,
				index = index,
				failure = failure,
				detail = detail,
				seed = seed,
				inlineSeeds = inlineSeeds,
				ms = math.round((os.clock() - clock) * 1000),
			})
		then
			if pass ~= nil and plan ~= nil then
				for rest = position + 1, #order do
					local nextIdx = order[rest]
					if chains[rest] == nil then pass(tests[nextIdx], plan[nextIdx]) end
				end
			end
			break
		end
	end
	local leftovers = {}
	for index = #started, 1, -1 do
		local afterErr = leave(started[index])
		if afterErr ~= nil then table.insert(leftovers, afterErr) end
	end
	return leftovers
end

local function toNameSet(list: { string }): { [string]: boolean }
	local set: { [string]: boolean } = {}
	for _, name in list do
		set[name] = true
	end
	return set
end

local function count(plan: { string }, step: string): number
	local total = 0
	for _, each in plan do
		if each == step then
			total += 1
		end
	end
	return total
end

local function enterMutant(opts: RunOptions): (boolean, () -> ())
	local batch = opts.mutants
	local ownsMutant = opts.mutant ~= nil or batch ~= nil
	local outerMutant: number? = mutant.get()
	local parsed = mutant.parsed
	if parsed ~= nil and parsed.id == opts.mutant then
		outerMutant, mutant.parsed = parsed.outer, nil
	end
	local mutantRun = ownsMutant or (registry.isolateDepth == 0 and mutant.get() ~= nil)
	if mutantRun and opts.failFast == nil then opts.failFast = true end
	if batch ~= nil then
		opts.silent = true
		mutant.set(nil)
	elseif opts.mutant ~= nil then
		mutant.set(opts.mutant)
	end
	local outerOptions = state.options
	return mutantRun, function()
		state.options = outerOptions
		if ownsMutant then mutant.set(outerMutant) end
	end
end

local function parseFileFilter(opts: RunOptions)
	if type(opts.filter) ~= "string" or string.sub(opts.filter, 1, 6) ~= "@file=" then return end
	local fileList: { string } = {}
	for part in string.gmatch(string.sub(opts.filter, 7), "[^,]+") do
		local trimmed = string.match(part, "^%s*(.-)%s*$")
		if trimmed ~= nil and trimmed ~= "" then table.insert(fileList, trimmed) end
	end
	opts.files, opts.filter = fileList, nil
end

local function selector(opts: RunOptions): (Shard?, (Test) -> boolean)
	local filters = if opts.filters ~= nil and #opts.filters > 0 then opts.filters else nil
	local lowerFilter = if opts.filter ~= nil then string.lower(opts.filter) else nil
	local lowerFilters: { string }? = nil
	if filters ~= nil then
		local lowered = {}
		for _, text in filters do
			table.insert(lowered, string.lower(text))
		end
		lowerFilters = lowered
	end
	local named = if opts.names ~= nil then toNameSet(opts.names) else nil
	local excluded = if opts.excludes ~= nil and #opts.excludes > 0 then toNameSet(opts.excludes) else nil
	local filed: { [string]: boolean }? = nil
	if opts.files ~= nil and #opts.files > 0 then
		local set = {}
		for _, file in opts.files do
			set[string.lower(registry.normalizeSpecFile(file))] = true
		end
		filed = set
	end
	local explicit = opts.filter ~= nil or filters ~= nil or opts.names ~= nil or filed ~= nil
	local shard: Shard? = if type(opts.shard) == "table"
		then opts.shard
		elseif opts.shard == true or (opts.shard == nil and not explicit) then shardInfo.get()
		else nil
	local function selected(test: Test): boolean
		if shard ~= nil and not shardInfo.selects(test.name, shard) then return false end
		local lowerName = string.lower(test.name)
		if lowerFilter ~= nil and string.find(lowerName, lowerFilter, 1, true) == nil then return false end
		if lowerFilters ~= nil then
			local any = false
			for _, text in lowerFilters do
				if string.find(lowerName, text, 1, true) ~= nil then
					any = true
					break
				end
			end
			if not any then return false end
		end
		if (named ~= nil and not named[test.name]) or (excluded ~= nil and excluded[test.name]) then return false end
		return filed == nil or filed[string.lower(test.file)] == true
	end
	return shard, selected
end

local function selectionText(opts: RunOptions, shard: Shard?): string
	local selection = {}
	if opts.filter ~= nil then table.insert(selection, `filter "{opts.filter}"`) end
	if opts.filters ~= nil and #opts.filters > 0 then
		table.insert(selection, `filters "{table.concat(opts.filters, '" | "')}"`)
	end
	if opts.names ~= nil then table.insert(selection, `{#opts.names} named`) end
	if opts.excludes ~= nil and #opts.excludes > 0 then table.insert(selection, `{#opts.excludes} excluded`) end
	if opts.files ~= nil and #opts.files > 0 then table.insert(selection, `files {table.concat(opts.files, ", ")}`) end
	if shard ~= nil then table.insert(selection, `shard {shard.name} ({shard.index}/{shard.count})`) end
	if opts.exhaustive then
		table.insert(selection, `exhaustive · budget {opts.budget or 600} s`)
	elseif opts.replay ~= nil then
		table.insert(selection, `replay {opts.replay}`)
	elseif opts.seeds ~= nil and next(opts.seeds) ~= nil then
		local seeded = 0
		for _ in opts.seeds do
			seeded += 1
		end
		table.insert(selection, `{seeded} seeded`)
	else
		if opts.seed ~= nil then table.insert(selection, `seed {opts.seed}`) end
		if opts.runs ~= nil then table.insert(selection, `{opts.runs} runs`) end
	end
	return if #selection > 0 then " · " .. table.concat(selection, " · ") else ""
end

local function planTests(opts: RunOptions, selected: (Test) -> boolean): ({ string }, boolean)
	local activeSide = state.side
	local plan: { string }, properties = {}, false
	for index, test in state.tests do
		local mode = test.mode
		local unfocused = state.focusing and not test.focused
		local headless = mode == "rtest" and not IS_ROBLOX
		local sampled = opts.exhaustive and (test.prop == nil or test.prop.options.exhaustive == nil)
		if
			(opts.rtestOnly and mode == "test") or (activeSide ~= nil and test.side ~= nil and test.side ~= activeSide)
		then
			plan[index] = "ignore"
		elseif unfocused or not selected(test) then
			plan[index] = "out"
		elseif mode == "todo" then
			plan[index] = "todo"
		elseif headless or sampled or mode == "skip" then
			plan[index] = "skip"
		else
			plan[index] = "run"
			properties = properties or test.prop ~= nil
		end
	end
	return plan, properties
end

local function runOrder(opts: RunOptions, mutantRun: boolean): { number }
	local order: { number } = {}
	if opts.failFast and mutantRun then
		local slow: { number } = {}
		for index, test in state.tests do
			table.insert(if test.prop ~= nil then slow else order, index)
		end
		table.move(slow, 1, #slow, #order + 1, order)
	else
		for index = 1, #state.tests do
			order[index] = index
		end
	end
	return order
end

local function listTests(plan: { string }, results: Results, out: (...any) -> ())
	local listed = 0
	for index, test in state.tests do
		if plan[index] ~= "out" and plan[index] ~= "ignore" then
			out(`[sert-list] {test.file}|{test.name}`)
			listed += 1
		end
	end
	out(`[sert-list] end {listed}`)
	results.skipped, results.total = listed, listed
	out(`[sert-done] {format.json(results)}`)
end

local function runBatch(batch: { number }, order: { number }, plan: { string }, opts: RunOptions, results: Results)
	local runnable: { number } = {}
	for _, index in order do
		if plan[index] == "run" then table.insert(runnable, index) end
	end
	local verdicts, lastKiller: number?, fastKillers: { number } = {}, nil, {}
	results.total = 0
	for _, id in batch do
		mutant.set(id)
		local sequence: { number } = if lastKiller ~= nil then { lastKiller } else {}
		for _, index in fastKillers do
			if index ~= lastKiller then table.insert(sequence, index) end
		end
		for _, index in runnable do
			if index ~= lastKiller and table.find(fastKillers, index) == nil then table.insert(sequence, index) end
		end
		local killed = false
		local leftovers = execute(sequence, nil, opts, false, function(outcome: Outcome): boolean
			results.total += 1
			if outcome.failure == nil then
				results.passed += 1
				return false
			end
			results.failed += 1
			killed, lastKiller = true, outcome.index
			if outcome.ms <= 100 then
				local existing = table.find(fastKillers, outcome.index)
				if existing ~= nil then
					table.remove(fastKillers, existing)
				elseif #fastKillers >= 3 then
					table.remove(fastKillers)
				end
				table.insert(fastKillers, 1, outcome.index)
			end
			return true
		end)
		killed = killed or #leftovers > 0
		table.insert(verdicts, { id = id, killed = killed })
		output.printFlush(`[sert-mutant] {id}={if killed then "KILLED" else "SURVIVED"}`)
	end
	results.mutants = verdicts
end

local function runSelection(
	order: { number },
	plan: { string },
	opts: RunOptions,
	results: Results,
	out: (...any) -> (),
	shout: (...any) -> ()
)
	local function marker(test: Test, status: string, ms: number, failure: string?)
		if opts.markers then
			out(`[sert-test] {format.json({
				name = test.name,
				file = test.file,
				status = status,
				ms = ms,
				error = failure,
			})}`)
		end
	end

	local leftovers = execute(order, plan, opts, true, function(outcome: Outcome): boolean
		local test, failure = outcome.test, outcome.failure
		if failure ~= nil then
			for key, seed in outcome.inlineSeeds do
				results.seeds[key] = seed
				out(`[sert-seed] {key}|{seed}`)
			end
		end
		if failure == nil then
			results.passed += 1
			if not (opts :: any).compact then
				out(`✅ {test.name} · {outcome.ms} ms{if outcome.detail then " · " .. outcome.detail else ""}`)
			end
			marker(test, "pass", outcome.ms)
			return false
		end
		results.failed += 1
		table.insert(results.failures, `{test.name}: {failure}`)
		shout(`❌ {test.name} · {outcome.ms} ms\n   ⚠️ {failure}`)
		if test.prop == nil then
			local cmd = opts.command or "python3 tools/sert.py run"
			out(string.format("     replay: %s --filter %q", cmd, test.name))
		end
		if outcome.seed ~= nil then
			results.seeds[test.name] = outcome.seed
			out(`[sert-seed] {test.name}|{outcome.seed}`)
		end
		marker(test, "fail", outcome.ms, failure)
		return opts.failFast == true
	end, function(test: Test, step: string)
		if step == "ignore" then
			return
		elseif step == "todo" then
			results.todo += 1
			if not opts.exhaustive then out(`📝 {test.name}`) end
			marker(test, "todo", 0)
			return
		end
		results.skipped += 1
		if step == "skip" then
			if test.mode == "rtest" and not IS_ROBLOX then
				results.skippedRtest += 1
			end
			if test.mode == "skip" and not opts.exhaustive then out(`🟡 {test.name}`) end
			marker(test, "skip", 0)
		end
	end)
	for _, afterErr in leftovers do
		results.failed += 1
		table.insert(results.failures, afterErr)
		shout(`❌ {afterErr}`)
	end
end

function runner.holdLoaded(): (timeout: number?) -> string?
	local held = state.loaded
	state.loaded = {}
	return function(timeout: number?): string? return drain(held, timeout or DEFAULT_TIMEOUT) end
end

local function filterHint(filter: string?, tests: { Test }): string
	if type(filter) ~= "string" then return "" end
	local lower = string.lower(filter)
	local fileLike = string.find(filter, "|", 1, true) ~= nil or string.find(lower, ".spec", 1, true) ~= nil
	if not fileLike then
		local normalized = string.lower(registry.normalizeSpecFile(filter))
		for _, test in tests do
			if string.lower(test.file) == normalized then
				fileLike = true
				break
			end
		end
	end
	if not fileLike then return "" end
	return ' (note: --filter matches test names by substring; use --filter "@file=Name1,Name2" to filter by spec file)'
end

function runner.run(options: RunOptions?): Results
	if state.running ~= nil then
		error("sert.run: called inside a running test; run an inner suite in sert.isolate", 2)
	end
	local opts: RunOptions = if options ~= nil then table.clone(options) else {}
	local tests = state.tests
	local mutantRun, finish = enterMutant(opts)
	if mutantRun then mutant.share() end
	parseFileFilter(opts)
	local out: (...any) -> () = if opts.silent then function() end else output.print
	local shout: (...any) -> () = if opts.silent then function() end else output.warn

	local results: Results = {
		passed = 0,
		failed = 0,
		skipped = 0,
		skippedRtest = 0,
		todo = 0,
		total = #tests,
		clock = 0,
		failures = format.array({}),
		seeds = {},
	}
	local function settle()
		local deferErr = drain(state.loaded, opts.timeout or DEFAULT_TIMEOUT)
		if deferErr ~= nil then
			results.failed += 1
			table.insert(results.failures, deferErr)
			shout(`❌ {deferErr}`)
		end
		finish()
	end
	local function abort(message: string): Results
		results.failed = 1
		table.insert(results.failures, message)
		shout(`❌ {message}`)
		settle()
		out(`[sert-done] {format.json(results)}`)
		if opts.raise ~= false then error(message, 0) end
		return results
	end

	local shard, selected = selector(opts)
	local plan, properties = planTests(opts, selected)
	if opts.list then
		listTests(plan, results, out)
		finish()
		return results
	end

	if #tests == 0 then return abort("sert.run: no tests registered") end

	local selection = selectionText(opts, shard)
	local runtime = if IS_ROBLOX then "Roblox" else "Luau CLI"
	local focus = if state.focusing then " · FOCUS" else ""
	out(`sert · {#tests} {if #tests == 1 then "test" else "tests"} · {runtime}{focus}{selection}`)

	results.total -= count(plan, "ignore")
	if properties and not opts.exhaustive then out(`[sert-seed] run {opts.seed or prop.DEFAULT_BASE}`) end
	if opts.requireTests and not table.find(plan, "run") and not table.find(plan, "skip") then
		results.skipped = results.total
		local hint = filterHint(opts.filter, tests)
		return abort(`sert.run: requireTests: the selection{selection} matched none of the {results.total} tests{hint}`)
	end

	local order = runOrder(opts, mutantRun)
	state.options = opts
	local startClock = os.clock()
	if opts.mutants ~= nil then
		runBatch(opts.mutants, order, plan, opts, results)
		results.clock = os.clock() - startClock
		settle()
		return results
	end
	runSelection(order, plan, opts, results, out, shout)
	results.clock = os.clock() - startClock
	settle()

	local unselected = count(plan, "out")
	local todo = if results.todo > 0 then ` · {results.todo} todo` else ""
	local notSelected = if unselected > 0 then ` · {unselected} not selected` else ""
	local rtestNote = if results.skippedRtest > 0
		then ` ({results.skippedRtest} rtest — run 'python3 tools/sert.py studio' to execute engine tests)`
		else ""
	out(
		`\n{results.passed} passed · {results.failed} failed · {results.skipped - unselected} skipped{rtestNote}{todo}{notSelected}`
			.. ` · {math.round(results.clock * 1000)} ms`
	)
	out(`[sert-done] {format.json(results)}`)

	if results.failed > 0 and opts.raise ~= false then error(`{results.failed} of {results.total} tests failed`, 0) end
	return results
end

local function idList(csv: string): { number }
	local list: { number } = {}
	for digits in string.gmatch(csv, "%d+") do
		table.insert(list, tonumber(digits) :: number)
	end
	return list
end

local KNOWN_FLAGS = "--filter, --seed, --replay, --runs, --budget, --test-timeout, --exhaustive, --list, --markers, --silent, --compact, "
	.. "-x/--fail-fast, --mutant, --mutants"
local NUMERIC_FLAGS: { [string]: string } = {
	seed = "seed",
	replay = "replay",
	runs = "runs",
	budget = "budget",
	["test-timeout"] = "timeout",
}
local SWITCH_FLAGS: { [string]: string } = {
	list = "list",
	exhaustive = "exhaustive",
	markers = "markers",
	silent = "silent",
	compact = "compact",
}

local function failCli(message: string): never error(`sert.parseCliArgs: {message}`, 0) end

function runner.parseCliArgs(...: any): RunOptions
	local first = select(1, ...)
	local raw: { any } = if select("#", ...) == 1 and type(first) == "table" then first else { ... }
	local opts: { [string]: any } = {}
	local i = 1
	if type(raw[1]) == "string" and not string.match(raw[1], "^[@%-]") and string.match(raw[1], "%.luau?$") ~= nil then
		i = 2
	end
	local mutantFilter: string? = nil
	local function setFilter(filter: string)
		if opts.filter ~= nil then
			failCli(`one filter only, got "{opts.filter}" and "{filter}" (quote a filter with spaces)`)
		end
		opts.filter = filter
	end
	while i <= #raw do
		local arg = raw[i]
		i += 1
		if type(arg) ~= "string" then
			continue
		elseif arg == "-x" then
			opts.failFast = true
			continue
		elseif string.sub(arg, 1, 1) ~= "-" then
			setFilter(arg)
			continue
		end
		local flag, value = string.match(arg, "^%-%-([%w%-]+)=(.*)$")
		if flag == nil then flag = string.match(arg, "^%-%-([%w%-]+)$") end
		local function takeValue(): string
			if value ~= nil then return value end
			local nextArg = raw[i]
			if type(nextArg) == "string" and (string.sub(nextArg, 1, 1) ~= "-" or string.match(nextArg, "^%-%d")) then
				i += 1
				return nextArg
			end
			return failCli(`--{flag} expects a value`)
		end
		if flag == nil then
			failCli(`unknown flag {arg} (known: {KNOWN_FLAGS})`)
		elseif flag == "mutant" or flag == "mutants" then
			local val = takeValue()
			local ids, rest = string.match(val, "^([%d,]+):(.*)$")
			ids = ids or val
			if string.match(ids :: string, if flag == "mutant" then "^%d+$" else "^[%d,]+$") == nil then
				failCli(`--{flag} expects {if flag == "mutant" then "a mutant id" else "mutant ids"}, got "{val}"`)
			end
			if flag == "mutant" then
				opts.mutant = tonumber(ids)
			else
				opts.mutants = idList(ids :: string)
			end
			if rest ~= nil and rest ~= "" then mutantFilter = rest end
			opts.failFast = true
		elseif flag == "fail-fast" then
			if value ~= nil and value ~= "true" and value ~= "false" then
				failCli(`--fail-fast expects true or false, got "{value}"`)
			end
			opts.failFast = value ~= "false"
		elseif SWITCH_FLAGS[flag] ~= nil then
			if value ~= nil then failCli(`--{flag} takes no value, got "{value}"`) end
			opts[SWITCH_FLAGS[flag]] = true
		elseif flag == "filter" then
			setFilter(takeValue())
		elseif NUMERIC_FLAGS[flag] ~= nil then
			local val = takeValue()
			if flag == "seed" and val == "random" then
				opts.seed = os.time()
			else
				local number = tonumber(val)
				if number == nil or number ~= number or math.abs(number) == math.huge then
					failCli(`--{flag} expects a number{if flag == "seed" then ' or "random"' else ""}, got "{val}"`)
				elseif flag == "runs" and (number < 1 or number ~= math.floor(number)) then
					failCli(`--runs expects a whole number from 1, got "{val}"`)
				elseif flag == "replay" and (number < 0 or number ~= math.floor(number)) then
					failCli(`--replay expects a whole number from 0, got "{val}"`)
				elseif (flag == "budget" or flag == "test-timeout") and number <= 0 then
					failCli(`--{flag} expects a number above 0, got "{val}"`)
				end
				opts[NUMERIC_FLAGS[flag]] = number
			end
		else
			failCli(`unknown flag --{flag} (known: {KNOWN_FLAGS})`)
		end
	end
	if opts.filter == nil then opts.filter = mutantFilter end
	if opts.mutant ~= nil then
		mutant.parsed = { id = opts.mutant, outer = mutant.get() or 0 }
		mutant.set(opts.mutant)
	end
	if opts.mutant ~= nil or opts.mutants ~= nil then mutant.share() end
	return opts :: any
end

return runner
