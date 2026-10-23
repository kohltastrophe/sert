--!strict
-- Studio test runner (`sert.roblox.Runner`): loads a place's spec modules on each side of a Studio session, runs them
-- with `sert`, and reports through markers and `StudioTestService:EndTest`.

local registry = require("../core/registry")
local runner = require("../core/runner")

local nativeRequire: any = require
local defaultSert: any = nil

local function service(name: string): any return (game :: any).GetService(game, name) end

export type Where = "server" | "client"

export type Context = {
	sert: any,
	side: string,
	where: string,
	request: Request,
	config: Config,
	filter: string,
	errors: { string },
}

export type Hooks = { beforeEach: (() -> ())?, afterEach: (() -> ())? }

export type Side = {
	root: Instance?,
	entry: ModuleScript?,
	where: Where?,
	filter: string?,
	setup: Hooks?,
	before: ((Context) -> ())?,
	after: ((Context) -> ())?,
	concurrent: boolean?,
	rtestOnly: boolean?,
}

export type Config = {
	name: string?,
	root: Instance?,
	entry: ModuleScript?,
	sides: { [string]: Side }?,
	order: { string }?,
	sert: any?,
	rtestOnly: boolean?,
	warmup: ((Context) -> (() -> ())?)?,
	hideChat: boolean?,
	characters: boolean?,
	scriptErrors: boolean?,
	randomSeed: boolean?,
	context: ((Context) -> ...any)?,
}

export type Request = {
	runId: string,
	mode: string,
	filter: string?,
	filters: { string }?,
	names: { string }?,
	files: { string }?,
	excludes: { string }?,
	sides: { string }?,
	list: boolean,
	seed: number?,
	runs: number?,
	seeds: { [string]: number }?,
	replay: number?,
	exhaustive: boolean,
	budget: number?,
	command: string,
	iterations: number,
	timeout: number?,
	deadline: number,
	args: { [string]: any },
	unknown: { string },
}

export type Counts = { passed: number, failed: number, skipped: number, todo: number, total: number }

export type Partial = {
	counts: Counts,
	sides: { [string]: Counts & { ms: number } },
	failures: { string },
	seeds: { [string]: number },
	listed: number,
	runnerPassed: number,
}

export type Verdict = {
	runId: string,
	name: string,
	mode: string,
	passed: boolean,
	failed: number,
	counts: Counts,
	sides: { [string]: Counts & { ms: number } },
	failures: { string },
	seeds: { [string]: number },
	seed: number?,
	iterations: number,
	listed: boolean?,
	reason: string?,
	unknown: { string },
}

export type Resolved = { name: string, side: Side, where: Where }

local session = {}
session.ARGS_ATTRIBUTE = "sert_Args"
session.RUN_ATTRIBUTE = "sert_Run"
session.REQUEST = "sert.Request"
session.RESULT = "sert.Result"
session.KEYS = table.freeze({
	"runId",
	"mode",
	"filter",
	"filters",
	"names",
	"files",
	"excludes",
	"sides",
	"list",
	"seed",
	"runs",
	"seeds",
	"replay",
	"exhaustive",
	"budget",
	"command",
	"repeat",
	"timeout",
	"deadline",
})

local DEFAULT_DEADLINE = 600
local DEFAULT_COMMAND = "python3 tools/sert.py studio"
local MAX_FAILURES = 25
local COUNT_KEYS = { "passed", "failed", "skipped", "todo", "total" }
local KNOWN: { [string]: boolean } = {}
for _, key in session.KEYS do
	KNOWN[key] = true
end

function session.marker(kind: string, payload: string) print(`[sert-{kind}] {payload}`) end

function session.phase(where: string, name: string)
	session.marker("phase", `{where} {name} {DateTime.now().UnixTimestampMillis}`)
end

local function strings(value: any): { string }?
	if type(value) ~= "table" then return nil end
	local list = {}
	for _, item in value do
		if type(item) == "string" or type(item) == "number" then table.insert(list, tostring(item)) end
	end
	return list
end

local function selection(value: any): { string }?
	local list = strings(value)
	return if list ~= nil and #list > 0 then list else nil
