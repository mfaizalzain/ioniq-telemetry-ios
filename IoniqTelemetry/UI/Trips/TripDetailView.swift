import Charts
import CoreData
import CoreDomain
import CoreUI
import MapKit
import SwiftUI

/// Detail for one trip: route (when GPS samples exist), the SOC / speed / power
/// traces, and an editable note.
struct TripDetailView: View {
    let trip: TripEntity
    let viewModel: TripsViewModel

    @State private var samples: [SampleEntity] = []
    @State private var note: String = ""
    @State private var isEditingNote = false

    private var routePoints: [CLLocationCoordinate2D] {
        samples.compactMap { sample in
            guard let lat = sample.lat, let lon = sample.lon else { return nil }
            return CLLocationCoordinate2D(latitude: lat, longitude: lon)
        }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                summaryCard

                if routePoints.count > 1 {
                    routeMap
                } else {
                    NoRouteCard()
                }

                if samples.isEmpty {
                    ContentUnavailableView(
                        "No samples recorded",
                        systemImage: "chart.xyaxis.line",
                        description: Text("This trip has no logged samples to chart.")
                    )
                    .frame(height: 180)
                } else {
                    DriveAnalyticsCard(analytics: analyzeDrive(samples: samples))
                    TraceChart(title: "STATE OF CHARGE", unit: "%", samples: samples) { $0.soc }
                    TraceChart(title: "SPEED", unit: "km/h", samples: samples) { $0.speedKph }
                    TraceChart(title: "POWER", unit: "kW", samples: samples) { $0.powerKw }
                }

                noteCard

                PostTripBriefingView(
                    trip: trip,
                    recentTrips: viewModel.recentTrips,
                    samples: viewModel.samples,
                    isPro: viewModel.isPro,
                    aiKey: viewModel.aiKey,
                    aiProvider: viewModel.aiProvider,
                    aiFeaturesEnabled: viewModel.aiFeaturesEnabled,
                    efficiencyBaseline: viewModel.efficiencyBaseline
                )
            }
            .padding(.vertical)
        }
        .background(Color.appBackground)
        .navigationTitle(trip.startTime.formatted(date: .abbreviated, time: .shortened))
        .navigationBarTitleDisplayMode(.inline)
        .task {
            samples = viewModel.samples(for: trip)
            note = trip.note ?? ""
        }
    }

    private var summaryCard: some View {
        GroupBox {
            HStack(spacing: 0) {
                stat("DISTANCE", viewModel.distance(trip.distanceKm))
                stat("ENERGY", String(format: "%.1f kWh", trip.energyUsedKwh))
                stat("DURATION", viewModel.duration(trip))
                stat("EFFICIENCY", viewModel.efficiency(trip.avgConsumptionKwhPer100km))
            }
            .padding(.vertical, 8)
        }
        .padding(.horizontal)
        .backgroundStyle(.ultraThinMaterial)
    }

    private var routeMap: some View {
        Map {
            MapPolyline(coordinates: routePoints)
                .stroke(Color.appAccent, lineWidth: 4)
            if let start = routePoints.first {
                Marker("Start", systemImage: "flag", coordinate: start)
                    .tint(Color.appGreen)
            }
            if let end = routePoints.last {
                Marker("End", systemImage: "flag.checkered", coordinate: end)
                    .tint(Color.appAccent)
            }
        }
        .frame(height: 240)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal)
        .accessibilityLabel("Route map")
    }

    private var noteCard: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                Text("NOTE")
                    .font(.ioniqCaption)
                    .foregroundStyle(.secondary)
                    .ioniqStatLabel()

                TextField("Add a note…", text: $note, axis: .vertical)
                    .lineLimit(1...4)
                    .textFieldStyle(.plain)
                    .onChange(of: note) { isEditingNote = true }

                if isEditingNote {
                    Button("Save") {
                        viewModel.setNote(note.isEmpty ? nil : note, for: trip)
                        isEditingNote = false
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Color.appAccent)
                    // The system's label choice on the bright accent is unreadable.
                    .foregroundStyle(Color.appOnAccent)
                }
            }
            .padding(12)
        }
        .padding(.horizontal)
        .backgroundStyle(.ultraThinMaterial)
    }

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(spacing: 4) {
            Text(label)
                .font(.ioniqCaption)
                .foregroundStyle(.secondary)
                .ioniqStatLabel()
            Text(value)
                .font(.system(size: 14, weight: .semibold))
                .minimumScaleFactor(0.6)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }
}

