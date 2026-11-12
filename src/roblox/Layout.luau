--!strict
-- Geometric UI layout assertions, layout settling, and multi-device viewport matrix audits (`sert.roblox.Layout`).

local Datatypes = require("../engine/datatypes")
local Env = require("../env")
local registry = require("../core/registry")
local util = require("../core/util")

local v2: (number?, number?) -> Vector2 = (if Vector2 ~= nil then Vector2.new else Datatypes.Vector2.new) :: any

local Layout = {}

export type Rect = { x: number, y: number, w: number, h: number }

export type PresetName = "Phone" | "SmallPhone" | "Tablet" | "Desktop" | "Console" | "Ultrawide"

export type ViewportPreset = {
	name: string,
	size: Vector2,
}

local PRESET_MAP: { [string]: Vector2 } = {
	Phone = v2(390, 844),
	SmallPhone = v2(320, 568),
	Tablet = v2(820, 1180),
	Desktop = v2(1920, 1080),
	Console = v2(1920, 1080),
	Ultrawide = v2(2560, 1080),
}

local DEFAULT_PRESET_ORDER: { PresetName } = {
	"Phone",
	"SmallPhone",
	"Tablet",
	"Desktop",
	"Console",
	"Ultrawide",
}

Layout.PRESETS = table.freeze(PRESET_MAP)

local function readLocalRotation(gui: GuiObject): number
	local ok, rot = pcall(function() return (gui :: any).Rotation end)
	return if ok and type(rot) == "number" then rot else 0
end

local function readRotation(gui: GuiObject): number
	local ok, rot = pcall(function() return (gui :: any).AbsoluteRotation end)
	if ok and type(rot) == "number" and rot ~= 0 then return rot end
	if util.doubleTag(gui) ~= nil then
		local sum = readLocalRotation(gui)
		local cur: Instance? = gui.Parent
		while cur ~= nil do
			if cur:IsA("LayerCollector") then break end
			if cur:IsA("GuiObject") then
				sum += readLocalRotation(cur)
			end
			cur = cur.Parent
		end
		return sum
	end
	return if ok and type(rot) == "number" then rot else 0
end

-- Computes the axis-aligned screen bounding box `(min, max)` of `gui`, accounting for `AbsoluteRotation` around its center.
local function aabbOf(gui: GuiObject): (Vector2, Vector2)
	local pos = gui.AbsolutePosition
	local size = gui.AbsoluteSize
	local rot = readRotation(gui)
	if rot % 360 == 0 then return pos, v2(pos.X + size.X, pos.Y + size.Y) end
	local cx = pos.X + size.X * 0.5
	local cy = pos.Y + size.Y * 0.5
	local rad = math.rad(rot)
	local c = math.abs(math.cos(rad))
	local s = math.abs(math.sin(rad))
	local halfW = (size.X * c + size.Y * s) * 0.5
	local halfH = (size.X * s + size.Y * c) * 0.5
	return v2(cx - halfW, cy - halfH), v2(cx + halfW, cy + halfH)
end

local function hasRotatedChain(gui: GuiObject): boolean
	if readRotation(gui) % 360 ~= 0 or readLocalRotation(gui) % 360 ~= 0 then return true end
	local cur: Instance? = gui.Parent
	while cur ~= nil do
		if cur:IsA("LayerCollector") then break end
		if cur:IsA("GuiObject") and readLocalRotation(cur) % 360 ~= 0 then return true end
		cur = cur.Parent
	end
	return false
end

-- `CanvasGroup` always clips to its group texture; `ClipsDescendants` is ignored by Roblox when the container or any
-- `GuiObject` ancestor has non-zero `Rotation`.
local function clipsDescendantsEffectively(gui: GuiObject): boolean
	if gui:IsA("CanvasGroup") then return true end
	if not gui.ClipsDescendants then return false end
	return not hasRotatedChain(gui)
end

local function hasZeroUIScale(inst: Instance): boolean
	local ok, children = pcall(function() return inst:GetChildren() end)
	if not ok or type(children) ~= "table" then return false end
	for _, ch in children do
		if ch:IsA("UIScale") then
			local okScale, scale = pcall(function() return (ch :: UIScale).Scale end)
			if okScale and type(scale) == "number" and scale <= 0 then return true end
		end
	end
	return false
end

local geometry = {}

--- Returns true when `object` is effectively visible on screen (`Visible` chain, `LayerCollector.Enabled`,
--- `CanvasGroup.GroupTransparency < 1`, ancestor `UIScale.Scale > 0`, and positive `AbsoluteSize`).
function geometry.visible(object: GuiObject): boolean
	if not object.Visible then return false end
	if object.AbsoluteSize.X <= 0 or object.AbsoluteSize.Y <= 0 then return false end
	if object:IsA("CanvasGroup") and (object :: CanvasGroup).GroupTransparency >= 1 - 1e-6 then return false end
	if hasZeroUIScale(object) then return false end

	local cur: Instance? = object.Parent
	while cur ~= nil do
		if hasZeroUIScale(cur) then return false end
		if cur:IsA("GuiObject") then
			if not cur.Visible then return false end
			if cur:IsA("CanvasGroup") and (cur :: CanvasGroup).GroupTransparency >= 1 - 1e-6 then return false end
		elseif cur:IsA("LayerCollector") then
			if not cur.Enabled then return false end
			break
		end
		cur = cur.Parent
	end
	return true
