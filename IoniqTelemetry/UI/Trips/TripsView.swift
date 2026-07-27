import CoreData
import CoreDomain
import CoreUI
import SwiftUI

struct TripsView: View {
    @Environment(AppServices.self) private var services
    @State private var viewModel: TripsViewModel?
    @State private var pendingDelete: TripEntity?

    var body: some View {
        NavigationStack {
            Group {
                if let viewModel {
                    if viewModel.trips.isEmpty {
                        EmptyTripsView()
                    } else {
                        tripList(viewModel)
                    }
                } else {
                    ProgressView()
                }
            }
            .background(Color.appBackground)
            .navigationTitle("Trips")
            .overlay(alignment: .bottom) {
                if let viewModel, viewModel.recentlyDeleted != nil {
                    UndoBar(
                        message: "Trip deleted",
                        onUndo: { viewModel.undoDelete() },
                        onDismiss: { viewModel.dismissUndo() }
                    )
                    .padding(.horizontal)
                    .padding(.bottom, 8)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(.easeInOut(duration: 0.2), value: viewModel?.recentlyDeleted?.id)
            .alert("Delete this trip?", isPresented: .constant(pendingDelete != nil)) {
                Button("Cancel", role: .cancel) { pendingDelete = nil }
                Button("Delete", role: .destructive) {
                    if let trip = pendingDelete { viewModel?.delete(trip) }
                    pendingDelete = nil
                }
            } message: {
                Text("You can undo this right after.")
            }
        }
        .task {
            if viewModel == nil { viewModel = TripsViewModel(services: services) }
            viewModel?.refresh()
        }
    }

    private func tripList(_ viewModel: TripsViewModel) -> some View {
        List {
            if let summary = viewModel.summary, summary.totalTrips > 0 {
                Section {
                    TripSummaryHeader(summary: summary, viewModel: viewModel)
                }
                .listRowBackground(Color.appSurface)
            }

            ForEach(viewModel.monthGroups) { group in
                Section(group.title) {
                    ForEach(group.trips, id: \.id) { trip in
                        NavigationLink {
                            TripDetailView(trip: trip, viewModel: viewModel)
                        } label: {
                            TripCard(trip: trip, viewModel: viewModel)
                        }
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                pendingDelete = trip
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    }
                }
                .listRowBackground(Color.appSurface)
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .refreshable { viewModel.refresh() }
    }
}

// MARK: - Summary

struct TripSummaryHeader: View {
    let summary: TripSummary
    let viewModel: TripsViewModel

    var body: some View {
        HStack(spacing: 0) {
            stat("TRIPS", "\(summary.totalTrips)")
            Divider().frame(height: 32)
            stat("DISTANCE", viewModel.distance(summary.totalDistanceKm))
            Divider().frame(height: 32)
            stat("AVG", viewModel.efficiency(summary.avgEfficiencyKwhPer100km))
        }
        .padding(.vertical, 6)
    }

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(spacing: 4) {
            Text(label)
                .font(.ioniqCaption)
                .foregroundStyle(.secondary)
                .ioniqStatLabel()
            Text(value)
                .font(.system(size: 15, weight: .semibold))
                .minimumScaleFactor(0.7)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Trip Card

struct TripCard: View {
    let trip: TripEntity
    let viewModel: TripsViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Image(systemName: "car.fill")
                    .font(.system(size: 15))
                    .foregroundStyle(Color.appAccent)
                    .frame(width: 36, height: 36)
                    .background(Color.appAccent.opacity(0.15))
                    .clipShape(Circle())

                VStack(alignment: .leading, spacing: 2) {
                    Text(trip.startTime, format: .dateTime.weekday(.abbreviated).day().month().hour().minute())
                        .font(.subheadline.weight(.medium))
                    Text(viewModel.duration(trip))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            Divider()

            HStack(spacing: 0) {
                stat("DISTANCE", viewModel.distance(trip.distanceKm))
                stat("ENERGY", String(format: "%.1f kWh", trip.energyUsedKwh))
                stat("EFFICIENCY", viewModel.efficiency(trip.avgConsumptionKwhPer100km))
            }

            SocBar(startSoc: trip.startSoc, endSoc: trip.endSoc)
        }
        .padding(.vertical, 6)
    }

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.ioniqCaption)
                .foregroundStyle(.secondary)
                .ioniqStatLabel()
            Text(value)
                .font(.system(size: 14, weight: .semibold))
                .minimumScaleFactor(0.7)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

/// Start → end state of charge as a single bar, so the drain is readable at a glance.
struct SocBar: View {
    let startSoc: Float
    let endSoc: Float?

    var body: some View {
        VStack(spacing: 4) {
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.appOutline)
                    Capsule()
                        .fill(Color.appAccent)
                        .frame(width: geometry.size.width * CGFloat(min(max(startSoc, 0), 100) / 100))
                    if let endSoc {
                        Capsule()
                            .fill(Color.appAccent.opacity(0.35))
                            .frame(width: geometry.size.width * CGFloat(min(max(endSoc, 0), 100) / 100))
                    }
                }
            }
            .frame(height: 6)

            HStack {
                Text(String(format: "%.0f%%", startSoc))
                Spacer()
                Text(endSoc.map { String(format: "%.0f%%", $0) } ?? "—")
            }
            .font(.ioniqCaption)
            .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("State of charge")
        .accessibilityValue(
            "From \(Int(startSoc)) percent to \(endSoc.map { "\(Int($0)) percent" } ?? "unknown")"
        )
    }
}

// MARK: - Undo

struct UndoBar: View {
    let message: String
    let onUndo: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack {
            Text(message)
                .font(.subheadline)
            Spacer()
            Button("Undo", action: onUndo)
                .font(.subheadline.weight(.semibold))
                .tint(Color.appAccent)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color.appSurfaceVariant, in: RoundedRectangle(cornerRadius: 12))
        .task {
            // Matches the system snackbar dwell time before the undo lapses.
            try? await Task.sleep(for: .seconds(5))
            onDismiss()
        }
    }
}

// MARK: - Empty State

struct EmptyTripsView: View {
    var body: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "car.front.waves.down")
                .font(.system(size: 56))
                .foregroundStyle(.tertiary)
            Text("No Recorded Trips Yet")
                .font(.title2.weight(.medium))
                .foregroundStyle(.secondary)
            Text("Trips are logged automatically whenever the vehicle ignition is active. Start driving and they'll appear here.")
                .font(.body)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
            Spacer()
        }
    }
}
