import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckNative

final class ChatDiagnosticsTests: XCTestCase {
    func testOnlyReportedWarningsAndErrorsEnterDiagnosticsAndCommandsRoutePrecisely() {
        func event(_ n: Int, _ kind: HootChatKind, _ value: NativeRPCValue) -> HootChatEvent { .init(conversationID: "c", turnID: "t", sequence: n, provider: .claude, record: .init(kind, value: value)) }
        let records = NativeChatDiagnostics.records([
            event(1, .message, .object([.init("text", .string("ordinary answer mentioning a warning"))])),
            event(2, .error, .object([.init("text", .string("Provider connection failed"))])),
            event(3, .session, .object([.init("warnings", .array([.string("Actual warning")]))]))])
        XCTAssertEqual(records.count, 2)
        XCTAssertEqual(records.map(\.recordID), ["c:2", "c:3"])
        let offered = HootSlashCommand.offered(.array([.object([.init("name", .string("feedback"))])]))
        XCTAssertEqual(offered.first?.opensInApp, "Chat diagnostics")
        XCTAssertFalse(NativeChatDiagnostics.destinations.contains("reset"))
    }
}
