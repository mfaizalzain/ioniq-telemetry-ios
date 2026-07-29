import Combine
import CoreData
import CoreDomain
import CoreOBD
import CoreRouting
import Foundation

/// Settings state. Every edit writes straight through to `PreferencesRepository`,
/// so nothing here is local-only view state that silently evaporates.
@Observable
@MainActor
final class SettingsViewModel {

    // MARK: - Preferences (mirrors of persisted values)

    private(set) var preferences = UserPreferences()
    private(set) var isPro = false
    /// Billed Google Places requests since launch — charger lookup, POI search and
    /// occupancy alerts all land on the user's own key.
    private(set) var placesApiCalls = 0

    // MARK: - Adapter

    private(set) var connectionState: ObdConnectionState = .disconnected
    private(set) var discoveredAdapters: [BleScanner.Discovery] = []
    private(set) var isScanning = false
    private(set) var adapterError: String?
    private(set) var isConnecting = false

    /// Non-nil when the active vehicle can't be decoded — surfaced rather than
    /// leaving the dashboard mysteriously blank.
    var profileError: String? { services.obdManager.lastProfileError }

    var connectedAdapterName: String? {
        connectionState == .connected ? preferences.lastObdDeviceName : nil
    }

    var savedAdapterName: String? { preferences.lastObdDeviceName }

    private let services: AppServices
    private var cancellables = Set<AnyCancellable>()

    init(services: AppServices) {
        self.services = services

        services.preferences.preferences
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.preferences = $0 }
            .store(in: &cancellables)

