--!strict
-- Headless `DataStoreService` and `OrderedDataStore` engine double with JSON tree cloning, quotas, request budgets, and fault injection.

local Datatypes = require("./datatypes")
local Rng = require("../core/rng")
local serialize = require("./serialize")

local copy = serialize.cloneTree
local DataStore = {}

local NAME_LIMIT, KEY_LIMIT = 50, 50
local MAX_USER_IDS, MAX_METADATA_BYTES = 4, 300
local MAX_VALUE, UNMODELLED = 4 * 1024 * 1024, 1000000
DataStore.MAX_VALUE, DataStore.UNMODELLED = MAX_VALUE, UNMODELLED
DataStore.copy = copy

local REQUEST_TYPES: { [string]: { [string]: { string } } } = {
	standard = {
		GetAsync = { "StandardRead" },
		SetAsync = { "StandardWrite" },
		IncrementAsync = { "StandardWrite" },
		UpdateAsync = { "StandardRead", "StandardWrite" },
		RemoveAsync = { "StandardRemove" },
		GetVersionAsync = { "StandardRead" },
		ListVersionsAsync = { "StandardList" },
		ListKeysAsync = { "StandardList" },
		RemoveVersionAsync = { "RemoveVersionAsync" },
	},
	ordered = {
		GetAsync = { "OrderedRead" },
		SetAsync = { "OrderedWrite" },
		IncrementAsync = { "OrderedWrite" },
		UpdateAsync = { "OrderedRead", "OrderedWrite" },
		RemoveAsync = { "OrderedRemove" },
		GetSortedAsync = { "OrderedList" },
	},
	service = {
		ListDataStoresAsync = { "StandardList" },
	},
}
DataStore.REQUEST_TYPES = REQUEST_TYPES

local function typeName(requestType: any): string
	local text = tostring(requestType)
	return string.match(text, "([%w_]+)$") or text
end

export type Budget = {
	rows: { [string]: any },
	set: (self: Budget, requestType: any, units: number?, perMinute: number?) -> (),
	remaining: (self: Budget, requestType: any) -> number?,
	charge: (self: Budget, types: { string }) -> string?,
}

--- Creates a per-request-type token bucket driven by `clock()` (in seconds).
function DataStore.budget(clock: () -> number, units: (number | () -> number?)?): Budget
	local rows: { [string]: any } = {}
	local function current(name: string): any
		local row, now = rows[name], clock()
		if row == nil then
			local start = if type(units) == "function" then units() else units
			if start == nil then return nil end
			row = { units = start, perMinute = start, max = start, at = now }
			rows[name] = row
		elseif row == false then
			return nil
		end
		row.units = math.min(row.max, row.units + math.max(0, now - row.at) * row.perMinute / 60)
		row.at = now
		return row
	end
	local budget: any = { rows = rows }
	function budget.set(_: any, requestType: any, count: number?, perMinute: number?)
		local rate = perMinute or count or 0
		rows[typeName(requestType)] = if count == nil
			then false
			else { units = count, perMinute = rate, max = math.max(count, rate), at = clock() }
	end
	function budget.remaining(_: any, requestType: any): number?
		local row = current(typeName(requestType))
		return if row == nil then nil else math.floor(row.units)
	end
	function budget.charge(_: any, types: { string }): string?
		local counts: { [string]: number } = {}
		for _, name in types do
			local need = (counts[name] or 0) + 1
			counts[name] = need
			local row = current(name)
			if row ~= nil and row.units < need then return name end
		end
		for name, need in counts do
			local row = current(name)
			if row ~= nil then
				row.units -= need
			end
		end
		return nil
	end
	return budget
end

local function checkName(what: string, name: any)
	if type(name) ~= "string" then
		error(`{what} must be a string`, 0)
	elseif #name == 0 then
		error(`{what} can't be empty.`, 0)
	elseif #name > NAME_LIMIT then
		error(`{what} exceeds the {NAME_LIMIT} character limit.`, 0)
	end
end

