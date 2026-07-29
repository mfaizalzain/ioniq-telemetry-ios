import CoreData
import CoreDomain
import CoreUI
import SwiftUI

/// AI-generated post-trip briefing card, shown on the trip detail screen.
/// Requires Pro entitlement and an AI API key stored in user preferences.
/// Matches Android's PostTripBriefingCard: no auto-fetch, user taps Generate.
/// Briefing is persisted on the trip entity so it survives navigation.
struct PostTripBriefingView: View {
    let trip: TripEntity
    let recentTrips: [TripEntity]
    let samples: [SampleEntity]
    let isPro: Bool
    let aiKey: String?
    let aiProvider: AiProvider
    let aiFeaturesEnabled: Bool
    let efficiencyBaseline: Double?

    @Environment(\.modelContext) private var modelContext
    @Environment(AppServices.self) private var services
    @State private var isLoading = false
    @State private var errorMessage: String?

    private let aiService = AiService()

    private var vehicleName: String {
        Ioniq5Constants.vehicleNameFor(services.preferences.currentPreferences.activeProfileId)
    }
    private var usableBatteryKwh: Double {
        Double(Ioniq5Constants.usableKwhForProfile(
            services.preferences.currentPreferences.activeProfileId,
            customKwh: services.preferences.currentPreferences.customUsableBatteryKwh
        ))
    }
    private var countryCode: String? {
        Locale.current.region?.identifier
    }

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                // Header with provider badge matching Android
                HStack {
                    Label("AI TRIP BRIEFING", systemImage: "wand.and.stars")
                        .font(.ioniqCaption)
                        .foregroundStyle(.secondary)
                        .ioniqStatLabel()
                    Spacer()
                    Text(aiProvider.label.uppercased())
                        .font(.caption2.weight(.bold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.appAccent.opacity(0.15), in: Capsule())
                        .foregroundStyle(Color.appAccent)
                }

                if !isPro {
                    lockMessage
                } else if !aiFeaturesEnabled {
                    featuresDisabledMessage
                } else if aiKey == nil || aiKey?.isEmpty == true {
                    noKeyMessage
                } else if let briefing = trip.aiBriefing {
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
                } else {
                    // Generate button — matching Android: user decides when
                    Button {
                        Task { await loadBriefing() }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "sparkles")
                                .font(.caption)
                            Text("Generate trip briefing")
                                .font(.subheadline)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Color.appAccent)
                    .foregroundStyle(Color.appOnAccent)
                }
            }
            .padding(12)
        }
        .padding(.horizontal)
        .backgroundStyle(.ultraThinMaterial)
    }

    @MainActor
    private func loadBriefing() async {
        guard isPro, aiFeaturesEnabled, let apiKey = aiKey, !apiKey.isEmpty, trip.aiBriefing == nil, !isLoading else { return }
        isLoading = true
        errorMessage = nil
        do {
            let text = try await aiService.generatePostTripBriefing(
                trip: trip,
                recentTrips: recentTrips,
                telemetrySamples: samples,
                efficiencyBaseline: efficiencyBaseline,
                vehicleName: vehicleName,
                usableBatteryKwh: usableBatteryKwh,
                apiKey: apiKey,
                aiProvider: aiProvider,
                countryCode: countryCode
            )
            trip.aiBriefing = text
            try modelContext.save()
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
