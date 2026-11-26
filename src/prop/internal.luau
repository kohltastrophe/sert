--!strict
-- Internal property tape, generator primitives, and shared option schemas shared across `prop`, `gen`, `model`, `laws`, and `sim`.

local format = require("../core/format")
local registry = require("../core/registry")
local rng = require("../core/rng")
local util = require("../core/util")

export type Shard = registry.Shard
export type RunOptions = registry.RunOptions
export type ShrinkBudget = registry.ShrinkBudget
export type Target = registry.Target
export type Span = { start: number, stop: number, list: number }
export type Hint = { first: number, last: number, draws: { number } }

export type GenContext = {
	size: number,
	seed: number,
	exhaustive: boolean,
	draw: <T>(self: GenContext, gen: (g: GenContext) -> T) -> T,
	assume: (self: GenContext, cond: any, why: string?) -> (),
	int: (self: GenContext, lo: number, hi: number) -> number,
	float: (self: GenContext, lo: number?, hi: number?) -> number,
	bool: (self: GenContext, p: number?) -> boolean,
	pick: <T>(self: GenContext, items: { T }) -> T,
	weighted: (self: GenContext, pairs: { { any } }) -> any,
	optional: <T>(self: GenContext, gen: (g: GenContext) -> T, absent: number?, present: number?) -> T?,
	tuple: (self: GenContext, first: any, ...(g: GenContext) -> any) -> { any },
	record: (self: GenContext, shape: { [string]: any }) -> { [string]: any },
	dict: <K, V>(
		self: GenContext,
		keyGen: (g: GenContext) -> K,
		valueGen: (g: GenContext) -> V,
		min: number?,
		max: number?
	) -> { [K]: V },
	list: <T>(self: GenContext, gen: (g: GenContext) -> T, min: number?, max: number?) -> { T },
	string: (self: GenContext, charset: (string | ((g: GenContext) -> string))?, min: number?, max: number?) -> string,
	bytes: (self: GenContext, min: number?, max: number?) -> buffer,
	note: (self: GenContext, fmt: string | (() -> string), ...any) -> (),
	target: (self: GenContext, score: number, label: string?) -> (),
	classify: (self: GenContext, cond: boolean, label: string) -> (),
	cover: (self: GenContext, minPct: number, cond: boolean, label: string) -> (),
}

export type Gen = GenContext
export type Generator<T> = (g: GenContext) -> T
export type PropFn = (g: GenContext) -> ()

export type PropOptions = typeof(table.freeze({} :: {
	runs: number?,
	size: number?,
	seed: number?,
	regressions: ({ number } | { string } | { number | string })?,
	exhaustive: registry.ExhaustiveOption?,
	shrinkBudget: ShrinkBudget?,
	timeout: number?,
	skip: boolean?,
	focus: boolean?,
	smoke: boolean?,
	tags: { string }?,
	file: string?,
	target: Target?,
	capMutant: boolean?,
}))

export type NoteEntry = string | () -> string
export type CoverEntry = { minPct: number, hit: boolean }
export type GenState = {
	forced: { number }?,
	rng: number,
	out: { number },
	ranges: { number },
	spans: { Span },
	hints: { Hint },
	lists: number,
	notes: { NoteEntry },
	exhaustive: boolean,
	vacuous: (string | boolean)?,
	assumedOut: string?,
	exhausted: boolean?,
	targets: { [string]: number }?,
	classified: { [string]: boolean }?,
	covers: { [string]: CoverEntry }?,
	recordDraws: boolean,
	drawDepth: number,
	autoDraws: { string }?,
}
export type GenImpl = GenContext & { _s: GenState }

local U32 = 2 ^ 32
local U21, U53 = 2 ^ 21, 2 ^ 53
local GOLDEN = 0x9E3779B9
local DEFAULT_BASE = 0x5EED
local FLOAT_STEPS = U32 - 1

local ASSUME_REJECT = table.freeze({})
local STOP_LIST: any = table.freeze({})
local GENERATOR_MARKS: { [any]: boolean } = setmetatable({}, { __mode = "k" }) :: any

local xorshift32 = rng.xorshift32
local fnv1a32 = rng.fnv1a32
local mutant = registry.mutant

