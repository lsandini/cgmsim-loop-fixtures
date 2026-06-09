# cgmsim-loop-fixtures — Setup Guide
*Continue from here in VSCode with Claude Code*

---

## Context

You have:
- Created the `cgmsim-loop-fixtures` repo on GitHub
- Cloned it locally
- Initialized the `LoopWorkspace` submodule recursively

The goal is to build a Swift command-line harness that calls Loop's core math functions (insulin effect, carb absorption, dosing logic), feeds them JSON scenarios, and outputs JSON fixture files. These fixtures will be used in CGMSIM's JS test suite to validate the Loop controller port.

---

## Repo structure to build toward

```
cgmsim-loop-fixtures/
├── .github/
│   └── workflows/
│       └── generate-fixtures.yml    ← macOS CI runner: builds harness, commits fixtures
├── LoopWorkspace/                   ← git submodule (LoopKit/LoopWorkspace)
├── Harness/
│   ├── Package.swift                ← Swift package, links against LoopKit source
│   └── Sources/
│       └── Harness/
│           └── main.swift           ← reads scenario JSON → computes → prints fixture JSON
└── fixtures/
    ├── insulin_fiasp_1u.json
    ├── carb_absorption_linear.json
    └── ...
```

---

## Step 1 — Create the Swift Package

Ask Claude Code to create `Harness/Package.swift` with the following intent:

- Swift tools version 5.9
- Executable target named `Harness`
- Sources in `Sources/Harness/`
- Dependencies pulled **locally** from the submodule paths (no remote URLs needed since the submodule is already present):
  - `LoopWorkspace/LoopKit` → provides `LoopKit` library
  - `LoopWorkspace/Loop` → provides dosing logic (optional for first pass)

**Suggested prompt for Claude Code:**
```
Create Harness/Package.swift for a Swift executable that depends locally on
LoopWorkspace/LoopKit. The target is named Harness, sources in Sources/Harness/.
Use Swift tools version 5.9. Use local path dependencies only, no remote URLs.
```

---

## Step 2 — Create main.swift (first scenario: Fiasp 1U bolus insulin effect)

The first scenario should be the simplest possible end-to-end test:
- Input: a single bolus dose of 1U Fiasp at time zero
- Output: the insulin effect curve (glucose effect per interval) over 6 hours at 5-minute resolution

**Suggested prompt for Claude Code:**
```
Create Harness/Sources/Harness/main.swift that:
1. Defines a hardcoded Fiasp dose of 1U at time zero
2. Calls LoopKit's InsulinMath to compute the insulin effect curve
3. Outputs the result as a JSON array to stdout
4. Each element has fields: minutesFromBolus (Int), insulinEffect (Double)
Use Fiasp exponential model parameters as used in LoopKit.
```

---

## Step 3 — Verify local build (optional but recommended)

If you have Swift available locally (even a partial install), try:
```bash
cd Harness
swift build
swift run
```

If Swift is not available in WSL2, skip this — the Actions runner will be the build environment. Don't spend time installing Swift locally.

---

## Step 4 — Create the GitHub Actions workflow

This is the core of the approach. The workflow:
1. Runs on `macos-15` runner (has Xcode + Swift preinstalled)
2. Checks out the repo **with submodules**
3. Builds and runs the harness
4. Captures stdout as a fixture JSON file
5. Commits and pushes the fixture back to the repo

**Suggested prompt for Claude Code:**
```
Create .github/workflows/generate-fixtures.yml that:
- Triggers on push to main when anything in Harness/ changes, and also on workflow_dispatch
- Uses macos-15 runner
- Checks out the repo with submodules (recurse-submodules: true)
- Builds the Swift package in Harness/ with swift build -c release
- Runs the executable and redirects stdout to fixtures/insulin_fiasp_1u.json
- Commits and pushes the fixture file back to the repo using git
- Uses GITHUB_TOKEN for push authentication
```

---

## Step 5 — Push and trigger the first run

```bash
git add .
git commit -m "Add Swift harness and CI workflow"
git push origin main
```

Then go to your repo on GitHub → **Actions** tab → watch the `generate-fixtures` workflow run. The first run will likely fail — that's expected. Common first-run issues and fixes:

| Problem | Likely cause | Fix |
|---|---|---|
| Submodule folders empty | Workflow missing `submodules: recursive` | Add `submodules: 'recursive'` to checkout action |
| `Package.swift` can't find LoopKit | Local path wrong | Check relative path from `Harness/` to `LoopWorkspace/LoopKit` |
| Compile error in main.swift | LoopKit API mismatch | Check actual function signatures in `LoopWorkspace/LoopKit/Sources/` |
| Git push fails in workflow | Permissions | Add `permissions: contents: write` to the workflow YAML |

---

## Step 6 — Expand scenarios incrementally

Once the first fixture generates cleanly, add further scenarios one at a time:

- `carb_absorption_linear.json` — 40g carbs, linear absorption model
- `carb_absorption_parabolic.json` — same, parabolic model
- `insulin_novorapid_1u.json` — repeat with Rapid-Acting Oref model
- `retrospective_correction.json` — glucose history input → RC effect output
- `dosing_recommendation.json` — full loop cycle: glucose + IOB + COB → recommended dose

Each new scenario = a new function in `main.swift` + a new output file in the workflow.

---

## Key LoopKit source files to be aware of

When Claude Code needs to look up actual API signatures, these are the files to reference:

```
LoopWorkspace/LoopKit/Sources/LoopKit/InsulinKit/InsulinMath.swift
LoopWorkspace/LoopKit/Sources/LoopKit/CarbKit/CarbMath.swift
LoopWorkspace/LoopKit/Sources/LoopKit/LoopMath.swift
LoopWorkspace/Loop/Loop/Managers/LoopDataManager.swift
```

Ask Claude Code to read these before writing harness code — the actual function signatures matter and change between LoopKit versions.

---

## How the fixtures connect back to CGMSIM

Once fixtures are committed to this repo, in your CGMSIM JS test suite:

```js
// Option A: commit fixtures as a submodule or copy
import expected from '../cgmsim-loop-fixtures/fixtures/insulin_fiasp_1u.json'

// Option B: fetch from raw GitHub URL in CI
const expected = await fetch(
  'https://raw.githubusercontent.com/YOUR_USER/cgmsim-loop-fixtures/main/fixtures/insulin_fiasp_1u.json'
).then(r => r.json())

// Then in your Jest test:
test('Fiasp 1U effect curve matches Loop reference', () => {
  const result = computeInsulinEffect({ dose: 1, model: 'fiasp' })
  expected.forEach(({ minutesFromBolus, insulinEffect }) => {
    expect(result[minutesFromBolus]).toBeCloseTo(insulinEffect, 4)
  })
})
```

---

## Notes

- You never need Swift installed locally — the `macos-15` GitHub Actions runner handles all compilation.
- The fixture JSON files are plain committed files — no build artifacts, no secrets, no tokens beyond `GITHUB_TOKEN`.
- If LoopKit's API surface changes in a future submodule update, your harness will fail to compile and CI will catch it before any fixtures are overwritten.
- Tolerance in JS tests: `toBeCloseTo(value, 4)` (4 decimal places) is appropriate for insulin effect curves. Floating point differences between Swift `Double` and JS `number` are negligible at this precision for clinical purposes.
