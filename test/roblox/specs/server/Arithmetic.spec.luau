--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local sert = require(ReplicatedStorage.sert)

sert.describe.server("server runtime, sweep, and remote fuzzing", function()
	sert.test.server("creates a Workspace Part that automatic sweep cleans up afterward", function()
		local marker = Instance.new("Part")
		marker.Name = "sert_SweepProbePart"
		marker.Anchored = true
		marker.Parent = Workspace
		sert.ne(Workspace:FindFirstChild("sert_SweepProbePart"), nil)
	end)

	sert.test.server(
		"starts with Workspace clean after previous test swept",
		function() sert.eq(Workspace:FindFirstChild("sert_SweepProbePart"), nil) end
	)

	sert.prop.server("addition commutes on the server VM", function(g: any)
		local a: number = g:int(-10000, 10000)
		local b: number = g:int(-10000, 10000)
		sert.eq(a + b, b + a)
	end)

	sert.roblox.fuzzRemote("inventory buy handler rejects adversarial payloads safely", {
		target = "server",
		runs = 50,
		handler = function(player: any, payload: any)
			if type(payload) ~= "table" then return false end
			local qty = payload.quantity
			if type(qty) ~= "number" or qty ~= qty or math.abs(qty) == math.huge then return false end
			if qty <= 0 or qty ~= math.floor(qty) or qty > 99 then return false end
			local itemId = payload.itemId
			if type(itemId) ~= "string" or #itemId == 0 or #itemId > 64 then return false end
			player._lastPurchase = { itemId = itemId, quantity = qty }
			return true
		end,
		checkState = function(player: any)
			local last = player._lastPurchase
			if last ~= nil then
				sert.eq(type(last.itemId), "string")
				sert.ge(last.quantity, 1)
				sert.le(last.quantity, 99)
			end
		end,
	})
end)
