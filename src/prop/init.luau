--!strict
-- Property testing engine (`sert.prop`): tape draws, shrinking, bounded-exhaustive enumeration, assumption tracking, and replay.

local corpus = require("@self/corpus")
local format = require("./core/format")
local registry = require("./core/registry")
local rng = require("./core/rng")
local util = require("./core/util")

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
	file: string?,
	target: Target?,
	capMutant: boolean?,
}))

export type PropResult = {
	ok: boolean,
	cases: number,
	exhaustive: boolean,
	report: string?,
	message: string?,
	original: string?,
	seed: number?,
	replay: string?,
	tape: { number }?,
	shrunk: { number }?,
	notes: { string }?,
	attempts: number,
	stopped: boolean?,
}

export type EachFormat<T> = registry.EachFormat<T>
export type PropCall = (name: string, fn: PropFn, options: PropOptions?) -> ()
export type PropSkipFn = (name: string, fn: PropFn?, options: PropOptions?) -> ()
export type PropEachFn = <T>(
	cases: { T }
) -> (fmt: EachFormat<T>, fn: (case: T, g: GenContext) -> (), options: PropOptions?) -> ()
export type PropEachTupleFn = (
	tuples: { { any } }
) -> (fmt: EachFormat<{ any }>, fn: (...any) -> (), options: PropOptions?) -> ()

export type TargetPropApi = typeof(setmetatable(
	{} :: {
		skip: PropSkipFn,
		focus: PropCall,
		each: PropEachFn,
		eachTuple: PropEachTupleFn,
	},
	{} :: { __call: (self: any, name: string, fn: PropFn, options: PropOptions?) -> () }
))

export type PropNamespace = typeof(setmetatable(
	{} :: {
		skip: PropSkipFn,
		focus: PropCall,
		each: PropEachFn,
		eachTuple: PropEachTupleFn,
		roblox: TargetPropApi,
		server: TargetPropApi,
		client: TargetPropApi,
		DEFAULT_BASE: number,
		CHARACTERS: string,
		mutant: typeof(registry.mutant),
		PROP_OPTIONS: { string },
		caseSeed: (name: string, base: number, run: number) -> number,
		checkRange: (api: string, lo: number, hi: number, integer: boolean) -> (),
		isGen: (value: any) -> boolean,
		markGenerator: <T>(fn: Generator<T>) -> Generator<T>,
		isGenerator: (value: any) -> boolean,
		gen: (seed: number?, size: number?, tape: { number }?) -> GenContext,
		exhaust: (g: any, msg: string, level: number?) -> never,
		tape: (g: GenContext) -> { number },
		mark: (g: GenContext) -> number,
		hint: (g: GenContext, first: number, last: number, draws: { number }) -> (),
		vacuous: (g: GenContext, why: string?) -> (),
		spans: (g: GenContext) -> { Span },
		tapeText: (tape: { number }) -> string,
		drawZero: (g: GenContext) -> number,
		drawTag: (g: GenContext, maxTag: number, probNonZero: number) -> number,
		drawInt: (g: GenContext, lo: number, hi: number) -> number,
		drawFloat: (g: GenContext, low: number, high: number) -> number,
		floatDrawWidth: (low: number, high: number) -> number,
		intDrawWidth: (low: number, high: number) -> number,
		run: (
			name: string,
			fn: PropFn,
			options: PropOptions?,
			runOptions: RunOptions?,
			capMutant: boolean?,
			filter: string?
		) -> PropResult,
	},
	{} :: { __call: (self: any, name: string, fn: PropFn, options: PropOptions?) -> () }
))

local U32 = 2 ^ 32
local U21, U53 = 2 ^ 21, 2 ^ 53
local GOLDEN = 0x9E3779B9
local DEFAULT_BASE = 0x5EED
local SHRINK_ATTEMPTS = 500
local SHRINK_SECONDS = 2
local TRACE_LINES = 200
local MUTANT_RUNS = 5
local MUTANT_SHRINK: ShrinkBudget = { tries = 0, seconds = 0 }
local FLOAT_STEPS = U32 - 1

local ASSUME_REJECT = table.freeze({})
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
	"target",
	"timeout",
}
local SHRINK_BUDGET_KEYS = { "seconds", "tries" }
local EXHAUSTIVE_KEYS = { "size" }
local VALID_TARGETS: { [string]: boolean } = { portable = true, roblox = true, server = true, client = true }

local prop: { [string]: any } = {
	mutant = mutant,
	DEFAULT_BASE = DEFAULT_BASE,
	CHARACTERS = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789 _-.;:'\"",
	PROP_OPTIONS = PROP_OPTIONS,
	checkRange = rng.checkRange,
}

local function caseSeedOf(nameHash: number, base: number, run: number): number
	return bit32.bxor(nameHash, base % U32, (run * GOLDEN) % U32)
end

function prop.caseSeed(name: string, base: number, run: number): number return caseSeedOf(fnv1a32(name), base, run) end

function prop.markGenerator<T>(fn: Generator<T>): Generator<T>
	GENERATOR_MARKS[fn] = true
	return fn
end

function prop.isGenerator(value: any): boolean return type(value) == "function" and GENERATOR_MARKS[value] == true end

type NoteEntry = string | () -> string
type CoverEntry = { minPct: number, hit: boolean }
type GenState = {
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
}
type GenImpl = GenContext & { _s: GenState }

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
function prop.drawZero(g: GenContext): number
	local state = (g :: GenImpl)._s
	local pos = #state.out + 1
	state.out[pos], state.ranges[pos] = 0, 0
	return 0
end

--- Draws a tag in `0..maxTag` where `0` is chosen with probability `1 - probNonZero` and `1..maxTag` uniformly with probability `probNonZero`.
function prop.drawTag(g: GenContext, maxTag: number, probNonZero: number): number
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

function prop.intDrawWidth(low: number, high: number): number return if low < 0 and high > 0 then 2 else 1 end

function prop.floatDrawWidth(low: number, high: number): number
	if low == high then return 0 end
	return if low < 0 and high > 0 then 2 else 1
end

local function checkGen(api: string, gen: any)
	if type(gen) ~= "function" then
		error(`{api}: expected a generator (a function (g) -> value), got {util.typeof(gen)}`, util.outside())
	end
end

local GenMethods = {}

function GenMethods.draw<T>(self: GenImpl, gen: Generator<T>): T
	checkGen("g:draw", gen)
	return gen(self)
end

function GenMethods.assume(self: GenImpl, cond: any, why: string?)
	if cond then return end
	local reason = if type(why) == "string" and #why > 0 then why else "assumption failed"
	self._s.assumedOut = reason
	error(ASSUME_REJECT, 0)
end

function prop.drawInt(g: GenContext, lo: number, hi: number): number
	local self = g :: GenImpl
	if lo >= 0 then
		return lo + drawUniform(self, hi - lo)
	elseif hi <= 0 then
		return hi - drawUniform(self, hi - lo)
	end
	local span = hi - lo + 1
	local pNeg = if span == math.huge then (-lo / hi) / (1 + (-lo / hi)) else -lo / span
	if GenMethods.bool(self, pNeg) then return -(1 + drawUniform(self, -lo - 1)) end
	return drawUniform(self, hi)
end

function GenMethods.int(self: GenImpl, lo: number, hi: number): number
	prop.checkRange("g:int", lo, hi, true)
	return prop.drawInt(self, lo, hi)
end

function GenMethods.bool(self: GenImpl, p: number?): boolean
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

