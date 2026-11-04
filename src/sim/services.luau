--!strict
-- Per-server service facades for the simulator (`Sim.services`).

local DataStoreDouble = require("../doubles/datastore")
local Datatypes = require("../doubles/datatypes")
local EncodingDouble = require("../doubles/encoding_service")
local MemoryStoreDouble = require("../doubles/memorystore")
local Scheduler = require("./scheduler")
local util = require("../util")

local Config = Scheduler.Config
local Http = EncodingDouble.HttpService
local deepCopy = util.copy
local customTypeof = Datatypes.typeof

local RunService = {}
local SERVER_PHASES = table.freeze({ "PreAnimation", "PreSimulation", "Stepped", "PostSimulation", "Heartbeat" })
local CLIENT_PHASES = table.freeze({
	"PreRender",
	"RenderStepped",
	"PreAnimation",
	"PreSimulation",
	"Stepped",
	"PostSimulation",
	"Heartbeat",
})
RunService.SERVER_PHASES, RunService.CLIENT_PHASES = SERVER_PHASES, CLIENT_PHASES

function RunService.new(world: any, owner: any, client: boolean, studio: (() -> boolean)?): any
	local run: any = {
		_phases = if client then CLIENT_PHASES else SERVER_PHASES,
		IsServer = function(): boolean return not client end,
		IsClient = function(): boolean return client end,
		IsStudio = function(): boolean return if studio ~= nil then studio() else false end,
	}
	for _, phase in run._phases do
		run[phase] = world:signal(owner, "spawn")
	end
	return run
end

function RunService.step(run: any, dt: number, now: number)
	for _, phase in run._phases do
		local sig = run[phase]
		if #sig._listeners > 0 then
			if phase == "Stepped" then
				sig:Fire(now, dt)
			else
				sig:Fire(dt)
			end
		end
	end
end

local Players = {}

function Players.new(world: any, server: any): any
	local p: any = {
		peers = {},
		list = {},
		PlayerAdded = world:signal(server, "defer"),
		PlayerRemoving = world:signal(server, "defer"),
	}
	function p.GetPlayers(_: any): { any }
		local result = table.clone(p.list)
		if next(p.peers) == nil then return result end
		local seen, extra = {}, {}
		for _, player in result do
			seen[player] = true
		end
		for id, player in p.peers do
			if not seen[player] then table.insert(extra, id) end
		end
		if #extra > 1 then table.sort(extra) end
		for _, id in extra do
			table.insert(result, p.peers[id])
		end
		return result
	end
	function p.GetPlayerByUserId(_: any, id: number): any return p.peers[id] end
	return p
end

function Players.join(server: any, userId: number): any
	local w = server.world
	local env = server._env
	local uname = if env ~= nil and env.userNames ~= nil then env.userNames[userId] else nil
	local player: any = { UserId = userId, Name = uname or `Player{userId}` }
	if uname ~= nil then player.DisplayName = uname end
	function player.Kick(p: any, message: string?) w:kick(server, p, message) end
	server.players.peers[userId] = player
	table.insert(server.players.list, player)
	if env ~= nil then env:_decoratePlayer(player) end
	w:trace(`join {userId} {server.name}`)
	server.players.PlayerAdded:Fire(player)
	return player
end

function Players.leave(server: any, player: any)
	local p = server.players
	local index = table.find(p.list, player)
	if index then table.remove(p.list, index) end
	if p.peers[player.UserId] == player then p.peers[player.UserId] = nil end
	server.world:trace(`leave {player.UserId} {server.name}`)
	p.PlayerRemoving:Fire(player)
	if type(player) == "table" and rawget(player, "_isInstance") == true then
		if server.world.instant then
			if rawget(player, "_parent") ~= nil then player.Parent = nil end
		else
			server.world.scheduler:defer(server, function()
				if rawget(player, "_parent") ~= nil then player.Parent = nil end
			end)
		end
	end
end

local CACHE_SECONDS, ATTEMPTS, HISTORY_LIMIT = 4, 10, 8
local FRESH = table.freeze({ UseCache = false })
local TYPES = DataStoreDouble.REQUEST_TYPES
local info, dsCopy = DataStoreDouble.makeKeyInfo, DataStoreDouble.copy

local function pushHistory(bucket: { any }, entry: any)
	table.insert(bucket, entry)
	if #bucket > HISTORY_LIMIT then table.remove(bucket, 1) end
end

