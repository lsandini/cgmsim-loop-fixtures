// Harness — emits LoopKit reference fixtures for the CGMSIM JS parity suite.
//
// Reads a scenario JSON (argv[1]), computes via the real, unmodified LoopKit
// math, and prints the resulting fixture JSON to stdout. No `Date()` is ever
// called, so the output is byte-identical run-to-run for a given scenario.
//
// First milestone: kind == "insulin_effect" — the glucose-effect curve of a
// single bolus, via the exact call path the iOS app uses
// (`[DoseEntry].glucoseEffects(...)`, LoopKit/InsulinKit/InsulinMath.swift).

import Foundation
import HealthKit
import LoopKit

// MARK: - Scenario / fixture models

struct Scenario: Decodable {
    let kind: String
    let anchor: String                       // fixed ISO-8601 UTC timestamp
    let doseUnits: Double
    let insulinModel: String                 // "fiasp" | "lyumjev" | "afrezza" | "novolog" ...
    let insulinSensitivity_mgdLperU: Double
    let durationHours: Double
    let deltaMinutes: Double
}

struct FixturePoint: Encodable {
    let minutesFromBolus: Int
    let glucoseEffect: Double                 // cumulative mg/dL (negative = lowering)
}

// MARK: - Helpers

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("error: \(message)\n".utf8))
    exit(1)
}

func insulinType(named name: String) -> InsulinType {
    switch name.lowercased() {
    case "fiasp":   return .fiasp
    case "lyumjev": return .lyumjev
    case "afrezza": return .afrezza
    // "novolog" / "humalog" / "apidra" / "rapidactingadult" → provider's
    // default rapid-acting model (ExponentialInsulinModelPreset.rapidActingAdult).
    default:        return .novolog
    }
}

// MARK: - Read scenario

guard CommandLine.arguments.count >= 2 else { fail("usage: Harness <scenario.json>") }
let scenarioPath = CommandLine.arguments[1]

guard let data = FileManager.default.contents(atPath: scenarioPath) else {
    fail("cannot read scenario file: \(scenarioPath)")
}

let scenario: Scenario
do {
    scenario = try JSONDecoder().decode(Scenario.self, from: data)
} catch {
    fail("cannot decode scenario: \(error)")
}

guard scenario.kind == "insulin_effect" else {
    fail("unknown scenario kind: \(scenario.kind)")
}

// Deterministic UTC parse — never Date().
let iso = ISO8601DateFormatter()
iso.formatOptions = [.withInternetDateTime]
iso.timeZone = TimeZone(identifier: "UTC")
guard let anchor = iso.date(from: scenario.anchor) else {
    fail("cannot parse anchor date: \(scenario.anchor)")
}

// MARK: - Compute via LoopKit (exact iOS-app call path)

let type = insulinType(named: scenario.insulinModel)

let dose = DoseEntry(
    type: .bolus,
    startDate: anchor,
    endDate: anchor,
    value: scenario.doseUnits,
    unit: .units,
    insulinType: type
)

let provider = PresetInsulinModelProvider(defaultRapidActingModel: nil)
let model = provider.model(for: type)

let isfUnit = HKUnit(from: "mg/dL").unitDivided(by: HKUnit.internationalUnit())
guard let sensitivity = InsulinSensitivitySchedule(
    unit: isfUnit,
    dailyItems: [RepeatingScheduleValue(startTime: 0, value: scenario.insulinSensitivity_mgdLperU)]
) else {
    fail("cannot build insulin sensitivity schedule")
}

let longestEffectDuration = max(model.effectDuration, scenario.durationHours * 3600.0)
let delta = scenario.deltaMinutes * 60.0

let effects = [dose].glucoseEffects(
    insulinModelProvider: provider,
    longestEffectDuration: longestEffectDuration,
    insulinSensitivity: sensitivity,
    delta: delta
)

// MARK: - Emit fixture JSON

let mgdL = HKUnit(from: "mg/dL")
let points = effects.map { effect in
    FixturePoint(
        minutesFromBolus: Int((effect.startDate.timeIntervalSince(anchor) / 60.0).rounded()),
        glucoseEffect: effect.quantity.doubleValue(for: mgdL)
    )
}

let encoder = JSONEncoder()
encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
do {
    let out = try encoder.encode(points)
    FileHandle.standardOutput.write(out)
    FileHandle.standardOutput.write(Data("\n".utf8))
} catch {
    fail("cannot encode fixture: \(error)")
}
