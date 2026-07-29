import Combine
import CoreDomain
import Testing
@testable import CoreData

struct ActivePlanHolderTests {

    @Test("isNavigating defaults to false")
    func defaultsToFalse() {
        let holder = ActivePlanHolderImpl()
        #expect(holder.currentIsNavigating == false)
    }

    @Test("setIsNavigating(true) sets flag")
    func setIsNavigatingTrue() {
        let holder = ActivePlanHolderImpl()
        holder.setIsNavigating(true)
        #expect(holder.currentIsNavigating == true)
    }

    @Test("setIsNavigating(false) clears flag after being set")
    func setIsNavigatingFalse() {
        let holder = ActivePlanHolderImpl()
        holder.setIsNavigating(true)
        holder.setIsNavigating(false)
        #expect(holder.currentIsNavigating == false)
    }

    @Test("clearPlan resets isNavigating to false")
    func clearPlanResets() {
        let holder = ActivePlanHolderImpl()
        holder.setIsNavigating(true)
        holder.clearPlan()
        #expect(holder.currentIsNavigating == false)
    }

    @Test("publisher emits correct values")
    func publisherEmitsValues() {
        let holder = ActivePlanHolderImpl()
        var values: [Bool] = []
        let cancellable = holder.isNavigating
            .sink { values.append($0) }

        holder.setIsNavigating(true)
        holder.setIsNavigating(false)
        holder.setIsNavigating(true)

        #expect(values == [false, true, false, true])
        _ = cancellable
    }
}
