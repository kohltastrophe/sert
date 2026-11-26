--!strict
-- Modern Roblox Audio API doubles: `Wire` pin auto-connection, `WiringChanged`, `GetConnectedWires`,
-- virtual-clock `AudioPlayer` playback/looping/completion, and `AudioEmitter`/`AudioListener`/`AudioFader`/
-- `AudioAnalyzer`/`AudioDeviceOutput` node support.

local Audio = {}

local NODE_PINS: { [string]: { inputs: { string }, outputs: { string } } } = {
	AudioPlayer = { inputs = {}, outputs = { "Output" } },
	AudioListener = { inputs = {}, outputs = { "Output" } },
	AudioDeviceInput = { inputs = {}, outputs = { "Output" } },
	AudioTextToSpeech = { inputs = {}, outputs = { "Output" } },
	AudioWindSynthesizer = { inputs = {}, outputs = { "Output" } },
	AudioEmitter = { inputs = { "Input" }, outputs = {} },
	AudioDeviceOutput = { inputs = { "Input" }, outputs = {} },
	AudioRecorder = { inputs = { "Input" }, outputs = {} },
	AudioSpeechToText = { inputs = { "Input" }, outputs = {} },
	AudioFader = { inputs = { "Input" }, outputs = { "Output" } },
	AudioAnalyzer = { inputs = { "Input" }, outputs = { "Output" } },
	AudioChorus = { inputs = { "Input" }, outputs = { "Output" } },
	AudioCompressor = { inputs = { "Input" }, outputs = { "Output" } },
	AudioDistortion = { inputs = { "Input" }, outputs = { "Output" } },
	AudioEcho = { inputs = { "Input" }, outputs = { "Output" } },
	AudioEqualizer = { inputs = { "Input" }, outputs = { "Output" } },
	AudioFilter = { inputs = { "Input" }, outputs = { "Output" } },
	AudioFlanger = { inputs = { "Input" }, outputs = { "Output" } },
	AudioGate = { inputs = { "Input" }, outputs = { "Output" } },
	AudioLimiter = { inputs = { "Input" }, outputs = { "Output" } },
	AudioPitchShifter = { inputs = { "Input" }, outputs = { "Output" } },
	AudioReverb = { inputs = { "Input" }, outputs = { "Output" } },
	AudioTremolo = { inputs = { "Input" }, outputs = { "Output" } },
	AudioChannelMixer = { inputs = { "Input" }, outputs = { "Output" } },
	AudioChannelSplitter = { inputs = { "Input" }, outputs = { "Output" } },
}

type WireLink = { connected: boolean, src: any, srcPin: string, dst: any, dstPin: string }

local WIRE_LINKS: { [any]: WireLink } = setmetatable({}, { __mode = "k" }) :: any
local NODE_PIN_WIRES: { [any]: { [string]: { any } } } = setmetatable({}, { __mode = "k" }) :: any
local NODE_ALL_WIRES: { [any]: { any } } = setmetatable({}, { __mode = "k" }) :: any
local ACTIVE_PLAYERS_BY_ENV: { [any]: { any } } = setmetatable({}, { __mode = "k" }) :: any
local NODE_CURVES: { [any]: { dist: { [number]: number }?, angle: { [number]: number }? } } = setmetatable(
	{},
	{ __mode = "k" }
) :: any

local setPropHook: ((inst: any, key: string, value: any) -> ())? = nil
local getSignalHook: ((inst: any, name: string) -> any)? = nil

--- Installs `instance.luau` property/signal hooks once during engine initialization.
function Audio.configure(
	setProp: (inst: any, key: string, value: any) -> (),
	getSignal: (inst: any, name: string) -> any
)
	setPropHook = setProp
	getSignalHook = getSignal
end

local function writeProp(inst: any, key: string, value: any)
	if setPropHook ~= nil then
		setPropHook(inst, key, value)
	else
		inst._props[key] = value
	end
end

