--!strict
-- Deterministic multi-peer simulator combining a virtual-time scheduler (`sim/scheduler.luau`),
-- choice-tree exploration, a shrinking workload runner (`sim/runner.luau`), and simulated Roblox servers
-- sharing `DataStore`, `MemoryStore`, `MessagingService`, and remotes (`sim/world.luau`, `sim/services.luau`).
local DataStoreDouble = require("./doubles/datastore")
local Model = require("./model")
local Rng = require("./rng")
local Runner = require("@self/runner")
local Scheduler = require("@self/scheduler")
local Services = require("@self/services")
local Spec = require("@self/spec")
local World = require("@self/world")
local registry = require("./core/registry")
local util = require("./util")

local Config = Scheduler.Config
local Coop = Scheduler.Coop
local Explore = Scheduler.Explore
local output = registry.output

-- The public types, so `require("@sert/sim")` is the only import a consumer needs for annotations too. Names that
-- clash across submodules take the submodule's name as a prefix (Scheduler.Options is SchedulerOptions).
export type World = World.World
export type Server = World.Server
export type Client = World.Client
export type PeerInfo = World.PeerInfo
export type RemoteError = World.RemoteError
export type FaultConfig = World.FaultConfig
export type Faults = World.Faults
export type WorldOptions = World.Options
export type Scheduler = Scheduler.Scheduler
export type Chooser = Scheduler.Chooser
export type Choice = Scheduler.Choice
export type HostHooks = Scheduler.HostHooks
export type SchedulerOptions = Scheduler.Options
export type SchedulerFailure = Scheduler.Failure
export type Op = Runner.Op
export type Ctx = Runner.Ctx
export type Workload = Runner.Workload
export type RunFailure = Runner.RunFailure
export type RunOptions = Runner.RunOptions
export type RunnerOptions = Runner.Options
export type Result = Runner.Result
export type ShrinkLimits = Runner.ShrinkLimits
export type ShrinkResult = Runner.ShrinkResult
export type ExploreLimits = Runner.ExploreLimits
export type ExploreResult = Runner.ExploreResult
export type ExplorerLimits = Scheduler.ExploreLimits
export type ExplorerFailure = Scheduler.ExploreFailure
export type ExplorerOutcome = Scheduler.ExploreOutcome
export type Backing = Scheduler.Backing
export type Config = Scheduler.Config
export type Rng = Rng.Rng
export type Spec = Spec.Spec
export type SpecDef = Spec.SpecDef
export type SimSpec = Spec.SimSpec
export type ActionSpec = Spec.ActionSpec
export type TraceEntry = Spec.TraceEntry
export type SpecCheckOptions = Spec.SpecCheckOptions
export type SpecCheckResult = Spec.SpecCheckResult
export type FailureFormatOptions = Spec.FailureFormatOptions

export type ModelCommand = {
	name: string?,
	weight: number?,
	pre: ((state: any, arg: any) -> boolean)?,
	guard: ((state: any, arg: any) -> boolean)?,
	gen: any?,
	run: (sut: any, arg: any, world: World, state: any) -> any,
	next: ((state: any, arg: any, result: any, world: World) -> ...any)?,
	post: ((state: any, sut: any, arg: any, result: any, world: World) -> ())?,
}

export type ModelSpec = {
	name: string?,
	init: ((world: World, g: any) -> (any, any?))?,
	commands: ({ ModelCommand } | { [string]: ModelCommand })?,
	actions: ({ ModelCommand } | { [string]: ModelCommand })?,
	remotes: { [string]: (world: World, player: PeerInfo, ...any) -> () }?,
	allowRemoteErrors: boolean?,
	invariant: ((state: any, sut: any, world: World) -> ())?,
	invariants: { [string]: (state: any, sut: any, world: World) -> any }?,
	never: { [string]: (state: any, sut: any, world: World) -> boolean }?,
	project: ((sut: any, world: World) -> any)?,
	spec: Spec?,
	converge: (boolean | ((state: any, sut: any, world: World) -> ()))?,
	teardown: ((sut: any, state: any, world: World) -> ())?,
	world: { [string]: any }?,
}

