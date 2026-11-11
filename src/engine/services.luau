--!strict
-- Unified Roblox peer service builders for `sert.env` and `sert.sim`.

local Util = require("../core/util")
local DataStoreDouble = require("./datastore")
local EncodingDouble = require("./encoding_service")
local InstanceDouble = require("./instance")
local MemoryStoreDouble = require("./memorystore")
local Serialize = require("./serialize")

local HttpDouble = EncodingDouble.HttpService

type Builder = (env: any, ctx: any, name: string) -> any

local PI, BACK = math.pi, 1.70158

local function bounceOut(t: number): number
	local n1, d1 = 7.5625, 2.75
	if t < 1 / d1 then
		return n1 * t * t
	elseif t < 2 / d1 then
		t -= 1.5 / d1
		return n1 * t * t + 0.75
	elseif t < 2.5 / d1 then
		t -= 2.25 / d1
		return n1 * t * t + 0.9375
	end
	t -= 2.625 / d1
	return n1 * t * t + 0.984375
end

local EASING_IN: { [string]: (number) -> number } = {
	Linear = function(t: number): number return t end,
	Sine = function(t: number): number return 1 - math.cos(t * PI / 2) end,
	Quad = function(t: number): number return t * t end,
	Cubic = function(t: number): number return t * t * t end,
	Quart = function(t: number): number return t ^ 4 end,
	Quint = function(t: number): number return t ^ 5 end,
	Exponential = function(t: number): number return if t <= 0 then 0 else 2 ^ (10 * t - 10) end,
	Circular = function(t: number): number return 1 - math.sqrt(math.max(0, 1 - t * t)) end,
	Back = function(t: number): number return (BACK + 1) * t * t * t - BACK * t * t end,
	Bounce = function(t: number): number return 1 - bounceOut(1 - t) end,
	Elastic = function(t: number): number
		return if t <= 0
			then 0
			elseif t >= 1 then 1
			else -(2 ^ (10 * t - 10)) * math.sin((t * 10 - 10.75) * (2 * PI / 3))
	end,
}

local function enumNameOf(item: any, default: string): string
	return if item == nil then default elseif type(item) == "string" then item else tostring(item.Name)
end

local Easing = {}

function Easing.value(alpha: number, style: any?, direction: any?): number
	local t = math.clamp(alpha, 0, 1)
	local curve = EASING_IN[enumNameOf(style, "Linear")] or EASING_IN.Linear
	local dir = enumNameOf(direction, "In")
	if dir == "Out" then
		return 1 - curve(1 - t)
	elseif dir == "InOut" then
		return if t < 0.5 then curve(2 * t) / 2 else 1 - curve(2 - 2 * t) / 2
	end
	return curve(t)
end

local function defService(ctx: any, className: string, methods: { [string]: any }?, props: { [string]: any }?): any
	local inst = ctx.createInstance(className, ctx.gameInst, true)
	rawset(inst, "_isService", true)
	if props ~= nil then
		for k, v in props do
			inst._props[k] = v
		end
	end
	if methods ~= nil then rawset(inst, "_methods", methods) end
	return inst
end

local DOUBLE_FIELDS = {
	calls = true,
	stores = true,
	budgets = true,
	failures = true,
	maps = true,
	queues = true,
	conflict = true,
}

local function proxyService(ctx: any, className: string, double: any): any
	local inst = ctx.createInstance(className, ctx.gameInst, true)
	rawset(inst, "_isService", true)
	local wrapped: { [string]: any } = {}
	rawset(
		inst,
		"_methods",
		setmetatable({}, {
			__index = function(_: any, key: any): any
				if type(key) ~= "string" or DOUBLE_FIELDS[key] then return nil end
				if wrapped[key] ~= nil then return wrapped[key] end
				local member: any = double[key]
				if type(member) ~= "function" then return nil end
				local fn = function(_self: any, ...: any): ...any return (member :: any)(double, ...) end
				wrapped[key] = fn
				return fn
			end,
		})
	)
	rawset(inst, "_double", double)
	rawset(inst, "_doubleFields", DOUBLE_FIELDS)
	return inst
end

local function genericService(_env: any, ctx: any, name: string): any
	local inst = ctx.createInstance(name, ctx.gameInst, true)
	rawset(inst, "_isService", true)
	return inst
end

local lazy: { [string]: Builder } = {}

function lazy.AssetService(_env: any, ctx: any): any
	local createInstance = ctx.createInstance
	return defService(ctx, "AssetService", {
		CreateMeshPartAsync = function(_self: any, meshId: any): any
			local mp = createInstance("MeshPart")
			mp._props.MeshId = tostring(meshId or "")
			return mp
		end,
		CreateEditableImageAsync = function(_self: any, imageOpts: { Size: any? }?): any
			local img = createInstance("EditableImage")
			if type(imageOpts) == "table" and imageOpts.Size ~= nil then img._props.Size = imageOpts.Size end
			return img
		end,
		CreateEditableMeshAsync = function(_self: any): any return createInstance("EditableMesh") end,
	})
end

function lazy.AvatarEditorService(_env: any, ctx: any): any
	return defService(ctx, "AvatarEditorService", {
		SearchCatalogAsync = function(_self: any, _params: any): any return DataStoreDouble.makePages({}, 1) end,
	})
end

function lazy.BadgeService(env: any, ctx: any): any
	return defService(ctx, "BadgeService", {
		UserHasBadgeAsync = function(_self: any, userId: number, badgeId: number): boolean
			return env.badges[userId] ~= nil and env.badges[userId][badgeId] == true
		end,
		AwardBadge = function(_self: any, userId: number, badgeId: number): boolean
			env.badges[userId] = env.badges[userId] or {}
			env.badges[userId][badgeId] = true
			return true
		end,
		GetBadgeInfoAsync = function(_self: any, badgeId: number): any
			return { Name = `Badge{badgeId}`, Description = "", IconImageId = badgeId, IsEnabled = true }
		end,
	})
end

function lazy.CollectionService(env: any, ctx: any): any
	return defService(ctx, "CollectionService", {
		AddTag = function(_self: any, instance: any, tag: string) instance:AddTag(tag) end,
		RemoveTag = function(_self: any, instance: any, tag: string) instance:RemoveTag(tag) end,
		HasTag = function(_self: any, instance: any, tag: string): boolean return instance:HasTag(tag) end,
		GetTags = function(_self: any, instance: any): { string } return instance:GetTags() end,
		GetTagged = function(_self: any, tag: string): { any } return InstanceDouble.getTagged(env, tag) end,
		GetInstanceAddedSignal = function(_self: any, tag: string): any
			env._tagAddedSignals[tag] = env._tagAddedSignals[tag] or env:signal()
			return env._tagAddedSignals[tag]
		end,
		GetInstanceRemovedSignal = function(_self: any, tag: string): any
			env._tagRemovedSignals[tag] = env._tagRemovedSignals[tag] or env:signal()
			return env._tagRemovedSignals[tag]
		end,
	})
end

function lazy.ContentProvider(_env: any, ctx: any): any
	local Enum = ctx.Enum
	return defService(ctx, "ContentProvider", {
		PreloadAsync = function(_self: any, assets: { any }, callback: ((string, any) -> ())?)
			if type(assets) == "table" and callback ~= nil then
				for _, asset in assets do
					callback(tostring(asset), Enum.AssetFetchStatus.Success)
				end
			end
		end,
	})
end

