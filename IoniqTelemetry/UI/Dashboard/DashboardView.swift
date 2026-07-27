import CoreDomain
import CoreUI
import SwiftUI

struct DashboardView: View {
    @Environment(AppServices.self) private var services
    @Binding var selectedTab: AppTab
    @State private var viewModel: DashboardViewModel?
    @State private var showCopilot = false

    var body: some View {
        NavigationStack {
            Group {
                if let viewModel {
                    // Nothing has ever arrived from an adapter, so every tile would
                    // be an em dash with no hint as to why. The Trips tab already
                    // explains itself when empty; this one should too.
                    if !viewModel.hasData && !viewModel.hasEverReceivedData {
                        NotConnectedView { selectedTab = .settings }
                    } else {
                        content(viewModel)
                    }
                } else {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .background(Color.appBackground)
            // The vehicle is the title: the tab bar already says "Dashboard", and a
            // separate in-content header repeated both.
            .navigationTitle(viewModel?.vehicleName ?? "")
            .toolbar {
                if let viewModel {
                    ToolbarItem(placement: .topBarTrailing) {
                        ConnectionBadge(state: ConnectionState(viewModel.connectionState), style: .plain)
                    }
                }
                if viewModel?.canUseCopilot == true {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            showCopilot = true
                        } label: {
                            Image(systemName: "sparkles")
                        }
                        .tint(Color.appAccent)
                        .accessibilityLabel("AI Assistant")
                    }
                }
            }
            .sheet(isPresented: $showCopilot) {
                CopilotView()
            }
        }
        .task {
            if viewModel == nil { viewModel = DashboardViewModel(services: services) }
        }
    }

    private func content(_ viewModel: DashboardViewModel) -> some View {
        ScrollView {
            LazyVStack(spacing: 16) {
                // Readings survive the adapter dropping, which is useful — but only
                // if it is clear they are a snapshot rather than live.
                if !viewModel.hasData {
                    StaleDataBanner(lastUpdated: viewModel.lastUpdatedText)
                }

                BatteryHeroCard(viewModel: viewModel)
                MetricTilesGrid(viewModel: viewModel)
                TirePressureVisualizerCard(viewModel: viewModel)

                if let tip = viewModel.thermalTip {
                    ThermalTipCard(tip: tip)
                }
            }
            .padding(.vertical)
        }
    }
}

// MARK: - Disconnected states

private struct NotConnectedView: View {
    let onOpenSettings: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "cable.connector.slash")
                .font(.system(size: 56))
                .foregroundStyle(.tertiary)
            Text("No Adapter Connected")
                .font(.title2.weight(.medium))
                .foregroundStyle(.secondary)
            Text("Plug an OBD-II adapter into your car's port and pair it to see live battery, power and tyre data here.")
                .font(.body)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
            Button("Set Up Adapter", action: onOpenSettings)
                .buttonStyle(.borderedProminent)
                .tint(Color.appAccent)
                .foregroundStyle(Color.appOnAccent)
                .padding(.top, 4)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
}

