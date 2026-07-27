import SwiftUI
import CoreUI

struct SettingsView: View {
    @Environment(AppServices.self) private var services
    @State private var showVehiclePicker = false
    @State private var selectedVehicle = "ioniq5_2022_77kwh"
    @State private var unitSystem: Unit = .metric
    @State private var geminiKey = ""
    @State private var showGeminiKey = false
    @State private var mapsKey = ""
    @State private var aiCoachingEnabled = false
    @State private var chargerAlerts = false

    enum Unit: String, CaseIterable { case metric, imperial }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button {
                        showVehiclePicker = true
                    } label: {
                        HStack {
                            Text("IONIQ 5 — 77.4 kWh")
                                .foregroundStyle(.primary)
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                    }
                } header: {
                    Text("Vehicle")
                }

                Section {
                    HStack {
                        Text("Status")
                        Spacer()
                        Text("Not Connected")
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("OBD Adapter")
                }

                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Image(systemName: "sparkles")
                                .foregroundStyle(Color(red: 0.09, green: 0.91, blue: 0.76))
                            Text("AI Assistant (BYOK)")
                                .font(.headline)
                        }
                        HStack {
                            TextField("Gemini API Key", text: $geminiKey)
                                .textFieldStyle(.roundedBorder)
                            Button {
                                showGeminiKey.toggle()
                            } label: {
                                Image(systemName: showGeminiKey ? "eye" : "eye.slash")
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Toggle("Enable AI Coaching", isOn: $aiCoachingEnabled)
                            .tint(Color(red: 0.09, green: 0.91, blue: 0.76))
                    }
                } header: {
                    Text("AI Assistant")
                } footer: {
                    Text("Bring your own Gemini API key. AI features: trip planning, smart charging advice, thermal insights, driving coaching.")
                }

                Section {
                    Toggle("Google Maps Routing", isOn: .constant(false))
                        .tint(Color(red: 0.09, green: 0.91, blue: 0.76))
                    Toggle("Charger Occupancy Alerts", isOn: $chargerAlerts)
                        .tint(Color(red: 0.09, green: 0.91, blue: 0.76))
                    TextField("Google Maps API Key", text: $mapsKey)
                        .textFieldStyle(.roundedBorder)
                } header: {
                    Text("Routing")
                } footer: {
                    Text("BYOK — Bring Your Own API Key. Google Maps routing is free with your own key.")
                }

                Section {
                    Picker("Unit System", selection: $unitSystem) {
                        Text("km / kWh/100km").tag(Unit.metric)
                        Text("mi / mi/kWh").tag(Unit.imperial)
                    }
                    .pickerStyle(.segmented)
                } header: {
                    Text("Units")
                }

                Section {
                    Picker("Theme", selection: .constant("dark")) {
                        Text("System").tag("system")
                        Text("Light").tag("light")
                        Text("Dark").tag("dark")
                    }
                } header: {
                    Text("Appearance")
                }

                Section {
                    Button("Backup Trips") {}
                    Button("Restore Backup") {}
                } header: {
                    Text("Data")
                }

                Section {
                    Button("Console") {}
                } header: {
                    Text("Advanced")
                }
            }
            .scrollContentBackground(.hidden)
            .background(Color(red: 0.043, green: 0.071, blue: 0.125))
            .navigationTitle("Settings")
        }
    }
}