local function checkKey(key: any)
	if type(key) ~= "string" and type(key) ~= "number" then error("101: Key name must be a string.", 0) end
	local text = tostring(key)
	if #text == 0 then
		error("101: Key name can't be empty.", 0)
	elseif #text > KEY_LIMIT then
		error(`102: Key name exceeds the {KEY_LIMIT} character limit.`, 0)
	end
end

local function validateUserIds(userIds: any): { number }
	if userIds == nil then return {} end
	if type(userIds) ~= "table" or Datatypes.typeof(userIds) ~= "table" or getmetatable(userIds) ~= nil then
		error("103: DataStore userIds must be a plain array of integer UserIds.", 0)
	end
	local count, maxInt = 0, 0
	for k, v in next, userIds do
		count += 1
		if type(k) ~= "number" or k < 1 or k % 1 ~= 0 then
			error("104: DataStore userIds must be an array without string or non-integer keys.", 0)
		end
		if k > maxInt then maxInt = k end
		if type(v) ~= "number" or v ~= v or math.abs(v) == math.huge or v % 1 ~= 0 then
			error("103: DataStore UserId entries must be integers.", 0)
		end
	end
	if maxInt ~= count then error("104: DataStore userIds array cannot contain holes.", 0) end
	if count > MAX_USER_IDS then error(`106: Max number of UserIds is {MAX_USER_IDS}.`, 0) end
	local out: { number } = table.create(count) :: any
	for i = 1, count do
		local id: number = rawget(userIds, i) :: any
		out[i] = if id == 0 then 0 else id
	end
	return out
end

local function validateMetadata(metadata: any): { [string]: any }
	if metadata == nil then return {} end
	if type(metadata) ~= "table" or Datatypes.typeof(metadata) ~= "table" or getmetatable(metadata) ~= nil then
		error("103: DataStore metadata must be a plain dictionary table.", 0)
	end
	for k in next, metadata do
		if type(k) ~= "string" then error("104: DataStore metadata keys must be strings.", 0) end
	end
	local cloned, _ = serialize.datastore(metadata, {
		maxBytes = MAX_METADATA_BYTES,
		label = "DataStore metadata",
	})
	return cloned
end

--- Validates `value` against Roblox DataStore serialization rules and returns its JSON byte size.
function DataStore.check(value: any): number
	local _, size = serialize.datastore(value)
	return size
end

local KEY_INFO_MT = {
	__type = "DataStoreKeyInfo",
	__tostring = function(): string return "DataStoreKeyInfo" end,
}

local function makeKeyInfo(row: any, cloneFn: ((any) -> any)?): any
	if row == nil then return nil end
	local clone: (any) -> any = cloneFn or copy
	local userIds, metadata = clone(row.userIds or {}), clone(row.metadata or {})
	return setmetatable({
		Version = tostring(row.version),
		CreatedTime = row.created,
		UpdatedTime = row.updated,
		GetUserIds = function(_self: any) return clone(userIds) end,
		GetMetadata = function(_self: any) return clone(metadata) end,
	}, KEY_INFO_MT)
end
DataStore.makeKeyInfo = makeKeyInfo

