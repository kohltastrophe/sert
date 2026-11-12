--!strict
-- Deterministic Server -> Client DataModel replication for `ReplicatedStorage`, `Workspace`, and `Players`.

local Util = require("../core/util")

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

type MirrorRecord = {
	id: number,
	srv: any,
	cli: any,
}

type RefBucket = {
	list: { any },
	seen: { [number]: boolean },
}

local function pairMirror(cliEnv: any, srvNode: any, cliNode: any)
	cliEnv._mirrorOf[srvNode], cliEnv._sourceOf[cliNode] = cliNode, srvNode
	local id: number = rawget(srvNode, "_id") or 0
	local byId: { [number]: MirrorRecord }? = rawget(cliEnv, "_mirrorById")
	local list: { MirrorRecord }? = rawget(cliEnv, "_mirrorList")
	if byId == nil or list == nil then
		byId = {}
		list = {}
		rawset(cliEnv, "_mirrorById", byId)
		rawset(cliEnv, "_mirrorList", list)
	end
	local existing = (byId :: { [number]: MirrorRecord })[id]
	if existing ~= nil then
		existing.srv = srvNode
		existing.cli = cliNode
	else
		local rec: MirrorRecord = { id = id, srv = srvNode, cli = cliNode }
		(byId :: { [number]: MirrorRecord })[id] = rec
		table.insert(list :: { MirrorRecord }, rec)
	end
end

local function unpairMirror(cliEnv: any, srvNode: any, cliNode: any)
	cliEnv._mirrorOf[srvNode], cliEnv._sourceOf[cliNode] = nil, nil
	local id: number? = rawget(srvNode, "_id")
	local byId: { [number]: MirrorRecord }? = rawget(cliEnv, "_mirrorById")
	if id ~= nil and byId ~= nil then
		local rec = byId[id]
		if rec ~= nil then
			rec.srv = nil
			rec.cli = nil
			byId[id] = nil
		end
	end
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
	for _, k in Util.sortedKeys(cliInst._props) do
		local cliVal = cliInst._props[k]
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
	for _, k in Util.sortedKeys(srvInst._props) do
		local v = srvInst._props[k]
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
		for _, attr in Util.sortedKeys(cliAttrs) do
			if srvAttrs == nil or srvAttrs[attr] == nil then cliInst:SetAttribute(attr, nil) end
		end
	end
	if srvAttrs ~= nil then
		for _, attr in Util.sortedKeys(srvAttrs) do
			local val = srvAttrs[attr]
			if customTypeof(val) ~= "Instance" then cliInst:SetAttribute(attr, val) end
		end
	end
	local srvTags, cliTags = rawget(srvInst, "_tags"), rawget(cliInst, "_tags")
	if cliTags ~= nil then
		for _, tag in Util.sortedKeys(cliTags) do
			if srvTags == nil or not srvTags[tag] then cliInst:RemoveTag(tag) end
		end
	end
	if srvTags ~= nil then
		local tagOrder: { [string]: number }? = rawget(srvInst, "_tagOrder") :: any
		local orderedTags: { string } = Util.sortedKeys(srvTags)
		if tagOrder ~= nil then
			table.sort(orderedTags, function(a: string, b: string): boolean
				local oa, ob = tagOrder[a] or math.huge, tagOrder[b] or math.huge
				if oa ~= ob then return oa < ob end
				return a < b
			end)
		end
		for _, tag in orderedTags do
			if srvTags[tag] then cliInst:AddTag(tag) end
		end
	end
end

