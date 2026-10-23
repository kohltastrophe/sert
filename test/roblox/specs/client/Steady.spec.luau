--!strict
-- A spec that returns a function: the runner calls it with its Context. Uses sert's Flicker on a plain Frame.
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Flicker = require(ReplicatedStorage.sert.roblox.Flicker) :: any

return function(context: any, extra: any)
	local sert = context.sert

	sert.test("context names its side", function() sert.eq(context.side, "client") end)

	sert.test(
		"config.context's second value is the second argument",
		function() sert.eq(extra.where, context.where) end
	)

	sert.rtest("a frame shown in place does not flicker", function()
		local player = Players.LocalPlayer :: Player
		local gui = Instance.new("ScreenGui")
		gui.Name = "sert.Steady"
		gui.ResetOnSpawn = false
		local frame = Instance.new("Frame")
		frame.Size = UDim2.fromOffset(100, 50)
		frame.Position = UDim2.fromOffset(40, 40)
		frame.Visible = false
		frame.Parent = gui
		gui.Parent = player:WaitForChild("PlayerGui")
		local result = Flicker.around(function() return frame end, function() frame.Visible = true end)
		gui:Destroy()
		Flicker.expect(result, "steady frame")
	end, { skip = Players.LocalPlayer == nil })
end
