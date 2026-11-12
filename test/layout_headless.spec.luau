--!strict
-- Headless `sert.roblox.Layout` geometry assertions: `visible`, `fitsParent` (with rotated AABB & ScrollingFrame),
-- `fitsViewport` (`IgnoreGuiInset = false` top-bar inset & rotated ClipsDescendants), `noOverlap`, `noTextOverflow`,
-- `minTouchTarget`, `aligned`, `within`, `audit`, and `Layout.matrix` across device presets.

local registry = require("../src/core/registry")
local sert = require("../src")

local describe = sert.describe
local test = sert.test
local Layout = sert.roblox.Layout

local function runIsolated(register: () -> (), opts: sert.RunOptions?): sert.Results
	local sub = registry.newState()
	registry.isolateDepth += 1
	local ok, res = pcall(function(): sert.Results
		return registry.withState(sub, function(): sert.Results
			register()
			local merged: sert.RunOptions = if opts ~= nil then table.clone(opts) else {}
			if merged.quiet == nil and merged.silent == nil then merged.quiet = true end
			if merged.raise == nil then merged.raise = false end
			return sert.run(merged)
		end)
	end)
	registry.isolateDepth -= 1
	if not ok then error(res, 0) end
	return res
end

describe("sert.roblox.Layout: visibility, rotated AABB containment & viewport insets", function()
	test(
		"Layout.visible rejects hidden, disabled LayerCollector, GroupTransparency = 1 CanvasGroup, and zero UIScale",
		function()
			local e = sert.env.new({ isClient = true, isServer = false })
			local sg = e.Instance.new("ScreenGui")
			sg.Parent = e:getService("Players").LocalPlayer.PlayerGui

			local card = e.Instance.new("Frame")
			card.Size = e.UDim2.fromOffset(120, 60)
			card.Parent = sg

			Layout.visible(card :: any)

			-- Visible = false
			card.Visible = false
			sert.throws(function() Layout.visible(card :: any) end, "Layout.visible")
			card.Visible = true

			-- Disabled ScreenGui ancestor
			sg.Enabled = false
			sert.throws(function() Layout.visible(card :: any) end, "Layout.visible")
			sg.Enabled = true

			-- Ancestor CanvasGroup with GroupTransparency = 1 renders all descendants invisible!
			local cg = e.Instance.new("CanvasGroup")
			cg.Size = e.UDim2.fromOffset(200, 200)
			cg.GroupTransparency = 1
			cg.Parent = sg
			local cgChild = e.Instance.new("Frame")
			cgChild.Size = e.UDim2.fromOffset(80, 40)
			cgChild.Parent = cg
			sert.eq(Layout.geometry.visible(cgChild :: any), false)
			sert.throws(function() Layout.visible(cgChild :: any) end, "Layout.visible")
			cg.GroupTransparency = 0
			Layout.visible(cgChild :: any)

			-- Zero UIScale collapses effective size to 0
			local scale = e.Instance.new("UIScale")
			scale.Scale = 0
			scale.Parent = cgChild
			sert.throws(function() Layout.visible(cgChild :: any) end, "Layout.visible")
		end
	)

	test(
		"Layout.fitsParent and Layout.within compute 45-degree rotated AABBs and ScrollingFrame CanvasSize bounds",
		function()
			local e = sert.env.new({ isClient = true, isServer = false })
			local sg = e.Instance.new("ScreenGui")
			sg.Parent = e:getService("Players").LocalPlayer.PlayerGui

			local box = e.Instance.new("Frame")
			box.Position = e.UDim2.fromOffset(50, 50)
			box.Size = e.UDim2.fromOffset(100, 100)
			box.Parent = sg

			-- A 90x90 square centered inside a 100x100 parent fits at Rotation = 0,
			-- but at Rotation = 45 its AABB diagonal is 90 * sqrt(2) ~= 127.3px > 100px!
			local badge = e.Instance.new("Frame")
			badge.AnchorPoint = e.Vector2.new(0.5, 0.5)
			badge.Position = e.UDim2.fromScale(0.5, 0.5)
			badge.Size = e.UDim2.fromOffset(90, 90)
			badge.Parent = box

			Layout.fitsParent(badge :: any)
			badge.Rotation = 45
			sert.throws(function() Layout.fitsParent(badge :: any) end, "Layout.fitsParent")

			-- Shrinking to 68x68 gives rotated AABB 68 * sqrt(2) ~= 96.2px <= 100px!
			badge.Size = e.UDim2.fromOffset(68, 68)
			Layout.fitsParent(badge :: any)
			Layout.within(badge :: any, box :: any, 1)

			-- ScrollingFrame: child beyond viewport height still fits inside CanvasSize!
			local scroll = e.Instance.new("ScrollingFrame")
			scroll.Size = e.UDim2.fromOffset(200, 120)
			scroll.CanvasSize = e.UDim2.fromOffset(0, 500)
			scroll.Parent = sg

			local row = e.Instance.new("Frame")
			row.Position = e.UDim2.fromOffset(10, 380)
			row.Size = e.UDim2.fromOffset(180, 60)
			row.Parent = scroll
			Layout.fitsParent(row :: any)

			row.Position = e.UDim2.fromOffset(10, 470) -- 470 + 60 = 530 > 500 canvas height
			sert.throws(function() Layout.fitsParent(row :: any) end, "Layout.fitsParent")
		end
	)

	test(
		"Layout.fitsViewport honors ScreenGui.IgnoreGuiInset = false top-bar inset and rotated ClipsDescendants rules",
		function()
			local e = sert.env.new({
				isClient = true,
				isServer = false,
				viewport = sert.env.Vector2.new(800, 600),
			})
			-- Configure a 58px top-bar inset on GuiService.
			local gs: any = e:getService("GuiService")
			rawset(gs._props, "_guiInset", e.Vector2.new(0, 58))

			local sg = e.Instance.new("ScreenGui")
			sg.IgnoreGuiInset = false
			sg.Parent = e:getService("Players").LocalPlayer.PlayerGui

			-- In headless layout, IgnoreGuiInset = false offsets ScreenGui origin to Y=58 (usable Y: 58..600).
			-- Placing a header at Position = (0, -20) puts it at screen Y=38 < 58 top-bar inset!
			local header = e.Instance.new("Frame")
			header.Position = e.UDim2.fromOffset(0, -20)
			header.Size = e.UDim2.fromOffset(300, 40)
			header.Parent = sg

			sert.throws(function() Layout.fitsViewport(sg :: any) end, "Layout.fitsViewport")

			-- Moving header to Y=0 (screen Y=58) or enabling IgnoreGuiInset = true satisfies viewport bounds!
			header.Position = e.UDim2.fromOffset(0, 0)
			Layout.fitsViewport(sg :: any)

			-- Unrotated ClipsDescendants clips overflowing children, whereas Rotation ~= 0 disables ClipsDescendants in Roblox!
			local clipper = e.Instance.new("Frame")
			clipper.Position = e.UDim2.fromOffset(700, 100)
			clipper.Size = e.UDim2.fromOffset(80, 80)
			clipper.ClipsDescendants = true
			clipper.Parent = sg

			local overflowChild = e.Instance.new("Frame")
			overflowChild.Position = e.UDim2.fromOffset(40, 0)
			overflowChild.Size = e.UDim2.fromOffset(120, 40) -- extends to X=860 > 800 when unclipped!
			overflowChild.Parent = clipper

			Layout.fitsViewport(sg :: any)
			clipper.Rotation = 5
			sert.throws(function() Layout.fitsViewport(sg :: any) end, "Layout.fitsViewport")
		end
	)
end)

