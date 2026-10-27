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

            // iOS has no in-app language API: an app may not set its own language, and
            // the only supported switch is the per-app language row iOS shows in
            // Settings once the bundle declares more than one localisation. Rather than
            // the unsupported `AppleLanguages` UserDefaults override (needs a relaunch,
            // and confuses the system's own formatting), this row reports the language
            // actually in force and jumps to where the user can change it.
            Button {
                guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
                UIApplication.shared.open(url)
            } label: {
                HStack {
                    Text("App language")
                        .foregroundStyle(.primary)
                    Spacer(minLength: 8)
                    Text(currentLanguageName)
                        .foregroundStyle(.secondary)
                }
            }

            Text("iOS does not let an app change its own language. Change it in Settings › IONIQ Telemetry › Language.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// The language this app is actually rendering in: the per-app override when the
    /// user set one, otherwise the device language. Read from the bundle rather than
    /// `Locale.current`, which reports the device language even when the app is pinned
    /// to another one, and named in the current interface language the way iOS's own
    /// language rows do it.
    private var currentLanguageName: String {
        let code = Bundle.main.preferredLocalizations.first ?? "en"
        return Locale.current.localizedString(forIdentifier: code) ?? code
    }
}
