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

    @Test("net elevation is the last minus first GPS altitude, in time order")
    func netElevationFromSamples() throws {
        let (repo, context) = makeRepository()

        let trip = TripEntity(
            id: "climb",
            startTime: Date(timeIntervalSince1970: 1000),
            distanceKm: 10,
            energyUsedKwh: 2
        )
        context.insert(trip)
        // Inserted out of time order on purpose — the helper must sort by
        // timestamp before subtracting.
        context.insert(SampleEntity(
            tripId: "climb",
            timestamp: Date(timeIntervalSince1970: 1002),
            speedKph: 90,
            elevationM: 350
        ))
        context.insert(SampleEntity(
            tripId: "climb",
            timestamp: Date(timeIntervalSince1970: 1001),
            speedKph: 90,
            elevationM: 100
        ))
        try context.save()

        #expect(try repo.netElevationGainM(tripId: "climb") == 250)
        #expect(try repo.netElevationGainM(tripId: "no-such-trip") == nil)
    }

    @Test("trips(since:) returns only trips started at or after the cutoff, newest first")
    func tripsSinceFiltersOldTrips() throws {
        let (repo, context) = makeRepository()

        // Three trips a day apart; the cutoff sits between the middle and newest.
        let old = Date(timeIntervalSince1970: 1_000)
        let middle = old.addingTimeInterval(24 * 3600)
        let newest = middle.addingTimeInterval(24 * 3600)
        for (id, start) in [("old", old), ("middle", middle), ("newest", newest)] {
            context.insert(TripEntity(id: id, startTime: start, distanceKm: 10, energyUsedKwh: 2))
        }
        try context.save()

        let cutoff = middle.addingTimeInterval(12 * 3600)
        let result = try repo.trips(since: cutoff)

        #expect(result.map(\.id) == ["newest"])
    }

    @Test("trips(limit:) returns only the N most recent trips")
    func tripsLimitCapsResult() throws {
        let (repo, context) = makeRepository()

        for i in 0..<5 {
            let start = Date(timeIntervalSince1970: 1_000 + Double(i) * 3600)
            context.insert(TripEntity(id: "t\(i)", startTime: start, distanceKm: 10, energyUsedKwh: 2))
        }
        try context.save()

        let result = try repo.trips(limit: 2)

        // Newest two, newest first.
        #expect(result.map(\.id) == ["t4", "t3"])
    }

    @Test("trips() with no arguments still returns the full history")
    func tripsUnparameterizedReturnsAll() throws {
        let (repo, context) = makeRepository()

        for i in 0..<3 {
            let start = Date(timeIntervalSince1970: 1_000 + Double(i) * 3600)
            context.insert(TripEntity(id: "t\(i)", startTime: start, distanceKm: 10, energyUsedKwh: 2))
        }
        try context.save()

        #expect(try repo.trips().count == 3)
    }

    @Test("net elevation is nil when samples carry no GPS altitude")
    func netElevationNilWithoutAltitude() throws {
        let (repo, context) = makeRepository()

        let trip = TripEntity(
            id: "flat",
            startTime: Date(timeIntervalSince1970: 1000),
            distanceKm: 10,
            energyUsedKwh: 2
        )
        context.insert(trip)
        context.insert(SampleEntity(
            tripId: "flat",
            timestamp: Date(timeIntervalSince1970: 1001),
            speedKph: 90
        ))
        try context.save()

        #expect(try repo.netElevationGainM(tripId: "flat") == nil)
    }
}