local function fireWiringChanged(node: any, connected: boolean, pin: string, wire: any, other: any)
	if node == nil or rawget(node, "_destroyed") == true then return end
	if getSignalHook ~= nil then
		getSignalHook(node, "WiringChanged"):Fire(connected, pin, wire, other)
	elseif node.WiringChanged ~= nil then
		node.WiringChanged:Fire(connected, pin, wire, other)
	end
end

local function fireEvent(node: any, name: string, ...: any)
	if node == nil or rawget(node, "_destroyed") == true then return end
	if getSignalHook ~= nil then
		getSignalHook(node, name):Fire(...)
	elseif node[name] ~= nil then
		node[name]:Fire(...)
	end
end

local function attachPinWire(node: any, pin: string, wire: any)
	local byPin = NODE_PIN_WIRES[node]
	if byPin == nil then
		byPin = {}
		NODE_PIN_WIRES[node] = byPin
	end
	local list = byPin[pin]
	if list == nil then
		list = {}
		byPin[pin] = list
	end
	if table.find(list, wire) == nil then table.insert(list, wire) end

	local all = NODE_ALL_WIRES[node]
	if all == nil then
		all = {}
		NODE_ALL_WIRES[node] = all
	end
	if table.find(all, wire) == nil then table.insert(all, wire) end
end

local function detachPinWire(node: any, pin: string, wire: any)
	local byPin = NODE_PIN_WIRES[node]
	if byPin ~= nil and byPin[pin] ~= nil then
		local idx = table.find(byPin[pin], wire)
		if idx ~= nil then table.remove(byPin[pin], idx) end
	end
	local all = NODE_ALL_WIRES[node]
	if all ~= nil then
		local idx = table.find(all, wire)
		if idx ~= nil then table.remove(all, idx) end
	end
end

local function isAudioClass(inst: any): boolean
	return inst ~= nil and type(inst._props) == "table" and NODE_PINS[inst._props.ClassName] ~= nil
end

local function isValidConnection(wire: any): (boolean, any?, string?, any?, string?)
	if rawget(wire, "_destroyed") == true then return false, nil, nil, nil, nil end
	local props = wire._props
	local src, dst = props.SourceInstance, props.TargetInstance
	local srcName, dstName = props.SourceName, props.TargetName
	if
		type(src) ~= "table"
		or type(dst) ~= "table"
		or rawget(src, "_isInstance") ~= true
		or rawget(dst, "_isInstance") ~= true
		or rawget(src, "_destroyed") == true
		or rawget(dst, "_destroyed") == true
		or src == dst
	then
		return false, nil, nil, nil, nil
	end
	local srcPins = NODE_PINS[src._props.ClassName]
	local dstPins = NODE_PINS[dst._props.ClassName]
	if srcPins == nil or dstPins == nil then return false, nil, nil, nil, nil end
	if type(srcName) ~= "string" or table.find(srcPins.outputs, srcName) == nil then
		return false, nil, nil, nil, nil
	end
	if type(dstName) ~= "string" or table.find(dstPins.inputs, dstName) == nil then return false, nil, nil, nil, nil end
	return true, src, srcName, dst, dstName
end

--- Re-evaluates a `Wire`'s `Connected` state and fires `WiringChanged` on transitions.
function Audio.syncWire(wire: any)
	if wire == nil or wire._props.ClassName ~= "Wire" then return end
	local prev = WIRE_LINKS[wire]
	local ok, src, srcName, dst, dstName = isValidConnection(wire)

	if prev ~= nil and prev.connected then
		if ok and prev.src == src and prev.srcPin == srcName and prev.dst == dst and prev.dstPin == dstName then
			return
		end
		detachPinWire(prev.src, prev.srcPin, wire)
		detachPinWire(prev.dst, prev.dstPin, wire)
		WIRE_LINKS[wire] = nil
		writeProp(wire, "Connected", false)
		fireWiringChanged(prev.src, false, prev.srcPin, wire, prev.dst)
		fireWiringChanged(prev.dst, false, prev.dstPin, wire, prev.src)
	end

	if ok and src ~= nil and dst ~= nil and srcName ~= nil and dstName ~= nil then
		attachPinWire(src, srcName, wire)
		attachPinWire(dst, dstName, wire)
		WIRE_LINKS[wire] = { connected = true, src = src, srcPin = srcName, dst = dst, dstPin = dstName }
		writeProp(wire, "Connected", true)
		fireWiringChanged(src, true, srcName, wire, dst)
		fireWiringChanged(dst, true, dstName, wire, src)
	elseif wire._props.Connected ~= false then
		writeProp(wire, "Connected", false)
	end
