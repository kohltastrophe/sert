--!strict
-- Test runner (`core/runner`): target selection, LIFO hooks, error preservation, CI focus gate, yield pumping, sharding, and CLI parsing.

local format = require("./format")
local registry = require("./registry")

local mutant = registry.mutant
local output = registry.output

export type Shard = registry.Shard
export type RunOptions = registry.RunOptions
export type Target = registry.Target

local IS_ROBLOX = (game :: any) ~= nil
local DEFAULT_TIMEOUT = 30
local DEFAULT_SEED_BASE = 0x5EED
local YIELDED = "test yielded and was never resumed"

type Test = registry.Test
type Hooks = registry.Hooks
type HookFn = registry.HookFn
type TestContext = registry.TestContext

export type Failure = string

export type Results = {
	passed: number,
	failed: number,
	skipped: number,
	skippedRoblox: number,
	skippedRtest: number,
	todo: number,
	total: number,
	clock: number,
	failures: { string },
	seeds: { [string]: number },
	mutants: { { id: number, killed: boolean } }?,
}

local errorText = format.errorText

local SHARD_KEY = "__SERT_SHARD"
local shardInfo = {}
local shardOverride: { value: Shard? }? = nil

function shardInfo.get(): Shard?
	local info = if shardOverride ~= nil then shardOverride.value else rawget(mutant._sharedG, SHARD_KEY)
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

local function appendError(existing: string?, extra: string?): string?
	if extra == nil or extra == "" then return existing end
	if existing == nil or existing == "" then return extra end
	return `{existing}\n   teardown also failed — {extra}`
end

local function isTruthyEnv(val: any): boolean
	if val == true or val == 1 then return true end
	if type(val) == "string" then
		local lower = string.lower(val)
		return lower ~= "" and lower ~= "0" and lower ~= "false" and lower ~= "no"
	end
	return false
end

local function detectCi(opts: RunOptions): boolean
	if opts.ci ~= nil then return opts.ci == true end
	local sharedCi = rawget(mutant._sharedG, "__SERT_CI")
	if sharedCi ~= nil then return isTruthyEnv(sharedCi) end
	local osTbl: any = os
	local getenv = if type(osTbl) == "table" then rawget(osTbl, "getenv") else nil
	if type(getenv) == "function" then
		local getenvFn = getenv :: (string) -> string?
		local ok, val = pcall(getenvFn, "CI")
		if ok and isTruthyEnv(val) then return true end
	end
	return false
end

local function resolveTimeout(opts: RunOptions): number return opts.testTimeout or opts.timeout or DEFAULT_TIMEOUT end

