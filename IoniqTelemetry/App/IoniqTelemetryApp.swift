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

    @Environment(\.scenePhase) private var scenePhase

    init() {
        // Auto-connect can relaunch this app in the background to hand back a
        // restored adapter link, and a background relaunch is not guaranteed to
        // present a scene — so the `.task` below may never run. `initialize()` is
        // idempotent, so starting it here as well covers both paths, and the trip
        // pipeline (`connectedCar.start()`) exists in either case.
        let services = AppServices.shared
        Task { await services.initialize() }
    }

    var body: some Scene {
        WindowGroup {
            AppRootView()
                .environment(appServices)
                .modelContainer(AppDatabase.shared.container)
                .task {
                    await appServices.initialize()
                }
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active {
                // While suspended, the supervisor Task freezes with the app, so a
                // trip whose frames stopped arriving can outlive its idle end.
                // Close it the moment we're back, before any new frames arrive.
                Task { @MainActor in
                    appServices.connectedCar.appDidBecomeActive()
                    await appServices.refreshEntitlements()
                }
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
