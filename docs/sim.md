# Deterministic Multi-Peer Simulation (`sim.md`)

`sert.sim` runs multiple Roblox servers and clients on a single deterministic virtual-time scheduler (`sert.sim.Scheduler`) backed by shared cloud services (`DataStoreService`, `OrderedDataStore`, `MemoryStoreService`, `MessagingService`, `TeleportService`, and `MarketplaceService`). Inspired by FoundationDB's simulation testing and TigerBeetle's VOPR, `sert.sim` injects network drops, packet reordering, stale DataStore reads, rolling 30-second `BindToClose` shutdowns, teleport session-lock races, and duplicate receipt deliveries. Every failure reproduces from a single seed or `{ replay = "v1:..." }` token.

---

## Core API

| Function | Description |
| --- | --- |
| `sert.sim.new(opts?: sert.SimWorldOptions) -> sert.SimWorld` | Creates a deterministic multi-peer simulation `World` for direct imperative tests. |
| `sert.sim.vopr(name, spec: sert.SimSpec<State, Sut>, opts?: sert.SimVoprOptions)` | Registers a shrinking VOPR command-sequence test (supports `.roblox`, `.server`, `.client`, `.skip`, `.focus`). |
| `sert.sim.check(spec, opts?: sert.SimCheckOptions) -> sert.SimCheckResult` | Runs bounded breadth-first state-space exploration (`bfs`) on finite models and/or VOPR execution immediately. |
| `sert.sim.explore(name?, opts?, fn: (world: sert.SimWorld) -> ())` | Exhaustively explores bounded scheduler interleaving choices (`maxChoices`, `maxRuns`, `maxBranch`). |
| `sert.sim.spec(def)` | Validates and types a `SimSpec<State, Sut>` table. |
| `sert.sim.verifyTrace(spec, trace, initialState?)` | Replays a recorded `{ TraceStep }` against pure `pre` / `next` / `invariants` transitions without aliasing caller tables. |
| `sert.sim.toItfJson(spec, trace, initialState?)` | Serializes a trace to Apalache Informal Trace Format (ITF) JSON for TLA+ tooling. |

---

## Unified `Spec<State, Sut>` and VOPR shrinking

`sert.sim.vopr` and `sert.sim.check` share the exact `Spec<State, Sut>` structure used by `sert.model`:

- `init: () -> State` constructs the initial pure reference state for each trial.
- `setup?: (world: sert.SimWorld) -> Sut` boots servers, clients, or services on `world` (defaults `sut` to `world` when omitted).
- `teardown?: (sut: Sut, world: sert.SimWorld) -> ()` runs optional cleanup after each trial.
- `commands: { [string]: SimCommand<State, Sut, Arg, Res> }` defines named operations with `gen?: (state, g) -> Arg` (or finite `args`), `pre?: (state, arg) -> boolean`, `run?: (sut, arg, world) -> Res`, `next: (state, arg, res) -> State?`, `post?: (state, sut, arg, res, world) -> ()`, and `weight?: number`.
- `invariants?: { [string]: (state: State, sut: Sut, world?: sert.SimWorld) -> () }` runs assertions after every step and after `converge` when configured.
- `converge?: boolean | ((state: State, sut: Sut, world: sert.SimWorld) -> ())` heals faults and drains pending cloud and remote work at the end of a trial so eventual-consistency invariants can assert convergence.
- `world?: sert.SimWorldOptions` configures the default world and fault profile for every trial.

```luau
--!strict
local sert = require("@sert")

sert.sim.vopr("session lock survives server handoffs and DataStore faults", {
	init = function()
		return { gold = 100 }
	end,
	setup = function(world)
		world:onServerStart(function(srv)
			local env = srv:env()
			local remotes = Instance.new("Folder")
			remotes.Name = "Remotes"
			remotes.Parent = env.game:GetService("ReplicatedStorage")
			local grant = Instance.new("RemoteEvent")
			grant.Name = "GrantGold"
			grant.Parent = remotes
			grant.OnServerEvent:Connect(function(player, amount: number)
				if type(amount) ~= "number" or amount <= 0 then return end
				local ds = env.game:GetService("DataStoreService"):GetDataStore("Profiles")
				ds:UpdateAsync(`u_{player.UserId}`, function(cur)
					return (cur or 100) + amount
				end)
			end)
		end)
		local s1 = world:server()
		local client = s1:client(42, "Player42")
		world:advance(0.2)
		return { client = client }
	end,
	commands = {
		grant = {
			gen = function(_state, g) return g:int(1, 50) end,
			run = function(sut, amount: number, world)
				local clientEnv = sut.client:env()
				local remote = clientEnv.game:GetService("ReplicatedStorage").Remotes.GrantGold
				remote:FireServer(amount)
				world:advance(0.5)
			end,
			next = function(state, amount: number)
				state.gold += amount
			end,
		},
		hopServer = {
			run = function(sut, _arg, world)
				local dest = world:server()
				world:handoffClient(sut.client, dest)
				world:advance(1.0)
			end,
			next = function() end,
		},
	},
	converge = true,
	invariants = {
		neverCorruptsGold = function(state, _sut, world)
			if world and world:isQuiescent() then
				local entry = world.backing.datastore:GetDataStore("Profiles").data.u_42
				if entry ~= nil then
					sert.le(entry.value, state.gold) -- Dropped remotes may skip grants, never invent gold
				end
			end
		end,
	},
	world = { faults = "light" },
}, { runs = 50 })
```

