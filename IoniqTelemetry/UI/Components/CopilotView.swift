import CoreUI
import SwiftUI

struct CopilotView: View {
    @Environment(AppServices.self) private var services
    @Environment(\.dismiss) private var dismiss
    @State private var viewModel: CopilotViewModel?

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if let viewModel {
                    transcript(viewModel)
                    Divider()
                    Composer(viewModel: viewModel)
                } else {
                    ProgressView()
                        .frame(maxHeight: .infinity)
                }
            }
            .background(Color.deepNavy)
            .navigationTitle("AI Assistant")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Clear") { viewModel?.clear() }
                        .disabled(viewModel?.messages.isEmpty ?? true)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .task {
            if viewModel == nil { viewModel = CopilotViewModel(services: services) }
        }
    }

    private func transcript(_ viewModel: CopilotViewModel) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if viewModel.messages.isEmpty {
                        SuggestionsView(viewModel: viewModel)
                    }
                    ForEach(viewModel.messages) { message in
                        ChatBubble(message: message)
                            .id(message.id)
                    }
                    if viewModel.isSending {
                        TypingIndicator()
                    }
                    if let error = viewModel.errorMessage {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(Color.redAlert)
                            .padding(.horizontal)
                    }
                }
                .padding()
            }
            .onChange(of: viewModel.messages.count) {
                withAnimation { proxy.scrollTo(viewModel.messages.last?.id, anchor: .bottom) }
            }
        }
    }
}

// MARK: - Bubble

private struct ChatBubble: View {
    let message: CopilotViewModel.Message

    private var isUser: Bool { message.role == .user }

    var body: some View {
        HStack {
            if isUser { Spacer(minLength: 40) }
            Text(message.text)
                .font(.body)
                .foregroundStyle(isUser ? Color.deepNavy : Color.onSurface)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(
                    isUser ? Color.electricTeal : Color.surfaceVariant,
                    in: RoundedRectangle(cornerRadius: 16)
                )
                .textSelection(.enabled)
            if !isUser { Spacer(minLength: 40) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(isUser ? "You said" : "Assistant said")
        .accessibilityValue(message.text)
    }
}

private struct TypingIndicator: View {
    @State private var phase = 0.0

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .fill(Color.onSurfaceVariant)
                    .frame(width: 6, height: 6)
                    .opacity(phase == Double(index) ? 1 : 0.35)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(Color.surfaceVariant, in: RoundedRectangle(cornerRadius: 16))
        .task {
            // Plain timer rather than repeatForever: the view is torn down when the
            // reply lands, and a detached animation would outlive it.
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(350))
                phase = (phase + 1).truncatingRemainder(dividingBy: 3)
            }
        }
        .accessibilityLabel("Assistant is typing")
    }
}

// MARK: - Suggestions

private struct SuggestionsView: View {
    let viewModel: CopilotViewModel

    private static let prompts = [
        "Why is my charging speed slow?",
        "How's my battery health?",
        "Explain my current energy use",
        "Should I precondition before charging?"
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Ask about your car")
                .font(.headline)
                .foregroundStyle(.secondary)
            ForEach(Self.prompts, id: \.self) { prompt in
                Button {
                    viewModel.inputText = prompt
                } label: {
                    HStack {
                        Text(prompt)
                            .multilineTextAlignment(.leading)
                        Spacer()
                        Image(systemName: "arrow.up.left")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    .padding(12)
                    .background(Color.surfaceNavy, in: RoundedRectangle(cornerRadius: 10))
                }
                .tint(.primary)
            }
        }
    }
}

// MARK: - Composer

private struct Composer: View {
    let viewModel: CopilotViewModel

    var body: some View {
        HStack(spacing: 10) {
            TextField("Ask about your car…", text: Binding(
                get: { viewModel.inputText },
                set: { viewModel.inputText = $0 }
            ), axis: .vertical)
            .lineLimit(1...4)
            .textFieldStyle(.plain)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Color.surfaceVariant, in: Capsule())
            .onSubmit { Task { await viewModel.send() } }

            Button {
                Task { await viewModel.send() }
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 30))
            }
            .tint(Color.electricTeal)
            .disabled(!viewModel.canSend)
            .accessibilityLabel("Send")
        }
        .padding()
        .background(Color.deepNavy)
    }
}
