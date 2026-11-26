--!strict
-- Universal property contract suites (`sert.laws`): `codec`, `order`, `algebra`, `differential`, `metamorphic`, and `complexity`.

local assertions = require("../core/assert")
local format = require("../core/format")
local gen = require("./gen")
local prop = require("../prop")
local propInternal = require("./internal")
local registry = require("../core/registry")
local util = require("../core/util")

export type Generator<T> = gen.Generator<T>
export type Equals<T> = (a: T, b: T) -> boolean
export type PropOptions = prop.PropOptions
export type TestOptions = registry.TestOptions

export type CodecSpec<T = any, E = any> = {
	name: string?,
	gen: Generator<T>,
	encode: (value: T) -> E,
	decode: (encoded: E) -> T,
	eq: Equals<T>?,
	decodedEq: Equals<T>?,
	encodedEq: Equals<E>?,
	deterministic: boolean?,
}

export type OrderSpec<T = any> = {
	name: string?,
	gen: Generator<T>,
	lt: (a: T, b: T) -> boolean,
	eq: Equals<T>?,
}

export type AlgebraSpec<T = any> = {
	name: string?,
	gen: Generator<T>,
	op: (a: T, b: T) -> T,
	identity: any,
	hasIdentity: boolean?,
	associative: boolean?,
	commutative: boolean?,
	idempotent: boolean?,
	inverse: ((a: T) -> T)?,
	eq: Equals<T>?,
}

export type DifferentialSpec<A = any, B = any> = {
	name: string?,
	gen: Generator<A>,
	sut: (input: A) -> B,
	oracle: (input: A) -> B,
	eq: Equals<B>?,
}

export type MetamorphicRelation<A = any, B = any> = {
	transform: (input: A, g: prop.GenContext) -> A,
	relate: (origInput: A, origOut: B, txInput: A, txOut: B) -> (),
}

export type MetamorphicSpec<A = any, B = any> = {
	name: string?,
	gen: Generator<A>,
	sut: (input: A) -> B,
	relations: { [string]: MetamorphicRelation<A, B> },
}

export type ComplexityBound = "O(1)" | "O(log n)" | "O(n)" | "O(n log n)"

export type ComplexitySpec<Input = any> = {
	name: string?,
	bound: ComplexityBound,
	sizes: { number }?,
	gen: (n: number) -> Input,
	sut: ((input: Input) -> any)?,
	measure: ((input: Input) -> number)?,
}

export type CodecLawFn =
	(<T, E>(name: string, spec: CodecSpec<T, E>, options: PropOptions?) -> ())
	& (<T, E>(spec: CodecSpec<T, E>, options: PropOptions?) -> ())

export type OrderLawFn =
	(<T>(name: string, spec: OrderSpec<T>, options: PropOptions?) -> ())
	& (<T>(spec: OrderSpec<T>, options: PropOptions?) -> ())

export type AlgebraLawFn =
	(<T>(name: string, spec: AlgebraSpec<T>, options: PropOptions?) -> ())
	& (<T>(spec: AlgebraSpec<T>, options: PropOptions?) -> ())

export type DifferentialLawFn =
	(<A, B>(name: string, spec: DifferentialSpec<A, B>, options: PropOptions?) -> ())
	& (<A, B>(spec: DifferentialSpec<A, B>, options: PropOptions?) -> ())

export type MetamorphicLawFn = (
	nameOrSpec: string | MetamorphicSpec<any, any>,
	specOrOpts: (MetamorphicSpec<any, any> | PropOptions)?,
	options: PropOptions?
) -> ()

export type ComplexityLawFn = (
	nameOrSpec: string | ComplexitySpec<any>,
	specOrOpts: (ComplexitySpec<any> | TestOptions)?,
	options: TestOptions?
) -> ()

export type Laws = {
	codec: CodecLawFn,
	order: OrderLawFn,
	algebra: AlgebraLawFn,
	differential: DifferentialLawFn,
	metamorphic: MetamorphicLawFn,
	complexity: ComplexityLawFn,
}