local function pickStaleSnapshot(world: any, bucket: { any }?, label: string): any?
	if bucket == nil or #bucket == 0 then return nil end
	return if world.mode == "random" then world.scheduler:pick(bucket, label) else bucket[#bucket]
end

local DataStore = {}

function DataStore.new(world: any, options: { [string]: any }?, backing: Scheduler.Backing?): any
	local store: any = backing or Config.datastore or DataStoreDouble
	local clone: (any) -> any = store.copy or dsCopy
	local given: any = table.clone(options or {})
	given.clock = given.clock or function(): number return world:unix() end
	local service: any = { mock = store.new(given), stores = {}, history = {} }
	local function describe(raw: any, name: string, scope: string?, ordered: boolean): any
		local found = service.stores[raw]
		if found == nil then
			found = table.freeze({ name = name, scope = scope or "global", ordered = ordered, handle = raw })
			service.stores[raw] = found
		end
		return found
	end
	local function historyFor(raw: any): { [string]: { any } }
		local h = service.history[raw]
		if h == nil then
			h = {}
			service.history[raw] = h
		end
		return h
	end
	local function snapshotRow(raw: any, ordered: boolean, key: string): { value: any, info: any }
		local row = raw.data[key]
		if row == nil then return { value = nil, info = nil } end
		if ordered then return { value = row, info = nil } end
		return { value = clone(row.value), info = info(row, clone) }
	end
	local function recordPrior(raw: any, ordered: boolean, key: string)
		local h = historyFor(raw)
		local bucket = h[key]
		if bucket == nil then
			bucket = {}
			h[key] = bucket
		end
		pushHistory(bucket, snapshotRow(raw, ordered, key))
		local allBucket = h._all
		if allBucket == nil then
			allBucket = {}
			h._all = allBucket
		end
		pushHistory(allBucket, table.clone(raw.data))
	end

	function service.facade(_self: any, server: any): any
		local s = world.scheduler
		local budgets = DataStoreDouble.budget(
			function(): number return s.now end,
			function(): number? return world.faults.budget end
		)
		local facade: any = { budgets = budgets.rows }
		function facade.budget(_: any, requestType: string, units: number?, perMinute: number?)
			budgets:set(requestType, units, perMinute)
		end
		function facade.GetRequestBudgetForRequestType(_: any, requestType: any): number
			return budgets:remaining(requestType) or DataStoreDouble.UNMODELLED
		end
		local function charge(types: { string })
			local exhausted = budgets:charge(types)
			if exhausted ~= nil then
				world:trace(`ds throttled {exhausted} on {server.name}`)
				error(`RequestThrottled: {exhausted} budget exhausted on {server.name}`, 0)
			end
		end

		local proxies: { [any]: any } = {}
		local function wrap(raw: any, storeDesc: any): any
			local types = TYPES[if storeDesc.ordered then "ordered" else "standard"]
			local cache: { [string]: { at: number, value: any, info: any } } = {}
			local storeHist = historyFor(raw)
			local function call(method: string, body: (...any) -> ...any, ...: any): ...any
				charge(types[method])
				return world:call(server, "DataStoreService", method, body, ...)
			end
			local function callOpts(method: string, opts: any, body: (...any) -> ...any, ...: any): ...any
				charge(types[method])
				return world:callOpts(server, "DataStoreService", method, opts, body, ...)
			end
			local function commit(key: string) world:commit(storeDesc, key, raw.data[key], server) end
			local function pages(result: any): any
				local advance = result.AdvanceToNextPageAsync
				result.AdvanceToNextPageAsync = function(p: any)
					charge(if storeDesc.ordered then types.GetSortedAsync else types.ListVersionsAsync)
					return world:call(server, "DataStoreService", "AdvanceToNextPageAsync", advance, p)
				end
				return result
			end
			local function invokeTransform(transform: any, snapshot: any): { n: number, [number]: any }
				return if storeDesc.ordered
					then world:transform(transform, snapshot, nil)
					else world:transform(
						transform,
						if snapshot then clone(snapshot.value) else nil,
						info(snapshot, clone)
					)
			end
			local proxy: any = setmetatable({}, { __index = raw })
			function proxy.GetAsync(_: any, key: string, getOptions: any?): ...any
				local entry = cache[key]
				local fresh = getOptions ~= nil and getOptions.UseCache == false
				local scripted = world.scripted["DataStoreService.GetAsync"]
				local hasScriptedOrGate = (scripted ~= nil and #scripted > 0)
					or world.gates["DataStoreService.GetAsync"] ~= nil
				if
					not storeDesc.ordered
					and not fresh
					and not hasScriptedOrGate
					and entry ~= nil
					and s.now - entry.at < CACHE_SECONDS
				then
					return clone(entry.value), entry.info
				end
				local value, keyInfo = callOpts("GetAsync", {
					stale = function(): (boolean, any, any)
						local snap = pickStaleSnapshot(world, storeHist[key], "ds.stale")
						if snap == nil then return false, nil, nil end
						return true, clone(snap.value), snap.info
					end,
				}, function(): ...any return raw:GetAsync(key, FRESH) end)
				cache[key] = { at = s.now, value = clone(value), info = keyInfo }
				return value, keyInfo
			end
			function proxy.UpdateAsync(_: any, key: string, transform: any): ...any
				local function runLateTransform()
					local snap = raw.data[key]
					local ok, lateRes = pcall(invokeTransform, transform, snap)
					if not ok or lateRes[1] == nil then return end
					recordPrior(raw, storeDesc.ordered, key)
					local conflict = false
					local out = table.pack(raw:UpdateAsync(key, function(): ...any
						if raw.data[key] ~= snap then
							conflict = true
							return nil
						end
						return table.unpack(lateRes, 1, lateRes.n)
					end))
					if not conflict and out[1] ~= nil then
						if not storeDesc.ordered then
							cache[key] = { at = s.now, value = clone(out[1]), info = out[2] }
						end
						world:trace(`ds retransform commit {storeDesc.name}/{key} on {server.name}`)
						commit(key)
					end
				end
				return callOpts("UpdateAsync", { mutates = true }, function(): ...any
					local retransformAfter = world:shouldFault(
						server,
						"DataStoreService",
						"UpdateAsync",
						"DataStoreService.UpdateAsync",
						"retransform"
					)
					for attempt = 1, ATTEMPTS do
						local snapshot = raw.data[key]
						local results = invokeTransform(transform, snapshot)
						if
							retransformAfter
							and attempt == 1
							and world.mode == "random"
							and world.scheduler:chance(0.5, "ds.retransform.pre")
						then
							retransformAfter = false
							world:trace(`ds retransform (retry) {storeDesc.name}/{key} on {server.name}`)
							results = invokeTransform(transform, snapshot)
						end
						if results[1] == nil then return nil end
						local inflightEntry: any = nil
						if
							server ~= nil
							and world.scheduler.current == server
							and server.inflight ~= nil
							and not world.instant
						then
							inflightEntry = {
								key = "DataStoreService.UpdateAsync",
								run = function()
									if raw.data[key] ~= snapshot then return end
									recordPrior(raw, storeDesc.ordered, key)
									local out = table.pack(
										raw:UpdateAsync(
											key,
											function(): ...any return table.unpack(results, 1, results.n) end
										)
									)
									if out[1] ~= nil then
										if not storeDesc.ordered then
											cache[key] = { at = s.now, value = clone(out[1]), info = out[2] }
										end
										commit(key)
									end
								end,
							}
							table.insert(server.inflight, inflightEntry)
						end
						world:pause("DataStoreService")
						if inflightEntry ~= nil and server ~= nil and server.inflight ~= nil then
							local idx = table.find(server.inflight, inflightEntry)
							if idx ~= nil then table.remove(server.inflight, idx) end
						end
						local conflict = false
						local out = table.pack(raw:UpdateAsync(key, function(): ...any
							if raw.data[key] ~= snapshot then
								conflict = true
								return nil
							end
							recordPrior(raw, storeDesc.ordered, key)
							return table.unpack(results, 1, results.n)
						end))
						if not conflict then
							if out[1] ~= nil then
								cache[key] = { at = s.now, value = clone(out[1]), info = out[2] }
								commit(key)
							end
							if retransformAfter then
								local delay = world:lateDelay()
								world:trace(`ds retransform (late) {storeDesc.name}/{key} scheduled on {server.name}`)
								world:detach(delay, runLateTransform)
							end
							return table.unpack(out, 1, out.n)
						end
						world:trace(`ds conflict {storeDesc.name}/{key} on {server.name}`)
					end
					error("UpdateAsync: too much contention on the key", 0)
				end)
			end
			function proxy.RemoveAsync(_: any, key: string): ...any
				return callOpts("RemoveAsync", { mutates = true }, function(): ...any
					local had = raw.data[key] ~= nil
					if had then recordPrior(raw, storeDesc.ordered, key) end
					local out = table.pack(raw:RemoveAsync(key))
					cache[key] = { at = s.now, value = nil, info = nil }
					if had then commit(key) end
					return table.unpack(out, 1, out.n)
				end)
			end
			for _, method in { "SetAsync", "IncrementAsync" } do
				if types[method] then
					proxy[method] = function(_: any, key: string, ...: any): ...any
						return callOpts(method, { mutates = true }, function(...: any): ...any
							recordPrior(raw, storeDesc.ordered, key)
							local out = table.pack(raw[method](raw, key, ...))
							if not storeDesc.ordered then
								local row = raw.data[key]
								cache[key] = {
									at = s.now,
									value = if row then clone(row.value) else nil,
									info = info(row, clone),
								}
							end
							commit(key)
							return table.unpack(out, 1, out.n)
						end, ...)
					end
				end
			end
			if types.GetVersionAsync then
				function proxy.GetVersionAsync(_: any, ...: any): ...any
					return call("GetVersionAsync", raw.GetVersionAsync, raw, ...)
				end
			end
			if types.RemoveVersionAsync then
				function proxy.RemoveVersionAsync(_: any, key: string, version: string): ...any
					return callOpts("RemoveVersionAsync", { mutates = true }, function(): ...any
						local before = raw.data[key]
						if before ~= nil then recordPrior(raw, storeDesc.ordered, key) end
						local out = table.pack(raw:RemoveVersionAsync(key, version))
						local after = raw.data[key]
						if before ~= after then
							cache[key] = if after ~= nil
								then { at = s.now, value = clone(after.value), info = info(after, clone) }
								else { at = s.now, value = nil, info = nil }
							commit(key)
						end
						return table.unpack(out, 1, out.n)
					end)
				end
			end
			for _, method in { "ListVersionsAsync", "ListKeysAsync", "GetSortedAsync" } do
				if types[method] and raw[method] ~= nil then
					proxy[method] = function(_: any, ...: any): any
						local qArgs = table.pack(...)
						local opts = if method == "ListKeysAsync" or method == "GetSortedAsync"
							then {
								stale = function(): (boolean, any)
									local allBucket = storeHist._all
									if allBucket == nil or #allBucket == 0 then return false, nil end
									local oldData = if world.mode == "random"
										then world.scheduler:pick(allBucket, "ds.stale.all")
										else allBucket[#allBucket]
									local saved = raw.data
									local savedVersions = raw.versions
									raw.data = oldData
									if savedVersions ~= nil then
										local filteredVersions: { [string]: any } = {}
										for k in oldData do
											if savedVersions[k] ~= nil then filteredVersions[k] = savedVersions[k] end
										end
										raw.versions = filteredVersions
									end
									local ok, res = pcall(raw[method], raw, table.unpack(qArgs, 1, qArgs.n))
									raw.data = saved
									raw.versions = savedVersions
									if not ok then error(res, 0) end
									return true, res
								end,
							}
							else nil
						return pages(callOpts(method, opts, raw[method], raw, ...))
					end
				end
			end
			return proxy
		end
		local function handle(raw: any, name: string, scope: string?, ordered: boolean): any
			local found = proxies[raw]
			if found == nil then
				found = wrap(raw, describe(raw, name, scope, ordered))
				proxies[raw] = found
			end
			return found
		end
		function facade.GetDataStore(_: any, name: string, scope: string?, _options: any?): any
			return handle(service.mock:GetDataStore(name, scope), name, scope, false)
		end
		function facade.GetGlobalDataStore(_: any): any
			return handle(service.mock:GetDataStore("_global", "global"), "_global", "global", false)
		end
		function facade.GetOrderedDataStore(_: any, name: string, scope: string?): any
			return handle(service.mock:GetOrderedDataStore(name, scope), name, scope, true)
		end
		function facade.ListDataStoresAsync(_: any, ...: any): any
			charge(TYPES.service.ListDataStoresAsync)
			return world:call(
				server,
				"DataStoreService",
				"ListDataStoresAsync",
				service.mock.ListDataStoresAsync,
				service.mock,
				...
			)
		end
		return facade
	end
	return service
end

local MemoryStore = {}

function MemoryStore.facade(service: any, world: any, server: any): any
	service._history = service._history or {}
	local function call(method: string, body: (...any) -> ...any, ...: any): ...any
		return world:call(server, "MemoryStoreService", method, body, ...)
	end
	local function callOpts(method: string, opts: any, body: (...any) -> ...any, ...: any): ...any
		return world:callOpts(server, "MemoryStoreService", method, opts, body, ...)
	end
	local function proxy(raw: any, methods: { string }, mutating: { [string]: boolean }?): any
		local p: any = setmetatable({}, { __index = raw })
		for _, method in methods do
			local opts = if mutating and mutating[method] then { mutates = true } else nil
			p[method] = function(_self: any, ...: any): ...any return callOpts(method, opts, raw[method], raw, ...) end
		end
		return p
	end
	local facade: any = {}
	local function mapOf(raw: any): any
		local mapHist: { [string]: { any } } = service._history[raw]
		if mapHist == nil then
			mapHist = {}
			service._history[raw] = mapHist
		end
		local function recordMapPrior(key: string)
			raw:prune(key)
			local cur = raw.data[key]
			local bucket = mapHist[key]
			if bucket == nil then
				bucket = {}
				mapHist[key] = bucket
			end
			pushHistory(
				bucket,
				if cur ~= nil
					then { value = deepCopy(cur.value), sortKey = cur.sortKey }
					else { value = nil, sortKey = nil }
			)
			local allBucket = mapHist._all
			if allBucket == nil then
				allBucket = {}
				mapHist._all = allBucket
			end
			pushHistory(allBucket, table.clone(raw.data))
		end
		local p = proxy(raw, { "GetSizeAsync" })
		function p.GetRangeAsync(_self: any, ...: any): any
			local rArgs = table.pack(...)
			return callOpts("GetRangeAsync", {
				stale = function(): (boolean, any)
					local allBucket = mapHist._all
					if allBucket == nil or #allBucket == 0 then return false, nil end
					local oldData = if world.mode == "random"
						then world.scheduler:pick(allBucket, "ms.stale.all")
						else allBucket[#allBucket]
					local saved = raw.data
					raw.data = table.clone(oldData)
					local ok, res = pcall(raw.GetRangeAsync, raw, table.unpack(rArgs, 1, rArgs.n))
					raw.data = saved
					if not ok then error(res, 0) end
					return true, res
				end,
			}, raw.GetRangeAsync, raw, ...)
		end
		function p.GetAsync(_self: any, key: string): ...any
			return callOpts("GetAsync", {
				stale = function(): (boolean, any, any)
					local snap = pickStaleSnapshot(world, mapHist[key], "ms.stale")
					if snap == nil then return false, nil, nil end
					return true, deepCopy(snap.value), snap.sortKey
				end,
			}, raw.GetAsync, raw, key)
		end
		function p.SetAsync(_self: any, key: string, value: any, expiry: number, sortKey: any): boolean
			return callOpts("SetAsync", { mutates = true }, function(): boolean
				recordMapPrior(key)
				return raw:SetAsync(key, value, expiry, sortKey)
			end)
		end
		function p.RemoveAsync(_self: any, key: string)
			return callOpts("RemoveAsync", { mutates = true }, function()
				recordMapPrior(key)
				raw:RemoveAsync(key)
			end)
		end
		function p.ListItemsAsync(_self: any, count: number): any
			local res = call("ListItemsAsync", raw.ListItemsAsync, raw, count)
			local advance = res.AdvanceToNextPageAsync
			res.AdvanceToNextPageAsync = function(pg: any) return call("AdvanceToNextPageAsync", advance, pg) end
			return res
		end
		function p.UpdateAsync(_self: any, key: string, fn: any, expiry: number): ...any
			local function runLateTransform()
				raw:prune(key)
				local snap = raw.data[key]
				local ok, lateRes = pcall(
					world.transform,
					world,
					fn,
					if snap then deepCopy(snap.value) else nil,
					if snap then snap.sortKey else nil
				)
				if not ok or lateRes[1] == nil then return end
				recordMapPrior(key)
				raw:UpdateAsync(key, function(): ...any
					if raw.data[key] ~= snap then return nil end
					return lateRes[1], lateRes[2]
				end, expiry)
				world:trace(`ms retransform commit {key} on {server.name}`)
			end
			return callOpts("UpdateAsync", { mutates = true }, function(): ...any
				local retransformAfter = world:shouldFault(
					server,
					"MemoryStoreService",
					"UpdateAsync",
					"MemoryStoreService.UpdateAsync",
					"retransform"
				)
				for attempt = 1, 10 do
					raw:prune(key)
					local snapshot = raw.data[key]
					local results = world:transform(
						fn,
						if snapshot then deepCopy(snapshot.value) else nil,
						if snapshot then snapshot.sortKey else nil
					)
					if
						retransformAfter
						and attempt == 1
						and world.mode == "random"
						and world.scheduler:chance(0.5, "ms.retransform.pre")
					then
						retransformAfter = false
						world:trace(`ms retransform (retry) {key} on {server.name}`)
						results = world:transform(
							fn,
							if snapshot then deepCopy(snapshot.value) else nil,
							if snapshot then snapshot.sortKey else nil
						)
					end
					if results[1] == nil then return nil end
					local inflightEntry: any = nil
					if
						server ~= nil
						and world.scheduler.current == server
						and server.inflight ~= nil
						and not world.instant
					then
						inflightEntry = {
							key = "MemoryStoreService.UpdateAsync",
							run = function()
								if raw.data[key] ~= snapshot then return end
								recordMapPrior(key)
								raw:UpdateAsync(key, function(): ...any return results[1], results[2] end, expiry)
							end,
						}
						table.insert(server.inflight, inflightEntry)
					end
					world:pause("MemoryStoreService")
					if inflightEntry ~= nil and server ~= nil and server.inflight ~= nil then
						local idx = table.find(server.inflight, inflightEntry)
						if idx ~= nil then table.remove(server.inflight, idx) end
					end
					local conflict = false
					local value, sortKey = raw:UpdateAsync(key, function(): ...any
						if raw.data[key] ~= snapshot then
							conflict = true
							return nil
						end
						recordMapPrior(key)
						return results[1], results[2]
					end, expiry)
					if not conflict then
						if retransformAfter then
							local delay = world:lateDelay()
							world:trace(`ms retransform (late) {key} scheduled on {server.name}`)
							world:detach(delay, runLateTransform)
						end
						return value, sortKey
					end
					world:trace(`ms conflict {key} on {server.name}`)
				end
				error("MemoryStore UpdateAsync: too much contention", 0)
			end)
		end
		return p
	end
	function facade.GetHashMap(_self: any, name: string): any return mapOf(service:GetHashMap(name)) end
	function facade.GetSortedMap(_self: any, name: string): any return mapOf(service:GetSortedMap(name)) end
	function facade.GetQueue(_self: any, name: string, invisibility: number?): any
		return proxy(
			service:GetQueue(name, invisibility),
			{ "AddAsync", "ReadAsync", "RemoveAsync", "GetSizeAsync" },
			{ AddAsync = true, RemoveAsync = true }
		)
	end
	return facade
end

function MemoryStore.new(clock: { now: number }?, options: { wait: ((seconds: number) -> ())? }?): any
	local service = MemoryStoreDouble.new(clock, options)
	service.facade = MemoryStore.facade
	return service
end

local Messaging = {}
local MSG_COPY: util.CopyOptions = {
	keepMetatables = false,
	map = function(value: any): (boolean, any)
		local kind = customTypeof(value)
		return if kind == "Instance" then true else kind ~= "table", if kind == "Instance" then nil else value
	end,
	overflow = table.clone,
}

function Messaging.new(world: any): any
	local s = world.scheduler
	local sizer = Http.new()
	local m: any = {
		topics = {},
		history = {},
		pending = {},
		partitions = {},
		publishCalls = 0,
		subscribeCalls = 0,
		auto = world.mode == "random",
		json = false,
		tableTopics = {},
		limit = 1024 :: number?,
		size = function(data: any): number return #sizer:JSONEncode(data) end,
	}

	local function partitioned(server: any): boolean return server ~= nil and (m.partitions[server] or -1) > s.now end
	function m.partitioned(_self: any, server: any): boolean return partitioned(server) end
	local function hand(slot: any, message: any)
		if slot.connected and not partitioned(slot.server) then
			local data = if message.json then sizer:JSONDecode(message.Data) else deepCopy(message.Data, MSG_COPY)
			world:dispatch(slot.server, slot.callback, { Data = data, Sent = message.Sent })
		end
	end
	local function route(message: any)
		for _, slot in table.clone(m.topics[message.topic] or {}) :: { any } do
			local faults = world.faults
			if s:chance(faults.drop, "ms.drop") then
				world:trace(`ms drop {message.topic} to {if slot.server then slot.server.name else "?"}`)
				continue
			end
			for _ = 1, if s:chance(faults.duplicate, "ms.duplicate") then 2 else 1 do
				slot.inflight = (slot.inflight or 0) + 1
				world.pendingCloud = (world.pendingCloud or 0) + 1
				s:after(world:latency("delivery"), slot.server, function()
					if (slot.inflight or 0) > 0 then
						slot.inflight -= 1
						world.pendingCloud = math.max(0, (world.pendingCloud or 0) - 1)
					end
					hand(slot, message)
				end)
			end
		end
	end

	local function subscribe(server: any, topic: string, callback: (any) -> ()): any
		m.subscribeCalls += 1
		return world:call(server, "MessagingService", "SubscribeAsync", function(): any
			if partitioned(server) then error("MessagingService: connection lost", 0) end
			local slot = { callback = callback, connected = true, server = server, topic = topic, inflight = 0 }
			m.topics[topic] = m.topics[topic] or {}
			table.insert(m.topics[topic], slot)
			return {
				Connected = true,
				Disconnect = function(connection: any)
					slot.connected = false
					if type(connection) == "table" then connection.Connected = false end
					local list = m.topics[topic]
					local index = table.find(list, slot)
					if index then table.remove(list, index) end
				end,
			}
		end)
	end

	local function publish(server: any, topic: string, data: any)
		m.publishCalls += 1
		local limit = m.limit
		if limit ~= nil and server ~= nil then
			local size = m.size(data)
			if size > limit then error(`MessagingService: message is {size} characters; the limit is {limit}`, 0) end
		end
		world:call(server, "MessagingService", "PublishAsync", function()
			if partitioned(server) then error("MessagingService: connection lost", 0) end
			local message = {
				topic = topic,
				Data = deepCopy(data, MSG_COPY),
				Sent = world:unix(),
				from = server,
				json = nil :: boolean?,
			}
			if m.json and type(data) ~= "buffer" then
				m.tableTopics[topic] = true
				message.Data = sizer:JSONEncode(data)
				message.json = true
			end
			table.insert(m.history, message)
			if m.auto then
				route(message)
			else
				table.insert(m.pending, message)
			end
		end)
	end

	function m.facade(_: any, server: any): any
		return {
			SubscribeAsync = function(_self: any, topic: string, callback: (any) -> ()): any
				return subscribe(server, topic, callback)
			end,
			PublishAsync = function(_self: any, topic: string, data: any) publish(server, topic, data) end,
		}
	end
	m.service = m:facade(nil)

	function m.deliver(_: any, message: any)
		for _, slot in table.clone(m.topics[message.topic] or {}) :: { any } do
			hand(slot, message)
		end
	end
	function m.pump(_: any, index: number?, drop: boolean?)
		local message = table.remove(m.pending, index or 1)
		if message and not drop then m:deliver(message) end
	end
	function m.drain(_: any)
		while #m.pending > 0 do
			m:pump()
		end
	end
	function m.subscriptions(_: any, server: any?): number
		local n = 0
		for _, slots in m.topics do
			for _, slot in slots do
				if slot.connected and (server == nil or slot.server == server) then
					n += 1
				end
			end
		end
		return n
	end
	function m.drop(_: any, server: any)
		for _, slots in m.topics do
			for i = #slots, 1, -1 do
				if slots[i].server == server then
					local inf = slots[i].inflight or 0
					if inf > 0 then
						slots[i].inflight = 0
						world.pendingCloud = math.max(0, (world.pendingCloud or 0) - inf)
					end
					slots[i].connected = false
					table.remove(slots, i)
				end
			end
		end
	end
	function m.partition(_: any, server: any, seconds: number)
		m.partitions[server] = s.now + seconds
		world:trace(`partition {server.name} {seconds}`)
	end
	function m.heal(_: any)
		table.clear(m.partitions)
		world:trace("heal")
	end
	return m
end

local Remotes = {}

local function translate(value: any, targetEnv: any?): any
	if targetEnv == nil or rawget(value, "_env") == targetEnv then return value end
	if targetEnv._mirrorOf ~= nil and targetEnv._mirrorOf[value] ~= nil then return targetEnv._mirrorOf[value] end
	if targetEnv._sourceOf ~= nil and targetEnv._sourceOf[value] ~= nil then return targetEnv._sourceOf[value] end
	local srcEnv = rawget(value, "_env")
	if srcEnv ~= nil and srcEnv._sourceOf ~= nil and srcEnv._sourceOf[value] ~= nil then
		local srvInst = srcEnv._sourceOf[value]
		if rawget(srvInst, "_env") == targetEnv then return srvInst end
		if targetEnv._mirrorOf ~= nil and targetEnv._mirrorOf[srvInst] ~= nil then
			return targetEnv._mirrorOf[srvInst]
		end
	end
	local mountPath = rawget(value, "_mountPath")
	if mountPath ~= nil and targetEnv._mountedByPath ~= nil and targetEnv._mountedByPath[mountPath] ~= nil then
		return targetEnv._mountedByPath[mountPath]
	end
	if targetEnv.game ~= nil then
		local path: { string }, cur: any = {}, value
		while cur ~= nil and cur._props ~= nil and cur._props.ClassName ~= "DataModel" do
			table.insert(path, tostring(cur._props.Name))
			cur = rawget(cur, "_parent")
		end
		if cur ~= nil and cur._props ~= nil and cur._props.ClassName == "DataModel" then
			local top = path[#path]
			if top == "ServerStorage" or top == "ServerScriptService" then return nil end
			if #path > 1 and (top == "Workspace" or top == "ReplicatedStorage" or top == "Players") then return nil end
			local node: any = targetEnv.game
			for i = #path, 1, -1 do
				node = if node then node:FindFirstChild(path[i]) else nil
			end
			return node
		end
	end
	return nil
end

local function copyRemote(value: any, targetEnv: any?, translateInstances: boolean?): any
	return deepCopy(value, {
		keepMetatables = false,
		map = function(v: any): (boolean, any)
			local kind = customTypeof(v)
			if kind == "Instance" then return true, if translateInstances then translate(v, targetEnv) else v end
			return kind ~= "table", v
		end,
		overflow = table.clone,
	})
end

local function pack(...: any): { n: number, [number]: any }
	local args = table.pack(...)
	for i = 1, args.n do
		args[i] = copyRemote(args[i], nil, false)
	end
	return args
end

local function translateArgs(args: { n: number, [number]: any }, targetEnv: any?): { n: number, [number]: any }
	local out = { n = args.n }
	for i = 1, args.n do
		out[i] = copyRemote(args[i], targetEnv, targetEnv ~= nil)
	end
	return out
end

local function serverPlayerFor(server: any, client: any): any
	local sEnv = server._env
	if sEnv ~= nil and sEnv.Players ~= nil then
		local uid = client.player.UserId
		return sEnv.Players:GetPlayerByUserId(uid) or sEnv:addPlayer(uid, client.player.Name)
	end
	return client.player
end

local function deliverRemotePacket(net: any, server: any, packet: any)
	if packet.to == "server" then
		if server.state == "up" and not packet.from.gone then
			local ch = net.remotes[packet.channel]
			if ch ~= nil and ch.OnServerEvent ~= nil then
				local args = translateArgs(packet.args, server._env)
				ch.OnServerEvent:Fire(serverPlayerFor(server, packet.from), table.unpack(args, 1, args.n))
			end
		end
	elseif not packet.to.gone then
		local ch = packet.to.remotes[packet.channel]
		if ch ~= nil and ch.OnClientEvent ~= nil then
			local args = translateArgs(packet.args, packet.to._env)
			ch.OnClientEvent:Fire(table.unpack(args, 1, args.n))
		end
	end
end

local function sortPackets(a: any, b: any): boolean
	if a.at ~= b.at then
		return a.at < b.at
	elseif a.peer ~= b.peer then
		return a.peer < b.peer
	end
	return a.seq < b.seq
end

local function flushRemoteQueue(net: any, server: any, now: number)
	local limit = now + util.EPSILON
	local anyDue = false
	for _, packet in net.queue do
		if packet.at <= limit then
			anyDue = true
			break
		end
	end
	if not anyDue then return end
	local due, kept = {}, {}
	for _, packet in net.queue do
		table.insert(if packet.at <= limit then due else kept, packet)
	end
	net.queue = kept
	table.sort(due, sortPackets)
	for _, packet in due do
		deliverRemotePacket(net, server, packet)
	end
end

local function haltClientPeer(scheduler: any, client: any)
	client.gone = true
	if client.stopFrame ~= nil then (client.stopFrame :: () -> ())() end
	scheduler:crash(client)
end

function Remotes.new(world: any, server: any): any
	local s = world.scheduler
	local net: any = {
		server = server,
		clients = {},
		queue = {},
		seq = 0,
		last = {},
		sent = 0,
		lost = 0,
		unreliableChannels = { unreliable = true },
	}
	local byPlayer, byUserId: { [number]: any } = {}, {}
	local nextClientIndex = 0
	local pendingCallers: { [thread]: any } = {}

	local function wakePendingCallers(targetClient: any?)
		for caller, rpcClient in pendingCallers do
			if targetClient == nil or rpcClient == targetClient then
				pendingCallers[caller] = nil
				if coroutine.status(caller) == "suspended" then s:resume(caller) end
			end
		end
	end

	local function invokeOnPeer(targetPeer: any, client: any, fn: () -> ...any): (boolean, any)
		if world.instant or not s:running() then
			local res = pack(pcall(fn))
			return res[1], res
		end
		local caller = coroutine.running()
		local done = false
		local res: any = nil
		pendingCallers[caller] = client
		s:spawn(targetPeer, function()
			res = pack(pcall(fn))
			done = true
			pendingCallers[caller] = nil
			if coroutine.status(caller) == "suspended" then s:resume(caller) end
		end)
		if not done then
			s:park()
			pendingCallers[caller] = nil
		end
		if res == nil then return false, pack(false, "peer disconnected") end
		return res[1], res
	end

	local function findClient(player: any): any
		if player == nil then return nil end
		return byPlayer[player]
			or (if type(player) == "table" and type(player.UserId) == "number" then byUserId[player.UserId] else nil)
	end

	local function ensureChannel(channel: string, unreliable: boolean?)
		if unreliable then net.unreliableChannels[channel] = true end
		local srvEntry = net.remotes[channel] or {}
		net.remotes[channel] = srvEntry
		if srvEntry.OnServerEvent == nil then
			srvEntry.OnServerEvent = world:signal(server, "spawn")
			srvEntry.FireClient = function(_self: any, player: any, ...: any)
				local client = findClient(player)
				if client ~= nil and not client.gone then net._send(server, client, channel, pack(...)) end
			end
			srvEntry.FireAllClients = function(_self: any, ...: any)
				local payload = pack(...)
				for _, client in net.clients do
					if not client.gone then net._send(server, client, channel, payload) end
				end
			end
		end
		for _, client in net.clients do
			local cliEntry = client.remotes[channel] or {}
			client.remotes[channel] = cliEntry
			if cliEntry.OnClientEvent == nil then
				cliEntry.OnClientEvent = world:signal(client, "spawn")
				cliEntry.FireServer = function(_self: any, ...: any)
					if not client.gone then net._send(client, "server", channel, pack(...)) end
				end
			end
		end
	end

	local function ensureRpc(channel: string)
		local serverRpc = net.remotes[channel] or { OnServerInvoke = nil }
		net.remotes[channel] = serverRpc
		if serverRpc.InvokeClient == nil then
			function serverRpc.InvokeClient(_self: any, player: any, ...: any): ...any
				local client = findClient(player)
				if client == nil or client.gone then error("InvokeClient: player disconnected", 0) end
				local req = translateArgs(pack(...), client._env)
				world:pause("remotes")
				if client.gone or server.state ~= "up" then error("InvokeClient: peer disconnected", 0) end
				local clientRpc = client.remotes[channel]
				local cb = if clientRpc ~= nil then clientRpc.OnClientInvoke else nil
				if cb == nil then return nil end
				local ok, rawRes = invokeOnPeer(client, client, function() return cb(table.unpack(req, 1, req.n)) end)
				world:pause("remotes")
				if client.gone or server.state ~= "up" then error("InvokeClient: peer disconnected", 0) end
				if not ok then error(rawRes[2], 0) end
				local res = translateArgs(pack(table.unpack(rawRes, 2, rawRes.n)), server._env)
				return table.unpack(res, 1, res.n)
			end
		end
		for _, client in net.clients do
			local clientRpc = client.remotes[channel] or { OnClientInvoke = nil }
			client.remotes[channel] = clientRpc
			if clientRpc.InvokeServer == nil then
				function clientRpc.InvokeServer(_self: any, ...: any): ...any
					if client.gone or server.state ~= "up" then error("InvokeServer: peer disconnected", 0) end
					local req = translateArgs(pack(...), server._env)
					world:pause("remotes")
					if client.gone or server.state ~= "up" then error("InvokeServer: peer disconnected", 0) end
					local srvRpc = net.remotes[channel]
					local cb = if srvRpc ~= nil then srvRpc.OnServerInvoke else nil
					if cb == nil then return nil end
					local ok, rawRes = invokeOnPeer(
						server,
						client,
						function() return cb(serverPlayerFor(server, client), table.unpack(req, 1, req.n)) end
					)
					world:pause("remotes")
					if client.gone or server.state ~= "up" then error("InvokeServer: peer disconnected", 0) end
					if not ok then error(rawRes[2], 0) end
					local res = translateArgs(pack(table.unpack(rawRes, 2, rawRes.n)), client._env)
					return table.unpack(res, 1, res.n)
				end
			end
		end
	end

	function net._send(from: any, to: any, channel: string, args: any)
		local unreliable = net.unreliableChannels[channel] == true
		net.sent += 1
		if unreliable and s:chance(world.faults.drop, "net.drop") then
			net.lost += 1
			return
		end
		local at = s.now + world:latency("remotes")
		if not unreliable then
			local path = if to == "server" then from else to
			local key = `{path.index}{to == "server"}`
			at = math.max(at, net.last[key] or 0)
			net.last[key] = at
		end
		net.seq += 1
		table.insert(net.queue, {
			at = at,
			peer = if to == "server" then from.index else 0,
			seq = net.seq,
			from = from,
			to = to,
			channel = channel,
			args = args,
		})
		if world.instant and at <= s.now + util.EPSILON then net:flush() end
	end

	function net.flush(_: any) flushRemoteQueue(net, server, s.now) end
	if not world.instant and not world.coarse then world.scheduler:onFrame(function() net:flush() end, nil, true) end

	net.remotes = {}
	for _, channel in { "reliable", "unreliable" } do
		ensureChannel(channel, channel == "unreliable")
	end
	ensureRpc("rpc")
	server.host.remotes = net.remotes

	function net.channel(_: any, channel: string, unreliable: boolean?, client: any?): any
		ensureChannel(channel, unreliable)
		return if client ~= nil then client.remotes[channel] else net.remotes[channel]
	end

	function net.rpc(_: any, channel: string, client: any?): any
		ensureRpc(channel)
		return if client ~= nil then client.remotes[channel] else net.remotes[channel]
	end

	function net.client(_: any, userId: number, options: { skew: number? }?): any
		local existingClient = byUserId[userId]
		if existingClient ~= nil and not existingClient.gone then return existingClient end
		nextClientIndex += 1
		local clientSkew = if options ~= nil and options.skew ~= nil then options.skew else 0
		local client: any = {
			index = nextClientIndex,
			gone = false,
			skew = clientSkew,
			remotes = {},
			server = server,
			world = world,
		}
		client.name = `{server.name}/c{client.index}`
		function client.drift(c: any, delta: number)
			c.skew += delta
			world:trace(
				string.format(
					"clock drift %s %s%.2fs (skew=%.2fs)",
					c.name,
					if delta >= 0 then "+" else "",
					delta,
					c.skew
				)
			)
		end
		local existingPlayer = if server.players ~= nil and server.players.peers ~= nil
			then server.players.peers[userId]
			else nil
		client.player = existingPlayer or server:join(userId)
		byPlayer[client.player], byUserId[userId] = client, client
		table.insert(net.clients, client)
		for channel, srvCh in net.remotes do
			if srvCh.OnServerEvent ~= nil then ensureChannel(channel, net.unreliableChannels[channel]) end
			if srvCh.InvokeClient ~= nil then ensureRpc(channel) end
		end
		local hooks = if world.instant then world.coop.hooks else s:host(client)
		local stream = s:stream(`random/{client.name}`)
		client.run = RunService.new(world, client, true)
		if not world.instant and not world.coarse then
			client.stopFrame = s:onFrame(function(dt: number) RunService.step(client.run, dt, s.now) end, client, true)
		end
		client.host = {
			clock = hooks.clock,
			wait = hooks.wait,
			spawn = hooks.spawn,
			defer = hooks.defer,
			resume = hooks.resume,
			unixTime = function(): number return world:unix() + client.skew end,
			random = function(): number return stream:float() end,
			RunService = client.run,
			remotes = client.remotes,
		}
		world:trace(`client {client.name} joins as {userId}`)
		return client
	end

	function net.leave(_: any, client: any)
		if client.gone then return end
		haltClientPeer(s, client)
		wakePendingCallers(client)
		local idx = table.find(net.clients, client)
		if idx ~= nil then table.remove(net.clients, idx) end
		if client.player ~= nil and byPlayer[client.player] == client then byPlayer[client.player] = nil end
		local uid = if type(client.player) == "table" then client.player.UserId else nil
		if type(uid) == "number" and byUserId[uid] == client then byUserId[uid] = nil end
		if table.find(server.players.list, client.player) ~= nil then Players.leave(server, client.player) end
		world:trace(`client {client.name} leaves`)
	end

	function net.stop(_: any)
		table.clear(net.queue)
		for _, client in net.clients do
			if not client.gone then haltClientPeer(s, client) end
		end
		wakePendingCallers(nil)
		table.clear(net.clients)
		table.clear(byPlayer)
		table.clear(byUserId)
	end
	return net
end

return table.freeze({
	datastore = table.freeze(DataStore),
	memorystore = table.freeze(MemoryStore),
	messaging = table.freeze(Messaging),
	players = table.freeze(Players),
	remotes = table.freeze(Remotes),
	run_service = table.freeze(RunService),
})
