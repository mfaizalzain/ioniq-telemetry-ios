import CoreDomain
import Foundation

/// Gemini API repository implementation.
public final class GeminiRepositoryImpl: GeminiRepository, Sendable {
    private let session: URLSession
    private let candidateModels = ["gemini-flash-lite-latest"]

    public init() {
        self.session = NetworkSession.shared
    }

    // MARK: - Public API

    public func testApiKey(_ apiKey: String) async -> Result<String, Error> {
        let cleanKey = apiKey.trimmingCharacters(in: .whitespaces)
        guard !cleanKey.isEmpty else {
            return .failure(GeminiError.invalidApiKey("API Key cannot be blank"))
        }

        do {
            let response = try await callGeminiApi(apiKey: cleanKey, prompt: "Hello! Respond with OK.")
            if let error = response.error {
                throw GeminiError.apiError(error.message ?? "API error: \(error.status ?? "")")
            }
            guard let candidate = response.candidates?.first,
                  let content = candidate.content,
                  let text = content.parts.first?.text,
                  !text.trimmingCharacters(in: CharacterSet.whitespaces).isEmpty
            else {
                throw GeminiError.emptyResponse
            }
            return .success("Verified! Gemini API key is active.")
        } catch {
            return .failure(mapError(error))
        }
    }

    public func parseTripRequest(request: String, apiKey: String) async -> Result<ParsedTripRequest, Error> {
        let cleanKey = apiKey.trimmingCharacters(in: .whitespaces)
        do {
            let prompt = tripParseInstructions + "\n\nDriver message: \"\(request)\""
            let response = try await callGeminiApi(apiKey: cleanKey, prompt: prompt)
            let text = try extractText(from: response)
            let parsed = try parseTripJson(text)
            return .success(parsed)
        } catch {
            return .failure(error)
        }
    }

    public func parseTripRequestAudio(audioWavBase64: String, apiKey: String) async -> Result<ParsedTripRequest, Error> {
        let cleanKey = apiKey.trimmingCharacters(in: .whitespaces)
        do {
            let prompt = tripParseInstructions + "\n\nThe attached audio is the driver speaking the trip request. Transcribe it, then extract the fields."
            let parts: [GeminiPart] = [
                GeminiPart(text: prompt),
                GeminiPart(inlineData: GeminiInlineData(mimeType: "audio/wav", data: audioWavBase64))
            ]
            let response = try await callGeminiApi(apiKey: cleanKey, parts: parts)
            let text = try extractText(from: response)
            let parsed = try parseTripJson(text)
            return .success(parsed)
        } catch {
            return .failure(error)
        }
    }

    public func getDiagnosticExplanation(dtcCode: String, contextDescription: String, apiKey: String) async -> Result<String, Error> {
        let cleanKey = apiKey.trimmingCharacters(in: .whitespaces)
        do {
            let prompt = """
                You are a senior automotive diagnostic software consultant for electric vehicles.
                The vehicle decoded code: \(dtcCode)
                Context: \(contextDescription)

                Explain in 2 simple sentences what this means for the driver and what action (if any) should be taken.
                """
            let response = try await callGeminiApi(apiKey: cleanKey, prompt: prompt)
            let text = try extractText(from: response)
            return .success(text)
        } catch {
            return .failure(error)
        }
    }

    public func askCopilot(userQuery: String, telemetryContext: String, apiKey: String) async -> Result<String, Error> {
        let cleanKey = apiKey.trimmingCharacters(in: .whitespaces)
        do {
            let prompt = """
                You are Ioniq Copilot, a friendly AI copilot for a Hyundai Ioniq 5 driver.
                Live Vehicle Context:
                \(telemetryContext)

                Driver Query: "\(userQuery)"

                Answer in 2 concise, helpful sentences. Focus on driver safety and clear guidance.
                """
            let response = try await callGeminiApi(apiKey: cleanKey, prompt: prompt)
            let text = try extractText(from: response)
            return .success(text)
        } catch {
            return .failure(error)
        }
    }

