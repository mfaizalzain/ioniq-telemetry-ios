import SwiftUI
import CoreUI

struct CopilotView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var inputText = ""
    @State private var messages: [CopilotMessage] = [
        CopilotMessage(role: .assistant, text: "Hi! I'm your AI Assistant. Ask me about trip planning, battery health, or nearby chargers.")
    ]
    @State private var isListening = false

    struct CopilotMessage: Identifiable {
        let id = UUID()
        var role: Role
        var text: String
        var timestamp: Date = Date()
        enum Role { case user, assistant }
    }

    var body: some View {
        NavigationStack {
            VStack {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 12) {
                            ForEach(messages) { message in
                                ChatBubble(message: message)
                                    .id(message.id)
                            }
                        }
                        .padding()
                    }
                    .onChange(of: messages.count) {
                        if let last = messages.last { proxy.scrollTo(last.id, anchor: .bottom) }
                    }
                }

                // Input
                HStack {
                    TextField("Ask AI Assistant...", text: $inputText)
                        .textFieldStyle(.roundedBorder)

                    Button {
                        send()
                    } label: {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.title2)
                            .foregroundStyle(Color(red: 0.09, green: 0.91, blue: 0.76))
                    }
                    .disabled(inputText.isEmpty)

                    Button {
                        isListening.toggle()
                    } label: {
                        Image(systemName: isListening ? "mic.fill" : "mic")
                            .font(.title2)
                            .foregroundStyle(isListening ? Color(red: 0.94, green: 0.33, blue: 0.31) : .secondary)
                    }
                }
                .padding()
            }
            .background(Color(red: 0.043, green: 0.071, blue: 0.125))
            .navigationTitle("AI Assistant")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    func send() {
        guard !inputText.isEmpty else { return }
        messages.append(CopilotMessage(role: .user, text: inputText))
        let query = inputText
        inputText = ""

        // Simulate AI response
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            let response = generateResponse(for: query)
            messages.append(CopilotMessage(role: .assistant, text: response))
        }
    }

    func generateResponse(for query: String) -> String {
        if query.lowercased().contains("charger") || query.lowercased().contains("charging") {
            return "I found 3 nearby charging stations:\n\n1. **Shell Recharge KL East** — 150 kW, 2/4 available, £0.45/kWh\n2. **ChargEV Pavilion** — 50 kW, 1/2 available, RM1.20/kWh\n3. **Petronas Solaris** — 180 kW, 3/3 available, RM1.50/kWh\n\nWould you like me to navigate to one of these?"
        }
        if query.lowercased().contains("trip") || query.lowercased().contains("plan") || query.lowercased().contains("navigate") {
            return "I can help plan your trip! Where would you like to go? Tell me the destination and I'll find the best charging stops along the way."
        }
        return "Your battery is at 78%, cell delta is a healthy 18 mV, and pack temperature is optimal at 31°C. Range is estimated at 312 km. Is there anything specific you'd like to know?"
    }
}

struct ChatBubble: View {
    var message: CopilotView.CopilotMessage

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            if message.role == .assistant {
                Image(systemName: "sparkles")
                    .font(.caption)
                    .foregroundStyle(Color(red: 0.09, green: 0.91, blue: 0.76))
                    .padding(6)
                    .background(.quaternary)
                    .clipShape(Circle())
            } else {
                Spacer()
            }
            Text(message.text)
                .font(.body)
                .padding(12)
                .background(message.role == .user ? Color(red: 0.09, green: 0.91, blue: 0.76).opacity(0.2) : .quaternary)
                .clipShape(RoundedRectangle(cornerRadius: 12))
            if message.role == .user {
                Spacer()
            }
        }
    }
}
