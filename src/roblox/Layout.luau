--!strict
-- GUI layout settling and geometry helpers (`sert.roblox.Layout`).

local Datatypes = require("../doubles/datatypes")
local Env = require("../env")
local util = require("../util")

local RunService: RunService? = if (game :: any) ~= nil then game:GetService("RunService") else nil
local Vector2Lib: typeof(Vector2) = if (Vector2 :: any) ~= nil then Vector2 else Datatypes.Vector2 :: any

-- Geometry ----------------------------------------------------------------------------------------------------------

local geometry = {}

export type VisibleOptions = {
	stopAt: Instance?,
	requireDataModel: boolean?,
}

export type Rect = { x: number, y: number, width: number, height: number }

--- Returns `true` when `object` and every `GuiObject` ancestor up to `stopAt` are visible and its `LayerCollector` is enabled.
function geometry.visible(object: GuiObject, options: VisibleOptions?): boolean
	local stopAt = if options ~= nil then options.stopAt else nil
	local requireDataModel = options ~= nil and options.requireDataModel == true
	local current: Instance? = object
	while current ~= nil do
		if current:IsA("GuiObject") then
			if not (current :: GuiObject).Visible then return false end
		elseif current:IsA("LayerCollector") then
			local enabled = (current :: LayerCollector).Enabled
			if requireDataModel then return enabled and current:FindFirstAncestorWhichIsA("DataModel") ~= nil end
			return enabled
		end
		if current == stopAt and not requireDataModel then return true end
		current = current.Parent
	end
	return not requireDataModel
end

--- Returns `object`'s screen rect (`anchor = true` uses its `AnchorPoint` instead of top-left).
function geometry.rect(object: GuiObject, anchor: boolean?): Rect
	local position, size = object.AbsolutePosition, object.AbsoluteSize
	local x, y = position.X, position.Y
	if anchor then
		local point = object.AnchorPoint
		x += size.X * point.X
		y += size.Y * point.Y
	end
	return { x = x, y = y, width = size.X, height = size.Y }
end

--- Returns `true` when `a` and `b` match within `tolerance` pixels (default `0.5`); `positionOnly` ignores size.
function geometry.sameRect(a: Rect, b: Rect, tolerance: number?, positionOnly: boolean?): boolean
	local slack = tolerance or 0.5
	if math.abs(a.x - b.x) > slack or math.abs(a.y - b.y) > slack then return false end
	if positionOnly then return true end
	return math.abs(a.width - b.width) <= slack and math.abs(a.height - b.height) <= slack
end

--- Returns a function that steps one frame on `runService[phase]`, `task.wait`, or the active `sert.env`.
function geometry.stepper(phase: string, runService: any?): () -> ()
	local service: any = if runService ~= nil then runService else RunService
	return function()
		if runService ~= nil then
			local signal: any = runService[phase]
			signal:Wait()
			return
		end
		local active: any = Env.active()
		if active ~= nil then
			active:step()
		elseif service ~= nil then
			local signal: any = (service :: any)[phase]
			signal:Wait()
		elseif (task :: any) ~= nil then
			task.wait()
		else
			error("no RunService and no active sert.env: pass options.step", util.outside())
		end
	end
end

-- Layout ------------------------------------------------------------------------------------------------------------

local Layout = {}
Layout.geometry = table.freeze(geometry)

export type SettleOptions = {
	lead: number?, -- initial frames stepped before the first snapshot (default 1)
	stable: number?, -- consecutive unchanged frames required (default 2)
	maxFrames: number?, -- max frames to poll before failing (default 120)
	timeout: number?, -- max wall-clock seconds before failing (default 2)
	tolerance: number?, -- position/size delta tolerance in pixels (default 0.5)
	descendants: boolean?, -- include all descendants of root(s) (default true)
	filter: ((GuiObject) -> boolean)?,
	step: (() -> ())?,
}

local defaultStep = geometry.stepper("Heartbeat")

--- Returns `true` when `object` and its `GuiObject` ancestors up to `stopAt` are visible and any enclosing `LayerCollector` is enabled.
function Layout.visible(object: GuiObject, stopAt: Instance?): boolean
	return geometry.visible(object, { stopAt = stopAt })
end

type Snapshot = { [GuiObject]: { rect: Rect, text: Vector2 } }

