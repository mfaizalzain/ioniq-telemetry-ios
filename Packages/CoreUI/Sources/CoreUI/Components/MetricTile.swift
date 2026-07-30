import SwiftUI

/// Dashboard metric tile: icon + uppercase label + value, on a surfaceNavy card.
/// Ported from the Android dashboard tile pattern
/// (`Column(padding h=12, v=10, spacedBy 6)` — never fillMaxSize + SpaceBetween).
///
/// Only data the car does NOT display on its cluster gets a tile
/// (Power, CellDelta, HV Voltage, Aux Battery).
public struct MetricTile: View {
    private let icon: String
    private let label: String
    private let value: String
    private let valueColor: Color
    private let badge: String?

    /// - Parameters:
    ///   - icon: SF Symbol name (e.g. "bolt.fill").
    ///   - label: Short stat label (rendered uppercase).
    ///   - value: Formatted value string (e.g. "45.2 kW").
    ///   - valueColor: Color for the value text (defaults to onSurface).
    ///   - badge: Optional pill badge text shown next to the label (e.g. "REGEN").
    public init(
        icon: String,
        label: String,
        value: String,
        valueColor: Color = .appOnSurface,
        badge: String? = nil
    ) {
        self.icon = icon
        self.label = label
        self.value = value
        self.valueColor = valueColor
        self.badge = badge
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Color.appAccent)
                Text(label)
                    .ioniqStatLabel()
                    .foregroundStyle(Color.secondary)
                    .lineLimit(1)
                if let badge {
                    Text(badge)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Color.appBackground)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.appAmber)
                        .clipShape(Capsule())
                }
            }
            Text(value)
                .font(.ioniqTitle)
                .foregroundStyle(valueColor)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label): \(value)")
    }
}

#Preview {
    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
        MetricTile(icon: "bolt.fill", label: "Power", value: "-12.4 kW", badge: "REGEN")
        MetricTile(icon: "chart.line.uptrend.xyaxis", label: "Cell Δ", value: "28 mV", valueColor: .appGreen)
        MetricTile(icon: "battery.100.bolt", label: "HV Voltage", value: "402 V")
        MetricTile(icon: "battery.100", label: "Aux Battery", value: "12.6 V")
    }
    .padding()
    .background(Color.appBackground)
    .preferredColorScheme(.dark)
}
