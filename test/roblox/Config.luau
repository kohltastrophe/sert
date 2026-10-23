--!strict
--[[
	The example place's runner configuration, shared by the server and client scripts (and an edit-mode driver).
	`specs/server` runs on the server and `specs/client` on the client in a play session, and `specs/overlap` on the
	server once the client has its request, alongside it (`concurrent`). All three run on the server in run mode and in
	the edit DataModel in edit mode.
]]
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Runner = require(ReplicatedStorage.sert.roblox.Runner)
local specs = ReplicatedStorage:WaitForChild("Tests"):WaitForChild("specs")

local config: Runner.Config = {
	name = "sert example",
	sides = {
		server = { root = specs:WaitForChild("server") },
		client = { root = specs:WaitForChild("client") },
		overlap = { root = specs:WaitForChild("overlap"), where = "server", concurrent = true },
	},
	characters = false,
	scriptErrors = true,
	randomSeed = true,
	-- Each value is one argument of a spec that returns a function: (ctx, extra), as a repository hands its specs
	-- `(t, context)`.
	context = function(ctx: Runner.Context): (Runner.Context, { where: string }) return ctx, { where = ctx.where } end,
}

return config
