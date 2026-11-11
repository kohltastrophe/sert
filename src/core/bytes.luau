--!strict
-- Buffer and string hex formatting, parsing, byte equality, and byte-offset diffing.

local bytes = {}

local DIFF_WINDOW = 8

--- Formats `value` (or `count` bytes from `offset`, 0-based) as lowercase hexadecimal.
function bytes.hex(value: buffer | string, offset: number?, count: number?): string
	if type(value) == "string" then
		local total = #value
		local start = offset or 0
		local length = if count ~= nil then count else math.max(0, total - start)
		if start < 0 or length < 0 or start + length > total then
			error(`bytes.hex: range [{start}, {start + length}) out of bounds for {total}-byte string`, 2)
		end
		local parts = table.create(length, "")
		for index = 0, length - 1 do
			parts[index + 1] = string.format("%02x", string.byte(value, start + index + 1))
		end
		return table.concat(parts)
	elseif type(value) == "buffer" then
		local total = buffer.len(value)
		local start = offset or 0
		local length = if count ~= nil then count else math.max(0, total - start)
		if start < 0 or length < 0 or start + length > total then
			error(`bytes.hex: range [{start}, {start + length}) out of bounds for {total}-byte buffer`, 2)
		end
		local parts = table.create(length, "")
		for index = 0, length - 1 do
			parts[index + 1] = string.format("%02x", buffer.readu8(value, start + index))
		end
		return table.concat(parts)
	end
	error(`bytes.hex: expected buffer or string, got {typeof(value)}`, 2)
end

--- Parses hexadecimal `hex` into a `buffer`, ignoring ASCII whitespace.
function bytes.fromHex(hex: string): buffer
	if type(hex) ~= "string" then error(`bytes.fromHex: expected string, got {typeof(hex)}`, 2) end
	local clean = string.gsub(hex, "%s+", "")
	if #clean % 2 ~= 0 then error("bytes.fromHex: hex text must have an even length", 2) end
	local byteCount = #clean // 2
	local out = buffer.create(byteCount)
	for index = 0, byteCount - 1 do
		local byte = tonumber(string.sub(clean, index * 2 + 1, index * 2 + 2), 16)
		if byte == nil then error(`bytes.fromHex: invalid hex at character {index * 2 + 1}`, 2) end
		buffer.writeu8(out, index, byte)
	end
	return out
end

--- Returns `true` when `a` and `b` hold identical byte sequences.
function bytes.equal(a: buffer, b: buffer): boolean
	return buffer.len(a) == buffer.len(b) and buffer.tostring(a) == buffer.tostring(b)
end

local function windowHex(b: buffer, center: number): string
	local len = buffer.len(b)
	if len == 0 then return "<empty>" end
	local start = math.max(0, center - 2)
	local stop = math.min(len, start + DIFF_WINDOW)
	local parts: { string } = {}
	if start > 0 then table.insert(parts, "…") end
	for offset = start, stop - 1 do
		local hx = string.format("%02x", buffer.readu8(b, offset))
		table.insert(parts, if offset == center then `[{hx}]` else hx)
	end
	if stop < len then table.insert(parts, "…") end
	return table.concat(parts, " ")
end

--- Describes the first differing byte offset and lengths between `a` and `b`, or returns `""` when equal.
function bytes.diff(a: buffer, b: buffer): string
	local lenA, lenB = buffer.len(a), buffer.len(b)
	local shared = math.min(lenA, lenB)
	for offset = 0, shared - 1 do
		local byteA, byteB = buffer.readu8(a, offset), buffer.readu8(b, offset)
		if byteA ~= byteB then
			local lenNote = if lenA ~= lenB then ` (lengths {lenA} and {lenB})` else ""
			return string.format(
				"first different byte at offset %d: got 0x%02x (%s), expected 0x%02x (%s)%s",
				offset,
				byteA,
				windowHex(a, offset),
				byteB,
				windowHex(b, offset),
				lenNote
			)
		end
	end
	if lenA ~= lenB then return `buffer lengths differ: got {lenA} bytes, expected {lenB} bytes` end
	return ""
end

return table.freeze(bytes)
