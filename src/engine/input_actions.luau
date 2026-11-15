--!strict
-- Modern Roblox Input Action System (`InputContext`, `InputAction`, `InputBinding`): priority/sink evaluation,
-- typed state aggregation (`Bool`, `Direction1D`, `Direction2D`, `Direction3D`, `ViewportPosition`), and signals.

local InputActions = {}

local ACTION_STATES: { [any]: any } = setmetatable({}, { __mode = "k" }) :: any

local DIRECTION_DEFAULT = {
	Bool = false,
	Direction1D = 0,
}

local function dtOf(inst: any): any?
	local env = rawget(inst, "_env")
	return if env ~= nil then env.datatypes else nil
end

local function actionTypeName(action: any): string
	local t = action._props.Type
	if t ~= nil and t.Name ~= nil then return tostring(t.Name) end
	return "Bool"
end

local function defaultStateFor(typeName: string, dt: any?): any
	if typeName == "Bool" then return false end
	if typeName == "Direction1D" then return 0 end
	if dt ~= nil then
		if typeName == "Direction3D" then return dt.Vector3.zero end
		if typeName == "Direction2D" or typeName == "ViewportPosition" then return dt.Vector2.zero end
	end
	return DIRECTION_DEFAULT[typeName]
end

local function coerceStateForType(typeName: string, value: any, dt: any?): any
	if typeName == "Bool" then
		if type(value) == "boolean" then return value end
		if type(value) == "number" then return value ~= 0 end
		return value ~= nil
	elseif typeName == "Direction1D" then
		if type(value) == "number" then return value end
		if type(value) == "boolean" then return if value then 1 else 0 end
		return 0
	elseif typeName == "Direction2D" or typeName == "ViewportPosition" then
		if dt ~= nil and dt.typeof(value) == "Vector2" then return value end
		if type(value) == "number" and dt ~= nil then return dt.Vector2.new(value, 0) end
		if type(value) == "boolean" and dt ~= nil then return dt.Vector2.new(if value then 1 else 0, 0) end
		return defaultStateFor(typeName, dt)
	elseif typeName == "Direction3D" then
		if dt ~= nil and dt.typeof(value) == "Vector3" then return value end
		return defaultStateFor(typeName, dt)
	end
	return value
end

local function statesEqual(a: any, b: any): boolean return a == b end

local function applyActionState(action: any, rawState: any, fireSignals: boolean): boolean
	local dt = dtOf(action)
	local typeName = actionTypeName(action)
	local prev = ACTION_STATES[action]
	if prev == nil then prev = defaultStateFor(typeName, dt) end
	local nextState = coerceStateForType(typeName, rawState, dt)
	if statesEqual(prev, nextState) then return false end
	ACTION_STATES[action] = nextState
	if fireSignals then
		if typeName == "Bool" then
			if nextState == true and prev == false then
				action.Pressed:Fire()
			elseif nextState == false and prev == true then
				action.Released:Fire()
			end
		end
		action.StateChanged:Fire(nextState)
	end
	return true
end

local function actionIsEnabled(action: any): boolean
	if action._props.Enabled == false then return false end
	local parent: any = rawget(action, "_parent")
	if parent ~= nil and parent:IsA("InputContext") and parent._props.Enabled == false then return false end
	return true
end

local function applyBindingScale(typeName: string, binding: any, value: any, dt: any?): any
	local bProps = binding._props
	local s = if type(bProps.Scale) == "number" then bProps.Scale else 1
	if typeName == "Direction1D" and type(value) == "number" then
		return value * s
	elseif typeName == "Direction2D" and dt ~= nil and dt.typeof(value) == "Vector2" then
		if bProps.ClampMagnitudeToOne ~= false and value.Magnitude > 1 then value = value.Unit end
		local v2s = bProps.Vector2Scale
		local sx = s * (if v2s ~= nil then v2s.X else 1)
		local sy = s * (if v2s ~= nil then v2s.Y else 1)
		return dt.Vector2.new(value.X * sx, value.Y * sy)
	elseif typeName == "Direction3D" and dt ~= nil and dt.typeof(value) == "Vector3" then
		if bProps.ClampMagnitudeToOne ~= false and value.Magnitude > 1 then value = value.Unit end
		local v3s = bProps.Vector3Scale
		local sx = s * (if v3s ~= nil then v3s.X else 1)
		local sy = s * (if v3s ~= nil then v3s.Y else 1)
		local sz = s * (if v3s ~= nil then v3s.Z else 1)
		return dt.Vector3.new(value.X * sx, value.Y * sy, value.Z * sz)
	end
	return value
