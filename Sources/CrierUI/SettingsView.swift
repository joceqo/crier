import CrierEmitCore
import SwiftUI

/// Menu bar → **Settings…** — overlay, conversations, diagnostics, global silence.
struct SettingsView: View {
    @ObservedObject var preferences: CrierPreferences
    let onOpenConversations: () -> Void
    let onRevealLogs: () -> Void
    let onToggleGlobalDisable: () -> Void

    @State private var globalDisableSynced: Bool = false

    var body: some View {
        Form {
            Section {
                Toggle(isOn: Binding(
                    get: { globalDisableSynced },
                    set: { target in
                        guard target != globalDisableSynced else { return }
                        onToggleGlobalDisable()
                        globalDisableSynced = FileManager.default.fileExists(atPath: CrierEmitCore.globalDisabledPath)
                    }
                )) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Disable Crier globally")
                            .font(.system(size: 13, weight: .medium))
                        Text(
                            "When on, hooks skip the overlay for every project until you turn this off."
                        )
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                }
            } header: {
                Text("Behavior")
            }

            Section {
                Button(action: onOpenConversations) {
                    HStack {
                        Text("Conversations…")
                            .font(.system(size: 13))
                            .foregroundStyle(.primary)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.tertiary)
                    }
                }
                .buttonStyle(.plain)

                Text("Active sessions, per-conversation disable, and project-wide flags. Shortcut: ⌘,")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            } header: {
                Text("Sessions")
            }

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

            Section {
                Button("Reveal Logs in Finder…") {
                    onRevealLogs()
                }
                .font(.system(size: 13))

                Text("Copies recent Crier logs into a temp folder and opens Finder.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            } header: {
                Text("Diagnostics")
            }
        }
        .formStyle(.grouped)
        .padding(16)
        .frame(minWidth: 440, minHeight: 420)
        .onAppear {
            globalDisableSynced = FileManager.default.fileExists(atPath: CrierEmitCore.globalDisabledPath)
        }
    }
}
