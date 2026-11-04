--!nonstrict
--!nolint DeprecatedApi
local Doubles = require("../src/doubles")
local Sim = require("../src/sim")
local format = require("../src/format")
local prop = require("../src/prop")
local sert = require("../src")
local util = require("../src/util")

local Coop = Sim.Coop
local Explore = Sim.Explore
local Runner = Sim.Runner
local Scheduler = Sim.Scheduler
local World = Sim.World
local copy = util.copy
local geometry = sert.roblox.Layout.geometry
local mutant = prop.mutant
local eq, fails, near, test = sert.eq, sert.fails, sert.near, sert.test

local CONFIG_KEYS = { "hash", "describeError", "reporter", "datastore", "breath", "breathe" }
local function restoreConfig(saved)
	for _, k in CONFIG_KEYS do
		Sim.Config[k] = saved[k]
	end
end

local LATENCY = { 0.05, 0.3, 1 }
local function toyLatency(s: any) s:wait(s:pick(LATENCY, "toy.latency")) end
local function toyGet(s: any, store: any): (number, number)
	toyLatency(s)
	local v, ver = store.value, store.version
	toyLatency(s)
	return v, ver
end
local function toySet(s: any, store: any, v: number, expected: number?): boolean
	toyLatency(s)
	local written = expected == nil or store.version == expected
	if written then
		store.value, store.version = v, store.version + 1
	end
	toyLatency(s)
	return written
end

local Toy = {
	name = "toy",
	steps = 12,
	gen = function(r: any, n: number): { any }
		local ops, tenths = {}, 0
		for _ = 1, n do
			tenths += r:int(0, 8)
			table.insert(
				ops,
				{ t = tenths / 10, server = r:int(1, 2), kind = if r:chance(0.75) then "increment" else "read" }
			)
		end
		return ops
	end,
	setup = function(ctx: any)
		return {
			s = ctx.scheduler,
			store = { value = 0, version = 0 },
			servers = { "server1", "server2" },
			acked = 0,
			inflight = 0,
			parked = false,
		}
	end,
	apply = function(ctx: any, state: any, op: any)
		local s = state.s
		if ctx.options.deadlock and not state.parked then
			state.parked = true
			s:park()
		end
		local owner = state.servers[op.server or 1]
		if op.kind == "increment" then
			state.inflight += 1
			s:spawn(owner, function()
				if ctx.options.explode then error("toy store exploded") end
				if ctx.options.bug then
					local v = toyGet(s, state.store)
					toySet(s, state.store, v + 1)
				else
					repeat
						local v, ver = toyGet(s, state.store)
					until toySet(s, state.store, v + 1, ver)
				end
				state.acked += 1
				state.inflight -= 1
				ctx.note(`{owner} acked; store={state.store.value}`)
			end)
		elseif op.kind == "read" then
			s:spawn(owner, function() ctx.note(`{owner} read {toyGet(s, state.store)}`) end)
		end
	end,
	check = function(ctx: any, state: any)
		if state.store.value > state.acked + state.inflight then ctx.fail("overcount", `store={state.store.value}`) end
	end,
	quiesce = function(_ctx: any, state: any)
		while state.inflight > 0 do
			state.s:wait(0.1)
		end
	end,
	final = function(ctx: any, state: any)
		if state.store.value ~= state.acked then
			ctx.fail("lost-update", `store={state.store.value} acked={state.acked}`)
		end
	end,
}

