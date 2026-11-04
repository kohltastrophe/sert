--!nonstrict
--!nolint DeprecatedApi
-- sert.env: globals, instances, module loader, signals, services, and virtual clock.
local sert = require("../src")
local Env = require("../src/env")
local eq, fails, near, test = sert.eq, sert.fails, sert.near, sert.test

test("env · globals, datatypes, CFrame/BasePart/TextSize coupling, utf8, task, tick, DateTime, and os.time", function()
	local e = Env.new({ isClient = true, isStudio = true })
	local g = e.globals

	local c = g.Color3.fromRGB(255, 128, 0)
	eq({ g.typeof(c), c:ToHex(), g.Color3.fromHex("#ff8000") }, { "Color3", "ff8000", c })
	local h, s, v = c:ToHSV()
	near(g.Color3.fromHSV(h, s, v).R, c.R, 1e-3)
	eq(g.BrickColor.new("Bright red").Name, "Bright red")
	eq(g.UDim2.fromOffset(120, 40) + g.UDim2.fromScale(0.5, 1), g.UDim2.new(0.5, 120, 1, 40))
	near(g.Vector2.new(3, 4).Magnitude, 5)
	near(g.Vector2.new(3, 4).Unit.Magnitude, 1)
	local v3 = g.Vector3.new(1, 2, 2)
	eq({ math.round(v3.Magnitude), v3:Cross(g.Vector3.xAxis) }, { 3, g.Vector3.new(0, 2, -2) })
	local cf = g.CFrame.new(10, 20, 30) * g.CFrame.Angles(0, math.pi / 2, 0)
	eq(cf * cf:Inverse(), g.CFrame.identity)
	eq(g.DateTime.fromIsoDate("2025-01-15T12:30:00Z"):ToIsoDate(), "2025-01-15T12:30:00Z")
	local key = g.Enum.KeyCode.Semicolon
	eq({ g.typeof(key), tostring(key), key:IsA("KeyCode") }, { "EnumItem", "Enum.KeyCode.Semicolon", true })

	-- CFrame.fromOrientation r21, BasePart.Position rotation, TextSize bounds, JSON surrogate pairs
	local rx, ry, rz = 0.4, 0.7, 1.1
	local _, _, _, _, _, _, _, _, _, _, r21 = g.CFrame.fromOrientation(rx, ry, rz):GetComponents()
	near(r21, math.sin(ry) * math.sin(rz) + math.cos(ry) * math.sin(rx) * math.cos(rz), 1e-6)
	local part = e.Instance.new("Part")
	local rot = g.CFrame.Angles(0.3, 0.6, 0.9)
	part.CFrame = rot + g.Vector3.new(1, 2, 3)
	part.Position = g.Vector3.new(10, 20, 30)
	eq(part.CFrame, rot + g.Vector3.new(10, 20, 30))

	local label = e.Instance.new("TextLabel")
	label.Text = "Hello"
	local firedBounds: any = nil
	label:GetPropertyChangedSignal("TextBounds"):Connect(function() firedBounds = label.TextBounds end)
	label.TextSize = 28
	eq(firedBounds, g.Vector2.new(math.ceil(5 * 28 * 0.55), math.ceil(28 * 1.2)))
	eq(e.game:GetService("HttpService"):JSONDecode('{"emoji":"\\uD83D\\uDE00"}').emoji, "\u{1F600}")

	-- utf8, Params, PhysicalProperties, task.delay + cancel, os.time, env:run, tick/DateTime fractions
	local graphemes = {}
	for first, last in g.utf8.graphemes("Aé😊") do
		table.insert(graphemes, string.sub("Aé😊", first, last))
	end
	eq({ graphemes, g.utf8.nfcnormalize("abc"), g.utf8.nfdnormalize("abc") }, { { "A", "é", "😊" }, "abc", "abc" })
	eq({
		g.RaycastParams.new().CollisionGroup,
		g.OverlapParams.new().CollisionGroup,
		g.PhysicalProperties.new(1, 0.5, 0.2).Density,
	}, { "Default", "Default", 1 })
	sert(g.os.time() >= 1700000000 and g.os.time({ year = 2025, month = 1, day = 1 }) > 0)

	local cancelledFired = false
	e.task.cancel(e.task.delay(0.1, function() cancelledFired = true end))
	e:step(0.2)
	eq({ cancelledFired, e:run(function(x: number) return x + 1 end, 41) }, { false, 42 })

	local tick0, millis0, os0 = g.tick(), g.DateTime.now().UnixTimestampMillis, g.os.time()
	e.task.wait(0.25)
	near(g.tick() - tick0, 0.25, 1e-6)
	eq({ g.DateTime.now().UnixTimestampMillis - millis0, g.os.time() }, { 250, os0 })
end)

