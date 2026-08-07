import Foundation
import CoreDomain

/// Physics constants and vehicle-catalog integration for the routing layer.
/// Delegates vehicle lookups to CoreDomain.Ioniq5Constants.
public enum Ioniq5RoutingConstants {
    // MARK: - Physics constants (spec §4.1)

    public static let massKg: Double = 2100.0        // curb; add user payload
    public static let cd: Double = 0.288
    public static let frontalAreaM2: Double = 2.60
    public static let crr: Double = 0.009
    public static let driveEfficiency: Double = 0.88
    public static let auxPowerW: Double = 400.0
    public static let airDensity: Double = 1.225
    public static let gravity: Double = 9.81

    // MARK: - Legacy OBD profile → vehicle ID mapping
    //
    // These resolve to CoreDomain catalog ids, which is what obdProfileIdFor
    // matches against. The older values ("ioniq5_77" etc.) were from the Android
    // catalog's id scheme and silently fell through to defaults here.

    private static let legacyToVehicle: [String: String] = [
        "ioniq5_84kwh":      "ioniq5_84",
        "ioniq5_2022_77kwh": "ioniq5_2022_77",
        "ioniq5_2021_72kwh": "ioniq5_2022_72",
        "ioniq5_2021_68kwh": "ioniq5_2022_72",
        "ioniq5_63kwh":      "ioniq6_2022_63",
        "ioniq5_2022_58kwh": "ioniq5_2022_58",
    ]

    /// Resolve a profile/vehicle ID to a vehicle catalog ID.
    private static func resolveVehicleId(_ id: String) -> String {
        legacyToVehicle[id] ?? id
    }

    // MARK: - Vehicle catalog delegation

    /// Resolve a profile/vehicle ID to the dashboard display name.
    public static func vehicleNameFor(_ profileId: String) -> String {
        Ioniq5Constants.vehicleNameFor(profileId)
    }

    /// Usable battery capacity (kWh) for a profile or vehicle ID.
    /// Falls back to 74 kWh when unmatched.
    public static func usableKwhForProfile(_ profileId: String, customKwh: Float? = nil) -> Double {
        if let customKwh, customKwh > 0 { return Double(customKwh) }
        return Double(Ioniq5Constants.usableKwhForProfile(profileId))
    }

    /// Resolve a profile/vehicle ID to its OBD profile identifier.
    public static func obdProfileIdFor(_ profileId: String) -> String? {
        let vid = resolveVehicleId(profileId)
        return Ioniq5Constants.allVehicles
            .first { $0.id == vid || $0.obdProfileId == profileId }?
            .obdProfileId
    }
}

// MARK: - HVAC power

/// HVAC power draw (W) as a function of ambient temperature (°C).
public func hvacPowerW(ambientC: Float) -> Double {
    switch ambientC {
    case ..<(-10): return 4500.0
    case ..<0:     return 3000.0
    case ..<10:    return 1500.0
    case ..<25:    return 300.0
    case ..<32:    return 1200.0
    default:       return 2500.0
    }
}
