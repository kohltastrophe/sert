--!strict
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local sert = require(ReplicatedStorage.sert)
local Flicker = sert.roblox.Flicker
local Layout = sert.roblox.Layout

sert.describe.client("client UI stability and layout", function()
	sert.test.client("runs on the client VM and settles steady UI without flicker", function()
		sert.ok(RunService:IsClient())
		local playerGui = Players.LocalPlayer:WaitForChild("PlayerGui")

		local sg = Instance.new("ScreenGui")
		sg.IgnoreGuiInset = true
		sg.ResetOnSpawn = false
		sg.Parent = playerGui

		local card = Instance.new("Frame")
		card.Name = "SteadyCard"
		card.Size = UDim2.fromOffset(220, 80)
		card.Position = UDim2.fromOffset(24, 24)
		card.Parent = sg

		local result = Flicker.steady(card, { stableFrames = 3, maxFrames = 20 })
		sert.eq(result.ok, true)
		Layout.visible(card)
		Layout.fitsViewport(sg)
	end)

	sert.test.client("audits responsive UI across standard device presets", function()
		Layout.matrix(function(container)
			local list = Instance.new("Frame")
			list.Name = "Toolbar"
			list.Size = UDim2.new(1, -16, 0, 56)
			list.Position = UDim2.fromOffset(8, 8)
			list.Parent = container

			local layout = Instance.new("UIListLayout")
			layout.FillDirection = Enum.FillDirection.Horizontal
			layout.Padding = UDim.new(0, 8)
			layout.Parent = list

			for i = 1, 2 do
				local btn = Instance.new("TextButton")
				btn.Name = `Action{i}`
				btn.Size = UDim2.fromOffset(120, 48)
				btn.Text = `Item {i}`
				btn.TextScaled = true
				btn.Parent = list
			end

			return list
		end, {
			presets = { "Phone", "SmallPhone", "Tablet", "Desktop" },
			audit = { touchTargets = 44 },
		})
	end)
end)
