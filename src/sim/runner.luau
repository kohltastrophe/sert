--!strict
-- Executes simulator workloads for a given seed, shrinks failing operation lists, and explores the scheduler choice tree.

local Rng = require("../rng")
local Scheduler = require("./scheduler")

local Config, Explore = Scheduler.Config, Scheduler.Explore

export type Op = { t: number, server: number?, kind: string, args: { [string]: any }? }
-- Workload options, passed to `gen`, `ctx.options` and the workload; the runner reads `allowErrors`: `true`, or a
-- function `(failure) -> boolean`, accepts an error escaping a scheduler thread.
export type Options = { [string]: any }
export type Ctx = {
	scheduler: Scheduler.Scheduler,
	seed: number,
	options: Options,
	fail: (invariant: string, detail: string) -> never,
	note: (text: string) -> (),
}
export type Workload = {
	name: string,
	-- Default op count.
	steps: number,
	gen: (rng: Rng.Rng, n: number, options: Options) -> { Op },
	setup: (ctx: Ctx) -> any,
	apply: (ctx: Ctx, state: any, op: Op) -> (),
	check: ((ctx: Ctx, state: any) -> ())?,
	quiesce: ((ctx: Ctx, state: any) -> ())?,
	final: ((ctx: Ctx, state: any) -> ())?,
	-- Virtual seconds the run may take past the last op (default 600), for workloads whose quiescence
	-- outlasts a runtime timeout.
	horizon: number?,
}
export type RunFailure = {
	invariant: string,
	detail: string,
	t: number,
	step: number,
	trace: { string },
	-- For an error escaping a scheduler thread: its owner and traceback.
	owner: any,
	traceback: string?,
}
export type RunOptions = {
	seed: number,
	steps: number?,
	ops: { Op }?,
	chooser: Scheduler.Chooser?,
	options: Options?,
	-- Keep the whole trace (up to the scheduler's limit) in `failure.trace` instead of the last 40 lines.
	trace: boolean?,
	-- Fixed frame length (explore uses 0.1 so frame lengths are not choice points).
	frame: number?,
	-- Wall-clock seconds per run (default 5).
	budget: number?,
	-- Virtual seconds per run (default: the last op's time + 600).
	maxTime: number?,
	-- Virtual seconds a runner thread may stay suspended with nothing scheduled (default 30).
	stall: number?,
}
export type Result = {
	ok: boolean,
	seed: number,
	options: Options,
	failure: RunFailure?,
	ops: { Op },
	choices: { Scheduler.Choice },
	frame: number?, -- the fixed frame length the run used (nil: random frames)
	digest: number,
	frames: number,
	elapsed: number,
	trace: { string },
}
export type ShrinkLimits = { maxRuns: number?, maxSeconds: number? }
export type ShrinkResult = {
	ops: { Op },
	literal: string,
	runs: number,
	truncated: boolean,
	failure: RunFailure,
}
export type ExploreLimits = {
	maxRuns: number?,
	maxChoices: number?,
	maxBranch: number?,
	seed: number?,
	options: Options?,
}
export type ExploreResult = {
	runs: number,
	truncated: boolean,
	choices: { number }?,
	failure: RunFailure?,
}

local TRACE_TAIL, DEFAULT_BUDGET, DEFAULT_STALL, QUIESCE_TIME = 40, 5, 30, 600
local Runner = {}

-- The marker `ctx.fail` raises.
local FAILURE = {}
type Marker = { [any]: any, invariant: string, detail: string }

local function isMarker(value: any): boolean return type(value) == "table" and value[FAILURE] == true end

--- A compact, deterministic rendering of a value (keys sorted), used in trace lines and literals.
local function describeVal(value: any, seen: { [any]: boolean }): string
	local kind = type(value)
	if kind == "string" then
		return string.format("%q", value)
	elseif kind == "number" or kind == "boolean" or kind == "nil" then
		return tostring(value)
	elseif kind ~= "table" then
		return `<{kind}>`
	end
	if seen[value] then return "<cycle>" end
	seen[value] = true
	local count, parts, entries: { { raw: any, key: string, val: any } } = #value, {}, {}
	for i = 1, count do
		table.insert(parts, describeVal(value[i], seen))
	end
	for k, v in value do
		if type(k) == "number" and k >= 1 and k <= count and k == math.floor(k) then continue end
		local key = if type(k) == "string" and string.match(k, "^[%a_][%w_]*$") then k else `[{describeVal(k, seen)}]`
		table.insert(entries, { raw = k, key = key, val = v })
	end
	table.sort(
		entries,
		function(a: { raw: any, key: string, val: any }, b: { raw: any, key: string, val: any }): boolean
			if a.key ~= b.key then return a.key < b.key end
			return type(a.raw) < type(b.raw)
		end
	)
	for _, entry in entries do
		table.insert(parts, `{entry.key} = {describeVal(entry.val, seen)}`)
	end
	seen[value] = nil
	return if #parts == 0 then "{}" else `\{ {table.concat(parts, ", ")} }`
end

function Runner.describe(value: any): string return describeVal(value, {}) end

--- An op list as a Luau table literal, one op per line, ready to paste into regressions.luau.
function Runner.literal(ops: { Op }): string
	local lines = { "{" }
	for _, op in ops do
		table.insert(lines, `\t{Runner.describe(op)},`)
	end
	table.insert(lines, "}")
	return table.concat(lines, "\n")
end

--- The workload's ops for `seed`: `gen` fed from the seed's "workload" stream.
function Runner.ops(workload: Workload, seed: number, steps: number?, options: Options?): { Op }
	local ops = workload.gen(Rng.new(Config.hash(`{seed}:workload`)), steps or workload.steps, options or {})
	for i = 2, #ops do
		assert(ops[i].t >= ops[i - 1].t, `{workload.name}.gen: ops must be sorted by t (op {i})`)
	end
	return ops
end

local function ownerName(owner: any): string
	if owner == nil then
		return "test"
	elseif type(owner) == "table" then
		local name = owner.name or owner.jobId or owner.id
		if name ~= nil then return tostring(name) end
	end
	return tostring(owner)
end

local function tail(lines: { string }, count: number?): { string }
	return table.move(lines, if count == nil then 1 else math.max(1, #lines - count + 1), #lines, 1, {})
end

--- Runs `workload` once. Never throws for a workload failure; errors in the runner's own arguments do.
function Runner.run(workload: Workload, given: RunOptions): Result
	local started, seed = os.clock(), given.seed
	local options: Options = given.options or {}
	local ops = given.ops or Runner.ops(workload, seed, given.steps, options)
	local recorder = Scheduler.record(given.chooser or Scheduler.seeded(seed))
	local s = Scheduler.new({ seed = seed, random = true, frame = given.frame, chooser = recorder })
	local budget, stall = given.budget or DEFAULT_BUDGET, given.stall or DEFAULT_STALL
	local maxTime = given.maxTime or ((if #ops > 0 then ops[#ops].t else 0) + (workload.horizon or QUIESCE_TIME))
	local allow: (boolean | (Scheduler.Failure) -> boolean)? = options.allowErrors
	local failure: RunFailure?, step, seenErrors = nil, 0, 0

	local function setFailure(invariant: string, detail: string, owner: any?, traceback: string?)
		if failure == nil then
			failure = {
				invariant = invariant,
				detail = detail,
				t = s.now,
				step = step,
				trace = {},
				owner = owner,
				traceback = traceback,
			}
			s:trace(`FAIL {invariant}: {detail}`)
		end
	end

	local ctx: Ctx = {
		scheduler = s,
		seed = seed,
		options = options,
		fail = function(invariant: string, detail: string): never
			setFailure(invariant, detail)
			local marker: Marker = { [FAILURE] = true, invariant = invariant, detail = detail }
			setmetatable(marker, {
				__tostring = function() return `{invariant}: {detail}` end,
			})
			error(marker, 0)
		end :: any,
		note = function(text: string) s:trace(text) end,
	}

	-- Runner threads still expected to finish, by label. A thread that died by an allowed error counts as finished.
	local pending: { [thread]: string } = {}
	local function track(label: string, fn: () -> ()): thread
		local thread = coroutine.create(fn)
		pending[thread] = label
		return thread
	end
	local function anyPending(): boolean
		for thread in pending do
			if coroutine.status(thread) == "dead" then pending[thread] = nil end
		end
		return next(pending) ~= nil
	end

	local function scanErrors()
		while seenErrors < #s.errors do
			seenErrors += 1
			local entry = s.errors[seenErrors]
			if isMarker(entry.error) then
				local marker = entry.error :: Marker
				setFailure(marker.invariant, marker.detail, entry.owner, entry.traceback)
			elseif
				not (allow == true or (type(allow) == "function" and (allow :: (Scheduler.Failure) -> boolean)(entry)))
			then
				setFailure(
					"runtime-error",
					`error in a thread of {ownerName(entry.owner)}: {entry.message}`,
					entry.owner,
					entry.traceback
				)
			end
		end
	end

	local function runCheck(fn: (ctx: Ctx, state: any) -> (), state: any)
		local thread = coroutine.create(fn)
		local ok, err = coroutine.resume(thread, ctx, state)
		if not ok then
			if isMarker(err) then
				setFailure(err.invariant, err.detail)
			else
				setFailure("check-error", tostring(err), nil, debug.traceback(thread))
			end
		elseif coroutine.status(thread) ~= "dead" then
			setFailure("check-error", "check yielded; it runs after every frame and must not yield")
		end
	end

	local function pendingLabels(suspendedOnly: boolean): string
		local labels: { string } = {}
		for thread, label in pending do
			if not suspendedOnly or coroutine.status(thread) == "suspended" then table.insert(labels, label) end
		end
		table.sort(labels)
		return table.concat(labels, ", ")
	end

	local idleSince: number? = nil
	-- Runs frames until no runner thread is pending (or a failure); `state` is nil until setup returns.
	local function settle(state: any, phase: string)
		scanErrors()
		while failure == nil and anyPending() do
			if os.clock() - started > budget then
				setFailure("budget", string.format("%s: run took over %.1f s of wall time", phase, budget))
				break
			elseif s.now >= maxTime then
				setFailure("time-limit", `{phase}: past {maxTime} s of virtual time; pending: {pendingLabels(false)}`)
				break
			elseif s:idle() then
				idleSince = idleSince or s.now
				if s.now - (idleSince :: number) >= stall then
					setFailure(
						"deadlock",
						`{phase}: suspended with nothing scheduled for {stall} s: {pendingLabels(true)}`
					)
					break
				end
			else
				idleSince = nil
			end
			s:frame()
			scanErrors()
			local check = workload.check
			if failure == nil and state ~= nil and check ~= nil then runCheck(check, state) end
		end
	end

	-- Setup.
	local state: any = nil
	s:spawn(nil, track("setup", function() state = workload.setup(ctx) end))
	settle(nil, "setup")
	if failure == nil and state == nil then state = {} end

	-- Ops, at op.t seconds after setup.
	if failure == nil then
		local base = s.now
		for i, op in ops do
			s:after(
				math.max(op.t + base - s.now, 0),
				nil,
				track(`op {i} {op.kind}`, function()
					step = math.max(step, i)
					local server = if op.server ~= nil then ` server={op.server}` else ""
					local args = if op.args ~= nil then ` {Runner.describe(op.args)}` else ""
					s:trace(`op {i} t={op.t}{server} {op.kind}{args}`)
					workload.apply(ctx, state, op)
				end)
			)
		end
		settle(state, "ops")
	end

	for _, phase in { "quiesce", "final" } do
		local fn: ((ctx: Ctx, state: any) -> ())? = (workload :: any)[phase]
		if failure == nil and fn ~= nil then
			local call = fn :: (ctx: Ctx, state: any) -> ()
			s:trace(phase)
			s:spawn(nil, track(phase, function() call(ctx, state) end))
			settle(state, phase)
		end
	end

	if failure ~= nil then failure.trace = tail(s.traced, if given.trace then nil else TRACE_TAIL) end
	return {
		ok = failure == nil,
		seed = seed,
		options = options,
		failure = failure,
		ops = ops,
		choices = recorder.choices,
		frame = given.frame,
		digest = s:digest(),
		frames = s.frames,
		elapsed = os.clock() - started,
		trace = tail(s.traced),
	}
end

--- Shrinks a failing run's ops, keeping its seed (so each label's choice stream starts the same): the
--- shortest failing prefix by bisection, then ddmin (complements of halving chunks down to single ops).
--- A candidate still fails when it fails with the same invariant.
function Runner.shrink(workload: Workload, failing: Result, limits: ShrinkLimits?): ShrinkResult
	assert(failing.failure ~= nil, "Runner.shrink needs a failing run")
	local best = failing.failure :: RunFailure
	local invariant = best.invariant
	local maxRuns, maxSeconds = (limits and limits.maxRuns) or 200, (limits and limits.maxSeconds) or 30
	local started, runs, truncated = os.clock(), 0, false

	local function fails(candidate: { Op }): boolean
		if runs >= maxRuns or os.clock() - started > maxSeconds then
			truncated = true
			return false
		end
		runs += 1
		local failure =
			Runner.run(workload, { seed = failing.seed, ops = candidate, options = failing.options }).failure
		if failure ~= nil and failure.invariant == invariant then
			best = failure
			return true
		end
		return false
	end

	local ops = failing.ops
	local lo, hi = 0, #ops
	while hi - lo > 1 do
		local mid = (lo + hi) // 2
		if fails(table.move(ops, 1, mid, 1, {})) then
			hi = mid
		else
			lo = mid
		end
	end
	local current, chunks = table.move(ops, 1, hi, 1, {}), 2

	while #current >= 2 and not truncated do
		local size, reduced = math.ceil(#current / chunks), false
		for start = 1, #current, size do
			local candidate: { Op } = {}
			for i, op in current do
				if i < start or i >= start + size then table.insert(candidate, op) end
			end
			if #candidate > 0 and fails(candidate) then
				current, chunks, reduced = candidate, math.max(chunks - 1, 2), true
				break
			end
		end
		if not reduced then
			if chunks >= #current then break end
			chunks = math.min(chunks * 2, #current)
		end
	end
	return { ops = current, literal = Runner.literal(current), runs = runs, truncated = truncated, failure = best }
end

--- Runs the fixed `ops` under every path of the choice tree (frames fixed at 0.1 s, so only ties, hooks
--- and workload decisions branch) until one fails. `choices` replays it with `Scheduler.replay`.
function Runner.explore(workload: Workload, ops: { Op }, limits: ExploreLimits?): ExploreResult
	local given: ExploreLimits = limits or {}
	local last: RunFailure? = nil
	local outcome = Explore.run(function(chooser)
		local result = Runner.run(workload, {
			seed = given.seed or 1,
			ops = ops,
			chooser = chooser,
			options = given.options,
			frame = 0.1,
		})
		if result.failure ~= nil then
			last = result.failure
			error(result.failure, 0)
		end
	end, { maxRuns = given.maxRuns, maxChoices = given.maxChoices, maxBranch = given.maxBranch })
	local failed = outcome.failure
	return {
		runs = outcome.runs,
		truncated = outcome.truncated,
		choices = if failed ~= nil then failed.choices else nil,
		failure = if failed ~= nil then last else nil,
	}
end

-- Whether a recorded choice list holds random frame lengths: every random frame asks "hitch" first.
local function recordsFrames(choices: { any }): boolean
	for _, item in choices do
		if type(item) == "table" and item.label == "hitch" then return true end
	end
	return false
end

--- Replays a pinned run (a regressions.luau entry): its ops (or the seed's), under its recorded `choices` when it
--- has them. `frame` defaults to the recording's: random when the choices hold frame lengths (a Result's), else
--- 0.1 s (an explore path's, or a run recorded at that fixed frame).
function Runner.replay(
	workload: Workload,
	entry: {
		seed: number,
		steps: number?,
		ops: { any }?,
		choices: { any }?,
		frame: number?,
		options: Options?,
	}
): Result
	local choices = entry.choices
	return Runner.run(workload, {
		seed = entry.seed,
		steps = entry.steps,
		ops = entry.ops,
		chooser = if choices ~= nil then Scheduler.replay(choices) else nil,
		options = entry.options,
		frame = entry.frame or (if choices ~= nil and not recordsFrames(choices) then 0.1 else nil),
	})
end

--- The registered workload called `name`.
function Runner.find(workloads: { Workload }, name: string): Workload?
	for _, workload in workloads do
		if workload.name == name then return workload end
	end
	return nil
end

--- One line for a failure: `FAIL <workload> seed=S step=i t=…: <invariant>: <detail>`.
function Runner.headline(name: string, seed: number, failure: RunFailure): string
	return string.format(
		"FAIL %s seed=%d step=%d t=%.3f: %s: %s",
		name,
		seed,
		failure.step,
		failure.t,
		failure.invariant,
		failure.detail
	)
end

return table.freeze(Runner)
