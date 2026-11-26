# Compatibility & Limitations Matrix (`compatibility.md`)

`sert` targets four execution environments (`luau`, `lute`, `lune`, and Roblox Studio / Open Cloud) across Linux, macOS, and Windows. This page documents what is supported, what `sert.env` models versus stubs, and where real Studio testing remains necessary.

---

## Runtime matrix

| Capability | `luau` (default CLI) | `lute` (`--runner lute`) | `lune` (`--runner lune`) | `sert studio` (cold / `--warm`) | `sert cloud` (Open Cloud) |
| --- | --- | --- | --- | --- | --- |
| `sert.test`, `sert.prop`, `sert.laws`, `sert.model` | Full | Full | Full | Full (`server` / `client` / `edit`) | Full (`server` / `roblox`) |
| `sert.env` headless DataModel & `sert.sim` | Full | Full | Full | N/A (runs in real DataModel) | N/A (runs in real DataModel) |
| Native `--codegen` execution | Yes (default `on`) | No | No | Engine Luau | Engine Luau |
| `luau --coverage` LCOV + `.sert/coverage-map.json` | Yes | No (exit `2`) | No (exit `2`) | No | No |
| `sert mutate` / `sert fuzz` | Yes | Custom `[test]` via `luau` | No | No | No |
| Inline & `.snap` snapshot updates (`-u`) | Yes | Yes (written by Python driver) | Yes | Yes (written by Python driver) | No |
| Multi-client `Players` & `PlayerGui` | Emulated in `sert.env`/`sert.sim` | Emulated in `sert.env`/`sert.sim` | Emulated in `sert.env`/`sert.sim` | Real (`--clients N`, `--mode play`) | Server-only (`run` context) |
| Viewport device emulation & PNG capture | Layout bounds solver only | Layout bounds solver only | Layout bounds solver only | Yes (`--device`, `--capture`) | No |

### `--codegen` vs `codegen = false`

`sert` avoids `getfenv` and `setfenv` throughout `src/` and staged specs so `luau --codegen` stays enabled cleanly:

- **Keep `codegen = true` (default)** for compute-heavy properties, `sert.laws`, `sert.sim.vopr`, `sert.fuzz`, and `sert.bench`.
- **Consider `codegen = false` in `sert.toml`** if your suite has hundreds of lightweight unit assertions and runs in under `0.5 s` cold, where JIT compilation startup outweighs interpreter savings. Override per run with `--codegen` or `--no-codegen`.

---

## Headless `sert.env` fidelity vs Roblox Studio

Every domain marked **Modeled + Conformance** is verified automatically against both headless `sert.env` and real Roblox Studio via `test/roblox/specs/conformance/EngineParity.spec.luau`.

### Modeled services and subsystems

| Subsystem / Service | Status | Verified parity & deliberate boundaries |
| --- | --- | --- |
| `Instance`, lifecycle, Attributes, `Tags` | Modeled + Conformance | `Destroy` fires `Destroying` before child unparenting and locks `Parent`; `Clone` clears refs to `Archivable = false` descendants; `SetAttribute` rejects `Instance`/tables; `NaN -> NaN` suppresses property-change signals; `WaitForChild` wakes on destroy and honors `timeOut = 0`. |
| `RunService` & `Signal` (`Deferred` / `Immediate`) | Modeled + Conformance | Deferred queuing checks `connection.Connected` at dispatch time, enforces the 80-cycle re-entrancy limit, and isolates step frames (`PreRender`, `PreAnimation`, `PreSimulation`, `Stepped`, `PostSimulation`, `Heartbeat`). |
| `DataStoreService` & `OrderedDataStore` | Modeled + Conformance | Key/scope/4 MB limits, strict JSON tree cloning, `DataStoreOptions.AllScopes`, `UpdateAsync` no-yield enforcement and nil-cancel cache preservation, tombstone `RemoveAsync`, and `GetSortedAsync` pagination. |
| `MemoryStoreService` | Modeled + Conformance | `HashMap`, `SortedMap`, and `Queue` with Roblox's `32 KB` value cap, strict `expiry > 0` enforcement, and per-queue `ReadAsync` invisibility leases. |
| `RemoteEvent`, `UnreliableRemoteEvent`, `RemoteFunction` | Modeled + Conformance | Wire sanitization matches Roblox by default (mixed-table non-array keys dropped, sparse arrays truncated at `nil`, metatables stripped, non-replicated `ServerStorage`/`ServerScriptService` instances become `nil`; opt into throwing via `strictRemotes = true`). `UnreliableRemoteEvent` enforces the `900`-byte cap including `buffer.len`. |
| `Workspace` 3D spatial queries | Modeled + Conformance | `Raycast`, `Blockcast`, `Spherecast`, `Shapecast`, `GetPartBoundsInBox`, `GetPartBoundsInRadius`, and `GetPartsInPart` across rotated boxes, spheres, and cylinders, honoring `CanQuery`, `CollisionGroups`, `OverlapParams`, and `BruteForceAllSlow`. No triangle-mesh (`MeshPart`/CSG) intersection. |
| UI layout solver, `GuiService`, `TextService` | Modeled + Conformance | Computes `AbsolutePosition`, `AbsoluteSize`, `AbsoluteCanvasSize`, `AbsoluteRotation`, `AutomaticSize`, `UIListLayout` (including flex & wrap), `UIGridLayout`, `UIPageLayout`, `UIPadding`, `UIScale`, `UISizeConstraint`, `UIAspectRatioConstraint`, `IgnoreGuiInset`/`GetGuiInset`, and deterministic `TextService:GetTextBoundsAsync` monospace metrics (approx real font glyph shaping in Studio). |
| `CollectionService` | Modeled + Conformance | Tag add/remove, `GetAllTags`, and `GetInstanceAddedSignal` / `GetInstanceRemovedSignal` scoped to `DataModel` descendants. |
| `Parallel` (`SharedTable`, `SharedTableRegistry`, `Actor`) | Modeled + Conformance | Enforces `SharedTable` key/value rules (integers/strings, native `vector`, whitelisted datatypes) and throws on parallel-unsafe mutations between `task.desynchronize()` and `task.synchronize()`. Executes deterministically without OS threads. |
| `TweenService`, `EncodingService`, `HttpService`, `PhysicsService`, `Players`, `MarketplaceService`, `TeleportService`, `Audio*` / `Wire`, `InputContext` | Modeled + Conformance | Driven deterministically on `env:advance()`, `env:step()`, `env:input()`, `env:onHttp()`, and `env:setGamePass` / `env:setProductInfo`. Audio DSP produces level/spectrum envelopes from graph topology rather than mixing real audio hardware. |

