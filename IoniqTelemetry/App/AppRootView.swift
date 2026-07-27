import SwiftUI
import CoreUI

struct AppRootView: View {
    @Binding var selectedTab: AppTab
    @Environment(AppServices.self) private var services
    @State private var showCopilot = false
    @State private var showPaywall = false
    @State private var showConsole = false

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
        .tint(Color(red: 0.09, green: 0.91, blue: 0.76))
    }
}