function lazy.ContextActionService(_env: any, ctx: any): any
	local boundActions: { [string]: any } = {}
	return defService(ctx, "ContextActionService", {
		BindAction = function(_self: any, name: string, fn: any, createTouchButton: boolean?, ...: any)
			boundActions[name] = { fn = fn, createTouchButton = createTouchButton, inputTypes = { ... } }
		end,
		BindActionAtPriority = function(
			_self: any,
			name: string,
			fn: any,
			createTouchButton: boolean?,
			_priority: number,
			...: any
		)
			boundActions[name] = { fn = fn, createTouchButton = createTouchButton, inputTypes = { ... } }
		end,
		UnbindAction = function(_self: any, name: string) boundActions[name] = nil end,
		UnbindAllActions = function(_self: any) table.clear(boundActions) end,
		GetBoundActionInfo = function(_self: any, name: string): any return boundActions[name] or {} end,
		GetAllBoundActionInfo = function(_self: any): { [string]: any } return table.clone(boundActions) end,
	})
end

function lazy.DataStoreService(_env: any, ctx: any): any
	local host = ctx.host
	return proxyService(
		ctx,
		"DataStoreService",
		if host and host.DataStoreService
			then host.DataStoreService
			else DataStoreDouble.new({ clock = ctx.getUnixTime })
	)
end

function lazy.Debris(_env: any, ctx: any): any
	local taskDelay = ctx.task.delay
	return defService(ctx, "Debris", {
		AddItem = function(_self: any, item: any, lifetime: number?)
			if item ~= nil then taskDelay(lifetime or 10, function() pcall(item.Destroy, item) end) end
		end,
	})
end

function lazy.EncodingService(_env: any, ctx: any): any
	local host = ctx.host
	return proxyService(
		ctx,
		"EncodingService",
		if host and host.EncodingService then host.EncodingService else EncodingDouble.new()
	)
end

function lazy.GroupService(env: any, ctx: any): any
	return defService(ctx, "GroupService", {
		GetGroupInfoAsync = function(_self: any, groupId: number): any
			local g = env.groups[groupId] or {}
			return {
				Id = groupId,
				Name = g.Name or `Group{groupId}`,
				EmblemUrl = g.EmblemUrl or `rbxassetid://{groupId}`,
				Description = g.Description or "",
				Owner = g.Owner or { Id = 1, Name = "Player1" },
				Roles = g.Roles
					or { { Name = "Member", Rank = 1 }, { Name = "Admin", Rank = 200 }, { Name = "Owner", Rank = 255 } },
			}
		end,
		GetGroupsAsync = function(_self: any, userId: number): { any }
			local groupIds: { number } = {}
			for groupId in env.groups do
				table.insert(groupIds, groupId)
			end
			table.sort(groupIds)
			local out = {}
			for _, groupId in groupIds do
				local g = env.groups[groupId]
				local rank = if g.ranks then g.ranks[userId] else nil
				if rank and rank > 0 then
					table.insert(out, {
						Id = groupId,
						Name = g.Name or `Group{groupId}`,
						EmblemUrl = g.EmblemUrl or `rbxassetid://{groupId}`,
						Rank = rank,
						Role = (if g.roles then g.roles[userId] else nil) or `Rank{rank}`,
						IsPrimary = false,
					})
				end
			end
			return out
		end,
	})
end

function lazy.GuiService(_env: any, ctx: any): any
	local isStrict, Vector2, Rect = ctx.isStrict, ctx.dt.Vector2, ctx.dt.Rect
	return defService(ctx, "GuiService", {
		GetGuiInset = function(self: any): (any, any)
			local inset = self._props._guiInset
			return if inset ~= nil then inset elseif isStrict then Vector2.zero else Vector2.new(0, 36), Vector2.zero
		end,
		IsTenFootInterface = function(): boolean return false end,
	}, if not isStrict then { TopbarInset = Rect.new(0, 0, 1280, 36) } else nil)
end

function lazy.HttpService(env: any, ctx: any): any
	local host = ctx.host
	local httpDouble = if host and host.HttpService then host.HttpService else HttpDouble.new()
	return defService(ctx, "HttpService", {
		GenerateGUID = function(_self: any, wrapInCurlyBraces: boolean?): string
			return httpDouble:GenerateGUID(wrapInCurlyBraces)
		end,
		JSONEncode = function(_self: any, value: any): string return httpDouble:JSONEncode(value) end,
		JSONDecode = function(_self: any, text: string): any return httpDouble:JSONDecode(text) end,
		UrlEncode = function(_self: any, text: string): string
			return (string.gsub(text, "([^%w_%-%.~])", function(c) return string.format("%%%02X", string.byte(c)) end))
		end,
		RequestAsync = function(self: any, req: any): any
			if not self.HttpEnabled then error("Http requests are not enabled. Enable via game settings", 2) end
			local handler: ((any) -> any)? = env.httpHandler
			return if handler ~= nil
				then handler(req)
				else { Success = true, StatusCode = 200, StatusMessage = "OK", Headers = {}, Body = "{}" }
		end,
		GetAsync = function(self: any, url: string): string
			local res = self:RequestAsync({ Url = url, Method = "GET" })
			if
				type(res) ~= "table"
				or res.Success == false
				or (type(res.StatusCode) == "number" and res.StatusCode >= 400)
			then
				error(
					string.format(
						"HTTP %s (%s)",
						tostring(res and res.StatusCode or 0),
						tostring(res and res.StatusMessage or "Error")
					),
					2
				)
			end
			return res.Body
		end,
		PostAsync = function(self: any, url: string, body: string): string
			local res = self:RequestAsync({ Url = url, Method = "POST", Body = body })
			if
				type(res) ~= "table"
				or res.Success == false
				or (type(res.StatusCode) == "number" and res.StatusCode >= 400)
			then
				error(
					string.format(
						"HTTP %s (%s)",
						tostring(res and res.StatusCode or 0),
						tostring(res and res.StatusMessage or "Error")
					),
					2
				)
			end
			return res.Body
		end,
	}, { HttpEnabled = true })
end

function lazy.InsertService(_env: any, ctx: any): any
	local createInstance = ctx.createInstance
	return defService(ctx, "InsertService", {
		LoadAsset = function(_self: any, assetId: number): any
			local model = createInstance("Model")
			model.Name = `Asset{assetId}`
			local tool = createInstance("Tool", model)
			tool.Name = `Tool{assetId}`
			local handle = createInstance("Part", tool)
			handle.Name = "Handle"
			return model
		end,
		CreateMeshPartAsync = function(_self: any, meshId: any): any
			return ctx.getService("AssetService"):CreateMeshPartAsync(meshId)
		end,
	})
end

function lazy.LogService(env: any, ctx: any): any
	return defService(ctx, "LogService", nil, { MessageOut = env:signal() })
end

