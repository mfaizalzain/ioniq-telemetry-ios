import Foundation
import SwiftData

@Model
public final class SavedTripEntity {
    @Attribute(.unique) public var id: UUID
    public var name: String
    public var originName: String
    public var destName: String
    public var originLat: Double?
    public var originLon: Double?
    public var destLat: Double?
    public var destLon: Double?
    public var planJson: String
    public var createdAt: Date

    public init(
        id: UUID = UUID(),
        name: String,
        originName: String = "",
        destName: String = "",
        originLat: Double? = nil,
        originLon: Double? = nil,
        destLat: Double? = nil,
        destLon: Double? = nil,
        planJson: String = "{}",
        createdAt: Date = .now
    ) {
        self.id = id
        self.name = name
        self.originName = originName
        self.destName = destName
        self.originLat = originLat
        self.originLon = originLon
        self.destLat = destLat
        self.destLon = destLon
        self.planJson = planJson
        self.createdAt = createdAt
    }
}
