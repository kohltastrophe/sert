--!strict
-- `MemoryStoreService` double (`sert.doubles.MemoryStore`) providing `HashMap`, `SortedMap`, and `Queue` with
-- virtual expiry, visibility timeouts, write-race hooks, and fault injection. Values are deep-copied on read and write.
local DataStoreDouble = require("./datastore")
local util = require("../util")

local copy = util.copy

local Double = {}

-- Seconds a read queue item stays invisible when `GetQueue` is given no invisibilityTimeout (the engine's default).
local DEFAULT_INVISIBILITY = 30

local function rank(value: any): number
	return if type(value) == "number" then 1 elseif type(value) == "string" then 2 else 3
end
local function lessSortKey(aKey: any, bKey: any): boolean
	if rank(aKey) ~= rank(bKey) then return rank(aKey) < rank(bKey) end
	if aKey ~= bKey then return aKey < bKey end
	return false
end
local function less(a: any, b: any): boolean
	if a.sortKey ~= b.sortKey then return lessSortKey(a.sortKey, b.sortKey) end
	return (a.key or "") < (b.key or "")
end
local function aboveLower(lower: any, entry: any): boolean
	return if lower.key ~= nil then less(lower, entry) else lessSortKey(lower.sortKey, entry.sortKey)
end
local function belowUpper(entry: any, upper: any): boolean
	return if upper.key ~= nil then less(entry, upper) else lessSortKey(entry.sortKey, upper.sortKey)
end

local function createMap(service: any, name: string, sorted: boolean): any
	local identity = `{if sorted then "sorted" else "hash"}:{name}`
	if service.maps[identity] then return service.maps[identity] end
	local m: any = { data = {} }
	function m.prune(self: any, targetKey: string?)
		if targetKey ~= nil then
			local target = self.data[targetKey]
			if target ~= nil and target.expiry <= service.now then self.data[targetKey] = nil end
			return
		end
		for key, entry in self.data do
			if entry.expiry <= service.now then self.data[key] = nil end
		end
	end
	function m.GetAsync(self: any, key: string): ...any
		service:touch("GetAsync", false)
		self:prune(key)
		local entry = self.data[key]
		service:touch("GetAsync", true)
		if entry then return copy(entry.value), entry.sortKey end
		return nil
	end
	function m.SetAsync(self: any, key: string, value: any, expiry: number, sortKey: any): boolean
		service:touch("SetAsync", false)
		self:prune(key)
		local overwritten = self.data[key] ~= nil
		self.data[key] = { value = copy(value), expiry = service.now + expiry, sortKey = sortKey }
		service:touch("SetAsync", true)
		return overwritten
	end
	function m.RemoveAsync(self: any, key: string)
		service:touch("RemoveAsync", false)
		self.data[key] = nil
		service:touch("RemoveAsync", true)
	end
	function m.UpdateAsync(self: any, key: string, fn: (any, any) -> (any, any), expiry: number): ...any
		service:touch("UpdateAsync", false)
		self:prune(key)
		local function invoke(): ...any
			local old = self.data[key]
			return fn(if old then copy(old.value) else nil, if old then old.sortKey else nil)
		end
		local value, sortKey = invoke()
		local conflict: ((any, string) -> ())? = service.conflict
		if conflict then
			service.conflict = nil
			conflict(self, key)
			value, sortKey = invoke()
		end
		if value == nil then
			service:touch("UpdateAsync", true)
			return nil
		end
		self.data[key] = { value = copy(value), expiry = service.now + expiry, sortKey = sortKey }
		service:touch("UpdateAsync", true)
		return copy(value), sortKey
	end
	function m.entries(self: any): any
		self:prune()
		local entries = {}
		for key, entry in self.data do
			table.insert(entries, { key = key, value = copy(entry.value), sortKey = entry.sortKey })
		end
		table.sort(entries, less)
		return entries
	end
	function m.GetRangeAsync(self: any, direction: any, count: number, lower: any, upper: any): any
		service:touch("GetRangeAsync", false)
		local entries = self:entries()
		local result = {}
		local desc = direction == "Descending" or string.find(tostring(direction), "Descending", 1, true) ~= nil
		for i = 1, #entries do
			local entry = entries[if desc then #entries - i + 1 else i]
			if (lower == nil or aboveLower(lower, entry)) and (upper == nil or belowUpper(entry, upper)) then
				table.insert(result, entry)
				if #result == count then break end
			end
		end
		service:touch("GetRangeAsync", true)
		return result
	end
	function m.ListItemsAsync(self: any, count: number): any
		service:touch("ListItemsAsync", false)
		local entries = self:entries()
		local pages = DataStoreDouble.makePages(entries, count, function()
			service:touch("AdvanceToNextPageAsync", false)
			service:touch("AdvanceToNextPageAsync", true)
		end)
		service:touch("ListItemsAsync", true)
		return pages
	end
	function m.GetSizeAsync(self: any): number
		service:touch("GetSizeAsync", false)
		self:prune()
		local size = 0
		for _ in self.data do
			size += 1
		end
		service:touch("GetSizeAsync", true)
		return size
	end
	function m.evict(self: any, key: string?): string?
		self:prune()
		if key ~= nil then
			if self.data[key] == nil then return nil end
			self.data[key] = nil
			return key
		end
		local keys: { string } = {}
		for k in self.data do
			table.insert(keys, k)
		end
		if #keys == 0 then return nil end
		table.sort(keys)
		local victim = keys[1]
		self.data[victim] = nil
		return victim
	end
	service.maps[identity] = m
	return m
end

local function pruneQueue(q: any, now: number)
	local data = q.data
	local write = 1
	for read = 1, #data do
		local entry = data[read]
		if entry.expiry > now then
			if write ~= read then data[write] = entry end
			write += 1
		end
	end
	for idx = write, #data do
		data[idx] = nil
	end
	if q.receipts ~= nil then
		for id, receipt in q.receipts do
			if receipt.expires <= now then q.receipts[id] = nil end
		end
	end
end

local function createQueue(
	service: any,
	name: string,
	invisibilityTimeout: number?,
	longPoll: ((seconds: number) -> ())?
): any
	local invisibility = invisibilityTimeout or DEFAULT_INVISIBILITY
	local storage: any = service.queues[name]
	if not storage then
		storage = { data = {}, receipts = {}, sequence = 0 }
		service.queues[name] = storage
	end
	local q: any = { data = storage.data, receipts = storage.receipts }

	function q.prune(qself: any) pruneQueue(qself, service.now) end

	function q.AddAsync(qself: any, value: any, expiry: number, priority: number?)
		service:touch("AddAsync", false)
		qself:prune()
		storage.sequence += 1
		table.insert(qself.data, {
			value = copy(value),
			expiry = service.now + expiry,
			visible = service.now,
			priority = if priority ~= nil then priority else 0,
			order = storage.sequence,
		})
		service:touch("AddAsync", true)
	end
	function q.ReadAsync(qself: any, count: number, allOrNothing: boolean, timeout: number?): ...any
		service:touch("ReadAsync", false)
		local function collect(): { any }
			qself:prune()
			local available: { any } = {}
			for _, entry in qself.data do
				if entry.expiry > service.now and entry.visible <= service.now then table.insert(available, entry) end
			end
			table.sort(
				available,
				function(a: any, b: any): boolean
					return if a.priority == b.priority then a.order < b.order else a.priority > b.priority
				end
			)
			return available
		end
		local function short(available: { any }): boolean
			return #available == 0 or (allOrNothing and #available < count)
		end
		local available = collect()
		if short(available) then
			-- Long poll: look again every frame until enough items arrive or the timeout passes.
			local deadline = service.now + math.max(timeout or 0, 0)
			while short(available) and service.now < deadline do
				local before = service.now
				local poll = longPoll
				if poll ~= nil then
					poll(math.min(1 / 60, deadline - before))
				else
					service:step(deadline - before)
				end
				available = collect()
				if service.now <= before then break end
			end
			if short(available) then
				service:touch("ReadAsync", true)
				return {}, nil
			end
		end
		local values, entries = {}, {}
		storage.sequence += 1
		local id = `receipt:{storage.sequence}`
		for i = 1, math.min(count, #available) do
			local entry = available[i]
			entry.visible = service.now + invisibility
			entry.receipt = id
			table.insert(entries, entry)
			table.insert(values, copy(entry.value))
		end
		qself.receipts[id] = { entries = entries, expires = service.now + invisibility }
		service:touch("ReadAsync", true)
		return values, id
	end
	function q.RemoveAsync(qself: any, id: string)
		service:touch("RemoveAsync", false)
		local receipt = qself.receipts[id]
		if receipt and receipt.expires > service.now then
			for _, entry in receipt.entries do
				if entry.receipt == id then entry.expiry = service.now end
			end
		end
		qself.receipts[id] = nil
		qself:prune()
		service:touch("RemoveAsync", true)
	end
	function q.GetSizeAsync(qself: any, excludeInvisible: boolean): number
		service:touch("GetSizeAsync", false)
		qself:prune()
		local count = 0
		for _, entry in qself.data do
			if entry.expiry > service.now and (not excludeInvisible or entry.visible <= service.now) then
				count += 1
			end
		end
		service:touch("GetSizeAsync", true)
		return count
	end
	function q.evict(qself: any, index: number?): boolean
		qself:prune()
		if #qself.data == 0 then return false end
		table.remove(qself.data, math.clamp(index or 1, 1, #qself.data))
		return true
	end
	return q
end

function Double.new(clock: { now: number }?, options: { wait: ((seconds: number) -> ())? }?): any
	local service: any = { calls = {}, maps = {}, queues = {}, failures = {}, conflict = nil }
	local longPoll = if options ~= nil then options.wait else nil
	local source: any = clock
	if source == nil then
		service.now = 0
		source = service
	else
		setmetatable(service :: any, {
			__index = function(_self: any, key: any): any return if key == "now" then source.now else nil end,
		})
	end
	function service.step(_self: any, seconds: number)
		source.now += seconds
	end
	--- Values held and their raw bytes (buffers by length, strings by length), after expiry.
	function service.stored(self: any): { values: number, bytes: number }
		local values, bytes = 0, 0
		local function count(value: any)
			values += 1
			bytes += if type(value) == "buffer" then buffer.len(value) elseif type(value) == "string" then #value else 0
		end
		for _, m in self.maps do
			m:prune()
			for _, entry in m.data do
				count(entry.value)
			end
		end
		for _, storage in self.queues do
			for _, entry in storage.data do
				if entry.expiry > source.now then count(entry.value) end
			end
		end
		return { values = values, bytes = bytes }
	end
	function service.fail(self: any, method: string, message: string?, after: boolean?)
		table.insert(self.failures, { method = method, message = message, after = after == true })
	end
	function service.touch(self: any, method: string, after: boolean)
		if not after then self.calls[method] = (self.calls[method] or 0) + 1 end
		for index, fail in self.failures do
			if fail.method == method and fail.after == after then
				table.remove(self.failures, index)
				error(fail.message or `MemoryStore double: injected failure in {method}`, 0)
			end
		end
	end
	function service.GetHashMap(self: any, name: string): any return createMap(self, name, false) end
	function service.GetSortedMap(self: any, name: string): any return createMap(self, name, true) end
	function service.GetQueue(self: any, name: string, invisibilityTimeout: number?): any
		return createQueue(self, name, invisibilityTimeout, longPoll)
	end
	--- Evicts one key from a map or one item from a queue (before TTL expiry), returning a description of what was lost.
	function service.evict(self: any, name: string?, key: string?, pickFn: (({ any }) -> any)?): string?
		if name ~= nil then
			local m = self.maps[`hash:{name}`] or self.maps[`sorted:{name}`] or self.maps[name]
			if m ~= nil then
				local victim = m:evict(key)
				return if victim ~= nil then `{name}/{victim}` else nil
			end
			local q = self.queues[name]
			if q ~= nil then
				pruneQueue(q, self.now)
				if #q.data > 0 then
					table.remove(q.data, 1)
					return `queue:{name}`
				end
			end
			return nil
		end
		local candidates: { any } = {}
		local mapNames: { string } = {}
		for identity in self.maps do
			table.insert(mapNames, identity)
		end
		table.sort(mapNames)
		for _, identity in mapNames do
			local m = self.maps[identity]
			m:prune()
			if key ~= nil then
				if m.data[key] ~= nil then
					table.insert(candidates, { kind = "map", identity = identity, map = m, key = key })
				end
			else
				local keys: { string } = {}
				for k in m.data do
					table.insert(keys, k)
				end
				table.sort(keys)
				for _, k in keys do
					table.insert(candidates, { kind = "map", identity = identity, map = m, key = k })
				end
			end
		end
		if key == nil then
			local queueNames: { string } = {}
			for qname in self.queues do
				table.insert(queueNames, qname)
			end
			table.sort(queueNames)
			for _, qname in queueNames do
				local storage = self.queues[qname]
				pruneQueue(storage, self.now)
				if #storage.data > 0 then
					table.insert(candidates, { kind = "queue", name = qname, storage = storage })
				end
			end
		end
		if #candidates == 0 then return nil end
		local chosen = if pickFn ~= nil then pickFn(candidates) else candidates[1]
		if chosen.kind == "map" then
			chosen.map.data[chosen.key] = nil
			return `{chosen.identity}/{chosen.key}`
		end
		table.remove(chosen.storage.data, 1)
		return `queue:{chosen.name}`
	end
	--- Wipes all volatile maps and queues in MemoryStore.
	function service.flush(self: any)
		for _, m in self.maps do
			table.clear(m.data)
		end
		for _, storage in self.queues do
			table.clear(storage.data)
			table.clear(storage.receipts)
		end
	end
	return service
end

return Double
