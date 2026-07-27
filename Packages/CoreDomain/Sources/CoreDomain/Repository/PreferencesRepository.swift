import Combine

public enum UnitSystem: String, Sendable {
    case metric = "METRIC"
    case imperial = "IMPERIAL"
}

/// Light/dark selection. DARK is the default — the phone is mounted in the car and
/// a light theme glares at night (spec §10.1); SYSTEM follows the OS setting.
public enum ThemeMode: String, Sendable {
    case light = "LIGHT"
    case dark = "DARK"
    case system = "SYSTEM"
}

/// Which routing engine plans the base route. Both are bring-your-own-key: the app
/// ships no routing key of its own, so each user's requests land on their own free
/// tier rather than a shared app-wide quota.
///
/// [openRouteService] is the recommended default — signup is an email and a token,
/// no card, and one key also covers geocoding and returns elevation gain.
public enum RoutingProvider: String, Sendable {
    /// Built-in MapKit — no key needed. No elevation data.
    case appleMaps = "APPLE_MAPS"
    case openRouteService = "OPEN_ROUTE_SERVICE"
    case googleMaps = "GOOGLE_MAPS"
}

/// Where charger locations are fetched from.
///
/// [openChargeMap] is the default and the only free option — the app ships a key,
/// it covers a bounding box in one request, and it carries price, operator and
/// access data. [googlePlaces] is bring-your-own-key and billed per request, but
/// its coverage is better in regions where OCM is thin. Places has no bounding-box
/// search, so an area is covered by tiled circle queries — the reason it is opt-in.
public enum ChargerSource: String, Sendable {
    case openChargeMap = "OPEN_CHARGE_MAP"
    case appleMaps = "APPLE_MAPS"
    case googlePlaces = "GOOGLE_PLACES"
    case combined = "COMBINED"
}

public struct UserPreferences: Sendable {
    public var unitSystem: UnitSystem
    public var connectorTypes: Set<ConnectorType>
    public var reserveSocPercent: Float
    public var targetArrivalSocPercent: Float
    public var payloadMassKg: Float
    public var activeProfileId: String
    public var customUsableBatteryKwh: Float?
    public var customVehicleName: String?
    public var priceWeight: Float
    public var lastObdDeviceAddress: String?
    public var lastObdDeviceName: String?
    public var lastObdTransportType: String?
    public var themeMode: ThemeMode
    /// Material You wallpaper-based color (Android 12+); ignored on older devices.
    public var dynamicColor: Bool
    /// Independently measured pack SOH from charge-session energy integration
    /// (coulomb counting), distinct from the BMS-reported SOH. Null until a large
    /// enough charge swing has been observed. [estimatedSohTimestamp] is epoch millis
    /// of that measurement.
    public var estimatedSohPercent: Float?
    public var estimatedSohTimestamp: Int64
    /// BYOK: user-supplied Google Maps API key, used for routing, Places and POI search.
    public var googleMapsApiKey: String?
    /// BYOK: user-supplied OpenRouteService key, used for routing and geocoding.
    public var orsApiKey: String?
    /// BYOK: Open Charge Map key. OCM rejects unauthenticated requests outright
    /// (HTTP 403), so charger lookup does nothing at all without this.
    public var openChargeMapApiKey: String?
    /// Which engine plans the base route. The key for the selected provider must also
    /// be set — [routingKeyFor] resolves both together, and route planning is
    /// unavailable until one pair is complete.
    public var routingProvider: RoutingProvider
    /// Pro/User BYOK feature: while driving or charging, user-supplied Google Gemini API key
    /// for plain-language diagnostics, battery thermal throttling explanations, and energy coaching.
    public var geminiApiKey: String?
    public var aiCoachingEnabled: Bool
    /// Pro feature: while driving, alert when every charger with live availability
    /// near the next stop is occupied and it's within ~10 min. Uses the Google
    /// Places API (billed to the user's key), so it is opt-in.
    public var chargerOccupancyAlerts: Bool
    /// Use Google Places API (instead of OpenRouteService geocoding) for POI destination search when key is set.
    public var googlePoiSearch: Bool
    /// Where charger locations come from. See [ChargerSource].
    public var chargerSource: ChargerSource

