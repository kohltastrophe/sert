--!strict
-- Deterministic multi-server and multi-client simulation fleet (`Sim.new`) backed by `src/engine/scheduler.luau`
-- and `src/sim/fabric.luau`.

local Env = require("../env")
local Fabric = require("./fabric")
local Rng = require("../core/rng")
local Scheduler = require("../engine/scheduler")
local Signal = require("../engine/signal")
local util = require("../core/util")

local CLOSE_SECONDS = 30

export type RemoteError = {
	peer: string,
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
	teleportRaceRate: number?,
	rollingShutdownRate: number?,
	receiptDuplicateRate: number?,
}

export type Faults = {
	before: number,
	after: number,
	late: number,
	retransform: number,
	stale: number,
	drift: number,
	crash: number,
	evict: number,
	subscribe: number,
	drop: number,
	duplicate: number,
	budget: number?,
	remoteDropRate: number,
	remoteReorderRate: number,
	remoteDuplicateRate: number,
	remoteLatencyRange: { number }?,
	teleportRaceRate: number,
	rollingShutdownRate: number,
	receiptDuplicateRate: number,
}

export type Options = {
	scheduler: Scheduler.Scheduler?,
	mode: ("manual" | "random")?,
	seed: number?,
	frame: number?,
	faults: (string | FaultConfig | { [string]: any })?,
	swarm: boolean?,
	autoRestart: boolean?,
	placeId: number?,
	datastoreBudget: number?,
	latency: { [string]: number }?,
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
		teleportRaceRate = 0,
		rollingShutdownRate = 0,
		receiptDuplicateRate = 0,
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
		teleportRaceRate = 0.05,
		rollingShutdownRate = 0,
		receiptDuplicateRate = 0.02,
	},
	heavy = {
		before = 0.02,
		after = 0.02,
		late = 0.01,
		retransform = 0.01,
		stale = 0.02,
		drift = 0.01,
		crash = 0,
		evict = 0.02,
		subscribe = 0.05,
		drop = 0.1,
		duplicate = 0.05,
		budget = 30,
		remoteDropRate = 0.02,
		remoteReorderRate = 0.02,
		remoteDuplicateRate = 0.01,
		teleportRaceRate = 0.15,
		rollingShutdownRate = 0.01,
		receiptDuplicateRate = 0.08,
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
		teleportRaceRate = 0.25,
		rollingShutdownRate = 0.02,
		receiptDuplicateRate = 0.15,
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
	"teleportRaceRate",
	"rollingShutdownRate",
	"receiptDuplicateRate",
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
	teleportRaceRate = { 0, 0.1, 0.25, 0.5 },
	rollingShutdownRate = { 0, 0.01, 0.04, 0.1 },
	receiptDuplicateRate = { 0, 0.05, 0.15, 0.35 },
}

local SWARM_WEIGHTS = { 55, 25, 14, 6 }

local VALID_WHENS: { [string]: boolean } = {
	before = true,
	after = true,
	late = true,
	retransform = true,
	stale = true,
	drift = true,
	crash = true,
	evict = true,
}

local LATENCY_DEFAULT = { levels = { 0.02, 0.05, 0.1, 0.25 }, weights = { 40, 30, 20, 10 } }
local LATENCY: { [string]: { levels: { number }, weights: { number } } } = {
	DataStore = { levels = { 0.05, 0.1, 0.2, 0.5, 1, 3 }, weights = { 30, 30, 20, 12, 6, 2 } },
	DataStoreService = { levels = { 0.05, 0.1, 0.2, 0.5, 1, 3 }, weights = { 30, 30, 20, 12, 6, 2 } },
	MemoryStore = { levels = { 0.02, 0.05, 0.1, 0.3 }, weights = { 40, 30, 20, 10 } },
	MemoryStoreService = { levels = { 0.02, 0.05, 0.1, 0.3 }, weights = { 40, 30, 20, 10 } },
	MessagingService = { levels = { 0.05, 0.1, 0.2, 0.5 }, weights = { 40, 30, 20, 10 } },
	HttpService = { levels = { 0.05, 0.15, 0.4, 1.0 }, weights = { 40, 30, 20, 10 } },
	TeleportService = { levels = { 0.05, 0.15, 0.35, 0.8 }, weights = { 40, 30, 20, 10 } },
	delivery = { levels = { 0.05, 0.1, 0.25, 0.5, 1, 5 }, weights = { 30, 30, 20, 10, 8, 2 } },
	remotes = { levels = { 0.03, 0.06, 0.1, 0.2, 0.5 }, weights = { 30, 30, 20, 15, 5 } },
}

local SKEWS, SKEW_WEIGHTS = { 0, 1, -1, 3, -3, 200 }, { 50, 15, 15, 8, 8, 4 }
local KICK_DELAYS = { 0, 0.25, 0.5, 1 }
local LATE_DELAYS = { 0.15, 0.4, 1.2, 3 }
local DRIFT_DELTAS = { -30, -5, -1, 1, 5, 30 }

local World = {}
World.__index = World

local Server = {}
Server.__index = Server

local Client = {}
Client.__index = Client

export type World = typeof(World) & {
	scheduler: Scheduler.Scheduler,
	rng: Rng.Rng,
	mode: "manual" | "random",
	seed: number,
	placeId: number,
	servers: { Server },
	kicks: { any },
	remoteErrors: { RemoteError },
	receipts: { any },
	actions: { any },
	profile: string,
	faults: Faults,
	swarm: boolean,
	autoRestart: boolean,
	coarse: boolean,
	backing: any,
	http: any,
	pendingCloud: number,
	pendingRemotes: number,
}

