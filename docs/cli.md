# CLI & Configuration Reference (`cli.md`)

Run `sert` through the committed repository wrapper (`python3 tools/sert.py <command>`, or `python tools/sert.py <command>` on Windows) or `.sert/bin/sert` after `sert fetch`.

### Global flags and exit codes

- `--version` prints `sert <version>`.
- `--root DIR` overrides the project root (defaults to `$SERT_ROOT`, else the nearest ancestor containing `sert.toml`, else `git rev-parse --show-toplevel`).

`sert` discovers tools (`luau`, `lute`, `lune`, `rojo`, `selene`, `StyLua`, `luau-lsp`) in `.sert/bin`, `PATH`, Rokit (`~/.rokit/bin`), Aftman (`~/.aftman/bin`), and Mise shims (`~/.local/share/mise/shims`). Set `SERT_AGENT=1` to default compatible subcommands (`check`, `run`, `lint`, `coverage`, `mutate`, `audit`, `bench`, `fuzz`, `studio`, `cloud`) to compact agent output, or `SERT_COMPACT=1` to suppress passing test lines. Every subcommand returns exit `0` when passed, `1` on test or quality gate failure, `2` on configuration, usage, or infrastructure error, `3` on timeout, and `130` on `SIGINT`.

---

## Commands

### `sert init`

Scaffolds `sert.toml`, `rokit.toml` (`luau = "luau-lang/luau@0.724"`, `rojo`, `selene`, `StyLua`, `luau-lsp`), `tools/sert.py`, `.luaurc`, `.gitignore`, and `test/example.spec.luau`.

| Flag | Description |
| --- | --- |
| `--force` | Overwrites existing scaffolded files (including `SKILL.md`). |
| `--fetch` | Runs `sert fetch` immediately after scaffolding to write `sert.lock` and populate `.sert/`. |
| `--agents` | Writes `.agents/skills/sert/SKILL.md` for AI coding agents. |
| `--skill [DIR]` | Writes `SKILL.md` into `DIR` (default `.agents/skills/sert/`) without full project scaffolding. |
| `--stdout` | Prints `SKILL.md` to stdout without writing files. |
| `--json` | Emits the machine-readable subcommand, flag, and API schema as JSON. |

### `sert fetch`

Downloads `sert-<version>.pyz`, `sert-<version>.zip` (extracted to `.sert/sert/`), and `globalTypes.d.luau` (matched to your `luau-lsp` version in `rokit.toml`), updates `sert.lock` with SHA-256 digests, writes `.sert/bin/sert`, and merges `"sert": "./.sert/sert/src"` into `.luaurc` while preserving JSONC comments and trailing commas.

| Flag | Description |
| --- | --- |
| `--only sert,types` | Restricts fetching to `sert`, `types`, or both. |
| `--offline` | Verifies existing `.sert/` caches against `sert.lock` without network requests. |
| `--json` | Emits resolved paths and digests as JSON. |

### `sert lint`

Runs up to seven static checks in parallel: `sourcemap` (`rojo sourcemap`, cached in `.sert/sourcemap.json`), `analyze` (`luau-lsp analyze` across both `"new"` and `"old"` Luau type solvers in parallel), `types`, `stylua`, `selene`, `extra` (`[lint].extra`), and `stub` (`[lint].stub` parity against `tools/sert.py`). Works zero-config without `sert.toml` when `src/`, `test/`, `tests/`, or `default.project.json` exist. The `types` check verifies positive probes and `-- expect-error` negative probes across every configured solver.

| Flag | Description |
| --- | --- |
| `--fix` | Formats files in place (`stylua` instead of `stylua --check`). |
| `--dry-run` | Prints planned tool commands without executing them. |
| `--only CHECK ...` / `--skip CHECK ...` | Filters checks (`sourcemap`, `analyze`, `types`, `stylua`, `selene`, `extra`, `stub`). |
| `--agent` / `--format human\|agent\|json` | Emits agent summary or a single JSON envelope with structured diagnostics. |