/// How much of the energy drawn from the pack came back through regen.
///
/// Integrated from this trip's samples, so recovered, net and share all share one
/// basis — the Android build's "Drive Analytics" card.
private struct DriveAnalyticsCard: View {
    let analytics: DriveAnalytics

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                Label("DRIVE ANALYTICS", systemImage: "battery.100.bolt")
                    .font(.ioniqCaption)
                    .foregroundStyle(.secondary)
                    .ioniqStatLabel()

                if analytics.hasData {
                    HStack(spacing: 0) {
                        stat("RECOVERED", String(format: "%.1f kWh", analytics.regenKwh))
                        stat("REGEN SHARE", String(format: "%.0f%%", analytics.regenSharePercent))
                        stat("NET ENERGY", String(format: "%.1f kWh", analytics.netConsumedKwh))
                        stat("RATING", analytics.regenRating)
                    }

                    shareBar

                    Text("Regenerative braking recovered \(String(format: "%.0f", analytics.regenSharePercent))% of the energy drawn from the battery. Higher is more efficient — smoother, anticipatory driving recovers more.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Not enough power telemetry was logged for this trip to analyze regen.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(12)
        }
        .padding(.horizontal)
        .backgroundStyle(.ultraThinMaterial)
    }

    /// Recovered energy as a proportion of gross draw.
    private var shareBar: some View {
        GeometryReader { geometry in
            let fraction = min(max(Double(analytics.regenSharePercent) / 100, 0), 1)
            ZStack(alignment: .leading) {
                Capsule().fill(Color.appSurfaceVariant)
                Capsule()
                    .fill(Color.appGreen)
                    .frame(width: geometry.size.width * fraction)
            }
        }
        .frame(height: 8)
        .accessibilityHidden(true)
    }

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(spacing: 4) {
            Text(label)
                .font(.ioniqCaption)
                .foregroundStyle(.secondary)
                .ioniqStatLabel()
            Text(value)
                .font(.system(size: 14, weight: .semibold))
                .minimumScaleFactor(0.6)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }
}

/// One metric over the trip's timeline. Samples missing the metric are dropped
/// rather than plotted as zero, which would fake a dip to the floor.
private struct TraceChart: View {
    let title: String
    let unit: String
    let samples: [SampleEntity]
    let value: (SampleEntity) -> Float?

    private var points: [(date: Date, value: Double)] {
        samples.compactMap { sample in
            guard let raw = value(sample) else { return nil }
            return (sample.timestamp, Double(raw))
        }
    }

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                Text("\(title) (\(unit))")
                    .font(.ioniqCaption)
                    .foregroundStyle(.secondary)
                    .ioniqStatLabel()

                if points.isEmpty {
                    Text("Not recorded")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .frame(height: 120)
                } else {
                    Chart(points, id: \.date) { point in
                        LineMark(x: .value("Time", point.date), y: .value(title, point.value))
                            .foregroundStyle(Color.appAccent)
                            .interpolationMethod(.monotone)
                    }
                    .chartYAxis { AxisMarks(position: .leading) }
                    .frame(height: 120)
                }
            }
            .padding(12)
        }
        .padding(.horizontal)
        .backgroundStyle(.ultraThinMaterial)
        .accessibilityLabel("\(title) chart")
    }
}

private struct NoRouteCard: View {
    var body: some View {
        GroupBox {
            HStack(spacing: 12) {
                Image(systemName: "mappin.slash")
                    .foregroundStyle(.secondary)
                Text("No GPS track for this trip.")
                    .font(.ioniqBody)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(12)
        }
        .padding(.horizontal)
        .backgroundStyle(.ultraThinMaterial)
    }
}
