# sert in Roblox

The `sert` package is a standard `ModuleScript` tree. Specs that run headlessly under `sert run` can also run inside a real Roblox place using `sert studio` or `sert cloud`.

## Requiring sert in Roblox

`sert fetch` extracts the release to `.sert/sert/`. Map that directory into `ReplicatedStorage` in your Rojo project:

```json
"ReplicatedStorage": {
	"sert": { "$path": ".sert/sert" }
}
```

Then require `ReplicatedStorage.sert`. Inside Roblox, `sert.isRoblox` is `true`, `sert.rtest` cases execute, and yielding tests time out after `timeout` seconds (default `30`). You can access submodules directly on `sert`, including `sert.doubles`, `sert.sim`, and `sert.roblox` (`Runner`, `Layout`, `Flicker`).

## Running specs in Studio

`sert studio` builds `[studio].project` with Rojo, launches Studio in batch mode (`-task RunScript`), runs specs across your configured sides, and writes reports to `[studio].out` (default `build/sert`).

| Mode | Session | Where sides run |
| --- | --- | --- |
| `play` | `StudioTestService:ExecutePlayModeAsync` (server + 1 client) | `server` side runs on the server, and all other sides run on the client. |
| `run` | `StudioTestService:ExecuteRunModeAsync` (server only) | Every side runs on the server. |
| `edit` | Edit DataModel, no session | Every side runs in the edit DataModel. |

### Minimal setup

1. **Server `Script` (`ServerScriptService`):**
   ```luau
   local ReplicatedStorage = game:GetService("ReplicatedStorage")
   require(ReplicatedStorage.sert.roblox.Runner).server(require(ReplicatedStorage.Tests.Config))
   ```
2. **Client `LocalScript` (`ReplicatedFirst`):**
   ```luau
   local ReplicatedStorage = game:GetService("ReplicatedStorage")
   if not game:IsLoaded() then
   	game.Loaded:Wait()
   end
   local Runner = require(ReplicatedStorage:WaitForChild("sert"):WaitForChild("roblox"):WaitForChild("Runner"))
   Runner.client(require(ReplicatedStorage:WaitForChild("Tests"):WaitForChild("Config")))
   ```
3. **Config `ModuleScript` (`ReplicatedStorage.Tests.Config`):**
   ```luau
   local ReplicatedStorage = game:GetService("ReplicatedStorage")
   local Runner = require(ReplicatedStorage.sert.roblox.Runner)
   local specs = ReplicatedStorage:WaitForChild("Tests"):WaitForChild("specs")

   return {
   	name = "my game",
   	sides = {
   		server = { root = specs:WaitForChild("server") },
   		client = { root = specs:WaitForChild("client") },
   	},
   	scriptErrors = true,
   } :: Runner.Config
   ```
4. **`sert.toml`:**
   ```toml
   [studio]
   project = "studio/default.project.json"
   config = "ReplicatedStorage/Tests/Config"
   specs = ["studio/specs/**/*.spec.luau"]
   sides = ["server", "client"]
   ```

Verify your setup without launching Studio by running `python3 tools/sert.py studio --check`, then run the suite with `python3 tools/sert.py studio`. Each spec is a `*.spec` `ModuleScript` that returns `{}` (or `fn(ctx)` / `{ register = fn }`).

## Runner config and helpers

### `Runner.Config`

| Key | Description |
| --- | --- |
| `name`, `sert` | Suite title in reports (default `"sert"`) and an optional explicit `sert` module table. |
| `sides`, `entry`, `root`, `order` | `{ [sideName] = Side }` map (or a single top-level `entry` / `root`) and side execution order (`"server"` runs first by default). |
| `rtestOnly` | Skips plain `sert.test` registrations unless overridden on a `Side`. |
| `warmup(ctx) -> (() -> ())?` | Client hook run before specs start. Can return a cleanup function. |
| `hideChat`, `characters` | Disables `CoreGui` chat on the client (default `true`). `characters = false` sets `Players.CharacterAutoLoads = false`. |
| `scriptErrors` | Fails the run if `ScriptContext.Error` fires (`<where> · no script errors`). |
| `randomSeed` | Picks a random base property seed when `--seed` is omitted. |
| `context(ctx) -> ...any` | Customizes the arguments passed to function-style spec modules (defaults to `ctx`). |

