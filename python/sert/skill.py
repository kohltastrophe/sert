"""Internal AI-agent SKILL.md and machine-readable schema generator (exposed via `sert init --skill`)."""

from __future__ import annotations

from pathlib import Path

from sert.util import write_atomic

SKILL_REL = ".agents/skills/sert/SKILL.md"


def render_skill_markdown() -> str:
    return """---
name: sert
description: Run, fuzz, audit, benchmark, snapshot-update, and verify Luau/Roblox projects using sert's closed-loop AI-agent workflow.
---

# sert — Deterministic Luau and Roblox Testing Workflow

Use `sert` as a closed-loop verification harness when writing, refactoring, or debugging Luau and Roblox code.

## Primary Verification Loop

1. **Run closed-loop verification after edits (`sert check --changed --agent`):**
   ```bash
   python3 tools/sert.py check --changed --agent
   ```
   - Runs `lint` and impacted `sert run --affected --coverage` concurrently (Test Impact Analysis via cached static `require` graph and `.sert/coverage-map.json`).
   - Runs `coverage --diff` and `sert audit` (anti-reward-hacking and export coverage check; pass `--no-audit` to skip or `--strict` to fail on uncovered exports or explicit skips).
   - Runs incremental `sert mutate --diff` if covered modified `src/` lines exist (pass `--no-mutate` to skip).
   - If affected specs skip engine tests (`roblox` / `server` / `client`), attempts `sert studio --warm` (falling back to cold headless `sert studio` only on bridge exit `2`), or fails with the exact follow-up command under `--no-studio` unless `--allow-skipped-targets` is set.
   - Run `sert check --watch` to re-run on save (or `sert check --changed --watch` for continuous TIA re-verification), or `sert check --audit --agent` for a full-suite verification pass.

2. **Check tests, lint, and coverage in agent mode:**
   ```bash
   python3 tools/sert.py run --affected --agent
   python3 tools/sert.py lint --agent
   python3 tools/sert.py coverage --diff --agent
   python3 tools/sert.py check --agent
   ```
   - Pass `--format json` on any verification command (`check`, `run`, `lint`, `coverage`, `audit`, `mutate`, `fuzz`, `bench`, `studio`, `cloud`) for a single JSON envelope (`version`, `command`, `status`, `exit_code`, `summary`, `errors`, `data`).
   - Replay failed tests and shrunk `v1:...` / `v2:...` counterexample tapes via `python3 tools/sert.py run --failed --agent`.
   - Surface order dependencies and intermittent flakes with `--shuffle [--seed N]` and `--retry N`.

3. **Audit for reward hacking and coverage blind spots (`sert audit`):**
   ```bash
   python3 tools/sert.py audit --diff --agent
   ```
   - Detects static tautologies (`sert.eq(a, a)`, `sert.ok(true)`, `sert.eq(1, 1.0)`, `sert.ne(literal, nil)`), runtime `zeroAssertionTests` (missing `{ smoke = true }`), runtime tautologies, vacuous properties, and `.OnServerEvent`/`.OnServerInvoke` handlers without `fuzzRemote`/`remotePayload` coverage (`--allow-unfuzzed-remotes` to waive).
   - Reports uncovered public `M.foo` exports in `src/` (including single-line functions) with `file:Lx-Ly` spans (`--strict` promotes uncovered exports and explicit `sert.test.skip` calls to exit 1).

4. **Fuzzing and permanent regression capture (`sert fuzz`):**
   ```bash
   python3 tools/sert.py fuzz --budget 10 --agent
   ```
   - Shrinks failing property, stateful model, and VOPR cases to minimal counterexamples and saves `v1:...` / `v2:...` tokens into `test/.sert-regressions.toml`.
   - `sert run` and `sert studio` load `test/.sert-regressions.toml` (`RunOptions.regressions`) and fail immediately if a saved regression reappears.

5. **Snapshots (`sert.inlineSnapshot` and `sert.snapshot`):**
   - Inline snapshots live in source (`sert.inlineSnapshot(val, "...")`); file snapshots live in `test/__snapshots__/*.snap` (`sert.snapshot(val, "name")`).
   - Update snapshots intentionally with `-u` / `--update-snapshots` (rejected when `--ci` or `CI=true`); prune obsolete `.snap` keys with `--prune-snapshots`.

6. **Benchmarks and allocation budgets (`sert bench` and `sert.noAllocs`):**
   ```bash
   python3 tools/sert.py bench --save main --agent
   python3 tools/sert.py bench --compare main --fail-regression 20 --agent
   ```
   - Runs `sert.bench(...)` specs with `luau --codegen` enabled and saves baselines in `.sert/bench/<name>.json`.
   - Fails with exit 1 if median `ns/op` or `allocKb` regresses past `--fail-regression` (default `20.0`%).
   - Guard hot paths with `sert.noAllocs(fn)` / `sert.maxAllocs(kb, fn)` / `sert.allocs(fn)`.

7. **Warm Studio bridge (`sert studio --warm`):**
   - Configure a bridge command with `[studio].bridge`, `SERT_STUDIO_BRIDGE`, `STUDIO_LINK`, or `sert-studio-bridge` / `studio-link` on `PATH`.

## Core Luau APIs

- **`sert.env`**: Deterministic headless Roblox `game`/services/Instance/task scheduler sandbox for Luau CLI specs (`sert.env.new`, `sert.env.installGlobals`).
- **`sert.sim.vopr`, `sert.sim.check`, `sert.sim.explore`, `sert.sim.verifyTrace`, `sert.sim.linearizable`**: Deterministic multi-peer simulation with fault injection, bounded BFS/interleaving exploration (exact by default, opt-in `stateHash = "backing"` or custom callback), trace verification, and linearizable history checks.
- **`sert.laws`**: Universal property contracts (`codec`, `order`, `algebra`, `differential`, `metamorphic`, `complexity`).
- **`sert.roblox.conformance`, `sert.roblox.Layout`, `sert.roblox.Flicker`, `sert.roblox.fuzzRemote`**: Dual-target (`sert.env` + Studio) specs, UI layout conformance checks (`settle`, `noOverlap`, `fitsParent`, `within`, `fitsViewport`, `noTextOverflow`, `minTouchTarget`, `aligned`, `audit`, `matrix` across `Phone`/`SmallPhone`/`Tablet`/`Desktop`/`Console`/`Ultrawide`), UI flicker detection, and adversarial remote payload fuzzing.
- **`sert.inlineSnapshot` / `sert.snapshot`**: Deterministic serialized snapshot assertions updated via `-u`.

## Exit Codes

- `0`: Passed or clean no-op (`--affected` with 0 impacted specs)
- `1`: Test failure, coverage floor failure, audit finding, benchmark regression, or skipped engine targets under `--no-studio`
- `2`: Infrastructure, config, or usage error
- `3`: Timeout
- `130`: Interrupted
"""


