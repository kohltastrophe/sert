--!strict
local corpus = require("../src/prop/corpus")
local format = require("../src/core/format")
local fuzz = require("../src/prop/fuzz")
local registry = require("../src/core/registry")
local sert = require("../src")

local function runFuzzIsolated(
	cfg: fuzz.FuzzConfig,
	sertOverride: any?
): (fuzz.FuzzSummary, { { [string]: any } }, { string })
	local lines: { string } = {}
	local events: { { [string]: any } } = {}
	local localCfg: fuzz.FuzzConfig = table.clone(cfg)
	localCfg.emit = function(line: string)
		table.insert(lines, line)
		if string.sub(line, 1, 12) == "[sert-fuzz] " then
			local decoded = format.jsonDecode(string.sub(line, 13))
			if type(decoded) == "table" then table.insert(events, decoded :: { [string]: any }) end
		end
	end

	local sub = registry.newState()
	local prevIso = registry.isolateDepth
	registry.isolateDepth = 0
	local ok, summary = pcall(function(): fuzz.FuzzSummary
		return registry.withState(sub, function(): fuzz.FuzzSummary return fuzz.run(localCfg, sertOverride or sert) end)
	end)
	registry.isolateDepth = prevIso
	if not ok then error(summary, 0) end
	return summary, events, lines
end

local function sharedFuzzCtrl(): any
	local envAny: any = sert.env
	local sg = envAny._sharedG
	return if type(sg) == "table" then sg.__SERT_FUZZ else nil
end

