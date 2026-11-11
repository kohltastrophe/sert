--!strict
-- Property testing engine (`sert.prop`): tape draws, shrinking, bounded-exhaustive enumeration, assumption tracking, and replay.

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
}

export type Gen = GenContext
export type Generator<T> = (g: GenContext) -> T
export type PropFn = (g: GenContext) -> ()

export type PropOptions = typeof(table.freeze({} :: {
	runs: number?,
	size: number?,
	seed: number?,
	regressions: { number }?,
	exhaustive: registry.ExhaustiveOption?,
	shrinkBudget: ShrinkBudget?,
	timeout: number?,
	skip: boolean?,
	focus: boolean?,
	file: string?,
	target: Target?,
}))

export type PropResult = {
	ok: boolean,
	cases: number,
	exhaustive: boolean,
	report: string?,
	message: string?,
	original: string?,
	seed: number?,
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
local MUTANT_RUNS = 15
local MUTANT_SHRINK: ShrinkBudget = { tries = 0, seconds = 0 }
local FLOAT_STEPS = U32 - 1

local ASSUME_REJECT = table.freeze({})
local GENERATOR_MARKS: { [any]: boolean } = setmetatable({}, { __mode = "k" }) :: any

local xorshift32 = rng.xorshift32
local fnv1a32 = rng.fnv1a32
local mutant = registry.mutant

local PROP_OPTIONS = {
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

local function report(name: string, result: PropResult, where: string, replay: string): string
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
	table.insert(lines, `   {replay}`)
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

local function parseReplaySeed(raw: (number | string)?): number?
	if type(raw) == "number" then return raw end
	if type(raw) == "string" then return tonumber(raw) end
	return nil
end

local function runProperty(
	name: string,
	filter: string,
	fn: PropFn,
	options: PropOptions,
	runOptions: RunOptions?,
	capMutant: boolean?
): PropResult
	local run: RunOptions = runOptions or {}
	local command = run.command or "python3 tools/sert.py run"
	local isMutant = capMutant == true and mutant.get() ~= nil
	local shrinkLimits: ShrinkBudget? = if isMutant then MUTANT_SHRINK else options.shrinkBudget

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
			local ok, err = pcall(fn :: (GenContext) -> ...any, gen)
			if not ok and isAssumedOut(gen, err) then
				if why == nil then why = gen._s.assumedOut or "assumption failed" end
			elseif not ok then
				local result = fail(fn, 0, bound.size, true, gen, err, shrinkLimits)
				result.cases = programs
				result.report = report(
					name,
					result,
					`exhaustive · size {bound.size} · program {programs} · tape {tapeText(gen._s.out)}`,
					`replay: {command} --filter "{filter}" --exhaustive`
				)
				return result
			else
				vacuous, why = tally(gen._s.vacuous, vacuous, why)
			end
			local out, ranges = gen._s.out, gen._s.ranges
			local last = #out
			while last > 0 and out[last] >= ranges[last] do
				last -= 1
			end
			if last == 0 then
				return vacuity(name, programs, true, vacuous, why)
					or { ok = true, cases = programs, exhaustive = true, attempts = 0 }
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
	local replaySeed = parseReplaySeed(run.replay)

	if replaySeed ~= nil then
		local gen = newGen(replaySeed, size, nil, false)
		local ok, err = pcall(fn :: (GenContext) -> ...any, gen)
		if not ok and not isAssumedOut(gen, err) then
			local result = fail(fn, replaySeed, size, false, gen, err, shrinkLimits)
			result.cases = 1
			result.report = report(
				name,
				result,
				`seed: base {base} · replay · case seed {replaySeed}`,
				`replay: {command} --filter "{filter}" --replay={replaySeed}`
			)
			return result
		end
		return { ok = true, cases = 1, exhaustive = false, attempts = 0 }
	end

	local targetRuns = run.runs or options.runs or 100
	if isMutant then targetRuns = math.min(targetRuns, MUTANT_RUNS) end

	local vacuous, why: string? = true, nil
	local validCases = 0
	local discards = 0
	local maxDiscards = math.max(targetRuns * 10, 100)

	for regIndex, regSeed in (options.regressions or {}) :: { number } do
		local gen = newGen(regSeed, size, nil, false)
		local ok, err = pcall(fn :: (GenContext) -> ...any, gen)
		if not ok and isAssumedOut(gen, err) then
			discards += 1
			if why == nil then why = gen._s.assumedOut or "assumption failed" end
		elseif not ok then
			local result = fail(fn, regSeed, size, false, gen, err, shrinkLimits)
			result.cases = validCases + 1
			result.report = report(
				name,
				result,
				`seed: base {base} · regression {regIndex} · case seed {regSeed}`,
				`replay: {command} --filter "{filter}" --replay={regSeed}`
			)
			return result
		else
			validCases += 1
			vacuous, why = tally(gen._s.vacuous, vacuous, why)
		end
	end

	local regressionCount = validCases
	local nameHash = fnv1a32(name)
	local runIndex = 0
	local validGenerated = 0

	while validGenerated < targetRuns do
		runIndex += 1
		local caseSeed = caseSeedOf(nameHash, base, runIndex)
		local gen = newGen(caseSeed, size, nil, false)
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
			local result = fail(fn, caseSeed, size, false, gen, err, shrinkLimits)
			result.cases = regressionCount + validGenerated + 1
			result.report = report(
				name,
				result,
				`seed: base {base} · run {runIndex} of {targetRuns} · case seed {caseSeed}`,
				`replay: {command} --filter "{filter}" --replay={caseSeed}`
			)
			return result
		else
			validGenerated += 1
			vacuous, why = tally(gen._s.vacuous, vacuous, why)
		end
	end

	local totalCases = regressionCount + validGenerated
	return vacuity(name, totalCases, false, vacuous, why)
		or { ok = true, cases = totalCases, exhaustive = false, attempts = 0 }
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
		local result = prop.run(fullName, fn, options, runOpts, current.last, current.name)
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
	local attachment: registry.PropAttachment
	attachment = {
		name = name,
		exhaustive = if options ~= nil then options.exhaustive else nil,
		defaultSeed = if options ~= nil and options.seed ~= nil then options.seed else DEFAULT_BASE,
		exec = function(runOptions: RunOptions, capMutant: boolean): registry.PropExecResult
			return prop.run(attachment.name, propFn, options, runOptions, capMutant, attachment.name)
		end,
	}
	registry.registerEntry(name, function()
		local res = prop.run(attachment.name, propFn, options, registry.currentOptions(), false, attachment.name)
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
