import Combine
import CoreDomain
import Foundation
import SwiftData
import Testing
@testable import CoreData

/// Format 2 is shared with the Android build. `backup-v2-golden.json` is
/// byte-identical to `core-data/src/test/resources/backup-v2-golden.json` in the
/// Android repo, and `BackupFormatV2Test` there asserts the same values — so a
/// change that breaks portability fails a test on both platforms instead of
/// surfacing as a mangled restore on someone's new phone.
///
/// Format 1 was platform-specific (iOS: `version`, ISO 8601 dates, `savedTrips`;
/// Android: `formatVersion`, epoch millis, `savedPlans`). Both are still readable.
@Suite("Backup format v2")
struct BackupFormatV2Tests {

    // MARK: - Helpers

    private func makeContainer() -> ModelContainer {
        let schema = Schema([
            TripEntity.self,
            SampleEntity.self,
            ChargeSessionEntity.self,
            SavedTripEntity.self,
            SavedPlaceEntity.self,
        ])
        return try! ModelContainer(
            for: schema,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
    }

    private func makeRepository(
        prefs: UserPreferences = UserPreferences()
    ) -> (BackupRepository, ModelContext, MockPreferencesRepository) {
        let context = ModelContext(makeContainer())
        let mockPrefs = MockPreferencesRepository(prefs)
        return (BackupRepository(modelContext: context, preferences: mockPrefs), context, mockPrefs)
    }

    private func goldenFixture() throws -> Data {
        let url = try #require(
            Bundle.module.url(forResource: "Fixtures/backup-v2-golden", withExtension: "json"),
            "golden fixture missing from the test bundle"
        )
        return try Data(contentsOf: url)
    }

    /// Epoch millis → Date, matching the fixture's encoding.
    private func date(_ millis: Int64) -> Date {
        Date(timeIntervalSince1970: Double(millis) / 1000)
    }

    // MARK: - Golden fixture

    @Test("the shared golden fixture restores with every value intact")
    func goldenFixtureRestores() async throws {
        let (repo, context, prefs) = makeRepository()
        let summary = try await repo.restore(from: try goldenFixture())

        #expect(summary.trips == 1)
        #expect(summary.samples == 1)
        #expect(summary.chargeSessions == 1)
        #expect(summary.savedTrips == 1)
        #expect(summary.savedPlaces == 1)
        #expect(summary.settingsRestored)

        let trip = try #require(try context.fetch(FetchDescriptor<TripEntity>()).first)
        #expect(trip.id == "trip-1")
        #expect(trip.startTime == date(1753840000000))
        #expect(trip.endTime == date(1753843600000))
        #expect(trip.distanceKm == 128.5)
        #expect(trip.note == "Trip to the office")
        // Format 1 on iOS dropped this field entirely.
        #expect(trip.aiBriefing == "Smooth run, regen did most of the work downhill.")

        let sample = try #require(try context.fetch(FetchDescriptor<SampleEntity>()).first)
        #expect(sample.tripId == "trip-1")
        #expect(sample.timestamp == date(1753840000000))
        #expect(sample.lat == 3.139)

        let session = try #require(try context.fetch(FetchDescriptor<ChargeSessionEntity>()).first)
        #expect(session.id == "session-1")
        #expect(session.startTime == date(1753846200000))
        #expect(session.chargeType == "DC")

        // Android calls these `savedPlans` on the wire; locally they are saved trips.
        let plan = try #require(try context.fetch(FetchDescriptor<SavedTripEntity>()).first)
        #expect(plan.id == "plan-1")
        #expect(plan.name == "KL to Penang")
        #expect(plan.createdAt == date(1753600000000))

        let place = try #require(try context.fetch(FetchDescriptor<SavedPlaceEntity>()).first)
        #expect(place.id == "place-1")
        #expect(place.createdAt == date(1753500000000))

        let restored = prefs.current
        #expect(restored.unitSystem == .imperial)
        #expect(restored.themeMode == .dark)
        #expect(restored.activeProfileId == "ioniq5_2022_77kwh")
        #expect(restored.customUsableBatteryKwh == 74.5)
        #expect(restored.customVehicleName == "My Ioniq")
        #expect(restored.reserveSocPercent == 15)
        #expect(restored.targetArrivalSocPercent == 25)
        #expect(restored.geminiApiKey == "gemini-key-abc")
        #expect(restored.googleMapsApiKey == "gmaps-key-abc")
        #expect(restored.orsApiKey == "ors-key-abc")
        // All four were dropped by one platform or the other before format 2.
        #expect(restored.deepseekApiKey == "ds-key-abc")
        #expect(restored.aiProvider == .deepseek)
        #expect(restored.connectorTypes == [.ccs2, .type2])
        #expect(restored.dynamicColor == false)
        #expect(restored.lastObdDeviceAddress == "AA:BB:CC:DD:EE:FF")
        #expect(restored.lastAutoBackupDate == date(1753790000000))
    }