function lazy.MarketplaceService(env: any, ctx: any): any
	local gameInst = ctx.gameInst
	local Enum = ctx.Enum
	local prompts: { { kind: string, player: any, id: any } } = {}
	local receiptSeq = 0
	local market = defService(ctx, "MarketplaceService", nil, {
		PromptGamePassPurchaseFinished = env:signal(),
		PromptPurchaseFinished = env:signal(),
		PromptBundlePurchaseFinished = env:signal(),
		PromptSubscriptionPurchaseFinished = env:signal(),
		PromptProductPurchaseFinished = env:signal(),
		_prompts = prompts,
	})
	local function resolveUid(player: any): any return if type(player) == "table" then player.UserId else player end
	local function grantEntry(bucket: { [any]: { [any]: boolean } }, uid: any, itemId: any)
		if uid == nil then return end
		bucket[uid] = bucket[uid] or {}
		bucket[uid][itemId] = true
	end
	local methods: { [string]: any } = {
		GetProductInfo = function(_self: any, id: number): any
			return env.marketplace.products[id]
				or {
					AssetId = id,
					Name = `Asset{id}`,
					Description = "",
					PriceInRobux = 100,
					Creator = { Id = gameInst.CreatorId, Name = "Creator", CreatorType = "User" },
					AssetTypeId = 8,
					IsForSale = true,
				}
		end,
		UserOwnsGamePassAsync = function(_self: any, userId: number, gamePassId: number): boolean
			local uid = resolveUid(userId)
			local map = env.marketplace.gamePasses[uid]
			return map ~= nil and map[gamePassId] == true
		end,
		PlayerOwnsAsset = function(_self: any, player: any, assetId: number): boolean
			local map = env.marketplace.assets[resolveUid(player)]
			return map ~= nil and map[assetId] == true
		end,
		PlayerOwnsBundle = function(_self: any, player: any, bundleId: number): boolean
			local map = env.marketplace.bundles[resolveUid(player)]
			return map ~= nil and map[bundleId] == true
		end,
		CheckUserSubscriptionStatusAsync = function(_self: any, player: any, subId: string): any
			local map = env.marketplace.subscriptions[resolveUid(player)]
			local sub = map ~= nil and map[subId] == true
			return { IsSubscribed = sub, IsRenewing = sub }
		end,
		PromptProductPurchase = function(_self: any, player: any, productId: number)
			table.insert(prompts, { kind = "Product", player = player, id = productId })
			-- When bound to a `sert.sim` server, `Fabric` delivers receipts asynchronously with VOPR hazards.
			if ctx.server ~= nil and ctx.server.MarketplaceService ~= nil then return end
			local uid = resolveUid(player)
			local processReceipt: any = market._props.ProcessReceipt
			local purchased = env.marketplace.autoApprove == true
			if type(processReceipt) == "function" then
				receiptSeq += 1
				local prodInfo = env.marketplace.products[productId]
				local price = if type(prodInfo) == "table" and type(prodInfo.PriceInRobux) == "number"
					then prodInfo.PriceInRobux
					else 100
				local decision = (processReceipt :: (...any) -> any)({
					PurchaseId = string.format("receipt-%d-%d-%d", gameInst.PlaceId, tonumber(uid) or 0, receiptSeq),
					PlayerId = uid,
					ProductId = productId,
					PlaceIdWherePurchased = gameInst.PlaceId,
					CurrencySpent = price,
					PurchaseType = Enum.InfoType.Product,
				})
				purchased = decision == Enum.ProductPurchaseDecision.PurchaseGranted
			end
			market._props.PromptProductPurchaseFinished:Fire(uid, productId, purchased)
		end,
		PromptGamePassPurchase = function(_self: any, player: any, gamePassId: number)
			table.insert(prompts, { kind = "GamePass", player = player, id = gamePassId })
			local purchased = env.marketplace.autoApprove == true
			if purchased then grantEntry(env.marketplace.gamePasses, resolveUid(player), gamePassId) end
			market._props.PromptGamePassPurchaseFinished:Fire(player, gamePassId, purchased)
		end,
		PromptPurchase = function(_self: any, player: any, assetId: number)
			table.insert(prompts, { kind = "Asset", player = player, id = assetId })
			local purchased = env.marketplace.autoApprove == true
			if purchased then grantEntry(env.marketplace.assets, resolveUid(player), assetId) end
			market._props.PromptPurchaseFinished:Fire(player, assetId, purchased)
		end,
		PromptBundlePurchase = function(_self: any, player: any, bundleId: number)
			table.insert(prompts, { kind = "Bundle", player = player, id = bundleId })
			local purchased = env.marketplace.autoApprove == true
			if purchased then grantEntry(env.marketplace.bundles, resolveUid(player), bundleId) end
			market._props.PromptBundlePurchaseFinished:Fire(player, bundleId, purchased)
		end,
		PromptSubscriptionPurchase = function(_self: any, player: any, subId: string)
			table.insert(prompts, { kind = "Subscription", player = player, id = subId })
			local purchased = env.marketplace.autoApprove == true
			if purchased then grantEntry(env.marketplace.subscriptions, resolveUid(player), subId) end
			market._props.PromptSubscriptionPurchaseFinished:Fire(player, subId, purchased)
		end,
	}
	methods.GetProductInfoAsync = methods.GetProductInfo
	methods.PlayerOwnsAssetAsync = methods.PlayerOwnsAsset
	methods.PlayerOwnsBundleAsync = methods.PlayerOwnsBundle
	methods.GetUserSubscriptionStatusAsync = methods.CheckUserSubscriptionStatusAsync
	rawset(market, "_methods", methods)
	return market
end

function lazy.MemoryStoreService(_env: any, ctx: any): any
	local host = ctx.host
	local clock = setmetatable({}, {
		__index = function(_: any, key: any): any return if key == "now" then ctx.getClock() else nil end,
		__newindex = function() error("MemoryStoreService: the env owns this clock; advance it with env:advance", 2) end,
	}) :: any
	local double = if host and host.MemoryStoreService
		then host.MemoryStoreService
		else MemoryStoreDouble.new(clock, {
			wait = function(seconds: number) ctx.task.wait(seconds) end,
		})
	return proxyService(ctx, "MemoryStoreService", double)
end

function lazy.MessagingService(env: any, ctx: any): any
	local host = ctx.host
	local double: any = if host and host.MessagingService then host.MessagingService else nil
	if double == nil then
		local topics: { [string]: any } = {}
		double = {
			SubscribeAsync = function(
				_self: any,
				topic: string,
				callback: (message: { Data: any, Sent: number }) -> ()
			): any
				topics[topic] = topics[topic] or env:signal()
				return topics[topic]:Connect(callback)
			end,
			PublishAsync = function(_self: any, topic: string, data: any)
				local payload = Util.copy(data)
				if topics[topic] ~= nil then topics[topic]:Fire({ Data = payload, Sent = ctx.getUnixTime() }) end
			end,
		}
	end
	return proxyService(ctx, "MessagingService", double)
end

