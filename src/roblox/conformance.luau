--!strict
-- Dual-target conformance harness (`sert.roblox.conformance`). Registers a portable `sert.env` run and a live
-- Roblox Studio (`roblox` / `client`) run from a single spec callback.

local registry = require("../core/registry")
local util = require("../core/util")
local Env = require("../env")

export type ConformanceTarget = "roblox" | "client"
export type ContainerKind = "workspace" | "PlayerGui"

export type ConformanceOptions = typeof(table.freeze({} :: {
	target: ConformanceTarget?,
	container: ContainerKind?,
	env: Env.Options?,
	tags: { string }?,
	timeout: number?,
	skip: boolean?,
	focus: boolean?,
}))

export type ConformanceContext = {
	isRoblox: boolean,
	target: "portable" | ConformanceTarget,
	env: Env.Env?,
	game: any,
	workspace: any,
	Instance: any,
	task: any,
	Enum: any,
	Vector2: any,
	Vector3: any,
	CFrame: any,
	UDim: any,
	UDim2: any,
	Color3: any,
	Rect: any,
	NumberRange: any,
	RaycastParams: any,
	OverlapParams: any,
	SharedTable: any,
	getService: (name: string) -> any,
	step: (seconds: number?) -> (),
}

export type ConformanceFn = (root: Instance, ctx: ConformanceContext) -> ()

export type ConformanceApi = typeof(setmetatable(
	{} :: {
		skip: (name: string, fn: ConformanceFn, opts: ConformanceOptions?) -> (),
		focus: (name: string, fn: ConformanceFn, opts: ConformanceOptions?) -> (),
	},
	{} :: { __call: (self: any, name: string, fn: ConformanceFn, opts: ConformanceOptions?) -> () }
))

local ALLOWED_OPTIONS: { [string]: boolean } = {
	target = true,
	container = true,
	env = true,
	tags = true,
	timeout = true,
	skip = true,
	focus = true,
}

local function sanitizeName(name: string): string
	local clean = string.gsub(name, "[^%w_%-]", "_")
	if #clean > 48 then clean = string.sub(clean, 1, 48) end
	return clean
end

local function makePortableContext(env: any): ConformanceContext
	local dt = env.datatypes
	return {
		isRoblox = false,
		target = "portable",
		env = env,
		game = env.game,
		workspace = env.workspace,
		Instance = env.Instance,
		task = env.task,
		Enum = env.Enum,
		Vector2 = dt.Vector2,
		Vector3 = dt.Vector3,
		CFrame = dt.CFrame,
		UDim = dt.UDim,
		UDim2 = dt.UDim2,
		Color3 = dt.Color3,
		Rect = dt.Rect,
		NumberRange = dt.NumberRange,
		RaycastParams = dt.RaycastParams,
		OverlapParams = dt.OverlapParams,
		SharedTable = env.SharedTable,
		getService = function(serviceName: string): any return env:getService(serviceName) end,
		step = function(seconds: number?) env:step(if seconds ~= nil then seconds else 1 / 60) end,
	}
end

local function makeStudioContext(target: ConformanceTarget): ConformanceContext
	local realGame: any = game
	local realWorkspace: any = workspace
	local sharedTableGlobal: any = SharedTable :: any
	return {
		isRoblox = true,
		target = target,
		env = nil,
		game = realGame,
		workspace = realWorkspace,
		Instance = Instance,
		task = task,
		Enum = Enum,
		Vector2 = Vector2,
		Vector3 = Vector3,
		CFrame = CFrame,
		UDim = UDim,
		UDim2 = UDim2,
		Color3 = Color3,
		Rect = Rect,
		NumberRange = NumberRange,
		RaycastParams = RaycastParams,
		OverlapParams = OverlapParams,
		SharedTable = sharedTableGlobal,
		getService = function(serviceName: string): any return realGame:GetService(serviceName) end,
		step = function(seconds: number?) task.wait(seconds) end,
	}
end

local function resolvePlayerGuiContainer(ctx: ConformanceContext, name: string): any
	local guiHost: any = nil
	if ctx.env ~= nil then
		local lp = ctx.env.LocalPlayer
		guiHost = if lp ~= nil then lp:FindFirstChildOfClass("PlayerGui") else ctx.env.playerGui
		if guiHost == nil then guiHost = ctx.getService("StarterGui") end
	else
		local okPlayers, players = pcall(ctx.getService, "Players")
		local lp = if okPlayers and players ~= nil then players.LocalPlayer else nil
		guiHost = if lp ~= nil then lp:FindFirstChildOfClass("PlayerGui") else nil
		if guiHost == nil then
			local okStarter, starterGui = pcall(ctx.getService, "StarterGui")
			if okStarter then guiHost = starterGui end
		end
	end
	local sg = ctx.Instance.new("ScreenGui")
	sg.Name = `sert_Conformance_{sanitizeName(name)}`
	sg.IgnoreGuiInset = true
	if ctx.isRoblox then sg.ResetOnSpawn = false end
	sg.Parent = guiHost
	return sg
