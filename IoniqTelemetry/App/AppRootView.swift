import SwiftUI
import CoreDomain
import CoreUI

struct AppRootView: View {
    @Environment(AppServices.self) private var services
    @State private var selectedTab: AppTab = .dashboard

    var body: some View {
        TabView(selection: $selectedTab) {
            DashboardView()
                .tabItem { Label(AppTab.dashboard.rawValue, systemImage: AppTab.dashboard.icon) }
                .tag(AppTab.dashboard)

            TripsView()
                .tabItem { Label(AppTab.trips.rawValue, systemImage: AppTab.trips.icon) }
                .tag(AppTab.trips)

            PlanView()
                .tabItem { Label(AppTab.plan.rawValue, systemImage: AppTab.plan.icon) }
                .tag(AppTab.plan)

            SettingsView()
                .tabItem { Label(AppTab.settings.rawValue, systemImage: AppTab.settings.icon) }
                .tag(AppTab.settings)
        }
        .tint(Color.appAccent)
        // Honours the Theme picker in Settings. `.system` maps to nil so the OS
        // setting wins, which is what "System" has to mean.
        .preferredColorScheme(colorScheme)
    }

    private var colorScheme: ColorScheme? {
        switch services.userPreferences.themeMode {
        case .light: return .light
        case .dark: return .dark
        case .system: return nil
        }
    }
}