local Sim = {
	Config = Config,
	Coop = Coop,
	DataStore = DataStoreDouble,
	Explore = Explore,
	Hash = table.freeze({ fnv1a32 = Rng.fnv1a32 }),
	Rng = Rng,
	Runner = Runner,
	Scheduler = Scheduler,
	Spec = Spec,
	World = World,
	services = Services,
	new = World.new,
	spec = Spec.new,
	formatFailure = Spec.formatFailure,
	summary = World.summary,
}

export type Options = {
	hash: ((text: string) -> number)?,
	describeError: ((err: any) -> string)?,
	reporter: ((handler: ((event: any) -> ())?) -> ())?,
	datastore: Scheduler.Backing?,
	breath: (number | false)?,
	breathe: (() -> ())?,
}

local KEYS = { hash = true, describeError = true, reporter = true, datastore = true, breath = true, breathe = true }

--- Sets the kernel's injected dependencies. Only the given keys change.
function Sim.configure(options: Options)
	for key, value in options :: any do
		assert(KEYS[key], `Sim.configure: unknown option {tostring(key)}`)
		local config: any = Config
		config[key] = value
	end
end

-- The options Sim.prop and Sim.model pass on to the property they register (registry.PropOptions).
local PROP_KEYS = registry.PROP_OPTIONS
-- The options Sim.explore passes on to the test it registers (registry.TestOptions, and `rtest`).
local TEST_KEYS = { "rtest", table.unpack(registry.TEST_OPTIONS) }

-- The keys of `lists`, sorted.
local function keyList(lists: { { string } }): { string }
	local keys = {}
	for _, list in lists do
		for _, key in list do
			if table.find(keys, key) == nil then table.insert(keys, key) end
		end
	end
	table.sort(keys)
	return keys
end

local WORLD_KEYS = {
	"faults",
	"swarm",
	"autoRestart",
	"frame",
	"coarse",
	"wait",
	"placeId",
	"backing",
	"datastore",
	"messaging",
	"latency",
}
local TAPE_WORLD = keyList({ WORLD_KEYS, { "mode", "tapeChoices", "noteChoices" } })
local EXPLORE_WORLD = keyList({ WORLD_KEYS, { "seed" } })
local PROP_OPTIONS = keyList({ PROP_KEYS, { "name", "world", "allowErrors", "allowRemoteErrors" } })
local MODEL_OPTIONS = keyList({
	PROP_KEYS,
	{ "length", "redraw", "maxRedraws", "world", "allowErrors", "allowRemoteErrors", "verifyTrace" },
})
local SPEC_FIELDS = keyList({
	{
		"name",
		"init",
		"commands",
		"actions",
		"remotes",
		"allowRemoteErrors",
		"invariant",
		"invariants",
		"never",
		"project",
		"spec",
		"converge",
		"teardown",
		"world",
	},
})
local CHECK_SPEC_OPTIONS = keyList({ TEST_KEYS, { "name", "maxStates", "maxDepth", "samples", "seed" } })
local EXPLORE_OPTIONS = keyList({
	TEST_KEYS,
	{ "name", "world", "allowErrors", "allowRemoteErrors", "maxChoices", "maxRuns", "maxBranch", "replay" },
})

local function pick(opts: { [string]: any }, keys: { string }): { [string]: any }
	local picked = {}
	for _, key in keys do
		picked[key] = opts[key]
	end
	return picked
end

-- `(name, fn, options?)` or `(fn, options?)` (named `options.name` or `default`): the name, body and options.
local function namedCall(
	default: string,
	nameOrFn: any,
	fnOrOptions: any?,
	maybeOptions: any?
): (string, any, { [string]: any })
	if type(nameOrFn) == "string" then return nameOrFn, fnOrOptions, maybeOptions or {} end
	local opts = fnOrOptions or {}
	return opts.name or default, nameOrFn, opts
