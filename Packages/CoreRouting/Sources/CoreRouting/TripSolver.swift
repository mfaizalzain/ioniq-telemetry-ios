import Foundation
import CoreDomain

// MARK: - RouteCharger

/// A charger projected onto the base route.
public struct RouteCharger: Sendable {
    public let charger: Charger
    public let distanceAlongRouteKm: Float
    public let detourKm: Float

    public init(charger: Charger, distanceAlongRouteKm: Float, detourKm: Float) {
        self.charger = charger
        self.distanceAlongRouteKm = distanceAlongRouteKm
        self.detourKm = detourKm
    }
}

// MARK: - SolverParams

public struct SolverParams: Sendable {
    public let usableKwh: Double
    public let startSocPercent: Float
    public let reserveSocPercent: Float
    public let arrivalReservePercent: Float
    public let chargeTargetMaxPercent: Float
    public let avgSpeedKph: Double
    public let consumptionKwhPer100Km: Double
    public let packTempC: Float
    public let priceWeight: Float
    public let ambientC: Float

    public static let fixedStopOverheadMin: Double = 5.0
    public static let detourPenaltyPerKm: Double = 1.5
    public static let socBucketPercent: Int = 5

    public init(
        usableKwh: Double,
        startSocPercent: Float,
        reserveSocPercent: Float = 10,
        arrivalReservePercent: Float = 20,
        chargeTargetMaxPercent: Float = 90,
        avgSpeedKph: Double = 95.0,
        consumptionKwhPer100Km: Double = 19.0,
        packTempC: Float = 25,
        priceWeight: Float = 0,
        ambientC: Float = 20
    ) {
        self.usableKwh = usableKwh
        self.startSocPercent = startSocPercent
        self.reserveSocPercent = reserveSocPercent
        self.arrivalReservePercent = arrivalReservePercent
        self.chargeTargetMaxPercent = chargeTargetMaxPercent
        self.avgSpeedKph = avgSpeedKph
        self.consumptionKwhPer100Km = consumptionKwhPer100Km
        self.packTempC = packTempC
        self.priceWeight = priceWeight
        self.ambientC = ambientC
    }
}

// MARK: - TripSolver

/// Charge-stop planner: Dijkstra over (charger, socBucket) nodes (spec §5.2).
/// Charge time is modeled from the real curve in the edge cost, so the solver
/// discovers on its own that several short stops in the fast part of the curve
/// beat one long stop into the taper.
public final class TripSolver: Sendable {
    private let consumption: ConsumptionModel

    // MARK: - Internal node types

    private struct Node: Hashable, Sendable {
        let chargerIdx: Int   // -1 = origin
        let socBucket: Int
    }

    private struct Arrival: Sendable {
        let stop: ChargeStop?
        let prev: Node?
        let arrivalSoc: Float
    }

    // MARK: - Simple min-priority queue

    private struct PriorityQueue {
        private var items: [(Node, Double)] = []

        var isEmpty: Bool { items.isEmpty }

        mutating func push(_ node: Node, _ cost: Double) {
            items.append((node, cost))
            items.sort { $0.1 < $1.1 }
        }

        mutating func pop() -> (Node, Double)? {
            guard !items.isEmpty else { return nil }
            return items.removeFirst()
        }
    }

    // MARK: - Init

    public init(consumption: ConsumptionModel = ConsumptionModel()) {
        self.consumption = consumption
    }

    // MARK: - Solve

