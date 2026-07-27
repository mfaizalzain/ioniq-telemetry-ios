import Foundation
import SwiftData

@Model
public final class ChargerEntity {
    @Attribute(.unique) public var id: String
    public var name: String
    public var latitude: Double
    public var longitude: Double
    public var maxPowerKw: Float
    public var operatorName: String?
    public var connectors: String
    public var pricePerKwh: Float?
    public var usageCost: String?
    public var isOperational: Bool
    public var lastVerified: Date?

    public init(
        id: String,
        name: String,
        latitude: Double,
        longitude: Double,
        maxPowerKw: Float = 0,
        operatorName: String? = nil,
        connectors: String = "[]",
        pricePerKwh: Float? = nil,
        usageCost: String? = nil,
        isOperational: Bool = true,
        lastVerified: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.latitude = latitude
        self.longitude = longitude
        self.maxPowerKw = maxPowerKw
        self.operatorName = operatorName
        self.connectors = connectors
        self.pricePerKwh = pricePerKwh
        self.usageCost = usageCost
        self.isOperational = isOperational
        self.lastVerified = lastVerified
    }
}
