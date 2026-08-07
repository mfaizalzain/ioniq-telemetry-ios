import CoreDomain
import CoreUI
import SwiftUI

struct DashboardView: View {
    @Environment(AppServices.self) private var services
    @Binding var selectedTab: AppTab
    @State private var viewModel: DashboardViewModel?
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
            }
        }
        .task {
            if viewModel == nil { viewModel = DashboardViewModel(services: services) }
            viewModel?.refreshTrips()
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

                // Thermal tip — separate card below hero, only when relevant
                if viewModel.thermalTip != nil {
                    ThermalTipCard(tip: viewModel.thermalTip!, viewModel: viewModel)
                }

                // DC fast charge curve card
                if viewModel.isDcCharging {
                    ChargeCurveCard(telemetry: viewModel.telemetry)
                }

                // Safety alert banners
                DashboardAlertBanners(telemetry: viewModel.telemetry)

                // "Since Charge" trip row — shown only when trip data is available
                if viewModel.hasTripData {
                    TripStatRow(viewModel: viewModel)
                }

                MetricTilesGrid(viewModel: viewModel)
                TirePressureVisualizerCard(viewModel: viewModel)

                AIDigestSection(
                    isPro: viewModel.isPro,
                    aiKey: viewModel.aiKey,
                    aiProvider: viewModel.aiProvider,
                    aiFeaturesEnabled: viewModel.aiFeaturesEnabled,
                    vehicleName: viewModel.vehicleName,
                    trips: viewModel.recentTrips
                )

                // AI-powered cards — shown only when telemetry data is available
                if viewModel.hasData {
                    BatteryHealthReportView(viewModel: viewModel)
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
        .background(Color.appSurfaceVariant, in: RoundedRectangle(cornerRadius: .cornerSmall))
        .padding(.horizontal)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Battery Hero Card

struct BatteryHeroCard: View {
    let viewModel: DashboardViewModel

    private var socPercent: Float? { viewModel.socPercent }
    private var fillFraction: Float { min(max((socPercent ?? 0) / 100, 0), 1) }
    private var fillColor: Color {
        guard let soc = socPercent else { return .appGreen }
        if soc > 50 { return Color.appGreen }
        if soc > 20 { return Color.appAmber }
        return Color.appRed
    }


    /// SOC percentage, plus the raw BMS figure when it disagrees with the display.
    private var socReadout: some View {
        HStack(alignment: .firstTextBaseline, spacing: 1) {
            Text(socPercent.map { String(format: "%.0f", $0) } ?? "—")
                .font(.system(size: 52, weight: .bold))
                .tracking(-1.5)
            Text("%")
                .font(.system(size: 26, weight: .medium))
                .foregroundStyle(.secondary)
            // BMS raw SOC — only when it differs from displayed SOC
            if let bms = viewModel.telemetry.socBms, let display = socPercent, abs(bms - display) > 0.4 {
                Text("BMS \(String(format: "%.1f", bms))%")
                    .font(.system(size: 11, weight: .regular))
                    .foregroundStyle(.tertiary)
                    .padding(.leading, 4)
            }
        }
    }

    /// Estimated remaining range. Single line by contract — the pill is a capsule,
    /// and a wrapped capsule reads as a blob rather than a badge.
    @ViewBuilder
    private var rangePill: some View {
        if let range = viewModel.rangeText {
            HStack(spacing: 4) {
                Image(systemName: "bolt.car.fill")
                    .font(.caption2)
                    .imageScale(.small)
                Text(range)
                    .font(.caption.weight(.semibold))
            }
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(fillColor.opacity(0.15))
            .foregroundStyle(fillColor)
            .clipShape(Capsule())
        }
    }

    private var accessibilityValueText: String {
        guard let soc = socPercent else { return "No data" }
        var value = "\(Int(soc.rounded())) percent"
        if let range = viewModel.rangeAccessibilityText { value += ", \(range)" }
        return value
    }

    var body: some View {
        VStack(spacing: 10) {
            // The range pill shares the readout's line only while both genuinely
            // fit. A longer string or an accessibility text size used to squeeze it
            // into a three-line blob overlapping its own icon, so the fallback
            // stacks it under the readout instead of compressing either one.
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: 1) {
                    socReadout
                    Spacer(minLength: 8)
                    rangePill
                }
                VStack(alignment: .leading, spacing: 8) {
                    socReadout
                    rangePill
                }
            }
            .foregroundStyle(Color.appOnSurface)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("State of charge")
            .accessibilityValue(accessibilityValueText)

            if viewModel.telemetry.isCharging {
                ChargingChip(viewModel: viewModel)
            }
        }
        // maxWidth belongs out here, not on either `ViewThatFits` branch: inside, a
        // greedy child always reports that it fits and the fallback never triggers.
        // Without it the stacked branch hugs its content and the card narrows.
        .frame(maxWidth: .infinity, minHeight: 78, alignment: .topLeading)
        // SOC fill — width tracks SOC, drawn behind the readout. A GeometryReader
        // wrapping the card would have no intrinsic height and collapse it, so the
        // measurement happens in the background layer, which inherits the card's
        // own size instead of dictating it. The negative inset lets the fill bleed
        // under `cardStyle`'s content padding to the card edge, where the card's
        // own clip shape trims it.
        .background {
            GeometryReader { geo in
                Rectangle()
                    .fill(fillColor.opacity(0.18))
                    .frame(width: geo.size.width * CGFloat(fillFraction))
                    .animation(.easeOut(duration: 0.8), value: fillFraction)
            }
            .padding(-CardLevel.hero.contentInset)
        }
        .cardStyle(.hero)
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

// MARK: - Thermal Tip Card

/// Battery thermal status — extracted from the hero card into its own secondary
/// card so the hero focuses on SOC and range.
private struct ThermalTipCard: View {
    let tip: String
    let viewModel: DashboardViewModel
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                    expanded.toggle()
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "thermometer.medium")
                        .foregroundStyle(Color.appAmber)
                    Text("Battery Temperature")
                        .font(.subheadline.weight(.medium))
                    if let temp = viewModel.packTempC {
                        Text("\(temp)°C")
                            .font(.caption.weight(.semibold))
                    }
                    Spacer()
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded {
                Text(tip)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 4)
            }
        }
        .cardStyle(.secondary)
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
        .background(Color.appSurfaceVariant.opacity(0.4), in: RoundedRectangle(cornerRadius: .cornerSmall))
        .padding(.horizontal)
    }
}

