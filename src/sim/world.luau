--!strict
-- Simulated multi-server fleet running on a shared virtual-time scheduler (`sim/scheduler.luau`) and
-- shared `DataStore`, `MemoryStore`, `MessagingService`, and remote services (`sim/services.luau`).
local DataStoreDouble = require("../doubles/datastore")
local Encoding = require("../doubles/encoding_service")
local Env = require("../env")
local Scheduler = require("./scheduler")
local Services = require("./services")
local Signal = require("../doubles/signal")
local format = require("../format")
local util = require("../util")

local Config, Coop, Http = Scheduler.Config, Scheduler.Coop, Encoding.HttpService
local DataStore, MemoryStore, Messaging = Services.datastore, Services.memorystore, Services.messaging
local Players, Remotes, RunService = Services.players, Services.remotes, Services.run_service
local CLOSE_SECONDS = 30

export type PeerInfo = {
	peerId: string,
	userId: number,
	Name: string,
	UserId: number,
	[string]: any,
}
export type RemoteError = {
	peerId: string,
	remote: string,
	err: string,
	time: number,
}
export type FaultConfig = {
	profile: string?,
	before: number?,
	after: number?,
	late: number?,
	retransform: number?,
	stale: number?,
	drift: number?,
	crash: number?,
	evict: number?,
	subscribe: number?,
	drop: number?,
	duplicate: number?,
	budget: number?,
	remoteDropRate: number?,
	remoteReorderRate: number?,
	remoteDuplicateRate: number?,
	remoteLatencyRange: { number }?,
}
export type Faults = {
	before: number, -- service call fails before it takes effect
	after: number, -- #1 ... after it took effect (the reply is lost)
	late: number, -- #2 write detaches and lands late (after timeout or server crash)
	retransform: number, -- #3 UpdateAsync transform runs again (spurious retry or post-answer late run)
	stale: number, -- #4 read returns an older committed snapshot from version history
	drift: number, -- #5 server/client clock jumps forward or backward mid-run
	crash: number, -- #6 server crashes (or restarts) at yield boundaries / between steps
	evict: number, -- #7 MemoryStore spontaneously drops keys or queue items
	subscribe: number, -- SubscribeAsync fails
	drop: number, -- a message or unreliable packet is lost
	duplicate: number, -- a message arrives twice
	budget: number?, -- DataStore request units per minute and type per server (nil: unmodelled)
	remoteDropRate: number?, -- probability [0, 1] that an unreliable or fault-injected remote packet is dropped
	remoteReorderRate: number?, -- probability [0, 1] that a remote packet is delayed past the next packet
	remoteDuplicateRate: number?, -- probability [0, 1] that a remote packet is delivered twice
	remoteLatencyRange: { number }?, -- { minSec, maxSec } simulated network transit delay (default { 0, 0 })
}
export type Options = {
	scheduler: Scheduler.Scheduler?,
	mode: ("manual" | "random")?,
	seed: number?,
	frame: number?,
	-- A profile name, or a table overriding fields of `profile` (default "none").
	faults: (string | FaultConfig | { [string]: any })?,
	-- Enable VOPR swarm fault matrix generation (default true when profile is "vopr" in random mode).
	swarm: boolean?,
	-- Automatically restart spontaneously crashed servers into a new incarnation (default true under "vopr").
	autoRestart: boolean?,
	wait: ("yield" | "instant")?,
	placeId: number?,
	-- Options for the backing store's `new` (its `clock` defaults to the world's Unix time).
	datastore: { [string]: any }?,
	-- The backing DataStore (`{ new, copy? }`, `true` for the built-in DataStore double, `false` for none); default
	-- `Config.datastore`, else the built-in double.
	backing: (Scheduler.Backing | boolean)?,
	-- MessagingService options: `json = true` sends non-buffer payloads as their JSON (the engine's
	-- form), so each subscriber gets a decoded table of its own.
	messaging: { json: boolean? }?,
	-- Fixed latencies by kind (a service name, "delivery", "remotes"), in any mode.
	latency: { [string]: number }?,
	-- Coarse choices for exhaustive exploration (random mode): two latency levels per kind (fast, slow)
	-- and one Heartbeat hook firing every live server in slot order, so frames add no choice points.
	coarse: boolean?,
}

local PROFILES: { [string]: Faults } = {
	none = {
		before = 0,
		after = 0,
		late = 0,
		retransform = 0,
		stale = 0,
		drift = 0,
		crash = 0,
		evict = 0,
		subscribe = 0,
		drop = 0,
		duplicate = 0,
		remoteDropRate = 0,
		remoteReorderRate = 0,
		remoteDuplicateRate = 0,
	},
	light = {
		before = 0.01,
		after = 0.01,
		late = 0,
		retransform = 0,
		stale = 0,
		drift = 0,
		crash = 0,
		evict = 0,
		subscribe = 0.02,
		drop = 0.02,
		duplicate = 0.01,
		remoteDropRate = 0,
		remoteReorderRate = 0,
		remoteDuplicateRate = 0,
	},
	heavy = {
		before = 0.02,
		after = 0.02,
		late = 0,
		retransform = 0,
		stale = 0,
		drift = 0,
		crash = 0,
		evict = 0,
		subscribe = 0.05,
		drop = 0.1,
		duplicate = 0.05,
		budget = 30,
		remoteDropRate = 0,
		remoteReorderRate = 0,
		remoteDuplicateRate = 0,
	},
	vopr = {
		before = 0.02,
		after = 0.03,
		late = 0.03,
		retransform = 0.03,
		stale = 0.04,
		drift = 0.03,
		crash = 0.02,
		evict = 0.04,
		subscribe = 0.03,
		drop = 0.05,
		duplicate = 0.03,
		remoteDropRate = 0.05,
		remoteReorderRate = 0.05,
		remoteDuplicateRate = 0.03,
	},
}
local SWARM_KEYS: { string } = table.freeze({
	"before",
	"after",
	"late",
	"retransform",
	"stale",
	"drift",
	"crash",
	"evict",
	"subscribe",
	"drop",
	"duplicate",
	"remoteDropRate",
	"remoteReorderRate",
	"remoteDuplicateRate",
})
local SWARM_LEVELS: { [string]: { number } } = {
	before = { 0, 0.02, 0.06, 0.15 },
	after = { 0, 0.02, 0.08, 0.2 },
	late = { 0, 0.02, 0.08, 0.2 },
	retransform = { 0, 0.02, 0.08, 0.2 },
	stale = { 0, 0.03, 0.1, 0.25 },
	drift = { 0, 0.02, 0.08, 0.2 },
	crash = { 0, 0.01, 0.04, 0.1 },
	evict = { 0, 0.03, 0.1, 0.25 },
	subscribe = { 0, 0.02, 0.06, 0.15 },
	drop = { 0, 0.03, 0.1, 0.25 },
	duplicate = { 0, 0.02, 0.06, 0.15 },
	remoteDropRate = { 0, 0.03, 0.1, 0.25 },
	remoteReorderRate = { 0, 0.03, 0.1, 0.25 },
	remoteDuplicateRate = { 0, 0.02, 0.06, 0.15 },
}
local SWARM_WEIGHTS = { 55, 25, 14, 6 }
local VALID_WHENS = {
	before = true,
	after = true,
	late = true,
	retransform = true,
	stale = true,
	drift = true,
	crash = true,
	evict = true,
}
-- Latency levels (seconds) and weights by service; the first level is an explorer's default.
local LATENCY: { [string]: { levels: { number }, weights: { number } } } = {
	DataStoreService = { levels = { 0.05, 0.1, 0.2, 0.5, 1, 3 }, weights = { 30, 30, 20, 12, 6, 2 } },
	MemoryStoreService = { levels = { 0.02, 0.05, 0.1, 0.3 }, weights = { 40, 30, 20, 10 } },
	MessagingService = { levels = { 0.05, 0.1, 0.2, 0.5 }, weights = { 40, 30, 20, 10 } },
	delivery = { levels = { 0.05, 0.1, 0.25, 0.5, 1, 5 }, weights = { 30, 30, 20, 10, 8, 2 } },
	remotes = { levels = { 0.03, 0.06, 0.1, 0.2, 0.5 }, weights = { 30, 30, 20, 15, 5 } },
}
local SERVER_OPTIONS = { slot = true, restarts = true, skew = true, jobId = true, build = true }
local WORLD_KEYS = {
	scheduler = true,
	mode = true,
	seed = true,
	frame = true,
	faults = true,
	swarm = true,
	autoRestart = true,
	wait = true,
	placeId = true,
	datastore = true,
	backing = true,
	messaging = true,
	latency = true,
	coarse = true,
}
local SKEWS, SKEW_WEIGHTS, KICK_DELAYS = { 0, 1, -1, 3, -3, 200 }, { 50, 15, 15, 8, 8, 4 }, { 0, 0.25, 0.5, 1 }
local LATE_DELAYS = { 0.15, 0.4, 1.2, 3 }
local DRIFT_DELTAS = { -30, -5, -1, 1, 5, 30 }

