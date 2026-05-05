import AppKit
import ApplicationServices
import CoreGraphics
import CrierEmitCore
import CrierServer
import MarkdownToAttributedString
import SwiftUI

// crier-ui — floating overlay panel.
//
// Runs as an .accessory app (no Dock icon). Long-polls the daemon's
// `GET /current?wait=30` endpoint in a loop. Each event makes the panel pop
// in the bottom-right of the active screen, except `dismiss` which hides it
// (UserPromptSubmit fires that — user is typing in the agent's TTY anyway).
//
// On reply submit, POSTs `/reply` with the event's session/request/channel/
// target. For tmux-channel events the daemon then runs `tmux send-keys` to
// deliver the text to the agent's pane; for `http-poll` (OpenCode) the
// daemon wakes the matching long-poll waiter.

private let endpoint = ProcessInfo.processInfo.environment["CRIER_ENDPOINT"] ?? "http://127.0.0.1:8731"

private func uiLogFilePath() -> String {
    let fm = FileManager.default
    guard let dir = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
        .appendingPathComponent("Crier", isDirectory: true) else {
        return (NSTemporaryDirectory() as NSString).appendingPathComponent("crier-ui.log")
    }
    try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir.appendingPathComponent("crier-ui.log").path
}

// Append a line to ~/Library/Application Support/Crier/crier-ui.log — neutral
// path (not under ~/.claude, which is only Claude Code’s config). Same general
// shape as crier-emit’s log lines for end-to-end debugging.
@inline(__always)
private func uiLog(_ msg: String) {
    let path = uiLogFilePath()
    let stamp = ISO8601DateFormatter().string(from: Date())
    let line = "[\(stamp)] [pid:\(getpid())] \(msg)\n"
    let data = line.data(using: .utf8) ?? Data()
    let url = URL(fileURLWithPath: path)
    if let h = try? FileHandle(forWritingTo: url) {
        h.seekToEndOfFile()
        h.write(data)
        try? h.close()
    } else {
        try? data.write(to: url)
    }
}

// Post a string to whatever app is frontmost, then press Return. Legacy
// fallback for events without a `reply_channel` — every supported agent now
// uses hook-stdout / tmux / http-poll, so this path is rarely hit. When it
// is hit and the user hasn't manually granted Accessibility, CGEventPost is
// silently filtered and the failure shows up in the UI log via
// the POST /reply completion handler. Each character goes through
// CGEventKeyboardSetUnicodeString with virtualKey 0, the canonical
// "type this Unicode regardless of keyboard layout" trick.
private func postKeystrokes(_ text: String, pressReturn: Bool = true) {
    guard let source = CGEventSource(stateID: .hidSystemState) else { return }
    for ch in text {
        let utf16 = Array(String(ch).utf16)
        utf16.withUnsafeBufferPointer { buf in
            guard let base = buf.baseAddress else { return }
            if let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true) {
                down.keyboardSetUnicodeString(stringLength: buf.count, unicodeString: base)
                down.post(tap: .cghidEventTap)
            }
            if let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) {
                up.keyboardSetUnicodeString(stringLength: buf.count, unicodeString: base)
                up.post(tap: .cghidEventTap)
            }
        }
    }
    if pressReturn {
        // virtualKey 0x24 = kVK_Return
        CGEvent(keyboardEventSource: source, virtualKey: 0x24, keyDown: true)?.post(tap: .cghidEventTap)
        CGEvent(keyboardEventSource: source, virtualKey: 0x24, keyDown: false)?.post(tap: .cghidEventTap)
    }
}

/// One agent session (Claude in repo A, Codex in repo B, …). `id` matches the wire `session_id` from crier-emit.
struct CrierSession: Identifiable, Equatable {
    let id: String
    var receivedAt: Date
    var title: String
    var eventKind: String
    var message: String
    var agentName: String
    var projectName: String
    var cwd: String?
    var requestId: String?
    var replyChannel: String?
    var replyTarget: String?
    var terminalPid: Int32?
    var replyDraft: String = ""

    var tabLabel: String {
        let ag = switch agentName {
        case "claude-code": "Claude"
        case "codex": "Codex"
        case "cursor": "Cursor"
        case "opencode": "OpenCode"
        default: String(agentName.prefix(5))
        }
        let p = projectName.isEmpty ? "…" : projectName
        return "\(ag) · \(p)"
    }

    static func fromPayload(_ obj: [String: Any], id: String) -> CrierSession {
        let cwd = obj["cwd"] as? String
        let proj = Self.displayProjectTitle(fromWorkingDirectory: cwd)
        return CrierSession(
            id: id,
            receivedAt: Date(),
            title: obj["title"] as? String ?? "Crier",
            eventKind: obj["event"] as? String ?? "",
            message: obj["message"] as? String ?? "",
            agentName: obj["agent"] as? String ?? "claude-code",
            projectName: proj,
            cwd: cwd,
            requestId: obj["request_id"] as? String,
            replyChannel: obj["reply_channel"] as? String,
            replyTarget: obj["reply_target"] as? String,
            terminalPid: (obj["terminal_pid"] as? Int).map { Int32($0) },
            replyDraft: ""
        )
    }

    /// Badge / tab line derived from `cwd`’s last path segment. Maps home
    /// config dirs like `~/.claude` to a short readable label instead of
    /// showing a dot-folder name.
    private static func displayProjectTitle(fromWorkingDirectory cwd: String?) -> String {
        guard let cwd, !cwd.isEmpty else { return "" }
        let path = (cwd as NSString).standardizingPath
        let home = (NSHomeDirectory() as NSString).standardizingPath
        let last = (path as NSString).lastPathComponent
        let parent = ((path as NSString).deletingLastPathComponent as NSString).standardizingPath

        if last == ".claude" { return parent == home ? "Claude" : (parent as NSString).lastPathComponent }
        if parent == home, last.hasPrefix("."), last.count > 1 {
            switch last {
            case ".cursor": return "Cursor"
            case ".codex": return "Codex"
            case ".opencode": return "OpenCode"
            case ".config": return "Config"
            default:
                let tail = String(last.dropFirst())
                return tail.isEmpty ? "…" : tail.capitalized
            }
        }
        return last
    }
}

final class CrierState: ObservableObject, @unchecked Sendable {
    @Published var sessions: [CrierSession] = []
    @Published var selectedSessionKey: String?
    @Published var focusGen: Int = 0
    @Published var showDisableDialog: Bool = false

