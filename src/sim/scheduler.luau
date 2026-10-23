--!strict
-- Deterministic virtual-time scheduler for the simulator (`Scheduler`), plus `Config`, `Explore`, and `Coop`.

local Rng = require("../rng")
local util = require("../util")

export type Backing = { new: (options: any, ...any) -> any, copy: ((value: any, ...any) -> any)? }
export type Config = {
	hash: (text: string) -> number,
	describeError: (err: any) -> string,
	reporter: ((handler: ((event: any) -> ())?) -> ())?,
	datastore: Backing?,
	breath: number | false,
	breathe: (() -> ())?,
}

local function describeError(err: any): string return tostring(err) end

local Config: Config = {
	hash = Rng.fnv1a32,
	describeError = describeError,
	reporter = nil,
	datastore = nil,
	breath = 1,
	breathe = if (game :: any) ~= nil then task.wait :: any else nil,
}

local MAX_DEFER_DEPTH = 80
local MANUAL_FRAME = 0.1
local MIN_FRAME, MAX_FRAME, HITCH, HITCH_CHANCE = 1 / 60, 0.25, 1, 0.02
local TRACE_LIMIT = 1000
local DEFAULT_LIMIT = 3600
local ON_TEST_THREAD = "a yielding call (GetAsync, a signal's Wait, a remote) on the test's own thread: run it inside "
	.. "server:spawn(fn) and advance time with world:run, world:runUntil or world:converge"

local MAIN = table.freeze({})

export type Chooser = { choose: (self: any, n: number, label: string, weights: { number }?) -> number }
export type Choice = { n: number, label: string, value: number }
export type Options = { seed: number?, random: boolean?, frame: number?, chooser: Chooser? }
export type Failure = { owner: any, message: string, traceback: string, error: any }
export type HostHooks = {
	clock: () -> number,
	wait: (seconds: number?) -> number,
	spawn: (fn: any, ...any) -> thread,
	defer: (fn: any, ...any) -> thread,
	resume: (thread: thread, ...any) -> (),
}

export type Scheduler = {
	now: number,
	current: any,
	errors: { Failure },
	frames: number,
	random: boolean,
	seed: number,
	traced: { string },
	testThread: thread?,
	stream: (self: Scheduler, name: string) -> Rng.Rng,
	choose: (self: Scheduler, n: number, label: string?, weights: { number }?) -> number,
	chance: (self: Scheduler, probability: number, label: string?) -> boolean,
	pick: <T>(self: Scheduler, list: { T }, label: string?, weights: { number }?) -> T,
	spawn: (self: Scheduler, owner: any, fn: any, ...any) -> thread,
	defer: (self: Scheduler, owner: any, fn: any, ...any) -> thread,
	wait: (self: Scheduler, seconds: number?) -> number,
	after: (self: Scheduler, seconds: number, owner: any, fn: any, ...any) -> thread,
	park: (self: Scheduler) -> ...any,
	resume: (self: Scheduler, thread: thread, ...any) -> (),
	cancel: (self: Scheduler, thread: thread) -> (),
	crash: (self: Scheduler, owner: any) -> (),
	crashed: (self: Scheduler, owner: any) -> boolean,
	onFrame: (self: Scheduler, fn: (dt: number) -> (), owner: any) -> () -> (),
	drain: (self: Scheduler) -> (),
	frame: (self: Scheduler, dt: number?) -> number,
	runFor: (self: Scheduler, seconds: number) -> (),
	runUntil: (self: Scheduler, target: number | () -> boolean, limit: number?) -> boolean,
	idle: (self: Scheduler) -> boolean,
	running: (self: Scheduler) -> boolean,
	owns: (self: Scheduler, thread: thread) -> boolean,
	wakeDue: (self: Scheduler) -> (),
	host: (self: Scheduler, owner: any) -> HostHooks,
	trace: (self: Scheduler, text: string) -> (),
	digest: (self: Scheduler) -> number,
}

type Timer = {
	wake: number,
	seq: number,
	thread: thread,
	owner: any,
	args: { n: number, [number]: any }?,
	cancelled: boolean,
}
type Deferred = {
	seq: number,
	thread: thread,
	owner: any,
	args: { n: number, [number]: any },
	depth: number,
	cancelled: boolean,
}
type Hook = { fn: (dt: number) -> (), owner: any, active: boolean }

