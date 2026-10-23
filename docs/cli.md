# The sert command line

```sh
python3 tools/sert.py <command> [options]      # through the committed bootstrap stub
PYTHONPATH=python python3 -m sert <command>    # from a sert checkout
```

The CLI requires Python 3.11 or newer and uses only the Python standard library. Every command accepts `--root DIR`, which defaults to `$SERT_ROOT`, the Git root, or the nearest parent directory containing `sert.toml`.

## The stub and pinning

`tools/sert.py` runs the `sert` version pinned in `sert.toml`. It checks `$SERT_SOURCE` first, then `[override].sert` in `sert.local.toml`, and otherwise downloads `sert-<version>.pyz` from GitHub Releases into the local download cache. Commit `tools/sert.py` without edits (`sert lint` verifies that it matches the release).

```toml
[sert]
version = "0.1.0"
```

Set `SERT_OFFLINE=1` to use cached downloads only.

## Commands

### Setup (`init`, `fetch`)

- **`sert init [--force]`** creates `sert.toml`, `tools/sert.py`, `.luaurc` (`"sert": "./.sert/sert/src"`), `.gitignore` entries (`.sert/`, `sert.local.toml`, `coverage.out`, `coverage.json`), and `test/Example.spec.luau`. Pass `--force` to overwrite `sert.toml` and update the `.luaurc` alias.
- **`sert fetch [--only sert|deps|tools|types] [--offline]`** downloads `.sert/sert/`, `.sert/pkg/<dep>/`, `.sert/bin/{luau,lute,sert}`, and `.sert/types/globalTypes.d.luau`. Commands like `run`, `lint`, `studio`, and `mutate` run `fetch` automatically when `.sert/` is incomplete.

### `sert run`

```text
sert run [specs ...] [--filter NAME] [-x] [--compact] [--list] [--seed N|random] [--runs N] [--replay N]
         [--exhaustive] [--budget S] [--coverage] [--codegen | --no-codegen] [--timeout S] [--entry FILE ...]
         [--junit FILE] [--json-out FILE] [-a ARGS ...]
```

Runs headless specs with `.sert/bin/luau` (or `lute run` when `[test].runner = "lute"`). If `[test].stage` is set, `run` stages your Rojo project first, then executes `[test].entries` and a generated `.sert/run.luau` runner for `[test].specs`. When a test fails, `run` prints inline numbered source snippets for the spec and source stack frames along with a copy-pasteable `replay:` command. If a filter matches only skipped `rtest` or `skip` blocks (`0 passed, N skipped`), `run` exits with code `1` and prints the `sert studio` command needed to run them.

| Flag | Description |
| --- | --- |
| `specs ...` | Spec files, directories, or globs to run instead of `[test]`. |
| `--filter NAME` | Case-insensitive substring match (or `@file=A,B`) passed to entry scripts. |
| `-x`, `--fail-fast` | Stop on the first failure. |
| `--compact` | Suppress passing `✅` lines while keeping failure diagnostics, slow test alerts, and the summary (also enabled by `SERT_COMPACT=1`). |
| `--list` | Print matching tests as `[sert-list]` lines without running them. |
| `--seed N\|random` | Set the property base seed (default `0x5EED`) or pick a random seed. |
| `--runs N` | Override the number of cases per property test. |
| `--replay N` | Rerun and shrink a single failing property case seed `N`. |
| `--exhaustive`, `--budget S` | Run only `exhaustive` properties with a per-property timeout in seconds (default `600`). |
| `--coverage` | Write LCOV coverage data to `coverage.out` (`luau` runner only). |
| `--codegen`, `--no-codegen` | Enable or disable native `--codegen` (disabled automatically under `--coverage`). |
| `--timeout S` | Per-entry timeout in seconds (exits with `3` on timeout). |
| `--entry FILE` | Run only the specified entry script (repeatable). |
| `--junit FILE`, `--json-out FILE` | Write JUnit XML or JSON results to a file. |
| `-a ARGS ...` | Forward remaining arguments (`--test-timeout=S`, `--markers`, etc.) to entry scripts. |

### `sert studio`

