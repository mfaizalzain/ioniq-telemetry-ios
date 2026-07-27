import Foundation
import SwiftData

@MainActor
public final class AppDatabase: Sendable {
    public static let shared = AppDatabase()
    public let container: ModelContainer

    private init() {
        let schema = Schema([
            TripEntity.self,
            SampleEntity.self,
            ChargeSessionEntity.self,
            SavedTripEntity.self,
            SavedPlaceEntity.self,
            ChargerEntity.self
        ])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)
        do {
            container = try ModelContainer(for: schema, configurations: [config])
        } catch {
            fatalError("Failed to create ModelContainer: \(error)")
        }
    }
}