type State = {
	now: number,
	current: any,
	errors: { Failure },
	frames: number,
	random: boolean,
	seed: number,
	traced: { string },
	frameLength: number,
	fixedFrame: boolean,
	chooser: Chooser,
	seq: number,
	timers: { Timer },
	queue: { [number]: Deferred },
	head: number,
	tail: number,
	owners: { [thread]: any },
	waits: { [thread]: Timer },
	dead: { [any]: boolean },
	hooks: { Hook },
	depth: number,
	deferDepth: number,
	draining: boolean,
	hash: number,
	testThread: thread?,
}

local Scheduler = {}
Scheduler.__index = Scheduler
Scheduler.Config = Config

local function keyOf(owner: any): any return if owner == nil then MAIN else owner end

local function ownerOf(key: any): any return if key == MAIN then nil else key end

local foldFnv1a32 = Rng.foldFnv1a32
local function fold(s: State, text: string) s.hash = foldFnv1a32(s.hash, text) end

local function foldInt(s: State, prefix: number, value: number)
	local h = bit32.bxor(s.hash, prefix)
	for shift = 0, 24, 8 do
		h = (bit32.lshift(h, 24) + h * 403) % 4294967296
		h = bit32.bxor(h, bit32.band(bit32.rshift(value, shift), 0xff))
	end
	s.hash = (bit32.lshift(h, 24) + h * 403) % 4294967296
end

local function nextSeq(s: State): number
	s.seq += 1
	return s.seq
end

local function before(a: Timer, b: Timer): boolean return a.wake < b.wake or (a.wake == b.wake and a.seq < b.seq) end

local function push(heap: { Timer }, timer: Timer)
	table.insert(heap, timer)
	local i = #heap
	while i > 1 do
		local parent = i // 2
		if not before(heap[i], heap[parent]) then break end
		heap[i], heap[parent] = heap[parent], heap[i]
		i = parent
	end
end

local function pop(heap: { Timer }): Timer
	local top = heap[1]
	local last = table.remove(heap) :: Timer
	local n = #heap
	if n > 0 then
		heap[1] = last
		local i = 1
		while true do
			local l, r, smallest = i * 2, i * 2 + 1, i
			if l <= n and before(heap[l], heap[smallest]) then smallest = l end
			if r <= n and before(heap[r], heap[smallest]) then smallest = r end
			if smallest == i then break end
			heap[i], heap[smallest] = heap[smallest], heap[i]
			i = smallest
		end
	end
	return top
end

local function record(s: State, owner: any, err: any, thread: thread?)
	table.insert(s.errors, {
		owner = ownerOf(owner),
		message = Config.describeError(err),
		traceback = if thread ~= nil then debug.traceback(thread) else "",
		error = err,
	})
	fold(s, "e")
end

local drain: (s: State) -> ()

local function resume(s: State, thread: thread, owner: any, tag: number, ...: any)
	if s.dead[owner] then return end
	local status = coroutine.status(thread)
	if status ~= "suspended" then
		record(s, owner, `cannot resume a {status} thread`, nil)
		return
	end
	s.owners[thread] = owner
	local waiting = s.waits[thread]
	if waiting ~= nil then
		waiting.cancelled = true
		s.waits[thread] = nil
	end
	foldInt(s, 114, tag)
	local previous = s.current
	s.current = ownerOf(owner)
	s.depth += 1
	local ok, err = coroutine.resume(thread, ...)
	s.depth -= 1
	s.current = previous
	if not ok then record(s, owner, err, thread) end
	if s.depth == 0 then drain(s) end
end

function drain(s: State)
	if s.draining then return end
	s.draining = true
	while s.head <= s.tail do
		local entry = s.queue[s.head]
		s.queue[s.head] = nil
		s.head += 1
		if not entry.cancelled then
			s.deferDepth = entry.depth
			resume(s, entry.thread, entry.owner, entry.seq, table.unpack(entry.args, 1, entry.args.n))
			s.deferDepth = 0
		end
	end
	s.head, s.tail = 1, 0
	s.draining = false
end

local function enqueue(s: State, thread: thread, owner: any, ...: any)
	local depth = s.deferDepth + 1
	if depth > MAX_DEFER_DEPTH then
		record(s, owner, `Maximum re-entrancy depth ({MAX_DEFER_DEPTH}) exceeded calling task.defer`, nil)
		return
	end
	s.tail += 1
	s.queue[s.tail] = {
		seq = nextSeq(s),
		thread = thread,
		owner = owner,
		args = table.pack(...),
		depth = depth,
		cancelled = false,
	}