    /// - Parameters:
    ///   - elevation: route climb/drop from the routing provider, spread evenly over
    ///     the route; only its net matters to the physics. Null when the provider reports
    ///     no elevation, which reproduces the old flat-ground behaviour.
    public func solve(
        origin: LatLon,
        destination: LatLon,
        totalRouteKm: Float,
        chargers: [RouteCharger],
        params: SolverParams,
        userWaypoints: [UserWaypoint] = [],
        elevation: RouteElevation? = nil
    ) -> TripPlan? {
        let netAscendM = elevation?.netM ?? 0
        // Climb per 100 km, so the grade term scales with the reference distance.
        let ascendPer100Km = totalRouteKm > 0
            ? Double(netAscendM) / Double(totalRouteKm) * 100.0 : 0.0

        // Real consumption from the physics model at the planned cruising speed and
        // ambient temperature (HVAC load included).
        let kwhPer100 = consumption
            .segmentEnergyKwh(
                distanceKm: 100.0, speedKph: params.avgSpeedKph,
                elevationGainM: ascendPer100Km, ambientC: params.ambientC
            )
            .clamped(to: 10.0...40.0)
        let socPerKm = kwhPer100 / 100.0 / params.usableKwh * 100.0
        let ascendPerKm = ascendPer100Km / 100.0

        func socUsed(_ distanceKm: Float) -> Float {
            Float(Double(distanceKm) * socPerKm)
        }

        func driveMinutes(_ distanceKm: Float) -> Double {
            Double(distanceKm) / params.avgSpeedKph * 60.0
        }

        // Direct drive with no stops?
        let directArrival = params.startSocPercent - socUsed(totalRouteKm)
        if directArrival >= params.arrivalReservePercent {
            return buildPlan(
                origin: origin, destination: destination, totalRouteKm: totalRouteKm,
                stops: [], arrivalSoc: directArrival, params: params,
                socPerKmValue: socPerKm, userWaypoints: userWaypoints,
                ascendPerKm: ascendPerKm, elevation: elevation
            )
        }

        let sorted = chargers
            .filter { $0.charger.isOperational && $0.charger.maxPowerKw >= 50 }
            .sorted { $0.distanceAlongRouteKm < $1.distanceAlongRouteKm }
        if sorted.isEmpty { return nil }

        let bucketSize = SolverParams.socBucketPercent
        var best: [Node: Double] = [:]
        var arrivals: [Node: Arrival] = [:]
        var queue = PriorityQueue()

        let start = Node(chargerIdx: -1, socBucket: Int(params.startSocPercent) / bucketSize)
        best[start] = 0.0
        arrivals[start] = Arrival(stop: nil, prev: nil, arrivalSoc: params.startSocPercent)
        queue.push(start, 0.0)

        var goal: Node? = nil
        var goalArrivalSoc: Float = 0
        // The true cost of finishing from a node is cost + the remaining drive time,
        // which differs per node — so "first node that can reach the destination" is
        // not the optimum. Track the best total found and only stop when every node
        // still queued costs at least that much.
        var bestGoalTotal = Double.greatestFiniteMagnitude

        while let (node, cost) = queue.pop() {
            // Nodes pop in cost order. If the cheapest unsettled node already costs
            // more than the best goal total, no later node can beat it.
            if cost >= bestGoalTotal { break }
            if cost > (best[node] ?? .greatestFiniteMagnitude) { continue }

            let fromKm: Float = node.chargerIdx < 0 ? 0 : sorted[node.chargerIdx].distanceAlongRouteKm
            guard let arrival = arrivals[node] else { continue }
            let socHere = arrival.stop?.departureSoc ?? arrival.arrivalSoc

            // Try finishing the trip from here. A node that reaches the destination
            // is terminal for its path (a further stop could only add time), so
            // record it as a goal candidate but keep searching for a cheaper one.
            let destSoc = socHere - socUsed(totalRouteKm - fromKm)
            if destSoc >= params.arrivalReservePercent {
                let total = cost + driveMinutes(totalRouteKm - fromKm)
                if total < bestGoalTotal {
                    bestGoalTotal = total
                    goal = node
                    goalArrivalSoc = destSoc
                }
                continue
            }

            // Expand to chargers further along the route.
            for i in sorted.indices {
                let next = sorted[i]
                if next.distanceAlongRouteKm <= fromKm { continue }
                // Reaching a charger means leaving the route and rejoining it, so the
                // detour is covered twice. Using it once under-counted the energy and
                // marked stops near the range edge as reachable when the round trip
                // would not be.
                let legKm = next.distanceAlongRouteKm - fromKm + next.detourKm * 2
                let arrivalSoc = socHere - socUsed(legKm)
                if arrivalSoc < params.reserveSocPercent { continue }   // unreachable

                // Charge to a set of candidate departure levels; bucket the result.
                let candidates: [Float] = [60, 80, params.chargeTargetMaxPercent]
                    .filter { $0 > arrivalSoc + 5 }
                for departSoc in candidates {
                    let curve = ChargeCurve(stationLimitKw: next.charger.maxPowerKw)
                    let chargeMin = curve.chargeMinutes(
                        fromSocPercent: arrivalSoc, toSocPercent: departSoc,
                        usableKwh: params.usableKwh, packTempC: params.packTempC
                    )
                    let energy = curve.energyAddedKwh(
                        fromSocPercent: arrivalSoc, toSocPercent: departSoc,
                        usableKwh: params.usableKwh
                    )
                    let price = next.charger.pricePerKwh ?? 0

                    let edgeCost = driveMinutes(legKm)
                        + Double(chargeMin)
                        + SolverParams.fixedStopOverheadMin
                        + Double(next.detourKm) * SolverParams.detourPenaltyPerKm
                        + Double(energy * price) * Double(params.priceWeight)

                    let nextNode = Node(chargerIdx: i, socBucket: Int(departSoc) / bucketSize)
                    let newCost = cost + edgeCost
                    if newCost < (best[nextNode] ?? .greatestFiniteMagnitude) {
                        best[nextNode] = newCost
                        arrivals[nextNode] = Arrival(
                            stop: ChargeStop(
                                charger: next.charger,
                                arrivalSoc: arrivalSoc,
                                departureSoc: departSoc,
                                chargeMinutes: chargeMin,
                                energyAddedKwh: energy,
                                distanceFromOriginKm: next.distanceAlongRouteKm,
                                detourKm: next.detourKm
                            ),
                            prev: node,
                            arrivalSoc: arrivalSoc
                        )
                        queue.push(nextNode, newCost)
                    }
                }
            }
        }

        guard let settled = goal else { return nil }

        // Walk back the chosen stops.
        var walker: Node? = settled
        var stops: [ChargeStop] = []
        while let node = walker {
            guard let arrival = arrivals[node] else { break }
            if let stop = arrival.stop { stops.append(stop) }
            walker = arrival.prev
        }
        stops.reverse()

        return buildPlan(
            origin: origin, destination: destination, totalRouteKm: totalRouteKm,
            stops: postProcess(stops: stops, params: params),
            arrivalSoc: goalArrivalSoc, params: params,
            socPerKmValue: socPerKm, userWaypoints: userWaypoints,
            ascendPerKm: ascendPerKm, elevation: elevation
        )
    }

