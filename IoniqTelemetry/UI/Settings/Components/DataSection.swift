import CoreData
import CoreDomain
import CoreUI
import SwiftUI
import UniformTypeIdentifiers

/// Backup and restore, as two verbs rather than five entry points.
///
/// A backup lives *in* the app: "Back up now" writes one, and the Backups list is
/// the single place to send one out (Share) or bring one back (Restore). Only a
/// file that isn't in that list needs the document picker, so it is the one that
/// says "Import".
///
/// The previous shape had "Export Backup", "Create new" and "Back Up Now" for
/// writing and "Restore from Backup" and "Restore auto backup" for reading, with
/// two near-identical file-list dialogs behind them — and "Create new" produced a
/// file that never appeared in the list it was shown inside.
struct DataSection: View {
    let viewModel: SettingsViewModel

    @State private var showBackupList = false
    @State private var isImporting = false
    @State private var backupCount = 0

    @State private var isWorking = false
    @State private var message: String?
    @State private var isError = false

    /// Sharing and restoring are raised from the list sheet's `onDismiss`: starting
    /// a presentation while another is still dismissing gets dropped by SwiftUI,
    /// which is what made sharing need two taps.
    @State private var pendingAction: PendingAction?
    @State private var exportedFile: ExportedFile?
    @State private var restoreCandidate: RestoreCandidate?

