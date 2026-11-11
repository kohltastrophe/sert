--!strict
-- Headless `MemoryStoreService` engine double separating `MemoryStoreHashMap`, `MemoryStoreSortedMap`, and `MemoryStoreQueue` with virtual TTLs, leases, quotas, and fault injection.

local DataStore = require("./datastore")
local serialize = require("./serialize")

local copy = serialize.cloneTree
local MemoryStore = {}

local DEFAULT_INVISIBILITY = 30
local DEFAULT_WAIT_CAP = 300
local MAX_EXPIRATION = 3888000
local MAX_KEY_BYTES = 128
local MAX_SORT_KEY_BYTES = 128
local MAX_ITEM_BYTES = 128 * 1024

local function checkMapName(where: string, name: any)
	if type(name) ~= "string" or #name == 0 or #name > 128 then
		error(`{where}: name must be a non-empty string up to 128 bytes`, 0)
	end
end

local function checkKey(where: string, key: any)
	if type(key) ~= "string" or #key == 0 or #key > MAX_KEY_BYTES or utf8.len(key) == nil then
		error(`{where}: key must be a valid non-empty UTF-8 string up to {MAX_KEY_BYTES} bytes`, 0)
	end
end

local function checkExpiration(where: string, expiry: any)
	if type(expiry) ~= "number" or expiry ~= expiry or expiry < 0 or expiry > MAX_EXPIRATION then
		error(`{where}: expiration must be a number in 0..{MAX_EXPIRATION}`, 0)
	end
end

local function checkSortKey(where: string, sortKey: any)
	if sortKey == nil then return end
	if type(sortKey) == "number" then
		if sortKey ~= sortKey or math.abs(sortKey) == math.huge then
			error(`{where}: numeric sortKey must be finite`, 0)
		end
		return
	elseif type(sortKey) == "string" then
		if #sortKey > MAX_SORT_KEY_BYTES or utf8.len(sortKey) == nil then
			error(`{where}: string sortKey must be valid UTF-8 up to {MAX_SORT_KEY_BYTES} bytes`, 0)
		end
		return
	end
	error(`{where}: sortKey must be nil, number, or string`, 0)
end

local function validateValue(where: string, value: any): any
	if value == nil then error(`{where}: value cannot be nil`, 0) end
	local cloned, _ = serialize.datastore(value, {
		maxBytes = MAX_ITEM_BYTES,
		label = "MemoryStore",
	})
	return cloned
end

local function invokeTransformNoYield(where: string, fn: any, ...: any): ...any
	if type(fn) ~= "function" then error(`{where}: transform function expected`, 0) end
	local co = coroutine.create(fn)
	local packed = table.pack(coroutine.resume(co, ...))
	if not packed[1] then error(packed[2], 0) end
	if coroutine.status(co) ~= "dead" then
		pcall(coroutine.close, co)
		error(`{where}: transform function cannot yield`, 0)
	end
	return table.unpack(packed, 2, packed.n)
end

-- `nil` sortKeys sort before numbers, which sort before strings; equal sortKeys break ties by `key`.
local function rank(value: any): number
	return if value == nil then 0 elseif type(value) == "number" then 1 elseif type(value) == "string" then 2 else 3
end

local function lessSortKey(aKey: any, bKey: any): boolean
	local ra, rb = rank(aKey), rank(bKey)
	if ra ~= rb then return ra < rb end
	if aKey ~= bKey then return aKey < bKey end
	return false
end

local function lessEntry(a: any, b: any): boolean
	if a.sortKey ~= b.sortKey then return lessSortKey(a.sortKey, b.sortKey) end
	return (a.key or "") < (b.key or "")
end

-- Bounds in `GetRangeAsync` may provide `{ key, sortKey }`, `{ sortKey }`, or `{ key }` alone.
local function aboveLower(lower: any, entry: any): boolean
	if lower.key ~= nil and lower.sortKey ~= nil then
		return lessEntry(lower, entry)
	elseif lower.sortKey ~= nil then
		return lessSortKey(lower.sortKey, entry.sortKey)
	elseif lower.key ~= nil then
		return lower.key < entry.key
	end
	return true
end

