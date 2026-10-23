--!strict
local Flicker = require("@self/Flicker")
local Layout = require("@self/Layout")
local Runner = require("@self/Runner")

export type Config = Runner.Config
export type Side = Runner.Side
export type Verdict = Runner.Verdict
export type Context = Runner.Context
export type Request = Runner.Request
export type Runner = Runner.Runner
export type SettleOptions = Layout.SettleOptions
export type FlickerOptions = Flicker.Options
export type FlickerResult = Flicker.Result

local roblox: {
	Runner: Runner.Runner,
	Layout: typeof(Layout),
	Flicker: typeof(Flicker),
} = {
	Runner = Runner,
	Layout = Layout,
	Flicker = Flicker,
}

return table.freeze(roblox) :: typeof(roblox)
