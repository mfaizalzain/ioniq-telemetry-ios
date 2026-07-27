import SwiftUI
import UIKit

/// Applies the Ioniq dark-navy theme to UIKit chrome (navigation bar, tab bar)
/// so SwiftUI screens hosted inside UIKit containers stay on-brand.
///
/// Dark is the default — the phone is frequently mounted in the vehicle and a
/// light theme is glaring at night (mirrors Android IoniqTheme).
public enum IoniqTheme {
    /// Sets global UINavigationBar / UITabBar appearances to the deep-navy theme.
    /// Call once at app launch (e.g. in `App.init()` or `SceneDelegate`).
    @MainActor
    public static func apply() {
        // Navigation bar
        let navAppearance = UINavigationBarAppearance()
        navAppearance.configureWithOpaqueBackground()
        navAppearance.backgroundColor = .deepNavy
        navAppearance.titleTextAttributes = [
            .foregroundColor: UIColor.onSurface
        ]
        navAppearance.largeTitleTextAttributes = [
            .foregroundColor: UIColor.onSurface
        ]
        UINavigationBar.appearance().standardAppearance = navAppearance
        UINavigationBar.appearance().scrollEdgeAppearance = navAppearance
        UINavigationBar.appearance().compactAppearance = navAppearance
        UINavigationBar.appearance().tintColor = .electricTeal

        // Tab bar
        let tabAppearance = UITabBarAppearance()
        tabAppearance.configureWithOpaqueBackground()
        tabAppearance.backgroundColor = .deepNavy
        UITabBar.appearance().standardAppearance = tabAppearance
        UITabBar.appearance().scrollEdgeAppearance = tabAppearance
        UITabBar.appearance().tintColor = .electricTeal
        UITabBar.appearance().unselectedItemTintColor = UIColor.onSurface.withAlphaComponent(0.6)
    }
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
            Color.deepNavy.ignoresSafeArea()
            content
        }
        .preferredColorScheme(.dark)
        .tint(Color.electricTeal)
    }
}
