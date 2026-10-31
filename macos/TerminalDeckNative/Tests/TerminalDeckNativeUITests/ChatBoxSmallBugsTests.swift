import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckNative

/// U83: the chat box's small bugs (#534, #536, #538, #550, #569).
@MainActor final class ChatBoxSmallBugsTests: XCTestCase {
    func testAWholeTypedSlashCommandComesBeforeALongerOneThatStartsTheSameWay() {
        let offered = [HootSlashCommand(name: "commit-push"), HootSlashCommand(name: "commit"), HootSlashCommand(name: "commits")]
        XCTAssertEqual(HootSlashCommand.matches(offered, query: "commit").map(\.name), ["commit", "commit-push", "commits"])
        XCTAssertEqual(HootSlashCommand.matches(offered, query: "comm").map(\.name), ["commit-push", "commit", "commits"])
    }

    func testDictationReplacesOnlyItsOwnWordsAndKeepsWhatWasTyped() {
        let dictation = HootDictationSplice()
        // Typed "fix the" after pressing the microphone, then the words arrive.
        var text = dictation.write("login", into: "Draft fix the")
        XCTAssertEqual(text, "Draft fix the login")
        text = dictation.write("login bug", into: text)
        XCTAssertEqual(text, "Draft fix the login bug")
        // Typed after the dictated words: they stay after them.
        text = dictation.write("login bug today", into: text + " please")
        XCTAssertEqual(text, "Draft fix the login bug today please")
    }

    func testTheSettingsPopoverTicksAModelSavedAsAnAlias() {
        var catalogue = HootComposerCatalogue()
        catalogue.resolved = ["claude:opus": "claude:claude-opus-5-5"]
        let opus = HootComposerModel(id: "claude:claude-opus-5-5", provider: "Claude Code", name: "Opus 5.5")
        let sonnet = HootComposerModel(id: "claude:claude-sonnet-5-5", provider: "Claude Code", name: "Sonnet 5.5")
        XCTAssertTrue(catalogue.isChosen(opus, savedID: "claude:opus"))
        XCTAssertTrue(catalogue.isChosen(opus, savedID: "claude:claude-opus-5-5"))
        XCTAssertFalse(catalogue.isChosen(sonnet, savedID: "claude:opus"))
    }

    func testExportAfterARewindHoldsTheWholeLongConversation() async throws {
        let events = (1...600).map { index in
            HootChatEvent(conversationID: "long", turnID: "t\((index + 1) / 2)", sequence: index, provider: .codex,
                          record: .text(index % 2 == 1 ? .user : .message, id: "m\(index)", "Line \(index)")).wireValue
        }
        func page(_ slice: ArraySlice<NativeRPCValue>, more: Bool, cursor: Int) -> Any {
            NativeRPCValue.object([.init("conversationId", .string("long")), .init("provider", .string("codex")),
                .init("model", .string("test")), .init("sequence", .number(600)), .init("events", .array(Array(slice))),
                .init("alive", .bool(true)), .init("busy", .bool(false)), .init("hasMore", .bool(more)),
                .init("cursor", .number(Double(cursor)))]).foundation ?? [:]
        }
        let state = try NativeRPCValue.fromFoundation(page(events[...], more: false, cursor: 600))
        var reads: [Int?] = []
        let chat = NativeHootChatModel(fixture: state, chatInvoke: { channel, arguments in
            if channel.hasSuffix(":rewind") { return ["text": ""] }
            guard channel.hasSuffix(":read") else { return state.foundation ?? [:] }
            let cursor = arguments.count > 1 ? arguments[1] as? Int : nil
            reads.append(cursor)
            // The store answers a missing cursor with the newest 500 only.
            guard let cursor else { return page(events.suffix(500), more: false, cursor: 600) }
            let end = min(cursor + 500, events.count)
            return page(events[cursor..<end], more: end < events.count, cursor: end)
        }, source: .session(UUID().uuidString, provider: "codex"))
        XCTAssertEqual(chat.transcriptExportEvents.count, 600)
        let row = try XCTUnwrap(chat.rows.last(where: { $0.kind == .user }))
        chat.rewind(to: row)
        for _ in 0..<200 where reads.count < 2 { try await Task.sleep(for: .milliseconds(10)) }
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertNil(chat.rewindProblem)
        XCTAssertEqual(reads, [0, 500])
        XCTAssertEqual(chat.transcriptExportEvents.count, 600)
        XCTAssertEqual(chat.transcriptExportEvents.first?.sequence, 1)
    }

    func testAHootFileBoxNeverShowsAnOlderReadThatLandsLate() async throws {
        let file = CopilotFileText()
        file.follow(open: true, key: "first") {
            try? await Task.sleep(for: .milliseconds(150))
            return ("older text", nil)
        }
        file.follow(open: true, key: "second") { ("what is on disk now", nil) }
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(file.text, "what is on disk now")
    }
}