end

local function unregisterPlayer(ap: any)
	local env = rawget(ap, "_env")
	if env == nil then return end
	local list = ACTIVE_PLAYERS_BY_ENV[env]
	if list ~= nil then
		local idx = table.find(list, ap)
		if idx ~= nil then table.remove(list, idx) end
	end
end

local function registerPlayer(ap: any)
	local env = rawget(ap, "_env")
	if env == nil then return end
	local list = ACTIVE_PLAYERS_BY_ENV[env]
	if list == nil then
		list = {}
		ACTIVE_PLAYERS_BY_ENV[env] = list
	end
	if table.find(list, ap) == nil then table.insert(list, ap) end
end

--- Tears down active wires and playback registrations when an Instance is destroyed.
function Audio.onInstanceDestroy(inst: any)
	if inst == nil or type(inst._props) ~= "table" then return end
	local cls = inst._props.ClassName
	if cls == "Wire" then
		Audio.syncWire(inst)
		return
	end
	if cls == "AudioPlayer" then unregisterPlayer(inst) end
	local wires = NODE_ALL_WIRES[inst]
	if wires ~= nil then
		for _, w in table.clone(wires) do
			Audio.syncWire(w)
		end
		NODE_ALL_WIRES[inst] = nil
		NODE_PIN_WIRES[inst] = nil
	end
end

local function computeNodeInputAmplitude(node: any, visited: { [any]: boolean }): number
	if node == nil or rawget(node, "_destroyed") == true or visited[node] then return 0 end
	visited[node] = true
	local cls = node._props.ClassName
	if cls == "AudioPlayer" then
		if node._props.IsPlaying == true then return math.max(node._props.Volume or 1, 0) end
		return 0
	end
	local byPin = NODE_PIN_WIRES[node]
	if byPin == nil then return 0 end
	local sum = 0
	local inputs = NODE_PINS[cls].inputs
	for _, pin in inputs do
		local wires = byPin[pin]
		if wires ~= nil then
			for _, w in wires do
				local src = w._props.SourceInstance
				if src ~= nil then
					sum += computeNodeInputAmplitude(src, visited)
				end
			end
		end
	end
	if cls == "AudioFader" and node._props.Bypass ~= true then
		sum *= math.max(node._props.Volume or 1, 0)
	end
	return sum
end

local function effectiveRangeOf(ap: any): (number, number)
	local pb = ap._props.PlaybackRegion
	local tl = ap._props.TimeLength
	local length = if type(tl) == "number" and tl > 0 then tl else 1
	if pb ~= nil then
		local maxV = if pb.Max < 60000 then pb.Max else length
		return math.max(pb.Min, 0), math.max(maxV, 0)
	end
	return 0, length
end

