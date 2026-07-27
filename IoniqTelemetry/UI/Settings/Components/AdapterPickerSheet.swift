import CoreDomain
import CoreOBD
import CoreUI
import SwiftUI

/// Bluetooth adapter discovery, plus a manual entry for WiFi ELM327 adapters
/// (which advertise nothing over BLE and so can never be scanned for).
struct AdapterPickerSheet: View {
    let viewModel: SettingsViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var wifiAddress = ""

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if viewModel.discoveredAdapters.isEmpty {
                        HStack(spacing: 10) {
                            ProgressView()
                            Text(viewModel.isScanning ? "Scanning…" : "No adapters found")
                                .foregroundStyle(.secondary)
                        }
                    }
                    ForEach(viewModel.discoveredAdapters) { discovery in
                        Button {
                            Task {
                                await viewModel.connect(to: discovery.device)
                                if viewModel.adapterError == nil { dismiss() }
                            }
                        } label: {
                            LabeledContent {
                                SignalBars(rssi: discovery.rssi)
                            } label: {
                                Text(discovery.device.name)
                            }
                        }
                        .tint(.primary)
                    }
                } header: {
                    Text("Bluetooth")
                } footer: {
                    Text("iOS has no Bluetooth Classic support for OBD adapters — only BLE adapters appear here.")
                }

                Section {
                    TextField("192.168.0.10:35000", text: $wifiAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                    Button("Connect") {
                        Task {
                            await viewModel.connectWifi(address: wifiAddress)
                            if viewModel.adapterError == nil { dismiss() }
                        }
                    }
                    .disabled(wifiAddress.trimmingCharacters(in: .whitespaces).isEmpty)
                } header: {
                    Text("WiFi Adapter")
                } footer: {
                    Text("Join the adapter's WiFi network first, then enter its address.")
                }

                if let error = viewModel.adapterError {
                    Section {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(Color.appRed)
                    }
                }
            }
            .navigationTitle("Find Adapter")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .overlay {
                if viewModel.isConnecting {
                    ProgressView("Connecting…")
                        .padding(24)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                }
            }
        }
        .task {
            viewModel.startScan()
        }
        .onDisappear {
            viewModel.stopScan()
        }
    }
}

/// RSSI as three bars. -60 dBm and stronger is effectively full scale for a
/// dongle sitting in the OBD port a metre away.
struct SignalBars: View {
    let rssi: Int

    private var filledBars: Int {
        switch rssi {
        case (-60)...: return 3
        case (-75)..<(-60): return 2
        default: return 1
        }
    }

    var body: some View {
        HStack(spacing: 2) {
            ForEach(1...3, id: \.self) { bar in
                Capsule()
                    .fill(bar <= filledBars ? Color.appAccent : Color.appOutline)
                    .frame(width: 3, height: CGFloat(4 + bar * 3))
            }
        }
        .accessibilityLabel("Signal strength \(filledBars) of 3")
    }
}

