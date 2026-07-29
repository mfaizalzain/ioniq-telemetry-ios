import Combine
import CoreDomain
import Foundation
import SwiftData
import Testing
@testable import CoreData

// MARK: - Mock

/// In-memory mock PreferencesRepository for backup tests.
final class MockPreferencesRepository: PreferencesRepository, @unchecked Sendable {
    var current: UserPreferences
    private let _preferences: CurrentValueSubject<UserPreferences, Never>

    var preferences: AnyPublisher<UserPreferences, Never> {
        _preferences.eraseToAnyPublisher()
    }

    init(_ prefs: UserPreferences = UserPreferences()) {
        current = prefs
        _preferences = CurrentValueSubject(prefs)
    }

    func update(_ transform: @Sendable (UserPreferences) -> UserPreferences) async {
        let newValue = transform(current)
        current = newValue
        _preferences.value = newValue
    }
}

// MARK: - Suite

@Suite("BackupRepository")
struct BackupRepositoryTests {

    // MARK: - Helpers

    /// Creates an in-memory ModelContainer registered with all entity types.
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

    /// Creates a BackupRepository backed by an in-memory container.
    private func makeRepository(
        prefs: UserPreferences = UserPreferences()
    ) -> (BackupRepository, ModelContext, MockPreferencesRepository) {
        let container = makeContainer()
        let context = ModelContext(container)
        let mockPrefs = MockPreferencesRepository(prefs)
        let repo = BackupRepository(modelContext: context, preferences: mockPrefs)
        return (repo, context, mockPrefs)
    }

    private let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    // MARK: - 1. Export produces valid JSON

    @Test("export produces valid JSON with expected keys")
    func exportProducesValidJSON() throws {
        let (repo, _, mockPrefs) = makeRepository()

        let data = try repo.export(preferences: mockPrefs.current)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]

