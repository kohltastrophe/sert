--!strict
-- Property testing engine (`sert.prop`): tape draws, shrinking, bounded-exhaustive enumeration, and replay.

local format = require("./format")
local rng = require("./rng")
local util = require("./util")

-- selene: allow(global_usage)
local SHARED_G: { [string]: any } = (
	if type(_G) == "table" and not table.isfrozen(_G) then _G :: any else setmetatable({}, { __index = _G })
) :: { [string]: any }
local MUTANT_WAIT_LIMIT = 25000
local waitCount, waitMutant: any = 0, nil

local mutant = {
	_sharedG = SHARED_G,
	parsed = nil :: { id: number, outer: number }?,
}

function mutant.share()
	local gf: any, sf: any = getfenv :: any, setfenv :: any
	if gf == nil or sf == nil then return end
	local ok0, g0 = pcall(gf, 0)
	if ok0 and type(g0) == "table" and g0._G ~= SHARED_G then
		local _ok = pcall(sf, 0, setmetatable({ _G = SHARED_G }, { __index = g0 }))
	end
	for level = 2, 16 do
		local ok, envTable = pcall(gf, level)
		if not ok then break end
		if type(envTable) == "table" and not table.isfrozen(envTable) and rawget(envTable, "_G") ~= SHARED_G then
			rawset(envTable, "_G", SHARED_G)
			local _ok = pcall(sf, level, envTable)
		end
	end
end

function mutant.waitGuard()
	local current = rawget(SHARED_G, "__SERT_MUTANT")
	if type(current) ~= "number" or current <= 0 then return end
	if current ~= waitMutant then
		waitMutant, waitCount = current, 0
	end
	waitCount += 1
	if waitCount > MUTANT_WAIT_LIMIT then error("sert.env: task.wait loop limit exceeded during mutation test", 0) end
end

function mutant.get(): number?
	local id = rawget(SHARED_G, "__SERT_MUTANT")
	return if type(id) == "number" then id else nil
end

function mutant.set(id: number?) rawset(SHARED_G, "__SERT_MUTANT", if id ~= 0 then id else nil) end

export type Shard = {
	name: string,
	index: number,
	count: number,
	runLimit: number,
	only: { string }?,
	except: { string }?,
}

local U32 = 2 ^ 32
local GOLDEN = 0x9E3779B9
local DEFAULT_BASE = 0x5EED
local SHRINK_ATTEMPTS = 500
local SHRINK_SECONDS = 2
local TRACE_LINES = 200
local MUTANT_RUNS = 15
local MUTANT_SHRINK: ShrinkBudget = { tries = 0, seconds = 0 }

local xorshift32 = rng.xorshift32
local fnv1a32 = rng.fnv1a32

export type RunOptions = {
	filter: string?,
	filters: { string }?,
	names: { string }?,
	excludes: { string }?,
	files: { string }?,
	shard: (Shard | boolean)?,
	list: boolean?,
	raise: boolean?,
	silent: boolean?,
	markers: boolean?,
	timeout: number?,
	requireTests: boolean?,
	rtestOnly: boolean?,
	seed: number?,
	replay: number?,
	seeds: { [string]: number }?,
	runs: number?,
	exhaustive: boolean?,
	budget: number?,
	command: string?,
	failFast: boolean?,
	mutant: number?,
	mutants: { number }?,
}

export type PropOptions = {
	runs: number?,
	size: number?,
	seed: number?,
	regressions: { number }?,
	exhaustive: { size: number }?,
	rtest: boolean?,
	shrinkBudget: ShrinkBudget?,
	timeout: number?,
	skip: boolean?,
	focus: boolean?,
	file: string?,
}

export type ShrinkBudget = { tries: number?, seconds: number? }
export type Span = { start: number, stop: number, list: number }
export type Hint = { first: number, last: number, draws: { number } }

export type Gen = {
	size: number,
	seed: number,
	exhaustive: boolean,
	int: (self: Gen, lo: number, hi: number) -> number,
	float: (self: Gen, lo: number?, hi: number?) -> number,
	bool: (self: Gen, p: number?) -> boolean,
	pick: <T>(self: Gen, items: { T }) -> T,
	weighted: (self: Gen, pairs: { { any } }) -> any,
	optional: <T>(self: Gen, gen: (Gen) -> T, absent: number?, present: number?) -> T?,
	tuple: (self: Gen, first: any, ...((Gen) -> any)) -> { any },
	record: (self: Gen, shape: { [string]: any }) -> { [string]: any },
	dict: <K, V>(self: Gen, keyGen: (Gen) -> K, valueGen: (Gen) -> V, min: number?, max: number?) -> { [K]: V },
	list: <T>(self: Gen, gen: (Gen) -> T, min: number?, max: number?) -> { T },
	string: (self: Gen, charset: (string | (Gen) -> string)?, min: number?, max: number?) -> string,
	bytes: (self: Gen, min: number?, max: number?) -> buffer,
	note: (self: Gen, fmt: string | (() -> string), ...any) -> (),
}

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