type Replicator = {
	env: any,
	ctx: any,
	refHolders: { [number]: RefBucket },
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
	local targetId: number? = rawget(target, "_id")
	local holderId: number? = rawget(holder, "_id")
	if targetId == nil or holderId == nil then return end
	local bucket = rep.refHolders[targetId]
	if bucket == nil then
		bucket = { list = {}, seen = {} }
		rep.refHolders[targetId] = bucket
	end
	if not bucket.seen[holderId] then
		bucket.seen[holderId] = true
		table.insert(bucket.list, holder)
	end
end

-- Maps srvInst's Instance-valued properties and attributes onto cliInst through cliEnv._mirrorOf, writing only
-- mirrored targets that differ. `syncing` (from syncSubtree) also records each reference in refHolders and
-- clears an attribute whose target is not mirrored yet.
local function remapRefs(rep: Replicator, srvInst: any, cliInst: any, cliEnv: any, syncing: boolean, existed: boolean?)
	local customTypeof = rep.ctx.typeof
	local mirrorOf = cliEnv._mirrorOf
	for _, k in Util.sortedKeys(srvInst._props) do
		local v = srvInst._props[k]
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
		for _, attr in Util.sortedKeys(srvAttrs) do
			local val = srvAttrs[attr]
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
		local targetId: number? = rawget(srvNode, "_id")
		local bucket = if targetId ~= nil then rep.refHolders[targetId] else nil
		if bucket ~= nil then
			for _, holder in bucket.list do
				local cliHolder = cliEnv._mirrorOf[holder]
				if cliHolder ~= nil and liveMirror(holder, cliHolder) then
					for _, k in Util.sortedKeys(cliHolder._props) do
						local v = cliHolder._props[k]
						if not SKIP_REPLICATED_PROPS[k] and v == cliTarget then setReplicatedProp(cliHolder, k, nil) end
					end
					local cliAttrs: { [string]: any }? = rawget(cliHolder, "_attributes") :: any
					if cliAttrs ~= nil then
						for _, attr in Util.sortedKeys(cliAttrs) do
							if cliAttrs[attr] == cliTarget then cliHolder:SetAttribute(attr, nil) end
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
	local seen: { [number]: boolean } = {}
	for _, target in touched do
		local targetId: number? = rawget(target, "_id") :: any
		local bucket = if targetId ~= nil then rep.refHolders[targetId] else nil
		if bucket ~= nil then
			for _, holder in bucket.list do
				local holderId: number = (rawget(holder, "_id") :: any) or 0
				if not seen[holderId] then
					seen[holderId] = true
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
		local targetId: number? = rawget(srvInst, "_id")
		if targetId ~= nil then rep.refHolders[targetId] = nil end
		eachMirroredClient(srvInst, false, function(cliEnv, cliInst)
			unpairMirror(cliEnv, srvInst, cliInst)
			cliInst:Destroy()
		end)
	end
end

return function(env: any, ctx: any)
	local server, client, isServer, isClient = ctx.server, ctx.client, ctx.isServer, ctx.isClient
	local gameInst, workspaceInst = ctx.gameInst, ctx.workspaceInst
	local terrainInst, replicatedStorage, playersInst = ctx.terrainInst, ctx.replicatedStorage, ctx.playersInst

	-- Keyed by monotonic server `_id` -> ordered array of server holders so reference back-patching never iterates pointer hashes.
	local rep: Replicator = {
		env = env,
		ctx = ctx,
		refHolders = {},
	}

	ctx.getAttachedClientEnvs = function(): { any }
		local out = {}
		local seen: { [any]: boolean } = {}
		if server ~= nil then
			if type(server.clients) == "table" then
				for _, cl in server.clients do
					if cl.connected ~= false and not cl.gone and cl._env ~= nil and not seen[cl._env] then
						seen[cl._env] = true
						table.insert(out, cl._env)
					end
				end
			end
			if server._net ~= nil and type(server._net.clients) == "table" then
				for _, cl in server._net.clients do
					if cl.connected ~= false and not cl.gone and cl._env ~= nil and not seen[cl._env] then
						seen[cl._env] = true
						table.insert(out, cl._env)
					end
				end
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

		local mirrorList: { MirrorRecord }? = rawget(cliEnv, "_mirrorList") :: any
		if mirrorList ~= nil then
			local liveList: { MirrorRecord } = {}
			for _, rec in mirrorList do
				if rec.srv ~= nil and rec.cli ~= nil and liveMirror(rec.srv, rec.cli) then
					table.insert(liveList, rec)
				end
			end
			table.sort(liveList, function(a: MirrorRecord, b: MirrorRecord): boolean return a.id < b.id end)
			rawset(cliEnv, "_mirrorList", liveList)
			for _, rec in liveList do
				remapRefs(rep, rec.srv, rec.cli, cliEnv, false)
			end
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
