--!strict
-- Parallel Luau doubles: `SharedTable`, `SharedTableRegistry` backing, `Actor` messaging, and per-coroutine
-- desynchronization state + strict-mode parallel safety enforcement.

local Parallel = {}

local STATES: { [any]: { data: { [any]: any }, frozen: boolean } } = setmetatable({}, { __mode = "k" }) :: any
local ACTOR_BINDINGS: { [any]: { [string]: { { fn: (...any) -> (), parallel: boolean, active: boolean } } } } = setmetatable(
	{},
	{ __mode = "k" }
) :: any

local SharedTable: any = {}
local SharedTableMeta: any = { __type = "SharedTable" }

local ALLOWED_SHARED_DATATYPES: { [string]: boolean } = {
	Axes = true,
	BrickColor = true,
	CFrame = true,
	Color3 = true,
	ColorSequence = true,
	ColorSequenceKeypoint = true,
	DateTime = true,
	EnumItem = true,
	Faces = true,
	Font = true,
	NumberRange = true,
	NumberSequence = true,
	NumberSequenceKeypoint = true,
	PhysicalProperties = true,
	Ray = true,
	Rect = true,
	Region3 = true,
	Region3int16 = true,
	UDim = true,
	UDim2 = true,
	Vector2 = true,
	Vector2int16 = true,
	Vector3 = true,
	Vector3int16 = true,
}

local wrapValue: (value: any, seen: { [any]: any }?, freezeChildren: boolean?) -> any

local function checkState(st: any, op: string, requireMutable: boolean?): { data: { [any]: any }, frozen: boolean }
	local state = if type(st) == "table" then STATES[st] else nil
	if state == nil then error(`SharedTable.{op}: expected a SharedTable, got {typeof(st)}`, 3) end
	if requireMutable and state.frozen then error(`SharedTable.{op}: attempt to modify a frozen SharedTable`, 3) end
	return state
end

local function isValidKey(key: any): boolean
	local kt = type(key)
	if kt == "string" then return true end
	return kt == "number" and key == key and key % 1 == 0 and math.abs(key) < 9007199254740992
end

local function newFromState(data: { [any]: any }, frozen: boolean): any
	local proxy = setmetatable({}, SharedTableMeta)
	STATES[proxy] = { data = data, frozen = frozen }
	return proxy
end

function wrapValue(value: any, seen: { [any]: any }?, freezeChildren: boolean?): any
	if value == nil then return nil end
	local vt = type(value)
	if vt == "boolean" or vt == "number" or vt == "string" or vt == "vector" then return value end
	if vt == "table" then
		if STATES[value] ~= nil then return value end
		if rawget(value, "_isInstance") == true then error("SharedTable cannot store Instance values", 3) end
		local mt = getmetatable(value :: any)
		if mt ~= nil then
			local dtTag = rawget(mt, "__type")
			if type(dtTag) == "string" and ALLOWED_SHARED_DATATYPES[dtTag] == true then return value end
			error("SharedTable cannot store tables with custom metatables", 3)
		end
		local tracker = seen or {}
		if tracker[value] ~= nil then error("SharedTable.new: cyclic table reference", 3) end
		tracker[value] = true
		local data: { [any]: any } = {}
		for k, v in next, value do
			if not isValidKey(k) then error(`SharedTable: invalid key type "{typeof(k)}"`, 3) end
			data[k] = wrapValue(v, tracker, freezeChildren)
		end
		tracker[value] = nil
		return newFromState(data, freezeChildren == true)
	end
	error(`SharedTable cannot store value of type "{typeof(value)}"`, 3)
end

function SharedTableMeta.__index(self: any, key: any): any
	local state = STATES[self]
	if state == nil then return nil end
	return state.data[key]
end

function SharedTableMeta.__newindex(self: any, key: any, value: any)
	local state = checkState(self, "__newindex", true)
	if not isValidKey(key) then error(`SharedTable: invalid key type "{typeof(key)}"`, 2) end
	state.data[key] = wrapValue(value, nil, false)
end

function SharedTableMeta.__len(self: any): number
	local state = STATES[self]
	return if state ~= nil then #state.data else 0
end

function SharedTableMeta.__iter(self: any): (any, any)
	local state = STATES[self]
	if state == nil then return next, {} end
	return next, state.data
end

function SharedTableMeta.__tostring(self: any): string
	local state = STATES[self]
	if state == nil then return "SharedTable" end
	return `SharedTable({SharedTable.size(self)})`
end

