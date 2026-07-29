import Combine
import CoreDomain
import Foundation

/// UserDefaults-backed implementation of PreferencesRepository.
///
/// The four API keys are the exception: they live in the Keychain (see
/// `KeychainStore`) rather than the plist, and are migrated out of UserDefaults on
/// first load. They remain ordinary fields on `UserPreferences`, so every reader —
/// including the backup export — is unaffected by where they are stored.
public final class PreferencesRepositoryImpl: PreferencesRepository, @unchecked Sendable {

    /// Keychain account names for the credentials held outside the plist. The
    /// strings double as the legacy UserDefaults keys they are migrated from.
    private enum SecretKey {
        static let googleMaps = "googleMapsApiKey"
        static let ors = "orsApiKey"
        static let openChargeMap = "openChargeMapApiKey"
        static let gemini = "geminiApiKey"

        static let all = [googleMaps, ors, openChargeMap, gemini]
    }

    private let defaults = UserDefaults.standard
    private let _preferences: CurrentValueSubject<UserPreferences, Never>

    public var preferences: AnyPublisher<UserPreferences, Never> {
        _preferences.eraseToAnyPublisher()
    }

    /// Latest value without subscribing, for callers that need a synchronous read.
    public var currentPreferences: UserPreferences { _preferences.value }

    public init() {
        Self.migrateSecretsToKeychain(from: defaults)
        _preferences = CurrentValueSubject(Self.load(from: defaults))
    }

    /// Moves any key still sitting in the plist into the Keychain, once, then
    /// removes the plaintext copy. Safe to run on every launch: after the first
    /// pass there is nothing left in UserDefaults to find.
    private static func migrateSecretsToKeychain(from defaults: UserDefaults) {
        for account in SecretKey.all {
            guard let legacy = defaults.string(forKey: account), !legacy.isEmpty else { continue }
            // Don't clobber a Keychain value that is already there — if both exist,
            // the Keychain one is the newer write.
            if KeychainStore.read(account) == nil {
                KeychainStore.write(legacy, account: account)
            }
            defaults.removeObject(forKey: account)
        }
    }

    public func update(_ transform: @Sendable (UserPreferences) -> UserPreferences) async {
        let newValue = transform(_preferences.value)
        _preferences.value = newValue
        Self.save(newValue, to: defaults)
    }

    // MARK: - Persistence

    private static func load(from defaults: UserDefaults) -> UserPreferences {
        var prefs = UserPreferences()

        if let raw = defaults.string(forKey: "unitSystem"),
           let val = UnitSystem(rawValue: raw) { prefs.unitSystem = val }

        if let rawTypes = defaults.stringArray(forKey: "connectorTypes") {
            prefs.connectorTypes = Set(rawTypes.compactMap { ConnectorType(rawValue: $0) })
        }

        prefs.reserveSocPercent = defaults.float(forKey: "reserveSocPercent", default: 10)
        prefs.targetArrivalSocPercent = defaults.float(forKey: "targetArrivalSocPercent", default: 20)
        prefs.payloadMassKg = defaults.float(forKey: "payloadMassKg", default: 100)
        prefs.activeProfileId = defaults.string(forKey: "activeProfileId") ?? "ioniq5_2022_77kwh"
        prefs.customUsableBatteryKwh = defaults.floatOrNil(forKey: "customUsableBatteryKwh")
        prefs.customVehicleName = defaults.string(forKey: "customVehicleName")
        prefs.priceWeight = defaults.float(forKey: "priceWeight", default: 0)
        prefs.lastObdDeviceAddress = defaults.string(forKey: "lastObdDeviceAddress")
        prefs.lastObdDeviceName = defaults.string(forKey: "lastObdDeviceName")
        prefs.lastObdTransportType = defaults.string(forKey: "lastObdTransportType")

        if let raw = defaults.string(forKey: "themeMode"),
           let val = ThemeMode(rawValue: raw) { prefs.themeMode = val }

        prefs.dynamicColor = defaults.bool(forKey: "dynamicColor", default: true)
        prefs.estimatedSohPercent = defaults.floatOrNil(forKey: "estimatedSohPercent")
        prefs.estimatedSohTimestamp = Int64(defaults.integer(forKey: "estimatedSohTimestamp"))
        prefs.googleMapsApiKey = KeychainStore.read(SecretKey.googleMaps)
        prefs.orsApiKey = KeychainStore.read(SecretKey.ors)
        prefs.openChargeMapApiKey = KeychainStore.read(SecretKey.openChargeMap)

        if let raw = defaults.string(forKey: "routingProvider"),
           let val = RoutingProvider(rawValue: raw) { prefs.routingProvider = val }

        prefs.geminiApiKey = KeychainStore.read(SecretKey.gemini)
        prefs.aiCoachingEnabled = defaults.bool(forKey: "aiCoachingEnabled", default: true)
        prefs.chargerOccupancyAlerts = defaults.bool(forKey: "chargerOccupancyAlerts", default: false)
        prefs.googlePoiSearch = defaults.bool(forKey: "googlePoiSearch", default: false)

        if let raw = defaults.string(forKey: "chargerSource"),
           let val = ChargerSource(rawValue: raw) { prefs.chargerSource = val }

        prefs.autoBackupEnabled = defaults.bool(forKey: "autoBackupEnabled", default: false)
        if let raw = defaults.string(forKey: "autoBackupFrequency"),
           let val = AutoBackupFrequency(rawValue: raw) { prefs.autoBackupFrequency = val }
        if let interval = defaults.object(forKey: "lastAutoBackupDate") as? TimeInterval {
            prefs.lastAutoBackupDate = Date(timeIntervalSince1970: interval)
        }

        return prefs
    }