end

--- Returns `object`'s screen rect (`anchor = true` measures position at `AnchorPoint`; rotated elements use rotated AABB).
function geometry.rect(object: GuiObject, anchor: boolean?): Rect
	if anchor then
		local pos, size, ap = object.AbsolutePosition, object.AbsoluteSize, object.AnchorPoint
		return { x = pos.X + size.X * ap.X, y = pos.Y + size.Y * ap.Y, w = size.X, h = size.Y }
	end
	local bMin, bMax = aabbOf(object)
	return { x = bMin.X, y = bMin.Y, w = bMax.X - bMin.X, h = bMax.Y - bMin.Y }
end

Layout.geometry = geometry

export type SettleOptions = {
	maxFrames: number?,
	stableFrames: number?,
	tolerance: number?,
	runService: any?,
}

export type NoOverlapOptions = {
	tolerance: number?,
	ignore: { string | Instance }?,
	recursive: boolean?,
}

export type Margin = number | { top: number?, bottom: number?, left: number?, right: number? }

export type FitsViewportOptions = {
	viewport: Vector2?,
	tolerance: number?,
	ignore: { string | Instance }?,
}

export type NoTextOverflowOptions = {
	tolerance: number?,
	ignore: { string | Instance }?,
}

export type MinTouchTargetOptions = {
	minSize: (number | Vector2)?,
	ignore: { string | Instance }?,
}

export type AuditOptions = {
	settle: (boolean | SettleOptions)?,
	overlap: (boolean | NoOverlapOptions)?,
	viewport: (boolean | Vector2 | FitsViewportOptions)?,
	textOverflow: (boolean | NoTextOverflowOptions)?,
	touchTargets: (boolean | number | Vector2 | MinTouchTargetOptions)?,
	ignore: { string | Instance }?,
}

export type MatrixOptions = {
	presets: { string | ViewportPreset }?,
	audit: (boolean | AuditOptions)?,
	settle: (boolean | SettleOptions)?,
	check: ((root: Instance, preset: ViewportPreset, env: any) -> ())?,
	target: registry.Target?,
}

local function findDataModel(inst: Instance): any?
	local cur: any = inst
	while cur ~= nil do
		local okParent, parent = pcall(function() return cur.Parent end)
		if not okParent or parent == nil then
			local okSvc, fn = pcall(function() return cur.GetService end)
			if okSvc and type(fn) == "function" then return cur end
			break
		end
		cur = parent
	end
	local activeEnv = registry.activeEnv()
	if activeEnv ~= nil and activeEnv.game ~= nil then return activeEnv.game end
	local realGame: any = if typeof(game) == "Instance" then game else nil
	return realGame
end

local function stepFrame(runService: any?): number
	local rs: any = runService
	if rs == nil then
		local activeEnv: any = registry.activeEnv()
		if activeEnv ~= nil then
			local stepFn: ((any) -> number)? = rawget(activeEnv, "step") :: any
			if stepFn ~= nil then return stepFn(activeEnv) end
		end
		if (game :: any) ~= nil then
			local dm: any = game
			local ok, svc = pcall(dm.GetService, dm, "RunService")
			if ok then rs = svc end
		end
	end
	if rs ~= nil then
		local isClient = false
		pcall(function() isClient = rs:IsClient() end)
		if isClient and rs.RenderStepped ~= nil then return tonumber((rs.RenderStepped :: any):Wait()) or 0 end
		if rs.Heartbeat ~= nil then return tonumber((rs.Heartbeat :: any):Wait()) or 0 end
	end
	if task ~= nil and task.wait ~= nil then return task.wait() end
	return 1 / 60
end

Layout.stepFrame = stepFrame

local function snapshotGeometry(root: Instance): { [GuiBase2d]: { pos: Vector2, size: Vector2 } }
	local snap: { [GuiBase2d]: { pos: Vector2, size: Vector2 } } = {}
	local function add(inst: Instance)
		if inst:IsA("GuiBase2d") then
			local g = inst :: GuiBase2d
			snap[g] = { pos = g.AbsolutePosition, size = g.AbsoluteSize }
		end
	end
	add(root)
	for _, desc in root:GetDescendants() do
		add(desc)
	end
	return snap
end

local function snapshotsMatch(
	a: { [GuiBase2d]: { pos: Vector2, size: Vector2 } },
	b: { [GuiBase2d]: { pos: Vector2, size: Vector2 } },
	tol: number
): boolean
	for inst, ga in a do
		local gb = b[inst]
		if not gb then return false end
		if math.abs(ga.pos.X - gb.pos.X) > tol or math.abs(ga.pos.Y - gb.pos.Y) > tol then return false end
		if math.abs(ga.size.X - gb.size.X) > tol or math.abs(ga.size.Y - gb.size.Y) > tol then return false end
	end
	for inst in b do
		if not a[inst] then return false end
	end
	return true
