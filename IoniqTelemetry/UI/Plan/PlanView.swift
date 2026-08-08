import Combine
import CoreData
import CoreDomain
import CoreRouting
import CoreUI
import SwiftUI

struct PlanView: View {
    @Environment(AppServices.self) private var services
    @State private var viewModel: PlanViewModel?
    @State private var showSaveTrip = false
    @State private var tripName = ""
    /// Drive-start occupancy opt-in, asked once per drive while the car is
    /// connected and the user has enabled occupancy alerts in Settings.
    @State private var showOccupancyPrompt = false
    /// Latest adapter link state; drives both the refresh-on-connect behaviour
    /// and whether the drive-start prompt is offered at all.
    @State private var vehicleConnected = false
    @State private var connectionCancellable: AnyCancellable?
    /// Slot whose full-screen search sheet is presented; nil = no sheet.
    @State private var searchTarget: SlotTarget?

    var body: some View {
        NavigationStack {
            ScrollView {
                if let viewModel {
                    LazyVStack(spacing: 16) {
                        if let notice = viewModel.routingNotice {
                            RoutingNoticeBar(message: notice, onDismiss: viewModel.dismissRoutingNotice)
                        }

                        if viewModel.canUseAi {
                            AiPlanCard(viewModel: viewModel)
                        }
                        RouteBuilderCard(
                            viewModel: viewModel,
                            showSaveTrip: $showSaveTrip,
                            vehicleConnected: vehicleConnected,
                            onStartDrive: startDrive,
                            onActivateSlot: { searchTarget = SlotTarget(slot: $0) }
                        )

                        if let plan = viewModel.plan {
                            ItineraryTimeline(plan: plan, viewModel: viewModel, showSaveTrip: $showSaveTrip, onNavigate: startDrive)
                        }

                        ChargersAlongRouteSection(viewModel: viewModel)
                        NearbyChargersSection(viewModel: viewModel)

                        Spacer(minLength: 120)
                    }
                    .padding(.horizontal)
                }
            }
            .background(Color.appBackground)
            .scrollDismissesKeyboard(.interactively)
            .refreshable { await viewModel?.loadNearbyChargers() }
            // Full-screen place search (Apple Maps style): tapping a slot opens a
            // sheet with its own search field, so results are never clipped by
            // the card stack or hidden behind the keyboard. The sheet also
            // carries saved-places and saved-trips management (delete, load).
            .sheet(item: $searchTarget) { target in
                if let vm = viewModel {
                    PlaceSearchSheet(slot: target.slot, viewModel: vm)
                }
            }
            .navigationTitle("Trip plan")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    if viewModel?.plan != nil {
                        HStack(spacing: 17) {
                            Button { startDrive() } label: {
                                HStack(spacing: 4) {
                                    Image(systemName: "location.fill")
                                    Text("Go").font(.caption.weight(.semibold))
                                }
                                .font(.callout)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(Color.appAccent, in: Capsule())
                                .foregroundStyle(Color.appOnAccent)
                            }
                        }
                    }
                }
            }
            .task {
                if viewModel == nil {
                    viewModel = await PlanViewModel(services: services)
                }
                connectionCancellable = services.telemetry.connectionState
                    .receive(on: DispatchQueue.main)
                    .sink { vehicleConnected = ($0 == .connected) }
            }
            .onChange(of: vehicleConnected) { _, connected in
                if connected {
                    Task { await viewModel?.loadNearbyChargers() }
                }
            }
            .confirmationDialog("Live occupancy alerts?", isPresented: $showOccupancyPrompt, titleVisibility: .visible) {
                Button("Enable") {
                    services.activePlan.setOccupancyTrackingEnabled(true)
                    beginNavigation()
                }
                Button("Not now") {
                    services.activePlan.setOccupancyTrackingEnabled(false)
                    beginNavigation()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Enable live charger occupancy tracking for this drive?")
            }
        }
        .sheet(isPresented: $showSaveTrip) {
            SaveTripSheet(viewModel: viewModel, tripName: $tripName, showSaveTrip: $showSaveTrip)
                .presentationDetents([.height(200)])
        }
    }

    /// Quick-access prompts that appear below the AI input field when empty.
    private static let quickPrompt = "Find chargers near me"

    /// Starts the drive. With the car connected and occupancy alerts enabled in
    /// Settings, the driver is asked once per drive whether live occupancy
    /// tracking should run (it bills Google Places per request); otherwise the
    /// drive starts straight away.
    private func startDrive() {
        guard vehicleConnected, services.userPreferences.chargerOccupancyAlerts else {
            beginNavigation()
            return
        }
        showOccupancyPrompt = true
    }

    /// Flips the active plan into navigating state and hands the whole route —
    /// origin, every stopover and charge stop, destination — to Google Maps as
    /// waypoints. With no plan there is nothing to hand off, so only the flag
    /// changes (occupancy/reroute monitoring still runs for free drives).
    private func beginNavigation() {
        services.activePlan.setIsNavigating(true)
        guard let plan = viewModel?.plan else { return }
        MapsNavigation.navigateTrip(plan)
    }
}