end

local function whole(value: any, least: number): number?
	return if type(value) == "number" and value == math.floor(value) and value >= least then value else nil
end

function session.request(value: { [string]: any }): Request
	local seeds: { [string]: number }? = nil
	if type(value.seeds) == "table" then
		local map = {}
		for name, seed in value.seeds do
			local n = whole(seed, 0)
			if type(name) == "string" and n ~= nil then map[name] = n end
		end
		seeds = if next(map) ~= nil then map else nil
	end
	local iterations = whole(value["repeat"], 1) or 1
	local RunService: RunService? = if (game :: any) ~= nil then service("RunService") else nil
	local mode = if value.mode == "run"
			or value.mode == "edit"
			or value.mode == "play"
		then value.mode
		elseif RunService ~= nil and RunService:IsRunMode() then "run"
		elseif RunService ~= nil and RunService:IsRunning() then "play"
		else "edit"
	local timeout = if type(value.timeout) == "number" and value.timeout > 0 then value.timeout else nil
	local deadline = if type(value.deadline) == "number" and value.deadline > 0
		then value.deadline
		else DEFAULT_DEADLINE * iterations
	local unknown = {}
	for key in value do
		if not KNOWN[key] then table.insert(unknown, tostring(key)) end
	end
	table.sort(unknown)
	return {
		runId = tostring(value.runId or "local"),
		mode = mode,
		filter = if type(value.filter) == "string" and value.filter ~= "" then value.filter else nil,
		filters = selection(value.filters),
		names = strings(value.names),
		files = selection(value.files),
		excludes = selection(value.excludes),
		sides = selection(value.sides),
		list = value.list == true,
		seed = whole(value.seed, 0),
		runs = whole(value.runs, 1),
		seeds = seeds,
		replay = whole(value.replay, 0),
		exhaustive = value.exhaustive == true,
		budget = if type(value.budget) == "number" and value.budget > 0 then value.budget else nil,
		command = if type(value.command) == "string" and value.command ~= ""
			then value.command
			else `{DEFAULT_COMMAND} --mode {mode}`,
		iterations = iterations,
		timeout = timeout,
		deadline = deadline,
		args = value,
		unknown = unknown,
	}
end

local function contextFilter(request: Request): string
	local parts = {}
	if request.filter then table.insert(parts, request.filter) end
	for _, text in (request.filters or {}) :: { string } do
		table.insert(parts, text)
	end
	for _, text in (request.names or {}) :: { string } do
		table.insert(parts, text)
	end
	for _, file in (request.files or {}) :: { string } do
		table.insert(parts, `file:{file}`)
	end
	return string.lower(table.concat(parts, "\n"))
end

local function base(file: string): string return string.lower(registry.normalizeSpecFile(file)) end

local function hasSpecs(folder: Instance): boolean
	for _, child in folder:GetDescendants() do
		if child:IsA("ModuleScript") and string.match(child.Name, "%.spec$") then return true end
	end
	return false
end

function session.sides(config: Config): { Resolved }
	local sides: { [string]: Side } = {}
	if config.sides then
		sides = config.sides
	elseif config.entry then
		sides.main = { entry = config.entry }
	elseif config.root then
		local folders = 0
		for _, child in config.root:GetChildren() do
			if child:IsA("Folder") and hasSpecs(child) then
				sides[child.Name] = { root = child }
				folders += 1
			end
		end
		if folders == 0 then sides.main = { root = config.root } end
	end
	local names = {}
	for name in sides do
		table.insert(names, name)
	end
	local order = config.order or {}
	table.sort(names, function(a: string, b: string): boolean
		local ia, ib = table.find(order, a), table.find(order, b)
		if ia or ib then
			return (ia or math.huge) < (ib or math.huge)
		elseif (a == "server") ~= (b == "server") then
			return a == "server"
		end
		return a < b
	end)
	local resolved = {}
	for _, name in names do
		local side = sides[name]
		local where: Where = side.where or (if name == "server" then "server" else "client")
		table.insert(resolved, { name = name, side = side, where = where })
	end
	return resolved
end