end

--- Steps frames until every `GuiBase2d` under `root` holds steady for `stableFrames` consecutive frames.
function Layout.settle(root: Instance, opts: SettleOptions?): number
	local maxFrames = if opts and opts.maxFrames then opts.maxFrames else 30
	local needStable = if opts and opts.stableFrames then opts.stableFrames else 2
	local tol = if opts and opts.tolerance then opts.tolerance else 0.5
	local rs = if opts then opts.runService else nil

	local prev = snapshotGeometry(root)
	local stable = 0
	for frame = 1, maxFrames do
		stepFrame(rs)
		local cur = snapshotGeometry(root)
		if snapshotsMatch(prev, cur, tol) then
			stable += 1
			if stable >= needStable then return frame end
		else
			stable = 0
		end
		prev = cur
	end
	return maxFrames
end

local function clippedBounds(gui: GuiObject, stopAt: Instance?): { min: Vector2, max: Vector2 }?
	if not geometry.visible(gui) then return nil end
	local bMin, bMax = aabbOf(gui)
	local minX, minY = bMin.X, bMin.Y
	local maxX, maxY = bMax.X, bMax.Y

	local cur: Instance? = gui.Parent
	while cur ~= nil and cur ~= stopAt do
		if cur:IsA("LayerCollector") then break end
		if cur:IsA("GuiObject") and clipsDescendantsEffectively(cur) then
			local cMin, cMax = aabbOf(cur)
			minX = math.max(minX, cMin.X)
			minY = math.max(minY, cMin.Y)
			maxX = math.min(maxX, cMax.X)
			maxY = math.min(maxY, cMax.Y)
			if maxX <= minX or maxY <= minY then return nil end
		end
		cur = cur.Parent
	end
	return { min = v2(minX, minY), max = v2(maxX, maxY) }
end

local function ancestorLayer(inst: Instance): LayerCollector?
	if inst:IsA("LayerCollector") then return inst end
	return inst:FindFirstAncestorWhichIsA("LayerCollector")
end

-- Resolves the usable screen viewport `(vpMin, vpMax)` in `AbsolutePosition` coordinates, accounting for
-- `ScreenGui.IgnoreGuiInset == false` (`GuiService:GetGuiInset()`) and `ScreenGui.AbsolutePosition` origin shifts.
local function resolveViewportBounds(root: Instance, override: Vector2?): (Vector2, Vector2)
	local dm = findDataModel(root)
	local layer = ancestorLayer(root)

	local vp: Vector2? = override
	local fromNativeLayerSize = false

	if vp == nil and dm ~= nil then
		local okWs, ws = pcall(function() return dm:GetService("Workspace") end)
		if okWs and ws ~= nil and ws.CurrentCamera ~= nil then vp = ws.CurrentCamera.ViewportSize end
	end
	if vp == nil and layer ~= nil then
		vp = (layer :: any).AbsoluteSize
		fromNativeLayerSize = util.doubleTag(layer) == nil
	end
	local rawVp = vp or v2(1920, 1080)

	local minX, minY = 0, 0
	if layer ~= nil then
		local lp = (layer :: any).AbsolutePosition
		if lp ~= nil then
			minX, minY = lp.X, lp.Y
		end
	end

	local usableW, usableH = rawVp.X, rawVp.Y
	if
		layer ~= nil
		and layer:IsA("ScreenGui")
		and not (layer :: ScreenGui).IgnoreGuiInset
		and not fromNativeLayerSize
	then
		if dm ~= nil then
			local okGs, gs = pcall(function() return dm:GetService("GuiService") end)
			if okGs and gs ~= nil then
				local okInset, topLeft, bottomRight = pcall(function() return gs:GetGuiInset() end)
				if okInset and topLeft ~= nil then
					local brX = if bottomRight ~= nil then bottomRight.X else 0
					local brY = if bottomRight ~= nil then bottomRight.Y else 0
					usableW = math.max(0, usableW - topLeft.X - brX)
					usableH = math.max(0, usableH - topLeft.Y - brY)
				end
			end
		end
	end

	return v2(minX, minY), v2(minX + usableW, minY + usableH)
end

local function unpackMargin(margin: Margin?): (number, number, number, number)
	if margin == nil then return 0, 0, 0, 0 end
	if type(margin) == "number" then return margin, margin, margin, margin end
	return margin.left or 0, margin.top or 0, margin.right or 0, margin.bottom or 0
end

local function buildIgnoreLookup(ignore: { string | Instance }?): ({ [string]: boolean }, { [Instance]: boolean })
	local byName: { [string]: boolean } = {}
	local byInst: { [Instance]: boolean } = {}
	if ignore then
		for _, item in ignore do
			if type(item) == "string" then
				byName[item] = true
			else
				byInst[item] = true
			end
		end
	end
	return byName, byInst