local World = {}
World.__index = World
local Server = {}
Server.__index = Server

-- Instance types, for annotations (`local world: Sim.World = Sim.World.new(...)`). The constructors return `any`, since
-- `World.extend` classes add methods of their own; these name the fields and methods every world, server and client has.
export type World = typeof(World) & {
	scheduler: Scheduler.Scheduler,
	mode: "manual" | "random",
	instant: boolean,
	placeId: number,
	servers: { Server },
	kicks: { any },
	remoteErrors: { RemoteError },
	profile: string,
	faults: Faults,
	coarse: boolean,
	count: number,
	clock: { now: number },
	coop: any, -- sim/coop.luau's hooks (instant waits only)
	datastore: any, -- the shared DataStore service (sim/services/datastore.luau), nil with `backing = false`
	memory: any, -- sim/services/memorystore.luau
	messaging: any, -- sim/services/messaging.luau
}
export type Server = typeof(Server) & {
	world: World,
	n: number,
	slot: number,
	restarts: number,
	name: string,
	jobId: string,
	skew: number,
	build: any,
	state: string, -- "up", "closing", "crashed" or "down"
	studio: boolean,
	kicks: { any },
	host: { [string]: any }, -- every Host key bound to this server (see the header)
	players: any, -- sim/services/players.luau
	run: any, -- sim/services/run_service.luau
}
export type Client = {
	name: string,
	index: number,
	gone: boolean,
	server: Server,
	world: World,
	player: any,
	remotes: { [string]: any }, -- the client's end of each channel ("reliable", "unreliable")
	host: { [string]: any },
	spawn: (self: Client, fn: (...any) -> ...any, ...any) -> any,
	env: (self: Client, options: Env.Options?) -> any,
	leave: (self: Client) -> (),
}

local function addHook(list: { any }, item: any): () -> ()
	table.insert(list, item)
	return function()
		local index = table.find(list, item)
		if index then table.remove(list, index) end
	end
end

function World.new(options: Options?, class: any?): any
	local o: Options = options or {}
	assert(type(o) == "table", "World.new: options must be a table")
	for key in o :: { [string]: any } do
		assert(WORLD_KEYS[key], `World.new: unknown option {tostring(key)}`)
	end
	local mode = o.mode or "manual"
	local instant = o.wait == "instant"
	local s = o.scheduler or Scheduler.new({ seed = o.seed, random = mode == "random", frame = o.frame })
	if o.scheduler == nil and not instant then
		local cur = coroutine.running()
		if cur ~= nil and s.testThread == nil and not s:running() and not s:owns(cur) then s.testThread = cur end
	end
	local w: any = setmetatable({
		scheduler = s,
		mode = mode,
		instant = instant,
		placeId = o.placeId or 1,
		servers = {},
		kicks = {},
		gates = {},
		scripted = {},
		commits = {},
		reported = {},
		hooks = {},
		actions = {},
		remoteErrors = {},
		_serverRemotes = {},
		_clientRemotes = {},
		_remoteQueue = {},
		_remoteSeq = 0,
		pendingCloud = 0,
		fixed = o.latency or {},
		coarse = o.coarse == true,
		count = 0,
		slots = 0,
	}, class or World)
	local given = o.faults
	local name = if type(given) == "string"
		then given
		elseif type(given) == "table" then given.profile or "none"
		elseif mode == "random" then s:pick({ "none", "light", "heavy" }, "faults")
		else "none"
	assert(PROFILES[name], `unknown fault profile {name}`)
	w.profile, w.faults = name, table.clone(PROFILES[name])
	local useSwarm = if o.swarm ~= nil then o.swarm else (name == "vopr" and mode == "random")
	w.swarm = useSwarm
	w.autoRestart = if o.autoRestart ~= nil then o.autoRestart else (name == "vopr")
	if useSwarm then
		for _, k in SWARM_KEYS do
			w.faults[k] = s:pick(SWARM_LEVELS[k], `swarm.{k}`, SWARM_WEIGHTS)
		end
	end
	if type(given) == "table" then
		for key, value in given :: { [string]: any } do
			if key ~= "profile" then
				assert(
					(PROFILES.none :: any)[key] ~= nil or key == "budget" or key == "remoteLatencyRange",
					`unknown fault {tostring(key)}`
				)
				w.faults[key] = value
			end
		end
	end
	w.unixTime = function(): number return util.UNIX_EPOCH + s.now end
	-- A table whose `now` is the scheduler's clock, for doubles that keep time in a `now` field.
	w.clock = setmetatable({}, {
		__index = function(_: any, key: any): any return if key == "now" then s.now else nil end,
		__newindex = function(_: any, key: any, value: any)
			assert(key == "now", "only now can be set")
			s.now = value
		end,
	})
	if w.instant then w.coop = Coop.new(w, false) end
	local backing: any = if o.backing == false
		then nil
		elseif o.backing == true then DataStoreDouble
		else o.backing or Config.datastore or DataStoreDouble
	if backing ~= nil then w.datastore = DataStore.new(w, o.datastore :: any, backing) end
	w.memory = MemoryStore.new(w.clock, {
		wait = function(seconds: number)
			if not w.instant and coroutine.isyieldable() then
				s:wait(seconds)
			else
				s.now += seconds
			end
		end,
	})
	w.messaging = Messaging.new(w)
	if o.messaging ~= nil and o.messaging.json then w.messaging.json = true end
	if w.coarse and not w.instant then
		s:onFrame(function(dt: number)
			for _, server in table.clone(w.servers) :: { any } do
				if server.state == "up" or server.state == "closing" then
					RunService.step(server.run, dt, s.now)
					if server._net ~= nil then
						for _, client in server._net.clients do
							if not client.gone then RunService.step(client.run, dt, s.now) end
						end
						server._net:flush()
					end
				end
			end
		end, nil, true)
	end
	s:trace(`world {mode} faults={name}`)
	return w
