import CoreDomain
import Foundation
import SwiftData

/// JSON export/import of everything the user would lose with the app.
///
/// The format is versioned and decoded field-by-field with defaults, so a backup
/// taken by an older build still restores after the schema moves on — a backup
/// that only restores into the exact build that wrote it is not a backup.
///
/// Format 2 is shared with the Android build so a file moves between platforms.
/// Format 1 was not: iOS wrote `version`, ISO 8601 dates and `savedTrips` while
/// Android wrote `formatVersion`, epoch millis and `savedPlans`, so each side
/// silently mangled or rejected the other's file. Version 2 settles on Android's
/// spelling — millis are unambiguous and are what its database already stores —
/// and the readers below still accept every format 1 file from either platform.
public final class BackupRepository: @unchecked Sendable {

    /// Bump when a change can't be absorbed by the tolerant decoding below.
    public static let formatVersion = 2

    private let modelContext: ModelContext
    private let preferences: PreferencesRepository

    public init(modelContext: ModelContext, preferences: PreferencesRepository) {
        self.modelContext = modelContext
        self.preferences = preferences
    }

    // MARK: - Export

    public func export(preferences prefs: UserPreferences) throws -> Data {
        let backup = Backup(
            formatVersion: Self.formatVersion,
            exportedAt: Date(),
            settings: BackupSettings(prefs),
            trips: try modelContext.fetch(FetchDescriptor<TripEntity>()).map(BackupTrip.init),
            samples: try modelContext.fetch(FetchDescriptor<SampleEntity>()).map(BackupSample.init),
            chargeSessions: try modelContext.fetch(FetchDescriptor<ChargeSessionEntity>())
                .map(BackupChargeSession.init),
            savedPlans: try modelContext.fetch(FetchDescriptor<SavedTripEntity>()).map(BackupSavedPlan.init),
            savedPlaces: try modelContext.fetch(FetchDescriptor<SavedPlaceEntity>()).map(BackupSavedPlace.init)
        )

        // No date strategy: `WireDate` encodes epoch millis itself, so the shared
        // format does not depend on a coder-wide setting.
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(backup)
    }

    /// Exports a backup directly to a timestamped file in the given directory and
    /// prunes old backups there, keeping only the last 5.
    ///
    /// - Parameter directory: A writable directory URL (e.g. Documents/autobackup/).
    /// - Returns: The URL of the newly written file.
    public func exportToPersistentFile(preferences prefs: UserPreferences, directory: URL) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let data = try export(preferences: prefs)

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let filename = "ioniq-telemetry-auto-\(formatter.string(from: Date())).json"
        let fileURL = directory.appendingPathComponent(filename)
        try data.write(to: fileURL, options: .atomic)

