import XCTest
import AppKit
import ApplicationServices

// End-to-end test for the CGEvent keystroke reply path that Claude Code
// (and the legacy fallback for any agent without a request_id) uses.
//
// CrierUI's `submit()` resolves a target NSRunningApplication, activates it,
// then 80ms later calls `postKeystrokes(text)` which posts CGEvents at the
// HID event tap. This test reproduces that flow against a controlled
// receiver process so we can assert the text actually lands.
//
// Skip conditions:
//   * AXIsProcessTrusted() == false — CGEvent at hidEventTap is silently
//     filtered without Accessibility permission. Grant the test runner
//     (xctest, or whichever binary is hosting these tests) permission via
//     System Settings → Privacy & Security → Accessibility, then retry.
//   * receiver binary not built — `swift build --product crier-keystroke-receiver`.
final class CrierKeystrokeE2ETests: XCTestCase {

    func testKeystrokeReplyDeliversToFocusedTextView() throws {
        guard AXIsProcessTrusted() else {
            throw XCTSkip("""
                Test runner lacks Accessibility permission — CGEventPost is silently
                filtered. Grant access in System Settings → Privacy & Security →
                Accessibility for the xctest / swift test binary, then retry.
                """)
        }

        guard let receiverBin = findReceiverBinary() else {
            throw XCTSkip("crier-keystroke-receiver binary not built — run `swift build --product crier-keystroke-receiver`")
        }

        let dir = FileManager.default.temporaryDirectory
        let readyPath = dir.appendingPathComponent("crier-ks-ready-\(UUID().uuidString)").path
        let resultPath = dir.appendingPathComponent("crier-ks-result-\(UUID().uuidString)").path
        defer {
            try? FileManager.default.removeItem(atPath: readyPath)
            try? FileManager.default.removeItem(atPath: resultPath)
        }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: receiverBin)
        proc.arguments = ["--ready=\(readyPath)", "--result=\(resultPath)"]
        try proc.run()
        defer {
            if proc.isRunning { proc.terminate() }
            proc.waitUntilExit()
        }

        // Wait for the receiver to put its window up and signal ready.
        let readyDeadline = Date().addingTimeInterval(5)
        while Date() < readyDeadline {
            if FileManager.default.fileExists(atPath: readyPath) { break }
            Thread.sleep(forTimeInterval: 0.05)
        }
        guard FileManager.default.fileExists(atPath: readyPath) else {
            return XCTFail("receiver never wrote ready sentinel — window never came up")
        }

        // Mimic CrierUI submit(): explicitly activate the target before
        // posting keys. Without this the receiver's window may not be the
        // frontmost first responder when CGEvents arrive.
        if let app = NSRunningApplication(processIdentifier: proc.processIdentifier) {
            app.activate(options: [])
        }
        // The same 80ms delay submit() uses, plus a little extra for the
        // window-server activation round-trip from a non-GUI test process.
        Thread.sleep(forTimeInterval: 0.4)

        let payload = "claude-test-\(UUID().uuidString.prefix(8))"
        postKeystrokesUnderTest(payload, pressReturn: true)

        // Poll the result file for up to 3s.
        let resultDeadline = Date().addingTimeInterval(3)
        var received = ""
        while Date() < resultDeadline {
            if let s = try? String(contentsOfFile: resultPath, encoding: .utf8), s.contains(payload) {
                received = s
                break
            }
            Thread.sleep(forTimeInterval: 0.1)
        }

        XCTAssertTrue(
            received.contains(payload),
            "keystrokes never reached the receiver's text view. last-seen contents:\n\(received)"
        )
    }

    // MARK: - Helpers

    /// Mirror of CrierUI/main.swift `postKeystrokes(_:pressReturn:)`. Kept
    /// inline rather than imported because the UI binary is not a library
    /// target. If the production impl changes, update here too.
    private func postKeystrokesUnderTest(_ text: String, pressReturn: Bool) {
        guard let source = CGEventSource(stateID: .hidSystemState) else {
            XCTFail("CGEventSource creation failed")
            return
        }
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
            CGEvent(keyboardEventSource: source, virtualKey: 0x24, keyDown: true)?.post(tap: .cghidEventTap)
            CGEvent(keyboardEventSource: source, virtualKey: 0x24, keyDown: false)?.post(tap: .cghidEventTap)
        }
    }

    private func findReceiverBinary() -> String? {
        let cwd = FileManager.default.currentDirectoryPath
        for rel in [".build/debug/crier-keystroke-receiver", ".build/release/crier-keystroke-receiver"] {
            let abs = cwd + "/" + rel
            if FileManager.default.fileExists(atPath: abs) { return abs }
        }
        return nil
    }
}
