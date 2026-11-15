--!strict
--[[
Testing, property shrinking, headless DataModel simulation, and Studio verification for Luau and Roblox.
]]

local assertions = require("@self/core/assert")
local bytes = require("@self/core/bytes")
local env = require("@self/env")
local format = require("@self/core/format")
local gen = require("@self/prop/gen")
local laws = require("@self/prop/laws")
local match = require("@self/core/match")
local model = require("@self/prop/model")
local perf = require("@self/core/perf")
local prop = require("@self/prop")
local registry = require("@self/core/registry")
local roblox = require("@self/roblox")
local runner = require("@self/core/runner")
local sim = require("@self/sim")
local snapshot = require("@self/core/snapshot")
local spy = require("@self/core/spy")

-- cast: Roblox's definitions type `game` as a DataModel, which the old solver will not compare with nil
local IS_ROBLOX = (game :: any) ~= nil
if not IS_ROBLOX then
	local function installCaller()
		local Datatypes = require("@self/engine/datatypes")
		registry.mutant.installCallerGlobals = Datatypes.installCallerGlobals
		Datatypes.installCallerGlobals()
	end
	registry.mutant.installCallerGlobals = installCaller
	if registry.mutant._slot.robloxGlobals or rawget(registry.mutant._sharedG, "__SERT_ROBLOX_GLOBALS") == true then
		registry.mutant._slot.robloxGlobals = true
		installCaller()
	end
end

export type Target = registry.Target
export type Mode = registry.Mode
export type Shard = registry.Shard
export type ShrinkBudget = registry.ShrinkBudget
export type RunOptions = registry.RunOptions
export type TestContext = registry.TestContext
export type TestFn = registry.TestFn
export type HookFn = registry.HookFn
export type TestOptions = registry.TestOptions
export type DescribeOptions = registry.DescribeOptions
export type Setup = registry.Setup
export type SkipReason = registry.SkipReason
export type SkippedByReason = registry.SkippedByReason
export type TautologyRecord = registry.TautologyRecord
export type ExhaustiveOption = registry.ExhaustiveOption
export type EachFormat<T> = registry.EachFormat<T>
export type BenchContext = perf.BenchContext
export type BenchOptions = perf.BenchOptions
export type Results = runner.Results
export type Failure = runner.Failure

export type Matcher = match.Matcher
export type Spy = spy.Spy
export type SpyCall = spy.Call

export type GenContext = prop.GenContext
export type Gen = prop.Gen
export type Generator<T> = gen.Generator<T>
export type FloatOptions = gen.FloatOptions
export type PropFn = prop.PropFn
export type PropOptions = prop.PropOptions
export type PropResult = prop.PropResult

export type ModelCommand<State = any, Sut = any, Arg = any, Res = any> = model.Command<State, Sut, Arg, Res>
export type ModelSpec<State = any, Sut = any> = model.Spec<State, Sut>
export type ModelOptions = model.Options
export type ModelStep = model.Step

export type Equals<T> = laws.Equals<T>
export type CodecSpec<T = any, E = any> = laws.CodecSpec<T, E>
export type OrderSpec<T = any> = laws.OrderSpec<T>
export type AlgebraSpec<T = any> = laws.AlgebraSpec<T>
export type DifferentialSpec<A = any, B = any> = laws.DifferentialSpec<A, B>
export type MetamorphicRelation<A = any, B = any> = laws.MetamorphicRelation<A, B>
export type MetamorphicSpec<A = any, B = any> = laws.MetamorphicSpec<A, B>
export type ComplexityBound = laws.ComplexityBound
export type ComplexitySpec<Input = any> = laws.ComplexitySpec<Input>

export type Env = env.Env
export type EnvNamespace = env.EnvNamespace
export type EnvOptions = env.Options
export type EnvSignalBehavior = env.SignalBehavior
export type EnvHost = env.Host
export type EnvInput = env.Input
export type EnvKick = env.Kick
export type EnvSettleOptions = env.SettleOptions

export type SimWorld = sim.World
export type SimWorldOptions = sim.WorldOptions
export type SimServer = sim.Server
export type SimClient = sim.Client
export type SimFaultConfig = sim.FaultConfig
export type SimFaults = sim.Faults
export type SimRemoteError = sim.RemoteError
export type SimCommand<State, Sut = any, Arg = any, Res = any> = sim.Command<State, Sut, Arg, Res>
export type SimSpec<State, Sut = any> = sim.Spec<State, Sut>
export type SimTraceStep = sim.TraceStep
export type SimBfsOptions = sim.BfsOptions
export type SimBfsResult = sim.BfsResult
export type SimVoprOptions = sim.VoprOptions
export type SimCheckOptions = sim.CheckOptions
export type SimCheckResult = sim.CheckResult
export type SimOperation<Arg = any, Res = any> = sim.Operation<Arg, Res>
export type SimSequentialModel<State, Arg = any, Res = any> = sim.SequentialModel<State, Arg, Res>
export type LinearizeResult = sim.LinearizeResult
export type SimRecorder = sim.Recorder
export type SimOperationHandle = sim.OperationHandle
export type SimExploreOptions = sim.ExploreOptions
export type SimExploreOutcome = sim.ExploreOutcome

