import CoreDomain
import CoreOBD
import CoreUI
import SwiftUI

// MARK: - Routing

struct RoutingSection: View {
    let viewModel: SettingsViewModel
    @Binding var showPaywall: Bool

    var body: some View {
        Section {
            // — Provider —
            Picker("Provider", selection: Binding(
                get: { viewModel.preferences.routingProvider },
                set: { viewModel.setRoutingProvider($0) }
            )) {
                Text("Apple Maps").tag(RoutingProvider.appleMaps)
                Text("OpenRouteService").tag(RoutingProvider.openRouteService)
                Text("Google Maps").tag(RoutingProvider.googleMaps)
            }

            if viewModel.preferences.routingProvider == .openRouteService {
                RoutingKeyField(viewModel: viewModel)
                GooglePoiSearchToggle(viewModel: viewModel)
            } else if viewModel.preferences.routingProvider == .googleMaps {
                RoutingKeyField(viewModel: viewModel)
            }

            // — Charger data source —
            Picker("Charger Source", selection: Binding(
                get: { viewModel.preferences.chargerSource },
                set: { viewModel.setChargerSource($0) }
            )) {
                Text("OCM + Apple Maps").tag(ChargerSource.combined)
                Text("Open Charge Map").tag(ChargerSource.openChargeMap)
                Text("Apple Maps").tag(ChargerSource.appleMaps)
                Text("Google Places").tag(ChargerSource.googlePlaces)
            }

            if viewModel.placesApiCalls > 0 {
                LabeledContent("Places calls this session", value: "\(viewModel.placesApiCalls)")
            }

            // — Charger occupancy alerts —
            let hasGoogleKey = !(viewModel.preferences.googleMapsApiKey ?? "").isEmpty
            if viewModel.isPro {
                Toggle("Charger occupancy alerts", isOn: Binding(
                    get: { viewModel.preferences.chargerOccupancyAlerts && hasGoogleKey },
                    set: { newValue in
                        if hasGoogleKey {
                            viewModel.setChargerOccupancyAlerts(newValue)
                        }
                    }
                ))
                .disabled(!hasGoogleKey)
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

            GoogleKeyField(viewModel: viewModel)
        } header: {
            Text("Routing")
        } footer: {
            VStack(alignment: .leading, spacing: 8) {
                if let missingKey = viewModel.missingRoutingKey {
                    Text("Route planning needs your \(missingKey) key. Both providers have a free tier.")
                        .foregroundStyle(Color.appAmber)
                } else {
                    Text("Apple Maps is the default — no key, no billing. Switch to OpenRouteService or Google Maps for elevation data or broader POI search.")
                }

                ChargerSourceFooter(source: viewModel.preferences.chargerSource)

                if let reason = viewModel.occupancyBlockedReason {
                    Text(reason)
                        .foregroundStyle(Color.appAmber)
                } else {
                    Text("Warns you when every charger with live status near your next stop is occupied. Needs a Google Cloud key with the Places API (New) enabled — enter it above.")
                }
            }
        }
    }
}

private struct ChargerSourceFooter: View {
    let source: ChargerSource

    var body: some View {
        switch source {
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
            || viewModel.isPro
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
    static let orsTitle = "Sign up at openrouteservice.org"
    static let ors = URL(string: "https://openrouteservice.org/dev/#/signup")!

    static let googleTitle = "Create a key in Google Cloud Console"
    static let google = URL(string: "https://console.cloud.google.com/apis/credentials")!
}
