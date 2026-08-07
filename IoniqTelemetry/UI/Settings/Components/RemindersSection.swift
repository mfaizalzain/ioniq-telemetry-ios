import CoreDomain
import SwiftUI

/// Preconditioning + off-peak charging reminders (feature suggestions #5/#7).
struct RemindersSection: View {
    let viewModel: SettingsViewModel

    @State private var departureTime = Date()

    var body: some View {
        Section("Reminders") {
            Toggle("Preconditioning reminder", isOn: Binding(
                get: { viewModel.preferences.departureReminderEnabled },
                set: { viewModel.setDepartureReminder(enabled: $0) }
            ))

            if viewModel.preferences.departureReminderEnabled {
                DatePicker(
                    "Departure time",
                    selection: $departureTime,
                    displayedComponents: .hourAndMinute
                )
                .onChange(of: departureTime) { _, newValue in
                    let comps = Calendar.current.dateComponents([.hour, .minute], from: newValue)
                    viewModel.setDepartureTime(
                        hour: comps.hour ?? 7,
                        minute: comps.minute ?? 0
                    )
                }
                .onAppear {
                    departureTime = Calendar.current.date(
                        bySettingHour: viewModel.preferences.departureReminderHour,
                        minute: viewModel.preferences.departureReminderMinute,
                        second: 0,
                        of: Date()
                    ) ?? Date()
                }
            }

            Toggle("Off-peak charging", isOn: Binding(
                get: { viewModel.preferences.offPeakReminderEnabled },
                set: { viewModel.setOffPeakReminder(enabled: $0) }
            ))
        }
    }
}
