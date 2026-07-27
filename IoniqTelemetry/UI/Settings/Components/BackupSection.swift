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

    @State private var exportedFile: ExportedFile?
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
            // Presentation modifiers go on the button rows, not on the Section:
            // a modifier on a Section is applied to every row inside it, so the
            // sheet ended up with one presenter per row all bound to the same
            // state, and the first tap was swallowed by the collision.
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
        } header: {
            Text("Data")
        } footer: {
            Text("Includes trips, charge sessions, saved routes and settings. Your API keys are in the file, so keep it somewhere private.")
        }
    }

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
            // Files chosen through the picker live outside the sandbox.
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