    var body: some View {
        Section {
            Button {
                Task { await backUpNow() }
            } label: {
                if isWorking {
                    HStack(spacing: 8) {
                        ProgressView().scaleEffect(0.8)
                        Text("Backing up…")
                    }
                } else {
                    Label("Back up now", systemImage: "externaldrive")
                }
            }
            .disabled(isWorking)

            Button {
                showBackupList = true
            } label: {
                HStack {
                    Label("Backups", systemImage: "clock.arrow.circlepath")
                    Spacer()
                    Text(backupCount == 0 ? "None" : "\(backupCount)")
                        .foregroundStyle(.secondary)
                }
            }

            Button {
                isImporting = true
            } label: {
                Label("Import from file…", systemImage: "folder")
            }
            .disabled(isWorking)

            if let message {
                Label(message, systemImage: isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(isError ? Color.appRed : Color.appGreen)
            }

            // — Auto Backup —
            Toggle(isOn: Binding(
                get: { viewModel.preferences.autoBackupEnabled },
                set: { viewModel.setAutoBackupEnabled($0) }
            )) {
                Label("Auto Backup", systemImage: "clock")
            }

            if viewModel.preferences.autoBackupEnabled {
                Picker("Frequency", selection: Binding(
                    get: { viewModel.preferences.autoBackupFrequency },
                    set: { viewModel.setAutoBackupFrequency($0) }
                )) {
                    ForEach(AutoBackupFrequency.allCases, id: \.self) { freq in
                        Text(freq.label).tag(freq)
                    }
                }

                HStack {
                    Text("Last backup")
                    Spacer()
                    Text(lastBackupLabel)
                        .foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("Data")
        } footer: {
            Text("A backup holds trips, charge sessions, saved routes and settings. Your API keys are in the file, so keep it somewhere private.\n\nBackups are saved inside the app and are also reachable from Files. The newest 5 are kept.")
        }
        .task {
            backupCount = viewModel.listAutoBackups().count
        }
        .sheet(isPresented: $showBackupList, onDismiss: consumePendingAction) {
            BackupListView(viewModel: viewModel) { action in
                pendingAction = action
            }
        }
        .sheet(item: $exportedFile) { file in
            ShareSheet(items: [file.url])
        }
        .fileImporter(
            isPresented: $isImporting,
            allowedContentTypes: [.json],
            allowsMultipleSelection: false
        ) { result in
            prepareImport(result)
        }
        // One confirmation for both paths — a restore replaces settings either way.
        .alert("Restore this backup?", isPresented: Binding(
            get: { restoreCandidate != nil },
            set: { if !$0 { restoreCandidate = nil } }
        ), presenting: restoreCandidate) { candidate in
            Button("Restore") {
                Task { await restore(candidate) }
            }
            Button("Cancel", role: .cancel) { restoreCandidate = nil }
        } message: { _ in
            Text("Trips and saved items with the same id are overwritten, anything else is kept, and your settings are replaced. Pro status is unaffected.")
        }
    }

    // MARK: - Actions

    private func consumePendingAction() {
        guard let action = pendingAction else { return }
        pendingAction = nil
        switch action {
        case .share(let url):
            exportedFile = ExportedFile(url: url)
        case .restore(let url, let label):
            restoreCandidate = RestoreCandidate(url: url, label: label, isTemporary: false)
        }
    }

    private func backUpNow() async {
        isWorking = true
        message = nil
        defer { isWorking = false }
        do {
            try await viewModel.performAutoBackup()
            backupCount = viewModel.listAutoBackups().count
            isError = false
            message = "Backup saved."
        } catch {
            isError = true
            message = error.localizedDescription
        }
    }

    /// Copies the picked file into the container before asking for confirmation: the
    /// security-scoped URL is only valid inside this callback, so a copy is what
    /// survives long enough for the user to answer.
    private func prepareImport(_ result: Result<[URL], any Error>) {
        do {
            guard let url = try result.get().first else { return }
            guard url.startAccessingSecurityScopedResource() else { throw BackupUIError.noAccess }
            defer { url.stopAccessingSecurityScopedResource() }

            let copy = FileManager.default.temporaryDirectory
                .appendingPathComponent("import-\(UUID().uuidString).json")
            try FileManager.default.copyItem(at: url, to: copy)
            restoreCandidate = RestoreCandidate(
                url: copy,
                label: url.lastPathComponent,
                isTemporary: true
            )
        } catch {
            isError = true
            message = error.localizedDescription
        }
    }

    private func restore(_ candidate: RestoreCandidate) async {
        isWorking = true
        message = nil
        defer {
            isWorking = false
            if candidate.isTemporary { try? FileManager.default.removeItem(at: candidate.url) }
            restoreCandidate = nil
        }
        do {
            let summary = try await viewModel.restoreBackup(from: candidate.url)
            backupCount = viewModel.listAutoBackups().count
            isError = false
            message = Self.summaryText(summary)
        } catch {
            isError = true
            message = error.localizedDescription
        }
    }

    /// Reports everything the file carried, including settings and samples — the
    /// old message counted four tables and stayed silent about the rest.
    private static func summaryText(_ summary: BackupRepository.ImportSummary) -> String {
        // Only what the file actually carried — naming every empty table made the
        // message long and told the user nothing.
        var parts: [String] = []
        if summary.trips > 0 { parts.append(count(summary.trips, "trip")) }
        if summary.chargeSessions > 0 { parts.append(count(summary.chargeSessions, "charge session")) }
        if summary.savedTrips > 0 { parts.append(count(summary.savedTrips, "saved route")) }
        if summary.savedPlaces > 0 { parts.append(count(summary.savedPlaces, "saved place")) }

        guard !parts.isEmpty else {
            return summary.settingsRestored
                ? "Settings restored. The backup held no records."
                : "That backup was empty."
        }
        var text = "Restored " + parts.joined(separator: ", ")
        text += summary.settingsRestored ? ", and your settings." : "."
        return text
    }

    private var lastBackupLabel: String {
        guard let date = viewModel.preferences.lastAutoBackupDate else { return "Never" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

// MARK: - Backup list

/// The one place backups are listed. Each row can go out (Share) or come back
/// (Restore); the parent performs whichever was asked for once this sheet closes.
private struct BackupListView: View {
    let viewModel: SettingsViewModel
    let onAction: (PendingAction) -> Void

    @State private var backups: [BackupRepository.AutoBackupFile] = []
    @State private var isLoading = true
    @State private var errorText: String?
    @Environment(\.dismiss) private var dismiss

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    ProgressView()
                } else if backups.isEmpty {
                    ContentUnavailableView(
                        "No backups yet",
                        systemImage: "tray",
                        description: Text("Tap “Back up now” to make one.")
                    )
                } else {
                    List {
                        Section {
                            ForEach(backups) { backup in
                                row(backup)
                            }
                        } footer: {
                            Text("Restoring merges a backup into your current data and replaces your settings.")
                        }
                    }
                }
            }
            .navigationTitle("Backups")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .alert("Couldn't read that backup", isPresented: Binding(
                get: { errorText != nil },
                set: { if !$0 { errorText = nil } }
            )) {
                Button("OK") { errorText = nil }
            } message: {
                Text(errorText ?? "")
            }
        }
        .task {
            backups = viewModel.listAutoBackups()
            isLoading = false
        }
    }

    private func row(_ backup: BackupRepository.AutoBackupFile) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(Self.dateFormatter.string(from: backup.lastModified))
                    .font(.body)
                Text(formatBytes(backup.sizeBytes))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                guard let url = viewModel.exportAutoBackupFile(stamp: backup.name) else {
                    errorText = "That backup file could not be read."
                    return
                }
                onAction(.share(url))
                dismiss()
            } label: {
                Label("Share", systemImage: "square.and.arrow.up")
                    .labelStyle(.iconOnly)
            }
            .buttonStyle(.borderless)
            .tint(Color.appAccent)

            Button("Restore") {
                onAction(.restore(
                    url: backup.url,
                    label: Self.dateFormatter.string(from: backup.lastModified)
                ))
                dismiss()
            }
            .buttonStyle(.borderless)
            .font(.callout.weight(.medium))
            .tint(Color.appAccent)
        }
        .accessibilityElement(children: .contain)
    }
}

// MARK: - Supporting types

/// What the list asked for, performed after it has finished dismissing.
private enum PendingAction {
    case share(URL)
    case restore(url: URL, label: String)
}

private struct RestoreCandidate: Identifiable {
    let url: URL
    let label: String
    /// True for a copy of an imported file, which is deleted once restored.
    let isTemporary: Bool
    var id: String { url.absoluteString }
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

private func count(_ value: Int, _ noun: String) -> String {
    "\(value) \(noun)\(value == 1 ? "" : "s")"
}

private func formatBytes(_ bytes: Int) -> String {
    if bytes < 1024 { return "\(bytes) B" }
    if bytes < 1024 * 1024 { return String(format: "%.1f KB", Double(bytes) / 1024.0) }
    return String(format: "%.1f MB", Double(bytes) / (1024.0 * 1024.0))
}