### `Runner.Side`

| Key | Description |
| --- | --- |
| `root` | Folder `Instance` whose descendant `*.spec` `ModuleScript`s are required in alphabetical order. |
| `entry` | Single aggregator `ModuleScript` required instead of scanning `root`. |
| `where` | `"server"` or `"client"` (defaults to `"server"` for the `"server"` side and `"client"` otherwise). |
| `filter` | Default test name substring filter when no CLI filter is passed. |
| `setup` | `{ beforeEach?, afterEach? }` hooks run around every test on this side. |
| `before(ctx)`, `after(ctx)` | Hooks run once before or after the side's specs. |
| `concurrent` | On the `"server"` side in `play` mode, runs server specs concurrently with client specs instead of before them. |
| `rtestOnly` | Overrides `Config.rtestOnly` for this side. |

### `Runner.Context` and helpers

Function specs, `warmup`, `before`, and `after` receive `ctx = { sert, side, where, request, config, filter, errors }`.

- **`Runner.args(wait?: number) -> { [string]: any }?`** waits up to `wait` seconds (default `5`) for `sert studio` arguments, returning `nil` during interactive Play in Studio.
- **`Runner.phase(where: string, name: string)`** emits `[sert-phase] <where> <name> <unixMs>`.
- **`Runner.marker(tag: string, text: string)`** emits `[sert-x:<tag>] <text>` for `[studio].hooks` `on_marker(tag, payload, state)`.

## Layout

`sert.roblox.Layout` settles and inspects GUI geometry in Studio and under `sert.env`.

```luau
local Layout = require(ReplicatedStorage.sert.roblox.Layout)

sert.rtest("inventory grid settles without clipping cards", function()
	local ok, moving = Layout.settle(playerGui.Inventory)
	sert(ok, `layout did not settle: {moving}`)
end)
```

| Function | Description |
| --- | --- |
| `Layout.settle(target, options?) -> (boolean, string?)` | Steps frames until every visible `GuiObject` under `target` keeps its `AbsolutePosition`, `AbsoluteSize`, and `TextBounds` within `tolerance` for `stable` consecutive frames. Returns `(false, fullName)` if an element is still moving at `maxFrames` or `timeout`. |
| `Layout.visible(object, stopAt?) -> boolean` | Returns `true` when `object` and every `GuiObject` ancestor up to `stopAt` have `Visible == true` and any enclosing `LayerCollector` has `Enabled == true`. |
| `Layout.clippedBounds(cell) -> (Vector2, Vector2)` | Returns the top-left and bottom-right corners of `cell` after clipping against `ClipsDescendants` ancestors. |
| `Layout.noOverlap(container, opts?)` | Asserts that no two visible sibling `GuiObject` children of `container` overlap beyond `opts.tolerance` (default `0.5` px). |
| `Layout.fitsParent(node, opts?)` | Asserts that `node` fits inside its parent `GuiBase2d` bounds within `opts.tolerance` (default `1` px). |
| `Layout.fitsViewport(root, opts?)` | Asserts that all visible `GuiObject` descendants of `root` stay inside `opts.viewport` (or the enclosing `ScreenGui` / `Camera.ViewportSize`). |
| `Layout.noTextOverflow(root, opts?)` | Asserts that every visible `TextLabel`, `TextButton`, and `TextBox` under `root` fits its `TextBounds` inside `AbsoluteSize`. |
| `Layout.audit(root, opts?)` | Runs `fitsViewport`, `noOverlap`, and `noTextOverflow` across `root` and throws if any invariant fails. |

