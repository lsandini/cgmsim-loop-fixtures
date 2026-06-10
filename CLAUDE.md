# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

A Swift command-line harness that calls the **real, unmodified LoopKit math** (insulin effect, dosing recommendations) and emits JSON fixture files. Those fixtures are the reference oracle for CGMSIM's JavaScript port of the Loop controller — the JS test suite asserts its own computations against them to `toBeCloseTo(value, 4)` fidelity.

The whole point is fidelity to the iOS app: **never modify LoopKit's math.** If LoopKit's API changes under a submodule bump, the harness should fail to compile in CI rather than silently produce wrong numbers.

## Architecture and data flow

```
scenarios/*.json   →   Harness (Swift CLI, links LoopKit submodule)   →   fixtures/*.json
 (committed input)      Sources/Harness/main.swift                        (CI-generated, committed back)
```

- **`scenarios/*.json`** — committed inputs. Each has a `"kind"` field that selects the computation. The basename of the scenario file determines the output fixture name (`scenarios/foo.json` → `fixtures/foo.json`).
- **`Harness/Sources/Harness/main.swift`** — reads `argv[1]` (a scenario path), decodes `"kind"`, dispatches to the matching `run*` function, computes via LoopKit, and prints fixture JSON to **stdout**. Any error → stderr + non-zero exit so CI fails loudly.
- **`fixtures/*.json`** — outputs. The GitHub Actions workflow generates and commits these; they are plain committed files (not build artifacts).
- **`LoopWorkspace/`** — git submodule (`LoopKit/LoopWorkspace`). Only the nested `LoopKit` submodule is actually used; the ~19 device/service submodules (Omnipod, Dexcom, Nightscout, …) are never initialized.

### Scenario kinds (in `main.swift`)

- **`insulin_effect`** → `[DoseEntry].glucoseEffects(...)` (InsulinMath). Emits a cumulative glucose-effect curve: array of `{minutesFromBolus, glucoseEffect}` (mg/dL, negative = lowering), one point per `deltaMinutes`.
- **`dosing_recommendation`** → `[GlucoseValue].recommendedManualBolus(...)` (DoseMath). Emits `{recommendedBolusUnits}` — the **raw** unrounded amount (no volume rounder), mirroring the LoopKit unit test it parallels.

Each scenario's `_comment` field documents which LoopKit unit test it mirrors and the expected Swift assertion value — preserve these when editing.

### Adding work

- **New scenario for an existing kind** = just a new JSON file in `scenarios/`. No Swift changes.
- **New kind** = a new `run<Kind>` function in `main.swift` plus a `case` in the dispatch `switch` at the bottom. Read the actual LoopKit signatures first (see source files below) — they change between LoopKit versions.

## Determinism (critical invariant)

Fixtures must be byte-identical run-to-run. The harness **never calls `Date()`**. Timestamps come only from scenario JSON, parsed with a fixed UTC `ISO8601DateFormatter` (`isoUTC`). JSON output uses `.sortedKeys` + `.prettyPrinted`. Dosing scenarios use flat all-day target/ISF schedules, so absolute timezone is irrelevant — only relative offsets between glucose points matter. Don't introduce wall-clock time, locale, or unsorted-key output.

## The macOS build trick

LoopKit's `Package.swift` declares `platforms: [.iOS("15.0")]`, so SwiftPM won't build it into a macOS executable as-is. The CI workflow **patches `.macOS("13.0")` onto LoopKit's manifest at build time only** (a `sed -i ''`), leaving the submodule pristine in git. This is safe because:

- LoopKit's math is plain `Double` IEEE-754 arithmetic — identical on macOS and iOS.
- HealthKit (`HKQuantity`/`HKUnit`, used pervasively by LoopKit) is available on macOS 13+.
- The core `LoopKit` target has no package dependencies (SwiftCharts is only pulled by `LoopKitUI`/tests, which we don't link).

`Harness/Package.swift` correspondingly declares `platforms: [.macOS("13.0")]`. If a submodule bump changes LoopKit's platform line, the `sed` patch self-checks and fails CI with a clear error.

## Commands

There is **no local Swift toolchain requirement** — the `macos-15` GitHub Actions runner is the build environment. Pushing changes under `Harness/`, `scenarios/`, or the workflow file triggers `.github/workflows/generate-fixtures.yml`, which inits only `LoopWorkspace → LoopKit`, patches the manifest, builds, runs every scenario, and commits regenerated fixtures.

If you do have Swift locally (macOS), the same steps the CI runs are:

```bash
swift build -c release --package-path Harness
Harness/.build/release/Harness scenarios/insulin_fiasp_1u.json > fixtures/insulin_fiasp_1u.json
```

Quick commit + push (also runnable as `./deploy.sh` — but edit its hardcoded message first):

```bash
git add . && git commit -m "..." && git push -u origin main
```

## Key LoopKit source files (for API signatures)

```
LoopWorkspace/LoopKit/Sources/LoopKit/InsulinKit/InsulinMath.swift   ← glucoseEffects on [DoseEntry]
LoopWorkspace/LoopKit/Sources/LoopKit/InsulinKit/DoseMath.swift      ← recommendedManualBolus
LoopWorkspace/LoopKit/Sources/LoopKit/CarbKit/CarbMath.swift
LoopWorkspace/LoopKit/Sources/LoopKit/LoopMath.swift
```

## Further reading

- `docs/superpowers/specs/2026-06-09-cgmsim-loop-fixtures-design.md` — full design rationale, rejected alternatives, and how fixtures connect back to CGMSIM's Jest suite.
- `cgmsim-loop-fixtures-setup.md` — the original step-by-step build guide.