local SPEC_FIELDS: { [string]: { string } } = {
	codec = { "decode", "decodedEq", "deterministic", "encode", "encodedEq", "eq", "gen", "name" },
	order = { "eq", "gen", "lt", "name" },
	algebra = {
		"associative",
		"commutative",
		"eq",
		"gen",
		"hasIdentity",
		"idempotent",
		"identity",
		"inverse",
		"name",
		"op",
	},
	differential = { "eq", "gen", "name", "oracle", "sut" },
	metamorphic = { "gen", "name", "relations", "sut" },
	complexity = { "bound", "gen", "measure", "name", "sizes", "sut" },
}
local RELATION_FIELDS = { "relate", "transform" }
local VALID_BOUNDS: { [string]: boolean } = {
	["O(1)"] = true,
	["O(log n)"] = true,
	["O(n)"] = true,
	["O(n log n)"] = true,
}
local DEFAULT_COMPLEXITY_SIZES = { 64, 256, 1024, 4096 }

local repr = format.repr

local function resolve(
	kind: string,
	nameOrSpec: any,
	maybeSpec: any,
	maybeOptions: any
): (string, { [string]: any }, any)
	local at = util.outside()
	local isTable = type(nameOrSpec) == "table"
	if not isTable and type(nameOrSpec) ~= "string" then
		error(`sert.laws.{kind}: expected a name string or a spec table, got {util.typeof(nameOrSpec)}`, at)
	end
	if not isTable and type(maybeSpec) == "table" and maybeSpec.gen == nil and maybeOptions ~= nil then
		error(`sert.laws.{kind}: pass the spec before the options: sert.laws.{kind}(name, spec, opts?)`, at)
	end
	local spec = if isTable then nameOrSpec else maybeSpec
	local options: any = if isTable then maybeSpec else maybeOptions
	local name: string = if isTable then (spec.name or `{kind} laws`) else nameOrSpec
	local where = `sert.laws.{kind}("{name}")`
	if type(spec) ~= "table" then error(`{where}: expected a spec table, got {util.typeof(spec)}`, at) end
	registry.checkKeys(where, "spec field", spec, SPEC_FIELDS[kind])
	registry.checkKeys(
		where,
		"option",
		options,
		if kind == "complexity" then registry.TEST_OPTIONS else propInternal.PROP_OPTIONS
	)
	if type(spec.gen) ~= "function" then
		error(`{where}: expected spec.gen to be a generator function, got {util.typeof(spec.gen)}`, at)
	end
	return name, spec, options
end

local function checkEq(eqFn: ((any, any) -> boolean)?, got: any, want: any, label: string, defaultWhy: string)
	if eqFn ~= nil then
		assertions.ok(eqFn(got, want), `{label}: expected {repr(want)}, got {repr(got)}`)
	else
		assertions.eq(got, want, defaultWhy)
	end
end

local laws: { [string]: any } = {}

--- Checks codec round-trip (`decode(encode(x)) == x`), plus determinism (`encode(x) == encode(x)`) and idempotence when `spec.deterministic ~= false`.
function laws.codec(nameOrSpec: any, maybeSpec: any?, maybeOptions: PropOptions?)
	local name, spec, options = resolve("codec", nameOrSpec, maybeSpec, maybeOptions)
	local where = `sert.laws.codec("{name}")`
	if type(spec.encode) ~= "function" or type(spec.decode) ~= "function" then
		error(`{where}: expected spec.encode and spec.decode to be functions`, util.outside())
	end
	local genFn: Generator<any> = spec.gen
	local encode: (any) -> any = spec.encode :: any
	local decode: (any) -> any = spec.decode :: any
	local valueEq: ((any, any) -> boolean)? = spec.decodedEq or spec.eq
	local encodedEq: ((any, any) -> boolean)? = spec.encodedEq
	local deterministic = spec.deterministic ~= false

	prop(name, function(g: prop.GenContext)
		local value = genFn(g)
		g:note(function() return `value: {repr(value)}` end)
		local encoded1 = encode(value)
		local encoded2 = encode(value)
		if deterministic then
			checkEq(
				encodedEq,
				encoded1,
				encoded2,
				"codec determinism",
				"codec determinism: encode(x) must equal encode(x)"
			)
		end
		local decoded1 = decode(encoded1)
		checkEq(valueEq, decoded1, value, "codec round-trip", "codec round-trip: decode(encode(x)) must equal x")
		if deterministic then
			checkEq(
				encodedEq,
				encode(decoded1),
				encoded1,
				"codec idempotence",
				"codec idempotence: encode(decode(encode(x))) must equal encode(x)"
			)
		else
			local decoded2 = decode(encoded2)
			checkEq(
				valueEq,
				decoded2,
				value,
				"codec second round-trip",
				"codec round-trip: decode(encode(x)) must equal x across non-deterministic encodings"
			)
			checkEq(
				valueEq,
				decode(encode(decoded1)),
				decoded1,
				"codec decoded stability",
				"codec round-trip: decode(encode(decode(encode(x)))) must equal decode(encode(x))"
			)
		end
	end, options)
