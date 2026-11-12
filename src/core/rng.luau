--!strict
-- Seeded `xorshift32` random number stream and FNV-1a hashing, deterministic across Luau CLI, Lute, Lune, and Roblox.

local U32 = 2 ^ 32
local GOLDEN = 0x9E3779B9

export type ByteKind = "random" | "text" | "runs" | "pattern" | "mixed"

export type Rng = {
	state: number,
	next: (self: Rng) -> number,
	u32: (self: Rng) -> number,
	int: (self: Rng, lo: number, hi: number) -> number,
	float: (self: Rng, lo: number?, hi: number?) -> number,
	chance: (self: Rng, p: number) -> boolean,
	bool: (self: Rng, p: number?) -> boolean,
	pick: <T>(self: Rng, list: { T }) -> T,
	shuffle: <T>(self: Rng, list: { T }) -> { T },
	clone: (self: Rng) -> Rng,
	fork: (self: Rng, label: string?) -> Rng,
	bytes: (self: Rng, count: number, kind: ByteKind?) -> buffer,
}

local rng = {}

--- Advances `x` by one `xorshift32` step (`x` must be a nonzero u32).
function rng.xorshift32(x: number): number
	x = bit32.bxor(x, bit32.lshift(x, 13))
	x = bit32.bxor(x, bit32.rshift(x, 17))
	return bit32.bxor(x, bit32.lshift(x, 5))
end

local function foldFnv1a32(hash: number, text: string): number
	for index = 1, #text do
		hash = bit32.bxor(hash, string.byte(text, index))
		-- Split `hash * 0x01000193 mod 2^32` so the product stays exact in an IEEE-754 double.
		hash = (bit32.lshift(hash, 24) + hash * 0x193) % U32
	end
	return hash
end

--- Folds the bytes of `text` into a 32-bit FNV-1a accumulator `hash`.
rng.foldFnv1a32 = foldFnv1a32

--- Computes the 32-bit FNV-1a hash of `text`.
function rng.fnv1a32(text: string): number return foldFnv1a32(0x811C9DC5, text) end

--- Alias for `fnv1a32`.
rng.hash = rng.fnv1a32

local Rng = {}
Rng.__index = Rng

--- Creates a seeded `Rng` stream (a `nil` or zero seed maps to `0x9E3779B9`).
function rng.new(seed: number?): Rng
	local s = if seed ~= nil and seed == seed and math.abs(seed) ~= math.huge then math.floor(seed) % U32 else 0
	if s == 0 then s = GOLDEN end
	return setmetatable({ state = s }, Rng) :: any
end

--- Draws the next nonzero u32 from the stream.
function Rng.next(self: Rng): number
	local state = rng.xorshift32(self.state)
	self.state = state
	return state
end

Rng.u32 = Rng.next

function rng.checkRange(api: string, lo: any, hi: any, integer: boolean, maxSpan: number?)
	if
		type(lo) ~= "number"
		or type(hi) ~= "number"
		or not (lo <= hi)
		or math.abs(lo) == math.huge
		or math.abs(hi) == math.huge
		or (integer and (lo ~= math.floor(lo) or hi ~= math.floor(hi)))
		or (maxSpan ~= nil and hi - lo + 1 > maxSpan)
	then
		local spanNote = if maxSpan ~= nil then " spanning at most 2^32" else ""
		error(`{api}: expected {if integer then "integers " else ""}lo <= hi{spanNote}, got {lo}, {hi}`, 3)
	end
end

--- Draws an unbiased integer in `[lo, hi]`.
function Rng.int(self: Rng, lo: number, hi: number): number
	rng.checkRange("Rng:int", lo, hi, true, U32)
	local span = hi - lo + 1
	-- Reject draws past the last complete multiple of `span` to avoid modulo bias.
	local limit = U32 - U32 % span
	local value = Rng.next(self)
	while value > limit do
		value = Rng.next(self)
	end
	return lo + value % span
end

--- Draws a float in `[lo, hi)` (default `[0, 1)`).
function Rng.float(self: Rng, lo: number?, hi: number?): number
	local unit = Rng.next(self) / U32
	if lo == nil and hi == nil then return unit end
	local low, high = lo or 0, hi or 1
	rng.checkRange("Rng:float", low, high, false)
	local span = high - low
	return if span == math.huge then low + unit * high - unit * low else low + unit * span
end

--- Picks a random element from `list`.
function Rng.pick<T>(self: Rng, list: { T }): T
	if #list == 0 then error("Rng:pick: an empty list", 2) end
	return list[Rng.int(self, 1, #list)]
end

--- Shuffles `list` in place using Fisher-Yates and returns it.
function Rng.shuffle<T>(self: Rng, list: { T }): { T }
	for index = #list, 2, -1 do
		local other = Rng.int(self, 1, index)
		list[index], list[other] = list[other], list[index]
	end
	return list
end

--- Returns a copy of this stream at its current state.
function Rng.clone(self: Rng): Rng return setmetatable({ state = self.state }, Rng) :: any end

--- Returns `true` with probability `p`.
function Rng.chance(self: Rng, p: number): boolean return Rng.float(self) < p end

--- Returns `true` with probability `p` (default `0.5`).
function Rng.bool(self: Rng, p: number?): boolean return Rng.float(self) < (if p ~= nil then p else 0.5) end

--- Forks an independent stream from the next draw, mixed with `fnv1a32(label)` when `label` is provided.
function Rng.fork(self: Rng, label: string?): Rng
	local seed = Rng.next(self)
	if label ~= nil then seed = bit32.bxor(seed, rng.fnv1a32(label)) end
	return rng.new(seed)
end

local TEXT_WORDS = { "alpha ", "beta ", "gamma ", "delta ", "player ", "score ", "the ", "of " }
local MIXED_MODES: { ByteKind } = { "random", "text", "runs", "pattern" }

--- Generates a `buffer` of `count` bytes with distribution `kind` (default `"random"`).
function Rng.bytes(self: Rng, count: number, kind: ByteKind?): buffer
	local b = buffer.create(count)
	local mode = kind or "random"
	if mode == "random" then
		for i = 0, count - 1 do
			buffer.writeu8(b, i, Rng.int(self, 0, 255))
		end
	elseif mode == "text" then
		local i = 0
		while i < count do
			local word = TEXT_WORDS[Rng.int(self, 1, #TEXT_WORDS)]
			local take = math.min(#word, count - i)
			buffer.writestring(b, i, word, take)
			i += take
		end
	elseif mode == "runs" then
		local i = 0
		while i < count do
			local length = math.min(Rng.int(self, 1, 600), count - i)
			buffer.fill(b, i, Rng.int(self, 0, 255), length)
			i += length
		end
	elseif mode == "pattern" then
		local period = Rng.int(self, 1, 300)
		for i = 0, count - 1 do
			buffer.writeu8(b, i, (i % period) * 7 % 256)
		end
	elseif mode == "mixed" then
		local i = 0
		while i < count do
			local length = math.min(Rng.int(self, 1, 2000), count - i)
			local sub = Rng.bytes(self, length, MIXED_MODES[Rng.int(self, 1, #MIXED_MODES)])
			buffer.copy(b, i, sub, 0, length)
			i += length
		end
	else
		error(`unknown byte kind {mode :: string}`, 2)
	end
	return b
end

rng.Rng = Rng

return table.freeze(rng)
