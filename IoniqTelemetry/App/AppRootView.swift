import SwiftUI
import CoreUI

struct AppRootView: View {
    @Binding var selectedTab: AppTab
    @Environment(AppServices.self) private var services

    var body: some View {
        TabView(selection: $selectedTab) {
            DashboardPlaceholderView()
                .tabItem { Label(AppTab.dashboard.rawValue, systemImage: AppTab.dashboard.icon) }
                .tag(AppTab.dashboard)

            TripsPlaceholderView()
                .tabItem { Label(AppTab.trips.rawValue, systemImage: AppTab.trips.icon) }
                .tag(AppTab.trips)

            PlanPlaceholderView()
                .tabItem { Label(AppTab.plan.rawValue, systemImage: AppTab.plan.icon) }
                .tag(AppTab.plan)

            SettingsPlaceholderView()
                .tabItem { Label(AppTab.settings.rawValue, systemImage: AppTab.settings.icon) }
                .tag(AppTab.settings)
        }
        .tint(Color(red: 0.09, green: 0.91, blue: 0.76))
    }
}

// MARK: - Placeholder Views (to be replaced by real screens)

struct DashboardPlaceholderView: View {
    var body: some View {
        NavigationStack {
            Text("Dashboard")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
                .navigationTitle("Dashboard")
        }
    }
}

struct TripsPlaceholderView: View {
    var body: some View {
        NavigationStack {
            Text("Trips")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
                .navigationTitle("Trips")
        }
    }
}

struct PlanPlaceholderView: View {
    var body: some View {
        NavigationStack {
            Text("Plan")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
                .navigationTitle("Plan")
        }
    }
}

struct SettingsPlaceholderView: View {
    var body: some View {
        NavigationStack {
            Text("Settings")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
                .navigationTitle("Settings")
        }
    }
}
