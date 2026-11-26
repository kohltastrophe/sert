--!strict
-- Tests for Wing & Gong / Porcupine concurrent history linearizability checker and monotonic recorder.

local SimMod = require("../src/sim")
local registry = require("../src/core/registry")
local sert = require("../src")

local describe = sert.describe
local test = sert.test
local Sim = sert.sim

type KvState = { [string]: any }
type KvArg = { key: string, value: any? }

local function makeKvModel(useHash: boolean?, usePartition: boolean?): SimMod.SequentialModel<KvState, KvArg, any>
	local model: SimMod.SequentialModel<KvState, KvArg, any> = {
		init = function(): KvState return {} end,
		step = function(state: KvState, op: string, arg: KvArg, res: any): (boolean, KvState)
			if op == "put" then
				if res ~= true then return false, state end
				local nextState = table.clone(state)
				nextState[arg.key] = arg.value
				return true, nextState
			elseif op == "get" then
				return state[arg.key] == res, state
			end
			return false, state
		end,
	}
	if useHash then
		model.hash = function(state: KvState): string
			local keys: { string } = {}
			for k in state do
				table.insert(keys, k)
			end
			table.sort(keys)
			local parts: { string } = {}
			for _, k in keys do
				table.insert(parts, `{k}={tostring(state[k])}`)
			end
			return table.concat(parts, ";")
		end
	end
	if usePartition then model.partition = function(op: SimMod.Operation<KvArg, any>): string return op.arg.key end end
	return model
end

local counterModel: SimMod.SequentialModel<number, number, number> = {
	init = function(): number return 0 end,
	step = function(count: number, op: string, delta: number, res: number): (boolean, number)
		if op == "inc" then
			local nextCount = count + delta
			return res == nextCount, nextCount
		elseif op == "get" then
			return res == count, count
		end
		return false, count
	end,
	hash = function(count: number): number return count end,
}

