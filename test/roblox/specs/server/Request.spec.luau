--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local sert = require(ReplicatedStorage.sert)

sert.describe.server("server coordination and relative spec paths", function()
	sert.test.server(
		"executes server-targeted tests only on the server VM",
		function() sert.ok(RunService:IsServer()) end
	)

	sert.test.roblox("executes shared roblox-targeted tests in Studio and Open Cloud", function()
		local folder = Instance.new("Folder")
		folder.Name = "SharedProbe"
		folder:SetAttribute("Version", 1)
		sert.eq(folder:GetAttribute("Version"), 1)
		folder:Destroy()
	end)
end)
