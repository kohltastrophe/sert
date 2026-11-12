--!strict
-- Headless tests for `sert.roblox` utilities: `Flicker` frame stability recorder/judge,
-- `fuzzRemote` adversarial boundary payload fuzzer, `sweep` LIFO DataModel cleanup, and `Runner` orchestration.

local registry = require("../src/core/registry")
local sert = require("../src")

local describe = sert.describe
local test = sert.test
local Flicker = sert.roblox.Flicker
local Layout = sert.roblox.Layout
local Runner = sert.roblox.Runner
local fuzzRemote = sert.roblox.fuzzRemote
local sweep = sert.roblox.sweep

local function runIsolated(register: () -> (), opts: sert.RunOptions?): sert.Results
	local sub = registry.newState()
	registry.isolateDepth += 1
	local ok, res = pcall(function(): sert.Results
		return registry.withState(sub, function(): sert.Results
			register()
			local merged: sert.RunOptions = if opts ~= nil then table.clone(opts) else {}
			if merged.quiet == nil and merged.silent == nil then merged.quiet = true end
			if merged.raise == nil then merged.raise = false end
			return sert.run(merged)
		end)
	end)
	registry.isolateDepth -= 1
	if not ok then error(res, 0) end
	return res
end

local function captureRunner<T>(fn: () -> T): (T, { string })
	local result: any = nil
	registry.isolateDepth += 1
	local ok, linesOrErr = pcall(function(): { string }
		return registry.output.capture(function() result = fn() end)
	end)
	registry.isolateDepth -= 1
	if not ok then error(linesOrErr, 0) end
	return result :: T, linesOrErr
end

local function makeSpecModule(envObj: any, parent: any, name: string, factory: (modEnv: any) -> any): ModuleScript
	local mod = envObj.Instance.new("ModuleScript")
	mod.Name = name
	rawset(mod, "_factory", factory)
	mod.Parent = parent
	return mod :: any
end

describe("sert.roblox.Flicker", function()
	test(
		"steady and expect pass on stable UI and detect jumped, blinked, jittered, never-visible, and never-settled",
		function()
			local e = sert.env.new({ isClient = true, isServer = false })
			local sg = e.Instance.new("ScreenGui")
			sg.Parent = e:getService("Players").LocalPlayer.PlayerGui

			-- 1) Stable frame settles cleanly with zero jump/blink/jitter.
			local steadyCard = e.Instance.new("Frame")
			steadyCard.Name = "SteadyCard"
			steadyCard.Position = e.UDim2.fromOffset(40, 50)
			steadyCard.Size = e.UDim2.fromOffset(200, 120)
			steadyCard.Parent = sg

			local okRes = Flicker.steady(steadyCard :: any, { maxFrames = 10, stableFrames = 3 })
			sert.eq(okRes.ok, true)
			sert.eq(okRes.problem, nil)

			-- 2) Single-frame mount jump (starts at X=0 on frame 0, snaps to X=120 on frame 1).
			local jumpCard = e.Instance.new("Frame")
			jumpCard.Name = "JumpCard"
			jumpCard.Position = e.UDim2.fromOffset(0, 50)
			jumpCard.Size = e.UDim2.fromOffset(160, 80)
			jumpCard.Parent = sg

			local jumpTick = 0
			local jumpRaw = Flicker.record(jumpCard :: any, {
				maxFrames = 8,
				stableFrames = 3,
				step = function()
					jumpTick += 1
					if jumpTick == 1 then jumpCard.Position = e.UDim2.fromOffset(120, 50) end
					e:step()
				end,
			})
			-- Flicker.judge returns a fresh Result without mutating jumpRaw in place!
			local rawOkBefore = jumpRaw.ok
			local judgedJump = Flicker.judge(jumpRaw, { tolerance = 0.5 })
			sert.eq(jumpRaw.ok, rawOkBefore)
			sert.ok(judgedJump ~= jumpRaw)
			sert.eq(judgedJump.ok, false)
			sert.eq(judgedJump.problem, "jumped")
			sert.matches(Flicker.describe(judgedJump, "JumpCard"), "jumped")
			sert.throws(function() Flicker.expect(jumpRaw, "JumpCard") end, "jumped")
			-- Re-judging with wide tolerance passes cleanly without mutating the original recording.
			local lenientJump = Flicker.judge(jumpRaw, { tolerance = 200 })
			sert.eq(lenientJump.ok, true)

			-- 3) Visibility blink (visible -> hidden -> visible).
			local blinkCard = e.Instance.new("Frame")
			blinkCard.Name = "BlinkCard"
			blinkCard.Size = e.UDim2.fromOffset(100, 60)
			blinkCard.Parent = sg

			local blinkTick = 0
			local blinkRaw = Flicker.record(blinkCard :: any, {
				maxFrames = 10,
				stableFrames = 3,
				step = function()
					blinkTick += 1
					blinkCard.Visible = (blinkTick ~= 2)
					e:step()
				end,
			})
			local judgedBlink = Flicker.judge(blinkRaw)
			sert.eq(judgedBlink.ok, false)
			sert.eq(judgedBlink.problem, "blinked")

			-- 4) Post-mount jitter (settles at X=40, spikes to X=90 mid-stream, returns to X=40).
			local jitterCard = e.Instance.new("Frame")
			jitterCard.Name = "JitterCard"
			jitterCard.Position = e.UDim2.fromOffset(40, 40)
			jitterCard.Size = e.UDim2.fromOffset(100, 60)
			jitterCard.Parent = sg

			local jitterTick = 0
			local jitterRaw = Flicker.record(jitterCard :: any, {
				maxFrames = 10,
				stableFrames = 4,
				step = function()
					jitterTick += 1
					jitterCard.Position = if jitterTick == 2
						then e.UDim2.fromOffset(90, 40)
						else e.UDim2.fromOffset(40, 40)
					e:step()
				end,
			})
			local judgedJitter = Flicker.judge(jitterRaw)
			sert.eq(judgedJitter.ok, false)
			sert.eq(judgedJitter.problem, "jittered")

			-- 5) Never-visible & never-settled detection + positionOnly / fromSettledSize options.
			local hiddenCard = e.Instance.new("Frame")
			hiddenCard.Visible = false
			hiddenCard.Size = e.UDim2.fromOffset(100, 50)
			hiddenCard.Parent = sg
			local hiddenRes = Flicker.judge(Flicker.record(hiddenCard :: any, { maxFrames = 4, stableFrames = 2 }))
			sert.eq(hiddenRes.ok, false)
			sert.eq(hiddenRes.problem, "never-visible")

			local movingCard = e.Instance.new("Frame")
			movingCard.Size = e.UDim2.fromOffset(80, 40)
			movingCard.Parent = sg
			local moveTick = 0
			local neverSettled = Flicker.record(movingCard :: any, {
				maxFrames = 6,
				stableFrames = 3,
				step = function()
					moveTick += 1
					movingCard.Position = e.UDim2.fromOffset(moveTick * 25, 0)
					e:step()
				end,
			})
			sert.eq(neverSettled.ok, false)
			sert.eq(neverSettled.problem, "never-settled")

			-- Size-only animation passes when `positionOnly = true` or `fromSettledSize = true`!
			local growCard = e.Instance.new("Frame")
			growCard.Position = e.UDim2.fromOffset(30, 30)
			growCard.Size = e.UDim2.fromOffset(40, 40)
			growCard.Parent = sg
			local growTick = 0
			local growRaw = Flicker.record(growCard :: any, {
				maxFrames = 8,
				stableFrames = 3,
				step = function()
					growTick += 1
					if growTick <= 2 then growCard.Size = e.UDim2.fromOffset(40 + growTick * 30, 40) end
					e:step()
				end,
			})
			sert.eq(Flicker.judge(growRaw).problem, "jumped")
			sert.eq(Flicker.judge(growRaw, { positionOnly = true }).ok, true)
			sert.eq(Flicker.judge(growRaw, { fromSettledSize = true }).ok, true)
			sert.eq(Layout.geometry.visible(growCard :: any), true)
		end
	)
