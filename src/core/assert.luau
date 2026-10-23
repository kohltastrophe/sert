--!strict
-- Core assertions (`sert`, `eq`, `rawEq`, `neq`, `equals`, `near`, `contains`, `matches`, `fails`, `waitFor`, `frames`).

local Datatypes = require("../doubles/datatypes")
local format = require("../format")
local registry = require("./registry")
local util = require("../util")
local equal = util.equal

local repr = format.repr
local errorText = format.errorText

local checks = {}

--- Returns `true` when `a` and `b` are deep-equal under `sert.eq`.
function checks.equals(a: any, b: any): boolean return equal(a, b, false) end

--- Returns `true` when `a` and `b` are deep-equal under `sert.rawEq`.
function checks.rawEquals(a: any, b: any): boolean return equal(a, b, true) end

-- Formats an equality mismatch message using `format.diff` when available.
function checks.mismatch(head: string, actual: any, expected: any, raw: boolean?): string
	local ok, text = pcall(format.diff, actual, expected, raw)
	if ok and type(text) == "string" and text ~= "" then
		if string.find(text, "\n", 1, true) == nil then return `{head}: {text}` end
		return `{head}\n   {(string.gsub(text, "\n", "\n   "))}`
	end
	return `{head}: expected {repr(expected)}, got {repr(actual)}`
end

local function components(value: any): (string, { number }?)
	local kind = Datatypes.typeof(value)
	local v: any = value
	if kind == "number" then
		return kind, { v }
	elseif kind == "vector" then
		return kind, { v.x, v.y, v.z }
	elseif kind == "Vector2" or kind == "Vector2int16" then
		return kind, { v.X, v.Y }
	elseif kind == "Vector3" or kind == "Vector3int16" then
		return kind, { v.X, v.Y, v.Z }
	elseif kind == "Color3" then
		return kind, { v.R, v.G, v.B }
	elseif kind == "UDim" then
		return kind, { v.Scale, v.Offset }
	elseif kind == "UDim2" then
		return kind, { v.X.Scale, v.X.Offset, v.Y.Scale, v.Y.Offset }
	elseif kind == "CFrame" then
		return kind, { v:GetComponents() }
	elseif kind == "Rect" then
		return kind, { v.Min.X, v.Min.Y, v.Max.X, v.Max.Y }
	elseif kind == "NumberRange" then
		return kind, { v.Min, v.Max }
	end
	return kind, nil
end