test("env · virtual Instances, geometry/setAbsolute, defaults, strict coercion, tags, attributes, and Kick", function()
	local e1, e2 = sert.env.new(), sert.env.new()
	local folder = e1.Instance.new("Folder", e1.game:GetService("ReplicatedStorage"))
	folder.Name = "Root"
	local frame = e1.Instance.new("Frame", folder)
	frame.Name, frame.Size = "Card", e1.globals.UDim2.fromOffset(240, 80)
	eq(
		{ e1.globals.typeof(frame), frame.AbsoluteSize, folder:FindFirstChild("Card") },
		{ "Instance", e1.globals.Vector2.new(240, 80), frame }
	)

	local attrObserved = nil
	frame:GetAttributeChangedSignal("Theme"):Connect(function(val) attrObserved = val end)
	frame:SetAttribute("Theme", "Dark")
	eq({ frame:GetAttribute("Theme"), attrObserved }, { "Dark", "Dark" })

	local cs = e1.game:GetService("CollectionService")
	cs:AddTag(frame, "Themed")
	eq({ frame:HasTag("Themed"), #cs:GetTagged("Themed") }, { true, 1 })
	cs:RemoveTag(frame, "Themed")
	eq(#cs:GetTagged("Themed"), 0)

	-- Lenient method stubbing vs strict rejection
	local dss = e1.game:GetService("DataStoreService")
	local origGetDs = dss.GetDataStore
	dss.GetDataStore = function() error("patched") end
	fails(function() dss:GetDataStore("x") end, "patched")
	dss.GetDataStore = nil
	eq(dss.GetDataStore, origGetDs)
	local pA, pB = e1.Instance.new("Part"), e1.Instance.new("Part")
	pA.FindFirstChild = function() return "stub" end
	eq({ pA:FindFirstChild("x"), pB:FindFirstChild("x") }, { "stub", nil })

	local strict = sert.env.new({ strict = true })
	fails(function()
		strict.Instance.new("Part").FindFirstChild = function() end
	end, "Property is read only")
	fails(function()
		strict.game:GetService("DataStoreService").GetDataStore = function() end
	end, "Property is read only")

	-- GuiObject geometry and setAbsolute
	local UDim2, Vector2 = e1.globals.UDim2, e1.globals.Vector2
	local screen = e1.Instance.new("ScreenGui")
	eq(screen.AbsoluteSize, Vector2.new(1280, 720))
	local gFrame = e1.Instance.new("Frame")
	gFrame.Size, gFrame.Position, gFrame.AnchorPoint =
		UDim2.new(0.5, 10, 0.25, 0), UDim2.fromScale(0.5, 0.5), Vector2.new(0.5, 0.5)
	eq(gFrame.AbsoluteSize, Vector2.new(10, 0))
	gFrame.Parent = screen
	eq({ gFrame.AbsoluteSize, gFrame.AbsolutePosition }, { Vector2.new(650, 180), Vector2.new(315, 270) })
	local gLabel = e1.Instance.new("TextLabel", e1.Instance.new("Folder", gFrame))
	gLabel.Size, gLabel.Position = UDim2.new(1, -10, 1, -10), UDim2.fromOffset(5, 5)
	eq({ gLabel.AbsoluteSize, gLabel.AbsolutePosition }, { Vector2.new(640, 170), Vector2.new(320, 275) })
	e1:setAbsolute(gFrame, Vector2.new(400, 300), Vector2.new(0, 0))
	eq(gLabel.AbsoluteSize, Vector2.new(390, 290))
	gFrame.Size = UDim2.fromOffset(1, 1)
	e1:setAbsolute(gFrame)
	eq(gFrame.AbsoluteSize, Vector2.new(1, 1))
	e1:setAbsolute(screen, Vector2.new(800, 600))
	eq(gFrame.AbsolutePosition, Vector2.new(399.5, 299.5))
	gLabel.AbsoluteSize = Vector2.new(7, 7)
	eq(gLabel.AbsoluteSize, Vector2.new(7, 7))
	fails(function() e1:setAbsolute(e1.Instance.new("Folder"), Vector2.zero) end, "expected a GuiBase2d")
	local sFrame = strict.Instance.new("Frame")
	fails(function() sFrame.AbsoluteSize = Vector2.new(1, 1) end, "read only")
	strict:setAbsolute(sFrame, Vector2.new(3, 4))
	eq(sFrame.AbsoluteSize, Vector2.new(3, 4))

	-- Defaults, TextBounds, destroyed tags, injected datatypes, int/int64 coercion, unimplemented method, attributes, Kick, public keys
	for _, env in { e1, strict } do
		for cls, txt in { TextLabel = "Label", TextButton = "Button", TextBox = "TextBox" } do
			local inst = env.Instance.new(cls)
			eq(inst.Text, txt)
			sert(inst.TextBounds.X > 0)
		end
		fails(
			function() env.Instance.new("Humanoid"):LoadAnimation(env.Instance.new("Animation")) end,
			"does not implement"
		)
	end
	sFrame.ZIndex = 2.6
	eq(sFrame.ZIndex, 2)
	sFrame.ZIndex = -2.6
	eq(sFrame.ZIndex, -2)
	local iv = strict.Instance.new("IntValue")
	iv.Value = 1.7
	eq(iv.Value, 2)
	iv.Value = -2.5
	eq(iv.Value, -3)

	local loot = e1.Instance.new("Part", e1.workspace)
	loot:AddTag("Loot")
	loot:Destroy()
	eq({ loot:HasTag("Loot"), #cs:GetTagged("Loot") }, { true, 0 })

	local marker = {}
	local custom = sert.env.new({
		datatypes = setmetatable(
			{ UDim = { new = function(s, o) return { marker = marker, Scale = s, Offset = o } end } },
			{ __index = e1.datatypes }
		),
	})
	eq(custom.Instance.new("UIPadding").PaddingTop.marker, marker)

	for _, name in { "a.b", "a-b", "a/b", "a_b" } do
		pB:SetAttribute(name, 1)
		eq(pB:GetAttribute(name), 1)
	end
	for _, bad in { "a b", "RBXName", string.rep("a", 101) } do
		fails(function() pB:SetAttribute(bad, 1) end, "is invalid")
	end
	pB:SetAttribute("Ref", e1.workspace)
	eq(pB:GetAttribute("Ref"), e1.workspace)

	local player = e2:addPlayer(7)
	player:LoadCharacter()
	local char = player.Character
	e2:advance(2)
	player:Kick("bye")
	player:Kick("again")
	eq({ player.Parent, char.Parent, #e2.kicks, e2.kicks[1].message }, { nil, nil, 1, "bye" })
	e2:addPlayer(8):Kick()
	eq(e2.kicks[2].message, "")
end)

test(
	"env · stage mounting, require resolution, caching, cycles, nil/multi returns, and DataModel place mount",
	function()
		local e1, e2 = sert.env.new(), sert.env.new()
		local stage = {
			root = {
				name = "RootMod",
				className = "ModuleScript",
				file = "RootMod.luau",
				props = { Tags = { "RootTag" } },
				attributes = { Ver = 1 },
				children = {
					ChildA = { name = "ChildA", className = "ModuleScript", file = "ChildA.luau", children = {} },
					ChildB = {
						name = "ChildB",
						className = "ModuleScript",
						file = "ChildB.luau",
						children = {
							Grand = { name = "Grand", className = "ModuleScript", file = "Grand.luau", children = {} },
						},
					},
					Cycle1 = { name = "Cycle1", className = "ModuleScript", file = "Cycle1.luau", children = {} },
					NoFactory = { name = "NoFactory", className = "ModuleScript", children = {} },
					ValChild = { name = "ValChild", className = "IntValue", value = 99 },
				},
			},
			files = {
				["RootMod.luau"] = function()
					return function(_ENV: any)
						if setfenv ~= nil then (setfenv :: any)(1, _ENV) end
						_ENV.shared.count = (_ENV.shared.count or 0)
							+ _ENV.require("@self/ChildA")
							+ _ENV.require("@self/./ChildB/Grand")
						return _ENV.shared.count
					end
				end,
				["ChildA.luau"] = function()
					return function(_ENV: any) return _ENV.require("./ChildB") * 2 end
				end,
				["ChildB.luau"] = function()
					return function() return 5 end
				end,
				["Grand.luau"] = function()
					return function(_ENV: any) return _ENV.require("../ChildB") end
				end,
				["Cycle1.luau"] = function()
					return function(_ENV: any) return _ENV.require(_ENV.script) end
				end,
			},
		}
		local m1, m2 = e1:mount(stage), e2:mount(stage)
		eq({
			m1:HasTag("RootTag"),
			m1:GetAttribute("Ver"),
			m1.ValChild.Value,
			e1:require(m1),
			e1:require(m1),
			e2:require(m2),
		}, { true, 1, 99, 15, 15, 15 })
		fails(function() e1:require(m1.Cycle1) end, "cyclic require")
		fails(function() e1:require(m1.NoFactory) end, "no staged factory")

		local runs = 0
		local function makeMod(name: string, body: () -> ...any): any
			local m = e1.Instance.new("ModuleScript")
			m.Name = name
			rawset(m, "_factory", body)
			return m
		end
		local nilMod = makeMod("Nil", function()
			runs += 1
			return nil
		end)
		eq({ e1:require(nilMod), e1:require(nilMod), runs }, { nil, nil, 1 })
		fails(function()
			e1:require(makeMod("Empty", function() end))
		end, "did not return exactly one value")
		fails(function()
			e1:require(makeMod("Two", function() return 1, 2 end))
		end, "did not return exactly one value")

		local placeStage = {
			root = {
				name = "Place",
				className = "DataModel",
				children = {
					ReplicatedStorage = {
						className = "ReplicatedStorage",
						children = { Shared = { className = "Folder", children = {} } },
					},
				},
			},
			files = {},
		}
		eq({ e1:mount(placeStage), e1.game.ReplicatedStorage.Shared.ClassName }, { e1.game, "Folder" })
		fails(
			function() e1:mount(placeStage, e1.workspace) end,
			"a place project (DataModel root) mounts into env.game"
		)
	end
)

test("env · Signal:Wait and WaitForChild across test threads, spawned threads, and custom hosts", function()
	local e = sert.env.new()
	local sig = e:signal()
	e.task.delay(0.05, function() sig:Fire("delayed", 42) end)
	eq({ sig:Wait() }, { "delayed", 42 })

	local spA, spB
	e.task.spawn(function()
		spA, spB = sig:Wait()
	end)
	sig:Fire("spawned", 99)
	eq({ spA, spB }, { "spawned", 99 })

	e.task.delay(10, function() sig:Fire("late") end)
	eq(sig:Wait(), "late")
	fails(function() sig:Wait() end, "Signal:Wait(): nothing scheduled can fire this signal")

	local beat = e.game:GetService("RunService").Heartbeat:Connect(function() end)
	fails(function() sig:Wait() end, "Signal:Wait(): the signal did not fire within 300 virtual seconds")
	beat:Disconnect()

	local got, hSig
	local co = coroutine.create(function()
		local he = sert.env.new({ host = { clock = function() return 0 end, wait = coroutine.yield } })
		hSig = he:signal()
		got = hSig:Wait()
	end)
	assert(coroutine.resume(co))
	hSig:Fire("hi")
	eq(got, "hi")
	fails(function()
		table.sort({ 1, 2 }, function()
			hSig:Wait()
			return false
		end)
	end, "Signal:Wait() called on a thread that cannot yield")

	for _, strict in { false, true } do
		local env = sert.env.new({ strict = strict })
		local folder = env.Instance.new("Folder")
		env.task.delay(0.5, function()
			local p = env.Instance.new("Part")
			p.Name, p.Parent = "Late", folder
		end)
		eq(folder:WaitForChild("Late", 2).Name, "Late")
		eq(folder:WaitForChild("Never", 1), nil)
		local spFound
		env.task.spawn(function() spFound = folder:WaitForChild("Spawned", 3) end)
		local ch = env.Instance.new("Folder")
		ch.Name, ch.Parent = "Spawned", folder
		eq(spFound, ch)
	end
	eq(sert.env.new().Instance.new("Folder"):WaitForChild("Absent"), nil)
	local sEnv = sert.env.new({ strict = true })
	local sFolder = sEnv.Instance.new("Folder")
	sEnv.task.delay(2, function()
		local p = sEnv.Instance.new("Part")
		p.Name, p.Parent = "Part", sFolder
	end)
	eq(sFolder:WaitForChild("Part").Name, "Part")
	fails(function() sFolder:WaitForChild("Absent") end, 'WaitForChild("Absent")')
	local sBeat = sEnv.game:GetService("RunService").Heartbeat:Connect(function() end)
	eq(sFolder:WaitForChild("Late", 400), nil)
	sBeat:Disconnect()
end)

test(
	"env.services · DataModel, RunService, Workspace, Players, TextChat, Http, Text, Marketplace, Group, Badge, Policy, Teleport, Input/UI, Physics, DataStore, and MemoryStore",
	function()
		local e = sert.env.new({ isClient = true, isStudio = true })
		local g = e.globals
		eq({
			e.game:IsLoaded(),
			e.game:GetObjects("rbxassetid://1"),
			e.game.Workspace,
			e.game.workspace,
			e.game.PlaceVersion,
		}, { true, {}, e.workspace, e.workspace, 0 })
		local closeCount = 0
		e.game:BindToClose(function()
			closeCount += 1
		end)

		local rs = e.game:GetService("RunService")
		eq({ rs:IsClient(), rs:IsStudio(), rs:IsRunning(), rs:IsRunMode() }, { true, true, true, false })
		local rSteps = {}
		rs:BindToRenderStep("late", 200, function() table.insert(rSteps, "late") end)
		rs:BindToRenderStep("early", 100, function() table.insert(rSteps, "early") end)
		e:step(1 / 60)
		eq(rSteps, { "early", "late" })
		rs:UnbindFromRenderStep("early")
		rs:UnbindFromRenderStep("late")

		-- Players, Character, Ban, Friends, PlayerGui
		local p1 = e:addPlayer(201, "Alice")
		eq(e:addPlayer(201, "Alice"), p1)
		p1:LoadCharacter()
		e.Instance.new("Accessory", p1.Character)
		e.Instance.new("Shirt", p1.Character)
		p1:ClearCharacterAppearance()
		eq({
			e.Players:GetPlayerByUserId(201),
			e.Players:GetPlayerFromCharacter(p1.Character),
			e.Players:GetPlayerFromCharacter(nil),
		}, { p1, p1, nil })
		eq({
			e.Players:GetNameFromUserIdAsync(201),
			e.Players:GetNameFromUserIdAsync(999),
			e.Players:GetUserIdFromNameAsync("alice"),
			e.Players:GetUserIdFromNameAsync("Player777"),
		}, { "Alice", "Player999", 201, 777 })
		fails(function() e.Players:GetUserIdFromNameAsync("NoSuchUser") end, "unknown user")
		local thumb, ready = e.Players:GetUserThumbnailAsync(201)
		eq(ready and string.find(thumb, "201", 1, true) ~= nil, true)
		e.friends[201] = { [202] = true }
		eq({ p1:IsFriendsWith(202), #e.Players:GetFriendsAsync(201):GetCurrentPage() }, { true, 1 })
		local d1 = e.Players:GetHumanoidDescriptionFromUserId(201)
		eq({
			d1.ClassName,
			e.Players:GetHumanoidDescriptionFromOutfitId(10).ClassName,
			e.Players:CreateHumanoidModelFromDescription(d1).ClassName,
			e.Players:CreateHumanoidModelFromUserId(201).ClassName,
		}, { "HumanoidDescription", "HumanoidDescription", "Model", "Model" })
		e.Players:BanAsync({ UserIds = { 201 }, DisplayReason = "Bye" })
		eq(#e.Players:GetBanHistoryAsync(201):GetCurrentPage(), 1)
		e.Players:UnbanAsync({ UserIds = { 201 } })
		eq(#e.Players:GetBanHistoryAsync(201):GetCurrentPage(), 0)
		e:removePlayer(201)

		local hitFrame = e.Instance.new("Frame", e.Instance.new("ScreenGui", e.LocalPlayer.PlayerGui))
		hitFrame.Position, hitFrame.Size = g.UDim2.fromOffset(10, 10), g.UDim2.fromOffset(50, 50)
		eq(e.LocalPlayer.PlayerGui:GetGuiObjectsAtPosition(20, 20), { hitFrame })

		-- Container services, LogService, StudioTestService, EncodingService
		for _, sName in
			{
				"ReplicatedFirst",
				"ServerStorage",
				"ServerScriptService",
				"StarterPack",
				"StarterPlayer",
				"Lighting",
				"SoundService",
				"Chat",
				"ProximityPromptService",
				"MaterialService",
				"LocalizationService",
				"AnalyticsService",
				"LogService",
				"ScriptContext",
				"VRService",
				"MemoryStoreService",
				"EncodingService",
			}
		do
			eq(e.game:GetService(sName).ClassName, sName)
		end
		local logMsgs = {}
		e.game
			:GetService("LogService").MessageOut
			:Connect(function(msg, t) table.insert(logMsgs, { msg = msg, t = t }) end)
		sert.capture(function()
			g.print("hello", 123)
			g.warn("careful")
		end)
		eq(#logMsgs, 2)
		local sts = e.game:GetService("StudioTestService")
		sts.TestArgs = { a = 1 }
		sts:EndTest("done")
		eq({ sts:GetTestArgs(), sts.EndedResult }, { { a = 1 }, "done" })
		local encSvc = e.game:GetService("EncodingService")
		eq({
			buffer.len(encSvc:ComputeBufferHash(buffer.fromstring("hi"), g.Enum.HashAlgorithm.Blake3)),
			#encSvc:ComputeStringHash("hi", g.Enum.HashAlgorithm.Blake3),
		}, { 32, 64 })

		-- TextChatService, ContentProvider, ReflectionService, Teams, MessagingService, HttpService, TextService
		local tcs = e.game:GetService("TextChatService")
		eq({ tcs:CanUserChatAsync(1), tcs:CanUsersChatAsync(1, 2) }, { true, true })
		tcs:DisplayBubble(e.workspace, "hi")
		tcs.OnIncomingMessage = function() return { PrefixText = "[Sys]" } end
		local chan = e.Instance.new("TextChannel", tcs)
		chan:AddUserAsync(1)
		chan:AddUserAsync(1)
		chan:SetDirectChatRequester(e.LocalPlayer)
		eq(chan:GetDirectChatRequester(), e.LocalPlayer)
		chan.ShouldDeliverCallback = function() return true end
		chan.OnIncomingMessage = function() return { Text = "override" } end
		eq({ chan:SendAsync("hello", "meta").Text, chan:DisplaySystemMessage("sys").Text }, { "override", "sys" })

		local preloaded = {}
		e.game:GetService("ContentProvider"):PreloadAsync({ "rbxassetid://1" }, function(id, st) preloaded[id] = st end)
		eq(preloaded["rbxassetid://1"], g.Enum.AssetFetchStatus.Success)
		local refl = e.game:GetService("ReflectionService")
		eq(refl:GetClass("Part").Superclass, "FormFactorPart")
		sert(#refl:GetPropertiesOfClass("Part") > 5)
		local teams = e.game:GetService("Teams")
		local t1 = e.Instance.new("Folder", teams)
		eq(teams:GetTeams(), { t1 })

		local http = e.game:GetService("HttpService")
		eq(
			{ http:UrlEncode("a b+c"), http:GetAsync("https://x"), http:PostAsync("https://x", "{}") },
			{ "a%20b%2Bc", "{}", "{}" }
		)
		fails(function() http:JSONDecode('"\\u+041"') end, "invalid \\u escape")

		local ts = e.game:GetService("TextService")
		sert(ts:GetTextSize("Hello World Long Text", 14, g.Enum.Font.SourceSans, g.Vector2.new(30, 100)).Y > 14)
		sert(ts:GetTextBoundsAsync({ Text = "Hello World", Size = 16, Width = 20 }).Y >= 16)

		-- MarketplaceService, GroupService, BadgeService, PolicyService, TeleportService, config helpers
		local mps = e.game:GetService("MarketplaceService")
		eq(mps:GetProductInfo(10).Name, "Asset10")
		e:setBadge(1, 99)
		eq(e.game:GetService("BadgeService"):UserHasBadgeAsync(1, 99), true)
		e:setBadge(1, 99, false)
		eq({
			e.game:GetService("BadgeService"):AwardBadge(1, 99),
			e.game:GetService("BadgeService"):GetBadgeInfoAsync(99).Name,
		}, { true, "Badge99" })
		e:setGamePass(1, 5)
		e:setProductInfo(10, { Name = "Custom10" })
		e.marketplace.assets[1], e.marketplace.bundles[1], e.marketplace.subscriptions[1] =
			{ [6] = true }, { [7] = true }, { sub1 = true }
		eq({
			mps:GetProductInfo(10).Name,
			mps:UserOwnsGamePassAsync(1, 5),
			mps:PlayerOwnsAsset(e.LocalPlayer, 6),
			mps:PlayerOwnsBundle(e.LocalPlayer, 7),
			mps:CheckUserSubscriptionStatusAsync(e.LocalPlayer, "sub1").IsSubscribed,
		}, { "Custom10", true, true, true, true })
		mps:PromptGamePassPurchase(e.LocalPlayer, 5)
		mps:PromptPurchase(e.LocalPlayer, 6)
		mps:PromptBundlePurchase(e.LocalPlayer, 7)
		mps:PromptSubscriptionPurchase(e.LocalPlayer, "sub1")
		mps:PromptProductPurchase(e.LocalPlayer, 8)
		eq(#mps._props._prompts, 5)

		e:setGroupRank(1, 50, 255, "Owner")
		eq({
			e.game:GetService("GroupService"):GetGroupInfoAsync(50).Name,
			e.LocalPlayer:GetRankInGroup(50),
			e.LocalPlayer:GetRoleInGroup(50),
			e.LocalPlayer:IsInGroup(50),
		}, { "Group50", 255, "Owner", true })
		eq(e.game:GetService("PolicyService"):GetPolicyInfoForPlayerAsync(e.LocalPlayer).AreAdsAllowed, true)
		local tp = e.game:GetService("TeleportService")
		tp:TeleportAsync(123, { e.LocalPlayer })
		eq({ #e.teleports, tp:ReserveServer(123) }, { 1, "access-123", "server-123" })
		e:onHttp(function(req) return { Body = req.Url } end)
		eq(http:GetAsync("https://x.test"), "https://x.test")
		e:onTextFilter(function(txt) return string.upper(txt) end)
		local fRes = ts:FilterStringAsync("abc", 1)
		eq({
			fRes:GetNonChatStringForBroadcastAsync(),
			fRes:GetNonChatStringForUserAsync(2),
			fRes:GetChatForUserAsync(2),
		}, { "ABC", "ABC", "ABC" })

		-- UIS, GuiService, StarterGui, ContextActionService, UserService, Debris, Insert, Asset, Physics, Avatar, GetService/FindService
		local uis = e.game:GetService("UserInputService")
		eq({
			uis:GetMouseLocation(),
			uis:GetMouseDelta(),
			uis:IsKeyDown(g.Enum.KeyCode.A),
			uis:IsMouseButtonPressed(g.Enum.UserInputType.MouseButton1),
			uis:GetFocusedTextBox(),
			uis:GetStringForKeyCode(g.Enum.KeyCode.A),
			uis:GetDeviceForm(),
		}, { g.Vector2.zero, g.Vector2.zero, false, false, nil, "A", g.Enum.DisplaySize.Medium })
		eq(
			{ (e.game:GetService("GuiService"):GetGuiInset()), e.game:GetService("GuiService"):IsTenFootInterface() },
			{ g.Vector2.new(0, 36), false }
		)
		local sguiSvc = e.game:GetService("StarterGui")
		sguiSvc:SetCore("ResetButtonCallback", false)
		sguiSvc:SetCoreGuiEnabled("All", false)
		eq({ sguiSvc:GetCore("ResetButtonCallback"), sguiSvc:GetCoreGuiEnabled("All") }, { false, false })
		local cas = e.game:GetService("ContextActionService")
		cas:BindAction("Jump", function() end, false, g.Enum.KeyCode.Space)
		cas:BindActionAtPriority("Run", function() end, false, 1, g.Enum.KeyCode.LeftShift)
		cas:UnbindAction("Jump")
		cas:UnbindAllActions()
		eq(
			{ cas:GetAllBoundActionInfo(), e.game:GetService("UserService"):GetUserInfosByUserIdsAsync({ 1 })[1].Id },
			{ {}, 1 }
		)
		local debrisItem = e.Instance.new("Part", e.workspace)
		e.game:GetService("Debris"):AddItem(debrisItem, 0.05)
		e:step(0.1)
		eq(debrisItem.Parent, nil)
		eq({
			e.game:GetService("InsertService"):LoadAsset(42).Name,
			e.game:GetService("InsertService"):CreateMeshPartAsync("rbxassetid://10").MeshId,
		}, { "Asset42", "rbxassetid://10" })
		local as = e.game:GetService("AssetService")
		eq({
			as:CreateMeshPartAsync("rbxassetid://11").MeshId,
			as:CreateEditableImageAsync({ Size = g.Vector2.new(64, 64) }).Size,
			as:CreateEditableMeshAsync().ClassName,
		}, { "rbxassetid://11", g.Vector2.new(64, 64), "EditableMesh" })
		e:shutdown()
		eq(closeCount, 1)

		local phys = e.game:GetService("PhysicsService")
		phys:RegisterCollisionGroup("Ghost")
		phys:CollisionGroupSetCollidable("Ghost", "Default", false)
		eq(
			{ phys:IsCollisionGroupRegistered("Ghost"), phys:CollisionGroupsAreCollidable("Ghost", "Default") },
			{ true, false }
		)
		phys:UnregisterCollisionGroup("Ghost")
		eq(
			e.game:GetService("AvatarEditorService"):SearchCatalogAsync(g.CatalogSearchParams.new()):GetCurrentPage(),
			{}
		)
		fails(function() e.game:GetService("NotAService") end, "is not a valid Service name")
		fails(function() e.game:GetService("Part") end, "is not a valid Service name")
		eq(e.game:FindService("Part"), nil)

		-- DataStore versions & MemoryStore expiry + long-poll
		local ds = e.game:GetService("DataStoreService"):GetDataStore("VStore")
		ds:SetAsync("k", "first")
		ds:SetAsync("k", "second")
		ds:RemoveAsync("k")
		ds:SetAsync("k", "third")
		ds:RemoveAsync("k")
		eq({ #ds:ListVersionsAsync("k"):GetCurrentPage(), (ds:GetVersionAsync("k", "1")) }, { 3, "first" })

		local msEnv = sert.env.new({ isServer = true })
		local msSvc = msEnv.game:GetService("MemoryStoreService")
		local map = msSvc:GetSortedMap("m")
		map:SetAsync("k", "v", 5)
		msEnv:advance(6)
		eq(map:GetAsync("k"), nil)
		local q = msSvc:GetQueue("q")
		eq({ q:ReadAsync(1, false, 5) }, { {} })
		local qRead
		msEnv.task.spawn(function() qRead = q:ReadAsync(1, false, 10) end)
		msEnv:advance(1)
		q:AddAsync("item", 60)
		msEnv:advance(1)
		eq(qRead, { "item" })
		msEnv:advance(31)
		eq(q:GetSizeAsync(true), 1)
		local msDouble: any = rawget(msSvc, "_double")
		msDouble:fail("SetAsync")
		fails(function() msSvc:GetHashMap("h"):SetAsync("k", 1, 5) end, "injected failure")
	end
)

test(
	"env · clock, RunService phases, TweenService, input, spatial queries, CharacterAutoLoads, waitFor, active, and host",
	function()
		local e = sert.env.new({ frameRate = 10 })
		fails(function() e.now = 5 end, "env.now is read-only")
		local order = {}
		e.task.spawn(function()
			e.task.defer(function() table.insert(order, "defer") end)
			e.task.spawn(function() table.insert(order, "spawn") end)
			table.insert(order, "body")
		end)
		eq(order, { "spawn", "body", "defer" })
		local flushed = false
		e.task.defer(function() flushed = true end)
		e:flush()
		eq(flushed, true)

		local tOrd = {}
		e.task.delay(0.2, function() table.insert(tOrd, "b") end)
		e.task.delay(0.1, function() table.insert(tOrd, "a") end)
		e:advance(0.25)
		eq(tOrd, { "a", "b" })
		e.task.wait(1)
		e.task.delay(0.1, function() error("late boom") end)
		fails(function() e:advance(0.2) end, "late boom")

		-- wakeDue past dead/cancelled thread
		local deadCo = coroutine.create(function() end)
		coroutine.resume(deadCo)
		e.task.delay(0.02, deadCo)
		e.task.cancel(e.task.delay(0.03, function() end))
		local wokeAfterDead = false
		e.task.delay(0.05, function() wokeAfterDead = true end)
		e:step(0.1)
		eq(wokeAfterDead, true)

		-- RunService phases and yielding Heartbeat handler
		local ce = sert.env.new({ isClient = true })
		local crs = ce.game:GetService("RunService")
		local seen = {}
		for _, n in { "Heartbeat", "PostSimulation", "PreSimulation", "PreAnimation", "PreRender" } do
			crs[n]:Connect(function() table.insert(seen, n) end)
		end
		crs:BindToRenderStep("cam", 200, function() table.insert(seen, "b200") end)
		crs:BindToRenderStep("in", 100, function() table.insert(seen, "b100") end)
		ce:step(0.1)
		eq(seen, { "b100", "b200", "PreRender", "PreAnimation", "PreSimulation", "PostSimulation", "Heartbeat" })

		local se = sert.env.new()
		local srs = se.game:GetService("RunService")
		local afterYield = false
		srs.Heartbeat:Connect(function() se.task.wait(1) end)
		srs.Heartbeat:Connect(function() afterYield = true end)
		se:step()
		eq(afterYield, true)

		-- TweenService curves, play/pause/cancel/repeat/reverse, goal validation, joint/light/nil-start
		local g = se.globals
		local tws = se.game:GetService("TweenService")
		local Style, Dir = g.Enum.EasingStyle, g.Enum.EasingDirection
		for _, st in
			{
				Style.Linear,
				Style.Quad,
				Style.Sine,
				Style.Cubic,
				Style.Exponential,
				Style.Back,
				Style.Bounce,
				Style.Elastic,
			}
		do
			for _, dr in { Dir.In, Dir.Out, Dir.InOut } do
				tws:GetValue(0.5, st, dr)
			end
		end
		local tPart = se.Instance.new("Part")
		local info = g.TweenInfo.new(1, Style.Linear)
		for _, bad in { { Nope = 1 }, { Transparency = "x" }, { Name = "x" }, { Touched = 1 } } do
			fails(function() tws:Create(tPart, info, bad) end)
		end
		local tw = tws:Create(
			tPart,
			g.TweenInfo.new(0.5, Style.Linear, Dir.In, 1, true, 0.2),
			{ Transparency = 1, Anchored = true, Position = g.Vector3.new(10, 0, 0) }
		)
		tw:Play()
		se:advance(0.2)
		tw:Pause()
		se:advance(0.2)
		tw:Play()
		se:advance(3)
		eq(tw.PlaybackState, g.Enum.PlaybackState.Completed)
		local img = se.Instance.new("ImageLabel")
		local holder = se.Instance.new("Folder")
		holder.Cell = g.Vector2int16.new(0, 0)
		tws:Create(img, info, { SliceCenter = g.Rect.new(10, 20, 30, 40) }):Play()
		tws:Create(holder, info, { Cell = g.Vector2int16.new(5, -5) }):Play()
		tws:Create(se.Instance.new("Motor6D"), info, { C0 = g.CFrame.new(0, 2, 0) }):Play()
		tws:Create(se.Instance.new("PointLight"), info, { Brightness = 3 }):Play()
		tws:Create(se.Instance.new("SelectionBox"), info, { Color3 = g.Color3.new(1, 0, 0) }):Play()
		se:advance(0.5)
		tw:Play()
		tw:Cancel()

		-- Input: keys, mouse, click ordering (DisplayOrder, Sibling, Global, BillboardGui), TextBox focus/type
		local uis = ce.game:GetService("UserInputService")
		local input = ce:input()
		uis.InputBegan:Connect(function() end)
		uis.InputEnded:Connect(function() end)
		uis.InputChanged:Connect(function() end)
		input:press(ce.globals.Enum.KeyCode.W)
		eq(uis:IsKeyDown(ce.globals.Enum.KeyCode.W), true)
		input:release(ce.globals.Enum.KeyCode.W)
		input:move(ce.globals.Vector2.new(30, 40))

		local sgui = ce.Instance.new("ScreenGui", ce.LocalPlayer.PlayerGui)
		sgui.ZIndexBehavior = ce.globals.Enum.ZIndexBehavior.Sibling
		local fLow, fHigh = ce.Instance.new("Frame", sgui), ce.Instance.new("Frame", sgui)
		fLow.ZIndex, fHigh.ZIndex = 1, 2
		local bDeep, bShal = ce.Instance.new("TextButton", fLow), ce.Instance.new("TextButton", fHigh)
		bDeep.ZIndex, bShal.ZIndex = 9, 1
		ce:setAbsolute(bDeep, ce.globals.Vector2.new(100, 100), ce.globals.Vector2.zero)
		ce:setAbsolute(bShal, ce.globals.Vector2.new(100, 100), ce.globals.Vector2.zero)
		local clicked = {}
		bDeep.Activated:Connect(function() table.insert(clicked, "Deep") end)
		bShal.Activated:Connect(function() table.insert(clicked, "Shallow") end)
		input:click(ce.globals.Vector2.new(50, 50))
		sgui.ZIndexBehavior = ce.globals.Enum.ZIndexBehavior.Global
		input:click(ce.globals.Vector2.new(50, 50))
		eq(clicked, { "Shallow", "Deep" })
		bDeep.Interactable = false
		fails(function() input:click(bDeep) end, "is not interactable")
		fHigh.Visible = false
		fails(function() input:click(bShal) end, "is not visible")

		local box = ce.Instance.new("TextBox", sgui)
		box.Text = "abc"
		fails(function() input:type("x") end, "no TextBox is focused")
		input:click(box)
		input:type("hi")
		input:click(box)
		eq(box.Text, "hi")
		input:press(ce.globals.Enum.KeyCode.Return)
		eq(uis:GetFocusedTextBox(), nil)

		-- Spatial queries, CharacterAutoLoads, waitFor, active, and outside host
		local wall = se.Instance.new("Part", se.workspace)
		wall.Size, wall.Position = g.Vector3.new(2, 10, 10), g.Vector3.new(10, 0, 0)
		local nearP = se.Instance.new("Part", se.workspace)
		nearP.Size, nearP.Position = g.Vector3.new(2, 2, 2), g.Vector3.new(5, 0, 0)
		eq(se.workspace:Raycast(g.Vector3.zero, g.Vector3.new(20, 0, 0)).Instance, nearP)
		local rParams = g.RaycastParams.new()
		rParams.FilterDescendantsInstances, rParams.FilterType = { nearP }, g.Enum.RaycastFilterType.Exclude
		eq(se.workspace:Raycast(g.Vector3.zero, g.Vector3.new(20, 0, 0), rParams).Instance, wall)
		rParams.FilterType = g.Enum.RaycastFilterType.Include
		eq(se.workspace:Raycast(g.Vector3.zero, g.Vector3.new(20, 0, 0), rParams).Instance, nearP)
		eq(se.workspace:GetPartBoundsInBox(g.CFrame.new(5, 0, 0), g.Vector3.new(1, 1, 1)), { nearP })
		local oParams = g.OverlapParams.new()
		oParams.MaxParts = 1
		eq(#se.workspace:GetPartBoundsInRadius(g.Vector3.new(7.5, 0, 0), 3, oParams), 1)
		nearP.Size = g.Vector3.new(12, 2, 2)
		eq(se.workspace:GetPartsInPart(nearP), { wall })

		se.Players.CharacterAutoLoads = false
		eq(se:addPlayer(2).Character, nil)
		se.Players.CharacterAutoLoads = true
		sert(se:addPlayer(3).Character ~= nil)

		local ready = false
		se.task.delay(0.5, function() ready = true end)
		eq(sert.waitFor(function() return ready end, 2), true)
		eq(sert.env.active(), se)

		local hNow, hDef, hDel, hCan = 5, {}, {}, {}
		local he = sert.env.new({
			isClient = true,
			host = {
				clock = function() return hNow end,
				defer = function(fn)
					table.insert(hDef, fn)
					return coroutine.running()
				end,
				delay = function(sec)
					table.insert(hDel, sec)
					return coroutine.running()
				end,
				cancel = function(th) table.insert(hCan, th) end,
			},
		})
		eq({ he.now, he.globals.os.clock() }, { 5, 5 })
		he.task.spawn(function() end)
		he.task.defer(print)
		he.task.delay(2, print)
		he.task.cancel(coroutine.create(function() end))
		he:step(0.25)
		eq({ he:advance(1), #hDef, #hDel, #hCan }, { 0, 1, 1, 1 })
		fails(function() sert.env.new({ host = {} :: any }) end, "host.clock must be a function")
		fails(
			function() sert.env.new({ world = sert.sim.World.new(), host = { clock = os.clock } }) end,
			"host is for standalone envs"
		)

		local cfLerp = he.globals.CFrame.Angles(0, 0, 0):Lerp(he.globals.CFrame.Angles(0, math.pi / 2, 0), 0.5)
		sert.near(cfLerp.RightVector:Dot(cfLerp.UpVector), 0, 1e-6)
		local cfPi = he.globals.CFrame.Angles(0, 0, 0):Lerp(he.globals.CFrame.Angles(0, math.pi, 0), 0.5)
		sert.near(cfPi.RightVector.Magnitude, 1, 1e-6)
		sert.near(cfPi.RightVector:Dot(he.globals.Vector3.xAxis), 0, 1e-6)
		local cfRollPi = he.globals.CFrame.Angles(0, 0, 0):Lerp(he.globals.CFrame.Angles(0, 0, math.pi), 0.5)
		sert.near(cfRollPi.RightVector:Dot(he.globals.Vector3.xAxis), 0, 1e-6)
		sert.near(cfRollPi.UpVector:Dot(he.globals.Vector3.yAxis), 0, 1e-6)
		local cfPitchPi = he.globals.CFrame.Angles(0, 0, 0):Lerp(he.globals.CFrame.Angles(math.pi, 0, 0), 0.5)
		sert.near(cfPitchPi.UpVector:Dot(he.globals.Vector3.yAxis), 0, 1e-6)
		local strictEnv = sert.env.new({ strict = true })
		eq(strictEnv.workspace:GetFullName(), "Workspace")
		local colonPart = strictEnv:createInstance("Part", strictEnv.workspace)
		eq(colonPart.Parent, strictEnv.workspace)
		local focusedBox = strictEnv.Instance.new("TextBox", strictEnv.workspace)
		focusedBox:CaptureFocus()
		focusedBox:Destroy()
		eq(strictEnv.game:GetService("UserInputService"):GetFocusedTextBox(), nil)
		local tcs = strictEnv.game:GetService("TextChatService")
		local chan = strictEnv.Instance.new("TextChannel", tcs)
		local delivered = 0
		chan.MessageReceived:Connect(function()
			delivered += 1
		end)
		chan.ShouldDeliverCallback = function() return false end
		chan:SendAsync("blocked")
		eq(delivered, 0)
		local prioQ = strictEnv.game:GetService("MemoryStoreService"):GetQueue("prio")
		prioQ:AddAsync("default", 60)
		prioQ:AddAsync("high", 60, 5)
		eq((prioQ:ReadAsync(2, false, 0)), { "high", "default" })

		local repW = sert.sim.World.new({ wait = "instant" })
		local repSrv = repW:server()
		local repCli = repSrv:client(1)
		local sEnv, cEnv = repSrv:env({ strict = true }), repCli:env({ strict = true })
		local objVal = sEnv.Instance.new("ObjectValue", sEnv.workspace)
		objVal.Name = "RefHolder"
		local targetPart = sEnv.Instance.new("Part")
		targetPart.Name = "DelayedTarget"
		local refChanges = 0
		local cObjVal = cEnv.workspace:FindFirstChild("RefHolder")
		cObjVal:GetPropertyChangedSignal("Value"):Connect(function()
			refChanges += 1
		end)
		objVal.Value = targetPart
		targetPart.Parent = sEnv.workspace
		eq({ cObjVal.Value ~= nil, refChanges }, { true, 1 })
		objVal.Parent = nil
		objVal.Value = nil
		objVal.Parent = sEnv.workspace
		eq({ cObjVal.Value, refChanges }, { nil, 2 })
		objVal.Parent = nil
		objVal.Value = targetPart
		objVal.Parent = sEnv.workspace
		eq({ cObjVal.Value ~= nil, refChanges }, { true, 3 })
		objVal:SetAttribute("TargetAttr", targetPart)
		eq(cObjVal:GetAttribute("TargetAttr") ~= nil, true)
		targetPart.Parent = sEnv.game:GetService("ServerStorage")
		eq({ cObjVal.Value, cObjVal:GetAttribute("TargetAttr") }, { nil, nil })
		local objVal2 = sEnv.Instance.new("ObjectValue", sEnv.workspace)
		objVal2.Name = "RefHolder2"
		objVal2.Value = targetPart
		eq(cEnv.workspace.RefHolder2.Value, nil)
		targetPart.Parent = sEnv.workspace
		eq({ cObjVal.Value ~= nil, cEnv.workspace.RefHolder2.Value ~= nil }, { true, true })

		-- TweenService: idle Cancel, resume conflict cancellation, and repeat DelayTime
		local twTarget = se.Instance.new("Part", se.workspace)
		twTarget.Transparency = 0
		local idleTw = tws:Create(twTarget, g.TweenInfo.new(1), { Transparency = 1 })
		local idleCompleted = 0
		idleTw.Completed:Connect(function()
			idleCompleted += 1
		end)
		idleTw:Cancel()
		eq({ idleTw.PlaybackState, idleCompleted }, { g.Enum.PlaybackState.Cancelled, 0 })
		local twA = tws:Create(twTarget, g.TweenInfo.new(1), { Transparency = 1 })
		local twB = tws:Create(twTarget, g.TweenInfo.new(1), { Transparency = 0.5 })
		twA:Play()
		twA:Pause()
		twB:Play()
		twA:Play()
		eq(twB.PlaybackState, g.Enum.PlaybackState.Cancelled)
		local repPart = se.Instance.new("Part", se.workspace)
		repPart.Transparency = 0
		local repTw =
			tws:Create(repPart, g.TweenInfo.new(0.5, Style.Linear, Dir.In, 1, false, 0.5), { Transparency = 1 })
		repTw:Play()
		se:advance(1.25)
		eq(repTw.PlaybackState, g.Enum.PlaybackState.Delayed)
		sert(repPart.Transparency > 0.9)
		local infZeroTw =
			tws:Create(repPart, g.TweenInfo.new(0, Style.Linear, Dir.In, -1, false, 0), { Transparency = 0 })
		infZeroTw:Play()
		se:step()
		eq(infZeroTw.PlaybackState, g.Enum.PlaybackState.Playing)
		infZeroTw:Cancel()
		local msProxy = se.game:GetService("MemoryStoreService")
		local conflictFn = function() return false end
		msProxy.conflict = conflictFn
		eq(msProxy.conflict, conflictFn)
		msProxy.conflict = nil

		-- HttpService: HttpEnabled and 4xx/5xx error throwing in GetAsync/PostAsync
		local sHttp = se.game:GetService("HttpService")
		se:onHttp(
			function() return { Success = false, StatusCode = 503, StatusMessage = "Service Unavailable", Body = "" } end
		)
		fails(function() sHttp:GetAsync("https://example.com") end, "HTTP 503")
		fails(function() sHttp:PostAsync("https://example.com", "{}") end, "HTTP 503")
		sHttp.HttpEnabled = false
		fails(function() sHttp:RequestAsync({ Url = "https://example.com" }) end, "Http requests are not enabled")

		-- env:shutdown disconnects external listeners
		local pageFrame = sEnv.Instance.new("Frame", sEnv.game.ReplicatedStorage)
		pageFrame.Name = "Pages"
		pageFrame.Size = sEnv.globals.UDim2.fromOffset(300, 120)
		local pageLayout = sEnv.Instance.new("UIPageLayout", pageFrame)
		local pageA = sEnv.Instance.new("Frame", pageFrame)
		pageA.Name = "PageA"
		pageLayout:JumpTo(pageA)
		local cPageFrame = cEnv.game.ReplicatedStorage.Pages
		cEnv:setAbsolute(cPageFrame, cEnv.globals.Vector2.new(999, 888))
		pageFrame.Size = sEnv.globals.UDim2.fromOffset(400, 150)
		eq(cPageFrame.AbsoluteSize, cEnv.globals.Vector2.new(999, 888))
		local cPageLayout = cPageFrame:FindFirstChildOfClass("UIPageLayout")
		eq(cPageLayout.CurrentPage, cEnv.game.ReplicatedStorage.Pages.PageA)
		local sSound = sEnv.Instance.new("Sound", sEnv.workspace)
		sSound.Name = "Horn"
		sSound:Play()
		eq(cEnv.workspace.Horn.Playing, true)
		sSound:Stop()
		eq(cEnv.workspace.Horn.Playing, false)
		local renderStepsRan = 0
		cEnv.game:GetService("RunService"):BindToRenderStep("TestRender", 100, function()
			renderStepsRan += 1
		end)
		repW:step(0.1)
		eq(renderStepsRan, 1)
		sEnv:shutdown()
		eq(#sEnv._ctx.serviceConnections, 0)

		-- TweenService Back/Elastic overshoot and Chat service textFilter
		local overPart = se.Instance.new("Part", se.workspace)
		overPart.Position = g.Vector3.new(0, 0, 0)
		local backTw =
			tws:Create(overPart, g.TweenInfo.new(1, Style.Back, Dir.Out), { Position = g.Vector3.new(10, 0, 0) })
		backTw:Play()
		se:step(0.6)
		sert(overPart.Position.X > 10)
		se:advance(1)
		eq(overPart.Position.X, 10)

		se:onTextFilter(function(txt, uid) return `[{uid}]:{txt}` end)
		local chatSvc = se.game:GetService("Chat")
		local pChat = se:addPlayer(77, "Chatter")
		eq(chatSvc:FilterStringAsync("hello", pChat), "[77]:hello")
		eq(chatSvc:FilterStringForBroadcast("world", 88), "[88]:world")
		eq({ chatSvc:CanUserChatAsync(77), chatSvc:CanUsersChatAsync(77, 88) }, { true, true })

		-- CFrame.fromAxisAngle zero-length axis, DateTime UTC/fractional, Model pivot/MoveTo, Humanoid.ChangeState,
		-- GetGuiObjectsAtPosition ancestor visibility, Options classes, Destroy/ClearAllChildren reparent guard,
		-- TweenService goal clone & re-entrancy, proxyService _doubleFields, and active() lifecycle
		eq(g.CFrame.fromAxisAngle(g.Vector3.zero, 1.5), g.CFrame.identity)
		local dtUtc = g.DateTime.fromUniversalTime(1970, 1, 1, 0, 0, 0, 250)
		eq(dtUtc.UnixTimestamp, 0)
		eq(dtUtc.UnixTimestampMillis, 250)
		local dtIsoMs = g.DateTime.fromIsoDate("1970-01-01T00:00:01.750Z")
		eq(dtIsoMs.UnixTimestamp, 1)
		eq(dtIsoMs.UnixTimestampMillis, 1750)

		local mdl = se.Instance.new("Model", se.workspace)
		local pp = se.Instance.new("Part", mdl)
		mdl.PrimaryPart = pp
		pp.CFrame = g.CFrame.new(5, 6, 7)
		eq(mdl:GetPivot().Position, g.Vector3.new(5, 6, 7))
		mdl:MoveTo(g.Vector3.new(10, 20, 30))
		eq(pp.Position, g.Vector3.new(10, 20, 30))

		local hum = se.Instance.new("Humanoid")
		local stateLog = {}
		local diedCount = 0
		hum.StateChanged:Connect(function(oldS, newS) table.insert(stateLog, { oldS, newS }) end)
		hum.Died:Connect(function()
			diedCount += 1
		end)
		hum:ChangeState(g.Enum.HumanoidStateType.Dead)
		eq(#stateLog, 1)
		eq(diedCount, 1)

		local pGui = pChat:FindFirstChildOfClass("PlayerGui")
		local sGui = se.Instance.new("ScreenGui", pGui)
		local hiddenParent = se.Instance.new("Frame", sGui)
		hiddenParent.Size = g.UDim2.fromOffset(100, 100)
		hiddenParent.Visible = false
		local childBtn = se.Instance.new("TextButton", hiddenParent)
		childBtn.Size = g.UDim2.fromOffset(50, 50)
		childBtn.Visible = true
		eq(#pGui:GetGuiObjectsAtPosition(10, 10), 0)
		hiddenParent.Visible = true
		sGui.Enabled = false
		eq(#pGui:GetGuiObjectsAtPosition(10, 10), 0)
		sGui.Enabled = true
		eq(#pGui:GetGuiObjectsAtPosition(10, 10), 2)

		local dsOpts = se.Instance.new("DataStoreSetOptions")
		dsOpts:SetMetadata({ tag = "v1" })
		eq(dsOpts:GetMetadata(), { tag = "v1" })
		local tpOpts = se.Instance.new("TeleportOptions")
		tpOpts:SetTeleportData({ room = 42 })
		eq(tpOpts:GetTeleportData(), { room = 42 })

		local parentFolder = se.Instance.new("Folder", se.workspace)
		local c1 = se.Instance.new("Part", parentFolder)
		local c2 = se.Instance.new("Part", parentFolder)
		local rescued = se.Instance.new("Folder", se.workspace)
		c1.Destroying:Connect(function() c2.Parent = rescued end)
		parentFolder:ClearAllChildren()
		eq(c2.Parent, rescued)

		local dsProxy = se.game:GetService("DataStoreService")
		sert(type(dsProxy.calls) == "table" and type(dsProxy.budgets) == "table")

		local twPart = se.Instance.new("Part", se.workspace)
		local goalsTbl = { Transparency = 0.8 }
		local reentTw = tws:Create(twPart, g.TweenInfo.new(0, Style.Linear, Dir.In), goalsTbl)
		goalsTbl.Transparency = 0.1
		local completedCount = 0
		twPart:GetPropertyChangedSignal("Transparency"):Connect(function() reentTw:Cancel() end)
		reentTw.Completed:Connect(function(st)
			if st == g.Enum.PlaybackState.Completed then
				completedCount += 1
			end
		end)
		reentTw:Play()
		eq(twPart.Transparency, 0.8)
		eq(completedCount, 0)

		local activeTestEnv = sert.env.new()
		eq(sert.env.active(), activeTestEnv)
		local simWorld = sert.sim.new()
		local peerSrvEnv = simWorld:server():env()
		eq(sert.env.active(), activeTestEnv)
		peerSrvEnv:shutdown()
		activeTestEnv:shutdown()
		eq(sert.env.active(), nil)

		-- env.datatypes.DateTime.now() advances with env:advance() and env.datatypes.Enum respects strict = true
		local dtEnv = sert.env.new({ strict = true })
		local t0 = dtEnv.datatypes.DateTime.now().UnixTimestampMillis
		dtEnv:advance(2.5)
		eq(dtEnv.datatypes.DateTime.now().UnixTimestampMillis - t0, 2500)
		fails(function() return dtEnv.datatypes.Enum.NotARealEnum end, "is not a valid member of Enum")

		-- Server-to-client replication of SetAttribute and CollectionService AddTag/RemoveTag
		local attrW = sert.sim.World.new({ wait = "instant" })
		local attrSrv = attrW:server()
		local attrCli = attrSrv:client(1)
		local saEnv, caEnv = attrSrv:env({ strict = true }), attrCli:env({ strict = true })
		local sPart = saEnv.Instance.new("Part", saEnv.workspace)
		sPart.Name = "TaggedAttrPart"
		local cPart = caEnv.workspace:FindFirstChild("TaggedAttrPart")
		local cCs = caEnv.game:GetService("CollectionService")
		local attrFires, tagFires = 0, 0
		cPart:GetAttributeChangedSignal("QuestId"):Connect(function()
			attrFires += 1
		end)
		cCs:GetInstanceAddedSignal("QuestTarget"):Connect(function(inst)
			if inst == cPart then
				tagFires += 1
			end
		end)
		sPart:SetAttribute("QuestId", 42)
		saEnv.game:GetService("CollectionService"):AddTag(sPart, "QuestTarget")
		eq({ cPart:GetAttribute("QuestId"), attrFires, cPart:HasTag("QuestTarget"), tagFires }, { 42, 1, true, 1 })
		saEnv.game:GetService("CollectionService"):RemoveTag(sPart, "QuestTarget")
		eq(cPart:HasTag("QuestTarget"), false)
		saEnv:shutdown()
		caEnv:shutdown()

		-- Multi-part Model:PivotTo and Model:MoveTo transforming all descendant BaseParts
		local multiMdl = se.Instance.new("Model", se.workspace)
		local mRoot = se.Instance.new("Part", multiMdl)
		local mChild = se.Instance.new("Part", multiMdl)
		mRoot.CFrame = g.CFrame.new(0, 0, 0)
		mChild.CFrame = g.CFrame.new(3, 4, 5)
		multiMdl.PrimaryPart = mRoot
		multiMdl:PivotTo(g.CFrame.new(10, 20, 30))
		eq({ mRoot.Position, mChild.Position }, { g.Vector3.new(10, 20, 30), g.Vector3.new(13, 24, 35) })
		multiMdl:MoveTo(g.Vector3.new(100, 200, 300))
		eq({ mRoot.Position, mChild.Position }, { g.Vector3.new(100, 200, 300), g.Vector3.new(103, 204, 305) })

		-- DataStoreOptions:SetExperimentalFeatures, detached tag clones, and repeating Tween:Pause() + Play() in cycle 2 delay
		local dsExpOpts = strictEnv.Instance.new("DataStoreOptions")
		eq(dsExpOpts.ExperimentalFeatures, nil)
		dsExpOpts:SetExperimentalFeatures({ v2 = true })
		eq(dsExpOpts.ExperimentalFeatures, { v2 = true })

		local tagProto = se.Instance.new("Part")
		tagProto:AddTag("DetachedCloneTag")
		local detachedClone = tagProto:Clone()
		eq({ detachedClone:HasTag("DetachedCloneTag"), #(se._tags["DetachedCloneTag"] or {}) }, { true, 0 })
		detachedClone.Parent = se.workspace
		eq(#se.game:GetService("CollectionService"):GetTagged("DetachedCloneTag"), 1)
		detachedClone:Destroy()

		local cycPart = se.Instance.new("Part", se.workspace)
		cycPart.Transparency = 0
		local cycTw =
			tws:Create(cycPart, g.TweenInfo.new(0.5, Style.Linear, Dir.In, 1, false, 0.5), { Transparency = 1 })
		cycTw:Play()
		se:advance(1.25)
		eq(cycTw.PlaybackState, g.Enum.PlaybackState.Delayed)
		cycTw:Pause()
		eq(cycTw.PlaybackState, g.Enum.PlaybackState.Paused)
		cycTw:Play()
		eq(cycTw.PlaybackState, g.Enum.PlaybackState.Delayed)

		-- Viewport configuration (options.viewport, env:setViewport) and ProximityPrompt / env:triggerPrompt
		local vpEnv = sert.env.new({ isClient = true, viewport = g.Vector2.new(390, 844) })
		eq(vpEnv.camera.ViewportSize, g.Vector2.new(390, 844))
		eq(vpEnv.playerGui.AbsoluteSize, g.Vector2.new(390, 844))
		local vpScreen = vpEnv.Instance.new("ScreenGui", vpEnv.playerGui)
		local vpFull = vpEnv.Instance.new("Frame", vpScreen)
		vpFull.Size = g.UDim2.fromScale(1, 1)
		eq(vpFull.AbsoluteSize, g.Vector2.new(390, 844))
		vpEnv:setViewport(g.Vector2.new(1280, 720))
		eq(vpEnv.camera.ViewportSize, g.Vector2.new(1280, 720))
		eq(vpScreen.AbsoluteSize, g.Vector2.new(1280, 720))
		eq(vpFull.AbsoluteSize, g.Vector2.new(1280, 720))

		local promptPart = vpEnv.Instance.new("Part", vpEnv.workspace)
		promptPart.Position = g.Vector3.new(0, 0, 5)
		local prompt = vpEnv.Instance.new("ProximityPrompt", promptPart)
		prompt.MaxActivationDistance = 10
		local plr = vpEnv.localPlayer
		plr:LoadCharacter()
		plr.Character.PrimaryPart.Position = g.Vector3.new(0, 0, 0)

		local triggeredCount, serviceCount, holdBeganCount, holdEndedCount = 0, 0, 0, 0
		prompt.Triggered:Connect(function(who)
			if who == plr then
				triggeredCount += 1
			end
		end)
		vpEnv.services.ProximityPromptService.PromptTriggered:Connect(function(pr, who)
			if pr == prompt and who == plr then
				serviceCount += 1
			end
		end)
		prompt.PromptButtonHoldBegan:Connect(function()
			holdBeganCount += 1
		end)
		prompt.PromptButtonHoldEnded:Connect(function()
			holdEndedCount += 1
		end)

		local ok1, reason1 = vpEnv:triggerPrompt(prompt)
		eq({ ok1, reason1, triggeredCount, serviceCount }, { true, nil, 1, 1 })

		prompt.Enabled = false
		local ok2, reason2 = vpEnv:triggerPrompt(prompt)
		eq({ ok2, reason2, triggeredCount }, { false, "disabled", 1 })
		prompt.Enabled = true

		plr.Character.PrimaryPart.Position = g.Vector3.new(0, 0, 25)
		local ok3, reason3 = vpEnv:triggerPrompt(prompt)
		eq({ ok3, reason3, triggeredCount }, { false, "out_of_range", 1 })
		plr.Character.PrimaryPart.Position = g.Vector3.new(0, 0, 0)

		prompt.HoldDuration = 1.5
		local ok4, reason4 = vpEnv:triggerPrompt(prompt, plr, 0.5)
		eq({ ok4, reason4, holdBeganCount, holdEndedCount, triggeredCount }, { false, "hold_too_short", 1, 1, 1 })
		local beforeHold = vpEnv.now
		local ok5, reason5 = vpEnv:triggerPrompt(prompt, plr)
		eq({ ok5, reason5, holdBeganCount, holdEndedCount, triggeredCount }, { true, nil, 2, 2, 2 })
		near(vpEnv.now - beforeHold, 1.5, 1e-3)

		-- Runtime-adaptive sert.env namespace, lazy services, installGlobals, and doubleTag wrapping
		eq(
			sert.doubles.Datatypes.Vector2.new(256, math.huge) == sert.doubles.Datatypes.Vector2.new(256, math.huge),
			true
		)
		if game == nil and (getfenv :: any) ~= nil then
			eq(typeof(Vector2.new(3, 4)), "Vector2")
			eq(typeof(UDim2.fromOffset(10, 20)), "UDim2")
			eq(typeof(Color3.fromRGB(255, 0, 128)), "Color3")
			eq(typeof(Enum.KeyCode.E), "EnumItem")
			eq(typeof(DateTime.fromUnixTimestamp(0)), "DateTime")
			eq(utf8.nfdnormalize("abc"), "abc")
		end
		local customTarget: any = {}
		eq(sert.doubles.Datatypes.installGlobals(customTarget), customTarget)
		eq(customTarget.typeof(customTarget.Vector2.new(1, 2)), "Vector2")
		eq(customTarget.type(customTarget.Vector2.new(1, 2)), "userdata")

		local wrappedEnv = sert.env.new({
			datatypes = {
				typeof = function(v: any): string return if type(v) == "number" then "num" else type(v) end,
				type = function(v: any): string return if type(v) == "number" then "num_t" else type(v) end,
			},
		})
		local wrappedFrame = wrappedEnv.Instance.new("Frame")
		eq(wrappedEnv.typeof(wrappedFrame), "Instance")
		eq(wrappedEnv.type(wrappedFrame), "userdata")
		eq(wrappedEnv.typeof(wrappedEnv.Vector2.new(1, 2)), "Vector2")
		eq(wrappedEnv.typeof(42), "num")
		eq(wrappedEnv.type(42), "num_t")
		eq(wrappedEnv:getService("GuiService"), wrappedEnv.services.GuiService)
		eq(wrappedEnv.getService("GuiService"), wrappedEnv.services.GuiService)
		local installBox: any = {}
		eq(wrappedEnv:install(installBox), installBox)
		eq(installBox.Instance, wrappedEnv.Instance)
		eq(installBox.Vector2, wrappedEnv.Vector2)

		sert.env.reset()
		sert.env.configure({ isClient = true, isStudio = true, strict = true })
		local cfgEnv = sert.env.current()
		eq(sert.env.current(), cfgEnv)
		eq(sert.env.Vector2, cfgEnv.Vector2)
		eq(sert.env.Instance, cfgEnv.Instance)
		eq(sert.env.getService("GuiService"), cfgEnv.services.GuiService)
		eq(sert.env:getService("GuiService"), cfgEnv.services.GuiService)
		local nsBox: any = {}
		eq(sert.env.install(nsBox), nsBox)
		eq(nsBox.game, cfgEnv.game)
		local nsBox2: any = {}
		eq(sert.env:install(nsBox2, { includeGame = false }), nsBox2)
		eq(nsBox2.game, nil)
		eq(nsBox2.Vector2, cfgEnv.Vector2)
		local nsBox3: any = {}
		eq(sert.env.install(cfgEnv, nsBox3), nsBox3)
		eq(nsBox3.Instance, cfgEnv.Instance)
		sert.env.configure(nil)
		sert.env.reset()
		local defaultCurrent = sert.env.current()
		sert(defaultCurrent ~= cfgEnv)
		sert.env.reset()
	end
)

return {}
