import Combine
import CoreBluetooth
import os
import CoreData
import CoreDomain
import CoreOBD
import CoreRouting
import Foundation
import SwiftData
import BackgroundTasks
import UserNotifications
private let log = Logger(subsystem: "com.fmz.ioniqtelemetry", category: "appservices")


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

    /// Owns the app's single `CBCentralManager` for the whole process, arm the
    /// unattended connect and receives the link iOS restores after it terminates
    /// us. Created at launch because state restoration only works for a manager
    /// that exists before iOS calls `willRestoreState`.
    let blePresence: BlePresenceHost

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

    /// Retained because `UNUserNotificationCenter.delegate` is a weak reference.
    private var notificationHandler: NotificationActionHandler?

    // MARK: - Init

    init(modelContext: ModelContext = AppDatabase.shared.container.mainContext) {
        // Built first: the OBD factory below captures it, and every BLE session has
        // to reuse this one central manager rather than create its own.
        let presence = BlePresenceHost()
        blePresence = presence
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
            source: { preferencesRef.currentPreferences.chargerSourceOrDefault },
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
                    return BleTransport(host: presence) as any ObdTransport
                }
                return WifiTransport() as any ObdTransport
            },
            sessionDirectory: Self.sessionDirectory()
        )

        connectedCar = ConnectedCarService(services: self)

        // Wired here, after `self` is fully formed: the host is created before the
        // repositories, and its handlers need `self`.
        blePresence.setLinkHandler { [weak self] link in
            // Delivered on the BLE queue; every consumer of this link is main-actor.
            Task { @MainActor in await self?.adoptRestoredLink(link) }
        }
        blePresence.setStateHandler { state in
            log.info("[AutoConnect] central state \(String(describing: state))")
        }
    }

    // MARK: - Startup

    func initialize() async {
        guard !isInitialized else { return }
        isInitialized = true

        bindPreferences()
        bindEntitlement()
        bindObdStream()
        bindNotificationActions()

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
            log.error("[AppServices] trip purge failed: \(error.localizedDescription)")
        }

        await autoConnectLastAdapter()
        // The car is usually asleep at launch, so the attempt above normally fails.
        // Hand the request to Core Bluetooth before returning: it is held for as
        // long as it takes, survives suspension, and iOS relaunches us in the
        // background to complete it if we get terminated first.
        armAutoConnect()

        Self.migrateLegacyAutoBackups()
        registerAutoBackupTask()
    }

    /// Recheck StoreKit when the app returns to the foreground. This catches a
    /// purchase/refund completed outside the app and retries a StoreKit refresh
    /// that was inconclusive during an app update.
    func refreshEntitlements() async {
        _ = await entitlement.refreshEntitlements()
    }

    /// Registers the alert action buttons and the delegate that handles them. The
    /// "Re-route" button commits the alternative the occupancy check parked.
    private func bindNotificationActions() {
        let handler = NotificationActionHandler { [weak self] in
            guard let self else { return }
            if self.activePlan.commitPendingReroute() != nil {
                self.connectedCar.onRerouteCommitted()
            }
        }
        notificationHandler = handler
        UNUserNotificationCenter.current().delegate = handler
        AlertNotifier.registerCategories()
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
        // The link is being opened by hand, so a request the host is still holding
        // for the same or another adapter must not race this one.
        blePresence.disarm()

        let result = await obdManager.connect(device: device)
        switch result {
        case .success:
            await preferences.update { prefs in
                var next = prefs
                next.lastObdDeviceAddress = device.address
                next.lastObdDeviceName = device.name
                next.lastObdTransportType = device.type.rawValue
                next.lastObdDeviceSeenAt = Date()
                return next
            }
        case .failure:
            // The adapter was not reachable (car switched off, most likely), so
            // park a request instead of leaving the next drive to chance.
            armAutoConnect()
        }
        return result
    }

    /// - Parameter userInitiated: true for the Settings button, false when
    ///   `ConnectedCarService` is tearing down a dead session to rebuild it.
    func disconnect(userInitiated: Bool = true) async {
        if userInitiated {
            autoReconnectSuppressed = true
            // Someone who taps Disconnect wants to stay disconnected: drop the
            // request the host is holding too, or the adapter comes back on its own.
            blePresence.disarm()
        }
        await obdManager.disconnect()
    }

    /// Clears the saved adapter so the app stops auto-reconnecting to it.
    func forgetAdapter() async {
        blePresence.disarm()
        await disconnect()
        await preferences.update { prefs in
            var next = prefs
            next.lastObdDeviceAddress = nil
            next.lastObdDeviceName = nil
            next.lastObdTransportType = nil
            next.lastObdDeviceSeenAt = nil
            return next
        }
    }

    // MARK: - Auto-connect

    /// The user-facing switch. On by default (it is what the app already did at
    /// launch) and off only when somebody turns it off.
    var autoConnectEnabled: Bool { userPreferences.autoConnectEnabled }

    /// True while Core Bluetooth is holding an untimed connect for the saved
    /// adapter on our behalf. The supervisor stands down while this is true: the
    /// request is already parked with iOS, and re-scanning every few seconds would
    /// burn the phone's battery for a result we will be woken for anyway.
    var isHoldingAutoConnectRequest: Bool { blePresence.armed != nil }

    /// True when the saved adapter is a BLE peripheral — the only kind iOS can be
    /// asked to wake us for. A WiFi ELM327 is reachable only while the app runs.
    var savedAdapterSupportsWakeUp: Bool {
        AutoConnectTarget.supportsWakeUp(userPreferences.lastObdDeviceAddress)
    }

    /// Parks an untimed connect for the saved adapter, so iOS completes it and wakes
    /// the app the moment the car powers the dongle up — even if this process is
    /// gone by then.
    @discardableResult
    func armAutoConnect() -> Bool {
        guard userPreferences.autoConnectEnabled,
              !autoReconnectSuppressed,
              let identifier = AutoConnectTarget.peripheralIdentifier(
                  forSavedAddress: userPreferences.lastObdDeviceAddress
              )
        else { return false }
        return blePresence.arm(identifier: identifier)
    }

    /// Turns unattended auto-connect on or off. Off unarms immediately; on parks a
    /// request now rather than waiting for the next launch.
    func setAutoConnectEnabled(_ enabled: Bool) async {
        await preferences.update { prefs in
            var next = prefs
            next.autoConnectEnabled = enabled
            return next
        }
        if enabled {
            armAutoConnect()
        } else {
            blePresence.disarm()
        }
    }

    /// Builds a session around a link iOS handed back: either a parked request that
    /// completed while the app was suspended, or a restored link from a background
    /// relaunch after the app had been terminated.
    private func adoptRestoredLink(_ link: BlePresenceHost.AdapterLink) async {
        guard userPreferences.autoConnectEnabled, !autoReconnectSuppressed else {
            log.info("[AutoConnect] link offered while disabled — ignoring")
            blePresence.disarm()
            return
        }
        // Only an idle session can adopt: a link offered while a connect is in
        // flight (or a session is live) is either a duplicate of it or a race, and
        // tearing the working one down to adopt it would lose frames.
        switch obdManager.connectionState {
        case .disconnected, .error:
            break
        default:
            return
        }

        log.info("[AutoConnect] adopting link \(link.identifier.uuidString, privacy: .public)")
        if case .failure(let error) = await obdManager.adoptRestoredLink(link) {
            log.error("[AutoConnect] adopt failed: \(error.localizedDescription)")
            // Nothing is driving that link now, so park a fresh request rather than
            // leaving the next drive to the reconnect loop.
            armAutoConnect()
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
            log.error("[AutoBackup] failed to schedule: \(error.localizedDescription)")
        }
    }

    /// The actual background task body: export, record the timestamp, and
    /// re-schedule the next run.
    private func handleAutoBackupTask(_ task: BGProcessingTask) async {
        // A background launch skips `initialize()`, so migrate here too.
        Self.migrateLegacyAutoBackups()
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
            log.error("[AutoBackup] export failed: \(error.localizedDescription)")
            task.setTaskCompleted(success: false)
        }
        // Schedule the next run regardless of success or failure — a transient
        // error (e.g. disk full) should not kill the schedule permanently.
        scheduleOrCancelAutoBackup()
    }

    /// The directory where auto-backup files are stored (Application Support/autobackup/).
    /// Application Support is not exposed in the Files app, which matters because a
    /// backup carries every API key the user has entered. Manual exports still go to
    /// a temp file via the share sheet, where the user picks the destination.
    static func autoBackupDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let directory = base.appendingPathComponent("autobackup", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// One-time move of auto-backup files written to Documents/autobackup by builds
    /// before the directory moved to Application Support. Idempotent: a no-op once
    /// the legacy directory is gone, so it can run on every launch. Runs from both
    /// `initialize()` and the background task handler, because a BGTaskScheduler
    /// launch skips the SwiftUI `.task` that calls `initialize()`.
    static func migrateLegacyAutoBackups() {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let legacy = documents.appendingPathComponent("autobackup", isDirectory: true)
        guard FileManager.default.fileExists(atPath: legacy.path) else { return }

        let destination = autoBackupDirectory()
        for file in (try? FileManager.default.contentsOfDirectory(at: legacy, includingPropertiesForKeys: nil)) ?? [] {
            // A name collision (same stamp in both directories) keeps the old copy
            // rather than losing either one.
            try? FileManager.default.moveItem(at: file, to: destination.appendingPathComponent(file.lastPathComponent))
        }
        // Only remove the directory once it is empty, so anything a user put there
        // by hand via Files survives the move.
        if (try? FileManager.default.contentsOfDirectory(at: legacy, includingPropertiesForKeys: nil))?.isEmpty == true {
            try? FileManager.default.removeItem(at: legacy)
        }
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