end

-- A World on scheduler `s` from the world options every entry point shares.
local function worldFor(s: any, o: { [string]: any }): any
	return World.new({
		scheduler = s,
		mode = o.mode or "random",
		faults = o.faults or "light",
		swarm = o.swarm,
		autoRestart = o.autoRestart,
		wait = o.wait,
		placeId = o.placeId,
		backing = (if o.backing == nil then true else o.backing) :: any,
		datastore = o.datastore,
		messaging = o.messaging,
		latency = o.latency,
		coarse = (if o.coarse == nil then true else o.coarse) :: boolean?,
	})
end

local function makeTapeWorld(g: any, o: { [string]: any }): any
	local worldSeed = g:int(1, 2147483647)
	local tapeChoices = if o.tapeChoices ~= nil then o.tapeChoices else true
	local chooser = if tapeChoices then Scheduler.fromGen(g, { note = o.noteChoices }) else Scheduler.seeded(worldSeed)
	local s = Scheduler.new({
		seed = worldSeed,
		random = o.mode ~= "manual",
		frame = o.frame or 0.1,
		chooser = chooser,
	})
	return worldFor(s, o)
end

-- Runs `body` with yields on the test thread refused (Scheduler.testThread), then fails on an unhandled scheduler
-- or remote error unless `allowErrors` / `allowRemoteErrors`. Returns pcall's results.
local function guarded(
	w: any,
	label: string,
	allowErrors: boolean?,
	allowRemoteErrors: boolean?,
	body: () -> ()
): (boolean, any)
	local s = w.scheduler
	s.testThread = coroutine.running()
	local ok, err = pcall(function()
		body()
		if not allowErrors then w:assertNoErrors(label) end
		if not allowErrors and not allowRemoteErrors then w:assertNoRemoteErrors(label) end
	end)
	s.testThread = nil
	return ok, err
end

--- Registers (or, inside a running test, runs at once) a tape-driven property test over a simulated `World` whose
--- scheduler choices and fault injection draw from `g`'s tape, so high-level inputs and low-level fault schedules
--- shrink together. `Sim.prop(name, fn, options?)` or `Sim.prop(fn, options?)`; fn(world, g). `options` are the
--- PropOptions, `allowErrors` and `world` (world options).
function Sim.prop(nameOrFn: string | (world: any, g: any) -> (), fnOrOptions: any?, maybeOptions: { [string]: any }?)
	local name, fn, opts = namedCall("sim.prop", nameOrFn, fnOrOptions, maybeOptions)
	registry.checkKeys("Sim.prop", "option", opts, PROP_OPTIONS)
	registry.checkKeys("Sim.prop", "world option", opts.world, TAPE_WORLD)
	local worldOpts: { [string]: any } = opts.world or {}
	local propOpts = pick(opts, PROP_KEYS)
	propOpts.runs = opts.runs or 50
	local function runSimProp(g: any)
		local w = makeTapeWorld(g, worldOpts)
		local ok, err = guarded(w, "Sim.prop", opts.allowErrors, opts.allowRemoteErrors, function() fn(w, g) end)
		if not ok then
			g:note("%s", w:summary())
			error(err, 0)
		end
	end
	registry.define("prop", name, runSimProp, propOpts)
end

local sortedKeys = util.sortedKeys

