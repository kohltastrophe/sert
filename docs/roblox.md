# Roblox Studio & Open Cloud (`roblox.md`)

`sert` runs your specs inside real Roblox Studio (`sert studio`) and Roblox Open Cloud Luau Execution (`sert cloud`) without requiring bootstrap `Script`, `LocalScript`, or runner configuration files in your repository.

---

## Zero-boilerplate setup

Point `[studio]` at your Rojo project and spec globs in `sert.toml`.

```toml
[studio]
project = "default.project.json"
specs = ["test/**/*.spec.luau"]
mode = "play"
```

When you run `python3 tools/sert.py studio` or `python3 tools/sert.py cloud`, `sert` generates a temporary Rojo overlay that mounts `@sert` and stages your `.spec.luau` files. It injects the server, client, edit, or Open Cloud bootstrap scripts automatically.

```sh
python3 tools/sert.py studio                        # Run in [studio].mode (edit, play, or run)
python3 tools/sert.py studio --device Phone         # Emulate a phone viewport & pixel density
python3 tools/sert.py studio --clients 2            # Boot PlayServer + 2 Player client sessions
python3 tools/sert.py studio --warm                 # Re-run in an already-open Studio in <1s
python3 tools/sert.py cloud                         # Upload place & run across parallel Open Cloud shards
```

---

## Target tags (`portable`, `roblox`, `server`, `client`)

Keep pure logic and `sert.env` specs in `sert.test` so they run in milliseconds under `sert run`, and tag real-engine specs according to which DataModel side they need:

| Registration | Target | Where it executes |
| --- | --- | --- |
| `sert.test` / `sert.prop` / `sert.model` | `"portable"` | `sert run` (and Studio/Cloud when `allTargets = true`) |
| `sert.test.roblox` / `sert.prop.roblox` | `"roblox"` | Server DataModel in `sert studio` (`edit`, `run`, `play`) and `sert cloud` |
| `sert.test.server` / `sert.prop.server` | `"server"` | Server DataModel in `sert studio` (`run`, `play`) and `sert cloud` |
| `sert.test.client` / `sert.prop.client` | `"client"` | Each `LocalPlayer` client DataModel in `sert studio --mode play` |

```luau
--!strict
local sert = require("@sert")

sert.test.server("PhysicsService collision groups isolate projectiles", function()
	local PhysicsService = game:GetService("PhysicsService")
	PhysicsService:RegisterCollisionGroup("Projectiles")
	PhysicsService:CollisionGroupSetCollidable("Projectiles", "Projectiles", false)
	sert.eq(PhysicsService:CollisionGroupsAreCollidable("Projectiles", "Projectiles"), false)
end)

sert.test.client("LocalPlayer spawns with a PlayerGui", function()
	local player = game:GetService("Players").LocalPlayer
	sert.ok(player:WaitForChild("PlayerGui", 5))
end)
```

---

## Device presets, multi-client, and `--warm` Studio

- **Device emulation (`--device <Preset>`):** Calls `StudioDeviceSimulatorService:SetDeviceAsync` before specs run. Built-in presets are `Phone` (`390x844@3`), `SmallPhone` (`320x568@2`), `Tablet` (`820x1180@2`), `Desktop` (`1920x1080@1`), `Console` (`1920x1080@1`), and `Ultrawide` (`2560x1080@1`), or pass custom geometry as `WxH` / `WxH@dpr` (`--device 412x915@2.6`).
- **Multi-client sessions (`--clients N`):** Launches a `PlayServer` plus `N` concurrent player clients, isolates each side's test registry, and aggregates the server report alongside all `N` client reports by `runId`.
- **Warm Studio bridge (`--warm`):** Connects to an already-open Roblox Studio via `studio_link.py` (`--studio ID` targets a named Studio instance; `--capture` records screenshots). On each warm run, `sert.roblox.Runner` clones spec `ModuleScript`s before calling `require`, bypassing Luau's module cache so edited specs re-execute without restarting Studio.

### Optional custom `sert.roblox.Runner`

Most projects need only `[studio].project` and `[studio].specs`. If your game needs custom per-side dependency injection or custom `ReplicatedStorage` setup before specs load, `sert.roblox.Runner` exposes `Runner.server(config?)`, `Runner.client(config?)`, `Runner.edit(config?, req?)`, `Runner.cloud(config?, req?)`, and `Runner.runOnce(config?, req?)`.

---

## UI geometry assertions (`sert.roblox.Layout`)

`sert.roblox.Layout` verifies rendered `GuiObject` bounds, text fitting, overlap, and touch targets in both Roblox Studio and headless `sert.env`:

| Function | Verifies |
| --- | --- |
| `Layout.settle(frames?, opts?)` | Steps `frames` render frames (default `2`) so `UIListLayout`, `AutomaticSize`, and `TextBounds` settle. |
| `Layout.visible(gui, label?)` | `AbsoluteSize` has positive width and height, `Visible` is `true` on all `GuiObject` ancestors, enclosing `LayerCollector.Enabled` is `true`, `CanvasGroup.GroupTransparency < 1`, and no ancestor `UIScale` is `0`. |
| `Layout.fitsParent(child, eps?, label?)` | `child` stays within its parent's bounds (checking `AbsoluteCanvasSize` when parented to a `ScrollingFrame`). |
| `Layout.within(inner, outer, eps?, label?)` | `inner`'s axis-aligned bounding box stays inside `outer`. |
| `Layout.fitsViewport(gui, viewport?, eps?)` | `gui` and its visible descendants fit inside the screen—accounting for `GuiService:GetGuiInset()` when `ScreenGui.IgnoreGuiInset == false`, rotated `Rotation` bounding boxes, and `ClipsDescendants` containers. |
| `Layout.noOverlap(items, eps?, label?)` | Sibling `GuiObject`s in `items` have pairwise non-overlapping rectangles. |
| `Layout.noTextOverflow(gui, eps?, label?)` | `TextBounds` (checked against `ContentText` and inner `UIPadding` space) fits inside `AbsoluteSize` and `TextFits` is `true`. |
| `Layout.minTouchTarget(gui, minPx?, label?)` | Interactive control measures at least `minPx x minPx` (default `44` px). |
| `Layout.aligned(items, edge, eps?, label?)` | Aligns `items` along `"left"`, `"right"`, `"top"`, `"bottom"`, `"centerX"`, or `"centerY"`. |
| `Layout.audit(root, opts?)` | Runs `settle` plus `viewport`, `overlap`, `textOverflow`, and `touchTargets` checks across an entire UI subtree (`opts = { settle?, overlap?, viewport?, textOverflow?, touchTargets?, ignore? }`). |
| `Layout.matrix(name?, mountFn, opts?)` | Runs `mountFn(presetName, viewportSize)` across `Layout.PRESETS` (`Phone`, `SmallPhone`, `Tablet`, `Desktop`, `Console`, `Ultrawide`). |

```luau
--!strict
local sert = require("@sert")
local Layout = sert.roblox.Layout

sert.test.client("shop modal passes layout audit across every form factor", function()
	Layout.matrix(function(_preset, size)
		local modal = mountShopModal(size)
		Layout.audit(modal, {
			touchTargets = 44,
			ignore = { Divider = true },
		})
		modal:Destroy()
	end)
end)
```

---

## Layout stability (`sert.roblox.Flicker`)

`Flicker.steady(target, opts?)` steps frame by frame while watching `AbsolutePosition` and `AbsoluteSize` on `target` and its descendants—catching one-frame zero-size flashes, `AutomaticSize` oscillation, or post-settle layout jumps:

```luau
--!strict
local sert = require("@sert")

sert.test.client("inventory drawer opens without a single-frame size snap", function()
	local drawer = openInventoryDrawer()
	sert.roblox.Flicker.steady(drawer, {
		maxFrames = 30,
		stableFrames = 4,
		tolerance = 0.5,
	})
end)
```

For lower-level inspection, call `local res = Flicker.record(target, opts?)`, then inspect `Flicker.judge(res, opts?)`, `Flicker.describe(res)`, or `Flicker.expect(res)`.

---

## Adversarial remote fuzzing (`sert.roblox.fuzzRemote`)

`sert.roblox.fuzzRemote` feeds a server remote handler `(player, ...)` malformed and boundary arguments drawn from `sert.gen.remotePayload()`. Generated inputs cover `NaN`, `±math.huge`, `-0.0`, deep or cyclic tables, sparse arrays with `nil` holes, oversized `buffer`s, spoofed `Instance`-shaped tables, and missing or extra varargs, asserting that the handler never yields unexpectedly, corrupts state, or leaks unhandled errors.

```luau
--!strict
local sert = require("@sert")

sert.roblox.fuzzRemote("EquipItem remote rejects untrusted payloads", {
	handler = EquipService.onEquipRemote,
	makePlayer = function() return { UserId = 101, Name = "Fuzzer" } end,
	allowYield = false,
	runs = 200,
	checkState = function()
		sert.ge(EquipService.activeCount(101), 0)
	end,
})
```

---

## Post-test DataModel cleanup (`sert.roblox.sweep`)

`sert.roblox.Runner` automatically wraps every Studio and Open Cloud test with `sert.roblox.sweep` (unless `sweep = false` is passed). Before each test, `sweep.snapshot()` records existing children of `Workspace`, `Lighting`, `SoundService`, `ReplicatedStorage` (excluding mounted code and spec containers), and `LocalPlayer.PlayerGui`; after the test finishes, `sweep.restore(snap)` destroys any leaked instances in LIFO order.

You can also invoke `sert.roblox.sweep.around(fn, opts?)` directly inside custom test setups.