    public init(
        unitSystem: UnitSystem = .metric,
        connectorTypes: Set<ConnectorType> = [.ccs2],
        reserveSocPercent: Float = 10,
        targetArrivalSocPercent: Float = 20,
        payloadMassKg: Float = 100,
        activeProfileId: String = "ioniq5_2022_77kwh",
        customUsableBatteryKwh: Float? = nil,
        customVehicleName: String? = nil,
        priceWeight: Float = 0,
        lastObdDeviceAddress: String? = nil,
        lastObdDeviceName: String? = nil,
        lastObdTransportType: String? = nil,
        themeMode: ThemeMode = .dark,
        dynamicColor: Bool = true,
        estimatedSohPercent: Float? = nil,
        estimatedSohTimestamp: Int64 = 0,
        googleMapsApiKey: String? = nil,
        orsApiKey: String? = nil,
        openChargeMapApiKey: String? = nil,
        routingProvider: RoutingProvider = .appleMaps,
        geminiApiKey: String? = nil,
        aiCoachingEnabled: Bool = true,
        chargerOccupancyAlerts: Bool = false,
        googlePoiSearch: Bool = false,
        chargerSource: ChargerSource = .openChargeMap
    ) {
        self.unitSystem = unitSystem
        self.connectorTypes = connectorTypes
        self.reserveSocPercent = reserveSocPercent
        self.targetArrivalSocPercent = targetArrivalSocPercent
        self.payloadMassKg = payloadMassKg
        self.activeProfileId = activeProfileId
        self.customUsableBatteryKwh = customUsableBatteryKwh
        self.customVehicleName = customVehicleName
        self.priceWeight = priceWeight
        self.lastObdDeviceAddress = lastObdDeviceAddress
        self.lastObdDeviceName = lastObdDeviceName
        self.lastObdTransportType = lastObdTransportType
        self.themeMode = themeMode
        self.dynamicColor = dynamicColor
        self.estimatedSohPercent = estimatedSohPercent
        self.estimatedSohTimestamp = estimatedSohTimestamp
        self.googleMapsApiKey = googleMapsApiKey
        self.orsApiKey = orsApiKey
        self.openChargeMapApiKey = openChargeMapApiKey
        self.routingProvider = routingProvider
        self.geminiApiKey = geminiApiKey
        self.aiCoachingEnabled = aiCoachingEnabled
        self.chargerOccupancyAlerts = chargerOccupancyAlerts
        self.googlePoiSearch = googlePoiSearch
        self.chargerSource = chargerSource
    }

    /// The API key for [provider], or null when the user hasn't supplied one yet.
    public func routingKeyFor(provider: RoutingProvider? = nil) -> String? {
        let target = provider ?? routingProvider
        switch target {
        case .appleMaps: return nil
        case .openRouteService:
            guard let key = orsApiKey, !key.isEmpty else { return nil }
            return key
        case .googleMaps:
            guard let key = googleMapsApiKey, !key.isEmpty else { return nil }
            return key
        }
    }

    /// True when the selected routing provider has a usable key.
    public var canPlanRoutes: Bool {
        if routingProvider == .appleMaps { return true }
        return routingKeyFor() != nil
    }

    /// True when a free-text place search can reach *some* geocoder.
    ///
    /// Mirrors the provider choice in GeocodingRepository: Places only when the user
    /// opted into it and has a Maps key — enabling it is a spend decision, so a Maps
    /// key alone must not authorise it — otherwise OpenRouteService. Neither means a
    /// search can only ever come back empty, which the UI must explain rather than
    /// present as "no matches".
    public var canSearchPlaces: Bool {
        (googlePoiSearch && !(googleMapsApiKey?.isEmpty ?? true)) ||
        !(orsApiKey?.isEmpty ?? true)
    }
}

public protocol PreferencesRepository: Sendable {
    /// Publisher emitting the current user preferences.
    var preferences: AnyPublisher<UserPreferences, Never> { get }

    /// Update preferences via a transform closure.
    func update(_ transform: @Sendable (UserPreferences) -> UserPreferences) async
}
