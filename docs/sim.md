# The simulation kernel (`sert.sim`)

`require("@sert/sim")` (or `sert.sim`) is a deterministic multi-server simulator. It runs multiple servers and clients on a virtual-time scheduler where every scheduling, latency, and fault decision is a tracked choice. Peers share `DataStore`, `MemoryStore`, `MessagingService`, and remote channels so you can find race conditions with property, stateful model, and exhaustive exploration tests.

```luau
local sert = require("@sert")
local Sim = require("@sert/sim")

local function visit(env)
	local store = env.game:GetService("DataStoreService"):GetDataStore("counters")
	store:UpdateAsync("visits", function(n)
		return (n or 0) + 1
	end)
end

Sim.prop("two servers count two visits", function(world)
	local a, b = world:server(), world:server()
	a:spawn(visit, a:env())
	b:spawn(visit, b:env())
	world:converge()
	sert.eq(world.datastore.mock:GetDataStore("counters").data.visits.value, 2)
end, { runs = 100, world = { faults = "none" } })

return {}
```

## The test body does not yield

The callback you pass to `Sim.prop`, `Sim.model`, or `Sim.explore` runs on the outer test thread. Calling a yielding service method (`GetAsync`, `Signal:Wait`, remotes, or `world:hold`) directly on the test thread throws an error immediately (`task.wait(s)` is the only exception and advances the world by `s` seconds).

Instead, follow these three steps:
1. Spawn work on a peer with `server:spawn(fn, ...)` or `client:spawn(fn, ...)`.
2. Advance virtual time with `world:step`, `world:run`, `world:runUntil`, or `world:converge`.
3. Inspect results on `world.datastore.mock`, `world.memory`, `world.messaging.history`, `world.kicks`, or local variables updated by your spawned threads.

## Exports and types

| Export | Description |
| --- | --- |
| `Sim.World`, `Sim.new`, `Sim.summary` | Fleet constructor `World.new(options?)`, `World.extend(methods)`, and `World.summary`. |
| `Sim.Scheduler` | Virtual-time scheduler and choosers (`seeded`, `replay`, `fromGen`, `record`). |
| `Sim.Runner` | Standalone workload runner (`run`, `shrink`, `explore`, `replay`, `ops`, `literal`, `describe`, `find`, `headline`). |
| `Sim.Explore` | Exhaustive choice-tree explorer (`Explore.run(body, limits?)`). |
| `Sim.Coop`, `Sim.Config`, `Sim.configure(opts)` | Instant-wait hooks and kernel dependency injection. |
| `Sim.Rng`, `Sim.Hash`, `Sim.DataStore`, `Sim.services` | `@sert/rng`, `{ fnv1a32 }`, `DataStore` double, and per-server service facades. |
| `Sim.Spec`, `Sim.spec`, `Sim.checkSpec` | TLA+-style state specifications (`init`, `actions`, `never`, `invariants`, `project`), standalone BFS model checking (`spec:check`), trace refinement (`spec:verifyTrace`), and TLA+ JSON trace export (`spec:toTlaJson`). |
| `Sim.vopr`, `Sim.prop`, `Sim.model`, `Sim.explore` | Test registration helpers (register at top level, or run immediately inside an active test). |

Exported types: `World`, `Server`, `Client`, `Faults`, `WorldOptions`, `Scheduler`, `Chooser`, `Choice`, `HostHooks`, `SchedulerOptions`, `SchedulerFailure`, `Op`, `Ctx`, `Workload`, `RunFailure`, `RunOptions`, `RunnerOptions`, `Result`, `ShrinkLimits`, `ShrinkResult`, `ExploreLimits`, `ExploreResult`, `ExplorerLimits`, `ExplorerFailure`, `ExplorerOutcome`, `ModelSpec`, `ModelCommand`, `Options`, `Config`, `Backing`, `Rng`, `Spec`, `SpecDef`, `ActionSpec`, `TraceEntry`, `SpecCheckOptions`, `SpecCheckResult`.

## Scheduler

