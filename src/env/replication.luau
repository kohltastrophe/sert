--!strict
-- Automatic Server -> Client DataModel replication for `ReplicatedStorage`, `Workspace` and `Players`: a server env
-- mirrors its replicated subtrees into every attached client env (`_syncClient`, `_syncChildInto`) and keeps them in
-- sync through the Instance double's hooks (`_onReparent`, `_onPropChange`, `_onAttrSet`, `onTagChange`,
-- `_onDestroy`). Client envs resolve children of mounted server nodes on demand (`_resolveMountedServerChild`).

local SKIP_REPLICATED_PROPS: { [string]: boolean } = {
	ClassName = true,
	Parent = true,
	Backpack = true,
	PlayerGui = true,
	StarterGear = true,
	CurrentCamera = true,
	Terrain = true,
	LocalPlayer = true,
	AbsoluteSize = true,
	AbsolutePosition = true,
	AbsoluteRotation = true,
	AbsoluteCanvasSize = true,
	AbsoluteWindowSize = true,
	TextBounds = true,
	TextFits = true,
	ContentText = true,
	OnServerInvoke = true,
	OnClientInvoke = true,
	OnInvoke = true,
	ShouldDeliverCallback = true,
	OnIncomingMessage = true,
}

local function liveMirror(srvInst: any, cliInst: any): boolean
	return type(srvInst) == "table"
		and srvInst._props ~= nil
		and not rawget(srvInst, "_destroyed")
		and not rawget(cliInst, "_destroyed")
end

local function pairMirror(cliEnv: any, srvNode: any, cliNode: any)
	cliEnv._mirrorOf[srvNode], cliEnv._sourceOf[cliNode] = cliNode, srvNode
end

local function resolveMirrorNode(
	srvInst: any,
	cliParent: any?,
	cliEnv: any,
	upgradePlayer: (any, any) -> any
): (any, boolean)
	local cliInst = cliEnv._mirrorOf[srvInst]
	if cliInst ~= nil and rawget(cliInst, "_destroyed") ~= true then return cliInst, true end
	local existed = false
	local className, name = srvInst._props.ClassName, srvInst._props.Name
	if className == "Player" and cliParent == cliEnv.Players then
		for _, child in cliEnv.Players:GetChildren() do
			if child.ClassName == "Player" and child.UserId == srvInst.UserId then
				cliInst = child
				existed = true
				break
			end
		end
		if cliInst == nil then
			cliInst = upgradePlayer(cliEnv, {
				UserId = srvInst.UserId,
				Name = name,
				DisplayName = srvInst.DisplayName or name,
				AccountAge = srvInst.AccountAge or 365,
			})
		end
	else
		if cliParent ~= nil then
			for _, child in rawget(cliParent, "_children") or {} do
				if
					child._props.Name == name
					and child._props.ClassName == className
					and cliEnv._sourceOf[child] == nil
				then
					cliInst = child
					existed = true
					break
				end
			end
		end
		if cliInst == nil then cliInst = cliEnv.createInstance(className, nil, true) end
	end
	pairMirror(cliEnv, srvInst, cliInst)
	return cliInst, existed
end

local function setReplicatedProp(cliInst: any, key: string, value: any)
	if cliInst._props[key] == value then return end
	rawset(cliInst, "_replicating", true)
	local ok, err = pcall(function() cliInst[key] = value end)
	rawset(cliInst, "_replicating", nil)
	if not ok then error(err, 0) end
end

