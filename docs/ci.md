# GitHub Actions (`ci.md`)

`kohltastrophe/sert/actions/setup@v0.1.0` sets up Python, installs your Rokit toolchain from `rokit.toml`, restores cached downloads, runs `python3 tools/sert.py fetch` with SHA-256 verification against `sert.lock`, and adds `.sert/bin` to `PATH`. It runs on Linux, macOS, and Windows runners.

## Workflow example (`.github/workflows/ci.yml`)

Commit `sert.toml`, `rokit.toml`, `tools/sert.py`, and `sert.lock` to your repository, then add `.github/workflows/ci.yml`:

```yaml
name: CI

on:
  push:
    branches: [main]
  pull_request:
    branches: [main]
  schedule:
    - cron: "17 4 * * *"

permissions:
  contents: read

jobs:
  check:
    if: github.event_name != 'schedule'
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v7
        with:
          fetch-depth: 0
      - uses: kohltastrophe/sert/actions/setup@v0.1.0
      - name: Lint, test, and verify coverage
        run: python3 tools/sert.py check
      - name: JUnit report
        if: always()
        run: python3 tools/sert.py run --junit sert-junit.xml
      - name: Diff-scoped mutation gate
        if: github.event_name == 'pull_request'
        run: python3 tools/sert.py mutate --diff "origin/${{ github.base_ref }}" --min 85

  exhaustive:
    if: github.event_name == 'schedule'
    runs-on: ubuntu-latest
    timeout-minutes: 60
    steps:
      - uses: actions/checkout@v7
      - uses: kohltastrophe/sert/actions/setup@v0.1.0
      - run: python3 tools/sert.py run --exhaustive --budget 600

  cloud:
    if: github.event_name != 'schedule'
    runs-on: ubuntu-latest
    environment: testing
    concurrency:
      group: luau-execution-${{ github.ref }}
      cancel-in-progress: true
    steps:
      - uses: actions/checkout@v7
      - uses: kohltastrophe/sert/actions/setup@v0.1.0
      - name: Run Open Cloud specs
        env:
          ROBLOX_API_KEY: ${{ secrets.ROBLOX_API_KEY }}
          ROBLOX_UNIVERSE_ID: ${{ secrets.ROBLOX_UNIVERSE_ID }}
          ROBLOX_PLACE_ID: ${{ secrets.ROBLOX_PLACE_ID }}
        run: |
          if [ -z "$ROBLOX_API_KEY" ] && [ "${{ github.event_name }}" = "pull_request" ]; then
            echo "::notice::Skipping sert cloud on pull request without Roblox secrets"
            exit 0
          fi
          python3 tools/sert.py cloud
```

## Toolchain and lockfile pins

`rokit.toml` pins the standalone binaries used by `sert run`, `sert lint`, `sert studio`, and `sert cloud`:

```toml
[tools]
luau = "luau-lang/luau@0.724"
lute = "luau-lang/lute@1.0.0"
rojo = "rojo-rbx/rojo@7.7.0"
selene = "Kampfkarren/selene@0.31.0"
StyLua = "JohnnyMorganz/StyLua@2.5.2"
luau-lsp = "JohnnyMorganz/luau-lsp@1.70.0"
```

`sert.lock` pins the exact download URLs and 64-character SHA-256 digests for `sert-<version>.pyz`, `sert-<version>.zip`, and `globalTypes.d.luau` (matched to your `luau-lsp` version in `rokit.toml`). Both `tools/sert.py` and `sert fetch` verify every archive against `sert.lock` and release `SHA256SUMS` before executing or extracting anything.

The setup action hashes `[sert]` in `sert.toml`, `[tools]` in `rokit.toml`, and `sert.lock` into its cache key. Editing `[test]`, `[coverage]`, or `[mutate]` settings keeps your CI cache warm.

## Action inputs

| Input | Default | Description |
| --- | --- | --- |
| `python-version` | `"3.13"` | Python version installed via `actions/setup-python` (pass `""` to use the runner's existing Python 3.11+). |
| `rokit` | `"true"` | Installs and caches tools from `rokit.toml` via `CompeyDev/setup-rokit`. Set `"false"` if an earlier step already installed `luau` and lint tools. |
| `token` | `${{ github.token }}` | Exported as `GITHUB_TOKEN` during `sert fetch` to avoid GitHub API rate limits and authenticate private release downloads. |
| `sert-ref` | `""` | Checks out `kohltastrophe/sert` at a Git branch, tag, or SHA and sets `SERT_SOURCE` instead of using the pinned release. Use only when testing unreleased `sert` changes. |
| `cache-key-extra` | `""` | Extra suffix appended to the `.sert` download cache key. |

### Private forks and `GITHUB_TOKEN`

If you host an internal fork via `[sert].repo = "your-org/sert"`, pass a Personal Access Token or GitHub App token with `contents: read` on that repository to `with.token` (or export `GITHUB_TOKEN`). When `GITHUB_TOKEN` is set, `tools/sert.py` and `sert fetch` resolve release assets through the GitHub Releases API (`Accept: application/octet-stream`) and strip `Authorization` headers across cross-host redirects.

## Quality gates, annotations, and summaries

When `CI=1` or `CI=true` (set automatically by GitHub Actions), any `.focus` test, describe block, or property fails the run unless `--allow-focused` is passed. Active `[override]` paths in `sert.toml` also fail right away under `CI=true` so branches can't pass against local paths by mistake.

`sert check` runs `sert lint` and `sert run --coverage` concurrently, then evaluates `[coverage].min`; pass `sert check --diff origin/main` on pull requests to enforce your coverage floor on newly added and modified lines. `sert mutate` enforces `[mutate].min` (or `--min N`), supporting `--diff origin/main` on pull requests and full-repo runs on pushes or nightly schedules.

When `GITHUB_ACTIONS=true`, `sert lint`, `sert run`, and `sert cloud` emit `::error` and `::warning` annotations directly on PR diffs, while `sert coverage` and `sert mutate` append Markdown tables to `$GITHUB_STEP_SUMMARY`. Pass `--junit sert-junit.xml` to `sert run` for test reporters and `--badge coverage.json` to `sert coverage` to write a Shields.io endpoint JSON payload.

## Open Cloud in CI (`sert cloud`)

`sert cloud` builds your place with Rojo, uploads a saved version, and executes specs on Roblox's Open Cloud Luau Execution servers across parallel shards.

### Required secrets

Configure these secrets in your repository or GitHub Actions deployment environment (`ROBLOX_CLOUD_KEY` is often used as a team secret name in Vault or CI—map it to `ROBLOX_API_KEY` in the step's `env:` block):

| Environment variable | Fallback alias | Purpose |
| --- | --- | --- |
| `ROBLOX_API_KEY` | — | Open Cloud API key with `universe-places:write` (when uploading places) and `universe.place.luau-execution-session:write` permissions. `sert` redacts this value from all error logs. |
| `ROBLOX_UNIVERSE_ID` | `ROBLOX_TEST_UNIVERSE_ID` | Target Universe ID. |
| `ROBLOX_PLACE_ID` | `ROBLOX_TEST_PLACE_ID` | Target Place ID within that universe. |

> [!NOTE]
> Roblox caps active Open Cloud Luau Execution tasks per universe (10 concurrent tasks). `sert cloud` runs up to `--jobs` shards in parallel (default `8`, capped at `10`). If a task times out or a workflow job is canceled, `sert cloud` calls the Open Cloud `:cancel` endpoint in a `finally` block so orphaned tasks don't exhaust your `429` quota.
