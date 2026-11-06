import Foundation
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

final class ChatRewindForkTests: XCTestCase, @unchecked Sendable {
    private let userID = "11111111-1111-4111-8111-111111111111"
    private let assistantID = "22222222-2222-4222-8222-222222222222"
    private func events(_ provider: HootChatProvider) -> [HootChatEvent] {
        [.init(conversationID: "c", turnID: userID, sequence: 1, provider: provider, record: .text(.user, "first")),
         .init(conversationID: "c", turnID: userID, sequence: 2, provider: provider,
               record: .init(.message, id: "assistant-api", value: .object([.init("text", .string("answer")), .init("providerMessageId", .string(assistantID))]))),
         .init(conversationID: "c", turnID: userID, sequence: 3, provider: provider, record: .init(.completed, value: .object([.init("id", .string("provider-turn"))])))]
    }
    func testRewindAndForkToolsRegisterWithTheProductionChatFamily() async throws {
        let baseline = try BackendDeckCoreTestPortS1CatalogueCostSources.deckToolDefinitions()
        let ids = ["sessions.chat", "sessions.start_agent", "sessions.chat_rewind", "sessions.chat_fork"]
        let actions = try ids.map { id in
            let spec = try BackendMCPTool(id: id, wireName: id.replacingOccurrences(of: ".", with: "_"),
                description: "Message action registration", inputSchema: .object([.init("type", .string("object"))]), tier: .read)
            return BackendDeckToolsDefinition(spec: spec, title: spec.description) { _, _ in .value(.object([])) }
        }
        let installed = try await BackendDeckToolsRegistration.register(on: BackendNativeMCPServer(), definitions: baseline + actions)
        XCTAssertTrue(Set(ids).isSubset(of: Set(installed.toolIDs)))
    }
    func testLegacyKeeperCannotSilentlyUseTheOldRewindMechanism() throws {
        let old = NativeRPCValue.object([.init("providerConversationId", .string("known-conversation"))])
        do { try BackendChatMessageActions.requireNativeRewind(old, sequence: 1); XCTFail("Old word-rebuilding rewind") }
        catch { XCTAssertEqual((error as? NativeRPCError)?.code, "helper-upgrade-required") }
        let current = old.setting("messageActions", .array([.object([.init("sequence", .number(1)), .init("rewind", .bool(true))])]))
        XCTAssertNoThrow(try BackendChatMessageActions.requireNativeRewind(current, sequence: 1))
        XCTAssertThrowsError(try BackendChatMessageActions.requireNativeRewind(current, sequence: 2))
        XCTAssertThrowsError(try BackendChatMessageActions.requireNativeRewind(current.setting("providerConversationId", .null), sequence: 1))
    }
    func testClaudeOffersRewindOnUserAndForkOnBothSides() {
        let rows = BackendChatMessageActions.rows(events(.claude), provider: .claude)
        XCTAssertEqual(rows.map { $0["rewind"].bool }, [true, false])
        XCTAssertEqual(rows.map { $0["fork"].bool }, [true, true])
    }
    func testCodexOnlyOffersExactCompletedTurnBoundaries() {
        var records = events(.codex)
        let rows = BackendChatMessageActions.rows(records, provider: .codex)
        XCTAssertEqual(rows.map { $0["rewind"].bool }, [true, false])
        XCTAssertEqual(rows.map { $0["fork"].bool }, [false, true])
        records.insert(.init(conversationID: "c", turnID: userID, sequence: 2, provider: .codex, record: .text(.user, "steered")), at: 1)
        records = records.enumerated().map { index, event in .init(conversationID: event.conversationID, turnID: event.turnID, sequence: index + 1, provider: event.provider, record: event.record, at: event.at) }
        let steered = BackendChatMessageActions.rows(records, provider: .codex)
        XCTAssertEqual(steered.map { $0["rewind"].bool }, [true, false, false])
        XCTAssertEqual(steered.map { $0["fork"].bool }, [false, false, true])
        XCTAssertTrue(BackendChatMessageActions.rows(Array(events(.codex).dropLast()), provider: .codex).allSatisfy { $0["fork"].bool == false })
    }
    func testGeminiAndUnknownMessagesHaveNoInventedActions() {
        let gemini = BackendChatMessageActions.rows(events(.gemini), provider: .gemini)
        XCTAssertTrue(gemini.allSatisfy { $0["rewind"].bool == false })
        XCTAssertTrue(gemini.allSatisfy { $0["fork"].bool == true }, "Gemini uses a separately seeded conversation, never an invented provider rewind")
        XCTAssertThrowsError(try BackendChatMessageActions.boundary(99, events: events(.claude), provider: .claude, action: "fork"))
    }
    func testClaudeDecoderRetainsTranscriptUUIDInsteadOfUsingAPIMessageID() throws {
        var decoder = HootChatDecoder(provider: .claude)
        let wire = try NativeRPCValue.parseJSON(Data(#"{"type":"assistant","uuid":"22222222-2222-4222-8222-222222222222","message":{"id":"msg_api","content":[{"type":"text","text":"hello"}]}}"#.utf8))
        let record = try XCTUnwrap(try decoder.decode(wire).first { $0.kind == .message })
        XCTAssertEqual(record.messageID, "msg_api")
        XCTAssertEqual(record.value["providerMessageId"].string, assistantID)
    }
    func testExactClaudeForkUsesRecordedMessageUUIDAndRejectsForeignSequence() async throws {
        let rows = BackendChatMessageActions.rows(events(.claude), provider: .claude)
        let plan = try await BackendChatFork.invoke(operation: "fork/create", args: .object([.init("throughSequence", .number(2))]), provider: .claude,
            conversation: "parent", cwd: "/scratch", knownTurns: [userID: ""], quiet: true, request: { _, _ in XCTFail(); return .null }, knownMessages: rows)
        XCTAssertEqual(plan["resumeSessionAt"].string, assistantID)
        XCTAssertEqual(plan["requiresForkLaunch"].bool, true)
        do {
            _ = try await BackendChatFork.invoke(operation: "fork/create", args: .object([.init("throughSequence", .number(99))]), provider: .claude,
                conversation: "parent", cwd: "/scratch", knownTurns: [:], quiet: true, request: { _, _ in XCTFail(); return .null }, knownMessages: rows)
            XCTFail("Foreign boundary")
        } catch { XCTAssertEqual((error as? NativeRPCError)?.code, "unavailable") }
    }
    func testOlderClaudeJournalRecoversUUIDByExactAPIIDWithoutChangingTranscript() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("chat-checkpoints-" + UUID().uuidString)
        let cwd = root.appendingPathComponent("work").path, config = root.appendingPathComponent("claude")
        let project = config.appendingPathComponent("projects").appendingPathComponent(NativeTranscriptPaths.encodeProjectPath(cwd))
        try FileManager.default.createDirectory(at: URL(fileURLWithPath: cwd), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let transcript = project.appendingPathComponent(userID + ".jsonl")
        let wire = NativeRPCValue.object([.init("type", .string("assistant")), .init("uuid", .string(assistantID)),
            .init("sessionId", .string(userID)), .init("cwd", .string(cwd)),
            .init("message", .object([.init("id", .string("msg-old")), .init("model", .string("claude-sonnet")),
                .init("content", .array([.object([.init("type", .string("text")), .init("text", .string("earlier answer"))])]))]))])
        let bytes = try wire.encodedJSON() + Data([10]); try bytes.write(to: transcript)
        let ids = try await BackendChatProviderCatalogue.claudeMessageIDs(environment: ["HOME": root.path, "CLAUDE_CONFIG_DIR": config.path], cwd: cwd, conversation: userID)
        XCTAssertEqual(ids["msg-old"], assistantID)
        XCTAssertEqual(try Data(contentsOf: transcript), bytes)
        let store = try BackendHootChatStore(file: root.appendingPathComponent("journal.json"), provider: .claude)
        let old = HootChatEvent(conversationID: "old", turnID: userID, sequence: 1, provider: .claude, record: .text(.message, id: "msg-old", "earlier answer"))
        try await store.seedForkHistory([old]); try await store.adoptClaudeMessageIDs(ids)
        let rows = await store.messageActionRows
        XCTAssertTrue(rows.first?["fork"].bool == true)
        XCTAssertEqual(rows.first?["providerMessageId"].string, assistantID)
    }
    func testCopiedForkJournalHasItsOwnIdentityAndDoesNotAutoAnswer() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("chat-fork-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("chat.json")
        let store = try BackendHootChatStore(file: file, provider: .claude)
        try await store.seedForkHistory(Array(events(.claude).prefix(1)))
        let restored = try BackendHootChatStore(file: file, provider: .claude)
        let snapshot = await restored.snapshot()
        XCTAssertFalse(snapshot["resuming"].bool == true)
        XCTAssertNotEqual(snapshot["conversationId"].string, "c")
        XCTAssertEqual(snapshot["events"].elements?.first?["conversationId"].string, snapshot["conversationId"].string)
    }
    func testPendingClaudeForkSurvivesRestoreAndStopsForkingAfterItsOwnIDArrives() throws {
        var input = BackendCreateSessionInput(cwd: "/scratch", provider: "claude")
        input.chat = true; input.resume = true; input.resumeConversationId = userID
        input.forkSession = true; input.resumeSessionAt = assistantID
        let wire = BackendSessionSaved.from(input)
        let restored = try BackendSessionSaved(wire).input(resume: true)
        XCTAssertEqual(restored.resumeSessionAt, assistantID)
        XCTAssertEqual(restored.forkSession, true)
        let continued = try BackendSessionSaved(wire.setting("agentSessionId", .string(assistantID))).input(resume: true)
        XCTAssertNil(continued.forkSession)
        XCTAssertFalse(BackendSessionChats.withoutConversation(["--model", "sonnet", "--resume-session-at=" + assistantID, "--resume", userID, "--fork-session"]).contains { $0.contains("resume-session-at") })
    }

    func testLiveCodexRewindKeepsItsProcessAndHasNoPhantomPage() async throws {
        let settings = ProcessInfo.processInfo.environment
        guard let location = settings["TD_REWIND_LIVE_ROOT"], let executable = settings["TD_REWIND_CODEX_BIN"] else { throw XCTSkip("Opt-in scratch Codex proof") }
        let root = URL(fileURLWithPath: location), file = root.appendingPathComponent("backend-codex-in-place.json")
        let store = try BackendHootChatStore(file: file, provider: .codex, retainAllHistory: true)
        var environment = settings.filter { key, _ in !["ANTHROPIC", "OPENAI", "CLAUDE", "CODEX"].contains { key.contains($0) } }
        environment["HOME"] = root.appendingPathComponent("home").path; environment["CODEX_HOME"] = root.appendingPathComponent("codex").path
        let plan = try BackendHootChatLaunchPlan(provider: .codex, cwd: root.appendingPathComponent("work").path, sessionID: nil,
            extra: ["--model", "gpt-6.1-sol", "--sandbox", "read-only", "--ask-for-approval", "never"], pageServers: [], privateDirectory: nil)
        do {
            try await store.attach(.init(command: executable, arguments: plan.arguments, cwd: root.appendingPathComponent("work").path, environment: environment, setup: plan.setup))
            try await store.initialize()
            try await say("Reply exactly LIVE_KEEP", to: store)
            try await say("Reply exactly LIVE_DROP", to: store)
            let before = await store.snapshot(limit: 500), originalPID = await store.processPID
            let chosen = try XCTUnwrap(before["events"].elements?.last { $0["kind"].string == "user" }?["sequence"].number)
            let restored = try await store.rewindProvider(to: Int(chosen))
            XCTAssertEqual(restored.text, "Reply exactly LIVE_DROP")
            let afterPID = await store.processPID, prefix = await store.snapshot(limit: 500)
            XCTAssertNotNil(originalPID); XCTAssertEqual(afterPID, originalPID)
            XCTAssertFalse(prefix["hasMore"].bool == true, "Retired sequence numbers do not represent unread history")
            let next = await store.snapshot(after: prefix["cursor"].number.map(Int.init), limit: 500)
            XCTAssertEqual(next["events"].elements?.count, 0); XCTAssertFalse(next["hasMore"].bool == true)
            try await say("List the exact words I previously asked you to reply, then LIVE_EDIT. Words only.", to: store)
            let edited = await store.snapshot(limit: 500), answer = lastAnswer(edited)
            XCTAssertTrue(answer.contains("LIVE_KEEP")); XCTAssertTrue(answer.contains("LIVE_EDIT")); XCTAssertFalse(answer.contains("LIVE_DROP"))
            try NativeRPCValue.object([.init("keptSameProcess", .bool(originalPID == afterPID)), .init("prefixHasMore", prefix["hasMore"]), .init("answer", .string(answer))])
                .encodedJSON(pretty: true).write(to: root.appendingPathComponent("codex-in-place-proof.json"))
            await store.stop()
        } catch { await store.stop(); throw error }
    }
    func testLiveClaudeRewindEditResendAndFork() async throws { try await live(.claude) }
    func testLiveCodexRewindEditResendAndFork() async throws { try await live(.codex) }
    private func live(_ provider: HootChatProvider) async throws {
        guard let location = ProcessInfo.processInfo.environment["TD_REWIND_LIVE_ROOT"] else { throw XCTSkip("Opt-in scratch subscription proof") }
        let root = URL(fileURLWithPath: location)
        if provider == .claude {
            let credential = try NativeRPCValue.parseJSON(Data(contentsOf: root.appendingPathComponent("claude/.credentials.json")))
            guard (credential["claudeAiOauth"]["expiresAt"].number ?? 0) > Date().timeIntervalSince1970 * 1000 + 600_000 else {
                throw XCTSkip("The copied Claude login is no longer fresh; its refresh token was not used.")
            }
        }
        let folder = root.appendingPathComponent("work").path
        let directory = root.appendingPathComponent("backend-" + provider.rawValue)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = try BackendHootChatStore(file: directory.appendingPathComponent("original.json"), provider: provider, retainAllHistory: true)
        let child = try BackendHootChatStore(file: directory.appendingPathComponent("fork.json"), provider: provider, retainAllHistory: true)
        var environment = ProcessInfo.processInfo.environment.filter { key, _ in
            !["ANTHROPIC", "OPENAI", "CLAUDE", "CODEX"].contains { key.contains($0) }
        }
        environment["HOME"] = root.appendingPathComponent("home").path
        environment["CLAUDE_CONFIG_DIR"] = root.appendingPathComponent("claude").path
        environment["CODEX_HOME"] = root.appendingPathComponent("codex").path
        let binaryKey = provider == .claude ? "TD_REWIND_CLAUDE_BIN" : "TD_REWIND_CODEX_BIN"
        guard let executable = ProcessInfo.processInfo.environment[binaryKey], executable.hasPrefix("/") else {
            throw XCTSkip("Provide the explicit scratch provider executable in " + binaryKey)
        }
        let extra = provider == .claude ? ["--model", "sonnet", "--setting-sources", "", "--strict-mcp-config", "--permission-mode", "default"]
            : ["--model", "gpt-6.1-sol", "--sandbox", "read-only", "--ask-for-approval", "never"]
        func launch(_ resume: String? = nil, forkAt: String? = nil) throws -> BackendHootChatLaunch {
            let flags = extra + (forkAt.map { ["--resume", resume!, "--fork-session", "--resume-session-at=" + $0] } ?? [])
            let plan = try BackendHootChatLaunchPlan(provider: provider, cwd: folder, sessionID: forkAt == nil && provider == .claude ? resume : nil,
                extra: flags, pageServers: [], privateDirectory: nil)
            return .init(command: executable, arguments: plan.arguments, cwd: folder, environment: environment, setup: plan.setup)
        }
        do {
            try await store.attach(launch()); try await store.initialize()
            try await say("Reply exactly FIRST_APPLE", to: store)
            try await say("Reply exactly LATER_BANANA", to: store)
            let original = await store.snapshot(limit: 500)
            let conversation = try original["providerConversationId"].requireString("conversation")
            let messages = try (original["events"].elements ?? []).map(HootChatEvent.init(wire:))
            let answer = try XCTUnwrap(messages.first { $0.record.kind == .message && $0.record.value["text"].string?.contains("FIRST_APPLE") == true })
            let user = try XCTUnwrap(messages.last { $0.record.kind == .user })
            let args = NativeRPCValue.object([.init("throughSequence", .number(Double(answer.sequence)))])
            let sourceLaunch = try launch(conversation)
            let plan = try await BackendChatFork.invoke(operation: "fork/create", args: args, provider: provider, conversation: conversation, cwd: folder,
                knownTurns: await store.forkTurnIDs(), quiet: true, request: { method, params in try await store.providerRequest(method: method, params: params) },
                isolatedFork: { params in try await BackendChatForkProcess.fork(launch: sourceLaunch, params: params) }, knownMessages: await store.messageActionRows)
            let forkConversation = try plan["conversationId"].requireString("fork")
            if provider == .codex { try await child.seedSessionConversation(forkConversation) }
            try await child.attach(launch(forkConversation, forkAt: plan["resumeSessionAt"].string)); try await child.initialize()
            let prefix = try await store.forkPrefix(through: answer.sequence)
            try await child.seedForkHistory(prefix)
            try await say("List the exact words I previously asked you to reply. Words only.", to: child)
            let fork = await child.snapshot(limit: 500)
            XCTAssertNotEqual(fork["providerConversationId"].string, conversation)
            let forkText = lastAnswer(fork)
            XCTAssertTrue(forkText.contains("FIRST_APPLE")); XCTAssertFalse(forkText.contains("LATER_BANANA"))
            let unchanged = await store.snapshot(limit: 500)
            let visible: (NativeRPCValue) -> [NativeRPCValue] = { snapshot in
                (snapshot["events"].elements ?? []).filter { ["user", "message"].contains($0["kind"].string ?? "") }
            }
            XCTAssertEqual(visible(unchanged), visible(original), "Fork leaves the original conversation untouched")
            XCTAssertEqual(unchanged["providerConversationId"].string, conversation)
            let edit = try await store.rewindProvider(to: user.sequence)
            XCTAssertEqual(edit.text, "Reply exactly LATER_BANANA")
            let rewound = await store.snapshot(limit: 500)
            XCTAssertFalse((rewound["events"].elements ?? []).contains { $0["value"]["text"].string?.contains("LATER_BANANA") == true })
            if await !store.alive {
                try await store.attach(launch(await store.cliSessionID)); try await store.initialize()
            }
            try await say("List the exact words I previously asked you to reply, then EDITED_CHERRY. Words only.", to: store)
            let edited = await store.snapshot(limit: 500), editedText = lastAnswer(edited)
            XCTAssertTrue(editedText.contains("FIRST_APPLE")); XCTAssertTrue(editedText.contains("EDITED_CHERRY")); XCTAssertFalse(editedText.contains("LATER_BANANA"))
            let proof = NativeRPCValue.object([.init("provider", .string(provider.rawValue)), .init("original", original), .init("fork", fork), .init("rewound", rewound), .init("edited", edited)])
            try proof.encodedJSON(pretty: true).write(to: directory.appendingPathComponent("proof.json"))
            await store.stop(); await child.stop()
            let restoredFork = try BackendHootChatStore(file: directory.appendingPathComponent("fork.json"), provider: provider, retainAllHistory: true)
            let restored = await restoredFork.snapshot(limit: 500)
            XCTAssertEqual(lastAnswer(restored), forkText)
            XCTAssertFalse(restored["resuming"].bool == true)
        } catch { await store.stop(); await child.stop(); throw error }
    }
    private func lastAnswer(_ snapshot: NativeRPCValue) -> String {
        snapshot["events"].elements?.last { $0["kind"].string == "message" }?["value"]["text"].string ?? ""
    }
    private func say(_ text: String, to store: BackendHootChatStore) async throws {
        _ = try await store.say(text)
        for _ in 0..<900 {
            if await !store.isBusy {
                let snapshot = await store.snapshot(limit: 500)
                if let error = snapshot["problem"].string { throw NativeRPCError(code: "live-proof-failed", message: error) }
                let value = lastAnswer(snapshot)
                guard !value.contains("hit your"), !value.isEmpty else { throw NativeRPCError(code: "live-proof-failed", message: "The provider did not answer the scratch proof") }
                return
            }
            try await Task.sleep(for: .milliseconds(200))
        }
        throw NativeRPCError(code: "timeout", message: "Scratch AI answer timed out")
    }
}
