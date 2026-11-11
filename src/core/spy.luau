--!strict
-- Standalone and table-method spies (`sert.spy`) with `rawset` installation/restoration and LIFO scope cleanup.

local registry = require("./registry")
local util = require("./util")

export type Call = { n: number, [number]: any }
export type ResultRecord = { ok: boolean, n: number, [number]: any }

export type SpyCalls = typeof(setmetatable(
	{} :: { Call },
	{} :: {
		__call: <F>(self: any, spyObj: any, fn: F?) -> Spy,
		__iter: (self: any) -> () -> (number?, Call),
	}
))

export type Spy = ((...any) -> ...any) & {
	calls: SpyCalls,
	results: { ResultRecord },
	called: boolean,
	callCount: number,
	lastArgs: Call?,
	returns: (self: Spy, ...any) -> Spy,
	returnsOnce: (self: Spy, ...any) -> Spy,
	throws: (self: Spy, err: any?) -> Spy,
	throwsOnce: (self: Spy, err: any?) -> Spy,
	reset: (self: Spy) -> Spy,
	restore: (self: Spy) -> (),
}

local spy = {}

local SPY_MARKER: { [any]: boolean } = setmetatable({}, { __mode = "k" }) :: any
local restorers: { [any]: () -> () } = setmetatable({}, { __mode = "k" }) :: any

local function makeReturner(...: any): (...any) -> ...any
	local packed = table.pack(...)
	return function() return table.unpack(packed, 1, packed.n) end
end

local function makeThrower(err: any?): (...any) -> ...any
	local payload = if err == nil then "spy error" else err
	return function(): ...any error(payload, 0) end
end

local function isCallableTableOrUserdata(value: any): boolean
	local kind = type(value)
	if kind ~= "table" and kind ~= "userdata" then return false end
	local mt = getmetatable(value)
	if mt == nil then return false end
	return type(mt) ~= "table" or rawget(mt, "__call") ~= nil
end

local function createSpy(initialImpl: ((...any) -> ...any)?): Spy
	local currentImpl: ((...any) -> ...any)? = initialImpl
	local onceQueue: { (...any) -> ...any } = {}
	local spyTable: { [string]: any } = {}

	-- `s.calls` is both an array `{ Call }` (`#s.calls`, `s.calls[1]`) and method `:calls(fn)` via `__call` + `__iter`.
	local callsArray: { Call } = setmetatable({} :: { Call }, {
		__call = function(_tbl: any, receiver: any, maybeFn: any): Spy
			local fn = if rawequal(receiver, spyTable) then maybeFn else receiver
			if fn ~= nil and type(fn) ~= "function" then
				error(`spy:calls: expected a function or nil, got {util.typeof(fn)}`, util.outside())
			end
			currentImpl = fn
			return (spyTable :: any) :: Spy
		end,
		__iter = function(tbl: { Call }) return next, tbl end,
	}) :: any

	spyTable.calls = callsArray
	spyTable.results = {}
	spyTable.called = false
	spyTable.callCount = 0
	spyTable.lastArgs = nil

	function spyTable.returns(self: any, ...: any): Spy
		currentImpl = makeReturner(...)
		return self
	end

	function spyTable.returnsOnce(self: any, ...: any): Spy
		table.insert(onceQueue, makeReturner(...))
		return self
	end

	function spyTable.throws(self: any, err: any?): Spy
		currentImpl = makeThrower(err)
		return self
	end

	function spyTable.throwsOnce(self: any, err: any?): Spy
		table.insert(onceQueue, makeThrower(err))
		return self
	end

	function spyTable.reset(self: any): Spy
		table.clear(callsArray)
		table.clear(self.results)
		table.clear(onceQueue)
		self.called = false
		self.callCount = 0
		self.lastArgs = nil
		return self
	end

	function spyTable.restore(self: any)
		self:reset()
		currentImpl = initialImpl
		local restoreFn = restorers[self]
		if restoreFn ~= nil then restoreFn() end
	end

	local instance: Spy = setmetatable(spyTable, {
		__call = function(self: any, ...: any): ...any
			local args = table.pack(...)
			table.insert(callsArray, args)
			self.called = true
			self.callCount += 1
			self.lastArgs = args

			local nextImpl = if #onceQueue > 0 then table.remove(onceQueue, 1) else currentImpl
			if nextImpl == nil then
				table.insert(self.results, { ok = true, n = 0 })
				return
			end
			local res = table.pack(pcall(nextImpl, ...))
			local ok = res[1]
			local record: ResultRecord = { ok = ok, n = res.n - 1 }
			for i = 2, res.n do
				record[i - 1] = res[i]
			end
			table.insert(self.results, record)
			if not ok then error(res[2], 0) end
			return table.unpack(res, 2, res.n)
		end,
	}) :: any

	SPY_MARKER[instance] = true
	return instance
end

--- Returns `true` when `value` was constructed by `sert.spy`.
function spy.isSpy(value: any): boolean return value ~= nil and SPY_MARKER[value] == true end

--- Creates a standalone `Spy` (`sert.spy(fn?)`) or spies on `tbl[key]` (`sert.spy(tbl, key, impl?)`) with automatic LIFO `rawset` restoration.
function spy.new(fnOrTbl: any?, key: any?, impl: ((...any) -> ...any)?): Spy
	if key == nil then
		if fnOrTbl == nil then
			return createSpy(nil)
		elseif type(fnOrTbl) == "function" then
			return createSpy(fnOrTbl)
		elseif isCallableTableOrUserdata(fnOrTbl) then
			return createSpy(function(...: any): ...any return (fnOrTbl :: any)(...) end)
		end
		error(
			`sert.spy: expected (fn?) or (targetTable, key, impl?), got {util.typeof(fnOrTbl)} without a key`,
			util.outside()
		)
	end

	if type(fnOrTbl) ~= "table" then
		error(`sert.spy: expected a target table as 1st argument, got {util.typeof(fnOrTbl)}`, util.outside())
	end
	if table.isfrozen(fnOrTbl) then error("sert.spy: cannot spy on a frozen table", util.outside()) end
	if impl ~= nil and type(impl) ~= "function" then
		error(
			`sert.spy: expected implementation function or nil as 3rd argument, got {util.typeof(impl)}`,
			util.outside()
		)
	end

	local target: any = fnOrTbl
	local origRaw = rawget(target, key)
	local original = origRaw
	if original == nil and getmetatable(target) ~= nil then
		local ok, inherited = pcall(function() return target[key] end)
		if ok then original = inherited end
	end

	local delegate: ((...any) -> ...any)? = if impl ~= nil
		then impl
		elseif type(original) == "function" then original
		elseif isCallableTableOrUserdata(original) then function(...: any): ...any return (original :: any)(...) end
		else nil

	local s = createSpy(delegate)
	local restored = false
	restorers[s] = function()
		if not restored then
			restored = true
			-- Restore via `rawset` so strict `__newindex` metatables never throw and inherited fields revert to raw-nil.
			if rawequal(rawget(target, key), s) then rawset(target, key, origRaw) end
		end
	end

	rawset(target, key, s)
	registry.autoRestore(function() s:restore() end)
	return s
end

return table.freeze(spy)