local function belowUpper(entry: any, upper: any): boolean
	if upper.key ~= nil and upper.sortKey ~= nil then
		return lessEntry(entry, upper)
	elseif upper.sortKey ~= nil then
		return lessSortKey(entry.sortKey, upper.sortKey)
	elseif upper.key ~= nil then
		return entry.key < upper.key
	end
	return true
end

local function pruneMapData(data: { [string]: any }, now: number, targetKey: string?)
	if targetKey ~= nil then
		local target = data[targetKey]
		if target ~= nil and target.expiry <= now then data[targetKey] = nil end
		return
	end
	for key, entry in data do
		if entry.expiry <= now then data[key] = nil end
	end
end

local function evictMapData(data: { [string]: any }, now: number, key: string?): string?
	pruneMapData(data, now, nil)
	if key ~= nil then
		if data[key] == nil then return nil end
		data[key] = nil
		return key
	end
	local keys: { string } = {}
	for k in data do
		table.insert(keys, k)
	end
	if #keys == 0 then return nil end
	table.sort(keys)
	local victim = keys[1]
	data[victim] = nil
	return victim
end

local function createHashMap(service: any, name: string): any
	checkMapName("MemoryStoreService:GetHashMap", name)
	local identity = `hash:{name}`
	if service.maps[identity] then return service.maps[identity] end
	local m: any = { data = {} }

	function m.prune(self: any, targetKey: string?) pruneMapData(self.data, service.now, targetKey) end
	function m.evict(self: any, key: string?): string? return evictMapData(self.data, service.now, key) end
	function m.entries(self: any): { any }
		self:prune()
		local entries = {}
		for key, entry in self.data do
			table.insert(entries, { key = key, value = copy(entry.value), sortKey = nil })
		end
		table.sort(entries, lessEntry)
		return entries
	end

	function m.GetAsync(self: any, key: string): any
		checkKey("MemoryStoreHashMap:GetAsync", key)
		service:touch("GetAsync", false)
		self:prune(key)
		local entry = self.data[key]
		service:touch("GetAsync", true)
		return if entry ~= nil then copy(entry.value) else nil
	end

	function m.SetAsync(self: any, key: string, value: any, expiry: number): boolean
		checkKey("MemoryStoreHashMap:SetAsync", key)
		checkExpiration("MemoryStoreHashMap:SetAsync", expiry)
		local cloned = validateValue("MemoryStoreHashMap:SetAsync", value)
		service:touch("SetAsync", false)
		self:prune(key)
		local overwritten = self.data[key] ~= nil
		self.data[key] = { value = cloned, expiry = service.now + expiry }
		service:touch("SetAsync", true)
		return overwritten
	end

	function m.RemoveAsync(self: any, key: string)
		checkKey("MemoryStoreHashMap:RemoveAsync", key)
		service:touch("RemoveAsync", false)
		self.data[key] = nil
		service:touch("RemoveAsync", true)
	end

	function m.UpdateAsync(self: any, key: string, fn: (any) -> any, expiry: number): any
		checkKey("MemoryStoreHashMap:UpdateAsync", key)
		checkExpiration("MemoryStoreHashMap:UpdateAsync", expiry)
		service:touch("UpdateAsync", false)
		self:prune(key)
		local function invoke(): any
			local old = self.data[key]
			return (invokeTransformNoYield("MemoryStoreHashMap:UpdateAsync", fn, if old then copy(old.value) else nil))
		end
		local value = invoke()
		local conflict: ((any, string) -> ())? = service.conflict
		if conflict ~= nil then
			service.conflict = nil
			conflict(self, key)
			value = invoke()
		end
		if value == nil then
			service:touch("UpdateAsync", true)
			return nil
		end
		local cloned = validateValue("MemoryStoreHashMap:UpdateAsync", value)
		self.data[key] = { value = cloned, expiry = service.now + expiry }
		service:touch("UpdateAsync", true)
		return copy(cloned)
	end

	function m.ListItemsAsync(self: any, count: number?): any
		local pageSize = if count ~= nil then count else 50
		if type(pageSize) ~= "number" or pageSize < 1 or pageSize > 200 or pageSize % 1 ~= 0 then
			error("MemoryStoreHashMap:ListItemsAsync: count must be an integer in 1..200", 0)
		end
		service:touch("ListItemsAsync", false)
		self:prune()
		local items: { { key: string, value: any } } = {}
		for key, entry in self.data do
			table.insert(items, { key = key, value = copy(entry.value) })
		end
		table.sort(
			items,
			function(a: { key: string, value: any }, b: { key: string, value: any }): boolean return a.key < b.key end
		)
		local pages = DataStore.makePages(items, pageSize, function()
			service:touch("AdvanceToNextPageAsync", false)
			service:touch("AdvanceToNextPageAsync", true)
		end)
		service:touch("ListItemsAsync", true)
		return pages
	end

	service.maps[identity] = m
	return m