end

local function isIgnored(inst: Instance, byName: { [string]: boolean }, byInst: { [Instance]: boolean }): boolean
	return byInst[inst] == true or byName[inst.Name] == true
end

--- Asserts that no two visible sibling `GuiObject` children of `container` overlap beyond `tolerance` pixels.
function Layout.noOverlap(container: Instance, opts: NoOverlapOptions?)
	local tolerance = if opts and opts.tolerance then opts.tolerance else 0.5
	local recursive = if opts and opts.recursive ~= nil then opts.recursive else false
	local byName, byInst = buildIgnoreLookup(if opts then opts.ignore else nil)

	local function checkContainer(parent: Instance)
		local children: { { gui: GuiObject, min: Vector2, max: Vector2 } } = {}
		for _, child in parent:GetChildren() do
			if child:IsA("GuiObject") and not isIgnored(child, byName, byInst) and geometry.visible(child) then
				local bMin, bMax = aabbOf(child)
				if bMax.X - bMin.X > 0 and bMax.Y - bMin.Y > 0 then
					table.insert(children, { gui = child, min = bMin, max = bMax })
				end
			end
		end
		for i = 1, #children do
			local a = children[i]
			for j = i + 1, #children do
				local b = children[j]
				local ix1 = math.max(a.min.X, b.min.X)
				local iy1 = math.max(a.min.Y, b.min.Y)
				local ix2 = math.min(a.max.X, b.max.X)
				local iy2 = math.min(a.max.Y, b.max.Y)
				if ix2 - ix1 > tolerance and iy2 - iy1 > tolerance then
					error(
						string.format(
							"Layout.noOverlap failed in %s: sibling %q (%.1f, %.1f, %.1fx%.1f) overlaps %q (%.1f, %.1f, %.1fx%.1f) by %.1fx%.1fpx",
							parent:GetFullName(),
							a.gui.Name,
							a.min.X,
							a.min.Y,
							a.max.X - a.min.X,
							a.max.Y - a.min.Y,
							b.gui.Name,
							b.min.X,
							b.min.Y,
							b.max.X - b.min.X,
							b.max.Y - b.min.Y,
							ix2 - ix1,
							iy2 - iy1
						),
						util.outside()
					)
				end
			end
		end
		if recursive then
			for _, item in children do
				checkContainer(item.gui)
			end
		end
	end

	checkContainer(container)
end

local function resolveCanvasSize(sf: ScrollingFrame, parentSize: Vector2): Vector2
	local absCanvas = sf.AbsoluteCanvasSize
	local cs = sf.CanvasSize
	local calcW = parentSize.X * cs.X.Scale + cs.X.Offset
	local calcH = parentSize.Y * cs.Y.Scale + cs.Y.Offset
	return v2(math.max(absCanvas.X, calcW), math.max(absCanvas.Y, calcH))
end

--- Asserts that `child` (or every direct visible `GuiObject` child when `child` has children and `margin` is given)
--- fits inside its parent `GuiBase2d` (checking `CanvasSize` along scrollable axes on `ScrollingFrame`s).
function Layout.fitsParent(child: GuiObject, margin: Margin?, tolerance: number?)
	local eps = tolerance or 0.5
	local mL, mT, mR, mB = unpackMargin(margin)
	local parent = child.Parent
	if not parent or not parent:IsA("GuiBase2d") then
		error(`Layout.fitsParent: {child:GetFullName()} has no GuiBase2d parent`, util.outside())
	end
	local pp = (parent :: GuiBase2d).AbsolutePosition
	local ps = (parent :: GuiBase2d).AbsoluteSize
	local cp, csMax = aabbOf(child)

	local scrollX, scrollY = false, false
	local canvasSize = v2(0, 0)
	local canvasPos = v2(0, 0)
	if parent:IsA("ScrollingFrame") then
		local sf = parent :: ScrollingFrame
		local dir: any = sf.ScrollingDirection
		local dirName = if util.typeof(dir) == "EnumItem" then (dir :: any).Name else tostring(dir)
		scrollX = dirName == "X"
			or dirName == "XY"
			or string.find(dirName, "%.X$") ~= nil
			or string.find(dirName, "%.XY$") ~= nil
		scrollY = dirName == "Y"
			or dirName == "XY"
			or string.find(dirName, "%.Y$") ~= nil
			or string.find(dirName, "%.XY$") ~= nil
		canvasSize = resolveCanvasSize(sf, ps)
		local okCp, cPos: Vector2? = pcall(function() return sf.CanvasPosition end)
		if okCp and cPos ~= nil then canvasPos = cPos end
	end

	local xOk: boolean
	if scrollX then
		local canvasOriginX = pp.X - canvasPos.X
		local maxCanvasX = math.max(ps.X, canvasSize.X)
		xOk = cp.X >= canvasOriginX + mL - eps and csMax.X <= canvasOriginX + maxCanvasX - mR + eps
	else
		xOk = cp.X >= pp.X + mL - eps and csMax.X <= pp.X + ps.X - mR + eps
	end

	local yOk: boolean
	if scrollY then
		local canvasOriginY = pp.Y - canvasPos.Y
		local maxCanvasY = math.max(ps.Y, canvasSize.Y)
		yOk = cp.Y >= canvasOriginY + mT - eps and csMax.Y <= canvasOriginY + maxCanvasY - mB + eps
	else
		yOk = cp.Y >= pp.Y + mT - eps and csMax.Y <= pp.Y + ps.Y - mB + eps
	end

	if not (xOk and yOk) then
		error(
			string.format(
				"Layout.fitsParent failed: %s (%.1f, %.1f .. %.1f, %.1f) overflows parent %s (%.1f, %.1f, %.1fx%.1f)",
				child:GetFullName(),
				cp.X,
				cp.Y,
				csMax.X,
				csMax.Y,
				parent:GetFullName(),
				pp.X,
				pp.Y,
				ps.X,
				ps.Y
			),
			util.outside()
		)
	end
