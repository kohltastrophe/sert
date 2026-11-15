--!strict
-- Wing & Gong / Porcupine concurrent history linearizability checker (`Linearize`) and monotonic concurrency recorder.

local Spec = require("./spec")
local format = require("../core/format")
local registry = require("../core/registry")
local util = require("../core/util")

export type Operation<Arg = any, Res = any> = {
	proc: number | string,
	op: string,
	arg: Arg,
	res: Res,
	callAt: number,
	retAt: number,
}

export type SequentialModel<State, Arg = any, Res = any> = {
	init: () -> State,
	step: (state: State, op: string, arg: Arg, res: Res) -> (boolean, State),
	hash: ((state: State) -> string | number)?,
	partition: ((op: Operation<Arg, Res>) -> string | number)?,
}

export type LinearizeResult = {
	ok: boolean,
	message: string?,
	timeline: string?,
	conflicts: { Operation<any, any> }?,
}

export type OperationHandle = {
	proc: number | string,
	op: string,
	arg: any,
	callAt: number,
	seq: number,
}

export type Recorder = {
	call: (self: Recorder, proc: number | string, op: string, arg: any) -> OperationHandle,
	finish: (self: Recorder, handle: OperationHandle, res: any) -> Operation<any, any>,
	wrap: <R...>(self: Recorder, proc: number | string, op: string, arg: any, fn: () -> R...) -> R...,
	operations: (self: Recorder) -> { Operation<any, any> },
}

type IndexedOp = {
	op: Operation<any, any>,
	origIdx: number,
}

type Bitset = { number }

type SolveResult = {
	ok: boolean,
	bestDepth: number,
	blockedOp: Operation<any, any>?,
	visitedCount: number,
}

local Linearize = {}

local function isFiniteNumber(n: any): boolean return type(n) == "number" and n == n and math.abs(n) ~= math.huge end

local function validateModel<State, Arg, Res>(model: SequentialModel<State, Arg, Res>)
	if type(model) ~= "table" then error("Linearize: expected model table", util.outside()) end
	if type(model.init) ~= "function" then error("Linearize: model.init must be a function", util.outside()) end
	if type(model.step) ~= "function" then error("Linearize: model.step must be a function", util.outside()) end
	if model.hash ~= nil and type(model.hash) ~= "function" then
		error("Linearize: model.hash must be a function when provided", util.outside())
	end
	if model.partition ~= nil and type(model.partition) ~= "function" then
		error("Linearize: model.partition must be a function when provided", util.outside())
	end
end

local function validateHistory(history: { Operation<any, any> })
	if type(history) ~= "table" then error("Linearize: expected history array", util.outside()) end
	for i, entry in history do
		if type(entry) ~= "table" then error(`Linearize: history[{i}] must be an Operation table`, util.outside()) end
		local pt = type(entry.proc)
		if pt ~= "number" and pt ~= "string" then
			error(`Linearize: history[{i}].proc must be a number or string`, util.outside())
		end
		if type(entry.op) ~= "string" or entry.op == "" then
			error(`Linearize: history[{i}].op must be a non-empty string`, util.outside())
		end
		if not isFiniteNumber(entry.callAt) then
			error(`Linearize: history[{i}].callAt must be a finite number`, util.outside())
		end
		if not isFiniteNumber(entry.retAt) then
			error(`Linearize: history[{i}].retAt must be a finite number`, util.outside())
		end
		if entry.callAt > entry.retAt then
			error(`Linearize: history[{i}] has callAt ({entry.callAt}) > retAt ({entry.retAt})`, util.outside())
		end
	end
end

local function makeBitset(n: number): Bitset
	local wordCount = math.max(1, math.ceil(n / 32))
	return table.create(wordCount, 0)
end

local function bitsetHas(bs: Bitset, bitIndex: number): boolean
	local zeroBased = bitIndex - 1
	local wordIdx = bit32.rshift(zeroBased, 5) + 1
	local bitMask = bit32.lshift(1, zeroBased % 32)
	return bit32.btest(bs[wordIdx], bitMask)
