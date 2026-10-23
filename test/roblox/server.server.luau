--!strict
-- The example place's server runner: does nothing in an ordinary Play session (no test arguments).
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Runner = require(ReplicatedStorage:WaitForChild("sert"):WaitForChild("roblox"):WaitForChild("Runner"))
Runner.server(require(ReplicatedStorage:WaitForChild("Tests"):WaitForChild("Config")))
