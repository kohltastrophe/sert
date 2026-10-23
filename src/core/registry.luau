--!strict
-- Test registry (`core/registry`): registration API, describe blocks, hooks, spies, output sinks, and mutation support.

local format = require("../format")
local gen = require("../gen")
local model = require("../model")
local prop = require("../prop")
local sourceInfo = require("../util")

local mutant = prop.mutant

export type RunOptions = prop.RunOptions
export type Shard = prop.Shard
export type TestOptions = {
	timeout: number?,
	skip: boolean?,
	focus: boolean?,
	file: string?,
}
export type PropOptions = prop.PropOptions
export type PropFn = prop.PropFn
export type PropResult = prop.PropResult
export type TestFn = () -> ()
export type Mode = "test" | "rtest" | "skip" | "todo"
export type Prop = { name: string, options: PropOptions, fn: PropFn }
export type Hooks = { beforeAll: { TestFn }, afterAll: { TestFn }, before: { TestFn }, after: { TestFn } }
export type Scope = { name: string, separator: string, hooks: Hooks, mode: ("skip" | "focus")?, file: string? }
export type Test = {
	name: string,
	fn: TestFn,
	mode: Mode,
	focused: boolean,
	file: string,
	side: string?,
	timeout: number?,
	prop: Prop?,
	scopes: { Scope },
}
export type Current = { name: string, file: string, last: boolean }
export type Setup = { beforeAll: TestFn?, afterAll: TestFn?, beforeEach: TestFn?, afterEach: TestFn? }
export type EachOptions<T> = TestOptions & { format: ((name: string, case: T, index: number) -> string)? }
export type DescribeOptions = { separator: string?, file: string? }
export type DescribeFn = (prefix: string, fn: () -> (), options: DescribeOptions?) -> ()
export type Describe = DescribeFn & { skip: DescribeFn, focus: DescribeFn }
export type PropRegister = (name: string, fn: PropFn, options: PropOptions?) -> ()
export type PropApi = PropRegister & {
	run: (name: string, fn: PropFn, options: PropOptions?, runOptions: RunOptions?) -> PropResult,
}
export type ModelRegister = (nameOrSpec: string | model.Spec, specOrOptions: any?, maybeOptions: model.Options?) -> ()
export type ModelApi = ModelRegister & { replay: typeof(model.replay), property: typeof(model.property) }

export type Call = { n: number, [number]: any }
export type Spy = ((...any) -> ...any) & {
	calls: { Call },
	results: { { ok: boolean, n: number, [number]: any } },
	callCount: number,
	lastCall: Call?,
	reset: (self: Spy) -> Spy,
	mockImplementation: (self: Spy, fn: ((...any) -> ...any)?) -> Spy,
	mockImplementationOnce: (self: Spy, fn: (...any) -> ...any) -> Spy,
	mockReturnValue: (self: Spy, ...any) -> Spy,
	mockReturnValueOnce: (self: Spy, ...any) -> Spy,
	restore: (self: Spy) -> (),
}

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
	deferred: { TestFn }?,
	loaded: { TestFn },
	options: RunOptions?,
	inlineSeeds: { [string]: number }?,
}

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
	local parts = table.create(select("#", ...))
	for index = 1, select("#", ...) do
		parts[index] = tostring((select(index, ...)))
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

local state: State = freshState()
local registry = {
	output = output,
	mutant = mutant,
	state = state,
	isolateDepth = 0,
}

function registry.normalizeSpecFile(path: string): string
	local base = string.gsub(string.gsub(path, "^[@=]", ""), "%.luau?$", "")
	base = string.match(base, "[^/\\]+$") or base
	base = string.gsub(base, "%.spec$", "")
	return string.match(base, "[^%.]+$") or base
end

local function specFile(): string
	if state.file ~= nil then return registry.normalizeSpecFile(state.file) end
	for level = 2, 64 do
		local source = debug.info(level, "s")
		if source == nil then break end
		if not sourceInfo.internal(source) then return registry.normalizeSpecFile(source) end
	end
	return "?"
end

