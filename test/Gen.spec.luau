--!strict
local propCore = require("../src/prop")
local registry = require("../src/core/registry")
local sert = require("../src")

local gen = sert.gen

local function runIsolated(register: () -> (), opts: sert.RunOptions?): sert.Results
	local sub = registry.newState()
	registry.isolateDepth += 1
	local ok, res = pcall(function(): sert.Results
		return registry.withState(sub, function(): sert.Results
			register()
			local merged: sert.RunOptions = if opts ~= nil then table.clone(opts) else {}
			if merged.quiet == nil and merged.silent == nil then merged.quiet = true end
			if merged.raise == nil then merged.raise = false end
			return sert.run(merged)
		end)
	end)
	registry.isolateDepth -= 1
	if not ok then error(res, 0) end
	return res
end

sert.describe("sert.prop registration, assumptions, and seed replay", function()
	sert.test("registers prop targets, modifiers, each/eachTuple, and inline prop execution", function()
		local log: { string } = {}
		local res = runIsolated(function()
			sert.prop("basic prop", function(g: sert.Gen)
				local x = g:draw(gen.int(1, 10))
				sert.ge(x, 1)
				sert.le(x, 10)
			end, { runs = 10 })

			sert.prop.skip("skipped prop", function() table.insert(log, "never") end)
			sert.prop.skip("skipped prop without fn")
			sert.prop.roblox("roblox prop", function(g: sert.Gen) sert.ge(g:int(0, 5), 0) end, { runs = 3 })
			sert.prop.server("server prop", function(g: sert.Gen) sert.ge(g:int(0, 5), 0) end, { runs = 3 })
			sert.prop.client("client prop", function(g: sert.Gen) sert.ge(g:int(0, 5), 0) end, { runs = 3 })

			sert.prop.each({ { 1, 5 }, { 10, 20 } })("range %s", function(bounds: { number }, g: sert.GenContext)
				local v = g:int(bounds[1], bounds[2])
				sert.ge(v, bounds[1])
				sert.le(v, bounds[2])
			end, { runs = 5 })

			sert.prop.eachTuple({ { 2, 4 }, { 3, 9 } })(
				"%d squared is %d",
				function(base: number, sq: number, g: sert.GenContext)
					local k = g:int(1, 3)
					sert.eq(base * base * k, sq * k)
				end,
				{ runs = 4 }
			)
		end)

		sert.eq(res.failed, 0)
		sert.eq(res.passed, 5)
		if not sert.isRoblox then sert.eq(res.skippedRoblox, 3) end
		sert.eq(log, {})
	end)

	sert.test("handles g:assume filtering, discard exhaustion, vacuous failure, and exact seed replay", function()
		local evenCount = 0
		local okRes = sert.prop.run("even filter", function(g)
			local n = g:draw(gen.int(1, 20))
			g:assume(n % 2 == 0, "must be even")
			sert.eq(n % 2, 0)
			evenCount += 1
		end, { runs = 25, seed = 42 })
		sert.eq(okRes.ok, true)
		sert.eq(okRes.cases, 25)
		sert.eq(evenCount, 25)

		local discardRes = sert.prop.run("impossible assumption", function(g)
			local n = g:draw(gen.int(1, 10))
			g:assume(n > 100, "unreachable bound")
		end, { runs = 15, seed = 7 })
		sert.eq(discardRes.ok, false)
		sert.contains(discardRes.message :: string, "unreachable bound")
		sert.contains(discardRes.message :: string, "discarded")

		local vacuousRes = sert.prop.run("explicitly vacuous", function(g)
			local _ = g:int(1, 5)
			propCore.vacuous(g, "no transitions enabled")
		end, { runs = 10, seed = 3 })
		sert.eq(vacuousRes.ok, false)
		sert.contains(vacuousRes.message :: string, "no transitions enabled in all 10 cases")

		local firstFail = sert.prop.run("replayable failure", function(g)
			local a = g:draw(gen.int(0, 100))
			local b = g:draw(gen.int(0, 100))
			g:note("pair=%d,%d", a, b)
			sert.lt(a + b, 50)
		end, { runs = 50, seed = 2026 })
		sert.eq(firstFail.ok, false)
		sert.ok(firstFail.seed ~= nil)

		local lastFailingPair: { number }? = nil
		local replayRes = sert.prop.run("replayable failure", function(g)
			local a = g:draw(gen.int(0, 100))
			local b = g:draw(gen.int(0, 100))
			if a + b >= 50 then lastFailingPair = { a, b } end
			sert.lt(a + b, 50)
		end, { runs = 50, seed = 2026 }, { replay = firstFail.seed })
		sert.eq(replayRes.ok, false)
		sert.eq(replayRes.shrunk, firstFail.shrunk)
		sert.ok(lastFailingPair ~= nil)
		sert.eq((lastFailingPair :: { number })[1] + (lastFailingPair :: { number })[2], 50)
	end)
end)