`Sim.Scheduler` models the Roblox task scheduler (`spawn` runs immediately, `defer` runs FIFO up to depth `80`, `wait(d)` wakes at the first frame `>= now + d`, and frame hooks drive `Heartbeat`).
- **Manual mode** (`World.new` default) uses fixed `0.1` s frames, FIFO ordering, and no random choices.
- **Random mode** (`Sim.prop`, `model`, and `explore` default) varies frame lengths (`1/60..0.25` s with a 2% chance of a `1` s hitch) and chooses timer and hook wakeup order.
- **Choosers:** `Scheduler.seeded(seed)`, `Scheduler.replay(list)`, `Scheduler.fromGen(g, { note? })`, and `Scheduler.record(inner)`.

| Group | Methods |
| --- | --- |
| **Choices and RNG** | `s:choose(n, label?, weights?) -> number`, `s:chance(p, label?) -> boolean`, `s:pick(list, label?, weights?) -> T`, `s:stream(name) -> Rng`. |
| **Coroutines and timers** | `s:spawn(owner, fn, ...) -> thread`, `s:defer(owner, fn, ...) -> thread`, `s:wait(seconds?) -> number`, `s:after(seconds, owner, fn, ...) -> Timer`, `s:park() -> ...any`, `s:resume(thread, ...)`, `s:cancel(thread)`, `s:onFrame(fn, owner?) -> () -> ()`, `s:host(owner) -> HostHooks`. |
| **Stepping and lifecycle** | `s:drain()`, `s:frame(dt?) -> number`, `s:runFor(seconds)`, `s:runUntil(target, limit?) -> boolean`, `s:wakeDue()`, `s:crash(owner)`, `s:crashed(owner) -> boolean`. |
| **Inspection** | `s:idle() -> boolean`, `s:running() -> boolean`, `s:owns(thread) -> boolean`, `s:trace(text)`, `s:digest() -> number`. |

## World, servers, and services

### `Sim.World.new(options?)`

| Option | Default | Description |
| --- | --- | --- |
| `mode` | `"manual"` | `"manual"` (fixed-step FIFO) or `"random"` (chosen latencies, faults, clock skew, and wakeup order). |
| `seed`, `frame`, `scheduler` | `1`, `0.1`, new | Base RNG seed, fixed frame duration in seconds, or an existing `Scheduler`. |
| `faults` | `"none"` (random: chosen) | `"none"`, `"light"`, `"heavy"`, `"vopr"`, or `{ profile?, before?, after?, late?, retransform?, stale?, drift?, crash?, evict?, subscribe?, drop?, duplicate?, budget? }`. |
| `swarm` | `true` on `"vopr"` | Draws a per-run swarm fault matrix from the generator tape so each run stresses a distinct subset of fault rates and shrinks active faults toward `0`. |
| `autoRestart` | `true` on `"vopr"` | Automatically restarts a server into a new incarnation (`s{slot}.{restarts}`) when `faults.crash` triggers. |
| `wait` | `"yield"` | `"yield"` parks coroutines across frames. `"instant"` advances the clock synchronously on waits (`world.coop`). |
| `backing`, `datastore` | `true`, `{}` | Shared `DataStore` double (`false` gives each server an isolated store, or pass `{ new, copy? }` for a custom store) and store options. |
| `messaging` | `{}` | Pass `{ json = true }` to round-trip `MessagingService` payloads through JSON. |
| `latency` | `{}` | Fixed latency overrides in seconds by service or kind (`"DataStoreService"`, `"MemoryStoreService"`, `"MessagingService"`, `"delivery"`, `"remotes"`). |
| `coarse` | `false` | Uses two latency levels (`fast` / `slow`) and coalesced server frame hooks to keep `Sim.explore` trees small. |
| `placeId` | `1` | Sets `game.PlaceId` on every server and client environment. |

### Servers and clients

`world:server({ jobId?, skew?, build?, slot?, restarts? })` creates a simulated server with its own `JobId` prefix, clock skew (`os.time` and `workspace:GetServerTimeNow`), and service facades. Changes under `ReplicatedStorage`, `Workspace`, and `Players` replicate automatically to connected clients, and remote events/functions copy arguments and translate `Instance` references across environments.