local function sameSample(
	a: { rect: Rect, text: Vector2 },
	b: { rect: Rect, text: Vector2 },
	tolerance: number
): boolean
	return geometry.sameRect(a.rect, b.rect, tolerance)
		and math.abs(a.text.X - b.text.X) <= tolerance
		and math.abs(a.text.Y - b.text.Y) <= tolerance
end

local function takeSnapshot(roots: { Instance }, descendants: boolean, filter: ((GuiObject) -> boolean)?): Snapshot
	local out: Snapshot = {}
	local function add(node: Instance, root: Instance)
		if not node:IsA("GuiObject") then return end
		if not Layout.visible(node, root) then return end
		if filter ~= nil and not filter(node) then return end
		local textBounds = if node:IsA("TextLabel")
				or node:IsA("TextButton")
				or node:IsA("TextBox")
			then node.TextBounds
			else Vector2Lib.zero
		out[node] = { rect = geometry.rect(node), text = textBounds }
	end
	for _, root in roots do
		add(root, root)
		if descendants then
			for _, child in root:GetDescendants() do
				add(child, root)
			end
		end
	end
	return out
end

--- Steps frames until all visible `GuiObject`s under `target` hold still for `stable` consecutive frames, returning `(ok, movingName)`.
function Layout.settle(target: Instance | { Instance }, options: SettleOptions?): (boolean, string?)
	local opts: SettleOptions = options or {}
	local step = opts.step or defaultStep
	local lead = opts.lead or 1
	local needed = opts.stable or 2
	local maxFrames = opts.maxFrames or 120
	local timeout = opts.timeout or 2
	local tolerance = opts.tolerance or 0.5
	local descendants = if opts.descendants == nil then true else opts.descendants
	local roots: { Instance } = if Datatypes.typeof(target) == "Instance"
		then { target :: Instance }
		else target :: { Instance }

	for _ = 1, lead do
		step()
	end
	local previous = takeSnapshot(roots, descendants, opts.filter)
	local stable = 0
	local frames = 0
	local changed = "initial layout"
	local started = os.clock()
	while stable < needed and frames < maxFrames and os.clock() - started < timeout do
		step()
		frames += 1
		local current = takeSnapshot(roots, descendants, opts.filter)
		local unchanged = true
		for object, bounds in current do
			local before = previous[object]
			if before == nil then
				unchanged, changed = false, object:GetFullName()
				break
			end
			if not sameSample(bounds, before, tolerance) then
				unchanged, changed = false, object:GetFullName()
				break
			end
		end
		if unchanged then
			for object in previous do
				if current[object] == nil then
					unchanged, changed = false, object:GetFullName()
					break
				end
			end
		end
		stable = if unchanged then stable + 1 else 0
		previous = current
	end
	return stable >= needed, if stable >= needed then nil else changed
end

--- Returns the top-left and bottom-right screen bounds of `cell` after clipping against `ClipsDescendants` ancestors.
function Layout.clippedBounds(cell: GuiObject): (Vector2, Vector2)
	local low, high = cell.AbsolutePosition, cell.AbsolutePosition + cell.AbsoluteSize
	local parent = cell.Parent
	while parent ~= nil and not parent:IsA("LayerCollector") do
		if parent:IsA("GuiObject") and parent.ClipsDescendants then
			low = Vector2Lib.new(math.max(low.X, parent.AbsolutePosition.X), math.max(low.Y, parent.AbsolutePosition.Y))
			local finish = parent.AbsolutePosition + parent.AbsoluteSize
			high = Vector2Lib.new(math.min(high.X, finish.X), math.min(high.Y, finish.Y))
		end
		parent = parent.Parent
	end
	return low, high
end

Layout.waitForLayout = Layout.settle

export type NoOverlapOptions = {
	tolerance: number?,
	ignore: { string | Instance }?,
	recursive: boolean?,
}

export type FitsParentOptions = {
	tolerance: number?,
	allowScroll: boolean?,
}

export type FitsViewportOptions = {
	viewport: Vector2?,
	tolerance: number?,
	ignoreOffscreen: { string | Instance }?,
}

export type NoTextOverflowOptions = {
	ignore: { string | Instance }?,
	tolerance: number?,
}

export type AuditOptions = {
	viewport: Vector2?,
	tolerance: number?,
	noOverlap: boolean?,
	fitsViewport: boolean?,
	noTextOverflow: boolean?,
	fitsParent: boolean?,
	ignore: { string | Instance }?,
}

