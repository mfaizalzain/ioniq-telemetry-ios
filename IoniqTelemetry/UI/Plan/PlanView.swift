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
                            onStartDrive: startDrive
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
            .scrollDismissesKeyboard(.interactively)
            .refreshable { await viewModel?.loadNearbyChargers() }
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
                    services.activePlan.setIsNavigating(true)
                }
                Button("Not now") {
                    services.activePlan.setOccupancyTrackingEnabled(false)
                    services.activePlan.setIsNavigating(true)
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
            services.activePlan.setIsNavigating(true)
            return
        }
        showOccupancyPrompt = true
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
                    .tint(Color.appAccent)
                    // The system's label choice on the bright accent is unreadable.
                    .foregroundStyle(Color.appOnAccent)
                    .disabled(viewModel.aiBusy || viewModel.aiInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

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

    @State private var focusedSlot: PlanViewModel.Slot?
    @FocusState private var focusedField: PlanViewModel.Slot?

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                // Origin row
                SlotRow(
                    slot: .origin,
                    viewModel: viewModel,
                    focusedSlot: $focusedSlot,
                    focusedField: $focusedField,
                    placeholder: "Origin",
                    systemImage: "location.circle"
                )

                // Stopover rows
                ForEach(Array(viewModel.waypoints.enumerated()), id: \.offset) { i, _ in
                    HStack(spacing: 6) {
                        SlotRow(
                            slot: .waypoint(i),
                            viewModel: viewModel,
                            focusedSlot: $focusedSlot,
                            focusedField: $focusedField,
                            placeholder: "Stopover \(i + 1)",
                            systemImage: "mappin.and.ellipse"
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
                    focusedSlot: $focusedSlot,
                    focusedField: $focusedField,
                    placeholder: "Destination",
                    systemImage: "flag.circle"
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

                // Plan button
                HStack {
                    Button(viewModel.canPlan ? "Plan" : "Select both endpoints") {
                        Task { await viewModel.plan() }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Color.appAccent)
                    // The system's label choice on the bright accent is unreadable.
                    .foregroundStyle(Color.appOnAccent)
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
    @Binding var focusedSlot: PlanViewModel.Slot?
    @FocusState.Binding var focusedField: PlanViewModel.Slot?
    let placeholder: String
    let systemImage: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage)
                .foregroundStyle(slot == .destination ? Color.appAccent : .secondary)
            TextField(placeholder, text: Binding(
                get: { viewModel.endpoint(for: slot).query },
                set: { viewModel.setQuery($0, for: slot) }
            ))
            .focused($focusedField, equals: slot)
            .font(.subheadline)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .onChange(of: focusedField) {
                focusedSlot = $1
            }

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
            } else if viewModel.endpoint(for: slot).isSearching {
                ProgressView().scaleEffect(0.7)
            }
        }
        .padding(8)
        .background(Color(.systemGray6), in: RoundedRectangle(cornerRadius: 8))
        // Show suggestions when this slot has focus and results exist
        .overlay(alignment: .topLeading) {
            if focusedSlot == slot {
                let suggestions = viewModel.endpoint(for: slot).suggestions
                if !suggestions.isEmpty || viewModel.endpoint(for: slot).query.count >= 3 {
                    SuggestionsDropdown(
                        suggestions: suggestions,
                        onSelect: { viewModel.select($0, for: slot) },
                        onUseCurrentLocation: { Task { await viewModel.useCurrentLocation() } },
                        favorites: viewModel.favoritePlaces,
                        onSelectFavorite: { viewModel.selectFavorite($0, for: slot) },
                        onAddFavoriteAsWaypoint: { viewModel.addFavoriteAsWaypoint($0) },
                        query: viewModel.endpoint(for: slot).query,
                        slot: slot
                    )
                    .offset(y: 40)
                    .zIndex(100)
                }
            }
        }
        .zIndex(focusedSlot == slot ? 10 : 0)
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
                    Text("\(Int(plan.stops.reduce(0) { $0 + $1.energyAddedKwh })) kWh · \(plan.stops.count) stop(s)")
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
                .tint(Color.appAccent)
                // The system's label choice on the bright accent is unreadable.
                .foregroundStyle(Color.appOnAccent)
                .disabled(tripName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding()
    }
}

// MARK: - Suggestions dropdown

private struct SuggestionsDropdown: View {
    let suggestions: [PlaceResult]
    let onSelect: (PlaceResult) -> Void
    let onUseCurrentLocation: () -> Void
    let favorites: [SavedPlaceEntity]
    let onSelectFavorite: (SavedPlaceEntity) -> Void
    let onAddFavoriteAsWaypoint: (SavedPlaceEntity) -> Void
    let query: String
    let slot: PlanViewModel.Slot

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Current location
            Button {
                onUseCurrentLocation()
            } label: {
                Label("Current location", systemImage: "location.circle")
                    .font(.subheadline).padding(8)
            }
            .buttonStyle(.plain)

            if !favorites.isEmpty {
                Divider()
                ForEach(favorites) { fav in
                    HStack {
                        Button {
                            onSelectFavorite(fav)
                        } label: {
                            Label(fav.name, systemImage: "star.fill")
                                .font(.subheadline).padding(8)
                        }
                        .buttonStyle(.plain)
                        if slot != .destination && slot != .origin {
                            Button {
                                onAddFavoriteAsWaypoint(fav)
                            } label: {
                                Image(systemName: "plus.circle")
                                    .foregroundStyle(.tertiary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }

            if !suggestions.isEmpty {
                Divider()
                ForEach(suggestions) { suggestion in
                    Button {
                        onSelect(suggestion)
                    } label: {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(suggestion.name).font(.subheadline)
                            if !suggestion.subtitle.isEmpty {
                                Text(suggestion.subtitle).font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                        .padding(8)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .frame(maxWidth: 300)
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

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: status.isFull ? "bolt.slash" : "bolt.fill")
                .font(.caption2)
            Text(status.isFull
                 ? "All connectors busy"
                 : "\(status.available) of \(status.total) connectors free")
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

                    ForEach(viewModel.nearbyChargers.prefix(6)) { charger in
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
