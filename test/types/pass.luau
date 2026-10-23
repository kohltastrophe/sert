--!strict
-- Type probe (`sert types`, run by `sert lint`): the public surface's call forms check under both solvers.
local Runner = require("../../src/roblox/Runner")
local Sim = require("../../src/sim")
local sert = require("../../src")

-- registration, hooks, describe, options
sert.test("test", function() end)
sert.test("options", function() end, { timeout = 1, skip = false, focus = false, file = "Wrapped.spec" })
sert.rtest("roblox only", function() end, { timeout = 5 })
sert.skip("skipped", function() end)
sert.skip("skipped, no body")
sert.todo("later")
sert.focus("focused", function() end, { timeout = 1 })
sert.each("double %d", { 1, 2, 3 }, function(n: number, _index: number) sert.eq(n * 2, n + n) end)
sert.each(
	"named",
	{ { a = 1, b = 2 }, { a = 3, b = 4 } },
	function(case: { a: number, b: number }) sert(case.a < case.b) end,
	{
		timeout = 1,
		format = function(name: string, case: { a: number, b: number }, index: number): string
			return `{name} {index}: {case.a}`
		end,
	}
)

sert.beforeAll(function() end)
sert.afterAll(function() end)
sert.beforeEach(function() end)
sert.afterEach(function() end)
local setup: sert.Setup = { beforeEach = function() end, afterEach = function() end }
sert.setup(setup)
sert.setup({})
local current: sert.Current? = sert.current()
if current ~= nil then
	local _name: string, _file: string, _last: boolean = current.name, current.file, current.last
end
sert.defer(function() end)
local _isolated: boolean, _first = sert.isolate(function() return 1 end)
local _loaded: { number } = sert.loaded({ 1 })

sert.describe("block", function() end, { separator = " / ", file = "Wrapped.spec" })
sert.describe.skip("block", function() end, { separator = " / " })
sert.describe.focus("block", function() end)

local testOptions: sert.TestOptions = { timeout = 1 }
sert.test("annotated", function() end, testOptions)
local eachOptions: sert.EachOptions<number> = {
	format = function(name: string, case: number, _index: number): string return `{name} {case}` end,
}
sert.each("annotated", { 1 }, function(_n: number) end, eachOptions)
local describeOptions: sert.DescribeOptions = { separator = "." }
sert.describe("annotated", function() end, describeOptions)
local propOptions: sert.PropOptions = { runs = 5 }
sert.prop("annotated", function(_g: sert.Gen) end, propOptions)

-- running, output, format, rng, bytes
local runOptions: sert.RunOptions = {
	filter = "math",
	filters = { "a", "b" },
	names = { "exact" },
	excludes = { "slow" },
	files = { "Button.spec" },
	shard = false,
	list = false,
	raise = false,
	silent = true,
	requireTests = true,
	rtestOnly = false,
	seed = 1,
	replay = 123,
	seeds = { prop = 456 },
	runs = 10,
	exhaustive = false,
	budget = 60,
	command = "python3 tools/sert.py run",
	failFast = true,
}
local results: sert.Results = sert.run(runOptions)
local _passed: number, _failed: number, _skipped: number = results.passed, results.failed, results.skipped
local _todo: number, _total: number, _clock: number = results.todo, results.total, results.clock
local _failures: { string }, _seeds: { [string]: number } = results.failures, results.seeds
sert.run()
sert.run(sert.parseCliArgs(...))
local parsed: sert.RunOptions = sert.parseCliArgs({ "--filter=math", "--seed=7", "-x" })
sert.run(parsed)
local shard: sert.Shard? = sert.shard()
if shard ~= nil then
	local _name: string, _index: number, _count: number = shard.name, shard.index, shard.count
	sert.run({ shard = shard })
end
local _selected: boolean = sert.shardSelects("math works")
local _isRoblox: boolean = sert.isRoblox

sert.print("shown", 1)
sert.warn("warned")
sert.quiet(function(n: number) print(n) end, 1)
local _lines: { string } = sert.capture(function() print("captured") end)
local _repr: string = sert.format.repr({ a = 1 })
local _diff: string? = sert.format.diff({ 1 }, { 2 })
local _json: string = sert.format.json({ a = 1 }, { strict = true })
local _decoded = sert.format.jsonDecode("[1]")
local rng: sert.Rng = sert.rng.new(1)
local _roll: number, _unit: number, _coin: boolean = rng:int(1, 6), rng:float(), rng:chance(0.5)
local _picked: string = rng:pick({ "a", "b" })
local _shuffled: { number } = rng:shuffle({ 1, 2, 3 })
local _forked: sert.Rng = rng:fork("child")
local _noise: buffer = rng:bytes(16, "text")
local _hash: number = sert.rng.fnv1a32("name")
local blob: buffer = sert.bytes.fromHex("00ff")
local _hex: string = sert.bytes.hex(blob)
local _sameBytes: boolean = sert.bytes.equal(blob, blob)
sert.bytes.assertBytes(blob, "00ff", "bytes")

