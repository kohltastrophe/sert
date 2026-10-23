# The headless environment (`sert.env`)

`sert.env.new(options?)` creates an isolated Roblox environment and DataModel for headless Luau CLI and Lute tests. Each environment has its own `game`, `workspace`, `Instance`, `Enum`, `task`, datatypes, services, `shared`, and `_G` running on a virtual clock.

```luau
local sert = require("@sert")

local function spawnCoin()
	local coin = Instance.new("Part")
	coin.Name = "Coin"
	coin.Parent = workspace
	task.delay(5, function()
		coin:Destroy()
	end)
end

sert.test("a coin despawns after five seconds", function()
	local env = sert.env.new()
	env:run(spawnCoin)
	sert(env.workspace:FindFirstChild("Coin"))
	env:advance(5)
	sert.eq(env.workspace:FindFirstChild("Coin"), nil)
end)

return {}
```

## Options, fields, and methods

### `sert.env.new(options?)`

| Option | Default | Meaning |
| --- | --- | --- |
| `strict` | `false` | Validates class names, members, property types, creatable classes, and `Enum` items against the Roblox API dump. |
| `frameRate` | `60` | Frames per virtual second used by `step` and `advance`. |
| `datatypes` | `sert`'s | Custom datatype table (`Vector3`, `Color3`, `Enum`, `typeof`, etc.). Missing keys fall back to `sert`'s doubles. |
| `isClient`, `isServer`, `isStudio` | `false`, `true`, `false` | `RunService` state. Client environments create `Players.LocalPlayer` and run client render frame phases. |
| `placeId`, `gameId`, `jobId`, `creatorId`, `creatorType` | `1`, `1`, GUID, `1`, `User` | `DataModel` identity properties on `env.game`. |
| `host` | `nil` | External clock hooks `{ clock, unixTime?, spawn?, defer?, delay?, wait?, cancel?, bindClose? }`. |

### Members on `env`

| Category | Member | Description |
| --- | --- | --- |
| **DataModel and globals** | `env.game`, `env.workspace`, `env.Players`, `env.LocalPlayer` | Root `DataModel`, `Workspace`, `Players` service, and `LocalPlayer` (present when `isClient = true`). |
| | `env.Instance`, `env.task`, `env.datatypes` | Environment-bound `Instance` table, virtual `task` scheduler, and datatype constructors. |
| | `env.globals`, `env.shared`, `env._G`, `env.now` | `_ENV` table bound by `env:run`, per-environment `shared` and `_G` tables, and elapsed virtual seconds. |
| **Virtual clock** | `env:step(dt?) -> number` | Advances one frame (`dt` defaults to `1 / env.frameRate`), running due timers and `RunService` phases, and returns `dt`. |
| | `env:advance(seconds) -> number` | Steps frames across `seconds` of virtual time and returns the elapsed time. |
| | `env:flush()` | Runs due `task.defer` threads and timers at `env.now` without advancing the clock. |
| **Code and Rojo trees** | `env:run(fn, ...) -> ...any` | Binds `fn`'s `_ENV` to `env.globals` and calls `fn(...)`. |
| | `env:mount(stage, parent?) -> Instance` | Mounts a staged Rojo tree table (from `.sert/stage`) into the DataModel (defaults to `ReplicatedStorage`, or `env.game` for a `DataModel` root). |
| | `env:require(target, callerScript?) -> any` | Requires a `ModuleScript` inside `env.globals` with a per-environment module cache. |
| **Instances, UI, and signals** | `env:createInstance(class, parent?, bypassAbstract?)` | Creates any API dump class, including abstract and service classes when `bypassAbstract = true` (callable with `.` or `:`). |
| | `env:setAbsolute(gui, size?, pos?)` | Pins `AbsoluteSize` and `AbsolutePosition` on a `GuiBase2d` for headless layout and hit tests. |
| | `env:setViewport(size: Vector2)` | Updates `Workspace.CurrentCamera.ViewportSize`, `PlayerGui`, and active `ScreenGui`s, then recalculates UI layout. |
| | `env:triggerPrompt(prompt, player?, holdDuration?)` | Triggers a `ProximityPrompt` after checking `Enabled` and `MaxActivationDistance`, firing `Triggered` and `ProximityPromptService.PromptTriggered`. |
| | `env:input() -> EnvInput` | Returns an input driver for keyboard, mouse, `GuiButton` clicks, and `TextBox` focus. |
| | `env:signal() -> Signal` | Creates a clock-bound `RBXScriptSignal` double whose `:Wait()` steps `env`. |
| **Players and lifecycle** | `env:addPlayer(userId, name?) -> Player` | Adds a `Player` to `env.Players` and fires `Players.PlayerAdded`. |
| | `env:removePlayer(userIdOrPlayer)` | Removes the player and fires `Players.PlayerRemoving`. |
| | `env.kicks` | Array of recorded `Player:Kick` calls (`{ player, userId, message, at }`). |
| | `env:shutdown()` | Disconnects service connections and runs `game:BindToClose` callbacks. |
| **Service responses** | `env:setBadge(userId, badgeId, owned?)` | Configures `BadgeService:UserHasBadgeAsync` and `AwardBadge` state (`env.badges`). |
| | `env:setGamePass(userId, passId, owned?)` | Configures `MarketplaceService:UserOwnsGamePassAsync` (`env.marketplace`). |
| | `env:setProductInfo(id, info?)` | Sets the table returned by `MarketplaceService:GetProductInfo(id)`. |
| | `env:setGroupRank(userId, groupId, rank, role?)` | Configures `Player:GetRankInGroup`, `GetRoleInGroup`, and `GroupService:GetGroupsAsync` (`env.groups`). |
| | `env:onHttp(handler?)` | Sets `handler(request) -> response` for `HttpService:RequestAsync`, `GetAsync`, and `PostAsync`. |
| | `env:onTextFilter(fn?)` | Sets `fn(text, fromUserId) -> string` for `TextService:FilterStringAsync` and `Chat:FilterStringAsync`. |