local function copyScalarPropsAndMeta(
	srvInst: any,
	cliInst: any,
	cliEnv: any,
	customTypeof: (any) -> string,
	existed: boolean
)
	for k, cliVal in table.clone(cliInst._props :: { [string]: any }) do
		if not SKIP_REPLICATED_PROPS[k] and string.byte(k, 1) ~= 95 and srvInst._props[k] == nil then
			if customTypeof(cliVal) == "Instance" then
				if existed then
					setReplicatedProp(cliInst, k, nil)
				else
					cliInst._props[k] = nil
				end
			elseif existed then
				local srvVal = srvInst[k]
				if srvVal ~= nil then
					setReplicatedProp(cliInst, k, srvVal)
				elseif not cliEnv.strict then
					setReplicatedProp(cliInst, k, nil)
				end
			end
		end
	end
	for k, v in srvInst._props do
		if not SKIP_REPLICATED_PROPS[k] and string.byte(k, 1) ~= 95 and type(v) ~= "function" then
			local kind = customTypeof(v)
			if kind ~= "Instance" and kind ~= "RBXScriptSignal" and (type(v) ~= "table" or kind ~= "table") then
				if existed or k == "Text" or k == "TextSize" then
					setReplicatedProp(cliInst, k, v)
				else
					cliInst._props[k] = v
				end
			end
		end
	end

	local mountPath = rawget(srvInst, "_mountPath")
	if mountPath ~= nil then
		rawset(cliInst, "_mountPath", mountPath)
		cliEnv._mountedByPath[mountPath] = cliInst
	end
	for _, field in { "_loader", "_factory" } do
		if rawget(srvInst, field) ~= nil then rawset(cliInst, field, rawget(srvInst, field)) end
	end

	local srvAttrs, cliAttrs = rawget(srvInst, "_attributes"), rawget(cliInst, "_attributes")
	if cliAttrs ~= nil then
		for attr in table.clone(cliAttrs) do
			if srvAttrs == nil or srvAttrs[attr] == nil then cliInst:SetAttribute(attr, nil) end
		end
	end
	if srvAttrs ~= nil then
		for attr, val in srvAttrs do
			if customTypeof(val) ~= "Instance" then cliInst:SetAttribute(attr, val) end
		end
	end
	local srvTags, cliTags = rawget(srvInst, "_tags"), rawget(cliInst, "_tags")
	if cliTags ~= nil then
		for tag in table.clone(cliTags) do
			if srvTags == nil or not srvTags[tag] then cliInst:RemoveTag(tag) end
		end
	end
	if srvTags ~= nil then
		for tag in srvTags do
			cliInst:AddTag(tag)
		end
	end
end

type Replicator = {
	env: any,
	ctx: any,
	refHolders: { [any]: { [any]: boolean } },
}

local function isReplicatedOnServer(rep: Replicator, srvInst: any): boolean
	local ctx = rep.ctx
	if srvInst == ctx.cameraInst then return false end
	local gameInst = ctx.gameInst
	local cur, top: any = srvInst, nil
	while cur ~= nil and cur ~= gameInst do
		top, cur = cur, rawget(cur, "_parent")
	end
	return cur == gameInst and (top == ctx.replicatedStorage or top == ctx.workspaceInst or top == ctx.playersInst)
end

local function noteRef(rep: Replicator, holder: any, target: any)
	local set = rep.refHolders[target]
	if set == nil then
		set = setmetatable({}, { __mode = "k" }) :: any
		rep.refHolders[target] = set
	end
	set[holder] = true
end

-- Maps srvInst's Instance-valued properties and attributes onto cliInst through cliEnv._mirrorOf, writing only
-- mirrored targets that differ. `syncing` (from syncSubtree) also records each reference in refHolders and
-- clears an attribute whose target is not mirrored yet.
local function remapRefs(rep: Replicator, srvInst: any, cliInst: any, cliEnv: any, syncing: boolean, existed: boolean?)
	local customTypeof = rep.ctx.typeof
	local mirrorOf = cliEnv._mirrorOf
	for k, v in srvInst._props do
		if not SKIP_REPLICATED_PROPS[k] and customTypeof(v) == "Instance" then
			local mapped = if isReplicatedOnServer(rep, v) then mirrorOf[v] else nil
			if syncing then
				noteRef(rep, srvInst, v)
				if existed then
					setReplicatedProp(cliInst, k, mapped)
				else
					cliInst._props[k] = mapped
				end
			elseif mapped ~= nil and cliInst._props[k] ~= mapped then
				setReplicatedProp(cliInst, k, mapped)
			end
		end
	end
	local srvAttrs = rawget(srvInst, "_attributes")
	if srvAttrs ~= nil then
		for attr, val in srvAttrs do
			if customTypeof(val) == "Instance" then
				local mapped = if isReplicatedOnServer(rep, val) then mirrorOf[val] else nil
				if syncing then
					noteRef(rep, srvInst, val)
					cliInst:SetAttribute(attr, mapped)
				elseif mapped ~= nil and cliInst:GetAttribute(attr) ~= mapped then
					cliInst:SetAttribute(attr, mapped)
				end
			end
		end
	end
end

local function clearRefsToNode(rep: Replicator, cliEnv: any, srvNode: any)
	local cliTarget = cliEnv._mirrorOf[srvNode]
	if cliTarget ~= nil then
		local holders = rep.refHolders[srvNode]
		if holders ~= nil then
			for holder in holders do
				local cliHolder = cliEnv._mirrorOf[holder]
				if cliHolder ~= nil and liveMirror(holder, cliHolder) then
					for k, v in cliHolder._props do
						if not SKIP_REPLICATED_PROPS[k] and v == cliTarget then setReplicatedProp(cliHolder, k, nil) end
					end
					local cliAttrs = rawget(cliHolder, "_attributes")
					if cliAttrs ~= nil then
						for attr, val in table.clone(cliAttrs) do
							if val == cliTarget then cliHolder:SetAttribute(attr, nil) end
						end
					end
				end
			end
		end
	end
	local children = rawget(srvNode, "_children")
	if children ~= nil then
		for _, child in children do
			clearRefsToNode(rep, cliEnv, child)
		end
	end