-- assertions, expect, spies, extend
local _value: number = sert(1 + 1, "addition")
sert(true)
local _eq: { number } = sert.eq({ 1 }, { 1 }, "deep")
sert.rawEq(setmetatable({ a = 1 }, {}), { a = 1 })
sert.neq(1, 2, "differ")
local _same: boolean = sert.equals({ a = 1 }, { a = 1 })
local _near: number = sert.near(0.1 + 0.2, 0.3)
sert.near(1, 1.01, 0.1, "tolerance")
local _contains: string = sert.contains("hello world", "world")
local _matches: string = sert.matches("abc123", "%d+$", "digits")
local _err: string = sert.fails(function() error("boom") end)
sert.fails(function() error("boom") end, "boom", "why")
sert.fails(function() error({ code = 1 }) end, function(err: any): boolean return err.code == 1 end)
local frameCount = 0
local _done: true = sert.frames(function()
	frameCount += 1
	return frameCount > 2
end, 10, "three frames", function() end)
local _found: number = sert.waitFor(function(): number? return 1 end, 1, "found", function() end)

local expect = sert.expect
expect(1).toBe(1)
expect({ 1 }, "why").toEqual({ 1 })
expect(setmetatable({}, {})).toRawEqual({})
expect({ a = 1, b = 2 }).toMatchObject({ a = 1 })
expect({ a = { b = 1 } }).toHaveProperty("a.b", 1)
expect({ a = { b = 1 } }).toHaveProperty({ "a", "b" })
expect(nil).toBeNil()
expect(1).toBeTruthy()
expect(false).toBeFalsy()
expect(0 / 0).toBeNaN()
expect(1).toBeFinite()
expect(0.1 + 0.2).toBeCloseTo(0.3)
expect(0.1 + 0.2).toBeCloseTo(0.3, 5)
expect(1).toBeNear(1.001, 0.01)
expect(2).toBeGreaterThan(1)
expect(2).toBeGreaterThanOrEqual(2)
expect(1).toBeLessThan(2)
expect(1).toBeLessThanOrEqual(1)
expect(1).toBeA("number")
expect({}).toBeInstanceOf({})
expect({}).toBeInstanceOf("table")
expect({ 1, 2 }).toContain(2)
expect("abc").toMatch("^a")
expect({ 1, 2 }).toHaveLength(2)
expect(function() error("boom") end).toThrow()
expect(function() error("boom") end).toThrow("boom")
expect(function() error("boom") end).toThrow(function(err: any): boolean return err ~= nil end)
expect(1).never.toBe(2)
expect(1).never.never.toBe(1)

local f = sert.fn(function(n: number): number return n * 2 end)
local _doubled = f(1)
f(1, "two")
f:mockReturnValue(1):mockReturnValueOnce(2)
f:mockImplementation(function() return 3 end)
f:mockImplementation()
f:mockImplementationOnce(function() end)
local _calls: number, _n: number = f.callCount, #f.calls
local last = f.lastCall
if last ~= nil then
	local _firstArg, _count: number = last[1], last.n
end
local _resOk: boolean = f.results[1].ok
f:reset()
expect(f).toHaveBeenCalled()
expect(f).toHaveBeenCalledTimes(2)
expect(f).toHaveBeenCalledWith(1, "two")
expect(f).toHaveBeenLastCalledWith(1, "two")
expect(f).toHaveBeenNthCalledWith(1, 1)
expect(f).toHaveReturned()
expect(f).toHaveReturnedWith(2)
expect(f).never.toHaveBeenCalled()

local target = {
	greet = function(name: string): string return "hi " .. name end,
}
local s: sert.Spy = sert.spy(target, "greet")
sert.spy(target, "greet", function() return "stub" end)
s:restore()

local isEven: sert.Matcher = function(actual: any): sert.MatcherResult
	return {
		pass = actual % 2 == 0,
		message = function() return `expected {actual} to be even` end,
		negMessage = `expected {actual} not to be even`,
	}
