--!strict
-- Pillar 6 end-to-end conformance specs verifying parity between headless `sert.env` (`[portable]`)
-- and live Roblox Studio (`[roblox]` / `[client]`) across spatial queries, InputAction, SharedTable/Actor,
-- Audio Wire graphs, UIPageLayout/RichText, and snapshot bridge emission.

local isStudio = (game :: any) ~= nil
local req: any = require
local function loadModule(alias: string, rel: string): any
	local ok, mod = pcall(req, alias)
	if ok and mod ~= nil then return mod end
	return req(rel)
end

local sert = if isStudio
	then require(game:GetService("ReplicatedStorage").sert)
	else loadModule("@sert", "../../../../src") :: typeof(require(game:GetService("ReplicatedStorage").sert))
local registry = if isStudio
	then require(game:GetService("ReplicatedStorage").sert.core.registry)
	else loadModule(
			"@sert/core/registry",
			"../../../../src/core/registry"
		) :: typeof(require(game:GetService("ReplicatedStorage").sert.core.registry))

local conformance = sert.roblox.conformance

local function makeAnchoredPart(root: Instance, ctx: any, name: string, size: any, cf: any): any
	local part: any = ctx.Instance.new("Part")
	part.Name = name
	part.Size = size
	part.CFrame = cf
	part.Anchored = true
	part.Parent = root
	return part
end

local function makeRaycastInclude(ctx: any, instances: { any }, collisionGroup: string?): any
	local params: any = ctx.RaycastParams.new()
	params.FilterType = ctx.Enum.RaycastFilterType.Include
	params.FilterDescendantsInstances = instances
	if collisionGroup ~= nil then params.CollisionGroup = collisionGroup end
	return params
end

local function makeOverlapInclude(ctx: any, instances: { any }, collisionGroup: string?): any
	local params: any = ctx.OverlapParams.new()
	params.FilterType = ctx.Enum.RaycastFilterType.Include
	params.FilterDescendantsInstances = instances
	if collisionGroup ~= nil then params.CollisionGroup = collisionGroup end
	return params
end

local function namesOf(instances: { any }): { string }
	local out: { string } = {}
	for _, inst in instances do
		table.insert(out, inst.Name)
	end
	table.sort(out)
	return out
end

local function runIsolated(register: () -> (), opts: { [string]: any }?): any
	local sub = registry.newState()
	registry.isolateDepth += 1
	local ok, res = pcall(function(): any
		return registry.withState(sub, function(): any
			register()
			local merged: any = if opts ~= nil then table.clone(opts) else {}
			if merged.quiet == nil and merged.silent == nil then merged.quiet = true end
			if merged.raise == nil then merged.raise = false end
			return sert.run(merged)
		end)
	end)
	registry.isolateDepth -= 1
	if not ok then error(res, 0) end
	return res
end

