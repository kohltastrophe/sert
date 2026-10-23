--!strict
-- Reusable property and structural contract suites (`sert.laws`): `codec`, `chunk`, `order`, `registry`, `remote`, `algebra`, `differential`, and `ui`.

local gen = require("./gen")
local prop = require("./prop")
local registry = require("./core/registry")
local util = require("./util")

export type Generator<T> = gen.Generator<T>
export type Equals<T> = (a: T, b: T) -> boolean

export type CodecSpec<T = any, E = any> = {
	name: string?,
	gen: (g: prop.Gen) -> T,
	encode: (value: T) -> E,
	decode: (encoded: E) -> T,
	eq: ((a: T, b: T) -> boolean)?, -- defaults to `sert.rawEq`
}

export type ChunkSpec<T = any, C = any> = {
	name: string?,
	gen: (g: prop.Gen) -> T,
	chunk: (value: T, budget: number) -> { C },
	join: (chunks: { C }) -> T,
	measure: ((chunk: C) -> number)?,
	eq: ((a: T, b: T) -> boolean)?, -- defaults to `sert.rawEq`
	minSize: number?, -- defaults to 8
	maxSize: number?, -- defaults to 256
}

export type OrderSpec<T = any> = {
	name: string?,
	gen: (g: prop.Gen) -> T,
	lt: (a: T, b: T) -> boolean,
	eq: ((a: T, b: T) -> boolean)?,
}

export type RegistrySpec = {
	name: string?,
	entries: any,
	schema: { [string]: any }?,
	check: ((entry: any, key: any) -> ())?,
	aliases: { [string]: any }?,
}

export type RemoteSpec = {
	name: string?,
	handler: (player: any, ...any) -> ...any,
	makePlayer: (() -> any)?,
	validGen: Generator<any>?,
	invalidGen: Generator<any>?,
	argCount: number?,
	allowError: boolean?,
	checkState: (player: any, ...any) -> (),
	post: ((player: any, ok: boolean, result: any, ...any) -> ())?,
}