end
sert.extend({
	toBeEven = isEven,
	toBeWithin = function(actual: any, lo: number, hi: number): sert.MatcherResult
		return { pass = actual >= lo and actual <= hi, message = "out of range" }
	end,
})
type Custom = sert.Matchers & { toBeEven: () -> (), toBeWithin: (lo: number, hi: number) -> () }
local expectCustom = sert.expect :: (actual: any, why: string?) -> Custom
expectCustom(2).toBeEven()
expectCustom(2).toBeWithin(1, 3)
expectCustom(2).toEqual(2)
local matchers: sert.Matchers = expect(1)
matchers.never.toBe(2)

-- prop, gen, check, model, laws
local gen = sert.gen
sert.prop("tape", function(g: sert.Gen)
	local _size: number, _seed: number, _exhaustive: boolean = g.size, g.seed, g.exhaustive
	local _i: number = g:int(-5, 5)
	local _fl: number, _bfl: number = g:float(), g:float(0, 10)
	local _bo: boolean, _bbo: boolean = g:bool(), g:bool(0.9)
	local _pk: string = g:pick({ "a", "b" })
	local _wt = g:weighted({ { 1, "rare" }, { 9, "common" } })
	local _opt: number? = g:optional(function(inner: sert.Gen): number return inner:int(1, 2) end)
	local _tup: { any } = g:tuple(gen.int(1, 2), gen.bool())
	local _tupSame: { any } = g:tuple({ gen.int(1, 2), gen.int(3, 4) })
	local _rec = g:record({ x = gen.int(1, 2), name = gen.string("ab") })
	local _dct: { [string]: number } = g:dict(gen.string("ab", 1, 3), gen.int(0, 9), 0, 4)
	local _lst: { number } = g:list(function(inner: sert.Gen): number return inner:int(1, 9) end, 1, 5)
	local _lstGen: { boolean } = g:list(gen.bool())
	local _str: string, _cstr: string = g:string(), g:string("abc", 1, 4)
	local _gstr: string = g:string(gen.pick({ "x", "y" }))
	local _bts: buffer = g:bytes(0, 16)
	g:note("drew %d", 1)
	g:note(function() return "lazy" end)
end, {
	runs = 50,
	size = 10,
	seed = 1,
	regressions = { 12345 },
	exhaustive = { size = 3 },
	shrinkBudget = { tries = 100, seconds = 1 },
	timeout = 5,
	skip = false,
	focus = false,
	rtest = false,
})

local int: sert.Generator<number> = gen.int(1, 9)
local _floatG: sert.Generator<number> = gen.float(0, 1, { nan = true, inf = true, negZero = true })
local _boolG: sert.Generator<boolean> = gen.bool()
local _constG: sert.Generator<string> = gen.constant("x")
local _pickG: sert.Generator<string> = gen.pick({ "a", "b" })
local _oneOfG: sert.Generator<any> = gen.oneOf({ gen.int(1, 2), gen.bool() })
local _freqG: sert.Generator<any> = gen.frequency({ { 1, gen.int(1, 2) }, { 3, gen.constant(0) } })
local _optG: sert.Generator<number?> = gen.optional(int, 1, 3)
local _listG: sert.Generator<{ number }> = gen.list(int, 0, 5)
local _uniqG: sert.Generator<{ number }> = gen.uniqueList(int, 1, 3)
local _recG: sert.Generator<{ [string]: any }> = gen.record({ x = int, y = gen.bool() })
local _dictG: sert.Generator<{ [string]: number }> = gen.dict(gen.string("ab"), int)
local _tupG: sert.Generator<{ any }> = gen.tuple(int, gen.bool())
local _tupSameG: sert.Generator<{ any }> = gen.tuple({ int, gen.int(3, 4) })
local _strG: sert.Generator<string> = gen.string()
local _cstrG: sert.Generator<string> = gen.string("abc", 1, 8)
local _gstrG: sert.Generator<string> = gen.string(gen.pick({ "x", "y" }), 0, 4)
local _chars: string = gen.CHARACTERS
local _mapG: sert.Generator<string> = gen.map(int, tostring)
local _bindG: sert.Generator<{ number }> = gen.bind(
	gen.int(0, 3),
	function(n: number): sert.Generator<{ number }> return gen.list(int, n, n) end
)
local _bytesG: sert.Generator<buffer> = gen.bytes(0, 64)
local _filtG: sert.Generator<number> = gen.filter(int, function(n: number): boolean return n % 2 == 0 end, 50)
local _vec2G: sert.Generator<Vector2> = gen.vector2()
local _vec3G: sert.Generator<Vector3> = gen.vector3(int, int, int)
local _col3G: sert.Generator<Color3> = gen.color3()
local _udimG: sert.Generator<UDim> = gen.udim()
local _udim2G: sert.Generator<UDim2> = gen.udim2()
local _cfG: sert.Generator<CFrame> = gen.cframe()
local _nrG: sert.Generator<NumberRange> = gen.numberRange()
local _rectG: sert.Generator<Rect> = gen.rect()
local _utf8G: sert.Generator<string> = gen.utf8(0, 8)
local _setG: sert.Generator<{ [number]: true }> = gen.set(int, 0, 4)
local _shufG: sert.Generator<{ string }> = gen.shuffle({ "a", "b", "c" })
local _subG: sert.Generator<{ string }> = gen.subset({ "a", "b", "c" }, 1)
local tree: sert.Generator<any> = gen.recursive(
	gen.int(0, 9),
	function(inner: sert.Generator<any>): sert.Generator<any> return gen.list(inner, 0, 3) end,
	3
)
local _lazyG: sert.Generator<any> = gen.lazy(function() return tree end)
local _enumG: sert.Generator<any> = gen.enum(Enum.KeyCode)
local _anyG: sert.Generator<any> = gen.any(2)
local _samp: number = gen.sample(int)
local _seededSamp: { number } = gen.sample(gen.list(int), 7, 10)