export type Server = typeof(Server) & {
	world: World,
	n: number,
	slot: number,
	restarts: number,
	name: string,
	jobId: string,
	placeId: number,
	privateServerId: string,
	skew: number,
	state: "up" | "closing" | "crashed" | "down",
	alive: boolean,
	clients: { Client },
	DataStoreService: any,
	MemoryStoreService: any,
	MessagingService: any,
	HttpService: any,
	EncodingService: any,
	TeleportService: any,
	MarketplaceService: any,
	Players: any,
	RunService: any,
	remotes: any,
	host: { [string]: any },
}

export type Client = typeof(Client) & {
	id: number,
	userId: number,
	name: string,
	server: Server,
	world: World,
	connected: boolean,
	skew: number,
	teleportData: any,
	player: { [string]: any },
	remotes: any,
	RunService: any,
	host: { [string]: any },
}

local function addHook(list: { any }, item: any): () -> ()
	table.insert(list, item)
	return function()
		local idx = table.find(list, item)
		if idx ~= nil then table.remove(list, idx) end
	end
end

local function makeWorldSignal(w: any, owner: any, spawnEach: boolean): any
	local s = w.scheduler
	return Signal.new({
		shouldPark = function(): boolean return s ~= nil and (s:running() or coroutine.running() == s.testThread) end,
		park = function(onPark: (co: thread) -> ()): ...any
			if s:running() then onPark(coroutine.running()) end
			return s:park()
		end,
		dispatch = if s ~= nil and owner ~= nil
			then if spawnEach
				then function(fn: (...any) -> (), ...: any) s:spawn(owner, fn, ...) end
				else function(fn: (...any) -> (), ...: any) s:defer(owner, fn, ...) end
			else nil,
		resume = if s ~= nil
			then function(wt: thread, ...: any)
				s:resume(wt, ...)
				if not s:running() then s:drain() end
			end
			else nil,
	})
end

local function newRunService(w: any, owner: any, isClient: boolean, isStudioFn: () -> boolean): any
	local heartbeat = makeWorldSignal(w, owner, true)
	local stepped = makeWorldSignal(w, owner, true)
	local preAnimation = makeWorldSignal(w, owner, true)
	local preSimulation = makeWorldSignal(w, owner, true)
	local postSimulation = makeWorldSignal(w, owner, true)
	local preRender = if isClient then makeWorldSignal(w, owner, true) else nil
	local renderStepped = if isClient then makeWorldSignal(w, owner, true) else nil

	local rs: any = {
		Heartbeat = heartbeat,
		Stepped = stepped,
		PreAnimation = preAnimation,
		PreSimulation = preSimulation,
		PostSimulation = postSimulation,
		PreRender = preRender,
		RenderStepped = renderStepped,
	}

	function rs.IsServer(_self: any): boolean return not isClient end
	function rs.IsClient(_self: any): boolean return isClient end
	function rs.IsStudio(_self: any): boolean return isStudioFn() end
	function rs.IsRunning(_self: any): boolean return true end
	function rs.IsRunMode(_self: any): boolean return isStudioFn() end

	function rs._step(dt: number, elapsed: number)
		if isClient and preRender ~= nil and renderStepped ~= nil then
			(preRender :: any):Fire(dt);
			(renderStepped :: any):Fire(dt)
		end
		preAnimation:Fire(dt)
		stepped:Fire(elapsed, dt)
		preSimulation:Fire(dt)
		postSimulation:Fire(dt)
		heartbeat:Fire(dt)
	end

	return rs
end

local function resolveFaults(
	s: Scheduler.Scheduler,
	mode: "manual" | "random",
	spec: (string | FaultConfig | { [string]: any })?,
	swarmOpt: boolean?
): (string, Faults, boolean)
	local profileName = "none"
	local overrides: { [string]: any }? = nil
	if type(spec) == "string" then
		profileName = spec
	elseif type(spec) == "table" then
		local specTbl: { [string]: any } = spec :: any
		profileName = if type(specTbl.profile) == "string" then specTbl.profile else "none"
		overrides = specTbl
	end
	local base = PROFILES[profileName]
	if base == nil then error(`Sim.new: unknown fault profile '{profileName}'`, util.outside()) end

	local faults: any = table.clone(base)
	local swarm = if swarmOpt ~= nil then swarmOpt else (profileName == "vopr" and mode == "random")
	if swarm then
		for _, k in SWARM_KEYS do
			local levels = SWARM_LEVELS[k]
			if levels ~= nil then faults[k] = s:pick(levels, `swarm.{k}`, SWARM_WEIGHTS) end
		end
	end
	if overrides ~= nil then
		for k, v in overrides do
			if k ~= "profile" then faults[k] = v end
		end
	end
	return profileName, faults :: Faults, swarm
end

