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

- **Device emulation (`--device <Preset>`):** Calls `StudioDeviceSimulatorService:SetDeviceAsync` before specs run. Built-in presets are `Phone` (`390x844@3`), `SmallPhone` (`375x667@2`), `Tablet` (`820x1180@2`), `Desktop` (`1920x1080@1`), `Console` (`1920x1080@1`), and `Ultrawide` (`2560x1080@1`), or pass custom geometry as `WxH` / `WxH@dpr` (`--device 412x915@2.6`).
- **Multi-client sessions (`--clients N`):** Launches a `PlayServer` plus `N` concurrent player clients, isolates each side's test registry, and aggregates the server report alongside all `N` client reports by `runId`.
- **Warm Studio bridge (`--warm`):** Attaches to an already-open Roblox Studio instance without building an overlay place or cold-booting Studio (`--studio-id ID` targets a named session; `--capture` records viewport PNGs into `<out>/<mode>.png`). `sert` resolves the bridge executable from `[studio].bridge`, `SERT_STUDIO_BRIDGE`, `STUDIO_LINK`, or `sert-studio-bridge` / `studio-link` on `PATH`, runs a `Runner` readiness handshake before `ExecutePlayModeAsync`, and clones spec `ModuleScript`s before calling `require` so edited specs bypass Luau's module cache. Custom bridges must accept `[--studio ID] exec --code <luau>` (returning JSON on stdout) and optionally `[--studio ID] screenshot --out <png>`.
- **Runner options & CI reporting:** `sert studio` accepts `--affected [REV]`, `--shuffle`, `--retry N`, `--junit FILE`, `--json-out FILE`, `-u` / `--update-snapshots`, `--prune-snapshots`, `--strict-assertions`, `--save-regressions`, `--bench`, `--agent`, and `--format human|agent|json`.

### Optional custom `sert.roblox.Runner`

Most projects need only `[studio].project` and `[studio].specs`. If your game needs custom per-side dependency injection or custom `ReplicatedStorage` setup before specs load, `sert.roblox.Runner` exposes `Runner.server(config?)`, `Runner.client(config?)`, `Runner.edit(config?, req?)`, `Runner.cloud(config?, req?)`, and `Runner.runOnce(config?, req?)`.

---

## Dual-target conformance (`sert.roblox.conformance`)

`sert.roblox.conformance(name, fn, opts?)` registers two specs from one callback: `<name> [portable]` runs in headless `sert.env`, and `<name> [roblox]` (or `<name> [client]` when `opts.target = "client"`) runs in live Roblox Studio. Each run receives a fresh container (`Workspace` folder or `PlayerGui` `ScreenGui` selected by `opts.container`) and a unified `ConformanceContext` exposing `isRoblox`, `target`, `game`, `workspace`, `Instance`, `task`, `Enum`, datatypes (`Vector2`, `Vector3`, `CFrame`, `Color3`, `UDim`, `UDim2`, `Rect`, `NumberRange`, `TweenInfo`, `Font`, `ColorSequence`, `ColorSequenceKeypoint`, `NumberSequence`, `NumberSequenceKeypoint`, `BrickColor`), `SharedTable`, `getService(name)`, and `step(seconds?)`. `sert` ships an 8-domain parity suite in `test/roblox/specs/conformance/EngineParity.spec.luau` covering instances, signals, DataStores/MemoryStores, remotes, UI layout/insets/text, tags/attributes, Parallel Luau, and spatial/audio/tween checks:

```luau
--!strict
local sert = require("@sert")

sert.roblox.conformance("raycast hits rotated box", function(root, ctx)
	local part = ctx.Instance.new("Part")
	part.Size = ctx.Vector3.new(4, 2, 4)
	part.CFrame = ctx.CFrame.new(0, 5, 0) * ctx.CFrame.Angles(0, math.rad(45), 0)
	part.Parent = root

	local hit = ctx.workspace:Raycast(ctx.Vector3.new(0, 10, 0), ctx.Vector3.new(0, -10, 0))
	sert.ok(hit ~= nil)
	sert.eq(hit.Instance, part)
end, { container = "workspace", target = "roblox" })
```

`sert.roblox.conformance` also provides `.skip` and `.focus` modifiers plus `{ tags, timeout, env }` options.

---

## UI geometry assertions (`sert.roblox.Layout`)

`sert.roblox.Layout` verifies rendered `GuiObject` bounds, text fitting, overlap, and touch targets in both Roblox Studio and headless `sert.env`, recording each check with `sert`'s assertion tracker so tests satisfy `--strict-assertions` and `sert audit`:

| Function | Verifies |
| --- | --- |
| `Layout.settle(root, opts?) -> number` | Steps render frames (`maxFrames`, `stableFrames`, `tolerance`) until `UIListLayout`, `AutomaticSize`, and `TextBounds` stabilize. |
| `Layout.visible(gui)` | `AbsoluteSize` has positive width and height, `Visible` is `true` on all `GuiObject` ancestors, enclosing `LayerCollector.Enabled` is `true`, `CanvasGroup.GroupTransparency < 1`, and no ancestor `UIScale` is `0`. |
| `Layout.fitsParent(child, margin?, tolerance?)` | `child` stays within its parent's bounds (checking `AbsoluteCanvasSize` when parented to a `ScrollingFrame`). |
| `Layout.within(descendant, ancestor, margin?, tolerance?)` | `descendant`'s axis-aligned bounding box stays inside `ancestor`. |
| `Layout.fitsViewport(root, opts?)` | `root` and its visible descendants fit inside the viewport (`opts = { viewport?, tolerance?, ignore? }`), accounting for `GuiService:GetGuiInset()`, rotated bounding boxes, and `ClipsDescendants`. |
| `Layout.noOverlap(container, opts?)` | Child `GuiObject`s inside `container` have pairwise non-overlapping rectangles (`opts = { tolerance?, ignore?, recursive? }`). |
| `Layout.noTextOverflow(root, opts?)` | `TextBounds` (checked against `ContentText` and inner `UIPadding` space) fits inside `AbsoluteSize` and `TextFits` is `true`. |
| `Layout.minTouchTarget(root, opts?)` | Interactive controls measure at least `minSize` (`number | Vector2`, default `44` px). |
| `Layout.aligned(elements, edge, tolerance?)` | Aligns `elements` along `"left"`, `"right"`, `"top"`, `"bottom"`, `"centerX"`, or `"centerY"`. |
| `Layout.audit(root, opts?)` | Runs `settle` plus `viewport`, `overlap`, `textOverflow`, and `touchTargets` checks across a UI subtree (`opts = { settle?, overlap?, viewport?, textOverflow?, touchTargets?, ignore? }`). |
| `Layout.matrix(name?, mountFn, opts?)` | Runs `mountFn(container, preset, env?)` across `Layout.PRESETS` (`Phone`, `SmallPhone`, `Tablet`, `Desktop`, `Console`, `Ultrawide`). |

```luau
--!strict
local sert = require("@sert")
local Layout = sert.roblox.Layout

sert.test.client("shop modal passes layout audit across every form factor", function()
	Layout.matrix(function(container, _preset)
		local modal = mountShopModal(container)
		Layout.audit(modal, {
			touchTargets = 44,
			ignore = { "Divider" },
		})
		modal:Destroy()
	end)
end)
```

---

## Layout stability (`sert.roblox.Flicker`)

`Flicker.steady(target, opts?)` steps frame by frame while watching `AbsolutePosition` and `AbsoluteSize` on `target` and its descendants. It catches single-frame zero-size flashes, `AutomaticSize` oscillation, and post-settle layout jumps while recording an assertion on `Flicker.expect`:

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