describe("Linearize concurrent history checker", function()
	test("validates model/history inputs and accepts empty or overlapping linearizable histories", function()
		local kv = makeKvModel(true, false)

		local emptyRes = Sim.checkLinearizable(kv, {})
		sert.eq(emptyRes.ok, true)

		local validHistory: { SimMod.Operation<KvArg, any> } = {
			{ proc = "p1", op = "put", arg = { key = "x", value = 1 }, res = true, callAt = 0, retAt = 4 },
			{ proc = "p2", op = "put", arg = { key = "x", value = 2 }, res = true, callAt = 1, retAt = 5 },
			{ proc = "p3", op = "get", arg = { key = "x" }, res = 1, callAt = 2, retAt = 6 },
			{ proc = "p4", op = "get", arg = { key = "x" }, res = 2, callAt = 5, retAt = 8 },
		}
		local res = Sim.linearizable(kv, validHistory, "concurrent kv register")
		sert.eq(res.ok, true)
		sert.eq(res.conflicts, nil)

		-- Concurrent instantaneous point intervals [5, 5] do not block each other.
		local pointCounterHistory: { SimMod.Operation<number, number> } = {
			{ proc = 1, op = "inc", arg = 1, res = 2, callAt = 5, retAt = 5 },
			{ proc = 2, op = "inc", arg = 1, res = 1, callAt = 5, retAt = 5 },
			{ proc = 3, op = "get", arg = 0, res = 2, callAt = 6, retAt = 7 },
		}
		sert.eq(Sim.checkLinearizable(counterModel, pointCounterHistory).ok, true)

		-- Input validation catches malformed models, empty op names, and inverted intervals.
		sert.throws(function() Sim.checkLinearizable(nil :: any, {}) end, "expected model table")
		sert.throws(function()
			Sim.checkLinearizable({ step = function() return true, {} end } :: any, {})
		end, "model.init")
		sert.throws(function()
			Sim.checkLinearizable({ init = function() return {} end } :: any, {})
		end, "model.step")
		sert.throws(
			function() Sim.checkLinearizable({ init = kv.init, step = kv.step, hash = 123 :: any }, {}) end,
			"model.hash"
		)
		sert.throws(
			function() Sim.checkLinearizable({ init = kv.init, step = kv.step, partition = 123 :: any }, {}) end,
			"model.partition"
		)
		sert.throws(function() Sim.checkLinearizable(kv, nil :: any) end, "expected history array")
		sert.throws(function() Sim.checkLinearizable(kv, { "bad-entry" :: any }) end, "Operation table")
		sert.throws(
			function()
				Sim.checkLinearizable(
					kv,
					{ { proc = "p1", op = "", arg = { key = "x" }, res = nil, callAt = 0, retAt = 1 } }
				)
			end,
			"non-empty string"
		)
		sert.throws(
			function()
				Sim.checkLinearizable(
					kv,
					{ { proc = "p1", op = "get", arg = { key = "x" }, res = nil, callAt = 5, retAt = 2 } }
				)
			end,
			"callAt (5) > retAt (2)"
		)
		sert.throws(
			function()
				Sim.checkLinearizable(
					kv,
					{ { proc = true :: any, op = "get", arg = { key = "x" }, res = nil, callAt = 0, retAt = 1 } }
				)
			end,
			"proc"
		)
		sert.throws(
			function()
				Sim.checkLinearizable(
					kv,
					{ { proc = 1, op = "get", arg = { key = "x" }, res = nil, callAt = 0 / 0, retAt = 1 } }
				)
			end,
			"callAt"
		)
		sert.throws(
			function()
				Sim.checkLinearizable(
					kv,
					{ { proc = 1, op = "get", arg = { key = "x" }, res = nil, callAt = 0, retAt = math.huge } }
				)
			end,
			"retAt"
		)
	end)

	test("supports DFS backtracking with state cloning, mutating models, and >32-op bitset signatures", function()
		-- FIFO queue model mutates `state` table directly and omits `hash` to exercise structural `Spec.canonicalize`.
		local queueModel: SimMod.SequentialModel<{ number }, number, any> = {
			init = function(): { number } return {} end,
			step = function(q: { number }, op: string, arg: number, res: any): (boolean, { number })
				if op == "enq" then
					table.insert(q, arg)
					return res == true, q
				elseif op == "deq" then
					if #q == 0 then return res == nil, q end
					local front = table.remove(q, 1)
					return res == front, q
				end
				return false, q
			end,
		}

		local queueHistory: { SimMod.Operation<number, any> } = {
			{ proc = "w1", op = "enq", arg = 10, res = true, callAt = 0, retAt = 4 },
			{ proc = "w2", op = "enq", arg = 20, res = true, callAt = 1, retAt = 5 },
			{ proc = "r1", op = "deq", arg = 0, res = 20, callAt = 2, retAt = 6 },
			{ proc = "r2", op = "deq", arg = 0, res = 10, callAt = 6, retAt = 8 },
		}
		sert.eq(Sim.checkLinearizable(queueModel, queueHistory).ok, true)

		-- Single-partition history with 38 operations (> 32 bits) exercising multi-word bitsets.
		local bigHistory: { SimMod.Operation<number, number> } = {}
		for i = 1, 38, 2 do
			local baseT = i
			-- Adjacent overlapping pairs linearize in reverse order `(i + 1) -> (i)`.
			table.insert(
				bigHistory,
				{ proc = "A", op = "inc", arg = 1, res = i + 1, callAt = baseT, retAt = baseT + 1.5 }
			)
			table.insert(
				bigHistory,
				{ proc = "B", op = "inc", arg = 1, res = i, callAt = baseT + 0.2, retAt = baseT + 1.4 }
			)
		end
		sert.eq(Sim.checkLinearizable(counterModel, bigHistory).ok, true)
	end)

	test("scales cleanly to 40+ operations with model.partition and isolates partition failures", function()
		local kvPartitioned = makeKvModel(false, true)
		local history: { SimMod.Operation<KvArg, any> } = {}
		local keys = { "alpha", "beta", "gamma", "delta", "epsilon", "zeta", "eta", "theta" }
		for idx, k in keys do
			local base = (idx - 1) * 10
			table.insert(history, {
				proc = "w1",
				op = "put",
				arg = { key = k, value = idx * 10 },
				res = true,
				callAt = base,
				retAt = base + 3,
			})
			table.insert(history, {
				proc = "r1",
				op = "get",
				arg = { key = k },
				res = idx * 10,
				callAt = base + 4,
				retAt = base + 5,
			})
			table.insert(history, {
				proc = "w2",
				op = "put",
				arg = { key = k, value = idx * 10 + 1 },
				res = true,
				callAt = base + 4,
				retAt = base + 8,
			})
			table.insert(history, {
				proc = "r2",
				op = "get",
				arg = { key = k },
				res = idx * 10 + 1,
				callAt = base + 9,
				retAt = base + 10,
			})
			table.insert(history, {
				proc = "w3",
				op = "put",
				arg = { key = k, value = idx * 10 + 2 },
				res = true,
				callAt = base + 11,
				retAt = base + 14,
			})
			table.insert(history, {
				proc = "r3",
				op = "get",
				arg = { key = k },
				res = idx * 10 + 2,
				callAt = base + 15,
				retAt = base + 16,
			})
		end
		sert.eq(#history, 48)
		sert.eq(Sim.checkLinearizable(kvPartitioned, history).ok, true)

		-- Inject failures in two independent partitions and verify aggregation.
		table.insert(history, {
			proc = "bad1",
			op = "get",
			arg = { key = "alpha" },
			res = 999,
			callAt = 200,
			retAt = 205,
		})
		table.insert(history, {
			proc = "bad2",
			op = "get",
			arg = { key = "zeta" },
			res = 888,
			callAt = 201,
			retAt = 206,
		})
		local failRes = Sim.checkLinearizable(kvPartitioned, history)
		sert.eq(failRes.ok, false)
		sert.ok(failRes.conflicts ~= nil and #(failRes.conflicts :: { any }) >= 2)
		sert.contains(failRes.message :: string, '"alpha"')
		sert.contains(failRes.message :: string, '"zeta"')
	end)

	test(
		"detects stale-read and split-brain failures with minimal conflicts, ASCII timeline, and assertion accounting",
		function()
			local kv = makeKvModel(true, false)

			-- Preceding valid window [-10..-8], stale-read conflict [0..8], and trailing window [20..22].
			local staleHistory: { SimMod.Operation<KvArg, any> } = {
				{ proc = "init", op = "put", arg = { key = "x", value = 0 }, res = true, callAt = -10, retAt = -8 },
				{ proc = "p1", op = "put", arg = { key = "x", value = 1 }, res = true, callAt = 0, retAt = 2 },
				{ proc = "p2", op = "put", arg = { key = "x", value = 2 }, res = true, callAt = 3, retAt = 5 },
				{ proc = "p3", op = "get", arg = { key = "x" }, res = 1, callAt = 6, retAt = 8 },
				{ proc = "tail", op = "put", arg = { key = "x", value = 9 }, res = true, callAt = 20, retAt = 22 },
			}
			local staleRes = Sim.checkLinearizable(kv, staleHistory)
			sert.eq(staleRes.ok, false)
			sert.ok(staleRes.conflicts ~= nil)
			sert.le(#(staleRes.conflicts :: { any }), 3)
			local timeline = staleRes.timeline :: string
			sert.contains(timeline, "proc")
			sert.contains(timeline, "operation")
			sert.contains(timeline, "p2")
			sert.contains(timeline, "p3")
			sert.contains(timeline, "[")
			sert.contains(timeline, "=")
			sert.contains(timeline, "]")
			sert.contains(timeline, "(3..5)")
			sert.contains(timeline, "(6..8)")

			-- Split-brain overlapping writes followed by incompatible sequential reads.
			local splitBrain: { SimMod.Operation<KvArg, any> } = {
				{ proc = "n1", op = "put", arg = { key = "leader", value = "A" }, res = true, callAt = 0, retAt = 2 },
				{ proc = "n2", op = "put", arg = { key = "leader", value = "B" }, res = true, callAt = 0, retAt = 2 },
				{ proc = "c1", op = "get", arg = { key = "leader" }, res = "A", callAt = 3, retAt = 5 },
				{ proc = "c2", op = "get", arg = { key = "leader" }, res = "B", callAt = 3, retAt = 5 },
			}

			local tracker = registry.activeTestAssertions()
			local beforeTotal = if tracker ~= nil then tracker.count else 0
			local beforeLin = if tracker ~= nil then (tracker.kinds.linearizable or 0) else 0
			local okLin, errLin = pcall(function() Sim.linearizable(kv, splitBrain, "split-brain invariant") end)
			local afterTotal = if tracker ~= nil then tracker.count else 0
			local afterLin = if tracker ~= nil then (tracker.kinds.linearizable or 0) else 0
			sert.eq(okLin, false)
			sert.eq(afterTotal - beforeTotal, 1)
			sert.eq(afterLin - beforeLin, 1)
			local errMsg = tostring(errLin)
			sert.contains(errMsg, "split-brain invariant")
			sert.contains(errMsg, "not linearizable")
			sert.contains(errMsg, "get(")
			sert.contains(errMsg, "=")
		end
	)
end)

describe("sert.sim.recorder() monotonic timestamps and World integration", function()
	test(
		"maintains monotonic (time, seq) timestamps across equal/regressing clocks and wraps multiple returns",
		function()
			local rawTime = 0
			local rec = Sim.recorder(function(): number return rawTime end)

			-- Sequential operations at constant timestamp 0 remain strictly ordered (A.retAt < B.callAt).
			local h1 = rec:call("p1", "inc", 1)
			local op1 = rec:finish(h1, 1)
			local h2 = rec:call("p2", "inc", 1)
			local op2 = rec:finish(h2, 2)
			sert.lt(op1.callAt, op1.retAt)
			sert.lt(op1.retAt, op2.callAt)
			sert.lt(op2.callAt, op2.retAt)

			-- Overlapping concurrent operations at constant timestamp 0 preserve overlap while clock briefly regresses.
			rawTime = 10
			local h3 = rec:call("p3", "inc", 1)
			rawTime = 9 -- Clock regression is clamped monotonically.
			local h4 = rec:call("p4", "inc", 1)
			local op3 = rec:finish(h3, 4)
			local op4 = rec:finish(h4, 3)
			sert.lt(op3.callAt, h4.callAt)
			sert.lt(h4.callAt, op3.retAt)
			sert.lt(op3.retAt, op4.retAt)

			-- :wrap preserves multiple return values while storing primary return value in Operation.res.
			local v1, v2 = rec:wrap("p5", "get", 0, function(): (number, string) return 4, "meta" end)
			sert.eq(v1, 4)
			sert.eq(v2, "meta")

			local ops = rec:operations()
			sert.eq(#ops, 5)
			sert.eq(Sim.checkLinearizable(counterModel, ops).ok, true)

			-- Propagates errors inside :wrap without losing caller error context and validates arguments.
			sert.throws(function()
				rec:wrap("p1", "get", 0, function(): number error("boom inside wrap", 0) end)
			end, "boom inside wrap")
			sert.throws(function() Sim.recorder(123 :: any) end, "clockFn")
			sert.throws(function() rec:call(true :: any, "get", 0) end, "proc")
			sert.throws(function() rec:call("p1", "", 0) end, "non-empty string")
			sert.throws(function() rec:finish(h1, 1) end, "already finished")
			sert.throws(function() rec:finish({} :: any, 1) end, "invalid OperationHandle")
			sert.throws(function() rec:wrap("p1", "get", 0, "nope" :: any) end, "expected function callback")
		end
	)

	test("uses active Env virtual clock automatically when clockFn is omitted", function()
		local env = sert.env.new()
		local envNow = 0
		env:advance(1.5)
		local rec = Sim.recorder()
		local a = rec:wrap("env1", "inc", 1, function()
			envNow = env.now
			env:advance(0.5)
			return 1
		end)
		sert.eq(a, 1)
		sert.ge(envNow, 1.5)
		local ops = rec:operations()
		sert.eq(#ops, 1)
		sert.ge(ops[1].callAt, 1.5)
		sert.ge(ops[1].retAt, 2.0)
		env:destroy()

		-- Outside any Env, falls back to os.clock cleanly.
		local plainRec = Sim.recorder()
		plainRec:wrap("os", "get", 0, function() return 0 end)
		sert.eq(#plainRec:operations(), 1)
	end)

	test(
		"verifies linearizable atomic World DataStore updates and catches non-linearizable read-modify-write races",
		function()
			-- 1. Linearizable atomic UpdateAsync across two concurrent World servers.
			local wGood = Sim.new({ seed = 7, mode = "manual" })
			local sGood1 = wGood:server({ name = "s1" })
			local sGood2 = wGood:server({ name = "s2" })
			local recGood = Sim.recorder(function() return wGood:now() end)

			sGood1:spawn(function()
				local ds = sGood1.DataStoreService:GetDataStore("counters")
				recGood:wrap("s1", "inc", 1, function()
					return ds:UpdateAsync("hits", function(old: any): number return (old or 0) + 1 end)
				end)
			end)
			sGood2:spawn(function()
				local ds = sGood2.DataStoreService:GetDataStore("counters")
				recGood:wrap("s2", "inc", 1, function()
					return ds:UpdateAsync("hits", function(old: any): number return (old or 0) + 1 end)
				end)
			end)
			wGood:converge()

			local goodRes = Sim.linearizable(counterModel, recGood:operations(), "UpdateAsync counter")
			sert.eq(goodRes.ok, true)

			-- 2. Buggy non-atomic GetAsync + sleep + SetAsync causes a lost update caught by `Sim.linearizable`.
			local wBad = Sim.new({ seed = 11, mode = "manual" })
			local sBad1 = wBad:server({ name = "s1" })
			local sBad2 = wBad:server({ name = "s2" })
			local recBad = Sim.recorder(function() return wBad:now() end)

			local function unsafeInc(srv: SimMod.Server, label: string)
				local ds = srv.DataStoreService:GetDataStore("counters")
				recBad:wrap(label, "inc", 1, function(): number
					local cur = (ds:GetAsync("hits") :: number?) or 0
					wBad:sleep(0.02)
					local nextVal = cur + 1
					ds:SetAsync("hits", nextVal)
					return nextVal
				end)
			end

			sBad1:spawn(function() unsafeInc(sBad1, "s1") end)
			sBad2:spawn(function() unsafeInc(sBad2, "s2") end)
			wBad:converge()

			local badCheck = Sim.checkLinearizable(counterModel, recBad:operations())
			sert.eq(badCheck.ok, false)
			sert.contains(badCheck.timeline :: string, "s1")
			sert.contains(badCheck.timeline :: string, "s2")
			sert.throws(
				function() Sim.linearizable(counterModel, recBad:operations(), "lost update") end,
				"lost update"
			)

			-- Deep (>depth 3) nested states remain distinct in linearizability state key memoization, and recorder:wrap captures extraRes and err.
			local deepRec = Sim.recorder()
			local d1, d2 = deepRec:wrap("p1", "multi", 1, function(): (string, number) return "ok", 99 end)
			sert.eq(d1, "ok")
			sert.eq(d2, 99)
			sert.throws(function()
				deepRec:wrap("p1", "fail", 2, function(): number error("boomWrap", 0) end)
			end, "boomWrap")
			local dOps = deepRec:operations()
			sert.eq(dOps[1].extraRes, { 99 })
			sert.contains(dOps[2].err :: string, "boomWrap")

			local deepModel: SimMod.SequentialModel<any, number, number> = {
				init = function() return { a = { b = { c = { d = { tag = "x" } } } } } end,
				step = function(st: any, op: string, _arg: number, res: number): (boolean, any)
					if op == "setA" then
						st.a.b.c.d.tag = "a"
						return res == 1, st
					elseif op == "setB" then
						st.a.b.c.d.tag = "b"
						return res == 1, st
					elseif op == "expectB" then
						return st.a.b.c.d.tag == "b", st
					end
					return false, st
				end,
			}
			local deepStateRes = Sim.checkLinearizable(deepModel, {
				{ proc = "p1", op = "setA", arg = 0, res = 1, callAt = 1, retAt = 4 },
				{ proc = "p2", op = "setB", arg = 0, res = 1, callAt = 1, retAt = 4 },
				{ proc = "p3", op = "expectB", arg = 0, res = 1, callAt = 5, retAt = 6 },
			})
			sert.eq(deepStateRes.ok, true)
		end
	)
end)
