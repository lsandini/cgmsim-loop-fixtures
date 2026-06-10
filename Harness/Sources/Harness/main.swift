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
//   "automatic_dose_recommendation" — recommendedAutomaticDose (DoseMath): the
//                             SMB-style auto path — partial bolus + (low-only) temp.
//   "predict_glucose"       — LoopMath.predictGlucose: compose momentum + N effect
//                             timelines into the predicted glucose curve.
//   "loop_prediction"       — THE CAPSTONE: LoopAlgorithm.generatePrediction runs the
//                             full pipeline (dose annotation incl. temp basals → insulin,
//                             ICE, dynamic carbs, RC, momentum → predictGlucose) from a
//                             realistic glucose/dose/carb history. Emits the predicted
//                             curve + all 5 effect arrays for component-level comparison.

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

/// Faithful port of LoopKit `InsulinMath.reconciled()` (bolus + tempBasal path).
/// `reconciled()` is `internal` so it can't be called from this module; real Loop
/// runs it in DoseStore BEFORE the algorithm, truncating each temp basal to end at
/// the next temp's start (the actual delivered insulin). CGMSIM has no suspend/
/// resume events, so only the temp/bolus branches matter. Boluses pass through.
func reconcileTempBasals(_ doses: [DoseEntry]) -> [DoseEntry] {
    let temps = doses.filter { $0.type == .tempBasal }.sorted { $0.startDate < $1.startDate }
    guard temps.count > 1 else { return doses }
    let others = doses.filter { $0.type != .tempBasal }

    var reconciled: [DoseEntry] = []
    for (i, cur) in temps.enumerated() {
        // Swift reconciled(): trim `last` to min(last.endDate, nextDose.startDate).
        let end = (i + 1 < temps.count) ? min(cur.endDate, temps[i + 1].startDate) : cur.endDate
        if end > cur.startDate {   // drop 0-duration after truncation (Swift's guard)
            reconciled.append(DoseEntry(
                type: .tempBasal, startDate: cur.startDate, endDate: end,
                value: cur.value, unit: cur.unit, insulinType: cur.insulinType))
        }
    }
    return others + reconciled
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

// MARK: - kind: loop_prediction  (THE CAPSTONE)

/// `LoopAlgorithm.generatePrediction` — the whole forecast pipeline in one call:
///   doses.annotated(with: basal)  → net insulin (the temp-basal/basal overlay = §T1)
///     → insulin glucose effects
///     → counteraction effects (ICE) from glucose vs insulin
///     → dynamic carb effects (map(to: ICE) → dynamicGlucoseEffects)
///     → retrospective correction (standard or integral)
///     → momentum (linearMomentumEffect)
///     → LoopMath.predictGlucose(...) → prediction (extended to insulin duration)
/// Emits the predicted glucose curve PLUS each component effect array, so a JS
/// divergence localizes to a single stage (insulin / carb / RC / momentum / ICE)
/// rather than just "the curve is off". Built directly from a simple scenario
/// (NOT by decoding LoopPredictionInput — that Codable path has a target-bound bug).
func runLoopPrediction(_ data: Data) {
    struct GlucosePoint: Decodable { let date: String; let value: Double }
    struct DoseIn: Decodable {
        let type: String          // "bolus" | "tempBasal"
        let start: String
        let end: String?
        let value: Double         // bolus: units; tempBasal: U/hr
    }
    struct CarbIn: Decodable {
        let start: String
        let grams: Double
        let absorptionMinutes: Double?
    }
    struct Scenario: Decodable {
        let now: String                       // prediction anchor (= last glucose date, aligned)
        let glucose: [GlucosePoint]
        let doses: [DoseIn]
        let carbEntries: [CarbIn]
        let basalRate_UperHr: Double
        let insulinSensitivity_mgdLperU: Double
        let carbRatio_gPerU: Double
        let targetLow_mgdL: Double
        let targetHigh_mgdL: Double
        let insulinModel: String?             // default rapid-acting adult
        let useIntegralRC: Bool?
    }
    struct EffectOut: Encodable { let date: String; let value: Double }
    struct IceOut: Encodable { let start: String; let end: String; let velocity_mgdL_per_min: Double }
    struct EffectsOut: Encodable {
        let insulin: [EffectOut]
        let carbs: [EffectOut]
        let retrospectiveCorrection: [EffectOut]
        let momentum: [EffectOut]
        let insulinCounteraction: [IceOut]
    }
    struct Fixture: Encodable {
        let predictedGlucose: [EffectOut]
        let effects: EffectsOut
    }

    guard let s = try? JSONDecoder().decode(Scenario.self, from: data) else {
        fail("cannot decode loop_prediction scenario")
    }
    guard let anchor = isoUTC.date(from: s.now) else { fail("cannot parse now: \(s.now)") }

    // Glucose history → StoredGlucoseSample.
    let glucoseHistory: [StoredGlucoseSample] = s.glucose.map { pt in
        guard let d = isoUTC.date(from: pt.date) else { fail("cannot parse glucose date: \(pt.date)") }
        return StoredGlucoseSample(startDate: d, quantity: HKQuantity(unit: mgdLUnit, doubleValue: pt.value))
    }

    // Doses → DoseEntry (bolus in units; tempBasal in U/hr). No scheduledBasalRate
    // set — generatePrediction's annotated(with: basal) overlays it.
    let insType = insulinType(named: s.insulinModel ?? "novolog")
    let doses: [DoseEntry] = s.doses.map { d in
        guard let start = isoUTC.date(from: d.start) else { fail("cannot parse dose start: \(d.start)") }
        let end = d.end.flatMap { isoUTC.date(from: $0) }
        switch d.type.lowercased() {
        case "bolus":
            return DoseEntry(type: .bolus, startDate: start, endDate: end ?? start,
                             value: d.value, unit: .units, insulinType: insType)
        case "tempbasal":
            guard let e = end else { fail("tempBasal dose needs an end date") }
            return DoseEntry(type: .tempBasal, startDate: start, endDate: e,
                             value: d.value, unit: .unitsPerHour, insulinType: insType)
        default:
            fail("unknown dose type: \(d.type)")
        }
    }

    // Reconcile overlapping temp basals (truncate each at the next temp's start),
    // matching what real Loop does in DoseStore.reconciled() BEFORE the algorithm
    // runs. LoopKit's `reconciled()` is `internal`, so it can't be called from this
    // module; this is a faithful port of its bolus + tempBasal path (CGMSIM has no
    // suspend/resume events). Without this, generatePrediction would see the raw
    // overlapping temps — which real Loop never feeds it. The JS port reconciles
    // identically in calculateInsulinEffect (§T1).
    let reconciledDoses = reconcileTempBasals(doses)

    // Carb entries → StoredCarbEntry.
    let gram = HKUnit.gram()
    let carbEntries: [StoredCarbEntry] = s.carbEntries.map { c in
        guard let d = isoUTC.date(from: c.start) else { fail("cannot parse carb start: \(c.start)") }
        return StoredCarbEntry(startDate: d, quantity: HKQuantity(unit: gram, doubleValue: c.grams),
                               absorptionTime: c.absorptionMinutes.map { $0 * 60.0 })
    }

    // Flat all-day schedules (distantPast→distantFuture so closestPrior/value(at:)
    // and the dose-annotation basal precondition are satisfied for any date).
    let basal = [AbsoluteScheduleValue(startDate: .distantPast, endDate: .distantFuture, value: s.basalRate_UperHr)]
    let sensitivity = [AbsoluteScheduleValue(startDate: .distantPast, endDate: .distantFuture,
                                             value: HKQuantity(unit: mgdLUnit, doubleValue: s.insulinSensitivity_mgdLperU))]
    let carbRatio = [AbsoluteScheduleValue(startDate: .distantPast, endDate: .distantFuture, value: s.carbRatio_gPerU)]
    let lo = HKQuantity(unit: mgdLUnit, doubleValue: s.targetLow_mgdL)
    let hi = HKQuantity(unit: mgdLUnit, doubleValue: s.targetHigh_mgdL)
    let target = [AbsoluteScheduleValue(startDate: .distantPast, endDate: .distantFuture,
                                        value: ClosedRange(uncheckedBounds: (lower: lo, upper: hi)))]

    let settings = LoopAlgorithmSettings(
        basal: basal,
        sensitivity: sensitivity,
        carbRatio: carbRatio,
        target: target,
        algorithmEffectsOptions: .all,
        useIntegralRetrospectiveCorrection: s.useIntegralRC ?? false
    )

    let input = LoopPredictionInput(
        glucoseHistory: glucoseHistory,
        doses: reconciledDoses,
        carbEntries: carbEntries,
        settings: settings
    )

    let mgdLPerMin = mgdLUnit.unitDivided(by: .minute())
    do {
        let p = try LoopAlgorithm.generatePrediction(input: input, startDate: anchor)
        let toEff: ([GlucoseEffect]) -> [EffectOut] = { arr in
            arr.map { EffectOut(date: isoUTC.string(from: $0.startDate), value: $0.quantity.doubleValue(for: mgdLUnit)) }
        }
        emit(Fixture(
            predictedGlucose: p.glucose.map { EffectOut(date: isoUTC.string(from: $0.startDate), value: $0.quantity.doubleValue(for: mgdLUnit)) },
            effects: EffectsOut(
                insulin: toEff(p.effects.insulin),
                carbs: toEff(p.effects.carbs),
                retrospectiveCorrection: toEff(p.effects.retrospectiveCorrection),
                momentum: toEff(p.effects.momentum),
                insulinCounteraction: p.effects.insulinCounteraction.map {
                    IceOut(start: isoUTC.string(from: $0.startDate), end: isoUTC.string(from: $0.endDate),
                           velocity_mgdL_per_min: $0.quantity.doubleValue(for: mgdLPerMin))
                }
            )
        ))
    } catch {
        fail("generatePrediction threw: \(error)")
    }
}

// MARK: - kind: predict_glucose

/// `LoopMath.predictGlucose` — composes a starting glucose, an optional momentum
/// timeline, and N effect timelines (insulin, carb, RC, …) into the predicted
/// glucose curve the recommenders consume. Each effect timeline contributes its
/// per-step *change* (differenced against its own first value); momentum is
/// linearly blended (overwrite-style) rather than summed. Validates the JS
/// `predictGlucoseFromEffects` (loop-predictions.js) — the composition step,
/// decoupled from how the individual effects are generated.
func runPredictGlucose(_ data: Data) {
    struct Point: Decodable { let date: String; let value: Double }
    struct Scenario: Decodable {
        let startingGlucose: Point
        let momentum: [Point]?       // optional; <2 points ⇒ no blend
        let effects: [[Point]]       // one or more cumulative effect timelines (mg/dL)
    }
    struct Out: Encodable { let date: String; let value: Double }

    guard let s = try? JSONDecoder().decode(Scenario.self, from: data) else {
        fail("cannot decode predict_glucose scenario")
    }

    func effectPoints(_ pts: [Point], _ label: String) -> [GlucoseEffect] {
        pts.map { p in
            guard let d = isoUTC.date(from: p.date) else { fail("cannot parse \(label) date: \(p.date)") }
            return GlucoseEffect(startDate: d, quantity: HKQuantity(unit: mgdLUnit, doubleValue: p.value))
        }
    }

    guard let startDate = isoUTC.date(from: s.startingGlucose.date) else {
        fail("cannot parse startingGlucose date: \(s.startingGlucose.date)")
    }
    let starting = SimpleGlucose(startDate: startDate,
                                 quantity: HKQuantity(unit: mgdLUnit, doubleValue: s.startingGlucose.value))
    let momentum = effectPoints(s.momentum ?? [], "momentum")
    let effects = s.effects.enumerated().map { effectPoints($1, "effects[\($0)]") }

    let prediction = LoopMath.predictGlucose(startingAt: starting, momentum: momentum, effects: effects)

    emit(prediction.map { Out(date: isoUTC.string(from: $0.startDate), value: $0.quantity.doubleValue(for: mgdLUnit)) })
}

// MARK: - kind: automatic_dose_recommendation

/// `recommendedAutomaticDose` — the SMB-style automatic path: a partial bolus for
/// high corrections plus a temp basal that, in auto mode, is capped at the
/// SCHEDULED basal rate (so it can only *reduce* basal for low glucose; high
/// corrections come out as the bolus). Returns nil if neither piece is needed.
///
/// PARITY NOTES — to match `loopkit.js` `recommendAutomaticDose` exactly:
///   • `partialApplicationFactor` — JS `computeApplicationFactor` returns the
///     constant `PARTIAL_APPLICATION_FACTOR` (0.4) under the 'constant' strategy;
///     pass that same scalar.
///   • `volumeRounder` (bolus) — JS `asPartialBolus` rounds both the partial dose
///     AND maxBolusUnits to `BOLUS_INCREMENT`; pass a matching rounder (Swift's
///     `asPartialBolus` applies `volumeRounder` to both, identically).
///   • `rateRounder` (temp) — JS `asTempBasal` rounds to 0.05 U/hr; pass a matching
///     rounder (Swift default is none).
///   • **NO IOB clamp here.** Swift's `recommendedAutomaticDose` (DoseMath) has no
///     `additionalActiveInsulinClamp` — the IOB cap that JS applies to
///     `maxAutomaticBolus` lives in the LoopDataManager layer JS fused in. The JS
///     test sets `currentIOB = 0` (headroom = maxBolus*2 ≥ maxAutomaticBolus) so
///     that JS-only cap is inert and the DoseMath-level math is what's compared.
/// `lastTempBasal` nil; duration 30 min; continuationInterval 11 min.
func runAutomaticDoseRecommendation(_ data: Data) {
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
        let maxAutomaticBolus: Double
        let partialApplicationFactor: Double
        let bolusIncrement_U: Double      // JS BOLUS_INCREMENT (volumeRounder)
        let rateIncrement_UperHr: Double  // JS temp rate rounding (0.05)
        let durationMinutes: Double       // JS TEMP_BASAL_DURATION (30)
    }
    struct TempOut: Encodable { let unitsPerHour: Double; let durationMinutes: Double }
    struct Fixture: Encodable {
        let isNil: Bool                   // recommendedAutomaticDose returned nil
        let basalAdjustment: TempOut?     // nil if no temp piece
        let bolusUnits: Double?
    }

    guard let s = try? JSONDecoder().decode(Scenario.self, from: data) else {
        fail("cannot decode automatic_dose_recommendation scenario")
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

    let bolusInc = s.bolusIncrement_U
    let rateInc = s.rateIncrement_UperHr
    let volumeRounder: (Double) -> Double = { ($0 / bolusInc).rounded() * bolusInc }
    let rateRounder: (Double) -> Double = { ($0 / rateInc).rounded() * rateInc }

    let rec = glucose.recommendedAutomaticDose(
        to: target,
        at: first.startDate,
        suspendThreshold: suspend,
        sensitivity: sensitivity,
        model: model,
        basalRates: basalRates,
        maxAutomaticBolus: s.maxAutomaticBolus,
        partialApplicationFactor: s.partialApplicationFactor,
        lastTempBasal: nil,
        volumeRounder: volumeRounder,
        rateRounder: rateRounder,
        isBasalRateScheduleOverrideActive: false,
        duration: s.durationMinutes * 60.0,
        continuationInterval: 11.0 * 60.0
    )

    if let rec = rec {
        let temp = rec.basalAdjustment.map { TempOut(unitsPerHour: $0.unitsPerHour, durationMinutes: $0.duration / 60.0) }
        emit(Fixture(isNil: false, basalAdjustment: temp, bolusUnits: rec.bolusUnits))
    } else {
        emit(Fixture(isNil: true, basalAdjustment: nil, bolusUnits: nil))
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
case "automatic_dose_recommendation": runAutomaticDoseRecommendation(data)
case "predict_glucose":       runPredictGlucose(data)
case "loop_prediction":       runLoopPrediction(data)
default:                      fail("unknown scenario kind: \(kind)")
}
