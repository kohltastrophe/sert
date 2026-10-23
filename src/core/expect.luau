--!strict
-- Jest-style `expect(value, why?)` matchers with `.never` negation and `sert.extend` custom matchers.

local Datatypes = require("../doubles/datatypes")
local checks = require("./assert")
local format = require("../format")
local registry = require("./registry")

local repr, errorText, spy = format.repr, format.errorText, registry.spy

-- Message strings can be lazy functions so passing assertions do not pay to format values.
export type Message = string | () -> string
export type MatcherResult = { pass: boolean, message: Message, negMessage: Message?, usage: boolean? }
export type Matcher = (actual: any, ...any) -> MatcherResult

export type Matchers = {
	toBe: (expected: any) -> (),
	toEqual: (expected: any) -> (),
	toRawEqual: (expected: any) -> (),
	toMatchObject: (partial: { [any]: any }) -> (),
	toHaveProperty: (path: string | { any }, value: any?) -> (),
	toBeNil: () -> (),
	toBeTruthy: () -> (),
	toBeFalsy: () -> (),
	toBeNaN: () -> (),
	toBeFinite: () -> (),
	toBeCloseTo: (expected: number, digits: number?) -> (),
	toBeNear: (expected: any, eps: number?) -> (),
	toBeGreaterThan: (expected: number) -> (),
	toBeGreaterThanOrEqual: (expected: number) -> (),
	toBeLessThan: (expected: number) -> (),
	toBeLessThanOrEqual: (expected: number) -> (),
	toBeA: (expectedType: string) -> (),
	toBeInstanceOf: (class: string | { [any]: any }) -> (),
	toContain: (item: any) -> (),
	toMatch: (pattern: string) -> (),
	toHaveLength: (expected: number) -> (),
	toHaveBeenCalled: () -> (),
	toHaveBeenCalledTimes: (expected: number) -> (),
	toHaveBeenCalledWith: (...any) -> (),
	toHaveBeenLastCalledWith: (...any) -> (),
	toHaveBeenNthCalledWith: (n: number, ...any) -> (),
	toHaveReturned: () -> (),
	toHaveReturnedWith: (...any) -> (),
	toThrow: (matcher: (string | (err: any) -> any)?) -> (),
	never: Matchers,
}

local function result(pass: boolean, message: Message, negMessage: Message?): MatcherResult
	return { pass = pass, message = message, negMessage = negMessage }
end

local function usage(message: string): MatcherResult return { pass = false, message = message, usage = true } end

local matchers: { [string]: Matcher } = {}

-- Equality --------------------------------------------------------------------------------------------------------

function matchers.toBe(actual: any, expected: any): MatcherResult
	local pass = rawequal(actual, expected)
		or (type(actual) == "number" and type(expected) == "number" and actual ~= actual and expected ~= expected)
	local hint = if not pass
			and type(actual) == "table"
			and checks.equals(actual, expected)
		then " (deep-equal, but not the same table: use toEqual)"
		else ""
	return result(
		pass,
		function() return `values differ: expected {repr(expected)}, got {repr(actual)}{hint}` end,
		function() return `expected not {repr(expected)}, got {repr(actual)}` end
	)
end

local function eqMatcher(raw: boolean): Matcher
	return function(actual: any, expected: any): MatcherResult
		return result(
			if raw then checks.rawEquals(actual, expected) else checks.equals(actual, expected),
			function() return checks.mismatch("values differ", actual, expected, raw) end,
			function() return `expected not {repr(expected)}, got {repr(actual)}` end
		)
	end
end
matchers.toEqual = eqMatcher(false)
matchers.toRawEqual = eqMatcher(true)