local function invoke(fn: () -> (), timeout: number): (boolean, any)
	local curState = registry.state
	local saved = table.clone(curState)
	local depth = registry.isolateDepth
	local activeMut = mutant.get()
	local sinkDepth = output.depth()

	local function restore()
		local nowState = registry.state
		local outerDeferred = saved.deferred or saved.loaded
		if outerDeferred ~= nil then
			if nowState.loaded ~= nil and nowState.loaded ~= saved.loaded and nowState.loaded ~= outerDeferred then
				table.move(nowState.loaded, 1, #nowState.loaded, #outerDeferred + 1, outerDeferred)
			end
			if
				nowState.deferred ~= nil
				and nowState.deferred ~= saved.deferred
				and nowState.deferred ~= outerDeferred
			then
				table.move(nowState.deferred, 1, #nowState.deferred, #outerDeferred + 1, outerDeferred)
			end
		end
		registry.replaceState(saved)
		registry.isolateDepth = depth
		mutant.set(activeMut)
		output.trim(sinkDepth)
	end

	if not IS_ROBLOX then
		local thread = coroutine.create(fn)
		local ok, err = coroutine.resume(thread)
		if not ok then
			restore()
			return false, err
		end
		if coroutine.status(thread) ~= "dead" then
			local driver = registry.getYieldDriver()
			if driver ~= nil then
				local callOk, drvOk, drvErr = pcall(driver, thread, timeout)
				if not callOk then
					pcall(coroutine.close, thread)
					restore()
					return false, drvOk
				end
				if coroutine.status(thread) ~= "dead" then
					pcall(coroutine.close, thread)
					restore()
					return false, drvErr or `test timed out after {timeout} s`
				end
				if not drvOk then restore() end
				return drvOk == true, drvErr
			end
			pcall(coroutine.close, thread)
			restore()
			return false, YIELDED
		end
		return true, nil
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
	if not ok then restore() end
	return ok, err
end

-- Drains `list` in strict LIFO order, preserving every raised error.
local function drain(list: { HookFn }, timeout: number): string?
	local failure: string? = nil
	while #list > 0 do
		local fn = table.remove(list) :: HookFn
		local ok, err = invoke(fn, timeout)
		if not ok then failure = appendError(failure, `defer: {errorText(err)}`) end
	end
	return failure
end

local function runTest(
	test: Test,
	chain: { Hooks },
	opts: RunOptions
): (string?, string?, number?, { [string]: number })
	local state = registry.state
	local timeout = test.timeout or resolveTimeout(opts)
	local outerDeferred, outerSeeds = state.deferred, state.inlineSeeds
	local pendingDefer: { HookFn }, inlineSeeds: { [string]: number } = {}, {}
	state.deferred, state.inlineSeeds = pendingDefer, inlineSeeds
	local endEnvScope = registry.beginEnvScope()

	local ctx: TestContext = {
		name = test.name,
		file = test.file,
		target = test.target,
		defer = function(_self: TestContext, fn: () -> ())
			registry.checkFn("ctx:defer", nil, fn, nil)
			table.insert(pendingDefer, fn)
		end,
	}

	local failure: string?, detail: string?, seed: number? = nil, nil, nil
	local enteredScopes = 0
	for scopeIdx = 1, #chain do
		local hooks = chain[scopeIdx]
		local scopeOk = true
		for _, hook in hooks.before do
			local ok, err = invoke(hook, timeout)
			if not ok then
				failure = `beforeEach: {errorText(err)}`
				scopeOk = false
				break
			end
		end
		if not scopeOk then break end
		enteredScopes = scopeIdx
	end

	if failure == nil then
		local property = test.prop
		if property ~= nil then
			local result: registry.PropExecResult? = nil
			local runOptions = table.clone(opts)
			local seeded = if opts.seeds ~= nil then opts.seeds[test.name] else nil
			if seeded ~= nil and runOptions.replay == nil then runOptions.replay = seeded end
			local ok, err = invoke(
				function() result = property.exec(runOptions, registry.isolateDepth == 0) end,
				timeout
			)
			if not ok then
				failure = errorText(err)
			elseif result ~= nil and not result.ok then
				failure = result.report or result.message or "property failed"
				seed = result.seed
			elseif result ~= nil then
				local noun = if result.exhaustive then "program" else "case"
				detail = `{result.cases} {noun}{if result.cases == 1 then "" else "s"}`
			end
		else
			local ok, err = invoke(function() test.fn(ctx) end, timeout)
			if not ok then failure = errorText(err) end
		end

		local postHook = registry.getPostTestHook()
		if postHook ~= nil and opts.sweep ~= false then
			local postOk, postErr = invoke(function() postHook(ctx) end, timeout)
			if not postOk then failure = appendError(failure, `postTest: {errorText(postErr)}`) end
		end
	end

	failure = appendError(failure, drain(pendingDefer, timeout))

	-- Run `afterEach` in strict LIFO order (`child` before `parent`, reverse registration within each scope),
	-- skipping scopes whose `beforeEach` threw.
	for scopeIdx = enteredScopes, 1, -1 do
		local afterList = chain[scopeIdx].after
		for hookIdx = #afterList, 1, -1 do
			local ok, err = invoke(afterList[hookIdx], timeout)
			if not ok then failure = appendError(failure, `afterEach: {errorText(err)}`) end
		end
	end

	failure = appendError(failure, drain(pendingDefer, timeout))

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
	pass: ((Test, string) -> ())?,
	chainByIndex: { [number]: { Hooks } }?
): { string }
	local state = registry.state
	local tests = state.tests
	local globals = if chainByIndex == nil then registry.globalChain() else nil
	local chains: { [number]: { Hooks } } = {}
	local first: { [Hooks]: number }, last: { [Hooks]: number } = {}, {}
	local lastOfFile: { [string]: number } = {}
	for position, index in order do
		if plan == nil or plan[index] == "run" then
			local test = tests[index]
			local chain: { Hooks } = if chainByIndex ~= nil
				then chainByIndex[index]
				else registry.chainOf(test, globals :: { Hooks })
			chains[position] = chain
			for _, hooks in chain do
				first[hooks] = first[hooks] or position
				last[hooks] = position
			end
			if withLast then lastOfFile[test.file] = position end
		end
	end

	local timeout = resolveTimeout(opts)
	local started: { Hooks }, finished: { [Hooks]: boolean } = {}, {}
	local beforeAllErr: { [Hooks]: string }, deferred: { [Hooks]: { HookFn } } = {}, {}

	local function enter(hooks: Hooks)
		table.insert(started, hooks)
		local list: { HookFn } = {}
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
		local list = deferred[hooks] :: { HookFn }
		local errAcc: string? = nil
		-- Skip `afterAll` if `beforeAll` for this scope threw; still drain any `defer`/spy cleanups registered before the throw.
		if beforeAllErr[hooks] == nil then
			state.deferred = list
			for hookIdx = #hooks.afterAll, 1, -1 do
				local ok, err = invoke(hooks.afterAll[hookIdx], timeout)
				if not ok then errAcc = appendError(errAcc, `afterAll: {errorText(err)}`) end
			end
			state.deferred = nil
		end
		errAcc = appendError(errAcc, drain(list, timeout))
		return errAcc
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
			state.running = {
				name = test.name,
				file = test.file,
				target = test.target,
				last = withLast and lastOfFile[test.file] == position,
			}
			failure, detail, seed, inlineSeeds = runTest(test, chain, opts)
			state.running = nil
		end
		for c = #chain, 1, -1 do
			local hooks = chain[c]
			if last[hooks] == position then
				local afterErr = leave(hooks)
				failure = appendError(failure, afterErr)
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

local function countStep(plan: { string }, step: string): number
	local total = 0
	for _, each in plan do
		if each == step then
			total += 1
		end
	end
	return total
end

local function enterMutant(opts: RunOptions): (boolean, () -> ())
	local state = registry.state
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
		opts.quiet = true
		mutant.set(nil)
	elseif opts.mutant ~= nil then
		mutant.set(opts.mutant)
	end
	local outerOptions = state.options
	return mutantRun,
		function()
			registry.state.options = outerOptions
			if ownsMutant then mutant.set(outerMutant) end
		end
end

local function parseFileFilter(opts: RunOptions)
	if type(opts.filter) == "string" and string.sub(opts.filter, 1, 6) == "@file=" then
		local fileList: { string } = if opts.files ~= nil then table.clone(opts.files) else {}
		for part in string.gmatch(string.sub(opts.filter, 7), "[^,]+") do
			local trimmed = string.match(part, "^%s*(.-)%s*$")
			if trimmed ~= nil and trimmed ~= "" then table.insert(fileList, trimmed) end
		end
		opts.files, opts.filter = fileList, nil
	end
	if opts.file ~= nil then
		local fileList: { string } = if opts.files ~= nil then table.clone(opts.files) else {}
		table.insert(fileList, opts.file)
		opts.files = fileList
	end
end

local function matchesPatternOrSubstring(name: string, lowerName: string, query: string, lowerQuery: string): boolean
	if string.find(lowerName, lowerQuery, 1, true) ~= nil then return true end
	local ok, found = pcall(function() return string.find(name, query) end)
	return ok and found ~= nil
end

local function fileMatches(testFile: string, wantedFiles: { string }): boolean
	local normTest = string.lower(testFile)
	local baseTest = string.match(normTest, "[^/]+$") or normTest
	for _, wanted in wantedFiles do
		if normTest == wanted or baseTest == wanted or string.sub(normTest, -#wanted - 1) == "/" .. wanted then
			return true
		end
	end
	return false
end

local function selector(opts: RunOptions): (Shard?, (Test) -> boolean)
	local filters = if opts.filters ~= nil and #opts.filters > 0 then opts.filters else nil
	local lowerFilter = if opts.filter ~= nil then string.lower(opts.filter) else nil
	local grep = opts.grep
	local lowerGrep = if grep ~= nil then string.lower(grep) else nil
	local lowerFilters: { string }? = nil
	if filters ~= nil then
		local lowered = {}
		for _, text in filters do
			table.insert(lowered, string.lower(text))
		end
		lowerFilters = lowered
	end
	local named = if opts.names ~= nil then toNameSet(opts.names) else nil
	local excludeExact = if opts.excludes ~= nil and #opts.excludes > 0 then toNameSet(opts.excludes) else nil
	local excludeQuery = opts.exclude
	local lowerExclude = if excludeQuery ~= nil then string.lower(excludeQuery) else nil

	local wantedFiles: { string }? = nil
	if opts.files ~= nil and #opts.files > 0 then
		local list: { string } = {}
		for _, f in opts.files do
			table.insert(list, string.lower(registry.normalizeSpecFile(f)))
		end
		wantedFiles = list
	end

	local explicit = opts.filter ~= nil or grep ~= nil or filters ~= nil or opts.names ~= nil or wantedFiles ~= nil
	local shard: Shard? = if type(opts.shard) == "table"
		then opts.shard
		elseif opts.shard == true or (opts.shard == nil and not explicit) then shardInfo.get()
		else nil

	local function selected(test: Test): boolean
		if shard ~= nil and not shardInfo.selects(test.name, shard) then return false end
		local lowerName = string.lower(test.name)
		if lowerFilter ~= nil and string.find(lowerName, lowerFilter, 1, true) == nil then return false end
		if
			grep ~= nil
			and lowerGrep ~= nil
			and not matchesPatternOrSubstring(test.name, lowerName, grep, lowerGrep)
		then
			return false
		end
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
		if named ~= nil and not named[test.name] then return false end
		if excludeExact ~= nil then
			if excludeExact[test.name] then return false end
			local exactMap: { [any]: boolean } = excludeExact :: any
			for ex in next, exactMap do
				if type(ex) == "string" and string.find(lowerName, string.lower(ex), 1, true) ~= nil then
					return false
				end
			end
		end
		if
			excludeQuery ~= nil
			and lowerExclude ~= nil
			and matchesPatternOrSubstring(test.name, lowerName, excludeQuery, lowerExclude)
		then
			return false
		end
		return wantedFiles == nil or fileMatches(test.file, wantedFiles)
	end
	return shard, selected
end

local function selectionText(opts: RunOptions, shard: Shard?): string
	local selection = {}
	if opts.filter ~= nil then table.insert(selection, `filter "{opts.filter}"`) end
	if opts.grep ~= nil then table.insert(selection, `grep "{opts.grep}"`) end
	if opts.filters ~= nil and #opts.filters > 0 then
		table.insert(selection, `filters "{table.concat(opts.filters, '" | "')}"`)
	end
	if opts.names ~= nil then table.insert(selection, `{#opts.names} named`) end
	if opts.exclude ~= nil then table.insert(selection, `exclude "{opts.exclude}"`) end
	if opts.excludes ~= nil and #opts.excludes > 0 then table.insert(selection, `{#opts.excludes} excluded`) end
	if opts.files ~= nil and #opts.files > 0 then table.insert(selection, `files {table.concat(opts.files, ", ")}`) end
	if shard ~= nil then table.insert(selection, `shard {shard.name} ({shard.index}/{shard.count})`) end
	if opts.exhaustive then
		table.insert(selection, `exhaustive · budget {opts.budget or 600} s`)
	elseif opts.replay ~= nil then
		table.insert(selection, `replay {tostring(opts.replay)}`)
	elseif opts.seeds ~= nil and next(opts.seeds) ~= nil then
		local seeded = 0
		for _ in next, opts.seeds do
			seeded += 1
		end
		table.insert(selection, `{seeded} seeded`)
	else
		if opts.seed ~= nil then table.insert(selection, `seed {opts.seed}`) end
		if opts.runs ~= nil then table.insert(selection, `{opts.runs} runs`) end
	end
	return if #selection > 0 then " · " .. table.concat(selection, " · ") else ""
end

local function targetSetOf(opts: RunOptions): ({ [string]: boolean }?, boolean)
	if opts.targets ~= nil then
		local allowed: { [string]: boolean } = {}
		for _, t in opts.targets do
			allowed[t] = true
		end
		if opts.allTargets == true then allowed.portable = true end
		return allowed, true
	end
	return nil, false
end

local function planTests(opts: RunOptions, selected: (Test) -> boolean, shard: Shard?): ({ string }, boolean, boolean)
	local state = registry.state
	local activeSide = state.side
	local modShard = shard ~= nil and shard.only == nil and shard.except == nil and shard.count > 1
	local shardMatched = 0
	local explicitTargets, hasExplicitTargets = targetSetOf(opts)
	local plan: { string }, properties, focusedRan = {}, false, false

	for index, test in state.tests do
		local mode = test.mode
		local unfocused = state.focusing and not test.focused
		local sampled = opts.exhaustive == true and (test.prop == nil or test.prop.exhaustive == nil)

		if
			(activeSide ~= nil and test.side ~= nil and test.side ~= activeSide)
			or (hasExplicitTargets and explicitTargets ~= nil and not explicitTargets[test.target])
		then
			plan[index] = "ignore"
		elseif unfocused or not selected(test) then
			plan[index] = "out"
		elseif modShard and shard ~= nil and ((shardMatched % shard.count) + 1 ~= shard.index) then
			shardMatched += 1
			plan[index] = "ignore"
		else
			if modShard then
				shardMatched += 1
			end
			local headlessRobloxSkip = not hasExplicitTargets
				and not IS_ROBLOX
				and opts.allTargets ~= true
				and test.target ~= "portable"
			if headlessRobloxSkip or sampled or mode == "skip" then
				plan[index] = "skip"
			else
				plan[index] = "run"
				properties = properties or test.prop ~= nil
				if test.focused then focusedRan = true end
			end
		end
	end
	return plan, properties, focusedRan
end

local function runOrder(opts: RunOptions, mutantRun: boolean): { number }
	local tests = registry.state.tests
	local order: { number } = {}
	if opts.failFast and mutantRun then
		local slow: { number } = {}
		for index, test in tests do
			table.insert(if test.prop ~= nil then slow else order, index)
		end
		table.move(slow, 1, #slow, #order + 1, order)
	else
		for index = 1, #tests do
			order[index] = index
		end
	end
	return order
end

local function listTests(plan: { string }, results: Results, out: (...any) -> ())
	local listed = 0
	for index, test in registry.state.tests do
		if plan[index] ~= "out" and plan[index] ~= "ignore" then
			out(`[sert-list] {test.file}|{test.name}|{test.target}`)
			listed += 1
		end
	end
	out(`[sert-list] end {listed}`)
	results.skipped, results.total = listed, listed
	out(`[sert-done] {format.json(results)}`)
end

local function runBatch(batch: { number }, order: { number }, plan: { string }, opts: RunOptions, results: Results)
	local tests = registry.state.tests
	local globals = registry.globalChain()
	local runnable: { number } = {}
	local chainByIndex: { [number]: { Hooks } } = {}
	for _, index in order do
		if plan[index] == "run" then
			table.insert(runnable, index)
			chainByIndex[index] = registry.chainOf(tests[index], globals)
		end
	end
	local verdicts, lastKiller: number?, fastKillers: { number } = {}, nil, {}
	local inFast: { [number]: boolean } = {}
	results.total = 0
	for _, id in batch do
		mutant.set(id)
		local sequence = table.create(#runnable) :: { number }
		if lastKiller ~= nil then table.insert(sequence, lastKiller) end
		for _, index in fastKillers do
			if index ~= lastKiller then table.insert(sequence, index) end
		end
		for _, index in runnable do
			if index ~= lastKiller and not inFast[index] then table.insert(sequence, index) end
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
				elseif #fastKillers >= 8 then
					local evicted = table.remove(fastKillers)
					if evicted ~= nil then inFast[evicted] = nil end
				end
				table.insert(fastKillers, 1, outcome.index)
				inFast[outcome.index] = true
			end
			return true
		end, nil, chainByIndex)
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
	timings: { { name: string, file: string, ms: number } },
	out: (...any) -> (),
	shout: (...any) -> ()
)
	local function marker(test: Test, status: string, ms: number, failure: string?)
		if opts.markers then
			out(`[sert-test] {format.json({
				name = test.name,
				file = test.file,
				target = test.target,
				status = status,
				ms = ms,
				err = failure,
				error = failure,
			})}`)
		end
	end

	local repeats = math.max(1, opts.repeatCount or 1)
	for iteration = 1, repeats do
		local iterSuffix = if repeats > 1 then ` (iter {iteration}/{repeats})` else ""
		local stoppedEarly = false
		local leftovers = execute(
			order,
			plan,
			opts,
			iteration == repeats,
			function(outcome: Outcome): boolean
				local test, failure = outcome.test, outcome.failure
				table.insert(timings, { name = test.name .. iterSuffix, file = test.file, ms = outcome.ms })
				if failure ~= nil then
					for key, seed in next, outcome.inlineSeeds do
						results.seeds[key] = seed
						out(`[sert-seed] {key}|{seed}`)
					end
				end
				if failure == nil then
					results.passed += 1
					if not opts.compact then
						out(
							`✅ {test.name}{iterSuffix} · {outcome.ms} ms{if outcome.detail
								then " · " .. outcome.detail
								else ""}`
						)
					end
					marker(test, "pass", outcome.ms)
					return false
				end
				results.failed += 1
				table.insert(results.failures, `{test.name}{iterSuffix}: {failure}`)
				shout(`❌ {test.name}{iterSuffix} · {outcome.ms} ms\n   ⚠️ {failure}`)
				if test.prop == nil then
					local cmd = opts.command or "python3 tools/sert.py run"
					out(string.format("     replay: %s --filter %q", cmd, test.name))
				end
				if outcome.seed ~= nil then
					results.seeds[test.name] = outcome.seed
					out(`[sert-seed] {test.name}|{outcome.seed}`)
				end
				marker(test, "fail", outcome.ms, failure)
				if opts.failFast == true then
					stoppedEarly = true
					return true
				end
				return false
			end,
			if iteration == 1
				then function(test: Test, step: string)
					if step == "ignore" then return end
					results.skipped += 1
					if step == "skip" then
						if test.target ~= "portable" and not IS_ROBLOX and opts.allTargets ~= true then
							results.skippedRoblox += 1
							results.skippedRtest += 1
						end
						if test.mode == "skip" and not opts.exhaustive then out(`🟡 {test.name}`) end
						marker(test, "skip", 0)
					end
				end
				else nil
		)

		for _, afterErr in leftovers do
			results.failed += 1
			table.insert(results.failures, afterErr)
			shout(`❌ {afterErr}`)
		end
		if stoppedEarly then break end
	end
end

function runner.holdLoaded(): (timeout: number?) -> string?
	local state = registry.state
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
	return " (note: --filter matches test names; use --file <Spec> to filter by spec file)"
end

--- Runs registered tests under isolated per-call `RunOptions` and returns `Results`.
function runner.run(options: RunOptions?): Results
	local state = registry.state
	if state.running ~= nil then error("sert.run: cannot invoke runner inside a running test", 2) end

	local opts: RunOptions = if options ~= nil then table.clone(options) else {}
	local tests = state.tests
	local mutantRun, finish = enterMutant(opts)
	parseFileFilter(opts)
	local isQuiet = opts.quiet == true or opts.silent == true
	local out: (...any) -> () = if isQuiet then function() end else output.print
	local shout: (...any) -> () = if isQuiet then function() end else output.warn

	local results: Results = {
		passed = 0,
		failed = 0,
		skipped = 0,
		skippedRoblox = 0,
		skippedRtest = 0,
		todo = 0,
		total = #tests,
		clock = 0,
		failures = format.array({}),
		seeds = {},
	}

	local function settle()
		local deferErr = drain(registry.state.loaded, resolveTimeout(opts))
		if deferErr ~= nil then
			results.failed += 1
			table.insert(results.failures, deferErr)
			shout(`❌ {deferErr}`)
		end
		finish()
	end

	local function abort(message: string): Results
		results.failed += 1
		table.insert(results.failures, message)
		shout(`❌ {message}`)
		settle()
		if opts.markers or not isQuiet then out(`[sert-done] {format.json(results)}`) end
		if opts.raise ~= false then error(message, 0) end
		return results
	end

	local shard, selected = selector(opts)
	local plan, properties, focusedRan = planTests(opts, selected, shard)
	if opts.list then
		listTests(plan, results, out)
		finish()
		return results
	end

	local isSharded = (shard ~= nil and (shard.count or 1) > 1) or (opts :: any)._specSharded == true
	if #tests == 0 then
		if isSharded then
			out(`[sert-done] {format.json(results)}`)
			finish()
			return results
		end
		return abort("sert.run: no tests registered")
	end

	local selection = selectionText(opts, shard)
	local runtime = if IS_ROBLOX then "Roblox" else "Luau CLI"
	local focusTag = if state.focusing then " · FOCUS" else ""
	out(`sert · {#tests} {if #tests == 1 then "test" else "tests"} · {runtime}{focusTag}{selection}`)

	results.total -= countStep(plan, "ignore")
	if properties and not opts.exhaustive then out(`[sert-seed] run {opts.seed or DEFAULT_SEED_BASE}`) end
	if
		opts.requireTests
		and not isSharded
		and results.total > 0
		and not table.find(plan, "run")
		and not table.find(plan, "skip")
	then
		results.skipped = results.total
		local hint = filterHint(opts.filter or opts.grep, tests)
		return abort(`sert.run: requireTests: selection{selection} matched none of the {results.total} tests{hint}`)
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

	local timings: { { name: string, file: string, ms: number } } = {}
	runSelection(order, plan, opts, results, timings, out, shout)

	-- Enforce CI `.focus` gate when any focused test ran under CI without `allowFocused`.
	if (focusedRan or state.focusing) and detectCi(opts) and opts.allowFocused ~= true then
		local ciMsg = "focused test (.focus) ran while CI is enabled (pass --allow-focused to override)"
		results.failed += 1
		table.insert(results.failures, ciMsg)
		shout(`❌ {ciMsg}`)
	end

	results.clock = os.clock() - startClock
	settle()

	if opts.slowest ~= nil and opts.slowest > 0 and #timings > 0 then
		table.sort(
			timings,
			function(
				a: { name: string, file: string, ms: number },
				b: { name: string, file: string, ms: number }
			): boolean
				return a.ms > b.ms
			end
		)
		local take = math.min(#timings, opts.slowest)
		out(`\nslowest {take} {if take == 1 then "test" else "tests"}:`)
		for i = 1, take do
			local item = timings[i]
			out(`  {item.ms} ms · {item.name} ({item.file})`)
		end
	end

	local unselected = countStep(plan, "out")
	local notSelected = if unselected > 0 then ` · {unselected} not selected` else ""
	local robloxNote = if results.skippedRoblox > 0
		then ` ({results.skippedRoblox} roblox — run 'python3 tools/sert.py studio' to execute engine tests)`
		else ""
	out(
		`\n{results.passed} passed · {results.failed} failed · {results.skipped - unselected} skipped{robloxNote}{notSelected}`
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

local KNOWN_FLAGS = "--filter, --grep/-g, --exclude, --file, --seed, --replay, --runs, --budget, --test-timeout, "
	.. "--repeat, --slowest, --exhaustive, --list, --markers, --quiet, --silent, --compact, --ci, --allow-focused, "
	.. "--all, --no-sweep, -x/--fail-fast, --mutant, --mutants, --shard"

local NUMERIC_FLAGS: { [string]: string } = {
	seed = "seed",
	runs = "runs",
	budget = "budget",
	["test-timeout"] = "testTimeout",
	["repeat"] = "repeatCount",
	slowest = "slowest",
}

local SWITCH_FLAGS: { [string]: string } = {
	list = "list",
	exhaustive = "exhaustive",
	markers = "markers",
	quiet = "quiet",
	silent = "quiet",
	compact = "compact",
	ci = "ci",
	["allow-focused"] = "allowFocused",
	all = "allTargets",
}

local function failCli(message: string): never error(`sert.parseCliArgs: {message}`, 0) end

--- Parses CLI arguments (`...` or `{ ... }`) into `RunOptions`.
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
		elseif arg == "-g" then
			local nextArg = raw[i]
			if type(nextArg) ~= "string" then failCli("-g expects a pattern value") end
			i += 1
			opts.grep = nextArg
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
		elseif flag == "no-sweep" then
			if value ~= nil then failCli(`--no-sweep takes no value, got "{value}"`) end
			opts.sweep = false
		elseif SWITCH_FLAGS[flag] ~= nil then
			if value ~= nil then failCli(`--{flag} takes no value, got "{value}"`) end
			opts[SWITCH_FLAGS[flag]] = true
		elseif flag == "filter" then
			setFilter(takeValue())
		elseif flag == "grep" then
			opts.grep = takeValue()
		elseif flag == "exclude" then
			opts.exclude = takeValue()
		elseif flag == "file" then
			opts.files = opts.files or {}
			table.insert(opts.files, takeValue())
		elseif flag == "replay" then
			local val = takeValue()
			local num = tonumber(val)
			if num ~= nil and num == math.floor(num) and num >= 0 and math.abs(num) ~= math.huge then
				opts.replay = num
			else
				opts.replay = val
			end
		elseif flag == "shard" then
			local val = takeValue()
			local idxStr, cntStr = string.match(val, "^(%d+)/(%d+)$")
			local idx, cnt = tonumber(idxStr), tonumber(cntStr)
			if idx == nil or cnt == nil or idx < 1 or cnt < 1 or idx > cnt then
				failCli(`--shard expects INDEX/COUNT with 1 <= INDEX <= COUNT, got "{val}"`)
			end
			opts.shard = {
				name = `{idx}/{cnt}`,
				index = idx,
				count = cnt,
				runLimit = 0,
			}
		elseif NUMERIC_FLAGS[flag] ~= nil then
			local val = takeValue()
			if flag == "seed" and val == "random" then
				opts.seed = os.time()
			else
				local number = tonumber(val)
				if number == nil or number ~= number or math.abs(number) == math.huge then
					failCli(`--{flag} expects a number{if flag == "seed" then ' or "random"' else ""}, got "{val}"`)
				elseif
					(flag == "runs" or flag == "repeat" or flag == "slowest")
					and (number < 1 or number ~= math.floor(number))
				then
					failCli(`--{flag} expects a whole number from 1, got "{val}"`)
				elseif (flag == "budget" or flag == "test-timeout") and number <= 0 then
					failCli(`--{flag} expects a number above 0, got "{val}"`)
				end
				opts[NUMERIC_FLAGS[flag]] = number
				if flag == "test-timeout" then opts.timeout = number end
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
	return opts :: any
end

return table.freeze(runner)