function session.picks(config: Config, request: Request): { Resolved }
	local list: { Resolved } = {}
	for _, resolved in session.sides(config) do
		if request.sides == nil or table.find(request.sides, resolved.name) ~= nil then table.insert(list, resolved) end
	end
	return list
end

local function sertOf(config: Config): any
	if config.sert ~= nil then
		return config.sert
	elseif defaultSert ~= nil then
		return defaultSert
	elseif (script :: any) ~= nil and (script :: any).Parent ~= nil then
		return (require :: any)((script.Parent :: Instance).Parent)
	end
	return nativeRequire("../")
end

function session.newPartial(): Partial
	return {
		counts = { passed = 0, failed = 0, skipped = 0, todo = 0, total = 0 },
		sides = {},
		failures = {},
		seeds = {},
		listed = 0,
		runnerPassed = 0,
	}
end

local function sideCounts(partial: Partial, side: string): Counts & { ms: number }
	local counts = partial.sides[side]
	if counts == nil then
		counts = { passed = 0, failed = 0, skipped = 0, todo = 0, total = 0, ms = 0 }
		partial.sides[side] = counts
	end
	return counts
end

local function addFailure(partial: Partial, text: string)
	if #partial.failures < MAX_FAILURES then table.insert(partial.failures, text) end
end

function session.synthesize(partial: Partial, side: string, name: string, problem: string?)
	local HttpService = service("HttpService")
	session.marker(
		"test",
		HttpService:JSONEncode({
			name = name,
			file = "",
			side = side,
			status = if problem == nil then "pass" else "fail",
			ms = 0,
			error = problem,
			runner = true,
		})
	)
	local counts = sideCounts(partial, side)
	counts.total += 1
	partial.counts.total += 1
	if problem == nil then
		counts.passed += 1
		partial.counts.passed += 1
		partial.runnerPassed += 1
	else
		counts.failed += 1
		partial.counts.failed += 1
		addFailure(partial, `{name}: {problem}`)
	end
end

local function registeredFiles(sert: any): { [string]: boolean }?
	local ok, lines = pcall(sert.capture, function() pcall(sert.run, { list = true }) end)
	if not ok or type(lines) ~= "table" then return nil end
	local files = {}
	for _, line in lines do
		local file = string.match(tostring(line), "^%[sert%-list%] ([^|]*)|")
		if file ~= nil then files[string.lower(file)] = true end
	end
	return files
end

local function load(sert: any, resolved: Resolved, ctx: Context, partial: Partial): { string }?
	local side = resolved.side
	local args = if ctx.config.context then table.pack(ctx.config.context(ctx)) else table.pack(ctx)
	local function call(module: ModuleScript): (boolean, any)
		return pcall(function()
			local value: any = (require :: any)(module)
			if type(value) == "function" then
				(value :: any)(table.unpack(args, 1, args.n))
			elseif type(value) == "table" and type(value.register) == "function" then
				(value.register :: any)(table.unpack(args, 1, args.n))
			end
		end)
	end
	if side.root ~= nil then
		local modules = {}
		for _, child in side.root:GetDescendants() do
			if child:IsA("ModuleScript") and string.match(child.Name, "%.spec$") then table.insert(modules, child) end
		end
		table.sort(
			modules,
			function(a: ModuleScript, b: ModuleScript): boolean return a:GetFullName() < b:GetFullName() end
		)
		local owned = {}
		for _, module in modules do
			local file = string.sub(module.Name, 1, -6)
			table.insert(owned, file)
			local started = os.clock()
			registry.state.file = file
			local ok, problem = call(module)
			registry.state.file = nil
			session.marker("file", `{resolved.name}|{file}|{math.round((os.clock() - started) * 1000)}`)
			if not ok then
				session.synthesize(partial, resolved.name, `{resolved.name} · {module.Name} loads`, tostring(problem))
			end
		end
		return owned
	elseif side.entry ~= nil then
		local before = registeredFiles(sert)
		local started = os.clock()
		local ok, problem = call(side.entry)
		local ms = math.round((os.clock() - started) * 1000)
		if not ok then
			session.synthesize(partial, resolved.name, `{resolved.name} · {side.entry.Name} loads`, tostring(problem))
		end
		local after = registeredFiles(sert)
		if before == nil or after == nil then
			session.marker("file", `{resolved.name}|*|{ms}`)
			return nil
		end
		local owned = {}
		for file in after do
			if not before[file] then table.insert(owned, file) end
		end
		table.sort(owned)
		for _, file in owned do
			session.marker("file", `{resolved.name}|{file}|{ms}`)
		end
		return owned
	end
	return {}
