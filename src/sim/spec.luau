--!strict
-- Unified stateful simulation and bounded model-checking specification (`Sim.spec`), aligned with `src/prop/model.luau`.

local World = require("./world")
local assert = require("../core/assert")
local bytes = require("../core/bytes")
local format = require("../core/format")
local util = require("../core/util")

export type Command<State, Sut = any, Arg = any, Res = any> = {
	gen: ((state: State, g: any) -> Arg)?,
	args: ({ Arg } | ((state: State) -> { Arg }))?,
	pre: ((state: State, arg: Arg) -> boolean)?,
	run: ((sut: Sut, arg: Arg, world: World.World) -> Res)?,
	next: (state: State, arg: Arg, res: Res) -> ...any,
	post: ((state: State, sut: Sut, arg: Arg, res: Res, world: World.World) -> ())?,
	weight: number?,
}

export type Spec<State, Sut = any> = {
	name: string?,
	init: () -> State,
	setup: ((world: World.World) -> Sut)?,
	teardown: ((sut: Sut, world: World.World) -> ())?,
	commands: { [string]: Command<State, Sut, any, any> },
	invariants: { [string]: (state: State, sut: Sut, world: World.World?) -> any }?,
	converge: (boolean | ((state: State, sut: Sut, world: World.World) -> ()))?,
	project: ((sut: Sut, world: World.World) -> State)?,
	world: World.Options?,
}

export type TraceStep = {
	command: string,
	arg: any,
	result: any?,
	state: any?,
}

export type BfsOptions = {
	maxStates: number?,
	maxDepth: number?,
}

export type BfsResult = {
	visited: number,
	maxDepthReached: number,
	truncated: boolean,
}

local SpecModule = {}

--- Validates `def` and returns it as a typed `Spec<State, Sut>`.
function SpecModule.define<State, Sut>(def: Spec<State, Sut>): Spec<State, Sut>
	if type(def) ~= "table" then error("Sim.spec: expected a table definition", util.outside()) end
	if type(def.init) ~= "function" then error("Sim.spec: 'init' must be a function", util.outside()) end
	if type(def.commands) ~= "table" then error("Sim.spec: 'commands' must be a table", util.outside()) end
	local count = 0
	for name, cmd in next, def.commands do
		if type(name) ~= "string" then error("Sim.spec: command names must be strings", util.outside()) end
		if type(cmd) ~= "table" or type(cmd.next) ~= "function" then
			error(`Sim.spec: command '{name}' must define a 'next' function`, util.outside())
		end
		count += 1
	end
	if count == 0 then error("Sim.spec: 'commands' must contain at least one command", util.outside()) end
	return def
end

