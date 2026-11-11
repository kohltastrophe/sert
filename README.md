# sert

[![CI](https://img.shields.io/github/actions/workflow/status/kohltastrophe/sert/ci.yml?style=for-the-badge)](https://github.com/kohltastrophe/sert/actions/workflows/ci.yml) [![Coverage](https://img.shields.io/endpoint?url=https://raw.githubusercontent.com/kohltastrophe/sert/badges/coverage.json&style=for-the-badge)](https://github.com/kohltastrophe/sert/actions/workflows/ci.yml) [![License](https://img.shields.io/github/license/kohltastrophe/sert?style=for-the-badge)](LICENSE.txt) [![GitHub Release](https://img.shields.io/github/v/release/kohltastrophe/sert?style=for-the-badge)](https://github.com/kohltastrophe/sert/releases)

Testing, property shrinking, deterministic simulation, and Studio verification for Luau and Roblox. Write unit tests, shrinking properties, headless DataModel specs, and multi-server fault simulations that run across standalone Luau, Roblox Studio, and Open Cloud.

`sert` combines procedural `sert.*` assertions, nested asymmetric matchers (`any`, `subset`, `within`, `matching`), and auto-restoring spies with byte-tape property shrinking (`sert.prop`, `sert.gen`), algebraic laws (`sert.laws`), and stateful model checking (`sert.model`). When code touches Roblox APIs, run `Instance` trees, deferred signals, UI layouts, input, DataStores, and MemoryStores on a virtual clock with `sert.env.new()`, or schedule multiple servers and clients with `sert.sim` to inject packet drops, cloud storage faults, rolling shutdowns, and teleport races. Point `sert studio` or `sert cloud` at your Rojo project to run server, client, multi-client, and device-preset suites without bootstrap scripts, and gate changes with dual-solver type probes, LCOV coverage floors, and token-stream mutation testing.

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
curl -fsSL --create-dirs -o tools/sert.py https://raw.githubusercontent.com/kohltastrophe/sert/v0.2.0/tools/sert.py
python3 tools/sert.py init --fetch
rokit install
python3 tools/sert.py run
```

On Windows, download `tools/sert.py` with PowerShell and run `python` instead of `python3`:

```powershell
mkdir -Force tools; iwr https://raw.githubusercontent.com/kohltastrophe/sert/v0.2.0/tools/sert.py -OutFile tools/sert.py
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
```

## Guides

| Guide | Contents |
| --- | --- |
| [docs/api.md](docs/api.md) | Registration, targets, hooks, assertions, asymmetric matchers, spies, `sert.prop`, `sert.gen`, `sert.laws`, `sert.model`, `sert.bytes`, output capture, and `sert.run`. |
| [docs/env.md](docs/env.md) | `sert.env.new()`, strict and deferred defaults, typed lexical staging (`[test].stage` and `@game`), modeled services, UI layout, and `env:input()`. |
| [docs/sim.md](docs/sim.md) | Multi-peer `sert.sim`, unified `Spec<State, Sut>`, VOPR fault injection, `{ replay = "v1:..." }` reproduction, remote faults, and Teleport/BindToClose/ProcessReceipt hazards. |
| [docs/roblox.md](docs/roblox.md) | Zero-boilerplate `sert studio` and `sert cloud`, target tags, `--device`, `--clients`, `--warm`, `Layout`, `Flicker`, `fuzzRemote`, and `sweep`. |
| [docs/cli.md](docs/cli.md) | All CLI commands (`init`, `fetch`, `lint`, `run`, `coverage`, `mutate`, `check`, `studio`, `cloud`), `sert.toml`, and `sert.lock`. |
| [docs/ci.md](docs/ci.md) | GitHub Actions setup (`kohltastrophe/sert/actions/setup@v0.2.0`), lockfile caching, coverage and mutation gates, and Open Cloud secrets. |

## CI

```yaml
jobs:
  check:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v7
      - uses: kohltastrophe/sert/actions/setup@v0.2.0
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