test("scheduler · spawn, defer, wait, after, park, resume, crash, errors, and re-entrancy", function()
	local s = Scheduler.new()
	local log: { any } = {}
	s:spawn("Outer", function()
		table.insert(log, "a")
		s:defer("Outer", function()
			table.insert(log, "d1")
			s:drain()
			table.insert(log, "d1-end")
			s:defer("Outer", function() table.insert(log, "d3") end)
		end)
		s:spawn("Inner", function()
			eq(s.current, "Inner")
			table.insert(log, "s")
		end)
		eq(s.current, "Outer")
		s:defer("Outer", function() table.insert(log, "d2") end)
		table.insert(log, "b")
	end)
	eq(s.current, nil)
	eq(next(s.queue), nil)
	eq(log, { "a", "s", "b", "d1", "d1-end", "d2", "d3" })
	s:defer(nil, function() table.insert(log, "late") end)
	eq(#log, 7)
	s:drain()
	eq(log[8], "late")

	-- wait and frame rounding
	local s2 = Scheduler.new()
	local woke: { [string]: number } = {}
	local elapsed = 0
	s2:spawn(nil, function()
		elapsed = s2:wait(0.25)
		woke.long = s2.now
	end)
	s2:spawn(nil, function()
		s2:wait(0)
		woke.zero = s2.now
		s2:wait(0)
		woke.again = s2.now
	end)
	near(s2:frame(), 0.1)
	near(woke.zero, 0.1)
	near(s2:frame(), 0.1)
	near(woke.again, 0.2)
	near(s2:frame(0.05), 0.05)
	near(woke.long, 0.25)
	near(elapsed, 0.25)
	local waited = 0
	s2:spawn(nil, function() waited = s2:wait(0.15) end)
	s2:frame()
	eq(waited, 0)
	s2:frame()
	near(waited, 0.2)
	eq(s2:idle(), true)

	-- after, FIFO tie-breaking, and cancel
	local s3 = Scheduler.new()
	local got: { any } = {}
	local th = s3:after(
		0.3,
		"A",
		function(x: number, y: string) table.insert(got, { x, y, s3.current, s3.now }) end,
		1,
		"two"
	)
	eq(s3.owners[th], "A")
	s3:runFor(0.2)
	eq(#got, 0)
	s3:frame()
	eq(got[1][1], 1)
	eq(got[1][2], "two")
	eq(got[1][3], "A")
	near(got[1][4], 0.3)
	local fifo = {}
	for i = 1, 5 do
		s3:after(0.1, nil, function() table.insert(fifo, i) end)
	end
	s3:frame()
	eq(fifo, { 1, 2, 3, 4, 5 })
	local fired = false
	local cancelled = s3:after(0.1, nil, function() fired = true end)
	s3:cancel(cancelled)
	s3:runFor(1)
	eq(fired, false)

	-- park and resume
	local s4 = Scheduler.new()
	local plog: { any } = {}
	local parked = s4:spawn("A", function()
		local a, b = s4:park()
		table.insert(plog, { a, b, s4.current })
	end)
	local bare = s4:spawn("B", function() table.insert(plog, { coroutine.yield(), s4.current }) end)
	s4:spawn("C", function()
		s4:resume(parked, 1, 2)
		s4:resume(bare, "x")
		table.insert(plog, "C done")
	end)
	eq(plog, { "C done", { 1, 2, "A" }, { "x", "B" } })
	local again = s4:spawn(nil, function() table.insert(plog, (s4:park())) end)
	s4:resume(again, "y")
	s4:drain()
	eq(plog[4], "y")
	local rawCo = coroutine.create(function() table.insert(plog, { s4:park(), s4.current }) end)
	s4:spawn("RawOwner", function() assert(coroutine.resume(rawCo)) end)
	s4:resume(rawCo, "raw-val")
	s4:drain()
	eq(plog[5], { "raw-val", "RawOwner" })

	-- crash, errors, and re-entrancy limit (80)
	local s5 = Scheduler.new()
	local ticks, hooks = { A = 0, B = 0 }, { A = 0, B = 0 }
	local parkedA: thread? = nil
	for _, owner in { "A", "B" } do
		s5:spawn(owner, function()
			while true do
				s5:wait(0.1)
				ticks[owner] += 1
			end
		end)
		s5:onFrame(function()
			hooks[owner] += 1
		end, owner)
	end
	s5:spawn("A", function()
		parkedA = coroutine.running()
		s5:park()
		ticks.A += 100
	end)
	s5:after(0.5, "A", function()
		ticks.A += 100
	end)
	s5:runFor(0.2)
	s5:spawn("B", function()
		s5:defer("A", function()
			ticks.A += 1000
		end)
		s5:crash("A")
	end)
	eq(s5:crashed("A") and not s5:crashed("B"), true)
	s5:resume(parkedA :: thread, "late")
	s5:spawn("A", function()
		ticks.A += 10000
	end)
	s5:runFor(1)
	eq({ ticks.A, ticks.B, hooks.A, hooks.B }, { 2, 12, 2, 12 })

	local s6 = Scheduler.new()
	s6:spawn("A", function() error("boom") end)
	s6:after(0.1, "B", function() error("late boom") end)
	s6:spawn("C", function()
		coroutine.resume(coroutine.create(function()
			s6:wait(0.2)
			error("raw boom")
		end))
	end)
	s6:runFor(0.3)
	local done = s6:spawn(nil, function() end)
	s6:resume(done)
	s6:drain()
	eq(#s6.errors, 4)
	eq({ s6.errors[1].owner, s6.errors[2].owner, s6.errors[3].owner, s6.errors[4].owner }, { "A", "B", "C", nil })

	local s7 = Scheduler.new()
	local count = 0
	local function loopDefer()
		count += 1
		s7:defer("A", loopDefer)
	end
	s7:spawn("A", function() s7:defer("A", loopDefer) end)
	eq(count, 80)
	eq(#s7.errors, 1)
	s7:spawn(nil, function()
		s7:defer(nil, function()
			count += 1
		end)
	end)
	eq(count, 81)
end)

test("scheduler · random mode, choice recording/replay, explorer, streams, compaction, and wakeDue", function()
	local function scenario(seed: number, chooser: any?): (number, string)
		local s = Scheduler.new({ seed = seed, random = true, chooser = chooser })
		local order: { string } = {}
		for i = 1, 6 do
			local owner = `server{(i - 1) % 3 + 1}`
			s:spawn(owner, function()
				for round = 1, 3 do
					s:wait(if i % 2 == 0 then 0.5 else s:choose(5, "delay") / 10)
					s:trace(`{owner}/{i}/{round}`)
					table.insert(order, tostring(i))
				end
			end)
		end
		s:onFrame(function(dt: number) sert(dt >= 1 / 60 - 1e-9 and dt <= 1) end)
		s:runFor(4)
		return s:digest(), table.concat(order, ",")
	end

	local recorder = Scheduler.record(Scheduler.seeded(42))
	local digest, order = scenario(42, recorder)
	eq(digest, (scenario(42)))
	local replayed, replayedOrder = scenario(42, Scheduler.replay(recorder.choices))
	eq({ replayed, replayedOrder }, { digest, order })
	local short = Scheduler.replay({ 2 })
	eq({ short:choose(3, "x"), short:choose(3, "x") }, { 2, 1 })
	local sc = Scheduler.new({ chooser = Scheduler.replay({ 2, 3 }) })
	eq(
		{ sc:chance(0.5, "coin"), sc:pick({ "a", "b", "c" }, "letter"), sc:choose(1), sc:chance(0), sc:chance(1) },
		{ true, "c", 1, false, true }
	)

	local function sameTime(chooser: any): string
		local s = Scheduler.new({ random = true, frame = 1, chooser = chooser })
		local ord = {}
		for i = 1, 3 do
			s:spawn(nil, function()
				s:wait(0.5)
				table.insert(ord, tostring(i))
			end)
		end
		s:frame()
		return table.concat(ord)
	end
	local seen = {}
	local outcome = Explore.run(function(chooser: any) seen[sameTime(chooser)] = true end)
	eq({ outcome.runs, outcome.truncated, seen["123"], seen["321"] }, { 6, false, true, true })
	eq(Explore.run(sameTime, { maxBranch = 2 }).runs, 4)
	eq(Explore.run(sameTime, { maxRuns = 2 }).limit, "maxRuns")
	eq(Explore.run(sameTime, { maxChoices = 1 }).limit, "maxChoices")
	local bugOut = Explore.run(function(chooser: any)
		if sameTime(chooser) == "312" then error("planted") end
	end)
	eq(sameTime(Scheduler.replay((bugOut.failure :: any).choices)), "312")

	-- streams and runUntil
	local ss = Scheduler.new({ seed = 9 })
	eq(ss:stream("faults"):next(), ss:stream("faults"):next())
	sert(ss:stream("network"):next() ~= ss:stream("faults"):next())
	local flag = false
	ss:after(1, nil, function() flag = true end)
	eq(ss:runUntil(function() return flag end), true)
	eq(ss:runUntil(2.5), true)
	eq(ss:runUntil(function() return false end, 1), false)
	ss:onFrame(function() end)()

	-- host hooks, wait cancellation, timer/trace compaction, running/owns, wakeDue
	local sh = Scheduler.new({ seed = 12 })
	local hooks = sh:host("ServerA")
	eq(hooks.clock(), 0)
	local hlog = {}
	hooks.spawn(function(msg: string)
		table.insert(hlog, `spawn:{msg}:{sh.current}`)
		hooks.defer(function(dmsg: string) table.insert(hlog, `defer:{dmsg}:{sh.current}`) end, "d")
		table.insert(hlog, string.format("waited:%.1f", hooks.wait(0.2)))
	end, "s")
	local pt = hooks.spawn(function() table.insert(hlog, `resumed:{sh:park()}`) end)
	hooks.resume(pt, "ok")
	sh:drain()
	sh:runFor(0.2)
	eq(hlog, { "spawn:s:ServerA", "defer:d:ServerA", "resumed:ok", "waited:0.2" })

	fails(function()
		table.sort({ 1, 2 }, function()
			sh:wait(0.1)
			return false
		end)
	end, "Scheduler.wait must be called from a thread that can yield")

	local waiter1 = sh:spawn(nil, function() sh:wait(10) end)
	sh:spawn(nil, waiter1)
	eq(sh.waits[waiter1], nil)

	local parkedWaiter = sh:spawn(nil, function() sh:park() end)
	local fakeTimer = { cancelled = false }
	sh.waits[parkedWaiter] = fakeTimer :: any
	sh:spawn(nil, parkedWaiter)
	eq(fakeTimer.cancelled, true)

	local waiter2 = sh:spawn(nil, function() sh:wait(10) end)
	assert(coroutine.resume(waiter2))
	sh:runFor(11)
	eq(#sh.timers, 0)

	local cancelWaiter = sh:spawn(nil, function() sh:wait(10) end)
	sh:cancel(cancelWaiter)
	eq(coroutine.status(cancelWaiter), "dead")
	sh:spawn(nil, function() sh:cancel(coroutine.running()) end)

	-- timer compaction on cancel and crash (>32 timers)
	sh.timers = {}
	for _ = 1, 10 do
		sh:after(0.5, nil, function() end)
	end
	local toCancel = {}
	for _ = 1, 33 do
		table.insert(toCancel, sh:after(5, nil, function() end))
	end
	local defThread = sh:defer(nil, function() end)
	sh:cancel(defThread)
	for i = 1, 33 do
		sh:cancel(toCancel[i])
	end
	eq(#sh.timers, 10)
	sh:runFor(1)

	for _ = 1, 10 do
		sh:after(0.5, "Surv", function() end)
	end
	for _ = 1, 33 do
		sh:after(5, "Doom", function() end)
	end
	sh:defer("Doom", function() end)
	sh:defer("Surv", function() end)
	local d1 = sh:onFrame(function() end, "Doom")
	local d2 = sh:onFrame(function() end, "Surv")
	sh:crash("Doom")
	eq(#sh.timers, 10)
	sh:runFor(1)
	d1()
	d2()

	-- random vs manual frame hooks, bad chooser, trace compaction, running/owns, wakeDue
	local rOrder, mOrder = {}, {}
	local rSched = Scheduler.new({ random = true, chooser = Scheduler.replay({ 2 }) })
	rSched:onFrame(function() table.insert(rOrder, 1) end)
	rSched:onFrame(function() table.insert(rOrder, 2) end)
	rSched:frame(0.1)
	local mSched = Scheduler.new({ random = false, chooser = Scheduler.replay({ 2 }) })
	mSched:onFrame(function() table.insert(mOrder, 1) end)
	mSched:onFrame(function() table.insert(mOrder, 2) end)
	mSched:frame(0.1)
	eq({ rOrder, mOrder }, { { 2, 1 }, { 1, 2 } })

	fails(function()
		Scheduler.new({ chooser = { choose = function() return 99 end } }):choose(3, "bad")
	end, "chooser answered 99 for bad")

	local tSched = Scheduler.new()
	for i = 1, 2005 do
		tSched:trace(`line-{i}`)
	end
	eq({ #tSched.traced, tSched.traced[1], tSched.traced[1005] }, { 1005, "line-1001", "line-2005" })

	local inside: boolean?, ownedWaiter: thread? = nil, nil
	tSched:spawn("A", function()
		inside, ownedWaiter = tSched:running(), coroutine.running()
		tSched:wait(1)
	end)
	eq(
		{ inside, tSched:running(), tSched:owns(ownedWaiter :: thread), tSched:owns(coroutine.create(function() end)) },
		{ true, false, true, false }
	)

	local wSched = Scheduler.new()
	local wLog = {}
	wSched:after(0, "A", function()
		table.insert(wLog, "due")
		wSched:defer("A", function() table.insert(wLog, "deferred") end)
	end)
	wSched:after(1, "A", function() table.insert(wLog, "later") end)
	wSched:wakeDue()
	eq(wLog, { "due", "deferred" })
	wSched:runFor(1)
	eq(wLog, { "due", "deferred", "later" })
end)

test("runner · ops, run, shrink, explore, replay, fromGen, check/marker errors, and owner formatting", function()
	local BUG = { bug = true }
	local APART = { { t = 0, server = 1, kind = "increment" }, { t = 1, server = 2, kind = "increment" } }
	eq(#Runner.ops(Toy, 7), Toy.steps)
	eq(#Runner.ops(Toy, 7, 3), 3)
	eq(Runner.find({ Toy }, "toy"), Toy)
	eq(Runner.find({ Toy }, "missing"), nil)

	local clean1 = Runner.run(Toy, { seed = 1 })
	eq(clean1.ok, true)

	local failRes: any = nil
	for seed = 1, 50 do
		local r = Runner.run(Toy, { seed = seed, options = BUG })
		if not r.ok then
			failRes = r
			break
		end
	end
	assert(failRes ~= nil, "failed")
	eq(failRes.failure.invariant, "lost-update")
	sert.contains(Runner.headline("toy", failRes.seed, failRes.failure), "FAIL toy seed=")

	local shrunk = Runner.shrink(Toy, failRes, { maxRuns = 200, maxSeconds = 30 })
	sert(#shrunk.ops <= 2)
	eq(Runner.literal({}), "{\n}")
	eq(
		(Runner.run(Toy, { seed = failRes.seed, ops = shrunk.ops, options = BUG }).failure :: any).invariant,
		"lost-update"
	)

	local expOut = Runner.explore(Toy, APART, { options = BUG, maxRuns = 2000 })
	assert(expOut.failure ~= nil and expOut.choices ~= nil, "failed")
	eq(
		(Runner.replay(Toy, { seed = 1, ops = APART, choices = expOut.choices, options = BUG }).failure :: any).invariant,
		"lost-update"
	)
	eq(Runner.explore(Toy, APART, { maxRuns = 50 }).failure, nil)

	local fixed = Runner.run(Toy, { seed = 4, ops = Runner.ops(Toy, 4), options = BUG, frame = 0.25 })
	eq(
		Runner.replay(Toy, { seed = 4, ops = fixed.ops, choices = fixed.choices, frame = fixed.frame, options = BUG }).digest,
		fixed.digest
	)

	-- explode, allowErrors, deadlock, time-limit, budget, swallowed ctx.fail
	eq((Runner.run(Toy, { seed = 1, options = { explode = true } }).failure :: any).invariant, "runtime-error")
	eq(
		Runner.run(Toy, {
			seed = 1,
			ops = { { t = 0, server = 1, kind = "read" } },
			options = {
				explode = true,
				allowErrors = function(e: any) return string.find(e.message, "exploded", 1, true) ~= nil end,
			},
		}).ok,
		true
	)
	local allowAll = Runner.run(Toy, {
		seed = 1,
		ops = { { t = 0, server = 1, kind = "increment" } },
		options = { explode = true, allowErrors = true },
	})
	sert(allowAll.failure == nil or allowAll.failure.invariant ~= "runtime-error")
	eq((Runner.run(Toy, { seed = 1, steps = 3, options = { deadlock = true } }).failure :: any).invariant, "deadlock")
	eq(
		(
			Runner.run(Toy, { seed = 1, steps = 3, options = { deadlock = true }, maxTime = 5, stall = 60 }).failure :: any
		).invariant,
		"time-limit"
	)
	eq(
		(
			Runner.run(Toy, { seed = 1, steps = 3, options = { deadlock = true }, budget = 0, stall = 1e9 }).failure :: any
		).invariant,
		"budget"
	)

	-- fromGen and prop over choices
	local zeroChooser = Scheduler.fromGen({
		int = function(_, lo) return lo end,
		weighted = function(_, items) return items[1][2] end,
	})
	eq(
		{ zeroChooser:choose(3, "x"), zeroChooser:choose(2, "c", { 0.9, 0.1 }), zeroChooser:choose(2, "z", { 0, 0 }) },
		{ 1, 1, 1 }
	)
	local propRes = sert.prop.run("toy choices", function(g)
		local r = Runner.run(
			Toy,
			{ seed = 1, ops = APART, options = BUG, chooser = Scheduler.fromGen(g, { note = true }), frame = 0.1 }
		)
		if r.failure then error(Runner.headline("toy", 1, r.failure), 0) end
	end, { runs = 300 }, {})
	eq(propRes.ok, false)

	-- describe, markers, owners, check errors, shrink truncation
	-- selene: allow(mixed_table)
	eq(
		Runner.describe({ 10, a = 1, ["b-c"] = { x = true }, [0] = "z", fn = function() end }),
		'{ 10, ["b-c"] = { x = true }, [0] = "z", a = 1, fn = <function> }'
	)
	eq(Runner.describe({}), "{}")
	eq(Runner.describe(nil), "nil")

	local capturedMarker: any = nil
	local resMarker = Runner.run(
		{
			name = "tm",
			steps = 1,
			gen = function() return { { t = 0, server = 1, kind = "boom", args = { k = 1 } } } end,
			setup = function() return {} end,
			apply = function(ctx: any)
				ctx.note("custom-note")
				ctx.scheduler:spawn({ id = 77 }, function()
					local _, err = pcall(ctx.fail, "spawn-inv", "from-thread")
					capturedMarker = err
					sert(tostring(err) == "spawn-inv: from-thread")
					error(err, 0)
				end)
			end,
		} :: any,
		{ seed = 1, trace = true }
	)
	eq((resMarker.failure :: any).invariant, "spawn-inv")

	local falseMarker = table.clone(capturedMarker)
	for k, v in falseMarker do
		if type(k) == "table" and v == true then falseMarker[k] = false end
	end
	for _, case in
		{
			{ "m-owner", capturedMarker, "spawn-inv" },
			{ "n-owner", 404, "runtime-error" },
			{ "f-owner", falseMarker, "runtime-error" },
			{ {}, { code = 500 }, "runtime-error" },
			{ { name = "srv-a" }, "boom", "runtime-error" },
			{ { jobId = "job-9" }, "boom", "runtime-error" },
			{ { id = 77 }, "boom", "runtime-error" },
			{ nil, "boom", "runtime-error" },
		}
	do
		local r = Runner.run(
			{
				name = "oe",
				steps = 1,
				gen = function() return { { t = 0, kind = "e" } } end,
				setup = function() return {} end,
				apply = function(ctx: any)
					ctx.scheduler:spawn(case[1], function() error(case[2], 0) end)
				end,
			} :: any,
			{ seed = 1 }
		)
		eq((r.failure :: any).invariant, case[3])
	end

	for _, checkFn in
		{
			function(ctx: any) ctx.fail("bad-check", "failed") end,
			function() error({ reason = "crash" }, 0) end,
			function() coroutine.yield() end,
		}
	do
		local r = Runner.run(
			{
				name = "ct",
				steps = 1,
				gen = function() return { { t = 0.2, kind = "w" } } end,
				setup = function() return {} end,
				apply = function(ctx: any) ctx.scheduler:wait(0.2) end,
				check = checkFn,
			} :: any,
			{ seed = 1 }
		)
		eq(r.ok, false)
	end

	local multiOp: any = {
		name = "mo",
		steps = 4,
		gen = function()
			return { { t = 0, kind = "a" }, { t = 0.1, kind = "b" }, { t = 0.2, kind = "c" }, { t = 0.3, kind = "d" } }
		end,
		setup = function() return { seen = {} } end,
		apply = function(ctx: any, st: any, op: any)
			st.seen[op.kind] = true
			if st.seen.a and st.seen.d then ctx.fail("pair-ad", "both") end
		end,
	}
	local failMulti = Runner.run(multiOp, { seed = 1 })
	eq(Runner.shrink(multiOp, failMulti, { maxRuns = 1 }).truncated, true)
	eq(#Runner.shrink(multiOp, failMulti, { maxRuns = 50 }).ops, 2)
end)

test(
	"world · messaging, partitions, JSON mode, server identities, custom/built-in DataStore, and Sim.configure",
	function()
		local w = World.new({ latency = { delivery = 0.5 } })
		w.messaging.auto = true
		local s = w.scheduler
		local a, b = w:server(), w:server()
		local got: { any } = {}
		s:spawn(b, function()
			b.host.MessagingService:SubscribeAsync("t", function(m: any) table.insert(got, { m.Data, s.now }) end)
		end)
		eq(w.messaging:subscriptions(b), 1)
		local function publish(srv: any, data: any): (boolean, any)
			local ok, err = false, nil
			s:spawn(srv, function()
				ok, err = pcall(srv.host.MessagingService.PublishAsync, srv.host.MessagingService, "t", data)
			end)
			return ok, err
		end
		eq(publish(a, "one"), true)
		s:runFor(1)
		eq(got[1][1], "one")
		w:partition(b, 10)
		eq(publish(a, "two"), true)
		eq((publish(b, "out")), false)
		s:runFor(1)
		eq(#got, 1)
		w:heal()
		publish(a, "three")
		s:runFor(1)
		eq(got[2][1], "three")
		eq((publish(a, string.rep("x", 2000))), false)
		b:crash()
		eq(w.messaging:subscriptions(), 0)

		-- random messaging drops/duplicates/reorders
		local wr = World.new({ mode = "random", seed = 11, faults = { drop = 0.2, duplicate = 0.2 } })
		local ra, rb = wr:server(), wr:server()
		local rgot = {}
		wr.scheduler:spawn(rb, function()
			rb.host.MessagingService:SubscribeAsync("t", function(m: any) table.insert(rgot, m.Data) end)
		end)
		wr.scheduler:runFor(2)
		wr.scheduler:spawn(ra, function()
			for i = 1, 60 do
				ra.host.MessagingService:PublishAsync("t", i)
			end
		end)
		wr.scheduler:runFor(30)
		sert(#rgot > 20)

		-- manual messaging pump, drain, fail, shared service, disconnect, isolate, deep copy
		local wm = World.new()
		local ma, mb = wm:server(), wm:server()
		local m = wm.messaging
		local mgot, sharedGot = {}, {}
		local sConn = m.service:SubscribeAsync("sh", function(msg) table.insert(sharedGot, msg.Data) end)
		m.service:PublishAsync("sh", "ok")
		m:drain()
		eq(sharedGot, { "ok" })
		sConn:Disconnect()

		wm:fail("MessagingService", "SubscribeAsync", "before")
		fails(function()
			ma.host.MessagingService:SubscribeAsync("t", function() end)
		end, "SubscribeAsync: connection lost")
		wm:isolate(ma)
		eq(wm:isolated(ma), true)
		fails(function()
			ma.host.MessagingService:SubscribeAsync("t", function() end)
		end, "MessagingService: connection lost")
		wm:heal()

		local c1 = mb.host.MessagingService:SubscribeAsync("t", function(msg: any) table.insert(mgot, msg.Data) end)
		mb.host.MessagingService:SubscribeAsync("t", function() end)
		ma.host.MessagingService:PublishAsync("t", "x")
		ma.host.MessagingService:PublishAsync("t", "y")
		m:pump(2)
		m:pump(1, true)
		eq(mgot, { "y" })
		wm:fail("MessagingService", "PublishAsync", "before")
		eq(pcall(ma.host.MessagingService.PublishAsync, ma.host.MessagingService, "t", "z"), false)
		wm:fail("MessagingService", "PublishAsync", "after", "lost")
		eq(pcall(ma.host.MessagingService.PublishAsync, ma.host.MessagingService, "t", "z"), false)
		m:drain()
		eq(mgot, { "y", "z" })

		local senv = ma:env()
		local deep: any = { leaf = "ok" }
		for _ = 1, 66 do
			deep = { child = deep }
		end
		m.limit = nil
		ma.host.MessagingService:PublishAsync("t", {
			buf = buffer.fromstring("hi"),
			inst = senv.Instance.new("Part"),
			vec = senv.globals.Vector3.new(1, 2, 3),
			deep = deep,
		})
		m:drain()
		c1:Disconnect()
		c1:Disconnect()
		ma.host.MessagingService:PublishAsync("t", "after-disc")
		m:drain()
		mb:shutdown()
		wm:run(0.5)

		-- JSON messaging
		local wj = World.new({ messaging = { json = true } })
		local ja, jb = wj:server(), wj:server()
		local jgot = {}
		jb.host.MessagingService:SubscribeAsync("t", function(msg) table.insert(jgot, msg.Data) end)
		ja.host.MessagingService:PublishAsync("t", { k = 1 })
		ja.host.MessagingService:PublishAsync("raw", buffer.fromstring("x"))
		wj.messaging:drain()
		eq(jgot[1], { k = 1 })

		-- server identities & World.extend
		local Ext = World.extend({ pair = function(world) return world:server(), world:server() end })
		local we = Ext.new()
		local ea, eb = we:pair()
		eq({ ea.name, eb:restart().name }, { "s1", "s2.1" })
		sert(#ea.host.HttpService:GenerateGUID(false) > 10)

		-- backing = false, custom backing, option validation, assertNoErrors, Sim.configure, breath, golden hash/rng
		local bare = World.new({ backing = false })
		eq(bare.datastore, nil)
		bare:server():env()
		eq(bare.datastore, nil)

		local copies = { 0 }
		local wc = World.new({
			backing = {
				new = function(opts)
					local mock = { stores = {}, options = opts }
					function mock:GetDataStore(name: string)
						mock.stores[name] = mock.stores[name]
							or {
								data = {},
								GetAsync = function(h, k) return if h.data[k] then h.data[k].value else nil end,
								UpdateAsync = function(h, k, fn)
									local v = fn(if h.data[k] then h.data[k].value else nil)
									if v == nil then return nil end
									h.data[k] = { value = v, version = 1 }
									return v
								end,
							}
						return mock.stores[name]
					end
					return mock
				end,
				copy = function(v)
					copies[1] += 1
					return v
				end,
			},
			latency = { DataStoreService = 0.5 },
		})
		local commits = {}
		wc:onCommit(function(st, k, row, srv) table.insert(commits, `{st.name}/{k}={row.value}@{srv.name}`) end)
		local ca = wc:server()
		wc.scheduler:spawn(ca, function()
			ca.host.DataStoreService:GetDataStore("S"):UpdateAsync("k", function(old) return (old or 0) + 1 end)
		end)
		wc.scheduler:runFor(2)
		eq(commits, { "S/k=1@s1" })
		sert(copies[1] > 0)

		fails(function() w:server({ name = "alpha" }) end, "unknown option name")
		fails(function() World.new({ faults = { profile = "light", dorp = 1 } }) end, "unknown fault dorp")

		local werr = World.new()
		werr:assertNoErrors("quiet")
		werr:server():spawn(function() error("boom", 0) end)
		fails(function() werr:assertNoErrors("label") end, "label: unhandled scheduler error: boom")

		local saved = table.clone(Sim.Config)
		local handler = nil
		local breaths = 0
		local ok, err = pcall(function()
			Sim.configure({
				describeError = function(e) return `described: {tostring(e)}` end,
				reporter = function(fn) handler = fn end,
				breath = 0,
				breathe = function()
					breaths += 1
				end,
			})
			local wcfg = World.new()
			wcfg.scheduler:spawn("A", function() error("boom", 0) end)
			eq(wcfg.scheduler.errors[1].message, "described: boom")
			local stop = wcfg:capture()
			handler({ source = "T", code = "Oops" })
			eq(wcfg:reports()[1].event.code, "Oops")
			stop()
			wcfg.scheduler:frame()
			eq(breaths, 1)
			Sim.configure({ breath = 3600 })
			wcfg.scheduler:frame()
			Sim.configure({ breath = false })
			wcfg.scheduler:frame()
			eq(breaths, 1)
			fails(function() Sim.configure({ nope = true }) end)
		end)
		restoreConfig(saved)
		assert(ok, tostring(err))

		eq({ Sim.Hash.fnv1a32(""), Sim.Hash.fnv1a32("a"), Sim.Rng.xorshift32(1) }, { 2166136261, 0xE40C292C, 270369 })
		eq(Sim.Rng.new(0):next(), Sim.Rng.new(0x9E3779B9):next())
	end
)

test("world · MemoryStore, DataStore, Players, gates, faults, instant mode, and converge", function()
	local MemoryStore = Sim.services.memorystore
	local standalone = MemoryStore.new()
	standalone:GetHashMap("pruneCheck"):SetAsync("short", "hello", 1)
	eq(standalone:stored(), { values = 1, bytes = 5 })
	standalone:step(2)
	eq(standalone:stored(), { values = 0, bytes = 0 })

	local tMap = standalone:GetSortedMap("tmap")
	tMap:SetAsync("exp_set", "old", 1, 1)
	tMap:SetAsync("exp_upd", "old", 1, 2)
	tMap:SetAsync("exp_range", "old", 1, 3)
	tMap:SetAsync("keep", "alive", 100, 4)
	standalone:step(2)
	eq(tMap:SetAsync("exp_set", "reborn", 60, 1), false)
	tMap:UpdateAsync("exp_upd", function() return "fresh-upd", 2 end, 60)
	eq(#tMap:GetRangeAsync("Ascending", 10), 3)

	local q = standalone:GetQueue("jobs", 10)
	q:AddAsync("low-1", 60, 1)
	q:AddAsync("high-1", 60, 5)
	q:AddAsync("high-2", 60, 5)
	q:AddAsync("short-lived", 1, 10)
	standalone:step(2)
	eq(#(q:ReadAsync(10, true, 1)), 0)
	local items, rid = q:ReadAsync(2, false, 1)
	eq(items, { "high-1", "high-2" })
	eq({ q:GetSizeAsync(false), q:GetSizeAsync(true) }, { 3, 1 })
	q:RemoveAsync(rid)
	local _, rid2 = q:ReadAsync(5, false, 1)
	standalone:step(11)
	q:RemoveAsync(rid2)

	-- World MemoryStore + DataStore + contention
	local w = World.new({ backing = true, faults = { budget = 5 }, latency = { MemoryStoreService = 0.2 } })
	local s = w.scheduler
	local a, b = w:server(), w:server()
	for _, srv in { a, b } do
		s:spawn(srv, function()
			srv.host.MemoryStoreService:GetHashMap("m"):UpdateAsync("k", function(old) return (old or 0) + 1, 0 end, 60)
		end)
	end
	s:runFor(3)
	eq(w.memory:GetHashMap("m"):GetAsync("k"), 2)
	w:fail("MemoryStoreService", "SetAsync", "after")
	s:spawn(
		a,
		function()
			pcall(
				a.host.MemoryStoreService:GetHashMap("m").SetAsync,
				a.host.MemoryStoreService:GetHashMap("m"),
				"j",
				7,
				60
			)
		end
	)
	s:runFor(2)
	eq(w.memory:GetHashMap("m"):GetAsync("j"), 7)
	s:spawn(a, function() a.host.MemoryStoreService:GetQueue("q", 30):ReadAsync(1, false, 1) end)
	s:runFor(3)
	w.fixed.MemoryStoreService = nil

	local sm = a.host.MemoryStoreService:GetSortedMap("scores")
	sm:SetAsync("p1", buffer.fromstring("buf"), 60, 10)
	sm:SetAsync("p2", "two", 60, 20)
	sm:SetAsync("p2", "two-upd", 60, 20)
	sm:SetAsync("p3", { nested = { x = 1 } }, 60, 20)
	sm:SetAsync("p4", 99, 60, "alpha")
	sm:SetAsync("p5", "none", 60, nil)
	sm:SetAsync("exp", "soon", 1, 5)
	sm:SetAsync("temp", "del", 60, 1)
	sm:RemoveAsync("temp")
	w:run(2)
	eq(sm:GetAsync("exp"), nil)
	eq(#sm:GetRangeAsync("Ascending", 3), 3)
	eq(#sm:GetRangeAsync("Descending", 2), 2)
	eq(#sm:GetRangeAsync("Ascending", 10, { sortKey = 10, key = "p1" }, { sortKey = "alpha", key = "p4" }), 2)
	local pages = sm:ListItemsAsync(2)
	pages:AdvanceToNextPageAsync()
	pages:AdvanceToNextPageAsync()
	eq(pages.IsFinished, true)
	eq(sm:UpdateAsync("p2", function() return nil end, 60), nil)
	local rawSm = w.memory:GetSortedMap("scores")
	eq(rawSm:UpdateAsync("p2", function() return nil end, 60), nil)
	w.memory.conflict = function(m, k) m.data[k] = { value = "interleaved", expiry = w.memory.now + 60, sortKey = 50 } end
	rawSm:UpdateAsync("p2", function(old, sk) return `{old}!`, (sk or 0) + 1 end, 60)
	sm:UpdateAsync("p2", function(old, sk) return `{old}?`, (sk or 0) + 9 end, 60)
	a.host.MemoryStoreService:GetQueue("wq", 30):AddAsync("qstr", 60, 1)
	sert(w.memory:stored().values >= 5)

	-- MemoryStore & DataStore contention exhaustion
	w.fixed.MemoryStoreService = 0.2
	local rawCont = w.memory:GetHashMap("contentious")
	local stopMut = s:onFrame(function() rawCont.data.hot = { value = s.now, expiry = s.now + 60 } end, b)
	local msContErr: any = nil
	s:spawn(a, function()
		local ok, err = pcall(function()
			a.host.MemoryStoreService
				:GetHashMap("contentious")
				:UpdateAsync("hot", function(o) return (o or 0) + 1 end, 60)
		end)
		if not ok then msContErr = err end
	end)
	s:runFor(5)
	stopMut()
	w.fixed.MemoryStoreService = nil
	sert.contains(tostring(msContErr), "too much contention")

	-- DataStore budgets, cache, versions, OrderedDataStore, contention
	local dss, bDss = a.host.DataStoreService, b.host.DataStoreService
	eq(dss:GetRequestBudgetForRequestType("StandardRead"), 5)
	eq(bDss:GetRequestBudgetForRequestType("StandardRead"), 5)
	dss:budget("StandardRead", nil)
	eq(dss:GetRequestBudgetForRequestType("StandardRead"), 1000000)
	dss:budget("StandardWrite", 0, 0)
	local gds, bGds = dss:GetGlobalDataStore(), bDss:GetGlobalDataStore()
	local rawGlobal = w.datastore.mock:GetDataStore("_global", "global")
	fails(function() gds:SetAsync("k", "v") end, "RequestThrottled")
	dss:budget("StandardWrite", 2, 60)
	eq(dss:GetRequestBudgetForRequestType("StandardWrite"), 2)
	w:run(1.1)
	eq(dss:GetRequestBudgetForRequestType("StandardWrite"), 3)
	dss:budget("StandardWrite", nil)
	bDss:budget("StandardWrite", nil)
	gds:SetAsync("k", "v1")
	bGds:SetAsync("k2", { nested = 42 })
	eq(gds:GetAsync("k"), "v1")
	rawGlobal.data.k.value = "behind-cache"
	eq(gds:GetAsync("k"), "v1")
	eq(gds:GetAsync("k", { UseCache = false }), "behind-cache")
	eq((bGds:GetAsync("k")), "behind-cache")
	rawGlobal.data.k.value = "mutated"
	eq((bGds:GetAsync("k")), "behind-cache")
	bDss:budget("StandardRead", nil)

	gds:SetAsync("num", 10)
	eq(gds:IncrementAsync("num", 5), 15)
	local vPages = gds:ListVersionsAsync("num", nil, nil, nil, 1)
	local ver = vPages:GetCurrentPage()[1].Version
	eq(gds:GetVersionAsync("num", ver), 10)
	vPages:AdvanceToNextPageAsync()
	gds:RemoveVersionAsync("num", ver)
	eq(gds:GetVersionAsync("num", ver), nil)
	eq((gds:RemoveAsync("num")), 15)
	eq(gds:GetAsync("num"), nil)
	eq(gds:RemoveAsync("nonexistent"), nil)
	eq(gds:UpdateAsync("k", function() return nil end), nil)

	local ods = dss:GetOrderedDataStore("Board", "s1")
	ods:SetAsync("u1", 100)
	ods:IncrementAsync("u2", 250)
	ods:UpdateAsync("u1", function(o) return (o or 0) + 50 end)
	local sp = ods:GetSortedAsync(false, 1)
	eq(sp:GetCurrentPage()[1].key, "u2")
	sp:AdvanceToNextPageAsync()
	eq(sp:GetCurrentPage()[1].key, "u1")
	ods:RemoveAsync("u1")

	w.fixed.DataStoreService = 0.2
	local vSeq = 100
	local stopDsMut = s:onFrame(function()
		vSeq += 1
		rawGlobal.data.contended = { value = vSeq, version = tostring(vSeq), created = 1, updated = 1 }
	end, b)
	local dsContErr: any = nil
	s:spawn(a, function()
		local ok, err = pcall(function()
			gds:UpdateAsync("contended", function(o) return (o or 0) + 1 end)
		end)
		if not ok then dsContErr = err end
	end)
	s:runFor(5)
	stopDsMut()
	sert.contains(tostring(dsContErr), "too much contention")

	-- Players, extra peers sorting, Kick in random & instant modes
	local wp = World.new({ mode = "random", seed = 7 })
	local spSrv = wp:server()
	local p1 = spSrv:join(100)
	wp.scheduler:drain()
	for _, uid in { 500, 300, 150 } do
		spSrv.players.peers[uid] = { UserId = uid, Name = `Player{uid}` }
	end
	eq(#spSrv.players:GetPlayers(), 4)
	eq(spSrv.players:GetPlayerByUserId(300).Name, "Player300")
	spSrv:env()
	eq(spSrv:join(999):IsA("Player"), true)
	p1:Kick("bye")
	p1:Kick("again")
	wp:run(2)
	eq(spSrv.players:GetPlayerByUserId(100), nil)

	-- Gates, coarse mode, transform error/yield, probabilistic faults, instant mode, converge
	local wg = World.new({
		backing = true,
		mode = "random",
		seed = 3,
		coarse = true,
		faults = { profile = "light", before = 0 },
	})
	wg:trace("custom")
	wg:latency("DataStoreService")
	local ga, gb = wg:server(), wg:server()
	wg:step(0.1)
	ga.host.bindClose(function() end)()
	wg:dispatch(ga, function() end)
	local spawnSig = wg:signal(ga, "spawn")
	wg.scheduler:spawn(ga, function() spawnSig:Wait() end)
	wg.scheduler:spawn(gb, function() spawnSig:Fire() end)

	local gate = wg:hold("MemoryStoreService", "GetAsync")
	for _, srv in { ga, gb } do
		wg.scheduler:spawn(srv, function() srv.host.MemoryStoreService:GetHashMap("g"):GetAsync("k") end)
	end
	wg.scheduler:spawn(ga, function()
		assert(coroutine.resume(coroutine.create(function() gate:enter() end)))
	end)
	gate:release(1)
	wg:run(1)
	gate:release()
	wg:run(1)
	gate:enter()
	local oldG = wg:hold("MemoryStoreService", "SetAsync")
	local newG = wg:hold("MemoryStoreService", "SetAsync")
	oldG:release()
	newG:release()

	fails(function()
		wg:transform(function() error("tx-boom", 0) end)
	end, "tx-boom")
	fails(function()
		wg:transform(function() coroutine.yield() end)
	end, "transforms cannot yield")

	local wf = World.new({ mode = "random", seed = 1, faults = { before = 1, subscribe = 1 } })
	local sf = wf:server()
	wf.scheduler:spawn(sf, function()
		pcall(sf.host.MessagingService.SubscribeAsync, sf.host.MessagingService, "t", function() end)
		pcall(sf.host.MemoryStoreService:GetHashMap("f").GetAsync, sf.host.MemoryStoreService:GetHashMap("f"), "k")
	end)
	wf:run(2)

	-- Instant mode
	local wi = World.new({ wait = "instant", backing = false })
	wi.clock.now = 10
	local si, siCr = wi:server(), wi:server()
	siCr:crash()
	si:join(50):Kick("instant")
	si.host.defer(function() end)
	si.host.wait(1)
	wi:dispatch(si, function() end)
	wi:signal(si, "defer")
	assert(
		coroutine.resume(
			coroutine.create(function() si.host.MemoryStoreService:GetQueue("iq", 10):ReadAsync(1, false, 2) end)
		)
	)
	si.run.Heartbeat:Connect(function()
		wi.coop.hooks.defer(function() end)
	end)
	local stopHk = wi:onFrame(function() end)
	wi:step(0.25)
	stopHk()
	wi:step()
	local iGate = wi:hold("MemoryStoreService", "GetAsync")
	assert(coroutine.resume(coroutine.create(function() si.host.MemoryStoreService:GetHashMap("ig"):GetAsync("k") end)))
	iGate:release()
	si.host.bindClose(function() end)
	si:shutdown()
	si:shutdown()

	-- Converge & closer error
	wg:onCommit(function() end)()
	eq(wg:runUntil(wg.scheduler.now + 0.2), true)
	wg:isolate(ga)
	wg.fixed.MessagingService = 0
	wg.fixed.MemoryStoreService = 0
	local cg = wg:hold("MemoryStoreService", "GetAsync")
	wg.scheduler:spawn(ga, function() ga.host.MemoryStoreService:GetHashMap("cg"):GetAsync("k") end)
	wg:fail("DataStoreService", "GetAsync", "before")
	wg.messaging.auto = false
	gb.host.MessagingService:SubscribeAsync("ct", function() end)
	gb.host.MessagingService:PublishAsync("ct", "msg")
	wg:converge({ seconds = 0.2, invariant = function() end })
	eq(cg.held, false)

	local cDead = wg:server()
	cDead.proj = { x = 999 }
	cDead:crash()
	ga.proj, gb.proj = { nested = { x = 1 } }, { nested = { x = 2 } }
	wg.scheduler:after(0.2, gb, function() gb.proj = { nested = { x = 1 } } end)
	wg:converge(function(srv) return srv.proj end, { timeout = 1, step = 0.1, invariant = function() end })

	ga.host.bindClose(function() error("closer-failed", 0) end)
	ga:shutdown(1)
	wg:run(0.5)
	sert.contains(wg:summary(), "[error] closer-failed")
	fails(function() wg:converge({ seconds = 0.1 }) end, "closer-failed")
	fails(function()
		wg:converge(function(srv) return srv.state end, { timeout = 0.2 })
	end, "closer-failed")
end)

test(
	"sim · replication, remotes, Coop, Sim.prop/model/explore, RunService phases, util.copy, format.json, DataStore, and geometry",
	function()
		-- Signal, Datatypes, strict env, lazy services
		local sig: any = Doubles.Signal.new()
		eq(
			{ Doubles.Datatypes.typeof(sig), tostring(sig), sig.connect, sig.wait, sig.once },
			{ "RBXScriptSignal", "RBXScriptSignal", sig.Connect, sig.Wait, nil }
		)
		local cPar = sig:ConnectParallel(function() end)
		eq({ cPar.disconnect, sig:connections(), sig:connected() }, { cPar.Disconnect, 1, true })
		cPar:Disconnect()
		sig:Once(function() end)
		sig:Fire("a")
		sig:DisconnectAll()
		local waiter = coroutine.create(function()
			if sig:Wait() == "boom" then error("waiter exploded", 0) end
		end)
		assert(coroutine.resume(waiter))
		fails(function() sig:Fire("boom") end, "waiter exploded")

		local strictEnv = sert.env.new({ strict = true })
		fails(function() strictEnv.Instance.new("GuiObject") end, "Unable to create an Instance")
		local root = strictEnv.Instance.new("Frame")
		fails(function() local _ = root.NonExistentProp end, "is not a valid member")
		fails(function() root.AbsoluteSize = strictEnv.globals.Vector2.new(1, 1) end, "Property is read only")
		local lbl = strictEnv.Instance.new("TextLabel", root)
		lbl.Name, lbl.Text, lbl.AutomaticSize = "Title", 42, "XY"
		lbl:AddTag("Header")
		eq(#root:QueryDescendants("TextLabel#Title.Header"), 1)
		lbl:Destroy()
		fails(function() lbl.Parent = root end, "Parent property of Title is locked")

		-- Replication, PrimaryPart, attributes, remotes, disconnect, instant remotes
		local w = World.new({ backing = true, latency = { remotes = 0.05 } })
		local s1 = w:server()
		local net = w:remotes(s1)
		net:channel("pre_ch", false)
		net:rpc("pre_rpc")
		local c1, c2 = s1:client(501), s1:client(502)
		eq(net:client(501), c1)
		c1.run.Heartbeat:Connect(function() end)
		w:step(0.05)
		eq({ c1.run.IsServer(), c1.run.IsClient(), c1.run.IsStudio() }, { false, true, false })
		sert(c1.host.unixTime() >= 1.7e9 and type(c1.host.random()) == "number")

		-- Raw remotes before env(), FIFO clamping vs unreliable reordering
		local rawGot = {}
		net.remotes.reliable.OnServerEvent:Connect(
			function(plr, tbl) table.insert(rawGot, { plr = plr, v = tbl.v }) end
		)
		c1.remotes.reliable:FireServer({ v = 10 })
		local savedUid = c1.player.UserId
		c1.player.UserId = "non-num" :: any
		net.remotes.reliable:FireClient(c1.player, { v = 20 })
		c1.player.UserId = savedUid
		w:run(0.1)
		eq(#rawGot, 1)

		local relOrd, unrelOrd = {}, {}
		net:channel("f_rel", false)
		net:channel("f_unrel", true)
		c1.remotes.f_rel.OnClientEvent:Connect(function(t) table.insert(relOrd, t) end)
		c1.remotes.f_unrel.OnClientEvent:Connect(function(t) table.insert(unrelOrd, t) end)
		w.fixed.remotes = 0.5
		net.remotes.f_rel:FireClient(c1.player, 1)
		net.remotes.f_unrel:FireClient(c1.player, 1)
		w.fixed.remotes = 0.1
		net.remotes.f_rel:FireClient(c1.player, 2)
		net.remotes.f_unrel:FireClient(c1.player, 2)
		w:run(0.6)
		eq({ relOrd, unrelOrd }, { { 1, 2 }, { 2, 1 } })
		w.fixed.remotes = 0.05

		local cenv1 = c1:env()
		local senv = s1:env()
		local cenv2 = c2:env()
		s1.players.peers[501] = nil
		c1.remotes.reliable:FireServer({ v = 40 })
		w:run(0.1)

		-- Model PrimaryPart, Instance attributes, dynamic remote rename, foreign instance filtering
		local model = senv.Instance.new("Model")
		model.Name = "Rig"
		local rPart = senv.Instance.new("Part", model)
		rPart.Name = "HumanoidRootPart"
		model.PrimaryPart = rPart
		model:SetAttribute("Ref", rPart)
		model.Parent = senv.workspace
		local cliModel = cenv1.workspace:FindFirstChild("Rig")
		eq(cliModel.PrimaryPart, cliModel:FindFirstChild("HumanoidRootPart"))
		eq(cliModel:GetAttribute("Ref"), cliModel.PrimaryPart)
		eq(model:Clone().PrimaryPart.Name, "HumanoidRootPart")
		rPart:Destroy()

		-- Mounted & DataModel path translation, UnreliableRemoteEvent, RemoteFunction, disconnect
		local srvMnt = senv.Instance.new("Folder")
		rawset(srvMnt, "_mountPath", "Shared/Mod")
		senv._mountedByPath = { ["Shared/Mod"] = srvMnt }
		local cliMnt = cenv1.Instance.new("Folder")
		rawset(cliMnt, "_mountPath", "Shared/Mod")
		cenv1._mountedByPath = { ["Shared/Mod"] = cliMnt }
		local srvSun = senv.Instance.new("Folder", senv.game:GetService("Lighting"))
		srvSun.Name = "Sun"
		local cliSun = cenv1.Instance.new("Folder", cenv1.game:GetService("Lighting"))
		cliSun.Name = "Sun"

		local urem = senv.Instance.new("UnreliableRemoteEvent", senv.game.ReplicatedStorage)
		urem.OnServerEvent:Connect(function() end)
		urem.Name = "FastPing"
		local cliUrem1 = cenv1.game.ReplicatedStorage:FindFirstChild("FastPing")
		cliUrem1.OnClientEvent:Connect(function() end)
		c1:spawn(
			function()
				cliUrem1:FireServer(
					buffer.fromstring("b"),
					cenv1.globals.Vector3.new(1, 2, 3),
					cliMnt,
					cliSun,
					cenv1.Instance.new("Part"),
					setmetatable({ a = 1 }, {})
				)
			end
		)
		s1:spawn(function()
			urem:FireClient({ UserId = 501 }, "direct")
			urem:FireAllClients("bcast")
		end)
		w:run(0.2)
		w.faults.drop = 1
		c1:spawn(function() cliUrem1:FireServer("drop") end)
		w:run(0.2)
		w.faults.drop = 0

		local rawW = Sim.new({ wait = "instant" })
		local rawSrv = rawW:server()
		local rawNet = rawW:remotes(rawSrv)
		local rawC1, rawC2 = rawSrv:client(1), rawSrv:client(2)
		local rawGot1, rawGot2: any = nil, nil
		rawC1.remotes.reliable.OnClientEvent:Connect(function(tbl)
			tbl.mutated = true
			rawGot1 = tbl.x
		end)
		rawC2.remotes.reliable.OnClientEvent:Connect(function(tbl) rawGot2 = tbl.mutated end)
		rawNet.remotes.reliable:FireAllClients({ x = 7 })
		rawW:step(0.1)
		eq({ rawGot1, rawGot2 }, { 7, nil })

		local rf = senv.Instance.new("RemoteFunction", senv.game.ReplicatedStorage)
		rf.Name = "CalcRpc"
		local cliRf1, cliRf2 =
			cenv1.game.ReplicatedStorage:FindFirstChild("CalcRpc"),
			cenv2.game.ReplicatedStorage:FindFirstChild("CalcRpc")
		c1:spawn(function() cliRf1:InvokeServer("hi") end)
		s1:spawn(function() rf:InvokeClient(c1.player, "hi") end)
		w:run(0.2)
		rf.OnServerInvoke = function(plr, mnt) return plr.UserId, mnt end
		cliRf1.OnClientInvoke = function(mnt, x) return x * 2, mnt end
		c1:spawn(function() cliRf1:InvokeServer(cliMnt) end)
		s1:spawn(function() rf:InvokeClient(c1.player, srvMnt, 21) end)
		w:run(0.3)

		rf.OnServerInvoke = function()
			c2:leave()
			return 1
		end
		w.scheduler:spawn(nil, function() pcall(cliRf2.InvokeServer, cliRf2) end)
		w:run(0.3)
		c2:leave()
		fails(function() cliRf2:InvokeServer() end, "peer disconnected")
		fails(function() rf:InvokeClient(c2.player) end, "player disconnected")

		cliRf1.OnClientInvoke = function()
			c1:leave()
			return 1
		end
		s1:spawn(function() pcall(rf.InvokeClient, rf, c1.player) end)
		w:run(0.3)
		local c3 = s1:client(503)
		w.fixed.remotes = 1
		c3.remotes.reliable:FireServer("in-flight")
		s1:crash()
		eq(c3.gone, true)

		-- Mounted child resolution, pre-existing child sync, instant remotes & thread spawn/defer
		local wi = Sim.new({ wait = "instant" })
		local si = wi:server()
		local netI = wi:remotes(si)
		local sEnvI = si:env()
		local srvRS = sEnvI.game:GetService("ReplicatedStorage")
		local srvPkg = sEnvI.Instance.new("ModuleScript", srvRS)
		srvPkg.Name = "MountedPkg"
		rawset(srvPkg, "_mountPath", "Shared/MountedPkg")
		rawset(srvPkg, "_loader", function() return "loaded" end)
		rawset(srvPkg, "_factory", function() return "factory" end)
		sEnvI._mountedByPath["Shared/MountedPkg"] = srvPkg
		local firstCh = sEnvI.Instance.new("ObjectValue", srvRS)
		firstCh.Name = "First"
		local secCh = sEnvI.Instance.new("Part", srvRS)
		secCh.Name = "Second"
		firstCh.Value = secCh
		firstCh:SetAttribute("Ref", secCh)

		local ci1 = si:client(801)
		local cEnvI = ci1:env()
		local cliRS = cEnvI.game:GetService("ReplicatedStorage")
		local preEx = cEnvI.Instance.new("Folder", cliRS)
		preEx.Name = "PreEx"
		preEx:SetAttribute("Stale", 1)
		preEx:AddTag("StaleTag")
		local srvPre = sEnvI.Instance.new("Folder")
		srvPre.Name = "PreEx"
		srvPre:SetAttribute("A", 10)
		srvPre:AddTag("T1")
		srvPre.Parent = srvRS
		eq(
			{ preEx:GetAttribute("A"), preEx:GetAttribute("Stale"), preEx:HasTag("T1"), preEx:HasTag("StaleTag") },
			{ 10, nil, true, false }
		)

		local dynF = sEnvI.Instance.new("Folder")
		dynF.Name = "LazySub"
		rawset(dynF, "_parent", srvPkg)
		rawset(srvPkg, "_children", { dynF })
		local cliPkg = cliRS:FindFirstChild("MountedPkg")
		eq(cEnvI._resolveMountedServerChild(cliPkg, "LazySub").Name, "LazySub")
		eq(cEnvI._resolveMountedServerChild(cliPkg, "Missing"), nil)

		sEnvI.task.spawn(coroutine.create(function() end))
		sEnvI.task.defer(coroutine.create(function() end))
		wi:step()
		fails(function()
			sEnvI.task.spawn(coroutine.create(function() error("boom", 0) end))
		end, "boom")
		local simDs = sEnvI.game:GetService("DataStoreService"):GetDataStore("CacheInv")
		local v1 = simDs:SetAsync("k", "a")
		local v2 = simDs:SetAsync("k", "b")
		simDs:RemoveVersionAsync("k", v2)
		eq((simDs:GetAsync("k")), "a")
		simDs:RemoveVersionAsync("k", v1)
		eq((simDs:GetAsync("k")), nil)

		netI.remotes.reliable.OnServerEvent:Connect(function() end)
		ci1.remotes.reliable:FireServer("sync")
		wi.fixed.remotes = 0.5
		ci1.remotes.reliable:FireServer("delayed")
		wi:step(0.5)
		sEnvI:removePlayer(801)
		si:crash()

		-- Coop
		local cKeep = Coop.new(nil, true, { now = 10 })
		cKeep.now = 12
		cKeep.onWait = function() end
		cKeep.hooks.spawn(function()
			coroutine.yield()
			cKeep.hooks.defer(function() end)
		end)
		cKeep:spawn(function() end)
		cKeep.hooks.wait(3)
		fails(function()
			cKeep.hooks.spawn(function() error("coop-boom", 0) end)
		end, "coop-boom")

		-- Sim.prop, Sim.model, Sim.explore
		Sim.prop(function(wp, g)
			wp:server():env().task.wait(0.1)
			sert(g:int(1, 5) >= 1)
		end, { runs = 2 })
		Sim.prop(
			"named-prop",
			function(wp) eq(wp.placeId, 42) end,
			{ runs = 1, seed = 7, world = { tapeChoices = false, placeId = 42, faults = "none", mode = "manual" } }
		)
		fails(function()
			Sim.prop(function(wp)
				wp:server():spawn(function() error("p-boom", 0) end)
			end, { runs = 1 })
		end, "Sim.prop: unhandled scheduler error")
		fails(function()
			Sim.prop(function(wp) wp:server():env().game:GetService("RunService").Heartbeat:Wait() end, { runs = 1 })
		end, "on the test's own thread")

		Sim.model({
			name = "m",
			init = function() return { c = 0 }, { b = 0 } end,
			commands = {
				{
					name = "add",
					gen = function(g) return g:int(1, 2) end,
					pre = function(st) return st.c < 10 end,
					run = function(sut, arg, wm)
						wm:step()
						sut.b += arg
						return sut.b
					end,
					next = function(st, arg)
						st.c += arg
					end,
					post = function(st, sut, arg, res) eq({ sut.b, res }, { st.c + arg, sut.b }) end,
				},
			},
			invariant = function(st, sut) eq(st.c, sut.b) end,
			converge = function() end,
			teardown = function() end,
		}, { runs = 2, length = 2, seed = 1 })

		fails(function()
			Sim.model({
				world = { faults = "none" },
				init = function() return { c = 0 } end,
				commands = {
					inc = {
						gen = function(g) return g:int(1, 5) end,
						run = function(sut, arg, wm)
							wm:step()
							sut.c += arg
							assert(sut.c < 3, "overflow")
						end,
					},
				},
			}, { runs = 10, length = 5 })
		end, "overflow")

		local refusing = {
			init = function() return {}, {} end,
			commands = {
				{ name = "refuse", weight = 1000, pre = function() return false end, run = function() end },
				{ name = "ok", run = function() end },
			},
		}
		fails(function() Sim.model(refusing, { runs = 3, length = 3, seed = 1 }) end, "pre refused every step")
		Sim.model(refusing, { runs = 2, length = 2, seed = 1, redraw = true })

		fails(function()
			Sim.model({
				init = function() return {} end,
				commands = {
					b = {
						run = function(_, _, wm)
							wm:server():spawn(function() error("m-boom", 0) end)
						end,
					},
				},
			}, { runs = 10, length = 1 })
		end, "Sim.model: unhandled scheduler error")
		fails(function()
			Sim.model({
				init = function() return {} end,
				commands = { n = { run = function() end } },
				teardown = function() error("td-boom", 0) end,
			}, { runs = 1, length = 1 })
		end, "td-boom")

		Sim.explore("exp-2", function(we) we:step() end)
		sert.capture(function()
			Sim.explore("exp-3", function(we)
				we.scheduler:choose(3, "a")
				we.scheduler:choose(3, "b")
			end, { maxRuns = 2 })
		end)
		local function pathBody(we)
			if we.scheduler:choose(3, "a") == 2 and we.scheduler:choose(3, "b") == 2 then error("found it", 0) end
		end
		fails(function() Sim.explore(pathBody) end, "replay = { 2, 2 }")
		fails(function() Sim.explore(pathBody, { replay = { 2, 2 } }) end, "Sim.explore failed on replay")
		Sim.explore(pathBody, { replay = { 1, 1 } })

		for _, bad in
			{
				function()
					Sim.prop(function() end, { faults = "none" })
				end,
				function()
					Sim.prop(function() end, { world = { fualts = "heavy" } })
				end,
				function()
					Sim.model({ init = function() end, commands = {}, runs = 3 })
				end,
				function()
					Sim.model({ init = function() end, commands = {} }, { steps = 3 })
				end,
				function()
					Sim.model({ init = function() end, commands = {}, world = { seed = 1 } })
				end,
				function()
					Sim.explore(function() end, { world = { tapeChoices = false } })
				end,
				function()
					Sim.explore(function() end, { runs = 2 })
				end,
			}
		do
			fails(bad)
		end

		local savedMut = mutant.get()
		local isoOk, isoErr = sert.isolate(function()
			mutant.set(savedMut)
			Sim.prop("reg-prop", function(wp) wp:step() end, { runs = 1, file = "Wanted" })
			Sim.model(
				"reg-model",
				{ init = function() return {} end, commands = { n = { run = function() end } } },
				{ runs = 1, length = 1, file = "Wanted" }
			)
			Sim.explore("reg-explore", function(we) we:step() end, { maxRuns = 1, file = "Wanted" })
			eq(sert.run({ silent = true, failFast = false }).passed, 3)
		end)
		assert(isoOk, tostring(isoErr))

		-- RunService phases, util.copy, format.json, DataStore standalone, geometry
		local wrs = World.new()
		local rsSrv = wrs:server()
		local rsCli = rsSrv:client(1)
		local rsLog = {}
		for _, ph in Sim.services.run_service.SERVER_PHASES do
			rsSrv.host.RunService[ph]:Connect(function() table.insert(rsLog, `s:{ph}`) end)
		end
		for _, ph in Sim.services.run_service.CLIENT_PHASES do
			rsCli.host.RunService[ph]:Connect(function() table.insert(rsLog, `c:{ph}`) end)
		end
		wrs:step()
		eq(#rsLog, 12)

		-- util.copy
		eq(buffer.tostring(copy(buffer.fromstring("bytes"))), "bytes")
		local inner = { 1, 2 }
		local cyc: any = { inner = inner, list = { inner }, [{ k = 1 }] = "v" }
		cyc.self = cyc
		local cOut = copy(cyc)
		eq(cOut.list[1] == cOut.inner and cOut.self == cOut, true)
		local metaObj = setmetatable({ a = 1 }, { __index = {} })
		eq(copy({ metaObj })[1], metaObj)
		eq(getmetatable(copy(metaObj, { keepMetatables = false })), nil)
		eq(copy({ drop = inner, keep = 1 }, { map = function(v) return v == inner, nil end }), { keep = 1 })
		local deep: any = {}
		local cur = deep
		for _ = 1, 8 do
			cur.next = {}
			cur = cur.next
		end
		fails(function() copy(deep, { depth = 3 }) end, "exceeds 3 levels")
		sert(copy(deep, { depth = 3, overflow = table.clone }) ~= nil)

		-- format.json & HttpService
		eq(format.json(0 / 0), "null")
		eq(format.json({ [1] = "x", [3] = "z" }, { strict = true }), '["x",null,"z"]')
		eq(format.json({}, { strict = true }), "[]")
		fails(function() format.json(math.huge, { strict = true }) end, "non-finite")
		-- selene: allow(mixed_table)
		fails(function() format.json({ 1, x = 2 }, { strict = true }) end, "mixed")
		fails(function() format.json(buffer.create(1), { strict = true }) end, "buffer")
		fails(function() format.json(print, { strict = true, prefix = "P: " }) end, "P: can't convert a function")
		eq(
			format.jsonDecode('{"a":[1,{"b":null}],"s":"x\\n\\u00e9\\uD83D\\uDE00"}'),
			{ a = { 1, {} }, s = "x\né😀" }
		)
		eq(format.jsonDecode('{"tag":1}', { revive = function(o) return if o.tag then "rev" else o end }), "rev")
		fails(function() format.jsonDecode("[1,", { prefix = "Q: " }) end, "Q: invalid JSON")
		local Http = Doubles.HttpService.new()
		local enc = Http:JSONEncode({ list = { 1, "two" }, buf = buffer.fromstring("hi") })
		eq(buffer.tostring(Http:JSONDecode(enc).buf), "hi")

		-- Standalone DataStore limits, versions, Listing, budgets, faults
		local now = 100
		local dsMock = Doubles.DataStore.new({ clock = function() return now end })
		for _, bad in
			{
				function() dsMock:GetDataStore("") end,
				function() dsMock:GetDataStore(string.rep("n", 51)) end,
				function() dsMock:GetDataStore("ok", string.rep("s", 51)) end,
			}
		do
			fails(bad)
		end
		dsMock:budget("StandardWrite", nil)
		dsMock:budget("StandardRead", nil)
		local st = dsMock:GetDataStore("Players")
		for _, bad in
			{
				function() st:SetAsync("", 1) end,
				function() st:GetAsync(string.rep("k", 51)) end,
				function() st:SetAsync("k", nil) end,
				function()
					st:SetAsync("bad", function() end)
				end,
				function() st:SetAsync("bad", strictEnv.Instance.new("Folder")) end,
				function() st:SetAsync("bad", strictEnv.globals.Vector3.new()) end,
				function() st:SetAsync("bad", setmetatable({}, {})) end,
				function() st:SetAsync("bad", 0 / 0) end,
				-- selene: allow(mixed_table)
				function() st:SetAsync("bad", { 1, x = 2 }) end,
				function() st:SetAsync("bad", { [true] = 1 }) end,
				function() st:SetAsync("bad", { [1.5] = 1 }) end,
				function() st:SetAsync("bad", { [1] = 1, [3] = 3 }) end,
				function() st:SetAsync("bad", "\255") end,
				function() st:SetAsync("bad", cyc) end,
				function() st:SetAsync("big", string.rep("a", Doubles.DataStore.MAX_VALUE)) end,
			}
		do
			fails(bad)
		end
		local dv1 = st:SetAsync("user_1", "v1", { 101 }, { metadata = { tag = "a" } })
		local _, dinfo1 = st:GetAsync("user_1")
		eq({ dinfo1:GetUserIds(), dinfo1:GetMetadata() }, { { 101 }, { tag = "a" } })
		now = 200
		local dv2 = st:SetAsync("user_1", "v2")
		st:SetAsync("user_2", "v")
		st:RemoveAsync("user_2")
		eq(#st:ListVersionsAsync("user_1", nil, 150000):GetCurrentPage(), 1)
		st:RemoveVersionAsync("user_1", dv2)
		eq((st:GetAsync("user_1")), "v1")
		st:RemoveVersionAsync("user_1", dv1)
		eq((st:GetAsync("user_1")), nil)
		st:SetAsync("user_3", "v")

		local kPages = st:ListKeysAsync("user_", 1)
		kPages:AdvanceToNextPageAsync()
		eq(#st:ListKeysAsync("user_", 10, nil, true):GetCurrentPage(), 1)
		dsMock:GetDataStore("Pets")
		local dListing = dsMock:ListDataStoresAsync("P", 1)
		dListing:AdvanceToNextPageAsync()

		dsMock:budget("StandardWrite", 1, 60)
		st:SetAsync("b1", 1)
		fails(function() st:SetAsync("b2", 2) end, "RequestThrottled")
		now = 260
		st:SetAsync("b2", 2)
		dsMock:budget("StandardWrite", nil)
		dsMock:fail("SetAsync", "boom")
		fails(function() st:SetAsync("f", 1) end, "boom")
		dsMock:fail("SetAsync", nil, true)
		fails(function() st:SetAsync("f", 2) end, "injected failure")
		local rMock = Doubles.DataStore.new({ faults = { before = 0.5, seed = 7 } })
		local rSt = rMock:GetDataStore("R")
		for i = 1, 10 do
			pcall(rSt.SetAsync, rSt, `k{i}`, i)
		end

		-- roblox.geometry
		local ge = sert.env.new()
		local scr = ge.Instance.new("ScreenGui")
		local frm = ge.Instance.new("Frame", scr)
		local ch = ge.Instance.new("Frame", frm)
		eq({ geometry.visible(ch), geometry.visible(ch, { requireDataModel = true }) }, { true, false })
		scr.Parent = ge.game:GetService("StarterGui")
		eq(geometry.visible(ch, { requireDataModel = true }), true)
		scr.Enabled = false
		eq(geometry.visible(ch), false)
		scr.Enabled, frm.Visible = true, false
		eq(geometry.visible(ch, { stopAt = frm }), false)
		frm.Visible = true
		frm.Position, frm.Size, frm.AnchorPoint =
			ge.globals.UDim2.fromOffset(10, 20), ge.globals.UDim2.fromOffset(100, 40), ge.globals.Vector2.new(0.5, 1)
		eq(geometry.rect(frm, true).x - geometry.rect(frm).x, 50)
		local ra = { x = 0, y = 0, width = 10, height = 10 }
		eq({
			geometry.sameRect(ra, { x = 0.4, y = 0, width = 10, height = 10 }),
			geometry.sameRect(ra, { x = 0.6, y = 0, width = 10, height = 10 }, 1),
			geometry.sameRect(ra, { x = 0, y = 0, width = 20, height = 10 }, 1, true),
		}, { true, true, true })
		local wPhases = {}
		geometry.stepper(
			"PreAnimation",
			{ PreAnimation = { Wait = function() table.insert(wPhases, "PreAnimation") end } }
		)()
		eq(wPhases, { "PreAnimation" })

		-- client-to-server remote Instance translation resolves replicated mirrors via _sourceOf even with duplicate sibling names
		local rw = World.new({ wait = "instant" })
		local rs = rw:server()
		local rc = rs:client(1)
		local sEnv, cEnv = rs:env(), rc:env()
		local rem = sEnv.Instance.new("RemoteFunction", sEnv.game.ReplicatedStorage)
		rem.Name = "CheckSibling"
		local firstDup = sEnv.Instance.new("Part", sEnv.workspace)
		firstDup.Name = "DupPart"
		local secondDup = sEnv.Instance.new("Part", sEnv.workspace)
		secondDup.Name = "DupPart"
		rem.OnServerInvoke = function(_plr: any, inst: any) return rawequal(inst, secondDup) end
		local cSecondDup = cEnv._mirrorOf[secondDup]
		local cRem = cEnv.game.ReplicatedStorage:FindFirstChild("CheckSibling")
		eq(cRem:InvokeServer(cSecondDup), true)

		-- strict client replication ignores internal _props keys and preserves client OnClientInvoke callbacks
		local sw = World.new({ wait = "instant" })
		local ss = sw:server()
		local sc = ss:client(1)
		local ssEnv, scEnv = ss:env({ strict = true }), sc:env({ strict = true })
		local sPlr = ss:join(1)
		local sPart = ssEnv.Instance.new("Part", ssEnv.workspace)
		sPart.Name = "ImpulsePart"
		sPart:ApplyImpulse(ssEnv.globals.Vector3.new(1, 2, 3))
		local sRf = ssEnv.Instance.new("RemoteFunction", ssEnv.game.ReplicatedStorage)
		sRf.Name = "ClientPing"
		local cRf = scEnv.game.ReplicatedStorage:FindFirstChild("ClientPing")
		cRf.OnClientInvoke = function(x: number) return x + 10 end
		sPart.Parent = ssEnv.game.ReplicatedStorage
		sRf.Parent = ssEnv.workspace
		eq(sRf:InvokeClient(sPlr, 5), 15)

		-- HapticEffect:Play/Stop and TextChannel:SetDirectChatRequester fire Changed and replicate
		local sHaptic = ssEnv.Instance.new("HapticEffect", ssEnv.workspace)
		sHaptic.Name = "Buzz"
		local cHaptic = scEnv.workspace:FindFirstChild("Buzz")
		local hapticChanges = 0
		cHaptic:GetPropertyChangedSignal("Playing"):Connect(function()
			hapticChanges += 1
		end)
		sHaptic:Play()
		sHaptic:Stop()
		eq({ cHaptic.Playing, hapticChanges }, { false, 2 })

		-- CFrame:Lerp extrapolates outside [0, 1] for overshooting tweens
		local cf0 = ssEnv.globals.CFrame.new(0, 0, 0)
		local cf1 = ssEnv.globals.CFrame.new(10, 0, 0)
		eq({ cf0:Lerp(cf1, -0.5).Position.X, cf0:Lerp(cf1, 1.5).Position.X }, { -5, 15 })

		-- Finding #5: block DataModel name-path spoofing for un-mirrored instances under replicated roots & server-only services
		local spoofSrvPart = sEnv.Instance.new("Part", sEnv.game:GetService("ServerStorage"))
		spoofSrvPart.Name = "Secret"
		local spoofCliSecret = cEnv.Instance.new("Part", cEnv.game:GetService("ServerStorage"))
		spoofCliSecret.Name = "Secret"
		local spoofCliLocal = cEnv.Instance.new("Part", cEnv.workspace)
		spoofCliLocal.Name = "DupPart"
		rem.OnServerInvoke = function(_plr: any, a: any, b: any, c: any, d: any)
			return { a ~= nil, b ~= nil, c == sEnv.workspace, d == sEnv.game:GetService("ServerStorage") }
		end
		eq(
			cRem:InvokeServer(spoofCliSecret, spoofCliLocal, cEnv.workspace, cEnv.game:GetService("ServerStorage")),
			{ false, false, true, false }
		)

		-- Finding #6: wait="instant" steps client RunService & coarse=true consolidates client RunService + remotes flush
		local instCliBeats = 0
		rc.host.RunService.Heartbeat:Connect(function()
			instCliBeats += 1
		end)
		rw:step(0.1)
		eq(instCliBeats, 1)

		local cRec = Scheduler.record(Scheduler.seeded(1))
		local cw = World.new({
			scheduler = Scheduler.new({ seed = 1, random = true, chooser = cRec }),
			mode = "random",
			coarse = true,
			faults = "none",
		})
		local cs = cw:server()
		local cc = cs:client(1)
		local coarseOrder = {}
		cs.host.RunService.Heartbeat:Connect(function() table.insert(coarseOrder, "s") end)
		cc.host.RunService.Heartbeat:Connect(function() table.insert(coarseOrder, "c") end)
		cc.remotes.reliable.OnClientEvent:Connect(function(v: any) table.insert(coarseOrder, v) end)
		cs.host.remotes.reliable:FireAllClients("pkt")
		cw:step(0.5)
		eq(coarseOrder, { "s", "c", "pkt" })
		eq(#cRec.choices, 2) -- only server skew + remotes latency, no per-frame hook shuffle choice

		-- Finding #14: World.new validates option keys
		fails(function() World.new({ instant = true } :: any) end, "World.new: unknown option instant")

		-- Finding #15: Sim.model converge = false skips world:converge()
		local convRan = false
		Sim.model({
			init = function() return {} end,
			commands = {
				step = {
					run = function(_, _, wm)
						local s = wm:server()
						s.host.RunService.Heartbeat:Connect(function() convRan = true end)
					end,
				},
			},
			converge = false,
		}, { runs = 1, length = 1 })
		eq(convRan, false)

		-- Finding #16: gate:release(n) skips crashed threads and releases n live threads
		local gw = World.new()
		local gs1, gs2 = gw:server(), gw:server()
		local g = gw:hold("DataStoreService", "GetAsync")
		local gDone = 0
		gs1:spawn(function() gs1.host.DataStoreService:GetDataStore("G"):GetAsync("k") end)
		gs2:spawn(function()
			gs2.host.DataStoreService:GetDataStore("G"):GetAsync("k")
			gDone += 1
		end)
		gw:step()
		eq(#g.waiting, 2)
		gs1:crash()
		g:release(1)
		gw:step()
		eq(gDone, 1)

		-- World.runUntil in wait = "instant" mode steps RunService/hooks and enforces limit
		local iw = World.new({ wait = "instant" })
		local isrv = iw:server()
		local iBeats = 0
		isrv.host.RunService.Heartbeat:Connect(function()
			iBeats += 1
		end)
		eq(iw:runUntil(function() return iBeats >= 3 end), true)
		eq(iBeats, 3)
		eq(iw:runUntil(iw.scheduler.now + 0.25), true)
		eq(iw:runUntil(function() return false end, 0.2), false)

		-- server:spawn and client:spawn bind _ENV, World.converge restores faults on error, and Sim.model preserves array order & opts.size
		if (setfenv :: any) ~= nil then
			local envW = World.new()
			local envS = envW:server()
			local envC = envS:client(1)
			local srvPlaceId, cliIsClient
			envS:spawn(function() srvPlaceId = game.PlaceId end)
			envC:spawn(function() cliIsClient = game:GetService("RunService"):IsClient() end)
			envW:step()
			eq({ srvPlaceId, cliIsClient }, { envW.placeId, true })
		end

		local faultW = World.new({ faults = "light" })
		faultW:server()
		local beforeBefore = faultW.faults.before
		fails(function()
			faultW:converge(function() error("proj-boom", 0) end)
		end, "proj-boom")
		eq(faultW.faults.before, beforeBefore)

		local maxListLen = 0
		Sim.model({
			init = function() return {} end,
			commands = {
				{
					name = "z_first",
					gen = function(g)
						local lst = g:list(function(gi) return gi:int(1, 2) end)
						if #lst > maxListLen then maxListLen = #lst end
						return #lst
					end,
					run = function() end,
				},
			},
		}, { runs = 5, length = 2, size = 3, seed = 1 })
		sert(maxListLen <= 3)

		-- InvokeServer/InvokeClient run on target peer's coroutine, net.leave cleans up net.clients,
		-- Players.join respects userNames, Players.leave unparents after PlayerRemoving, Runner.describe handles cycles,
		-- and Sim.model teardown runs inside guarded()
		local rpcW = World.new({ latency = { remotes = 0.05 } })
		local rpcSrv = rpcW:server()
		local rpcCli = rpcSrv:client(77)
		local rpcSEnv, rpcCEnv = rpcSrv:env(), rpcCli:env()
		local rpcRf = rpcSEnv.Instance.new("RemoteFunction", rpcSEnv.game.ReplicatedStorage)
		rpcRf.Name = "PeerOwnerRpc"
		local cliRpcRf = rpcCEnv.game.ReplicatedStorage:FindFirstChild("PeerOwnerRpc")
		local invokeOwner: any = nil
		rpcRf.OnServerInvoke = function(_plr: any, x: number)
			invokeOwner = rpcW.scheduler.owners[coroutine.running()]
			rpcSEnv.task.wait(0.05)
			return x + 1
		end
		local rpcOut: number? = nil
		rpcCli:spawn(function() rpcOut = cliRpcRf:InvokeServer(41) end)
		rpcW:run(0.3)
		eq(rpcOut, 42)
		eq(invokeOwner, rpcSrv)

		local pLeaveParent: any = nil
		rpcSEnv.game:GetService("Players").PlayerRemoving:Connect(function(p) pLeaveParent = p.Parent end)
		rpcCli:leave()
		rpcW.scheduler:drain()
		eq(pLeaveParent, rpcSEnv.game:GetService("Players"))
		eq(rpcCli.player.Parent, nil)
		eq(#rpcSrv._net.clients, 0)

		local namedW = World.new()
		local namedSrv = namedW:server()
		local namedSEnv = namedSrv:env()
		local addedName: string? = nil
		namedSEnv.game:GetService("Players").PlayerAdded:Connect(function(p) addedName = p.Name end)
		local namedPlr = namedSEnv:addPlayer(901, "CustomName")
		namedW.scheduler:drain()
		eq(addedName, "CustomName")
		eq(namedPlr.Character ~= nil, true)

		local cycDesc: any = { a = 1 }
		cycDesc.self = cycDesc
		sert.contains(Runner.describe(cycDesc), "<cycle>")

		fails(function()
			Sim.model({
				init = function() return {} end,
				commands = { nop = { run = function() end } },
				teardown = function(_sut, _st, wm)
					wm:server():spawn(function() error("teardown-sched-err", 0) end)
				end,
			}, { runs = 1, length = 1 })
		end, "Sim.model: unhandled scheduler error: teardown-sched-err")
	end
)

test(
	"vopr · 7 distributed hazards (lost reply, late write, re-transform, stale read, clock drift, server crash, MemoryStore eviction), swarm matrix, and TLA+-style Spec/Trace refinement",
	function()
		-- #1 Writes that land and lose their reply + #2 Writes that land late (both via timeout and after server crash)
		local w = World.new({ latency = { DataStoreService = 0.2, MemoryStoreService = 0.2 } })
		local s1, s2 = w:server({ skew = 0 }), w:server({ skew = 0 })
		local ds1 = s1.host.DataStoreService:GetDataStore("Players")
		local ds2 = s2.host.DataStoreService:GetDataStore("Players")
		local rawPlayers = w.datastore.mock:GetDataStore("Players")

		-- #2a: Server s1 sends SetAsync("p1", "from-dead-s1") and crashes while the write is in flight;
		-- the write still lands late after s1 is gone!
		s1:spawn(function() ds1:SetAsync("p1", "from-dead-s1") end)
		w:run(0.05) -- request is in flight (latency = 0.2s)
		s1:crash()
		eq(s1.state, "crashed")
		eq((rawPlayers:GetAsync("p1", { UseCache = false })), nil) -- not landed yet
		w:run(1) -- tail delay elapses on cloud timeline
		eq((rawPlayers:GetAsync("p1", { UseCache = false })), "from-dead-s1")

		-- #2b: Scripted "late" fault throws a timeout to the caller while the write lands in the background
		w:fail("DataStoreService", "SetAsync", "late")
		local lateErr: any = nil
		s2:spawn(function()
			local ok, err = pcall(function() ds2:SetAsync("p1", "late-after-timeout") end)
			if not ok then lateErr = err end
		end)
		w:run(0.25)
		sert.contains(tostring(lateErr), "connection lost")
		w:run(1)
		eq((rawPlayers:GetAsync("p1", { UseCache = false })), "late-after-timeout")

		-- #2c: UpdateAsync in-flight crash still lands its CAS write after server crashes
		local s1b = s1:restart()
		local ds1b = s1b.host.DataStoreService:GetDataStore("Players")
		s1b:spawn(function()
			ds1b:UpdateAsync("cas_crash", function() return "cas-from-crashed-server" end)
		end)
		w:run(0.05)
		s1b:crash()
		w:run(1)
		eq((rawPlayers:GetAsync("cas_crash", { UseCache = false })), "cas-from-crashed-server")

		-- #3: Transforms that run again after their call already answered (DataStore & MemoryStore)
		local transformCalls = 0
		w:fail("DataStoreService", "UpdateAsync", "retransform")
		local firstAnswer: any = nil
		s2:spawn(function()
			firstAnswer = ds2:UpdateAsync("counter", function(old)
				transformCalls += 1
				return (old or 0) + 10
			end)
		end)
		w:run(0.65)
		eq(firstAnswer, 10)
		w:run(1) -- late post-answer re-transform executes!
		eq(transformCalls, 2)
		eq((rawPlayers:GetAsync("counter", { UseCache = false })), 20)

		local msTransformCalls = 0
		local msMap = s2.host.MemoryStoreService:GetHashMap("Locks")
		w:fail("MemoryStoreService", "UpdateAsync", "retransform")
		local msFirst: any = nil
		s2:spawn(function()
			msFirst = msMap:UpdateAsync("lock1", function(old)
				msTransformCalls += 1
				return (old or 0) + 1
			end, 60)
		end)
		w:run(0.65)
		eq(msFirst, 1)
		w:run(1)
		eq(msTransformCalls, 2)
		eq(w.memory:GetHashMap("Locks"):GetAsync("lock1"), 2)

		-- #4: Reads that give back old data (even with UseCache = false, GetSortedAsync, ListKeysAsync, MemoryStore)
		s2:spawn(function()
			ds2:SetAsync("verKey", "v1")
			ds2:SetAsync("verKey", "v2")
		end)
		w:run(1.5)
		eq((rawPlayers:GetAsync("verKey", { UseCache = false })), "v2")
		w:fail("DataStoreService", "GetAsync", "stale")
		local staleVal: any = nil
		s2:spawn(function() staleVal = ds2:GetAsync("verKey", { UseCache = false }) end)
		w:run(0.6)
		eq(staleVal, "v1")

		local ods = s2.host.DataStoreService:GetOrderedDataStore("Board")
		s2:spawn(function()
			ods:SetAsync("u1", 10)
			ods:SetAsync("u1", 99)
		end)
		w:run(1.5)
		w:fail("DataStoreService", "GetSortedAsync", "stale")
		local stalePages: any = nil
		s2:spawn(function() stalePages = ods:GetSortedAsync(false, 10):GetCurrentPage() end)
		w:run(0.6)
		eq(stalePages[1].value, 10)

		local smap = s2.host.MemoryStoreService:GetSortedMap("Rank")
		s2:spawn(function()
			smap:SetAsync("k1", "first", 60, 1)
			smap:SetAsync("k1", "second", 60, 2)
		end)
		w:run(1.5)
		w:fail("MemoryStoreService", "GetAsync", "stale")
		local msStale: any = nil
		s2:spawn(function() msStale = smap:GetAsync("k1") end)
		w:run(0.6)
		eq(msStale, "first")

		w:fail("MemoryStoreService", "GetRangeAsync", "stale")
		local msStaleRange: any = nil
		s2:spawn(function() msStaleRange = smap:GetRangeAsync("Ascending", 10) end)
		w:run(0.6)
		eq(msStaleRange[1].value, "first")

		-- #5: Clocks that are off from each other (dynamic drift, client skew, fresh restart skew)
		local beforeUnix = s2.host.unixTime()
		w:fail("DataStoreService", "GetAsync", "drift")
		s2:spawn(function() ds2:GetAsync("verKey", { UseCache = false }) end)
		w:run(0.6)
		eq(s2.skew, 5)
		sert(s2.host.unixTime() > beforeUnix + 4)
		local cliSkewed = s2:client(303, { skew = -12 })
		eq(cliSkewed.host.unixTime() - w:unix(), -12)
		cliSkewed:drift(20)
		eq(cliSkewed.host.unixTime() - w:unix(), 8)

		-- #6: Servers that crash between any two steps (yield-boundary crash + autoRestart + maybeCrashStep)
		local wCrash = World.new({ mode = "random", seed = 9, faults = "vopr" })
		sert(wCrash.swarm == true and wCrash.autoRestart == true)
		sert.contains(wCrash:summary(), "faults profile=vopr (swarm)")
		local builtCount = 0
		local cs1 = wCrash:server({
			build = function()
				builtCount += 1
			end,
		})
		wCrash:fail("DataStoreService", "SetAsync", "crash")
		local crashErr: any = nil
		cs1:spawn(function()
			local ok, err = pcall(function() cs1.host.DataStoreService:GetDataStore("D"):SetAsync("k", 1) end)
			if not ok then crashErr = err end
		end)
		wCrash:run(0.5)
		eq(cs1.state, "crashed")
		eq(builtCount, 1) -- auto-restarted into s1.1 and invoked build(nextServer)
		sert(crashErr ~= nil)

		-- #7: MemoryStore losing things whenever it feels like it (evict & flush)
		local mEvict = w.memory
		mEvict:flush()
		local hm = mEvict:GetHashMap("Sessions")
		hm:SetAsync("userA", { lock = "s2" }, 300)
		hm:SetAsync("userB", { lock = "s2" }, 300)
		local qEvict = mEvict:GetQueue("MatchQueue")
		qEvict:AddAsync("ticket1", 300)
		eq(hm:evict("userA"), "userA")
		eq(hm:GetAsync("userA"), nil)
		eq(qEvict:evict(), true)
		eq(qEvict:GetSizeAsync(false), 0)
		w:fail("MemoryStoreService", "GetSizeAsync", "evict")
		s2:spawn(function() s2.host.MemoryStoreService:GetHashMap("Sessions"):GetSizeAsync() end)
		w:run(0.6)
		eq(hm:GetAsync("userB"), nil) -- spontaneously evicted during call!
		hm:SetAsync("userC", 1, 300)
		mEvict:flush()
		eq(mEvict:stored().values, 0)

		-- TLA+-style Spec-First: 1. Define spec + `never` invariants, 2. Model-check pure spec (`spec:check`),
		-- 3. Translate to Luau + run VOPR + feed output trace back into `spec:verifyTrace` + `spec:toTlaJson`
		local buggyLockSpec = Sim.spec({
			name = "BuggyLeaseLock",
			init = function() return { holder = "none", s1 = false, s2 = false } end,
			actions = {
				s1Acquire = {
					next = function(st)
						st.holder = "s1"
						st.s1 = true
					end,
				},
				-- Bug: s2 steals the lock on expiry without clearing s1's belief!
				s2StealWithoutFencing = {
					guard = function(st) return st.s1 == true end,
					next = function(st)
						st.holder = "s2"
						st.s2 = true
					end,
				},
			},
			never = {
				splitBrain = function(st) return st.s1 and st.s2 end,
			},
		})
		local checkRes = buggyLockSpec:check({ soft = true })
		eq(checkRes.ok, false)
		sert.contains(tostring(checkRes.violation), "never.splitBrain violated")
		eq(#(checkRes.trace :: any), 2)
		fails(function() Sim.checkSpec(buggyLockSpec) end, "never.splitBrain violated")

		-- Fixed fenced-token spec passes `Sim.checkSpec`, runs in `Sim.vopr`, and validates traces
		local fencedSpec = Sim.spec({
			name = "FencedLedger",
			init = function(_world) return { token = 0, committed = 0 }, { token = 0, committed = 0 } end,
			project = function(sut) return { token = sut.token, committed = sut.committed } end,
			actions = {
				advance = {
					gen = function(g) return g:int(1, 3) end,
					guard = function(st, delta) return delta >= 1 and st.committed < 50 end,
					run = function(sut, delta, world)
						local srv = world.servers[1] or world:server()
						if srv.state ~= "up" then srv = srv:restart() end
						sut.token += 1
						local myToken = sut.token
						srv:spawn(function()
							pcall(function()
								srv.host.DataStoreService:GetDataStore("Ledger"):UpdateAsync("acct", function(old)
									if old ~= nil and old.token > myToken then return nil end
									return { token = myToken, committed = sut.committed }
								end)
							end)
						end)
						world:run(0.5)
						sut.committed += delta
						return sut.committed
					end,
					next = function(st, delta)
						st.token += 1
						st.committed += delta
					end,
				},
			},
			never = {
				negativeCommitted = function(st) return st.committed < 0 end,
			},
			invariants = {
				tokenMonotonic = function(st) return st.token >= 0 end,
			},
		})
		Sim.checkSpec("fenced spec check", fencedSpec, { maxStates = 40, maxDepth = 5 })
		Sim.vopr("fenced ledger under vopr", fencedSpec, { runs = 5, length = 4, seed = 11 })

		-- Direct trace verification & TLA+ JSON export
		local manualTrace: { Sim.TraceEntry } = {
			{ action = "advance", arg = 2, state = { token = 1, committed = 2 } },
			{ action = "advance", arg = 3, state = { token = 2, committed = 5 } },
		}
		local finalSpecState = fencedSpec:verifyTrace(manualTrace, { token = 0, committed = 0 })
		eq(finalSpecState, { token = 2, committed = 5 })
		local tlaJson = fencedSpec:toTlaJson(manualTrace, { token = 0, committed = 0 })
		sert.contains(tlaJson, '"spec":"FencedLedger"')
		sert.contains(tlaJson, '"_action":"advance"')
		sert.contains(w:tlaTrace("CustomWorld"), '"spec":"CustomWorld"')

		-- Trace verification catches state divergence when SUT output disagrees with spec
		fails(
			function()
				fencedSpec:verifyTrace({
					{ action = "advance", arg = 2, state = { token = 1, committed = 999 } },
				}, { token = 0, committed = 0 })
			end,
			"state refinement mismatch at step #1"
		)

		-- Outer test-thread yield guard (ON_TEST_THREAD) fires on direct yielding calls
		local wGuard = World.new({ latency = { DataStoreService = 0.2 } })
		local sGuard = wGuard:server()
		fails(function() sGuard.host.DataStoreService:GetDataStore("T"):GetAsync("k") end, "on the test's own thread")

		-- World.converge(project) waits for a 1.2s+ detached late write before returning
		local wConvLate = World.new({ latency = { DataStoreService = 1.5 } })
		local sLate = wConvLate:server()
		local dsLate = sLate.host.DataStoreService:GetDataStore("ConvStore")
		local rawConvStore = wConvLate.datastore.mock:GetDataStore("ConvStore")
		wConvLate:fail("DataStoreService", "SetAsync", "late")
		sLate:spawn(function()
			pcall(function() dsLate:SetAsync("k", "landed-late") end)
		end)
		wConvLate:run(1.6) -- request latency (1.5s) elapsed; detached late write (+1.5s) is now in flight
		eq((rawConvStore:GetAsync("k", { UseCache = false })), nil)
		wConvLate:converge(function() return rawConvStore:GetAsync("k", { UseCache = false }) end)
		eq((rawConvStore:GetAsync("k", { UseCache = false })), "landed-late")

		-- s1:restart() replaces world.servers[1] in place without duplicate 's1.1' servers
		local wSlot = World.new()
		local slotS1 = wSlot:server()
		local slotS1_1 = slotS1:restart()
		eq({ #wSlot.servers, wSlot.servers[1], slotS1_1.name, slotS1.replacedBy }, { 1, slotS1_1, "s1.1", slotS1_1 })
		local slotS1_2 = slotS1:restart()
		eq({ #wSlot.servers, wSlot.servers[1], slotS1_2.name, slotS1_2.restarts }, { 1, slotS1_2, "s1.2", 2 })

		-- Spec.check distinguishes states at depth > 4 and > 10 keys
		local deepWideSpec = Sim.spec({
			name = "DeepWideSpec",
			init = function()
				return {
					k1 = 1,
					k2 = 2,
					k3 = 3,
					k4 = 4,
					k5 = 5,
					k6 = 6,
					k7 = 7,
					k8 = 8,
					k9 = 9,
					k10 = 10,
					k11 = { l1 = { l2 = { l3 = { l4 = { leaf = 0 } } } } },
				}
			end,
			actions = {
				incDeep = {
					guard = function(st) return st.k11.l1.l2.l3.l4.leaf < 3 end,
					next = function(st)
						st.k11.l1.l2.l3.l4.leaf += 1
					end,
				},
			},
			never = {
				reachedThree = function(st) return st.k11.l1.l2.l3.l4.leaf == 3 end,
			},
		})
		local dwRes = deepWideSpec:check({ soft = true })
		eq({ dwRes.ok, dwRes.statesVisited }, { false, 3 })
		sert.contains(tostring(dwRes.violation), "never.reachedThree violated")

		-- Sim.vopr / Sim.model works with a Sim.spec using gen = { 1, 2 } (table candidate array)
		-- and an immutable next(state, arg) returning a new table
		local immutSpec = Sim.spec({
			name = "ImmutableTableGenSpec",
			init = function() return { total = 0 }, { total = 0 } end,
			project = function(sut) return { total = sut.total } end,
			actions = {
				add = {
					gen = { 1, 2 },
					guard = function(st, x) return (x == 1 or x == 2) and st.total < 100 end,
					run = function(sut, x)
						sut.total += x
						return sut.total
					end,
					next = function(st, x) return { total = st.total + x } end,
				},
			},
			invariants = {
				matchesSut = function(st, sut) return st.total == sut.total end,
			},
		})
		Sim.model("immutable spec model", immutSpec, { runs = 4, length = 5, seed = 3 })
		Sim.vopr("immutable spec vopr", immutSpec, { runs = 4, length = 5, seed = 5 })
	end
)

test(
	"remote packet fault injection (drop, duplicate, reorder, latency) and VOPR declarative remotes + replay formatting",
	function()
		-- 1. Synchronous delivery by default (remoteLatencyRange = { 0, 0 }, no faults)
		local wSync = World.new({ mode = "random", seed = 1, faults = "none" })
		local serverLog: { string } = {}
		local clientLogP1: { string } = {}
		local clientLogP2: { string } = {}

		local disconnectServer = wSync:onServerEvent(
			"Purchase",
			function(player, item, qty) table.insert(serverLog, `{player.peerId}:{player.userId}:{item}x{qty}`) end
		)
		local disconnectClient1 = wSync:onClientEvent(
			"peer1",
			"Notify",
			function(msg) table.insert(clientLogP1, msg) end
		)
		wSync:onClientEvent("peer2", "Notify", function(msg) table.insert(clientLogP2, msg) end)

		wSync:fireServer("peer1", "Purchase", "sword", 2)
		eq(serverLog, { "peer1:1:swordx2" })

		wSync:fireClient("peer1", "Notify", "hello-p1")
		eq(clientLogP1, { "hello-p1" })
		eq(clientLogP2, {})

		wSync:fireAllClients("Notify", "broadcast")
		eq(clientLogP1, { "hello-p1", "broadcast" })
		eq(clientLogP2, { "broadcast" })

		disconnectServer()
		disconnectClient1()
		wSync:fireServer("peer1", "Purchase", "shield", 1)
		wSync:fireAllClients("Notify", "after-disconnect")
		eq(serverLog, { "peer1:1:swordx2" })
		eq(clientLogP1, { "hello-p1", "broadcast" })
		eq(clientLogP2, { "broadcast", "after-disconnect" })

		-- 2. remoteDropRate = 1 drops packets and records "remoteDropped" trace event
		local wDrop = World.new({
			mode = "random",
			seed = 2,
			faults = { remoteDropRate = 1 },
		})
		local dropCount = 0
		wDrop:onServerEvent("Ping", function()
			dropCount += 1
		end)
		wDrop:fireServer("p1", "Ping", 123)
		wDrop:flushRemotes()
		eq(dropCount, 0)
		sert.contains(wDrop:summary(), "fireServer Ping from p1")
		sert.contains(wDrop:summary(), "remoteDropped Ping (p1)")

		-- 3. remoteDuplicateRate = 1 delivers each packet twice
		local wDup = World.new({
			mode = "random",
			seed = 3,
			faults = { remoteDuplicateRate = 1 },
		})
		local dupLog: { number } = {}
		wDup:onServerEvent("Claim", function(_player, token) table.insert(dupLog, token) end)
		wDup:fireServer("p1", "Claim", 77)
		eq(dupLog, { 77, 77 })

		-- 4. remoteReorderRate = 1 swaps adjacent packets deterministically on flushRemotes / step
		local wReorder = World.new({
			mode = "random",
			seed = 4,
			faults = { remoteReorderRate = 1 },
		})
		local reorderLog: { string } = {}
		wReorder:onServerEvent("Seq", function(_player, label) table.insert(reorderLog, label) end)
		wReorder:fireServer("p1", "Seq", "first")
		wReorder:fireServer("p1", "Seq", "second")
		wReorder:flushRemotes()
		eq(reorderLog, { "second", "first" })

		-- 5. remoteLatencyRange = { 0.1, 0.2 } queues packets until step(dt) or flushRemotes()
		local wLat = World.new({
			mode = "random",
			seed = 5,
			faults = { remoteLatencyRange = { 0.15, 0.15 } },
		})
		local latLog: { string } = {}
		wLat:onServerEvent("Delayed", function(_player, v) table.insert(latLog, v) end)
		wLat:fireServer("p1", "Delayed", "pkt1")
		eq(latLog, {}) -- still in flight at t=0
		wLat:step(0.05)
		eq(latLog, {}) -- still in flight at t=0.05
		wLat:step(0.15)
		eq(latLog, { "pkt1" }) -- delivered once latency elapses

		wLat:fireServer("p1", "Delayed", "pkt2")
		eq(latLog, { "pkt1" })
		wLat:flushRemotes()
		eq(latLog, { "pkt1", "pkt2" })

		-- 6. Server handler error capture in world.remoteErrors + "remoteError" trace event
		local wErr = World.new({ mode = "random", seed = 6, faults = "none" })
		wErr:onServerEvent("Explode", function(_player, reason) error(`bad payload: {tostring(reason)}`, 0) end)
		wErr:fireServer("p9", "Explode", "nan")
		eq(#wErr.remoteErrors, 1)
		eq(wErr.remoteErrors[1].peerId, "p9")
		eq(wErr.remoteErrors[1].remote, "Explode")
		sert.contains(wErr.remoteErrors[1].err, "bad payload: nan")
		sert.contains(wErr:summary(), "remoteError Explode from p9")

		-- 7. Declarative remotes in Sim.spec + Sim.vopr, allowRemoteErrors, and failure replay snippet
		local okVoprSpec = Sim.spec({
			name = "IdempotentRemoteBank",
			init = function() return { balance = 0, seen = {} } end,
			remotes = {
				Deposit = function(_world, _player, st, txId, amount)
					if type(amount) ~= "number" or amount <= 0 then return end
					if st.seen[txId] then return end
					st.seen[txId] = true
					st.balance += amount
				end,
			},
			actions = {
				sendDeposit = {
					gen = function(g) return g:int(1, 4) end,
					run = function(sut, txId, world)
						world:fireServer("p1", "Deposit", sut, txId, 10)
						world:flushRemotes()
					end,
				},
			},
			invariants = {
				nonNegative = function(st) return st.balance >= 0 and st.balance <= 40 end,
			},
		})
		Sim.vopr("idempotent remote bank under vopr", okVoprSpec, { seed = 12, steps = 6, runs = 5 })

		-- Unhandled remote error fails Sim.vopr unless allowRemoteErrors = true
		local remoteErrorSpec = Sim.spec({
			name = "ExplodingRemoteSpec",
			init = function() return { count = 0 } end,
			remotes = {
				CrashOnServer = function(_world, _player, arg) error(`unvalidated client arg: {tostring(arg)}`, 0) end,
			},
			actions = {
				triggerRemote = {
					gen = { "bad" },
					run = function(_sut, arg, world)
						world:fireServer("peer7", "CrashOnServer", arg)
						world:flushRemotes()
					end,
				},
			},
		})
		local okFail, failMsg = pcall(function() Sim.vopr(remoteErrorSpec, { seed = 42, steps = 3, runs = 5 }) end)
		eq(okFail, false)
		local failStr = tostring(failMsg)
		sert.contains(failStr, "unhandled remote error on CrashOnServer")
		sert.contains(failStr, "remoteErrors:")
		sert.contains(failStr, "trace:")
		sert.contains(failStr, "[t=")
		sert.contains(failStr, "action: triggerRemote")
		sert.contains(failStr, "replay: Sim.vopr(spec, { seed = 42, steps = 3 })")
		sert.contains(failStr, "[1] triggerRemote")

		-- When allowRemoteErrors = true on the spec, remote errors are recorded without failing the VOPR run
		local allowedRemoteErrSpec = Sim.spec({
			name = "AllowedRemoteErrorSpec",
			allowRemoteErrors = true,
			init = function() return { count = 0 } end,
			remotes = {
				CrashOnServer = function() error("expected-fuzz-rejection", 0) end,
			},
			actions = {
				fuzz = {
					run = function(_sut, _arg, world)
						world:fireServer("peer1", "CrashOnServer")
						world:flushRemotes()
					end,
				},
			},
		})
		Sim.vopr(allowedRemoteErrSpec, { seed = 42, steps = 2, runs = 2 })
	end
)

return {}
