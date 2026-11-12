--!strict
-- Universal property contract suites (`sert.laws`): `codec`, `order`, `algebra`, and `differential`.

local assertions = require("../core/assert")
local format = require("../core/format")
local gen = require("./gen")
local prop = require("../prop")
local registry = require("../core/registry")
local util = require("../core/util")

export type Generator<T> = gen.Generator<T>
export type Equals<T> = (a: T, b: T) -> boolean
export type PropOptions = prop.PropOptions

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

export type Laws = {
	codec: CodecLawFn,
	order: OrderLawFn,
	algebra: AlgebraLawFn,
	differential: DifferentialLawFn,
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
}

local repr = format.repr

local function resolve(
	kind: string,
	nameOrSpec: any,
	maybeSpec: any,
	maybeOptions: any
): (string, { [string]: any }, PropOptions?)
	local at = util.outside()
	local isTable = type(nameOrSpec) == "table"
	if not isTable and type(nameOrSpec) ~= "string" then
		error(`sert.laws.{kind}: expected a name string or a spec table, got {util.typeof(nameOrSpec)}`, at)
	end
	if not isTable and type(maybeSpec) == "table" and maybeSpec.gen == nil and maybeOptions ~= nil then
		error(`sert.laws.{kind}: pass the spec before the options: sert.laws.{kind}(name, spec, opts?)`, at)
	end
	local spec = if isTable then nameOrSpec else maybeSpec
	local options: PropOptions? = if isTable then maybeSpec else maybeOptions
	local name: string = if isTable then (spec.name or `{kind} laws`) else nameOrSpec
	local where = `sert.laws.{kind}("{name}")`
	if type(spec) ~= "table" then error(`{where}: expected a spec table, got {util.typeof(spec)}`, at) end
	registry.checkKeys(where, "spec field", spec, SPEC_FIELDS[kind])
	registry.checkKeys(where, "option", options, prop.PROP_OPTIONS)
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

return (laws :: any) :: Laws