describe("sert.roblox.Layout: noOverlap, noTextOverflow, minTouchTarget, aligned, audit & matrix", function()
	test(
		"validates sibling overlap, TextFits/ContentText/UIPadding overflow, 44px touch targets, and edge alignment",
		function()
			local e = sert.env.new({ isClient = true, isServer = false })
			local sg = e.Instance.new("ScreenGui")
			sg.IgnoreGuiInset = true
			sg.Parent = e:getService("Players").LocalPlayer.PlayerGui

			local row = e.Instance.new("Frame")
			row.Position = e.UDim2.fromOffset(20, 20)
			row.Size = e.UDim2.fromOffset(400, 80)
			row.Parent = sg

			local a = e.Instance.new("TextButton")
			a.Name = "PrimaryBtn"
			a.Position = e.UDim2.fromOffset(0, 10)
			a.Size = e.UDim2.fromOffset(120, 48)
			a.Text = "Play"
			a.TextSize = 16
			a.Parent = row

			local b = e.Instance.new("TextButton")
			b.Name = "SecondaryBtn"
			b.Position = e.UDim2.fromOffset(80, 10) -- overlaps `a` (0..120 vs 80..200)!
			b.Size = e.UDim2.fromOffset(120, 48)
			b.Text = "Shop"
			b.TextSize = 16
			b.Parent = row

			sert.throws(function() Layout.noOverlap(row :: any) end, "Layout.noOverlap")

			b.Position = e.UDim2.fromOffset(132, 10)
			Layout.noOverlap(row :: any)
			Layout.aligned({ a :: any, b :: any }, "top")
			Layout.aligned({ a :: any, b :: any }, "centerY")
			Layout.minTouchTarget(row :: any)

			-- Undersized interactive button (< 44x44px) fails minTouchTarget!
			local tinyBtn = e.Instance.new("ImageButton")
			tinyBtn.Name = "TinyClose"
			tinyBtn.Position = e.UDim2.fromOffset(280, 10)
			tinyBtn.Size = e.UDim2.fromOffset(28, 28)
			tinyBtn.Parent = row

			sert.throws(function() Layout.minTouchTarget(row :: any) end, "Layout.minTouchTarget")
			Layout.minTouchTarget(row :: any, { ignore = { "TinyClose" } })
			tinyBtn.Size = e.UDim2.fromOffset(44, 44)
			Layout.minTouchTarget(row :: any)

			-- noTextOverflow checks TextFits == false, ContentText (RichText), and UIPadding inner width!
			local label = e.Instance.new("TextLabel")
			label.Name = "Title"
			label.Position = e.UDim2.fromOffset(20, 120)
			label.Size = e.UDim2.fromOffset(60, 24)
			label.TextSize = 20
			label.Text = "Extremely Long Unwrapped Heading Text"
			label.Parent = sg

			sert.eq(label.TextFits, false)
			sert.throws(function() Layout.noTextOverflow(sg :: any) end, "Layout.noTextOverflow")

			-- RichText tags do not count toward ContentText width when rendered text is short!
			label.RichText = true
			label.Size = e.UDim2.fromOffset(120, 32)
			label.Text = '<b><font color="#ffffff">OK</font></b>'
			sert.eq(label.ContentText, "OK")
			sert.eq(label.TextFits, true)
			Layout.noTextOverflow(sg :: any)

			-- Excessive UIPadding shrinks inner text box below TextBounds -> caught by noTextOverflow!
			local pad = e.Instance.new("UIPadding")
			pad.PaddingLeft = e.UDim.new(0, 58)
			pad.PaddingRight = e.UDim.new(0, 58)
			pad.Parent = label
			sert.throws(function() Layout.noTextOverflow(sg :: any) end, "Layout.noTextOverflow")
			pad:Destroy()

			-- Composite Layout.audit passes cleanly when layout, text, viewport, and touch targets are healthy!
			Layout.audit(sg :: any, { touchTargets = true })
		end
	)

	-- Top-level registered Layout.matrix test across responsive device presets!
	Layout.matrix(
		"responsive HUD passes Layout.audit across Phone, SmallPhone, Tablet, Desktop, Console, and Ultrawide",
		function(container: Instance, preset, env: any)
			local inst = env.Instance
			local udim2 = env.UDim2
			local udim = env.UDim

			local bar = inst.new("Frame")
			bar.Name = "ActionBar"
			bar.AnchorPoint = env.Vector2.new(0.5, 1)
			bar.Position = udim2.new(0.5, 0, 1, -12)
			bar.Size = udim2.fromOffset(math.min(preset.size.X - 24, 420), 56)
			bar.Parent = container

			local list = inst.new("UIListLayout")
			list.FillDirection = env.Enum.FillDirection.Horizontal
			list.HorizontalAlignment = env.Enum.HorizontalAlignment.Center
			list.VerticalAlignment = env.Enum.VerticalAlignment.Center
			list.Padding = udim.new(0, 8)
			list.Parent = bar

			for i, caption in { "Play", "Bag", "Shop" } do
				local btn = inst.new("TextButton")
				btn.Name = `Btn_{caption}`
				btn.LayoutOrder = i
				btn.Size = udim2.fromOffset(84, 48)
				btn.TextSize = 14
				btn.Text = caption
				btn.Parent = bar
			end

			return bar
		end,
		{
			audit = { touchTargets = true },
		}
	)

	test("Layout.matrix runs inline with custom preset subsets and catches small-screen overflow", function()
		local visited: { string } = {}
		sert.throws(function()
			Layout.matrix(function(container: Instance, preset, env: any)
				table.insert(visited, preset.name)
				local modal = env.Instance.new("Frame")
				modal.Size = env.UDim2.fromOffset(700, 300)
				modal.Parent = container
				return modal
			end, {
				presets = { "Desktop" :: any, "SmallPhone" :: any },
			})
		end, "SmallPhone")
		sert.eq(visited, { "Desktop", "SmallPhone" })
	end)

	test(
		"exercises stepFrame, geometry.rect, clippedBounds, aligned modes, diagnostics, and audit/matrix options",
		function()
			-- 1) stepFrame with custom client/server RunService mocks and fallback when activeEnv is unset.
			local prevEnv = registry.activeEnv()
			registry.setActiveEnv(nil)
			local renderSteps = 0
			local dtClient = Layout.stepFrame({
				IsClient = function() return true end,
				RenderStepped = {
					Wait = function()
						renderSteps += 1
						return 0.016
					end,
				},
			})
			sert.near(dtClient, 0.016, 1e-4)
			sert.eq(renderSteps, 1)

			local hbSteps = 0
			local dtServer = Layout.stepFrame({
				IsClient = function() return false end,
				Heartbeat = {
					Wait = function()
						hbSteps += 1
						return 0.02
					end,
				},
			})
			sert.near(dtServer, 0.02, 1e-4)
			sert.eq(hbSteps, 1)

			local dtFallback = Layout.stepFrame({})
			sert.gt(dtFallback, 0)
			registry.setActiveEnv(prevEnv)

			-- 2) geometry.rect (anchor vs rotated AABB), fitsParent edge cases, and clippedBounds inside Layout.within.
			local e = sert.env.new({ isClient = true, isServer = false, viewport = sert.env.Vector2.new(800, 600) })
			local sg = e.Instance.new("ScreenGui")
			sg.IgnoreGuiInset = true
			sg.Parent = e:getService("Players").LocalPlayer.PlayerGui

			local orphan = e.Instance.new("Frame")
			orphan.Size = e.UDim2.fromOffset(40, 40)
			sert.throws(function() Layout.fitsParent(orphan :: any) end, "no GuiBase2d parent")

			local folderParent = e.Instance.new("Folder")
			folderParent.Parent = sg
			orphan.Parent = folderParent
			sert.throws(function() Layout.fitsParent(orphan :: any) end, "no GuiBase2d parent")
			orphan:Destroy()
			folderParent:Destroy()

			-- Horizontal ScrollingFrame (`ScrollingDirection.X`) + margin table `{ left, top, right, bottom }`.
			local hScroll = e.Instance.new("ScrollingFrame")
			hScroll.Position = e.UDim2.fromOffset(10, 10)
			hScroll.Size = e.UDim2.fromOffset(150, 80)
			hScroll.CanvasSize = e.UDim2.fromOffset(600, 0)
			hScroll.ScrollingDirection = e.Enum.ScrollingDirection.X
			hScroll.Parent = sg

			local hItem = e.Instance.new("Frame")
			hItem.AnchorPoint = e.Vector2.new(0.5, 0.5)
			hItem.Position = e.UDim2.fromOffset(450, 40)
			hItem.Size = e.UDim2.fromOffset(100, 50)
			hItem.Parent = hScroll

			local rectAnchor = Layout.geometry.rect(hItem :: any, true)
			local rectBox = Layout.geometry.rect(hItem :: any, false)
			sert.near(rectAnchor.x, 460, 0.5)
			sert.near(rectBox.x, 410, 0.5)
			Layout.fitsParent(hItem :: any, { left = 8, top = 8, right = 8, bottom = 8 })

			hItem.Position = e.UDim2.fromOffset(570, 40) -- 570 + 50 = 620 > 600 canvas width
			sert.throws(
				function() Layout.fitsParent(hItem :: any, { left = 8, top = 8, right = 8, bottom = 8 }) end,
				"Layout.fitsParent failed"
			)
			hScroll:Destroy()

			-- Intermediate `ClipsDescendants = true` container inside an outer ancestor exercises `clippedBounds`.
			local outer = e.Instance.new("Frame")
			outer.Name = "OuterPanel"
			outer.Position = e.UDim2.fromOffset(40, 40)
			outer.Size = e.UDim2.fromOffset(200, 160)
			outer.Parent = sg

			local innerClip = e.Instance.new("Frame")
			innerClip.Name = "InnerClip"
			innerClip.Position = e.UDim2.fromOffset(20, 20)
			innerClip.Size = e.UDim2.fromOffset(100, 80)
			innerClip.ClipsDescendants = true
			innerClip.Parent = outer

			local clippedChild = e.Instance.new("Frame")
			clippedChild.Name = "ClippedBanner"
			clippedChild.Position = e.UDim2.fromOffset(50, 10)
			clippedChild.Size = e.UDim2.fromOffset(220, 40) -- unclipped reaches X=330, clipped stops at X=160 <= 240!
			clippedChild.Parent = innerClip
			Layout.within(clippedChild :: any, outer :: any, { left = 10, top = 10, right = 10, bottom = 10 })
			Layout.within(clippedChild :: any, sg :: any, 5)

			-- Fully clipped out (`maxX <= minX`) returns `nil` from `clippedBounds` and falls back to `aabbOf` in `within`,
			-- catching the runaway off-panel coordinates!
			clippedChild.Position = e.UDim2.fromOffset(250, 10)
			sert.throws(function() Layout.within(clippedChild :: any, outer :: any, 4) end, "Layout.within failed")
			outer:Destroy()

			-- 3) Layout.aligned all 6 edges + <2 elements early return + unknown edge + failure diagnostic.
			local col = e.Instance.new("Frame")
			col.Position = e.UDim2.fromOffset(20, 20)
			col.Size = e.UDim2.fromOffset(300, 240)
			col.Parent = sg

			local c1 = e.Instance.new("Frame")
			c1.Name = "CardOne"
			c1.Position = e.UDim2.fromOffset(30, 20)
			c1.Size = e.UDim2.fromOffset(120, 40)
			c1.Parent = col

			local c2 = e.Instance.new("Frame")
			c2.Name = "CardTwo"
			c2.Position = e.UDim2.fromOffset(30, 20)
			c2.Size = e.UDim2.fromOffset(120, 40)
			c2.Parent = col

			Layout.aligned({ c1 :: any }, "left")
			for _, edge in { "left", "right", "top", "bottom", "centerX", "centerY" } do
				Layout.aligned({ c1 :: any, c2 :: any }, edge :: any, 0.5)
			end
			c2.Position = e.UDim2.fromOffset(55, 80)
			sert.throws(
				function() Layout.aligned({ c1 :: any, c2 :: any }, "left", 1.0) end,
				'Layout.aligned%("left"%) failed'
			)
			sert.throws(
				function() Layout.aligned({ c1 :: any, c2 :: any }, "right", 1.0) end,
				'Layout.aligned%("right"%) failed'
			)
			sert.throws(function() Layout.aligned({ c1 :: any, c2 :: any }, "diagonal" :: any) end, "unknown edge")

			-- Recursive `noOverlap` + Instance-ref ignore.
			local nestedWrap = e.Instance.new("Frame")
			nestedWrap.Size = e.UDim2.fromOffset(100, 60)
			nestedWrap.Position = e.UDim2.fromOffset(0, 140)
			nestedWrap.Parent = col
			local n1 = e.Instance.new("Frame")
			n1.Name = "N1"
			n1.Size = e.UDim2.fromOffset(60, 40)
			n1.Parent = nestedWrap
			local n2 = e.Instance.new("Frame")
			n2.Name = "N2"
			n2.Position = e.UDim2.fromOffset(20, 0)
			n2.Size = e.UDim2.fromOffset(60, 40)
			n2.Parent = nestedWrap
			sert.throws(function() Layout.noOverlap(col :: any, { recursive = true, ignore = { c2 :: any } }) end, "N1")
			Layout.noOverlap(col :: any, { recursive = true, ignore = { c2 :: any, n2 :: any } })
			col:Destroy()

			-- 4) Layout.audit option variants (`mergeIgnore`, `UIGridLayout` inside `Folder`, `Vector2` viewport/touchTargets).
			local auditRoot = e.Instance.new("Frame")
			auditRoot.Size = e.UDim2.fromOffset(400, 300)
			auditRoot.Parent = sg

			local folder = e.Instance.new("Folder")
			folder.Parent = auditRoot
			local gridHost = e.Instance.new("Frame")
			gridHost.Size = e.UDim2.fromOffset(300, 120)
			gridHost.Parent = folder
			local grid = e.Instance.new("UIGridLayout")
			grid.CellSize = e.UDim2.fromOffset(80, 48)
			grid.CellPadding = e.UDim2.fromOffset(8, 8)
			grid.Parent = gridHost

			local gBtn = e.Instance.new("TextButton")
			gBtn.Name = "GridBtn"
			gBtn.Text = "Go"
			gBtn.TextSize = 14
			gBtn.Parent = gridHost

			local ignoredBad = e.Instance.new("TextButton")
			ignoredBad.Name = "IgnoredTiny"
			ignoredBad.Position = e.UDim2.fromOffset(950, 10) -- off-viewport + tiny + long text, ignored via merged lists!
			ignoredBad.Size = e.UDim2.fromOffset(16, 16)
			ignoredBad.TextSize = 22
			ignoredBad.Text = "Overflowing Ignored Button Label"
			ignoredBad.Parent = auditRoot

			local sharedIgnored = e.Instance.new("Frame")
			sharedIgnored.Name = "SharedOffscreen"
			sharedIgnored.Position = e.UDim2.fromOffset(920, 50)
			sharedIgnored.Size = e.UDim2.fromOffset(40, 40)
			sharedIgnored.Parent = auditRoot

			Layout.audit(auditRoot :: any, {
				settle = { maxFrames = 3, stableFrames = 2 },
				ignore = { sharedIgnored :: any },
				viewport = { viewport = e.Vector2.new(800, 600), tolerance = 1, ignore = { "IgnoredTiny" } },
				overlap = { tolerance = 1, ignore = { "IgnoredTiny" } },
				textOverflow = { tolerance = 1, ignore = { ignoredBad :: any } },
				touchTargets = { minSize = e.Vector2.new(44, 44), ignore = { "IgnoredTiny" } },
			})
			Layout.audit(auditRoot :: any, {
				settle = false,
				ignore = { sharedIgnored :: any, ignoredBad :: any },
				viewport = e.Vector2.new(800, 600),
				touchTargets = 44,
			})
			Layout.audit(auditRoot :: any, {
				settle = false,
				viewport = false,
				overlap = false,
				textOverflow = false,
				touchTargets = false,
			})

			-- 5) Layout.matrix custom `{ name, size }` preset, inline 3-arg call, error guards, and target registration.
			local checkedPresets: { string } = {}
			Layout.matrix("inline custom watch preset", function(container: Instance, _preset, env: any)
				local pill = env.Instance.new("Frame")
				pill.Size = env.UDim2.fromOffset(120, 48)
				pill.Parent = container
				return pill
			end, {
				presets = { { name = "SquareWatch", size = e.Vector2.new(240, 240) } },
				settle = false,
				audit = false,
				check = function(_root: Instance, preset) table.insert(checkedPresets, preset.name) end,
			})
			sert.eq(checkedPresets, { "SquareWatch" })

			sert.throws(function()
				Layout.matrix(function(): any return nil end, { presets = { "UnknownDevice" :: any } })
			end, "unknown device preset")
			sert.throws(function()
				Layout.matrix(function(): any return nil end, { presets = { {} :: any } })
			end, "preset entry must be")
			sert.throws(function() Layout.matrix("bad", "not_a_fn" :: any) end, "expected mount function")
			sert.throws(function() Layout.matrix(42 :: any) end, "expected mount function")

			local regRuns = 0
			local isoRes = runIsolated(function()
				local mountMini = function(container: Instance, _preset: any, env: any)
					regRuns += 1
					local f = env.Instance.new("Frame")
					f.Size = env.UDim2.fromOffset(60, 48)
					f.Parent = container
					return f
				end
				Layout.matrix("client target matrix", mountMini, { presets = { "Phone" }, target = "client" })
				Layout.matrix("roblox target matrix", mountMini, { presets = { "Phone" }, target = "roblox" })
				Layout.matrix("server target matrix", mountMini, { presets = { "Phone" }, target = "server" })
				Layout.matrix("portable target matrix", mountMini, { presets = { "Phone" } })
			end, { allTargets = true })
			sert.eq(isoRes.passed, 4)
			sert.eq(regRuns, 4)
		end
	)
end)