// MARK: - AI plan card

/// Natural-language trip planning: type a request and the configured AI provider
/// extracts the destination and waypoints. Gated on `canUseAi` by the caller.
private struct AiPlanCard: View {
    let viewModel: PlanViewModel

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Image(systemName: "sparkles")
                        .foregroundStyle(Color.appAccent)
                    Text("Plan by conversation")
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    Text(viewModel.aiProviderLabel.uppercased())
                        .font(.caption2.weight(.bold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.appAccent.opacity(0.15), in: Capsule())
                        .foregroundStyle(Color.appAccent)
                }

                TextField("e.g. Drive to the airport, charge to 80%", text: Binding(
                    get: { viewModel.aiInput },
                    set: { viewModel.aiInput = $0 }
                ))
                .textFieldStyle(.roundedBorder)
                .font(.subheadline)
                .disabled(viewModel.aiBusy)
                .onSubmit { Task { await viewModel.planFromNaturalLanguage() } }

                if viewModel.aiBusy {
                    HStack(spacing: 6) {
                        ProgressView()
                        Text("Planning…").font(.caption).foregroundStyle(.secondary)
                    }
                } else if let interpretation = viewModel.aiInterpretation {
                    Text(interpretation).font(.caption).foregroundStyle(.secondary)
                }

                if let error = viewModel.aiError {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.caption2)
                            .foregroundStyle(Color.appRed)
                        Text(error).font(.caption).foregroundStyle(Color.appRed)
                        Spacer()
                        Button { viewModel.dismissAiError() } label: {
                            Image(systemName: "xmark.circle.fill").font(.caption)
                        }
                        .buttonStyle(.plain)
                    }
                }

                HStack {
                    Button {
                        Task { await viewModel.planFromNaturalLanguage() }
                    } label: {
                        if viewModel.aiBusy {
                            ProgressView().scaleEffect(0.8)
                        } else {
                            Label("Plan trip", systemImage: "sparkles")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(viewModel.canRunAi ? Color.appAccent : Color(.systemGray4))
                    // The system's label choice on the bright accent is unreadable;
                    // the disabled state must be visibly gray, not a washed accent.
                    .foregroundStyle(viewModel.canRunAi ? Color.appOnAccent : Color.secondary)
                    .disabled(!viewModel.canRunAi)

                    Spacer()

                    if !viewModel.aiInput.isEmpty {
                        Button("Clear") { viewModel.clearAiInput() }
                            .font(.caption)
                    }
                }
            }
        }
    }
}

// MARK: - Route builder card

private struct RouteBuilderCard: View {
    @Environment(AppServices.self) private var services
    let viewModel: PlanViewModel
    @Binding var showSaveTrip: Bool
    /// Whether the adapter is connected; the drive-start occupancy prompt is
    /// only offered when live data is actually flowing.
    let vehicleConnected: Bool
    /// Runs the drive-start flow (possible occupancy opt-in prompt, then
    /// navigation), owned by `PlanView` so both start buttons share one prompt.
    let onStartDrive: () -> Void

    /// Opens the full-screen search sheet for a slot.
    let onActivateSlot: (PlanViewModel.Slot) -> Void

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                // Origin row
                SlotRow(
                    slot: .origin,
                    viewModel: viewModel,
                    placeholder: "Origin",
                    systemImage: "location.circle",
                    onActivate: { onActivateSlot(.origin) }
                )

