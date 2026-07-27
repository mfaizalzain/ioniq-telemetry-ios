import Foundation
import SwiftData

@Model
public final class TripEntity {
    @Attribute(.unique) public var id: String
    public var startTime: Date
    public var endTime: Date?
    public var startSoc: Float
    public var endSoc: Float?
    public var distanceKm: Float
    public var energyUsedKwh: Float
    public var avgConsumptionKwhPer100km: Float?
    public var ambientTempAvgC: Float?
    public var note: String?

    public init(
        id: String,
        startTime: Date,
        endTime: Date? = nil,
        startSoc: Float = 0,
        endSoc: Float? = nil,
        distanceKm: Float = 0,
        energyUsedKwh: Float = 0,
        avgConsumptionKwhPer100km: Float? = nil,
        ambientTempAvgC: Float? = nil,
        note: String? = nil
    ) {
        self.id = id
        self.startTime = startTime
        self.endTime = endTime
        self.startSoc = startSoc
        self.endSoc = endSoc
        self.distanceKm = distanceKm
        self.energyUsedKwh = energyUsedKwh
        self.avgConsumptionKwhPer100km = avgConsumptionKwhPer100km
        self.ambientTempAvgC = ambientTempAvgC
        self.note = note
    }
}
