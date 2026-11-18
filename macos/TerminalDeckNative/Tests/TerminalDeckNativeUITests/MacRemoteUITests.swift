import AppKit
import SwiftUI
import XCTest
import TerminalDeckBackend
import TerminalDeckNativeCore
@testable import TerminalDeckNative

/// Native route and view models only. The engine is a scratch registry with fake sessions, never the working host.
@MainActor
final class MacRemoteUITests: XCTestCase {
    private var root: URL!
    private var graph: BackendCompositionRoot!
    private actor Calls {
        var values: [(String, [NativeRPCValue])] = []
        func add(_ channel: String, _ args: [NativeRPCValue]) { values.append((channel, args)) }
    }
    override func setUp() async throws {
        _ = NSApplication.shared
        root = FileManager.default.temporaryDirectory.appendingPathComponent("mac-remote-ui-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        graph = try BackendCompositionRoot(dataRoot: root, state: NativeStateStore(), environment: [:], home: root.path)
    }
    override func tearDown() async throws {
        await EngineBridge.shared.disconnectNative()
        try await graph.shutdown()
        try FileManager.default.removeItem(at: root)
    }
    private static var view: NativeRPCValue {
        .object([.init("machines", .array([.object([.init("id", .string("reach-fixture")), .init("name", .string("Fixture MacBook"))])])),
            .init("links", .array([.object([.init("id", .string("reach-fixture")), .init("machine", .string(CloudLiveUseUITests.ref)), .init("state", .string("online")),
                .init("sessions", .array([
                    .object([.init("id", .string("p1")), .init("tab", .string("tab-1")), .init("title", .string("Deck Dev")), .init("cwd", .string("/fixture/work")), .init("provider", .string("claude")), .init("status", .string("idle"))]),
                    .object([.init("id", .string("c9")), .init("tab", .string("tab-9")), .init("title", .string("Chat on MacBook")), .init("cwd", .string("/fixture/work")), .init("provider", .string("codex")), .init("status", .string("idle")), .init("chat", .bool(true))])]))])]))])
    }
    private func connect(_ calls: Calls) async throws {
        let view = Self.view
        let channels = ["machines:list", "machines:attach", "machines:detach", "machines:input", "machines:resize", "machines:chats", "machines:controls:read", "machines:account:read", "machines:usage:read", "settings:get", "prefs:get"]
        for channel in channels {
            try await graph.registry.register(channel, ownerID: "mac-remote-ui") { _, args in
                await calls.add(channel, args)
                if channel == "machines:list" { return view }
                if channel == "settings:get" || channel == "prefs:get" { return .object([]) }
                if channel == "machines:chats", ["options", "set"].contains(args.dropFirst().first?.string ?? "") {
                    return .object([.init("model", .string("codex:test")), .init("effort", .string("high")),
                        .init("models", .array([.object([.init("id", .string("codex:test")), .init("provider", .string("Codex")), .init("name", .string("Test model"))])])),
                        .init("efforts", .array([.string("high")]))])
                }
                return .bool(true)
            }
        }
        try await graph.retain(.init(name: "mac-remote-ui", domains: ["mac-remote-ui"], ownerID: "mac-remote-ui", invokes: Set(channels),
            events: ["machines:output", "machines:state", "machines:chats:events"], stop: {}))
        await graph.seal()
        try await EngineBridge.shared.configure(native: graph)
    }
    private func wait(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        let end = Date().addingTimeInterval(3)
        while !condition(), Date() < end { try? await Task.sleep(for: .milliseconds(5)) }
        XCTAssertTrue(condition(), "Fixture did not settle", file: file, line: line)
    }
    private func screen(_ session: NativeTerminalSession) -> String {
        (0..<30).compactMap { session.terminal.getTerminal().getScrollInvariantLine(row: $0)?.translateToString(trimRight: true) }.joined(separator: "\n")
    }

    func testCloudTerminalChoosesTheNativeMachineRouteAndSplitsWithoutASecondSession() async throws {
        let row = try CloudLiveUseUITests.row("tab-1", kind: "chat", on: false)
        let snapshot = try XCTUnwrap(MachinesSnapshot.decode(Self.view.foundation))
        let choice = NativeCloudLiveChoice.choose(row: row, links: snapshot)
        XCTAssertEqual(choice, .terminal(tabId: "machine reach-fixture p1"), "The live host's terminal type and link beat stale Cloud metadata")
        var calls: [String] = []
        let actions = NativeButtonActions(effects: .init(invoke: { channel, _ in calls.append(channel); return Self.view.foundation }, presentSession: { _ in }, confirm: { _ in true }))
        actions.ingest(TabsState(tabs: [], canNewTerminal: true, canNewBrowser: true, layout: WindowLayout(modeSwitch: false)))
        let opened = await actions.run(.selectTab(try XCTUnwrap(choice.tabId))).value
        XCTAssertTrue(opened)
        XCTAssertEqual(actions.tabs.activeID, choice.tabId)
        XCTAssertEqual(actions.tabs.tabs.count, 1)
        XCTAssertTrue(actions.tabs.layout?.modeSwitch == true, "The native-only session must offer Split even when the old page has no active session")
        let split = await actions.run(.setMode("split")).value
        XCTAssertTrue(split)
        XCTAssertEqual(actions.tabs.layout?.root?.leaves.first?.tabId, choice.tabId)
        XCTAssertEqual(actions.tabs.tabs.count, 1)
        XCTAssertFalse(calls.contains("machines:create") || calls.contains("session:create"))
        actions.retireRemoteViewer(try XCTUnwrap(choice.tabId))
        XCTAssertFalse(actions.tabs.tabs.contains { $0.id == choice.tabId })
        XCTAssertFalse(calls.contains("machines:close"), "A completed move retires only this viewer")
    }

    func testAccountSwitchReplacementOpensThroughTheSameNativeRoute() async throws {
        var routed: [PageCommand] = [], task: Task<Bool, Never>?
        let actions = NativeButtonActions(effects: .init(invoke: { _, _ in Self.view.foundation }, presentSession: { _ in }, confirm: { _ in true }))
        NativeMachineSessionRoute.open(tabId: "machine reach-fixture c9") { command in
            routed.append(command); task = actions.run(command)
        }
        let opened = await task?.value
        XCTAssertEqual(opened, true)
        XCTAssertEqual(routed.first?.name, "select-tab")
        XCTAssertEqual(actions.tabs.activeID, "machine reach-fixture c9")
        XCTAssertEqual(actions.tabs.tabs.count, 1)
    }

    func testRemoteTerminalStreamsReplacesReplayAndSendsPasteInOrder() async throws {
        let calls = Calls(); try await connect(calls)
        let terminal = NativeTerminalSession(target: .machine(machineId: "reach-fixture", sessionId: "p1"))
        defer { terminal.shutDown() }
        await wait { terminal.info?.title == "Deck Dev" && !terminal.ended }
        func output(_ text: String, reset: Bool = false, replay: Bool = false) async throws {
            try await graph.registry.publish("machines:output", arguments: [.object([.init("machineId", .string("reach-fixture")), .init("sessionId", .string("p1")),
                .init("data", .string(text)), .init("reset", .bool(reset)), .init("replay", .bool(replay))])])
        }
        try await output("old screen\r\n", reset: true, replay: true)
        try await output("live tail\r\n")
        await wait { self.screen(terminal).contains("live tail") }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = terminal.container
        defer { window.contentView = nil; window.close() }
        terminal.container.layoutSubtreeIfNeeded()
        terminal.terminal.eventDelegate?.sizeChanged(source: terminal.terminal, newCols: 132, newRows: 42)
        terminal.type(paste: "one\ntwo")
        terminal.type(paste: "three")
        try await Task.sleep(for: .milliseconds(30))
        let sent = await calls.values.filter { $0.0 == "machines:input" }
        let sizes = await calls.values.filter { $0.0 == "machines:resize" }
        XCTAssertTrue(sizes.contains { $0.1[2].number == 132 && $0.1[3].number == 42 })
        XCTAssertEqual(sent.map { $0.1[2].string }, ["one\rtwo", "three"])
        try await graph.registry.publish("machines:output", arguments: [.object([.init("machineId", .string("reach-fixture")), .init("sessionId", .string("p1")),
            .init("data", .string("")), .init("problem", .string("The previous connection ended"))])])
        await wait { terminal.note != nil }
        try await output("replacement screen\r\n", reset: true, replay: true)
        try await output("new tail\r\n")
        await wait { self.screen(terminal).contains("new tail") }
        XCTAssertFalse(screen(terminal).contains("old screen"), "Reconnect replay replaces the old buffer instead of appending it twice")
        XCTAssertNil(terminal.note, "A confirmed reattach clears the old connection error")
        terminal.shutDown()
        terminal.type(paste: "must not be sent")
        try await Task.sleep(for: .milliseconds(20))
        let after = await calls.values.filter { $0.0 == "machines:input" }
        XCTAssertEqual(after.count, 2)
    }

    func testRemoteChatNeverAttachesAPTYOrReadsALocalChatAndKeepsItsModelOnReopen() async throws {
        let calls = Calls(); try await connect(calls)
        let session = NativeTerminalSession(target: .machine(machineId: "reach-fixture", sessionId: "c9"))
        defer { session.shutDown() }
        await wait { session.isChat }
        XCTAssertTrue(session.isRemote)
        await session.remoteChat.open(machineId: "reach-fixture", chatId: "c9")
        session.remoteChat.receive(CloudLiveUseUITests.frame([CloudLiveUseUITests.event(1, .user, "hello")], busy: false).merging(["machineId": "reach-fixture"]) { _, new in new })
        await session.remoteChat.open(machineId: "reach-fixture", chatId: "c9")
        XCTAssertEqual(session.remoteChat.events.count, 1)
        XCTAssertEqual(session.remoteChat.options["model"].string, "codex:test")
        let sent = await calls.values
        XCTAssertFalse(sent.contains { $0.0 == "machines:attach" || $0.0.hasPrefix("session:chat") })
        XCTAssertEqual(sent.filter { $0.0 == "machines:chats" && $0.1[1].string == "watch" }.count, 1)
    }

    func testChatRewatchesAfterReconnectAndRestoresARefusedMessage() async throws {
        let live = NativeMachineChatLive()
        var sent: [[Any?]] = [], choices = 0
        live.send = { sent.append($0) }
        live.readOptions = { _ in choices += 1; return .object([]) }
        await live.open(machineId: "reach-m1", chatId: "c9")
        defer { live.close() }
        live.connectionChanged(false)
        XCTAssertNotNil(live.problem)
        live.connectionChanged(true)
        await wait { sent.filter { $0[1] as? String == "watch" }.count == 2 }
        await wait { choices == 2 }
        let accepted = await live.say("keep this message")
        XCTAssertTrue(accepted)
        let rid = try XCTUnwrap(sent.last?[5] as? String)
        live.receive(["machineId": "another", "frame": ["t": "error", "rid": rid, "message": "not mine"]])
        XCTAssertNil(live.unsentText)
        live.receive(["machineId": "reach-m1", "frame": ["t": "error", "rid": rid, "message": "This device may only view this chat."]])
        XCTAssertEqual(live.unsentText, "keep this message")
        XCTAssertEqual(live.problem, "This device may only view this chat.")
    }

    func testMoveKeepsTheNameAndExactlyOneRowWhileCloudOwnershipChanges() throws {
        let row = try CloudLiveUseUITests.row("tab-1", name: "Keep this name")
        var move = BackendCloudSessionMoveEntry(ref: row.ref, sessionId: "tab-1", role: .taker, step: .asked, moveId: "move", other: "MacBook", startedAt: 1)
        move.source = row
        let snapshot = try XCTUnwrap(MachinesSnapshot.decode(Self.view.foundation))
        let tab = "machine reach-fixture p1"
        let state = SidebarState(groups: [], projects: [.init(id: "machine:reach-fixture", title: "MacBook", expanded: true,
            sessions: [.init(id: tab, title: "Keep this name", kind: .session, status: "exited")])], selectedId: tab)
        for step in [BackendCloudSessionMoveEntry.Step.asked, .owner, .chat, .code, .launching, .failed] {
            move.step = step
            let rows = NativeCloudChats.retainingMoves([], moves: [move])
            XCTAssertEqual(rows.map(\.name), ["Keep this name"])
            let running = NativeRemoteSessionRows.running(state, localIDs: [], links: .empty,
                liveRefs: [tab: row.ref], moves: [row.ref: move], started: [:])
            XCTAssertEqual(running.map(\.id), [tab], "The keeper's local-only ids must not filter out a remote viewer")
            XCTAssertEqual(running.first?.title, "Keep this name")
            if !move.finished { XCTAssertEqual(running.first?.status, "working") }
            XCTAssertEqual(NativeCloudLiveChoice.shownOthers(rows, ownIDs: ["machine reach-fixture p1"], links: .empty,
                liveRefs: ["machine reach-fixture p1": row.ref]).count, 0, "The kept native viewer is still the one row when the host no longer lists it")
            XCTAssertEqual(NativeCloudLiveChoice.shownOthers(rows, ownIDs: [], links: snapshot).count, 1)
        }
        XCTAssertTrue(NativeRemoteSessionRows.chat("machine reach-fixture c9", links: snapshot))
        XCTAssertFalse(NativeRemoteSessionRows.chat(tab, links: snapshot))
        move.step = .done; move.launchedID = "new-local"
        XCTAssertTrue(NativeCloudChats.retainingMoves([], moves: [move]).isEmpty, "Only successful launch removes the temporary Cloud row")
        let encoded = try JSONEncoder().encode(move)
        XCTAssertEqual(try JSONDecoder().decode(BackendCloudSessionMoveEntry.self, from: encoded).source?.name, row.name)
    }

    func testMovingStateKeepsProgressForLaterStagesAndHidesTooLateCancel() throws {
        let row = try CloudLiveUseUITests.row("tab-1")
        let state = NativeCloudMoveLine.state(row: row, machine: "MacBook", move: ("Starting here…", true, false))
        XCTAssertEqual(state, .moving("Starting here…", canCancel: false))
    }

    func testSharedRemoteHeaderAndWritableChatPicturesBothThemes() async throws {
        try SessionPictureFixture.prepare()
        let calls = Calls(); try await connect(calls)
        let session = NativeTerminalSession(target: .machine(machineId: "reach-fixture", sessionId: "c9"))
        defer { session.shutDown() }
        await wait { session.isChat }
        await session.remoteChat.open(machineId: "reach-fixture", chatId: "c9")
        session.remoteChat.receive(["machineId": "reach-fixture", "frame": ["id": "c9", "events": [
            CloudLiveUseUITests.event(1, .user, "Continue the work from this Mac").wireValue.foundation,
            CloudLiveUseUITests.event(2, .message, "The session is still running on the MacBook. This is its live conversation.").wireValue.foundation], "busy": false, "reset": true]])
        let package = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let output = package.deletingLastPathComponent().appendingPathComponent("night/codex/mac-remote-evidence")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let size = NSSize(width: 1000, height: 650)
        for dark in [false, true] {
            let host = NSHostingView(rootView: NativeSessionBody(session: session) { NativeSessionHeader(session: session) }
                .environment(\.colorScheme, dark ? .dark : .light).environment(\.agkitOffscreenSolid, true)
                .frame(width: size.width, height: size.height))
            host.sizingOptions = []; host.frame = NSRect(origin: .zero, size: size)
            host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua); host.layoutSubtreeIfNeeded()
            for (name, rect) in [("whole", host.bounds), ("header", NSRect(x: 0, y: host.isFlipped ? 0 : size.height - 85, width: size.width, height: 85))] {
                let picture = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: rect))
                host.cacheDisplay(in: rect, to: picture)
                let png = try XCTUnwrap(picture.representation(using: .png, properties: [:]))
                try png.write(to: output.appendingPathComponent("remote-chat-\(name)-\(dark ? "dark" : "light").png"))
            }
        }
    }
}
