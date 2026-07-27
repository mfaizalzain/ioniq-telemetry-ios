import Foundation
import SwiftData

@Model
public final class SampleEntity {
    @Attribute(.unique) public var id: UUID
    public var timestamp: Date
    public var speedKph: Float?
    public var socPercent: Float?
    public var powerKw: Float?
    public var packVoltage: Float?
    public var packCurrent: Float?
    public var cellDeltaMv: Float?
    public var maxCellTempC: Float?
    public var minCellTempC: Float?
    public var latitude: Double?
    public var longitude: Double?
    public var trip: TripEntity?

    public init(
        id: UUID = UUID(),
        timestamp: Date,
        speedKph: Float? = nil,
        socPercent: Float? = nil,
        powerKw: Float? = nil,
        packVoltage: Float? = nil,
        packCurrent: Float? = nil,
        cellDeltaMv: Float? = nil,
        maxCellTempC: Float? = nil,
        minCellTempC: Float? = nil,
        latitude: Double? = nil,
        longitude: Double? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.speedKph = speedKph
        self.socPercent = socPercent
        self.powerKw = powerKw
        self.packVoltage = packVoltage
        self.packCurrent = packCurrent
        self.cellDeltaMv = cellDeltaMv
        self.maxCellTempC = maxCellTempC
        self.minCellTempC = minCellTempC
        self.latitude = latitude
        self.longitude = longitude
    }
}
