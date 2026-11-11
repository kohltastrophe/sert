# Headless Roblox Environment (`env.md`)

`sert.env.new(options?)` constructs an isolated, deterministic Roblox DataModel, virtual `task` scheduler, UI layout solver, and service layer that runs in microseconds under standalone Luau (`sert run`). Each `Env` owns its own `game`, `workspace`, clock, instances, and backing stores—tests never share global state.

```luau
--!strict
local sert = require("@sert")

sert.test("coalesces deferred attribute changes before firing listeners", function(ctx)
	local env = sert.env.new()
	ctx:defer(function() env:destroy() end)

	local observed = {}
	env:run(function()
		local folder = Instance.new("Folder")
		folder.Parent = workspace
		folder:GetAttributeChangedSignal("Combo"):Connect(function()
			table.insert(observed, folder:GetAttribute("Combo"))
		end)

		folder:SetAttribute("Combo", 1)
		folder:SetAttribute("Combo", 2)
		sert.eq(#observed, 0) -- Deferred signal has not fired yet
	end)

	env:flush()
	sert.eq(observed, { 2 })
end)
```

---

## Strict and deferred defaults

`sert.env.new(options?: sert.EnvOptions)` enables strict API validation and deferred signals by default so headless tests match modern Roblox places:

| Option | Default | Description |
| --- | --- | --- |
| `strict` | `true` | Validates class names, creatable vs non-creatable classes, read-only properties, property value types, and `Enum` items against the Roblox API schema (`strict = false` allows ad-hoc properties on mock instances). |
| `signalBehavior` | `"Deferred"` | Queues signal listeners onto the active defer point and re-checks `connection.Connected` before invoking each handler. Pass `"Immediate"` to model legacy immediate places. |
| `seed` | `1` | Deterministic seed for `math.random` and `Random.new()` inside `env:run` / `env:require`. |
| `frame` | `1 / 60` | Default frame delta (seconds) used by `env:step()`, `env:frames()`, and `RunService` events. |
| `viewport` | `Vector2.new(1920, 1080)` | Initial `Workspace.CurrentCamera.ViewportSize` for UI layout calculation. |
| `isServer` / `isClient` / `isStudio` | `true` / `false` / `false` | Configures `RunService:IsServer()`, `:IsClient()`, and `:IsStudio()`. |
| `placeId` / `jobId` | `0` / `"sert-job"` | Sets `game.PlaceId` and `game.JobId`. |

When a test yields while an `env` is active in `sert run`, `sert`'s runner automatically steps that `env` forward until the coroutine completes or `--test-timeout` expires.

---

## Typed lexical staging (`[test].stage` and `@game`)

Set `[test].stage` in `sert.toml` to point at your Rojo project file.

```toml
[test]
stage = "default.project.json"
```

During `sert run` and `sert lint`, `sert` builds two synchronized artifacts under `.sert/stage/` without calling `setfenv` or `getfenv`. Keeping `L->gt->safeenv` intact lets `luau --codegen` compile both your game modules and your tests to native machine code:

1. **Line-preserving lexical modules (`.sert/stage/lexical/`):** Wraps each script in `return function(_ENV: any, ...: any): ...any` on line 1 so `game`, `workspace`, `script`, `Instance`, `task`, `typeof`, and Roblox datatypes bind lexically to whichever `Env` mounts the stage, while preserving original line numbers `1..N` for stack traces and `coverage.out`.
2. **Type-preserving mirrors (`.sert/stage/game/`):** Writes `--!strict` wrapper modules and maps `"game": "./.sert/stage/game"` in `.luaurc`.

Mount the generated stage into an `Env`, then require modules through `@game/...` with full `luau-lsp` autocomplete and typechecking:

```luau
--!strict
local sert = require("@sert")
local stage = require("../.sert/stage")
local Inventory = require("@game/ReplicatedStorage/Shared/Inventory")

sert.test("awards starter items to joining players", function(ctx)
	local env = sert.env.new()
	ctx:defer(function() env:destroy() end)
	env:mount(stage)

	local player = env:addPlayer(1001, "Kohl")
	local inv = Inventory.forPlayer(player)
	inv:grant("WoodenSword", 1)
	sert.eq(inv:count("WoodenSword"), 1)
end)
```