end

local function sideFiles(request: Request, side: string, owned: { string }?): { string }?
	local wanted: { [string]: boolean }? = nil
	if request.files then
		local set = {}
		for _, entry in request.files do
			local from, file = string.match(entry, "^([^/]+)/(.+)$")
			if from == nil then
				set[base(entry)] = true
			elseif from == side then
				set[base(file :: string)] = true
			end
		end
		wanted = set
	end
	if owned == nil then
		if wanted == nil then return nil end
		local list = {}
		for file in wanted do
			table.insert(list, file)
		end
		return list
	end
	local list = {}
	for _, file in owned do
		if wanted == nil or wanted[base(file)] then table.insert(list, file) end
	end
	return list
end

local function steadyFrames(runService: RunService): number
	local steady, steadyTime, started = 0, 0, os.clock()
	while steady < 5 and os.clock() - started < 10 do
		local step = runService.Heartbeat:Wait()
		steady = if step < 0.1 then steady + 1 else 0
		steadyTime = if step < 0.1 then steadyTime + step else 0
	end
	return math.round(steadyTime / math.max(steady, 1) * 1000)
end

local function invoke(sert: any, options: { [string]: any }): (any, string?)
	local ok, val = pcall(sert.run, options)
	return if ok then val else nil, if ok then nil else tostring(val)
end

local function prepareClient(config: Config, ctx: Context, runService: RunService)
	if config.hideChat ~= false then
		local TextChatService = service("TextChatService")
		for _, name in { "ChatWindowConfiguration", "ChatInputBarConfiguration" } do
			local chat = TextChatService:WaitForChild(name, 5)
			if chat ~= nil then (chat :: any).Enabled = false end
		end
	end
	if config.warmup then
		local ok, undo = pcall(config.warmup, ctx)
		session.marker("frame", `warm {steadyFrames(runService)}`)
		if ok and type(undo) == "function" then pcall(undo) end
	end
	session.phase("client", "warm")
end

local function listAndCountByFile(
	sert: any,
	config: Config,
	sides: { Resolved },
	logService: LogService
): (number, boolean, { [string]: { [string]: number } }, { [string]: number })
	local sideRtestOnly: { [string]: boolean } = {}
	for _, resolved in sides do
		local rtestOnly = if resolved.side.rtestOnly ~= nil then resolved.side.rtestOnly else config.rtestOnly
		sideRtestOnly[resolved.name] = rtestOnly == true
	end
	local sideFileCounts: { [string]: { [string]: number } } = {}
	for _, test in registry.state.tests do
		local sideName = test.side
		if sideName ~= nil and not (sideRtestOnly[sideName] and test.mode == "test") then
			local byFile = sideFileCounts[sideName]
			if byFile == nil then
				byFile = {}
				sideFileCounts[sideName] = byFile
			end
			local key = base(test.file)
			byFile[key] = (byFile[key] or 0) + 1
		end
	end
	local perFile: { [string]: number } = {}
	local listEnded = false
	local listing = logService.MessageOut:Connect(function(message: string)
		local file = string.match(message, "^%[sert%-list%] ([^|]*)|")
		if file ~= nil then
			perFile[string.lower(file)] = (perFile[string.lower(file)] or 0) + 1
		elseif string.match(message, "^%[sert%-list%] end ") then
			listEnded = true
		end
	end)
	local listOk, listed = pcall(sert.run, { list = true, markers = true, rtestOnly = config.rtestOnly })
	for _ = 1, 10 do
		if listEnded or not listOk then break end
		task.wait()
	end
	listing:Disconnect()
	local total = if listOk and type(listed) == "table" then tonumber(listed.total) or 0 else 0
	return total, listEnded, sideFileCounts, perFile