export type RobloxConfig = roblox.Config
export type RobloxContext = roblox.Context
export type RobloxVerdict = roblox.Verdict
export type RobloxSide = roblox.Side
export type RobloxRequest = roblox.Request
export type LayoutRect = roblox.Rect
export type PresetName = roblox.PresetName
export type ViewportPreset = roblox.ViewportPreset
export type SettleOptions = roblox.SettleOptions
export type AuditOptions = roblox.AuditOptions
export type MatrixOptions = roblox.MatrixOptions
export type FlickerOptions = roblox.FlickerOptions
export type FlickerResult = roblox.FlickerResult
export type RemoteFuzzSpec = roblox.RemoteFuzzSpec
export type SweepOptions = roblox.SweepOptions
export type SweepSnapshot = roblox.SweepSnapshot
export type ConformanceTarget = roblox.ConformanceTarget
export type ContainerKind = roblox.ContainerKind
export type ConformanceOptions = roblox.ConformanceOptions
export type ConformanceContext = roblox.ConformanceContext
export type ConformanceFn = roblox.ConformanceFn
export type ConformanceApi = roblox.ConformanceApi

export type JsonOptions = format.JsonOptions

type SimExploreFn = (
	optsOrName: string | sim.ExploreOptions | ((world: sim.World) -> ()),
	maybeFn: ((world: sim.World) -> ())?,
	maybeOpts: sim.ExploreOptions?
) -> sim.ExploreOutcome?

local api = registry.api
local output = registry.output

local publicBytes = table.freeze({
	hex = bytes.hex,
	fromHex = bytes.fromHex,
})

local publicSim: {
	Scheduler: typeof(sim.Scheduler),
	Fabric: typeof(sim.Fabric),
	spec: typeof(sim.spec),
	verifyTrace: typeof(sim.verifyTrace),
	toItfJson: typeof(sim.toItfJson),
	canonicalize: typeof(sim.canonicalize),
	linearizable: typeof(sim.linearizable),
	checkLinearizable: typeof(sim.checkLinearizable),
	recorder: typeof(sim.recorder),
	vopr: typeof(sim.vopr),
	new: typeof(sim.new),
	check: typeof(sim.check),
	explore: SimExploreFn,
} =
	sim :: any

local sert = {
	-- Runtime & Subsystems
	isRoblox = IS_ROBLOX,
	gen = gen,
	laws = laws,
	model = model,
	env = env :: env.EnvNamespace,
	sim = publicSim,
	roblox = roblox,
	bytes = publicBytes,

	-- Registration & Lifecycle
	test = api.test,
	describe = api.describe,
	prop = prop,
	beforeAll = api.beforeAll,
	afterAll = api.afterAll,
	beforeEach = api.beforeEach,
	afterEach = api.afterEach,
	defer = api.defer,
	setup = api.setup,

	-- Procedural Assertions
	ok = assertions.ok,
	eq = assertions.eq,
	ne = assertions.ne,
	equals = assertions.equals,
	lt = assertions.lt,
	le = assertions.le,
	gt = assertions.gt,
	ge = assertions.ge,
	near = assertions.near,
	matches = assertions.matches,
	contains = assertions.contains,
	throws = assertions.throws,
	doesNotThrow = assertions.doesNotThrow,
	fail = assertions.fail,
	waitFor = assertions.waitFor,

	-- Snapshots & Performance
	inlineSnapshot = snapshot.inlineSnapshot,
	snapshot = snapshot.snapshot,
	allocs = perf.allocs,
	maxAllocs = perf.maxAllocs,
	noAllocs = perf.noAllocs,
	bench = perf.bench,

	-- Asymmetric Matchers
	any = match.any,
	subset = match.subset,
	within = match.within,
	matching = match.matching,
	exact = match.exact,

	-- Spies & Spy Assertions
	spy = spy.new,
	called = assertions.called,
	calledTimes = assertions.calledTimes,
	calledWith = assertions.calledWith,

	-- Output Sink
	print = output.print,
	warn = output.warn,
	quiet = output.quiet,
	capture = output.capture,

	-- Runner Entrypoints
	run = runner.run,
	parseCliArgs = runner.parseCliArgs,
}

roblox.Runner.setDefaultSert(sert)

return setmetatable(sert, {
	__call = function<T>(_, condition: T, msg: string?): T return assertions.ok(condition, msg) end,
})
