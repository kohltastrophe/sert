--!strict
-- Deterministic multi-peer simulation (`sert.sim`), unified `Spec<State, Sut>` model checking & VOPR,
-- trace shrinking + `v1:` replay tokens, and distributed Roblox cloud/network hazard regressions.

local registry = require("../src/core/registry")
local sert = require("../src")

local describe = sert.describe
local test = sert.test
local Sim = sert.sim

describe("Multi-peer sert.sim.new() world, replication & remotes", function()
	test(
		"replicates Workspace, ReplicatedStorage, and Players across server and multiple clients with join/leave/kick",
		function()
			local w = Sim.new({ seed = 42 })
			local srv = w:server()
			local sEnv = srv:env()

			local c1 = srv:client(1001)
			local c2 = srv:client(1002)
			local c1Env = c1:env()
			local c2Env = c2:env()

			-- Server spawns replicated instances in Workspace and ReplicatedStorage.
			local mapFolder = sEnv.Instance.new("Folder")
			mapFolder.Name = "Arena"
			mapFolder.Parent = sEnv.workspace

			local beacon = sEnv.Instance.new("Part")
			beacon.Name = "Beacon"
			beacon.Position = sEnv.Vector3.new(12, 34, 56)
			beacon:SetAttribute("Wave", 3)
			beacon.Parent = mapFolder

			local cfg = sEnv.Instance.new("StringValue")
			cfg.Name = "Season"
			cfg.Value = "Launch"
			cfg.Parent = sEnv:getService("ReplicatedStorage")

			w:run(0.1)

			for _, cEnv in { c1Env, c2Env } do
				local cBeacon = cEnv.workspace:FindFirstChild("Arena")
					and cEnv.workspace.Arena:FindFirstChild("Beacon") :: any
				sert.ok(cBeacon ~= nil)
				sert.eq(cBeacon.Position, cEnv.Vector3.new(12, 34, 56))
				sert.eq(cBeacon:GetAttribute("Wave"), 3)

				local cCfg = cEnv:getService("ReplicatedStorage"):FindFirstChild("Season") :: any
				sert.ok(cCfg ~= nil)
				sert.eq(cCfg.Value, "Launch")
				sert.eq(#cEnv:getService("Players"):GetPlayers(), 2)
			end

			-- Join a third player via srv:join, leave one via srv:leave, and kick another via w:kick.
			local p3 = srv:join(1003)
			w:run(0.05)
			sert.eq(#c1Env:getService("Players"):GetPlayers(), 3)

			local removedUsers: { number } = {}
			srv.Players.PlayerRemoving:Connect(function(plr: any) table.insert(removedUsers, plr.UserId) end)

			srv:leave(p3)
			w:kick(srv, c2.player, "AFK timeout")
			w:run(0.1)

			sert.eq(c2.connected, false)
			sert.eq(#sEnv:getService("Players"):GetPlayers(), 1)
			sert.eq(#c1Env:getService("Players"):GetPlayers(), 1)
			sert.eq(removedUsers, { 1003, 1002 })
			sert.eq(w.kicks[1].message, "AFK timeout")
		end
	)

	test(
		"delivers RemoteEvent, UnreliableRemoteEvent, and RemoteFunction across peers with Instance mapping",
		function()
			local w = Sim.new({ seed = 99 })
			local srv = w:server()
			local cli = srv:client(501)
			local sEnv = srv:env()
			local cEnv = cli:env()

			local rs = sEnv:getService("ReplicatedStorage")
			local sReliable = sEnv.Instance.new("RemoteEvent")
			sReliable.Name = "ReliableEvt"
			sReliable.Parent = rs

			local sUnreliable = sEnv.Instance.new("UnreliableRemoteEvent")
			sUnreliable.Name = "FastState"
			sUnreliable.Parent = rs

			local sFunc = sEnv.Instance.new("RemoteFunction")
			sFunc.Name = "PurchaseItem"
			sFunc.Parent = rs

			local chest = sEnv.Instance.new("Part")
			chest.Name = "LootChest"
			chest.Parent = sEnv.workspace

			w:run(0.05)

			local cRs = cEnv:getService("ReplicatedStorage")
			local cReliable = cRs:FindFirstChild("ReliableEvt") :: any
			local cUnreliable = cRs:FindFirstChild("FastState") :: any
			local cFunc = cRs:FindFirstChild("PurchaseItem") :: any
			local cChest = cEnv.workspace:FindFirstChild("LootChest") :: any
			sert.ok(cReliable ~= nil and cUnreliable ~= nil and cFunc ~= nil and cChest ~= nil)

			local serverEvents: { string } = {}
			sReliable.OnServerEvent:Connect(function(plr: any, targetInst: any, count: number)
				-- Client Instance reference maps to the corresponding Server Instance!
				sert.eq(targetInst, chest)
				table.insert(serverEvents, `rel:{plr.UserId}:{targetInst.Name}:{count}`)
				sReliable:FireClient(plr, chest, count * 10)
			end)

			local unreliableHits = 0
			sUnreliable.OnServerEvent:Connect(function(_plr: any, seq: number)
				unreliableHits += seq
			end)

			sFunc.OnServerInvoke = function(plr: any, itemId: string): (boolean, string)
				return true, `{plr.UserId}:{itemId}`
			end

			local clientReplies: { string } = {}
			cReliable.OnClientEvent:Connect(function(mappedInst: any, score: number)
				sert.eq(mappedInst, cChest)
				table.insert(clientReplies, `{mappedInst.Name}:{score}`)
			end)

			cEnv.task.spawn(function()
				cReliable:FireServer(cChest, 3)
				cUnreliable:FireServer(7)
				local ok, receipt = cFunc:InvokeServer("Potion")
				sert.eq(ok, true)
				table.insert(clientReplies, `rpc:{receipt}`)
			end)

			w:run(0.2)

			sert.eq(serverEvents, { "rel:501:LootChest:3" })
			sert.eq(unreliableHits, 7)
			sert.contains(clientReplies, "LootChest:30")
			sert.contains(clientReplies, "rpc:501:Potion")
		end
	)
end)

describe("Unified Spec<State, Sut>, sert.sim.vopr, shrinking & replay tokens", function()
	type BankState = { a: number, b: number }
	type BankSut = { srv: any, ledger: BankState }

	Sim.vopr("bank transfer model preserves total balance under VOPR faults", {
		init = function(): BankState return { a = 100, b = 100 } end,
		setup = function(w: any): BankSut
			local srv = w:server()
			local ds = srv.DataStoreService:GetDataStore("Ledger")
			srv:spawn(function()
				pcall(function() ds:SetAsync("balances", { a = 100, b = 100 }) end)
			end)
			w:converge()
			return { srv = srv, ledger = { a = 100, b = 100 } }
		end,
		commands = {
			transferAtoB = {
				gen = function(_s: BankState, g: any): number return g:int(1, 25) end,
				pre = function(s: BankState, amt: number): boolean return s.a >= amt end,
				run = function(sut: BankSut, amt: number): number
					sut.ledger.a -= amt
					sut.ledger.b += amt
					return sut.ledger.b
				end,
				next = function(s: BankState, amt: number): BankState?
					s.a -= amt
					s.b += amt
					return nil
				end,
			},
			transferBtoA = {
				gen = function(_s: BankState, g: any): number return g:int(1, 25) end,
				pre = function(s: BankState, amt: number): boolean return s.b >= amt end,
				run = function(sut: BankSut, amt: number): number
					sut.ledger.b -= amt
					sut.ledger.a += amt
					return sut.ledger.a
				end,
				next = function(s: BankState, amt: number): BankState?
					s.b -= amt
					s.a += amt
					return nil
				end,
			},
		},
		invariants = {
			conservation = function(s: BankState, sut: BankSut): any
				sert.eq(s.a + s.b, 200)
				sert.eq(sut.ledger.a, s.a)
				sert.eq(sut.ledger.b, s.b)
				return true
			end,
		},
	}, { runs = 12, steps = 10, seed = 2026 })

	test("canonicalize separates numeric vs string keys, and verifyTrace + toItfJson validate traces", function()
		local cNum = Sim.canonicalize({ [1] = "same" })
		local cStr = Sim.canonicalize({ ["1"] = "same" })
		sert.ne(cNum, cStr)

		type CounterState = { n: number }
		local counterSpec = Sim.spec({
			name = "BoundedCounter",
			init = function(): CounterState return { n = 0 } end,
			commands = {
				inc = {
					args = { 1, 2 },
					pre = function(s: CounterState, d: number): boolean return s.n + d <= 4 end,
					next = function(s: CounterState, d: number): CounterState?
						s.n += d
						return nil
					end,
				},
				reset = {
					pre = function(s: CounterState): boolean return s.n > 0 end,
					next = function(s: CounterState): CounterState?
						s.n = 0
						return nil
					end,
				},
			},
			invariants = {
				inBounds = function(s: CounterState, _sut: any, _w: any?): any
					sert.ge(s.n, 0)
					sert.le(s.n, 4)
					return true
				end,
			},
		})

		local checkRes = Sim.check(counterSpec, { bfs = true, vopr = false })
		sert.eq(checkRes.states, 5)
		sert.eq(checkRes.truncated, false)

		local trace: { any } = {
			{ command = "inc", arg = 2, state = { n = 2 } },
			{ command = "inc", arg = 2, state = { n = 4 } },
			{ command = "reset", state = { n = 0 } },
		}
		Sim.verifyTrace(counterSpec, trace)
		local itf = Sim.toItfJson(counterSpec, trace)
		sert.matches(itf, '"states"')
		sert.matches(itf, '"inc"')
	end)

	test(
		"is deterministic per seed, propagates invariant failures directly, shrinks, formats w:summary() once, and roundtrips replay = 'v1:...'",
		function()
			type SumState = { total: number }
			local function recordRun(seed: number): { string }
				local log: { string } = {}
				local spec = Sim.spec({
					init = function(): SumState return { total = 0 } end,
					commands = {
						add = {
							gen = function(_s: SumState, g: any): number return g:int(1, 9) end,
							run = function(_sut: any, x: number): number
								table.insert(log, `+{x}`)
								return x
							end,
							next = function(s: SumState, x: number): SumState?
								s.total += x
								return nil
							end,
						},
					},
				})
				Sim.check(spec, { runs = 4, steps = 5, seed = seed, bfs = false })
				return log
			end

			sert.eq(recordRun(777), recordRun(777))
			sert.ne(recordRun(777), recordRun(888))

			-- Invariant assertion failures MUST NEVER be swallowed: they shrink, emit ONE `[world ...]` summary,
			-- and produce a copy-paste `{ replay = "v1:..." }` token that reproduces the exact minimal failure in 1 trial!
			type BugState = { count: number }
			type BugSut = { srv: any, count: number }
			local teardownCalls = 0
			local buggySpec = Sim.spec({
				name = "OverflowBug",
				init = function(): BugState return { count = 0 } end,
				setup = function(w: any): BugSut
					local srv = w:server()
					return { srv = srv, count = 0 }
				end,
				teardown = function(_sut: BugSut, _w: any)
					teardownCalls += 1
				end,
				commands = {
					bump = {
						gen = function(_s: BugState, g: any): number return g:int(1, 10) end,
						run = function(sut: BugSut, delta: number): number
							-- Deliberate bug when delta >= 4: SUT drifts by +1 from model!
							sut.count += if delta >= 4 then delta + 1 else delta
							return sut.count
						end,
						next = function(s: BugState, delta: number): BugState?
							s.count += delta
							return nil
						end,
					},
				},
				invariants = {
					matchesModel = function(s: BugState, sut: BugSut): any
						sert.eq(sut.count, s.count)
						return true
					end,
				},
			})

			local ok, errObj = pcall(
				function() Sim.check(buggySpec, { runs = 30, steps = 12, seed = 1337, bfs = false }) end
			)
			sert.eq(ok, false)
			local report = tostring(errObj)
			sert.gt(teardownCalls, 1) -- ran across multiple shrink probes

			-- Count occurrences of `[world t=` in the report: w:summary() must be formatted ONLY ONCE post-shrink!
			local summaryBlocks = 0
			for _ in string.gmatch(report, "%[world t=") do
				summaryBlocks += 1
			end
			sert.eq(summaryBlocks, 1)

			-- Shrunk counterexample should be 1 step (`bump(4)`).
			sert.matches(report, "Shrunk steps:")
			sert.matches(report, "bump%(4%)")

			local token = string.match(report, 'replay = "(v1:[^"]+)"')
			sert.ok(token ~= nil, "expected v1 replay token in VOPR failure report")

			local beforeReplayTeardowns = teardownCalls
			local okReplay, replayErr = pcall(function() Sim.check(buggySpec, { replay = token :: string }) end)
			sert.eq(okReplay, false)
			-- Exact replay runs 1 trial with zero extra shrink probes!
			sert.eq(teardownCalls - beforeReplayTeardowns, 1)
			sert.matches(tostring(replayErr), "bump%(4%)")
		end
	)

	test(
		"applies VOPR network drop, reorder, duplicate, and latency faults to real RemoteEvents in ReplicatedStorage",
		function()
			-- 1) 100% drop on UnreliableRemoteEvent drops unreliable packets while reliable RemoteEvent with 0% drop arrives.
			do
				local w = Sim.new({
					seed = 11,
					mode = "random",
					faults = {
						remoteDropRate = 1.0,
						remoteLatencyRange = { 0.02, 0.05 },
					},
				})
				local srv = w:server()
				local cli = srv:client(201)
				local sEnv = srv:env()
				local cEnv = cli:env()

				local uev = sEnv.Instance.new("UnreliableRemoteEvent")
				uev.Name = "Telemetry"
				uev.Parent = sEnv:getService("ReplicatedStorage")
				w:run(0.05)

				local cUev = cEnv:getService("ReplicatedStorage"):FindFirstChild("Telemetry") :: any
				local received = 0
				uev.OnServerEvent:Connect(function()
					received += 1
				end)

				for i = 1, 8 do
					cUev:FireServer(i)
				end
				w:run(0.5)
				sert.eq(received, 0)
			end

			-- 2) Reorder + duplicate + latency on real RemoteEvent in ReplicatedStorage.
			do
				local w = Sim.new({
					seed = 29,
					mode = "random",
					faults = {
						remoteDropRate = 0,
						remoteReorderRate = 1.0,
						remoteDuplicateRate = 0.5,
						remoteLatencyRange = { 0.01, 0.08 },
					},
				})
				local srv = w:server()
				local cli = srv:client(202)
				local sEnv = srv:env()
				local cEnv = cli:env()

				local rev = sEnv.Instance.new("RemoteEvent")
				rev.Name = "ActionStream"
				rev.Parent = sEnv:getService("ReplicatedStorage")
				w:run(0.05)

				local cRev = cEnv:getService("ReplicatedStorage"):FindFirstChild("ActionStream") :: any
				local seqLog: { number } = {}
				rev.OnServerEvent:Connect(function(_plr: any, seq: number) table.insert(seqLog, seq) end)

				for seq = 1, 12 do
					cRev:FireServer(seq)
				end
				-- Immediately after FireServer, latency keeps packets in flight (0 delivered synchronously).
				sert.eq(#seqLog, 0)

				w:run(1.0)
				-- Duplicate rate > 0 produces > 12 deliveries, and reorder rate = 1 scrambles arrival order!
				sert.gt(#seqLog, 12)
				local outOfOrder = false
				for i = 2, #seqLog do
					if seqLog[i] < seqLog[i - 1] then
						outOfOrder = true
						break
					end
				end
				sert.eq(outOfOrder, true)
			end
		end
	)
end)

describe("VOPR cloud & server lifecycle hazard regressions", function()
	test(
		"DataStore SetAsync late write isolates snapshot at call time and avoids premature local cache fill",
		function()
			local w = Sim.new({ seed = 31 })
			local srv = w:server()
			local ds = srv.DataStoreService:GetDataStore("Profiles")

			srv:spawn(function() ds:SetAsync("u_1", { gold = 10, items = { "dagger" } }) end)
			w:converge()

			-- Inject a one-shot `late` fault on the next SetAsync.
			w:fail("DataStore", "SetAsync", "late")

			local payload = { gold = 500, items = { "excalibur" } }
			local setErr: any = nil
			local immediateRead: any = nil

			srv:spawn(function()
				local ok, err = pcall(function() ds:SetAsync("u_1", payload) end)
				if not ok then setErr = err end
				-- Mutate caller's table immediately after SetAsync returns/errors!
				payload.gold = -9999
				payload.items[1] = "broken_stick"
				-- Read before the detached late write lands: must still see 10, NOT 500 or -9999!
				immediateRead = ds:GetAsync("u_1")
			end)

			w:run(0.05)
			sert.ok(setErr ~= nil, "expected simulated late timeout error")
			sert.eq(immediateRead.gold, 10)

			-- Advance past the late commit window + 4s read cache TTL: backing store has isolated { gold = 500, items = { "excalibur" } }!
			w:run(5.0)
			local finalRead: any = nil
			srv:spawn(function() finalRead = ds:GetAsync("u_1") end)
			w:converge()
			sert.eq(finalRead, { gold = 500, items = { "excalibur" } })
		end
	)

	test("MemoryStore stale read returns an isolated deep copy without corrupting historical or live values", function()
		local w = Sim.new({
			seed = 44,
			mode = "random",
			faults = { stale = 1.0 },
		})
		local srv = w:server()
		local sm = srv.MemoryStoreService:GetSortedMap("SessionLocks")

		srv:spawn(function()
			sm:SetAsync("lock_1", { owner = "srvA", tags = { "v1" } }, 60)
			sm:SetAsync("lock_1", { owner = "srvB", tags = { "v2" } }, 60)
		end)
		w:converge()

		-- Stale reads on MemoryStore.GetAsync return isolated deep copies of historical entries (step with w:run so faults stay active).
		local staleFirst: any = nil
		local staleSecond: any = nil
		srv:spawn(function()
			staleFirst = sm:GetAsync("lock_1")
			-- Mutate the returned stale table aggressively!
			staleFirst.owner = "CORRUPTED"
			staleFirst.tags[1] = "MUTATED"
			staleSecond = sm:GetAsync("lock_1")
		end)
		w:run(2.0)

		sert.eq(staleSecond.owner, "srvA")
		sert.eq(staleSecond.tags, { "v1" })

		-- Disable stale reads and verify live value is untouched.
		w.faults.stale = 0
		local liveVal: any = nil
		srv:spawn(function() liveVal = sm:GetAsync("lock_1") end)
		w:converge()
		sert.eq(liveVal, { owner = "srvB", tags = { "v2" } })
	end)

	test(
		"MemoryStoreQueue wakes blocked ReadAsync event-driven on AddAsync and invisibility lease expiration",
		function()
			local w = Sim.new({ seed = 52 })
			local srv = w:server()
			local q = srv.MemoryStoreService:GetQueue("MatchTickets", 2) -- 2s invisibility timeout

			local stages: { string } = {}
			local firstId: string? = nil

			-- Consumer 1 blocks on an empty queue with a 10s waitTimeout; producer wakes it at t=0.2s!
			srv:spawn(function()
				table.insert(stages, "consumer1:waiting")
				local items, id = q:ReadAsync(1, false, 10)
				firstId = id
				table.insert(stages, `consumer1:got:{items[1]}@{string.format("%.1f", w:now())}`)
				-- Intentionally do NOT call RemoveAsync so the 2s invisibility lease expires!
			end)

			w:run(0.2)
			sert.eq(stages, { "consumer1:waiting" })

			srv:spawn(function() q:AddAsync("ticket_alpha", 60, 1) end)
			w:run(0.05)
			sert.eq(#stages, 2)
			sert.ok(firstId ~= nil)

			-- Consumer 2 starts waiting while ticket_alpha is invisible; wakes automatically when 2s lease expires!
			local redelivered: any = nil
			srv:spawn(function()
				local items, id = q:ReadAsync(1, false, 10)
				redelivered = items[1]
				q:RemoveAsync(id)
			end)

			w:run(1.0)
			sert.eq(redelivered, nil) -- still invisible at +1.0s
			w:run(1.5)
			sert.eq(redelivered, "ticket_alpha")
		end
	)

	test(
		"30s BindToClose budget completes normal saves and detaches in-flight task.spawn SetAsync writes at cutoff",
		function()
			-- Case A: Normal save inside BindToClose finishes cleanly within the 30s budget.
			do
				local w = Sim.new({ seed = 60, latency = { DataStore = 0.5 } })
				local srv = w:server()
				local sEnv = srv:env()
				local ds = sEnv:getService("DataStoreService"):GetDataStore("ShutdownSave")

				sEnv.game:BindToClose(function() ds:SetAsync("clean", { saved = true }) end)

				w.scheduler:spawn(srv, function() srv:shutdown() end)
				w:run(2.0)
				sert.eq(srv.state, "down")

				local srv2 = w:server()
				local loaded: any = nil
				srv2:spawn(function() loaded = srv2.DataStoreService:GetDataStore("ShutdownSave"):GetAsync("clean") end)
				w:run(2.0)
				sert.eq(loaded, { saved = true })
			end

			-- Case B: A BindToClose callback hangs past 30s while a detached task.spawn SetAsync is still in flight at t=30s.
			do
				local w = Sim.new({ seed = 61, latency = { DataStore = 5.0 } })
				local srv = w:server()
				local sEnv = srv:env()
				local ds = sEnv:getService("DataStoreService"):GetDataStore("CutoffSave")

				sEnv.game:BindToClose(function()
					sEnv.task.delay(28, function()
						-- Starts SetAsync at t=28s with 5s DataStore latency -> still in flight at the 30s hard cutoff!
						ds:SetAsync("inflight_at_cutoff", { gold = 777 })
					end)
					sEnv.task.wait(60) -- exceeds 30s BindToClose budget
				end)

				w.scheduler:spawn(srv, function() srv:shutdown() end)
				w:run(35)
				w:converge()

				sert.eq(srv.state, "down")
				local srv2 = w:server()
				local recovered: any = nil
				srv2:spawn(
					function()
						recovered = srv2.DataStoreService:GetDataStore("CutoffSave"):GetAsync("inflight_at_cutoff")
					end
				)
				w:converge()
				sert.eq(recovered, { gold = 777 })
			end
		end
	)

	test(
		"MessagingService:PublishAsync auto-delivers across live servers and respects network partition/heal",
		function()
			local w = Sim.new({ seed = 71 })
			local s1 = w:server()
			local s2 = w:server()
			local e1 = s1:env()
			local e2 = s2:env()

			local inbox2: { any } = {}
			s2:spawn(function()
				e2:getService("MessagingService")
					:SubscribeAsync("GlobalBans", function(packet: any) table.insert(inbox2, packet.Data) end)
			end)
			w:converge()

			s1:spawn(function() e1:getService("MessagingService"):PublishAsync("GlobalBans", { userId = 404 }) end)
			w:converge()
			sert.eq(inbox2, { { userId = 404 } })

			-- Partition s2: messages published while partitioned do not arrive; healing restores delivery.
			w:isolate(s2)
			s1:spawn(function() e1:getService("MessagingService"):PublishAsync("GlobalBans", { userId = 505 }) end)
			w:run(0.5)
			sert.eq(#inbox2, 1)

			w:heal()
			s1:spawn(function() e1:getService("MessagingService"):PublishAsync("GlobalBans", { userId = 606 }) end)
			w:converge()
			sert.eq(inbox2, { { userId = 404 }, { userId = 606 } })
		end
	)

	test(
		"TeleportService:TeleportAsync exercises arrival-before-PlayerRemoving handoff race (teleportRaceRate)",
		function()
			local w = Sim.new({
				seed = 81,
				mode = "random",
				faults = { teleportRaceRate = 1.0 },
			})

			local timeline: { string } = {}
			w:onServerStart(function(srv: any)
				local env = srv:env()
				env:getService("Players").PlayerAdded:Connect(function(plr: any)
					local joinData = plr:GetJoinData()
					local tag = if joinData and joinData.TeleportData then joinData.TeleportData.tag else "initial"
					table.insert(timeline, `{srv.name}:added:{plr.UserId}:{tag}`)
				end)
				env:getService("Players").PlayerRemoving
					:Connect(function(plr: any) table.insert(timeline, `{srv.name}:removing:{plr.UserId}`) end)
			end)

			local s1 = w:server({ placeId = 100 })
			local s2 = w:server({ placeId = 200 })
			local cli = s1:client(901)
			w:run(0.05)

			-- Run multiple teleports so `teleportRaceRate = 1.0` exercises arrival overlapping/preceding removal!
			local s1Env = s1:env()
			local tpOpts = s1Env.Instance.new("TeleportOptions")
			tpOpts:SetTeleportData({ tag = "dungeon" })

			s1:spawn(function() s1Env:getService("TeleportService"):TeleportAsync(200, { cli.player }, tpOpts) end)
			w:converge()

			sert.eq(#s1.clients, 0)
			sert.eq(#s2.clients, 1)
			sert.eq(s2.clients[1].userId, 901)
			sert.contains(timeline, `{s2.name}:added:901:dungeon`)
			sert.contains(timeline, `{s1.name}:removing:901`)
		end
	)

	test(
		"rolling Server:shutdown() (rollingShutdownRate) boots replacement server against shared cloud persistence",
		function()
			local bootedServers = 0
			local activePlayersByServer: { [string]: number } = {}

			type DeployState = { deposits: number }
			type DeploySut = { world: any }
			local spec = Sim.spec({
				name = "RollingDeployPersistence",
				world = {
					faults = {
						rollingShutdownRate = 1.0,
						teleportRaceRate = 0.5,
					},
				},
				init = function(): DeployState return { deposits = 0 } end,
				setup = function(w: any): DeploySut
					bootedServers = 0
					table.clear(activePlayersByServer)
					w:onServerStart(function(srv: any)
						bootedServers += 1
						local env = srv:env()
						env:getService("Players").PlayerAdded:Connect(
							function(_plr: any)
								activePlayersByServer[srv.name] = (activePlayersByServer[srv.name] or 0) + 1
							end
						)
					end)
					local s1 = w:server()
					s1:client(701)
					w:run(0.05)
					return { world = w }
				end,
				commands = {
					deposit = {
						args = { 10 },
						run = function(sut: DeploySut, amount: number, _w: any): number
							-- Find whichever live server currently hosts player 701 and increment shared DataStore!
							local host: any = nil
							for _, srv in sut.world.servers do
								if srv.state == "up" then
									host = srv
									break
								end
							end
							if host ~= nil then
								host:spawn(function()
									local ds = host.DataStoreService:GetDataStore("SharedBank")
									ds:UpdateAsync("u_701", function(old: any) return (old or 0) + amount end)
								end)
								sut.world:converge()
							end
							return amount
						end,
						next = function(s: DeployState, amount: number): DeployState?
							s.deposits += amount
							return nil
						end,
					},
				},
				invariants = {
					bankMatches = function(s: DeployState, sut: DeploySut): any
						sut.world:converge()
						local live: any = nil
						for _, srv in sut.world.servers do
							if srv.alive then
								live = srv
								break
							end
						end
						sert.ok(live ~= nil, "at least one live replacement server must exist")
						local stored = 0
						live:spawn(
							function() stored = live.DataStoreService:GetDataStore("SharedBank"):GetAsync("u_701") or 0 end
						)
						sut.world:converge()
						sert.eq(stored, s.deposits)
						return true
					end,
				},
			})

			Sim.check(spec, { runs = 3, minSteps = 3, steps = 4, seed = 95, bfs = false })
			-- Rolling shutdown booted at least one replacement server beyond s1!
			sert.gt(bootedServers, 1)
		end
	)

	test(
		"MarketplaceService.ProcessReceipt redelivers across NotProcessedYet, errors, and receiptDuplicateRate until idempotent PurchaseGranted",
		function()
			local w = Sim.new({
				seed = 108,
				mode = "random",
				faults = { receiptDuplicateRate = 1.0 },
			})
			local srv = w:server()
			local cli = srv:client(303)
			local sEnv = srv:env()
			local mps = sEnv:getService("MarketplaceService")
			local ds = sEnv:getService("DataStoreService"):GetDataStore("ReceiptLedger")

			local callbackInvocations = 0
			mps.ProcessReceipt = function(receiptInfo: any)
				callbackInvocations += 1
				-- Attempt 1: transient failure; Attempt 2: NotProcessedYet; Attempt 3+: idempotent grant + ACK-loss duplicate!
				if callbackInvocations == 1 then error("transient datastore hiccup") end
				if callbackInvocations == 2 then return sEnv.Enum.ProductPurchaseDecision.NotProcessedYet end

				local grantedNow = false
				ds:UpdateAsync(`user_{receiptInfo.PlayerId}`, function(old: any)
					local doc = old or { gems = 0, processed = {} }
					if doc.processed[receiptInfo.PurchaseId] then return doc end
					doc.processed[receiptInfo.PurchaseId] = true
					doc.gems += 100
					grantedNow = true
					return doc
				end)
				local _ = grantedNow
				return sEnv.Enum.ProductPurchaseDecision.PurchaseGranted
			end

			local purchaseId = w:purchaseProduct(cli, 99901, 150)
			w:run(15.0)
			w:converge()

			-- Attempt 1 (error) + Attempt 2 (NotProcessedYet) + Attempt 3 (PurchaseGranted + receiptDuplicateRate=1 ACK loss) + Attempt 4 (duplicate PurchaseGranted)!
			sert.ge(callbackInvocations, 4)

			local profile: any = nil
			srv:spawn(function() profile = ds:GetAsync("user_303") end)
			w:converge()
			sert.eq(profile.gems, 100)
			sert.eq(profile.processed[purchaseId], true)
		end
	)
end)

local function runSimIsolated(register: () -> (), opts: sert.RunOptions?): sert.Results
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

describe("Sim.explore, BFS Sim.check, verifyTrace diffs, and Sim.vopr modifiers", function()
	test("Sim.explore passes on mutex-protected concurrent tasks and registers named tests", function()
		local directRuns = 0
		local directOutcome = Sim.explore(function(w: sert.SimWorld)
			directRuns += 1
			local srv = w:server()
			local locked = false
			local waitQueue: { thread } = {}
			local balance = 0

			local function withLock(delta: number)
				if locked then
					table.insert(waitQueue, coroutine.running())
					coroutine.yield()
				end
				locked = true
				local snap = balance
				local stepDelay = if w.scheduler:choose(2, "io.delay") == 1 then 0.01 else 0.04
				w:sleep(stepDelay)
				balance = snap + delta
				local nextThread = table.remove(waitQueue, 1)
				if nextThread ~= nil then
					w.scheduler:resume(nextThread)
				else
					locked = false
				end
			end

			srv:spawn(function() withLock(10) end)
			srv:spawn(function() withLock(25) end)
			w:run(1.0)
			sert.eq(balance, 35)
		end)

		sert.ok(directOutcome ~= nil)
		sert.gt((directOutcome :: any).runs, 1)
		sert.eq((directOutcome :: any).failure, nil)
		sert.eq(directRuns, (directOutcome :: any).runs)

		local namedRuns = 0
		local childRes = runSimIsolated(function()
			Sim.explore("named Sim.explore suite", function(w: sert.SimWorld)
				namedRuns += 1
				local pick = w.scheduler:choose(2, "branch")
				sert.ok(pick == 1 or pick == 2)
			end, { maxRuns = 8, seed = 9 })
		end)
		sert.eq(childRes.passed, 1)
		sert.eq(childRes.failed, 0)
		sert.eq(namedRuns, 2)

		sert.throws(function() Sim.explore({} :: any) end, "expected callback function")
	end)

	test(
		"Sim.explore catches concurrent interleaving races and uncaught peer task errors with schedule trace",
		function()
			-- Two concurrent withdrawals without locking: one interleaving reads stale balance = 100 twice and overdrafts to -60!
			local okRace, raceErr = pcall(function()
				Sim.explore({ maxRuns = 32, seed = 5 }, function(w: sert.SimWorld)
					local srv = w:server()
					local balance = 100

					local function withdrawUnsafe(amount: number)
						local seen = balance
						if seen >= amount then
							local delay = if w.scheduler:choose(2, "withdraw.jitter") == 1 then 0.01 else 0.05
							w:sleep(delay)
							balance -= amount
						end
					end

					srv:spawn(function() withdrawUnsafe(80) end)
					srv:spawn(function() withdrawUnsafe(80) end)
					w:run(0.5)
					sert.ge(balance, 0)
				end)
			end)

			sert.eq(okRace, false)
			local raceMsg = tostring(raceErr)
			sert.contains(raceMsg, "Sim.explore failed on run #")
			sert.contains(raceMsg, "choices = {")
			sert.contains(raceMsg, "[world t=")

			-- Uncaught error inside a spawned server coroutine on one schedule branch is caught by `w:assertNoErrors`.
			local okTaskErr, taskErr = pcall(function()
				Sim.explore({ maxRuns = 16, seed = 3 }, function(w: sert.SimWorld)
					local srv = w:server()
					srv:spawn(function()
						if w.scheduler:choose(2, "crash.branch") == 2 then error("background worker exploded", 0) end
					end)
					w:run(0.1)
				end)
			end)
			sert.eq(okTaskErr, false)
			sert.contains(tostring(taskErr), "background worker exploded")
			sert.contains(tostring(taskErr), "Sim.explore failed on run #2 (choices = {")
		end
	)

	test(
		"Sim.check BFS explores dynamic args, reports truncation, and finds minimal multi-step counterexamples",
		function()
			type VaultState = { balance: number, locked: boolean, overrides: number }

			local safeVault = Sim.spec({
				name = "SafeVault",
				init = function(): VaultState return { balance = 0, locked = false, overrides = 0 } end,
				commands = {
					deposit = {
						args = { 1, 2 },
						pre = function(s: VaultState, amt: number): boolean
							return not s.locked and s.balance + amt <= 4
						end,
						next = function(s: VaultState, amt: number): VaultState?
							s.balance += amt
							return nil
						end,
					},
					toggleLock = {
						args = { true },
						next = function(s: VaultState, _flag: boolean): VaultState?
							s.locked = not s.locked
							return nil
						end,
					},
					withdraw = {
						args = function(s: VaultState): { number }
							local choices: { number } = {}
							for amt = 1, s.balance do
								table.insert(choices, amt)
							end
							return choices
						end,
						pre = function(s: VaultState, amt: number): boolean return not s.locked and amt <= s.balance end,
						next = function(s: VaultState, amt: number): VaultState?
							s.balance -= amt
							return nil
						end,
					},
				},
				invariants = {
					nonNegative = function(s: VaultState, _sut: any, _w: any?): any
						sert.ge(s.balance, 0)
						sert.le(s.balance, 4)
						return true
					end,
				},
			})

			local fullRes = Sim.check(safeVault)
			sert.eq(fullRes.states, 10)
			sert.eq(fullRes.truncated, false)
			sert.eq(fullRes.cases, 0)

			local truncDepth = Sim.check(safeVault, { maxDepth = 2 })
			sert.eq(truncDepth.truncated, true)
			sert.eq(truncDepth.depth, 2)

			local truncStates = Sim.check(safeVault, { maxStates = 4 })
			sert.eq(truncStates.truncated, true)
			sert.eq(truncStates.states, 4)

			-- Multi-step bug reachable ONLY at depth 3: `deposit(2) -> armOverride(true) -> forceWithdraw(3)` drives balance to -1.
			local buggyVault = Sim.spec({
				name = "BuggyVault",
				init = function(): VaultState return { balance = 0, locked = false, overrides = 0 } end,
				commands = {
					deposit = {
						args = { 1, 2 },
						pre = function(s: VaultState, amt: number): boolean return s.balance + amt <= 3 end,
						next = function(s: VaultState, amt: number): VaultState?
							s.balance += amt
							return nil
						end,
					},
					armOverride = {
						args = { true },
						pre = function(s: VaultState, _flag: boolean): boolean
							return s.balance == 2 and s.overrides == 0
						end,
						next = function(s: VaultState, _flag: boolean): VaultState?
							s.overrides = 1
							return nil
						end,
					},
					forceWithdraw = {
						args = function(s: VaultState): { number } return if s.overrides > 0 then { 1, 3 } else { 1 } end,
						pre = function(s: VaultState, amt: number): boolean
							return if s.overrides > 0 then amt <= s.balance + 1 else amt <= s.balance
						end,
						next = function(s: VaultState, amt: number): VaultState?
							s.balance -= amt
							return nil
						end,
					},
				},
				invariants = {
					neverOverdraft = function(s: VaultState, _sut: any, _w: any?): any
						sert.ge(s.balance, 0)
						return true
					end,
				},
			})

			local okBfs, bfsErr = pcall(function() Sim.check(buggyVault) end)
			sert.eq(okBfs, false)
			local bfsMsg = tostring(bfsErr)
			sert.contains(
				bfsMsg,
				"Sim.check counterexample at depth 3 (deposit(2) -> armOverride(true) -> forceWithdraw(3)):"
			)
			sert.contains(bfsMsg, "State:")

			local badInitSpec = Sim.spec({
				init = function(): { x: number } return { x = -5 } end,
				commands = {
					noop = { next = function(s: { x: number }): { x: number }? return s end },
				},
				invariants = {
					positive = function(s: { x: number }, _sut: any, _w: any?): any
						sert.gt(s.x, 0)
						return true
					end,
				},
			})
			sert.throws(function() Sim.check(badInitSpec) end, "Sim.check initial state failed invariant")
		end
	)

	test("Sim.verifyTrace clones caller inputs, validates matching traces, and formats clear step diffs", function()
		type Ledger = { coins: number, items: { string } }
		local ledgerSpec = Sim.spec({
			init = function(): Ledger return { coins = 10, items = {} } end,
			commands = {
				earn = {
					pre = function(_s: Ledger, amt: number): boolean return amt > 0 end,
					next = function(s: Ledger, amt: number): Ledger?
						s.coins += amt
						return nil
					end,
				},
				buy = {
					pre = function(s: Ledger, req: { item: string, cost: number }): boolean return s.coins >= req.cost end,
					next = function(s: Ledger, req: { item: string, cost: number }): Ledger?
						s.coins -= req.cost
						table.insert(s.items, req.item)
						return nil
					end,
				},
			},
			invariants = {
				solvent = function(s: Ledger, _sut: any, _w: any?): any
					sert.ge(s.coins, 0)
					return true
				end,
			},
		})

		local customInit: Ledger = { coins = 5, items = { "starter" } }
		local buyArg = { item = "shield", cost = 4 }
		local validTrace: { any } = {
			{ command = "earn", arg = 3, state = { coins = 8, items = { "starter" } } },
			{ command = "buy", arg = buyArg, state = { coins = 4, items = { "starter", "shield" } } },
		}
		local finalState = Sim.verifyTrace(ledgerSpec, validTrace, customInit)
		sert.eq(finalState, { coins = 4, items = { "starter", "shield" } })
		-- Caller `customInit` must remain untouched despite mutating `next` transitions.
		sert.eq(customInit, { coins = 5, items = { "starter" } })

		local divergentTrace: { any } = {
			{ command = "earn", arg = 5, state = { coins = 15, items = {} } },
			{ command = "buy", arg = { item = "sword", cost = 6 }, state = { coins = 99, items = { "sword" } } },
		}
		local okDiv, divErr = pcall(function() Sim.verifyTrace(ledgerSpec, divergentTrace) end)
		sert.eq(okDiv, false)
		local divMsg = tostring(divErr)
		sert.contains(divMsg, "verifyTrace step #2 ('buy'): projected state diverged from model")
		sert.contains(divMsg, "coins")

		sert.throws(
			function() Sim.verifyTrace(ledgerSpec, { { command = "teleport", arg = 1 } }) end,
			"unknown command 'teleport'"
		)

		sert.throws(
			function() Sim.verifyTrace(ledgerSpec, { { command = "buy", arg = { item = "crown", cost = 50 } } }) end,
			"precondition failed"
		)
	end)

	test("Sim.vopr supports skip/focus/target gating, replay token roundtrips, and rejects malformed tokens", function()
		type StepState = { v: number }
		local passSpec = Sim.spec({
			init = function(): StepState return { v = 0 } end,
			setup = function(_w: any): { v: number } return { v = 0 } end,
			commands = {
				inc = {
					gen = function(_s: StepState, g: any): number return g:int(1, 3) end,
					run = function(sut: { v: number }, x: number): number
						sut.v += x
						return sut.v
					end,
					next = function(s: StepState, x: number): StepState?
						s.v += x
						return nil
					end,
				},
			},
			invariants = {
				synced = function(s: StepState, sut: { v: number }): any
					sert.eq(sut.v, s.v)
					return true
				end,
			},
		})

		local executed: { string } = {}
		local function trackedSpec(tag: string)
			return Sim.spec({
				init = function(): StepState return { v = 0 } end,
				setup = function(_w: any): boolean
					table.insert(executed, tag)
					return true
				end,
				commands = {
					step = {
						run = function(): nil return nil end,
						next = function(s: StepState): StepState?
							s.v += 1
							return nil
						end,
					},
				},
			})
		end

		local headlessRes = runSimIsolated(function()
			Sim.vopr("portable vopr", trackedSpec("portable"), { runs = 2, steps = 2 })
			Sim.vopr.skip("skipped vopr", trackedSpec("skip"))
			Sim.vopr.roblox("roblox vopr", trackedSpec("roblox"), { runs = 1, steps = 1 })
			Sim.vopr.roblox.skip("roblox skip vopr", trackedSpec("roblox.skip"))
			Sim.vopr.server("server vopr", trackedSpec("server"), { runs = 1, steps = 1 })
			Sim.vopr.server.skip("server skip vopr", trackedSpec("server.skip"))
			Sim.vopr.client("client vopr", trackedSpec("client"), { runs = 1, steps = 1 })
			Sim.vopr.client.skip("client skip vopr", trackedSpec("client.skip"))
		end)
		sert.eq(headlessRes.passed, 1)
		sert.eq(headlessRes.skipped, 7)
		sert.eq(headlessRes.skippedRoblox, 6)
		sert.eq(executed, { "portable", "portable" })

		table.clear(executed)
		local allTargetsRes = runSimIsolated(function()
			Sim.vopr("portable vopr", trackedSpec("portable"), { runs = 1, steps = 1 })
			Sim.vopr.roblox("roblox vopr", trackedSpec("roblox"), { runs = 1, steps = 1 })
			Sim.vopr.server("server vopr", trackedSpec("server"), { runs = 1, steps = 1 })
			Sim.vopr.client("client vopr", trackedSpec("client"), { runs = 1, steps = 1 })
		end, { allTargets = true })
		sert.eq(allTargetsRes.passed, 4)
		sert.eq(executed, { "portable", "roblox", "server", "client" })

		table.clear(executed)
		local focusRes = runSimIsolated(function()
			Sim.vopr("unfocused", trackedSpec("unfocused"), { runs = 1, steps = 1 })
			Sim.vopr.focus("focused portable", trackedSpec("focus.portable"), { runs = 1, steps = 1 })
			Sim.vopr.roblox.focus("focused roblox", trackedSpec("focus.roblox"), { runs = 1, steps = 1 })
		end, { ci = false, allTargets = true })
		sert.eq(focusRes.passed, 2)
		sert.eq(executed, { "focus.portable", "focus.roblox" })

		-- Passing replay token runs 1 trial cleanly; failing VOPR suite roundtrips `runOptions.replay`.
		local passReplay = Sim.check(passSpec, { replay = "v1:42:40:0,1,0" })
		sert.eq(passReplay.cases, 1)

		local failSuiteRes = runSimIsolated(function()
			Sim.vopr(
				"vopr bug",
				Sim.spec({
					init = function(): StepState return { v = 0 } end,
					setup = function(_w: any): { v: number } return { v = 0 } end,
					commands = {
						hit = {
							gen = function(_s: StepState, g: any): number return g:int(1, 5) end,
							run = function(sut: { v: number }, n: number): number
								sut.v += if n >= 3 then n + 10 else n
								return sut.v
							end,
							next = function(s: StepState, n: number): StepState?
								s.v += n
								return nil
							end,
						},
					},
					invariants = {
						eq = function(s: StepState, sut: { v: number }): any
							sert.eq(sut.v, s.v)
							return true
						end,
					},
				}),
				{ runs = 25, steps = 6, seed = 99 }
			)
		end)
		sert.eq(failSuiteRes.failed, 1)
		local voprToken = string.match(failSuiteRes.failures[1], 'replay = "(v1:[^"]+)"')
		sert.ok(voprToken ~= nil)

		local replayedTrials = 0
		local replayedRes = runSimIsolated(function()
			Sim.vopr(
				"vopr bug",
				Sim.spec({
					init = function(): StepState return { v = 0 } end,
					setup = function(_w: any): { v: number }
						replayedTrials += 1
						return { v = 0 }
					end,
					commands = {
						hit = {
							gen = function(_s: StepState, g: any): number return g:int(1, 5) end,
							run = function(sut: { v: number }, n: number): number
								sut.v += if n >= 3 then n + 10 else n
								return sut.v
							end,
							next = function(s: StepState, n: number): StepState?
								s.v += n
								return nil
							end,
						},
					},
					invariants = {
						eq = function(s: StepState, sut: { v: number }): any
							sert.eq(sut.v, s.v)
							return true
						end,
					},
				}),
				{ runs = 25, steps = 6, seed = 99 }
			)
		end, { replay = voprToken :: string })
		sert.eq(replayedRes.failed, 1)
		sert.eq(replayedTrials, 1)

		for _, badToken in { "", "v2:1:40:0", "v1:abc:40:0", "v1:1:40:1,nope" } do
			sert.throws(function() Sim.check(passSpec, { replay = badToken }) end, "malformed replay token")
		end
	end)
end)

describe("World & Fabric partitions, remote FIFO/RPC disconnect, and cloud faults", function()
	test(
		"MessagingService enforces partition, isolate, timed expiry, heal, and drop/duplicate/subscribe faults",
		function()
			local w = Sim.new({ seed = 51 })
			w:setLatency("MessagingService", 0.05)
			local s1 = w:server()
			local s2 = w:server()
			local s3 = w:server()

			local inbox1: { string } = {}
			local inbox2: { string } = {}
			local inbox3: { string } = {}

			s1:spawn(function()
				s1.MessagingService:SubscribeAsync("guild", function(msg: any) table.insert(inbox1, msg.Data) end)
			end)
			s2:spawn(function()
				s2.MessagingService:SubscribeAsync("guild", function(msg: any) table.insert(inbox2, msg.Data) end)
			end)
			s3:spawn(function()
				s3.MessagingService:SubscribeAsync("guild", function(msg: any) table.insert(inbox3, msg.Data) end)
			end)
			w:converge()

			w:partition(s2, 1.0)
			w:isolate(s3)
			sert.eq(w:isolated(s1), false)
			sert.eq(w:isolated(s2), true)
			sert.eq(w:isolated(s3), true)
			sert.eq(w:isPartitioned(s1, s2), true)
			sert.eq(w:isPartitioned(s1, s1), false)

			-- While s2 (timed 1.0s) and s3 (isolated) are partitioned, s1's publish reaches only s1 itself.
			s1:spawn(function() s1.MessagingService:PublishAsync("guild", "during_partition") end)
			w:run(0.5)
			sert.eq(inbox1, { "during_partition" })
			sert.eq(inbox2, {})
			sert.eq(inbox3, {})

			-- Advance past 1.0s: s2's timed partition expires automatically while s3 stays isolated until `w:heal()`.
			w:run(0.7)
			sert.eq(w:isolated(s2), false)
			sert.eq(w:isolated(s3), true)
			s1:spawn(function() s1.MessagingService:PublishAsync("guild", "after_s2_expiry") end)
			w:run(0.3)
			sert.eq(inbox2, { "after_s2_expiry" })
			sert.eq(inbox3, {})

			w:heal()
			sert.eq(w:isolated(s3), false)
			s1:spawn(function() s1.MessagingService:PublishAsync("guild", "after_heal") end)
			w:run(0.3)
			sert.eq(inbox3, { "after_heal" })

			-- MessagingService `duplicate`, `drop`, and `subscribe` fault injection.
			w.mode = "random"
			w.faults.duplicate = 1.0
			s1:spawn(function() s1.MessagingService:PublishAsync("guild", "dup_msg") end)
			w:run(0.3)
			sert.eq(inbox3, { "after_heal", "dup_msg", "dup_msg" })

			w.faults.duplicate = 0
			w.faults.drop = 1.0
			s1:spawn(function() s1.MessagingService:PublishAsync("guild", "dropped_msg") end)
			w:run(0.3)
			sert.eq(#inbox3, 3)

			w.faults.subscribe = 1.0
			local subErr: any = nil
			s1:spawn(function()
				local ok, err = pcall(function()
					s1.MessagingService:SubscribeAsync("other", function() end)
				end)
				if not ok then subErr = err end
			end)
			w:run(0.3)
			sert.ok(subErr ~= nil)
			sert.contains(tostring(subErr), "SubscribeAsync")
		end
	)

	test(
		"UnreliableRemoteEvent drops under unreliable/oversize faults while reliable RemoteEvent preserves FIFO when healed",
		function()
			local w = Sim.new({
				seed = 63,
				mode = "random",
				faults = {
					drop = 1.0, -- drops UnreliableRemoteEvent ONLY, never reliable RemoteEvent
					remoteDropRate = 0,
					remoteReorderRate = 0,
					remoteLatencyRange = { 0.01, 0.09 },
				},
			})
			local srv = w:server()
			local cli = srv:client(501)
			local sNet = w:remotes(srv)
			local cNet = sNet:forClient(cli)

			local sRel = sNet:event("ReliableSeq")
			local cRel = cNet:event("ReliableSeq")
			local sUnrel = sNet:unreliable("UnreliableTick")
			local cUnrel = cNet:unreliable("UnreliableTick")

			local relLog: { number } = {}
			local unrelCount = 0
			sRel.OnServerEvent:Connect(function(_plr: any, seq: number) table.insert(relLog, seq) end)
			sUnrel.OnServerEvent:Connect(function()
				unrelCount += 1
			end)

			for seq = 1, 6 do
				cUnrel:FireServer(seq)
				cRel:FireServer(seq)
			end
			w:run(0.5)
			sert.eq(unrelCount, 0)
			sert.eq(#relLog, 6)

			-- Oversize >900B UnreliableRemoteEvent payload drops even when `drop = 0`.
			w.faults.drop = 0
			cUnrel:FireServer(string.rep("x", 950))
			cUnrel:FireServer("small")
			w:run(0.5)
			sert.eq(unrelCount, 1)

			-- Inject reorder fault, then heal (`mode = "manual"`, `remoteReorderRate = 0`, fixed latency) and verify strict FIFO.
			table.clear(relLog)
			w.faults.remoteReorderRate = 1.0
			cRel:FireServer(10)
			cRel:FireServer(20)
			w:run(0.5)
			sert.eq(#relLog, 2)

			table.clear(relLog)
			w.mode = "manual"
			w.scheduler.random = false
			w.faults.remoteReorderRate = 0
			w.faults.remoteLatencyRange = { 0.02, 0.02 }
			for seq = 101, 105 do
				cRel:FireServer(seq)
			end
			w:run(0.2)
			sert.eq(relLog, { 101, 102, 103, 104, 105 })

			-- Handler exception records into `w.remoteErrors` and fails `w:assertNoRemoteErrors`.
			local sBad = sNet:event("BrokenHandler")
			local cBad = cNet:event("BrokenHandler")
			sBad.OnServerEvent:Connect(function() error("bad remote payload", 0) end)
			cBad:FireServer("boom")
			w:run(0.2)
			sert.throws(function() w:assertNoRemoteErrors("expected handler failure") end, "bad remote payload")
		end
	)

	test(
		"RemoteFunction errors under packet drop or mid-flight disconnect, and client reconnect restores session",
		function()
			local w = Sim.new({
				seed = 77,
				mode = "random",
				faults = {
					remoteDropRate = 0,
					remoteLatencyRange = { 0.02, 0.02 },
				},
			})
			local srv = w:server()
			local sEnv = srv:env()
			local removedUsers: { number } = {}
			local addedUsers: { number } = {}
			srv.Players.PlayerAdded:Connect(function(plr: any) table.insert(addedUsers, plr.UserId) end)
			srv.Players.PlayerRemoving:Connect(function(plr: any) table.insert(removedUsers, plr.UserId) end)

			local cli1 = srv:client(707)
			local c1Env = cli1:env()
			local sNet = w:remotes(srv)
			local c1Net = sNet:forClient(cli1)
			local sRpc = sNet:func("TradeRpc")
			local c1Rpc = c1Net:func("TradeRpc")

			sRpc.OnServerInvoke = function(_plr: any, op: string): string
				if op == "slow" then w:sleep(0.5) end
				return `ack:{op}`
			end
			c1Rpc.OnClientInvoke = function(op: string): string
				if op == "slow_client" then w:sleep(0.5) end
				return `client_ack:{op}`
			end

			-- 1) Packet loss on `RemoteFunction` fails with `connection lost`.
			w.faults.remoteDropRate = 1.0
			local dropErr: any = nil
			cli1:spawn(function()
				local ok, err = pcall(function() return c1Rpc:InvokeServer("ping") end)
				if not ok then dropErr = err end
			end)
			w:run(0.2)
			sert.contains(tostring(dropErr), "connection lost")
			w.faults.remoteDropRate = 0

			-- 2) Reply-leg packet drop mid-RPC throws `connection lost before reply`, and `cli1:disconnect()` cleans up session.
			local midRpcDropErr: any = nil
			cli1:spawn(function()
				local ok, err = pcall(function() return c1Rpc:InvokeServer("slow") end)
				if not ok then midRpcDropErr = err end
			end)
			w:run(0.1)
			w.faults.remoteDropRate = 1.0
			w:run(0.6)
			sert.contains(tostring(midRpcDropErr), "connection lost before reply")
			w.faults.remoteDropRate = 0

			cli1:disconnect()
			w:run(0.1)
			sert.eq(removedUsers, { 707 })
			sert.eq(#sEnv.Players:GetChildren(), 0)
			local _ = c1Env

			-- Disconnected player rejects `InvokeClient` and `InvokeServer`.
			local deadSrvInvoke: any = nil
			srv:spawn(function()
				local ok, err = pcall(function() return sRpc:InvokeClient(707, "poke") end)
				if not ok then deadSrvInvoke = err end
			end)
			local deadCliInvoke: any = nil
			local okDeadCli, errDeadCli = pcall(function() return c1Rpc:InvokeServer("after_leave") end)
			if not okDeadCli then deadCliInvoke = errDeadCli end
			w:run(0.2)
			sert.contains(tostring(deadSrvInvoke), "not connected")
			sert.contains(tostring(deadCliInvoke), "sender disconnected")

			-- 3) Reconnecting user 707 via a new client session restores `Players`, replication, and bidirectional RPC!
			local marker = sEnv.Instance.new("IntValue")
			marker.Name = "SessionEpoch"
			marker.Value = 2
			marker.Parent = sEnv:getService("ReplicatedStorage")

			local cli2 = srv:client(707)
			local c2Env = cli2:env()
			local c2Rpc = sNet:forClient(cli2):func("TradeRpc")
			c2Rpc.OnClientInvoke = function(v: number): number return v * 3 end
			w:run(0.05)

			sert.eq(addedUsers, { 707, 707 })
			local cMarker = c2Env:getService("ReplicatedStorage"):FindFirstChild("SessionEpoch") :: any
			sert.eq(cMarker.Value, 2)

			local sReply: string? = nil
			local cReply: number? = nil
			cli2:spawn(function() sReply = c2Rpc:InvokeServer("fast") end)
			srv:spawn(function() cReply = sRpc:InvokeClient(cli2.player, 14) end)
			w:run(0.3)
			sert.eq(sReply, "ack:fast")
			sert.eq(cReply, 42)
		end
	)

	test(
		"DataStore and MemoryStore enforce simulated latency, transient before/after/budget/evict faults, and hold gates",
		function()
			local w = Sim.new({ seed = 88 })
			w:setLatency("DataStore", 0.15)
			w:setLatency("MemoryStore", 0.10)
			local srv = w:server()
			local ds = srv.DataStoreService:GetDataStore("Profiles")
			local map = srv.MemoryStoreService:GetSortedMap("ActiveLocks")

			-- Simulated latency advances `w:now()`, and transient `before` / `after` faults recover cleanly on retry.
			w:fail("DataStoreService", "GetAsync", "before", "503 transient read failure")
			w:fail("DataStore", "SetAsync", "after", "lost SetAsync ACK after commit")

			local t0 = w:now()
			local firstReadErr: any = nil
			local lostAckErr: any = nil
			local committedVal: any = nil
			srv:spawn(function()
				local okR, errR = pcall(function() return ds:GetAsync("p1") end)
				if not okR then firstReadErr = errR end

				local okW, errW = pcall(function() return ds:SetAsync("p1", { gold = 250 }) end)
				if not okW then lostAckErr = errW end

				-- Backing store committed despite `after` ACK loss; fresh uncached read sees `{ gold = 250 }`.
				committedVal = (ds:GetAsync("p1", { UseCache = false }))
			end)
			w:run(1.0)

			sert.ge(w:now() - t0, 0.44)
			sert.contains(tostring(firstReadErr), "503 transient read failure")
			sert.contains(tostring(lostAckErr), "lost SetAsync ACK after commit")
			sert.eq(committedVal, { gold = 250 })

			-- Simulated DataStore budget throttle fault (`faults.budget = 1.0`).
			w.mode = "random"
			w.faults.budget = 1.0
			local throttleErr: any = nil
			srv:spawn(function()
				local okT, errT = pcall(function() return ds:IncrementAsync("counter", 1) end)
				if not okT then throttleErr = errT end
			end)
			w:run(0.5)
			sert.contains(tostring(throttleErr), "throttled (simulated budget fault on IncrementAsync)")
			w.faults.budget = 0

			-- MemoryStore transient `before` fault + retry, followed by `evict = 1.0` eviction on `GetAsync`.
			w:fail("MemoryStoreService", "UpdateAsync", "before", "MemoryStore transient throttle")
			local msTransientErr: any = nil
			local updatedLock: any = nil
			local postEvictVal: any = "unset"
			srv:spawn(function()
				local okU, errU = pcall(function()
					return map:UpdateAsync("k1", function() return "owner_a", 10 end, 60)
				end)
				if not okU then msTransientErr = errU end

				updatedLock = (map:UpdateAsync("k1", function() return "owner_a", 10 end, 60))
				w.faults.evict = 1.0
				postEvictVal = (map:GetAsync("k1"))
			end)
			w:run(1.0)
			sert.contains(tostring(msTransientErr), "MemoryStore transient throttle")
			sert.eq(updatedLock, "owner_a")
			sert.eq(postEvictVal, nil)
			w.faults.evict = 0

			-- `w:hold` barrier gate parks concurrent `w:call` invocations and releases them deterministically.
			local gate = w:hold("CustomSvc", "SyncOp")
			local order: { string } = {}
			srv:spawn(function()
				w:call(srv, "CustomSvc", "SyncOp", function() table.insert(order, "op1") end)
			end)
			srv:spawn(function()
				w:call(srv, "CustomSvc", "SyncOp", function() table.insert(order, "op2") end)
			end)
			w:run(0.05)
			sert.eq(gate.calls, 2)
			sert.eq(order, {})
			gate:release(1)
			w:run(0.05)
			sert.eq(#order, 1)
			gate:release()
			w:converge()
			sert.eq(#order, 2)
		end
	)

	test(
		"covers sim HttpService mocks, MemoryStoreSortedMap UpdateAsync retransform/RemoveAsync/GetSizeAsync, and replicated Instance remote args",
		function()
			local w = sert.sim.new({
				seed = 77,
				faults = { retransform = 1 },
			})
			local s1 = w:server()
			local c1 = s1:client(301, { name = "SimPeer" })
			local sEnv = s1:env()
			local cEnv = c1:env()

			-- Sim HttpService GUID, JSON, UrlEncode, and string/function mock handlers
			local http = s1.HttpService
			sert.eq(#http:GenerateGUID(false), 36)
			sert.eq(#http:GenerateGUID(true), 38)
			sert.eq(http:UrlEncode("a b+c"), "a%20b%2Bc")
			sert.eq(http:JSONDecode(http:JSONEncode({ k = 5 })), { k = 5 })
			w.http:mock("/items", function(_req: any) return '{"items":[1,2]}' end)
			w.http:mock(
				function(req: any) return req.Method == "POST" end,
				function(req: any) return { StatusCode = 201, Body = req.Body } end
			)
			local getResp = ""
			local postStatus = 0
			local postBody = ""
			s1:spawn(function()
				getResp = http:GetAsync("https://api.test/items")
				local r = http:RequestAsync({ Url = "https://api.test/create", Method = "POST", Body = "created" })
				postStatus = r.StatusCode
				postBody = r.Body
			end)
			w:converge()
			sert.eq(http:JSONDecode(getResp), { items = { 1, 2 } })
			sert.eq(postStatus, 201)
			sert.eq(postBody, "created")

			-- Sim MemoryStore SortedMap + HashMap UpdateAsync (with retransform = 1), GetSizeAsync, RemoveAsync
			local ms = s1.MemoryStoreService
			local sm = ms:GetSortedMap("Leaderboard")
			local hm = ms:GetHashMap("LobbyState")
			local smCalls = 0
			local val: any, sk: any = nil, nil
			local smSize1, smSize2 = -1, -1
			local hmCalls = 0
			local hVal: any = nil
			s1:spawn(function()
				val, sk = sm:UpdateAsync("p301", function(cur: any, _curSk: any)
					smCalls += 1
					return (cur or 0) + 100, 100
				end, 60)
				smSize1 = sm:GetSizeAsync()
				sm:RemoveAsync("p301")
				smSize2 = sm:GetSizeAsync()

				hVal = hm:UpdateAsync("room1", function(cur: any)
					hmCalls += 1
					return (cur or 0) + 1
				end, 60)
				hm:RemoveAsync("room1")
			end)
			w:converge()
			sert.eq(val, 100)
			sert.eq(sk, 100)
			sert.ge(smCalls, 2)
			sert.eq(smSize1, 1)
			sert.eq(smSize2, 0)
			sert.eq(hVal, 1)
			sert.ge(hmCalls, 2)

			-- Replicated Instance arguments across RemoteEvent (Workspace, ReplicatedStorage, Players)
			local targetPart = sEnv.Instance.new("Part")
			targetPart.Name = "ArenaTarget"
			targetPart.Parent = sEnv.Workspace
			local rsItem = sEnv.Instance.new("Folder")
			rsItem.Name = "SharedBadge"
			rsItem.Parent = sEnv.ReplicatedStorage
			local pingRemote = sEnv.Instance.new("RemoteEvent")
			pingRemote.Name = "InspectInstances"
			pingRemote.Parent = sEnv.ReplicatedStorage
			w:advance(0.05)

			local receivedOnServer: { string } = {}
			pingRemote.OnServerEvent:Connect(
				function(_plr: any, p: any, r: any, pl: any)
					table.insert(
						receivedOnServer,
						`{tostring(p and p.Name)}:{tostring(r and r.Name)}:{tostring(pl and pl.Name)}`
					)
				end
			)
			local receivedOnClient: { string } = {}
			local cPing = cEnv.ReplicatedStorage:FindFirstChild("InspectInstances") :: any
			cPing.OnClientEvent:Connect(
				function(p: any, r: any, pl: any)
					table.insert(
						receivedOnClient,
						`{tostring(p and p.Name)}:{tostring(r and r.Name)}:{tostring(pl and pl.Name)}`
					)
				end
			)

			local cPart = cEnv.Workspace:FindFirstChild("ArenaTarget")
			local cRsItem = cEnv.ReplicatedStorage:FindFirstChild("SharedBadge")
			cPing:FireServer(cPart, cRsItem, cEnv.LocalPlayer)
			pingRemote:FireClient(
				sEnv.Players:GetPlayerByUserId(301),
				targetPart,
				rsItem,
				sEnv.Players:GetPlayerByUserId(301)
			)
			w:converge()

			sert.eq(receivedOnServer, { "ArenaTarget:SharedBadge:SimPeer" })
			sert.eq(receivedOnClient, { "ArenaTarget:SharedBadge:SimPeer" })

			-- Server:restart replaces active fleet slot and chains repeat restart calls cleanly
			local restarted1 = s1:restart()
			sert.eq(s1.state, "crashed")
			sert.eq(restarted1.state, "up")
			sert.eq(restarted1.restarts, 1)
			local restarted2 = s1:restart()
			sert.eq(restarted2.restarts, 2)
			sert.eq(restarted1.state, "crashed")
		end
	)
end)