    var selectedSession: CrierSession? {
        guard let k = selectedSessionKey else { return nil }
        return sessions.first { $0.id == k }
    }

    /// Merge or append by `session_id` so parallel agents (two Claudes, Claude+Codex, …) each keep a tab.
    func upsertFromPayload(_ obj: [String: Any]) {
        let sidRaw = obj["session_id"] as? String
        let sid = (sidRaw?.isEmpty == false) ? sidRaw! : UUID().uuidString

        var next = sessions
        let isNewSession: Bool
        if let idx = next.firstIndex(where: { $0.id == sid }) {
            let old = next[idx]
            let newRid = obj["request_id"] as? String
            var incoming = CrierSession.fromPayload(obj, id: sid)
            if newRid == old.requestId { incoming.replyDraft = old.replyDraft }
            next[idx] = incoming
            isNewSession = false
        } else {
            next.append(CrierSession.fromPayload(obj, id: sid))
            isNewSession = true
        }
        next.sort { $0.receivedAt > $1.receivedAt }
        sessions = next

        // Tab-selection rule for parallel sessions:
        //   • No tab selected yet → select the incoming one.
        //   • Currently-selected session has an empty replyDraft (user
        //     hasn't started typing) → swap to the freshly-arrived
        //     session so the panel shows the latest pop. Without this,
        //     a second discussion firing while a first is up never
        //     gets surfaced beyond a small tab — which the user
        //     reported as "Crier shows one discussion but blocks
        //     another."
        //   • Otherwise (user is mid-typing in another tab) → leave
        //     selection alone. The new tab is still visible in the
        //     SessionTabStrip; user can switch when ready.
        if selectedSessionKey == nil {
            selectedSessionKey = sid
        } else if isNewSession,
                  let current = next.first(where: { $0.id == selectedSessionKey }),
                  current.replyDraft.isEmpty {
            selectedSessionKey = sid
        }
        focusGen += 1
    }

    func updateReplyDraft(sessionId id: String, text: String) {
        guard let idx = sessions.firstIndex(where: { $0.id == id }) else { return }
        var copy = sessions
        let wasEmpty = copy[idx].replyDraft.isEmpty
        copy[idx].replyDraft = text
        sessions = copy
        // First keystroke per turn → notify the daemon the user is
        // engaging this session, so /reply/drain extends its wait window.
        // Only meaningful for the pre-queue path; cheap no-op for others.
        if wasEmpty && !text.isEmpty,
           copy[idx].replyChannel == "hook-stdout-queue" {
            CrierState.postReplyEngage(sessionId: id)
        }
    }

    /// Fire-and-forget POST /reply/engage. Called on the user's first
    /// keystroke per turn (and could be called on Send too, but Send already
    /// queues a reply which wakes the drain).
    static func postReplyEngage(sessionId: String) {
        guard let url = URL(string: "\(endpoint)/reply/engage"),
              let data = try? JSONSerialization.data(withJSONObject: [
                "session_id": sessionId,
                "extend_seconds": 30,
              ]) else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.httpBody = data
        URLSession.shared.dataTask(with: req).resume()
    }

    func removeSession(id: String) {
        sessions = sessions.filter { $0.id != id }
        if selectedSessionKey == id { selectedSessionKey = sessions.first?.id }
    }

    func removeAllSessions() {
        sessions.removeAll()
        selectedSessionKey = nil
    }

    func selectSession(id: String) {
        selectedSessionKey = id
        focusGen += 1
    }
}

// Confirmation dialog shown when the user clicks the badge X. Three exits:
// - top-right X: dismiss the dialog only (panel stays exactly as it was).
// - "Leave": close the panel for this turn — agent gets an empty reply,
//   next turn pops the panel again.
// - "Disable": silence this whole conversation; re-enable from the
//   menu-bar megaphone → Conversations…
struct DisableSessionDialog: View {
    let onConfirm: () -> Void   // Disable
    let onLeave: () -> Void     // Leave (this turn)
    let onCancel: () -> Void    // X / backdrop tap (just close the dialog)

    var body: some View {
        ZStack {
            // Transparent tap-to-dismiss layer. We used to dim the panel
            // (Color.black.opacity 0.35) but that bled outside the panel
            // and over the terminal underneath, making the dialog feel
            // heavier than the small choice it represents. The card's
            // shadow already separates it from the panel content.
            Color.clear
                .contentShape(Rectangle())
                .ignoresSafeArea()
                .onTapGesture { onCancel() }

            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top) {
                    Text("Disable Crier for this conversation?")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.primary)
                    Spacer(minLength: 8)
                    Button(action: onCancel) {
                        Image(systemName: "xmark")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.primary)
                            .frame(width: 20, height: 20)
                            .background(.quaternary, in: Circle())
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.cancelAction)
                }

                bodyText

                HStack(spacing: 12) {
                    Button(action: onLeave) {
                        Text("Leave")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.primary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 9)
                    }
                    .buttonStyle(.plain)
                    .background(.quaternary, in: Capsule())

                    Button(action: onConfirm) {
                        Text("Disable")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.red)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 9)
                    }
                    .buttonStyle(.plain)
                    .background(Color.red.opacity(0.18), in: Capsule())
                    .keyboardShortcut(.defaultAction)
                }
            }
            .padding(20)
            .frame(width: 360)
            .crierCard(cornerRadius: 18)
        }
    }

    private var bodyText: Text {
        Text("Leave closes the panel for this turn — Crier pops again on the next message. Disable silences this conversation; re-enable from the menu-bar megaphone → Conversations…")
            .foregroundStyle(.secondary)
            .font(.system(size: 13))
    }
}

// Standalone window opened from the menu-bar status item. Lists every
// conversation we currently know about — "Active" rows are sessions whose
// panel is (or was just) showing; "Disabled" rows come from the on-disk
// `/tmp/crier-agent/disabled-<md5(cwd)>` flag files written by the
// `/crier off` skill or the badge X dialog. Each row's switch flips that
// flag, which is the same mechanism `crier-emit` checks before posting an
// event.
//
// The "Settings" section is intentionally a placeholder until we have real
// per-app preferences to expose.
struct ConversationsView: View {
    @ObservedObject var state: CrierState
    @State private var disabledCwdKnown: [String] = []
    @State private var disabledCwdUnknown: [String] = []
    @State private var disabledSessions: [(fullId: String, cwd: String)] = []