end)

describe("sert.roblox.fuzzRemote", function()
	-- Top-level registered property test via fuzzRemote(name, spec)
	fuzzRemote("hardened shop handler survives adversarial payloads without corrupting state", {
		handler = function(player: any, action: any, qty: any)
			if type(action) ~= "string" or #action == 0 or #action > 32 then return false, "bad_action" end
			if type(qty) ~= "number" or qty ~= qty or qty % 1 ~= 0 or qty < 1 or qty > 99 then
				return false, "bad_qty"
			end
			player.coins = (player.coins or 1000) - qty
			return true, player.coins
		end,
		runs = 80,
		seed = 404,
		makePlayer = function()
			return {
				ClassName = "Player",
				UserId = 77,
				Name = "Buyer",
				coins = 1000,
			}
		end,
		checkState = function(player: any)
			-- Balance must remain a finite integer <= 1000 and never become NaN or negative infinity!
			sert.eq(player.coins == player.coins, true)
			sert.lt(player.coins, math.huge)
			sert.le(player.coins, 1000)
		end,
	})

	test("catches vulnerable remote handlers on NaN, spoofed Instances, and unexpected yields", function()
		-- 1) Vulnerable handler with classic NaN / ±huge bypass (`if amount < 0 then return end` lets NaN and +huge poison balance!).
		local balances: { [number]: number } = { [1001] = 500 }
		sert.throws(function()
			fuzzRemote({
				handler = function(plr: any, payload: any)
					local amount = if type(payload) == "table" then payload.amount else payload
					if type(amount) == "number" then
						if amount < 0 then return end
						balances[plr.UserId] = (balances[plr.UserId] or 500) - amount
					end
				end,
				runs = 250,
				maxArgs = 1,
				seed = 12,
				checkState = function(plr: any)
					local bal = balances[plr.UserId] or 500
					sert.eq(bal == bal and bal > -math.huge and bal <= 500, true, "balance poisoned by NaN/huge")
				end,
			})
		end)

		-- 2) Vulnerable handler fooled by a plain table spoofing `{ ClassName = "Part", IsA = ... }` instead of checking `typeof(x) == "Instance"`.
		local e = sert.env.new()
		sert.throws(function()
			fuzzRemote({
				handler = function(_plr: any, target: any)
					if type(target) == "table" and target.ClassName == "Part" and e.typeof(target) ~= "Instance" then
						error("accepted spoofed non-Instance table!")
					end
				end,
				runs = 120,
				seed = 19,
				allowError = false,
			})
		end)

		-- 3) Yielding inside a RemoteEvent handler when allowYield defaults to false fails cleanly.
		sert.throws(function()
			fuzzRemote({
				handler = function() coroutine.yield() end,
				runs = 5,
				seed = 3,
				allowYield = false,
			})
		end, "yield")
	end)

	test("mutates validGen table payloads for near-miss fuzzing and supports 3-arg top-level registration", function()
		local validHits = 0
		local corruptedTableHits = 0
		fuzzRemote(
			function(_plr: any, payload: any)
				if type(payload) == "table" and rawget(payload, "_isInstance") ~= true then
					local okAction = payload.action == "buy"
					local okQty = type(payload.qty) == "number"
						and payload.qty == payload.qty
						and payload.qty >= 1
						and payload.qty <= 5
					if okAction and okQty then
						validHits += 1
					elseif okAction or okQty then
						corruptedTableHits += 1
					end
				end
			end,
			{
				validGen = sert.gen.record({
					action = sert.gen.constant("buy"),
					qty = sert.gen.int(1, 5),
				}),
				runs = 120,
				seed = 42,
			} :: any
		)
		sert.gt(validHits, 0)
		sert.gt(corruptedTableHits, 0)

		-- Empty validGen table exercises the `#keys == 0` adversarial slot-1 mutation path!
		local sawSlotOneMutation = false
		fuzzRemote(
			function(_plr: any, payload: any)
				if
					type(payload) == "table"
					and rawget(payload, "_isInstance") ~= true
					and rawget(payload, 1) ~= nil
				then
					sawSlotOneMutation = true
				end
			end,
			{
				validGen = sert.gen.constant({}),
				runs = 60,
				seed = 9,
			} :: any
		)
		sert.eq(sawSlotOneMutation, true)

		-- Throwing on a valid payload fails even when `allowError = true`!
		sert.throws(function()
			fuzzRemote(
				function(_plr: any, payload: any)
					if
						type(payload) == "table"
						and rawget(payload, "_isInstance") ~= true
						and payload.action == "buy"
						and type(payload.qty) == "number"
					then
						error("rejected valid buy")
					end
				end,
				{
					validGen = sert.gen.record({
						action = sert.gen.constant("buy"),
						qty = sert.gen.int(1, 5),
					}),
					runs = 40,
					seed = 42,
					allowError = true,
				} :: any
			)
		end, "valid payload")

		sert.throws(function() fuzzRemote("missing_handler", 123 :: any) end, "expected handler")
		sert.throws(function() fuzzRemote(123 :: any) end, "expected")

		-- Top-level 3-arg `fuzzRemote(name, handler, opts)` registration across targets inside an isolated runner pass.
		local registeredCalls = 0
		local isoRes = runIsolated(function()
			local handler = function(_plr: any, payload: any)
				registeredCalls += 1
				if type(payload) == "table" and rawget(payload, "_isInstance") ~= true and payload.action == "buy" then
					if type(payload.qty) ~= "number" or payload.qty ~= payload.qty then return false end
				end
				return true
			end
			local opts: sert.RemoteFuzzSpec = {
				handler = handler,
				validGen = sert.gen.record({
					action = sert.gen.constant("buy"),
					qty = sert.gen.int(1, 5),
				}),
				runs = 20,
				seed = 77,
			}
			fuzzRemote("portable 3-arg fuzz", handler, opts)
			local srvOpts = table.clone(opts)
			srvOpts.target = "server"
			fuzzRemote("server 3-arg fuzz", handler, srvOpts)
			local cliOpts = table.clone(opts)
			cliOpts.target = "client"
			fuzzRemote("client 3-arg fuzz", handler, cliOpts)
			local rbxOpts = table.clone(opts)
			rbxOpts.target = "roblox"
			fuzzRemote("roblox 3-arg fuzz", handler, rbxOpts)
		end, { allTargets = true })
		sert.eq(isoRes.passed, 4)
		sert.eq(isoRes.failed, 0)
		sert.ge(registeredCalls, 80)
	end)