end

local function runSideGroup(
	sert: any,
	config: Config,
	request: Request,
	resolved: Resolved,
	ctx: Context,
	files: { string }?,
	selects: boolean,
	listEnded: boolean,
	sideFileCounts: { [string]: { [string]: number } },
	perFile: { [string]: number },
	partial: Partial
)
	local side = resolved.side
	local started = os.clock()
	local problem: string? = nil
	local results: any = nil
	local ok, hookProblem = pcall(function()
		if side.before then side.before(ctx) end
	end)
	if not ok then
		problem = `before: {hookProblem}`
	else
		sert.setup(side.setup or {})
		registry.state.side = resolved.name
		results, problem = invoke(sert, {
			filter = if selects then request.filter else side.filter or request.filter,
			filters = request.filters,
			names = request.names,
			files = files,
			excludes = request.excludes,
			seed = request.seed,
			runs = request.runs,
			seeds = request.seeds,
			replay = request.replay,
			exhaustive = request.exhaustive,
			budget = request.budget,
			command = request.command,
			timeout = request.timeout,
			rtestOnly = if side.rtestOnly ~= nil then side.rtestOnly else config.rtestOnly,
			markers = true,
			raise = false,
		})
		registry.state.side = nil
		sert.setup({})
		if side.after then
			local after = side.after
			local afterOk, afterProblem = pcall(function() after(ctx) end)
			if not afterOk then
				session.synthesize(partial, resolved.name, `{resolved.name} · after`, tostring(afterProblem))
			end
		end
	end
	local counts = sideCounts(partial, resolved.name)
	counts.ms += math.round((os.clock() - started) * 1000)
	if type(results) == "table" then
		local total = tonumber(results.total) or 0
		if files ~= nil then
			local bySide = sideFileCounts[resolved.name]
			if bySide ~= nil or listEnded then
				local own = 0
				for _, file in files do
					local key = base(file)
					own += if bySide ~= nil then (bySide[key] or 0) else (perFile[key] or 0)
				end
				total = math.min(total, own)
			end
		end
		local passed, failed = tonumber(results.passed) or 0, tonumber(results.failed) or 0
		local todo = tonumber(results.todo) or 0
		local tally: { [string]: number } = {
			passed = passed,
			failed = failed,
			skipped = math.max(0, total - passed - failed - todo),
			todo = todo,
			total = math.max(total, passed + failed + todo),
		}
		for key, n in tally do
			local c: any, p: any = counts, partial.counts
			c[key] += n
			p[key] += n
		end
		for _, failure in results.failures or {} do
			addFailure(partial, `{resolved.name} · {failure}`)
		end
		for name, seed in results.seeds or {} do
			partial.seeds[name] = seed
		end
	elseif problem ~= nil then
		session.synthesize(partial, resolved.name, `{resolved.name} · runs`, tostring(problem))
	end
end

