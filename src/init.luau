--!strict
--[[
Testing and deterministic simulation toolkit for Luau and Roblox.

Runs unit tests, property tests, stateful models, and multi-server simulations in standalone Luau, a headless
DataModel (`[sert.env]`), Roblox Studio, or Open Cloud. Tests run sequentially in registration order on isolated
coroutines.

```luau
local sert = require("@sert")

sert.test("math works", function()
	sert(1 + 1 == 2, "addition")
	sert.eq({ a = 1 }, { a = 1 }, "deep equality")
	sert.near(0.1 + 0.2, 0.3)
	sert.fails(function()
		error("boom")
	end, "boom")
end)

sert.prop("reverse twice is the identity", function(g: sert.Gen)
	local list = g:list(sert.gen.int(-5, 5))
	sert.eq(reverse(reverse(list)), list)
end, { runs = 200 })

sert.check("abs is non-negative", { sert.gen.int(-100, 100) }, function(n)
	sert(math.abs(n) >= 0)
end)

return {}
```
]]

local assert = require("@self/core/assert")
local bytes = require("@self/bytes")
local doubles = require("@self/doubles")
local env = require("@self/env")
local expect = require("@self/core/expect")
local format = require("@self/format")
local gen = require("@self/gen")
local laws = require("@self/laws")
local model = require("@self/model")
local prop = require("@self/prop")
local registry = require("@self/core/registry")
local rng = require("@self/rng")
local roblox = require("@self/roblox")
local runner = require("@self/core/runner")
local sim = require("@self/sim")

-- cast: Roblox's definitions type `game` as a DataModel, which the old solver will not compare with nil
local IS_ROBLOX = (game :: any) ~= nil
if not IS_ROBLOX then
	doubles.Datatypes.installGlobals()
	doubles.Datatypes.installCallerGlobals()
	registry.onRegister = doubles.Datatypes.installCallerGlobals
end

export type RunOptions = registry.RunOptions
export type PropOptions = registry.PropOptions
export type TestOptions = registry.TestOptions
export type Gen = prop.Gen
export type PropResult = prop.PropResult
export type Generator<T> = gen.Generator<T>
export type ModelSpec = model.Spec
export type ModelCommand = model.Command
export type ModelOptions = model.Options
export type CodecSpec<T = any, E = any> = laws.CodecSpec<T, E>
export type ChunkSpec<T = any, C = any> = laws.ChunkSpec<T, C>
export type OrderSpec<T = any> = laws.OrderSpec<T>
export type RegistrySpec = laws.RegistrySpec
export type RemoteSpec = laws.RemoteSpec
export type AlgebraSpec<T = any> = laws.AlgebraSpec<T>
export type DifferentialSpec<A = any, B = any> = laws.DifferentialSpec<A, B>
export type UiSpec = laws.UiSpec
export type ViewportPreset = laws.ViewportPreset
export type Env = env.Env
export type EnvNamespace = env.EnvNamespace
export type EnvOptions = env.Options
export type EnvHost = env.Host
export type EnvInput = env.Input
export type EnvKick = env.Kick
export type SimWorld = sim.World
export type SimWorldOptions = sim.WorldOptions
export type SimServer = sim.Server
export type SimClient = sim.Client
export type SimScheduler = sim.Scheduler
export type SimModelSpec = sim.ModelSpec
export type SimModelCommand = sim.ModelCommand
export type SimSpec = sim.Spec
export type SimSpecDef = sim.SpecDef
export type SimActionSpec = sim.ActionSpec
export type SimTraceEntry = sim.TraceEntry
export type SimSpecCheckOptions = sim.SpecCheckOptions
export type SimSpecCheckResult = sim.SpecCheckResult
export type RobloxConfig = roblox.Config
export type RobloxContext = roblox.Context
export type RobloxVerdict = roblox.Verdict
export type SettleOptions = roblox.SettleOptions
export type FlickerOptions = roblox.FlickerOptions
export type FlickerResult = roblox.FlickerResult
export type FloatOptions = gen.FloatOptions
export type JsonOptions = format.JsonOptions
export type Rng = rng.Rng
export type Spy = registry.Spy
export type Matchers = expect.Matchers
export type Matcher = expect.Matcher
export type MatcherResult = expect.MatcherResult
export type Results = runner.Results
export type Setup = registry.Setup
export type Current = registry.Current
export type EachOptions<T> = registry.EachOptions<T>
export type DescribeOptions = registry.DescribeOptions
export type Shard = registry.Shard