local PROP_OPTIONS = {
	"capMutant",
	"exhaustive",
	"file",
	"focus",
	"regressions",
	"runs",
	"seed",
	"shrinkBudget",
	"size",
	"skip",
	"smoke",
	"tags",
	"target",
	"timeout",
}

local internal = {
	U32 = U32,
	U21 = U21,
	U53 = U53,
	DEFAULT_BASE = DEFAULT_BASE,
	CHARACTERS = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789 _-.;:'\"",
	PROP_OPTIONS = PROP_OPTIONS,
	STOP_LIST = STOP_LIST,
	ASSUME_REJECT = ASSUME_REJECT,
	mutant = mutant,
	checkRange = rng.checkRange,
}

function internal.caseSeedOf(nameHash: number, base: number, run: number): number
	return bit32.bxor(nameHash, base % U32, (run * GOLDEN) % U32)
end

function internal.caseSeed(name: string, base: number, run: number): number
	return internal.caseSeedOf(fnv1a32(name), base, run)
end

function internal.markGenerator<T>(fn: Generator<T>): Generator<T>
	GENERATOR_MARKS[fn] = true
	return fn
end

function internal.isGenerator(value: any): boolean return type(value) == "function" and GENERATOR_MARKS[value] == true end

local function nextU32(self: GenImpl): number
	local state = self._s
	state.rng = xorshift32(state.rng)
	return state.rng
end

local function uniform(self: GenImpl, range: number): number
	local u = nextU32(self)
	if range < U32 - 1 then
		return u % (range + 1)
	elseif range < U32 then
		return math.floor(u / U32 * (range + 1))
	end
	local wide = (u % U21) * U32 + nextU32(self) - 1
	return if range < U53 then wide % (range + 1) else math.floor(wide / U53 * (range + 1))
end

local function drawUniform(self: GenImpl, range: number): number
	local state = self._s
	local pos = #state.out + 1
	local forced = state.forced
	local value = if forced ~= nil then math.clamp(forced[pos] or 0, 0, range) else uniform(self, range)
	state.out[pos], state.ranges[pos] = value, range
	return value
end

--- Records a zero-range padding slot (`0..0`) so fixed-width tagged generators preserve tape alignment without inflating exhaustive enumeration.
function internal.drawZero(g: GenContext): number
	local state = (g :: GenImpl)._s
	local pos = #state.out + 1
	state.out[pos], state.ranges[pos] = 0, 0
	return 0
end

--- Draws a tag in `0..maxTag` where `0` is chosen with probability `1 - probNonZero` and `1..maxTag` uniformly with probability `probNonZero`.
function internal.drawTag(g: GenContext, maxTag: number, probNonZero: number): number
	local self = g :: GenImpl
	local state = self._s
	local pos = #state.out + 1
	if maxTag <= 0 then
		state.out[pos], state.ranges[pos] = 0, 0
		return 0
	end
	local forced = state.forced
	local value: number
	if forced ~= nil then
		value = math.clamp(forced[pos] or 0, 0, maxTag)
	else
		local roll = nextU32(self) / U32
		value = if roll < probNonZero then 1 + uniform(self, maxTag - 1) else 0
	end
	state.out[pos], state.ranges[pos] = value, maxTag
	return value
end

function internal.intDrawWidth(low: number, high: number): number return if low < 0 and high > 0 then 2 else 1 end

function internal.floatDrawWidth(low: number, high: number): number
	if low == high then return 0 end
	return if low < 0 and high > 0 then 2 else 1
end

local function checkGen(api: string, gen: any)
	if type(gen) ~= "function" then
		error(`{api}: expected a generator (a function (g) -> value), got {util.typeof(gen)}`, util.outside())
	end
end

local function recordedDraw<T>(self: GenImpl, label: string, body: () -> T): T
	local state = self._s
	local isTop = state.drawDepth == 0
	state.drawDepth += 1
	local ok, val = pcall(body :: () -> any)
	state.drawDepth -= 1
	if not ok then error(val, 0) end
	if isTop then
		local autoList: { string }
		if state.autoDraws == nil then
			autoList = {}
			state.autoDraws = autoList
		else
			autoList = state.autoDraws
		end
		if #autoList < 32 then table.insert(autoList, `draw #{#autoList + 1} ({label}): {format.repr(val)}`) end
	end
	return val
