import Combine
import CoreDomain
import Foundation
import SwiftData

/// Samples buffered before a batched write — ~1 minute of driving at 1 Hz.
private let sampleFlushBatch = 60

/// Minimum SOC drop (percent) before a SOC-delta energy figure is preferred.
private let socDeltaMinTrusted: Float = 3

/// Bands for comparable DC charge sessions.
private let comparableSocRange: ClosedRange<Float> = 10...45
private let comparableTempRange: ClosedRange<Float> = 15...35
private let minSessionsPerSide = 3

// MARK: - Data Types

/// Trend in DC charge acceptance — how peak charging power has changed over time.
public struct ChargeAcceptanceTrend: Sendable, Equatable {
    public let recentPeakKw: Float
    public let baselinePeakKw: Float
    public let recentSessions: Int
    public let baselineSessions: Int

    /// Negative means acceptance has fallen since the baseline period.
    public var changePercent: Float {
        baselinePeakKw > 0 ? (recentPeakKw - baselinePeakKw) / baselinePeakKw * 100 : 0
    }

    public init(recentPeakKw: Float, baselinePeakKw: Float, recentSessions: Int, baselineSessions: Int) {
        self.recentPeakKw = recentPeakKw
        self.baselinePeakKw = baselinePeakKw
        self.recentSessions = recentSessions
        self.baselineSessions = baselineSessions
    }
}

/// Aggregate stats for a set of trips.
public struct TripSummary: Sendable, Equatable {
    public let totalTrips: Int
    public let totalDistanceKm: Float
    public let totalEnergyKwh: Float
    public let avgEfficiencyKwhPer100km: Float?

    public init(totalTrips: Int, totalDistanceKm: Float, totalEnergyKwh: Float, avgEfficiencyKwhPer100km: Float?) {
        self.totalTrips = totalTrips
        self.totalDistanceKm = totalDistanceKm
        self.totalEnergyKwh = totalEnergyKwh
        self.avgEfficiencyKwhPer100km = avgEfficiencyKwhPer100km
    }
}

// MARK: - TripLogRepository

/// Trip and sample logging with retention policy: 1 Hz while a trip is active,
/// downsampled to 0.1 Hz on completion, purged at 90/365 days.
public final class TripLogRepository: @unchecked Sendable {
    private let modelContext: ModelContext
    private let entitlement: EntitlementRepository
    private let preferencesRepository: PreferencesRepository

    // Buffered samples
    private let pendingSamplesLock = NSLock()
    private var pendingSamples: [SampleEntity] = []

    // Active trip state
    private var activeTripId: String?
    private var tripStartSocDisplay: Float?
    private var tripStartSocBms: Float?
    private var tripStartTime: Date = Date()
    private var lastSampleAt: Date = Date(timeIntervalSince1970: 0)
    private var startOdometerKm: Int?
    private var grossEnergyConsumedKwh: Double = 0
    private var regenEnergyKwh: Double = 0
    private var netEnergyConsumedKwh: Double = 0
    private var lastTimestamp: Date = Date(timeIntervalSince1970: 0)
    private var gpsDistanceKm: Double = 0
    private var lastLat: Double?
    private var lastLon: Double?

    // Charge session state
    private var activeChargeSessionId: String?
    private var chargeStartTime: Date = Date()
    private var chargeStartSoc: Float = 0
    private var chargePeakPowerKw: Float = 0
    private var chargeEnergyAddedKwh: Double = 0
    private var chargePackTempStartC: Float?
    private var chargePowerSamplesCount: Int = 0
    private var chargePowerSum: Double = 0
    private var chargeType: String = "DC"
    private var lastChargeTimestamp: Date = Date(timeIntervalSince1970: 0)

    /// Time source for testing; production uses real clock.
    var clock: () -> Date = { Date() }

    // MARK: - Init

    public init(
        modelContext: ModelContext,
        entitlement: EntitlementRepository,
        preferencesRepository: PreferencesRepository
    ) {
        self.modelContext = modelContext
        self.entitlement = entitlement
        self.preferencesRepository = preferencesRepository
    }

