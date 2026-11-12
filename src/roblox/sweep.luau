--!strict
-- Automatic per-test DataModel instance sweeper (`sert.roblox.sweep`). Snapshots `Workspace`, `Lighting`,
-- `SoundService`, `ReplicatedStorage`, and `LocalPlayer.PlayerGui` before a test and destroys new instances in LIFO order.

local registry = require("../core/registry")

export type SweepOptions = {
	gameRoot: any?,
	exclude: { Instance }?,
}

export type Snapshot = {
	roots: { Instance },
	keep: { [Instance]: boolean },
	excluded: { [Instance]: boolean },
	created: { Instance },
	connections: { RBXScriptConnection },
}

local STATIC_RS_CONTAINERS: { [string]: boolean } = {
	sert = true,
	Packages = true,
	DevPackages = true,
	ServerPackages = true,
	Tests = true,
	Specs = true,
	["sert.Request"] = true,
	["sert.Result"] = true,
}

local sweep = {}

local function resolveGameRoot(explicit: any?): any?
	if explicit ~= nil then return explicit end
	local activeEnv = registry.activeEnv()
	if activeEnv ~= nil and activeEnv.game ~= nil then return activeEnv.game end
	local realGame: any = if typeof(game) == "Instance" then game else nil
	return realGame
end

local function safeGetService(gameRoot: any, serviceName: string): Instance?
	local ok, svc = pcall(function() return gameRoot:GetService(serviceName) end)
	if ok and svc ~= nil then return svc end
	return nil
end

local function isUnderExcluded(inst: Instance, excluded: { [Instance]: boolean }): boolean
	local cur: Instance? = inst
	while cur ~= nil do
		if excluded[cur] then return true end
		local ok, parent = pcall(function() return (cur :: Instance).Parent end)
		cur = if ok then parent else nil
	end
	return false
end

local function collectExisting(root: Instance, keep: { [Instance]: boolean }, excluded: { [Instance]: boolean })
	keep[root] = true
	local ok, children = pcall(function() return root:GetChildren() end)
	if not ok or type(children) ~= "table" then return end
	for _, child in children do
		if not excluded[child] then
			keep[child] = true
			collectExisting(child, keep, excluded)
		end
	end
end

local function collectStragglers(
	node: Instance,
	keep: { [Instance]: boolean },
	excluded: { [Instance]: boolean },
	out: { Instance }
)
	local ok, children = pcall(function() return node:GetChildren() end)
	if not ok or type(children) ~= "table" then return end
	for _, child in children do
		if not excluded[child] then
			if not keep[child] then
				table.insert(out, child)
			else
				collectStragglers(child, keep, excluded, out)
			end
		end
	end
end

--- Captures pre-test instances across `Workspace`, `Lighting`, `SoundService`, `ReplicatedStorage`, and `PlayerGui`.
function sweep.snapshot(options: SweepOptions?): Snapshot
	local opts: SweepOptions = options or {}
	local gameRoot = resolveGameRoot(opts.gameRoot)
	local roots: { Instance } = {}
	local keep: { [Instance]: boolean } = {}
	local excluded: { [Instance]: boolean } = {}
	local created: { Instance } = {}
	local connections: { RBXScriptConnection } = {}

	if opts.exclude ~= nil then
		for _, ex in opts.exclude do
			excluded[ex] = true
		end
	end

	if gameRoot == nil then
		return {
			roots = roots,
			keep = keep,
			excluded = excluded,
			created = created,
			connections = connections,
		}
	end

	local ws = safeGetService(gameRoot, "Workspace")
	if ws ~= nil then
		table.insert(roots, ws)
		local okTerrain, terrain = pcall(function() return (ws :: any).Terrain end)
		if okTerrain and terrain ~= nil then keep[terrain] = true end
		local okCam, cam = pcall(function() return (ws :: any).CurrentCamera end)
		if okCam and cam ~= nil then keep[cam] = true end
	end

	local lighting = safeGetService(gameRoot, "Lighting")
	if lighting ~= nil then table.insert(roots, lighting) end

	local sound = safeGetService(gameRoot, "SoundService")
	if sound ~= nil then table.insert(roots, sound) end

	local rs = safeGetService(gameRoot, "ReplicatedStorage")
	if rs ~= nil then
		table.insert(roots, rs)
		local okCh, rsChildren = pcall(function() return rs:GetChildren() end)
		if okCh and type(rsChildren) == "table" then
			for _, ch in rsChildren do
				if STATIC_RS_CONTAINERS[ch.Name] then excluded[ch] = true end
			end
		end
	end

	local players = safeGetService(gameRoot, "Players")
	if players ~= nil then
		local okLp, lp = pcall(function() return (players :: any).LocalPlayer end)
		if okLp and lp ~= nil then
			local okPg, pg = pcall(function() return lp:FindFirstChildOfClass("PlayerGui") end)
			if okPg and pg ~= nil then table.insert(roots, pg) end
		end
	end

	for _, root in roots do
		collectExisting(root, keep, excluded)
		local okConn, conn: RBXScriptConnection? = pcall(function()
			return root.DescendantAdded:Connect(function(inst: Instance)
				if not keep[inst] and not isUnderExcluded(inst, excluded) then table.insert(created, inst) end
			end)
		end)
		if okConn and conn ~= nil then table.insert(connections, conn) end
	end

	return {
		roots = roots,
		keep = keep,
		excluded = excluded,
		created = created,
		connections = connections,
	}
end

--- Destroys all instances created since `snap` in LIFO order and returns the count destroyed.
function sweep.restore(snap: Snapshot): number
	for _, conn in snap.connections do
		pcall(function() conn:Disconnect() end)
	end
	table.clear(snap.connections)

	local destroyed = 0

	-- Destroy tracked `DescendantAdded` instances in strict LIFO order.
	for i = #snap.created, 1, -1 do
		local inst = snap.created[i]
		if not snap.keep[inst] and not isUnderExcluded(inst, snap.excluded) then
			pcall(function()
				if inst.Parent ~= nil then
					inst:Destroy()
					destroyed += 1
				end
			end)
		end
	end

	-- Catch any reparented instances not already destroyed.
	local stragglers: { Instance } = {}
	for _, root in snap.roots do
		collectStragglers(root, snap.keep, snap.excluded, stragglers)
	end
	for i = #stragglers, 1, -1 do
		local inst = stragglers[i]
		pcall(function()
			if inst.Parent ~= nil then
				inst:Destroy()
				destroyed += 1
			end
		end)
	end

	return destroyed
end

--- Runs `fn()` and restores the DataModel snapshot afterward even if `fn()` throws.
function sweep.around(fn: () -> (), options: SweepOptions?)
	local snap = sweep.snapshot(options)
	local ok, err = pcall(fn :: () -> ...any)
	sweep.restore(snap)
	if not ok then error(err, 0) end
end

return sweep
