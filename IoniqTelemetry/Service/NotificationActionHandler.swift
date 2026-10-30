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
/// ## Why the completion-handler variants, not the `async` ones
///
/// `UNUserNotificationCenterDelegate` is not a main-actor protocol — its requirements
/// carry no `NS_SWIFT_UI_ACTOR` annotation — so the `async` forms are `nonisolated`
/// and the framework resumes its own continuation on a cooperative thread when they
/// return. UIKit then runs its snapshot / state-restoration work *synchronously on
/// that thread* and asserts it is the main thread, so the app dies with SIGABRT inside
/// `-[UIApplication _performBlockAfterCATransactionCommitSynchronizes:]` the first time
/// a notification is tapped, before any of this code's own work matters. TestFlight
/// 1.0.10 (20261027182919) crashed exactly that way: thread 12, with the app being
/// brought to the foreground by the tap.
///
/// Marking the `async` forms `@MainActor` is the obvious fix but does not compile in
/// Swift 6 against this SDK: `UNUserNotificationCenter`, `UNNotification` and
/// `UNNotificationResponse` are not `Sendable`, so sending them into a main-actor
/// implementation is rejected (`NonSendableInAsyncConformanceOrOverride`).
///
/// Both callbacks therefore use the Objective-C completion-handler form and invoke the
/// handler **on the main actor**, which keeps the framework's follow-on work on the
/// thread it requires. Only the action identifier (a `String`) and the presentation
/// options cross the actor boundary; the non-Sendable `UN…` arguments never do.
final class NotificationActionHandler: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {

    private let onCommitReroute: @Sendable @MainActor () -> Void

    init(onCommitReroute: @escaping @Sendable @MainActor () -> Void) {
        self.onCommitReroute = onCommitReroute
        super.init()
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let actionIdentifier = response.actionIdentifier
        let completion = CompletionBox(completionHandler)

        Task { @MainActor in
            if actionIdentifier == AlertNotifier.Action.commitReroute.rawValue {
                onCommitReroute()
            }

            completion.value()
        }
    }

    /// Alerts are worth seeing while the app is open too — the driver is usually
    /// looking at the Plan screen when one fires.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        let completion = CompletionBox(completionHandler)
        let options: UNNotificationPresentationOptions = [.banner, .sound]

        // Same hazard as `didReceive`: the options are delivered by calling the
        // handler, and the framework's follow-on work must start on the main thread.
        Task { @MainActor in
            completion.value(options)
        }
    }
}

/// Carries a non-`Sendable` Objective-C completion handler across an actor hop.
///
/// `@unchecked` is sound here: the handler is an opaque framework block that this
/// type only forwards, each one is invoked exactly once, from the main actor, and is
/// never touched again afterwards.
private struct CompletionBox<Handler>: @unchecked Sendable {
    let value: Handler

    init(_ value: Handler) {
        self.value = value
    }
}
