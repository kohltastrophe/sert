--!strict
-- Coverage- and comparison-guided evolutionary greybox fuzzing driver (`sert fuzz`).

local corpusCodec = require("./corpus")
local format = require("../core/format")
local prop = require("../prop")
local rng = require("../core/rng")

export type CorpusItem = {
	seed: number?,
	size: number?,
	tape: { number }?,
}

export type ModuleItem = {
	file: string,
	load: () -> any,
}

export type FuzzConfig = {
	seed: number?,
	budget: number?,
	maxRuns: number?,
	propCountHint: number?,
	filter: string?,
	grep: string?,
	files: { string }?,
	dictStrings: { string }?,
	dictNumbers: { number }?,
	corpus: { [string]: { CorpusItem } }?,
	regressions: { [string]: { string } }?,
	setups: { ModuleItem }?,
	specs: { ModuleItem }?,
	entries: { ModuleItem }?,
	emit: ((line: string) -> ())?,
}

export type FuzzSummary = {
	iterations: number,
	passed: number,
	failed: number,
	edges: number,
	bestCmp: number,
	seed: number,
}

local U32 = 2 ^ 32
local dynRequire: (string) -> any = require :: any

local fuzz = {}

-- AFL hit-count bucket map: 1, 2, 3, 4-7, 8-15, 16-31, 32+.
local function hitBucket(cnt: number): number
	if cnt <= 0 then
		return 0
	elseif cnt == 1 then
		return 1
	elseif cnt == 2 then
		return 2
	elseif cnt == 3 then
		return 3
	elseif cnt <= 7 then
		return 4
	elseif cnt <= 15 then
		return 5
	elseif cnt <= 31 then
		return 6
	else
		return 7
	end
end

local function strDistance(a: string, b: string): number
	local la, lb = #a, #b
	local d = math.abs(la - lb) * 256
	local lim = math.min(la, lb)
	for idx = 1, lim do
		local ba, bb = string.byte(a, idx), string.byte(b, idx)
		if ba ~= bb then
			d += 1 + math.abs(ba - bb) / 256
		end
	end
	return d
end

