import CoreDomain
import Foundation
import Testing
@testable import CoreRouting

/// Regressions for the charge-stop Dijkstra: the goal-break and the round-trip
/// detour both changed *which* plan the solver returns, so they need plans, not
/// just unit values.
@Suite("TripSolver")
struct TripSolverRegressionTests {

    private let origin = LatLon(lat: 52.5, lon: 13.4)
    private let destination = LatLon(lat: 48.1, lon: 11.6)

    private func charger(
        _ id: String, alongKm: Float, powerKw: Float = 150, detourKm: Float = 1
    ) -> RouteCharger {
        RouteCharger(
            charger: Charger(
                id: id, name: id, lat: 50.0, lon: 12.0,
                connectors: [Connector(type: .ccs2, powerKw: powerKw, count: 2)],
                maxPowerKw: powerKw, isOperational: true
            ),
            distanceAlongRouteKm: alongKm,
            detourKm: detourKm
        )
    }

    private var params: SolverParams {
        SolverParams(usableKwh: 74.0, startSocPercent: 90)
    }

    @Test("a later cheaper-to-finish stop beats the first node that can reach the destination")
    func goalBreak() throws {
        // From 90% on a 350 km run the 50 kW charger at 150 km is the first node
        // that can reach the destination (settles first: lowest cost-to-node), but
        // finishing through it costs a long charge. The 350 kW charger at 250 km
        // needs only a short top-up, so its total is lower — the solver must keep
        // searching past the first node that can finish instead of breaking on it.
        let slow = charger("slow", alongKm: 150, powerKw: 50)
        let fast = charger("fast", alongKm: 250, powerKw: 350)
        let plan = try #require(
            TripSolver().solve(
                origin: origin, destination: destination, totalRouteKm: 350,
                chargers: [slow, fast], params: params
            )
        )
        #expect(plan.stops.allSatisfy { $0.charger.id != "slow" })
        #expect(plan.arrivalSoc >= params.arrivalReservePercent)
    }

    @Test("a detour near the range edge is counted as a round trip")
    func roundTripDetour() throws {
        // Position a charger so that counting the detour once leaves the arrival
        // just above reserve, but counting it twice (leave the route, then rejoin
        // it) drops it below — the solver must treat it as unreachable. The same
        // charger with a small detour stays reachable as a control. The geometry
        // is derived from the same physics model the solver uses, so the test
        // stays discriminating across constant changes.
        let usableKwh = 74.0
        let model = ConsumptionModel()
        let kwhPer100 = model.segmentEnergyKwh(
            distanceKm: 100.0, speedKph: params.avgSpeedKph,
            elevationGainM: 0, ambientC: params.ambientC
        )
        let socPerKm = kwhPer100 / 100.0 / usableKwh * 100.0
        let reachKm = 80.0 / socPerKm      // distance that burns 80% SOC from 90%
        let alongKm = Float(reachKm) - 15  // ~3% above reserve with detour = 10
        let totalKm = alongKm + 150        // remaining drive is a comfortable finish

        let nearEdge = charger("edge", alongKm: alongKm, powerKw: 350, detourKm: 10)
        #expect(
            TripSolver().solve(
                origin: origin, destination: destination, totalRouteKm: totalKm,
                chargers: [nearEdge], params: params
            ) == nil
        )

        let smallDetour = charger("control", alongKm: alongKm, powerKw: 350, detourKm: 1)
        #expect(
            TripSolver().solve(
                origin: origin, destination: destination, totalRouteKm: totalKm,
                chargers: [smallDetour], params: params
            ) != nil
        )
    }

    @Test("charging cost totals price times energy across stops")
    func chargingCost() throws {
        func priced(_ id: String, _ alongKm: Float) -> RouteCharger {
            // RouteCharger.charger is a let — rebuild the charger with the price.
            return RouteCharger(
                charger: Charger(
                    id: id, name: id, lat: 50.0, lon: 12.0,
                    connectors: [Connector(type: .ccs2, powerKw: 350, count: 2)],
                    maxPowerKw: 350, isOperational: true, pricePerKwh: 0.5
                ),
                distanceAlongRouteKm: alongKm,
                detourKm: 1
            )
        }
        let plan = try #require(
            TripSolver().solve(
                origin: origin, destination: destination, totalRouteKm: 700,
                chargers: [priced("a", 150), priced("b", 300), priced("c", 450)],
                params: params
            )
        )
        let expected = plan.stops.reduce(Float(0)) { $0 + $1.energyAddedKwh * 0.5 }
        #expect(plan.totalChargingCost == expected)
    }

    @Test("charging cost is nil when any stop lacks a price")
    func chargingCostNilWithoutPrice() throws {
        func unpriced(_ id: String, _ alongKm: Float) -> RouteCharger {
            return RouteCharger(
                charger: Charger(
                    id: id, name: id, lat: 50.0, lon: 12.0,
                    connectors: [Connector(type: .ccs2, powerKw: 350, count: 2)],
                    maxPowerKw: 350, isOperational: true
                ),
                distanceAlongRouteKm: alongKm,
                detourKm: 1
            )
        }
        let plan = try #require(
            TripSolver().solve(
                origin: origin, destination: destination, totalRouteKm: 500,
                chargers: [unpriced("a", 200), unpriced("b", 400)],
                params: params
            )
        )
        #expect(plan.totalChargingCost == nil)
    }
}
