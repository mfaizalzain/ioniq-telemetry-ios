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

                // "Since Charge" trip row — shown only when trip data is available
                if viewModel.hasTripData {
                    TripStatRow(viewModel: viewModel)
                }

                MetricTilesGrid(viewModel: viewModel)
                TirePressureVisualizerCard(viewModel: viewModel)
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
    @State private var showThermalTip = false

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
                        .stroke(Color.appOutline, style: StrokeStyle(lineWidth: 10, lineCap: .round))
                        .rotationEffect(.degrees(Self.startAngle))
                        .frame(width: 100, height: 100)

                    Circle()
                        .trim(from: 0, to: Self.sweepFraction * CGFloat(fillFraction))
                        .stroke(
                            AngularGradient(
                                colors: [.appAccent.opacity(0.75), .electricTeal],
                                center: .center,
                                startAngle: .degrees(Self.startAngle),
                                endAngle: .degrees(Self.startAngle + 220)
                            ),
                            style: StrokeStyle(lineWidth: 10, lineCap: .round)
                        )
                        .rotationEffect(.degrees(Self.startAngle))
                        .frame(width: 100, height: 100)
                        .animation(.easeOut(duration: 0.4), value: fillFraction)

                    HStack(alignment: .firstTextBaseline, spacing: 1) {
                        Text(socPercent.map { String(format: "%.0f", $0) } ?? "—")
                            .font(.system(size: 28, weight: .bold))
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

                // Collapsible thermal tip integrated inside the hero card
                if let tip = viewModel.thermalTip {
                    Button {
                        showThermalTip.toggle()
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "thermometer.medium")
                                .foregroundStyle(Color.appAmber)
                            Text("Thermal")
                                .font(.caption.weight(.medium))
                                .foregroundStyle(Color.appAmber)
                            Image(systemName: showThermalTip ? "chevron.up" : "chevron.down")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Color.appAmber.opacity(0.12))
                        .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)

                    if showThermalTip {
                        Text(tip)
                            .font(.ioniqBody)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.appSurfaceVariant.opacity(0.5))
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                }
            }
            .padding(20)
        }
        .padding(.horizontal)
        .backgroundStyle(.ultraThinMaterial)
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

// MARK: - Since Charge Trip Row

private struct TripStatRow: View {
    let viewModel: DashboardViewModel

    var body: some View {
        HStack(spacing: 16) {
            Label(viewModel.tripDistanceText, systemImage: "arrow.triangle.swap")
            Divider()
                .frame(height: 14)
            Label(viewModel.tripEnergyText, systemImage: "bolt")
            if let duration = viewModel.tripDurationText {
                Divider()
                    .frame(height: 14)
                Label(duration, systemImage: "clock")
            }
        }
        .font(.caption.weight(.medium))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.appSurfaceVariant.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
        .padding(.horizontal)
    }
}

// MARK: - Metric Tiles

struct MetricTilesGrid: View {
    let viewModel: DashboardViewModel

    private var telemetry: VehicleTelemetry { viewModel.telemetry }

    var body: some View {
        GroupBox {
            VStack(spacing: 8) {
                // Header
                HStack {
                    Image(systemName: "chart.bar.fill")
                        .font(.caption)
                    Text("LIVE METRICS")
                        .font(.ioniqCaption.weight(.medium))
                        .ioniqStatLabel()
                    Spacer()
                }
                .foregroundStyle(.secondary)

                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                    // Row 1
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

                    // Row 2
                    MetricTile(
                        icon: "speedometer",
                        label: "SPEED",
                        value: viewModel.speed(telemetry.speedKph),
                        valueColor: .appAccent
                    )
                    MetricTile(
                        icon: "battery.100percent",
                        label: "BMS SOC",
                        value: telemetry.socBms.map { String(format: "%.1f%%", $0) } ?? "—",
                        valueColor: .appOnSurface
                    )

                    // Row 3
                    MetricTile(
                        icon: "battery.100percent.bolt",
                        label: "HV VOLTAGE",
                        value: DashboardViewModel.format(telemetry.packVoltage, unit: "V", decimals: 0),
                        valueColor: .appAccent
                    )
                    MetricTile(
                        icon: "heart.text.clipboard",
                        label: "SOH",
                        value: telemetry.soh.map { String(format: "%.0f%%", $0) } ?? "—",
                        valueColor: .appGreen
                    )

                    // Row 4
                    MetricTile(
                        icon: "battery.25percent",
                        label: "AUX BATTERY",
                        value: DashboardViewModel.format(telemetry.auxVoltage, unit: "V", decimals: 1),
                        // Below ~12.0 V the 12 V battery is draining faster than the DC-DC
                        // replaces it — the classic E-GMP no-start warning.
                        valueColor: (telemetry.auxVoltage ?? 12.6) < 12.0 ? .appAmber : .appGreen
                    )
                    MetricTile(
                        icon: "thermometer.medium",
                        label: "PACK TEMP",
                        value: viewModel.temperature(viewModel.packTempC.map(Float.init)),
                        valueColor: .packTemp(viewModel.packTempC)
                    )
                }
            }
            .padding(12)
        }
        .padding(.horizontal)
        .backgroundStyle(.ultraThinMaterial)
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
        let psi = kpa.map { Int($0 * 0.145038) }
        return VStack(spacing: 2) {
            Text(label)
                .font(.ioniqCaption.weight(.bold))
            // Primary: PSI (always shown, matching Android)
            Text(psi.map { "\($0) PSI" } ?? "—")
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(isLow ? Color.appRed : Color.appOnSurface)
            // Secondary: kPa (muted, below PSI — matching Android)
            Text(formattedKpa(kpa))
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
                : "\(psi.map(String.init) ?? "—") PSI, \(viewModel.tirePressure(kpa)) kPa\(isLow ? ", low" : "")"
        )
    }

    private func formattedKpa(_ kpa: Float?) -> String {
        guard let kpa else { return "—" }
        return "\(Int(kpa)) kPa"
    }
}
