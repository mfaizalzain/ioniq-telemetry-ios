import CoreDomain
import Foundation

// MARK: - RemainingLeg

/// One un-driven leg of the trip, as the arrival estimator sees it.
public struct RemainingLeg: Sendable {
    public let distanceKm: Float
    public let elevationGainM: Float
    public let speedKph: Float

    public init(distanceKm: Float, elevationGainM: Float, speedKph: Float) {
        self.distanceKm = distanceKm
        self.elevationGainM = elevationGainM
        self.speedKph = speedKph
    }
}

// MARK: - LegEstimate

public struct LegEstimate: Sendable {
    public let distanceKm: Float
    public let elevationGainM: Float
    public let kwhUsed: Float

    public init(distanceKm: Float, elevationGainM: Float, kwhUsed: Float) {
        self.distanceKm = distanceKm
        self.elevationGainM = elevationGainM
        self.kwhUsed = kwhUsed
    }
}

// MARK: - ArrivalEstimate

public struct ArrivalEstimate: Sendable {
    /// Predicted SOC on arrival, from the live estimate.
    public let predictedArrivalSocPercent: Float
    /// The behavior figure the estimate was scaled to (kWh/100 km).
    public let kwhPer100KmUsed: Float
    /// Per-leg energy breakdown, in route order.
    public let legs: [LegEstimate]

    public init(
        predictedArrivalSocPercent: Float,
        kwhPer100KmUsed: Float,
        legs: [LegEstimate]
    ) {
        self.predictedArrivalSocPercent = predictedArrivalSocPercent
        self.kwhPer100KmUsed = kwhPer100KmUsed
        self.legs = legs
    }
}

// MARK: - LiveArrivalEstimator

/// Predicts arrival SOC over the remaining route, combining two signals:
///
/// 1. **The road** — the physics model (`ConsumptionModel`) burns energy per
///    leg at that leg's speed, ambient temperature and elevation gain, so a
///    climb costs more than the flat average and a cold day costs more HVAC.
/// 2. **The driver** — the model is rescaled by how this driver actually
///    consumes versus the physics on flat ground: live OBD measurement when
///    there is one, otherwise learned history, otherwise the nominal baseline.
///    A driver who cruises at 19 kWh/100 km where the model says 16 gets a
///    1.19× factor applied to every remaining leg, elevation included.
///
/// This is the ABRP approach: model the road, calibrate to the driver.
public final class LiveArrivalEstimator: Sendable {

    /// How far the behavior figure may rescale the model before it is a bad
    /// frame rather than a signal. 0.5×–2.0× covers everything from hypermiling
    /// to a headwind on snow tyres, while keeping a junk reading from
    /// manufacturing a fake arrival.
    public static let scaleRange: ClosedRange<Double> = 0.5...2.0

    private let consumption: ConsumptionModel

    public init(consumption: ConsumptionModel = ConsumptionModel()) {
        self.consumption = consumption
    }

    /// - Parameters:
    ///   - liveKwhPer100Km: measured this drive (OBD power/speed). Wins when
    ///     present — it already contains this weather, this road and this mood.
    ///   - learnedKwhPer100Km: the driver's own history when no live figure.
    ///   - baselineKwhPer100Km: nominal fallback, HVAC-adjusted by the caller.
    public func estimate(
        currentSocPercent: Float,
        usableKwh: Double,
        remainingLegs: [RemainingLeg],
        ambientC: Float,
        liveKwhPer100Km: Float?,
        learnedKwhPer100Km: Float?,
        baselineKwhPer100Km: Float
    ) -> ArrivalEstimate? {
        guard usableKwh > 0, !remainingLegs.isEmpty else { return nil }

        let behavior = liveKwhPer100Km ?? learnedKwhPer100Km ?? baselineKwhPer100Km
        guard behavior > 0 else { return nil }

        var totalKwh: Double = 0
        var legs: [LegEstimate] = []

        for leg in remainingLegs {
            // Energy for this leg with its grade and this ambient — elevation is
            // applied per leg, not as one route-wide average.
            let modelEnergy = consumption.segmentEnergyKwh(
                distanceKm: Double(leg.distanceKm),
                speedKph: Double(leg.speedKph),
                elevationGainM: Double(leg.elevationGainM),
                ambientC: ambientC
            )
            // Flat reference at the same speed: how much the physics model says
            // this leg costs with no grade. The behavior scale is the ratio of
            // what the driver really uses to that flat figure.
            let modelFlat = consumption.segmentEnergyKwh(
                distanceKm: 100.0,
                speedKph: Double(leg.speedKph),
                elevationGainM: 0,
                ambientC: ambientC
            )
            let scale = modelFlat > 0.1
                ? min(max(Double(behavior) / modelFlat, Self.scaleRange.lowerBound), Self.scaleRange.upperBound)
                : 1.0
            let kwh = modelEnergy * scale
            totalKwh += kwh
            legs.append(LegEstimate(
                distanceKm: leg.distanceKm,
                elevationGainM: leg.elevationGainM,
                kwhUsed: Float(kwh)
            ))
        }

        let consumedSoc = Float(totalKwh / usableKwh * 100.0)
        return ArrivalEstimate(
            predictedArrivalSocPercent: max(currentSocPercent - consumedSoc, 0),
            kwhPer100KmUsed: behavior,
            legs: legs
        )
    }
}
