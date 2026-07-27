import Foundation
import SwiftData
import CoreDomain

/// Repository for saved places — simple CRUD with SwiftData.
public final class SavedPlaceRepository: @unchecked Sendable {
    private let modelContext: ModelContext

    public init(modelContext: ModelContext) {
        self.modelContext = modelContext
    }

    public func all() throws -> [SavedPlaceEntity] {
        let descriptor = FetchDescriptor<SavedPlaceEntity>(sortBy: [SortDescriptor(\.createdAt, order: .reverse)])
        return try modelContext.fetch(descriptor)
    }

    /// Saves a favorite place location. Deduplicates by coordinates (within 0.0001 deg ~ 11m)
    /// or exact name match so duplicate rows are never created for the same location.
    @discardableResult
    public func savePlace(
        name: String,
        lat: Double,
        lon: Double,
        category: String = "CUSTOM",
        id: String? = nil
    ) throws -> String {
        let existing = try all()
        let match = existing.first {
            (id != nil && $0.id == id) ||
            (abs($0.lat - lat) < 0.0001 && abs($0.lon - lon) < 0.0001) ||
            $0.name.caseInsensitiveCompare(name.trimmingCharacters(in: .whitespaces)) == .orderedSame
        }

        let targetId = id ?? match?.id ?? UUID().uuidString
        let entity = SavedPlaceEntity(
            id: targetId,
            name: name.trimmingCharacters(in: .whitespaces),
            category: category,
            lat: lat,
            lon: lon,
            createdAt: match?.createdAt ?? Date()
        )
        modelContext.insert(entity)
        try modelContext.save()
        return targetId
    }

    public func deletePlace(id: String) throws {
        let descriptor = FetchDescriptor<SavedPlaceEntity>(predicate: #Predicate { $0.id == id })
        if let entity = try modelContext.fetch(descriptor).first {
            modelContext.delete(entity)
            try modelContext.save()
        }
    }

    public func deleteByCoordinates(lat: Double, lon: Double) throws {
        let all = try self.all()
        if let match = all.first(where: { abs($0.lat - lat) < 0.0001 && abs($0.lon - lon) < 0.0001 }) {
            modelContext.delete(match)
            try modelContext.save()
        }
    }

    public func toggleFavorite(
        name: String,
        location: LatLon,
        category: String = "CUSTOM"
    ) throws {
        let existing = try all()
        if let match = existing.first(where: { abs($0.lat - location.lat) < 0.0001 && abs($0.lon - location.lon) < 0.0001 }) {
            modelContext.delete(match)
        } else {
            try savePlace(name: name, lat: location.lat, lon: location.lon, category: category)
        }
        try modelContext.save()
    }
}
