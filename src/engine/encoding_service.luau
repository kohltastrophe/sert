--!strict
-- Headless `EncodingService` and `HttpService` engine doubles (reversible zstd-framed RLE, exact Base64, deterministic hashes, strict JSON, and seeded GUIDs).

local bytes = require("../core/bytes")
local format = require("../core/format")

local EncodingService = {}

local MAGIC = { 0x28, 0xB5, 0x2F, 0xFD }
local HEADER = 8
local ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local BASE64_DECODE: { [number]: number } = {}
for idx = 1, #ALPHABET do
	BASE64_DECODE[string.byte(ALPHABET, idx)] = idx - 1
end

local HASH_SIZES: { [string]: number } = {
	Blake2b = 32,
	["Enum.HashAlgorithm.Blake2b"] = 32,
	Blake3 = 32,
	["Enum.HashAlgorithm.Blake3"] = 32,
	Md5 = 16,
	["Enum.HashAlgorithm.Md5"] = 16,
	Sha1 = 20,
	["Enum.HashAlgorithm.Sha1"] = 20,
	Sha256 = 32,
	["Enum.HashAlgorithm.Sha256"] = 32,
}

local function checkAlgorithm(algorithm: any)
	if algorithm ~= "Zstd" and tostring(algorithm) ~= "Enum.CompressionAlgorithm.Zstd" then
		error(`EncodingService double: unsupported algorithm {tostring(algorithm)}`, 3)
	end
end

local function checkHashAlgorithm(algorithm: any): (number, number)
	local key = tostring(algorithm)
	local size = HASH_SIZES[key]
	if size == nil then error(`EncodingService double: unsupported hash algorithm {key}`, 3) end
	local tag = 0
	for i = 1, #key do
		tag = bit32.bxor(tag, string.byte(key, i)) * 16777619
	end
	return size, tag
end

-- Four ChaCha-style double rounds over 8 words diffuse every input bit across all output lanes.
local function mixState(s: { number })
	for _ = 1, 4 do
		s[1] = bit32.band(s[1] + s[5], 0xFFFFFFFF)
		s[4] = bit32.lrotate(bit32.bxor(s[4], s[1]), 16)
		s[3] = bit32.band(s[3] + s[7], 0xFFFFFFFF)
		s[2] = bit32.lrotate(bit32.bxor(s[2], s[3]), 12)
		s[1] = bit32.band(s[1] + s[5], 0xFFFFFFFF)
		s[4] = bit32.lrotate(bit32.bxor(s[4], s[1]), 8)
		s[3] = bit32.band(s[3] + s[7], 0xFFFFFFFF)
		s[2] = bit32.lrotate(bit32.bxor(s[2], s[3]), 7)

		s[5] = bit32.band(s[5] + s[2], 0xFFFFFFFF)
		s[8] = bit32.lrotate(bit32.bxor(s[8], s[5]), 16)
		s[7] = bit32.band(s[7] + s[4], 0xFFFFFFFF)
		s[6] = bit32.lrotate(bit32.bxor(s[6], s[7]), 12)
		s[5] = bit32.band(s[5] + s[2], 0xFFFFFFFF)
		s[8] = bit32.lrotate(bit32.bxor(s[8], s[5]), 8)
		s[7] = bit32.band(s[7] + s[4], 0xFFFFFFFF)
		s[6] = bit32.lrotate(bit32.bxor(s[6], s[7]), 7)

		local t = s[5]
		s[5], s[6], s[7], s[8] = s[6], s[7], s[8], t
	end
end

