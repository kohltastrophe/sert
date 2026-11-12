--!strict
-- Multi-peer VOPR cloud and remote fault fabric (`DataStoreService`, `MemoryStoreService`, `MessagingService`,
-- `HttpService`, `TeleportService`, `MarketplaceService`, `Players`, and real `RemoteEvent`/`RemoteFunction` routing).

local DataStore = require("../engine/datastore")
local Datatypes = require("../engine/datatypes")
local EncodingService = require("../engine/encoding_service")
local MemoryStore = require("../engine/memorystore")
local Signal = require("../engine/signal")
local format = require("../core/format")
local serialize = require("../engine/serialize")
local util = require("../core/util")

local copy = DataStore.copy

local Fabric = {}

local HISTORY_DEPTH = 4
local UNRELIABLE_MAX_BYTES = 900
local RECEIPT_DEADLINE = 30

type QueueWaiter = {
	id: number,
	active: boolean,
	wake: () -> (),
}

type PendingCaller = {
	id: number,
	active: boolean,
	thread: thread,
}

type Subscription = {
	id: number,
	topic: string,
	server: any,
	callback: (any) -> (),
	disconnected: boolean,
}

local function checkAlive(server: any, op: string)
	if not server.alive then error(`{op}: server '{server.name}' has stopped`, 0) end
end

local function fault(w: any, server: any, service: string, method: string, key: string, when: string)
	local triggered, msg = w:shouldFault(server, service, method, key, when)
	if triggered then error(msg or `{method}: connection lost (injected {when})`, 0) end
end

local function packValues(...: any): { [number]: any, n: number } return table.pack(...) end

local function unpackValues(packed: { [number]: any, n: number }): ...any return table.unpack(packed, 1, packed.n) end

local function makeWorldSignal(w: any, owner: any?, syncFire: boolean?): any
	local s = w.scheduler
	return Signal.new({
		shouldPark = function(): boolean return s ~= nil and (s:running() or coroutine.running() == s.testThread) end,
		park = function(onPark: (co: thread) -> ()): ...any
			if s:running() then onPark(coroutine.running()) end
			return s:park()
		end,
		dispatch = if not syncFire
				and s ~= nil
				and owner ~= nil
			then function(fn: (...any) -> (), ...: any) s:defer(owner, fn, ...) end
			else nil,
		resume = if s ~= nil
			then function(wt: thread, ...: any)
				s:resume(wt, ...)
				if not s:running() then s:drain() end
			end
			else nil,
	})
end

-- Runs `fn(localAck)` on `server` with latency, `before`/`after`/`late` fault injection, and crash cancellation.
local function serverCall(
	w: any,
	server: any,
	service: string,
	method: string,
	mutates: boolean,
	fn: (localAck: boolean) -> ...any
): ...any
	checkAlive(server, method)
	local key = `{service}.{method}`
	local delay = w:latency(service)
	local late = mutates and (w:shouldFault(server, service, method, key, "late")) or false
	local lateMsg = if late then `{method}: request timed out (simulated late write)` else nil

	if not mutates then
		if delay > 0 then
			w:sleep(delay)
			checkAlive(server, method)
		end
		fault(w, server, service, method, key, "before")
		local results = packValues(fn(true))
		fault(w, server, service, method, key, "after")
		return unpackValues(results)
	end

	-- Register mutating call in `server.inflight` (monotonic array + lookup) so crash/shutdown deadline can detach it.
	local caller = coroutine.running()
	local settled = false
	local results: { [number]: any, n: number }? = nil
	local runErr: any = nil

	local entry: any = nil
	local function removeInflight()
		if entry == nil or not entry.active then return end
		entry.active = false
		w.pendingCloud = math.max(0, (w.pendingCloud or 0) - 1)
		local list = server.inflightList
		for i = #list, 1, -1 do
			if list[i] == entry then
				table.remove(list, i)
				break
			end
		end
	end

	entry = {
		id = server._nextInflightId,
		active = true,
		mutates = true,
		service = service,
		method = method,
		remainingDelay = math.max(0.05, delay),
		run = function(localAck: boolean) return fn(localAck) end,
		onCancel = function()
			if not settled and caller ~= nil and coroutine.status(caller) == "suspended" then
				settled = true
				w.scheduler:resume(caller, false, `{method}: server '{server.name}' stopped during request`)
			end
		end,
	}
	server._nextInflightId += 1
	w.pendingCloud = (w.pendingCloud or 0) + 1
	table.insert(server.inflightList, entry)

	if delay > 0 then
		local timer = w.scheduler:after(delay, nil, function()
			if not settled and caller ~= nil and coroutine.status(caller) == "suspended" then
				w.scheduler:resume(caller, true)
			end
		end)
		local ok, stopErr = coroutine.yield()
		w.scheduler:cancel(timer)
		if not ok then
			removeInflight()
			error(stopErr, 0)
		end
	end

	if not server.alive then
		removeInflight()
		error(`{method}: server '{server.name}' has stopped`, 0)
	end

	local okBefore, beforeErr = pcall(fault :: (...any) -> ...any, w, server, service, method, key, "before")
	if not okBefore then
		settled = true
		removeInflight()
		error(beforeErr, 0)
	end

	if late then
		settled = true
		removeInflight()
		local lateDelay = math.max(0.05, if delay > 0 then delay * 2 else 0.25)
		w:detach(lateDelay, function() pcall(fn, false) end)
		error(lateMsg or `{method}: request timed out (simulated late write)`, 0)
	end

	settled = true
	removeInflight()
	local okRun, packedOrErr = pcall(function() return packValues(fn(true)) end)
	if not okRun then
		runErr = packedOrErr
		error(runErr, 0)
	end
	results = packedOrErr

	-- `after` fault: backing mutation already committed, but caller loses ACK (and local cache is invalidated).
	local okAfter, afterErr = pcall(fault :: (...any) -> ...any, w, server, service, method, key, "after")
	if not okAfter then error(afterErr, 0) end

	return unpackValues(results :: { [number]: any, n: number })
end

-- Backing cloud stores -----------------------------------------------------------------------------------------------

function Fabric.newBacking(w: any): any
	local backing: any = {
		history = {},
		queueWaiters = {} :: { [string]: { QueueWaiter } },
		nextWaiterId = 1,
	}

	backing.datastore = DataStore.new({
		clock = function() return w:unix() end,
		budget = w.datastoreBudget,
	})

	backing.memorystore = MemoryStore.new(w.scheduler)

	local bus = {
		nextSubId = 1,
		nextMsgId = 1,
		subscriptions = {} :: { Subscription },
		queue = {} :: { any },
		deliver = function(_msg: any) end,
		drain = function() end,
	}

	function bus.deliver(msg: any)
		if msg.delivered then return end
		msg.delivered = true
		for i = #bus.queue, 1, -1 do
			if bus.queue[i] == msg then
				table.remove(bus.queue, i)
				break
			end
		end

		local snapshot: { Subscription } = table.clone(bus.subscriptions)
		for _, sub in snapshot do
			if not sub.disconnected and sub.server.alive and sub.topic == msg.topic then
				if not w:isPartitioned(msg.origin, sub.server) then
					local payload = { Data = copy(msg.data), Sent = msg.sent }
					sub.server:spawn(function()
						if not sub.disconnected and sub.server.alive then sub.callback(payload) end
					end)
				end
			end
		end
	end

	function bus.drain()
		while #bus.queue > 0 do
			local nextMsg = table.remove(bus.queue, 1)
			if nextMsg ~= nil then bus.deliver(nextMsg) end
		end
	end

	backing.messaging = bus

	function backing.notifyQueue(queueName: string)
		local waiters: { QueueWaiter }? = backing.queueWaiters[queueName]
		if waiters == nil or #waiters == 0 then return end
		local snapshot: { QueueWaiter } = table.clone(waiters)
		for _, waiter in snapshot do
			if waiter.active then waiter.wake() end
		end
	end

	return backing
