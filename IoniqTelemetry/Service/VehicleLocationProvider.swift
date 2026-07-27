import CoreDomain
import CoreLocation
import CoreMotion
import Foundation

/// Continuous position and motion for trip tracking.
///
/// Distinct from `LocationProvider` in the Plan screen, which is a one-shot lookup:
/// this one holds a long-running session with background updates so a drive keeps
/// being recorded while the phone is locked.
@MainActor
final class VehicleLocationProvider: NSObject {

    /// Matches the Android build's displacement filter. Larger than it sounds — a
    /// parked car then produces no fixes at all, which is exactly what
    /// `DriveMonitor` relies on to tell parked from tunnel.
    private static let distanceFilterM: CLLocationDistance = 25

    private let manager = CLLocationManager()
    // Constructing a CMMotionActivityManager is itself enough to raise the Motion
    // & Fitness prompt, so it is built on first use — once an adapter is connected
    // and there is a drive to detect — rather than at app launch.
    private var activityManager: CMMotionActivityManager?

    private(set) var latestFix: Fix?

    /// For debug simulation: injects a synthetic GPS fix without CoreLocation.
    func setFix(_ fix: Fix?) { latestFix = fix }
    private(set) var isInVehicle = false
    private(set) var isTracking = false

    var hasLocationPermission: Bool {
        switch manager.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse: return true
        default: return false
        }
    }

    /// Only consults CoreMotion once tracking has begun. Querying it at all is
    /// enough to raise the Motion & Fitness prompt, and asking before an adapter is
    /// even connected gives the user no context for the request.
    var hasMotionPermission: Bool {
        guard isTracking else { return false }
        return CMMotionActivityManager.authorizationStatus() == .authorized
    }

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBestForNavigation
        manager.distanceFilter = Self.distanceFilterM
        // `activityType` and `pausesLocationUpdatesAutomatically` both lean on the
        // motion coprocessor, and merely setting them raises the Motion & Fitness
        // prompt — so they are configured in `start()`, not here. Constructing this
        // provider must stay free of side effects: it happens at app launch, long
        // before there is a drive to track.
    }

    // MARK: - Control

    func start() {
        guard !isTracking else { return }
        isTracking = true

        manager.activityType = .automotiveNavigation
        // Lets iOS suspend and relaunch us around a drive instead of keeping GPS hot.
        manager.pausesLocationUpdatesAutomatically = true

        switch manager.authorizationStatus {
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
        case .authorizedWhenInUse:
            // Background trip logging needs Always; asking only once the user has
            // already granted When In Use is the sequence iOS expects.
            manager.requestAlwaysAuthorization()
        default:
            break
        }

        guard hasLocationPermission else { return }
        manager.startUpdatingLocation()
        if manager.authorizationStatus == .authorizedAlways {
            manager.allowsBackgroundLocationUpdates = true
        }
        startActivityUpdates()
    }

    func stop() {
        isTracking = false
        manager.stopUpdatingLocation()
        manager.allowsBackgroundLocationUpdates = false
        activityManager?.stopActivityUpdates()
        latestFix = nil
        isInVehicle = false
    }

    private func authorizationChanged() {
        guard isTracking, hasLocationPermission else { return }
        manager.startUpdatingLocation()
        if manager.authorizationStatus == .authorizedAlways {
            manager.allowsBackgroundLocationUpdates = true
        }
        startActivityUpdates()
    }

    private func startActivityUpdates() {
        guard CMMotionActivityManager.isActivityAvailable() else { return }
        let manager = activityManager ?? CMMotionActivityManager()
        activityManager = manager
        manager.startActivityUpdates(to: .main) { [weak self] activity in
            guard let activity else { return }
            // Low confidence is worse than no signal here: DriveMonitor treats
            // inVehicle as a trip-start trigger when it's blind otherwise.
            guard activity.confidence != .low else { return }
            self?.isInVehicle = activity.automotive
        }
    }
}

// MARK: - CLLocationManagerDelegate

extension VehicleLocationProvider: CLLocationManagerDelegate {

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        let fix = Fix(
            lat: location.coordinate.latitude,
            lon: location.coordinate.longitude,
            at: location.timestamp
        )
        Task { @MainActor in self.latestFix = fix }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // Transient failures are normal (tunnels, cold start). DriveMonitor already
        // treats an absent fix as "unknown" rather than "stationary".
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        // Use the actor-isolated `self.manager` rather than the callback argument,
        // which cannot cross the isolation boundary.
        Task { @MainActor in self.authorizationChanged() }
    }
}
