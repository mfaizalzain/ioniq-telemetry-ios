import Combine
import CoreData
import CoreDomain
import CoreOBD
import CoreRouting
import Foundation
import SwiftData
import BackgroundTasks

/// Composition root. Owns every repository and the OBD stack, and joins the OBD
/// telemetry stream to the shared telemetry repository and the trip log.
///
/// Injected into the SwiftUI environment once by `IoniqTelemetryApp`; the CarPlay
/// scene reads the same instance via `AppServices.shared`, so both surfaces show
/// identical live data from one adapter connection.
@Observable
@MainActor
final class AppServices {

    /// Shared instance so the CarPlay scene delegate — which has no SwiftUI
    /// environment to read from — reaches the same repositories as the phone UI.
    static let shared = AppServices()

    // MARK: - Repositories

    let preferences: PreferencesRepositoryImpl
    let entitlement: EntitlementRepositoryImpl
    let telemetry: TelemetryRepositoryImpl
    let tripLog: TripLogRepository
    let chargers: ChargerRepository
    let savedTrips: SavedTripRepository
    let savedPlaces: SavedPlaceRepository
    let backup: BackupRepository
    let occupancy = OccupancyRepository()
    let routing: RouteRepository
    let geocoding: GeocodingRepository
    let activePlan = ActivePlanHolderImpl()

    // MARK: - OBD

    let obdManager: ObdManager
    let bleScanner = BleScanner()

    /// Raw decoder output, before correction. `ConnectedCarService` is the only
    /// subscriber: it fixes regen-vs-charging and speed, then publishes the result
    /// to `telemetry`, which is what every other surface reads.
    let rawTelemetry = PassthroughSubject<VehicleTelemetry, Never>()

    /// Owns the drive pipeline. Not observable — it needs `self`, and @Observable
    /// cannot back a lazy property.
    @ObservationIgnored private(set) var connectedCar: ConnectedCarService!

    // MARK: - Observable state

    private(set) var isInitialized = false
    private(set) var isPro = false
    private(set) var userPreferences = UserPreferences()

    private var cancellables = Set<AnyCancellable>()
    private var loadedProfileId: String?

    // MARK: - Init

    init(modelContext: ModelContext = AppDatabase.shared.container.mainContext) {
        preferences = PreferencesRepositoryImpl()
        entitlement = EntitlementRepositoryImpl()
        telemetry = TelemetryRepositoryImpl()
        tripLog = TripLogRepository(
            modelContext: modelContext,
            entitlement: entitlement,
            preferencesRepository: preferences
        )
        // Captured weakly through a box so the repository always sees the current
        // preference rather than whatever was set at launch.
        let preferencesRef = preferences
        chargers = ChargerRepository(
            modelContext: modelContext,
            apiKey: {
                let userKey = preferencesRef.currentPreferences.openChargeMapApiKey ?? ""
                return userKey.isEmpty ? Secrets.openChargeMapKey : userKey
            },
            source: { preferencesRef.currentPreferences.chargerSource },
            googleApiKey: { preferencesRef.currentPreferences.googleMapsApiKey ?? "" }
        )
        savedTrips = SavedTripRepository(modelContext: modelContext)
        savedPlaces = SavedPlaceRepository(modelContext: modelContext)
        routing = RouteRepository(preferences: preferences)
        geocoding = GeocodingRepository(preferences: preferences)
        backup = BackupRepository(modelContext: modelContext, preferences: preferences)

        obdManager = ObdManager(
            transportFactory: { address in
                // A UUID is a CoreBluetooth peripheral identifier; anything else
                // (host, or host:port) is a WiFi ELM327 adapter.
                if UUID(uuidString: address) != nil {
                    return BleTransport() as any ObdTransport
                }
                return WifiTransport() as any ObdTransport
            },
            sessionDirectory: Self.sessionDirectory()
        )

        connectedCar = ConnectedCarService(services: self)
    }

    // MARK: - Startup

    func initialize() async {
        guard !isInitialized else { return }
        isInitialized = true

        bindPreferences()
        bindEntitlement()
        bindObdStream()

        // Re-derived from StoreKit, not read back from the cached flag — a refund or
        // a purchase made on another device lands here rather than waiting for the
        // user to open the paywall.
        let entitled = await entitlement.refreshEntitlements()

        connectedCar.start()

        // Retention purge is cheap and only needs to run once per launch. It uses the
        // value just returned rather than `isPro`, which the publisher has not
        // necessarily delivered to the main queue yet.
        do {
            try tripLog.purge(isPro: entitled)
        } catch {
            print("[AppServices] trip purge failed: \(error.localizedDescription)")
        }

        await autoConnectLastAdapter()

        registerAutoBackupTask()
    }

    private func bindPreferences() {
        preferences.preferences
            .receive(on: DispatchQueue.main)
            .sink { [weak self] prefs in
                guard let self else { return }
                self.userPreferences = prefs
                guard prefs.activeProfileId != self.loadedProfileId else { return }
                self.loadedProfileId = prefs.activeProfileId
                self.obdManager.loadProfile(profileId: prefs.activeProfileId)
            }
            .store(in: &cancellables)
    }