end

-- HttpService --------------------------------------------------------------------------------------------------------

local function urlEncode(str: string): string
	return (string.gsub(str, "([^%w%-_%.~])", function(ch: string) return string.format("%%%02X", string.byte(ch)) end))
end

function Fabric.newHttpService(w: any): any
	local seq = 0
	local handlers: { { match: any, fn: (any) -> any } } = {}
	local requests: { any } = {}

	local http: any = {
		HttpEnabled = true,
		_requests = requests,
	}

	function http.GenerateGUID(_self: any, wrapInCurlyBraces: boolean?): string
		seq += 1
		local a = w.rng:int(0, 0xFFFFFFFF)
		local b = w.rng:int(0, 0xFFFFFFFF)
		local c = bit32.bor(bit32.band(w.rng:int(0, 0xFFFFFFFF), 0x0FFF), 0x4000)
		local d = bit32.bor(bit32.band(w.rng:int(0, 0xFFFFFFFF), 0x3FFF), 0x8000)
		local guid = string.format(
			"%08x-%04x-%04x-%04x-%08x%04x",
			a,
			bit32.rshift(b, 16),
			c,
			d,
			bit32.band(b, 0xFFFF),
			seq % 0x10000
		)
		return if wrapInCurlyBraces == false then guid else `\{{guid}\}`
	end

	function http.JSONEncode(_self: any, value: any): string return format.json(value) end

	function http.JSONDecode(_self: any, text: string): any return format.jsonDecode(text) end

	function http.UrlEncode(_self: any, input: string): string return urlEncode(tostring(input)) end

	function http.mock(_self: any, matcher: any, responder: (any) -> any)
		table.insert(handlers, { match = matcher, fn = responder })
	end

	function http.dispatch(_self: any, req: any): any
		table.insert(requests, util.copy(req))
		local url = tostring(req.Url or "")
		for i = #handlers, 1, -1 do
			local h = handlers[i]
			local matched = if type(h.match) == "string"
				then string.find(url, h.match, 1, true) ~= nil
				elseif type(h.match) == "function" then (h.match :: (any) -> boolean)(req)
				else true
			if matched then
				local resp = h.fn(util.copy(req))
				if type(resp) == "string" then
					return { Success = true, StatusCode = 200, StatusMessage = "OK", Headers = {}, Body = resp }
				end
				local status = resp.StatusCode or 200
				return {
					Success = if resp.Success ~= nil then resp.Success else (status >= 200 and status < 300),
					StatusCode = status,
					StatusMessage = resp.StatusMessage or (if status == 200 then "OK" else "Error"),
					Headers = util.copy(resp.Headers or {}),
					Body = tostring(resp.Body or ""),
				}
			end
		end
		return { Success = false, StatusCode = 404, StatusMessage = "Not Found", Headers = {}, Body = "" }
	end

	function http.RequestAsync(self: any, options: any): any return self:dispatch(options) end

	function http.GetAsync(self: any, url: string, _nocache: boolean?, headers: any?): string
		local res = self:RequestAsync({ Url = url, Method = "GET", Headers = headers })
		if not res.Success then error(`HttpService:GetAsync failed ({res.StatusCode} {res.StatusMessage})`, 0) end
		return res.Body
	end

	function http.PostAsync(
		self: any,
		url: string,
		data: string,
		_contentType: any?,
		_compress: boolean?,
		headers: any?
	): string
		local res = self:RequestAsync({ Url = url, Method = "POST", Body = data, Headers = headers })
		if not res.Success then error(`HttpService:PostAsync failed ({res.StatusCode} {res.StatusMessage})`, 0) end
		return res.Body
	end

	return http
end

function Fabric.attachHttp(w: any, server: any)
	local shared = w.http
	local svc: any = setmetatable({}, { __index = shared })

	function svc.RequestAsync(_self: any, options: any): any
		return serverCall(
			w,
			server,
			"HttpService",
			"RequestAsync",
			true,
			function(_localAck: boolean) return shared:dispatch(options) end
		)
	end

	function svc.GetAsync(self: any, url: string, _nocache: boolean?, headers: any?): string
		local res = self:RequestAsync({ Url = url, Method = "GET", Headers = headers })
		if not res.Success then error(`HttpService:GetAsync failed ({res.StatusCode} {res.StatusMessage})`, 0) end
		return res.Body
	end

	function svc.PostAsync(self: any, url: string, data: string, _ct: any?, _comp: boolean?, headers: any?): string
		local res = self:RequestAsync({ Url = url, Method = "POST", Body = data, Headers = headers })
		if not res.Success then error(`HttpService:PostAsync failed ({res.StatusCode} {res.StatusMessage})`, 0) end
		return res.Body
	end

	server.HttpService = svc
	server.host.HttpService = svc
end

-- DataStoreService ---------------------------------------------------------------------------------------------------

local CACHE_TTL = 4