function session.runHere(
	config: Config,
	request: Request,
	where: string,
	sides: { Resolved },
	handoff: (() -> ())?
): Partial
	local HttpService = service("HttpService")
	local LogService = service("LogService")
	local RunService = service("RunService")
	local sert = sertOf(config)
	local partial = session.newPartial()
	local errors: { string } = {}
	local watcher: RBXScriptConnection? = nil
	if config.scriptErrors then
		local ScriptContext: ScriptContext = service("ScriptContext")
		watcher = ScriptContext.Error:Connect(
			function(message: string, trace: string)
				table.insert(errors, `{message} @ {(string.gsub(trace, "\n", " | "))}`)
			end
		)
	end
	local function context(side: string): Context
		return {
			sert = sert,
			side = side,
			where = where,
			request = request,
			config = config,
			filter = contextFilter(request),
			errors = errors,
		}
	end

	if where == "client" then prepareClient(config, context(""), RunService) end

	local owned: { [string]: { string }? } = {}
	for _, resolved in sides do
		registry.state.side = resolved.name
		owned[resolved.name] = load(sert, resolved, context(resolved.name), partial)
		registry.state.side = nil
	end
	session.phase(where, "loaded")
	local drainLoaded = runner.holdLoaded()
	local function settle()
		local problem = drainLoaded(request.timeout)
		if problem ~= nil then session.synthesize(partial, where, `{where} · defer`, problem) end
	end

	local listedTotal, listEnded, sideFileCounts, perFile = listAndCountByFile(sert, config, sides, LogService)
	partial.listed = listedTotal
	if request.list then
		settle()
		session.phase(where, "listed")
		if watcher then watcher:Disconnect() end
		return partial
	end

	local selects = request.filter ~= nil or request.filters ~= nil or request.names ~= nil or request.files ~= nil
	local frames, frameTime = 0, 0
	local frameClock = RunService.Heartbeat:Connect(function(step: number)
		frames += 1
		frameTime += step
	end)

	local function runGroup(group: { Resolved })
		for iteration = 1, request.iterations do
			if request.iterations > 1 then session.marker("iter", `{where} {iteration} begin`) end
			local before = table.clone(partial.counts)
			for _, resolved in group do
				local files = sideFiles(request, resolved.name, owned[resolved.name])
				if files ~= nil and #files == 0 then continue end
				runSideGroup(
					sert,
					config,
					request,
					resolved,
					context(resolved.name),
					files,
					selects,
					listEnded,
					sideFileCounts,
					perFile,
					partial
				)
			end
			if request.iterations > 1 then
				local delta = {}
				for _, key in COUNT_KEYS do
					delta[key] = (partial.counts :: any)[key] - (before :: any)[key]
				end
				session.marker("iter", `{where} {iteration} end {HttpService:JSONEncode(delta)}`)
			end
		end
	end

	if handoff == nil then
		runGroup(sides)
	else
		local serial: { Resolved }, concurrent: { Resolved } = {}, {}
		for _, resolved in sides do
			table.insert(if resolved.side.concurrent then concurrent else serial, resolved)
		end
		runGroup(serial)
		handoff()
		runGroup(concurrent)
	end
	frameClock:Disconnect()
	settle()
	if frames > 0 then session.marker("frame", `run {math.round(frameTime / frames * 1000)}`) end
	if watcher then
		watcher:Disconnect()
		for _, text in errors do
			session.marker("x:error", `{where} {text}`)
		end
		session.synthesize(partial, where, `{where} · no script errors`, errors[1])
	end
	session.phase(where, "ran")
	return partial
end

function session.merge(into: Partial, from: any)
	if type(from) ~= "table" then return end
	for _, key in COUNT_KEYS do
		(into.counts :: any)[key] += tonumber(from.counts and from.counts[key]) or 0
	end
	for name, counts in from.sides or {} do
		into.sides[name] = counts
	end
	for _, failure in from.failures or {} do
		addFailure(into, tostring(failure))
	end
	for name, seed in from.seeds or {} do
		into.seeds[name] = seed
	end
	into.listed += tonumber(from.listed) or 0
	into.runnerPassed += tonumber(from.runnerPassed) or 0
end

function session.verdict(config: Config, request: Request, partial: Partial): Verdict
	local counts = partial.counts
	local ran = counts.passed - partial.runnerPassed
	local result: Verdict = {
		runId = request.runId,
		name = config.name or "sert",
		mode = request.mode,
		passed = counts.failed == 0 and ran > 0,
		failed = counts.failed,
		counts = counts,
		sides = partial.sides,
		failures = partial.failures,
		seeds = partial.seeds,
		seed = request.seed,
		iterations = request.iterations,
		unknown = request.unknown,
	}
	if request.list then
		result.listed = true
		result.passed = counts.failed == 0
		result.reason = `listed {partial.listed}`
	elseif counts.failed == 0 and ran == 0 then
		result.reason = "no test ran: nothing matched the selection"
	end
	return result
end

function session.report(result: Verdict)
	local HttpService = service("HttpService")
	local counts = result.counts
	print(
		`sert · {result.name} · {result.mode} · {if result.passed then "PASSED" else "FAILED"} · {counts.passed} passed`
			.. ` · {counts.failed} failed · {counts.skipped} skipped`
			.. `{if (counts.todo or 0) > 0 then ` · {counts.todo} todo` else ""}{if result.reason
				then " · " .. result.reason
				else ""}`
	)
	session.marker("verdict", HttpService:JSONEncode(result))
