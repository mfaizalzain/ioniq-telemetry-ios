import CoreDomain
import Foundation
import UserNotifications

/// Handles taps on alert action buttons.
///
/// Only one action exists today: "Re-route" on an occupancy alert, which commits the
/// alternative plan the occupancy check already computed and parked. Committing is
/// self-contained — `commitPendingReroute()` swaps the active plan and route — so
/// every screen reading the active plan follows without further plumbing.
///
/// The delegate callbacks are `nonisolated`: `UNNotificationResponse` is not
/// Sendable, so only the action identifier (a String) crosses to the main actor.
final class NotificationActionHandler: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {

    private let onCommitReroute: @Sendable @MainActor () -> Void

    init(onCommitReroute: @escaping @Sendable @MainActor () -> Void) {
        self.onCommitReroute = onCommitReroute
        super.init()
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let actionIdentifier = response.actionIdentifier
        guard actionIdentifier == AlertNotifier.Action.commitReroute.rawValue else { return }
        await MainActor.run { onCommitReroute() }
    }

    /// Alerts are worth seeing while the app is open too — the driver is usually
    /// looking at the Plan screen when one fires.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}
