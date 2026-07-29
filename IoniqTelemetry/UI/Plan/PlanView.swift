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

    var body: some View {
        NavigationStack {
            ScrollView {
                if let viewModel {
                    LazyVStack(spacing: 16) {
                        if let notice = viewModel.routingNotice {
                            RoutingNoticeBar(message: notice, onDismiss: viewModel.dismissRoutingNotice)
                        }

                        RouteBuilderCard(viewModel: viewModel, showSaveTrip: $showSaveTrip)

                        if let plan = viewModel.plan {
                            ItineraryTimeline(plan: plan, viewModel: viewModel, showSaveTrip: $showSaveTrip, onNavigate: { services.activePlan.setIsNavigating(true) })
                            ChargersAlongRouteSection(viewModel: viewModel)
                        }

                        SavedTripsSection(viewModel: viewModel)
                        NearbyChargersSection(viewModel: viewModel)
                    }
                    .padding(.vertical)
                } else {
                    ProgressView()
                }
            }
            .background(Color.appBackground)
            .navigationTitle("Plan")
            .alert("Save this plan", isPresented: $showSaveTrip) {
                TextField("Name", text: $tripName)
                Button("Cancel", role: .cancel) { tripName = "" }
                Button("Save") {
                    let fallback = viewModel?.defaultTripName ?? "Trip"
                    viewModel?.saveTrip(named: tripName.isEmpty ? fallback : tripName)
                    tripName = ""
                }
            }
        }
        .task {
            if viewModel == nil { viewModel = PlanViewModel(services: services) }
            viewModel?.reloadSaved()
        }
    }
}

// MARK: - Notices

private struct RoutingNoticeBar: View {
    let message: String
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "info.circle.fill")
                .foregroundStyle(Color.appAmber)
            Text(message)
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button {
                onDismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.caption)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
        .padding(12)
        .background(Color.appSurface, in: RoundedRectangle(cornerRadius: 10))
        .padding(.horizontal)
    }
}

// MARK: - Route builder

private struct RouteBuilderCard: View {
    let viewModel: PlanViewModel
    @Binding var showSaveTrip: Bool
    @State private var advancedExpanded = false