end

local Runner = {
	KEYS = session.KEYS,
	_session = table.freeze(session),
}

local CLIENT_WAIT = 600

function Runner.marker(tag: string, text: string) session.marker(`x:{tag}`, text) end

function Runner.phase(where: string, name: string)
	for _, part in { where, name } do
		if type(part) ~= "string" or not string.match(part, "^%S+$") then
			error(`Runner.phase: where and name must be one word each, got {string.format("%q", tostring(part))}`, 2)
		end
	end
	session.phase(where, name)
end

function Runner.args(wait: number?): { [string]: any }?
	local limit, waited = wait or 5, 0
	local HttpService = service("HttpService")
	local StudioTestService = service("StudioTestService")
	while true do
		local preset = workspace:GetAttribute(session.ARGS_ATTRIBUTE)
		if type(preset) == "string" then
			local decoded, given = pcall(HttpService.JSONDecode, HttpService, preset)
			if decoded and type(given) == "table" then return given end
		end
		local ok, value = pcall(StudioTestService.GetTestArgs, StudioTestService)
		if ok and type(value) == "table" then return value end
		if waited >= limit then return nil end
		waited += task.wait(0.1)
	end
end

function Runner.server(config: Config)
	local HttpService = service("HttpService")
	local Players = service("Players")
	local ReplicatedStorage = service("ReplicatedStorage")
	local RunService = service("RunService")
	if not RunService:IsStudio() then return end
	local args = Runner.args()
	if args == nil then return end
	local request = session.request(args)
	session.phase("server", "named")
	if config.characters == false then Players.CharacterAutoLoads = false end
	if request.seed == nil and config.randomSeed and not request.list then
		request.seed = Random.new():NextInteger(1, 0x7FFFFFFF)
	end

	local play = request.mode == "play"
	local here: { Resolved }, there: { Resolved } = {}, {}
	for _, resolved in session.picks(config, request) do
		table.insert(if play and resolved.where == "client" then there else here, resolved)
	end

	local clientReport: any = nil
	local resultEvent: RemoteEvent? = nil
	local resultConn: RBXScriptConnection? = nil
	if #there > 0 then
		local event = Instance.new("RemoteEvent")
		event.Name = session.RESULT
		resultConn = event.OnServerEvent:Connect(function(_, runId: any, payload: any)
			if runId == request.runId and type(payload) == "string" then
				local ok, value = pcall(HttpService.JSONDecode, HttpService, payload)
				clientReport = if ok then value else { failures = { `undecodable client report: {payload}` } }
			end
		end)
		event.Parent = ReplicatedStorage
		resultEvent = event
	end

	local handedAt: number? = nil
	local requestValue: StringValue? = nil
	local function handoff()
		if handedAt ~= nil then return end
		handedAt = os.clock()
		local stale = ReplicatedStorage:FindFirstChild(session.REQUEST)
		if stale ~= nil then stale:Destroy() end
		local value = Instance.new("StringValue")
		value.Name = session.REQUEST
		value.Value = HttpService:JSONEncode(table.clone(request) :: any)
		value.Parent = ReplicatedStorage
		requestValue = value
		workspace:SetAttribute(session.RUN_ATTRIBUTE, request.runId)
		session.phase("server", "handed")
	end

	local overlap = false
	if #there > 0 and request.iterations == 1 then
		for _, resolved in here do
			if resolved.side.concurrent then overlap = true end
		end
	end

	local partial = session.newPartial()
	if #here > 0 then
		local ok, found = pcall(session.runHere, config, request, "server", here, if overlap then handoff else nil)
		if ok then
			partial = found
		else
			session.synthesize(partial, "server", "server · runs", tostring(found))
		end
	end

	if #there > 0 then
		handoff()
		local deadline = (handedAt or os.clock()) + request.deadline
		while clientReport == nil and os.clock() < deadline do
			task.wait(0.05)
		end
		session.phase("server", "reported")
		if clientReport == nil then
			session.synthesize(partial, "client", "client · reports", `no client report within {request.deadline} s`)
		else
			session.merge(partial, clientReport)
		end
	end
	if resultConn then resultConn:Disconnect() end
	if resultEvent then resultEvent:Destroy() end
	if requestValue then requestValue:Destroy() end
	workspace:SetAttribute(session.RUN_ATTRIBUTE, nil)

	local result = session.verdict(config, request, partial)
	session.report(result)
	local StudioTestService = service("StudioTestService")
	local ended, problem = pcall(StudioTestService.EndTest, StudioTestService, result)
	if not ended then warn(`sert · StudioTestService:EndTest failed: {problem}`) end
