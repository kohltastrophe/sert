--!strict
--[=[
	`DataStoreService` double (`sert.doubles.DataStore`, `Sim.DataStore`). Supports standard and ordered stores,
	key versions, listing, engine size limits, request budgets, and fault injection.
]=]

local Datatypes = require("./datatypes")
local Rng = require("../rng")
local format = require("../format")
local util = require("../util")

local deepCopy = util.copy
local DataStore = {}

local NAME_LIMIT, KEY_LIMIT = 50, 50
local MAX_VALUE, UNMODELLED = 4 * 1024 * 1024, 1000000
DataStore.MAX_VALUE, DataStore.UNMODELLED = MAX_VALUE, UNMODELLED

-- The request types each method draws on (Enum.DataStoreRequestType names).
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

local COPY: util.CopyOptions = {
	overflow = function(_: any): any error("DataStore double: table exceeds 64 levels", 0) end,
}

--- A stored value's own copy (src/util.luau: buffers copied, tables with metatables shared, cycle-safe).
local function copy(value: any): any return deepCopy(value, COPY) end
DataStore.copy = copy

-- Request budgets ------------------------------------------------------------------------------------------------

local function typeName(requestType: any): string
	local text = tostring(requestType)
	return string.match(text, "([%w_]+)$") or text
end

export type Budget = {
	-- Rows by request type name: `{ units, perMinute, max, at }`, or false when set unmodelled.
	rows: { [string]: any },
	--- Models `requestType`: `units` now and `perMinute` refill (default `units`); units nil stops modelling it.
	set: (self: Budget, requestType: any, units: number?, perMinute: number?) -> (),
	--- Units left (floored), or nil when the type is unmodelled.
	remaining: (self: Budget, requestType: any) -> number?,
	--- Takes one unit of each type, or none and returns the first exhausted type's name.
	charge: (self: Budget, types: { string }) -> string?,
}

--- A per-request-type budget on `clock()` (seconds). A type not set explicitly starts at `units` (a number, or a
--- function read each time) and refills as many per minute; nil units leave it unmodelled.
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

-- Limits and serializability -------------------------------------------------------------------------------------

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
	if type(key) ~= "string" and type(key) ~= "number" then error(`101: Key name must be a string.`, 0) end
	local text = tostring(key)
	if #text == 0 then
		error("101: Key name can't be empty.", 0)
	elseif #text > KEY_LIMIT then
		error(`102: Key name exceeds the {KEY_LIMIT} character limit.`, 0)
	end
end

-- Raises the engine's error for the first part of `value` a data store can't hold.
local function checkValue(value: any, seen: { [any]: boolean })
	local kind = type(value)
	if kind == "nil" or kind == "boolean" or kind == "buffer" then
		return
	elseif kind == "number" then
		if value ~= value or value == math.huge or value == -math.huge then
			error("104: Cannot store NaN or infinity in data store.", 0)
		end
		return
	elseif kind == "string" then
		if utf8.len(value) == nil then
			error("104: Cannot store string in data store. Data stores can only accept valid UTF-8 characters.", 0)
		end
		return
	elseif kind ~= "table" then
		error(`103: {Datatypes.typeof(value)} is not allowed in data stores.`, 0)
	end
	local named = Datatypes.typeof(value)
	if named ~= "table" then
		error(`103: {named} is not allowed in data stores.`, 0)
	elseif getmetatable(value) ~= nil then
		error("103: Tables with metatables are not allowed in data stores.", 0)
	elseif seen[value] then
		error("104: Cannot store cyclic tables in data store.", 0)
	end
	seen[value] = true
	local count, strings = 0, 0
	for key, item in value do
		count += 1
		if type(key) == "string" then
			strings += 1
			if utf8.len(key) == nil then
				error(
					"104: Cannot store Dictionary in data store. Data stores can only accept valid UTF-8 characters.",
					0
				)
			end
		elseif type(key) ~= "number" or key < 1 or key % 1 ~= 0 then
			error(`104: Cannot store a table with {Datatypes.typeof(key)} keys in data store.`, 0)
		end
		checkValue(item, seen)
	end
	if strings > 0 and strings < count then
		error("104: Cannot store mixed tables in data store.", 0)
	elseif strings == 0 and count ~= #value then
		error("104: Cannot store arrays with holes in data store.", 0)
	end
	seen[value] = nil
end

