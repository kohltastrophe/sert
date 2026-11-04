--!strict
-- Stateful command-sequence model testing (`sert.model`) built on `sert.prop`'s tape.

local format = require("./format")
local prop = require("./prop")
local util = require("./util")

type Gen = prop.Gen

export type Command = {
	name: string?, -- required in the array form; taken from the table key in the map form
	weight: number?, -- relative draw weight (default 1)
	gen: (any | (g: Gen, state: any) -> any)?,
	pre: ((state: any, arg: any) -> boolean)?,
	guard: ((state: any, arg: any) -> boolean)?,
	run: ((sut: any, arg: any, state: any) -> any)?,
	post: ((state: any, arg: any, result: any) -> ())?,
	next: ((state: any, arg: any, result: any) -> ...any)?,
}

export type Spec = {
	name: string?,
	init: ((...any) -> ...any)?,
	def: any?,
	-- Single indexer type so both array and string-keyed command tables typecheck under both solvers.
	commands: { [any]: Command }?,
	actions: { [any]: Command }?,
	setup: (() -> any)?,
	teardown: ((sut: any, state: any) -> ())?,
	invariant: ((state: any, sut: any) -> ())?,
	invariants: { [string]: (state: any, sut: any) -> any }?,
	never: { [string]: (state: any, sut: any) -> boolean }?,
}

export type Options = {
	length: number?, -- max steps per sequence (default 30)
	redraw: boolean?, -- retry another command when `pre` refuses a step
	maxRedraws: number?,
	runs: number?,
	size: number?,
	seed: number?,
	regressions: { number }?,
	exhaustive: { size: number }?,
	rtest: boolean?,
	shrinkBudget: prop.ShrinkBudget?,
	timeout: number?,
	skip: boolean?,
	focus: boolean?,
	file: string?,
}

export type Step = { [any]: any }

local model = {}

local SPEC_FIELDS = {
	"actions",
	"commands",
	"init",
	"invariant",
	"invariants",
	"name",
	"never",
	"setup",
	"teardown",
}

local OPTION_HINTS = {
	"exhaustive",
	"file",
	"focus",
	"length",
	"maxRedraws",
	"redraw",
	"regressions",
	"replay",
	"rtest",
	"runs",
	"seed",
	"shrinkBudget",
	"size",
	"skip",
	"timeBudget",
	"timeout",
}

local COMMAND_FIELDS = {
	"gen",
	"guard",
	"name",
	"next",
	"post",
	"pre",
	"run",
	"weight",
}

local sortedKeys = util.sortedKeys

local function unwrapAndValidateSpec(rawSpec: any, caller: string?, requireInit: boolean): Spec
	local where = caller or "sert.model"
	local spec: any = if type(rawSpec) == "table"
			and type(rawSpec.def) == "table"
			and type(rawSpec.check) == "function"
		then rawSpec.def
		else rawSpec
	if type(spec) ~= "table" then error(`{where}: expected a spec table, got {typeof(rawSpec)}`, util.outside()) end
	for key in spec do
		if table.find(SPEC_FIELDS, key) == nil then
			local hint = if table.find(OPTION_HINTS, key) ~= nil then " (an option: pass it in options)" else ""
			error(`{where}: unknown spec field {tostring(key)}{hint}`, util.outside())
		end
	end
	if (requireInit or spec.init ~= nil) and type(spec.init) ~= "function" then
		error(`{where}: spec.init must be a function, got {typeof(spec.init)}`, util.outside())
	end
	return spec
end