conformance(
	"3D spatial queries (Raycast, Blockcast, Spherecast, Shapecast, overlap, CollisionGroup)",
	function(root: Instance, ctx)
		local ws: any = ctx.workspace
		local cf: any = ctx.CFrame
		local v3: any = ctx.Vector3

		-- 1) Rotated OBB Raycast: hit rotated bar, miss its AABB-only corner, hit tilted slope normal.
		local rotatedBar =
			makeAnchoredPart(root, ctx, "RotatedBar", v3.new(8, 2, 2), cf.new(0, 10, 0) * cf.Angles(0, math.rad(45), 0))
		local barParams = makeRaycastInclude(ctx, { rotatedBar })
		local barHit = ws:Raycast(v3.new(2, 14, -2), v3.new(0, -10, 0), barParams)
		sert.ok(barHit ~= nil, "ray on rotated OBB diagonal should hit")
		sert.eq(barHit.Instance, rotatedBar)
		sert.near(barHit.Distance, 3, 1e-2)
		sert.near(barHit.Normal, v3.new(0, 1, 0), 1e-2)

		local aabbOnlyMiss = ws:Raycast(v3.new(3.2, 14, 0), v3.new(0, -10, 0), barParams)
		sert.eq(aabbOnlyMiss, nil)

		local slopeAngle = math.rad(30)
		local slope =
			makeAnchoredPart(root, ctx, "TiltedSlope", v3.new(6, 2, 4), cf.new(20, 10, 0) * cf.Angles(0, 0, slopeAngle))
		local slopeHit = ws:Raycast(v3.new(20, 16, 0), v3.new(0, -12, 0), makeRaycastInclude(ctx, { slope }))
		sert.ok(slopeHit ~= nil, "tilted slope raycast should hit")
		sert.eq(slopeHit.Instance, slope)
		sert.near(slopeHit.Normal, v3.new(-math.sin(slopeAngle), math.cos(slopeAngle), 0), 1e-2)
		sert.near(slopeHit.Distance, 6 - 1 / math.cos(slopeAngle), 1e-2)

		-- 2) Blockcast, Spherecast, and Shapecast against a target pad.
		local pad = makeAnchoredPart(root, ctx, "TargetPad", v3.new(6, 2, 6), cf.new(0, 10, 20))
		local padParams = makeRaycastInclude(ctx, { pad })

		local blockHit = ws:Blockcast(
			cf.new(0, 20, 20) * cf.Angles(0, math.rad(30), 0),
			v3.new(2, 2, 2),
			v3.new(0, -15, 0),
			padParams
		)
		sert.ok(blockHit ~= nil, "Blockcast should hit TargetPad")
		sert.eq(blockHit.Instance, pad)
		sert.near(blockHit.Distance, 8, 1e-2)
		sert.near(blockHit.Normal, v3.new(0, 1, 0), 1e-2)

		local sphereHit = ws:Spherecast(v3.new(0, 20, 20), 1.5, v3.new(0, -15, 0), padParams)
		sert.ok(sphereHit ~= nil, "Spherecast should hit TargetPad")
		sert.eq(sphereHit.Instance, pad)
		sert.near(sphereHit.Distance, 7.5, 1e-2)
		sert.near(sphereHit.Normal, v3.new(0, 1, 0), 1e-2)

		local sphereMiss = ws:Spherecast(v3.new(5, 20, 20), 1.5, v3.new(0, -15, 0), padParams)
		sert.eq(sphereMiss, nil)

		local boxProbe = makeAnchoredPart(root, ctx, "BoxProbe", v3.new(2, 2, 2), cf.new(0, 18, 20))
		local boxSweep = ws:Shapecast(boxProbe, v3.new(0, -12, 0), padParams)
		sert.ok(boxSweep ~= nil, "Box Shapecast should hit TargetPad")
		sert.eq(boxSweep.Instance, pad)
		sert.near(boxSweep.Distance, 6, 1e-2)
		sert.near(boxSweep.Normal, v3.new(0, 1, 0), 1e-2)

		local ballProbe = makeAnchoredPart(root, ctx, "BallProbe", v3.new(2, 2, 2), cf.new(0, 18, 20))
		ballProbe.Shape = ctx.Enum.PartType.Ball
		local ballSweep = ws:Shapecast(ballProbe, v3.new(0, -12, 0), padParams)
		sert.ok(ballSweep ~= nil, "Ball Shapecast should hit TargetPad")
		sert.eq(ballSweep.Instance, pad)
		sert.near(ballSweep.Distance, 6, 1e-2)

		-- 3) GetPartBoundsInBox and GetPartsInPart OBB overlap precision + MaxParts.
		local insideOverlap = makeAnchoredPart(root, ctx, "InsideOBB", v3.new(1, 1, 1), cf.new(42, 10, -2))
		local aabbOnlyOverlap = makeAnchoredPart(root, ctx, "AABBOnly", v3.new(0.4, 0.4, 0.4), cf.new(43.1, 10, 0))
		local queryCf = cf.new(40, 10, 0) * cf.Angles(0, math.rad(45), 0)
		local querySize = v3.new(8, 2, 2)
		local ovParams = makeOverlapInclude(ctx, { insideOverlap, aabbOnlyOverlap })

		local boxBoundsHits = ws:GetPartBoundsInBox(queryCf, querySize, ovParams)
		sert.eq(namesOf(boxBoundsHits), { "InsideOBB" })

		local overlapProbe = makeAnchoredPart(root, ctx, "OverlapProbe", querySize, queryCf)
		local inPartHits = ws:GetPartsInPart(overlapProbe, ovParams)
		sert.eq(namesOf(inPartHits), { "InsideOBB" })

		local secondInside = makeAnchoredPart(root, ctx, "SecondInside", v3.new(1, 1, 1), cf.new(39, 10, 1))
		local cappedParams = makeOverlapInclude(ctx, { insideOverlap, secondInside })
		cappedParams.MaxParts = 1
		sert.eq(#ws:GetPartBoundsInBox(queryCf, querySize, cappedParams), 1)

		-- 4) PhysicsService CollisionGroup filtering for Raycast and Overlap queries.
		local physics: any = ctx.getService("PhysicsService")
		local groupA = "SertParityGroupA"
		local groupB = "SertParityGroupB"
		pcall(function() physics:UnregisterCollisionGroup(groupA) end)
		pcall(function() physics:UnregisterCollisionGroup(groupB) end)

		local okPhys, physErr = pcall(function()
			physics:RegisterCollisionGroup(groupA)
			physics:RegisterCollisionGroup(groupB)
			physics:CollisionGroupSetCollidable(groupA, groupB, false)
			physics:CollisionGroupSetCollidable(groupA, groupA, true)

			sert.eq(physics:CollisionGroupsAreCollidable(groupA, groupB), false)
			sert.eq(physics:CollisionGroupsAreCollidable(groupA, groupA), true)

			local partB = makeAnchoredPart(root, ctx, "GroupBPart", v3.new(4, 2, 4), cf.new(60, 14, 0))
			partB.CollisionGroup = groupB
			local partA = makeAnchoredPart(root, ctx, "GroupAPart", v3.new(4, 2, 4), cf.new(60, 6, 0))
			partA.CollisionGroup = groupA

			local grpRayParams = makeRaycastInclude(ctx, { partA, partB }, groupA)
			local grpHit = ws:Raycast(v3.new(60, 20, 0), v3.new(0, -20, 0), grpRayParams)
			sert.ok(grpHit ~= nil, "CollisionGroup raycast should skip GroupBPart and hit GroupAPart")
			sert.eq(grpHit.Instance, partA)

			local grpOverlapParams = makeOverlapInclude(ctx, { partA, partB }, groupA)
			local grpBounds = ws:GetPartBoundsInBox(cf.new(60, 10, 0), v3.new(10, 20, 10), grpOverlapParams)
			sert.eq(namesOf(grpBounds), { "GroupAPart" })
		end)

		pcall(function() physics:UnregisterCollisionGroup(groupA) end)
		pcall(function() physics:UnregisterCollisionGroup(groupB) end)
		if not okPhys then error(physErr, 0) end
	end
)