local function wrapStore(w: any, server: any, raw: any, ordered: boolean, budget: any): any
	local cache: { [string]: { value: any, info: any, expires: number } } = {}
	local store: any = {}

	local function chargeBudget(method: string)
		local group = if ordered then DataStore.REQUEST_TYPES.ordered else DataStore.REQUEST_TYPES.standard
		local reqTypes = group[method]
		if reqTypes ~= nil then
			local exhausted = budget:charge(reqTypes)
			if exhausted ~= nil then error(`DataStore request was throttled ({exhausted} budget exhausted)`, 0) end
			if (w.faults.budget or 0) > 0 and w.scheduler:chance(w.faults.budget, "DataStore.budget") then
				error(`DataStore request was throttled (simulated budget fault on {method})`, 0)
			end
		end
	end

	function store.GetAsync(_self: any, key: string, options: any?): (any, any)
		local useCache = true
		if type(options) == "table" and options.UseCache == false then useCache = false end
		return serverCall(w, server, "DataStore", "GetAsync", false, function(_localAck: boolean)
			local now = server:now()
			if useCache then
				local hit = cache[key]
				if hit ~= nil and hit.expires > now then return copy(hit.value), copy(hit.info) end
			end
			chargeBudget("GetAsync")
			local val, info = raw:GetAsync(key, options)
			if useCache then
				cache[key] = { value = copy(val), info = copy(info), expires = server:now() + CACHE_TTL }
			end
			return copy(val), copy(info)
		end)
	end

	function store.SetAsync(_self: any, key: string, value: any, userIds: any?, options: any?): any
		local snapVal = copy(value)
		local snapUsers = copy(userIds)
		return serverCall(w, server, "DataStore", "SetAsync", true, function(localAck: boolean)
			chargeBudget("SetAsync")
			local version = raw:SetAsync(key, snapVal, snapUsers, options)
			-- Never populate the caller's 4s read cache on `late` or detached writes where the server got no ACK.
			if localAck and server.alive then
				local _, info = raw:GetAsync(key, { UseCache = false })
				cache[key] = { value = copy(snapVal), info = copy(info), expires = server:now() + CACHE_TTL }
			end
			return version
		end)
	end

	function store.IncrementAsync(_self: any, key: string, delta: number?, userIds: any?, options: any?): (any, any)
		local snapUsers = copy(userIds)
		return serverCall(w, server, "DataStore", "IncrementAsync", true, function(localAck: boolean)
			chargeBudget("IncrementAsync")
			local nextVal, info = raw:IncrementAsync(key, delta, snapUsers, options)
			if localAck and server.alive then
				cache[key] = { value = copy(nextVal), info = copy(info), expires = server:now() + CACHE_TTL }
			end
			return copy(nextVal), copy(info)
		end)
	end

	function store.RemoveAsync(_self: any, key: string): (any, any)
		return serverCall(w, server, "DataStore", "RemoveAsync", true, function(localAck: boolean)
			chargeBudget("RemoveAsync")
			local prev, info = raw:RemoveAsync(key)
			if localAck and server.alive then
				cache[key] = { value = nil, info = nil, expires = server:now() + CACHE_TTL }
			end
			return copy(prev), copy(info)
		end)
	end

	function store.UpdateAsync(_self: any, key: string, transform: (any, any) -> (any, any?, any?)): (any, any)
		checkAlive(server, "UpdateAsync")
		return serverCall(w, server, "DataStore", "UpdateAsync", true, function(localAck: boolean)
			chargeBudget("UpdateAsync")
			local retransform = (w.faults.retransform or 0) > 0
				and w.scheduler:chance(w.faults.retransform, "DataStore.retransform")
			local ranOnce = false
			local val, info = raw:UpdateAsync(key, function(current: any, keyInfo: any)
				if retransform and not ranOnce then
					ranOnce = true
					transform(copy(current), copy(keyInfo))
				end
				return transform(copy(current), copy(keyInfo))
			end)
			if localAck and server.alive then
				cache[key] = { value = copy(val), info = copy(info), expires = server:now() + CACHE_TTL }
			end
			return copy(val), copy(info)
		end)
	end

	if ordered then
		function store.GetSortedAsync(
			_self: any,
			ascending: boolean,
			pageSize: number,
			minValue: number?,
			maxValue: number?
		): any
			return serverCall(w, server, "DataStore", "GetSortedAsync", false, function(_localAck: boolean)
				chargeBudget("GetSortedAsync")
				return raw:GetSortedAsync(ascending, pageSize, minValue, maxValue)
			end)
		end
	else
		function store.ListKeysAsync(
			_self: any,
			prefix: string?,
			pageSize: number?,
			cursor: string?,
			excludeDeleted: boolean?
		): any
			return serverCall(w, server, "DataStore", "ListKeysAsync", false, function(_localAck: boolean)
				chargeBudget("ListKeysAsync")
				return raw:ListKeysAsync(prefix, pageSize, cursor, excludeDeleted)
			end)
		end
		function store.ListVersionsAsync(
			_self: any,
			key: string,
			sortDirection: any?,
			minDate: number?,
			maxDate: number?,
			pageSize: number?
		): any
			return serverCall(w, server, "DataStore", "ListVersionsAsync", false, function(_localAck: boolean)
				chargeBudget("ListVersionsAsync")
				return raw:ListVersionsAsync(key, sortDirection, minDate, maxDate, pageSize)
			end)
		end
		function store.GetVersionAsync(_self: any, key: string, version: string): (any, any)
			return serverCall(w, server, "DataStore", "GetVersionAsync", false, function(_localAck: boolean)
				chargeBudget("GetVersionAsync")
				return raw:GetVersionAsync(key, version)
			end)
		end
		function store.RemoveVersionAsync(_self: any, key: string, version: string)
			serverCall(w, server, "DataStore", "RemoveVersionAsync", true, function(_localAck: boolean)
				chargeBudget("RemoveVersionAsync")
				raw:RemoveVersionAsync(key, version)
			end)
		end
	end

	return store
end

function Fabric.attachDataStore(w: any, server: any)
	local backing = w.backing.datastore
	local stores: { [string]: any } = {}
	local budget = DataStore.budget(function() return server:now() end, w.datastoreBudget)

	local svc: any = { _budget = budget }

	function svc.GetDataStore(_self: any, name: string, scope: string?, options: any?): any
		local sc = scope or "global"
		local id = `std:{name}:{sc}`
		if stores[id] == nil then
			stores[id] = wrapStore(w, server, backing:GetDataStore(name, sc, options), false, budget)
		end
		return stores[id]
	end

	function svc.GetGlobalDataStore(self: any): any return self:GetDataStore("_global", "global") end

	function svc.GetOrderedDataStore(_self: any, name: string, scope: string?): any
		local sc = scope or "global"
		local id = `ord:{name}:{sc}`
		if stores[id] == nil then
			stores[id] = wrapStore(w, server, backing:GetOrderedDataStore(name, sc), true, budget)
		end
		return stores[id]
	end

	function svc.GetRequestBudgetForRequestType(_self: any, requestType: any): number
		return budget:remaining(requestType) or DataStore.UNMODELLED
	end

	function svc.ListDataStoresAsync(_self: any, prefix: string?, pageSize: number?, cursor: string?): any
		return serverCall(
			w,
			server,
			"DataStore",
			"ListDataStoresAsync",
			false,
			function(_localAck: boolean) return backing:ListDataStoresAsync(prefix, pageSize, cursor) end
		)
	end

	server.DataStoreService = svc
	server.host.DataStoreService = svc
end

-- MemoryStoreService -------------------------------------------------------------------------------------------------