-- Every key of `partial` matches `actual`'s, recursively for plain tables; an array matches element for element.
local function matchesObject(actual: any, partial: any, seen: { [any]: { [any]: boolean } }?): boolean
	if type(partial) ~= "table" or getmetatable(partial) ~= nil then
		return checks.equals(actual, partial)
	elseif type(actual) ~= "table" or (#partial > 0 and #actual ~= #partial) then
		return false
	end
	local pairsSeen: { [any]: { [any]: boolean } } = seen or {}
	local actualSeen = pairsSeen[actual]
	if actualSeen ~= nil and actualSeen[partial] then return true end
	if actualSeen == nil then
		actualSeen = {}
		pairsSeen[actual] = actualSeen
	end
	actualSeen[partial] = true
	for key, value in partial do
		local ok, actualValue = pcall(function() return actual[key] end)
		if not ok or not matchesObject(actualValue, value, pairsSeen) then return false end
	end
	return true
end

function matchers.toMatchObject(actual: any, partial: any): MatcherResult
	if type(partial) ~= "table" then return usage(`toMatchObject: expected a table to match, got {type(partial)}`) end
	return result(
		matchesObject(actual, partial),
		function() return `expected {repr(actual)} to match object {repr(partial)}` end,
		function() return `expected {repr(actual)} not to match object {repr(partial)}` end
	)
end

-- "a.b[2].c" (or { "a", "b", 2, "c" }) as its keys, or nil on malformed paths.
local function pathKeys(path: string | { any }): ({ any }?, string)
	if type(path) == "table" then
		if #path == 0 then return nil, "" end
		local parts = table.create(#path)
		for idx, item in path do
			parts[idx] = if type(item) == "string" or type(item) == "number" then tostring(item) else repr(item)
		end
		return path, table.concat(parts, ".")
	end
	if
		path == ""
		or string.sub(path, 1, 1) == "."
		or string.sub(path, -1) == "."
		or string.find(path, "..", 1, true) ~= nil
	then
		return nil, path
	end
	local keys: { any } = {}
	for part in string.gmatch(path, "[^%.]+") do
		local head, rest = string.match(part, "^([^%[%]]*)(.*)$")
		if head == nil or (head == "" and rest == "") or string.gsub(rest or "", "%[%d+%]", "") ~= "" then
			return nil, path
		end
		if head ~= "" then table.insert(keys, head) end
		for index in string.gmatch(rest or "", "%[(%d+)%]") do
			table.insert(keys, tonumber(index))
		end
	end
	if #keys == 0 then return nil, path end
	return keys, path
end

local function index(value: any, key: any): (boolean, any)
	if type(value) ~= "table" and type(value) ~= "userdata" then return false, nil end
	local ok, found = pcall(function() return value[key] end)
	return ok and found ~= nil, found
end

function matchers.toHaveProperty(actual: any, path: string | { any }, ...: any): MatcherResult
	if type(path) ~= "string" and type(path) ~= "table" then
		return usage(`toHaveProperty: expected a property path string or table, got {type(path)}`)
	end
	local keys, text = pathKeys(path)
	if keys == nil then return usage(`toHaveProperty: invalid property path {repr(path)}`) end
	local current = actual
	for _, key in keys do
		local found, value = index(current, key)
		if not found then
			return result(
				false,
				function() return `expected property "{text}" in {repr(actual)}` end,
				`expected no property "{text}"`
			)
		end
		current = value
	end
	if select("#", ...) == 0 then
		return result(true, "", function() return `expected no property "{text}", got {repr(current)}` end)
	end
	local expected = ...
	return result(
		checks.equals(current, expected),
		function() return checks.mismatch(`property "{text}" differs`, current, expected) end,
		function() return `expected property "{text}" not to be {repr(expected)}` end
	)
end

-- Truthiness and numbers ----------------------------------------------------------------------------------------

function matchers.toBeNil(actual: any): MatcherResult
	return result(
		actual == nil,
		function() return `expected nil, got {repr(actual)}` end,
		"expected value not to be nil"
	)
end

local function truthiness(actual: any, wantTruthy: boolean, label: string): MatcherResult
	local isTruthy = actual ~= nil and actual ~= false
	return result(
		isTruthy == wantTruthy,
		function() return `expected {label}, got {repr(actual)}` end,
		function() return `expected not {label}, got {repr(actual)}` end
	)
end

function matchers.toBeTruthy(actual: any): MatcherResult return truthiness(actual, true, "truthy") end

function matchers.toBeFalsy(actual: any): MatcherResult return truthiness(actual, false, "falsy") end

function matchers.toBeNaN(actual: any): MatcherResult
	return result(
		type(actual) == "number" and actual ~= actual,
		function() return `expected NaN, got {repr(actual)}` end,
		"expected number not to be NaN"
	)
end

function matchers.toBeFinite(actual: any): MatcherResult
	return result(
		type(actual) == "number" and actual == actual and math.abs(actual) ~= math.huge,
		function() return `expected finite number, got {repr(actual)}` end,
		function() return `expected not finite number, got {repr(actual)}` end
	)
end

-- As in Jest: within half a unit of the `digits`th decimal place (default 2), or equal (an infinity).
function matchers.toBeCloseTo(actual: any, expected: number, digits: number?): MatcherResult
	if type(expected) ~= "number" then
		return usage(`toBeCloseTo: expected a number to compare with, got {type(expected)}`)
	elseif type(actual) ~= "number" then
		return usage(`toBeCloseTo: expected a number, got {type(actual)}`)
	end
	local places = digits or 2
	local tol = 10 ^ -places / 2
	return result(
		actual == expected or math.abs(actual - expected) < tol,
		function() return `expected {expected} to {places} digits (± {tol}), got {repr(actual)}` end,
		function() return `expected not {expected} to {places} digits (± {tol}), got {repr(actual)}` end
	)
end

function matchers.toBeNear(actual: any, expected: any, eps: number?): MatcherResult
	local tol = eps or 1e-6
	local near, misuse = checks.near(actual, expected, tol)
	if misuse ~= nil then return usage(`toBeNear: {misuse}`) end
	return result(
		near,
		function() return `expected {checks.describeNear(expected)} ± {tol}, got {checks.describeNear(actual)}` end,
		function() return `expected not {checks.describeNear(expected)} ± {tol}, got {checks.describeNear(actual)}` end
	)
end

local function compare(name: string, symbol: string, holds: (number, number) -> boolean): Matcher
	return function(actual: any, expected: number): MatcherResult
		if type(expected) ~= "number" then
			return usage(`{name}: expected a number to compare with, got {type(expected)}`)
		elseif type(actual) ~= "number" then
			return usage(`{name}: expected a number, got {type(actual)}`)
		end
		return result(
			holds(actual, expected),
			function() return `expected {symbol} {expected}, got {repr(actual)}` end,
			function() return `expected not {symbol} {expected}, got {repr(actual)}` end
		)
	end
end

matchers.toBeGreaterThan = compare("toBeGreaterThan", ">", function(a, b) return a > b end)
matchers.toBeGreaterThanOrEqual = compare("toBeGreaterThanOrEqual", ">=", function(a, b) return a >= b end)
matchers.toBeLessThan = compare("toBeLessThan", "<", function(a, b) return a < b end)
matchers.toBeLessThanOrEqual = compare("toBeLessThanOrEqual", "<=", function(a, b) return a <= b end)

-- Types ------------------------------------------------------------------------------------------------------------

-- typeof (Roblox datatypes and sert.doubles too), type, or an Instance's IsA.
local function isKind(actual: any, kind: string): boolean
	if Datatypes.typeof(actual) == kind or type(actual) == kind then return true end
	if type(actual) == "table" or type(actual) == "userdata" then
		local ok, isA = pcall(function() return (actual :: any).IsA end)
		if ok and type(isA) == "function" then
			local called, res = pcall(isA, actual, kind)
			return called and res == true
		end
	end
	return false
end

function matchers.toBeA(actual: any, expectedType: string): MatcherResult
	local actualType = Datatypes.typeof(actual)
	return result(
		isKind(actual, expectedType),
		function() return `expected a {expectedType}, got {actualType} ({repr(actual)})` end,
		function() return `expected value not to be a {expectedType}, got {actualType}` end
	)
end

-- Whether `value`'s metatable chain (metatables and their __index tables) reaches `class`.
local function inherits(value: any, class: any): boolean
	local current = getmetatable(value)
	for _ = 1, 32 do
		if type(current) ~= "table" then return false end
		local proto = rawget(current, "__index")
		if current == class or proto == class then return true end
		current = if type(proto) == "table" then getmetatable(proto) else nil
	end
	return false
end

function matchers.toBeInstanceOf(actual: any, class: any): MatcherResult
	if type(class) == "string" then
		return matchers.toBeA(actual, class)
	elseif type(class) ~= "table" then
		return usage(`toBeInstanceOf: expected a class name or table, got {type(class)}`)
	end
	return result(
		inherits(actual, class),
		function() return `expected {repr(actual)} to be an instance of {repr(class)}` end,
		function() return `expected {repr(actual)} not to be an instance of {repr(class)}` end
	)
end

-- Collections and text -----------------------------------------------------------------------------------------------

function matchers.toContain(actual: any, item: any): MatcherResult
	local found = false
	if type(actual) == "string" then
		found = type(item) == "string" and string.find(actual, item, 1, true) ~= nil
	elseif type(actual) == "table" then
		for _, elem in actual :: { [any]: any } do
			if checks.equals(elem, item) then
				found = true
				break
			end
		end
	else
		return usage(`toContain: expected string or table, got {type(actual)}`)
	end
	return result(
		found,
		function() return `expected {repr(actual)} to contain {repr(item)}` end,
		function() return `expected {repr(actual)} not to contain {repr(item)}` end
	)
end

function matchers.toMatch(actual: any, pattern: string): MatcherResult
	local text = tostring(actual)
	return result(
		string.find(text, pattern) ~= nil,
		function() return `expected {repr(text)} to match pattern "{pattern}"` end,
		function() return `expected {repr(text)} not to match pattern "{pattern}"` end
	)
end

function matchers.toHaveLength(actual: any, expected: number): MatcherResult
	local len: number
	if type(actual) == "buffer" then
		len = buffer.len(actual)
	elseif type(actual) == "string" or type(actual) == "table" then
		len = #(actual :: any)
	else
		return usage(`toHaveLength: expected string, table, or buffer, got {type(actual)}`)
	end
	return result(
		len == expected,
		function() return `expected length {expected}, got {len}` end,
		function() return `expected length not to be {expected}, got {len}` end
	)
end

-- Spies ------------------------------------------------------------------------------------------------------------

local function sameArgs(call: { n: number, [number]: any }, wanted: { n: number, [number]: any }): boolean
	if call.n ~= wanted.n then return false end
	for i = 1, wanted.n do
		if not checks.equals(call[i], wanted[i]) then return false end
	end
	return true
end

-- A packed argument or return list as it was written: `(1, nil, "x")`.
local function args(packed: { n: number, [number]: any }): string
	local parts = table.create(packed.n)
	for i = 1, packed.n do
		parts[i] = repr(packed[i])
	end
	return `({table.concat(parts, ", ")})`
end

local RECORDED = 8

-- The lists a spy recorded, for a failure that needs them: `; its 2 calls: (1, 2), ("x")`.
local function recorded(lists: { { n: number, [number]: any } }, noun: string, none: string): string
	if #lists == 0 then return `; {none}` end
	local parts = table.create(math.min(#lists, RECORDED))
	for i = 1, math.min(#lists, RECORDED) do
		parts[i] = args(lists[i])
	end
	local more = if #lists > RECORDED then `, … {#lists - RECORDED} more` else ""
	return `; its {#lists} {noun}: {table.concat(parts, ", ")}{more}`
end

local function spyMatcher(name: string, fn: (actual: any, ...any) -> MatcherResult): Matcher
	return function(actual: any, ...: any): MatcherResult
		if not spy.isSpy(actual) then return usage(`{name}: expected a sert.fn or sert.spy`) end
		return fn(actual, ...)
	end
end

matchers.toHaveBeenCalled = spyMatcher("toHaveBeenCalled", function(actual: any): MatcherResult
	local count = actual.callCount :: number
	return result(
		count > 0,
		"expected spy to have been called, but it was not called",
		function() return `expected spy not to have been called, but it was called {count} time(s)` end
	)
end)

matchers.toHaveBeenCalledTimes = spyMatcher(
	"toHaveBeenCalledTimes",
	function(actual: any, expected: number): MatcherResult
		local count = actual.callCount :: number
		return result(
			count == expected,
			function() return `expected spy to be called {expected} time(s), got {count}` end,
			function() return `expected spy not to be called {expected} time(s), got {count}` end
		)
	end
)

matchers.toHaveBeenCalledWith = spyMatcher("toHaveBeenCalledWith", function(actual: any, ...: any): MatcherResult
	local wanted = table.pack(...)
	local matched = false
	for _, call in actual.calls :: { { n: number, [number]: any } } do
		if sameArgs(call, wanted) then
			matched = true
			break
		end
	end
	return result(
		matched,
		function()
			return `expected spy to have been called with {args(wanted)}{recorded(
				actual.calls,
				"calls",
				"it was never called"
			)}`
		end,
		function() return `expected spy not to have been called with {args(wanted)}` end
	)
end)

matchers.toHaveBeenNthCalledWith = spyMatcher(
	"toHaveBeenNthCalledWith",
	function(actual: any, n: number, ...: any): MatcherResult
		local wanted, call = table.pack(...), actual.calls[n]
		return result(
			call ~= nil and sameArgs(call, wanted),
			function()
				return `expected call {n} to have been with {args(wanted)}, got {if call
					then args(call)
					else "no such call"}`
			end,
			function() return `expected call {n} not to have been with {args(wanted)}` end
		)
	end
)

matchers.toHaveBeenLastCalledWith = spyMatcher(
	"toHaveBeenLastCalledWith",
	function(actual: any, ...: any): MatcherResult
		local wanted, call = table.pack(...), actual.calls[#actual.calls]
		return result(
			call ~= nil and sameArgs(call, wanted),
			function()
				return `expected the last call to have been with {args(wanted)}, got {if call
					then args(call)
					else "no call"}`
			end,
			function() return `expected the last call not to have been with {args(wanted)}` end
		)
	end
)

matchers.toHaveReturned = spyMatcher("toHaveReturned", function(actual: any): MatcherResult
	local returned = 0
	for _, record in actual.results :: { { ok: boolean } } do
		if record.ok then
			returned += 1
		end
	end
	return result(
		returned > 0,
		"expected spy to have returned, but no call returned",
		function() return `expected spy not to have returned, but {returned} call(s) did` end
	)
end)

matchers.toHaveReturnedWith = spyMatcher("toHaveReturnedWith", function(actual: any, ...: any): MatcherResult
	local wanted = table.pack(...)
	local matched = false
	local returns: { { n: number, [number]: any } } = {}
	for _, record in actual.results :: { { ok: boolean, n: number, [number]: any } } do
		if record.ok then
			table.insert(returns, record)
			matched = matched or sameArgs(record, wanted)
		end
	end
	return result(
		matched,
		function()
			return `expected spy to have returned {args(wanted)}{recorded(returns, "returns", "no call returned")}`
		end,
		function() return `expected spy not to have returned {args(wanted)}` end
	)
end)

-- Errors -----------------------------------------------------------------------------------------------------------

function matchers.toThrow(actual: any, matcher: (string | (err: any) -> any)?): MatcherResult
	local meta = if type(actual) == "table" then getmetatable(actual) else nil
	if not (type(actual) == "function" or (type(meta) == "table" and rawget(meta, "__call") ~= nil)) then
		return usage(`toThrow: expected a function, got {type(actual)}`)
	end
	local ok, err = pcall(actual)
	if ok then
		return result(false, "expected function to throw, but it succeeded", "")
	elseif matcher == nil then
		return result(true, "", function() return `expected function not to throw, but got: {errorText(err)}` end)
	end
	local matched, wanted = checks.errorMatches(err, matcher)
	return result(
		matched,
		function() return `expected error {wanted}, got: {errorText(err)}` end,
		function()
			return if type(matcher) == "string"
				then `expected function not to throw "{matcher}", but got: {errorText(err)}`
				else `expected function not to throw an error {wanted}, but got: {errorText(err)}`
		end
	)
end

-- expect ------------------------------------------------------------------------------------------------------------

local expect = {}

-- A Message's text: a function's result (its own error, or a non-string result, says so instead of hiding the failure).
local function render(message: Message): string
	if type(message) ~= "function" then return tostring(message) end
	local ok, text = pcall(message)
	return if ok then tostring(text) else `(the failure message raised: {tostring(text)})`
end

local function build(actual: any, why: string?, negated: boolean): any
	local prefix = if why ~= nil then `{why}: ` else ""
	local proxy = {}
	return setmetatable(proxy, {
		__index = function(_, key: string): any
			if key == "never" then
				if negated then error("expect: .never.never is not a matcher", 2) end
				return build(actual, why, true)
			end
			local matcher = matchers[key]
			if matcher == nil then error(`expect: no matcher named {tostring(key)} (sert.extend adds matchers)`, 2) end
			return function(...: any)
				if select("#", ...) > 0 and rawequal((...), proxy) then
					error(`expect(...).{key}: call matchers with '.', not ':'`, 2)
				end
				local outcome = matcher(actual, ...)
				if outcome.usage then
					error(prefix .. render(outcome.message), 2)
				elseif outcome.pass == negated then
					local message = if not negated
						then render(outcome.message)
						elseif outcome.negMessage ~= nil then render(outcome.negMessage)
						else `not: {render(outcome.message)}`
					error(prefix .. message, 2)
				end
			end
		end,
	})
end

--- Wraps `actual` in a `Matchers` chain with `.never` negation.
function expect.expect(actual: any, why: string?): Matchers return build(actual, why, false) :: Matchers end

--- Adds or overrides matchers on `sert.expect`.
function expect.extend(added: { [string]: Matcher })
	for name, matcher in added do
		if name == "never" then
			error("sert.extend: `never` is reserved", 2)
		elseif type(matcher) ~= "function" then
			error(`sert.extend: matcher {name} is not a function`, 2)
		end
		matchers[name] = matcher
	end
end

return expect
