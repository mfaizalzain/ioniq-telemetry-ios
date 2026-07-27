import CoreDomain
import Foundation
import SwiftData

/// JSON export/import of everything the user would lose with the app.
///
/// The format is versioned and decoded field-by-field with defaults, so a backup
/// taken by an older build still restores after the schema moves on — a backup
/// that only restores into the exact build that wrote it is not a backup.
public final class BackupRepository: @unchecked Sendable {

    /// Bump when a change can't be absorbed by the tolerant decoding below.
    public static let formatVersion = 1

    private let modelContext: ModelContext
    private let preferences: PreferencesRepository

    public init(modelContext: ModelContext, preferences: PreferencesRepository) {
        self.modelContext = modelContext
        self.preferences = preferences
    }

    // MARK: - Export

    public func export(preferences prefs: UserPreferences) throws -> Data {
        let backup = Backup(
            version: Self.formatVersion,
            exportedAt: Date(),
            settings: BackupSettings(prefs),
            trips: try modelContext.fetch(FetchDescriptor<TripEntity>()).map(BackupTrip.init),
            samples: try modelContext.fetch(FetchDescriptor<SampleEntity>()).map(BackupSample.init),
            chargeSessions: try modelContext.fetch(FetchDescriptor<ChargeSessionEntity>())
                .map(BackupChargeSession.init),
            savedTrips: try modelContext.fetch(FetchDescriptor<SavedTripEntity>()).map(BackupSavedTrip.init),
            savedPlaces: try modelContext.fetch(FetchDescriptor<SavedPlaceEntity>()).map(BackupSavedPlace.init)
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(backup)
    }

    public static func suggestedFilename(now: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HHmm"
        return "ioniq-telemetry-backup-\(formatter.string(from: now)).json"
    }

    // MARK: - Import

    public struct ImportSummary: Sendable, Equatable {
        public let trips: Int
        public let samples: Int
        public let chargeSessions: Int
        public let savedTrips: Int
        public let savedPlaces: Int
        public let settingsRestored: Bool
    }

    /// Restores a backup, skipping anything already present by id so re-importing
    /// the same file is harmless rather than producing duplicates.
    @discardableResult
    public func restore(from data: Data) async throws -> ImportSummary {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let backup: Backup
        do {
            backup = try decoder.decode(Backup.self, from: data)
        } catch {
            throw BackupError.unreadable(error)
        }

        guard backup.version <= Self.formatVersion else {
            throw BackupError.tooNew(backup.version)
        }

        let existingTrips = Set(try modelContext.fetch(FetchDescriptor<TripEntity>()).map(\.id))
        var insertedTrips = 0
        for trip in backup.trips where !existingTrips.contains(trip.id) {
            modelContext.insert(trip.entity)
            insertedTrips += 1
        }

        // Samples carry no id of their own; dedupe on (tripId, timestamp), which is
        // unique because the logger writes at most one sample per second per trip.
        let existingSamples = Set(
            try modelContext.fetch(FetchDescriptor<SampleEntity>())
                .map { SampleKey(tripId: $0.tripId, timestamp: $0.timestamp) }
        )
        var insertedSamples = 0
        for sample in backup.samples
        where !existingSamples.contains(SampleKey(tripId: sample.tripId, timestamp: sample.timestamp)) {
            modelContext.insert(sample.entity)
            insertedSamples += 1
        }

        let existingSessions = Set(
            try modelContext.fetch(FetchDescriptor<ChargeSessionEntity>()).map(\.id)
        )
        var insertedSessions = 0
        for session in backup.chargeSessions where !existingSessions.contains(session.id) {
            modelContext.insert(session.entity)
            insertedSessions += 1
        }

        let existingSavedTrips = Set(try modelContext.fetch(FetchDescriptor<SavedTripEntity>()).map(\.id))
        var insertedSavedTrips = 0
        for saved in backup.savedTrips where !existingSavedTrips.contains(saved.id) {
            modelContext.insert(saved.entity)
            insertedSavedTrips += 1
        }

        let existingPlaces = Set(try modelContext.fetch(FetchDescriptor<SavedPlaceEntity>()).map(\.id))
        var insertedPlaces = 0
        for place in backup.savedPlaces where !existingPlaces.contains(place.id) {
            modelContext.insert(place.entity)
            insertedPlaces += 1
        }

        try modelContext.save()

        var settingsRestored = false
        if let settings = backup.settings {
            await preferences.update { settings.applied(to: $0) }
            settingsRestored = true
        }

        return ImportSummary(
            trips: insertedTrips,
            samples: insertedSamples,
            chargeSessions: insertedSessions,
            savedTrips: insertedSavedTrips,
            savedPlaces: insertedPlaces,
            settingsRestored: settingsRestored
        )
    }

    private struct SampleKey: Hashable {
        let tripId: String
        let timestamp: Date
    }
}

// MARK: - Errors

public enum BackupError: LocalizedError {
    case unreadable(any Error)
    case tooNew(Int)