                // Stopover rows
                ForEach(Array(viewModel.waypoints.enumerated()), id: \.offset) { i, _ in
                    HStack(spacing: 6) {
                        SlotRow(
                            slot: .waypoint(i),
                            viewModel: viewModel,
                            placeholder: "Stopover \(i + 1)",
                            systemImage: "mappin.and.ellipse",
                            onActivate: { onActivateSlot(.waypoint(i)) }
                        )
                        Button { viewModel.removeWaypoint(at: i) } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.tertiary)
                        }
                        .buttonStyle(.plain)
                    }
                }

                // Destination row
                SlotRow(
                    slot: .destination,
                    viewModel: viewModel,
                    placeholder: "Destination",
                    systemImage: "flag.circle",
                    onActivate: { onActivateSlot(.destination) }
                )

                // Control rows
                HStack {
                    Button { viewModel.addWaypoint() } label: {
                        Label("Add stop", systemImage: "plus.circle")
                            .font(.caption)
                    }
                    Spacer()
                    Button { viewModel.swapEndpoints() } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.up.arrow.down")
                            Text("Swap ends").font(.caption)
                        }
                    }
                }

                // Charge corridor slider
                HStack {
                    Text("CHARGER CORRIDOR")
                        .font(.ioniqCaption).foregroundStyle(.secondary).ioniqStatLabel()
                    Spacer()
                    Text("\(Int(viewModel.corridorRadiusKm)) km").font(.caption).foregroundStyle(.secondary)
                }
                Slider(value: Binding(
                    get: { viewModel.corridorRadiusKm },
                    set: { viewModel.setCorridorRadius($0) }
                ), in: 2...30, step: 1)

                // Starting battery — live SOC from the car when connected, or a
                // manual slider. Mirrors Android's "Advanced" battery section.
                HStack {
                    Text("STARTING BATTERY")
                        .font(.ioniqCaption).foregroundStyle(.secondary).ioniqStatLabel()
                    Spacer()
                    Text("\(Int(viewModel.departureSoc))%")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(Color.appOnAccent)
                        .padding(.horizontal, 8).padding(.vertical, 2)
                        .background(Color.appAccent, in: Capsule())
                }

                if viewModel.usesLiveSoc && viewModel.liveSocAvailable {
                    HStack(spacing: 6) {
                        Label("Live from vehicle", systemImage: "bolt.car")
                            .font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("Set manually") {
                            viewModel.setDepartureSoc(viewModel.departureSoc)
                        }
                        .font(.caption)
                    }
                } else {
                    Slider(value: Binding(
                        get: { viewModel.departureSoc },
                        set: { viewModel.setDepartureSoc($0) }
                    ), in: 10...100, step: 1)
                    if viewModel.liveSocAvailable {
                        // Vehicle connected but the driver took the slider — offer
                        // to hand tracking back to the car.
                        HStack(spacing: 6) {
                            Label("Manual value", systemImage: "slider.horizontal.3")
                                .font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            Button("Use live SOC") { viewModel.useLiveSoc() }
                                .font(.caption)
                        }
                    } else {
                        Label("Vehicle disconnected — using manual value", systemImage: "car.slash")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }

                // Target arrival battery
                HStack {
                    Text("TARGET ARRIVAL BATTERY")
                        .font(.ioniqCaption).foregroundStyle(.secondary).ioniqStatLabel()
                    Spacer()
                    Text("\(Int(viewModel.arrivalReserve))%")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(Color.appOnAccent)
                        .padding(.horizontal, 8).padding(.vertical, 2)
                        .background(Color.appAccent, in: Capsule())
                }
                Slider(value: Binding(
                    get: { viewModel.arrivalReserve },
                    set: { viewModel.setArrivalReserve($0) }
                ), in: 5...50, step: 5)

                // Plan button
                HStack {
                    Button(viewModel.canPlan ? "Plan" : "Select both endpoints") {
                        Task { await viewModel.plan() }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(viewModel.canPlan ? Color.appAccent : Color(.systemGray4))
                    // The system's label choice on the bright accent is unreadable;
                    // the disabled state must be visibly gray, not a washed accent.
                    .foregroundStyle(viewModel.canPlan ? Color.appOnAccent : Color.secondary)
                    .disabled(!viewModel.canPlan)

                    if let msg = viewModel.errorMessage {
                        Text(msg)
                            .font(.caption).foregroundStyle(Color.appRed)
                    }
                }

                 if let msg = viewModel.statusMessage {
                    HStack(spacing: 6) {
                        ProgressView().scaleEffect(0.7)
                        Text(msg).font(.caption).foregroundStyle(.secondary)
                    }
                }

                // Distinct from errorMessage: the plan is usable, the charger data
                // just might be stale.
                if viewModel.chargersAreCached {
                    HStack(spacing: 4) {
                        Image(systemName: "exclamationmark.triangle").font(.caption)
                        Text("Charger data couldn't be refreshed — showing saved results, which may be out of date.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }

                // Restore excluded chargers banner
                if !viewModel.excludedChargerIds.isEmpty {
                    Button {
                        viewModel.restoreExcludedChargers()
                    } label: {
                        Label("Restore \(viewModel.excludedChargerIds.count) excluded chargers",
                              systemImage: "arrow.counterclockwise.circle")
                            .font(.caption).foregroundStyle(Color.appAccent)
                    }
                }

                // Play / Stop buttons — show only on an active plan
                if viewModel.plan != nil && !viewModel.isPlanning {
                    HStack(spacing: 12) {
                        Button { onStartDrive() } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "play.fill")
                                Text("Start driving").font(.caption.weight(.semibold))
                            }
                            .padding(.horizontal, 20).padding(.vertical, 8)
                            .background(Color.appAccent, in: Capsule())
                            .foregroundStyle(Color.appOnAccent)
                        }
                        Button {
                            viewModel.clearPlan()
                            services.activePlan.clearPlan()
                            services.activePlan.setIsNavigating(false)
                        } label: {
                            Text("Cancel trip").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .backgroundStyle(.ultraThinMaterial)
    }
}

// MARK: - Slot row

private struct SlotRow: View {
    let slot: PlanViewModel.Slot
    let viewModel: PlanViewModel
    let placeholder: String
    let systemImage: String
    /// Opens the full-screen search sheet for this slot.
    let onActivate: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage)
                .foregroundStyle(slot == .destination ? Color.appAccent : .secondary)
            Button(action: onActivate) {
                HStack {
                    Text(displayText)
                        .font(.subheadline)
                        .foregroundStyle(hasValue ? .primary : .secondary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if let selected = viewModel.endpoint(for: slot).selected {
                if viewModel.isFavorite(selected) {
                    Image(systemName: "star.fill")
                        .font(.caption).foregroundStyle(Color.appAmber)
                }
                Button { viewModel.clearEndpoint(slot) } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(8)
        .background(Color(.systemGray6), in: RoundedRectangle(cornerRadius: 8))
    }

    /// The row is display-only: it shows what the slot holds (or a placeholder)
    /// and tapping it opens the full-screen search sheet — see `PlaceSearchSheet`.
    private var displayText: String {
        let endpoint = viewModel.endpoint(for: slot)
        return endpoint.selected?.name ?? (endpoint.query.isEmpty ? placeholder : endpoint.query)
    }

    private var hasValue: Bool {
        let endpoint = viewModel.endpoint(for: slot)
        return endpoint.selected != nil || !endpoint.query.trimmingCharacters(in: .whitespaces).isEmpty
    }
}

// MARK: - Itinerary timeline

private struct ItineraryTimeline: View {
    let plan: TripPlan
    let viewModel: PlanViewModel
    @Binding var showSaveTrip: Bool
    let onNavigate: () -> Void

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 0) {
                // Summary header
                HStack {
                    Image(systemName: "battery.100.bolt")
                        .foregroundStyle(Color.appAccent)
                    Text("\(Int(plan.stops.reduce(0) { $0 + $1.energyAddedKwh })) kWh · \(plan.stops.count) stop(s)"
                        + (plan.totalChargingCost.map {
                            " · ~\(currencySymbol(from: plan.stops.first?.charger.usageCost))\(String(format: "%.2f", $0)) charging"
                        } ?? ""))
                        .font(.subheadline.weight(.medium))
                    Spacer()
                    Button { showSaveTrip = true } label: {
                        Image(systemName: "bookmark").font(.caption)
                    }
                }
                .padding(.bottom, 12)

                // Legs
                ForEach(Array(plan.legs.enumerated()), id: \.offset) { i, leg in
                    LegRow(leg: leg, index: i, totalLegs: plan.legs.count)
                }

                Divider().padding(.vertical, 8)

                // Stop cards (origin, chargers, destination). Rows are keyed on a
                // stable id (charger id for charger stops) so re-solving the plan
                // after an exclusion does not invalidate a row mid-tap.
                let stopRows = plan.stops.enumerated().map { index, stop in
                    StopRow(
                        id: "charger-\(stop.charger.id)",
                        index: index,
                        stop: stop
                    )
                }
                ForEach(stopRows) { row in
                    StopCard(stop: row.stop, index: row.index, totalStops: plan.stops.count, viewModel: viewModel)
                }
            }
        }
        .backgroundStyle(.ultraThinMaterial)
    }
}

/// The currency symbol implied by a raw OCM cost string ("£0.45/kWh" → "£").
private func currencySymbol(from raw: String?) -> String {
    guard let raw else { return "" }
    let codes = [("USD", "$"), ("EUR", "€"), ("GBP", "£"), ("AUD", "$"), ("CAD", "$")]
    for (code, symbol) in codes where raw.uppercased().contains(code) { return symbol }
    return raw.first { "$€£¥".contains($0) }.map(String.init) ?? ""
}

private struct LegRow: View {
    let leg: TripLeg
    let index: Int
    let totalLegs: Int

    var body: some View {
        HStack(spacing: 8) {
            VStack(spacing: 0) {
                Circle().fill(Color.appAccent).frame(width: 8, height: 8)
                Rectangle().fill(Color.appAccent.opacity(0.3)).frame(width: 2, height: 30)
                if index == totalLegs - 1 { Circle().fill(Color.appAccent).frame(width: 8, height: 8) }
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("\(String(format: "%.0f", leg.distanceKm)) km · \(leg.driveMinutes) min")
                    .font(.caption.weight(.medium))
                if leg.startSoc > 0 || leg.endSoc > 0 {
                    Text("SOC \(Int(leg.startSoc))% → \(Int(leg.endSoc))%")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.leading, 4)
    }
}

// Stable identity for a stop card row: charger stops are keyed on their charger
// id, plain stops on their position, so a plan re-solve never shifts identity
// under an in-flight tap.
private struct StopRow: Identifiable {
    let id: String
    let index: Int
    let stop: ChargeStop
}

private struct StopCard: View {
    let stop: ChargeStop
    let index: Int
    let totalStops: Int
    let viewModel: PlanViewModel

    var body: some View {
        HStack(spacing: 8) {
            ZStack {
                Circle().fill(index == 0 || index == totalStops - 1 ? Color.appAccent : Color.appAccent.opacity(0.6))
                    .frame(width: 24, height: 24)
                Text("\(index + 1)").font(.caption.weight(.bold)).foregroundStyle(Color.appOnAccent)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(stop.charger.name).font(.subheadline.weight(.medium))
                if let address = stop.charger.address {
                    Text(address).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                let kw = stop.charger.maxPowerKw
                HStack(spacing: 4) {
                    if kw > 0 {
                        Text(String(format: "%.0f kW", kw)).font(.caption.weight(.semibold))
                    }
                    if let price = stop.charger.pricePerKwh, price > 0 {
                        Text(String(format: "$%.2f/kWh", price)).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }

            Spacer()

            // Direct button, not just a Menu item: fires on the first tap. Menu
            // items can be dropped when the exclusion re-solves the plan (and the
            // stops array changes) while the menu is dismissing.
            Button {
                viewModel.excludeChargerAndReplan(stop.charger.id)
            } label: {
                Image(systemName: "xmark.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Avoid this charger — re-route")

            Menu {
                Button {
                    viewModel.setDestination(charger: stop.charger)
                } label: {
                    Label("Navigate here", systemImage: "arrow.triangle.turn.up.right.diamond")
                }
                Button {
                    viewModel.excludeChargerAndReplan(stop.charger.id)
                } label: {
                    Label("Avoid this charger — re-route", systemImage: "arrow.triangle.branch")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .foregroundStyle(.secondary)
            }
            .accessibilityLabel("Options for \(stop.charger.name)")
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Save trip sheet

private struct SaveTripSheet: View {
    let viewModel: PlanViewModel?
    @Binding var tripName: String
    @Binding var showSaveTrip: Bool

    private var canSave: Bool {
        !tripName.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        VStack(spacing: 16) {
            Text("Save trip").font(.headline)
            TextField("Trip name", text: $tripName)
                .textFieldStyle(.roundedBorder)
            HStack {
                Button("Cancel") { showSaveTrip = false }
                    .buttonStyle(.bordered)
                Button("Save") {
                    viewModel?.saveTrip(named: tripName)
                    showSaveTrip = false
                }
                .buttonStyle(.borderedProminent)
                .tint(canSave ? Color.appAccent : Color(.systemGray4))
                // The system's label choice on the bright accent is unreadable;
                // the disabled state must be visibly gray, not a washed accent.
                .foregroundStyle(canSave ? Color.appOnAccent : Color.secondary)
                .disabled(!canSave)
            }
        }
        .padding()
    }
}

// MARK: - Place search sheet
//
// Apple Maps style: tapping a slot opens this full-screen sheet with its own
// search field. Being a modal sheet it is always above the card stack and the
// keyboard, so results are never clipped or hidden — the inline dropdown this
// replaces was clipped by the scroll stack and sat behind the keyboard. The
// sheet also exposes saved-places and saved-trips management (delete, load)
// for parity with Android, which shows chips and a saved-trips row on the plan
// card.

/// Identifiable wrapper so `.sheet(item:)` can present per-slot search.
private struct SlotTarget: Identifiable {
    let slot: PlanViewModel.Slot

    var id: String {
        switch slot {
        case .origin: return "origin"
        case .destination: return "destination"
        case .waypoint(let index): return "waypoint-\(index)"
        }
    }
}

/// What the confirmation dialog is about to delete.
private enum PendingDelete: Identifiable {
    case favorite(SavedPlaceEntity)
    case trip(SavedTrip)

    var id: String {
        switch self {
        case .favorite(let favorite): return "favorite-\(favorite.id)"
        case .trip(let trip): return "trip-\(trip.id)"
        }
    }
}

private struct PlaceSearchSheet: View {
    let slot: PlanViewModel.Slot
    let viewModel: PlanViewModel

    @Environment(\.dismiss) private var dismiss
    @FocusState private var searchFieldFocused: Bool
    /// Single delete target so the two confirmation dialogs can share one
    /// `.alert` — SwiftUI only honors the last `.alert` attached to a view.
    @State private var pendingDelete: PendingDelete?

    private var query: String { viewModel.endpoint(for: slot).query }
    private var suggestions: [PlaceResult] { viewModel.endpoint(for: slot).suggestions }
    private var isSearching: Bool { viewModel.endpoint(for: slot).isSearching }
    private var canSearch: Bool { query.trimmingCharacters(in: .whitespaces).count >= 3 }

    private var title: String {
        switch slot {
        case .origin: return "Set origin"
        case .destination: return "Set destination"
        case .waypoint(let index): return "Set stopover \(index + 1)"
        }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass")
                            .foregroundStyle(.secondary)
                        TextField("Search places", text: queryBinding)
                            .focused($searchFieldFocused)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                            .submitLabel(.search)
                        if !query.isEmpty {
                            Button { viewModel.setQuery("", for: slot) } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(.tertiary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                if canSearch {
                    searchResultsSection
                } else {
                    quickActionsSection
                    favoritesSection
                    savedTripsSection
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .onAppear { searchFieldFocused = true }
            .alert("Remove saved item?", isPresented: deleteBinding, presenting: pendingDelete) { target in
                switch target {
                case .favorite(let favorite):
                    Button("Remove", role: .destructive) { viewModel.deleteFavorite(favorite) }
                    Button("Cancel", role: .cancel) {}
                case .trip(let trip):
                    Button("Delete", role: .destructive) { viewModel.deleteTrip(trip) }
                    Button("Cancel", role: .cancel) {}
                }
            } message: { target in
                switch target {
                case .favorite(let favorite):
                    Text("Remove \u{201C}\(favorite.name)\u{201D} from your saved places?")
                case .trip(let trip):
                    Text("Delete \u{201C}\(trip.name)\u{201D} from your saved trips?")
                }
            }
        }
    }

    private var queryBinding: Binding<String> {
        Binding(
            get: { viewModel.endpoint(for: slot).query },
            set: { viewModel.setQuery($0, for: slot) }
        )
    }

    private var deleteBinding: Binding<Bool> {
        Binding(
            get: { pendingDelete != nil },
            set: { if !$0 { pendingDelete = nil } }
        )
    }

    @ViewBuilder private var searchResultsSection: some View {
        if isSearching {
            Section {
                HStack { Spacer(); ProgressView(); Spacer() }
            }
        } else if suggestions.isEmpty {
            Section {
                Text("No places found for \u{201C}\(query)\u{201D}.")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
        } else {
            Section("Results") {
                ForEach(suggestions) { suggestion in
                    Button {
                        viewModel.select(suggestion, for: slot)
                        dismiss()
                    } label: {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(suggestion.name).font(.subheadline)
                            if !suggestion.subtitle.isEmpty {
                                Text(suggestion.subtitle).font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    @ViewBuilder private var quickActionsSection: some View {
        Section {
            Button {
                Task {
                    await viewModel.useCurrentLocation(for: slot)
                    dismiss()
                }
            } label: {
                Label("Current location", systemImage: "location.circle")
            }
        }
    }

    @ViewBuilder private var favoritesSection: some View {
        if !viewModel.favoritePlaces.isEmpty {
            Section("Favorite places") {
                ForEach(viewModel.favoritePlaces) { favorite in
                    HStack(spacing: 4) {
                        Button {
                            viewModel.selectFavorite(favorite, for: slot)
                            dismiss()
                        } label: {
                            Label(favorite.name, systemImage: "star.fill")
                                .font(.subheadline)
                                .lineLimit(1)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        if slot != .destination && slot != .origin {
                            Button {
                                viewModel.addFavoriteAsWaypoint(favorite)
                            } label: {
                                Image(systemName: "plus.circle")
                                    .foregroundStyle(.tertiary)
                            }
                            .buttonStyle(.plain)
                        }
                        Button {
                            pendingDelete = .favorite(favorite)
                        } label: {
                            Image(systemName: "trash")
                                .foregroundStyle(.red)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    @ViewBuilder private var savedTripsSection: some View {
        if !viewModel.savedTrips.isEmpty {
            Section("Saved trips") {
                ForEach(viewModel.savedTrips) { trip in
                    HStack(spacing: 4) {
                        Button {
                            viewModel.loadTrip(trip)
                            dismiss()
                        } label: {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(trip.name).font(.subheadline)
                                Text("\(trip.def.origin.name) → \(trip.def.destination.name)")
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        Button {
                            pendingDelete = .trip(trip)
                        } label: {
                            Image(systemName: "trash")
                                .foregroundStyle(.red)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }
}

// MARK: - Routing notice bar

private struct RoutingNoticeBar: View {
    let message: String
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "info.circle").font(.caption)
            Text(message).font(.caption).foregroundStyle(.secondary)
            Spacer()
            Button(action: onDismiss) {
                Image(systemName: "xmark").font(.caption2)
            }
            .buttonStyle(.plain)
        }
        .padding(10)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
    }
}

// MARK: - Availability badge

private struct AvailabilityBadge: View {
    let status: PlanViewModel.ChargerAvailability

    private var label: String {
        if status.isFull { return "All connectors busy" }
        if status.total > 0 { return "\(status.available) of \(status.total) connectors free" }
        return "\(status.available) connectors free"
    }

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: status.isFull ? "bolt.slash" : "bolt.fill")
                .font(.caption2)
            Text(label)
        }
        .font(.caption2)
        .foregroundStyle(status.isFull ? Color.appRed : .green)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(status.isFull ? Color.appRed.opacity(0.1) : Color.green.opacity(0.1), in: Capsule())
    }
}

/// Results only — there is no empty state. The list is populated by asking the
/// planner's assistant for chargers nearby; a bare lookup button sitting under the
/// route sections read as a stray control with nothing around it.
private struct NearbyChargersSection: View {
    let viewModel: PlanViewModel

    var body: some View {
        if !viewModel.nearbyChargers.isEmpty {
            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("NEARBY CHARGERS")
                            .font(.ioniqCaption).foregroundStyle(.secondary).ioniqStatLabel()
                        Spacer()
                        Button("Clear") {
                            viewModel.clearNearbyChargers()
                        }
                        .font(.caption)
                    }

                    ForEach(viewModel.nearbyChargers) { charger in
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(charger.name).font(.subheadline).lineLimit(1)
                                if let address = charger.address {
                                    Text(address).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                                }
                                HStack(spacing: 6) {
                                    if let op = charger.operator {
                                        Text(op).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                    }
                                    if let price = ChargerPrice.label(for: charger) {
                                        Text(price)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                // Rows without a matched live-status station
                                // carry no badge at all — chargerAvailability
                                // only ever holds chargers flagged hasLiveStatus,
                                // so "full" can never be implied from absence.
                                if let status = viewModel.chargerAvailability[charger.id] {
                                    AvailabilityBadge(status: status)
                                }
                            }
                            Spacer()
                            Button {
                                viewModel.setDestination(charger: charger)
                            } label: {
                                Image(systemName: "arrow.triangle.turn.up.right.diamond")
                                    .font(.title3)
                                    .foregroundStyle(Color.appAccent)
                                    .padding(.leading, 8)
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.vertical, 3)
                    }
                }
            }
        }
    }
}

/// Lists all chargers found along the planned route corridor, matching Android's
/// behaviour. The user can browse, exclude, and set a charger as destination.
private struct ChargersAlongRouteSection: View {
    let viewModel: PlanViewModel

    /// Chargers still eligible for the current plan, excluded ones drop out of the
    /// list immediately after an "exclude" tap.
    private var visibleChargers: [RouteCharger] {
        viewModel.lastRouteChargers.filter { !viewModel.excludedChargerIds.contains($0.charger.id) }
    }

    var body: some View {
        if !visibleChargers.isEmpty || !viewModel.excludedChargerIds.isEmpty {
            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("CHARGERS ALONG ROUTE")
                            .font(.ioniqCaption).foregroundStyle(.secondary).ioniqStatLabel()
                        Spacer()
                        Text("\(visibleChargers.count) found")
                            .font(.caption).foregroundStyle(.secondary)
                    }

                    ForEach(Array(visibleChargers.enumerated()), id: \.element.charger.id) { i, rc in
                        ChargerAlongRouteCard(rc: rc, viewModel: viewModel)
                        if i < visibleChargers.count - 1 {
                            Divider()
                        }
                    }

                    if !viewModel.excludedChargerIds.isEmpty {
                        Button("Reset excluded chargers") {
                            viewModel.restoreExcludedChargers()
                        }
                        .font(.caption)
                    }
                }
            }
            .backgroundStyle(.ultraThinMaterial)
        }
    }
}

private struct ChargerAlongRouteCard: View {
    let rc: RouteCharger
    let viewModel: PlanViewModel

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(rc.charger.name)
                    .font(.subheadline.weight(.medium)).lineLimit(1)
                if let address = rc.charger.address {
                    Text(address).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                HStack(spacing: 6) {
                    if rc.charger.maxPowerKw > 0 {
                        Text(String(format: "%.0f kW", rc.charger.maxPowerKw))
                            .font(.caption.weight(.semibold))
                    }
                    Text(String(format: "%.1f km", rc.distanceAlongRouteKm))
                        .font(.caption).foregroundStyle(.secondary)
                    if rc.detourKm > 1 {
                        Text(String(format: "+%.1f km detour", rc.detourKm))
                            .font(.caption).foregroundStyle(Color.appAmber)
                    }
                }
                if ChargerPriceText(charger: rc.charger).isEmpty == false {
                    Text(ChargerPriceText(charger: rc.charger))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            // Direct button, not just a Menu item: fires on the first tap (see
            // StopCard for why Menu-only actions get dropped on re-solve).
            Button {
                viewModel.excludeChargerAndReplan(rc.charger.id)
            } label: {
                Image(systemName: "xmark.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Exclude from plan")

            Menu {
                Button {
                    viewModel.setDestination(charger: rc.charger)
                } label: {
                    Label("Set as destination", systemImage: "mappin.circle")
                }
                Button {
                    viewModel.excludeChargerAndReplan(rc.charger.id)
                } label: {
                    Label("Exclude from plan", systemImage: "xmark.circle")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 3)
    }
}

/// Returns a formatted price string for a charger, or empty string if unavailable.
private func ChargerPriceText(charger: Charger) -> String {
    if let price = charger.pricePerKwh, price > 0 {
        return String(format: "$%.2f/kWh", price)
    }
    if !(charger.usageCost ?? "").isEmpty {
        return charger.usageCost!
    }
    return ""
}

// MARK: - Charger price label

/// Tariff for a charger row.
private enum ChargerPrice {
    static func label(for charger: Charger) -> String? {
        if let price = charger.pricePerKwh {
            return String(format: "$%.2f/kWh", price)
        }
        guard let cost = charger.usageCost?.trimmingCharacters(in: .whitespacesAndNewlines),
              !cost.isEmpty else { return nil }
        return cost
    }
}