Negative type probes (`[types].fail` globs) mark expected type errors inline with `-- expect-error` (or `-- expect-error: substring`). `sert lint` verifies that every marked line produces a diagnostic under **every** configured solver and that no unmarked lines fail. Under `[lint].solvers = ["new", "old"]`, annotate literal unions on local tables and arrays so the old type solver does not widen bare literals past the union type.

### `sert run`

Discovers specs matching `[test].specs`, compiles `[test].stage` if configured, auto-loads `test/.sert-regressions.toml` and `test/__snapshots__/**/*.snap`, and executes specs across parallel worker shards (`--codegen` is enabled by default on standalone `luau`).

| Flag | Description |
| --- | --- |
| `[specs...]` / `--file FILE` | Restricts execution to matching spec paths or basenames. |
| `--affected [REV]` / `--changed [REV]` | Runs only specs impacted by git diff against `REV` (default `HEAD`) using cached static `require`/Rojo/`.luaurc` graph analysis and `.sert/coverage-map.json`. |
| `--runner luau\|lute\|lune` | Selects the standalone Luau runtime (default `luau`). |
| `--codegen` / `--no-codegen` | Enables (default) or disables native Luau code generation (`luau --codegen`). |
| `--roblox-globals` | Installs `Vector3`, `CFrame`, `Color3`, `UDim2`, `Enum`, and `typeof` into headless spec globals. |
| `--coverage` | Collects `luau --coverage` data, writes `coverage.out`, and records per-spec line coverage in `.sert/coverage-map.json`. |
| `-j, --jobs N` | Parallel shard count (`>= 1`; defaults to CPU core count, or `1` under `--coverage`). |
| `--filter SUBSTR` / `-g, --grep PAT` | Runs tests matching case-insensitive substring(s) or repeatable Luau string patterns (`%d+`, `%s`). |
| `--exclude SUBSTR` | Excludes tests matching substring(s). |
| `--failed` | Re-runs failures from `.sert/last-failed.json`, replaying stored failure seeds and shrunk tapes. |
| `--watch` | Polls `.luau`, `.lua`, `.snap`, `.meta.json`, `.project.json`, `.luaurc`, and `sert.toml` (`0.25 s`) and re-runs only TIA-affected specs. |
| `--shuffle` | Randomizes test execution order deterministically (prints `--seed` for replay). |
| `--repeat N` / `--retry N` | Runs the selected tests `N` times, or retries failing tests up to `N` times and marks recovered passes as `flaky`. |
| `--slowest N` | Prints the `N` slowest tests (`>= 1`). |
| `--timeout S` / `--test-timeout S` | Shard wall-clock timeout and per-test timeout in seconds. |
| `--seed N\|random` / `--runs N` / `--replay N\|TOKEN` | Overrides property base seed or shuffle seed, trial count, or replays one counterexample seed or `v1:...`/`v2:...` tape token. |
| `--exhaustive` / `--budget S` | Runs bounded-exhaustive properties within an optional wall-clock budget. |
| `-u, --update-snapshots` / `--prune-snapshots` | Writes inline and `.snap` snapshot updates or removes unused `.snap` keys/files (rejected under `--ci` or `CI=true`). |
| `--strict-assertions` | Fails any test that finishes with zero recorded assertions unless marked `{ smoke = true }`. |
| `--save-regressions` | Persists failing `[sert-x:regression]` tokens into `test/.sert-regressions.toml`. |
| `--bench` | Executes registered `sert.bench` benchmarks alongside specs. |
| `--allow-focused` / `--ci` | Permits `.focus` tests under CI, or forces CI checks locally. |
| `-x, --fail-fast` / `--compact` / `--list` | Stops on first failure, condenses output, or lists matching test names without running them. |
| `--agent` / `--format human\|agent\|json` | Selects terminal, token-compact agent, or structured JSON envelope output (`data` / `summary`). |
| `--junit FILE` / `--json-out FILE` | Writes JUnit XML or structured JSON results. |