local function buildIgnoreLookup(list: { string | Instance }?): ({ [string]: boolean }, { [any]: boolean })
	local byName: { [string]: boolean } = {}
	local byInst: { [any]: boolean } = {}
	if list ~= nil then
		for _, item in list do
			if type(item) == "string" then
				byName[item] = true
			else
				byInst[item] = true
			end
		end
	end
	return byName, byInst
end

local function isIgnored(inst: Instance, byName: { [string]: boolean }, byInst: { [any]: boolean }): boolean
	return byInst[inst] == true or byName[inst.Name] == true
end

--- Asserts that no two visible sibling `GuiObject` children of `container` overlap by more than `tolerance` pixels (default `0.5`).
function Layout.noOverlap(container: Instance, opts: NoOverlapOptions?)
	local tolerance = if opts ~= nil and opts.tolerance ~= nil then opts.tolerance else 0.5
	local recursive = opts ~= nil and opts.recursive == true
	local byName, byInst = buildIgnoreLookup(if opts ~= nil then opts.ignore else nil)

	local function checkContainer(parent: Instance)
		local children: { GuiObject } = {}
		for _, child in parent:GetChildren() do
			if child:IsA("GuiObject") and not isIgnored(child, byName, byInst) then
				local gui = child :: GuiObject
				if gui.Visible and gui.AbsoluteSize.X > 0 and gui.AbsoluteSize.Y > 0 then
					table.insert(children, gui)
				end
			end
		end
		for i = 1, #children do
			local a = children[i]
			local ap, as = a.AbsolutePosition, a.AbsoluteSize
			for j = i + 1, #children do
				local b = children[j]
				local bp, bs = b.AbsolutePosition, b.AbsoluteSize
				local ix1 = math.max(ap.X, bp.X)
				local iy1 = math.max(ap.Y, bp.Y)
				local ix2 = math.min(ap.X + as.X, bp.X + bs.X)
				local iy2 = math.min(ap.Y + as.Y, bp.Y + bs.Y)
				if ix2 - ix1 > tolerance and iy2 - iy1 > tolerance then
					error(
						string.format(
							"Layout.noOverlap failed in %s: sibling %q (%.1f, %.1f, %.1fx%.1f) overlaps %q (%.1f, %.1f, %.1fx%.1f) by %.1fx%.1fpx",
							parent:GetFullName(),
							a.Name,
							ap.X,
							ap.Y,
							as.X,
							as.Y,
							b.Name,
							bp.X,
							bp.Y,
							bs.X,
							bs.Y,
							ix2 - ix1,
							iy2 - iy1
						),
						util.outside()
					)
				end
			end
		end
		if recursive then
			for _, child in parent:GetChildren() do
				if not isIgnored(child, byName, byInst) then
					local shouldVisit = if child:IsA("GuiObject")
						then (child :: GuiObject).Visible
						elseif child:IsA("LayerCollector") then (child :: LayerCollector).Enabled
						else child:IsA("GuiBase2d")
					if shouldVisit and child:FindFirstChildWhichIsA("UIPageLayout") == nil then
						checkContainer(child)
					end
				end
			end
		end
	end

	checkContainer(container)
end