end

InputActions.InputActionMethods = {
	GetState = function(self: any): any
		local cur = ACTION_STATES[self]
		if cur ~= nil then return cur end
		return defaultStateFor(actionTypeName(self), dtOf(self))
	end,
	Fire = function(self: any, state: any)
		if not actionIsEnabled(self) then return end
		applyActionState(self, state, true)
	end,
}

InputActions.InputBindingMethods = {
	Fire = function(self: any, state: any)
		local parent = rawget(self, "_parent")
		if parent == nil or not parent:IsA("InputAction") or not actionIsEnabled(parent) then return end
		local dt = dtOf(parent)
		local scaled =
			applyBindingScale(actionTypeName(parent), self, coerceStateForType(actionTypeName(parent), state, dt), dt)
		applyActionState(parent, scaled, true)
	end,
}

local function keyIsNone(kc: any): boolean return kc == nil or kc.Name == "None" or kc.Name == "Unknown" end

local function buildHeldSnapshot(env: any, ctx: any): ({ [any]: boolean }, { [any]: boolean }, any)
	local Enum = ctx.Enum
	local state = ctx.inputState
	local heldKeys: { [any]: boolean } = {}
	if state ~= nil then
		for _, io in state.keys do
			local kc = io.KeyCode
			if kc ~= nil then heldKeys[kc] = true end
		end
		for _, io in state.buttons do
			local ut = io.UserInputType
			if ut == Enum.UserInputType.MouseButton1 then
				heldKeys[Enum.KeyCode.MouseLeftButton] = true
			elseif ut == Enum.UserInputType.MouseButton2 then
				heldKeys[Enum.KeyCode.MouseRightButton] = true
			elseif ut == Enum.UserInputType.MouseButton3 then
				heldKeys[Enum.KeyCode.MouseMiddleButton] = true
			end
		end
	end
	local heldButtons: { [any]: boolean } = rawget(env, "_heldUiButtons") or {}
	return heldKeys, heldButtons, if state ~= nil then state.mouse else nil
end

local function evaluateBinding(
	binding: any,
	typeName: string,
	heldKeys: { [any]: boolean },
	heldButtons: { [any]: boolean },
	sunkKeys: { [any]: boolean },
	sunkButtons: { [any]: boolean },
	mousePos: any,
	dt: any
): any
	local b = binding._props
	local function keyDown(kc: any): boolean return not keyIsNone(kc) and heldKeys[kc] == true and not sunkKeys[kc] end
	local function btnDown(btn: any): boolean return btn ~= nil and heldButtons[btn] == true and not sunkButtons[btn] end

	if not keyIsNone(b.PrimaryModifier) and not keyDown(b.PrimaryModifier) then return defaultStateFor(typeName, dt) end
	if not keyIsNone(b.SecondaryModifier) and not keyDown(b.SecondaryModifier) then
		return defaultStateFor(typeName, dt)
	end
	if b.UIModifier ~= nil and not btnDown(b.UIModifier) then return defaultStateFor(typeName, dt) end

	if typeName == "Bool" then
		return keyDown(b.KeyCode) or btnDown(b.UIButton)
	elseif typeName == "Direction1D" then
		local v = 0
		if keyDown(b.KeyCode) or keyDown(b.Up) or btnDown(b.UIButton) then
			v += 1
		end
		if keyDown(b.Down) then
			v -= 1
		end
		return applyBindingScale(typeName, binding, v, dt)
	elseif typeName == "Direction2D" then
		local dx, dy = 0, 0
		if keyDown(b.Right) then
			dx += 1
		end
		if keyDown(b.Left) then
			dx -= 1
		end
		if keyDown(b.Up) then
			dy += 1
		end
		if keyDown(b.Down) then
			dy -= 1
		end
		return applyBindingScale(typeName, binding, dt.Vector2.new(dx, dy), dt)
	elseif typeName == "Direction3D" then
		local dx, dy, dz = 0, 0, 0
		if keyDown(b.Right) then
			dx += 1
		end
		if keyDown(b.Left) then
			dx -= 1
		end
		if keyDown(b.Up) then
			dy += 1
		end
		if keyDown(b.Down) then
			dy -= 1
		end
		if keyDown(b.Forward) then
			dz -= 1
		end
		if keyDown(b.Backward) then
			dz += 1
		end
		return applyBindingScale(typeName, binding, dt.Vector3.new(dx, dy, dz), dt)
	elseif typeName == "ViewportPosition" then
		local kc = b.KeyCode
		local isPointer = (
			kc ~= nil and (kc.Name == "MousePosition" or kc.Name == "TouchPosition" or kc.Name == "Touch")
		) or b.UIButton ~= nil
		if isPointer and mousePos ~= nil then return mousePos end
		return dt.Vector2.zero
	end
	return defaultStateFor(typeName, dt)