private struct StaleDataBanner: View {
    let lastUpdated: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.circle.fill")
            VStack(alignment: .leading, spacing: 1) {
                Text("Adapter disconnected")
                    .font(.subheadline.weight(.medium))
                Text("Showing the last reading, \(lastUpdated).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .foregroundStyle(Color.appAmber)
        .padding(12)
        .background(Color.appSurfaceVariant, in: RoundedRectangle(cornerRadius: 10))
        .padding(.horizontal)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Battery Hero Card

struct BatteryHeroCard: View {
    let viewModel: DashboardViewModel

    /// Gauge geometry, shared with the Android build: a 220° arc starting at 160°,
    /// leaving a 140° gap centred at the bottom.
    private static let startAngle: Double = 160
    private static let sweepFraction: CGFloat = 220.0 / 360.0

    private var socPercent: Float? { viewModel.socPercent }
    private var fillFraction: Float { min(max((socPercent ?? 0) / 100, 0), 1) }

    var body: some View {
        GroupBox {
            VStack(spacing: 10) {
                ZStack {
                    // SwiftUI trims clockwise from 3 o'clock, so the 160° rotation
                    // puts the 140° gap centred at the bottom.
                    Circle()
                        .trim(from: 0, to: Self.sweepFraction)
                        .stroke(Color.appOutline, style: StrokeStyle(lineWidth: 12, lineCap: .round))
                        .rotationEffect(.degrees(Self.startAngle))
                        .frame(width: 120, height: 120)

                    Circle()
                        .trim(from: 0, to: Self.sweepFraction * CGFloat(fillFraction))
                        .stroke(
                            AngularGradient(
                                colors: [.appAccent.opacity(0.75), .electricTeal],
                                center: .center,
                                startAngle: .degrees(Self.startAngle),
                                endAngle: .degrees(Self.startAngle + 220)
                            ),
                            style: StrokeStyle(lineWidth: 12, lineCap: .round)
                        )
                        .rotationEffect(.degrees(Self.startAngle))
                        .frame(width: 120, height: 120)
                        .animation(.easeOut(duration: 0.4), value: fillFraction)

                    HStack(alignment: .firstTextBaseline, spacing: 1) {
                        Text(socPercent.map { String(format: "%.0f", $0) } ?? "—")
                            .font(.system(size: 32, weight: .bold))
                            .tracking(-1.5)
                        Text("%")
                            .font(.system(size: 16, weight: .medium))
                    }
                    .foregroundStyle(Color.appOnSurface)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("State of charge")
                .accessibilityValue(socPercent.map { "\(Int($0.rounded())) percent" } ?? "No data")

                if viewModel.telemetry.isCharging {
                    ChargingChip(viewModel: viewModel)
                }

                HStack(spacing: 16) {
                    statBadge(
                        label: "BMS SOC",
                        value: viewModel.telemetry.socBms.map { String(format: "%.1f%%", $0) } ?? "—"
                    )
                    statBadge(
                        label: "HEALTH SOH",
                        value: viewModel.telemetry.soh.map { String(format: "%.0f%%", $0) } ?? "—"
                    )
                    statBadge(
                        label: "PACK TEMP",
                        value: viewModel.temperature(viewModel.packTempC.map(Float.init)),
                        color: .packTemp(viewModel.packTempC)
                    )
                }
            }
            .padding(20)
        }
        .padding(.horizontal)
        .backgroundStyle(.ultraThinMaterial)
    }

    private func statBadge(label: String, value: String, color: Color = .appOnSurface) -> some View {
        VStack(spacing: 4) {
            Text(label)
                .font(.ioniqCaption)
                .foregroundStyle(.secondary)
                .ioniqStatLabel()
            Text(value)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(color)
        }
        .frame(maxWidth: .infinity)
        .padding(8)
        .background(Color.appSurfaceVariant.opacity(0.6))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .combine)
    }
}

private struct ChargingChip: View {
    let viewModel: DashboardViewModel

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "bolt.fill")
            Text(viewModel.telemetry.chargeType?.rawValue ?? "Charging")
            if let power = viewModel.telemetry.powerKw {
                Text(String(format: "%.1f kW", abs(power)))
                    .fontWeight(.semibold)
            }
        }
        .font(.caption)
        .foregroundStyle(Color.appGreen)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color.appGreen.opacity(0.15))
        .clipShape(Capsule())
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Metric Tiles

struct MetricTilesGrid: View {
    let viewModel: DashboardViewModel

    private var telemetry: VehicleTelemetry { viewModel.telemetry }