    var body: some View {
        List {
            Section("Active conversations") {
                if state.sessions.isEmpty {
                    Text("No active conversations.")
                        .foregroundStyle(.secondary)
                        .font(.system(size: 12))
                } else {
                    ForEach(state.sessions, id: \.id) { s in
                        ConversationRow(
                            title: rowTitle(for: s),
                            subtitle: rowSubtitle(for: s),
                            enabled: isActiveEnabled(session: s),
                            onToggle: { toggleActive(session: s) }
                        )
                    }
                }
            }

            Section("Disabled conversations (not active)") {
                let inactive = disabledSessions.filter { d in
                    !state.sessions.contains { $0.id == d.fullId }
                }
                if inactive.isEmpty {
                    Text("None.")
                        .foregroundStyle(.secondary)
                        .font(.system(size: 12))
                } else {
                    ForEach(inactive, id: \.fullId) { d in
                        ConversationRow(
                            title: d.cwd.isEmpty ? d.fullId : d.cwd,
                            subtitle: d.cwd.isEmpty ? "Disabled" : "Disabled · \(d.fullId)",
                            enabled: false,
                            onToggle: { CrierEmitCore.clearSessionDisabled(d.fullId); reload() }
                        )
                    }
                }
            }

            Section("Disabled projects (whole cwd)") {
                let inactiveCwds = disabledCwdKnown.filter { d in
                    !state.sessions.contains { $0.cwd == d }
                }
                if inactiveCwds.isEmpty && disabledCwdUnknown.isEmpty {
                    Text("None.")
                        .foregroundStyle(.secondary)
                        .font(.system(size: 12))
                } else {
                    ForEach(inactiveCwds, id: \.self) { cwd in
                        ConversationRow(
                            title: cwd,
                            subtitle: "Disabled (project)",
                            enabled: false,
                            onToggle: { CrierEmitCore.clearCwdDisabled(cwd); reload() }
                        )
                    }
                    if !disabledCwdUnknown.isEmpty {
                        Text("\(disabledCwdUnknown.count) older flag file(s) without recorded path. Run /crier on in the relevant project to clear.")
                            .foregroundStyle(.secondary)
                            .font(.system(size: 11))
                    }
                }
            }

            Section("Settings") {
                Text("More options coming soon.")
                    .foregroundStyle(.secondary)
                    .font(.system(size: 12))
            }
        }
        .listStyle(.sidebar)
        .frame(minWidth: 460, minHeight: 460)
        .onAppear { reload() }
        .onChange(of: state.sessions.count) { _, _ in reload() }
    }

    private func rowTitle(for s: CrierSession) -> String {
        if !s.projectName.isEmpty { return s.projectName }
        if let cwd = s.cwd, !cwd.isEmpty { return cwd }
        return s.agentName
    }

    private func rowSubtitle(for s: CrierSession) -> String {
        let parts: [String] = [s.agentName, s.cwd ?? ""].filter { !$0.isEmpty }
        return parts.joined(separator: " · ")
    }

    private func isActiveEnabled(session s: CrierSession) -> Bool {
        if disabledSessions.contains(where: { $0.fullId == s.id }) { return false }
        if let cwd = s.cwd, !cwd.isEmpty, disabledCwdKnown.contains(cwd) { return false }
        return true
    }

    /// Active-row toggle. If the session is currently disabled (by either
    /// flag), clear both so flipping the switch always re-enables. If it's
    /// currently enabled, set the per-session flag (cwd-wide disable lives
    /// behind `/crier off` only).
    private func toggleActive(session s: CrierSession) {
        let cwd = s.cwd ?? ""
        if isActiveEnabled(session: s) {
            CrierEmitCore.setSessionDisabled(s.id, cwd: cwd)
        } else {
            CrierEmitCore.clearSessionDisabled(s.id)
            if !cwd.isEmpty { CrierEmitCore.clearCwdDisabled(cwd) }
        }
        reload()
    }

    private func reload() {
        let cwds = CrierEmitCore.disabledCwds()
        disabledCwdKnown = cwds.known
        disabledCwdUnknown = cwds.unknownDigests
        disabledSessions = CrierEmitCore.disabledSessions()
    }
}

private struct ConversationRow: View {
    let title: String
    let subtitle: String
    let enabled: Bool
    let onToggle: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                if !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer(minLength: 8)
            Toggle("", isOn: Binding(
                get: { enabled },
                set: { _ in onToggle() }
            ))
            .toggleStyle(.switch)
            .labelsHidden()
        }
        .padding(.vertical, 2)
    }
}

// MARK: - SwiftUI helpers

// AppKit visual effect (vibrancy / blur) bridged into SwiftUI so the panel
// gets the same translucent look macOS HUDs and command palettes use.
struct VisualEffectView: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    let blendingMode: NSVisualEffectView.BlendingMode
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = material
        v.blendingMode = blendingMode
        v.state = .active
        v.isEmphasized = true
        return v
    }
    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

// Click-drag moves the borderless `NSPanel` (same as a title bar). Optional
// `onTap` keeps tap-to-dismiss when the gesture barely moves — used on the
// badge title next to the icon.
//
// `mouseDownCanMoveWindow` isn't reliably honored when this NSView is hosted
// inside SwiftUI's NSHostingView under a `.nonactivatingPanel`: AppKit
// dispatches mouseDown to us instead of running its own drag session, and
// `super.mouseDown` doesn't start one. So we call `performDrag` ourselves —
// it's synchronous, returning once the user releases, and screen coords
// before/after tell us whether it was a tap or a real drag.
private final class WindowDragChromeView: NSView {
    var onTap: (() -> Void)?

    override func mouseDown(with event: NSEvent) {
        let start = NSEvent.mouseLocation
        window?.performDrag(with: event)
        let end = NSEvent.mouseLocation
        let dx = end.x - start.x, dy = end.y - start.y
        if (dx * dx + dy * dy) < 36, let onTap {
            onTap()
        }
    }
}

struct WindowDragRegion: NSViewRepresentable {
    var onTap: (() -> Void)? = nil

    func makeNSView(context: Context) -> NSView {
        let v = WindowDragChromeView()
        v.onTap = onTap
        return v
    }

    func updateNSView(_ v: NSView, context: Context) {
        (v as? WindowDragChromeView)?.onTap = onTap
    }
}