    private func bindEntitlement() {
        entitlement.isPro
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.isPro = $0 }
            .store(in: &cancellables)
    }

    /// Publishes OBD output to `rawTelemetry`, never straight to the repository.
    /// `ConnectedCarService` is the single consumer that corrects the frame (regen
    /// vs charging, GPS-derived speed) and only then updates `telemetry` — so the
    /// UI, CarPlay and the trip log all see one corrected view of the drive.
    private func bindObdStream() {
        obdManager.onTelemetryUpdated = { [weak self] sample in
            Task { @MainActor in
                self?.rawTelemetry.send(sample)
            }
        }

        obdManager.onConnectionStateChanged = { [weak self] state in
            Task { @MainActor in
                self?.telemetry.setConnectionState(state)
            }
        }
    }

    /// True once an adapter has been saved, so the supervisor knows there is
    /// something to reconnect to.
    var hasSavedAdapter: Bool {
        !(userPreferences.lastObdDeviceAddress ?? "").isEmpty
    }

    /// Set when the user disconnects by hand. Someone who taps Disconnect wants to
    /// stay disconnected, so the supervisor's reconnect loop stands down until they
    /// connect again — otherwise the adapter comes back a few seconds later and the
    /// button looks broken.
    private(set) var autoReconnectSuppressed = false

    /// Reconnects to the adapter used last session, if one was saved. Called at
    /// launch and again by `ConnectedCarService` whenever the link drops.
    @discardableResult
    func autoConnectLastAdapter() async -> Bool {
        guard let address = userPreferences.lastObdDeviceAddress, !address.isEmpty else { return false }
        let device = ObdDevice(
            name: userPreferences.lastObdDeviceName ?? "OBD Adapter",
            address: address,
            type: ObdDeviceType(rawValue: userPreferences.lastObdTransportType ?? "") ?? .ble,
            isPaired: true
        )
        if case .success = await connect(to: device) { return true }
        return false
    }

    // MARK: - Adapter control

    /// Connects and remembers the adapter so the next launch reconnects on its own.
    @discardableResult
    func connect(to device: ObdDevice) async -> Result<Void, Error> {
        bleScanner.stop()
        autoReconnectSuppressed = false
        let result = await obdManager.connect(device: device)
        if case .success = result {
            await preferences.update { prefs in
                var next = prefs
                next.lastObdDeviceAddress = device.address
                next.lastObdDeviceName = device.name
                next.lastObdTransportType = device.type.rawValue
                return next
            }
        }
        return result
    }

    /// - Parameter userInitiated: true for the Settings button, false when
    ///   `ConnectedCarService` is tearing down a dead session to rebuild it.
    func disconnect(userInitiated: Bool = true) async {
        if userInitiated { autoReconnectSuppressed = true }
        await obdManager.disconnect()
    }

    /// Clears the saved adapter so the app stops auto-reconnecting to it.
    func forgetAdapter() async {
        await disconnect()
        await preferences.update { prefs in
            var next = prefs
            next.lastObdDeviceAddress = nil
            next.lastObdDeviceName = nil
            next.lastObdTransportType = nil
            return next
        }
    }

    // MARK: - Auto Backup

    /// Identifier registered in Info.plist for the background backup task.
    private static let autoBackupTaskIdentifier = "com.fmz.IoniqTelemetry.autobackup"

    /// Registers the BGTaskScheduler task handler and schedules the first run if
    /// auto-backup is enabled. Called once during app launch.
    private func registerAutoBackupTask() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: Self.autoBackupTaskIdentifier, using: nil) { task in
            Task {
                await self.handleAutoBackupTask(task as! BGProcessingTask)
            }
        }
        scheduleOrCancelAutoBackup()
    }

    /// Schedules or cancels the background backup task based on current preferences.
    /// Called whenever the user toggles auto-backup or changes the frequency, and
    /// also after a background run completes so the next one is booked.
    func scheduleOrCancelAutoBackup() {
        guard userPreferences.autoBackupEnabled else {
            BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.autoBackupTaskIdentifier)
            return
        }

        let request = BGProcessingTaskRequest(identifier: Self.autoBackupTaskIdentifier)
        request.requiresNetworkConnectivity = false
        request.requiresExternalPower = false
        request.earliestBeginDate = Date().addingTimeInterval(
            userPreferences.autoBackupFrequency.schedulingInterval
        )

        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            print("[AutoBackup] failed to schedule: \(error.localizedDescription)")
        }
    }

    /// The actual background task body: export, record the timestamp, and
    /// re-schedule the next run.
    private func handleAutoBackupTask(_ task: BGProcessingTask) async {
        let directory = Self.autoBackupDirectory()
        do {
            try backup.exportToPersistentFile(preferences: userPreferences, directory: directory)
            await preferences.update { prefs in
                var next = prefs
                next.lastAutoBackupDate = Date()
                return next
            }
            task.setTaskCompleted(success: true)
        } catch {
            print("[AutoBackup] export failed: \(error.localizedDescription)")
            task.setTaskCompleted(success: false)
        }
        // Schedule the next run regardless of success or failure — a transient
        // error (e.g. disk full) should not kill the schedule permanently.
        scheduleOrCancelAutoBackup()
    }

    /// The directory where auto-backup files are stored (Documents/autobackup/).
    /// Files here are visible via iTunes File Sharing and the Files app because
    /// UIFileSharingEnabled is set in Info.plist.
    static func autoBackupDirectory() -> URL {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return documents.appendingPathComponent("autobackup", isDirectory: true)
    }

    // MARK: - Helpers

    private static func sessionDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let directory = base.appendingPathComponent("ObdSessions", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}

/// Build-time configuration read from Info.plist, so no key is committed in source.
enum Secrets {
    /// Optional build-time Open Charge Map key, for a distribution build that ships
    /// one. Empty in normal development, in which case the user's own key from
    /// Settings is used — OCM rejects unauthenticated requests with HTTP 403.
    static var openChargeMapKey: String {
        Bundle.main.object(forInfoDictionaryKey: "OpenChargeMapAPIKey") as? String ?? ""
    }
}
