import Foundation
import Testing
@testable import TerminalDeckBackend
import TerminalDeckNativeCore

/// Fixtures only: real record readers, a scripted terminal and WhatsAppFakeTransport. No app, host or network.
@Suite struct WhatsAppTerminalReplyTests {
    @Test func claudeSendsOnlyTheFinalAnswerAfterTheTurnEnds() async throws {
        let f = try TerminalWAWorld()
        defer { f.remove() }
        try f.append("Old answer", at: f.milliseconds - 10_000)
        let link = f.link()
        await link.take(f.text("inspect it"))
        f.clock.advance(1)
        try f.append("I will run a command.", at: f.milliseconds, final: false)
        await f.receivers.setScreen("❯ inspect it\nRan 1 shell command\n✻ Baked for 11s\n❯ \n? for shortcuts")
        try await f.until { await f.receivers.recordReads > 2 }
        await link.flushed()
        #expect(await f.transport.sentTexts.isEmpty) // Quiet screen and intermediate assistant text are not a final answer.
        f.clock.advance(1)
        try f.append("**Fixed.** The answer is clean.", at: f.milliseconds)
        await f.receivers.end(at: f.milliseconds + 1)
        try await f.until { await f.transport.sent.count == 1 }
        await link.look(); await link.flushed(); await link.stop()
        #expect(await f.transport.sentTexts == ["*Fixed.* The answer is clean."])
        #expect(await f.receivers.typed == ["inspect it\r"])
    }

    @Test func aMarkdownTableUsesTheExistingWhatsAppFormatter() async throws {
        let f = try TerminalWAWorld()
        defer { f.remove() }
        let link = f.link()
        await link.take(f.text("table please"))
        f.clock.advance(1)
        try f.append("| Name | Count |\n| --- | --- |\n| Tests | 6 |", at: f.milliseconds)
        await f.receivers.end(at: f.milliseconds + 1)
        try await f.until { await f.transport.sent.count == 1 }
        await link.flushed(); await link.stop()
        #expect(await f.transport.sentTexts == ["*Name* | *Count*\nTests | 6"])
    }

    @Test func shellDropsFramesPromptEchoTimingStatusAndReplacementGlyphs() async throws {
        let f = try TerminalWAWorld(provider: "shell")
        defer { f.remove() }
        await f.receivers.setScreen("\n┌─────────────┐\n│user@mac:~$ report│\n├─────────────┤\n│ Ready� now │\n└─────────────┘\nRan 1 shell command\n✻ Baked for 11s\n❯ \n⏵⏵ bypass permissions on\n? for shortcuts\n")
        let link = f.link()
        await link.take(f.text("report")); await link.flushed(); await link.stop()
        #expect(await f.transport.sentTexts == ["```\nReady now\n```"])
    }

    @Test func specialSpacesBecomeOrdinarySpacesAndOnlyFortyCleanedLinesRemain() {
        let spaces = "a\u{00A0}b\u{2007}c\u{202F}d\u{2009}e\u{3000}f"
        #expect(BackendWhatsAppLink.cleanTerminal(spaces, echo: "x") == "a b c d e f")
        #expect(BackendWhatsAppLink.cleanTerminal("  indented output", echo: "x") == "  indented output")
        #expect(BackendWhatsAppLink.cleanTerminal("a\u{FEFF}b\u{200B}c\u{2060}d", echo: "x") == "a b c d")
        let lines = (1...60).map { "line \($0)" }.joined(separator: "\n")
        let cleaned = BackendWhatsAppLink.cleanTerminal(lines + "\n" + String(repeating: "└───┘\n", count: 50), echo: "x")
        #expect(cleaned.components(separatedBy: "\n").count == 40)
        #expect(cleaned.hasPrefix("line 21\n") && cleaned.hasSuffix("line 60"))
    }

    @Test(arguments: ["claude", "codex", "gemini"])
    func missingRecordFallsBackForEachKnownAI(_ provider: String) async throws {
        let f = try TerminalWAWorld(provider: provider)
        defer { f.remove() }
        try FileManager.default.removeItem(at: f.file)
        await f.receivers.setScreen("┌────┐\n❯ inspect it\n│Recovered\u{00A0}output�│\n└────┘\n❯ ")
        let link = f.link()
        await link.take(f.text("inspect it")); await link.flushed(); await link.stop()
        #expect(await f.transport.sentTexts == ["```\nRecovered output\n```"])
    }