end

--- Asserts that `descendant` lies inside `ancestor` by at least `margin` pixels.
function Layout.within(descendant: GuiObject, ancestor: GuiBase2d, margin: Margin?, tolerance: number?)
	local eps = tolerance or 0.5
	local mL, mT, mR, mB = unpackMargin(margin)
	local ap: Vector2 = v2(0, 0)
	local aMax: Vector2 = v2(0, 0)
	if ancestor:IsA("GuiObject") then
		local minP, maxP = aabbOf(ancestor)
		ap = minP
		aMax = maxP
	else
		local p, s = ancestor.AbsolutePosition, ancestor.AbsoluteSize
		ap = p
		aMax = v2(p.X + s.X, p.Y + s.Y)
	end

	local b = clippedBounds(descendant, ancestor)
	local cMin: Vector2 = v2(0, 0)
	local cMax: Vector2 = v2(0, 0)
	if b ~= nil then
		cMin = b.min
		cMax = b.max
	else
		local minP, maxP = aabbOf(descendant)
		cMin = minP
		cMax = maxP
	end

	if
		cMin.X < ap.X + mL - eps
		or cMin.Y < ap.Y + mT - eps
		or cMax.X > aMax.X - mR + eps
		or cMax.Y > aMax.Y - mB + eps
	then
		error(
			string.format(
				"Layout.within failed: %s (%.1f..%.1f, %.1f..%.1f) escapes %s (%.1f..%.1f, %.1f..%.1f)",
				descendant:GetFullName(),
				cMin.X,
				cMax.X,
				cMin.Y,
				cMax.Y,
				ancestor:GetFullName(),
				ap.X + mL,
				aMax.X - mR,
				ap.Y + mT,
				aMax.Y - mB
			),
			util.outside()
		)
	end
end

--- Asserts that every visible non-clipped `GuiObject` under `root` fits inside the usable screen viewport.
function Layout.fitsViewport(root: Instance, opts: FitsViewportOptions?)
	local eps = if opts and opts.tolerance then opts.tolerance else 0.5
	local vpMin, vpMax = resolveViewportBounds(root, if opts then opts.viewport else nil)
	local byName, byInst = buildIgnoreLookup(if opts then opts.ignore else nil)

	local function visit(obj: Instance)
		if isIgnored(obj, byName, byInst) then return end
		if obj:IsA("GuiObject") then
			local gui = obj :: GuiObject
			if not gui.Visible then return end
			local b = clippedBounds(gui, nil)
			if b == nil then return end
			if
				b.min.X < vpMin.X - eps
				or b.min.Y < vpMin.Y - eps
				or b.max.X > vpMax.X + eps
				or b.max.Y > vpMax.Y + eps
			then
				error(
					string.format(
						"Layout.fitsViewport failed: %s clipped bounds (%.1f..%.1f, %.1f..%.1f) escape viewport (%.1f..%.1f, %.1f..%.1f)",
						gui:GetFullName(),
						b.min.X,
						b.max.X,
						b.min.Y,
						b.max.Y,
						vpMin.X,
						vpMax.X,
						vpMin.Y,
						vpMax.Y
					),
					util.outside()
				)
			end
			if clipsDescendantsEffectively(gui) then return end
		end
		for _, child in obj:GetChildren() do
			visit(child)
		end
	end

	visit(root)
end

local function innerTextSize(gui: GuiObject): (number, number)
	local size = gui.AbsoluteSize
	local padL, padR, padT, padB = 0, 0, 0, 0
	for _, ch in gui:GetChildren() do
		if ch:IsA("UIPadding") then
			local p = ch :: UIPadding
			padL += size.X * p.PaddingLeft.Scale + p.PaddingLeft.Offset
			padR += size.X * p.PaddingRight.Scale + p.PaddingRight.Offset
			padT += size.Y * p.PaddingTop.Scale + p.PaddingTop.Offset
			padB += size.Y * p.PaddingBottom.Scale + p.PaddingBottom.Offset
		end
	end
	return math.max(0, size.X - padL - padR), math.max(0, size.Y - padT - padB)
