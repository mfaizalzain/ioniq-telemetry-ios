import SwiftUI
import CoreUI

struct DashboardView: View {
    @Environment(AppServices.self) private var services

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: 16) {
                    // Header
                    HStack {
                        Text("IONIQ 5")
                            .font(.headline.weight(.medium))
                            .foregroundStyle(.secondary)
                        Spacer()
                        ConnectionBadge(state: .offline)
                    }
                    .padding(.horizontal)

                    BatteryHeroCard()
                    MetricTilesGrid()
                    TirePressureVisualizerCard()
                    ThermalTipCard()
                }
                .padding(.vertical)
            }
            .background(Color.deepNavy)
            .navigationTitle("Dashboard")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        // AI Copilot FAB placeholder
                    } label: {
                        Image(systemName: "sparkles")
                            .foregroundStyle(Color.electricTeal)
                    }
                }
            }
        }
    }
}

// MARK: - Battery Hero Card

struct BatteryHeroCard: View {
    var socPercent: Float = 78

    /// Gauge geometry, shared with the Android build: a 220° arc starting at 160°,
    /// leaving a 140° gap centred at the bottom.
    private static let startAngle: Double = 160
    private static let sweepFraction: CGFloat = 220.0 / 360.0

    private var fillFraction: Float { min(max(socPercent / 100, 0), 1) }

    var body: some View {
        GroupBox {
            VStack(spacing: 10) {
                // SOC ring
                ZStack {
                    // Dim track. SwiftUI trims clockwise from 3 o'clock, so the
                    // 160° rotation puts the 140° gap centred at the bottom —
                    // matching the Android gauge (start 160°, sweep 220°).
                    Circle()
                        .trim(from: 0, to: Self.sweepFraction)
                        .stroke(Color.outlineVariant, style: StrokeStyle(lineWidth: 12, lineCap: .round))
                        .rotationEffect(.degrees(Self.startAngle))
                        .frame(width: 120, height: 120)

                    Circle()
                        .trim(from: 0, to: Self.sweepFraction * CGFloat(fillFraction))
                        .stroke(
                            AngularGradient(
                                colors: [.electricTeal.opacity(0.75), .electricTeal],
                                center: .center,
                                startAngle: .degrees(Self.startAngle),
                                endAngle: .degrees(Self.startAngle + 220)
                            ),
                            style: StrokeStyle(lineWidth: 12, lineCap: .round)
                        )
                        .rotationEffect(.degrees(Self.startAngle))
                        .frame(width: 120, height: 120)
                        .animation(.easeOut(duration: 0.4), value: socPercent)

                    HStack(alignment: .firstTextBaseline, spacing: 1) {
                        Text(String(format: "%.0f", socPercent))
                            .font(.system(size: 32, weight: .bold))
                            .tracking(-1.5)
                        Text("%")
                            .font(.system(size: 16, weight: .medium))
                    }
                    .foregroundStyle(Color.onSurface)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("State of charge")
                .accessibilityValue("\(Int(socPercent.rounded())) percent")

                // Stats row
                HStack(spacing: 16) {
                    statBadge(label: "BMS SOC", value: "76.5%")
                    statBadge(label: "HEALTH SOH", value: "98%")
                    statBadge(label: "PACK TEMP", value: "31°C")
                }
            }
            .padding(20)
        }
        .padding(.horizontal)
        .backgroundStyle(.ultraThinMaterial)
    }

    func statBadge(label: String, value: String) -> some View {
        VStack(spacing: 4) {
            Text(label)
                .font(.ioniqCaption)
                .foregroundStyle(.secondary)
                .ioniqStatLabel()
            Text(value)
                .font(.system(size: 14, weight: .medium))
        }
        .frame(maxWidth: .infinity)
        .padding(8)
        .background(Color(white: 1).opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

// MARK: - Metric Tiles Grid

struct MetricTilesGrid: View {
    var body: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
            MetricTile(
                icon: "bolt.fill",
                label: "POWER",
                value: "45 kW",
                valueColor: .white
            )
            MetricTile(
                icon: "chart.line.uptrend.xyaxis",
                label: "CELL Δ",
                value: "18 mV",
                valueColor: Color.greenOk
            )
            MetricTile(
                icon: "battery.100percent.bolt",
                label: "HV VOLTAGE",
                value: "782 V",
                valueColor: Color.electricTeal
            )
            MetricTile(
                icon: "battery.25percent",
                label: "AUX BATTERY",
                value: "12.6 V",
                valueColor: Color.greenOk
            )
        }
        .padding(.horizontal, 12)
    }
}

// MARK: - Tire Pressure Card

struct TirePressureVisualizerCard: View {
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

                HStack(spacing: 12) {
                    tireSquare(label: "FL", pressure: "36", temp: "32°C")
                    Spacer()
                    Image(systemName: "car.fill")
                        .font(.title)
                        .foregroundStyle(.secondary)
                    Spacer()
                    tireSquare(label: "FR", pressure: "35", temp: "31°C")
                }
                HStack(spacing: 12) {
                    tireSquare(label: "RL", pressure: "37", temp: "33°C")
                    Spacer()
                    Spacer().frame(width: 32)
                    Spacer()
                    tireSquare(label: "RR", pressure: "36", temp: "32°C")
                }
            }
            .padding(16)
        }
        .padding(.horizontal)
        .backgroundStyle(.ultraThinMaterial)
    }

    func tireSquare(label: String, pressure: String, temp: String) -> some View {
        VStack(spacing: 2) {
            Text(label)
                .font(.ioniqCaption.weight(.bold))
            Text(pressure)
                .font(.system(size: 18, weight: .bold))
            Text("PSI")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            Text(temp)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .frame(width: 70)
        .padding(8)
        .background(Color(white: 1).opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

// MARK: - Thermal Tip Card

struct ThermalTipCard: View {
    var body: some View {
        GroupBox {
            HStack(spacing: 12) {
                Image(systemName: "thermometer.medium")
                    .font(.title2)
                    .foregroundStyle(.orange)
                Text("Battery temperature optimal for peak performance.")
                    .font(.ioniqBody)
                    .foregroundStyle(.secondary)
            }
            .padding(12)
        }
        .padding(.horizontal)
        .backgroundStyle(.ultraThinMaterial)
    }
}
