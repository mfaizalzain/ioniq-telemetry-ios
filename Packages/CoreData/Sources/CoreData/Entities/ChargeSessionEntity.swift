import Foundation
import SwiftData

@Model
public final class ChargeSessionEntity {
    @Attribute(.unique) public var id: UUID
    public var startTime: Date
    public var endTime: Date?
    public var energyAddedKwh: Float
    public var maxPowerKw: Float?
    public var avgPowerKw: Float?
    public var startSoc: Float?
    public var endSoc: Float?
    public var chargeType: String?
    public var chargerName: String?
    public var chargerLat: Double?
    public var chargerLon: Double?
    public var costEstimate: String?
    public var isSaved: Bool

    public init(
        id: UUID = UUID(),
        startTime: Date,
        endTime: Date? = nil,
        energyAddedKwh: Float = 0,
        maxPowerKw: Float? = nil,
        avgPowerKw: Float? = nil,
        startSoc: Float? = nil,
        endSoc: Float? = nil,
        chargeType: String? = nil,
        chargerName: String? = nil,
        chargerLat: Double? = nil,
        chargerLon: Double? = nil,
        costEstimate: String? = nil,
        isSaved: Bool = false
    ) {
        self.id = id
        self.startTime = startTime
        self.endTime = endTime
        self.energyAddedKwh = energyAddedKwh
        self.maxPowerKw = maxPowerKw
        self.avgPowerKw = avgPowerKw
        self.startSoc = startSoc
        self.endSoc = endSoc
        self.chargeType = chargeType
        self.chargerName = chargerName
        self.chargerLat = chargerLat
        self.chargerLon = chargerLon
        self.costEstimate = costEstimate
        self.isSaved = isSaved
    }
}
