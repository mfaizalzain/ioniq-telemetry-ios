import Combine
import CoreDomain
import Foundation
import SwiftData
import Testing
@testable import CoreData

// MARK: - Mock

private final class MockEntitlement: EntitlementRepository, @unchecked Sendable {
    private let subject = CurrentValueSubject<Bool, Never>(true)
    var isPro: AnyPublisher<Bool, Never> { subject.eraseToAnyPublisher() }
    func setPro(_ isPro: Bool, token: String?) async { subject.send(isPro) }
    func refreshEntitlements() async -> Bool { subject.value }
}

// MARK: - Suite

@Suite("TripLogRepository")
struct TripLogRepositoryTests {

    /// In-memory ModelContainer registered with all entity types.
    private func makeContainer() -> ModelContainer {
        let schema = Schema([
            TripEntity.self,
            SampleEntity.self,
            ChargeSessionEntity.self,
            SavedTripEntity.self,
            SavedPlaceEntity.self,
        ])
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        return try! ModelContainer(for: schema, configurations: config)
    }

    private func makeRepository() -> (TripLogRepository, ModelContext) {
        let container = makeContainer()
        let context = ModelContext(container)
        let repo = TripLogRepository(
            modelContext: context,
            entitlement: MockEntitlement(),
            preferencesRepository: MockPreferencesRepository()
        )
        return (repo, context)
    }

    @Test("undo restores the deleted trip's samples with it")
    func undoRestoresSamples() throws {
        let (repo, context) = makeRepository()

        let trip = TripEntity(
            id: "t1", startTime: Date(timeIntervalSince1970: 1000),
            distanceKm: 42, energyUsedKwh: 8
        )
        context.insert(trip)
        let sample = SampleEntity(
            tripId: "t1", timestamp: Date(timeIntervalSince1970: 1010),
            soc: 80, powerKw: -20, speedKph: 90, lat: 3.139, lon: 101.6869
        )
        context.insert(sample)
        try context.save()

        try repo.deleteTrip(id: "t1")
        // The trip and its samples are gone from the store.
        #expect(try context.fetch(FetchDescriptor<TripEntity>()).isEmpty)
        #expect(try context.fetch(FetchDescriptor<SampleEntity>()).isEmpty)

        try repo.restoreTrip(trip)
        #expect(try context.fetch(FetchDescriptor<TripEntity>()).count == 1)
        let restored = try context.fetch(
            FetchDescriptor<SampleEntity>(predicate: #Predicate { $0.tripId == "t1" })
        )
        #expect(restored.count == 1)
        #expect(restored.first?.soc == 80)
        #expect(restored.first?.lat == 3.139)
    }
}
