--!strict
-- Test registry (`core/registry`): registration namespaces (`test`, `describe`), lifecycle hooks, output sinks, isolated state, yield drivers, and `safeenv`-clean mutation tracking.

local format = require("./format")
local mutantSlot = require("./mutant")
local util = require("./util")

export type Target = "portable" | "roblox" | "server" | "client"
export type Mode = "run" | "skip"

export type Shard = {
	name: string,
	index: number,
	count: number,
	runLimit: number?,
	only: { string }?,
	except: { string }?,
}

export type ShrinkBudget = { tries: number?, seconds: number? }

export type RunOptions = {
	filter: string?,
	grep: string?,
	filters: { string }?,
	names: { string }?,
	exclude: string?,
	excludes: { string }?,
	file: string?,
	files: { string }?,
	targets: { Target }?,
	allTargets: boolean?,
	ci: boolean?,
	allowFocused: boolean?,
	seed: number?,
	replay: (number | string)?,
	seeds: { [string]: number }?,
	runs: number?,
	exhaustive: boolean?,
	budget: number?,
	testTimeout: number?,
	timeout: number?,
	repeatCount: number?,
	slowest: number?,
	failFast: boolean?,
	quiet: boolean?,
	silent: boolean?,
	compact: boolean?,
	markers: boolean?,
	list: boolean?,
	shard: (Shard | boolean)?,
	command: string?,
	sweep: boolean?,
	raise: boolean?,
	requireTests: boolean?,
	mutant: number?,
	mutants: { number }?,
}

export type TestContext = typeof(table.freeze({} :: {
	name: string,
	file: string,
	target: Target,
	defer: (self: any, fn: () -> ...any) -> (),
}))

export type TestFn = (ctx: TestContext) -> ...any
export type HookFn = () -> ...any

export type TestOptions = typeof(table.freeze({} :: {
	timeout: number?,
	skip: boolean?,
	focus: boolean?,
	file: string?,
	target: Target?,
}))

export type DescribeOptions = typeof(table.freeze({} :: {
	separator: string?,
	file: string?,
	target: Target?,
	skip: boolean?,
	focus: boolean?,
}))

export type PropExecResult = {
	ok: boolean,
	cases: number,
	exhaustive: boolean,
	report: string?,
	message: string?,
	seed: number?,
}

export type ExhaustiveOption = typeof(table.freeze({} :: { size: number }))

export type PropAttachment = {
	name: string,
	exhaustive: ExhaustiveOption?,
	defaultSeed: number,
	exec: (runOptions: RunOptions, capMutant: boolean) -> PropExecResult,
}

export type Hooks = {
	beforeAll: { HookFn },
	afterAll: { HookFn },
	before: { HookFn },
	after: { HookFn },
}

export type Scope = {
	name: string,
	separator: string,
	hooks: Hooks,
	mode: ("skip" | "focus")?,
	target: Target?,
	file: string?,
}

export type Test = {
	name: string,
	fn: TestFn,
	mode: Mode,
	target: Target,
	focused: boolean,
	file: string,
	side: string?,
	timeout: number?,
	prop: PropAttachment?,
	scopes: { Scope },
}

export type Current = { name: string, file: string, target: Target, last: boolean }
export type Setup = { beforeAll: HookFn?, afterAll: HookFn?, beforeEach: HookFn?, afterEach: HookFn? }

export type EachFormat<T> = string | ((case: T, index: number) -> string)
export type TestCall = (name: string, fn: TestFn, options: TestOptions?) -> ()
export type TestSkipFn = (name: string, fn: TestFn?, options: TestOptions?) -> ()
export type TestEachFn = <T>(
	cases: { T }
) -> (fmt: EachFormat<T>, fn: (case: T, ctx: TestContext) -> (), options: TestOptions?) -> ()
export type TestEachTupleFn = (
	tuples: { { any } }
) -> (fmt: EachFormat<{ any }>, fn: (...any) -> (), options: TestOptions?) -> ()

export type TargetTestApi = typeof(setmetatable(
	{} :: {
		skip: TestSkipFn,
		focus: TestCall,
		each: TestEachFn,
		eachTuple: TestEachTupleFn,
	},
	{} :: { __call: (self: any, name: string, fn: TestFn, options: TestOptions?) -> () }
))

