import CoreDomain
import SwiftUI

/// Scheduled auto-backup controls: enable toggle, frequency picker, last-backup
/// status, and a one-shot "Backup Now" button.
struct AutoBackupSection: View {
    let viewModel: SettingsViewModel

    @State private var isWorking = false
    @State private var message: String?
    @State private var isError = false

    var body: some View {
        Section {
            Toggle(isOn: Binding(
                get: { viewModel.preferences.autoBackupEnabled },
                set: { newValue in
                    viewModel.setAutoBackupEnabled(newValue)
                }
            )) {
                Label("Auto Backup", systemImage: "clock.arrow.circlepath")
            }

            if viewModel.preferences.autoBackupEnabled {
                Picker("Frequency", selection: Binding(
                    get: { viewModel.preferences.autoBackupFrequency },
                    set: { newValue in
                        viewModel.setAutoBackupFrequency(newValue)
                    }
                )) {
                    ForEach(AutoBackupFrequency.allCases, id: \.self) { freq in
                        Text(freq.label).tag(freq)
                    }
                }

                HStack {
                    Label("Last backup", systemImage: "clock")
                    Spacer()
                    Text(lastBackupLabel)
                        .foregroundStyle(.secondary)
                }

                Button {
                    Task { await performBackupNow() }
                } label: {
                    if isWorking {
                        HStack(spacing: 8) {
                            ProgressView()
                                .scaleEffect(0.8)
                            Text("Backing up…")
                        }
                    } else {
                        Label("Back Up Now", systemImage: "square.and.arrow.up")
                    }
                }
                .disabled(isWorking)
            }

            if let message {
                Label(message, systemImage: isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(isError ? Color.appRed : Color.appGreen)
            }
        } header: {
            Text("Auto Backup")
        } footer: {
            Text("Backups are saved to the app's Documents folder and are accessible via Finder or Files. Old backups are automatically pruned, keeping the last 5.")
        }
    }

    private var lastBackupLabel: String {
        if let date = viewModel.preferences.lastAutoBackupDate {
            let formatter = RelativeDateTimeFormatter()
            formatter.unitsStyle = .abbreviated
            return formatter.localizedString(for: date, relativeTo: Date())
        }
        return "Never"
    }

    private func performBackupNow() async {
        isWorking = true
        message = nil
        defer { isWorking = false }
        do {
            try await viewModel.performAutoBackup()
            isError = false
            message = "Backup complete."
        } catch {
            isError = true
            message = error.localizedDescription
        }
    }
}
