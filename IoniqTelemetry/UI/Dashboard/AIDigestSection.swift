import CoreData
import CoreDomain
import CoreUI
import SwiftUI

/// AI-generated weekly or monthly driving digest section for the dashboard.
/// Requires Pro entitlement and an AI API key stored in user preferences.
/// Collapsed by default; user taps to expand and fetch. Result cached for the session.
struct AIDigestSection: View {
    let isPro: Bool
    let aiKey: String?
    let aiProvider: AiProvider
    let aiFeaturesEnabled: Bool
    let vehicleName: String
    let trips: [TripEntity]

    @State private var expanded = false
    @State private var digestText: String?
    @State private var selectedPeriod: DigestPeriod = .weekly
    @State private var lastFetchedPeriod: DigestPeriod = .weekly
    @State private var isLoading = false
    @State private var errorMessage: String?

    private let aiService = AiService()
    private let countryCode = Locale.current.region?.identifier
    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                // Header — tap to expand/collapse
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        expanded.toggle()
                    }
                    // Auto-fetch on first expand or when period changed
                    if expanded && (digestText == nil || selectedPeriod != lastFetchedPeriod)
                        && !isLoading
                        && isPro && aiFeaturesEnabled && aiKey?.isEmpty == false && !trips.isEmpty {
                        Task { await loadDigest() }
                    }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "sparkles")
                            .foregroundStyle(Color.appAccent)
                        Text("AI Digest")
                            .font(.subheadline.weight(.semibold))
                        Text(aiProvider.label.uppercased())
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
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if expanded {
                    // Period picker + refresh button
                    if isPro && aiFeaturesEnabled && aiKey?.isEmpty == false {
                        HStack(spacing: 8) {
                            periodPicker
                            Spacer()
                            if digestText != nil {
                                Button {
                                    Task { await loadDigest() }
                                } label: {
                                    Image(systemName: "arrow.clockwise")
                                        .font(.caption)
                                }
                                .buttonStyle(.plain)
                                .foregroundStyle(Color.appAccent)
                            }
                        }
                    }

                    if !isPro {
                        lockMessage
                    } else if !aiFeaturesEnabled {
                        featuresDisabledMessage
                    } else if aiKey == nil || aiKey?.isEmpty == true {
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
            }
            .padding(12)
        }
        .padding(.horizontal)
        .backgroundStyle(.ultraThinMaterial)
        .onChange(of: selectedPeriod) { _, newPeriod in
            if expanded && newPeriod != lastFetchedPeriod {
                Task { await loadDigest() }
            }
        }
    }

    @MainActor
    private func loadDigest() async {
        guard isPro, aiFeaturesEnabled, let apiKey = aiKey, !apiKey.isEmpty, !trips.isEmpty else { return }
        isLoading = true
        errorMessage = nil
        digestText = nil
        lastFetchedPeriod = selectedPeriod

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
                apiKey: apiKey,
                vehicleName: vehicleName,
                countryCode: countryCode,
                aiProvider: aiProvider
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
            Text("Add an API key in Settings to enable AI digests.")
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