local function normalizeCommand(where: string, rawCmd: any, key: any, isArray: boolean): Command
	if type(rawCmd) ~= "table" then
		error(`{where}: command {tostring(key)} must be a table, got {typeof(rawCmd)}`, util.outside())
	end
	if isArray and type(rawCmd.name) ~= "string" then
		error(`{where}: command {tostring(key)} has no name`, util.outside())
	end
	local cmdName: string = if isArray then rawCmd.name else key
	for field in rawCmd do
		if table.find(COMMAND_FIELDS, field) == nil then
			error(`{where}: command "{cmdName}" has unknown field {tostring(field)}`, util.outside())
		end
	end
	local command = table.clone(rawCmd)
	command.name = cmdName
	if command.pre == nil and command.guard ~= nil then command.pre = command.guard end
	local rawGen: any = command.gen
	if type(rawGen) == "table" then
		local drawFn = (rawGen :: { [any]: any }).draw
		if type(drawFn) == "function" then
			command.gen = function(g: Gen) return (drawFn :: (Gen) -> any)(g) end
		else
			command.gen = function(g: Gen) return g:pick(rawGen :: { any }) end
		end
	elseif rawGen ~= nil and type(rawGen) ~= "function" then
		error(`{where}: command "{cmdName}" gen must be a function or table, got {typeof(rawGen)}`, util.outside())
	end
	if command.run == nil and command.next == nil and command.post == nil then
		error(`{where}: command "{cmdName}" must define at least one of run, next, or post`, util.outside())
	end
	return command
end

