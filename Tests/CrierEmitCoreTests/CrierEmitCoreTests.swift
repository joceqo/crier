import XCTest
@testable import CrierEmitCore

final class CrierEmitCoreTests: XCTestCase {

    // MARK: - UI Send routing (CrierEmitCore.buildReplyPost)
    //
    // Pin the body shape and endpoint URL CrierUI's submit() produces —
    // these are the regression guard for "Send from UI doesn't work"
    // reports. The assertions match exactly what CrierServer's handlers
    // expect; if either side drifts, this test fails before a user
    // notices the silently-broken Send.

    func testBuildReplyPostQueuePathPostsToSlashReplyQueueWithSessionAndText() throws {
        let plan = try XCTUnwrap(CrierEmitCore.buildReplyPost(
            endpoint: "http://127.0.0.1:8731",
            sessionId: "claude-code-abc-123",
            text: "user reply via overlay",
            replyChannel: "hook-stdout-queue",  // pre-queue path
            requestId: "C8E1A7C5-…",            // present, but must NOT be sent
            replyTarget: nil
        ))

        XCTAssertEqual(plan.url.absoluteString, "http://127.0.0.1:8731/reply/queue")

        let parsed = try XCTUnwrap(
            JSONSerialization.jsonObject(with: plan.body) as? [String: Any]
        )
        XCTAssertEqual(parsed["session_id"] as? String, "claude-code-abc-123")
        XCTAssertEqual(parsed["text"] as? String, "user reply via overlay")
        // Critical: queue path must NOT carry request_id / channel /
        // target — CrierServer's handlePostReplyQueue keys on session_id
        // only. Sending request_id here would route the body to the
        // legacy ReplyHub.deliver path and the drain on session_id
        // would never wake.
        XCTAssertNil(parsed["request_id"])
        XCTAssertNil(parsed["channel"])
        XCTAssertNil(parsed["target"])
    }

    func testBuildReplyPostLegacyPathPostsToSlashReplyWithRequestIdAndChannel() throws {
        let plan = try XCTUnwrap(CrierEmitCore.buildReplyPost(
            endpoint: "http://127.0.0.1:8731",
            sessionId: "cursor-xyz-789",
            text: "two",
            replyChannel: "hook-stdout",        // legacy path (cursor/codex/opencode)
            requestId: "12345-67890",
            replyTarget: nil
        ))

        XCTAssertEqual(plan.url.absoluteString, "http://127.0.0.1:8731/reply")

        let parsed = try XCTUnwrap(
            JSONSerialization.jsonObject(with: plan.body) as? [String: Any]
        )
        XCTAssertEqual(parsed["session_id"] as? String, "cursor-xyz-789")
        XCTAssertEqual(parsed["text"] as? String, "two")
        XCTAssertEqual(parsed["request_id"] as? String, "12345-67890")
        XCTAssertEqual(parsed["channel"] as? String, "hook-stdout")
    }

    func testBuildReplyPostTmuxChannelCarriesTarget() throws {
        let plan = try XCTUnwrap(CrierEmitCore.buildReplyPost(
            endpoint: "http://127.0.0.1:8731",
            sessionId: "claude-code-tmux",
            text: "ls -la",
            replyChannel: "tmux",
            requestId: nil,
            replyTarget: "main:0.0"
        ))
        let parsed = try XCTUnwrap(
            JSONSerialization.jsonObject(with: plan.body) as? [String: Any]
        )
        XCTAssertEqual(parsed["channel"] as? String, "tmux")
        XCTAssertEqual(parsed["target"] as? String, "main:0.0")
    }

    func testBuildReplyPostNilChannelFallsThroughToLegacyPath() throws {
        // A session that arrived without a reply_channel (e.g., a very
        // old payload) must fall through to /reply, not accidentally
        // hit the queue endpoint.
        let plan = try XCTUnwrap(CrierEmitCore.buildReplyPost(
            endpoint: "http://127.0.0.1:8731",
            sessionId: "anon",
            text: "hello",
            replyChannel: nil,
            requestId: "rid",
            replyTarget: nil
        ))
        XCTAssertEqual(plan.url.absoluteString, "http://127.0.0.1:8731/reply")
    }

    // MARK: - existing tests

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

    func testGlobalPauseActiveUntilFutureUnixStamp() throws {
        let p = CrierEmitCore.globalPauseUntilPath
        defer { try? FileManager.default.removeItem(atPath: p) }
        let future = Int(Date().timeIntervalSince1970) + 3600
        try FileManager.default.createDirectory(
            atPath: CrierEmitCore.crierAgentDir,
            withIntermediateDirectories: true
        )
        FileManager.default.createFile(atPath: p, contents: "\(future)\n".data(using: .utf8))
        XCTAssertTrue(CrierEmitCore.isGlobalPauseActive())
        XCTAssertTrue(CrierEmitCore.isGlobalSilenceActive())
    }

    func testGlobalPauseExpiredDeletesFlag() throws {
        let p = CrierEmitCore.globalPauseUntilPath
        defer { try? FileManager.default.removeItem(atPath: p) }
        let past = Int(Date().timeIntervalSince1970) - 30
        try FileManager.default.createDirectory(
            atPath: CrierEmitCore.crierAgentDir,
            withIntermediateDirectories: true
        )
        FileManager.default.createFile(atPath: p, contents: "\(past)\n".data(using: .utf8))
        XCTAssertFalse(CrierEmitCore.isGlobalPauseActive())
        XCTAssertFalse(FileManager.default.fileExists(atPath: p))
    }

    func testGlobalSilenceWithoutPauseOrDisable() throws {
        let g = CrierEmitCore.globalDisabledPath
        let p = CrierEmitCore.globalPauseUntilPath
        defer {
            try? FileManager.default.removeItem(atPath: g)
            try? FileManager.default.removeItem(atPath: p)
        }
        if FileManager.default.fileExists(atPath: g) { try? FileManager.default.removeItem(atPath: g) }
        if FileManager.default.fileExists(atPath: p) { try? FileManager.default.removeItem(atPath: p) }
        XCTAssertFalse(CrierEmitCore.isGlobalSilenceActive())
    }

    // MARK: - Summary affordance gating

    func testSummaryThresholdConstantIs400() {
        XCTAssertEqual(CrierEmitCore.summarizeMinimumChars, 400)
    }

    func testShouldOfferSummaryRequiresModelAvailable() {
        XCTAssertFalse(
            CrierEmitCore.shouldOfferSummary(textLength: 1000, modelAvailable: false),
            "long text + no model → no chip"
        )
        XCTAssertTrue(
            CrierEmitCore.shouldOfferSummary(textLength: 1000, modelAvailable: true),
            "long text + model available → chip"
        )
    }

    func testShouldOfferSummaryRespectsLengthThreshold() {
        XCTAssertFalse(
            CrierEmitCore.shouldOfferSummary(textLength: 0, modelAvailable: true),
            "empty text never gets a chip"
        )
        XCTAssertFalse(
            CrierEmitCore.shouldOfferSummary(textLength: 399, modelAvailable: true),
            "just below threshold → no chip"
        )
        XCTAssertTrue(
            CrierEmitCore.shouldOfferSummary(textLength: 400, modelAvailable: true),
            "exactly at threshold → chip"
        )
        XCTAssertTrue(
            CrierEmitCore.shouldOfferSummary(textLength: 401, modelAvailable: true),
            "just above threshold → chip"
        )
    }
}