local function defineModel(
	caller: string,
	defaultFaults: string,
	nameOrSpec: any,
	maybeSpec: { [string]: any }?,
	maybeOptions: { [string]: any }?
)
	local isTable = type(nameOrSpec) == "table"
	local givenSpec: any = if isTable then nameOrSpec else maybeSpec
	local opts: { [string]: any } = (if isTable then maybeSpec else maybeOptions) or {}
	registry.checkKeys(caller, "option", opts, MODEL_OPTIONS)

	-- Unwrap a `Sim.spec` instance if passed directly
	local boundSpec: Spec.Spec? = nil
	local spec: { [string]: any }
	if type(givenSpec) == "table" and getmetatable(givenSpec) == Spec then
		local unwrapped = givenSpec :: Spec.Spec
		boundSpec = unwrapped
		spec = table.clone(unwrapped.def :: any)
	else
		spec = givenSpec
		boundSpec = spec.spec
	end

	for key in spec do
		if table.find(SPEC_FIELDS, key) == nil then
			local hint = if table.find(MODEL_OPTIONS, key) ~= nil then " (an option: pass it in options)" else ""
			error(`{caller}: unknown spec field {tostring(key)}{hint}`, 2)
		end
	end
	local worldOpts: { [string]: any } = table.clone(opts.world or spec.world or {})
	if worldOpts.faults == nil then worldOpts.faults = defaultFaults end
	registry.checkKeys(caller, "world option", worldOpts, TAPE_WORLD)

	local invariantFn: ((any, any, any) -> ())? = spec.invariant
	local neverMap: { [string]: (any, any?, any?) -> boolean }? = spec.never
		or (if boundSpec then boundSpec.def.never else nil)
	local invMap: { [string]: (any, any?, any?) -> any }? = spec.invariants
		or (if boundSpec then boundSpec.def.invariants else nil)
	local neverKeys = sortedKeys(neverMap)
	local invKeys = sortedKeys(invMap)
	local projectFn: ((any, any) -> any)? = spec.project or (if boundSpec then boundSpec.def.project else nil)
	local remotesMap: { [string]: Spec.RemoteHandler }? = spec.remotes
		or (if boundSpec then boundSpec.def.remotes else nil)
	local allowRemoteErrors: boolean = if opts.allowRemoteErrors ~= nil
		then opts.allowRemoteErrors == true
		elseif spec.allowRemoteErrors ~= nil then spec.allowRemoteErrors == true
		elseif boundSpec ~= nil then boundSpec.allowRemoteErrors
		else false
	local initFn: (any, any) -> (any, any?) = spec.init
		or (if boundSpec and boundSpec.def.init then boundSpec.def.init else function() return {}, {} end)
	local specName = if isTable then (spec.name or string.lower(caller)) else nameOrSpec

	local convergeFn: (any, any, any) -> () = spec.converge
	local hasConvergeFn = type(spec.converge) == "function"
	local teardownFn: (any, any, any) -> ...any = spec.teardown
	local stepCount = opts.length or 15
	local rawCommands: { [any]: any } = spec.commands or spec.actions
	assert(type(rawCommands) == "table", `{caller}: spec must define commands or actions`)
	if rawCommands[1] ~= nil then
		local named: { [number]: { [string]: any } } = table.clone(rawCommands)
		for i, cmd in named do
			local copy: { [string]: any } = if type(cmd) == "function" then { run = cmd } else table.clone(cmd)
			if copy.name == nil then copy.name = `cmd{i}` end
			named[i] = copy
		end
		rawCommands = named
	end
	-- Normalize `guard` -> `pre` for Spec actions
	local normalizedMap: { [any]: any } = {}
	for k, cmd in rawCommands do
		local c: { [string]: any } = if type(cmd) == "function" then { run = cmd } else table.clone(cmd)
		if c.pre == nil and c.guard ~= nil then c.pre = c.guard end
		if c.run == nil and type(c.next) == "function" then c.run = function() end end
		normalizedMap[k] = c
	end
	local commands = Model.commandList({ commands = normalizedMap }, caller)

	-- Auto-construct a pure `Spec` for trace refinement if `boundSpec` wasn't passed
	if boundSpec == nil and opts.verifyTrace == true then
		boundSpec = Spec.new({
			name = specName,
			init = function() return (initFn(nil :: any, nil :: any)) end,
			actions = rawCommands :: any,
			remotes = remotesMap,
			allowRemoteErrors = allowRemoteErrors,
			never = neverMap,
			invariants = invMap,
			invariant = invariantFn,
			project = projectFn,
		})
	end

	local needTraceVerify = boundSpec ~= nil and opts.verifyTrace ~= false

	local currentWorld: any = nil
	local currentState: any = nil
	local currentSut: any = nil
	local initialSpecState: any = nil

	local function checkAllInvariants(state: any, sut: any, w: any)
		local checkState = if projectFn ~= nil then projectFn(sut, w) else state
		Spec.checkInvariants(specName, neverMap, neverKeys, invMap, invKeys, invariantFn, checkState, sut, w)
	end

	local adaptedCommands: { any } = {}
	for _, cmd in commands do
		local rawGen: any = cmd.gen
		local genFn: ((any, any) -> any)? = if type(rawGen) == "table"
			then if type((rawGen :: { draw: any }).draw) == "function"
				then function(g: any) return ((rawGen :: { draw: (any) -> any }).draw)(g) end
				else function(g: any) return g:pick(rawGen :: { any }) end
			elseif type(rawGen) == "function" then function(g: any, _state: any)
				return (rawGen :: (any, any) -> any)(g, currentState)
			end
			else nil
		local preFn: ((any, any) -> boolean)? = cmd.pre
		local nextFn: ((any, any, any, any) -> any)? = cmd.next
		local postFn: ((any, any, any, any, any) -> ())? = cmd.post
		local runFn: (any, any, any, any) -> any = cmd.run
		local cmdName: string = cmd.name
		table.insert(adaptedCommands, {
			name = cmdName,
			weight = cmd.weight,
			gen = genFn,
			pre = if preFn ~= nil
				then function(_state: any, arg: any): boolean return preFn(currentState, arg) end
				else nil,
			run = function(sut: any, arg: any, _state: any): any
				currentWorld:maybeCrashStep()
				local res = runFn(sut, arg, currentWorld, currentState)
				if needTraceVerify then
					local projected = if projectFn ~= nil then projectFn(sut, currentWorld) else nil
					currentWorld:action(cmdName, arg, projected, res)
				else
					local step = #currentWorld.actions + 1
					table.insert(currentWorld.actions, {
						step = step,
						t = currentWorld.scheduler.now,
						action = cmdName,
						arg = arg,
						result = res,
					})
					currentWorld:trace(`action #{step} {cmdName}`)
				end
				if not opts.allowErrors and not allowRemoteErrors then currentWorld:assertNoRemoteErrors(caller) end
				return res
			end,
			next = if nextFn ~= nil
				then function(state: any, arg: any, result: any): any
					local nextSt = nextFn(currentState, arg, result, currentWorld)
					if nextSt ~= nil then
						state = nextSt
					else
						state = currentState
					end
					currentState = state
					return state
				end
				else nil,
			post = if postFn ~= nil
				then function(_state: any, arg: any, result: any)
					postFn(currentState, currentSut, arg, result, currentWorld)
				end
				else nil,
		})
	end

	local hasInvariants = invariantFn ~= nil or #neverKeys > 0 or #invKeys > 0

	local function runSimModel(g: any)
		local w = makeTapeWorld(g, worldOpts)
		Spec.attachRemotes(remotesMap, w)
		currentWorld = w
		currentState = nil
		currentSut = nil
		initialSpecState = nil
		local initialized = false

		local adaptedSpec: Model.Spec = {
			init = function(): any
				local state, sut = initFn(w, g)
				if state == nil then state = {} end
				currentState = state
				currentSut = if sut ~= nil then sut else state
				initialSpecState = if needTraceVerify then util.copy(state) else nil
				initialized = true
				return currentState
			end,
			setup = function(): any return currentSut end,
			commands = adaptedCommands,
			invariant = if hasInvariants
				then function(_state: any, sut: any) checkAllInvariants(currentState, sut, w) end
				else nil,
		}

		local runner = Model.property(adaptedSpec, {
			length = stepCount,
			redraw = opts.redraw,
			maxRedraws = opts.maxRedraws,
		})

		local ok, err = guarded(w, caller, opts.allowErrors, allowRemoteErrors, function()
			local runOk, runErr = pcall(function()
				runner(g)
				if spec.converge then
					w:converge({ allowErrors = opts.allowErrors })
					if hasConvergeFn then convergeFn(currentState, currentSut, w) end
					if hasInvariants then checkAllInvariants(currentState, currentSut, w) end
				end
				if boundSpec ~= nil and opts.verifyTrace ~= false and #w.actions > 0 then
					boundSpec:verifyTrace(w.actions, initialSpecState)
				end
			end)
			if teardownFn ~= nil and initialized then
				local tdOk, tdErr = pcall(teardownFn, currentSut, currentState, w)
				if runOk and not tdOk then
					runOk, runErr = false, tdErr
				end
			end
			if not runOk then error(runErr, 0) end
		end)
		if not ok then
			local formatted = Spec.formatFailure({
				specName = specName,
				err = err,
				world = w,
				seed = opts.seed or g.seed,
				steps = stepCount,
				actions = w.actions,
			})
			g:note("%s", w:summary())
			error(formatted, 0)
		end
	end

	local propOpts = pick(opts, PROP_KEYS)
	propOpts.runs = opts.runs or (if registry.inline() then 25 else 40)
	propOpts.size = opts.size or stepCount
	registry.define("prop", specName, runSimModel, propOpts)
