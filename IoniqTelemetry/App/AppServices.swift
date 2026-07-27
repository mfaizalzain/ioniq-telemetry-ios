import Foundation
import CoreDomain
import CoreData
import CoreOBD
import CoreRouting

@Observable
@MainActor
final class AppServices {
    // These will be replaced with real implementations as packages are built
    var isInitialized = false

    func initialize() async {
        // Placeholder — real services will be wired in Phase 2-5
        isInitialized = true
    }
}
