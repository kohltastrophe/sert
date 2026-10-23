--!strict
-- Value formatting (`repr`), structural diffing (`diff`), and JSON encoding/decoding (`json`, `jsonDecode`).

local format = {}
local BUFFER_BYTES = 32
local KEY_RANK: { [string]: number } = { number = 1, string = 2 }

-- Sort numbers ascending, then strings, then other keys by type and tostring.
local function keyBefore(a: any, b: any): boolean
	local rankA, rankB = KEY_RANK[type(a)] or 3, KEY_RANK[type(b)] or 3
	if rankA ~= rankB then
		return rankA < rankB
	elseif rankA < 3 then
		return a < b
	end
	return `{type(a)}:{tostring(a)}` < `{type(b)}:{tostring(b)}`
end

-- Use `next` instead of generalized iteration so `__iter` metamethods cannot error or loop while formatting.
local function sortedKeys(value: { [any]: any }): { any }
	local keys = {}
	for key in next, value do
		table.insert(keys, key)
	end
	table.sort(keys, keyBefore)
	return keys
end

type Limits = { depth: number, items: number }
local DEFAULT_LIMITS: Limits = { depth = 3, items = 8 }
local DIFF_LIMITS: Limits = { depth = 5, items = 16 }

-- Returns the `__type` tag when `value` is a datatype double with a `__tostring` metamethod.
local function doubleType(value: any): string?
	local meta = getmetatable(value)
	if type(meta) ~= "table" or rawget(meta, "__tostring") == nil then return nil end
	local tag = rawget(meta, "__type")
	return if type(tag) == "string" then tag else nil
end