sert.describe("sert.prop.fuzz greybox engine", function()
	sert.test("exercises AFL buckets, cmp distances, dict splices, crossover, targets, and replay", function()
		local seenControl = false
		local observedScore = -1
		local observedCmp = -1
		local trialIdx = 0

		local summary, events, lines = runFuzzIsolated({
			budget = 2.0,
			maxRuns = 80,
			propCountHint = 1,
			dictStrings = { "alpha", "magic" },
			dictNumbers = { 42, -17 },
			corpus = {
				["afl-cmp"] = {
					{ seed = 101, size = 12, tape = { 1, 2, 3, 4 } },
					{ seed = 102, size = 12, tape = { 2, 3, 4, 5 } },
				},
			},
			regressions = {
				["afl-cmp"] = { corpus.encode(55, 8, { 0, 1 }), "56" },
			},
			specs = {
				{
					file = "test/fake_pass.spec.luau",
					load = function(): any
						sert.prop("afl-cmp", function(g: sert.Gen)
							trialIdx += 1
							local ctrl = sharedFuzzCtrl()
							if ctrl ~= nil then
								seenControl = true
								local counts = { 1, 2, 3, 5, 10, 20, 36 }
								local hits = counts[((trialIdx - 1) % #counts) + 1]
								for _ = 1, hits do
									ctrl.edge(100 + (trialIdx % 4))
								end
								local n = g:int(-128, 128)
								local s = g:string(nil, 2, 6)
								local _b = g:bytes(2, 6)
								ctrl.cmp(1, "==", n, 77)
								ctrl.cmp(2, "~=", n, n)
								ctrl.cmp(3, "<", n, -999)
								ctrl.cmp(4, "<=", n, -999)
								ctrl.cmp(5, ">", n, 999)
								ctrl.cmp(6, ">=", n, 999)
								ctrl.cmp(7, "==", s, "needle")
								ctrl.cmp(8, "~=", s, s)
								ctrl.cmp(9, "??", n, 0)
								observedScore = math.max(observedScore, ctrl.score())
								observedCmp = math.max(observedCmp, ctrl.bestCmp())
								if trialIdx % 17 == 0 then g:assume(false) end
								if trialIdx % 11 == 0 then g:target(math.abs(n), "magnitude") end
								sert.ge(n, -128)
								sert.le(n, 128)
							end
						end, { runs = 5, seed = 777, size = 16 })
						return nil
					end,
				},
			},
		})

		sert.eq(seenControl, true)
		sert.eq(summary.passed, 1)
		sert.eq(summary.failed, 0)
		sert.ge(summary.iterations, 40)
		sert.ge(summary.edges, 1)
		sert.ge(summary.bestCmp, 1)
		sert.ge(observedScore, 1)
		sert.ge(observedCmp, 1)
		sert.gt(#lines, 1)

		local sawCorpus, sawDone = false, false
		for _, ev in events do
			if ev.event == "corpus" then
				sawCorpus = true
				sert.ok(corpus.decode(ev.token) ~= nil)
			elseif ev.event == "done" then
				sawDone = true
				sert.eq(ev.passed, 1)
				sert.eq(ev.failed, 0)
				sert.eq(ev.seed, 0x5EED)
			end
		end
		sert.eq(sawCorpus, true)
		sert.eq(sawDone, true)
		sert.eq(sharedFuzzCtrl(), nil)
	end)

	sert.test("shrinks failing tapes, filters files, and JSON-escapes control bytes", function()
		local skippedLoaded = false
		local propName = 'ctrl\0\1\n\31"\\-prop'
		local summary, events = runFuzzIsolated({
			seed = 999,
			budget = 2.0,
			maxRuns = 25,
			files = { "match.spec.luau" },
			specs = {
				{
					file = "sub/skip.spec.luau",
					load = function(): any
						skippedLoaded = true
						return nil
					end,
				},
				{
					file = "sub/match.spec.luau",
					load = function(): any
						sert.prop(propName, function(g: sert.Gen)
							local a = g:int(0, 50)
							local b = g:int(0, 50)
							local c = g:int(0, 50)
							g:note(function(): string return "note\0\1\n\31" end)
							if a + b + c >= 10 then error("boom\0\1\n\31", 0) end
						end, { runs = 10, seed = 42, size = 30, file = "sub/match.spec.luau" })
						return nil
					end,
				},
			},
		})

		sert.eq(skippedLoaded, false)
		sert.eq(summary.failed, 1)
		sert.eq(summary.passed, 0)

		local failToken: string? = nil
		for _, ev in events do
			if ev.event == "failure" then
				failToken = ev.token
				sert.eq(ev.name, propName)
				sert.eq(ev.file, "sub/match.spec.luau")
				sert.contains(ev.counterexample, "note\0\1\n\31")
				sert.contains(ev.message, "boom\0\1\n\31")
				sert.eq(string.sub(ev.token, 1, 3), "v1:")
				sert.ok(corpus.decode(ev.token) ~= nil)
			end
		end
		sert.ok(failToken ~= nil)

		local replaySummary, replayEvents = runFuzzIsolated({
			seed = 999,
			budget = 1.0,
			maxRuns = 5,
			regressions = {
				[propName] = { failToken :: string },
			},
			specs = {
				{
					file = "sub/match.spec.luau",
					load = function(): any
						sert.prop(propName, function(g: sert.Gen)
							local a = g:int(0, 50)
							local b = g:int(0, 50)
							local c = g:int(0, 50)
							if a + b + c >= 10 then error("replayed", 0) end
						end, { runs = 10, seed = 42, size = 30, file = "sub/match.spec.luau" })
						return nil
					end,
				},
			},
		})
		sert.eq(replaySummary.failed, 1)
		local sawReplayFail = false
		for _, ev in replayEvents do
			if ev.event == "failure" then sawReplayFail = true end
		end
		sert.eq(sawReplayFail, true)
	end)

	sert.test("runs trial hooks via entries and captures setup/spec/entry/runner errors", function()
		local setupRan = false
		local trialStep = 0
		local summary, events = runFuzzIsolated({
			seed = 321,
			budget = 2.0,
			maxRuns = 15,
			setups = {
				{
					file = "setup.luau",
					load = function(): any
						setupRan = true
						return nil
					end,
				},
			},
			entries = {
				{
					file = "entry.luau",
					load = function(): any
						local ctrl = sharedFuzzCtrl()
						sert.ok(ctrl ~= nil)
						local okRes = ctrl.runProperty({
							name = "trial-ok",
							filter = "trial",
							meta = { baseSeed = 11, size = 8, file = "entry.luau" },
							trial = function(_forcedTape: { number }?, _seedVal: number, _sizeVal: number): any
								trialStep += 1
								if trialStep == 1 then return { assumed = true } end
								ctrl.edge(77)
								return {
									ok = true,
									tape = { 1, 2 },
									ranges = { 10, 10 },
									targets = { depth = trialStep },
								}
							end,
						})
						sert.eq(okRes.ok, true)

						local failRes = ctrl.runProperty({
							name = "trial-fail",
							meta = { baseSeed = 12, size = 8, file = "entry.luau" },
							trial = function()
								return {
									ok = false,
									tape = { 9, 4 },
									ranges = { 20, 20 },
									message = "hook boom",
								}
							end,
						})
						sert.eq(failRes.ok, false)
						sert.eq(failRes.message, "hook boom")
						return nil
					end,
				},
			},
		})

		sert.eq(setupRan, true)
		sert.eq(summary.passed, 1)
		sert.eq(summary.failed, 1)
		local sawDone = false
		for _, ev in events do
			if ev.event == "done" then sawDone = true end
		end
		sert.eq(sawDone, true)

		local errProxy = {
			prop = sert.prop,
			env = sert.env,
			run = function() error("run boom", 0) end,
		}
		local errSummary, errEvents = runFuzzIsolated({
			seed = 1,
			budget = 0.5,
			maxRuns = 2,
			specs = {
				{
					file = "bad_spec.luau",
					load = function(): any error("spec boom", 0) end,
				},
			},
			entries = {
				{
					file = "bad_entry.luau",
					load = function(): any error("entry boom", 0) end,
				},
			},
		}, errProxy)

		sert.eq(errSummary.failed, 3)
		local errorMsgs: { string } = {}
		for _, ev in errEvents do
			if ev.event == "error" then table.insert(errorMsgs, ev.message) end
		end
		sert.eq(#errorMsgs, 3)
		sert.contains(errorMsgs[1], "spec boom")
		sert.contains(errorMsgs[2], "entry boom")
		sert.contains(errorMsgs[3], "run boom")
	end)
end)