end

-- Time, choices and the call proxy --------------------------------------------------------------------

--- Unix seconds on the world's clock (servers add their skew).
function World.unix(w: any): number return w.unixTime() end

--- A latency for `kind` (a service name, "delivery" or "remotes"): the fixed one when given, else 0 in
--- manual mode and a choice in random mode.
function World.latency(w: any, kind: string): number
	local fixed = w.fixed[kind]
	if fixed ~= nil then
		return fixed
	elseif w.mode ~= "random" then
		return 0
	end
	local spec = LATENCY[kind]
	if w.coarse then return w.scheduler:pick({ spec.levels[1], spec.levels[#spec.levels - 1] }, `{kind}.latency`) end
	return w.scheduler:pick(spec.levels, `{kind}.latency`, spec.weights)
end

--- Waits one latency of `kind` (nothing when it is 0).
function World.pause(w: any, kind: string)
	local delay = w:latency(kind)
	if delay > 0 then w.scheduler:wait(delay) end
end

--- Tail delay (seconds) for a detached late write or post-answer re-transform.
function World.lateDelay(w: any): number
	if w.instant then return 0 end
	if w.mode ~= "random" then return w.fixed.DataStoreService or 0.25 end
	if w.coarse then return w.scheduler:pick({ LATE_DELAYS[1], LATE_DELAYS[#LATE_DELAYS] }, "late.delay") end
	return w.scheduler:pick(LATE_DELAYS, "late.delay")
end

--- Schedules `fn()` on the cloud/network timeline (`owner = nil`) so it survives `server:crash()`.
function World.detach(w: any, delay: number, fn: () -> ())
	if w.instant then
		fn()
		return
	end
	w.pendingCloud = (w.pendingCloud or 0) + 1
	local function tracked()
		local ok, err = pcall(fn :: any)
		w.pendingCloud = math.max(0, (w.pendingCloud or 0) - 1)
		if not ok then error(err, 0) end
	end
	if delay <= 0 then
		w.scheduler:spawn(nil, tracked)
	else
		w.scheduler:after(delay, nil, tracked)
	end
end

--- Runs a DataStore or MemoryStore transform on a fresh thread; a yield is an error, as in the engine.
--- Returns its results packed.
function World.transform(_w: any, fn: (...any) -> ...any, ...: any): { n: number, [number]: any }
	local thread = coroutine.create(fn)
	local results = table.pack(coroutine.resume(thread, ...))
	if not results[1] then
		error(results[2], 0)
	elseif coroutine.status(thread) ~= "dead" then
		coroutine.close(thread)
		error("UpdateAsync: the transform function yielded; transforms cannot yield", 0)
	end
	return table.pack(table.unpack(results, 2, results.n))
end

--- Checks whether fault `when` fires on `service.method` (either scripted via `world:fail` or probabilistic).
function World.shouldFault(
	w: any,
	server: any,
	service: string,
	method: string,
	key: string,
	when: string
): (boolean, string?)
	local queue = w.scripted[key]
	local head = if queue then queue[1] else nil
	if head ~= nil and head.when == when then
		table.remove(queue, 1)
		w:trace(`fault {when} {key} on {if server then server.name else "?"}: {head.message}`)
		return true, head.message
	end
	local field = if method == "SubscribeAsync" then (if when == "before" then "subscribe" else nil) else when
	local probability = if field then (w.faults[field] or 0) else 0
	if probability > 0 and w.scheduler:chance(probability, `{service}.{when}`) then
		w:trace(`fault {when} {key} on {if server then server.name else "?"}`)
		return true, `{method}: connection lost (injected {when})`
	end
	return false, nil
end

-- `key` is `{service}.{method}`, built once per call by World.call.
local function fault(w: any, server: any, service: string, method: string, key: string, when: string)
	local triggered, msg = w:shouldFault(server, service, method, key, when)
	if triggered then error(msg or `{method}: connection lost (injected {when})`, 0) end
end

export type CallOptions = {
	mutates: boolean?,
	stale: (() -> (boolean, ...any))?,
}

--- Extended service call proxy supporting VOPR hazards (`mutates` for detached late writes, `stale` for old snapshots).
function World.callOpts(
	w: any,
	server: any,
	service: string,
	method: string,
	opts: CallOptions?,
	body: (...any) -> ...any,
	...: any
): ...any
	local key = `{service}.{method}`
	local gate = w.gates[key]
	if gate ~= nil then gate:enter() end

	-- #5 Dynamic clock drift
	if server ~= nil then
		local drifted = w:shouldFault(server, service, method, key, "drift")
		if drifted then
			local delta = if w.mode == "random" then w.scheduler:pick(DRIFT_DELTAS, "drift.delta") else 5
			server:drift(delta)
		end
	end

	-- #7 MemoryStore spontaneous key/queue eviction
	if w:shouldFault(server, service, method, key, "evict") then
		local pickFn = if w.mode == "random"
			then function(items: { any }): any return w.scheduler:pick(items, "ms.evict") end
			else nil
		local victim = w.memory:evict(nil, nil, pickFn)
		if victim ~= nil then w:trace(`ms evict {victim}`) end
	end

	-- #2 Late write (write detaches onto cloud timeline; caller gets a timeout error or server crashes)
	local args = table.pack(...)
	local mutates = opts ~= nil and opts.mutates == true
	local isLate, lateMsg = false, nil
	if mutates then
		isLate, lateMsg = w:shouldFault(server, service, method, key, "late")
	end

	-- #6 Spontaneous server crash at yield boundary
	if server ~= nil and server.state == "up" and w:shouldFault(server, service, method, key, "crash") then
		if mutates and (isLate or (w.mode == "random" and w.scheduler:chance(0.5, "crash.afterSend"))) then
			local delay = w:lateDelay()
			w:trace(`late in-flight {key} detached from crashing {server.name}`)
			w:detach(delay, function() pcall(body, table.unpack(args, 1, args.n)) end)
		end
		if w.autoRestart then
			server:restart()
			server.autoRestarted = true
		else
			server:crash()
		end
		error(`{method}: server {server.name} crashed`, 0)
	end

	local srv: any = server
	local srvName: string = if srv ~= nil then srv.name else "?"

	if isLate then
		w:pause(service)
		local delay = w:lateDelay()
		w:trace(`late write {key} scheduled (+{string.format("%.2f", delay)}s) from {srvName}`)
		w:detach(delay, function() pcall(body, table.unpack(args, 1, args.n)) end)
		error(lateMsg or `{method}: connection lost (injected late)`, 0)
	end

	-- #4 Stale read from version history
	if opts ~= nil and opts.stale ~= nil and w:shouldFault(server, service, method, key, "stale") then
		w:pause(service)
		local staleResults = table.pack((opts.stale :: any)())
		if staleResults[1] == true then
			w:trace(`stale read {key} on {srvName}`)
			w:pause(service)
			fault(w, server, service, method, key, "after")
			return table.unpack(staleResults, 2, staleResults.n)
		end
	end

	-- Register in-flight mutation on the server so an external `server:crash()` during `w:pause` still lands the write late
	local inflightEntry: any = nil
	local inflightList: { any }? = if srv ~= nil then srv.inflight else nil
	if mutates and inflightList ~= nil and not w.instant then
		inflightEntry = {
			key = key,
			run = function() pcall(body, table.unpack(args, 1, args.n)) end,
		}
		table.insert(inflightList, inflightEntry)
	end

	w:pause(service)
	if inflightEntry ~= nil and inflightList ~= nil then
		local idx = table.find(inflightList, inflightEntry)
		if idx ~= nil then table.remove(inflightList, idx) end
	end
	fault(w, server, service, method, key, "before")
	local results = table.pack(body(table.unpack(args, 1, args.n)))
	w:pause(service)
	fault(w, server, service, method, key, "after")
	return table.unpack(results, 1, results.n)
end

--- The service call proxy: gate, request latency, fault before, `body(...)` (atomic), reply latency,
--- fault after. Returns what `body` returned.
function World.call(
	w: any,
	server: any,
	service: string,
	method: string,
	body: (...any) -> ...any,
	...: any
): ...any
	return w:callOpts(server, service, method, nil, body, ...)
end

--- Holds every call of `service.method` at its gate until `gate:release(n?)` lets the first `n` waiting
--- calls through (all of them, and stops holding, without `n`). `gate.waiting` lists the held threads and
--- `gate.calls` counts arrivals.
function World.hold(w: any, service: string, method: string): any
	local key = `{service}.{method}`
	local gate: any = { held = true, waiting = {}, calls = 0 }
	function gate.enter(g: any)
		if not g.held then return end
		g.calls += 1
		local thread = coroutine.running()
		table.insert(g.waiting, thread)
		while table.find(g.waiting, thread) do
			if w.instant then
				coroutine.yield()
			else
				w.scheduler:park()
			end
		end
	end
	function gate.release(g: any, n: number?)
		if n == nil then
			g.held = false
			if w.gates[key] == g then w.gates[key] = nil end
		end
		local remaining = n or #g.waiting
		while remaining > 0 and #g.waiting > 0 do
			local thread = table.remove(g.waiting, 1) :: thread
			local owner = w.scheduler.owners[thread]
			if coroutine.status(thread) ~= "suspended" or (owner ~= nil and w.scheduler:crashed(owner)) then
				continue
			end
			remaining -= 1
			if w.instant then
				local ok, err = coroutine.resume(thread)
				if not ok then error(err, 0) end
			else
				w.scheduler:resume(thread)
			end
		end
	end
	w.gates[key] = gate
	return gate
end

--- The next call of `service.method` injects fault `when` ("before", "after", "late", "retransform", "stale", "drift", "crash", "evict").
function World.fail(w: any, service: string, method: string, when: string, message: string?)
	assert(VALID_WHENS[when], "when must be before, after, late, retransform, stale, drift, crash, or evict")
	local key = `{service}.{method}`
	w.scripted[key] = w.scripted[key] or {}
	table.insert(w.scripted[key], { when = when, message = message or `{method}: connection lost` })
end

--- Records a high-level spec action transition in `world.actions` for trace refinement (`spec:verifyTrace`) and TLA+ export.
function World.action(w: any, actionName: string, arg: any?, stateProjection: any?, result: any?): any
	local entry = {
		step = #w.actions + 1,
		t = w.scheduler.now,
		action = actionName,
		arg = util.copy(arg),
		result = util.copy(result),
		state = if stateProjection ~= nil then util.copy(stateProjection) else nil,
	}
	table.insert(w.actions, entry)
	w:trace(`action #{entry.step} {actionName}`)
	return entry
end

--- Exports the world's recorded actions and DataStore/MemoryStore state as a TLA+ / Apalache-compatible JSON trace string.
function World.tlaTrace(w: any, specName: string?): string
	local states: { any } = {}
	for i, entry in w.actions do
		table.insert(states, {
			_step = i,
			_t = entry.t,
			_action = entry.action,
			_arg = entry.arg,
			_result = entry.result,
			state = entry.state,
		})
	end
	return format.json({
		spec = specName or "WorldTrace",
		digest = w:digest(),
		states = states,
	})
end

--- Injects a between-step server crash (or restart when `autoRestart` is enabled) according to `faults.crash`.
function World.maybeCrashStep(w: any): any?
	local prob = w.faults.crash or 0
	if prob <= 0 then return nil end
	local live: { any } = {}
	for _, srv in w.servers do
		if srv.state == "up" then table.insert(live, srv) end
	end
	if #live == 0 or not w.scheduler:chance(prob, "step.crash") then return nil end
	local victim = if w.mode == "random" then w.scheduler:pick(live, "step.crash.server") else live[1]
	if w.autoRestart then
		local nextSrv = victim:restart()
		victim.autoRestarted = true
		return nextSrv
	else
		victim:crash()
		return victim
	end
end

--- Runs `fn(...)` as `owner`: at once on this thread with instant waits, else on a new thread of `owner`.
function World.dispatch(w: any, owner: any, fn: any, ...: any)
	if w.instant then
		fn(...)
	else
		w.scheduler:spawn(owner, fn, ...)
	end
end

--- A signal whose handlers run as `owner`: each on a new thread ("spawn", RunService) or deferred
--- ("defer", Players; the engine's deferred signal behaviour); at once with instant waits.
function World.signal(w: any, owner: any, mode: string?): any
	if w.instant then return Signal.new() end
	return Signal.fromWorld(w, owner, nil, mode ~= "defer")
end

--- Calls `fn(dt)` every frame (not tied to a server); returns a disconnect function.
function World.onFrame(w: any, fn: (dt: number) -> ()): () -> ()
	return if w.instant then addHook(w.hooks, fn) else w.scheduler:onFrame(fn, nil)
end

--- One frame (`dt` or the mode's length). With instant waits: advance the clock, fire every live
--- server's Heartbeat and the frame hooks, then pump deferred work.
function World.step(w: any, dt: number?): number
	if not w.instant then
		local step = w.scheduler:frame(dt)
		w:_flushDueRemotes()
		return step
	end
	local step = dt or 0.1
	w.scheduler.now += step
	for _, server in table.clone(w.servers) :: { any } do
		if server.state == "up" then
			RunService.step(server.run, step, w.scheduler.now)
			if server._net ~= nil then
				for _, client in server._net.clients do
					if not client.gone then RunService.step(client.run, step, w.scheduler.now) end
				end
				server._net:flush()
			end
		end
	end
	w:_flushDueRemotes()
	for _, fn in table.clone(w.hooks) :: { (number) -> () } do
		fn(step)
	end
	w.coop:pump()
	return step
end

--- Runs frames for `seconds` of virtual time.
function World.run(w: any, seconds: number)
	local s = w.scheduler
	local stop = s.now + seconds
	while s.now + util.EPSILON < stop do
		w:step()
	end
end

function World.runUntil(w: any, target: number | () -> boolean, limit: number?): boolean
	if not w.instant then return w.scheduler:runUntil(target, limit) end
	w.coop:pump()
	local s = w.scheduler
	local stop = s.now + (limit or 3600)
	local function reached(): boolean
		return if type(target) == "number" then s.now + util.EPSILON >= target else (target :: () -> boolean)()
	end
	while not reached() do
		if s.now + util.EPSILON >= stop then return false end
		w:step()
	end
	return true
end

-- Faults, hooks and reports ----------------------------------------------------------------------------

--- Blacks `server` out from MessagingService both ways for `seconds`.
function World.partition(w: any, server: any, seconds: number) w.messaging:partition(server, seconds) end

--- Isolates `server` from MessagingService until `world:heal()`.
function World.isolate(w: any, server: any) w.messaging:partition(server, 1e9) end

--- Returns true when `server` is currently partitioned from MessagingService.
function World.isolated(w: any, server: any): boolean return w.messaging:partitioned(server) end

--- Ends every partition.
function World.heal(w: any) w.messaging:heal() end

--- Calls `fn(store, key, row, server)` after every committed DataStore write (`store` is
--- `{ name, scope, ordered, handle }`, `row` the stored row or nil); returns a disconnect function.
function World.onCommit(w: any, fn: (store: any, key: string, row: any, server: any) -> ()): () -> ()
	return addHook(w.commits, fn)
end

function World.commit(w: any, store: any, key: string, row: any, server: any)
	local on = if server ~= nil then server.name else "?"
	w:trace(`ds commit {store.name}/{key} on {on}{if row == nil then " (removed)" else ""}`)
	for _, fn in table.clone(w.commits) :: { (any, string, any, any) -> () } do
		fn(store, key, row, server)
	end
end

function World.trace(w: any, text: string) w.scheduler:trace(text) end

function World.digest(w: any): number return w.scheduler:digest() end

--- Collects runtime reports (`Config.reporter`) in `world.reported` as `{ owner, event }`
--- until the returned function restores the default reporter.
function World.capture(w: any): () -> ()
	local reporter = Config.reporter
	assert(reporter ~= nil, "world:capture needs a reporter: Sim.configure{ reporter = ... }")
	reporter(function(event: any)
		table.insert(w.reported, { owner = w.scheduler.current, event = event })
		w:trace(`report {event.source} {event.code}`)
	end)
	return function() reporter(nil) end
end

function World.reports(w: any): { any } return w.reported end

function World.kick(w: any, server: any, player: any, message: string?)
	local entry = { server = server, player = player, userId = player.UserId, message = message, at = w.scheduler.now }
	table.insert(w.kicks, entry)
	table.insert(server.kicks, entry)
	w:trace(`kick {player.UserId} on {server.name}: {message}`)
	if w.instant or server.kicked[player] then return end
	server.kicked[player] = true
	local delay = if w.mode == "random" then w.scheduler:pick(KICK_DELAYS, "kick") else 0
	w.scheduler:after(delay, server, function()
		if table.find(server.players.list, player) then server:leave(player) end
	end)
end

--- The simulated remotes (named event and rpc channels) for `server` and its clients (sim/services/remotes.luau).
function World.remotes(w: any, server: any): any
	if server._net == nil then server._net = Remotes.new(w, server) end
	return server._net
end

local function makePeerInfo(w: any, peerId: string): PeerInfo
	local numId = tonumber(string.match(peerId, "%d+")) or 1
	for _, srv in w.servers do
		if srv.players ~= nil and srv.players.peers ~= nil then
			local existing = srv.players.peers[numId]
			if existing ~= nil then
				if existing.peerId == nil then existing.peerId = peerId end
				if existing.userId == nil then existing.userId = existing.UserId or numId end
				return existing
			end
		end
	end
	return {
		peerId = peerId,
		userId = numId,
		Name = peerId,
		UserId = numId,
	}
end

local function remoteDelay(w: any): (number, boolean)
	local s = w.scheduler
	local range = w.faults.remoteLatencyRange
	local delay = 0
	if type(range) == "table" and #range >= 2 then
		local lo = tonumber(range[1]) or 0
		local hi = tonumber(range[2]) or lo
		if hi < lo then hi = lo end
		if hi > 0 then
			if hi == lo then
				delay = lo
			else
				local steps = 10
				local idx = s:choose(steps + 1, "remote.latency") - 1
				delay = lo + (hi - lo) * (idx / steps)
			end
		end
	end
	local reorderRate = w.faults.remoteReorderRate or 0
	local reordered = reorderRate > 0 and s:chance(reorderRate, "remote.reorder")
	return delay, reordered
end

local function deliverBusPacket(w: any, pkt: any)
	local args = pkt.args
	if pkt.dir == "server" then
		local handlers = w._serverRemotes[pkt.remote]
		if handlers == nil or #handlers == 0 then return end
		local peerInfo = makePeerInfo(w, pkt.peerId)
		for _, handler in table.clone(handlers) :: { (PeerInfo, ...any) -> () } do
			local copied = util.copy(args)
			local ok, err = pcall(function() handler(peerInfo, table.unpack(copied, 1, copied.n)) end)
			if not ok then
				local errStr = Config.describeError(err)
				table.insert(w.remoteErrors, {
					peerId = pkt.peerId,
					remote = pkt.remote,
					err = errStr,
					time = w.scheduler.now,
				})
				w:trace(`remoteError {pkt.remote} from {pkt.peerId}: {errStr}`)
			end
		end
	else
		local byRemote = w._clientRemotes[pkt.peerId]
		local handlers = if byRemote ~= nil then byRemote[pkt.remote] else nil
		if handlers == nil or #handlers == 0 then return end
		for _, handler in table.clone(handlers) :: { (...any) -> () } do
			local copied = util.copy(args)
			local ok, err = pcall(function() handler(table.unpack(copied, 1, copied.n)) end)
			if not ok then
				local errStr = Config.describeError(err)
				table.insert(w.remoteErrors, {
					peerId = pkt.peerId,
					remote = pkt.remote,
					err = errStr,
					time = w.scheduler.now,
				})
				w:trace(`remoteError {pkt.remote} to {pkt.peerId}: {errStr}`)
			end
		end
	end
end

local function sortBusPackets(a: any, b: any): boolean
	if a.at ~= b.at then return a.at < b.at end
	if a.order ~= b.order then return a.order < b.order end
	return a.seq < b.seq
end

local function enqueueOrDeliverRemote(w: any, dir: "server" | "client", peerId: string, remoteName: string, args: any)
	local s = w.scheduler
	local dropRate = w.faults.remoteDropRate or 0
	if dropRate > 0 and s:chance(dropRate, "remote.drop") then
		w:trace(`remoteDropped {remoteName} ({peerId})`)
		return
	end
	local dupRate = w.faults.remoteDuplicateRate or 0
	local copies = if dupRate > 0 and s:chance(dupRate, "remote.duplicate") then 2 else 1
	local delay, reordered = remoteDelay(w)
	local lastPkt = w._remoteQueue[#w._remoteQueue]
	local overtaking = lastPkt ~= nil and lastPkt.holdReorder == true
	if delay <= 0 and not reordered then
		if overtaking then lastPkt.holdReorder = false end
		local pkt = {
			dir = dir,
			peerId = peerId,
			remote = remoteName,
			args = args,
		}
		for _ = 1, copies do
			deliverBusPacket(w, pkt)
		end
		return
	end
	for c = 1, copies do
		w._remoteSeq += 1
		local seq = w._remoteSeq
		local targetAt = s.now + delay
		local order = seq
		local holdReorder = false
		if c == 1 and overtaking then
			lastPkt.holdReorder = false
			order = lastPkt.seq
			lastPkt.order = seq + 0.5
			if lastPkt.at < targetAt then lastPkt.at = targetAt end
		elseif reordered then
			holdReorder = (c == copies)
			order = seq + 1000000
		end
		table.insert(w._remoteQueue, {
			at = targetAt,
			order = order + (c - 1) * 0.01,
			seq = seq,
			holdReorder = holdReorder,
			dir = dir,
			peerId = peerId,
			remote = remoteName,
			args = args,
		})
	end
end

--- Registers a server-side handler for `remoteName` on the world's simulated remote bus.
function World.onServerEvent(w: any, remoteName: string, handler: (player: PeerInfo, ...any) -> ()): () -> ()
	assert(type(remoteName) == "string", "world:onServerEvent: remoteName must be a string")
	assert(type(handler) == "function", "world:onServerEvent: handler must be a function")
	w._serverRemotes[remoteName] = w._serverRemotes[remoteName] or {}
	return addHook(w._serverRemotes[remoteName], handler)
end

--- Registers a client-side handler for `remoteName` on `peerId` on the world's simulated remote bus.
function World.onClientEvent(w: any, peerId: string, remoteName: string, handler: (...any) -> ()): () -> ()
	assert(type(peerId) == "string", "world:onClientEvent: peerId must be a string")
	assert(type(remoteName) == "string", "world:onClientEvent: remoteName must be a string")
	assert(type(handler) == "function", "world:onClientEvent: handler must be a function")
	w._clientRemotes[peerId] = w._clientRemotes[peerId] or {}
	w._clientRemotes[peerId][remoteName] = w._clientRemotes[peerId][remoteName] or {}
	return addHook(w._clientRemotes[peerId][remoteName], handler)
end

--- Fires `remoteName` from client `peerId` to the server with deterministic packet fault injection.
function World.fireServer(w: any, peerId: string, remoteName: string, ...: any)
	assert(type(peerId) == "string", "world:fireServer: peerId must be a string")
	assert(type(remoteName) == "string", "world:fireServer: remoteName must be a string")
	local args = util.copy(table.pack(...))
	w:trace(`fireServer {remoteName} from {peerId}`)
	enqueueOrDeliverRemote(w, "server", peerId, remoteName, args)
end

--- Fires `remoteName` from the server to client `peerId` with deterministic packet fault injection.
function World.fireClient(w: any, peerId: string, remoteName: string, ...: any)
	assert(type(peerId) == "string", "world:fireClient: peerId must be a string")
	assert(type(remoteName) == "string", "world:fireClient: remoteName must be a string")
	local args = util.copy(table.pack(...))
	w:trace(`fireClient {remoteName} to {peerId}`)
	enqueueOrDeliverRemote(w, "client", peerId, remoteName, args)
end

--- Fires `remoteName` from the server to all registered client peers on the world's remote bus.
function World.fireAllClients(w: any, remoteName: string, ...: any)
	assert(type(remoteName) == "string", "world:fireAllClients: remoteName must be a string")
	local args = util.copy(table.pack(...))
	w:trace(`fireAllClients {remoteName}`)
	local peers: { string } = {}
	for peerId, byRemote in w._clientRemotes do
		if byRemote[remoteName] ~= nil and #byRemote[remoteName] > 0 then table.insert(peers, peerId) end
	end
	table.sort(peers)
	for _, peerId in peers do
		enqueueOrDeliverRemote(w, "client", peerId, remoteName, args)
	end
end

function World._flushDueRemotes(w: any, flushAll: boolean?)
	local queue = w._remoteQueue
	if #queue == 0 then return end
	local limit = if flushAll then math.huge else w.scheduler.now + util.EPSILON
	local due: { any }, kept: { any } = {}, {}
	for _, pkt in queue do
		if pkt.at <= limit then
			table.insert(due, pkt)
		else
			table.insert(kept, pkt)
		end
	end
	if #due == 0 then return end
	w._remoteQueue = kept
	table.sort(due, sortBusPackets)
	for _, pkt in due do
		deliverBusPacket(w, pkt)
	end
end

--- Flushes all queued in-flight remote packets deterministically.
function World.flushRemotes(w: any)
	while #w._remoteQueue > 0 do
		w:_flushDueRemotes(true)
	end
	for _, srv in w.servers do
		if srv._net ~= nil then srv._net:flush() end
	end
end

--- Formats a concise causal timeline of the world's recent trace lines and any unhandled scheduler errors.
function World.summary(w: any, maxEntries: number?): string
	local s = w.scheduler
	local limit = maxEntries or 24
	local traced: { string } = s.traced or {}
	local lines = {
		string.format(
			"[world t=%.2fs frames=%d servers=%d errors=%d digest=0x%08x]",
			s.now,
			s.frames,
			#w.servers,
			#s.errors,
			s:digest()
		),
	}
	local activeFaults: { string } = {}
	for _, k in SWARM_KEYS do
		local rate = w.faults[k]
		if type(rate) == "number" and rate > 0 then table.insert(activeFaults, `{k}={string.format("%.2f", rate)}`) end
	end
	if #activeFaults > 0 then
		table.insert(
			lines,
			`  [faults profile={w.profile}{if w.swarm then " (swarm)" else ""}: {table.concat(activeFaults, " ")}]`
		)
	end
	for i = math.max(1, #traced - limit + 1), #traced do
		table.insert(lines, `  {traced[i]}`)
	end
	for _, remErr in w.remoteErrors do
		table.insert(
			lines,
			string.format("  [remoteError t=%.2fs %s (%s)] %s", remErr.time, remErr.remote, remErr.peerId, remErr.err)
		)
	end
	for _, err in s.errors do
		table.insert(lines, `  [error] {err.message}`)
	end
	return table.concat(lines, "\n")
end

--- Raises `{label}: unhandled scheduler error: ...` with its traceback when a scheduler thread errored.
function World.assertNoErrors(w: any, label: string)
	local first = w.scheduler.errors[1]
	if first ~= nil then error(`{label}: unhandled scheduler error: {first.message}\n{first.traceback}`, 0) end
end

--- Raises `{label}: unhandled remote error: ...` when a remote handler recorded an error in `world.remoteErrors`.
function World.assertNoRemoteErrors(w: any, label: string)
	local first: RemoteError? = w.remoteErrors[1]
	if first ~= nil then
		error(
			string.format(
				"%s: unhandled remote error on %s (%s at t=%.2fs): %s",
				label,
				first.remote,
				first.peerId,
				first.time,
				first.err
			),
			0
		)
	end
end

--- Heals partitions, releases held gates, drains pending MessagingService queues, and steps virtual time
--- so all live servers converge, then asserts no unhandled scheduler errors occurred (unless `allowErrors` is set).
--- When `optionsOrProject` is a projection function `(server) -> state`, steps `step` seconds (1) at a time until all
--- live servers project equal state, for at most `timeout` seconds (15), and raises if they do not (`soft`: returns
--- false instead); without one it runs `seconds` (10) and settles. `invariant(world)` runs last.
function World.converge(w: any, optionsOrProject: any?, maybeOptions: any?): boolean
	local project: ((server: any) -> any)? = if type(optionsOrProject) == "function" then optionsOrProject else nil
	local o: {
		seconds: number?,
		timeout: number?,
		step: number?,
		allowErrors: boolean?,
		soft: boolean?,
		invariant: ((world: any) -> ())?,
	} = if project
			~= nil
		then (maybeOptions or {})
		else (optionsOrProject or {})
	w:heal()
	for _, gate in table.clone(w.gates) :: { [string]: any } do
		gate:release()
	end
	table.clear(w.scripted)
	local savedFaults = w.faults
	w.faults = table.clone(PROFILES.none)
	local function flushNet()
		w.messaging:drain()
		w:flushRemotes()
	end
	local converged = true
	local timeout = o.timeout or 15
	local ok, err = pcall(function()
		w.messaging:drain()
		if project ~= nil then
			local proj = project
			local stepDt, elapsed = o.step or 1, 0
			local function allEqual(): boolean
				local ref: any, hasRef = nil, false
				for _, srv in w.servers do
					if srv.state == "up" then
						local cur = proj(srv)
						if not hasRef then
							ref, hasRef = cur, true
						elseif not util.equal(ref, cur, true) then
							return false
						end
					end
				end
				return true
			end
			local function flushStep()
				if not w.instant then w.scheduler:drain() end
				flushNet()
				if not w.instant then w.scheduler:drain() end
			end
			converged = false
			while elapsed < timeout do
				flushStep()
				if allEqual() and (w.pendingCloud or 0) == 0 and (elapsed > 0 or w.instant or w.scheduler:idle()) then
					converged = true
					break
				end
				w:run(stepDt)
				elapsed += stepDt
			end
			if not converged then
				flushStep()
				converged = allEqual() and (w.pendingCloud or 0) == 0
			end
		else
			w:run(o.seconds or 10)
			flushNet()
			w:step()
		end
	end)
	w.faults = savedFaults
	if not ok then error(err, 0) end
	if not o.allowErrors then w:assertNoErrors("world:converge") end
	if not converged then
		if o.soft == true then return false end
		error(`world:converge: projected server states did not converge within {timeout}s\n{w:summary()}`, 0)
	end
	if o.invariant ~= nil then o.invariant(w) end
	return true
end

-- Servers ----------------------------------------------------------------------------------------------

--- A new server. `slot` keeps a restarted server's place in the fleet; `restarts` counts its restarts.
function World.server(w: any, options: { [string]: any }?): any
	local o: { [string]: any } = options or {}
	assert(type(o) == "table", "world:server: options must be a table")
	for key in o do
		assert(SERVER_OPTIONS[key], `world:server: unknown option {tostring(key)}`)
	end
	local s = w.scheduler
	w.count += 1
	local n = w.count
	local slot = o.slot
	if slot == nil then
		w.slots += 1
		slot = w.slots
	end
	local restarts = o.restarts or 0
	local pinnedSkew = o.skew ~= nil
	local skew = if pinnedSkew then o.skew elseif w.mode == "random" then s:pick(SKEWS, "skew", SKEW_WEIGHTS) else 0
	local server: any = setmetatable({
		world = w,
		n = n,
		slot = slot,
		restarts = restarts,
		name = if restarts > 0 then `s{slot}.{restarts}` else `s{slot}`,
		jobId = o.jobId or string.format("%08x-%04x-4000-8000-%012x", n, slot % 65536, restarts),
		skew = skew,
		pinnedSkew = pinnedSkew,
		build = o.build,
		state = "up",
		studio = false,
		closers = {},
		inflight = {},
		kicks = {},
		kicked = setmetatable({}, { __mode = "k" }),
	}, Server)
	server.owner = server
	server.players = Players.new(w, server)
	server.run = RunService.new(w, server, false, function(): boolean return server.studio end)
	-- Runtime random draws are data (backoff jitter), not decisions: a per-server stream keeps them
	-- reproducible without growing the choice tree.
	local stream = s:stream(`random/{server.jobId}`)
	local hooks = if w.instant then w.coop.hooks else s:host(server)
	server.host = {
		clock = hooks.clock,
		wait = hooks.wait,
		spawn = hooks.spawn,
		defer = hooks.defer,
		resume = hooks.resume,
		unixTime = function(): number return w:unix() + server.skew end,
		random = function(): number return stream:float() end,
		bindClose = function(fn: () -> ()): () -> () return addHook(server.closers, { fn = fn }) end,
		jobId = server.jobId,
		placeId = w.placeId,
		Players = server.players,
		RunService = server.run,
		HttpService = Http.new({ prefix = n }),
		EncodingService = Encoding.new(),
		DataStoreService = if w.datastore ~= nil then w.datastore:facade(server) else nil,
		MemoryStoreService = w.memory:facade(w, server),
		MessagingService = w.messaging:facade(server),
	}
	if not w.instant and not w.coarse then
		server.stopFrame = s:onFrame(function(dt: number) RunService.step(server.run, dt, s.now) end, server, true)
	end
	if slot ~= nil and w.servers[slot] ~= nil and w.servers[slot].state ~= "up" then
		w.servers[slot] = server
	else
		table.insert(w.servers, server)
	end
	w:trace(`server {server.name} up {server.jobId} skew={skew}`)
	return server
end

local function makeEnv(target: any, server: any, isServer: boolean, options: Env.Options?): any
	if target._env ~= nil then return target._env end
	local merged: any = table.clone(options or {})
	merged.world, merged.server = server.world, server
	merged.client = if isServer then nil else target
	merged.isServer, merged.isClient = isServer, not isServer
	target._env = Env.new(merged)
	return target._env
end

local function bindPeerEnv(peer: any, fn: any): any
	if setfenv ~= nil and type(fn) == "function" then
		local setFnEnv: any = setfenv
		setFnEnv(fn, peer:env().globals)
	end
	return fn
end

--- Returns (and caches) a headless Roblox `Env` (`src/env/init.luau`) bound to this server's `host`.
function Server.env(server: any, options: Env.Options?): any return makeEnv(server, server, true, options) end

function Server.spawn(server: any, fn: (...any) -> ...any, ...: any): any
	return server.host.spawn(bindPeerEnv(server, fn), ...)
end

--- Joins a simulated client (`userId`) on this server's `Remotes` network and attaches `client:env()` and `client:leave()`.
function Server.client(server: any, userId: number, options: { skew: number? }?): any
	local net = server.world:remotes(server)
	local client = net:client(userId, options)
	function client.spawn(c: any, fn: (...any) -> ...any, ...: any): any return c.host.spawn(bindPeerEnv(c, fn), ...) end
	function client.env(c: any, envOptions: Env.Options?): any return makeEnv(c, server, false, envOptions) end
	function client.leave(c: any) net:leave(c) end
	return client
end

--- A player joins (PlayerAdded fires); returns it. `player:Kick(message)` is recorded in `world.kicks`
--- and `server.kicks`, and the player leaves 0-1 s later (not with instant waits).
function Server.join(server: any, userId: number): any return Players.join(server, userId) end

--- A player leaves (PlayerRemoving fires); a newer player object of the same user stays.
function Server.leave(server: any, player: any)
	local net: any = server._net
	if net ~= nil and net.clients ~= nil then
		for _, client in table.clone(net.clients) :: { any } do
			if client.player == player and not client.gone then net:leave(client) end
		end
	end
	if table.find(server.players.list, player) ~= nil then Players.leave(server, player) end
end

-- Ends a server: its threads, timers and Heartbeat stop, its subscriptions go and its players vanish.
local function stop(server: any, state: string)
	local w = server.world
	if server.state == "crashed" or server.state == "down" then return end
	if state == "crashed" and server.inflight ~= nil and #server.inflight > 0 then
		local pending: { { key: string, run: () -> () } } = table.clone(server.inflight)
		table.clear(server.inflight)
		for _, entry in pending do
			local delay = w:lateDelay()
			w:trace(`late in-flight {entry.key} detached from crashed {server.name}`)
			w:detach(delay, entry.run)
		end
	elseif server.inflight ~= nil then
		table.clear(server.inflight)
	end
	local stopFrame: (() -> ())? = server.stopFrame
	if stopFrame ~= nil then stopFrame() end
	if server._net ~= nil then server._net:stop() end
	w.scheduler:crash(server)
	server.state = state
	w.messaging:drop(server)
	table.clear(server.players.peers)
	table.clear(server.players.list)
	w:trace(`server {server.name} {state}`)
end

--- Shifts the server's clock skew by `delta` seconds (positive = fast, negative = slow/jump-back).
function Server.drift(server: any, delta: number)
	server.skew += delta
	server.world:trace(
		string.format(
			"clock drift %s %s%.2fs (skew=%.2fs)",
			server.name,
			if delta >= 0 then "+" else "",
			delta,
			server.skew
		)
	)
end

--- The server dies at once: no close hooks, no PlayerRemoving; in-flight replies are lost, commits stand.
function Server.crash(server: any) stop(server, "crashed") end

--- Shuts the server down as the engine does: players leave, the bound close hooks run (each on a thread
--- of this server), and once they return or `deadline` seconds (30) pass, the server stops.
function Server.shutdown(server: any, deadline: number?)
	if server.state ~= "up" then return end
	local w, s = server.world, server.world.scheduler
	server.state = "closing"
	w:trace(`server {server.name} shutdown`)
	local closers: { any } = table.clone(server.closers)
	for _, player in table.clone(server.players.list) do
		server:leave(player)
	end
	if w.instant then
		for _, closer in closers do
			closer.fn()
		end
		stop(server, "down")
		return
	end
	s:drain()
	if #closers == 0 then
		stop(server, "down")
		return
	end
	local finished = false
	local function finalize()
		if finished or rawget(server, "state") ~= "closing" then return end
		finished = true
		s:drain()
		stop(server, "down")
	end
	local running = #closers
	for _, closer in closers do
		s:spawn(server, function()
			local ok, err = pcall(closer.fn)
			running -= 1
			if running == 0 then s:defer(server, finalize) end
			if not ok then error(err, 0) end
		end)
	end
	if not finished and rawget(server, "state") == "closing" then
		s:after(deadline or CLOSE_SECONDS, server, finalize)
	end
end

--- A new incarnation of this server (a new owner, jobId and GUID prefix); a live one crashes first.
function Server.restart(server: any): any
	local w = server.world
	local current = w.servers[server.slot]
	if current ~= nil and current ~= server then
		if server.autoRestarted and current.state == "up" then
			server.autoRestarted = nil
			return current
		end
		local nextServer = current:restart()
		server.replacedBy = nextServer
		return nextServer
	end
	if server.state == "up" or server.state == "closing" then server:crash() end
	local nextServer = w:server({
		slot = server.slot,
		skew = if server.pinnedSkew then server.skew else nil,
		build = server.build,
		restarts = server.restarts + 1,
	})
	server.replacedBy = nextServer
	local buildFn: any = server.build
	if type(buildFn) == "function" then (buildFn :: (any) -> ())(nextServer) end
	return nextServer
end

-- Extension ----------------------------------------------------------------------------------------

--- A World class with `methods` added (a consumer's shims or helpers): its `new(options)` makes worlds
--- whose methods include them, and its other functions are World's.
function World.extend(methods: { [string]: any }): any
	local class: any = table.clone(World)
	class.__index = class
	for key, value in methods do
		class[key] = value
	end
	class.new = function(options: Options?): any return World.new(options, class) end
	return class
end

return table.freeze(World)
