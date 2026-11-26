--!strict
-- Value formatting (`repr`), structural diffing (`diff`), and JSON encoding/decoding (`json`, `jsonDecode`).

local bytes = require("./bytes")
local util = require("./util")

local format = {}
local BUFFER_BYTES = 32
local KEY_RANK: { [string]: number } = { number = 1, string = 2 }

local function safeTostring(value: any): (boolean, string)
	local ok, text = pcall(tostring, value)
	if ok and type(text) == "string" then return true, text end
	return false, `<{util.typeof(value)}>`
end

-- Sort numbers ascending (NaN last), then strings, then other keys by type and safe tostring.
function format.keyBefore(a: any, b: any): boolean
	local rankA, rankB = KEY_RANK[type(a)] or 3, KEY_RANK[type(b)] or 3
	if rankA ~= rankB then return rankA < rankB end
	if rankA == 1 then
		local nanA, nanB = a ~= a, b ~= b
		if nanA or nanB then return not nanA and nanB end
		if a == b then
			if a == 0 then return 1 / a < 1 / b end
			return false
		end
		return a < b
	elseif rankA == 2 then
		return a < b
	end
	local _, strA = safeTostring(a)
	local _, strB = safeTostring(b)
	return `{type(a)}:{strA}` < `{type(b)}:{strB}`
end

local keyBefore = format.keyBefore

-- Use `next` instead of generalized iteration so `__iter` metamethods cannot error or loop while formatting.
function format.sortedKeys(value: { [any]: any }): { any }
	local keys = {}
	for key in next, value do
		table.insert(keys, key)
	end
	table.sort(keys, keyBefore)
	return keys
end

local sortedKeys = format.sortedKeys

type Limits = { depth: number, items: number }
local DEFAULT_LIMITS: Limits = { depth = 3, items = 8 }
local DIFF_LIMITS: Limits = { depth = 5, items = 16 }

local function isMatcherTable(value: any): boolean
	if type(value) ~= "table" then return false end
	local meta = getmetatable(value)
	return type(meta) == "table" and rawget(meta, "__sertMatcher") == true
end

local function render(
	value: any,
	level: number,
	limits: Limits,
	focus: { any }?,
	focusIndex: number,
	ancestors: { [any]: boolean }
): string
	local valueType = type(value)
	if valueType == "string" then
		return string.format("%q", value)
	elseif valueType == "number" then
		if value ~= value then return "nan" end
		if value == 0 and 1 / value < 0 then return "-0" end
		return tostring(value)
	elseif valueType == "buffer" then
		local length = buffer.len(value)
		local take = math.min(length, BUFFER_BYTES)
		local parts = table.create(take)
		for offset = 0, take - 1 do
			parts[offset + 1] = string.format("%02x", buffer.readu8(value, offset))
		end
		local more = if length > BUFFER_BYTES then ` … {length - BUFFER_BYTES} more` else ""
		return `buffer({length}){if length > 0 then " " else ""}{table.concat(parts, " ")}{more}`
	elseif valueType == "vector" or valueType == "userdata" then
		local kind = util.typeof(value)
		local _, text = safeTostring(value)
		return if kind == "Instance"
				or kind == "EnumItem"
				or kind == "Enum"
				or kind == "userdata"
			then text
			else `{kind}({text})`
	elseif valueType ~= "table" then
		local _, text = safeTostring(value)
		return text
	end

	if isMatcherTable(value) then
		local desc = rawget(value, "description")
		if type(desc) == "string" then return desc end
		local _, text = safeTostring(value)
		return text
	end

	local double = util.doubleTag(value)
	if double ~= nil then
		local ok, text = safeTostring(value)
		if ok then
			return if double == "Instance" or double == "EnumItem" or double == "Enum" then text else `{double}({text})`
		end
		return `<{double}>`
	end

	local meta = getmetatable(value)
	if type(meta) == "table" and rawget(meta, "__tostring") ~= nil then
		local _, text = safeTostring(value)
		return text
	elseif meta ~= nil and type(meta) ~= "table" then
		local ok, text = safeTostring(value)
		if not ok or not string.match(text, "^table: 0x") then return text end
	end

	-- Track active ancestor tables so cycles render `<cycle>` even along `format.diff` focus paths.
	if ancestors[value] then return "<cycle>" end

	local onPath = focus ~= nil and focus[focusIndex] ~= nil
	if level > limits.depth and not onPath then return "{…}" end

	ancestors[value] = true
	local focusKey = if onPath then (focus :: { any })[focusIndex] else nil
	local parts, count, elided, arrayIndex = {}, 0, false, 1
	for _, key in sortedKeys(value) do
		local isFocus = onPath and rawequal(key, focusKey)
		if count >= limits.items and not isFocus then
			if not elided then
				elided = true
				table.insert(parts, "…")
			end
			continue
		end
		count += 1
		local prefix: string
		if key == arrayIndex and not elided then
			arrayIndex += 1
			prefix = ""
		elseif type(key) == "string" and string.match(key, "^[_%a][_%w]*$") ~= nil then
			prefix = `{key} = `
		else
			prefix = `[{render(key, level + 1, limits, nil, 1, ancestors)}] = `
		end
		local item = rawget(value, key)
		local text = if isFocus
			then render(item, level + 1, limits, focus, focusIndex + 1, ancestors)
			else render(
				item,
				if onPath then math.min(level + 1, limits.depth) else level + 1,
				limits,
				nil,
				1,
				ancestors
			)
		table.insert(parts, prefix .. text)
	end
	ancestors[value] = nil
	return if #parts == 0 then "{}" else "{ " .. table.concat(parts, ", ") .. " }"
end

--- Formats `value` as compact Luau syntax for failure messages and traces.
function format.repr(value: any, maxDepth: number?): string
	local limits: Limits = if maxDepth ~= nil
		then { depth = maxDepth, items = DEFAULT_LIMITS.items }
		else DEFAULT_LIMITS
	return render(value, 1, limits, nil, 1, {})