export type PropFn = (Gen) -> ()

local prop = {
	mutant = mutant,
	DEFAULT_BASE = DEFAULT_BASE,
	CHARACTERS = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789 _-.;:'\"",
}

local function caseSeedOf(nameHash: number, base: number, run: number): number
	return bit32.bxor(nameHash, base % U32, (run * GOLDEN) % U32)
end

function prop.caseSeed(name: string, base: number, run: number): number return caseSeedOf(fnv1a32(name), base, run) end

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
	exhausted: boolean?,
}
type GenImpl = Gen & { _s: GenState }

local function nextU32(self: GenImpl): number
	local state = self._s
	state.rng = xorshift32(state.rng)
	return state.rng
end

local U21, U53 = 2 ^ 21, 2 ^ 53

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

prop.checkRange = rng.checkRange

local GenMethods = {}

function prop.drawInt(g: Gen, lo: number, hi: number): number
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
	if #items == 0 then error("g:pick: empty array", 2) end
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
	if count == 0 then error("g:weighted: no item with a positive weight", 2) end
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

local function checkGen(api: string, gen: any)
	if type(gen) ~= "function" then
		error(`{api}: expected a generator (a function (g) -> value), got {typeof(gen)}`, util.outside())
	end
end

function GenMethods.list(self: GenImpl, gen: (Gen) -> any, min: number?, max: number?): { any }
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

local FLOAT_STEPS = U32 - 1

function prop.drawFloat(g: Gen, low: number, high: number): number
	local self = g :: GenImpl
	local origin = math.clamp(0, low, high)
	local up, down = high - origin, origin - low
	if up <= 0 and down <= 0 then return low end
	local steps = if self._s.exhaustive then math.max(self.size, 1) else FLOAT_STEPS
	local below = if up <= 0 then true elseif down <= 0 then false else GenMethods.bool(self, 1 / (1 + up / down))
	local offset = drawUniform(self, steps)
	return if below then origin - (offset + 1) / (steps + 1) * down else origin + offset / (steps + 1) * up
end

function GenMethods.float(self: GenImpl, lo: number?, hi: number?): number
	local low, high = if lo == nil then 0 else lo, if hi == nil then 1 else hi
	prop.checkRange("g:float", low, high, false)
	return prop.drawFloat(self, low, high)
end

local DEFAULT_OPTIONAL_WEIGHTS: { { any } } = { { 1, false }, { 1, true } }

function GenMethods.optional(self: GenImpl, gen: (Gen) -> any, absent: number?, present: number?): any
	checkGen("g:optional", gen)
	local weights: { { any } } = if absent == nil and present == nil
		then DEFAULT_OPTIONAL_WEIGHTS
		else { { absent or 1, false }, { present or 1, true } }
	return if GenMethods.weighted(self, weights) then gen(self) else nil
end

function GenMethods.tuple(self: GenImpl, first: any, ...: (Gen) -> any): { any }
	if type(first) == "table" then
		local gens = first :: { (Gen) -> any }
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
	values[1] = (first :: (Gen) -> any)(self)
	for index = 1, count - 1 do
		local each = select(index, ...)
		checkGen("g:tuple", each)
		values[index + 1] = each(self)
	end
	return values
end

function GenMethods.record(self: GenImpl, shape: { [string]: any }): { [string]: any }
	local keys = {}
	for key in shape do
		table.insert(keys, key)
	end
	table.sort(keys)
	local value = {}
	for _, key in keys do
		local field: any = shape[key]
		value[key] = if type(field) == "function" then (field :: (Gen) -> any)(self) else field
	end
	return value
end

function GenMethods.dict(
	self: GenImpl,
	keyGen: (Gen) -> any,
	valueGen: (Gen) -> any,
	min: number?,
	max: number?
): { [any]: any }
	checkGen("g:dict", keyGen)
	checkGen("g:dict", valueGen)
	local out = {}
	for _, pair in GenMethods.list(self, function(g: Gen) return { keyGen(g), valueGen(g) } end, min, max) do
		out[pair[1]] = pair[2]
	end
	return out
end

function GenMethods.string(self: GenImpl, charset: (string | (Gen) -> string)?, min: number?, max: number?): string
	local each: (Gen) -> string
	if type(charset) == "function" then
		each = charset
	else
		local chars: string = if charset == nil then prop.CHARACTERS else charset
		if #chars == 0 then error("g:string: an empty charset", 2) end
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
	if max ~= nil and least > max then error("g:bytes: min > max", 2) end
	local octets = GenMethods.list(self, function(g: any) return drawUniform(g, 255) end, least, max)
	local b = buffer.create(#octets)
	for index, byte in octets do
		buffer.writeu8(b, index - 1, byte)
	end
	return b
end

local GenMeta = { __index = GenMethods }

function prop.isGen(value: any): boolean return getmetatable(value) == GenMeta end

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
		exhausted = false,
	}
	return setmetatable({ size = size, seed = seed, exhaustive = exhaustive, _s = genState }, GenMeta) :: any
