--!strict
-- Boundary value cloning and validation for remotes (`serialize.remote`) and cloud stores (`serialize.datastore`).

local Datatypes = require("./datatypes")

export type RemoteOptions = {
	allowInstances: boolean?,
	mapInstance: ((inst: any) -> any)?,
	maxDepth: number?,
}

export type DataStoreOptions = {
	maxBytes: number?,
	label: string?,
}

local NON_REMOTE_TAGS: { [string]: boolean } = {
	RBXScriptSignal = true,
	RBXScriptConnection = true,
	Enums = true,
	Enum = true,
	Random = true,
}

local DEFAULT_REMOTE: RemoteOptions = {}
local DEFAULT_DATASTORE_MAX = 4 * 1024 * 1024

local serialize = {}

local function cloneParamState(v: any): any
	local tag = Datatypes.doubleTag(v)
	if tag == "RaycastParams" then
		local out = Datatypes.RaycastParams.new()
		out.FilterDescendantsInstances = v.FilterDescendantsInstances
		out.FilterType = v.FilterType
		out.IgnoreWater = v.IgnoreWater
		out.CollisionGroup = v.CollisionGroup
		out.RespectCanCollide = v.RespectCanCollide
		out.BruteForceAllSlow = v.BruteForceAllSlow
		return out
	elseif tag == "OverlapParams" then
		local out = Datatypes.OverlapParams.new()
		out.FilterDescendantsInstances = v.FilterDescendantsInstances
		out.FilterType = v.FilterType
		out.MaxParts = v.MaxParts
		out.CollisionGroup = v.CollisionGroup
		out.RespectCanCollide = v.RespectCanCollide
		out.BruteForceAllSlow = v.BruteForceAllSlow
		return out
	elseif tag == "CatalogSearchParams" then
		local out = Datatypes.CatalogSearchParams.new()
		out.SearchKeyword = v.SearchKeyword
		out.MinPrice = v.MinPrice
		out.MaxPrice = v.MaxPrice
		out.SortType = v.SortType
		out.SortAggregation = v.SortAggregation
		out.CategoryFilter = v.CategoryFilter
		out.SalesTypeFilter = v.SalesTypeFilter
		out.BundleTypes = v.BundleTypes
		out.AssetTypes = v.AssetTypes
		out.IncludeOffSale = v.IncludeOffSale
		out.CreatorName = v.CreatorName
		out.CreatorType = v.CreatorType
		out.CreatorId = v.CreatorId
		out.Limit = v.Limit
		return out
	end
	return v
end

--- Clones `value` across a `RemoteEvent` / `RemoteFunction` boundary, stripping user table metatables and mapping Instances.
function serialize.remote(value: any, opts: RemoteOptions?): any
	local o: RemoteOptions = opts or DEFAULT_REMOTE
	local allowInstances = o.allowInstances ~= false
	local mapInstance = o.mapInstance
	local maxDepth = o.maxDepth or 128
	local active: { [any]: boolean } = {}

	local function walk(v: any, depth: number): any
		local kind = type(v)
		if kind == "nil" or kind == "boolean" or kind == "number" or kind == "string" or kind == "vector" then
			return v
		elseif kind == "buffer" then
			local b = buffer.create(buffer.len(v))
			buffer.copy(b, 0, v)
			return b
		elseif kind == "function" or kind == "thread" then
			error(`Cannot pass {kind} across remote boundary`, 0)
		elseif kind ~= "table" then
			local ut = typeof(v)
			if ut == "Instance" then
				if not allowInstances then return nil end
				return if mapInstance ~= nil then mapInstance(v) else v
			elseif NON_REMOTE_TAGS[ut] then
				error(`Cannot pass {ut} across remote boundary`, 0)
			end
			return v
		end

		local tag = Datatypes.doubleTag(v)
		if tag ~= nil then
			if tag == "Instance" then
				if not allowInstances then return nil end
				return if mapInstance ~= nil then mapInstance(v) else v
			elseif NON_REMOTE_TAGS[tag] then
				error(`Cannot pass {tag} across remote boundary`, 0)
			end
			return cloneParamState(v)
		end

		if active[v] then error("Cannot pass cyclic tables across remote boundary", 0) end
		if depth > maxDepth then error(`Remote payload table exceeds maximum depth of {maxDepth}`, 0) end
		active[v] = true

		local count, intCount, strCount, maxInt = 0, 0, 0, 0
		for k in next, v do
			count += 1
			local kt = type(k)
			if kt == "string" then
				strCount += 1
			elseif kt == "number" and k == k and k >= 1 and k % 1 == 0 and k < 2 ^ 31 then
				intCount += 1
				if k > maxInt then maxInt = k end
			else
				active[v] = nil
				error(`Cannot pass table with {Datatypes.typeof(k)} keys across remote boundary`, 0)
			end
		end

		if strCount > 0 and intCount > 0 then
			active[v] = nil
			error("Cannot pass mixed array and dictionary table across remote boundary", 0)
		elseif intCount > 0 and maxInt ~= intCount then
			active[v] = nil
			error("Cannot pass sparse array with holes across remote boundary", 0)
		end

		-- Plain `{}` intentionally omits any metatable from `v` so OOP methods/metamethods never cross remotes.
		local out: { [any]: any } = if intCount > 0 then table.create(intCount) else {}
		if intCount > 0 then
			for i = 1, intCount do
				out[i] = walk(rawget(v, i), depth + 1)
			end
		else
			for k, item in next, v do
				out[k] = walk(item, depth + 1)
			end
		end

		active[v] = nil
		return out
	end

	return walk(value, 0)