end

local function pathText(path: { any }): string
	local parts = {}
	for _, key in path do
		table.insert(
			parts,
			if type(key) == "string" and string.match(key, "^[_%a][_%w]*$") ~= nil
				then `.{key}`
				else `[{render(key, 1, DEFAULT_LIMITS, nil, 1, {})}]`
		)
	end
	return table.concat(parts)
end

local UNREADABLE = table.freeze({})

-- Reads `container[key]` without allowing strict `__index` tables or invalid userdata properties to crash diffing.
local function safeReadField(container: any, key: any, raw: boolean): (boolean, any)
	local kind = type(container)
	if kind == "table" then
		if isMatcherTable(container) then return false, nil end
		local direct = rawget(container, key)
		if raw or direct ~= nil or getmetatable(container) == nil then return true, direct end
		local ok, value = pcall(function() return container[key] end)
		return ok, if ok then value else nil
	elseif not raw and kind == "userdata" then
		local ok, value = pcall(function() return container[key] end)
		return ok, if ok then value else nil
	end
	return false, nil
end

function format.snapNum(n: number): string
	if n ~= n then return "nan" end
	if n == math.huge then
		return "inf"
	elseif n == -math.huge then
		return "-inf"
	end
	if n == 0 then return "0" end
	if n % 1 == 0 and math.abs(n) < 1e15 then return tostring(n) end
	return string.format("%.6g", n)
end

local snapNum = format.snapNum

local function signedDelta(delta: number): string
	if delta ~= delta then return "nan" end
	local s = snapNum(delta)
	if delta > 0 and string.sub(s, 1, 1) ~= "+" then return "+" .. s end
	return s
end

local CFRAME_PART_NAMES = { "X", "Y", "Z", "R00", "R01", "R02", "R10", "R11", "R12", "R20", "R21", "R22" }

function format.datatypeComponents(value: any): (string, { { any } }?)
	local kind = util.typeof(value)
	local v: any = value
	if kind == "vector" then
		return kind, { { "x", v.x }, { "y", v.y }, { "z", v.z } }
	elseif kind == "Vector2" or kind == "Vector2int16" then
		return kind, { { "X", v.X }, { "Y", v.Y } }
	elseif kind == "Vector3" or kind == "Vector3int16" then
		return kind, { { "X", v.X }, { "Y", v.Y }, { "Z", v.Z } }
	elseif kind == "Color3" then
		return kind, { { "R", v.R }, { "G", v.G }, { "B", v.B } }
	elseif kind == "UDim" then
		return kind, { { "Scale", v.Scale }, { "Offset", v.Offset } }
	elseif kind == "UDim2" then
		return kind,
			{
				{ "X.Scale", v.X.Scale },
				{ "X.Offset", v.X.Offset },
				{ "Y.Scale", v.Y.Scale },
				{ "Y.Offset", v.Y.Offset },
			}
	elseif kind == "Rect" then
		return kind,
			{
				{ "Min.X", v.Min.X },
				{ "Min.Y", v.Min.Y },
				{ "Max.X", v.Max.X },
				{ "Max.Y", v.Max.Y },
			}
	elseif kind == "NumberRange" then
		return kind, { { "Min", v.Min }, { "Max", v.Max } }
	elseif kind == "CFrame" then
		local okC, comps = pcall(function() return { v:GetComponents() } end)
		if okC and type(comps) == "table" and #comps >= 12 then
			local pairsOut: { { any } } = {}
			for i = 1, 12 do
				table.insert(pairsOut, { CFRAME_PART_NAMES[i], comps[i] })
			end
			return kind, pairsOut
		end
	end
	return kind, nil
end

local datatypeComponents = format.datatypeComponents

local function datatypeDeltaNote(actual: any, expected: any): string?
	local kindA, partsA = datatypeComponents(actual)
	local kindB, partsB = datatypeComponents(expected)
	if kindA ~= kindB or partsA == nil or partsB == nil then return nil end

	if kindA == "CFrame" then
		local cA, cB = partsA, partsB
		local diffs: { string } = {}
		for i = 1, 3 do
			local vA, vB = cA[i][2] :: number, cB[i][2] :: number
			local d = vA - vB
			if d ~= 0 or (d ~= d and (vA == vA or vB == vB)) then table.insert(diffs, `{cA[i][1]}={signedDelta(d)}`) end
		end
		local maxRotDelta = 0
		local rotDiffer = false
		for i = 4, 12 do
			local d = math.abs((cA[i][2] :: number) - (cB[i][2] :: number))
			if d ~= 0 then
				rotDiffer = true
				if d == d and d > maxRotDelta then maxRotDelta = d end
			end
		end
		if rotDiffer then table.insert(diffs, `rot max Δ={snapNum(maxRotDelta)}`) end
		if #diffs > 0 then return `Δ {table.concat(diffs, ", ")}` end
		return nil
	end

	local diffs: { string } = {}
	for i = 1, #partsA do
		local name = partsA[i][1] :: string
		local valA = partsA[i][2] :: number
		local valB = partsB[i][2] :: number
		local bothNan = valA ~= valA and valB ~= valB
		if not bothNan and valA ~= valB then table.insert(diffs, `{name}={signedDelta(valA - valB)}`) end
	end
	if #diffs > 0 then return `Δ {table.concat(diffs, ", ")}` end
	return nil
end

local INSTANCE_KEY_PROPS = {
	"Name",
	"Parent",
	"Value",
	"Visible",
	"Text",
	"Position",
	"Size",
	"Anchored",
	"CanCollide",
	"Transparency",
	"Color",
	"AbsolutePosition",
	"AbsoluteSize",
}

local function instanceLabel(inst: any): (string, string)
	local okCls, cls = pcall(function() return inst.ClassName end)
	local clsName = if okCls and type(cls) == "string" then cls else "Instance"
	local okFull, full = pcall(function() return inst:GetFullName() end)
	if okFull and type(full) == "string" then return clsName, full end
	local okNm, nm = pcall(function() return inst.Name end)
	return clsName, if okNm and type(nm) == "string" then nm else "?"