local propRes: sert.PropResult = sert.prop.run("run", function(g: sert.Gen) g:int(1, 2) end, { runs = 1 }, { seed = 1 })
local _propOk: boolean, _report: string?, _cases: number, _attempts: number, _pseed: number? =
	propRes.ok, propRes.report, propRes.cases, propRes.attempts, propRes.seed

sert.check("one", gen.int(1, 9), function(_n: number) end, { runs = 1 })
sert.check("same", { gen.int(1, 9), gen.int(1, 9) }, function(_a: number, _b: number) end)
local mixed: { sert.Generator<any> } = { gen.int(1, 9), gen.bool(), gen.string() }
sert.check("mixed", mixed, function(_n: number, _b: boolean, _s: string) end)
local _mixedTuple: sert.Generator<{ any }> = gen.tuple(mixed)

local modelSpec: sert.ModelSpec = {
	name = "counter",
	init = function() return { n = 0 } end,
	setup = function() return { n = 0 } end,
	teardown = function(_sut: any, _state: any) end,
	invariant = function(state: any, sut: any) sert.eq(sut.n, state.n) end,
	commands = {
		{
			name = "inc",
			weight = 2,
			gen = function(g: sert.Gen, _state: any): number return g:int(1, 3) end,
			pre = function(_state: any, arg: any): boolean return arg > 0 end,
			run = function(sut: any, arg: any, _state: any)
				sut.n += arg
				return sut.n
			end,
			post = function(_state: any, _arg: any, returned: any) sert(returned > 0) end,
			next = function(state: any, arg: any, _result: any)
				state.n += arg
			end,
		},
	},
}
local modelOpts: sert.ModelOptions = { length = 10, redraw = true, maxRedraws = 3, runs = 20 }
sert.model("counter", modelSpec, modelOpts)
sert.model(modelSpec)
sert.model("map", {
	init = function() return 0 end,
	commands = {
		inc = {
			run = function(sut: any) return sut end,
			pre = function(_state: any, _arg: any): boolean return true end,
		},
	},
}, { runs = 5 })
local property: (sert.Gen) -> () = sert.model.property(modelSpec, { length = 5 })
sert.prop("model as a property", property)
local _mstate, _msut = sert.model.replay(modelSpec, { { "inc", 1 }, { "inc", 2 } })
sert.model.replay(modelSpec, { { name = "inc", arg = 1 } })
local actionModelSpec: sert.ModelSpec = {
	init = function() return 0 end,
	actions = {
		inc = {
			gen = { 1, 2 },
			guard = function(st: number, d: number): boolean return st + d <= 10 end,
			next = function(st: number, d: number): number return st + d end,
		},
	},
	never = {
		overTen = function(st: number): boolean return st > 10 end,
	},
	invariants = {
		nonNeg = function(st: number): boolean return st >= 0 end,
	},
}
sert.model("action model", actionModelSpec)
local command: sert.ModelCommand = {
	run = function(sut: any) return sut end,
}
local _commandRun = command.run

