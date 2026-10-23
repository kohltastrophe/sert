--!strict
-- Buffer hex formatting, parsing, and byte-level equality helpers.

local bytes = {}

--- Formats `count` bytes of `b` from `offset` (default: all bytes) as lowercase hex.
function bytes.hex(b: buffer, offset: number?, count: number?): string
	local start = offset or 0
	local length = count or (buffer.len(b) - start)
	local parts = table.create(length)
	for index = 0, length - 1 do
		parts[index + 1] = string.format("%02x", buffer.readu8(b, start + index))
	end
	return table.concat(parts)
end

--- Parses hex `text` into a buffer, ignoring whitespace.
function bytes.fromHex(text: string): buffer
	local clean = string.gsub(text, "%s", "")
	if #clean % 2 ~= 0 then error("bytes.fromHex: hex text must have an even length", 2) end
	local b = buffer.create(#clean // 2)
	for index = 0, #clean // 2 - 1 do
		local byte = tonumber(string.sub(clean, index * 2 + 1, index * 2 + 2), 16)
		if byte == nil then error(`bytes.fromHex: invalid hex at {index * 2 + 1}`, 2) end
		buffer.writeu8(b, index, byte)
	end
	return b
end

--- Returns `true` when `a` and `b` hold the same bytes.
function bytes.equal(a: buffer, b: buffer): boolean
	return buffer.len(a) == buffer.len(b) and buffer.tostring(a) == buffer.tostring(b)
end

--- Asserts that `actual` holds the same bytes as `expected` (a buffer or hex string) and returns `actual`.
function bytes.assertBytes(actual: buffer, expected: buffer | string, why: string?): buffer
	if type(expected) == "buffer" then
		if bytes.equal(actual, expected) then return actual end
		error(`{why or "bytes differ"}: expected {bytes.hex(expected)}, got {bytes.hex(actual)}`, 2)
	end
	local actualHex = bytes.hex(actual)
	local clean = string.lower((string.gsub(expected, "%s", "")))
	if actualHex ~= clean then error(`{why or "bytes differ"}: expected {clean}, got {actualHex}`, 2) end
	return actual
end

return bytes
