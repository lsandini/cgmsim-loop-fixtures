# cgmsim-loop-fixtures — Design Spec

*Date: 2026-06-09*

## Purpose

Generate reference fixture data from the **real, unmodified LoopKit Swift math** so that CGMSIM's JavaScript port of the Loop controller can be validated to byte-for-byte (within `toBeCloseTo(_, 4)`) fidelity.

Everything runs on GitHub Actions. No local Swift toolchain is required. A `macos-15` runner builds a small Swift command-line harness that links LoopKit from the submodule, computes a curve (starting with the Fiasp 1U insulin effect over 6 hours at 5-minute resolution), and emits a JSON fixture. CI commits the fixture back to the repo, and CGMSIM's Jest suite asserts its own computations against it.

## Goals

- Produce deterministic, reproducible fixture JSON from LoopKit's actual functions.
- Touch **zero lines of LoopKit's math** — fidelity to the iOS app is the whole point.
- Drive the harness from JSON scenario files so new scenarios are data, not code rewrites.
- Walking-skeleton first: one fixture (`insulin_fiasp_1u`) flowing end-to-end to green CI before expanding.

## Non-goals (for the first milestone)

- Carb absorption, alternate insulin models, retrospective correction, and full dosing recommendations. These are deferred follow-up scenarios (see "Future scenarios").
- Running anything locally. No local build is part of the deliverable.
- Linking `LoopKitUI`, `MockKit`, or the `Loop` app target (UIKit / Xcode-project-only — out of scope).

## Key constraint discovered during exploration

LoopKit's `Package.swift` declares `platforms: [.iOS("15.0")]` (`LoopWorkspace/LoopKit/Package.swift:14`). SwiftPM will refuse to build it into a macOS executable as written. Two facts make this a non-problem:

1. LoopKit's insulin math is plain `Double` IEEE-754 arithmetic — identical results on macOS and iOS. Building for macOS yields the same numbers the iOS app produces.
2. HealthKit (`HKQuantity` / `HKUnit`, used pervasively by LoopKit) is available on macOS 13+, so a macOS 13+ CLI can link LoopKit without mocking HealthKit.

The core `LoopKit` library target also has **no package dependencies** (`dependencies: []`); SwiftCharts is pulled only by `LoopKitUI` and the test target, neither of which we use.

**Resolution:** the CI workflow patches `.macOS("13.0")` onto LoopKit's manifest *at build time only* (a `sed`), leaving the submodule pristine in git. No math is modified.

