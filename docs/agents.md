# AI Agent Guide (`agents.md`)

`sert` ships a closed-loop verification workflow built for AI coding agents. Every test, audit, fuzzer, and mutation check runs from one entrypoint with deterministic replay tokens, structured JSON or compact agent output, and automatic Test Impact Analysis (TIA).

## Quickstart workflow

Scaffold the agent skill file into a repository once, then run `check --changed` after each edit:

```bash
python3 tools/sert.py init --agents
python3 tools/sert.py check --changed --agent
```

`sert init --agents` writes `.agents/skills/sert/SKILL.md` (pass `--force` to overwrite an existing skill). Run `sert init --stdout` to print the skill text to stdout, `sert init --skill DIR` to write it into another tool directory without scaffolding project files, or `sert init --json` to dump the machine-readable CLI schema (`version`, `skill_path`, `formats`, `exit_codes`, `commands`).

## Closed-loop verification (`sert check`)

`sert check` runs `sert lint`, `sert run --coverage`, and the configured coverage floor in parallel. Adding `--changed [REV]` (or `--audit` / `--strict`) expands it into a four-stage closed-loop gate that exits early on hard failures:

1. **Lint and impacted tests:** runs `sert lint` (StyLua, Selene, Luau analyze, and `.stub` checks) concurrently with `sert run --affected [REV] --coverage` (under `--changed`, defaulting `REV` to `HEAD`, or the full suite under `sert check --audit`).
2. **Diff coverage and audit:** runs `sert coverage` (with `--diff REV --uncovered` when a revision is supplied) and `sert audit` against Stage 1 telemetry (`coverage.out` and `.sert/last-telemetry.json`).
3. **Incremental mutation testing:** under `--changed` or `--mutate`, runs `sert mutate --diff` against covered, modified lines under `src/` unless `--no-mutate` is passed or zero covered source lines changed.
4. **Engine target fallback:** under `--changed`, when Stage 1 skips `roblox`, `server`, or `client` specs (`skippedByReason`), runs `sert studio --warm` (`--studio-id ID` pins an open Studio session) and falls back to cold headless `sert studio` only on a bridge infrastructure error (exit `2`). With `--no-studio`, exits `1` and prints the exact `sert studio` follow-up command unless `--allow-skipped-targets` is set.

Pass `sert check --audit` (or `sert check --audit --diff REV`) to verify the full suite, `--strict` to fail audit on uncovered public exports, and `--allow-unfuzzed-remotes` to waive remote fuzz checks. You can also pass `-j N` (`--jobs N`), `--timeout S` per entry, and `--ci` for strict CI rules.

## Agent and JSON output modes

| Output switch | Effect |
| --- | --- |
| `--agent` or `SERT_AGENT=1` | Strips passing noise, emits `OK` or `FAIL` headers, adds 3-line stack snippets, and prints snapshot diffs and `regressions = { "v1:..." }` hints |
| `--format json` | Emits one JSON envelope `{ version: 1, command, status, exit_code, summary, errors, data }` to stdout (`status` is `"ok"`, `"failed"`, or `"error"`) |
| `--format human` | Restores colored terminal output even when `SERT_AGENT=1` is exported |

Precedence is `--format`, then `--agent`, then `SERT_AGENT=1` (`1`, `true`, `yes`, or `on`), then `human`. Passing `--format json` or `--agent` works on `check`, `run`, `coverage`, `mutate`, `audit`, `bench`, `fuzz`, and `studio`.

When tests fail, replay only the failing tests with their shrunk `v1:...` tapes or case seeds saved in `.sert/last-failed.json`:

```bash
python3 tools/sert.py run --failed --agent
```

## Test Impact Analysis (`--affected`)

Passing `--affected [REV]` (or `--changed [REV]`, default `HEAD`) to `sert run`, `sert check`, or `sert studio` builds a hybrid impact graph. Static analysis parses `require(...)` strings, Rojo `*.project.json` `$path` mappings, and `.luaurc` aliases (with `extends` inheritance), while dynamic coverage reads per-spec line maps recorded in `.sert/coverage-map.json` during `--coverage` runs.

Edits to global files (`sert.toml`, `sert.local.toml`, `.luaurc`, `rokit.toml`, `.config.luau`, `init.config.luau`, `*.project.json`, or `[test].setup`) invalidate the cache and select all specs. If zero specs are impacted by a non-Luau edit, `sert run --affected` exits `0` immediately.

## Runtime tiers (`run` -> `studio --warm` -> `cloud`)

| Tier | Command | Targets covered | Speed and fidelity |
| --- | --- | --- | --- |
| 1. Headless Luau | `sert run` | `portable`, `sert.env`, `sert.sim` | Sub-second execution under `luau --codegen` with deterministic virtual clocks and modeled DataModel |
| 2. Warm Studio | `sert studio --warm` | `roblox`, `server`, `client` | Attaches to an open Studio instance via `studio_link.py` and reloads cloned `ModuleScript`s without a cold boot |
| 3. Cold Studio | `sert studio` | `roblox`, `server`, `client` | Launches headless Studio (`--mode edit\|play\|run`); multi-client play and viewport screenshots (`--device`, `--capture`) |
| 4. Open Cloud | `sert cloud` | `server`, `roblox` | Runs sharded specs in Roblox Luau Execution over HTTPS (`ROBLOX_API_KEY`) |

