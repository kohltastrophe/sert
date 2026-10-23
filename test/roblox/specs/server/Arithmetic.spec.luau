--!strict
-- A plain spec: registers at top level.
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local sert = require(ReplicatedStorage.sert) :: any

sert.test("adds", function() sert.expect(1 + 1).toBe(2) end)

sert.prop("addition commutes", function(g: any)
	local a, b = g:int(-100, 100), g:int(-100, 100)
	sert.eq(a + b, b + a)
end, { runs = 50 })

sert.rtest("runs on the server in play mode", function()
	local RunService = game:GetService("RunService")
	sert(RunService:IsServer() or not RunService:IsRunning(), "a server, or edit mode")
end)

return {}