export type AlgebraSpec<T = any> = {
	name: string?,
	gen: Generator<T>,
	op: (a: T, b: T) -> T,
	identity: T?,
	associative: boolean?, -- default true
	commutative: boolean?, -- default false
	idempotent: boolean?, -- default false
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

export type ViewportPreset = { name: string, size: Vector2 }

export type UiSpec = {
	name: string?,
	mount: (env: any, parent: any, viewport: Vector2) -> any,
	viewports: { ViewportPreset }?,
	tolerance: number?,
	noOverlap: boolean?,
	fitsViewport: boolean?,
	noTextOverflow: boolean?,
	check: ((env: any, root: any, viewport: ViewportPreset) -> ())?,
}

export type Laws = {
	codec: (nameOrSpec: string | CodecSpec, maybeSpec: any?, maybeOptions: registry.PropOptions?) -> (),
	chunk: (nameOrSpec: string | ChunkSpec, maybeSpec: any?, maybeOptions: registry.PropOptions?) -> (),
	order: (nameOrSpec: string | OrderSpec, maybeSpec: any?, maybeOptions: registry.PropOptions?) -> (),
	registry: (nameOrSpec: string | RegistrySpec, maybeSpec: any?, maybeOptions: registry.TestOptions?) -> (),
	remote: (nameOrSpec: string | RemoteSpec, maybeSpec: any?, maybeOptions: registry.PropOptions?) -> (),
	algebra: (nameOrSpec: string | AlgebraSpec, maybeSpec: any?, maybeOptions: registry.PropOptions?) -> (),
	differential: (
		nameOrSpec: string | DifferentialSpec,
		maybeSpec: any?,
		maybeOptions: registry.PropOptions?
	) -> (),
	ui: (nameOrSpec: string | UiSpec, maybeSpec: any?, maybeOptions: registry.TestOptions?) -> (),
}

local SPEC_FIELDS: { [string]: { string } } = {
	codec = { "decode", "encode", "eq", "gen", "name" },
	chunk = { "chunk", "eq", "gen", "join", "maxSize", "measure", "minSize", "name" },
	order = { "eq", "gen", "lt", "name" },
	registry = { "aliases", "check", "entries", "name", "schema" },
	remote = {
		"allowError",
		"argCount",
		"checkState",
		"handler",
		"invalidGen",
		"makePlayer",
		"name",
		"post",
		"validGen",
	},
	algebra = { "associative", "commutative", "eq", "gen", "idempotent", "identity", "inverse", "name", "op" },
	differential = { "eq", "gen", "name", "oracle", "sut" },
	ui = { "check", "fitsViewport", "mount", "name", "noOverlap", "noTextOverflow", "tolerance", "viewports" },
}

local function resolve(
	kind: string,
	nameOrSpec: any,
	maybeSpec: any,
	maybeOptions: any,
	keys: { string },
	level: number
): (string, any, any)
	local at = util.outside()
	local isTable = type(nameOrSpec) == "table"
	if not isTable and type(nameOrSpec) ~= "string" then
		error(`sert.laws.{kind}: expected a name string or a spec table, got {typeof(nameOrSpec)}`, at)
	end
	local spec = if isTable then nameOrSpec else maybeSpec
	local options = if isTable then maybeSpec else maybeOptions
	local name: string = if isTable then (spec.name or `{kind} laws`) else nameOrSpec
	local where = `sert.laws.{kind}("{name}")`
	if type(spec) ~= "table" then error(`{where}: expected a spec table, got {typeof(spec)}`, at) end
	registry.checkKeys(where, "spec field", spec, SPEC_FIELDS[kind], level + 1)
	registry.checkKeys(where, "option", options, keys, level + 1)
	return name, spec, options
end

local LawsModule = {}

function LawsModule.bind(sert: any): Laws
	local laws = {}
	local repr = sert.format.repr

	local function dispatchProp(
		kind: string,
		nameOrSpec: any,
		maybeSpec: any,
		maybeOptions: registry.PropOptions?,
		makeFn: (spec: any) -> (prop.Gen) -> ()
	)
		local name, spec, options = resolve(kind, nameOrSpec, maybeSpec, maybeOptions, registry.PROP_OPTIONS, 4)
		registry.define("prop", name, makeFn(spec), options)
	end

	local function checkEq(eqFn: ((any, any) -> boolean)?, got: any, want: any, label: string, defaultWhy: string)
		if eqFn ~= nil then
			sert(eqFn(got, want), `{label}: expected {repr(want)}, got {repr(got)}`)
		else
			sert.rawEq(got, want, defaultWhy)
		end
	end

	--- Checks round-trip (`decode(encode(x)) == x`), determinism (`encode(x) == encode(x)`), and idempotence.
	function laws.codec(nameOrSpec: any, maybeSpec: any?, maybeOptions: registry.PropOptions?)
		dispatchProp("codec", nameOrSpec, maybeSpec, maybeOptions, function(spec: any)
			return function(g: prop.Gen)
				local value = spec.gen(g)
				g:note(function() return `value: {repr(value)}` end)
				local encoded1, encoded2 = spec.encode(value), spec.encode(value)
				sert.rawEq(encoded1, encoded2, "codec determinism: encode(x) must equal encode(x)")
				local decoded = spec.decode(encoded1)
				checkEq(spec.eq, decoded, value, "codec round-trip", "codec round-trip: decode(encode(x)) must equal x")
				sert.rawEq(
					spec.encode(decoded),
					encoded1,
					"codec idempotence: encode(decode(encode(x))) must equal encode(x)"
				)
			end
		end)
	end

	--- Checks that `chunk(x, budget)` produces non-empty chunks within `budget` that `join` reconstructs into `x`.
	function laws.chunk(nameOrSpec: any, maybeSpec: any?, maybeOptions: registry.PropOptions?)
		dispatchProp("chunk", nameOrSpec, maybeSpec, maybeOptions, function(spec: any)
			local maxSize = spec.maxSize or math.max(spec.minSize or 0, 256)
			local minSize = spec.minSize or math.min(8, maxSize)
			local measureFn: ((any) -> number)? = spec.measure
			return function(g: prop.Gen)
				local value = spec.gen(g)
				local budget = if minSize == maxSize then maxSize else g:int(minSize, maxSize)
				g:note(function() return `budget: {budget}, value: {repr(value)}` end)
				local chunks = spec.chunk(value, budget)
				sert(type(chunks) == "table", "chunk must return a table of chunks")
				for index, item in chunks do
					local nonEmpty = if type(item) == "string"
						then #item > 0
						elseif type(item) == "table" then next(item) ~= nil
						elseif type(item) == "buffer" then buffer.len(item) > 0
						else item ~= nil
					sert(nonEmpty, `chunk[{index}] must not be empty`)
					if measureFn ~= nil then
						local size = (measureFn :: (any) -> number)(item)
						sert(
							size <= budget or (type(item) == "table" and #item == 1),
							`chunk[{index}] size {size} exceeds budget {budget}: {repr(item)}`
						)
					end
				end
				checkEq(
					spec.eq,
					spec.join(chunks),
					value,
					"chunk reconstruction",
					"chunk reconstruction: join(chunk(x, budget)) must equal x"
				)
			end
		end)
	end

	--- Checks strict weak ordering laws for `lt(a, b)` (irreflexivity, asymmetry, transitivity, and equivalence transitivity).
	function laws.order(nameOrSpec: any, maybeSpec: any?, maybeOptions: registry.PropOptions?)
		dispatchProp("order", nameOrSpec, maybeSpec, maybeOptions, function(spec: any)
			local lt, eqFn: ((any, any) -> boolean)? = spec.lt, spec.eq
			return function(g: prop.Gen)
				local a, b, c = spec.gen(g), spec.gen(g), spec.gen(g)
				g:note(function() return `a={repr(a)}, b={repr(b)}, c={repr(c)}` end)
				for _, x in { a, b, c } do
					sert(not lt(x, x), `order irreflexivity failed for {repr(x)}`)
					if eqFn ~= nil then
						sert((eqFn :: (any, any) -> boolean)(x, x), `order eq reflexivity failed for {repr(x)}`)
					end
				end
				local ab, ba, bc, cb, ac, ca = lt(a, b), lt(b, a), lt(b, c), lt(c, b), lt(a, c), lt(c, a)
				for _, pair in { { ab, ba, a, b }, { bc, cb, b, c }, { ac, ca, a, c } } do
					if pair[1] then
						sert(not pair[2], `order asymmetry failed for {repr(pair[3])} and {repr(pair[4])}`)
					end
					if eqFn ~= nil then
						local incomp = not pair[1] and not pair[2]
						sert(
							(eqFn :: (any, any) -> boolean)(pair[3], pair[4]) == incomp
								and (eqFn :: (any, any) -> boolean)(pair[4], pair[3]) == incomp,
							`order eq consistency failed for {repr(pair[3])} and {repr(pair[4])}`
						)
					end
				end
				if ab and bc then sert(ac, `order transitivity failed for {repr(a)} < {repr(b)} < {repr(c)}`) end
				if cb and ba then sert(ca, `order transitivity failed for {repr(c)} < {repr(b)} < {repr(a)}`) end
				if ac and cb then sert(ab, `order transitivity failed for {repr(a)} < {repr(c)} < {repr(b)}`) end
				if bc and ca then sert(ba, `order transitivity failed for {repr(b)} < {repr(c)} < {repr(a)}`) end
				if ba and ac then sert(bc, `order transitivity failed for {repr(b)} < {repr(a)} < {repr(c)}`) end
				if ca and ab then sert(cb, `order transitivity failed for {repr(c)} < {repr(a)} < {repr(b)}`) end
				local eqAB, eqBC, eqAC = not ab and not ba, not bc and not cb, not ac and not ca
				if (eqAB and eqBC and not eqAC) or (eqAB and eqAC and not eqBC) or (eqBC and eqAC and not eqAB) then
					sert(false, `order equivalence transitivity failed for {repr(a)}, {repr(b)}, {repr(c)}`)
				end
			end
		end)
	end

	--- Checks schema fields, `check`, and `aliases` across every entry in `spec.entries`.
	function laws.registry(nameOrSpec: any, maybeSpec: RegistrySpec?, maybeOptions: registry.TestOptions?)
		local name, spec, options = resolve("registry", nameOrSpec, maybeSpec, maybeOptions, registry.TEST_OPTIONS, 3)
		for field, rule in spec.schema or {} do
			if type(rule) ~= "string" and type(rule) ~= "function" then
				error(
					`laws.registry: schema.{tostring(field)} must be a type name ("string", "number?") or a predicate, got {typeof(
						rule
					)}`,
					2
				)
			end
		end
		local function checkAll()
			local checkFn: ((any, any) -> ())? = spec.check
			local entries: { [any]: any } = if type(spec.entries) == "function"
				then (spec.entries :: () -> { [any]: any })()
				else spec.entries
			sert(type(entries) == "table", "laws.registry: entries must be a table")
			local count = 0
			for key, entry in entries do
				count += 1
				if spec.schema ~= nil then
					sert(type(entry) == "table", `laws.registry [{tostring(key)}]: entry must be a table`)
					for field, rule in spec.schema do
						local val = entry[field]
						if type(rule) == "string" then
							local optional = string.sub(rule, -1) == "?"
							local expected = if optional then string.sub(rule, 1, -2) else rule
							if val ~= nil or not optional then
								local actual = type(val)
								sert(
									actual == expected,
									`laws.registry [{tostring(key)}].{field}: expected {rule}, got {actual} ({repr(val)})`
								)
							end
						else
							sert(
								rule(val, entry, key),
								`laws.registry [{tostring(key)}].{field}: predicate failed on {repr(val)}`
							)
						end
					end
				end
				if checkFn ~= nil then checkFn(entry, key) end
				if spec.aliases ~= nil and type(entry) == "table" and type(entry.aliases) == "table" then
					for _, alias in entry.aliases do
						if type(alias) == "string" and #alias > 0 then
							sert(
								(spec.aliases[alias] or spec.aliases[string.lower(alias)]) ~= nil,
								`laws.registry [{tostring(key)}]: alias "{alias}" missing from aliases map`
							)
						end
					end
				end
			end
			sert(count > 0, "laws.registry: registry had 0 entries")
		end
		registry.define("test", name, checkAll, options)
	end

	--- Fuzzes a remote `handler(player, ...)` with adversarial payloads (and optional `validGen` payloads), verifying no unhandled errors, infinite yields, or state corruption via mandatory `checkState`.
	function laws.remote(nameOrSpec: any, maybeSpec: RemoteSpec?, maybeOptions: registry.PropOptions?)
		local name, spec, options = resolve("remote", nameOrSpec, maybeSpec, maybeOptions, registry.PROP_OPTIONS, 3)
		if type(spec.handler) ~= "function" then
			error(
				`sert.laws.remote("{name}"): expected spec.handler to be a function, got {typeof(spec.handler)}`,
				util.outside()
			)
		end
		if type(spec.checkState) ~= "function" then
			error(
				`sert.laws.remote("{name}"): expected spec.checkState to be a function (remote laws must verify state invariants, not just crash-freedom)`,
				util.outside()
			)
		end
		local handler: (any, ...any) -> ...any = spec.handler
		local invalidGen: Generator<any> = spec.invalidGen or gen.remotePayload()
		local makePlayerFn: (() -> any)? = spec.makePlayer
		local checkStateFn: (any, ...any) -> () = spec.checkState
		local postFn: ((any, boolean, any, ...any) -> ())? = spec.post
		local maxArgs = math.max(1, spec.argCount or 3)
		local function getPlayer(): any
			if makePlayerFn ~= nil then return makePlayerFn() end
			return { UserId = 1, Name = "TestPlayer", ClassName = "Player" }
		end
		local descOpts: registry.DescribeOptions? = if options ~= nil and options.file ~= nil
			then { file = options.file }
			else nil
		sert.describe(`{name} [remote laws]`, function()
			registry.define(
				"prop",
				"rejects or safely handles adversarial payloads without unhandled crash",
				function(g: prop.Gen)
					local nArgs = g:int(1, maxArgs)
					local args: { any } = table.create(nArgs)
					for i = 1, nArgs do
						args[i] = invalidGen(g)
					end
					g:note(function()
						local parts: { string } = {}
						for i = 1, nArgs do
							parts[i] = repr(args[i])
						end
						return `args: ({table.concat(parts, ", ")})`
					end)
					local player = getPlayer()
					local co = coroutine.create(handler)
					local ok, err = coroutine.resume(co, player, table.unpack(args, 1, nArgs))
					sert(
						coroutine.status(co) ~= "suspended",
						"remote law: handler yielded unexpectedly (infinite yield)"
					)
					if not ok and spec.allowError ~= true then
						sert(false, `remote law: handler raised unhandled error: {tostring(err)}`)
					end
					if postFn ~= nil then postFn(player, ok, err, table.unpack(args, 1, nArgs)) end
					checkStateFn(player, table.unpack(args, 1, nArgs))
				end,
				options
			)
			if spec.validGen ~= nil then
				local validGen = spec.validGen :: Generator<any>
				registry.define("prop", "accepts valid payloads and preserves state invariants", function(g: prop.Gen)
					local val = validGen(g)
					g:note(function() return `valid payload: {repr(val)}` end)
					local player = getPlayer()
					local co = coroutine.create(handler)
					local ok, err = coroutine.resume(co, player, val)
					sert(
						coroutine.status(co) ~= "suspended",
						"remote law: handler yielded unexpectedly on valid payload"
					)
					sert(ok, `remote law: handler rejected valid payload: {tostring(err)}`)
					if postFn ~= nil then postFn(player, ok, err, val) end
					checkStateFn(player, val)
				end, options)
			end
		end, descOpts)
	end

	local function checkStructEq(eqFn: ((any, any) -> boolean)?, got: any, want: any, label: string, defaultWhy: string)
		if eqFn ~= nil then
			sert(eqFn(got, want), `{label}: expected {repr(want)}, got {repr(got)}`)
		else
			sert.eq(got, want, defaultWhy)
		end
	end

	--- Checks algebraic laws (`associative`, `identity`, `commutative`, `idempotent`, `inverse`) across `spec.gen`.
	function laws.algebra<T>(nameOrSpec: any, maybeSpec: AlgebraSpec<T>?, maybeOptions: registry.PropOptions?)
		local name, spec, options = resolve("algebra", nameOrSpec, maybeSpec, maybeOptions, registry.PROP_OPTIONS, 3)
		if type(spec.op) ~= "function" then
			error(
				`sert.laws.algebra("{name}"): expected spec.op to be a function, got {typeof(spec.op)}`,
				util.outside()
			)
		end
		local genFn: Generator<any> = spec.gen
		local op: (any, any) -> any = spec.op
		local eqFn: ((any, any) -> boolean)? = spec.eq
		local descOpts: registry.DescribeOptions? = if options ~= nil and options.file ~= nil
			then { file = options.file }
			else nil
		sert.describe(`{name} [algebra laws]`, function()
			if spec.associative ~= false then
				registry.define("prop", "associative", function(g: prop.Gen)
					local a, b, c = genFn(g), genFn(g), genFn(g)
					g:note(function() return `a={repr(a)}, b={repr(b)}, c={repr(c)}` end)
					checkStructEq(
						eqFn,
						op(op(a, b), c),
						op(a, op(b, c)),
						"algebra associativity",
						"algebra associativity: op(op(a, b), c) must equal op(a, op(b, c))"
					)
				end, options)
			end
			if spec.identity ~= nil then
				local id = spec.identity
				registry.define("prop", "identity", function(g: prop.Gen)
					local a = genFn(g)
					g:note(function() return `a={repr(a)}, identity={repr(id)}` end)
					checkStructEq(
						eqFn,
						op(a, id),
						a,
						"algebra right identity",
						"algebra right identity: op(a, identity) must equal a"
					)
					checkStructEq(
						eqFn,
						op(id, a),
						a,
						"algebra left identity",
						"algebra left identity: op(identity, a) must equal a"
					)
				end, options)
			end
			if spec.commutative == true then
				registry.define("prop", "commutative", function(g: prop.Gen)
					local a, b = genFn(g), genFn(g)
					g:note(function() return `a={repr(a)}, b={repr(b)}` end)
					checkStructEq(
						eqFn,
						op(a, b),
						op(b, a),
						"algebra commutativity",
						"algebra commutativity: op(a, b) must equal op(b, a)"
					)
				end, options)
			end
			if spec.idempotent == true then
				registry.define("prop", "idempotent", function(g: prop.Gen)
					local a = genFn(g)
					g:note(function() return `a={repr(a)}` end)
					checkStructEq(
						eqFn,
						op(a, a),
						a,
						"algebra idempotence",
						"algebra idempotence: op(a, a) must equal a"
					)
				end, options)
			end
			if spec.inverse ~= nil and spec.identity ~= nil then
				local invFn: (any) -> any = spec.inverse
				local id = spec.identity
				registry.define("prop", "inverse", function(g: prop.Gen)
					local a = genFn(g)
					g:note(function() return `a={repr(a)}, identity={repr(id)}` end)
					local inv = invFn(a)
					checkStructEq(
						eqFn,
						op(a, inv),
						id,
						"algebra right inverse",
						"algebra right inverse: op(a, inverse(a)) must equal identity"
					)
					checkStructEq(
						eqFn,
						op(inv, a),
						id,
						"algebra left inverse",
						"algebra left inverse: op(inverse(a), a) must equal identity"
					)
				end, options)
			end
		end, descOpts)
	end

	--- Verifies that `spec.sut(x)` matches `spec.oracle(x)` across inputs drawn from `spec.gen`.
	function laws.differential<A, B>(nameOrSpec: any, maybeSpec: DifferentialSpec<A, B>?, maybeOptions: registry.PropOptions?)
		local name, spec, options =
			resolve("differential", nameOrSpec, maybeSpec, maybeOptions, registry.PROP_OPTIONS, 3)
		if type(spec.sut) ~= "function" or type(spec.oracle) ~= "function" then
			error(`sert.laws.differential("{name}"): expected spec.sut and spec.oracle to be functions`, util.outside())
		end
		local genFn: Generator<any> = spec.gen
		local sutFn: (any) -> any = spec.sut
		local oracleFn: (any) -> any = spec.oracle
		local eqFn: ((any, any) -> boolean)? = spec.eq
		local descOpts: registry.DescribeOptions? = if options ~= nil and options.file ~= nil
			then { file = options.file }
			else nil
		sert.describe(`{name} [differential laws]`, function()
			registry.define("prop", "matches reference oracle across generated inputs", function(g: prop.Gen)
				local x = genFn(g)
				g:note(function() return `input: {repr(x)}` end)
				local got = sutFn(x)
				local want = oracleFn(x)
				checkStructEq(eqFn, got, want, "differential law", "differential law: sut(x) must equal oracle(x)")
			end, options)
		end, descOpts)
	end

	--- Mounts a UI tree in `sert.env` across viewports (Phone, Tablet, Desktop, Console by default) and runs `Layout.audit` and `spec.check`.
	function laws.ui(nameOrSpec: any, maybeSpec: UiSpec?, maybeOptions: registry.TestOptions?)
		local name, spec, options = resolve("ui", nameOrSpec, maybeSpec, maybeOptions, registry.TEST_OPTIONS, 3)
		if type(spec.mount) ~= "function" then
			error(
				`sert.laws.ui("{name}"): expected spec.mount to be a function, got {typeof(spec.mount)}`,
				util.outside()
			)
		end
		local mountFn: (any, any, any) -> any = spec.mount
		local checkFn: ((any, any, any) -> ())? = spec.check
		local Datatypes = require("./doubles/datatypes")
		local Env = require("./env")
		local Layout = require("./roblox/Layout")
		local isRoblox = (game :: any) ~= nil
		local Vector2Lib: any = if isRoblox then Vector2 else Datatypes.Vector2
		local UDim2Lib: any = if isRoblox then UDim2 else Datatypes.UDim2
		local viewports: { ViewportPreset } = spec.viewports
			or {
				{ name = "Phone", size = Vector2Lib.new(390, 844) },
				{ name = "Tablet", size = Vector2Lib.new(820, 1180) },
				{ name = "Desktop", size = Vector2Lib.new(1920, 1080) },
				{ name = "Console", size = Vector2Lib.new(1920, 1080) },
			}
		local descOpts: registry.DescribeOptions? = if options ~= nil and options.file ~= nil
			then { file = options.file }
			else nil
		sert.describe(`{name} [ui laws]`, function()
			for _, vp in viewports do
				registry.define("test", "layout audit @ " .. vp.name, function()
					local env: any = Env.new({ isClient = true, viewport = vp.size } :: any)
					local setViewport: ((any, any) -> ())? = env.setViewport
					if setViewport ~= nil then setViewport(env, vp.size) end
					if env.playerGui == nil then
						local lp = env.LocalPlayer or env:addPlayer(1, "Player1")
						env.playerGui = if lp ~= nil then lp:FindFirstChild("PlayerGui") else nil
					end
					local ok, err = pcall(function()
						local screenGui = env.Instance.new("ScreenGui")
						screenGui.Size = UDim2Lib.fromOffset(vp.size.X, vp.size.Y)
						local setAbsolute: ((any, any, any, any) -> ())? = env.setAbsolute
						if setAbsolute ~= nil then setAbsolute(env, screenGui, vp.size, Vector2Lib.new(0, 0)) end
						screenGui.Parent = env.playerGui
						local root = mountFn(env, screenGui, vp.size) or screenGui
						local auditFn: ((any, any) -> ())? = (Layout :: any).audit
						if auditFn ~= nil then
							auditFn(root, {
								viewport = vp.size,
								tolerance = spec.tolerance,
								noOverlap = spec.noOverlap,
								fitsViewport = spec.fitsViewport,
								noTextOverflow = spec.noTextOverflow,
							})
						else
							local tol = spec.tolerance or 0.5
							local nodes: { any } = { root }
							for _, d in root:GetDescendants() do
								table.insert(nodes, d)
							end
							for _, node in nodes do
								if node:IsA("GuiObject") and Layout.visible(node) then
									local pos, size = node.AbsolutePosition, node.AbsoluteSize
									if spec.fitsViewport ~= false then
										sert(
											pos.X >= -tol
												and pos.Y >= -tol
												and pos.X + size.X <= vp.size.X + tol
												and pos.Y + size.Y <= vp.size.Y + tol,
											`layout audit: {node:GetFullName()} overflows viewport ({vp.size.X}x{vp.size.Y})`
										)
									end
									if
										spec.noTextOverflow ~= false
										and (node:IsA("TextLabel") or node:IsA("TextButton") or node:IsA("TextBox"))
									then
										local tb = node.TextBounds
										if tb ~= nil then
											sert(
												tb.X <= size.X + tol and tb.Y <= size.Y + tol,
												`layout audit: text overflow on {node:GetFullName()}`
											)
										end
									end
								end
								if spec.noOverlap ~= false then
									local children: { any } = {}
									for _, ch in node:GetChildren() do
										if ch:IsA("GuiObject") and Layout.visible(ch) then
											table.insert(children, ch)
										end
									end
									for i = 1, #children do
										local a = children[i]
										local ap, as = a.AbsolutePosition, a.AbsoluteSize
										for j = i + 1, #children do
											local b = children[j]
											local bp, bs = b.AbsolutePosition, b.AbsoluteSize
											local ox = math.min(ap.X + as.X, bp.X + bs.X) - math.max(ap.X, bp.X)
											local oy = math.min(ap.Y + as.Y, bp.Y + bs.Y) - math.max(ap.Y, bp.Y)
											sert(
												ox <= tol or oy <= tol,
												`layout audit: sibling overlap between {a:GetFullName()} and {b:GetFullName()}`
											)
										end
									end
								end
							end
						end
						if checkFn ~= nil then checkFn(env, root, vp) end
					end)
					local destroyFn: ((any) -> ())? = env.destroy
					local shutdownFn: ((any) -> ())? = env.shutdown
					if destroyFn ~= nil then
						destroyFn(env)
					elseif shutdownFn ~= nil then
						shutdownFn(env)
					end
					if not ok then error(err, 0) end
				end, options)
			end
		end, descOpts)
	end

	return (table.freeze(laws) :: any) :: Laws
end

return table.freeze(LawsModule) :: { bind: (sert: any) -> Laws }