end

-- Every server node syncSubtree (re)mirrors is appended to `touched` (when given), so references to those nodes
-- can be resolved afterwards without rescanning the whole mirror.
local function syncSubtree(rep: Replicator, srvInst: any, cliEnv: any, touched: { any }?): any
	local ctx = rep.ctx
	if srvInst == ctx.cameraInst then return nil end
	local srvParent = rawget(srvInst, "_parent")
	local cliParent = if srvParent ~= nil then cliEnv._mirrorOf[srvParent] else nil
	if srvParent ~= nil and cliParent == nil and isReplicatedOnServer(rep, srvParent) then
		cliParent = syncSubtree(rep, srvParent, cliEnv, touched)
	end

	local cliInst, existed = resolveMirrorNode(srvInst, cliParent, cliEnv, ctx.upgradePlayer)
	if touched ~= nil then table.insert(touched, srvInst) end

	copyScalarPropsAndMeta(srvInst, cliInst, cliEnv, ctx.typeof, existed)

	if cliInst._props.ClassName == "Player" then
		for _, propName in { "Backpack", "PlayerGui", "StarterGear" } do
			local srvCont, cliCont = srvInst._props[propName], cliInst._props[propName]
			if srvCont ~= nil and cliCont ~= nil then
				pairMirror(cliEnv, srvCont, cliCont)
				if touched ~= nil then table.insert(touched, srvCont) end
			end
		end
	end

	-- Sync children first so Instance-valued properties (e.g. Model.PrimaryPart) resolve in _mirrorOf
	local children = rawget(srvInst, "_children")
	if children ~= nil then
		for _, child in children do
			syncSubtree(rep, child, cliEnv, touched)
		end
	end
	remapRefs(rep, srvInst, cliInst, cliEnv, true, existed)
	ctx.ensureRemoteBound(cliInst)
	if rawget(cliInst, "_parent") ~= cliParent then cliInst.Parent = cliParent end
	return cliInst
end

local function resolveRefsTo(rep: Replicator, cliEnv: any, touched: { any })
	local mirrorOf = cliEnv._mirrorOf
	local seen: { [any]: boolean } = {}
	for _, target in touched do
		local holders = rep.refHolders[target]
		if holders ~= nil then
			for holder in holders do
				if not seen[holder] then
					seen[holder] = true
					local cliHolder = mirrorOf[holder]
					if cliHolder ~= nil and liveMirror(holder, cliHolder) then
						remapRefs(rep, holder, cliHolder, cliEnv, false)
					end
				end
			end
		end
	end
end

local function attachServerHooks(rep: Replicator)
	local env, ctx = rep.env, rep.ctx
	local customTypeof = ctx.typeof

	local function eachMirroredClient(srvInst: any, checkReplicated: boolean, fn: (cliEnv: any, cliInst: any) -> ())
		local envs = ctx.getAttachedClientEnvs()
		if #envs == 0 or (checkReplicated and not isReplicatedOnServer(rep, srvInst)) then return end
		for _, cliEnv in envs do
			local cliInst = cliEnv._mirrorOf[srvInst]
			if cliInst ~= nil and not rawget(cliInst, "_destroyed") then fn(cliEnv, cliInst) end
		end
	end

	env._onReparent = function(srvInst: any, newSrvParent: any?)
		for _, cliEnv in ctx.getAttachedClientEnvs() do
			if newSrvParent ~= nil and isReplicatedOnServer(rep, srvInst) then
				local touched = {}
				syncSubtree(rep, srvInst, cliEnv, touched)
				resolveRefsTo(rep, cliEnv, touched)
			else
				local cliInst = cliEnv._mirrorOf[srvInst]
				if cliInst ~= nil and not rawget(cliInst, "_destroyed") then cliInst.Parent = nil end
				clearRefsToNode(rep, cliEnv, srvInst)
			end
		end
	end

	env._onPropChange = function(srvInst: any, key: string, value: any)
		if SKIP_REPLICATED_PROPS[key] or string.byte(key, 1) == 95 or type(value) == "function" then return end
		local isInst = customTypeof(value) == "Instance"
		if isInst and isReplicatedOnServer(rep, srvInst) then noteRef(rep, srvInst, value) end
		local targetReplicated = isInst and isReplicatedOnServer(rep, value)
		eachMirroredClient(
			srvInst,
			true,
			function(cliEnv, cliInst)
				setReplicatedProp(
					cliInst,
					key,
					if isInst then (if targetReplicated then cliEnv._mirrorOf[value] else nil) else value
				)
			end
		)
	end

	env._onAttrSet = function(srvInst: any, attr: string, value: any)
		local isInst = customTypeof(value) == "Instance"
		if isInst and isReplicatedOnServer(rep, srvInst) then noteRef(rep, srvInst, value) end
		local targetReplicated = isInst and isReplicatedOnServer(rep, value)
		eachMirroredClient(
			srvInst,
			true,
			function(cliEnv, cliInst)
				cliInst:SetAttribute(
					attr,
					if isInst then (if targetReplicated then cliEnv._mirrorOf[value] else nil) else value
				)
			end
		)
	end

	env.onTagChange = function(srvInst: any, tag: string, added: boolean)
		eachMirroredClient(srvInst, true, function(_cliEnv, cliInst)
			if added then
				cliInst:AddTag(tag)
			else
				cliInst:RemoveTag(tag)
			end
		end)
	end

	env._onDestroy = function(srvInst: any)
		eachMirroredClient(srvInst, false, function(cliEnv, cliInst)
			cliEnv._mirrorOf[srvInst], cliEnv._sourceOf[cliInst] = nil, nil
			cliInst:Destroy()
		end)
	end