    @Test func unreadableRecordFallsBackAndAnEmptyCleanedScreenStillSendsAReply() async throws {
        let f = try TerminalWAWorld()
        defer { f.remove() }
        await f.receivers.refuseRecord()
        await f.receivers.setScreen("┌────┐\n❯ inspect it\n�\n└────┘")
        let link = f.link()
        await link.take(f.text("inspect it")); await link.flushed(); await link.stop()
        #expect(await f.transport.sentTexts == ["(no output)"])
    }

    @Test func aRecordThatDisappearsDuringTheTurnFallsBackForThatReply() async throws {
        let f = try TerminalWAWorld()
        defer { f.remove() }
        let link = f.link()
        await link.take(f.text("inspect it"))
        try FileManager.default.removeItem(at: f.file)
        await f.receivers.setScreen("❯ inspect it\n│Fallback output�│\n❯ ")
        try await f.until { await f.transport.sent.count == 1 }
        await link.flushed(); await link.stop()
        #expect(await f.transport.sentTexts == ["```\nFallback output\n```"])
    }

    @Test func approvalDuringTheTurnUsesTheExistingQuestionAndOneTwoAnswerPath() async throws {
        let f = try TerminalWAWorld()
        defer { f.remove() }
        let link = f.link()
        await link.take(f.text("inspect it"))
        await f.receivers.ask(.init(id: "approval-1", summary: "It asks to use Bash.", detail: "pwd"))
        await link.look(); await link.look(); await link.flushed()
        #expect(await f.transport.sentTexts == ["It asks to use Bash.\n\n```\npwd\n```\n\nReply 1 to allow, 2 to deny."])
        await link.take(f.text("1", id: "allow"))
        #expect(await f.receivers.approved == ["approval-1"])
        #expect(await f.receivers.typed == ["inspect it\r"])
        f.clock.advance(1)
        try f.append("Approved and finished.", at: f.milliseconds)
        await f.receivers.end(at: f.milliseconds + 1)
        try await f.until { await f.transport.sent.count == 2 }
        await link.flushed(); await link.stop()
        #expect(await f.transport.sentTexts.last == "Approved and finished.")
    }

    @Test func aLateAnswerIsDeliveredOnceAfterThe120SecondWaitCeiling() async throws {
        let f = try TerminalWAWorld()
        defer { f.remove() }
        let link = f.link()
        await link.take(f.text("inspect it"))
        f.clock.advance(121)
        try await f.until { await f.receivers.recordReads >= 2 }
        // Let the bounded wait hand off to the normal watcher.
        try await Task.sleep(for: .milliseconds(10))
        #expect(await f.transport.sentTexts.isEmpty)
        f.clock.advance(1)
        try f.append("Finished later.", at: f.milliseconds)
        await f.receivers.end(at: f.milliseconds + 1)
        try await f.until {
            await link.look(); await link.flushed()
            return await f.transport.sent.count == 1
        }
        await link.look(); await link.flushed(); await link.stop()
        #expect(await f.transport.sentTexts == ["Finished later."])
    }

    @Test func staleAnswersAndAnswersNewerThanTheLastTurnEndAreNotSent() async throws {
        let f = try TerminalWAWorld()
        defer { f.remove() }
        try f.append("Old answer", at: f.milliseconds - 10_000)
        let link = f.link()
        await link.take(f.text("inspect it"))
        await f.receivers.end(at: f.milliseconds + 1)
        try await f.until { await f.receivers.recordReads >= 2 }
        #expect(await f.transport.sentTexts.isEmpty)
        f.clock.advance(1)
        try f.append("Still working", at: f.milliseconds + 10_000)
        try await f.until { await f.receivers.recordReads >= 3 }
        await link.flushed(); await link.stop()
        #expect(await f.transport.sentTexts.isEmpty)
    }

    @Test(arguments: ["codex", "gemini"])
    func otherAIRecordsUseLastAnswerAndTheExisting4096SplitWithoutTruncating(_ provider: String) async throws {
        let f = try TerminalWAWorld(provider: provider)
        defer { f.remove() }
        let link = f.link()
        await link.take(f.text("inspect it"))
        f.clock.advance(1)
        let answer = String(repeating: "z", count: 5_000)
        try f.append(answer, at: f.milliseconds)
        await f.receivers.end(at: f.milliseconds + 1)
        try await f.until { await f.transport.sent.count == 2 }
        await link.flushed(); await link.stop()
        let sent = await f.transport.sentTexts
        #expect(sent.joined() == answer && sent.allSatisfy { $0.utf16.count <= 4_096 })
    }