local SIZE_JSON: format.JsonOptions = {
	strict = true,
	prefix = "104: Cannot store value in data store: ",
	buffer = function(value: buffer): string
		-- The engine's uncompressed buffer form, {"m":null,"t":"buffer","base64":"..."}: only its length matters.
		return string.rep("x", 35 + 4 * math.ceil(buffer.len(value) / 3))
	end,
}

--- Raises the engine's error when `value` can't be stored (see the header); returns its serialized size.
function DataStore.check(value: any): number
	checkValue(value, {})
	local size = #format.json(value, SIZE_JSON)
	if size > MAX_VALUE then error(`105: Serialized value exceeds 4MB limit.`, 0) end
	return size
end

-- Shapes ---------------------------------------------------------------------------------------------------------

local function makeKeyInfo(row: any, cloneFn: ((any) -> any)?): any
	if row == nil then return nil end
	local clone: (any) -> any = cloneFn or copy
	local userIds, metadata = clone(row.userIds or {}), clone(row.metadata or {})
	return {
		Version = tostring(row.version),
		CreatedTime = row.created,
		UpdatedTime = row.updated,
		GetUserIds = function(_self: any) return clone(userIds) end,
		GetMetadata = function(_self: any) return clone(metadata) end,
	}
end
DataStore.makeKeyInfo = makeKeyInfo

--- A Pages object over `items`, `pageSize` per page. `onAdvance` runs before each AdvanceToNextPageAsync;
--- `cursorOf(item)` gives the `Cursor` that resumes after an item (DataStoreKeyPages and DataStoreListingPages:
--- "" once the last page is current).
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

-- The sorted names (or keys) that start with `prefix` and sort after `cursor`.
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

-- The double ------------------------------------------------------------------------------------------------------

local function extractSetMetadata(setOptions: any): { [string]: any }?
	if type(setOptions) ~= "table" then return nil end
	local getMeta = setOptions.GetMetadata
	if type(getMeta) == "function" then
		return getMeta(setOptions)
	elseif type(setOptions.metadata) == "table" then
		return copy(setOptions.metadata)
	end
	return nil
end

local function writeStoreRow(
	handle: any,
	key: string,
	value: any,
	userIds: { number }?,
	metadata: { [string]: any }?,
	nowMs: () -> number
): any
	if handle.ordered then
		if type(value) ~= "number" or value % 1 ~= 0 then error("OrderedDataStore: value must be an integer", 0) end
		handle.data[key] = value
		return nil
	end
	DataStore.check(value)
	if metadata ~= nil then DataStore.check(metadata) end
	local prev, t = handle.data[key], nowMs()
	local version = math.max(if prev ~= nil then prev.version + 1 else 1, (handle.nextVersion[key] or 0) + 1)
	handle.nextVersion[key] = version
	local row = {
		value = copy(value),
		version = version,
		created = if prev ~= nil then prev.created else t,
		updated = t,
		userIds = if userIds ~= nil then copy(userIds) else {},
		metadata = if metadata ~= nil then copy(metadata) else {},
		deleted = false,
	}
	handle.data[key] = row
	handle.versions[key] = handle.versions[key] or {}
	handle.versions[key][tostring(version)] = copy(row)
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
			return makePages(items, pageSize)
		end
	)

	--- DataStoreKeyPages of `{ KeyName }` in key order: keys starting with `prefix`, after `cursor`. A
	--- removed key whose versions remain is listed unless `excludeDeleted`.
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
			return makePages(items, pageSize, nil, function(item: any): string return item.KeyName end)
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
			for k, v in handle.data do
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
			return makePages(items, pageSize)
		end)
	end
end

local function listStandardStores(mock: any, prefix: string?, pageSize: number?, cursor: string?): any
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
	return makePages(items, pageSize, nil, function(item: any): string return item.DataStoreName end)
end

