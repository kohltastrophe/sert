--!strict
--[=[
	`RBXScriptSignal` and `RBXScriptConnection` doubles.
	Calling `Wait()` on the clock-owning test thread advances the virtual clock until the signal fires or `WAIT_LIMIT` expires.
]=]

export type DispatchFn = (fn: (...any) -> (), ...any) -> ()
export type ResumeFn = (co: thread, ...any) -> ()
export type ErrorFn = (err: any) -> ()

export type SignalHost = {
	dispatch: DispatchFn?,
	resume: ResumeFn?,
	wait: ((sig: Signal) -> ...any)?,
	canStep: (() -> boolean)?,
	isMainThread: (() -> boolean)?,
	shouldPark: (() -> boolean)?,
	park: ((onPark: (co: thread) -> ()) -> ...any)?,
	--- Virtual seconds on the host's clock, which bounds a stepping `Wait`.
	clock: (() -> number)?,
	onError: ErrorFn?,
}

export type Connection = {
	Connected: boolean,
	Disconnect: (self: Connection) -> (),
	disconnect: (self: Connection) -> (), -- deprecated alias of Disconnect, as in Roblox
}

type ConnectionInternal = Connection & {
	_signal: SignalInternal?,
	_fn: ((...any) -> ())?,
	_once: boolean,
	_waitThread: thread?,
}

export type Signal = {
	Connect: (self: Signal, fn: (...any) -> ()) -> Connection,
	ConnectParallel: (self: Signal, fn: (...any) -> ()) -> Connection,
	Once: (self: Signal, fn: (...any) -> ()) -> Connection,
	Wait: (self: Signal, yieldFn: (() -> ...any)?) -> ...any,
	-- Roblox's deprecated lowercase aliases
	connect: (self: Signal, fn: (...any) -> ()) -> Connection,
	connectParallel: (self: Signal, fn: (...any) -> ()) -> Connection,
	wait: (self: Signal, yieldFn: (() -> ...any)?) -> ...any,
	Fire: (self: Signal, ...any) -> (),
	DisconnectAll: (self: Signal) -> (),
	connections: (self: Signal) -> number,
	connected: (self: Signal) -> boolean,
}

type SignalInternal = Signal & {
	_listeners: { ConnectionInternal },
	_host: SignalHost?,
	_onEmpty: (() -> ())?,
}

-- Virtual seconds a stepping `Wait` runs before it gives up on the signal.
local WAIT_LIMIT = 300

local Connection = {}
Connection.__index = Connection

function Connection.Disconnect(self: ConnectionInternal)
	if not self.Connected then return end
	self.Connected = false
	local sig = self._signal
	self._signal = nil
	if sig then
		local listeners = sig._listeners
		local idx = table.find(listeners, self)
		if idx then table.remove(listeners, idx) end
		if #listeners == 0 and sig._onEmpty ~= nil then sig._onEmpty() end
	end
end

Connection.disconnect = Connection.Disconnect

local ConnectionMT = {
	__type = "RBXScriptConnection",
	__index = Connection,
	__tostring = function(): string return "RBXScriptConnection" end,
}

local Signal = {}
Signal.__index = Signal

local function pruneDeadWaiters(self: SignalInternal)
	local listeners = self._listeners
	local i = 1
	while i <= #listeners do
		local conn = listeners[i]
		local wt = conn._waitThread
		if not conn.Connected or (wt ~= nil and coroutine.status(wt) == "dead") then
			conn.Connected = false
			conn._signal = nil
			table.remove(listeners, i)
		else
			i += 1
		end
	end
end

local function addConnection(
	self: SignalInternal,
	fn: ((...any) -> ())?,
	once: boolean,
	waitThread: thread?
): ConnectionInternal
	local conn: ConnectionInternal = setmetatable({
		Connected = true,
		_signal = self,
		_fn = fn,
		_once = once,
		_waitThread = waitThread,
	}, ConnectionMT) :: any
	table.insert(self._listeners, conn)
	return conn
end

function Signal.Connect(self: Signal, fn: (...any) -> ()): Connection
	assert(type(fn) == "function", "Connect expects a function")
	return addConnection(self :: SignalInternal, fn, false, nil)
end

Signal.ConnectParallel = Signal.Connect

function Signal.Once(self: Signal, fn: (...any) -> ()): Connection
	assert(type(fn) == "function", "Once expects a function")
	return addConnection(self :: SignalInternal, fn, true, nil)
end

