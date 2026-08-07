import CoreData
import Foundation
import UserNotifications

/// Daily reminders: a preconditioning nudge at the driver's departure time and an
/// off-peak charging nudge. Both are calendar triggers, re-armed idempotently on
/// every settings change.
enum ReminderScheduler {

    static func scheduleDeparture(hour: Int, minute: Int, enabled: Bool) {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [departureId])
        guard enabled else { return }

        let content = UNMutableNotificationContent()
        content.title = "Departure time"
        content.body = "Preconditioning before you leave cuts cold-start losses and gets you more range per kWh."
        content.sound = .default

        var components = DateComponents()
        components.hour = hour
        components.minute = minute
        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: true)
        center.add(UNNotificationRequest(identifier: departureId, content: content, trigger: trigger))
    }

    /// Schedules the evening off-peak nudge only when the driver's usual charging
    /// hour actually falls outside 23:00–06:00 — otherwise the reminder is noise.
    static func scheduleOffPeak(enabled: Bool, modalChargeHour: Int?) {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [offPeakId])
        guard enabled, let hour = modalChargeHour, !(hour == 23 || (0...5).contains(hour)) else { return }

        let content = UNMutableNotificationContent()
        content.title = "Off-peak charging"
        content.body = String(
            format: "You usually charge at %02d:00 — off-peak rates typically start at 23:00. Charging then could save real money.",
            hour
        )
        content.sound = .default

        var components = DateComponents()
        components.hour = 19
        components.minute = 0
        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: true)
        center.add(UNNotificationRequest(identifier: offPeakId, content: content, trigger: trigger))
    }

    /// The most common hour (0-23) that charge sessions started, over the last 30.
    static func modalChargeHour(from sessions: [ChargeSessionEntity]) -> Int? {
        guard !sessions.isEmpty else { return nil }
        let hours = Dictionary(grouping: sessions.prefix(30)) {
            Calendar.current.component(.hour, from: $0.startTime)
        }
        return hours.max { $0.value.count < $1.value.count }?.key
    }

    private static let departureId = "departure-reminder"
    private static let offPeakId = "off-peak-reminder"
}
