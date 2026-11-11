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
local prop = require("@self/prop")
local registry = require("@self/core/registry")
local roblox = require("@self/roblox")
local runner = require("@self/core/runner")
local sim = require("@self/sim")
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
export type Results = runner.Results
export type Failure = runner.Failure

export type Matcher = match.Matcher
export type Spy = spy.Spy
export type SpyCall = spy.Call

export type GenContext = prop.GenContext
export type Gen = prop.Gen
export type Generator<T> = gen.Generator<T>
export type FloatOptions = gen.FloatOptions
export type PropOptions = prop.PropOptions
export type PropResult = prop.PropResult

export type ModelCommand<State = any, Sut = any, Arg = any, Res = any> = model.Command<State, Sut, Arg, Res>
export type ModelSpec<State = any, Sut = any> = model.Spec<State, Sut>
export type ModelOptions = model.Options

export type CodecSpec<T = any, E = any> = laws.CodecSpec<T, E>
export type OrderSpec<T = any> = laws.OrderSpec<T>
export type AlgebraSpec<T = any> = laws.AlgebraSpec<T>
export type DifferentialSpec<A = any, B = any> = laws.DifferentialSpec<A, B>

export type Env = env.Env
export type EnvNamespace = env.EnvNamespace
export type EnvOptions = env.Options
export type EnvSignalBehavior = env.SignalBehavior
export type EnvHost = env.Host
export type EnvInput = env.Input
export type EnvKick = env.Kick

export type SimWorld = sim.World
export type SimWorldOptions = sim.WorldOptions
export type SimServer = sim.Server
export type SimClient = sim.Client
export type SimFaultConfig = sim.FaultConfig
export type SimFaults = sim.Faults
export type SimCommand<State, Sut = any, Arg = any, Res = any> = sim.Command<State, Sut, Arg, Res>
export type SimSpec<State, Sut = any> = sim.Spec<State, Sut>
export type SimVoprOptions = sim.VoprOptions
export type SimCheckOptions = sim.CheckOptions
export type SimCheckResult = sim.CheckResult

export type RobloxConfig = roblox.Config
export type RobloxContext = roblox.Context
export type RobloxVerdict = roblox.Verdict
export type ViewportPreset = roblox.ViewportPreset
export type SettleOptions = roblox.SettleOptions
export type FlickerOptions = roblox.FlickerOptions
export type FlickerResult = roblox.FlickerResult
export type RemoteFuzzSpec = roblox.RemoteFuzzSpec
export type SweepOptions = roblox.SweepOptions

export type JsonOptions = format.JsonOptions

local api = registry.api
local output = registry.output

local publicBytes = table.freeze({
	hex = bytes.hex,
	fromHex = bytes.fromHex,
})

local sert = {
	-- Runtime & Subsystems
	isRoblox = IS_ROBLOX,
	gen = gen,
	laws = laws,
	model = model,
	env = env :: env.EnvNamespace,
	sim = sim,
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
