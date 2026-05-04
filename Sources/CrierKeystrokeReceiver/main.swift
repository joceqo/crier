// Test fixture: a minimal NSApp whose entire purpose is to receive CGEvent
// keystrokes into a focused NSTextView. Used by CrierKeystrokeE2ETests to
// validate that CrierUI's `postKeystrokes()` (the path Claude Code replies
// take) actually delivers text to a frontmost focused field.
//
// Usage:
//   crier-keystroke-receiver --ready=<path> --result=<path>
//
//   --ready  : the receiver writes "ready\n" to this path once its window
//              is key, focused, and the text view is first responder. The
//              test waits on this before posting keystrokes.
//   --result : the receiver continuously writes its text view contents to
//              this path (atomically) on a 100ms timer. The test polls
//              this file for the expected payload.
//
// The receiver runs until killed by the test (Process.terminate()).

import AppKit

let argv = CommandLine.arguments
guard let readyArg = argv.first(where: { $0.hasPrefix("--ready=") }),
      let resultArg = argv.first(where: { $0.hasPrefix("--result=") })
else {
    FileHandle.standardError.write(Data("usage: crier-keystroke-receiver --ready=<path> --result=<path>\n".utf8))
    exit(2)
}
let readyPath = String(readyArg.dropFirst("--ready=".count))
let resultPath = String(resultArg.dropFirst("--result=".count))

@MainActor
final class ReceiverDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    var textView: NSTextView!
    var dumpTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let frame = NSRect(x: 200, y: 200, width: 480, height: 200)
        window = NSWindow(
            contentRect: frame,
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Crier Keystroke Test Receiver"

        let scroll = NSScrollView(frame: window.contentView!.bounds)
        scroll.hasVerticalScroller = true
        scroll.autoresizingMask = [.width, .height]

        textView = NSTextView(frame: scroll.bounds)
        textView.isEditable = true
        textView.isSelectable = true
        textView.font = NSFont.userFixedPitchFont(ofSize: 13)
        textView.allowsUndo = false
        textView.autoresizingMask = [.width]
        scroll.documentView = textView
        window.contentView = scroll

        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(textView)
        NSApp.activate(ignoringOtherApps: true)

        // Confirm the field is actually first responder before signalling
        // ready — otherwise CGEvents posted by the test would route to
        // whoever holds focus instead.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            if self.window.firstResponder !== self.textView,
               let fr = self.window.firstResponder as? NSText {
                _ = fr // best-effort; NSTextView's field editor may take focus
            }
            try? "ready\n".write(toFile: readyPath, atomically: true, encoding: .utf8)
        }

        // Capture references directly so the timer body has no implicit
        // `self` and avoids strict-concurrency Sendable trouble.
        let tv = textView!
        nonisolated(unsafe) var lastSnapshot = ""
        dumpTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
            MainActor.assumeIsolated {
                let cur = tv.string
                if cur != lastSnapshot {
                    lastSnapshot = cur
                    try? cur.write(toFile: resultPath, atomically: true, encoding: .utf8)
                }
            }
        }
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let delegate = ReceiverDelegate()
app.delegate = delegate
app.run()
