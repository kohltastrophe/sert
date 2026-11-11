--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local sert = require(ReplicatedStorage.sert)
local Layout = sert.roblox.Layout

sert.describe.roblox("layout geometry invariants", function()
	sert.test.roblox("detects sibling overlap and respects CanvasGroup and UIScale visibility", function()
		local sg = Instance.new("ScreenGui")
		sg.IgnoreGuiInset = true

		local container = Instance.new("Frame")
		container.Name = "Container"
		container.Size = UDim2.fromOffset(300, 200)
		container.Parent = sg

		local first = Instance.new("Frame")
		first.Name = "First"
		first.Position = UDim2.fromOffset(10, 10)
		first.Size = UDim2.fromOffset(100, 60)
		first.Parent = container

		local second = Instance.new("Frame")
		second.Name = "Second"
		second.Position = UDim2.fromOffset(50, 20)
		second.Size = UDim2.fromOffset(100, 60)
		second.Parent = container

		sert.throws(function() Layout.noOverlap(container) end, "overlaps")

		second.Position = UDim2.fromOffset(120, 10)
		sert.doesNotThrow(function() Layout.noOverlap(container) end)

		local group = Instance.new("CanvasGroup")
		group.Size = UDim2.fromOffset(80, 40)
		group.GroupTransparency = 1
		group.Parent = container
		sert.eq(Layout.geometry.visible(group), false)

		sg:Destroy()
	end)
end)
