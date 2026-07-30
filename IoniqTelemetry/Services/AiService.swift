import CoreData
import CoreDomain
import Foundation

/// AI-powered service for charging insights, battery health reports, and
/// contextual assistant chat. Supports Gemini (via Google AI) and DeepSeek
/// (OpenAI-compatible API). All methods require a valid API key for the selected
/// provider and Pro entitlement (gated at the call site).
@Observable
@MainActor
final class AiService {

    private let session: URLSession
    private let baseURLGemini = "https://generativelanguage.googleapis.com/v1beta/models/gemini-flash-lite-latest:generateContent"
    private let baseURLDeepSeek = "https://api.deepseek.com/v1/chat/completions"
    private let deepseekModel = "deepseek-v4-flash"

    init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30
        self.session = URLSession(configuration: config)
    }

    // MARK: - Post-Trip Briefing

    /// Generates a concise post-trip briefing from trip data and telemetry.
    /// - Parameters:
    ///   - trip: The completed trip.
    ///   - recentTrips: Recent trips for context (e.g. efficiency trend).
    ///   - telemetrySamples: Telemetry samples for this trip.
    ///   - efficiencyBaseline: Vehicle baseline efficiency in kWh/100km.
    ///   - apiKey: API key for the selected provider.
    ///   - aiProvider: The AI provider to use (Gemini or DeepSeek).
    /// - Returns: AI-generated briefing text.
    func generatePostTripBriefing(
        trip: TripEntity,
        recentTrips: [TripEntity],
        telemetrySamples: [SampleEntity],
        efficiencyBaseline: Double?,
        vehicleName: String,
        usableBatteryKwh: Double,
        apiKey: String,
        aiProvider: AiProvider = .gemini,
        countryCode: String? = nil
    ) async throws -> String {
        guard !apiKey.isEmpty else { throw AiError.missingApiKey }

        let prompt = AiPrompts.postTripBriefing(
            tripJson: buildTripJson(trip: trip, samples: telemetrySamples),
            recentTripsSummary: buildRecentTripsSummary(recentTrips: recentTrips),
            efficiencyBaseline: efficiencyBaseline,
            vehicleName: vehicleName,
            usableBatteryKwh: usableBatteryKwh,
            countryCode: countryCode
        )
        return try await send(prompt, provider: aiProvider, apiKey: apiKey)
    }

    // MARK: - AI Digest

    /// Generates a weekly or monthly digest of driving activity.
    /// - Parameters:
    ///   - trips: Trips in the period.
    ///   - chargeSessions: Charge sessions in the period, for charging context.
    ///   - period: Weekly or monthly.
    ///   - apiKey: API key for the selected provider.
    ///   - aiProvider: The AI provider to use (Gemini or DeepSeek).
    /// - Returns: AI-generated digest text.
    func generateDigest(
        trips: [TripEntity],
        chargeSessions: [ChargeSessionEntity] = [],
        period: DigestPeriod,
        apiKey: String,
        vehicleName: String = "Ioniq 5",
        countryCode: String? = nil,
        aiProvider: AiProvider = .gemini
    ) async throws -> String {
        guard !apiKey.isEmpty else { throw AiError.missingApiKey }
        guard !trips.isEmpty else { return "No trips recorded this \(period.label.lowercased())." }

        let prompt = AiPrompts.digest(
            stats: buildDigestStats(trips: trips),
            chargeSessionsSummary: buildChargeSessionsSummary(sessions: chargeSessions),
            period: period,
            vehicleName: vehicleName,
            countryCode: countryCode
        )
        return try await send(prompt, provider: aiProvider, apiKey: apiKey)
    }

    // MARK: - Charging Insight

    /// Generates a plain-language insight about recent charge sessions.
    /// - Parameters:
    ///   - chargeSessions: Last 30 charge sessions (most recent first).
    ///   - apiKey: API key for the selected provider.
    ///   - aiProvider: The AI provider to use (Gemini or DeepSeek).
    /// - Returns: AI-generated insight text.
    func generateChargingInsight(
        chargeSessions: [ChargeSessionEntity],
        apiKey: String,
        aiProvider: AiProvider = .gemini
    ) async throws -> String {
        guard !chargeSessions.isEmpty else { return "No charge sessions to analyse." }
        guard !apiKey.isEmpty else { throw AiError.missingApiKey }

        let recent = Array(chargeSessions.prefix(30))
        let prompt = AiPrompts.chargingInsight(sessionSummary: buildSessionRows(sessions: recent))
        return try await send(prompt, provider: aiProvider, apiKey: apiKey)
    }

    // MARK: - Battery Health Report

    /// Generates a battery health report from SOH history, voltage deltas, and
    /// charge speed trends.
    func generateBatteryReport(
        sohHistory: [(Date, Double)],
        voltageDeltas: [Double],
        chargeSpeeds: [(Date, Double)],
        apiKey: String,
        aiProvider: AiProvider = .gemini
    ) async throws -> String {
        guard !apiKey.isEmpty else { throw AiError.missingApiKey }

        let prompt = AiPrompts.batteryReport(
            sohHistory: buildSohRows(sohHistory),
            voltageDeltas: buildVoltageDeltaLine(voltageDeltas),
            chargeSpeeds: buildChargeSpeedRows(chargeSpeeds)
        )
        return try await send(prompt, provider: aiProvider, apiKey: apiKey)
    }

    // MARK: - AiAssistant with Context

    /// Sends a user query to Gemini with vehicle telemetry context prepended.
    func askCopilotWithContext(
        query: String,
        telemetryContext: String,
        apiKey: String,
        aiProvider: AiProvider = .gemini
    ) async throws -> String {
        guard !apiKey.isEmpty else { throw AiError.missingApiKey }
        guard !query.isEmpty else { throw AiError.emptyQuery }

        let prompt = AiPrompts.assistant(query: query, telemetryContext: telemetryContext)
        return try await send(prompt, provider: aiProvider, apiKey: apiKey)
    }

    // MARK: - Validation

    /// Validates an API key by sending a lightweight query to the specified provider.
    func validateApiKey(_ apiKey: String, provider: AiProvider) async throws -> Bool {
        guard !apiKey.isEmpty else { throw AiError.missingApiKey }
        let res = try await sendPrompt(provider: provider, apiKey: apiKey, prompt: "Reply with OK.")
        return !res.isEmpty
    }

    // MARK: - Prompt data builders
    //
    // These assemble the *figures*; the wording lives in AiPrompts so it can be kept
    // identical to Android.

    private func buildDigestStats(trips: [TripEntity]) -> String {
        let totalDistance = trips.reduce(0) { $0 + $1.distanceKm }
        let totalEnergy = trips.reduce(0) { $0 + $1.energyUsedKwh }
        // kWh per 100 km: energy over distance. This was inverted, feeding the model
        // ~590 kWh/100km for trips averaging 17 — and the prompt prices that figure.
        let avgConsumption = totalDistance > 0 ? totalEnergy / totalDistance * 100 : 0
        let avgSpeed = trips.compactMap { avgSpeedValue(from: $0) }.reduce(0, +) / max(Float(trips.count), 1)
        let totalDurationMinutes = trips.compactMap { durationMinutes(from: $0) }.reduce(0, +)

        var statsLines = [
            "Trips: \(trips.count)",
            "Total distance: \(String(format: "%.1f", totalDistance)) km",
            "Total energy: \(String(format: "%.1f", totalEnergy)) kWh",
        ]
        if avgConsumption > 0 {
            statsLines.append("Average efficiency: \(String(format: "%.1f", avgConsumption)) kWh/100km")
        }
        if avgSpeed > 0 {
            statsLines.append("Average speed: \(String(format: "%.0f", avgSpeed)) km/h")
        }
        if totalDurationMinutes > 0 {
            let h = Int(totalDurationMinutes) / 60
            let m = Int(totalDurationMinutes) % 60
            statsLines.append("Total driving time: \(h > 0 ? "\(h)h " : "")\(m)m")
        }

        // Most efficient day — lowest average consumption.
        let dayGrouped = Dictionary(grouping: trips) { Calendar.current.startOfDay(for: $0.startTime) }
        let bestDay = dayGrouped.min { a, b in
            dayConsumption(a.value) < dayConsumption(b.value)
        }
        if let (day, dayTrips) = bestDay {
            let formatter = DateFormatter()
            formatter.setLocalizedDateFormatFromTemplate("EEEE")
            statsLines.append(
                "Most efficient day: \(formatter.string(from: day)) "
                    + "(\(String(format: "%.1f", dayConsumption(dayTrips))) kWh/100km)"
            )
        }

        if trips.count >= 3 {
            let sorted = trips.sorted { $0.startTime < $1.startTime }
            let mid = sorted.count / 2
            let firstAvg = dayConsumption(Array(sorted.prefix(mid)))
            let secondAvg = dayConsumption(Array(sorted.suffix(sorted.count - mid)))
            if firstAvg > 0, secondAvg > 0 {
                let trend = secondAvg < firstAvg ? "improving" : "declining"
                statsLines.append(
                    "Efficiency trend: \(trend) (from \(String(format: "%.1f", firstAvg)) "
                        + "to \(String(format: "%.1f", secondAvg)) kWh/100km)"
                )
            }
        }

        return statsLines.joined(separator: "\n")
    }

    private func dayConsumption(_ trips: [TripEntity]) -> Float {
        let values = trips.compactMap { $0.avgConsumptionKwhPer100km }
        guard !values.isEmpty else { return 0 }
        return values.reduce(0, +) / Float(values.count)
    }

    /// One row per session, matching the charging-insight rows so the digest and the
    /// charging card describe sessions the same way.
    private func buildChargeSessionsSummary(sessions: [ChargeSessionEntity]) -> String {
        guard !sessions.isEmpty else { return "" }
        var lines = ["Sessions: \(sessions.count)"]
        lines.append(contentsOf: sessions.prefix(10).map(sessionRow))
        return lines.joined(separator: "\n")
    }


    // MARK: - Prompt helpers
    
    private func buildTripJson(trip: TripEntity, samples: [SampleEntity]) -> String {
        var lines = [String]()
        lines.append("Distance: \(String(format: "%.1f", trip.distanceKm)) km")
        lines.append("Energy used: \(String(format: "%.1f", trip.energyUsedKwh)) kWh")
        if let consumption = trip.avgConsumptionKwhPer100km {
            lines.append("Avg consumption: \(String(format: "%.1f", consumption)) kWh/100km")
        }
        lines.append("Start SOC: \(String(format: "%.0f", trip.startSoc))%")
        if let endSoc = trip.endSoc {
            lines.append("End SOC: \(String(format: "%.0f", endSoc))%")
        }
        if !samples.isEmpty {
            let validTemps = samples.compactMap({ $0.ambientTempC }).filter({ $0 > -20 })
            if !validTemps.isEmpty {
                let avgTemp = validTemps.reduce(0, +) / Float(validTemps.count)
                lines.append("Ambient temp: \(String(format: "%.0f", avgTemp))°C")
            }
        }
        lines.append("Duration: \(durationString(from: trip))")
        return lines.joined(separator: "\n")
    }
    
    private func buildRecentTripsSummary(recentTrips: [TripEntity]) -> String {
        recentTrips
            .filter { $0.endTime != nil }
            .sorted { $0.startTime > $1.startTime }
            .prefix(10)
            .map { t in
                let endSoc = t.endSoc.map { "\(String(format: "%.0f", $0))" } ?? "?"
                return "Distance: \(String(format: "%.1f", t.distanceKm)) km, \(String(format: "%.1f", t.energyUsedKwh)) kWh, \(String(format: "%.0f", t.startSoc))% -> \(endSoc)% SOC"
            }
            .joined(separator: "\n")
    }
    
    private func durationString(from trip: TripEntity) -> String {
        guard let end = trip.endTime else { return "In progress" }
        let minutes = Int(end.timeIntervalSince(trip.startTime) / 60)
        return minutes >= 60 ? "\(minutes / 60)h \(minutes % 60)m" : "\(minutes)m"
    }

    private func avgSpeedString(from trip: TripEntity) -> String {
        guard let end = trip.endTime else { return "—" }
        let hours = end.timeIntervalSince(trip.startTime) / 3600
        guard hours > 0 else { return "—" }
        let speed = Double(trip.distanceKm) / hours
        return String(format: "%.0f km/h", speed)
    }

    private func avgSpeedValue(from trip: TripEntity) -> Float? {
        guard let end = trip.endTime else { return nil }
        let hours = end.timeIntervalSince(trip.startTime) / 3600
        guard hours > 0 else { return nil }
        return trip.distanceKm / Float(hours)
    }

    private func durationMinutes(from trip: TripEntity) -> Int? {
        guard let end = trip.endTime else { return nil }
        return Int(end.timeIntervalSince(trip.startTime) / 60)
    }

    /// Computes regen energy recovered from telemetry samples.
    private func computeRegen(from samples: [SampleEntity]) -> (regenKwh: Double?, totalDraw: Double?) {
        guard samples.count > 1 else { return (nil, nil) }
        var regenEnergy = 0.0
        var drawEnergy = 0.0
        for i in 1 ..< samples.count {
            guard let p1 = samples[i - 1].powerKw, let p2 = samples[i].powerKw else { continue }
            let dt = samples[i].timestamp.timeIntervalSince(samples[i - 1].timestamp) / 3600.0
            let avgPower = (Double(p1) + Double(p2)) / 2.0
            let energy = avgPower * dt
            if avgPower < 0 { // Discharge = negative power (driving)
                drawEnergy += abs(energy)
            } else if avgPower > 0 { // Regen = positive power
                regenEnergy += energy
            }
        }
        return (regenEnergy > 0 ? regenEnergy : nil, drawEnergy > 0 ? drawEnergy : nil)
    }

    // MARK: - Private

    /// Dispatches a prompt to the selected provider, using each API's own
    /// convention: DeepSeek takes the persona as a system message, Gemini gets the
    /// combined text. The model sees the same content either way.
    private func send(_ prompt: AiPrompt, provider: AiProvider, apiKey: String) async throws -> String {
        switch provider {
        case .gemini:
            return try await callGemini(prompt: prompt.combined, apiKey: apiKey)
        case .deepseek:
            return try await callDeepSeek(
                systemPrompt: prompt.persona, userMessage: prompt.body, apiKey: apiKey
            )
        }
    }

    /// Dispatches a bare prompt with no persona (key validation only).
    private func sendPrompt(provider: AiProvider, apiKey: String, prompt: String) async throws -> String {
        switch provider {
        case .gemini:
            return try await callGemini(prompt: prompt, apiKey: apiKey)
        case .deepseek:
            return try await callDeepSeek(systemPrompt: nil, userMessage: prompt, apiKey: apiKey)
        }
    }

    /// Calls the Gemini API (Google AI Studio).
    private func callGemini(prompt: String, apiKey: String) async throws -> String {
        guard let url = URL(string: "\(baseURLGemini)?key=\(apiKey)") else {
            throw AiError.invalidURL
        }

        let body: [String: Any] = [
            "contents": [
                ["parts": [["text": prompt]]]
            ],
            "generationConfig": [
                "temperature": 0.3,
                "maxOutputTokens": 1024,
                "topP": 0.95,
                "topK": 40
            ]
        ]

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw AiError.networkError("No response")
        }

        guard httpResponse.statusCode == 200 else {
            let body = String(data: data, encoding: .utf8) ?? "—"
            throw AiError.apiError(httpResponse.statusCode, body)
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let candidates = json["candidates"] as? [[String: Any]],
              let first = candidates.first,
              let content = first["content"] as? [String: Any],
              let parts = content["parts"] as? [[String: Any]],
              let text = parts.first?["text"] as? String else {
            throw AiError.decodingError
        }

        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Calls the DeepSeek API (OpenAI-compatible format).
    /// - Parameters:
    ///   - systemPrompt: Optional system message. When nil the prompt is sent as a user message.
    ///   - userMessage: The user's message content.
    ///   - apiKey: DeepSeek API key.
    /// - Returns: The model's response text.
    private func callDeepSeek(systemPrompt: String?, userMessage: String, apiKey: String) async throws -> String {
        guard let url = URL(string: baseURLDeepSeek) else {
            throw AiError.invalidURL
        }

        var messages: [[String: Any]] = []
        if let systemPrompt, !systemPrompt.isEmpty {
            messages.append(["role": "system", "content": systemPrompt])
        }
        messages.append(["role": "user", "content": userMessage])

        let body: [String: Any] = [
            "model": "\(deepseekModel)",
            "messages": messages,
            "max_tokens": 1024,
            "temperature": 0.3
        ]

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw AiError.networkError("No response")
        }

        guard httpResponse.statusCode == 200 else {
            let body = String(data: data, encoding: .utf8) ?? "—"
            throw AiError.apiError(httpResponse.statusCode, body)
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let first = choices.first,
              let message = first["message"] as? [String: Any],
              let text = message["content"] as? String else {
            throw AiError.decodingError
        }

        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A session row: everything the charging prompt asks about — including the date
    /// and pack temperature, without which "are there seasonal patterns?" is
    /// unanswerable.
    private func sessionRow(_ session: ChargeSessionEntity) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate]
        let endSoc = session.endSoc.map { String(format: "%.0f%%", $0) } ?? "—"
        let tempStr = session.packTempStartC.map { String(format: "%.0f°C", $0) } ?? "—"
        return "- \(formatter.string(from: session.startTime)): "
            + "\(String(format: "%.0f", session.startSoc))% → \(endSoc), "
            + "energy: \(String(format: "%.1f", session.energyAddedKwh)) kWh, "
            + "peak: \(String(format: "%.1f", session.peakPowerKw)) kW, "
            + "avg: \(String(format: "%.1f", session.avgPowerKw)) kW, "
            + "type: \(session.chargeType), "
            + "10-80% time: \(session.timeTo80Percent), "
            + "pack temp: \(tempStr)"
    }

    private func buildSessionRows(sessions: [ChargeSessionEntity]) -> String {
        sessions.map(sessionRow).joined(separator: "\n")
    }

    private func buildSohRows(_ history: [(Date, Double)]) -> String {
        guard !history.isEmpty else { return "" }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate]
        return history
            .map { "- \(formatter.string(from: $0.0)): \(String(format: "%.1f", $0.1))%" }
            .joined(separator: "\n")
    }

    private func buildVoltageDeltaLine(_ deltas: [Double]) -> String {
        guard !deltas.isEmpty else { return "" }
        let sorted = deltas.sorted()
        return "min=\(String(format: "%.1f", sorted.first ?? 0)), "
            + "max=\(String(format: "%.1f", sorted.last ?? 0)), "
            + "avg=\(String(format: "%.1f", sorted.reduce(0, +) / Double(sorted.count)))"
    }

    private func buildChargeSpeedRows(_ speeds: [(Date, Double)]) -> String {
        guard !speeds.isEmpty else { return "" }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate]
        return speeds
            .map { "- \(formatter.string(from: $0.0)): \(String(format: "%.0f", $0.1)) min" }
            .joined(separator: "\n")
    }
}

