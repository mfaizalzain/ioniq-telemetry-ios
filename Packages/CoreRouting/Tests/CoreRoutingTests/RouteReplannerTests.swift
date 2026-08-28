import CoreDomain
import Foundation
import Testing
@testable import CoreRouting

/// `RouteReplanner.reroute` is what makes an occupancy alert actionable: it re-solves
/// the rest of the trip from here, on the charge actually in the pack, with the busy
/// stop excluded. It had no callers and no tests until the occupancy alert was wired
/// to it, so its guard rails were unverified.
@Suite("RouteReplanner")
struct RouteReplannerTests {

    private var routePoints: [LatLon] { (0...20).map { LatLon(lat: Double($0) * 0.05, lon: 0) } }

    private func charger(_ id: String, lat: Double, powerKw: Float = 150) -> Charger {
        Charger(
            id: id, name: "Charger \(id)", lat: lat, lon: 0,
            connectors: [Connector(type: .ccs2, powerKw: powerKw, count: 2)],
            maxPowerKw: powerKw, isOperational: true
        )
    }

    private func plan(stopCharger: Charger, totalKm: Float = 200) -> TripPlan {
        TripPlan(
            origin: LatLon(lat: 0, lon: 0),
            destination: LatLon(lat: 1, lon: 0),
            stops: [ChargeStop(
                charger: stopCharger, arrivalSoc: 20, departureSoc: 80,
                chargeMinutes: 25, energyAddedKwh: 40, distanceFromOriginKm: totalKm / 2
            )],
            totalDistanceKm: totalKm,
            totalDriveMinutes: 150,
            totalChargeMinutes: 25,
            arrivalSoc: 20,
            generatedAt: Date(timeIntervalSince1970: 1)
        )
    }

    private var params: SolverParams {
        SolverParams(
            usableKwh: 74,
            startSocPercent: 60,
            reserveSocPercent: 10,
            arrivalReservePercent: 20,
            packTempC: 25,
            priceWeight: 0.3
        )
    }

    @Test("a reroute avoids the charger that is full")
    func excludesOccupiedCharger() throws {
        let busy = charger("busy", lat: 0.5)
        let alternative = charger("alt", lat: 0.55)
        let replanner = RouteReplanner()

        let result = replanner.reroute(
            currentPosition: LatLon(lat: 0.1, lon: 0),
            liveSocPercent: 60,
            plan: plan(stopCharger: busy),
            routePoints: routePoints,
            candidateChargers: [busy, alternative],
            occupiedChargerId: "busy",
            paramsTemplate: params
        )

        let rerouted = try #require(result, "expected an alternative to be reachable")
        #expect(
            !rerouted.plan.stops.contains { $0.charger.id == "busy" },
            "the busy charger must not come back in the alternative"
        )
        #expect(rerouted.remainingRoute.count >= 2)
    }

    /// The alternative has to start where the car is, not at the original origin —
    /// otherwise it would be solved against charge the driver no longer has.
    @Test("the alternative covers only the route still ahead")
    func remainingRouteStartsAtTheCar() throws {
        let busy = charger("busy", lat: 0.5)
        let result = RouteReplanner().reroute(
            currentPosition: LatLon(lat: 0.5, lon: 0),
            liveSocPercent: 60,
            plan: plan(stopCharger: busy),
            routePoints: routePoints,
            candidateChargers: [busy, charger("alt", lat: 0.75)],
            occupiedChargerId: "busy",
            paramsTemplate: params
        )
        let rerouted = try #require(result)
        // Half way along a 21-point route, so about half the points remain.
        #expect(rerouted.remainingRoute.count <= routePoints.count / 2 + 1)
        #expect(rerouted.remainingRoute.first?.lat == 0.5)
    }

    /// The only candidate is the occupied stop, so the re-solve has no chargers to
    /// work with. On a healthy charge that still leaves the destination directly
    /// reachable — the correct reroute is a stop-free plan, not nil. (Nil is the
    /// "nothing ahead is reachable" case, covered by the nearly-flat test below.)
    @Test("falls back to a stop-free run when the only candidate is occupied")
    func noAlternativeAvailable() {
        let busy = charger("busy", lat: 0.5)
        let result = RouteReplanner().reroute(
            currentPosition: LatLon(lat: 0.1, lon: 0),
            liveSocPercent: 60,
            plan: plan(stopCharger: busy),
            routePoints: routePoints,
            candidateChargers: [busy],
            occupiedChargerId: "busy",
            paramsTemplate: params
        )
        // Remaining polyline is ~100 km and the pack covers it, so the reroute
        // succeeds with no charging stop instead of failing outright.
        let rerouted = try? #require(result, "a stop-free reroute is still a route")
        #expect(rerouted?.plan.stops.isEmpty == true)
        #expect(rerouted?.remainingRoute.first?.lat == 0.1)
    }

    /// Mid charge, no candidates at all, and the destination out of reach on the
    /// pack alone: there is genuinely nothing to route through, so nil.
    @Test("nil when the only candidate is occupied and the destination is out of reach")
    func noAlternativeAndDestinationUnreachable() {
        let busy = charger("busy", lat: 0.5)
        let result = RouteReplanner().reroute(
            currentPosition: LatLon(lat: 0.1, lon: 0),
            liveSocPercent: 30,
            plan: plan(stopCharger: busy),
            routePoints: routePoints,
            candidateChargers: [busy],
            occupiedChargerId: "busy",
            paramsTemplate: params
        )
        #expect(result == nil, "excluding the only charger leaves nothing to route through")
    }

    /// A nearly flat battery cannot reach anything; the caller turns this nil into
    /// "reduce speed to extend range" rather than offering a stop that is out of reach.
    @Test("no alternative on a charge that cannot reach one")
    func noAlternativeOnEmptyBattery() {
        let busy = charger("busy", lat: 0.5)
        let result = RouteReplanner().reroute(
            currentPosition: LatLon(lat: 0.1, lon: 0),
            liveSocPercent: 3,
            plan: plan(stopCharger: busy, totalKm: 600),
            routePoints: routePoints,
            candidateChargers: [busy, charger("far", lat: 0.95)],
            occupiedChargerId: "busy",
            paramsTemplate: params
        )
        #expect(result == nil)
    }

    @Test("a route too short to project against yields no reroute")
    func degenerateRoute() {
        let busy = charger("busy", lat: 0.5)
        for points in [[], [LatLon(lat: 0, lon: 0)]] {
            let result = RouteReplanner().reroute(
                currentPosition: LatLon(lat: 0, lon: 0),
                liveSocPercent: 60,
                plan: plan(stopCharger: busy),
                routePoints: points,
                candidateChargers: [charger("alt", lat: 0.5)],
                occupiedChargerId: "busy",
                paramsTemplate: params
            )
            #expect(result == nil)
        }
    }
}
