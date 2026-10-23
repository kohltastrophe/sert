--!nonstrict
-- sert.model: drawn command sequences against a model, shrinking to a minimal failing sequence, and explicit replays.
local sert = require("../src")
local prop = require("../src/prop")
local gen = sert.gen
local test = sert.test
local expect = sert

local function Stack(capacity: number)
	local self = { items = {} }
	function self.push(v: number)
		if #self.items < capacity then table.insert(self.items, v) end
	end
	function self.pop(): number? return table.remove(self.items) end
	function self.size(): number return #self.items end
	return self
end

local function spec(capacity: number, log: { string }?)
	return {
		init = function() return { items = {} } end,
		setup = function() return Stack(capacity) end,
		teardown = function()
			if log then table.insert(log, "teardown") end
		end,
		invariant = function(state, sut) sert.eq(sut.size(), #state.items, "size") end,
		commands = {
			{
				name = "push",
				weight = 2,
				gen = function(g) return gen.int(0, if g.exhaustive then 1 else 99)(g) end,
				run = function(sut, v) sut.push(v) end,
				next = function(state, v) table.insert(state.items, v) end,
			},
			{
				name = "pop",
				pre = function(state) return #state.items > 0 end,
				run = function(sut) return sut.pop() end,
				post = function(state, _, res) sert.eq(res, state.items[#state.items], "popped") end,
				next = function(state) table.remove(state.items) end,
			},
		},
	}
end

local WHO = { "game", "player", "guest" }
local noisy: sert.ModelSpec = {
	init = function() return { items = {}, paused = false, at = 0 } end,
	setup = function() return { items = {} } end,
	invariant = function(state, sut) sert.eq(#sut.items, #state.items, "size") end,
	commands = {
		{
			name = "push",
			gen = gen.record({ who = gen.pick(WHO), value = gen.int(0, 99) }),
			run = function(sut, arg)
				if #sut.items < 2 then table.insert(sut.items, arg.value) end
			end,
			next = function(state, arg) table.insert(state.items, arg.value) end,
		},
		{
			name = "pause",
			weight = 3,
			gen = gen.record({ who = gen.pick(WHO) }),
			run = function() end,
			next = function(state) state.paused = #state.items > 0 end,
		},
		{
			name = "seek",
			weight = 3,
			gen = gen.record({ who = gen.pick(WHO), to = gen.int(0, 9), fast = gen.bool() }),
			run = function() end,
			next = function(state, arg) state.at = arg.to end,
		},
		{
			name = "pop",
			pre = function(state) return #state.items > 0 end,
			run = function(sut) return table.remove(sut.items) end,
			post = function(state, _, res) sert.eq(res, state.items[#state.items], "popped") end,
			next = function(state) table.remove(state.items) end,
		},
	},
}

test("model · passing, shrinking, replay, command map form, and teardown", function()
	local log = {}
	local okRes = sert.prop.run("stack", sert.model.property(spec(math.huge, log)), { runs = 50 })
	expect(okRes.ok and #log == 50)

	local failLog = {}
	local failRes = sert.prop.run("stack", sert.model.property(spec(2, failLog), { length = 20 }), { runs = 200 })
	expect(not failRes.ok and failLog[#failLog] == "teardown")
	sert.eq(failRes.notes, { '{ "push", 0 },', '{ "push", 0 },', '{ "push", 0 },' })
	expect(string.find(failRes.message, "step 3 (push 0): ", 1, true))
	sert.fails(
		function() sert.model.replay(spec(2), { { "push", 0 }, { "push", 0 }, { "push", 0 } }) end,
		"step 3 (push 0): "
	)

	local state, sut = sert.model.replay(spec(math.huge), {
		{ "push", 1000 },
		{ name = "push", arg = 7 },
		{ "pop" },
	})
	sert.eq(state.items, { 1000 })
	expect(sut.size() == 1)
	sert.fails(function() sert.model.replay(spec(math.huge), { { "pop" } }) end, "step 1 (pop): pre refused it")
	sert.fails(function() sert.model.replay(spec(math.huge), { { "peek" } }) end, 'no command named "peek"')
	local rLog = {}
	sert.fails(function() sert.model.replay(spec(1, rLog), { { "push", 1 }, { "push", 2 } }) end, "step 2")
	sert.eq(rLog, { "teardown" })

	local counter: sert.ModelSpec = {
		init = function() return { n = 0, real = 0 } end,
		commands = {
			inc = {
				run = function(s)
					s.real += if s.real >= 3 then 2 else 1
				end,
				next = function(s)
					s.n += 1
				end,
			},
			reset = {
				weight = 0,
				run = function(s) s.real = 0 end,
				next = function(s) s.n = 0 end,
			},
		},
		invariant = function(s) sert.eq(s.real, s.n, "count") end,
	}
	local cRes = sert.prop.run("counter", sert.model.property(counter), { runs = 100 })
	expect(not cRes.ok and #cRes.notes == 4)
	sert.model.replay(counter, { { "inc" }, { "reset" }, { "inc" } })

	local broken = table.clone(counter)
	broken.teardown = function() error("teardown broke", 0) end
	sert.fails(function() sert.model.replay(broken, { { "reset" } }) end, "teardown: teardown broke")
end)

test("model · shrinking no-op steps, redraw hints, pinned tapes, and shrinkBudget", function()
	local push = `\{ "push", {sert.format.repr({ who = "game", value = 0 })} },`
	for _, redraw in { false, true } do
		for seed = 1, 8 do
			local result = sert.prop.run(
				"noisy",
				sert.model.property(noisy, { length = 30, redraw = redraw }),
				{ runs = 200 },
				{ seed = seed }
			)
			expect(not result.ok and not result.stopped)
			sert.eq(result.notes, { push, push, push })
		end
	end

	local sessions: sert.ModelSpec = {
		init = function() return { at = 0, online = {}, left = {}, stats = {}, lost = false } end,
		invariant = function(s) expect(not s.lost, "a stat was lost") end,
		commands = {
			join = {
				weight = 2,
				gen = gen.record({ user = gen.int(1, 3), server = gen.int(1, 3) }),
				pre = function(s, arg) return s.online[arg.user] == nil end,
				run = function(s, arg)
					local left = s.left[arg.user]
					if left and left.server ~= arg.server and s.at - left.at < 30 and s.stats[arg.user] then
						s.lost = true
					end
					s.online[arg.user] = arg.server
				end,
			},
			leave = {
				gen = gen.record({ user = gen.int(1, 3) }),
				pre = function(s, arg) return s.online[arg.user] ~= nil end,
				run = function(s, arg)
					s.left[arg.user] = { server = s.online[arg.user], at = s.at }
					s.online[arg.user] = nil
				end,
			},
			stat = {
				weight = 2,
				gen = gen.record({ user = gen.int(1, 3), delta = gen.int(1, 5) }),
				pre = function(s, arg) return s.online[arg.user] ~= nil end,
				run = function(s, arg) s.stats[arg.user] = (s.stats[arg.user] or 0) + arg.delta end,
			},
			advance = {
				weight = 2,
				gen = gen.record({ seconds = gen.int(0, 60), salt = gen.int(0, 1e6) }),
				run = function(s, arg)
					s.at += arg.seconds
				end,
			},
			note = {
				weight = 2,
				gen = gen.record({ user = gen.int(1, 3), server = gen.int(1, 3) }),
				run = function() end,
			},
		},
	}
	for seed = 1, 10 do
		local result = sert.prop.run(
			"sessions",
			sert.model.property(sessions, { length = 60, redraw = true }),
			{ runs = 400 },
			{ seed = seed }
		)
		expect(not result.ok)
		local shape = {}
		for _, note in result.notes do
			table.insert(shape, (string.match(note, '^{ "(%a+)"')))
		end
		sert.eq(shape, { "join", "stat", "leave", "join" })
	end

	local pinnedSpec: sert.ModelSpec = {
		init = function() return { items = {} } end,
		commands = {
			{
				name = "push",
				gen = gen.record({ who = gen.pick(WHO), value = gen.int(0, 99) }),
				run = function(s, arg) table.insert(s.items, arg.value) end,
			},
			{ name = "pause", weight = 3, gen = gen.record({ who = gen.pick(WHO) }), run = function() end },
			{ name = "pop", pre = function(s) return #s.items > 0 end, run = function(s) table.remove(s.items) end },
		},
	}
	local pinned = {
		[false] = {
			{ 1, 1, 1, 1, 1, 2, 0 },
			{ 1, 0, 45, 0, 1, 1, 1, 1, 1, 0, 1, 1, 2, 1, 1, 0, 1, 1, 2, 0 },
			{ 1, 1, 1, 1, 1, 0, 1, 1, 1, 1, 2, 1, 1, 0, 1, 0, 41, 0, 1, 2, 0 },
			{ 1, 1, 0, 0 },
			{ 1, 0, 25, 2, 1, 1, 2, 1, 1, 0, 1, 0, 41, 0, 1, 1, 2, 0 },
		},
		[true] = {
			{ 1, 1, 1, 1, 1, 2, 0 },
			{ 1, 0, 45, 0, 1, 1, 1, 1, 1, 0, 1, 1, 2, 1, 1, 0, 1, 1, 2, 0 },
			{ 1, 1, 1, 1, 1, 0, 1, 1, 1, 1, 2, 1, 0, 1, 0, 41, 0, 1, 2, 1, 2, 1, 2, 0 },
			{ 1, 1, 0, 0 },
			{ 1, 0, 25, 2, 1, 1, 2, 1, 1, 0, 1, 0, 41, 0, 1, 1, 2, 0 },
		},
	}
	for _, redraw in { false, true } do
		local property = sert.model.property(pinnedSpec, { length = 8, redraw = redraw })
		local tapes = {}
		local result = sert.prop.run("golden model", function(g)
			property(g)
			table.insert(tapes, prop.tape(g))
		end, { runs = 5 })
		expect(result.ok)
		sert.eq(tapes, pinned[redraw])
	end

	local property = sert.model.property(noisy, { length = 30 })
	local bRes = sert.prop.run(
		"budget",
		property,
		require("../src/model").propOptions({ runs = 200, shrinkBudget = { tries = 5 } })
	)
	expect(not bRes.ok and bRes.attempts == 5 and bRes.stopped)
	expect(string.find(bRes.report, "(5 attempts, stopped by the shrink budget)", 1, true))

	local none = sert.prop.run("budget", property, { runs = 200, shrinkBudget = { seconds = 0 } })
	expect(none.attempts == 0 and none.stopped)
	sert.eq(none.shrunk, none.tape)

	local roomy = sert.prop.run("budget", property, { runs = 200, shrinkBudget = { tries = 10000, seconds = 60 } })
	expect(not roomy.stopped and roomy.attempts < 10000 and not string.find(roomy.report, "stopped", 1, true))
end)

test("model · redraw counts, empty/refusing models, inline execution, and options", function()
	local function counted(redraw: boolean, refuseAll: boolean): (number, number, any)
		local steps, cases = 0, 0
		local redrawSpec: sert.ModelSpec = {
			init = function()
				cases += 1
			end,
			commands = {
				never = { pre = function() return false end, run = function() end },
				ok = {
					pre = function() return not refuseAll end,
					run = function()
						steps += 1
					end,
				},
			},
		}
		local result =
			sert.prop.run("redraw", sert.model.property(redrawSpec, { length = 10, redraw = redraw }), { runs = 100 })
		expect(result.ok or refuseAll)
		return steps, cases, result
	end
	local dropped = counted(false, false)
	local redrawn, cases = counted(true, false)
	expect(cases == 100 and redrawn > dropped * 1.5)
	local steps, _, refused = counted(true, true)
	expect(steps == 0 and not refused.ok)
	sert.eq(refused.message, "pre refused every step in all 100 cases")
	sert.eq(refused.report, 'property "redraw" failed: pre refused every step in all 100 cases')

	sert.fails(function()
		sert.model("empty", { init = function() end, commands = {} })
	end, "sert.model: spec must define commands (or actions)")
	sert.fails(function()
		sert.model.property({ init = function() end, commands = { idle = { weight = 0, run = function() end } } })
	end, "sert.model: no command has a positive weight")
	local refusing: sert.ModelSpec = {
		init = function() end,
		commands = { a = { pre = function() return nil :: any end, run = function() end } },
	}
	sert.eq(
		sert.prop.run("refusing", sert.model.property(refusing), { runs = 20 }).report,
		'property "refusing" failed: pre refused every step in all 20 cases'
	)
	sert.eq(
		sert.prop.run(
			"refusing",
			sert.model.property(refusing, { length = 2 }),
			{ exhaustive = { size = 2 } },
			{ exhaustive = true }
		).message,
		"pre refused every step in all 3 programs"
	)
	expect(sert.prop.run("refusing", sert.model.property(refusing), {}, { replay = 1 }).ok)
	expect(
		sert.prop.run(
			"short",
			sert.model.property({ init = function() end, commands = { a = { run = function() end } } }, { length = 0 }),
			{ runs = 5 }
		).ok
	)

	local runs = 0
	local s: any = spec(math.huge)
	local origInit = s.init
	s.init = function()
		runs += 1
		return origInit()
	end
	sert.model("inline named model", s, { runs = 10, length = 5 })
	expect(runs == 10)
	runs = 0
	s.name = "table model"
	sert.model(s, { runs = 7, length = 4 })
	expect(runs == 7)

	local drawnA, drawnB = {}, {}
	local seededSpec: any = {
		init = function() end,
		commands = {
			step = {
				gen = function(g) return g:int(1, 100000) end,
				run = function(_, n) table.insert(drawnA, n) end,
			},
		},
	}
	sert.model("seeded model", seededSpec, { runs = 2, seed = 98765, length = 3 })
	seededSpec.commands.step.run = function(_, n) table.insert(drawnB, n) end
	sert.model("seeded model", seededSpec, { runs = 2, seed = 98765, length = 3 })
	expect(#drawnA > 0)
	sert.eq(drawnA, drawnB)

	local preCalls = 0
	local cappedSpec: sert.ModelSpec = {
		init = function() end,
		commands = {
			{
				name = "a",
				pre = function()
					preCalls += 1
					return false
				end,
				run = function() end,
			},
			{
				name = "b",
				pre = function()
					preCalls += 1
					return false
				end,
				run = function() end,
			},
			{
				name = "c",
				pre = function()
					preCalls += 1
					return false
				end,
				run = function() end,
			},
			{ name = "zero", weight = 0, pre = function() error("zero weight") end, run = function() end },
		},
	}
	sert.model.property(cappedSpec, { length = 1, redraw = true, maxRedraws = 1 })(prop.gen(1, 10, { 1, 0, 0, 0 }))
	sert.eq(preCalls, 2)

	local allowA, ranCmds = true, {}
	local hintSpec: sert.ModelSpec = {
		init = function() return { allowA = allowA } end,
		commands = {
			{
				name = "cmdA",
				pre = function(st) return st.allowA end,
				run = function() table.insert(ranCmds, "cmdA") end,
			},
			{ name = "cmdB", pre = function() return true end, run = function() table.insert(ranCmds, "cmdB") end },
		},
	}
	local hintProp = sert.model.property(hintSpec, { length = 2, redraw = true })
	local gFirst = prop.gen(1, 10, { 1, 0, 0 })
	hintProp(gFirst)
	sert.eq({ ranCmds, (gFirst :: any)._s.hints }, { { "cmdA" }, {} })

	allowA = false
	table.clear(ranCmds)
	local gRedraw = prop.gen(1, 10, { 1, 0, 0, 0 })
	hintProp(gRedraw)
	sert.eq(ranCmds, { "cmdB" })
	sert.eq((gRedraw :: any)._s.hints, { { first = 2, last = 3, draws = { 1 } } })

	local ok, results = sert.isolate(function()
		sert.model("rtest model", cappedSpec, { rtest = true, runs = 1 })
		sert.model("skipped model", cappedSpec, { skip = true, runs = 1 })
		return sert.run({ silent = true })
	end)
	expect(ok and results.skipped == (if (game :: any) == nil then 2 else 1))

	sert.fails(function()
		sert.model.property({ init = function() end, commands = { { run = function() end } :: any } })
	end, "sert.model: command 1 has no name")

	sert.eq(
		require("../src/model").propOptions({ shrinkBudget = { tries = 5 }, file = "Other", length = 3, redraw = true }),
		{
			shrinkBudget = { tries = 5 },
			file = "Other",
		}
	)

	local sawState = false
	local initial = { tag = "state" }
	sert.model.replay({
		init = function() return initial end,
		commands = { { name = "check", run = function(s2) sawState = (s2 == initial) end } },
	}, { { "check" } })
	expect(sawState)

	sert.fails(function()
		sert.model.replay({
			init = function() return { ok = false } end,
			invariant = function(st) assert(st.ok, "bad initial state") end,
			commands = { { name = "noop", run = function() end } },
		}, {})
	end, "bad initial state")
end)

test(
	"model · unified state-machine contract (actions, guard, table gen, immutable next, never/invariants, Sim.spec)",
	function()
		-- Spec validation and option hints
		sert.fails(
			function() sert.model.property("not a table" :: any) end,
			"sert.model: expected a spec table, got string"
		)
		sert.fails(function()
			sert.model.property({ init = 123 :: any, commands = { a = { run = function() end } } })
		end, "sert.model: spec.init must be a function, got number")
		sert.fails(function()
			sert.model.property({ init = function() end } :: any)
		end, "sert.model: spec must define commands (or actions)")
		sert.fails(function()
			sert.model.property({
				init = function() end,
				commands = { a = { run = function() end } },
				runs = 10,
			} :: any)
		end, "sert.model: unknown spec field runs (an option: pass it in options)")
		sert.fails(function()
			sert.model.property({
				init = function() end,
				commands = { a = { run = function() end } },
				bogus = true,
			} :: any)
		end, "sert.model: unknown spec field bogus")
		sert.fails(function()
			sert.model.property({
				init = function() end,
				commands = { a = { run = function() end, badKey = 1 } :: any },
			})
		end, 'sert.model: command "a" has unknown field badKey')
		sert.fails(function()
			sert.model.property({
				init = function() end,
				commands = { a = "not a table" :: any },
			})
		end, "sert.model: command a must be a table, got string")
		sert.fails(function()
			sert.model.property({
				init = function() end,
				commands = { [123] = { run = function() end } } :: any,
			})
		end, "sert.model: command key must be a string, got number")
		sert.fails(function()
			sert.model.property({
				init = function() end,
				commands = { a = { gen = 42 :: any, run = function() end } },
			})
		end, 'sert.model: command "a" gen must be a function or table, got number')
		sert.fails(function()
			sert.model.property({
				init = function() end,
				commands = { a = {} },
			})
		end, 'sert.model: command "a" must define at least one of run, next, or post')

		-- actions, guard, table gen (candidate list + .draw table), immutable next, never, and invariants
		local sutBox = { value = 0 }
		local unifiedSpec: sert.ModelSpec = {
			init = function() return 0 end,
			setup = function()
				sutBox.value = 0
				return sutBox
			end,
			actions = {
				add = {
					gen = { 1, 2, 3 },
					guard = function(state: number, delta: number) return state + delta <= 6 end,
					run = function(sut, delta: number)
						sut.value += delta
						return sut.value
					end,
					next = function(state: number, delta: number) return state + delta end,
				},
				bonus = {
					gen = { draw = function(g: sert.Gen) return g:int(1, 2) end },
					guard = function(state: number, delta: number) return state + delta <= 6 end,
					run = function(sut, delta: number)
						sut.value += delta
					end,
					next = function(state: number, delta: number) return state + delta end,
				},
			},
			never = {
				overSix = function(state: number) return state > 6 end,
			},
			invariants = {
				matchesSut = function(state: number, sut) return sut.value == state end,
			},
		}
		expect(
			sert.prop.run("unified", sert.model.property(unifiedSpec, { length = 10, redraw = true }), { runs = 40 }).ok
		)
		local finalState, finalSut = sert.model.replay(unifiedSpec, { { "add", 2 }, { "bonus", 1 }, { "add", 3 } })
		sert.eq({ finalState, finalSut.value }, { 6, 6 })
		sert.fails(
			function() sert.model.replay(unifiedSpec, { { "add", 4 }, { "add", 3 } }) end,
			"step 2 (add 3): pre refused it"
		)

		-- never and invariants violations report clearly
		local neverSpec: sert.ModelSpec = {
			init = function() return 0 end,
			actions = {
				step = {
					next = function(s: number) return s + 1 end,
				},
			},
			never = {
				reachedTwo = function(s: number) return s >= 2 end,
			},
		}
		sert.fails(
			function() sert.model.replay(neverSpec, { { "step" }, { "step" } }) end,
			"negative invariant never.reachedTwo violated"
		)

		local invFalseSpec: sert.ModelSpec = {
			init = function() return 0 end,
			actions = {
				step = {
					next = function(s: number) return s + 1 end,
				},
			},
			invariants = {
				staysZero = function(s: number) return s == 0 end,
			},
		}
		sert.fails(
			function() sert.model.replay(invFalseSpec, { { "step" } }) end,
			"invariant.staysZero violated (returned false)"
		)

		local invThrowSpec: sert.ModelSpec = {
			init = function() return 0 end,
			actions = {
				step = {
					next = function(s: number) return s + 1 end,
				},
			},
			invariants = {
				explodes = function() error("inv kaboom", 0) end,
			},
		}
		sert.fails(
			function() sert.model.replay(invThrowSpec, { { "step" } }) end,
			"invariant.explodes failed: inv kaboom"
		)

		-- Sim.spec passed directly to sert.model / model.property / model.replay
		local simCounter = sert.sim.spec({
			name = "SimCounterInModel",
			init = function() return { n = 0 }, { n = 0 } end,
			actions = {
				inc = {
					gen = { 1, 2 },
					guard = function(st, step) return st.n + step <= 10 end,
					run = function(sut, step)
						sut.n += step
					end,
					next = function(st, step) return { n = st.n + step } end,
				},
			},
			never = {
				aboveTen = function(st) return st.n > 10 end,
			},
			invariants = {
				inSync = function(st, sut) return sut.n == st.n end,
			},
		})
		sert.model(simCounter, { runs = 15, length = 6, redraw = true })
		local rState, rSut = sert.model.replay(simCounter :: any, { { "inc", 2 }, { "inc", 3 } })
		sert.eq({ rState.n, rSut.n }, { 5, 5 })
	end
)

sert.model("model · registered stack model", spec(math.huge), { runs = 100, length = 8, exhaustive = { size = 3 } })

return {}
