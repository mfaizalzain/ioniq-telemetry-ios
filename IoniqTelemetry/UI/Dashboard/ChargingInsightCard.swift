import CoreData
import CoreDomain
import SwiftUI

/// A card that displays AI-generated charging trend insights powered by AI.
/// Collapsed by default; user taps to expand and fetch. Result cached for the session.
struct ChargingInsightCard: View {
    @Environment(AppServices.self) private var services
    let viewModel: DashboardViewModel

    @State private var expanded = false
    @State private var insight: String?
    @State private var isLoading = false
    @State private var errorMessage: String?

    private let aiService = AiService()

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                // Header — tap to expand/collapse
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        expanded.toggle()
                    }
                    // Auto-fetch on first expand
                    if expanded && insight == nil && errorMessage == nil && canUseAi {
                        Task { await refresh() }
                    }
                } label: {
                    HStack {
                        Image(systemName: "bolt.brain")
                            .font(.caption)
                        Text("CHARGING INSIGHT")
                            .font(.ioniqCaption.weight(.medium))
                            .ioniqStatLabel()
                        Spacer()
                        Image(systemName: "chevron.down")
                            .rotationEffect(.degrees(expanded ? 180 : 0))
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    .foregroundStyle(.secondary)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if expanded {
                    if isLoading {
                        HStack(spacing: 8) {
                            ProgressView()
                                .scaleEffect(0.8)
                            Text("Analysing charge sessions…")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } else if let errorMessage {
                        VStack(alignment: .leading, spacing: 4) {
                            Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                                .font(.caption)
                                .foregroundStyle(Color.appAmber)
                            if canUseAi && !errorMessage.contains("Settings") {
                                Button("Try Again") {
                                    Task { await refresh() }
                                }
                                .font(.caption)
                                .tint(Color.appAccent)
                            }
                        }
                    } else if let insight {
                        Text(insight)
                            .font(.ioniqBody)
                            .foregroundStyle(.primary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else if !canUseAi {
                        VStack(alignment: .leading, spacing: 4) {
                            Label("Charging Insights are available with Pro and an API key.",
                                  systemImage: "sparkles")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        Text("Tap refresh to analyse recent charging sessions.")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            .padding(14)
        }
        .padding(.horizontal)
        .backgroundStyle(.ultraThinMaterial)
    }

    private var canUseAi: Bool {
        services.isPro && services.userPreferences.aiFeaturesEnabled && !(services.userPreferences.aiKey ?? "").isEmpty
    }

    private func refresh() async {
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
            let sessions = try services.tripLog.chargeSessions()
            insight = try await aiService.generateChargingInsight(
                chargeSessions: sessions,
                apiKey: apiKey,
                aiProvider: services.userPreferences.aiProvider
            )
        } catch {
            errorMessage = error.localizedDescription
        }

        isLoading = false
    }
}
