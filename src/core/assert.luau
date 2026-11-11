--!strict
-- Procedural assertions (`ok`, `eq`, `ne`, `equals`, `lt`, `le`, `gt`, `ge`, `near`, `matches`, `contains`, `throws`, `doesNotThrow`, `fail`, `called`, `calledTimes`, `calledWith`, `waitFor`).

local format = require("./format")
local match = require("./match")
local registry = require("./registry")
local spy = require("./spy")
local util = require("./util")

local repr = format.repr
local errorText = format.errorText

export type Matcher = match.Matcher
export type Spy = spy.Spy

local assertions = {}

local function mismatch(head: string, actual: any, expected: any, raw: boolean?): string
	local ok, text = pcall(format.diff, actual, expected, raw)
	if ok and type(text) == "string" and text ~= "" then
		if string.find(text, "\n", 1, true) == nil then return `{head}: {text}` end
		return `{head}\n   {(string.gsub(text, "\n", "\n   "))}`
	end
	return `{head}: expected {repr(expected)}, got {repr(actual)}`
end

local function isCallable(value: any): boolean
	local v: any = value
	if type(v) == "function" then return true end
	local kind = type(v)
	if kind ~= "table" and kind ~= "userdata" then return false end
	local mt: any = getmetatable(v)
	if mt == nil then return false end
	return type(mt) ~= "table" or rawget(mt, "__call") ~= nil
end

--- Asserts that `val` is truthy (`not nil` and `not false`) and returns `val`.
function assertions.ok<T>(val: T, msg: string?): T
	if not val then error(msg or `expected truthy value, got {repr(val)}`, util.outside()) end
	return (val :: any) :: T
end

--- Asserts deep equality between `actual` and `expected` (with asymmetric `Matcher` support) and returns `actual`.
function assertions.eq<T>(actual: T, expected: any, msg: string?): T
	if not match.equal(actual, expected) then
		error(mismatch(msg or "values differ", actual, expected, false), util.outside())
	end
	return actual
end

--- Asserts that `actual` does not match `unexpected` and returns `actual`.
function assertions.ne<T>(actual: T, unexpected: any, msg: string?): T
	if match.equal(actual, unexpected) then
		error(`{msg or "values equal"}: expected not {repr(unexpected)}, got {repr(actual)}`, util.outside())
	end
	return actual
end

--- Returns `true` when `a` matches `b` under `sert.eq` without raising.
function assertions.equals(a: any, b: any): boolean return match.equal(a, b) end

local function checkComparable(apiName: string, a: any, b: any)
	local ta, tb = type(a), type(b)
	if ta ~= tb or (ta ~= "number" and ta ~= "string") then
		error(
			`sert.{apiName}: expected two numbers or two strings, got {util.typeof(a)} and {util.typeof(b)}`,
			util.outside()
		)
	end
end

local function failOrder(sym: string, a: any, b: any, msg: string?): never
	local prefix = if msg ~= nil then `{msg}: ` else ""
	error(`{prefix}expected {repr(a)} {sym} {repr(b)}`, util.outside())
end

--- Asserts `a < b` and returns `a`.
function assertions.lt<T>(a: T, b: T, msg: string?): T
	checkComparable("lt", a, b)
	if not ((a :: any) < (b :: any)) then failOrder("<", a, b, msg) end
	return a
end

--- Asserts `a <= b` and returns `a`.
function assertions.le<T>(a: T, b: T, msg: string?): T
	checkComparable("le", a, b)
	if not ((a :: any) <= (b :: any)) then failOrder("<=", a, b, msg) end
	return a
end

--- Asserts `a > b` and returns `a`.
function assertions.gt<T>(a: T, b: T, msg: string?): T
	checkComparable("gt", a, b)
	if not ((a :: any) > (b :: any)) then failOrder(">", a, b, msg) end
	return a
end

--- Asserts `a >= b` and returns `a`.
function assertions.ge<T>(a: T, b: T, msg: string?): T
	checkComparable("ge", a, b)
	if not ((a :: any) >= (b :: any)) then failOrder(">=", a, b, msg) end
	return a
end

--- Asserts component-wise proximity within `eps` (default `1e-6`) across numbers and Roblox datatypes, returning `actual`.
function assertions.near<T>(actual: T, expected: T, eps: number?, msg: string?): T
	local tol = if eps ~= nil then eps else 1e-6
	local pass, misuse = match.nearCheck(actual, expected, tol)
	if misuse ~= nil then
		error(`sert.near: {misuse}`, util.outside())
	elseif not pass then
		error(
			`{msg or "values differ"}: expected {match.describeNear(expected)} ± {tol}, got {match.describeNear(actual)}`,
			util.outside()
		)
	end
	return actual
