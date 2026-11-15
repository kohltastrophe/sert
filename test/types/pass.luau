--!strict
-- Positive type probe (`sert lint --only types`): exercises every public `sert` 0.1.0 type and function under both Luau solvers.
local sert = require("../../src")

-- Exported top-level type aliases
local _target: sert.Target = "portable"
local _mode: sert.Mode = "run"
local shard: sert.Shard = { name = "1/2", index = 1, count = 2, runLimit = 0, only = { "a" }, except = { "b" } }
local budget: sert.ShrinkBudget = { tries = 100, seconds = 2 }
local testOpts: sert.TestOptions = { timeout = 5, skip = false, focus = false, file = "Pass.spec", target = "portable" }
local descOpts: sert.DescribeOptions =
	{ separator = " / ", file = "Pass.spec", target = "portable", skip = false, focus = false }
local setupHooks: sert.Setup = {
	beforeAll = function() end,
	afterAll = function() end,
	beforeEach = function() end,
	afterEach = function() end,
}
local _hookFn: sert.HookFn = function() end
local _testFn: sert.TestFn = function(ctx: sert.TestContext)
	local _n: string, _f: string, _t: sert.Target = ctx.name, ctx.file, ctx.target
	ctx:defer(function() end)
end
local _jsonOpts: sert.JsonOptions = { strict = true, prefix = "json: " }