    public var errorDescription: String? {
        switch self {
        case .unreadable:
            return "That file isn't a readable Ioniq Telemetry backup."
        case .tooNew(let version):
            return "This backup was written by a newer version of the app (format \(version))."
        }
    }
}

// MARK: - Wire format

private struct Backup: Codable {
    let version: Int
    let exportedAt: Date
    let settings: BackupSettings?
    let trips: [BackupTrip]
    let samples: [BackupSample]
    let chargeSessions: [BackupChargeSession]
    let savedTrips: [BackupSavedTrip]
    let savedPlaces: [BackupSavedPlace]

    // Every collection defaults to empty: a backup from a build that predates a
    // table must still restore the tables it does have.
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        exportedAt = try c.decodeIfPresent(Date.self, forKey: .exportedAt) ?? Date()
        settings = try c.decodeIfPresent(BackupSettings.self, forKey: .settings)
        trips = try c.decodeIfPresent([BackupTrip].self, forKey: .trips) ?? []
        samples = try c.decodeIfPresent([BackupSample].self, forKey: .samples) ?? []
        chargeSessions = try c.decodeIfPresent([BackupChargeSession].self, forKey: .chargeSessions) ?? []
        savedTrips = try c.decodeIfPresent([BackupSavedTrip].self, forKey: .savedTrips) ?? []
        savedPlaces = try c.decodeIfPresent([BackupSavedPlace].self, forKey: .savedPlaces) ?? []
    }

    init(
        version: Int,
        exportedAt: Date,
        settings: BackupSettings?,
        trips: [BackupTrip],
        samples: [BackupSample],
        chargeSessions: [BackupChargeSession],
        savedTrips: [BackupSavedTrip],
        savedPlaces: [BackupSavedPlace]
    ) {
        self.version = version
        self.exportedAt = exportedAt
        self.settings = settings
        self.trips = trips
        self.samples = samples
        self.chargeSessions = chargeSessions
        self.savedTrips = savedTrips
        self.savedPlaces = savedPlaces
    }
}

/// The subset of preferences worth carrying between installs. API keys are
/// included — they are the user's own credentials and losing them on restore is
/// the most annoying possible outcome — so the file must be treated as sensitive.
private struct BackupSettings: Codable {
    var activeProfileId: String?
    var customUsableBatteryKwh: Float?
    var customVehicleName: String?
    var unitSystem: String?
    var themeMode: String?
    var reserveSocPercent: Float?
    var targetArrivalSocPercent: Float?
    var payloadMassKg: Float?
    var priceWeight: Float?
    var routingProvider: String?
    var googleMapsApiKey: String?
    var orsApiKey: String?
    var geminiApiKey: String?
    var aiCoachingEnabled: Bool?
    var chargerOccupancyAlerts: Bool?
    var googlePoiSearch: Bool?
    var chargerSource: String?
    var estimatedSohPercent: Float?
    var estimatedSohTimestamp: Int64?

    init(_ prefs: UserPreferences) {
        activeProfileId = prefs.activeProfileId
        customUsableBatteryKwh = prefs.customUsableBatteryKwh
        customVehicleName = prefs.customVehicleName
        unitSystem = prefs.unitSystem.rawValue
        themeMode = prefs.themeMode.rawValue
        reserveSocPercent = prefs.reserveSocPercent
        targetArrivalSocPercent = prefs.targetArrivalSocPercent
        payloadMassKg = prefs.payloadMassKg
        priceWeight = prefs.priceWeight
        routingProvider = prefs.routingProvider.rawValue
        googleMapsApiKey = prefs.googleMapsApiKey
        orsApiKey = prefs.orsApiKey
        geminiApiKey = prefs.geminiApiKey
        aiCoachingEnabled = prefs.aiCoachingEnabled
        chargerOccupancyAlerts = prefs.chargerOccupancyAlerts
        googlePoiSearch = prefs.googlePoiSearch
        chargerSource = prefs.chargerSource.rawValue
        estimatedSohPercent = prefs.estimatedSohPercent
        estimatedSohTimestamp = prefs.estimatedSohTimestamp
    }

    /// Absent fields keep whatever is currently set rather than resetting to
    /// defaults — a partial backup must not wipe unrelated settings.
    func applied(to current: UserPreferences) -> UserPreferences {
        var next = current
        if let activeProfileId { next.activeProfileId = activeProfileId }
        next.customUsableBatteryKwh = customUsableBatteryKwh ?? current.customUsableBatteryKwh
        next.customVehicleName = customVehicleName ?? current.customVehicleName
        if let unitSystem, let value = UnitSystem(rawValue: unitSystem) { next.unitSystem = value }
        if let themeMode, let value = ThemeMode(rawValue: themeMode) { next.themeMode = value }
        if let reserveSocPercent { next.reserveSocPercent = reserveSocPercent }
        if let targetArrivalSocPercent { next.targetArrivalSocPercent = targetArrivalSocPercent }
        if let payloadMassKg { next.payloadMassKg = payloadMassKg }
        if let priceWeight { next.priceWeight = priceWeight }
        if let routingProvider, let value = RoutingProvider(rawValue: routingProvider) {
            next.routingProvider = value
        }
        next.googleMapsApiKey = googleMapsApiKey ?? current.googleMapsApiKey
        next.orsApiKey = orsApiKey ?? current.orsApiKey
        next.geminiApiKey = geminiApiKey ?? current.geminiApiKey
        if let aiCoachingEnabled { next.aiCoachingEnabled = aiCoachingEnabled }
        if let chargerOccupancyAlerts { next.chargerOccupancyAlerts = chargerOccupancyAlerts }
        if let googlePoiSearch { next.googlePoiSearch = googlePoiSearch }
        if let chargerSource, let value = ChargerSource(rawValue: chargerSource) {
            next.chargerSource = value
        }
        next.estimatedSohPercent = estimatedSohPercent ?? current.estimatedSohPercent
        if let estimatedSohTimestamp { next.estimatedSohTimestamp = estimatedSohTimestamp }
        return next
    }
}

