import XCTest
@testable import CrierEmitCore

final class CrierEmitCoreTests: XCTestCase {
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
}
