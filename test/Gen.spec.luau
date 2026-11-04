--!nonstrict
-- Generators, shrinking, exhaustive enumeration, and the xorshift32 PRNG.

local sert = require("../src")
local prop = require("../src/prop")
local gen = sert.gen
local rng = sert.rng
local test = sert.test
local expect = sert

local function runProp(name: string, options: any, fn: any, runOptions: any?)
	return sert.prop.run(name, fn, options, runOptions)
end

local function shrinkOf(g, holds: (any) -> boolean, options: { [string]: any }?)
	return runProp("shrink", options or {}, function(source)
		local value = g(source)
		source:note(sert.format.repr(value))
		expect(holds(value), "does not hold")
	end)
end

local function shrunk(g, holds: (any) -> boolean): string
	local result = shrinkOf(g, holds)
	expect(not result.ok, "the property fails")
	return result.notes[1]
end

test("gen · int, float, list, string, combinators, optional, dict, and exhaustive", function()
	for _, bounds in { { -3, 3 }, { 2, 5 }, { -7, -4 }, { 0, 0 }, { -1, 2 } } do
		local lo, hi = bounds[1], bounds[2]
		local seen = {}
		local result = runProp(`int {lo} {hi}`, { runs = 400 }, function(g)
			local n = gen.int(lo, hi)(g)
			expect(n >= lo and n <= hi and n == math.floor(n))
			seen[n] = true
		end)
		expect(result.ok)
		for n = lo, hi do
			expect(seen[n])
		end
	end
	sert.fails(function() gen.int(2, 1) end, "lo <= hi")

	sert.eq(shrunk(gen.int(-1000, 1000), function(x) return x < 500 end), "500")
	sert.eq(shrunk(gen.int(-1000, 1000), function(x) return x > -300 end), "-300")
	sert.eq(shrunk(gen.int(-1e9, 1e9), function(x) return math.abs(x) < 123456 end), "123456")
	sert.eq(shrunk(gen.int(10, 1000), function(x) return x < 600 end), "600")
	sert.eq(shrunk(gen.int(-1000, -10), function(x) return x > -600 end), "-600")
	sert.eq(shrunk(gen.int(10, 1000), function() return false end), "10")
	sert.eq(shrunk(gen.int(-50, 50), function() return false end), "0")

	expect(runProp("float", { runs = 500 }, function(g)
		local x, y = gen.float(-2, 3)(g), gen.float(1, 2)(g)
		expect(x >= -2 and x < 3 and y >= 1 and y < 2 and gen.float(4, 4)(g) == 4)
	end).ok)
	sert.eq(shrunk(gen.float(-10, 10), function() return false end), "0")
	local boundary = tonumber(shrunk(gen.float(-10, 10), function(x) return x < 2.5 end)) :: number
	expect(boundary >= 2.5 and boundary < 2.5 + 1e-6)
	local negative = tonumber(shrunk(gen.float(-10, 10), function(x) return x > -2.5 end)) :: number
	expect(negative <= -2.5 and negative > -2.5 - 1e-6)

	sert.eq(
		shrunk(gen.list(gen.int(0, 100)), function(list)
			for _, v in list do
				if v >= 10 then return false end
			end
			return true
		end),
		"{ 10 }"
	)
	sert.eq(shrunk(gen.list(gen.int(-100, 100), 3), function() return false end), "{ 0, 0, 0 }")
	sert.eq(shrunk(gen.list(gen.int(0, 9)), function(list) return #list < 4 end), "{ 0, 0, 0, 0 }")
	sert.eq(shrunk(gen.string(), function(text) return string.find(text, "z", 1, true) == nil end), '"z"')
	sert.eq(shrunk(gen.string(nil, 0, 30), function(text) return #text < 5 end), '"aaaaa"')
	sert.eq(shrunk(gen.string("xyz", 2, 2), function() return false end), '"xx"')

	expect(runProp("bounds", { runs = 300 }, function(g)
		local list = gen.list(gen.bool(), 2, 5)(g)
		local text = gen.string(gen.pick({ "a", "b" }), 1, 3)(g)
		expect(
			#list >= 2
				and #list <= 5
				and #text >= 1
				and #text <= 3
				and string.match(text, "^[ab]+$")
				and #gen.list(gen.constant(1))(g) <= g.size
		)
	end).ok)
	sert.fails(function() gen.list(gen.bool(), 3, 2) end, "min > max")

	local counts = { a = 0, b = 0 }
	expect(runProp("combinators", { runs = 2000 }, function(g)
		local e = gen.pick({ "x", "y", "z" })(g)
		local o = gen.oneOf({ gen.constant("c"), gen.int(1, 2) })(g)
		local f = gen.frequency({ { 1, gen.constant("a") }, { 3, gen.constant("b") }, { 0, gen.constant("never") } })(g)
		counts[f] += 1
		local r = gen.record({ n = gen.int(0, 3), flag = gen.bool() })(g)
		local t = gen.tuple({ gen.constant(1), gen.bool() })(g)
		local m = gen.map(gen.int(1, 5), function(n) return n * 10 end)(g)
		local list = gen.bind(gen.int(0, 3), function(n) return gen.list(gen.constant(n), n, n) end)(g)
		expect((e == "x" or e == "y" or e == "z") and (o == "c" or o == 1 or o == 2))
		expect(r.n >= 0 and r.n <= 3 and type(r.flag) == "boolean" and #t == 2 and t[1] == 1)
		expect(m % 10 == 0 and m >= 10 and m <= 50)
		for _, v in list do
			expect(v == #list)
		end
	end).ok)
	expect(counts.b > 2 * counts.a and counts.a > 300)
	sert.eq(
		shrunk(
			gen.frequency({ { 1, gen.constant("first") }, { 5, gen.constant("second") } }),
			function() return false end
		),
		'"first"'
	)
	sert.eq(
		shrunk(gen.record({ a = gen.int(-5, 5), b = gen.string() }), function() return false end),
		'{ a = 0, b = "" }'
	)
	sert.eq(
		shrunk(
			gen.bind(gen.int(1, 5), function(n) return gen.list(gen.int(0, 50), n, n) end),
			function(list) return #list < 3 end
		),
		"{ 0, 0, 0 }"
	)

	local function same(made, spelled, label: string)
		expect(runProp(label, { runs = 200 }, function(g)
			local value = made(g)
			local tape = prop.tape(g)
			local replayed = prop.gen(1, g.size, table.clone(tape))
			sert.eq(spelled(replayed), value)
			sert.eq(prop.tape(replayed), tape)
		end).ok)
	end
	local inner = gen.int(-3, 9)
	same(gen.optional(inner, 2, 1), gen.frequency({ { 2, gen.constant(nil) }, { 1, inner } }), "optional 2:1")
	same(gen.optional(inner), gen.frequency({ { 1, gen.constant(nil) }, { 1, inner } }), "optional")
	local keys, values = gen.pick({ "a", "b", "c" }), gen.bool()
	same(
		gen.dict(keys, values, 1, 3),
		gen.map(gen.list(gen.tuple({ keys, values }), 1, 3), function(pairs)
			local out = {}
			for _, pair in pairs do
				out[pair[1]] = pair[2]
			end
			return out
		end),
		"dict"
	)
	sert.eq(shrunk(gen.optional(gen.int(1, 5)), function() return false end), "nil")
	sert.eq(shrunk(gen.dict(gen.pick({ "x", "y" }), gen.int(0, 9)), function(map) return map.y == nil end), "{ y = 0 }")

	local seen = {}
	local exh = runProp(
		"ints",
		{ exhaustive = { size = 3 } },
		function(g) table.insert(seen, gen.int(-2, 2)(g)) end,
		{ exhaustive = true }
	)
	expect(exh.ok and exh.cases == 5)
	table.sort(seen)
	sert.eq(seen, { -2, -1, 0, 1, 2 })
	local floats = runProp("floats", { exhaustive = { size = 4 } }, function(g)
		local x = gen.float(-1, 1)(g)
		expect(x >= -1 and x < 1)
	end, { exhaustive = true })
	expect(floats.ok and floats.cases == 10)
	local strings = runProp(
		"strings",
		{ exhaustive = { size = 2 } },
		function(g) gen.string("ab")(g) end,
		{ exhaustive = true }
	)
	expect(strings.ok and strings.cases == 7)
end)

sert.check("gen · reversing a list twice is the identity", { gen.list(gen.int(-5, 5)) }, function(list)
	local reversed, back = {}, {}
	for i = #list, 1, -1 do
		table.insert(reversed, list[i])
	end
	for i = #reversed, 1, -1 do
		table.insert(back, reversed[i])
	end
	sert.eq(back, list)
end, { runs = 100, exhaustive = { size = 2 } })

test("gen · pinned draws, curried g methods, wide spans, list spans, and combinator validation", function()
	local spans = {
		{ 0, 0 },
		{ 0, 1 },
		{ -3, 3 },
		{ 1, 6 },
		{ 0, 999 },
		{ -1000000, 1000000 },
		{ 0, 2 ^ 31 },
		{ 0, 2 ^ 32 - 2 },
		{ 0, 2 ^ 32 - 1 },
		{ -2 ^ 31, 2 ^ 31 - 1 },
	}
	local rows = {}
	expect(runProp("golden draws", { runs = 3 }, function(g)
		local row = {}
		for _, span in spans do
			table.insert(row, g:int(span[1], span[2]))
		end
		table.insert(row, gen.int(-100, 100)(g))
		table.insert(row, gen.int(-2 ^ 31, 2 ^ 31)(g))
		table.insert(rows, row)
	end).ok)
	sert.eq(rows, {
		{ 0, 0, -1, 1, 592, 485173, 679859552, 1461088981, 2967425043, -864702640, -78, 1343948438 },
		{ 0, 0, -3, 1, 420, 250477, 788322514, 2301814304, 1797724091, 1727048747, -56, 1446270221 },
		{ 0, 1, -1, 6, 349, 53842, 198186164, 2711155414, 1200606167, -322152753, -39, 547748337 },
	})

	for seed = 1, 50 do
		for _, bounds in { { -100, 100 }, { 3, 9 }, { -9, -3 }, { -2 ^ 31, 2 ^ 31 } } do
			local g, direct = prop.gen(seed), prop.gen(seed)
			sert.eq(gen.int(bounds[1], bounds[2])(g), direct:int(bounds[1], bounds[2]))
			sert.eq(prop.tape(g), prop.tape(direct))
		end
		for _, bounds in { { -5, 5 }, { 0, 1 }, { 2, 3 }, { -3, -2 } } do
			local g, direct = prop.gen(seed), prop.gen(seed)
			sert.eq(gen.float(bounds[1], bounds[2])(g), direct:float(bounds[1], bounds[2]))
			sert.eq(prop.tape(g), prop.tape(direct))
		end
	end
	local function minimal(draw: (any) -> number): string
		return runProp("minimal", {}, function(g)
			g:note(tostring(draw(g)))
			error("always", 0)
		end).notes[1]
	end
	sert.eq(minimal(function(g) return g:int(-100, 100) end), "0")
	sert.eq(minimal(function(g) return g:int(-9, -3) end), "-3")
	sert.eq(minimal(function(g) return g:float(-5, 5) end), "0")
	sert.eq(minimal(function(g) return g:float(2, 3) end), "2")
	expect(
		runProp(
			"float top",
			{ exhaustive = { size = 4 } },
			function(g) expect(g:float() < 1 and g:float(-1, 0) < 0) end,
			{ exhaustive = true }
		).ok
	)

	sert.fails(function()
		sert.check("uncalled", gen.int :: any, function() end)
	end, "gen.int(…) makes a generator: pass gen.int(1, 10), not gen.int")
	sert.fails(function() gen.float(prop.gen(1) :: any, 1) end, "gen.float(…) makes a generator")
	sert.fails(function()
		sert.check("uncalled", gen.bool :: any, function() end, { runs = 1 })
	end, "gen.bool(…) makes a generator: pass gen.bool(), not gen.bool")
	for name, factory in gen :: any do
		if type(factory) == "function" and name ~= "sample" then
			local ok, err = pcall(factory, prop.gen(1))
			expect(not ok and string.find(tostring(err), `gen.{name}(…) makes a generator`, 1, true))
		end
	end

	local g0 = prop.gen(1)
	local function raisesHere(call: () -> (), message: string)
		local ok, err = pcall(call)
		expect(not ok)
		sert.contains(tostring(err), `Gen.spec.luau:{debug.info(call, "l")}: {message}`)
	end
	raisesHere(
		function() g0:list(g0:int(0, 3) :: any) end,
		"g:list: expected a generator (a function (g) -> value), got number"
	)
	raisesHere(function() g0:list(gen.int :: any) end, "gen.int(…) makes a generator")
	raisesHere(function() g0:optional(1 :: any) end, "g:optional: expected a generator")
	raisesHere(function() g0:tuple({ 1 :: any }) end, "g:tuple: expected a generator")
	raisesHere(function() g0:tuple(gen.constant(1), 2 :: any) end, "g:tuple: expected a generator")
	raisesHere(function() g0:dict(gen.constant(1), "v" :: any) end, "g:dict: expected a generator")

	local negDraw = false
	for seed = 1, 300 do
		if gen.float(-1e308, 1e308)(prop.gen(seed)) < 0 then
			negDraw = true
			break
		end
	end
	expect(negDraw)

	for _, bounds in { { 0, 2 ^ 40 }, { 0, 2 ^ 32 }, { -2 ^ 52, 2 ^ 52 }, { 0, 2 ^ 53 } } do
		local lo, hi = bounds[1], bounds[2]
		local odd, even, residues = 0, 0, {}
		expect(runProp(`wide {lo} {hi}`, { runs = 400 }, function(g)
			local n, m = g:int(lo, hi), gen.int(lo, hi)(g)
			expect(n >= lo and n <= hi and n == math.floor(n) and m >= lo and m <= hi and m == math.floor(m))
			if n % 2 == 0 then
				even += 1
			else
				odd += 1
			end
			residues[n % 256] = true
		end).ok)
		if hi - lo < 2 ^ 53 then
			expect(odd > 100 and even > 100)
			local count = 0
			for _ in residues do
				count += 1
			end
			expect(count > 150)
		end
	end
	expect(prop.gen(1, 40, { 2 ^ 40 }):int(0, 2 ^ 40) == 2 ^ 40)

	local function listSpans(g): { string }
		local out = {}
		for _, span in prop.spans(g) do
			table.insert(out, `{span.list}:{span.start}-{span.stop}`)
		end
		return out
	end
	local tape = { 1, 7, 0, 1, 1, 2, 1, 3, 0, 0 }
	local gs = prop.gen(1, 40, tape)
	local lists = gs:list(function(outer)
		return outer:list(function(inner) return inner:int(0, 9) end)
	end, 1)
	sert.eq(
		{ lists, prop.tape(gs), listSpans(gs) },
		{ { { 7 }, { 2, 3 } }, tape, { "2:1-2", "3:5-6", "3:7-8", "1:4-9" } }
	)
	gs = prop.gen(1, 40, { 1, 4, 1, 5 })
	expect(not pcall(function()
		gs:list(function(inner)
			local v = inner:int(0, 9)
			expect(v < 5)
			return v
		end)
	end))
	sert.eq(listSpans(gs), { "1:1-2" })
end)

test(
	"gen · g:float exhaustive, combinator methods, bytes, filter, uniqueList, datatypes, specials, utf8, set, shuffle, subset, recursive, enum, any",
	function()
		local seenFloats = {}
		local floatRes = runProp("g:float exhaustive", { exhaustive = { size = 4 } }, function(g)
			local f = g:float(-2, 2)
			expect(f >= -2 and f <= 2 and g:float(5, 5) == 5)
			table.insert(seenFloats, f)
		end, { exhaustive = true })
		expect(floatRes.ok and floatRes.cases == 10)
		sert.eq(seenFloats, { 0, 0.4, 0.8, 1.2, 1.6, -0.4, -0.8, -1.2, -1.6, -2 })
		sert.fails(function() prop.gen(1):float(3, 1) end, "lo <= hi")
		local infGen = prop.gen(1)
		for _, fn in
			{
				function() infGen:int(-math.huge, 0) end,
				function() infGen:int(0, math.huge) end,
				function() gen.int(-math.huge, 0) end,
				function() gen.int(0, math.huge) end,
				function() infGen:float(-math.huge, 0) end,
				function() infGen:float(0, math.huge) end,
				function() gen.float(-math.huge, 0) end,
				function() gen.float(0, math.huge) end,
			}
		do
			sert.fails(fn, "expected")
		end

		expect(runProp("g combinators", { runs = 100 }, function(g)
			local opt = g:optional(function(inner) return inner:int(1, 5) end)
			local tup1 = g:tuple({ gen.int(1, 2), gen.bool() })
			local tup2 = g:tuple(gen.int(3, 4), gen.constant("ok"))
			local rec = g:record({ id = gen.int(10, 20), tag = "fixed" })
			local d = g:dict(gen.pick({ "k1", "k2" }), gen.int(1, 3), 0, 3)
			local dRange = g:dict(gen.pick({ "a", "b" }), gen.int(1, 2), 1, 2)
			local arr = g:list(function(inner) return inner:int(1, 5) end, 2, 4)
			local sBounded = g:string("abc", 2, 4)
			local negFloat = gen.float(-5, -1)(g)
			expect((opt == nil or (opt >= 1 and opt <= 5)) and #tup1 == 2 and #tup2 == 2 and tup2[2] == "ok")
			expect(rec.id >= 10 and rec.id <= 20 and rec.tag == "fixed")
			for k, v in d do
				expect((k == "k1" or k == "k2") and v >= 1 and v <= 3)
			end
			local cRange = 0
			for _ in dRange do
				cRange += 1
			end
			expect(
				cRange >= 1
					and cRange <= 2
					and #arr >= 2
					and #arr <= 4
					and #sBounded >= 2
					and #sBounded <= 4
					and negFloat >= -5
					and negFloat < -1
			)
		end).ok)

		local gErr = prop.gen(1)
		for _, errCase in
			{
				{ function() gen.pick({}) end, "gen.pick: an empty list" },
				{ function() gen.oneOf({}) end, "gen.oneOf: no generators" },
				{ function() gen.frequency({}) end, "gen.frequency: no weight" },
				{ function() gen.frequency({ { 0, gen.bool() } }) end, "gen.frequency: no weight" },
				{ function() gen.string("") end, "empty" },
				{ function() gErr:pick({}) end, "g:pick: empty array" },
				{ function() gErr:weighted({}) end, "g:weighted: no item with a positive weight" },
				{ function() gErr:weighted({ { 0, "a" } }) end, "g:weighted: no item with a positive weight" },
			}
		do
			sert.fails(errCase[1], errCase[2])
		end

		local noteRes = runProp("note and tape truncation", { runs = 1, shrinkBudget = { tries = 0 } }, function(g)
			for _ = 1, 70 do
				g:int(0, 10)
			end
			for i = 1, 210 do
				g:note("note line %d", i)
			end
			error("fail with long trace and tape", 0)
		end)
		expect(
			not noteRes.ok
				and string.find(noteRes.report :: string, "… 6 more", 1, true) ~= nil
				and string.find(noteRes.report :: string, "… 10 more", 1, true) ~= nil
		)

		expect(runProp("bytes, filter, uniqueList, datatypes", { runs = 100 }, function(g)
			local b1, b3, b4 = g:bytes(2, 6), g:bytes(4), gen.bytes(2, 5)(g)
			expect(
				buffer.len(b1) >= 2
					and buffer.len(b1) <= 6
					and buffer.len(b3) >= 4
					and buffer.len(b4) >= 2
					and buffer.len(b4) <= 5
			)
			expect(gen.filter(gen.int(0, 50), function(n) return n % 2 == 0 end)(g) % 2 == 0)
			local uniq = gen.uniqueList(gen.int(1, 10), 2, 5)(g)
			expect(#uniq >= 2 and #uniq <= 5 and #gen.uniqueList(gen.record({ k = gen.int(1, 4) }), 1, 3)(g) >= 1)
			local seen = {}
			for _, v in uniq do
				expect(not seen[v])
				seen[v] = true
			end
			sert.expect(gen.vector2()(g)).toBeA("Vector2")
			sert.expect(gen.vector3()(g)).toBeA("Vector3")
			sert.expect(gen.color3()(g)).toBeA("Color3")
			sert.expect(gen.udim()(g)).toBeA("UDim")
			sert.expect(gen.udim2()(g)).toBeA("UDim2")
			sert.expect(gen.cframe()(g)).toBeA("CFrame")
			local nr, rc = gen.numberRange()(g), gen.rect()(g)
			sert.expect(nr).toBeA("NumberRange")
			sert.expect(rc).toBeA("Rect")
			expect(nr.Min <= nr.Max and rc.Min.X <= rc.Max.X and rc.Min.Y <= rc.Max.Y)
		end).ok)

		local shrunkBuf = shrinkOf(
			gen.bytes(1, 8),
			function(b) return buffer.len(b) == 0 or buffer.readu8(b, 0) < 10 end
		)
		expect(not shrunkBuf.ok and shrunkBuf.notes[1] == "buffer(1) 0a")
		sert.eq(shrunk(gen.filter(gen.int(0, 100), function(n) return n >= 7 end), function(n) return n < 20 end), "20")

		for _, errCase in
			{
				{ function() gen.bytes(5, 2) end, "gen.bytes: min > max" },
				{ function() prop.gen(1):bytes(5, 2) end, "g:bytes: min > max" },
				{
					function()
						gen.filter(gen.int(1, 2), function() return true end, 0)
					end,
					"gen.filter: expected maxTries >= 1",
				},
				{
					function()
						gen.filter(gen.int(1, 2), function() return false end, 3)(prop.gen(1))
					end,
					"predicate not satisfied after 3 attempts",
				},
				{ function() gen.uniqueList(gen.int(1, 2), 5, 2) end, "gen.uniqueList: min > max" },
				{
					function() gen.uniqueList(gen.constant(1), 2, 3)(prop.gen(1)) end,
					"could not draw 2 unique elements",
				},
			}
		do
			sert.fails(errCase[1], errCase[2])
		end

		local never = gen.filter(gen.int(1, 10), function() return false end)
		local filterLine = debug.info(1, "l") - 1
		local fLineRes = sert.prop.run(
			"never",
			function(g) gen.list(never, 1, 1)(g) end,
			{ runs = 1, shrinkBudget = { tries = 0 } }
		)
		sert.eq(
			fLineRes.message,
			`gen.filter ({debug.info(1, "s")}:{filterLine}): predicate not satisfied after 100 attempts`
		)

		local long1, long2 = { 0, 0, 0, 0, 0, 0, 0, 0, 0, 1 }, { 0, 0, 0, 0, 0, 0, 0, 0, 0, 2 }
		local deep1, deep2 = { a = { b = { c = 1 } } }, { a = { b = { c = 2 } } }
		for _, pair in { { long1, long2 }, { deep1, deep2 }, { buffer.fromstring("ab"), buffer.fromstring("ac") } } do
			local two = gen.uniqueList(gen.pick(pair), 2, 2)(prop.gen(1))
			expect(#two == 2 and two[1] ~= two[2])
		end
		sert.eq(#gen.uniqueList(gen.pick({ { 1, { 2 } }, { 1, { 2 } } }), 1, 5)(prop.gen(1)), 1)
		sert.fails(
			function() gen.uniqueList(gen.constant(0 / 0), 2, 3)(prop.gen(1)) end,
			"could not draw 2 unique elements"
		)
		sert.fails(function() gen.set(gen.constant(0 / 0), 1, 3)(prop.gen(1)) end, "could not draw 1 unique elements")
		sert.eq(gen.set(gen.constant(0 / 0), 0, 3)(prop.gen(1)), {})
		expect(runProp("set with nan float never drops below min", { runs = 100 }, function(g)
			local s = gen.set(gen.float(-10, 10, { nan = true }), 3, 5)(g)
			local n = 0
			for k, v in s do
				expect(k == k and v == true)
				n += 1
			end
			expect(n >= 3 and n <= 5)
		end).ok)

		-- Shrink hijacking protection when gen.filter or gen.uniqueList exhausts on a shrink candidate
		local filterShrinkRes = runProp("filter shrink does not hijack failure", { runs = 50 }, function(g)
			local x = gen.filter(gen.int(0, 20), function(n) return n >= 5 end, 3)(g)
			g:note(tostring(x))
			expect(x < 10, "expected x < 10")
		end)
		expect(not filterShrinkRes.ok)
		sert.contains(filterShrinkRes.message, "expected x < 10")
		sert.eq(filterShrinkRes.notes, { "10" })

		local uniqShrinkRes = runProp("uniqueList shrink does not hijack failure", { runs = 50 }, function(g)
			local items = gen.uniqueList(gen.int(0, 5), 3, 4)(g)
			g:note(sert.format.repr(items))
			local sum = 0
			for _, v in items do
				sum += v
			end
			expect(sum < 6, "sum too large")
		end)
		expect(not uniqShrinkRes.ok)
		sert.contains(uniqShrinkRes.message, "sum too large")

		-- Wide mixed-sign g:int(-1e308, 1e308) draws both negative and positive values without span overflow
		local wideNeg, widePos = 0, 0
		expect(runProp("wide mixed-sign int", { runs = 200 }, function(g)
			local v = g:int(-1e308, 1e308)
			if v < 0 then
				wideNeg += 1
			else
				widePos += 1
			end
		end).ok)
		expect(wideNeg > 50 and widePos > 50)

		expect(gen.CHARACTERS == prop.CHARACTERS)
		sert.eq({
			gen.sample(gen.record({ kind = "user", id = gen.constant(3) })),
			gen.sample(gen.tuple(gen.constant(1), gen.constant(2))),
			gen.sample(gen.tuple({ gen.constant(1), gen.constant(2) })),
			gen.sample(gen.string(gen.constant("z"), 3, 3)),
			prop.gen(1):string(gen.constant("z"), 2, 2),
		}, { { kind = "user", id = 3 }, { 1, 2 }, { 1, 2 }, "zzz", "zz" })
		for seed = 1, 20 do
			sert.eq(
				gen.sample(gen.dict(gen.pick({ "a", "b", "c" }), gen.int(0, 9)), seed),
				prop.gen(seed):dict(gen.pick({ "a", "b", "c" }), gen.int(0, 9))
			)
			sert.eq(gen.sample(gen.bytes(0, 4), seed), prop.gen(seed):bytes(0, 4))
		end
		sert.fails(function() gen.dict(gen.bool(), gen.bool(), 3, 2) end, "gen.dict: min > max")
		sert.fails(function() gen.string("ab", 3, 2) end, "gen.string: min > max")
		expect(runProp("unified", { runs = 200 }, function(g)
			local w = g:weighted({ { 0, "never" }, { 1, "x" }, { 3, "y" } })
			local s = g:string()
			local b = g:bytes(1, 3)
			expect((w == "x" or w == "y") and #s <= g.size and buffer.len(b) >= 1 and buffer.len(b) <= 3)
		end).ok)
		sert.eq(gen.sample(gen.string("xyz", 2, 6), 77), prop.gen(77):string("xyz", 2, 6))
		sert.fails(function() prop.gen(1):string("") end, "g:string: an empty charset")

		local seeds = {}
		runProp("precedence", { seed = 5, runs = 1 }, function(g) table.insert(seeds, g.seed) end, { seed = 9 })
		runProp("precedence", { runs = 1 }, function(g) table.insert(seeds, g.seed) end, { seed = 9 })
		runProp("precedence", { seed = 5 }, function(g) table.insert(seeds, g.seed) end, { seed = 9, replay = 1234 })
		sert.eq(seeds, { prop.caseSeed("precedence", 5, 1), prop.caseSeed("precedence", 9, 1), 1234 })
		local failedCmd = runProp("default command", { runs = 1 }, function() error("boom", 0) end)
		expect(
			string.find(
				failedCmd.report,
				'replay: python3 tools/sert.py run --filter "default command" --replay=',
				1,
				true
			)
		)

		local okIn, resIn = sert.isolate(function()
			test("outer", function()
				sert.prop("inner", function(g) expect(g:int(0, 1000) < 900, "big") end)
			end)
			return sert.run({ raise = false, silent = true, seed = 1 })
		end)
		expect(okIn)
		local filter, seedStr =
			string.match(resIn.failures[1], 'replay: python3 tools/sert.py run %-%-filter "([^"]+)" %-%-replay=(%d+)')
		sert.eq(filter, "outer")
		local _, againIn = sert.isolate(function()
			test("outer", function()
				sert.prop("inner", function(g) expect(g:int(0, 1000) < 900, "big") end)
			end)
			test("other", function() end)
			local options: any = sert.parseCliArgs({ "--filter=" .. filter, "--replay=" .. seedStr })
			options.raise, options.silent = false, true
			return sert.run(options)
		end)
		expect(
			againIn.failed == 1
				and againIn.passed == 0
				and string.find(againIn.failures[1], `replay · case seed {seedStr}`, 1, true)
		)

		local nRes = runProp("notes", { runs = 1 }, function(g)
			g:note("world\nserver up\nclient up")
			g:note(function(): string error("note exploded", 0) end)
			error("boom", 0)
		end)
		expect(
			not nRes.ok
				and string.find(nRes.report, "      world\n      server up\n      client up\n", 1, true)
				and string.find(nRes.report, "      (note raised: note exploded)", 1, true)
		)

		local spSeen = { nan = 0, inf = 0, ninf = 0, negZero = 0 }
		expect(runProp("float specials", { runs = 600 }, function(g)
			local x = gen.float(-10, 10, { nan = true, inf = true, negZero = true })(g)
			if x ~= x then
				spSeen.nan += 1
			elseif x == math.huge then
				spSeen.inf += 1
			elseif x == -math.huge then
				spSeen.ninf += 1
			elseif x == 0 and 1 / x < 0 then
				spSeen.negZero += 1
			else
				expect(x >= -10 and x < 10)
			end
			local plain = gen.float(-10, 10)(g)
			expect(plain == plain and math.abs(plain) <= 10)
		end).ok)
		for _, count in spSeen do
			expect(count > 0)
		end
		expect(
			tonumber(shrunk(gen.float(-10, 10, { inf = true, nan = true }), function(x) return x == x and x < 5 end))
				== 5
		)
		sert.fails(
			function() gen.float(0, 1, { infinity = true } :: any) end,
			"gen.float: unknown option infinity (nan, inf, negZero)"
		)

		local function codepoints(s: string): { number }
			local out = {}
			for _, point in utf8.codes(s) do
				table.insert(out, point)
			end
			return out
		end
		local widths = {}
		expect(runProp("utf8", { runs = 300 }, function(g)
			local s = gen.utf8(1, 6)(g)
			local length = utf8.len(s)
			expect(length ~= nil and length >= 1 and length <= 6)
			for _, point in codepoints(s) do
				expect((point < 0xD800 or point > 0xDFFF) and point >= 0x20 and point <= 0x10FFFF)
				widths[#utf8.char(point)] = true
			end
		end).ok)
		expect(widths[1] and widths[2] and widths[3] and widths[4])
		sert.eq(shrunk(gen.utf8(), function(s) return utf8.len(s) < 2 end), '"aa"')
		sert.eq(
			shrunk(gen.utf8(), function(s)
				for _, point in codepoints(s) do
					if point > 0x7F then return false end
				end
				return true
			end),
			`"{utf8.char(0x80)}"`
		)
		local uExh = runProp(
			"utf8 exhaustive",
			{ exhaustive = { size = 2 } },
			function(g) expect(utf8.len(gen.utf8(0, 1)(g)) ~= nil) end,
			{ exhaustive = true }
		)
		expect(uExh.ok and uExh.cases == 9)
		sert.fails(function() gen.utf8(3, 1) end, "gen.utf8: min > max")

		expect(runProp("collections", { runs = 300 }, function(g)
			local set = gen.set(gen.int(1, 6), 2, 4)(g)
			local count = 0
			for k, v in set do
				count += 1
				expect(v == true and k >= 1 and k <= 6)
			end
			expect(count >= 2 and count <= 4)
			local perm = gen.shuffle({ "a", "b", "c", "d" })(g)
			table.sort(perm)
			sert.eq(perm, { "a", "b", "c", "d" })
			local sub = gen.subset({ 10, 20, 30, 40, 50 }, 1, 3)(g)
			expect(#sub >= 1 and #sub <= 3)
			for i = 2, #sub do
				expect(sub[i - 1] < sub[i])
			end
		end).ok)
		sert.eq(shrunk(gen.shuffle({ 1, 2, 3 }), function() return false end), "{ 1, 2, 3 }")
		sert.eq(shrunk(gen.subset({ 1, 2, 3, 4 }), function(s) return #s < 2 end), "{ 1, 2 }")
		sert.eq(shrunk(gen.set(gen.int(0, 9)), function(s) return next(s) == nil end), "{ [0] = true }")

		local perms, subsets = {}, {}
		expect(runProp("perms", { exhaustive = { size = 3 } }, function(g)
			perms[table.concat(gen.shuffle({ 1, 2, 3 })(g))] = true
			subsets[table.concat(gen.subset({ 1, 2, 3 })(g), ",")] = true
		end, { exhaustive = true }).ok)
		local pCount, sCount = 0, 0
		for _ in perms do
			pCount += 1
		end
		for _ in subsets do
			sCount += 1
		end
		expect(pCount == 6 and sCount == 8)
		sert.fails(function() gen.subset({ 1, 2 }, 0, 3) end, "gen.subset: expected 0 <= min <= max <= 2")

		local function depth(v): number
			if type(v) ~= "table" then return 0 end
			local d = 0
			for _, c in v do
				d = math.max(d, depth(c))
			end
			return 1 + d
		end
		local tree = gen.recursive(gen.int(0, 9), function(child) return gen.list(child, 1, 3) end, 3)
		local deepSeen = 0
		expect(runProp("trees", { runs = 300 }, function(g)
			local v = tree(g)
			expect(depth(v) <= 3)
			deepSeen = math.max(deepSeen, depth(v))
		end).ok and deepSeen == 3)
		sert.eq(shrunk(tree, function(v) return type(v) == "table" end), "0")

		local nested
		nested = gen.frequency({
			{ 3, gen.constant("leaf") },
			{ 1, gen.lazy(function() return gen.list(nested, 0, 2) end) },
		})
		expect(runProp("lazy", { runs = 100 }, function(g)
			local v = nested(g)
			expect(v == "leaf" or type(v) == "table")
		end).ok)
		sert.fails(function()
			gen.recursive(gen.bool(), function(c) return c end, -1)
		end, "gen.recursive: expected an integer maxDepth >= 0")

		local EnumType = require("../src/doubles/datatypes").Enum.UserInputType
		local items = EnumType:GetEnumItems()
		local lowest = items[1]
		for _, it in items do
			if it.Value < lowest.Value then lowest = it end
		end
		local seenEnum = {}
		expect(runProp("enum", { runs = 200 }, function(g)
			local it = gen.enum(EnumType)(g)
			expect(it.EnumType == EnumType)
			seenEnum[it] = true
		end).ok)
		local eCount = 0
		for _ in seenEnum do
			eCount += 1
		end
		expect(eCount == #items)
		sert.eq(shrunk(gen.enum(EnumType), function() return false end), sert.format.repr(lowest))

		local kinds = {}
		expect(runProp("any", { runs = 400 }, function(g)
			local v = gen.any()(g)
			expect(v ~= nil and v == v or type(v) == "table")
			kinds[type(v)] = true
			expect(type(gen.any(0)(g)) ~= "table")
		end).ok)
		for _, k in { "boolean", "number", "string", "buffer", "table" } do
			expect(kinds[k])
		end
		sert.eq(shrunk(gen.any(), function() return false end), "false")
		sert.eq(gen.sample(gen.any(), 3), gen.sample(gen.any(), 3))
		sert.eq(gen.sample(gen.int(0, 1e6)), gen.sample(gen.int(0, 1e6)))
		expect(#gen.sample(gen.list(gen.bool()), 1, 3) <= 3)
		expect(runProp("uniqueList with nil element generator", { runs = 30 }, function(g)
			local list = gen.uniqueList(gen.optional(gen.int(1, 3)), 0, 5)(g)
			for _, v in list do
				expect(type(v) == "number")
			end
		end).ok)
	end
)

test("gen · boundaryInt, boundaryFloat, malformedString, sparseTable, remotePayload, adversarial", function()
	local bIntSeen: { [number]: boolean } = {}
	expect(runProp("boundaryInt default", { runs = 500 }, function(g)
		local n = gen.boundaryInt()(g)
		expect(n >= -2147483648 and n <= 2147483647 and n == math.floor(n))
		bIntSeen[n] = true
	end).ok)
	for _, target in { 0, 1, -1, 127, -128, 255, 32767, -32768, 65535, 2147483647, -2147483648 } do
		expect(bIntSeen[target])
	end

	local bIntWide: { [number]: boolean } = {}
	expect(runProp("boundaryInt wide", { runs = 400 }, function(g)
		local n = gen.boundaryInt(-9007199254740991, 9007199254740991)(g)
		bIntWide[n] = true
	end).ok)
	expect(bIntWide[9007199254740991] and bIntWide[-9007199254740991])

	sert.eq(shrunk(gen.boundaryInt(-1000, 1000), function() return false end), "0")
	sert.eq(shrunk(gen.boundaryInt(10, 1000), function() return false end), "10")
	sert.eq(shrunk(gen.boundaryInt(-1000, 1000), function(x) return x < 500 end), "500")
	sert.fails(function() gen.boundaryInt(10, 5) end, "lo <= hi")

	local bfSeen = { zero = false, negZero = false, nan = false, posInf = false, negInf = false, finite = false }
	expect(runProp("boundaryFloat", { runs = 500 }, function(g)
		local x = gen.boundaryFloat()(g)
		if x ~= x then
			bfSeen.nan = true
		elseif x == math.huge then
			bfSeen.posInf = true
		elseif x == -math.huge then
			bfSeen.negInf = true
		elseif x == 0 then
			if 1 / x < 0 then
				bfSeen.negZero = true
			else
				bfSeen.zero = true
			end
		else
			bfSeen.finite = true
		end
	end).ok)
	expect(bfSeen.zero and bfSeen.negZero and bfSeen.nan and bfSeen.posInf and bfSeen.negInf and bfSeen.finite)

	local bfBounded = { lo = false, hi = false, nan = false }
	expect(runProp("boundaryFloat bounded", { runs = 400 }, function(g)
		local x = gen.boundaryFloat(10, 20)(g)
		if x ~= x then
			bfBounded.nan = true
		elseif x == 10 then
			bfBounded.lo = true
		elseif x == 20 then
			bfBounded.hi = true
		end
	end).ok)
	expect(bfBounded.lo and bfBounded.hi and bfBounded.nan)
	sert.eq(shrunk(gen.boundaryFloat(-10, 10), function() return false end), "0")
	sert.fails(function() gen.boundaryFloat(5, 1) end, "lo <= hi")

	local msSeen =
		{ empty = false, nul = false, invalidUtf8 = false, patternMagic = false, richText = false, long = false }
	expect(runProp("malformedString", { runs = 300 }, function(g)
		local s = gen.malformedString()(g)
		expect(type(s) == "string")
		if s == "" then msSeen.empty = true end
		if string.find(s, "\0", 1, true) ~= nil then msSeen.nul = true end
		if utf8.len(s) == nil then msSeen.invalidUtf8 = true end
		if string.find(s, "^$()%.[]*+-?", 1, true) ~= nil then msSeen.patternMagic = true end
		if string.find(s, "<font", 1, true) ~= nil then msSeen.richText = true end
		if #s == 1024 then msSeen.long = true end
	end).ok)
	expect(
		msSeen.empty and msSeen.nul and msSeen.invalidUtf8 and msSeen.patternMagic and msSeen.richText and msSeen.long
	)
	sert.eq(shrunk(gen.malformedString(), function() return false end), '""')

	local stSeen = { empty = false, sparse = false, mixed = false, negFloat = false }
	expect(runProp("sparseTable", { runs = 300 }, function(g)
		local t = gen.sparseTable(gen.int(1, 5))(g)
		expect(type(t) == "table")
		if next(t) == nil then stSeen.empty = true end
		if t[10000] ~= nil then stSeen.sparse = true end
		if t.foo ~= nil then stSeen.mixed = true end
		if t[-1] ~= nil and t[1.5] ~= nil then stSeen.negFloat = true end
	end).ok)
	expect(stSeen.empty and stSeen.sparse and stSeen.mixed and stSeen.negFloat)
	sert.eq(shrunk(gen.sparseTable(gen.int(1, 5)), function() return false end), "{}")

	local rpSeen = {
		nilVal = false,
		boolVal = false,
		numVal = false,
		strVal = false,
		tableVal = false,
		cyclicVal = false,
	}
	expect(runProp("remotePayload", { runs = 500 }, function(g)
		local v = gen.remotePayload()(g)
		if v == nil then
			rpSeen.nilVal = true
		elseif type(v) == "boolean" then
			rpSeen.boolVal = true
		elseif type(v) == "number" then
			rpSeen.numVal = true
		elseif type(v) == "string" then
			rpSeen.strVal = true
		elseif type(v) == "table" then
			rpSeen.tableVal = true
			if rawget(v, "self") == v then rpSeen.cyclicVal = true end
		end
	end).ok)
	expect(
		rpSeen.nilVal and rpSeen.boolVal and rpSeen.numVal and rpSeen.strVal and rpSeen.tableVal and rpSeen.cyclicVal
	)
	sert.eq(shrunk(gen.remotePayload(), function() return false end), "nil")
	sert.fails(function() gen.remotePayload(-1) end, "expected an integer depth >= 0")

	local advSeen = { fn = false, thread = false, userdata = false, frozen = false }
	expect(runProp("adversarial", { runs = 600 }, function(g)
		local v = gen.adversarial()(g)
		if type(v) == "function" then
			advSeen.fn = true
			sert.fails(v, "adversarial callback")
		elseif type(v) == "thread" then
			advSeen.thread = true
		elseif type(v) == "userdata" then
			advSeen.userdata = true
		elseif type(v) == "table" and table.isfrozen(v) then
			advSeen.frozen = true
		end
	end).ok)
	expect(advSeen.fn and advSeen.thread and advSeen.userdata and advSeen.frozen)
	sert.eq(shrunk(gen.adversarial(), function() return false end), "nil")
	sert.fails(function() gen.adversarial(-1) end, "expected an integer depth >= 0")
end)

test(
	"rng · xorshift32, new, int, float, chance, fork, fnv1a32, bytes, unbiased wide spans, pick, shuffle, clone",
	function()
		expect(rng.xorshift32(1) == 270369 and rng.xorshift32(0x9E3779B9) == 1359758873)
		local r = rng.new(1)
		sert.eq({ r:next(), r:next(), r:next() }, { 270369, 67634689, 2647435461 })
		local zero = rng.new(0)
		expect(
			zero.state == 0x9E3779B9
				and zero:next() == 1359758873
				and rng.new(2 ^ 32 + 1).state == 1
				and rng.new(1.75).state == 1
		)
		for _, badSeed in { 0.5, 0 / 0, math.huge, -math.huge } do
			local rBad = rng.new(badSeed)
			expect(rBad.state == 0x9E3779B9 and rBad:next() == 1359758873 and prop.gen(badSeed):int(1, 10) >= 1)
		end

		local r42 = rng.new(42)
		sert.eq({ r42:int(1, 6), r42:int(1, 6) }, { 1, 5 })
		sert.near(r42:float(), 0.11095708678476512, 1e-15)
		expect(r42:chance(0.5) == false and rng.new(42):fork("x").state == 4255192495)
		expect(
			rng.new(42):fork().state == rng.new(42):fork().state
				and rng.new(42):fork("x").state ~= rng.new(42):fork("y").state
		)

		sert.eq({ rng.fnv1a32(""), rng.fnv1a32("a"), rng.fnv1a32("sert") }, { 2166136261, 3826002220, 1652437395 })
		local again = {}
		runProp(
			"golden",
			{ runs = 3 },
			function(g)
				table.insert(
					again,
					`{g.seed}:{g:int(0, 1000)},{g:int(-5, 5)},{tostring(g:bool())},{#g:list(
						function(g) return g:int(0, 1) end,
						0,
						10
					)}`
				)
			end
		)
		sert.eq(again, { "2301790736:369,1,true,8", "728432859:680,-5,false,0", "3450052226:992,1,true,0" })

		local rb = rng.new(123)
		local bDefault, bRandom = rb:bytes(32), rng.new(123):bytes(32, "random")
		expect(
			buffer.len(bDefault) == 32
				and buffer.tostring(bDefault) == buffer.tostring(bRandom)
				and buffer.readu32(bDefault, 0) ~= 0
		)
		for _, kind in { "text", "runs", "pattern", "mixed" } do
			expect(buffer.len(rb:bytes(128, kind)) == 128)
		end
		expect(string.match(buffer.tostring(rng.new(7):bytes(40, "text")), "^[%a ]+$") ~= nil)
		sert.fails(function() rb:bytes(8, "bogus" :: any) end, "unknown byte kind bogus")

		local r2, raw = rng.new(42), rng.new(42)
		for _ = 1, 200 do
			sert.eq(r2:int(0, 255), raw:next() % 256)
			sert.eq(r2:int(-8, 7), -8 + raw:next() % 16)
		end
		local wide, top = rng.new(7), 0
		for _ = 1, 4000 do
			local n = wide:int(0, 2 ^ 31)
			if n >= 1.5 * 2 ^ 30 then
				top += 1
			end
		end
		expect(top > 850 and top < 1150 and rng.new(1):int(5, 5) == 5 and rng.new(1):int(0, 2 ^ 32 - 1) >= 0)
		sert.fails(function() rng.new(1):int(3, 2) end, "Rng:int: expected integers lo <= hi")
		sert.fails(function() rng.new(1):int(0, 1.5) end, "Rng:int: expected integers")
		sert.fails(function() rng.new(1):int(0, 2 ^ 32) end, "spanning at most 2^32")

		local r9 = rng.new(9)
		expect(rng.new(5):float(4, 4) == 4)
		sert.near(rng.new(5):float(10, 20), 10 + rng.new(5):float() * 10, 1e-12)
		expect(rng.new(5):float(-1e308, 1e308) >= -1e308)
		sert.fails(function() rng.new(1):float(2, 1) end, "Rng:float: expected lo <= hi")
		sert.fails(function() rng.new(1):float(0, math.huge) end, "Rng:float: expected lo <= hi")
		local seenPick = {}
		for _ = 1, 100 do
			seenPick[r9:pick({ "a", "b", "c" })] = true
		end
		expect(seenPick.a and seenPick.b and seenPick.c)
		sert.fails(function() r9:pick({}) end, "Rng:pick: an empty list")

		local list = { 1, 2, 3, 4, 5, 6, 7, 8 }
		local sameList = rng.new(3):shuffle(list)
		expect(sameList == list)
		table.sort(sameList)
		sert.eq(sameList, { 1, 2, 3, 4, 5, 6, 7, 8 })
		sert.eq(rng.new(3):shuffle({}), {})

		local source = rng.new(11)
		source:next()
		local copy = source:clone()
		expect(copy ~= source and copy.state == source.state)
		sert.eq({ copy:next(), copy:int(1, 6) }, { source:next(), source:int(1, 6) })
		copy:next()
		expect(copy.state ~= source.state)
	end
)

return {}