end

local function createContainer(ctx: ConformanceContext, kind: ContainerKind, name: string): any
	if kind == "PlayerGui" then return resolvePlayerGuiContainer(ctx, name) end
	local folder = ctx.Instance.new("Folder")
	folder.Name = `sert_Conformance_{sanitizeName(name)}`
	folder.Parent = ctx.workspace
	return folder
end

local function runPortable(
	name: string,
	fn: ConformanceFn,
	studioTarget: ConformanceTarget,
	kind: ContainerKind,
	opts: ConformanceOptions
)
	local prevActive = registry.activeEnv()
	local envOpts: { [string]: any } = if opts.env ~= nil then table.clone(opts.env :: any) else {}
	if studioTarget == "client" then
		if envOpts.isClient == nil then envOpts.isClient = true end
		if envOpts.isServer == nil then envOpts.isServer = false end
	end
	local env = Env.new(envOpts :: any)
	registry.setActiveEnv(env)

	local container: any = nil
	local ok, err = pcall(function()
		local ctx = makePortableContext(env)
		container = createContainer(ctx, kind, name)
		fn(container :: Instance, ctx)
	end)

	pcall(function()
		if container ~= nil then container:Destroy() end
	end)
	pcall(function() env:destroy() end)
	registry.setActiveEnv(prevActive)

	if not ok then error(err, 0) end
end

local function runStudio(name: string, fn: ConformanceFn, studioTarget: ConformanceTarget, kind: ContainerKind)
	local ctx = makeStudioContext(studioTarget)
	local container: any = nil
	local ok, err = pcall(function()
		container = createContainer(ctx, kind, name)
		fn(container :: Instance, ctx)
	end)
	pcall(function()
		if container ~= nil then container:Destroy() end
	end)
	if not ok then error(err, 0) end
end

local function validateAndRegister(
	apiName: string,
	name: string,
	fn: ConformanceFn,
	opts: ConformanceOptions?,
	forcedMode: ("skip" | "focus")?
)
	if type(name) ~= "string" or name == "" then
		error(`{apiName}: expected non-empty test name, got {util.typeof(name)}`, util.outside())
	end
	if type(fn) ~= "function" then error(`{apiName}: expected callback function as second argument`, util.outside()) end
	if opts ~= nil then
		if type(opts) ~= "table" then
			error(`{apiName}: options must be a table, got {util.typeof(opts)}`, util.outside())
		end
		for k in opts :: { [any]: any } do
			if not ALLOWED_OPTIONS[k] then error(`{apiName}: unknown option '{tostring(k)}'`, util.outside()) end
		end
	end

	local resolvedOpts: ConformanceOptions = opts or {}
	local studioTarget: ConformanceTarget = if resolvedOpts.target ~= nil then resolvedOpts.target else "roblox"
	if studioTarget ~= "roblox" and studioTarget ~= "client" then
		error(`{apiName}: target must be "roblox" or "client", got {tostring(studioTarget)}`, util.outside())
	end
	local containerKind: ContainerKind = if resolvedOpts.container ~= nil then resolvedOpts.container else "workspace"
	if containerKind ~= "workspace" and containerKind ~= "PlayerGui" then
		error(`{apiName}: container must be "workspace" or "PlayerGui", got {tostring(containerKind)}`, util.outside())
	end

	local regOpts: { [string]: any } = {}
	if resolvedOpts.tags ~= nil then regOpts.tags = resolvedOpts.tags end
	if resolvedOpts.timeout ~= nil then regOpts.timeout = resolvedOpts.timeout end
	if forcedMode == "skip" or resolvedOpts.skip == true then regOpts.skip = true end
	if forcedMode == "focus" or resolvedOpts.focus == true then regOpts.focus = true end

	local portableBody = function() runPortable(name, fn, studioTarget, containerKind, resolvedOpts) end
	local studioBody = function() runStudio(name, fn, studioTarget, containerKind) end

	registry.api.test(`{name} [portable]`, portableBody, regOpts :: any)
	if studioTarget == "client" then
		registry.api.test.client(`{name} [client]`, studioBody, regOpts :: any)
	else
		registry.api.test.roblox(`{name} [roblox]`, studioBody, regOpts :: any)
	end
end

local conformance = {}

local callTable = {
	skip = function(name: string, fn: ConformanceFn, opts: ConformanceOptions?)
		validateAndRegister("sert.roblox.conformance.skip", name, fn, opts, "skip")
	end,
	focus = function(name: string, fn: ConformanceFn, opts: ConformanceOptions?)
		validateAndRegister("sert.roblox.conformance.focus", name, fn, opts, "focus")
	end,
}

conformance.api = (
	setmetatable(callTable, {
		__call = function(_self: any, name: string, fn: ConformanceFn, opts: ConformanceOptions?)
			validateAndRegister("sert.roblox.conformance", name, fn, opts, nil)
		end,
	}) :: any
) :: ConformanceApi

return conformance
