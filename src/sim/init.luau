--!strict
-- Deterministic multi-peer simulation, VOPR fault injection, and bounded state-space checking (`sert.sim`).

local Fabric = require("@self/fabric")
local Linearize = require("@self/linearize")
local Scheduler = require("./engine/scheduler")
local Spec = require("@self/spec")
local World = require("@self/world")
local format = require("./core/format")
local prop = require("./prop")
local registry = require("./core/registry")
local util = require("./core/util")

export type World = World.World
export type Server = World.Server
export type Client = World.Client
export type WorldOptions = World.Options
export type FaultConfig = World.FaultConfig
export type Faults = World.Faults
export type RemoteError = World.RemoteError

export type Command<State, Sut = any, Arg = any, Res = any> = Spec.Command<State, Sut, Arg, Res>
export type Spec<State, Sut = any> = Spec.Spec<State, Sut>
export type TraceStep = Spec.TraceStep
export type BfsOptions = Spec.BfsOptions
export type BfsResult = Spec.BfsResult

export type Operation<Arg = any, Res = any> = Linearize.Operation<Arg, Res>
export type SequentialModel<State, Arg = any, Res = any> = Linearize.SequentialModel<State, Arg, Res>
export type LinearizeResult = Linearize.LinearizeResult
export type Recorder = Linearize.Recorder
export type OperationHandle = Linearize.OperationHandle
export type ExploreOutcome = Scheduler.ExploreOutcome

local MUTANT_SIM_RUNS = 3
local MUTANT_SIM_MAX_STATES = 20
local MUTANT_SIM_EXPLORE_RUNS = 3

local function isMutantActive(runOptions: registry.RunOptions?, optCap: boolean?): boolean
	if optCap == false then return false end
	return (runOptions ~= nil and (runOptions.mutant ~= nil or runOptions.mutants ~= nil))
		or (registry.isolateDepth == 0 and registry.mutant.get() ~= nil)
end

export type VoprOptions = {
	runs: number?,
	steps: number?,
	minSteps: number?,
	size: number?,
	seed: number?,
	replay: (number | string)?,
	faults: (string | FaultConfig | { [string]: any })?,
	swarm: boolean?,
	converge: boolean?,
	shrinkBudget: registry.ShrinkBudget?,
	timeout: number?,
	capMutant: boolean?,
}

export type CheckOptions = VoprOptions & BfsOptions & {
	bfs: boolean?,
	vopr: boolean?,
}

export type CheckResult = {
	states: number,
	depth: number,
	truncated: boolean,
	bfs: BfsResult?,
	cases: number,
}

local function simplerTape(a: { number }, b: { number }): boolean
	if #a ~= #b then return #a < #b end
	for i = 1, #a do
		if a[i] ~= b[i] then return a[i] < b[i] end
	end
	return false
end

