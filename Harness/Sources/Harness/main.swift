// Harness — emits LoopKit reference fixtures for the CGMSIM JS parity suite.
//
// Reads a scenario JSON (argv[1]), dispatches on its "kind", computes via the
// real, unmodified LoopKit math, and prints the resulting fixture JSON to
// stdout. No `Date()` is ever called, so output is deterministic per scenario.
//
// Kinds:
//   "insulin_effect"        — glucose-effect curve of a single bolus (InsulinMath).
//   "dosing_recommendation" — recommendedManualBolus for a glucose curve (DoseMath).

import Foundation
import HealthKit
import LoopKit

// MARK: - Shared helpers

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("error: \(message)\n".utf8))
    exit(1)
}

// mg/dL constructed exactly as LoopKit's (internal) HKUnit.milligramsPerDeciliter
// = gramUnit(.milli) / literUnit(.deci), so doubleValue(for:) conversions are identities.
let mgdLUnit = HKUnit.gramUnit(with: .milli).unitDivided(by: HKUnit.literUnit(with: .deci))

// Deterministic UTC ISO-8601 parser — never Date(). The dosing scenario uses flat
// (all-day) target/ISF schedules, so the absolute timezone is irrelevant to the
// result; only relative offsets between glucose points matter.
let isoUTC: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime]
    f.timeZone = TimeZone(identifier: "UTC")
    return f
}()

let jsonEncoder: JSONEncoder = {
    let e = JSONEncoder()
    e.outputFormatting = [.prettyPrinted, .sortedKeys]
    return e
}()

func emit<T: Encodable>(_ value: T) {
    do {
        let out = try jsonEncoder.encode(value)
        FileHandle.standardOutput.write(out)
        FileHandle.standardOutput.write(Data("\n".utf8))
    } catch {
        fail("cannot encode fixture: \(error)")
    }
}

func insulinType(named name: String) -> InsulinType {
    switch name.lowercased() {
    case "fiasp":   return .fiasp
    case "lyumjev": return .lyumjev
    case "afrezza": return .afrezza
    default:        return .novolog   // → provider default rapid-acting model
    }
}

/// Minimal public GlucoseValue conformer (the test's SimpleGlucoseFixtureValue is
/// test-target-only; GlucoseValue only requires startDate + quantity).
struct SimpleGlucose: GlucoseValue {
    let startDate: Date
    let quantity: HKQuantity
}

// MARK: - kind: insulin_effect

func runInsulinEffect(_ data: Data) {
    struct Scenario: Decodable {
        let anchor: String
        let doseUnits: Double
        let insulinModel: String
        let insulinSensitivity_mgdLperU: Double
        let durationHours: Double
        let deltaMinutes: Double
    }
    struct FixturePoint: Encodable {
        let minutesFromBolus: Int
        let glucoseEffect: Double      // cumulative mg/dL (negative = lowering)
    }

    guard let s = try? JSONDecoder().decode(Scenario.self, from: data) else {
        fail("cannot decode insulin_effect scenario")
    }
    guard let anchor = isoUTC.date(from: s.anchor) else { fail("cannot parse anchor: \(s.anchor)") }

    let type = insulinType(named: s.insulinModel)
    let dose = DoseEntry(type: .bolus, startDate: anchor, endDate: anchor,
                         value: s.doseUnits, unit: .units, insulinType: type)
    let provider = PresetInsulinModelProvider(defaultRapidActingModel: nil)
    let model = provider.model(for: type)

    guard let sensitivity = InsulinSensitivitySchedule(
        unit: mgdLUnit,
        dailyItems: [RepeatingScheduleValue(startTime: 0, value: s.insulinSensitivity_mgdLperU)]
    ) else { fail("cannot build insulin sensitivity schedule") }

    let longest = max(model.effectDuration, s.durationHours * 3600.0)
    let effects = [dose].glucoseEffects(
        insulinModelProvider: provider,
        longestEffectDuration: longest,
        insulinSensitivity: sensitivity,
        delta: s.deltaMinutes * 60.0
    )

    let points = effects.map { effect in
        FixturePoint(
            minutesFromBolus: Int((effect.startDate.timeIntervalSince(anchor) / 60.0).rounded()),
            glucoseEffect: effect.quantity.doubleValue(for: mgdLUnit)
        )
    }
    emit(points)
}