--- Advances all playing `AudioPlayer` instances in `env` by `dt` virtual seconds.
function Audio.advanceAll(env: any, dt: number)
	if dt <= 0 or env == nil then return end
	local list = ACTIVE_PLAYERS_BY_ENV[env]
	if list == nil or #list == 0 then return end

	for _, ap in table.clone(list) do
		if rawget(ap, "_destroyed") == true or ap._props.IsPlaying ~= true then
			unregisterPlayer(ap)
			continue
		end
		local speed = ap._props.PlaybackSpeed
		if type(speed) ~= "number" or speed <= 0 then continue end
		local startPos, endPos = effectiveRangeOf(ap)
		if endPos <= startPos then
			writeProp(ap, "IsPlaying", false)
			unregisterPlayer(ap)
			fireEvent(ap, "Ended")
			continue
		end

		local pos = (ap._props.TimePosition or 0) + dt * speed
		if ap._props.Looping == true then
			local lr = ap._props.LoopRegion
			local loopStart = if lr ~= nil and lr.Max < 60000 then math.max(lr.Min, 0) else startPos
			local loopEnd = if lr ~= nil and lr.Max < 60000 then math.max(lr.Max, loopStart) else endPos
			local span = math.max(loopEnd - loopStart, 1e-6)
			if pos >= loopEnd then
				while pos >= loopEnd do
					pos -= span
					fireEvent(ap, "Looped")
				end
			end
			writeProp(ap, "TimePosition", pos)
		else
			if pos >= endPos then
				writeProp(ap, "TimePosition", endPos)
				writeProp(ap, "IsPlaying", false)
				unregisterPlayer(ap)
				fireEvent(ap, "Ended")
			else
				writeProp(ap, "TimePosition", pos)
			end
		end
	end
end

--- Returns `true` when any `AudioPlayer` in `env` is currently playing.
function Audio.hasPlaying(env: any): boolean
	local list = if env ~= nil then ACTIVE_PLAYERS_BY_ENV[env] else nil
	if list == nil then return false end
	for _, ap in list do
		if rawget(ap, "_destroyed") ~= true and ap._props.IsPlaying == true then return true end
	end
	return false
end

local SharedNodeMethods = {
	GetConnectedWires = function(self: any, pin: string): { any }
		assert(type(pin) == "string", "GetConnectedWires: pin must be a string")
		local byPin = NODE_PIN_WIRES[self]
		local wires = if byPin ~= nil then byPin[pin] else nil
		return if wires ~= nil then table.clone(wires) else {}
	end,
	GetInputPins = function(self: any): { string }
		local spec = NODE_PINS[self._props.ClassName]
		return if spec ~= nil then table.clone(spec.inputs) else {}
	end,
	GetOutputPins = function(self: any): { string }
		local spec = NODE_PINS[self._props.ClassName]
		return if spec ~= nil then table.clone(spec.outputs) else {}
	end,
}

local function positionOfAudioNode(node: any): any?
	local pType = node._props.PositionType
	local target = if pType ~= nil and pType.Name == "Parent"
		then rawget(node, "_parent")
		else node._props.PositionInstance
	local posInst = target or rawget(node, "_parent")
	if posInst ~= nil then
		local inst: any = posInst
		if inst:IsA("BasePart") then return inst.Position end
		if inst:IsA("Attachment") then return inst.WorldPosition end
		if inst:IsA("Camera") then return inst.CFrame.Position end
	end
	return nil
end

local function computeAudibility(emitter: any, listener: any): number
	if emitter == nil or listener == nil then return 0 end
	if emitter._props.AudioInteractionGroup ~= listener._props.AudioInteractionGroup then return 0 end
	local pe, pl = positionOfAudioNode(emitter), positionOfAudioNode(listener)
	if pe == nil or pl == nil then return 1 end
	local dist = (pe - pl).Magnitude
	local bounds = emitter._props.DistanceAttenuationBounds
	local minD = if bounds ~= nil then bounds.Min else 4
	local maxD = if bounds ~= nil then bounds.Max else 10000
	if dist <= minD then return 1 end
	if dist >= maxD then return 0 end
	return math.clamp(1 - (dist - minD) / math.max(maxD - minD, 1e-6), 0, 1)
end

local function withShared(extra: { [string]: (...any) -> ...any }): { [string]: (...any) -> ...any }
	local out: { [string]: (...any) -> ...any } = table.clone(SharedNodeMethods)
	for k, v in extra do
		out[k] = v
	end
	return out
end

Audio.SharedNodeMethods = SharedNodeMethods

