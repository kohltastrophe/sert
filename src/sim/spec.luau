--!strict
-- TLA+-style state-machine specification, negative invariants ("what isn't promised" / `never`),
-- standalone BFS state-space model checker (`spec:check`), trace refinement verifier (`spec:verifyTrace`),
-- and TLA+ JSON trace exporter (`spec:toTlaJson`).

local Rng = require("../rng")
local format = require("../format")
local prop = require("../prop")
local util = require("../util")

export type ActionSpec = {
	name: string?,
	weight: number?,
	-- Precondition / guard (`ENABLED` in TLA+).
	guard: ((state: any, arg: any) -> boolean)?,
	pre: ((state: any, arg: any) -> boolean)?,
	-- Parameter generator or finite candidate list (`{ a, b }` or `(g, state) -> arg`).
	gen: any?,
	-- Next-state relation (`Next` in TLA+): may mutate `state` in place or return the next state.
	next: (state: any, arg: any, result: any?) -> ...any,
	-- Concrete Luau SUT execution when bound to `Sim.vopr` or `Sim.model`.
	run: ((sut: any, arg: any, world: any, state: any) -> any)?,
	-- Post-step assertion when bound to `Sim.vopr` or `Sim.model`.
	post: ((state: any, sut: any, arg: any, result: any, world: any) -> ())?,
}

export type RemoteHandler = (world: any, player: any, ...any) -> ()

export type TraceEntry = {
	step: number?,
	t: number?,
	action: string,
	arg: any?,
	result: any?,
	state: any?,
}

export type SpecCheckOptions = {
	maxStates: number?,
	maxDepth: number?,
	samples: number?,
	seed: number?,
	soft: boolean?,
}

export type SpecCheckResult = {
	ok: boolean,
	statesVisited: number,
	transitions: number,
	violation: string?,
	trace: { TraceEntry }?,
}

export type SpecDef = {
	name: string?,
	init: ((...any) -> (any, any?))?,
	actions: ({ [string]: ActionSpec } | { ActionSpec })?,
	commands: ({ [string]: ActionSpec } | { ActionSpec })?,
	-- Declarative server remote handlers attached on `World` setup in `Sim.vopr` / `Sim.model`.
	remotes: { [string]: RemoteHandler }?,
	-- Allow remote handler errors without failing the run.
	allowRemoteErrors: boolean?,
	-- Negative invariants ("what isn't promised" — raises when a predicate returns true).
	never: { [string]: (state: any, sut: any?, world: any?) -> boolean }?,
	-- Positive safety invariants (raises when a predicate returns false or errors).
	invariants: { [string]: (state: any, sut: any?, world: any?) -> any }?,
	-- Single invariant callback (for compatibility with `Sim.model`).
	invariant: ((state: any, sut: any?, world: any?) -> ())?,
	-- Refinement mapping `(sut, world) -> abstractState` to compare Luau SUT state against the spec.
	project: ((sut: any, world: any?) -> any)?,
	converge: (boolean | ((state: any, sut: any, world: any) -> ()))?,
	teardown: ((sut: any, state: any, world: any) -> ())?,
	world: { [string]: any }?,
}
export type SimSpec = SpecDef

local Spec = {}
Spec.__index = Spec

export type Spec = typeof(setmetatable(
	{} :: {
		name: string,
		def: SpecDef,
		actions: { [string]: ActionSpec },
		actionOrder: { string },
		neverKeys: { string },
		invariantKeys: { string },
		remotes: { [string]: RemoteHandler }?,
		allowRemoteErrors: boolean,
	},
	Spec
))

local function sortedKeys(tbl: { [string]: any }?): { string }
	local keys: { string } = {}
	if tbl == nil then return keys end
	for k in tbl do
		table.insert(keys, k)
	end
	table.sort(keys)
	return keys
end