end

function prop.gen(seed: number, size: number?, tape: { number }?): Gen return newGen(seed, size or 40, tape, false) end

function prop.exhaust(g: any, msg: string, level: number?): never
	if type(g) == "table" and type((g :: any)._s) == "table" then (g :: GenImpl)._s.exhausted = true end
	error(msg, if level == nil then 2 else level)
end

function prop.tape(g: Gen): { number } return table.clone((g :: GenImpl)._s.out) end

function prop.mark(g: Gen): number return #(g :: GenImpl)._s.out + 1 end

function prop.hint(g: Gen, first: number, last: number, draws: { number })
	table.insert((g :: GenImpl)._s.hints, { first = first, last = last, draws = table.clone(draws) })
end

function prop.vacuous(g: Gen, why: string?) (g :: GenImpl)._s.vacuous = if why ~= nil then why else true end

function prop.spans(g: Gen): { Span }
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
		if hint.last < floor and #hint.draws < hint.last - hint.first + 1 then
			local copy = table.move(out, 1, hint.first - 1, 1, {})
			table.move(hint.draws, 1, #hint.draws, hint.first, copy)
			out = table.move(out, hint.last + 1, #out, hint.first + #hint.draws, copy)
			floor = hint.first
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
		local ok, err = pcall(fn :: (Gen) -> ...any, gen)
		if ok or (gen._s.exhausted and not failing.exhausted) or not simpler(gen._s.out, best.tape) then
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
		for _, blocks in { 1, 2, 0 } do
			local cursor, ranges = 1, spanRanges(best.spans, blocks)
			while budget() do
				local range = ranges[cursor]
				if range == nil then break end
				if try(without(range[1], range[2])) then
					improved = true
					ranges = spanRanges(best.spans, blocks)
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
	if mark == nil then return false, nil end
	return vacuous, why or (if type(mark) == "string" then mark else nil)
end

local function vacuity(name: string, cases: number, exhaustive: boolean, vacuous: boolean, why: string?): PropResult?
	if not vacuous or why == nil then return nil end
	local message = `{why} in all {cases} {if exhaustive then "programs" else "cases"}`
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
		if bound == nil then error(`sert.prop "{name}": no exhaustive bound`, 2) end
		local budget = run.budget or 600
		local deadline = os.clock() + budget
		local prefix: { number }, programs = {}, 0
		local vacuous, why = true, nil
		while true do
			programs += 1
			local gen = newGen(0, bound.size, prefix, true)
			local ok, err = pcall(fn :: (Gen) -> ...any, gen)
			vacuous, why = tally(gen._s.vacuous, vacuous, why)
			if not ok then
				local result = fail(fn, 0, bound.size, true, gen, err, shrinkLimits)
				result.cases = programs
				result.report = report(
					name,
					result,
					`exhaustive · size {bound.size} · program {programs} · tape {tapeText(gen._s.out)}`,
					`replay: {command} --filter "{filter}" --exhaustive`
				)
				return result
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
	local cases: { { label: string?, index: number, seed: number } } = {}
	local runs = 0
	if run.replay ~= nil then
		table.insert(cases, { label = "replay", index = 0, seed = run.replay })
	else
		for index, seed in (options.regressions or {}) :: { number } do
			table.insert(cases, { label = `regression {index}`, index = index, seed = seed })
		end
		runs = run.runs or options.runs or 200
		if isMutant then runs = math.min(runs, MUTANT_RUNS) end
		local nameHash = fnv1a32(name)
		for index = 1, runs do
			table.insert(cases, { index = index, seed = caseSeedOf(nameHash, base, index) })
		end
	end

	local vacuous, why = true, nil
	for count, case in cases do
		local gen = newGen(case.seed, size, nil, false)
		local ok, err = pcall(fn :: (Gen) -> ...any, gen)
		vacuous, why = tally(gen._s.vacuous, vacuous, why)
		if not ok then
			local result = fail(fn, case.seed, size, false, gen, err, shrinkLimits)
			result.cases = count
			local label = case.label or `run {case.index} of {runs}`
			result.report = report(
				name,
				result,
				`seed: base {base} · {label} · case seed {case.seed}`,
				`replay: {command} --filter "{filter}" --replay={case.seed}`
			)
			return result
		end
	end
	return (if run.replay == nil then vacuity(name, #cases, false, vacuous, why) else nil)
		or { ok = true, cases = #cases, exhaustive = false, attempts = 0 }
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

return prop
