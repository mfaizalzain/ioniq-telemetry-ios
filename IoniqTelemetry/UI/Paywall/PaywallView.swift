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
                        } else {
                            ProductList(viewModel: viewModel)
                        }

                        if let error = viewModel.errorMessage {
                            Label(error, systemImage: "exclamationmark.triangle.fill")
                                .font(.caption)
                                .foregroundStyle(Color.amberWarn)
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
            .background(Color.deepNavy)
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
                .foregroundStyle(Color.electricTeal)
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
        ("sparkles", "AI Assistant", "Plain-language diagnostics and energy coaching"),
        ("bell.badge", "Charger Occupancy Alerts", "Know before you arrive at a full charger"),
        ("map", "Live Charger Availability", "Real-time status along your route"),
        ("calendar", "365-Day Trip History", "Up from 90 days on the free tier"),
        ("rectangle.slash", "No Ads", "")
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(Self.features, id: \.title) { feature in
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: feature.icon)
                        .foregroundStyle(Color.electricTeal)
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
        .background(Color.surfaceNavy, in: RoundedRectangle(cornerRadius: 14))
    }
}

// MARK: - Products

private struct ProductList: View {
    let viewModel: PaywallViewModel

    var body: some View {
        VStack(spacing: 10) {
            if viewModel.isLoading && viewModel.products.isEmpty {
                ProgressView()
            }
            ForEach(viewModel.products) { product in
                ProductButton(
                    product: product,
                    viewModel: viewModel,
                    badge: product.id == PaywallViewModel.ProductKind.yearly.rawValue
                        ? viewModel.yearlySavingsPercent.map { "SAVE \($0)%" }
                        : nil
                )
            }
        }
    }
}

private struct ProductButton: View {
    let product: Product
    let viewModel: PaywallViewModel
    let badge: String?

    var body: some View {
        Button {
            Task { await viewModel.purchase(product) }
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(viewModel.title(for: product))
                            .font(.headline)
                        if let badge {
                            Text(badge)
                                .font(.caption2.weight(.bold))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.greenOk.opacity(0.2), in: Capsule())
                                .foregroundStyle(Color.greenOk)
                        }
                    }
                    Text(viewModel.subtitle(for: product))
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
            .background(Color.surfaceVariant, in: RoundedRectangle(cornerRadius: 12))
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
                .foregroundStyle(Color.greenOk)
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
        .background(Color.greenOk.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .combine)
    }
}

private struct LegalLinks: View {
    var body: some View {
        VStack(spacing: 6) {
            Text("Subscriptions renew automatically until cancelled. Manage them in your Apple Account settings.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .padding(.top, 4)
    }
}
