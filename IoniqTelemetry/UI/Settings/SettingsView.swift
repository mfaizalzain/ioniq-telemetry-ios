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
            .background(Color.deepNavy)
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
            AiSection(viewModel: viewModel, showPaywall: $showPaywall)
            RoutingSection(viewModel: viewModel)
            UnitsSection(viewModel: viewModel)
            AppearanceSection(viewModel: viewModel)
            ProSection(viewModel: viewModel, showPaywall: $showPaywall)
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
                    .foregroundStyle(Color.amberWarn)
            }
        }
    }
}

// MARK: - Units / Appearance / Pro

private struct UnitsSection: View {
    let viewModel: SettingsViewModel

    var body: some View {
        Section("Units") {
            Picker("Units", selection: Binding(
                get: { viewModel.preferences.unitSystem },
                set: { viewModel.setUnitSystem($0) }
            )) {
                Text("Metric").tag(UnitSystem.metric)
                Text("Imperial").tag(UnitSystem.imperial)
            }
            .pickerStyle(.segmented)
        }
    }
}

private struct AppearanceSection: View {
    let viewModel: SettingsViewModel

    var body: some View {
        Section("Appearance") {
            Picker("Theme", selection: Binding(
                get: { viewModel.preferences.themeMode },
                set: { viewModel.setThemeMode($0) }
            )) {
                Text("System").tag(ThemeMode.system)
                Text("Light").tag(ThemeMode.light)
                Text("Dark").tag(ThemeMode.dark)
            }
            .pickerStyle(.segmented)
        }
    }
}

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
                .tint(Color.electricTeal)
            }
        } footer: {
            Text(viewModel.isPro ? "Pro is active on this device." : "")
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
                    .foregroundStyle(Color.redAlert)
            }
        }
    }
}