        // Prune: keep last 5, delete the oldest ones.
        let contents = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.creationDateKey],
            options: .skipsHiddenFiles
        )
        let backupFiles = contents
            .filter { $0.lastPathComponent.hasPrefix("ioniq-telemetry-auto-") && $0.pathExtension == "json" }
            .sorted { lhs, rhs in
                let lhsDate = (try? lhs.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
                let rhsDate = (try? rhs.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
                return lhsDate > rhsDate
            }
        if backupFiles.count > 5 {
            for stale in backupFiles.dropFirst(5) {
                try? FileManager.default.removeItem(at: stale)
            }
        }

        return fileURL
    }

    /// Returns auto-backup files sorted newest-first.
    /// Files are in the auto-backup directory (Documents/autobackup/).
    public static func listAutoBackups(directory: URL) -> [AutoBackupFile] {
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
            options: .skipsHiddenFiles
        ) else { return [] }

        return contents
            .filter { $0.lastPathComponent.hasPrefix("ioniq-telemetry-auto-") && $0.pathExtension == "json" }
            .compactMap { url -> AutoBackupFile? in
                guard let attrs = try? fm.attributesOfItem(atPath: url.path) else { return nil }
                let name = url.lastPathComponent
                    .replacingOccurrences(of: "ioniq-telemetry-auto-", with: "")
                    .replacingOccurrences(of: ".json", with: "")
                return AutoBackupFile(
                    name: name,
                    url: url,
                    sizeBytes: (attrs[.size] as? Int64).flatMap(Int.init) ?? 0,
                    lastModified: (attrs[.modificationDate] as? Date) ?? .distantPast
                )
            }
            .sorted { $0.lastModified > $1.lastModified }
    }

    /// Copies an auto-backup file identified by its stamp name to the given URL.
    /// - Parameters:
    ///   - stamp: The timestamp portion of the auto-backup filename (e.g. "20250115-143022").
    ///   - destination: Where to write the copy (e.g. a temporary file for sharing).
    /// - Returns: `true` if the file was found and copied successfully.
    public static func exportAutoBackupFile(stamp: String, from directory: URL, to destination: URL) -> Bool {
        let source = directory.appendingPathComponent("ioniq-telemetry-auto-\(stamp).json")
        guard FileManager.default.fileExists(atPath: source.path) else { return false }
        do {
            try FileManager.default.copyItem(at: source, to: destination)
            return true
        } catch {
            return false
        }
    }

    /// A discovered auto-backup file on disk.
    public struct AutoBackupFile: Sendable, Identifiable {
        /// The timestamp portion of the filename (e.g. "20250115-143022").
        public let name: String
        /// The full file URL.
        public let url: URL
        /// File size in bytes.
        public let sizeBytes: Int
        /// When the file was last modified (the backup timestamp).
        public let lastModified: Date

        public var id: String { name }
    }

    public static func suggestedFilename(now: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HHmm"
        return "ioniq-telemetry-backup-\(formatter.string(from: now)).json"
    }

    // MARK: - Import

    /// Counts are what the file carried, not what happened to be new: restoring
    /// onto the device the backup came from is the common case, and reporting the
    /// zero rows it inserted reads as "nothing was restored".
    public struct ImportSummary: Sendable, Equatable {
        public let trips: Int
        public let samples: Int
        public let chargeSessions: Int
        public let savedTrips: Int
        public let savedPlaces: Int
        public let settingsRestored: Bool
    }

    /// Restores a backup, overwriting rows that share an id so re-importing the
    /// same file is idempotent rather than producing duplicates.
    @discardableResult
    public func restore(from data: Data) async throws -> ImportSummary {
        // No date strategy: `WireDate` accepts both epoch millis (format 2) and the
        // ISO 8601 strings iOS wrote for format 1.
        let decoder = JSONDecoder()
        let backup: Backup
        do {
            backup = try decoder.decode(Backup.self, from: data)
        } catch {
            throw BackupError.unreadable(error)
        }

        guard backup.formatVersion <= Self.formatVersion else {
            throw BackupError.tooNew(backup.formatVersion)
        }

        // `id` is a unique attribute on each of these, so inserting a row that is
        // already there replaces it instead of duplicating it.
        for trip in backup.trips {
            modelContext.insert(trip.entity)
        }
        for session in backup.chargeSessions {
            modelContext.insert(session.entity)
        }
        for saved in backup.savedPlans {
            modelContext.insert(saved.entity)
        }
        for place in backup.savedPlaces {
            modelContext.insert(place.entity)
        }

        // Samples carry no id of their own, so they can't upsert. Replace the whole
        // sample run of every trip the backup mentions: the file is the authority
        // for those trips, and anything else double-imports the run.
        let restoredTripIds = Set(backup.samples.map(\.tripId))
        for tripId in restoredTripIds {
            let existing = try modelContext.fetch(
                FetchDescriptor<SampleEntity>(predicate: #Predicate { $0.tripId == tripId })
            )
            for sample in existing {
                modelContext.delete(sample)
            }
        }
        for sample in backup.samples {
            modelContext.insert(sample.entity)
        }

        try modelContext.save()

        var settingsRestored = false
        if let settings = backup.settings {
            await preferences.update { settings.applied(to: $0) }
            settingsRestored = true
        }

        return ImportSummary(
            trips: backup.trips.count,
            samples: backup.samples.count,
            chargeSessions: backup.chargeSessions.count,
            savedTrips: backup.savedPlans.count,
            savedPlaces: backup.savedPlaces.count,
            settingsRestored: settingsRestored
        )
    }
}

// MARK: - Errors

public enum BackupError: LocalizedError {
    case unreadable(any Error)
    case tooNew(Int)