end

--- Asserts that `str` matches Luau pattern `pattern` and returns `str`.
function assertions.matches(str: string, pattern: string, msg: string?): string
	if type(str) ~= "string" then
		error(`sert.matches: expected string as 1st argument, got {util.typeof(str)}`, util.outside())
	elseif type(pattern) ~= "string" then
		error(`sert.matches: expected pattern string as 2nd argument, got {util.typeof(pattern)}`, util.outside())
	end
	local okPat, found = pcall(function() return string.find(str, pattern) end)
	if not okPat then
		error(`sert.matches: invalid pattern {repr(pattern)} ({errorText(found)})`, util.outside())
	elseif found == nil then
		error(`{msg or "pattern mismatch"}: expected {repr(str)} to match pattern {repr(pattern)}`, util.outside())
	end
	return str
end

--- Asserts that `haystack` (string, array, or map) contains `needle` (substring, value, or `Matcher`), returning `haystack`.
function assertions.contains<T>(haystack: T, needle: any, msg: string?): T
	local kind = type(haystack)
	if kind == "string" then
		local s = (haystack :: any) :: string
		if match.isMatcher(needle) then
			if needle.matches(s) then return haystack end
		elseif type(needle) == "string" then
			if string.find(s, needle, 1, true) ~= nil then return haystack end
		else
			error(
				`sert.contains: string haystack expects a string or matcher needle, got {util.typeof(needle)}`,
				util.outside()
			)
		end
		error(`{msg or "missing substring"}: expected {repr(s)} to contain {repr(needle)}`, util.outside())
	elseif kind == "table" then
		for _, item in next, (haystack :: any) :: { [any]: any } do
			if match.equal(item, needle) then return haystack end
		end
		error(`{msg or "missing element"}: expected {repr(haystack)} to contain {repr(needle)}`, util.outside())
	end
	error(`sert.contains: expected string or table haystack, got {util.typeof(haystack)}`, util.outside())
end

local function matchesError(err: any, text: string, matcher: any): (boolean, string)
	if type(matcher) == "string" then
		local okPat, foundPat = pcall(string.find, text, matcher)
		if (okPat and foundPat ~= nil) or string.find(text, matcher, 1, true) ~= nil then return true, "" end
		return false, string.format("matching %q", matcher)
	elseif match.isMatcher(matcher) then
		if matcher.matches(err) or matcher.matches(text) then return true, "" end
		return false, `matching {matcher.description}`
	elseif type(matcher) == "function" then
		local okPred, res = pcall(matcher, err)
		if not okPred then return false, `satisfying predicate (predicate raised: {errorText(res)})` end
		return res ~= nil and res ~= false, "satisfying predicate"
	end
	error(
		`sert.throws: expected pattern string, matcher, or predicate function, got {util.typeof(matcher)}`,
		util.outside()
	)
end

--- Asserts that calling `fn` throws an error (optionally matching `patternOrMatcher`) and returns the formatted error text.
function assertions.throws(
	fn: () -> ...any,
	patternOrMatcher: (string | Matcher | ((err: any) -> boolean))?,
	msg: string?
): string
	if not isCallable(fn) then error(`sert.throws: expected a function, got {util.typeof(fn)}`, util.outside()) end
	local ok, err = pcall(fn)
	if ok then error(msg or "expected function to throw, but it succeeded", util.outside()) end
	local text = errorText(err)
	if patternOrMatcher ~= nil then
		local matched, wanted = matchesError(err, text, patternOrMatcher)
		if not matched then error(`{msg or "wrong error"}: expected error {wanted}, got: {text}`, util.outside()) end
	end
	return text
end

--- Asserts that calling `fn` succeeds without throwing and returns its return values.
function assertions.doesNotThrow<T...>(fn: () -> T..., msg: string?): T...
	if not isCallable(fn) then
		error(`sert.doesNotThrow: expected a function, got {util.typeof(fn)}`, util.outside())
	end
	local callable: () -> ...any = fn :: any
	local res = table.pack(pcall(callable))
	if not res[1] then
		error(`{msg or "unexpected error"}: expected function not to throw, got: {errorText(res[2])}`, util.outside())
	end
	local unpackFn: any = table.unpack
	return unpackFn(res, 2, res.n)
end

--- Fails the current test unconditionally with `msg`.
function assertions.fail(msg: string?): never error(msg or "explicit assertion failure", util.outside()) end

local function requireSpy(apiName: string, s: any): Spy
	if not spy.isSpy(s) then error(`sert.{apiName}: expected a sert.spy, got {util.typeof(s)}`, util.outside()) end
	return s :: Spy
end