    @Test("a file the Android app actually wrote restores here")
    func realAndroidFileRestores() async throws {
        // Real output from Android's BackupRepository encoder, not a hand-written
        // fixture — the end-to-end proof that a backup moves between platforms.
        // Under format 1 this file failed outright: its numeric dates could not be
        // decoded by an ISO 8601 date strategy, so the whole restore was rejected.
        let url = try #require(
            Bundle.module.url(forResource: "Fixtures/backup-v2-from-android", withExtension: "json")
        )
        let (repo, context, prefs) = makeRepository()
        try await repo.restore(from: try Data(contentsOf: url))

        let trip = try #require(try context.fetch(FetchDescriptor<TripEntity>()).first)
        #expect(trip.id == "android-trip-1")
        #expect(trip.startTime == date(1753840000000))
        #expect(trip.endTime == date(1753843600000))
        #expect(trip.distanceKm == 128.5)
        #expect(trip.note == "Written by Android")
        #expect(trip.aiBriefing == "Android briefing")

        #expect(try context.fetch(FetchDescriptor<SampleEntity>()).first?.timestamp == date(1753840000000))
        #expect(try context.fetch(FetchDescriptor<ChargeSessionEntity>()).first?.id == "android-session-1")
        // Android's `savedPlans` land in the local SavedTripEntity table.
        #expect(try context.fetch(FetchDescriptor<SavedTripEntity>()).first?.id == "android-plan-1")
        #expect(try context.fetch(FetchDescriptor<SavedPlaceEntity>()).first?.id == "android-place-1")

