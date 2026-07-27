import Foundation
import SwiftData

@Model
public final class ChargerEntity {
    @Attribute(.unique) public var id: String
    public var name: String
    public var lat: Double
    public var lon: Double
    public var geohash: String
    public var maxPowerKw: Float
    public var connectorsJson: String
    public var `operator`: String?
    public var isOperational: Bool
    public var pricePerKwh: Float?
    public var cachedAt: Date
    public var isRestricted: Bool
    public var usageCost: String?

    public init(
        id: String,
        name: String,
        lat: Double,
        lon: Double,
        geohash: String,
        maxPowerKw: Float = 0,
        connectorsJson: String = "[]",
        operator: String? = nil,
        isOperational: Bool = true,
        pricePerKwh: Float? = nil,
        cachedAt: Date = Date(),
        isRestricted: Bool = false,
        usageCost: String? = nil
    ) {
        self.id = id
        self.name = name
        self.lat = lat
        self.lon = lon
        self.geohash = geohash
        self.maxPowerKw = maxPowerKw
        self.connectorsJson = connectorsJson
        self.operator = `operator`
        self.isOperational = isOperational
        self.pricePerKwh = pricePerKwh
        self.cachedAt = cachedAt
        self.isRestricted = isRestricted
        self.usageCost = usageCost
    }
}