--- Asserts that `node` (`GuiObject`) stays within its parent `GuiBase2d`'s bounds (respecting `ScrollingFrame` canvas bounds on scrollable axes when `allowScroll ~= false`).
function Layout.fitsParent(node: Instance, opts: FitsParentOptions?)
	if not node:IsA("GuiObject") then error("Layout.fitsParent: expected a GuiObject", util.outside()) end
	local parent = node.Parent
	if parent == nil or not parent:IsA("GuiBase2d") then
		error(`Layout.fitsParent: {node:GetFullName()} has no GuiBase2d parent`, util.outside())
	end
	local tolerance = if opts ~= nil and opts.tolerance ~= nil then opts.tolerance else 0.5
	local allowScroll = if opts == nil or opts.allowScroll == nil then true else opts.allowScroll

	local pGui = parent :: GuiBase2d
	local pPos, pSize = pGui.AbsolutePosition, pGui.AbsoluteSize
	local minX, minY = pPos.X, pPos.Y
	local maxX, maxY = pPos.X + pSize.X, pPos.Y + pSize.Y

	if allowScroll and parent:IsA("ScrollingFrame") then
		local sf: any = parent
		local dir = sf.ScrollingDirection
		local dirName = if type(dir) == "table" and dir.Name ~= nil then tostring(dir.Name) else tostring(dir or "XY")
		local scrollX = dirName == "XY"
			or dirName == "X"
			or string.sub(dirName, -2) == "XY"
			or string.sub(dirName, -1) == "X"
		local scrollY = dirName == "XY"
			or dirName == "Y"
			or string.sub(dirName, -2) == "XY"
			or string.sub(dirName, -1) == "Y"
		local canvasSize: Vector2 = sf.AbsoluteCanvasSize or pSize
		local canvasPos: Vector2 = sf.CanvasPosition or Vector2Lib.zero
		if scrollX then
			minX = pPos.X - canvasPos.X
			maxX = minX + math.max(pSize.X, canvasSize.X)
		end
		if scrollY then
			minY = pPos.Y - canvasPos.Y
			maxY = minY + math.max(pSize.Y, canvasSize.Y)
		end
	end

	local nGui = node :: GuiObject
	local nPos, nSize = nGui.AbsolutePosition, nGui.AbsoluteSize
	if
		nPos.X < minX - tolerance
		or nPos.Y < minY - tolerance
		or nPos.X + nSize.X > maxX + tolerance
		or nPos.Y + nSize.Y > maxY + tolerance
	then
		error(
			string.format(
				"Layout.fitsParent failed for %s: rect (%.1f, %.1f, %.1fx%.1f) exceeds parent %s bounds [%.1f..%.1f, %.1f..%.1f]",
				node:GetFullName(),
				nPos.X,
				nPos.Y,
				nSize.X,
				nSize.Y,
				parent:GetFullName(),
				minX,
				maxX,
				minY,
				maxY
			),
			util.outside()
		)
	end
end

local function resolveViewport(root: Instance, explicit: Vector2?): Vector2
	if explicit ~= nil then return explicit end
	local cur: Instance? = root
	while cur ~= nil do
		if cur:IsA("LayerCollector") or cur:IsA("BasePlayerGui") then
			local sz: any = (cur :: any).AbsoluteSize
			if sz ~= nil and sz.X > 0 and sz.Y > 0 then return sz end
		end
		cur = cur.Parent
	end
	if type(root) == "table" then
		local env = rawget(root :: any, "_env")
		if env ~= nil then
			if env.viewport ~= nil then return env.viewport end
			if env.camera ~= nil and env.camera.ViewportSize ~= nil then return env.camera.ViewportSize end
		end
	end
	local active: any = Env.active()
	if active ~= nil and active.viewport ~= nil then return active.viewport end
	if (workspace :: any) ~= nil and workspace.CurrentCamera ~= nil then return workspace.CurrentCamera.ViewportSize end
	return Vector2Lib.new(1920, 1080)
end

--- Asserts that all visible unclipped `GuiObject`s under `root` stay within the viewport bounds `[0, 0, viewport.X, viewport.Y]`.
function Layout.fitsViewport(root: Instance, opts: FitsViewportOptions?)
	local tolerance = if opts ~= nil and opts.tolerance ~= nil then opts.tolerance else 0.5
	local vp = resolveViewport(root, if opts ~= nil then opts.viewport else nil)
	local byName, byInst = buildIgnoreLookup(if opts ~= nil then opts.ignoreOffscreen else nil)

	local function visit(node: Instance)
		if isIgnored(node, byName, byInst) then return end
		if node:IsA("LayerCollector") and not (node :: LayerCollector).Enabled then return end
		if node:IsA("GuiObject") then
			local gui = node :: GuiObject
			if not gui.Visible then return end
			local pos, size = gui.AbsolutePosition, gui.AbsoluteSize
			if size.X > 0 and size.Y > 0 then
				if
					pos.X < -tolerance
					or pos.Y < -tolerance
					or pos.X + size.X > vp.X + tolerance
					or pos.Y + size.Y > vp.Y + tolerance
				then
					error(
						string.format(
							"Layout.fitsViewport failed for %s: rect (%.1f, %.1f, %.1fx%.1f) exceeds viewport (%.1fx%.1f)",
							node:GetFullName(),
							pos.X,
							pos.Y,
							size.X,
							size.Y,
							vp.X,
							vp.Y
						),
						util.outside()
					)
				end
			end
			if gui.ClipsDescendants or gui:IsA("ScrollingFrame") then return end
		end
		for _, child in node:GetChildren() do
			visit(child)
		end
	end

	visit(root)
end

