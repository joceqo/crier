import SwiftUI
import AppKit

// SetupView — first-launch (and "Setup…" menu) wizard that wires Crier hooks
// into each detected agent's config. State for the per-agent rows is held in
// SetupModel; the actual file editing lives in Installer.swift.

@MainActor
final class SetupModel: ObservableObject {
    struct Row: Identifiable {
        let id = UUID()
        let agent: Installer.Agent
        var status: Installer.InstallStatus
        var enabled: Bool
        var lastError: String?
    }

    @Published var rows: [Row] = []
    @Published var isInstalling = false
    @Published var installSummary: String?

    init() { refresh() }

    func refresh() {
        rows = Installer.Agent.allCases.map { agent in
            let status = Installer.status(agent)
            // Default the checkbox: on for detected-but-unwired, on for stale
            // path (so the user gets a one-click "fix everything"), off for
            // not-detected and already-wired (nothing to do).
            let enabled: Bool
            switch status {
            case .detectedNotWired, .wiredOtherPath: enabled = true
            case .notDetected, .wired:               enabled = false
            }
            return Row(agent: agent, status: status, enabled: enabled, lastError: nil)
        }
    }

    func install() async {
        isInstalling = true
        installSummary = nil
        var done: [String] = []
        var failed: [String] = []
        for i in rows.indices {
            guard rows[i].enabled else { continue }
            do {
                try Installer.install(rows[i].agent)
                rows[i].lastError = nil
                done.append(rows[i].agent.rawValue)
            } catch {
                rows[i].lastError = error.localizedDescription
                failed.append(rows[i].agent.rawValue)
            }
        }
        refresh()
        isInstalling = false

        if failed.isEmpty {
            installSummary = done.isEmpty
                ? "Nothing was selected."
                : "Wired hooks for: \(done.joined(separator: ", ")). Restart any running agent sessions."
        } else {
            installSummary = "Failed: \(failed.joined(separator: ", ")). " +
                             (done.isEmpty ? "" : "Succeeded: \(done.joined(separator: ", ")).")
        }
    }
}

struct SetupView: View {
    @StateObject private var model = SetupModel()
    var onClose: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "megaphone.fill")
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Set up Crier integrations")
                        .font(.title2.weight(.semibold))
                    Text("Crier wires hooks into each agent's config so it can catch \"turn finished\" and \"needs permission\" events. The bundled crier-emit binary inside Crier.app is referenced by absolute path — no PATH changes, no sudo.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 10) {
                ForEach($model.rows) { $row in
                    AgentRow(row: $row)
                }
            }

            if let summary = model.installSummary {
                Text(summary)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Divider()

            HStack {
                Spacer()
                Button("Close") { onClose() }
                    .keyboardShortcut(.cancelAction)
                Button(action: { Task { await model.install() } }) {
                    if model.isInstalling {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("Install Selected")
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(model.isInstalling || !model.rows.contains(where: { $0.enabled }))
            }
        }
        .padding(20)
        .frame(width: 540)
    }
}

private struct AgentRow: View {
    @Binding var row: SetupModel.Row

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Toggle("", isOn: $row.enabled)
                .toggleStyle(.checkbox)
                .labelsHidden()
                .disabled(disabled)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(row.agent.rawValue)
                        .font(.headline)
                    Text(statusBadge)
                        .font(.caption)
                        .foregroundStyle(badgeColor)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(badgeColor.opacity(0.15), in: Capsule())
                }
                Text(detailText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let err = row.lastError {
                    Text(err)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
            Spacer()
        }
    }

    private var disabled: Bool {
        switch row.status {
        case .notDetected: return true
        default:           return false
        }
    }

    private var statusBadge: String {
        switch row.status {
        case .notDetected:     return "not detected"
        case .detectedNotWired: return "ready to install"
        case .wired:           return "installed"
        case .wiredOtherPath:  return "stale path"
        }
    }

    private var badgeColor: Color {
        switch row.status {
        case .notDetected:     return .secondary
        case .detectedNotWired: return .orange
        case .wired:           return .green
        case .wiredOtherPath:  return .yellow
        }
    }

    private var detailText: String {
        switch row.agent {
        case .claudeCode:
            return "~/.claude/settings.json — Stop, Notification, PermissionRequest, PreToolUse:AskUserQuestion, UserPromptSubmit. Also installs /crier skill + slash command."
        case .cursor:
            return "~/.cursor/hooks.json — stop, beforeShellExecution."
        case .codex:
            return "~/.codex/config.toml — [[hooks.Stop]] and [[hooks.PermissionRequest]] inside a managed CRIER block."
        case .opencode:
            return "~/.config/opencode/opencode.json — adds the bundled plugin's absolute path to the `plugin` array. Listens for session.idle and permission.asked."
        }
    }
}
