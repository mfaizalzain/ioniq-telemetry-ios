import CoreUI
import StoreKit
import SwiftUI

struct PaywallView: View {
    @Environment(AppServices.self) private var services
    @Environment(\.dismiss) private var dismiss
    @State private var viewModel: PaywallViewModel?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    header

                    FeatureList()

                    if let viewModel {
                        if viewModel.isPro {
                            ActiveProCard()
                        } else if let product = viewModel.product {
                            ProductButton(product: product, viewModel: viewModel)
                        } else if viewModel.isLoading {
                            ProgressView()
                        }

                        if let error = viewModel.errorMessage {
                            Label(error, systemImage: "exclamationmark.triangle.fill")
                                .font(.caption)
                                .foregroundStyle(Color.appAmber)
                                .multilineTextAlignment(.center)
                        }

                        Button("Restore Purchases") {
                            Task { await viewModel.restore() }
                        }
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .disabled(viewModel.isLoading)

                        LegalLinks()
                    } else {
                        ProgressView()
                    }
                }
                .padding()
            }
            .background(Color.appBackground)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Close") { dismiss() }
                }
            }
        }
        .task {
            if viewModel == nil {
                viewModel = PaywallViewModel(entitlement: services.entitlement)
            }
            await viewModel?.load()
        }
    }

    private var header: some View {
        VStack(spacing: 8) {
            Image(systemName: "bolt.fill")
                .font(.system(size: 48))
                .foregroundStyle(Color.appAccent)
            Text("Unlock Pro")
                .font(.largeTitle.bold())
            Text("Supports all E-GMP vehicles.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding(.top, 8)
    }
}

// MARK: - Features

private struct FeatureList: View {
    private static let features: [(icon: String, title: String, detail: String)] = [
        ("sparkles", "AI Assistant", "Plain-language diagnostics and energy insights"),
        ("bell.badge", "Charger Occupancy Alerts", "Know before you arrive at a full charger"),
        ("map", "Live Charger Availability", "Connector status on nearby chargers, with your Google key"),
        ("calendar", "365-Day Trip History", "Up from 90 days on the free tier")
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(Self.features, id: \.title) { feature in
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: feature.icon)
                        .foregroundStyle(Color.appAccent)
                        .frame(width: 24)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(feature.title)
                            .font(.subheadline.weight(.medium))
                        if !feature.detail.isEmpty {
                            Text(feature.detail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                }
                .accessibilityElement(children: .combine)
            }
        }
        .padding()
        .background(Color.appSurface, in: RoundedRectangle(cornerRadius: 14))
    }
}

// MARK: - Product

/// The single non-consumable unlock. No plan picker — there is one price, paid once.
private struct ProductButton: View {
    let product: Product
    let viewModel: PaywallViewModel

    var body: some View {
        Button {
            Task { await viewModel.purchase(product) }
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Unlock Pro")
                        .font(.headline)
                    Text("One-time purchase")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if viewModel.purchaseInProgress == product.id {
                    ProgressView()
                } else {
                    Text(product.displayPrice)
                        .font(.headline)
                }
            }
            .padding()
            .background(Color.appSurfaceVariant, in: RoundedRectangle(cornerRadius: 12))
        }
        .tint(.primary)
        .disabled(viewModel.purchaseInProgress != nil)
        .accessibilityElement(children: .combine)
    }
}

private struct ActiveProCard: View {
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "checkmark.seal.fill")
                .font(.title2)
                .foregroundStyle(Color.appGreen)
            VStack(alignment: .leading, spacing: 2) {
                Text("Pro is active")
                    .font(.headline)
                Text("Thanks for supporting development.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding()
        .background(Color.appGreen.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .combine)
    }
}

private struct LegalLinks: View {
    var body: some View {
        VStack(spacing: 6) {
            Text("Pro is a one-time purchase — no subscription, nothing to renew or cancel.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)

            HStack(spacing: 16) {
                Link("Privacy Policy", destination: AppLinks.privacyPolicy)
                Link("Terms of Use", destination: AppLinks.termsOfUse)
            }
            .font(.caption2)
            .tint(Color.appAccent)
        }
        .padding(.top, 4)
    }
}
