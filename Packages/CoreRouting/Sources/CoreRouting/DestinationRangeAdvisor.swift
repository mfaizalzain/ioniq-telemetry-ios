import CoreDomain
import Foundation

// MARK: - RouteChargerCandidate

/// A charger the range advisor may suggest, with its drive distance from the
/// driver's current position (road distance, detour already applied).
public struct RouteChargerCandidate: Sendable {
    public let charger: Charger
    public let driveKm: Double

    public init(charger: Charger, driveKm: Double) {
        self.charger = charger
        self.driveKm = driveKm
    }
}

// MARK: - SuggestedStop

/// A charging stop that extends range toward a destination.
public struct SuggestedStop: Sendable {
    public let charger: Charger
    /// Predicted SOC on arrival at the charger.
    public let arriveSocPercent: Float
    /// SOC after charging.
    public let departSocPercent: Float
    public let chargeMinutes: Int
    /// Predicted SOC at the destination after this stop.
    public let arriveDestinationSocPercent: Float
    /// True when the destination is actually reachable after this stop.
    public let reachesDestination: Bool

    public init(
        charger: Charger,
        arriveSocPercent: Float,
        departSocPercent: Float,
        chargeMinutes: Int,
        arriveDestinationSocPercent: Float,
        reachesDestination: Bool
    ) {
        self.charger = charger
        self.arriveSocPercent = arriveSocPercent
        self.departSocPercent = departSocPercent
        self.chargeMinutes = chargeMinutes
        self.arriveDestinationSocPercent = arriveDestinationSocPercent
        self.reachesDestination = reachesDestination
    }
}

// MARK: - RangeAdvice

public struct RangeAdvice: Sendable {
    /// Predicted SOC on arrival at the destination with no stop.
    public let predictedArrivalSocPercent: Float
    /// True when the destination is reachable on the current charge with no
    /// stop at all. When false, `suggestedStop` may still rescue the trip.
    public let canReachDirectly: Bool
    /// Best charging stop to extend range, when any candidate is usable. May
    /// still fall short (`suggestedStop.reachesDestination == false`).
    public let suggestedStop: SuggestedStop?
    public let reserveSocPercent: Float

    public init(
        predictedArrivalSocPercent: Float,
        canReachDirectly: Bool,
        suggestedStop: SuggestedStop?,
        reserveSocPercent: Float
    ) {
        self.predictedArrivalSocPercent = predictedArrivalSocPercent
        self.canReachDirectly = canReachDirectly
        self.suggestedStop = suggestedStop
        self.reserveSocPercent = reserveSocPercent
    }
}

// MARK: - DestinationRangeAdvisor

/// Decides whether a destination is reachable on the current charge, and when it
/// is not, which nearby charger best extends the range to get there.
///
/// The math is the same as the trip solver's: SOC consumed = distance ×
/// consumption / usable capacity. Charge time comes from the real Ioniq 5 curve
/// (`ChargeCurve`), so a suggestion's duration is a model's answer, not a guess.
public final class DestinationRangeAdvisor: Sendable {

    public init() {}

