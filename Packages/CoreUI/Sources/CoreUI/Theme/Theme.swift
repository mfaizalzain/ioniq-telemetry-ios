import SwiftUI
import UIKit

/// Applies the Ioniq dark-navy theme to UIKit chrome (navigation bar, tab bar)
/// so SwiftUI screens hosted inside UIKit containers stay on-brand.
///
/// Dark is the default — the phone is frequently mounted in the vehicle and a
/// light theme is glaring at night (mirrors Android IoniqTheme).
public enum IoniqTheme {
    /// Deliberately does nothing.
    ///
    /// This used to install global `UINavigationBar`/`UITabBar` appearance proxies
    /// with hardcoded dark-navy backgrounds. That had two bugs: it suppressed the
    /// large navigation title entirely (leaving a tall empty bar on every screen),
    /// and it pinned the chrome to dark so the light theme setting did nothing.
    ///
    /// SwiftUI styles both bars correctly on its own from the colour scheme. Kept
    /// as a no-op so the call site stays obvious rather than silently disappearing.
    @available(*, deprecated, message: "No longer needed; SwiftUI styles the bars.")
    @MainActor
    public static func apply() {}
}

// MARK: - SwiftUI convenience

/// A SwiftUI container that applies the dark-navy background behind content,
/// mirroring the Android IoniqTheme composable's dark default.
public struct IoniqThemedBackground<Content: View>: View {
    private let content: Content

    public init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    public var body: some View {
        ZStack {
            Color.appBackground.ignoresSafeArea()
            content
        }
        .preferredColorScheme(.dark)
        .tint(Color.appAccent)
    }
}