local codec: sert.CodecSpec<number, string> = {
	gen = function(g: sert.Gen): number return g:int(1, 9) end,
	encode = function(n: number): string return tostring(n) end,
	decode = function(str: string): number return tonumber(str) :: number end,
}
sert.laws.codec("codec", codec, { runs = 5, file = "Wrapped.spec" })
sert.laws.codec({
	name = "inline codec",
	gen = gen.string(),
	encode = function(str: string): string return str end,
	decode = function(str: string): string return str end,
})
local chunk: sert.ChunkSpec<string, string> = {
	gen = function(g: sert.Gen): string return g:string("ab") end,
	chunk = function(text: string, budget: number): { string }
		return { string.sub(text, 1, budget), string.sub(text, budget + 1) }
	end,
	join = function(chunks: { string }): string return table.concat(chunks) end,
}
sert.laws.chunk("chunk", chunk)
local registrySpec: sert.RegistrySpec = { entries = {}, aliases = {} }
sert.laws.registry("registry", registrySpec)
sert.laws.registry("entries", {
	entries = function() return { a = { kind = "x" } } end,
	schema = {
		kind = "string",
		label = "string?",
		id = function(value: any, _entry: any, _key: any): boolean return value == nil end,
	},
	check = function(_entry: any, _key: any) end,
}, { timeout = 1 })
local order: sert.OrderSpec<number> = {
	gen = function(g: sert.Gen): number return g:int(1, 9) end,
	lt = function(a: number, b: number): boolean return a < b end,
	eq = function(a: number, b: number): boolean return a == b end,
}
sert.laws.order("order", order, { runs = 5 })
sert.laws.order({
	name = "inline order",
	gen = function(g: sert.Gen): number return g:int(1, 9) end,
	lt = function(a: number, b: number): boolean return a < b end,
})

-- env and doubles
local envOpts: sert.EnvOptions = {
	isServer = true,
	isClient = false,
	isStudio = false,
	strict = true,
	creatorId = 1,
	placeId = 2,
	gameId = 3,
	jobId = "job",
	frameRate = 60,
}
local env: sert.Env = sert.env.new(envOpts)
sert.env.new()
local _currentEnv: sert.Env = sert.env.current()
sert.env.configure({ isClient = true })
sert.env.reset()
local _installedNs = sert.env.install({}, { includeGame = false })
local _nsSvc = sert.env.getService("GuiService")
local _envSvc = env:getService("GuiService")
local _installedEnv = env:install({})
local active: sert.Env? = sert.env.active()
sert.env.hooks.wait = function() end
local hostEnv = sert.env.new({
	host = {
		clock = os.clock,
		wait = function(seconds: number?): number return seconds or 0 end,
	},
})
hostEnv:step(1 / 60)
local _now: number, _stepped: number = env.now, env:step()
env:step(1 / 30)
env:advance(0.5)
env:flush()

local part = env.Instance.new("Part")
part.Parent = env.workspace
local _service = env.game:GetService("ReplicatedStorage")
local _created = env.createInstance("Folder", env.workspace)
env.task.delay(1, function() end)
env.globals.print = print
local _players, _signal = env.Players, env:signal()
local player = env:addPlayer(1, "One")
env:addPlayer(2)
env:removePlayer(player)
env:removePlayer(2)
env:setBadge(1, 10, true)
env:setGamePass(1, 20)
env:setProductInfo(30, { Name = "Thing" })
env:setGroupRank(1, 40, 255, "Owner")
env:onHttp(function(request: any) return { StatusCode = 200, Body = request.Url } end)
env:onHttp(nil)
env:onTextFilter(function(text: string, _fromUserId: number): string return text end)
local _kicks = env.kicks
local input: sert.EnvInput = env:input()
input:press(Enum.KeyCode.E)
input:release(Enum.KeyCode.E)
input:move(Vector2.new(10, 10))
input:click(part)
input:type("hello")
local root = env:mount({ Name = "Stage" })
env:mount({ Name = "Other" }, env.workspace)
local _module = env:require(root)
local _sum: number = env:run(function(a: number, b: number): number return a + b end, 1, 2)
local gui = env.Instance.new("Frame")
env:setAbsolute(gui, Vector2.new(100, 50), Vector2.new(0, 0))
env:shutdown()
if active ~= nil then active:advance(1) end