// Each visible element (badge pill, message card, input card) gets this:
// a self-contained card with its own background + rounded corners +
// hairline stroke. Older versions used `NSVisualEffectView` with
// `.behindWindow` blending so the desktop showed through, which made
// every screenshot look different — dark terminal behind → dark
// panel, bright IDE/browser behind → washed-out tinted panel.
//
// New approach: `.menu` material with `.withinWindow` blending. The
// material paints a consistent light vibrancy regardless of the
// desktop, but unlike `.behindWindow` mode it doesn't sample the
// desktop colours at all — it only blends within the window's own
// content. A solid `controlBackgroundColor` underneath provides the
// floor color so even if vibrancy is disabled (Reduce Transparency
// system setting), the panel still has a consistent light surface.
extension View {
    func crierCard(cornerRadius: CGFloat = 14) -> some View {
        self
            .background {
                ZStack {
                    // Solid base — system-adaptive surface color.
                    // In dark mode this is a darkish gray; in light
                    // mode a light gray. Either way, consistent
                    // across desktops because no transparency.
                    Color(nsColor: .controlBackgroundColor)
                    // Light frosted vibrancy on top, blending
                    // *within* the window only. No desktop bleed.
                    VisualEffectView(material: .menu, blendingMode: .withinWindow)
                        .opacity(0.85)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
            )
    }
}

// Pill-shaped key cap, e.g. "esc" / "↩" hint next to a button label.
struct Keycap: View {
    let label: String
    var emphasis: Bool = false
    var body: some View {
        Text(label)
            .font(.system(size: 11, weight: .medium, design: .rounded))
            .foregroundStyle(emphasis ? .primary : .secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 5).fill(.quaternary))
    }
}

// Top badge: brand icon (lobe-icons) + project title. Drag the title (or the
// padded area beside it) to move the panel. The icon is the disable affordance:
// hover morphs to X, click opens the "Disable Crier for this session?" dialog
// (mirrors Superwhisper). One-shot dismiss without disabling lives on the
// "Dismiss" button / Esc in the input card. Clicks on the title area do
// nothing — only drag-to-move — so users don't accidentally trigger the
// dialog when reaching for the drag handle.
struct AgentBadge: View {
    let agent: String
    let project: String
    let onClose: () -> Void
    @State private var hovered: Bool = false

    var body: some View {
        HStack(spacing: 6) {
            Button(action: onClose) {
                ZStack {
                    if hovered {
                        Image(systemName: "xmark")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.primary)
                            .frame(width: 18, height: 18)
                            .background(.quaternary, in: Circle())
                            .transition(.opacity.combined(with: .scale))
                    } else {
                        agentIcon
                            .frame(width: 18, height: 18)
                            .transition(.opacity.combined(with: .scale))
                    }
                }
                .animation(.easeOut(duration: 0.12), value: hovered)
            }
            .buttonStyle(.plain)

            Text(project.isEmpty ? agent : project)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .padding(.trailing, 2)
                .frame(minHeight: 18, alignment: .leading)
        }
        .background(WindowDragRegion())
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .crierCard(cornerRadius: 100)
        .onHover { hovered = $0 }
    }

    @ViewBuilder
    private var agentIcon: some View {
        let assetName = iconAssetName(for: agent)
        if !assetName.isEmpty, let img = AgentBrandIcon.image(named: assetName) {
            // Single-color SVGs (claude.svg) are loaded as template images
            // so SwiftUI's foregroundStyle tints them. The colored ones
            // (claudecode-color, codex-color, opencode) keep their own fill.
            if let tint = monochromeTint(for: assetName) {
                let templated: NSImage = {
                    let copy = img.copy() as? NSImage ?? img
                    copy.isTemplate = true
                    return copy
                }()
                Image(nsImage: templated)
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(tint)
            } else {
                Image(nsImage: img)
                    .resizable()
                    .scaledToFit()
            }
        } else {
            ZStack {
                Circle().fill(LinearGradient(
                    colors: fallbackColors(for: agent),
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing))
                Text(initial(for: agent))
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
            }
        }
    }

    private func iconAssetName(for a: String) -> String {
        switch a {
        case "claude-code": return "claude"
        case "codex":       return "codex-color"
        case "cursor":      return "cursor"
        case "opencode":    return "opencode"
        default:            return ""
        }
    }

    // Returns a tint color for monochrome (single-fill, currentColor) SVGs.
    // Colored multi-fill SVGs return nil and render as-is.
    private func monochromeTint(for asset: String) -> Color? {
        switch asset {
        case "claude": return Color(red: 0.85, green: 0.45, blue: 0.27)  // Anthropic brand orange
        default:       return nil
        }
    }
    private func initial(for a: String) -> String {
        switch a {
        case "claude-code": return "C"
        case "codex":       return "X"
        case "cursor":      return "U"
        case "opencode":    return "O"
        case "aider":       return "A"
        default:            return String(a.first ?? "?").uppercased()
        }
    }
    private func fallbackColors(for a: String) -> [Color] {
        switch a {
        case "claude-code": return [.orange, .red]
        case "codex":       return [.green, .teal]
        case "cursor":      return [.blue, .purple]
        case "opencode":    return [.indigo, .blue]
        case "aider":       return [.pink, .purple]
        default:            return [.gray, .gray.opacity(0.6)]
        }
    }
}

