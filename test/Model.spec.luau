--!strict
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

type QueueState = { items: { number }, closed: boolean }
type QueueSut = { buf: { number }, head: number, closed: boolean, buggyThreshold: number? }

local function makeQueueSpec(buggyThreshold: number?, teardowns: { number }?): sert.ModelSpec<QueueState, QueueSut>
	return {
		name = "bounded-queue",
		init = function(): QueueState return { items = {}, closed = false } end,
		setup = function(): QueueSut return { buf = {}, head = 1, closed = false, buggyThreshold = buggyThreshold } end,
		teardown = function(sut: QueueSut)
			sut.closed = true
			if teardowns ~= nil then
				teardowns[1] += 1
			end
		end,
		commands = {
			push = {
				weight = 3,
				gen = function(_state: QueueState, g: sert.GenContext): number return g:int(1, 20) end,
				pre = function(state: QueueState, _arg: number): boolean return #state.items < 8 end,
				run = function(sut: QueueSut, val: number): number
					table.insert(sut.buf, val)
					local count = #sut.buf - sut.head + 1
					if sut.buggyThreshold ~= nil and count >= sut.buggyThreshold and val >= 10 then
						-- Inject subtle bug: drop oldest element when threshold is hit with val >= 10.
						sut.head += 1
					end
					return #sut.buf - sut.head + 1
				end,
				next = function(state: QueueState, val: number): QueueState?
					local nextItems = table.clone(state.items)
					table.insert(nextItems, val)
					return { items = nextItems, closed = state.closed }
				end,
				post = function(state: QueueState, _sut: QueueSut, _val: number, res: number)
					sert.eq(res, #state.items)
				end,
			},
			pop = {
				weight = 2,
				pre = function(state: QueueState): boolean return #state.items > 0 end,
				run = function(sut: QueueSut): number?
					if sut.head > #sut.buf then return nil end
					local v = sut.buf[sut.head]
					sut.head += 1
					return v
				end,
				next = function(state: QueueState): QueueState?
					local nextItems = table.clone(state.items)
					table.remove(nextItems, 1)
					return { items = nextItems, closed = state.closed }
				end,
				post = function(_state: QueueState, _sut: QueueSut, _arg: any, res: number?) sert.ok(res ~= nil) end,
			},
			peekAt = {
				weight = 1,
				gen = function(state: QueueState, g: sert.GenContext): number
					return if #state.items == 0 then 1 else g:int(1, #state.items)
				end,
				pre = function(state: QueueState, idx: number): boolean return idx >= 1 and idx <= #state.items end,
				run = function(sut: QueueSut, idx: number): number? return sut.buf[sut.head + idx - 1] end,
				post = function(state: QueueState, _sut: QueueSut, idx: number, res: number?)
					sert.eq(res, state.items[idx])
				end,
			},
		},
		invariants = {
			lengthMatches = function(state: QueueState, sut: QueueSut) sert.eq(#sut.buf - sut.head + 1, #state.items) end,
			elementsMatch = function(state: QueueState, sut: QueueSut): boolean
				for i, expected in state.items do
					if sut.buf[sut.head + i - 1] ~= expected then return false end
				end
				return true
			end,
		},
	}
end

sert.describe("sert.model unified Spec<State, Sut>", function()
	sert.test("passes healthy stateful queue model via sert.model, model.prop, and model.check", function()
		local teardowns = { 0 }
		local spec = makeQueueSpec(nil, teardowns)

		local checkRes = sert.model.check(spec, { runs = 25, length = 20, seed = 101 })
		sert.eq(checkRes.ok, true)
		sert.eq(teardowns[1], 25)

		local isoRes = runIsolated(function()
			sert.model("callable model", spec, { runs = 5, length = 10 })
			sert.model(spec, { runs = 3, length = 8 })
			sert.model.prop("prop alias", spec, { runs = 4, length = 8 })
			sert.model.prop.skip("skipped model", spec)
			sert.model.prop.roblox("roblox model", spec, { runs = 2 })
			sert.model.prop.server("server model", spec, { runs = 2 })
			sert.model.prop.client("client model", spec, { runs = 2 })
		end)

		sert.eq(isoRes.failed, 0)
		sert.eq(isoRes.passed, 3)
		if not sert.isRoblox then sert.eq(isoRes.skippedRoblox, 3) end
	end)

	sert.test(
		"redraw = true adapts past disabled preconditions while shrinking to minimal sequence + seed replay",
		function()
			local teardowns = { 0 }
			local buggy = makeQueueSpec(3, teardowns)

			local res = sert.model.check(buggy, {
				runs = 60,
				length = 25,
				seed = 4242,
				raise = false,
			})

			sert.eq(res.ok, false)
			sert.ok(res.seed ~= nil)
			sert.ok(res.notes ~= nil)
			-- Minimal bug trigger requires exactly 3 pushes (with the 3rd push == 10)!
			local traceNotes = res.notes :: { string }
			sert.eq(#traceNotes, 3)
			sert.contains(traceNotes[3], '"push", 10')
			sert.gt(teardowns[1], 0)

			local replayRes = sert.model.check(buggy, {
				length = 25,
				seed = 4242,
				replay = res.seed,
				raise = false,
			})
			sert.eq(replayRes.ok, false)
			sert.eq(replayRes.notes, res.notes)

			-- Verify redraw = true overcomes a heavy-weight disabled command (`drain` weight 50 vs `inc` weight 1).
			local maxReached = 0
			local heavyPreSpec: sert.ModelSpec<{ n: number }, { n: number }> = {
				init = function() return { n = 0 } end,
				commands = {
					drain = {
						weight = 50,
						pre = function(s) return s.n >= 3 end,
						run = function(sut) sut.n = 0 end,
						next = function(s) s.n = 0 end,
					},
					inc = {
						weight = 1,
						gen = gen.int(1, 2),
						run = function(sut, d: number)
							sut.n += d
							if sut.n > maxReached then maxReached = sut.n end
						end,
						next = function(s, d: number)
							s.n += d
						end,
					},
				},
			}
			local redrawRes = sert.model.check(heavyPreSpec, { runs = 15, length = 10, seed = 9 })
			sert.eq(redrawRes.ok, true)
			sert.ge(maxReached, 3)
		end
	)

	sert.test("model.replay executes tuple and named traces, validates pre, and preserves teardown errors", function()
		local teardowns = { 0 }
		local spec = makeQueueSpec(nil, teardowns)

		local finalState, finalSut = sert.model.replay(spec, {
			{ "push", 5 },
			{ command = "push", arg = 9 },
			{ name = "peekAt", arg = 2 },
			{ "pop" },
		})
		sert.eq(finalState.items, { 9 })
		sert.eq(finalSut.closed, true)
		sert.eq(teardowns[1], 1)

		sert.throws(function() sert.model.replay(spec, { { "pop" } }) end, "pre refused")

		sert.throws(function() sert.model.replay(spec, { { "nonexistent", 1 } }) end, "no command named")

		local dualFailSpec: sert.ModelSpec<{ x: number }, { x: number }> = {
			init = function() return { x = 0 } end,
			teardown = function() error("model teardown explosion", 0) end,
			commands = {
				boom = {
					run = function() error("model command explosion", 0) end,
					next = function() end,
				},
			},
		}
		local dualErr = sert.throws(function() sert.model.replay(dualFailSpec, { { "boom" } }) end)
		sert.contains(dualErr, "model command explosion")
		sert.contains(dualErr, "model teardown explosion")

		-- Spec & command normalization validation guards + array-form commands with discrete `gen` array
		local checkAny: any = sert.model.check
		sert.throws(function() checkAny("not-a-table") end, "expected a spec table")
		sert.throws(function()
			checkAny({ init = function() return 0 end, runs = 5, commands = {} })
		end, "an option")
		sert.throws(function() checkAny({ init = 123, commands = {} }) end, "spec.init must be a function")
		sert.throws(function()
			checkAny({ init = function() return 0 end, setup = 1, commands = {} })
		end, "spec.setup")
		sert.throws(function()
			checkAny({ init = function() return 0 end, teardown = 1, commands = {} })
		end, "spec.teardown")
		sert.throws(function()
			checkAny({ init = function() return 0 end, invariants = 1, commands = {} })
		end, "spec.invariants")
		sert.throws(function()
			checkAny({ init = function() return 0 end, commands = { bad = "str" } })
		end, "must be a table")
		sert.throws(function()
			checkAny({ init = function() return 0 end, commands = { { next = function() end } } })
		end, "has no name")
		sert.throws(function()
			checkAny({ init = function() return 0 end, commands = { c = { bogus = 1, next = function() end } } })
		end, "unknown field")
		sert.throws(function()
			checkAny({ init = function() return 0 end, commands = { c = { gen = {}, next = function() end } } })
		end, "cannot be empty")
		local arrRes = checkAny({
			init = function() return 0 end,
			commands = {
				{
					name = "add",
					gen = { 1, 2, 3 },
					run = function(_sut: any, n: number) return n end,
					next = function(s: number, n: number) return s + n end,
				},
			},
		}, { runs = 5, length = 4 })
		sert.eq(arrRes.ok, true)
	end)
end)