Rejected alternatives: **xcodebuild for iOS** (an iOS binary can't be run on the runner to emit stdout without a simulator); **vendoring the math files** (drifts from upstream LoopKit, defeats the fidelity goal).

## Repository layout

```
cgmsim-loop-fixtures/
├── .github/workflows/generate-fixtures.yml   ← macOS CI: patch manifest, build, run, commit fixtures
├── LoopWorkspace/                             ← git submodule (LoopKit/LoopWorkspace), already initialized
├── Harness/
│   ├── Package.swift                          ← tools 5.9, executable "Harness", local path dep on LoopKit
│   └── Sources/Harness/main.swift             ← reads scenario JSON → computes via LoopKit → prints fixture JSON
├── scenarios/
│   └── insulin_fiasp_1u.json                  ← committed input
└── fixtures/
    └── insulin_fiasp_1u.json                  ← CI-generated output, committed back
```

## Components

### Harness/Package.swift

- `swift-tools-version: 5.9`
- One executable target `Harness`, sources in `Sources/Harness/`.
- Single local path dependency: `.package(path: "../LoopWorkspace/LoopKit")`, target depends on product `"LoopKit"`.
- Declares `platforms: [.macOS("13.0")]` (needed for HealthKit on macOS and to match the patched LoopKit platform).
- No remote URLs.

### Harness/Sources/Harness/main.swift

Flow:

1. Read a scenario file path from `argv[1]`.
2. Decode it into a `Scenario` struct (`Codable`).
3. Dispatch on `Scenario.kind`. First milestone implements only `"insulin_effect"`.
4. Compute via LoopKit (see below).
5. Encode the resulting fixture array to **stdout** as JSON.
6. On any error (missing arg, decode failure, unknown kind), print a clear message to stderr and exit non-zero so CI fails loudly.

**`Scenario` shape (for `kind: "insulin_effect"`):**

```json
{
  "kind": "insulin_effect",
  "anchor": "2025-01-01T00:00:00Z",
  "doseUnits": 1.0,
  "insulinModel": "fiasp",
  "insulinSensitivity_mgdLperU": 50.0,
  "durationHours": 6,
  "deltaMinutes": 5
}
```

- `anchor` is a **fixed ISO-8601 timestamp**, decoded with a fixed UTC `ISO8601DateFormatter`. The harness never calls `Date()`, so output is identical run-to-run.
- `insulinModel` maps to LoopKit's `InsulinType` / `ExponentialInsulinModelPreset` (`"fiasp"` → `.fiasp`).

**Computation (the exact LoopKit call path the iOS app uses):**

- `let anchor = <parsed ISO-8601 date>`
- `let dose = DoseEntry(type: .bolus, startDate: anchor, endDate: anchor, value: doseUnits, unit: .units, insulinType: .fiasp)`
- `let provider = PresetInsulinModelProvider(defaultRapidActingModel: nil)` (resolves `.fiasp` → `ExponentialInsulinModelPreset.fiasp`)
- A constant `InsulinSensitivitySchedule` built from `insulinSensitivity_mgdLperU`:
  `InsulinSensitivitySchedule(unit: HKUnit.milligramsPerDeciliter.unitDivided(by: .internationalUnit()), dailyItems: [RepeatingScheduleValue(startTime: 0, value: insulinSensitivity_mgdLperU)])`
  (single all-day value → no schedule-boundary effects)
- `let effects = [dose].glucoseEffects(insulinModelProvider: provider, longestEffectDuration: <model action duration + delay, ≥ durationHours>, insulinSensitivity: schedule, delta: TimeInterval(minutes: deltaMinutes))`

LoopKit's `glucoseEffects(...)` lives at `LoopWorkspace/LoopKit/LoopKit/InsulinKit/InsulinMath.swift` (extension on `Collection where Element == DoseEntry`).

### Fixture output

A JSON array, full `Double` precision, one element per `deltaMinutes` step:

```json
[
  { "minutesFromBolus": 0, "glucoseEffect": 0.0 },
  { "minutesFromBolus": 5, "glucoseEffect": -0.123456789 },
  ...
]
```

- `minutesFromBolus`: `Int`, computed as `(effect.startDate - anchor) / 60`.
- `glucoseEffect`: `Double`, **cumulative** glucose effect in mg/dL — exactly what `GlucoseEffect.quantity.doubleValue(for: .milligramsPerDeciliter)` returns. This cumulative value is the canonical thing the JS port should reproduce. Negative values represent glucose lowering.
- ISF is fixed by the scenario, so the curve is fully determined; the JS side uses the same ISF.

### .github/workflows/generate-fixtures.yml

- Triggers: `push` to `main` affecting `Harness/**` or `scenarios/**`; plus `workflow_dispatch`.
- Runner: `macos-15`.
- `permissions: contents: write` (so the bot can push fixtures back).
- Steps:
  1. `actions/checkout` with `submodules: recursive`.
  2. Patch LoopKit's manifest to add macOS support (e.g. `sed -i '' 's/platforms: \[.iOS("15.0")\]/platforms: [.iOS("15.0"), .macOS("13.0")]/' LoopWorkspace/LoopKit/Package.swift`).
  3. `swift build -c release --package-path Harness`.
  4. For each scenario in `scenarios/`, run the executable with the scenario path and redirect stdout to the matching `fixtures/<name>.json`.
  5. Commit any changed files under `fixtures/` and push, using `GITHUB_TOKEN`. No-op cleanly if nothing changed.

The manifest patch is never committed (the submodule working tree change is discarded / not staged).

## Data flow

```
scenarios/insulin_fiasp_1u.json
        │  (argv)
        ▼
  Harness (Swift, links LoopKit) ── glucoseEffects() ──▶ stdout JSON
        │  (CI redirect)
        ▼
fixtures/insulin_fiasp_1u.json  ──commit/push──▶ repo
        │  (import / raw fetch)
        ▼
CGMSIM Jest:  expect(jsResult[minutesFromBolus]).toBeCloseTo(glucoseEffect, 4)
```

## Error handling

- Harness exits non-zero with a stderr message on: missing scenario arg, unreadable/undecodable scenario, unknown `kind`, or a `nil` from an optional LoopKit initializer (e.g. the ISF schedule). A non-zero exit fails the CI step before any fixture is overwritten with garbage.
- If LoopKit's API surface changes in a future submodule bump, the harness fails to compile and CI catches it before fixtures are touched.
- The commit/push step is a clean no-op when no fixture content changed.

## Testing / verification

- Primary verification is the CI run itself: green workflow + a committed, non-empty `fixtures/insulin_fiasp_1u.json` with the expected shape and a plausible curve (starts at 0, dips to a trough around the model peak, returns toward 0 by ~6h).
- Sanity checks on the generated curve: first element `minutesFromBolus == 0`; element count `== durationHours*60/deltaMinutes + 1` (boundary inclusive — exact count confirmed against actual LoopKit output during implementation); monotonic-then-recovering shape; all `glucoseEffect <= 0`.
- No local Swift run is required or expected; the runner is the build/test environment.

## Future scenarios (deferred)

Each is a new `kind` in `main.swift` + a new `scenarios/*.json` + the workflow loop already iterating all scenarios:

- `carb_absorption_linear` / `carb_absorption_parabolic` — `CarbMath`.
- `insulin_novorapid_1u` — `insulinModel: "rapidActingAdult"`.
- `retrospective_correction` — glucose history → RC effect (`LoopMath`).
- `dosing_recommendation` — full loop cycle (glucose + IOB + COB → recommended dose).

## Open risks

- LoopKit's manifest header warns "Not complete yet, do not expect this to work" regarding resource-bundle handling. The core `LoopKit` target declares no resources, but a CoreData `.xcdatamodeld` in its sources could force an explicit resource declaration. If `swift build` complains, the fix is contained to the CI patch step (handle the resource) — this is anticipated first-run iteration, not a design flaw.
- Exact boundary element count and the precise `longestEffectDuration` needed to capture the full tail will be confirmed against real LoopKit output during the walking-skeleton run.