local function describeNear(value: any): string
	local kind, parts = components(value)
	if kind == "number" or parts == nil then return if kind == "number" then tostring(value) else repr(value) end
	local shown = table.create(#parts)
	for index, part in parts do
		shown[index] = tostring(part)
	end
	return `{kind}({table.concat(shown, ", ")})`
end
checks.describeNear = describeNear

--- Returns whether `value` is within `eps` of `expected` component-wise, plus any usage error message.
function checks.near(value: any, expected: any, eps: number): (boolean, string?)
	local expectedKind, want = components(expected)
	if want == nil then return false, `near: expected a number or a Roblox datatype, got {expectedKind}` end
	local kind, got = components(value)
	if kind ~= expectedKind or got == nil or #got ~= #want then return false, nil end
	for index, part in want do
		-- Use `not (... <= eps)` so NaN components fail instead of passing `>`.
		if not (math.abs(got[index] - part) <= eps) then return false, nil end
	end
	return true, nil
end

-- Checks whether `err` matches a substring or predicate `matcher`.
function checks.errorMatches(err: any, matcher: string | (err: any) -> any): (boolean, string)
	if type(matcher) == "function" then
		local ok, result = pcall(matcher, err)
		if not ok then return false, `matching the predicate (it raised: {errorText(result)})` end
		return result ~= nil and result ~= false, "matching the predicate"
	end
	return string.find(errorText(err), matcher, 1, true) ~= nil, `containing "{matcher}"`
end

local api = {}

--- Asserts deep equality between `value` and `expected` (honoring `__eq` on tables with metatables) and returns `value`.
function api.eq(value: any, expected: any, why: string?): any
	if not equal(value, expected, false) then error(checks.mismatch(why or "values differ", value, expected), 2) end
	return value
end

--- Asserts structural equality between `value` and `expected`, comparing raw fields of tables with metatables, and returns `value`.
function api.rawEq(value: any, expected: any, why: string?): any
	if not equal(value, expected, true) then
		error(checks.mismatch(why or "values differ", value, expected, true), 2)
	end
	return value
end

--- Asserts that `value` is not deep-equal to `unexpected` and returns `value`.
function api.neq(value: any, unexpected: any, why: string?): any
	if equal(value, unexpected, false) then
		error(`{why or "values equal"}: expected not {repr(unexpected)}, got {repr(value)}`, 2)
	end
	return value
end

--- Returns `true` when `a` and `b` are deep-equal under `sert.eq` without raising.
api.equals = checks.equals

--- Asserts that `value` is within `tolerance` (default `1e-6`) of `expected` component-wise and returns `value`.
function api.near<T>(value: T, expected: T, tolerance: number?, why: string?): T
	local eps = tolerance or 1e-6
	local near, misuse = checks.near(value, expected, eps)
	if misuse ~= nil then
		error(misuse, 2)
	elseif not near then
		error(`{why or "values differ"}: expected {describeNear(expected)} ± {eps}, got {describeNear(value)}`, 2)
	end
	return value
end

local function findInText(text: any, needle: string, plain: boolean, defaultWhy: string, prefix: string): string
	local whole = tostring(text)
	if string.find(whole, needle, 1, plain) == nil then
		error(`{defaultWhy}: {prefix} "{needle}" in {repr(whole)}`, util.outside())
	end
	return whole
end

--- Asserts that `tostring(text)` contains the plain substring `fragment` and returns the string.
function api.contains(text: any, fragment: string, why: string?): string
	return findInText(text, fragment, true, why or "missing text", "expected")
end

--- Asserts that `tostring(text)` matches the Luau pattern `pattern` and returns the string.
function api.matches(text: any, pattern: string, why: string?): string
	return findInText(text, pattern, false, why or "pattern mismatch", "expected pattern")
end

--- Asserts that calling `fn` raises an error (optionally matching `matcher`) and returns the error message.
function api.fails(fn: () -> ...any, matcher: (string | (err: any) -> any)?, why: string?): string
	local ok, err = pcall(fn)
	if ok then error(why or "expected the call to error, but it succeeded", 2) end
	local message = errorText(err)
	if matcher ~= nil then
		local matched, wanted = checks.errorMatches(err, matcher)
		if not matched then error(`{why or "wrong error"}: expected error {wanted}, got: {message}`, 2) end
	end
	return message
end

--- Steps up to `frames` frames (default `60`) until `done()` returns truthy.
function api.frames(done: () -> boolean, frames: number?, why: string?, step: (() -> ...any)?): true
	local limit = frames or 60
	local advance: () -> ...any
	local active: any = if step == nil then registry.activeEnv() else nil
	if step ~= nil then
		advance = step
	elseif active ~= nil then
		advance = function() active:step() end
	elseif task ~= nil then
		advance = task.wait :: any
	else
		advance = function() error("sert.frames: requires Roblox task scheduler (or a step function)", 3) end
	end
	for _ = 1, limit do
		if done() then return true end
		advance()
	end
	if not done() then error(`{why or "condition not met"} after {limit} frames`, 2) end
	return true
end

--- Polls `predicate()` until it returns truthy or `timeout` seconds pass (default `1`), returning the result.
function api.waitFor<T>(predicate: () -> T?, timeout: number?, why: string?, step: (() -> ())?): T
	local limit = timeout or 1
	local active: any = registry.activeEnv()
	local yield: () -> ()
	if step ~= nil then
		yield = step
	elseif active ~= nil then
		yield = function() active:step() end
	elseif task ~= nil then
		yield = function() task.wait() end
	else
		yield = function(): () error("sert.waitFor: requires Roblox task scheduler (or a step function)", 3) end
	end
	local startedVirtual: number? = if active ~= nil then active.now else nil
	local startedWall = os.clock()
	local last: any = nil
	while true do
		local ok, value = pcall(predicate)
		if ok and value then return value :: T end
		last = if ok then nil else value
		if
			(active ~= nil and startedVirtual ~= nil and active.now - startedVirtual >= limit)
			or (os.clock() - startedWall >= limit)
		then
			break
		end
		yield()
	end
	error(`{why or "timed out"} after {limit} s{if last ~= nil then ` (last error: {errorText(last)})` else ""}`, 2)
end

checks.api = api

return checks