end

--- Asserts that every visible text element under `root` fits its padded inner bounds (`ContentText` + `UIPadding` + `TextFits`).
function Layout.noTextOverflow(root: Instance, opts: NoTextOverflowOptions?)
	local eps = if opts and opts.tolerance then opts.tolerance else 1.0
	local byName, byInst = buildIgnoreLookup(if opts then opts.ignore else nil)

	local function checkText(inst: Instance)
		if isIgnored(inst, byName, byInst) then return end
		if inst:IsA("TextLabel") or inst:IsA("TextButton") or inst:IsA("TextBox") then
			local t = inst :: TextLabel
			if geometry.visible(t) then
				local okCt, contentText = pcall(function() return (t :: any).ContentText end)
				local rendered = if okCt and type(contentText) == "string" then contentText else t.Text
				if #rendered > 0 and t.TextTransparency < 1 - 1e-6 then
					local tb = t.TextBounds
					local innerW, innerH = innerTextSize(t)
					if not t.TextFits or tb.X > innerW + eps or tb.Y > innerH + eps then
						error(
							string.format(
								"Layout.noTextOverflow failed: %s TextBounds (%.1fx%.1f) overflows inner bounds (%.1fx%.1f), TextFits=%s, ContentText=%q",
								t:GetFullName(),
								tb.X,
								tb.Y,
								innerW,
								innerH,
								tostring(t.TextFits),
								string.sub(rendered, 1, 40)
							),
							util.outside()
						)
					end
				end
			end
		end
	end

	checkText(root)
	for _, desc in root:GetDescendants() do
		checkText(desc)
	end
end

--- Asserts that every visible interactive button/textbox under `root` meets minimum touch-target dimensions (default 44x44px).
function Layout.minTouchTarget(root: Instance, opts: MinTouchTargetOptions?)
	local rawMin = if opts and opts.minSize then opts.minSize else 44
	local minW = if type(rawMin) == "number" then rawMin else rawMin.X
	local minH = if type(rawMin) == "number" then rawMin else rawMin.Y
	local byName, byInst = buildIgnoreLookup(if opts then opts.ignore else nil)

	local function checkInteractive(inst: Instance)
		if isIgnored(inst, byName, byInst) then return end
		if inst:IsA("GuiButton") or inst:IsA("TextBox") then
			local g = inst :: GuiObject
			if g.Active and geometry.visible(g) then
				local s = g.AbsoluteSize
				if s.X + 0.5 < minW or s.Y + 0.5 < minH then
					error(
						string.format(
							"Layout.minTouchTarget failed: %s is %.1fx%.1fpx, below minimum %.1fx%.1fpx",
							g:GetFullName(),
							s.X,
							s.Y,
							minW,
							minH
						),
						util.outside()
					)
				end
			end
		end
	end

	checkInteractive(root)
	for _, desc in root:GetDescendants() do
		checkInteractive(desc)
	end
end

--- Asserts that `gui` is effectively visible on screen.
function Layout.visible(gui: GuiObject)
	if not geometry.visible(gui) then
		error(
			string.format(
				"Layout.visible failed: %s is not effectively visible (Visible=%s, AbsoluteSize=%.1fx%.1f)",
				gui:GetFullName(),
				tostring(gui.Visible),
				gui.AbsoluteSize.X,
				gui.AbsoluteSize.Y
			),
			util.outside()
		)
	end
end

export type AlignEdge = "left" | "right" | "top" | "bottom" | "centerX" | "centerY"

local function edgeCoord(gui: GuiObject, edge: AlignEdge): number
	local bMin, bMax = aabbOf(gui)
	if edge == "left" then return bMin.X end
	if edge == "right" then return bMax.X end
	if edge == "top" then return bMin.Y end
	if edge == "bottom" then return bMax.Y end
	if edge == "centerX" then return (bMin.X + bMax.X) * 0.5 end
	if edge == "centerY" then return (bMin.Y + bMax.Y) * 0.5 end
	error(`Layout.aligned: unknown edge '{tostring(edge)}'`, util.outside())
end

--- Asserts that every `GuiObject` in `elements` aligns along `edge` within `tolerance` pixels.
function Layout.aligned(elements: { GuiObject }, edge: AlignEdge, tolerance: number?)
	local eps = tolerance or 1.0
	if #elements < 2 then return end
	local ref = edgeCoord(elements[1], edge)
	for i = 2, #elements do
		local val = edgeCoord(elements[i], edge)
		if math.abs(val - ref) > eps then
			error(
				string.format(
					"Layout.aligned(%q) failed: %s is at %.1fpx vs %s at %.1fpx (delta %.1fpx > %.1fpx)",
					edge,
					elements[i]:GetFullName(),
					val,
					elements[1]:GetFullName(),
					ref,
					math.abs(val - ref),
					eps
				),
				util.outside()
			)
		end
	end
end

