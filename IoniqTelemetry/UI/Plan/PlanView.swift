import CoreData
import CoreDomain
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

                        if viewModel.canUseAi {
                            AiPlanCard(viewModel: viewModel)
                        }
                        RouteBuilderCard(viewModel: viewModel)
                        FavoritePlaceChips(viewModel: viewModel)
                        BatteryParametersCard(viewModel: viewModel)
                        PlanActionSection(viewModel: viewModel)

                        if let plan = viewModel.plan {
                            ItineraryTimeline(plan: plan, viewModel: viewModel)
                            PlanActionsRow(viewModel: viewModel, showSaveTrip: $showSaveTrip)
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
            .alert("Save this trip", isPresented: $showSaveTrip) {
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
            await viewModel?.loadNearbyChargers()
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
                .foregroundStyle(Color.amberWarn)
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

// MARK: - AI planning

/// Plans from a sentence: "drive from KL to Penang, stop in Ipoh, arrive with 30%".
///
/// The parse is echoed back before the plan appears — the driver needs to see what
/// the assistant understood, because a misread destination produces a confident,
/// wrong itinerary that looks exactly like a right one.
private struct AiPlanCard: View {
    let viewModel: PlanViewModel

    /// One chip, matching Android: the others were guesses at phrasing the parser
    /// may not handle, and a suggestion that fails reads as the feature being broken.
    private static let quickPrompt = "Find chargers near me"

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Image(systemName: "sparkles").foregroundStyle(Color.appAccent)
                    Text("AI Assistant")
                        .font(.subheadline.weight(.semibold))
                    Text("GEMINI AI")
                        .font(.caption2.weight(.bold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.appAccent.opacity(0.15), in: Capsule())
                        .foregroundStyle(Color.appAccent)
                    Spacer()
                }

                HStack(spacing: 8) {
                    HStack(spacing: 6) {
                        TextField("e.g. Find chargers near me, or drive to Penang with 30% reserve…", text: Binding(
                            get: { viewModel.aiInput },
                            set: { viewModel.aiInput = $0 }
                        ), axis: .vertical)
                        .lineLimit(1...3)
                        .textFieldStyle(.plain)
                        .onSubmit { Task { await viewModel.planFromNaturalLanguage() } }

                        // A long dictated sentence is tedious to clear a character
                        // at a time, and the parse it produced is stale anyway.
                        if !viewModel.aiInput.isEmpty {
                            Button {
                                viewModel.clearAiInput()
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.tertiary)
                            .accessibilityLabel("Clear")
                        }
                    }
                    .padding(10)
                    .background(Color.appSurfaceVariant, in: RoundedRectangle(cornerRadius: 10))

                    Button {
                        Task { await viewModel.planFromNaturalLanguage() }
                    } label: {
                        if viewModel.aiBusy {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "arrow.up.circle.fill").font(.title2)
                        }
                    }
                    .tint(Color.appAccent)
                    .disabled(viewModel.aiBusy || viewModel.aiInput.trimmingCharacters(in: .whitespaces).isEmpty)
                    .accessibilityLabel("Plan this trip")
                }

                if viewModel.aiInput.isEmpty && !viewModel.aiBusy && viewModel.aiInterpretation == nil {
                    Button {
                        viewModel.aiInput = Self.quickPrompt
                        Task { await viewModel.planFromNaturalLanguage() }
                    } label: {
                        Text(Self.quickPrompt)
                            .font(.caption)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(Color.appSurface, in: Capsule())
                    }
                    .tint(.primary)
                }

                if let interpretation = viewModel.aiInterpretation {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(Color.appGreen)
                        Text(interpretation)
                            .font(.caption)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .accessibilityElement(children: .combine)
                }

                if let error = viewModel.aiError {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "exclamationmark.circle.fill")
                            .foregroundStyle(Color.amberWarn)
                        Text(error).font(.caption)
                        Spacer()
                        Button {
                            viewModel.dismissAiError()
                        } label: {
                            Image(systemName: "xmark").font(.caption2)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(14)
        }
        .padding(.horizontal)
        .backgroundStyle(Color.appAccent.opacity(0.08))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.appAccent.opacity(0.3), lineWidth: 1)
                .padding(.horizontal)
        }
    }
}

// MARK: - Route builder

private struct RouteBuilderCard: View {
    let viewModel: PlanViewModel