local function formatArgs(packed: { n: number, [number]: any }): string
	local parts = table.create(packed.n, "")
	for i = 1, packed.n do
		parts[i] = repr(packed[i])
	end
	return `({table.concat(parts, ", ")})`
end

local MAX_SHOWN_CALLS = 8

local function formatRecordedCalls(calls: any): string
	local list: { spy.Call } = calls
	if #list == 0 then return "; it was never called" end
	local take = math.min(#list, MAX_SHOWN_CALLS)
	local parts = table.create(take, "")
	for i = 1, take do
		parts[i] = formatArgs(list[i])
	end
	local more = if #list > MAX_SHOWN_CALLS then `, … {#list - MAX_SHOWN_CALLS} more` else ""
	return `; recorded {#list} {if #list == 1 then "call" else "calls"}: {table.concat(parts, ", ")}{more}`
end

--- Asserts that spy `s` was called at least once.
function assertions.called(s: Spy, msg: string?)
	local target = requireSpy("called", s)
	if target.callCount == 0 then
		error(`{msg or "spy not called"}: expected spy to have been called at least once`, util.outside())
	end
end

--- Asserts that spy `s` was called `count` times.
function assertions.calledTimes(s: Spy, count: number, msg: string?)
	local target = requireSpy("calledTimes", s)
	if type(count) ~= "number" or count ~= math.floor(count) or count < 0 then
		error(`sert.calledTimes: expected non-negative integer count, got {repr(count)}`, util.outside())
	end
	if target.callCount ~= count then
		error(
			`{msg or "spy call count mismatch"}: expected {count} {if count == 1 then "call" else "calls"}, got {target.callCount}`,
			util.outside()
		)
	end
end

--- Asserts that spy `s` was called at least once with arguments matching `...` (including asymmetric matchers).
function assertions.calledWith(s: Spy, ...: any)
	local target = requireSpy("calledWith", s)
	local wanted = table.pack(...)
	for i = 1, #target.calls do
		local call = target.calls[i]
		if call.n == wanted.n then
			local allMatch = true
			for argIdx = 1, wanted.n do
				if not match.equal(call[argIdx], wanted[argIdx]) then
					allMatch = false
					break
				end
			end
			if allMatch then return end
		end
	end
	error(
		`expected spy to have been called with {formatArgs(wanted)}{formatRecordedCalls(target.calls)}`,
		util.outside()
	)
end

--- Polls `pred()` until it returns truthy or `timeout` seconds elapse (default `1`), stepping `sert.env` or `task.wait(interval)`.
function assertions.waitFor<T>(pred: () -> T?, timeout: number?, interval: number?, msg: string?): T
	if not isCallable(pred) then
		error(`sert.waitFor: expected predicate function, got {util.typeof(pred)}`, util.outside())
	end
	local limit = if timeout ~= nil then timeout else 1
	if type(limit) ~= "number" or limit < 0 or limit ~= limit then
		error(`sert.waitFor: expected non-negative timeout, got {repr(timeout)}`, util.outside())
	end
	if interval ~= nil and (type(interval) ~= "number" or interval < 0 or interval ~= interval) then
		error(`sert.waitFor: expected non-negative interval, got {repr(interval)}`, util.outside())
	end

	local active: any = registry.activeEnv()
	local startedVirtual: number? = if active ~= nil and type(active.now) == "number" then active.now else nil
	local startedWall = os.clock()
	local lastErr: any = nil

	while true do
		local ok, value = pcall(pred)
		if ok and value then return value :: T end
		lastErr = if ok then nil else value

		local elapsedVirtual = if active ~= nil
				and startedVirtual ~= nil
				and type(active.now) == "number"
			then active.now - startedVirtual
			else nil
		if
			(elapsedVirtual ~= nil and elapsedVirtual >= limit)
			or (elapsedVirtual == nil and os.clock() - startedWall >= limit)
		then
			break
		end

		if active ~= nil then
			local advFn = active.advance
			local stepFn = active.step
			if interval ~= nil and interval > 0 and type(advFn) == "function" then
				(advFn :: (any, number) -> ())(active, interval)
			elseif type(stepFn) == "function" then
				(stepFn :: (any) -> ())(active)
			else
				error("sert.waitFor: active environment does not support step/advance", util.outside())
			end
		elseif (task :: any) ~= nil then
			if interval ~= nil then
				task.wait(interval)
			else
				task.wait()
			end
		else
			error("sert.waitFor: requires an active sert.env or Roblox task scheduler", util.outside())
		end
	end

	local errNote = if lastErr ~= nil then ` (last error: {errorText(lastErr)})` else ""
	error(`{msg or "waitFor timed out"} after {limit} s{errNote}`, util.outside())
end

return table.freeze(assertions)
