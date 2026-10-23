--!nonstrict
--!nolint DeprecatedApi
-- sert.laws: codec, chunk, order and registry, registered and inline, and their negative checks.

local mutant = require("../src/core/registry").mutant
local sert = require("../src")

local alphaGen = sert.gen.string("abcdefghijklmnopqrstuvwxyz", 0, 12)

sert.laws.codec("laws · codec verifies round-trip, determinism, and idempotence", {
	gen = function(g)
		return {
			id = g:int(1, 1000),
			label = alphaGen(g),
		}
	end,
	encode = function(v) return `{v.id}:{v.label}` end,
	decode = function(s)
		local id, label = string.match(s, "^(%d+):(.*)$")
		return { id = tonumber(id), label = label }
	end,
}, { runs = 50 })

local chunkStrGen = sert.gen.string("abcdefghi", 0, 60)

sert.laws.chunk("laws · chunk verifies budget adherence and reconstruction", {
	gen = function(g) return chunkStrGen(g) end,
	minSize = 4,
	maxSize = 16,
	chunk = function(str, maxSize)
		local out = {}
		local i = 1
		while i <= #str do
			table.insert(out, string.sub(str, i, i + maxSize - 1))
			i += maxSize
		end
		return out
	end,
	measure = function(piece) return #piece end,
	join = function(chunks) return table.concat(chunks, "") end,
}, { runs = 50 })

sert.laws.order("laws · order verifies strict weak ordering", {
	gen = function(g) return { rank = g:int(0, 10), name = g:int(1, 5) } end,
	lt = function(a, b)
		if a.rank ~= b.rank then return a.rank < b.rank end
		return a.name < b.name
	end,
}, { runs = 50 })

sert.laws.registry("laws · registry validates schema and custom invariants", {
	entries = {
		ban = { name = "ban", group = "moderation", args = { "players", "string?" } },
		kick = { name = "kick", group = "moderation", args = { "players" } },
	},
	schema = {
		name = "string",
		group = "string",
		args = "table",
		description = "string?",
	},
	check = function(entry, key) sert.eq(entry.name, key) end,
})

sert.test("laws · negative checks fail on broken codec, chunk, order, and registry specs", function()
	sert.fails(function()
		sert.laws.codec({
			gen = function(g) return g:int(1, 100) end,
			encode = function(n) return tostring(n) end,
			decode = function(s) return (tonumber(s) or 0) + 1 end,
		}, { runs = 10 })
	end, "codec round-trip")

	sert.fails(function()
		sert.laws.chunk({
			gen = function() return "abcdefghij" end,
			minSize = 3,
			maxSize = 4,
			chunk = function(s) return { s } end,
			measure = function(piece) return #piece end,
			join = function(pieces) return table.concat(pieces, "") end,
		}, { runs = 10 })
	end, "exceeds budget")

	sert.fails(function()
		sert.laws.order({
			gen = function(g) return g:int(1, 5) end,
			lt = function(a, b) return a <= b end,
		}, { runs = 10 })
	end, "order irreflexivity")

	sert.fails(
		function()
			sert.laws.registry({
				entries = {
					bad = { name = 123 },
				},
				schema = {
					name = "string",
				},
			})
		end,
		"expected string"
	)

	sert.fails(function()
		sert.laws.chunk({
			gen = function(g) return g:int(1, 9) end,
			chunk = function(n) return { tostring(n), "" } end,
			join = function(pieces) return tonumber(table.concat(pieces)) end,
		}, { runs = 10 })
	end, "chunk[2] must not be empty")

	sert.fails(function()
		sert.laws.order({
			gen = function(g) return g:int(1, 5) end,
			lt = function(a, b) return a < b end,
			eq = function() return true end,
		}, { runs = 50 })
	end, "order eq consistency failed")
end)

sert.test("laws · inline codec with a custom eq", function()
	sert.laws.codec({
		gen = function(g) return g:int(1, 50) end,
		encode = function(n) return n * 2 end,
		decode = function(n) return n // 2 end,
		eq = function(a, b) return a == b end,
	}, { runs = 15 })
end)

sert.test("laws · inline chunk with a custom eq and an oversized singleton table", function()
	sert.laws.chunk({
		minSize = 4,
		maxSize = 4,
		gen = function(g) return g:int(1, 20) end,
		chunk = function(n) return { { n } } end,
		measure = function()
			return 10 -- exceeds budget 4, allowed because #item == 1 table singleton
		end,
		join = function(chunks) return chunks[1][1] end,
		eq = function(a, b) return a == b end,
	}, { runs = 15 })
end)

sert.test("laws · inline order with a custom eq", function()
	sert.laws.order({
		gen = function(g) return g:int(1, 10) end,
		lt = function(a, b) return a < b end,
		eq = function(a, b) return a == b end,
	}, { runs = 15 })
end)

