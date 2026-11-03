import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckNative

@MainActor final class ChatContextReadoutTests: XCTestCase {
    func testActualSnapshotReadingClearsWhenProviderOrConversationClearsIt() {
        let reading = NativeRPCValue.object([.init("state", .string("ok")), .init("tokens", .number(25000)), .init("window", .number(100000)), .init("percent", .number(25)), .init("windowBasis", .string("reported")), .init("reportedAt", .number(1000))])
        let model = NativeHootChatModel(fixture: .object([.init("conversationId", .string("first")), .init("events", .array([])), .init("contextReading", reading)]))
        XCTAssertEqual(model.chatContextReading?.tokens, 25000)
        XCTAssertEqual(model.chatContextReading?.window, 100000)
        model.acceptFixtureUpdate(.object([.init("conversationId", .string("first")), .init("sequence", .number(1)), .init("contextReading", .null)]))
        XCTAssertNil(model.chatContextReading)
        model.acceptFixtureUpdate(.object([.init("conversationId", .string("second")), .init("events", .array([]))]))
        XCTAssertEqual(model.chatContextState["state"].string, "not-reported")
        XCTAssertTrue(model.chatContextState["reading"].isNullish)
    }
}