local function cloneNumList(xs: { number }): { number }
	local out: { number } = table.create(#xs, 0)
	for i = 1, #xs do
		out[i] = xs[i]
	end
	return out
end

local function clampSlot(val: number, r: number?): number
	local maxV = if r ~= nil and r >= 0 then r else 0xFFFFFFFF
	local iv = math.floor(val)
	if iv < 0 then return 0 end
	if iv > maxV then return maxV end
	return iv
end

local function evalCmp(op: string, a: any, b: any): boolean
	if op == "==" then
		return a == b
	elseif op == "~=" then
		return a ~= b
	elseif op == "<" then
		return a < b
	elseif op == "<=" then
		return a <= b
	elseif op == ">" then
		return a > b
	elseif op == ">=" then
		return a >= b
	end
	return false
end

local function normSpec(p: string): string
	local c = string.gsub(string.gsub(p, "^[@=]", ""), "%.luau?$", "")
	c = string.gsub(string.gsub(c, "\\", "/"), "^%./", "")
	return string.lower((string.gsub(c, "%.spec$", "")))
end

--- Runs the greybox evolutionary fuzzing loop described by `cfg` against `sertMod`.
function fuzz.run(cfg: FuzzConfig, sertMod: any): FuzzSummary
	local sert: any = sertMod
	local propApi: any = if type(sert) == "table" and type(sert.prop) == "table" then sert.prop else prop
	local emitLine: (string) -> () = if type(cfg.emit) == "function" then cfg.emit :: (string) -> () else print

	local paused = false
	local function withoutTracking<T>(fn: () -> T): T
		local prev = paused
		paused = true
		local ok, res = pcall(fn)
		paused = prev
		if not ok then error(res, 0) end
		return res
	end

	local function encodeToken(seedVal: number, sizeVal: number, tape: { number }): string
		return withoutTracking(function(): string
			local normTape: { number } = table.create(#tape, 0)
			for i = 1, #tape do
				normTape[i] = bit32.band(math.floor(tape[i]), 0xFFFFFFFF)
			end
			local normSeed = math.floor(seedVal)
			local normSize = math.max(0, math.floor(sizeVal))
			return corpusCodec.encode(normSeed, normSize, normTape)
		end)
	end

	local function emitEvent(payload: { [string]: any })
		local jsonLine = withoutTracking(function(): string return format.json(payload) end)
		emitLine("[sert-fuzz] " .. jsonLine)
	end

	local prngState: number = (cfg.seed or 0x5EED) % U32
	if prngState == 0 then prngState = 0x5EED end
	local function randU32(): number
		if prngState == 0 then prngState = 0x5EED end
		prngState = bit32.band(rng.xorshift32(prngState), 0xFFFFFFFF)
		if prngState == 0 then prngState = 0x5EED end
		return prngState
	end
	local function randRange(lo: number, hi: number): number
		if hi <= lo then return lo end
		return lo + (randU32() % (hi - lo + 1))
	end

	local charsStr: string = propApi.CHARACTERS or prop.CHARACTERS
	local charMap: { [string]: number } = {}
	for ci = 1, #charsStr do
		local ch = string.sub(charsStr, ci, ci)
		if charMap[ch] == nil then charMap[ch] = ci - 1 end
	end

	local seenBuckets: { [number]: number } = {}
	local edgesCovered = 0
	local trialHits: { [number]: number } = {}
	local touchedEdges: { number } = {}

	local bestCmpDist: { [number]: number } = {}
	local bestCmpCount = 0
	local trialMinDist: { [number]: number } = {}
	local touchedCmps: { number } = {}

	local dynNumbers: { number } = {}
	local seenDynNum: { [number]: boolean } = {}
	local dynStrings: { string } = {}
	local seenDynStr: { [string]: boolean } = {}

	if cfg.dictNumbers ~= nil then
		for _, n in cfg.dictNumbers do
			if type(n) == "number" and n == n and math.abs(n) < 1e15 and not seenDynNum[n] then
				seenDynNum[n] = true
				table.insert(dynNumbers, n)
			end
		end
	end
	if cfg.dictStrings ~= nil then
		for _, s in cfg.dictStrings do
			if type(s) == "string" and #s >= 1 and #s <= 64 and not seenDynStr[s] then
				seenDynStr[s] = true
				table.insert(dynStrings, s)
			end
		end
	end

	local function noteDynNum(v: any)
		if #dynNumbers >= 256 or type(v) ~= "number" or v ~= v or math.abs(v) >= 1e12 then return end
		if v == 0 or v == 1 or v == -1 then return end
		local iv = math.floor(v)
		if iv == v and not seenDynNum[iv] then
			seenDynNum[iv] = true
			table.insert(dynNumbers, iv)
		end
	end

	local function noteDynStr(v: any)
		if #dynStrings >= 128 or type(v) ~= "string" or #v < 2 or #v > 64 or seenDynStr[v] then return end
		seenDynStr[v] = true
		table.insert(dynStrings, v)
	end

	local fuzzCtrl: { [string]: any } = {
		_isCliFuzzer = true,
		dict = {
			strings = cfg.dictStrings or {},
			numbers = cfg.dictNumbers or {},
		},
	}

	function fuzzCtrl.edge(id: number)
		if paused then return end
		local prev = trialHits[id]
		if prev == nil or prev == 0 then
			trialHits[id] = 1
			table.insert(touchedEdges, id)
		else
			trialHits[id] = prev + 1
		end
	end

	function fuzzCtrl.cmp(id: number, op: string, a: any, b: any): boolean
		local res = evalCmp(op, a, b)
		if paused or res then return res end

		local ta, tb = type(a), type(b)
		local dist: number? = nil
		if ta == "number" and tb == "number" and a == a and b == b then
			local na, nb = a :: number, b :: number
			noteDynNum(na)
			noteDynNum(nb)
			if op == "==" then
				dist = math.abs(na - nb)
			elseif op == "<" then
				dist = (na - nb) + 1e-6
			elseif op == "<=" then
				dist = na - nb
			elseif op == ">" then
				dist = (nb - na) + 1e-6
			elseif op == ">=" then
				dist = nb - na
			elseif op == "~=" then
				dist = 1
			end
		elseif ta == "string" and tb == "string" and (op == "==" or op == "~=") then
			local sa, sb = a :: string, b :: string
			noteDynStr(sa)
			noteDynStr(sb)
			dist = if op == "==" then strDistance(sa, sb) else 1
		end
		if dist ~= nil then
			local prevMin = trialMinDist[id]
			if prevMin == nil then
				trialMinDist[id] = dist
				table.insert(touchedCmps, id)
			elseif dist < prevMin then
				trialMinDist[id] = dist
			end
		end
		return res
	end

	function fuzzCtrl.score(): number return edgesCovered end

	function fuzzCtrl.bestCmp(): number return bestCmpCount end

	function fuzzCtrl.reset()
		seenBuckets = {}
		edgesCovered = 0
		bestCmpDist = {}
		bestCmpCount = 0
		trialHits = {}
		touchedEdges = {}
		trialMinDist = {}
		touchedCmps = {}
	end

	function fuzzCtrl.step(): (boolean, boolean)
		local newCov = false
		local distImproved = false
		for i = 1, #touchedEdges do
			local id = touchedEdges[i]
			local cnt = trialHits[id] or 0
			trialHits[id] = 0
			if cnt > 0 then
				local bucket = hitBucket(cnt)
				local mask = bit32.lshift(1, bucket)
				local prevMask = seenBuckets[id] or 0
				if prevMask == 0 then
					edgesCovered += 1
				end
				if bit32.band(prevMask, mask) == 0 then
					seenBuckets[id] = bit32.bor(prevMask, mask)
					newCov = true
				end
			end
		end
		touchedEdges = {}

		for i = 1, #touchedCmps do
			local id = touchedCmps[i]
			local d = trialMinDist[id]
			trialMinDist[id] = nil
			if d ~= nil then
				local best = bestCmpDist[id]
				if best == nil or d < best then
					bestCmpDist[id] = d
					bestCmpCount += 1
					distImproved = true
				end
			end
		end
		touchedCmps = {}
		return newCov, distImproved
	end

	local function mutateSingleSlot(tape: { number }, ranges: { number }, kind: number)
		if #tape == 0 then return end
		local idx = randRange(1, #tape)
		local r = ranges[idx] or 0xFFFFFFFF
		if r <= 0 then
			for _ = 1, 4 do
				local alt = randRange(1, #tape)
				if (ranges[alt] or 0xFFFFFFFF) > 0 then
					idx = alt
					r = ranges[alt] or 0xFFFFFFFF
					break
				end
			end
		end
		local v = tape[idx]
		if kind == 1 then
			local maxBit = 0
			local tmp = r
			while tmp > 1 and maxBit < 31 do
				tmp = math.floor(tmp / 2)
				maxBit += 1
			end
			local bitIdx = randRange(0, maxBit)
			local flipped = bit32.bxor(bit32.band(v, 0xFFFFFFFF), bit32.lshift(1, bitIdx))
			tape[idx] = clampSlot(flipped, r)
		elseif kind == 2 then
			local delta = if randRange(0, 1) == 0 then 1 else -1
			if randRange(0, 3) == 0 then delta = delta * randRange(2, 8) end
			tape[idx] = clampSlot(v + delta, r)
		elseif kind == 3 then
			local maxPow = 0
			local tmp = math.max(1, r)
			while tmp >= 2 and maxPow < 30 do
				tmp = math.floor(tmp / 2)
				maxPow += 1
			end
			local stepVal = bit32.lshift(1, randRange(0, maxPow))
			local dir = if randRange(0, 1) == 0 then 1 else -1
			tape[idx] = clampSlot(v + dir * stepVal, r)
		else
			tape[idx] = clampSlot(randU32() % (math.min(r, 0x7FFFFFFF) + 1), r)
		end
	end

	local function spliceDictNumber(tape: { number }, ranges: { number }): boolean
		if #dynNumbers == 0 or #tape == 0 then return false end
		local num = dynNumbers[randRange(1, #dynNumbers)]
		local absNum = math.abs(math.floor(num))
		local candidates: { number } = {}
		for i = 1, #tape do
			if (ranges[i] or 0xFFFFFFFF) >= absNum and (ranges[i] or 0) > 1 then table.insert(candidates, i) end
		end
		if #candidates == 0 then return false end
		local idx = candidates[randRange(1, #candidates)]
		local r = ranges[idx] or 0xFFFFFFFF
		if num < 0 then
			if idx > 1 and ranges[idx - 1] == 1 then
				tape[idx - 1] = 1
				tape[idx] = clampSlot(absNum - 1, r)
			else
				tape[idx] = clampSlot(absNum, r)
			end
		else
			if idx > 1 and ranges[idx - 1] == 1 then tape[idx - 1] = 0 end
			local nudge = 0
			local roll = randRange(0, 9)
			if roll == 0 then
				nudge = -1
			elseif roll == 1 then
				nudge = 1
			end
			tape[idx] = clampSlot(absNum + nudge, r)
		end
		return true
	end

	local function spliceDictString(tape: { number }, ranges: { number }): boolean
		if #dynStrings == 0 or #tape == 0 then return false end
		local s = dynStrings[randRange(1, #dynStrings)]
		local charRange = #charsStr - 1
		local enc: { number } = {}
		local pos: number? = nil
		for i = 1, #tape do
			local r = ranges[i]
			if r == charRange or r == 255 then
				pos = if i > 1 and ranges[i - 1] == 1 then i - 1 else i
				break
			end
		end
		if pos == nil then return false end
		local p = pos :: number
		local isBytes = (ranges[p] == 255) or (p < #ranges and ranges[p + 1] == 255)
		local hasMoreFlag = ranges[p] == 1
		if hasMoreFlag then
			for ci = 1, #s do
				local code = if isBytes then string.byte(s, ci) else (charMap[string.sub(s, ci, ci)] or 0)
				table.insert(enc, 1)
				table.insert(enc, code)
			end
			table.insert(enc, 0)
		else
			for ci = 1, #s do
				local code = if isBytes then string.byte(s, ci) else (charMap[string.sub(s, ci, ci)] or 0)
				table.insert(enc, code)
			end
		end
		local rebuilt: { number } = {}
		for i = 1, p - 1 do
			table.insert(rebuilt, tape[i])
		end
		for i = 1, #enc do
			table.insert(rebuilt, enc[i])
		end
		for i = p + #enc, #tape do
			table.insert(rebuilt, tape[i])
		end
		for i = #tape, 1, -1 do
			tape[i] = nil
		end
		for i = 1, #rebuilt do
			tape[i] = rebuilt[i]
		end
		return true
	end

	local function mutateEntry(entry: any, corpus: { any }): ({ number }, number, number)
		local tape = cloneNumList(entry.tape or {})
		local ranges = entry.ranges or {}
		local seed = entry.seed
		local size = entry.size
		local mode = randRange(1, 10)
		if mode <= 2 and #corpus >= 2 then
			local other = corpus[randRange(1, #corpus)]
			local ot = other.tape or {}
			if #tape >= 2 and #ot >= 2 then
				local cutA = randRange(1, #tape)
				local cutB = randRange(1, #ot)
				local crossed: { number } = {}
				for i = 1, cutA do
					table.insert(crossed, tape[i])
				end
				for i = cutB, #ot do
					table.insert(crossed, ot[i])
				end
				tape = crossed
			else
				mutateSingleSlot(tape, ranges, randRange(1, 3))
			end
		elseif mode <= 4 then
			mutateSingleSlot(tape, ranges, 1)
		elseif mode <= 6 then
			mutateSingleSlot(tape, ranges, randRange(2, 3))
		elseif mode <= 8 then
			local okS = if randRange(0, 1) == 0 then spliceDictNumber(tape, ranges) else spliceDictString(tape, ranges)
			if not okS then
				if not spliceDictNumber(tape, ranges) and not spliceDictString(tape, ranges) then
					mutateSingleSlot(tape, ranges, randRange(1, 3))
				end
			end
		else
			local ops = randRange(2, 5)
			for _ = 1, ops do
				local roll = randRange(1, 5)
				if roll == 4 then
					spliceDictNumber(tape, ranges)
				elseif roll == 5 then
					spliceDictString(tape, ranges)
				else
					mutateSingleSlot(tape, ranges, roll)
				end
			end
		end
		return tape, seed, size
	end

	local function isAssumedReject(genObj: any, err: any): boolean
		return type(err) == "table" and genObj ~= nil and genObj._s ~= nil and genObj._s.assumedOut ~= nil
	end

	local function runTrial(
		fn: any,
		seedVal: number,
		sizeVal: number,
		forcedTape: { number }?
	): (boolean, boolean, any, any)
		local genObj: any = propApi.gen(seedVal, sizeVal, forcedTape)
		local ok, err = pcall(fn, genObj)
		if not ok and isAssumedReject(genObj, err) then return true, true, nil, genObj end
		return ok, false, err, genObj
	end

	type RawRunner = (number, number, { number }?) -> (boolean, boolean, any, any)

	local function makeRawRunner(propFn: any, trialHook: any): RawRunner
		if type(propFn) == "function" then
			return function(seedVal: number, sizeVal: number, forcedTape: { number }?)
				return runTrial(propFn, seedVal, sizeVal, forcedTape)
			end
		end
		return function(seedVal: number, sizeVal: number, forcedTape: { number }?)
			local tr = trialHook(forcedTape, seedVal, sizeVal)
			local trGen = if type(tr) == "table" and tr._gen ~= nil
				then tr._gen
				else {
					_s = {
						out = (tr and tr.tape) or {},
						ranges = (tr and tr.ranges) or {},
						targets = tr and tr.targets,
						notes = {},
					},
				}
			if type(tr) == "table" and tr.assumed == true then return true, true, nil, trGen end
			local ok = type(tr) == "table" and tr.ok == true
			return ok, false, if ok then nil else (tr and (tr._err or tr.message) or "property failed"), trGen
		end
	end

	local function shrinkTape(
		rawRun: RawRunner,
		seedVal: number,
		sizeVal: number,
		initialTape: { number }
	): ({ number }, any)
		local best = cloneNumList(initialTape)
		local _, _, bestErr = rawRun(seedVal, sizeVal, best)
		local deadline = os.clock() + 0.5
		local budget = 180
		local function check(cand: { number }): boolean
			if budget <= 0 or os.clock() > deadline then return false end
			budget -= 1
			local ok, discarded, err = rawRun(seedVal, sizeVal, cand)
			if not ok and not discarded then
				best = cand
				bestErr = err
				return true
			end
			return false
		end

		if check({}) then return best, bestErr end

		local stepSize = math.max(1, math.floor(#best / 2))
		while stepSize >= 1 and budget > 0 and os.clock() <= deadline do
			local i = 1
			while i <= #best and #best > 1 and budget > 0 do
				local cand: { number } = {}
				for j = 1, #best do
					if j < i or j >= i + stepSize then table.insert(cand, best[j]) end
				end
				-- Re-probe from the same index when deletion succeeds because remaining chunks shift left.
				if not (#cand < #best and check(cand)) then
					i += stepSize
				end
			end
			stepSize = math.floor(stepSize / 2)
		end

		for idx = 1, #best do
			if budget <= 0 or os.clock() > deadline then break end
			if best[idx] > 0 then
				local candZero = cloneNumList(best)
				candZero[idx] = 0
				if not check(candZero) then
					local lo, hi = 0, best[idx]
					while lo + 1 < hi and budget > 0 and os.clock() <= deadline do
						local mid = math.floor((lo + hi) / 2)
						local cand = cloneNumList(best)
						cand[idx] = mid
						if check(cand) then
							hi = mid
						else
							lo = mid
						end
					end
				end
			end
		end
		return best, bestErr
	end

	local totalIterations = 0
	local propsPassed = 0
	local propsFailed = 0
	local campaignEdgesSeen: { [number]: boolean } = {}
	local campaignEdgesCount = 0
	local campaignCmpsSeen: { [number]: boolean } = {}
	local campaignCmpsCount = 0
	local currentFileHint = ""
	local campaignDeadline = os.clock() + (cfg.budget or 5.0)

	local function fuzzSingleProperty(
		name: string,
		propFn: any,
		options: any,
		runOptions: any,
		_filter: string,
		trialHook: any,
		metaFile: string?
	): any
		fuzzCtrl.reset()
		local opts = options or {}
		local rOpts = runOptions or {}
		local baseSeed: number = opts.seed or rOpts.seed or cfg.seed or propApi.DEFAULT_BASE or 0x5EED
		local size: number = opts.size or 40
		local maxRuns = cfg.maxRuns
		local remProps = math.max(1, (cfg.propCountHint or 1) - (propsPassed + propsFailed))
		local sliceBudget = math.max(0.05, (campaignDeadline - os.clock()) / remProps)
		local propDeadline = if maxRuns == nil
			then math.min(campaignDeadline, os.clock() + sliceBudget)
			else campaignDeadline + 30.0
		local fileRel: string = opts.file or metaFile or currentFileHint
		local propLine: number? = nil
		if type(propFn) == "function" then
			local debugInfo: any = debug.info
			local okLine, fnLineRaw = pcall(debugInfo, propFn, "l")
			if okLine and type(fnLineRaw) == "number" and (fnLineRaw :: number) > 0 then
				propLine = fnLineRaw :: number
			end
		end

		local rawRunner = makeRawRunner(propFn, trialHook)
		local function evalTrial(
			seedVal: number,
			sizeVal: number,
			forcedTape: { number }?
		): (boolean, boolean, any, any)
			if type(trialHook) == "function" then
				local hookFn: (...any) -> any = trialHook
				local tr = hookFn(forcedTape, seedVal, sizeVal)
				if type(tr) == "table" then
					local genLike = if tr._gen ~= nil
						then tr._gen
						else {
							_s = { out = tr.tape or {}, ranges = tr.ranges or {}, targets = tr.targets, notes = {} },
						}
					if tr.assumed == true then return true, true, nil, genLike end
					local ok = tr.ok == true
					return ok, false, if ok then nil else (tr._err or tr.message or "property failed"), genLike
				end
			end
			return runTrial(propFn, seedVal, sizeVal, forcedTape)
		end

		local corpusList: { any } = {}
		local initialSeeds: { CorpusItem } = {}
		if cfg.regressions ~= nil and type(cfg.regressions[name]) == "table" then
			for _, tok in cfg.regressions[name] do
				local parsed = withoutTracking(function() return corpusCodec.parseReplay(tok) end)
				if parsed ~= nil then
					if parsed.kind == "tape" then
						table.insert(initialSeeds, { seed = parsed.seed, size = parsed.size, tape = parsed.tape })
					else
						table.insert(initialSeeds, { seed = parsed.seed, size = size, tape = nil })
					end
				end
			end
		end
		if cfg.corpus ~= nil and type(cfg.corpus[name]) == "table" then
			for _, item in cfg.corpus[name] do
				table.insert(initialSeeds, item)
			end
		end

		local failed = false
		local failInfo: any = nil
		local propRuns = 0
		local bestTargetScores: { [string]: number } = {}

		local function recordCorpusAndCheck(
			ok: boolean,
			discarded: boolean,
			err: any,
			genObj: any,
			trialSeed: number,
			trialSize: number,
			usedTape: { number }
		)
			local newCov, distImp = fuzzCtrl.step()
			propRuns += 1
			totalIterations += 1
			if discarded then return end
			if not ok then
				local usedLen = #(if genObj and genObj._s and genObj._s.out then genObj._s.out else usedTape)
				local trimmed: { number } = {}
				for i = 1, math.max(usedLen, #usedTape) do
					if genObj and genObj._s and genObj._s.out and i <= #genObj._s.out then
						trimmed[i] = genObj._s.out[i]
					elseif i <= #usedTape then
						trimmed[i] = usedTape[i]
					end
				end
				local shrinkRes = withoutTracking(function()
					local mTape, mErr = shrinkTape(rawRunner, trialSeed, trialSize, trimmed)
					local _, _, _, mGen = rawRunner(trialSeed, trialSize, mTape)
					return { tape = mTape, err = mErr, gen = mGen }
				end)
				local minTape: { number } = shrinkRes.tape
				local minErr = shrinkRes.err
				local minGen = shrinkRes.gen
				local tok = encodeToken(trialSeed, trialSize, minTape)
				local notes: { string } = {}
				if minGen and minGen._s and minGen._s.notes then
					for _, nt in minGen._s.notes do
						table.insert(notes, if type(nt) == "function" then tostring(nt()) else tostring(nt))
					end
				end
				local errMsg = tostring(minErr or err or "property failed")
				local ce = if #notes > 0
					then table.concat(notes, "; ")
					else string.format("tape[%d] seed=%d", #minTape, trialSeed)
				failed = true
				failInfo = {
					name = name,
					file = fileRel,
					line = propLine,
					message = errMsg,
					counterexample = ce,
					replay = tok,
					seed = trialSeed,
					runs = propRuns,
				}
				emitEvent({
					event = "failure",
					name = name,
					file = fileRel,
					line = if propLine ~= nil then math.floor(propLine) else nil,
					message = errMsg,
					counterexample = ce,
					token = tok,
					seed = math.floor(trialSeed),
					runs = propRuns,
				})
				return
			end

			local targetImp = false
			if genObj and genObj._s and type(genObj._s.targets) == "table" then
				for lbl, score in genObj._s.targets do
					if type(score) == "number" and score == score then
						local prev = bestTargetScores[lbl]
						if prev == nil or score > prev then
							bestTargetScores[lbl] = score
							targetImp = true
						end
					end
				end
			end

			local outTape = if genObj
					and genObj._s
					and genObj._s.out
				then cloneNumList(genObj._s.out)
				else cloneNumList(usedTape)
			local outRanges = if genObj and genObj._s and genObj._s.ranges then cloneNumList(genObj._s.ranges) else {}
			if newCov or distImp or targetImp or #corpusList < 12 then
				table.insert(corpusList, {
					seed = trialSeed,
					size = trialSize,
					tape = outTape,
					ranges = outRanges,
					interesting = newCov or distImp or targetImp,
				})
				if newCov or distImp or targetImp then
					local tok = encodeToken(trialSeed, trialSize, outTape)
					emitEvent({
						event = "corpus",
						prop = name,
						file = fileRel,
						token = tok,
						edges = edgesCovered,
					})
				end
			end
		end

		for _, item in initialSeeds do
			if failed then break end
			if maxRuns ~= nil and propRuns >= maxRuns then break end
			local itemSeed = item.seed or baseSeed
			local itemSize = item.size or size
			local ok, discarded, err, genObj = evalTrial(itemSeed, itemSize, item.tape)
			recordCorpusAndCheck(ok, discarded, err, genObj, itemSeed, itemSize, item.tape or {})
		end

		local randIdx = 0
		while not failed do
			if maxRuns ~= nil then
				if propRuns >= maxRuns then break end
			else
				if os.clock() >= propDeadline then break end
			end
			if #corpusList < 8 or randRange(1, 5) == 1 then
				randIdx += 1
				local caseSeedFn: any = propApi.caseSeed
				local cSeed = if type(caseSeedFn) == "function"
					then (caseSeedFn :: (...any) -> number)(name, baseSeed, randIdx)
					else (baseSeed + randIdx) % U32
				local ok, discarded, err, genObj = evalTrial(cSeed, size, nil)
				local genTape: { number } = if genObj and genObj._s and genObj._s.out then genObj._s.out else {}
				recordCorpusAndCheck(ok, discarded, err, genObj, cSeed, size, genTape)
			else
				local parent = corpusList[randRange(1, #corpusList)]
				if randRange(0, 1) == 0 then
					local pickIdx = randRange(math.max(1, #corpusList - 8), #corpusList)
					parent = corpusList[pickIdx]
				end
				local mutTape, mSeed, mSize = mutateEntry(parent, corpusList)
				local ok, discarded, err, genObj = evalTrial(mSeed, mSize, mutTape)
				recordCorpusAndCheck(ok, discarded, err, genObj, mSeed, mSize, mutTape)
			end
		end

		for edgeKey in seenBuckets do
			if not campaignEdgesSeen[edgeKey] then
				campaignEdgesSeen[edgeKey] = true
				campaignEdgesCount += 1
			end
		end
		for cmpKey in bestCmpDist do
			if not campaignCmpsSeen[cmpKey] then
				campaignCmpsSeen[cmpKey] = true
				campaignCmpsCount += 1
			end
		end
		if failed then
			propsFailed += 1
			return {
				ok = false,
				cases = propRuns,
				exhaustive = false,
				message = failInfo.message,
				original = failInfo.message,
				report = failInfo.message,
				seed = failInfo.seed,
				replay = failInfo.replay,
				attempts = 1,
			}
		end
		propsPassed += 1
		return { ok = true, cases = propRuns, exhaustive = false, attempts = 0 }
	end

	function fuzzCtrl.runProperty(ctx: any)
		if type(ctx) == "table" and (type(ctx.fn) == "function" or type(ctx.trial) == "function") then
			local meta = if type(ctx.meta) == "table" then ctx.meta else {}
			local pName = ctx.name or meta.name or "(property)"
			local pFilter = ctx.filter or meta.filter or pName
			local pOpts = ctx.options or { seed = meta.baseSeed, size = meta.size, file = meta.file }
			local pRunOpts = ctx.runOptions or {}
			return fuzzSingleProperty(pName, ctx.fn, pOpts, pRunOpts, pFilter, ctx.trial, meta.file)
		end
		return nil
	end

	-- Save previous global state so standalone in-process runs (`Fuzz.spec.luau`) never leak hooks.
	local rtMod: any = nil
	local prevRtCtrl: any = nil
	pcall(function()
		local okRt, rt: any = pcall(dynRequire, "@__SERT_FUZZ")
		if okRt and type(rt) == "table" then
			rtMod = rt
			prevRtCtrl = rt.ctrl
			rt.ctrl = fuzzCtrl
		end
	end)

	-- selene: allow(global_usage)
	local hasWritableG = type(_G) == "table" and not table.isfrozen(_G)
	local envSharedG: any = if type(sert) == "table"
			and type(sert.env) == "table"
			and type(sert.env._sharedG) == "table"
			and not table.isfrozen(sert.env._sharedG)
		then sert.env._sharedG
		else nil
	local mutSharedG: any = if type(propApi.mutant) == "table"
			and type(propApi.mutant._sharedG) == "table"
			and not table.isfrozen(propApi.mutant._sharedG)
		then propApi.mutant._sharedG
		else nil

	-- Snapshot all three aliases before writing, because _G, sert.env._sharedG,
	-- and propApi.mutant._sharedG can reference the same table in Luau CLI / lute.
	-- selene: allow(global_usage)
	local prevGlobalFuzz = if hasWritableG then (_G :: any).__SERT_FUZZ else nil
	local prevEnvFuzz = if envSharedG ~= nil then envSharedG.__SERT_FUZZ else nil
	local prevMutFuzz = if mutSharedG ~= nil then rawget(mutSharedG, "__SERT_FUZZ") else nil
	local prevMutRegs = if mutSharedG ~= nil then rawget(mutSharedG, "__SERT_REGRESSIONS") else nil

	if hasWritableG then
		-- selene: allow(global_usage)
		(_G :: any).__SERT_FUZZ = fuzzCtrl
	end
	if envSharedG ~= nil then envSharedG.__SERT_FUZZ = fuzzCtrl end
	if mutSharedG ~= nil then
		rawset(mutSharedG, "__SERT_FUZZ", fuzzCtrl)
		if cfg.regressions ~= nil then rawset(mutSharedG, "__SERT_REGRESSIONS", cfg.regressions) end
	end

	local origSertRun = if type(sert) == "table" then sert.run else nil
	local ranViaEntry = false
	local function patchedRun(opts: any)
		ranViaEntry = true
		local merged: { [string]: any } = {}
		if type(opts) == "table" then
			for k, v in opts do
				merged[k] = v
			end
		end
		if cfg.filter ~= nil then merged.filter = cfg.filter end
		if cfg.grep ~= nil then merged.grep = cfg.grep end
		if cfg.files ~= nil and #cfg.files > 0 then merged.files = cfg.files end
		merged.seed = cfg.seed
		merged.quiet = true
		merged.markers = false
		merged.raise = false
		local tlim = math.max((cfg.budget or 5.0) + 30, 120)
		merged.timeout = tlim
		merged.testTimeout = tlim
		return origSertRun(merged)
	end
	if type(sert) == "table" and type(origSertRun) == "function" then sert.run = patchedRun end

	local wantedSpecs: { string }? = nil
	if cfg.files ~= nil and #(cfg.files :: { string }) > 0 then
		local list: { string } = {}
		for _, f in cfg.files :: { string } do
			table.insert(list, normSpec(f))
		end
		wantedSpecs = list
	end
	local function specMatches(file: string): boolean
		if wantedSpecs == nil then return true end
		local norm = normSpec(file)
		local base = string.match(norm, "[^/]+$") or norm
		for _, w in wantedSpecs :: { string } do
			if norm == w or base == w or string.sub(norm, -#w - 1) == "/" .. w then return true end
		end
		return false
	end

	if cfg.setups ~= nil then
		for _, sItem in cfg.setups do
			pcall(sItem.load)
		end
	end
	if cfg.specs ~= nil then
		for _, spItem in cfg.specs do
			if specMatches(spItem.file) then
				currentFileHint = spItem.file
				local ok, err = pcall(spItem.load)
				if not ok then
					propsFailed += 1
					emitEvent({ event = "error", file = spItem.file, message = tostring(err) })
				end
			end
		end
	end
	if cfg.entries ~= nil then
		for _, entItem in cfg.entries do
			currentFileHint = entItem.file
			local ok, err = pcall(entItem.load)
			if not ok then
				propsFailed += 1
				emitEvent({ event = "error", file = entItem.file, message = tostring(err) })
			end
		end
	end
	if not ranViaEntry and cfg.specs ~= nil and #cfg.specs > 0 and type(origSertRun) == "function" then
		local ok, resOrErr = pcall(patchedRun, {})
		if not ok then
			propsFailed += 1
			emitEvent({ event = "error", file = "", message = tostring(resOrErr) })
		end
	end

	if type(sert) == "table" and type(origSertRun) == "function" then sert.run = origSertRun end
	if rtMod ~= nil then rtMod.ctrl = prevRtCtrl end
	if hasWritableG then
		-- selene: allow(global_usage)
		(_G :: any).__SERT_FUZZ = prevGlobalFuzz
	end
	if envSharedG ~= nil then envSharedG.__SERT_FUZZ = prevEnvFuzz end
	if mutSharedG ~= nil then
		rawset(mutSharedG, "__SERT_FUZZ", prevMutFuzz)
		rawset(mutSharedG, "__SERT_REGRESSIONS", prevMutRegs)
	end

	local effectiveSeed = math.floor(cfg.seed or 0x5EED)
	emitEvent({
		event = "done",
		iterations = totalIterations,
		passed = propsPassed,
		failed = propsFailed,
		edges = campaignEdgesCount,
		bestCmp = campaignCmpsCount,
		seed = effectiveSeed,
	})

	return {
		iterations = totalIterations,
		passed = propsPassed,
		failed = propsFailed,
		edges = campaignEdgesCount,
		bestCmp = campaignCmpsCount,
		seed = effectiveSeed,
	}
end

return fuzz