function lazy.PhysicsService(_env: any, ctx: any): any
	local groups: { [string]: { [string]: boolean } } = { Default = { Default = true } }
	return defService(ctx, "PhysicsService", {
		RegisterCollisionGroup = function(_self: any, name: string) groups[name] = groups[name] or { [name] = true } end,
		UnregisterCollisionGroup = function(_self: any, name: string) groups[name] = nil end,
		IsCollisionGroupRegistered = function(_self: any, name: string): boolean return groups[name] ~= nil end,
		CollisionGroupSetCollidable = function(_self: any, g1: string, g2: string, collidable: boolean)
			groups[g1], groups[g2] = groups[g1] or {}, groups[g2] or {}
			groups[g1][g2], groups[g2][g1] = collidable, collidable
		end,
		CollisionGroupsAreCollidable = function(_self: any, g1: string, g2: string): boolean
			return groups[g1] ~= nil and groups[g1][g2] ~= false
		end,
		GetRegisteredCollisionGroups = function(_self: any): { { name: string } }
			local names = Util.sortedKeys(groups)
			local out: { { name: string } } = table.create(#names) :: any
			for i, k in names do
				out[i] = { name = k }
			end
			return out
		end,
	})
end

function lazy.PolicyService(_env: any, ctx: any): any
	return defService(ctx, "PolicyService", {
		GetPolicyInfoForPlayerAsync = function(): any
			return {
				AreAdsAllowed = true,
				ArePaidRandomItemsRestricted = false,
				AllowedExternalLinkReferences = { "Discord", "GitHub", "YouTube", "Twitch" },
				IsPaidItemTradingAllowed = true,
				IsSubjectToChinaPolicies = false,
			}
		end,
	})
end

function lazy.ReflectionService(env: any, ctx: any): any
	return defService(ctx, "ReflectionService", {
		GetClass = function(_self: any, className: string): any
			return {
				Name = className,
				Superclass = InstanceDouble.SUPERCLASS[className] or "Instance",
				Permits = { GetService = if env:_hasService(className) then true else nil },
			}
		end,
		GetPropertiesOfClass = function(_self: any, className: string): { any }
			local schema = InstanceDouble.CLASSES[className]
			local out = {}
			if schema ~= nil then
				for _, propName in Util.sortedKeys(schema.members) do
					local member = schema.members[propName]
					if member.kind == "property" then
						table.insert(out, {
							Name = propName,
							Type = { ScriptType = member.type, EngineType = member.type },
							Permits = { Read = true, Write = if not member.readOnly then true else nil },
						})
					end
				end
			end
			return out
		end,
	})
end

function lazy.ScriptContext(env: any, ctx: any): any
	return defService(ctx, "ScriptContext", nil, { Error = env:signal() })
end

function lazy.StarterGui(_env: any, ctx: any): any
	local coreState: { [string]: any }, coreGuiEnabled: { [any]: boolean } = {}, {}
	return defService(ctx, "StarterGui", {
		SetCore = function(_self: any, name: string, value: any) coreState[name] = value end,
		GetCore = function(_self: any, name: string): any return coreState[name] end,
		SetCoreGuiEnabled = function(_self: any, coreType: any, enabled: boolean) coreGuiEnabled[coreType] = enabled end,
		GetCoreGuiEnabled = function(_self: any, coreType: any): boolean return coreGuiEnabled[coreType] ~= false end,
	})
end

function lazy.StudioTestService(_env: any, ctx: any): any
	return defService(ctx, "StudioTestService", {
		GetTestArgs = function(self: any): any return self._props.TestArgs end,
		EndTest = function(self: any, result: any) self._props.EndedResult = result end,
	})
end

function lazy.Teams(_env: any, ctx: any): any
	return defService(ctx, "Teams", {
		GetTeams = function(self: any): { any } return self:GetChildren() end,
	})
end

function lazy.TeleportService(env: any, ctx: any): any
	local createInstance = ctx.createInstance
	local reserveSeq = 0
	local reservedByCode: { [string]: string } = {}
	local function reserve(_self: any, placeId: number): (string, string)
		reserveSeq += 1
		local code = `access-{placeId}-{reserveSeq}`
		local serverId = `server-{placeId}-{reserveSeq}`
		reservedByCode[code] = serverId
		return code, serverId
	end
	local function extractTeleportData(teleportOptions: any?): any
		if type(teleportOptions) ~= "table" then return nil end
		local okMethod, getFn = pcall(function() return teleportOptions.GetTeleportData end)
		if okMethod and type(getFn) == "function" then
			local okCall, td = pcall(getFn, teleportOptions)
			if okCall and td ~= nil then return Serialize.remote(td, { allowInstances = false }) end
		end
		local props = rawget(teleportOptions, "_props")
		if type(props) == "table" and props._teleportData ~= nil then
			return Serialize.remote(props._teleportData, { allowInstances = false })
		end
		return nil
	end
	return defService(ctx, "TeleportService", {
		ReserveServer = reserve,
		ReserveServerAsync = reserve,
		TeleportAsync = function(self: any, placeId: number, players: { any }, teleportOptions: any?): any
			assert(type(players) == "table", "TeleportService:TeleportAsync expects an array of Players")
			local teleportData = extractTeleportData(teleportOptions)
			local accessCode = ""
			local privateServerId = ""
			if type(teleportOptions) == "table" then
				local props = rawget(teleportOptions, "_props") or teleportOptions
				if type(props.ReservedServerAccessCode) == "string" and #props.ReservedServerAccessCode > 0 then
					accessCode = props.ReservedServerAccessCode
					privateServerId = reservedByCode[accessCode] or `server-{placeId}`
				elseif props.ShouldReserveServer == true then
					accessCode, privateServerId = reserve(self, placeId)
				end
			end
			table.insert(env.teleports, {
				kind = "TeleportAsync",
				placeId = placeId,
				players = table.clone(players),
				options = teleportOptions,
				teleportData = teleportData,
				accessCode = accessCode,
				privateServerId = privateServerId,
			})
			local res = createInstance("TeleportAsyncResult", nil, true)
			res._props.PrivateServerId = privateServerId
			res._props.ReservedServerAccessCode = accessCode
			return res
		end,
		Teleport = function(_self: any, placeId: number, player: any?, teleportData: any?, customLoadingScreen: any?)
			local safeData = if teleportData ~= nil
				then Serialize.remote(teleportData, { allowInstances = false })
				else nil
			local targetPlayer = player or env.LocalPlayer
			table.insert(env.teleports, {
				kind = "Teleport",
				placeId = placeId,
				players = if targetPlayer ~= nil then { targetPlayer } else {},
				teleportData = safeData,
				customLoadingScreen = customLoadingScreen,
			})
		end,
		TeleportToPrivateServer = function(
			_self: any,
			placeId: number,
			accessCode: string,
			players: { any },
			spawnName: string?,
			teleportData: any?,
			customLoadingScreen: any?
		)
			local safeData = if teleportData ~= nil
				then Serialize.remote(teleportData, { allowInstances = false })
				else nil
			table.insert(env.teleports, {
				kind = "TeleportToPrivateServer",
				placeId = placeId,
				accessCode = accessCode,
				privateServerId = reservedByCode[accessCode] or "",
				players = if type(players) == "table" then table.clone(players) else {},
				spawnName = spawnName,
				teleportData = safeData,
				customLoadingScreen = customLoadingScreen,
			})
		end,
		TeleportToPlaceInstance = function(
			_self: any,
			placeId: number,
			instanceId: string,
			player: any?,
			spawnName: string?,
			teleportData: any?,
			customLoadingScreen: any?
		)
			local safeData = if teleportData ~= nil
				then Serialize.remote(teleportData, { allowInstances = false })
				else nil
			local targetPlayer = player or env.LocalPlayer
			table.insert(env.teleports, {
				kind = "TeleportToPlaceInstance",
				placeId = placeId,
				instanceId = instanceId,
				players = if targetPlayer ~= nil then { targetPlayer } else {},
				spawnName = spawnName,
				teleportData = safeData,
				customLoadingScreen = customLoadingScreen,
			})
		end,
		SetTeleportData = function(_self: any, teleportData: any)
			env._localTeleportData = if teleportData ~= nil
				then Serialize.remote(teleportData, { allowInstances = false })
				else nil
		end,
		GetLocalPlayerTeleportData = function(_self: any): any return Util.copy(env._localTeleportData) end,
	}, {
		TeleportInitFailed = env:signal(),
		LocalPlayerArrivedFromTeleport = env:signal(),
	})
end

function lazy.TextChatService(env: any, ctx: any): any
	return defService(ctx, "TextChatService", {
		CanUserChatAsync = function(): boolean return true end,
		CanUsersChatAsync = function(): boolean return true end,
		DisplayBubble = function(self: any, partOrChar: any, message: string)
			table.insert(self._props._bubbles, { target = partOrChar, message = message })
			self._props.BubbleDisplayed:Fire(partOrChar, message)
		end,
	}, {
		ChatVersion = ctx.Enum.ChatVersion.TextChatService,
		CreateDefaultTextChannels = true,
		CreateDefaultCommands = true,
		BubbleDisplayed = env:signal(),
		_bubbles = {},
	})
end

function lazy.TextService(env: any, ctx: any): any
	local Vector2 = ctx.dt.Vector2
	local textService = defService(ctx, "TextService")
	local methods = {}
	function methods.GetTextSize(_self: any, text: string, fontSize: number, _font: any, frameSize: any?): any
		local sz = fontSize or 14
		local w, h = #tostring(text) * math.ceil(sz * 0.55), sz
		if frameSize ~= nil and frameSize.X > 0 and w > frameSize.X then
			w, h = frameSize.X, math.ceil(w / frameSize.X) * sz
		end
		return Vector2.new(w, h)
	end
	function methods.GetTextBoundsAsync(_self: any, params: any): any
		local text = if params then params.Text or "" else ""
		local size = if params then params.Size or 14 else 14
		local width = if params and params.Width and params.Width > 0 then params.Width else math.huge
		return methods.GetTextSize(textService, text, size, nil, Vector2.new(width, math.huge))
	end
	function methods.FilterStringAsync(_self: any, text: string, fromUserId: number): any
		local filterFn: ((string, number) -> string)? = env.textFilter
		local filtered = if filterFn ~= nil then filterFn(text, fromUserId) else text
		local function get(): string return filtered end
		return {
			GetNonChatStringForBroadcastAsync = get,
			GetNonChatStringForUserAsync = get,
			GetChatForUserAsync = get,
		}
	end
	rawset(textService, "_methods", methods)
	return textService
end

local TWEENABLE: { [string]: boolean } = {}
for _, k in string.split("number boolean CFrame Rect Color3 UDim UDim2 Vector2 Vector2int16 Vector3 EnumItem", " ") do
	TWEENABLE[k] = true
end

function lazy.TweenService(_env: any, ctx: any): any
	local createInstance, Enum, dt, typeOf = ctx.createInstance, ctx.Enum, ctx.dt, ctx.typeof
	local active: { any } = {}
	ctx.activeTweens = active

	local function lerp(a: any, b: any, t: number): any
		local av: any, bv: any = a, b
		if a == nil then
			return b
		elseif type(a) == "number" and type(b) == "number" then
			return a + (b - a) * t
		end
		local kind = typeOf(a)
		if kind ~= typeOf(b) then
			return a
		elseif kind == "UDim" then
			return dt.UDim.new(av.Scale + (bv.Scale - av.Scale) * t, av.Offset + (bv.Offset - av.Offset) * t)
		elseif kind == "Vector2" or kind == "Vector3" or kind == "Color3" or kind == "UDim2" or kind == "CFrame" then
			return av:Lerp(bv, t)
		elseif kind == "Rect" then
			return dt.Rect.new(av.Min:Lerp(bv.Min, t), av.Max:Lerp(bv.Max, t))
		elseif kind == "Vector2int16" then
			return dt.Vector2int16.new(math.round(av.X + (bv.X - av.X) * t), math.round(av.Y + (bv.Y - av.Y) * t))
		end
		return if t >= 1 then b else a
	end

	local function stop(state: any)
		state.active = false
		state.runId += 1
		local index = table.find(active, state)
		if index ~= nil then table.remove(active, index) end
	end

	local function finish(state: any, playback: any)
		stop(state)
		state.elapsed = 0
		state.tween._props.PlaybackState = playback
		state.tween.Completed:Fire(playback)
	end

	local function apply(state: any): boolean
		local myRunId = state.runId
		local info = state.info
		local duration, delay = math.max(info.Time or 0, 0), math.max(info.DelayTime or 0, 0)
		local reverses, repeats = info.Reverses == true, info.RepeatCount or 0
		local cycles = if repeats < 0 then math.huge else repeats + 1
		local cycleLength = delay + duration * (if reverses then 2 else 1)
		local target = state.tween._props.Instance
		local done, alpha = false, 0
		if cycleLength <= 0 then
			done, alpha = repeats >= 0, if reverses then 0 else 1
		else
			local cycle = math.floor(state.elapsed / cycleLength + 1e-9)
			if cycle >= cycles then
				done, alpha = true, if reverses then 0 else 1
			else
				local within = math.max(state.elapsed - cycle * cycleLength, 0)
				if within < delay then
					state.tween._props.PlaybackState = Enum.PlaybackState.Delayed
					return false
				else
					state.tween._props.PlaybackState = Enum.PlaybackState.Playing
					local p = within - delay
					alpha = if duration <= 0
						then 1
						elseif p <= duration then p / duration
						else 1 - (p - duration) / duration
				end
			end
		end
		local eased = if done then alpha else Easing.value(alpha, info.EasingStyle, info.EasingDirection)
		if target ~= nil then
			for key, goal in state.goals do
				local startVal = state.starts[key]
				target[key] = if done
					then (if alpha >= 1 or startVal == nil then goal else startVal)
					else lerp(startVal, goal, eased)
				if state.runId ~= myRunId then return false end
			end
		end
		return done
	end

	local function update(step: number)
		if #active == 0 then return end
		for _, state in table.clone(active) do
			if state.active then
				local myRunId = state.runId
				state.elapsed += step
				if apply(state) and state.active and state.runId == myRunId then
					finish(state, Enum.PlaybackState.Completed)
				end
			end
		end
	end

	if ctx.standalone then
		table.insert(ctx.frameCallbacks, update)
	elseif ctx.runService ~= nil and ctx.runService._props.Heartbeat ~= nil then
		local conns: { any } = ctx.serviceConnections
		local conn: any = ctx.runService._props.Heartbeat:Connect(update)
		table.insert(conns, conn)
	end

	return defService(ctx, "TweenService", {
		Create = function(_self: any, target: any, tweenInfo: any, propTable: { [string]: any }): any
			local schema = if type(target) == "table" and rawget(target, "_isInstance") == true
				then InstanceDouble.CLASSES[target._props.ClassName]
				else nil
			for key, goal in propTable do
				local ok, current = pcall(function(): any return target[key] end)
				local member = if schema ~= nil then schema.members[key] else nil
				local isProperty = if schema ~= nil
					then (member ~= nil and member.kind == "property") or target._props[key] ~= nil
					else ok
						and current ~= nil
						and typeOf(current) ~= "function"
						and typeOf(current) ~= "RBXScriptSignal"
				local goalKind = typeOf(goal)
				local kind = if current ~= nil
					then typeOf(current)
					elseif member ~= nil and member.type ~= nil then member.type
					else goalKind
				if not isProperty then
					error(`TweenService:Create no property named '{key}' for object '{target.Name}'`, 2)
				elseif not TWEENABLE[kind] then
					error(
						`TweenService:Create property named '{key}' on object '{target.Name}' is not a data type that can be tweened`,
						2
					)
				elseif goalKind ~= kind then
					error(
						`TweenService:Create property named '{key}' cannot be tweened due to type mismatch (property is a '{kind}', but given type is '{goalKind}')`,
						2
					)
				end
			end
			local tween = createInstance("Tween", nil, true)
			tween._props.Instance = target
			tween._props.TweenInfo = tweenInfo
			tween._props.PlaybackState = Enum.PlaybackState.Begin
			local state: any = {
				tween = tween,
				info = tweenInfo,
				goals = table.clone(propTable),
				starts = {},
				elapsed = 0,
				active = false,
				runId = 0,
			}
			rawset(tween, "_methods", {
				Play = function()
					if state.active then return end
					if tween._props.PlaybackState ~= Enum.PlaybackState.Paused then
						state.elapsed = 0
						for key in state.goals do
							state.starts[key] = if target ~= nil then target[key] else nil
						end
					end
					for _, other in table.clone(active) do
						if other ~= state and other.tween._props.Instance == target then
							for key in state.goals do
								if other.goals[key] ~= nil then
									finish(other, Enum.PlaybackState.Cancelled)
									break
								end
							end
						end
					end
					state.runId += 1
					state.active = true
					table.insert(active, state)
					local delay = tweenInfo.DelayTime or 0
					local duration = tweenInfo.Time or 0
					local cycleDuration = delay + duration * (if tweenInfo.Reverses then 2 else 1)
					local within = if cycleDuration > 0 and state.elapsed > 0
						then state.elapsed % cycleDuration
						else state.elapsed
					tween._props.PlaybackState = if within < delay
						then Enum.PlaybackState.Delayed
						else Enum.PlaybackState.Playing
					if duration <= 0 and delay <= 0 and (tweenInfo.RepeatCount or 0) == 0 then
						local myRunId = state.runId
						apply(state)
						if state.active and state.runId == myRunId then finish(state, Enum.PlaybackState.Completed) end
					end
				end,
				Pause = function()
					if state.active then
						stop(state)
						tween._props.PlaybackState = Enum.PlaybackState.Paused
					end
				end,
				Cancel = function()
					if state.active or tween._props.PlaybackState == Enum.PlaybackState.Paused then
						finish(state, Enum.PlaybackState.Cancelled)
					else
						tween._props.PlaybackState = Enum.PlaybackState.Cancelled
					end
				end,
			})
			return tween
		end,
		GetValue = function(_self: any, alpha: number, style: any?, direction: any?): number
			return Easing.value(alpha, style, direction)
		end,
	})
end

function lazy.UserInputService(env: any, ctx: any): any
	local Enum, Vector2 = ctx.Enum, ctx.dt.Vector2
	local uis = defService(ctx, "UserInputService")
	local state = {
		keys = {} :: { any },
		buttons = {} :: { any },
		mouse = Vector2.new(0, 0),
		delta = Vector2.new(0, 0),
		lastType = Enum.UserInputType.MouseMovement,
	}
	ctx.inputState = state
	local function find(list: { any }, field: string, value: any): number?
		for i, io in list do
			if io[field] == value then return i end
		end
		return nil
	end
	rawset(uis, "_methods", {
		GetMouseLocation = function(): any return uis._props._mouseLocation or state.mouse end,
		GetMouseDelta = function(): any return state.delta end,
		IsKeyDown = function(_self: any, keyCode: any): boolean return find(state.keys, "KeyCode", keyCode) ~= nil end,
		IsMouseButtonPressed = function(_self: any, button: any): boolean
			return find(state.buttons, "UserInputType", button) ~= nil
		end,
		GetKeysPressed = function(): { any } return table.clone(state.keys) end,
		GetMouseButtonsPressed = function(): { any } return table.clone(state.buttons) end,
		GetFocusedTextBox = function(): any return env._focusedBox end,
		GetStringForKeyCode = function(_self: any, keyCode: any): string
			local k = type(keyCode)
			return if (k == "table" or k == "userdata") and keyCode.Name then keyCode.Name else tostring(keyCode)
		end,
		GetLastInputType = function(): any return state.lastType end,
		GetDeviceForm = function(): any return Enum.DisplaySize.Medium end,
	})
	return uis
end

function lazy.UserService(env: any, ctx: any): any
	return defService(ctx, "UserService", {
		GetUserInfosByUserIdsAsync = function(_self: any, userIds: { number }): { any }
			local out = {}
			for _, uid in userIds do
				local uname = env.userNames[uid] or `Player{uid}`
				table.insert(out, { Id = uid, Username = uname, DisplayName = uname, HasVerifiedBadge = false })
			end
			return out
		end,
	})
end

function lazy.VRService(_env: any, ctx: any): any return defService(ctx, "VRService", nil, { VREnabled = false }) end

function lazy.Chat(env: any, ctx: any): any
	local function filterText(_self: any, text: string, fromPlayerOrUserId: any): string
		local filterFn: ((string, number) -> string)? = env.textFilter
		if filterFn == nil then return text end
		local uid = if type(fromPlayerOrUserId) == "number"
			then fromPlayerOrUserId
			elseif
				type(fromPlayerOrUserId) == "table" and type(fromPlayerOrUserId.UserId) == "number"
			then fromPlayerOrUserId.UserId
			else 0
		return filterFn(text, uid)
	end
	return defService(ctx, "Chat", {
		FilterStringAsync = filterText,
		FilterStringForBroadcast = filterText,
		CanUserChatAsync = function(): boolean return true end,
		CanUsersChatAsync = function(): boolean return true end,
	})
end

for _, name in
	string.split(
		"ReplicatedFirst ServerStorage ServerScriptService StarterPack StarterPlayer Lighting SoundService ProximityPromptService MaterialService LocalizationService AnalyticsService",
		" "
	)
do
	lazy[name] = genericService
end

type Bounds = { minX: number, minY: number, minZ: number, maxX: number, maxY: number, maxZ: number }

local function boundsOf(cframe: any, size: any): Bounds
	local x, y, z, r00, r01, r02, r10, r11, r12, r20, r21, r22 = cframe:GetComponents()
	local sx, sy, sz = size.X / 2, size.Y / 2, size.Z / 2
	local ex = math.abs(r00) * sx + math.abs(r01) * sy + math.abs(r02) * sz
	local ey = math.abs(r10) * sx + math.abs(r11) * sy + math.abs(r12) * sz
	local ez = math.abs(r20) * sx + math.abs(r21) * sy + math.abs(r22) * sz
	return { minX = x - ex, minY = y - ey, minZ = z - ez, maxX = x + ex, maxY = y + ey, maxZ = z + ez }
end

local function overlaps(a: Bounds, b: Bounds): boolean
	return a.minX <= b.maxX
		and a.maxX >= b.minX
		and a.minY <= b.maxY
		and a.maxY >= b.minY
		and a.minZ <= b.maxZ
		and a.maxZ >= b.minZ
end

local function isWithin(inst: any, list: { any }): boolean
	for _, root in list do
		if inst == root or inst:IsDescendantOf(root) then return true end
	end
	return false
end

local eager: { [string]: (env: any, ctx: any) -> any } = {}

function eager.Workspace(_env: any, ctx: any): any
	local createInstance, dt, Enum = ctx.createInstance, ctx.dt, ctx.Enum
	local workspaceInst = createInstance("Workspace", ctx.gameInst, true)
	rawset(workspaceInst, "_isService", true)
	workspaceInst._props.CurrentCamera = createInstance("Camera", workspaceInst, true)
	local terrainInst = createInstance("Terrain", workspaceInst, true)
	workspaceInst._props.Terrain = terrainInst

	local function candidates(params: any?): { any }
		local filterList: { any } = if params ~= nil then params.FilterDescendantsInstances or {} else {}
		local include = params ~= nil and params.FilterType == Enum.RaycastFilterType.Include
		local respectCollide = params ~= nil and params.RespectCanCollide == true
		local out = {}
		for _, inst in workspaceInst:GetDescendants() do
			if inst == terrainInst or not inst:IsA("BasePart") then continue end
			if inst.CanQuery == false or (respectCollide and inst.CanCollide == false) then continue end
			local listed = #filterList > 0 and isWithin(inst, filterList)
			if if include then listed else not listed then table.insert(out, inst) end
		end
		return out
	end

	local function limit(list: { any }, params: any?): { any }
		local maxParts = if params ~= nil then params.MaxParts or 0 else 0
		return if maxParts > 0 and #list > maxParts then table.move(list, 1, maxParts, 1, {}) else list
	end

	rawset(workspaceInst, "_methods", {
		GetServerTimeNow = function(): number return ctx.getUnixTime() end,
		Raycast = function(_self: any, origin: any, direction: any, params: any?): any
			if origin == nil or direction == nil then return nil end
			local o, d = { origin.X, origin.Y, origin.Z }, { direction.X, direction.Y, direction.Z }
			local bestT, bestPart, bestAxis = math.huge, nil :: any, 0
			for _, part in candidates(params) do
				local b = boundsOf(part.CFrame, part.Size)
				local lo, hi = { b.minX, b.minY, b.minZ }, { b.maxX, b.maxY, b.maxZ }
				local tEnter, tExit, axis, miss = -math.huge, math.huge, 0, false
				for i = 1, 3 do
					if math.abs(d[i]) < 1e-12 then
						if o[i] < lo[i] or o[i] > hi[i] then
							miss = true
							break
						end
					else
						local t1, t2 = (lo[i] - o[i]) / d[i], (hi[i] - o[i]) / d[i]
						if t1 > t2 then
							t1, t2 = t2, t1
						end
						if t1 > tEnter then
							tEnter, axis = t1, i
						end
						tExit = math.min(tExit, t2)
					end
				end
				if not miss and tEnter <= tExit and tEnter >= 0 and tEnter <= 1 and tEnter < bestT then
					bestT, bestPart, bestAxis = tEnter, part, axis
				end
			end
			if bestPart == nil then return nil end
			local n = { 0, 0, 0 }
			n[bestAxis] = if d[bestAxis] > 0 then -1 else 1
			return dt.newRaycastResult(
				bestPart,
				origin + direction * bestT,
				dt.Vector3.new(n[1], n[2], n[3]),
				direction.Magnitude * bestT,
				bestPart.Material or Enum.Material.Plastic
			)
		end,
		GetPartBoundsInBox = function(_self: any, cframe: any?, size: any?, params: any?): { any }
			if cframe == nil or size == nil then return {} end
			local query, out = boundsOf(cframe, size), {}
			for _, part in candidates(params) do
				if overlaps(boundsOf(part.CFrame, part.Size), query) then table.insert(out, part) end
			end
			return limit(out, params)
		end,
		GetPartBoundsInRadius = function(_self: any, position: any?, radius: number?, params: any?): { any }
			if position == nil or radius == nil then return {} end
			local out = {}
			for _, part in candidates(params) do
				local b = boundsOf(part.CFrame, part.Size)
				local dx = position.X - math.clamp(position.X, b.minX, b.maxX)
				local dy = position.Y - math.clamp(position.Y, b.minY, b.maxY)
				local dz = position.Z - math.clamp(position.Z, b.minZ, b.maxZ)
				if dx * dx + dy * dy + dz * dz <= radius * radius then table.insert(out, part) end
			end
			return limit(out, params)
		end,
		GetPartsInPart = function(_self: any, part: any?, params: any?): { any }
			if part == nil then return {} end
			local query, out = boundsOf(part.CFrame, part.Size), {}
			for _, other in candidates(params) do
				if other ~= part and overlaps(boundsOf(other.CFrame, other.Size), query) then
					table.insert(out, other)
				end
			end
			return limit(out, params)
		end,
	})
	return workspaceInst
end

function eager.RunService(_env: any, ctx: any): any
	local host = ctx.host
	local isServer, isClient, isStudio = ctx.isServer, ctx.isClient, ctx.isStudio
	local renderSteps: { { name: string, priority: number, seq: number, fn: (number) -> () } } = ctx.renderSteps
	local runService = ctx.createInstance("RunService", ctx.gameInst, true)
	rawset(runService, "_isService", true)
	local props = runService._props

	if host ~= nil and host.RunService ~= nil then
		local runDouble = host.RunService
		props.Heartbeat = runDouble.Heartbeat or ctx.threadedSignal()
		props.PreRender = runDouble.PreRender or ctx.threadedSignal()
		props.RenderStepped = runDouble.RenderStepped or ctx.threadedSignal()
		props.PreAnimation = runDouble.PreAnimation or ctx.threadedSignal()
		props.Stepped = runDouble.Stepped or ctx.threadedSignal()
		props.PreSimulation = runDouble.PreSimulation or ctx.threadedSignal()
		props.PostSimulation = runDouble.PostSimulation or ctx.threadedSignal()
		if isClient and props.PreRender ~= nil then
			local conns: { any } = ctx.serviceConnections
			local conn: any = props.PreRender:Connect(function(step: number)
				for _, entry in table.clone(renderSteps) do
					entry.fn(step)
				end
			end)
			table.insert(conns, conn)
		end
	else
		props.Heartbeat = ctx.threadedSignal()
		props.PreRender = ctx.threadedSignal()
		props.RenderStepped = ctx.threadedSignal()
		props.PreAnimation = ctx.threadedSignal()
		props.Stepped = ctx.threadedSignal()
		props.PreSimulation = ctx.threadedSignal()
		props.PostSimulation = ctx.threadedSignal()
	end
	props._renderSteps = renderSteps

	local seq = 0
	local function unbindRenderStep(_self: any, name: string)
		for i = #renderSteps, 1, -1 do
			if renderSteps[i].name == name then table.remove(renderSteps, i) end
		end
	end

	rawset(runService, "_methods", {
		IsServer = function(): boolean return if props.IsServer ~= nil then props.IsServer else isServer end,
		IsClient = function(): boolean return if props.IsClient ~= nil then props.IsClient else isClient end,
		IsStudio = function(): boolean return if props.IsStudio ~= nil then props.IsStudio else isStudio end,
		IsRunning = function(): boolean return if props.IsRunning ~= nil then props.IsRunning else true end,
		IsRunMode = function(): boolean return if props.IsRunMode ~= nil then props.IsRunMode else false end,
		IsEdit = function(): boolean return false end,
		BindToRenderStep = function(self: any, name: string, priority: number, fn: (number) -> ())
			if ctx.isStrict and not isClient then
				error("RunService:BindToRenderStep() can only be called from a LocalScript", 2)
			end
			unbindRenderStep(self, name)
			seq += 1
			table.insert(renderSteps, { name = name, priority = priority or 0, seq = seq, fn = fn })
			table.sort(
				renderSteps,
				function(a: any, b: any): boolean
					return a.priority < b.priority or (a.priority == b.priority and a.seq < b.seq)
				end
			)
		end,
		UnbindFromRenderStep = unbindRenderStep,
	})
	return runService
end

function eager.Players(env: any, ctx: any): any
	local createInstance, server, client, isServer, isClient =
		ctx.createInstance, ctx.server, ctx.client, ctx.isServer, ctx.isClient
	local playersInst = createInstance("Players", ctx.gameInst, true)
	rawset(playersInst, "_isService", true)

	function env._decoratePlayer(_self: any, player: any): any
		if player == nil then return nil end
		local upgraded = InstanceDouble.upgradePlayer(env, player)
		if (isServer or (server == nil and client == nil)) and rawget(upgraded, "_parent") == nil then
			upgraded.Parent = playersInst
		end
		return upgraded
	end

	local underlyingPlayers = (if ctx.host ~= nil then ctx.host.Players else nil)
		or (if server ~= nil then server.Players or server.players else nil)
		or (if client ~= nil and client.server ~= nil then client.server.Players or client.server.players else nil)
	local standalonePlayers: { any } = {}

	if underlyingPlayers ~= nil and isServer then
		playersInst._props.PlayerAdded = underlyingPlayers.PlayerAdded
		playersInst._props.PlayerRemoving = underlyingPlayers.PlayerRemoving
		local conns: { any } = ctx.serviceConnections
		local addConn: any = underlyingPlayers.PlayerAdded:Connect(function(p: any) env:_decoratePlayer(p) end)
		table.insert(conns, addConn)
		for _, p in underlyingPlayers:GetPlayers() do
			env:_decoratePlayer(p)
		end
	else
		playersInst._props.PlayerAdded = env:signal()
		playersInst._props.PlayerRemoving = env:signal()
	end

	local localSpec: any = (if ctx.opts ~= nil then ctx.opts.localPlayer else nil)
		or (if client ~= nil then client.player else nil)
	if isClient or localSpec ~= nil then
		local lp: any
		if type(localSpec) == "number" then
			lp = env:_decoratePlayer({ UserId = localSpec, Name = `Player{localSpec}` })
		elseif type(localSpec) == "string" then
			lp = env:_decoratePlayer({ UserId = 1, Name = localSpec })
		elseif type(localSpec) == "table" then
			if rawget(localSpec, "_isInstance") == true then
				lp = localSpec
			else
				local uid = localSpec.UserId or 1
				local uname = localSpec.Name or `Player{uid}`
				lp = InstanceDouble.upgradePlayer(env, {
					UserId = uid,
					Name = uname,
					DisplayName = localSpec.DisplayName or uname,
					AccountAge = localSpec.AccountAge or 365,
				})
			end
		else
			lp = env:_decoratePlayer({ UserId = 1, Name = "Player1" })
		end
		lp.Parent = playersInst
		playersInst._props.LocalPlayer, env.LocalPlayer = lp, lp
		table.insert(standalonePlayers, lp)
	end

	function env.addPlayer(_self: any, userIdOrSpec: any, name: string?): any
		local isSpec = type(userIdOrSpec) == "table"
		local userId: number = if isSpec then userIdOrSpec.UserId else userIdOrSpec
		local uname: string = (if isSpec then userIdOrSpec.Name else name) or `Player{userId}`
		local displayName: string = (if isSpec then userIdOrSpec.DisplayName else nil) or uname
		local accountAge: number = (if isSpec then userIdOrSpec.AccountAge else nil) or 365
		env.userNames[userId] = uname
		if underlyingPlayers ~= nil and server ~= nil and isServer then
			local rawPlayer = underlyingPlayers:GetPlayerByUserId(userId)
			if rawPlayer == nil and not isSpec then
				local clientFn: ((any, number, any?) -> any)? = server.client
				if clientFn ~= nil then rawPlayer = clientFn(server, userId, { name = uname }).player end
			end
			if rawPlayer ~= nil then
				local p = env:_decoratePlayer(rawPlayer)
				p.Name, p.DisplayName = uname, displayName
				if playersInst.CharacterAutoLoads == true and p.Character == nil and p.Parent == playersInst then
					p:LoadCharacter()
				end
				return p
			end
		end
		for _, existing in standalonePlayers do
			if existing.UserId == userId then return existing end
		end
		local plr = InstanceDouble.upgradePlayer(env, {
			UserId = userId,
			Name = uname,
			DisplayName = displayName,
			AccountAge = accountAge,
		})
		plr.Parent = playersInst
		table.insert(standalonePlayers, plr)
		-- When `Server:client` passes a spec table, `Server:client` fires `underlyingPlayers.PlayerAdded` right after.
		if not (isSpec and underlyingPlayers ~= nil and isServer) then playersInst.PlayerAdded:Fire(plr) end
		if playersInst.CharacterAutoLoads == true and plr.Parent == playersInst then plr:LoadCharacter() end
		return plr
	end

	function env.removePlayer(_self: any, userIdOrPlayer: any)
		local uid = if type(userIdOrPlayer) == "table" then userIdOrPlayer.UserId else userIdOrPlayer
		if underlyingPlayers ~= nil and server ~= nil and isServer then
			local existing = underlyingPlayers:GetPlayerByUserId(uid)
			local leaveFn: ((any, any) -> ())? = server.leave
			if existing ~= nil and leaveFn ~= nil then leaveFn(server, existing) end
			return
		end
		for i, existing in standalonePlayers do
			if existing.UserId == uid then
				table.remove(standalonePlayers, i)
				playersInst.PlayerRemoving:Fire(existing)
				if existing.Character ~= nil then existing.Character:Destroy() end
				existing.Parent = nil
				break
			end
		end
	end

	local playersMethods: { [string]: any } = {}
	function playersMethods.GetPlayers(_self: any): { any }
		if underlyingPlayers ~= nil and isServer then
			local list = underlyingPlayers:GetPlayers()
			for _, p in list do
				env:_decoratePlayer(p)
			end
			return list
		end
		local out = {}
		for _, child in playersInst:GetChildren() do
			if child.ClassName == "Player" then table.insert(out, child) end
		end
		return if #out > 0 then out else table.clone(standalonePlayers)
	end

	function playersMethods.GetPlayerByUserId(_self: any, userId: number): any
		if underlyingPlayers ~= nil and isServer then
			local p = underlyingPlayers:GetPlayerByUserId(userId)
			return if p then env:_decoratePlayer(p) else nil
		end
		for _, p in playersMethods.GetPlayers(playersInst) do
			if p.UserId == userId then return p end
		end
		return nil
	end

	function playersMethods.GetPlayerFromCharacter(_self: any, character: any): any
		if character == nil then return nil end
		for _, p in playersMethods.GetPlayers(playersInst) do
			if p.Character == character then return p end
		end
		return nil
	end

	function playersMethods.GetNameFromUserIdAsync(_self: any, userId: number): string
		assert(userId and userId > 0, "GetNameFromUserIdAsync: invalid userId")
		if env.userNames[userId] ~= nil then return env.userNames[userId] end
		local p = playersInst:GetPlayerByUserId(userId)
		return if p ~= nil then p.Name else `Player{userId}`
	end

	function playersMethods.GetUserIdFromNameAsync(_self: any, name: string): number
		local lower = string.lower(name)
		for uid, uname in env.userNames do
			if string.lower(uname) == lower then return uid end
		end
		for _, p in playersInst:GetPlayers() do
			if string.lower(p.Name) == lower then return p.UserId end
		end
		local digits = string.match(name, "^[Pp]layer(%d+)$")
		if digits ~= nil then return tonumber(digits) :: number end
		error(`Players:GetUserIdFromNameAsync: unknown user "{name}"`, 0)
	end

	function playersMethods.GetUserThumbnailAsync(_self: any, userId: number): (string, boolean)
		return `rbxthumb://type=AvatarHeadShot&id={userId}&w=420&h=420`, true
	end

	function playersMethods.GetFriendsAsync(_self: any, userId: number): any
		local friendIds: { number } = {}
		for fid in env.friends[userId] or {} do
			table.insert(friendIds, fid)
		end
		table.sort(friendIds)
		local items = table.create(#friendIds)
		for i, fid in friendIds do
			items[i] = { Id = fid, Username = `Player{fid}`, DisplayName = `Player{fid}`, IsOnline = false }
		end
		return DataStoreDouble.makePages(items, math.max(#items, 1))
	end

	local function makeDesc(): any return createInstance("HumanoidDescription") end
	local function makeHumModel(): any
		local model = createInstance("Model")
		createInstance("Humanoid", model)
		return model
	end
	playersMethods.GetHumanoidDescriptionFromUserId = makeDesc
	playersMethods.GetHumanoidDescriptionFromOutfitId = makeDesc
	playersMethods.GetHumanoidDescriptionFromUserIdAsync = makeDesc
	playersMethods.GetHumanoidDescriptionFromOutfitIdAsync = makeDesc
	playersMethods.CreateHumanoidModelFromDescription = makeHumModel
	playersMethods.CreateHumanoidModelFromUserId = makeHumModel
	playersMethods.CreateHumanoidModelFromDescriptionAsync = makeHumModel
	playersMethods.CreateHumanoidModelFromUserIdAsync = makeHumModel

	function playersMethods.BanAsync(_self: any, config: { UserIds: { number }?, DisplayReason: string? })
		for _, uid in (config.UserIds or {}) :: { number } do
			env.bans[uid] = config
			local p = playersInst:GetPlayerByUserId(uid)
			if p ~= nil then p:Kick(config.DisplayReason or "Banned") end
		end
	end

	function playersMethods.UnbanAsync(_self: any, config: { UserIds: { number }? })
		for _, uid in (config.UserIds or {}) :: { number } do
			env.bans[uid] = nil
		end
	end

	function playersMethods.GetBanHistoryAsync(_self: any, userId: number): any
		local item = env.bans[userId]
		return DataStoreDouble.makePages(if item then { item } else {}, 1)
	end

	rawset(playersInst, "_methods", playersMethods)
	return playersInst
end

return table.freeze({
	lazy = table.freeze(lazy),
	eager = table.freeze(eager),
	Easing = table.freeze(Easing),
})
