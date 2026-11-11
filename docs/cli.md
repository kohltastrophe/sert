# CLI & Configuration Reference (`cli.md`)

Run `sert` through the committed repository wrapper (`python3 tools/sert.py <command>`, or `python tools/sert.py <command>` on Windows) or `.sert/bin/sert` after `sert fetch`.

### Global flags and exit codes

- `--version` — prints `sert <version>`.
- `--root DIR` — project root override (defaults to `$SERT_ROOT`, `git rev-parse --show-toplevel`, or the nearest ancestor containing `sert.toml`).

Every subcommand uses consistent exit codes: `0` passed, `1` test or quality gate failed, `2` configuration, usage, or infrastructure error, `3` timeout, `130` interrupted (`SIGINT`).

---

## Commands

### `sert init`

Scaffolds `sert.toml`, `rokit.toml` (`luau = "luau-lang/luau@0.724"`, `rojo`, `selene`, `StyLua`, `luau-lsp`), `tools/sert.py`, `.luaurc`, `.gitignore`, and `test/example.spec.luau`.

| Flag | Description |
| --- | --- |
| `--force` | Overwrites existing scaffolded files. |
| `--fetch` | Runs `sert fetch` immediately after scaffolding to write `sert.lock` and populate `.sert/`. |

### `sert fetch`

Downloads `sert-<version>.pyz`, `sert-<version>.zip` (extracted to `.sert/sert/`), and `globalTypes.d.luau` (matched to your `luau-lsp` version in `rokit.toml`), updates `sert.lock` with SHA-256 digests, writes `.sert/bin/sert`, and merges `"sert": "./.sert/sert/src"` into `.luaurc` while preserving JSONC comments and trailing commas.

| Flag | Description |
| --- | --- |
| `--only sert,types` | Restricts fetching to `sert`, `types`, or both. |
| `--offline` | Verifies existing `.sert/` caches against `sert.lock` without network requests. |
| `--json` | Emits resolved paths and digests as JSON. |

### `sert lint`

Runs up to seven static checks in parallel: `sourcemap` (`rojo sourcemap`), `analyze` (`luau-lsp analyze` across both `"new"` and `"old"` Luau type solvers by default), `types`, `stylua`, `selene`, `extra` (`[lint].extra`), and `stub` (`[lint].stub` parity against `tools/sert.py`). The `types` check verifies positive probes and `-- expect-error` negative probes across every configured solver.

| Flag | Description |
| --- | --- |
| `--fix` | Formats files in place (`stylua` instead of `stylua --check`). |
| `--dry-run` | Prints planned tool commands without executing them. |
| `--only CHECK ...` / `--skip CHECK ...` | Filters checks (`sourcemap`, `analyze`, `types`, `stylua`, `selene`, `extra`, `stub`). |

Negative type probes (`[types].fail` globs) mark expected type errors inline with `-- expect-error` (or `-- expect-error: substring`). `sert lint` verifies that every marked line produces a diagnostic under **every** configured solver and that no unmarked lines fail.

### `sert run`

Discovers specs matching `[test].specs`, compiles `[test].stage` if configured, and executes specs across parallel worker shards (`--codegen` is enabled by default on standalone `luau`).

| Flag | Description |
| --- | --- |
| `[specs...]` / `--file FILE` | Restricts execution to matching spec paths or basenames. |
| `--runner luau\|lute\|lune` | Selects the standalone Luau runtime (default `luau`). |
| `--codegen` / `--no-codegen` | Enables (default) or disables native Luau code generation (`luau --codegen`). |
| `--roblox-globals` | Installs `Vector3`, `CFrame`, `Color3`, `UDim2`, `Enum`, and `typeof` into headless spec globals. |
| `--coverage` | Collects `luau --coverage` data and writes LCOV output to `coverage.out`. |
| `-j, --jobs N` | Parallel shard count (`0` uses CPU core count; `1` runs in a single process, automatic under `--coverage`). |
| `--filter SUBSTR` / `-g, --grep PAT` | Runs tests matching case-insensitive substring(s) or Luau/regex pattern. |
| `--exclude SUBSTR` | Excludes tests matching substring(s). |
| `--failed` | Re-runs only failures from `.sert/last-failed.json` (replaying failed property seeds). |
| `--watch` | Re-runs specs whenever `.luau` or config files change (`150 ms` debounce). |
| `--repeat N` | Runs the selected tests `N` times to surface order or timing flakes. |
| `--slowest N` | Prints the `N` slowest tests after the summary. |
| `--timeout S` / `--test-timeout S` | Shard wall-clock timeout (default `120`s) and per-test timeout (default `10`s). |
| `--seed N\|random` / `--runs N` / `--replay N` | Overrides property base seed, trial count, or replays one counterexample seed. |
| `--exhaustive` / `--budget S` | Runs bounded-exhaustive properties within an optional wall-clock budget. |
| `--allow-focused` / `--ci` | Permits `.focus` tests under CI, or forces CI checks locally. |
| `-x, --fail-fast` / `--compact` / `--list` | Stops on first failure, condenses output, or lists matching test names without running them. |
| `--junit FILE` / `--json-out FILE` | Writes JUnit XML or structured JSON results. |

### `sert coverage`

Parses an LCOV tracefile (`coverage.out`), prints per-file line and function hit percentages, appends a Markdown summary when `$GITHUB_STEP_SUMMARY` is set, and enforces minimum line coverage.