end)

describe("sert.roblox.sweep", function()
	test(
		"snapshots DataModel containers, destroys new instances in LIFO order, preserves exclusions & static containers, and cleans up on throw",
		function()
			local e = sert.env.new({ isClient = true, isServer = false })
			local rs = e:getService("ReplicatedStorage")

			-- Pre-existing fixtures + static `Packages` container in ReplicatedStorage must survive sweep!
			local existingPart = e.Instance.new("Part")
			existingPart.Name = "Baseplate"
			existingPart.Parent = e.workspace

			local packagesFolder = e.Instance.new("Folder")
			packagesFolder.Name = "Packages"
			packagesFolder.Parent = rs

			local keptMarker = e.Instance.new("Folder")
			keptMarker.Name = "ExcludedRoot"
			keptMarker.Parent = e.workspace

			local snap = sweep.snapshot({ exclude = { keptMarker :: any } })

			local destroyOrder: { string } = {}
			local first = e.Instance.new("Part")
			first.Name = "FirstSpawned"
			first.Destroying:Connect(function() table.insert(destroyOrder, "FirstSpawned") end)
			first.Parent = e.workspace

			local second = e.Instance.new("Part")
			second.Name = "SecondSpawned"
			second.Destroying:Connect(function() table.insert(destroyOrder, "SecondSpawned") end)
			second.Parent = e.workspace

			local keptChild = e.Instance.new("Part")
			keptChild.Name = "InsideExcluded"
			keptChild.Parent = keptMarker

			local guiLeak = e.Instance.new("ScreenGui")
			guiLeak.Name = "LeakedHud"
			guiLeak.Parent = e:getService("Players").LocalPlayer.PlayerGui

			local destroyedCount = sweep.restore(snap)
			e:flush()

			sert.ge(destroyedCount, 3)
			-- LIFO destruction: SecondSpawned is destroyed before FirstSpawned!
			sert.eq(destroyOrder, { "SecondSpawned", "FirstSpawned" })
			sert.eq(e.workspace:FindFirstChild("Baseplate"), existingPart)
			sert.eq(rs:FindFirstChild("Packages"), packagesFolder)
			sert.eq(keptMarker:FindFirstChild("InsideExcluded"), keptChild)
			sert.eq(e:getService("Players").LocalPlayer.PlayerGui:FindFirstChild("LeakedHud"), nil)
			sert.ok(e.workspace.CurrentCamera ~= nil)

			-- sweep.around restores leaked instances even when the callback throws!
			sert.throws(function()
				sweep.around(function()
					local temp = e.Instance.new("Part")
					temp.Name = "ThrowLeak"
					temp.Parent = e.workspace
					error("boom inside around")
				end)
			end, "boom inside around")
			sert.eq(e.workspace:FindFirstChild("ThrowLeak"), nil)
		end
	)

	test(
		"handles nil gameRoot, explicit gameRoot across Lighting/SoundService/ReplicatedStorage, and straggler sweeps",
		function()
			local prevEnv = registry.activeEnv()
			registry.setActiveEnv(nil)
			local emptySnap = sweep.snapshot()
			sert.eq(#emptySnap.roots, 0)
			sert.eq(sweep.restore(emptySnap), 0)

			local e = sert.env.new({ isClient = true, isServer = true })
			-- Explicitly clear activeEnv so `gameRoot = e.game` is resolved via `opts.gameRoot` rather than `activeEnv`!
			registry.setActiveEnv(nil)

			local lighting = e:getService("Lighting")
			local soundSvc = e:getService("SoundService")
			local rs = e:getService("ReplicatedStorage")
			for _, staticName in { "sert", "Tests", "Specs", "sert.Request", "sert.Result" } do
				local f = e.Instance.new("Folder")
				f.Name = staticName
				f.Parent = rs
			end

			local excludedSound = e.Instance.new("Sound")
			excludedSound.Name = "AmbientLoop"
			excludedSound.Parent = soundSvc

			sweep.around(function()
				local bloom = e.Instance.new("Folder")
				bloom.Name = "TempAtmosphere"
				bloom.Parent = lighting

				local sfx = e.Instance.new("Sound")
				sfx.Name = "OneShotClick"
				sfx.Parent = soundSvc

				local transientRemote = e.Instance.new("RemoteEvent")
				transientRemote.Name = "TempRemote"
				transientRemote.Parent = rs
			end, {
				gameRoot = e.game,
				exclude = { excludedSound :: any },
			})

			sert.eq(lighting:FindFirstChild("TempAtmosphere"), nil)
			sert.eq(soundSvc:FindFirstChild("OneShotClick"), nil)
			sert.eq(soundSvc:FindFirstChild("AmbientLoop"), excludedSound)
			sert.eq(rs:FindFirstChild("TempRemote"), nil)
			sert.ok(rs:FindFirstChild("sert") ~= nil)
			sert.ok(rs:FindFirstChild("sert.Request") ~= nil)

			-- Mock container without `DescendantAdded` exercises `collectStragglers` LIFO sweep while keeping pre-existing & excluded nodes!
			local stragglerDestroyed: { string } = {}
			local mockWsChildren: { any } = {}
			local function makeMockNode(name: string, parent: any): any
				local nodeChildren: { any } = {}
				local node: any = {
					Name = name,
					Parent = parent,
					GetChildren = function() return nodeChildren end,
				}
				node.Destroy = function(self: any)
					table.insert(stragglerDestroyed, self.Name)
					self.Parent = nil
				end
				if parent ~= nil then table.insert(parent._list, node) end
				node._list = nodeChildren
				return node
			end

			local mockWs: any = {
				Name = "Workspace",
				_list = mockWsChildren,
				GetChildren = function() return mockWsChildren end,
			}
			local keptGroup = makeMockNode("KeptGroup", mockWs)
			local excludedGroup = makeMockNode("ExcludedGroup", mockWs)
			local mockGame = {
				GetService = function(_self: any, svc: string): any
					if svc == "Workspace" then return mockWs end
					return nil
				end,
			}

			local stragglerSnap = sweep.snapshot({ gameRoot = mockGame, exclude = { excludedGroup } })
			makeMockNode("NestedLeakA", keptGroup)
			makeMockNode("NestedLeakB", keptGroup)
			makeMockNode("KeptUnderExcluded", excludedGroup)

			local count = sweep.restore(stragglerSnap)
			sert.eq(count, 2)
			sert.eq(stragglerDestroyed, { "NestedLeakB", "NestedLeakA" })

			registry.setActiveEnv(prevEnv)
		end
	)
end)

describe("sert.roblox.Runner: markers, args, edit & cloud", function()
	test(
		"emits diagnostic markers and reads Runner.args from attributes, delayed tasks, and StudioTestService",
		function()
			local prevEnv = registry.activeEnv()
			registry.setActiveEnv(nil)

			-- 1) Runner.marker and Runner.phase emit structured `[sert-x:<tag>]` and `[sert-phase]` lines.
			local markerLines = registry.output.capture(function()
				Runner.marker("net", "ready=true")
				Runner.phase("server", "init")
			end)
			sert.eq(#markerLines, 2)
			sert.eq(markerLines[1], "[sert-x:net] ready=true")
			sert.matches(markerLines[2], "^%[sert%-phase%] server init %d+$")

			-- 2) Runner.args returns nil when no DataModel is active in headless Luau.
			sert.eq(Runner.args(0), nil)

			-- 3) Valid JSON in `workspace:GetAttribute("sert_Args")` decodes immediately.
			local e: any = sert.env.new()
			e.clock = function(self: any): number return self.now end
			e.workspace:SetAttribute("sert_Args", '{"filter":"combat","runs":25,"ci":true}')
			local parsed = Runner.args(0.1, { env = e })
			sert.ok(parsed ~= nil)
			sert.eq((parsed :: any).filter, "combat")
			sert.eq((parsed :: any).runs, 25)
			sert.eq((parsed :: any).ci, true)

			-- 4) Invalid JSON + unset StudioTestService times out cleanly via `env.task.wait(0.05)`.
			e.workspace:SetAttribute("sert_Args", "{invalid-json")
			local timedOut = Runner.args(0.08, { env = e })
			sert.eq(timedOut, nil)

			-- 5) Delayed `sert_Args` attribute set while `Runner.args` is polling resolves before timeout!
			e.workspace:SetAttribute("sert_Args", "")
			e.task.delay(0.04, function() e.workspace:SetAttribute("sert_Args", '{"file":"Inventory","seed":123}') end)
			local delayed = Runner.args(0.2, { env = e })
			sert.ok(delayed ~= nil)
			sert.eq((delayed :: any).file, "Inventory")
			sert.eq((delayed :: any).seed, 123)

			-- 6) `StudioTestService:GetTestArgs()` + fallback `format.jsonDecode` when `HttpService` is absent on a mock dm.
			local mockWs = {
				GetAttribute = function(_self: any, key: string): any
					if key == "sert_Args" then return "{not-valid" end
					return nil
				end,
			}
			local mockSts = {
				GetTestArgs = function(_self: any): any return { filter = "from_studio_service", quiet = true } end,
			}
			local mockDm = {
				GetService = function(_self: any, name: string): any
					if name == "Workspace" then return mockWs end
					if name == "StudioTestService" then return mockSts end
					return nil
				end,
			}
			local stsArgs = Runner.args(0, { env = e, game = mockDm })
			sert.ok(stsArgs ~= nil)
			sert.eq((stsArgs :: any).filter, "from_studio_service")
			sert.eq((stsArgs :: any).quiet, true)

			registry.setActiveEnv(prevEnv)
		end
	)

	test(
		"Runner.edit and Runner.cloud discover specs, filter subpaths, list, repeat, resolve sert, and run side hooks",
		function()
			local e = sert.env.new()
			local rs = e:getService("ReplicatedStorage")
			local sss = e:getService("ServerScriptService")
			local ss = e:getService("ServerStorage")

			-- Ignored containers (`Packages`, `sert`) and non-spec helper ModuleScripts must not be auto-executed!
			local pkgFolder = e.Instance.new("Folder")
			pkgFolder.Name = "Packages"
			pkgFolder.Parent = rs
			makeSpecModule(
				e,
				pkgFolder,
				"IgnoredPkg.spec",
				function(_m: any) error("Packages spec should never be loaded!") end
			)
			makeSpecModule(
				e,
				rs,
				"PlainHelper",
				function(_m: any) error("Non-spec helper should never be auto-required!") end
			)

			-- Place specs under `ReplicatedStorage/Tests/specs/...`, `ServerScriptService`, and `ServerStorage` with `.spec`, `_spec`, `.test`.
			local testsRoot = e.Instance.new("Folder")
			testsRoot.Name = "Tests"
			testsRoot.Parent = rs
			local specsFolder = e.Instance.new("Folder")
			specsFolder.Name = "specs"
			specsFolder.Parent = testsRoot
			local serverSub = e.Instance.new("Folder")
			serverSub.Name = "server"
			serverSub.Parent = specsFolder

			local invRuns = 0
			makeSpecModule(e, serverSub, "Inventory.spec", function(_m: any)
				return function(ctx: any)
					ctx.sert.test("Portable inventory math", function()
						invRuns += 1
						ctx.sert.eq(ctx.isEdit or ctx.isServer, true)
					end)
					ctx.sert.test.skip("Skipped inventory placeholder")
				end
			end)

			makeSpecModule(e, sss, "Combat_spec", function(_m: any)
				return function(ctx: any)
					ctx.sert.test.server("Server combat hit", function()
						local debris = e.Instance.new("Part")
						debris.Name = "CombatDebris"
						debris.Parent = e.workspace
						ctx.sert.defer(function() debris:Destroy() end)
						ctx.sert.ok(debris.Parent == e.workspace)
					end)
				end
			end)

			makeSpecModule(e, ss, "Matchmaking.test", function(_m: any)
				return function(ctx: any)
					ctx.sert.test.roblox("Roblox queue check", function() ctx.sert.eq(1 + 1, 2) end)
				end
			end)

			local excludedFixture = e.Instance.new("Part")
			excludedFixture.Name = "PermanentArena"
			excludedFixture.Parent = e.workspace

			-- 1) `config.sert` as a function + `Runner.edit` subpath `files` filter + `repeat` option via `sert_Args` JSON.
			e.workspace:SetAttribute(
				"sert_Args",
				'{"files":["server/Inventory","Combat_spec"],"repeat":2,"seed":707,"slowest":2,"compact":true}'
			)
			local editVerdict, editLines = captureRunner(function()
				return Runner.edit({
					name = "edit-suite",
					env = e,
					sert = function() return sert end,
					excludeSweep = { excludedFixture :: any },
					command = "sert studio",
				})
			end)

			sert.eq(editVerdict.passed, true)
			sert.eq(editVerdict.mode, "edit")
			sert.eq(editVerdict.name, "edit-suite")
			sert.eq(editVerdict.counts.passed, 4) -- 2 tests * repeat 2
			sert.eq(editVerdict.counts.skipped, 1)
			sert.eq(invRuns, 2)
			sert.eq(e.workspace:FindFirstChild("CombatDebris"), nil)
			sert.eq(e.workspace:FindFirstChild("PermanentArena"), excludedFixture)
			sert.ok(string.find(table.concat(editLines, "\n"), "%[sert%-result%]") ~= nil)

			-- 2) `config.sert` as a ModuleScript + `request.list = true` + `Runner.edit` CLI args array `{ "--filter", ... }` + `{}`.
			local sertModScript = e.Instance.new("ModuleScript")
			sertModScript.Name = "sert"
			rawset(sertModScript, "_factory", function(_m: any) return sert end)
			sertModScript.Parent = rs

			e.workspace:SetAttribute("sert_Args", '{"list":true,"file":"Matchmaking.test"}')
			local listVerdict = captureRunner(
				function()
					return Runner.edit({
						env = e,
						sert = sertModScript :: any,
					})
				end
			)
			sert.eq(listVerdict.passed, true)
			sert.eq(listVerdict.listed, true)
			sert.eq(listVerdict.counts.total, 1)
			sert.eq(listVerdict.reason, "listed 1")

			local cliArgsVerdict = captureRunner(
				function() return Runner.edit({ env = e }, { "--filter", "Roblox queue check" }) end
			)
			sert.eq(cliArgsVerdict.passed, true)
			sert.eq(cliArgsVerdict.counts.passed, 1)

			local emptyArgsVerdict = captureRunner(function() return Runner.edit({ env = e }, {}) end)
			sert.eq(emptyArgsVerdict.passed, true)
			sert.eq(emptyArgsVerdict.counts.passed, 3)

			-- 3) Unmatched filter returns `passed = false` with `"no test ran: nothing matched the selection"`.
			e.workspace:SetAttribute("sert_Args", '{"filter":"nonexistent_xyz_spec_999"}')
			local noneVerdict = captureRunner(function() return Runner.edit({ env = e }) end)
			e.workspace:SetAttribute("sert_Args", "")
			sert.eq(noneVerdict.passed, false)
			sert.eq(noneVerdict.failed, 0)
			sert.matches(noneVerdict.reason or "", "no test ran")

			-- 4) `Runner.cloud` runs server/roblox targets with `clients = 0` and `mode = "cloud"`, using `Runner.setDefaultSert`.
			sertModScript:Destroy()
			Runner.setDefaultSert(sert)
			local cloudVerdict = captureRunner(
				function()
					return Runner.cloud({ env = e }, {
						allTargets = true,
						filters = { "Combat", "Queue", "Portable" },
						excludes = { "never_match" },
						grep = ".*",
						ci = true,
						allowFocused = false,
						runs = 10,
						exhaustive = false,
						budget = 50,
						timeout = 5,
						failFast = false,
						quiet = true,
					})
				end
			)
			Runner.setDefaultSert(nil)
			sert.eq(cloudVerdict.passed, true)
			sert.eq(cloudVerdict.mode, "cloud")
			sert.eq(cloudVerdict.counts.passed, 3)

			-- 5) `sides.edit` lifecycle (`context`, `setup`, `teardown`, `beforeEach`, `afterEach`, `specs` function, multi-pass `order`)
			-- plus error reporting on broken `ModuleScript` require, exported fn throw, setup/teardown throws, and test failures!
			local customRootA = e.Instance.new("Folder")
			customRootA.Name = "RootA"
			local customRootB = e.Instance.new("Folder")
			customRootB.Name = "RootB"

			local hookEvents: { string } = {}
			makeSpecModule(e, customRootA, "Hooked.spec", function(_m: any)
				return function(ctx: any)
					ctx.sert.test("uses side context", function()
						table.insert(hookEvents, `test:{ctx.tag}`)
						ctx.sert.eq(ctx.tag, "injected")
					end)
				end
			end)
			makeSpecModule(e, customRootB, "Second.spec", function(_m: any)
				return function(ctx: any)
					ctx.sert.test("second root pass", function() ctx.sert.ok(true) end)
				end
			end)

			local multiPassVerdict = captureRunner(function()
				return Runner.edit({
					env = e,
					sert = function() return sert end,
					allTargets = true,
					order = { "edit", "edit" },
					sides = {
						edit = {
							specs = function() return { customRootA :: any, customRootB :: any } end,
							timeout = 5,
							context = function(_base) return { tag = "injected" } end,
							setup = function(_ctx)
								table.insert(hookEvents, "setup")
								return function() table.insert(hookEvents, "teardown") end
							end,
							beforeEach = function(_ctx) table.insert(hookEvents, "beforeEach") end,
							afterEach = function(_ctx) table.insert(hookEvents, "afterEach") end,
						},
					},
				}, { repeatCount = 1 })
			end)
			sert.eq(multiPassVerdict.passed, true)
			sert.eq(multiPassVerdict.counts.passed, 4) -- 2 specs * 2 passes in `order`
			sert.eq(multiPassVerdict.sides.edit.passed, 4)
			sert.ok(table.find(hookEvents, "setup") ~= nil)
			sert.ok(table.find(hookEvents, "beforeEach") ~= nil)
			sert.ok(table.find(hookEvents, "test:injected") ~= nil)
			sert.ok(table.find(hookEvents, "afterEach") ~= nil)
			sert.ok(table.find(hookEvents, "teardown") ~= nil)

			-- Broken require, exported-fn throw, test assertion failure, setup throw, and teardown throw populate loadErrors & failures.
			local errFolder = e.Instance.new("Folder")
			errFolder.Name = "BrokenSpecs"
			makeSpecModule(e, errFolder, "SyntaxBoom.spec", function(_m: any) error("require exploded") end)
			makeSpecModule(e, errFolder, "ExportBoom.spec", function(_m: any)
				return function(_ctx: any) error("exported callback exploded") end
			end)
			makeSpecModule(e, errFolder, "FailingTest.spec", function(_m: any)
				return function(ctx: any)
					ctx.sert.test("deliberate failure", function() ctx.sert.eq(1, 2) end)
				end
			end)

			local brokenVerdict = captureRunner(function()
				return Runner.edit({
					env = e,
					sert = function() return sert end,
					allTargets = true,
					order = { "broken", "badSetup" },
					sides = {
						broken = {
							specs = errFolder :: any,
							setup = function(_ctx): (() -> ())?
								local td: () -> () = function() error("teardown exploded") end
								return td
							end,
						},
						badSetup = {
							specs = errFolder :: any,
							setup = function(_ctx): (() -> ())? error("setup exploded") end,
						},
					},
				})
			end)
			sert.eq(brokenVerdict.passed, false)
			sert.ge(brokenVerdict.failed, 5)
			sert.ge(#brokenVerdict.loadErrors, 4)
			sert.ge(#brokenVerdict.failures, 5)
		end
	)
end)

