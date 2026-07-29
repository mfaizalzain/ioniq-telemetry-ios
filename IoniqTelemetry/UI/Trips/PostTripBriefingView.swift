import CoreData
import CoreDomain
import CoreUI
import SwiftUI

/// AI-generated post-trip briefing card, shown on the trip detail screen.
/// Requires Pro entitlement and an AI API key stored in user preferences.
struct PostTripBriefingView: View {
    let trip: TripEntity
    let recentTrips: [TripEntity]
    let samples: [SampleEntity]
    let isPro: Bool
    let aiKey: String?
    let aiProvider: AiProvider
    let aiFeaturesEnabled: Bool
    let efficiencyBaseline: Double?

    @State private var briefing: String?
    @State private var isLoading = false
    @State private var errorMessage: String?

    private let aiService = AiService()

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                // Header
                Label("AI TRIP BRIEFING", systemImage: "wand.and.stars")
                    .font(.ioniqCaption)
                    .foregroundStyle(.secondary)
                    .ioniqStatLabel()

                if !isPro {
                    lockMessage
                } else if !aiFeaturesEnabled {
                    featuresDisabledMessage
                } else if aiKey == nil || aiKey?.isEmpty == true {
                    noKeyMessage
                } else if let briefing {
                    Text(briefing)
                        .font(.subheadline)
                        .foregroundStyle(.primary)
                } else if isLoading {
                    HStack(spacing: 8) {
                        ProgressView()
                            .scaleEffect(0.8)
                        Text("Analysing trip…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else if let errorMessage {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Could not generate briefing")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(Color.appAmber)
                        Text(errorMessage)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            .padding(12)
        }
        .padding(.horizontal)
        .backgroundStyle(.ultraThinMaterial)
        .task {
            await loadBriefing()
        }
    }

    @MainActor
    private func loadBriefing() async {
        guard isPro, aiFeaturesEnabled, let apiKey = aiKey, !apiKey.isEmpty, briefing == nil, !isLoading else { return }
        isLoading = true
        errorMessage = nil
        do {
            briefing = try await aiService.generatePostTripBriefing(
                trip: trip,
                recentTrips: recentTrips,
                telemetrySamples: samples,
                efficiencyBaseline: efficiencyBaseline,
                apiKey: apiKey,
                aiProvider: aiProvider
            )
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    private var lockMessage: some View {
        HStack(spacing: 8) {
            Image(systemName: "lock.fill")
                .font(.caption)
                .foregroundStyle(.tertiary)
            Text("Unlock Pro for AI trip briefings.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var noKeyMessage: some View {
        HStack(spacing: 8) {
            Image(systemName: "key.fill")
                .font(.caption)
                .foregroundStyle(.tertiary)
            Text("Add an API key in Settings to enable AI briefings.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var featuresDisabledMessage: some View {
        HStack(spacing: 8) {
            Image(systemName: "poweroff")
                .font(.caption)
                .foregroundStyle(.tertiary)
            Text("AI Features are turned off. Enable them in Settings.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