    public func advise(
        currentSocPercent: Float,
        usableKwh: Double,
        consumptionKwhPer100Km: Double,
        distanceToDestinationKm: Double,
        reserveSocPercent: Float,
        chargeTargetSocPercent: Float = 80,
        packTempC: Float = 25,
        availableChargerIds: Set<String> = [],
        /// Override for the direct-arrival prediction. Callers with elevation
        /// or live-behavior data pass the elevation-aware figure here; the
        /// candidate ranking below still uses the flat linear model, since
        /// chargers carry no grade data.
        predictedArrivalSocPercent: Float? = nil,
        chargers: [RouteChargerCandidate]
    ) -> RangeAdvice {
        // Degenerate inputs say nothing about range — report the current SOC and
        // let the caller stay quiet rather than invent an alert.
        guard usableKwh > 0,
              consumptionKwhPer100Km > 0,
              distanceToDestinationKm > 0 else {
            return RangeAdvice(
                predictedArrivalSocPercent: currentSocPercent,
                canReachDirectly: true,
                suggestedStop: nil,
                reserveSocPercent: reserveSocPercent
            )
        }

        let socPerKm = Float(consumptionKwhPer100Km / 100.0 / usableKwh * 100.0)
        let predicted = predictedArrivalSocPercent
            ?? (currentSocPercent - socPerKm * Float(distanceToDestinationKm))

        // Direct drive is fine — no need to disturb the driver.
        if predicted >= reserveSocPercent {
            return RangeAdvice(
                predictedArrivalSocPercent: predicted,
                canReachDirectly: true,
                suggestedStop: nil,
                reserveSocPercent: reserveSocPercent
            )
        }

        let candidates: [SuggestedStop] = chargers.compactMap { candidate in
            let charger = candidate.charger
            // A charger past the destination is useless — it can't get you there.
            guard candidate.driveKm < distanceToDestinationKm else { return nil }

            let arrive = currentSocPercent - socPerKm * Float(candidate.driveKm)
            // Physically unreachable on this charge — excluded outright.
            guard arrive > 0 else { return nil }

            // Departure SOC needed to finish with reserve: reserve + the energy
            // the remaining leg will burn.
            let remainingKm = distanceToDestinationKm - candidate.driveKm
            let needed = reserveSocPercent + socPerKm * Float(remainingKm)
            // Charge enough to make it, but never less than a +10 point top-up
            // (a stop must buy a meaningful buffer) and never past the target.
            let depart = min(chargeTargetSocPercent, max(arrive + 10, needed))
            guard depart > arrive else { return nil }

            let curve = ChargeCurve(stationLimitKw: charger.maxPowerKw)
            let minutes = curve.chargeMinutes(
                fromSocPercent: arrive,
                toSocPercent: depart,
                usableKwh: usableKwh,
                packTempC: packTempC
            )
            let destArrival = depart - socPerKm * Float(remainingKm)

            return SuggestedStop(
                charger: charger,
                arriveSocPercent: arrive,
                departSocPercent: depart,
                chargeMinutes: minutes,
                arriveDestinationSocPercent: destArrival,
                reachesDestination: destArrival >= reserveSocPercent
            )
        }

        guard let best = candidates.min(by: {
            score($0, availableChargerIds: availableChargerIds)
                < score($1, availableChargerIds: availableChargerIds)
        }) else {
            // Nothing usable nearby — the driver still needs to know they won't
            // make it, but there is no stop to offer.
            return RangeAdvice(
                predictedArrivalSocPercent: predicted,
                canReachDirectly: false,
                suggestedStop: nil,
                reserveSocPercent: reserveSocPercent
            )
        }

        return RangeAdvice(
            predictedArrivalSocPercent: predicted,
            canReachDirectly: false,
            suggestedStop: best,
            reserveSocPercent: reserveSocPercent
        )
    }

    /// Ordering: stops that actually reach the destination first, then chargers
    /// with live availability, then shorter charge time, then arrival margin.
    private func score(_ stop: SuggestedStop, availableChargerIds: Set<String>) -> Score {
        Score(
            reaches: stop.reachesDestination ? 0 : 1,
            available: availableChargerIds.contains(stop.charger.id) ? 0 : 1,
            minutes: stop.chargeMinutes,
            destArrival: -stop.arriveDestinationSocPercent
        )
    }

    private struct Score: Comparable {
        let reaches: Int
        let available: Int
        let minutes: Int
        let destArrival: Float

        static func < (lhs: Score, rhs: Score) -> Bool {
            if lhs.reaches != rhs.reaches { return lhs.reaches < rhs.reaches }
            if lhs.available != rhs.available { return lhs.available < rhs.available }
            if lhs.minutes != rhs.minutes { return lhs.minutes < rhs.minutes }
            return lhs.destArrival < rhs.destArrival
        }
    }
}