// MARK: - Errors

enum AiError: LocalizedError {
    case missingApiKey
    case emptyQuery
    case invalidURL
    case networkError(String)
    case apiError(Int, String)
    case decodingError

    var errorDescription: String? {
        switch self {
        case .missingApiKey:
            return "AI API key is not set. Add it in Settings."
        case .emptyQuery:
            return "Please enter a question."
        case .invalidURL:
            return "Could not build the request URL."
        case .networkError(let detail):
            return "Network error: \(detail)"
        case .apiError(let code, let body):
            return "API error (\(code)): \(body)"
        case .decodingError:
            return "Could not decode the response."
        }
    }
}

// MARK: - ChargeSessionEntity helpers

private extension ChargeSessionEntity {
    /// Estimated 10-80% charge time in minutes, approximated from session data.
    var timeTo80Percent: String {
        guard let endSoc, endSoc > startSoc else { return "—" }
        let socRange = endSoc - startSoc
        guard socRange > 0 else { return "—" }
        guard let endTime else { return "—" }
        let duration = endTime.timeIntervalSince(startTime) / 60.0
        guard duration > 0 else { return "—" }
        // Scale to the 10-80 band
        let speedPerPercent = duration / Double(socRange)
        let estimated = speedPerPercent * 70 // 70% = 10% → 80%
        return String(format: "%.0f min", estimated)
    }
}