    @Test(arguments: ["codex", "gemini"])
    func aToolContinuationCannotFinishFromAScreenStatusReceipt(_ provider: String) async throws {
        let f = try TerminalWAWorld(provider: provider)
        defer { f.remove() }
        let link = f.link()
        await link.take(f.text("inspect it"))
        f.clock.advance(1)
        try f.append("I am still using tools.", at: f.milliseconds, final: false)
        await f.receivers.end(at: f.milliseconds + 1)
        let reads = await f.receivers.recordReads
        try await f.until { await f.receivers.recordReads > reads }
        await link.flushed()
        #expect(await f.transport.sentTexts.isEmpty)
        f.clock.advance(1)
        try f.append("The final result.", at: f.milliseconds)
        try await f.until { await f.transport.sent.count == 1 }
        await link.flushed(); await link.stop()
        #expect(await f.transport.sentTexts == ["The final result."])
    }

    @Test func codexTaskCompleteFinishesALegacyAnswerWithoutAPhase() async throws {
        let f = try TerminalWAWorld(provider: "codex")
        defer { f.remove() }
        let link = f.link()
        await link.take(f.text("inspect it"))
        f.clock.advance(1)
        try f.append("Legacy final result.", at: f.milliseconds, final: false)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let row = NativeRPCValue.object([.init("type", .string("event_msg")), .init("timestamp", .string(formatter.string(from: f.clock.date()))),
            .init("payload", .object([.init("type", .string("task_complete")), .init("turn_id", .string("fixture-turn"))]))])
        var data = try Data(contentsOf: f.file)
        data.append(try row.encodedJSON()); data.append(0x0a)
        try data.write(to: f.file, options: .atomic)
        try await f.until { await f.transport.sent.count == 1 }
        await link.flushed(); await link.stop()
        #expect(await f.transport.sentTexts == ["Legacy final result."])
    }

    @Test func theSharedReaderKeepsTheSessionsResultCapButWhatsAppReadsTheWholeAnswer() async throws {
        let f = try TerminalWAWorld()
        defer { f.remove() }
        let text = String(repeating: "a", count: 5_000)
        try f.append("Earlier tool narration.", at: f.milliseconds - 1_000, final: false)
        try f.append(text, at: f.milliseconds)
        let source = await f.receivers.source()
        let session = await f.receivers.session
        let capped = try await BackendDeckToolsSessionsArea.answerRecord(session, sessions: [session], source: source)
        let whole = try await BackendDeckToolsSessionsArea.answerRecord(session, sessions: [session], source: source, maximumChars: nil)
        #expect(capped?.answer?["text"].string?.utf16.count == 4_001)
        #expect(capped?.answer?["truncated"].bool == true)
        #expect(whole?.answer?["text"].string == text)
        let chatReader = NativeChatTranscriptReader(path: f.file.path, allowedRoots: [f.root.path])
        let chat = try await chatReader.readAll(wholeConversation: true)
        #expect(chat.messages.last?.text == "Earlier tool narration.\n\n" + text)
    }
}

private struct TerminalWAWorld {
    let clock = WAClock()
    let transport = WhatsAppFakeTransport()
    let root: URL
    let file: URL
    let provider: String?
    let receivers: TerminalWAReceivers
    var milliseconds: Double { clock.date().timeIntervalSince1970 * 1_000 }

    init(provider: String? = "claude") throws {
        self.provider = provider
        root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent(".wa-terminal-fixture-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        file = root.appendingPathComponent("conversation.jsonl")
        try "{}\n".write(to: file, atomically: true, encoding: .utf8)
        receivers = TerminalWAReceivers(file: file, provider: provider)
    }
    func remove() { try? FileManager.default.removeItem(at: root) }
    func text(_ body: String, id: String = "m1") -> WhatsAppInbound {
        .init(id: id, from: "user:1000", timestamp: clock.date(), kind: .text, text: body)
    }
    func link() -> BackendWhatsAppLink {
        let box = WARecordBox(.init(id: "wa-fixture", name: "Fixture", receiver: .session(id: "terminal-fixture", name: "Fixture"),
            creator: "user:1000", offset: 1, addedAt: 0))
        return BackendWhatsAppLink(agentID: "wa-fixture", key: "fixture-key", transport: transport, receivers: receivers, clock: clock.link,
            read: { await box.record }, update: { await box.edit($0) }, stopped: { _ in })
    }
    func append(_ text: String, at: Double, final: Bool = true) throws {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let stamp = formatter.string(from: Date(timeIntervalSince1970: at / 1_000))
        let row: NativeRPCValue
        switch provider {
        case "codex":
            row = .object([.init("type", .string("event_msg")), .init("timestamp", .string(stamp)),
                .init("payload", .object([.init("type", .string("agent_message")), .init("message", .string(text)), .init("phase", .string(final ? "final_answer" : "commentary"))]))])
        case "gemini":
            row = .object([.init("id", .string(UUID().uuidString)), .init("type", .string("gemini")),
                .init("timestamp", .string(stamp)), .init("content", .string(text)),
                .init("toolCalls", .array(final ? [] : [.object([.init("id", .string("tool")), .init("status", .string("success"))])]))])
        default:
            row = .object([.init("type", .string("assistant")), .init("uuid", .string(UUID().uuidString)), .init("timestamp", .string(stamp)),
                .init("message", .object([.init("id", .string(UUID().uuidString)), .init("stop_reason", .string(final ? "end_turn" : "tool_use")),
                    .init("content", .array([.object([.init("type", .string("text")), .init("text", .string(text))])]))]))])
        }
        var data = try Data(contentsOf: file)
        data.append(try row.encodedJSON()); data.append(0x0a)
        try data.write(to: file, options: .atomic)
    }
    func until(_ condition: () async -> Bool) async throws {
        for _ in 0..<1_000 {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(1))
        }
        throw NativeRPCError(code: "fixture-timeout", message: "The fixture did not finish")
    }
}