end

function Runner.client(config: Config)
	local HttpService = service("HttpService")
	local ReplicatedStorage = service("ReplicatedStorage")
	local RunService = service("RunService")
	if not RunService:IsStudio() then return end
	if not game:IsLoaded() then game.Loaded:Wait() end
	session.phase("client", "started")
	local runId: any, waited = nil, 0
	while waited < CLIENT_WAIT do
		runId = workspace:GetAttribute(session.RUN_ATTRIBUTE)
		if type(runId) == "string" then break end
		waited += task.wait()
	end
	if type(runId) ~= "string" then return end
	local value = ReplicatedStorage:WaitForChild(session.REQUEST, 10)
	local decoded, given = false, nil
	if value ~= nil and value:IsA("StringValue") then
		decoded, given = pcall(HttpService.JSONDecode, HttpService, (value :: StringValue).Value)
	end
	if not decoded or type(given) ~= "table" then
		local failed = session.newPartial()
		local why = if value == nil or not value:IsA("StringValue")
			then `missing {session.REQUEST} StringValue`
			else `invalid {session.REQUEST} JSON`
		session.synthesize(failed, "client", "client · request", why)
		local event = ReplicatedStorage:WaitForChild(session.RESULT, 10)
		if event ~= nil and event:IsA("RemoteEvent") then event:FireServer(runId, HttpService:JSONEncode(failed)) end
		return
	end
	local request = session.request(given.args or {})
	request.seed = given.seed
	request.mode = "play"
	request.command = given.command or request.command
	session.phase("client", "named")

	local mine: { Resolved } = {}
	for _, resolved in session.picks(config, request) do
		if resolved.where == "client" then table.insert(mine, resolved) end
	end
	local ok, partial = pcall(session.runHere, config, request, "client", mine, nil)
	if not ok then
		local failed = session.newPartial()
		session.synthesize(failed, "client", "client · runs", tostring(partial))
		partial = failed
	end
	local event = ReplicatedStorage:WaitForChild(session.RESULT, 10)
	if event ~= nil and event:IsA("RemoteEvent") then event:FireServer(runId, HttpService:JSONEncode(partial)) end
end

function Runner.edit(config: Config, args: { [string]: any }?): Verdict
	local HttpService = service("HttpService")
	local given = args
	if given == nil then
		local preset = workspace:GetAttribute(session.ARGS_ATTRIBUTE)
		if type(preset) == "string" and preset ~= "" then
			local ok, decoded = pcall(HttpService.JSONDecode, HttpService, preset)
			given = if ok and type(decoded) == "table" then decoded else {}
		else
			given = {}
		end
	end
	local raw = table.clone(given :: { [string]: any })
	raw.mode = "edit"
	local request = session.request(raw)
	if request.seed == nil and config.randomSeed and not request.list then
		request.seed = Random.new():NextInteger(1, 0x7FFFFFFF)
	end
	session.phase("edit", "named")
	local ok, partial = pcall(session.runHere, config, request, "edit", session.picks(config, request), nil)
	if not ok then
		local failed = session.newPartial()
		session.synthesize(failed, "edit", "edit · runs", tostring(partial))
		partial = failed
	end
	local result = session.verdict(config, request, partial)
	session.report(result)
	return result
end

function Runner.setDefaultSert(sert: any) defaultSert = sert end

export type Runner = typeof(Runner)

return table.freeze(Runner) :: Runner
