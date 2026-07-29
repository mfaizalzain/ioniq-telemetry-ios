import Combine
import CoreData
import CoreDomain
import Foundation

/// Trip history backed by `TripLogRepository`.
///
/// Reads through the repository rather than `@Query` so pending in-memory samples
/// are flushed first — a trip that just ended is otherwise missing its tail.
@Observable
@MainActor
final class TripsViewModel {

    struct MonthGroup: Identifiable {
        let id: String
        let title: String
        let trips: [TripEntity]
    }

    private(set) var trips: [TripEntity] = []
    private(set) var chargeSessions: [ChargeSessionEntity] = []
    private(set) var summary: TripSummary?
    private(set) var errorMessage: String?
    private(set) var unitSystem: UnitSystem = .metric
    private(set) var isPro = false
    private(set) var aiKey: String?
    private(set) var aiProvider = AiProvider.gemini
    private(set) var aiFeaturesEnabled = true

    /// Vehicle baseline efficiency in kWh/100km. Derived from recent trips when data
    /// is available, or nil before enough data exists.
    var efficiencyBaseline: Double? {
        let completed = trips.filter { $0.endTime != nil && $0.avgConsumptionKwhPer100km != nil && $0.avgConsumptionKwhPer100km! > 0 }
        guard completed.count >= 3 else { return nil }
        let avg = completed.compactMap { Double($0.avgConsumptionKwhPer100km!) }.reduce(0, +) / Double(completed.count)
        return avg
    }

    /// Set after a delete so the UI can offer an undo before the row is gone for good.
    private(set) var recentlyDeleted: TripEntity?

    private let services: AppServices
    private var cancellables = Set<AnyCancellable>()

    init(services: AppServices) {
        self.services = services
        services.preferences.preferences
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in
                self?.unitSystem = $0.unitSystem
                self?.aiKey = $0.aiKey
                self?.aiProvider = $0.aiProvider
                self?.aiFeaturesEnabled = $0.aiFeaturesEnabled
            }
            .store(in: &cancellables)

        services.entitlement.isPro
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.isPro = $0 }
            .store(in: &cancellables)
    }

    // MARK: - Loading

    func refresh() {
        do {
            trips = try services.tripLog.trips()
            chargeSessions = try services.tripLog.chargeSessions()
            summary = try services.tripLog.getTripSummary(from: .distantPast, to: .distantFuture)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    var monthGroups: [MonthGroup] {
        let keyFormatter = DateFormatter()
        keyFormatter.dateFormat = "yyyy-MM"
        let titleFormatter = DateFormatter()
        titleFormatter.setLocalizedDateFormatFromTemplate("MMMM yyyy")

        return Dictionary(grouping: trips) { keyFormatter.string(from: $0.startTime) }
            .sorted { $0.key > $1.key }
            .map { key, value in
                MonthGroup(
                    id: key,
                    title: titleFormatter.string(from: value[0].startTime),
                    trips: value.sorted { $0.startTime > $1.startTime }
                )
            }
    }

    // MARK: - Mutations

    func delete(_ trip: TripEntity) {
        do {
            try services.tripLog.deleteTrip(id: trip.id)
            recentlyDeleted = trip
            refresh()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// No undo here, unlike trips: a charge session has no restore path in the
    /// repository, so the UI confirms before calling this.
    func deleteChargeSession(_ session: ChargeSessionEntity) {
        do {
            try services.tripLog.deleteChargeSession(id: session.id)
            refresh()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func undoDelete() {
        guard let trip = recentlyDeleted else { return }
        do {
            try services.tripLog.restoreTrip(trip)
            recentlyDeleted = nil
            refresh()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func dismissUndo() { recentlyDeleted = nil }

    func setNote(_ note: String?, for trip: TripEntity) {
        do {
            try services.tripLog.setTripNote(id: trip.id, note: note)
            refresh()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func samples(for trip: TripEntity) -> [SampleEntity] {
        (try? services.tripLog.samplesForTrip(tripId: trip.id)) ?? []
    }

    // MARK: - Formatting

    func distance(_ km: Float) -> String {
        unitSystem == .imperial
            ? String(format: "%.1f mi", km * 0.621371)
            : String(format: "%.1f km", km)
    }

    var distanceUnit: String { unitSystem == .imperial ? "mi" : "km" }

    /// Consumption is conventionally shown per 100 km (metric) or as mi/kWh
    /// (imperial), which is a reciprocal — not just a scaled value.
    func efficiency(_ kwhPer100km: Float?) -> String {
        guard let kwhPer100km, kwhPer100km > 0 else { return "—" }
        if unitSystem == .imperial {
            let milesPerKwh = 62.1371 / kwhPer100km
            return String(format: "%.1f mi/kWh", milesPerKwh)
        }
        return String(format: "%.1f kWh/100km", kwhPer100km)
    }

    func duration(_ trip: TripEntity) -> String {
        guard let end = trip.endTime else { return "In progress" }
        return formatMinutes(Int(end.timeIntervalSince(trip.startTime) / 60))
    }

    func duration(_ session: ChargeSessionEntity) -> String {
        guard let end = session.endTime else { return "Charging…" }
        return formatMinutes(Int(end.timeIntervalSince(session.startTime) / 60))
    }

    private func formatMinutes(_ minutes: Int) -> String {
        minutes >= 60
            ? "\(minutes / 60)h \(minutes % 60)m"
            : "\(minutes)m"
    }
}