| Target | Method | Description |
| --- | --- | --- |
| **Server** | `server:env(opts?) -> Env` | Creates or returns the server's `sert.env`. |
| | `server:spawn(fn, ...) -> thread` | Binds `fn` to the server's `_ENV` and spawns it under the server's ownership. |
| | `server:join(userId) -> Player` | Adds a player (`Players.PlayerAdded`) and returns the server `Player`. |
| | `server:leave(userIdOrPlayer)` | Removes the player and fires `Players.PlayerRemoving`. |
| | `server:client(userId) -> Client` | Creates or returns a connected client peer for `userId`. |
| | `server:crash()` | Crashes immediately, dropping owned threads and in-flight replies and skipping `BindToClose`. |
| | `server:shutdown(deadline?)` | Shuts down gracefully, firing `PlayerRemoving` and `BindToClose` (default `deadline` is `30` s). |
| | `server:restart() -> Server` | Starts a replacement server in the same slot with `restarts + 1`. |
| **Client** | `client:env() -> Env` | Returns the client's `sert.env` (`isClient = true`, `Players.LocalPlayer`). |
| | `client:spawn(fn, ...) -> thread` | Binds `fn` to the client's `_ENV` and spawns it under the client's ownership. |
| | `client:leave()` | Disconnects the client and removes its player from the server. |

### World methods and fault injection

```luau
sert.test("handles a lost UpdateAsync reply without double-applying", function()
	local world = Sim.World.new({ mode = "manual" })
	local s = world:server()
	world:fail("DataStoreService", "UpdateAsync", "after", "simulated timeout after commit")

	local ok, err = false, nil
	s:spawn(function()
		local store = game:GetService("DataStoreService"):GetDataStore("bank")
		ok, err = pcall(function()
			store:UpdateAsync("coins", function(v)
				return (v or 0) + 50
			end)
		end)
	end)

	world:converge()
	sert.eq(ok, false)
	sert.contains(err, "simulated timeout after commit")
	-- "after" fails the caller after the write commits to the backing store:
	sert.eq(world.datastore.mock:GetDataStore("bank").data.coins.value, 50)
end)
```

| Category | Method / Field | Description |
| --- | --- | --- |
| **Time** | `world:step(dt?) -> number` | Steps one frame. |
| | `world:run(seconds)` | Steps frames across `seconds` of virtual time. |
| | `world:runUntil(target, limit?) -> boolean` | Steps until timestamp `target` or predicate `target()` holds (within `limit` s). |
| | `world:converge(project?, options?)` | Heals partitions, releases gates, disables faults, delivers pending messages, advances virtual time (`seconds = 10`, or until `project(server)` agrees across live servers within `timeout = 15`), checks `assertNoErrors` (unless `allowErrors`), and runs `invariant(world)`. |
| **Faults and gates** | `world:hold(service, method) -> Gate` | Parks calls to `service` (`"DataStoreService"`, `"MemoryStoreService"`, `"MessagingService"`) at a gate until `gate:release(n?)`. `gate:waiting()` lists parked calls. |
| | `world:fail(service, method, when, msg?)` | Injects fault `when` (`"before"`, `"after"`, `"late"`, `"retransform"`, `"stale"`, `"drift"`, `"crash"`, or `"evict"`) on the next matching call. |
| | `world:onServerEvent(name, fn)`, `world:onClientEvent(peerId, name, fn)` | Registers simulated remote handlers on the world remote bus. |
| | `world:fireServer(peerId, name, ...)`, `world:fireClient(peerId, name, ...)`, `world:fireAllClients(name, ...)`, `world:flushRemotes()` | Sends packets across the simulated remote bus with configurable `remoteDropRate`, `remoteReorderRate`, `remoteDuplicateRate`, and `remoteLatencyRange` faults. |
| | `world:detach(delay, fn)` | Schedules `fn()` on the cloud/network timeline (`owner = nil`) after `delay` seconds so it survives `server:crash()`. |
| | `world:partition(server, seconds)` | Isolates `server` from `MessagingService` for `seconds` of virtual time. |
| | `world:isolate(server)`, `world:heal()`, `world:isolated(server)` | Isolates `server` indefinitely, heals all partitions, or checks whether `server` is partitioned. |
| | `world.memory:evict(name?, key?)`, `world.memory:flush()` | Evicts a key or queue item from `MemoryStore` before its TTL expires, or wipes all volatile maps and queues. |
| | `server:drift(delta)`, `client:drift(delta)` | Shifts a peer's clock skew by `delta` seconds mid-run. |
| **Inspection** | `world:assertNoErrors(label?)` | Throws if any peer or service recorded an unhandled error. |
| | `world:onCommit(fn)`, `world:onFrame(fn)` | Registers a listener called after each committed service operation or after each frame. |
| | `world:action(name, arg?, state?, res?)`, `world:tlaTrace(name?)` | Records a state-machine transition in `world.actions` or exports a TLA+ JSON trace. |
| | `world:summary(maxEntries?) -> string`, `world:trace(text)`, `world:digest() -> number` | Formats a trace summary (including active swarm fault rates), appends a custom trace entry, or computes an FNV-1a state digest. |
| | `world.datastore.mock`, `world.memory`, `world.messaging`, `world.kicks`, `world.servers` | Backing service state, `messaging.history` / `.pending`, recorded player kicks, and the server list. |

