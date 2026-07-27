import Foundation

// MARK: - E-GMP Vehicle Catalog

public struct SupportedVehicle: Sendable, Identifiable, Equatable {
    public var id: String
    public var make: VehicleMake
    public var model: String
    public var year: Int
    public var usableKwh: Float
    public var obdProfileId: String
    public var displayName: String

    public init(
        id: String, make: VehicleMake, model: String, year: Int,
        usableKwh: Float, obdProfileId: String, displayName: String
    ) {
        self.id = id
        self.make = make
        self.model = model
        self.year = year
        self.usableKwh = usableKwh
        self.obdProfileId = obdProfileId
        self.displayName = displayName
    }
}

public enum VehicleMake: String, Sendable, CaseIterable {
    case hyundai = "Hyundai"
    case kia = "Kia"
    case genesis = "Genesis"
}

public enum Ioniq5Constants {
    public static let allVehicles: [SupportedVehicle] = [
        // Hyundai Ioniq 5
        SupportedVehicle(id: "ioniq5_2022_58", make: .hyundai, model: "Ioniq 5", year: 2022, usableKwh: 58.0, obdProfileId: "ioniq5_2022_58kwh", displayName: "IONIQ 5"),
        SupportedVehicle(id: "ioniq5_2022_72", make: .hyundai, model: "Ioniq 5", year: 2022, usableKwh: 72.6, obdProfileId: "ioniq5_2022_72kwh", displayName: "IONIQ 5"),
        SupportedVehicle(id: "ioniq5_2022_77", make: .hyundai, model: "Ioniq 5", year: 2022, usableKwh: 77.4, obdProfileId: "ioniq5_2022_77kwh", displayName: "IONIQ 5"),
        SupportedVehicle(id: "ioniq5_84", make: .hyundai, model: "Ioniq 5", year: 2023, usableKwh: 84.0, obdProfileId: "ioniq5_84kwh", displayName: "IONIQ 5"),
        SupportedVehicle(id: "ioniq5n", make: .hyundai, model: "Ioniq 5 N", year: 2024, usableKwh: 84.0, obdProfileId: "ioniq5_84kwh", displayName: "IONIQ 5 N"),
        // Hyundai Ioniq 6
        SupportedVehicle(id: "ioniq6_2022_58", make: .hyundai, model: "Ioniq 6", year: 2022, usableKwh: 58.0, obdProfileId: "ioniq6_58kwh", displayName: "IONIQ 6"),
        SupportedVehicle(id: "ioniq6_2022_63", make: .hyundai, model: "Ioniq 6", year: 2022, usableKwh: 63.0, obdProfileId: "ioniq6_63kwh", displayName: "IONIQ 6"),
        SupportedVehicle(id: "ioniq6_2022_77", make: .hyundai, model: "Ioniq 6", year: 2022, usableKwh: 77.4, obdProfileId: "ioniq6_77kwh", displayName: "IONIQ 6"),
        // Kia EV6
        SupportedVehicle(id: "ev6_2022_58", make: .kia, model: "EV6", year: 2022, usableKwh: 58.0, obdProfileId: "ev6_58kwh", displayName: "EV6"),
        SupportedVehicle(id: "ev6_2022_76", make: .kia, model: "EV6", year: 2022, usableKwh: 76.1, obdProfileId: "ev6_76kwh", displayName: "EV6"),
        SupportedVehicle(id: "ev6_2022_77", make: .kia, model: "EV6", year: 2022, usableKwh: 77.4, obdProfileId: "ev6_77kwh", displayName: "EV6"),
        SupportedVehicle(id: "ev6_84", make: .kia, model: "EV6", year: 2023, usableKwh: 84.0, obdProfileId: "ev6_84kwh", displayName: "EV6"),
        SupportedVehicle(id: "ev6_gt", make: .kia, model: "EV6 GT", year: 2023, usableKwh: 77.4, obdProfileId: "ev6_77kwh", displayName: "EV6 GT"),
        // Kia EV9
        SupportedVehicle(id: "ev9_2024_76", make: .kia, model: "EV9", year: 2024, usableKwh: 76.1, obdProfileId: "ev9_76kwh", displayName: "EV9"),
        SupportedVehicle(id: "ev9_2024_99", make: .kia, model: "EV9", year: 2024, usableKwh: 99.8, obdProfileId: "ev9_99kwh", displayName: "EV9"),
        // Genesis GV60
        SupportedVehicle(id: "gv60_77", make: .genesis, model: "GV60", year: 2023, usableKwh: 77.4, obdProfileId: "gv60_77kwh", displayName: "GV60"),
    ]

    public static func vehicleNameFor(_ profileId: String) -> String {
        allVehicles.first { $0.obdProfileId == profileId }?.displayName
            ?? allVehicles.first { $0.id == profileId }?.displayName
            ?? "E-GMP"
    }

    public static func usableKwhForProfile(_ profileId: String) -> Float {
        allVehicles.first { $0.id == profileId }?.usableKwh
            ?? 77.4 // default
    }
}