| Flag | Description |
| --- | --- |
| `[FILE]` | Path to LCOV file (defaults to `"coverage.out"`). |
| `--min N` | Minimum line coverage percentage (`0–100`, overrides `[coverage].min`). |
| `--uncovered` | Lists uncovered line ranges (`L12-L18`) for each file. |
| `--diff [REV]` | Computes and gates coverage exclusively on lines added or modified relative to `REV` (auto-detects `origin/$GITHUB_BASE_REF` or `HEAD`, and includes untracked `.luau` files). |
| `--badge [FILE]` | Writes a Shields.io endpoint JSON file (defaults to `[coverage].badge` or `"coverage.json"`). |

### `sert mutate`

Scores test thoroughness by lexing target `.luau` files with `sert`'s pure-Python Luau lexer (`luau_lex`), leaving comments, string literals, and type annotations untouched. `sert mutate` builds a zero-copy hardlink overlay in `.sert/mutate/overlay/` without modifying your working tree, prunes uncovered lines via LCOV, and switches active mutants across parallel worker shards via `@__SERT_MUTANT`.

Built-in operators: `stmt_del` (statement deletion), `ret_val` (return value replacement), `cond_inv` (`if`/`elseif` inversion), `rel_flip` (`==`/`~=`, `<`/`<=`/`>`/`>=`), `arith_op` (`+`/`-`, `*`/`/`), `logic_op` (`and`/`or`), and `math_fn` (`math.min`/`max`, `floor`/`ceil`). Results report `KILLED`, `SURVIVED`, and `TIMEOUT` separately.

| Flag | Description |
| --- | --- |
| `[paths...]` | Target files or globs (overrides `[mutate].include`). |
| `--diff [REV]` | Mutates only lines added or modified since `REV` (including untracked `.luau` files). |
| `--min N` | Minimum mutation score percentage `(killed + timeout) / total * 100`. |
| `--operators a,b,...` | Comma-separated subset of operators to enable. |
| `--max-mutants N` | Deterministic sample cap when bounding CI runtime (`0` = unlimited). |
| `-j, --jobs N` / `--timeout S` | Worker concurrency and per-mutant timeout (auto-scaled to 5x baseline when `0`). |
| `--coverage-file FILE` / `--no-coverage-run` | Reuses an existing LCOV file or skips baseline coverage pruning. |

### `sert check`

Runs `sert lint` and `sert run --coverage` concurrently, then evaluates `sert coverage` (`--diff [REV]`, `--fix`, `--uncovered`, `--compact`, and `--studio` / `--no-studio`).

### `sert studio` and `sert cloud`

- **`sert studio`:** `--mode edit|play|run`, `--device PRESET`, `--clients N`, `--warm`, `--studio ID`, `--capture`, `--suite NAME`, `--check`, `--side server|client`, `--filter`, `-g/--grep`, `--exclude`, `--file`, `--failed`, `--list`, `--repeat N`, `--seed`, `--runs`, `--replay`, `--exhaustive`, `--budget`, `--test-timeout`, `--deadline`, `--timeout`, `--allow-focused`, `-x/--fail-fast`, `--compact`, `--slowest N`, `--keep`, `--launcher PATH`, `--json-out FILE`.
- **`sert cloud`:** `--project FILE`, `--script FILE`, `--place FILE`, `--place-version N`, `--output DIR`, `--shard k/N`, `-j/--jobs N` (default `8`, max `10`), `--timeout S`, `--json-out FILE`, `--unsharded`, `--dry-run`, `--emit FILE`.

---

## `sert.toml` and `sert.lock`

`sert.local.toml` (gitignored) deep-merges over `sert.toml` for machine-local tweaks.

| Section | Key settings |
| --- | --- |
| `[sert]` | `version = "0.2.0"`, `repo = "kohltastrophe/sert"` |
| `[test]` | `specs = ["test/**/*.spec.luau"]`, `entries = []`, `runner = "luau"`, `codegen = true`, `setup = ""`, `stage = ""`, `globals = ""`, `jobs = 0`, `timeout = 120`, `repeat = 1`, `slowest = 0`, `allow_focused = false` |
| `[studio]` | `project = "default.project.json"`, `specs = [...]`, `mode = "play"`, `device = ""`, `clients = 1`, `warm = false`, `studio = ""`, `capture = false`, `sides = [...]`, `timeout = 180`, `out = ".sert/studio"`, `hooks = ""`, `config = ""`, `runner = ""`, `[studio.suites.<name>]` |
| `[cloud]` | `project = ""`, `specs = [...]`, `script = ""`, `shards = []`, `shard_limit = 0`, `jobs = 8`, `max_workers = 10`, `timeout = 300` |
| `[lint]` | `paths = ["src", "test"]`, `project = "default.project.json"`, `solvers = ["new", "old"]`, `ignore = []`, `stylua = true`, `selene = true`, `stub = true`, `extra = []`, `[[lint.analyze]]` |
| `[types]` | `pass = ["test/types"]`, `fail = ["test/types/fail"]`, `solvers = []` |
| `[coverage]` | `include = ["src"]`, `exclude = []`, `min = 80`, `badge = "coverage.json"` |
| `[mutate]` | `include = ["src"]`, `exclude = []`, `specs = {}`, `operators = []`, `min = 0`, `timeout = 0`, `jobs = 0`, `max_mutants = 0`, `benign_calls = []`, `cosmetic_props = []` |
| `[override]` | `sert = "../sert"` (local dev only; fails automatically when `CI=true`) |
| `[release]` | Release metadata pass-through table (for example `kohltastrophe/release` version sync rules) |

`sert.lock` is a TOML lockfile (`schema = 1`) recording exact URLs and SHA-256 hashes for `[assets."sert.pyz"]`, `[assets."sert.zip"]`, and `[assets."globalTypes.d.luau"]`. Commit `sert.lock` alongside `sert.toml` and `tools/sert.py`.