export type TestApi = typeof(setmetatable(
	{} :: {
		skip: TestSkipFn,
		focus: TestCall,
		each: TestEachFn,
		eachTuple: TestEachTupleFn,
		roblox: TargetTestApi,
		server: TargetTestApi,
		client: TargetTestApi,
	},
	{} :: { __call: (self: any, name: string, fn: TestFn, options: TestOptions?) -> () }
))

export type DescribeCall = (prefix: string, fn: () -> (), options: DescribeOptions?) -> ()
export type DescribeSkipFn = (prefix: string, fn: (() -> ())?, options: DescribeOptions?) -> ()
export type DescribeEachFn = <T>(
	cases: { T }
) -> (fmt: EachFormat<T>, fn: (case: T) -> (), options: DescribeOptions?) -> ()
export type DescribeEachTupleFn = (
	tuples: { { any } }
) -> (fmt: EachFormat<{ any }>, fn: (...any) -> (), options: DescribeOptions?) -> ()

export type TargetDescribeApi = typeof(setmetatable(
	{} :: {
		skip: DescribeSkipFn,
		focus: DescribeCall,
		each: DescribeEachFn,
		eachTuple: DescribeEachTupleFn,
	},
	{} :: { __call: (self: any, prefix: string, fn: () -> (), options: DescribeOptions?) -> () }
))

export type DescribeApi = typeof(setmetatable(
	{} :: {
		skip: DescribeSkipFn,
		focus: DescribeCall,
		each: DescribeEachFn,
		eachTuple: DescribeEachTupleFn,
		roblox: TargetDescribeApi,
		server: TargetDescribeApi,
		client: TargetDescribeApi,
	},
	{} :: { __call: (self: any, prefix: string, fn: () -> (), options: DescribeOptions?) -> () }
))

export type YieldDriver = (thread: thread, timeout: number) -> (boolean, any)
export type PostTestHook = (ctx: TestContext) -> ()

export type State = {
	tests: { Test },
	globalHooks: Hooks,
	fileHooks: { [string]: Hooks },
	fileOrder: { string },
	testFiles: { [string]: boolean },
	focusing: boolean,
	scopes: { Scope },
	side: string?,
	file: string?,
	running: Current?,
	deferred: { HookFn }?,
	loaded: { HookFn },
	options: RunOptions?,
	inlineSeeds: { [string]: number }?,
}

-- selene: allow(global_usage)
local SHARED_G: { [string]: any } = (
	if type(_G) == "table" and not table.isfrozen(_G) then _G :: any else setmetatable({}, { __index = _G })
) :: { [string]: any }

local MUTANT_WAIT_LIMIT = 25000
local waitCount, waitMutant: any = 0, nil

local mutant = {
	_sharedG = SHARED_G,
	_slot = mutantSlot,
	installCallerGlobals = nil :: (() -> ())?,
	parsed = nil :: { id: number, outer: number }?,
}

local function maybeInstallCallerGlobals()
	if mutantSlot.robloxGlobals and mutant.installCallerGlobals ~= nil then mutant.installCallerGlobals() end
end

function mutant.get(): number?
	local id = mutantSlot.id
	if type(id) == "number" and id > 0 then return id end
	local gId = rawget(SHARED_G, "__SERT_MUTANT")
	return if type(gId) == "number" and gId > 0 then gId else nil
end

function mutant.set(id: number?)
	local nextId = if id ~= nil and id > 0 then id else 0
	mutantSlot.id = nextId
	rawset(SHARED_G, "__SERT_MUTANT", if nextId > 0 then nextId else nil)
end

function mutant.waitGuard()
	local current = mutantSlot.id
	if current <= 0 then
		local gId = rawget(SHARED_G, "__SERT_MUTANT")
		current = if type(gId) == "number" then gId else 0
	end
	if current <= 0 then return end
	if current ~= waitMutant then
		waitMutant, waitCount = current, 0
	end
	waitCount += 1
	if waitCount > MUTANT_WAIT_LIMIT then error("sert.env: task.wait loop limit exceeded during mutation test", 0) end
end

local function emptyHooks(): Hooks return { beforeAll = {}, afterAll = {}, before = {}, after = {} } end

local function freshState(): State
	return {
		tests = {},
		globalHooks = emptyHooks(),
		fileHooks = {},
		fileOrder = {},
		testFiles = {},
		focusing = false,
		scopes = {},
		side = nil,
		file = nil,
		running = nil,
		deferred = nil,
		loaded = {},
		options = nil,
		inlineSeeds = nil,
	}
end

