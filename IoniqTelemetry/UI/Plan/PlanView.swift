import CoreDomain
import CoreUI
import SwiftUI

struct PlanView: View {
    @Environment(AppServices.self) private var services
    @State private var viewModel: PlanViewModel?

    var body: some View {
        NavigationStack {
            ScrollView {
                if let viewModel {
                    LazyVStack(spacing: 16) {
                        RouteBuilderCard(viewModel: viewModel)
                        BatteryParametersCard(viewModel: viewModel)
                        PlanActionSection(viewModel: viewModel)

                        if let plan = viewModel.plan {
                            ItineraryTimeline(plan: plan)
                            Button("Clear Plan", role: .destructive) {
                                viewModel.clearPlan()
                            }
                            .font(.footnote)
                        }

                        NearbyChargersSection(viewModel: viewModel)
                    }
                    .padding(.vertical)
                } else {
                    ProgressView()
                }
            }
            .background(Color.appBackground)
            .navigationTitle("Plan")
        }
        .task {
            if viewModel == nil { viewModel = PlanViewModel(services: services) }
            await viewModel?.loadNearbyChargers()
        }
    }
}

// MARK: - Route builder

private struct RouteBuilderCard: View {
    @Bindable var viewModel: PlanViewModel

    var body: some View {
        GroupBox {
            VStack(spacing: 10) {
                HStack(spacing: 8) {
                    VStack(spacing: 8) {
                        endpointField(
                            systemImage: "location.circle",
                            placeholder: "Origin",
                            text: $viewModel.originQuery,
                            field: .origin
                        )
                        endpointField(
                            systemImage: "mappin.circle",
                            placeholder: "Destination",
                            text: $viewModel.destinationQuery,
                            field: .destination
                        )
                    }
                    Button {
                        viewModel.swapEndpoints()
                    } label: {
                        Image(systemName: "arrow.up.arrow.down")
                    }
                    .tint(Color.appAccent)
                    .accessibilityLabel("Swap origin and destination")
                }

                Button {
                    Task { await viewModel.useCurrentLocation() }
                } label: {
                    Label("Use current location", systemImage: "location.fill")
                        .font(.caption)
                }
                .tint(Color.appAccent)
                .frame(maxWidth: .infinity, alignment: .leading)

                if !viewModel.suggestions.isEmpty {
                    SuggestionList(viewModel: viewModel)
                }
            }
            .padding(14)
        }
        .padding(.horizontal)
        .backgroundStyle(.ultraThinMaterial)
    }

    private func endpointField(
        systemImage: String,
        placeholder: String,
        text: Binding<String>,
        field: PlanViewModel.Field
    ) -> some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage)
                .foregroundStyle(.secondary)
            TextField(placeholder, text: text)
                .autocorrectionDisabled()
                .onChange(of: text.wrappedValue) {
                    viewModel.search(text.wrappedValue, field: field)
                }
        }
        .padding(10)
        .background(Color.appSurfaceVariant, in: RoundedRectangle(cornerRadius: 10))
    }
}

private struct SuggestionList: View {
    let viewModel: PlanViewModel

    var body: some View {
        VStack(spacing: 0) {
            ForEach(viewModel.suggestions) { place in
                Button {
                    viewModel.select(place)
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(place.name)
                            .font(.subheadline)
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
    }
}

// MARK: - Battery parameters

private struct BatteryParametersCard: View {
    @Bindable var viewModel: PlanViewModel

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 14) {
                sliderRow(
                    title: "DEPARTURE CHARGE",
                    value: $viewModel.departureSoc,
                    range: 10...100,
                    onEdit: viewModel.socEdited
                )
                sliderRow(
                    title: "ARRIVAL RESERVE",
                    value: $viewModel.arrivalReserve,
                    range: 5...50,
                    onEdit: viewModel.reserveEdited
                )
            }
            .padding(14)
        }
        .padding(.horizontal)
        .backgroundStyle(.ultraThinMaterial)
    }

    private func sliderRow(
        title: String,
        value: Binding<Float>,
        range: ClosedRange<Float>,
        onEdit: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                    .font(.ioniqCaption)
                    .foregroundStyle(.secondary)
                    .ioniqStatLabel()
                Spacer()
                Text("\(Int(value.wrappedValue))%")
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.appAccent.opacity(0.18), in: Capsule())
                    .foregroundStyle(Color.appAccent)
            }
            Slider(value: value, in: range, step: 5) { editing in
                if editing { onEdit() }
            }
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

// MARK: - Itinerary

private struct ItineraryTimeline: View {
    let plan: TripPlan

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 0) {
                summary

                Divider().padding(.vertical, 10)

                TimelineRow(
                    icon: "flag.fill",
                    tint: .greenOk,
                    title: "Departure",
                    detail: String(format: "%.0f%% charge", plan.legs.first?.startSoc ?? 0),
                    isLast: plan.stops.isEmpty
                )

                ForEach(Array(plan.stops.enumerated()), id: \.offset) { _, stop in
                    TimelineRow(
                        icon: "bolt.fill",
                        tint: .electricTeal,
                        title: stop.charger.name,
                        detail: stopDetail(stop),
                        isLast: false
                    )
                }

                TimelineRow(
                    icon: "flag.checkered",
                    tint: .electricTeal,
                    title: "Arrival",
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

    private func stopDetail(_ stop: ChargeStop) -> String {
        var parts = [
            String(format: "%.0f%% → %.0f%%", stop.arrivalSoc, stop.departureSoc),
            "\(stop.chargeMinutes) min"
        ]
        if stop.charger.maxPowerKw > 0 {
            parts.append(String(format: "%.0f kW", stop.charger.maxPowerKw))
        }
        if let price = stop.charger.pricePerKwh {
            parts.append(String(format: "%.2f/kWh", price))
        }
        return parts.joined(separator: " · ")
    }

    private func formatMinutes(_ minutes: Int) -> String {
        minutes >= 60 ? "\(minutes / 60)h \(minutes % 60)m" : "\(minutes)m"
    }

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(spacing: 4) {
            Text(label)
                .font(.ioniqCaption)
                .foregroundStyle(.secondary)
                .ioniqStatLabel()
            Text(value)
                .font(.system(size: 14, weight: .semibold))
                .minimumScaleFactor(0.7)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
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
                    Rectangle()
                        .fill(Color.appOutline)
                        .frame(width: 2)
                        .frame(minHeight: 24)
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.medium))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.bottom, isLast ? 0 : 12)
            Spacer()
        }
        .accessibilityElement(children: .combine)
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
                        .font(.ioniqCaption)
                        .foregroundStyle(.secondary)
                        .ioniqStatLabel()

                    ForEach(viewModel.nearbyChargers.prefix(5)) { charger in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(charger.name)
                                    .font(.subheadline)
                                    .lineLimit(1)
                                if let op = charger.operator {
                                    Text(op)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            if charger.maxPowerKw > 0 {
                                Text(String(format: "%.0f kW", charger.maxPowerKw))
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(Color.appAccent)
                            }
                        }
                        .accessibilityElement(children: .combine)
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
