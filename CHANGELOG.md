# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.2.0] - 2026-11-18

### Added

- Multi-path structural table diffs (`format.diff`, up to 8 leaf diffs), canonical snapshot serialization (`format.snapshot`, `sert.inlineSnapshot`, `sert.snapshot`), heap allocation checks (`sert.allocs`, `sert.maxAllocs`, `sert.noAllocs`), benchmark registration (`sert.bench`), `smoke` / `tags` test options, and runtime assertion and tautology tracking (`zeroAssertionTests`, `tautologies`, `skippedByReason`, `--strict-assertions`).
- Hybrid static and dynamic Test Impact Analysis (`--affected` / `--changed` in `sert run` and `sert studio`, backed by `.sert/coverage-map.json`), reverse-offset inline snapshot patching, `.snap` file persistence (`-u`, `--prune-snapshots`), and machine-readable agent output (`--agent`, `SERT_AGENT=1`, `--format json`).
- Compact `v1:<seed>:<size>:<hex>` property tape serialization, `GenContext` guidance and distribution assertions (`g:target`, `g:classify`, `g:cover` with 99% Wilson confidence checks), automatic `test/.sert-regressions.toml` loading and saving (`--save-regressions`), `sert.laws.metamorphic`, and empirical/cost `sert.laws.complexity` checks.
- Concurrent linearizability verification (`sert.sim.linearizable`, `sert.sim.checkLinearizable`, `sert.sim.recorder` with partitioned multi-word bitset search and conflict timelines) and opt-in state-hashed pruning in `Scheduler.explore` and `Sim.explore` (`stateHash = "backing"` or custom hash function, `pruned`).
- New CLI commands and unified flags: `sert check --changed` / `--audit` (closed-loop 4-stage gate), `sert audit` (anti-reward-hacking, tautology, remote-fuzz, and public export checks), `sert fuzz` (overlay edge/comparison greybox fuzzer), `sert bench` (code-generated `ns/op` and `allocKb` baselines with regression gates), and `sert init --agents` / `--skill`.
- Zero-config fastest-spec-first routing, `.sert/mutate/cache.json` verdict caching, and `off_by_one`, `nil_guard`, and `remote_guard` mutation operators in `sert mutate`.
- Expanded `sert.env` engine parity: rotated OBB, ball, and X-cylinder 3D spatial casts (`Raycast`, `Blockcast`, `Spherecast`, `Shapecast`, `GetPartBoundsInBox`, `GetPartsInPart`, `GetPartBoundsInRadius`, `CollisionGroup`, `BruteForceAllSlow`), `InputContext`/`InputAction`/`InputBinding` evaluation wired to `env:input()`, `SharedTable`/`SharedTableRegistry`/`Actor` and `task.desynchronize`/`task.synchronize` strict guards, modern Audio graph nodes (`Wire`, `AudioPlayer`, `AudioEmitter`, `AudioListener`, `AudioFader`, `AudioAnalyzer`, `AudioDeviceOutput`), `UIPageLayout`, and `RichText` tag stripping for `ContentText` and `TextBounds`.
- Dual-target `sert.roblox.conformance` test helper, assertion tracking across `Layout` and `Flicker`, `--warm` Studio bridge attachment (`studio_link.py`, `--studio`, `--capture`), and [the AI agent guide](docs/agents.md).

### Changed

- Updated `sert run --replay` and `RunOptions.replay` to accept shrunk `v1:...` tape tokens in addition to integer seeds, and updated `sert run --failed` to replay stored failure tapes from `.sert/last-failed.json`.
- Extended `sert coverage` LCOV diff parsing to include untracked `.luau` and `.lua` files and glob patterns in `[coverage].include` and `exclude`.

## [0.1.0] - 2026-11-11

### Added

- Procedural `sert.*` assertions (`ok`, `eq`, `ne`, `equals`, `lt`, `le`, `gt`, `ge`, `near`, `matches`, `contains`, `throws`, `doesNotThrow`, `fail`, `waitFor`), nested asymmetric matchers (`any`, `subset`, `within`, `matching`, `exact`), LIFO `rawset` spies (`spy`, `called`, `calledTimes`, `calledWith`), and `--replay` failure commands.
- Byte-tape property testing (`sert.prop`, `sert.gen`), `0.0`-first `boundaryFloat` and `remotePayload` generators, algebraic law suites (`sert.laws`), and stateful model checking (`sert.model`).
- Strict-by-default headless Roblox environment (`sert.env.new()`) with deferred signals, virtual clock frames, UI container layout geometry, `env:input()`, `DataStoreService`, `MemoryStoreService`, and `function(_ENV)` lexical `@game` staging.
- Deterministic multi-server and multi-client VOPR fault simulation (`sert.sim.vopr`, `sert.sim.check`, `sert.sim.explore`) over real `RemoteEvent` instances with packet faults, cloud storage hazards, rolling `BindToClose` shutdowns, and portable `v1:...` replay tokens.
- Zero-boilerplate Roblox Studio (`sert studio`) and Open Cloud (`sert cloud`) runners with `.roblox`/`.server`/`.client` target tags, `--device` viewport emulation, `--clients` multi-player sessions, `--warm` live Studio reloads, `Layout` audits, `Flicker` stability checks, `fuzzRemote`, and LIFO `sweep` cleanup.
- Stdlib Python 3.11+ CLI (`init`, `fetch`, `lint`, `run`, `coverage`, `mutate`, `check`, `studio`, `cloud`), SHA-256 `sert.lock` verification, dual-solver positive and `-- expect-error` negative type probes, pure-Python `luau_lex` token-stream mutation testing, reproducible `pack.py` archives, and `kohltastrophe/sert/actions/setup@v0.1.0`.

[0.2.0]: https://github.com/kohltastrophe/sert/releases/tag/v0.2.0
[0.1.0]: https://github.com/kohltastrophe/sert/releases/tag/v0.1.0
