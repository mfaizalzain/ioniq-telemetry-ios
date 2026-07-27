import CoreDomain
import CoreOBD
import CoreUI
import SwiftUI

// MARK: - Vehicle picker

struct VehiclePickerSheet: View {
    let viewModel: SettingsViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                ForEach(viewModel.vehiclesByMake, id: \.make) { group in
                    Section(group.make.rawValue) {
                        ForEach(group.vehicles) { vehicle in
                            Button {
                                viewModel.selectVehicle(vehicle)
                                dismiss()
                            } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(vehicle.displayName)
                                        Text("\(vehicle.year)")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Text(String(format: "%.0f kWh", vehicle.usableKwh))
                                        .font(.caption.weight(.medium))
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 3)
                                        .background(Color.appSurfaceVariant, in: Capsule())
                                    if viewModel.activeVehicle?.id == vehicle.id {
                                        Image(systemName: "checkmark")
                                            .foregroundStyle(Color.appAccent)
                                    }
                                }
                            }
                            .tint(.primary)
                        }
                    }
                }
            }
            .navigationTitle("Vehicle")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

