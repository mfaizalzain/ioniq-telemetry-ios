import Foundation
import UserNotifications

/// Local notifications for the background monitors.
///
/// Authorization is requested lazily — on the first alert the app actually wants to
/// deliver — rather than at launch, so the prompt arrives with context.
@MainActor
final class AlertNotifier {

    enum Category: String {
        case chargeMilestone
        case tirePressure
        case chargerOccupancy
        case replanAdvice

        /// One identifier per category so a newer alert of the same kind replaces
        /// the old one instead of stacking up in Notification Centre.
        var requestIdentifier: String { "alert.\(rawValue)" }
    }

    private var didRequestAuthorization = false

    func post(_ category: Category, title: String, body: String) async {
        guard await ensureAuthorized() else { return }

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.interruptionLevel = .timeSensitive
        content.threadIdentifier = category.rawValue

        let request = UNNotificationRequest(
            identifier: category.requestIdentifier,
            content: content,
            trigger: nil                     // deliver now
        )
        try? await UNUserNotificationCenter.current().add(request)
    }

    private func ensureAuthorized() async -> Bool {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()

        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            return true
        case .denied:
            return false
        case .notDetermined:
            guard !didRequestAuthorization else { return false }
            didRequestAuthorization = true
            // Time-sensitive so charge-complete and low-tyre alerts can break
            // through a Focus mode, which is the whole point of them.
            return (try? await center.requestAuthorization(
                options: [.alert, .sound, .timeSensitive]
            )) ?? false
        @unknown default:
            return false
        }
    }
}