end

local function threadOf(fn: any): thread return if type(fn) == "thread" then fn else coroutine.create(fn) end

function Scheduler.new(options: Options?): Scheduler
	local given: Options = options or {}
	local seed = given.seed or 1
	local s: State = {
		now = 0,
		current = nil,
		errors = {},
		frames = 0,
		random = given.random == true,
		seed = seed,
		traced = {},
		frameLength = given.frame or MANUAL_FRAME,
		fixedFrame = given.random ~= true or given.frame ~= nil,
		chooser = given.chooser or Scheduler.seeded(seed),
		seq = 0,
		timers = {},
		queue = {},
		head = 1,
		tail = 0,
		owners = setmetatable({}, { __mode = "k" }) :: any,
		waits = setmetatable({}, { __mode = "k" }) :: any,
		dead = {},
		hooks = {},
		depth = 0,
		deferDepth = 0,
		draining = false,
		hash = 2166136261,
	}
	return setmetatable(s :: any, Scheduler) :: any
end

local function weighted(rng: Rng.Rng, n: number, weights: { number }?): number
	if weights == nil then return rng:int(1, n) end
	local total = 0
	for i = 1, n do
		total += weights[i] or 0
	end
	local point = rng:float() * total
	for i = 1, n do
		point -= weights[i] or 0
		if point < 0 then return i end
	end
	return n
end

function Scheduler.seeded(seed: number): Chooser
	local streams: { [string]: Rng.Rng } = {}
	return {
		choose = function(_self: any, n: number, label: string, weights: { number }?): number
			local rng = streams[label]
			if rng == nil then
				rng = Rng.new(Config.hash(`{seed}:choose:{label}`))
				streams[label] = rng
			end
			return weighted(rng, n, weights)
		end,
	}
end

function Scheduler.replay(list: { any }): Chooser
	local index = 0
	return {
		choose = function(_self: any, n: number, _label: string): number
			index += 1
			local item = list[index]
			local value = if type(item) == "table" then item.value else item
			return if type(value) == "number" and value >= 1 and value <= n then value else 1
		end,
	}
end

function Scheduler.fromGen(g: any, options: { note: boolean? }?): Chooser
	local note = options ~= nil and options.note == true
	return {
		choose = function(_self: any, n: number, label: string, weights: { number }?): number
			local value: number
			local total = 0
			local built: { { number } }? = nil
			if weights ~= nil then
				local items = table.create(n) :: { { number } }
				for i = 1, n do
					local w = math.max(weights[i] or 0, 0)
					total += w
					items[i] = { w, i }
				end
				built = items
			end
			if built ~= nil and total > 0 then
				value = g:weighted(built)
			else
				value = g:int(1, n)
			end
			if note then g:note(`{label}={value}/{n}`) end
			return value
		end,
	}
end

function Scheduler.record(inner: Chooser): Chooser & { choices: { Choice } }
	local recorder = { choices = {} :: { Choice } }
	function recorder.choose(_self: any, n: number, label: string, weights: { number }?): number
		local value = inner:choose(n, label, weights)
		table.insert(recorder.choices, { n = n, label = label, value = value })
		return value
	end
	return recorder :: any
end

function Scheduler.stream(s: State, name: string): Rng.Rng return Rng.new(Config.hash(`{s.seed}:{name}`)) end

function Scheduler.choose(s: State, n: number, label: string?, weights: { number }?): number
	if n <= 1 then return 1 end
	local name = label or "choice"
	local value = s.chooser:choose(n, name, weights)
	if type(value) ~= "number" or value ~= math.floor(value) or value < 1 or value > n then
		error(`chooser answered {tostring(value)} for {name}; expected 1..{n}`, 2)
	end
	foldInt(s, 99, value)
	return value
end

function Scheduler.chance(s: State, probability: number, label: string?): boolean
	if probability <= 0 then
		return false
	elseif probability >= 1 then
		return true
	end
	return Scheduler.choose(s, 2, label or "chance", { 1 - probability, probability }) == 2
end