end

--- Registers (or, inside a running test, runs at once) a tape-driven stateful model test over a simulated `World`,
--- built on `model.luau`'s `g:list` step spans and `Prop.hint` so shrinking can delete whole command+simulation steps
--- cleanly. `Sim.model(name, spec, options?)` or `Sim.model(spec, options?)`. `spec.init(world, g)` returns
--- `(state, sut)`; commands receive `(sut, arg, world, state)`; `spec.invariant(state, sut, world)` runs after every
--- step. When `spec.converge` is provided, `world:converge()` and `spec.converge(state, sut, world)` run after all
--- steps. `options` are the PropOptions, `length` (15), `redraw`, `maxRedraws`, `allowErrors` and `world` (world
--- options, which may sit in `spec.world` instead).
function Sim.model(nameOrSpec: any, maybeSpec: { [string]: any }?, maybeOptions: { [string]: any }?)
	defineModel("Sim.model", "light", nameOrSpec, maybeSpec, maybeOptions)
end

--- Registers (or runs at once) a VOPR simulation test (`faults = "vopr"`, swarm fault matrix with all 7 distributed
--- hazards, negative `never` invariants, and automatic trace refinement when given a `Sim.spec`).
--- Accepts either a `ModelSpec`/`Spec` table (`Sim.vopr(name?, spec, options?)`) or a property callback
--- (`Sim.vopr(name?, fn(world, g), options?)`).
function Sim.vopr(nameOrSpecOrFn: any, maybeSpecOrFnOrOpts: any?, maybeOptions: { [string]: any }?)
	local firstIsString = type(nameOrSpecOrFn) == "string"
	local target = if firstIsString then maybeSpecOrFnOrOpts else nameOrSpecOrFn
	if type(target) == "function" then
		local name, fn, opts = namedCall("sim.vopr", nameOrSpecOrFn, maybeSpecOrFnOrOpts, maybeOptions)
		local clonedOpts = table.clone(opts)
		clonedOpts.steps = nil
		local worldOpts = table.clone(clonedOpts.world or {})
		if worldOpts.faults == nil then worldOpts.faults = "vopr" end
		clonedOpts.world = worldOpts
		Sim.prop(name, fn, clonedOpts)
		return
	end
	local rawOpts = if firstIsString then maybeOptions else maybeSpecOrFnOrOpts
	if type(rawOpts) == "table" and rawOpts.steps ~= nil then
		local mappedOpts = table.clone(rawOpts)
		if mappedOpts.length == nil then mappedOpts.length = mappedOpts.steps end
		mappedOpts.steps = nil
		if firstIsString then
			maybeOptions = mappedOpts
		else
			maybeSpecOrFnOrOpts = mappedOpts
		end
	end
	defineModel("Sim.vopr", "vopr", nameOrSpecOrFn, maybeSpecOrFnOrOpts, maybeOptions)
