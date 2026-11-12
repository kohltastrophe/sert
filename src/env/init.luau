--!strict
--!nolint DeprecatedApi
-- Headless Roblox VM and DataModel sandbox (`sert.env`) for standalone Luau and `sert.sim` peers.

local registry = require("./core/registry")
local util = require("./core/util")
local Datatypes = require("./engine/datatypes")
local Generated = require("./engine/generated")
local InstanceDouble = require("./engine/instance")
local Scheduler = require("./engine/scheduler")
local ServiceRegistry = require("./engine/services")
local Signal = require("./engine/signal")

local Replication = require("@self/replication")

local output = registry.output
local nativeRequire = require
local NIL_MODULE = table.freeze({})
local IS_ROBLOX = (game :: any) ~= nil
local doubleTag = Datatypes.doubleTag

local Env = {}
Env._sharedG = registry.mutant._sharedG
Env.hooks = { wait = registry.mutant.waitGuard } :: { wait: (() -> ())? }

local function buildInput(env: any, ctx: any): any
	local Enum, customTypeof = ctx.Enum, ctx.typeof
	local dt = ctx.dt
	local uis = ctx.getService("UserInputService")
	local state = ctx.inputState

	local function inputObject(inputType: any, keyCode: any, inputState: any, delta: any?): any
		local io = ctx.createInstance("InputObject", nil, true)
		io.Name = "InputObject"
		local props = io._props
		props.UserInputType, props.KeyCode, props.UserInputState = inputType, keyCode, inputState
		props.Position = dt.Vector3.new(state.mouse.X, state.mouse.Y, 0)
		props.Delta = delta or dt.Vector3.new(0, 0, 0)
		return io
	end

	local function setLastType(inputType: any)
		if state.lastType ~= inputType then
			state.lastType = inputType
			uis.LastInputTypeChanged:Fire(inputType)
		end
	end

	local function isMouseButton(code: any): boolean
		return customTypeof(code) == "EnumItem" and code.EnumType == Enum.UserInputType
	end

	local function beginButton(button: any, gameProcessed: boolean): any
		local io = inputObject(button, Enum.KeyCode.Unknown, Enum.UserInputState.Begin)
		table.insert(state.buttons, io)
		setLastType(button)
		uis.InputBegan:Fire(io, gameProcessed)
		return io
	end

	local function endButton(button: any, gameProcessed: boolean)
		for i, held in state.buttons do
			if held.UserInputType == button then
				table.remove(state.buttons, i)
				held._props.UserInputState = Enum.UserInputState.End
				uis.InputEnded:Fire(held, gameProcessed)
				return
			end
		end
		uis.InputEnded:Fire(inputObject(button, Enum.KeyCode.Unknown, Enum.UserInputState.End), gameProcessed)
	end

	local driver = {}

	function driver.press(_self: any, keyCode: any)
		if isMouseButton(keyCode) then
			beginButton(keyCode, false)
			return
		end
		for _, held in state.keys do
			if held.KeyCode == keyCode then return end
		end
		local wasProcessed = env._focusedBox ~= nil
		local io = inputObject(Enum.UserInputType.Keyboard, keyCode, Enum.UserInputState.Begin)
		table.insert(state.keys, io)
		setLastType(Enum.UserInputType.Keyboard)
		uis.InputBegan:Fire(io, wasProcessed)
		local box = env._focusedBox
		if box ~= nil and (keyCode == Enum.KeyCode.Return or keyCode == Enum.KeyCode.KeypadEnter) then
			box:ReleaseFocus(true)
		end
	end

	function driver.release(_self: any, keyCode: any)
		if isMouseButton(keyCode) then
			endButton(keyCode, false)
			return
		end
		for i, held in state.keys do
			if held.KeyCode == keyCode then
				table.remove(state.keys, i)
				held._props.UserInputState = Enum.UserInputState.End
				uis.InputEnded:Fire(held, env._focusedBox ~= nil)
				return
			end
		end
	end

	function driver.move(_self: any, position: any)
		local delta = position - state.mouse
		state.delta, state.mouse = delta, position
		local io = inputObject(
			Enum.UserInputType.MouseMovement,
			Enum.KeyCode.Unknown,
			Enum.UserInputState.Change,
			dt.Vector3.new(delta.X, delta.Y, 0)
		)
		setLastType(Enum.UserInputType.MouseMovement)
		uis.InputChanged:Fire(io, false)
	end

	local function hitTestGui(gui: any, point: any): boolean
		local pos, size = gui.AbsolutePosition, gui.AbsoluteSize
		if
			pos == nil
			or size == nil
			or point.X < pos.X
			or point.Y < pos.Y
			or point.X >= pos.X + size.X
			or point.Y >= pos.Y + size.Y
		then
			return false
		end
		local anc = gui.Parent
		while anc ~= nil and not anc:IsA("LayerCollector") do
			if anc:IsA("GuiObject") and (anc.ClipsDescendants == true or anc:IsA("ScrollingFrame")) then
				local aPos, aSize = anc.AbsolutePosition, anc.AbsoluteSize
				if
					aPos == nil
					or aSize == nil
					or point.X < aPos.X
					or point.Y < aPos.Y
					or point.X >= aPos.X + aSize.X
					or point.Y >= aPos.Y + aSize.Y
				then
					return false
				end
			end
			anc = anc.Parent
		end
		return true
	end

	local function visible(gui: any): boolean
		local cur = gui
		while cur ~= nil do
			if
				(cur:IsA("GuiObject") and cur.Visible == false)
				or (cur:IsA("LayerCollector") and cur.Enabled == false)
			then
				return false
			end
			cur = cur.Parent
		end
		return true
	end

	local function chainOf(gui: any): ({ any }, any)
		local chain, cur = {}, gui
		while cur ~= nil and not cur:IsA("LayerCollector") do
			table.insert(chain, 1, cur)
			cur = cur.Parent
		end
		return chain, cur
	end

	local function above(a: any, b: any): boolean
		local aLayer, bLayer = a.layer, b.layer
		if aLayer ~= bLayer then
			local aDisplay = if aLayer ~= nil and aLayer:IsA("ScreenGui") then aLayer.DisplayOrder or 0 else 0
			local bDisplay = if bLayer ~= nil and bLayer:IsA("ScreenGui") then bLayer.DisplayOrder or 0 else 0
			return if aDisplay ~= bDisplay then aDisplay > bDisplay else a.order > b.order
		end
		if aLayer == nil or aLayer.ZIndexBehavior ~= Enum.ZIndexBehavior.Sibling then
			local aZ, bZ = a.gui.ZIndex or 1, b.gui.ZIndex or 1
			return if aZ ~= bZ then aZ > bZ else a.order > b.order
		end
		for level = 1, math.min(#a.chain, #b.chain) do
			local x, y = a.chain[level], b.chain[level]
			if x ~= y then
				local xZ, yZ = x.ZIndex or 1, y.ZIndex or 1
				return if xZ ~= yZ then xZ > yZ else a.order > b.order
			end
		end
		return #a.chain > #b.chain
	end

	local function hit(point: any): any
		InstanceDouble.flushLayouts(env)
		local player = env.LocalPlayer
		local gui = if player ~= nil then player:FindFirstChild("PlayerGui") else env.playerGui
		if gui == nil then return nil end
		local best: any = nil
		for order, inst in gui:GetDescendants() do
			if
				(inst:IsA("GuiButton") or inst:IsA("TextBox"))
				and inst.Interactable ~= false
				and visible(inst)
				and hitTestGui(inst, point)
			then
				local chain, layer = chainOf(inst)
				local candidate = { gui = inst, order = order, chain = chain, layer = layer }
				if best == nil or above(candidate, best) then best = candidate end
			end
		end
		return if best ~= nil then best.gui else nil
	end

	function driver.click(self: any, target: any, button: any?)
		InstanceDouble.flushLayouts(env)
		local mouseButton = button or Enum.UserInputType.MouseButton1
		local gui: any = nil
		if ctx.typeof(target) == "Instance" then
			if not visible(target) then
				error(`env:input():click: {target:GetFullName()} is not visible`, 2)
			elseif target.Interactable == false then
				error(`env:input():click: {target:GetFullName()} is not interactable`, 2)
			end
			gui = target
			local pos, size = target.AbsolutePosition, target.AbsoluteSize
			if pos ~= nil and size ~= nil then driver.move(self, pos + size / 2) end
		elseif target ~= nil then
			driver.move(self, target)
			gui = hit(target)
		end
		local onGui = gui ~= nil
		local x, y = state.mouse.X, state.mouse.Y
		local suffix = if mouseButton == Enum.UserInputType.MouseButton2 then "2" else "1"
		local io = beginButton(mouseButton, onGui)
		local isButton = gui ~= nil and gui:IsA("GuiButton")
		if isButton then gui[`MouseButton{suffix}Down`]:Fire(x, y) end
		endButton(mouseButton, onGui)
		if isButton then
			gui[`MouseButton{suffix}Up`]:Fire(x, y)
			gui[`MouseButton{suffix}Click`]:Fire()
			if suffix == "1" then gui.Activated:Fire(io, 1) end
		elseif gui ~= nil and gui:IsA("TextBox") then
			if gui.ClearTextOnFocus ~= false and env._focusedBox ~= gui then gui.Text = "" end
			gui:CaptureFocus()
		elseif env._focusedBox ~= nil then
			env._focusedBox:ReleaseFocus(false)
		end
	end

	function driver.type(_self: any, text: string)
		local box = env._focusedBox
		if box == nil then error("env:input():type: no TextBox is focused (click one or call CaptureFocus)", 2) end
		box.Text = (box.Text or "") .. text
	end

	return table.freeze(driver)
end

local function installLoader(env: any, ctx: any)
	local createInstance = ctx.createInstance
	local globalTable = ctx.globalTable

	local function resolveStringTarget(path: string, callerScript: any?): any?
		if callerScript ~= nil then
			local relPath: string?, cur: any = nil, nil
			if string.sub(path, 1, 6) == "@self/" then
				relPath, cur = string.sub(path, 7), callerScript
			elseif string.sub(path, 1, 2) == "./" or string.sub(path, 1, 3) == "../" then
				relPath, cur = path, rawget(callerScript, "_parent")
			end
			if relPath ~= nil then
				for seg in string.gmatch(relPath, "[^/]+") do
					if cur == nil then
						break
					elseif seg ~= "." then
						cur = if seg == ".." then rawget(cur, "_parent") else cur:FindFirstChild(seg)
					end
				end
				assert(cur ~= nil, `env:require: could not resolve "{path}" from {callerScript:GetFullName()}`)
				return cur
			end
		end
		local mounted = env._mountedByPath[path]
		if mounted ~= nil then return mounted end
		local clean = string.gsub(path, "^[Gg]ame[./]", "")
		local cur: any = env.game
		local first = true
		for seg in string.gmatch(clean, "[^/.]+") do
			if cur == nil then return nil end
			if first then
				first = false
				if env:_hasService(seg) then
					cur = ctx.getService(seg)
				else
					cur = cur:FindFirstChild(seg)
				end
			else
				cur = cur:FindFirstChild(seg)
			end
		end
		return if not first and cur ~= env.game then cur else nil
	end

	function env.require(_self: any, target: any, callerScript: any?): any
		if type(target) == "string" then
			local resolved = resolveStringTarget(target, callerScript)
			if resolved ~= nil then target = resolved end
		end
		if type(target) == "function" then
			local cached = env._loaded[target]
			if cached ~= nil then return if cached == NIL_MODULE then nil else cached end
			assert(not env._loading[target], "env:require: cyclic require on function module")
			env._loading[target] = true
			local scriptInst = createInstance("ModuleScript", nil, true)
			local childEnv = setmetatable({
				script = scriptInst,
				require = function(reqTarget: any): any return env:require(reqTarget, scriptInst) end,
			}, { __index = env.globals, __newindex = globalTable })
			local numParams, isVararg = debug.info(target :: (...any) -> ...any, "a")
			local results: { [number]: any, n: number }
			if (numParams ~= nil and numParams >= 1) or isVararg then
				results = table.pack(pcall(target, childEnv))
			else
				if setfenv ~= nil then (setfenv :: any)(target, childEnv) end
				results = table.pack(pcall(target))
			end
			env._loading[target] = nil
			if not results[1] then
				error(results[2], 0)
			elseif results.n ~= 2 then
				error("env:require: module function did not return exactly one value", 0)
			end
			local result = results[2]
			env._loaded[target] = if result == nil then NIL_MODULE else result
			return result
		end
		if type(target) == "table" then
			if rawget(target, "_isInstance") ~= true then return target end
			local cached = env._loaded[target]
			if cached ~= nil then return if cached == NIL_MODULE then nil else cached end
			assert(not env._loading[target], `env:require: cyclic require on {target:GetFullName()}`)
			local factory: any = rawget(target, "_factory")
			if factory == nil then
				local loader: any = rawget(target, "_loader")
				if type(loader) == "function" then
					factory = (loader :: () -> any)()
					rawset(target, "_factory", factory)
				end
			end
			if type(factory) == "string" then
				error(`env:require: ModuleScript {target:GetFullName()} failed to load: {factory}`, 0)
			end
			assert(
				type(factory) == "function",
				`env:require: ModuleScript {target:GetFullName()} has no staged factory`
			)
			env._loading[target] = true
			local childEnv = setmetatable({
				script = target,
				require = function(reqTarget: any): any return env:require(reqTarget, target) end,
			}, { __index = env.globals, __newindex = globalTable })
			local numParams, isVararg = debug.info(factory :: (...any) -> ...any, "a")
			local results: { [number]: any, n: number }
			if (numParams ~= nil and numParams >= 1) or isVararg then
				results = table.pack(pcall(factory, childEnv))
			else
				if setfenv ~= nil then (setfenv :: any)(factory, childEnv) end
				results = table.pack(pcall(factory))
			end
			env._loading[target] = nil
			if not results[1] then
				error(results[2], 0)
			elseif results.n ~= 2 then
				error(`env:require: ModuleScript {target:GetFullName()} did not return exactly one value`, 0)
			end
			local result = results[2]
			env._loaded[target] = if result == nil then NIL_MODULE else result
			return result
		end
		return (nativeRequire :: any)(target)
	end

	function env.mount(_self: any, stage: any, parent: any?): any
		local files: { [string]: any } = stage.files or {}
		local rootSpec = stage.root or stage

		local function buildNode(node: any, intoParent: any?, overrideName: string?, prefix: string?): any
			local className = node.className or "Folder"
			local name = overrideName or node.name or className
			local mountPath = if prefix ~= nil and prefix ~= "" then `{prefix}/{name}` else name
			local inst: any = nil
			if intoParent == env.game and (className == "DataModel" or env:_hasService(name)) then
				inst = if className == "DataModel" then env.game else ctx.getService(name)
			else
				if intoParent ~= nil then
					local existingChildren = rawget(intoParent, "_children")
					if existingChildren ~= nil then
						for _, child in existingChildren do
							if child._props.Name == name and child._props.ClassName == className then
								inst = child
								break
							end
						end
					end
				end
				if inst == nil then
					inst = createInstance(className, nil, true)
					inst.Name = name
					if intoParent ~= nil then inst.Parent = intoParent end
				end
			end
			rawset(inst, "_mountPath", mountPath)
			env._mountedByPath[mountPath] = inst
			if node.value ~= nil then inst.Value = node.value end
			if type(node.props) == "table" then
				for _, propKey in util.sortedKeys(node.props) do
					local propVal = node.props[propKey]
					if propKey == "Tags" and type(propVal) == "table" then
						for _, tag in propVal do
							inst:AddTag(tag)
						end
					else
						inst[propKey] = propVal
					end
				end
			end
			if type(node.attributes) == "table" then
				for _, attrKey in util.sortedKeys(node.attributes) do
					inst:SetAttribute(attrKey, node.attributes[attrKey])
				end
			end
			if type(node.factory) == "function" then rawset(inst, "_factory", node.factory) end
			if type(node.loader) == "function" then rawset(inst, "_loader", node.loader) end
			if node.file ~= nil and files[node.file] ~= nil then rawset(inst, "_loader", files[node.file]) end
			if node.children ~= nil then
				for _, childName in util.sortedKeys(node.children) do
					buildNode(node.children[childName], inst, childName, mountPath)
				end
			end
			return inst
		end

		local targetParent = parent
		if rootSpec.className == "DataModel" then
			if parent ~= nil and parent ~= env.game then
				error(`env:mount: a place project (DataModel root) mounts into env.game, not {parent:GetFullName()}`, 2)
			end
			targetParent = env.game
		elseif targetParent == nil then
			targetParent = ctx.replicatedStorage
		end
		return buildNode(rootSpec, targetParent, rootSpec.name, "")
	end
end

export type SignalBehavior = Signal.SignalBehavior

export type SettleOptions = {
	maxFrames: number?,
	dt: number?,
}

export type Options = {
	isServer: boolean?,
	isClient: boolean?,
	isStudio: boolean?,
	strict: boolean?,
	signalBehavior: SignalBehavior?,
	viewport: any?,
	creatorId: number?,
	creatorType: any?,
	placeId: number?,
	gameId: number?,
	jobId: string?,
	frameRate: number?,
	datatypes: any?,
	host: Host?,
	peerBridge: any?,
	remoteHandler: ((inst: any, method: string, ...any) -> ...any)?,
	localPlayer: (number | string | { UserId: number?, Name: string?, DisplayName: string?, AccountAge: number? })?,
	teleportData: any?,
}

type PeerOptions = Options & { world: any?, server: any?, client: any? }

export type Host = {
	clock: (() -> number)?,
	unixTime: (() -> number)?,
	spawn: ((fnOrThread: any, ...any) -> thread)?,
	defer: ((fnOrThread: any, ...any) -> thread)?,
	deferSignal: ((fn: (...any) -> (), ...any) -> ())?,
	delay: ((seconds: number?, fnOrThread: any, ...any) -> thread)?,
	wait: ((seconds: number?) -> number)?,
	cancel: ((thread: thread) -> ())?,
	bindClose: ((fn: () -> ()) -> ())?,
}

export type Input = {
	press: (self: Input, keyCode: any) -> (),
	release: (self: Input, keyCode: any) -> (),
	move: (self: Input, position: any) -> (),
	click: (self: Input, target: any, button: any?) -> (),
	type: (self: Input, text: string) -> (),
}

export type Kick = { player: any, userId: number, message: string, at: number }

export type Env = {
	world: any,
	server: any,
	client: any,
	isServer: boolean,
	isClient: boolean,
	isStudio: boolean,
	strict: boolean,
	signalBehavior: SignalBehavior,
	now: number,
	frameRate: number,
	viewport: any,
	datatypes: any,
	game: any,
	workspace: any,
	Workspace: any,
	camera: any,
	Players: any,
	LocalPlayer: any,
	localPlayer: any,
	playerGui: any,
	PlayerGui: any,
	services: { [string]: any },
	Instance: any,
	task: any,
	typeof: (value: any) -> string,
	type: (value: any) -> string,
	Random: any,
	Ray: any,
	Color3: any,
	BrickColor: any,
	UDim: any,
	UDim2: any,
	Vector2: any,
	Vector3: any,
	Vector2int16: any,
	Vector3int16: any,
	CFrame: any,
	Rect: any,
	Region3: any,
	Axes: any,
	Faces: any,
	NumberRange: any,
	ColorSequence: any,
	ColorSequenceKeypoint: any,
	NumberSequence: any,
	NumberSequenceKeypoint: any,
	Font: any,
	TweenInfo: any,
	FloatCurveKey: any,
	Enum: any,
	CatalogSearchParams: any,
	RaycastParams: any,
	OverlapParams: any,
	PhysicalProperties: any,
	PathWaypoint: any,
	DateTime: any,
	globals: { [string]: any },
	shared: { [any]: any },
	_G: { [any]: any },
	teleports: { any },
	badges: { [number]: { [number]: boolean } },
	groups: { [number]: any },
	friends: { [number]: { [number]: boolean } },
	bans: { [number]: any },
	kicks: { Kick },
	userNames: { [number]: string },
	marketplace: any,
	textFilter: ((text: string, fromUserId: number) -> string)?,
	httpHandler: ((request: any) -> any)?,
	peerBridge: any?,
	remoteHandler: ((inst: any, method: string, ...any) -> ...any)?,

	step: (self: Env, dt: number?) -> number,
	advance: (self: Env, seconds: number) -> number,
	frames: (self: Env, count: number, dt: number?) -> number,
	settle: (self: Env, opts: SettleOptions?) -> number,
	flush: (self: Env) -> (),
	signal: (self: Env) -> any,
	input: (self: Env) -> Input,
	getService: (selfOrName: any, maybeName: string?) -> any,
	setAbsolute: (self: Env, gui: any, size: any?, position: any?) -> (),
	setViewport: (self: Env, size: any) -> (),
	triggerPrompt: (self: Env, prompt: any, player: any?, holdDuration: number?) -> (boolean, string?),
	createInstance: ((self: Env, className: string, parent: any?, bypassAbstract: boolean?) -> any)
		& ((className: string, parent: any?, bypassAbstract: boolean?) -> any),
	addPlayer: (self: Env, userIdOrSpec: any, name: string?) -> any,
	removePlayer: (self: Env, userIdOrPlayer: any) -> (),
	setBadge: (self: Env, userId: number, badgeId: number, owned: boolean?) -> (),
	setGamePass: (self: Env, userId: number, passId: number, owned: boolean?) -> (),
	setProductInfo: (self: Env, id: number, info: { [string]: any }?) -> (),
	setGroupRank: (self: Env, userId: number, groupId: number, rank: number, role: string?) -> (),
	onHttp: (self: Env, handler: ((request: any) -> any)?) -> (),
	onTextFilter: (self: Env, fn: ((text: string, fromUserId: number) -> string)?) -> (),
	require: (self: Env, target: any, callerScript: any?) -> any,
	mount: (self: Env, stage: any, parent: any?) -> any,
	bind: <F>(self: Env, fn: F) -> F,
	run: (self: Env, fn: (...any) -> ...any, ...any) -> ...any,
	destroy: (self: Env) -> (),
	shutdown: (self: Env) -> (),
}

export type EnvNamespace = {
	new: (options: Options?) -> Env,
	active: () -> Env?,
	getService: (selfOrName: any, maybeName: string?) -> any,
	hooks: { wait: (() -> ())? },
	isRoblox: boolean,
	game: any,
	workspace: any,
	services: { [string]: any },
	Instance: any,
	task: any,
	typeof: (value: any) -> string,
	type: (value: any) -> string,
	Random: any,
	Ray: any,
	Color3: any,
	BrickColor: any,
	UDim: any,
	UDim2: any,
	Vector2: any,
	Vector3: any,
	Vector2int16: any,
	Vector3int16: any,
	CFrame: any,
	Rect: any,
	Region3: any,
	Axes: any,
	Faces: any,
	NumberRange: any,
	ColorSequence: any,
	ColorSequenceKeypoint: any,
	NumberSequence: any,
	NumberSequenceKeypoint: any,
	Font: any,
	TweenInfo: any,
	FloatCurveKey: any,
	Enum: any,
	CatalogSearchParams: any,
	RaycastParams: any,
	OverlapParams: any,
	PhysicalProperties: any,
	PathWaypoint: any,
	DateTime: any,
}

local DATATYPE_GLOBALS = Datatypes.DATATYPE_GLOBALS
local customUtf8 = Datatypes.utf8

local ROBLOX_DATATYPES: { [string]: any } = if IS_ROBLOX
	then {
		Random = Random,
		Ray = Ray,
		Color3 = Color3,
		BrickColor = BrickColor,
		UDim = UDim,
		UDim2 = UDim2,
		Vector2 = Vector2,
		Vector3 = Vector3,
		Vector2int16 = Vector2int16,
		Vector3int16 = Vector3int16,
		CFrame = CFrame,
		Rect = Rect,
		Region3 = Region3,
		Axes = Axes,
		Faces = Faces,
		NumberRange = NumberRange,
		ColorSequence = ColorSequence,
		ColorSequenceKeypoint = ColorSequenceKeypoint,
		NumberSequence = NumberSequence,
		NumberSequenceKeypoint = NumberSequenceKeypoint,
		Font = Font,
		TweenInfo = TweenInfo,
		FloatCurveKey = FloatCurveKey,
		Enum = Enum,
		CatalogSearchParams = CatalogSearchParams,
		RaycastParams = RaycastParams,
		OverlapParams = OverlapParams,
		PhysicalProperties = PhysicalProperties,
		PathWaypoint = PathWaypoint,
		DateTime = DateTime,
	}
	else {}

local function wrapTypeof(fn: ((any) -> string)?): (any) -> string
	if fn == nil or fn == Datatypes.typeof or fn == typeof then return Datatypes.typeof end
	return function(v: any): string return doubleTag(v) or fn(v) end
end

local function wrapType(fn: ((any) -> string)?): (any) -> string
	if fn == nil or fn == Datatypes.type or fn == type then return Datatypes.type end
	return function(v: any): string return if doubleTag(v) ~= nil then "userdata" else fn(v) end
end

local function mergeDatatypes(injected: any): any
	if injected == Datatypes or (injected == nil and not IS_ROBLOX) then
		return setmetatable({
			_isDefault = true,
			typeof = Datatypes.typeof,
			type = Datatypes.type,
		}, { __index = Datatypes })
	end
	local hasInjected = injected ~= nil
	local injectedEnum = (hasInjected and injected.Enum ~= nil and injected.makeEnum == nil) or IS_ROBLOX
	return setmetatable({
		_injectedEnum = injectedEnum,
		typeof = wrapTypeof(if hasInjected then injected.typeof else nil),
		type = wrapType(if hasInjected then injected.type else nil),
	}, {
		__index = function(_: any, key: any): any
			if hasInjected then
				local v = injected[key]
				if v ~= nil then return v end
			end
			if IS_ROBLOX then
				local rv = ROBLOX_DATATYPES[key]
				if rv ~= nil then return rv end
			end
			return Datatypes[key]
		end,
	})
end

local function outsideHost(given: Host?, world: any, peer: any): Host?
	if given == nil then return nil end
	assert(world == nil and peer == nil, "sert.env: host is for standalone envs (no world, server or client)")
	assert(type(given.clock) == "function", "sert.env: host.clock must be a function")
	local host: any = table.clone(given :: any)
	local function runNow(fnOrThread: any, ...: any): thread
		local th = if type(fnOrThread) == "thread" then fnOrThread else coroutine.create(fnOrThread)
		local ok, err = coroutine.resume(th, ...)
		if not ok then error(err, 0) end
		return th
	end
	host.spawn = host.spawn or runNow
	host.defer = host.defer or runNow
	return host
end

local FALLBACK_BASE_ENV: { [string]: any } = {
	_VERSION = _VERSION,
	assert = assert,
	bit32 = bit32,
	buffer = buffer,
	coroutine = coroutine,
	debug = debug,
	error = error,
	gcinfo = gcinfo,
	getmetatable = getmetatable,
	ipairs = ipairs,
	loadstring = loadstring :: any,
	math = math,
	newproxy = newproxy,
	next = next,
	pairs = pairs,
	pcall = pcall,
	print = print,
	rawequal = rawequal,
	rawget = rawget,
	rawlen = rawlen,
	rawset = rawset,
	select = select,
	setfenv = setfenv :: any,
	setmetatable = setmetatable,
	string = string,
	table = table,
	tonumber = tonumber,
	tostring = tostring,
	unpack = unpack,
	utf8 = utf8,
	vector = vector,
	xpcall = xpcall,
}

local function setOwnedEntry(map: { [number]: { [any]: boolean? } }, userId: number, id: any, owned: boolean?)
	local entry = map[userId]
	if entry == nil then
		entry = {}
		map[userId] = entry
	end
	entry[id] = if owned == false then nil else true
end

local function attachEnvHelpers(env: any, ctx: any)
	function env.setBadge(_self: any, userId: number, badgeId: number, owned: boolean?)
		setOwnedEntry(env.badges, userId, badgeId, owned)
	end
	function env.setGamePass(_self: any, userId: number, passId: number, owned: boolean?)
		setOwnedEntry(env.marketplace.gamePasses, userId, passId, owned)
	end
	function env.setProductInfo(_self: any, id: number, info: { [string]: any }?) env.marketplace.products[id] = info end
	function env.setGroupRank(_self: any, userId: number, groupId: number, rank: number, role: string?)
		local g = env.groups[groupId] or {}
		env.groups[groupId] = g
		g.ranks, g.roles = g.ranks or {}, g.roles or {}
		g.ranks[userId] = if rank > 0 then rank else nil
		g.roles[userId] = if rank > 0 then role else nil
	end
	function env.onHttp(_self: any, handler: ((request: any) -> any)?) env.httpHandler = handler end
	function env.onTextFilter(_self: any, fn: ((text: string, fromUserId: number) -> string)?) env.textFilter = fn end
	function env.setAbsolute(_self: any, gui: any, size: any?, position: any?)
		InstanceDouble.setAbsolute(gui, size, position)
	end
	function env.setViewport(self: any, size: any)
		assert(ctx.typeof(size) == "Vector2", "env:setViewport: size must be a Vector2")
		self.viewport = size
		self._viewport = size
		if self.camera ~= nil then
			rawset(self.camera, "_viewportSet", true)
			self.camera._props.ViewportSize = size
		end
		local seen: { [any]: boolean } = {}
		local function updateContainer(container: any)
			if container == nil or seen[container] then return end
			seen[container] = true
			container._props.AbsoluteSize = size
			InstanceDouble.relayout(container)
			for _, desc in container:GetDescendants() do
				if desc:IsA("LayerCollector") then
					seen[desc] = true
					if rawget(desc, "_pinnedSize") == nil then desc._props.AbsoluteSize = size end
					InstanceDouble.relayout(desc)
				end
			end
		end
		updateContainer(self.playerGui)
		updateContainer(self.services.CoreGui)
		if self.Players ~= nil then
			for _, plr in self.Players:GetPlayers() do
				updateContainer(plr:FindFirstChild("PlayerGui"))
			end
		end
		if self.game ~= nil then
			for _, desc in self.game:GetDescendants() do
				if desc:IsA("LayerCollector") or desc:IsA("BasePlayerGui") then updateContainer(desc) end
			end
		end
		for _, lc in self._layerCollectorList do
			if not seen[lc] and rawget(lc, "_destroyed") ~= true then
				if rawget(lc, "_pinnedSize") == nil then lc._props.AbsoluteSize = size end
				InstanceDouble.relayout(lc)
			end
		end
	end
	function env.triggerPrompt(self: any, prompt: any, player: any?, holdDuration: number?): (boolean, string?)
		if type(prompt) ~= "table" or not prompt:IsA("ProximityPrompt") then
			error("env:triggerPrompt: expected a ProximityPrompt Instance", 2)
		end
		if prompt.Enabled == false then return false, "disabled" end
		local p = player
			or self.localPlayer
			or self.LocalPlayer
			or (if self.services.Players ~= nil then self.services.Players.LocalPlayer else nil)
		if p == nil and self.Players ~= nil then p = self.Players:GetPlayers()[1] end
		if p == nil then p = ctx.createInstance("Player", nil, true) end

		local char = p.Character
		local parent = prompt.Parent
		if char ~= nil and parent ~= nil then
			local rootPart = char.PrimaryPart or char:FindFirstChild("HumanoidRootPart")
			if rootPart ~= nil and rootPart:IsA("BasePart") then
				local promptPos: any = nil
				if parent:IsA("BasePart") then
					promptPos = parent.Position
				elseif parent:IsA("Attachment") then
					local worldPos = parent._props.WorldPosition
					if worldPos ~= nil then
						promptPos = worldPos
					elseif parent.Parent ~= nil and parent.Parent:IsA("BasePart") then
						promptPos = parent.Parent.Position + parent.Position
					else
						promptPos = parent.Position
					end
				elseif parent:IsA("Model") then
					promptPos = parent:GetPivot().Position
				end
				if promptPos ~= nil then
					local maxDist = prompt.MaxActivationDistance or 10
					local dist = (rootPart.Position - promptPos).Magnitude
					if dist > maxDist then return false, "out_of_range" end
				end
			end
		end

		local pps = ctx.getService("ProximityPromptService")
		local reqHold = prompt.HoldDuration or 0
		if reqHold > 0 then
			local actualHold = if holdDuration ~= nil then holdDuration else reqHold
			prompt.PromptButtonHoldBegan:Fire(p)
			pps.PromptButtonHoldBegan:Fire(prompt, p)
			if actualHold < reqHold then
				if actualHold > 0 then self:advance(actualHold) end
				prompt.PromptButtonHoldEnded:Fire(p)
				pps.PromptButtonHoldEnded:Fire(prompt, p)
				return false, "hold_too_short"
			end
			self:advance(reqHold)
			prompt.PromptButtonHoldEnded:Fire(p)
			pps.PromptButtonHoldEnded:Fire(prompt, p)
		end

		prompt.Triggered:Fire(p)
		pps.PromptTriggered:Fire(prompt, p)
		return true, nil
	end

	local inputDriver: any = nil
	function env.input(_self: any): any
		if inputDriver == nil then inputDriver = buildInput(env, ctx) end
		return inputDriver
	end
end

local function mountCoreServices(
	env: any,
	ctx: any,
	gProps: { [string]: any },
	sched: any,
	outside: boolean,
	envOwner: any
)
	local services: { [string]: any } = ctx.services
	local serviceBuilders: { [string]: () -> any } = ctx.serviceBuilders
	local gameInst = ctx.gameInst
	local createInstance = ctx.createInstance
	local isStrict: boolean = ctx.isStrict
	local isClient: boolean = ctx.isClient
	local host: Host? = ctx.host
	local server = ctx.server
	local getClock: () -> number = ctx.getClock

	local workspaceInst = ServiceRegistry.eager.Workspace(env, ctx)
	workspaceInst._props.DistributedGameTime = 0
	ctx.workspaceInst = workspaceInst
	ctx.cameraInst = workspaceInst._props.CurrentCamera
	ctx.cameraInst._props.ViewportSize = env.viewport
	if env._viewport ~= nil then rawset(ctx.cameraInst, "_viewportSet", true) end
	env.camera = ctx.cameraInst
	ctx.terrainInst = workspaceInst._props.Terrain
	services.Workspace, env.workspace, env.Workspace = workspaceInst, workspaceInst, workspaceInst

	local replicatedStorage = createInstance("ReplicatedStorage", gameInst, true)
	rawset(replicatedStorage, "_isService", true)
	replicatedStorage.Name = "ReplicatedStorage"
	services.ReplicatedStorage, ctx.replicatedStorage = replicatedStorage, replicatedStorage

	local coreGui = createInstance("CoreGui", gameInst, true)
	rawset(coreGui, "_isService", true)
	coreGui.Name = "CoreGui"
	coreGui._props.AbsoluteSize = env.viewport
	services.CoreGui = coreGui

	local pps = createInstance("ProximityPromptService", gameInst, true)
	rawset(pps, "_isService", true)
	pps.Name = "ProximityPromptService"
	services.ProximityPromptService = pps

	local runService = ServiceRegistry.eager.RunService(env, ctx)
	services.RunService, ctx.runService = runService, runService
	gProps.Workspace, gProps.workspace, gProps.RunService, gProps.PlaceVersion =
		workspaceInst, workspaceInst, runService, 0

	local playersInst = ServiceRegistry.eager.Players(env, ctx)
	services.Players, ctx.playersInst, env.Players = playersInst, playersInst, playersInst
	env.localPlayer = env.LocalPlayer
	if env.LocalPlayer ~= nil then
		env.playerGui = env.LocalPlayer:FindFirstChild("PlayerGui")
	else
		local pg = createInstance("PlayerGui", nil, true)
		pg.Name = "PlayerGui"
		pg._props.AbsoluteSize = env.viewport
		env.playerGui = pg
	end
	env.PlayerGui = env.playerGui

	for name, builder in ServiceRegistry.lazy do
		serviceBuilders[name] = function(): any return builder(env, ctx, name) end
	end

	function env._hasService(_self: any, name: string): boolean
		return services[name] ~= nil or serviceBuilders[name] ~= nil
	end

	local function getService(_self: any, serviceName: string): any
		local found = rawget(services, serviceName)
		if found ~= nil then return found end
		local builder = serviceBuilders[serviceName]
		if builder ~= nil then
			local built = builder()
			rawset(services, serviceName, built)
			return built
		end
		if isStrict or type(serviceName) ~= "string" or not Generated.isService(serviceName) then
			error(`'{tostring(serviceName)}' is not a valid Service name`, 2)
		end
		local dynamic = createInstance(serviceName, gameInst, true)
		rawset(dynamic, "_isService", true)
		dynamic.Name = serviceName
		rawset(services, serviceName, dynamic)
		return dynamic
	end
	ctx.getService = function(name: string): any return getService(gameInst, name) end
	function env.getService(first: any, second: any?): any
		return getService(gameInst, if first == env then second else first)
	end
	local servicesProxy: any = setmetatable({}, {
		__index = function(_: any, name: any): any
			local found = rawget(services, name)
			if found ~= nil then return found end
			if type(name) == "string" and (serviceBuilders[name] ~= nil or Generated.isService(name)) then
				return getService(gameInst, name)
			end
			return nil
		end,
		__newindex = function(_: any, name: any, val: any) rawset(services, name, val) end,
	})
	env.services = servicesProxy

	local closeCallbacks: { () -> () } = {}
	gProps._closeCallbacks = closeCallbacks

	local function disconnectServiceConnections()
		local conns: { any } = ctx.serviceConnections
		for _, conn in table.clone(conns) do
			if conn ~= nil and type((conn :: any).Disconnect) == "function" then (conn :: any):Disconnect() end
		end
		table.clear(conns)
	end

	local function runCloseCallbacks()
		disconnectServiceConnections()
		for _, fn in table.clone(closeCallbacks) do
			fn()
		end
	end

	function env.destroy(_self: any)
		if rawget(env, "_destroyed") then return end
		rawset(env, "_destroyed", true)
		if registry.activeEnv() == env then
			registry.setActiveEnv(nil)
			local clearDriver: (() -> ())? = rawget(env, "_clearYieldDriver")
			if clearDriver ~= nil then clearDriver() end
		end
		disconnectServiceConnections()
		if sched ~= nil then sched:crash(envOwner) end
	end

	function env.shutdown(self: any)
		if rawget(env, "_destroyed") then return end
		local shutdownFn: ((any) -> ())? = if server ~= nil then server.shutdown else nil
		if ctx.isServer and shutdownFn ~= nil then
			self:destroy()
			shutdownFn(server)
		elseif ctx.client ~= nil then
			runCloseCallbacks()
			self:destroy()
			local leaveFn: ((any) -> ())? = ctx.client.leave
			if leaveFn ~= nil then leaveFn(ctx.client) end
		else
			runCloseCallbacks()
			self:destroy()
		end
	end

	rawset(gameInst, "_methods", {
		IsLoaded = function(): boolean return true end,
		GetService = getService,
		FindService = function(self: any, serviceName: string): any
			if type(serviceName) ~= "string" or not Generated.isService(serviceName) then return nil end
			return getService(self, serviceName)
		end,
		GetObjects = function(): { any } return {} end,
		BindToClose = function(_self: any, fn: () -> ())
			table.insert(closeCallbacks, fn)
			if host ~= nil and host.bindClose ~= nil then host.bindClose(fn) end
		end,
		_close = runCloseCallbacks,
	})

	local function syncDistributedGameTime()
		local t = getClock()
		if workspaceInst._props.DistributedGameTime ~= t then
			workspaceInst._props.DistributedGameTime = t
			local propSignals: { [string]: any }? = rawget(workspaceInst, "_propSignals") :: any
			if propSignals ~= nil then
				local dgtSig: any = propSignals.DistributedGameTime
				if dgtSig ~= nil then dgtSig:Fire() end
			end
			local sigs: { [string]: any }? = rawget(workspaceInst, "_signals") :: any
			if sigs ~= nil then
				local changedSig: any = sigs.Changed
				if changedSig ~= nil then changedSig:Fire("DistributedGameTime") end
			end
		end
	end
	env._syncDistributedGameTime = syncDistributedGameTime

	if sched ~= nil or outside then
		local props = runService._props
		local function drainIfSched()
			if sched ~= nil then sched:drain() end
		end
		local function runFrame(step: number)
			if step <= 0 then return end
			syncDistributedGameTime()
			if isClient then
				if #ctx.renderSteps > 0 then
					for _, entry in table.clone(ctx.renderSteps) :: { any } do
						entry.fn(step)
					end
				end
				props.PreRender:Fire(step)
				props.RenderStepped:Fire(step)
				drainIfSched()
			end
			props.PreAnimation:Fire(step)
			drainIfSched()
			props.Stepped:Fire(getClock(), step)
			drainIfSched()
			props.PreSimulation:Fire(step)
			drainIfSched()
			props.PostSimulation:Fire(step)
			drainIfSched()
			if #ctx.frameCallbacks > 0 then
				for _, fn in table.clone(ctx.frameCallbacks) :: { (number) -> () } do
					fn(step)
				end
			end
			props.Heartbeat:Fire(step)
			drainIfSched()
			InstanceDouble.flushLayouts(env)
			drainIfSched()
		end
		if sched ~= nil then
			sched:onFrame(runFrame, envOwner)
		else
			env._runFrame = runFrame
		end
	elseif runService._props.PreAnimation ~= nil then
		local conns: { any } = ctx.serviceConnections
		local conn: any = runService._props.PreAnimation:Connect(function() syncDistributedGameTime() end)
		table.insert(conns, conn)
	end

	return workspaceInst
end

local function buildEnvGlobals(env: any, ctx: any, InstanceLib: any)
	local dt = ctx.dt
	local Enum, customTypeof = ctx.Enum, ctx.typeof
	local getClock, getUnixTime = ctx.getClock, ctx.getUnixTime
	local taskOps = ctx.task
	local services = ctx.services

	local sharedTable: { [any]: any } = {}
	local globalTable: { [any]: any } = setmetatable({}, { __index = Env._sharedG }) :: any
	env.shared, env._G, ctx.globalTable = sharedTable, globalTable, globalTable

	local customOs = setmetatable({
		clock = getClock,
		time = function(t: any?): number return if t ~= nil then os.time(t) else math.floor(getUnixTime()) end,
	}, { __index = os })

	local customTask = table.freeze({
		wait = taskOps.wait,
		spawn = taskOps.spawn,
		defer = taskOps.defer,
		delay = taskOps.delay,
		cancel = taskOps.cancel,
		synchronize = function() end,
		desynchronize = function() end,
	})
	env.task = customTask

	local function logTo(messageType: any, ...: any)
		local msg = output.join(...)
		if messageType == Enum.MessageType.MessageWarning then
			output.warn(msg)
		else
			output.print(msg)
		end
		local ls = services.LogService
		if ls ~= nil and ls._props.MessageOut ~= nil then ls._props.MessageOut:Fire(msg, messageType) end
	end

	dt.DateTime = dt.makeDateTime(getUnixTime)
	local makeEnum = dt.makeEnum
	if not rawget(dt, "_injectedEnum") and type(makeEnum) == "function" then
		dt.Enum = (makeEnum :: any)(ctx.isStrict)
	end
	ctx.Enum = dt.Enum

	local warnFn = function(...: any) logTo(Enum.MessageType.MessageWarning, ...) end
	env._warn = warnFn

	local globals: { [string]: any } = {
		game = ctx.gameInst,
		Game = ctx.gameInst,
		workspace = ctx.workspaceInst,
		Workspace = ctx.workspaceInst,
		Instance = InstanceLib,
		shared = sharedTable,
		_G = globalTable,
		task = customTask,
		os = customOs,
		utf8 = customUtf8,
		tick = getUnixTime,
		time = getClock,
		elapsedTime = getClock,
		wait = taskOps.wait,
		spawn = function(fn: (...any) -> ...any) return taskOps.defer(fn) end,
		delay = taskOps.delay,
		print = function(...: any) logTo(Enum.MessageType.MessageOutput, ...) end,
		warn = warnFn,
		type = dt.type,
		typeof = customTypeof,
		require = function(target: any): any return env:require(target) end,
		DateTime = dt.DateTime,
	}
	for _, name in DATATYPE_GLOBALS do
		local val = dt[name]
		globals[name] = val
		env[name] = val
	end
	globals.Enum = dt.Enum
	env.Enum = dt.Enum
	env.DateTime = dt.DateTime
	env.typeof = customTypeof
	env.type = dt.type

	-- Never call `getfenv` here because `getfenv` permanently clears `safeenv` across the Luau VM.
	env.globals = setmetatable(globals, { __index = FALLBACK_BASE_ENV })
end

local function frameBusy(env: any): boolean
	local ctxAny: any = env._ctx
	if ctxAny == nil then return false end
	if #ctxAny.renderSteps > 0 or (ctxAny.activeTweens ~= nil and #ctxAny.activeTweens > 0) then return true end
	local rs = ctxAny.runService
	if rs ~= nil then
		for _, name in
			{ "PreRender", "RenderStepped", "PreAnimation", "Stepped", "PreSimulation", "PostSimulation", "Heartbeat" }
		do
			local sig = rs._props[name]
			if sig ~= nil and sig:connections() > 0 then return true end
		end
	end
	return false
end

local function buildTaskTable(
	sched: any,
	host: Host?,
	world: any,
	peer: any,
	outside: boolean,
	frameDt: number,
	envOwner: any,
	spawnedThreads: { [thread]: boolean },
	inside: () -> boolean,
	rethrow: () -> (),
	advance: (number) -> number
): (any, (number?) -> number, (((...any) -> ...any) | thread, ...any) -> thread)
	local delayedBy: { [thread]: thread } = setmetatable({}, { __mode = "k" }) :: any

	local function threadOf(fnOrThread: any): thread
		local th = if type(fnOrThread) == "thread" then fnOrThread else coroutine.create(fnOrThread)
		spawnedThreads[th] = true
		return th
	end

	local function taskWait(seconds: number?): number
		local hook = Env.hooks.wait
		if hook ~= nil then hook() end
		if sched == nil then
			local d = seconds or 0.03
			if host ~= nil and host.wait ~= nil and coroutine.isyieldable() then
				if world == nil or world.instant or (world.scheduler ~= nil and world.scheduler:running()) then
					return host.wait(d)
				end
			end
			if world ~= nil and not world.instant and not world.scheduler:running() then world:run(d) end
			return d
		end
		local running = coroutine.running()
		if coroutine.isyieldable() and (inside() or spawnedThreads[running]) then return sched:wait(seconds) end
		return advance(seconds or frameDt)
	end

	local function taskSpawn(fnOrThread: ((...any) -> ...any) | thread, ...: any): thread
		if host ~= nil and host.spawn ~= nil then
			if type(fnOrThread) == "thread" and world ~= nil and world.instant then
				local ok, err = coroutine.resume(fnOrThread, ...)
				if not ok then error(err, 0) end
				return fnOrThread
			end
			return host.spawn(fnOrThread :: any, ...)
		end
		local th = threadOf(fnOrThread)
		sched:spawn(envOwner, th, ...)
		rethrow()
		return th
	end

	local function taskDefer(fnOrThread: ((...any) -> ...any) | thread, ...: any): thread
		if host ~= nil and host.defer ~= nil then
			if type(fnOrThread) == "thread" and world ~= nil and world.instant then
				local th = fnOrThread
				return host.defer(function(...: any)
					local ok, err = coroutine.resume(th, ...)
					if not ok then error(err, 0) end
				end, ...)
			end
			return host.defer(fnOrThread :: any, ...)
		end
		local th = threadOf(fnOrThread)
		sched:defer(envOwner, th, ...)
		return th
	end

	local function taskDelay(seconds: number?, fnOrThread: ((...any) -> ...any) | thread, ...: any): thread
		if world ~= nil and world.scheduler ~= nil and not world.instant then
			return world.scheduler:after(seconds or 0, peer, fnOrThread, ...)
		elseif outside and host ~= nil and host.delay ~= nil then
			return host.delay(seconds, fnOrThread, ...)
		elseif sched == nil then
			return taskSpawn(fnOrThread, ...)
		end
		if type(fnOrThread) == "thread" then
			local target = fnOrThread
			local wrapper = threadOf(function(...: any)
				delayedBy[target] = nil
				if coroutine.status(target) == "suspended" then
					spawnedThreads[target] = true
					sched:spawn(envOwner, target, ...)
				end
			end)
			delayedBy[target] = wrapper
			sched:after(seconds or 0, envOwner, wrapper, ...)
			return target
		end
		local th = threadOf(fnOrThread)
		sched:after(seconds or 0, envOwner, th, ...)
		return th
	end

	local function taskCancel(thread: thread)
		if sched ~= nil then
			local wrapper = delayedBy[thread]
			if wrapper ~= nil then
				delayedBy[thread] = nil
				sched:cancel(wrapper)
			end
			sched:cancel(thread)
		elseif world ~= nil and world.scheduler ~= nil then
			local _ok = pcall(world.scheduler.cancel, world.scheduler, thread)
		elseif outside and host ~= nil and host.cancel ~= nil then
			host.cancel(thread)
			return
		end
		if type(thread) == "thread" and coroutine.status(thread) == "suspended" then
			local _ok = pcall(coroutine.close, thread)
		end
	end

	return { wait = taskWait, spawn = taskSpawn, defer = taskDefer, delay = taskDelay, cancel = taskCancel },
		taskWait,
		taskSpawn
end

type GeomSnap = { [number]: { number } }

local function snapshotGuiGeometry(env: any): GeomSnap
	local snap: GeomSnap = {}
	local visited: { [number]: boolean } = {}
	local function visitTree(root: any)
		if root == nil or rawget(root, "_destroyed") == true then return end
		local id: number = (rawget(root, "_id") :: any) or 0
		if id > 0 and visited[id] then return end
		if id > 0 then visited[id] = true end
		if root:IsA("GuiBase2d") then
			local pos = root._props.AbsolutePosition
			local size = root._props.AbsoluteSize
			snap[id] = {
				if pos ~= nil then pos.X else 0,
				if pos ~= nil then pos.Y else 0,
				if size ~= nil then size.X else 0,
				if size ~= nil then size.Y else 0,
			}
		end
		local children = rawget(root, "_children")
		if children ~= nil then
			for _, child in children do
				visitTree(child)
			end
		end
	end
	visitTree(env.playerGui)
	if env._services ~= nil then visitTree(env._services.CoreGui) end
	if env.Players ~= nil then
		for _, plr in env.Players:GetPlayers() do
			visitTree(plr:FindFirstChild("PlayerGui"))
		end
	end
	for _, lc in env._layerCollectorList do
		visitTree(lc)
	end
	return snap
end

local function sameGeometry(a: GeomSnap, b: GeomSnap): boolean
	for id, av in a do
		local bv = b[id]
		if bv == nil then return false end
		for i = 1, 4 do
			if math.abs(av[i] - bv[i]) > 1e-5 then return false end
		end
	end
	for id in b do
		if a[id] == nil then return false end
	end
	return true
end

local function buildSchedulerAndSignals(
	env: any,
	host: Host?,
	world: any,
	peer: any,
	outside: boolean,
	frameDt: number,
	signalBehavior: SignalBehavior
)
	local sched: any = if host == nil and world == nil then Scheduler.new({ frame = frameDt }) else nil
	local envOwner = table.freeze({ owner = "sert.env" })
	local reported = 0
	env._frameDt = frameDt
	env._sched = sched

	local function getClock(): number
		if host ~= nil and host.clock ~= nil then
			return host.clock()
		elseif world ~= nil and world.scheduler ~= nil then
			return world.scheduler.now
		end
		return if sched ~= nil then sched.now else 0
	end

	local function getUnixTime(): number
		if host ~= nil and host.unixTime ~= nil then
			return host.unixTime()
		elseif world ~= nil then
			return world:unix()
		end
		return util.UNIX_EPOCH + getClock()
	end

	(setmetatable :: any)(env, {
		__index = function(_: any, key: any): any
			if key == "now" then return getClock() end
			if type(key) == "string" then
				local hasSvc: ((any, string) -> boolean)? = rawget(env, "_hasService")
				if hasSvc ~= nil and hasSvc(env, key) then return env:getService(key) end
			end
			return nil
		end,
		__newindex = function(t: any, key: any, value: any)
			if key == "now" then error("env.now is read-only; move time with env:advance or env:step", 2) end
			rawset(t, key, value)
		end,
	})

	local spawnedThreads: { [thread]: boolean } = setmetatable({}, { __mode = "k" }) :: any

	local function inside(): boolean return sched ~= nil and sched.current == envOwner end

	local function rethrow()
		if sched == nil or inside() then return end
		local errors = sched.errors
		if #errors > reported then
			local first = errors[reported + 1]
			reported = #errors
			error(first.error, 0)
		end
	end

	local function frame(step: number)
		sched:frame(step)
		rethrow()
	end

	local function advance(seconds: number): number
		local s = sched
		local start = s.now
		local target = start + math.max(seconds, 0)
		s:drain()
		rethrow()
		while s.now + util.EPSILON < target do
			frame(math.min(frameDt, target - s.now))
		end
		if math.abs(s.now - target) <= util.EPSILON then
			s.now = target
			local syncDgt: (() -> ())? = rawget(env, "_syncDistributedGameTime")
			if syncDgt ~= nil then syncDgt() end
			return math.max(seconds, 0)
		end
		return s.now - start
	end

	local taskOps, taskWait, taskSpawn =
		buildTaskTable(sched, host, world, peer, outside, frameDt, envOwner, spawnedThreads, inside, rethrow, advance)

	local function canStepNow(): boolean
		if sched ~= nil then
			return not inside() and (not sched:idle() or frameBusy(env))
		elseif world ~= nil and world.scheduler ~= nil and not world.instant then
			return not world.scheduler:running() and not world.scheduler:idle()
		end
		return false
	end
	env._canStep = function(_self: any): boolean return canStepNow() end

	local deferSignalFn: Signal.DeferSignalFn? = nil
	if signalBehavior == "Deferred" then
		if sched ~= nil then
			deferSignalFn = function(fn: (...any) -> (), ...: any) sched:deferSignal(envOwner, fn, ...) end
		elseif host ~= nil and host.deferSignal ~= nil then
			deferSignalFn = host.deferSignal
		elseif world ~= nil and world.scheduler ~= nil and not world.instant then
			deferSignalFn = function(fn: (...any) -> (), ...: any) world.scheduler:deferSignal(peer, fn, ...) end
		end
	end
	env._deferSignal = deferSignalFn

	local signalOpts: Signal.SignalHost = {
		signalBehavior = signalBehavior,
		deferSignal = deferSignalFn,
		dispatch = function(fn: (...any) -> (), ...: any) taskSpawn(fn, ...) end,
		wait = function(_sig: Signal.Signal)
			if sched ~= nil then
				advance(frameDt)
			else
				taskWait(frameDt)
			end
		end,
		canStep = canStepNow,
		clock = getClock,
		isMainThread = function(): boolean
			if sched == nil then
				if
					(world == nil and host ~= nil)
					or (world ~= nil and world.scheduler ~= nil and not world.instant and world.scheduler:running())
				then
					return false
				end
			elseif inside() then
				return false
			end
			local running = coroutine.running()
			return not spawnedThreads[running]
		end,
		resume = function(wt: thread, ...: any)
			if sched ~= nil then
				if coroutine.status(wt) == "suspended" then
					sched:spawn(envOwner, wt, ...)
					rethrow()
				end
			elseif world ~= nil and world.scheduler ~= nil and not world.instant and world.scheduler:owns(wt) then
				world.scheduler:resume(wt, ...)
				if not world.scheduler:running() then world.scheduler:drain() end
			else
				local ok, err = coroutine.resume(wt, ...)
				if not ok then error(err, 0) end
			end
		end,
		shouldPark = if world ~= nil and not world.instant
			then function(): boolean
				local s = world.scheduler
				return s ~= nil and (s:running() or coroutine.running() == s.testThread)
			end
			else nil,
		park = if world ~= nil and not world.instant
			then function(onPark: (co: thread) -> ()): ...any
				if world.scheduler:running() then onPark(coroutine.running()) end
				return world.scheduler:park()
			end
			else nil,
	}

	local immediateOpts: Signal.SignalHost = table.clone(signalOpts)
	immediateOpts.signalBehavior = "Immediate"
	immediateOpts.deferSignal = nil

	function env.signal(_self: any): any return Signal.new(signalOpts) end
	function env._immediateSignal(_self: any): any return Signal.new(immediateOpts) end

	local function threadedSignal(): any return Signal.new(signalOpts) end

	function env.step(_self: any, seconds: number?): number
		if sched ~= nil then
			if inside() and coroutine.isyieldable() then return sched:wait(seconds or frameDt) end
			local step = seconds or frameDt
			sched:drain()
			rethrow()
			frame(step)
			return step
		elseif outside then
			local step = seconds or frameDt
			env._runFrame(step)
			return step
		end
		local d = taskWait(seconds)
		for _, entry in table.clone(env._ctx.renderSteps) :: { any } do
			entry.fn(d)
		end
		return d
	end

	function env.advance(_self: any, seconds: number): number
		if sched ~= nil then
			return advance(seconds)
		elseif outside then
			return 0
		elseif world ~= nil and not world.instant then
			world:run(seconds)
		end
		return seconds
	end

	function env.frames(self: any, count: number, dt: number?): number
		assert(type(count) == "number" and count >= 0, "env:frames: count must be a non-negative number")
		local total = 0
		for _ = 1, math.floor(count) do
			total += self:step(dt)
		end
		return total
	end

	function env.settle(self: any, settleOpts: SettleOptions?): number
		local maxFrames = if settleOpts ~= nil and settleOpts.maxFrames ~= nil then settleOpts.maxFrames else 60
		local stepDt = if settleOpts ~= nil and settleOpts.dt ~= nil then settleOpts.dt else frameDt
		self:flush()
		InstanceDouble.flushLayouts(self)
		if maxFrames <= 0 then return 0 end
		local prev = snapshotGuiGeometry(self)
		local framesStepped = 0
		while framesStepped < maxFrames do
			self:step(stepDt)
			framesStepped += 1
			local cur = snapshotGuiGeometry(self)
			local ctxAny: any = self._ctx
			local hasTweens = ctxAny ~= nil and ctxAny.activeTweens ~= nil and #ctxAny.activeTweens > 0
			local hasDeferred = sched ~= nil and sched.head <= sched.tail
			local layoutState: any = rawget(self, "_layoutState")
			local hasDirtyLayouts = layoutState ~= nil and #layoutState.dirtyOrder > 0
			if not hasTweens and not hasDeferred and not hasDirtyLayouts and sameGeometry(prev, cur) then break end
			prev = cur
		end
		return framesStepped
	end

	function env.flush(_self: any)
		if sched ~= nil then
			sched:drain()
			rethrow()
			sched:wakeDue()
			rethrow()
		elseif world ~= nil and world.scheduler ~= nil then
			world.scheduler:drain()
		end
	end

	return sched, envOwner, getClock, getUnixTime, threadedSignal, taskOps
end

local function envYieldDriver(thread: thread, timeout: number): (boolean, any)
	local active: any = registry.activeEnv()
	if active == nil or rawget(active, "_destroyed") == true then
		return false, "a test yielded outside Roblox without an active sert.env"
	end
	local sched: any = rawget(active, "_sched")
	local stepDt: number = (rawget(active, "_frameDt") :: any) or (1 / 60)
	local startErrors = if sched ~= nil then #sched.errors else 0
	local elapsed = 0
	while coroutine.status(thread) ~= "dead" and elapsed < timeout do
		local flushOk, flushErr = pcall(active.flush, active)
		if not flushOk then return false, flushErr end
		if coroutine.status(thread) == "dead" then break end
		if not active:_canStep() then return false, "test yielded with nothing scheduled in sert.env to resume it" end
		local stepOk, stepErr = pcall(active.step, active, stepDt)
		if not stepOk then return false, stepErr end
		elapsed += stepDt
	end
	if sched ~= nil and #sched.errors > startErrors then return false, sched.errors[startErrors + 1].error end
	if coroutine.status(thread) ~= "dead" then
		return false, string.format("test timed out after %g virtual seconds", timeout)
	end
	return true, nil
end

function Env.new(options: Options?): Env
	local opts: PeerOptions = (options or {}) :: any
	local server, client = opts.server, opts.client
	local world = opts.world or (if server then server.world elseif client then client.world else nil)
	local peer = client or server
	local host: Host? = outsideHost(opts.host, world, peer) or if peer ~= nil then peer.host else nil
	local outside = opts.host ~= nil

	local isClient = if opts.isClient ~= nil then opts.isClient else client ~= nil
	local isServer = if opts.isServer ~= nil then opts.isServer else not isClient
	local isStudio = opts.isStudio == true
	local isStrict = opts.strict ~= false
	local signalBehavior: SignalBehavior = opts.signalBehavior or "Deferred"
	assert(
		signalBehavior == "Deferred" or signalBehavior == "Immediate",
		`sert.env: invalid signalBehavior "{tostring(signalBehavior)}" (expected "Deferred" or "Immediate")`
	)
	local frameRate = opts.frameRate or 60
	assert(frameRate > 0, "sert.env: frameRate must be positive")
	local frameDt = 1 / frameRate
	local dt: any = mergeDatatypes(opts.datatypes)
	local Enum, customTypeof = dt.Enum, dt.typeof
	local defaultViewport = opts.viewport or dt.Vector2.new(1920, 1080)
	local initialTeleportData = if opts.teleportData ~= nil
		then util.copy(opts.teleportData)
		elseif client ~= nil and client.teleportData ~= nil then util.copy(client.teleportData)
		else nil

	local env: any = {
		world = world,
		server = server,
		client = client,
		isServer = isServer,
		isClient = isClient,
		isStudio = isStudio,
		strict = isStrict,
		signalBehavior = signalBehavior,
		frameRate = frameRate,
		viewport = defaultViewport,
		_viewport = opts.viewport,
		_layerCollectors = setmetatable({}, { __mode = "k" }),
		_layerCollectorList = {},
		datatypes = dt,
		_loaded = {},
		_loading = {},
		_mountedByPath = {},
		_tags = {},
		_tagAddedSignals = {},
		_tagRemovedSignals = {},
		_mirrorOf = setmetatable({}, { __mode = "k" }),
		_sourceOf = setmetatable({}, { __mode = "k" }),
		_localTeleportData = initialTeleportData,
		teleports = {},
		badges = {},
		groups = {},
		friends = {},
		bans = {},
		kicks = {},
		userNames = {},
		marketplace = { gamePasses = {}, assets = {}, bundles = {}, subscriptions = {}, products = {} },
		textFilter = nil,
		httpHandler = nil,
		peerBridge = opts.peerBridge,
		remoteHandler = opts.remoteHandler,
	}

	local sched, envOwner, getClock, getUnixTime, threadedSignal, taskOps =
		buildSchedulerAndSignals(env, host, world, peer, outside, frameDt, signalBehavior)

	local function trackCreated(inst: any): any
		if inst ~= nil and inst:IsA("LayerCollector") and not env._layerCollectors[inst] then
			env._layerCollectors[inst] = true
			table.insert(env._layerCollectorList, inst)
		end
		return inst
	end

	local function createInstance(first: any, second: any?, third: any?, fourth: any?): any
		if first == env then return trackCreated(InstanceDouble.createInstance(env, second, third, fourth ~= false)) end
		return trackCreated(InstanceDouble.createInstance(env, first, second, third ~= false))
	end
	env.createInstance = createInstance

	local InstanceLib = table.freeze({
		new = function(className: string, parent: any?): any
			return trackCreated(InstanceDouble.createInstance(env, className, parent, false))
		end,
		fromExisting = InstanceDouble.fromExisting,
	})
	env.Instance = InstanceLib

	local services: { [string]: any } = {}
	local serviceBuilders: { [string]: () -> any } = {}
	env._services = services
	env.services = services

	local gameInst = createInstance("DataModel", nil, true)
	rawset(gameInst, "_isService", true)
	gameInst.Name = "Game"
	local gProps = gameInst._props
	gProps.PlaceId = opts.placeId or (if world then world.placeId else 1)
	gProps.GameId = opts.gameId or 1
	gProps.CreatorId = opts.creatorId or 1
	gProps.CreatorType = opts.creatorType or Enum.CreatorType.User
	gProps.JobId = opts.jobId or (if server then server.jobId else "00000000-0000-4000-8000-000000000001")
	gProps.PrivateServerId = if server ~= nil and type(server.privateServerId) == "string"
		then server.privateServerId
		else ""
	gProps.PrivateServerOwnerId = 0
	env.game = gameInst

	local ctx: any = {
		opts = opts,
		host = host,
		world = world,
		server = server,
		client = client,
		peer = peer,
		isClient = isClient,
		isServer = isServer,
		isStudio = isStudio,
		isStrict = isStrict,
		standalone = sched ~= nil or outside,
		dt = dt,
		Enum = Enum,
		typeof = customTypeof,
		getClock = getClock,
		getUnixTime = getUnixTime,
		createInstance = createInstance,
		upgradePlayer = InstanceDouble.upgradePlayer,
		ensureRemoteBound = InstanceDouble.ensureRemoteBound,
		services = services,
		serviceBuilders = serviceBuilders,
		gameInst = gameInst,
		renderSteps = {},
		frameCallbacks = {},
		serviceConnections = {},
		signal = function(): any return env:signal() end,
		threadedSignal = threadedSignal,
		task = taskOps,
		inputState = nil,
	}
	env._ctx = ctx

	mountCoreServices(env, ctx, gProps, sched, outside, envOwner)
	Replication(env, ctx)
	attachEnvHelpers(env, ctx)
	buildEnvGlobals(env, ctx, InstanceLib)
	installLoader(env, ctx)

	function env.bind<F>(_self: any, fn: F): F
		assert(type(fn) == "function", "env:bind expects a function")
		if setfenv ~= nil then (setfenv :: any)(fn, env.globals) end
		return (fn :: any) :: F
	end

	function env.run<T...>(_self: any, fn: (T...) -> ...any, ...: T...): ...any
		assert(type(fn) == "function", "env:run expects a function")
		if setfenv ~= nil then (setfenv :: any)(fn, env.globals) end
		return fn(...)
	end

	if server ~= nil and client == nil then
		server._env = env
		for _, cliEnv in ctx.getAttachedClientEnvs() do
			env:_syncClient(cliEnv)
		end
	elseif client ~= nil then
		client._env = env
		local srv = server or client.server
		if srv ~= nil and srv._env ~= nil then srv._env:_syncClient(env) end
	end

	if world == nil then
		env._clearYieldDriver = function()
			if registry.getYieldDriver() == envYieldDriver then registry.setYieldDriver(nil) end
		end
		registry.setActiveEnv(env)
		registry.setYieldDriver(envYieldDriver)
	end
	return env :: Env
end

Env.active = registry.activeEnv :: () -> Env?
Env._beginTest = registry.beginEnvScope

local exportedEnv: any = nil

local robloxServiceCache: { [string]: any } = {}
local robloxServicesProxy: any = setmetatable({}, {
	__index = function(_: any, name: any): any
		if not IS_ROBLOX or type(name) ~= "string" then return nil end
		local cached = rawget(robloxServiceCache, name)
		if cached ~= nil then return cached end
		local ok, svc = pcall(game.GetService, game, name)
		if ok and svc ~= nil then
			rawset(robloxServiceCache, name, svc)
			return svc
		end
		return nil
	end,
})

function Env.getService(first: any, second: any?): any
	local name: string = if first == Env or first == exportedEnv then second else first
	local active = registry.activeEnv()
	if active ~= nil then return active:getService(name) end
	if IS_ROBLOX then
		local cached = rawget(robloxServiceCache, name)
		if cached ~= nil then return cached end
		local svc = game:GetService(name)
		rawset(robloxServiceCache, name, svc)
		return svc
	end
	error("sert.env: no active Env (create one with sert.env.new())", 2)
end

local STATELESS_DATATYPES: { [string]: boolean } = { DateTime = true, Enum = true }
for _, name in DATATYPE_GLOBALS do
	STATELESS_DATATYPES[name] = true
end

exportedEnv = setmetatable({
	new = Env.new,
	active = Env.active,
	getService = Env.getService,
	_beginTest = Env._beginTest,
	hooks = Env.hooks,
	_sharedG = Env._sharedG,
	isRoblox = IS_ROBLOX,
	typeof = Datatypes.typeof,
	type = Datatypes.type,
}, {
	__index = function(_: any, key: any): any
		if type(key) ~= "string" then return nil end
		local active = registry.activeEnv()
		if active ~= nil then
			local v = (active :: any)[key]
			if v ~= nil then return v end
		end
		if IS_ROBLOX then
			if key == "game" or key == "Game" then
				return game
			elseif key == "workspace" or key == "Workspace" then
				return workspace
			elseif key == "Instance" then
				return Instance
			elseif key == "task" then
				return task
			elseif key == "services" then
				return robloxServicesProxy
			elseif ROBLOX_DATATYPES[key] ~= nil then
				return ROBLOX_DATATYPES[key]
			end
		end
		if STATELESS_DATATYPES[key] then return Datatypes[key] end
		return nil
	end,
})

return exportedEnv :: EnvNamespace & { _beginTest: () -> () -> (), _sharedG: { [any]: any } }