--- Creates a new deterministic simulation `World`.
function World.new(options: Options?): World
	local o: Options = options or {}
	local mode: "manual" | "random" = o.mode or "manual"
	local seed = o.seed or 1
	local s = o.scheduler or Scheduler.new({
		seed = seed,
		random = mode == "random",
		frame = o.frame,
	})
	local profile, faults, swarm = resolveFaults(s, mode, o.faults, o.swarm)
	local autoRestart = if o.autoRestart ~= nil then o.autoRestart else (profile == "vopr")

	local w: any = setmetatable({
		scheduler = s,
		rng = Rng.new(s.seed),
		mode = mode,
		seed = s.seed,
		placeId = o.placeId or 1,
		datastoreBudget = o.datastoreBudget or faults.budget,
		fixed = if o.latency ~= nil then table.clone(o.latency) else {},
		coarse = o.coarse == true,
		profile = profile,
		faults = faults,
		swarm = swarm,
		autoRestart = autoRestart,
		servers = {},
		count = 0,
		slots = 0,
		nextClientId = 1,
		nextReceiptSeq = 1,
		pendingCloud = 0,
		pendingRemotes = 0,
		kicks = {},
		remoteErrors = {},
		receipts = {},
		actions = {},
		gates = {},
		scripted = {},
		partitions = {} :: { { server: any, untilAt: number } },
		serverInitializers = {} :: { (Server) -> () },
		_reservedPlaces = {},
		_nextReserveSeq = 0,
	}, World)

	w.http = Fabric.newHttpService(w)
	w.backing = Fabric.newBacking(w)

	if w.coarse then
		s:onFrame(function(dt: number)
			for _, srv in table.clone(w.servers) :: { any } do
				if srv.state == "up" then srv:_stepFrame(dt) end
			end
		end, nil, true)
	end

	return w
end

--- Current virtual clock in seconds since simulation start.
function World.now(w: any): number return w.scheduler.now end

--- Current simulated Unix timestamp in seconds.
function World.unix(w: any): number return util.UNIX_EPOCH + w.scheduler.now end

--- Sleeps the current scheduler coroutine for `seconds` of virtual time.
function World.sleep(w: any, seconds: number): number return w.scheduler:wait(seconds) end

--- Schedules `fn` as a detached background effect (surviving server crashes/shutdowns) after `delay` seconds.
function World.detach(w: any, delay: number, fn: () -> ())
	w.pendingCloud = (w.pendingCloud or 0) + 1
	w.scheduler:after(math.max(0, delay), nil, function()
		local ok, err = pcall(fn :: () -> ...any)
		w.pendingCloud = math.max(0, (w.pendingCloud or 0) - 1)
		if not ok then w:trace(`detached error: {tostring(err)}`) end
	end)
end

function World.lateDelay(w: any): number
	return if w.mode == "random" then w.scheduler:pick(LATE_DELAYS, "late.delay") else LATE_DELAYS[1]
end

local LATENCY_ALIASES: { [string]: string } = {
	datastore = "DataStore",
	datastoreservice = "DataStore",
	DataStoreService = "DataStore",
	memorystore = "MemoryStore",
	memorystoreservice = "MemoryStore",
	MemoryStoreService = "MemoryStore",
	messaging = "MessagingService",
	messagingservice = "MessagingService",
	http = "HttpService",
	httpservice = "HttpService",
}

local function normalizeLatencyKind(kind: string): string
	return LATENCY_ALIASES[kind] or LATENCY_ALIASES[string.lower(kind)] or kind
end

--- Sets a fixed network/service latency in seconds for `kind`.
function World.setLatency(w: any, kind: string, seconds: number?) w.fixed[normalizeLatencyKind(kind)] = seconds end

