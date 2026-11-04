# sert

[![CI](https://img.shields.io/github/actions/workflow/status/kohltastrophe/sert/ci.yml?style=for-the-badge)](https://github.com/kohltastrophe/sert/actions/workflows/ci.yml) [![Coverage](https://img.shields.io/endpoint?url=https://raw.githubusercontent.com/kohltastrophe/sert/badges/coverage.json&style=for-the-badge)](https://github.com/kohltastrophe/sert/actions/workflows/ci.yml) [![License](https://img.shields.io/github/license/kohltastrophe/sert?style=for-the-badge)](LICENSE.txt) [![GitHub Release](https://img.shields.io/github/v/release/kohltastrophe/sert?style=for-the-badge)](https://github.com/kohltastrophe/sert/releases)

A testing and deterministic simulation toolkit for Luau and Roblox. Run unit tests, property tests, stateful models, and multi-server simulations in standalone Luau, Roblox Studio, or Open Cloud.

- **Assertions and Spies:** Write unit tests with value-returning assertions, `expect` matchers, and auto-restoring spies.
- **Property Shrinking and Law Suites:** Generate adversarial inputs, boundary values, and command sequences with `sert.gen`, `sert.model`, and reusable contract suites (`laws.codec`, `laws.remote`, `laws.algebra`, `laws.differential`, `laws.ui`).
- **Headless Roblox Environment:** Test `Instance` trees, UI container layouts (`UIListLayout`, `UIGridLayout`, `UIPadding`, `AutomaticSize`, `Layout.audit`), `RunService` frames, `TweenService`, input, `ProximityPrompt`, and DataStores on a virtual clock without launching Studio.
- **VOPR Multi-Server Simulation:** Run multiple servers and clients on one deterministic scheduler with swarm fault matrices (`Sim.vopr`), remote packet drop/reorder/duplicate faults, TLA+-style state specs (`Sim.spec`), negative invariants (`never`), and trace refinement (`spec:verifyTrace`).
- **Built-in CLI:** Run `sert check`, lint, execute tests with inline failure snippets, inspect diff-scoped coverage (`--uncovered`, `--diff`), and run mutation testing (`--diff`) from a single Python script.

```luau
local sert = require("@sert")

sert.test("string.rep repeats", function()
	sert.expect(string.rep("ab", 3)).toBe("ababab")
end)

sert.prop("string.rep multiplies the length", function(g: sert.Gen)
	local s, n = g:string(), g:int(0, 20)
	sert.eq(#string.rep(s, n), #s * n)
end)

return {}
```

## Install

The `sert` CLI only requires Python 3.11 or newer. The `lint` command also uses `luau-lsp`, StyLua, and `rojo`, which you can install from `rokit.toml` with [rokit](https://github.com/rojo-rbx/rokit).

```sh
curl -fsSL --create-dirs -o tools/sert.py https://raw.githubusercontent.com/kohltastrophe/sert/v0.1.0/tools/sert.py
python3 tools/sert.py init
python3 tools/sert.py run
```

On Windows, download the stub with PowerShell and run `python` instead of `python3`.

```powershell
mkdir -Force tools; iwr https://raw.githubusercontent.com/kohltastrophe/sert/v0.1.0/tools/sert.py -OutFile tools/sert.py
```

`tools/sert.py` is a small bootstrap script that you commit to your repository. It runs the `sert` version pinned in `sert.toml`.

Running `init` creates `sert.toml`, adds the `"sert": "./.sert/sert/src"` alias to `.luaurc`, updates `.gitignore`, and writes `test/Example.spec.luau`. Your first `run` downloads `sert` and `luau` into `.sert/`. See [docs/cli.md](docs/cli.md) for all commands and `sert.toml` options.

## Your first test

Spec files live under `test/` and end in `.spec.luau`. Each spec requires `@sert`, registers its tests, and ends with `return {}` because the Luau CLI requires modules to return a value.

Here is a spec for a `src/Queue.luau` module with `new`, `push`, and `pop`:

```luau
local sert = require("@sert")
local Queue = require("../src/Queue")

sert.describe("queue", function()
	sert.test("pops in push order", function()
		local q = Queue.new()
		q:push("a")
		q:push("b")
		sert.expect(q:pop()).toBe("a")
		sert.expect(q:pop()).toBe("b")
		sert.expect(q:pop()).toBeNil()
	end)

	sert.prop("pops what was pushed", function(g: sert.Gen)
		local items = g:list(sert.gen.int(-100, 100))
		g:note("items: %s", sert.format.repr(items))
		local q = Queue.new()
		for _, item in items do
			q:push(item)
		end
		for _, item in items do
			sert.eq(q:pop(), item)
		end
	end)
end)

return {}
```

Run your suite with `python3 tools/sert.py run`:

```text
sert · 2 tests · Luau CLI
✅ queue > pops in push order · 0 ms
✅ queue > pops what was pushed · 6 ms · 200 cases

2 passed · 0 failed · 0 skipped · 6 ms
```

The property test ran 200 generated lists. If `pop` returned the last item instead of the first, both tests would fail and the property test would shrink the failing input to a two-item list:

```text
❌ queue > pops in push order · 0 ms
   ⚠️ ./test/Queue.spec.luau:9: values differ: expected "a", got "b"
❌ queue > pops what was pushed · 2 ms
   ⚠️ property "queue > pops what was pushed" failed: ./test/Queue.spec.luau:22: values differ: expected 1, got 0
   first failure: ./test/Queue.spec.luau:22: values differ: expected 69, got 94
   seed: base 24301 · run 1 of 200 · case seed 3622492770
   tape: 85 draws → 7 after shrinking (73 attempts): { 1, 0, 1, 1, 0, 0, 0 }
   trace:
      items: { 1, 0 }
   replay: python3 tools/sert.py run --filter "queue > pops what was pushed" --replay=3622492770

0 passed · 2 failed · 0 skipped · 2 ms
.sert/run.luau: failed (exit 1, 0.1s)
```

The `tape:` line shows the internal random draws that produced the failure. Calling `g:note` prints your generated values under `trace:`. Copy the `replay:` command to rerun and shrink that exact failing case.

You can filter tests by file path or by a case-insensitive name substring:

```sh
python3 tools/sert.py run test/Queue.spec.luau
python3 tools/sert.py run --filter "push order"
python3 tools/sert.py run --filter "queue > pops what was pushed" --replay=3622492770
```

`run` exits with `0` when all tests pass and `1` when any test fails. See [docs/cli.md](docs/cli.md#sert-run) for flags like `--fail-fast`, `--seed`, `--runs`, and `--list`.

## Guides

| Guide | What it covers |
| --- | --- |
| [docs/api.md](docs/api.md) | Assertions, `expect`, spies, hooks, properties, generators, models, laws, and `sert.run`. |
| [docs/env.md](docs/env.md) | Headless DataModel testing with `sert.env`, virtual clocks, `RunService`, `TweenService`, input, and DataStores. |
| [docs/sim.md](docs/sim.md) | Multi-server and multi-client VOPR simulation with `sert.sim`, swarm fault injection, `Sim.spec`, `Sim.vopr`, `Sim.prop`, `Sim.model`, and `Sim.explore`. |
| [docs/roblox.md](docs/roblox.md) | Running specs in Roblox Studio and Open Cloud, plus the `Runner`, `Layout`, and `Flicker` helpers. |
| [docs/cli.md](docs/cli.md) | CLI commands, flags, entry scripts, output markers, `sert.toml` configuration, and exit codes. |
| [docs/ci.md](docs/ci.md) | GitHub Actions setup, caching, annotations, and Open Cloud secrets. |

## Roblox

Map `.sert/sert` into your Rojo project to use `sert` inside Roblox:

```json
"ReplicatedStorage": {
	"sert": { "$path": ".sert/sert" }
}
```

Then require it with `require(ReplicatedStorage.sert)`. Run `python3 tools/sert.py studio` to execute your suite in a local Roblox Studio session, or `python3 tools/sert.py cloud` to run it on Open Cloud Luau Execution. See [docs/roblox.md](docs/roblox.md) for setup details.

## CI

```yaml
jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v7
      - uses: kohltastrophe/sert/actions/setup@v0.1.0
      - run: python3 tools/sert.py run --coverage
      - run: python3 tools/sert.py coverage --min 90
      - run: python3 tools/sert.py lint
```

See [docs/ci.md](docs/ci.md) for action inputs, scheduled exhaustive runs, and Open Cloud setup.

## Sponsors

`sert` is free and MIT-licensed. If `sert` is useful to you or your team, you can support its development through [GitHub Sponsors](https://github.com/sponsors/kohltastrophe) or [Ko-fi](https://ko-fi.com/kohltastrophe).

<p align="center">
  <a href="https://github.com/sponsors/kohltastrophe"><img src="https://raw.githubusercontent.com/kohltastrophe/kohltastrophe/badges/sponsor-github.svg" alt="GitHub Sponsors" /></a>&nbsp;&nbsp;<a href="https://ko-fi.com/kohltastrophe"><img src="https://raw.githubusercontent.com/kohltastrophe/kohltastrophe/badges/sponsor-kofi.svg" alt="Ko-fi" /></a>
  <a href="https://github.com/sponsors/kohltastrophe"><img src="https://raw.githubusercontent.com/kohltastrophe/kohltastrophe/badges/sponsors.svg" alt="Sponsors" /></a>
</p>

## License

MIT. See [LICENSE.txt](LICENSE.txt).
