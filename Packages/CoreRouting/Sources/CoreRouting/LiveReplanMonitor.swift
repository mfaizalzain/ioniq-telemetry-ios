import CoreDomain
import Foundation

/// Live progress watch for an active trip plan.
///
/// Preferred mode uses the GPS fix: the position is matched onto the routed
/// polyline for distance-along-route and off-route distance, and the plan's own leg
/// SOC profile gives the predicted SOC at that point. Actual vs predicted SOC and
/// the off-route distance feed the shared `Replanner`.
///
/// With no fix or route geometry it falls back to dead reckoning (integrating
/// speed), which can flag consumption drift but never off-route.
///
/// Not thread-safe — drive it from one consumer.
///
/// Ported from Android LiveReplanMonitor.kt.
public final class LiveReplanMonitor {

    private let replanner: Replanner
    private let minDistanceKm: Double
    private let useMiles: Bool

    private var planGeneratedAt: Date?
    private var startSoc: Float = 0
    private var socPerKm: Float = 0          // dead-reckoning fallback rate
    private var deadReckonedKm: Double = 0
    private var lastTimestamp: Date?
    private var armed = false

    public init(
        replanner: Replanner = Replanner(),
        minDistanceKm: Double = 10,
        useMiles: Bool = false
    ) {
        self.replanner = replanner
        self.minDistanceKm = minDistanceKm
        self.useMiles = useMiles
    }

    /// Returns advice to surface once, or nil when the plan is on track.
    public func onTelemetry(
        telemetry: VehicleTelemetry,
        plan: TripPlan?,
        routePoints: [LatLon],
        position: LatLon?
    ) -> String? {
        guard let plan else {
            armed = false
            return nil
        }
        guard let soc = telemetry.socDisplay ?? telemetry.socBms else { return nil }

        // A new plan resets the baseline rather than comparing against the old one.
        if plan.generatedAt != planGeneratedAt {
            planGeneratedAt = plan.generatedAt
            let leg = plan.legs.first { $0.distanceKm > 1 }
            socPerKm = (leg.map { $0.distanceKm > 0 ? ($0.startSoc - $0.endSoc) / $0.distanceKm : 0 }) ?? 0
            startSoc = soc
            deadReckonedKm = 0
            lastTimestamp = telemetry.timestamp
            armed = true
            return nil
        }
        guard armed else { return nil }

        var travelledKm: Double
        var offRouteKm: Float?
        var predictedSoc: Float?

        if let position, routePoints.count >= 2 {
            let (alongKm, detourKm) = RouteGeo.projectOntoRoute(
                points: routePoints,
                lat: position.lat,
                lon: position.lon,
                totalKm: plan.totalDistanceKm
            )
            travelledKm = Double(alongKm)
            offRouteKm = detourKm
            predictedSoc = Self.predictedSoc(at: alongKm, plan: plan)
            deadReckonedKm = travelledKm
        } else {
            // Dead reckoning: integrate speed. Never yields an off-route figure.
            // A zero rate (leg.startSoc == leg.endSoc) would predict startSoc forever
            // and silently disable drift detection — bail out instead.
            guard socPerKm > 0 else { return nil }
            let dtHours = telemetry.timestamp.timeIntervalSince(lastTimestamp ?? telemetry.timestamp) / 3600
            if dtHours > 0, dtHours < 1 {
                deadReckonedKm += Double(telemetry.speedKph ?? 0) * dtHours
            }
            travelledKm = deadReckonedKm
            predictedSoc = startSoc - Float(travelledKm) * socPerKm
        }
        lastTimestamp = telemetry.timestamp

        // Too early to judge: SOC resolution makes short-distance drift meaningless.
        guard travelledKm >= minDistanceKm else { return nil }

        guard replanner.shouldReplan(
            predictedSoc: predictedSoc,
            actualSoc: soc,
            offRouteKm: offRouteKm
        ) else { return nil }

        return advice(actualSoc: soc, predictedSoc: predictedSoc, offRouteKm: offRouteKm)
    }

    public func reset() {
        planGeneratedAt = nil
        armed = false
        deadReckonedKm = 0
    }

    /// Interpolates the plan's own SOC profile at a distance along the route.
    private static func predictedSoc(at alongKm: Float, plan: TripPlan) -> Float? {
        var cursor: Float = 0
        for leg in plan.legs {
            let legEnd = cursor + leg.distanceKm
            if alongKm <= legEnd {
                guard leg.distanceKm > 0 else { return leg.startSoc }
                let fraction = (alongKm - cursor) / leg.distanceKm
                return leg.startSoc + (leg.endSoc - leg.startSoc) * fraction
            }
            cursor = legEnd
        }
        return plan.legs.last?.endSoc
    }

    private func advice(actualSoc: Float, predictedSoc: Float?, offRouteKm: Float?) -> String {
        if let offRouteKm, offRouteKm > 2 {
            let distance = useMiles
                ? String(format: "%.1f mi", offRouteKm * 0.621371)
                : String(format: "%.1f km", offRouteKm)
            return "You're \(distance) off the planned route. Re-plan to update your charging stops."
        }
        guard let predictedSoc else {
            return "Consumption differs from the plan. Consider re-planning."
        }
        let delta = actualSoc - predictedSoc
        if delta < 0 {
            return String(
                format: "Using more energy than planned (%.0f%% vs %.0f%% expected). You may need an earlier stop.",
                actualSoc, predictedSoc
            )
        }
        return String(
            format: "Using less energy than planned (%.0f%% vs %.0f%% expected). You may be able to skip a stop.",
            actualSoc, predictedSoc
        )
    }
}
