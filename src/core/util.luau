--!strict
-- Shared internal utilities: virtual clock constants, datatype tag inspection, stack frame resolution, deep equality, and deep copy.

local bytes = require("./bytes")

export type CopyOptions = {
	keepMetatables: boolean?,
	map: ((value: any) -> (boolean, any))?,
	depth: number?,
	overflow: ((value: any) -> any)?,
}

local nativeType, nativeTypeof = type, typeof

local SELF_SOURCE: string = debug.info(1, "s") or ""
local CLEAN_SELF: string = string.gsub(SELF_SOURCE, "%.luau?$", "")
-- Compute `src/` root (parent of `core/util`) so frames in `core`, `prop`, `engine`, `env`, `sim`, and `roblox` all count as internal.
local ROOT: string = string.match(CLEAN_SELF, "^(.*)[/\\%.]core[/\\%.]util$")
	or (if CLEAN_SELF == "core/util" or CLEAN_SELF == "core\\util" or CLEAN_SELF == "core.util" then "" else nil)
	or string.match(CLEAN_SELF, "^(.*)[/\\%.]util$")
	or CLEAN_SELF

local INTERNAL_SUBDIRS: { [string]: boolean } = {
	init = true,
	core = true,
	prop = true,
	engine = true,
	env = true,
	sim = true,
	roblox = true,
}

local util = {
	-- Virtual times within EPSILON count as equal to absorb fixed-step rounding error.
	EPSILON = 1e-9,
	-- Deterministic Unix timestamp at virtual time 0.
	UNIX_EPOCH = 1700000000,
}

--- Returns the headless engine datatype tag (`__type` or `"Instance"`) when `value` is a datatype/Instance double, or `nil`.
function util.doubleTag(value: any): string?
	if nativeType(value) == "table" then
		local mt = getmetatable(value)
		if nativeType(mt) == "table" then
			local tag = rawget(mt, "__type")
			if nativeType(tag) == "string" then return tag end
		end
		if rawget(value, "_isInstance") == true then return "Instance" end
	end
	return nil
end

--- Returns the Roblox or headless engine datatype name for `value`.
function util.typeof(value: any): string return util.doubleTag(value) or nativeTypeof(value) end

--- Returns `"userdata"` for headless engine datatype/Instance doubles and `type(value)` otherwise.
function util.type(value: any): string return if util.doubleTag(value) ~= nil then "userdata" else nativeType(value) end

--- Returns `true` when `chunk` (`debug.info(level, "s")`) belongs to `sert` or is `[C]`.
function util.internal(chunk: string): boolean
	if chunk == "[C]" or chunk == SELF_SOURCE then return true end
	local clean = string.gsub(chunk, "%.luau?$", "")
	if ROOT == "" then
		local head = string.match(clean, "^([^/\\%.]+)")
		return head ~= nil and INTERNAL_SUBDIRS[head] == true
	end
	if clean == ROOT then return true end
	if string.sub(clean, 1, #ROOT) ~= ROOT then return false end
	local sep = string.sub(clean, #ROOT + 1, #ROOT + 1)
	return sep == "/" or sep == "\\" or sep == "."
end

--- Returns the `error` stack level of the nearest caller outside `sert` (or `2` if none).
function util.outside(): number
	for level = 3, 64 do
		local chunk = debug.info(level, "s")
		if chunk == nil then break end
		if not util.internal(chunk) then return level - 1 end
	end
	return 2
end

local function exactNumberEqual(a: number, b: number): boolean
	if a ~= a and b ~= b then return true end
	if a ~= b then return false end
	return a ~= 0 or 1 / a == 1 / b
end

-- Track paired tables in `seen` so cycles and shared DAG nodes terminate.
local function deepEquals(a: any, b: any, seen: { [any]: { [any]: boolean } }, raw: boolean): boolean
	local typeA, typeB = nativeType(a), nativeType(b)
	if typeA ~= typeB then return false end
	if typeA == "number" then
		if raw then return exactNumberEqual(a, b) end
		return a == b or (a ~= a and b ~= b)
	elseif typeA == "vector" then
		if raw then
			local va: any, vb: any = a, b
			return exactNumberEqual(va.x, vb.x) and exactNumberEqual(va.y, vb.y) and exactNumberEqual(va.z, vb.z)
		end
		return a == b
	end
	if if raw then rawequal(a, b) else a == b then return true end
	if typeA == "buffer" then
		return bytes.equal(a, b :: buffer)
	elseif typeA ~= "table" then
		return raw and a == b
	end
	-- Under `raw = false`, tables with metatables compare via `==` / `__eq` and are not walked structurally.
	if not raw and (getmetatable(a :: any) ~= nil or getmetatable(b :: any) ~= nil) then return false end
	local seenA = seen[a]
	if seenA ~= nil then
		if seenA[b] then return true end
		seenA[b] = true
	else
		seen[a] = { [b] = true }
	end
	for key, value in next, a do
		if not deepEquals(value, rawget(b, key), seen, raw) then return false end
	end
	for key in next, b do
		if rawget(a, key) == nil then return false end
	end
	return true
end

--- Compares `a` and `b` for cycle-safe deep equality (`raw = true` distinguishes `-0.0` vs `+0.0` and walks raw fields).
function util.equal(a: any, b: any, raw: boolean?): boolean return deepEquals(a, b, {}, raw == true) end

local DEFAULT_COPY: CopyOptions = {}

--- Deep-copies tables and buffers using `next` so custom `__iter` metamethods are never invoked.
function util.copy(value: any, options: CopyOptions?): any
	local kind = nativeType(value)
	if kind == "buffer" then
		local b = buffer.create(buffer.len(value))
		buffer.copy(b, 0, value)
		return b
	elseif kind ~= "table" then
		return value
	end
	local o: CopyOptions = options or DEFAULT_COPY
	local keepMetatables = o.keepMetatables ~= false
	local map = o.map
	local limit = o.depth or 64
	local overflow = o.overflow
	local seen: { [any]: any } = {}

	local function walk(v: any, level: number): any
		local t = nativeType(v)
		if t == "buffer" then
			local b = buffer.create(buffer.len(v))
			buffer.copy(b, 0, v)
			return b
		elseif t ~= "table" then
			return v
		end
		local done = seen[v]
		if done ~= nil then return done end
		if map ~= nil then
			local handled, replacement = map(v)
			if handled then return replacement end
		end
		if keepMetatables and getmetatable(v) ~= nil then return v end
		if level >= limit then
			if overflow ~= nil then return overflow(v) end
			error(`copy: table exceeds {limit} levels`, 0)
		end
		local out = {}
		seen[v] = out
		for k, item in next, v do
			local ck = walk(k, level + 1)
			if ck ~= nil then out[ck] = walk(item, level + 1) end
		end
		return out
	end

	return walk(value, 0)
end

--- Returns the string keys of `tbl` in ascending lexicographic order (or `{}` when `tbl` is `nil`).
function util.sortedKeys(tbl: { [string]: any }?): { string }
	local keys: { string } = {}
	if tbl == nil then return keys end
	for k in next, tbl do
		if nativeType(k) == "string" then table.insert(keys, k) end
	end
	table.sort(keys)
	return keys
end

return table.freeze(util)
