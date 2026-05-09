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

    // MARK: - Cursor envelope (role:"assistant")
    //
    // Cursor's JSONL transcripts use `"role":"assistant"` at the top level
    // instead of Claude Code's `"type":"assistant"`. The content grammar
    // inside `message.content` is identical (array of `{type:"text",...}`
    // and `{type:"tool_use",...}` blocks), so detection just needs to
    // accept either envelope key.

    func testCursorRoleEnvelopeWithTextBlock() {
        let transcript = #"""
        {"role":"user","message":{"content":[{"type":"text","text":"hi"}]}}
        {"role":"assistant","message":{"content":[{"type":"text","text":"hello from cursor"}]}}
        """#
        XCTAssertEqual(
            CrierEmitCore.extractLastAssistantMessage(transcript: transcript),
            "hello from cursor"
        )
    }

    func testCursorRoleEnvelopeMixedTextAndToolUse() {
        // Verbatim shape from /Users/joce/.cursor/projects/.../*.jsonl: a
        // text block followed by a tool_use (Cursor's tool names differ from
        // Claude's — `ReadFile` here — but that's irrelevant since we filter
        // on block.type, not block.name).
        let transcript = #"""
        {"role":"assistant","message":{"content":[{"type":"text","text":"You're seeing a harness page"},{"type":"tool_use","name":"ReadFile","input":{"path":"/tmp/x"}}]}}
        """#
        XCTAssertEqual(
            CrierEmitCore.extractLastAssistantMessage(transcript: transcript),
            "You're seeing a harness page"
        )
    }

    func testCursorToolUseOnlyTurnSkipsToPreviousText() {
        let transcript = #"""
        {"role":"assistant","message":{"content":[{"type":"text","text":"earlier visible answer"}]}}
        {"role":"assistant","message":{"content":[{"type":"tool_use","name":"Shell","input":{"command":"ls"}}]}}
        """#
        XCTAssertEqual(
            CrierEmitCore.extractLastAssistantMessage(transcript: transcript),
            "earlier visible answer"
        )
    }

    func testCursorEmptyFinalTurnReturnsEmpty() {
        // The "don't show stale text" invariant must hold across both
        // envelope shapes: an empty-text final assistant turn returns ""
        // even though there is a non-empty earlier turn.
        let transcript = #"""
        {"role":"assistant","message":{"content":[{"type":"text","text":"earlier"}]}}
        {"role":"assistant","message":{"content":[{"type":"text","text":""}]}}
        """#
        XCTAssertEqual(CrierEmitCore.extractLastAssistantMessage(transcript: transcript), "")
    }

    func testMixedClaudeCodeAndCursorEnvelopesInOneFile() {
        // Defensive: a single transcript containing both envelope shapes
        // (e.g. agent migration mid-session) still resolves the last
        // assistant turn correctly regardless of which envelope it uses.
        let transcript = #"""
        {"type":"assistant","message":{"content":"old claude turn"}}
        {"role":"assistant","message":{"content":[{"type":"text","text":"new cursor turn"}]}}
        """#
        XCTAssertEqual(
            CrierEmitCore.extractLastAssistantMessage(transcript: transcript),
            "new cursor turn"
        )
    }

    // MARK: - cwd recovery (CrierEmitCore.recoverCwdFromTranscript)
    //
    // Cursor reports its config dir as `cwd` in hook stdin; the project
    // dir is encoded in `transcript_path` as `<configDir>/projects/<encoded>/...`
    // where `<encoded>` is the absolute path with `/` replaced by `-`.
    // Decoding is filesystem-validated because real path components can
    // legitimately contain dashes (`tinker-app`).

    /// Builds an isolated temp "home" with a fake `.cursor` config dir
    /// and the requested project dirs created on real disk. Returns
    /// (home, configDir, cleanup). Tests pass `home` and `configDirNames`
    /// into recoverCwdFromTranscript so the helper probes our fake tree.
    private func makeFakeHome(projectSubpaths: [String], file: StaticString = #filePath, line: UInt = #line) -> (home: String, configDir: String, cleanup: () -> Void) {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("crier-recover-\(UUID().uuidString)")
            .standardizedFileURL
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let home = base.path
        let configDir = (home as NSString).appendingPathComponent(".cursor")
        try? FileManager.default.createDirectory(atPath: configDir, withIntermediateDirectories: true)
        for sub in projectSubpaths {
            let p = (home as NSString).appendingPathComponent(sub)
            do {
                try FileManager.default.createDirectory(atPath: p, withIntermediateDirectories: true)
            } catch {
                XCTFail("setup: could not create \(p): \(error)", file: file, line: line)
            }
        }
        return (home, configDir, { try? FileManager.default.removeItem(at: base) })
    }

    /// Encode an absolute path the way Cursor does (Claude Code prepends a
    /// leading `-`; we'll test both forms separately).
    private func cursorEncode(_ absolutePath: String) -> String {
        var s = absolutePath
        if s.hasPrefix("/") { s.removeFirst() }
        return s.replacingOccurrences(of: "/", with: "-")
    }

    func testRecoverCwdReturnsStdinWhenNotSuspicious() {
        // Claude Code passes a real project cwd. Even with a transcript
        // path present, the trust gate must leave stdinCwd untouched.
        let (home, _, cleanup) = makeFakeHome(projectSubpaths: ["Desktop/coding/crier"])
        defer { cleanup() }
        let realCwd = (home as NSString).appendingPathComponent("Desktop/coding/crier")
        let encoded = cursorEncode(realCwd)
        let transcript = "\(home)/.cursor/projects/\(encoded)/agent-transcripts/abc/abc.jsonl"
        let recovered = CrierEmitCore.recoverCwdFromTranscript(
            stdinCwd: realCwd,
            transcriptPath: transcript,
            home: home,
            configDirNames: [".cursor"]
        )
        XCTAssertEqual(recovered, realCwd)
    }

    func testRecoverCwdDecodesCleanProjectName() {
        // Cursor passes its own config dir as cwd; recover via transcript.
        let (home, configDir, cleanup) = makeFakeHome(projectSubpaths: ["Desktop/coding/mochi"])
        defer { cleanup() }
        let realProject = (home as NSString).appendingPathComponent("Desktop/coding/mochi")
        let encoded = cursorEncode(realProject)
        let transcript = "\(configDir)/projects/\(encoded)/agent-transcripts/abc/abc.jsonl"
        let recovered = CrierEmitCore.recoverCwdFromTranscript(
            stdinCwd: configDir,
            transcriptPath: transcript,
            home: home,
            configDirNames: [".cursor"]
        )
        XCTAssertEqual(recovered, realProject)
    }

    func testRecoverCwdDecodesNameWithDashGreedy() {
        // Real dir has a literal dash (`tinker-app`). Greedy walk must
        // pick `.../tinker-app`, not `.../tinker/app` (which doesn't exist).
        let (home, configDir, cleanup) = makeFakeHome(projectSubpaths: ["Desktop/coding/tinker-app"])
        defer { cleanup() }
        let realProject = (home as NSString).appendingPathComponent("Desktop/coding/tinker-app")
        let encoded = cursorEncode(realProject)
        let transcript = "\(configDir)/projects/\(encoded)/agent-transcripts/abc/abc.jsonl"
        let recovered = CrierEmitCore.recoverCwdFromTranscript(
            stdinCwd: configDir,
            transcriptPath: transcript,
            home: home,
            configDirNames: [".cursor"]
        )
        XCTAssertEqual(recovered, realProject)
    }

    func testRecoverCwdReturnsInputWhenNoCandidateExists() {
        // Encoded points to a non-existent path → return stdinCwd, never invent.
        let (home, configDir, cleanup) = makeFakeHome(projectSubpaths: [])
        defer { cleanup() }
        let bogus = (home as NSString).appendingPathComponent("Desktop/coding/never-existed")
        let encoded = cursorEncode(bogus)
        let transcript = "\(configDir)/projects/\(encoded)/agent-transcripts/abc/abc.jsonl"
        let recovered = CrierEmitCore.recoverCwdFromTranscript(
            stdinCwd: configDir,
            transcriptPath: transcript,
            home: home,
            configDirNames: [".cursor"]
        )
        XCTAssertEqual(recovered, configDir)
    }

    func testRecoverCwdReturnsInputWhenTranscriptPathIsSystemTemp() {
        // Cursor sometimes uses encoded names that are session UUIDs or
        // var-folders temp-path encodings. If no full-match candidate exists
        // under our (fake) home, recovery must bail out.
        let (home, configDir, cleanup) = makeFakeHome(projectSubpaths: [])
        defer { cleanup() }
        let transcript = "\(configDir)/projects/1777491472785/agent-transcripts/abc/abc.jsonl"
        let recovered = CrierEmitCore.recoverCwdFromTranscript(
            stdinCwd: configDir,
            transcriptPath: transcript,
            home: home,
            configDirNames: [".cursor"]
        )
        XCTAssertEqual(recovered, configDir)
    }

    func testRecoverCwdReturnsInputWhenNoTranscriptPath() {
        let (_, configDir, cleanup) = makeFakeHome(projectSubpaths: [])
        defer { cleanup() }
        let recovered = CrierEmitCore.recoverCwdFromTranscript(
            stdinCwd: configDir,
            transcriptPath: nil
        )
        XCTAssertEqual(recovered, configDir)
    }

    // MARK: - findCursorTranscriptPath
    //
    // Cursor's beforeShellExecution stdin sometimes omits transcript_path
    // (causes empty cursor tabs in the panel — no message text extracted).
    // Recovery walks ~/.cursor/projects/*/agent-transcripts/<sid>/<sid>.jsonl;
    // session_ids are UUIDs, globally unique, so first hit wins.

    private func makeFakeHomeWithCursorTranscripts(
        projectsAndSessions: [(project: String, sessions: [String])]
    ) -> (home: String, cleanup: () -> Void) {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("crier-cursor-tx-\(UUID().uuidString)")
            .standardizedFileURL
        let home = base.path
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let projectsDir = (home as NSString).appendingPathComponent(".cursor/projects")
        try? FileManager.default.createDirectory(atPath: projectsDir, withIntermediateDirectories: true)
        for (project, sessions) in projectsAndSessions {
            for sid in sessions {
                let dir = "\(projectsDir)/\(project)/agent-transcripts/\(sid)"
                try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
                let file = "\(dir)/\(sid).jsonl"
                FileManager.default.createFile(atPath: file, contents: Data("{}\n".utf8))
            }
        }
        return (home, { try? FileManager.default.removeItem(at: base) })
    }

    func testFindCursorTranscriptPathLocatesByGlobWithoutKnowingCwdEncoding() {
        let sid = "7a2ac714-eb64-4714-bd1b-9f2a6c557686"
        let (home, cleanup) = makeFakeHomeWithCursorTranscripts(projectsAndSessions: [
            ("Users-joce-Desktop-coding-mochi", [sid])
        ])
        defer { cleanup() }
        let recovered = CrierEmitCore.findCursorTranscriptPath(sessionId: sid, home: home)
        XCTAssertEqual(
            recovered,
            "\(home)/.cursor/projects/Users-joce-Desktop-coding-mochi/agent-transcripts/\(sid)/\(sid).jsonl"
        )
    }

    func testFindCursorTranscriptPathFindsCorrectProjectAmongMultiple() {
        let sid = "session-A"
        let (home, cleanup) = makeFakeHomeWithCursorTranscripts(projectsAndSessions: [
            ("project-foo", ["session-other"]),
            ("project-bar", [sid]),
            ("project-baz", []),
        ])
        defer { cleanup() }
        let recovered = CrierEmitCore.findCursorTranscriptPath(sessionId: sid, home: home)
        XCTAssertNotNil(recovered)
        XCTAssertTrue(recovered!.contains("/project-bar/"),
                      "expected project-bar path, got \(recovered ?? "nil")")
    }

    func testFindCursorTranscriptPathReturnsNilWhenSessionAbsent() {
        let (home, cleanup) = makeFakeHomeWithCursorTranscripts(projectsAndSessions: [
            ("project-foo", ["other-session"])
        ])
        defer { cleanup() }
        XCTAssertNil(CrierEmitCore.findCursorTranscriptPath(sessionId: "missing", home: home))
    }

    func testFindCursorTranscriptPathReturnsNilWhenEmptySessionId() {
        let (home, cleanup) = makeFakeHomeWithCursorTranscripts(projectsAndSessions: [])
        defer { cleanup() }
        XCTAssertNil(CrierEmitCore.findCursorTranscriptPath(sessionId: "", home: home))
    }

    func testFindCursorTranscriptPathReturnsNilWhenProjectsDirMissing() {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("crier-cursor-tx-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        // No ~/.cursor/projects in this fake home.
        XCTAssertNil(CrierEmitCore.findCursorTranscriptPath(sessionId: "any", home: base.path))
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