sert.describe("shrinker O(log N) convergence and float/int boundary invariants", function()
	sert.test("shrinks a >=200-element failing list to minimal 3-element counterexample in <= 25 tries", function()
		local chosenSeed: number? = nil
		for candidateSeed = 1, 200 do
			local sample = gen.sample(gen.list(gen.int(0, 1000), 0, 400), candidateSeed, 400)
			if #sample >= 200 then
				chosenSeed = candidateSeed
				break
			end
		end
		sert.ok(chosenSeed ~= nil, "expected a seed producing an initial list of >= 200 elements")

		local firstSeenLen = 0
		local lastFailedList: { number } = {}
		local res = sert.prop.run("log-n list shrink", function(g)
			local arr = g:draw(gen.list(gen.int(0, 1000), 0, 400))
			if firstSeenLen == 0 then firstSeenLen = #arr end
			if #arr >= 3 then
				lastFailedList = arr
				sert.fail(`too many items: {#arr}`)
			end
		end, {
			size = 400,
			regressions = { chosenSeed :: number },
			runs = 1,
			shrinkBudget = { tries = 25, seconds = 2 },
		})

		sert.eq(res.ok, false)
		sert.ge(firstSeenLen, 200)
		sert.le(res.attempts, 25)
		sert.eq(#lastFailedList, 3)

		-- With default shrink budget, elements also converge to { 0, 0, 0 }.
		local convergedList: { number } = {}
		local fullRes = sert.prop.run("log-n list full shrink", function(g)
			local arr = g:draw(gen.list(gen.int(0, 1000), 0, 400))
			if #arr >= 3 then
				convergedList = arr
				sert.fail(`too many items: {#arr}`)
			end
		end, {
			size = 400,
			regressions = { chosenSeed :: number },
			runs = 1,
		})
		sert.eq(fullRes.ok, false)
		sert.eq(convergedList, { 0, 0, 0 })
	end)

	sert.test("gen.float covers full negative intervals and shrinks special-enabled floats to +0.0 first", function()
		local sawLowerHalf = false
		local sawUpperHalf = false
		local res = sert.prop.run("negative float coverage", function(g)
			local f = g:draw(gen.float(-5, -1))
			sert.ge(f, -5)
			sert.le(f, -1)
			if f < -3 then
				sawLowerHalf = true
			else
				sawUpperHalf = true
			end
		end, { runs = 150, seed = 99 })
		sert.eq(res.ok, true)
		sert.ok(sawLowerHalf, "expected gen.float(-5, -1) to sample values < -3")
		sert.ok(sawUpperHalf, "expected gen.float(-5, -1) to sample values >= -3")

		local lastNegShrink = 0
		local negShrink = sert.prop.run("negative float shrink origin", function(g)
			local f = g:draw(gen.float(-5, -1))
			lastNegShrink = f
			sert.fail("shrink negative float")
		end, { runs = 10, seed = 77 })
		sert.eq(negShrink.ok, false)
		sert.eq(lastNegShrink, -1)

		local specialFloatGen = gen.float(-100, 100, { nan = true, inf = true, negZero = true })
		local widthZero = #propCore.tape((function()
			local g = propCore.gen(1, 40, { 0, 0, 0 })
			g:draw(specialFloatGen)
			return g
		end)())
		local widthNan = #propCore.tape((function()
			local g = propCore.gen(1, 40, { 4, 0, 0 })
			g:draw(specialFloatGen)
			return g
		end)())
		sert.eq(widthZero, widthNan)

		local lastSpecialFloat: number = 999
		local shrinkSpecial = sert.prop.run("float special shrinks to +0.0", function(g)
			local f = g:draw(specialFloatGen)
			lastSpecialFloat = f
			sert.fail("always fail")
		end, { runs = 20, seed = 11 })
		sert.eq(shrinkSpecial.ok, false)
		sert.eq(lastSpecialFloat, 0.0)
		sert.eq(1 / lastSpecialFloat, math.huge)
	end)

	sert.test("gen.boundaryFloat shrinks finite 0.0 before NaN/Inf and preserves downstream alignment", function()
		local lastBoundary: number = 123
		local lastDownstream: number = -1
		local bFloat = gen.boundaryFloat(-1000, 1000)

		local resAll = sert.prop.run("boundaryFloat finite-first", function(g)
			local x = g:draw(bFloat)
			local tail = g:draw(gen.int(50, 60))
			lastBoundary = x
			lastDownstream = tail
			sert.fail("fail on every float")
		end, { runs = 30, seed = 314 })

		sert.eq(resAll.ok, false)
		sert.eq(lastBoundary, 0.0)
		sert.eq(1 / lastBoundary, math.huge)
		sert.eq(lastDownstream, 50)

		local sawNonFinite = false
		for s = 1, 80 do
			local v = gen.sample(bFloat, s)
			if v ~= v or math.abs(v) == math.huge then
				sawNonFinite = true
				break
			end
		end
		sert.ok(sawNonFinite, "expected boundaryFloat to sample NaN or ±huge")
	end)

	sert.test("gen.boundaryInt shrinks tag-first toward 0 and enumerates bounded-exhaustively", function()
		local bInt = gen.boundaryInt()
		local lastInt = 999
		local shrinkZero = sert.prop.run("boundaryInt shrinks to 0", function(g)
			lastInt = g:draw(bInt)
			sert.fail("always fail")
		end, { runs = 20, seed = 19 })
		sert.eq(shrinkZero.ok, false)
		sert.eq(lastInt, 0)

		local lastLarge = 0
		local shrinkThreshold = sert.prop.run("boundaryInt hints into range", function(g)
			local n = g:draw(bInt)
			if n >= 100 then
				lastLarge = n
				sert.fail("too big")
			end
		end, { runs = 50, seed = 23 })
		sert.eq(shrinkThreshold.ok, false)
		sert.eq(lastLarge, 100)

		local exhRes = sert.prop.run("boundaryInt exhaustive", function(g)
			local n = g:draw(gen.boundaryInt(-1000000, 1000000))
			sert.eq(n, math.floor(n))
		end, { exhaustive = { size = 2 } }, { exhaustive = true, budget = 5 })
		sert.eq(exhRes.ok, true)
		sert.lt(exhRes.cases, 100)
	end)