        #expect(json != nil)
        #expect(json?["version"] as? Int == BackupRepository.formatVersion)
        #expect(json?["exportedAt"] is String) // ISO 8601 date string
        #expect(json?["trips"] is [Any])
        #expect(json?["samples"] is [Any])
        #expect(json?["chargeSessions"] is [Any])
        #expect(json?["savedTrips"] is [Any])
        #expect(json?["savedPlaces"] is [Any])
    }

    @Test("export JSON has settings key with preferences")
    func exportIncludesSettings() throws {
        var prefs = UserPreferences()
        prefs.customVehicleName = "Blue Ioniq 5"
        prefs.unitSystem = .imperial
        let (repo, _, mockPrefs) = makeRepository(prefs: prefs)

        let data = try repo.export(preferences: mockPrefs.current)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let settings = json?["settings"] as? [String: Any]

        #expect(settings != nil)
        #expect(settings?["customVehicleName"] as? String == "Blue Ioniq 5")
        #expect(settings?["unitSystem"] as? String == "IMPERIAL")
    }

    // MARK: - 2. Import restores data

    @Test("import restores trips, charges, saved trips and saved places into fresh context")
    func importRestoresData() async throws {
        let (repo, context, mockPrefs) = makeRepository()
        let start = Date()

        let trip = TripEntity(id: "trip-1", startTime: start, startSoc: 80, distanceKm: 100, energyUsedKwh: 15)
        context.insert(trip)

        let charge = ChargeSessionEntity(id: "charge-1", startTime: start, startSoc: 20, endSoc: 80, energyAddedKwh: 40)
        context.insert(charge)

        let savedTrip = SavedTripEntity(id: "st-1", name: "Work", planJson: "{}", createdAt: start)
        context.insert(savedTrip)

        let savedPlace = SavedPlaceEntity(id: "sp-1", name: "Home", lat: 37.33, lon: -122.01)
        context.insert(savedPlace)

        try context.save()

        let data = try repo.export(preferences: mockPrefs.current)

        // Fresh context
        let freshContext = ModelContext(makeContainer())
        let freshRepo = BackupRepository(modelContext: freshContext, preferences: MockPreferencesRepository())
        let summary = try await freshRepo.restore(from: data)

        #expect(summary.trips == 1)
        #expect(summary.chargeSessions == 1)
        #expect(summary.savedTrips == 1)
        #expect(summary.savedPlaces == 1)
        #expect(summary.samples == 0)
        #expect(summary.settingsRestored == true)

        let trips = try freshContext.fetch(FetchDescriptor<TripEntity>())
        #expect(trips.count == 1)
        #expect(trips[0].id == "trip-1")

        let charges = try freshContext.fetch(FetchDescriptor<ChargeSessionEntity>())
        #expect(charges.count == 1)
        #expect(charges[0].id == "charge-1")
    }

    // MARK: - 3. exportToPersistentFile creates file on disk

    @Test("exportToPersistentFile creates a JSON file with correct naming")
    func exportToPersistentFileCreatesFile() throws {
        let (repo, _, mockPrefs) = makeRepository()

        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("backup-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let fileURL = try repo.exportToPersistentFile(preferences: mockPrefs.current, directory: tempDir)

        #expect(FileManager.default.fileExists(atPath: fileURL.path))
        #expect(fileURL.pathExtension == "json")
        #expect(fileURL.lastPathComponent.hasPrefix("ioniq-telemetry-auto-"))

        // Verify valid JSON
        let data = try Data(contentsOf: fileURL)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(json != nil)
        #expect(json?["version"] as? Int == BackupRepository.formatVersion)
    }

    // MARK: - 4. Pruning

    @Test("exportToPersistentFile prunes old backups keeping at most 5")
    func exportPrunesOldBackups() throws {
        let (repo, _, mockPrefs) = makeRepository()

        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("prune-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tempDir) }
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        let fmt = DateFormatter()
        fmt.dateFormat = "yyyyMMdd-HHmmss"

        // Create 6 stale backup files dated in the past
        for i in 0 ..< 6 {
            let date = Calendar.current.date(byAdding: .day, value: -(10 + i), to: Date())!
            let name = "ioniq-telemetry-auto-\(fmt.string(from: date)).json"
            let url = tempDir.appendingPathComponent(name)
            try Data("{\"stale\":true}".utf8).write(to: url)
            try FileManager.default.setAttributes([.creationDate: date], ofItemAtPath: url.path)
        }

        // Export a new backup — triggers pruning
        _ = try repo.exportToPersistentFile(preferences: mockPrefs.current, directory: tempDir)

        let contents = try FileManager.default.contentsOfDirectory(
            at: tempDir, includingPropertiesForKeys: nil
        )
        let backups = contents.filter {
            $0.lastPathComponent.hasPrefix("ioniq-telemetry-auto-") && $0.pathExtension == "json"
        }
        #expect(backups.count == 5, "Expected 5 backups after pruning, got \(backups.count)")
    }

    // MARK: - 5. AutoBackupFrequency scheduling intervals

    @Test("AutoBackupFrequency.daily has 24-hour interval")
    func dailyInterval() {
        #expect(AutoBackupFrequency.daily.schedulingInterval == 86_400)
    }

    @Test("AutoBackupFrequency.weekly has 7-day interval")
    func weeklyInterval() {
        #expect(AutoBackupFrequency.weekly.schedulingInterval == 604_800)
    }

    @Test("AutoBackupFrequency.monthly has 30-day interval")
    func monthlyInterval() {
        #expect(AutoBackupFrequency.monthly.schedulingInterval == 2_592_000)
    }

    @Test("AutoBackupFrequency labels match display text")
    func frequencyLabels() {
        #expect(AutoBackupFrequency.daily.label == "Daily")
        #expect(AutoBackupFrequency.weekly.label == "Weekly")
        #expect(AutoBackupFrequency.monthly.label == "Monthly")
    }

    @Test("AutoBackupFrequency is CaseIterable")
    func frequencyCaseIterable() {
        #expect(AutoBackupFrequency.allCases == [.daily, .weekly, .monthly])
    }

    // MARK: - 6. BackupSettings includes auto-backup fields

    @Test("export includes autoBackupEnabled and autoBackupFrequency in settings")
    func exportIncludesAutoBackupSettings() throws {
        var prefs = UserPreferences()
        prefs.autoBackupEnabled = true
        prefs.autoBackupFrequency = .daily
        let (repo, _, mockPrefs) = makeRepository(prefs: prefs)

        let data = try repo.export(preferences: mockPrefs.current)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let settings = json?["settings"] as? [String: Any]

        #expect(settings?["autoBackupEnabled"] as? Bool == true)
        #expect(settings?["autoBackupFrequency"] as? String == "DAILY")
    }

    @Test("export includes lastAutoBackupDate when set")
    func exportIncludesLastAutoBackupDate() throws {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        var prefs = UserPreferences()
        prefs.autoBackupEnabled = true
        prefs.lastAutoBackupDate = date
        let (repo, _, mockPrefs) = makeRepository(prefs: prefs)

        let data = try repo.export(preferences: mockPrefs.current)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let settings = json?["settings"] as? [String: Any]

        #expect(settings?["autoBackupEnabled"] as? Bool == true)
        #expect(settings?["lastAutoBackupDate"] as? TimeInterval == 1_700_000_000)
    }

    @Test("restoring auto-backup settings applies them via PreferencesRepository.update")
    func restoreAppliesAutoBackupSettings() async throws {
        var prefs = UserPreferences()
        prefs.autoBackupEnabled = true
        prefs.autoBackupFrequency = .monthly
        let (repo, _, mockPrefs) = makeRepository(prefs: prefs)

        let data = try repo.export(preferences: mockPrefs.current)

        let freshContext = ModelContext(makeContainer())
        let freshMock = MockPreferencesRepository()
        let freshRepo = BackupRepository(modelContext: freshContext, preferences: freshMock)

        let summary = try await freshRepo.restore(from: data)
        #expect(summary.settingsRestored == true)
        #expect(freshMock.current.autoBackupEnabled == true)
        #expect(freshMock.current.autoBackupFrequency == .monthly)
    }

    // MARK: - 7. Round-trip preserves data

    @Test("full round-trip preserves all field values")
    func roundTripPreservesAllFields() async throws {
        let (repo, context, mockPrefs) = makeRepository()
        let start = Date()

        // Trip with all fields filled
        let trip = TripEntity(
            id: "rt-trip-1",
            startTime: start,
            endTime: start.addingTimeInterval(3600),
            startSoc: 80,
            endSoc: 45,
            distanceKm: 120.5,
            energyUsedKwh: 18.3,
            avgConsumptionKwhPer100km: 15.2,
            ambientTempAvgC: 22.5,
            note: "Highway trip"
        )
        context.insert(trip)

        // Sample
        let sample = SampleEntity(
            tripId: "rt-trip-1",
            timestamp: start.addingTimeInterval(300),
            soc: 75,
            powerKw: 50,
            speedKph: 100,
            lat: 37.33,
            lon: -122.01,
            elevationM: 10,
            ambientTempC: 22,
            packTempC: 28
        )
        context.insert(sample)

        // Charge session
        let charge = ChargeSessionEntity(
            id: "rt-charge-1",
            startTime: start.addingTimeInterval(7200),
            endTime: start.addingTimeInterval(9000),
            startSoc: 10,
            endSoc: 80,
            energyAddedKwh: 50,
            peakPowerKw: 220,
            avgPowerKw: 180,
            chargeType: "DC",
            packTempStartC: 25,
            chargerId: "charger-abc"
        )
        context.insert(charge)

        // Saved trip
        let savedTrip = SavedTripEntity(
            id: "rt-st-1", name: "Mountain Run",
            planJson: "{\"waypoints\":[]}", createdAt: start
        )
        context.insert(savedTrip)

        // Saved place
        let savedPlace = SavedPlaceEntity(
            id: "rt-sp-1", name: "Office", category: "WORK",
            lat: 37.77, lon: -122.41
        )
        context.insert(savedPlace)

        try context.save()

        // Export
        let data = try repo.export(preferences: mockPrefs.current)

        // Fresh context for import
        let freshContext = ModelContext(makeContainer())
        let freshMock = MockPreferencesRepository()
        let freshRepo = BackupRepository(modelContext: freshContext, preferences: freshMock)

        let summary = try await freshRepo.restore(from: data)

        #expect(summary.trips == 1)
        #expect(summary.samples == 1)
        #expect(summary.chargeSessions == 1)
        #expect(summary.savedTrips == 1)
        #expect(summary.savedPlaces == 1)
        #expect(summary.settingsRestored == true)

        // Verify trip fields
        let trips = try freshContext.fetch(FetchDescriptor<TripEntity>())
        #expect(trips[0].id == "rt-trip-1")
        #expect(trips[0].startSoc == 80)
        #expect(trips[0].endSoc == 45)
        #expect(trips[0].distanceKm == 120.5)
        #expect(trips[0].energyUsedKwh == 18.3)
        #expect(trips[0].avgConsumptionKwhPer100km == 15.2)
        #expect(trips[0].ambientTempAvgC == 22.5)
        #expect(trips[0].note == "Highway trip")

        // Verify sample fields
        let samples = try freshContext.fetch(FetchDescriptor<SampleEntity>())
        #expect(samples[0].tripId == "rt-trip-1")
        #expect(samples[0].soc == 75)
        #expect(samples[0].powerKw == 50)
        #expect(samples[0].speedKph == 100)
        #expect(samples[0].lat == 37.33)
        #expect(samples[0].lon == -122.01)
        #expect(samples[0].elevationM == 10)
        #expect(samples[0].ambientTempC == 22)
        #expect(samples[0].packTempC == 28)

        // Verify charge session fields
        let charges = try freshContext.fetch(FetchDescriptor<ChargeSessionEntity>())
        #expect(charges[0].id == "rt-charge-1")
        #expect(charges[0].startSoc == 10)
        #expect(charges[0].endSoc == 80)
        #expect(charges[0].energyAddedKwh == 50)
        #expect(charges[0].peakPowerKw == 220)
        #expect(charges[0].avgPowerKw == 180)
        #expect(charges[0].chargeType == "DC")
        #expect(charges[0].packTempStartC == 25)
        #expect(charges[0].chargerId == "charger-abc")

        // Verify saved trip fields
        let savedTrips = try freshContext.fetch(FetchDescriptor<SavedTripEntity>())
        #expect(savedTrips[0].name == "Mountain Run")

        // Verify saved place fields
        let savedPlaces = try freshContext.fetch(FetchDescriptor<SavedPlaceEntity>())
        #expect(savedPlaces[0].name == "Office")
        #expect(savedPlaces[0].category == "WORK")
        #expect(savedPlaces[0].lat == 37.77)
        #expect(savedPlaces[0].lon == -122.41)
    }

    // MARK: - Error handling

    @Test("restore throws BackupError when version is too new")
    func importFailsForTooNewVersion() async throws {
        let freshContext = ModelContext(makeContainer())
        let freshRepo = BackupRepository(
            modelContext: freshContext,
            preferences: MockPreferencesRepository()
        )

        let jsonDict: [String: Any] = [
            "version": 999,
            "exportedAt": isoFormatter.string(from: Date()),
            "trips": [], "samples": [], "chargeSessions": [],
            "savedTrips": [], "savedPlaces": [],
        ]
        let data = try JSONSerialization.data(withJSONObject: jsonDict)

        do {
            try await freshRepo.restore(from: data)
            #expect(Bool(false), "Expected BackupError.tooNew to be thrown")
        } catch let error as BackupError {
            // Can't pattern-match on associated values with #expect(throws:)
            // so check the description
            #expect(error.errorDescription?.contains("newer version") == true)
        }
    }

    @Test("restore throws BackupError for invalid JSON")
    func importFailsForInvalidJSON() async throws {
        let freshContext = ModelContext(makeContainer())
        let freshRepo = BackupRepository(
            modelContext: freshContext,
            preferences: MockPreferencesRepository()
        )

        let badData = Data("not valid json".utf8)

        do {
            try await freshRepo.restore(from: badData)
            #expect(Bool(false), "Expected BackupError.unreadable to be thrown")
        } catch let error as BackupError {
            #expect(error.errorDescription?.contains("isn't a readable") == true)
        }
    }

    // MARK: - Settings restore edge cases

    @Test("import does not restore settings when backup has no settings key")
    func importWithoutSettingsPreservesDefaults() async throws {
        let (repo, context, mockPrefs) = makeRepository()
        // Insert a trip so export produces something
        let trip = TripEntity(id: "no-settings-trip", startTime: Date(), startSoc: 50, distanceKm: 10, energyUsedKwh: 2)
        context.insert(trip)
        try context.save()

        let data = try repo.export(preferences: mockPrefs.current)

        // Strip the settings key from the JSON
        var json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        json.removeValue(forKey: "settings")
        let stripped = try JSONSerialization.data(withJSONObject: json)

        let freshContext = ModelContext(makeContainer())
        let freshMock = MockPreferencesRepository()
        let freshRepo = BackupRepository(modelContext: freshContext, preferences: freshMock)

        let summary = try await freshRepo.restore(from: stripped)
        #expect(summary.settingsRestored == false)
    }
}
