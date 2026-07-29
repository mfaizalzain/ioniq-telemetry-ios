import CoreData
import CoreDomain
import CoreUI
import SwiftUI

/// AI-generated post-trip briefing card, shown on the trip detail screen.
/// Requires Pro entitlement and a Gemini API key stored in user preferences.
struct PostTripBriefingView: View {
    let trip: TripEntity
    let recentTrips: [TripEntity]
    let samples: [SampleEntity]
    let isPro: Bool
    let geminiApiKey: String?
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
                } else if geminiApiKey == nil || geminiApiKey?.isEmpty == true {
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
        guard isPro, let apiKey = geminiApiKey, !apiKey.isEmpty, briefing == nil, !isLoading else { return }
        isLoading = true
        errorMessage = nil
        do {
            briefing = try await aiService.generatePostTripBriefing(
                trip: trip,
                recentTrips: recentTrips,
                telemetrySamples: samples,
                efficiencyBaseline: efficiencyBaseline,
                apiKey: apiKey
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
            Text("Add a Gemini API key in Settings to enable AI briefings.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