end

--- Checks strict weak ordering laws for `lt(a, b)` (irreflexivity, asymmetry, transitivity, and equivalence transitivity).
function laws.order(nameOrSpec: any, maybeSpec: any?, maybeOptions: PropOptions?)
	local name, spec, options = resolve("order", nameOrSpec, maybeSpec, maybeOptions)
	local where = `sert.laws.order("{name}")`
	if type(spec.lt) ~= "function" then
		error(`{where}: expected spec.lt to be a function, got {util.typeof(spec.lt)}`, util.outside())
	end
	local genFn: Generator<any> = spec.gen
	local lt: (any, any) -> boolean = spec.lt :: any
	local hasEq = spec.eq ~= nil
	local safeEq: (any, any) -> boolean = if spec.eq ~= nil
		then spec.eq :: any
		else function(_a: any, _b: any): boolean return false end

	prop(name, function(g: prop.GenContext)
		local a, b, c = genFn(g), genFn(g), genFn(g)
		g:note(function() return `a={repr(a)}, b={repr(b)}, c={repr(c)}` end)
		for _, x in { a, b, c } do
			assertions.ok(not lt(x, x), `order irreflexivity failed for {repr(x)}`)
			if hasEq then assertions.ok(safeEq(x, x), `order eq reflexivity failed for {repr(x)}`) end
		end
		local ab, ba, bc, cb, ac, ca = lt(a, b), lt(b, a), lt(b, c), lt(c, b), lt(a, c), lt(c, a)
		for _, pair in { { ab, ba, a, b } :: { any }, { bc, cb, b, c }, { ac, ca, a, c } } do
			if pair[1] then
				assertions.ok(not pair[2], `order asymmetry failed for {repr(pair[3])} and {repr(pair[4])}`)
			end
			if hasEq then
				local incomp = not pair[1] and not pair[2]
				assertions.ok(
					safeEq(pair[3], pair[4]) == incomp and safeEq(pair[4], pair[3]) == incomp,
					`order eq consistency failed for {repr(pair[3])} and {repr(pair[4])}`
				)
			end
		end
		if ab and bc then assertions.ok(ac, `order transitivity failed for {repr(a)} < {repr(b)} < {repr(c)}`) end
		if cb and ba then assertions.ok(ca, `order transitivity failed for {repr(c)} < {repr(b)} < {repr(a)}`) end
		if ac and cb then assertions.ok(ab, `order transitivity failed for {repr(a)} < {repr(c)} < {repr(b)}`) end
		if bc and ca then assertions.ok(ba, `order transitivity failed for {repr(b)} < {repr(c)} < {repr(a)}`) end
		if ba and ac then assertions.ok(bc, `order transitivity failed for {repr(b)} < {repr(a)} < {repr(c)}`) end
		if ca and ab then assertions.ok(cb, `order transitivity failed for {repr(c)} < {repr(a)} < {repr(b)}`) end
		local eqAB, eqBC, eqAC = not ab and not ba, not bc and not cb, not ac and not ca
		if (eqAB and eqBC and not eqAC) or (eqAB and eqAC and not eqBC) or (eqBC and eqAC and not eqAB) then
			assertions.fail(`order equivalence transitivity failed for {repr(a)}, {repr(b)}, {repr(c)}`)
		end
	end, options)
end