end)

sert.describe("sert.gen combinators and datatype/adversarial generators", function()
	sert.test("exercises composite, collection, datatype, recursive, and adversarial generators", function()
		local res = sert.prop.run("all combinators", function(g)
			local customEven = gen.custom(function(inner) return inner:int(0, 10) * 2 end)
			sert.eq(g:draw(customEven) % 2, 0)
			sert.eq(g:draw(gen.constant("fixed")), "fixed")
			sert.eq(type(g:draw(gen.bool())), "boolean")
			sert.contains({ "x", "y", "z" }, g:draw(gen.pick({ "x", "y", "z" })))

			local one = g:draw(gen.oneOf({ gen.constant(1), gen.constant(2) }))
			sert.contains({ 1, 2 }, one)

			local freq = g:draw(gen.frequency({ { 1, gen.constant("a") }, { 3, gen.constant("b") } }))
			sert.contains({ "a", "b" }, freq)

			local opt = g:draw(gen.optional(gen.int(1, 5)))
			if opt ~= nil then sert.ge(opt, 1) end

			local uniq = g:draw(gen.uniqueList(gen.int(1, 6), 2, 4))
			sert.ge(#uniq, 2)
			sert.ne(uniq[1], uniq[2])

			local rec = g:draw(gen.record({ id = gen.int(1, 9), tag = "const" }))
			sert.eq(rec.tag, "const")
			sert.ge(rec.id, 1)

			local dict = g:draw(gen.dict(gen.string("ab", 1, 2), gen.int(0, 3), 0, 3))
			sert.eq(type(dict), "table")

			local tup = g:draw(gen.tuple(gen.int(1, 2), gen.bool()))
			sert.eq(#tup, 2)

			local mapped = g:draw(gen.map(gen.int(1, 5), function(n: number): number return n * 3 end))
			sert.eq(mapped % 3, 0)

			local bound =
				g:draw(gen.bind(gen.int(1, 3), function(n: number) return gen.list(gen.constant(n), n, n) end))
			sert.eq(#bound, bound[1])

			local filtered = g:draw(gen.filter(gen.int(0, 20), function(n: number): boolean return n >= 5 end))
			sert.ge(filtered, 5)

			local u8 = g:draw(gen.utf8(0, 6))
			sert.ok(utf8.len(u8) ~= nil)

			local setTbl = g:draw(gen.set(gen.int(1, 5), 1, 3))
			sert.eq(type(setTbl), "table")

			local shuf = g:draw(gen.shuffle({ 1, 2, 3 }))
			sert.eq(#shuf, 3)

			local sub = g:draw(gen.subset({ "a", "b", "c", "d" }, 1, 3))
			sert.ge(#sub, 1)
			sert.le(#sub, 3)

			local tree = gen.recursive(gen.int(0, 5), function(child) return gen.list(child, 0, 2) :: any end, 2)
			local lazyTree = gen.lazy(function() return tree end)
			sert.ok(g:draw(lazyTree) ~= nil)

			sert.eq(sert.env.typeof(g:draw(gen.vector2())), "Vector2")
			sert.eq(sert.env.typeof(g:draw(gen.vector3())), "Vector3")
			sert.eq(sert.env.typeof(g:draw(gen.color3())), "Color3")
			sert.eq(sert.env.typeof(g:draw(gen.udim())), "UDim")
			sert.eq(sert.env.typeof(g:draw(gen.udim2())), "UDim2")
			sert.eq(sert.env.typeof(g:draw(gen.cframe())), "CFrame")
			sert.eq(sert.env.typeof(g:draw(gen.numberRange())), "NumberRange")
			sert.eq(sert.env.typeof(g:draw(gen.rect())), "Rect")
			sert.eq(sert.env.typeof(g:draw(gen.enum(sert.env.Enum.KeyCode))), "EnumItem")

			sert.ok(g:draw(gen.any(1)) ~= nil)
			sert.eq(type(g:draw(gen.malformedString())), "string")
			sert.eq(type(g:draw(gen.sparseTable())), "table")
			local _ = g:draw(gen.remotePayload(1))
			local _adv = g:draw(gen.adversarial(1))
		end, { runs = 15, seed = 101 })

		sert.eq(res.ok, true)
		sert.throws(function()
			local g = propCore.gen(1, 10)
			g:draw(gen.bool :: any)
		end, "gen.bool()")
	end)
end)
