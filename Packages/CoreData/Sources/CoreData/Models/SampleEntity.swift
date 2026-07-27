import Foundation
import SwiftData

@Model
public final class SampleEntity {
    public var tripId: String
    public var timestamp: Date
    public var soc: Float?
    public var powerKw: Float?
    public var speedKph: Float?
    public var lat: Double?
    public var lon: Double?
    public var elevationM: Float?
    public var ambientTempC: Float?
    public var packTempC: Float?

    public init(
        tripId: String,
        timestamp: Date,
        soc: Float? = nil,
        powerKw: Float? = nil,
        speedKph: Float? = nil,
        lat: Double? = nil,
        lon: Double? = nil,
        elevationM: Float? = nil,
        ambientTempC: Float? = nil,
        packTempC: Float? = nil
    ) {
        self.tripId = tripId
        self.timestamp = timestamp
        self.soc = soc
        self.powerKw = powerKw
        self.speedKph = speedKph
        self.lat = lat
        self.lon = lon
        self.elevationM = elevationM
        self.ambientTempC = ambientTempC
        self.packTempC = packTempC
    }
}
