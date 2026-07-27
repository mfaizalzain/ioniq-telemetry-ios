import SwiftUI
import CoreDomain
import CoreData
import CoreOBD
import CoreRouting
import CoreUI
import SwiftData

@main
struct IoniqTelemetryApp: App {
    // Shared with the CarPlay scene so one adapter connection feeds both surfaces.
    private let appServices = AppServices.shared

    init() {
        IoniqTheme.apply()
    }

    var body: some Scene {
        WindowGroup {
            AppRootView()
                .environment(appServices)
                .modelContainer(AppDatabase.shared.container)
                .preferredColorScheme(.dark)
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