    var body: some View {
        GroupBox {
            VStack(spacing: 10) {
                // Endpoint fields
                HStack(spacing: 8) {
                    VStack(spacing: 8) {
                        EndpointField(viewModel: viewModel, slot: .origin,
                                      systemImage: "location.circle", placeholder: "Origin")
                        ForEach(Array(viewModel.waypoints.enumerated()), id: \.element.id) { index, _ in
                            EndpointField(
                                viewModel: viewModel,
                                slot: .waypoint(index),
                                systemImage: "mappin.and.ellipse",
                                placeholder: "Stopover \(index + 1)",
                                onRemove: { viewModel.removeWaypoint(at: index) }
                            )
                        }
                        EndpointField(viewModel: viewModel, slot: .destination,
                                      systemImage: "mappin.circle", placeholder: "Destination")
                    }
                    Button {
                        viewModel.swapEndpoints()
                    } label: {
                        Image(systemName: "arrow.up.arrow.down")
                    }
                    .tint(Color.appAccent)
                    .accessibilityLabel("Swap origin and destination")
                }

                // Inline favourite places + Use my location / Add stopover
                HStack {
                    Button {
                        Task { await viewModel.useCurrentLocation() }
                    } label: {
                        Label("Current location", systemImage: "location.fill").font(.caption)
                    }
                    Spacer()
                    Button {
                        viewModel.addWaypoint()
                    } label: {
                        Label("Add stopover", systemImage: "plus.circle").font(.caption)
                    }
                }
                .tint(Color.appAccent)

                // Inline favourite places chips
                if !viewModel.favoritePlaces.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(viewModel.favoritePlaces, id: \.id) { place in
                                Menu {
                                    Button("Set as origin") { viewModel.selectFavorite(place, for: .origin) }
                                    Button("Set as destination") { viewModel.selectFavorite(place, for: .destination) }
                                    Button("Add as stopover") { viewModel.addFavoriteAsWaypoint(place) }
                                } label: {
                                    HStack(spacing: 5) {
                                        Image(systemName: "star.fill").font(.caption2)
                                        Text(place.name).font(.caption)
                                    }
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 6)
                                    .background(Color.appSurface, in: Capsule())
                                }
                                .tint(.primary)
                            }
                        }
                    }
                }

                Divider()

                // Collapsible Advanced section (battery parameters)
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { advancedExpanded.toggle() }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "bolt.fill")
                            .foregroundStyle(Color.appAccent)
                            .font(.caption)
                        Text("Advanced")
                            .font(.subheadline.weight(.semibold))
                        Spacer()
                        Image(systemName: "chevron.down")
                            .rotationEffect(.degrees(advancedExpanded ? 180 : 0))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)

                if advancedExpanded {
                    VStack(alignment: .leading, spacing: 14) {
                        // Departure charge
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text("DEPARTURE CHARGE")
                                    .font(.ioniqCaption).foregroundStyle(.secondary).ioniqStatLabel()
                                if viewModel.usesLiveSoc && viewModel.liveSocAvailable {
                                    Text("LIVE")
                                        .font(.caption2.weight(.bold))
                                        .padding(.horizontal, 5).padding(.vertical, 1)
                                        .background(Color.appGreen.opacity(0.2), in: Capsule())
                                        .foregroundStyle(Color.appGreen)
                                }
                                Spacer()
                                percentBadge(viewModel.departureSoc)
                            }
                            Slider(
                                value: Binding(
                                    get: { viewModel.departureSoc },
                                    set: { viewModel.setDepartureSoc($0) }
                                ),
                                in: 10...100, step: 5
                            )
                            .tint(Color.appAccent)

                            if !viewModel.usesLiveSoc && viewModel.liveSocAvailable {
                                Button("Use live charge from car") { viewModel.useLiveSoc() }
                                    .font(.caption)
                                    .tint(Color.appAccent)
                            }
                        }

                        // Arrival reserve
                        sliderRow("ARRIVAL RESERVE", value: Binding(
                            get: { viewModel.arrivalReserve },
                            set: { viewModel.arrivalReserve = $0 }
                        ), range: 5...50)

                        // Corridor radius
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text("CHARGER CORRIDOR")
                                    .font(.ioniqCaption).foregroundStyle(.secondary).ioniqStatLabel()
                                Spacer()
                                Text("\(Int(viewModel.corridorRadiusKm)) km")
                                    .font(.caption.weight(.semibold))
                                    .padding(.horizontal, 8).padding(.vertical, 3)
                                    .background(Color.appAccent.opacity(0.18), in: Capsule())
                                    .foregroundStyle(Color.appAccent)
                            }
                            Slider(
                                value: Binding(
                                    get: { viewModel.corridorRadiusKm },
                                    set: { viewModel.setCorridorRadius($0) }
                                ),
                                in: 2...25, step: 1
                            )
                            .tint(Color.appAccent)
                        }
                    }
                    .padding(.leading, 4)
                }

                Divider()

                // Plan Route button (card footer)
                VStack(spacing: 8) {
                    Button {
                        Task { await viewModel.plan() }
                    } label: {
                        HStack {
                            if viewModel.isPlanning { ProgressView().tint(Color.appOnAccent) }
                            Text(viewModel.isPlanning ? (viewModel.statusMessage ?? "Planning…") : "Plan Route")
                                .fontWeight(.semibold)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        // Explicit fill and label rather than `.borderedProminent` + tint:
                        // the system pairs the bright accent with a light label, which is
                        // unreadable on it.
                        .foregroundStyle(viewModel.canPlan ? Color.appOnAccent : Color.appOnSurface.opacity(0.4))
                        .background(
                            viewModel.canPlan ? Color.appAccent : Color.appSurfaceVariant,
                            in: RoundedRectangle(cornerRadius: 12)
                        )
                    }
                    .buttonStyle(.plain)
                    .disabled(!viewModel.canPlan)

                    // Up front, not after a 20 s timeout: routing needs the network, and a
                    // driver in a car park should be told that before they wait.
                    if viewModel.isOffline {
                        Label(
                            "You're offline. Route planning needs a connection — this will work again once you have signal.",
                            systemImage: "wifi.slash"
                        )
                        .font(.caption)
                        .foregroundStyle(Color.appAmber)
                        .multilineTextAlignment(.center)
                    }

                    if let error = viewModel.errorMessage {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(Color.appAmber)
                            .multilineTextAlignment(.center)
                    }

                    // Distinct from `errorMessage`: the plan is usable, the charger data
                    // behind it just couldn't be refreshed. Saying nothing would let a
                    // driver route to a station that closed since the cache was written.
                    if viewModel.chargersAreCached {
                        Label(
                            "Charger data couldn't be refreshed — showing saved results, which may be out of date.",
                            systemImage: "wifi.exclamationmark"
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    }
                }
            }
            .padding(14)
        }
        .padding(.horizontal)
        .backgroundStyle(.ultraThinMaterial)
    }

    private func percentBadge(_ value: Float) -> some View {
        Text("\(Int(value))%")
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(Color.appAccent.opacity(0.18), in: Capsule())
            .foregroundStyle(Color.appAccent)
    }

    private func sliderRow(_ title: String, value: Binding<Float>, range: ClosedRange<Float>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title).font(.ioniqCaption).foregroundStyle(.secondary).ioniqStatLabel()
                Spacer()
                percentBadge(value.wrappedValue)
            }
            Slider(value: value, in: range, step: 5)
                .tint(Color.appAccent)
                .accessibilityValue("\(Int(value.wrappedValue)) percent")
        }
    }
}

