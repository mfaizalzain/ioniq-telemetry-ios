import CoreDomain
import SwiftUI

/// Expandable AI planning card matching the Android AiPlanCard layout.
///
/// Gate this card with `isPro && hasKey && aiFeaturesEnabled` at the call site.
struct AiPlanCardView: View {
    let viewModel: PlanViewModel
    let aiKey: String?
    let aiProvider: AiProvider
    let isBusy: Bool
    let showError: String?
    let showInterpretation: String?
    let onInputChange: (String) -> Void
    let onPlan: () -> Void

    @State private var expanded = false

    private var providerName: String { aiProvider.label }
    private var hasKey: Bool { aiKey.map { !$0.isEmpty } ?? false }

    var body: some View {
        GroupBox {
            VStack(spacing: 0) {
                // Header Row — always visible, clickable to expand/collapse
                headerRow

                if expanded {
                    VStack(spacing: 12) {
                        // Text input + send
                        inputBar

                        // Quick preset prompt chip
                        if viewModel.nlInput.isEmpty && !isBusy && showInterpretation == nil {
                            quickPromptChips
                        }

                        // Error or Interpretation
                        if let error = showError {
                            errorBanner(error)
                        } else if let interpretation = showInterpretation {
                            interpretationBanner(interpretation)
                        }
                    }
                    .padding(.top, 12)
                }
            }
        }
        .padding(.horizontal)
        .backgroundStyle(.ultraThinMaterial)
    }

    // MARK: - Header

    private var headerRow: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) { expanded.toggle() }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "sparkles")
                    .foregroundStyle(Color.appAccent)
                    .font(.caption)

                Text("Plan by Conversation")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)

                Spacer()

                // Provider badge
                Text(providerName)
                    .font(.caption2.weight(.bold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(Color.appAccent.opacity(0.15), in: Capsule())
                    .foregroundStyle(Color.appAccent)

                Image(systemName: "chevron.down")
                    .rotationEffect(.degrees(expanded ? 180 : 0))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: - Input Bar

    private var inputBar: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("Where do you want to go?", text: Binding(
                get: { viewModel.nlInput },
                set: { onInputChange($0) }
            ), axis: .vertical)
                .textFieldStyle(.plain)
                .font(.subheadline)
                .padding(10)
                .background(Color.appSurfaceVariant, in: RoundedRectangle(cornerRadius: 10))
                .disabled(isBusy)
                .lineLimit(2...5)

            // Send button (or loading spinner)
            if isBusy {
                ProgressView()
                    .scaleEffect(0.8)
                    .frame(width: 36, height: 36)
            } else {
                Button {
                    onPlan()
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.title2)
                }
                .buttonStyle(.plain)
                .foregroundStyle(
                    !viewModel.nlInput.trimmingCharacters(in: .whitespaces).isEmpty
                        ? Color.appAccent
                        : Color.appOnSurface.opacity(0.3)
                )
                .disabled(viewModel.nlInput.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }

    // MARK: - Quick Prompt Chips

    private var quickPromptChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                Button {
                    onInputChange("Find chargers near me")
                    Task { onPlan() }
                } label: {
                    Text("Find chargers near me")
                        .font(.caption)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Color.appSurface, in: Capsule())
                }
                .buttonStyle(.plain)
                .tint(.primary)
            }
        }
    }

    // MARK: - Feedback Banners

    private func errorBanner(_ error: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(Color.appAmber)
            Text(error)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(10)
        .background(Color.appSurfaceVariant, in: RoundedRectangle(cornerRadius: 8))
    }

    private func interpretationBanner(_ text: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(Color.appGreen)
            Text(text)
                .font(.caption)
                .foregroundStyle(.primary)
            Spacer()
        }
        .padding(10)
        .background(Color.appAccent.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }
}