    public var errorDescription: String? {
        switch self {
        case .unreadable:
            return "That file isn't a readable IONIQ Telemetry backup."
        case .tooNew(let version):
            return "This backup was written by a newer version of the app (format \(version))."
        }
    }
}

// MARK: - Wire format

/// A timestamp on the wire.
///
/// Written as epoch milliseconds, which is what Android's database stores and what
/// format 2 standardises on. Read as either milliseconds or the ISO 8601 string
/// that iOS's format 1 produced, so no existing backup becomes unreadable — and so
/// an Android format 1 file, whose dates were already millis, reads too.
struct WireDate: Codable, Equatable, Sendable {
    let date: Date

    init(_ date: Date) { self.date = date }

    /// Built on demand rather than shared: only legacy format 1 files reach the
    /// string branch, and a shared formatter would be mutable global state.
    private static func parseISO8601(_ text: String) -> Date? {
        let plain = ISO8601DateFormatter()
        if let date = plain.date(from: text) { return date }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: text)
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()

        if let millis = try? container.decode(Int64.self) {
            date = Date(timeIntervalSince1970: Double(millis) / 1000)
            return
        }
        // A double covers millis that arrived with a decimal point.
        if let millis = try? container.decode(Double.self) {
            date = Date(timeIntervalSince1970: millis / 1000)
            return
        }

        let text = try container.decode(String.self)
        guard let parsed = Self.parseISO8601(text) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Expected epoch milliseconds or an ISO 8601 date, got \"\(text)\"."
            )
        }
        date = parsed
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(Int64((date.timeIntervalSince1970 * 1000).rounded()))
    }
}

private struct Backup: Codable {
    let formatVersion: Int
    let exportedAt: WireDate
    let settings: BackupSettings?
    let trips: [BackupTrip]
    let samples: [BackupSample]
    let chargeSessions: [BackupChargeSession]
    let savedPlans: [BackupSavedPlan]
    let savedPlaces: [BackupSavedPlace]

    enum CodingKeys: String, CodingKey {
        case formatVersion, exportedAt, settings, trips, samples, chargeSessions
        case savedPlans, savedPlaces
        /// Format 1 spellings, read but never written.
        case version, savedTrips
    }