/// Horizontal chips to pick which parallel agent/session is active for Send / Cancel / Disable.
private struct SessionTabStrip: View {
    @ObservedObject var state: CrierState

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(state.sessions) { sess in
                    let selected = sess.id == state.selectedSessionKey
                    Button {
                        state.selectSession(id: sess.id)
                    } label: {
                        Text(sess.tabLabel)
                            .font(.system(size: 11, weight: selected ? .semibold : .regular))
                            .lineLimit(1)
                            .foregroundStyle(.primary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(
                                selected ? Color.primary.opacity(0.12) : Color.clear,
                                in: Capsule()
                            )
                            .overlay(
                                Capsule()
                                    .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1)
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

/// Renders the agent's last assistant message as a SwiftUI view tree
/// via `MarkdownContent`. Replaces the previous NSTextView pipeline
/// (NSAttributedString + NSTextBlock) so we can put real SwiftUI
/// `.background` + `.clipShape(RoundedRectangle)` on per-block code
/// containers — something NSAttributedString's per-glyph attributes
/// could only approximate as rectangles.
///
/// Sizing: the inner ScrollView lets the message area scroll
/// vertically when the panel hits its 720 pt height ceiling
/// (clamped in AppDelegate.applyContentSize). Below the ceiling the
/// panel grows naturally with content, reported up via
/// `PanelContentSizeKey`.
struct MessageCard: View {
    let text: String

    var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            MarkdownContent(markdown: text)
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
        }
        .frame(maxWidth: .infinity)
        .frame(maxHeight: 460)
        .crierCard()
    }
}

// PreferenceKey used to push the SwiftUI ideal size up to AppDelegate so it
// can resize the NSPanel. Without this, the panel stays stuck at its initial
// 240pt height and tall messages get clipped.
struct PanelContentSizeKey: PreferenceKey {
    static let defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        value = nextValue()
    }
}

struct CrierPanelView: View {
    @ObservedObject var state: CrierState
    @FocusState private var fieldFocused: Bool
    let onSubmit: () -> Void
    let onCancel: () -> Void
    let onDisableSession: () -> Void
    let onContentSize: (CGSize) -> Void

    private var selected: CrierSession? { state.selectedSession }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                AgentBadge(
                    agent: selected?.agentName ?? "claude-code",
                    project: selected?.projectName ?? "",
                    onClose: { state.showDisableDialog = true }
                )
                // Tab strip lives inline with the badge so a parallel
                // session shows up as a chip *next to* the active session
                // instead of taking a whole row above it. Hidden when
                // there's only one session — the badge already names it.
                if state.sessions.count > 1 {
                    SessionTabStrip(state: state)
                }
                Spacer(minLength: 8)
                if let kind = selected?.eventKind, !kind.isEmpty && kind != "turn_done" {
                    Text(kind)
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 4)
                        .crierCard(cornerRadius: 100)
                }
            }

            // Message bubble mirrors Superwhisper: always show the card so the
            // overlay reads as "alert + input". An empty `message` means
            // crier-emit found no last assistant line in the transcript (new
            // session, timing, or parse miss) — still show a placeholder.
            let msg = selected?.message ?? ""
            if !msg.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                MessageWithOptionalSummary(text: msg)
                    .id(msg)
            }

            inputCard
                .crierCard(cornerRadius: 16)
        }
        .padding(20)
        .frame(width: 640)
        .fixedSize(horizontal: false, vertical: true)
        .background(
            GeometryReader { proxy in
                Color.clear
                    .preference(key: PanelContentSizeKey.self, value: proxy.size)
            }
        )
        .onPreferenceChange(PanelContentSizeKey.self) { onContentSize($0) }
        .overlay {
            if state.showDisableDialog {
                DisableSessionDialog(
                    onConfirm: {
                        state.showDisableDialog = false
                        onDisableSession()
                    },
                    onLeave: {
                        state.showDisableDialog = false
                        onCancel()
                    },
                    onCancel: {
                        state.showDisableDialog = false
                    }
                )
            }
        }
    }

    private var inputCard: some View {
        let key = state.selectedSessionKey
        let draftEmpty = (key.flatMap { k in state.sessions.first { $0.id == k }?.replyDraft.isEmpty } ?? true)

        return VStack(alignment: .leading, spacing: 0) {
            if let k = key {
                ScrollView(.vertical) {
                    TextField(
                        "Type or dictate what you want changed.",
                        text: Binding(
                            get: { state.sessions.first { $0.id == k }?.replyDraft ?? "" },
                            set: { state.updateReplyDraft(sessionId: k, text: $0) }
                        ),
                        axis: .vertical
                    )
                    .textFieldStyle(.plain)
                    .font(.system(size: 14))
                    .lineLimit(2...)
                    .padding(16)
                    .focused($fieldFocused)
                    .onSubmit { onSubmit() }
                }
                .frame(maxHeight: 180)
            } else {
                Text("No session")
                    .foregroundStyle(.secondary)
                    .padding(16)
            }

            HStack(spacing: 10) {
                Spacer()

                Button(action: onCancel) {
                    HStack(spacing: 5) {
                        Text("Dismiss")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                        Keycap(label: "esc")
                    }
                }
                .buttonStyle(.plain)

                Button(action: onSubmit) {
                    HStack(spacing: 5) {
                        Text("Send")
                            .font(.system(size: 12, weight: .medium))
                        Keycap(label: "↩", emphasis: true)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(.tertiary, in: Capsule())
                }
                .buttonStyle(.plain)
                .disabled(draftEmpty)
                .opacity(draftEmpty ? 0.5 : 1)
                .keyboardShortcut(.return, modifiers: [.command])
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 10)

            // Hidden Esc handler — captures Escape regardless of focus.
            Button("", action: onCancel)
                .keyboardShortcut(.cancelAction)
                .opacity(0)
                .frame(width: 0, height: 0)
        }
        .onAppear { fieldFocused = true }
        .onChange(of: state.focusGen) { _, _ in fieldFocused = true }
    }
}

// Bundle IDs we never want to use as the keystroke target. Superwhisper pops
// its own window on Claude Code's Stop hook (its hook is wired alongside
// ours), and on activation it would otherwise become "frontmost" right when
// we want to post into the user's terminal. We continuously track the most
// recent app that isn't us and isn't on this list.
private let keystrokeTargetExclusions: Set<String> = [
    "com.superduper.superwhisper",
    "com.superduper.superwhisper.debug",
]

// Borderless NSPanel that *can* still become key (default borderless panels
// can't, which would prevent the SwiftUI TextField from receiving keys).
final class CrierBorderlessPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}


