import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

/// Asad, 12 Oct: one account dropdown for every AI, and "once we send new message, the new AI will read the whole
/// message history and it will start right from there without feeling that there is a change"; and a Hoot answer cut
/// off by an app restart carries on by itself. Scratch folders and the offline fake CLI only (no account, no model).
final class HootChatCarriesOnTests: XCTestCase, @unchecked Sendable {
    private func scratch() throws -> URL {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("hoot-carries-on-" + UUID().uuidString + ".noindex")
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: path) }
        return path
    }
    private var fakeCLI: String {
        var source = URL(fileURLWithPath: #filePath); for _ in 0..<4 { source.deleteLastPathComponent() }
        return source.appendingPathComponent("testing/suite/fixtures/HootFakeRPC.py").path
    }
    /// A saved chat: the person and Hoot, `pairs` times, each turn finished.
    private func saved(_ file: URL, provider: HootChatProvider = .claude, conversation: String = "c1", pairs: Int, at: Double = 1_000,
                       sessionID: String? = "cli-1", context: String? = nil, extra: [HootChatEvent] = [], window: Int? = nil) throws {
        var events: [HootChatEvent] = [], sequence = 0
        func add(_ turn: String, _ record: HootChatRecord) {
            sequence += 1
            events.append(.init(conversationID: conversation, turnID: turn, sequence: sequence, provider: provider, record: record, at: at + Double(sequence)))
        }
        for index in 1...max(1, pairs) where pairs > 0 {
            add("t\(index)", .init(.user, id: "t\(index)", value: .object([.init("text", .string("Question \(index) about the shop")), .init("attachmentCount", .number(0)), .init("context", .object([]))])))
            add("t\(index)", .text(.message, id: "m\(index)", "Answer \(index): the shop builds."))
            add("t\(index)", .init(.completed, value: .object([])))
        }
        for event in extra {
            sequence += 1
            events.append(.init(conversationID: conversation, turnID: event.turnID, sequence: sequence, provider: provider, record: event.record, at: event.at))
        }
        var value = NativeRPCValue.object([.init("version", .number(1)), .init("conversationId", .string(conversation)), .init("provider", .string(provider.rawValue)),
            .init("sessionId", sessionID.map(NativeRPCValue.string) ?? .null), .init("contextKey", context.map(NativeRPCValue.string) ?? .null),
            .init("events", .array(events.map(\.wireValue)))])
        if let window { value = value.setting("window", .number(Double(window))) }
        try value.encodedJSON().write(to: file)
    }
    private func requests(_ root: URL) throws -> [NativeRPCValue] {
        try String(contentsOf: root.appendingPathComponent("requests.jsonl"), encoding: .utf8).split(separator: "\n").map { try NativeRPCValue.parseJSON(Data($0.utf8)) }
    }
    private func turnText(_ request: NativeRPCValue) -> String {
        (request["params"]["input"].elements ?? []).compactMap { $0["text"].string }.joined(separator: "\n")
    }
    private func waitIdle(_ store: BackendHootChatStore) async throws {
        let deadline = Date().addingTimeInterval(10)
        while await store.isBusy, Date() < deadline { try await Task.sleep(for: .milliseconds(30)) }
        let busy = await store.isBusy
        XCTAssertFalse(busy, "The fake CLI's turn finished")
    }

    // MARK: Another AI carries on the same conversation

    func testSwitchingAICarriesTheVisibleConversationAndNeverTheCLIsOwnID() async throws {
        let root = try scratch(), claudeFile = root.appendingPathComponent("chat.json"), codexFile = root.appendingPathComponent("chat-codex.json")
        try saved(claudeFile, pairs: 3, window: 1_000_000)
        // The Codex file held another, older conversation: it is kept beside, never lost.
        try saved(codexFile, provider: .codex, conversation: "older", pairs: 1, sessionID: "codex-thread", window: 272_000)
        let store = try BackendHootChatStore(file: claudeFile, provider: .claude)
        let before = await store.snapshot(limit: 500)
        try await store.rebindProvider(.codex)
        let after = await store.snapshot(limit: 500)
        XCTAssertEqual(after["conversationId"], before["conversationId"], "The same conversation goes on")
        XCTAssertEqual(after["provider"].string, "codex")
        XCTAssertEqual(after["events"].elements?.count, before["events"].elements?.count, "Every message the person saw is still there")
        XCTAssertFalse((after["events"].elements ?? []).contains { $0["kind"].string == "message" && ($0["value"]["text"].string ?? "").hasPrefix("New conversation with") },
                       "No 'new conversation' line: nothing changes for the person")
        let cli = await store.cliSessionID, pending = await store.handoverPending
        XCTAssertNil(cli, "Claude's own conversation id is never handed to Codex")
        XCTAssertTrue(pending, "The next message hands Codex the conversation")
        XCTAssertEqual(after["window"].number, 272_000, "Codex's own measured window, not Claude's")
        // On disk: Codex's file now holds this conversation; the older one was kept as an archive.
        let reread = try BackendHootChatStore.readHistory(file: codexFile, provider: .codex)
        XCTAssertEqual(reread.id, before["conversationId"].string)
        XCTAssertNil(reread.sessionID)
        XCTAssertEqual(reread.handover, "claude")
        let archives = try FileManager.default.contentsOfDirectory(atPath: root.path).filter { $0.hasPrefix("chat-archive-older-") }
        XCTAssertEqual(archives.count, 1, "The conversation Codex's file held before is kept")
        // And back to Claude: the same conversation again, with what was said meanwhile.
        try await store.rebindProvider(.claude)
        let back = await store.snapshot(limit: 500)
        XCTAssertEqual(back["conversationId"], before["conversationId"])
        XCTAssertEqual(back["provider"].string, "claude")
        let backCLI = await store.cliSessionID
        XCTAssertNil(backCLI, "Claude's old CLI conversation does not know what was said with Codex: a clean desk again")
    }

    func testTheNewAIsFirstMessageCarriesTheWholeConversationOnce() async throws {
        let root = try scratch(), claudeFile = root.appendingPathComponent("chat.json")
        try saved(claudeFile, pairs: 20)
        let store = try BackendHootChatStore(file: claudeFile, provider: .claude)
        try await store.rebindProvider(.codex)
        await store.setPermissionPolicy("danger-full-access")
        try await store.attach(.init(command: "/usr/bin/python3", arguments: [fakeCLI, "codex"], cwd: root.path, environment: [:], setup: .init(cwd: root.path)))
        try await store.initialize()
        _ = try await store.say("And the release?")
        try await waitIdle(store)
        _ = try await store.say("Thanks")
        try await waitIdle(store)
        await store.stop()
        let turns = try requests(root).filter { $0["method"].string == "turn/start" }.map(turnText)
        XCTAssertEqual(turns.count, 2)
        let first = turns[0]
        XCTAssertTrue(first.hasPrefix("And the release?"), "The person's words come first, as written")
        XCTAssertTrue(first.contains("<deck-memory>") && first.contains("The conversation so far, word for word"), first.prefix(400).description)
        XCTAssertTrue(first.contains("taking over this conversation from Claude Code"))
        // The whole history, not only the desk's last 12 messages.
        XCTAssertTrue(first.contains("Question 1 about the shop") && first.contains("Answer 20: the shop builds."), "All 40 messages went in")
        XCTAssertFalse(turns[1].contains("The conversation so far"), "Only the first message carries it")
        let pending = await store.handoverPending
        XCTAssertFalse(pending)
        // The chat keeps only what the person wrote.
        let users = (await store.snapshot(limit: 500)["events"].elements ?? []).filter { $0["kind"].string == "user" }.compactMap { $0["value"]["text"].string }
        XCTAssertEqual(users.suffix(2), ["And the release?", "Thanks"])
    }

    func testAnotherAccountNeverBorrowsTheOldCLIConversationButTheChatCarriesOn() async throws {
        let root = try scratch(), file = root.appendingPathComponent("chat.json")
        try saved(file, pairs: 2, sessionID: "cli-1", context: "account-a:/folder")
        let store = try BackendHootChatStore(file: file)
        try await store.requireContext("account-a:/folder")
        var cli = await store.cliSessionID
        XCTAssertEqual(cli, "cli-1", "Same account and folder: the CLI's own conversation resumes")
        try await store.requireContext("account-b:/folder")
        cli = await store.cliSessionID
        let pending = await store.handoverPending
        XCTAssertNil(cli, "Account B never resumes account A's conversation")
        XCTAssertTrue(pending, "Account B's first message carries the conversation")
        XCTAssertEqual(BackendHootHandover.text(from: "account", messages: [.init(fromPerson: true, text: "hi")])?.contains("another account"), true)
    }

    func testHistoryKeepsAsMuchAsFitsAndThePersonsLastMessageWhole() {
        var messages: [BackendHootDeskMessage] = []
        for index in 1...30 { messages.append(.init(fromPerson: true, text: "Ask \(index)")); messages.append(.init(fromPerson: false, text: "Reply \(index)")) }
        let all = BackendHootHandover.history(messages) ?? ""
        XCTAssertTrue(all.contains("The person: Ask 1") && all.contains("You: Reply 30"), "Sixty short messages all fit")
        let long = String(repeating: "word ", count: 3_000)
        let cut = BackendHootHandover.history([.init(fromPerson: false, text: "early")] + [.init(fromPerson: true, text: long)], budget: 1_000) ?? ""
        XCTAssertTrue(cut.contains(long.trimmingCharacters(in: .whitespaces).prefix(100)), "The person's last message is always there")
        XCTAssertTrue(cut.hasPrefix("[1 earlier message is in the diary.]"))
        XCTAssertNil(BackendHootHandover.history([]))
    }

    // MARK: An answer cut off by a restart carries on by itself

    private func cutTurn(interruptedBy: String?, error: String? = nil, age: Double = 60_000) -> [HootChatEvent] {
        let at = Date().timeIntervalSince1970 * 1000 - age
        var events: [HootChatEvent] = [
            .init(conversationID: "c1", turnID: "cut", sequence: 0, provider: .codex,
                  record: .init(.user, id: "cut", value: .object([.init("text", .string("Fix the login page")), .init("attachmentCount", .number(0)), .init("context", .object([]))])), at: at),
            .init(conversationID: "c1", turnID: "cut", sequence: 0, provider: .codex, record: .init(.toolCall, id: "tool-1", value: .object([.init("name", .string("Read"))])), at: at + 1)]
        if let error { events.append(.init(conversationID: "c1", turnID: "cut", sequence: 0, provider: .codex, record: .text(.error, error), at: at + 2)) }
        if let interruptedBy {
            events.append(.init(conversationID: "c1", turnID: "cut", sequence: 0, provider: .codex,
                                record: .init(.interrupted, value: interruptedBy.isEmpty ? .null : .object([.init("by", .string(interruptedBy))])), at: at + 3))
        }
        return events
    }

    func testOnlyACutByTheAppIsCarriedOnNeverAPersonsStopOrAFailure() async throws {
        let root = try scratch()
        let cases: [(String, [HootChatEvent], Bool)] = [
            ("the app closing", cutTurn(interruptedBy: "quit"), true),
            ("a kill (no line at all)", cutTurn(interruptedBy: nil), true),
            ("Hoot's program ended under it", cutTurn(interruptedBy: nil, error: "Hoot stopped before finishing that answer. It is starting again."), true),
            ("the person's Stop", cutTurn(interruptedBy: "person"), false),
            ("the AI failed (a usage limit)", cutTurn(interruptedBy: nil, error: "You've hit your usage limit."), false),
            ("more than a day ago", cutTurn(interruptedBy: "quit", age: 2 * 86_400_000), false),
        ]
        for (name, extra, expected) in cases {
            let file = root.appendingPathComponent(UUID().uuidString + ".json")
            try saved(file, provider: .codex, pairs: 1, at: Date().timeIntervalSince1970 * 1000 - 3 * 86_400_000, sessionID: "saved-codex", extra: extra)
            let made = try BackendHootChatStore(file: file, provider: .codex)
            let resuming = await made.snapshot()["resuming"].bool
            XCTAssertEqual(resuming, expected, name)
            let taken = await made.takeContinuation()
            XCTAssertEqual(taken?.turn, expected ? "cut" : nil, name)
            let again = await made.takeContinuation()
            XCTAssertNil(again?.turn, name + ": taken once")
        }
    }

    func testACutOffAnswerCarriesOnInTheSameTurnWithNoNewBubble() async throws {
        let root = try scratch(), file = root.appendingPathComponent("chat-codex.json")
        try saved(file, provider: .codex, pairs: 1, at: Date().timeIntervalSince1970 * 1000 - 120_000, sessionID: "saved-codex", extra: cutTurn(interruptedBy: "quit"))
        let store = try BackendHootChatStore(file: file, provider: .codex)
        let cut = await store.takeContinuation()
        XCTAssertEqual(cut?.turn, "cut")
        await store.setPermissionPolicy("danger-full-access")
        try await store.attach(.init(command: "/usr/bin/python3", arguments: [fakeCLI, "codex"], cwd: root.path, environment: [:], setup: .init(cwd: root.path)))
        try await store.initialize()
        try await store.continueCutOff(turn: "cut", text: "Fix the login page")
        try await waitIdle(store)
        await store.stop()
        let sent = try requests(root).filter { $0["method"].string == "turn/start" }.map(turnText)
        XCTAssertEqual(sent.count, 1)
        XCTAssertTrue(sent[0].contains("Terminal Deck was restarted") && sent[0].contains("Fix the login page"), sent[0])
        let events = try (await store.snapshot(limit: 500)["events"].elements ?? []).map(HootChatEvent.init(wire:))
        XCTAssertEqual(events.filter { $0.record.kind == .user }.count, 2, "No new bubble: the app's line is not the person's")
        XCTAssertTrue(events.contains { $0.turnID == "cut" && $0.record.kind == .completed }, "The answer finished under the person's message")
        XCTAssertTrue(events.contains { $0.turnID == "cut" && $0.record.kind == .session && $0.record.value["continued"].string == "restart" })
        XCTAssertNil(BackendHootChatStore.unanswered(events), "Never carried on twice")
    }

    /// "Pick up where you left off" off: Hoot's cut-off answer is not carried on by itself (the default stays on).
    func testPickUpWhereYouLeftOffOffMeansNoCarryingOn() async throws {
        XCTAssertTrue(BackendCopilotSessionDependencies.picksUpAfterRestart(.object([])), "On by default")
        XCTAssertTrue(BackendCopilotSessionDependencies.picksUpAfterRestart(.object([.init("restoreSessions", .bool(true))])))
        XCTAssertFalse(BackendCopilotSessionDependencies.picksUpAfterRestart(.object([.init("restoreSessions", .bool(false))])))
        let root = try scratch(), file = root.appendingPathComponent("chat-codex.json")
        try saved(file, provider: .codex, pairs: 1, at: Date().timeIntervalSince1970 * 1000 - 120_000, sessionID: "saved-codex", extra: cutTurn(interruptedBy: "quit"))
        let store = try BackendHootChatStore(file: file, provider: .codex)
        let before = await store.snapshot()["resuming"].bool
        XCTAssertEqual(before, true)
        let runtime = BackendCopilotSessionRuntime(dependencies: .init(userData: root.path, driver: BackendCopilotSessionUnavailableDriver(),
            records: BackendCopilotSessionUnavailableRecords(), chat: store, picksUpAfterRestart: { false }))
        await runtime.carryOnAfterRestart()
        let after = await store.snapshot(limit: 500)
        XCTAssertEqual(after["resuming"].bool, false, "Nothing waits to carry on")
        let events = try (after["events"].elements ?? []).map(HootChatEvent.init(wire:))
        XCTAssertFalse(events.contains { $0.record.kind == .session && !$0.record.value["continued"].isNullish }, "Not carried on")
        XCTAssertEqual(BackendHootChatStore.unanswered(events)?.turn, "cut", "The message stays unanswered: Send again is still there")
    }

    func testThePersonsStopIsMarkedSoItIsNeverCarriedOn() async throws {
        let root = try scratch()
        let store = try BackendHootChatStore(file: root.appendingPathComponent("chat.json"))
        try await store.attach(.init(command: "/bin/sh", arguments: ["-c", "read first; read second"], cwd: root.path, environment: [:]))
        _ = try await store.say("one")
        await store.markStop("person")
        await store.stop()
        let events = try (await store.snapshot(limit: 500)["events"].elements ?? []).map(HootChatEvent.init(wire:))
        XCTAssertEqual(events.last?.record.kind, .interrupted)
        XCTAssertEqual(events.last?.record.value["by"].string, "person")
        XCTAssertNil(BackendHootChatStore.unanswered(events))
    }
}
