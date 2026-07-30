import CoreData
import CoreDomain
import SwiftUI

/// A card/sheet view that displays an AI-generated battery health report including
/// SOH history, voltage balance trends, and charge speed degradation analysis.
/// Collapsed by default; user taps to expand and fetch. Result cached for the session.
struct BatteryHealthReportView: View {
    @Environment(AppServices.self) private var services
    let viewModel: DashboardViewModel

    @State private var expanded = false
    @State private var report: String?
    @State private var isLoading = false
    @State private var errorMessage: String?

    private let aiService = AiService()

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
                // Header — tap to expand/collapse
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        expanded.toggle()
                    }
                    // Auto-fetch on first expand
                    if expanded && report == nil && errorMessage == nil && canUseAi {
                        Task { await generateReport() }
                    }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "sparkles")
                            .foregroundStyle(Color.appAccent)
                        Text("AI Battery")
                            .font(.subheadline.weight(.semibold))
                        Text(services.userPreferences.aiProvider.label.uppercased())
                            .font(.caption2.weight(.bold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.appAccent.opacity(0.15), in: Capsule())
                            .foregroundStyle(Color.appAccent)
                        Spacer()
                        Image(systemName: "chevron.down")
                            .rotationEffect(.degrees(expanded ? 180 : 0))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .foregroundStyle(Color.appOnSurface)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if expanded {
                    // Current SOH display
                    if let soh = viewModel.telemetry.soh {
                        HStack(spacing: 8) {
                            Text("Current SOH")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(String(format: "%.0f%%", soh))
                                .font(.title3.weight(.bold))
                                .foregroundStyle(Color.appGreen)
                        }
                    }

                    // Quick stats summary
                    if let delta = viewModel.telemetry.cellVoltDelta {
                        VStack(alignment: .leading, spacing: 4) {
                            statsRow("Cell Delta", value: String(format: "%.0f mV", delta * 1000),
                                     color: delta > 0.03 ? Color.appAmber : Color.appGreen)
                        }
                    }

                    // AI content
                    if isLoading {
                        HStack(spacing: 8) {
                            ProgressView()
                            Text("Generating battery health report…")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    } else if let errorMessage {
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .font(.subheadline)
                            .foregroundStyle(Color.appAmber)
                    } else if let report {
                        Text(report)
                            .font(.ioniqBody)
                            .foregroundStyle(.primary)
                    } else if !canUseAi {
                        Label("Full AI battery health report available with Pro + API key.",
                              systemImage: "sparkles")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Tap \"Generate\" for a detailed AI analysis of battery degradation trends and recommendations.")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                        Button("Generate Report") {
                            Task { await generateReport() }
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(Color.appAccent)
                        .frame(maxWidth: .infinity)
                    }
                }
            }
            .padding(14)
        }
        .cardStyle(.secondary)
    }

    private var canUseAi: Bool {
        services.isPro && services.userPreferences.aiFeaturesEnabled && !(services.userPreferences.aiKey ?? "").isEmpty
    }

    private func generateReport() async {
        guard let apiKey = services.userPreferences.aiKey, !apiKey.isEmpty else {
            errorMessage = "Add an AI API key in Settings."
            return
        }
        guard services.isPro else {
            errorMessage = nil
            return
        }

        isLoading = true
        errorMessage = nil

        do {
            // Collect charge speed history from sessions
            let sessions = try services.tripLog.chargeSessions()
            let chargeSpeeds: [(Date, Double)] = sessions.compactMap { s in
                guard let endSoc = s.endSoc, endSoc > s.startSoc, s.endTime != nil,
                      s.energyAddedKwh > 0 else { return nil }
                let socRange = endSoc - s.startSoc
                let duration = s.endTime!.timeIntervalSince(s.startTime) / 60.0
                guard socRange > 0, duration > 0 else { return nil }
                let speedPerPercent = duration / Double(socRange)
                let estimated70 = speedPerPercent * 70
                return (s.startTime, estimated70)
            }

            // Voltage delta history (from current telemetry as single datapoint)
            let voltageDeltas: [Double] = viewModel.telemetry.cellVoltDelta.map { [Double($0)] } ?? []
            // SOH history (from current telemetry)
            let sohHistory: [(Date, Double)] = viewModel.telemetry.soh.map {
                [(Date(), Double($0))]
            } ?? []

            report = try await aiService.generateBatteryReport(
                sohHistory: sohHistory,
                voltageDeltas: voltageDeltas,
                chargeSpeeds: chargeSpeeds,
                apiKey: apiKey,
                aiProvider: services.userPreferences.aiProvider
            )
        } catch {
            errorMessage = error.localizedDescription
        }

        isLoading = false
    }

    // MARK: - Helpers

    private func statsRow(_ label: String, value: String, color: Color) -> some View {
        HStack {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.caption.weight(.semibold))
                .foregroundStyle(color)
        }
    }
}
