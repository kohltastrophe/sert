--!strict
-- Shared internal utilities: virtual clock constants, stack frame helpers, deep equality, and deep copy.

local bytes = require("./bytes")

export type CopyOptions = {
	keepMetatables: boolean?,
	map: ((value: any) -> (boolean, any))?,
	depth: number?,
	overflow: ((value: any) -> any)?,
}

local SELF_SOURCE: string = debug.info(1, "s") or ""
local ROOT: string = string.match(SELF_SOURCE, "^(.*)[/\\%.]util") or SELF_SOURCE

local util = {
	-- Virtual times within EPSILON count as equal to absorb fixed-step rounding error.
	EPSILON = 1e-9,
	-- Unix timestamp at virtual time 0.
	UNIX_EPOCH = 1700000000,
}

--- Returns `true` when `chunk` (`debug.info(level, "s")`) belongs to `sert` or is `[C]`.
function util.internal(chunk: string): boolean
	if chunk == ROOT or chunk == "[C]" then return true end
	return string.sub(chunk, 1, #ROOT) == ROOT
		and string.find(string.sub(chunk, #ROOT + 1, #ROOT + 1), "^[/\\%.]") ~= nil
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

-- Track paired tables in `seen` so cycles and shared DAG nodes terminate.
local function deepEquals(a: any, b: any, seen: { [any]: { [any]: boolean } }, raw: boolean): boolean
	if if raw then rawequal(a, b) else a == b then return true end
	local typeA, typeB = type(a), type(b)
	if typeA ~= typeB then
		return false
	elseif typeA == "number" then
		return a ~= a and b ~= b -- NaN
	elseif typeA == "buffer" then
		return bytes.equal(a, b :: buffer)
	elseif typeA ~= "table" then
		return raw and a == b -- rawEq: userdata and vectors by their own __eq
	end
	-- Under `sert.eq` (`raw = false`), tables with metatables have object identity (`==` / `__eq`) and are not walked.
	if not raw and (getmetatable(a :: any) ~= nil or getmetatable(b :: any) ~= nil) then return false end
	local seenA = seen[a]
	if seenA ~= nil then
		if seenA[b] then return true end
		seenA[b] = true
	else
		seen[a] = { [b] = true }
	end
	if raw then
		for key, value in next, a do
			if not deepEquals(value, rawget(b, key), seen, true) then return false end
		end
		for key in next, b do
			if rawget(a, key) == nil then return false end
		end
		return true
	end
	for key, value in a :: { [any]: any } do
		if not deepEquals(value, b[key], seen, false) then return false end
	end
	for key in b :: { [any]: any } do
		if a[key] == nil then return false end
	end
	return true
end

--- Compares `a` and `b` for cycle-safe deep equality (`raw = true` ignores metatables and `__eq`).
function util.equal(a: any, b: any, raw: boolean): boolean return deepEquals(a, b, {}, raw) end

local DEFAULT_COPY: CopyOptions = {}

--- Deep-copies tables and buffers so callers cannot alias internal state across doubles.
function util.copy(value: any, options: CopyOptions?): any
	local kind = type(value)
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
		local t = type(v)
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
		for k, item in v do
			local ck = walk(k, level + 1)
			if ck ~= nil then out[ck] = walk(item, level + 1) end
		end
		return out
	end

	return walk(value, 0)
end

return table.freeze(util)