private struct EndpointField: View {
    let viewModel: PlanViewModel
    let slot: PlanViewModel.Slot
    let systemImage: String
    let placeholder: String
    var onRemove: (() -> Void)?

    private var endpoint: PlanViewModel.Endpoint { viewModel.endpoint(for: slot) }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: systemImage)
                    .foregroundStyle(.secondary)

                TextField(placeholder, text: Binding(
                    get: { endpoint.query },
                    set: { viewModel.setQuery($0, for: slot) }
                ))
                .autocorrectionDisabled()

                if endpoint.isSearching {
                    ProgressView().controlSize(.small)
                }
                if !endpoint.query.isEmpty {
                    Button {
                        viewModel.clearEndpoint(slot)
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.tertiary)
                    .accessibilityLabel("Clear \(placeholder)")
                }
                if let selected = endpoint.selected {
                    Button {
                        viewModel.toggleFavorite(selected)
                    } label: {
                        Image(systemName: viewModel.isFavorite(selected) ? "star.fill" : "star")
                    }
                    .buttonStyle(.plain)
                    .tint(Color.appAccent)
                    .accessibilityLabel(viewModel.isFavorite(selected) ? "Remove from favourites" : "Add to favourites")
                }
                if let onRemove {
                    Button(action: onRemove) {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.plain)
                    .tint(Color.appRed)
                    .accessibilityLabel("Remove stopover")
                }
            }
            .padding(10)
            .background(Color.appSurfaceVariant, in: RoundedRectangle(cornerRadius: 10))

            if !endpoint.suggestions.isEmpty {
                VStack(spacing: 0) {
                    ForEach(endpoint.suggestions) { place in
                        Button {
                            viewModel.select(place, for: slot)
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(place.name).font(.subheadline)
                                if !place.subtitle.isEmpty {
                                    Text(place.subtitle)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 8)
                        }
                        .tint(.primary)
                        Divider()
                    }
                }
                .padding(.horizontal, 10)
            }
        }
    }
}

// MARK: - Itinerary