--- Asserts that all visible `TextLabel`, `TextButton`, and `TextBox` nodes under `root` have `TextFits == true` and `TextBounds <= AbsoluteSize + tolerance`.
function Layout.noTextOverflow(root: Instance, opts: NoTextOverflowOptions?)
	local tolerance = if opts ~= nil and opts.tolerance ~= nil then opts.tolerance else 0.5
	local byName, byInst = buildIgnoreLookup(if opts ~= nil then opts.ignore else nil)

	local function visit(node: Instance)
		if isIgnored(node, byName, byInst) then return end
		if node:IsA("LayerCollector") and not (node :: LayerCollector).Enabled then return end
		if node:IsA("GuiObject") then
			local gui = node :: GuiObject
			if not gui.Visible then return end
			if node:IsA("TextLabel") or node:IsA("TextButton") or node:IsA("TextBox") then
				local t: any = node
				local text = tostring(t.Text or "")
				if text ~= "" then
					local bounds: Vector2 = t.TextBounds
					local size: Vector2 = gui.AbsoluteSize
					local fits: boolean = t.TextFits ~= false
					if not fits or bounds.X > size.X + tolerance or bounds.Y > size.Y + tolerance then
						error(
							string.format(
								"Layout.noTextOverflow failed for %s (Text=%q): TextBounds (%.1fx%.1f, TextFits=%s) overflows AbsoluteSize (%.1fx%.1f)",
								node:GetFullName(),
								text,
								bounds.X,
								bounds.Y,
								tostring(fits),
								size.X,
								size.Y
							),
							util.outside()
						)
					end
				end
			end
		end
		for _, child in node:GetChildren() do
			visit(child)
		end
	end

	visit(root)
end

--- Runs a composite layout audit across `root` (`fitsViewport`, `noTextOverflow`, `noOverlap` recursive across containers without `UIPageLayout`, and `fitsParent` when `opts.fitsParent == true`).
function Layout.audit(root: Instance, opts: AuditOptions?)
	local o: AuditOptions = opts or {}
	local tol = o.tolerance
	local ignore = o.ignore

	if o.fitsViewport ~= false then
		Layout.fitsViewport(root, { viewport = o.viewport, tolerance = tol, ignoreOffscreen = ignore })
	end
	if o.noTextOverflow ~= false then Layout.noTextOverflow(root, { tolerance = tol, ignore = ignore }) end
	if o.noOverlap ~= false then
		local byName, byInst = buildIgnoreLookup(ignore)
		local function auditOverlap(node: Instance)
			if isIgnored(node, byName, byInst) then return end
			if node:IsA("LayerCollector") and not (node :: LayerCollector).Enabled then return end
			if node:IsA("GuiObject") and not (node :: GuiObject).Visible then return end
			if node:IsA("GuiBase2d") and node:FindFirstChildWhichIsA("UIPageLayout") == nil then
				Layout.noOverlap(node, { tolerance = tol, ignore = ignore, recursive = false })
			end
			for _, child in node:GetChildren() do
				auditOverlap(child)
			end
		end
		auditOverlap(root)
	end
	if o.fitsParent == true then
		local byName, byInst = buildIgnoreLookup(ignore)
		local function auditParentFit(node: Instance)
			if isIgnored(node, byName, byInst) then return end
			if node:IsA("LayerCollector") and not (node :: LayerCollector).Enabled then return end
			if node:IsA("GuiObject") then
				if not (node :: GuiObject).Visible then return end
				if node ~= root and node.Parent ~= nil and node.Parent:IsA("GuiBase2d") then
					Layout.fitsParent(node, { tolerance = tol, allowScroll = true })
				end
			end
			for _, child in node:GetChildren() do
				auditParentFit(child)
			end
		end
		auditParentFit(root)
	end
end