    public func askCopilotAudio(audioWavBase64: String, telemetryContext: String, apiKey: String) async -> Result<String, Error> {
        let cleanKey = apiKey.trimmingCharacters(in: .whitespaces)
        do {
            let prompt = """
                You are Ioniq Copilot, a friendly AI copilot for a Hyundai Ioniq 5 driver.
                The attached audio is the driver speaking a question. Transcribe it and answer it.
                Live Vehicle Context:
                \(telemetryContext)

                Answer in 2 concise, helpful sentences meant to be read aloud to a driver.
                Focus on driver safety and clear guidance. Do not repeat the question back.
                """
            let parts: [GeminiPart] = [
                GeminiPart(text: prompt),
                GeminiPart(inlineData: GeminiInlineData(mimeType: "audio/wav", data: audioWavBase64))
            ]
            let response = try await callGeminiApi(apiKey: cleanKey, parts: parts)
            let text = try extractText(from: response)
            return .success(text)
        } catch {
            return .failure(error)
        }
    }

    public func planTrip(request: String, apiKey: String) async -> Result<TripPlan, Error> {
        // Placeholder — full implementation requires route planning integration.
        return .failure(GeminiError.apiError("planTrip not yet implemented on iOS"))
    }

    public func analyzeTrip(tripData: String, apiKey: String) async -> Result<String, Error> {
        let cleanKey = apiKey.trimmingCharacters(in: .whitespaces)
        do {
            let prompt = """
                You are Ioniq Copilot, an EV driving coach.
                Trip data:
                \(tripData)

                Give a brief 3-sentence analysis: energy efficiency, regen usage, and one tip for improvement.
                """
            let response = try await callGeminiApi(apiKey: cleanKey, prompt: prompt)
            let text = try extractText(from: response)
            return .success(text)
        } catch {
            return .failure(error)
        }
    }

    // MARK: - Gemini API Calls

    private func callGeminiApi(apiKey: String, prompt: String) async throws -> GeminiResponse {
        try await callGeminiApi(apiKey: apiKey, parts: [GeminiPart(text: prompt)])
    }

    private func callGeminiApi(apiKey: String, parts: [GeminiPart]) async throws -> GeminiResponse {
        let request = GeminiRequest(
            contents: [GeminiContent(parts: parts)]
        )

        var lastError: Error?
        for model in candidateModels {
            do {
                guard let url = URL(
                    string: "https://generativelanguage.googleapis.com/v1beta/models/\(model):generateContent"
                ) else {
                    throw GeminiError.apiError("Could not build a request URL for model \(model).")
                }
                var urlRequest = URLRequest(url: url)
                urlRequest.httpMethod = "POST"
                urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
                // Header rather than a `?key=` query parameter: URLs reach system
                // diagnostics, crash reports and any proxy on the path, and this is a
                // credential billed to the user. Matches how the Places calls in
                // GeocodingRepository and OccupancyRepository already authenticate.
                urlRequest.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
                urlRequest.httpBody = try JSONEncoder().encode(request)

                let (data, response) = try await session.dataWithRetry(for: urlRequest)
                let httpResponse = response as? HTTPURLResponse

                if httpResponse?.statusCode == 404 {
                    lastError = GeminiError.httpError(404, "Model not found")
                    continue
                }

                if httpResponse?.statusCode == 400 {
                    let body = String(data: data, encoding: .utf8) ?? ""
                    throw GeminiError.httpError(400, body)
                }

                if httpResponse?.statusCode == 403 {
                    throw GeminiError.httpError(403, "Forbidden: Enable Generative Language API")
                }

                let geminiResponse = try JSONDecoder().decode(GeminiResponse.self, from: data)

                if let candidate = geminiResponse.candidates?.first,
                   let content = candidate.content,
                   content.parts.first?.text != nil {
                    return geminiResponse
                }
                lastError = GeminiError.emptyResponse
            } catch let error as GeminiError {
                throw error
            } catch {
                lastError = error
            }
        }

        throw lastError ?? GeminiError.emptyResponse
    }

    // MARK: - Helpers

    private func extractText(from response: GeminiResponse) throws -> String {
        if let error = response.error {
            throw GeminiError.apiError(error.message ?? "API error")
        }
        guard let candidate = response.candidates?.first,
              let content = candidate.content,
              let text = content.parts.first?.text,
              !text.trimmingCharacters(in: CharacterSet.whitespaces).isEmpty
        else {
            throw GeminiError.emptyResponse
        }
        return text
    }

