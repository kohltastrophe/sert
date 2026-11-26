--!strict
-- First-class asymmetric matchers (`any`, `subset`, `within`, `matching`, `exact`) composable inside `sert.eq`, `sert.ne`, `sert.equals`, `sert.contains`, and `sert.calledWith`.

local format = require("./format")
local util = require("./util")

local repr = format.repr

export type Matcher = {
	kind: string,
	description: string,
	matches: (actual: any) -> boolean,
	check: (actual: any, path: { any }) -> (boolean, { any }?, string?),
}

local MATCHER_MT = table.freeze({
	__sertMatcher = true,
	__tostring = function(self: any): string return self.description end,
})

local match = {}

--- Returns `true` when `value` is an asymmetric `Matcher` constructed by `sert.any`, `sert.subset`, `sert.within`, `sert.matching`, or `sert.exact`.
function match.isMatcher(value: any): boolean return type(value) == "table" and getmetatable(value) == MATCHER_MT end

local function makeMatcher(
	kind: string,
	description: string,
	check: (actual: any, path: { any }) -> (boolean, { any }?, string?),
	partial: { [any]: any }?
): Matcher
	local m: { [string]: any } = {
		kind = kind,
		description = description,
		matches = function(actual: any): boolean
			local ok = check(actual, {})
			return ok
		end,
		check = check,
		_partial = partial,
	}
	setmetatable(m, MATCHER_MT :: any)
	table.freeze(m)
	return (m :: any) :: Matcher
end

local function nearComponents(value: any): (string, { { any } }?)
	if util.typeof(value) == "number" then return "number", { { "", value } } end
	return format.datatypeComponents(value)
end