`sert.env.active()` returns the most recently created environment in the current test. `sert.waitFor` and `sert.frames` step that environment automatically.

## Virtual clock, frame phases, and `TweenService`

- **Task scheduling:** `task.spawn` runs immediately. `task.defer` queues the thread until the current resumption finishes. `task.wait(s)` parks scheduled threads or advances the clock when called from the test thread. Calling `Signal:Wait()` on the test thread steps three frames at a time (up to `300` s) and throws if nothing is scheduled.
- **Frame phase order:** Due timers (`wait` and `delay`) run first, followed by client `BindToRenderStep` (by priority) and `PreRender` / `RenderStepped`, `PreAnimation`, `TweenService` interpolation, `PreSimulation` / `Stepped(time, dt)`, `PostSimulation`, and finally `Heartbeat(dt)`.
- **`TweenService`:** Interpolates numbers, `Vector2`, `Vector3`, `Vector2int16`, `Color3`, `UDim`, `UDim2`, `CFrame`, and `Rect` using Roblox's `EasingStyle` and `EasingDirection` curves, `DelayTime`, `RepeatCount`, and `Reverses`. Booleans and `EnumItem` properties snap when the tween completes.

## Input (`env:input()`)

```luau
sert.test("clicking a TextBox focuses it and typing updates Text", function()
	local env = sert.env.new({ isClient = true })
	local gui = env.Instance.new("ScreenGui", env.LocalPlayer.PlayerGui)
	local box = env.Instance.new("TextBox", gui)
	box.Size = env.datatypes.UDim2.fromOffset(120, 32)

	local input = env:input()
	input:click(box)
	input:type("hello")
	input:press(env.datatypes.Enum.KeyCode.Return)
	sert.eq(box.Text, "hello")
end)
```

| Call | Effect |
| --- | --- |
| `input:press(keyCode)`, `input:release(keyCode)` | Fires `InputBegan` or `InputEnded`, updates `IsKeyDown`, and releases `TextBox` focus on `Return`. |
| `input:move(pos: Vector2)` | Fires `InputChanged` (`MouseMovement` with `Delta`) and updates `GetMouseLocation`. |
| `input:click(target, button?)` | Clicks a `GuiButton` or `TextBox` instance (checking visibility and interactability), or clicks the topmost GUI object in `LocalPlayer.PlayerGui` at a `Vector2` screen position. |
| `input:type(text)` | Appends `text` to the currently focused `TextBox.Text` (throws if no `TextBox` is focused). |