end

return function(env: any, ctx: any)
	local server, client, isServer, isClient = ctx.server, ctx.client, ctx.isServer, ctx.isClient
	local gameInst, workspaceInst = ctx.gameInst, ctx.workspaceInst
	local terrainInst, replicatedStorage, playersInst = ctx.terrainInst, ctx.replicatedStorage, ctx.playersInst

	-- Server target -> server holders whose Instance-valued properties or attributes pointed at it when the holder
	-- was synced or set. Weak both ways; a stale entry is harmless, because the holder is rescanned, not trusted.
	local rep: Replicator = {
		env = env,
		ctx = ctx,
		refHolders = setmetatable({}, { __mode = "k" }) :: any,
	}

	ctx.getAttachedClientEnvs = function(): { any }
		local out = {}
		if server ~= nil and server._net ~= nil and server._net.clients ~= nil then
			for _, cl in server._net.clients do
				if not cl.gone and cl._env ~= nil then table.insert(out, cl._env) end
			end
		end
		return out
	end

	function env._syncClient(_self: any, cliEnv: any)
		if cliEnv == nil then return end
		pairMirror(cliEnv, gameInst, cliEnv.game)
		pairMirror(cliEnv, workspaceInst, cliEnv.workspace)
		pairMirror(cliEnv, terrainInst, cliEnv.workspace.Terrain)
		pairMirror(cliEnv, replicatedStorage, cliEnv._services.ReplicatedStorage)
		pairMirror(cliEnv, playersInst, cliEnv.Players)

		for _, root in { replicatedStorage, workspaceInst, playersInst } do
			for _, child in rawget(root, "_children") or {} do
				syncSubtree(rep, child, cliEnv)
			end
		end
		for srvInst, cliInst in cliEnv._mirrorOf do
			if liveMirror(srvInst, cliInst) then remapRefs(rep, srvInst, cliInst, cliEnv, false) end
		end
	end

	function env._syncChildInto(_self: any, srvChild: any, cliEnv: any, cliParent: any): any
		local srvParent = rawget(srvChild, "_parent")
		if srvParent ~= nil then pairMirror(cliEnv, srvParent, cliParent) end
		local touched = if srvParent ~= nil then { srvParent } else {}
		local cliChild = syncSubtree(rep, srvChild, cliEnv, touched)
		resolveRefsTo(rep, cliEnv, touched)
		if cliChild ~= nil and rawget(cliChild, "_parent") ~= cliParent then cliChild.Parent = cliParent end
		return cliChild
	end

	if isClient then
		env._resolveMountedServerChild = function(inst: any, childName: string): any
			local mountPath = rawget(inst, "_mountPath")
			local srv = server or (if client then client.server else nil)
			local srvEnv = if srv then srv._env else nil
			local srvNode = if mountPath ~= nil
					and srvEnv ~= nil
					and srvEnv._mountedByPath ~= nil
				then srvEnv._mountedByPath[mountPath]
				else nil
			local srvChild = if srvNode ~= nil then srvNode:FindFirstChild(childName) else nil
			return if srvChild ~= nil then srvEnv:_syncChildInto(srvChild, env, inst) else nil
		end
	end

	if isServer and server ~= nil then attachServerHooks(rep) end
end
