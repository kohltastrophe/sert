--!strict
-- Stateful command-sequence model testing (`sert.model`) built on `sert.prop`'s tape.

local format = require("../core/format")
local prop = require("../prop")
local registry = require("../core/registry")
local util = require("../core/util")

export type GenContext = prop.GenContext

export type Command<State = any, Sut = any, Arg = any, Res = any> = {
	name: string?,
	weight: number?,
	gen: (((state: State, g: GenContext) -> Arg) | ((g: any) -> Arg) | { Arg })?,
	args: ({ Arg } | ((state: State) -> { Arg }))?,
	pre: ((state: State, arg: Arg) -> boolean)?,
	run: ((sut: Sut, arg: Arg, world: any) -> ...any)?,
	next: ((state: State, arg: Arg, res: Res) -> ...any)?,
	post: ((state: State, sut: Sut, arg: Arg, res: Res, world: any) -> ...any)?,
}

export type Spec<State = any, Sut = any> = {
	name: string?,
	init: () -> State,
	setup: ((world: any) -> Sut)?,
	teardown: ((sut: Sut, world: any) -> ...any)?,
	commands: { [string]: Command<State, Sut, any, any> },
	invariants: { [string]: (state: State, sut: Sut, world: any) -> ...any }?,
	converge: (boolean | ((...any) -> ...any))?,
	project: ((...any) -> ...any)?,
	world: { [string]: any }?,
}

export type Options = typeof(table.freeze({} :: {
	length: number?,
	redraw: boolean?,
	maxRedraws: number?,
	world: { [string]: any }?,
	raise: boolean?,
	replay: (number | string)?,
	runs: number?,
	size: number?,
	seed: number?,
	regressions: { number }?,
	exhaustive: registry.ExhaustiveOption?,
	shrinkBudget: prop.ShrinkBudget?,
	timeout: number?,
	skip: boolean?,
	focus: boolean?,
	file: string?,
	target: registry.Target?,
	init: nil,
	commands: nil,
}))

export type Step = { [any]: any }

export type ModelCall = <S, T>(nameOrSpec: string | S, specOrOpts: T?, options: Options?) -> ()

export type ModelMeta = {
	__call: <S, T>(self: any, nameOrSpec: string | S, specOrOpts: T?, options: Options?) -> (),
}

export type TargetModelApi = typeof(setmetatable(
	{} :: {
		skip: ModelCall,
		focus: ModelCall,
	},
	{} :: ModelMeta
))

export type ModelPropApi = typeof(setmetatable(
	{} :: {
		skip: ModelCall,
		focus: ModelCall,
		roblox: TargetModelApi,
		server: TargetModelApi,
		client: TargetModelApi,
	},
	{} :: ModelMeta
))

export type ModelNamespace = typeof(setmetatable(
	{} :: {
		prop: ModelPropApi,
		property: <State, Sut>(spec: Spec<State, Sut>, options: Options?) -> (g: GenContext) -> (),
		check: <State, Sut>(spec: Spec<State, Sut>, options: Options?) -> prop.PropResult,
		replay: <State, Sut>(spec: Spec<State, Sut>, trace: { Step }, world: { [string]: any }?) -> (State, Sut),
		commandList: <State, Sut>(spec: Spec<State, Sut>, caller: string?) -> { Command<State, Sut, any, any> },
		checkInvariants: <State, Sut>(
			spec: Spec<State, Sut>,
			invKeys: { string },
			state: State,
			sut: Sut,
			world: any
		) -> (),
		stepSpec: <State, Sut>(
			spec: Spec<State, Sut>,
			invKeys: { string },
			command: Command<State, Sut, any, any>,
			sut: Sut,
			state: State,
			arg: any,
			index: number,
			world: any
		) -> (State, any),
		propOptions: (options: Options?) -> prop.PropOptions,
	},
	{} :: ModelMeta
))

local SPEC_FIELDS = {
	"commands",
	"converge",
	"init",
	"invariants",
	"name",
	"project",
	"setup",
	"teardown",
	"world",
}

local OPTION_KEYS = {
	"exhaustive",
	"file",
	"focus",
	"length",
	"maxRedraws",
	"raise",
	"redraw",
	"regressions",
	"replay",
	"runs",
	"seed",
	"shrinkBudget",
	"size",
	"skip",
	"target",
	"timeout",
	"world",
}

local COMMAND_FIELDS = {
	"args",
	"gen",
	"name",
	"next",
	"post",
	"pre",
	"run",
	"weight",
}

local sortedKeys = util.sortedKeys

