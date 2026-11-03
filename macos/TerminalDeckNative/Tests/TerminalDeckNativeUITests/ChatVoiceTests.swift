import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckNative

@MainActor final class ChatVoiceTests: XCTestCase {
    func testExplicitPlaybackAndStopUseInjectedOutputAndUnavailableInputWithoutHardware() async throws {
        var played: [String] = [], stops = 0
        let mic = HootComposerVoice(available: false, observeHardware: false)
        let voice = NativeChatVoice(dictation: mic, play: { played.append($0) }, stop: { stops += 1 })
        XCTAssertEqual(voice.state["state"].string, "idle")
        try await voice.play(text: "Recorded reply", record: "r1")
        XCTAssertEqual(played, ["Recorded reply"])
        XCTAssertEqual(voice.state["state"].string, "speaking")
        XCTAssertEqual(voice.state["speakingRecordId"].string, "r1")
        var writes = 0
        await voice.listen { _ in writes += 1 }
        XCTAssertEqual(stops, 1)
        XCTAssertEqual(writes, 0)
        XCTAssertEqual(voice.state["state"].string, "idle")
        XCTAssertEqual(voice.state["dictationProblem"].string, "No microphone connected")
        await voice.stop()
        XCTAssertEqual(stops, 1)
        XCTAssertEqual(voice.state["providerConversationalVoice"], .null)
        XCTAssertThrowsError(try NativeChatVoice.checkedText(" "))
        XCTAssertThrowsError(try NativeChatVoice.checkedText(String(repeating: "x", count: 32769)))
    }
    func testVoiceReadIsLimitedToAssistantRepliesAndDoesNotChangeComposer() async throws {
        let events = [HootChatEvent(conversationID: "voice", turnID: "t", sequence: 1, provider: .codex, record: .text(.user, "User secret question")), HootChatEvent(conversationID: "voice", turnID: "t", sequence: 2, provider: .codex, record: .text(.message, "Assistant response"))]
        let model = NativeHootChatModel(fixture: .object([.init("conversationId", .string("voice")), .init("events", .array(events.map(\.wireValue)))]))
        model.composerDraft.text = "Retain draft"; let saved = model.composerDraft
        let state = try await model.voiceTool("read", request: nil)
        XCTAssertEqual(state["replies"].elements?.count, 1)
        XCTAssertEqual(state["replies"].elements?.first?["text"].string, "Assistant response")
        XCTAssertEqual(model.composerDraft, saved)
        do { _ = try await model.voiceTool("speak", request: "nonexistent"); XCTFail("Unknown reply must be refused") } catch { }
        XCTAssertEqual(model.composerDraft, saved)
    }
    /// Review chat-ui #3: voice stops only when the last view of the chat closes.
    func testSharedChatVoiceStopsOnlyWhenTheLastViewCloses() {
        let mic = HootComposerVoice(available: false, observeHardware: false)
        mic.viewAppeared(); mic.viewAppeared()          // the page and the island
        XCTAssertFalse(mic.viewDisappeared(), "The island closing must not stop the page's voice")
        XCTAssertTrue(mic.viewDisappeared())
        XCTAssertTrue(mic.viewDisappeared(), "An unmatched disappear stays at zero")
        mic.viewAppeared()
        XCTAssertTrue(mic.viewDisappeared())
    }
}