end

local function renderShort(v: any): string return render(v, 1, DEFAULT_LIMITS, nil, 1, {}) end

local function mergedStringKeys(a: { [any]: any }, b: { [any]: any }): { string }
	local keys: { string } = {}
	local seenK: { [string]: boolean } = {}
	for _, tbl in { b, a } do
		for k in next, tbl do
			if type(k) == "string" and not seenK[k] then
				seenK[k] = true
				table.insert(keys, k)
			end
		end
	end
	table.sort(keys)
	return keys
end

local function instanceDiffNote(actual: any, expected: any): string?
	if util.typeof(actual) ~= "Instance" or util.typeof(expected) ~= "Instance" or actual == expected then
		return nil
	end
	local expCls, expFull = instanceLabel(expected)
	local actCls, actFull = instanceLabel(actual)
	local header = string.format("expected %s %q, got %s %q", expCls, expFull, actCls, actFull)

	local diffs: { string } = {}
	if expCls == actCls then
		for _, propName in INSTANCE_KEY_PROPS do
			if #diffs >= 6 then break end
			local okA, vA = pcall(function() return actual[propName] end)
			local okB, vB = pcall(function() return expected[propName] end)
			if okA and okB and vA ~= vB then
				if propName == "Parent" then
					local pAStr = if vA == nil then "nil" else select(2, instanceLabel(vA))
					local pBStr = if vB == nil then "nil" else select(2, instanceLabel(vB))
					table.insert(diffs, `Parent: {pBStr} -> {pAStr}`)
				else
					table.insert(diffs, `{propName}: {renderShort(vB)} -> {renderShort(vA)}`)
				end
			end
		end

		if #diffs < 6 then
			local okAA, attrsA = pcall(function() return actual:GetAttributes() end)
			local okAB, attrsB = pcall(function() return expected:GetAttributes() end)
			if okAA and okAB and type(attrsA) == "table" and type(attrsB) == "table" then
				for _, k in mergedStringKeys(attrsA :: { [any]: any }, attrsB :: { [any]: any }) do
					if #diffs >= 6 then break end
					local vA, vB = (attrsA :: any)[k], (attrsB :: any)[k]
					if vA ~= vB then table.insert(diffs, `attr[{k}]: {renderShort(vB)} -> {renderShort(vA)}`) end
				end
			end
		end

		if #diffs < 6 then
			local okTA, tagsA = pcall(function() return actual:GetTags() end)
			local okTB, tagsB = pcall(function() return expected:GetTags() end)
			if okTA and okTB and type(tagsA) == "table" and type(tagsB) == "table" then
				local sA = table.concat(tagsA :: { string }, ",")
				local sB = table.concat(tagsB :: { string }, ",")
				if sA ~= sB then table.insert(diffs, `tags: [{sB}] -> [{sA}]`) end
			end
		end

		if #diffs < 6 then
			local okCA, chA = pcall(function() return #actual:GetChildren() end)
			local okCB, chB = pcall(function() return #expected:GetChildren() end)
			if okCA and okCB and chA ~= chB then table.insert(diffs, `children: {chB} -> {chA}`) end
		end
	end

	if #diffs > 0 then return `{header}; {table.concat(diffs, ", ")}` end
	return header
end

local function splitLines(text: string): { string }
	local lines: { string } = {}
	local pos = 1
	while true do
		local nl = string.find(text, "\n", pos, true)
		if nl == nil then
			table.insert(lines, string.sub(text, pos))
			break
		end
		table.insert(lines, string.sub(text, pos, nl - 1))
		pos = nl + 1
	end
	return lines
end

local function diffMultilineStrings(actualStr: string, expectedStr: string): (number, number, string)
	local expLines = splitLines(expectedStr)
	local actLines = splitLines(actualStr)

	local crlfOnly = #expLines == #actLines
	if crlfOnly then
		for i = 1, #expLines do
			if (string.gsub(expLines[i], "\r$", "")) ~= (string.gsub(actLines[i], "\r$", "")) then
				crlfOnly = false
				break
			end
		end
	end
	if crlfOnly then return #expLines, #actLines, "  line endings differ (\\r\\n vs \\n)" end

	type OpLine = { tag: string, text: string }
	local ops: { OpLine } = {}
	local n, m = #expLines, #actLines
	if n * m <= 40000 then
		local dp: { { number } } = table.create(n + 1) :: any
		for i = 1, n + 1 do
			dp[i] = table.create(m + 1, 0)
		end
		for i = n, 1, -1 do
			local row = dp[i]
			local nextRow = dp[i + 1]
			local eLine = expLines[i]
			for j = m, 1, -1 do
				if eLine == actLines[j] then
					row[j] = nextRow[j + 1] + 1
				else
					local a, b = nextRow[j], row[j + 1]
					row[j] = if a >= b then a else b
				end
			end
		end
		local i, j = 1, 1
		while i <= n and j <= m do
			if expLines[i] == actLines[j] then
				table.insert(ops, { tag = " ", text = expLines[i] })
				i += 1
				j += 1
			elseif dp[i + 1][j] >= dp[i][j + 1] then
				table.insert(ops, { tag = "-", text = expLines[i] })
				i += 1
			else
				table.insert(ops, { tag = "+", text = actLines[j] })
				j += 1
			end
		end
		while i <= n do
			table.insert(ops, { tag = "-", text = expLines[i] })
			i += 1
		end
		while j <= m do
			table.insert(ops, { tag = "+", text = actLines[j] })
			j += 1
		end
	else
		local maxLen = math.max(n, m)
		for idx = 1, maxLen do
			local eLine, aLine = expLines[idx], actLines[idx]
			if eLine == aLine then
				table.insert(ops, { tag = " ", text = eLine })
			else
				if eLine ~= nil then table.insert(ops, { tag = "-", text = eLine }) end
				if aLine ~= nil then table.insert(ops, { tag = "+", text = aLine }) end
			end
		end
	end

	local keep: { [number]: boolean } = {}
	for idx, op in ops do
		if op.tag ~= " " then
			keep[idx] = true
			if idx > 1 then keep[idx - 1] = true end
			if idx < #ops then keep[idx + 1] = true end
		end
	end

	local out: { string } = { "  --- expected", "  +++ actual" }
	local MAX_LINES = 24
	local emitted = 0
	local remaining = 0
	local lastKept = 0
	for idx, op in ops do
		if keep[idx] then
			if lastKept > 0 and idx > lastKept + 1 then
				if emitted < MAX_LINES then
					table.insert(out, "  @@ … @@")
					emitted += 1
				else
					remaining += 1
				end
			end
			lastKept = idx
			if emitted < MAX_LINES then
				local prefix = if op.tag == " " then "   " else ` {op.tag} `
				table.insert(out, `{prefix}{op.text}`)
				emitted += 1
			else
				remaining += 1
			end
		end
	end
	if remaining > 0 then table.insert(out, `  … (+{remaining} more diff lines)`) end
	return n, m, table.concat(out, "\n")
end

local MAX_DIFF_LINES = 8
local MAX_DIFF_SCAN = 1000

type DiffLeaf = {
	path: { any },
	note: string?,
}

type DiffCollectState = {
	diffs: { DiffLeaf },
	total: number,
	visiting: { [any]: { [any]: boolean } },
	equalCache: { [any]: { [any]: boolean } },
}

local function recordDiff(state: DiffCollectState, path: { any }, note: string?)
	state.total += 1
	if #state.diffs < MAX_DIFF_LINES then table.insert(state.diffs, { path = table.clone(path), note = note }) end
end

-- Collects up to `MAX_DIFF_LINES` leaf differences between `a` and `b`, counting additional differences up to `MAX_DIFF_SCAN`.
local function collectDifferences(a: any, b: any, path: { any }, state: DiffCollectState, raw: boolean)
	if state.total >= MAX_DIFF_SCAN then return end

	if not raw and isMatcherTable(b) then
		local checkFn = rawget(b, "check")
		if type(checkFn) == "function" then
			local fn = checkFn :: (any, { any }) -> (boolean, { any }?, string?)
			local pass, subPath, reason = fn(a, path)
			if not pass then recordDiff(state, subPath or path, reason) end
			return
		end
	end

	local typeA, typeB = type(a), type(b)
	if typeA ~= typeB then
		recordDiff(state, path, nil)
		return
	end
	if typeA == "number" then
		if a ~= a and b ~= b then return end
		if a ~= b then
			recordDiff(state, path, nil)
			return
		end
		if raw and a == 0 and 1 / a ~= 1 / b then recordDiff(state, path, "signed zero mismatch (-0.0 vs +0.0)") end
		return
	elseif typeA == "vector" then
		if raw then
			local va: any, vb: any = a, b
			local eqX = (va.x == vb.x and (va.x ~= 0 or 1 / va.x == 1 / vb.x)) or (va.x ~= va.x and vb.x ~= vb.x)
			local eqY = (va.y == vb.y and (va.y ~= 0 or 1 / va.y == 1 / vb.y)) or (va.y ~= va.y and vb.y ~= vb.y)
			local eqZ = (va.z == vb.z and (va.z ~= 0 or 1 / va.z == 1 / vb.z)) or (va.z ~= va.z and vb.z ~= vb.z)
			if not (eqX and eqY and eqZ) then recordDiff(state, path, datatypeDeltaNote(a, b)) end
			return
		end
		if a ~= b then recordDiff(state, path, datatypeDeltaNote(a, b)) end
		return
	end

	if if raw then rawequal(a, b) else a == b then return end

	if typeA == "buffer" then
		if not bytes.equal(a, b) then recordDiff(state, path, bytes.diff(a, b)) end
		return
	elseif typeA ~= "table" then
		if not (raw and a == b) then
			local note = instanceDiffNote(a, b) or datatypeDeltaNote(a, b)
			recordDiff(state, path, note)
		end
		return
	end

	if not raw and (getmetatable(a) ~= nil or getmetatable(b) ~= nil) then
		if util.doubleTag(a) ~= nil or util.doubleTag(b) ~= nil then
			local note = instanceDiffNote(a, b) or datatypeDeltaNote(a, b)
			recordDiff(state, path, note)
		else
			recordDiff(
				state,
				path,
				"tables with metatables compare by identity or __eq; use sert.exact(expected) to compare raw fields"
			)
		end
		return
	end

	local visitingA = state.visiting[a]
	if visitingA ~= nil and visitingA[b] then return end
	local cachedA = state.equalCache[a]
	if cachedA ~= nil and cachedA[b] then return end

	if visitingA == nil then
		visitingA = {}
		state.visiting[a] = visitingA
	end
	visitingA[b] = true
	local beforeTotal = state.total

	local keys, present: { [any]: boolean } = sortedKeys(b), {}
	for _, key in keys do
		present[key] = true
	end
	for _, key in sortedKeys(a) do
		if not present[key] then table.insert(keys, key) end
	end
	table.sort(keys, keyBefore)
	for _, key in keys do
		if state.total >= MAX_DIFF_SCAN then break end
		table.insert(path, key)
		local _, valA = safeReadField(a, key, raw)
		local _, valB = safeReadField(b, key, raw)
		collectDifferences(valA, valB, path, state, raw)
		table.remove(path)
	end

	visitingA[b] = nil
	if state.total == beforeTotal then
		local eqA = state.equalCache[a]
		if eqA == nil then
			eqA = {}
			state.equalCache[a] = eqA
		end
		eqA[b] = true
	end
end

local function resolveLeafValues(actual: any, expected: any, path: { any }, isRaw: boolean): (any, any)
	local here, there = actual, expected
	local hereBroken, thereBroken = false, false
	for _, key in path do
		if not hereBroken then
			local okHere, nextHere = safeReadField(here, key, isRaw)
			if okHere then
				here = nextHere
			else
				here = UNREADABLE
				hereBroken = true
			end
		end
		if not thereBroken then
			if isMatcherTable(there) then
				-- When a matcher (`subset`) reported a deeper sub-path, check `_partial` before falling back.
				local partial = rawget(there, "_partial")
				if type(partial) == "table" then
					local okPartial, nextPartial = safeReadField(partial, key, false)
					if okPartial then
						there = nextPartial
					else
						there = UNREADABLE
						thereBroken = true
					end
				else
					thereBroken = true
				end
			else
				local okThere, nextThere = safeReadField(there, key, isRaw)
				if okThere then
					there = nextThere
				else
					there = UNREADABLE
					thereBroken = true
				end
			end
		end
		if hereBroken and thereBroken then break end
	end
	return here, there
end

local function reprLeaf(value: any): string
	if value == UNREADABLE then return "<unreadable>" end
	return format.repr(value)
end

--- Returns up to 8 leaf path differences between `actual` and `expected`, or `nil` when equal.
function format.diff(actual: any, expected: any, raw: boolean?): string?
	local isRaw = raw == true
	local state: DiffCollectState = {
		diffs = {},
		total = 0,
		visiting = {},
		equalCache = {},
	}
	collectDifferences(actual, expected, {}, state, isRaw)
	if #state.diffs == 0 then return nil end

	local lines: { string } = {}
	for _, diff in state.diffs do
		local here, there = resolveLeafValues(actual, expected, diff.path, isRaw)
		local where = if #diff.path > 0 then `actual{pathText(diff.path)}: ` else ""
		local note = diff.note
		if
			type(here) == "string"
			and type(there) == "string"
			and here ~= there
			and (string.find(here, "\n", 1, true) ~= nil or string.find(there, "\n", 1, true) ~= nil)
		then
			local expCount, actCount, block = diffMultilineStrings(here, there)
			table.insert(
				lines,
				`{where}multiline strings differ ({expCount} expected {if expCount == 1 then "line" else "lines"}, {actCount} actual {if actCount
						== 1
					then "line"
					else "lines"}):\n{block}`
			)
		else
			table.insert(
				lines,
				`{where}expected {reprLeaf(there)}, got {reprLeaf(here)}{if note and note ~= "" then ` ({note})` else ""}`
			)
		end
	end
	if state.total > MAX_DIFF_LINES then
		table.insert(lines, `… and {state.total - MAX_DIFF_LINES} more differences`)
	end
	local firstPath = state.diffs[1].path
	if #firstPath > 0 then
		table.insert(lines, `  expected: {render(expected, 1, DIFF_LIMITS, firstPath, 1, {})}`)
		table.insert(lines, `  actual:   {render(actual, 1, DIFF_LIMITS, firstPath, 1, {})}`)
	end
	return table.concat(lines, "\n")
end

--- Formats a raised error value into diagnostic text without throwing if `__tostring` fails.
function format.errorText(err: any): string
	local ok, text = pcall(function(): any
		if type(err) == "table" then
			local meta = getmetatable(err)
			if not (type(meta) == "table" and rawget(meta, "__tostring") ~= nil) then return format.repr(err) end
		end
		local strOk, str = safeTostring(err)
		if not strOk then error("tostring failed", 0) end
		return str
	end)
	if ok and type(text) == "string" then return util.stripStagePrefix(text) end
	return `<{util.typeof(err)} error>`
end

-- Weak set of tables that should encode as `[]` even when empty.
local arrays: { [any]: boolean } = setmetatable({}, { __mode = "k" }) :: any

--- Marks `list` so `format.json` encodes it as `[]` even when empty, and returns `list`.
function format.array<T>(list: T): T
	arrays[list] = true
	return list
end

local ESCAPES: { [string]: string } = {
	['"'] = '\\"',
	["\\"] = "\\\\",
	["\b"] = "\\b",
	["\f"] = "\\f",
	["\n"] = "\\n",
	["\r"] = "\\r",
	["\t"] = "\\t",
}
local UNESCAPES: { [string]: string } = { b = "\b", f = "\f", n = "\n", r = "\r", t = "\t" }

local function quote(text: string): string
	return '"'
		.. string.gsub(
			text,
			'[%c"\\]',
			function(char: string): string return ESCAPES[char] or string.format("\\u%04x", string.byte(char)) end
		)
		.. '"'
end

--- Options for `format.json` and `format.jsonDecode`. `strict = true` enforces `HttpService:JSONEncode` rules.
export type JsonOptions = {
	strict: boolean?,
	buffer: ((value: buffer) -> string)?,
	revive: ((object: { [string]: any }) -> any)?,
	prefix: string?,
}

local LENIENT: JsonOptions = {}

local function encodeJson(value: any, depth: number, options: JsonOptions, seen: { [any]: boolean }): string
	local isStrict = options.strict == true
	local function fail(message: string): never error(`{options.prefix or ""}{message}`, 0) end
	if depth > 100 then return if isStrict then fail("nesting too deep") else "null" end
	local kind = type(value)
	if value == nil then
		return "null"
	elseif kind == "boolean" then
		return if value then "true" else "false"
	elseif kind == "number" then
		if value ~= value or value == math.huge or value == -math.huge then
			return if isStrict then fail("can't convert a non-finite number to JSON") else "null"
		elseif value % 1 == 0 and math.abs(value) < 2 ^ 53 then
			return string.format("%d", value)
		end
		return if isStrict then tostring(value) else string.format("%.17g", value)
	elseif kind == "string" then
		return quote(value)
	elseif kind == "buffer" and options.buffer ~= nil then
		return options.buffer(value)
	elseif kind == "table" then
		if seen[value] then return if isStrict then fail("nesting too deep") else "null" end
		seen[value] = true
		local arrayLen: number? = nil
		if isStrict then
			local n, count, maxInt, allPosInt = #value, 0, 0, true
			for k in next, value do
				count += 1
				if type(k) == "number" and k >= 1 and k % 1 == 0 then
					maxInt = math.max(maxInt, k)
				else
					allPosInt = false
				end
			end
			if count == n or (count > 0 and allPosInt and maxInt <= 1024) then arrayLen = math.max(n, maxInt) end
		elseif rawget(value, 1) ~= nil or arrays[value] then
			arrayLen = #value
		end
		if arrayLen ~= nil then
			local parts = table.create(arrayLen)
			for index = 1, arrayLen do
				parts[index] = encodeJson(rawget(value, index), depth + 1, options, seen)
			end
			seen[value] = nil
			return "[" .. table.concat(parts, ",") .. "]"
		end
		local entries: { { key: string, item: any } } = {}
		for key: any, item in next, value do
			if isStrict and type(key) ~= "string" then
				fail("can't convert a table with mixed or non-string keys to JSON")
			end
			local _, kStr = safeTostring(key)
			table.insert(entries, { key = kStr, item = item })
		end
		table.sort(
			entries,
			function(a: { key: string, item: any }, b: { key: string, item: any }) return a.key < b.key end
		)
		local parts = table.create(#entries)
		for index, entry in entries do
			parts[index] = quote(entry.key) .. ":" .. encodeJson(entry.item, depth + 1, options, seen)
		end
		seen[value] = nil
		return "{" .. table.concat(parts, ",") .. "}"
	end
	if isStrict then return fail(`can't convert a {util.typeof(value)} to JSON`) end
	local _, text = safeTostring(value)
	return quote(text)
end

--- Encodes `value` as JSON with sorted object keys. Pass `options.strict = true` to enforce `HttpService:JSONEncode` rules.
function format.json(value: any, options: JsonOptions?): string return encodeJson(value, 0, options or LENIENT, {}) end

--- Decodes JSON `text` into Luau values, passing decoded objects through `options.revive` when provided.
function format.jsonDecode(text: string, options: JsonOptions?): any
	local o = options or LENIENT
	local revive = o.revive
	local function fail(message: string): never error(`{o.prefix or ""}{message}`, 0) end
	local at = 1
	local function skip() at = string.find(text, "[^ \t\r\n]", at) or #text + 1 end
	local function expect(literal: string)
		if string.sub(text, at, at + #literal - 1) ~= literal then fail(`invalid JSON at character {at}`) end
		at += #literal
	end
	local parseValue: () -> any
	local function parseString(): string
		expect('"')
		local parts = {}
		while true do
			local stop = string.find(text, '["\\]', at)
			if stop == nil then return fail("unterminated string") end
			table.insert(parts, string.sub(text, at, stop - 1))
			at = stop
			if string.sub(text, at, at) == '"' then
				at += 1
				return table.concat(parts)
			end
			local escape = string.sub(text, at + 1, at + 1)
			if escape == "u" then
				local hex = string.sub(text, at + 2, at + 5)
				if string.match(hex, "^%x%x%x%x$") == nil then fail("invalid \\u escape") end
				local code = tonumber(hex, 16) :: number
				at += 6
				if code >= 0xD800 and code <= 0xDBFF and string.sub(text, at, at + 1) == "\\u" then
					local lowHex = string.sub(text, at + 2, at + 5)
					if string.match(lowHex, "^%x%x%x%x$") ~= nil then
						local low = tonumber(lowHex, 16)
						if low ~= nil and low >= 0xDC00 and low <= 0xDFFF then
							at += 6
							code = 0x10000 + (code - 0xD800) * 0x400 + (low - 0xDC00)
						end
					end
				end
				table.insert(parts, utf8.char(code))
			else
				table.insert(parts, UNESCAPES[escape] or escape)
				at += 2
			end
		end
	end
	function parseValue(): any
		skip()
		local ch = string.sub(text, at, at)
		if ch == "{" then
			at += 1
			local object = {}
			skip()
			if string.sub(text, at, at) == "}" then
				at += 1
				return if revive ~= nil then revive(object) else object
			end
			while true do
				skip()
				local key = parseString()
				skip()
				expect(":")
				object[key] = parseValue()
				skip()
				if string.sub(text, at, at) == "}" then
					at += 1
					break
				end
				expect(",")
			end
			return if revive ~= nil then revive(object) else object
		elseif ch == "[" then
			at += 1
			local array = {}
			skip()
			if string.sub(text, at, at) == "]" then
				at += 1
				return array
			end
			while true do
				table.insert(array, parseValue())
				skip()
				if string.sub(text, at, at) == "]" then
					at += 1
					break
				end
				expect(",")
			end
			return array
		elseif ch == '"' then
			return parseString()
		elseif ch == "t" then
			expect("true")
			return true
		elseif ch == "f" then
			expect("false")
			return false
		elseif ch == "n" then
			expect("null")
			return nil
		end
		local number = string.match(text, "^-?%d+%.?%d*[eE]?[-+]?%d*", at)
		if number == nil or tonumber(number) == nil then fail(`invalid JSON at character {at}`) end
		at += #(number :: string)
		return tonumber(number)
	end
	local value = parseValue()
	skip()
	if at <= #text then fail("trailing characters after JSON value") end
	return value
end

local function sanitizeJsonValue(value: any, depth: number, limit: number, seen: { [any]: boolean }): any
	local kind = type(value)
	if value == nil or kind == "boolean" then return value end
	if kind == "number" then
		if value == value and math.abs(value) ~= math.huge then return value end
		return if value ~= value then "nan" else tostring(value)
	elseif kind == "string" then
		if #value > 1024 then return string.sub(value, 1, 1021) .. "..." end
		return value
	elseif kind == "table" then
		if isMatcherTable(value) or util.doubleTag(value) ~= nil or getmetatable(value) ~= nil then
			if util.typeof(value) == "Instance" then
				local cls, full = instanceLabel(value)
				return string.format("%s %q", cls, full)
			end
			return format.repr(value)
		end
		if seen[value] then return "<cycle>" end
		if depth > limit then return "{…}" end
		seen[value] = true
		local keys = sortedKeys(value)
		local n = #value
		local isArr = #keys == n and (n == 0 or (keys[1] == 1 and keys[n] == n))
		local out: { [any]: any } = {}
		if isArr then
			local take = math.min(n, 16)
			for i = 1, take do
				out[i] = sanitizeJsonValue(rawget(value, i), depth + 1, limit, seen)
			end
			if n > 16 then table.insert(out, `… {n - 16} more`) end
		else
			local taken = 0
			for _, k in keys do
				if taken >= 16 then
					out["…"] = `{#keys - 16} more`
					break
				end
				taken += 1
				local _, kStr = safeTostring(k)
				out[kStr] = sanitizeJsonValue(rawget(value, k), depth + 1, limit, seen)
			end
		end
		seen[value] = nil
		return out
	end
	if util.typeof(value) == "Instance" then
		local cls, full = instanceLabel(value)
		return string.format("%s %q", cls, full)
	end
	return format.repr(value)
end

--- Converts arbitrary values into bounded JSON-encodable structures for structured diagnostics.
function format.jsonValue(value: any, maxDepth: number?): any return sanitizeJsonValue(value, 1, maxDepth or 3, {}) end

local DATATYPE_FORMATTERS: { [string]: (v: any) -> string } = {
	Vector2 = function(v: any): string return `Vector2.new({snapNum(v.X)}, {snapNum(v.Y)})` end,
	Vector3 = function(v: any): string return `Vector3.new({snapNum(v.X)}, {snapNum(v.Y)}, {snapNum(v.Z)})` end,
	Vector2int16 = function(v: any): string return `Vector2int16.new({snapNum(v.X)}, {snapNum(v.Y)})` end,
	Vector3int16 = function(v: any): string return `Vector3int16.new({snapNum(v.X)}, {snapNum(v.Y)}, {snapNum(v.Z)})` end,
	UDim = function(v: any): string return `UDim.new({snapNum(v.Scale)}, {snapNum(v.Offset)})` end,
	UDim2 = function(v: any): string
		return `UDim2.new({snapNum(v.X.Scale)}, {snapNum(v.X.Offset)}, {snapNum(v.Y.Scale)}, {snapNum(v.Y.Offset)})`
	end,
	Color3 = function(v: any): string return `Color3.new({snapNum(v.R)}, {snapNum(v.G)}, {snapNum(v.B)})` end,
	BrickColor = function(v: any): string return `BrickColor.new({quote(v.Name)})` end,
	CFrame = function(v: any): string
		local comps = table.pack(v:GetComponents())
		local parts = table.create(comps.n)
		for i = 1, comps.n do
			parts[i] = snapNum(comps[i])
		end
		return `CFrame.new({table.concat(parts, ", ")})`
	end,
	Rect = function(v: any): string
		return `Rect.new({snapNum(v.Min.X)}, {snapNum(v.Min.Y)}, {snapNum(v.Max.X)}, {snapNum(v.Max.Y)})`
	end,
	Region3 = function(v: any): string
		local center = v.CFrame.Position
		local half = v.Size * 0.5
		local minP, maxP = center - half, center + half
		return `Region3.new(Vector3.new({snapNum(minP.X)}, {snapNum(minP.Y)}, {snapNum(minP.Z)}), Vector3.new({snapNum(
			maxP.X
		)}, {snapNum(maxP.Y)}, {snapNum(maxP.Z)}))`
	end,
	Region3int16 = function(v: any): string
		return `Region3int16.new(Vector3int16.new({snapNum(v.Min.X)}, {snapNum(v.Min.Y)}, {snapNum(v.Min.Z)}), Vector3int16.new({snapNum(
			v.Max.X
		)}, {snapNum(v.Max.Y)}, {snapNum(v.Max.Z)}))`
	end,
	NumberRange = function(v: any): string return `NumberRange.new({snapNum(v.Min)}, {snapNum(v.Max)})` end,
	Ray = function(v: any): string
		local o, d = v.Origin, v.Direction
		return `Ray.new(Vector3.new({snapNum(o.X)}, {snapNum(o.Y)}, {snapNum(o.Z)}), Vector3.new({snapNum(d.X)}, {snapNum(
			d.Y
		)}, {snapNum(d.Z)}))`
	end,
	ColorSequence = function(v: any): string
		local parts: { string } = {}
		for _, kp in v.Keypoints do
			local c = kp.Value
			table.insert(
				parts,
				`ColorSequenceKeypoint.new({snapNum(kp.Time)}, Color3.new({snapNum(c.R)}, {snapNum(c.G)}, {snapNum(c.B)}))`
			)
		end
		return "ColorSequence.new({" .. table.concat(parts, ", ") .. "})"
	end,
	NumberSequence = function(v: any): string
		local parts: { string } = {}
		for _, kp in v.Keypoints do
			table.insert(
				parts,
				`NumberSequenceKeypoint.new({snapNum(kp.Time)}, {snapNum(kp.Value)}, {snapNum(kp.Envelope)})`
			)
		end
		return "NumberSequence.new({" .. table.concat(parts, ", ") .. "})"
	end,
	TweenInfo = function(v: any): string
		return `TweenInfo.new({snapNum(v.Time)}, {tostring(v.EasingStyle)}, {tostring(v.EasingDirection)}, {snapNum(
			v.RepeatCount
		)}, {tostring(v.Reverses)}, {snapNum(v.DelayTime)})`
	end,
	Font = function(v: any): string return `Font.new({quote(v.Family)}, {tostring(v.Weight)}, {tostring(v.Style)})` end,
	DateTime = function(v: any): string return `DateTime.fromUnixTimestampMillis({snapNum(v.UnixTimestampMillis)})` end,
	EnumItem = function(v: any): string return tostring(v) end,
	Enum = function(v: any): string return tostring(v) end,
}

local function formatDatatype(kind: string, value: any): string
	local formatter = DATATYPE_FORMATTERS[kind]
	if formatter ~= nil then
		local ok, rendered = pcall(formatter, value)
		if ok and type(rendered) == "string" then return rendered end
	end
	local _, text = safeTostring(value)
	return if kind == "userdata" then text else `{kind}({text})`
end

local function appendInstanceSnapshot(
	inst: any,
	depth: number,
	firstPrefix: string,
	lines: { string },
	ancestors: { [any]: boolean }
)
	local indent = if depth == 0 and firstPrefix == "" then "" else string.rep("  ", depth)
	local prefix = if #lines == 0 and firstPrefix ~= "" then firstPrefix else indent
	if ancestors[inst] then
		table.insert(lines, `{prefix}<cycle Instance>`)
		return
	end
	ancestors[inst] = true

	local okCls, cls = pcall(function() return (inst :: any).ClassName end)
	local className = if okCls and type(cls) == "string" then cls else "Instance"
	local okName, nm = pcall(function() return (inst :: any).Name end)
	local instName = if okName and type(nm) == "string" then nm else ""

	local attrs: { string } = {}
	local okGui, isGui2d = pcall(function() return (inst :: any):IsA("GuiBase2d") end)
	if okGui and isGui2d then
		local okPos, pos = pcall(function() return (inst :: any).AbsolutePosition end)
		if okPos and pos ~= nil then
			local okXY, px, py = pcall(function() return pos.X, pos.Y end)
			if okXY and type(px) == "number" and type(py) == "number" then
				table.insert(attrs, `pos=({snapNum(px)}, {snapNum(py)})`)
			end
		end
		local okSize, sz = pcall(function() return (inst :: any).AbsoluteSize end)
		if okSize and sz ~= nil then
			local okXY, sx, sy = pcall(function() return sz.X, sz.Y end)
			if okXY and type(sx) == "number" and type(sy) == "number" then
				table.insert(attrs, `size=({snapNum(sx)}, {snapNum(sy)})`)
			end
		end
		local okVis, vis = pcall(function() return (inst :: any).Visible end)
		if okVis and type(vis) == "boolean" then table.insert(attrs, `visible={if vis then "true" else "false"}`) end
		local okTxt, txt = pcall(function() return (inst :: any).Text end)
		if okTxt and type(txt) == "string" then table.insert(attrs, `text={quote(txt)}`) end
	end

	local suffix = if #attrs > 0 then ` [{table.concat(attrs, " ")}]` else ""
	table.insert(lines, `{prefix}{className} {quote(instName)}{suffix}`)

	local okCh, children = pcall(function() return (inst :: any):GetChildren() end)
	if okCh and type(children) == "table" then
		for _, child in children do
			appendInstanceSnapshot(child, depth + 1, "", lines, ancestors)
		end
	end
	ancestors[inst] = nil
end

local function snapshotRender(value: any, depth: number, ancestors: { [any]: boolean }): string
	local valueType = type(value)
	if valueType == "nil" then
		return "nil"
	elseif valueType == "boolean" then
		return if value then "true" else "false"
	elseif valueType == "number" then
		if value ~= value then return "nan" end
		if value == 0 and 1 / value < 0 then return "-0" end
		return tostring(value)
	elseif valueType == "string" then
		return quote(value)
	elseif valueType == "buffer" then
		local length = buffer.len(value)
		return if length == 0 then "buffer(0)" else `buffer({length}) {bytes.hex(value)}`
	elseif valueType == "vector" or valueType == "userdata" then
		local kind = util.typeof(value)
		if kind == "Instance" then
			local lines: { string } = {}
			appendInstanceSnapshot(value, depth, "", lines, ancestors)
			return table.concat(lines, "\n")
		end
		return formatDatatype(kind, value)
	elseif valueType ~= "table" then
		return `<{valueType}>`
	end

	if isMatcherTable(value) then
		local desc = rawget(value, "description")
		if type(desc) == "string" then return desc end
		return "<matcher>"
	end

	local double = util.doubleTag(value)
	if double == "Instance" then
		local lines: { string } = {}
		appendInstanceSnapshot(value, depth, "", lines, ancestors)
		return table.concat(lines, "\n")
	elseif double ~= nil then
		return formatDatatype(double, value)
	end

	if ancestors[value] then return "<cycle>" end
	local keys = sortedKeys(value)
	if #keys == 0 then return "{}" end

	ancestors[value] = true
	local childIndent = string.rep("  ", depth + 1)
	local closeIndent = string.rep("  ", depth)
	local lines = { "{" }
	local arrayIndex = 1
	for _, key in keys do
		local val = rawget(value, key)
		local isInst = (type(val) == "userdata" and util.typeof(val) == "Instance")
			or (type(val) == "table" and util.doubleTag(val) == "Instance")
		local keyPrefix: string
		if key == arrayIndex then
			arrayIndex += 1
			keyPrefix = ""
		elseif type(key) == "string" and string.match(key, "^[_%a][_%w]*$") ~= nil then
			keyPrefix = `{key} = `
		else
			keyPrefix = `[{snapshotRender(key, depth + 1, ancestors)}] = `
		end
		if isInst then
			local instLines: { string } = {}
			appendInstanceSnapshot(val, depth + 1, `{childIndent}{keyPrefix}`, instLines, ancestors)
			instLines[#instLines] ..= ","
			for _, l in instLines do
				table.insert(lines, l)
			end
		else
			local renderedVal = snapshotRender(val, depth + 1, ancestors)
			table.insert(lines, `{childIndent}{keyPrefix}{renderedVal},`)
		end
	end
	ancestors[value] = nil
	table.insert(lines, closeIndent .. "}")
	return table.concat(lines, "\n")
end

--- Serializes `value` into a deterministic, canonical multi-line snapshot string.
function format.snapshot(value: any): string return snapshotRender(value, 0, {}) end

return table.freeze(format)
