//
//  PlanView.swift
//  IoniqTelemetry
//
//  Plan editor: origin/destination endpoints, stopover waypoints, and the
//  resolved trip (legs + charge stops) with exclusion controls.
//

import CoreDomain
import SwiftUI
import MapKit

struct PlanView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var viewModel: PlanViewModel
    let vehicleConnected: Bool
    /// Runs the drive-start flow (possible occupancy opt-in prompt, then
    /// navigation), owned by `PlanView` so both start buttons share one prompt.
    let onStartDrive: () -> Void

    @State private var focusedSlot: PlanViewModel.Slot?
    @FocusState private var focusedField: PlanViewModel.Slot?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    // Origin row
                    SlotRow(
                        slot: .origin,
                        viewModel: viewModel,
                        focusedSlot: $focusedSlot,
                        focusedField: $focusedField,
                        placeholder: "Origin",
                        systemImage: "location.circle"
                    )

                    // Waypoints
                    ForEach(Array(viewModel.waypoints.enumerated()), id: \.offset) { index, _ in
                        SlotRow(
                            slot: .waypoint(index),
                            viewModel: viewModel,
                            focusedSlot: $focusedSlot,
                            focusedField: $focusedField,
                            placeholder: "Waypoint \(index + 1)",
                            systemImage: "mappin.and.ellipse"
                        )
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

                    Divider()

                    // Route summary / legs
                    if let plan = viewModel.plan {
                        PlanSummaryCard(plan: plan)

                        if !plan.legs.isEmpty {
                            Text("Route")
                                .font(.headline)
                            ForEach(Array(plan.legs.enumerated()), id: \.offset) { index, leg in
                                LegRow(leg: leg, index: index, totalLegs: plan.legs.count)
                            }
                        }

                        if !plan.stops.isEmpty {
                            Text("Charging stops")
                                .font(.headline)
                            ForEach(Array(plan.stops.enumerated()), id: \.offset) { index, stop in
                                StopCard(stop: stop, index: index, totalStops: plan.stops.count, viewModel: viewModel)
                            }
                        }
                    } else {
                        ProgressView("Planning…")
                            .frame(maxWidth: .infinity)
                            .padding()
                    }

                    Spacer(minLength: 40)
                }
                .padding()
            }
            .navigationTitle("Trip Plan")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Close") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Start Drive") { onStartDrive() }
                        .disabled(viewModel.plan == nil)
                }
            }
        }
    }
}

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
                .font(.body)
                .foregroundStyle(.secondary)
                .frame(width: 24)

            TextField(placeholder, text: binding)
                .focused($focusedField, equals: slot)
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled()
                .submitLabel(.next)
                .onSubmit {
                    focusedSlot = viewModel.nextSlot(after: slot)
                }
        }
    }

    private var binding: Binding<String> {
        Binding(
            get: { viewModel.text(for: slot) },
            set: { viewModel.set(text: $0, for: slot) }
        )
    }
}

private struct PlanSummaryCard: View {
    let plan: TripPlan

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("\(String(format: "%.0f", plan.totalDistanceKm)) km total")
                .font(.headline)
            Text("\(plan.totalDriveMinutes) min driving · \(plan.totalChargeMinutes) min charging")
                .font(.caption).foregroundStyle(.secondary)
            Text("Arrival SOC: \(Int(plan.arrivalSoc))%")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 10))
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
                Text("\(String(format: "%.0f", leg.distanceKm)) km · \(leg.estimateString)")
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
                Text("\(index + 1)").font(.caption.weight(.bold)).foregroundStyle(.white)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(stop.label).font(.subheadline.weight(.medium))
                if stop.isChargerStop, let address = stop.charger.address {
                    Text(address).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                if stop.isChargerStop {
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
            }

            Spacer()

            // Direct button, not just a Menu item: fires on the first tap. Menu
            // items can be dropped when the exclusion re-solves the plan (and the
            // stops array changes) while the menu is dismissing.
            if stop.isChargerStop {
                Button {
                    viewModel.excludeChargerAndReplan(stop.charger.id)
                } label: {
                    Image(systemName: "xmark.circle")
                        .font(.caption)
                }
            }
        }
        .padding(.vertical, 4)
    }
}