describe("sert.roblox.Runner: runOnce, server & client", function()
	test(
		"Runner.runOnce handles server-only (0 clients), 1-client live handoff, 2-client player labels, and client timeout",
		function()
			-- 1) `expectedClients = 0` via `clients = 0`, `sides` without `client`, and `RunService:IsRunMode() == true`.
			local e0: any = sert.env.new()
			e0.clock = function(self: any): number return self.now end
			local sss0 = e0:getService("ServerScriptService")
			makeSpecModule(e0, sss0, "ServerOnly.spec", function(_m: any)
				return function(ctx: any)
					ctx.sert.test.server("server authority check", function() ctx.sert.eq(ctx.isServer, true) end)
				end
			end)

			local vZero = captureRunner(function()
				return Runner.runOnce({ env = e0, sert = function() return sert end }, { clients = 0 })
			end)
			sert.eq(vZero.passed, true)
			sert.eq(vZero.sides.server.passed, 1)
			sert.eq(vZero.sides.client, nil)

			-- `RunService:IsRunMode() == true` + mock DataModel without `HttpService` (exercises fallback json/guid).
			local rs0 = e0:getService("ReplicatedStorage")
			local runModeDm = {
				GetService = function(_self: any, name: string): any
					if name == "RunService" then
						return { IsRunMode = function() return true end }
					elseif name == "ReplicatedStorage" then
						return rs0
					elseif name == "ServerScriptService" then
						return sss0
					end
					return nil
				end,
			}
			local vRunMode = captureRunner(function()
				return Runner.runOnce({ env = e0, game = runModeDm, sert = function() return sert end })
			end)
			sert.eq(vRunMode.passed, true)
			sert.eq(vRunMode.sides.server.passed, 1)
			sert.eq(vRunMode.sides.client, nil)
			sert.matches(vRunMode.runId, "^00000000%-0000%-4000%-8000%-")

			-- 2) `expectedClients = 1` paired with live `Runner.client` discovering PlayerScripts & StarterPlayer specs.
			local e1: any = sert.env.new({ isClient = true, isServer = true })
			e1.clock = function(self: any): number return self.now end
			local rs1 = e1:getService("ReplicatedStorage")
			local sss1 = e1:getService("ServerScriptService")
			local sp1 = e1:getService("StarterPlayer")
			local lp1 = e1:getService("Players").LocalPlayer
			local ps1 = lp1:FindFirstChildOfClass("PlayerScripts")
			if ps1 == nil then ps1 = e1:mount({ className = "PlayerScripts", name = "PlayerScripts" }, lp1) end

			makeSpecModule(e1, sss1, "SrvNet.spec", function(_m: any)
				return function(ctx: any)
					ctx.sert.test.server("server side pass", function() ctx.sert.eq(ctx.side, "server") end)
				end
			end)
			makeSpecModule(e1, ps1, "HudClient.spec", function(_m: any)
				return function(ctx: any)
					ctx.sert.test.client("playerScripts client spec", function()
						Runner.marker("hud", "mounted")
						ctx.sert.eq(ctx.isClient, true)
					end)
				end
			end)
			makeSpecModule(e1, sp1, "BootClient.spec", function(_m: any)
				return function(ctx: any)
					ctx.sert.test.client("starterPlayer client spec", function() ctx.sert.ok(true) end)
				end
			end)

			-- Pre-create custom comms objects so `Runner.client` attaches immediately without waiting.
			local customReq = e1.Instance.new("StringValue")
			customReq.Name = "sert.CustomReq"
			customReq.Parent = rs1
			local customRes = e1.Instance.new("RemoteEvent")
			customRes.Name = "sert.CustomRes"
			customRes.Parent = rs1

			local clientCfg: sert.RobloxConfig = {
				env = e1,
				sert = function() return sert end,
				requestName = "sert.CustomReq",
				resultName = "sert.CustomRes",
				clients = 1,
			}
			local cliHandle = Runner.client(clientCfg)

			local vOne, oneLines = captureRunner(function() return Runner.runOnce(clientCfg, { clients = 1 }) end)
			sert.eq(vOne.passed, true)
			sert.eq(vOne.sides.server.passed, 1)
			sert.eq(vOne.sides.client.passed, 2)
			local joinedOne = table.concat(oneLines, "\n")
			sert.matches(joinedOne, '"side":"client"')
			sert.matches(joinedOne, "%[sert%-x:hud%] mounted")

			-- Server-only request (`side = "server"`) is ignored by `Runner.client` and `expectedClientCount` is 0.
			local vSrvOnly = captureRunner(function() return Runner.runOnce(clientCfg, { side = "server" }) end)
			sert.eq(vSrvOnly.passed, true)
			sert.eq(vSrvOnly.sides.client, nil)
			cliHandle.stop()

			-- 3) `expectedClients = 2`: simulated 2-player listeners verify `client:Player1` / `client:Player2` labels,
			-- wrong-runId ignore, duplicate-player deduplication, `[sert-test]` rewriting, and `list = true` suppression!
			local e2: any = sert.env.new()
			e2.clock = function(self: any): number return self.now end
			local rs2 = e2:getService("ReplicatedStorage")
			local sss2 = e2:getService("ServerScriptService")
			makeSpecModule(e2, sss2, "MatchSrv.spec", function(_m: any)
				return function(ctx: any)
					ctx.sert.test.server("lobby ready", function() ctx.sert.ok(true) end)
				end
			end)

			local reqVal2 = e2.Instance.new("StringValue")
			reqVal2.Name = "sert.Request"
			reqVal2.Parent = rs2
			local resRem2 = e2.Instance.new("RemoteEvent")
			resRem2.Name = "sert.Result"
			resRem2.Parent = rs2

			local hs2 = e2:getService("HttpService")
			local plr1 = { Name = "Player1" }
			local plr2 = { Name = "Player2" }
			local simConn = reqVal2.Changed:Connect(function(raw: string)
				if raw == "" then return end
				local decoded = hs2:JSONDecode(raw)
				local rid = decoded.runId
				local mkOutcome = function(passedCount: number)
					return {
						side = "client",
						passed = passedCount,
						failed = 0,
						skipped = 0,
						todo = 0,
						total = passedCount,
						durationMs = 4,
						failures = {},
						loadErrors = {},
					}
				end
				local srvSig: any = resRem2.OnServerEvent
				-- Wrong runId must be ignored!
				srvSig:Fire(plr1, { runId = "stale-id", outcome = mkOutcome(99) })
				-- Player1 report + duplicate Player1 report (must be deduplicated!).
				local p1Payload = {
					runId = rid,
					outcome = mkOutcome(1),
					markerLines = {
						'[sert-test] {"name":"ClientPing","status":"pass","ms":1}',
						"[sert-x:cli] from-p1",
					},
				}
				srvSig:Fire(plr1, p1Payload)
				srvSig:Fire(plr1, p1Payload)
				-- Player2 report.
				srvSig:Fire(plr2, {
					runId = rid,
					outcome = mkOutcome(2),
					markerLines = {
						'[sert-test] {"name":"ClientPing","status":"pass","ms":2}',
						"[sert-x:cli] from-p2",
					},
				})
			end)

			local vTwo, twoLines = captureRunner(function()
				return Runner.runOnce({ env = e2, sert = function() return sert end, clients = 2 })
			end)
			sert.eq(vTwo.passed, true)
			sert.eq(vTwo.sides.server.passed, 1)
			sert.eq(vTwo.sides["client:Player1"].passed, 1)
			sert.eq(vTwo.sides["client:Player2"].passed, 2)
			sert.eq(vTwo.counts.passed, 4)
			local joinedTwo = table.concat(twoLines, "\n")
			sert.matches(joinedTwo, '"side":"client:Player1"')
			sert.matches(joinedTwo, '"side":"client:Player2"')
			sert.matches(joinedTwo, "%[sert%-x:cli%] from%-p1")
			sert.matches(joinedTwo, "%[sert%-x:cli%] from%-p2")

			-- `list = true` with 2 clients suppresses duplicate non-test markers on `receivedClients > 1`.
			local vTwoList, twoListLines = captureRunner(function()
				return Runner.runOnce({ env = e2, sert = function() return sert end, clients = 2 }, { list = true })
			end)
			sert.eq(vTwoList.passed, true)
			sert.eq(vTwoList.listed, true)
			local joinedList = table.concat(twoListLines, "\n")
			sert.ok(string.find(joinedList, "from-p1", 1, true) ~= nil)
			sert.eq(string.find(joinedList, "from-p2", 1, true), nil)

			-- 4) Client handoff timeout (`clientTimeout = 0.05` with no client responding -> `<client-handoff>` failure).
			simConn:Disconnect()
			local vTimeout = captureRunner(function()
				return Runner.runOnce(
					{ env = e2, sert = function() return sert end, clients = 2, clientTimeout = 0.05 },
					{ side = "client" }
				)
			end)
			sert.eq(vTimeout.passed, false)
			sert.eq(vTimeout.failed, 1)
			sert.eq(vTimeout.failures[1].name, "<client-handoff>")
			sert.eq(vTimeout.loadErrors[1].spec, "<client-handoff>")
			sert.matches(vTimeout.failures[1].message, "Timed out after 0.05s waiting for 2 of 2")
		end
	)

	test(
		"Runner.server supports sert_Args StudioTestService one-shot and warm sert.Request Clone re-runs, plus Runner.client guards",
		function()
			-- 1) `Runner.server` one-shot `sert_Args` attribute + `StudioTestService:EndTest(verdict)`.
			local eOneShot: any = sert.env.new()
			eOneShot.clock = function(self: any): number return self.now end
			makeSpecModule(eOneShot, eOneShot:getService("ServerScriptService"), "BootSpec.spec", function(_m: any)
				return function(ctx: any)
					ctx.sert.test.server("oneshot server spec", function() ctx.sert.ok(true) end)
				end
			end)
			eOneShot.workspace:SetAttribute("sert_Args", '{"runId":"oneshot-1","clients":0}')

			local endedVerdict: any = nil
			local dmOneShot = {
				GetService = function(_self: any, name: string): any
					if name == "StudioTestService" then
						return { EndTest = function(_sts: any, v: any) endedVerdict = v end }
					end
					return eOneShot.game:GetService(name)
				end,
			}

			local srvOneShot: any = nil
			captureRunner(function()
				srvOneShot = Runner.server({
					env = eOneShot,
					game = dmOneShot,
					sert = function() return sert end,
					clients = 0,
				})
				eOneShot:flush()
				return nil
			end)
			sert.ok(endedVerdict ~= nil)
			sert.eq(endedVerdict.runId, "oneshot-1")
			sert.eq(endedVerdict.passed, true)
			sert.eq(endedVerdict.counts.passed, 1)
			srvOneShot.stop()

			-- 2) Warm `Runner.server` + `sert.Request` StringValue listener re-running specs via `requireSpecFresh` Clone!
			local eWarm: any = sert.env.new({ isClient = true, isServer = true })
			eWarm.clock = function(self: any): number return self.now end
			local rsWarm = eWarm:getService("ReplicatedStorage")
			local sssWarm = eWarm:getService("ServerScriptService")

			local moduleLoads = 0
			local testRuns = 0
			makeSpecModule(eWarm, sssWarm, "WarmReload.spec", function(_m: any)
				moduleLoads += 1
				return function(ctx: any)
					ctx.sert.test.server("warm reload pass", function()
						testRuns += 1
						ctx.sert.ok(true)
					end)
				end
			end)

			-- Pre-populate `sert.Request` BEFORE `Runner.server` starts so the startup `reqVal.Value ~= ""` branch runs!
			local warmReqVal = eWarm.Instance.new("StringValue")
			warmReqVal.Name = "sert.Request"
			warmReqVal.Value = '{"runId":"warm-1","clients":0}'
			warmReqVal.Parent = rsWarm

			local srvWarm: any = nil
			captureRunner(function()
				srvWarm = Runner.server({ env = eWarm, sert = function() return sert end, clients = 0 })
				eWarm:flush()
				return nil
			end)
			sert.eq(moduleLoads, 1)
			sert.eq(testRuns, 1)

			-- Duplicate `runId` and malformed JSON are ignored without re-running specs.
			captureRunner(function()
				warmReqVal.Value = "{not-json"
				warmReqVal.Value = '{"runId":"warm-1","clients":0}'
				eWarm:flush()
				return nil
			end)
			sert.eq(moduleLoads, 1)
			sert.eq(testRuns, 1)

			-- Distinct `runId` triggers a fresh `ModuleScript:Clone()` reload and second execution!
			captureRunner(function()
				warmReqVal.Value = '{"runId":"warm-2","clients":0}'
				eWarm:flush()
				return nil
			end)
			sert.eq(moduleLoads, 2)
			sert.eq(testRuns, 2)

			-- Direct `srvWarm.runOnce()` executes a third fresh pass, and `srvWarm.stop()` disconnects the listener.
			local vManual = captureRunner(function() return srvWarm.runOnce({ clients = 0 }) end)
			sert.eq(vManual.passed, true)
			sert.eq(moduleLoads, 3)
			sert.eq(testRuns, 3)

			srvWarm.stop()
			warmReqVal.Value = '{"runId":"warm-after-stop","clients":0}'
			eWarm:flush()
			sert.eq(moduleLoads, 3)

			-- 3) `Runner.client` pre-populated `reqVal.Value ~= ""` startup + error guards on missing comms/services.
			local ePreCli: any = sert.env.new({ isClient = true, isServer = false })
			local rsPre = ePreCli:getService("ReplicatedStorage")
			local spPre = ePreCli:getService("StarterPlayer")
			makeSpecModule(ePreCli, spPre, "PreBootClient.spec", function(_m: any)
				return function(ctx: any)
					ctx.sert.test.client("preboot client spec", function() ctx.sert.ok(true) end)
				end
			end)
			local preReq = ePreCli.Instance.new("StringValue")
			preReq.Name = "sert.Request"
			preReq.Value = '{"runId":"cli-pre-1","side":"client"}'
			preReq.Parent = rsPre
			local preRes = ePreCli.Instance.new("RemoteEvent")
			preRes.Name = "sert.Result"
			preRes.Parent = rsPre

			local preReports: { any } = {}
			preRes.OnServerEvent:Connect(function(_plr: any, payload: any) table.insert(preReports, payload) end)
			local preCli = Runner.client({ env = ePreCli, sert = function() return sert end })
			ePreCli:flush()
			sert.eq(#preReports, 1)
			sert.eq(preReports[1].runId, "cli-pre-1")
			sert.eq(preReports[1].outcome.passed, 1)
			preCli.stop()

			local emptyDm = { GetService = function() return nil end }
			sert.throws(
				function() Runner.client({ env = ePreCli, game = emptyDm }) end,
				"ReplicatedStorage is unavailable"
			)
			sert.throws(function()
				captureRunner(function() return Runner.runOnce({ env = ePreCli, game = emptyDm }) end)
			end, "ReplicatedStorage is unavailable")

			local timeoutRsDm = {
				GetService = function(_self: any, name: string): any
					if name == "ReplicatedStorage" then return { WaitForChild = function() return nil end } end
					return nil
				end,
			}
			sert.throws(function() Runner.client({ env = ePreCli, game = timeoutRsDm }) end, "timed out waiting")
		end
	)
end)