local function cloneSnapshotEntries(entries: { any }): { any }
	local out = table.create(#entries)
	for i, e in entries do
		out[i] = { key = e.key, value = copy(e.value), sortKey = e.sortKey }
	end
	return out
end

local function pushRing(ring: { any }, item: any)
	table.insert(ring, item)
	while #ring > HISTORY_DEPTH do
		table.remove(ring, 1)
	end
end

function Fabric.attachMemoryStore(w: any, server: any)
	local backing = w.backing
	local rawSvc = backing.memorystore
	local history = backing.history

	local function recordMapHistory(mapId: string, rawMap: any, key: string, value: any, sortKey: any)
		local bucket = history[mapId]
		if bucket == nil then
			bucket = { keys = {}, _all = {} }
			history[mapId] = bucket
		end
		local keyRing = bucket.keys[key]
		if keyRing == nil then
			keyRing = {}
			bucket.keys[key] = keyRing
		end
		pushRing(keyRing, { value = copy(value), sortKey = sortKey })
		pushRing(bucket._all, cloneSnapshotEntries(rawMap:entries()))
	end

	local function wrapMap(mapId: string, rawMap: any, sorted: boolean): any
		local map: any = {}

		local function maybeEvict()
			if (w.faults.evict or 0) > 0 and w.scheduler:chance(w.faults.evict, "MemoryStore.evict") then
				rawMap:evict()
			end
		end

		function map.GetAsync(_self: any, key: string): ...any
			return serverCall(w, server, "MemoryStore", "GetAsync", false, function(_localAck: boolean)
				maybeEvict()
				local doStale = w:shouldFault(server, "MemoryStore", "GetAsync", "MemoryStore.GetAsync", "stale")
				if doStale then
					local bucket = history[mapId]
					local ring = if bucket ~= nil then bucket.keys[key] else nil
					if ring ~= nil and #ring > 1 then
						local historical = table.move(ring, 1, #ring - 1, 1, table.create(#ring - 1))
						local h = if w.mode == "random"
							then w.scheduler:pick(historical, "MemoryStore.staleEntry")
							else historical[#historical]
						if sorted then return copy(h.value), copy(h.sortKey) end
						return copy(h.value)
					end
				end
				if sorted then
					local val, sk = rawMap:GetAsync(key)
					return copy(val), copy(sk)
				end
				local val = rawMap:GetAsync(key)
				return copy(val)
			end)
		end

		function map.SetAsync(_self: any, key: string, value: any, expiry: number, sortKey: any?): boolean
			local snapVal = copy(value)
			local snapSk = copy(sortKey)
			return serverCall(w, server, "MemoryStore", "SetAsync", true, function(_localAck: boolean)
				local ok = rawMap:SetAsync(key, snapVal, expiry, if sorted then snapSk else nil)
				recordMapHistory(mapId, rawMap, key, snapVal, if sorted then snapSk else nil)
				return ok
			end)
		end

		function map.RemoveAsync(_self: any, key: string)
			serverCall(w, server, "MemoryStore", "RemoveAsync", true, function(_localAck: boolean)
				rawMap:RemoveAsync(key)
				recordMapHistory(mapId, rawMap, key, nil, nil)
			end)
		end

		function map.UpdateAsync(_self: any, key: string, transform: (any, any?) -> (any, any?), expiry: number): ...any
			return serverCall(w, server, "MemoryStore", "UpdateAsync", true, function(_localAck: boolean)
				local retransform = (w.faults.retransform or 0) > 0
					and w.scheduler:chance(w.faults.retransform, "MemoryStore.retransform")
				local ranOnce = false
				local val, sk = rawMap:UpdateAsync(key, function(curVal: any, curSk: any)
					if retransform and not ranOnce then
						ranOnce = true
						if sorted then
							transform(copy(curVal), copy(curSk))
						else
							transform(copy(curVal))
						end
					end
					if sorted then return transform(copy(curVal), copy(curSk)) end
					local nextVal = transform(copy(curVal))
					return nextVal, nil
				end, expiry)
				if val ~= nil then recordMapHistory(mapId, rawMap, key, val, sk) end
				if sorted then return copy(val), copy(sk) end
				return copy(val)
			end)
		end

		function map.GetSizeAsync(_self: any): number
			return serverCall(
				w,
				server,
				"MemoryStore",
				"GetSizeAsync",
				false,
				function(_localAck: boolean) return rawMap:GetSizeAsync() end
			)
		end

		if sorted then
			function map.GetRangeAsync(_self: any, direction: any, count: number, lower: any?, upper: any?): { any }
				return serverCall(w, server, "MemoryStore", "GetRangeAsync", false, function(_localAck: boolean)
					maybeEvict()
					local doStale =
						w:shouldFault(server, "MemoryStore", "GetRangeAsync", "MemoryStore.GetRangeAsync", "stale")
					if doStale then
						local bucket = history[mapId]
						local allRing = if bucket ~= nil then bucket._all else nil
						if allRing ~= nil and #allRing > 1 then
							local historical = table.move(allRing, 1, #allRing - 1, 1, table.create(#allRing - 1))
							local snap = if w.mode == "random"
								then w.scheduler:pick(historical, "MemoryStore.staleRange")
								else historical[#historical]
							local desc = direction == "Descending"
								or string.find(tostring(direction), "Descending", 1, true) ~= nil
							local out = {}
							for i = 1, #snap do
								local entry = snap[if desc then #snap - i + 1 else i]
								table.insert(out, {
									key = entry.key,
									value = copy(entry.value),
									sortKey = copy(entry.sortKey),
								})
								if #out >= count then break end
							end
							return out
						end
					end
					return cloneSnapshotEntries(rawMap:GetRangeAsync(direction, count, lower, upper))
				end)
			end
		else
			function map.ListItemsAsync(_self: any, count: number): any
				return serverCall(
					w,
					server,
					"MemoryStore",
					"ListItemsAsync",
					false,
					function(_localAck: boolean) return rawMap:ListItemsAsync(count) end
				)
			end
		end

		return map
	end

	local function wrapQueue(queueName: string, invisibilityTimeout: number?): any
		local invisibility = if invisibilityTimeout ~= nil then invisibilityTimeout else 30
		local rawQueue = rawSvc:GetQueue(queueName, invisibility)
		local q: any = {}

		local function scheduleNextVisibilityWake()
			local now = w:now()
			local earliest: number? = nil
			for _, entry in rawQueue.data do
				if entry.expiry > now and entry.visible > now and entry.expiry > entry.visible then
					if earliest == nil or entry.visible < earliest then earliest = entry.visible end
				end
			end
			if earliest ~= nil then
				w.scheduler:after(math.max(0, earliest - now), nil, function() backing.notifyQueue(queueName) end)
			end
		end

		function q.AddAsync(_self: any, value: any, expiry: number, priority: number?)
			local snapVal = copy(value)
			serverCall(w, server, "MemoryStore", "AddAsync", true, function(_localAck: boolean)
				rawQueue:AddAsync(snapVal, expiry, priority)
				backing.notifyQueue(queueName)
			end)
		end

		function q.RemoveAsync(_self: any, id: string)
			serverCall(
				w,
				server,
				"MemoryStore",
				"RemoveAsync",
				true,
				function(_localAck: boolean) rawQueue:RemoveAsync(id) end
			)
		end

		-- Event-driven long-polling `ReadAsync` (zero 60Hz spin) with mutating lease acquisition so `after`/`late`
		-- faults leave items leased until `invisibilityTimeout` expires and redelivers them.
		function q.ReadAsync(
			_self: any,
			count: number,
			allOrNothing: boolean?,
			waitTimeout: number?
		): ({ any }, string?)
			checkAlive(server, "ReadAsync")
			local maxWait = if waitTimeout == nil then 30 elseif waitTimeout < 0 then 3600 else waitTimeout
			local deadline = w:now() + maxWait

			while true do
				checkAlive(server, "ReadAsync")
				rawQueue:prune()
				local visibleCount = 0
				for _, entry in rawQueue.data do
					if entry.expiry > w:now() and entry.visible <= w:now() then
						visibleCount += 1
					end
				end
				local ready = visibleCount > 0 and (not allOrNothing or visibleCount >= count)
				if ready or w:now() >= deadline then
					return serverCall(w, server, "MemoryStore", "ReadAsync", true, function(_localAck: boolean)
						local items, receiptId = rawQueue:ReadAsync(count, allOrNothing == true, 0)
						if receiptId ~= nil then scheduleNextVisibilityWake() end
						return copy(items), receiptId
					end)
				end

				-- Park until an item is added, an invisibility lease expires, the deadline elapses, or the server stops.
				scheduleNextVisibilityWake()
				local caller = coroutine.running()
				local list = backing.queueWaiters[queueName]
				if list == nil then
					list = {}
					backing.queueWaiters[queueName] = list
				end
				local waiter: QueueWaiter = {
					id = backing.nextWaiterId,
					active = true,
					wake = function() end,
				}
				backing.nextWaiterId += 1

				local timeoutTimer: thread? = nil
				local function removeWaiter()
					if not waiter.active then return end
					waiter.active = false
					if timeoutTimer ~= nil then w.scheduler:cancel(timeoutTimer) end
					for i = #list, 1, -1 do
						if list[i] == waiter then
							table.remove(list, i)
							break
						end
					end
				end

				waiter.wake = function()
					if not waiter.active then return end
					removeWaiter()
					if caller ~= nil and coroutine.status(caller) == "suspended" then
						w.scheduler:resume(caller, true)
					end
				end

				local cancelEntry = {
					id = server._nextInflightId,
					active = true,
					mutates = false,
					onCancel = function()
						if not waiter.active then return end
						removeWaiter()
						if caller ~= nil and coroutine.status(caller) == "suspended" then
							w.scheduler:resume(caller, false, `ReadAsync: server '{server.name}' has stopped`)
						end
					end,
				}
				server._nextInflightId += 1
				table.insert(server.inflightList, cancelEntry)

				table.insert(list, waiter)
				timeoutTimer = w.scheduler:after(math.max(0, deadline - w:now()), nil, function() waiter.wake() end)

				local ok, err = coroutine.yield()
				cancelEntry.active = false
				for i = #server.inflightList, 1, -1 do
					if server.inflightList[i] == cancelEntry then
						table.remove(server.inflightList, i)
						break
					end
				end
				removeWaiter()
				if not ok then error(err, 0) end
			end
		end

		function q.GetSizeAsync(_self: any): number
			return serverCall(w, server, "MemoryStore", "GetSizeAsync", false, function(_localAck: boolean)
				rawQueue:prune()
				return #rawQueue.data
			end)
		end

		return q
	end

	local svc: any = {}

	function svc.GetSortedMap(_self: any, name: string): any
		return wrapMap(`sorted:{name}`, rawSvc:GetSortedMap(name), true)
	end

	function svc.GetHashMap(_self: any, name: string): any return wrapMap(`hash:{name}`, rawSvc:GetHashMap(name), false) end

	function svc.GetQueue(_self: any, name: string, invisibilityTimeout: number?): any
		return wrapQueue(name, invisibilityTimeout)
	end

	server.MemoryStoreService = svc
	server.host.MemoryStoreService = svc
end

-- MessagingService ---------------------------------------------------------------------------------------------------

function Fabric.attachMessaging(w: any, server: any)
	local bus = w.backing.messaging
	local svc: any = {}

	function svc.SubscribeAsync(_self: any, topic: string, callback: (any) -> ()): any
		return serverCall(w, server, "MessagingService", "SubscribeAsync", false, function(_localAck: boolean)
			local sub: any = {
				id = bus.nextSubId,
				server = server,
				topic = topic,
				callback = callback,
				disconnected = false,
			}
			bus.nextSubId += 1
			table.insert(bus.subscriptions, sub)
			return {
				Connected = true,
				Disconnect = function(conn: any)
					conn.Connected = false
					sub.disconnected = true
				end,
			}
		end)
	end

	function svc.PublishAsync(_self: any, topic: string, message: any)
		local snap = copy(message)
		serverCall(w, server, "MessagingService", "PublishAsync", true, function(_localAck: boolean)
			if (w.faults.drop or 0) > 0 and w.scheduler:chance(w.faults.drop, "MessagingService.drop") then
				w:trace(`messagingDrop {topic} from {server.name}`)
				return
			end
			local copies = if (w.faults.duplicate or 0) > 0
					and w.scheduler:chance(w.faults.duplicate, "MessagingService.duplicate")
				then 2
				else 1
			for copyIdx = 1, copies do
				local msg = {
					id = bus.nextMsgId,
					topic = topic,
					data = copy(snap),
					sent = server:now(),
					origin = server,
					delivered = false,
				}
				bus.nextMsgId += 1
				table.insert(bus.queue, msg)
				local transit = w:latency("delivery") + (copyIdx - 1) * 0.005
				w.scheduler:after(math.max(0, transit), nil, function() bus.deliver(msg) end)
			end
		end)
	end

	function svc._pump() bus.drain() end

	server.MessagingService = svc
	server.host.MessagingService = svc
end

-- Cross-Peer Instance Translation & VOPR Remote Packet Pipeline ------------------------------------------------------

local function translateClientToServer(client: any?, server: any): (any) -> any
	return function(inst: any): any
		local cliEnv: any = if client ~= nil then rawget(client, "_env") else nil
		local srvEnv: any = rawget(server, "_env")
		if cliEnv ~= nil and cliEnv._sourceOf ~= nil then
			local src: any = cliEnv._sourceOf[inst]
			if src ~= nil and not rawget(src, "_destroyed") then return src end
			return nil
		end
		if cliEnv == nil and srvEnv == nil then return inst end
		return nil
	end
end

local function resolveReplicatedOnClient(srvInst: any, srvEnv: any, cliEnv: any): any
	local existing = cliEnv._mirrorOf[srvInst]
	if existing ~= nil and not rawget(existing, "_destroyed") then return existing end
	-- Walk ancestor chain up to a replicated service (`ReplicatedStorage`, `Workspace`, `Players`) for lazy mirrors.
	local chain: { any } = {}
	local cur: any = srvInst
	while cur ~= nil do
		if cur == srvEnv.ReplicatedStorage then
			local node: any = cliEnv.ReplicatedStorage
			for i = #chain, 1, -1 do
				node = node:FindFirstChild(chain[i].Name)
				if node == nil then return nil end
			end
			return node
		elseif cur == srvEnv.Workspace then
			local node: any = cliEnv.Workspace
			for i = #chain, 1, -1 do
				node = node:FindFirstChild(chain[i].Name)
				if node == nil then return nil end
			end
			return node
		elseif cur == srvEnv.Players then
			local node: any = cliEnv.Players
			for i = #chain, 1, -1 do
				node = node:FindFirstChild(chain[i].Name)
				if node == nil then return nil end
			end
			return node
		end
		table.insert(chain, cur)
		cur = rawget(cur, "_parent")
	end
	return nil
end

local function translateServerToClient(server: any, client: any?): (any) -> any
	return function(inst: any): any
		local srvEnv: any = rawget(server, "_env")
		local cliEnv: any = if client ~= nil then rawget(client, "_env") else nil
		if srvEnv ~= nil and cliEnv ~= nil and cliEnv._mirrorOf ~= nil then
			return resolveReplicatedOnClient(inst, srvEnv, cliEnv)
		end
		if srvEnv == nil and cliEnv == nil then return inst end
		return nil
	end
end

local function serializeTuple(mapper: (any) -> any, ...: any): { [number]: any, n: number }
	local count = select("#", ...)
	local out: { [number]: any, n: number } = { n = count }
	for i = 1, count do
		local v = select(i, ...)
		out[i] = serialize.remote(v, {
			allowInstances = true,
			mapInstance = mapper,
		})
	end
	return out
end

local function estimateBytes(packed: { [number]: any, n: number }): number
	local ok, encoded = pcall(format.json, packed)
	return if ok then #encoded else 0
end

local function computeRemoteTransit(w: any): (number, boolean)
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
				local idx = s:choose(11, "remote.latency") - 1
				delay = lo + (hi - lo) * (idx / 10)
			end
		end
	else
		delay = w:latency("remotes")
	end
	local reorderRate = w.faults.remoteReorderRate or 0
	local reordered = reorderRate > 0 and s:chance(reorderRate, "remote.reorder")
	return delay, reordered
end

local function shouldDropPacket(w: any, unreliable: boolean): boolean
	local s = w.scheduler
	local dropRate = w.faults.remoteDropRate or 0
	if dropRate > 0 and s:chance(dropRate, "remote.drop") then return true end
	if unreliable then
		local uDrop = w.faults.drop or 0
		if uDrop > 0 and s:chance(uDrop, "remotes.unreliableDrop") then return true end
	end
	return false
end

local function recordRemoteError(w: any, peerName: string, remoteName: string, err: any)
	local text = format.errorText(err)
	table.insert(w.remoteErrors, {
		peer = peerName,
		remote = remoteName,
		err = text,
		time = w:now(),
	})
	w:trace(`remoteError {remoteName} ({peerName}): {text}`)
end

function Fabric.attachRemotes(w: any, server: any): any
	if server._net ~= nil then return server._net end

	local serverEvents: { [string]: any } = {}
	local serverRpcs: { [string]: any } = {}
	local pendingCallers: { PendingCaller } = {}
	local nextCallerId = 1
	local lastSendReadyAt = 0

	local function makeSignal(): any return makeWorldSignal(w, server, true) end

	local function findClientForPlayer(player: any): any?
		if player == nil then return nil end
		for _, cli in server.clients do
			if cli == player or cli.player == player or cli.userId == player then return cli end
			if type(player) == "table" and player.UserId ~= nil and cli.userId == player.UserId then return cli end
		end
		return nil
	end

	local function resolveServerPlayer(client: any): any
		local srvEnv: any = rawget(server, "_env")
		if srvEnv ~= nil and srvEnv.Players ~= nil then
			for _, child in srvEnv.Players:GetChildren() do
				if child.ClassName == "Player" and child.UserId == client.userId then return child end
			end
		end
		return client.player
	end

	local function schedulePacket(
		remoteName: string,
		unreliable: boolean,
		packedFactory: () -> { [number]: any, n: number },
		deliverFn: (packed: { [number]: any, n: number }) -> ()
	)
		local firstPacked = packedFactory()
		if unreliable and estimateBytes(firstPacked) > UNRELIABLE_MAX_BYTES then
			w:trace(`remoteOversizeDrop {remoteName}`)
			return
		end
		if shouldDropPacket(w, unreliable) then
			w:trace(`remoteDrop {remoteName}`)
			return
		end

		local dupRate = w.faults.remoteDuplicateRate or 0
		local copies = if dupRate > 0 and w.scheduler:chance(dupRate, "remote.duplicate") then 2 else 1
		local delay, reordered = computeRemoteTransit(w)
		local now = w:now()

		if delay <= 0 and not reordered then
			deliverFn(firstPacked)
			if copies > 1 then deliverFn(packedFactory()) end
			return
		end

		local targetAt = now + delay
		if reordered then
			targetAt = math.max(targetAt, lastSendReadyAt) + 0.03
		else
			if targetAt < lastSendReadyAt and not unreliable then targetAt = lastSendReadyAt end
			lastSendReadyAt = targetAt
		end

		for copyIdx = 1, copies do
			local payload = if copyIdx == 1 then firstPacked else packedFactory()
			local fireAt = targetAt + (copyIdx - 1) * 0.005
			w.pendingRemotes = (w.pendingRemotes or 0) + 1
			w.scheduler:after(math.max(0, fireAt - now), nil, function()
				w.pendingRemotes = math.max(0, (w.pendingRemotes or 0) - 1)
				deliverFn(payload)
			end)
		end
	end

	local function getOrCreateEvent(name: string, unreliable: boolean): any
		local ev: any = serverEvents[name]
		if ev ~= nil then return ev end
		ev = {
			name = name,
			unreliable = unreliable,
			OnServerEvent = makeSignal(),
			clientSignals = {} :: { [number]: any },
		}

		function ev.clientSignal(client: any): any
			local sig = ev.clientSignals[client.id]
			if sig == nil then
				sig = makeSignal()
				ev.clientSignals[client.id] = sig
			end
			return sig
		end

		function ev.FireClient(_self: any, player: any, ...: any)
			if not server.alive then return end
			local target = findClientForPlayer(player)
			if target == nil or not target.connected or target.server ~= server then return end
			local rawArgs = packValues(...)
			-- Validate eagerly on sender side (matching Roblox RemoteEvent argument checks).
			local validated = serializeTuple(translateServerToClient(server, target), unpackValues(rawArgs))
			local firstUsed = false
			schedulePacket(name, ev.unreliable, function()
				if not firstUsed then
					firstUsed = true
					return validated
				end
				return serializeTuple(translateServerToClient(server, target), unpackValues(rawArgs))
			end, function(packed)
				if not server.alive or not target.connected or target.server ~= server then return end
				target:spawn(function()
					local ok, err = pcall(function() ev.clientSignal(target):Fire(unpackValues(packed)) end)
					if not ok then recordRemoteError(w, target.name, name, err) end
				end)
			end)
		end

		function ev.FireAllClients(self: any, ...: any)
			if not server.alive then return end
			local snapshot: { any } = table.clone(server.clients)
			for _, cli in snapshot do
				if cli.connected and cli.server == server then self:FireClient(cli.player, ...) end
			end
		end

		serverEvents[name] = ev
		return ev
	end

	local function getOrCreateRpc(name: string): any
		local rpc = serverRpcs[name]
		if rpc ~= nil then return rpc end
		rpc = {
			name = name,
			OnServerInvoke = nil :: ((any, ...any) -> ...any)?,
			clientHandlers = {} :: { [number]: (...any) -> ...any },
		}
		serverRpcs[name] = rpc
		return rpc
	end

	local function invokeAcrossPeers(
		name: string,
		senderAlive: () -> boolean,
		receiverAlive: () -> boolean,
		receiverSpawn: (() -> ()) -> (),
		reqMapper: (any) -> any,
		resMapper: (any) -> any,
		getHandler: () -> ((...any) -> ...any)?,
		prependArg: (() -> any)?,
		...: any
	): ...any
		if not senderAlive() then error(`RemoteFunction '{name}': sender disconnected`, 0) end
		local reqPacked = serializeTuple(reqMapper, ...)
		if shouldDropPacket(w, false) or not receiverAlive() then
			error(`RemoteFunction '{name}': connection lost`, 0)
		end

		local callerThread = coroutine.running()
		local callerRecord: PendingCaller = {
			id = nextCallerId,
			active = true,
			thread = callerThread,
		}
		nextCallerId += 1
		table.insert(pendingCallers, callerRecord)

		local function removeCaller()
			if not callerRecord.active then return end
			callerRecord.active = false
			for i = #pendingCallers, 1, -1 do
				if pendingCallers[i] == callerRecord then
					table.remove(pendingCallers, i)
					break
				end
			end
		end

		local reqDelay = (computeRemoteTransit(w))
		local done = false
		local replyOk = false
		local replyData: any = nil

		w.pendingRemotes = (w.pendingRemotes or 0) + 1
		w.scheduler:after(math.max(0, reqDelay), nil, function()
			if not callerRecord.active or not senderAlive() or not receiverAlive() then
				w.pendingRemotes = math.max(0, (w.pendingRemotes or 0) - 1)
				if callerRecord.active then
					done = true
					replyOk = false
					replyData = `RemoteFunction '{name}': peer disconnected`
					removeCaller()
					if coroutine.status(callerThread) == "suspended" then w.scheduler:resume(callerThread) end
				end
				return
			end

			receiverSpawn(function()
				local fn = getHandler()
				local okCall, resOrErr: any
				if fn == nil then
					okCall, resOrErr = true, { n = 0 }
				else
					okCall, resOrErr = pcall(function()
						if prependArg ~= nil then return packValues(fn(prependArg(), unpackValues(reqPacked))) end
						return packValues(fn(unpackValues(reqPacked)))
					end)
				end

				local resDelay = (computeRemoteTransit(w))
				w.scheduler:after(math.max(0, resDelay), nil, function()
					w.pendingRemotes = math.max(0, (w.pendingRemotes or 0) - 1)
					if not callerRecord.active then return end
					done = true
					if not senderAlive() or not receiverAlive() or shouldDropPacket(w, false) then
						replyOk = false
						replyData = `RemoteFunction '{name}': connection lost before reply`
					elseif not okCall then
						replyOk = false
						replyData = format.errorText(resOrErr)
					else
						local okSer, serializedOrErr = pcall(
							function() return serializeTuple(resMapper, unpackValues(resOrErr)) end
						)
						if okSer then
							replyOk = true
							replyData = serializedOrErr
						else
							replyOk = false
							replyData = format.errorText(serializedOrErr)
						end
					end
					removeCaller()
					if coroutine.status(callerThread) == "suspended" then w.scheduler:resume(callerThread) end
				end)
			end)
		end)

		while not done do
			coroutine.yield()
		end
		removeCaller()
		if not replyOk then error(replyData, 0) end
		return unpackValues(replyData)
	end

	local net: any = {
		clients = server.clients,
	}

	function net.abortDisconnected()
		local snapshot = table.clone(pendingCallers)
		for _, rec in snapshot do
			if rec.active then
				rec.active = false
				if coroutine.status(rec.thread) == "suspended" then w.scheduler:resume(rec.thread) end
			end
		end
		table.clear(pendingCallers)
	end

	function net.channel(_self: any, name: string, unreliable: boolean?, client: any?): any
		local ev = getOrCreateEvent(name, unreliable == true)
		if client == nil then return ev end
		return {
			OnClientEvent = ev.clientSignal(client),
			FireServer = function(_ch: any, ...: any)
				if not client.connected or client.server ~= server or not server.alive then return end
				local rawArgs = packValues(...)
				local validated = serializeTuple(translateClientToServer(client, server), unpackValues(rawArgs))
				local firstUsed = false
				schedulePacket(name, ev.unreliable, function()
					if not firstUsed then
						firstUsed = true
						return validated
					end
					return serializeTuple(translateClientToServer(client, server), unpackValues(rawArgs))
				end, function(packed)
					if not server.alive or not client.connected or client.server ~= server then return end
					local playerArg = resolveServerPlayer(client)
					server:spawn(function()
						local ok, err = pcall(function() ev.OnServerEvent:Fire(playerArg, unpackValues(packed)) end)
						if not ok then recordRemoteError(w, server.name, name, err) end
					end)
				end)
			end,
		}
	end

	function net.rpc(_self: any, name: string, client: any?): any
		local rpc = getOrCreateRpc(name)
		if client == nil then
			return setmetatable({
				InvokeClient = function(_r: any, player: any, ...: any): ...any
					local target = findClientForPlayer(player)
					if target == nil then error(`InvokeClient('{name}'): target player is not connected`, 0) end
					return invokeAcrossPeers(
						name,
						function() return server.alive end,
						function() return target.connected and target.server == server end,
						function(fn) target:spawn(fn) end,
						translateServerToClient(server, target),
						translateClientToServer(target, server),
						function() return rpc.clientHandlers[target.id] end,
						nil,
						...
					)
				end,
			}, {
				__index = function(_t: any, k: string): any
					if k == "OnServerInvoke" then return rpc.OnServerInvoke end
					return nil
				end,
				__newindex = function(_t: any, k: string, v: any)
					if k == "OnServerInvoke" then rpc.OnServerInvoke = v end
				end,
			})
		end

		return setmetatable({
			InvokeServer = function(_r: any, ...: any): ...any
				return invokeAcrossPeers(
					name,
					function(): boolean return client.connected == true and client.server == server end,
					function(): boolean
						return server.alive == true and client.connected == true and client.server == server
					end,
					function(fn) server:spawn(fn) end,
					translateClientToServer(client, server),
					translateServerToClient(server, client),
					function() return rpc.OnServerInvoke end,
					function() return resolveServerPlayer(client) end,
					...
				)
			end,
		}, {
			__index = function(_t: any, k: string): any
				if k == "OnClientInvoke" then return rpc.clientHandlers[client.id] end
				return nil
			end,
			__newindex = function(_t: any, k: string, v: any)
				if k == "OnClientInvoke" then rpc.clientHandlers[client.id] = v end
			end,
		})
	end

	function net.event(self: any, name: string): any return self:channel(name, false, nil) end

	function net.unreliable(self: any, name: string): any return self:channel(name, true, nil) end

	function net.func(self: any, name: string): any return self:rpc(name, nil) end

	function net.forClient(self: any, client: any): any
		return {
			channel = function(_c: any, cname: string, unreliable: boolean?)
				return self:channel(cname, unreliable, client)
			end,
			rpc = function(_c: any, cname: string) return self:rpc(cname, client) end,
			event = function(_c: any, cname: string) return self:channel(cname, false, client) end,
			unreliable = function(_c: any, cname: string) return self:channel(cname, true, client) end,
			func = function(_c: any, cname: string) return self:rpc(cname, client) end,
		}
	end

	server._net = net
	server.remotes = net
	server.host.remotes = net
	return net
end

-- Players Service Double ---------------------------------------------------------------------------------------------

function Fabric.attachPlayers(w: any, server: any)
	local added = makeWorldSignal(w, server, false)
	local removing = makeWorldSignal(w, server, false)

	local playersSvc: any = {
		PlayerAdded = added,
		PlayerRemoving = removing,
	}

	function playersSvc.GetPlayers(_self: any): { any }
		local list = {}
		for _, cli in server.clients do
			if cli.connected and cli.server == server then table.insert(list, cli.player) end
		end
		return list
	end

	function playersSvc.GetPlayerByUserId(_self: any, userId: number): any?
		for _, cli in server.clients do
			if cli.connected and cli.server == server and cli.userId == userId then return cli.player end
		end
		return nil
	end

	server.Players = playersSvc
	server.players = playersSvc
	server.host.Players = playersSvc
	return w
end

-- VOPR Hazard 1: TeleportService Session-Lock Handoff Race (`teleportRaceRate`) -------------------------------------

local function extractTeleportData(teleportOptions: any?): any
	if teleportOptions == nil then return nil end
	if type(teleportOptions) == "table" then
		local okMethod, getFn = pcall(function() return teleportOptions.GetTeleportData end)
		if okMethod and type(getFn) == "function" then
			local okCall, td = pcall(getFn, teleportOptions)
			if okCall then return serialize.remote(td, { allowInstances = false }) end
		end
		local props = rawget(teleportOptions, "_props")
		if type(props) == "table" and props._teleportData ~= nil then
			return serialize.remote(props._teleportData, { allowInstances = false })
		end
		if teleportOptions.TeleportData ~= nil then
			return serialize.remote(teleportOptions.TeleportData, { allowInstances = false })
		end
	end
	return nil
end

local function extractAccessCode(teleportOptions: any?): string?
	if type(teleportOptions) ~= "table" then return nil end
	local props = rawget(teleportOptions, "_props")
	if
		type(props) == "table"
		and type(props.ReservedServerAccessCode) == "string"
		and #props.ReservedServerAccessCode > 0
	then
		return props.ReservedServerAccessCode
	end
	if type(teleportOptions.ReservedServerAccessCode) == "string" and #teleportOptions.ReservedServerAccessCode > 0 then
		return teleportOptions.ReservedServerAccessCode
	end
	return nil
end

function Fabric.attachTeleport(w: any, server: any)
	local teleportFailed = makeWorldSignal(w, server, false)
	local svc: any = {
		TeleportInitFailed = teleportFailed,
	}

	function svc.ReserveServer(_self: any, placeId: number): (string, string)
		return serverCall(w, server, "TeleportService", "ReserveServer", true, function(_localAck: boolean)
			w._nextReserveSeq = (w._nextReserveSeq or 0) + 1
			local code = `access_{placeId}_{w._nextReserveSeq}`
			local privateId = `private_{placeId}_{w._nextReserveSeq}`
			w._reservedPlaces[code] = { placeId = placeId, privateServerId = privateId, server = nil }
			return code, privateId
		end)
	end

	function svc.TeleportAsync(_self: any, placeId: number, players: { any }, teleportOptions: any?): any
		local teleportData = extractTeleportData(teleportOptions)
		local accessCode = extractAccessCode(teleportOptions)
		local targetPlayers = table.clone(players)
		local raceRate = w.faults.teleportRaceRate or 0

		return serverCall(w, server, "TeleportService", "TeleportAsync", true, function(_localAck: boolean)
			-- Resolve or spawn destination server.
			local dest: any = nil
			local privateServerId = ""
			if accessCode ~= nil then
				local resInfo = w._reservedPlaces[accessCode]
				if resInfo ~= nil then
					privateServerId = resInfo.privateServerId
					if resInfo.server ~= nil and resInfo.server.alive then
						dest = resInfo.server
					else
						dest = w:server({ placeId = placeId, privateServerId = privateServerId })
						resInfo.server = dest
					end
				end
			end
			if dest == nil then
				for _, cand in w.servers do
					if cand ~= server and cand.alive and (cand.placeId == placeId or placeId == 0) then
						dest = cand
						break
					end
				end
			end
			if dest == nil then dest = w:server({ placeId = placeId }) end

			for _, playerObj in targetPlayers do
				local uid = if type(playerObj) == "table" then playerObj.UserId else playerObj
				local cli: any = nil
				for _, c in server.clients do
					if c.userId == uid and c.connected then
						cli = c
						break
					end
				end
				if cli ~= nil then
					local race = raceRate > 0 and w.scheduler:chance(raceRate, "teleport.race")
					if race then
						-- Session-lock handoff hazard: destination `PlayerAdded` fires BEFORE source `PlayerRemoving` completes!
						local mode = w.scheduler:pick({ "before_removing", "during_removing" }, "teleport.raceMode")
						w:trace(`teleportRace ({mode}) userId={cli.userId} {server.name} -> {dest.name}`)
						w:handoffClient(cli, server, dest, teleportData, mode)
					else
						w:handoffClient(cli, server, dest, teleportData, "ordered")
					end
				end
			end

			return {
				PrivateServerId = privateServerId,
				ReservedServerAccessCode = accessCode or "",
			}
		end)
	end

	server.TeleportService = svc
	server.host.TeleportService = svc
end

-- VOPR Hazard 3: MarketplaceService.ProcessReceipt Duplicate Delivery (`receiptDuplicateRate`) -----------------------

local function isPurchaseGranted(decision: any): boolean
	if decision == Datatypes.Enum.ProductPurchaseDecision.PurchaseGranted then return true end
	if type(decision) == "string" and decision == "PurchaseGranted" then return true end
	if util.typeof(decision) == "EnumItem" and (decision :: any).Name == "PurchaseGranted" then return true end
	return false
end

function Fabric.deliverReceipt(w: any, record: any, server: any)
	if record.granted or record.inFlight or not server.alive then return end

	local function getCallback(): ((any) -> any)?
		local srvEnv: any = rawget(server, "_env")
		if srvEnv ~= nil and srvEnv.game ~= nil then
			local okMkt, mkt: any = pcall(function() return srvEnv.game:GetService("MarketplaceService") end)
			if okMkt and type(mkt) == "table" then
				local props: any = rawget(mkt, "_props")
				if type(props) == "table" and type(props.ProcessReceipt) == "function" then
					return props.ProcessReceipt
				end
			end
		end
		if type(server.MarketplaceService.ProcessReceipt) == "function" then
			return server.MarketplaceService.ProcessReceipt
		end
		return nil
	end

	-- Confirm player is connected to `server` before invoking `ProcessReceipt`.
	local connected = false
	for _, cli in server.clients do
		if cli.connected and cli.server == server and cli.userId == record.playerId then
			connected = true
			break
		end
	end
	if not connected then return end

	local cb = getCallback()
	if cb == nil then return end

	record.inFlight = true
	record.attempts += 1
	local dupRate = w.faults.receiptDuplicateRate or 0

	local receiptInfo = {
		PurchaseId = record.purchaseId,
		PlayerId = record.playerId,
		ProductId = record.productId,
		PlaceIdWherePurchased = record.placeId,
		CurrencySpent = record.currencySpent,
		PurchaseType = Datatypes.Enum.InfoType.Product,
	}

	local settled = false
	local deadlineTimer: thread? = nil

	local function scheduleRedelivery(reason: string)
		if settled then return end
		settled = true
		record.inFlight = false
		if deadlineTimer ~= nil then w.scheduler:cancel(deadlineTimer) end
		w:trace(`receiptRedeliver {record.purchaseId} (player={record.playerId}): {reason}`)
		w.scheduler:after(0.1, nil, function()
			if record.granted then return end
			for _, srv in w.servers do
				if srv.alive then
					for _, cli in srv.clients do
						if cli.connected and cli.server == srv and cli.userId == record.playerId then
							Fabric.deliverReceipt(w, record, srv)
							return
						end
					end
				end
			end
		end)
	end

	deadlineTimer = w.scheduler:after(
		RECEIPT_DEADLINE,
		nil,
		function() scheduleRedelivery("ProcessReceipt exceeded deadline") end
	)

	server:spawn(function()
		local ok, decision = pcall(cb, util.copy(receiptInfo))
		if settled then return end
		if deadlineTimer ~= nil then w.scheduler:cancel(deadlineTimer) end

		if not server.alive then
			scheduleRedelivery("server stopped during ProcessReceipt")
			return
		end
		if not ok then
			scheduleRedelivery(`ProcessReceipt threw: {format.errorText(decision)}`)
			return
		end
		if not isPurchaseGranted(decision) then
			scheduleRedelivery("NotProcessedYet")
			return
		end

		if not record.duplicatedOnce and dupRate > 0 and w.scheduler:chance(dupRate, "receipt.duplicate") then
			record.duplicatedOnce = true
			scheduleRedelivery("simulated ACK loss after PurchaseGranted")
			return
		end

		settled = true
		record.inFlight = false
		record.granted = true
		w:trace(`receiptGranted {record.purchaseId} (attempts={record.attempts})`)
	end)
end

function Fabric.flushPlayerReceipts(w: any, server: any, userId: number)
	for _, record in w.receipts do
		if not record.granted and not record.inFlight and record.playerId == userId then
			Fabric.deliverReceipt(w, record, server)
		end
	end
end

function Fabric.attachMarketplace(w: any, server: any)
	local svc: any = {
		ProcessReceipt = nil :: ((any) -> any)?,
	}

	function svc.PromptProductPurchase(_self: any, player: any, productId: number)
		local uid = if type(player) == "table" then player.UserId else player
		if type(uid) == "number" then w:purchaseProduct(uid, productId) end
	end

	server.MarketplaceService = svc
	server.host.MarketplaceService = svc
end

-- Bind TeleportService & MarketplaceService onto `server:env()` when instantiated ------------------------------------

function Fabric.bindServerEnv(_w: any, server: any, envInst: any)
	-- Override `TeleportService:TeleportAsync` & `ReserveServer` inside `server:env()` so DataModel scripts route through VOPR.
	local okTp, tp: any = pcall(function() return envInst.game:GetService("TeleportService") end)
	if okTp and type(tp) == "table" then
		local rawTpMethods: { [string]: any } = (rawget(tp, "_methods") :: any) or {}
		local patchedTp: { [string]: any } = table.clone(rawTpMethods)
		patchedTp.TeleportAsync = function(
			_self: any,
			placeId: number,
			players: { any },
			teleportOptions: any?
		): any
			return server.TeleportService:TeleportAsync(placeId, players, teleportOptions)
		end
		patchedTp.ReserveServer = function(_self: any, placeId: number): (string, string)
			return server.TeleportService:ReserveServer(placeId)
		end
		rawset(tp, "_methods", patchedTp)
	end

	-- Route `MarketplaceService:PromptProductPurchase` inside `server:env()` to `w:purchaseProduct`.
	local okMkt, mkt: any = pcall(function() return envInst.game:GetService("MarketplaceService") end)
	if okMkt and type(mkt) == "table" then
		local rawMktMethods: { [string]: any } = (rawget(mkt, "_methods") :: any) or {}
		local patchedMkt: { [string]: any } = table.clone(rawMktMethods)
		local origPrompt: ((any, any, number) -> ())? = rawMktMethods.PromptProductPurchase
		patchedMkt.PromptProductPurchase = function(self: any, player: any, productId: number)
			if origPrompt ~= nil then origPrompt(self, player, productId) end
			server.MarketplaceService:PromptProductPurchase(player, productId)
		end
		rawset(mkt, "_methods", patchedMkt)
	end
end

function Fabric.bindClientEnv(_w: any, client: any, envInst: any)
	local okTp, tp: any = pcall(function() return envInst.game:GetService("TeleportService") end)
	if okTp and type(tp) == "table" then
		local rawTpMethods: { [string]: any } = (rawget(tp, "_methods") :: any) or {}
		local patchedTp: { [string]: any } = table.clone(rawTpMethods)
		patchedTp.GetLocalPlayerTeleportData = function(_self: any): any return util.copy(client.teleportData) end
		rawset(tp, "_methods", patchedTp)
	end
end

function Fabric.attachAll(w: any, server: any)
	server.EncodingService = EncodingService.new()
	server.host.EncodingService = server.EncodingService
	Fabric.attachHttp(w, server)
	Fabric.attachDataStore(w, server)
	Fabric.attachMemoryStore(w, server)
	Fabric.attachMessaging(w, server)
	Fabric.attachRemotes(w, server)
	Fabric.attachPlayers(w, server)
	Fabric.attachTeleport(w, server)
	Fabric.attachMarketplace(w, server)
end

return Fabric