private struct BackupTrip: Codable {
    let id: String
    let startTime: Date
    let endTime: Date?
    let startSoc: Float
    let endSoc: Float?
    let distanceKm: Float
    let energyUsedKwh: Float
    let avgConsumptionKwhPer100km: Float?
    let ambientTempAvgC: Float?
    let note: String?

    init(_ e: TripEntity) {
        id = e.id
        startTime = e.startTime
        endTime = e.endTime
        startSoc = e.startSoc
        endSoc = e.endSoc
        distanceKm = e.distanceKm
        energyUsedKwh = e.energyUsedKwh
        avgConsumptionKwhPer100km = e.avgConsumptionKwhPer100km
        ambientTempAvgC = e.ambientTempAvgC
        note = e.note
    }

    var entity: TripEntity {
        TripEntity(
            id: id, startTime: startTime, endTime: endTime,
            startSoc: startSoc, endSoc: endSoc,
            distanceKm: distanceKm, energyUsedKwh: energyUsedKwh,
            avgConsumptionKwhPer100km: avgConsumptionKwhPer100km,
            ambientTempAvgC: ambientTempAvgC, note: note
        )
    }
}

private struct BackupSample: Codable {
    let tripId: String
    let timestamp: Date
    let soc: Float?
    let powerKw: Float?
    let speedKph: Float?
    let lat: Double?
    let lon: Double?
    let elevationM: Float?
    let ambientTempC: Float?
    let packTempC: Float?

    init(_ e: SampleEntity) {
        tripId = e.tripId
        timestamp = e.timestamp
        soc = e.soc
        powerKw = e.powerKw
        speedKph = e.speedKph
        lat = e.lat
        lon = e.lon
        elevationM = e.elevationM
        ambientTempC = e.ambientTempC
        packTempC = e.packTempC
    }

    var entity: SampleEntity {
        SampleEntity(
            tripId: tripId, timestamp: timestamp, soc: soc, powerKw: powerKw,
            speedKph: speedKph, lat: lat, lon: lon, elevationM: elevationM,
            ambientTempC: ambientTempC, packTempC: packTempC
        )
    }
}

private struct BackupChargeSession: Codable {
    let id: String
    let startTime: Date
    let endTime: Date?
    let startSoc: Float
    let endSoc: Float?
    let energyAddedKwh: Float
    let peakPowerKw: Float
    let avgPowerKw: Float
    let chargeType: String
    let packTempStartC: Float?
    let chargerId: String?

    init(_ e: ChargeSessionEntity) {
        id = e.id
        startTime = e.startTime
        endTime = e.endTime
        startSoc = e.startSoc
        endSoc = e.endSoc
        energyAddedKwh = e.energyAddedKwh
        peakPowerKw = e.peakPowerKw
        avgPowerKw = e.avgPowerKw
        chargeType = e.chargeType
        packTempStartC = e.packTempStartC
        chargerId = e.chargerId
    }

    var entity: ChargeSessionEntity {
        ChargeSessionEntity(
            id: id, startTime: startTime, endTime: endTime,
            startSoc: startSoc, endSoc: endSoc,
            energyAddedKwh: energyAddedKwh, peakPowerKw: peakPowerKw,
            avgPowerKw: avgPowerKw, chargeType: chargeType,
            packTempStartC: packTempStartC, chargerId: chargerId
        )
    }
}

private struct BackupSavedTrip: Codable {
    let id: String
    let name: String
    let planJson: String
    let createdAt: Date

    init(_ e: SavedTripEntity) {
        id = e.id
        name = e.name
        planJson = e.planJson
        createdAt = e.createdAt
    }

    var entity: SavedTripEntity {
        SavedTripEntity(id: id, name: name, planJson: planJson, createdAt: createdAt)
    }
}

private struct BackupSavedPlace: Codable {
    let id: String
    let name: String
    let category: String
    let lat: Double
    let lon: Double
    let createdAt: Date

    init(_ e: SavedPlaceEntity) {
        id = e.id
        name = e.name
        category = e.category
        lat = e.lat
        lon = e.lon
        createdAt = e.createdAt
    }

    var entity: SavedPlaceEntity {
        SavedPlaceEntity(id: id, name: name, category: category, lat: lat, lon: lon, createdAt: createdAt)
    }
}