local api = registry.api
local checks = assert.api
local output = registry.output
local spy = registry.spy

local sert = {
	--[[ `true` inside Roblox and `false` under standalone Luau or Lute. ]]
	isRoblox = IS_ROBLOX,
	--[[ Roblox Studio and Open Cloud `Runner`, `Layout`, and `Flicker` helpers. ]]
	roblox = roblox,
	--[[ Standalone engine doubles (`Signal`, `Datatypes`, `Instance`, `DataStore`, `MemoryStore`, `HttpService`, `EncodingService`). ]]
	doubles = doubles,
	--[[ Composable property generators. ]]
	gen = gen,
	--[[ Seeded `xorshift32` random stream and FNV-1a hashing (`@sert/rng`). ]]
	rng = rng,
	--[[ Buffer hex formatting and byte equality assertions (`@sert/bytes`). ]]
	bytes = bytes,
	--[[ Luau value formatting (`repr`), structural diffing (`diff`), and JSON codecs (`json`, `jsonDecode`). ]]
	format = format,
	--[[ Headless Roblox DataModel, virtual clock sandbox, and runtime-adaptive datatypes and services (`new`, `active`, `current`, `configure`, `reset`, `install`, `getService`, `hooks`). ]]
	env = env :: env.EnvNamespace,
	--[[ Deterministic multi-server and multi-client simulator (`World`, `Scheduler`, `Runner`, `prop`, `model`, `vopr`, `spec`, `checkSpec`, `explore`). ]]
	sim = sim,

	-- output
	--[[ Prints values through the active test output sink so `quiet` and `capture` can intercept them. ]]
	print = output.print,
	--[[ Emits a warning through the active test output sink. ]]
	warn = output.warn,
	--[[ Runs `fn(...)` with `sert.print` and `sert.warn` output suppressed. ]]
	quiet = output.quiet,
	--[[ Runs `fn(...)` and returns the lines written to `sert.print` and `sert.warn`. ]]
	capture = output.capture,

	-- assertions
	--[[ Asserts deep equality between `v` and `expected` (honoring `__eq` on tables with metatables) and returns `v`. ]]
	eq = checks.eq,
	--[[ Asserts deep equality between `v` and `expected`, comparing raw fields of tables with metatables, and returns `v`. ]]
	rawEq = checks.rawEq,
	--[[ Asserts that `v` is not deep-equal to `unexpected` and returns `v`. ]]
	neq = checks.neq,
	--[[ Returns `true` when `a` and `b` are deep-equal under `sert.eq` without raising. ]]
	equals = checks.equals,
	--[[ Asserts that `v` and `expected` are within `eps` (default `1e-6`) component-wise and returns `v`. ]]
	near = checks.near,
	--[[ Asserts that `tostring(text)` contains the plain substring `fragment` and returns the string. ]]
	contains = checks.contains,
	--[[ Asserts that `tostring(text)` matches the Luau pattern `pattern` and returns the string. ]]
	matches = checks.matches,
	--[[ Asserts that `fn` raises an error (optionally matching `matcher`) and returns the error message. ]]
	fails = checks.fails,
	--[[ Steps up to `frames` frames (default `60`) until `done()` returns truthy. ]]
	frames = checks.frames,
	--[[ Polls `predicate()` until it returns truthy or `timeout` seconds pass (default `1`), returning the result. ]]
	waitFor = checks.waitFor,
	--[[ Wraps `value` in `[Matchers]` with `.never` negation. ]]
	expect = expect.expect,
	--[[ Adds custom matchers to `sert.expect`. ]]
	extend = expect.extend,

	-- spies
	--[[ Creates a callable `[Spy]`, optionally delegating to `impl`. ]]
	fn = spy.fn,
	--[[ Replaces `target[key]` with a `[Spy]` and restores it when the current test ends. ]]
	spy = spy.spy,

	-- registration
	--[[ Registers a test case. ]]
	test = api.test,
	--[[ Registers a Roblox-only test case (skipped under standalone Luau and Lute). ]]
	rtest = api.rtest,
	--[[ Registers a skipped test case. ]]
	skip = api.skip,
	--[[ Registers a placeholder `todo` test entry. ]]
	todo = api.todo,
	--[[ Registers a focused test case. When any test is focused, unfocused tests are skipped. ]]
	focus = api.focus,
	--[[ Registers one test per entry in `cases`. ]]
	each = api.each,
	--[[ Registers a tape-shrinking property test, or runs it immediately inside a test. ]]
	prop = api.prop,
	--[[ Registers a property test drawing arguments from one generator or a list of generators. ]]
	check = api.check,
	--[[ Registers a stateful command-sequence model test. ]]
	model = api.model,
	--[[ Groups tests and hooks under a shared name prefix (`prefix > name`). ]]
	describe = api.describe,
	--[[ Runs `fn` once before the first selected test in the current `describe` block or file. ]]
	beforeAll = api.beforeAll,
	--[[ Runs `fn` once after the last selected test in the current `describe` block or file. ]]
	afterAll = api.afterAll,
	--[[ Runs `fn` before each selected test in the current `describe` block or file. ]]
	beforeEach = api.beforeEach,
	--[[ Runs `fn` after each selected test in the current `describe` block or file. ]]
	afterEach = api.afterEach,
	--[[ Sets global `beforeAll`, `afterAll`, `beforeEach`, and `afterEach` hooks across all spec files. ]]
	setup = api.setup,
	--[[ Returns `[Current]` metadata (`{ name, file, last }`) for the running test, or `nil` outside a test. ]]
	current = api.current,
	--[[ Queues `fn` to run in LIFO order when the current test (or file `afterAll`) finishes. ]]
	defer = api.defer,
	--[[ Runs `fn` against an isolated test registry and returns `pcall` results. ]]
	isolate = api.isolate,
	--[[ Raises any load error string returned by `require` under the Luau CLI, or returns the module. ]]
	loaded = api.loaded,

	-- running
	--[[ Runs registered tests with `[RunOptions]`, prints the report, and returns `[Results]`. ]]
	run = runner.run,
	--[[ Returns the active `[Shard]` (`_G.__SERT_SHARD`) under `sert cloud`, or `nil`. ]]
	shard = runner.shard.get,
	--[[ Returns `true` when test `name` belongs to the active cloud `[Shard]`. ]]
	shardSelects = runner.shard.selects,
	--[[ Parses CLI arguments (`...`) into `[RunOptions]`. ]]
	parseCliArgs = runner.parseCliArgs,
}

-- annotated: the old solver leaves a field added after the table literal `any` otherwise
local boundLaws: laws.Laws = laws.bind(sert)
--[[ Reusable property contract suites (`codec`, `chunk`, `order`, `registry`). ]]
sert.laws = boundLaws
roblox.Runner.setDefaultSert(sert)

--[[
Asserts that `condition` is truthy (`not nil` and `not false`) and returns `condition`.
]]
return setmetatable(sert, {
	__call = function(_, condition: any, why: string?): any
		if not condition then error(why or "expected condition to be true", 2) end
		return condition
	end,
})