sert.test("laws · inline registry with function entries, a function schema rule, check and aliases", function()
	local checked = 0
	sert.laws.registry({
		entries = function()
			return {
				tp = {
					name = "tp",
					level = 2,
					aliases = { "teleport", "goto" },
				},
			}
		end,
		schema = {
			name = "string",
			level = function(val) return type(val) == "number" and val > 0 end,
		},
		check = function(entry, key)
			checked += 1
			sert.eq(key, entry.name)
		end,
		aliases = {
			teleport = "tp",
			goto = "tp",
		},
	})
	sert.eq(checked, 1)
end)

sert.test("laws · options carry the file and run options; the spec carries neither", function()
	local function codec(): any
		return {
			gen = function(g) return g:int(1, 9) end,
			encode = tostring,
			decode = tonumber,
		}
	end
	local function chunk(): any
		return {
			gen = function(g) return g:int(1, 9) end,
			chunk = function(n) return { n } end,
			join = function(chunks) return chunks[1] end,
		}
	end
	local function order(): any
		return {
			gen = function(g) return g:int(1, 9) end,
			lt = function(a, b) return a < b end,
		}
	end
	local printed = table.concat(
		sert.capture(function()
			sert.isolate(function()
				sert.laws.codec("c", codec(), { file = "Elsewhere" })
				sert.laws.chunk("k", chunk(), { file = "Elsewhere" })
				sert.laws.order("o", order(), { file = "Elsewhere" })
				sert.laws.registry("r", { entries = { a = {} } }, { file = "Elsewhere" })
				sert.run({ list = true })
			end)
		end),
		"\n"
	)
	for _, name in { "c", "k", "o", "r" } do
		sert.contains(printed, `[sert-list] Elsewhere|{name}`)
	end
	local cases = 0
	local spec = codec()
	spec.gen = function(g)
		cases += 1
		return g:int(1, 9)
	end
	sert.laws.codec(spec, { runs = 7 })
	sert.eq(cases, 7)
end)

sert.test("laws · raise at the spec's line for a bad name, spec, spec field or option", function()
	local function codec(): any
		return {
			gen = function(g) return g:int(1, 9) end,
			encode = tostring,
			decode = tonumber,
		}
	end
	local function raisesHere(fn: () -> (), message: string)
		local line = debug.info(fn, "l") :: number
		local ok, err = pcall(fn)
		sert.eq(ok, false)
		sert.contains(tostring(err), `Laws.spec.luau:{line}: {message}`)
	end
	raisesHere(
		function() sert.laws.codec("c", codec(), { time = 1 }) end,
		'sert.laws.codec("c"): unknown option "time" (options: exhaustive, file,'
	)
	raisesHere(
		function() sert.laws.order("o", codec(), { timout = 3 }) end,
		'sert.laws.order("o"): unknown spec field "encode" (spec fields: eq, gen, lt, name)'
	)
	local withRuns = codec()
	withRuns.runs = 3
	raisesHere(function() sert.laws.codec(withRuns) end, 'sert.laws.codec("codec laws"): unknown spec field "runs"')
	raisesHere(function() sert.laws.chunk("k") end, 'sert.laws.chunk("k"): expected a spec table, got nil')
	raisesHere(
		function() sert.laws.codec(5 :: any, codec()) end,
		"sert.laws.codec: expected a name string or a spec table, got number"
	)
	raisesHere(
		function() sert.laws.registry("r", { entries = { a = {} } }, { runs = 5 } :: any) end,
		'sert.laws.registry("r"): unknown option "runs" (options: file, focus, skip, timeout)'
	)
end)

sert.test("laws · chunk passes the drawn budget to chunk", function()
	local budgets = {}
	sert.laws.chunk({
		gen = function(g) return g:int(1, 9) end,
		minSize = 2,
		maxSize = 5,
		chunk = function(n, budget)
			budgets[budget] = true
			return { n }
		end,
		join = function(chunks) return chunks[1] end,
	}, { runs = 100 })
	sert.eq(budgets, { [2] = true, [3] = true, [4] = true, [5] = true })
end)

sert.test("laws · registered mode inside sert.isolate", function()
	local outerMut = mutant.get()
	local isoOk, isoRes = sert.isolate(function()
		mutant.set(outerMut)
		sert.laws.codec("isolated codec law", {
			gen = function(g) return g:int(1, 10) end,
			encode = function(x) return x end,
			decode = function(x) return x end,
		}, { runs = 5 })

		sert.laws.registry("isolated registry law", {
			entries = { cmd = { name = "cmd" } },
			schema = { name = "string" },
		})

		return sert.run({ silent = true })
	end)
	sert(isoOk, "isolated laws registration succeeded")
	sert.eq(isoRes.passed, 2)
	sert.eq(isoRes.failed, 0)
end)

