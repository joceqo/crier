import AppKit
import ApplicationServices
import CoreGraphics
import CrierServer
import CryptoKit
import MarkdownToAttributedString
import Permiso
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

// Append a line to ~/.claude/crier-ui.log. Same shape as crier-emit's log so
// the two can be tail -f'd together when debugging end-to-end. Used to trace
// SwiftUI sizing, panel resizes, event handling, and reply delivery without
// needing to attach a debugger to the GUI process.
@inline(__always)
private func uiLog(_ msg: String) {
    let path = (NSHomeDirectory() as NSString).appendingPathComponent(".claude/crier-ui.log")
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

// Trigger the Accessibility permission flow. If untrusted, hand off to permiso
// (https://github.com/zats/permiso) which opens System Settings to the right
// pane and overlays a draggable Crier.app icon over the Settings window — the
// user drags it directly into the Accessibility list.
@discardableResult
private func ensureAccessibilityPermission() -> Bool {
    let trusted = AXIsProcessTrusted()
    if trusted { return true }
    DispatchQueue.main.async {
        PermisoAssistant.shared.present(panel: .accessibility)
    }
    return false
}

// Post a string to whatever app is frontmost, then press Return. Used when the
// event has no `reply_channel` (i.e. the agent isn't in tmux). Each character
// goes through CGEventKeyboardSetUnicodeString with virtualKey 0, which is the
// canonical "type this Unicode regardless of keyboard layout" trick.
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

final class CrierState: ObservableObject, @unchecked Sendable {
    @Published var title: String = "Crier"
    @Published var subtitle: String = ""
    @Published var projectName: String = ""
    @Published var agentName: String = "claude-code"
    @Published var message: String = ""
    @Published var replyText: String = ""
    @Published var focusGen: Int = 0
    @Published var showDisableDialog: Bool = false

    var sessionId: String?
    var requestId: String?
    var replyChannel: String?
    var replyTarget: String?
    var terminalPid: Int32?
    var cwd: String?
}

// SwiftUI confirmation dialog mirroring SW's "Disable for this session"
// styling: light material card, pill-shaped Cancel + destructive Disable
// buttons, body text with `/crier on` styled as a code chip.
struct DisableSessionDialog: View {
    let onConfirm: () -> Void
    let onCancel: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.35)
                .ignoresSafeArea()
                .onTapGesture { onCancel() }

            VStack(alignment: .leading, spacing: 14) {
                Text("Disable Crier for this session?")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.primary)

                bodyText

                HStack(spacing: 12) {
                    Button(action: onCancel) {
                        Text("Cancel")
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
            .crierCard(cornerRadius: 18, shadowRadius: 24)
        }
    }

    private var bodyText: Text {
        let intro = Text("Crier won't pop a panel for the rest of this session. To re-enable, run ")
            .foregroundStyle(.secondary)
            .font(.system(size: 13))
        let cmd = Text("/crier on")
            .font(.system(size: 12.5, design: .monospaced).weight(.medium))
            .foregroundStyle(.blue)
        let outro = Text(" in the terminal.")
            .foregroundStyle(.secondary)
            .font(.system(size: 13))
        return intro + cmd + outro
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
// - .menu material (light translucent), behind-window blending so the
//   terminal text is visible through it.
// - Rounded corners.
// - Drop shadow for the "floating" feel SW's UI has.
extension View {
    func crierCard(cornerRadius: CGFloat = 14, shadowRadius: CGFloat = 18) -> some View {
        self
            .background {
                VisualEffectView(material: .menu, blendingMode: .behindWindow)
            }
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(.white.opacity(0.06), lineWidth: 1)
            )
            .compositingGroup()
            .shadow(color: .black.opacity(0.28), radius: shadowRadius, x: 0, y: 6)
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
// padded area beside it) to move the panel. The icon is the close affordance:
// hover morphs to X, click closes. Clicks on the title area do nothing — only
// drag-to-move — so users don't accidentally dismiss the panel when reaching
// for the drag handle.
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
                .background(WindowDragRegion())
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .crierCard(cornerRadius: 100, shadowRadius: 10)
        .onHover { hovered = $0 }
    }

    @ViewBuilder
    private var agentIcon: some View {
        let assetName = iconAssetName(for: agent)
        if !assetName.isEmpty, let img = NSImage(named: assetName) {
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

// Renders the agent's last assistant message via NSTextView (reliable
// drag-to-select + Cmd+C inside the non-activating panel) with the markdown
// converted to an NSAttributedString by MarkdownToAttributedString. The
// converter uses Apple's swift-markdown parser under the hood, so fenced
// code blocks, lists, headings, blockquotes, and inline styles all become
// attributed-string runs we can hand directly to the text view.
struct MessageBody: NSViewRepresentable {
    let attributed: NSAttributedString

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true

        let tv = NSTextView()
        tv.isEditable = false
        tv.isSelectable = true
        tv.drawsBackground = false
        tv.textContainerInset = NSSize(width: 16, height: 16)
        tv.allowsUndo = false
        tv.font = .systemFont(ofSize: 14)
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.autoresizingMask = [.width]
        tv.textContainer?.widthTracksTextView = true
        tv.textContainer?.containerSize = NSSize(
            width: 0,
            height: CGFloat.greatestFiniteMagnitude
        )

        scroll.documentView = tv
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let tv = scroll.documentView as? NSTextView else { return }
        tv.textStorage?.setAttributedString(attributed)
    }
}

// Card sizes itself to the rendered markdown height, clamped to a sane
// range. A short reply ("Working. What can I help you with?") gets a tight
// pill; long replies cap at 240pt and scroll inside the NSTextView.
struct MessageCard: View {
    let text: String

    var body: some View {
        let attr = MessageCard.renderMarkdown(text)
        return MessageBody(attributed: attr)
            .frame(maxWidth: .infinity)
            .frame(height: MessageCard.clampedHeight(for: attr))
            .crierCard()
    }

    static func renderMarkdown(_ s: String) -> NSAttributedString {
        var styles = MarkdownStyles.default
        styles.setBaseAttribute(.font, NSFont.systemFont(ofSize: 14))
        styles.setBaseAttribute(.foregroundColor, NSColor.labelColor)
        return AttributedStringFormatter.format(markdown: s, styles: styles)
    }

    // Compute the rendered text height for our content width and clamp.
    // Width = panel(620) − root padding(2×20) − card text-container inset(2×16).
    static func clampedHeight(for attr: NSAttributedString) -> CGFloat {
        let textWidth: CGFloat = 620 - 40 - 32
        let bounding = attr.boundingRect(
            with: NSSize(width: textWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        )
        let raw = ceil(bounding.height) + 32  // re-add the inset for the card frame
        return Swift.min(Swift.max(raw, 56), 240)
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

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                AgentBadge(agent: state.agentName, project: state.projectName, onClose: onCancel)
                Spacer(minLength: 8)
                if !state.subtitle.isEmpty && state.subtitle != "turn_done" {
                    Text(state.subtitle)
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 4)
                        .crierCard(cornerRadius: 100, shadowRadius: 8)
                }
            }

            // Message bubble mirrors Superwhisper: always show the card so the
            // overlay reads as "alert + input". An empty `message` means
            // crier-emit found no last assistant line in the transcript (new
            // session, timing, or parse miss) — still show a placeholder.
            MessageCard(
                text: state.message.isEmpty
                    ? "No assistant message was read from the transcript. You can still reply below."
                    : state.message
            )

            inputCard
                .crierCard(cornerRadius: 16)
        }
        .padding(20)
        .frame(width: 620)
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
                    onCancel: {
                        state.showDisableDialog = false
                    }
                )
                .transition(.opacity.combined(with: .scale(scale: 0.95)))
            }
        }
        .animation(.easeOut(duration: 0.15), value: state.showDisableDialog)
    }

    private var inputCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            TextField("Type or dictate what you want changed.",
                      text: $state.replyText, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .lineLimit(2...8)
                .padding(16)
                .focused($fieldFocused)
                .onSubmit { onSubmit() }

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
                .disabled(state.replyText.isEmpty)
                .opacity(state.replyText.isEmpty ? 0.5 : 1)
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

final class AppDelegate: NSObject, NSApplicationDelegate, @unchecked Sendable {
    let state = CrierState()
    var panel: NSPanel!
    var subscriberTask: Task<Void, Never>?
    var lastTerminalApp: NSRunningApplication?
    var statusItem: NSStatusItem?
    var statusDisableItem: NSMenuItem?

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
            hide()
        }
        refreshGlobalDisableState()
    }

    @objc private func quitApp(_ sender: Any?) {
        NSApp.terminate(nil)
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
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 240),
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
            guard let self,
                  let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  self.isValidKeystrokeTarget(app) else { return }
            self.lastTerminalApp = app
        }

        ensureAccessibilityPermission()
        subscriberTask = Task { [weak self] in await self?.subscribeLoop() }
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
    // pinned at 620 (the SwiftUI root sets it explicitly); height tracks
    // content but is clamped so a runaway message can't fill the screen.
    // After resize we re-pin to bottom-right so the visible anchor doesn't
    // jump when the panel grows.
    func applyContentSize(_ size: CGSize) {
        guard size.height > 0 else { return }
        let height = min(max(size.height, 120), 720)
        let newSize = NSSize(width: 620, height: height)
        let currentContent = panel.contentRect(forFrameRect: panel.frame).size
        if abs(currentContent.height - height) < 0.5 {
            uiLog("applyContentSize — reported=\(size) current=\(currentContent) → unchanged")
            return
        }
        uiLog("applyContentSize — reported=\(size) current=\(currentContent) → resizing to \(newSize)")
        panel.setContentSize(newSize)
        if panel.isVisible { positionBottomRight() }
    }

    func showPanel() {
        positionBottomRight()
        panel.orderFrontRegardless()
        panel.makeKey()
        uiLog("showPanel — frame=\(panel.frame) key=\(panel.isKeyWindow) visible=\(panel.isVisible)")
    }

    func hide() {
        panel.orderOut(nil)
        state.replyText = ""
    }

    // Esc / Dismiss: hide the panel AND release any blocking hook so Claude
    // stops normally instead of waiting for the long-poll timeout.
    func cancel() {
        if let rid = state.requestId {
            postReply(body: ["request_id": rid, "text": ""])
        }
        state.requestId = nil
        hide()
    }

    // Confirmed-Disable handler — wired from the SwiftUI dialog's Disable
    // button. Touches /tmp/crier-agent/disabled-<md5(cwd)> to match the
    // `/crier off` skill behavior, releases the blocking hook with an empty
    // reply, hides the panel.
    func confirmDisableSession() {
        guard let cwd = state.cwd, !cwd.isEmpty else { return }
        let digest = Insecure.MD5.hash(data: Data(cwd.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        let path = "/tmp/crier-agent/disabled-\(hex)"
        try? FileManager.default.createDirectory(atPath: "/tmp/crier-agent",
                                                 withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: path, contents: nil)

        if let rid = state.requestId {
            postReply(body: ["request_id": rid, "text": ""])
        }
        state.requestId = nil
        hide()
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
            hide()
            return
        }
        state.title = obj["title"] as? String ?? "Crier"
        state.subtitle = kind
        state.message = obj["message"] as? String ?? ""
        state.agentName = obj["agent"] as? String ?? "claude-code"
        if let cwd = obj["cwd"] as? String, !cwd.isEmpty {
            state.projectName = (cwd as NSString).lastPathComponent
        } else {
            state.projectName = ""
        }
        state.cwd = obj["cwd"] as? String
        state.sessionId = obj["session_id"] as? String
        state.requestId = obj["request_id"] as? String
        state.replyChannel = obj["reply_channel"] as? String
        state.replyTarget = obj["reply_target"] as? String
        if let tp = obj["terminal_pid"] as? Int { state.terminalPid = Int32(tp) } else { state.terminalPid = nil }
        state.focusGen += 1
        showPanel()
    }

    func submit() {
        let text = state.replyText
        guard !text.isEmpty else { return }

        // Resolve the keystroke target with three layers of fallback:
        //  1. terminal_pid from the event — the GUI app hosting the agent,
        //     captured at hook time by walking the agent's parent chain.
        //     Reliable even when that terminal isn't frontmost.
        //  2. lastTerminalApp — most recent frontmost app excluding Crier and
        //     known offenders like Superwhisper.
        //  3. NSWorkspace.frontmostApplication — last resort.
        let targetApp: NSRunningApplication? = {
            if let pid = state.terminalPid, pid > 0,
               let app = NSRunningApplication(processIdentifier: pid) { return app }
            return lastTerminalApp ?? NSWorkspace.shared.frontmostApplication
        }()

        var body: [String: Any] = ["text": text]
        if let s = state.sessionId    { body["session_id"]  = s }
        if let r = state.requestId    { body["request_id"]  = r }
        if let c = state.replyChannel { body["channel"]     = c }
        if let t = state.replyTarget  { body["target"]      = t }

        if let url = URL(string: "\(endpoint)/reply"),
           let data = try? JSONSerialization.data(withJSONObject: body) {
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "content-type")
            req.httpBody = data
            URLSession.shared.dataTask(with: req).resume()
        }

        let channel = state.replyChannel
        hide()

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
        if channel != "hook-stdout" && channel != "tmux" && channel != "http-poll" {
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
