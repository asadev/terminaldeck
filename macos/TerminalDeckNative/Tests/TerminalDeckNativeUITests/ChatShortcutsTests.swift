import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckNative

@MainActor final class ChatShortcutsTests: XCTestCase {
    func testHelpAndFindUseSameDispatcherAndAdvertiseActualStopBinding() {
        let model = NativeHootChatModel(fixture: .object([]))
        NativeChatShortcuts.navigate(model, action: "shortcuts")
        XCTAssertTrue(model.chatShortcutsVisible)
        NativeChatShortcuts.navigate(model, action: "open")
        XCTAssertTrue(model.findVisible)
        XCTAssertEqual(NativeChatShortcuts.entries.first { $0.id == "stop" }?.keys, "⌘.")
        XCTAssertEqual(Set(NativeChatShortcuts.entries.map(\.id)).count, NativeChatShortcuts.entries.count)
        XCTAssertTrue(NativeChatShortcuts.wire.elements?.allSatisfy { !$0["condition"].isNullish } == true)
    }
}
