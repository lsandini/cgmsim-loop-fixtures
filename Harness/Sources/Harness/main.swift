// Harness — emits LoopKit reference fixtures for the CGMSIM JS parity suite.
//
// Reads a scenario JSON (argv[1]), dispatches on its "kind", computes via the
// real, unmodified LoopKit math, and prints the resulting fixture JSON to
// stdout. No `Date()` is ever called, so output is deterministic per scenario.
//
// Kinds:
//   "insulin_effect"        — glucose-effect curve of a single bolus (InsulinMath).
//   "dosing_recommendation" — recommendedManualBolus for a glucose curve (DoseMath).
//   "dynamic_carb_effect"   — PRODUCTION carb path: entries + ICE → map(to:) →
//                             dynamicGlucoseEffects + dynamicCarbsOnBoard (CarbMath).
//   "temp_basal_recommendation" — recommendedTempBasal for a glucose curve (DoseMath):
//                             the call the live closed-loop controller makes every 5 min.

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
        let delayMinutes: Double?   // optional; LoopKit ExponentialInsulinModel default delay is 10 min
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

    // Direct ExponentialInsulinModel. delayMinutes is optional: omitted ⇒ LoopKit's
    // default 600 s (10 min), used by testDose{Fiasp,Child}Curve; the class-level
    // exponentialInsulinModel (peak 75) explicitly uses delay 0.
    let model = ExponentialInsulinModel(
        actionDuration: s.actionDurationHours * 3600.0,
        peakActivityTime: s.peakActivityMinutes * 60.0,
        delay: (s.delayMinutes ?? 10.0) * 60.0
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

// MARK: - kind: temp_basal_recommendation

/// `recommendedTempBasal` — the dose the live closed-loop controller computes
/// every 5 min for deviceType 3. Reuses the dosing scenario shape (predicted
/// glucose curve + ISF + target + suspend + insulin model) plus a basal rate and
/// maxBasalRate. There is no replayable committed LoopKit fixture for this call
/// (DoseMathTests asserts hard-coded rates), so the harness adds unique value.
///
/// PARITY NOTES — the JS `recommendTempBasal`/`asTempBasal` (loopkit.js) makes two
/// choices that LoopKit leaves to the caller, so we pass them explicitly here:
///   • JS ALWAYS rounds the rate to a 0.05 U/hr increment → pass a matching
///     `rateRounder` (Swift's default is no rounding). Math.round and Swift's
///     `.rounded()` agree for positive values.
///   • JS ALWAYS applies the IOB clamp (`iobHeadroom = maxBolus*2 − currentIOB`,
///     then `maxRate = min(iobHeadroom*2 + scheduledBasal, maxRate)`) → pass
///     `additionalActiveInsulinClamp = maxBolus*2 − currentIOB` (Swift uses the
///     identical formula `clamp*2 + scheduledBasal`; its default is nil = no clamp).
/// `lastTempBasal` is nil (no continuation/cancel path), duration 30 min,
/// continuationInterval 11 min — all matching the JS constants.
func runTempBasalRecommendation(_ data: Data) {
    struct GlucosePoint: Decodable { let date: String; let value: Double }
    struct Scenario: Decodable {
        let glucose: [GlucosePoint]
        let targetLow_mgdL: Double
        let targetHigh_mgdL: Double
        let suspendThreshold_mgdL: Double
        let insulinSensitivity_mgdLperU: Double
        let peakActivityMinutes: Double
        let actionDurationHours: Double
        let delayMinutes: Double?
        let scheduledBasalRate_UperHr: Double
        let maxBasalRate_UperHr: Double
        let currentIOB: Double          // JS currentIOB (for IOB-clamp parity)
        let maxBolus: Double            // JS MAX_BOLUS (for IOB-clamp parity)
        let rateIncrement_UperHr: Double // JS rounds rate to this (0.05)
        let durationMinutes: Double      // JS TEMP_BASAL_DURATION (30)
    }
    struct Fixture: Encodable {
        let isNil: Bool                 // recommendedTempBasal returned nil (no temp needed)
        let unitsPerHour: Double?
        let durationMinutes: Double?
    }

    guard let s = try? JSONDecoder().decode(Scenario.self, from: data) else {
        fail("cannot decode temp_basal_recommendation scenario")
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

    guard let basalRates = BasalRateSchedule(
        dailyItems: [RepeatingScheduleValue(startTime: 0, value: s.scheduledBasalRate_UperHr)]
    ) else { fail("cannot build basal rate schedule") }

    let model = ExponentialInsulinModel(
        actionDuration: s.actionDurationHours * 3600.0,
        peakActivityTime: s.peakActivityMinutes * 60.0,
        delay: (s.delayMinutes ?? 10.0) * 60.0
    )
    let suspend = HKQuantity(unit: mgdLUnit, doubleValue: s.suspendThreshold_mgdL)

    // JS-parity: explicit IOB clamp + 0.05 rate rounder (see PARITY NOTES above).
    let iobHeadroom = s.maxBolus * 2.0 - s.currentIOB
    let increment = s.rateIncrement_UperHr
    let rounder: (Double) -> Double = { ($0 / increment).rounded() * increment }

    let rec = glucose.recommendedTempBasal(
        to: target,
        at: first.startDate,
        suspendThreshold: suspend,
        sensitivity: sensitivity,
        model: model,
        basalRates: basalRates,
        maxBasalRate: s.maxBasalRate_UperHr,
        additionalActiveInsulinClamp: iobHeadroom,
        lastTempBasal: nil,
        rateRounder: rounder,
        isBasalRateScheduleOverrideActive: false,
        duration: s.durationMinutes * 60.0,
        continuationInterval: 11.0 * 60.0
    )

    if let rec = rec {
        emit(Fixture(isNil: false, unitsPerHour: rec.unitsPerHour, durationMinutes: rec.duration / 60.0))
    } else {
        emit(Fixture(isNil: true, unitsPerHour: nil, durationMinutes: nil))
    }
}

// MARK: - kind: dynamic_carb_effect

/// The PRODUCTION carb-absorption path, exactly as Loop runs it every cycle:
///   [CarbEntry].map(to: ICE, …)  → [CarbStatus]   (CarbStatusBuilder allocation)
///   statuses.dynamicGlucoseEffects(from:to:…)     (observed + modeled projection)
///   statuses.dynamicCarbsOnBoard(from:to:…)
/// ICE = insulin counteraction effects, a timeline of glucose-change velocities
/// (observed Δglucose − modeled insulin effect). All APIs are public in v3.14.2.
/// The static CarbMath.glucoseEffects path is internal AND non-production — skipped.
func runDynamicCarbEffect(_ data: Data) {
    struct CarbEntryIn: Decodable {
        let start: String
        let grams: Double
        let absorptionTimeMinutes: Double?   // nil ⇒ defaultAbsorptionTime
    }
    struct IceIn: Decodable {
        let start: String
        let end: String
        let velocity_mgdL_per_min: Double
    }
    struct Scenario: Decodable {
        let carbEntries: [CarbEntryIn]
        let ice: [IceIn]
        let carbRatio_gPerU: Double
        let insulinSensitivity_mgdLperU: Double
        let absorptionTimeOverrun: Double          // production: 1.5
        let initialAbsorptionTimeOverrun: Double   // production: 1.5
        let defaultAbsorptionTimeMinutes: Double   // production: 180
        let delayMinutes: Double                   // production: 10
        let deltaMinutes: Double                   // production: 5
        let effectFrom: String                     // `from` for both timelines
        let effectToHoursAfter: Double             // `to` = from + this
    }
    struct EffectOut: Encodable { let date: String; let value_mgdL: Double }
    struct CobOut: Encodable { let date: String; let grams: Double }
    struct AbsorptionOut: Encodable {
        let entryStart: String
        let entryGrams: Double
        let observedGrams: Double
        let clampedGrams: Double
        let totalGrams: Double
        let remainingGrams: Double
        let observedDateStart: String
        let observedDateEnd: String
        let estimatedTimeRemainingMinutes: Double
        let timeToAbsorbObservedCarbsMinutes: Double
        let observedTimelineCount: Int   // -1 if observedTimeline is nil
    }
    struct Fixture: Encodable {
        let glucoseEffects: [EffectOut]   // cumulative mg/dL (absolute, like Swift)
        let carbsOnBoard: [CobOut]        // grams remaining at each grid point
        let absorption: [AbsorptionOut]   // per-entry builder result (divergence localization)
    }

    guard let s = try? JSONDecoder().decode(Scenario.self, from: data) else {
        fail("cannot decode dynamic_carb_effect scenario")
    }

    let gram = HKUnit.gram()
    let velocityUnit = mgdLUnit.unitDivided(by: .minute())

    let entries: [NewCarbEntry] = s.carbEntries.map { e in
        guard let d = isoUTC.date(from: e.start) else { fail("cannot parse carb entry start: \(e.start)") }
        // `date:` defaults to Date() — pass explicitly to stay deterministic.
        return NewCarbEntry(
            date: d,
            quantity: HKQuantity(unit: gram, doubleValue: e.grams),
            startDate: d,
            foodType: nil,
            absorptionTime: e.absorptionTimeMinutes.map { $0 * 60.0 }
        )
    }

    let ice: [GlucoseEffectVelocity] = s.ice.map { v in
        guard let sd = isoUTC.date(from: v.start), let ed = isoUTC.date(from: v.end) else {
            fail("cannot parse ICE interval dates: \(v.start) / \(v.end)")
        }
        return GlucoseEffectVelocity(
            startDate: sd, endDate: ed,
            quantity: HKQuantity(unit: velocityUnit, doubleValue: v.velocity_mgdL_per_min)
        )
    }

    // Flat schedules covering all entry dates (closestPrior just needs start ≤ date).
    let carbRatios = [AbsoluteScheduleValue(startDate: .distantPast, endDate: .distantFuture, value: s.carbRatio_gPerU)]
    let sensitivities = [AbsoluteScheduleValue(
        startDate: .distantPast, endDate: .distantFuture,
        value: HKQuantity(unit: mgdLUnit, doubleValue: s.insulinSensitivity_mgdLperU)
    )]

    let defaultAbsorption = s.defaultAbsorptionTimeMinutes * 60.0
    let delay = s.delayMinutes * 60.0
    let delta = s.deltaMinutes * 60.0
    let model = PiecewiseLinearAbsorption()   // production absorption model

    let statuses = entries.map(
        to: ice,
        carbRatio: carbRatios,
        insulinSensitivity: sensitivities,
        absorptionTimeOverrun: s.absorptionTimeOverrun,
        defaultAbsorptionTime: defaultAbsorption,
        delay: delay,
        initialAbsorptionTimeOverrun: s.initialAbsorptionTimeOverrun,
        absorptionModel: model,
        adaptiveAbsorptionRateEnabled: false,
        adaptiveRateStandbyIntervalFraction: 0.2
    )

    guard let from = isoUTC.date(from: s.effectFrom) else { fail("cannot parse effectFrom: \(s.effectFrom)") }
    let to = from.addingTimeInterval(s.effectToHoursAfter * 3600.0)

    let effects = statuses.dynamicGlucoseEffects(
        from: from, to: to,
        carbRatios: carbRatios,
        insulinSensitivities: sensitivities,
        defaultAbsorptionTime: defaultAbsorption,
        absorptionModel: model,
        delay: delay,
        delta: delta
    )

    let cob = statuses.dynamicCarbsOnBoard(
        from: from, to: to,
        defaultAbsorptionTime: defaultAbsorption,
        absorptionModel: model,
        delay: delay,
        delta: delta
    )

    let absorption: [AbsorptionOut] = statuses.map { st in
        guard let a = st.absorption else {
            fail("CarbStatus has no absorption for entry at \(isoUTC.string(from: st.entry.startDate)) — ICE must overlap entries")
        }
        return AbsorptionOut(
            entryStart: isoUTC.string(from: st.entry.startDate),
            entryGrams: st.entry.quantity.doubleValue(for: gram),
            observedGrams: a.observed.doubleValue(for: gram),
            clampedGrams: a.clamped.doubleValue(for: gram),
            totalGrams: a.total.doubleValue(for: gram),
            remainingGrams: a.remaining.doubleValue(for: gram),
            observedDateStart: isoUTC.string(from: a.observedDate.start),
            observedDateEnd: isoUTC.string(from: a.observedDate.end),
            estimatedTimeRemainingMinutes: a.estimatedTimeRemaining / 60.0,
            timeToAbsorbObservedCarbsMinutes: a.timeToAbsorbObservedCarbs / 60.0,
            observedTimelineCount: st.observedTimeline?.count ?? -1
        )
    }

    emit(Fixture(
        glucoseEffects: effects.map {
            EffectOut(date: isoUTC.string(from: $0.startDate), value_mgdL: $0.quantity.doubleValue(for: mgdLUnit))
        },
        carbsOnBoard: cob.map {
            CobOut(date: isoUTC.string(from: $0.startDate), grams: $0.value)
        },
        absorption: absorption
    ))
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
case "dynamic_carb_effect":   runDynamicCarbEffect(data)
case "temp_basal_recommendation": runTempBasalRecommendation(data)
default:                      fail("unknown scenario kind: \(kind)")
}