local doubles = sert.doubles
local signal = doubles.Signal.new()
local connection = signal:Connect(function(_value: number) end)
signal:Once(function() end)
signal:Fire(1)
local _listening: number, _connected: boolean = signal:connections(), signal:connected()
connection:Disconnect()
signal:DisconnectAll()
doubles.Signal.new({ clock = os.clock }, function() end)
local _isSignal: boolean = doubles.Signal.is(signal)
local _vector = doubles.Datatypes.Vector3.new(1, 2, 3)
local folder = doubles.Instance.new("Folder")
doubles.Instance.createInstance(nil, "Part", folder)
local _isClass: boolean = doubles.Instance.isClass("Part", "BasePart")
doubles.Instance.setAbsolute(doubles.Instance.new("Frame"), Vector2.new(1, 1))
local store = doubles.DataStore.new({ clock = os.clock })
local _ds = store:GetDataStore("Players")
local memory = doubles.MemoryStore.new({ now = 0 })
memory:step(1)
local http = doubles.HttpService.new()
local _encoded: string = http:JSONEncode({ 1 })
local _base64: string = doubles.EncodingService.base64Encode(buffer.fromstring("hi"))
local _encoding = doubles.EncodingService.new()
local _exists: boolean = doubles.Generated.exists("Part")
local _isA: boolean = doubles.Generated.isA("Part", "BasePart")
local _superclass: string? = doubles.Generated.superclass("Part")

-- roblox (Layout, Flicker, Runner)
local Layout, Flicker = sert.roblox.Layout, sert.roblox.Flicker
local screen = Instance.new("ScreenGui")
local frame = Instance.new("Frame")
frame.Parent = screen
local settled: boolean, problem: string? = Layout.settle(screen)
sert(settled, problem)
local roots: { Instance } = { screen, frame }
Layout.settle(roots, {
	lead = 1,
	stable = 2,
	maxFrames = 60,
	timeout = 1,
	tolerance = 0.5,
	descendants = false,
	filter = function(object: GuiObject): boolean return object.Visible end,
	step = function() end,
})
local _visible: boolean = Layout.visible(frame)
Layout.visible(frame, screen)
local _position: Vector2, _size: Vector2 = Layout.clippedBounds(frame)

local fResult = Flicker.around(
	function() return frame end,
	function() frame.Visible = true end,
	{ motion = 0, tolerance = 1, stable = 3, timeout = 2, label = "open" }
)
Flicker.expect(fResult, "open")
local _fok: boolean, _description: string = fResult.ok, Flicker.describe(fResult)
local recorder = Flicker.record(function(): GuiObject? return frame end, {
	shown = function(object: GuiObject): boolean return object.BackgroundTransparency < 1 end,
	positionOnly = true,
	maxStep = 4,
	fromSettledSize = false,
	busy = function(): boolean return false end,
})
local _samples = recorder.samples
local judged = Flicker.judge(recorder.result())
recorder.stop()
local _settledAt, _shown: boolean = judged.settled, Flicker.visible(frame)
Flicker.drive(function() end)
Flicker.drive()

local rConfig: Runner.Config = {
	name = "Game",
	sides = {
		server = { root = Instance.new("Folder"), where = "server" },
		client = {
			entry = Instance.new("ModuleScript"),
			filter = "ui",
			setup = { beforeEach = function() end },
			before = function(context: Runner.Context) local _side: string = context.side end,
			rtestOnly = true,
		},
	},
	order = { "server", "client" },
	hideChat = true,
	characters = false,
	scriptErrors = true,
	randomSeed = true,
	context = function(context: Runner.Context) return context.sert, context end,
}
local _topRConfig: sert.RobloxConfig = rConfig
local _topSettleOpts: sert.SettleOptions = { lead = 1, stable = 2 }
local _topFlickerOpts: sert.FlickerOptions = { motion = 0, stable = 2 }
local _topFlickerRes: sert.FlickerResult = fResult
Runner.server(rConfig)
Runner.client(rConfig)
local verdict: Runner.Verdict = Runner.edit(rConfig, { filter = "ui" })
local _topVerdict: sert.RobloxVerdict = verdict
local _topCtx: sert.RobloxContext? = nil
local _vpassed: boolean, _vfailures: { string } = verdict.passed, verdict.failures
Runner.edit(rConfig)
local _args, _sameRunner = Runner.args(5), sert.roblox.Runner.edit

-- sim (prop, model, explore, World, Scheduler, Runner, Explore, configure)
local function visit(e: any)
	local st = e.game:GetService("DataStoreService"):GetDataStore("counters")
	st:UpdateAsync("visits", function(n: number?): number return (n or 0) + 1 end)
end

