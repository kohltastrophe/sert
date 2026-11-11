--!strict
-- Composable property generators (`sert.gen`). Every generator is a function `(g: GenContext) -> T` that draws from
-- `sert.prop`'s tape so shrinking, replay, and bounded-exhaustive enumeration work automatically.

local prop = require("../prop")
local util = require("../core/util")

local IS_ROBLOX = (game :: any) ~= nil
local Datatypes: any = if IS_ROBLOX then nil else require("../engine/datatypes")
local Vector2Lib: any = if IS_ROBLOX then Vector2 else Datatypes.Vector2
local Vector3Lib: any = if IS_ROBLOX then Vector3 else Datatypes.Vector3
local Color3Lib: any = if IS_ROBLOX then Color3 else Datatypes.Color3
local UDimLib: any = if IS_ROBLOX then UDim else Datatypes.UDim
local UDim2Lib: any = if IS_ROBLOX then UDim2 else Datatypes.UDim2
local CFrameLib: any = if IS_ROBLOX then CFrame else Datatypes.CFrame
local NumberRangeLib: any = if IS_ROBLOX then NumberRange else Datatypes.NumberRange
local RectLib: any = if IS_ROBLOX then Rect else Datatypes.Rect

local equal = util.equal
local mark = prop.markGenerator

type Gen = prop.GenContext
export type Generator<T> = prop.Generator<T>

local gen = {}

-- Guard against passing a generator factory (`gen.int`) instead of a generator (`gen.int(1, 10)`).
local function called(api: string, example: string, first: any)
	if prop.isGen(first) then error(`{api}(…) makes a generator: pass {example}, not {api}`, util.outside()) end
end

local function checkBounds(api: string, min: number?, max: number?): number
	local least = min or 0
	if max ~= nil and least > max then error(`{api}: min > max`, util.outside()) end
	return least
end

local function checkNonNegInt(api: string, label: string, n: number)
	if n ~= math.floor(n) or n < 0 then error(`{api}: expected an integer {label} >= 0, got {n}`, util.outside()) end
end

--- Marks a custom `(g: GenContext) -> T` function as a `Generator<T>`.
function gen.custom<T>(fn: Generator<T>): Generator<T>
	if type(fn) ~= "function" then error(`gen.custom: expected a function, got {util.typeof(fn)}`, util.outside()) end
	return mark(fn)
end

--- Generates an integer in `[lo, hi]`, shrinking toward `0`.
function gen.int(lo: number, hi: number): Generator<number>
	called("gen.int", "gen.int(1, 10)", lo)
	prop.checkRange("gen.int", lo, hi, true)
	return mark(function(g: Gen): number return prop.drawInt(g, lo, hi) end)
end

--- Options for mixing IEEE-754 special values into `gen.float`.
export type FloatOptions = {
	nan: boolean?,
	inf: boolean?,
	negZero: boolean?,
}

