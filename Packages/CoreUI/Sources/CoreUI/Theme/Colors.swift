import SwiftUI
import UIKit

// MARK: - Brand Colors
// Ported from Android core-ui Theme.kt (core-ui/src/main/kotlin/com/fmz/ioniqtelemetry/ui/theme/Theme.kt).
// Dark by default: the phone is frequently mounted in the vehicle and a light
// theme is glaring at night.

public extension Color {
    /// Primary accent — teal used for highlights, active states, SOC ring.
    static let electricTeal = Color(red: 0x17 / 255.0, green: 0xE8 / 255.0, blue: 0xC2 / 255.0)

    /// Darker teal variant (light-theme primary / inversePrimary in dark).
    static let electricTealLight = Color(red: 0x00 / 255.0, green: 0x6B / 255.0, blue: 0x58 / 255.0)

    /// App background — deep navy, near-black with a blue tint.
    static let deepNavy = Color(red: 0x0B / 255.0, green: 0x12 / 255.0, blue: 0x20 / 255.0)

    /// Card/surface background — one step lighter than deepNavy.
    static let surfaceNavy = Color(red: 0x14 / 255.0, green: 0x1D / 255.0, blue: 0x30 / 255.0)

    /// Secondary surface — used for stat rows and flat accent cards (Android: 0xFF1C2740).
    static let surfaceVariant = Color(red: 0x1C / 255.0, green: 0x27 / 255.0, blue: 0x40 / 255.0)

    /// Muted text on surfaces (Android onSurfaceVariant: 0xFFB9C2D6).
    static let onSurfaceVariant = Color(red: 0xB9 / 255.0, green: 0xC2 / 255.0, blue: 0xD6 / 255.0)

    /// Primary text on dark surfaces (Android onSurface/onBackground: 0xFFE4E9F2).
    static let onSurface = Color(red: 0xE4 / 255.0, green: 0xE9 / 255.0, blue: 0xF2 / 255.0)

    /// Healthy / connected / charging — dark theme variant.
    static let greenOk = Color(red: 0x66 / 255.0, green: 0xBB / 255.0, blue: 0x6A / 255.0)

    /// Dark emerald green for light theme (WCAG AA ratio ~5.1:1).
    static let greenOkLight = Color(red: 0x00 / 255.0, green: 0x70 / 255.0, blue: 0x3C / 255.0)

    /// Caution / cold battery / connecting.
    static let amberWarn = Color(red: 0xFF / 255.0, green: 0xB7 / 255.0, blue: 0x4D / 255.0)

    /// Error / hot battery / low tire / disconnected.
    static let redAlert = Color(red: 0xEF / 255.0, green: 0x53 / 255.0, blue: 0x50 / 255.0)

    /// Subtle outline color for dividers (Android outlineVariant: 0xFF2C3752).
    static let outlineVariant = Color(red: 0x2C / 255.0, green: 0x37 / 255.0, blue: 0x52 / 255.0)
}

// MARK: - UIColor equivalents (for UIKit appearance APIs)

public extension UIColor {
    static let electricTeal = UIColor(red: 0x17 / 255.0, green: 0xE8 / 255.0, blue: 0xC2 / 255.0, alpha: 1)
    static let deepNavy = UIColor(red: 0x0B / 255.0, green: 0x12 / 255.0, blue: 0x20 / 255.0, alpha: 1)
    static let surfaceNavy = UIColor(red: 0x14 / 255.0, green: 0x1D / 255.0, blue: 0x30 / 255.0, alpha: 1)
    static let greenOk = UIColor(red: 0x66 / 255.0, green: 0xBB / 255.0, blue: 0x6A / 255.0, alpha: 1)
    static let amberWarn = UIColor(red: 0xFF / 255.0, green: 0xB7 / 255.0, blue: 0x4D / 255.0, alpha: 1)
    static let redAlert = UIColor(red: 0xEF / 255.0, green: 0x53 / 255.0, blue: 0x50 / 255.0, alpha: 1)
    static let onSurface = UIColor(red: 0xE4 / 255.0, green: 0xE9 / 255.0, blue: 0xF2 / 255.0, alpha: 1)
}

// MARK: - Semantic status colors (ported helpers)

public extension Color {
    /// Theme-aware green status color that maintains >= 4.5:1 WCAG contrast.
    static func greenOk(for scheme: ColorScheme) -> Color {
        scheme == .dark ? .greenOk : .greenOkLight
    }

    /// Cell voltage delta colour coding (Android spec §10.1): green <30 mV, amber 30–50, red >50.
    static func cellDelta(_ deltaVolts: Float?, dark: Bool = true) -> Color {
        guard let delta = deltaVolts else { return .gray }
        if delta < 0.030 { return dark ? .greenOk : .greenOkLight }
        if delta <= 0.050 { return .amberWarn }
        return .redAlert
    }

    /// Battery pack temperature colour (Android spec §10.1).
    /// Green in the healthy window, amber when cold enough to throttle DC charging,
    /// red when hot enough to risk derating.
    static func packTemp(_ tempC: Int?, dark: Bool = true) -> Color {
        guard let temp = tempC else { return .gray }
        if temp < 5 { return .amberWarn }                     // too cold: DC charging throttled
        if temp <= 40 { return dark ? .greenOk : .greenOkLight } // healthy operating window
        if temp <= 50 { return .amberWarn }                   // warm: approaching derate
        return .redAlert                                      // hot: derating likely
    }
}
