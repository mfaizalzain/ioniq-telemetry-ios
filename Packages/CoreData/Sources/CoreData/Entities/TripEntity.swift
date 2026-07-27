import Foundation
import SwiftData

@Model
public final class TripEntity {
    @Attribute(.unique) public var id: UUID
    public var startTime: Date
    public var endTime: Date?
    public var startOdometerKm: Float?
    public var endOdometerKm: Float?
    public var distanceKm: Float
    public var energyKwh: Float
    public var avgEfficiencyKwhPer100km: Float?
    public var startSocPercent: Float?
    public var endSocPercent: Float?
    public var notes: String?
    public var startLatitude: Double?
    public var startLongitude: Double?
    public var endLatitude: Double?
    public var endLongitude: Double?

    @Relationship(deleteRule: .cascade, inverse: \SampleEntity.trip)
    public var samples: [SampleEntity]?

    public init(
        id: UUID = UUID(),
        startTime: Date,
        endTime: Date? = nil,
        startOdometerKm: Float? = nil,
        endOdometerKm: Float? = nil,
        distanceKm: Float = 0,
        energyKwh: Float = 0,
        avgEfficiencyKwhPer100km: Float? = nil,
        startSocPercent: Float? = nil,
        endSocPercent: Float? = nil,
        notes: String? = nil,
        startLatitude: Double? = nil,
        startLongitude: Double? = nil,
        endLatitude: Double? = nil,
        endLongitude: Double? = nil
    ) {
        self.id = id
        self.startTime = startTime
        self.endTime = endTime
        self.startOdometerKm = startOdometerKm
        self.endOdometerKm = endOdometerKm
        self.distanceKm = distanceKm
        self.energyKwh = energyKwh
        self.avgEfficiencyKwhPer100km = avgEfficiencyKwhPer100km
        self.startSocPercent = startSocPercent
        self.endSocPercent = endSocPercent
        self.notes = notes
        self.startLatitude = startLatitude
        self.startLongitude = startLongitude
        self.endLatitude = endLatitude
        self.endLongitude = endLongitude
    }
}