--- Generates a float in `[lo, hi)`, shrinking toward `0`. Pass `options` to mix in `-0.0`, `±inf`, or `NaN` on a fixed-width draw span.
function gen.float(lo: number, hi: number, options: FloatOptions?): Generator<number>
	called("gen.float", "gen.float(0, 1)", lo)
	prop.checkRange("gen.float", lo, hi, false)
	local specials: { number } = {}
	if options ~= nil then
		for key in next, options :: any do
			if key ~= "nan" and key ~= "inf" and key ~= "negZero" then
				error(`gen.float: unknown option {tostring(key)} (nan, inf, negZero)`, util.outside())
			end
		end
		if options.negZero then table.insert(specials, -0.0) end
		if options.inf then
			table.insert(specials, math.huge)
			table.insert(specials, -math.huge)
		end
		if options.nan then table.insert(specials, 0 / 0) end
	end
	if #specials == 0 then
		return mark(function(g: Gen): number return prop.drawFloat(g, lo, hi) end)
	end
	local width = prop.floatDrawWidth(lo, hi)
	return mark(function(g: Gen): number
		-- Tag 0 is always finite (`0.0` at all-zero draws); special tags pad `width` zero-range slots so downstream draws never shift.
		local tag = prop.drawTag(g, #specials, 0.1)
		if tag == 0 then return prop.drawFloat(g, lo, hi) end
		for _ = 1, width do
			prop.drawZero(g)
		end
		return specials[tag]
	end)
end

--- Generates a boolean, shrinking toward `false`.
function gen.bool(...: never): Generator<boolean>
	called("gen.bool", "gen.bool()", (...))
	return mark(function(g: Gen): boolean return g:bool() end)
end

--- Always returns `value` without consuming tape draws.
function gen.constant<T>(value: T): Generator<T>
	called("gen.constant", "gen.constant(value)", value)
	return mark(function(_: Gen): T return value end)
end

--- Picks an element from `list`, shrinking toward `list[1]`.
function gen.pick<T>(list: { T }): Generator<T>
	called("gen.pick", "gen.pick(list)", list)
	if #list == 0 then error("gen.pick: an empty list", util.outside()) end
	return mark(function(g: Gen): T return g:pick(list) end)
end

--- Picks a generator from `gens` and draws from it, shrinking toward `gens[1]`.
function gen.oneOf(gens: { Generator<any> }): Generator<any>
	called("gen.oneOf", "gen.oneOf(gens)", gens)
	if #gens == 0 then error("gen.oneOf: no generators", util.outside()) end
	return mark(function(g: Gen): any return g:pick(gens)(g) end)
end

--- Picks a `{ weight, gen }` pair by weight and draws from it, shrinking toward the first positive-weight pair.
function gen.frequency(pairs: { { any } }): Generator<any>
	called("gen.frequency", "gen.frequency(pairs)", pairs)
	local total = 0
	for _, pair in pairs do
		total += math.max(pair[1] :: number, 0)
	end
	if total <= 0 then error("gen.frequency: no weight", util.outside()) end
	local items = table.clone(pairs)
	return mark(function(g: Gen): any return (g:weighted(items) :: Generator<any>)(g) end)
end

--- Generates `source(g)` or `nil` weighted `absent` (`1`) to `present` (`1`), shrinking toward `nil`.
function gen.optional<T>(source: Generator<T>, absent: number?, present: number?): Generator<T?>
	called("gen.optional", "gen.optional(source)", source)
	return gen.frequency({ { absent or 1, gen.constant(nil) }, { present or 1, source } })
end

--- Generates an array of `min` (`0`) to `max` (`g.size`) elements from `element`.
function gen.list<T>(element: Generator<T>, min: number?, max: number?): Generator<{ T }>
	called("gen.list", "gen.list(element)", element)
	local least = checkBounds("gen.list", min, max)
	return mark(function(g: Gen): { T } return g:list(element, least, max) end)
end

--- Generates a table matching `shape`, calling any function fields as generators in sorted key order.
function gen.record(shape: { [string]: any }): Generator<{ [string]: any }>
	called("gen.record", "gen.record(shape)", shape)
	return mark(function(g: Gen): { [string]: any } return g:record(shape) end)
end

--- Generates a dictionary of `min` (`0`) to `max` (`g.size`) key-value pairs.
function gen.dict<K, V>(key: Generator<K>, value: Generator<V>, min: number?, max: number?): Generator<{ [K]: V }>
	called("gen.dict", "gen.dict(key, value)", key)
	checkBounds("gen.dict", min, max)
	return mark(function(g: Gen): { [K]: V } return g:dict(key, value, min, max) end)
end

--- Generates an array of values drawn from each generator in order.
function gen.tuple(first: { Generator<any> } | Generator<any>, ...: Generator<any>): Generator<{ any }>
	called("gen.tuple", "gen.tuple(gens)", first)
	local gens: { Generator<any> } = if type(first) == "table" then first else { first :: Generator<any>, ... }
	return mark(function(g: Gen): { any } return g:tuple(gens) end)
end

--- Default character set used by `gen.string` and `g:string`.
gen.CHARACTERS = prop.CHARACTERS

--- Generates a string of `min` (`0`) to `max` (`g.size`) characters from `charset` (default `gen.CHARACTERS`).
function gen.string(charset: (string | Generator<string>)?, min: number?, max: number?): Generator<string>
	called("gen.string", "gen.string()", charset)
	if charset == "" then error("gen.string: an empty charset", util.outside()) end
	checkBounds("gen.string", min, max)
	return mark(function(g: Gen): string return g:string(charset, min, max) end)
end

--- Transforms values drawn from `source` with `fn`.
function gen.map<A, B>(source: Generator<A>, fn: (A) -> B): Generator<B>
	called("gen.map", "gen.map(source, fn)", source)
	return mark(function(g: Gen): B return fn(source(g)) end)
end

--- Draws `x` from `source`, then draws from `fn(x)` on the same tape.
function gen.bind<A, B>(source: Generator<A>, fn: (A) -> Generator<B>): Generator<B>
	called("gen.bind", "gen.bind(source, fn)", source)
	return mark(function(g: Gen): B return fn(source(g))(g) end)
end

--- Generates a buffer of `min` (`0`) to `max` (`g.size`) bytes.
function gen.bytes(min: number?, max: number?): Generator<buffer>
	called("gen.bytes", "gen.bytes()", min)
	local least = checkBounds("gen.bytes", min, max)
	return mark(function(g: Gen): buffer return g:bytes(least, max) end)
end

--- Redraws from `source` until `predicate(value)` holds, raising after `maxTries` (default `100`) attempts.
function gen.filter<T>(source: Generator<T>, predicate: (T) -> boolean, maxTries: number?): Generator<T>
	called("gen.filter", "gen.filter(source, predicate)", source)
	local limit = maxTries or 100
	if limit < 1 then error("gen.filter: expected maxTries >= 1", util.outside()) end
	local callerLevel = util.outside()
	local file, line = debug.info(callerLevel, "sl")
	local made = if file ~= nil then `{file}:{line}` else "?"
	return mark(function(g: Gen): T
		local firstMark = prop.mark(g)
		for attempt = 1, limit do
			local attemptMark = prop.mark(g)
			local value = source(g)
			if predicate(value) then
				if attempt > 1 then
					local fullTape = prop.tape(g)
					prop.hint(g, firstMark, #fullTape, table.move(fullTape, attemptMark, #fullTape, 1, {}))
				end
				return value
			end
		end
		return prop.exhaust(g, `gen.filter ({made}): predicate not satisfied after {limit} attempts`, 0)
	end)
end

-- Sentinel key used to track NaN in `seen` sets.
local NAN = {}

local function addUnique(out: { any }, seen: { [any]: boolean }, deep: { any }, item: any): boolean
	if item == nil then return false end
	local kind = type(item)
	if kind == "table" or kind == "buffer" then
		for _, other in deep do
			if equal(item, other, true) then return false end
		end
		table.insert(deep, item)
	else
		local key = if item ~= item then NAN else item
		if seen[key] then return false end
		seen[key] = true
	end
	table.insert(out, item)
	return true
end

--- Generates an array of `min` (`0`) to `max` (`g.size`) distinct elements from `element`.
function gen.uniqueList<T>(element: Generator<T>, min: number?, max: number?): Generator<{ T }>
	called("gen.uniqueList", "gen.uniqueList(element)", element)
	local least = checkBounds("gen.uniqueList", min, max)
	return mark(function(g: Gen): { T }
		local out: { T }, seen: { [any]: boolean }, deep: { any } = {}, {}, {}
		for _, item in g:list(element, least, max) do
			addUnique(out, seen, deep, item)
		end
		if #out < least then
			local s = (g :: any)._s
			for _ = 1, math.max(least * 20, 50) do
				if s ~= nil and s.forced ~= nil and #s.out >= #s.forced then break end
				if addUnique(out, seen, deep, element(g)) and #out >= least then break end
			end
			if #out < least then prop.exhaust(g, `gen.uniqueList: could not draw {least} unique elements`, 2) end
		end
		return out
	end)
end

local function defaultComponentGen(label: string, first: Generator<number>?): Generator<number>
	called(label, `{label}()`, first)
	return first or gen.float(-1000, 1000)
end

--- Generates a `Vector2` from `xGen` and `yGen` (default `gen.float(-1000, 1000)`).
function gen.vector2(xGen: Generator<number>?, yGen: Generator<number>?): Generator<Vector2>
	local gx = defaultComponentGen("gen.vector2", xGen)
	local gy = yGen or gx
	return mark(function(g: Gen): Vector2 return Vector2Lib.new(gx(g), gy(g)) end)
end

--- Generates a `Vector3` from `xGen`, `yGen`, and `zGen` (default `gen.float(-1000, 1000)`).
function gen.vector3(xGen: Generator<number>?, yGen: Generator<number>?, zGen: Generator<number>?): Generator<Vector3>
	local gx = defaultComponentGen("gen.vector3", xGen)
	local gy, gz = yGen or gx, zGen or gx
	return mark(function(g: Gen): Vector3 return Vector3Lib.new(gx(g), gy(g), gz(g)) end)
end

--- Generates a `Color3` via `Color3.fromRGB(0..255, 0..255, 0..255)`.
function gen.color3(...: never): Generator<Color3>
	called("gen.color3", "gen.color3()", (...))
	return mark(function(g: Gen): Color3 return Color3Lib.fromRGB(g:int(0, 255), g:int(0, 255), g:int(0, 255)) end)
end

--- Generates a `UDim` from `scaleGen` (default `-2..2`) and `offsetGen` (default `-500..500`).
function gen.udim(scaleGen: Generator<number>?, offsetGen: Generator<number>?): Generator<UDim>
	called("gen.udim", "gen.udim()", scaleGen)
	local gs, go = scaleGen or gen.float(-2, 2), offsetGen or gen.int(-500, 500)
	return mark(function(g: Gen): UDim return UDimLib.new(gs(g), go(g)) end)
end

--- Generates a `UDim2` from X and Y scale and offset generators.
function gen.udim2(
	xsGen: Generator<number>?,
	xoGen: Generator<number>?,
	ysGen: Generator<number>?,
	yoGen: Generator<number>?
): Generator<UDim2>
	called("gen.udim2", "gen.udim2()", xsGen)
	local gxs, gxo = xsGen or gen.float(-2, 2), xoGen or gen.int(-500, 500)
	local gys, gyo = ysGen or gxs, yoGen or gxo
	return mark(function(g: Gen): UDim2 return UDim2Lib.new(gxs(g), gxo(g), gys(g), gyo(g)) end)
end

--- Generates a `CFrame` with position from `posGen` (default `gen.vector3()`) and random Euler angles.
function gen.cframe(posGen: Generator<Vector3>?): Generator<CFrame>
	called("gen.cframe", "gen.cframe()", posGen)
	local gp: Generator<Vector3> = if posGen ~= nil then posGen else gen.vector3()
	local ga = gen.float(-math.pi, math.pi)
	return mark(function(g: Gen): CFrame
		local p: any = gp(g)
		return CFrameLib.new(p.X, p.Y, p.Z) * CFrameLib.fromEulerAnglesXYZ(ga(g), ga(g), ga(g))
	end)
end

--- Generates a `NumberRange` with `Min <= Max` from `loGen` and `hiGen` (default `gen.float(-1000, 1000)`).
function gen.numberRange(loGen: Generator<number>?, hiGen: Generator<number>?): Generator<NumberRange>
	called("gen.numberRange", "gen.numberRange()", loGen)
	local ga = loGen or gen.float(-1000, 1000)
	local gb = hiGen or ga
	return mark(function(g: Gen): NumberRange
		local a, b = ga(g), gb(g)
		return NumberRangeLib.new(math.min(a, b), math.max(a, b))
	end)
end

--- Generates a `Rect` with `Min.X <= Max.X` and `Min.Y <= Max.Y`.
function gen.rect(
	minXGen: Generator<number>?,
	minYGen: Generator<number>?,
	maxXGen: Generator<number>?,
	maxYGen: Generator<number>?
): Generator<Rect>
	called("gen.rect", "gen.rect()", minXGen)
	local gx1 = minXGen or gen.float(-1000, 1000)
	local gy1 = minYGen or gx1
	local gx2, gy2 = maxXGen or gx1, maxYGen or gy1
	return mark(function(g: Gen): Rect
		local x1, y1, x2, y2 = gx1(g), gy1(g), gx2(g), gy2(g)
		return RectLib.new(math.min(x1, x2), math.min(y1, y2), math.max(x1, x2), math.max(y1, y2))
	end)
end

-- UTF-8 scalar classes weighted toward printable ASCII; 3-byte range skips U+D800..U+DFFF surrogates.
local UTF8_CLASSES: { { any } } = {
	{ 6, { 0x20, 0x5F } }, -- offset 0 maps to "a"
	{ 2, { 0x80, 0x780 } },
	{ 1, { 0x800, 0xF800 - 0x800 } },
	{ 1, { 0x10000, 0x100000 } },
}

--- Generates a valid UTF-8 string of `min` (`0`) to `max` (`g.size`) codepoints, shrinking toward `"a"`.
function gen.utf8(min: number?, max: number?): Generator<string>
	called("gen.utf8", "gen.utf8()", min)
	local least = checkBounds("gen.utf8", min, max)
	local function codepoint(g: Gen): string
		local class = g:weighted(UTF8_CLASSES) :: { number }
		local first = class[1]
		local count = if g.exhaustive then math.min(class[2], math.max(g.size, 1)) else class[2]
		local offset = g:int(0, count - 1)
		local point = if first == 0x20
			then 0x20 + (offset + 0x41) % 0x5F
			elseif first == 0x800 and 0x800 + offset >= 0xD800 then 0x1000 + offset
			else first + offset
		return utf8.char(point)
	end
	return mark(function(g: Gen): string return table.concat(g:list(codepoint, least, max)) end)
end

--- Generates a `{ [value] = true }` set of `min` (`0`) to `max` (`g.size`) distinct elements (`NaN` is dropped).
function gen.set<T>(element: Generator<T>, min: number?, max: number?): Generator<{ [T]: true }>
	called("gen.set", "gen.set(element)", element)
	local least = checkBounds("gen.set", min, max)
	local nonNan: Generator<T> = mark(function(g: Gen): T
		local v = element(g)
		return if v == v then v else nil :: any
	end)
	local list = gen.uniqueList(nonNan, least, max)
	return mark(function(g: Gen): { [T]: true }
		local out = {}
		for _, item in list(g) do
			if item == item then out[item] = true end
		end
		return out :: any
	end)
end

--- Generates a shuffled copy of `list`, shrinking toward the original order.
function gen.shuffle<T>(list: { T }): Generator<{ T }>
	called("gen.shuffle", "gen.shuffle(list)", list)
	local items = table.clone(list)
	return mark(function(g: Gen): { T }
		local out = table.clone(items)
		for index = 1, #out - 1 do
			local other = index + g:int(0, #out - index)
			out[index], out[other] = out[other], out[index]
		end
		return out
	end)
end

--- Generates an ordered subsequence of `min` (`0`) to `max` (`#list`) elements from `list`.
function gen.subset<T>(list: { T }, min: number?, max: number?): Generator<{ T }>
	called("gen.subset", "gen.subset(list)", list)
	local items = table.clone(list)
	local count = #items
	local least, most = min or 0, max or count
	if least < 0 or most > count or least > most then
		error(`gen.subset: expected 0 <= min <= max <= {count}, got {least}, {most}`, util.outside())
	end
	return mark(function(g: Gen): { T }
		local take = least + g:int(0, most - least)
		local indices: { number } = {}
		for index = 1, count do
			indices[index] = index
		end
		-- Partial Fisher-Yates where offset 0 selects the first `take` indices.
		for index = 1, take do
			local other = index + g:int(0, count - index)
			indices[index], indices[other] = indices[other], indices[index]
		end
		local chosen: { number } = table.move(indices, 1, take, 1, {} :: { number })
		table.sort(chosen)
		local out = table.create(take)
		for index, position in chosen do
			out[index] = items[position]
		end
		return out
	end)
end

--- Defers building `fn()` until the first draw so recursive generators can reference themselves.
function gen.lazy<T>(fn: () -> Generator<T>): Generator<T>
	called("gen.lazy", "gen.lazy(fn)", fn)
	local built: Generator<T>? = nil
	return mark(function(g: Gen): T
		if built == nil then built = fn() end
		return (built :: Generator<T>)(g)
	end)
end

--- Builds a recursive generator up to `maxDepth` levels deep from leaf generator `base` and layer wrapper `extend`.
function gen.recursive<T>(base: Generator<T>, extend: (Generator<T>) -> Generator<T>, maxDepth: number): Generator<T>
	called("gen.recursive", "gen.recursive(base, extend, maxDepth)", base)
	checkNonNegInt("gen.recursive", "maxDepth", maxDepth)
	local level = base
	for _ = 1, maxDepth do
		local deeper = extend(level)
		local prev = base
		level = mark(function(g: Gen): T return if g:bool() then deeper(g) else prev(g) end)
	end
	return level
end

--- Picks an `EnumItem` from `enumType`, shrinking toward the lowest `Value`.
function gen.enum(enumType: any): Generator<any>
	called("gen.enum", "gen.enum(Enum.Material)", enumType)
	local items = table.clone(enumType:GetEnumItems() :: { any })
	if #items == 0 then error(`gen.enum: {tostring(enumType)} has no items`, util.outside()) end
	table.sort(items, function(a: any, b: any): boolean return a.Value < b.Value end)
	return gen.pick(items)
end

local function anyOf(depth: number): Generator<any>
	local kinds: { { any } } = {
		{ 2, gen.bool() },
		{ 3, gen.int(-1000, 1000) },
		{ 2, gen.float(-1000, 1000) },
		{ 3, gen.string(nil, 0, 8) },
		{ 1, gen.bytes(0, 8) },
	}
	if depth > 0 then
		local child = anyOf(depth - 1)
		table.insert(kinds, { 2, gen.list(child, 0, 4) :: any })
		table.insert(kinds, { 2, gen.dict(gen.string("abcdefgh", 1, 4), child, 0, 4) :: any })
	end
	return gen.frequency(kinds)
end

--- Generates an arbitrary non-`nil`, non-`NaN` Luau value up to nesting `depth` (default `2`).
function gen.any(depth: number?): Generator<any>
	called("gen.any", "gen.any()", depth)
	local levels = depth or 2
	checkNonNegInt("gen.any", "depth", levels)
	return anyOf(levels)
end

--- Generates an integer in `[lo, hi]` (default `-2147483648..2147483647`), branching on tag first so exhaustive mode stays tractable and shrinking toward `0`.
function gen.boundaryInt(lo: number?, hi: number?): Generator<number>
	called("gen.boundaryInt", "gen.boundaryInt()", lo)
	local minLo = if lo ~= nil then lo else -2147483648
	local maxHi = if hi ~= nil then hi else 2147483647
	prop.checkRange("gen.boundaryInt", minLo, maxHi, true)
	local rawCandidates: { number } = {
		0,
		1,
		-1,
		2,
		-2,
		minLo,
		maxHi,
		minLo + 1,
		maxHi - 1,
		127,
		-128,
		255,
		32767,
		-32768,
		65535,
		2147483647,
		-2147483648,
		9007199254740991,
		-9007199254740991,
	}
	local candidates: { number } = {}
	local seen: { [number]: boolean } = {}
	for _, c in rawCandidates do
		if c >= minLo and c <= maxHi and c == math.floor(c) and not seen[c] then
			seen[c] = true
			table.insert(candidates, c)
		end
	end
	table.sort(candidates, function(a: number, b: number): boolean
		local aa, ab = math.abs(a), math.abs(b)
		if aa ~= ab then return aa < ab end
		return a > b
	end)
	local width = prop.intDrawWidth(minLo, maxHi)
	return mark(function(g: Gen): number
		local firstMark = prop.mark(g)
		-- Branch on tag before drawing `[-2^31, 2^31 - 1]` so bounded-exhaustive enumeration never explodes.
		local tag = prop.drawTag(g, #candidates, 0.7)
		if tag == 0 then
			if g.exhaustive then
				if minLo < 0 and maxHi > 0 then
					local span = math.max(g.size, 1)
					return prop.drawInt(g, math.max(minLo, -span), math.min(maxHi, span))
				elseif minLo >= 0 then
					return prop.drawInt(g, minLo, math.min(maxHi, minLo + g.size))
				else
					return prop.drawInt(g, math.max(minLo, maxHi - g.size), maxHi)
				end
			end
			return prop.drawInt(g, minLo, maxHi)
		end
		for _ = 1, width do
			prop.drawZero(g)
		end
		local picked = candidates[tag]
		if not g.exhaustive then
			local hintDraws: { number } = if minLo >= 0
				then { 0, picked - minLo }
				elseif maxHi <= 0 then { 0, maxHi - picked }
				elseif picked >= 0 then { 0, 0, picked }
				else { 0, 1, -picked - 1 }
			prop.hint(g, firstMark, firstMark + width, hintDraws)
		end
		return picked
	end)
end

--- Generates IEEE-754 boundary floats (`0.0`, finite endpoints, `-0.0`, `±math.huge`, `NaN`) and uniform floats on a fixed-width span where tag `0` is finite `0.0`.
function gen.boundaryFloat(lo: number?, hi: number?): Generator<number>
	called("gen.boundaryFloat", "gen.boundaryFloat()", lo)
	local minLo = if lo ~= nil then lo else -1e6
	local maxHi = if hi ~= nil then hi else 1e6
	prop.checkRange("gen.boundaryFloat", minLo, maxHi, false)
	local finiteCandidates: { number } = {
		0.0,
		1.0,
		-1.0,
		1e-9,
		-1e-9,
		0.1 + 0.2,
		math.pi,
		minLo,
		maxHi,
		minLo + 1e-9,
		maxHi - 1e-9,
		1e-308,
		1e308,
	}
	local specials: { number } = {}
	local seenFinite: { [number]: boolean } = {}
	for _, candidate in finiteCandidates do
		local inRange = (lo == nil and hi == nil) or (candidate >= minLo and candidate <= maxHi)
		if inRange and candidate == candidate and math.abs(candidate) < math.huge then
			local norm = if candidate == 0 then 0 else candidate
			if not seenFinite[norm] then
				seenFinite[norm] = true
				table.insert(specials, norm)
			end
		end
	end
	-- Keep `-0.0`, `±math.huge`, and `NaN` at the highest tags so shrinking prefers finite values and `0.0` (`tag = 0`).
	table.insert(specials, -0.0)
	table.insert(specials, math.huge)
	table.insert(specials, -math.huge)
	table.insert(specials, 0 / 0)

	local width = prop.floatDrawWidth(minLo, maxHi)
	return mark(function(g: Gen): number
		local tag = prop.drawTag(g, #specials, 0.7)
		if tag == 0 then return prop.drawFloat(g, minLo, maxHi) end
		for _ = 1, width do
			prop.drawZero(g)
		end
		return specials[tag]
	end)
end

local MALFORMED_STRINGS: { string } = {
	"",
	"\0",
	"a\0b\0c",
	"\255\254\128\192",
	"\192\128\244\144\128\128",
	"\r\n\t\b\27[31m",
	"   \t\n  ",
	"%s%s%n%x",
	"^$()%.[]*+-?",
	"nan",
	"-inf",
	"1e999",
	"<font size='99999'><b>unclosed",
	"</font><stroke thickness='99'>",
	"\226\128\139\240\159\145\168\226\128\141\240\159\146\187",
	string.rep("A", 1024),
}

--- Generates Luau/Roblox adversarial strings (NUL bytes, invalid UTF-8, control chars, format/pattern magic chars, RichText breakouts, ZWJ sequences, long strings), shrinking toward `""`.
function gen.malformedString(...: never): Generator<string>
	called("gen.malformedString", "gen.malformedString()", (...))
	return mark(function(g: Gen): string return g:pick(MALFORMED_STRINGS) end)
end

--- Generates tables with sparse integer indices, mixed array + string keys, negative/zero/float keys, and `{}`, shrinking toward `{}`.
function gen.sparseTable<T>(valGen: Generator<T>?): Generator<{ [any]: any }>
	called("gen.sparseTable", "gen.sparseTable()", valGen)
	local vg: Generator<any> = if valGen ~= nil then valGen else gen.int(-100, 100)
	return mark(function(g: Gen): { [any]: any }
		local kind = g:int(0, 4)
		if kind == 0 then
			return {}
		elseif kind == 1 then
			local v1, v2, v3 = vg(g), vg(g), vg(g)
			return { [1] = v1, [100] = v2, [10000] = v3 }
		elseif kind == 2 then
			local v1, v2 = vg(g), vg(g)
			return { [1] = v1, foo = v2 }
		elseif kind == 3 then
			local v1, v2, v3 = vg(g), vg(g), vg(g)
			return { [0] = v1, [-1] = v2, [1.5] = v3 }
		else
			local v1, v2, v3 = vg(g), vg(g), vg(g)
			return { [1] = v1, [100] = v2, [0] = v3, [-1] = v1, [1.5] = v2, foo = v3 }
		end
	end)
end

local function buildRemotePayload(depth: number): Generator<any>
	local bFloat = gen.boundaryFloat()
	local bInt = gen.boundaryInt()
	local mStr = gen.malformedString()
	local kinds: { { any } } = {
		{ 2, gen.constant(nil) },
		{ 2, gen.bool() },
		{ 3, bInt },
		{ 3, bFloat },
		{ 3, mStr },
		{ 2, gen.vector3(bFloat) },
		{ 2, gen.cframe(gen.vector3(gen.boundaryFloat(-1e6, 1e6))) },
		{ 1, gen.color3() },
		{ 1, gen.udim2(bFloat, bInt, bFloat, bInt) },
	}
	if depth > 0 then
		local child = buildRemotePayload(depth - 1)
		table.insert(kinds, { 2, gen.sparseTable(child) :: any })
		table.insert(kinds, {
			1,
			mark(function(g: Gen): any
				local node: any = { value = child(g) }
				local nest = g:int(1, 5)
				for _ = 1, nest do
					node = { nested = node }
				end
				return node
			end) :: any,
		})
		table.insert(kinds, {
			1,
			mark(function(g: Gen): any
				local cyclic: { [any]: any } = { id = g:int(0, 10) }
				cyclic.self = cyclic
				return cyclic
			end) :: any,
		})
		table.insert(kinds, {
			1,
			mark(function(g: Gen): any
				local fill = g:int(0, 10)
				return table.create(64, fill)
			end) :: any,
		})
		table.insert(kinds, {
			2,
			gen.record({
				id = mStr,
				amount = bFloat,
				count = bInt,
				items = gen.constant("wrong_type"),
			}) :: any,
		})
	end
	return gen.frequency(kinds)
end

--- Generates untrusted client→server Roblox remote payloads up to `depth` (default `2`), shrinking toward `nil`.
function gen.remotePayload(depth: number?): Generator<any>
	called("gen.remotePayload", "gen.remotePayload()", depth)
	local levels = depth or 2
	checkNonNegInt("gen.remotePayload", "depth", levels)
	return buildRemotePayload(levels)
end

--- Generates arbitrary adversarial Luau values (all `remotePayload` values plus functions, threads, userdata proxies, and frozen tables).
function gen.adversarial(depth: number?): Generator<any>
	called("gen.adversarial", "gen.adversarial()", depth)
	local levels = depth or 2
	checkNonNegInt("gen.adversarial", "depth", levels)
	local base = buildRemotePayload(levels)
	return gen.frequency({
		{ 6, base },
		{
			1,
			mark(function(_: Gen): any
				return function() error("adversarial callback", 0) end
			end),
		},
		{
			1,
			mark(function(_: Gen): any
				return coroutine.create(function() end)
			end),
		},
		{
			1,
			mark(function(_: Gen): any return newproxy(false) end),
		},
		{
			1,
			mark(function(g: Gen): any return table.freeze({ id = g:int(0, 10), frozen = true }) end),
		},
	})
end

--- Draws a single value from `generator` outside a property test using `seed` (default `0x5EED`) and `size` (default `40`).
function gen.sample<T>(generator: Generator<T>, seed: number?, size: number?): T
	return generator(prop.gen(if seed ~= nil then seed else prop.DEFAULT_BASE, size))
end

return gen
