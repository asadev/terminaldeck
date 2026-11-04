import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckNative

@MainActor final class ChatFollowToolTests: XCTestCase {
    func testExistingFeatureDoorReadsAndScrollsEveryOpenViewWithoutSending() async throws {
        let model = NativeHootChatModel(fixture: .object([.init("conversationId", .string("scratch-follow")), .init("events", .array([]))]))
        let a = NativeChatFollowViewport(), b = NativeChatFollowViewport()
        model.chatViewports = [a.id: a, b.id: b]
        var pins = 0
        var moves: [CGFloat] = []
        a.pin = { pins += 1 }; b.pin = { pins += 1 }
        a.move = { moves.append($0) }; b.move = { moves.append($0) }
        let read = try await model.featureTool("follow", action: "read", args: .object([]))
        XCTAssertEqual(read["views"].elements?.count, 2)
        XCTAssertEqual(pins, 0)
        _ = try await model.featureTool("follow", action: "earlier", args: .object([]))
        XCTAssertEqual(moves.count, 2)
        XCTAssertTrue(moves.allSatisfy { $0 < 0 })
        XCTAssertFalse(a.following); XCTAssertFalse(b.following)
        _ = try await model.featureTool("follow", action: "latest", args: .object([]))
        XCTAssertEqual(pins, 2)
        XCTAssertTrue(a.following); XCTAssertTrue(b.following)
        XCTAssertTrue(model.composerDraft.text.isEmpty)
        XCTAssertThrowsError(try model.followTool("invented"))
    }
}

@MainActor final class RoutineChatFollowToolTests: XCTestCase {
    func testMountedRoutineViewsUseTheSameFollowActionsAndDetachCleanly() throws {
        let view = NativeChatFollowViewport()
        NativeRoutineChatFollow.attach(view, routine: "scratch-routine")
        defer { NativeRoutineChatFollow.detach(view, routine: "scratch-routine") }
        let read = try NativeRoutineChatFollow.tool("scratch-routine", "read")
        XCTAssertEqual(read["views"].elements?.count, 1)
        _ = try NativeRoutineChatFollow.tool("scratch-routine", "earlier")
        XCTAssertFalse(view.following)
        _ = try NativeRoutineChatFollow.tool("scratch-routine", "latest")
        XCTAssertTrue(view.following)
        NativeRoutineChatFollow.detach(view, routine: "scratch-routine")
        XCTAssertTrue(try NativeRoutineChatFollow.tool("scratch-routine", "read")["views"].elements?.isEmpty == true)
    }
}
