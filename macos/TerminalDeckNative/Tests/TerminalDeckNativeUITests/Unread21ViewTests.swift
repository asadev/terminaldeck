import AppKit
import SwiftUI
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckNative

@MainActor final class Unread21ViewTests: XCTestCase {
    private let messages = (2...5).map { ChatUnreadMessage(id: "m\($0)", sequence: $0) }
    func testOpeningAndPillBothTargetTheFirstUnseenMessage() {
        let view = NativeChatUnreadViewport()
        view.appear()
        view.receive(conversation: "c", seen: 2, messages: messages)
        XCTAssertEqual(view.dividerID, "m3")
        XCTAssertEqual(view.dividerCount, 3)
        XCTAssertEqual(view.firstUnseenTarget, "m3")
        XCTAssertEqual(view.position.viewID(type: String.self), "unread:m3")
        view.disappear()
        view.appear()
        view.receive(conversation: "c", seen: 5, messages: messages)
        view.geometry(CGRect(x: 0, y: 0, width: 600, height: 300), bottom: false)
        view.receive(conversation: "c", seen: 5, messages: messages + [.init(id: "m6", sequence: 6), .init(id: "m7", sequence: 7)])
        XCTAssertNil(view.dividerID)
        XCTAssertEqual(view.pillCount, 2)
        view.revealFirst()
        XCTAssertEqual(view.dividerID, "m6")
        XCTAssertEqual(view.position.viewID(type: String.self), "unread:m6")
        view.disappear()
    }
    func testWatchingTheBottomNeverAddsADividerForAnArrivalOrAnOwnMessage() {
        let view = NativeChatUnreadViewport()
        view.appear(); view.active = true
        view.receive(conversation: "c", seen: 5, messages: messages)
        view.geometry(.init(x: 0, y: 0, width: 600, height: 300), bottom: true)
        view.receive(conversation: "c", seen: 5, messages: messages + [.init(id: "m6", sequence: 6)])
        XCTAssertNil(view.dividerID); XCTAssertEqual(view.pillCount, 0)
        view.disappear()
    }
    func testDividerOnlyFadesAfterThreeSecondsInAnActiveVisibleWindow() async throws {
        let view = NativeChatUnreadViewport()
        var receipts: [Int] = []
        view.save = { sequence, _ in receipts.append(sequence) }
        view.appear(); view.receive(conversation: "c", seen: 2, messages: messages)
        view.layout(["unread:m3": .init(x: 0, y: 0, width: 600, height: 25),
                     "m3": .init(x: 0, y: 30, width: 600, height: 100),
                     "m4": .init(x: 0, y: 500, width: 600, height: 100)])
        view.geometry(.init(x: 0, y: 0, width: 600, height: 300), bottom: false)
        try await Task.sleep(for: .milliseconds(3100))
        XCTAssertEqual(view.dividerID, "m3"); XCTAssertTrue(receipts.isEmpty)
        view.active = true
        try await Task.sleep(for: .milliseconds(100))
        view.active = false
        try await Task.sleep(for: .milliseconds(3100))
        XCTAssertEqual(view.dividerID, "m3"); XCTAssertTrue(receipts.isEmpty)
        view.active = true
        try await Task.sleep(for: .milliseconds(3150))
        XCTAssertNil(view.dividerID); XCTAssertEqual(receipts, [3])
        XCTAssertEqual(view.seen, 3, "An offscreen message stays unread")
        view.disappear()
    }
    func testLeavingBeforeTheDelayKeepsTheMessagesUnread() async throws {
        let view = NativeChatUnreadViewport()
        view.appear(); view.receive(conversation: "c", seen: 2, messages: messages)
        view.layout(["unread:m3": .init(x: 0, y: 0, width: 600, height: 25), "m3": .init(x: 0, y: 30, width: 600, height: 100)])
        view.geometry(.init(x: 0, y: 0, width: 600, height: 300), bottom: false)
        view.active = true; view.disappear()
        try await Task.sleep(for: .milliseconds(3100))
        XCTAssertEqual(view.seen, 2)
        view.appear(); view.receive(conversation: "c", seen: 2, messages: messages)
        XCTAssertEqual(view.dividerID, "m3")
        view.disappear()
    }
    func testSidebarCountsFollowTheSameMarker() {
        let counts = NativeChatUnreadCounts()
        counts.accept(.object([.init("unread", .object([.init("count", .number(3))]))]), id: "session")
        let sidebar = SidebarState(groups: [], projects: [.init(id: "p", title: "P", expanded: true,
            sessions: [.init(id: "session", title: "Chat", kind: .session)])], selectedId: nil)
        XCTAssertTrue(counts.decorate(sidebar).projects[0].sessions[0].unread)
        counts.accept(.object([.init("unread", .object([.init("count", .number(0))]))]), id: "session")
        XCTAssertFalse(counts.decorate(sidebar).projects[0].sessions[0].unread)
    }
    func testRenderSharedChatLightAndDarkWithNewMessages() throws {
        guard let output = ProcessInfo.processInfo.environment["UNREAD21_RENDER_OUTPUT"] else { return XCTFail("Set the owned frame directory") }
        let folder = URL(fileURLWithPath: output)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let events = [
            HootChatEvent(conversationID: "render", turnID: "old", sequence: 1, provider: .claude, record: .text(.user, id: "own", "How is the inbox work going?")),
            HootChatEvent(conversationID: "render", turnID: "old", sequence: 2, provider: .claude, record: .text(.message, id: "old", "The earlier messages are kept above.")),
            HootChatEvent(conversationID: "render", turnID: "new1", sequence: 3, provider: .claude, record: .text(.message, id: "first", "The chat changes are ready to read. This is the first message you haven’t seen yet.")),
            HootChatEvent(conversationID: "render", turnID: "new2", sequence: 4, provider: .claude, record: .text(.message, id: "second", "Scroll down for the rest. The divider clears after a few seconds in the active window."))]
        let fixture = NativeRPCValue.object([.init("conversationId", .string("render")), .init("sequence", .number(4)),
            .init("events", .array(events.map(\.wireValue))), .init("alive", .bool(true)),
            .init("unread", ChatUnreadMessages.summary(events, seen: 2))])
        for dark in [false, true] {
            let model = NativeHootChatModel(fixture: fixture)
            let size = CGSize(width: 920, height: 680)
            let host = NSHostingView(rootView: NativeHootChat(model: model)
                .environment(\.colorScheme, dark ? .dark : .light).environment(\.agkitOffscreenSolid, true)
                .frame(width: size.width, height: size.height).background(Color(nsColor: .windowBackgroundColor)))
            let window = NSWindow(contentRect: .init(origin: .init(x: -30000, y: -30000), size: size), styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            window.contentView = host
            for _ in 0..<8 { host.layoutSubtreeIfNeeded(); RunLoop.main.run(until: Date().addingTimeInterval(0.12)) }
            XCTAssertFalse(window.isVisible)
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                .write(to: folder.appendingPathComponent("unread21-\(dark ? "dark" : "light").png"))
            window.contentView = nil; window.close()
        }
    }
}
