--!strict
local corpus = require("../src/prop/corpus")
local format = require("../src/core/format")
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

		local firstFail: any
		local lastFailingPair: { number }? = nil
		local replayRes: any
		sert.capture(function()
			firstFail = sert.prop.run("replayable failure", function(g)
				local a = g:draw(gen.int(0, 100))
				local b = g:draw(gen.int(0, 100))
				g:note("pair=%d,%d", a, b)
				sert.lt(a + b, 50)
			end, { runs = 50, seed = 2026 })
			sert.eq(firstFail.ok, false)
			sert.ok(firstFail.seed ~= nil)

			replayRes = sert.prop.run("replayable failure", function(g)
				local a = g:draw(gen.int(0, 100))
				local b = g:draw(gen.int(0, 100))
				if a + b >= 50 then lastFailingPair = { a, b } end
				sert.lt(a + b, 50)
			end, { runs = 50, seed = 2026 }, { replay = firstFail.seed })
		end)
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
		local res: any
		local convergedList: { number } = {}
		local fullRes: any
		sert.capture(function()
			res = sert.prop.run("log-n list shrink", function(g)
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

			-- With default shrink budget, elements also converge to { 0, 0, 0 }.
			fullRes = sert.prop.run("log-n list full shrink", function(g)
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
		end)

		sert.eq(res.ok, false)
		sert.ge(firstSeenLen, 200)
		sert.le(res.attempts, 25)
		sert.eq(#lastFailedList, 3)

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
		local negShrink: any
		sert.capture(function()
			negShrink = sert.prop.run("negative float shrink origin", function(g)
				local f = g:draw(gen.float(-5, -1))
				lastNegShrink = f
				sert.fail("shrink negative float")
			end, { runs = 10, seed = 77 })
		end)
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
		local shrinkSpecial: any
		sert.capture(function()
			shrinkSpecial = sert.prop.run("float special shrinks to +0.0", function(g)
				local f = g:draw(specialFloatGen)
				lastSpecialFloat = f
				sert.fail("always fail")
			end, { runs = 20, seed = 11 })
		end)
		sert.eq(shrinkSpecial.ok, false)
		sert.eq(lastSpecialFloat, 0.0)
		sert.eq(1 / lastSpecialFloat, math.huge)
	end)

	sert.test("gen.boundaryFloat shrinks finite 0.0 before NaN/Inf and preserves downstream alignment", function()
		local lastBoundary: number = 123
		local lastDownstream: number = -1
		local bFloat = gen.boundaryFloat(-1000, 1000)

		local resAll: any
		sert.capture(function()
			resAll = sert.prop.run("boundaryFloat finite-first", function(g)
				local x = g:draw(bFloat)
				local tail = g:draw(gen.int(50, 60))
				lastBoundary = x
				lastDownstream = tail
				sert.fail("fail on every float")
			end, { runs = 30, seed = 314 })
		end)

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
		local shrinkZero: any
		local lastLarge = 0
		local shrinkThreshold: any
		sert.capture(function()
			shrinkZero = sert.prop.run("boundaryInt shrinks to 0", function(g)
				lastInt = g:draw(bInt)
				sert.fail("always fail")
			end, { runs = 20, seed = 19 })
			shrinkThreshold = sert.prop.run("boundaryInt hints into range", function(g)
				local n = g:draw(bInt)
				if n >= 100 then
					lastLarge = n
					sert.fail("too big")
				end
			end, { runs = 50, seed = 23 })
		end)
		sert.eq(shrinkZero.ok, false)
		sert.eq(lastInt, 0)
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

sert.describe("corpus codec, target/classify/cover, v1 regressions, markers, and __SERT_FUZZ", function()
	sert.test("corpus encode, decode, and parseReplay roundtrip u32 tapes and reject invalid inputs", function()
		local emptyTok = corpus.encode(42, 40, {})
		sert.eq(emptyTok, "v1:42:40:")
		local es, ez, et = corpus.decode(emptyTok)
		sert.eq(es, 42)
		sert.eq(ez, 40)
		sert.eq(et, {})

		local entries = { 0, 1, 255, 0x12345678, 0xFFFFFFFF }
		local tok = corpus.encode(0, 12, entries)
		sert.eq(tok, "v1:0:12:0000000000000001000000ff12345678ffffffff")
		local ds, dz, dt = corpus.decode(tok)
		sert.eq(ds, 0)
		sert.eq(dz, 12)
		sert.eq(dt, entries)

		local negTok = corpus.encode(-7, 0, { 9 })
		local ns, nz, nt = corpus.decode(negTok)
		sert.eq(ns, -7)
		sert.eq(nz, 0)
		sert.eq(nt, { 9 })

		for _, bad in { "", "v2:1:2:", "v1:abc:10:00000000", "v1:1:-1:", "v1:1:10:123", "v1:1:10:zzzzzzzz" } do
			local rs, rz, rt = corpus.decode(bad)
			sert.eq(rs, nil)
			sert.eq(rz, nil)
			sert.eq(rt, nil)
			sert.eq(corpus.parseReplay(bad), nil)
		end

		sert.eq(corpus.parseReplay(nil), nil)
		sert.eq(corpus.parseReplay(99), { kind = "seed", seed = 99 })
		sert.eq(corpus.parseReplay("99"), { kind = "seed", seed = 99 })
		sert.eq(corpus.parseReplay(tok), { kind = "tape", seed = 0, size = 12, tape = entries })

		sert.throws(function() corpus.encode(1.5, 10, {}) end, "finite integer")
		sert.throws(function() corpus.encode(1, -1, {}) end, "non-negative integer")
		sert.throws(function() corpus.encode(1, 10, { -1 }) end, "u32")
		sert.throws(function() corpus.encode(1, 10, { 2 ^ 32 }) end, "u32")
	end)

	sert.test("emits [sert-x:regression], includes replay = token, and replays v1 regressions", function()
		local failCaptured = sert.capture(function()
			local res = runIsolated(function()
				sert.prop("v1 token failure", function(g: sert.Gen)
					local a = g:int(0, 100)
					local b = g:int(0, 100)
					if a + b >= 80 then sert.fail(`sum={a + b}`) end
				end, { runs = 60, seed = 1337 })
			end, { markers = true, quiet = false })
			sert.eq(res.failed, 1)
			local rep = res.failures[1]
			local tok = string.match(rep, 'replay = "(v1:[^"]+)"')
			sert.ok(tok ~= nil, `expected replay = "v1:..." in failure report:\n{rep}`)
			sert.contains(rep, `--replay={tok}`)
		end)

		local markerLine: string? = nil
		for _, line in failCaptured do
			local jsonStr = string.match(line, "^%[sert%-x:regression%]%s*(.+)$")
			if jsonStr ~= nil then
				markerLine = jsonStr
				break
			end
		end
		sert.ok(markerLine ~= nil, "expected [sert-x:regression] marker on property failure")
		local payload = format.jsonDecode(markerLine :: string) :: { [string]: any }
		sert.eq(payload.name, "v1 token failure")
		sert.eq(type(payload.seed), "number")
		local rSeed, rSize, rTape = corpus.decode(payload.token)
		sert.eq(rSeed, payload.seed)
		sert.ok(rTape ~= nil and #rTape >= 2 and rSize == 40)

		-- Replay exact v1 token in 1 trial
		local replayRuns = 0
		local replayRes: any
		sert.capture(function()
			replayRes = sert.prop.run("v1 token failure", function(g: sert.Gen)
				replayRuns += 1
				local a = g:int(0, 100)
				local b = g:int(0, 100)
				if a + b >= 80 then sert.fail(`sum={a + b}`) end
			end, { runs = 60, seed = 1337 }, { replay = payload.token })
		end)
		sert.eq(replayRes.ok, false)
		sert.eq(replayRes.cases, 1)
		sert.eq(replayRuns, 1)
		sert.eq(replayRes.replay, payload.token)

		sert.throws(function()
			sert.prop.run("bad replay", function(g: sert.Gen) sert.ge(g:int(0, 10), 0) end, nil, {
				replay = "v1:bad:token",
			})
		end, "malformed replay token")

		-- v1 token in PropOptions.regressions, RunOptions.regressions[fullName/shortName], and __SERT_REGRESSIONS
		local runOrder: { number } = {}
		local regRes: any
		sert.capture(function()
			regRes = sert.prop.run("v1 reg check", function(g: sert.Gen)
				local a = g:int(0, 100)
				local b = g:int(0, 100)
				table.insert(runOrder, a + b)
				sert.lt(a + b, 80)
			end, {
				regressions = { payload.token },
				runs = 5,
			})
		end)
		sert.eq(regRes.ok, false)
		sert.eq(regRes.cases, 1)
		sert.ge(runOrder[1], 80)

		local autoRes = runIsolated(function()
			sert.describe("suite", function()
				sert.prop("auto reg target", function(g: sert.Gen)
					local a = g:int(0, 100)
					local b = g:int(0, 100)
					sert.lt(a + b, 80)
				end, { runs = 5, seed = 1 })
			end)
		end, {
			regressions = { ["auto reg target"] = { payload.token } },
		})
		sert.eq(autoRes.failed, 1)

		local prevShared = rawget(registry.mutant._sharedG, "__SERT_REGRESSIONS")
		rawset(registry.mutant._sharedG, "__SERT_REGRESSIONS", {
			["shared reg prop"] = { payload.token },
		})
		local sharedOk, sharedRes = pcall(function()
			return runIsolated(function()
				sert.prop("shared reg prop", function(g: sert.Gen)
					local a = g:int(0, 100)
					local b = g:int(0, 100)
					sert.lt(a + b, 80)
				end, { runs = 5, seed = 1 })
			end)
		end)
		rawset(registry.mutant._sharedG, "__SERT_REGRESSIONS", prevShared)
		sert.ok(sharedOk)
		sert.eq((sharedRes :: sert.Results).failed, 1)
	end)

	sert.test("g:classify records non-discarded distributions and prints on verbose pass or failure", function()
		local verboseOut = sert.capture(function()
			local res = sert.prop.run("classify pass", function(g: sert.Gen)
				local x = g:int(-10, 10)
				g:assume(x ~= 0, "non-zero")
				g:classify(x > 0, "positive")
				g:classify(x < 0, "negative")
				sert.ne(x, 0)
			end, { runs = 40, seed = 17 }, { quiet = false })
			sert.eq(res.ok, true)
		end)
		local outText = table.concat(verboseOut, "\n")
		sert.contains(outText, 'property "classify pass" classification (40 cases):')
		sert.contains(outText, "positive:")
		sert.contains(outText, "negative:")

		local failRes: any
		sert.capture(function()
			failRes = sert.prop.run("classify fail", function(g: sert.Gen)
				local x = g:int(1, 20)
				g:classify(x <= 10, "small")
				g:classify(x > 10, "large")
				sert.lt(x, 12)
			end, { runs = 50, seed = 9 })
		end)
		sert.eq(failRes.ok, false)
		sert.contains(failRes.report :: string, "classification:")
		sert.contains(failRes.report :: string, "small:")

		sert.throws(function()
			local g = propCore.gen(1, 10)
			g:classify(true, "")
		end, "non-empty string")
	end)

	sert.test("g:cover validates bounds, uses 99% Wilson score check, and skips single --replay trial", function()
		sert.throws(function()
			local g = propCore.gen(1, 10)
			g:cover(-1, true, "bad")
		end, "[0, 100]")
		sert.throws(function()
			local g = propCore.gen(1, 10)
			g:cover(101, true, "bad")
		end, "[0, 100]")
		sert.throws(function()
			local g = propCore.gen(1, 10)
			g:cover(10, true, "")
		end, "non-empty string")

		-- Healthy ~50% distribution easily passes cover(25, ...)
		local passCov = sert.prop.run("healthy cover", function(g: sert.Gen)
			local b = g:bool(0.5)
			g:cover(25, b, "true-branch")
		end, { runs = 100, seed = 11 })
		sert.eq(passCov.ok, true)

		-- Weak 2/100 and 0/100 reliably fail cover(25, ...)
		local idxWeak = 0
		local failWeak = sert.prop.run("weak cover", function(g: sert.Gen)
			local _ = g:int(1, 5)
			idxWeak += 1
			g:cover(25, idxWeak <= 2, "rare")
		end, { runs = 100, seed = 1 })
		sert.eq(failWeak.ok, false)
		sert.contains(failWeak.message :: string, 'coverage check failed for "rare"')

		-- Boundary at N=100 for 25%: 16/100 passes (upper 0.262 >= 0.25), 14/100 fails (upper 0.239 < 0.25)
		local iPass = 0
		local boundaryPass = sert.prop.run("wilson 16/100", function(g: sert.Gen)
			local _ = g:int(1, 2)
			iPass += 1
			g:cover(25, iPass <= 16, "edge")
		end, { runs = 100, seed = 1 })
		sert.eq(boundaryPass.ok, true)

		local iFail = 0
		local boundaryFail = sert.prop.run("wilson 14/100", function(g: sert.Gen)
			local _ = g:int(1, 2)
			iFail += 1
			g:cover(25, iFail <= 14, "edge")
		end, { runs = 100, seed = 1 })
		sert.eq(boundaryFail.ok, false)
		sert.contains(boundaryFail.message :: string, "coverage check failed")

		-- Single --replay trial skips cover check
		local replaySkip = sert.prop.run("replay skips cover", function(g: sert.Gen)
			local _ = g:int(1, 2)
			g:cover(90, false, "impossible")
		end, { runs = 50, seed = 1 }, { replay = 123 })
		sert.eq(replaySkip.ok, true)
		sert.eq(replaySkip.cases, 1)
	end)

	sert.test("g:target climbs toward edge cases, ignores NaN, and hooks into __SERT_FUZZ", function()
		local seenScore = false
		local prevFuzz = rawget(registry.mutant._sharedG, "__SERT_FUZZ")
		local targetSpy: { [string]: any } = {
			maxScore = nil,
			targets = {},
			calls = 0,
			onTarget = function(_lbl: string, _score: number, _name: string) seenScore = true end,
		}
		rawset(registry.mutant._sharedG, "__SERT_FUZZ", targetSpy)

		local hitNeedle = false
		local climbOk, climbRes = pcall(function()
			local res: any
			sert.capture(function()
				res = sert.prop.run("targeted climb", function(g: sert.Gen)
					local a = g:int(0, 1000)
					local b = g:int(0, 1000)
					g:target(0 / 0, "nan-safe")
					g:target(-(math.abs(a - 777) + math.abs(b - 333)), "distance")
					if a == 777 and b == 333 then
						hitNeedle = true
						sert.fail("hit exact needle (777, 333)")
					end
				end, { runs = 500, seed = 42 })
			end)
			return res
		end)
		rawset(registry.mutant._sharedG, "__SERT_FUZZ", prevFuzz)

		sert.ok(climbOk)
		sert.eq((climbRes :: propCore.PropResult).ok, false)
		sert.eq(hitNeedle, true)
		sert.ok(seenScore, "expected onTarget callback to fire")
		sert.eq(targetSpy.targets["nan-safe"], nil)
		sert.ok(targetSpy.maxScore ~= nil and targetSpy.maxScore <= 0)

		-- Controller hook: __SERT_FUZZ.runProperty(ctx)
		local ctrlCalled = false
		local ctrlMetaName: string? = nil
		local ctrl: { [string]: any } = {
			runProperty = function(ctx: any)
				ctrlCalled = true
				ctrlMetaName = ctx.meta.name
				local t1 = ctx.trial({ 10 }, 9, 20)
				sert.eq(t1.ok, true)
				local tFail = ctx.trial({ 99 }, 9, 20)
				sert.eq(tFail.ok, false)
				return ctx.shrinkFn(tFail)
			end,
		}
		rawset(registry.mutant._sharedG, "__SERT_FUZZ", ctrl)
		local hookOk, hookRes = pcall(function()
			local res: any
			sert.capture(function()
				res = sert.prop.run("greybox prop", function(g: sert.Gen)
					local n = g:int(0, 100)
					sert.lt(n, 50)
				end, { runs = 10, seed = 7 })
			end)
			return res
		end)
		rawset(registry.mutant._sharedG, "__SERT_FUZZ", prevFuzz)
		sert.ok(hookOk)
		sert.eq(ctrlCalled, true)
		sert.eq(ctrlMetaName, "greybox prop")
		local fRes = hookRes :: propCore.PropResult
		sert.eq(fRes.ok, false)
		sert.ok(fRes.replay ~= nil)
		local _, _, sTape = corpus.decode(fRes.replay :: string)
		sert.eq(sTape, { 50 })
	end)

	sert.test("prop trials record 'prop' assertions for strictAssertions", function()
		local res = runIsolated(function()
			sert.prop("raw error prop counts as asserted", function(g: sert.Gen)
				local n = g:int(1, 10)
				if n < 0 then error("impossible", 0) end
			end, { runs = 5, seed = 1 })
		end, { strictAssertions = true })
		sert.eq(res.passed, 1)
		sert.eq(res.failed, 0)
	end)
end)