// MARK: - Alert Banners

private struct DashboardAlertBanners: View {
    let telemetry: VehicleTelemetry

    private static let cellDeltaWarningV: Float = 0.030
    private static let cellDeltaAlertV: Float = 0.050
    private static let packTempWarmC: Int = 45
    private static let packTempHotC: Int = 55
    private static let auxVoltageLow: Float = 12.0

    private var maxModuleTemp: Int? {
        telemetry.moduleTempsC.max()
    }

    var body: some View {
        let banners = buildAlerts()

        if !banners.isEmpty {
            VStack(spacing: 8) {
                ForEach(banners) { banner in
                    AlertBannerRow(alert: banner)
                }
            }
            .padding(.horizontal)
        }
    }

    fileprivate struct AlertBanner: Identifiable {
        let id: String
        let icon: String
        let title: String
        let message: String
        let isCritical: Bool
    }

    private func buildAlerts() -> [AlertBanner] {
        var alerts: [AlertBanner] = []

        // Cell voltage delta
        if let delta = telemetry.cellVoltDelta {
            if delta >= Self.cellDeltaAlertV {
                alerts.append(AlertBanner(
                    id: "cell_delta_critical",
                    icon: "exclamationmark.triangle.fill",
                    title: "Cell Voltage Imbalance",
                    message: "Delta: \(String(format: "%.0f", delta * 1000)) mV — service recommended above \(String(format: "%.0f", Self.cellDeltaWarningV * 1000)) mV",
                    isCritical: true
                ))
            } else if delta > Self.cellDeltaWarningV {
                alerts.append(AlertBanner(
                    id: "cell_delta_warning",
                    icon: "exclamationmark.triangle.fill",
                    title: "Cell Voltage Imbalance",
                    message: "Delta: \(String(format: "%.0f", delta * 1000)) mV — service recommended above \(String(format: "%.0f", Self.cellDeltaWarningV * 1000)) mV",
                    isCritical: false
                ))
            }
        }

        // Pack temperature
        if let maxTemp = maxModuleTemp {
            if maxTemp >= Self.packTempHotC {
                alerts.append(AlertBanner(
                    id: "pack_temp_hot",
                    icon: "thermometer.sun.fill",
                    title: "Battery Temperature Critical",
                    message: "Pack at \(maxTemp)°C — maximum operating temperature exceeded",
                    isCritical: true
                ))
            } else if maxTemp >= Self.packTempWarmC {
                alerts.append(AlertBanner(
                    id: "pack_temp_warm",
                    icon: "thermometer.medium",
                    title: "Battery Temperature Elevated",
                    message: "Pack at \(maxTemp)°C",
                    isCritical: false
                ))
            }
        }

        // Low 12V aux voltage
        if let aux = telemetry.auxVoltage, aux < Self.auxVoltageLow {
            alerts.append(AlertBanner(
                id: "aux_low",
                icon: "battery.25percent",
                title: "12V Battery Low",
                message: "\(String(format: "%.1f", aux)) V — may not start",
                isCritical: true
            ))
        }

        return alerts
    }
}

