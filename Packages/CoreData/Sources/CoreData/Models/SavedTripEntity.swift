import Foundation
import SwiftData

@Model
public final class SavedTripEntity {
    @Attribute(.unique) public var id: String
    public var name: String
    public var planJson: String
    public var createdAt: Date

    public init(
        id: String,
        name: String,
        planJson: String,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.planJson = planJson
        self.createdAt = createdAt
    }
}
