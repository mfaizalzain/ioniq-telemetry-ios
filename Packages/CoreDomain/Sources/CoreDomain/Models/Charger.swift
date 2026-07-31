import Foundation

// MARK: - LatLon

public struct LatLon: Sendable, Equatable, Hashable {
    public var lat: Double
    public var lon: Double

    public init(lat: Double, lon: Double) {
        self.lat = lat
        self.lon = lon
    }
}

// MARK: - Charger

public struct Charger: Sendable, Identifiable, Equatable {
    public var id: String
    public var name: String
    public var address: String?
    public var lat: Double
    public var lon: Double
    public var connectors: [Connector]
    public var maxPowerKw: Float
    public var `operator`: String?
    public var isOperational: Bool
    public var pricePerKwh: Float?
    public var lastVerified: Date?
    public var isRestricted: Bool
    public var usageCost: String?
    /// True when the occupancy enrichment matched this charger to a station that
    /// reported live connector availability. UI must never show a "full" state
    /// for a charger without this flag — "no data" is not "free", and it is not
    /// "full" either.
    public var hasLiveStatus: Bool = false

    public init(
        id: String,
        name: String,
        address: String? = nil,
        lat: Double,
        lon: Double,
        connectors: [Connector] = [],
        maxPowerKw: Float = 0,
        operator: String? = nil,
        isOperational: Bool = true,
        pricePerKwh: Float? = nil,
        lastVerified: Date? = nil,
        isRestricted: Bool = false,
        usageCost: String? = nil,
        hasLiveStatus: Bool = false
    ) {
        self.id = id
        self.name = name
        self.address = address
        self.lat = lat
        self.lon = lon
        self.connectors = connectors
        self.maxPowerKw = maxPowerKw
        self.operator = `operator`
        self.isOperational = isOperational
        self.pricePerKwh = pricePerKwh
        self.lastVerified = lastVerified
        self.isRestricted = isRestricted
        self.usageCost = usageCost
        self.hasLiveStatus = hasLiveStatus
    }
}

// MARK: - Connector

public struct Connector: Sendable, Equatable, Codable {
    public var type: ConnectorType
    public var powerKw: Float
    public var count: Int

    public init(type: ConnectorType, powerKw: Float, count: Int) {
        self.type = type
        self.powerKw = powerKw
        self.count = count
    }
}

public enum ConnectorType: String, Sendable, CaseIterable, Codable {
    case ccs2 = "CCS2"
    case ccs1 = "CCS1"
    case chademo = "CHADEMO"
    case type2 = "TYPE2"
    case nacs = "NACS"
    case teslaSupercharger = "TESLA_SUPERCHARGER"
}
