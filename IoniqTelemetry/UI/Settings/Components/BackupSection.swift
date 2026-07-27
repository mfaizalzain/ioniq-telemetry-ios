import CoreData
import CoreDomain
import CoreUI
import SwiftUI
import UniformTypeIdentifiers

/// Backup export/import.
///
/// Export goes through the system share sheet and import through the document
/// picker, so the file lands wherever the user keeps their own data (Files,
/// iCloud Drive, AirDrop) rather than somewhere the app chose.
struct BackupSection: View {
    let viewModel: SettingsViewModel

    @State private var exportedFile: BackupFile?
    @State private var isImporting = false
    @State private var message: String?
    @State private var isError = false
    @State private var isWorking = false

    var body: some View {
        Section {
            Button {
                Task { await exportBackup() }
            } label: {
                Label("Export Backup", systemImage: "square.and.arrow.up")
            }
            .disabled(isWorking)

            Button {
                isImporting = true
            } label: {
                Label("Restore from Backup", systemImage: "square.and.arrow.down")
            }
            .disabled(isWorking)

            if let message {
                Label(message, systemImage: isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(isError ? Color.redAlert : Color.greenOk)
            }
        } header: {
            Text("Data")
        } footer: {
            Text("Includes trips, charge sessions, saved routes and settings. Your API keys are in the file, so keep it somewhere private.")
        }
        .sheet(item: $exportedFile) { file in
            ShareSheet(items: [file.url])
        }
        .fileImporter(
            isPresented: $isImporting,
            allowedContentTypes: [.json],
            allowsMultipleSelection: false
        ) { result in
            Task { await importBackup(result) }
        }
    }

    private func exportBackup() async {
        isWorking = true
        defer { isWorking = false }
        do {
            let url = try await viewModel.exportBackup()
            exportedFile = BackupFile(url: url)
            message = nil
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
            // Files chosen through the picker live outside the sandbox.
            guard url.startAccessingSecurityScopedResource() else {
                throw BackupUIError.noAccess
            }
            defer { url.stopAccessingSecurityScopedResource() }

            let summary = try await viewModel.restoreBackup(from: url)
            isError = false
            message = "Restored \(summary.trips) trips, \(summary.chargeSessions) charge sessions, \(summary.savedTrips) saved routes."
        } catch {
            isError = true
            message = error.localizedDescription
        }
    }
}

private enum BackupUIError: LocalizedError {
    case noAccess
    var errorDescription: String? { "Couldn't open that file." }
}

/// Identifiable wrapper so `.sheet(item:)` can drive presentation off the URL.
private struct BackupFile: Identifiable {
    let url: URL
    var id: String { url.path }
}

private struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
