import CoreData
import CoreDomain
import SwiftUI

/// A card/sheet view that displays an AI-generated battery health report including
/// SOH history, voltage balance trends, and charge speed degradation analysis.
struct BatteryHealthReportView: View {
    @Environment(AppServices.self) private var services
    let viewModel: DashboardViewModel

    @State private var report: String?
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var showSheet = false

    private let aiService = AiService()

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                // Header
                HStack {
                    Image(systemName: "heart.text.clipboard")
                        .font(.caption)
                    Text("BATTERY HEALTH REPORT")
                        .font(.ioniqCaption.weight(.medium))
                        .ioniqStatLabel()
                    Spacer()

                    if !isLoading {
                        Button {
                            showSheet = true
                        } label: {
                            HStack(spacing: 4) {
                                Text("View Report")
                                    .font(.caption.weight(.medium))
                                Image(systemName: "chevron.right")
                                    .font(.caption2)
                            }
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(Color.appAccent)
                        .disabled(!canUseAi)
                    }
                }
                .foregroundStyle(.secondary)

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

                // Status text
                if !canUseAi {
                    Label("Full AI battery health report available with Pro + Gemini key.",
                          systemImage: "sparkles")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Tap \"View Report\" for a detailed AI analysis of battery degradation trends and recommendations.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(14)
        }
        .padding(.horizontal)
        .backgroundStyle(.ultraThinMaterial)
        .sheet(isPresented: $showSheet) {
            reportSheet
        }
    }

    // MARK: - Sheet Content

    private var reportSheet: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // Current SOH big display
                    if let soh = viewModel.telemetry.soh {
                        VStack(spacing: 4) {
                            Text("STATE OF HEALTH")
                                .font(.ioniqCaption.weight(.medium))
                                .foregroundStyle(.secondary)
                            Text(String(format: "%.0f%%", soh))
                                .font(.system(size: 48, weight: .bold))
                                .foregroundStyle(Color.appGreen)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                    }

                    // Stats grid
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                        if let delta = viewModel.telemetry.cellVoltDelta {
                            statTile("Cell Delta", "\(String(format: "%.0f", delta * 1000)) mV",
                                     delta > 0.03 ? Color.appAmber : Color.appGreen)
                        }
                        if let soh = viewModel.telemetry.soh {
                            statTile("BMS SOH", String(format: "%.0f%%", soh), Color.appGreen)
                        }
                        if let packTemp = viewModel.packTempC {
                            statTile("Pack Temp", "\(packTemp)°C",
                                     packTemp > 45 ? Color.appAmber : Color.appGreen)
                        }
                    }

                    Divider()

                    // AI report content
                    if isLoading {
                        HStack(spacing: 8) {
                            ProgressView()
                            Text("Generating battery health report…")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding()
                    } else if let errorMessage {
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .font(.subheadline)
                            .foregroundStyle(Color.appAmber)
                    } else if let report {
                        Text(report)
                            .font(.ioniqBody)
                            .foregroundStyle(.primary)
                    } else {
                        Text("Tap generate to produce a detailed battery health analysis.")
                            .font(.subheadline)
                            .foregroundStyle(.tertiary)
                        Button("Generate Report") {
                            Task { await generateReport() }
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(Color.appAccent)
                        .frame(maxWidth: .infinity)
                    }
                }
                .padding()
            }
            .background(Color.appBackground)
            .navigationTitle("Battery Health")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Close") { showSheet = false }
                }
                ToolbarItem(placement: .topBarLeading) {
                    if report != nil && !isLoading {
                        Button("Regenerate") {
                            Task { await generateReport() }
                        }
                        .font(.caption)
                    }
                }
            }
        }
        .task {
            if report == nil && errorMessage == nil {
                await generateReport()
            }
        }
    }

    private var canUseAi: Bool {
        services.isPro && !(services.userPreferences.geminiApiKey ?? "").isEmpty
    }

    private func generateReport() async {
        guard let apiKey = services.userPreferences.geminiApiKey, !apiKey.isEmpty else {
            errorMessage = "Add a Gemini API key in Settings."
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
                apiKey: apiKey
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

    private func statTile(_ label: String, _ value: String, _ color: Color) -> some View {
        VStack(spacing: 4) {
            Text(label)
                .font(.ioniqCaption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.title3.weight(.bold))
                .foregroundStyle(color)
        }
        .frame(maxWidth: .infinity)
        .padding(10)
        .background(Color.appSurfaceVariant.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
    }
}
