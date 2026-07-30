import CoreDomain
import SwiftUI

/// AI AiAssistant chat view that prepends current vehicle telemetry context to
/// every user query, providing informed responses about battery, driving
/// efficiency, charging and vehicle health.
struct AiAssistantChatView: View {
    @Environment(AppServices.self) private var services
    let viewModel: DashboardViewModel

    @State private var messages: [AiAssistantMessage] = []
    @State private var inputText = ""
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var showPaywall = false

    private let aiService = AiService()

    private var canUseAi: Bool {
        services.isPro && services.userPreferences.aiFeaturesEnabled && !(services.userPreferences.aiKey ?? "").isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
                // Header
                HStack(spacing: 8) {
                    Image(systemName: "sparkles")
                        .foregroundStyle(Color.appAccent)
                    Text("AI Copilot")
                        .font(.subheadline.weight(.semibold))
                    Text(services.userPreferences.aiProvider.label.uppercased())
                        .font(.caption2.weight(.bold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.appAccent.opacity(0.15), in: Capsule())
                        .foregroundStyle(Color.appAccent)
                    Spacer()
                    if !messages.isEmpty {
                        Button("Clear") {
                            messages.removeAll()
                            errorMessage = nil
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }
                .foregroundStyle(Color.appOnSurface)
                .padding(.horizontal, 14)
                .padding(.top, 14)

                if !canUseAi {
                    // Pro + Key required state
                    VStack(spacing: 8) {
                        Image(systemName: "sparkles")
                            .font(.title2)
                            .foregroundStyle(Color.appAccent)
                        Text("AI AiAssistant with Vehicle Context")
                            .font(.subheadline.weight(.medium))
                        Text("Ask questions about your battery, efficiency, and driving patterns. Available with Pro and an API key.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity)
                } else if messages.isEmpty {
                    // Empty state with suggestions
                    VStack(spacing: 8) {
                        Image(systemName: "sparkles")
                            .font(.title2)
                            .foregroundStyle(Color.appAccent.opacity(0.6))
                        Text("Ask me anything about your vehicle")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 6) {
                            suggestionButton("What's my current battery health?")
                            suggestionButton("How can I improve my efficiency?")
                            suggestionButton("Are my charging patterns optimal?")
                        }
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity)
                } else {
                    // Messages
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(spacing: 10) {
                                ForEach(messages) { message in
                                    MessageBubble(message: message)
                                }
                                if isLoading {
                                    HStack(spacing: 6) {
                                        ProgressView()
                                            .scaleEffect(0.7)
                                        Text("Thinking…")
                                            .font(.caption)
                                            .foregroundStyle(.tertiary)
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, 14)
                                }
                                if let errorMessage {
                                    Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                                        .font(.caption)
                                        .foregroundStyle(Color.appAmber)
                                        .padding(.horizontal, 14)
                                }
                            }
                            .padding(.vertical, 8)
                        }
                        .frame(maxHeight: 250)
                        .onChange(of: messages.count) { _, _ in
                            if let last = messages.last {
                                withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                            }
                        }
                    }
                }

                // Input bar
                Divider()

                HStack(spacing: 8) {
                    TextField("Ask about your vehicle…", text: $inputText)
                        .textFieldStyle(.plain)
                        .font(.subheadline)
                        .padding(10)
                        .background(Color.appSurfaceVariant, in: RoundedRectangle(cornerRadius: 8))
                        .disabled(!canUseAi || isLoading)

                    Button {
                        Task { await sendMessage() }
                    } label: {
                        if isLoading {
                            ProgressView()
                                .scaleEffect(0.8)
                        } else {
                            Image(systemName: "arrow.up.circle.fill")
                                .font(.title2)
                        }
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(canUseAi && !inputText.trimmingCharacters(in: .whitespaces).isEmpty
                        ? Color.appAccent : Color.appOnSurface.opacity(0.3))
                    .disabled(!canUseAi || isLoading || inputText.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                .padding(10)
            }
            .padding(.horizontal)
            .background(Color.appSurface)
            .clipShape(RoundedRectangle(cornerRadius: .cornerMedium))
        .sheet(isPresented: $showPaywall) {
            PaywallView()
        }
    }

    // MARK: - Suggestion

    private func suggestionButton(_ text: String) -> some View {
        Button {
            inputText = text
            Task { await sendMessage() }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "message.badge")
                    .font(.caption2)
                Text(text)
                    .font(.caption)
            }
            .foregroundStyle(Color.appAccent)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color.appAccent.opacity(0.1), in: Capsule())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Send

    private func sendMessage() async {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let apiKey = services.userPreferences.aiKey, !apiKey.isEmpty else { return }

        inputText = ""
        errorMessage = nil

        let userMessage = AiAssistantMessage(role: .user, text: text)
        messages.append(userMessage)

        isLoading = true

        // Build vehicle context from current telemetry
        let telemetry = viewModel.telemetry
        let soh = telemetry.soh.map { String(format: "%.0f%%", $0) } ?? "—"
        let soc = viewModel.socPercent.map { String(format: "%.0f%%", $0) } ?? "—"
        let packTemp = viewModel.packTempC.map { "\($0)°C" } ?? "—"
        let power = telemetry.powerKw.map { String(format: "%.1f kW", $0) } ?? "—"
        let voltage = telemetry.packVoltage.map { String(format: "%.0f V", $0) } ?? "—"
        let cellDelta = telemetry.cellVoltDelta.map { String(format: "%.0f mV", $0 * 1000) } ?? "—"
        let odometer = telemetry.odometerKm.map { "\($0) km" } ?? "—"
        let charging = telemetry.isCharging
        let chargeType = telemetry.chargeType?.rawValue ?? "—"
        let ambientTemp = telemetry.ambientTempC.map { "\($0)°C" } ?? "—"
        let auxVoltage = telemetry.auxVoltage.map { String(format: "%.1f V", $0) } ?? "—"

        let context = """
            Vehicle: E-GMP (Hyundai IONIQ/Kia EV6/Genesis GV60)
            State of Charge (SOC): \(soc)
            State of Health (SOH): \(soh)
            Battery Pack Temperature: \(packTemp)
            Power: \(power)
            HV Voltage: \(voltage)
            Cell Voltage Delta: \(cellDelta)
            Odometer: \(odometer)
            Is Charging: \(charging)
            Charge Type: \(chargeType)
            Ambient Temperature: \(ambientTemp)
            12V Aux Voltage: \(auxVoltage)
            """

        do {
            let response = try await aiService.askCopilotWithContext(
                query: text,
                telemetryContext: context,
                apiKey: apiKey,
                aiProvider: services.userPreferences.aiProvider
            )
            let assistantMessage = AiAssistantMessage(role: .assistant, text: response)
            messages.append(assistantMessage)
        } catch {
            errorMessage = error.localizedDescription
        }

        isLoading = false
    }
}

// MARK: - Message Bubble

private struct MessageBubble: View {
    let message: AiAssistantMessage

    var body: some View {
        HStack {
            if message.role == .user {
                Spacer(minLength: 40)
            }

            Text(message.text)
                .font(.subheadline)
                .foregroundStyle(message.role == .user ? Color.appOnAccent : .primary)
                .padding(10)
                .background(
                    message.role == .user
                        ? Color.appAccent
                        : Color.appSurfaceVariant,
                    in: RoundedRectangle(cornerRadius: 12)
                )

            if message.role == .assistant {
                Spacer(minLength: 40)
            }
        }
        .padding(.horizontal, 14)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Model

/// A single message in the AI assistant chat.
private struct AiAssistantMessage: Identifiable {
    let id = UUID()
    let role: MessageRole
    let text: String
}

private enum MessageRole {
    case user
    case assistant
}