local function validateSpec<State, Sut>(rawSpec: any, caller: string?, requireInit: boolean): Spec<State, Sut>
	local where = caller or "sert.model"
	if type(rawSpec) ~= "table" then
		error(`{where}: expected a spec table, got {util.typeof(rawSpec)}`, util.outside())
	end
	local rawTbl: { [any]: any } = rawSpec
	for key in next, rawTbl do
		if table.find(SPEC_FIELDS, key) == nil then
			local hint = if table.find(OPTION_KEYS, key) ~= nil then " (an option: pass it in options)" else ""
			error(`{where}: unknown spec field {tostring(key)}{hint}`, util.outside())
		end
	end
	if (requireInit or rawSpec.init ~= nil) and type(rawSpec.init) ~= "function" then
		error(`{where}: spec.init must be a function, got {util.typeof(rawSpec.init)}`, util.outside())
	end
	if rawSpec.setup ~= nil and type(rawSpec.setup) ~= "function" then
		error(`{where}: spec.setup must be a function, got {util.typeof(rawSpec.setup)}`, util.outside())
	end
	if rawSpec.teardown ~= nil and type(rawSpec.teardown) ~= "function" then
		error(`{where}: spec.teardown must be a function, got {util.typeof(rawSpec.teardown)}`, util.outside())
	end
	if rawSpec.invariants ~= nil and type(rawSpec.invariants) ~= "table" then
		error(`{where}: spec.invariants must be a table, got {util.typeof(rawSpec.invariants)}`, util.outside())
	end
	return rawSpec
end

local function normalizeCommand<State, Sut>(where: string, rawCmd: any, key: any, isArray: boolean): Command<State, Sut, any, any>
	if type(rawCmd) ~= "table" then
		error(`{where}: command {tostring(key)} must be a table, got {util.typeof(rawCmd)}`, util.outside())
	end
	if isArray and type(rawCmd.name) ~= "string" then
		error(`{where}: command {tostring(key)} has no name`, util.outside())
	end
	local cmdName: string = if isArray then rawCmd.name else key
	local rawCmdTbl: { [any]: any } = rawCmd
	for field in next, rawCmdTbl do
		if table.find(COMMAND_FIELDS, field) == nil then
			error(`{where}: command "{cmdName}" has unknown field {tostring(field)}`, util.outside())
		end
	end
	local command: Command<State, Sut, any, any> = table.clone(rawCmd)
	command.name = cmdName

	local rawGen: any = rawCmd.gen
	if type(rawGen) == "table" then
		local items = rawGen :: { any }
		if #items == 0 then error(`{where}: command "{cmdName}" gen array cannot be empty`, util.outside()) end
		command.gen = function(_state: State, g: GenContext): any return g:pick(items) end
	elseif type(rawGen) == "function" then
		if prop.isGenerator(rawGen) then
			local gFn = rawGen :: prop.Generator<any>
			command.gen = function(_state: State, g: GenContext): any return gFn(g) end
		else
			local stateGen = rawGen :: (State, GenContext) -> any
			command.gen = stateGen
		end
	elseif rawGen == nil and rawCmd.args ~= nil then
		local rawArgs = rawCmd.args
		if type(rawArgs) == "function" then
			local argsFn = rawArgs :: (State) -> { any }
			command.gen = function(state: State, g: GenContext): any
				local list = argsFn(state)
				return if #list > 0 then g:pick(list) else nil
			end
		elseif type(rawArgs) == "table" then
			local list = rawArgs :: { any }
			command.gen = function(_state: State, g: GenContext): any return if #list > 0 then g:pick(list) else nil end
		else
			error(`{where}: command "{cmdName}" args must be a table or function`, util.outside())
		end
	elseif rawGen ~= nil then
		error(`{where}: command "{cmdName}" gen must be a function or array, got {util.typeof(rawGen)}`, util.outside())
	end

	if command.run == nil and command.next == nil and command.post == nil then
		error(`{where}: command "{cmdName}" must define at least one of run, next, or post`, util.outside())
	end
	return command
end

local model: { [string]: any } = {}