end

local function createSortedMap(service: any, name: string): any
	checkMapName("MemoryStoreService:GetSortedMap", name)
	local identity = `sorted:{name}`
	if service.maps[identity] then return service.maps[identity] end
	local m: any = { data = {} }

	function m.prune(self: any, targetKey: string?) pruneMapData(self.data, service.now, targetKey) end
	function m.evict(self: any, key: string?): string? return evictMapData(self.data, service.now, key) end

	function m.GetAsync(self: any, key: string): ...any
		checkKey("MemoryStoreSortedMap:GetAsync", key)
		service:touch("GetAsync", false)
		self:prune(key)
		local entry = self.data[key]
		service:touch("GetAsync", true)
		if entry ~= nil then return copy(entry.value), entry.sortKey end
		return nil, nil
	end

	function m.SetAsync(self: any, key: string, value: any, expiry: number, sortKey: any?): boolean
		checkKey("MemoryStoreSortedMap:SetAsync", key)
		checkExpiration("MemoryStoreSortedMap:SetAsync", expiry)
		checkSortKey("MemoryStoreSortedMap:SetAsync", sortKey)
		local cloned = validateValue("MemoryStoreSortedMap:SetAsync", value)
		service:touch("SetAsync", false)
		self:prune(key)
		local overwritten = self.data[key] ~= nil
		local normSort = if type(sortKey) == "number" and sortKey == 0 then 0 else sortKey
		self.data[key] = { value = cloned, expiry = service.now + expiry, sortKey = normSort }
		service:touch("SetAsync", true)
		return overwritten
	end

	function m.RemoveAsync(self: any, key: string)
		checkKey("MemoryStoreSortedMap:RemoveAsync", key)
		service:touch("RemoveAsync", false)
		self.data[key] = nil
		service:touch("RemoveAsync", true)
	end

	function m.UpdateAsync(self: any, key: string, fn: (any, any) -> (any, any), expiry: number): ...any
		checkKey("MemoryStoreSortedMap:UpdateAsync", key)
		checkExpiration("MemoryStoreSortedMap:UpdateAsync", expiry)
		service:touch("UpdateAsync", false)
		self:prune(key)
		local function invoke(): (any, any)
			local old = self.data[key]
			return invokeTransformNoYield(
				"MemoryStoreSortedMap:UpdateAsync",
				fn,
				if old then copy(old.value) else nil,
				if old then old.sortKey else nil
			)
		end
		local value, sortKey = invoke()
		local conflict: ((any, string) -> ())? = service.conflict
		if conflict ~= nil then
			service.conflict = nil
			conflict(self, key)
			value, sortKey = invoke()
		end
		if value == nil then
			service:touch("UpdateAsync", true)
			return nil, nil
		end
		checkSortKey("MemoryStoreSortedMap:UpdateAsync", sortKey)
		local cloned = validateValue("MemoryStoreSortedMap:UpdateAsync", value)
		local normSort = if type(sortKey) == "number" and sortKey == 0 then 0 else sortKey
		self.data[key] = { value = cloned, expiry = service.now + expiry, sortKey = normSort }
		service:touch("UpdateAsync", true)
		return copy(cloned), normSort
	end

	function m.entries(self: any): { any }
		self:prune()
		local entries = {}
		for key, entry in self.data do
			table.insert(entries, { key = key, value = copy(entry.value), sortKey = entry.sortKey })
		end
		table.sort(entries, lessEntry)
		return entries
	end

	function m.GetRangeAsync(self: any, direction: any, count: number, lower: any?, upper: any?): { any }
		if type(count) ~= "number" or count < 1 or count > 200 or count % 1 ~= 0 then
			error("MemoryStoreSortedMap:GetRangeAsync: count must be an integer in 1..200", 0)
		end
		if lower ~= nil and type(lower) ~= "table" then
			error("MemoryStoreSortedMap:GetRangeAsync: exclusiveLowerBound must be a table", 0)
		end
		if upper ~= nil and type(upper) ~= "table" then
			error("MemoryStoreSortedMap:GetRangeAsync: exclusiveUpperBound must be a table", 0)
		end
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
	checkMapName("MemoryStoreService:GetQueue", name)
	local invisibility = if invisibilityTimeout ~= nil then invisibilityTimeout else DEFAULT_INVISIBILITY
	if type(invisibility) ~= "number" or invisibility < 0 then
		error("MemoryStoreService:GetQueue: invisibilityTimeout must be non-negative", 0)
	end
	local storage: any = service.queues[name]
	if not storage then
		storage = { data = {}, receipts = {}, sequence = 0 }
		service.queues[name] = storage
	end
	local q: any = { data = storage.data, receipts = storage.receipts }

	function q.prune(qself: any) pruneQueue(qself, service.now) end

	function q.AddAsync(qself: any, value: any, expiry: number, priority: number?)
		checkExpiration("MemoryStoreQueue:AddAsync", expiry)
		if
			priority ~= nil and (type(priority) ~= "number" or priority ~= priority or math.abs(priority) == math.huge)
		then
			error("MemoryStoreQueue:AddAsync: priority must be a finite number", 0)
		end
		local cloned = validateValue("MemoryStoreQueue:AddAsync", value)
		service:touch("AddAsync", false)
		qself:prune()
		storage.sequence += 1
		table.insert(qself.data, {
			value = cloned,
			expiry = service.now + expiry,
			visible = service.now,
			priority = if priority ~= nil then priority else 0,
			order = storage.sequence,
		})
		service:touch("AddAsync", true)
	end

	function q.ReadAsync(qself: any, count: number, allOrNothing: boolean?, waitTimeout: number?): ...any
		if type(count) ~= "number" or count < 1 or count > 200 or count % 1 ~= 0 then
			error("MemoryStoreQueue:ReadAsync: count must be an integer in 1..200", 0)
		end
		local mustHaveAll = allOrNothing == true
		-- Roblox defaults `waitTimeout` to `-1` (wait until items arrive); `0` performs an immediate non-blocking poll.
		local effectiveWait = if waitTimeout == nil or waitTimeout < 0 then DEFAULT_WAIT_CAP else waitTimeout
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

		local function short(available: { any }): boolean return #available == 0 or (mustHaveAll and #available < count) end

		local available = collect()
		if short(available) then
			local deadline = service.now + effectiveWait
			while short(available) and service.now < deadline do
				local before = service.now
				local poll = longPoll
				if poll ~= nil then
					poll(math.min(1 / 60, deadline - before))
				else
					-- Without an external scheduler advancing concurrent producers, only advance if an invisible item can become visible before `deadline`.
					local nextVisible: number? = nil
					for _, entry in qself.data do
						if entry.expiry > before and entry.visible > before and entry.visible < entry.expiry then
							if nextVisible == nil or entry.visible < nextVisible then nextVisible = entry.visible end
						end
					end
					if nextVisible ~= nil and nextVisible <= deadline then
						service:step(nextVisible - before)
					else
						if waitTimeout ~= nil and waitTimeout > 0 then service:step(deadline - before) end
						break
					end
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

	function q.GetSizeAsync(qself: any, excludeInvisible: boolean?): number
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

--- Creates a headless `MemoryStoreService` double.
function MemoryStore.new(clock: { now: number }?, options: { wait: ((seconds: number) -> ())? }?): any
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

	function service.GetHashMap(self: any, name: string): any return createHashMap(self, name) end
	function service.GetSortedMap(self: any, name: string): any return createSortedMap(self, name) end
	function service.GetQueue(self: any, name: string, invisibilityTimeout: number?): any
		return createQueue(self, name, invisibilityTimeout, longPoll)
	end

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

return table.freeze(MemoryStore)
