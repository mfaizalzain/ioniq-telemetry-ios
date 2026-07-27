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
                placeholder: "Gemini API key",
                initialValue: viewModel.preferences.geminiApiKey ?? "",
                onCommit: { viewModel.setGeminiKey($0) },
                helpTitle: KeyHelp.geminiTitle,
                helpURL: KeyHelp.gemini
            )
            .disabled(!viewModel.isPro)

            Toggle("Enable AI", isOn: Binding(
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
                Text("Apple Maps").tag(RoutingProvider.appleMaps)
                Text("OpenRouteService").tag(RoutingProvider.openRouteService)
                Text("Google Maps").tag(RoutingProvider.googleMaps)
            }

            if viewModel.preferences.routingProvider != .appleMaps {
                RoutingKeyField(viewModel: viewModel)
                GooglePoiSearchToggle(viewModel: viewModel)
                GoogleKeyField(viewModel: viewModel)
            }
        } header: {
            Text("Routing")
        } footer: {
            RoutingFooter(missingKey: viewModel.missingRoutingKey)
        }
    }
}

/// Opt-in Google Places destination search while still routing with OpenRouteService
/// — the Android build's "Google POI search" switch. Not shown for Google routing,
/// which already searches with Google.
private struct GooglePoiSearchToggle: View {
    let viewModel: SettingsViewModel

