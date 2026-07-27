import Foundation

public protocol GeminiRepository: Sendable {
    /// Test a Gemini API key for validity.
    func testApiKey(_ apiKey: String) async -> Result<String, Error>

    /// Extracts a structured [ParsedTripRequest] from a free-form trip description
    /// (e.g. "drive from KL to Penang, stop in Ipoh, arrive with at least 30%").
    /// Only parses intent — it does not plan the route or choose chargers.
    func parseTripRequest(
        request: String,
        apiKey: String
    ) async -> Result<ParsedTripRequest, Error>

    /// Voice variant of [parseTripRequest]: [audioWavBase64] is a base64 16 kHz
    /// mono PCM WAV clip of the driver speaking a trip request. Gemini transcribes
    /// and extracts the structured intent in a single call.
    func parseTripRequestAudio(
        audioWavBase64: String,
        apiKey: String
    ) async -> Result<ParsedTripRequest, Error>

    /// Get a plain-language diagnostic explanation for a DTC code.
    func getDiagnosticExplanation(
        dtcCode: String,
        contextDescription: String,
        apiKey: String
    ) async -> Result<String, Error>

    /// Ask the AI copilot a question with telemetry context.
    func askCopilot(
        userQuery: String,
        telemetryContext: String,
        apiKey: String
    ) async -> Result<String, Error>

    /// Voice query: [audioWavBase64] is a base64-encoded 16 kHz mono PCM WAV clip
    /// of the driver speaking. Gemini transcribes and answers in one call.
    func askCopilotAudio(
        audioWavBase64: String,
        telemetryContext: String,
        apiKey: String
    ) async -> Result<String, Error>

    /// Plan a trip using AI assistance.
    func planTrip(
        request: String,
        apiKey: String
    ) async -> Result<TripPlan, Error>

    /// Analyze a completed trip using AI.
    func analyzeTrip(
        tripData: String,
        apiKey: String
    ) async -> Result<String, Error>
}