local function render(value: any, level: number, limits: Limits, focus: { any }?, focusIndex: number): string
	local valueType = type(value)
	local double = if valueType == "table" then doubleType(value) else nil
	local doubleText: string? = nil
	if double ~= nil then
		local ok, text = pcall(tostring, value)
		doubleText = if ok and type(text) == "string" then text else nil
	end
	if valueType == "string" then
		return string.format("%q", value)
	elseif valueType == "buffer" then
		local length = buffer.len(value)
		local parts = table.create(math.min(length, BUFFER_BYTES))
		for offset = 0, math.min(length, BUFFER_BYTES) - 1 do
			parts[offset + 1] = string.format("%02x", buffer.readu8(value, offset))
		end
		local more = if length > BUFFER_BYTES then ` … {length - BUFFER_BYTES} more` else ""
		return `buffer({length}){if length > 0 then " " else ""}{table.concat(parts, " ")}{more}`
	elseif valueType == "vector" or valueType == "userdata" or doubleText ~= nil then
		-- a datatype's tostring is a bare comma list, so name its type; these describe themselves already
		local kind = double or typeof(value)
		local text = doubleText or tostring(value)
		return if kind == "Instance"
				or kind == "EnumItem"
				or kind == "Enum"
				or kind == "userdata"
			then text
			else `{kind}({text})`
	elseif valueType ~= "table" then
		return tostring(value)
	end
	-- a table on the focus path (format.diff's path to a difference) is always opened, and always shows that key
	local onPath = focus ~= nil and focus[focusIndex] ~= nil
	if level > limits.depth and not onPath then return "{…}" end
	local focusKey = if onPath then (focus :: { any })[focusIndex] else nil
	local parts, count, elided, arrayIndex = {}, 0, false, 1
	for _, key in sortedKeys(value) do
		local isFocus = onPath and rawequal(key, focusKey)
		if count >= limits.items and not isFocus then
			if not elided then
				elided = true
				table.insert(parts, "…")
			end
			continue
		end
		count += 1
		local prefix: string
		if key == arrayIndex and not elided then
			arrayIndex += 1
			prefix = "" -- array part: hide ordinal keys
		elseif type(key) == "string" and string.match(key, "^[_%a][_%w]*$") ~= nil then
			prefix = `{key} = `
		else
			prefix = `[{render(key, level + 1, limits, nil, 1)}] = `
		end
		local item = rawget(value, key)
		local text = if isFocus
			then render(item, level + 1, limits, focus, focusIndex + 1)
			else render(item, if onPath then math.min(level + 1, limits.depth) else level + 1, limits, nil, 1)
		table.insert(parts, prefix .. text)
	end
	return if #parts == 0 then "{}" else "{ " .. table.concat(parts, ", ") .. " }"
end

--- Formats `value` as compact Luau syntax for failure messages and traces.
function format.repr(value: any): string return render(value, 1, DEFAULT_LIMITS, nil, 1) end

local function pathText(path: { any }): string
	local parts = {}
	for _, key in path do
		table.insert(
			parts,
			if type(key) == "string" and string.match(key, "^[_%a][_%w]*$") ~= nil
				then `.{key}`
				else `[{render(key, 1, DEFAULT_LIMITS, nil, 1)}]`
		)
	end
	return table.concat(parts)
end

-- Finds the path and note for the first difference between `a` and `b`.
local function firstDifference(
	a: any,
	b: any,
	path: { any },
	seen: { [any]: { [any]: boolean } },
	raw: boolean
): ({ any }?, string?)
	if if raw then rawequal(a, b) else a == b then return nil, nil end
	local typeA, typeB = type(a), type(b)
	if typeA ~= typeB then
		return path, nil
	elseif typeA == "number" then
		return if a ~= a and b ~= b then nil else path, nil
	elseif typeA == "buffer" then
		local lengthA, lengthB = buffer.len(a), buffer.len(b)
		for offset = 0, math.min(lengthA, lengthB) - 1 do
			if buffer.readu8(a, offset) ~= buffer.readu8(b, offset) then
				return path, `first different byte at offset {offset}`
			end
		end
		return if lengthA ~= lengthB then path else nil,
			if lengthA ~= lengthB then `lengths {lengthA} and {lengthB}` else nil
	elseif typeA ~= "table" then
		return if raw and a == b then nil else path, nil
	end
	if not raw and (getmetatable(a) ~= nil or getmetatable(b) ~= nil) then
		if doubleType(a) ~= nil or doubleType(b) ~= nil then return path, nil end
		return path,
			"a table with a metatable compares by identity or __eq; sert.rawEq and toRawEqual compare raw fields"
	end
	local seenA = seen[a]
	if seenA ~= nil then
		if seenA[b] then return nil, nil end
		seenA[b] = true
	else
		seen[a] = { [b] = true }
	end
	local keys, present: { [any]: boolean } = sortedKeys(b), {}
	for _, key in keys do
		present[key] = true
	end
	for _, key in sortedKeys(a) do
		if not present[key] then table.insert(keys, key) end
	end
	table.sort(keys, keyBefore)
	for _, key in keys do
		table.insert(path, key)
		local where, note = firstDifference(
			if raw then rawget(a, key) else a[key],
			if raw then rawget(b, key) else b[key],
			path,
			seen,
			raw
		)
		if where ~= nil then return where, note end
		table.remove(path)
	end
	return nil, nil
end

--- Returns the path and values of the first difference between `actual` and `expected`, or `nil` when equal.
function format.diff(actual: any, expected: any, raw: boolean?): string?
	local path, note = firstDifference(actual, expected, {}, {}, raw == true)
	if path == nil then return nil end
	local here, there = actual, expected
	for _, key in path do
		here = if raw then rawget(here, key) else here[key]
		there = if raw then rawget(there, key) else there[key]
	end
	local where = if #path > 0 then `at {pathText(path)}: ` else ""
	local lines = {
		`{where}expected {format.repr(there)}, got {format.repr(here)}{if note then ` ({note})` else ""}`,
	}
	if #path > 0 then
		table.insert(lines, `  expected: {render(expected, 1, DIFF_LIMITS, path, 1)}`)
		table.insert(lines, `  actual:   {render(actual, 1, DIFF_LIMITS, path, 1)}`)
	end
	return table.concat(lines, "\n")
end

--- Formats a raised error value into diagnostic text without throwing if `__tostring` fails.
function format.errorText(err: any): string
	local ok, text = pcall(function(): any
		if type(err) == "table" then
			local meta = getmetatable(err)
			if not (type(meta) == "table" and meta.__tostring ~= nil) then return format.repr(err) end
		end
		return tostring(err)
	end)
	if ok and type(text) == "string" then return text end
	return `<{typeof(err)} error; rendering it raised: {if type(text) == "string" then text else typeof(text)}>`
end

-- Weak set of tables that should encode as `[]` even when empty.
local arrays: { [any]: boolean } = setmetatable({}, { __mode = "k" }) :: any

--- Marks `list` so `format.json` encodes it as `[]` even when empty, and returns `list`.
function format.array<T>(list: T): T
	arrays[list] = true
	return list
end

local ESCAPES: { [string]: string } = {
	['"'] = '\\"',
	["\\"] = "\\\\",
	["\b"] = "\\b",
	["\f"] = "\\f",
	["\n"] = "\\n",
	["\r"] = "\\r",
	["\t"] = "\\t",
}
local UNESCAPES: { [string]: string } = { b = "\b", f = "\f", n = "\n", r = "\r", t = "\t" }

local function quote(text: string): string
	return '"'
		.. string.gsub(
			text,
			'[%c"\\]',
			function(char: string): string return ESCAPES[char] or string.format("\\u%04x", string.byte(char)) end
		)
		.. '"'
end

--- Options for `format.json` and `format.jsonDecode`. `strict = true` enforces `HttpService:JSONEncode` rules.
export type JsonOptions = {
	strict: boolean?,
	buffer: ((value: buffer) -> string)?,
	revive: ((object: { [string]: any }) -> any)?,
	prefix: string?,
}

local LENIENT: JsonOptions = {}

local function encodeJson(value: any, depth: number, options: JsonOptions, seen: { [any]: boolean }): string
	local isStrict = options.strict == true
	local function fail(message: string): never error(`{options.prefix or ""}{message}`, 0) end
	if depth > 100 then return if isStrict then fail("nesting too deep") else "null" end
	local kind = type(value)
	if value == nil then
		return "null"
	elseif kind == "boolean" then
		return if value then "true" else "false"
	elseif kind == "number" then
		if value ~= value or value == math.huge or value == -math.huge then
			return if isStrict then fail("can't convert a non-finite number to JSON") else "null"
		elseif value % 1 == 0 and math.abs(value) < 2 ^ 53 then
			return string.format("%d", value)
		end
		return if isStrict then tostring(value) else string.format("%.17g", value)
	elseif kind == "string" then
		return quote(value)
	elseif kind == "buffer" and options.buffer ~= nil then
		return options.buffer(value)
	elseif kind == "table" then
		if seen[value] then return if isStrict then fail("nesting too deep") else "null" end
		seen[value] = true
		local arrayLen: number? = nil
		if isStrict then
			local n, count, maxInt, allPosInt = #value, 0, 0, true
			for k in next, value do
				count += 1
				if type(k) == "number" and k >= 1 and k % 1 == 0 then
					maxInt = math.max(maxInt, k)
				else
					allPosInt = false
				end
			end
			if count == n or (count > 0 and allPosInt and maxInt <= 1024) then arrayLen = math.max(n, maxInt) end
		elseif value[1] ~= nil or arrays[value] then
			arrayLen = #value
		end
		if arrayLen ~= nil then
			local parts = table.create(arrayLen)
			for index = 1, arrayLen do
				parts[index] = encodeJson(value[index], depth + 1, options, seen)
			end
			seen[value] = nil
			return "[" .. table.concat(parts, ",") .. "]"
		end
		local entries: { { key: string, item: any } } = {}
		for key: any, item in next, value do
			if isStrict and type(key) ~= "string" then
				fail("can't convert a table with mixed or non-string keys to JSON")
			end
			table.insert(entries, { key = tostring(key), item = item })
		end
		table.sort(
			entries,
			function(a: { key: string, item: any }, b: { key: string, item: any }) return a.key < b.key end
		)
		local parts = table.create(#entries)
		for index, entry in entries do
			parts[index] = quote(entry.key) .. ":" .. encodeJson(entry.item, depth + 1, options, seen)
		end
		seen[value] = nil
		return "{" .. table.concat(parts, ",") .. "}"
	end
	return if isStrict then fail(`can't convert a {typeof(value)} to JSON`) else quote(tostring(value))
end

--- Encodes `value` as JSON with sorted object keys. Pass `options.strict = true` to enforce `HttpService:JSONEncode` rules.
function format.json(value: any, options: JsonOptions?): string return encodeJson(value, 0, options or LENIENT, {}) end

--- Decodes JSON `text` into Luau values, passing decoded objects through `options.revive` when provided.
function format.jsonDecode(text: string, options: JsonOptions?): any
	local o = options or LENIENT
	local revive = o.revive
	local function fail(message: string): never error(`{o.prefix or ""}{message}`, 0) end
	local at = 1
	local function skip() at = string.find(text, "[^ \t\r\n]", at) or #text + 1 end
	local function expect(literal: string)
		if string.sub(text, at, at + #literal - 1) ~= literal then fail(`invalid JSON at character {at}`) end
		at += #literal
	end
	local parseValue: () -> any
	local function parseString(): string
		expect('"')
		local parts = {}
		while true do
			local stop = string.find(text, '["\\]', at)
			if stop == nil then return fail("unterminated string") end
			table.insert(parts, string.sub(text, at, stop - 1))
			at = stop
			if string.sub(text, at, at) == '"' then
				at += 1
				return table.concat(parts)
			end
			local escape = string.sub(text, at + 1, at + 1)
			if escape == "u" then
				local hex = string.sub(text, at + 2, at + 5)
				if string.match(hex, "^%x%x%x%x$") == nil then fail("invalid \\u escape") end
				local code = tonumber(hex, 16) :: number
				at += 6
				if code >= 0xD800 and code <= 0xDBFF and string.sub(text, at, at + 1) == "\\u" then
					local lowHex = string.sub(text, at + 2, at + 5)
					if string.match(lowHex, "^%x%x%x%x$") ~= nil then
						local low = tonumber(lowHex, 16)
						if low ~= nil and low >= 0xDC00 and low <= 0xDFFF then
							at += 6
							code = 0x10000 + (code - 0xD800) * 0x400 + (low - 0xDC00)
						end
					end
				end
				table.insert(parts, utf8.char(code))
			else
				table.insert(parts, UNESCAPES[escape] or escape)
				at += 2
			end
		end
	end
	function parseValue(): any
		skip()
		local ch = string.sub(text, at, at)
		if ch == "{" then
			at += 1
			local object = {}
			skip()
			if string.sub(text, at, at) == "}" then
				at += 1
				return if revive ~= nil then revive(object) else object
			end
			while true do
				skip()
				local key = parseString()
				skip()
				expect(":")
				object[key] = parseValue()
				skip()
				if string.sub(text, at, at) == "}" then
					at += 1
					break
				end
				expect(",")
			end
			return if revive ~= nil then revive(object) else object
		elseif ch == "[" then
			at += 1
			local array = {}
			skip()
			if string.sub(text, at, at) == "]" then
				at += 1
				return array
			end
			while true do
				table.insert(array, parseValue())
				skip()
				if string.sub(text, at, at) == "]" then
					at += 1
					break
				end
				expect(",")
			end
			return array
		elseif ch == '"' then
			return parseString()
		elseif ch == "t" then
			expect("true")
			return true
		elseif ch == "f" then
			expect("false")
			return false
		elseif ch == "n" then
			expect("null")
			return nil
		end
		local number = string.match(text, "^-?%d+%.?%d*[eE]?[-+]?%d*", at)
		if number == nil or tonumber(number) == nil then fail(`invalid JSON at character {at}`) end
		at += #(number :: string)
		return tonumber(number)
	end
	local value = parseValue()
	skip()
	if at <= #text then fail("trailing characters after JSON value") end
	return value
end

return format
