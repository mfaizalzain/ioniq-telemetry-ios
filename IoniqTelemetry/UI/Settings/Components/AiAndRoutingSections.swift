import CoreDomain
import CoreOBD
import CoreUI
import SwiftUI

// MARK: - AI

struct AiSection: View {
    let viewModel: SettingsViewModel
    @Binding var showPaywall: Bool

    var body: some View {
        Section {
            if !viewModel.isPro {
                Button {
                    showPaywall = true
                } label: {
                    Label("Unlock AI Features with Pro", systemImage: "lock.fill")
                }
                .tint(Color.appAccent)
            }

            SecretField(
                placeholder: "API key",
                initialValue: viewModel.preferences.geminiApiKey ?? "",
                onCommit: { viewModel.setGeminiKey($0) },
                helpTitle: KeyHelp.geminiTitle,
                helpURL: KeyHelp.gemini
            )
            .disabled(!viewModel.isPro)

            Toggle("Enable AI coaching", isOn: Binding(
                get: { viewModel.preferences.aiCoachingEnabled },
                set: { viewModel.setAiCoaching($0) }
            ))
            .disabled(!viewModel.isPro)
        } header: {
            AiSectionHeader(isPro: viewModel.isPro)
        } footer: {
            Text("Explains diagnostics, thermal limits and energy use in plain language while you drive.\n\nThe key is free: sign in at Google AI Studio, choose \u{201C}Create API key\u{201D}, and paste it above. Requests are billed to your account, not ours.")
        }
    }
}

private struct AiSectionHeader: View {
    let isPro: Bool

    var body: some View {
        HStack {
            Text("AI Assistant")
            if !isPro {
                Text("PRO")
                    .font(.caption2.weight(.bold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.appAccent.opacity(0.2), in: Capsule())
                    .foregroundStyle(Color.appAccent)
            }
        }
    }
}

// MARK: - Routing

struct RoutingSection: View {
    let viewModel: SettingsViewModel

    var body: some View {
        Section {
            Picker("Provider", selection: Binding(
                get: { viewModel.preferences.routingProvider },
                set: { viewModel.setRoutingProvider($0) }
            )) {
                Text("OpenRouteService").tag(RoutingProvider.openRouteService)
                Text("Google Maps").tag(RoutingProvider.googleMaps)
            }

            RoutingKeyField(viewModel: viewModel)
        } header: {
            Text("Routing")
        } footer: {
            RoutingFooter(missingKey: viewModel.missingRoutingKey)
        }
    }
}

/// One field, swapped by provider — each provider's key is stored separately so
/// switching back and forth doesn't discard the other one.
private struct RoutingKeyField: View {
    let viewModel: SettingsViewModel

    var body: some View {
        if viewModel.preferences.routingProvider == .openRouteService {
            SecretField(
                placeholder: "OpenRouteService key",
                initialValue: viewModel.preferences.orsApiKey ?? "",
                onCommit: { viewModel.setOrsKey($0) },
                helpTitle: KeyHelp.orsTitle,
                helpURL: KeyHelp.ors
            )
        } else {
            SecretField(
                placeholder: "Google Maps key",
                initialValue: viewModel.preferences.googleMapsApiKey ?? "",
                onCommit: { viewModel.setGoogleMapsKey($0) },
                helpTitle: KeyHelp.googleTitle,
                helpURL: KeyHelp.google
            )
        }
    }
}

private struct RoutingFooter: View {
    let missingKey: String?

    var body: some View {
        if let missingKey {
            Text("Route planning needs a \(missingKey) key. Both providers have a free tier.")
                .foregroundStyle(Color.amberWarn)
        } else {
            Text("OpenRouteService is the easier option — signup is an email and a token, no card, and it returns elevation. Google Maps needs a Cloud project with the Directions API enabled and billing set up.\n\nEither way the key is yours, so requests count against your own quota.")
        }
    }
}

// MARK: - Shared

/// Masked API-key field with a reveal toggle. Commits on every edit so a key
/// typed and then immediately backgrounded is still saved.
struct SecretField: View {
    let placeholder: String
    let initialValue: String
    let onCommit: (String) -> Void
    /// Where to obtain the key. Shown as a link under the field — a bare secure
    /// field tells the user nothing about where to go.
    var helpTitle: String? = nil
    var helpURL: URL? = nil

    @State private var text = ""
    @State private var isRevealed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            field
            if let helpTitle, let helpURL {
                Link(destination: helpURL) {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.up.right.square")
                        Text(helpTitle)
                    }
                    .font(.caption)
                }
                .tint(Color.appAccent)
            }
        }
    }

    private var field: some View {
        HStack {
            Group {
                if isRevealed {
                    TextField(placeholder, text: $text)
                } else {
                    SecureField(placeholder, text: $text)
                }
            }
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()

            Button {
                isRevealed.toggle()
            } label: {
                Image(systemName: isRevealed ? "eye.slash" : "eye")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .accessibilityLabel(isRevealed ? "Hide key" : "Show key")
        }
        .onAppear { text = initialValue }
        .onChange(of: text) { onCommit(text) }
    }
}

// MARK: - Key sources

enum KeyHelp {
    static let geminiTitle = "Get a free key at Google AI Studio"
    static let gemini = URL(string: "https://aistudio.google.com/apikey")!

    static let orsTitle = "Sign up at openrouteservice.org"
    static let ors = URL(string: "https://openrouteservice.org/dev/#/signup")!

    static let googleTitle = "Create a key in Google Cloud Console"
    static let google = URL(string: "https://console.cloud.google.com/apis/credentials")!
}


// MARK: - Charger availability

/// Live charger occupancy.
///
/// Its own section rather than a row under Routing: it is powered by the Google
/// Places API, not by the routing provider, and nesting it there meant its key
/// field was hidden whenever the user routed with OpenRouteService — so the
/// feature could never be switched on from the default settings.
struct ChargerAvailabilitySection: View {
    let viewModel: SettingsViewModel
    @Binding var showPaywall: Bool

    var body: some View {
        Section {
            if viewModel.isPro {
                Toggle("Charger occupancy alerts", isOn: Binding(
                    get: { viewModel.preferences.chargerOccupancyAlerts },
                    set: { viewModel.setChargerOccupancyAlerts($0) }
                ))

                SecretField(
                    placeholder: "Google Places API key",
                    initialValue: viewModel.preferences.googleMapsApiKey ?? "",
                    onCommit: { viewModel.setGoogleMapsKey($0) },
                    helpTitle: KeyHelp.googleTitle,
                    helpURL: KeyHelp.google
                )
            } else {
                Button {
                    showPaywall = true
                } label: {
                    LabeledContent {
                        Text("PRO")
                            .font(.caption2.weight(.bold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.appAccent.opacity(0.2), in: Capsule())
                            .foregroundStyle(Color.appAccent)
                    } label: {
                        Label("Charger occupancy alerts", systemImage: "bell.badge")
                    }
                }
                .tint(.primary)
            }
        } header: {
            Text("Charger Availability")
        } footer: {
            ChargerAvailabilityFooter(reason: viewModel.occupancyBlockedReason)
        }
    }
}

private struct ChargerAvailabilityFooter: View {
    let reason: String?

    var body: some View {
        if let reason {
            Text(reason)
                .foregroundStyle(Color.amberWarn)
        } else {
            Text("Warns you when every charger with live status near your next stop is occupied.\n\nNeeds a Google Cloud key with the \u{201C}Places API (New)\u{201D} enabled — the same key works for Google Maps routing. Calls are billed to your account, so this stays off until you switch it on.")
        }
    }
}