function Scheduler.pick<T>(s: State, list: { T }, label: string?, weights: { number }?): T
	return list[Scheduler.choose(s, #list, label or "pick", weights)]
end

function Scheduler.spawn(s: State, owner: any, fn: any, ...: any): thread
	local thread = threadOf(fn)
	resume(s, thread, keyOf(owner), nextSeq(s), ...)
	return thread
end

function Scheduler.defer(s: State, owner: any, fn: any, ...: any): thread
	local thread = threadOf(fn)
	enqueue(s, thread, keyOf(owner), ...)
	return thread
end

local function yielder(s: State, thread: thread): any
	local owner = if s.depth > 0 then keyOf(s.current) else (s.owners[thread] or keyOf(s.current))
	s.owners[thread] = owner
	return owner
end

function Scheduler.wait(s: State, seconds: number?): number
	if not coroutine.isyieldable() then error("Scheduler.wait must be called from a thread that can yield", 2) end
	local thread = coroutine.running()
	if thread == s.testThread then error(ON_TEST_THREAD, util.outside()) end
	local owner = yielder(s, thread)
	local start = s.now
	local delay = if seconds ~= nil and seconds > 0 then seconds else 0
	local timer: Timer =
		{ wake = start + delay, seq = nextSeq(s), thread = thread, owner = owner, args = nil, cancelled = false }
	push(s.timers, timer)
	s.waits[thread] = timer
	coroutine.yield()
	if s.waits[thread] == timer then
		timer.cancelled = true
		s.waits[thread] = nil
	end
	return s.now - start
end

function Scheduler.after(s: State, seconds: number, owner: any, fn: any, ...: any): thread
	local thread = threadOf(fn)
	local key = keyOf(owner)
	s.owners[thread] = key
	push(s.timers, {
		wake = s.now + math.max(seconds, 0),
		seq = nextSeq(s),
		thread = thread,
		owner = key,
		args = table.pack(...),
		cancelled = false,
	})
	return thread
end

function Scheduler.park(s: State): ...any
	local thread = coroutine.running()
	if thread == s.testThread then error(ON_TEST_THREAD, util.outside()) end
	yielder(s, thread)
	return coroutine.yield()
end

function Scheduler.resume(s: State, thread: thread, ...: any)
	enqueue(s, thread, s.owners[thread] or keyOf(s.current), ...)
end

local function maybeCompactTimers(timers: { Timer }, cancelled: number)
	if cancelled > 32 and cancelled > #timers // 2 then
		local kept: { Timer } = {}
		for _, timer in timers do
			if not timer.cancelled then table.insert(kept, timer) end
		end
		table.clear(timers)
		for _, timer in kept do
			push(timers, timer)
		end
	end
end

function Scheduler.cancel(s: State, thread: thread)
	local cancelled = 0
	for _, timer in s.timers do
		if timer.thread == thread then timer.cancelled = true end
		if timer.cancelled then
			cancelled += 1
		end
	end
	maybeCompactTimers(s.timers, cancelled)
	for i = s.head, s.tail do
		if s.queue[i].thread == thread then s.queue[i].cancelled = true end
	end
	s.waits[thread] = nil
	if coroutine.status(thread) == "suspended" then coroutine.close(thread) end
end

function Scheduler.crash(s: State, owner: any)
	assert(owner ~= nil, "the test's own owner cannot crash")
	s.dead[owner] = true
	local cancelled = 0
	for _, timer in s.timers do
		if timer.owner == owner then timer.cancelled = true end
		if timer.cancelled then
			cancelled += 1
		end
	end
	maybeCompactTimers(s.timers, cancelled)
	for i = s.head, s.tail do
		if s.queue[i].owner == owner then s.queue[i].cancelled = true end
	end
	for i = #s.hooks, 1, -1 do
		local hook = s.hooks[i]
		if hook.owner == owner then
			hook.active = false
			table.remove(s.hooks, i)
		end
	end
	for thread, tOwner in s.owners do
		if tOwner == owner then
			s.waits[thread] = nil
			if thread ~= s.testThread and coroutine.status(thread) == "suspended" then coroutine.close(thread) end
		end
	end
	fold(s, "c")
end

function Scheduler.crashed(s: State, owner: any): boolean return s.dead[keyOf(owner)] == true end

function Scheduler.onFrame(s: State, fn: (dt: number) -> (), owner: any): () -> ()
	local hook: Hook = { fn = fn, owner = keyOf(owner), active = true }
	table.insert(s.hooks, hook)
	return function()
		hook.active = false
		local index = table.find(s.hooks, hook)
		if index ~= nil then table.remove(s.hooks, index) end
	end
end

function Scheduler.drain(s: State) drain(s) end

local function permute(s: State, list: { any }, first: number, last: number, label: string)
	for k = first, last - 1 do
		local c = Scheduler.choose(s, last - k + 1, label)
		if c > 1 then
			local item = table.remove(list, k + c - 1)
			table.insert(list, k, item)
		end
	end
end

local breathed = os.clock()

local function breathe(s: State)
	local every, fn = Config.breath, Config.breathe
	if fn == nil or every == false or s.depth > 0 or not coroutine.isyieldable() then return end
	if os.clock() - breathed >= (every :: number) then
		fn()
		breathed = os.clock()
	end
end

local FRAME_LEVELS = table.create(6)
for i = 1, 6 do
	FRAME_LEVELS[i] = MIN_FRAME + (i - 1) * (MAX_FRAME - MIN_FRAME) / 5
end

local function wakeTimers(s: State)
	if #s.timers == 0 or s.timers[1].wake > s.now + util.EPSILON then return end
	local due: { Timer } = {}
	while #s.timers > 0 and s.timers[1].wake <= s.now + util.EPSILON do
		local timer = pop(s.timers)
		if not timer.cancelled then table.insert(due, timer) end
	end
	if s.random then
		local first = 1
		for i = 2, #due + 1 do
			if i > #due or due[i].wake ~= due[first].wake then
				permute(s, due, first, i - 1, "tie")
				first = i
			end
		end
	end
	for _, timer in due do
		if timer.cancelled then continue end
		local args = timer.args
		if args == nil then
			if s.waits[timer.thread] == timer then resume(s, timer.thread, timer.owner, timer.seq) end
		else
			resume(s, timer.thread, timer.owner, timer.seq, table.unpack(args, 1, args.n))
		end
	end
end

function Scheduler.frame(s: State, dt: number?): number
	breathe(s)
	drain(s)
	local length = dt
	if length == nil then
		if s.fixedFrame then
			length = s.frameLength
		elseif Scheduler.chance(s, HITCH_CHANCE, "hitch") then
			length = HITCH
		else
			length = Scheduler.pick(s, FRAME_LEVELS, "frame")
		end
	end
	local step = length :: number
	s.now += step
	s.frames += 1
	foldInt(s, 102, s.frames)
	wakeTimers(s)
	if #s.hooks > 0 then
		local hooks = table.clone(s.hooks)
		if s.random then permute(s, hooks, 1, #hooks, "hooks") end
		for _, hook in hooks do
			if hook.active then resume(s, coroutine.create(hook.fn), hook.owner, nextSeq(s), step) end
		end
	end
	drain(s)
	return step
end

function Scheduler.runFor(s: State, seconds: number)
	local stop = s.now + seconds
	while s.now + util.EPSILON < stop do
		Scheduler.frame(s)
	end
end

function Scheduler.runUntil(s: State, target: number | () -> boolean, limit: number?): boolean
	drain(s)
	local stop = s.now + (limit or DEFAULT_LIMIT)
	local function reached(): boolean
		return if type(target) == "number" then s.now + util.EPSILON >= target else (target :: () -> boolean)()
	end
	while not reached() do
		if s.now + util.EPSILON >= stop then return false end
		Scheduler.frame(s)
	end
	return true
end

function Scheduler.idle(s: State): boolean
	if s.head <= s.tail then return false end
	for _, timer in s.timers do
		if not timer.cancelled then return false end
	end
	return true
end

function Scheduler.running(s: State): boolean return s.depth > 0 end

function Scheduler.owns(s: State, thread: thread): boolean return s.owners[thread] ~= nil end

function Scheduler.wakeDue(s: State)
	drain(s)
	wakeTimers(s)
	drain(s)
end

function Scheduler.host(s: State, owner: any): HostHooks
	return {
		clock = function(): number return s.now end,
		wait = function(seconds: number?): number return Scheduler.wait(s, seconds) end,
		spawn = function(fn: any, ...: any): thread return Scheduler.spawn(s, owner, fn, ...) end,
		defer = function(fn: any, ...: any): thread return Scheduler.defer(s, owner, fn, ...) end,
		resume = function(thread: thread, ...: any) Scheduler.resume(s, thread, ...) end,
	}
end

function Scheduler.trace(s: State, text: string)
	local traced = s.traced
	table.insert(traced, text)
	if #traced > 2 * TRACE_LIMIT then
		table.move(traced, TRACE_LIMIT + 1, #traced, 1)
		for i = #traced, #traced - TRACE_LIMIT + 1, -1 do
			traced[i] = nil
		end
	end
	fold(s, "t")
	fold(s, text)
end

function Scheduler.digest(s: State): number return s.hash end

export type ExploreLimits = { maxChoices: number?, maxRuns: number?, maxBranch: number? }
export type ExploreFailure = { choices: { number }, error: any }
export type ExploreOutcome = {
	runs: number,
	truncated: boolean,
	limit: ("maxRuns" | "maxChoices")?,
	failure: ExploreFailure?,
}

local Explore = {}

function Explore.run(body: (chooser: Chooser) -> (), limits: ExploreLimits?): ExploreOutcome
	local given: ExploreLimits = limits or {}
	local maxChoices = given.maxChoices or 64
	local maxRuns = given.maxRuns or 10000
	local maxBranch = given.maxBranch or math.huge
	local prefix: { number } = {}
	local runs, branched = 0, false
	local limit: ("maxRuns" | "maxChoices")? = nil
	while true do
		if runs >= maxRuns then return { runs = runs, truncated = true, limit = "maxRuns", failure = nil } end
		runs += 1
		local values, sizes: { number } = {}, {}
		local chooser: Chooser = {
			choose = function(_self: any, n: number, _label: string): number
				local index = #values + 1
				if index > maxChoices then
					limit = "maxChoices"
					return 1
				end
				local value = math.min(prefix[index] or 1, n)
				values[index], sizes[index] = value, n
				if n > maxBranch then branched = true end
				return value
			end,
		}
		local ok, err = pcall(function() body(chooser) end)
		if not ok then
			return {
				runs = runs,
				truncated = branched or limit ~= nil,
				limit = limit,
				failure = { choices = values, error = err },
			}
		end
		local depth = #values
		while depth > 0 and values[depth] >= math.min(sizes[depth], maxBranch) do
			depth -= 1
		end
		if depth == 0 then
			return { runs = runs, truncated = branched or limit ~= nil, limit = limit, failure = nil }
		end
		prefix = table.move(values, 1, depth - 1, 1, {})
		prefix[depth] = values[depth] + 1
	end
end

Scheduler.Explore = table.freeze(Explore)

local Coop = {}

function Coop.new(world: any, keep: boolean, time: { now: number }?): any
	local clock: { now: number } = time or world.clock
	local c: any = { deferred = {}, threads = {}, sleeps = {}, onWait = nil }
	local function resumeCoop(thread: thread, ...: any)
		local ok, err = coroutine.resume(thread, ...)
		if not ok then error(err, 0) end
		if keep and coroutine.status(thread) == "suspended" then table.insert(c.threads, thread) end
	end
	function c.spawn(_self: any, fn: (...any) -> ...any, ...: any): thread
		local thread = coroutine.create(fn)
		resumeCoop(thread, ...)
		return thread
	end
	function c.pump(self: any)
		if keep then
			repeat
				local deferred, threads = self.deferred, self.threads
				self.deferred, self.threads = {}, {}
				for _, call in deferred do
					self:spawn(call[1], table.unpack(call, 2, call.n))
				end
				for _, thread in threads do
					if coroutine.status(thread) == "suspended" then resumeCoop(thread) end
				end
			until #self.deferred == 0
		else
			while #self.deferred > 0 do
				local queued = self.deferred
				self.deferred = {}
				local hostSpawn = if self.host then self.host.spawn else nil
				for _, call in queued do
					if hostSpawn then
						hostSpawn(call[1], table.unpack(call, 2, call.n))
					else
						self:spawn(call[1], table.unpack(call, 2, call.n))
					end
				end
			end
		end
	end
	c.hooks = {
		clock = function(): number return clock.now end,
		wait = function(seconds: number): boolean
			table.insert(c.sleeps, seconds)
			clock.now += seconds
			if c.onWait then (c.onWait :: (...any) -> ())(seconds) end
			c:pump()
			return true
		end,
		spawn = function(fn: (...any) -> ...any, ...: any): thread return c:spawn(fn, ...) end,
		defer = function(fn: (...any) -> ...any, ...: any) table.insert(c.deferred, table.pack(fn, ...)) end,
	}
	return setmetatable({}, {
		__index = function(_: any, key: any): any return if key == "now" then clock.now else c[key] end,
		__newindex = function(_: any, key: any, value: any)
			if key == "now" then
				clock.now = value
			else
				c[key] = value
			end
		end,
	})
end

Scheduler.Coop = table.freeze(Coop)

return table.freeze(Scheduler)