end

--- Serializes a packed vararg tuple across a remote boundary while preserving trailing/interior `nil` slots.
function serialize.remoteTuple(opts: RemoteOptions?, ...: any): ({ any }, number)
	local n = select("#", ...)
	if n == 0 then return {}, 0 end
	local out = table.create(n)
	for i = 1, n do
		out[i] = serialize.remote(select(i, ...), opts)
	end
	return out, n
end

local function quotedJsonLen(text: string): number
	if string.find(text, '[%c"\\]') == nil then return #text + 2 end
	local extra = 2
	for i = 1, #text do
		local b = string.byte(text, i)
		if b == 34 or b == 92 or b == 8 or b == 9 or b == 10 or b == 12 or b == 13 then
			extra += 1
		elseif b < 32 or b == 127 then
			extra += 5
		end
	end
	return #text + extra
end

--- Validates and clones `value` as a strict JSON tree (shared DAG nodes become distinct tables) and returns `(clone, byteSize)`.
function serialize.datastore(value: any, opts: DataStoreOptions?): (any, number)
	local maxBytes = if opts ~= nil and opts.maxBytes ~= nil then opts.maxBytes else DEFAULT_DATASTORE_MAX
	local storeName = if opts ~= nil and opts.label ~= nil then opts.label else "data store"
	local ancestors: { [any]: boolean } = {}
	local tooDeep = false

	local function walk(v: any, depth: number): (any, number)
		if depth > 100 then tooDeep = true end
		local kind = type(v)
		if kind == "nil" then
			return nil, 4
		elseif kind == "boolean" then
			return v, if v then 4 else 5
		elseif kind == "buffer" then
			local len = buffer.len(v)
			local copy = buffer.create(len)
			buffer.copy(copy, 0, v)
			return copy, 35 + 4 * math.ceil(len / 3)
		elseif kind == "number" then
			if v ~= v or v == math.huge or v == -math.huge then
				error(`104: Cannot store NaN or infinity in {storeName}.`, 0)
			end
			-- JSON roundtripping canonicalizes `-0.0` to `0`.
			local norm = if v == 0 then 0 else v
			local numLen = if norm % 1 == 0 and math.abs(norm) < 2 ^ 53
				then #string.format("%d", norm)
				else #tostring(norm)
			return norm, numLen
		elseif kind == "string" then
			if utf8.len(v) == nil then
				error(`104: Cannot store string in {storeName}. Data stores can only accept valid UTF-8 characters.`, 0)
			end
			return v, quotedJsonLen(v)
		elseif kind ~= "table" then
			error(`103: {Datatypes.typeof(v)} is not allowed in data stores.`, 0)
		end

		local named = Datatypes.typeof(v)
		if named ~= "table" then
			error(`103: {named} is not allowed in data stores.`, 0)
		elseif getmetatable(v) ~= nil then
			error("103: Tables with metatables are not allowed in data stores.", 0)
		elseif ancestors[v] then
			error(`104: Cannot store cyclic tables in {storeName}.`, 0)
		end

		ancestors[v] = true
		local count, strings, maxInt, totalBytes = 0, 0, 0, 2
		local nextDepth = depth + 1
		local out: { [any]: any } = {}

		for key, item in next, v do
			count += 1
			if type(key) == "string" then
				strings += 1
				if utf8.len(key) == nil then
					ancestors[v] = nil
					error(
						`104: Cannot store Dictionary in {storeName}. Data stores can only accept valid UTF-8 characters.`,
						0
					)
				end
				totalBytes += quotedJsonLen(key) + 1
			elseif type(key) == "number" and key == key and key >= 1 and key % 1 == 0 and key < 2 ^ 31 then
				if key > maxInt then maxInt = key end
			else
				ancestors[v] = nil
				error(`104: Cannot store a table with {Datatypes.typeof(key)} keys in {storeName}.`, 0)
			end
			local clonedItem, itemBytes = walk(item, nextDepth)
			out[key] = clonedItem
			totalBytes += itemBytes
		end

		ancestors[v] = nil
		if strings > 0 and strings < count then
			error(`104: Cannot store mixed tables in {storeName}.`, 0)
		elseif strings == 0 and count > 0 and maxInt ~= count then
			error(`104: Cannot store arrays with holes in {storeName}.`, 0)
		end
		if count > 1 then
			totalBytes += count - 1
		end
		return out, totalBytes
	end

	local cloned, byteSize = walk(value, 0)
	if tooDeep then error(`104: Cannot store value in {storeName}: nesting too deep`, 0) end
	if byteSize > maxBytes then
		if maxBytes == DEFAULT_DATASTORE_MAX then error("105: Serialized value exceeds 4MB limit.", 0) end
		error(`105: Serialized value ({byteSize} bytes) exceeds {maxBytes}-byte limit in {storeName}.`, 0)
	end
	return cloned, byteSize
end

--- Deep-clones an already-validated JSON/buffer tree so reads never alias backing store tables.
function serialize.cloneTree(value: any): any
	local kind = type(value)
	if kind == "buffer" then
		local b = buffer.create(buffer.len(value))
		buffer.copy(b, 0, value)
		return b
	elseif kind ~= "table" then
		return value
	end
	local out: { [any]: any } = {}
	for k, item in next, value do
		out[k] = serialize.cloneTree(item)
	end
	return out
end

return table.freeze(serialize)