--- Checks algebraic laws (`associative`, `identity`, `commutative`, `idempotent`, `inverse`) directly via `sert.prop` without opening nested `describe` scopes.
function laws.algebra(nameOrSpec: any, maybeSpec: any?, maybeOptions: PropOptions?)
	local name, spec, options = resolve("algebra", nameOrSpec, maybeSpec, maybeOptions)
	local where = `sert.laws.algebra("{name}")`
	if type(spec.op) ~= "function" then
		error(`{where}: expected spec.op to be a function, got {util.typeof(spec.op)}`, util.outside())
	end
	local genFn: Generator<any> = spec.gen
	local op: (any, any) -> any = spec.op :: any
	local eqFn: ((any, any) -> boolean)? = spec.eq
	local hasIdentity = if spec.hasIdentity ~= nil then spec.hasIdentity == true else spec.identity ~= nil
	local prefix = `{name} [algebra laws]`

	if spec.associative ~= false then
		prop(`{prefix} > associative`, function(g: prop.GenContext)
			local a, b, c = genFn(g), genFn(g), genFn(g)
			g:note(function() return `a={repr(a)}, b={repr(b)}, c={repr(c)}` end)
			checkEq(
				eqFn,
				op(op(a, b), c),
				op(a, op(b, c)),
				"algebra associativity",
				"algebra associativity: op(op(a, b), c) must equal op(a, op(b, c))"
			)
		end, options)
	end

	if hasIdentity then
		local id = spec.identity
		prop(`{prefix} > identity`, function(g: prop.GenContext)
			local a = genFn(g)
			g:note(function() return `a={repr(a)}, identity={repr(id)}` end)
			checkEq(
				eqFn,
				op(a, id),
				a,
				"algebra right identity",
				"algebra right identity: op(a, identity) must equal a"
			)
			checkEq(eqFn, op(id, a), a, "algebra left identity", "algebra left identity: op(identity, a) must equal a")
		end, options)
	end

	if spec.commutative == true then
		prop(`{prefix} > commutative`, function(g: prop.GenContext)
			local a, b = genFn(g), genFn(g)
			g:note(function() return `a={repr(a)}, b={repr(b)}` end)
			checkEq(
				eqFn,
				op(a, b),
				op(b, a),
				"algebra commutativity",
				"algebra commutativity: op(a, b) must equal op(b, a)"
			)
		end, options)
	end

	if spec.idempotent == true then
		prop(`{prefix} > idempotent`, function(g: prop.GenContext)
			local a = genFn(g)
			g:note(function() return `a={repr(a)}` end)
			checkEq(eqFn, op(a, a), a, "algebra idempotence", "algebra idempotence: op(a, a) must equal a")
		end, options)
	end

	if spec.inverse ~= nil and hasIdentity then
		if type(spec.inverse) ~= "function" then
			error(`{where}: expected spec.inverse to be a function, got {util.typeof(spec.inverse)}`, util.outside())
		end
		local invFn: (any) -> any = spec.inverse
		local id = spec.identity
		prop(`{prefix} > inverse`, function(g: prop.GenContext)
			local a = genFn(g)
			g:note(function() return `a={repr(a)}, identity={repr(id)}` end)
			local inv = invFn(a)
			checkEq(
				eqFn,
				op(a, inv),
				id,
				"algebra right inverse",
				"algebra right inverse: op(a, inverse(a)) must equal identity"
			)
			checkEq(
				eqFn,
				op(inv, a),
				id,
				"algebra left inverse",
				"algebra left inverse: op(inverse(a), a) must equal identity"
			)
		end, options)
	end
end

--- Verifies that `spec.sut(x)` matches `spec.oracle(x)` across inputs drawn from `spec.gen`.
function laws.differential(nameOrSpec: any, maybeSpec: any?, maybeOptions: PropOptions?)
	local name, spec, options = resolve("differential", nameOrSpec, maybeSpec, maybeOptions)
	local where = `sert.laws.differential("{name}")`
	if type(spec.sut) ~= "function" or type(spec.oracle) ~= "function" then
		error(`{where}: expected spec.sut and spec.oracle to be functions`, util.outside())
	end
	local genFn: Generator<any> = spec.gen
	local sutFn: (any) -> any = spec.sut :: any
	local oracleFn: (any) -> any = spec.oracle :: any
	local eqFn: ((any, any) -> boolean)? = spec.eq

	prop(`{name} [differential laws]`, function(g: prop.GenContext)
		local x = genFn(g)
		g:note(function() return `input: {repr(x)}` end)
		local got = sutFn(x)
		local want = oracleFn(x)
		checkEq(eqFn, got, want, "differential law", "differential law: sut(x) must equal oracle(x)")
	end, options)
end