### The 7 VOPR distributed hazards (`faults = "vopr"`)

When `faults = "vopr"` is active (the default in `Sim.vopr`), the simulator draws a per-run swarm fault matrix from the generator tape across all seven distributed failure modes:

1. **Writes that land and lose their reply (`after`)**: The mutation commits to `DataStore` or `MemoryStore`, and the caller gets a connection error.
2. **Writes that land late, after the server that sent them is gone (`late`)**: In-flight mutations detach onto the cloud timeline (`owner = nil`). If the caller times out or `server:crash()` kills the server mid-request, the write still lands after a tail delay.
3. **Transforms that run again after their call already answered (`retransform`)**: `UpdateAsync` re-runs its transform callback (both as a pre-answer retry and as a detached post-answer execution), catching non-idempotent transforms.
4. **Reads that give back old data (`stale`)**: `GetAsync` (even with `{ UseCache = false }`), `GetSortedAsync`, `ListKeysAsync`, and `MemoryStore` reads (`GetAsync`, `GetRangeAsync`) can return a prior snapshot from the per-key version ring buffer.
5. **Clocks that are off from each other (`drift`)**: Servers and clients start with clock skew, draw fresh skew on `server:restart()`, and jump forward or backward mid-run (`server:drift(delta)`).
6. **Servers that crash between any two steps (`crash`)**: Live servers crash (and restart into a new incarnation when `autoRestart` is enabled) at yield boundaries and between model steps.
7. **MemoryStore losing things whenever it feels like it (`evict`)**: `MemoryStore` maps and queues spontaneously evict keys or queued items before their TTL expires.

## Spec-first workflow with `Sim.spec`, `Sim.checkSpec`, and `Sim.vopr`

To verify distributed logic before writing service code, define a pure state machine with `Sim.spec` and write negative invariants (`never` — states that must never happen) first:

