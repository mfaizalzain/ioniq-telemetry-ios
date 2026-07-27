import SwiftUI
import CoreUI

struct PlanView: View {
    @Environment(AppServices.self) private var services
    @State private var origin = ""
    @State private var destination = ""
    @State private var departureSoc: Float = 80
    @State private var reservePercent: Float = 20

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: 16) {
                    PlanHeader()

                    RouteBuilderCard(origin: $origin, destination: $destination)

                    BatteryParametersCard(departureSoc: $departureSoc, reservePercent: $reservePercent)

                    if !origin.isEmpty && !destination.isEmpty {
                        Button("Plan Route") {
                            // Trigger planning
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(Color(red: 0.09, green: 0.91, blue: 0.76))
                    }

                    NearbyChargersSection()

                    FavoriteTripsSection()
                }
                .padding()
            }
            .background(Color(red: 0.043, green: 0.071, blue: 0.125))
            .navigationTitle("Plan")
        }
    }
}

struct PlanHeader: View {
    var body: some View {
        HStack {
            Image(systemName: "map.fill")
                .foregroundStyle(Color(red: 0.09, green: 0.91, blue: 0.76))
            Text("Trip Planner")
                .font(.title3.weight(.semibold))
            Spacer()
        }
    }
}

struct RouteBuilderCard: View {
    @Binding var origin: String
    @Binding var destination: String

    var body: some View {
        GroupBox {
            VStack(spacing: 12) {
                HStack {
                    VStack(spacing: 6) {
                        Circle().fill(Color(red: 0.09, green: 0.91, blue: 0.76)).frame(width: 8, height: 8)
                        Rectangle().fill(.quaternary).frame(width: 2, height: 24)
                        Circle().fill(Color(red: 0.94, green: 0.33, blue: 0.31)).frame(width: 8, height: 8)
                    }
                    VStack(spacing: 8) {
                        TextField("Origin", text: $origin)
                            .textFieldStyle(.roundedBorder)
                        TextField("Destination", text: $destination)
                            .textFieldStyle(.roundedBorder)
                    }
                }
            }
            .padding(12)
        }
        .backgroundStyle(.ultraThinMaterial)
    }
}

struct BatteryParametersCard: View {
    @Binding var departureSoc: Float
    @Binding var reservePercent: Float

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                Text("BATTERY")
                    .font(.ioniqCaption.weight(.medium))
                    .ioniqStatLabel()
                    .foregroundStyle(.secondary)

                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Departure SOC")
                            .font(.subheadline)
                        Spacer()
                        Text("\(String(format: "%.0f", departureSoc))%")
                            .font(.headline)
                            .foregroundStyle(Color(red: 0.09, green: 0.91, blue: 0.76))
                    }
                    Slider(value: $departureSoc, in: 10...100, step: 5)
                        .tint(Color(red: 0.09, green: 0.91, blue: 0.76))
                }

                Text("Arrival Reserve Target")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                HStack(spacing: 8) {
                    ReserveChip(label: "⚡ Aggressive", value: 10, selected: $reservePercent)
                    ReserveChip(label: "🛡️ Safe", value: 20, selected: $reservePercent)
                    ReserveChip(label: "🔋 Conservative", value: 30, selected: $reservePercent)
                }
            }
            .padding(12)
        }
        .backgroundStyle(.ultraThinMaterial)
    }
}

struct ReserveChip: View {
    var label: String
    var value: Float
    @Binding var selected: Float

    var body: some View {
        Button {
            selected = value
        } label: {
            Text(label)
                .font(.caption.weight(.medium))
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(selected == value ? Color(red: 0.09, green: 0.91, blue: 0.76) : .quaternary)
                .foregroundStyle(selected == value ? .black : .primary)
                .clipShape(Capsule())
        }
    }
}

struct NearbyChargersSection: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("NEARBY CHARGERS")
                .font(.ioniqCaption.weight(.medium))
                .ioniqStatLabel()
                .foregroundStyle(.secondary)

            Text("No nearby chargers found. Configure a routing key to enable live charger search.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.quaternary.opacity(0.3))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}

struct FavoriteTripsSection: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("SAVED TRIPS")
                .font(.ioniqCaption.weight(.medium))
                .ioniqStatLabel()
                .foregroundStyle(.secondary)

            Text("Save a trip plan to access it quickly here.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.quaternary.opacity(0.3))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}