function DataStore.new(options: { [string]: any }?): any
	local opts: { [string]: any } = options or {}
	local clock: () -> number = opts.clock or function(): number return os.time() end
	local mock: any = { calls = {}, stores = {}, options = opts, failures = {} }
	local budget = DataStore.budget(clock, opts.budget)
	mock.budgets = budget.rows
	local faults: { [string]: any } = opts.faults or {}
	local stream = Rng.new(faults.seed or 1)

	local function nowMs(): number return math.floor(clock() * 1000) end

	--- Models `requestType`'s budget: `units` now and `perMinute` refill; units nil makes it unmodelled.
	function mock.budget(_self: any, requestType: any, units: number?, perMinute: number?)
		budget:set(requestType, units, perMinute)
	end

	function mock.GetRequestBudgetForRequestType(_self: any, requestType: any): number
		return budget:remaining(requestType) or UNMODELLED
	end

	--- Queues one failure for the next `method` call: before it takes effect, or `after` (the write stands).
	function mock.fail(_self: any, method: string, message: string?, after: boolean?)
		table.insert(mock.failures, { method = method, message = message, after = after == true })
	end

	-- A scripted or random fault for `method` at this phase, raised as an error.
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

	-- Charges the method's request types, then runs it between the before and after faults.
	local function guarded(types: { [string]: { string } }, method: string, body: (...any) -> ...any, ...: any): ...any
		local exhausted = budget:charge(types[method] or {})
		if exhausted ~= nil then error(`RequestThrottled: {exhausted} budget exhausted`, 0) end
		fault(method, false)
		local out = table.pack(body(...))
		fault(method, true)
		return table.unpack(out, 1, out.n)
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

		-- Defines `handle[method]`: records the call, checks the key, then runs `body` guarded.
		local function method(methodName: string, body: (key: any, ...any) -> ...any)
			handle[methodName] = function(_self: any, key: any, ...: any): ...any
				record(name, scopeName, methodName, key)
				checkKey(key)
				return guarded(types, methodName, body, tostring(key), ...)
			end
		end

		method("GetAsync", function(key: string): ...any
			local row = handle.data[key]
			if row == nil then
				return nil, nil
			elseif ordered then
				return row
			end
			return copy(row.value), makeKeyInfo(row)
		end)

		method("SetAsync", function(key: string, ...: any): any
			local value: any, userIds: { number }?, setOptions: any? = ...
			if select("#", ...) == 0 or value == nil then
				error("SetAsync: Argument 2 missing or nil", 0)
			elseif ordered then
				writeRow(key, value)
				return nil
			end
			return tostring(writeRow(key, value, userIds, extractSetMetadata(setOptions)).version)
		end)

		method("IncrementAsync", function(key: string, delta: number?, userIds: { number }?, setOptions: any?): ...any
			local prev = handle.data[key]
			local current = if prev == nil then 0 elseif ordered then prev else prev.value
			if type(current) ~= "number" then error("IncrementAsync: current value is not a number", 0) end
			local nextVal = current + (delta or 1)
			if ordered then
				writeRow(key, nextVal)
				return nextVal
			end
			local row = writeRow(key, nextVal, userIds, extractSetMetadata(setOptions))
			return copy(row.value), makeKeyInfo(row)
		end)

		method("UpdateAsync", function(key: string, transform: (any, any) -> ...any): ...any
			local prev = handle.data[key]
			if ordered then
				local nextVal = transform(prev, nil)
				if nextVal == nil then return nil end
				writeRow(key, nextVal)
				return nextVal
			end
			local nextVal, userIds, metadata =
				transform(if prev ~= nil then copy(prev.value) else nil, makeKeyInfo(prev))
			if nextVal == nil then return nil, nil end
			local row = writeRow(key, nextVal, userIds, metadata)
			return copy(row.value), makeKeyInfo(row)
		end)

		method("RemoveAsync", function(key: string): ...any
			local prev = handle.data[key]
			handle.data[key] = nil
			if prev == nil then
				return nil, nil
			elseif ordered then
				return prev
			end
			if handle.versions[key] ~= nil then
				local verRow = handle.versions[key][tostring(prev.version)]
				if verRow ~= nil then verRow.deleted = true end
			end
			return copy(prev.value), makeKeyInfo(prev)
		end)

		if not ordered then
			attachStandardVersionMethods(handle, method, record, guarded, types, name, scopeName)
		else
			attachOrderedMethods(handle, record, guarded, types, name, scopeName)
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

	--- DataStoreListingPages of `{ DataStoreName, CreatedTime, UpdatedTime }`: the standard stores opened so far
	--- (any scope), by name, starting with `prefix` and after `cursor`.
	function mock.ListDataStoresAsync(_self: any, prefix: string?, pageSize: number?, cursor: string?): any
		return guarded(REQUEST_TYPES.service, "ListDataStoresAsync", listStandardStores, mock, prefix, pageSize, cursor)
	end

	return mock
end

return table.freeze(DataStore)