private struct AlertBannerRow: View {
    let alert: DashboardAlertBanners.AlertBanner

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: alert.icon)
                .font(.body)
            VStack(alignment: .leading, spacing: 1) {
                Text(alert.title)
                    .font(.subheadline.weight(.medium))
                Text(alert.message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .foregroundStyle(alert.isCritical ? Color.appRed : Color.appAmber)
        .padding(12)
        .background(
            (alert.isCritical ? Color.appRed : Color.appAmber).opacity(0.08),
            in: RoundedRectangle(cornerRadius: .cornerSmall)
        )
        .animation(.easeInOut, value: alert.id)
    }
}

// MARK: - Charge Curve Card

private struct ChargeCurveCard: View {
    let telemetry: VehicleTelemetry

    /// E-GMP 800V DC fast charge taper curve (SOC % → power kW) on a 350 kW charger.
    private static let curvePoints: [(soc: Float, kw: Float)] = [
        (10, 180), (20, 230), (30, 235), (40, 210),
        (50, 180), (60, 150), (70, 120), (80, 80),
    ]
    private static let minSoc: Float = 10
    private static let maxSoc: Float = 80
    private static let maxPower: Float = 250

    private var socPercent: Float? { telemetry.socDisplay ?? telemetry.socBms }

    var body: some View {
        VStack(spacing: 8) {
            // Header
            HStack {
                Image(systemName: "bolt.batteryblock.fill")
                    .font(.ioniqCaption)
                Text("DC CHARGE CURVE")
                    .font(.ioniqCaption.weight(.medium))
                    .ioniqStatLabel()
                Spacer()
                if let power = telemetry.powerKw {
                    Text(String(format: "%.1f kW", abs(power)))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.appGreen)
                }
            }
            .foregroundStyle(.secondary)

            // Graph area
            Canvas { context, size in
                let chartRect = CGRect(
                    x: 28, y: 8,
                    width: max(size.width - 44, 100),
                    height: size.height - 24
                )

                guard chartRect.width > 0, chartRect.height > 0 else { return }

                // --- Grid lines ---
                let gridColor = Color.appOutline.opacity(0.25)
                let gridPath = Path { p in
                    // Horizontal grid at power levels
                    for kw in stride(from: 0, through: 250, by: 50) {
                        let y = chartRect.maxY - (CGFloat(kw) / CGFloat(Self.maxPower)) * chartRect.height
                        p.move(to: CGPoint(x: chartRect.minX, y: y))
                        p.addLine(to: CGPoint(x: chartRect.maxX, y: y))
                    }
                }
                context.stroke(gridPath, with: .color(gridColor), style: StrokeStyle(lineWidth: 0.5, dash: [3, 3]))

                // --- Y-axis labels ---
                let labelFont = Font.system(size: 9, design: .monospaced).weight(.regular)
                let labelColor = Color.secondary
                for kw in stride(from: 0, through: 250, by: 50) {
                    let y = chartRect.maxY - (CGFloat(kw) / CGFloat(Self.maxPower)) * chartRect.height
                    context.draw(
                        Text("\(kw)").font(labelFont).foregroundStyle(labelColor),
                        at: CGPoint(x: chartRect.minX - 4, y: y),
                        anchor: .trailing
                    )
                }

                // --- X-axis labels (SOC) ---
                for soc in stride(from: 10, through: 80, by: 10) {
                    let socF = CGFloat(soc)
                    let x = chartRect.minX + (socF - CGFloat(Self.minSoc)) / CGFloat(Self.maxSoc - Self.minSoc) * chartRect.width
                    context.draw(
                        Text("\(soc)%").font(labelFont).foregroundStyle(labelColor),
                        at: CGPoint(x: x, y: chartRect.maxY + 4),
                        anchor: .top
                    )
                }

                // --- Background fill under curve ---
                if let currentSoc = socPercent, currentSoc >= Self.minSoc {
                    let clipSoc = min(currentSoc, Self.maxSoc)
                    let fillPath = Path { p in
                        let pointsUpTo = Self.curvePoints.filter { $0.soc <= clipSoc }
                        guard let first = pointsUpTo.first else { return }
                        let startX = chartRect.minX + (CGFloat(first.soc - Self.minSoc) / CGFloat(Self.maxSoc - Self.minSoc)) * chartRect.width
                        p.move(to: CGPoint(x: startX, y: chartRect.maxY))
                        for point in pointsUpTo {
                            let px = chartRect.minX + (CGFloat(point.soc - Self.minSoc) / CGFloat(Self.maxSoc - Self.minSoc)) * chartRect.width
                            let py = chartRect.maxY - (CGFloat(point.kw) / CGFloat(Self.maxPower)) * chartRect.height
                            p.addLine(to: CGPoint(x: px, y: py))
                        }
                        // Close back to bottom
                        let lastX = chartRect.minX + (CGFloat(clipSoc - Self.minSoc) / CGFloat(Self.maxSoc - Self.minSoc)) * chartRect.width
                        p.addLine(to: CGPoint(x: lastX, y: chartRect.maxY))
                        p.closeSubpath()
                    }
                    context.fill(fillPath, with: .color(Color.appGreen.opacity(0.15)))
                }

                // --- Curve line ---
                let curvePath = Path { p in
                    guard let first = Self.curvePoints.first else { return }
                    let startX = chartRect.minX + (CGFloat(first.soc - Self.minSoc) / CGFloat(Self.maxSoc - Self.minSoc)) * chartRect.width
                    let startY = chartRect.maxY - (CGFloat(first.kw) / CGFloat(Self.maxPower)) * chartRect.height
                    p.move(to: CGPoint(x: startX, y: startY))
                    for point in Self.curvePoints.dropFirst() {
                        let px = chartRect.minX + (CGFloat(point.soc - Self.minSoc) / CGFloat(Self.maxSoc - Self.minSoc)) * chartRect.width
                        let py = chartRect.maxY - (CGFloat(point.kw) / CGFloat(Self.maxPower)) * chartRect.height
                        p.addLine(to: CGPoint(x: px, y: py))
                    }
                }
                context.stroke(curvePath, with: .color(Color.appAccent), style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))

                // --- Current SOC marker ---
                if let currentSoc = socPercent, currentSoc >= Self.minSoc {
                    let clampedSoc = min(max(currentSoc, Self.minSoc), Self.maxSoc)
                    // Interpolate power at the current SOC
                    let currentKw = interpolatePower(at: clampedSoc)
                    let dotX = chartRect.minX + (CGFloat(clampedSoc - Self.minSoc) / CGFloat(Self.maxSoc - Self.minSoc)) * chartRect.width
                    let dotY = chartRect.maxY - (CGFloat(currentKw) / CGFloat(Self.maxPower)) * chartRect.height

                    // Outer ring
                    let ringRect = CGRect(x: dotX - 6, y: dotY - 6, width: 12, height: 12)
                    context.fill(Path(ellipseIn: ringRect), with: .color(Color.appOnSurface))
                    // Inner dot
                    let dotRect = CGRect(x: dotX - 4, y: dotY - 4, width: 8, height: 8)
                    context.fill(Path(ellipseIn: dotRect), with: .color(Color.appAccent))
                }
            }
            .frame(height: 140)
            .accessibilityLabel("DC charge curve graph")
        }
        .cardStyle(.primary)
    }

    /// Linearly interpolate the charge curve to find power at any SOC between 10-80%.
    private func interpolatePower(at soc: Float) -> Float {
        let points = Self.curvePoints
        guard soc >= points.first!.soc else { return points.first!.kw }
        guard soc <= points.last!.soc else { return points.last!.kw }

        for i in 0 ..< points.count - 1 {
            let a = points[i]
            let b = points[i + 1]
            if soc >= a.soc && soc <= b.soc {
                let t = (soc - a.soc) / (b.soc - a.soc)
                return a.kw + t * (b.kw - a.kw)
            }
        }
        return points.last!.kw
    }
}