--- Normalizes and sorts `spec.commands` by name so a seed produces identical sequences across Luau hash orders.
function model.commandList<State, Sut>(rawSpec: Spec<State, Sut>, caller: string?): { Command<State, Sut, any, any> }
	local where = caller or "sert.model"
	local spec: Spec<State, Sut> = validateSpec(rawSpec, where, false)
	local commands: any = spec.commands
	if type(commands) ~= "table" or next(commands) == nil then
		error(`{where}: spec must define non-empty commands`, util.outside())
	end
	if commands[1] ~= nil then
		local list: { Command<State, Sut, any, any> } = table.create(#commands) :: any
		for index = 1, #commands do
			list[index] = normalizeCommand(where, commands[index], index, true)
		end
		return list
	end
	local names: { string } = {}
	for name in next, commands do
		if type(name) ~= "string" then
			error(`{where}: command key must be a string, got {util.typeof(name)}`, util.outside())
		end
		table.insert(names, name)
	end
	table.sort(names)
	local list: { Command<State, Sut, any, any> } = table.create(#names) :: any
	for index, name in names do
		list[index] = normalizeCommand(where, commands[name], name, false)
	end
	return list
end

local function describeStep(name: string, arg: any): string
	return if arg == nil then name else `{name}({format.repr(arg)})`
end

--- Evaluates every invariant in `spec.invariants` in deterministic sorted key order.
function model.checkInvariants<State, Sut>(spec: Spec<State, Sut>, invKeys: { string }, state: State, sut: Sut, world: any?)
	local invs = spec.invariants
	if invs == nil then return end
	for _, key in invKeys do
		local ok, res = pcall(invs[key], state, sut, world)
		if not ok then
			error(`invariant.{key} failed: {format.errorText(res)}\nstate = {format.repr(state)}`, 0)
		elseif res == false then
			error(`invariant.{key} violated (returned false)\nstate = {format.repr(state)}`, 0)
		end
	end
end

--- Executes a single model command (`run` -> `next` -> `post` -> `invariants`) and returns `(nextState, result)`.
function model.stepSpec<State, Sut>(
	spec: Spec<State, Sut>,
	invKeys: { string },
	command: Command<State, Sut, any, any>,
	sut: Sut,
	state: State,
	arg: any,
	index: number,
	world: any?
): (State, any)
	local result: any = nil
	local nextState: State = state
	local ok, why = pcall(function()
		if command.run ~= nil then result = command.run(sut, arg, world) end
		if command.next ~= nil then
			local produced = command.next(nextState, arg, result)
			if produced ~= nil then nextState = produced end
		end
		if command.post ~= nil then command.post(nextState, sut, arg, result, world) end
		model.checkInvariants(spec, invKeys, nextState, sut, world)
	end)
	if not ok then error(`step {index} ({describeStep(command.name :: string, arg)}): {format.errorText(why)}`, 0) end
	return nextState, result
end

local function startSpec<State, Sut>(spec: Spec<State, Sut>, world: any?): (State, Sut)
	local state = spec.init()
	local sut: Sut = if spec.setup ~= nil then spec.setup(world) else state :: any
	return state, sut
end

local function finishSpec<State, Sut>(spec: Spec<State, Sut>, sut: Sut, world: any?, ok: boolean, err: any)
	local td = spec.teardown
	if td ~= nil then
		local tornDown, why = pcall(function() td(sut, world) end)
		if not tornDown then
			local tdMsg = `teardown: {format.errorText(why)}`
			if ok then
				error(tdMsg, 0)
			else
				error(`{format.errorText(err)}\n{tdMsg}`, 0)
			end
		end
	end
	if not ok then error(err, 0) end
end

--- Strips model-only keys (`length`, `redraw`, `maxRedraws`, `world`, `raise`, `replay`) from `options` to produce `PropOptions`.
function model.propOptions(options: Options?): prop.PropOptions
	if options == nil then return {} end
	local out: any = table.clone(options)
	out.length = nil
	out.redraw = nil
	out.maxRedraws = nil
	out.world = nil
	out.raise = nil
	out.replay = nil
	return out
end

--- Builds the `(g: GenContext) -> ()` property function for `spec`, defaulting `redraw` to `true`.
function model.property<State, Sut>(rawSpec: Spec<State, Sut>, options: Options?): (g: GenContext) -> ()
	local spec: Spec<State, Sut> = validateSpec(rawSpec, "sert.model", true)
	local opts: Options = options or {}
	registry.checkKeys("sert.model", "option", options, OPTION_KEYS)
	local commands = model.commandList(spec, "sert.model")
	local invKeys = sortedKeys(spec.invariants)
	local length = opts.length or 30
	local redraw = opts.redraw ~= false
	local maxRedraws = opts.maxRedraws or 16
	local hostWorld = opts.world

	local weighted: { { any } } = {}
	local drawn: { [Command<State, Sut, any, any>]: number } = {}
	local live = 0
	for _, command in commands do
		local weight = command.weight or 1
		if weight > 0 then
			table.insert(weighted, { weight :: any, command })
			drawn[command] = live
			live += 1
		end
	end
	if live == 0 then error("sert.model: no command has a positive weight", util.outside()) end

	-- Hint accepted redraws back to a single direct draw so shrinking earlier steps does not shift command choices.
	local function choose(g: GenContext, state: State): (Command<State, Sut, any, any>?, any)
		local left = weighted
		local first = prop.mark(g)
		local redraws = 0
		local retriesPerCommand: { [Command<State, Sut, any, any>]: number } = {}
		while #left > 0 do
			local pick = prop.mark(g)
			local command = g:weighted(left) :: Command<State, Sut, any, any>
			local genFn = command.gen :: ((State, GenContext) -> any)?
			local arg = if genFn ~= nil then genFn(state, g) else nil
			if command.pre == nil or command.pre(state, arg) then
				if pick > first then prop.hint(g, first, pick, { drawn[command] }) end
				return command, arg
			elseif not redraw or redraws >= maxRedraws then
				return nil, nil
			end
			redraws += 1
			local tried = (retriesPerCommand[command] or 0) + 1
			retriesPerCommand[command] = tried
			-- Commands without `gen` are deterministic on `state`, so remove immediately; commands with `gen` get 2 tries before pruning.
			if genFn == nil or tried >= 2 then
				local others = {}
				for _, entry in left do
					if entry[2] ~= command then table.insert(others, entry) end
				end
				left = others
			end
		end
		return nil, nil
	end

	return function(g: GenContext)
		local state, sut = startSpec(spec, hostWorld)
		local ok, err = pcall(function()
			model.checkInvariants(spec, invKeys, state, sut, hostWorld)
			local executed = 0
			local refused = false
			g:list(function(stepGen: GenContext)
				local command, arg = choose(stepGen, state)
				if command == nil then
					refused = true
					return false
				end
				executed += 1
				local cmdName = command.name :: string
				stepGen:note(function() return string.format("{ %q, %s },", cmdName, format.repr(arg)) end)
				state = model.stepSpec(spec, invKeys, command, sut, state, arg, executed, hostWorld)
				return true
			end, 0, length)
			if executed == 0 and refused then prop.vacuous(g, "pre refused every step") end
		end)
		finishSpec(spec, sut, hostWorld, ok, err)
	end
end

--- Runs `spec` immediately via `prop.run`, raising on failure unless `options.raise == false`.
function model.check<State, Sut>(rawSpec: Spec<State, Sut>, options: Options?): prop.PropResult
	local spec: Spec<State, Sut> = validateSpec(rawSpec, "sert.model.check", true)
	local propFn = model.property(spec, options)
	local propOpts = model.propOptions(options)
	local runOpts: registry.RunOptions? = registry.currentOptions()
	if options ~= nil and options.replay ~= nil then
		local cloned: registry.RunOptions = if runOpts ~= nil then table.clone(runOpts) else {}
		cloned.replay = options.replay
		runOpts = cloned
	end
	local name = spec.name or "model"
	local result = prop.run(name, propFn, propOpts, runOpts, false, name)
	if not result.ok and (options == nil or options.raise ~= false) then
		error(result.report or result.message or "model check failed", util.outside())
	end
	return result
end

--- Replays an explicit `{ { name, arg }, ... }` or `{ { command = name, arg = arg }, ... }` trace against `spec` and returns `(state, sut)`.
function model.replay<State, Sut>(rawSpec: Spec<State, Sut>, trace: { Step }, world: any?): (State, Sut)
	local spec: Spec<State, Sut> = validateSpec(rawSpec, "sert.model.replay", true)
	if type(trace) ~= "table" then
		error(`sert.model.replay: expected a trace table, got {util.typeof(trace)}`, util.outside())
	end
	local commands: { [string]: Command<State, Sut, any, any> } = {}
	for _, command in model.commandList(spec, "sert.model.replay") do
		commands[command.name :: string] = command
	end
	local invKeys = sortedKeys(spec.invariants)
	local state, sut = startSpec(spec, world)
	local ok, err = pcall(function()
		model.checkInvariants(spec, invKeys, state, sut, world)
		for index, step in trace do
			if type(step) ~= "table" then error(`step {index}: expected a step table, got {util.typeof(step)}`, 0) end
			local name = step.command or step.name or step[1]
			local hasNamed = step.command ~= nil or step.name ~= nil
			local arg = if hasNamed then step.arg else step[2]
			local command = if type(name) == "string" then commands[name] else nil
			if command == nil then error(`step {index}: no command named {format.repr(name)}`, 0) end
			if command.pre ~= nil and not command.pre(state, arg) then
				error(`step {index} ({describeStep(name, arg)}): pre refused it`, 0)
			end
			state = model.stepSpec(spec, invKeys, command, sut, state, arg, index, world)
		end
	end)
	finishSpec(spec, sut, world, ok, err)
	return state, sut
end

local function resolveModelArgs(
	where: string,
	nameOrSpec: any,
	specOrOpts: any?,
	maybeOpts: Options?
): (string, Spec<any, any>, Options?)
	if type(nameOrSpec) == "string" then
		if type(specOrOpts) ~= "table" or (specOrOpts.commands == nil and specOrOpts.init == nil) then
			if maybeOpts ~= nil and type(maybeOpts) == "table" and (maybeOpts :: any).commands ~= nil then
				error(`{where}: pass the spec before the options: {where}(name, spec, opts?)`, util.outside())
			end
		end
		local spec = validateSpec(specOrOpts, `{where}("{nameOrSpec}")`, true)
		registry.checkKeys(`{where}("{nameOrSpec}")`, "option", maybeOpts, OPTION_KEYS)
		return nameOrSpec, spec, maybeOpts
	elseif type(nameOrSpec) == "table" then
		local spec = validateSpec(nameOrSpec, where, true)
		local name = spec.name or "model"
		registry.checkKeys(`{where}("{name}")`, "option", specOrOpts, OPTION_KEYS)
		return name, spec, specOrOpts :: Options?
	end
	error(`{where}: expected a name string or spec table, got {util.typeof(nameOrSpec)}`, util.outside())
end

local function buildModelTarget(
	apiPrefix: string,
	target: registry.Target?,
	fixedSkip: boolean,
	fixedFocus: boolean
): TargetModelApi
	local function invokeModel(nameOrSpec: any, specOrOpts: any?, maybeOpts: Options?)
		local name, spec, opts = resolveModelArgs(`sert.{apiPrefix}`, nameOrSpec, specOrOpts, maybeOpts)
		local propFn = if fixedSkip then function(_g: GenContext) end else model.property(spec, opts)
		local propOpts = model.propOptions(opts)
		if target ~= nil and propOpts.target == nil then propOpts.target = target end
		if fixedSkip then propOpts.skip = true end
		if fixedFocus then propOpts.focus = true end
		prop(name, propFn, propOpts)
	end

	local ns: { [string]: any } = {}
	if not fixedSkip and not fixedFocus then
		ns.skip = buildModelTarget(`{apiPrefix}.skip`, target, true, false)
		ns.focus = buildModelTarget(`{apiPrefix}.focus`, target, false, true)
	else
		ns.skip = function(nameOrSpec: any, specOrOpts: any?, maybeOpts: Options?)
			local name, spec, opts = resolveModelArgs(`sert.{apiPrefix}.skip`, nameOrSpec, specOrOpts, maybeOpts)
			local propOpts = model.propOptions(opts)
			if target ~= nil and propOpts.target == nil then propOpts.target = target end
			propOpts.skip = true
			local _ = spec
			prop.skip(name, nil, propOpts)
		end
		ns.focus = function(nameOrSpec: any, specOrOpts: any?, maybeOpts: Options?)
			local name, spec, opts = resolveModelArgs(`sert.{apiPrefix}.focus`, nameOrSpec, specOrOpts, maybeOpts)
			local propFn = model.property(spec, opts)
			local propOpts = model.propOptions(opts)
			if target ~= nil and propOpts.target == nil then propOpts.target = target end
			propOpts.focus = true
			prop.focus(name, propFn, propOpts)
		end
	end

	return (
		setmetatable(ns, {
			__call = function(_self: any, nameOrSpec: any, specOrOpts: any?, maybeOpts: Options?)
				invokeModel(nameOrSpec, specOrOpts, maybeOpts)
			end,
		}) :: any
	) :: TargetModelApi
end

local modelProp: any = buildModelTarget("model.prop", nil, false, false)
modelProp.roblox = buildModelTarget("model.prop.roblox", "roblox", false, false)
modelProp.server = buildModelTarget("model.prop.server", "server", false, false)
modelProp.client = buildModelTarget("model.prop.client", "client", false, false)
model.prop = modelProp :: ModelPropApi

setmetatable(model, {
	__call = function(_self: any, nameOrSpec: any, specOrOpts: any?, maybeOpts: Options?)
		local name, spec, opts = resolveModelArgs("sert.model", nameOrSpec, specOrOpts, maybeOpts)
		local propFn = model.property(spec, opts)
		local propOpts = model.propOptions(opts)
		prop(name, propFn, propOpts)
	end,
})

return (model :: any) :: ModelNamespace
