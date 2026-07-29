import CoreData
import CoreDomain
import CoreUI
import SwiftUI
import UniformTypeIdentifiers

/// Backup export/import and auto-backup controls merged into one "Data" section.
///
/// Export goes through the system share sheet and import through the document
/// picker, so the file lands wherever the user keeps their own data (Files,
/// iCloud Drive, AirDrop) rather than somewhere the app chose.
struct DataSection: View {
    let viewModel: SettingsViewModel

    @State private var exportedFile: ExportedFile?
    @State private var isImporting = false
    @State private var message: String?
    @State private var isError = false
    @State private var isWorking = false

    // Auto-backup state
    @State private var autoBackupIsWorking = false
    @State private var autoBackupMessage: String?
    @State private var autoBackupIsError = false

    var body: some View {
        Section {
            // — Export / Import —
            Button {
                Task { await exportBackup() }
            } label: {
                Label("Export Backup", systemImage: "square.and.arrow.up")
            }
            .disabled(isWorking)
            .sheet(item: $exportedFile, onDismiss: { exportedFile = nil }) { file in
                ShareSheet(items: [file.url])
            }

            Button {
                isImporting = true
            } label: {
                Label("Restore from Backup", systemImage: "square.and.arrow.down")
            }
            .disabled(isWorking)
            .fileImporter(
                isPresented: $isImporting,
                allowedContentTypes: [.json],
                allowsMultipleSelection: false
            ) { result in
                Task { await importBackup(result) }
            }

            if let message {
                Label(message, systemImage: isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(isError ? Color.appRed : Color.appGreen)
            }

            // — Auto Backup —
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
                    if autoBackupIsWorking {
                        HStack(spacing: 8) {
                            ProgressView()
                                .scaleEffect(0.8)
                            Text("Backing up…")
                        }
                    } else {
                        Label("Back Up Now", systemImage: "square.and.arrow.up")
                    }
                }
                .disabled(autoBackupIsWorking)

                if let autoBackupMessage {
                    Label(autoBackupMessage, systemImage: autoBackupIsError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(autoBackupIsError ? Color.appRed : Color.appGreen)
                }
            }
        } header: {
            Text("Data")
        } footer: {
            Text("Includes trips, charge sessions, saved routes and settings. Your API keys are in the file, so keep it somewhere private.\n\nAuto-backups are saved to the app's Documents folder and are accessible via Finder or Files. Old backups are automatically pruned, keeping the last 5.")
        }
    }

    // MARK: - Backup export / import

    private func exportBackup() async {
        isWorking = true
        defer { isWorking = false }
        do {
            let url = try await viewModel.exportBackup()
            message = nil
            exportedFile = ExportedFile(url: url)
        } catch {
            isError = true
            message = error.localizedDescription
        }
    }

    private func importBackup(_ result: Result<[URL], any Error>) async {
        isWorking = true
        defer { isWorking = false }
        do {
            guard let url = try result.get().first else { return }
            guard url.startAccessingSecurityScopedResource() else {
                throw BackupUIError.noAccess
            }
            defer { url.stopAccessingSecurityScopedResource() }

            let summary = try await viewModel.restoreBackup(from: url)
            isError = false
            message = "Restored "
                + [
                    count(summary.trips, "trip"),
                    count(summary.chargeSessions, "charge session"),
                    count(summary.savedTrips, "saved route"),
                    count(summary.savedPlaces, "saved place"),
                ].joined(separator: ", ") + "."
        } catch {
            isError = true
            message = error.localizedDescription
        }
    }

    // MARK: - Auto backup

    private var lastBackupLabel: String {
        if let date = viewModel.preferences.lastAutoBackupDate {
            let formatter = RelativeDateTimeFormatter()
            formatter.unitsStyle = .abbreviated
            return formatter.localizedString(for: date, relativeTo: Date())
        }
        return "Never"
    }

    private func performBackupNow() async {
        autoBackupIsWorking = true
        autoBackupMessage = nil
        defer { autoBackupIsWorking = false }
        do {
            try await viewModel.performAutoBackup()
            autoBackupIsError = false
            autoBackupMessage = "Backup complete."
        } catch {
            autoBackupIsError = true
            autoBackupMessage = error.localizedDescription
        }
    }
}

private func count(_ value: Int, _ noun: String) -> String {
    "\(value) \(noun)\(value == 1 ? "" : "s")"
}

/// Identity is the URL, so a re-export of the same path still re-presents.
private struct ExportedFile: Identifiable {
    let url: URL
    var id: String { url.absoluteString }
}

private enum BackupUIError: LocalizedError {
    case noAccess
    var errorDescription: String? { "Couldn't open that file." }
}

private struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
