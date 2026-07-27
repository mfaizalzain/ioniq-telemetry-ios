import Combine
import CoreDomain
import CoreRouting
import Foundation

/// AI assistant chat backed by `GeminiRepository`, with live telemetry supplied
/// as context so answers can reference the actual car state.
@Observable
@MainActor
final class CopilotViewModel {

    struct Message: Identifiable, Equatable {
        enum Role { case user, assistant }
        let id = UUID()
        let role: Role
        let text: String
    }

    private(set) var messages: [Message] = []
    private(set) var isSending = false
    private(set) var errorMessage: String?
    var inputText = ""

    private let services: AppServices
    private var telemetry = VehicleTelemetry()
    private var vehicleName = "E-GMP"
    private var apiKey: String?
    private var cancellables = Set<AnyCancellable>()

    var canSend: Bool {
        !inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !isSending
            && !(apiKey ?? "").isEmpty
    }

    init(services: AppServices) {
        self.services = services

        services.telemetry.state
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.telemetry = $0 }
            .store(in: &cancellables)

        services.preferences.preferences
            .receive(on: DispatchQueue.main)
            .sink { [weak self] prefs in
                self?.apiKey = prefs.geminiApiKey
                self?.vehicleName = Ioniq5Constants.vehicleNameFor(prefs.activeProfileId)
            }
            .store(in: &cancellables)
    }

    // MARK: - Chat

    func send() async {
        let query = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }
        guard let apiKey, !apiKey.isEmpty else {
            errorMessage = "Add your API key in Settings to use the assistant."
            return
        }

        inputText = ""
        errorMessage = nil
        messages.append(Message(role: .user, text: query))
        isSending = true
        defer { isSending = false }

        let result = await services.gemini.askCopilot(
            userQuery: query,
            telemetryContext: telemetryContext,
            apiKey: apiKey
        )

        switch result {
        case .success(let answer):
            messages.append(Message(role: .assistant, text: answer))
        case .failure(let error):
            errorMessage = error.localizedDescription
        }
    }

    func clear() {
        messages.removeAll()
        errorMessage = nil
    }

    /// Compact snapshot of the car handed to the model as grounding. Omits absent
    /// signals rather than sending nulls, which the model tends to narrate.
    private var telemetryContext: String {
        var parts: [String] = ["Vehicle: \(vehicleName)"]

        if let soc = telemetry.socDisplay ?? telemetry.socBms {
            parts.append(String(format: "State of charge: %.0f%%", soc))
        }
        if let soh = telemetry.soh {
            parts.append(String(format: "Battery health: %.0f%%", soh))
        }
        if let power = telemetry.powerKw {
            parts.append(String(format: "Power: %.1f kW", power))
        }
        if let speed = telemetry.speedKph {
            parts.append(String(format: "Speed: %.0f km/h", speed))
        }
        if !telemetry.moduleTempsC.isEmpty {
            let avg = telemetry.moduleTempsC.reduce(0, +) / telemetry.moduleTempsC.count
            parts.append("Pack temperature: \(avg)°C")
        }
        if let delta = telemetry.cellVoltDelta {
            parts.append(String(format: "Cell delta: %.0f mV", delta * 1000))
        }
        if let aux = telemetry.auxVoltage {
            parts.append(String(format: "12V battery: %.1f V", aux))
        }
        if let ambient = telemetry.ambientTempC {
            parts.append("Ambient: \(ambient)°C")
        }
        if telemetry.isCharging {
            parts.append("Currently charging (\(telemetry.chargeType?.rawValue ?? "unknown") )")
        }
        if telemetry.connectionState != .connected {
            parts.append("Note: the adapter is not connected, so these values may be stale.")
        }

        return parts.joined(separator: "\n")
    }
}
