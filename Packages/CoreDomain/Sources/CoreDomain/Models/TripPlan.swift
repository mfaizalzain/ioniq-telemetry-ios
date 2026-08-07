import Foundation

// MARK: - TripPlan

public struct RouteElevation: Sendable, Equatable {
    public var ascendM: Float
    public var descendM: Float
    public var netM: Float { ascendM - descendM }

    public init(ascendM: Float, descendM: Float) {
        self.ascendM = ascendM
        self.descendM = descendM
    }
}

public struct TripPlan: Sendable, Equatable {
    public var origin: LatLon
    public var destination: LatLon
    public var legs: [TripLeg]
    public var stops: [ChargeStop]
    public var userWaypoints: [UserWaypoint]
    public var totalDistanceKm: Float
    public var totalDriveMinutes: Int
    public var totalChargeMinutes: Int
    public var arrivalSoc: Float
    public var generatedAt: Date
    public var elevation: RouteElevation?
    /// Planned charging bill: Σ energyAddedKwh × pricePerKwh across stops. Nil
    /// when any stop has no price — the network fee would be unknown, so quoting
    /// a total would understate the real cost.
    public var totalChargingCost: Float?

    public init(
        origin: LatLon,
        destination: LatLon,
        legs: [TripLeg] = [],
        stops: [ChargeStop] = [],
        userWaypoints: [UserWaypoint] = [],
        totalDistanceKm: Float,
        totalDriveMinutes: Int,
        totalChargeMinutes: Int = 0,
        arrivalSoc: Float,
        generatedAt: Date = Date(),
        elevation: RouteElevation? = nil,
        totalChargingCost: Float? = nil
    ) {
        self.origin = origin
        self.destination = destination
        self.legs = legs
        self.stops = stops
        self.userWaypoints = userWaypoints
        self.totalDistanceKm = totalDistanceKm
        self.totalDriveMinutes = totalDriveMinutes
        self.totalChargeMinutes = totalChargeMinutes
        self.arrivalSoc = arrivalSoc
        self.generatedAt = generatedAt
        self.elevation = elevation
        self.totalChargingCost = totalChargingCost
    }
}

// MARK: - TripLeg

public struct TripLeg: Sendable, Equatable {
    public var fromLat: Double
    public var fromLon: Double
    public var toLat: Double
    public var toLon: Double
    public var distanceKm: Float
    public var driveMinutes: Int
    public var startSoc: Float
    public var endSoc: Float
    public var elevationGainM: Float
    public var geometry: String

    public init(
        fromLat: Double, fromLon: Double,
        toLat: Double, toLon: Double,
        distanceKm: Float, driveMinutes: Int,
        startSoc: Float, endSoc: Float,
        elevationGainM: Float = 0,
        geometry: String = ""
    ) {
        self.fromLat = fromLat
        self.fromLon = fromLon
        self.toLat = toLat
        self.toLon = toLon
        self.distanceKm = distanceKm
        self.driveMinutes = driveMinutes
        self.startSoc = startSoc
        self.endSoc = endSoc
        self.elevationGainM = elevationGainM
        self.geometry = geometry
    }
}

// MARK: - ChargeStop

public struct ChargeStop: Sendable, Equatable {
    public var charger: Charger
    public var arrivalSoc: Float
    public var departureSoc: Float
    public var chargeMinutes: Int
    public var energyAddedKwh: Float
    public var distanceFromOriginKm: Float
    /// Perpendicular drive off the main route to reach this charger, in km.
    public var detourKm: Float

    public init(
        charger: Charger,
        arrivalSoc: Float,
        departureSoc: Float,
        chargeMinutes: Int,
        energyAddedKwh: Float,
        distanceFromOriginKm: Float,
        detourKm: Float = 0
    ) {
        self.charger = charger
        self.arrivalSoc = arrivalSoc
        self.departureSoc = departureSoc
        self.chargeMinutes = chargeMinutes
        self.energyAddedKwh = energyAddedKwh
        self.distanceFromOriginKm = distanceFromOriginKm
        self.detourKm = detourKm
    }
}

// MARK: - UserWaypoint

public struct UserWaypoint: Sendable, Equatable {
    public var name: String
    public var location: LatLon
    public var distanceFromOriginKm: Float

    public init(name: String, location: LatLon, distanceFromOriginKm: Float) {
        self.name = name
        self.location = location
        self.distanceFromOriginKm = distanceFromOriginKm
    }
}

// MARK: - ItineraryStep

public enum ItineraryStep: Sendable, Equatable {
    case departure(name: String, location: LatLon)
    case stopover(waypoint: UserWaypoint)
    case charge(stop: ChargeStop)
    case arrival(name: String, location: LatLon, distanceFromOriginKm: Float)

    public var distanceFromOriginKm: Float {
        switch self {
        case .departure: return 0
        case .stopover(let waypoint): return waypoint.distanceFromOriginKm
        case .charge(let stop): return stop.distanceFromOriginKm
        case .arrival(_, _, let dist): return dist
        }
    }
}

public extension TripPlan {
    func itinerarySteps(originName: String = "Origin", destinationName: String = "Destination") -> [ItineraryStep] {
        var intermediate = [ItineraryStep]()
        intermediate += userWaypoints.map { ItineraryStep.stopover(waypoint: $0) }
        intermediate += stops.map { ItineraryStep.charge(stop: $0) }
        intermediate.sort { $0.distanceFromOriginKm < $1.distanceFromOriginKm }

        return [.departure(name: originName, location: origin)]
            + intermediate
            + [.arrival(name: destinationName, location: destination, distanceFromOriginKm: totalDistanceKm)]
    }
}