-- Sort map-form commands by name so a seed produces the same sequence regardless of hash iteration order.
function model.commandList(rawSpec: any, caller: string?): { any }
	local where = caller or "sert.model"
	local spec = unwrapAndValidateSpec(rawSpec, where, false)
	local commands = (spec.commands or spec.actions) :: any
	if type(commands) ~= "table" or next(commands) == nil then
		error(`{where}: spec must define commands (or actions)`, util.outside())
	end
	if commands[1] ~= nil then
		local list = table.create(#(commands :: { Command }))
		for index, command in commands :: { Command } do
			list[index] = normalizeCommand(where, command, index, true)
		end
		return list
	end
	local names = {}
	for name in commands :: { [string]: Command } do
		if type(name) ~= "string" then
			error(`{where}: command key must be a string, got {typeof(name)}`, util.outside())
		end
		table.insert(names, name)
	end
	table.sort(names)
	local list = table.create(#names)
	for index, name in names do
		list[index] = normalizeCommand(where, commands[name], name, false)
	end
	return list
end
local commandList = model.commandList

local function describe(name: string, arg: any): string return if arg == nil then name else `{name} {format.repr(arg)}` end

local function checkInvariants(spec: Spec, neverKeys: { string }, invKeys: { string }, state: any, sut: any)
	if spec.never ~= nil then
		for _, key in neverKeys do
			if spec.never[key](state, sut) then
				error(
					`negative invariant never.{key} violated (forbidden state occurred)\nstate = {format.repr(state)}`,
					0
				)
			end
		end
	end
	if spec.invariants ~= nil then
		for _, key in invKeys do
			local ok, res = pcall(spec.invariants[key], state, sut)
			if not ok then
				error(`invariant.{key} failed: {format.errorText(res)}\nstate = {format.repr(state)}`, 0)
			elseif res == false then
				error(`invariant.{key} violated (returned false)\nstate = {format.repr(state)}`, 0)
			end
		end
	end
	if spec.invariant then spec.invariant(state, sut) end
end

local function execute(
	spec: Spec,
	neverKeys: { string },
	invKeys: { string },
	command: Command,
	sut: any,
	state: any,
	arg: any,
	index: number
): any
	local ok, why = pcall(function()
		local result = if command.run ~= nil then command.run(sut, arg, state) else nil
		if command.post then command.post(state, arg, result) end
		if command.next then
			local nextState = command.next(state, arg, result)
			if nextState ~= nil then state = nextState end
		end
		checkInvariants(spec, neverKeys, invKeys, state, sut)
	end)
	if not ok then error(`step {index} ({describe(command.name :: string, arg)}): {format.errorText(why)}`, 0) end
	return state
end

local function start(spec: Spec): (any, any)
	local initFn = spec.init :: (...any) -> (any, any?)
	local state, initSut = initFn()
	local sut = if spec.setup then spec.setup() elseif initSut ~= nil then initSut else state
	return state, sut
end

local function finishing(spec: Spec, sut: any, state: any, ok: boolean, err: any)
	if spec.teardown then
		local tornDown, why = pcall(spec.teardown :: (any, any) -> ...any, sut, state)
		if ok and not tornDown then error(`teardown: {format.errorText(why)}`, 0) end
	end
	if not ok then error(err, 0) end
end

--- Builds the `(g: Gen) -> ()` property function for `spec`.
function model.property(rawSpec: Spec, options: Options?): (Gen) -> ()
	local spec = unwrapAndValidateSpec(rawSpec, "sert.model", true)
	local opts: Options = options or {}
	local commands = commandList(spec, "sert.model")
	local neverKeys = sortedKeys(spec.never)
	local invKeys = sortedKeys(spec.invariants)
	local length = opts.length or 25
	local redraw = opts.redraw == true
	local maxRedraws = opts.maxRedraws
	local weighted = {}
	local drawn: { [Command]: number } = {}
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
	local function choose(g: Gen, state: any): (Command?, any)
		local left = weighted
		local first = prop.mark(g)
		local redraws = 0
		while #left > 0 do
			local pick = prop.mark(g)
			local command = g:weighted(left) :: Command
			local genFn = command.gen :: ((Gen, any) -> any)?
			local arg = if genFn ~= nil then genFn(g, state) else nil
			if command.pre == nil or command.pre(state, arg) then
				if pick > first then prop.hint(g, first, pick, { drawn[command] }) end
				return command, arg
			elseif not redraw or (maxRedraws ~= nil and redraws >= (maxRedraws :: number)) then
				return nil, nil
			end
			redraws += 1
			local others = {}
			for _, entry in left do
				if entry[2] ~= command then table.insert(others, entry) end
			end
			left = others
		end
		return nil, nil
	end
	return function(g: Gen)
		local state, sut = start(spec)
		local ok, err = pcall(function()
			checkInvariants(spec, neverKeys, invKeys, state, sut)
			local index = 0
			local refused = false
			g:list(function(stepGen: Gen)
				local command, arg = choose(stepGen, state)
				if command == nil then
					refused = true
					return false
				end
				index += 1
				local cmdName = command.name :: string
				stepGen:note(function() return string.format("{ %q, %s },", cmdName, format.repr(arg)) end)
				state = execute(spec, neverKeys, invKeys, command, sut, state, arg, index)
				return true
			end, 0, length)
			if index == 0 then prop.vacuous(g, if refused then "pre refused every step" else nil) end
		end)
		finishing(spec, sut, state, ok, err)
	end
end

--- Runs an explicit `{ { name, arg }, ... }` list against `spec` and returns `(state, sut)`.
function model.replay(rawSpec: Spec, steps: { Step }): (any, any)
	local spec = unwrapAndValidateSpec(rawSpec, "sert.model", true)
	local commands: { [string]: Command } = {}
	for _, command in commandList(spec, "sert.model") do
		commands[command.name :: string] = command
	end
	local neverKeys = sortedKeys(spec.never)
	local invKeys = sortedKeys(spec.invariants)
	local state, sut = start(spec)
	local ok, err = pcall(function()
		checkInvariants(spec, neverKeys, invKeys, state, sut)
		for index, step in steps do
			local name = step.name or step[1]
			local arg = if step.name ~= nil then step.arg else step[2]
			local command = commands[name]
			if command == nil then error(`step {index}: no command named {format.repr(name)}`, 0) end
			if command.pre and not command.pre(state, arg) then
				error(`step {index} ({describe(name, arg)}): pre refused it`, 0)
			end
			state = execute(spec, neverKeys, invKeys, command, sut, state, arg, index)
		end
	end)
	finishing(spec, sut, state, ok, err)
	return state, sut
end

--- Strips model-only keys (`length`, `redraw`, `maxRedraws`) from `options` to produce `PropOptions`.
function model.propOptions(options: Options?): prop.PropOptions
	local out: any = table.clone(options or {})
	out.length, out.redraw, out.maxRedraws = nil, nil, nil
	return out
end

return model