-- Registration & modifiers (`test`, `describe`, `prop`)
sert.test("basic", _testFn, testOpts)
sert.test.skip("skipped")
sert.test.skip("skipped body", function() end)
sert.test.focus("focused", function() end)
sert.test.roblox("roblox", function() end)
sert.test.roblox.skip("roblox skip")
sert.test.roblox.focus("roblox focus", function() end)
sert.test.server("server", function() end)
sert.test.client("client", function() end)
sert.test.each({ { 1, 2 }, { 3, 4 } })("pair %s", function(pair: { number }, ctx: sert.TestContext)
	sert.eq(#pair, 2)
	local _ = ctx.name
end)
sert.test.eachTuple({ { 1, 2, 3 } })(
	"%d + %d = %d",
	function(a: number, b: number, sum: number) sert.eq(a + b, sum) end
)

sert.describe("suite", function() end, descOpts)
sert.describe.skip("skipped suite")
sert.describe.focus("focused suite", function() end)
sert.describe.roblox("roblox suite", function() end)
sert.describe.server("server suite", function() end)
sert.describe.client("client suite", function() end)
sert.describe.each({ "a", "b" })("item %s", function(_s: string) end)
sert.describe.eachTuple({ { "x", 1 } })("%s=%d", function(_k: string, _v: number) end)

sert.beforeAll(function() end)
sert.afterAll(function() end)
sert.beforeEach(function() end)
sert.afterEach(function() end)
sert.defer(function() end)
sert.setup(setupHooks)

-- Runner, CLI args, output sinks, and bytes
local runOpts: sert.RunOptions = {
	filter = "math",
	grep = "^math",
	filters = { "a", "b" },
	names = { "exact" },
	exclude = "slow",
	excludes = { "flaky" },
	file = "Pass.spec",
	files = { "Pass.spec" },
	targets = { "portable" :: sert.Target },
	allTargets = false,
	ci = false,
	allowFocused = false,
	seed = 42,
	replay = 42,
	seeds = { prop = 1 },
	runs = 10,
	exhaustive = false,
	budget = 60,
	testTimeout = 10,
	repeatCount = 1,
	slowest = 5,
	failFast = true,
	quiet = true,
	compact = false,
	markers = false,
	list = false,
	shard = shard,
	command = "python3 tools/sert.py run",
	sweep = true,
	raise = false,
	requireTests = false,
}
local results: sert.Results = sert.run(runOpts)
local _passed: number, _failed: number, _skipped: number = results.passed, results.failed, results.skipped
local _total: number, _clock: number = results.total, results.clock
local _failures: { sert.Failure } = results.failures
local _parsed: sert.RunOptions = sert.parseCliArgs({ "--filter=math", "--seed=7", "-x" })
local _isRoblox: boolean = sert.isRoblox

sert.print("hello", 1)
sert.warn("warning")
local _qVal: number = sert.quiet(function(x: number): number return x + 1 end, 4)
local _captured: { string } = sert.capture(function() sert.print("line") end)

local rawBuf: buffer = sert.bytes.fromHex("deadbeef")
local _hexStr: string = sert.bytes.hex(rawBuf)

-- Procedural assertions & asymmetric matchers
local _truthy: number = sert(10, "callable")
local _okVal: string = sert.ok("yes", "ok")
local _eqVal: { number } = sert.eq({ 1, 2 }, { 1, 2 })
local _neVal: number = sert.ne(1, 2)
local _same: boolean = sert.equals({ a = 1 }, { a = sert.any("number") })
local _lt: number = sert.lt(1, 2)
local _le: number = sert.le(2, 2)
local _gt: string = sert.gt("b", "a")
local _ge: string = sert.ge("b", "b")
local _near: number = sert.near(0.1 + 0.2, 0.3, 1e-6)
local _matched: string = sert.matches("id_10", "^id_%d+$")
local _contained: { number } = sert.contains({ 1, 2, 3 }, 2)
local _errStr: string = sert.throws(function() error("boom") end, "boom")
local _dntA: number, _dntB: string = sert.doesNotThrow(function(): (number, string) return 1, "a" end)
local _waited: boolean = sert.waitFor(function(): boolean? return true end, 0.5, 0.05)
if false then local _never: never = sert.fail("unreachable") end

local mAny: sert.Matcher = sert.any("number")
local mSub: sert.Matcher = sert.subset({ x = mAny })
local mWin: sert.Matcher = sert.within(1.0, 1e-4)
local mPat: sert.Matcher = sert.matching("^ok")
local mEx: sert.Matcher = sert.exact(-0.0)
sert.eq({ x = 1, y = 1.0, s = "ok", z = -0.0 }, { x = mSub.kind and mAny, y = mWin, s = mPat, z = mEx })

-- Spies & spy assertions
local standaloneSpy: sert.Spy = sert.spy(function(x: number): number return x * 2 end)
standaloneSpy:returns(10):returnsOnce(20):throwsOnce("err"):throws("err2"):reset()
local _sOut = standaloneSpy(5)
local lastCall: sert.SpyCall? = standaloneSpy.lastArgs
if lastCall ~= nil then local _argCount: number = lastCall.n end
local tblTarget = { greet = function(name: string): string return "hi " .. name end }
local methodSpy: sert.Spy = sert.spy(tblTarget, "greet")
sert.called(standaloneSpy)
sert.calledTimes(standaloneSpy, 1)
sert.calledWith(standaloneSpy, sert.any("number"))
methodSpy:restore()

-- Property testing & generators
local gen = sert.gen
local floatOpts: sert.FloatOptions = { nan = true, inf = true, negZero = true }
local propOpts: sert.PropOptions = {
	runs = 20,
	size = 16,
	seed = 1,
	regressions = { 7 },
	exhaustive = { size = 2 },
	shrinkBudget = budget,
	timeout = 5,
	skip = false,
	focus = false,
	file = "Pass.spec",
	target = "portable",
}
sert.prop("typed prop", function(g: sert.GenContext)
	local _gAlias: sert.Gen = g
	local n: number = g:draw(gen.int(1, 10))
	g:assume(n > 0, "positive")
	local _f: number = g:draw(gen.float(-1, 1, floatOpts))
	local _b: boolean = g:bool(0.5)
	local _pk: string = g:pick({ "a", "b" })
	local _lst: { number } = g:list(gen.int(0, 5), 0, 4)
	local _opt: number? = g:optional(gen.int(1, 3))
	local _str: string = g:string("abc", 0, 4)
	local _buf: buffer = g:bytes(0, 8)
	g:note("n=%d", n)
end, propOpts)
sert.prop.roblox("roblox prop", function(_g: sert.Gen) end)
sert.prop.server("server prop", function(_g: sert.Gen) end)
sert.prop.client("client prop", function(_g: sert.Gen) end)
sert.prop.skip("skip prop")
sert.prop.focus("focus prop", function(_g: sert.Gen) end)

local intGen: sert.Generator<number> = gen.int(0, 10)
local _bInt: sert.Generator<number> = gen.boundaryInt(-10, 10)
local _bFloat: sert.Generator<number> = gen.boundaryFloat(-1, 1)
local _sampled: number = gen.sample(intGen, 1, 10)
local propRes: sert.PropResult = sert.prop.run("inline", function(g: sert.GenContext) g:int(0, 1) end, { runs = 1 })
local _pOk: boolean = propRes.ok

-- Stateful models & universal laws
local cmd: sert.ModelCommand<{ n: number }, { n: number }, number, number> = {
	weight = 1,
	gen = function(_s: { n: number }, g: sert.GenContext): number return g:int(1, 3) end,
	pre = function(s: { n: number }, d: number): boolean return s.n + d <= 100 end,
	run = function(sut: { n: number }, d: number): number
		sut.n += d
		return sut.n
	end,
	next = function(s: { n: number }, d: number): { n: number }?
		s.n += d
		return nil
	end,
	post = function(s: { n: number }, _sut: { n: number }, _d: number, res: number) sert.eq(res, s.n) end,
}
local modelSpec: sert.ModelSpec<{ n: number }, { n: number }> = {
	name = "counter",
	init = function() return { n = 0 } end,
	setup = function() return { n = 0 } end,
	teardown = function(_sut: { n: number }) end,
	commands = { inc = cmd },
	invariants = { match = function(s: { n: number }, sut: { n: number }) sert.eq(s.n, sut.n) end },
}
local modelOpts: sert.ModelOptions = { length = 8, redraw = true, maxRedraws = 4, runs = 5, raise = false }
local _modelPropOpts: sert.PropOptions = sert.model.propOptions(modelOpts)
local _modelFn: (sert.GenContext) -> () = sert.model.property(modelSpec, modelOpts)
local _mRes: sert.PropResult = sert.model.check(modelSpec, modelOpts)
local _mState, _mSut = sert.model.replay(modelSpec, { { "inc", 1 } })

local codecSpec: sert.CodecSpec<number, string> = {
	gen = intGen,
	encode = function(n: number): string return tostring(n) end,
	decode = function(s: string): number return tonumber(s) :: number end,
	eq = function(a: number, b: number): boolean return a == b end,
	encodedEq = function(a: string, b: string): boolean return a == b end,
	deterministic = true,
}
sert.laws.codec("num codec", codecSpec, { runs = 5 })

local orderSpec: sert.OrderSpec<number> = {
	gen = intGen,
	lt = function(a: number, b: number): boolean return a < b end,
	eq = function(a: number, b: number): boolean return a == b end,
}
sert.laws.order("num order", orderSpec, { runs = 5 })

local algSpec: sert.AlgebraSpec<number> = {
	gen = intGen,
	op = function(a: number, b: number): number return a + b end,
	identity = 0,
	hasIdentity = true,
	associative = true,
	commutative = true,
	inverse = function(a: number): number return -a end,
}
sert.laws.algebra("num algebra", algSpec, { runs = 5 })

local diffSpec: sert.DifferentialSpec<number, number> = {
	gen = intGen,
	sut = function(x: number): number return x * 2 end,
	oracle = function(x: number): number return x + x end,
}
sert.laws.differential("num diff", diffSpec, { runs = 5 })

-- Headless Env, VOPR Sim, and Roblox Studio/UI types
local sigBehavior: sert.EnvSignalBehavior = "Deferred"
local host: sert.EnvHost = { clock = os.clock }
local envOpts: sert.EnvOptions = { isServer = true, strict = true, signalBehavior = sigBehavior, host = host }
local envNs: sert.EnvNamespace = sert.env
local env: sert.Env = envNs.new(envOpts)
local _activeEnv: sert.Env? = envNs.active()
local input: sert.EnvInput = env:input()
input:press(env.Enum.KeyCode.E)
local _kicks: { sert.EnvKick } = env.kicks
env:step()
env:advance(0.1)
env:frames(2)
env:settle()
env:destroy()

local faultCfg: sert.SimFaultConfig = { profile = "light", remoteDropRate = 0.05, teleportRaceRate = 0.1 }
local wOpts: sert.SimWorldOptions = { mode = "random", seed = 1, faults = faultCfg }
local world: sert.SimWorld = sert.sim.new(wOpts)
local _faults: sert.SimFaults = world.faults
local srv: sert.SimServer = world:server()
local _cli: sert.SimClient = srv:client(1)
local simCmd: sert.SimCommand<{ n: number }, any, number, number> = {
	args = { 1, 2 },
	next = function(s: { n: number }, d: number): { n: number }? return { n = s.n + d } end,
}
local simSpec: sert.SimSpec<{ n: number }, any> = sert.sim.spec({
	init = function() return { n = 0 } end,
	commands = { add = simCmd },
})
local voprOpts: sert.SimVoprOptions = { runs = 2, steps = 4, faults = "none" }
sert.sim.vopr("sim vopr", simSpec, voprOpts)
local checkOpts: sert.SimCheckOptions = { maxStates = 10, maxDepth = 3, bfs = true, vopr = false }
local simCheckRes: sert.SimCheckResult = sert.sim.check(simSpec, checkOpts)
local _visited: number = simCheckRes.states

local _rCfg: sert.RobloxConfig = { name = "Suite" }
local _rCtx: sert.RobloxContext? = nil
local _rVerdict: sert.RobloxVerdict? = nil
local _vp: sert.ViewportPreset = { name = "Phone", size = Vector2.new(390, 844) }
local _settleOpts: sert.SettleOptions = { maxFrames = 30, stableFrames = 2, tolerance = 0.5 }
local _flOpts: sert.FlickerOptions = { maxFrames = 20, stableFrames = 3, tolerance = 0.5 }
local _flRes: sert.FlickerResult? = nil
local _fuzzSpec: sert.RemoteFuzzSpec = { handler = function(_player: any) end, runs = 5 }
local _sweepOpts: sert.SweepOptions = {}

-- Wave 1 & Wave 2: Snapshots, Performance & Benchmarks, Registry Audit Types
local _testOpts: sert.TestOptions = { smoke = true, tags = { "unit", "fast" } }
local _exhaustive: sert.ExhaustiveOption = { size = 16 }
sert.test("typed test options", function() end, _testOpts)

local _runOpts: sert.RunOptions = {
	updateSnapshots = true,
	strictAssertions = true,
	regressions = { ["prop/foo"] = { "r1" } },
	snapshots = { ["suite/a"] = { snap1 = '"hello"' } },
	bench = true,
}

local function _checkResults(res: sert.Results)
	local _skipReason: sert.SkipReason = "explicit"
	local _byReason: sert.SkippedByReason = res.skippedByReason
	local _zero: { string } = res.zeroAssertionTests
	local _tauts: { sert.TautologyRecord } = res.tautologies
	local _ = _byReason.explicit
	local _2 = _zero[1]
	local _3 = _tauts[1]
end

local _eachFmt: sert.EachFormat<number> = function(v: number): string return tostring(v) end

local _inlineStr: string = sert.inlineSnapshot("hello", '"hello"', "inline probe")
local _inlineTbl: { count: number } = sert.inlineSnapshot({ count = 1 })
local _fileStr: string = sert.snapshot("world", "greeting", "snapshot probe")
local _fileNum: number = sert.snapshot(42)

local _allocKb: number = sert.allocs(function() end, 1, 2)
local _maxKb: number = sert.maxAllocs(32, function() end, "within alloc budget")
sert.noAllocs(function() end, "zero allocations")

local _benchOpts: sert.BenchOptions = { warmup = 1, samples = 3, iterations = 10, bytes = 64 }
sert.bench("bench probe", function(b: sert.BenchContext)
	b:stopTimer()
	b:startTimer()
	b:bytes(16)
	b:iter(function() end)
end, _benchOpts)

-- Wave 1 & Wave 2: Targeted/Classified Properties & Laws (Metamorphic / Complexity)
local _propRegOpts: sert.PropOptions = { runs = 10, regressions = { "deadbeef", "cafebabe" } }
local _propNumRegOpts: sert.PropOptions = { runs = 10, regressions = { 42 } }
local _propFn: sert.PropFn = function(g: sert.GenContext)
	local x: number = g:draw(sert.gen.int(1, 20))
	g:target(x, "value")
	g:classify(x > 10, "large")
	g:cover(25, x % 2 == 0, "even")
end
sert.prop("targeted property probe", _propFn, _propRegOpts)
sert.prop("numeric regression probe", _propFn, _propNumRegOpts)

local _metaRel: sert.MetamorphicRelation<number, number> = {
	transform = function(x: number, _g: sert.GenContext): number return -x end,
	relate = function(origIn: number, origOut: number, txIn: number, txOut: number)
		sert.eq(origIn + txIn, 0)
		sert.eq(origOut, -txOut)
	end,
}
local _metaSpec: sert.MetamorphicSpec<number, number> = {
	name = "negation law",
	gen = sert.gen.int(-10, 10),
	sut = function(x: number): number return x * 2 end,
	relations = { negate = _metaRel },
}
sert.laws.metamorphic("negation metamorphic", _metaSpec, { runs = 5 })
sert.laws.metamorphic(_metaSpec)

local _bound: sert.ComplexityBound = "O(n log n)"
local _compSpec: sert.ComplexitySpec<{ number }> = {
	name = "scan complexity",
	bound = _bound,
	sizes = { 8, 16 },
	gen = function(n: number): { number } return table.create(n, 1) end,
	sut = function(xs: { number }): number return #xs end,
	measure = function(xs: { number }): number return #xs end,
}
sert.laws.complexity("scan complexity law", _compSpec, { runs = 3 })
sert.laws.complexity(_compSpec)

-- Wave 1 & Wave 2: Linearizability, Recorder, and State-Hashed / DPOR Exploration
local _simOp: sert.SimOperation<number, number> = {
	proc = "p1",
	op = "inc",
	arg = 1,
	res = 1,
	callAt = 0,
	retAt = 1,
}
local _seqModel: sert.SimSequentialModel<number, number, number> = {
	init = function(): number return 0 end,
	step = function(state: number, _op: string, arg: number, res: number): (boolean, number)
		local nextState = state + arg
		return res == nextState, nextState
	end,
	hash = function(state: number): number return state end,
	partition = function(op: sert.SimOperation<number, number>): string | number return op.proc end,
}
local _linRes: sert.LinearizeResult = sert.sim.linearizable(_seqModel, { _simOp }, "linearizable counter")
local _linCheck: sert.LinearizeResult = sert.sim.checkLinearizable(_seqModel, { _simOp })
local _linOk: boolean = _linRes.ok and _linCheck.ok

local _rec: sert.SimRecorder = sert.sim.recorder(function(): number return os.clock() end)
local _opHandle: sert.SimOperationHandle = _rec:call("p1", "inc", 1)
local _finishedOp: sert.SimOperation<any, any> = _rec:finish(_opHandle, 1)
local _wrappedVal: number = _rec:wrap("p1", "inc", 1, function(): number return 2 end)
local _recOps: { sert.SimOperation<any, any> } = _rec:operations()

local _exploreOpts: sert.SimExploreOptions = {
	maxChoices = 16,
	maxRuns = 8,
	maxBranch = 4,
	seed = 42,
	stateHash = function(w: sert.SimWorld): (string | number)? return `{w:now()}` end,
}
local _exploreOptsBacking: sert.SimExploreOptions = {
	stateHash = "backing" :: "backing",
}
local _exploreOptsExact: sert.SimExploreOptions = {
	stateHash = false :: false,
}
local _exploreOut1: sert.SimExploreOutcome? = sert.sim.explore(
	function(w: sert.SimWorld) local _pick: number = w.scheduler:choose(2, "branch") end
)
local _exploreOut2: sert.SimExploreOutcome? = sert.sim.explore(
	_exploreOpts,
	function(w: sert.SimWorld) local _pick: number = w.scheduler:choose(2, "branch") end
)
local _exploreOut3: sert.SimExploreOutcome? = sert.sim.explore(
	"named explore",
	function(w: sert.SimWorld) local _pick: number = w.scheduler:choose(2, "branch") end,
	_exploreOpts
)
local _exploreOut4: sert.SimExploreOutcome? = sert.sim.explore(function(w) local _now: number = w:now() end)
local _pruned: number = if _exploreOut1 ~= nil then _exploreOut1.pruned else 0
local _envSettleOpts: sert.EnvSettleOptions = { maxFrames = 10, dt = 1 / 60 }
local _simBfsOpts: sert.SimBfsOptions = { maxStates = 10 }
local _simBfsRes: sert.SimBfsResult? = nil
local _simTraceStep: sert.SimTraceStep? = nil
local _simRemoteErr: sert.SimRemoteError? = nil

-- Wave 1 & Wave 2: Portable Conformance & New sert.env / Engine Doubles
local _confTarget: sert.ConformanceTarget = "roblox"
local _confContainer: sert.ContainerKind = "PlayerGui"
local _confOpts: sert.ConformanceOptions = {
	target = _confTarget,
	container = _confContainer,
	tags = { "conformance" },
	timeout = 5,
}
local _confFn: sert.ConformanceFn = function(root: Instance, ctx: sert.ConformanceContext)
	local _isRoblox: boolean = ctx.isRoblox
	local _target: "portable" | sert.ConformanceTarget = ctx.target
	local _ws: any = ctx.workspace
	local _shared: any = ctx.SharedTable
	ctx.step(1 / 60)
	local _inst: Instance? = root:FindFirstChild("Probe")
end
local _confApi: sert.ConformanceApi = sert.roblox.conformance
_confApi("conformance probe", _confFn, _confOpts)
sert.roblox.conformance.skip("skipped conformance", _confFn, _confOpts)
sert.roblox.conformance.focus("focused conformance", _confFn, _confOpts)

local _robloxSide: sert.RobloxSide? = nil
local _robloxReq: sert.RobloxRequest? = nil
local _layoutRect: sert.LayoutRect? = nil
local _presetName: sert.PresetName = "Phone"
local _auditOpts: sert.AuditOptions = {}
local _matrixOpts: sert.MatrixOptions = {}
local _sweepSnap: sert.SweepSnapshot? = nil

local function _probeEnvEngineApis(e: sert.Env)
	-- Spatial casts & CollisionGroup (PhysicsService)
	local ws = e.workspace :: Workspace
	local castParams = e.RaycastParams.new()
	castParams.CollisionGroup = "Players"
	local overlapParams = e.OverlapParams.new()
	local part = e.Instance.new("Part", ws) :: Part
	part.CollisionGroup = "Players"
	local _bHit: RaycastResult? =
		ws:Blockcast(CFrame.new(0, 0, 0), Vector3.new(2, 2, 2), Vector3.new(0, -10, 0), castParams)
	local _sHit: RaycastResult? = ws:Spherecast(Vector3.new(0, 5, 0), 1, Vector3.new(0, -10, 0), castParams)
	local _shHit: RaycastResult? = ws:Shapecast(part, Vector3.new(0, -10, 0), castParams)
	local _boxParts: { BasePart } = ws:GetPartBoundsInBox(CFrame.new(), Vector3.new(4, 4, 4), overlapParams)
	local _inPart: { BasePart } = ws:GetPartsInPart(part, overlapParams)
	local phys: PhysicsService = e:getService("PhysicsService")
	phys:RegisterCollisionGroup("Players")
	phys:CollisionGroupSetCollidable("Default", "Players", false)

	-- InputContext / InputAction / InputBinding
	local inputCtx = e.Instance.new("InputContext", e.game:GetService("StarterGui"))
	local inputAct = e.Instance.new("InputAction", inputCtx)
	inputAct.Type = e.Enum.InputActionType.Bool
	local inputBind = e.Instance.new("InputBinding", inputAct)
	inputBind.KeyCode = e.Enum.KeyCode.Space

	-- SharedTable / SharedTableRegistry / Actor / task.desynchronize & synchronize
	local reg: SharedTableRegistry = e:getService("SharedTableRegistry")
	local st: SharedTable = e.SharedTable.new({ score = 0 })
	reg:SetSharedTable("Stats", st)
	local _fetched: SharedTable = reg:GetSharedTable("Stats")
	local _prev: number = e.SharedTable.increment(st, "score", 1)
	local actor = e.Instance.new("Actor", ws)
	local _ownedActor: Actor? = part:GetActor()
	e.task.desynchronize()
	e.task.synchronize()
	local _ = actor

	-- Audio Wire / AudioPlayer / AudioFader / AudioAnalyzer / AudioDeviceOutput
	local aPlayer = e.Instance.new("AudioPlayer", ws)
	local aFader = e.Instance.new("AudioFader", ws)
	local aAnalyzer = e.Instance.new("AudioAnalyzer", ws)
	local aOut = e.Instance.new("AudioDeviceOutput", ws)
	local wire = e.Instance.new("Wire", ws)
	wire.SourceInstance = aPlayer
	wire.TargetInstance = aFader
	local _wireConnected: boolean = wire.Connected
	local _audioUnused = { aAnalyzer, aOut }

	-- UIPageLayout / RichText ContentText
	local sg = e.Instance.new("ScreenGui", e.LocalPlayer.PlayerGui)
	local pagerHost = e.Instance.new("Frame", sg)
	local pager = e.Instance.new("UIPageLayout", pagerHost) :: UIPageLayout
	pager:Next()
	pager:Previous()
	local label = e.Instance.new("TextLabel", pagerHost) :: TextLabel
	label.RichText = true
	label.Text = "<b>Hi</b>"
	local _contentText: string = label.ContentText
end