--- Formats numeric or Roblox datatype components for near/within failure messages.
function match.describeNear(value: any): string
	local kind, parts = nearComponents(value)
	if kind == "number" or parts == nil then return if kind == "number" then tostring(value) else repr(value) end
	local shown = table.create(#parts)
	for index, part in parts do
		shown[index] = tostring(part[2])
	end
	return `{kind}({table.concat(shown, ", ")})`
end

--- Checks component-wise numeric/datatype proximity within `eps`, returning `(pass, usageError, detail)`.
function match.nearCheck(value: any, expected: any, eps: number): (boolean, string?, string?)
	if type(eps) ~= "number" or eps ~= eps or eps < 0 then
		return false, `tolerance must be a non-negative number, got {repr(eps)}`, nil
	end
	local expectedKind, want = nearComponents(expected)
	if want == nil then return false, `expected a number or numeric Roblox datatype, got {expectedKind}`, nil end
	local kind, got = nearComponents(value)
	if kind ~= expectedKind or got == nil or #got ~= #want then
		return false, nil, `type mismatch: expected {expectedKind}, got {kind}`
	end
	if #want == 1 then
		local gotVal, wantVal = got[1][2] :: number, want[1][2] :: number
		local delta = math.abs(gotVal - wantVal)
		if not (delta <= eps) then
			if gotVal ~= gotVal or wantVal ~= wantVal then return false, nil, "non-finite component (nan)" end
			return false, nil, `|actual - expected| = {format.snapNum(delta)} > {format.snapNum(eps)}`
		end
		return true, nil, nil
	end
	local mismatches: { string } = {}
	for index, pair in want do
		local delta = math.abs((got[index][2] :: number) - (pair[2] :: number))
		-- `not (... <= eps)` rejects NaN components cleanly.
		if not (delta <= eps) then
			if #mismatches < 4 then
				local cname = pair[1] :: string
				if delta ~= delta then
					table.insert(mismatches, `{cname}: nan`)
				else
					table.insert(mismatches, `{cname}: |Δ|={format.snapNum(delta)} > {format.snapNum(eps)}`)
				end
			elseif #mismatches == 4 then
				table.insert(mismatches, "…")
				break
			end
		end
	end
	if #mismatches > 0 then return false, nil, table.concat(mismatches, ", ") end
	return true, nil, nil
end

local function isKind(actual: any, kind: string): boolean
	if util.typeof(actual) == kind or type(actual) == kind then return true end
	if type(actual) == "table" or type(actual) == "userdata" then
		local okMethod, isA = pcall(function() return (actual :: any).IsA end)
		if okMethod and type(isA) == "function" then
			local okCall, res = pcall(isA, actual, kind)
			return okCall and res == true
		end
	end
	return false
end

--- Matches any non-`nil` value, any value of `typeof`/`type`/`Instance:IsA` `kindOrPred` string, or any value satisfying predicate `kindOrPred`.
function match.any(kindOrPred: (string | ((value: any) -> boolean))?): Matcher
	if kindOrPred == nil then
		return makeMatcher("any", "any()", function(actual: any, path: { any }): (boolean, { any }?, string?)
			if actual ~= nil then return true, nil, nil end
			return false, table.clone(path), "expected non-nil value"
		end)
	elseif type(kindOrPred) == "string" then
		local wanted = kindOrPred
		return makeMatcher(
			"any",
			string.format("any(%q)", wanted),
			function(actual: any, path: { any }): (boolean, { any }?, string?)
				if isKind(actual, wanted) then return true, nil, nil end
				return false, table.clone(path), `got {util.typeof(actual)}`
			end
		)
	elseif type(kindOrPred) == "function" then
		local pred = kindOrPred
		return makeMatcher("any", "any(<predicate>)", function(actual: any, path: { any }): (boolean, { any }?, string?)
			local ok, res = pcall(pred, actual)
			if not ok then return false, table.clone(path), `predicate raised: {format.errorText(res)}` end
			if res ~= nil and res ~= false then return true, nil, nil end
			return false, table.clone(path), nil
		end)
	end
	error(
		`sert.any: expected nil, type name string, or predicate function, got {util.typeof(kindOrPred)}`,
		util.outside()
	)
end

--- Matches numbers or Roblox numeric datatypes (`Vector2`, `Vector3`, `UDim`, `UDim2`, `Color3`, `CFrame`, `Rect`, `NumberRange`) within `eps` (default `1e-6`).
function match.within(expected: any, eps: number?): Matcher
	local tol = if eps ~= nil then eps else 1e-6
	local _, misuse = match.nearCheck(expected, expected, tol)
	if misuse ~= nil and not (type(expected) == "number" and expected ~= expected) then
		error(`sert.within: {misuse}`, util.outside())
	elseif type(expected) == "number" and expected ~= expected then
		error("sert.within: expected value cannot be NaN", util.outside())
	end
	local desc = `within({match.describeNear(expected)}, {tol})`
	return makeMatcher("within", desc, function(actual: any, path: { any }): (boolean, { any }?, string?)
		local pass, _, detail = match.nearCheck(actual, expected, tol)
		if pass then return true, nil, nil end
		return false, table.clone(path), detail
	end)
end

--- Matches strings containing Luau pattern `pattern`.
function match.matching(pattern: string): Matcher
	if type(pattern) ~= "string" then
		error(`sert.matching: expected pattern string, got {util.typeof(pattern)}`, util.outside())
	end
	local okPat, patErr = pcall(function() return string.find("", pattern) end)
	if not okPat then
		error(`sert.matching: invalid pattern {repr(pattern)} ({format.errorText(patErr)})`, util.outside())
	end
	return makeMatcher(
		"matching",
		string.format("matching(%q)", pattern),
		function(actual: any, path: { any }): (boolean, { any }?, string?)
			if type(actual) ~= "string" then
				return false, table.clone(path), `expected string, got {util.typeof(actual)}`
			end
			if string.find(actual, pattern) ~= nil then return true, nil, nil end
			return false, table.clone(path), nil
		end
	)
end

--- Forces bit-exact comparison (`-0.0 ~= +0.0`, `NaN == NaN`, raw table field walk bypassing metatables).
function match.exact(expected: any): Matcher
	return makeMatcher(
		"exact",
		`exact({repr(expected)})`,
		function(actual: any, path: { any }): (boolean, { any }?, string?)
			if util.equal(actual, expected, true) then return true, nil, nil end
			local detail = format.diff(actual, expected, true)
			return false, table.clone(path), detail
		end
	)
end

local orderedKeys = format.sortedKeys

local function readTargetProperty(target: any, key: any): (boolean, any, string?)
	local kind = type(target)
	if kind == "table" then
		local direct = rawget(target, key)
		if direct ~= nil or getmetatable(target) == nil then return true, direct, nil end
		local ok, val = pcall(function() return target[key] end)
		if not ok then return false, nil, `reading {repr(key)} raised: {format.errorText(val)}` end
		return true, val, nil
	elseif kind == "userdata" then
		local ok, val = pcall(function() return target[key] end)
		if not ok then return false, nil, `reading property {tostring(key)} raised: {format.errorText(val)}` end
		return true, val, nil
	end
	return false, nil, `expected table or Instance, got {util.typeof(target)}`
end

local matchNode: (
	actual: any,
	expected: any,
	path: { any },
	seen: { [any]: { [any]: boolean } },
	subsetMode: boolean
) -> (boolean, { any }?, string?)

function matchNode(
	actual: any,
	expected: any,
	path: { any },
	seen: { [any]: { [any]: boolean } },
	subsetMode: boolean
): (boolean, { any }?, string?)
	if match.isMatcher(expected) then return expected.check(actual, path) end

	if
		subsetMode
		and type(expected) == "table"
		and getmetatable(expected) == nil
		and util.doubleTag(expected) == nil
	then
		local actualType = type(actual)
		if actualType ~= "table" and actualType ~= "userdata" then
			return false, table.clone(path), `expected table or Instance for subset, got {util.typeof(actual)}`
		end
		local seenA = seen[actual]
		if seenA ~= nil then
			if seenA[expected] then return true, nil, nil end
			seenA[expected] = true
		else
			seen[actual] = { [expected] = true }
		end
		for _, key in orderedKeys(expected) do
			table.insert(path, key)
			local readable, actualVal, readErr = readTargetProperty(actual, key)
			if not readable then
				local failPath = table.clone(path)
				table.remove(path)
				return false, failPath, readErr
			end
			local expectedVal = rawget(expected, key)
			local ok, subPath, reason = matchNode(actualVal, expectedVal, path, seen, true)
			table.remove(path)
			if not ok then return false, subPath, reason end
		end
		return true, nil, nil
	end

	local typeA, typeB = type(actual), type(expected)
	if typeA == "number" and typeB == "number" then
		if actual == expected or (actual ~= actual and expected ~= expected) then return true, nil, nil end
		return false, table.clone(path), nil
	end
	if actual == expected then return true, nil, nil end
	if typeA ~= typeB then return false, table.clone(path), nil end
	if typeA == "buffer" then
		if util.equal(actual, expected, false) then return true, nil, nil end
		return false, table.clone(path), nil
	elseif typeA ~= "table" then
		return false, table.clone(path), nil
	end
	if getmetatable(actual) ~= nil or getmetatable(expected) ~= nil then return false, table.clone(path), nil end

	local seenA = seen[actual]
	if seenA ~= nil then
		if seenA[expected] then return true, nil, nil end
		seenA[expected] = true
	else
		seen[actual] = { [expected] = true }
	end

	local keys, present: { [any]: boolean } = orderedKeys(expected), {}
	for _, key in keys do
		present[key] = true
	end
	for _, key in orderedKeys(actual) do
		if not present[key] then table.insert(keys, key) end
	end
	table.sort(keys, format.keyBefore)
	for _, key in keys do
		table.insert(path, key)
		local ok, subPath, reason = matchNode(rawget(actual, key), rawget(expected, key), path, seen, false)
		table.remove(path)
		if not ok then return false, subPath, reason end
	end
	return true, nil, nil
end

--- Matches tables or `Instance`s where every key/property in `partial` recursively matches `actual`.
function match.subset(partial: { [any]: any }): Matcher
	if type(partial) ~= "table" then
		error(`sert.subset: expected a table, got {util.typeof(partial)}`, util.outside())
	end
	return makeMatcher(
		"subset",
		`subset({repr(partial)})`,
		function(actual: any, path: { any }): (boolean, { any }?, string?)
			return matchNode(actual, partial, path, {}, true)
		end,
		partial
	)
end

--- Compares `actual` against `expected` with full asymmetric `Matcher` support at root or nested inside tables.
function match.equal(actual: any, expected: any): boolean
	local ok = matchNode(actual, expected, {}, {}, false)
	return ok
end

local function formatPath(root: string, path: { any }): string
	local parts = { root }
	for _, key in path do
		if type(key) == "string" and string.match(key, "^[_%a][_%w]*$") ~= nil then
			table.insert(parts, `.{key}`)
		else
			table.insert(parts, `[{repr(key)}]`)
		end
	end
	return table.concat(parts)
end

local EXPLAIN_UNREADABLE = table.freeze({})

--- Returns `nil` when `match.equal(actual, expected)` holds, or a human-readable path + mismatch explanation (`$.items[2].pos: ...`).
function match.explain(actual: any, expected: any, path: string?): string?
	local ok, subPath, reason = matchNode(actual, expected, {}, {}, false)
	if ok then return nil end
	local root = path or "$"
	local failPath: { any } = subPath or {}
	local here, there = actual, expected
	local hereBroken = false
	for _, key in failPath do
		if match.isMatcher(there) then
			local partial = rawget(there :: any, "_partial")
			if type(partial) == "table" then
				there = rawget(partial, key)
			else
				break
			end
		elseif type(there) == "table" then
			there = rawget(there, key)
		end
		if not hereBroken then
			local readable, nextHere = readTargetProperty(here, key)
			if readable then
				here = nextHere
			else
				here = EXPLAIN_UNREADABLE
				hereBroken = true
			end
		end
	end
	local note = if reason ~= nil and reason ~= "" then ` ({reason})` else ""
	local hereText = if here == EXPLAIN_UNREADABLE then "<unreadable>" else repr(here)
	return `{formatPath(root, failPath)}: expected {repr(there)}, got {hereText}{note}`
end

return table.freeze(match)
