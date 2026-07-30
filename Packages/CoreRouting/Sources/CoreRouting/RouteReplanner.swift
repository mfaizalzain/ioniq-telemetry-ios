import Foundation
import CoreDomain

// MARK: - RouteGeo

/// Nearest-vertex geometry helpers shared by the live monitors and the re-planner.
public enum RouteGeo {
    /// Haversine distance in kilometres.
    public static func haversineKm(
        lat1: Double, lon1: Double, lat2: Double, lon2: Double
    ) -> Double {
        let r = 6371.0
        let dLat = (lat2 - lat1) * .pi / 180.0
        let dLon = (lon2 - lon1) * .pi / 180.0
        let a = sin(dLat / 2) * sin(dLat / 2)
            + cos(lat1 * .pi / 180.0) * cos(lat2 * .pi / 180.0)
            * sin(dLon / 2) * sin(dLon / 2)
        return r * 2 * atan2(sqrt(a), sqrt(1 - a))
    }

    /// Index of the polyline vertex closest to `position`.
    public static func nearestIndex(position: LatLon, points: [LatLon]) -> Int {
        var bestIdx = 0
        var bestDist = Double.greatestFiniteMagnitude
        for (i, p) in points.enumerated() {
            let d = haversineKm(
                lat1: position.lat, lon1: position.lon, lat2: p.lat, lon2: p.lon
            )
            if d < bestDist { bestDist = d; bestIdx = i }
        }
        return bestIdx
    }

    /// Projects a point onto `points`, returning (distance-along-km, off-route-detour-km).
    public static func projectOntoRoute(
        points: [LatLon], lat: Double, lon: Double, totalKm: Float
    ) -> (Float, Float) {
        if points.isEmpty { return (0, 0) }
        var bestIdx = 0
        var bestDist = Double.greatestFiniteMagnitude
        for (i, p) in points.enumerated() {
            let d = haversineKm(lat1: p.lat, lon1: p.lon, lat2: lat, lon2: lon)
            if d < bestDist { bestDist = d; bestIdx = i }
        }
        // Over segments, not points: with n points there are n-1 segments, so the
        // last point is the whole route. Dividing by `count` under-reported progress
        // by a factor of (n-1)/n — 91 km of a 100 km route at the destination on an
        // 11-point polyline, and half the route on a two-point one. Every ETA and
        // off-route figure downstream inherited that. Matches Android's
        // `projectAlongKm`, which divides by `points.size - 1`.
        let alongKm = totalKm * Float(bestIdx) / Float(max(points.count - 1, 1))
        return (alongKm, Float(bestDist))
    }
}

// MARK: - Rerouted

/// A re-plan from the current position, plus the polyline it covers.
public struct Rerouted: Sendable {
    public let plan: TripPlan
    public let remainingRoute: [LatLon]

    public init(plan: TripPlan, remainingRoute: [LatLon]) {
        self.plan = plan
        self.remainingRoute = remainingRoute
    }
}

// MARK: - RouteReplanner

/// Re-plans an in-progress trip from the driver's current position and *current*
/// state of charge, over the remaining portion of the already-routed polyline
/// (no new routing call). The alternative it returns is guaranteed reachable on
/// the current charge: `TripSolver` only expands edges whose arrival SOC stays
/// above the reserve, so a charger out of range is never chosen — and if nothing
/// (charger or destination) is reachable, `reroute` returns nil.
public final class RouteReplanner: Sendable {
    private let solver: TripSolver

    public init(solver: TripSolver = TripSolver()) {
        self.solver = solver
    }

    public func reroute(
        currentPosition: LatLon,
        liveSocPercent: Float,
        plan: TripPlan,
        routePoints: [LatLon],
        candidateChargers: [Charger],
        occupiedChargerId: String,
        paramsTemplate: SolverParams
    ) -> Rerouted? {
        if routePoints.count < 2 { return nil }

        let nearestIdx = RouteGeo.nearestIndex(position: currentPosition, points: routePoints)
        let remaining = Array(routePoints[nearestIdx...])
        if remaining.count < 2 { return nil }

        let alongKm = plan.totalDistanceKm * Float(nearestIdx) / Float(max(routePoints.count - 1, 1))
        let remainingKm = max(plan.totalDistanceKm - alongKm, 0)

        let routeChargers: [RouteCharger] = candidateChargers
            .filter { $0.id != occupiedChargerId }
            .map { c in
                let (along, detour) = RouteGeo.projectOntoRoute(
                    points: remaining, lat: c.lat, lon: c.lon, totalKm: remainingKm
                )
                return RouteCharger(charger: c, distanceAlongRouteKm: along, detourKm: detour)
            }

        // SolverParams is a struct with all lets; create a new instance with
        // overridden startSocPercent.
        let params = SolverParams(
            usableKwh: paramsTemplate.usableKwh,
            startSocPercent: liveSocPercent,
            reserveSocPercent: paramsTemplate.reserveSocPercent,
            arrivalReservePercent: paramsTemplate.arrivalReservePercent,
            chargeTargetMaxPercent: paramsTemplate.chargeTargetMaxPercent,
            avgSpeedKph: paramsTemplate.avgSpeedKph,
            consumptionKwhPer100Km: paramsTemplate.consumptionKwhPer100Km,
            packTempC: paramsTemplate.packTempC,
            priceWeight: paramsTemplate.priceWeight,
            ambientC: paramsTemplate.ambientC
        )

        guard let newPlan = solver.solve(
            origin: currentPosition,
            destination: plan.destination,
            totalRouteKm: remainingKm,
            chargers: routeChargers,
            params: params,
            // Deliberately flat: the original plan's ascent covers the whole route,
            // and most of the climbing may already be behind the car.
            elevation: nil
        ) else { return nil }

        return Rerouted(plan: newPlan, remainingRoute: remaining)
    }
}
