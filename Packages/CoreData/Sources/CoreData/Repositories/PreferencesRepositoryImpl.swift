import Combine
import CoreDomain
import Foundation

/// UserDefaults-backed implementation of PreferencesRepository.
public final class PreferencesRepositoryImpl: PreferencesRepository, @unchecked Sendable {
    private let defaults = UserDefaults.standard
    private let _preferences: CurrentValueSubject<UserPreferences, Never>

    public var preferences: AnyPublisher<UserPreferences, Never> {
        _preferences.eraseToAnyPublisher()
    }

    /// Latest value without subscribing, for callers that need a synchronous read.
    public var currentPreferences: UserPreferences { _preferences.value }

    public init() {
        _preferences = CurrentValueSubject(Self.load(from: defaults))
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
        prefs.googleMapsApiKey = defaults.string(forKey: "googleMapsApiKey")
        prefs.orsApiKey = defaults.string(forKey: "orsApiKey")
        prefs.openChargeMapApiKey = defaults.string(forKey: "openChargeMapApiKey")

        if let raw = defaults.string(forKey: "routingProvider"),
           let val = RoutingProvider(rawValue: raw) { prefs.routingProvider = val }

        prefs.geminiApiKey = defaults.string(forKey: "geminiApiKey")
        prefs.aiCoachingEnabled = defaults.bool(forKey: "aiCoachingEnabled", default: true)
        prefs.chargerOccupancyAlerts = defaults.bool(forKey: "chargerOccupancyAlerts", default: false)
        prefs.googlePoiSearch = defaults.bool(forKey: "googlePoiSearch", default: false)

        if let raw = defaults.string(forKey: "chargerSource"),
           let val = ChargerSource(rawValue: raw) { prefs.chargerSource = val }

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
        defaults.set(prefs.googleMapsApiKey, forKey: "googleMapsApiKey")
        defaults.set(prefs.orsApiKey, forKey: "orsApiKey")
        defaults.set(prefs.openChargeMapApiKey, forKey: "openChargeMapApiKey")
        defaults.set(prefs.routingProvider.rawValue, forKey: "routingProvider")
        defaults.set(prefs.geminiApiKey, forKey: "geminiApiKey")
        defaults.set(prefs.aiCoachingEnabled, forKey: "aiCoachingEnabled")
        defaults.set(prefs.chargerOccupancyAlerts, forKey: "chargerOccupancyAlerts")
        defaults.set(prefs.googlePoiSearch, forKey: "googlePoiSearch")
        defaults.set(prefs.chargerSource.rawValue, forKey: "chargerSource")
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
    func float(forKey key: String, default defaultValue: Float) -> Float {
        let value = self.float(forKey: key)
        // UserDefaults returns 0 for unset float keys — use dictionaryRepresentation to detect
        return dictionaryRepresentation()[key] != nil ? value : defaultValue
    }

    func bool(forKey key: String, default defaultValue: Bool) -> Bool {
        dictionaryRepresentation()[key] != nil ? bool(forKey: key) : defaultValue
    }

    func floatOrNil(forKey key: String) -> Float? {
        dictionaryRepresentation()[key] != nil ? float(forKey: key) : nil
    }
}