        let p = prefs.current
        #expect(p.unitSystem == .imperial)
        #expect(p.themeMode == .dark)
        #expect(p.geminiApiKey == "gemini-from-android")
        #expect(p.deepseekApiKey == "deepseek-from-android")
        #expect(p.aiProvider == .deepseek)
        #expect(p.customUsableBatteryKwh == 74.5)
        #expect(p.customVehicleName == "My Ioniq")
        #expect(p.connectorTypes == [.ccs2, .type2])
        #expect(p.lastAutoBackupDate == date(1753790000000))
    }

    // MARK: - Round trip

    @Test("export then restore preserves trips and settings")
    func roundTrip() async throws {
        var prefs = UserPreferences()
        prefs.unitSystem = .imperial
        prefs.geminiApiKey = "keep-me"
        prefs.deepseekApiKey = "keep-me-too"
        prefs.aiProvider = .deepseek
        prefs.customUsableBatteryKwh = 74.5

        let (repo, context, _) = makeRepository(prefs: prefs)
        let start = date(1753840000000)
        context.insert(TripEntity(
            id: "trip-rt", startTime: start, endTime: start.addingTimeInterval(3600),
            startSoc: 80, endSoc: 60, distanceKm: 90, energyUsedKwh: 15,
            note: "note", aiBriefing: "briefing"
        ))
        try context.save()

        let data = try repo.export(preferences: prefs)

        // Restore into a *different* store, so nothing survives by accident.
        let (freshRepo, freshContext, freshPrefs) = makeRepository()
        try await freshRepo.restore(from: data)

        let trip = try #require(try freshContext.fetch(FetchDescriptor<TripEntity>()).first)
        #expect(trip.id == "trip-rt")
        #expect(trip.startTime == start)
        #expect(trip.aiBriefing == "briefing")

        #expect(freshPrefs.current.unitSystem == .imperial)
        #expect(freshPrefs.current.geminiApiKey == "keep-me")
        #expect(freshPrefs.current.deepseekApiKey == "keep-me-too")
        #expect(freshPrefs.current.aiProvider == .deepseek)
        #expect(freshPrefs.current.customUsableBatteryKwh == 74.5)
    }

    @Test("exported files declare format 2 with millisecond dates")
    func exportShape() throws {
        let (repo, context, _) = makeRepository()
        context.insert(TripEntity(id: "t", startTime: date(1753840000000)))
        try context.save()

        let json = try JSONSerialization.jsonObject(
            with: try repo.export(preferences: UserPreferences())
        ) as? [String: Any]
        let root = try #require(json)

        #expect(root["formatVersion"] as? Int == 2)
        #expect(root["version"] == nil, "the format 1 key must not be written")
        #expect(root["savedPlans"] != nil)
        #expect(root["savedTrips"] == nil, "the format 1 key must not be written")
        #expect(root["exportedAt"] is NSNumber, "dates are epoch millis, not strings")

        let trips = try #require(root["trips"] as? [[String: Any]])
        #expect(trips.first?["startTime"] as? Int64 == 1753840000000)
    }

    // MARK: - Format 1 compatibility

    @Test("an iOS format 1 file still restores, ISO dates and all")
    func legacyIosFormatReadable() async throws {
        let legacy = """
        {
          "version": 1,
          "exportedAt": "2026-07-30T04:00:00Z",
          "trips": [{
            "id": "legacy-trip",
            "startTime": "2026-07-30T02:00:00Z",
            "endTime": "2026-07-30T03:00:00Z",
            "startSoc": 80, "endSoc": 60,
            "distanceKm": 90, "energyUsedKwh": 15
          }],
          "samples": [],
          "chargeSessions": [],
          "savedTrips": [{
            "id": "legacy-plan", "name": "Old plan", "planJson": "{}",
            "createdAt": "2026-07-20T00:00:00Z"
          }],
          "savedPlaces": [],
          "settings": { "unitSystem": "IMPERIAL", "lastAutoBackupDate": 1753790000 }
        }
        """.data(using: .utf8)!

        let (repo, context, prefs) = makeRepository()
        let summary = try await repo.restore(from: legacy)
        #expect(summary.trips == 1)
        #expect(summary.savedTrips == 1, "format 1's savedTrips must map to savedPlans")

        let trip = try #require(try context.fetch(FetchDescriptor<TripEntity>()).first)
        #expect(trip.id == "legacy-trip")
        #expect(trip.startTime == ISO8601DateFormatter().date(from: "2026-07-30T02:00:00Z"))

        #expect(prefs.current.unitSystem == .imperial)
        // Format 1 wrote seconds; format 2 writes millis. Both land on the same date.
        #expect(prefs.current.lastAutoBackupDate == date(1753790000000))
    }

    @Test("an Android format 1 file restores — its dates were already millis")
    func legacyAndroidFormatReadable() async throws {
        let legacy = """
        {
          "formatVersion": 1,
          "exportedAt": 1753851600000,
          "trips": [{
            "id": "android-trip",
            "startTime": 1753840000000,
            "startSoc": 80,
            "distanceKm": 90, "energyUsedKwh": 15,
            "aiBriefing": "from android"
          }],
          "samples": [],
          "chargeSessions": [],
          "savedPlans": [],
          "savedPlaces": [],
          "settings": { "themeMode": "DARK", "autoBackupLastRunAt": 1753790000000 }
        }
        """.data(using: .utf8)!

        let (repo, context, prefs) = makeRepository()
        try await repo.restore(from: legacy)

        let trip = try #require(try context.fetch(FetchDescriptor<TripEntity>()).first)
        #expect(trip.id == "android-trip")
        #expect(trip.startTime == date(1753840000000))
        #expect(trip.aiBriefing == "from android")
        #expect(prefs.current.themeMode == .dark)
    }

    @Test("a file from a newer format is refused rather than half-read")
    func tooNewIsRefused() async throws {
        let future = #"{"formatVersion": 99, "trips": []}"#.data(using: .utf8)!
        let (repo, _, _) = makeRepository()
        await #expect(throws: BackupError.self) {
            try await repo.restore(from: future)
        }
    }

    // MARK: - Absent settings must not reset anything

    @Test("settings the backup omits keep their current values")
    func absentSettingsPreserved() async throws {
        var existing = UserPreferences()
        existing.geminiApiKey = "do-not-wipe"
        existing.deepseekApiKey = "do-not-wipe-either"
        existing.googleMapsApiKey = "keep"
        existing.unitSystem = .imperial
        existing.payloadMassKg = 120
        existing.reserveSocPercent = 18

        // A settings block carrying exactly one field, as an older build would write.
        let sparse = #"{"formatVersion": 2, "trips": [], "settings": {"themeMode": "LIGHT"}}"#
            .data(using: .utf8)!

        let (repo, _, prefs) = makeRepository(prefs: existing)
        try await repo.restore(from: sparse)

        #expect(prefs.current.themeMode == .light, "the one field present should apply")
        #expect(prefs.current.geminiApiKey == "do-not-wipe")
        #expect(prefs.current.deepseekApiKey == "do-not-wipe-either")
        #expect(prefs.current.googleMapsApiKey == "keep")
        #expect(prefs.current.unitSystem == .imperial)
        #expect(prefs.current.payloadMassKg == 120)
        #expect(prefs.current.reserveSocPercent == 18)
    }

    @Test("a backup with no settings block leaves preferences untouched")
    func missingSettingsBlockPreserved() async throws {
        var existing = UserPreferences()
        existing.geminiApiKey = "survives"
        existing.unitSystem = .imperial

        let noSettings = #"{"formatVersion": 2, "trips": []}"#.data(using: .utf8)!
        let (repo, _, prefs) = makeRepository(prefs: existing)
        let summary = try await repo.restore(from: noSettings)

        #expect(!summary.settingsRestored)
        #expect(prefs.current.geminiApiKey == "survives")
        #expect(prefs.current.unitSystem == .imperial)
    }
}