## Strict mode, staged trees, and modeled classes

Set `[test].stage = "default.project.json"` in `sert.toml` to stage your Rojo tree into `.sert/stage`. You can then mount it with `env:mount(stage)` and require `ModuleScript` instances inside the environment with `env:require`:

```luau
local stage = require("../.sert/stage")

sert.test("loads staged ModuleScript in env", function()
	local env = sert.env.new({ strict = true })
	env:mount(stage)
	local Inventory = env:require(env.game.ReplicatedStorage.Inventory)
	sert.eq(Inventory.capacity(), 20)
end)
```

- **Strict mode (`{ strict = true }`):** Rejects unknown members, services, and `Enum` items, blocks writes to read-only properties, rejects `Instance.new` on non-creatable classes, and validates property types (coercing `int` and `int64` the same way Roblox does). Calling `WaitForChild(name)` without a timeout yields instead of returning `nil`.
- **Modeled classes and services:** Every class in the Roblox API dump is available with `IsA`, default property values, attributes, tags, `Clone`, `Destroy`, and `QueryDescendants(selector)`. Server-to-client replication (`sert.sim`) also syncs Instance attributes (`SetAttribute`) and `CollectionService` tags (`AddTag`/`RemoveTag`). `BasePart` keeps `CFrame` and `Position` in sync and supports approximate AABB spatial queries on `Workspace` (`Raycast`, `GetPartBoundsInBox`, `GetPartBoundsInRadius`, `GetPartsInPart`). `GuiObject` computes `AbsoluteSize`, `AbsolutePosition`, `AbsoluteContentSize`, `AbsoluteCanvasSize`, `TextBounds`, and `TextFits` from `Size`, `Position`, `AnchorPoint`, `AutomaticSize`, `UIListLayout`, `UIGridLayout`, `UIPadding`, `UIScale`, `UISizeConstraint`, and `UIAspectRatioConstraint` (or `env:setAbsolute`). `DataStoreService` and `MemoryStoreService` wrap the engine doubles and expose `:fail(method, msg?)` for fault injection.

## Doubles

Every engine double in `@sert/doubles` (or `sert.doubles`) can also be used standalone without creating a `sert.env`.

| Double | Description |
| --- | --- |
| `Signal` | `Signal.new(clock?)` with `Connect`, `ConnectParallel`, `Once`, `Wait`, `Fire`, `DisconnectAll`, `connections()`, and `connected()`. |
| `Datatypes` | Pure-Luau Roblox datatypes (`Vector2`, `Vector3`, `CFrame`, `Color3`, `UDim2`, `Enum`, `typeof`, `makeEnum`, etc.). |
| `Instance` | `new(class, parent?)`, `createInstance(env, class, parent?, bypassAbstract?)`, `isClass`, and `setAbsolute`. |
| `DataStore` | `DataStore.new({ clock?, budget?, faults? })` with standard and ordered stores, versions, key/value limits, request budgets, and `:fail`. |
| `MemoryStore` | `MemoryStore.new(clock?)` with `HashMap`, `SortedMap`, and `Queue`, expiry, invisibility timeouts, `:step`, `:fail`, `:evict`, `:flush`, `:stored`, and `.conflict`. |
| `HttpService`, `EncodingService` | `JSONEncode` / `JSONDecode`, deterministic GUIDs, Base64, reversible zstd-framed `CompressBuffer`, and deterministic hashes. |
| `Generated` | API dump lookup tables (`superclass`, `isA`, `exists`, `property`, `members`, `creatable`, `isService`, `isAbstract`, `defaultValue`, `enum`, `enumItem`, `classNames`, `enumNames`). |

## Known limitations

- **Physics and collisions:** Parts don't fall under gravity or collide in `sert.env`. Use `sert studio` to test physics.
- **Animations:** `Animator:LoadAnimation` throws in headless mode. Test animations with `sert studio`.
- **Font glyph shaping:** `TextBounds` and `TextFits` use a deterministic character-width model in headless mode. Use `sert studio` for exact font kerning checks.
- **Rendering and audio:** Frames and sounds aren't rendered or played.