You can also load staged instances directly via `env:require(env.game.ReplicatedStorage.Shared.Inventory)` when testing multiple `Env` worlds side by side. For pure datatype helpers that don't mount a DataModel, pass `--roblox-globals` (or set `[test].globals = "roblox"` in `sert.toml`) to expose `Vector3`, `CFrame`, `Color3`, `UDim2`, and `Enum` globally.

---

## Clock, lifecycle, and inspection methods

| Method | Description |
| --- | --- |
| `env:run(fn, ...)` | Runs `fn(...)` with `env` bound as the active environment and drains immediate/deferred tasks scheduled during the call. |
| `env:bind(fn)` | Wraps `fn` so future invocations execute inside `env`. |
| `env:step(dt?)` | Advances one frame (`dt` defaults to `options.frame`), firing `RunService` step pipelines and timers due within that frame. |
| `env:frames(count, dt?)` | Steps `count` discrete frames. |
| `env:advance(seconds)` | Advances virtual time by `seconds` across discrete frames. |
| `env:flush()` | Drains pending deferred signals and zero-delay `task.defer` / `task.spawn` continuations at the current timestamp. |
| `env:settle(opts?)` | Advances frames until pending timers, tweens, and dirty UI layouts settle (or `maxFrames` is reached). |
| `env:mount(stage, parent?)` | Materializes a staged Rojo tree (from `require("../.sert/stage")`) into `env.game` (or `parent`). |
| `env:require(moduleScript)` | Executes and caches a `ModuleScript` inside `env` (isolated per `Env` instance). |
| `env:addPlayer(userId, name?)` / `env:removePlayer(playerOrId)` | Joins or removes a `Player` in `Players`, firing `PlayerAdded` / `PlayerRemoving`. |
| `env:shutdown()` | Fires `game:BindToClose` callbacks and marks the environment closed. |
| `env:destroy()` | Shuts down tasks, disconnects signals, and releases environment state. |

---

## Modeled engine semantics and services

### Core DataModel and datatypes

