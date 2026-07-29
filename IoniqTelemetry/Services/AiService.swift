import CoreData
import CoreDomain
import Foundation

/// AI-powered service for charging insights, battery health reports, and
/// contextual aiAssistant chat. Supports Gemini (via Google AI) and DeepSeek
/// (OpenAI-compatible API). All methods require a valid API key for the selected
/// provider and Pro entitlement (gated at the call site).
@Observable
@MainActor
final class AiService {

    private let session: URLSession
    private let baseURLGemini = "https://generativelanguage.googleapis.com/v1beta/models/gemini-flash-lite-latest:generateContent"
    private let baseURLDeepSeek = "https://api.deepseek.com/v1/chat/completions"

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
        apiKey: String,
        aiProvider: AiProvider = .gemini,
        countryCode: String? = nil
    ) async throws -> String {
        guard !apiKey.isEmpty else { throw AiError.missingApiKey }

        let prompt = buildPostTripBriefingPrompt(
            trip: trip,
            recentTrips: recentTrips,
            telemetrySamples: telemetrySamples,
            efficiencyBaseline: efficiencyBaseline
        )
        return try await sendPrompt(provider: aiProvider, apiKey: apiKey, prompt: prompt)
    }

    // MARK: - AI Digest

    /// Generates a weekly or monthly digest of driving activity.
    /// - Parameters:
    ///   - trips: Trips in the period.
    ///   - period: Weekly or monthly.
    ///   - apiKey: API key for the selected provider.
    ///   - aiProvider: The AI provider to use (Gemini or DeepSeek).
    /// - Returns: AI-generated digest text.
    func generateDigest(
        trips: [TripEntity],
        period: DigestPeriod,
        apiKey: String,
        aiProvider: AiProvider = .gemini
    ) async throws -> String {
        guard !apiKey.isEmpty else { throw AiError.missingApiKey }
        guard !trips.isEmpty else { return "No trips recorded this \\(period.label.lowercased())." }

        let prompt = buildDigestPrompt(trips: trips, period: period)
        return try await sendPrompt(provider: aiProvider, apiKey: apiKey, prompt: prompt)
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
        let prompt = buildChargingPrompt(sessions: recent)
        return try await sendPrompt(provider: aiProvider, apiKey: apiKey, prompt: prompt)
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

        let prompt = buildBatteryReportPrompt(
            sohHistory: sohHistory,
            voltageDeltas: voltageDeltas,
            chargeSpeeds: chargeSpeeds
        )
        return try await sendPrompt(provider: aiProvider, apiKey: apiKey, prompt: prompt)
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

        let prompt = """
            You are an expert automotive AI aiAssistant for an electric vehicle.

            VEHICLE CONTEXT:
            \(telemetryContext)

            USER QUERY:
            \(query)

            Provide a clear, concise answer based on the context above.
            """
        return try await sendPrompt(provider: aiProvider, apiKey: apiKey, prompt: prompt)
    }

    // MARK: - Validation

    /// Validates an API key by sending a lightweight query to the specified provider.
    func validateApiKey(_ apiKey: String, provider: AiProvider) async throws -> Bool {
        guard !apiKey.isEmpty else { throw AiError.missingApiKey }
        let res = try await sendPrompt(provider: provider, apiKey: apiKey, prompt: "Reply with OK.")
        return !res.isEmpty
    }

    // MARK: - Post-Trip Briefing Prompt

    private func buildPostTripBriefingPrompt(
        trip: TripEntity,
        recentTrips: [TripEntity],
        telemetrySamples: [SampleEntity],
        efficiencyBaseline: Double?
    ) -> String {
        var lines = [
            "You are an AI driving assistant for an E-GMP electric vehicle.",
            "Generate a very concise post-trip briefing in 3-4 sentences.",
            "Be specific with numbers and compare to the driver's baseline where available.",
            "Do NOT use markdown or bullet points — write natural plain text.",
            "",
            "TRIP SUMMARY:",
            "- Distance: \(String(format: "%.1f", trip.distanceKm)) km",
            "- Duration: \(durationString(from: trip))",
            "- Energy used: \(String(format: "%.1f", trip.energyUsedKwh)) kWh",
            "- Average speed: \(avgSpeedString(from: trip))",
            "- Start SOC: \(String(format: "%.0f", trip.startSoc))%",
            "- End SOC: \(String(format: "%.0f", trip.endSoc ?? 0))%",
        ]

        // Efficiency
        if let consumption = trip.avgConsumptionKwhPer100km {
            lines.append("- Efficiency: \(String(format: "%.1f", consumption)) kWh/100km")
            if let baseline = efficiencyBaseline, baseline > 0 {
                let diff = consumption - Float(baseline)
                if abs(diff) > 0.5 {
                    let sign = diff > 0 ? "worse" : "better"
                    lines.append("- Baseline: \(String(format: "%.1f", baseline)) kWh/100km (\(sign) by \(String(format: "%.1f", abs(diff))))")
                }
            }
        }

        // Regen from samples
        let regen = computeRegen(from: telemetrySamples)
        if let regenKwh = regen.regenKwh, regenKwh > 0.1, let totalDraw = regen.totalDraw, totalDraw > 0 {
            let share = (regenKwh / totalDraw) * 100
            lines.append("- Energy recovered: \(String(format: "%.1f", regenKwh)) kWh (\(String(format: "%.0f", share))%)")
        }

        // Cost estimation — Gemini handles with local rates

        lines.append("")
        lines.append("Write a friendly, informative 3-4 sentence summary. Start with a greeting. Mention the most notable aspect of the trip.")

        return lines.joined(separator: "\n")
    }

    // MARK: - Digest Prompt

    private func buildDigestPrompt(trips: [TripEntity], period: DigestPeriod) -> String {
        let totalDistance = trips.reduce(0) { $0 + $1.distanceKm }
        let totalEnergy = trips.reduce(0) { $0 + $1.energyUsedKwh }
        let avgConsumption = totalEnergy > 0 ? totalDistance / totalEnergy * 100 : 0
        let tripCount = trips.count
        let avgSpeed = trips.compactMap { avgSpeedValue(from: $0) }.reduce(0, +) / max(Float(trips.count), 1)
        let totalDurationMinutes = trips.compactMap { durationMinutes(from: $0) }.reduce(0, +)

        // Best efficiency day
        let dayGrouped = Dictionary(grouping: trips) { Calendar.current.startOfDay(for: $0.startTime) }
        let bestDay = dayGrouped.max { a, b in
            let aConsumption = a.value.compactMap { $0.avgConsumptionKwhPer100km }.reduce(0, +) / max(Float(a.value.count), 1)
            let bConsumption = b.value.compactMap { $0.avgConsumptionKwhPer100km }.reduce(0, +) / max(Float(b.value.count), 1)
            return aConsumption > bConsumption
        }

        var lines = [
            "You are an AI driving assistant for an E-GMP electric vehicle.",
            "Write a \(period.label.lowercased()) driving digest in 2-3 sentences.",
            "Be friendly and encouraging. Use natural plain text without markdown.",
            "",
            "\(period.label) SUMMARY (\(tripCount) trips):",
            "- Total distance: \(String(format: "%.0f", totalDistance)) km",
            "- Total energy: \(String(format: "%.1f", totalEnergy)) kWh",
            "- Average efficiency: \(String(format: "%.1f", avgConsumption)) kWh/100km",
            "- Average speed: \(String(format: "%.0f", avgSpeed)) km/h",
            "- Total driving time: \(totalDurationMinutes >= 60 ? "\(Int(totalDurationMinutes) / 60)h \(Int(totalDurationMinutes) % 60)m" : "\(Int(totalDurationMinutes))m")",
        ]

        // Cost saved vs petrol
        let costPerKwh = 0.12
        let totalCost = Double(totalEnergy) * costPerKwh
        let petrolCost = Double(totalDistance) / 100.0 * 8.0 * 1.50
        let saved = petrolCost - totalCost
        if saved > 0 {
            lines.append("- Cost saved vs petrol: $\(String(format: "%.2f", saved))")
        }

        // Best day
        if let (day, dayTrips) = bestDay {
            let dayConsumption = dayTrips.compactMap { $0.avgConsumptionKwhPer100km }.reduce(0, +) / max(Float(dayTrips.count), 1)
            let formatter = DateFormatter()
            formatter.setLocalizedDateFormatFromTemplate("EEEE")
            lines.append("- Best efficiency day: \(formatter.string(from: day)) (\(String(format: "%.1f", dayConsumption)) kWh/100km)")
        }

        // Efficiency trend
        if trips.count >= 3 {
            let sorted = trips.sorted { $0.startTime < $1.startTime }
            let firstHalf = sorted.prefix(sorted.count / 2)
            let secondHalf = sorted.suffix(sorted.count / 2)
            let firstAvg = firstHalf.compactMap { $0.avgConsumptionKwhPer100km }.reduce(0, +) / max(Float(firstHalf.count), 1)
            let secondAvg = secondHalf.compactMap { $0.avgConsumptionKwhPer100km }.reduce(0, +) / max(Float(secondHalf.count), 1)
            if firstAvg > 0, secondAvg > 0 {
                let trend = secondAvg < firstAvg ? "improving" : "declining"
                lines.append("- Efficiency trend: \(trend) (from \(String(format: "%.1f", firstAvg)) to \(String(format: "%.1f", secondAvg)) kWh/100km)")
            }
        }

        lines.append("")
        lines.append("Write 2-3 concise, encouraging sentences.")

        return lines.joined(separator: "\n")
    }

    // MARK: - Prompt helpers

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

    /// Dispatches the prompt to the selected AI provider.
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
            "model": "deepseek-chat",
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

    private func buildChargingPrompt(sessions: [ChargeSessionEntity]) -> String {
        var lines = [
            "Analyse the following \(sessions.count) charging sessions for an E-GMP electric vehicle.",
            "Identify trends such as charging speed degradation, seasonal warming effects, or changes in peak power.",
            "",
            "Session Data:",
        ]

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate]

        for session in sessions {
            let date = formatter.string(from: session.startTime)
            let endSoc = session.endSoc.map { String(format: "%.0f%%", $0) } ?? "—"
            let timeTo80 = session.timeTo80Percent
            let tempStr = session.packTempStartC.map { String(format: "%.0f°C", $0) } ?? "—"
            lines.append("- \(date): \(String(format: "%.0f", session.startSoc))% → \(endSoc), " +
                "energy: \(String(format: "%.1f", session.energyAddedKwh)) kWh, " +
                "peak: \(String(format: "%.1f", session.peakPowerKw)) kW, " +
                "avg: \(String(format: "%.1f", session.avgPowerKw)) kW, " +
                "type: \(session.chargeType), " +
                "10-80% time: \(timeTo80), " +
                "pack temp: \(tempStr)")
        }

        lines.append("")
        lines.append("Summarise: Is charging speed degrading? Are there seasonal patterns? Any anomalies to flag?")
        lines.append("Keep the response concise and focused on actionable insights for the driver.")

        return lines.joined(separator: "\n")
    }

    private func buildBatteryReportPrompt(
        sohHistory: [(Date, Double)],
        voltageDeltas: [Double],
        chargeSpeeds: [(Date, Double)]
    ) -> String {
        var lines = [
            "Generate a battery health report for an E-GMP electric vehicle.",
            "",
        ]

        // SOH history
        if !sohHistory.isEmpty {
            lines.append("SOH (State of Health) over time:")
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withFullDate]
            for (date, soh) in sohHistory {
                lines.append("- \(formatter.string(from: date)): \(String(format: "%.1f", soh))%")
            }
        }

        // Voltage deltas
        if !voltageDeltas.isEmpty {
            let sorted = voltageDeltas.sorted()
            lines.append("")
            lines.append("Cell voltage deltas (mV): min=\(String(format: "%.1f", sorted.first ?? 0)), " +
                "max=\(String(format: "%.1f", sorted.last ?? 0)), " +
                "avg=\(String(format: "%.1f", sorted.reduce(0, +) / Double(sorted.count)))")
        }

        // Charge speeds
        if !chargeSpeeds.isEmpty {
            lines.append("")
            lines.append("10-80% charge times over time:")
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withFullDate]
            for (date, minutes) in chargeSpeeds {
                lines.append("- \(formatter.string(from: date)): \(String(format: "%.0f", minutes)) min")
            }
        }

        lines.append("")
        lines.append("Rate the overall battery health and highlight any degradation concerns or recommendations.")
        lines.append("Keep the response clear and actionable.")

        return lines.joined(separator: "\n")
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
