--!strict
-- Deterministic byte-tape codec (`v1:<seed>:<size>:<hex>` / `v2:...`) and replay token parser for property/model corpora.

export type ReplaySpec = { kind: "seed", seed: number } | { kind: "tape", seed: number, size: number, tape: { number } }

local corpus = {}

local U32_SCALE = 0x100000000
local U53_MAX = 9007199254740991

local function isFiniteInt(n: number): boolean
	return type(n) == "number" and n == n and n ~= math.huge and n ~= -math.huge and n % 1 == 0
end

local function isU32(n: number): boolean return isFiniteInt(n) and n >= 0 and n <= 0xFFFFFFFF end

local function isU53(n: number): boolean return isFiniteInt(n) and n >= 0 and n <= U53_MAX end

function corpus.encode(seed: number, size: number, tape: { number }): string
	if not isFiniteInt(seed) then error(`corpus.encode: seed must be a finite integer, got {seed}`, 2) end
	if not isFiniteInt(size) or size < 0 then
		error(`corpus.encode: size must be a non-negative integer, got {size}`, 2)
	end
	if type(tape) ~= "table" then error("corpus.encode: tape must be an array of u53 integers", 2) end

	local normSeed = if seed == 0 then 0 else seed
	local normSize = if size == 0 then 0 else size
	local needU53 = false
	for i, entry in tape do
		if not isU53(entry) then error(`corpus.encode: tape[{i}] must be a u53 integer, got {entry}`, 2) end
		if entry > 0xFFFFFFFF then needU53 = true end
	end

	local chunks = table.create(#tape)
	if needU53 then
		for i, entry in tape do
			local hi = math.floor(entry / U32_SCALE)
			local lo = entry - hi * U32_SCALE
			chunks[i] = string.format("%06x%08x", hi, lo)
		end
		return `v2:{string.format("%.0f", normSeed)}:{string.format("%.0f", normSize)}:{table.concat(chunks)}`
	end

	for i, entry in tape do
		chunks[i] = string.format("%08x", entry)
	end
	return `v1:{string.format("%.0f", normSeed)}:{string.format("%.0f", normSize)}:{table.concat(chunks)}`
end

function corpus.decode(token: string): (number?, number?, { number }?)
	if type(token) ~= "string" then return nil, nil, nil end
	local ver, seedStr, sizeStr, hex = string.match(token, "^v([12]):([^:]+):([^:]+):(.*)$")
	if ver == nil or seedStr == nil or sizeStr == nil or hex == nil then return nil, nil, nil end
	if string.match(seedStr, "^-?%d+$") == nil then return nil, nil, nil end
	if string.match(sizeStr, "^%d+$") == nil then return nil, nil, nil end

	local seedNum = tonumber(seedStr)
	local sizeNum = tonumber(sizeStr)
	if seedNum == nil or sizeNum == nil or not isFiniteInt(seedNum) or not isFiniteInt(sizeNum) or sizeNum < 0 then
		return nil, nil, nil
	end

	if ver == "2" then
		if #hex % 14 ~= 0 then return nil, nil, nil end
		local count = #hex // 14
		local tape: { number } = table.create(count, 0)
		for i = 1, count do
			local startIdx = (i - 1) * 14 + 1
			local hiHex = string.sub(hex, startIdx, startIdx + 5)
			local loHex = string.sub(hex, startIdx + 6, startIdx + 13)
			if string.match(hiHex, "^%x%x%x%x%x%x$") == nil or string.match(loHex, "^%x%x%x%x%x%x%x%x$") == nil then
				return nil, nil, nil
			end
			local hi = tonumber(hiHex, 16)
			local lo = tonumber(loHex, 16)
			if hi == nil or lo == nil then return nil, nil, nil end
			local word = hi * U32_SCALE + lo
			if not isU53(word) then return nil, nil, nil end
			tape[i] = word
		end
		return seedNum, sizeNum, tape
	end

	if #hex % 8 ~= 0 then return nil, nil, nil end
	local count = #hex // 8
	local tape: { number } = table.create(count, 0)
	for i = 1, count do
		local startIdx = (i - 1) * 8 + 1
		local chunk = string.sub(hex, startIdx, startIdx + 7)
		if string.match(chunk, "^%x%x%x%x%x%x%x%x$") == nil then return nil, nil, nil end
		local word = tonumber(chunk, 16)
		if word == nil or not isU32(word) then return nil, nil, nil end
		tape[i] = word
	end
	return seedNum, sizeNum, tape
end

function corpus.parseReplay(raw: (number | string)?): ReplaySpec?
	if raw == nil then return nil end
	if type(raw) == "number" then
		if raw ~= raw or raw == math.huge or raw == -math.huge then return nil end
		local out: ReplaySpec = { kind = "seed", seed = raw }
		return out
	end
	if type(raw) == "string" then
		local prefix = string.sub(raw, 1, 3)
		if prefix == "v1:" or prefix == "v2:" then
			local seed, size, tape = corpus.decode(raw)
			if seed ~= nil and size ~= nil and tape ~= nil then
				local out: ReplaySpec = { kind = "tape", seed = seed, size = size, tape = tape }
				return out
			end
			return nil
		end
		local n = tonumber(raw)
		if n ~= nil and n == n and n ~= math.huge and n ~= -math.huge then
			local out: ReplaySpec = { kind = "seed", seed = n }
			return out
		end
		return nil
	end
	return nil
end

return corpus