    var body: some View {
        if viewModel.preferences.routingProvider == .openRouteService {
            Toggle(isOn: Binding(
                get: { viewModel.preferences.googlePoiSearch },
                set: { viewModel.setGooglePoiSearch($0) }
            )) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Google POI search")
                    if viewModel.preferences.googlePoiSearch {
                        Text("For the best result")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}

/// The one and only Google key field.
///
/// Routing, POI search, charger data and occupancy alerts all authenticate with the
/// same Google Cloud key, so each feature owning its own entry box meant the same
/// string typed in several places. It appears as soon as any of them needs it.
struct GoogleKeyField: View {
    let viewModel: SettingsViewModel

    private var isNeeded: Bool {
        viewModel.preferences.routingProvider == .googleMaps
            || viewModel.preferences.googlePoiSearch
            || viewModel.preferences.chargerOccupancyAlerts
            || viewModel.preferences.chargerSource == .googlePlaces
    }

    var body: some View {
        if isNeeded {
            // Routing already shows its own key field for the Google provider.
            if viewModel.preferences.routingProvider != .googleMaps {
                SecretField(
                    placeholder: "Google Maps API key",
                    initialValue: viewModel.preferences.googleMapsApiKey ?? "",
                    onCommit: { viewModel.setGoogleMapsKey($0) },
                    helpTitle: KeyHelp.googleTitle,
                    helpURL: KeyHelp.google
                )
            }

            if (viewModel.preferences.googleMapsApiKey ?? "").isEmpty {
                Label(
                    "Google POI search and occupancy alerts need a key with the Places API enabled. Search falls back to OpenRouteService without one.",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.caption)
                .foregroundStyle(Color.appAmber)
            }
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
            // "your … key" rather than "a/an": the provider name is injected, and
            // "a OpenRouteService key" was wrong for one of the two providers.
            Text("Route planning needs your \(missingKey) key. Both providers have a free tier.")
                .foregroundStyle(Color.appAmber)
        } else {
            Text("Apple Maps is the default — no key, no billing. Switch to OpenRouteService or Google Maps for elevation data or broader POI search.\n\nOpenRouteService is free with a quick signup. Google Maps needs a Cloud project with billing set up. Either way the key is yours, so requests count against your own quota.")
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

    /// Seeded here rather than in `onAppear`. A section that adds or drops a row
    /// around this one — buying Pro removes the unlock button above the AI key
    /// field — reshuffles List row identity and hands the field fresh state; with
    /// `onAppear` seeding that fires only once per slot, the stored key silently
    /// vanished from the box.
    @State private var text: String
    @State private var isRevealed = false

    init(
        placeholder: String,
        initialValue: String,
        onCommit: @escaping (String) -> Void,
        helpTitle: String? = nil,
        helpURL: URL? = nil
    ) {
        self.placeholder = placeholder
        self.initialValue = initialValue
        self.onCommit = onCommit
        self.helpTitle = helpTitle
        self.helpURL = helpURL
        _text = State(initialValue: initialValue)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // The name of the key is a label in its own right. Leaving it as the
            // field's placeholder made an empty field read as a greyed-out caption,
            // with nothing to suggest it could be typed into.
            HStack(spacing: 6) {
                Text(placeholder.uppercased())
                    .font(.ioniqCaption)
                    .foregroundStyle(.secondary)
                    .ioniqStatLabel()
                if !text.isEmpty {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.caption2)
                        .foregroundStyle(Color.appGreen)
                        .accessibilityLabel("Key saved")
                }
            }

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
        .padding(.vertical, 4)
    }

    private var field: some View {
        HStack(spacing: 8) {
            Group {
                if isRevealed {
                    TextField("Tap to paste your key", text: $text)
                } else {
                    SecureField("Tap to paste your key", text: $text)
                }
            }
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .font(.system(size: 15, design: .monospaced))

            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tertiary)
                .accessibilityLabel("Clear key")
            }

            Button {
                isRevealed.toggle()
            } label: {
                Image(systemName: isRevealed ? "eye.slash" : "eye")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .accessibilityLabel(isRevealed ? "Hide key" : "Show key")
        }
        // A visible box, so the row looks like something you can type into.
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color.appSurfaceVariant, in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.appOutline, lineWidth: 1)
        )
        // Only real edits commit: the seed above is applied before the view is
        // installed, so it never round-trips through the repository.
        .onChange(of: text) { onCommit(text) }
        // A key pasted in from restore or another field while this one is on
        // screen still needs to show up.
        .onChange(of: initialValue) { _, new in
            if new != text { text = new }
        }
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


// MARK: - Charger data

/// Where charger locations come from.
///
/// Open Charge Map is the default and costs the user nothing — the app ships a
/// key. Google Places is offered because OCM coverage is thin in some regions, but
/// it bills the user's own key per request, so the trade is stated plainly rather
/// than buried.
struct ChargerSourceSection: View {
    let viewModel: SettingsViewModel

    var body: some View {
        Section {
            Picker("Source", selection: Binding(
                get: { viewModel.preferences.chargerSource },
                set: { viewModel.setChargerSource($0) }
            )) {
                Text("OCM + Apple Maps").tag(ChargerSource.combined)
                Text("Open Charge Map").tag(ChargerSource.openChargeMap)
                Text("Apple Maps").tag(ChargerSource.appleMaps)
                Text("Google Places").tag(ChargerSource.googlePlaces)
            }

            if viewModel.preferences.chargerSource == .googlePlaces {
                GoogleKeyField(viewModel: viewModel)
            }

            if viewModel.placesApiCalls > 0 {
                LabeledContent("Places calls this session", value: "\(viewModel.placesApiCalls)")
            }
        } header: {
            Text("Charger Data")
        } footer: {
            switch viewModel.preferences.chargerSource {
            case .googlePlaces:
                Text("Google Places covers areas where Open Charge Map is thin, and reports connector types and power. It has no price, network operator or access information, and it cannot search a bounding box — a route is covered by up to 12 circle queries, each one billed to your key.")
            case .appleMaps:
                Text("Apple Maps shows nearby charging stations with no key, no billing, and no quota. Location and name only — no pricing, connector or operator data.")
            case .openChargeMap:
                Text("Charger locations come from Open Charge Map. Free, and it carries price, operator and access data.")
            case .combined:
                Text("Merges Open Charge Map (pricing, connectors, operator) with Apple Maps (broader coverage). Duplicates within 200 m are removed, keeping OCM's richer data.")
            }
        }
    }
}

// MARK: - Charger availability

/// Live charger occupancy.
///
/// Just the switch: the Google key it authenticates with is entered once in the
/// Routing section, which reveals the field as soon as this is turned on.
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
                .foregroundStyle(Color.appAmber)
        } else {
            Text("Warns you when every charger with live status near your next stop is occupied.\n\nNeeds a Google Cloud key with the \u{201C}Places API (New)\u{201D} enabled — enter it once under Routing, where it also covers Google routing and POI search. Calls are billed to your account, so this stays off until you switch it on.")
        }
    }
}