Audio.AudioPlayerMethods = withShared({
	Play = function(self: any, atTime: number?): number
		local startPos, endPos = effectiveRangeOf(self)
		if atTime ~= nil then
			writeProp(self, "TimePosition", math.max(atTime, 0))
		elseif (self._props.TimePosition or 0) >= endPos then
			writeProp(self, "TimePosition", startPos)
		end
		writeProp(self, "IsPlaying", true)
		registerPlayer(self)
		return 1
	end,
	Stop = function(self: any, _atTime: number?): number
		writeProp(self, "IsPlaying", false)
		unregisterPlayer(self)
		return 1
	end,
	Cancel = function(_self: any, _actionId: number?): boolean return false end,
	GetWaveformAsync = function(_self: any, _timeRange: any, samples: number): { number }
		local n = math.max(math.floor(samples or 0), 0)
		return table.create(n, 0)
	end,
})

Audio.AudioAnalyzerMethods = withShared({
	GetSpectrum = function(self: any): { number }
		if self._props.SpectrumEnabled == false then return {} end
		local amp = computeNodeInputAmplitude(self, {})
		return { amp, amp * 0.5, amp * 0.25 }
	end,
	_sampleLevels = function(self: any): (number, number)
		local amp = computeNodeInputAmplitude(self, {})
		writeProp(self, "PeakLevel", amp)
		writeProp(self, "RmsLevel", amp * 0.70710678)
		return amp, amp * 0.70710678
	end,
})

Audio.AudioEmitterMethods = withShared({
	GetDistanceAttenuation = function(self: any): { [number]: number }
		local c = NODE_CURVES[self]
		return if c ~= nil and c.dist ~= nil then table.clone(c.dist) else {}
	end,
	SetDistanceAttenuation = function(self: any, curve: { [number]: number })
		local c: { dist: { [number]: number }?, angle: { [number]: number }? } = NODE_CURVES[self] or {}
		NODE_CURVES[self] = c
		c.dist = table.clone(curve)
	end,
	GetAngleAttenuation = function(self: any): { [number]: number }
		local c = NODE_CURVES[self]
		return if c ~= nil and c.angle ~= nil then table.clone(c.angle) else {}
	end,
	SetAngleAttenuation = function(self: any, curve: { [number]: number })
		local c: { dist: { [number]: number }?, angle: { [number]: number }? } = NODE_CURVES[self] or {}
		NODE_CURVES[self] = c
		c.angle = table.clone(curve)
	end,
	GetInteractingListeners = function(self: any): { any }
		local env = rawget(self, "_env")
		if env == nil or env.game == nil then return {} end
		local out = {}
		for _, inst in env.game:GetDescendants() do
			if inst._props.ClassName == "AudioListener" and computeAudibility(self, inst) > 0 then
				table.insert(out, inst)
			end
		end
		return out
	end,
	GetAudibilityFor = function(self: any, listener: any): number return computeAudibility(self, listener) end,
})

Audio.AudioListenerMethods = withShared({
	GetDistanceAttenuation = Audio.AudioEmitterMethods.GetDistanceAttenuation,
	SetDistanceAttenuation = Audio.AudioEmitterMethods.SetDistanceAttenuation,
	GetAngleAttenuation = Audio.AudioEmitterMethods.GetAngleAttenuation,
	SetAngleAttenuation = Audio.AudioEmitterMethods.SetAngleAttenuation,
	GetInteractingEmitters = function(self: any): { any }
		local env = rawget(self, "_env")
		if env == nil or env.game == nil then return {} end
		local out = {}
		for _, inst in env.game:GetDescendants() do
			if inst._props.ClassName == "AudioEmitter" and computeAudibility(inst, self) > 0 then
				table.insert(out, inst)
			end
		end
		return out
	end,
	GetAudibilityFor = function(self: any, emitter: any): number return computeAudibility(emitter, self) end,
})

--- Checks if `AudioAnalyzer` property reads (`PeakLevel` / `RmsLevel`) should refresh live signal levels.
function Audio.refreshAnalyzerIfNeeded(inst: any, key: any)
	if
		(key == "PeakLevel" or key == "RmsLevel")
		and inst._props.ClassName == "AudioAnalyzer"
		and isAudioClass(inst)
	then
		Audio.AudioAnalyzerMethods._sampleLevels(inst)
	end
end

return Audio