end

--- Registers (or runs at once) a standalone TLA+-style state-space check on `spec` (`spec:check(options)`),
--- verifying `never` and `invariants` across reachable states before Luau implementation.
function Sim.checkSpec(nameOrSpec: any, maybeSpecOrOpts: any?, maybeOptions: { [string]: any }?)
	local isSpecTable = type(nameOrSpec) == "table"
	local rawSpec = if isSpecTable then nameOrSpec else maybeSpecOrOpts
	local opts: { [string]: any } = (if isSpecTable then maybeSpecOrOpts else maybeOptions) or {}
	registry.checkKeys("Sim.checkSpec", "option", opts, CHECK_SPEC_OPTIONS)
	local specObj: Spec.Spec = if getmetatable(rawSpec) == Spec then rawSpec else Spec.new(rawSpec)
	local name = if isSpecTable then (opts.name or specObj.name) else nameOrSpec
	local checkOpts: Spec.SpecCheckOptions = {
		maxStates = opts.maxStates,
		maxDepth = opts.maxDepth,
		samples = opts.samples,
		seed = opts.seed,
	}
	registry.define("test", name, function() specObj:check(checkOpts) end, pick(opts, TEST_KEYS))
end

--- Registers (or, inside a running test, runs at once) a bounded-exhaustive choice-tree exploration test
--- (`Explore.run`) over a coarse random-mode `World`. `Sim.explore(name, fn, options?)` or
--- `Sim.explore(fn, options?)`; fn(world). A failure names its choice path: `options.replay` set to that path reruns
--- only it, in the same world.
function Sim.explore(nameOrFn: string | (world: any) -> (), fnOrOptions: any?, maybeOptions: { [string]: any }?)
	local name, fn, opts = namedCall("sim.explore", nameOrFn, fnOrOptions, maybeOptions)
	registry.checkKeys("Sim.explore", "option", opts, EXPLORE_OPTIONS)
	registry.checkKeys("Sim.explore", "world option", opts.world, EXPLORE_WORLD)
	local wOpts: { [string]: any } = opts.world or {}
	local lastSummary = ""
	local function body(chooser: Scheduler.Chooser)
		local s = Scheduler.new({
			seed = wOpts.seed or 1,
			random = true,
			frame = wOpts.frame or 0.1,
			chooser = chooser,
		})
		local w = worldFor(s, wOpts)
		local ok, err = guarded(w, "Sim.explore", opts.allowErrors, opts.allowRemoteErrors, function() fn(w) end)
		if not ok then
			lastSummary = w:summary()
			error(err, 0)
		end
	end
	local function runExplore()
		local replay: { number }? = opts.replay
		if replay ~= nil then
			local ok, err = pcall(function() body(Scheduler.replay(replay)) end)
			if not ok then error(`Sim.explore failed on replay: {tostring(err)}\n{lastSummary}`, 0) end
			return
		end
		local outcome = Explore.run(body, {
			maxChoices = opts.maxChoices or 16,
			maxRuns = opts.maxRuns or 128,
			maxBranch = opts.maxBranch or 3,
		})
		local failure = outcome.failure
		if failure ~= nil then
			local path = table.concat(failure.choices, ", ")
			error(
				`Sim.explore failed on run {outcome.runs} (rerun it alone with replay = \{ {path} \}): `
					.. `{tostring(failure.error)}\n{lastSummary}`,
				0
			)
		elseif outcome.limit ~= nil then
			output.print(
				`Sim.explore "{name}": stopped at {outcome.limit} after {outcome.runs} runs, so only those passed; `
					.. `raise {outcome.limit} or shrink the configuration`
			)
		end
	end
	registry.define("test", name, runExplore, pick(opts, TEST_KEYS))
end

return table.freeze(Sim)