/// Route elevation, led by the figure that actually drives consumption.
///
/// The provider's ascent and descent are cumulative over every sampled point, and
/// the elevation model it samples is noisy — a flat trunk road across Peninsular
/// Malaysia can total several kilometres of "climb" from metre-scale wobble that no
/// driver would call a hill. Only the net change moves the energy estimate
/// (`TripSolver` uses `RouteElevation.netM`), so that goes first and the cumulative
/// pair is labelled as the rolling total it is.
private struct ElevationLine: View {
    let elevation: RouteElevation

    private var netText: String {
        let net = Int(elevation.netM.rounded())
        if net > 0 { return "Net climb \(net) m" }
        if net < 0 { return "Net descent \(abs(net)) m" }
        return "Net level"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(netText)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("Rolling total +\(Int(elevation.ascendM)) m / −\(Int(elevation.descendM)) m")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct ItineraryTimeline: View {
    let plan: TripPlan
    let viewModel: PlanViewModel
    @Binding var showSaveTrip: Bool
    let onNavigate: () -> Void

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 0) {
                summary
                if viewModel.hasElevationData, let elevation = plan.elevation {
                    ElevationLine(elevation: elevation)
                        .padding(.top, 6)
                }

                // Header actions: Save, Clear, Navigate
                HStack {
                    if !viewModel.excludedChargerIds.isEmpty {
                        Button {
                            viewModel.restoreExcludedChargers()
                        } label: {
                            Label(
                                "Restore \(viewModel.excludedChargerIds.count)",
                                systemImage: "arrow.uturn.backward"
                            )
                            .font(.caption)
                        }
                        .tint(Color.appAccent)
                    }
                    if let plan = viewModel.plan {
                        Button {
                            onNavigate()
                            MapsNavigation.navigateTrip(plan)
                        } label: {
                            Label("Navigate", systemImage: "arrow.triangle.turn.up.right.circle.fill")
                                .font(.caption.weight(.medium))
                        }
                        .tint(Color.appAccent)
                    }
                    Spacer()
                    Button {
                        showSaveTrip = true
                    } label: {
                        Label("Save plan", systemImage: "star")
                            .font(.caption)
                    }
                    .disabled(!viewModel.canSaveTrip)
                    Button("Clear", role: .destructive) { viewModel.clearPlan() }
                        .font(.caption)
                }
                .padding(.top, 8)

                Divider().padding(.vertical, 10)

                TimelineRow(
                    icon: "flag.fill", tint: .appGreen, title: "Departure",
                    detail: String(format: "%.0f%% charge", plan.legs.first?.startSoc ?? 0),
                    isLast: waypointsAndStops.isEmpty
                )

                // Stopovers and charge stops share one timeline in route order —
                // listing only the charge stops made a stopover the driver had
                // explicitly asked for vanish from the plan.
                ForEach(Array(waypointsAndStops.enumerated()), id: \.offset) { _, entry in
                    switch entry {
                    case .stop(let stop):
                        ChargeStopRow(stop: stop, viewModel: viewModel)
                    case .waypoint(let waypoint):
                        TimelineRow(
                            icon: "mappin.and.ellipse", tint: .appAccent,
                            title: waypoint.name,
                            detail: String(format: "Stopover · %.0f km from start", waypoint.distanceFromOriginKm),
                            isLast: false
                        )
                    }
                }

                TimelineRow(
                    icon: "flag.checkered", tint: .appAccent, title: "Arrival",
                    detail: String(format: "%.0f%% remaining", plan.arrivalSoc),
                    isLast: true
                )
            }
            .padding(14)
        }
        .padding(.horizontal)
        .backgroundStyle(.ultraThinMaterial)
    }

    /// One entry per intermediate point, ordered by distance from the origin.
    private enum TimelineEntry {
        case waypoint(UserWaypoint)
        case stop(ChargeStop)

        var distanceKm: Float {
            switch self {
            case .waypoint(let waypoint): return waypoint.distanceFromOriginKm
            case .stop(let stop): return stop.distanceFromOriginKm
            }
        }
    }

    private var waypointsAndStops: [TimelineEntry] {
        (plan.userWaypoints.map(TimelineEntry.waypoint) + plan.stops.map(TimelineEntry.stop))
            .sorted { $0.distanceKm < $1.distanceKm }
    }

    private var summary: some View {
        HStack(spacing: 0) {
            stat("DISTANCE", String(format: "%.0f km", plan.totalDistanceKm))
            stat("DRIVE", formatMinutes(plan.totalDriveMinutes))
            stat("CHARGE", formatMinutes(plan.totalChargeMinutes))
            stat("STOPS", "\(plan.stops.count)")
        }
    }

    private func formatMinutes(_ minutes: Int) -> String {
        minutes >= 60 ? "\(minutes / 60)h \(minutes % 60)m" : "\(minutes)m"
    }

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(spacing: 4) {
            Text(label).font(.ioniqCaption).foregroundStyle(.secondary).ioniqStatLabel()
            Text(value).font(.system(size: 14, weight: .semibold)).minimumScaleFactor(0.7).lineLimit(1)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }
}