    // Every collection defaults to empty: a backup from a build that predates a
    // table must still restore the tables it does have.
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        formatVersion = try c.decodeIfPresent(Int.self, forKey: .formatVersion)
            ?? c.decodeIfPresent(Int.self, forKey: .version)
            ?? 1
        exportedAt = try c.decodeIfPresent(WireDate.self, forKey: .exportedAt) ?? WireDate(Date())
        settings = try c.decodeIfPresent(BackupSettings.self, forKey: .settings)
        trips = try c.decodeIfPresent([BackupTrip].self, forKey: .trips) ?? []
        samples = try c.decodeIfPresent([BackupSample].self, forKey: .samples) ?? []
        chargeSessions = try c.decodeIfPresent([BackupChargeSession].self, forKey: .chargeSessions) ?? []
        // iOS format 1 called these `savedTrips`; the shared format uses Android's
        // `savedPlans`, which matches the `planJson` they actually carry.
        savedPlans = try c.decodeIfPresent([BackupSavedPlan].self, forKey: .savedPlans)
            ?? c.decodeIfPresent([BackupSavedPlan].self, forKey: .savedTrips)
            ?? []
        savedPlaces = try c.decodeIfPresent([BackupSavedPlace].self, forKey: .savedPlaces) ?? []
    }

    func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(formatVersion, forKey: .formatVersion)
        try c.encode(exportedAt, forKey: .exportedAt)
        try c.encodeIfPresent(settings, forKey: .settings)
        try c.encode(trips, forKey: .trips)
        try c.encode(samples, forKey: .samples)
        try c.encode(chargeSessions, forKey: .chargeSessions)
        try c.encode(savedPlans, forKey: .savedPlans)
        try c.encode(savedPlaces, forKey: .savedPlaces)
    }

    init(
        formatVersion: Int,
        exportedAt: Date,
        settings: BackupSettings?,
        trips: [BackupTrip],
        samples: [BackupSample],
        chargeSessions: [BackupChargeSession],
        savedPlans: [BackupSavedPlan],
        savedPlaces: [BackupSavedPlace]
    ) {
        self.formatVersion = formatVersion
        self.exportedAt = WireDate(exportedAt)
        self.settings = settings
        self.trips = trips
        self.samples = samples
        self.chargeSessions = chargeSessions
        self.savedPlans = savedPlans
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
    var aiFeaturesEnabled: Bool?
    var aiCoachingEnabled: Bool?
    var chargerOccupancyAlerts: Bool?
    var googlePoiSearch: Bool?
    var chargerSource: String?
    var estimatedSohPercent: Float?
    var estimatedSohTimestamp: Int64?
    var autoBackupEnabled: Bool?
    var autoBackupFrequency: String?
    /// Epoch milliseconds, spelled as Android spells it. Format 1 on iOS wrote
    /// `lastAutoBackupDate` in epoch *seconds*; that key is still read below.
    var autoBackupLastRunAt: Int64?
    var lastAutoBackupDate: TimeInterval?
    // ── Added in format 2: previously dropped by one platform or the other. ──
    var deepseekApiKey: String?
    var aiProvider: String?
    var openChargeMapApiKey: String?
    var connectorTypes: [String]?
    var dynamicColor: Bool?
    var lastObdDeviceAddress: String?
    var lastObdDeviceName: String?
    var lastObdTransportType: String?

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
        aiFeaturesEnabled = prefs.aiFeaturesEnabled
        aiCoachingEnabled = prefs.aiCoachingEnabled
        chargerOccupancyAlerts = prefs.chargerOccupancyAlerts
        googlePoiSearch = prefs.googlePoiSearch
        chargerSource = prefs.chargerSource.rawValue
        estimatedSohPercent = prefs.estimatedSohPercent
        estimatedSohTimestamp = prefs.estimatedSohTimestamp
        autoBackupEnabled = prefs.autoBackupEnabled
        autoBackupFrequency = prefs.autoBackupFrequency.rawValue
        autoBackupLastRunAt = prefs.lastAutoBackupDate
            .map { Int64(($0.timeIntervalSince1970 * 1000).rounded()) }
        lastAutoBackupDate = nil
        deepseekApiKey = prefs.deepseekApiKey
        aiProvider = prefs.aiProvider.rawValue
        openChargeMapApiKey = prefs.openChargeMapApiKey
        connectorTypes = prefs.connectorTypes.map(\.rawValue).sorted()
        dynamicColor = prefs.dynamicColor
        lastObdDeviceAddress = prefs.lastObdDeviceAddress
        lastObdDeviceName = prefs.lastObdDeviceName
        lastObdTransportType = prefs.lastObdTransportType
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
        if let aiFeaturesEnabled { next.aiFeaturesEnabled = aiFeaturesEnabled }
        if let aiCoachingEnabled { next.aiCoachingEnabled = aiCoachingEnabled }
        if let chargerOccupancyAlerts { next.chargerOccupancyAlerts = chargerOccupancyAlerts }
        if let googlePoiSearch { next.googlePoiSearch = googlePoiSearch }
        if let chargerSource, let value = ChargerSource(rawValue: chargerSource) {
            next.chargerSource = value
        }
        next.estimatedSohPercent = estimatedSohPercent ?? current.estimatedSohPercent
        if let estimatedSohTimestamp { next.estimatedSohTimestamp = estimatedSohTimestamp }
        if let autoBackupEnabled { next.autoBackupEnabled = autoBackupEnabled }
        if let autoBackupFrequency, let val = AutoBackupFrequency(rawValue: autoBackupFrequency) {
            next.autoBackupFrequency = val
        }
        if let autoBackupLastRunAt {
            next.lastAutoBackupDate = Date(timeIntervalSince1970: Double(autoBackupLastRunAt) / 1000)
        } else if let lastAutoBackupDate {
            // Format 1 (iOS): seconds, not millis.
            next.lastAutoBackupDate = Date(timeIntervalSince1970: lastAutoBackupDate)
        }
        next.deepseekApiKey = deepseekApiKey ?? current.deepseekApiKey
        if let aiProvider, let value = AiProvider(rawValue: aiProvider) { next.aiProvider = value }
        next.openChargeMapApiKey = openChargeMapApiKey ?? current.openChargeMapApiKey
        if let connectorTypes {
            let parsed = Set(connectorTypes.compactMap(ConnectorType.init(rawValue:)))
            // An empty or wholly unrecognised list keeps the current filter rather
            // than leaving the user with no connectors selected at all.
            if !parsed.isEmpty { next.connectorTypes = parsed }
        }
        if let dynamicColor { next.dynamicColor = dynamicColor }
        next.lastObdDeviceAddress = lastObdDeviceAddress ?? current.lastObdDeviceAddress
        next.lastObdDeviceName = lastObdDeviceName ?? current.lastObdDeviceName
        next.lastObdTransportType = lastObdTransportType ?? current.lastObdTransportType
        return next
    }
}

