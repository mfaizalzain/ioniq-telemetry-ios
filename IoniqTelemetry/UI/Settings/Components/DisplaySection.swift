import CoreDomain
import SwiftUI

/// Units and appearance settings merged into one "Display" section.
struct DisplaySection: View {
    let viewModel: SettingsViewModel

    var body: some View {
        Section("Display") {
            Picker("Units", selection: Binding(
                get: { viewModel.preferences.unitSystem },
                set: { viewModel.setUnitSystem($0) }
            )) {
                Text("Metric").tag(UnitSystem.metric)
                Text("Imperial").tag(UnitSystem.imperial)
            }
            .pickerStyle(.segmented)

            Picker("Theme", selection: Binding(
                get: { viewModel.preferences.themeMode },
                set: { viewModel.setThemeMode($0) }
            )) {
                Text("System").tag(ThemeMode.system)
                Text("Light").tag(ThemeMode.light)
                Text("Dark").tag(ThemeMode.dark)
            }
            .pickerStyle(.segmented)
        }
    }
}