--- Asserts that `child` fits inside `container` (defaulting to `child.Parent`).
function Layout.within(child: GuiObject, container: GuiBase2d?, tolerance: number?)
	local parentInst: Instance? = if container ~= nil then container else child.Parent
	if parentInst == nil or not parentInst:IsA("GuiBase2d") then
		error(`Layout.within: {child:GetFullName()} has no GuiBase2d container`, util.outside())
	end
	local parent = parentInst :: GuiBase2d
	if parent == child.Parent then
		Layout.fitsParent(child, { tolerance = tolerance })
		return
	end
	local tol = tolerance or 0.5
	local cPos, cSize = child.AbsolutePosition, child.AbsoluteSize
	local pPos, pSize = parent.AbsolutePosition, parent.AbsoluteSize
	if
		cPos.X < pPos.X - tol
		or cPos.Y < pPos.Y - tol
		or cPos.X + cSize.X > pPos.X + pSize.X + tol
		or cPos.Y + cSize.Y > pPos.Y + pSize.Y + tol
	then
		error(
			string.format(
				"Layout.within failed: %s (%.1f, %.1f, %.1fx%.1f) outside %s (%.1f, %.1f, %.1fx%.1f)",
				child:GetFullName(),
				cPos.X,
				cPos.Y,
				cSize.X,
				cSize.Y,
				parent:GetFullName(),
				pPos.X,
				pPos.Y,
				pSize.X,
				pSize.Y
			),
			util.outside()
		)
	end
end

--- Asserts that `objects` share the given alignment edge (`"Left"`, `"CenterX"`, `"Right"`, `"Top"`, `"CenterY"`, `"Bottom"`) within `tolerance` pixels.
function Layout.aligned(objects: { GuiObject }, edge: string, tolerance: number?)
	local tol = tolerance or 0.5
	if #objects < 2 then return end
	local function valueOf(g: GuiObject): number
		local p, s = g.AbsolutePosition, g.AbsoluteSize
		if edge == "Left" then
			return p.X
		elseif edge == "CenterX" then
			return p.X + s.X * 0.5
		elseif edge == "Right" then
			return p.X + s.X
		elseif edge == "Top" then
			return p.Y
		elseif edge == "CenterY" then
			return p.Y + s.Y * 0.5
		elseif edge == "Bottom" then
			return p.Y + s.Y
		end
		error(`Layout.aligned: unknown edge {tostring(edge)}`, util.outside())
	end
	local ref = valueOf(objects[1])
	for i = 2, #objects do
		local v = valueOf(objects[i])
		if math.abs(v - ref) > tol then
			error(
				string.format(
					"Layout.aligned(%s) failed: %s (%.1f) != %s (%.1f)",
					edge,
					objects[1]:GetFullName(),
					ref,
					objects[i]:GetFullName(),
					v
				),
				util.outside()
			)
		end
	end
end

--- Asserts that consecutive `objects` have `expectedGap` pixels between them along `axis` (`"X"` or `"Y"`) within `tolerance` pixels.
function Layout.spacing(objects: { GuiObject }, axis: string, expectedGap: number, tolerance: number?)
	local tol = tolerance or 0.5
	for i = 1, #objects - 1 do
		local a, b = objects[i], objects[i + 1]
		local gap = if axis == "X"
			then b.AbsolutePosition.X - (a.AbsolutePosition.X + a.AbsoluteSize.X)
			else b.AbsolutePosition.Y - (a.AbsolutePosition.Y + a.AbsoluteSize.Y)
		if math.abs(gap - expectedGap) > tol then
			error(
				string.format(
					"Layout.spacing(%s) failed between %s and %s: expected %.1fpx, got %.1fpx",
					axis,
					a.Name,
					b.Name,
					expectedGap,
					gap
				),
				util.outside()
			)
		end
	end
end

--- Asserts that `gui` has `AbsoluteSize.X > 0` and `AbsoluteSize.Y > 0`.
function Layout.nonZero(gui: GuiObject)
	local sz = gui.AbsoluteSize
	if sz.X <= 0 or sz.Y <= 0 then
		error(
			string.format("Layout.nonZero failed for %s: AbsoluteSize is (%.1fx%.1f)", gui:GetFullName(), sz.X, sz.Y),
			util.outside()
		)
	end
end

--- Asserts that `gui.AbsoluteSize.X / gui.AbsoluteSize.Y` matches `expected` within `tolerance`.
function Layout.aspectRatio(gui: GuiObject, expected: number, tolerance: number?)
	local tol = tolerance or 0.02
	local sz = gui.AbsoluteSize
	if sz.Y <= 0 then error(`Layout.aspectRatio failed for {gui:GetFullName()}: height is {sz.Y}`, util.outside()) end
	local actual = sz.X / sz.Y
	if math.abs(actual - expected) > tol then
		error(
			string.format(
				"Layout.aspectRatio failed for %s: expected %.3f, got %.3f (%.1fx%.1f)",
				gui:GetFullName(),
				expected,
				actual,
				sz.X,
				sz.Y
			),
			util.outside()
		)
	end
end

return Layout
