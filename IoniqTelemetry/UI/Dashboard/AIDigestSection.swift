import CoreData
import CoreDomain
import CoreUI
import SwiftUI

/// AI-generated weekly or monthly driving digest section for the dashboard.
/// Requires Pro entitlement and a Gemini API key stored in user preferences.
struct AIDigestSection: View {
    let isPro: Bool
    let geminiApiKey: String?
    let aiFeaturesEnabled: Bool
    let trips: [TripEntity]

    @State private var digestText: String?
    @State private var selectedPeriod: DigestPeriod = .weekly
    @State private var isLoading = false
    @State private var errorMessage: String?

    private let aiService = AiService()

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                // Header
                HStack {
                    Label("AI DIGEST", systemImage: "calendar.badge.clock")
                        .font(.ioniqCaption)
                        .foregroundStyle(.secondary)
                        .ioniqStatLabel()
                    Spacer()
                    if isPro && aiFeaturesEnabled && geminiApiKey?.isEmpty == false {
                        periodPicker
                    }
                }

                if !isPro {
                    lockMessage
                } else if !aiFeaturesEnabled {
                    featuresDisabledMessage
                } else if geminiApiKey == nil || geminiApiKey?.isEmpty == true {
                    noKeyMessage
                } else if trips.isEmpty {
                    Text("No trips yet this \(selectedPeriod.label.lowercased()).")
                        .font(.subheadline)
                        .foregroundStyle(.tertiary)
                } else if let digestText {
                    Text(digestText)
                        .font(.subheadline)
                        .foregroundStyle(.primary)
                } else if isLoading {
                    HStack(spacing: 8) {
                        ProgressView()
                            .scaleEffect(0.8)
                        Text("Generating digest…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else if let errorMessage {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Could not generate digest")
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
        .task(id: selectedPeriod) {
            await loadDigest()
        }
    }

    @MainActor
    private func loadDigest() async {
        guard isPro, aiFeaturesEnabled, let apiKey = geminiApiKey, !apiKey.isEmpty, !trips.isEmpty else { return }
        isLoading = true
        errorMessage = nil
        digestText = nil

        let filteredTrips = trips.filter { trip in
            let age = Date().timeIntervalSince(trip.startTime)
            switch selectedPeriod {
            case .weekly: return age <= 7 * 24 * 3600
            case .monthly: return age <= 30 * 24 * 3600
            }
        }

        guard !filteredTrips.isEmpty else {
            digestText = "No trips recorded this \(selectedPeriod.label.lowercased())."
            isLoading = false
            return
        }

        do {
            digestText = try await aiService.generateDigest(
                trips: filteredTrips,
                period: selectedPeriod,
                apiKey: apiKey
            )
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    private var periodPicker: some View {
        Picker("Period", selection: $selectedPeriod) {
            Text("Weekly").tag(DigestPeriod.weekly)
            Text("Monthly").tag(DigestPeriod.monthly)
        }
        .pickerStyle(.segmented)
        .frame(width: 180)
    }

    private var lockMessage: some View {
        HStack(spacing: 8) {
            Image(systemName: "lock.fill")
                .font(.caption)
                .foregroundStyle(.tertiary)
            Text("Unlock Pro for AI driving digests.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var noKeyMessage: some View {
        HStack(spacing: 8) {
            Image(systemName: "key.fill")
                .font(.caption)
                .foregroundStyle(.tertiary)
            Text("Add a Gemini API key in Settings to enable AI digests.")
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