type Sink = (kind: "print" | "warn", line: string) -> ()
local sinks: { Sink } = {}
local output = {}

function output.join(...: any): string
	local n = select("#", ...)
	local parts = table.create(n)
	for index = 1, n do
		local ok, text = pcall(tostring, (select(index, ...)))
		parts[index] = if ok then text else "<unprintable>"
	end
	return table.concat(parts, " ")
end

local FLUSH_PAD = string.rep(" ", 8192)

function output.print(...: any)
	local sink = sinks[#sinks]
	if sink then
		sink("print", output.join(...))
	else
		print(...)
	end
end

function output.printFlush(...: any)
	local sink = sinks[#sinks]
	if sink then
		sink("print", output.join(...))
	else
		print(output.join(...) .. FLUSH_PAD)
	end
end

function output.warn(...: any)
	local sink = sinks[#sinks]
	if sink then
		sink("warn", output.join(...))
	else
		local w: (...any) -> () = if (warn :: any) == nil then print else warn
		w(...)
	end
end

local function within<T...>(sink: Sink, fn: (T...) -> ...any, ...: T...): (boolean, { n: number, [number]: any })
	table.insert(sinks, sink)
	local results = table.pack(pcall(fn, ...))
	for index = #sinks, 1, -1 do
		if sinks[index] == sink then
			table.remove(sinks, index)
			break
		end
	end
	return results[1], results
end

local NOOP_SINK: Sink = function() end

function output.quiet<T...>(fn: (T...) -> ...any, ...: T...): ...any
	local ok, results = within(NOOP_SINK, fn, ...)
	if not ok then error(results[2], 0) end
	return table.unpack(results, 2, results.n)
end

function output.capture<T...>(fn: (T...) -> ...any, ...: T...): { string }
	local lines = {}
	local ok, results = within(function(_, line) table.insert(lines, line) end, fn, ...)
	if not ok then error(results[2], 0) end
	return lines
end

function output.depth(): number return #sinks end

function output.trim(depth: number)
	while #sinks > depth do
		table.remove(sinks)
	end
end

local activeState: State = freshState()
local yieldDriver: YieldDriver? = nil
local postTestHook: PostTestHook? = nil
local activeEnvRef: { [number]: any } = setmetatable({}, { __mode = "v" }) :: any

local registry = {
	output = output,
	mutant = mutant,
	state = activeState,
	isolateDepth = 0,
}

--- Creates a fresh, isolated registry `State`.
function registry.newState(): State return freshState() end

--- Executes `fn` against `nextState` and restores the previous registry `State` afterward.
function registry.withState<T...>(nextState: State, fn: () -> T...): T...
	local prev = activeState
	activeState = nextState
	registry.state = nextState
	local callable: () -> ...any = fn :: any
	local results = table.pack(pcall(callable))
	activeState = prev
	registry.state = prev
	if not results[1] then error(results[2], 0) end
	local unpackFn: any = table.unpack
	return unpackFn(results, 2, results.n)
end

function registry.replaceState(from: State)
	table.clear(activeState :: any)
	for key, value in next, from :: any do
		(activeState :: any)[key] = value
	end
end

function registry.setYieldDriver(driver: YieldDriver?) yieldDriver = driver end
function registry.getYieldDriver(): YieldDriver? return yieldDriver end

function registry.setPostTestHook(hook: PostTestHook?) postTestHook = hook end
function registry.getPostTestHook(): PostTestHook? return postTestHook end

function registry.activeEnv(): any return activeEnvRef[1] end
function registry.setActiveEnv(env: any) activeEnvRef[1] = env end

function registry.beginEnvScope(): () -> ()
	local outer = activeEnvRef[1]
	activeEnvRef[1] = nil
	return function() activeEnvRef[1] = outer end
end

--- Normalizes a spec file path while preserving relative subdirectories (`specs/server/Inventory`).
function registry.normalizeSpecFile(path: string): string
	local clean = string.gsub(string.gsub(path, "^[@=]", ""), "%.luau?$", "")
	clean = string.gsub(clean, "\\", "/")
	clean = string.gsub(clean, "^%./", "")
	clean = string.gsub(clean, "%.spec$", "")
	return clean
end

local function specFile(): string
	if activeState.file ~= nil then return registry.normalizeSpecFile(activeState.file) end
	for level = 2, 64 do
		local source = debug.info(level, "s")
		if source == nil then break end
		if not util.internal(source) then return registry.normalizeSpecFile(source) end
	end
	return "?"
end

local TEST_OPTIONS = { "file", "focus", "skip", "target", "timeout" }
local DESCRIBE_OPTIONS = { "file", "focus", "separator", "skip", "target" }
local VALID_TARGETS: { [string]: boolean } = { portable = true, roblox = true, server = true, client = true }
local SETUP_HOOKS = { "afterAll", "afterEach", "beforeAll", "beforeEach" }

registry.TEST_OPTIONS = TEST_OPTIONS
registry.DESCRIBE_OPTIONS = DESCRIBE_OPTIONS

local function label(apiName: string, name: any): string
	return if type(name) == "string" then `sert.{apiName}("{name}")` else `sert.{apiName}`
end

function registry.checkName(apiName: string, name: any)
	if type(name) ~= "string" then
		error(`sert.{apiName}: expected a name string, got {util.typeof(name)}`, util.outside())
	end
end

function registry.checkFn(apiName: string, name: any, fn: any, options: any, usage: string?)
	if type(fn) == "function" then return end
	if usage ~= nil and type(options) == "function" then
		error(`{label(apiName, name)}: pass the function before the options: sert.{apiName}{usage}`, util.outside())
	end
	error(`{label(apiName, name)}: expected a function, got {util.typeof(fn)}`, util.outside())
end

function registry.checkKeys(where: string, what: string, given: any, keys: { string })
	if given == nil then return end
	local at = util.outside()
	if type(given) ~= "table" then error(`{where}: expected a table of {what}s, got {util.typeof(given)}`, at) end
	local tbl: { [any]: any } = given
	for key in next, tbl do
		if table.find(keys, key) == nil then
			error(`{where}: unknown {what} {format.repr(key)} ({what}s: {table.concat(keys, ", ")})`, at)
		end
	end
end

local function checkTargetOption(where: string, target: any)
	if target ~= nil and (type(target) ~= "string" or not VALID_TARGETS[target]) then
		error(
			`{where}: invalid target {format.repr(target)} (expected portable, roblox, server, or client)`,
			util.outside()
		)
	end
end

local function qualify(name: string): string
	local scope = activeState.scopes[#activeState.scopes]
	return if scope == nil then name else scope.name .. scope.separator .. name
end

local NOOP_TEST: TestFn = function() end
local NOOP_DESCRIBE = function() end

local function fileKey(file: string, side: string?): string return if side ~= nil then `{side}/{file}` else file end

function registry.registerEntry(
	name: string,
	fn: TestFn,
	mode: Mode,
	explicitTarget: Target?,
	explicitFocus: boolean,
	options: TestOptions?,
	propInfo: PropAttachment?
): Test
	if activeState.running ~= nil then error("cannot register a new test inside a running test", util.outside()) end
	local effectiveMode: Mode = mode
	local focused = explicitFocus or (options ~= nil and options.focus == true)
	if options ~= nil and options.skip == true then effectiveMode = "skip" end

	local inheritedTarget: Target? = nil
	local scopeFile: string? = nil
	for _, scope in activeState.scopes do
		if scope.mode == "skip" then
			effectiveMode = "skip"
		elseif scope.mode == "focus" then
			focused = true
		end
		if scope.target ~= nil then inheritedTarget = scope.target end
		if scope.file ~= nil then scopeFile = scope.file end
	end

	local optTarget: Target? = if options ~= nil then options.target else nil
	local finalTarget: Target = explicitTarget or optTarget or inheritedTarget or "portable"
	if focused and effectiveMode ~= "skip" then activeState.focusing = true end

	local namedFile: string? = if options ~= nil and options.file ~= nil then options.file else scopeFile
	local file: string = if type(namedFile) == "string" then registry.normalizeSpecFile(namedFile) else specFile()
	maybeInstallCallerGlobals()
	activeState.testFiles[fileKey(file, activeState.side)] = true

	local entry: Test = {
		name = qualify(name),
		fn = fn,
		mode = effectiveMode,
		target = finalTarget,
		focused = focused,
		file = file,
		side = activeState.side,
		timeout = if options ~= nil then options.timeout else nil,
		prop = propInfo,
		scopes = table.clone(activeState.scopes),
	}
	if propInfo ~= nil then propInfo.name = entry.name end
	table.insert(activeState.tests, entry)
	return entry
end

function registry.qualifyName(name: string): string return qualify(name) end
function registry.inline(): boolean return activeState.running ~= nil end
function registry.currentRun(): Current? return activeState.running end
function registry.currentOptions(): RunOptions? return activeState.options end

function registry.recordInlineSeed(key: string, seed: number)
	local seeds = activeState.inlineSeeds
	if seeds ~= nil then seeds[key] = seed end
end

--- Formats a parameterized `each` or `eachTuple` title without guessing whether array elements unpack.
function registry.formatEachTitle(fmt: any, rawCase: any, isTuple: boolean, tupleCount: number, index: number): string
	if type(fmt) == "function" then
		local ok, custom = pcall(fmt, rawCase, index)
		if not ok then error(`each format callback raised: {format.errorText(custom)}`, util.outside()) end
		return tostring(custom)
	end
	if type(fmt) ~= "string" then
		error(`each: expected format string or function, got {util.typeof(fmt)}`, util.outside())
	end
	if string.find(fmt, "%%[^%%]") ~= nil then
		local fmtArgs: { any } = {}
		if isTuple and type(rawCase) == "table" then
			for i = 1, tupleCount do
				local v = rawCase[i]
				fmtArgs[i] = if type(v) == "string" or type(v) == "number" then v else format.repr(v)
			end
		else
			fmtArgs[1] = if type(rawCase) == "string" or type(rawCase) == "number"
				then rawCase
				else format.repr(rawCase)
			fmtArgs[2] = index
		end
		local ok, formatted = pcall(string.format, fmt, table.unpack(fmtArgs, 1, #fmtArgs))
		if ok and type(formatted) == "string" then return formatted end
	end
	if not isTuple and type(rawCase) == "table" then
		local named = rawget(rawCase, "name")
		if named ~= nil then return `{fmt} · {tostring(named)}` end
	end
	return `{fmt} [{index}]`
end

local function buildTestNamespace(
	apiPrefix: string,
	target: Target?,
	fixedMode: Mode?,
	fixedFocus: boolean
): TargetTestApi
	local function callTest(name: string, fn: TestFn?, options: TestOptions?)
		registry.checkName(apiPrefix, name)
		if fixedMode == "skip" and fn == nil then
			registry.checkKeys(label(apiPrefix, name), "option", options, TEST_OPTIONS)
			if options ~= nil then checkTargetOption(label(apiPrefix, name), options.target) end
			registry.registerEntry(name, NOOP_TEST, "skip", target, fixedFocus, options, nil)
			return
		end
		registry.checkFn(apiPrefix, name, fn, options, "(name, fn, opts?)")
		registry.checkKeys(label(apiPrefix, name), "option", options, TEST_OPTIONS)
		if options ~= nil then checkTargetOption(label(apiPrefix, name), options.target) end
		registry.registerEntry(name, fn :: TestFn, fixedMode or "run", target, fixedFocus, options, nil)
	end

	local function eachFn<T>(cases: { T })
		if type(cases) ~= "table" then
			error(`sert.{apiPrefix}.each: expected a table of cases, got {util.typeof(cases)}`, util.outside())
		end
		return function(fmt: EachFormat<T>, fn: (case: T, ctx: TestContext) -> (), options: TestOptions?)
			if fixedMode ~= "skip" or fn ~= nil then
				registry.checkFn(`{apiPrefix}.each`, fmt, fn, options, "(cases)(fmt, fn, opts?)")
			end
			registry.checkKeys(`sert.{apiPrefix}.each`, "option", options, TEST_OPTIONS)
			if options ~= nil then checkTargetOption(`sert.{apiPrefix}.each`, options.target) end
			for index = 1, #cases do
				local item = cases[index]
				local title = registry.formatEachTitle(fmt, item, false, 1, index)
				local body: TestFn = if fn == nil then NOOP_TEST else function(ctx: TestContext) fn(item, ctx) end
				registry.registerEntry(title, body, fixedMode or "run", target, fixedFocus, options, nil)
			end
		end
	end

	local function eachTupleFn(tuples: { { any } })
		if type(tuples) ~= "table" then
			error(
				`sert.{apiPrefix}.eachTuple: expected a table of tuple rows, got {util.typeof(tuples)}`,
				util.outside()
			)
		end
		return function(fmt: EachFormat<{ any }>, fn: (...any) -> (), options: TestOptions?)
			if fixedMode ~= "skip" or fn ~= nil then
				registry.checkFn(`{apiPrefix}.eachTuple`, fmt, fn, options, "(tuples)(fmt, fn, opts?)")
			end
			registry.checkKeys(`sert.{apiPrefix}.eachTuple`, "option", options, TEST_OPTIONS)
			if options ~= nil then checkTargetOption(`sert.{apiPrefix}.eachTuple`, options.target) end
			for index = 1, #tuples do
				local row = tuples[index]
				if type(row) ~= "table" then
					error(
						`sert.{apiPrefix}.eachTuple: row {index} must be a table, got {util.typeof(row)}`,
						util.outside()
					)
				end
				local rowAny: { [any]: any } = row :: any
				local rowLen = if type(rawget(rowAny, "n")) == "number" then rawget(rowAny, "n") :: number else #row
				local title = registry.formatEachTitle(fmt, row, true, rowLen, index)
				local body: TestFn = if fn == nil
					then NOOP_TEST
					else function(ctx: TestContext)
						local unpacked = table.move(row, 1, rowLen, 1, {})
						unpacked[rowLen + 1] = ctx
						fn(table.unpack(unpacked, 1, rowLen + 1))
					end
				registry.registerEntry(title, body, fixedMode or "run", target, fixedFocus, options, nil)
			end
		end
	end

	local ns: { [string]: any } = {
		each = eachFn,
		eachTuple = eachTupleFn,
	}
	if fixedMode == nil and not fixedFocus then
		ns.skip = buildTestNamespace(`{apiPrefix}.skip`, target, "skip", false)
		ns.focus = buildTestNamespace(`{apiPrefix}.focus`, target, "run", true)
	else
		ns.skip = function(name: string, fn: TestFn?, options: TestOptions?)
			registry.checkName(`{apiPrefix}.skip`, name)
			if fn ~= nil then registry.checkFn(`{apiPrefix}.skip`, name, fn, options, "(name, fn?, opts?)") end
			registry.checkKeys(label(`{apiPrefix}.skip`, name), "option", options, TEST_OPTIONS)
			registry.registerEntry(name, fn or NOOP_TEST, "skip", target, false, options, nil)
		end
		ns.focus = function(name: string, fn: TestFn, options: TestOptions?)
			registry.checkName(`{apiPrefix}.focus`, name)
			registry.checkFn(`{apiPrefix}.focus`, name, fn, options, "(name, fn, opts?)")
			registry.checkKeys(label(`{apiPrefix}.focus`, name), "option", options, TEST_OPTIONS)
			registry.registerEntry(name, fn, "run", target, true, options, nil)
		end
	end

	return (
		setmetatable(ns, {
			__call = function(_self: any, name: string, fn: TestFn, options: TestOptions?) callTest(name, fn, options) end,
		}) :: any
	) :: TargetTestApi
end

local function openScope(
	prefix: string,
	fn: () -> (),
	options: DescribeOptions?,
	explicitMode: ("skip" | "focus")?,
	explicitTarget: Target?
)
	if activeState.running ~= nil then error("cannot open a describe block inside a running test", util.outside()) end
	maybeInstallCallerGlobals()
	local parent = activeState.scopes[#activeState.scopes]
	local separator = if options ~= nil and options.separator ~= nil
		then options.separator
		elseif parent ~= nil then parent.separator
		else " > "
	local scopeMode: ("skip" | "focus")? = explicitMode
	if scopeMode == nil and options ~= nil then
		if options.skip == true then
			scopeMode = "skip"
		elseif options.focus == true then
			scopeMode = "focus"
		end
	end
	local scopeTarget: Target? = explicitTarget or (if options ~= nil then options.target else nil)
	table.insert(activeState.scopes, {
		name = qualify(prefix),
		separator = separator,
		hooks = emptyHooks(),
		mode = scopeMode,
		target = scopeTarget,
		file = if options ~= nil then options.file else nil,
	})
	local depth = #activeState.scopes
	local ok, err = pcall(fn :: () -> ...any)
	for index = #activeState.scopes, depth, -1 do
		activeState.scopes[index] = nil
	end
	if not ok then error(err, 0) end
end

local function buildDescribeNamespace(
	apiPrefix: string,
	target: Target?,
	fixedMode: ("skip" | "focus")?
): TargetDescribeApi
	local function callDescribe(prefix: string, fn: (() -> ())?, options: DescribeOptions?)
		registry.checkName(apiPrefix, prefix)
		if fixedMode == "skip" and fn == nil then
			registry.checkKeys(label(apiPrefix, prefix), "option", options, DESCRIBE_OPTIONS)
			if options ~= nil then checkTargetOption(label(apiPrefix, prefix), options.target) end
			openScope(prefix, NOOP_DESCRIBE, options, "skip", target)
			return
		end
		registry.checkFn(apiPrefix, prefix, fn, options, "(prefix, fn, opts?)")
		registry.checkKeys(label(apiPrefix, prefix), "option", options, DESCRIBE_OPTIONS)
		if options ~= nil then checkTargetOption(label(apiPrefix, prefix), options.target) end
		openScope(prefix, fn :: () -> (), options, fixedMode, target)
	end

	local function eachFn<T>(cases: { T })
		if type(cases) ~= "table" then
			error(`sert.{apiPrefix}.each: expected a table of cases, got {util.typeof(cases)}`, util.outside())
		end
		return function(fmt: EachFormat<T>, fn: (case: T) -> (), options: DescribeOptions?)
			registry.checkFn(`{apiPrefix}.each`, fmt, fn, options, "(cases)(fmt, fn, opts?)")
			registry.checkKeys(`sert.{apiPrefix}.each`, "option", options, DESCRIBE_OPTIONS)
			if options ~= nil then checkTargetOption(`sert.{apiPrefix}.each`, options.target) end
			for index = 1, #cases do
				local item = cases[index]
				local title = registry.formatEachTitle(fmt, item, false, 1, index)
				openScope(title, function() fn(item) end, options, fixedMode, target)
			end
		end
	end

	local function eachTupleFn(tuples: { { any } })
		if type(tuples) ~= "table" then
			error(
				`sert.{apiPrefix}.eachTuple: expected a table of tuple rows, got {util.typeof(tuples)}`,
				util.outside()
			)
		end
		return function(fmt: EachFormat<{ any }>, fn: (...any) -> (), options: DescribeOptions?)
			registry.checkFn(`{apiPrefix}.eachTuple`, fmt, fn, options, "(tuples)(fmt, fn, opts?)")
			registry.checkKeys(`sert.{apiPrefix}.eachTuple`, "option", options, DESCRIBE_OPTIONS)
			if options ~= nil then checkTargetOption(`sert.{apiPrefix}.eachTuple`, options.target) end
			for index = 1, #tuples do
				local row = tuples[index]
				if type(row) ~= "table" then
					error(
						`sert.{apiPrefix}.eachTuple: row {index} must be a table, got {util.typeof(row)}`,
						util.outside()
					)
				end
				local rowAny: { [any]: any } = row :: any
				local rowLen = if type(rawget(rowAny, "n")) == "number" then rawget(rowAny, "n") :: number else #row
				local title = registry.formatEachTitle(fmt, row, true, rowLen, index)
				openScope(title, function() fn(table.unpack(row, 1, rowLen)) end, options, fixedMode, target)
			end
		end
	end

	local ns: { [string]: any } = {
		each = eachFn,
		eachTuple = eachTupleFn,
	}
	if fixedMode == nil then
		ns.skip = buildDescribeNamespace(`{apiPrefix}.skip`, target, "skip")
		ns.focus = buildDescribeNamespace(`{apiPrefix}.focus`, target, "focus")
	else
		ns.skip = function(prefix: string, fn: (() -> ())?, options: DescribeOptions?)
			registry.checkName(`{apiPrefix}.skip`, prefix)
			if fn ~= nil then registry.checkFn(`{apiPrefix}.skip`, prefix, fn, options, "(prefix, fn?, opts?)") end
			registry.checkKeys(label(`{apiPrefix}.skip`, prefix), "option", options, DESCRIBE_OPTIONS)
			openScope(prefix, fn or NOOP_DESCRIBE, options, "skip", target)
		end
		ns.focus = function(prefix: string, fn: () -> (), options: DescribeOptions?)
			registry.checkName(`{apiPrefix}.focus`, prefix)
			registry.checkFn(`{apiPrefix}.focus`, prefix, fn, options, "(prefix, fn, opts?)")
			registry.checkKeys(label(`{apiPrefix}.focus`, prefix), "option", options, DESCRIBE_OPTIONS)
			openScope(prefix, fn, options, "focus", target)
		end
	end

	return (
		setmetatable(ns, {
			__call = function(_self: any, prefix: string, fn: () -> (), options: DescribeOptions?)
				callDescribe(prefix, fn, options)
			end,
		}) :: any
	) :: TargetDescribeApi
end

local rootTest: any = buildTestNamespace("test", nil, nil, false)
rootTest.roblox = buildTestNamespace("test.roblox", "roblox", nil, false)
rootTest.server = buildTestNamespace("test.server", "server", nil, false)
rootTest.client = buildTestNamespace("test.client", "client", nil, false)

local rootDescribe: any = buildDescribeNamespace("describe", nil, nil)
rootDescribe.roblox = buildDescribeNamespace("describe.roblox", "roblox", nil)
rootDescribe.server = buildDescribeNamespace("describe.server", "server", nil)
rootDescribe.client = buildDescribeNamespace("describe.client", "client", nil)

local api = {
	test = rootTest :: TestApi,
	describe = rootDescribe :: DescribeApi,
}

local function hooksFor(file: string): Hooks
	maybeInstallCallerGlobals()
	local scope = activeState.scopes[#activeState.scopes]
	if scope ~= nil then
		return scope.hooks
	elseif file == "?" then
		return activeState.globalHooks
	end
	local key = fileKey(file, activeState.side)
	local hooks = activeState.fileHooks[key]
	if hooks == nil then
		hooks = emptyHooks()
		activeState.fileHooks[key] = hooks
		table.insert(activeState.fileOrder, key)
	end
	return hooks
end

function api.beforeAll(fn: HookFn)
	registry.checkFn("beforeAll", nil, fn, nil)
	table.insert(hooksFor(specFile()).beforeAll, fn)
end

function api.afterAll(fn: HookFn)
	registry.checkFn("afterAll", nil, fn, nil)
	table.insert(hooksFor(specFile()).afterAll, fn)
end

function api.beforeEach(fn: HookFn)
	registry.checkFn("beforeEach", nil, fn, nil)
	table.insert(hooksFor(specFile()).before, fn)
end

function api.afterEach(fn: HookFn)
	registry.checkFn("afterEach", nil, fn, nil)
	table.insert(hooksFor(specFile()).after, fn)
end

function api.setup(hooks: Setup)
	maybeInstallCallerGlobals()
	if type(hooks) ~= "table" then
		error(`sert.setup: expected a table of hooks, got {util.typeof(hooks)}`, util.outside())
	end
	for key, hook in next, hooks :: { [any]: any } do
		if table.find(SETUP_HOOKS, key) == nil then
			error(
				`sert.setup: unknown hook {format.repr(key)} (hooks: {table.concat(SETUP_HOOKS, ", ")})`,
				util.outside()
			)
		elseif type(hook) ~= "function" then
			error(`sert.setup: {key} must be a function, got {util.typeof(hook)}`, util.outside())
		end
	end
	activeState.globalHooks = {
		beforeAll = if hooks.beforeAll then { hooks.beforeAll } else {},
		afterAll = if hooks.afterAll then { hooks.afterAll } else {},
		before = if hooks.beforeEach then { hooks.beforeEach } else {},
		after = if hooks.afterEach then { hooks.afterEach } else {},
	}
	local kept = {}
	for _, file in activeState.fileOrder do
		if activeState.testFiles[file] then
			table.insert(kept, file)
		else
			activeState.fileHooks[file] = nil
		end
	end
	activeState.fileOrder = kept
end

function registry.globalChain(): { Hooks }
	local chain = { activeState.globalHooks }
	for _, file in activeState.fileOrder do
		if not activeState.testFiles[file] then table.insert(chain, activeState.fileHooks[file]) end
	end
	return chain
end

function registry.chainOf(test: Test, globals: { Hooks }): { Hooks }
	local chain = table.clone(globals)
	local key = fileKey(test.file, test.side)
	local own = activeState.fileHooks[key]
	if own ~= nil and activeState.testFiles[key] then table.insert(chain, own) end
	for _, scope in test.scopes do
		table.insert(chain, scope.hooks)
	end
	return chain
end

--- Queues `fn` to run in LIFO order when the active test or `beforeAll`/`afterAll` scope exits.
function api.defer(fn: HookFn)
	registry.checkFn("defer", nil, fn, nil)
	table.insert(activeState.deferred or activeState.loaded, fn)
end

--- Registers automatic LIFO spy/stub cleanup bound to the currently active hook/test scope.
function registry.autoRestore(restoreFn: HookFn) table.insert(activeState.deferred or activeState.loaded, restoreFn) end

registry.api = api

return registry