        services.entitlement.isPro
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.isPro = $0 }
            .store(in: &cancellables)

        services.telemetry.connectionState
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.connectionState = $0 }
            .store(in: &cancellables)

        PlacesUsageCounter.shared.count
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.placesApiCalls = $0 }
            .store(in: &cancellables)

        services.bleScanner.devices
            .sink { [weak self] in self?.discoveredAdapters = $0 }
            .store(in: &cancellables)

        services.bleScanner.isScanning
            .sink { [weak self] in self?.isScanning = $0 }
            .store(in: &cancellables)
    }

    // MARK: - Vehicle

    var activeVehicle: SupportedVehicle? {
        Ioniq5Constants.allVehicles.first { $0.id == preferences.activeProfileId }
            ?? Ioniq5Constants.allVehicles.first { $0.obdProfileId == preferences.activeProfileId }
    }

    var vehicleName: String {
        preferences.customVehicleName ?? Ioniq5Constants.vehicleNameFor(preferences.activeProfileId)
    }

    var vehiclesByMake: [(make: VehicleMake, vehicles: [SupportedVehicle])] {
        VehicleMake.allCases.map { make in
            (make, Ioniq5Constants.allVehicles.filter { $0.make == make })
        }
    }

    func selectVehicle(_ vehicle: SupportedVehicle) {
        update { $0.activeProfileId = vehicle.id }
    }

    // MARK: - Adapter control

    func startScan() {
        adapterError = services.bleScanner.unavailableReason
        guard adapterError == nil else { return }
        services.bleScanner.start()
    }

    func stopScan() { services.bleScanner.stop() }

    func connect(to device: ObdDevice) async {
        isConnecting = true
        adapterError = nil
        let result = await services.connect(to: device)
        isConnecting = false
        if case .failure(let error) = result {
            adapterError = error.localizedDescription
        }
    }

    /// Reconnects to the saved adapter without a fresh scan.
    func reconnectSaved() async {
        guard let address = preferences.lastObdDeviceAddress else { return }
        await connect(to: ObdDevice(
            name: preferences.lastObdDeviceName ?? "OBD Adapter",
            address: address,
            type: ObdDeviceType(rawValue: preferences.lastObdTransportType ?? "") ?? .ble,
            isPaired: true
        ))
    }

    /// Connects to a WiFi ELM327 by host or host:port.
    func connectWifi(address: String) async {
        let trimmed = address.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        await connect(to: ObdDevice(name: "WiFi Adapter", address: trimmed, type: .wifi))
    }

    func disconnect() async { await services.disconnect() }

    func forgetAdapter() async { await services.forgetAdapter() }

    // MARK: - Preference writers

    func setUnitSystem(_ value: UnitSystem) { update { $0.unitSystem = value } }
    func setThemeMode(_ value: ThemeMode) { update { $0.themeMode = value } }
    func setGoogleMapsKey(_ value: String) { update { $0.googleMapsApiKey = value.isEmpty ? nil : value } }
    func setOrsKey(_ value: String) { update { $0.orsApiKey = value.isEmpty ? nil : value } }
    func setRoutingProvider(_ value: RoutingProvider) { update { $0.routingProvider = value } }
    func setChargerOccupancyAlerts(_ value: Bool) { update { $0.chargerOccupancyAlerts = value } }
    func setGooglePoiSearch(_ value: Bool) { update { $0.googlePoiSearch = value } }

    /// Switching source invalidates the cache: rows from the old provider would
    /// otherwise keep satisfying the 7-day TTL and the change would look inert.
    func setChargerSource(_ value: ChargerSource) {
        guard value != preferences.chargerSource else { return }
        update { $0.chargerSource = value }
        try? services.chargers.clearCache()
    }
    func setReserveSoc(_ value: Float) { update { $0.reserveSocPercent = value } }
    func setTargetArrivalSoc(_ value: Float) { update { $0.targetArrivalSocPercent = value } }
    func setGeminiApiKey(_ value: String) { update { $0.geminiApiKey = value.isEmpty ? nil : value } }
    func setAiFeaturesEnabled(_ value: Bool) { update { $0.aiFeaturesEnabled = value } }
    func setAiCoachingEnabled(_ value: Bool) { update { $0.aiCoachingEnabled = value } }

    /// Why charger occupancy alerts cannot run, or nil when they can. Surfaced so a
    /// disabled toggle explains itself instead of just looking broken.
    var occupancyBlockedReason: String? {
        if !isPro { return "Charger occupancy alerts are part of Pro." }
        if (preferences.googleMapsApiKey ?? "").isEmpty {
            return "Add a Google Places API key below to check live availability."
        }
        return nil
    }

    /// The routing key required by the selected provider, if it's still missing.
    var missingRoutingKey: String? {
        switch preferences.routingProvider {
        case .appleMaps:
            return nil
        case .openRouteService:
            return (preferences.orsApiKey ?? "").isEmpty ? "OpenRouteService" : nil
        case .googleMaps:
            return (preferences.googleMapsApiKey ?? "").isEmpty ? "Google Maps" : nil
        }
    }

    // MARK: - Backup

    /// Writes the backup to a temporary file and returns its URL for sharing.
    func exportBackup() async throws -> URL {
        let data = try services.backup.export(preferences: preferences)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(BackupRepository.suggestedFilename())
        try data.write(to: url, options: .atomic)
        return url
    }

    func restoreBackup(from url: URL) async throws -> BackupRepository.ImportSummary {
        try await services.backup.restore(from: Data(contentsOf: url))
    }

    // MARK: - Auto Backup

    func setAutoBackupEnabled(_ enabled: Bool) {
        update { $0.autoBackupEnabled = enabled }
        AppServices.shared.scheduleOrCancelAutoBackup()
    }

    func setAutoBackupFrequency(_ frequency: AutoBackupFrequency) {
        update { $0.autoBackupFrequency = frequency }
        AppServices.shared.scheduleOrCancelAutoBackup()
    }

    /// Performs an immediate backup to the persistent autobackup directory and
    /// records the timestamp so the UI reflects it straight away.
    func performAutoBackup() async throws {
        let directory = AppServices.autoBackupDirectory()
        try services.backup.exportToPersistentFile(preferences: preferences, directory: directory)
        // Update last-backup timestamp in preferences so the UI updates.
        let now = Date()
        await services.preferences.update { prefs in
            var next = prefs
            next.lastAutoBackupDate = now
            return next
        }
    }

    private func update(_ mutate: @escaping @Sendable (inout UserPreferences) -> Void) {
        Task {
            await services.preferences.update { current in
                var next = current
                mutate(&next)
                return next
            }
        }
    }
}
