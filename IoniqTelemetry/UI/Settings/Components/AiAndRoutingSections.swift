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
                onCommit: { viewModel.setGeminiKey($0) }
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
            Text("Explains diagnostics, thermal limits, and energy use in plain language while you drive. Bring your own key — requests are billed to your account.")
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

            Toggle("Charger occupancy alerts", isOn: Binding(
                get: { viewModel.preferences.chargerOccupancyAlerts },
                set: { viewModel.setChargerOccupancyAlerts($0) }
            ))
            .disabled(!viewModel.isPro)
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
                onCommit: { viewModel.setOrsKey($0) }
            )
        } else {
            SecretField(
                placeholder: "Google Maps key",
                initialValue: viewModel.preferences.googleMapsApiKey ?? "",
                onCommit: { viewModel.setGoogleMapsKey($0) }
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
            Text("Requests use your own key, so they count against your quota rather than a shared one.")
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

    @State private var text = ""
    @State private var isRevealed = false

    var body: some View {
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