sert.test("laws · negative schema predicate and missing alias", function()
	sert.fails(function()
		sert.laws.registry({
			entries = { a = { level = -1 } },
			schema = {
				level = function(v) return v > 0 end,
			},
		})
	end, "predicate failed")

	sert.fails(
		function()
			sert.laws.registry({
				entries = { a = { aliases = { "missingAlias" } } },
				aliases = {},
			})
		end,
		'alias "missingAlias" missing'
	)
	sert.laws.registry({
		entries = { a = { aliases = { "TP" } } },
		aliases = { tp = true },
	})

	local line = (debug.info(1, "l") :: number) + 2
	local ok, err = pcall(
		function() sert.laws.registry("bad schema", { entries = { a = { level = 1 } }, schema = { level = 1 } }) end
	)
	sert.eq(ok, false)
	sert(
		string.find(
			tostring(err),
			`Laws%.spec[^:]*:{line}: laws%.registry: schema%.level must be a type name %("string", "number%?"%) or a predicate, got number`
		) ~= nil,
		err
	)

	-- Inline skip and rtest options on laws/define; order transitivity and eq reflexivity/symmetry
	sert.laws.codec("skipped inline codec", {
		gen = function() error("skipped inline law must not run") end,
		encode = tostring,
		decode = tonumber,
	}, { skip = true })
	sert.laws.registry("skipped inline registry", {
		entries = function() error("skipped inline registry must not run") end,
	}, { skip = true })
	if (game :: any) == nil then
		sert.laws.codec("rtest inline codec", {
			gen = function() error("headless rtest inline law must not run") end,
			encode = tostring,
			decode = tonumber,
		}, { rtest = true })
	end

	local seq = { 1, 2, 3 }
	local idx = 0
	sert.fails(function()
		sert.laws.order({
			gen = function()
				idx = (idx % 3) + 1
				return seq[idx]
			end,
			lt = function(x, y) return (x == 1 and y == 3) or (x == 3 and y == 2) end,
		}, { runs = 3 })
	end, "order transitivity failed")
	sert.fails(function()
		sert.laws.order({
			gen = function(g) return g:int(1, 3) end,
			lt = function(x, y) return x < y end,
			eq = function() return false end,
		}, { runs = 3 })
	end, "order eq reflexivity failed")
end)

sert.laws.remote("laws · remote validates untrusted payloads and valid payloads", {
	makePlayer = function() return { UserId = 42, Name = "Alice", ClassName = "Player", coins = 100 } end,
	validGen = sert.gen.int(1, 50),
	handler = function(player, amount)
		if
			type(amount) ~= "number"
			or amount ~= amount
			or amount <= 0
			or amount > 50
			or amount ~= math.floor(amount)
		then
			return false
		end
		player.coins += amount
		return true
	end,
	checkState = function(player)
		sert(type(player.coins) == "number" and player.coins >= 100 and player.coins <= 150, "coins invariant")
	end,
}, { runs = 30 })

sert.laws.algebra("laws · algebra verifies integer addition group laws", {
	gen = sert.gen.int(-100, 100),
	op = function(a, b) return a + b end,
	identity = 0,
	associative = true,
	commutative = true,
	inverse = function(a) return -a end,
}, { runs = 30 })

sert.laws.algebra("laws · algebra verifies math.max idempotence and commutativity", {
	gen = sert.gen.int(-50, 50),
	op = function(a, b) return math.max(a, b) end,
	associative = true,
	commutative = true,
	idempotent = true,
}, { runs = 30 })

sert.laws.differential("laws · differential compares fast clamp against reference", {
	gen = sert.gen.boundaryInt(-1000, 1000),
	sut = function(x) return math.clamp(x, -100, 100) end,
	oracle = function(x)
		if x < -100 then return -100 end
		if x > 100 then return 100 end
		return x
	end,
}, { runs = 40 })

sert.laws.ui("laws · ui audits responsive layout across viewports", {
	mount = function(env, parent, _viewport)
		local UDim2Lib = env.datatypes.UDim2
		local frame = env.Instance.new("Frame")
		frame.Name = "Card"
		frame.Size = UDim2Lib.fromOffset(120, 40)
		frame.Position = UDim2Lib.fromOffset(10, 10)
		frame.Parent = parent
		local second = env.Instance.new("Frame")
		second.Name = "Action"
		second.Size = UDim2Lib.fromOffset(120, 40)
		second.Position = UDim2Lib.fromOffset(10, 60)
		second.Parent = parent
		return parent
	end,
	check = function(_env, root, vp) sert(root:FindFirstChild("Card") ~= nil, `Card mounted on {vp.name}`) end,
})

