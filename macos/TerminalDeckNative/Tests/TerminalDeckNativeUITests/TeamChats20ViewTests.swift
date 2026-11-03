import XCTest
import TerminalDeckNativeCore
import TerminalDeckBackend
@testable import TerminalDeckNative

@MainActor final class TeamChats20ViewTests: XCTestCase {
    private func snapshot(_ range: ClosedRange<Int>, finished: Bool) -> NativeRPCValue {
        let events = range.map { HootChatEvent(conversationID: "job", turnID: "turn", sequence: $0, provider: .claude,
            record: .init(.message, value: .object([.init("text", .string("Line \($0)"))]))) }
        return .object([.init("conversationId", .string("job")), .init("sequence", .number(600)), .init("events", .array(events.map(\.wireValue))),
            .init("readOnly", .bool(finished)), .init("alive", .bool(!finished)), .init("busy", .bool(false))])
    }
    func testOpeningFinishedHistoryDoesNotWakeAnAIAndKeepsEarlierPages() {
        let model = NativeHootChatModel(fixture: snapshot(1...500, finished: true), source: .session("job", provider: "claude"))
        model.acceptFixtureUpdate(snapshot(501...600, finished: true))
        XCTAssertTrue(model.readOnly)
        XCTAssertFalse(model.alive)
        XCTAssertEqual(model.rows.count, 600)
        XCTAssertEqual(model.rows.first?.value["text"].string, "Line 1")
        model.wakeIfNeeded()
        XCTAssertFalse(model.alive)
    }
    func testFinishedPushMarksTheOpenChatReadOnlyWithoutLosingMessages() {
        let model = NativeHootChatModel(fixture: snapshot(1...3, finished: false), source: .session("job", provider: "claude"))
        XCTAssertFalse(model.readOnly)
        model.acceptFixtureUpdate(snapshot(3...4, finished: true))
        XCTAssertTrue(model.readOnly)
        XCTAssertEqual(model.rows.count, 4)
    }
    func testLaterIdlePushCannotMakeFinishedHistoryWritable() {
        let model = NativeHootChatModel(fixture: snapshot(1...4, finished: true), source: .session("job", provider: "claude"))
        model.acceptFixtureUpdate(snapshot(3...4, finished: false))
        XCTAssertTrue(model.readOnly)
        XCTAssertEqual(model.status, "Finished · Saved history")
        XCTAssertEqual(model.avatarState, .stopped)
    }
    func testAnOlderHistoryPageStillLoadsWithoutOverwritingFinishedState() {
        let model = NativeHootChatModel(fixture: snapshot(501...600, finished: true), source: .session("job", provider: "claude"))
        model.acceptFixtureUpdate(snapshot(1...500, finished: false).setting("sequence", .number(599)))
        XCTAssertTrue(model.readOnly)
        XCTAssertFalse(model.alive)
        XCTAssertEqual(model.rows.count, 600)
    }

    func testPhoneStartsKeepTheirExistingPath() throws {
        XCTAssertThrowsError(try NativeTeamChatStartPolicy.requireDesktop(.remote))
        for kind in [BackendDeckCoreSecurityCaller.Kind.local, .key, .session] {
            XCTAssertNoThrow(try NativeTeamChatStartPolicy.requireDesktop(kind))
        }
    }

}