local inputOpts = { target = "client" :: "client", container = "PlayerGui" :: "PlayerGui" }
conformance(
	"InputContext, InputAction (Bool/Direction1D/Direction2D), InputBinding, Fire, Priority/Sink",
	function(root: Instance, ctx)
		local highCtx: any = ctx.Instance.new("InputContext")
		highCtx.Name = "HighPriorityContext"
		highCtx.Priority = 200
		highCtx.Sink = true
		highCtx.Enabled = true
		highCtx.Parent = root

		local lowCtx: any = ctx.Instance.new("InputContext")
		lowCtx.Name = "LowPriorityContext"
		lowCtx.Priority = 100
		lowCtx.Sink = false
		lowCtx.Enabled = true
		lowCtx.Parent = root

		local boolAction: any = ctx.Instance.new("InputAction")
		boolAction.Name = "JumpAction"
		boolAction.Type = ctx.Enum.InputActionType.Bool
		boolAction.Parent = highCtx

		local boolBinding: any = ctx.Instance.new("InputBinding")
		boolBinding.KeyCode = ctx.Enum.KeyCode.E
		boolBinding.Parent = boolAction

		local scriptableBinding: any = ctx.Instance.new("InputBinding")
		scriptableBinding.Type = ctx.Enum.InputBindingType.Scriptable
		scriptableBinding.Parent = boolAction

		local lowAction: any = ctx.Instance.new("InputAction")
		lowAction.Name = "LowInteractAction"
		lowAction.Type = ctx.Enum.InputActionType.Bool
		lowAction.Parent = lowCtx

		local lowBinding: any = ctx.Instance.new("InputBinding")
		lowBinding.KeyCode = ctx.Enum.KeyCode.E
		lowBinding.Parent = lowAction

		local dir1DAction: any = ctx.Instance.new("InputAction")
		dir1DAction.Name = "ThrottleAction"
		dir1DAction.Type = ctx.Enum.InputActionType.Direction1D
		dir1DAction.Parent = highCtx

		local dir1DBinding: any = ctx.Instance.new("InputBinding")
		dir1DBinding.Up = ctx.Enum.KeyCode.W
		dir1DBinding.Down = ctx.Enum.KeyCode.S
		dir1DBinding.Scale = 2
		dir1DBinding.Parent = dir1DAction

		local dir2DAction: any = ctx.Instance.new("InputAction")
		dir2DAction.Name = "MoveAction"
		dir2DAction.Type = ctx.Enum.InputActionType.Direction2D
		dir2DAction.Parent = highCtx

		local dir2DBinding: any = ctx.Instance.new("InputBinding")
		dir2DBinding.Up = ctx.Enum.KeyCode.W
		dir2DBinding.Down = ctx.Enum.KeyCode.S
		dir2DBinding.Left = ctx.Enum.KeyCode.A
		dir2DBinding.Right = ctx.Enum.KeyCode.D
		dir2DBinding.Parent = dir2DAction

		local pressedCount = 0
		local releasedCount = 0
		local boolStates: { any } = {}
		local c1 = boolAction.Pressed:Connect(function()
			pressedCount += 1
		end)
		local c2 = boolAction.Released:Connect(function()
			releasedCount += 1
		end)
		local c3 = boolAction.StateChanged:Connect(function(v: any) table.insert(boolStates, v) end)

		local dir1DEvents: { number } = {}
		local c4 = dir1DAction.StateChanged:Connect(function(v: number) table.insert(dir1DEvents, v) end)

		local dir2DEvents: { any } = {}
		local c5 = dir2DAction.StateChanged:Connect(function(v: any) table.insert(dir2DEvents, v) end)

		sert.eq(boolAction:GetState(), false)
		boolAction:Fire(true)
		ctx.step(1 / 60)
		sert.eq(boolAction:GetState(), true)
		sert.eq(pressedCount, 1)
		sert.eq(releasedCount, 0)

		boolAction:Fire(false)
		ctx.step(1 / 60)
		sert.eq(boolAction:GetState(), false)
		sert.eq(releasedCount, 1)
		sert.eq(boolStates, { true, false })

		scriptableBinding:Fire(true)
		ctx.step(1 / 60)
		sert.eq(boolAction:GetState(), true)
		scriptableBinding:Fire(false)
		ctx.step(1 / 60)
		sert.eq(boolAction:GetState(), false)

		dir1DAction:Fire(0.75)
		ctx.step(1 / 60)
		sert.near(dir1DAction:GetState(), 0.75, 1e-4)
		sert.eq(#dir1DEvents, 1)

		local moveVec = ctx.Vector2.new(0.5, -1)
		dir2DAction:Fire(moveVec)
		ctx.step(1 / 60)
		sert.near(dir2DAction:GetState(), moveVec, 1e-4)
		sert.eq(#dir2DEvents, 1)

		-- Priority + Sink sanity: verify properties roundtrip on InputContext.
		sert.eq(highCtx.Priority, 200)
		sert.eq(highCtx.Sink, true)
		sert.eq(lowCtx.Priority, 100)
		sert.eq(lowCtx.Sink, false)

		c1:Disconnect()
		c2:Disconnect()
		c3:Disconnect()
		c4:Disconnect()
		c5:Disconnect()
	end,
	inputOpts
)

conformance("SharedTable, SharedTableRegistry, Actor, and Instance:GetActor conformance", function(root: Instance, ctx)
	local ST: any = ctx.SharedTable
	local st = ST.new({ hp = 10, name = "knight" })
	sert.eq(ST.size(st), 2)
	sert.eq(st.hp, 10)

	local prevHp = ST.increment(st, "hp", 5)
	sert.eq(prevHp, 10)
	sert.eq(st.hp, 15)

	ST.update(st, "hp", function(cur: number?): number return (cur or 0) * 2 end)
	sert.eq(st.hp, 30)

	local frozen = ST.cloneAndFreeze(st, true)
	sert.eq(ST.isFrozen(frozen), true)
	sert.eq(frozen.hp, 30)
	sert.eq(ST.size(frozen), 2)
	sert.throws(function() (frozen :: any).hp = 99 end)

	ST.clear(st)
	sert.eq(ST.size(st), 0)

	local reg: any = ctx.getService("SharedTableRegistry")
	local regKey = "SertEngineParitySharedTable"
	local regTable = ST.new({ epoch = 7 })
	local okReg, regErr = pcall(function()
		reg:SetSharedTable(regKey, regTable)
		local fetched = reg:GetSharedTable(regKey)
		sert.ok(fetched ~= nil, "SharedTableRegistry should return registered SharedTable")
		sert.eq(fetched.epoch, 7)
		ST.increment(fetched, "epoch", 3)
		sert.eq(regTable.epoch, 10)
	end)
	pcall(function() reg:SetSharedTable(regKey, nil) end)
	if not okReg then error(regErr, 0) end

	local actor: any = ctx.Instance.new("Actor")
	actor.Name = "ParityActor"
	actor.Parent = root

	local childPart: any = ctx.Instance.new("Part")
	childPart.Name = "ActorChild"
	childPart.Anchored = true
	childPart.Parent = actor

	local nestedFolder: any = ctx.Instance.new("Folder")
	nestedFolder.Name = "Nested"
	nestedFolder.Parent = actor
	local grandchildPart: any = ctx.Instance.new("Part")
	grandchildPart.Name = "ActorGrandchild"
	grandchildPart.Anchored = true
	grandchildPart.Parent = nestedFolder

	local outsidePart: any = ctx.Instance.new("Part")
	outsidePart.Name = "OutsidePart"
	outsidePart.Anchored = true
	outsidePart.Parent = root

	sert.eq(childPart:GetActor(), actor)
	sert.eq(grandchildPart:GetActor(), actor)
	sert.eq(outsidePart:GetActor(), nil)
end)

local audioOpts = { target = "client" :: "client", container = "workspace" :: "workspace" }
conformance(
	"Audio Wire graph wiring AudioPlayer -> AudioFader -> AudioAnalyzer and AudioDeviceOutput",
	function(root: Instance, ctx)
		local player: any = ctx.Instance.new("AudioPlayer")
		player.Parent = root

		local fader: any = ctx.Instance.new("AudioFader")
		fader.Volume = 0.5
		fader.Parent = root

		local analyzer: any = ctx.Instance.new("AudioAnalyzer")
		analyzer.Parent = root

		local deviceOut: any = ctx.Instance.new("AudioDeviceOutput")
		deviceOut.Parent = root

		local playerOutputs = player:GetOutputPins()
		local faderInputs = fader:GetInputPins()
		local faderOutputs = fader:GetOutputPins()
		local analyzerInputs = analyzer:GetInputPins()
		local deviceInputs = deviceOut:GetInputPins()

		sert.contains(playerOutputs, "Output")
		sert.contains(faderInputs, "Input")
		sert.contains(faderOutputs, "Output")
		sert.contains(analyzerInputs, "Input")
		sert.contains(deviceInputs, "Input")

		local wire1: any = ctx.Instance.new("Wire")
		wire1.SourceInstance = player
		wire1.TargetInstance = fader
		wire1.Parent = root

		local wire2: any = ctx.Instance.new("Wire")
		wire2.SourceInstance = fader
		wire2.TargetInstance = analyzer
		wire2.Parent = root

		local wire3: any = ctx.Instance.new("Wire")
		wire3.SourceInstance = fader
		wire3.TargetInstance = deviceOut
		wire3.Parent = root

		ctx.step(1 / 60)

		sert.eq(wire1.SourceName, "Output")
		sert.eq(wire1.TargetName, "Input")
		sert.eq(wire1.Connected, true)
		sert.eq(wire2.Connected, true)
		sert.eq(wire3.Connected, true)

		sert.eq(player:GetConnectedWires("Output"), { wire1 })
		sert.eq(fader:GetConnectedWires("Input"), { wire1 })
		sert.eq(#fader:GetConnectedWires("Output"), 2)
		sert.eq(analyzer:GetConnectedWires("Input"), { wire2 })
		sert.eq(deviceOut:GetConnectedWires("Input"), { wire3 })

		wire2.TargetInstance = nil
		ctx.step(1 / 60)
		sert.eq(wire2.Connected, false)
		sert.eq(analyzer:GetConnectedWires("Input"), {})

		wire2.SourceInstance = nil
		ctx.step(1 / 60)
		sert.eq(fader:GetConnectedWires("Output"), { wire3 })
	end,
	audioOpts
)

local uiOpts = { target = "client" :: "client", container = "PlayerGui" :: "PlayerGui" }
conformance(
	"UIPageLayout navigation/Circular and RichText ContentText/TextBounds conformance",
	function(root: Instance, ctx)
		local pageHost: any = ctx.Instance.new("Frame")
		pageHost.Name = "PageHost"
		pageHost.Size = ctx.UDim2.fromOffset(320, 200)
		pageHost.Parent = root

		local pages: any = ctx.Instance.new("UIPageLayout")
		pages.Padding = ctx.UDim.new(0, 8)
		pages.Animated = false
		pages.Circular = false
		pages.SortOrder = ctx.Enum.SortOrder.LayoutOrder
		pages.Parent = pageHost

		local p1: any = ctx.Instance.new("Frame")
		p1.Name = "Page1"
		p1.LayoutOrder = 1
		p1.Size = ctx.UDim2.fromScale(1, 1)
		p1.Parent = pageHost

		local p2: any = ctx.Instance.new("Frame")
		p2.Name = "Page2"
		p2.LayoutOrder = 2
		p2.Size = ctx.UDim2.fromScale(1, 1)
		p2.Parent = pageHost

		local p3: any = ctx.Instance.new("Frame")
		p3.Name = "Page3"
		p3.LayoutOrder = 3
		p3.Size = ctx.UDim2.fromScale(1, 1)
		p3.Parent = pageHost

		ctx.step(1 / 60)
		sert.eq(pages.CurrentPage, p1)

		pages:Previous()
		ctx.step(1 / 60)
		sert.eq(pages.CurrentPage, p1)

		pages:Next()
		ctx.step(1 / 60)
		sert.eq(pages.CurrentPage, p2)

		pages:Next()
		ctx.step(1 / 60)
		sert.eq(pages.CurrentPage, p3)

		pages:Next()
		ctx.step(1 / 60)
		sert.eq(pages.CurrentPage, p3)

		pages:JumpTo(p1)
		ctx.step(1 / 60)
		sert.eq(pages.CurrentPage, p1)

		pages:JumpToIndex(2)
		ctx.step(1 / 60)
		sert.eq(pages.CurrentPage, p3)

		pages.Circular = true
		pages:Next()
		ctx.step(1 / 60)
		sert.eq(pages.CurrentPage, p1)

		pages:Previous()
		ctx.step(1 / 60)
		sert.eq(pages.CurrentPage, p3)

		-- RichText markup stripping and TextBounds measurement.
		local richMulti: any = ctx.Instance.new("TextLabel")
		richMulti.Name = "RichMulti"
		richMulti.Size = ctx.UDim2.fromOffset(300, 120)
		richMulti.Position = ctx.UDim2.fromOffset(0, 220)
		richMulti.RichText = true
		richMulti.TextSize = 18
		richMulti.Text = "<b>Bold</b> &amp; <i>Italic</i><br/>Line 2"
		richMulti.Parent = root

		local richShort: any = ctx.Instance.new("TextLabel")
		richShort.Name = "RichShort"
		richShort.Size = ctx.UDim2.fromOffset(300, 40)
		richShort.Position = ctx.UDim2.fromOffset(0, 350)
		richShort.RichText = true
		richShort.TextSize = 18
		richShort.Text = "<b>AB</b>"
		richShort.Parent = root

		local rawTagText: any = ctx.Instance.new("TextLabel")
		rawTagText.Name = "RawTagText"
		rawTagText.Size = ctx.UDim2.fromOffset(300, 40)
		rawTagText.Position = ctx.UDim2.fromOffset(0, 400)
		rawTagText.RichText = false
		rawTagText.TextSize = 18
		rawTagText.Text = "<b>AB</b>"
		rawTagText.Parent = root

		ctx.step(1 / 60)
		sert.eq(richMulti.ContentText, "Bold & Italic\nLine 2")
		sert.eq(richShort.ContentText, "AB")
		sert.eq(rawTagText.ContentText, "<b>AB</b>")
		sert.gt(richShort.TextBounds.X, 0)
		sert.lt(richShort.TextBounds.X, rawTagText.TextBounds.X)
		sert.gt(richMulti.TextBounds.Y, richShort.TextBounds.Y)
	end,
	uiOpts
)

conformance(
	"sert.snapshot and sert.inlineSnapshot check and isolated [sert-x:snapshot] marker emission",
	function(_root: Instance, ctx)
		local payload = {
			count = 3,
			pos = ctx.Vector3.new(1, 2, 3),
			tag = "parity",
		}
		sert.inlineSnapshot(
			payload,
			[[{
  count = 3,
  pos = Vector3.new(1, 2, 3),
  tag = "parity",
}]]
		)

		-- Exercise file/sharedG snapshot lookup and `-u` `[sert-x:snapshot]` marker emission
		-- inside `sert.capture` + isolated registry so no repo fixtures or Studio marker streams leak.
		local prevShared = rawget(registry.mutant._sharedG, "__SERT_SNAPSHOTS")
		local matchRes: any
		local okSnap, snapErr = pcall(function()
			rawset(registry.mutant._sharedG, "__SERT_SNAPSHOTS", {
				EngineParityShared = {
					["shared snap :: badge"] = "{\n  active = true,\n}",
				},
			})
			matchRes = runIsolated(function()
				sert.test("opt snap", function()
					sert.snapshot({ hp = 100 }, "hero")
					sert.snapshot("ordinal-ok")
				end, { file = "EngineParityOpt" })
				sert.test(
					"shared snap",
					function() sert.snapshot({ active = true }, "badge") end,
					{ file = "EngineParityShared" }
				)
			end, {
				snapshots = {
					EngineParityOpt = {
						["opt snap :: hero"] = "{\n  hp = 100,\n}",
						["opt snap :: 1"] = "ordinal-ok",
					},
				},
			})
		end)
		rawset(registry.mutant._sharedG, "__SERT_SNAPSHOTS", prevShared)
		if not okSnap then error(snapErr, 0) end
		sert.eq(matchRes.failures, {})
		sert.eq(matchRes.total, 2)
		sert.eq(matchRes.passed, 2)
		sert.eq(matchRes.failed, 0)

		local emittedLines = sert.capture(function()
			local updRes = runIsolated(function()
				sert.test("emit bridge", function()
					sert.inlineSnapshot({ x = 1 }, nil)
					sert.snapshot({ y = 2 }, "card")
				end, { file = "EngineParityEmit" })
			end, { updateSnapshots = true })
			sert.eq(updRes.passed, 1)
			sert.eq(updRes.failed, 0)
		end)

		local http: any = ctx.getService("HttpService")
		local decodedMarkers: { any } = {}
		for _, line in emittedLines do
			local jsonPart = string.match(line, "^%[sert%-x:snapshot%] (.+)$")
			if jsonPart ~= nil then
				local decoded: any = http:JSONDecode(jsonPart)
				table.insert(decodedMarkers, decoded)
			end
		end
		sert.eq(#decodedMarkers, 2)
		sert.eq(decodedMarkers[1].kind, "inline")
		sert.eq(decodedMarkers[1].ordinal, 1)
		sert.eq(decodedMarkers[1].actual, "{\n  x = 1,\n}")
		sert.eq(decodedMarkers[2].kind, "file")
		sert.eq(decodedMarkers[2].key, "emit bridge :: card")
		sert.eq(decodedMarkers[2].actual, "{\n  y = 2,\n}")
	end
)
