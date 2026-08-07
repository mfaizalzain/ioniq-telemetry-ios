import ActivityKit
import Foundation

/// Live Activity content: SOC, range, charging state — glanceable on the lock
/// screen / Dynamic Island while a drive or charge is in progress (feature
/// suggestion #2). Started when the adapter connects, updated on meaningful
/// changes, ended on disconnect.
struct TelemetryActivityAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        var socPercent: Double
        var rangeKm: Double
        var isCharging: Bool
    }
    var vehicleName: String
}

enum TelemetryLiveActivity {
    // Accessed only from ConnectedCarService's main-actor sink; the single
    // consumer makes the shared state safe in practice.
    nonisolated(unsafe) private static var active: Activity<TelemetryActivityAttributes>?

    static func start(vehicleName: String, soc: Double, rangeKm: Double, isCharging: Bool) {
        guard active == nil, ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        let attributes = TelemetryActivityAttributes(vehicleName: vehicleName)
        let state = TelemetryActivityAttributes.ContentState(
            socPercent: soc, rangeKm: rangeKm, isCharging: isCharging
        )
        do {
            active = try Activity.request(attributes: attributes, contentState: state, pushType: nil)
        } catch {
            print("[LiveActivity] start failed: \(error.localizedDescription)")
        }
    }

    static func update(soc: Double, rangeKm: Double, isCharging: Bool) {
        guard let active else { return }
        let state = TelemetryActivityAttributes.ContentState(
            socPercent: soc, rangeKm: rangeKm, isCharging: isCharging
        )
        Task {
            await active.update(using: state)
        }
    }

    static func stop() {
        guard let active else { return }
        let activity = active
        self.active = nil
        Task {
            await activity.end(dismissalPolicy: .immediate)
        }
    }
}
