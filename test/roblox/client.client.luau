--!strict
-- The example place's client runner, from ReplicatedFirst: waits for the server to hand it the run.
local ReplicatedStorage = game:GetService("ReplicatedStorage")

if not game:IsLoaded() then game.Loaded:Wait() end
local Runner = require(ReplicatedStorage:WaitForChild("sert"):WaitForChild("roblox"):WaitForChild("Runner"))
Runner.client(require(ReplicatedStorage:WaitForChild("Tests"):WaitForChild("Config")))