--- Constructs a new `SharedTable`, optionally populated recursively from `t`.
function SharedTable.new(t: { [any]: any }?): any
	if t == nil then return newFromState({}, false) end
	if type(t) ~= "table" then error(`SharedTable.new: expected table or nil, got {typeof(t)}`, 2) end
	if STATES[t] ~= nil then return SharedTable.clone(t, true) end
	return wrapValue(t, nil, false)
end

--- Removes all entries from a mutable `SharedTable`.
function SharedTable.clear(st: any)
	local state = checkState(st, "clear", true)
	table.clear(state.data)
end

--- Returns a shallow or deep mutable clone of `st`.
function SharedTable.clone(st: any, deep: boolean?): any
	local state = checkState(st, "clone", false)
	local out: { [any]: any } = {}
	for k, v in next, state.data do
		out[k] = if deep == true and type(v) == "table" and STATES[v] ~= nil then SharedTable.clone(v, true) else v
	end
	return newFromState(out, false)
end

--- Returns a shallow or deep frozen (read-only) clone of `st`.
function SharedTable.cloneAndFreeze(st: any, deep: boolean?): any
	local state = checkState(st, "cloneAndFreeze", false)
	local out: { [any]: any } = {}
	for k, v in next, state.data do
		out[k] = if deep == true
				and type(v) == "table"
				and STATES[v] ~= nil
			then SharedTable.cloneAndFreeze(v, true)
			else v
	end
	return newFromState(out, true)
end

--- Returns `true` when `st` is frozen.
function SharedTable.isFrozen(st: any): boolean
	local state = checkState(st, "isFrozen", false)
	return state.frozen
end

--- Returns total entry count in `st`.
function SharedTable.size(st: any): number
	local state = checkState(st, "size", false)
	local count = 0
	for _ in next, state.data do
		count += 1
	end
	return count
end

--- Atomically adds `delta` to `st[key]` (initializing missing keys from 0) and returns the previous value.
function SharedTable.increment(st: any, key: any, delta: number): number
	local state = checkState(st, "increment", true)
	if not isValidKey(key) then error(`SharedTable.increment: invalid key type "{typeof(key)}"`, 2) end
	if type(delta) ~= "number" then error(`SharedTable.increment: expected number delta, got {typeof(delta)}`, 2) end
	local prev = state.data[key]
	if prev == nil then
		prev = 0
	elseif type(prev) ~= "number" then
		error(`SharedTable.increment: existing value at key "{tostring(key)}" is not a number`, 2)
	end
	state.data[key] = prev + delta
	return prev
end

--- Applies `f(oldValue)` to update `st[key]`.
function SharedTable.update(st: any, key: any, f: (any) -> any)
	local state = checkState(st, "update", true)
	if not isValidKey(key) then error(`SharedTable.update: invalid key type "{typeof(key)}"`, 2) end
	if type(f) ~= "function" then error(`SharedTable.update: expected function, got {typeof(f)}`, 2) end
	local updated = f(state.data[key])
	state.data[key] = wrapValue(updated, nil, false)
end

Parallel.SharedTable = table.freeze(SharedTable)

--- Returns per-env `(isDesynchronized, setDesynchronized)` tracking keyed weakly by coroutine.
function Parallel.makeThreadTracker(): (() -> boolean, (boolean) -> ())
	local threads: { [thread]: boolean } = setmetatable({}, { __mode = "k" }) :: any
	local function isDesynchronized(): boolean return threads[coroutine.running()] == true end
	local function setDesynchronized(flag: boolean)
		local running = coroutine.running()
		if flag then
			threads[running] = true
		else
			threads[running] = nil
		end
	end
	return isDesynchronized, setDesynchronized
end

--- Throws a Roblox-accurate parallel safety error when `env.strict == true` and current coroutine is desynchronized.
function Parallel.assertSerial(env: any?, opLabel: string)
	if env == nil or env.strict ~= true then return end
	local isDesync: any = rawget(env, "_isDesynchronized")
	if type(isDesync) == "function" and (isDesync :: () -> boolean)() == true then
		error(`{opLabel} is not safe to write or call in parallel`, 3)
	end
end

