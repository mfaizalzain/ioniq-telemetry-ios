import SwiftUI
import CoreUI
import CoreDomain

struct TripsView: View {
    @Environment(AppServices.self) private var services

    var body: some View {
        NavigationStack {
            VStack {
                EmptyTripsView()
            }
            .background(Color(red: 0.043, green: 0.071, blue: 0.125))
            .navigationTitle("Trips")
        }
    }
}

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
            Text("Trips are automatically logged whenever the vehicle ignition is active. Start driving and trips will appear here.")
                .font(.body)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
            Spacer()
        }
    }
}

struct TripSummaryHeader: View {
    var tripCount: Int = 0
    var totalDistanceKm: Float = 0
    var avgEfficiency: Float = 0

    var body: some View {
        HStack(spacing: 0) {
            statItem(label: "ALL TIME", value: String(tripCount))
            Divider().frame(height: 32).padding(.horizontal, 12)
            statItem(label: "TOTAL", value: String(format: "%.0f km", totalDistanceKm))
            Divider().frame(height: 32).padding(.horizontal, 12)
            statItem(label: "AVG EFF", value: String(format: "%.1f", avgEfficiency))
        }
        .padding(12)
        .background(Color(white: 1).opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    func statItem(label: String, value: String) -> some View {
        VStack(spacing: 2) {
            Text(label)
                .font(.ioniqCaption)
                .foregroundStyle(.tertiary)
                .ioniqStatLabel()
            Text(value)
                .font(.system(size: 16, weight: .bold))
        }
        .frame(maxWidth: .infinity)
    }
}

struct TripCard: View {
    var body: some View {
        GroupBox {
            VStack(spacing: 10) {
                HStack {
                    Circle()
                        .fill(Color(red: 0.09, green: 0.91, blue: 0.76))
                        .frame(width: 36, height: 36)
                        .overlay {
                            Image(systemName: "car.fill")
                                .font(.caption)
                                .foregroundStyle(.black)
                        }
                    VStack(alignment: .leading) {
                        Text("Today, 8:30 AM")
                            .font(.body.weight(.medium))
                        Text("42m")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: "trash")
                        .foregroundStyle(.red)
                }
                Divider()
                HStack {
                    statColumn(label: "DISTANCE", value: "12.4 km")
                    statColumn(label: "ENERGY", value: "2.1 kWh")
                    statColumn(label: "EFFICIENCY", value: "16.9 kWh/100km")
                }
                // SOC bar
                HStack(spacing: 4) {
                    Text(String(format: "%.0f%%", 85.0))
                        .font(.caption)
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 4)
                                .fill(.quaternary)
                            RoundedRectangle(cornerRadius: 4)
                                .fill(
                                    LinearGradient(colors: [
                                        Color(red: 0.40, green: 0.73, blue: 0.42),
                                        Color(red: 0.09, green: 0.91, blue: 0.76)
                                    ], startPoint: .leading, endPoint: .trailing)
                                )
                                .frame(width: geo.size.width * 0.85)
                        }
                    }
                    .frame(height: 8)
                    Text(String(format: "%.0f%%", 78.0))
                        .font(.caption)
                }
            }
            .padding(16)
        }
        .padding(.horizontal)
        .backgroundStyle(.ultraThinMaterial)
    }

    func statColumn(label: String, value: String) -> some View {
        VStack(spacing: 2) {
            Text(label)
                .font(.ioniqCaption.weight(.medium))
                .foregroundStyle(.tertiary)
                .ioniqStatLabel()
            Text(value)
                .font(.system(size: 14, weight: .bold))
        }
        .frame(maxWidth: .infinity)
    }
}

struct TripDetailView: View {
    var tripId: String

    var body: some View {
        Text("Trip Detail: \(tripId)")
            .foregroundStyle(.secondary)
            .navigationTitle("Trip Detail")
    }
}
