--!strict
local format = require("../src/core/format")
local registry = require("../src/core/registry")
local sert = require("../src")

local function withIsolatedState(fn: () -> ())
	local sub = registry.newState()
	registry.isolateDepth += 1
	local ok, err = pcall(function() registry.withState(sub, fn) end)
	registry.isolateDepth -= 1
	if not ok then error(err, 0) end
end

sert.describe("allocation assertions (allocs, maxAllocs, noAllocs)", function()
	sert.test("measures zero vs heap allocations and records allocs assertions", function()
		local acc = 0
		local zeroKb = sert.allocs(function()
			for i = 1, 8 do
				acc += i
			end
		end)
		sert.le(zeroKb, 0.01)

		local sink: any = nil
		local allocKb = sert.allocs(function() sink = { a = 1, b = 2, c = { 3, 4, 5 } } end, 2, 32)
		sert.gt(allocKb, 0.05)

		local trackerBefore = (registry.activeTestAssertions() :: registry.AssertionTracker).count
		sert.noAllocs(function()
			acc += 1
		end)
		local measured = sert.maxAllocs(2.0, function() sink = { v = 1 } end)
		sert.ge(measured, 0)
		local _keep = sink
		local tracker = registry.activeTestAssertions() :: registry.AssertionTracker
		sert.eq(tracker.kinds["allocs"], 2)
		sert.ok(tracker.count >= trackerBefore + 2)
	end)

	sert.test("fails when exceeding maxAllocs/noAllocs budget and validates arguments", function()
		local leak: any = nil
		sert.throws(function()
			sert.noAllocs(function() leak = { 1, 2, 3, 4, 5 } end, "hot path")
		end, "hot path")
		sert.throws(function()
			sert.maxAllocs(0.001, function() leak = { 1, 2, 3, 4, 5 } end, "tight budget")
		end, "tight budget")
		local _keep = leak

		sert.throws(function() sert.allocs(123 :: any) end, "expected a function")
		sert.throws(function()
			sert.allocs(function() end, -1)
		end, "non-negative integer warmup")
		sert.throws(function()
			sert.allocs(function() end, 1, 0)
		end, "positive integer samples")
		sert.throws(function()
			sert.maxAllocs(-1, function() end)
		end, "non-negative maxKb")
		sert.throws(function() sert.maxAllocs(1, "nope" :: any) end, "expected a function")
		sert.throws(function() sert.noAllocs("nope" :: any) end, "expected a function")
	end)
end)

sert.describe("sert.bench and runner --bench", function()
	sert.test("does not run benchmarks in normal sert.run and executes them under bench = true", function()
		local ranBench = false
		local ranTest = false
		withIsolatedState(function()
			sert.test("normal test", function()
				ranTest = true
				sert.eq(ranTest, true)
			end)
			sert.bench("bench sum", function(b)
				ranBench = true
				local total = 0
				b:bytes(64)
				b:iter(function()
					b:stopTimer()
					local n = 10
					b:startTimer()
					for i = 1, n do
						total += i
					end
				end)
				local _keep = total
			end, { iterations = 50, samples = 5, warmup = 1 })

			sert.bench("bench manual", function(_b)
				local x = 1 + 2
				local _keep = x
			end, { samples = 4 })

			sert.bench("bench skipped", function() error("should not run", 0) end, { skip = true })

			local normalRes = sert.run({ quiet = true, raise = false })
			sert.eq(normalRes.passed, 1)
			sert.eq(ranTest, true)
			sert.eq(ranBench, false)

			local captured = sert.capture(function()
				local benchRes = sert.run({ bench = true, quiet = true, raise = false })
				sert.eq(benchRes.failed, 0)
			end)
			sert.eq(ranBench, true)

			local benchEvents: { { [string]: any } } = {}
			for _, line in captured do
				local payload = string.match(line, "^%[sert%-x:bench%] (.+)$")
				if payload ~= nil then table.insert(benchEvents, format.jsonDecode(payload)) end
			end
			sert.eq(#benchEvents, 2)
			sert.eq(benchEvents[1].name, "bench sum")
			sert.contains(benchEvents[1].file, "Perf")
			sert.eq(benchEvents[1].iterations, 50)
			sert.eq(benchEvents[1].samples, 5)
			sert.ge(benchEvents[1].medianNs, 0)
			sert.ge(benchEvents[1].iqrNs, 0)
			sert.ge(benchEvents[1].opsPerSec, 0)
			sert.ge(benchEvents[1].allocKb, 0)
			sert.eq(benchEvents[1].bytes, 64)
			sert.eq(benchEvents[2].name, "bench manual")
		end)
	end)

	sert.test("supports bench-only runs, error reporting, and rejects registration inside a test", function()
		sert.throws(function()
			sert.bench("nested", function() end)
		end, "cannot register a new benchmark")

		local captured = sert.capture(function()
			withIsolatedState(function()
				sert.bench("only bench", function(b)
					local acc = 0
					b:iter(function()
						acc += 1
					end)
					local _keep = acc
				end, { samples = 3 })
				sert.bench("broken bench", function() error("bench crashed", 0) end, { samples = 2 })
				local res = sert.run({ bench = true, quiet = true, raise = false })
				sert.eq(res.failed, 1)
				sert.contains(res.failures[1], "bench broken bench")
				sert.contains(res.failures[1], "bench crashed")
			end)
		end)

		local foundOnly = false
		for _, line in captured do
			if string.find(line, '"name":"only bench"', 1, true) ~= nil then foundOnly = true end
		end
		sert.ok(foundOnly)
	end)
end)