local TEST_OPTIONS = { "file", "focus", "skip", "timeout" }
local PROP_OPTIONS =
	{ "exhaustive", "file", "focus", "regressions", "rtest", "runs", "seed", "shrinkBudget", "size", "skip", "timeout" }
registry.TEST_OPTIONS = TEST_OPTIONS
registry.PROP_OPTIONS = PROP_OPTIONS
local EACH_OPTIONS = { "file", "focus", "format", "skip", "timeout" }
local MODEL_OPTIONS = table.clone(PROP_OPTIONS)
table.move({ "length", "maxRedraws", "redraw" }, 1, 3, #MODEL_OPTIONS + 1, MODEL_OPTIONS)
table.sort(MODEL_OPTIONS)
local DESCRIBE_OPTIONS = { "file", "separator" }
local SETUP_HOOKS = { "afterAll", "afterEach", "beforeAll", "beforeEach" }

local function label(api: string, name: any): string
	return if type(name) == "string" then `sert.{api}("{name}")` else `sert.{api}`
end

local function checkName(api: string, name: any)
	if type(name) ~= "string" then
		error(`sert.{api}: expected a name string, got {typeof(name)}`, sourceInfo.outside())
	end
end

local function checkFn(api: string, name: any, fn: any, options: any, usage: string?, todo: boolean?)
	if type(fn) == "function" then return end
	if usage ~= nil and type(options) == "function" then
		error(`{label(api, name)}: pass the function before the options: sert.{api}{usage}`, sourceInfo.outside())
	end
	local hint = if todo and fn == nil then " (sert.todo registers a placeholder)" else ""
	error(`{label(api, name)}: expected a function, got {typeof(fn)}{hint}`, sourceInfo.outside())
end

function registry.checkKeys(where: string, what: string, given: any, keys: { string }, _level: number?)
	if given == nil then return end
	local at = sourceInfo.outside()
	if type(given) ~= "table" then error(`{where}: expected a table of {what}s, got {typeof(given)}`, at) end
	for key in given do
		if table.find(keys, key) == nil then
			error(`{where}: unknown {what} {format.repr(key)} ({what}s: {table.concat(keys, ", ")})`, at)
		end
	end
end

local function checkOptions(api: string, name: any, options: any, keys: { string })
	registry.checkKeys(label(api, name), "option", options, keys, 4)
end

local function qualify(name: string): string
	local scope = state.scopes[#state.scopes]
	return if scope == nil then name else scope.name .. scope.separator .. name
end

local NOOP_TEST: TestFn = function() end
registry.onRegister = nil :: ((fn: any?) -> ())?

local function fileKey(file: string, side: string?): string return if side ~= nil then `{side}/{file}` else file end

local function register(name: string, fn: TestFn, mode: Mode, options: TestOptions?)
	if registry.onRegister ~= nil then registry.onRegister(fn) end
	if state.running ~= nil then error("cannot register a new test inside a running test", sourceInfo.outside()) end
	local effective: Mode = mode
	local focused = options ~= nil and options.focus == true
	if mode ~= "todo" and options ~= nil and options.skip == true then effective = "skip" end
	for _, scope in state.scopes do
		if scope.mode == "skip" and effective ~= "todo" then
			effective = "skip"
		elseif scope.mode == "focus" then
			focused = true
		end
	end
	if focused and effective ~= "skip" and effective ~= "todo" then state.focusing = true end
	local named: string? = if options ~= nil then options.file else nil
	if named == nil then
		for _, scope in state.scopes do
			named = scope.file or named
		end
	end
	local file: string = if type(named) == "string" then registry.normalizeSpecFile(named) else specFile()
	state.testFiles[fileKey(file, state.side)] = true
	table.insert(state.tests, {
		name = qualify(name),
		fn = fn,
		mode = effective,
		focused = focused,
		file = file,
		side = state.side,
		timeout = if options then options.timeout else nil,
		prop = nil,
		scopes = table.clone(state.scopes),
	})
end

local function registerProp(name: string, fn: PropFn, options: PropOptions?)
	if registry.onRegister ~= nil then registry.onRegister(fn) end
	local opts: PropOptions = options or {}
	register(name, NOOP_TEST, if opts.rtest then "rtest" else "test", opts)
	local test = state.tests[#state.tests]
	test.prop = { name = test.name, options = opts, fn = fn }
end

local function runInline(name: string, fn: PropFn, options: PropOptions?)
	local running = state.running :: Current
	local key = `{running.name} > {name}`
	local active = state.options
	local runOptions: any = if active ~= nil then table.clone(active) else {}
	if runOptions.replay == nil and runOptions.seeds ~= nil then runOptions.replay = runOptions.seeds[key] end
	local result = prop.run(key, fn, options, runOptions, registry.isolateDepth == 0, running.name)
	if not result.ok then
		local seeds = state.inlineSeeds
		if seeds ~= nil and result.seed ~= nil then seeds[key] = result.seed end
		error(result.report or result.message or "property failed", 0)
	end
end

function registry.define(kind: "test" | "prop", name: string, fn: any, options: any?)
	if state.running ~= nil then
		if options ~= nil and (options.skip == true or (options.rtest == true and (game :: any) == nil)) then return end
		if kind == "prop" then
			runInline(name, fn, options)
		else
			fn()
		end
	elseif kind == "prop" then
		registerProp(name, fn, options)
	else
		register(name, fn, if options and options.rtest then "rtest" else "test", options)
	end
end

function registry.inline(): boolean return state.running ~= nil end

local api = {}

local function registerTest(apiName: string, mode: Mode, name: string, fn: TestFn, options: TestOptions?)
	checkName(apiName, name)
	checkFn(apiName, name, fn, options, "(name, fn, opts?)", true)
	checkOptions(apiName, name, options, TEST_OPTIONS)
	register(name, fn, mode, options)
end

function api.test(name: string, fn: TestFn, options: TestOptions?) registerTest("test", "test", name, fn, options) end

function api.rtest(name: string, fn: TestFn, options: TestOptions?) registerTest("rtest", "rtest", name, fn, options) end

function api.focus(name: string, fn: TestFn, options: TestOptions?)
	checkName("focus", name)
	checkFn("focus", name, fn, options, "(name, fn, opts?)", true)
	checkOptions("focus", name, options, TEST_OPTIONS)
	local opts: TestOptions = if options then table.clone(options) else {}
	opts.focus = true
	register(name, fn, "test", opts)
end

function api.skip(name: string, fn: TestFn?, options: TestOptions?)
	checkName("skip", name)
	if fn ~= nil then checkFn("skip", name, fn, options, "(name, fn?, opts?)") end
	checkOptions("skip", name, options, TEST_OPTIONS)
	register(name, fn or NOOP_TEST, "skip", options)
end

function api.todo(name: string, ...: never)
	checkName("todo", name)
	if select("#", ...) > 0 then error(`sert.todo("{name}"): takes only a name; use sert.test to run a body`, 2) end
	register(name, NOOP_TEST, "todo", nil)
end

function api.each<T>(name: string, cases: { T }, fn: (T, number) -> (), options: EachOptions<T>?)
	checkName("each", name)
	if type(cases) ~= "table" then error(`sert.each("{name}"): expected a list of cases, got {typeof(cases)}`, 2) end
	checkFn("each", name, fn, options, "(name, cases, fn, opts?)")
	checkOptions("each", name, options, EACH_OPTIONS)
	local formatName = if options then options.format else nil
	for index, case in cases do
		local caseName = if type(case) == "table" then rawget(case :: any, "name") else nil
		local caseLabel = if caseName ~= nil then tostring(caseName) else tostring(index)
		local testName = if formatName then formatName(name, case, index) else `{name} · {caseLabel}`
		register(testName, function() fn(case, index) end, "test", options)
	end
end

api.prop = (
	setmetatable({
		run = function(name: string, fn: PropFn, options: PropOptions?, runOptions: RunOptions?): PropResult
			return prop.run(name, fn, options, runOptions)
		end,
	}, {
		__call = function(_: any, name: string, fn: PropFn, options: PropOptions?)
			checkName("prop", name)
			checkFn("prop", name, fn, options, "(name, fn, opts?)")
			checkOptions("prop", name, options, PROP_OPTIONS)
			registry.define("prop", name, fn, options)
		end,
	}) :: any
) :: PropApi

function api.check(
	name: string,
	gens: gen.Generator<any> | { gen.Generator<any> },
	fn: (...any) -> (),
	options: PropOptions?
)
	checkName("check", name)
	if type(fn :: any) == "table" and type(gens) == "function" then
		error(`sert.check("{name}"): pass the generators before the function: sert.check(name, gens, fn, opts?)`, 2)
	end
	local list: { gen.Generator<any> } = if type(gens) == "function" then { gens } else gens :: { gen.Generator<any> }
	if type(list) ~= "table" or #list == 0 then
		local got = if type(gens) == "table" then "an empty list" else typeof(gens)
		error(`sert.check("{name}"): expected a generator or a list of them, got {got}`, 2)
	end
	for index, each in list do
		if type(each) ~= "function" then
			error(`sert.check("{name}"): generator {index} is a {typeof(each)}, not a generator`, 2)
		end
	end
	checkFn("check", name, fn, options, "(name, gens, fn, opts?)")
	checkOptions("check", name, options, PROP_OPTIONS)
	registry.define("prop", name, function(g: prop.Gen)
		local values = table.create(#list)
		for index, each in list do
			values[index] = each(g)
		end
		g:note(function()
			local shown = table.create(#list)
			for index = 1, #list do
				shown[index] = format.repr(values[index])
			end
			return `args: ({table.concat(shown, ", ")})`
		end)
		fn(table.unpack(values, 1, #list))
	end, options)
end

api.model = (
	setmetatable({ replay = model.replay, property = model.property }, {
		__call = function(_: any, nameOrSpec: string | model.Spec, specOrOptions: any?, maybeOptions: model.Options?)
			local isTable = type(nameOrSpec) == "table"
			local spec: any = if isTable then nameOrSpec else specOrOptions
			local opts: model.Options? = if isTable then specOrOptions else maybeOptions
			if type(spec) == "table" and type(spec.def) == "table" and type(spec.check) == "function" then
				spec = spec.def
			end
			local name: string = if isTable
				then (spec.name or (nameOrSpec :: any).name or "model")
				else nameOrSpec :: string
			checkName("model", name)
			if type(spec) ~= "table" then
				error(`sert.model("{name}"): expected a spec table, got {typeof(spec)}`, 2)
			end
			checkOptions("model", name, opts, MODEL_OPTIONS)
			registry.define("prop", name, model.property(spec, opts), model.propOptions(opts))
		end,
	}) :: any
) :: ModelApi

local function openScope(prefix: string, fn: () -> (), options: DescribeOptions?, mode: ("skip" | "focus")?)
	if registry.onRegister ~= nil then registry.onRegister(fn) end
	local parent = state.scopes[#state.scopes]
	local separator = if options and options.separator
		then options.separator
		elseif parent then parent.separator
		else " > "
	table.insert(state.scopes, {
		name = qualify(prefix),
		separator = separator,
		hooks = emptyHooks(),
		mode = mode,
		file = if options then options.file else nil,
	})
	local depth = #state.scopes
	local ok, err = pcall(fn :: () -> ...any)
	for index = #state.scopes, depth, -1 do
		state.scopes[index] = nil
	end
	if not ok then error(err, 0) end
end

local function describeWith(
	apiName: string,
	mode: ("skip" | "focus")?,
	prefix: string,
	fn: () -> (),
	options: DescribeOptions?
)
	checkName(apiName, prefix)
	checkFn(apiName, prefix, fn, options, "(prefix, fn, opts?)")
	checkOptions(apiName, prefix, options, DESCRIBE_OPTIONS)
	openScope(prefix, fn, options, mode)
end

api.describe = (
	setmetatable({
		skip = function(prefix: string, fn: () -> (), options: DescribeOptions?)
			describeWith("describe.skip", "skip", prefix, fn, options)
		end,
		focus = function(prefix: string, fn: () -> (), options: DescribeOptions?)
			describeWith("describe.focus", "focus", prefix, fn, options)
		end,
	}, {
		__call = function(_: any, prefix: string, fn: () -> (), options: DescribeOptions?)
			describeWith("describe", nil, prefix, fn, options)
		end,
	}) :: any
) :: Describe

local function hooksFor(file: string): Hooks
	local scope = state.scopes[#state.scopes]
	if scope ~= nil then
		return scope.hooks
	elseif file == "?" then
		return state.globalHooks
	end
	local key = fileKey(file, state.side)
	local hooks = state.fileHooks[key]
	if hooks == nil then
		hooks = emptyHooks()
		state.fileHooks[key] = hooks
		table.insert(state.fileOrder, key)
	end
	return hooks
end

function api.beforeAll(fn: TestFn)
	checkFn("beforeAll", nil, fn, nil)
	table.insert(hooksFor(specFile()).beforeAll, fn)
end
function api.afterAll(fn: TestFn)
	checkFn("afterAll", nil, fn, nil)
	table.insert(hooksFor(specFile()).afterAll, fn)
end
function api.beforeEach(fn: TestFn)
	checkFn("beforeEach", nil, fn, nil)
	table.insert(hooksFor(specFile()).before, fn)
end
function api.afterEach(fn: TestFn)
	checkFn("afterEach", nil, fn, nil)
	table.insert(hooksFor(specFile()).after, fn)
end

function api.setup(hooks: Setup)
	if type(hooks) ~= "table" then error(`sert.setup: expected a table of hooks, got {typeof(hooks)}`, 2) end
	for key, hook in hooks :: { [any]: any } do
		if table.find(SETUP_HOOKS, key) == nil then
			error(`sert.setup: unknown hook {format.repr(key)} (hooks: {table.concat(SETUP_HOOKS, ", ")})`, 2)
		elseif type(hook) ~= "function" then
			error(`sert.setup: {key} must be a function, got {typeof(hook)}`, 2)
		end
	end
	state.globalHooks = {
		beforeAll = if hooks.beforeAll then { hooks.beforeAll } else {},
		afterAll = if hooks.afterAll then { hooks.afterAll } else {},
		before = if hooks.beforeEach then { hooks.beforeEach } else {},
		after = if hooks.afterEach then { hooks.afterEach } else {},
	}
	local kept = {}
	for _, file in state.fileOrder do
		if state.testFiles[file] then
			table.insert(kept, file)
		else
			state.fileHooks[file] = nil
		end
	end
	state.fileOrder = kept
end

function registry.globalChain(): { Hooks }
	local chain = { state.globalHooks }
	for _, file in state.fileOrder do
		if not state.testFiles[file] then table.insert(chain, state.fileHooks[file]) end
	end
	return chain
end

function registry.chainOf(test: Test, globals: { Hooks }): { Hooks }
	local chain = table.clone(globals)
	local key = fileKey(test.file, test.side)
	local own = state.fileHooks[key]
	if own ~= nil and state.testFiles[key] then table.insert(chain, own) end
	for _, scope in test.scopes do
		table.insert(chain, scope.hooks)
	end
	return chain
end

function api.loaded<T>(result: T): T
	if type(result) == "string" and string.match(result, "^.-:%d+: ") ~= nil then
		error(`failed to load a spec: {result}`, 2)
	end
	return result
end

function api.current(): Current? return if state.running then table.clone(state.running) else nil end

function api.defer(fn: TestFn)
	checkFn("defer", nil, fn, nil)
	table.insert(state.deferred or state.loaded, fn)
end

function registry.replaceState(from: State)
	table.clear(state :: any)
	for key, value in from :: any do
		(state :: any)[key] = value
	end
end

function api.isolate(fn: () -> ...any): (boolean, ...any)
	local savedMutant = mutant.get()
	local nested = state.running ~= nil
	if nested then
		registry.isolateDepth += 1
	end
	local saved = table.clone(state)
	registry.replaceState(freshState())
	local results = table.pack(pcall(fn))
	local leftover = state.loaded
	registry.replaceState(saved)
	table.move(leftover, 1, #leftover, #(state.deferred or state.loaded) + 1, state.deferred or state.loaded)
	if nested then
		registry.isolateDepth -= 1
	end
	mutant.set(savedMutant)
	return table.unpack(results, 1, results.n)
end

local restorers: { [any]: () -> () } = setmetatable({}, { __mode = "k" }) :: any
local spy = {}

local function returning(...: any): (...any) -> ...any
	local packed = table.pack(...)
	return function() return table.unpack(packed, 1, packed.n) end
end

function spy.fn(impl: ((...any) -> ...any)?): Spy
	local currentImpl = impl
	local once: { (...any) -> ...any } = {}
	local spyTable: any = { calls = {}, results = {}, callCount = 0, lastCall = nil }
	function spyTable.reset(self: any): any
		table.clear(self.calls)
		table.clear(self.results)
		table.clear(once)
		self.callCount, self.lastCall = 0, nil
		return self
	end
	function spyTable.mockImplementation(self: any, fn: ((...any) -> ...any)?): any
		currentImpl = fn
		return self
	end
	function spyTable.mockImplementationOnce(self: any, fn: (...any) -> ...any): any
		table.insert(once, fn)
		return self
	end
	function spyTable.mockReturnValue(self: any, ...: any): any
		currentImpl = returning(...)
		return self
	end
	function spyTable.mockReturnValueOnce(self: any, ...: any): any
		table.insert(once, returning(...))
		return self
	end
	function spyTable.restore(self: any)
		self:reset()
		currentImpl = impl
		local restore = restorers[self]
		if restore ~= nil then restore() end
	end
	return setmetatable(spyTable, {
		__call = function(self: any, ...: any): ...any
			local args = table.pack(...)
			table.insert(self.calls, args)
			self.lastCall, self.callCount = args, self.callCount + 1
			local nextImpl = if #once > 0 then table.remove(once, 1) else currentImpl
			if nextImpl == nil then
				table.insert(self.results, { ok = true, n = 0 })
				return
			end
			local res = table.pack(pcall(nextImpl, ...))
			local ok = res[1]
			local record: { ok: boolean, n: number, [number]: any } = { ok = ok, n = res.n - 1 }
			for i = 2, res.n do
				record[i - 1] = res[i]
			end
			table.insert(self.results, record)
			if not ok then error(res[2], 0) end
			return table.unpack(res, 2, res.n)
		end,
	}) :: any
end

function spy.spy(target: { [any]: any }, key: any, impl: ((...any) -> ...any)?): Spy
	local original = target[key]
	local inherited = type(target) == "table" and original ~= nil and rawget(target, key) == nil
	local mt = if type(original) == "table" then getmetatable(original) else nil
	local callable = mt ~= nil and (type(mt) ~= "table" or rawget(mt, "__call") ~= nil)
	local delegate = if impl ~= nil
		then impl
		elseif type(original) == "function" then original
		elseif callable then function(...: any): ...any return (original :: any)(...) end
		else nil
	local s = spy.fn(delegate)
	local restored = false
	restorers[s] = function()
		if not restored then
			restored = true
			if inherited and rawequal(rawget(target, key), s) then
				rawset(target, key, nil)
			else
				target[key] = original
			end
		end
	end
	target[key] = s
	api.defer(function() s:restore() end)
	return s
end

function spy.isSpy(value: any): boolean
	return type(value) == "table"
		and type(rawget(value, "calls")) == "table"
		and type(rawget(value, "callCount")) == "number"
end

local activeEnvRef: { [number]: any } = setmetatable({}, { __mode = "v" }) :: any

function registry.activeEnv(): any return activeEnvRef[1] end

function registry.setActiveEnv(env: any) activeEnvRef[1] = env end

function registry.beginEnvScope(): () -> ()
	local outer = activeEnvRef[1]
	activeEnvRef[1] = nil
	return function() activeEnvRef[1] = outer end
end

registry.spy = spy
registry.api = api

return registry