    // MARK: - Public API

    public func trips() throws -> [TripEntity] {
        try flushPendingSamples()
        let descriptor = FetchDescriptor<TripEntity>(sortBy: [SortDescriptor(\.startTime, order: .reverse)])
        return try modelContext.fetch(descriptor)
    }

    public func chargeSessions() throws -> [ChargeSessionEntity] {
        let descriptor = FetchDescriptor<ChargeSessionEntity>(sortBy: [SortDescriptor(\.startTime, order: .reverse)])
        return try modelContext.fetch(descriptor)
    }

    public func samplesForTrip(tripId: String) throws -> [SampleEntity] {
        try flushPendingSamples()
        let descriptor = FetchDescriptor<SampleEntity>(
            predicate: #Predicate { $0.tripId == tripId },
            sortBy: [SortDescriptor(\.timestamp)]
        )
        return try modelContext.fetch(descriptor)
    }

    public func tripById(_ id: String) throws -> TripEntity? {
        let descriptor = FetchDescriptor<TripEntity>(predicate: #Predicate { $0.id == id })
        return try modelContext.fetch(descriptor).first
    }

    public func deleteChargeSession(id: String) throws {
        let descriptor = FetchDescriptor<ChargeSessionEntity>(predicate: #Predicate { $0.id == id })
        if let entity = try modelContext.fetch(descriptor).first {
            modelContext.delete(entity)
            try modelContext.save()
        }
    }

    public func setTripNote(id: String, note: String?) throws {
        let cleaned = note?.trimmingCharacters(in: .whitespaces)
        let effectiveNote = cleaned.flatMap { $0.isEmpty ? nil : $0 }
        if let trip = try tripById(id) {
            trip.note = effectiveNote
            try modelContext.save()
        }
    }

    public func getTripSummary(from startTime: Date, to endTime: Date) throws -> TripSummary {
        let descriptor = FetchDescriptor<TripEntity>(
            predicate: #Predicate { $0.startTime >= startTime && $0.startTime < endTime },
            sortBy: [SortDescriptor(\.startTime, order: .reverse)]
        )
        let trips = try modelContext.fetch(descriptor)
        let totalDistance = trips.reduce(0) { $0 + $1.distanceKm }
        let totalEnergy = trips.reduce(0) { $0 + $1.energyUsedKwh }
        let avgEff: Float? = totalDistance > 0 ? (totalEnergy / totalDistance * 100) : nil
        return TripSummary(
            totalTrips: trips.count,
            totalDistanceKm: totalDistance,
            totalEnergyKwh: totalEnergy,
            avgEfficiencyKwhPer100km: avgEff
        )
    }

    public func chargeAcceptanceTrend() throws -> ChargeAcceptanceTrend? {
        let descriptor = FetchDescriptor<ChargeSessionEntity>(sortBy: [SortDescriptor(\.startTime)])
        let allSessions = try modelContext.fetch(descriptor)

        let comparable = allSessions
            .filter { $0.chargeType == "DC" }
            .filter { comparableSocRange.contains($0.startSoc) }
            .filter { $0.packTempStartC == nil || comparableTempRange.contains($0.packTempStartC!) }
            .filter { $0.peakPowerKw > 0 }

        guard comparable.count >= minSessionsPerSide * 2 else { return nil }

        let midpoint = comparable.count / 2
        let baseline = Array(comparable.prefix(midpoint))
        let recent = Array(comparable.suffix(from: midpoint))
        guard baseline.count >= minSessionsPerSide, recent.count >= minSessionsPerSide else { return nil }

        return ChargeAcceptanceTrend(
            recentPeakKw: median(recent.map(\.peakPowerKw)),
            baselinePeakKw: median(baseline.map(\.peakPowerKw)),
            recentSessions: recent.count,
            baselineSessions: baseline.count
        )
    }

    public func deleteTrip(id: String) throws {
        if id == activeTripId { activeTripId = nil }
        pendingSamplesLock.withLock {
            pendingSamples.removeAll { $0.tripId == id }
        }
        // Delete samples
        let sampleDescriptor = FetchDescriptor<SampleEntity>(predicate: #Predicate { $0.tripId == id })
        for sample in try modelContext.fetch(sampleDescriptor) {
            modelContext.delete(sample)
        }
        // Delete trip
        let tripDescriptor = FetchDescriptor<TripEntity>(predicate: #Predicate { $0.id == id })
        if let trip = try modelContext.fetch(tripDescriptor).first {
            modelContext.delete(trip)
        }
        try modelContext.save()
    }

    public func restoreTrip(_ trip: TripEntity) throws {
        modelContext.insert(trip)
        try modelContext.save()
    }

    /// Writes any buffered samples. Called before every read of sample data, on trip end,
    /// and during teardown so an in-progress trip does not lose its tail.
    public func flushPendingSamples() throws {
        let batch = pendingSamplesLock.withLock {
            if pendingSamples.isEmpty { return [SampleEntity]() }
            let copy = pendingSamples
            pendingSamples.removeAll()
            return copy
        }
        guard !batch.isEmpty else { return }
        for sample in batch { modelContext.insert(sample) }
        try modelContext.save()
    }

    // MARK: - Trip Lifecycle

    public func startTrip(telemetry: VehicleTelemetry) throws {
        try flushPendingSamples()
        let id = UUID().uuidString
        activeTripId = id
        tripStartTime = clock()
        tripStartSocDisplay = telemetry.socDisplay
        tripStartSocBms = telemetry.socBms
        startOdometerKm = telemetry.odometerKm
        grossEnergyConsumedKwh = 0
        regenEnergyKwh = 0
        netEnergyConsumedKwh = 0
        lastTimestamp = Date(timeIntervalSince1970: 0)
        lastSampleAt = Date(timeIntervalSince1970: 0)
        gpsDistanceKm = 0
        lastLat = nil
        lastLon = nil

        let trip = TripEntity(
            id: id,
            startTime: tripStartTime,
            startSoc: (tripStartSocDisplay ?? tripStartSocBms) ?? 0
        )
        modelContext.insert(trip)
        try modelContext.save()
    }

    /// Record at 1 Hz for the active trip & charge tracking.
    public func onTelemetry(telemetry: VehicleTelemetry, lat: Double?, lon: Double?, inVehicle: Bool = false) throws {
        let now = clock()
        updateChargeSession(telemetry: telemetry, now: now, inVehicle: inVehicle)

        guard let tripId = activeTripId else { return }

        // Latch odometer from first frame that carries one
        if startOdometerKm == nil { startOdometerKm = telemetry.odometerKm }
        if tripStartSocDisplay == nil { tripStartSocDisplay = telemetry.socDisplay }
        if tripStartSocBms == nil { tripStartSocBms = telemetry.socBms }

        // Accumulate GPS distance
        if let lat, let lon {
            if let pLat = lastLat, let pLon = lastLon {
                let dist = haversineKm(lat1: pLat, lon1: pLon, lat2: lat, lon2: lon)
                if dist >= 0.001 && dist <= 0.5 {
                    gpsDistanceKm += dist
                    lastLat = lat
                    lastLon = lon
                }
            } else {
                lastLat = lat
                lastLon = lon
            }
        }

        // Integrate power continuously
        let power = telemetry.powerKw
        if let power, lastTimestamp.timeIntervalSince1970 > 0 {
            let dtHours = now.timeIntervalSince(lastTimestamp) / 3600.0
            if dtHours > 0 && dtHours <= (60.0 / 3600.0) {
                let energy = Double(power) * dtHours
                if power < 0 {
                    grossEnergyConsumedKwh += -energy
                    netEnergyConsumedKwh += -energy
                } else {
                    let speed = telemetry.speedKph
                    let moving = speed == nil || speed! > 3
                    if moving {
                        regenEnergyKwh += energy
                        netEnergyConsumedKwh = max(netEnergyConsumedKwh - energy, 0)
                    }
                }
            }
        }
        lastTimestamp = now

        // 1 Hz sample gate
        if now.timeIntervalSince(lastSampleAt) < 1.0 { return }
        lastSampleAt = now

        let sample = SampleEntity(
            tripId: tripId,
            timestamp: now,
            soc: telemetry.socDisplay ?? telemetry.socBms,
            powerKw: telemetry.powerKw,
            speedKph: telemetry.speedKph,
            lat: lat,
            lon: lon,
            ambientTempC: telemetry.ambientTempC.map { Float($0) },
            packTempC: telemetry.moduleTempsC.max().map { Float($0) }
        )

        let shouldFlush = pendingSamplesLock.withLock {
            pendingSamples.append(sample)
            return pendingSamples.count >= sampleFlushBatch
        }
        if shouldFlush { try flushPendingSamples() }
    }

    public func endTrip(telemetry: VehicleTelemetry) async throws {
        guard let tripId = activeTripId else { return }
        activeTripId = nil
        try flushPendingSamples()

        guard let trip = try tripById(tripId) else { return }
        let samples = try samplesForTrip(tripId: tripId)

        // Distance calculation
        let odoStart = startOdometerKm
        let odoEnd = telemetry.odometerKm
        let odoDelta: Int? = {
            guard let odoStart, let odoEnd, odoEnd >= odoStart else { return nil }
            return odoEnd - odoStart
        }()
        let sampleDist = estimateDistanceKm(samples: samples)
        let distanceKm: Float = {
            if let odoDelta, odoDelta > 0, odoDelta <= 2000 { return Float(odoDelta) }
            if gpsDistanceKm > 0 { return max(Float(gpsDistanceKm), sampleDist) }
            return sampleDist
        }()

        let ambientAvg: Float? = {
            let temps = samples.compactMap(\.ambientTempC)
            guard !temps.isEmpty else { return nil }
            return Float(temps.reduce(0, +)) / Float(temps.count)
        }()

        // Usable capacity
        var usableKwh: Float = 77.4
        let prefsCancellable = preferencesRepository.preferences
            .prefix(1)
            .sink { prefs in
                usableKwh = Ioniq5Constants.usableKwhForProfile(prefs.activeProfileId, customKwh: prefs.customUsableBatteryKwh)
            }
        // We need to wait for the value — use a simple approach
        // (In production, use withCheckedContinuation or a Task)

        // Since AnyPublisher requires async handling, directly read the value:
        let prefs = await withCheckedContinuation { (continuation: CheckedContinuation<UserPreferences, Never>) in
            var cancellable: AnyCancellable?
            cancellable = preferencesRepository.preferences
                .prefix(1)
                .sink { value in
                    continuation.resume(returning: value)
                    _ = cancellable // keep alive
                }
        }
        usableKwh = Ioniq5Constants.usableKwhForProfile(prefs.activeProfileId, customKwh: prefs.customUsableBatteryKwh)
        _ = prefsCancellable // silence warning

        // SOC pair
        let socPair: (Float, Float)? = {
            if let start = tripStartSocDisplay, let end = telemetry.socDisplay {
                return (start, end)
            }
            if let start = tripStartSocBms, let end = telemetry.socBms {
                return (start, end)
            }
            return nil
        }()

        let startSoc = socPair?.0 ?? trip.startSoc
        let endSoc = socPair?.1 ?? samples.compactMap(\.soc).last
        let socDelta = socPair.map { $0.0 - $0.1 } ?? 0
        let sampleAnalytics = analyzeDrive(samples: samples)

        // Energy calculation
        let integratedKwh = netEnergyConsumedKwh > 0 ? Float(netEnergyConsumedKwh) :
            (sampleAnalytics.netConsumedKwh > 0 ? Float(sampleAnalytics.netConsumedKwh) :
                (sampleAnalytics.grossConsumedKwh > 0 ? Float(sampleAnalytics.grossConsumedKwh) : nil))
        let socEnergyKwh: Float? = socDelta > 0 ? (socDelta / 100 * usableKwh) : nil

        var energyKwh: Float = {
            if socDelta >= socDeltaMinTrusted, let e = socEnergyKwh { return e }
            if let e = integratedKwh { return e }
            if let e = socEnergyKwh { return e }
            return 0
        }()

        // Fallback: estimate from distance if energy still 0
        if energyKwh <= 0 && distanceKm >= 0.1 {
            energyKwh = max(distanceKm * 0.16, 0.01)
        }

        // Discard trips where vehicle didn't meaningfully move
        if distanceKm < 0.1 {
            // Delete samples
            let sampleDesc = FetchDescriptor<SampleEntity>(predicate: #Predicate { $0.tripId == tripId })
            for s in try modelContext.fetch(sampleDesc) { modelContext.delete(s) }
            modelContext.delete(trip)
            try modelContext.save()
            return
        }

        trip.endTime = clock()
        trip.startSoc = startSoc
        trip.endSoc = endSoc
        trip.distanceKm = distanceKm
        trip.energyUsedKwh = energyKwh
        trip.avgConsumptionKwhPer100km = distanceKm > 0.1 ? (energyKwh / distanceKm * 100) : nil
        trip.ambientTempAvgC = ambientAvg
        try modelContext.save()

        try downsample(tripId: tripId, samples: samples)

        // Enforce retention window
        let isPro = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            var cancellable: AnyCancellable?
            cancellable = entitlement.isPro
                .prefix(1)
                .sink { value in
                    continuation.resume(returning: value)
                    _ = cancellable
                }
        }
        try purge(isPro: isPro)
    }

    // MARK: - Private: Downsampling & Purge

    /// Keep one sample per 10 s once the trip is history.
    private func downsample(tripId: String, samples: [SampleEntity]) throws {
        guard samples.count >= 20 else { return }
        var kept: [SampleEntity] = []
        var lastKeptAt: Date = Date(timeIntervalSince1970: 0)

        for sample in samples {
            if sample.timestamp.timeIntervalSince(lastKeptAt) >= 10 {
                let copy = SampleEntity(
                    tripId: sample.tripId,
                    timestamp: sample.timestamp,
                    soc: sample.soc,
                    powerKw: sample.powerKw,
                    speedKph: sample.speedKph,
                    lat: sample.lat,
                    lon: sample.lon,
                    elevationM: sample.elevationM,
                    ambientTempC: sample.ambientTempC,
                    packTempC: sample.packTempC
                )
                kept.append(copy)
                lastKeptAt = sample.timestamp
            }
        }

        // Delete old samples
        let oldDescriptor = FetchDescriptor<SampleEntity>(predicate: #Predicate { $0.tripId == tripId })
        for old in try modelContext.fetch(oldDescriptor) { modelContext.delete(old) }
        for k in kept { modelContext.insert(k) }
        try modelContext.save()
    }

    public func purge(isPro: Bool) throws {
        let retentionDays: Double = isPro ? 365 : 90
        let cutoff = clock().addingTimeInterval(-retentionDays * 24 * 60 * 60)

        // Purge trips
        let tripDescriptor = FetchDescriptor<TripEntity>(predicate: #Predicate { $0.startTime < cutoff })
        for trip in try modelContext.fetch(tripDescriptor) {
            modelContext.delete(trip)
        }

        // Purge orphan samples
        let sampleDescriptor = FetchDescriptor<SampleEntity>(predicate: #Predicate { $0.timestamp < cutoff })
        for sample in try modelContext.fetch(sampleDescriptor) {
            modelContext.delete(sample)
        }
        // Charge sessions are intentionally never purged.

        try modelContext.save()
    }

    // MARK: - Export

    public func exportCsv(samples: [SampleEntity]) -> String {
        var csv = "timestamp,soc,power_kw,speed_kph,lat,lon,ambient_c,pack_temp_c\n"
        let formatter = ISO8601DateFormatter()
        for s in samples {
            let ts = formatter.string(from: s.timestamp)
            csv += "\(ts),\(s.soc?.description ?? ""),\(s.powerKw?.description ?? ""),\(s.speedKph?.description ?? ""),"
            csv += "\(s.lat?.description ?? ""),\(s.lon?.description ?? ""),\(s.ambientTempC?.description ?? ""),\(s.packTempC?.description ?? "")\n"
        }
        return csv
    }

    public func exportGpx(samples: [SampleEntity]) -> String {
        var gpx = """
            <?xml version="1.0" encoding="UTF-8"?>
            <gpx version="1.1" creator="Ioniq 5 Telemetry" xmlns="http://www.topografix.com/GPX/1/1">
              <trk><name>Trip</name><trkseg>
            """
        let formatter = ISO8601DateFormatter()
        for s in samples {
            guard let lat = s.lat, let lon = s.lon else { continue }
            let ts = formatter.string(from: s.timestamp)
            gpx += "      <trkpt lat=\"\(lat)\" lon=\"\(lon)\"><time>\(ts)</time></trkpt>\n"
        }
        gpx += """
              </trkseg></trk>
            </gpx>
            """
        return gpx
    }

    // MARK: - Private: Distance & Math

    /// Great-circle distance between two coordinates, in kilometres.
    private func haversineKm(lat1: Double, lon1: Double, lat2: Double, lon2: Double) -> Double {
        let r = 6371.0
        let dLat = (lat2 - lat1) * .pi / 180.0
        let dLon = (lon2 - lon1) * .pi / 180.0
        let a = sin(dLat / 2) * sin(dLat / 2) +
            cos(lat1 * .pi / 180.0) * cos(lat2 * .pi / 180.0) *
            sin(dLon / 2) * sin(dLon / 2)
        return r * 2 * atan2(sqrt(a), sqrt(1 - a))
    }

    private func estimateDistanceKm(samples: [SampleEntity]) -> Float {
        var haversineSum = 0.0
        var prevLat: Double?
        var prevLon: Double?

        for sample in samples {
            guard let lat = sample.lat, let lon = sample.lon else { continue }
            if let pLat = prevLat, let pLon = prevLon {
                let d = haversineKm(lat1: pLat, lon1: pLon, lat2: lat, lon2: lon)
                if d >= 0.001 && d <= 0.5 {
                    haversineSum += d
                }
            }
            prevLat = lat
            prevLon = lon
        }
        if haversineSum > 0 { return Float(haversineSum) }

        // Fallback: speed × time
        var speedSum = 0.0
        for i in 1..<samples.count {
            let dt = samples[i].timestamp.timeIntervalSince(samples[i - 1].timestamp) / 3600.0
            guard let v = samples[i].speedKph else { continue }
            speedSum += Double(v) * dt
        }
        return Float(speedSum)
    }

    private func median(_ values: [Float]) -> Float {
        let sorted = values.sorted()
        let mid = sorted.count / 2
        if sorted.count % 2 == 0 {
            return (sorted[mid - 1] + sorted[mid]) / 2
        }
        return sorted[mid]
    }

    // MARK: - Private: Charge Session

    private func updateChargeSession(telemetry: VehicleTelemetry, now: Date, inVehicle: Bool) {
        let isCharging = telemetry.isCharging || (telemetry.chargeType != nil && telemetry.chargeType != .none)
        let currentPowerKw = telemetry.powerKw.map { abs($0) } ?? 0
        let speed = telemetry.speedKph
        let stationary = speed == nil || speed! <= 3

        if isCharging && currentPowerKw > 0.1 && stationary && !inVehicle {
            if activeChargeSessionId == nil {
                // Start new charge session
                let sessionId = UUID().uuidString
                activeChargeSessionId = sessionId
                chargeStartTime = now
                chargeStartSoc = telemetry.socDisplay ?? telemetry.socBms ?? 0
                chargePeakPowerKw = currentPowerKw
                chargeEnergyAddedKwh = 0
                chargePackTempStartC = telemetry.moduleTempsC.max().map { Float($0) }
                chargePowerSamplesCount = 1
                chargePowerSum = Double(currentPowerKw)
                lastChargeTimestamp = now
                chargeType = telemetry.chargeType?.rawValue ?? (currentPowerKw > 22 ? "DC" : "AC")

                let session = ChargeSessionEntity(
                    id: sessionId,
                    startTime: chargeStartTime,
                    startSoc: chargeStartSoc,
                    peakPowerKw: chargePeakPowerKw,
                    avgPowerKw: currentPowerKw,
                    chargeType: chargeType,
                    packTempStartC: chargePackTempStartC
                )
                modelContext.insert(session)
                try? modelContext.save()
            } else {
                // Update ongoing session
                let dtHours: Double
                if lastChargeTimestamp.timeIntervalSince1970 > 0 {
                    dtHours = max(now.timeIntervalSince(lastChargeTimestamp), 0) / 3600.0
                } else {
                    dtHours = 0
                }

                if dtHours > 0 && dtHours < 0.1 {
                    chargeEnergyAddedKwh += Double(currentPowerKw) * dtHours
                }
                lastChargeTimestamp = now

                if currentPowerKw > chargePeakPowerKw {
                    chargePeakPowerKw = currentPowerKw
                }
                chargePowerSamplesCount += 1
                chargePowerSum += Double(currentPowerKw)

                let currentSoc = telemetry.socDisplay ?? telemetry.socBms
                let avgPower = Float(chargePowerSum / Double(chargePowerSamplesCount))

                if let sid = activeChargeSessionId {
                    let desc = FetchDescriptor<ChargeSessionEntity>(predicate: #Predicate { $0.id == sid })
                    if let existing = try? modelContext.fetch(desc).first {
                        existing.endTime = now
                        existing.startSoc = chargeStartSoc
                        existing.endSoc = currentSoc
                        existing.energyAddedKwh = Float(chargeEnergyAddedKwh)
                        existing.peakPowerKw = chargePeakPowerKw
                        existing.avgPowerKw = avgPower
                        existing.chargeType = chargeType
                        existing.packTempStartC = chargePackTempStartC
                        try? modelContext.save()
                    }
                }
            }
        } else if let sid = activeChargeSessionId {
            // End charge session
            if chargeEnergyAddedKwh < 1.0 {
                // Discard negligible sessions
                let desc = FetchDescriptor<ChargeSessionEntity>(predicate: #Predicate { $0.id == sid })
                if let entity = try? modelContext.fetch(desc).first {
                    modelContext.delete(entity)
                    try? modelContext.save()
                }
                activeChargeSessionId = nil
                lastChargeTimestamp = Date(timeIntervalSince1970: 0)
                return
            }

            let currentSoc = telemetry.socDisplay ?? telemetry.socBms
            let avgPower = chargePowerSamplesCount > 0
                ? Float(chargePowerSum / Double(chargePowerSamplesCount))
                : chargePeakPowerKw

            let desc = FetchDescriptor<ChargeSessionEntity>(predicate: #Predicate { $0.id == sid })
            if let existing = try? modelContext.fetch(desc).first {
                existing.endTime = now
                existing.startSoc = chargeStartSoc
                existing.endSoc = currentSoc
                existing.energyAddedKwh = Float(chargeEnergyAddedKwh)
                existing.peakPowerKw = chargePeakPowerKw
                existing.avgPowerKw = avgPower
                existing.chargeType = chargeType
                existing.packTempStartC = chargePackTempStartC
                try? modelContext.save()
            }
            activeChargeSessionId = nil
            lastChargeTimestamp = Date(timeIntervalSince1970: 0)
        }
    }
}