function Signal.Wait(self: Signal, yieldFn: (() -> ...any)?): ...any
	local internal = self :: SignalInternal
	if yieldFn ~= nil then
		local results: { any }? = nil
		local conn = self:Once(function(...) results = table.pack(...) end)
		while results == nil do
			yieldFn()
		end
		conn:Disconnect()
		return table.unpack(results :: any, 1, (results :: any).n)
	end

	local host = internal._host
	if host ~= nil and host.park ~= nil and (host.shouldPark == nil or host.shouldPark()) then
		return host.park(function(co: thread) addConnection(internal, nil, true, co) end)
	end

	if host ~= nil and host.wait ~= nil then
		local canStep = if host.canStep ~= nil then host.canStep() else true
		local isMain = if host.isMainThread ~= nil then host.isMainThread() else true
		if canStep or isMain then
			local waitStep = host.wait
			local results: { any }? = nil
			local conn = self:Once(function(...) results = table.pack(...) end)
			local clock = host.clock
			local start = if clock ~= nil then clock() else 0
			local steps = 0
			while results == nil do
				if host.canStep ~= nil and not host.canStep() then
					conn:Disconnect()
					error("Signal:Wait(): nothing scheduled can fire this signal", 2)
				end
				-- Without a clock, each step counts as one frame at 60 fps.
				if (if clock ~= nil then clock() - start else steps / 60) >= WAIT_LIMIT then
					conn:Disconnect()
					error(`Signal:Wait(): the signal did not fire within {WAIT_LIMIT} virtual seconds`, 2)
				end
				steps += 1
				waitStep(self)
			end
			conn:Disconnect()
			return table.unpack(results :: any, 1, (results :: any).n)
		end
	end

	if not coroutine.isyieldable() then error("Signal:Wait() called on a thread that cannot yield", 2) end

	local co = coroutine.running()
	addConnection(internal, nil, true, co)
	return coroutine.yield()
end

function Signal.Fire(self: Signal, ...: any)
	local internal = self :: SignalInternal
	local listeners = internal._listeners
	if #listeners == 0 then return end
	local snapshot = table.clone(listeners)
	local host = internal._host
	local dispatch = if host then host.dispatch else nil
	local resume = if host then host.resume else nil
	local onError = if host then host.onError else nil

	for _, conn in snapshot do
		if not conn.Connected then continue end
		if conn._once then conn:Disconnect() end
		local wt = conn._waitThread
		if wt ~= nil then
			if coroutine.status(wt) == "suspended" then
				if resume ~= nil then
					resume(wt, ...)
				else
					local ok, err = coroutine.resume(wt, ...)
					if not ok then
						if onError ~= nil then
							onError(err)
						else
							error(err, 0)
						end
					end
				end
			end
		else
			local fn = conn._fn
			if fn ~= nil then
				if dispatch ~= nil then
					dispatch(fn, ...)
				else
					fn(...)
				end
			end
		end
	end
end

function Signal.DisconnectAll(self: Signal)
	local internal = self :: SignalInternal
	local listeners = internal._listeners
	for _, conn in listeners do
		conn.Connected = false
		conn._signal = nil
	end
	table.clear(listeners)
	if internal._onEmpty ~= nil then internal._onEmpty() end
end

function Signal.connections(self: Signal): number
	local internal = self :: SignalInternal
	pruneDeadWaiters(internal)
	return #internal._listeners
end

function Signal.connected(self: Signal): boolean return self:connections() > 0 end

Signal.connect = Signal.Connect
Signal.connectParallel = Signal.Connect
Signal.wait = Signal.Wait

local SignalMT = {
	__type = "RBXScriptSignal",
	__index = Signal,
	__tostring = function(): string return "RBXScriptSignal" end,
}

local Module = {}

--- A signal on `host`'s hooks (nil: handlers run at once on the firing thread); `onEmpty` runs whenever the last
--- connection goes.
function Module.new(host: SignalHost?, onEmpty: (() -> ())?): Signal
	return setmetatable({
		_listeners = {},
		_host = host,
		_onEmpty = onEmpty,
	}, SignalMT) :: any
end

function Module.fromWorld(world: any, owner: any, onEmpty: (() -> ())?, spawn: boolean?): Signal
	local s = if world ~= nil then world.scheduler else nil
	return Module.new({
		shouldPark = function(): boolean return s ~= nil and (s:running() or coroutine.running() == s.testThread) end,
		park = function(onPark: (co: thread) -> ()): ...any
			if s:running() then onPark(coroutine.running()) end
			return s:park()
		end,
		dispatch = if s ~= nil and owner ~= nil
			then if spawn
				then function(fn: (...any) -> (), ...: any) s:spawn(owner, fn, ...) end
				else function(fn: (...any) -> (), ...: any) s:defer(owner, fn, ...) end
			else nil,
		resume = if s ~= nil and owner ~= nil
			then function(wt: thread, ...: any)
				s:resume(wt, ...)
				if not s:running() then s:drain() end
			end
			else nil,
	}, onEmpty)
end

function Module.is(value: any): boolean return type(value) == "table" and getmetatable(value) == SignalMT end

function Module.isConnection(value: any): boolean return type(value) == "table" and getmetatable(value) == ConnectionMT end

return Module
