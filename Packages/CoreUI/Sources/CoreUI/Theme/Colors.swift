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

    /// Cell voltage delta colour coding (Android spec §10.1): green <30 mV, amber
    /// 30–50, red >50. Green resolves per interface style so it stays legible on a
    /// light background.
    static func cellDelta(_ deltaVolts: Float?) -> Color {
        guard let delta = deltaVolts else { return .secondary }
        if delta < 0.030 { return .appGreen }
        if delta <= 0.050 { return .appAmber }
        return .appRed
    }

    /// Battery pack temperature colour (Android spec §10.1).
    /// Green in the healthy window, amber when cold enough to throttle DC charging,
    /// red when hot enough to risk derating.
    static func packTemp(_ tempC: Int?) -> Color {
        guard let temp = tempC else { return .secondary }
        if temp < 5 { return .appAmber }        // too cold: DC charging throttled
        if temp <= 40 { return .appGreen }       // healthy operating window
        if temp <= 50 { return .appAmber }      // warm: approaching derate
        return .appRed                         // hot: derating likely
    }
}


// MARK: - Adaptive semantic palette

// The brand colours above are fixed values — they are the dark-theme palette and
// the literal Android match. These semantic colours resolve per interface style so
// the light theme is a real theme rather than dark chrome on a white page.
//
// Views should use these, not the raw brand colours, for anything structural
// (backgrounds, surfaces, body text, dividers). Reach for the raw values only when
// a specific hue is the point, such as the SOC ring gradient.

public extension UIColor {
    /// Screen background.
    static let appBackground = UIColor { traits in
        traits.userInterfaceStyle == .dark ? .deepNavy : .systemGroupedBackground
    }

    /// Card and grouped-row background, one step off the screen background.
    static let appSurface = UIColor { traits in
        traits.userInterfaceStyle == .dark ? .surfaceNavy : .secondarySystemGroupedBackground
    }

    /// Secondary fill for stat pills and inset rows.
    static let appSurfaceVariant = UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0x1C / 255.0, green: 0x27 / 255.0, blue: 0x40 / 255.0, alpha: 1)
            : .tertiarySystemFill
    }

    /// Primary body text.
    static let appOnSurface = UIColor { traits in
        traits.userInterfaceStyle == .dark ? .onSurface : .label
    }

    /// Hairlines and gauge tracks.
    static let appOutline = UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0x2C / 255.0, green: 0x37 / 255.0, blue: 0x52 / 255.0, alpha: 1)
            : .separator
    }

    /// Accent. The bright teal fails contrast on white, so light mode uses the
    /// darker variant that was already defined for exactly this purpose.
    static let appAccent = UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? .electricTeal
            : UIColor(red: 0x00 / 255.0, green: 0x6B / 255.0, blue: 0x58 / 255.0, alpha: 1)
    }

    /// Label colour for anything filled with `appAccent`.
    ///
    /// The dark theme's accent is a bright teal, and the system's own choice of
    /// label colour against it lands near 1.3:1 — legible only if you already know
    /// what it says. Deep navy on that teal is about 11:1.
    static let appOnAccent = UIColor { traits in
        traits.userInterfaceStyle == .dark ? .deepNavy : .white
    }

    /// Healthy / connected, contrast-safe in both themes.
    static let appGreen = UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? .greenOk
            : UIColor(red: 0x00 / 255.0, green: 0x70 / 255.0, blue: 0x3C / 255.0, alpha: 1)
    }

    /// Caution, contrast-safe in both themes.
    ///
    /// The brand amber is a light tint built for a near-black background; as
    /// foreground text on a light one it lands near 1.8:1, which is decorative
    /// rather than readable. The light variant is the same hue taken down to a
    /// shade that clears AA (~5.4:1) — it is the colour of every settings warning,
    /// so it has to be legible before it is on-brand.
    static let appAmber = UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? .amberWarn
            : UIColor(red: 0x9A / 255.0, green: 0x5B / 255.0, blue: 0x00 / 255.0, alpha: 1)
    }

    /// Error / alert, contrast-safe in both themes. The brand red is ~3.3:1 on a
    /// light background, short of the 4.5:1 needed for body text; the light variant
    /// is ~5.6:1.
    static let appRed = UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? .redAlert
            : UIColor(red: 0xC6 / 255.0, green: 0x28 / 255.0, blue: 0x28 / 255.0, alpha: 1)
    }
}

public extension Color {
    static let appBackground = Color(uiColor: .appBackground)
    static let appSurface = Color(uiColor: .appSurface)
    static let appSurfaceVariant = Color(uiColor: .appSurfaceVariant)
    static let appOnSurface = Color(uiColor: .appOnSurface)
    static let appOutline = Color(uiColor: .appOutline)
    static let appAccent = Color(uiColor: .appAccent)
    static let appOnAccent = Color(uiColor: .appOnAccent)
    static let appGreen = Color(uiColor: .appGreen)
    static let appAmber = Color(uiColor: .appAmber)
    static let appRed = Color(uiColor: .appRed)
}
