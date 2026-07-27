import Combine
import CoreData
import CoreDomain
import CoreOBD
import CoreRouting
import Foundation
import SwiftData

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
    let gemini: GeminiRepositoryImpl
    let tripLog: TripLogRepository
    let chargers: ChargerRepository
    let savedTrips: SavedTripRepository
    let savedPlaces: SavedPlaceRepository

    // MARK: - OBD

    let obdManager: ObdManager
    let bleScanner = BleScanner()

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
        gemini = GeminiRepositoryImpl()
        tripLog = TripLogRepository(
            modelContext: modelContext,
            entitlement: entitlement,
            preferencesRepository: preferences
        )
        chargers = ChargerRepository(modelContext: modelContext, apiKey: Secrets.openChargeMapKey)
        savedTrips = SavedTripRepository(modelContext: modelContext)
        savedPlaces = SavedPlaceRepository(modelContext: modelContext)

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
    }

    // MARK: - Startup

    func initialize() async {
        guard !isInitialized else { return }
        isInitialized = true

        bindPreferences()
        bindEntitlement()
        bindObdStream()

        await entitlement.refreshEntitlements()

        // Retention purge is cheap and only needs to run once per launch.
        do {
            try tripLog.purge(isPro: isPro)
        } catch {
            print("[AppServices] trip purge failed: \(error.localizedDescription)")
        }

        await autoConnectLastAdapter()
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

    /// Fans OBD output out to the telemetry repository (phone UI + CarPlay) and
    /// the trip log (persistence). This is the join that makes the packages live.
    private func bindObdStream() {
        obdManager.onTelemetryUpdated = { [weak self] sample in
            Task { @MainActor in
                guard let self else { return }
                self.telemetry.update(sample)
                do {
                    // No GPS fix yet — location comes from the drive-monitor
                    // service (Phase 5), so trips currently derive distance from
                    // the odometer rather than a GPS track.
                    try self.tripLog.onTelemetry(telemetry: sample, lat: nil, lon: nil)
                } catch {
                    print("[AppServices] sample logging failed: \(error.localizedDescription)")
                }
            }
        }

        obdManager.onConnectionStateChanged = { [weak self] state in
            Task { @MainActor in
                self?.telemetry.setConnectionState(state)
            }
        }
    }

    /// Reconnects to the adapter used last session, if one was saved.
    private func autoConnectLastAdapter() async {
        guard let address = userPreferences.lastObdDeviceAddress, !address.isEmpty else { return }
        let device = ObdDevice(
            name: userPreferences.lastObdDeviceName ?? "OBD Adapter",
            address: address,
            type: ObdDeviceType(rawValue: userPreferences.lastObdTransportType ?? "") ?? .ble,
            isPaired: true
        )
        await connect(to: device)
    }

    // MARK: - Adapter control

    /// Connects and remembers the adapter so the next launch reconnects on its own.
    @discardableResult
    func connect(to device: ObdDevice) async -> Result<Void, Error> {
        bleScanner.stop()
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

    func disconnect() async {
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
    /// Open Charge Map API key. OCM serves keyless requests at a lower rate limit,
    /// so an empty value degrades gracefully rather than failing outright.
    static var openChargeMapKey: String {
        Bundle.main.object(forInfoDictionaryKey: "OpenChargeMapAPIKey") as? String ?? ""
    }
}