local function mergeIgnore(a: { string | Instance }?, b: { string | Instance }?): { string | Instance }?
	if not a then return b end
	if not b then return a end
	local merged = table.clone(a)
	for _, item in b do
		table.insert(merged, item)
	end
	return merged
end

local function auditOverlapRecursive(
	root: Instance,
	opts: NoOverlapOptions,
	byName: { [string]: boolean },
	byInst: { [Instance]: boolean }
)
	local function visit(node: Instance)
		if isIgnored(node, byName, byInst) then return end
		local hasListOrGrid = false
		for _, ch in node:GetChildren() do
			if ch:IsA("UIListLayout") or ch:IsA("UIGridLayout") then
				hasListOrGrid = true
				break
			end
		end
		if hasListOrGrid then Layout.noOverlap(node, opts) end
		for _, ch in node:GetChildren() do
			if ch:IsA("GuiBase2d") or ch:IsA("Folder") then visit(ch) end
		end
	end
	visit(root)
end

--- Settles `root` and runs composite layout checks (`fitsViewport`, `UIListLayout`/`UIGridLayout` `noOverlap`,
--- `noTextOverflow`, and optional `touchTargets`).
function Layout.audit(root: Instance, opts: AuditOptions?)
	local sharedIgnore = if opts then opts.ignore else nil

	local settleOpt = if opts and opts.settle ~= nil then opts.settle else true
	if settleOpt ~= false then Layout.settle(root, if type(settleOpt) == "table" then settleOpt else nil) end

	local vpOpt: any = if opts and opts.viewport ~= nil then opts.viewport else true
	if vpOpt ~= false then
		local vpArgs: FitsViewportOptions = if util.typeof(vpOpt) == "Vector2"
			then { viewport = vpOpt :: Vector2, ignore = sharedIgnore }
			elseif type(vpOpt) == "table" then {
				viewport = vpOpt.viewport,
				tolerance = vpOpt.tolerance,
				ignore = mergeIgnore(sharedIgnore, vpOpt.ignore),
			}
			else { ignore = sharedIgnore }
		Layout.fitsViewport(root, vpArgs)
	end

	local ovOpt = if opts and opts.overlap ~= nil then opts.overlap else true
	if ovOpt ~= false then
		local ovArgs: NoOverlapOptions = if type(ovOpt) == "table"
			then {
				tolerance = ovOpt.tolerance,
				recursive = false,
				ignore = mergeIgnore(sharedIgnore, ovOpt.ignore),
			}
			else { ignore = sharedIgnore }
		local byName, byInst = buildIgnoreLookup(ovArgs.ignore)
		auditOverlapRecursive(root, ovArgs, byName, byInst)
	end

	local txOpt = if opts and opts.textOverflow ~= nil then opts.textOverflow else true
	if txOpt ~= false then
		local txArgs: NoTextOverflowOptions = if type(txOpt) == "table"
			then { tolerance = txOpt.tolerance, ignore = mergeIgnore(sharedIgnore, txOpt.ignore) }
			else { ignore = sharedIgnore }
		Layout.noTextOverflow(root, txArgs)
	end

	local ttOpt: any = if opts and opts.touchTargets ~= nil then opts.touchTargets else false
	if ttOpt ~= false then
		local ttArgs: MinTouchTargetOptions = if type(ttOpt) == "number" or util.typeof(ttOpt) == "Vector2"
			then { minSize = ttOpt, ignore = sharedIgnore }
			elseif type(ttOpt) == "table" then {
				minSize = ttOpt.minSize,
				ignore = mergeIgnore(sharedIgnore, ttOpt.ignore),
			}
			else { ignore = sharedIgnore }
		Layout.minTouchTarget(root, ttArgs)
	end
end

local function resolvePresets(list: { string | ViewportPreset }?): { ViewportPreset }
	local rawList: { any } = if list ~= nil then list else DEFAULT_PRESET_ORDER
	local out: { ViewportPreset } = {}
	for _, entry in rawList do
		if type(entry) == "string" then
			local sz: Vector2? = PRESET_MAP[entry]
			if sz == nil then error(`Layout.matrix: unknown device preset '{entry}'`, util.outside()) end
			table.insert(out, { name = entry, size = sz })
		elseif type(entry) == "table" and type(entry.name) == "string" and entry.size ~= nil then
			table.insert(out, entry)
		else
			error(
				"Layout.matrix: preset entry must be a preset name or { name = string, size = Vector2 }",
				util.outside()
			)
		end
	end
	return out
end

