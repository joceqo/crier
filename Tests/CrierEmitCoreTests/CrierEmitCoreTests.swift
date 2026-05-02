import XCTest
@testable import CrierEmitCore

final class CrierEmitCoreTests: XCTestCase {
    func testEmptyMessageDiagnosticFlags() {
        XCTAssertTrue(CrierEmptyMessageDiagnostic.shouldLogEmptyMessage(event: "turn_done"))
        XCTAssertTrue(CrierEmptyMessageDiagnostic.shouldLogEmptyMessage(event: "needs_permission"))
        XCTAssertTrue(CrierEmptyMessageDiagnostic.shouldLogEmptyMessage(event: "needs_input"))
        XCTAssertFalse(CrierEmptyMessageDiagnostic.shouldLogEmptyMessage(event: "dismiss"))
        XCTAssertTrue(CrierEmptyMessageDiagnostic.isEffectivelyEmptyMessage(nil))
        XCTAssertTrue(CrierEmptyMessageDiagnostic.isEffectivelyEmptyMessage("   \n"))
        XCTAssertFalse(CrierEmptyMessageDiagnostic.isEffectivelyEmptyMessage("x"))
    }

    func testExtractsLastAssistantStringContent() {
        let transcript = """
        {"type":"user","message":{"content":"hello"}}
        {"type":"assistant","message":{"content":"first answer"}}
        {"type":"assistant","message":{"content":"latest answer"}}
        """

        XCTAssertEqual(
            CrierEmitCore.extractLastAssistantMessage(transcript: transcript),
            "latest answer"
        )
    }

    func testSkipsToolOnlyAssistantEntryAndUsesPreviousText() {
        let transcript = """
        {"type":"assistant","message":{"content":[{"type":"text","text":"visible answer"}]}}
        {"type":"assistant","message":{"content":[{"type":"tool_use","name":"Read"}]}}
        """

        XCTAssertEqual(
            CrierEmitCore.extractLastAssistantMessage(transcript: transcript),
            "visible answer"
        )
    }

    func testJoinsMultipleTextBlocks() {
        let transcript = """
        {"type":"assistant","message":{"content":[{"type":"text","text":"part one"},{"type":"tool_use","name":"Edit"},{"type":"text","text":"part two"}]}}
        """

        XCTAssertEqual(
            CrierEmitCore.extractLastAssistantMessage(transcript: transcript),
            "part one\npart two"
        )
    }

    func testDisabledPathIsStableMd5OfCwd() {
        XCTAssertEqual(
            CrierEmitCore.disabledPath(forCwd: "/Users/joce/Desktop/coding/crier"),
            "/tmp/crier-agent/disabled-7aaec934eaa258933207266301745ba8"
        )
    }

    func testEmptyTranscriptReturnsEmpty() {
        XCTAssertEqual(CrierEmitCore.extractLastAssistantMessage(transcript: ""), "")
    }

    func testNoAssistantEntriesReturnsEmpty() {
        let transcript = """
        {"type":"user","message":{"content":"hello"}}
        {"type":"user","message":{"content":"still user"}}
        """
        XCTAssertEqual(CrierEmitCore.extractLastAssistantMessage(transcript: transcript), "")
    }

    func testMalformedJsonLinesAreSkipped() {
        let transcript = """
        {"type":"assistant","message":{"content":"good answer"}}
        NOT JSON AT ALL
        {broken
        """
        XCTAssertEqual(CrierEmitCore.extractLastAssistantMessage(transcript: transcript), "good answer")
    }

    func testLastAssistantWithEmptyStringContentReturnsEmpty() {
        let transcript = """
        {"type":"assistant","message":{"content":"previous answer"}}
        {"type":"assistant","message":{"content":""}}
        """
        XCTAssertEqual(CrierEmitCore.extractLastAssistantMessage(transcript: transcript), "")
    }

    func testAllEmptyTextBlocksReturnEmpty() {
        let transcript = """
        {"type":"assistant","message":{"content":"fallback"}}
        {"type":"assistant","message":{"content":[{"type":"text","text":""},{"type":"text","text":""}]}}
        """
        XCTAssertEqual(CrierEmitCore.extractLastAssistantMessage(transcript: transcript), "")
    }

    func testIsGloballyDisabledReturnsFalseWhenFlagAbsent() {
        // The flag path should not exist in a clean test environment.
        let flagPath = CrierEmitCore.globalDisabledPath
        let exists = FileManager.default.fileExists(atPath: flagPath)
        if exists { try? FileManager.default.removeItem(atPath: flagPath) }
        XCTAssertFalse(CrierEmitCore.isGloballyDisabled())
    }
}
