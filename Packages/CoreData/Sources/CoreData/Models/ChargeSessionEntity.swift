import Foundation
import SwiftData

@Model
public final class ChargeSessionEntity {
    @Attribute(.unique) public var id: String
    public var startTime: Date
    public var endTime: Date?
    public var startSoc: Float
    public var endSoc: Float?
    public var energyAddedKwh: Float
    public var peakPowerKw: Float
    public var avgPowerKw: Float
    public var chargeType: String
    public var packTempStartC: Float?
    public var chargerId: String?

    public init(
        id: String,
        startTime: Date,
        endTime: Date? = nil,
        startSoc: Float = 0,
        endSoc: Float? = nil,
        energyAddedKwh: Float = 0,
        peakPowerKw: Float = 0,
        avgPowerKw: Float = 0,
        chargeType: String = "DC",
        packTempStartC: Float? = nil,
        chargerId: String? = nil
    ) {
        self.id = id
        self.startTime = startTime
        self.endTime = endTime
        self.startSoc = startSoc
        self.endSoc = endSoc
        self.energyAddedKwh = energyAddedKwh
        self.peakPowerKw = peakPowerKw
        self.avgPowerKw = avgPowerKw
        self.chargeType = chargeType
        self.packTempStartC = packTempStartC
        self.chargerId = chargerId
    }
}