local function encodeReplayToken(seed: number, tape: { number }, size: number): string
	local parts = table.create(#tape)
	for i, v in tape do
		parts[i] = tostring(v)
	end
	return `v1:{seed}:{size}:{table.concat(parts, ",")}`
end

local function decodeReplayToken(token: string): (number?, number?, { number }?)
	local seedStr, sizeStr, rest = string.match(token, "^v1:(%d+):(%d+):(.*)$")
	if seedStr == nil or sizeStr == nil or rest == nil then return nil, nil, nil end
	local seed = tonumber(seedStr)
	local size = tonumber(sizeStr)
	if seed == nil or size == nil then return nil, nil, nil end
	local tape: { number } = {}
	if #rest > 0 then
		for numStr in string.gmatch(rest, "[^,]+") do
			local n = tonumber(numStr)
			if n == nil then return nil, nil, nil end
			table.insert(tape, n)
		end
	end
	return seed, size, tape
end

local function formatTraceLine(stepIdx: number, name: string, arg: any, res: any): string
	local argStr = if arg ~= nil then format.repr(arg, 3) else ""
	local resSuffix = if res ~= nil then ` -> {format.repr(res, 2)}` else ""
	return string.format("#%d %s(%s)%s", stepIdx, name, argStr, resSuffix)
end

local function hasRuntimeCommands<State, Sut>(spec: Spec<State, Sut>): boolean
	if spec.setup ~= nil then return true end
	for _, cmd in next, spec.commands do
		if cmd.run ~= nil then return true end
	end
	return false
end

local function hasFiniteModel<State, Sut>(spec: Spec<State, Sut>): boolean
	for _, cmd in next, spec.commands do
		if cmd.gen ~= nil and cmd.args == nil then return false end
	end
	return true
end

-- Executes a single stateful VOPR trial driven by `g` (`GenContext`), without formatting `w:summary()` on failure.
local function executeVoprTrial<State, Sut>(spec: Spec<State, Sut>, opts: VoprOptions, g: any): (World, { string })
	local maxSteps = opts.steps or 25
	local minSteps = math.min(opts.minSteps or 1, maxSteps)
	local baseWorldOpts: WorldOptions = if spec.world ~= nil then table.clone(spec.world) else {}
	local faultSpec = if opts.faults ~= nil
		then opts.faults
		elseif baseWorldOpts.faults ~= nil then baseWorldOpts.faults
		else "vopr"

	local s = Scheduler.new({
		seed = g.seed or 1,
		random = true,
		frame = baseWorldOpts.frame,
		chooser = Scheduler.fromGen(g),
	})

	baseWorldOpts.scheduler = s
	baseWorldOpts.mode = "random"
	baseWorldOpts.seed = g.seed or 1
	baseWorldOpts.faults = faultSpec
	if opts.swarm ~= nil then baseWorldOpts.swarm = opts.swarm end

	local w = World.new(baseWorldOpts)
	local cmdNames = Spec.commandNames(spec)
	local stepTrace: { string } = {}

	local state: State = util.copy(spec.init())
	local sut: Sut = if spec.setup ~= nil then spec.setup(w) else w :: any

	local okTrial, trialErr = pcall(function()
		Spec.checkInvariants(spec, state, sut, w)

		local stepCount = g:int(minSteps, maxSteps)
		for stepIdx = 1, stepCount do
			-- Collect commands whose `pre` could be satisfied (for commands without `arg`-dependent `pre`, filter upfront).
			local weightedChoices: { { any } } = {}
			for _, name in cmdNames do
				local cmd = spec.commands[name]
				local weight = math.max(1, math.floor(cmd.weight or 1))
				local row: { any } = { weight, name }
				table.insert(weightedChoices, row)
			end
			if #weightedChoices == 0 then break end

			local chosenName: string? = nil
			local chosenArg: any = nil
			local chosenCmd: Command<State, Sut, any, any>? = nil

			for _attempt = 1, 6 do
				local candName: string = if #weightedChoices == 1
					then weightedChoices[1][2]
					else g:weighted(weightedChoices)
				local cand = spec.commands[candName]
				local arg: any = nil
				if cand.gen ~= nil then
					arg = cand.gen(util.copy(state), g)
				elseif type(cand.args) == "function" then
					local list = (cand.args :: (State) -> { any })(state)
					if #list > 0 then arg = g:pick(list) end
				elseif type(cand.args) == "table" and #(cand.args :: { any }) > 0 then
					arg = g:pick(cand.args :: { any })
				end
				if cand.pre == nil or cand.pre(state, arg) then
					chosenName = candName
					chosenArg = arg
					chosenCmd = cand
					break
				end
			end

			if chosenName == nil or chosenCmd == nil then continue end

			local res: any = nil
			if chosenCmd.run ~= nil then res = chosenCmd.run(sut, util.copy(chosenArg), w) end
			s:drain()

			local working = util.copy(state)
			local produced = chosenCmd.next(working, util.copy(chosenArg), util.copy(res))
			state = if produced ~= nil then produced else working

			local projected = if spec.project ~= nil then spec.project(sut, w) else nil
			w:action(chosenName, chosenArg, projected or state, res)
			table.insert(stepTrace, formatTraceLine(stepIdx, chosenName, chosenArg, res))

			if chosenCmd.post ~= nil then chosenCmd.post(state, sut, chosenArg, res, w) end
			Spec.checkInvariants(spec, state, sut, w)

			-- Inject between-step VOPR server crashes and spontaneous rolling shutdowns.
			w:maybeCrashStep()
			w:maybeRollingShutdown()
		end

		local shouldConverge = if opts.converge ~= nil then opts.converge else spec.converge
		if shouldConverge ~= false then
			if type(spec.converge) == "function" then
				spec.converge(state, sut, w)
			else
				w:converge()
			end
			Spec.checkInvariants(spec, state, sut, w)
		end

		w:assertNoErrors(spec.name or "Sim.vopr")
		w:assertNoRemoteErrors(spec.name or "Sim.vopr")
	end)

	if spec.teardown ~= nil then
		local okTd, tdErr = pcall(spec.teardown :: (...any) -> ...any, sut, w)
		if okTrial and not okTd then
			okTrial = false
			trialErr = tdErr
		end
	end

	if not okTrial then error({ err = trialErr, world = w, steps = stepTrace }, 0) end
	return w, stepTrace
end

local function runVoprSuite<State, Sut>(
	name: string,
	spec: Spec<State, Sut>,
	options: VoprOptions?,
	runOptions: registry.RunOptions?,
	capMutant: boolean?
): (boolean, string?, number)
	Spec.define(spec)
	local opts: VoprOptions = options or {}
	local size = opts.size or 40
	local replaySpec = if opts.replay ~= nil then opts.replay elseif runOptions ~= nil then runOptions.replay else nil

	-- Fast-path exact string replay token (`{ replay = "v1:<seed>:<size>:<tape>" }`): runs 1 trial with zero shrinking.
	if type(replaySpec) == "string" then
		local rSeed, rSize, rTape = decodeReplayToken(replaySpec)
		if rSeed == nil or rSize == nil or rTape == nil then
			error(`Sim: malformed replay token {format.repr(replaySpec)}`, util.outside())
		end
		local g = prop.gen(rSeed, rSize, rTape)
		local ok, rawPayload: any = pcall(function(): nil
			executeVoprTrial(spec, opts, g)
			return nil
		end)
		if ok then return true, nil, 1 end
		local errText = if type(rawPayload) == "table" and rawPayload.err ~= nil
			then format.errorText(rawPayload.err)
			else format.errorText(rawPayload)
		local lines = {
			`VOPR counterexample in "{name}": {errText}`,
		}
		if type(rawPayload) == "table" then
			local steps: { string } = rawPayload.steps or {}
			if #steps > 0 then
				table.insert(lines, "Steps:")
				for _, st in steps do
					table.insert(lines, `  {st}`)
				end
			end
			if rawPayload.world ~= nil then
				-- Format `w:summary()` ONCE on the replayed counterexample.
				local worldSummary: string = (rawPayload.world :: World):summary()
				table.insert(lines, worldSummary)
			end
		end
		table.insert(lines, `Replay: \{ replay = "{replaySpec}" \}`)
		return false, table.concat(lines, "\n"), 1
	end

	-- Track ONLY lightweight pointers during trial & shrink probes; NEVER call `w:summary()` until shrinking completes!
	local bestTape: { number }? = nil
	local bestWorld: World? = nil
	local bestSteps: { string }? = nil
	local bestErrText: string? = nil

	local effectiveRuns = opts.runs or 50
	local effectiveCap = capMutant == true and opts.capMutant ~= false
	if effectiveCap and isMutantActive(runOptions, opts.capMutant) then
		effectiveRuns = math.min(effectiveRuns, MUTANT_SIM_RUNS)
	end

	local propOpts: any = {
		runs = effectiveRuns,
		size = size,
		seed = opts.seed,
		shrinkBudget = opts.shrinkBudget,
	}

	local effectiveRunOpts: any = if runOptions ~= nil then table.clone(runOptions) else {}
	if type(replaySpec) == "number" then effectiveRunOpts.replay = replaySpec end

	local res = prop.run(name, function(g: any)
		local ok, rawPayload: any = pcall(function(): nil
			executeVoprTrial(spec, opts, g)
			return nil
		end)
		if not ok then
			local currentTape = prop.tape(g)
			local innerErr = if type(rawPayload) == "table" and rawPayload.err ~= nil
				then rawPayload.err
				else rawPayload
			local msg = format.errorText(innerErr)
			if bestTape == nil or simplerTape(currentTape, bestTape) then
				bestTape = currentTape
				bestErrText = msg
				if type(rawPayload) == "table" then
					bestWorld = rawPayload.world
					bestSteps = rawPayload.steps
				end
			end
			error(msg, 0)
		end
	end, propOpts, effectiveRunOpts, effectiveCap, name)

	if res.ok then return true, nil, res.cases end

	local finalTape = (res :: any).shrunk or bestTape or {}
	local finalSeed = res.seed or opts.seed or 1
	local token = encodeReplayToken(finalSeed, finalTape, size)
	local lines = {
		`VOPR counterexample in "{name}": {bestErrText or res.message or "failed"}`,
	}
	if bestSteps ~= nil and #bestSteps > 0 then
		table.insert(lines, "Shrunk steps:")
		for _, st in bestSteps do
			table.insert(lines, `  {st}`)
		end
	end
	if bestWorld ~= nil then
		-- Format `w:summary()` ONLY ONCE on the final shrunk counterexample!
		table.insert(lines, bestWorld:summary())
	end
	table.insert(lines, `Replay: \{ replay = "{token}" \}`)
	return false, table.concat(lines, "\n"), res.cases
end

local function makeVoprRegistrar(target: registry.Target?, mode: registry.Mode?, focus: boolean)
	return function<State, Sut>(name: string, spec: Spec<State, Sut>, options: VoprOptions?)
		Spec.define(spec)
		if mode == "skip" then
			local skipFn = if target == "roblox"
				then registry.api.test.roblox.skip
				elseif target == "server" then registry.api.test.server.skip
				elseif target == "client" then registry.api.test.client.skip
				else registry.api.test.skip
			skipFn(name)
			return
		end

		local testOpts: registry.TestOptions? = if options ~= nil and options.timeout ~= nil
			then { timeout = options.timeout }
			else nil
		local body = function()
			local ok, report = runVoprSuite(name, spec, options, registry.currentOptions(), true)
			if not ok then error(report or "Sim.vopr failed", 0) end
		end

		if focus then
			if target == "roblox" then
				registry.api.test.roblox.focus(name, body, testOpts)
			elseif target == "server" then
				registry.api.test.server.focus(name, body, testOpts)
			elseif target == "client" then
				registry.api.test.client.focus(name, body, testOpts)
			else
				registry.api.test.focus(name, body, testOpts)
			end
		else
			if target == "roblox" then
				registry.api.test.roblox(name, body, testOpts)
			elseif target == "server" then
				registry.api.test.server(name, body, testOpts)
			elseif target == "client" then
				registry.api.test.client(name, body, testOpts)
			else
				registry.api.test(name, body, testOpts)
			end
		end
	end
end

local voprApi: any = setmetatable({
	skip = makeVoprRegistrar(nil, "skip", false),
	focus = makeVoprRegistrar(nil, "run", true),
	roblox = setmetatable({
		skip = makeVoprRegistrar("roblox", "skip", false),
		focus = makeVoprRegistrar("roblox", "run", true),
	}, {
		__call = function(_self: any, name: string, spec: any, options: VoprOptions?)
			return makeVoprRegistrar("roblox", nil, false)(name, spec, options)
		end,
	}),
	server = setmetatable({
		skip = makeVoprRegistrar("server", "skip", false),
		focus = makeVoprRegistrar("server", "run", true),
	}, {
		__call = function(_self: any, name: string, spec: any, options: VoprOptions?)
			return makeVoprRegistrar("server", nil, false)(name, spec, options)
		end,
	}),
	client = setmetatable({
		skip = makeVoprRegistrar("client", "skip", false),
		focus = makeVoprRegistrar("client", "run", true),
	}, {
		__call = function(_self: any, name: string, spec: any, options: VoprOptions?)
			return makeVoprRegistrar("client", nil, false)(name, spec, options)
		end,
	}),
}, {
	__call = function(_self: any, name: string, spec: any, options: VoprOptions?)
		return makeVoprRegistrar(nil, nil, false)(name, spec, options)
	end,
})

local Sim = {}

Sim.Scheduler = Scheduler
Sim.Fabric = Fabric
Sim.spec = Spec.define
Sim.verifyTrace = Spec.verifyTrace
Sim.toItfJson = Spec.toItfJson
Sim.canonicalize = Spec.canonicalize
Sim.linearizable = Linearize.linearizable
Sim.checkLinearizable = Linearize.check
Sim.recorder = Linearize.recorder
Sim.vopr = voprApi

--- Creates a new deterministic simulation `World`.
function Sim.new(options: WorldOptions?): World return World.new(options) end

--- Runs bounded BFS state-space model checking and/or VOPR execution on `spec` immediately.
function Sim.check<State, Sut>(spec: Spec<State, Sut>, options: CheckOptions?): CheckResult
	Spec.define(spec)
	local o: CheckOptions = options or {}
	local curRunOpts = registry.currentOptions()
	local mutantActive = isMutantActive(curRunOpts, o.capMutant)
	local bfsRes: BfsResult? = nil

	local doBfs = if o.bfs ~= nil then o.bfs else (o.replay == nil and hasFiniteModel(spec))
	if doBfs then
		local maxStates = o.maxStates
		if mutantActive then maxStates = math.min(maxStates or 2000, MUTANT_SIM_MAX_STATES) end
		bfsRes = Spec.bfsCheck(spec, {
			maxStates = maxStates,
			maxDepth = o.maxDepth,
		})
	end

	local doVopr = if o.vopr ~= nil then o.vopr else (hasRuntimeCommands(spec) or o.replay ~= nil or o.runs ~= nil)
	local cases = 0
	if doVopr then
		local ok, report, ranCases = runVoprSuite(spec.name or "Sim.check", spec, o, curRunOpts, o.capMutant ~= false)
		cases = ranCases
		if not ok then error(report or "Sim.check failed", util.outside()) end
	end

	return {
		states = if bfsRes ~= nil then bfsRes.visited else 0,
		depth = if bfsRes ~= nil then bfsRes.maxDepthReached else 0,
		truncated = if bfsRes ~= nil then bfsRes.truncated else false,
		bfs = bfsRes,
		cases = cases,
	}
end

export type ExploreOptions = WorldOptions & {
	maxChoices: number?,
	maxRuns: number?,
	maxBranch: number?,
	stateHash: (false | "backing" | ((world: World) -> (string | number)?))?,
	capMutant: boolean?,
}

local function sortedStringKeys(tbl: { [any]: any }): { any }
	local keys: { any } = {}
	for k in tbl do
		table.insert(keys, k)
	end
	table.sort(keys, function(a: any, b: any): boolean
		local ta, tb = type(a), type(b)
		if ta ~= tb then return ta < tb end
		return tostring(a) < tostring(b)
	end)
	return keys
end

--- Hashes backing DataStore, MemoryStore, MessagingService, scheduler state, and in-flight remotes of `world`.
local function defaultWorldStateHash(world: World): string
	local w: any = world
	local parts: { string } = {}
	local backing: any = w.backing

	if backing ~= nil and backing.datastore ~= nil and type(backing.datastore.stores) == "table" then
		local storeParts: { string } = {}
		local storeIds = sortedStringKeys(backing.datastore.stores)
		for _, id in storeIds do
			local handle = backing.datastore.stores[id]
			if type(handle) == "table" and type(handle.data) == "table" then
				local rowParts: { string } = {}
				for _, k in sortedStringKeys(handle.data) do
					local rawRow = handle.data[k]
					local encoded = if handle.ordered and type(rawRow) == "number"
						then Spec.canonicalize(rawRow)
						elseif type(rawRow) == "table" then Spec.canonicalize({
							v = rawRow.value,
							ver = rawRow.version,
							del = rawRow.deleted == true,
							u = rawRow.userIds,
							m = rawRow.metadata,
						})
						else Spec.canonicalize(rawRow)
					table.insert(rowParts, `{tostring(k)}={encoded}`)
				end
				if #rowParts > 0 then
					table.insert(
						storeParts,
						`{tostring(id)}({if handle.ordered then "o" else "s"}):{table.concat(rowParts, ",")}`
					)
				end
			end
		end
		table.insert(parts, `ds=[{table.concat(storeParts, ";")}]`)
	end

	local s: any = w.scheduler
	local msNow = if s ~= nil and type(s.now) == "number" then s.now else 0
	if backing ~= nil and backing.memorystore ~= nil then
		local ms = backing.memorystore
		if type(ms.now) == "number" then msNow = ms.now end
		local mapParts: { string } = {}
		if type(ms.maps) == "table" then
			for _, id in sortedStringKeys(ms.maps) do
				local m = ms.maps[id]
				if type(m) == "table" and type(m.data) == "table" then
					local entryParts: { string } = {}
					for _, k in sortedStringKeys(m.data) do
						local entry = m.data[k]
						if type(entry) == "table" and (type(entry.expiry) ~= "number" or entry.expiry > msNow) then
							local ttl = if type(entry.expiry) == "number"
								then math.round((entry.expiry - msNow) * 1e9)
								else -1
							table.insert(
								entryParts,
								`{tostring(k)}={Spec.canonicalize({ v = entry.value, sk = entry.sortKey, ttl = ttl })}`
							)
						end
					end
					if #entryParts > 0 then table.insert(mapParts, `{tostring(id)}:{table.concat(entryParts, ",")}`) end
				end
			end
		end
		local queueParts: { string } = {}
		if type(ms.queues) == "table" then
			for _, qname in sortedStringKeys(ms.queues) do
				local storage = ms.queues[qname]
				if type(storage) == "table" and type(storage.data) == "table" then
					local itemParts: { string } = {}
					for _, item in storage.data do
						if type(item) == "table" and (type(item.expiry) ~= "number" or item.expiry > msNow) then
							table.insert(
								itemParts,
								Spec.canonicalize({
									v = item.value,
									p = item.priority,
									vis = type(item.visible) == "number" and item.visible > msNow,
									rc = item.receipt ~= nil,
								})
							)
						end
					end
					if #itemParts > 0 then
						table.insert(queueParts, `{tostring(qname)}:[{table.concat(itemParts, ",")}]`)
					end
				end
			end
		end
		table.insert(parts, `ms=m[{table.concat(mapParts, ";")}]q[{table.concat(queueParts, ";")}]`)
	end

	if backing ~= nil and type(backing.messaging) == "table" then
		local bus = backing.messaging
		local subParts: { string } = {}
		if type(bus.subscriptions) == "table" then
			for _, sub in bus.subscriptions do
				if type(sub) == "table" and not sub.disconnected then
					local srvName = if sub.server ~= nil then tostring(sub.server.name) else "nil"
					table.insert(subParts, `{tostring(sub.topic)}@{srvName}`)
				end
			end
			table.sort(subParts)
		end
		local msgParts: { string } = {}
		if type(bus.queue) == "table" then
			for _, msg in bus.queue do
				if type(msg) == "table" and not msg.delivered then
					local originName = if msg.origin ~= nil then tostring(msg.origin.name) else "nil"
					table.insert(msgParts, `{tostring(msg.topic)}<-{originName}:{Spec.canonicalize(msg.data)}`)
				end
			end
		end
		table.insert(parts, `msg=s[{table.concat(subParts, ",")}];q[{table.concat(msgParts, ",")}]`)
	end

	if w.scheduler ~= nil then table.insert(parts, `sched={w.scheduler:stateDigest()}`) end

	local serverParts: { string } = {}
	if type(w.servers) == "table" then
		for _, srv in w.servers do
			if type(srv) == "table" then
				table.insert(
					serverParts,
					`{tostring(srv.name)}:{if srv.alive then "1" else "0"}:{tostring(srv.skew or 0)}`
				)
			end
		end
		table.sort(serverParts)
	end
	local remoteParts: { string } = {}
	if type(w._inflightRemotes) == "table" then
		for _, pkt in w._inflightRemotes do
			table.insert(remoteParts, Spec.canonicalize(pkt))
		end
		table.sort(remoteParts)
	end
	table.insert(
		parts,
		`net=c:{w.pendingCloud or 0};r:{w.pendingRemotes or 0};p:[{table.concat(remoteParts, ",")}];s:[{table.concat(
			serverParts,
			","
		)}]`
	)

	return table.concat(parts, "|")
end

--- Exhaustively explores bounded scheduler decision prefixes of `fn(world)`, with optional `stateHash` pruning.
--- Supports both direct `Sim.explore(opts, fn)` / `Sim.explore(fn)` and named test registration `Sim.explore(name, fn, opts?)`.
function Sim.explore(optsOrName: any, maybeFn: any?, maybeOpts: ExploreOptions?): Scheduler.ExploreOutcome?
	if type(optsOrName) == "string" then
		local name = optsOrName
		local bodyFn: (world: World) -> () = maybeFn :: any
		local opts: ExploreOptions = maybeOpts or {}
		registry.api.test(name, function() Sim.explore(opts, bodyFn) end)
		return nil
	end

	local opts: ExploreOptions
	local bodyFn: (world: World) -> ()
	if type(optsOrName) == "function" then
		opts = {} :: ExploreOptions
		bodyFn = optsOrName
	else
		opts = (optsOrName or {}) :: ExploreOptions
		bodyFn = maybeFn :: any
	end
	if type(bodyFn) ~= "function" then
		error("Sim.explore: expected callback function (world) -> ()", util.outside())
	end

	local hashOpt = opts.stateHash
	if hashOpt ~= nil and hashOpt ~= false and hashOpt ~= "backing" and type(hashOpt) ~= "function" then
		error('Sim.explore: stateHash must be false, "backing", or a function', util.outside())
	end
	registry.recordAssertion("sim.explore")

	local exploreStateHash: (() -> (string | number)?)? = nil
	local activeWorld: World? = nil
	if hashOpt ~= nil and hashOpt ~= false then
		exploreStateHash = function(): (string | number)?
			local w = activeWorld
			if w == nil then return nil end
			if hashOpt == "backing" then return defaultWorldStateHash(w) end
			local raw = (hashOpt :: (world: World) -> (string | number)?)(w)
			if raw == nil then return nil end
			return `{tostring(raw)}|{w.scheduler:stateDigest()}`
		end
	end

	local maxRuns = opts.maxRuns
	if isMutantActive(registry.currentOptions(), opts.capMutant) then
		maxRuns = math.min(maxRuns or 10000, MUTANT_SIM_EXPLORE_RUNS)
	end

	local failedWorld: World? = nil
	local outcome = Scheduler.explore(function(chooser: Scheduler.Chooser)
		activeWorld = nil
		local s = Scheduler.new({
			seed = opts.seed or 1,
			random = true,
			frame = opts.frame,
			chooser = chooser,
		})
		local wOpts: WorldOptions = table.clone(opts :: any)
		wOpts.scheduler = s
		wOpts.mode = "random"
		if wOpts.coarse == nil then wOpts.coarse = true end
		local w = World.new(wOpts)
		activeWorld = w
		local ok, err = pcall(bodyFn :: (...any) -> ...any, w)
		if ok then
			local okErr, noErrMsg = pcall(w.assertNoErrors :: (...any) -> ...any, w, "Sim.explore")
			if not okErr then
				ok = false
				err = noErrMsg
			end
		end
		if not ok then
			failedWorld = w
			error(err, 0)
		end
	end, {
		maxChoices = opts.maxChoices,
		maxRuns = maxRuns,
		maxBranch = opts.maxBranch,
		stateHash = exploreStateHash,
	})

	if outcome.failure ~= nil then
		local choiceParts = table.create(#outcome.failure.choices)
		for i, c in outcome.failure.choices do
			choiceParts[i] = tostring(c)
		end
		local summaryBlock = if failedWorld ~= nil then `\n{failedWorld:summary()}` else ""
		error(
			`Sim.explore failed on run #{outcome.runs} (choices = \{ {table.concat(choiceParts, ", ")} \}):\n`
				.. format.errorText(outcome.failure.error)
				.. summaryBlock,
			util.outside()
		)
	end

	return outcome
end

return Sim