local function hashBuffer(input: buffer, algorithm: any): buffer
	local size, tag = checkHashAlgorithm(algorithm)
	local n = buffer.len(input)
	local s = {
		bit32.bxor(0x6A09E667, tag),
		bit32.bxor(0xBB67AE85, n),
		0x3C6EF372,
		0xA54FF53A,
		0x510E527F,
		0x9B05688C,
		0x1F83D9AB,
		0x5BE0CD19,
	}
	local i = 0
	while i + 4 <= n do
		local w = buffer.readu32(input, i)
		local lane = (i // 4) % 8 + 1
		s[lane] = bit32.bxor(s[lane], w)
		mixState(s)
		i += 4
	end
	local tail = 0x80
	for j = n - 1, i, -1 do
		tail = tail * 256 + buffer.readu8(input, j)
	end
	s[1] = bit32.bxor(s[1], tail)
	s[2] = bit32.bxor(s[2], n)
	mixState(s)
	mixState(s)

	local full = buffer.create(32)
	for k = 1, 8 do
		buffer.writeu32(full, (k - 1) * 4, s[k])
	end
	if size == 32 then return full end
	local out = buffer.create(size)
	buffer.copy(out, 0, full, 0, size)
	return out
end

--- Encodes `b` as standard padded Base64 text.
function EncodingService.base64Encode(b: buffer): string
	local n = buffer.len(b)
	local parts = table.create((n + 2) // 3)
	for i = 0, n - 1, 3 do
		local remaining = n - i
		local x = buffer.readu8(b, i) * 65536
			+ (if remaining > 1 then buffer.readu8(b, i + 1) * 256 else 0)
			+ (if remaining > 2 then buffer.readu8(b, i + 2) else 0)
		local c1, c2 = x // 262144 + 1, x // 4096 % 64 + 1
		local c3, c4 = x // 64 % 64 + 1, x % 64 + 1
		table.insert(
			parts,
			string.sub(ALPHABET, c1, c1)
				.. string.sub(ALPHABET, c2, c2)
				.. (if remaining > 1 then string.sub(ALPHABET, c3, c3) else "=")
				.. (if remaining > 2 then string.sub(ALPHABET, c4, c4) else "=")
		)
	end
	return table.concat(parts)
end

--- Decodes strict padded Base64 `text`, returning `nil` when `text` is malformed.
function EncodingService.base64Decode(text: string): buffer?
	local n = #text
	if n % 4 ~= 0 then return nil end
	local padding = if n >= 2 and string.sub(text, -2) == "=="
		then 2
		elseif n >= 1 and string.sub(text, -1) == "=" then 1
		else 0
	local outLen = n // 4 * 3 - padding
	if outLen < 0 then return nil end
	local out = buffer.create(outLen)
	local at = 0
	local padStart = n - padding
	for i = 1, n, 4 do
		local x = 0
		for j = 0, 3 do
			local pos = i + j
			local b = string.byte(text, pos)
			local value = 0
			if b == 61 then
				if pos <= padStart then return nil end
			else
				local found = BASE64_DECODE[b]
				if found == nil then return nil end
				value = found
			end
			x = x * 64 + value
		end
		if at < outLen then
			buffer.writeu8(out, at, bit32.rshift(x, 16))
			at += 1
		end
		if at < outLen then
			buffer.writeu8(out, at, bit32.band(bit32.rshift(x, 8), 0xFF))
			at += 1
		end
		if at < outLen then
			buffer.writeu8(out, at, bit32.band(x, 0xFF))
			at += 1
		end
	end
	return out
end

-- Control byte `c < 128` copies `c + 1` literal bytes; `c >= 128` repeats the next byte `c - 125` times.
local function compress(input: buffer): buffer
	local n = buffer.len(input)
	local out = buffer.create(HEADER + n + n // 128 + 2)
	for i, byte in MAGIC do
		buffer.writeu8(out, i - 1, byte)
	end
	buffer.writeu32(out, 4, n)
	local at, i, literalStart = HEADER, 0, 0
	local function flushLiterals(stop: number)
		while literalStart < stop do
			local count = math.min(128, stop - literalStart)
			buffer.writeu8(out, at, count - 1)
			buffer.copy(out, at + 1, input, literalStart, count)
			at += count + 1
			literalStart += count
		end
	end
	while i < n do
		local byte = buffer.readu8(input, i)
		local run = 1
		while i + run < n and run < 130 and buffer.readu8(input, i + run) == byte do
			run += 1
		end
		if run >= 3 then
			flushLiterals(i)
			buffer.writeu8(out, at, run + 125)
			buffer.writeu8(out, at + 1, byte)
			at += 2
			i += run
			literalStart = i
		else
			i += run
		end
	end
	flushLiterals(n)
	local result = buffer.create(at)
	buffer.copy(result, 0, out, 0, at)
	return result
end

local function declared(input: buffer): number?
	if buffer.len(input) < HEADER then return nil end
	for i, byte in MAGIC do
		if buffer.readu8(input, i - 1) ~= byte then return nil end
	end
	local size = buffer.readu32(input, 4)
	return if size <= 1073741824 then size else nil
end

local function decompress(input: buffer): buffer
	local size = declared(input)
	if size == nil then error("EncodingService double: not a compressed buffer", 3) end
	local out = buffer.create(size)
	local at, i, n = 0, HEADER, buffer.len(input)
	while i < n do
		local control = buffer.readu8(input, i)
		if control < 128 then
			local count = control + 1
			if i + 1 + count > n or at + count > size then error("EncodingService double: corrupt literal run", 3) end
			buffer.copy(out, at, input, i + 1, count)
			at += count
			i += count + 1
		else
			local count = control - 125
			if i + 2 > n or at + count > size then error("EncodingService double: corrupt repeat run", 3) end
			buffer.fill(out, at, buffer.readu8(input, i + 1), count)
			at += count
			i += 2
		end
	end
	if at ~= size then error("EncodingService double: decompressed size differs from the declared size", 3) end
	return out
end

--- Creates a headless `EncodingService` double.
function EncodingService.new(): any
	local service: any = { calls = {}, levels = {} }
	local function count(method: string) service.calls[method] = (service.calls[method] or 0) + 1 end
	function service.CompressBuffer(_self: any, input: buffer, algorithm: any, level: number?): buffer
		count("CompressBuffer")
		checkAlgorithm(algorithm)
		local chosen = level or 1
		if chosen % 1 ~= 0 or chosen < -7 or chosen > 22 then
			error("EncodingService double: zstd level must be an integer from -7 to 22", 2)
		end
		table.insert(service.levels, chosen)
		return compress(input)
	end
	function service.GetDecompressedBufferSize(_self: any, input: buffer, algorithm: any): number?
		count("GetDecompressedBufferSize")
		checkAlgorithm(algorithm)
		return declared(input)
	end
	function service.DecompressBuffer(_self: any, input: buffer, algorithm: any): buffer
		count("DecompressBuffer")
		checkAlgorithm(algorithm)
		return decompress(input)
	end
	function service.Base64Encode(_self: any, input: buffer): buffer
		count("Base64Encode")
		return buffer.fromstring(EncodingService.base64Encode(input))
	end
	function service.Base64Decode(_self: any, input: buffer): buffer
		count("Base64Decode")
		local decoded = EncodingService.base64Decode(buffer.tostring(input))
		if decoded == nil then error("EncodingService double: invalid Base64", 2) end
		return decoded
	end
	function service.ComputeBufferHash(_self: any, input: buffer, algorithm: any): buffer
		count("ComputeBufferHash")
		return hashBuffer(input, algorithm)
	end
	function service.ComputeStringHash(_self: any, input: string, algorithm: any): string
		count("ComputeStringHash")
		return bytes.hex(hashBuffer(buffer.fromstring(input), algorithm))
	end
	return service
end

local function failHttp(message: string): never error(`HttpService double: {message}`, 0) end

local HTTP_JSON: format.JsonOptions = {
	strict = true,
	prefix = "HttpService double: ",
	buffer = function(value: buffer): string
		return `\{"m":null,"t":"buffer","base64":"{EncodingService.base64Encode(value)}"}`
	end,
	revive = function(object: { [string]: any }): any
		local base64: string? = object.base64
		if object.t == "buffer" and base64 ~= nil then
			local decoded = EncodingService.base64Decode(base64)
			if decoded == nil then failHttp("invalid buffer Base64") end
			return decoded
		end
		return object
	end,
}

local HttpService = {}

--- Creates a headless `HttpService` double with strict JSON encoding/decoding and deterministic GUID generation.
function HttpService.new(options: { prefix: number? }?): any
	local given = if options ~= nil then options.prefix else nil
	local prefix = if given ~= nil then string.format("%08X", given % 4294967296) else "0A1B2C3D"
	local fourth = if given ~= nil then string.format("%04X", given % 65536) else "8293"
	local service: any = { calls = {}, guids = 0 }
	local function count(method: string) service.calls[method] = (service.calls[method] or 0) + 1 end
	function service.JSONEncode(_self: any, value: any): string
		count("JSONEncode")
		return format.json(value, HTTP_JSON)
	end
	function service.JSONDecode(_self: any, text: string): any
		count("JSONDecode")
		return format.jsonDecode(text, HTTP_JSON)
	end
	function service.GenerateGUID(_self: any, wrap: boolean?): string
		count("GenerateGUID")
		service.guids += 1
		local id = string.format("%s-4E5F-4061-%s-%012X", prefix, fourth, service.guids)
		return if wrap == false then id else "{" .. id .. "}"
	end
	function service.UrlEncode(_self: any, input: string): string
		count("UrlEncode")
		return (
			string.gsub(
				tostring(input),
				"([^%w%-_%.~])",
				function(ch: string): string return string.format("%%%02X", string.byte(ch)) end
			)
		)
	end
	return service
end

EncodingService.HttpService = HttpService

return table.freeze(EncodingService)