    // MARK: - Post-processing

    /// Merge stops under 20 km apart; drop stops contributing under 5 minutes (spec §5.2).
    private func postProcess(stops: [ChargeStop], params: SolverParams) -> [ChargeStop] {
        var merged: [ChargeStop] = []
        for stop in stops {
            if let last = merged.last,
               stop.distanceFromOriginKm - last.distanceFromOriginKm < 20 {
                let curve = ChargeCurve(stationLimitKw: last.charger.maxPowerKw)
                let combined = ChargeStop(
                    charger: last.charger,
                    arrivalSoc: last.arrivalSoc,
                    departureSoc: stop.departureSoc,
                    chargeMinutes: curve.chargeMinutes(
                        fromSocPercent: last.arrivalSoc,
                        toSocPercent: stop.departureSoc,
                        usableKwh: params.usableKwh,
                        packTempC: params.packTempC
                    ),
                    energyAddedKwh: curve.energyAddedKwh(
                        fromSocPercent: last.arrivalSoc,
                        toSocPercent: stop.departureSoc,
                        usableKwh: params.usableKwh
                    ),
                    distanceFromOriginKm: last.distanceFromOriginKm,
                    // The merged stop is at the earlier charger, so its detour stands.
                    detourKm: last.detourKm
                )
                merged[merged.count - 1] = combined
            } else {
                merged.append(stop)
            }
        }
        return merged.filter { $0.chargeMinutes >= 5 }
    }

    // MARK: - Plan builder

    private func buildPlan(
        origin: LatLon,
        destination: LatLon,
        totalRouteKm: Float,
        stops: [ChargeStop],
        arrivalSoc: Float,
        params: SolverParams,
        socPerKmValue: Double,
        userWaypoints: [UserWaypoint],
        ascendPerKm: Double,
        elevation: RouteElevation?
    ) -> TripPlan {
        var legs: [TripLeg] = []
        var fromKm: Float = 0
        var fromSoc: Float = params.startSocPercent
        var prevLat = origin.lat
        var prevLon = origin.lon
        let socPerKm = Float(socPerKmValue)

        for stop in stops {
            let legKm = stop.distanceFromOriginKm - fromKm
            legs.append(TripLeg(
                fromLat: prevLat, fromLon: prevLon,
                toLat: stop.charger.lat, toLon: stop.charger.lon,
                distanceKm: legKm,
                driveMinutes: Int((Double(legKm) / params.avgSpeedKph * 60).rounded()),
                startSoc: fromSoc, endSoc: stop.arrivalSoc,
                elevationGainM: Float(Double(legKm) * ascendPerKm),
                geometry: ""
            ))
            fromKm = stop.distanceFromOriginKm
            fromSoc = stop.departureSoc
            prevLat = stop.charger.lat
            prevLon = stop.charger.lon
        }

        let lastKm = totalRouteKm - fromKm
        legs.append(TripLeg(
            fromLat: prevLat, fromLon: prevLon,
            toLat: destination.lat, toLon: destination.lon,
            distanceKm: lastKm,
            driveMinutes: Int((Double(lastKm) / params.avgSpeedKph * 60).rounded()),
            startSoc: fromSoc, endSoc: fromSoc - lastKm * socPerKm,
            elevationGainM: Float(Double(lastKm) * ascendPerKm),
            geometry: ""
        ))

        // Every stop's price comes from the same source (OCM usageCost or Places),
        // so either all stops carry one or none do. Only quote a total when the
        // whole route is priced — a partial sum would quietly understate the bill.
        let chargingCost: Float? = stops.isEmpty || stops.contains { $0.charger.pricePerKwh == nil }
            ? nil
            : stops.reduce(0) { $0 + $1.energyAddedKwh * ($1.charger.pricePerKwh ?? 0) }

        return TripPlan(
            origin: origin,
            destination: destination,
            legs: legs,
            stops: stops,
            userWaypoints: userWaypoints,
            // The legs lie along the base route, but the driver actually covers each
            // stop's detour; the SOC math already charges that energy, so the headline
            // distance must agree.
            totalDistanceKm: totalRouteKm + stops.map(\.detourKm).reduce(0, +),
            totalDriveMinutes: legs.map(\.driveMinutes).reduce(0, +),
            totalChargeMinutes: stops.map(\.chargeMinutes).reduce(0, +),
            arrivalSoc: arrivalSoc,
            generatedAt: Date(),
            elevation: elevation,
            totalChargingCost: chargingCost
        )
    }
}

// MARK: - Comparable.clamped helper

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