end

local GenMethods = {}

function GenMethods.draw<T>(self: GenImpl, gen: Generator<T>): T
	checkGen("g:draw", gen)
	if not self._s.recordDraws then return gen(self) end
	return recordedDraw(self, "draw", function(): T return gen(self) end)
end

function GenMethods.assume(self: GenImpl, cond: any, why: string?)
	if cond then return end
	local reason = if type(why) == "string" and #why > 0 then why else "assumption failed"
	self._s.assumedOut = reason
	error(ASSUME_REJECT, 0)
end

local function rawBool(self: GenImpl, p: number?): boolean
	local chance = p or 0.5
	local state = self._s
	local pos = #state.out + 1
	local forced = state.forced
	if chance <= 0 or chance >= 1 then
		if forced == nil then nextU32(self) end
		state.out[pos], state.ranges[pos] = 0, 0
		return chance >= 1
	end
	local value = if forced ~= nil
		then math.clamp(forced[pos] or 0, 0, 1)
		elseif nextU32(self) / U32 < chance then 1
		else 0
	state.out[pos], state.ranges[pos] = value, 1
	return value == 1
end

function internal.drawInt(g: GenContext, lo: number, hi: number): number
	local self = g :: GenImpl
	if lo >= 0 then
		return lo + drawUniform(self, hi - lo)
	elseif hi <= 0 then
		return hi - drawUniform(self, hi - lo)
	end
	local span = hi - lo + 1
	local pNeg = if span == math.huge then (-lo / hi) / (1 + (-lo / hi)) else -lo / span
	if rawBool(self, pNeg) then return -(1 + drawUniform(self, -lo - 1)) end
	return drawUniform(self, hi)
end

function GenMethods.int(self: GenImpl, lo: number, hi: number): number
	internal.checkRange("g:int", lo, hi, true)
	if not self._s.recordDraws then return internal.drawInt(self, lo, hi) end
	return recordedDraw(self, "int", function(): number return internal.drawInt(self, lo, hi) end)
end

function GenMethods.bool(self: GenImpl, p: number?): boolean
	if not self._s.recordDraws then return rawBool(self, p) end
	return recordedDraw(self, "bool", function(): boolean return rawBool(self, p) end)
end

