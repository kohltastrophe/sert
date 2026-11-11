--!strict
-- Deterministic multi-peer simulation, VOPR fault injection, and bounded state-space checking (`sert.sim`).

local Fabric = require("@self/fabric")
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
	runOptions: registry.RunOptions?
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

	local propOpts: any = {
		runs = opts.runs or 50,
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
	end, propOpts, effectiveRunOpts, true, name)

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
			local ok, report = runVoprSuite(name, spec, options, registry.currentOptions())
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
Sim.vopr = voprApi

--- Creates a new deterministic simulation `World`.
function Sim.new(options: WorldOptions?): World return World.new(options) end

--- Runs bounded BFS state-space model checking and/or VOPR execution on `spec` immediately.
function Sim.check<State, Sut>(spec: Spec<State, Sut>, options: CheckOptions?): CheckResult
	Spec.define(spec)
	local o: CheckOptions = options or {}
	local bfsRes: BfsResult? = nil

	local doBfs = if o.bfs ~= nil then o.bfs else (o.replay == nil and hasFiniteModel(spec))
	if doBfs then bfsRes = Spec.bfsCheck(spec, {
		maxStates = o.maxStates,
		maxDepth = o.maxDepth,
	}) end

	local doVopr = if o.vopr ~= nil then o.vopr else (hasRuntimeCommands(spec) or o.replay ~= nil or o.runs ~= nil)
	local cases = 0
	if doVopr then
		local ok, report, ranCases = runVoprSuite(spec.name or "Sim.check", spec, o, registry.currentOptions())
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

export type ExploreOptions = Scheduler.ExploreLimits & WorldOptions

--- Exhaustively explores bounded scheduler decision prefixes of `fn(world)`.
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

	local failedWorld: World? = nil
	local outcome = Scheduler.explore(function(chooser: Scheduler.Chooser)
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
		maxRuns = opts.maxRuns,
		maxBranch = opts.maxBranch,
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