Sim.prop("two servers count two visits", function(w: Sim.World)
	local a, b = w:server(), w:server()
	a:spawn(visit, a:env())
	b:spawn(visit, b:env())
	w:converge()
	sert.eq(w.datastore.mock:GetDataStore("counters").data.visits.value, 2)
end, { runs = 100, world = { faults = "none" } })
Sim.prop(function(w: Sim.World, g: sert.Gen) w:step(g:float(0, 1)) end)
sert.sim.prop("re-exported", function(w: sert.SimWorld)
	local srv: sert.SimServer = w:server()
	local _cli: sert.SimClient = srv:client(1)
	local _sched: sert.SimScheduler = w.scheduler
	sert(w:runUntil(function() return srv.state == "up" end, 30))
end, { allowErrors = true })
local _simCmd: sert.SimModelCommand = {
	run = function(sut: any) return sut end,
}
local _simSpec: sert.SimModelSpec = {
	init = function() return 0, nil end,
	commands = { inc = _simCmd },
}

Sim.model("visits add up across servers", {
	init = function(w: Sim.World) return { visits = 0 }, { w:server(), w:server() } end,
	commands = {
		visit = {
			gen = function(g: sert.Gen): number return g:int(1, 2) end,
			run = function(servers: { Sim.Server }, i: number)
				local srv = servers[i]
				srv:spawn(visit, srv:env())
			end,
			next = function(state: { visits: number })
				state.visits += 1
			end,
		},
	},
	converge = function(state: { visits: number }, _servers: any, w: Sim.World)
		sert.eq(w.datastore.mock:GetDataStore("counters").data.visits.value, state.visits)
	end,
}, { length = 5, runs = 20 })
Sim.model({
	name = "spec first",
	init = function() return 0, nil end,
	commands = {},
})

Sim.explore("every interleaving counts two visits", function(w: Sim.World)
	local a, b = w:server({ skew = 0 }), w:server({ skew = 0 })
	a:spawn(visit, a:env())
	b:spawn(visit, b:env())
	w:converge()
end, { world = { faults = "none", latency = { DataStoreService = 0.1 } }, maxRuns = 100 })
Sim.explore(function(w: Sim.World) w:run(1) end)

local formalSpec: Sim.Spec = Sim.spec({
	name = "CounterSpec",
	init = function() return { n = 0 }, { n = 0 } end,
	project = function(sut: { n: number }) return { n = sut.n } end,
	actions = {
		inc = {
			guard = function(st: { n: number }) return st.n < 10 end,
			run = function(sut: { n: number })
				sut.n += 1
				return sut.n
			end,
			next = function(st: { n: number })
				st.n += 1
			end,
		},
	},
	never = {
		overflow = function(st: { n: number }) return st.n > 10 end,
	},
	invariants = {
		nonNegative = function(st: { n: number }) return st.n >= 0 end,
	},
})
local _specCheckOpts: sert.SimSpecCheckOptions = { maxStates = 10, maxDepth = 4 }
local _specCheck: sert.SimSpecCheckResult = formalSpec:check(_specCheckOpts)
Sim.checkSpec("check counter spec", formalSpec, { maxStates = 10 })
Sim.vopr("vopr counter spec", formalSpec, { runs = 2, length = 3 })
sert.model("formal spec as model", formalSpec, { runs = 2, length = 3 })
local _tlaText: string = formalSpec:toTlaJson({ { action = "inc", state = { n = 1 } } })

local wOpts: sert.SimWorldOptions = { mode = "manual", faults = "none", seed = 1, wait = "instant", backing = true }
local world: Sim.World = Sim.World.new(wOpts)
local _sameW: Sim.World = Sim.new({ mode = "random", faults = "light" })
local server: Sim.Server = world:server()
local _jobId: string = server.jobId
local sEnv = server:env({ strict = true })
sEnv:advance(1)
local client: Sim.Client = server:client(1)
local _clientEnv = client:env()
client:leave()
server:join(2)
server:crash()
server:restart()
server:shutdown(5)
local _wFrame: number = world:step()
world:run(1)
local _reached: boolean = world:runUntil(2)
world:partition(server, 5)
world:heal()
world:fail("DataStoreService", "SetAsync", "before", "throttled")
local _summary: string, _digest: number, _converged: boolean = world:summary(), world:digest(), world:converge()
world:assertNoErrors("label")
local _wNow: number = world.clock.now
local extended: typeof(Sim.World) & { extra: number } = nil :: any
local _newW, _sameWorld = extended.new, sert.sim.World.new

