import SwiftUI
import CoreUI

struct PaywallView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    // Header
                    VStack(spacing: 8) {
                        Image(systemName: "bolt.fill")
                            .font(.system(size: 48))
                            .foregroundStyle(Color(red: 0.09, green: 0.91, blue: 0.76))

                        Text("Unlock Pro")
                            .font(.largeTitle.bold())

                        Text("Supports all E-GMP vehicles.")
                            .foregroundStyle(.secondary)
                    }
                    .padding(.top, 32)

                    // Feature list
                    VStack(alignment: .leading, spacing: 12) {
                        FeatureRow(icon: "sparkles", text: "AI Assistant — trip planning & coaching")
                        FeatureRow(icon: "xmark.circle", text: "Remove Ads")
                        FeatureRow(icon: "bell.fill", text: "Charger Occupancy Alerts")
                        FeatureRow(icon: "calendar", text: "365-Day Trip Retention")
                    }
                    .padding(20)
                    .background(.ultraThinMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 12))

                    // Products
                    VStack(spacing: 12) {
                        productButton(title: "Monthly", price: "$1.99/mo", badge: nil)
                        productButton(title: "Yearly", price: "$19.99/yr", badge: "Save 16%")
                        productButton(title: "Lifetime", price: "$49.99", badge: "Best Value")
                    }

                    // Restore
                    Button("Restore Purchases") {
                        // Restore
                    }
                    .foregroundStyle(.secondary)
                    .font(.subheadline)
                }
                .padding()
            }
            .background(Color(red: 0.043, green: 0.071, blue: 0.125))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Close") { dismiss() }
                }
            }
        }
    }

    func productButton(title: String, price: String, badge: String?) -> some View {
        Button {
            // Purchase
        } label: {
            HStack {
                VStack(alignment: .leading) {
                    Text(title)
                        .font(.headline)
                    Text(price)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if let badge = badge {
                    Text(badge)
                        .font(.caption.weight(.bold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color(red: 0.09, green: 0.91, blue: 0.76))
                        .foregroundStyle(.black)
                        .clipShape(Capsule())
                }
            }
            .padding(16)
            .background(Color(white: 1).opacity(0.1))
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
        .foregroundStyle(.primary)
    }
}

struct FeatureRow: View {
    var icon: String
    var text: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .frame(width: 24)
                .foregroundStyle(Color(red: 0.09, green: 0.91, blue: 0.76))
            Text(text)
                .font(.body)
            Spacer()
        }
    }
}
