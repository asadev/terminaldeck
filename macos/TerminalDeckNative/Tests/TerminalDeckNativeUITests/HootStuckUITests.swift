import AppKit
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckNative

@MainActor final class HootStuckUITests: XCTestCase {
    func testReopenedComposerShowsSendForFinishedAnswerWhileChildKeepsRunning() {
        let event = HootChatEvent(conversationID: "stuck-fixture", turnID: "turn", sequence: 1, provider: .claude,
            record: .init(.completed, value: .object([])))
        let child = NativeRPCValue.object([.init("id", .string("background")), .init("title", .string("Scratch watcher")), .init("status", .string("running"))])
        let state = NativeRPCValue.object([.init("conversationId", .string("stuck-fixture")), .init("sequence", .number(1)),
            .init("events", .array([event.wireValue])), .init("alive", .bool(true)), .init("busy", .bool(true)),
            .init("foreground", .bool(false)), .init("answering", .bool(false)), .init("children", .array([child]))])
        let model = NativeHootChatModel(fixture: state, source: .session("scratch-stuck", provider: "claude"))
        XCTAssertFalse(model.busy)
        XCTAssertFalse(model.answering)
        XCTAssertEqual(model.childTasks.count, 1)
        model.acceptFixtureUpdate(state.setting("foreground", .bool(true)).setting("answering", .bool(true)))
        XCTAssertTrue(model.busy)
        XCTAssertTrue(model.answering)
        model.acceptFixtureUpdate(state.setting("alive", .bool(false)).setting("foreground", .bool(true)))
        XCTAssertFalse(model.busy, "A dead provider cannot leave a Stop button behind")
    }
    func testFinishedAndRunningComposerFrames() throws {
        guard let path = ProcessInfo.processInfo.environment["HOOT_STUCK_RENDER_DIR"] else { throw XCTSkip("Frames need an explicit scratch output folder.") }
        let output = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let events = [
            HootChatEvent(conversationID: "stuck-frame", turnID: "turn", sequence: 1, provider: .claude, record: .text(.user, "Has that check finished?")),
            HootChatEvent(conversationID: "stuck-frame", turnID: "turn", sequence: 2, provider: .claude, record: .text(.message, "The answer is complete. The background watcher is still running.")),
            HootChatEvent(conversationID: "stuck-frame", turnID: "turn", sequence: 3, provider: .claude, record: .init(.completed))]
        let child = NativeRPCValue.object([.init("id", .string("watcher")), .init("title", .string("Scratch background watcher")),
            .init("kind", .string("local_bash")), .init("status", .string("running"))])
        for dark in [false, true] {
            for width in [420, 1000] {
                for running in [false, true] {
                    let state = NativeRPCValue.object([.init("conversationId", .string("stuck-frame")), .init("sequence", .number(3)),
                        .init("events", .array(events.map(\.wireValue))), .init("alive", .bool(true)), .init("busy", .bool(true)),
                        .init("foreground", .bool(running)), .init("answering", .bool(running)), .init("children", .array([child]))])
                    let model = NativeHootChatModel(fixture: state, source: .session("scratch-frame", provider: "claude"))
                    try HOOTSIMRenderingTests.render(NativeHootChat(model: model), size: CGSize(width: width, height: 650), dark: dark,
                        to: output.appendingPathComponent("\(running ? "running" : "finished")-\(dark ? "dark" : "light")-\(width).png"))
                }
            }
        }
    }

}