Builds your test place and runs specs in an unattended Roblox Studio session (`edit`, `play`, or `run` mode), saving logs and reports under `[studio].out`. See [roblox.md](roblox.md#running-specs-in-studio).

```text
sert studio [FILTER] [--mode edit|play|run ...] [--filter TEXT ...] [--grep REGEX ...] [--exclude TEXT ...]
            [--file SPEC ...] [--side SIDE ...] [--failed] [--list] [--repeat N] [--seed N|random] [--runs N]
            [--replay SEED] [--exhaustive] [--budget S] [--test-timeout S] [--deadline S] [--slowest N]
            [--timeout S] [--keep] [--launcher CMD] [--json-out FILE] [--check] [--suite NAME ...]
```

| Flag | Description |
| --- | --- |
| `FILTER`, `--filter TEXT`, `--grep REGEX`, `--exclude TEXT` | Filter by test name (`--filter`, `--grep`, and `--failed` union together, positional `FILTER`, `--file`, and `--side` intersect, and `--exclude` subtracts). |
| `--mode`, `--file SPEC`, `--side SIDE`, `--suite NAME` | Select Studio mode, spec base name, side name, or `[studio.suites.<name>]` profile (all repeatable). |
| `--failed` | Rerun tests that failed in the last Studio run along with their failing property seeds. |
| `--list` | List matching tests from the spec catalog without launching Studio. |
| `--repeat N` | Repeat the run `N` times and write `flake.json`. |
| `--seed`, `--runs`, `--replay`, `--exhaustive`, `--budget` | Property flags forwarded to the Studio runner. |
| `--test-timeout S`, `--deadline S`, `--timeout S` | Per-test yield timeout (`30` s), client report deadline (`600` s), and Studio process timeout (`900` s). |
| `--slowest N`, `--keep`, `--launcher CMD`, `--json-out FILE` | Number of slowest tests to list (`10`), keep staging temp directory, custom Studio launcher command, or JSON verdict output path. |
| `--check` | Build the Rojo place and run spec-drift and hook checks without launching Studio. |

#### Studio Python hooks (`[studio].hooks`)

Set `hooks = "tools/studio_hooks.py"` in `[studio]` (or `[studio.suites.<name>]`) to load a Python module with optional lifecycle hooks:

```python
# tools/studio_hooks.py
def add_arguments(parser):
    parser.add_argument("--device", help="Studio device preset id")

def prelude(args, mode):
    if getattr(args, "device", None):
        return f'game:GetService("StudioDeviceSimulatorService"):SetDeviceAsync({args.device!r})'
```

| Hook | Purpose |
| --- | --- |
| `add_arguments(parser)` | Adds custom CLI flags to `sert studio`'s `argparse.ArgumentParser`. |
| `passes(args) -> list[list[str]] \| None` | Expands one CLI invocation into multiple Studio passes (such as multiple device presets). |
| `check(args) -> list[str]` | Runs during `sert studio --check` and returns a list of error strings (empty when clean). |
| `request(args, req) -> dict \| None` | Modifies or replaces the runner request dict before Studio starts. |
| `prelude(args, mode) -> str \| None` | Returns Luau source code to run in `play` or `run` mode before the test runner starts. |
| `monitor(ctx)` | Runs on a background thread while Studio is open (useful for window capture or watchdogs). |
| `on_marker(tag, payload, state)` | Handles `[sert-x:<tag>] <payload>` lines emitted by `Runner.marker(tag, payload)`. |
| `report(state) -> int \| None` | Runs after Studio exits and can return a custom exit code. |

### `sert cloud`

Builds the place, uploads a Saved version, and runs Open Cloud Luau Execution tasks (one task per shard). Reads `ROBLOX_API_KEY`, `ROBLOX_UNIVERSE_ID`, and `ROBLOX_PLACE_ID` (or their `ROBLOX_TEST_*` equivalents). See [roblox.md](roblox.md#open-cloud).

| Flag | Description |
| --- | --- |
| `--project PROJECT`, `--script SCRIPT` | Rojo project and task script (defaults to `[cloud]` in `sert.toml`). |
| `--place FILE`, `--place-version N`, `--output FILE` | Upload a prebuilt `.rbxl`, reuse uploaded version `N`, or save the built place to `FILE`. |
| `--shard NAME`, `--unsharded` | Run only the named shard(s), or run everything in a single unsharded task. |
| `--dry-run [--emit DIR]` | Build the place and print or write per-shard scripts without network calls or credentials. |
| `--json-out FILE` | Write task verdicts to a JSON file. |

### `sert check`, `lint`, `coverage`, `mutate`, and `release`

- **`sert check [--diff [REV]] [--compact] [--uncovered] [--studio | --no-studio]`** runs `lint`, `run --coverage`, and `coverage` in a single pass (and `studio --check` when `--studio` is passed).
- **`sert lint [--dry-run] [--skip CHECK ...] [--only CHECK ...]`** runs `sourcemap`, `analyze` (`luau-lsp analyze` per solver or `[[lint.analyze]]` group), `types` (`[types].pass` files must typecheck cleanly and `[types].fail` files must error on `-- expect-error` lines), `registration`, `stylua`, `selene`, `extra`, and `stub`.
- **`sert coverage [FILE] [--min N] [--uncovered] [--diff [REV]] [--badge [FILE]] [--badge-branch [BRANCH]] [--badge-push]`** summarizes LCOV records (`coverage.out`) across `[coverage].include` minus `exclude`, printing uncovered line ranges (`Lx-Ly`) next to files below 100%. Pass `--uncovered` to inline missed source lines or `--diff [REV]` to evaluate coverage across lines modified since `REV` (default `HEAD`). Pass `--badge` to write a Shields.io endpoint file (`coverage.json`), `--badge-branch` to commit it onto the `badges` branch via Git plumbing without modifying your working tree, and `--badge-push` to fetch and push `origin <branch>`.
- **`sert mutate [paths ...] [-j N] [--timeout S] [--min N] [--max-mutants N] [--operators LIST] [--diff [REV]] [--coverage-file FILE] [--no-coverage-run] [-a ARGS ...]`** mutates covered lines (`stmt_del`, `ret_val`, `cond_inv`, `rel_flip`, `arith_op`, `logic_op`, `math_fn`) inside `.sert/mutate/tree`. Pass `--diff [REV]` to scope mutations to Git-modified lines. Prints the mutation score to stdout, prints surviving diffs with surrounding source context and a suggested `sert run` filter to stderr, and exits with `1` if the score is below `--min` (or `[mutate].min`).
- **`sert release dist [--from REV] [--version V] [--dry-run]`** (alias `sert dist`) commits `[dist].paths` from `REV` (default `HEAD`) onto `[dist].branch` using Git plumbing without modifying your working tree.
- **`sert release pack [--out DIR]`** (alias `sert pack`) builds `sert-<version>.zip`, `sert-<version>.pyz`, and `SHA256SUMS` into `DIR` (default `dist`).

## Entry scripts and markers

- **`[test].specs`** generates `.sert/run.luau`, which requires each spec inside `pcall` and calls `sert.run(sert.parseCliArgs(...))`. Every spec module must end with `return {}`.
- **`[test].entries`** runs custom entry scripts. Wrap each `require` in `sert.loaded(require(...))` so Luau CLI syntax or load errors throw instead of returning an error string.
- **`sert.run` markers:**

| Marker | Payload |
| --- | --- |
| `[sert-list] <file>\|<name>` | Emitted for each selected test under `--list`, followed by `[sert-list] end <n>`. |
| `[sert-seed] run <base>` | Suite base property seed, followed by `[sert-seed] <name>\|<seed>` for any failing properties. |
| `[sert-test] <json>` | Per-test result under `--markers` (`{ name, status, ms, file?, err? }`). |
| `[sert-mutant] <id>=KILLED\|SURVIVED` | Mutant verdict during `sert mutate` batches. |
| `[sert-done] <json>` | Final `Results` summary (`{ passed, failed, skipped, todo, total, clock }`). |

## `sert.toml` reference

`sert.local.toml` deep-merges on top of `sert.toml` for local overrides. Unknown keys or mismatched types exit with code `2`.

| Section | Keys |
| --- | --- |
| `[sert]` | `version`, `repo` (`"kohltastrophe/sert"`). |
| `[tools]` | `luau`, `lute`, `luau_lsp`. |
| `[deps.<name>]` | `repo`, `tag`, `asset`, `strip`, `paths`. |
| `[override]` | `<pkg> = "<path>"` (copies a local checkout into `.sert/` during `sert fetch`). |
| `[test]` | `specs`, `entries`, `setup`, `runner` (`"luau"` or `"lute"`), `codegen` (`false`), `stage`. |
| `[studio]` | `project`, `mode` (`"play"`), `config`, `runner`, `specs`, `sides`, `out` (`"build/sert"`), `hooks`, `timeout` (`900`), `launcher`, `list_command`, `drift`, `run_level`, `suites.<name>` (`default` plus studio keys). |
| `[cloud]` | `project`, `script`, `shards` (names or `{ name, only?, except? }`), `shard_limit` (`120`). |
| `[lint]` | `paths` (`["src"]`), `project`, `solvers` (`["new"]`), `ignore`, `selene`, `stylua` (`true`), `stub` (`true`), `extra`, `registration` (`{ aggregator, specs }`), `[[lint.analyze]]` (`name`, `paths`, `ignore`, `platform`, `defs`, `definitions`, `sourcemap`, `solvers`). |
| `[types]` | `pass`, `fail`, `solvers`. |
| `[coverage]` | `include` (`["src"]`), `exclude`, `min`, `badge`, `badge_branch`. |
| `[mutate]` | `include`, `exclude`, `min`, `timeout` (`5`), `max_mutants`, `jobs`, `operators`, `specs`, `benign_calls`, `cosmetic_props`. |
| `[release]` | `prefix`, `versions`, `released`, `packages.<name>` (each source: `{ file, key?, pattern?, where?, field? }`). |
| `[dist]` | `paths` (required), `branch` (`"dist"`), `name`, `version`, `package`. |

## Exit codes, environment variables, and platforms

### Exit codes

| Code | Meaning |
| --- | --- |
| `0` | All selected tests and checks passed. |
| `1` | Test, lint, coverage, or mutation failure, or zero tests matched. |
| `2` | CLI usage error, invalid `sert.toml`, missing credentials or pins, or infrastructure error. |
| `3` | Entry script or Studio process timed out. |
| `130` | Interrupted by `SIGINT`, `SIGTERM`, or a broken output pipe. |

### Environment variables

| Variable | Effect |
| --- | --- |
| `SERT_ROOT` | Default project root when `--root` is omitted. |
| `SERT_CACHE` | Download and zipapp cache directory. |
| `SERT_OFFLINE` | Set to `1` to disable network downloads and use cached files only. |
| `SERT_SOURCE` | Local `sert` checkout used by `tools/sert.py` instead of the pinned release. |
| `SERT_PYTHON` | Python interpreter used when spawning child `sert` processes. |
| `SERT_RETRY_DELAY`, `SERT_GITHUB_URL`, `SERT_RAW_URL` | HTTP retry base delay in seconds and GitHub URL overrides. |
| `GITHUB_TOKEN` | Bearer token for GitHub API requests and release downloads. |
| `CI`, `GITHUB_ACTIONS`, `GITHUB_STEP_SUMMARY` | Rejects local `[override]` entries in `sert.local.toml` (`CI=true`) and enables GitHub Actions annotations and `$GITHUB_STEP_SUMMARY` tables. |
| `ROBLOX_API_KEY`, `ROBLOX_UNIVERSE_ID`, `ROBLOX_PLACE_ID`, `ROBLOX_CLOUD_BASE_URL` | Open Cloud credentials and target IDs for `sert cloud` (also reads `ROBLOX_TEST_UNIVERSE_ID` and `ROBLOX_TEST_PLACE_ID`). |
| `WINEPREFIX` | Wine prefix searched for Studio logs on Linux. |

### Studio platforms and maintainers

- **Studio discovery:** Automatically locates Studio on Linux (`flatpak run org.vinegarhq.Vinegar`, reading logs from Vinegar appdata or `$WINEPREFIX`), Windows (`%LOCALAPPDATA%\Roblox\Versions\...\RobloxStudioBeta.exe`), and macOS (`/Applications/RobloxStudio.app/Contents/MacOS/RobloxStudio`).
- **Maintainers:** Run `python3 scripts/gen_api.py [--check]` to regenerate or verify `src/doubles/generated.luau` from the pinned Roblox API dump.