function GenMethods.pick(self: GenImpl, items: { any }): any
	if #items == 0 then error("g:pick: empty array", util.outside()) end
	return items[1 + drawUniform(self, #items - 1)]
end

function GenMethods.weighted(self: GenImpl, items: { { any } }): any
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

function GenMethods.list(self: GenImpl, gen: Generator<any>, min: number?, max: number?): { any }
	checkGen("g:list", gen)
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
		items[index] = gen(self)
		if index > low then table.insert(state.spans, { start = start, stop = #state.out, list = list }) end
	end
	return items
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
function prop.drawFloat(g: GenContext, low: number, high: number): number
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
	local below = GenMethods.bool(self, 1 / (1 + up / down))
	local offset = drawUniform(self, steps)
	if below then return origin - ((offset + 1) / (steps + 1)) * down end
	if offset == 0 then return 0 end
	return origin + (offset / (steps + 1)) * up
end

function GenMethods.float(self: GenImpl, lo: number?, hi: number?): number
	local low, high = if lo == nil then 0 else lo, if hi == nil then 1 else hi
	prop.checkRange("g:float", low, high, false)
	return prop.drawFloat(self, low, high)
end

local DEFAULT_OPTIONAL_WEIGHTS: { { any } } = { { 1, false }, { 1, true } }

function GenMethods.optional(self: GenImpl, gen: Generator<any>, absent: number?, present: number?): any
	checkGen("g:optional", gen)
	local weights: { { any } } = if absent == nil and present == nil
		then DEFAULT_OPTIONAL_WEIGHTS
		else { { absent or 1, false }, { present or 1, true } }
	return if GenMethods.weighted(self, weights) then gen(self) else nil
end

function GenMethods.tuple(self: GenImpl, first: any, ...: Generator<any>): { any }
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

function GenMethods.record(self: GenImpl, shape: { [string]: any }): { [string]: any }
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

function GenMethods.dict(
	self: GenImpl,
	keyGen: Generator<any>,
	valueGen: Generator<any>,
	min: number?,
	max: number?
): { [any]: any }
	checkGen("g:dict", keyGen)
	checkGen("g:dict", valueGen)
	local out = {}
	for _, pair in GenMethods.list(self, function(g: GenContext) return { keyGen(g), valueGen(g) } end, min, max) do
		out[pair[1]] = pair[2]
	end
	return out
end

function GenMethods.string(self: GenImpl, charset: (string | Generator<string>)?, min: number?, max: number?): string
	local each: Generator<string>
	if type(charset) == "function" then
		each = charset
	else
		local chars: string = if charset == nil then prop.CHARACTERS else charset
		if #chars == 0 then error("g:string: an empty charset", util.outside()) end
		local count = #chars
		each = function(g: any): string
			local index = 1 + drawUniform(g, count - 1)
			return string.sub(chars, index, index)
		end
	end
	return table.concat(GenMethods.list(self, each, min, max))
end

function GenMethods.bytes(self: GenImpl, min: number?, max: number?): buffer
	local least = min or 0
	if max ~= nil and least > max then error("g:bytes: min > max", util.outside()) end
	local octets = GenMethods.list(self, function(g: any) return drawUniform(g, 255) end, least, max)
	local b = buffer.create(#octets)
	for index, byte in octets do
		buffer.writeu8(b, index - 1, byte)
	end
	return b
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

function prop.isGen(value: any): boolean return type(value) == "table" and getmetatable(value) == GenMeta end

local function newGen(seed: number, size: number, forced: { number }?, exhaustive: boolean): GenImpl
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
	}
	return setmetatable({ size = size, seed = seed, exhaustive = exhaustive, _s = genState }, GenMeta) :: any
end

function prop.gen(seed: number?, size: number?, tape: { number }?): GenContext
	return newGen(if seed ~= nil then seed else DEFAULT_BASE, size or 40, tape, false)
end

function prop.exhaust(g: any, msg: string, level: number?): never
	if type(g) == "table" and type((g :: any)._s) == "table" then (g :: GenImpl)._s.exhausted = true end
	error(msg, if level == nil then 2 else level)
end

function prop.tape(g: GenContext): { number } return table.clone((g :: GenImpl)._s.out) end

function prop.mark(g: GenContext): number return #(g :: GenImpl)._s.out + 1 end

function prop.hint(g: GenContext, first: number, last: number, draws: { number })
	table.insert((g :: GenImpl)._s.hints, { first = first, last = last, draws = table.clone(draws) })
end

function prop.vacuous(g: GenContext, why: string?) (g :: GenImpl)._s.vacuous = if why ~= nil then why else true end

function prop.spans(g: GenContext): { Span }
	local spans = {}
	for index, span in (g :: GenImpl)._s.spans do
		spans[index] = table.clone(span)
	end
	return spans
end

local function simpler(a: { number }, b: { number }): boolean
	if #a ~= #b then return #a < #b end
	for index = 1, #a do
		if a[index] ~= b[index] then return a[index] < b[index] end
	end
	return false
end

type Case = {
	tape: { number },
	spans: { Span },
	hints: { Hint },
	message: string,
	notes: { string },
	exhausted: boolean?,
}

local function spanRanges(spans: { Span }, size: number): { { number } }
	local lists: { [number]: { Span } } = {}
	local order: { number } = {}
	for _, span in spans do
		local elements = lists[span.list]
		if elements == nil then
			elements = {}
			lists[span.list] = elements
			table.insert(order, span.list)
		end
		table.insert(elements, span)
	end
	table.sort(order)
	local ranges = {}
	for _, list in order do
		local elements = lists[list]
		table.sort(elements, function(a: Span, b: Span) return a.start < b.start end)
		local count = #elements
		if size > 0 then
			for first = count - size + 1, 1, -1 do
				table.insert(ranges, { elements[first].start, elements[first + size - 1].stop })
			end
		else
			local block = count // 2
			while block > 2 do
				for first = 1 + (count - 1) // block * block, 1, -block do
					table.insert(
						ranges,
						{ elements[first].start, elements[math.min(first + block, count + 1) - 1].stop }
					)
				end
				block //= 2
			end
		end
	end
	return ranges
end

local function hinted(tape: { number }, hints: { Hint }): { number }?
	local sorted = table.clone(hints)
	table.sort(sorted, function(a: Hint, b: Hint) return a.first > b.first end)
	local out, floor = tape, math.huge
	for _, hint in sorted do
		local spanLen = hint.last - hint.first + 1
		if hint.last < floor and #hint.draws <= spanLen then
			local copy = table.move(out, 1, hint.first - 1, 1, {})
			table.move(hint.draws, 1, #hint.draws, hint.first, copy)
			copy = table.move(out, hint.last + 1, #out, hint.first + #hint.draws, copy)
			if simpler(copy, out) then
				out = copy
				floor = hint.first
			end
		end
	end
	return if out ~= tape then out else nil
end

local function resolveNotes(raw: { NoteEntry }): { string }
	local out: { string } = {}
	for index, entry in raw do
		if type(entry) == "function" then
			local ok, text = pcall(entry)
			out[index] = if ok then tostring(text) else `(note raised: {format.errorText(text)})`
		else
			out[index] = entry
		end
	end
	return out
end

local function caseOf(gen: GenImpl, err: any): Case
	local state = gen._s
	return {
		tape = state.out,
		spans = state.spans,
		hints = state.hints,
		message = format.errorText(err),
		notes = resolveNotes(state.notes),
		exhausted = state.exhausted == true,
	}
end

local function isAssumedOut(gen: GenImpl, err: any): boolean return gen._s.assumedOut ~= nil or err == ASSUME_REJECT end

local function shrink(
	fn: PropFn,
	seed: number,
	size: number,
	exhaustive: boolean,
	failing: Case,
	limits: ShrinkBudget?
): (Case, number, boolean)
	local best, attempts = failing, 0
	local tries = if limits and limits.tries then limits.tries else SHRINK_ATTEMPTS
	local deadline = os.clock() + (if limits and limits.seconds then limits.seconds else SHRINK_SECONDS)

	local function budget(): boolean return attempts < tries and os.clock() < deadline end

	local function try(candidate: { number }): boolean
		if not budget() then return false end
		attempts += 1
		local gen = newGen(seed, size, candidate, exhaustive)
		local ok, err = pcall(fn :: (GenContext) -> ...any, gen)
		if
			ok
			or isAssumedOut(gen, err)
			or (gen._s.exhausted and not failing.exhausted)
			or not simpler(gen._s.out, best.tape)
		then
			return false
		end
		best = caseOf(gen, err)
		return true
	end

	local function with(index: number, value: number): { number }
		local copy = table.clone(best.tape)
		copy[index] = value
		return copy
	end

	local function without(first: number, last: number): { number }
		local copy = table.move(best.tape, 1, first - 1, 1, {})
		return table.move(best.tape, last + 1, #best.tape, first, copy)
	end

	local converged = false
	repeat
		local improved = false
		local all = hinted(best.tape, best.hints)
		if all ~= nil and try(all) then
			improved = true
		elseif all ~= nil then
			local cursor = 1
			while budget() and best.hints[cursor] ~= nil do
				local one = hinted(best.tape, { best.hints[cursor] })
				if one ~= nil and try(one) then
					improved = true
				else
					cursor += 1
				end
			end
		end
		-- Run binary-halving span deletion (`blocks == 0`) first so large failing lists shrink in O(log N) evaluations.
		for _, blocks in { 0, 2, 1 } do
			local cursor, ranges = 1, spanRanges(best.spans, blocks)
			while budget() do
				local range = ranges[cursor]
				if range == nil then break end
				if try(without(range[1], range[2])) then
					improved = true
					ranges = spanRanges(best.spans, blocks)
					cursor = 1
				else
					cursor += 1
				end
			end
		end
		for _, chunk in { 8, 4, 2, 1 } do
			local index = 1
			while index + chunk - 1 <= #best.tape and budget() do
				if try(without(index, index + chunk - 1)) then
					improved = true
				else
					index += 1
				end
			end
		end
		local index = 1
		while index <= #best.tape and budget() do
			local value = best.tape[index]
			if value > 0 and (try(with(index, 0)) or (value > 2 and try(with(index, value // 2)))) then
				improved = true
			elseif value > 1 and try(with(index, value - 1)) then
				improved = true
				local lo, hi = if value > 2 then value // 2 else 0, value - 1
				while hi - lo > 1 and budget() and best.tape[index] == hi do
					local mid = lo + (hi - lo) // 2
					if try(with(index, mid)) then
						hi = mid
					else
						lo = mid
					end
				end
			else
				index += 1
			end
		end
		converged = not improved and budget()
	until converged or not budget()

	return best, attempts, not converged
end

local function tapeText(tape: { number }): string
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
prop.tapeText = tapeText

local function indent(text: string, pad: string): string return (string.gsub(text, "\n([^\n])", "\n" .. pad .. "%1")) end

local Z_99 = 2.3263478740408408
local Z2_99 = Z_99 * Z_99
local MAX_TARGET_PER_LABEL = 2

local function sortedStringKeys(map: { [string]: any }): { string }
	local keys: { string } = {}
	for k in next, map do
		table.insert(keys, k)
	end
	table.sort(keys)
	return keys
end

local function formatClassifyLines(counts: { [string]: number }, total: number, pad: string): { string }
	if total <= 0 or next(counts) == nil then return {} end
	local keys = sortedStringKeys(counts)
	local lines = {}
	for _, label in keys do
		local hitCount = counts[label]
		local pct = hitCount * 100 / total
		table.insert(lines, `{pad}{label}: {hitCount}/{total} ({string.format("%.1f", pct)}%)`)
	end
	return lines
end

local function wilsonCoverFailure(coverStats: { [string]: { minPct: number, hits: number } }, total: number): string?
	if total <= 0 or next(coverStats) == nil then return nil end
	local keys = sortedStringKeys(coverStats)
	for _, label in keys do
		local entry = coverStats[label]
		local minPct = entry.minPct
		if minPct > 0 then
			local hits = entry.hits
			local pHat = hits / total
			local observedPct = pHat * 100
			if observedPct < minPct then
				local p0 = minPct / 100
				local denom = 1 + Z2_99 / total
				local center = pHat + Z2_99 / (2 * total)
				local rad = Z_99 * math.sqrt(math.max(0, pHat * (1 - pHat) / total + Z2_99 / (4 * total * total)))
				local upper = (center + rad) / denom
				if upper < p0 or (minPct == 100 and hits < total) then
					return `coverage check failed for "{label}": observed {hits}/{total} ({string.format(
						"%.1f",
						observedPct
					)}%, 99% upper bound {string.format("%.1f", upper * 100)}%) < required {string.format(
						"%.1f",
						minPct
					)}%`
				end
			end
		end
	end
	return nil
end

local function encodeTokenSafe(seed: number, size: number, tape: { number }): string?
	local ok, token = pcall(corpus.encode, seed, size, tape)
	if ok and type(token) == "string" then return token end
	return nil
end

local function emitRegressionMarker(fullName: string, file: string, seed: number, token: string)
	if registry.isolateDepth > 0 and registry.output.depth() == 0 then return end
	local payload = format.json({
		name = fullName,
		file = file,
		seed = seed,
		token = token,
	})
	registry.output.marker(`[sert-x:regression] {payload}`)
end

local function report(name: string, result: PropResult, where: string, replay: string, classLines: { string }?): string
	local lines = { `property "{name}" failed: {indent(result.message :: string, "   ")}` }
	if result.original ~= result.message then
		table.insert(lines, `   first failure: {indent(result.original :: string, "   ")}`)
	end
	table.insert(lines, `   {where}`)
	local tape, shrunk = result.tape :: { number }, result.shrunk :: { number }
	local stopped = if result.stopped then ", stopped by the shrink budget" else ""
	table.insert(
		lines,
		`   tape: {#tape} draw{if #tape == 1 then "" else "s"} → {#shrunk} after shrinking `
			.. `({result.attempts} attempt{if result.attempts == 1 then "" else "s"}{stopped}): {tapeText(shrunk)}`
	)
	local notes = result.notes :: { string }
	if #notes > 0 then
		table.insert(lines, "   trace:")
		for index, note in notes do
			if index > TRACE_LINES then
				table.insert(lines, `      … {#notes - TRACE_LINES} more`)
				break
			end
			table.insert(lines, "      " .. indent(note, "      "))
		end
	end
	if classLines ~= nil and #classLines > 0 then
		table.insert(lines, "   classification:")
		for _, line in classLines do
			table.insert(lines, line)
		end
	end
	table.insert(lines, `   {replay}`)
	if result.replay ~= nil then table.insert(lines, `   replay = "{result.replay}"`) end
	return table.concat(lines, "\n")
end

local function fail(
	fn: PropFn,
	seed: number,
	size: number,
	exhaustive: boolean,
	gen: GenImpl,
	err: any,
	limits: ShrinkBudget?
): PropResult
	local first = caseOf(gen, err)
	local best, attempts, stopped = shrink(fn, seed, size, exhaustive, first, limits)
	return {
		ok = false,
		cases = 0,
		exhaustive = exhaustive,
		message = best.message,
		original = first.message,
		seed = if exhaustive then nil else seed,
		tape = first.tape,
		shrunk = best.tape,
		notes = best.notes,
		attempts = attempts,
		stopped = stopped,
	}
end

local function tally(mark: (string | boolean)?, vacuous: boolean, why: string?): (boolean, string?)
	if mark == nil then return false, why end
	local nextWhy: string? = if why ~= nil then why elseif type(mark) == "string" then mark else "vacuous property"
	return vacuous, nextWhy
end

local function vacuity(name: string, cases: number, exhaustive: boolean, vacuous: boolean, why: string?): PropResult?
	if not vacuous then return nil end
	local reason = why or "assumption failed"
	local message = `{reason} in all {cases} {if exhaustive then "programs" else "cases"}`
	return {
		ok = false,
		cases = cases,
		exhaustive = exhaustive,
		message = message,
		original = message,
		report = `property "{name}" failed: {message}`,
		attempts = 0,
	}
end

local function printClassifyIfVerbose(
	fullName: string,
	run: RunOptions,
	isMutant: boolean,
	counts: { [string]: number },
	total: number
)
	if isMutant or run.quiet == true or run.silent == true or run.compact == true then return end
	if total <= 0 or next(counts) == nil then return end
	local lines = { `property "{fullName}" classification ({total} cases):` }
	for _, line in formatClassifyLines(counts, total, "   ") do
		table.insert(lines, line)
	end
	registry.output.print(table.concat(lines, "\n"))
end

type RegressionEntry = {
	raw: number | string,
	parsed: corpus.ReplaySpec,
}

local function appendRegressionItem(
	propName: string,
	item: any,
	outList: { RegressionEntry },
	seen: { [string]: boolean }
)
	if type(item) ~= "number" and type(item) ~= "string" then
		error(`property "{propName}": invalid regression entry {format.repr(item)}`, util.outside())
	end
	local parsed = corpus.parseReplay(item)
	if parsed == nil then
		error(`property "{propName}": invalid regression token {format.repr(item)}`, util.outside())
	end
	local dedupKey = if parsed.kind == "tape" then `tape:{item}` else `seed:{parsed.seed}`
	if seen[dedupKey] then return end
	seen[dedupKey] = true
	table.insert(outList, { raw = item, parsed = parsed })
end

local function collectFromBucket(
	propName: string,
	bucket: any,
	outList: { RegressionEntry },
	seen: { [string]: boolean }
)
	if type(bucket) == "table" then
		for i = 1, #bucket do
			appendRegressionItem(propName, bucket[i], outList, seen)
		end
	elseif type(bucket) == "string" or type(bucket) == "number" then
		appendRegressionItem(propName, bucket, outList, seen)
	end
end

local function collectRegressionsFromMap(
	propName: string,
	source: any,
	fullName: string,
	shortName: string,
	filter: string,
	file: string,
	outList: { RegressionEntry },
	seen: { [string]: boolean }
)
	if type(source) ~= "table" then return end
	if source[1] ~= nil then collectFromBucket(propName, source, outList, seen) end
	collectFromBucket(propName, source[fullName], outList, seen)
	if shortName ~= fullName then collectFromBucket(propName, source[shortName], outList, seen) end
	if filter ~= fullName and filter ~= shortName then collectFromBucket(propName, source[filter], outList, seen) end
	if file ~= "?" and type(source[file]) == "table" and source[file][1] == nil then
		local fileBucket = source[file]
		collectFromBucket(propName, fileBucket[fullName], outList, seen)
		if shortName ~= fullName then collectFromBucket(propName, fileBucket[shortName], outList, seen) end
		if filter ~= fullName and filter ~= shortName then
			collectFromBucket(propName, fileBucket[filter], outList, seen)
		end
	end
end

local function trailingSegment(fullName: string): string
	local tail = string.match(fullName, " > ([^>]+)$")
	return tail or fullName
end

type TargetPoolEntry = {
	score: number,
	tape: { number },
	ranges: { number },
}

local function mutateTape(
	tape: { number },
	ranges: { number },
	nextU: () -> number,
	altPool: { TargetPoolEntry }?
): { number }
	local copy = table.clone(tape)
	local len = #copy
	if len == 0 then return copy end

	local numEdits = if len > 1 and (nextU() % 4 == 0) then 2 else 1
	for _ = 1, numEdits do
		local idx = 1 + nextU() % len
		for _ = 1, 4 do
			if (ranges[idx] or 0) > 0 then break end
			idx = 1 + nextU() % len
		end
		local maxVal = math.max(ranges[idx] or 0, 0)
		if maxVal > 0 then
			local cur = copy[idx]
			local op = nextU() % 10
			if op < 3 then
				local step = if maxVal >= 4 and (nextU() % 2 == 0) then 1 + nextU() % math.min(4, maxVal) else 1
				local sign = if nextU() % 2 == 0 then 1 else -1
				copy[idx] = math.clamp(cur + sign * step, 0, maxVal)
			elseif op < 7 then
				local bits = 1
				local rem = maxVal
				while rem >= 2 and bits < 53 do
					bits += 1
					rem = rem // 2
				end
				local shift = nextU() % bits
				local step = math.floor(2 ^ shift)
				local sign = if nextU() % 2 == 0 then 1 else -1
				copy[idx] = math.clamp(cur + sign * step, 0, maxVal)
			elseif op == 7 and maxVal <= 0xFFFFFFFF and cur <= 0xFFFFFFFF then
				local bits = 1
				local rem = maxVal
				while rem >= 2 and bits < 32 do
					bits += 1
					rem = rem // 2
				end
				local bitIdx = nextU() % bits
				copy[idx] = math.clamp(bit32.bxor(cur, bit32.lshift(1, bitIdx)), 0, maxVal)
			elseif op == 8 then
				local edgePick = nextU() % 3
				copy[idx] = if edgePick == 0 then 0 elseif edgePick == 1 then maxVal else maxVal // 2
			else
				if maxVal < U32 - 1 then
					copy[idx] = nextU() % (maxVal + 1)
				else
					local wide = (nextU() % U21) * U32 + nextU() - 1
					copy[idx] = math.clamp(if maxVal < U53 then wide % (maxVal + 1) else wide, 0, maxVal)
				end
			end
		end
	end

	if len >= 2 and (nextU() % 10 == 0) then
		if altPool ~= nil and #altPool > 0 then
			local partner = altPool[1 + nextU() % #altPool]
			local pLen = #partner.tape
			if pLen > 1 then
				local cut = 1 + nextU() % math.min(len, pLen)
				for i = cut, pLen do
					local maxVal = math.max(ranges[i] or partner.ranges[i] or 0, 0)
					copy[i] = math.clamp(partner.tape[i], 0, maxVal)
				end
			end
		elseif len > 2 then
			local i = 1 + nextU() % len
			local j = 1 + nextU() % len
			if i ~= j then
				local rI = math.max(ranges[i] or 0, 0)
				local rJ = math.max(ranges[j] or 0, 0)
				local aVal, bVal = copy[i], copy[j]
				copy[i] = math.clamp(bVal, 0, rI)
				copy[j] = math.clamp(aVal, 0, rJ)
			end
		end
	end

	return copy
end

local function reportTargetToFuzz(fuzzCtrl: any, label: string, score: number, fullName: string)
	if type(fuzzCtrl) ~= "table" then return end
	if type(fuzzCtrl.onTarget) == "function" then pcall(fuzzCtrl.onTarget, label, score, fullName) end
	if type(fuzzCtrl.reportTarget) == "function" then pcall(fuzzCtrl.reportTarget, score, label, fullName) end
	if not table.isfrozen(fuzzCtrl) and getmetatable(fuzzCtrl) == nil then
		if fuzzCtrl.maxScore == nil or score > fuzzCtrl.maxScore then fuzzCtrl.maxScore = score end
		if fuzzCtrl.targets == nil then fuzzCtrl.targets = {} end
		if type(fuzzCtrl.targets) == "table" and not table.isfrozen(fuzzCtrl.targets) then
			local prev = fuzzCtrl.targets[label]
			if prev == nil or score > prev then fuzzCtrl.targets[label] = score end
		end
	end
end

local function finalizeFailure(
	fullName: string,
	filter: string,
	file: string,
	command: string,
	fn: PropFn,
	caseSeed: number,
	caseSize: number,
	exhaustive: boolean,
	gen: GenImpl,
	err: any,
	limits: ShrinkBudget?,
	isMutant: boolean,
	whereText: string,
	classCounts: { [string]: number },
	classTrials: number
): PropResult
	local res = fail(fn, caseSeed, caseSize, exhaustive, gen, err, limits)
	local tokenSeed = if exhaustive then 0 else caseSeed
	local token = encodeTokenSafe(tokenSeed, caseSize, res.shrunk :: { number })
	res.replay = token
	local replayCmd = if exhaustive
		then `replay: {command} --filter "{filter}" --exhaustive`
		else `replay: {command} --filter "{filter}" --replay={token or tostring(caseSeed)}`
	local classLines = formatClassifyLines(classCounts, classTrials, "      ")
	res.report = report(fullName, res, whereText, replayCmd, classLines)
	if not isMutant and token ~= nil then emitRegressionMarker(fullName, file, tokenSeed, token) end
	return res
end

local function runProperty(
	name: string,
	filter: string,
	fn: PropFn,
	options: PropOptions,
	runOptions: RunOptions?,
	capMutant: boolean?,
	fileOverride: string?,
	shortNameOverride: string?,
	fromRegistry: boolean?
): PropResult
	local run: RunOptions = runOptions or {}
	local command = run.command or "python3 tools/sert.py run"
	local current = registry.currentRun()
	local file: string = if fileOverride ~= nil and fileOverride ~= ""
		then fileOverride
		elseif options.file ~= nil then registry.normalizeSpecFile(options.file)
		elseif current ~= nil and current.file ~= "?" then current.file
		else "?"
	local shortName: string = shortNameOverride or trailingSegment(name)
	local isMutant = capMutant == true
		and options.capMutant ~= false
		and (run.mutant ~= nil or run.mutants ~= nil or (registry.isolateDepth == 0 and mutant.get() ~= nil))
	local shrinkLimits: ShrinkBudget? = if isMutant then MUTANT_SHRINK else options.shrinkBudget

	local classCounts: { [string]: number } = {}
	local classTrials = 0
	local coverStats: { [string]: { minPct: number, hits: number } } = {}
	local coverTrials = 0

	local function recordClassify(gInst: GenImpl)
		classTrials += 1
		local classified = gInst._s.classified
		if classified ~= nil then
			for label, hit in next, classified do
				classCounts[label] = (classCounts[label] or 0) + (if hit then 1 else 0)
			end
		end
	end

	local function recordCover(gInst: GenImpl)
		coverTrials += 1
		local covers = gInst._s.covers
		if covers ~= nil then
			for label, entry in next, covers do
				local stat = coverStats[label]
				if stat == nil then
					stat = { minPct = entry.minPct, hits = 0 }
					coverStats[label] = stat
				else
					stat.minPct = math.max(stat.minPct, entry.minPct)
				end
				if entry.hit then
					stat.hits += 1
				end
			end
		end
	end

	if run.exhaustive then
		local bound = options.exhaustive
		if bound == nil then error(`sert.prop "{name}": no exhaustive bound`, util.outside()) end
		local budget = run.budget or 600
		local deadline = os.clock() + budget
		local prefix: { number }, programs = {}, 0
		local vacuous, why: string? = true, nil
		while true do
			programs += 1
			local gen = newGen(0, bound.size, prefix, true)
			registry.recordAssertion("prop")
			local ok, err = pcall(fn :: (GenContext) -> ...any, gen)
			if not ok and isAssumedOut(gen, err) then
				if why == nil then why = gen._s.assumedOut or "assumption failed" end
			elseif not ok then
				recordClassify(gen)
				local res = finalizeFailure(
					name,
					filter,
					file,
					command,
					fn,
					0,
					bound.size,
					true,
					gen,
					err,
					shrinkLimits,
					isMutant,
					`exhaustive · size {bound.size} · program {programs} · tape {tapeText(gen._s.out)}`,
					classCounts,
					classTrials
				)
				res.cases = programs
				return res
			else
				vacuous, why = tally(gen._s.vacuous, vacuous, why)
				if gen._s.vacuous == nil then
					recordClassify(gen)
					recordCover(gen)
				end
			end
			local out, ranges = gen._s.out, gen._s.ranges
			local last = #out
			while last > 0 and out[last] >= ranges[last] do
				last -= 1
			end
			if last == 0 then
				local vac = vacuity(name, programs, true, vacuous, why)
				if vac ~= nil then return vac end
				local covFail = wilsonCoverFailure(coverStats, coverTrials)
				if covFail ~= nil then
					local covLines = { `property "{name}" failed: {covFail}` }
					local cLines = formatClassifyLines(classCounts, classTrials, "      ")
					if #cLines > 0 then
						table.insert(covLines, "   classification:")
						for _, line in cLines do
							table.insert(covLines, line)
						end
					end
					return {
						ok = false,
						cases = programs,
						exhaustive = true,
						message = covFail,
						original = covFail,
						report = table.concat(covLines, "\n"),
						attempts = 0,
					}
				end
				printClassifyIfVerbose(name, run, isMutant, classCounts, classTrials)
				return { ok = true, cases = programs, exhaustive = true, attempts = 0 }
			end
			prefix = table.move(out, 1, last, 1, {})
			prefix[last] += 1
			if os.clock() > deadline then
				local message =
					`exhaustive budget of {budget} s exceeded after {programs} programs (tape space not exhausted)`
				return {
					ok = false,
					cases = programs,
					exhaustive = true,
					message = message,
					original = message,
					report = `property "{name}" failed: {message}`,
					attempts = 0,
				}
			end
		end
	end

	local base = options.seed or run.seed or DEFAULT_BASE
	local size = options.size or 40

	if run.replay ~= nil then
		local replaySpec = corpus.parseReplay(run.replay)
		if replaySpec == nil then
			error(`property "{name}": malformed replay token {format.repr(run.replay)}`, util.outside())
		end
		local rSeed = replaySpec.seed
		local rSize = if replaySpec.kind == "tape" then replaySpec.size else size
		local rTape: { number }? = if replaySpec.kind == "tape" then replaySpec.tape else nil
		local gen = newGen(rSeed, rSize, rTape, false)
		registry.recordAssertion("prop")
		local ok, err = pcall(fn :: (GenContext) -> ...any, gen)
		if not ok and not isAssumedOut(gen, err) then
			recordClassify(gen)
			local replayLimits: ShrinkBudget? = if replaySpec.kind == "tape" then { tries = 0 } else shrinkLimits
			local res = finalizeFailure(
				name,
				filter,
				file,
				command,
				fn,
				rSeed,
				rSize,
				false,
				gen,
				err,
				replayLimits,
				isMutant,
				`seed: base {base} · replay · case seed {rSeed}`,
				classCounts,
				classTrials
			)
			res.cases = 1
			return res
		end
		if ok and gen._s.vacuous == nil then
			recordClassify(gen)
			printClassifyIfVerbose(name, run, isMutant, classCounts, classTrials)
		end
		return { ok = true, cases = 1, exhaustive = false, attempts = 0 }
	end

	local targetRuns = run.runs or options.runs or 100
	if isMutant then targetRuns = math.min(targetRuns, MUTANT_RUNS) end

	local fuzzCtrl: any = rawget(mutant._sharedG, "__SERT_FUZZ")
	local targetPools: { [string]: { TargetPoolEntry } } = {}
	local targetLabels: { string } = {}
	local reportedMax: { [string]: number } = {}
	local nameHash = fnv1a32(name)
	local mutRngState = caseSeedOf(nameHash, base, 0x7A96E7)
	if mutRngState == 0 then mutRngState = 1 end

	local function nextMut(): number
		mutRngState = xorshift32(mutRngState)
		return mutRngState
	end

	local function recordTargetSamples(gInst: GenImpl)
		local targets = gInst._s.targets
		if targets == nil then return end
		for label, score in next, targets do
			local prevMax = reportedMax[label]
			if prevMax == nil or score > prevMax then
				reportedMax[label] = score
				if not isMutant and type(fuzzCtrl) == "table" then reportTargetToFuzz(fuzzCtrl, label, score, name) end
			end
			local pool = targetPools[label]
			if pool == nil then
				pool = {}
				targetPools[label] = pool
				table.insert(targetLabels, label)
				table.sort(targetLabels)
			end
			if #pool < MAX_TARGET_PER_LABEL or score > pool[#pool].score then
				local entry: TargetPoolEntry = {
					score = score,
					tape = table.clone(gInst._s.out),
					ranges = table.clone(gInst._s.ranges),
				}
				table.insert(pool, entry)
				table.sort(pool, function(a: TargetPoolEntry, b: TargetPoolEntry) return a.score > b.score end)
				while #pool > MAX_TARGET_PER_LABEL do
					table.remove(pool)
				end
			end
		end
	end

	local regressions: { RegressionEntry } = {}
	local seenReg: { [string]: boolean } = {}
	collectRegressionsFromMap(name, run.regressions, name, shortName, filter, file, regressions, seenReg)
	collectRegressionsFromMap(
		name,
		rawget(mutant._sharedG, "__SERT_REGRESSIONS"),
		name,
		shortName,
		filter,
		file,
		regressions,
		seenReg
	)
	if options.regressions ~= nil then
		local optRegs = options.regressions :: { any }
		for i = 1, #optRegs do
			appendRegressionItem(name, optRegs[i], regressions, seenReg)
		end
	end

	local vacuous, why: string? = true, nil
	local validCases = 0
	local discards = 0
	local maxDiscards = math.max(targetRuns * 10, 100)

	local allowFuzz = not isMutant
		and type(fuzzCtrl) == "table"
		and type(fuzzCtrl.runProperty) == "function"
		and (
			not fuzzCtrl._isCliFuzzer
			or (
				registry.isolateDepth == 0
				and registry.output.depth() == 0
				and (fromRegistry == true or not registry.inline())
			)
		)

	if not (allowFuzz and fuzzCtrl._isCliFuzzer == true) then
		for regIndex, regEntry in regressions do
			local regSpec = regEntry.parsed
			local regSeed = regSpec.seed
			local regSize = if regSpec.kind == "tape" then regSpec.size else size
			local regTape: { number }? = if regSpec.kind == "tape" then regSpec.tape else nil
			local gen = newGen(regSeed, regSize, regTape, false)
			registry.recordAssertion("prop")
			local ok, err = pcall(fn :: (GenContext) -> ...any, gen)
			if not ok and isAssumedOut(gen, err) then
				discards += 1
				if why == nil then why = gen._s.assumedOut or "assumption failed" end
			elseif not ok then
				recordClassify(gen)
				local res = finalizeFailure(
					name,
					filter,
					file,
					command,
					fn,
					regSeed,
					regSize,
					false,
					gen,
					err,
					shrinkLimits,
					isMutant,
					`seed: base {base} · regression {regIndex} · case seed {regSeed}`,
					classCounts,
					classTrials
				)
				res.cases = validCases + 1
				return res
			else
				validCases += 1
				vacuous, why = tally(gen._s.vacuous, vacuous, why)
				if gen._s.vacuous == nil then
					recordClassify(gen)
					recordCover(gen)
					recordTargetSamples(gen)
				end
			end
		end
	end

	local regressionCount = validCases

	if allowFuzz then
		local fuzzCases = 0
		local fuzzSeq = 0
		local lastFailure: any = nil

		local function fuzzTrial(tapeOverride: { number }?, seedOverride: number?, sizeOverride: number?)
			fuzzSeq += 1
			local effSeed = if seedOverride ~= nil then seedOverride else caseSeedOf(nameHash, base, fuzzSeq)
			local effSize = if sizeOverride ~= nil then sizeOverride else size
			local tGen = newGen(effSeed, effSize, tapeOverride, false)
			registry.recordAssertion("prop")
			local tOk, tErr = pcall(fn :: (GenContext) -> ...any, tGen)
			if not tOk and isAssumedOut(tGen, tErr) then
				discards += 1
				if why == nil then why = tGen._s.assumedOut or "assumption failed" end
				local out: { [string]: any } = {
					ok = false,
					assumed = true,
					vacuous = false,
					tape = table.clone(tGen._s.out),
					ranges = table.clone(tGen._s.ranges),
					seed = effSeed,
					size = effSize,
					message = tGen._s.assumedOut or "assumption failed",
				}
				return out
			elseif not tOk then
				fuzzCases += 1
				recordClassify(tGen)
				local info: { [string]: any } = {
					ok = false,
					assumed = false,
					vacuous = false,
					tape = table.clone(tGen._s.out),
					ranges = table.clone(tGen._s.ranges),
					targets = if tGen._s.targets ~= nil then table.clone(tGen._s.targets) else nil,
					seed = effSeed,
					size = effSize,
					message = format.errorText(tErr),
					_gen = tGen,
					_err = tErr,
				}
				lastFailure = info
				return info
			else
				fuzzCases += 1
				vacuous, why = tally(tGen._s.vacuous, vacuous, why)
				if tGen._s.vacuous == nil then
					recordClassify(tGen)
					recordCover(tGen)
					recordTargetSamples(tGen)
				end
				local okOut: { [string]: any } = {
					ok = true,
					assumed = false,
					vacuous = tGen._s.vacuous ~= nil,
					tape = table.clone(tGen._s.out),
					ranges = table.clone(tGen._s.ranges),
					targets = if tGen._s.targets ~= nil then table.clone(tGen._s.targets) else nil,
					seed = effSeed,
					size = effSize,
				}
				return okOut
			end
		end

		local function fuzzShrink(
			failInfo: any?,
			seedOverride: number?,
			sizeOverride: number?,
			limitsOverride: ShrinkBudget?
		): PropResult
			local targetFail = if type(failInfo) == "table" and failInfo._gen ~= nil then failInfo else lastFailure
			if targetFail == nil then
				error(`property "{name}": shrinkFn called with no failing trial`, util.outside())
			end
			local sSeed = seedOverride or targetFail.seed
			local sSize = sizeOverride or targetFail.size
			local res = finalizeFailure(
				name,
				filter,
				file,
				command,
				fn,
				sSeed,
				sSize,
				false,
				targetFail._gen,
				targetFail._err,
				limitsOverride or shrinkLimits,
				isMutant,
				`seed: base {base} · fuzz · case seed {sSeed}`,
				classCounts,
				classTrials
			)
			res.cases = regressionCount + fuzzCases
			lastFailure = nil
			return res
		end

		local runFuzz: (any) -> any = fuzzCtrl.runProperty
		local ctrlRes = runFuzz({
			fn = fn,
			name = name,
			filter = filter,
			options = options,
			runOptions = run,
			trial = fuzzTrial,
			shrinkFn = fuzzShrink,
			meta = {
				name = name,
				shortName = shortName,
				filter = filter,
				file = file,
				baseSeed = base,
				size = size,
				runs = targetRuns,
				remainingRuns = math.max(0, targetRuns - regressionCount),
				maxDiscards = maxDiscards,
				regressionCount = regressionCount,
			},
		})

		if type(ctrlRes) == "table" then
			if ctrlRes._gen ~= nil and ctrlRes.ok == false and ctrlRes.assumed ~= true then
				return fuzzShrink(ctrlRes)
			end
			if type(ctrlRes.ok) == "boolean" then
				if ctrlRes.ok == false then
					if ctrlRes.report == nil and lastFailure ~= nil then return fuzzShrink(lastFailure) end
					return ctrlRes :: PropResult
				end
			end
		elseif lastFailure ~= nil then
			return fuzzShrink(lastFailure)
		end

		local fuzzTotal = regressionCount + fuzzCases
		local fuzzVac = vacuity(name, fuzzTotal, false, vacuous, why)
		if fuzzVac ~= nil then return fuzzVac end
		local fuzzCov = wilsonCoverFailure(coverStats, coverTrials)
		if fuzzCov ~= nil then
			local covLines = { `property "{name}" failed: {fuzzCov}` }
			local cLines = formatClassifyLines(classCounts, classTrials, "      ")
			if #cLines > 0 then
				table.insert(covLines, "   classification:")
				for _, line in cLines do
					table.insert(covLines, line)
				end
			end
			return {
				ok = false,
				cases = fuzzTotal,
				exhaustive = false,
				message = fuzzCov,
				original = fuzzCov,
				report = table.concat(covLines, "\n"),
				attempts = 0,
			}
		end
		printClassifyIfVerbose(name, run, isMutant, classCounts, classTrials)
		return { ok = true, cases = fuzzTotal, exhaustive = false, attempts = 0 }
	end

	local runIndex = 0
	local validGenerated = 0
	local mutatePhase = 0

	while validGenerated < targetRuns do
		runIndex += 1
		local caseSeed = caseSeedOf(nameHash, base, runIndex)
		local forcedTape: { number }? = nil
		if #targetLabels > 0 then
			local useTarget = (mutatePhase % 10 == 2 or mutatePhase % 10 == 5 or mutatePhase % 10 == 8)
			mutatePhase += 1
			if useTarget then
				local lbl = targetLabels[1 + nextMut() % #targetLabels]
				local pool = targetPools[lbl]
				if pool ~= nil and #pool > 0 then
					local pickIdx = if #pool > 1 and (nextMut() % 4 == 0) then 2 else 1
					local parent = pool[pickIdx]
					if #parent.tape > 0 then
						local altPool = if #targetLabels > 1
							then targetPools[targetLabels[1 + nextMut() % #targetLabels]]
							else pool
						forcedTape = mutateTape(parent.tape, parent.ranges, nextMut, altPool)
					end
				end
			end
		end
		local gen = newGen(caseSeed, size, forcedTape, false)
		registry.recordAssertion("prop")
		local ok, err = pcall(fn :: (GenContext) -> ...any, gen)
		if not ok and isAssumedOut(gen, err) then
			discards += 1
			if why == nil then why = gen._s.assumedOut or "assumption failed" end
			if discards > maxDiscards then
				local reason = why :: string
				local message =
					`{reason} (discarded {discards} cases, completed {validGenerated} of {targetRuns} required runs)`
				return {
					ok = false,
					cases = regressionCount + validGenerated,
					exhaustive = false,
					message = message,
					original = message,
					report = `property "{name}" failed: {message}`,
					attempts = 0,
				}
			end
		elseif not ok then
			recordClassify(gen)
			local res = finalizeFailure(
				name,
				filter,
				file,
				command,
				fn,
				caseSeed,
				size,
				false,
				gen,
				err,
				shrinkLimits,
				isMutant,
				`seed: base {base} · run {runIndex} of {targetRuns} · case seed {caseSeed}`,
				classCounts,
				classTrials
			)
			res.cases = regressionCount + validGenerated + 1
			return res
		else
			validGenerated += 1
			vacuous, why = tally(gen._s.vacuous, vacuous, why)
			if gen._s.vacuous == nil then
				recordClassify(gen)
				recordCover(gen)
				recordTargetSamples(gen)
			end
		end
	end

	local totalCases = regressionCount + validGenerated
	local vacResult = vacuity(name, totalCases, false, vacuous, why)
	if vacResult ~= nil then return vacResult end
	local covFail = wilsonCoverFailure(coverStats, coverTrials)
	if covFail ~= nil then
		local covLines = { `property "{name}" failed: {covFail}` }
		local cLines = formatClassifyLines(classCounts, classTrials, "      ")
		if #cLines > 0 then
			table.insert(covLines, "   classification:")
			for _, line in cLines do
				table.insert(covLines, line)
			end
		end
		return {
			ok = false,
			cases = totalCases,
			exhaustive = false,
			message = covFail,
			original = covFail,
			report = table.concat(covLines, "\n"),
			attempts = 0,
		}
	end
	printClassifyIfVerbose(name, run, isMutant, classCounts, classTrials)
	return { ok = true, cases = totalCases, exhaustive = false, attempts = 0 }
end

function prop.run(
	name: string,
	fn: PropFn,
	options: PropOptions?,
	runOptions: RunOptions?,
	capMutant: boolean?,
	filter: string?
): PropResult
	return runProperty(name, filter or name, fn, options or {}, runOptions, capMutant)
end

local function validatePropOptions(where: string, options: PropOptions?)
	if options == nil then return end
	registry.checkKeys(where, "option", options, PROP_OPTIONS)
	local targetVal: any = options.target
	if targetVal ~= nil and (type(targetVal) ~= "string" or not VALID_TARGETS[targetVal]) then
		error(
			`{where}: invalid target {format.repr(targetVal)} (expected portable, roblox, server, or client)`,
			util.outside()
		)
	end
	if options.shrinkBudget ~= nil then
		registry.checkKeys(`{where}.shrinkBudget`, "field", options.shrinkBudget, SHRINK_BUDGET_KEYS)
	end
	if options.exhaustive ~= nil then
		registry.checkKeys(`{where}.exhaustive`, "field", options.exhaustive, EXHAUSTIVE_KEYS)
		local sz = options.exhaustive.size
		if type(sz) ~= "number" or sz ~= math.floor(sz) or sz < 0 then
			error(`{where}.exhaustive: expected integer size >= 0, got {format.repr(sz)}`, util.outside())
		end
	end
	if options.runs ~= nil and (type(options.runs) ~= "number" or options.runs < 1) then
		error(`{where}: expected runs >= 1, got {format.repr(options.runs)}`, util.outside())
	end
end

local NOOP_TEST: registry.TestFn = function() end

local function definePropEntry(
	name: string,
	fn: PropFn?,
	mode: registry.Mode,
	target: Target?,
	focused: boolean,
	options: PropOptions?
)
	local effectiveSkip = mode == "skip" or (options ~= nil and options.skip == true)
	if registry.inline() then
		if effectiveSkip or fn == nil then return end
		local current = registry.currentRun() :: registry.Current
		local fullName = `{current.name} > {name}`
		local runOpts = registry.currentOptions()
		local seeded = if runOpts ~= nil and runOpts.seeds ~= nil then runOpts.seeds[current.name] else nil
		if seeded ~= nil and runOpts ~= nil and runOpts.replay == nil then
			local cloned = table.clone(runOpts)
			cloned.replay = seeded
			runOpts = cloned
		end
		local capMutant = (runOpts ~= nil and (runOpts.mutant ~= nil or runOpts.mutants ~= nil))
			or (registry.isolateDepth == 0 and mutant.get() ~= nil)
		local result = runProperty(fullName, current.name, fn, options or {}, runOpts, capMutant, current.file, name)
		if not result.ok then
			if result.seed ~= nil then registry.recordInlineSeed(current.name, result.seed) end
			error(result.report or result.message or "property failed", 0)
		end
		return
	end

	local testOpts: registry.TestOptions? = if options ~= nil
		then {
			timeout = options.timeout,
			skip = options.skip,
			focus = options.focus,
			file = options.file,
			target = options.target,
		}
		else nil

	if effectiveSkip or fn == nil then
		registry.registerEntry(name, NOOP_TEST, "skip", target, focused, testOpts, nil)
		return
	end

	local propFn = fn :: PropFn
	local shortName = name
	local attachment: registry.PropAttachment
	local registeredEntry: registry.Test
	attachment = {
		name = name,
		exhaustive = if options ~= nil then options.exhaustive else nil,
		defaultSeed = if options ~= nil and options.seed ~= nil then options.seed else DEFAULT_BASE,
		exec = function(runOptions: RunOptions, capMutant: boolean): registry.PropExecResult
			return runProperty(
				attachment.name,
				attachment.name,
				propFn,
				options or {},
				runOptions,
				capMutant,
				registeredEntry.file,
				shortName,
				true
			)
		end,
	}
	registeredEntry = registry.registerEntry(name, function()
		local res = runProperty(
			attachment.name,
			attachment.name,
			propFn,
			options or {},
			registry.currentOptions(),
			false,
			registeredEntry.file,
			shortName,
			true
		)
		if not res.ok then error(res.report or res.message or "property failed", 0) end
	end, "run", target, focused, testOpts, attachment)
end

local function buildPropNamespace(
	apiPrefix: string,
	target: Target?,
	fixedMode: registry.Mode?,
	fixedFocus: boolean,
	baseTable: { [string]: any }?
): TargetPropApi
	local function propLabel(name: any): string
		return if type(name) == "string" then `sert.{apiPrefix}("{name}")` else `sert.{apiPrefix}`
	end

	local function callProp(name: string, fn: PropFn?, options: PropOptions?)
		registry.checkName(apiPrefix, name)
		if fixedMode == "skip" and fn == nil then
			validatePropOptions(propLabel(name), options)
			definePropEntry(name, nil, "skip", target, fixedFocus, options)
			return
		end
		registry.checkFn(apiPrefix, name, fn, options, "(name, fn, opts?)")
		validatePropOptions(propLabel(name), options)
		definePropEntry(name, fn, fixedMode or "run", target, fixedFocus, options)
	end

	local function eachFn<T>(cases: { T })
		if type(cases) ~= "table" then
			error(`sert.{apiPrefix}.each: expected a table of cases, got {util.typeof(cases)}`, util.outside())
		end
		return function(fmt: EachFormat<T>, fn: (case: T, g: GenContext) -> (), options: PropOptions?)
			if fixedMode ~= "skip" or fn ~= nil then
				registry.checkFn(`{apiPrefix}.each`, fmt, fn, options, "(cases)(fmt, fn, opts?)")
			end
			validatePropOptions(`sert.{apiPrefix}.each`, options)
			for index = 1, #cases do
				local item = cases[index]
				local title = registry.formatEachTitle(fmt, item, false, 1, index)
				local body: PropFn? = if fn == nil then nil else function(g: GenContext) fn(item, g) end
				definePropEntry(title, body, fixedMode or "run", target, fixedFocus, options)
			end
		end
	end

	local function eachTupleFn(tuples: { { any } })
		if type(tuples) ~= "table" then
			error(
				`sert.{apiPrefix}.eachTuple: expected a table of tuple rows, got {util.typeof(tuples)}`,
				util.outside()
			)
		end
		return function(fmt: EachFormat<{ any }>, fn: (...any) -> (), options: PropOptions?)
			if fixedMode ~= "skip" or fn ~= nil then
				registry.checkFn(`{apiPrefix}.eachTuple`, fmt, fn, options, "(tuples)(fmt, fn, opts?)")
			end
			validatePropOptions(`sert.{apiPrefix}.eachTuple`, options)
			for index = 1, #tuples do
				local row = tuples[index]
				if type(row) ~= "table" then
					error(
						`sert.{apiPrefix}.eachTuple: row {index} must be a table, got {util.typeof(row)}`,
						util.outside()
					)
				end
				local rowAny: { [any]: any } = row :: any
				local rowLen = if type(rawget(rowAny, "n")) == "number" then rawget(rowAny, "n") :: number else #row
				local title = registry.formatEachTitle(fmt, row, true, rowLen, index)
				local body: PropFn? = if fn == nil
					then nil
					else function(g: GenContext)
						local unpacked = table.move(row, 1, rowLen, 1, {})
						unpacked[rowLen + 1] = g
						fn(table.unpack(unpacked, 1, rowLen + 1))
					end
				definePropEntry(title, body, fixedMode or "run", target, fixedFocus, options)
			end
		end
	end

	local ns: { [string]: any } = baseTable or {}
	ns.each = eachFn
	ns.eachTuple = eachTupleFn

	if fixedMode == nil and not fixedFocus then
		ns.skip = buildPropNamespace(`{apiPrefix}.skip`, target, "skip", false, nil)
		ns.focus = buildPropNamespace(`{apiPrefix}.focus`, target, "run", true, nil)
	else
		ns.skip = function(name: string, fn: PropFn?, options: PropOptions?)
			registry.checkName(`{apiPrefix}.skip`, name)
			if fn ~= nil then registry.checkFn(`{apiPrefix}.skip`, name, fn, options, "(name, fn?, opts?)") end
			validatePropOptions(`sert.{apiPrefix}.skip("{name}")`, options)
			definePropEntry(name, fn, "skip", target, false, options)
		end
		ns.focus = function(name: string, fn: PropFn, options: PropOptions?)
			registry.checkName(`{apiPrefix}.focus`, name)
			registry.checkFn(`{apiPrefix}.focus`, name, fn, options, "(name, fn, opts?)")
			validatePropOptions(`sert.{apiPrefix}.focus("{name}")`, options)
			definePropEntry(name, fn, "run", target, true, options)
		end
	end

	return (
		setmetatable(ns, {
			__call = function(_self: any, name: string, fn: PropFn, options: PropOptions?) callProp(name, fn, options) end,
		}) :: any
	) :: TargetPropApi
end

buildPropNamespace("prop", nil, nil, false, prop)
prop.roblox = buildPropNamespace("prop.roblox", "roblox", nil, false, nil)
prop.server = buildPropNamespace("prop.server", "server", nil, false, nil)
prop.client = buildPropNamespace("prop.client", "client", nil, false, nil)

return (prop :: any) :: PropNamespace
