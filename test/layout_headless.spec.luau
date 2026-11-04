--!strict
-- Headless UI layout engine (`src/doubles/instance.luau`), `sert.env` viewport/ProximityPrompt helpers,
-- and `sert.roblox.Layout` high-signal invariant assertions.

local sert = require("../src")
local Layout = sert.roblox.Layout
local V2 = sert.doubles.Datatypes.Vector2
local describe, it, expect = sert.describe, sert.test, sert.expect

describe("Headless UI Layout Engine & Layout Invariants", function()
	it(
		"computes UIListLayout vertical, horizontal, Padding, Wraps, alignments, SortOrder, and AbsoluteContentSize",
		function()
			local env = sert.env.new({ isClient = true, viewport = V2.new(800, 600) })
			local g = env.globals
			local screen = env.Instance.new("ScreenGui", env.playerGui)
			local container = env.Instance.new("Frame", screen)
			container.Size = g.UDim2.fromOffset(400, 300)
			container.Position = g.UDim2.fromOffset(50, 40)

			local list = env.Instance.new("UIListLayout", container)
			list.Padding = g.UDim.new(0, 10)
			list.SortOrder = g.Enum.SortOrder.LayoutOrder

			local a = env.Instance.new("Frame", container)
			a.Name = "B_Item"
			a.LayoutOrder = 2
			a.Size = g.UDim2.fromOffset(100, 40)

			local b = env.Instance.new("Frame", container)
			b.Name = "A_Item"
			b.LayoutOrder = 1
			b.Size = g.UDim2.fromOffset(120, 30)

			-- b (LayoutOrder 1) comes first at y=40, then a (LayoutOrder 2) at y=40+30+10=80
			expect(b.AbsolutePosition).toEqual(g.Vector2.new(50, 40))
			expect(a.AbsolutePosition).toEqual(g.Vector2.new(50, 80))
			expect(list.AbsoluteContentSize).toEqual(g.Vector2.new(120, 80))

			-- Switch to SortOrder.Name: A_Item then B_Item, Center horizontal alignment, Bottom vertical alignment
			list.SortOrder = g.Enum.SortOrder.Name
			list.HorizontalAlignment = g.Enum.HorizontalAlignment.Center
			list.VerticalAlignment = g.Enum.VerticalAlignment.Bottom
			expect(b.AbsolutePosition).toEqual(g.Vector2.new(50 + (400 - 120) * 0.5, 40 + (300 - 80)))
			expect(a.AbsolutePosition).toEqual(g.Vector2.new(50 + (400 - 100) * 0.5, 40 + (300 - 80) + 40))

			-- Horizontal fill with Wraps = true
			list.FillDirection = g.Enum.FillDirection.Horizontal
			list.HorizontalAlignment = g.Enum.HorizontalAlignment.Left
			list.VerticalAlignment = g.Enum.VerticalAlignment.Top
			list.Wraps = true
			a.Size = g.UDim2.fromOffset(250, 40)
			b.Size = g.UDim2.fromOffset(200, 30)
			-- b is first (200px wide), a (250px) wraps to line 2 at y = 40 + 30 + 10 = 80
			expect(b.AbsolutePosition).toEqual(g.Vector2.new(50, 40))
			expect(a.AbsolutePosition).toEqual(g.Vector2.new(50, 80))
			expect(list.AbsoluteContentSize).toEqual(g.Vector2.new(250, 80))
		end
	)

	it("computes UIGridLayout cells, CellPadding, FillDirectionMaxCells, and AbsoluteContentSize", function()
		local env = sert.env.new({ isClient = true })
		local g = env.globals
		local screen = env.Instance.new("ScreenGui", env.playerGui)
		local container = env.Instance.new("Frame", screen)
		container.Size = g.UDim2.fromOffset(250, 250)
		container.Position = g.UDim2.fromOffset(10, 20)

		local grid = env.Instance.new("UIGridLayout", container)
		grid.CellSize = g.UDim2.fromOffset(100, 50)
		grid.CellPadding = g.UDim2.fromOffset(10, 15)
		grid.FillDirectionMaxCells = 2

		local cells = {}
		for i = 1, 3 do
			local c = env.Instance.new("Frame", container)
			c.Name = `Cell{i}`
			c.LayoutOrder = i
			cells[i] = c
		end

		expect(cells[1].AbsoluteSize).toEqual(g.Vector2.new(100, 50))
		expect(cells[1].AbsolutePosition).toEqual(g.Vector2.new(10, 20))
		expect(cells[2].AbsolutePosition).toEqual(g.Vector2.new(120, 20))
		expect(cells[3].AbsolutePosition).toEqual(g.Vector2.new(10, 85))
		expect(grid.AbsoluteContentSize).toEqual(g.Vector2.new(210, 115))
		Layout.noOverlap(container)
	end)

	it("applies UIPadding, UIScale, UISizeConstraint, and UIAspectRatioConstraint", function()
		local env = sert.env.new({ isClient = true })
		local g = env.globals
		local screen = env.Instance.new("ScreenGui", env.playerGui)
		local parent = env.Instance.new("Frame", screen)
		parent.Size = g.UDim2.fromOffset(300, 200)
		parent.Position = g.UDim2.fromOffset(20, 30)

		local pad = env.Instance.new("UIPadding", parent)
		pad.PaddingLeft = g.UDim.new(0, 10)
		pad.PaddingRight = g.UDim.new(0, 20)
		pad.PaddingTop = g.UDim.new(0, 15)
		pad.PaddingBottom = g.UDim.new(0, 25)

		local child = env.Instance.new("Frame", parent)
		child.Size = g.UDim2.fromScale(1, 1)
		expect(child.AbsolutePosition).toEqual(g.Vector2.new(30, 45))
		expect(child.AbsoluteSize).toEqual(g.Vector2.new(270, 160))

		local sizeCon = env.Instance.new("UISizeConstraint", child)
		sizeCon.MaxSize = g.Vector2.new(200, 150)
		expect(child.AbsoluteSize).toEqual(g.Vector2.new(200, 150))

		local aspect = env.Instance.new("UIAspectRatioConstraint", child)
		aspect.AspectRatio = 2
		expect(child.AbsoluteSize).toEqual(g.Vector2.new(200, 100))
		Layout.aspectRatio(child, 2)

		local scale = env.Instance.new("UIScale", child)
		scale.Scale = 0.5
		expect(child.AbsoluteSize).toEqual(g.Vector2.new(100, 50))
	end)

	it("expands containers with AutomaticSize and ScrollingFrame AutomaticCanvasSize", function()
		local env = sert.env.new({ isClient = true })
		local g = env.globals
		local screen = env.Instance.new("ScreenGui", env.playerGui)

		local autoFrame = env.Instance.new("Frame", screen)
		autoFrame.Size = g.UDim2.fromOffset(0, 0)
		autoFrame.AutomaticSize = g.Enum.AutomaticSize.XY
		local pad = env.Instance.new("UIPadding", autoFrame)
		pad.PaddingLeft = g.UDim.new(0, 8)
		pad.PaddingRight = g.UDim.new(0, 8)
		pad.PaddingTop = g.UDim.new(0, 6)
		pad.PaddingBottom = g.UDim.new(0, 6)
		local list = env.Instance.new("UIListLayout", autoFrame)
		list.Padding = g.UDim.new(0, 4)

		local r1 = env.Instance.new("Frame", autoFrame)
		r1.Size = g.UDim2.fromOffset(100, 20)
		local r2 = env.Instance.new("Frame", autoFrame)
		r2.Size = g.UDim2.fromOffset(140, 30)

		expect(autoFrame.AbsoluteSize).toEqual(g.Vector2.new(140 + 16, 20 + 4 + 30 + 12))

		local scroll = env.Instance.new("ScrollingFrame", screen)
		scroll.Size = g.UDim2.fromOffset(200, 100)
		scroll.CanvasSize = g.UDim2.fromOffset(0, 0)
		scroll.AutomaticCanvasSize = g.Enum.AutomaticSize.Y
		local sList = env.Instance.new("UIListLayout", scroll)
		sList.Padding = g.UDim.new(0, 10)
		for i = 1, 5 do
			local item = env.Instance.new("Frame", scroll)
			item.Name = `Item{i}`
			item.Size = g.UDim2.fromOffset(180, 40)
		end
		expect(scroll.AbsoluteCanvasSize).toEqual(g.Vector2.new(0, 5 * 40 + 4 * 10))
		for _, child in scroll:GetChildren() do
			if child:IsA("GuiObject") then Layout.fitsParent(child) end
		end
	end)

	it("estimates TextBounds and TextFits for plain, RichText, wrapped, and TextScaled labels", function()
		local env = sert.env.new({ isClient = true })
		local g = env.globals
		local screen = env.Instance.new("ScreenGui", env.playerGui)

		local lbl = env.Instance.new("TextLabel", screen)
		lbl.Size = g.UDim2.fromOffset(200, 40)
		lbl.TextSize = 20
		lbl.Text = "Hello"
		-- 5 chars * 20 * 0.55 = 55, height = ceil(20 * 1.2) = 24
		expect(lbl.TextBounds).toEqual(g.Vector2.new(55, 24))
		expect(lbl.TextFits).toBe(true)

		lbl.RichText = true
		lbl.Text = "<b><font color='#ff0000'>Hello</font></b>"
		expect(lbl.ContentText).toBe("Hello")
		expect(lbl.TextBounds).toEqual(g.Vector2.new(55, 24))
		expect(lbl.TextFits).toBe(true)

		-- Overflow when unwrapped text is wider than box
		lbl.RichText = false
		lbl.Size = g.UDim2.fromOffset(60, 24)
		lbl.Text = "Hello world from sert layout engine"
		expect(lbl.TextFits).toBe(false)
		expect(function() Layout.noTextOverflow(screen) end).toThrow("noTextOverflow")

		-- Wrapping into a taller box makes it fit
		lbl.Size = g.UDim2.fromOffset(120, 200)
		lbl.TextWrapped = true
		expect(lbl.TextBounds.X <= 120).toBe(true)
		expect(lbl.TextBounds.Y > 24).toBe(true)
		expect(lbl.TextFits).toBe(true)
		Layout.noTextOverflow(screen)

		-- TextScaled scales down to fit a small box
		local scaled = env.Instance.new("TextButton", screen)
		scaled.Position = g.UDim2.fromOffset(0, 220)
		scaled.Size = g.UDim2.fromOffset(80, 30)
		scaled.TextSize = 36
		scaled.TextScaled = true
		scaled.Text = "Compact Button"
		expect(scaled.TextFits).toBe(true)
		Layout.noTextOverflow(screen)
	end)

	it("catches sibling overlap, parent overflow, viewport overflow, and passes clean Layout.audit", function()
		local env = sert.env.new({ isClient = true, viewport = V2.new(400, 300) })
		local g = env.globals
		local screen = env.Instance.new("ScreenGui", env.playerGui)

		local cardA = env.Instance.new("Frame", screen)
		cardA.Name = "CardA"
		cardA.Position = g.UDim2.fromOffset(20, 20)
		cardA.Size = g.UDim2.fromOffset(100, 80)

		local cardB = env.Instance.new("Frame", screen)
		cardB.Name = "CardB"
		cardB.Position = g.UDim2.fromOffset(60, 40)
		cardB.Size = g.UDim2.fromOffset(100, 80)

		expect(function() Layout.noOverlap(screen) end).toThrow("Layout.noOverlap")

		-- Move cardB so it no longer overlaps cardA
		cardB.Position = g.UDim2.fromOffset(140, 20)
		Layout.noOverlap(screen)

		-- Child overflowing its parent
		local badChild = env.Instance.new("Frame", cardA)
		badChild.Name = "OverflowChild"
		badChild.Position = g.UDim2.fromOffset(50, 10)
		badChild.Size = g.UDim2.fromOffset(80, 40)
		expect(function() Layout.fitsParent(badChild) end).toThrow("Layout.fitsParent")

		badChild.Position = g.UDim2.fromOffset(10, 10)
		Layout.fitsParent(badChild)

		-- Node overflowing viewport
		cardB.Position = g.UDim2.fromOffset(350, 20)
		expect(function() Layout.fitsViewport(screen) end).toThrow("Layout.fitsViewport")

		cardB.Position = g.UDim2.fromOffset(140, 20)
		Layout.audit(screen, { fitsParent = true })

		-- Resize viewport small enough that cardB overflows
		env:setViewport(g.Vector2.new(200, 150))
		expect(function() Layout.audit(screen) end).toThrow("Layout.fitsViewport")
	end)
end)

return {}