### Deterministic `{ replay = "v1:..." }` reproduction

When `sert.sim.vopr` finds a bug, it shrinks the command sequence and fault schedule on the byte tape and prints the world event timeline once for the minimal counterexample. It also outputs a self-contained replay token:

```luau
}, { replay = "v1:2948104721:34:0100020f..." })
```

Passing `{ replay = "v1:..." }` in `VoprOptions` executes that exact single shrunk trial right away with zero shrinking overhead. You can also rerun a seed from the CLI via `python3 tools/sert.py run --replay 2948104721`.

---

## Fault profiles, swarm testing, and real `RemoteEvent` faults

Configure `world = { faults = ... }` with a named profile (`"none"`, `"light"`, `"heavy"`, `"vopr"`) or a `SimFaultConfig` table overriding individual rates. When `swarm = true` (enabled automatically by `sert.sim.vopr` unless disabled), each trial samples a distinct combination of fault rates from `SWARM_LEVELS` so rare multi-fault bugs aren't masked by uniform noise.

### Network faults on real `Instance` remotes

`server:env()` and `client:env()` bridge real DataModel instances across peers:

- Server `ReplicatedStorage`, `Workspace`, `Players`, attributes, and `CollectionService` tags replicate to connected clients.
- Firing a real `RemoteEvent`, `UnreliableRemoteEvent`, or `RemoteFunction` routes payloads through `sert`'s boundary serializer and fault fabric:
  - `remoteDropRate` drops packets (`UnreliableRemoteEvent` also drops payloads exceeding 1,000 bytes and applies higher loss under contention).
  - `remoteReorderRate` and `remoteLatencyRange` jitter delivery timestamps so packets arrive out of order.
  - `remoteDuplicateRate` delivers duplicate packets to test handler idempotency.

### Cloud storage and messaging faults

| Fault key | Effect on `DataStore`, `MemoryStore`, and `MessagingService` |
| --- | --- |
| `before` | Raises a transient service error before mutating backing state. |
| `after` | Commits the write to backing storage, then raises an error to the caller so retry logic is tested against already-applied writes. |
| `late` | Delays commit completion behind concurrent operations without polluting the caller's 4-second local DataStore read cache. |
| `retransform` | Invokes `UpdateAsync` transform callbacks multiple times under simulated contention. |
| `stale` | Serves deep-copied historical snapshots on reads. |
| `drift` | Skews an individual server's `os.time()` / `workspace:GetServerTimeNow()` clock (`server:drift(delta)`). |
| `evict` | Evicts ephemeral `MemoryStore` keys or expires queue invisibility leases early. |
| `drop` / `duplicate` / `subscribe` | Drops, duplicates, or fails `MessagingService:PublishAsync` / `SubscribeAsync` deliveries. |
| `budget` | Caps per-minute DataStore request budgets to trigger throttling errors. |

Use `world:partition(server, seconds)`, `world:isolate(server)`, and `world:heal()` to inject deterministic network splits between servers.

---

## Distributed Roblox hazards

`sert.sim` models three multi-server failure modes that single-server tests cannot exercise:

1. **Teleport session-lock races (`teleportRaceRate` and `world:handoffClient`):** When a player teleports via `TeleportService:TeleportAsync(placeId, { player })` or `world:handoffClient(client, destServer)`, the destination server's `Players.PlayerAdded` can fire *before* the source server finishes `Players.PlayerRemoving` and releases its DataStore session lock.
2. **Rolling 30-second `BindToClose` shutdowns (`rollingShutdownRate` and `server:shutdown`):** Servers shut down mid-traffic, running `game:BindToClose` handlers against a strict 30-second virtual deadline (`CLOSE_SECONDS = 30`) while detaching in-flight cloud writes that already left the process. `server:crash()` models an abrupt kill where `BindToClose` never runs at all.
3. **Duplicate `ProcessReceipt` delivery (`receiptDuplicateRate` and `world:purchaseProduct`):** If `MarketplaceService.ProcessReceipt` yields, throws, crashes, or returns `Enum.ProductPurchaseDecision.NotProcessedYet` (or if `receiptDuplicateRate` triggers after a lost acknowledgment), `sert.sim` redelivers the exact same `PurchaseId` on rejoin or on another server—verifying that receipt handlers grant currency at most once.