--- Returns simulated latency in seconds for `kind` (`0` in manual mode unless pinned via `setLatency` or `options.latency`).
function World.latency(w: any, kind: string): number
	local norm = normalizeLatencyKind(kind)
	local fixed = w.fixed[norm] or w.fixed[kind]
	if fixed ~= nil then return fixed end
	if w.mode ~= "random" then return 0 end
	local spec = LATENCY[norm] or LATENCY[kind] or LATENCY_DEFAULT
	if w.coarse then
		return w.scheduler:pick({ spec.levels[1], spec.levels[math.max(1, #spec.levels - 1)] }, `{norm}.latency`)
	end
	return w.scheduler:pick(spec.levels, `{norm}.latency`, spec.weights)
end

function World.shouldFault(
	w: any,
	server: any,
	service: string,
	method: string,
	key: string,
	when: string
): (boolean, string?)
	local queue = w.scripted[key]
	local head = if queue ~= nil then queue[1] else nil
	if head ~= nil and head.when == when then
		table.remove(queue, 1)
		w:trace(`fault {when} {key} on {if server then server.name else "?"}: {head.message}`)
		return true, head.message
	end

	-- Also check service-alias key (`DataStore.SetAsync` vs `DataStoreService.SetAsync`).
	local altKey = if service == "DataStore"
		then `DataStoreService.{method}`
		elseif service == "MemoryStore" then `MemoryStoreService.{method}`
		else nil
	if altKey ~= nil then
		local altQueue = w.scripted[altKey]
		local altHead = if altQueue ~= nil then altQueue[1] else nil
		if altHead ~= nil and altHead.when == when then
			table.remove(altQueue, 1)
			w:trace(`fault {when} {altKey} on {if server then server.name else "?"}: {altHead.message}`)
			return true, altHead.message
		end
	end

	if server ~= nil and when == "before" and (w.faults.drift or 0) > 0 then
		if w.scheduler:chance(w.faults.drift, `{service}.drift`) then
			local delta = w.scheduler:pick(DRIFT_DELTAS, "clock.drift")
			server:drift(delta)
		end
	end

	local field = if method == "SubscribeAsync" then (if when == "before" then "subscribe" else nil) else when
	local probability = if field ~= nil then (w.faults[field] or 0) else 0
	if probability > 0 and w.scheduler:chance(probability, `{service}.{when}`) then
		w:trace(`fault {when} {key} on {if server then server.name else "?"}`)
		return true, `{method}: connection lost (injected {when})`
	end
	return false, nil
end

local SERVICE_ALIASES: { [string]: string } = {
	DataStoreService = "DataStore",
	MemoryStoreService = "MemoryStore",
}

--- Scripts the next call to `service.method` to trigger fault `when`.
function World.fail(w: any, service: string, method: string, when: string, message: string?)
	if not VALID_WHENS[when] then error(`world:fail: invalid fault phase '{when}'`, util.outside()) end
	local canonical = SERVICE_ALIASES[service] or service
	local key = `{canonical}.{method}`
	if w.scripted[key] == nil then w.scripted[key] = {} end
	table.insert(w.scripted[key], { when = when, message = message or `{method}: connection lost` })
end

--- Holds calls to `service.method` at a barrier until `gate:release(n?)` is called.
function World.hold(w: any, service: string, method: string): any
	local canonical = SERVICE_ALIASES[service] or service
	local key = `{canonical}.{method}`
	local gate: any = { held = true, waiting = {} :: { thread }, calls = 0 }
	function gate.enter(g: any)
		if not g.held then return end
		g.calls += 1
		local thread = coroutine.running()
		table.insert(g.waiting, thread)
		while table.find(g.waiting, thread) ~= nil do
			w.scheduler:park()
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
			if coroutine.status(thread) ~= "suspended" then continue end
			remaining -= 1
			w.scheduler:resume(thread)
		end
	end
	w.gates[key] = gate
	return gate
end

--- Proxy helper running `body(...)` through gates, simulated latency, and `before`/`after` faults.
function World.call(w: any, server: any, service: string, method: string, body: (...any) -> ...any, ...: any): ...any
	local key = `{service}.{method}`
	local gate = w.gates[key]
	if gate ~= nil then gate:enter() end
	local delay = w:latency(service)
	if delay > 0 then w:sleep(delay) end
	if server ~= nil and not server.alive then error(`{method}: server '{server.name}' has stopped`, 0) end
	local trigBefore, msgBefore = w:shouldFault(server, service, method, key, "before")
	if trigBefore then error(msgBefore or `{method}: connection lost`, 0) end
	local packed = table.pack(body(...))
	local replyDelay = w:latency(service)
	if replyDelay > 0 then w:sleep(replyDelay) end
	local trigAfter, msgAfter = w:shouldFault(server, service, method, key, "after")
	if trigAfter then error(msgAfter or `{method}: connection lost after commit`, 0) end
	return table.unpack(packed, 1, packed.n)
end

-- Network partitions (MessagingService) ------------------------------------------------------------------------------

function World.partition(w: any, server: any, seconds: number)
	local untilAt = w:now() + math.max(0, seconds)
	for _, p in w.partitions do
		if p.server == server then
			p.untilAt = math.max(p.untilAt, untilAt)
			return
		end
	end
	table.insert(w.partitions, { server = server, untilAt = untilAt })
end

function World.isolate(w: any, server: any) w:partition(server, 1e9) end

function World.isolated(w: any, server: any): boolean
	local now = w:now()
	for _, p in w.partitions do
		if p.server == server and p.untilAt > now then return true end
	end
	return false
end

function World.isPartitioned(w: any, origin: any, target: any): boolean
	if origin == target then return false end
	return w:isolated(origin) or w:isolated(target)
end

function World.heal(w: any) table.clear(w.partitions) end

-- Stepping & Convergence ---------------------------------------------------------------------------------------------

function World.onFrame(w: any, fn: (dt: number) -> ()): () -> () return w.scheduler:onFrame(fn, nil) end

function World.step(w: any, dt: number?): number return w.scheduler:frame(dt) end

function World.run(w: any, seconds: number)
	local s = w.scheduler
	local stopAt = s.now + seconds
	while s.now + util.EPSILON < stopAt do
		w:step(math.min(1 / 60, stopAt - s.now))
	end
end

function World.advance(w: any, seconds: number) w:run(seconds) end

function World.runUntil(w: any, target: number | () -> boolean, limit: number?): boolean
	return w.scheduler:runUntil(target, limit)
end

function World.isQuiescent(w: any): boolean
	return w.scheduler:idle() == true
		and (w.pendingCloud or 0) == 0
		and (w.pendingRemotes or 0) == 0
		and #w.backing.messaging.queue == 0
end

--- Heals partitions, releases gates, drains pending queues, and advances virtual time only until quiescent
--- (and until `project(server)` converges across live servers when supplied). Returns immediately if already idle.
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

	local function allEqual(): boolean
		if project == nil then return true end
		local ref: any, hasRef = nil, false
		for _, srv in w.servers do
			if srv.state == "up" then
				local cur = project(srv)
				if not hasRef then
					ref, hasRef = cur, true
				elseif not util.equal(ref, cur, true) then
					return false
				end
			end
		end
		return true
	end

	local function drainQueues()
		w.scheduler:drain()
		w.backing.messaging.drain()
		w.scheduler:drain()
	end

	local converged = false
	local timeout = o.timeout or o.seconds or 15
	local stepDt = o.step or (1 / 60)

	local ok, err = pcall(function(): nil
		drainQueues()
		if o.seconds == nil and w:isQuiescent() and allEqual() then
			converged = true
			return nil
		end

		local elapsed = 0
		local targetDuration = o.seconds
		while elapsed + util.EPSILON < timeout do
			drainQueues()
			if w:isQuiescent() and allEqual() then
				if targetDuration == nil or elapsed + util.EPSILON >= targetDuration then
					converged = true
					return nil
				end
			end
			local dt = math.min(stepDt, timeout - elapsed)
			w:step(dt)
			elapsed += dt
		end
		drainQueues()
		converged = w:isQuiescent() and allEqual()
		if project == nil and o.seconds ~= nil then converged = allEqual() end
		return nil
	end)

	w.faults = savedFaults
	if not ok then error(err, 0) end
	if not o.allowErrors then w:assertNoErrors("world:converge") end
	if not converged then
		if o.soft == true then return false end
		error(`world:converge: did not converge within {timeout}s\n{w:summary()}`, 0)
	end
	if o.invariant ~= nil then o.invariant(w) end
	return true
end

-- Tracing, Diagnostics & Action Log ----------------------------------------------------------------------------------

function World.trace(w: any, text: string) w.scheduler:trace(text) end

function World.digest(w: any): number return w.scheduler:digest() end

function World.action(w: any, commandName: string, arg: any?, stateProjection: any?, result: any?): any
	local entry = {
		step = #w.actions + 1,
		t = w.scheduler.now,
		command = commandName,
		arg = util.copy(arg),
		result = util.copy(result),
		state = if stateProjection ~= nil then util.copy(stateProjection) else nil,
	}
	table.insert(w.actions, entry)
	w:trace(`cmd #{entry.step} {commandName}`)
	return entry
end

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
			string.format("  [remoteError t=%.2fs %s (%s)] %s", remErr.time, remErr.remote, remErr.peer, remErr.err)
		)
	end
	for _, err in s.errors do
		table.insert(lines, `  [error] {err.message}`)
	end
	return table.concat(lines, "\n")
end

function World.assertNoErrors(w: any, label: string)
	local first = w.scheduler.errors[1]
	if first ~= nil then error(`{label}: unhandled scheduler error: {first.message}\n{first.traceback}`, 0) end
end

function World.assertNoRemoteErrors(w: any, label: string)
	local first: RemoteError? = w.remoteErrors[1]
	if first ~= nil then
		error(
			string.format(
				"%s: unhandled remote error on %s (%s at t=%.2fs): %s",
				label,
				first.remote,
				first.peer,
				first.time,
				first.err
			),
			0
		)
	end
end

function World.remotes(w: any, server: any): any return Fabric.attachRemotes(w, server) end

--- Registers an initializer called automatically whenever a new `Server` boots in this `World`
--- (including destination servers created by `TeleportAsync`, `restart`, or rolling shutdowns).
function World.onServerStart(w: any, fn: (server: Server) -> ()): () -> () return addHook(w.serverInitializers, fn) end

-- VOPR Hazards (Crash, Rolling Shutdown, Teleport Handoff Race, Receipt Duplicate Delivery) --------------------------

--- Injects a between-step spontaneous crash (and restart if `autoRestart` is true) according to `faults.crash`.
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
	end
	victim:crash()
	return victim
end

--- VOPR Hazard 2: Injects a spontaneous rolling `Server:shutdown()` (30s `BindToClose` window + player migration).
function World.maybeRollingShutdown(w: any): any?
	local prob = w.faults.rollingShutdownRate or 0
	if prob <= 0 then return nil end
	local live: { any } = {}
	for _, srv in w.servers do
		if srv.state == "up" then table.insert(live, srv) end
	end
	if #live == 0 or not w.scheduler:chance(prob, "step.rollingShutdown") then return nil end
	local victim = if w.mode == "random" then w.scheduler:pick(live, "step.rollingShutdown.server") else live[1]

	-- Ensure a replacement server is up to receive migrating players.
	local dest: any = nil
	for _, cand in live do
		if cand ~= victim then
			dest = cand
			break
		end
	end
	if dest == nil then dest = w:server({ placeId = victim.placeId, build = victim.build }) end

	w:trace(`rollingShutdown {victim.name} -> migrating {#victim.clients} client(s) to {dest.name}`)
	local migrating: { any } = table.clone(victim.clients)
	local raceRate = w.faults.teleportRaceRate or 0
	for _, cli in migrating do
		if cli.connected then
			local mode: "ordered" | "during_removing" = if raceRate > 0
					and w.scheduler:chance(raceRate, "teleport.race")
				then "during_removing"
				else "ordered"
			w:handoffClient(cli, victim, dest, cli.teleportData, mode)
		end
	end
	victim:shutdown(CLOSE_SECONDS)
	return dest
end

--- Transfers `client` from `sourceServer` to `destServer` with configurable `PlayerAdded` vs `PlayerRemoving` overlap.
function World.handoffClient(
	w: any,
	client: any,
	sourceServer: any,
	destServer: any,
	teleportData: any?,
	mode: ("ordered" | "before_removing" | "during_removing")?
)
	local handoffMode = mode or "ordered"
	local userId = client.userId
	local oldPlayer = client.player
	local joinInfo = {
		SourceGameId = w.placeId,
		SourcePlaceId = sourceServer.placeId,
		TeleportData = util.copy(teleportData),
	}

	local function detachFromSource()
		if client.server == sourceServer then
			client.connected = false
			client.gone = true
		end
		local idx = table.find(sourceServer.clients, client)
		if idx ~= nil then table.remove(sourceServer.clients, idx) end
		if sourceServer._net ~= nil then sourceServer._net.abortDisconnected() end
		local srvEnv = rawget(sourceServer, "_env")
		if srvEnv ~= nil and srvEnv.Players ~= nil then
			for _, p in srvEnv.Players:GetChildren() do
				if p.ClassName == "Player" and p.UserId == userId then
					p:Destroy()
					break
				end
			end
		end
		if sourceServer.alive then sourceServer.Players.PlayerRemoving:Fire(oldPlayer) end
	end

	local function attachToDest()
		if not destServer.alive then return end
		destServer:client(userId, {
			teleportData = teleportData,
			joinData = joinInfo,
		})
	end

	if handoffMode == "before_removing" then
		-- Destination `PlayerAdded` runs BEFORE source `PlayerRemoving` begins!
		attachToDest()
		w.scheduler:after(0.05, nil, detachFromSource)
	elseif handoffMode == "during_removing" then
		-- Source `PlayerRemoving` starts first, and destination `PlayerAdded` fires 10ms later while save is in flight!
		w.scheduler:spawn(sourceServer, detachFromSource)
		w.scheduler:after(0.01, nil, attachToDest)
	else
		detachFromSource()
		local transit = w:latency("TeleportService")
		if transit > 0 then
			w.scheduler:after(transit, nil, attachToDest)
		else
			attachToDest()
		end
	end
end

--- VOPR Hazard 3: Initiates a Developer Product purchase (`MarketplaceService.ProcessReceipt`) with idempotent
--- `PurchaseId` tracking and crash/timeout/ACK-loss duplicate delivery.
function World.purchaseProduct(w: any, clientOrUserId: any, productId: number, currencySpent: number?): string
	local userId: number
	local hostServer: any = nil
	if type(clientOrUserId) == "number" then
		userId = clientOrUserId
	elseif type(clientOrUserId) == "table" then
		userId = clientOrUserId.userId or clientOrUserId.UserId
		hostServer = clientOrUserId.server
	else
		error("world:purchaseProduct: expected Client, Player, or userId number", util.outside())
	end

	if hostServer == nil then
		for _, srv in w.servers do
			if srv.alive then
				for _, cli in srv.clients do
					if cli.connected and cli.userId == userId then
						hostServer = srv
						break
					end
				end
			end
			if hostServer ~= nil then break end
		end
	end

	local seq = w.nextReceiptSeq
	w.nextReceiptSeq += 1
	local purchaseId = string.format("purchase_%d_%d_%d", w.seed, seq, productId)
	local record = {
		purchaseId = purchaseId,
		playerId = userId,
		productId = productId,
		placeId = if hostServer ~= nil then hostServer.placeId else w.placeId,
		currencySpent = currencySpent or 100,
		granted = false,
		inFlight = false,
		duplicatedOnce = false,
		attempts = 0,
	}
	table.insert(w.receipts, record)
	if hostServer ~= nil and hostServer.alive then Fabric.deliverReceipt(w, record, hostServer) end
	return purchaseId
end

function World.kick(w: any, server: any, player: any, message: string?)
	local entry = { server = server, player = player, userId = player.UserId, message = message, at = w:now() }
	table.insert(w.kicks, entry)
	table.insert(server.kicks, entry)
	w:trace(`kick {player.UserId} on {server.name}: {message or ""}`)
	local delay = if w.mode == "random" then w.scheduler:pick(KICK_DELAYS, "kick") else 0
	w.scheduler:after(delay, server, function() server:leave(player) end)
end

-- Servers & Clients --------------------------------------------------------------------------------------------------

function World.server(w: any, options: { [string]: any }?): Server
	local o: { [string]: any } = options or {}
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
	local placeId = o.placeId or w.placeId
	local privateServerId = o.privateServerId or ""

	local server: any = setmetatable({
		world = w,
		n = n,
		slot = slot,
		restarts = restarts,
		name = if restarts > 0 then `s{slot}.{restarts}` else `s{slot}`,
		jobId = o.jobId or string.format("%08x-%04x-4000-8000-%012x", n, slot % 65536, restarts),
		placeId = placeId,
		privateServerId = privateServerId,
		skew = skew,
		pinnedSkew = pinnedSkew,
		build = o.build,
		state = "up" :: string,
		alive = true,
		studio = false,
		closers = {} :: { { fn: () -> () } },
		inflightList = {} :: { any },
		_nextInflightId = 1,
		clients = {} :: { Client },
		kicks = {},
	}, Server)

	server.RunService = newRunService(w, server, false, function() return server.studio end)

	local stream = s:stream(`random/{server.jobId}`)
	local hooks = s:host(server)
	server.host = {
		clock = hooks.clock,
		wait = hooks.wait,
		spawn = hooks.spawn,
		defer = hooks.defer,
		deferSignal = hooks.deferSignal,
		resume = hooks.resume,
		unixTime = function(): number return w:unix() + server.skew end,
		random = function(): number return stream:float() end,
		bindClose = function(fn: () -> ()): () -> () return addHook(server.closers, { fn = fn }) end,
		jobId = server.jobId,
		placeId = placeId,
		privateServerId = privateServerId,
		RunService = server.RunService,
	}

	Fabric.attachAll(w, server)

	if not w.coarse then server.stopFrame = s:onFrame(function(dt: number) server:_stepFrame(dt) end, server, true) end

	if slot ~= nil and w.servers[slot] ~= nil and w.servers[slot].state ~= "up" then
		w.servers[slot] = server
	else
		table.insert(w.servers, server)
	end

	w:trace(`server {server.name} up {server.jobId} skew={skew}`)

	local buildFn: any = server.build
	if type(buildFn) == "function" then (buildFn :: (any) -> ())(server) end
	local inits: { (Server) -> () } = table.clone(w.serverInitializers)
	for _, initFn in inits do
		initFn(server)
	end

	return server
end

function Server._stepFrame(server: any, dt: number)
	if server.state ~= "up" then return end
	local now = server.world.scheduler.now
	server.RunService._step(dt, now)
	local clientSnap: { any } = table.clone(server.clients)
	for _, cli in clientSnap do
		if cli.connected and cli.server == server then cli.RunService._step(dt, now) end
	end
end

function Server.now(server: any): number return server.world:unix() + server.skew end

function Server.BindToClose(server: any, fn: () -> ()): () -> () return server.host.bindClose(fn) end

function Server.spawn(server: any, fn: (...any) -> ...any, ...: any): thread return server.host.spawn(fn, ...) end

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

function Server.env(server: any, options: Env.Options?): any
	if server._env ~= nil then return server._env end
	local merged: any = table.clone(options or {})
	merged.world = server.world
	merged.server = server
	merged.isServer = true
	merged.isClient = false
	local created = Env.new(merged)
	server._env = created
	Fabric.bindServerEnv(server.world, server, created)
	return created
end

local function makeMockPlayer(server: any, userId: number, name: string, joinData: any): any
	local player: any = {
		UserId = userId,
		Name = name,
		DisplayName = name,
		AccountAge = 365,
		Parent = server.Players,
	}
	function player.Kick(p: any, msg: string?) server.world:kick(server, p, msg) end
	function player.GetJoinData(_p: any): any return util.copy(joinData) end
	return player
end

function Server.client(
	server: any,
	userId: number,
	options: { skew: number?, name: string?, teleportData: any?, joinData: any? }?
): Client
	if not server.alive then error(`server:client: server '{server.name}' has stopped`, util.outside()) end
	local o: { skew: number?, name: string?, teleportData: any?, joinData: any? } = options
		or {} :: { skew: number?, name: string?, teleportData: any?, joinData: any? }
	local w = server.world
	local s = w.scheduler
	local id = w.nextClientId
	w.nextClientId += 1
	local name = o.name or `Player_{userId}`
	local teleportData = util.copy(o.teleportData)
	local joinData = o.joinData or {
		SourceGameId = 0,
		SourcePlaceId = 0,
		TeleportData = teleportData,
	}

	local skew = if o.skew ~= nil
		then o.skew
		elseif w.mode == "random" then s:pick(SKEWS, "client.skew", SKEW_WEIGHTS)
		else 0

	local player = makeMockPlayer(server, userId, name, joinData)
	local client: any = setmetatable({
		id = id,
		userId = userId,
		name = name,
		server = server,
		world = w,
		connected = true,
		gone = false,
		skew = skew,
		teleportData = teleportData,
		joinData = joinData,
		player = player,
	}, Client)

	client.RunService = newRunService(w, client, true, function() return server.studio end)
	local stream = s:stream(`client/{id}/{userId}`)
	local hooks = s:host(client)
	local net = Fabric.attachRemotes(w, server)
	client.remotes = net:forClient(client)

	client.host = {
		clock = hooks.clock,
		wait = hooks.wait,
		spawn = hooks.spawn,
		defer = hooks.defer,
		deferSignal = hooks.deferSignal,
		resume = hooks.resume,
		unixTime = function(): number return w:unix() + client.skew end,
		random = function(): number return stream:float() end,
		RunService = client.RunService,
		remotes = client.remotes,
	}

	table.insert(server.clients, client)

	-- Sync into `server._env.Players` if `server:env()` was already initialized.
	local srvEnv: any = rawget(server, "_env")
	if srvEnv ~= nil then
		local decorate: ((any, any) -> any)? = rawget(srvEnv, "_decoratePlayer") :: any
		if decorate ~= nil then
			local envPlayer: any = decorate(srvEnv, player)
			local rawMethods: { [string]: any } = rawget(envPlayer, "_methods") or {}
			local patched: { [string]: any } = table.clone(rawMethods)
			patched.GetJoinData = function(_self: any): any return util.copy(joinData) end
			rawset(envPlayer, "_methods", patched)
			client.player = envPlayer
		end
	end

	server.Players.PlayerAdded:Fire(client.player)
	Fabric.flushPlayerReceipts(w, server, userId)

	return client
end

function Server.join(server: any, userId: number): any
	local cli = server:client(userId)
	return cli.player
end

function Server.leave(server: any, playerOrClient: any)
	for i = #server.clients, 1, -1 do
		local cli = server.clients[i]
		if cli == playerOrClient or cli.player == playerOrClient or cli.userId == playerOrClient then
			cli:disconnect()
			return
		end
	end
end

function Client.now(client: any): number return client.world:unix() + client.skew end

function Client.spawn(client: any, fn: (...any) -> ...any, ...: any): thread return client.host.spawn(fn, ...) end

function Client.env(client: any, options: Env.Options?): any
	if client._env ~= nil then return client._env end
	local merged: any = table.clone(options or {})
	merged.world = client.world
	merged.server = client.server
	merged.client = client
	merged.isServer = false
	merged.isClient = true
	merged.localPlayer = { UserId = client.userId, Name = client.name }
	local created = Env.new(merged)
	client._env = created
	Fabric.bindClientEnv(client.world, client, created)
	return created
end

function Client.disconnect(client: any)
	if not client.connected then return end
	client.connected = false
	client.gone = true
	local server = client.server
	local idx = table.find(server.clients, client)
	if idx ~= nil then table.remove(server.clients, idx) end
	if server._net ~= nil then server._net.abortDisconnected() end
	client.world.scheduler:crash(client)

	local srvEnv: any = rawget(server, "_env")
	if srvEnv ~= nil and srvEnv.Players ~= nil then
		for _, p in srvEnv.Players:GetChildren() do
			if p.ClassName == "Player" and p.UserId == client.userId then
				p:Destroy()
				break
			end
		end
	end

	if server.alive then server.Players.PlayerRemoving:Fire(client.player) end
end

Client.leave = Client.disconnect

local function stopServer(server: any, nextState: "crashed" | "down")
	local w = server.world
	if server.state == "crashed" or server.state == "down" then return end
	server.alive = false
	server.state = nextState

	-- Detach ALL still-in-flight mutating cloud writes (both on crash AND when `BindToClose` hits its 30s deadline!)
	-- so writes already sent over the wire can still commit late on the backing store.
	if #server.inflightList > 0 then
		local pending: { any } = table.clone(server.inflightList)
		table.clear(server.inflightList)
		for _, entry in pending do
			if entry.active then
				entry.active = false
				w.pendingCloud = math.max(0, (w.pendingCloud or 0) - 1)
				local onCancel: (() -> ())? = entry.onCancel
				if onCancel ~= nil then onCancel() end
				if entry.mutates and entry.run ~= nil then
					local delay = w:lateDelay()
					w:trace(`late in-flight {entry.service}.{entry.method} detached from {nextState} {server.name}`)
					w:detach(delay, function() pcall(entry.run, false) end)
				end
			end
		end
	end

	local stopFrame: (() -> ())? = server.stopFrame
	if stopFrame ~= nil then stopFrame() end

	-- Mark remaining connected clients disconnected and wake any parked RPC callers.
	local remainingClients: { any } = table.clone(server.clients)
	table.clear(server.clients)
	for _, cli in remainingClients do
		cli.connected = false
		cli.gone = true
		w.scheduler:crash(cli)
	end
	if server._net ~= nil then server._net.abortDisconnected() end

	-- Unsubscribe dead server from MessagingService.
	for _, sub in w.backing.messaging.subscriptions do
		if sub.server == server then sub.disconnected = true end
	end

	w.scheduler:crash(server)
	w:trace(`server {server.name} {nextState}`)
end

--- Immediately kills `server` without firing `PlayerRemoving` or `BindToClose`; in-flight mutations detach.
function Server.crash(server: any) stopServer(server, "crashed") end

--- Gracefully shuts `server` down: disconnects players (`PlayerRemoving`), runs `BindToClose` callbacks concurrently,
--- and hard-stops at `deadline` (default 30s), detaching any cloud writes still in flight at the deadline.
function Server.shutdown(server: any, deadline: number?)
	local curState: string = server.state
	if curState ~= "up" then return end
	local w = server.world
	local s = w.scheduler
	server.state = "closing"
	w:trace(`server {server.name} shutdown`)

	local currentClients: { any } = table.clone(server.clients)
	for _, cli in currentClients do
		cli:disconnect()
	end
	s:drain()

	local closers: { { fn: () -> () } } = table.clone(server.closers)
	local srvEnv: any = rawget(server, "_env")
	if srvEnv ~= nil then
		local envClosers: any = rawget(srvEnv, "_closers")
		if type(envClosers) == "table" then
			for _, fn in envClosers do
				table.insert(closers, { fn = fn })
			end
		end
	end

	if #closers == 0 then
		stopServer(server, "down")
		return
	end

	local finished = false
	local function finalize()
		local st: string = server.state
		if finished or st ~= "closing" then return end
		finished = true
		s:drain()
		stopServer(server, "down")
	end

	local running = #closers
	for _, closer in closers do
		s:spawn(server, function()
			local ok, err = pcall(closer.fn :: () -> ...any)
			running -= 1
			if running == 0 then s:defer(server, finalize) end
			if not ok then error(err, 0) end
		end)
	end

	local postSpawnState: string = server.state
	if not finished and postSpawnState == "closing" then s:after(deadline or CLOSE_SECONDS, nil, finalize) end
end

--- Crashes `server` (if still running) and boots a fresh incarnation in the same fleet slot.
function Server.restart(server: any): Server
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
		placeId = server.placeId,
		skew = if server.pinnedSkew then server.skew else nil,
		build = server.build,
		restarts = server.restarts + 1,
	})
	server.replacedBy = nextServer
	return nextServer
end

return table.freeze(World)
