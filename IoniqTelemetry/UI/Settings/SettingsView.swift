import CoreDomain
import CoreOBD
import CoreUI
import SwiftUI

struct SettingsView: View {
    @Environment(AppServices.self) private var services
    @State private var viewModel: SettingsViewModel?
    @State private var showVehiclePicker = false
    @State private var showAdapterPicker = false
    @State private var showPaywall = false

    var body: some View {
        NavigationStack {
            Group {
                if let viewModel {
                    settingsList(viewModel)
                } else {
                    ProgressView()
                }
            }
            .background(Color.appBackground)
            .navigationTitle("Settings")
            .sheet(isPresented: $showVehiclePicker) {
                if let viewModel { VehiclePickerSheet(viewModel: viewModel) }
            }
            .sheet(isPresented: $showAdapterPicker) {
                if let viewModel { AdapterPickerSheet(viewModel: viewModel) }
            }
            .sheet(isPresented: $showPaywall) {
                PaywallView()
            }
        }
        .task {
            if viewModel == nil { viewModel = SettingsViewModel(services: services) }
        }
    }

    @ViewBuilder
    private func settingsList(_ viewModel: SettingsViewModel) -> some View {
        List {
            VehicleSection(viewModel: viewModel, showVehiclePicker: $showVehiclePicker)
            AdapterSection(viewModel: viewModel, showAdapterPicker: $showAdapterPicker)
            RoutingSection(viewModel: viewModel, showPaywall: $showPaywall)
            DataSection(viewModel: viewModel)
            AiSection(viewModel: viewModel, showPaywall: $showPaywall)
            DisplaySection(viewModel: viewModel)
            ProSection(viewModel: viewModel, showPaywall: $showPaywall)
            AboutSection()
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
    }
}

// MARK: - Vehicle

private struct VehicleSection: View {
    let viewModel: SettingsViewModel
    @Binding var showVehiclePicker: Bool

    var body: some View {
        Section("Vehicle") {
            Button {
                showVehiclePicker = true
            } label: {
                LabeledContent {
                    HStack(spacing: 6) {
                        Text(viewModel.vehicleName)
                        Image(systemName: "chevron.right")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                } label: {
                    Label("Model", systemImage: "car.fill")
                }
            }
            .tint(.primary)

            if let vehicle = viewModel.activeVehicle {
                LabeledContent("Usable capacity", value: String(format: "%.1f kWh", vehicle.usableKwh))
            }
            if let profileError = viewModel.profileError {
                Label(profileError, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(Color.appAmber)
            }
        }
    }
}

// MARK: - Pro

private struct ProSection: View {
    let viewModel: SettingsViewModel
    @Binding var showPaywall: Bool

    var body: some View {
        Section {
            if !viewModel.isPro {
                Button {
                    showPaywall = true
                } label: {
                    Label("Unlock Pro", systemImage: "sparkles")
                }
                .tint(Color.appAccent)
            }
        } footer: {
            Text(viewModel.isPro ? "Pro is active on this device." : "")
        }
    }
}

// MARK: - About

/// Outward-facing links. The privacy policy is the same page the Android build
/// links to, and App Review expects it reachable from inside the app, not only
/// from the store listing.
enum AppLinks {
    static let privacyPolicy = URL(string: "https://ioniq.faizalmzain.com/privacy")!
    /// Apple's standard EULA, which applies unless a custom one is supplied in
    /// App Store Connect.
    static let termsOfUse = URL(string: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/")!
}

private struct AboutSection: View {
    private var version: String {
        let bundle = Bundle.main
        let short = bundle.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
        let build = bundle.infoDictionary?["CFBundleVersion"] as? String ?? "—"
        return "\(short) (\(build))"
    }

    var body: some View {
        Section("About") {
            Link(destination: AppLinks.privacyPolicy) {
                Label("Privacy Policy", systemImage: "hand.raised.fill")
            }
            .tint(.primary)

            Link(destination: AppLinks.termsOfUse) {
                Label("Terms of Use", systemImage: "doc.text")
            }
            .tint(.primary)

            LabeledContent("Version", value: version)
        }
    }
}

// MARK: - Adapter

private struct AdapterSection: View {
    let viewModel: SettingsViewModel
    @Binding var showAdapterPicker: Bool

    var body: some View {
        Section("OBD Adapter") {
            LabeledContent {
                ConnectionBadge(state: ConnectionState(viewModel.connectionState))
            } label: {
                Label("Status", systemImage: "antenna.radiowaves.left.and.right")
            }

            if let name = viewModel.savedAdapterName {
                LabeledContent("Paired", value: name)
            }

            if viewModel.connectionState == .connected {
                Button("Disconnect", role: .destructive) {
                    Task { await viewModel.disconnect() }
                }
            } else {
                if viewModel.savedAdapterName != nil {
                    Button("Reconnect") {
                        Task { await viewModel.reconnectSaved() }
                    }
                    .disabled(viewModel.isConnecting)
                }
                Button {
                    showAdapterPicker = true
                } label: {
                    Label("Find Adapter", systemImage: "magnifyingglass")
                }
            }

            if viewModel.savedAdapterName != nil {
                Button("Forget Adapter", role: .destructive) {
                    Task { await viewModel.forgetAdapter() }
                }
            }

            if let error = viewModel.adapterError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(Color.appRed)
            }
        }
    }
}

// MARK: - AI

private struct AiSection: View {
    let viewModel: SettingsViewModel
    @Binding var showPaywall: Bool

    var body: some View {
        Section {
            if viewModel.isPro {
                SecretField(
                    placeholder: "Gemini API key",
                    initialValue: viewModel.preferences.geminiApiKey ?? "",
                    onCommit: { viewModel.setGeminiApiKey($0) },
                    helpTitle: "Get a key at Google AI Studio",
                    helpURL: URL(string: "https://aistudio.google.com/apikey")
                )

                Toggle(isOn: Binding(
                    get: { viewModel.preferences.aiCoachingEnabled },
                    set: { viewModel.setAiCoachingEnabled($0) }
                )) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("AI Coaching")
                        Text("Charging insights, battery reports & aiAssistant")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
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
                        VStack(alignment: .leading, spacing: 1) {
                            Label("Gemini AI Features", systemImage: "rectangle.3.group")
                            Text("Charging Intelligence, Battery Reports & AI AiAssistant")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .tint(.primary)
            }
        } header: {
            Text("AI & Intelligence")
        } footer: {
            if viewModel.isPro && (viewModel.preferences.geminiApiKey ?? "").isEmpty {
                Text("Add a Gemini API key to enable AI-powered features. Your own key means requests land on your free quota, not a shared pool. Your trip data, battery stats, and vehicle telemetry are sent to Google Gemini to generate responses.")
            } else if viewModel.isPro {
                Text("AI features use your Gemini API key. Battery Health Reports, Charging Insights, and the AI AiAssistant all draw from the same key. Your trip data and vehicle telemetry are sent to Google Gemini to generate responses.")
            } else {
                Text("Charging Intelligence, Battery Health Reports and the AI AiAssistant with vehicle context are Pro features that need a Gemini API key.")
            }
        }
    }
}