--- Checks each metamorphic relation in `spec.relations` inside a `describe` block with one `sert.prop` per relation (sorted by key).
function laws.metamorphic(nameOrSpec: any, maybeSpec: any?, maybeOptions: PropOptions?)
	local name, spec, options = resolve("metamorphic", nameOrSpec, maybeSpec, maybeOptions)
	local where = `sert.laws.metamorphic("{name}")`
	if type(spec.sut) ~= "function" then
		error(`{where}: expected spec.sut to be a function, got {util.typeof(spec.sut)}`, util.outside())
	end
	if type(spec.relations) ~= "table" then
		error(`{where}: expected spec.relations to be a table, got {util.typeof(spec.relations)}`, util.outside())
	end
	local keys = util.sortedKeys(spec.relations)
	if #keys == 0 then error(`{where}: spec.relations must not be empty`, util.outside()) end

	type CompiledRelation = {
		key: string,
		transform: (any, prop.GenContext) -> any,
		relate: (any, any, any, any) -> (),
	}
	local compiled: { CompiledRelation } = {}
	for i, relKey in keys do
		local rel = spec.relations[relKey]
		if type(rel) ~= "table" then
			error(`{where}: relation "{relKey}" must be a table, got {util.typeof(rel)}`, util.outside())
		end
		registry.checkKeys(`{where}.relations["{relKey}"]`, "field", rel, RELATION_FIELDS)
		if type(rel.transform) ~= "function" or type(rel.relate) ~= "function" then
			error(`{where}: relation "{relKey}" must define transform and relate functions`, util.outside())
		end
		compiled[i] = { key = relKey, transform = rel.transform, relate = rel.relate }
	end

	local genFn: Generator<any> = spec.gen
	local sutFn: (any) -> any = spec.sut :: any
	local propOpts: PropOptions? = options
	local describeOpts: registry.DescribeOptions? = if propOpts ~= nil
		then {
			file = propOpts.file,
			target = propOpts.target,
			skip = propOpts.skip,
			focus = propOpts.focus,
		}
		else nil

	registry.api.describe(name, function()
		for _, entry in compiled do
			local transformFn = entry.transform
			local relateFn = entry.relate
			prop(entry.key, function(g: prop.GenContext)
				local origInput = genFn(g)
				g:note(function() return `origInput: {repr(origInput)}` end)
				local txInput = transformFn(origInput, g)
				g:note(function() return `txInput: {repr(txInput)}` end)
				local origOut = sutFn(origInput)
				g:note(function() return `origOut: {repr(origOut)}` end)
				local txOut = sutFn(txInput)
				g:note(function() return `txOut: {repr(txOut)}` end)
				relateFn(origInput, origOut, txInput, txOut)
			end, propOpts)
		end
	end, describeOpts)
end

local function theoreticalRatio(bound: string, n1: number, n2: number): number
	if bound == "O(1)" then
		return 1
	elseif bound == "O(log n)" then
		return math.log(math.max(n2, 2)) / math.log(math.max(n1, 2))
	elseif bound == "O(n)" then
		return n2 / n1
	else
		return (n2 * math.log(math.max(n2, 2))) / (n1 * math.log(math.max(n1, 2)))
	end
end

local function calibrateIters(fn: (any) -> any, input: any): number
	local iters = 1
	local TARGET_BATCH = 0.001
	local MAX_ITERS = 32768
	while iters < MAX_ITERS do
		local t0 = os.clock()
		for _ = 1, iters do
			local _res = fn(input)
		end
		if os.clock() - t0 >= TARGET_BATCH then break end
		iters *= 2
	end
	return iters
end

