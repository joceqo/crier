import SwiftUI

/// Menu bar → **Settings…** — overlay and other app-wide toggles.
struct SettingsView: View {
    @ObservedObject var preferences: CrierPreferences

    var body: some View {
        Form {
            Section {
                Toggle(isOn: $preferences.compactOverlay) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Compact overlay")
                            .font(.system(size: 13, weight: .medium))
                        Text(
                            "When enabled, Crier opens as a slim session list with an activity count. Expand to read and reply, or collapse again when you need focus. You can also toggle this from the menu bar."
                        )
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                }
            } header: {
                Text("Overlay")
            }
        }
        .formStyle(.grouped)
        .padding(16)
        .frame(minWidth: 440, minHeight: 260)
    }
}
