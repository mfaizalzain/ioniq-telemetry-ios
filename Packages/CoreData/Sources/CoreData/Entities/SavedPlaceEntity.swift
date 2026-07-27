import Foundation
import SwiftData

@Model
public final class SavedPlaceEntity {
    @Attribute(.unique) public var id: UUID
    public var name: String
    public var label: String
    public var latitude: Double
    public var longitude: Double
    public var createdAt: Date

    public init(
        id: UUID = UUID(),
        name: String,
        label: String = "",
        latitude: Double,
        longitude: Double,
        createdAt: Date = .now
    ) {
        self.id = id
        self.name = name
        self.label = label
        self.latitude = latitude
        self.longitude = longitude
        self.createdAt = createdAt
    }
}
