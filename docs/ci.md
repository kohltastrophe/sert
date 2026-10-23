# sert in GitHub Actions

`kohltastrophe/sert/actions/setup` installs Python and your `rokit.toml` toolchain, restores `.sert/` and download caches by pin hash, runs `tools/sert.py fetch`, and adds `.sert/bin` to `PATH`. Pin the action to the release version in `sert.toml`.

## Complete workflow (`.github/workflows/ci.yml`)

```yaml
name: CI

on:
  push:
    branches: [main]
  pull_request:
  schedule:
    - cron: "17 4 * * *"

jobs:
  check:
    if: github.event_name != 'schedule'
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v7
      - uses: kohltastrophe/sert/actions/setup@v0.1.0
      - run: python3 tools/sert.py lint
      - run: python3 tools/sert.py run --coverage
      - run: python3 tools/sert.py coverage --min 90

  exhaustive:
    if: github.event_name == 'schedule'
    runs-on: ubuntu-latest
    timeout-minutes: 60
    steps:
      - uses: actions/checkout@v7
      - uses: kohltastrophe/sert/actions/setup@v0.1.0
        with:
          rokit: false
      - run: python3 tools/sert.py run --exhaustive

  roblox:
    if: github.event_name != 'schedule'
    runs-on: ubuntu-latest
    environment: testing
    concurrency:
      group: luau-execution
      cancel-in-progress: false
    steps:
      - uses: actions/checkout@v7
      - uses: kohltastrophe/sert/actions/setup@v0.1.0
      - name: sert cloud
        env:
          ROBLOX_API_KEY: ${{ secrets.ROBLOX_API_KEY }}
          ROBLOX_UNIVERSE_ID: ${{ secrets.ROBLOX_UNIVERSE_ID }}
          ROBLOX_PLACE_ID: ${{ secrets.ROBLOX_PLACE_ID }}
        run: |
          if [ -z "$ROBLOX_API_KEY" ] && [ "${{ github.event_name }}" = "pull_request" ]; then
            echo "::notice::no Roblox secrets (fork or Dependabot pull request); skipping sert cloud"
            exit 0
          fi
          python3 tools/sert.py cloud --project studio/default.project.json
```

## Setup action (`kohltastrophe/sert/actions/setup`)

| Input | Default | Description |
| --- | --- | --- |
| `python-version` | `"3.13"` | Python version installed for the CLI (`""` uses the runner's existing Python 3.11+). |
| `rokit` | `"true"` | Installs tools from `rokit.toml` when present (`"false"` when the job only needs `luau` and `sert`). |
| `sert-ref` | `""` | Mirrors `sert` from a Git ref of `kohltastrophe/sert` instead of `sert.toml`. |
| `cache-key-extra` | `""` | Suffix appended to the `.sert/` cache key. |
| `token` | `github.token` | GitHub token passed to `sert fetch` as `GITHUB_TOKEN`. |

### Open Cloud secrets

Store `ROBLOX_API_KEY`, `ROBLOX_UNIVERSE_ID` (or `ROBLOX_TEST_UNIVERSE_ID`), and `ROBLOX_PLACE_ID` (or `ROBLOX_TEST_PLACE_ID`) as repository secrets or secrets on your `testing` deployment environment.

> [!NOTE]
> An Open Cloud place only runs one task at a time. Share a `concurrency.group` across workflows that target the same place so runs queue up instead of colliding.

## Reports, annotations, and coverage badges

When `GITHUB_ACTIONS=true`, `sert run`, `sert lint`, and `sert cloud` emit `::error` and `::warning` workflow annotations automatically. `sert coverage` and `sert mutate` also append markdown summary tables to `$GITHUB_STEP_SUMMARY`.

To publish a Shields.io coverage badge without external actions or Gist secrets, grant `contents: write` and pass `--badge-branch --badge-push` on `main` pushes:

```yaml
- name: Update coverage badge
  if: github.event_name == 'push' && github.ref == 'refs/heads/main'
  env:
    GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}
  run: python3 tools/sert.py coverage --badge-branch --badge-push
```

Then point your README badge at `https://img.shields.io/endpoint?url=https://raw.githubusercontent.com/<owner>/<repo>/badges/coverage.json`.