// MARK: - kind: dosing_recommendation

func runDosingRecommendation(_ data: Data) {
    struct GlucosePoint: Decodable { let date: String; let value: Double }
    struct Scenario: Decodable {
        let glucose: [GlucosePoint]
        let targetLow_mgdL: Double
        let targetHigh_mgdL: Double
        let suspendThreshold_mgdL: Double
        let insulinSensitivity_mgdLperU: Double
        let peakActivityMinutes: Double
        let actionDurationHours: Double
        let pendingInsulin: Double
        let maxBolus: Double
    }
    struct Fixture: Encodable {
        let recommendedBolusUnits: Double   // raw amount (no volume rounder), like the LoopKit test
    }

    guard let s = try? JSONDecoder().decode(Scenario.self, from: data) else {
        fail("cannot decode dosing_recommendation scenario")
    }

    let glucose: [SimpleGlucose] = s.glucose.map { pt in
        guard let d = isoUTC.date(from: pt.date) else { fail("cannot parse glucose date: \(pt.date)") }
        return SimpleGlucose(startDate: d, quantity: HKQuantity(unit: mgdLUnit, doubleValue: pt.value))
    }
    guard let first = glucose.first else { fail("empty glucose array") }

    guard let target = GlucoseRangeSchedule(
        unit: mgdLUnit,
        dailyItems: [RepeatingScheduleValue(startTime: 0, value: DoubleRange(minValue: s.targetLow_mgdL, maxValue: s.targetHigh_mgdL))]
    ) else { fail("cannot build glucose target range schedule") }

    guard let sensitivity = InsulinSensitivitySchedule(
        unit: mgdLUnit,
        dailyItems: [RepeatingScheduleValue(startTime: 0, value: s.insulinSensitivity_mgdLperU)]
    ) else { fail("cannot build insulin sensitivity schedule") }

    // Direct ExponentialInsulinModel (matches testDoseWithChildCurve, delay defaults to 600s).
    let model = ExponentialInsulinModel(
        actionDuration: s.actionDurationHours * 3600.0,
        peakActivityTime: s.peakActivityMinutes * 60.0
    )
    let suspend = HKQuantity(unit: mgdLUnit, doubleValue: s.suspendThreshold_mgdL)

    // No volumeRounder → raw bolus (the LoopKit test compares the unrounded value
    // at 1/40 accuracy; we mirror that so the JS raw correction is comparable).
    let dose = glucose.recommendedManualBolus(
        to: target,
        at: first.startDate,
        suspendThreshold: suspend,
        sensitivity: sensitivity,
        model: model,
        pendingInsulin: s.pendingInsulin,
        maxBolus: s.maxBolus
    )

    emit(Fixture(recommendedBolusUnits: dose.amount))
}

// MARK: - Dispatch

struct KindOnly: Decodable { let kind: String }

guard CommandLine.arguments.count >= 2 else { fail("usage: Harness <scenario.json>") }
let scenarioPath = CommandLine.arguments[1]
guard let data = FileManager.default.contents(atPath: scenarioPath) else {
    fail("cannot read scenario file: \(scenarioPath)")
}
guard let kind = (try? JSONDecoder().decode(KindOnly.self, from: data))?.kind else {
    fail("cannot read scenario kind from \(scenarioPath)")
}

switch kind {
case "insulin_effect":        runInsulinEffect(data)
case "dosing_recommendation": runDosingRecommendation(data)
default:                      fail("unknown scenario kind: \(kind)")
}
