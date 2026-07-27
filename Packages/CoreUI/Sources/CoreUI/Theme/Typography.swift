import SwiftUI

/// Typography matching the Android IoniqTypography scale
/// (core-ui/.../theme/Theme.kt), built on Material 3 defaults with
/// SemiBold display/headline/title tweaks for glanceable in-car reading.
public extension Font {
    /// Large dashboard values (e.g. SOC percentage). ~32sp Bold, tight tracking.
    static let ioniqDisplay = Font.system(size: 32, weight: .bold, design: .default)

    /// Screen titles / section headers. Material headlineSmall, SemiBold.
    static let ioniqHeadline = Font.system(size: 24, weight: .semibold, design: .default)

    /// Card titles. Material titleLarge, SemiBold.
    static let ioniqTitle = Font.system(size: 22, weight: .semibold, design: .default)

    /// Smaller titles / list headers. Material titleMedium, Medium.
    static let ioniqTitleMedium = Font.system(size: 16, weight: .medium, design: .default)

    /// Primary body text. Material bodyLarge.
    static let ioniqBody = Font.system(size: 16, weight: .regular, design: .default)

    /// Secondary body text. Material bodyMedium.
    static let ioniqBodyMedium = Font.system(size: 14, weight: .regular, design: .default)

    /// Captions, stat labels, timestamps. Material labelSmall/bodySmall.
    static let ioniqCaption = Font.system(size: 12, weight: .regular, design: .default)

    /// Uppercase pill badges and tile labels. Material labelLarge, Medium.
    static let ioniqLabel = Font.system(size: 14, weight: .medium, design: .default)
}

public extension View {
    /// Uppercase stat-label styling used on dashboard tiles (letter-spaced caption).
    func ioniqStatLabel() -> some View {
        self
            .font(.ioniqCaption.weight(.medium))
            .tracking(0.5)
            .textCase(.uppercase)
    }
}
