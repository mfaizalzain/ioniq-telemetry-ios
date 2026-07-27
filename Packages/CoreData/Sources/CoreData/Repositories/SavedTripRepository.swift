import Foundation
import SwiftData

/// A place chosen for a saved trip — name plus coordinates.
public struct SavedPlaceDef: Codable, Sendable, Equatable {
    public let name: String
    public let lat: Double
    public let lon: Double

    public init(name: String, lat: Double, lon: Double) {
        self.name = name
        self.lat = lat
        self.lon = lon
    }
}

/// The reusable definition of a trip: endpoints, stopovers, and target arrival buffer.
public struct SavedTripDef: Codable, Sendable, Equatable {
    public let origin: SavedPlaceDef
    public let destination: SavedPlaceDef
    public let waypoints: [SavedPlaceDef]
    public let arrivalSocTarget: Float

    public init(
        origin: SavedPlaceDef,
        destination: SavedPlaceDef,
        waypoints: [SavedPlaceDef] = [],
        arrivalSocTarget: Float = 20
    ) {
        self.origin = origin
        self.destination = destination
        self.waypoints = waypoints
        self.arrivalSocTarget = arrivalSocTarget
    }
}

/// A named, persisted SavedTripDef.
public struct SavedTrip: Identifiable, Sendable, Equatable {
    public let id: String
    public let name: String
    public let def: SavedTripDef
    public let createdAt: Date

    public init(id: String, name: String, def: SavedTripDef, createdAt: Date) {
        self.id = id
        self.name = name
        self.def = def
        self.createdAt = createdAt
    }
}

/// Repository for saved trips — simple CRUD with SwiftData.
public final class SavedTripRepository: @unchecked Sendable {
    private let modelContext: ModelContext
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(modelContext: ModelContext) {
        self.modelContext = modelContext
    }

    public func all() throws -> [SavedTrip] {
        let descriptor = FetchDescriptor<SavedTripEntity>(sortBy: [SortDescriptor(\.createdAt, order: .reverse)])
        let entities = try modelContext.fetch(descriptor)
        return entities.compactMap { entity in
            guard let data = entity.planJson.data(using: .utf8),
                  let def = try? decoder.decode(SavedTripDef.self, from: data)
            else { return nil }
            return SavedTrip(id: entity.id, name: entity.name, def: def, createdAt: entity.createdAt)
        }
    }

    /// Saves a favorite trip route plan. Deduplicates by exact name match or matching
    /// origin & destination coordinates.
    @discardableResult
    public func save(name: String, def: SavedTripDef, id: String? = nil) throws -> String {
        let existing = try all()
        let match = existing.first {
            (id != nil && $0.id == id) ||
            $0.name.caseInsensitiveCompare(name.trimmingCharacters(in: .whitespaces)) == .orderedSame ||
            (abs($0.def.origin.lat - def.origin.lat) < 0.0001 &&
             abs($0.def.origin.lon - def.origin.lon) < 0.0001 &&
             abs($0.def.destination.lat - def.destination.lat) < 0.0001 &&
             abs($0.def.destination.lon - def.destination.lon) < 0.0001)
        }

        let targetId = id ?? match?.id ?? UUID().uuidString
        let jsonData = try encoder.encode(def)
        let jsonString = String(data: jsonData, encoding: .utf8) ?? "{}"

        let entity = SavedTripEntity(
            id: targetId,
            name: name.trimmingCharacters(in: .whitespaces),
            planJson: jsonString,
            createdAt: match?.createdAt ?? Date()
        )
        modelContext.insert(entity)
        try modelContext.save()
        return targetId
    }

    public func delete(id: String) throws {
        let descriptor = FetchDescriptor<SavedTripEntity>(predicate: #Predicate { $0.id == id })
        if let entity = try modelContext.fetch(descriptor).first {
            modelContext.delete(entity)
            try modelContext.save()
        }
    }
}
