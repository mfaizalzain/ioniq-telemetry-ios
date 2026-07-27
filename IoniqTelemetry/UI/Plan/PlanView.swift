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
                    viewModel?.saveTrip(named: tripName.isEmpty ? "Trip" : tripName)
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

    var body: some View {
        if !viewModel.favoritePlaces.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(viewModel.favoritePlaces, id: \.id) { place in
                        Menu {
                            Button("Set as origin") { viewModel.selectFavorite(place, for: .origin) }
                            Button("Set as destination") { viewModel.selectFavorite(place, for: .destination) }
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
                    if viewModel.isPlanning { ProgressView().tint(.white) }
                    Text(viewModel.isPlanning ? (viewModel.statusMessage ?? "Planning…") : "Plan Route")
                        .fontWeight(.semibold)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .tint(Color.appAccent)
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

private struct ItineraryTimeline: View {
    let plan: TripPlan
    let viewModel: PlanViewModel

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 0) {
                summary
                if viewModel.hasElevationData, let elevation = plan.elevation {
                    Text("Elevation: +\(Int(elevation.ascendM)) m / −\(Int(elevation.descendM)) m")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.top, 6)
                }

                Divider().padding(.vertical, 10)

                TimelineRow(
                    icon: "flag.fill", tint: .appGreen, title: "Departure",
                    detail: String(format: "%.0f%% charge", plan.legs.first?.startSoc ?? 0),
                    isLast: plan.stops.isEmpty
                )

                ForEach(Array(plan.stops.enumerated()), id: \.offset) { _, stop in
                    ChargeStopRow(stop: stop, viewModel: viewModel)
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
                            VStack(alignment: .leading, spacing: 2) {
                                Text(charger.name).font(.subheadline).lineLimit(1)
                                if let op = charger.operator {
                                    Text(op).font(.caption).foregroundStyle(.secondary)
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