local function canonicalize(value: any, seen: { [any]: number }, nextId: { number }): string
	local kind = type(value)
	if kind == "string" then
		return string.format("%q", value)
	elseif kind == "number" or kind == "boolean" or kind == "nil" then
		return tostring(value)
	elseif kind == "buffer" then
		return `buf:{string.format("%q", buffer.tostring(value))}`
	elseif kind ~= "table" then
		return `<{kind}:{tostring(value)}>`
	end
	local existing = seen[value]
	if existing ~= nil then return `<cycle:{existing}>` end
	local id = nextId[1]
	nextId[1] = id + 1
	seen[value] = id
	local entries: { { k: string, v: string, tk: string } } = {}
	for k, v in value do
		local ks = canonicalize(k, seen, nextId)
		local vs = canonicalize(v, seen, nextId)
		table.insert(entries, { k = ks, v = vs, tk = type(k) })
	end
	table.sort(
		entries,
		function(a: { k: string, v: string, tk: string }, b: { k: string, v: string, tk: string }): boolean
			if a.tk ~= b.tk then return a.tk < b.tk end
			return a.k < b.k
		end
	)
	local parts = table.create(#entries) :: { string }
	for i, e in entries do
		parts[i] = `{e.k}={e.v}`
	end
	seen[value] = nil
	return `\{{table.concat(parts, ",")}}`
end

local function canonicalKey(value: any): string return canonicalize(value, {}, { 1 }) end

local function normalizeActions(raw: { [any]: any }): ({ [string]: ActionSpec }, { string })
	assert(type(raw) == "table", "Sim.spec: actions must be a table")
	local map: { [string]: ActionSpec } = {}
	local order: { string } = {}
	if raw[1] ~= nil then
		for i, item in raw :: { any } do
			local copy: ActionSpec = if type(item) == "function"
				then { name = `action{i}`, run = item, next = nil :: any }
				else table.clone(item)
			local name = copy.name or `action{i}`
			copy.name = name
			copy.guard = copy.guard or (copy :: any).pre
			map[name] = copy
			table.insert(order, name)
		end
	else
		for k, item in raw :: { [string]: any } do
			assert(type(k) == "string", "Sim.spec: action keys must be strings")
			local copy: ActionSpec = if type(item) == "function"
				then { name = k, run = item, next = nil :: any }
				else table.clone(item)
			copy.name = copy.name or k
			copy.guard = copy.guard or (copy :: any).pre
			map[k] = copy
			table.insert(order, k)
		end
		table.sort(order)
	end
	assert(#order > 0, "Sim.spec: actions must not be empty")
	return map, order
end

local function isPureStateFn(fn: (...any) -> ...any): boolean
	local arity, isVararg = debug.info(fn, "a")
	return (arity or 1) <= 1 and not isVararg
end

--- Checks `never` (negative invariants: what isn't promised) and `invariants` (positive safety properties).
function Spec.checkInvariants(
	specName: string,
	neverMap: { [string]: (any, any?, any?) -> boolean }?,
	neverKeys: { string },
	invMap: { [string]: (any, any?, any?) -> any }?,
	invKeys: { string },
	singleInv: ((any, any?, any?) -> ())?,
	state: any,
	sut: any?,
	world: any?
)
	if neverMap ~= nil then
		for _, k in neverKeys do
			local fn = neverMap[k]
			if sut == nil and not isPureStateFn(fn) then
				local ok, violated = pcall(fn, state, sut, world)
				if ok and violated then
					error(
						`spec "{specName}": negative invariant never.{k} violated (forbidden state occurred)\nstate = {format.repr(
							state
						)}`,
						0
					)
				end
			else
				local violated = fn(state, sut, world)
				if violated then
					error(
						`spec "{specName}": negative invariant never.{k} violated (forbidden state occurred)\nstate = {format.repr(
							state
						)}`,
						0
					)
				end
			end
		end
	end
	if invMap ~= nil then
		for _, k in invKeys do
			local fn = invMap[k]
			local ok, res = pcall(fn, state, sut, world)
			if not ok then
				if sut ~= nil or isPureStateFn(fn) then
					error(`spec "{specName}": invariant.{k} failed: {tostring(res)}\nstate = {format.repr(state)}`, 0)
				end
			elseif res == false then
				error(`spec "{specName}": invariant.{k} violated (returned false)\nstate = {format.repr(state)}`, 0)
			end
		end
	end
	if singleInv ~= nil then
		if sut == nil and not isPureStateFn(singleInv) then
			pcall(singleInv, state, sut, world)
		else
			singleInv(state, sut, world)
		end
	end
end

--- Constructs a TLA+-style state-machine `Spec` from `def` (`init`, `actions`, `never`, `invariants`, `project`).
function Spec.new(def: SpecDef): Spec
	assert(type(def) == "table", "Sim.spec: definition must be a table")
	assert(def.init == nil or type(def.init) == "function", "Sim.spec: init must be a function")
	local rawActions: any = def.actions or (def :: any).commands
	local actions, actionOrder = normalizeActions(rawActions)
	for _, name in actionOrder do
		local act = actions[name]
		assert(
			type(act.next) == "function" or type(act.run) == "function",
			`Sim.spec: action "{name}" must define a next(state, arg) or run(sut, arg, world, state) function`
		)
	end
	if def.remotes ~= nil then
		assert(type(def.remotes) == "table", "Sim.spec: remotes must be a table")
		for k, fn in def.remotes do
			assert(
				type(k) == "string" and type(fn) == "function",
				"Sim.spec: remotes entries must map remote names to handler functions"
			)
		end
	end
	local self = setmetatable({
		name = def.name or "Spec",
		def = def,
		actions = actions,
		actionOrder = actionOrder,
		neverKeys = sortedKeys(def.never),
		invariantKeys = sortedKeys(def.invariants),
		remotes = def.remotes,
		allowRemoteErrors = def.allowRemoteErrors == true,
	}, Spec)
	return self
end

--- Attaches declarative `remotes` handlers (`(world, player, ...args)`) to `world` via `world:onServerEvent`.
function Spec.attachRemotes(remotes: { [string]: RemoteHandler }?, world: any)
	if remotes == nil then return end
	local names = sortedKeys(remotes)
	for _, remoteName in names do
		local handler = remotes[remoteName]
		world:onServerEvent(remoteName, function(player: any, ...: any) handler(world, player, ...) end)
	end
end

export type FailureFormatOptions = {
	specName: string?,
	err: any,
	world: any?,
	seed: number?,
	steps: number?,
	actions: { TraceEntry }?,
	maxTrace: number?,
}

--- Formats a simulation/spec failure with any `world.remoteErrors`, the last N (up to 10) trace events,
--- and a copy-pasteable `replay:` snippet and action sequence.
function Spec.formatFailure(opts: FailureFormatOptions): string
	local lines: { string } = {}
	local errMsg = if opts.err ~= nil then tostring(opts.err) else "simulation failed"
	table.insert(lines, errMsg)
	local w = opts.world
	local maxTrace = opts.maxTrace or 10
	if w ~= nil and type(w.remoteErrors) == "table" and #w.remoteErrors > 0 then
		table.insert(lines, "remoteErrors:")
		for i, remErr in w.remoteErrors :: { { time: number?, remote: any, peerId: any, err: any } } do
			local remTime: number = remErr.time or 0
			local remName: string = tostring(remErr.remote)
			local remPeer: string = tostring(remErr.peerId)
			local remMsg: string = tostring(remErr.err)
			table.insert(lines, string.format("  [%d] [t=%.2fs] %s (%s): %s", i, remTime, remName, remPeer, remMsg))
		end
	end
	local actions: { TraceEntry }? = opts.actions
		or (if w ~= nil and type(w.actions) == "table" then w.actions else nil)
	local traced: { string }? = if w ~= nil
			and w.scheduler ~= nil
			and type(w.scheduler.traced) == "table"
		then w.scheduler.traced
		else nil
	if actions ~= nil and #actions > 0 then
		table.insert(lines, "trace:")
		local startIdx = math.max(1, #actions - maxTrace + 1)
		for i = startIdx, #actions do
			local entry = actions[i]
			local tVal: number = entry.t or 0
			local argSuffix: string = if entry.arg ~= nil then `({format.repr(entry.arg)})` else ""
			table.insert(lines, string.format("  [t=%.2fs] action: %s%s", tVal, entry.action, argSuffix))
		end
	elseif traced ~= nil and #traced > 0 then
		table.insert(lines, "trace:")
		local nowVal: number = if w ~= nil and w.scheduler ~= nil then (w.scheduler.now or 0) else 0
		local startIdx = math.max(1, #traced - maxTrace + 1)
		for i = startIdx, #traced do
			local line: string = traced[i]
			if string.sub(line, 1, 3) == "[t=" then
				table.insert(lines, `  {line}`)
			else
				table.insert(lines, string.format("  [t=%.2fs] %s", nowVal, line))
			end
		end
	end
	if traced ~= nil and #traced > 0 and actions ~= nil and #actions > 0 then
		local nowVal: number = if w ~= nil and w.scheduler ~= nil then (w.scheduler.now or 0) else 0
		local startIdx = math.max(1, #traced - maxTrace + 1)
		for i = startIdx, #traced do
			local line: string = traced[i]
			if not string.find(line, "^action #") then
				table.insert(lines, string.format("  [t=%.2fs] %s", nowVal, line))
			end
		end
	end
	local seed: number = opts.seed
		or (if w ~= nil and w.scheduler ~= nil and type(w.scheduler.seed) == "number" then w.scheduler.seed else 1)
	local steps: number = opts.steps or (if actions ~= nil and #actions > 0 then #actions else 15)
	table.insert(lines, string.format("replay: Sim.vopr(spec, { seed = %d, steps = %d })", seed, steps))
	if actions ~= nil and #actions > 0 then
		local seqParts: { string } = {}
		for i, entry in actions do
			local argSuffix = if entry.arg ~= nil then `({format.repr(entry.arg)})` else ""
			table.insert(seqParts, `[{i}] {entry.action}{argSuffix}`)
		end
		table.insert(lines, `actions: {table.concat(seqParts, ", ")}`)
	end
	return table.concat(lines, "\n")
end

--- Evaluates all `never` and `invariants` predicates on `(state, sut, world)`.
function Spec.assertInvariants(self: Spec, state: any, sut: any?, world: any?)
	Spec.checkInvariants(
		self.name,
		self.def.never,
		self.neverKeys,
		self.def.invariants,
		self.invariantKeys,
		self.def.invariant,
		state,
		sut,
		world
	)
end

--- Steps the pure specification from `state` via `actionName(arg)` and verifies all invariants on the resulting state.
function Spec.step(self: Spec, state: any, actionName: string, arg: any?, result: any?, sut: any?, world: any?): any
	local act = self.actions[actionName]
	if act == nil then error(`spec "{self.name}": unknown action "{tostring(actionName)}"`, 0) end
	local nextState = util.copy(state)
	if act.guard ~= nil and not act.guard(nextState, arg) then
		error(
			`spec "{self.name}": action "{actionName}" guard violated for arg {format.repr(arg)} in state {format.repr(
				state
			)}`,
			0
		)
	end
	local returned = if act.next ~= nil then act.next(nextState, arg, result) else nil
	if returned ~= nil then nextState = returned end
	self:assertInvariants(nextState, sut, world)
	return nextState
end

local function formatTrace(trace: { TraceEntry }): string
	local lines: { string } = {}
	for i, entry in trace do
		local argText = if entry.arg ~= nil then `({format.repr(entry.arg)})` else "()"
		table.insert(lines, `  {i}. {entry.action}{argText} -> {format.repr(entry.state)}`)
	end
	return table.concat(lines, "\n")
end

local function sampleArgs(act: ActionSpec, state: any, rng: Rng.Rng, samples: number): { n: number, [number]: any }
	local genSpec = act.gen
	if genSpec == nil then return { n = 1 } end
	if type(genSpec) == "table" and genSpec.draw == nil then
		local list = table.clone(genSpec)
		list.n = #list
		return list
	end
	local out: { n: number, [number]: any } = { n = 0 }
	local seen: { [string]: boolean } = {}
	for _ = 1, samples do
		local g = prop.gen(rng:int(1, 2147483647), 10)
		local genFn: any = genSpec
		local candidate = if type(genFn) == "function"
			then (genFn :: (any, any) -> any)(g, state)
			else (genFn :: { draw: (any) -> any }).draw(g)
		local key = canonicalKey(candidate)
		if not seen[key] then
			seen[key] = true
			out.n += 1
			out[out.n] = candidate
		end
	end
	return out
end

--- Model-checks the pure specification via bounded BFS state-space exploration before translating to Luau.
function Spec.check(self: Spec, options: SpecCheckOptions?): SpecCheckResult
	local o: SpecCheckOptions = options or {}
	local maxStates = o.maxStates or 500
	local maxDepth = o.maxDepth or 12
	local samples = o.samples or 4
	local rng = Rng.new(o.seed or 1)

	local initFn = self.def.init
	local initState = if initFn ~= nil then (initFn()) else {}
	local okInit, initErr = pcall(function() self:assertInvariants(initState) end)
	if not okInit then
		local res: SpecCheckResult = {
			ok = false,
			statesVisited = 1,
			transitions = 0,
			violation = tostring(initErr),
			trace = {},
		}
		if o.soft then return res end
		error(`{tostring(initErr)}\nCounterexample trace: <initial state>`, 0)
	end

	type Node = { state: any, depth: number, trace: { TraceEntry } }
	local queue: { Node } = { { state = initState, depth = 0, trace = {} } }
	local visited: { [string]: boolean } = { [canonicalKey(initState)] = true }
	local statesVisited = 1
	local transitions = 0
	local head = 1

	while head <= #queue and statesVisited <= maxStates do
		local current = queue[head]
		head += 1
		if current.depth >= maxDepth then continue end

		for _, actionName in self.actionOrder do
			local act = self.actions[actionName]
			local candidates = sampleArgs(act, current.state, rng, samples)
			for cIdx = 1, candidates.n do
				local arg = candidates[cIdx]
				if act.guard ~= nil and not act.guard(current.state, arg) then continue end
				transitions += 1
				local nextState = util.copy(current.state)
				local okNext, retOrErr = pcall(act.next, nextState, arg, nil)
				if okNext and retOrErr ~= nil then nextState = retOrErr end
				local nextTrace = table.clone(current.trace)
				table.insert(nextTrace, {
					step = #nextTrace + 1,
					action = actionName,
					arg = util.copy(arg),
					state = util.copy(nextState),
				})
				if not okNext then
					local msg = `spec "{self.name}": action "{actionName}" errored: {tostring(retOrErr)}`
					if o.soft then
						return {
							ok = false,
							statesVisited = statesVisited,
							transitions = transitions,
							violation = msg,
							trace = nextTrace,
						}
					end
					error(`{msg}\nCounterexample trace:\n{formatTrace(nextTrace)}`, 0)
				end
				local okInv, invErr = pcall(function() self:assertInvariants(nextState) end)
				if not okInv then
					local msg = tostring(invErr)
					if o.soft then
						return {
							ok = false,
							statesVisited = statesVisited,
							transitions = transitions,
							violation = msg,
							trace = nextTrace,
						}
					end
					error(`{msg}\nCounterexample trace:\n{formatTrace(nextTrace)}`, 0)
				end
				local stateKey = canonicalKey(nextState)
				if not visited[stateKey] and statesVisited < maxStates then
					visited[stateKey] = true
					statesVisited += 1
					table.insert(queue, { state = nextState, depth = current.depth + 1, trace = nextTrace })
				end
			end
		end
	end

	return {
		ok = true,
		statesVisited = statesVisited,
		transitions = transitions,
		violation = nil,
		trace = nil,
	}
end

--- Feeds an execution trace from a Luau simulation run back into the spec, verifying every guard, transition,
--- invariant, and projected state refinement.
function Spec.verifyTrace(self: Spec, trace: { TraceEntry }, initialState: any?, sut: any?, world: any?): any
	local initFn = self.def.init
	local state = if initialState ~= nil then util.copy(initialState) elseif initFn ~= nil then (initFn()) else {}
	self:assertInvariants(state, sut, world)
	for i, entry in trace do
		local ok, nextOrErr = pcall(
			function() return self:step(state, entry.action, entry.arg, entry.result, sut, world) end
		)
		if not ok then
			error(
				`spec "{self.name}" trace verification failed at step #{i} ({entry.action}): {tostring(nextOrErr)}`,
				0
			)
		end
		state = nextOrErr
		local act = self.actions[entry.action]
		if act ~= nil and act.next ~= nil and entry.state ~= nil and not util.equal(entry.state, state, true) then
			error(
				`spec "{self.name}" state refinement mismatch at step #{i} ({entry.action}):\n`
					.. `expected spec state: {format.repr(state)}\n`
					.. `actual SUT state:    {format.repr(entry.state)}`,
				0
			)
		end
	end
	return state
end

--- Exports an execution trace through the spec as a deterministic TLA+ / Apalache-compatible JSON trace.
function Spec.toTlaJson(self: Spec, trace: { TraceEntry }, initialState: any?): string
	local initFn = self.def.init
	local state = if initialState ~= nil then util.copy(initialState) elseif initFn ~= nil then (initFn()) else {}
	local states: { any } = {
		{
			_step = 0,
			_action = "Init",
			state = util.copy(state),
		},
	}
	for i, entry in trace do
		state = self:step(state, entry.action, entry.arg, entry.result)
		table.insert(states, {
			_step = i,
			_action = entry.action,
			_arg = entry.arg,
			_result = entry.result,
			state = util.copy(if entry.state ~= nil then entry.state else state),
		})
	end
	return format.json({
		spec = self.name,
		states = states,
	})
end

return table.freeze(Spec)
