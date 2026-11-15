# sert

[![CI](https://img.shields.io/github/actions/workflow/status/kohltastrophe/sert/ci.yml?style=for-the-badge)](https://github.com/kohltastrophe/sert/actions/workflows/ci.yml) [![Coverage](https://img.shields.io/endpoint?url=https://raw.githubusercontent.com/kohltastrophe/sert/badges/coverage.json&style=for-the-badge)](https://github.com/kohltastrophe/sert/actions/workflows/ci.yml) [![License](https://img.shields.io/github/license/kohltastrophe/sert?style=for-the-badge)](LICENSE.txt) [![GitHub Release](https://img.shields.io/github/v/release/kohltastrophe/sert?style=for-the-badge)](https://github.com/kohltastrophe/sert/releases)

Testing, property shrinking, deterministic simulation, and Studio verification for Luau and Roblox. Write unit tests, shrinking properties, headless DataModel specs, and multi-server fault simulations that run across standalone Luau, Roblox Studio, and Open Cloud.

`sert` combines procedural assertions, canonical inline and `.snap` snapshots, allocation checks (`sert.noAllocs`, `sert.bench`), and auto-restoring spies with byte-tape property shrinking (`sert.prop`, `sert.gen`), algebraic/metamorphic/complexity laws (`sert.laws`), and stateful model checking (`sert.model`). Headless `sert.env.new()` simulates `Instance` trees, 3D spatial casts, `InputAction`s, `SharedTable`/`Actor` guards, Audio routing, UI layouts, deferred signals, DataStores, and MemoryStores on a virtual clock. `sert.sim` schedules multiple servers and clients with VOPR fault injection, exact bounded `explore` (with opt-in `stateHash` pruning), and concurrent linearizability verification (`sert.sim.linearizable`). For real Roblox engines and automated workflows, `sert studio` (with `--warm` bridge attachment), `sert cloud`, `sert.roblox.conformance`, greybox `sert fuzz` (persisting `test/.sert-regressions.toml`), zero-config `sert mutate`, `sert audit`, and `sert check --changed --agent` form one closed-loop verification harness.

```luau
--!strict
local sert = require("@sert")

sert.test("matches nested tables", function()
	local event = { kind = "purchase", receipt = "rcpt_42", total = 19.99 }
	sert.eq(event, sert.subset({
		receipt = sert.matching("^rcpt_%d+$"),
		total = sert.within(20.0, 0.05),
	}))
end)

sert.prop("string.rep multiplies length", function(g)
	local text = g:draw(sert.gen.string())
	local count = g:int(0, 20)
	sert.eq(#string.rep(text, count), #text * count)
end)
```

## Quickstart

`sert` requires Python 3.11 or newer and [Rokit](https://github.com/rojo-rbx/rokit) to manage `luau`, `rojo`, `selene`, `StyLua`, and `luau-lsp`.

```sh
curl -fsSL --create-dirs -o tools/sert.py https://raw.githubusercontent.com/kohltastrophe/sert/v0.1.0/tools/sert.py
python3 tools/sert.py init --fetch
rokit install
python3 tools/sert.py run
```

On Windows, download `tools/sert.py` with PowerShell and run `python` instead of `python3`:

```powershell
mkdir -Force tools; iwr https://raw.githubusercontent.com/kohltastrophe/sert/v0.1.0/tools/sert.py -OutFile tools/sert.py
python tools/sert.py init --fetch
rokit install
python tools/sert.py run
```

`init --fetch` writes `sert.toml`, `rokit.toml` (pinning `luau = "luau-lang/luau@0.724"` alongside your lint and build tools), `tools/sert.py`, `.luaurc`, `.gitignore`, `sert.lock`, and `test/example.spec.luau`. Commit `tools/sert.py` and `sert.lock` to your repository so every machine and CI job verifies the exact SHA-256 digests of the `sert` CLI archive, Luau package, and `globalTypes.d.luau`.

## Writing specs

Spec files live under `test/` (such as `test/queue.spec.luau`) and require `@sert`. Spec files omit any trailing `return` statement—`sert` stages top-level specs while keeping line numbers unchanged for stack traces and coverage reports. `sert` stays free of `getfenv` and `setfenv`, so `luau --codegen` stays enabled by default.

```luau
--!strict
local sert = require("@sert")
local Queue = require("../src/Queue")

sert.describe("Queue", function()
	sert.test("pops items in FIFO order", function()
		local q = Queue.new()
		q:push("first")
		q:push("second")
		sert.eq(q:pop(), "first")
		sert.eq(q:pop(), "second")
		sert.eq(q:pop(), nil)
	end)

	sert.prop("drains every pushed item", function(g)
		local items = g:draw(sert.gen.list(sert.gen.boundaryInt(-1000, 1000)))
		local q = Queue.new()
		for _, item in items do
			q:push(item)
		end
		for _, item in items do
			sert.eq(q:pop(), item)
		end
	end)
end)
```

When a property fails, `sert` binary-searches the draw tape down to the smallest failing input and prints a command to replay that exact seed:

```sh
python3 tools/sert.py run --filter "Queue > drains every pushed item" --replay 3622492770
```

## Headless DataModel and VOPR simulation

Use `sert.env.new()` to test Roblox instances, deferred signals, UI layouts, and services in milliseconds under standalone Luau. Step up to `sert.sim` when you want multiple servers and clients sharing cloud stores and remotes under deterministic fault injection.

```luau
--!strict
local sert = require("@sert")

sert.test("despawns temporary parts on the virtual clock", function(ctx)
	local env = sert.env.new()
	ctx:defer(function() env:destroy() end)

	env:run(function()
		local part = Instance.new("Part")
		part.Name = "Orb"
		part.Parent = workspace
		task.delay(5, function() part:Destroy() end)
	end)

	sert.ok(env.workspace:FindFirstChild("Orb"))
	env:advance(5)
	sert.eq(env.workspace:FindFirstChild("Orb"), nil)
end)

sert.sim.vopr("concurrent UpdateAsync increments never lose writes", {
	init = function() return { total = 0 } end,
	commands = {
		deposit = {
			gen = function(_state, g) return g:int(1, 25) end,
			run = function(_sut, amount: number, world)
				local srv = if #world.servers > 0 then world.servers[1] else world:server()
				srv:spawn(function()
					local store = game:GetService("DataStoreService"):GetDataStore("Bank")
					store:UpdateAsync("vault", function(cur) return (cur or 0) + amount end)
				end)
			end,
			next = function(state, amount: number)
				state.total += amount
			end,
		},
	},
	invariants = {
		matchesLedger = function(state, _sut, world)
			if world and world:isQuiescent() then
				local entry = world.backing.datastore:GetDataStore("Bank").data.vault
				local actual = if entry then entry.value else 0
				sert.eq(actual, state.total)
			end
		end,
	},
}, { runs = 50, faults = "none" })
```

## Roblox Studio and Open Cloud

Point `[studio]` at your Rojo project and spec globs in `sert.toml`:

```toml
[studio]
project = "default.project.json"
specs = ["test/**/*.spec.luau"]
```

Tag tests that need the real Roblox engine with `.roblox`, `.server`, or `.client`, then run `sert studio` locally or `sert cloud` in CI:

```luau
--!strict
local sert = require("@sert")

sert.test.client("HUD fits inside a phone viewport", function()
	local Players = game:GetService("Players")
	local hud = Players.LocalPlayer:WaitForChild("PlayerGui"):WaitForChild("Hud")
	sert.roblox.Layout.audit(hud, { touchTargets = 44 })
end)
```

```sh
python3 tools/sert.py studio --device Phone
python3 tools/sert.py studio --clients 2
python3 tools/sert.py studio --warm --affected
python3 tools/sert.py check --changed --agent
```

## Guides

| Guide | Contents |
| --- | --- |
| [docs/agents.md](docs/agents.md) | AI-agent workflow (`sert check --changed`, `sert audit`, `sert init --skill`, `--agent` / `--format json`, `--affected`, `sert fuzz`, zero-config `sert mutate`, snapshots, and anti-reward-hacking rules). |
| [docs/api.md](docs/api.md) | Registration, targets, assertions, inline and `.snap` snapshots, allocation budgets and `sert.bench`, spies, `sert.prop`, `sert.gen`, `sert.laws`, `sert.model`, `sert.bytes`, output capture, and `sert.run`. |
| [docs/env.md](docs/env.md) | `sert.env.new()`, strict and deferred defaults, `[test].stage` and `@game`, 3D spatial casts, `InputAction`, `SharedTable`, Audio nodes, UI layout, and `env:input()`. |
| [docs/sim.md](docs/sim.md) | Multi-peer `sert.sim`, unified `Spec<State, Sut>`, VOPR fault injection, `{ replay = "v1:..." }` reproduction, bounded `explore` (`stateHash`), and linearizability checks (`sert.sim.linearizable`). |
| [docs/roblox.md](docs/roblox.md) | Zero-boilerplate `sert studio` and `sert cloud`, target tags, `--device`, `--clients`, `--warm`, `sert.roblox.conformance`, `Layout`, `Flicker`, `fuzzRemote`, and `sweep`. |
| [docs/cli.md](docs/cli.md) | All CLI commands (`check`, `run`, `fuzz`, `audit`, `bench`, `coverage`, `mutate`, `studio`, `cloud`, `lint`, `init`, `fetch`), `sert.toml`, and `sert.lock`. |
| [docs/ci.md](docs/ci.md) | GitHub Actions setup (`kohltastrophe/sert/actions/setup@v0.1.0`), lockfile caching, coverage, audit, benchmark and mutation gates, and Open Cloud secrets. |

## CI

```yaml
jobs:
  check:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v7
      - uses: kohltastrophe/sert/actions/setup@v0.1.0
      - run: python3 tools/sert.py check
      - run: python3 tools/sert.py mutate --diff origin/main
```

See [docs/ci.md](docs/ci.md) for private-repo tokens, JUnit reports, and Open Cloud workflows.

## Sponsors

`sert` is free and MIT-licensed. If `sert` is useful to you or your team, you can support its development through [GitHub Sponsors](https://github.com/sponsors/kohltastrophe) or [Ko-fi](https://ko-fi.com/kohltastrophe).

<p align="center">
  <a href="https://github.com/sponsors/kohltastrophe"><img src="https://raw.githubusercontent.com/kohltastrophe/kohltastrophe/badges/sponsor-github.svg" alt="GitHub Sponsors" /></a>&nbsp;&nbsp;<a href="https://ko-fi.com/kohltastrophe"><img src="https://raw.githubusercontent.com/kohltastrophe/kohltastrophe/badges/sponsor-kofi.svg" alt="Ko-fi" /></a>
  <a href="https://github.com/sponsors/kohltastrophe"><img src="https://raw.githubusercontent.com/kohltastrophe/kohltastrophe/badges/sponsors.svg" alt="Sponsors" /></a>
</p>

## License

MIT. See [LICENSE.txt](LICENSE.txt).