`--warm` locates `studio_link.py` from `SERT_STUDIO_BRIDGE`, `STUDIO_LINK`, the repository `scripts/` directory, or `~/.agents/skills/roblox-dev/scripts/studio_link.py`. Configure `[studio] warm = true` or `studio = "ID"` in `sert.toml` to make warm attachment the default locally.

## Zero-config mutation testing (`sert mutate`)

`sert mutate` works without manual `[mutate.specs]` entries. When `[mutate.specs]` does not override a file, `sert` queries `.sert/coverage-map.json` for every spec that executed the mutated line, orders candidates fastest first (`ms`), and stops as soon as the first spec kills the mutant. Static `require` graph reachability supplies fallback specs for uncovered lines.

Mutation runs ten operators (`stmt_del`, `ret_val`, `cond_inv`, `rel_flip`, `arith_op`, `logic_op`, `math_fn`, `off_by_one`, `nil_guard`, and `remote_guard`) and caches results in `.sert/mutate/cache.json` keyed by normalized file tokens, line, operator, covering spec hashes, and `sert` version. Pass `--diff` to test only modified lines or `--no-cache` to bypass cached verdicts.

## Greybox fuzzing and permanent regressions (`sert fuzz`)

```bash
python3 tools/sert.py fuzz --budget 10 --agent
```

`sert fuzz` copies the project into a temporary hardlink overlay under `.sert/fuzz/overlay/`, adds line-preserving edge (`__SERT_FUZZ_EDGE`) and relational comparison (`__SERT_FUZZ_CMP`) probes, extracts string and number constants to `.sert/fuzz/dict.json`, and evolves byte-tape seeds in `.sert/fuzz/corpus` (override with `--corpus DIR` or `--dict FILE`). Control termination with `--budget SEC` (default `5.0`), `--runs N`, or `--seed N`, and filter specs with positional paths, `--filter`, `-g/--grep`, or `--file`.

When a property, `sert.model`, or `sert.sim.vopr` run fails, `sert fuzz` shrinks the counterexample to a deterministic `v1:<seed>:<size>:<hex>` tape and records a `[[regression]]` entry (`test`, `file`, `token`) in `test/.sert-regressions.toml` (suppress with `--no-save-regressions`). Both `sert run` and `sert studio` load `test/.sert-regressions.toml` automatically into `RunOptions.regressions` and replay every saved token before generating fresh cases. Passing `--save-regressions` on `sert run` or `sert studio` captures new failure tapes too.

## Snapshots (`-u` and `--prune-snapshots`)

Use `sert.inlineSnapshot(value, expected?, msg?)` for short deterministic structures stored directly in the spec, or `sert.snapshot(value, name?, msg?)` for larger outputs saved under `test/__snapshots__/<spec_stem>.snap`. Tables serialize with sorted keys, and `Instance` values render deterministically with sorted attributes and `GuiBase2d` layout bounds.

Update changed or missing snapshots with `-u` / `--update-snapshots`, and delete stale keys or `.snap` files with `--prune-snapshots`. Both `sert run` and `sert studio` reject `-u` and `--prune-snapshots` when `--ci` or `CI=true` is set. Always review inline and `.snap` diffs before committing so snapshots never ratify broken output.

## Anti-reward-hacking rules (`sert audit` and `--strict-assertions`)

Passing `sert run` alone does not prove tests verify behavior. Enable `--strict-assertions` on `sert run` or `sert studio` to fail any test with zero recorded assertions, and run `sert audit [--diff [REV]]` (or `sert check --audit` / `sert check --changed`) to catch four failure modes:

| Check | What triggers a failure or warning | Approved fix |
| --- | --- | --- |
| `zeroAssertionTests` | A test completes with `0` assertions recorded (`sert.*`, `Layout.*`, `Flicker.expect`, `sert.sim.linearizable`, `sert.sim.check`, `sert.sim.explore`, `sert.sim.verifyTrace`) | Add real behavioral assertions, or mark genuine crash-only smoke tests `{ smoke = true }` |
| Static tautologies | `sert.eq(a, a)`, `sert.ok(true)`, `sert.ne(literal, nil)` outside `throws`, or identical subexpressions | Compare against independently expected values computed from inputs or a reference oracle |
| Vacuous or covered-out properties | Every property run discarded via `g:assume` / `prop.vacuous`, or `g:cover` misses its 99% Wilson upper bound | Broaden generators or fix unreachable branch weights instead of loosening conditions |
| Unfuzzed remotes and dead exports | Changed `.OnServerEvent:Connect`/`:Once` or `.OnServerInvoke` without `sert.roblox.fuzzRemote` / `sert.gen.remotePayload` coverage, or uncovered `M.foo` exports (`--strict`) | Add adversarial payload fuzz specs (use `--allow-unfuzzed-remotes` only when a handler is proven unreachable or audited separately) |

Never delete saved entries from `test/.sert-regressions.toml` to turn a failing suite green, and never wrap a failing assertion in `pcall` to hide a regression.
