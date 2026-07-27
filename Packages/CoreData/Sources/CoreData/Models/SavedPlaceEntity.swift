import Foundation
import SwiftData

@Model
public final class SavedPlaceEntity {
    @Attribute(.unique) public var id: String
    public var name: String
    public var category: String
    public var lat: Double
    public var lon: Double
    public var createdAt: Date

    public init(
        id: String,
        name: String,
        category: String = "CUSTOM",
        lat: Double,
        lon: Double,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.category = category
        self.lat = lat
        self.lon = lon
        self.createdAt = createdAt
    }
}