local function runMatrixOnce(
	mountFn: (container: Instance, preset: ViewportPreset, env: any?) -> any,
	opts: MatrixOptions
)
	local presets = resolvePresets(opts.presets)
	local isStudio = typeof(game) == "Instance"

	for _, preset in presets do
		local scratchEnv: any = nil
		local container: Instance
		local screenCleanup: (() -> ())? = nil

		if isStudio then
			local playersOk, players = pcall(game.GetService, game, "Players")
			local lp: Player? = if playersOk and players then (players :: Players).LocalPlayer else nil
			local parentGui: Instance? = if lp then lp:FindFirstChildOfClass("PlayerGui") else nil
			if parentGui == nil then
				local sgOk, sg = pcall(game.GetService, game, "StarterGui")
				if sgOk then parentGui = sg end
			end
			local sg = Instance.new("ScreenGui")
			sg.Name = `sert_Matrix_{preset.name}`
			sg.IgnoreGuiInset = true
			sg.ResetOnSpawn = false
			sg.Parent = parentGui

			local viewportFrame = Instance.new("Frame")
			viewportFrame.Name = preset.name
			viewportFrame.BackgroundTransparency = 1
			viewportFrame.Position = UDim2.fromOffset(0, 0)
			viewportFrame.Size = UDim2.fromOffset(preset.size.X, preset.size.Y)
			viewportFrame.Parent = sg
			container = viewportFrame
			screenCleanup = function() sg:Destroy() end
		else
			local prevActive = registry.activeEnv()
			scratchEnv = Env.new({ isClient = true, viewport = preset.size })
			registry.setActiveEnv(scratchEnv)
			local sg = scratchEnv.Instance.new("ScreenGui")
			sg.Name = `sert_Matrix_{preset.name}`
			sg.IgnoreGuiInset = true
			sg.Parent = scratchEnv.playerGui
			container = sg
			screenCleanup = function()
				scratchEnv:shutdown()
				registry.setActiveEnv(prevActive)
			end
		end

		local okPreset, presetErr = pcall(function()
			local mounted = mountFn(container, preset, scratchEnv)
			local rootSubject: Instance = container
			local userCleanup: (() -> ())? = nil

			if type(mounted) == "table" and util.typeof(mounted) ~= "Instance" and mounted.root ~= nil then
				rootSubject = mounted.root
				userCleanup = mounted.cleanup
			elseif mounted ~= nil and util.typeof(mounted) == "Instance" then
				rootSubject = mounted
				if (mounted :: any).Parent == nil then (mounted :: any).Parent = container end
			end

			local okAudit, auditErr = pcall(function()
				if opts.settle ~= false then
					Layout.settle(rootSubject, if type(opts.settle) == "table" then opts.settle else nil)
				end

				if opts.audit ~= false then
					local baseAudit: AuditOptions = if type(opts.audit) == "table" then table.clone(opts.audit) else {}
					baseAudit.settle = false
					if baseAudit.viewport == nil or baseAudit.viewport == true then
						baseAudit.viewport = { viewport = preset.size }
					elseif type(baseAudit.viewport) == "table" and baseAudit.viewport.viewport == nil then
						local vpCopy = table.clone(baseAudit.viewport)
						vpCopy.viewport = preset.size
						baseAudit.viewport = vpCopy
					end
					Layout.audit(rootSubject, baseAudit)
				end

				if opts.check ~= nil then opts.check(rootSubject, preset, scratchEnv) end
			end)

			if userCleanup ~= nil then pcall(userCleanup) end
			if not okAudit then error(auditErr, 0) end
		end)

		if screenCleanup ~= nil then pcall(screenCleanup) end
		if not okPreset then
			error(
				`Layout.matrix [{preset.name} {preset.size.X}x{preset.size.Y}]: {tostring(presetErr)}`,
				util.outside()
			)
		end
	end
end

--- Mounts and audits a UI builder across standard device presets (`Phone`, `SmallPhone`, `Tablet`, `Desktop`,
--- `Console`, `Ultrawide`). Runs inline inside a test or registers a test when given `(name, mountFn, opts?)` at top level.
function Layout.matrix(
	nameOrMount: string | ((container: Instance, preset: ViewportPreset, env: any?) -> any),
	maybeMountOrOpts: (((container: Instance, preset: ViewportPreset, env: any?) -> any) | MatrixOptions)?,
	maybeOpts: MatrixOptions?
)
	if type(nameOrMount) == "string" then
		local name = nameOrMount
		local mountFn = maybeMountOrOpts :: (container: Instance, preset: ViewportPreset, env: any?) -> any
		local opts: MatrixOptions = maybeOpts or {}
		if type(mountFn) ~= "function" then
			error("Layout.matrix: expected mount function as second argument", util.outside())
		end
		if not registry.inline() then
			local body = function() runMatrixOnce(mountFn, opts) end
			if opts.target == "client" then
				registry.api.test.client(name, body)
			elseif opts.target == "roblox" then
				registry.api.test.roblox(name, body)
			elseif opts.target == "server" then
				registry.api.test.server(name, body)
			else
				registry.api.test(name, body)
			end
			return
		end
		runMatrixOnce(mountFn, opts)
		return
	end

	if type(nameOrMount) ~= "function" then
		error("Layout.matrix: expected mount function or (name, mountFn, opts?)", util.outside())
	end
	local opts: MatrixOptions = (maybeMountOrOpts :: MatrixOptions?) or {}
	runMatrixOnce(nameOrMount, opts)
end

return Layout