--- Creates a `Pages` double over `items` with `pageSize` items per page and optional `onAdvance` / `cursorOf` callbacks.
local function makePages(items: { any }, pageSize: number?, onAdvance: (() -> ())?, cursorOf: ((any) -> string)?): any
	local step, index = math.max(1, math.floor(pageSize or 50)), 1
	local pages: any = { IsFinished = #items <= step }
	local function updateCursor()
		if cursorOf ~= nil then
			local last = items[math.min(#items, index + step - 1)]
			pages.Cursor = if pages.IsFinished or last == nil then "" else cursorOf(last)
		end
	end
	updateCursor()
	function pages.GetCurrentPage(_p: any): { any }
		return table.move(items, index, math.min(#items, index + step - 1), 1, {})
	end
	function pages.AdvanceToNextPageAsync(p: any)
		if p.IsFinished then error("AdvanceToNextPageAsync: No more pages", 0) end
		if onAdvance ~= nil then onAdvance() end
		index += step
		p.IsFinished = index + step - 1 >= #items
		updateCursor()
	end
	return pages
end
DataStore.makePages = makePages

local function listing(names: { string }, prefix: string?, cursor: string?): { string }
	table.sort(names)
	local out = {}
	for _, name in names do
		if
			(prefix == nil or prefix == "" or string.sub(name, 1, #prefix) == prefix)
			and (cursor == nil or cursor == "" or name > cursor)
		then
			table.insert(out, name)
		end
	end
	return out
end

local function extractSetMetadata(setOptions: any): { [string]: any }?
	if type(setOptions) ~= "table" then return nil end
	local getMeta = setOptions.GetMetadata
	if type(getMeta) == "function" then
		return getMeta(setOptions)
	elseif type(setOptions.metadata) == "table" then
		return setOptions.metadata
	end
	return nil
end

-- Runs `fn(...)` inside a fresh coroutine so yielding inside `UpdateAsync` fails immediately like Roblox.
local function invokeTransformNoYield(fn: any, ...: any): ...any
	if type(fn) ~= "function" then error("UpdateAsync: transform must be a function", 0) end
	local co = coroutine.create(fn)
	local packed = table.pack(coroutine.resume(co, ...))
	if not packed[1] then error(packed[2], 0) end
	if coroutine.status(co) ~= "dead" then
		pcall(coroutine.close, co)
		error("UpdateAsync: transform function cannot yield", 0)
	end
	return table.unpack(packed, 2, packed.n)
end

local function normalizeOrderedRow(rawRow: any, fallbackTime: number): any
	if rawRow == nil then return nil end
	if type(rawRow) == "number" then
		return {
			value = rawRow,
			version = 1,
			created = fallbackTime,
			updated = fallbackTime,
			userIds = {},
			metadata = {},
			deleted = false,
		}
	end
	return rawRow
end

local function writeStoreRow(
	handle: any,
	key: string,
	value: any,
	userIds: { number }?,
	metadata: { [string]: any }?,
	nowMs: () -> number
): any
	local cleanUsers = validateUserIds(userIds)
	local cleanMeta = validateMetadata(metadata)
	local rawPrev, t = handle.data[key], nowMs()
	local prev = if handle.ordered then normalizeOrderedRow(rawPrev, handle.created) else rawPrev

	local clonedValue: any
	if handle.ordered then
		if type(value) ~= "number" or value ~= value or math.abs(value) == math.huge or value % 1 ~= 0 then
			error("OrderedDataStore: value must be an integer", 0)
		end
		clonedValue = if value == 0 then 0 else value
	else
		clonedValue = (serialize.datastore(value))
	end

	local version = math.max(if prev ~= nil then prev.version + 1 else 1, (handle.nextVersion[key] or 0) + 1)
	handle.nextVersion[key] = version
	local row = {
		value = clonedValue,
		version = version,
		created = if prev ~= nil then prev.created else t,
		updated = t,
		userIds = cleanUsers,
		metadata = cleanMeta,
		deleted = false,
	}
	handle.data[key] = row
	if not handle.ordered then
		handle.versions[key] = handle.versions[key] or {}
		handle.versions[key][tostring(version)] = copy(row)
	end
	handle.updated = t
	return row
end

local function attachStandardVersionMethods(
	handle: any,
	method: (methodName: string, body: (key: any, ...any) -> ...any) -> (),
	record: (storeName: string, scope: string, method: string, key: string?) -> (),
	guarded: (
		types: { [string]: { string } },
		method: string,
		body: (...any) -> ...any,
		...any
	) -> ...any,
	chargePageAdvance: (budgetTypes: { string }) -> (),
	types: { [string]: { string } },
	name: string,
	scopeName: string
)
	method("GetVersionAsync", function(key: string, version: string): ...any
		local map = handle.versions[key]
		local row = if map ~= nil then map[tostring(version)] else nil
		if row == nil then return nil, nil end
		return copy(row.value), makeKeyInfo(row)
	end)

	method("RemoveVersionAsync", function(key: string, version: string)
		local map = handle.versions[key]
		if map ~= nil then map[tostring(version)] = nil end
		if handle.data[key] ~= nil and tostring(handle.data[key].version) == tostring(version) then
			local latestRow: any = nil
			for _, row in map or {} do
				if latestRow == nil or row.version > latestRow.version then latestRow = row end
			end
			handle.data[key] = if latestRow ~= nil and not latestRow.deleted then copy(latestRow) else nil
		end
	end)

	method(
		"ListVersionsAsync",
		function(key: string, sortDirection: any?, minDate: number?, maxDate: number?, pageSize: number?): any
			local items = {}
			for ver, row in handle.versions[key] or {} do
				if (minDate == nil or row.updated >= minDate) and (maxDate == nil or row.updated <= maxDate) then
					table.insert(items, { Version = ver, CreatedTime = row.updated, IsDeleted = row.deleted == true })
				end
			end
			local desc = tostring(sortDirection or "Ascending"):find("Descending", 1, true) ~= nil
			table.sort(items, function(a, b)
				local va, vb = tonumber(a.Version) or 0, tonumber(b.Version) or 0
				return if desc then va > vb else va < vb
			end)
			return makePages(items, pageSize, function() chargePageAdvance(types.ListVersionsAsync) end)
		end
	)

	function handle.ListKeysAsync(
		_self: any,
		prefix: string?,
		pageSize: number?,
		cursor: string?,
		excludeDeleted: boolean?
	): any
		record(name, scopeName, "ListKeysAsync", nil)
		return guarded(types, "ListKeysAsync", function(): any
			local present: { [string]: boolean } = {}
			for key in handle.data do
				present[key] = true
			end
			if not excludeDeleted then
				for key, map in handle.versions do
					if next(map) ~= nil then present[key] = true end
				end
			end
			local names, items = {}, {}
			for key in present do
				table.insert(names, key)
			end
			for _, key in listing(names, prefix, cursor) do
				table.insert(items, { KeyName = key })
			end
			return makePages(
				items,
				pageSize,
				function() chargePageAdvance(types.ListKeysAsync) end,
				function(item: any): string return item.KeyName end
			)
		end)
	end
end

local function attachOrderedMethods(
	handle: any,
	record: (storeName: string, scope: string, method: string, key: string?) -> (),
	guarded: (
		types: { [string]: { string } },
		method: string,
		body: (...any) -> ...any,
		...any
	) -> ...any,
	chargePageAdvance: (budgetTypes: { string }) -> (),
	types: { [string]: { string } },
	name: string,
	scopeName: string
)
	function handle.GetSortedAsync(
		_self: any,
		ascending: boolean,
		pageSize: number,
		minValue: number?,
		maxValue: number?
	): any
		record(name, scopeName, "GetSortedAsync", nil)
		if
			pageSize ~= nil
			and (type(pageSize) ~= "number" or pageSize < 1 or pageSize > 100 or pageSize ~= math.floor(pageSize))
		then
			error("GetSortedAsync: pageSize must be an integer in 1..100", 2)
		end
		if minValue ~= nil and maxValue ~= nil and minValue > maxValue then
			error("GetSortedAsync: minValue cannot be greater than maxValue", 2)
		end
		return guarded(types, "GetSortedAsync", function(): any
			local items: { { key: string, value: number } } = {}
			for k, rawRow in handle.data do
				local v = if type(rawRow) == "table" then rawRow.value else rawRow
				if
					type(v) == "number"
					and (minValue == nil or v >= minValue)
					and (maxValue == nil or v <= maxValue)
				then
					table.insert(items, { key = tostring(k), value = v })
				end
			end
			table.sort(items, function(a: { key: string, value: number }, b: { key: string, value: number }): boolean
				if a.value ~= b.value then return if ascending then a.value < b.value else a.value > b.value end
				return a.key < b.key
			end)
			return makePages(items, pageSize, function() chargePageAdvance(types.GetSortedAsync) end)
		end)
	end
end

local function listStandardStores(
	mock: any,
	chargePageAdvance: (budgetTypes: { string }) -> (),
	prefix: string?,
	pageSize: number?,
	cursor: string?
): any
	local byName: { [string]: { created: number, updated: number } } = {}
	for _, handle in mock.stores do
		if not handle.ordered then
			local entry, updated = byName[handle.name], handle.updated or handle.created
			if entry == nil then
				byName[handle.name] = { created = handle.created, updated = updated }
			else
				entry.created, entry.updated = math.min(entry.created, handle.created), math.max(entry.updated, updated)
			end
		end
	end
	local names, items = {}, {}
	for storeName in byName do
		table.insert(names, storeName)
	end
	for _, storeName in listing(names, prefix, cursor) do
		local entry = byName[storeName]
		table.insert(items, { DataStoreName = storeName, CreatedTime = entry.created, UpdatedTime = entry.updated })
	end
	return makePages(
		items,
		pageSize,
		function() chargePageAdvance(REQUEST_TYPES.service.ListDataStoresAsync) end,
		function(item: any): string return item.DataStoreName end
	)
end

--- Creates a headless `DataStoreService` double.
function DataStore.new(options: { [string]: any }?): any
	local opts: { [string]: any } = options or {}
	local clock: () -> number = opts.clock or function(): number return os.time() end
	local mock: any = { calls = {}, stores = {}, options = opts, failures = {}, conflict = nil }
	local budget = DataStore.budget(clock, opts.budget)
	mock.budgets = budget.rows
	local faults: { [string]: any } = opts.faults or {}
	local stream = Rng.new(faults.seed or 1)

	local function nowMs(): number return math.floor(clock() * 1000) end

	function mock.budget(_self: any, requestType: any, units: number?, perMinute: number?)
		budget:set(requestType, units, perMinute)
	end

	function mock.GetRequestBudgetForRequestType(_self: any, requestType: any): number
		return budget:remaining(requestType) or UNMODELLED
	end

	function mock.fail(_self: any, method: string, message: string?, after: boolean?)
		table.insert(mock.failures, { method = method, message = message, after = after == true })
	end

	local function fault(method: string, after: boolean)
		for index, entry in mock.failures do
			if entry.method == method and entry.after == after then
				table.remove(mock.failures, index)
				error(entry.message or `DataStore double: injected failure in {method}`, 0)
			end
		end
		local chance = if after then faults.after else faults.before
		if chance ~= nil and chance > 0 and stream:chance(chance) then
			error(
				if after
					then `DataStore double: {method} reply lost`
					else `DataStore double: {method} failed before taking effect`,
				0
			)
		end
	end

	local function guarded(types: { [string]: { string } }, method: string, body: (...any) -> ...any, ...: any): ...any
		local exhausted = budget:charge(types[method] or {})
		if exhausted ~= nil then error(`RequestThrottled: {exhausted} budget exhausted`, 0) end
		fault(method, false)
		local out = table.pack(body(...))
		fault(method, true)
		return table.unpack(out, 1, out.n)
	end

	local function chargePageAdvance(budgetTypes: { string })
		local exhausted = budget:charge(budgetTypes)
		if exhausted ~= nil then error(`RequestThrottled: {exhausted} budget exhausted`, 0) end
		fault("AdvanceToNextPageAsync", false)
		fault("AdvanceToNextPageAsync", true)
	end

	local function record(storeName: string, scope: string, method: string, key: string?)
		table.insert(mock.calls, { store = storeName, scope = scope, method = method, key = key })
	end

	local function createStore(name: string, scope: string?, ordered: boolean): any
		checkName("DataStore name", name)
		local scopeName = scope or "global"
		checkName("DataStore scope", scopeName)
		local id = `{if ordered then "ordered" else "standard"}:{name}/{scopeName}`
		if mock.stores[id] ~= nil then return mock.stores[id] end
		local types = REQUEST_TYPES[if ordered then "ordered" else "standard"]
		local handle: any = {
			name = name,
			scope = scopeName,
			ordered = ordered,
			created = nowMs(),
			data = {},
			versions = {},
			nextVersion = {},
		}

		local function writeRow(key: string, value: any, userIds: { number }?, metadata: { [string]: any }?): any
			return writeStoreRow(handle, key, value, userIds, metadata, nowMs)
		end

		local function method(methodName: string, body: (key: any, ...any) -> ...any)
			handle[methodName] = function(_self: any, key: any, ...: any): ...any
				record(name, scopeName, methodName, key)
				checkKey(key)
				return guarded(types, methodName, body, tostring(key), ...)
			end
		end

		method("GetAsync", function(key: string, _getOptions: any?): ...any
			local rawRow = handle.data[key]
			local row = if ordered then normalizeOrderedRow(rawRow, handle.created) else rawRow
			if row == nil then return nil, nil end
			return copy(row.value), makeKeyInfo(row)
		end)

		method("SetAsync", function(key: string, ...: any): string
			local value: any, userIds: { number }?, setOptions: any? = ...
			if select("#", ...) == 0 or value == nil then error("SetAsync: Argument 2 missing or nil", 0) end
			local row = writeRow(key, value, userIds, extractSetMetadata(setOptions))
			return tostring(row.version)
		end)

		method("IncrementAsync", function(key: string, delta: number?, userIds: { number }?, setOptions: any?): ...any
			local rawPrev = handle.data[key]
			local prev = if ordered then normalizeOrderedRow(rawPrev, handle.created) else rawPrev
			local current = if prev == nil then 0 else prev.value
			if type(current) ~= "number" then error("IncrementAsync: current value is not a number", 0) end
			local step = if delta ~= nil then delta else 1
			if type(step) ~= "number" or step ~= step or math.abs(step) == math.huge then
				error("IncrementAsync: delta must be a finite number", 0)
			end
			local row = writeRow(key, current + step, userIds, extractSetMetadata(setOptions))
			return copy(row.value), makeKeyInfo(row)
		end)

		method("UpdateAsync", function(key: string, transform: (any, any) -> ...any): ...any
			local function runTransform(): (any, any, any)
				local rawPrev = handle.data[key]
				local prev = if ordered then normalizeOrderedRow(rawPrev, handle.created) else rawPrev
				return invokeTransformNoYield(
					transform,
					if prev ~= nil then copy(prev.value) else nil,
					makeKeyInfo(prev)
				)
			end
			local nextVal, userIds, metadata = runTransform()
			local conflict: ((any, string) -> ())? = mock.conflict
			if conflict ~= nil then
				mock.conflict = nil
				conflict(handle, key)
				nextVal, userIds, metadata = runTransform()
			end
			if nextVal == nil then return nil, nil end
			local row = writeRow(key, nextVal, userIds, metadata)
			return copy(row.value), makeKeyInfo(row)
		end)

		method("RemoveAsync", function(key: string): ...any
			local rawPrev = handle.data[key]
			local prev = if ordered then normalizeOrderedRow(rawPrev, handle.created) else rawPrev
			handle.data[key] = nil
			if prev == nil then return nil, nil end
			if not ordered and handle.versions[key] ~= nil then
				local verRow = handle.versions[key][tostring(prev.version)]
				if verRow ~= nil then verRow.deleted = true end
			end
			return copy(prev.value), makeKeyInfo(prev)
		end)

		if not ordered then
			attachStandardVersionMethods(handle, method, record, guarded, chargePageAdvance, types, name, scopeName)
		else
			attachOrderedMethods(handle, record, guarded, chargePageAdvance, types, name, scopeName)
		end

		mock.stores[id] = handle
		return handle
	end

	function mock.GetDataStore(_self: any, name: string, scope: string?, _options: any?): any
		return createStore(name, scope, false)
	end

	function mock.GetGlobalDataStore(_self: any): any return createStore("_global", "global", false) end

	function mock.GetOrderedDataStore(_self: any, name: string, scope: string?): any
		return createStore(name, scope, true)
	end

	function mock.ListDataStoresAsync(_self: any, prefix: string?, pageSize: number?, cursor: string?): any
		return guarded(
			REQUEST_TYPES.service,
			"ListDataStoresAsync",
			listStandardStores,
			mock,
			chargePageAdvance,
			prefix,
			pageSize,
			cursor
		)
	end

	return mock
end

return table.freeze(DataStore)