    var body: some View {
        GroupBox {
            VStack(spacing: 10) {
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
            }
            .padding(14)
        }
        .padding(.horizontal)
        .backgroundStyle(.ultraThinMaterial)
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
                    .tint(Color.redAlert)
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

// MARK: - Favourite places

private struct FavoritePlaceChips: View {
    let viewModel: PlanViewModel
    @State private var renaming: SavedPlaceEntity?
    @State private var draftName = ""

    var body: some View {
        if !viewModel.favoritePlaces.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(viewModel.favoritePlaces, id: \.id) { place in
                        Menu {
                            Button("Set as origin") { viewModel.selectFavorite(place, for: .origin) }
                            Button("Set as destination") { viewModel.selectFavorite(place, for: .destination) }
                            Button("Add as stopover") { viewModel.addFavoriteAsWaypoint(place) }
                            Button("Rename…") {
                                draftName = place.name
                                renaming = place
                            }
                            Button("Remove", role: .destructive) { viewModel.deleteFavorite(place) }
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
                .padding(.horizontal)
            }
            .alert("Rename place", isPresented: Binding(
                get: { renaming != nil },
                set: { if !$0 { renaming = nil } }
            )) {
                TextField("Name", text: $draftName)
                Button("Cancel", role: .cancel) { renaming = nil }
                Button("Save") {
                    if let place = renaming { viewModel.renameFavorite(place, to: draftName) }
                    renaming = nil
                }
            }
        }
    }
}

// MARK: - Parameters

private struct BatteryParametersCard: View {
    let viewModel: PlanViewModel

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 14) {
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

                sliderRow("ARRIVAL RESERVE", value: Binding(
                    get: { viewModel.arrivalReserve },
                    set: { viewModel.arrivalReserve = $0 }
                ), range: 5...50)

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

// MARK: - Action

private struct PlanActionSection: View {
    let viewModel: PlanViewModel

    var body: some View {
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

            if let error = viewModel.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(Color.amberWarn)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(.horizontal)
    }
}

private struct PlanActionsRow: View {
    let viewModel: PlanViewModel
    @Binding var showSaveTrip: Bool

    var body: some View {
        VStack(spacing: 8) {
            if !viewModel.excludedChargerIds.isEmpty {
                Button {
                    viewModel.restoreExcludedChargers()
                } label: {
                    Label(
                        "Restore \(viewModel.excludedChargerIds.count) excluded charger\(viewModel.excludedChargerIds.count == 1 ? "" : "s")",
                        systemImage: "arrow.uturn.backward"
                    )
                    .font(.caption)
                }
                .tint(Color.appAccent)
            }
            if let plan = viewModel.plan {
                Button {
                    MapsNavigation.navigateTrip(plan)
                } label: {
                    Label("Navigate this trip", systemImage: "arrow.triangle.turn.up.right.circle.fill")
                        .font(.footnote.weight(.medium))
                }
                .tint(Color.appAccent)
            }

            HStack {
                Button {
                    showSaveTrip = true
                } label: {
                    Label("Save trip", systemImage: "star")
                }
                .disabled(!viewModel.canSaveTrip)
                Spacer()
                Button("Clear plan", role: .destructive) { viewModel.clearPlan() }
            }
            .font(.footnote)
        }
        .padding(.horizontal)
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

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 0) {
                summary
                if viewModel.hasElevationData, let elevation = plan.elevation {
                    ElevationLine(elevation: elevation)
                        .padding(.top, 6)
                }

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
            VStack(alignment: .leading, spacing: 2) {
                Text(stop.charger.name).font(.subheadline.weight(.medium))
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
        if stop.charger.maxPowerKw > 0 { parts.append(String(format: "%.0f kW", stop.charger.maxPowerKw)) }
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

    var body: some View {
        if !viewModel.savedTrips.isEmpty {
            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    Text("SAVED TRIPS")
                        .font(.ioniqCaption).foregroundStyle(.secondary).ioniqStatLabel()

                    ForEach(viewModel.savedTrips) { trip in
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
                .fill(status.isFull ? Color.redAlert : Color.appGreen)
                .frame(width: 6, height: 6)
            Text(status.isFull
                 ? "All \(status.total) in use"
                 : "\(status.available) of \(status.total) free")
                .font(.caption2.weight(.medium))
                .foregroundStyle(status.isFull ? Color.redAlert : Color.appGreen)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(status.isFull
                            ? "All \(status.total) connectors in use"
                            : "\(status.available) of \(status.total) connectors free")
    }
}

private struct NearbyChargersSection: View {
    let viewModel: PlanViewModel

    var body: some View {
        if !viewModel.nearbyChargers.isEmpty {
            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    Text("NEARBY CHARGERS")
                        .font(.ioniqCaption).foregroundStyle(.secondary).ioniqStatLabel()

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
                            if charger.maxPowerKw > 0 {
                                Text(String(format: "%.0f kW", charger.maxPowerKw))
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(Color.appAccent)
                            }
                            Menu {
                                Button {
                                    viewModel.setDestination(charger: charger)
                                } label: {
                                    Label("Set as destination", systemImage: "mappin.circle")
                                }
                                Button {
                                    MapsNavigation.navigate(
                                        to: LatLon(lat: charger.lat, lon: charger.lon),
                                        name: charger.name
                                    )
                                } label: {
                                    Label("Navigate here", systemImage: "arrow.triangle.turn.up.right.circle")
                                }
                            } label: {
                                Image(systemName: "ellipsis.circle").foregroundStyle(.secondary)
                            }
                            .accessibilityLabel("Options for \(charger.name)")
                        }
                        .accessibilityElement(children: .contain)
                        Divider()
                    }
                }
                .padding(14)
            }
            .padding(.horizontal)
            .backgroundStyle(.ultraThinMaterial)
        }
    }
}
