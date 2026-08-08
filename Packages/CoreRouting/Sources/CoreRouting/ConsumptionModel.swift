import CoreDomain
import Foundation

// MARK: - CalibrationFactors

/// Multiplicative scale factors fitted online against logged trip data.
/// Clamped to ±30% of seed values (spec §4.3).
public struct CalibrationFactors: Sendable {
    public var crrScale: Double
    public var cdaScale: Double
    public var auxScale: Double
    public var fittedSampleKm: Double

    public static let minCalibrationKm: Double = 200.0

    public var isApplicable: Bool { fittedSampleKm >= Self.minCalibrationKm }

    public init(
        crrScale: Double = 1.0,
        cdaScale: Double = 1.0,
        auxScale: Double = 1.0,
        fittedSampleKm: Double = 0.0
    ) {
        self.crrScale = crrScale
        self.cdaScale = cdaScale
        self.auxScale = auxScale
        self.fittedSampleKm = fittedSampleKm
    }

    public static func clamp(_ v: Double) -> Double {
        min(max(v, 0.7), 1.3)
    }

    /// Loads persisted calibration from the preferences snapshot. An unset or
    /// immature snapshot (below `minCalibrationKm`) degrades to neutral scales
    /// inside `ConsumptionModel`, so it is safe to apply unconditionally.
    public init(snapshot: CalibrationSnapshot) {
        self.init(
            crrScale: Double(snapshot.crrScale),
            cdaScale: Double(snapshot.cdaScale),
            auxScale: Double(snapshot.auxScale),
            fittedSampleKm: Double(snapshot.fittedSampleKm)
        )
    }

    /// The persisted form of the current factors.
    public var snapshot: CalibrationSnapshot {
        CalibrationSnapshot(
            crrScale: Float(crrScale),
            cdaScale: Float(cdaScale),
            auxScale: Float(auxScale),
            fittedSampleKm: Float(fittedSampleKm)
        )
    }
}

// MARK: - ConsumptionModel

/// Physics-based consumption model (spec §4.1):
///   P_wheel = (Crr·m·g + ½·ρ·Cd·A·v² + m·g·sinθ + m·a) · v
///   P_batt  = P_wheel / η_drive + P_aux + P_hvac(T_ambient)
public final class ConsumptionModel: Sendable {
    private let payloadMassKg: Double
    private let calibration: CalibrationFactors

    private var massKg: Double { Ioniq5RoutingConstants.massKg + payloadMassKg }

    private var crr: Double {
        Ioniq5RoutingConstants.crr * (calibration.isApplicable ? calibration.crrScale : 1.0)
    }

    private var cda: Double {
        Ioniq5RoutingConstants.cd * Ioniq5RoutingConstants.frontalAreaM2
            * (calibration.isApplicable ? calibration.cdaScale : 1.0)
    }

    private var auxW: Double {
        Ioniq5RoutingConstants.auxPowerW * (calibration.isApplicable ? calibration.auxScale : 1.0)
    }

    public init(payloadMassKg: Double = 100.0, calibration: CalibrationFactors = CalibrationFactors()) {
        self.payloadMassKg = payloadMassKg
        self.calibration = calibration
    }

    /// Battery power draw in watts at steady state.
    public func batteryPowerW(
        speedMps: Double,
        gradeRadians: Double = 0.0,
        accelerationMps2: Double = 0.0,
        ambientC: Float = 20
    ) -> Double {
        let g = Ioniq5RoutingConstants.gravity
        let rolling = crr * massKg * g
        let aero = 0.5 * Ioniq5RoutingConstants.airDensity * cda * speedMps * speedMps
        let grade = massKg * g * sin(gradeRadians)
        let inertia = massKg * accelerationMps2
        let pWheel = (rolling + aero + grade + inertia) * speedMps

        // Regen recovers downhill/braking energy at drive efficiency; traction
        // pays the inverse. Either way HVAC and aux are drawn from the pack.
        let pDrive: Double
        if pWheel >= 0 {
            pDrive = pWheel / Ioniq5RoutingConstants.driveEfficiency
        } else {
            pDrive = pWheel * Ioniq5RoutingConstants.driveEfficiency
        }
        return pDrive + auxW + hvacPowerW(ambientC: ambientC)
    }

    /// Energy in kWh for a segment driven at constant speed.
    public func segmentEnergyKwh(
        distanceKm: Double,
        speedKph: Double,
        elevationGainM: Double = 0.0,
        ambientC: Float = 20
    ) -> Double {
        if distanceKm <= 0.0 || speedKph <= 0.0 { return 0.0 }
        let speedMps = speedKph / 3.6
        let gradeRad = atan(elevationGainM / (distanceKm * 1000.0))
        let powerW = batteryPowerW(
            speedMps: speedMps, gradeRadians: gradeRad,
            accelerationMps2: 0.0, ambientC: ambientC
        )
        let hours = distanceKm / speedKph
        // A long descent can regen, but never returns more than a small credit.
        let energy = powerW / 1000.0 * hours
        return max(energy, -abs(elevationGainM) * massKg * 2.0e-6)
    }
}

// MARK: - CalibrationUpdater

/// Recursive-least-squares style updater for the calibration factors. Each
/// logged segment compares predicted vs actual energy and nudges the scales.
public final class CalibrationUpdater: @unchecked Sendable {
    private var factors: CalibrationFactors

    public var current: CalibrationFactors { factors }

    public init(factors: CalibrationFactors = CalibrationFactors()) {
        self.factors = factors
    }

    @discardableResult
    public func update(
        distanceKm: Double,
        speedKph: Double,
        elevationGainM: Double,
        ambientC: Float,
        actualEnergyKwh: Double
    ) -> CalibrationFactors {
        if distanceKm < 1.0 || speedKph < 5.0 { return factors }
        // Zero/near-zero measured energy (a bad trip log, or a regen-only segment)
        // must not calibrate: it would drive the ratio to the 0.3 floor and ratchet
        // the scales down on every trip. Reject it outright.
        if actualEnergyKwh <= 0.05 { return factors }
        let seedModel = ConsumptionModel(
            calibration: CalibrationFactors(fittedSampleKm: 0.0)
        )
        let predicted = seedModel.segmentEnergyKwh(
            distanceKm: distanceKm, speedKph: speedKph,
            elevationGainM: elevationGainM, ambientC: ambientC
        )
        if predicted <= 0.05 { return factors }

        let ratio = min(max(actualEnergyKwh / predicted, 0.3), 3.0)
        // Aero dominates at speed, rolling at low speed — attribute the error accordingly.
        let aeroWeight = min(max((speedKph - 40.0) / 80.0, 0.1), 0.9)
        let gain = min(distanceKm / 50.0, 0.1)   // slow, stable convergence

        factors = CalibrationFactors(
            crrScale: CalibrationFactors.clamp(
                factors.crrScale + gain * (1 - aeroWeight) * (ratio - 1.0)
            ),
            cdaScale: CalibrationFactors.clamp(
                factors.cdaScale + gain * aeroWeight * (ratio - 1.0)
            ),
            auxScale: factors.auxScale,
            fittedSampleKm: factors.fittedSampleKm + distanceKm
        )
        return factors
    }
}