```luau
local FencedSessionSpec = Sim.spec({
	name = "FencedSession",
	init = function()
		return { token = 0, savedToken = 0 }, { token = 0, savedToken = 0 }
	end,
	project = function(sut)
		return { token = sut.token, savedToken = sut.savedToken }
	end,
	actions = {
		save = {
			gen = function(g) return g:int(1, 3) end,
			guard = function(st) return st.token < 20 end,
			next = function(st)
				st.token += 1
				st.savedToken = st.token
			end,
			run = function(sut, _arg, world)
				local srv = world.servers[1] or world:server()
				if srv.state ~= "up" then srv = srv:restart() end
				sut.token += 1
				local myToken = sut.token
				srv:spawn(function()
					pcall(function()
						srv.host.DataStoreService:GetDataStore("Saves"):UpdateAsync("p1", function(old)
							if old ~= nil and old.token > myToken then return nil end
							return { token = myToken }
						end)
					end)
				end)
				world:run(0.5)
				sut.savedToken = myToken
			end,
		},
	},
	never = {
		regression = function(st)
			return st.savedToken > st.token
		end,
	},
})

-- 1. Model-check the pure spec first (BFS state-space exploration):
Sim.checkSpec("fenced session spec", FencedSessionSpec, { maxStates = 100, maxDepth = 8 })

-- 2. Run the Luau SUT under VOPR faults and feed the execution trace back into the spec:
Sim.vopr("fenced session under vopr", FencedSessionSpec, { runs = 40, length = 10 })
```

- **`spec:check(options?)` / `Sim.checkSpec(name?, spec, options?)`** explores reachable states of the pure spec (`init`, `actions`, `never`, `invariants`) via BFS before any Luau service code runs.
- **`Sim.vopr(name?, specOrFn, options?)`** runs `spec` (or a `fn(world, g)` property) with `faults = "vopr"`, checking `never` and `invariants` after every step and `DataStore` commit, and calls `spec:verifyTrace(world.actions)` to confirm that every concrete Luau transition matches the spec.
- **`spec:verifyTrace(trace, initialState?)`** and **`spec:toTlaJson(trace, initialState?)`** validate recorded runs against the spec or export TLA+ JSON traces.

## Testing with `Sim.prop`, `Sim.model`, and `Sim.explore`

All three functions register a test at the top level of a spec or run immediately when called inside a test. `options.world` defaults to `{ mode = "random", faults = "light", frame = 0.1, coarse = true, backing = true, tapeChoices = true }`.

```luau
Sim.explore("lock handoff across every schedule", function(world)
	local a, b = world:server(), world:server()
	local acquired = {}
	for id, srv in { a = a, b = b } do
		srv:spawn(function()
			local map = game:GetService("MemoryStoreService"):GetSortedMap("locks")
			local ok = pcall(function()
				map:UpdateAsync("room-1", function(cur)
					return if cur == nil then id else nil
				end, 30)
			end)
			if ok then
				table.insert(acquired, id)
			end
		end)
	end
	world:converge()
	sert(#acquired >= 1, "at least one server acquires the lock")
end, { maxRuns = 64, world = { faults = "none" } })
```

- **`Sim.prop(name?, fn(world, g), options?)`** runs `runs` (default `50`) cases with scheduler choices drawn from `g`'s tape so generated inputs and fault schedules shrink together.
- **`Sim.model(name?, spec, options?)`** runs stateful command sequences against a `world` (`runs` defaults to `40`, or `25` inline, and `length` defaults to `15`).
  - `spec`: `{ name?, init(world, g) -> (state, sut?), commands, invariant?(state, sut, world), converge?: boolean | (state, sut, world) -> (), teardown?(sut, state, world), world? }`.
  - Command: `{ run(sut, arg, world, state), gen?(g, state), pre?(state, arg), next?(state, arg, res, world), post?(state, sut, arg, res, world), weight? }`.
- **`Sim.explore(name?, fn(world), options?)`** performs a depth-first bounded-exhaustive search of the choice tree. Options include `maxChoices` (`16`), `maxRuns` (`128`), `maxBranch` (`3`), `replay` (`{ 1, 2, ... }` choice path), `allowErrors`, and `world`.

## Standalone workloads and configuration

- **`Sim.Runner`** runs `{ name, steps, gen(rng, n, opts), setup(ctx), apply(ctx, state, op), check?, quiesce?, final?, horizon? }` workloads through `Runner.run`, `Runner.shrink`, `Runner.explore`, and `Runner.replay`. Call `ctx.fail(invariant, detail)` to record a structured failure.
- **`Sim.configure(options)`** sets `hash`, `describeError`, `reporter`, `datastore`, `breath`, and `breathe`.