    private static func save(_ prefs: UserPreferences, to defaults: UserDefaults) {
        defaults.set(prefs.unitSystem.rawValue, forKey: "unitSystem")
        defaults.set(prefs.connectorTypes.map(\.rawValue), forKey: "connectorTypes")
        defaults.set(prefs.reserveSocPercent, forKey: "reserveSocPercent")
        defaults.set(prefs.targetArrivalSocPercent, forKey: "targetArrivalSocPercent")
        defaults.set(prefs.payloadMassKg, forKey: "payloadMassKg")
        defaults.set(prefs.activeProfileId, forKey: "activeProfileId")
        setFloatOrNil(prefs.customUsableBatteryKwh, forKey: "customUsableBatteryKwh", in: defaults)
        defaults.set(prefs.customVehicleName, forKey: "customVehicleName")
        defaults.set(prefs.priceWeight, forKey: "priceWeight")
        defaults.set(prefs.lastObdDeviceAddress, forKey: "lastObdDeviceAddress")
        defaults.set(prefs.lastObdDeviceName, forKey: "lastObdDeviceName")
        defaults.set(prefs.lastObdTransportType, forKey: "lastObdTransportType")
        defaults.set(prefs.themeMode.rawValue, forKey: "themeMode")
        defaults.set(prefs.dynamicColor, forKey: "dynamicColor")
        setFloatOrNil(prefs.estimatedSohPercent, forKey: "estimatedSohPercent", in: defaults)
        defaults.set(Int(prefs.estimatedSohTimestamp), forKey: "estimatedSohTimestamp")
        KeychainStore.write(prefs.googleMapsApiKey, account: SecretKey.googleMaps)
        KeychainStore.write(prefs.orsApiKey, account: SecretKey.ors)
        KeychainStore.write(prefs.openChargeMapApiKey, account: SecretKey.openChargeMap)
        defaults.set(prefs.routingProvider.rawValue, forKey: "routingProvider")
        KeychainStore.write(prefs.geminiApiKey, account: SecretKey.gemini)
        defaults.set(prefs.aiCoachingEnabled, forKey: "aiCoachingEnabled")
        defaults.set(prefs.chargerOccupancyAlerts, forKey: "chargerOccupancyAlerts")
        defaults.set(prefs.googlePoiSearch, forKey: "googlePoiSearch")
        defaults.set(prefs.chargerSource.rawValue, forKey: "chargerSource")
        defaults.set(prefs.autoBackupEnabled, forKey: "autoBackupEnabled")
        defaults.set(prefs.autoBackupFrequency.rawValue, forKey: "autoBackupFrequency")
        if let date = prefs.lastAutoBackupDate {
            defaults.set(date.timeIntervalSince1970, forKey: "lastAutoBackupDate")
        } else {
            defaults.removeObject(forKey: "lastAutoBackupDate")
        }
    }

    private static func setFloatOrNil(_ value: Float?, forKey key: String, in defaults: UserDefaults) {
        if let value {
            defaults.set(value, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }
}

private extension UserDefaults {
    /// `object(forKey:)` rather than `dictionaryRepresentation()[key]`: the latter
    /// materialises every default in every domain — including the global ones — on
    /// each call, and these helpers are called once per preference.
    func hasValue(forKey key: String) -> Bool { object(forKey: key) != nil }

    func float(forKey key: String, default defaultValue: Float) -> Float {
        // UserDefaults returns 0 for unset float keys, so presence has to be checked.
        hasValue(forKey: key) ? float(forKey: key) : defaultValue
    }

    func bool(forKey key: String, default defaultValue: Bool) -> Bool {
        hasValue(forKey: key) ? bool(forKey: key) : defaultValue
    }

    func floatOrNil(forKey key: String) -> Float? {
        hasValue(forKey: key) ? float(forKey: key) : nil
    }
}