end

local function bitsetSet(bs: Bitset, bitIndex: number)
	local zeroBased = bitIndex - 1
	local wordIdx = bit32.rshift(zeroBased, 5) + 1
	local bitMask = bit32.lshift(1, zeroBased % 32)
	bs[wordIdx] = bit32.bor(bs[wordIdx], bitMask)
end

local function bitsetClear(bs: Bitset, bitIndex: number)
	local zeroBased = bitIndex - 1
	local wordIdx = bit32.rshift(zeroBased, 5) + 1
	local bitMask = bit32.lshift(1, zeroBased % 32)
	bs[wordIdx] = bit32.band(bs[wordIdx], bit32.bnot(bitMask))
end

local function bitsetSig(bs: Bitset): string
	if #bs == 1 then return string.format("%08x", bs[1]) end
	local parts = table.create(#bs)
	for i = 1, #bs do
		parts[i] = string.format("%08x", bs[i])
	end
	return table.concat(parts)
end

local function computeStateKey<State>(model: SequentialModel<State, any, any>, state: State): string
	if model.hash ~= nil then
		local h = model.hash(state)
		if type(h) == "number" then return `n:{string.format("%.17g", h :: number)}` end
		return `s:{tostring(h)}`
	end
	return Spec.canonicalize(state)
end

local function invokeStep<State>(
	model: SequentialModel<State, any, any>,
	state: State,
	op: Operation<any, any>
): (boolean, State)
	local working = util.copy(state)
	local okStep, nextState = model.step(working, op.op, util.copy(op.arg), util.copy(op.res))
	if okStep then
		if nextState == nil and type(working) == "table" then return true, working end
		return true, nextState
	end
	return false, state
end

--- Runs memoized Wing & Gong / Porcupine DFS on `ops`.
local function solvePartition<State>(model: SequentialModel<State, any, any>, ops: { Operation<any, any> }): SolveResult
	local n = #ops
	if n == 0 then return { ok = true, bestDepth = 0, blockedOp = nil, visitedCount = 0 } end

	local callSorted: { IndexedOp } = {}
	for i = 1, n do
		callSorted[i] = { op = ops[i], origIdx = i }
	end
	table.sort(callSorted, function(a: IndexedOp, b: IndexedOp): boolean
		if a.op.callAt ~= b.op.callAt then return a.op.callAt < b.op.callAt end
		if a.op.retAt ~= b.op.retAt then return a.op.retAt < b.op.retAt end
		return a.origIdx < b.origIdx
	end)

	local retOrder: { number } = table.create(n, 0)
	for i = 1, n do
		retOrder[i] = i
	end
	table.sort(retOrder, function(ia: number, ib: number): boolean
		local a = callSorted[ia].op
		local b = callSorted[ib].op
		if a.retAt ~= b.retAt then return a.retAt < b.retAt end
		if a.callAt ~= b.callAt then return a.callAt < b.callAt end
		return ia < ib
	end)

	local done = makeBitset(n)
	local visited: { [string]: boolean } = {}
	local visitedCount = 0
	local bestDepth = -1
	local blockedOp: Operation<any, any>? = nil

	local function dfs(state: State, stateKey: string, depth: number, retCursor: number): boolean
		if depth == n then
			bestDepth = n
			return true
		end

		local doneSig = bitsetSig(done)
		local visitKey = `{doneSig}|{stateKey}`
		if visited[visitKey] then return false end

		local curRet = retCursor
		while curRet <= n and bitsetHas(done, retOrder[curRet]) do
			curRet += 1
		end
		local minRetAt = callSorted[retOrder[curRet]].op.retAt

		if depth > bestDepth then
			bestDepth = depth
			-- Pick the earliest-returning undone candidate for failure diagnostics.
			blockedOp = callSorted[retOrder[curRet]].op
		end

		for i = 1, n do
			local item = callSorted[i].op
			-- Any op with callAt > minRetAt has an undone strict real-time predecessor, as do all later callSorted ops.
			if item.callAt > minRetAt then break end
			if not bitsetHas(done, i) then
				local okStep, nextState = invokeStep(model, state, item)
				if okStep then
					local nextKey = computeStateKey(model, nextState)
					bitsetSet(done, i)
					if dfs(nextState, nextKey, depth + 1, curRet) then return true end
					bitsetClear(done, i)
				end
			end
		end

		visited[visitKey] = true
		visitedCount += 1
		return false
	end

	local initState = model.init()
	local initKey = computeStateKey(model, initState)
	local solved = dfs(initState, initKey, 0, 1)
	if solved then return { ok = true, bestDepth = n, blockedOp = nil, visitedCount = visitedCount } end

	return {
		ok = false,
		bestDepth = math.max(0, bestDepth),
		blockedOp = blockedOp,
		visitedCount = visitedCount,
	}
end

--- Groups operations into consecutive quiescent real-time windows (no operation crosses a window boundary).
local function splitQuiescentWindows(ops: { Operation<any, any> }): { { Operation<any, any> } }
	local ordered = table.clone(ops)
	table.sort(ordered, function(a: Operation<any, any>, b: Operation<any, any>): boolean
		if a.callAt ~= b.callAt then return a.callAt < b.callAt end
		if a.retAt ~= b.retAt then return a.retAt < b.retAt end
		return tostring(a.proc) < tostring(b.proc)
	end)

	local windows: { { Operation<any, any> } } = {}
	local current: { Operation<any, any> } = {}
	local maxRet = -math.huge
	for _, op in ordered do
		if #current > 0 and op.callAt > maxRet then
			table.insert(windows, current)
			current = {}
			maxRet = -math.huge
		end
		table.insert(current, op)
		if op.retAt > maxRet then maxRet = op.retAt end
	end
	if #current > 0 then table.insert(windows, current) end
	return windows
end

local function flattenWindows(
	windows: { { Operation<any, any> } },
	upTo: number,
	skipIndex: number?
): { Operation<any, any> }
	local out: { Operation<any, any> } = {}
	for w = 1, upTo do
		if w ~= skipIndex then
			for _, op in windows[w] do
				table.insert(out, op)
			end
		end
	end
	return out
end

--- Extracts a minimal unlinearizable conflict set without breaking preceding concurrent producers.
local function minimizeConflicts<State>(
	model: SequentialModel<State, any, any>,
	ops: { Operation<any, any> }
): ({ Operation<any, any> }, SolveResult)
	local windows = splitQuiescentWindows(ops)

	-- 1. Binary search the earliest quiescent prefix that fails.
	local lo, hi = 1, #windows
	local failWin = #windows
	while lo <= hi do
		local mid = math.floor((lo + hi) / 2)
		local prefixOps = flattenWindows(windows, mid)
		local res = solvePartition(model, prefixOps)
		if res.ok then
			lo = mid + 1
		else
			failWin = mid
			hi = mid - 1
		end
	end

	-- 2. Drop strictly preceding independent quiescent windows when preceding prefix still passes.
	local keptWindows: { { Operation<any, any> } } = {}
	for i = 1, failWin do
		keptWindows[i] = windows[i]
	end
	if #keptWindows > 1 then
		local idx = 1
		while idx < #keptWindows and #keptWindows > 2 do
			local candWithout = table.clone(keptWindows)
			table.remove(candWithout, idx)
			local fullWithout = flattenWindows(candWithout, #candWithout)
			local resFull = solvePartition(model, fullWithout)
			if not resFull.ok then
				local prefixWithout = flattenWindows(candWithout, #candWithout - 1)
				if solvePartition(model, prefixWithout).ok then
					keptWindows = candWithout
					continue
				end
			end
			idx += 1
		end
	end

	local current = flattenWindows(keptWindows, #keptWindows)
	local curSolve = solvePartition(model, current)

	-- 3. Prune redundant individual operations within small working sets without orphaning concurrent producers.
	local MAX_SINGLE_PRUNE_OPS = 24
	if #current > 2 and #current <= MAX_SINGLE_PRUNE_OPS then
		local changed = true
		while changed and #current > 2 do
			changed = false
			local bestDropIdx: number? = nil
			local bestDropSolve: SolveResult? = nil
			local bestDropDepth = -1

			for i = 1, #current do
				local trial = table.clone(current)
				table.remove(trial, i)
				local trialSolve = solvePartition(model, trial)
				if not trialSolve.ok then
					local depthDrop = curSolve.bestDepth - trialSolve.bestDepth
					-- Do not prune an operation whose removal collapses multiple other satisfied operations.
					if depthDrop <= 1 and trialSolve.bestDepth > bestDropDepth then
						bestDropIdx = i
						bestDropSolve = trialSolve
						bestDropDepth = trialSolve.bestDepth
					end
				end
			end

			if bestDropIdx ~= nil and bestDropSolve ~= nil then
				table.remove(current, bestDropIdx)
				curSolve = bestDropSolve
				changed = true
			end
		end
	end

	table.sort(current, function(a: Operation<any, any>, b: Operation<any, any>): boolean
		if a.callAt ~= b.callAt then return a.callAt < b.callAt end
		if a.retAt ~= b.retAt then return a.retAt < b.retAt end
		return tostring(a.proc) < tostring(b.proc)
	end)

	return current, curSolve
end

local function formatNumberCompact(n: number): string
	if n == math.floor(n) and math.abs(n) < 1e12 then return string.format("%d", n) end
	return string.format("%.6g", n)
end

local function formatOpSignature(op: Operation<any, any>): string
	local argStr = if op.arg ~= nil then format.repr(op.arg, 2) else ""
	local resStr = format.repr(op.res, 2)
	return `{op.op}({argStr}) -> {resStr}`
end

local function formatIntervalBar(op: Operation<any, any>, minT: number, span: number, width: number): string
	if span <= 0 then return "[==]" end
	local slots = width - 2
	local startCol = math.clamp(math.floor(((op.callAt - minT) / span) * slots) + 1, 1, slots)
	local pad = string.rep(" ", startCol - 1)
	if op.callAt == op.retAt then return `{pad}[]` end
	local rawEnd = math.floor(((op.retAt - minT) / span) * slots) + 1
	local endCol = math.clamp(math.max(startCol + 1, rawEnd), startCol + 1, width)
	local len = endCol - startCol + 1
	if len <= 2 then return `{pad}[]` end
	return `{pad}[{string.rep("=", len - 2)}]`
end

local function formatTimeline(
	ops: { Operation<any, any> },
	solve: SolveResult,
	partitionLabel: string?,
	totalPartitionOps: number
): string
	local BAR_WIDTH = 40
	local sorted = table.clone(ops)
	table.sort(sorted, function(a: Operation<any, any>, b: Operation<any, any>): boolean
		if a.callAt ~= b.callAt then return a.callAt < b.callAt end
		if a.retAt ~= b.retAt then return a.retAt < b.retAt end
		return tostring(a.proc) < tostring(b.proc)
	end)

	local minT = math.huge
	local maxT = -math.huge
	local procWidth = 4
	local sigWidth = 9
	local rows: { { proc: string, sig: string, op: Operation<any, any> } } = {}

	for i, op in sorted do
		if op.callAt < minT then minT = op.callAt end
		if op.retAt > maxT then maxT = op.retAt end
		local procStr = tostring(op.proc)
		local sigStr = formatOpSignature(op)
		if #procStr > procWidth then procWidth = #procStr end
		if #sigStr > sigWidth then sigWidth = #sigStr end
		rows[i] = { proc = procStr, sig = sigStr, op = op }
	end

	local span = maxT - minT
	local lines: { string } = {}
	local partPrefix = if partitionLabel ~= nil then `Partition {partitionLabel}: ` else ""
	local blockedStr = if solve.blockedOp ~= nil
		then `; blocked around {tostring(solve.blockedOp.proc)}: {formatOpSignature(solve.blockedOp)}`
		else ""
	table.insert(
		lines,
		`{partPrefix}not linearizable ({#sorted} minimal conflict(s) of {totalPartitionOps} op(s); max valid sequential prefix: {solve.bestDepth}/{#sorted}{blockedStr})`
	)

	local minLabel = formatNumberCompact(minT)
	local maxLabel = formatNumberCompact(maxT)
	local axisGap = math.max(1, BAR_WIDTH - #minLabel - #maxLabel - 2)
	local axisHeader = `[{minLabel}{string.rep(" ", axisGap)}{maxLabel}]`
	table.insert(lines, string.format(`%-{procWidth}s | %-{sigWidth}s | %s`, "proc", "operation", axisHeader))
	table.insert(
		lines,
		`{string.rep("-", procWidth)}-+-{string.rep("-", sigWidth)}-+-{string.rep("-", math.max(BAR_WIDTH, #axisHeader))}`
	)

	for _, row in rows do
		local bar = formatIntervalBar(row.op, minT, span, BAR_WIDTH)
		local tRange = `({formatNumberCompact(row.op.callAt)}..{formatNumberCompact(row.op.retAt)})`
		table.insert(
			lines,
			string.format(`%-{procWidth}s | %-{sigWidth}s | %-{BAR_WIDTH}s %s`, row.proc, row.sig, bar, tRange)
		)
	end

	return table.concat(lines, "\n")
end

--- Checks whether `history` admits a valid linearization under sequential `model`.
function Linearize.check<State, Arg, Res>(model: SequentialModel<State, Arg, Res>, history: { Operation<Arg, Res> }): LinearizeResult
	validateModel(model)
	validateHistory(history :: { Operation<any, any> })

	if #history == 0 then return { ok = true } end

	type PartitionGroup = { key: string, label: string, ops: { Operation<any, any> } }
	local groups: { PartitionGroup } = {}

	if model.partition ~= nil then
		local byKey: { [string]: PartitionGroup } = {}
		for _, op in history :: { Operation<any, any> } do
			local rawKey = model.partition(op :: Operation<Arg, Res>)
			local key = if type(rawKey) == "number"
				then `n:{string.format("%.17g", rawKey :: number)}`
				else `s:{tostring(rawKey)}`
			local g = byKey[key]
			if g == nil then
				g = { key = key, label = format.repr(rawKey, 2), ops = {} }
				byKey[key] = g
				table.insert(groups, g)
			end
			table.insert(g.ops, op)
		end
	else
		groups[1] = { key = "__all__", label = "", ops = table.clone(history :: { Operation<any, any> }) }
	end

	local allConflicts: { Operation<any, any> } = {}
	local timelines: { string } = {}
	local failLabels: { string } = {}

	for _, group in groups do
		local res = solvePartition(model, group.ops)
		if not res.ok then
			local conflicts, minSolve = minimizeConflicts(model, group.ops)
			for _, c in conflicts do
				table.insert(allConflicts, c)
			end
			local label: string? = if model.partition ~= nil then group.label else nil
			table.insert(timelines, formatTimeline(conflicts, minSolve, label, #group.ops))
			if label ~= nil then table.insert(failLabels, label) end
		end
	end

	if #timelines == 0 then return { ok = true } end

	local combinedTimeline = table.concat(timelines, "\n\n")
	local header = if #failLabels > 0
		then `History is not linearizable in partition(s) {table.concat(failLabels, ", ")}`
		else "History is not linearizable under the sequential model"

	return {
		ok = false,
		message = `{header}\n{combinedTimeline}`,
		timeline = combinedTimeline,
		conflicts = allConflicts,
	}
end

--- Asserts that `history` is linearizable under `model`, recording a `linearizable` assertion in `registry`.
function Linearize.linearizable<State, Arg, Res>(
	model: SequentialModel<State, Arg, Res>,
	history: { Operation<Arg, Res> },
	msg: string?
): LinearizeResult
	registry.recordAssertion("linearizable")
	local res = Linearize.check(model, history)
	if not res.ok then
		local prefix = if msg ~= nil and msg ~= "" then `{msg}: ` else ""
		error(`{prefix}{res.message or "History is not linearizable"}`, util.outside())
	end
	return res
end

--- Returns a monotonic concurrency operation recorder backed by `clockFn` (or active `Env.now` / `os.clock`).
function Linearize.recorder(clockFn: (() -> number)?): Recorder
	if clockFn ~= nil and type(clockFn) ~= "function" then
		error("Linearize.recorder: clockFn must be a function when provided", util.outside())
	end

	local recorded: { Operation<any, any> } = {}
	local completedOrder: { [Operation<any, any>]: number } = {}
	local finishedHandles: { [OperationHandle]: boolean } = {}
	local seq = 0
	local lastBase: number? = nil
	local lastTs: number? = nil

	local function readClock(): number
		if clockFn ~= nil then return clockFn() end
		local env = registry.activeEnv()
		if env ~= nil and type((env :: any).now) == "number" then return (env :: any).now end
		return os.clock()
	end

	local function nextTimestamp(): number
		local raw = readClock()
		if not isFiniteNumber(raw) then
			error("Linearize.recorder: clock returned non-finite timestamp", util.outside())
		end
		seq += 1
		if lastBase == nil or raw > lastBase then lastBase = raw end
		local base = lastBase :: number
		local step = math.max(1e-9, math.abs(base) * 1e-12)
		local candidate = base + seq * step
		if lastTs ~= nil and candidate <= lastTs then
			local bump = math.max(1e-9, math.abs(lastTs) * 1e-12)
			candidate = lastTs + bump
		end
		lastTs = candidate
		return candidate
	end

	local rec = {} :: Recorder

	function rec:call(proc: number | string, op: string, arg: any): OperationHandle
		local pt = type(proc)
		if pt ~= "number" and pt ~= "string" then
			error("Linearize.recorder:call: proc must be a number or string", util.outside())
		end
		if type(op) ~= "string" or op == "" then
			error("Linearize.recorder:call: op must be a non-empty string", util.outside())
		end
		local callAt = nextTimestamp()
		return {
			proc = proc,
			op = op,
			arg = arg,
			callAt = callAt,
			seq = seq,
		}
	end

	function rec:finish(handle: OperationHandle, res: any): Operation<any, any>
		if type(handle) ~= "table" or type(handle.op) ~= "string" or not isFiniteNumber(handle.callAt) then
			error("Linearize.recorder:finish: invalid OperationHandle", util.outside())
		end
		if finishedHandles[handle] then
			error("Linearize.recorder:finish: handle was already finished", util.outside())
		end
		finishedHandles[handle] = true
		local retAt = nextTimestamp()
		local entry: Operation<any, any> = {
			proc = handle.proc,
			op = handle.op,
			arg = handle.arg,
			res = res,
			callAt = handle.callAt,
			retAt = retAt,
		}
		completedOrder[entry] = handle.seq
		table.insert(recorded, entry)
		return entry
	end

	function rec:wrap<R...>(proc: number | string, op: string, arg: any, fn: () -> R...): R...
		if type(fn) ~= "function" then error("Linearize.recorder:wrap: expected function callback", util.outside()) end
		local handle = rec:call(proc, op, arg)
		local packed = table.pack(pcall(fn :: () -> ...any))
		if not packed[1] then error(packed[2], 0) end
		local resValue: any = if packed.n >= 2 then packed[2] else nil
		rec:finish(handle, resValue)
		return (table.unpack :: any)(packed, 2, packed.n)
	end

	function rec:operations(): { Operation<any, any> }
		local copy = table.clone(recorded)
		table.sort(copy, function(a: Operation<any, any>, b: Operation<any, any>): boolean
			if a.callAt ~= b.callAt then return a.callAt < b.callAt end
			return (completedOrder[a] or 0) < (completedOrder[b] or 0)
		end)
		return copy
	end

	return rec
end

return Linearize