    var body: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
            MetricTile(
                icon: "bolt.fill",
                label: viewModel.isRegenerating ? "POWER · REGEN" : "POWER",
                value: DashboardViewModel.format(telemetry.powerKw, unit: "kW", decimals: 1),
                valueColor: viewModel.isRegenerating ? .appGreen : .appOnSurface
            )
            MetricTile(
                icon: "chart.line.uptrend.xyaxis",
                label: "CELL Δ",
                // cellVoltDelta is in volts; millivolts is the readable unit here.
                value: telemetry.cellVoltDelta.map { String(format: "%.0f mV", $0 * 1000) } ?? "—",
                valueColor: .cellDelta(telemetry.cellVoltDelta)
            )
            MetricTile(
                icon: "battery.100percent.bolt",
                label: "HV VOLTAGE",
                value: DashboardViewModel.format(telemetry.packVoltage, unit: "V", decimals: 0),
                valueColor: .appAccent
            )
            MetricTile(
                icon: "battery.25percent",
                label: "AUX BATTERY",
                value: DashboardViewModel.format(telemetry.auxVoltage, unit: "V", decimals: 1),
                // Below ~12.0 V the 12 V battery is draining faster than the DC-DC
                // replaces it — the classic E-GMP no-start warning.
                valueColor: (telemetry.auxVoltage ?? 12.6) < 12.0 ? .appAmber : .appGreen
            )
        }
        .padding(.horizontal, 12)
    }
}

// MARK: - Tire Pressure

struct TirePressureVisualizerCard: View {
    let viewModel: DashboardViewModel

    /// Below this an E-GMP tire is meaningfully under-inflated.
    private static let lowPressureKpa: Float = 220

    var body: some View {
        GroupBox {
            VStack(spacing: 8) {
                HStack {
                    Image(systemName: "tire")
                    Text("TIRE PRESSURE")
                        .font(.ioniqCaption.weight(.medium))
                        .ioniqStatLabel()
                    Spacer()
                }
                .foregroundStyle(.secondary)

                let pressures = viewModel.telemetry.tirePressuresKpa
                let temps = viewModel.telemetry.tireTempsC

                HStack(spacing: 12) {
                    tireSquare("FL", pressures?.fl, temps?.fl)
                    Spacer()
                    Image(systemName: "car.fill")
                        .font(.title)
                        .foregroundStyle(.secondary)
                    Spacer()
                    tireSquare("FR", pressures?.fr, temps?.fr)
                }
                HStack(spacing: 12) {
                    tireSquare("RL", pressures?.rl, temps?.rl)
                    Spacer()
                    Spacer().frame(width: 32)
                    Spacer()
                    tireSquare("RR", pressures?.rr, temps?.rr)
                }
            }
            .padding(16)
        }
        .padding(.horizontal)
        .backgroundStyle(.ultraThinMaterial)
    }

    private func tireSquare(_ label: String, _ kpa: Float?, _ tempC: Float?) -> some View {
        let isLow = (kpa ?? .greatestFiniteMagnitude) < Self.lowPressureKpa
        return VStack(spacing: 2) {
            Text(label)
                .font(.ioniqCaption.weight(.bold))
            Text(viewModel.tirePressure(kpa))
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(isLow ? Color.appRed : Color.appOnSurface)
            Text(viewModel.tirePressureUnit)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            Text(viewModel.temperature(tempC))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .frame(minWidth: 70)
        .padding(8)
        .background(Color.appSurfaceVariant.opacity(0.6))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label) tire")
        .accessibilityValue(
            kpa == nil
                ? "No data"
                : "\(viewModel.tirePressure(kpa)) \(viewModel.tirePressureUnit)\(isLow ? ", low" : "")"
        )
    }
}

// MARK: - Thermal Tip

struct ThermalTipCard: View {
    let tip: String

    var body: some View {
        GroupBox {
            HStack(spacing: 12) {
                Image(systemName: "thermometer.medium")
                    .font(.title2)
                    .foregroundStyle(Color.appAmber)
                Text(tip)
                    .font(.ioniqBody)
                    .foregroundStyle(.secondary)
            }
            .padding(12)
        }
        .padding(.horizontal)
        .backgroundStyle(.ultraThinMaterial)
        .accessibilityElement(children: .combine)
    }
}