sert.test("laws · negative checks for remote, algebra, differential, and ui laws", function()
	-- remote: missing checkState is rejected so invariant-free fuzz tests cannot be registered
	sert.fails(function()
		sert.laws.remote(
			{
				handler = function() end,
			} :: any,
			{ runs = 5 }
		)
	end, "expected spec.checkState to be a function")

	-- remote: unhandled crash
	sert.fails(function()
		sert.laws.remote({
			handler = function(_player, x)
				if x == nil or type(x) ~= "table" then error("unhandled crash!") end
			end,
			checkState = function() end,
		}, { runs = 15 })
	end, "handler raised unhandled error")

	-- remote: allowError = true permits errors as long as checkState and post hold
	local postCount = 0
	sert.laws.remote({
		allowError = true,
		handler = function(_player, x) assert(type(x) == "number", "expected number") end,
		post = function(_player, ok)
			postCount += 1
			sert(type(ok) == "boolean", "post receives boolean status")
		end,
		checkState = function(player) sert(player.UserId == 1, "default player intact") end,
	}, { runs = 15 })
	sert(postCount == 15, "post called for every remote run")

	-- remote: unexpected yield
	sert.fails(function()
		sert.laws.remote({
			handler = function() coroutine.yield() end,
			checkState = function() end,
		}, { runs = 5 })
	end, "handler yielded unexpectedly")

	-- remote: state invariant corrupted
	sert.fails(function()
		sert.laws.remote({
			makePlayer = function() return { UserId = 1, balance = 100 } end,
			invalidGen = sert.gen.constant(-999),
			handler = function(player, delta)
				player.balance += delta
			end,
			checkState = function(player) sert(player.balance >= 0, "negative balance!") end,
		}, { runs = 5 })
	end, "negative balance!")

	-- remote: rejects valid payload
	sert.fails(function()
		sert.laws.remote({
			allowError = true,
			validGen = sert.gen.int(1, 10),
			handler = function() error("broken on valid input") end,
			checkState = function() end,
		}, { runs = 5 })
	end, "handler rejected valid payload")

	-- algebra: non-associative subtraction
	sert.fails(function()
		sert.laws.algebra({
			gen = sert.gen.int(1, 20),
			op = function(a, b) return a - b end,
		}, { runs = 20 })
	end, "algebra associativity")

	-- algebra: wrong identity
	sert.fails(function()
		sert.laws.algebra({
			gen = sert.gen.int(1, 20),
			op = function(a, b) return a + b end,
			identity = 1,
		}, { runs = 10 })
	end, "algebra right identity")

	-- algebra: non-commutative string concat
	sert.fails(function()
		sert.laws.algebra({
			gen = sert.gen.pick({ "a", "b" }),
			op = function(a, b) return a .. b end,
			commutative = true,
		}, { runs = 20 })
	end, "algebra commutativity")

	-- algebra: non-idempotent addition
	sert.fails(function()
		sert.laws.algebra({
			gen = sert.gen.int(1, 10),
			op = function(a, b) return a + b end,
			idempotent = true,
		}, { runs = 10 })
	end, "algebra idempotence")

	-- algebra: wrong inverse
	sert.fails(function()
		sert.laws.algebra({
			gen = sert.gen.int(1, 10),
			op = function(a, b) return a + b end,
			identity = 0,
			inverse = function(a) return a end,
		}, { runs = 10 })
	end, "algebra right inverse")

	-- differential: sut diverges from oracle
	sert.fails(function()
		sert.laws.differential({
			gen = sert.gen.int(1, 10),
			sut = function(x) return x + 1 end,
			oracle = function(x) return x end,
		}, { runs = 10 })
	end, "differential law")

	-- ui: viewport overflow
	sert.fails(function()
		sert.laws.ui({
			mount = function(env, parent)
				local UDim2Lib = env.datatypes.UDim2
				local huge = env.Instance.new("Frame")
				huge.Name = "OverflowFrame"
				huge.Size = UDim2Lib.fromOffset(5000, 5000)
				huge.Parent = parent
				return parent
			end,
		})
	end, "OverflowFrame")

	-- ui: sibling overlap
	sert.fails(function()
		sert.laws.ui({
			mount = function(env, parent)
				local UDim2Lib = env.datatypes.UDim2
				local a = env.Instance.new("Frame")
				a.Name = "BoxA"
				a.Size = UDim2Lib.fromOffset(100, 100)
				a.Position = UDim2Lib.fromOffset(10, 10)
				a.Parent = parent
				local b = env.Instance.new("Frame")
				b.Name = "BoxB"
				b.Size = UDim2Lib.fromOffset(100, 100)
				b.Position = UDim2Lib.fromOffset(20, 20)
				b.Parent = parent
				return parent
			end,
		})
	end, "BoxA")

	-- ui: custom check failure
	sert.fails(function()
		sert.laws.ui({
			mount = function(_env, parent) return parent end,
			check = function() sert(false, "custom ui invariant failed") end,
		})
	end, "custom ui invariant failed")
end)

return {}