/// A charge stop, with the re-route affordance: rejecting a stop re-solves against
/// the cached route rather than re-requesting it, so it costs no API calls.
private struct ChargeStopRow: View {
    let stop: ChargeStop
    let viewModel: PlanViewModel

    private var speedBadgeText: String? {
        let kw = stop.charger.maxPowerKw
        if kw >= 250 { return "\(Int(kw)) kW Ultra-Fast" }
        if kw >= 100 { return "\(Int(kw)) kW Fast" }
        if kw > 0 { return "\(Int(kw)) kW DC" }
        return nil
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(spacing: 0) {
                Image(systemName: "bolt.fill")
                    .font(.caption)
                    .foregroundStyle(Color.appAccent)
                    .frame(width: 28, height: 28)
                    .background(Color.appAccent.opacity(0.15), in: Circle())
                Rectangle().fill(Color.appOutline).frame(width: 2).frame(minHeight: 24)
            }
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(stop.charger.name).font(.subheadline.weight(.medium))
                    if let badge = speedBadgeText {
                        Text(badge)
                            .font(.caption2.weight(.bold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.appGreen.opacity(0.18), in: Capsule())
                            .foregroundStyle(Color.appGreen)
                    }
                }
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            .padding(.bottom, 12)
            Spacer()
            Menu {
                Button {
                    MapsNavigation.navigate(
                        to: LatLon(lat: stop.charger.lat, lon: stop.charger.lon),
                        name: stop.charger.name
                    )
                } label: {
                    Label("Navigate here", systemImage: "arrow.triangle.turn.up.right.circle")
                }
                Button(role: .destructive) {
                    viewModel.excludeChargerAndReplan(stop.charger.id)
                } label: {
                    Label("Avoid this charger — re-route", systemImage: "arrow.triangle.branch")
                }
            } label: {
                Image(systemName: "ellipsis.circle").foregroundStyle(.secondary)
            }
            .accessibilityLabel("Options for \(stop.charger.name)")
        }
    }

    private var detail: String {
        var parts = [
            String(format: "%.0f%% → %.0f%%", stop.arrivalSoc, stop.departureSoc),
            "\(stop.chargeMinutes) min"
        ]
        if let price = stop.charger.pricePerKwh { parts.append(String(format: "%.2f/kWh", price)) }
        return parts.joined(separator: " · ")
    }
}

private struct TimelineRow: View {
    let icon: String
    let tint: Color
    let title: String
    let detail: String
    let isLast: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(spacing: 0) {
                Image(systemName: icon)
                    .font(.caption)
                    .foregroundStyle(tint)
                    .frame(width: 28, height: 28)
                    .background(tint.opacity(0.15), in: Circle())
                if !isLast {
                    Rectangle().fill(Color.appOutline).frame(width: 2).frame(minHeight: 24)
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.medium))
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            .padding(.bottom, isLast ? 0 : 12)
            Spacer()
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Saved trips

private struct SavedTripsSection: View {
    let viewModel: PlanViewModel
    @State private var savedTripsExpanded = false