private actor TerminalWAReceivers: WhatsAppReceiverPort {
    let file: URL
    let provider: String?
    var session: NativeRPCValue {
        .object([.init("id", .string("terminal-fixture")), .init("provider", provider.map(NativeRPCValue.string) ?? .null),
            .init("cwd", .string(file.deletingLastPathComponent().path)), .init("createdAt", .number(0))])
    }
    private(set) var typed: [String] = []
    private(set) var approved: [String] = []
    private(set) var recordReads = 0
    private var endedAt: Double?
    private var unreadable = false
    private var screenText = "❯ inspect it\nRan 1 shell command\n✻ Baked for 11s\n❯ \n? for shortcuts"
    private var approval: WhatsAppApproval?
    init(file: URL, provider: String?) { self.file = file; self.provider = provider }
    func setScreen(_ value: String) { screenText = value }
    func end(at: Double) { endedAt = at }
    func refuseRecord() { unreadable = true }
    func ask(_ request: WhatsAppApproval) { approval = request }
    func target(for receiver: WhatsAppReceiver, conversationName: String, agentID: String) -> WhatsAppTarget? {
        .init(sessionID: "terminal-fixture", isTerminal: true)
    }
    func say(_ target: WhatsAppTarget, text: String, attachments: [WhatsAppAttachment]) throws {
        throw NativeRPCError(code: "fixture", message: "A terminal must never use chat say")
    }
    func turn(_ target: WhatsAppTarget) -> WhatsAppTurn? {
        approval.map { .init(turnID: "turn", state: .needsApproval([$0])) }
    }
    func approve(_ target: WhatsAppTarget, approvalID: String, allow: Bool) -> Bool {
        guard approval?.id == approvalID, allow else { return false }
        approved.append(approvalID); approval = nil
        return true
    }
    func type(_ target: WhatsAppTarget, text: String) { typed.append(text) }
    func screen(_ target: WhatsAppTarget) -> String? { typed.isEmpty ? "" : screenText }
    func isOpen(_ target: WhatsAppTarget) -> Bool { true }
    func isToolSession(_ target: WhatsAppTarget, _ sessionID: String) -> Bool { false }
    func source() -> BackendSessionAnswerSource {
        let file = file, root = file.deletingLastPathComponent().path, unreadable = unreadable
        return .init(transcripts: { _ in
            [.object([.init("path", .string(file.path)), .init("bytes", .number(1))])]
        }, transcriptBytes: { _ in
            if unreadable { throw NativeRPCError(code: "unreadable-fixture", message: "Fixture read refused") }
            return try (FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.intValue ?? 0
        }, transcriptMessages: { path, from in
            try await BackendSessionAnswerSource.messages(path: path, fromByte: from, roots: [root])
        }, agentRecord: { session in
            if unreadable { return nil }
            return await BackendDeckCoreAgentRecords.read(session: session, locate: { _ in .init(path: file.path, roots: [root]) }, windowBytes: 256 * 1_024)
        })
    }
    func terminalRecord(_ target: WhatsAppTarget) async -> WhatsAppTerminalRecord? {
        recordReads += 1
        guard ["claude", "codex", "gemini"].contains(provider ?? ""), let record = try? await BackendDeckToolsSessionsArea.answerRecord(session, sessions: [session], source: source(), maximumChars: nil) else { return nil }
        return .init(answer: record.answer?["text"].string, answeredAt: record.answer?["at"].number, endedAt: provider == "claude" ? endedAt : record.completedAt)
    }
}