### `sert audit`

Detects test reward-hacking and uncovered public exports using `luau_lex` static analysis and runtime telemetry (`.sert/last-telemetry.json`):

| Flag | Description |
| --- | --- |
| `--diff [REV]` | Scopes export and remote checks to changes since `REV` (default `HEAD`) while scanning specs covering changed `src/` files. |
| `--strict` | Fails with exit `1` when public module exports (`M.foo`, including single-line functions) have `0` hits or explicit `sert.test.skip` calls exist. |
| `--allow-unfuzzed-remotes` | Waives per-handler `.OnServerEvent` / `.OnServerInvoke` remote checks missing `fuzzRemote` or `remotePayload` coverage. |
| `--no-run` / `--run-output FILE` / `--coverage-file FILE` | Reuses `.sert/last-telemetry.json`, captured output markers, or an alternate `coverage.out`. |
| `--agent` / `--format human\|agent\|json` | Emits agent summary or JSON envelope. |

### `sert fuzz`

Coverage-guided greybox fuzzer using an isolated `.sert/fuzz/overlay/` hardlink worktree instrumented with edge (`__SERT_FUZZ_EDGE`) and relational comparison (`__SERT_FUZZ_CMP`) probes:

| Flag | Description |
| --- | --- |
| `[specs...]` / `--file FILE` / `--filter SUBSTR` / `-g, --grep PAT` | Restricts which property specs are fuzzed. |
| `--budget SEC` / `--runs N` / `--seed N` | Controls wall-clock budget (default `5.0` s), fixed trial count, and PRNG seed. |
| `--dict FILE` / `--corpus DIR` | Supplies extra dictionary tokens (JSON or line-separated) and corpus seed directory (default `.sert/fuzz/corpus`). |
| `--no-save-regressions` | Skips saving shrunk `v1:...` counterexamples into `test/.sert-regressions.toml`. |
| `--agent` / `--format human\|agent\|json` | Emits agent summary or JSON envelope. |

### `sert bench`

Executes `sert.bench` registrations with `luau --codegen` enabled and tracks both median `ns/op` and `allocKb` baselines under `.sert/bench/<NAME>.json`:

| Flag | Description |
| --- | --- |
| `[specs...]` / `--filter SUBSTR` / `-g, --grep PAT` | Filters which benchmark specs run. |
| `--save NAME` / `--compare NAME` | Saves a baseline to `.sert/bench/NAME.json` or compares against an existing one. |
| `--fail-regression PCT` | Regression failure threshold percentage for `medianNs` and `allocKb` (default `20.0`). |
| `--timeout S` / `-j, --jobs N` / `--agent` / `--format human\|agent\|json` | Entry timeout, worker concurrency, and output formatting. |

### `sert coverage`

Parses an LCOV tracefile (`coverage.out`), prints per-file line and function hit percentages, appends a Markdown summary when `$GITHUB_STEP_SUMMARY` is set, and enforces minimum line coverage (supporting globs in `[coverage].include` / `exclude`).

| Flag | Description |
| --- | --- |
| `[FILE]` | Path to LCOV file (defaults to `"coverage.out"`). |
| `--min N` | Minimum line coverage percentage (`0–100`, overrides `[coverage].min`). |
| `--uncovered` | Lists uncovered line ranges (`L12-L18`) for each file. |
| `--diff [REV]` | Computes and gates coverage exclusively on lines added or modified relative to `REV` (including untracked `.luau` / `.lua` files). |
| `--badge [FILE]` | Writes a Shields.io endpoint JSON file (defaults to `[coverage].badge` or `"coverage.json"`). |
| `--agent` / `--format human\|agent\|json` | Emits concise agent output or JSON envelope. |

### `sert mutate`