    private var tripCount: Int { viewModel.savedTrips.count }
    private static let maxCollapsed = 3

    var body: some View {
        if !viewModel.savedTrips.isEmpty {
            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) { savedTripsExpanded.toggle() }
                    } label: {
                        HStack(spacing: 8) {
                            Text("SAVED TRIPS (\(tripCount))")
                                .font(.ioniqCaption).foregroundStyle(.secondary).ioniqStatLabel()
                            Spacer()
                            Image(systemName: "chevron.down")
                                .rotationEffect(.degrees(savedTripsExpanded ? 180 : 0))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)

                    let trips = savedTripsExpanded
                        ? viewModel.savedTrips
                        : Array(viewModel.savedTrips.prefix(Self.maxCollapsed))

                    ForEach(trips) { trip in
                        Button {
                            viewModel.loadTrip(trip)
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(trip.name).font(.subheadline)
                                    Text("\(trip.def.origin.name) → \(trip.def.destination.name)")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                                Spacer()
                                if !trip.def.waypoints.isEmpty {
                                    Text("\(trip.def.waypoints.count) stop\(trip.def.waypoints.count == 1 ? "" : "s")")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        .tint(.primary)
                        .swipeActions {
                            Button(role: .destructive) { viewModel.deleteTrip(trip) } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                        .contextMenu {
                            Button(role: .destructive) { viewModel.deleteTrip(trip) } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                        Divider()
                    }

                    // Show all / Show less footer
                    if tripCount > Self.maxCollapsed {
                        Button {
                            withAnimation(.easeInOut(duration: 0.2)) { savedTripsExpanded.toggle() }
                        } label: {
                            HStack {
                                Spacer()
                                Text(savedTripsExpanded ? "Show less" : "Show all \(tripCount)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Spacer()
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(14)
            }
            .padding(.horizontal)
            .backgroundStyle(.ultraThinMaterial)
        }
    }
}

// MARK: - Nearby chargers

/// Tariff for a charger row.
///
/// Prefers the parsed per-kWh figure and falls back to whatever free-text tariff
/// the source gave, trimmed — many entries are only ever a sentence. Google Places
/// carries no pricing at all, so rows from that source show nothing here.
private enum ChargerPrice {
    static func label(for charger: Charger) -> String? {
        if let price = charger.pricePerKwh {
            return price == 0 ? "Free" : String(format: "%.2f/kWh", price)
        }
        guard let cost = charger.usageCost?.trimmingCharacters(in: .whitespacesAndNewlines),
              !cost.isEmpty
        else { return nil }
        return cost.count > 24 ? String(cost.prefix(24)) + "…" : cost
    }
}

/// Live connector availability. Only shown when Places actually reported it —
/// there is no "assumed free" state.
private struct AvailabilityBadge: View {
    let status: PlanViewModel.ChargerAvailability

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(status.isFull ? Color.appRed : Color.appGreen)
                .frame(width: 6, height: 6)
            Text(status.isFull
                 ? "All \(status.total) in use"
                 : "\(status.available) of \(status.total) free")
                .font(.caption2.weight(.medium))
                .foregroundStyle(status.isFull ? Color.appRed : Color.appGreen)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(status.isFull
                            ? "All \(status.total) connectors in use"
                            : "\(status.available) of \(status.total) connectors free")
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

    var body: some View {
        if !viewModel.lastRouteChargers.isEmpty {
            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("CHARGERS ALONG ROUTE")
                            .font(.ioniqCaption).foregroundStyle(.secondary).ioniqStatLabel()
                        Spacer()
                        Text("\(viewModel.lastRouteChargers.count) found")
                            .font(.caption).foregroundStyle(.secondary)
                    }

                    ForEach(Array(zip(viewModel.lastRouteChargers.indices, viewModel.lastRouteChargers)), id: \.0) { i, rc in
                        ChargerAlongRouteCard(rc: rc, viewModel: viewModel)
                        if i < viewModel.lastRouteChargers.count - 1 {
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
                .padding(14)
            }
            .padding(.horizontal)
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