- **Exact datatype equality:** `Vector2`, `Vector3`, `CFrame`, `Color3`, `UDim`, `UDim2`, and `Rect` compare exact components under `==` (matching Luau's native engine `__eq`). Use `:FuzzyEq` or `sert.near` for floating-point tolerances.
- **Signals and hierarchy:** `GetPropertyChangedSignal(prop)` and `GetAttributeChangedSignal(attr)` fire with `0` arguments; `Instance:WaitForChild(name, timeOut?)` yields on the virtual clock (emitting an infinite-yield warning at 5 seconds when `timeOut` is omitted); `Instance:Destroy()` disconnects all signals without firing spurious descendant `Changed("Parent")` cascades.
- **Boundary serialization:** `RemoteEvent` / `RemoteFunction` payloads strip user table metatables, clone buffers and tables, and reject functions, threads, and mixed array/dictionary tables. `DataStore` and `MemoryStore` payloads enforce strict JSON tree cloning (`NaN`, `±math.huge`, invalid UTF-8, and shared DAG reference aliasing are rejected or cloned into independent trees).

### Built-in services (`game:GetService(name)`)

| Service | Modeled capabilities |
| --- | --- |
| `RunService` | Distinct `PreRender`, `PreAnimation`, `PreSimulation`, `PostSimulation`, `Heartbeat`, and `Stepped` signals passing `dt` while advancing `Workspace.DistributedGameTime`, `time()`, and `elapsedTime()`. |
| `DataStoreService` | `GetDataStore`, `GetOrderedDataStore` (`GetSortedAsync`), `GetAsync`, `SetAsync`, `IncrementAsync`, `RemoveAsync`, `UpdateAsync` (enforces Roblox's no-yield transform rule), `DataStoreKeyInfo` metadata/userIds/versions, and request budgets. |
| `MemoryStoreService` | `GetHashMap` (including `ListItemsAsync`), `GetSortedMap` (`GetRangeAsync` with `sortKey` lower/upper bounds), and `GetQueue` (`AddAsync`, `ReadAsync` with `waitTimeout` and `invisibilityTimeout` lease expiry, `RemoveAsync`). |
| `EncodingService` | `Base64Encode`, `Base64Decode`, zstd-framed `CompressBuffer` / `DecompressBuffer`, and `ComputeStringHash` / `ComputeBufferHash`. |
| `HttpService` | `JSONEncode`, `JSONDecode`, `GenerateGUID`, and `RequestAsync` (mocked via `env:onHttp(handler)`). |
| `CollectionService` | `AddTag`, `RemoveTag`, `HasTag`, `GetTags`, `GetTagged`, `GetInstanceAddedSignal`, `GetInstanceRemovedSignal`. |
| `TweenService` | `Create` and `GetValue` across numeric, vector, color, `CFrame`, `UDim`, and `UDim2` properties on the virtual clock. |
| `Players` | `PlayerAdded`, `PlayerRemoving`, `GetPlayers`, `GetPlayerByUserId`, `LocalPlayer`, and character helpers. |
| `MarketplaceService` | `ProcessReceipt`, `PromptProductPurchase`, `PromptGamePassPurchase`, `UserOwnsGamePassAsync`, `GetProductInfo` (configured with `env:setGamePass` and `env:setProductInfo`). |
| `TeleportService` | `TeleportAsync`, `ReserveServer`, `TeleportToPrivateServer`, and `GetLocalPlayerTeleportData`. |

---

## UI layout solver and `env:input()`

`sert.env` computes `AbsolutePosition`, `AbsoluteSize`, `AbsoluteCanvasSize`, and `ContentText` in headless Luau across:

- `UIListLayout` and `UIGridLayout` (including `StartCorner`, `FillDirection`, `HorizontalAlignment`, `VerticalAlignment`, and `AbsoluteCellCount`)
- `UIPadding`, `UIScale`, `UISizeConstraint`, `UIAspectRatioConstraint` (`FitWithinMaxSize` and `ScaleWithParentSize`), and `UIFlexItem` grow/shrink distribution
- `AutomaticSize` (`X`, `Y`, `XY`), `ClipsDescendants`, and `ScrollingFrame.CanvasPosition`

Drive keyboard and pointer interactions against laid-out `GuiObject`s and `UserInputService` through `env:input()`:

| Method | Description |
| --- | --- |
| `env:input():press(keyCode)` | Fires `UserInputService.InputBegan` (`gameProcessedEvent` reflects active `TextBox` focus). |
| `env:input():release(keyCode)` | Fires `UserInputService.InputEnded` for `keyCode`. |
| `env:input():move(pos: Vector2)` | Moves the virtual pointer, firing `MouseEnter`, `MouseLeave`, and `MouseMoved` on hovered `GuiObject`s. |
| `env:input():click(target, button?)` | Clicks a `GuiButton` / `GuiObject` or `Vector2` coordinate (respecting `Active`, `Visible`, `ZIndex`, and `ClipsDescendants`), firing `InputBegan`, `MouseButton1Down`, `MouseButton1Up`, `MouseButton1Click`, and `Activated`. |
| `env:input():type(text: string)` | Appends or sets text into the focused `TextBox` and fires `GetPropertyChangedSignal("Text")`. |

```luau
--!strict
local sert = require("@sert")

sert.test("clicking a laid-out button fires Activated", function(ctx)
	local env = sert.env.new({ viewport = Vector2.new(390, 844) })
	ctx:defer(function() env:destroy() end)

	local clicks = 0
	local button: TextButton
	env:run(function()
		local player = env:addPlayer(1, "Tester")
		local gui = Instance.new("ScreenGui")
		gui.Parent = player:WaitForChild("PlayerGui")

		button = Instance.new("TextButton")
		button.Size = UDim2.fromOffset(160, 48)
		button.Position = UDim2.fromOffset(24, 24)
		button.Parent = gui
		button.Activated:Connect(function() clicks += 1 end)
	end)

	env:settle()
	env:input():click(button)
	env:flush()
	sert.eq(clicks, 1)
end)
```