function GenMethods.pick(self: GenImpl, items: { any }): any
	if #items == 0 then error("g:pick: empty array", util.outside()) end
	if not self._s.recordDraws then return items[1 + drawUniform(self, #items - 1)] end
	return recordedDraw(self, "pick", function(): any return items[1 + drawUniform(self, #items - 1)] end)
end

local function rawWeighted(self: GenImpl, items: { { any } }): any
	local count, total = 0, 0
	for _, entry in items do
		local weight = entry[1] :: number
		if weight > 0 then
			count += 1
			total += weight
		end
	end
	if count == 0 then error("g:weighted: no item with a positive weight", util.outside()) end
	local state = self._s
	local pos, range = #state.out + 1, count - 1
	local forced = state.forced
	if forced ~= nil then
		local offset = math.clamp(forced[pos] or 0, 0, range)
		state.out[pos], state.ranges[pos] = offset, range
		local target, seen = offset + 1, 0
		for _, entry in items do
			if (entry[1] :: number) > 0 then
				seen += 1
				if seen == target then return entry[2] end
			end
		end
		return nil
	end
	local roll, liveIndex = nextU32(self) / U32 * total, 0
	local offset, chosen: any = range, nil
	for _, entry in items do
		local weight = entry[1] :: number
		if weight > 0 then
			chosen = entry[2]
			roll -= weight
			if roll < 0 then
				offset = liveIndex
				break
			end
			liveIndex += 1
		end
	end
	state.out[pos], state.ranges[pos] = offset, range
	return chosen
end

function GenMethods.weighted(self: GenImpl, items: { { any } }): any
	if not self._s.recordDraws then return rawWeighted(self, items) end
	return recordedDraw(self, "weighted", function(): any return rawWeighted(self, items) end)
end

local function rawList(self: GenImpl, gen: Generator<any>, min: number?, max: number?): { any }
	local state = self._s
	state.lists += 1
	local list = state.lists
	local low = min or 0
	local high = max or self.size
	if state.exhaustive then high = math.min(high, self.size) end
	high = math.max(high, low)
	local target: number? = nil
	local items = {}
	for index = 1, high do
		local start = #state.out + 1
		if index > low then
			local forced = state.forced
			local more
			if forced ~= nil then
				more = math.clamp(forced[start] or 0, 0, 1)
			else
				if target == nil then target = low + uniform(self, high - low) end
				more = if index <= (target :: number) then 1 else 0
			end
			state.out[start], state.ranges[start] = more, 1
			if more == 0 then break end
		end
		local item = gen(self)
		if item == STOP_LIST then break end
		items[index] = item
		if index > low then table.insert(state.spans, { start = start, stop = #state.out, list = list }) end
	end
	return items
end

function GenMethods.list(self: GenImpl, gen: Generator<any>, min: number?, max: number?): { any }
	checkGen("g:list", gen)
	if not self._s.recordDraws then return rawList(self, gen, min, max) end
	return recordedDraw(self, "list", function(): { any } return rawList(self, gen, min, max) end)
end

function GenMethods.note(self: GenImpl, fmt: string | (() -> string), ...: any)
	local notes: { NoteEntry } = self._s.notes
	if type(fmt) == "function" then
		table.insert(notes, fmt)
	else
		local msg: string = if select("#", ...) > 0 then string.format(fmt, ...) else fmt
		table.insert(notes, msg)
	end
end

--- Draws a float in `[low, high)` (or `[low, high]` when `high < 0`), anchored at `origin = clamp(0, low, high)` so shrinking moves monotonically toward `0` (or the nearer bound).
function internal.drawFloat(g: GenContext, low: number, high: number): number
	local self = g :: GenImpl
	local origin = math.clamp(0, low, high)
	local up, down = high - origin, origin - low
	if up <= 0 and down <= 0 then return if low == 0 then 0 else low end
	local steps = if self._s.exhaustive then math.max(self.size, 1) else FLOAT_STEPS
	if up <= 0 then
		local offset = drawUniform(self, steps)
		if offset == 0 then return if origin == 0 then 0 else origin end
		local denom = if origin == 0 then steps + 1 else steps
		return origin - (offset / denom) * down
	elseif down <= 0 then
		local offset = drawUniform(self, steps)
		if offset == 0 then return if origin == 0 then 0 else origin end
		return origin + (offset / (steps + 1)) * up
	end
	local below = rawBool(self, 1 / (1 + up / down))
	local offset = drawUniform(self, steps)
	if below then return origin - ((offset + 1) / (steps + 1)) * down end
	if offset == 0 then return 0 end
	return origin + (offset / (steps + 1)) * up
end

function GenMethods.float(self: GenImpl, lo: number?, hi: number?): number
	local low, high = if lo == nil then 0 else lo, if hi == nil then 1 else hi
	internal.checkRange("g:float", low, high, false)
	if not self._s.recordDraws then return internal.drawFloat(self, low, high) end
	return recordedDraw(self, "float", function(): number return internal.drawFloat(self, low, high) end)
end

local DEFAULT_OPTIONAL_WEIGHTS: { { any } } = { { 1, false }, { 1, true } }

function GenMethods.optional(self: GenImpl, gen: Generator<any>, absent: number?, present: number?): any
	checkGen("g:optional", gen)
	local weights: { { any } } = if absent == nil and present == nil
		then DEFAULT_OPTIONAL_WEIGHTS
		else { { absent or 1, false }, { present or 1, true } }
	if not self._s.recordDraws then return if rawWeighted(self, weights) then gen(self) else nil end
	return recordedDraw(
		self,
		"optional",
		function(): any return if rawWeighted(self, weights) then gen(self) else nil end
	)
end

local function rawTuple(self: GenImpl, first: any, rest: { Generator<any> }, restCount: number): { any }
	if type(first) == "table" then
		local gens = first :: { Generator<any> }
		local values = table.create(#gens)
		for index, each in gens do
			checkGen("g:tuple", each)
			values[index] = each(self)
		end
		return values
	end
	local count = restCount + 1
	local values = table.create(count)
	checkGen("g:tuple", first)
	values[1] = (first :: Generator<any>)(self)
	for index = 1, restCount do
		local each = rest[index]
		checkGen("g:tuple", each)
		values[index + 1] = each(self)
	end
	return values
end

function GenMethods.tuple(self: GenImpl, first: any, ...: Generator<any>): { any }
	if not self._s.recordDraws then
		if type(first) == "table" then
			local gens = first :: { Generator<any> }
			local values = table.create(#gens)
			for index, each in gens do
				checkGen("g:tuple", each)
				values[index] = each(self)
			end
			return values
		end
		local count = select("#", ...) + 1
		local values = table.create(count)
		checkGen("g:tuple", first)
		values[1] = (first :: Generator<any>)(self)
		for index = 1, count - 1 do
			local each = select(index, ...)
			checkGen("g:tuple", each)
			values[index + 1] = each(self)
		end
		return values
	end
	local rest = { ... }
	local restCount = select("#", ...)
	return recordedDraw(self, "tuple", function(): { any } return rawTuple(self, first, rest, restCount) end)
end

local function rawRecord(self: GenImpl, shape: { [string]: any }): { [string]: any }
	local keys = {}
	for key in next, shape do
		table.insert(keys, key)
	end
	table.sort(keys)
	local value = {}
	for _, key in keys do
		local field: any = shape[key]
		value[key] = if type(field) == "function" then (field :: Generator<any>)(self) else field
	end
	return value
end

function GenMethods.record(self: GenImpl, shape: { [string]: any }): { [string]: any }
	if not self._s.recordDraws then return rawRecord(self, shape) end
	return recordedDraw(self, "record", function(): { [string]: any } return rawRecord(self, shape) end)
end

local function rawDict(
	self: GenImpl,
	keyGen: Generator<any>,
	valueGen: Generator<any>,
	min: number?,
	max: number?
): { [any]: any }
	local out = {}
	for _, pair in rawList(self, function(g: GenContext) return { keyGen(g), valueGen(g) } end, min, max) do
		out[pair[1]] = pair[2]
	end
	return out
end

function GenMethods.dict(
	self: GenImpl,
	keyGen: Generator<any>,
	valueGen: Generator<any>,
	min: number?,
	max: number?
): { [any]: any }
	checkGen("g:dict", keyGen)
	checkGen("g:dict", valueGen)
	if not self._s.recordDraws then return rawDict(self, keyGen, valueGen, min, max) end
	return recordedDraw(self, "dict", function(): { [any]: any } return rawDict(self, keyGen, valueGen, min, max) end)
end

local function rawString(self: GenImpl, charset: (string | Generator<string>)?, min: number?, max: number?): string
	local each: Generator<string>
	if type(charset) == "function" then
		each = charset
	else
		local chars: string = if charset == nil then internal.CHARACTERS else charset
		if #chars == 0 then error("g:string: an empty charset", util.outside()) end
		local count = #chars
		each = function(g: any): string
			local index = 1 + drawUniform(g, count - 1)
			return string.sub(chars, index, index)
		end
	end
	return table.concat(rawList(self, each, min, max))
end

function GenMethods.string(self: GenImpl, charset: (string | Generator<string>)?, min: number?, max: number?): string
	if not self._s.recordDraws then return rawString(self, charset, min, max) end
	return recordedDraw(self, "string", function(): string return rawString(self, charset, min, max) end)
end

local function rawBytes(self: GenImpl, min: number?, max: number?): buffer
	local least = min or 0
	if max ~= nil and least > max then error("g:bytes: min > max", util.outside()) end
	local octets = rawList(self, function(g: any) return drawUniform(g, 255) end, least, max)
	local b = buffer.create(#octets)
	for index, byte in octets do
		buffer.writeu8(b, index - 1, byte)
	end
	return b
end

function GenMethods.bytes(self: GenImpl, min: number?, max: number?): buffer
	if not self._s.recordDraws then return rawBytes(self, min, max) end
	return recordedDraw(self, "bytes", function(): buffer return rawBytes(self, min, max) end)
end

function GenMethods.target(self: GenImpl, score: number, label: string?)
	if type(score) ~= "number" or score ~= score then return end
	if label ~= nil and type(label) ~= "string" then
		error(`g:target: expected string label or nil, got {util.typeof(label)}`, util.outside())
	end
	local key = if label ~= nil then label else "_default"
	local state = self._s
	local targets = state.targets
	local tMap: { [string]: number }
	if targets == nil then
		tMap = {}
		state.targets = tMap
	else
		tMap = targets
	end
	local prev = tMap[key]
	if prev == nil or score > prev then tMap[key] = score end
end

function GenMethods.classify(self: GenImpl, cond: boolean, label: string)
	if type(label) ~= "string" or #label == 0 then
		error(`g:classify: expected non-empty string label, got {util.typeof(label)}`, util.outside())
	end
	local state = self._s
	local classified = state.classified
	local cMap: { [string]: boolean }
	if classified == nil then
		cMap = {}
		state.classified = cMap
	else
		cMap = classified
	end
	local hit = if cond then true else false
	cMap[label] = (cMap[label] == true) or hit
end

function GenMethods.cover(self: GenImpl, minPct: number, cond: boolean, label: string)
	if type(minPct) ~= "number" or minPct ~= minPct or minPct < 0 or minPct > 100 then
		error(`g:cover: expected minPct in [0, 100], got {format.repr(minPct)}`, util.outside())
	end
	if type(label) ~= "string" or #label == 0 then
		error(`g:cover: expected non-empty string label, got {util.typeof(label)}`, util.outside())
	end
	local state = self._s
	local covers = state.covers
	local covMap: { [string]: CoverEntry }
	if covers == nil then
		covMap = {}
		state.covers = covMap
	else
		covMap = covers
	end
	local hit = if cond then true else false
	local existing = covMap[label]
	if existing == nil then
		covMap[label] = { minPct = minPct, hit = hit }
	else
		existing.minPct = math.max(existing.minPct, minPct)
		existing.hit = existing.hit or hit
	end
end

local GenMeta = { __index = GenMethods }

function internal.isGen(value: any): boolean return type(value) == "table" and getmetatable(value) == GenMeta end

function internal.newGen(
	seed: number,
	size: number,
	forced: { number }?,
	exhaustive: boolean,
	recordDraws: boolean?
): GenImpl
	local state = rng.new(seed).state
	for _ = 1, 4 do
		state = xorshift32(state)
	end
	local genState: GenState = {
		forced = forced,
		rng = state,
		out = {},
		ranges = {},
		spans = {},
		lists = 0,
		hints = {},
		notes = {},
		exhaustive = exhaustive,
		vacuous = nil,
		assumedOut = nil,
		exhausted = false,
		recordDraws = recordDraws == true,
		drawDepth = 0,
		autoDraws = nil,
	}
	return setmetatable({ size = size, seed = seed, exhaustive = exhaustive, _s = genState }, GenMeta) :: any
end

function internal.gen(seed: number?, size: number?, tape: { number }?): GenContext
	return internal.newGen(if seed ~= nil then seed else DEFAULT_BASE, size or 40, tape, false, false)
end

function internal.exhaust(g: any, msg: string, level: number?): never
	if type(g) == "table" and type((g :: any)._s) == "table" then (g :: GenImpl)._s.exhausted = true end
	error(msg, if level == nil then 2 else level)
end

function internal.tape(g: GenContext): { number } return table.clone((g :: GenImpl)._s.out) end

function internal.mark(g: GenContext): number return #(g :: GenImpl)._s.out + 1 end

function internal.hint(g: GenContext, first: number, last: number, draws: { number })
	table.insert((g :: GenImpl)._s.hints, { first = first, last = last, draws = table.clone(draws) })
end

function internal.vacuous(g: GenContext, why: string?) (g :: GenImpl)._s.vacuous = if why ~= nil then why else true end

function internal.autoDraws(g: GenContext): { string } return (g :: GenImpl)._s.autoDraws or {} end

function internal.tapeText(tape: { number }): string
	local parts = {}
	for index, value in tape do
		if index > 64 then
			table.insert(parts, `… {#tape - 64} more`)
			break
		end
		table.insert(parts, tostring(value))
	end
	return "{ " .. table.concat(parts, ", ") .. " }"
end

return internal