--- Produces a deterministic, collision-free canonical string key for `value` with explicit Luau type tags.
function SpecModule.canonicalize(value: any): string
	local active: { [any]: boolean } = {}

	local function encode(v: any): string
		local t = type(v)
		if v == nil then
			return "nil"
		elseif t == "boolean" then
			return if v then "b:1" else "b:0"
		elseif t == "number" then
			if v ~= v then return "n:nan" end
			if v == math.huge then return "n:+inf" end
			if v == -math.huge then return "n:-inf" end
			if v == 0 then return "n:0" end
			return string.format("n:%.17g", v)
		elseif t == "string" then
			return `s:{#v}:{v}`
		elseif t == "buffer" then
			return `buf:{bytes.hex(v)}`
		elseif t == "table" then
			local tag = util.doubleTag(v)
			if tag ~= nil then return `dt:{tag}:{format.repr(v)}` end
			if active[v] then return "t:<cycle>" end
			active[v] = true
			type PairEntry = { k: string, pair: string }
			local pairsList: { PairEntry } = {}
			for k, item in next, v do
				local ks = encode(k)
				local vs = encode(item)
				table.insert(pairsList, { k = ks, pair = `{ks}={vs}` })
			end
			active[v] = nil
			table.sort(pairsList, function(a: PairEntry, b: PairEntry): boolean return a.k < b.k end)
			local parts = table.create(#pairsList)
			for i, p in pairsList do
				parts[i] = p.pair
			end
			return `t:\{{table.concat(parts, ",")}\}`
		else
			return `u:{util.typeof(v)}:{tostring(v)}`
		end
	end

	return encode(value)
end

--- Evaluates every invariant in `spec.invariants` directly (without swallowing assertion errors) in sorted order.
function SpecModule.checkInvariants<State, Sut>(spec: Spec<State, Sut>, state: State, sut: Sut, world: World.World?)
	local invs = spec.invariants
	if invs == nil then return end
	for _, name in util.sortedKeys(invs) do
		local fn = invs[name]
		local res = fn(state, sut, world)
		if res == false then assert.fail(`Invariant '{name}' returned false`) end
	end
end

--- Returns sorted command names for deterministic iteration.
function SpecModule.commandNames<State, Sut>(spec: Spec<State, Sut>): { string } return util.sortedKeys(spec.commands) end

--- Replays a recorded `trace` against `spec`'s pure model transitions (`pre`, `next`, `invariants`),
--- deep-cloning `initialState` and every step state so mutating transitions never alias caller tables.
function SpecModule.verifyTrace<State, Sut>(spec: Spec<State, Sut>, trace: { TraceStep }, initialState: State?): State
	local state: State = if initialState ~= nil then util.copy(initialState) else util.copy(spec.init())
	SpecModule.checkInvariants(spec, state, nil :: any, nil)

	for i, step in trace do
		local cmdName = step.command
		local cmd = spec.commands[cmdName]
		if cmd == nil then assert.fail(`verifyTrace step #{i}: unknown command '{tostring(cmdName)}'`) end
		local argCopy = util.copy(step.arg)
		if cmd.pre ~= nil and not cmd.pre(state, argCopy) then
			assert.fail(`verifyTrace step #{i} ('{cmdName}'): precondition failed for arg {format.repr(step.arg)}`)
		end
		local working = util.copy(state)
		local produced = cmd.next(working, argCopy, util.copy(step.result))
		state = if produced ~= nil then produced else working
		if step.state ~= nil and not util.equal(state, step.state) then
			assert.fail(
				`verifyTrace step #{i} ('{cmdName}'): projected state diverged from model\n{format.diff(
					step.state,
					state
				)}`
			)
		end
		SpecModule.checkInvariants(spec, state, nil :: any, nil)
	end

	return state
end

local function candidateArgs<State, Sut>(cmd: Command<State, Sut, any, any>, state: State): { any }
	local rawArgs = cmd.args
	if type(rawArgs) == "function" then
		return (rawArgs :: (State) -> { any })(state)
	elseif type(rawArgs) == "table" then
		return rawArgs
	end
	return { nil :: any }
end

--- Bounded breadth-first state-space exploration over `spec.init()` and `commands` (`args`, `pre`, `next`, `invariants`).
function SpecModule.bfsCheck<State, Sut>(spec: Spec<State, Sut>, options: BfsOptions?): BfsResult
	local o: BfsOptions = options or {}
	local maxStates = o.maxStates or 2000
	local maxDepth = o.maxDepth or 20
	local names = SpecModule.commandNames(spec)

	type Node = {
		state: State,
		depth: number,
		parent: number?,
		command: string?,
		arg: any,
	}

	local initState = util.copy(spec.init())
	local visited: { [string]: boolean } = {
		[SpecModule.canonicalize(initState)] = true,
	}
	local queue: { Node } = {
		{ state = initState, depth = 0, parent = nil, command = nil, arg = nil },
	}

	local function formatPath(nodeIdx: number, tailCmd: string?, tailArg: any): string
		local steps: { string } = {}
		local cur: number? = nodeIdx
		while cur ~= nil do
			local n = queue[cur]
			if n.command ~= nil then
				table.insert(steps, 1, `{n.command}({if n.arg ~= nil then format.repr(n.arg) else ""})`)
			end
			cur = n.parent
		end
		if tailCmd ~= nil then
			table.insert(steps, `{tailCmd}({if tailArg ~= nil then format.repr(tailArg) else ""})`)
		end
		return if #steps == 0 then "<init>" else table.concat(steps, " -> ")
	end

	local okInit, initErr = pcall(function(): nil
		SpecModule.checkInvariants(spec, initState, nil :: any, nil)
		return nil
	end)
	if not okInit then
		error(`Sim.check initial state failed invariant:\n{format.errorText(initErr)}`, util.outside())
	end

	local head = 1
	local maxDepthReached = 0
	local truncated = false

	while head <= #queue do
		local node = queue[head]
		local parentIdx = head
		head += 1
		if node.depth > maxDepthReached then maxDepthReached = node.depth end
		if node.depth >= maxDepth then
			truncated = true
			continue
		end

		for _, cmdName in names do
			local cmd = spec.commands[cmdName]
			for _, arg in candidateArgs(cmd, node.state) do
				local enabled = if cmd.pre ~= nil then cmd.pre(node.state, arg) else true
				if enabled then
					local working = util.copy(node.state)
					local produced = cmd.next(working, util.copy(arg), nil)
					local nextState = if produced ~= nil then produced else working

					local okInv, invErr = pcall(function(): nil
						SpecModule.checkInvariants(spec, nextState, nil :: any, nil)
						return nil
					end)
					if not okInv then
						local traceStr = formatPath(parentIdx, cmdName, arg)
						error(
							`Sim.check counterexample at depth {node.depth + 1} ({traceStr}):\n`
								.. `State: {format.repr(nextState)}\n`
								.. format.errorText(invErr),
							util.outside()
						)
					end

					local hash = SpecModule.canonicalize(nextState)
					if not visited[hash] then
						if #queue >= maxStates then
							truncated = true
						else
							visited[hash] = true
							table.insert(queue, {
								state = nextState,
								depth = node.depth + 1,
								parent = parentIdx,
								command = cmdName,
								arg = util.copy(arg),
							})
						end
					end
				end
			end
		end
	end

	return {
		visited = #queue,
		maxDepthReached = maxDepthReached,
		truncated = truncated,
	}
end

--- Exports `trace` in Apalache Informal Trace Format (ITF) JSON for TLA+ trace checking.
function SpecModule.toItfJson<State, Sut>(spec: Spec<State, Sut>, trace: { TraceStep }, initialState: State?): string
	local cur: any = if initialState ~= nil then util.copy(initialState) else util.copy(spec.init())
	local varSet: { [string]: boolean } = { _action = true }
	if type(cur) == "table" then
		for k in next, cur do
			if type(k) == "string" then varSet[k] = true end
		end
	else
		varSet.value = true
	end

	local states: { any } = {}
	local function pushState(index: number, actionLabel: string, st: any)
		local entry: { [string]: any } = {
			["#meta"] = { index = index },
			_action = actionLabel,
		}
		if type(st) == "table" then
			for k, v in next, st do
				if type(k) == "string" then
					varSet[k] = true
					entry[k] = util.copy(v)
				end
			end
		else
			varSet.value = true
			entry.value = util.copy(st)
		end
		table.insert(states, entry)
	end

	pushState(0, "Init", cur)
	for i, step in trace do
		local cmd = spec.commands[step.command]
		if step.state ~= nil then
			cur = util.copy(step.state)
		elseif cmd ~= nil then
			local working = util.copy(cur)
			local produced = cmd.next(working, util.copy(step.arg), util.copy(step.result))
			cur = if produced ~= nil then produced else working
		end
		pushState(i, step.command, cur)
	end

	local vars = util.sortedKeys(varSet)
	return format.json({
		["#meta"] = {
			format = "ITF",
			["format-description"] = "https://apalache.informal.systems/docs/adr/015adr-trace.html",
			source = spec.name or "sert.sim",
		},
		vars = vars,
		states = states,
	})
end

return SpecModule
