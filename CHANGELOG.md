# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.2.0] - 2026-11-11

### Added

- Add assertions, matchers, spies, and test runner. ([2f0f322](https://github.com/kohltastrophe/sert/commit/2f0f32299d4aeef5c8af0a25051419c1de63a9e4))
- Add headless Roblox engine, datatypes, and virtual environment. ([859145c](https://github.com/kohltastrophe/sert/commit/859145c07ee3e8225b82bdd6d681aa6a0b618d2e))
- Add property shrinker, laws, models, VOPR simulation, and Studio helpers. ([1b1708f](https://github.com/kohltastrophe/sert/commit/1b1708f888b835b2107869615e8e6fb778d24fa1))
- Add stdlib CLI, lockfile fetcher, Luau lexer mutator, and pack. ([2e259f3](https://github.com/kohltastrophe/sert/commit/2e259f338d1554baf1876bfac131d1496d8efe70))

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