    private func mapError(_ error: Error) -> Error {
        if let geminiError = error as? GeminiError { return geminiError }
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain {
            return GeminiError.networkError(error.localizedDescription)
        }
        return GeminiError.unknown(error.localizedDescription)
    }

    // MARK: - JSON Parsing

    /// Tolerant JSON extraction: strips ``` fences and any prose around the object.
    private func parseTripJson(_ raw: String) throws -> ParsedTripRequest {
        guard let start = raw.firstIndex(of: "{"),
              let end = raw.lastIndex(of: "}"),
              start < end
        else {
            throw GeminiError.parseError("Model did not return a trip object.")
        }

        let jsonStr = String(raw[start...end])
        guard let data = jsonStr.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            throw GeminiError.parseError("Invalid JSON in response")
        }

        func strOrNil(_ key: String) -> String? {
            guard let val = json[key] as? String, !val.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
            return val.trimmingCharacters(in: .whitespaces)
        }

        let waypoints: [String] = {
            guard let arr = json["waypoints"] as? [String] else { return [] }
            return arr.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        }()

        var arrivalSoc: Float?
        if let socVal = json["arrivalSocPercent"] as? Double, !socVal.isNaN {
            arrivalSoc = Float(socVal).clamped(to: 0...100)
        } else if let socVal = json["arrivalSocPercent"] as? Float, !socVal.isNaN {
            arrivalSoc = socVal.clamped(to: 0...100)
        }

        return ParsedTripRequest(
            origin: strOrNil("origin"),
            destination: strOrNil("destination"),
            waypoints: waypoints,
            arrivalSocPercent: arrivalSoc
        )
    }

    // MARK: - Constants

    private var tripParseInstructions: String {
        """
        You extract structured trip intent for an EV route planner.
        Identify the starting point, the final destination, any intermediate
        stops, and the desired arrival battery percentage.

        Respond with ONLY a minified JSON object, no markdown, no prose:
        {"origin": string|null, "destination": string|null, "waypoints": [string], "arrivalSocPercent": number|null}

        Rules:
        - Use place names exactly as a map search would understand them (city, landmark, or address). Do not invent coordinates.
        - origin is null if no starting point is stated (means "current location").
        - waypoints is an ordered list of intermediate stops; [] if none.
        - arrivalSocPercent is the number to arrive with (0-100), or null if unspecified.
        """
    }
}

// MARK: - Gemini API Models

private struct GeminiRequest: Codable {
    let contents: [GeminiContent]
}

private struct GeminiContent: Codable {
    let parts: [GeminiPart]
}

private struct GeminiPart: Codable {
    let text: String?
    let inlineData: GeminiInlineData?

    init(text: String) {
        self.text = text
        self.inlineData = nil
    }

    init(inlineData: GeminiInlineData) {
        self.text = nil
        self.inlineData = inlineData
    }
}

private struct GeminiInlineData: Codable {
    let mimeType: String
    let data: String
}

private struct GeminiResponse: Codable {
    let candidates: [GeminiCandidate]?
    let error: GeminiErrorBody?
}

private struct GeminiCandidate: Codable {
    let content: GeminiContent?
}

private struct GeminiErrorBody: Codable {
    let message: String?
    let status: String?
}

// MARK: - Error Types

public enum GeminiError: Error, LocalizedError {
    case invalidApiKey(String)
    case emptyResponse
    case apiError(String)
    case httpError(Int, String)
    case networkError(String)
    case parseError(String)
    case unknown(String)

    public var errorDescription: String? {
        switch self {
        case .invalidApiKey(let msg): return msg
        case .emptyResponse: return "Empty response from Gemini API."
        case .apiError(let msg): return msg
        case .httpError(let code, let msg): return "HTTP \(code): \(msg)"
        case .networkError(let msg): return msg
        case .parseError(let msg): return msg
        case .unknown(let msg): return msg
        }
    }
}

// MARK: - Float Clamping

private extension Float {
    func clamped(to range: ClosedRange<Float>) -> Float {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}