end

local function recordBoundInputs(binding: any, sinkKeys: { [any]: boolean }, sinkButtons: { [any]: boolean })
	local b = binding._props
	for _, propName in { "KeyCode", "Up", "Down", "Left", "Right", "Forward", "Backward" } do
		local kc = b[propName]
		if not keyIsNone(kc) then sinkKeys[kc] = true end
	end
	if b.UIButton ~= nil then sinkButtons[b.UIButton] = true end
end

local function evaluateAction(
	action: any,
	contextEnabled: boolean,
	heldKeys: { [any]: boolean },
	heldButtons: { [any]: boolean },
	sunkKeys: { [any]: boolean },
	sunkButtons: { [any]: boolean },
	sinkActive: boolean,
	nextSunkKeys: { [any]: boolean },
	nextSunkButtons: { [any]: boolean },
	mousePos: any,
	dt: any
)
	local typeName = actionTypeName(action)
	if not contextEnabled or action._props.Enabled == false then
		applyActionState(action, defaultStateFor(typeName, dt), true)
		return
	end

	local bindings: { any } = {}
	for _, child in action:GetChildren() do
		if child:IsA("InputBinding") then table.insert(bindings, child) end
	end

	if #bindings == 0 then return end

	local combined: any = defaultStateFor(typeName, dt)
	for _, binding in bindings do
		local contrib = evaluateBinding(binding, typeName, heldKeys, heldButtons, sunkKeys, sunkButtons, mousePos, dt)
		if typeName == "Bool" then
			if contrib == true then combined = true end
		elseif typeName == "Direction1D" or typeName == "Direction2D" or typeName == "Direction3D" then
			combined = combined + contrib
		elseif typeName == "ViewportPosition" then
			if contrib ~= nil and contrib ~= dt.Vector2.zero then combined = contrib end
		end
		if sinkActive then recordBoundInputs(binding, nextSunkKeys, nextSunkButtons) end
	end

	applyActionState(action, combined, true)
end

--- Evaluates all `InputContext`s under `env.game` in descending `Priority` order (honoring `Enabled` and `Sink`).
function InputActions.evaluate(env: any)
	if env == nil or rawget(env, "_destroyed") == true then return end
	local ctx = rawget(env, "_ctx")
	local gameInst = env.game
	if ctx == nil or gameInst == nil then return end

	local contexts: { any } = {}
	for _, inst in gameInst:GetDescendants() do
		if inst:IsA("InputContext") then table.insert(contexts, inst) end
	end
	if #contexts == 0 then return end

	table.sort(contexts, function(a: any, b: any): boolean
		local pa = if type(a._props.Priority) == "number" then a._props.Priority else 1000
		local pb = if type(b._props.Priority) == "number" then b._props.Priority else 1000
		if pa ~= pb then return pa > pb end
		return (rawget(a, "_id") or 0) < (rawget(b, "_id") or 0)
	end)

	local heldKeys, heldButtons, mousePos = buildHeldSnapshot(env, ctx)
	local dt: any = (ctx :: any).dt
	local sunkKeys: { [any]: boolean } = {}
	local sunkButtons: { [any]: boolean } = {}

	for _, ic in contexts do
		local enabled = ic._props.Enabled ~= false
		local sink = enabled and ic._props.Sink == true
		local nextSunkKeys: { [any]: boolean } = {}
		local nextSunkButtons: { [any]: boolean } = {}
		for _, child in ic:GetChildren() do
			if child:IsA("InputAction") then
				evaluateAction(
					child,
					enabled,
					heldKeys,
					heldButtons,
					sunkKeys,
					sunkButtons,
					sink,
					nextSunkKeys,
					nextSunkButtons,
					mousePos,
					dt
				)
			end
		end
		if sink then
			for k in nextSunkKeys do
				sunkKeys[k] = true
			end
			for btn in nextSunkButtons do
				sunkButtons[btn] = true
			end
		end
	end
end

return InputActions
