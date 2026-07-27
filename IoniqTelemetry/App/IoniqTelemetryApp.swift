import SwiftUI
import CoreDomain
import CoreData
import CoreOBD
import CoreRouting
import CoreUI

@main
struct IoniqTelemetryApp: App {
    @State private var appServices = AppServices()
    @State private var selectedTab: AppTab = .dashboard

    var body: some Scene {
        WindowGroup {
            AppRootView(selectedTab: $selectedTab)
                .environment(appServices)
                .task {
                    await appServices.initialize()
                }
        }
    }
}

enum AppTab: String, CaseIterable {
    case dashboard = "Dashboard"
    case trips = "Trips"
    case plan = "Plan"
    case settings = "Settings"

    var icon: String {
        switch self {
        case .dashboard: return "gauge"
        case .trips: return "list.bullet"
        case .plan: return "map"
        case .settings: return "gear"
        }
    }
}