private struct BackupTrip: Codable {
    let id: String
    let startTime: WireDate
    let endTime: WireDate?
    let startSoc: Float
    let endSoc: Float?
    let distanceKm: Float
    let energyUsedKwh: Float
    let avgConsumptionKwhPer100km: Float?
    let ambientTempAvgC: Float?
    let note: String?
    /// Was missing from format 1 on iOS, so exporting dropped the briefing and
    /// restoring overwrote the row with a nil one. Android carried it all along.
    let aiBriefing: String?

    init(_ e: TripEntity) {
        id = e.id
        startTime = WireDate(e.startTime)
        endTime = e.endTime.map(WireDate.init)
        startSoc = e.startSoc
        endSoc = e.endSoc
        distanceKm = e.distanceKm
        energyUsedKwh = e.energyUsedKwh
        avgConsumptionKwhPer100km = e.avgConsumptionKwhPer100km
        ambientTempAvgC = e.ambientTempAvgC
        note = e.note
        aiBriefing = e.aiBriefing
    }

    var entity: TripEntity {
        TripEntity(
            id: id, startTime: startTime.date, endTime: endTime?.date,
            startSoc: startSoc, endSoc: endSoc,
            distanceKm: distanceKm, energyUsedKwh: energyUsedKwh,
            avgConsumptionKwhPer100km: avgConsumptionKwhPer100km,
            ambientTempAvgC: ambientTempAvgC, note: note,
            aiBriefing: aiBriefing
        )
    }
}

private struct BackupSample: Codable {
    let tripId: String
    let timestamp: WireDate
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
        timestamp = WireDate(e.timestamp)
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
            tripId: tripId, timestamp: timestamp.date, soc: soc, powerKw: powerKw,
            speedKph: speedKph, lat: lat, lon: lon, elevationM: elevationM,
            ambientTempC: ambientTempC, packTempC: packTempC
        )
    }
}

private struct BackupChargeSession: Codable {
    let id: String
    let startTime: WireDate
    let endTime: WireDate?
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
        startTime = WireDate(e.startTime)
        endTime = e.endTime.map(WireDate.init)
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
            id: id, startTime: startTime.date, endTime: endTime?.date,
            startSoc: startSoc, endSoc: endSoc,
            energyAddedKwh: energyAddedKwh, peakPowerKw: peakPowerKw,
            avgPowerKw: avgPowerKw, chargeType: chargeType,
            packTempStartC: packTempStartC, chargerId: chargerId
        )
    }
}

/// Named for the shared wire format (`savedPlans`); the local entity is still
/// `SavedTripEntity`. Both sides carry the same `planJson`.
private struct BackupSavedPlan: Codable {
    let id: String
    let name: String
    let planJson: String
    let createdAt: WireDate

    init(_ e: SavedTripEntity) {
        id = e.id
        name = e.name
        planJson = e.planJson
        createdAt = WireDate(e.createdAt)
    }

    var entity: SavedTripEntity {
        SavedTripEntity(id: id, name: name, planJson: planJson, createdAt: createdAt.date)
    }
}

private struct BackupSavedPlace: Codable {
    let id: String
    let name: String
    let category: String
    let lat: Double
    let lon: Double
    let createdAt: WireDate

    init(_ e: SavedPlaceEntity) {
        id = e.id
        name = e.name
        category = e.category
        lat = e.lat
        lon = e.lon
        createdAt = WireDate(e.createdAt)
    }

    var entity: SavedPlaceEntity {
        SavedPlaceEntity(id: id, name: name, category: category, lat: lat, lon: lon, createdAt: createdAt.date)
    }
}