// Path of the global "Crier disabled" flag file. Mirrors the per-CWD pattern
// in confirmDisableSession() / crier-emit but applies project-wide. When
// present, every Stop hook short-circuits in crier-emit (post-update there)
// and the panel never pops. The status item toggles this file.
private let crierGlobalDisabledPath = "/tmp/crier-agent/disabled-global"

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let state = CrierState()
    var panel: NSPanel!
    var subscriberTask: Task<Void, Never>?
    var lastTerminalApp: NSRunningApplication?
    var statusItem: NSStatusItem?
    var statusDisableItem: NSMenuItem?
    var conversationsWindow: NSWindow?
    var setupWindow: NSWindow?
    // First show pins to screen bottom-right; subsequent shows keep
    // wherever the user dragged the panel. Resizes also avoid re-anchoring,
    // so a growing message doesn't snap the window back.
    var hasPositionedPanel = false

    // Install a minimal main menu — `.accessory` apps don't get one by default,
    // and without an Edit menu macOS doesn't route Cmd+C/V/X/A through the
    // responder chain. Result: copy from the message card and paste into the
    // reply TextField both silently fail. The menu items target `nil`, which
    // means "send to first responder" — NSTextView and NSTextField both
    // implement these standard selectors, so the routing is automatic.
    func installMainMenu() {
        let mainMenu = NSMenu()

        // App menu (required even if empty — system uses it for the app name
        // pseudo-header on the menu bar even though we're an accessory).
        let appItem = NSMenuItem()
        appItem.submenu = NSMenu()
        mainMenu.addItem(appItem)

        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo",   action: Selector(("undo:")),                          keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo",   action: Selector(("redo:")),                          keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut",    action: #selector(NSText.cut(_:)),                   keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy",   action: #selector(NSText.copy(_:)),                  keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste",  action: #selector(NSText.paste(_:)),                 keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)),         keyEquivalent: "a")
        editItem.submenu = editMenu
        mainMenu.addItem(editItem)

        NSApp.mainMenu = mainMenu
    }

    // Menu-bar status item — megaphone icon in the top-right, dropdown
    // exposes the global Disable toggle and a Quit entry. Sessions list /
    // per-session controls land in pass 2 once the daemon tracks them.
    func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            let cfg = NSImage.SymbolConfiguration(pointSize: 14, weight: .semibold)
            let icon = NSImage(systemSymbolName: "megaphone.fill",
                               accessibilityDescription: "Crier")?
                .withSymbolConfiguration(cfg)
            icon?.isTemplate = true  // adopts menu-bar tinting (light/dark)
            button.image = icon
            button.toolTip = "Crier"
        }

        let menu = NSMenu()

        let setupItem = NSMenuItem(
            title: "Setup…",
            action: #selector(openSetupWindow(_:)),
            keyEquivalent: ""
        )
        setupItem.target = self
        menu.addItem(setupItem)

        let conversationsItem = NSMenuItem(
            title: "Conversations…",
            action: #selector(openConversationsWindow(_:)),
            keyEquivalent: ","
        )
        conversationsItem.target = self
        menu.addItem(conversationsItem)

        menu.addItem(.separator())

        let disableItem = NSMenuItem(
            title: "Disable Crier (Global)",
            action: #selector(toggleGlobalDisable(_:)),
            keyEquivalent: ""
        )
        disableItem.target = self
        statusDisableItem = disableItem
        menu.addItem(disableItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(
            title: "Quit Crier",
            action: #selector(quitApp(_:)),
            keyEquivalent: "q"
        )
        quitItem.target = self
        menu.addItem(quitItem)

        item.menu = menu
        statusItem = item
        refreshGlobalDisableState()
    }

    @objc private func toggleGlobalDisable(_ sender: Any?) {
        let fm = FileManager.default
        if fm.fileExists(atPath: crierGlobalDisabledPath) {
            try? fm.removeItem(atPath: crierGlobalDisabledPath)
            uiLog("global disable cleared")
        } else {
            try? fm.createDirectory(atPath: "/tmp/crier-agent",
                                     withIntermediateDirectories: true)
            fm.createFile(atPath: crierGlobalDisabledPath, contents: nil)
            uiLog("global disable set")
            // Hide any currently-shown panel so the user sees the toggle take
            // effect immediately.
            state.removeAllSessions()
            hide()
        }
        refreshGlobalDisableState()
    }

    @objc private func quitApp(_ sender: Any?) {
        NSApp.terminate(nil)
    }

    // Lazily create a single Conversations window. Subsequent menu clicks
    // bring it forward instead of stacking duplicates. We're an .accessory
    // app, so explicit `activate(ignoringOtherApps:)` is needed for the
    // window to take focus.
    @objc private func openConversationsWindow(_ sender: Any?) {
        if let w = conversationsWindow {
            w.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let view = ConversationsView(state: state)
        let hosting = NSHostingController(rootView: view)
        let w = NSWindow(contentViewController: hosting)
        w.title = "Crier"
        w.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        w.setContentSize(NSSize(width: 480, height: 520))
        w.center()
        w.isReleasedWhenClosed = false
        conversationsWindow = w
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // Setup window — same lazy/single-instance pattern as the Conversations
    // window. Auto-shown on first launch when any detected agent isn't wired
    // (see applicationDidFinishLaunching), also reachable from the status
    // menu's "Setup…" item.
    @objc func openSetupWindow(_ sender: Any?) {
        if let w = setupWindow {
            w.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 540, height: 380),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        let hosting = NSHostingController(rootView: SetupView { [weak w] in
            w?.close()
        })
        w.contentViewController = hosting
        w.title = "Crier — Setup"
        w.center()
        w.isReleasedWhenClosed = false
        setupWindow = w
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func refreshGlobalDisableState() {
        let isDisabled = FileManager.default.fileExists(atPath: crierGlobalDisabledPath)
        statusDisableItem?.title = isDisabled
            ? "Enable Crier (Global)"
            : "Disable Crier (Global)"
        statusDisableItem?.state = isDisabled ? .on : .off
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        uiLog("applicationDidFinishLaunching — endpoint=\(endpoint)")
        installMainMenu()
        installStatusItem()
        let view = CrierPanelView(
            state: state,
            onSubmit: { [weak self] in self?.submit() },
            onCancel: { [weak self] in self?.cancel() },
            onDisableSession: { [weak self] in self?.confirmDisableSession() },
            onContentSize: { [weak self] size in self?.applyContentSize(size) }
        )
        let hosting = NSHostingView(rootView: view)

        panel = CrierBorderlessPanel(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 240),
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.contentView = hosting
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = false
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false  // each card draws its own shadow
        panel.isReleasedWhenClosed = false
        // Don't clip the content view — each card already self-clips with
        // rounded corners and we need shadow overflow to render.

        // Start the embedded daemon. If a standalone `crier-daemon` is
        // already serving the port, this silently no-ops and the UI just
        // subscribes to that one. Either way, no separate launch step.
        CrierServer.startInBackground()

        // Seed lastTerminalApp with whatever's currently frontmost (likely
        // the terminal that just spawned us via `open Crier.app`).
        if let initial = NSWorkspace.shared.frontmostApplication, isValidKeystrokeTarget(initial) {
            lastTerminalApp = initial
        }

        // Track future activations, skipping ourselves and known offenders.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            // Notification isn't Sendable, but we registered with queue: .main
            // so we're already on the main thread. Filter using only Sendable
            // primitives, then assumeIsolated to touch @MainActor state.
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            if app.processIdentifier == NSRunningApplication.current.processIdentifier { return }
            if let id = app.bundleIdentifier, keystrokeTargetExclusions.contains(id) { return }
            MainActor.assumeIsolated {
                self?.lastTerminalApp = app
            }
        }

        subscriberTask = Task { [weak self] in await self?.subscribeLoop() }

        // First-launch (or post-move) setup prompt. If any detected agent
        // isn't wired up to point at *this* Crier.app, pop the Setup window
        // so the user sees one-click "Install Selected" instead of an inert
        // menu-bar icon. Cheap to call — pure file checks.
        if Installer.anyAgentNeedsSetup() {
            DispatchQueue.main.async { [weak self] in
                self?.openSetupWindow(nil)
            }
        }
    }

    func isValidKeystrokeTarget(_ app: NSRunningApplication) -> Bool {
        if app.processIdentifier == NSRunningApplication.current.processIdentifier { return false }
        if let id = app.bundleIdentifier, keystrokeTargetExclusions.contains(id) { return false }
        return true
    }

    func positionBottomRight() {
        guard let screen = NSScreen.main else { return }
        let visible = screen.visibleFrame
        let size = panel.frame.size
        let origin = NSPoint(x: visible.maxX - size.width - 24, y: visible.minY + 24)
        panel.setFrameOrigin(origin)
    }

    // Resize the panel to match SwiftUI's reported ideal size. Width stays
    // pinned at 640 (the SwiftUI root sets it explicitly); height tracks
    // content but is clamped so a runaway message can't fill the screen.
    // `setContentSize` keeps origin.y (the bottom edge in AppKit coords)
    // fixed, so a growing message expands upward and the user's drag
    // position is preserved.
    func applyContentSize(_ size: CGSize) {
        guard size.height > 0 else { return }
        let height = min(max(size.height, 120), 720)
        let newSize = NSSize(width: 640, height: height)
        let currentContent = panel.contentRect(forFrameRect: panel.frame).size
        if abs(currentContent.height - height) < 0.5 {
            uiLog("applyContentSize — reported=\(size) current=\(currentContent) → unchanged")
            return
        }
        uiLog("applyContentSize — reported=\(size) current=\(currentContent) → resizing to \(newSize)")
        panel.setContentSize(newSize)
    }

    func showPanel() {
        if !hasPositionedPanel {
            positionBottomRight()
            hasPositionedPanel = true
        }
        panel.orderFrontRegardless()
        panel.makeKey()
        uiLog("showPanel — frame=\(panel.frame) key=\(panel.isKeyWindow) visible=\(panel.isVisible)")
    }

    func hide() {
        panel.orderOut(nil)
    }

    // Esc / Dismiss: closes the current session tab. For the legacy
    // hook-stdout path (cursor/codex/opencode) we POST an empty /reply so
    // the long-poll waiter wakes immediately. For the pre-queue path
    // (claude-code) we POST /reply/dismiss so any extended engage window
    // stops blocking the terminal. Other parallel sessions stay open.
    func cancel() {
        guard let s = state.selectedSession else {
            state.removeAllSessions()
            hide()
            return
        }
        if s.replyChannel == "hook-stdout-queue" {
            postDismiss(sessionId: s.id)
        } else if let rid = s.requestId {
            postReply(body: ["request_id": rid, "text": ""])
        }
        let sid = s.id
        state.removeSession(id: sid)
        if state.sessions.isEmpty {
            hide()
        } else {
            showPanel()
        }
    }

    // Confirmed-Disable handler — wired from the SwiftUI dialog's Disable
    // button. Touches /tmp/crier-agent/disabled-<md5(cwd)> to match the
    // `/crier off` skill behavior, releases the blocking hook with an empty
    // reply, removes the current session tab.
    func confirmDisableSession() {
        guard let s = state.selectedSession else { return }
        // Per-conversation disable — does NOT silence other agents in the
        // same project. Whole-project disable lives in `/crier off` and the
        // Conversations window's per-cwd toggle.
        CrierEmitCore.setSessionDisabled(s.id, cwd: s.cwd ?? "")

        if s.replyChannel == "hook-stdout-queue" {
            postDismiss(sessionId: s.id)
        } else if let rid = s.requestId {
            postReply(body: ["request_id": rid, "text": ""])
        }
        let sid = s.id
        state.removeSession(id: sid)
        if state.sessions.isEmpty {
            hide()
        } else {
            showPanel()
        }
    }

    private func postReply(body: [String: Any]) {
        guard let url = URL(string: "\(endpoint)/reply"),
              let data = try? JSONSerialization.data(withJSONObject: body) else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.httpBody = data
        URLSession.shared.dataTask(with: req).resume()
    }

    /// Convenience wrapper around `CrierEmitCore.buildReplyPost(...)` so
    /// the call site at submit() reads naturally. The function lives in
    /// CrierEmitCore (pure Foundation, no UI deps) so the routing logic
    /// is unit-testable from CrierEmitCoreTests without spawning the UI.
    static func buildReplyPost(
        endpoint: String,
        sessionId: String,
        text: String,
        replyChannel: String?,
        requestId: String?,
        replyTarget: String?
    ) -> CrierEmitCore.ReplyPostPlan? {
        CrierEmitCore.buildReplyPost(
            endpoint: endpoint,
            sessionId: sessionId,
            text: text,
            replyChannel: replyChannel,
            requestId: requestId,
            replyTarget: replyTarget
        )
    }

    /// Pre-queue path dismiss. Clears any pending engage window on the
    /// daemon so a sync claude-code Stop hook stops blocking the terminal.
    private func postDismiss(sessionId: String) {
        guard let url = URL(string: "\(endpoint)/reply/dismiss"),
              let data = try? JSONSerialization.data(withJSONObject: ["session_id": sessionId]) else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.httpBody = data
        URLSession.shared.dataTask(with: req).resume()
    }


    func subscribeLoop() async {
        let url = URL(string: "\(endpoint)/current?wait=30")!
        while !Task.isCancelled {
            var req = URLRequest(url: url)
            req.timeoutInterval = 35
            do {
                let (data, response) = try await URLSession.shared.data(for: req)
                guard let http = response as? HTTPURLResponse else { continue }
                if http.statusCode == 200 {
                    // Pass Data (Sendable) across the boundary; parse on main
                    // so [String: Any] never crosses an isolation domain.
                    DispatchQueue.main.async { [weak self] in
                        guard let self else { return }
                        if let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
                            self.handleEvent(obj)
                        }
                    }
                }
                // 204 = timeout, just loop
            } catch {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }

    func handleEvent(_ obj: [String: Any]) {
        let kind = obj["event"] as? String ?? ""
        let messageLen = (obj["message"] as? String)?.count ?? 0
        let agent = obj["agent"] as? String ?? "?"
        let cwd = obj["cwd"] as? String ?? "?"
        uiLog("handleEvent — kind=\(kind) agent=\(agent) message=\(messageLen)chars cwd=\(cwd)")
        if kind == "dismiss" {
            if let sid = obj["session_id"] as? String, !sid.isEmpty {
                state.removeSession(id: sid)
            } else {
                state.removeAllSessions()
            }
            if state.sessions.isEmpty {
                hide()
            } else {
                showPanel()
            }
            return
        }

        state.upsertFromPayload(obj)
        // Pre-queue path: as soon as the panel pops for a turn_done,
        // engage the daemon's drain so it waits long enough for the
        // user to read the response and start typing. Without this,
        // the hook's 5 s base window would expire before a human can
        // realistically reach the keyboard. Esc/Dismiss in the panel
        // posts /reply/dismiss to cut the wait short on intent.
        if (obj["reply_channel"] as? String) == "hook-stdout-queue",
           let sid = obj["session_id"] as? String, !sid.isEmpty {
            CrierState.postReplyEngage(sessionId: sid)
        }
        if CrierEmptyMessageDiagnostic.shouldLogEmptyMessage(event: kind),
           CrierEmptyMessageDiagnostic.isEffectivelyEmptyMessage(obj["message"] as? String) {
            var rec: [String: Any] = [
                "ts": CrierEmptyMessageDiagnostic.nowTS(),
                "kind": "empty_message_panel",
                "source": "crier-ui",
                "agent": agent,
                "event": kind,
                "session_id": obj["session_id"] as? String ?? "?",
                "cwd": cwd,
            ]
            if let rid = obj["request_id"] as? String { rec["request_id"] = rid }
            rec["payload_keys"] = obj.keys.sorted().map { $0 }
            if let tp = obj["transcript_path"] as? String, !tp.isEmpty { rec["transcript_path"] = tp }
            rec["crier_ui_log"] = uiLogFilePath()
            rec["note"] = "Panel opened with an empty assistant `message`; correlate with empty_assistant_extract / empty_message_event lines with nearby ts."
            CrierEmptyMessageDiagnostic.append(record: rec)
        }
        showPanel()
    }

    func submit() {
        guard let s = state.selectedSession else { return }
        let text = s.replyDraft
        guard !text.isEmpty else { return }

        // Resolve the keystroke target with three layers of fallback:
        //  1. terminal_pid from the event — the GUI app hosting the agent,
        //     captured at hook time by walking the agent's parent chain.
        //     Reliable even when that terminal isn't frontmost.
        //  2. lastTerminalApp — most recent frontmost app excluding Crier and
        //     known offenders like Superwhisper.
        //  3. NSWorkspace.frontmostApplication — last resort.
        let targetApp: NSRunningApplication? = {
            if let pid = s.terminalPid, pid > 0,
               let app = NSRunningApplication(processIdentifier: pid) { return app }
            return lastTerminalApp ?? NSWorkspace.shared.frontmostApplication
        }()

        // Build URL + body via the testable helper so the submit() routing
        // is exercised by unit tests, not just at runtime in the app.
        let plan = AppDelegate.buildReplyPost(
            endpoint: endpoint,
            sessionId: s.id,
            text: text,
            replyChannel: s.replyChannel,
            requestId: s.requestId,
            replyTarget: s.replyTarget
        )

        if let plan {
            var req = URLRequest(url: plan.url)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "content-type")
            req.httpBody = plan.body
            // Log every Send so the UI log shows what was posted, win or
            // lose. Previously only failure paths logged, which made
            // "send didn't work" reports impossible to diagnose without
            // a network sniffer.
            let session = s.id
            let chForLog = s.replyChannel ?? "keystroke"
            uiLog("reply POST sending · session=\(session) · ch=\(chForLog) · url=\(plan.url.path) · bytes=\(plan.body.count)")
            URLSession.shared.dataTask(with: req) { _, resp, err in
                if let err {
                    uiLog("reply POST failed · session=\(session) · ch=\(chForLog) · err=\(err.localizedDescription)")
                } else if let http = resp as? HTTPURLResponse, http.statusCode != 200 {
                    uiLog("reply POST non-200 · session=\(session) · ch=\(chForLog) · status=\(http.statusCode)")
                } else {
                    uiLog("reply POST ok · session=\(session) · ch=\(chForLog)")
                }
            }.resume()
        } else {
            uiLog("reply POST skipped: invalid url or unencodable body · session=\(s.id)")
        }

        let channel = s.replyChannel
        let keystrokePath = channel != "hook-stdout"
            && channel != "hook-stdout-queue"
            && channel != "tmux"
            && channel != "http-poll"
        let removedId = s.id
        state.removeSession(id: removedId)
        if state.sessions.isEmpty {
            hide()
        } else {
            showPanel()
        }

        // Reply delivery routing:
        //   hook-stdout → crier-emit is blocking on /reply; daemon wakes it
        //                 and the hook prints {"decision":"block","reason":...}
        //                 which Claude Code uses as the next prompt. No
        //                 keystroke posting needed (and shouldn't be — this
        //                 path doesn't touch the user's terminal at all).
        //   tmux        → daemon runs `tmux send-keys`
        //   http-poll   → daemon wakes the OpenCode plugin's long-poll
        //   anything else (incl. nil) → CGEvent into the previously-frontmost
        //                 app. Legacy fallback for events without request_id.
        if keystrokePath {
            targetApp?.activate(options: [])
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
                postKeystrokes(text)
            }
        }
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