local scheduler: Sim.Scheduler = Sim.Scheduler.new({ seed = 1, random = true, frame = 1 / 60 })
local _at: number = scheduler.now
scheduler:spawn(nil, function() end)
scheduler:after(1, nil, function() end)
scheduler:runFor(2)
local _choice: number, _spicked: string = scheduler:choose(3, "label"), scheduler:pick({ "a", "b" })
local _seeded: Sim.Chooser = Sim.Scheduler.seeded(1)
Sim.Scheduler.new({ chooser = Sim.Scheduler.replay({ 1, 2 }) })

local visits: Sim.Workload = {
	name = "visits",
	steps = 20,
	gen = function(r: Sim.Rng, n: number): { Sim.Op }
		local ops = {}
		for i = 1, n do
			table.insert(ops, { t = i * 0.5, server = r:int(1, 2), kind = "visit" })
		end
		return ops
	end,
	setup = function(ctx: Sim.Ctx)
		local w = Sim.World.new({ scheduler = ctx.scheduler, mode = "random", faults = "none", backing = true })
		return { world = w, servers = { w:server(), w:server() }, sent = 0 }
	end,
	apply = function(_ctx: Sim.Ctx, state: any, op: Sim.Op)
		state.sent += 1
		visit(state.servers[op.server]:env())
	end,
	quiesce = function(_ctx: Sim.Ctx, state: any) state.world:converge() end,
	final = function(ctx: Sim.Ctx, state: any)
		if state.sent < 0 then ctx.fail("visits", "negative") end
	end,
}
local sRes: Sim.Result = Sim.Runner.run(visits, { seed = 42 })
if not sRes.ok then
	local shrunk: Sim.ShrinkResult = Sim.Runner.shrink(visits, sRes)
	local _headline: string = Sim.Runner.headline(visits.name, sRes.seed, shrunk.failure)
	local _literal: string = shrunk.literal
end
Sim.Runner.replay(visits, { seed = 42, ops = sRes.ops })
local _explored: Sim.ExploreResult = Sim.Runner.explore(visits, sRes.ops, { maxRuns = 10 })
local limits: Sim.ExplorerLimits = { maxRuns = 10, maxChoices = 8 }
local outcome: Sim.ExplorerOutcome = Sim.Explore.run(
	function(chooser: Sim.Chooser) chooser:choose(2, "branch") end,
	limits
)
local _truncated: boolean = outcome.truncated

Sim.configure({ breath = false })
local HostStore = {}
function HostStore.new(storeOptions: any, _extra: number?): any return storeOptions end
function HostStore.copy(value: any, _depth: number?): any return value end
Sim.configure({ describeError = tostring, datastore = { new = HostStore.new, copy = HostStore.copy } })

-- adversarial generators, laws, headless layout, and sim remotes
local _bInt: sert.Generator<number> = sert.gen.boundaryInt(-10, 10)
local _bFloat: sert.Generator<number> = sert.gen.boundaryFloat(-1, 1)
local _malStr: sert.Generator<string> = sert.gen.malformedString()
local _sparse: sert.Generator<{ [any]: any }> = sert.gen.sparseTable(sert.gen.int(1, 5))
local _rPayload: sert.Generator<any> = sert.gen.remotePayload(2)
local _adv: sert.Generator<any> = sert.gen.adversarial(2)

local remoteLaw: sert.RemoteSpec = {
	name = "ping",
	handler = function(_player: any, _payload: any) end,
	checkState = function(_player: any) end,
	post = function(_player: any, _ok: boolean, _res: any) end,
}
sert.laws.remote("ping remote", remoteLaw, { runs = 5 })

local algebraLaw: sert.AlgebraSpec<number> = {
	gen = sert.gen.int(-10, 10),
	op = function(a: number, b: number): number return a + b end,
	identity = 0,
	associative = true,
	commutative = true,
}
sert.laws.algebra("addition algebra", algebraLaw, { runs = 5 })

local diffLaw: sert.DifferentialSpec<number, number> = {
	gen = sert.gen.int(-10, 10),
	sut = function(x: number): number return x * 2 end,
	oracle = function(x: number): number return x + x end,
}
sert.laws.differential("double differential", diffLaw, { runs = 5 })

local uiLaw: sert.UiSpec = {
	mount = function(e: any, parent: any, _vp: any): any
		local uiFrame = e.Instance.new("Frame", parent)
		return uiFrame
	end,
}
sert.laws.ui("frame ui", uiLaw)

world:onServerEvent("Ping", function(_peer, _x) end)
world:fireServer("c1", "Ping", 123)
world:flushRemotes()