Scores test thoroughness by lexing target `.luau` files with `sert`'s pure-Python Luau lexer (`luau_lex`), leaving comments, string literals, and type annotations untouched. `sert mutate` builds a zero-copy hardlink overlay in `.sert/mutate/overlay/` without modifying your working tree, routes each `(file, line)` automatically via `.sert/coverage-map.json` (fastest covering spec first, falling back to static reachability without needing `[mutate.specs]`), caches verdicts in `.sert/mutate/cache.json`, and switches active mutants via `@__SERT_MUTANT`.

Built-in operators cover `stmt_del` (statement deletion), `ret_val` (return value replacement), `cond_inv` (`if`/`elseif` inversion), `rel_flip` (`==`/`~=`, `<`/`<=`/`>`/`>=`), `arith_op` (`+`/`-`, `*`/`/`), and `logic_op` (`and`/`or`). Four more operators target common Luau edge cases: `math_fn` (`math.min`/`max`, `floor`/`ceil`), `off_by_one` (`+ 1`/`- 1`), `nil_guard` (`~= nil`/`if not`), and `remote_guard`. Results report `KILLED`, `SURVIVED`, and `TIMEOUT` separately.

| Flag | Description |
| --- | --- |
| `[paths...]` | Target files or globs (overrides `[mutate].include`). |
| `--diff [REV]` | Mutates only lines added or modified since `REV` (including untracked `.luau` files). |
| `--min N` | Minimum mutation score percentage `(killed + timeout) / total * 100`. |
| `--operators a,b,...` | Comma-separated subset of operators to enable. |
| `--max-mutants N` | Deterministic sample cap when bounding CI runtime (`0` = unlimited). |
| `-j, --jobs N` / `--timeout S` | Worker concurrency and per-mutant timeout (auto-scaled to 3.5x baseline when `0`). |
| `--coverage-file FILE` / `--no-coverage-run` | Reuses an existing LCOV file or skips baseline coverage pruning. |
| `--no-cache` / `--strict-cache` | Ignores cached mutant verdicts, or verifies cache keys including transitive dependencies and config files. |
| `--agent` / `--format human\|agent\|json` | Emits concise agent output or JSON envelope. |

### `sert check`

Runs `sert lint` and `sert run --coverage` concurrently, enforces `sert coverage` (`[coverage].min`), and optionally runs the 4-stage closed-loop gate (`audit`, `mutate`, and `studio` escalation) under `--changed` or `--audit`:

| Flag | Description |
| --- | --- |
| `--changed [REV]` | Runs TIA-affected tests plus `coverage --diff --uncovered`, `audit`, incremental `mutate --diff` (on covered modified `src/` lines), and `studio` escalation when `roblox`/`server`/`client` specs skip. Defaults `REV` to `HEAD`. |
| `--diff [REV]` | Scopes `coverage` and `audit` checks to lines added or modified since `REV` (default `HEAD`). |
| `--audit` / `--no-audit` | Enables or skips the `sert audit` stage (enabled automatically by `--changed` or `--strict`). |
| `--mutate` / `--no-mutate` | Enables or skips incremental `sert mutate --diff` (enabled automatically by `--changed`). |
| `--strict` | Fails audit on uncovered public exports (`M.foo`) and explicit skips; implies `--audit`. |
| `--allow-unfuzzed-remotes` / `--allow-skipped-targets` | Waives missing remote fuzz coverage in `audit`, or waives `--no-studio` failure when engine-targeted specs were skipped. |
| `--studio` / `--no-studio` / `--studio-id ID` | Runs `[studio]` checks (`--studio`), forbids launching Studio (`--no-studio`), or pins a warm Studio session (`--studio-id ID`; falls back from `--warm` to cold headless `sert studio` only on bridge exit `2`). |
| `--fix` / `--watch` / `--uncovered` / `--compact` | Formats with StyLua first, re-runs on edits (pair with `--changed` for TIA re-verification), prints missed coverage lines, and suppresses passing test lines. |
| `--timeout S` / `-j, --jobs N` / `--ci` | Entry timeout, parallel worker limit, and strict CI mode. |
| `--agent` / `--format human\|agent\|json` | Selects compact agent summary or JSON envelope output (preserving exit codes `0/1/2/3`). |