### `SettleOptions`

| Option | Default | Description |
| --- | --- | --- |
| `lead` | `1` | Initial frames stepped before taking the first snapshot. |
| `stable` | `2` | Consecutive unchanged frames required to count as settled. |
| `maxFrames`, `timeout` | `120`, `2` | Maximum frames and wall-clock seconds before returning `false`. |
| `tolerance` | `0.5` | Maximum pixel delta between frames that still counts as stationary. |
| `descendants` | `true` | Checks `target` and all descendant `GuiObject`s (`false` checks `target` only). |
| `filter` | `nil` | Predicate `(GuiObject) -> boolean` to include or skip descendants. |
| `step` | `nil` | Custom frame stepper (`RunService.Heartbeat:Wait()` in Roblox, `env:step()` headlessly). |

## Flicker

`sert.roblox.Flicker` records a `GuiObject`'s screen rect on every `RunService.PreAnimation` frame starting from the first frame it becomes visible. It fails if any frame deviates from the final settled rect beyond your declared entrance motion.

```luau
local result = Flicker.around(function()
	return playerGui:FindFirstChild("Dialog", true)
end, openDialog, { motion = 24 })
Flicker.expect(result, "dialog")
```

| Function | Description |
| --- | --- |
| `Flicker.around(target: () -> GuiObject?, open: () -> (), options?) -> Result` | Records `target` across `open()` until it settles, then judges the recording. |
| `Flicker.record(target: () -> GuiObject?, options?) -> Recorder` | Starts recording. Call `recorder.result()` to wait and judge, or `recorder.stop()` to stop early. |
| `Flicker.expect(result, label?)` | Throws with a frame-by-frame rect trace if `not result.ok`. |
| `Flicker.judge(result, options?) -> Result` | Judges a sample list `{ frame, shown, x, y, width, height }` headlessly. |
| `Flicker.describe(result) -> string`, `Flicker.visible(obj)`, `Flicker.drive(frame?)` | Formats a sample trace, checks visibility, or overrides the frame stepper. |

### `Flicker` options

| Option | Default | Description |
| --- | --- | --- |
| `motion` | `0` | Allowed monotonic entrance slide in pixels along one axis toward the settled position. |
| `tolerance` | `1` | Sub-pixel rounding tolerance in pixels. |
| `stable` | `3` | Consecutive stationary frames required after entrance motion ends. |
| `timeout`, `shown` | `2`, `nil` | Seconds to wait for settling and an optional visibility predicate `(GuiObject) -> boolean` checked alongside `Flicker.visible`. |
| `positionOnly` | `false` | Ignores size changes during entrance motion and checks position only. |
| `maxStep` | `nil` | Maximum pixel step allowed between two consecutive frames. |
| `fromSettledSize` | `false` | Starts judging from the first visible frame that matches the settled size. |
| `busy` | `nil` | Predicate `() -> boolean` that keeps recording while an animation or tween is active. |
| `label`, `runService` | `nil`, `RunService` | Diagnostic label and `RunService` override. |

## Open Cloud

`sert cloud` builds `[cloud].project`, uploads it as a Saved version, and runs `[cloud].script` on Open Cloud Luau Execution (in parallel across `[cloud].shards` when configured).

1. **Credentials:** Set `ROBLOX_API_KEY` (with `universe-places: Write` and `luau-execution-sessions: Read, Write` permissions), `ROBLOX_UNIVERSE_ID`, and `ROBLOX_PLACE_ID`.
2. **Task script (`studio/cloud.luau`):** Require your spec modules and end with `return sert.run()`.
3. **`sert.toml`:**
   ```toml
   [cloud]
   project = "studio/default.project.json"
   script = "studio/cloud.luau"
   shards = [{ name = "queue", only = ["queue"] }, "rest"]
   ```
4. **Run:** Verify locally with `python3 tools/sert.py cloud --dry-run`, then execute on Open Cloud with `python3 tools/sert.py cloud`.