// MARK: - Metric Tiles

struct MetricTilesGrid: View {
    let viewModel: DashboardViewModel

    private var telemetry: VehicleTelemetry { viewModel.telemetry }

    var body: some View {
        VStack(spacing: 12) {
            // Header
            HStack {
                Image(systemName: "chart.bar.fill")
                    .font(.ioniqCaption)
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
                    valueColor: .appGreen,
                    // Independent coulomb-counted estimate (see BatteryHealthEstimator)
                    badge: viewModel.estimatedSoh.map { String(format: "Est %.0f%%", $0) }
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
        .cardStyle(.primary)
    }
}

// MARK: - Tire Pressure

struct TirePressureVisualizerCard: View {
    let viewModel: DashboardViewModel

    /// Below this an E-GMP tire is meaningfully under-inflated.
    private static let lowPressureKpa: Float = 220

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Image(systemName: "tire")
                    .font(.ioniqCaption)
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
        .cardStyle(.primary)
    }

    private func tireSquare(_ label: String, _ kpa: Float?, _ tempC: Float?) -> some View {
        let isLow = (kpa ?? .greatestFiniteMagnitude) < Self.lowPressureKpa
        let isWarning = (kpa ?? .greatestFiniteMagnitude) < (Self.lowPressureKpa + 15)
        let psi = kpa.map { Int($0 * 0.145038) }
        
        let statusColor: Color = {
            if kpa == nil { return .secondary }
            if isLow { return Color.appRed }
            if isWarning { return Color.appAmber }
            return Color.appGreen
        }()

        return VStack(spacing: 2) {
            HStack(spacing: 3) {
                Text(label)
                    .font(.ioniqCaption.weight(.bold))
                Circle()
                    .fill(statusColor)
                    .frame(width: 6, height: 6)
            }
            // Primary: PSI
            Text(psi.map { "\($0) PSI" } ?? "—")
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(isLow ? Color.appRed : Color.appOnSurface)
            // Secondary: kPa
            Text(formattedKpa(kpa))
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            Text(viewModel.temperature(tempC))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .frame(minWidth: 72)
        .padding(8)
        .background(statusColor.opacity(0.10))
        .overlay(
            RoundedRectangle(cornerRadius: .cornerSmall)
                .stroke(statusColor.opacity(0.3), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: .cornerSmall))
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