--- Creates a `SharedTableRegistry` method table backed by `registryStore`.
function Parallel.sharedTableRegistryMethods(registryStore: { [string]: any }): { [string]: (...any) -> ...any }
	return {
		GetSharedTable = function(_self: any, name: string): any
			assert(type(name) == "string", "SharedTableRegistry:GetSharedTable: expected string name")
			local st = registryStore[name]
			if st == nil then
				st = SharedTable.new()
				registryStore[name] = st
			end
			return st
		end,
		SetSharedTable = function(_self: any, name: string, st: any?)
			assert(type(name) == "string", "SharedTableRegistry:SetSharedTable: expected string name")
			if st ~= nil and STATES[st] == nil then
				error(`SharedTableRegistry:SetSharedTable: expected SharedTable or nil, got {typeof(st)}`, 2)
			end
			registryStore[name] = st
		end,
	}
end

local function addMessageBinding(actor: any, topic: string, fn: (...any) -> (), parallel: boolean): any
	assert(type(topic) == "string", "Actor:BindToMessage: topic must be a string")
	assert(type(fn) == "function", "Actor:BindToMessage: callback must be a function")
	local byTopic = ACTOR_BINDINGS[actor]
	if byTopic == nil then
		byTopic = {}
		ACTOR_BINDINGS[actor] = byTopic
	end
	local list = byTopic[topic]
	if list == nil then
		list = {}
		byTopic[topic] = list
	end
	local entry = { fn = fn, parallel = parallel, active = true }
	table.insert(list, entry)

	local conn = { Connected = true } :: any
	function conn.Disconnect(self: any)
		if not self.Connected then return end
		self.Connected = false
		entry.active = false
		local idx = table.find(list, entry)
		if idx ~= nil then table.remove(list, idx) end
	end
	return conn
end

local function cloneMessageArg(value: any, seen: { [any]: any }?): any
	if value == nil then return nil end
	local vt = type(value)
	if vt == "buffer" then
		local len = buffer.len(value)
		local copyBuf = buffer.create(len)
		buffer.copy(copyBuf, 0, value, 0, len)
		return copyBuf
	end
	if vt ~= "table" then return value end
	if STATES[value] ~= nil or rawget(value, "_isInstance") == true then return value end
	local mt = getmetatable(value :: any)
	if mt ~= nil then
		local dtTag = rawget(mt, "__type")
		if type(dtTag) == "string" and ALLOWED_SHARED_DATATYPES[dtTag] == true then return value end
		return value
	end
	local tracker = seen or {}
	if tracker[value] ~= nil then return tracker[value] end
	local out: { [any]: any } = {}
	tracker[value] = out
	for k, v in next, value do
		out[cloneMessageArg(k, tracker)] = cloneMessageArg(v, tracker)
	end
	return out
end

local function clonePackedArgs(packed: { [number]: any, n: number }): { [number]: any, n: number }
	local out: { [number]: any, n: number } = { n = packed.n }
	local tracker: { [any]: any } = {}
	for i = 1, packed.n do
		out[i] = cloneMessageArg(packed[i], tracker)
	end
	return out
end

Parallel.ActorMethods = {
	BindToMessage = function(self: any, topic: string, fn: (...any) -> ()): any
		return addMessageBinding(self, topic, fn, false)
	end,
	BindToMessageParallel = function(self: any, topic: string, fn: (...any) -> ()): any
		return addMessageBinding(self, topic, fn, true)
	end,
	SendMessage = function(self: any, topic: string, ...: any)
		assert(type(topic) == "string", "Actor:SendMessage: topic must be a string")
		local byTopic = ACTOR_BINDINGS[self]
		local list = if byTopic ~= nil then byTopic[topic] else nil
		if list == nil or #list == 0 then return end
		local env = rawget(self, "_env")
		local taskLib = if env ~= nil then env.task else nil
		local setDesync: any = if env ~= nil then rawget(env, "_setDesynchronized") else nil
		local snapshot = table.clone(list)
		local activeEntries = {}
		for _, entry in snapshot do
			if entry.active then table.insert(activeEntries, entry) end
		end
		if #activeEntries == 0 then return end
		local packed = clonePackedArgs(table.pack(...))
		local activeCount = #activeEntries
		for idx, entry in activeEntries do
			local argsForEntry = if idx < activeCount then clonePackedArgs(packed) else packed
			local runner = function()
				if type(setDesync) == "function" then (setDesync :: (boolean) -> ())(entry.parallel) end
				entry.fn(table.unpack(argsForEntry, 1, argsForEntry.n))
			end
			if taskLib ~= nil and taskLib.spawn ~= nil then
				taskLib.spawn(runner)
			else
				local ok, err = coroutine.resume(coroutine.create(runner))
				if not ok then error(err, 0) end
			end
		end
	end,
}

return Parallel