### Stubbed services in `sert.env`

These services exist in `sert.env` with safe default properties and methods so scripts `game:GetService(...)` without crashing, rather than full backend simulation:

`AssetService`, `AvatarEditorService`, `BadgeService`, `Chat`, `ContentProvider`, `ContextActionService`, `Debris`, `GroupService`, `InsertService`, `LogService`, `MessagingService` (use `sert.sim` for cross-server pub/sub), `PolicyService`, `ReflectionService`, `ScriptContext`, `StarterGui`, `StudioTestService`, `Teams`, `TextChatService`, `UserService`, `VRService`.

### Studio / Open Cloud only (never emulated headlessly)

Run tests with `sert.test.roblox`, `sert.test.server`, or `sert.test.client` when verifying:

- Rigid-body physics, constraints, `AssemblyLinearVelocity`, `BasePart.Touched`, and `Humanoid` state transitions.
- Real `Font` glyph kerning, localized text wrapping, `RichText` font fallback, and viewport pixel screenshots (`--capture`).
- `MeshPart`, `UnionOperation` (CSG), `Terrain` voxel geometry, `EditableImage` / `EditableMesh`, and actual GPU frame pacing.
- Native parallel Actor VM scaling across real worker threads.

---

## Platform, toolchain, and distribution matrix

### Operating systems

| Platform | Headless CLI (`run`, `lint`, `mutate`, `fuzz`) | `sert studio` launcher resolution | Warm Studio (`--warm`) |
| --- | --- | --- | --- |
| Linux | Full (`.sert/bin/sert`) | Flatpak Vinegar (`org.vinegarhq.Vinegar`), native `vinegar studio run` on `PATH`, or `--launcher CMD` (Wine/Proton/umu Z:-path mapping automatic) | `[studio].bridge`, `SERT_STUDIO_BRIDGE`, `STUDIO_LINK`, or `sert-studio-bridge` / `studio-link` on `PATH` |
| macOS | Full (`.sert/bin/sert`) | `/Applications/RobloxStudio.app/Contents/MacOS/RobloxStudio` or `--launcher CMD` | Same portable bridge contract |
| Windows | Full (`.sert/bin/sert.cmd`) | `%LOCALAPPDATA%\Roblox\Versions\*\RobloxStudioBeta.exe` (`pwsh`/`wmic`/`tasklist` PID detection) or `--launcher CMD` | Same portable bridge contract |

### Tool discovery order

`sert` searches for external tools (`luau`, `lute`, `lune`, `rojo`, `selene`, `StyLua`, `luau-lsp`) in order:

1. `<root>/.sert/bin`
2. Current `PATH`
3. Rokit (`$ROKIT_ROOT/bin`, `~/.rokit/bin`)
4. Aftman (`$AFTMAN_HOME/bin`, `~/.aftman/bin`)
5. Mise (`$MISE_DATA_DIR/shims`, `$XDG_DATA_HOME/mise/shims`, `~/.local/share/mise/shims`)

### Distribution modes

- **Full verification toolchain (`tools/sert.py` + `sert.lock`):** Requires Python 3.11+ and gives you all 12 CLI subcommands (`check`, `run`, `lint`, `coverage`, `audit`, `mutate`, `fuzz`, `bench`, `studio`, `cloud`, `init`, `fetch`).
- **Luau-only via Wally or Pesde (`wally.toml`, `pesde.toml`):** Installs `src/` with zero Python requirement for projects using standalone `lute`/`lune`, existing Rojo builds, or in-Studio runners (`sert.roblox.Runner`). Note: Wally's default linker strips `.luaurc` aliases unless you map `@sert` or require the generated Wally package module directly.

---

## Test Impact Analysis (`--affected` and `--watch`) boundaries

`sert run --affected`, `sert check --changed`, and `--watch` track dependencies cleanly across:

- Direct and relative `require(...)` strings, `@self/...`, and `.luaurc` aliases (including `.luaurc` `extends` inheritance).
- Rojo `*.project.json` `$path` trees, `env.game` / `env.workspace` / `env:require(...)` chains, `.meta.json` sidecars, `.snap` files, and `test/.sert-regressions.toml`.
- Dynamic per-spec line hits recorded in `.sert/coverage-map.json` during `--coverage` runs.

**Conservative full-suite fallbacks:** Edits to `sert.toml`, `sert.local.toml`, `.luaurc`, `rokit.toml`, `.config.luau` / `init.config.luau`, `*.project.json`, `test/.sert-regressions.toml`, or `[test].setup` automatically select all specs so configuration changes never under-test a build. Dynamic string construction in `require(variable)` without a static path falls back to `.sert/coverage-map.json`; run `sert run --coverage` once (or `sert check`) after adding heavily dynamic requires.