### `sert studio` and `sert cloud`

- **`sert studio`:** `--mode edit|play|run`, `--device PRESET`, `--clients N`, `--warm`, `--studio / --studio-id ID`, `--capture`, `--affected [REV]`, `--suite NAME`, `--check`, `--side server|client`, `--filter`, `-g/--grep`, `--exclude`, `--file`, `--failed`, `--list`, `--shuffle`, `--repeat N`, `--retry N`, `--seed`, `--runs`, `--replay`, `--exhaustive`, `--budget`, `--test-timeout`, `--deadline`, `--timeout`, `-u/--update-snapshots`, `--prune-snapshots`, `--strict-assertions`, `--save-regressions`, `--bench`, `--ci`, `--allow-focused`, `-x/--fail-fast`, `--compact`, `--slowest N`, `--keep`, `--launcher PATH`, `--agent`, `--format human|agent|json`, `--json-out FILE`, `--junit FILE`.
- **`sert cloud`:** `--project FILE`, `--script FILE`, `--place FILE`, `--place-version N`, `--output FILE`, `--shard NAME`, `-j/--jobs N` (default `8`, max `10`), `--timeout S`, `--json-out FILE`, `--junit FILE`, `--agent`, `--format human|agent|json`, `--unsharded`, `--dry-run`, `--emit DIR` (requires `--dry-run`).

---

## `sert.toml` and `sert.lock`

`sert.local.toml` (gitignored) deep-merges over `sert.toml` for machine-local tweaks.

| Section | Key settings |
| --- | --- |
| `[sert]` | `version = "0.3.0"`, `repo = "kohltastrophe/sert"` |
| `[test]` | `specs = ["test/**/*.spec.luau"]`, `entries = []`, `runner = "luau"`, `codegen = true`, `setup = ""`, `stage = ""`, `globals = ""`, `jobs = <CPU count>`, `timeout = 120`, `repeat = 1`, `slowest = <unset>`, `allow_focused = false` |
| `[studio]` | `project = "default.project.json"`, `specs = [...]`, `mode = "play"`, `device = ""`, `clients = 1`, `warm = false`, `studio = ""`, `bridge = ""`, `capture = false`, `sides = [...]`, `timeout = 900`, `out = "build/sert"`, `hooks = ""`, `config = ""`, `runner = ""`, `[studio.suites.<name>]` |
| `[cloud]` | `project = ""`, `specs = [...]`, `script = ""`, `shards = []`, `shard_limit = 0`, `jobs = 8`, `max_workers = 10`, `timeout = 300` |
| `[lint]` | `paths = ["src", "test"]`, `project = "default.project.json"`, `solvers = ["new", "old"]`, `ignore = []`, `stylua = true`, `selene = true`, `stub = true`, `extra = []`, `[[lint.analyze]]` |
| `[types]` | `pass = ["test/types"]`, `fail = ["test/types/fail"]`, `solvers = []` |
| `[coverage]` | `file = "coverage.out"`, `include = ["src"]`, `exclude = []`, `min = 80`, `badge = "coverage.json"` |
| `[mutate]` | `include = ["src"]`, `exclude = []`, `specs = {}` (optional override; defaults to automatic coverage-map routing), `operators = []`, `codegen = true`, `cache = "scoped"`, `min = 0`, `timeout = 0`, `jobs = 0`, `max_mutants = 0`, `benign_calls = []`, `cosmetic_props = []` |
| `[override]` | `sert = "../sert"` (local dev only; fails automatically when `CI=true`) |
| `[release]` | Release metadata pass-through table (for example `kohltastrophe/release` version sync rules) |

`sert.lock` is a TOML lockfile (`schema = 1`) recording exact URLs and SHA-256 hashes for `[assets."sert.pyz"]`, `[assets."sert.zip"]`, and `[assets."globalTypes.d.luau"]`. Commit `sert.lock` alongside `sert.toml` and `tools/sert.py`.