def skill_schema() -> dict:
    return {
        "version": 1,
        "skill_path": SKILL_REL,
        "formats": ["human", "agent", "json"],
        "exit_codes": {
            "0": "passed or clean affected no-op",
            "1": "test, audit, coverage, benchmark regression, or engine-target failure",
            "2": "infrastructure or usage error",
            "3": "timeout",
            "130": "interrupted",
        },
        "commands": {
            "init": {
                "summary": "scaffold sert config, tools stub, starter spec, or output/install AI agent skill",
                "flags": ["--force", "--fetch", "--agents", "--skill [DIR]", "--stdout", "--json"],
            },
            "fetch": {
                "summary": "download and SHA-256 verify sert and globalTypes into .sert/ and sert.lock",
                "flags": ["--only sert,types", "--offline", "--json"],
            },
            "check": {
                "summary": "lint, run --coverage, coverage gate, plus optional audit/mutate/Studio verification",
                "flags": [
                    "--changed [REV]",
                    "--diff [REV]",
                    "--audit",
                    "--no-audit",
                    "--mutate",
                    "--no-mutate",
                    "--strict",
                    "--allow-unfuzzed-remotes",
                    "--allow-skipped-targets",
                    "--compact",
                    "--uncovered",
                    "--fix",
                    "--watch",
                    "--studio",
                    "--no-studio",
                    "--studio-id ID",
                    "--timeout S",
                    "-j / --jobs N",
                    "--ci",
                    "--agent",
                    "--format human|agent|json",
                ],
            },
            "run": {
                "summary": "run headless Luau specs with luau, lute, or lune",
                "flags": [
                    "[specs...]",
                    "--runner luau|lute|lune",
                    "--coverage",
                    "--codegen",
                    "--no-codegen",
                    "--roblox-globals",
                    "-j / --jobs N",
                    "--timeout S",
                    "--entry FILE",
                    "--affected [REV]",
                    "--changed [REV]",
                    "--watch",
                    "--junit FILE",
                    "--json-out FILE",
                    "--filter NAME",
                    "-g / --grep PAT",
                    "--exclude TEXT",
                    "--file SPEC",
                    "--failed",
                    "-x / --fail-fast",
                    "--compact",
                    "--list",
                    "--shuffle",
                    "--repeat N",
                    "--retry N",
                    "--slowest N",
                    "--test-timeout S",
                    "--allow-focused",
                    "--ci",
                    "--seed SEED",
                    "--runs N",
                    "--replay TOKEN",
                    "--exhaustive",
                    "--budget S",
                    "-u / --update-snapshots",
                    "--prune-snapshots",
                    "--strict-assertions",
                    "--save-regressions",
                    "--bench",
                    "--agent",
                    "--format human|agent|json",
                ],
            },
            "fuzz": {
                "summary": "continuous property, model, and VOPR fuzzing with shrinking and regression capture",
                "flags": [
                    "[specs...]",
                    "--filter SUBSTR",
                    "-g / --grep PAT",
                    "--file FILE",
                    "--budget SEC",
                    "--runs N",
                    "--seed N",
                    "--dict FILE",
                    "--corpus DIR",
                    "--no-save-regressions",
                    "--agent",
                    "--format human|agent|json",
                ],
            },
            "audit": {
                "summary": "anti-reward-hacking static, runtime, remote-fuzz, and public export scanner",
                "flags": [
                    "--diff [REV]",
                    "--allow-unfuzzed-remotes",
                    "--strict",
                    "--no-run",
                    "--run-output FILE",
                    "--coverage-file FILE",
                    "--agent",
                    "--format human|agent|json",
                ],
            },
            "bench": {
                "summary": "run sert.bench specs with luau --codegen and compare baselines",
                "flags": [
                    "[specs...]",
                    "--filter PAT",
                    "-g / --grep PAT",
                    "--file SPEC",
                    "--save NAME",
                    "--compare NAME",
                    "--fail-regression PCT",
                    "--timeout S",
                    "-j / --jobs N",
                    "--ci",
                    "--agent",
                    "--format human|agent|json",
                ],
            },
            "studio": {
                "summary": "run specs in Roblox Studio",
                "flags": [
                    "[filter]",
                    "--mode edit|play|run",
                    "--device PRESET",
                    "--clients N",
                    "--warm",
                    "--studio ID",
                    "--studio-id ID",
                    "--capture",
                    "--filter TEXT",
                    "-g / --grep PAT",
                    "--exclude TEXT",
                    "--file SPEC",
                    "--side SIDE",
                    "--failed",
                    "--list",
                    "--shuffle",
                    "--repeat N",
                    "--retry N",
                    "--seed SEED",
                    "--runs N",
                    "--replay SEED",
                    "--exhaustive",
                    "--budget S",
                    "--test-timeout S",
                    "--deadline S",
                    "--allow-focused",
                    "-x / --fail-fast",
                    "--compact",
                    "--slowest N",
                    "--timeout S",
                    "--keep",
                    "--launcher CMD",
                    "--affected [REV]",
                    "--changed [REV]",
                    "-u / --update-snapshots",
                    "--prune-snapshots",
                    "--strict-assertions",
                    "--save-regressions",
                    "--bench",
                    "--ci",
                    "--agent",
                    "--format human|agent|json",
                    "--json-out FILE",
                    "--junit FILE",
                    "--check",
                    "--suite NAME",
                ],
            },
            "cloud": {
                "summary": "run specs in parallel shards on Open Cloud Luau Execution",
                "flags": [
                    "--project FILE",
                    "--script FILE",
                    "--place FILE",
                    "--place-version N",
                    "--output FILE",
                    "--shard NAME",
                    "-j / --jobs N",
                    "--timeout S",
                    "--json-out FILE",
                    "--junit FILE",
                    "--agent",
                    "--format human|agent|json",
                    "--unsharded",
                    "--dry-run",
                    "--emit DIR",
                ],
            },
            "lint": {
                "summary": "luau-lsp analyze, type probes, StyLua, selene, and stub sync",
                "flags": [
                    "--fix",
                    "--dry-run",
                    "--only CHECK",
                    "--skip CHECK",
                    "--agent",
                    "--format human|agent|json",
                ],
            },
            "coverage": {
                "summary": "summarize luau --coverage LCOV output",
                "flags": [
                    "[file]",
                    "--min PCT",
                    "--uncovered",
                    "--diff [REV]",
                    "--badge [FILE]",
                    "--agent",
                    "--format human|agent|json",
                ],
            },
            "mutate": {
                "summary": "coverage-guided Luau token mutation testing",
                "flags": [
                    "[paths...]",
                    "--diff [REV]",
                    "--min PCT",
                    "--max-mutants N",
                    "-j / --jobs N",
                    "--timeout S",
                    "--operators OPS",
                    "--coverage-file FILE",
                    "--no-coverage-run",
                    "--no-cache",
                    "--strict-cache",
                    "--agent",
                    "--format human|agent|json",
                ],
            },
        },
        "luau_apis": {
            "snapshots": ["sert.inlineSnapshot", "sert.snapshot"],
            "env": ["sert.env.new", "sert.env.installGlobals"],
            "sim": [
                "sert.sim.vopr",
                "sert.sim.check",
                "sert.sim.explore",
                "sert.sim.verifyTrace",
                "sert.sim.linearizable",
                "sert.sim.recorder",
                "sert.sim.spec",
            ],
            "perf": ["sert.noAllocs", "sert.maxAllocs", "sert.allocs", "sert.bench"],
            "properties": [
                "sert.prop",
                "sert.laws",
                "sert.laws.metamorphic",
                "sert.laws.complexity",
                "sert.model",
                "sert.gen",
            ],
            "roblox": [
                "sert.roblox.conformance",
                "sert.roblox.Layout",
                "sert.roblox.Layout.matrix",
                "sert.roblox.Layout.audit",
                "sert.roblox.Flicker",
                "sert.roblox.fuzzRemote",
                "sert.roblox.Runner",
                "sert.roblox.sweep",
            ],
        },
        "artifacts": {
            "regressions": "test/.sert-regressions.toml",
            "file_snapshots": "test/__snapshots__/<stem>.snap",
            "bench_baselines": ".sert/bench/<name>.json",
            "coverage_map": ".sert/coverage-map.json",
            "last_failed": ".sert/last-failed.json",
        },
    }


def install_skill(target_dir: Path, *, force: bool = True) -> Path:
    dest = target_dir if target_dir.name == "SKILL.md" else (target_dir / "SKILL.md")
    if dest.exists() and not force:
        return dest
    write_atomic(dest, render_skill_markdown().encode("utf-8"))
    return dest