--- Checks asymptotic time/cost growth against `spec.bound` across consecutive `sizes`.
function laws.complexity(nameOrSpec: any, maybeSpec: any?, maybeOptions: TestOptions?)
	local name, spec, rawOpts = resolve("complexity", nameOrSpec, maybeSpec, maybeOptions)
	local where = `sert.laws.complexity("{name}")`
	local boundVal: any = spec.bound
	if type(boundVal) ~= "string" or not VALID_BOUNDS[boundVal] then
		error(
			`{where}: expected bound "O(1)", "O(log n)", "O(n)", or "O(n log n)", got {repr(boundVal)}`,
			util.outside()
		)
	end
	local bound: string = boundVal
	local measureFn: ((any) -> number)? = spec.measure
	local sutFn: ((any) -> any)? = spec.sut
	if measureFn ~= nil and type(measureFn) ~= "function" then
		error(`{where}: expected spec.measure to be a function, got {util.typeof(measureFn)}`, util.outside())
	end
	if sutFn ~= nil and type(sutFn) ~= "function" then
		error(`{where}: expected spec.sut to be a function, got {util.typeof(sutFn)}`, util.outside())
	end
	if measureFn == nil and sutFn == nil then
		error(`{where}: expected either spec.measure or spec.sut to be provided`, util.outside())
	end

	local rawSizes: any = if spec.sizes ~= nil then spec.sizes else DEFAULT_COMPLEXITY_SIZES
	if type(rawSizes) ~= "table" or #rawSizes < 2 then
		error(`{where}: expected spec.sizes array with at least 2 sizes`, util.outside())
	end
	local rawList = rawSizes :: { any }
	local sizes: { number } = {}
	for i = 1, #rawList do
		local sz = rawList[i]
		if type(sz) ~= "number" or sz ~= sz or sz == math.huge or sz < 2 then
			error(`{where}: expected sizes[{i}] >= 2, got {repr(sz)}`, util.outside())
		end
		local numSz: number = sz
		if i > 1 and numSz <= sizes[i - 1] then
			error(`{where}: expected strictly increasing sizes ({sizes[i - 1]} < {numSz})`, util.outside())
		end
		sizes[i] = numSz
	end

	local genFn: (number) -> any = spec.gen
	local testOpts: TestOptions? = rawOpts

	registry.api.test(name, function()
		local inputs: { any } = table.create(#sizes)
		for i, n in sizes do
			inputs[i] = genFn(n)
		end

		if measureFn ~= nil then
			local mFn = measureFn
			local slack = if bound == "O(1)" then 1.75 else 1.8
			local costs: { number } = table.create(#sizes, 0)
			for i, input in inputs do
				local cost = mFn(input)
				if type(cost) ~= "number" or cost ~= cost or cost < 0 then
					error(`{where}: measure returned invalid cost {repr(cost)} at n={sizes[i]}`, 0)
				end
				costs[i] = cost
			end
			for i = 1, #sizes - 1 do
				local n1, n2 = sizes[i], sizes[i + 1]
				local c1, c2 = costs[i], costs[i + 1]
				local ratio = if c1 == 0 and c2 == 0 then 1 elseif c1 <= 0 then math.huge else c2 / c1
				local limit = slack * theoreticalRatio(bound, n1, n2)
				assertions.le(
					ratio,
					limit,
					`{where} [{bound}] exceeded scaling bound from n={n1} (cost={c1}) to n={n2} (cost={c2}): ratio {string.format(
						"%.3f",
						ratio
					)} > limit {string.format("%.3f", limit)}`
				)
			end
			return
		end

		local fn = sutFn :: (any) -> any
		for i = 1, #sizes - 1 do
			local n1, n2 = sizes[i], sizes[i + 1]
			local input1, input2 = inputs[i], inputs[i + 1]
			for _ = 1, 3 do
				local _w1 = fn(input1)
				local _w2 = fn(input2)
			end
			local iters1 = calibrateIters(fn, input1)
			local iters2 = calibrateIters(fn, input2)
			local ratios: { number } = table.create(7, 0)
			for trial = 1, 7 do
				local t1: number, t2: number
				if trial % 2 == 1 then
					local s1 = os.clock()
					for _ = 1, iters1 do
						local _r1 = fn(input1)
					end
					t1 = os.clock() - s1
					local s2 = os.clock()
					for _ = 1, iters2 do
						local _r2 = fn(input2)
					end
					t2 = os.clock() - s2
				else
					local s2 = os.clock()
					for _ = 1, iters2 do
						local _r2 = fn(input2)
					end
					t2 = os.clock() - s2
					local s1 = os.clock()
					for _ = 1, iters1 do
						local _r1 = fn(input1)
					end
					t1 = os.clock() - s1
				end
				local per1 = math.max(t1, 1e-9) / iters1
				local per2 = math.max(t2, 1e-9) / iters2
				ratios[trial] = per2 / per1
			end
			table.sort(ratios)
			local medianRatio = ratios[4]
			local limit = 2.2 * theoreticalRatio(bound, n1, n2)
			assertions.le(
				medianRatio,
				limit,
				`{where} [{bound}] exceeded timed ratio from n={n1} to n={n2}: median ratio {string.format(
					"%.3f",
					medianRatio
				)} > limit {string.format("%.3f", limit)}`
			)
		end
	end, testOpts)
end

return (laws :: any) :: Laws
