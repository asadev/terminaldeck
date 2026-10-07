import Foundation
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

@MainActor final class BackendMacAppWindowsRegistryTests: XCTestCase {
    func testOpensSameSessionAndStartsNothing() throws {
        let r = BackendMacAppWindowsTestRig(), result = try r.registry.open("s1")
        XCTAssertEqual(result["ok"], .bool(true)); XCTAssertEqual(r.windows.count, 1); XCTAssertTrue(r.registry.isPopped("s1"))
        XCTAssertEqual(try r.registry.view()["windows"].elements?.map { $0["sessionId"] }, [.string("s1")])
        XCTAssertEqual(r.events.last ?? nil, .object([.init("kind", .string("opened")), .init("sessionId", .string("s1"))]))
        XCTAssertEqual(r.windows[0].windowTitle, "Session 1"); XCTAssertEqual(r.windows[0].sessionID, "s1")
    }
    func testForwardsOnlyItsSessionOutputAndBroadcastsSmallPushes() throws {
        let r = BackendMacAppWindowsTestRig(); _ = try r.registry.open("s1")
        r.registry.forward("session:data", arguments: [.string("s1"), .string("hello")])
        r.registry.forward("session:data", arguments: [.string("s2"), .string("not for you")])
        r.registry.forward("session:status", arguments: [.string("s2"), .string("idle")])
        XCTAssertEqual(r.windows[0].pushes.filter { $0.channel == "session:data" }.map(\.arguments), [[.string("s1"), .string("hello")]])
        XCTAssertTrue(r.windows[0].pushes.contains { $0.channel == "session:status" })
    }
    func testDoesNotForwardUnconsumedStreams() throws {
        let r = BackendMacAppWindowsTestRig(); _ = try r.registry.open("s1")
        r.registry.forward("devices:frame", arguments: [.object([])]); r.registry.forward("machines:output", arguments: [.string("m"), .string("x")])
        XCTAssertEqual(r.windows[0].pushes.count, 0)
    }
    func testRedButtonDocksAndNeverEndsSession() throws {
        let r = BackendMacAppWindowsTestRig(); _ = try r.registry.open("s1"); r.windows[0].close()
        XCTAssertFalse(r.registry.isPopped("s1")); XCTAssertNotNil(r.sessions["s1"])
        XCTAssertEqual(r.events.last ?? nil, .object([.init("kind", .string("docked")), .init("sessionId", .string("s1")), .init("select", .bool(false))]))
        XCTAssertEqual(r.disk.file["windows"], .array([]))
    }
    func testExplicitDockSelectsMainWindow() throws {
        let r = BackendMacAppWindowsTestRig(); _ = try r.registry.open("s1")
        let result = try r.registry.dock("s1", select: true)
        XCTAssertEqual(result["message"], .string("It is back in the main window.")); XCTAssertTrue(r.windows[0].destroyed)
        XCTAssertEqual(r.events.last ?? nil, .object([.init("kind", .string("docked")), .init("sessionId", .string("s1")), .init("select", .bool(true))]))
        XCTAssertEqual(r.shownMain, [nil])
    }
    func testRepeatedOpenFocusesExistingWindow() throws {
        let r = BackendMacAppWindowsTestRig(); _ = try r.registry.open("s1"); r.windows[0].minimized = true
        let result = try r.registry.open("s1")
        XCTAssertEqual(result["ok"], .bool(true)); XCTAssertEqual(result["message"], .string("That session already has its own window; it is in front now."))
        XCTAssertEqual(r.windows.count, 1); XCTAssertTrue(r.windows[0].focused); XCTAssertFalse(r.windows[0].minimized)
    }
    func testHootAndMissingSessionsRefuseWithSentences() throws {
        let r = BackendMacAppWindowsTestRig()
        XCTAssertEqual(try r.registry.open("copilot")["message"], .string("Hoot stays in the main window."))
        XCTAssertEqual(try r.registry.open("nope")["message"], .string("No session with that id is running on this computer."))
        XCTAssertEqual(r.windows.count, 0)
    }
    func testNamedDisplayAndMissingDisplay() throws {
        let r = BackendMacAppWindowsTestRig()
        XCTAssertEqual(try r.registry.open("s2", displayID: 7)["display"], .string("DELL U2723QE"))
        XCTAssertEqual(try r.registry.view()["windows"].elements?.first?["displayId"], .number(7))
        XCTAssertEqual(try r.registry.open("s1", displayID: 42)["ok"], .bool(false))
    }
    func testWindowTitleTracksSessionLabel() throws {
        let r = BackendMacAppWindowsTestRig(); _ = try r.registry.open("s1")
        r.registry.setLabels(.object([.init("s1", .string("Fix the parser"))]))
        XCTAssertEqual(r.windows[0].windowTitle, "Fix the parser"); XCTAssertEqual(try r.registry.view()["windows"].elements?.first?["label"], .string("Fix the parser"))
    }
    func testCommandWClosesWindowWithoutDeletingSession() throws {
        let r = BackendMacAppWindowsTestRig(); _ = try r.registry.open("s1"); r.windows[0].focused = true
        XCTAssertTrue(try r.registry.routeMenu("session.close")); XCTAssertFalse(r.registry.isPopped("s1")); XCTAssertNotNil(r.sessions["s1"])
        XCTAssertEqual(r.events.last ?? nil, .object([.init("kind", .string("docked")), .init("sessionId", .string("s1")), .init("select", .bool(false))]))
    }
    func testOtherMenuCommandsReachMainOwner() throws {
        let r = BackendMacAppWindowsTestRig(); _ = try r.registry.open("s1"); r.windows[0].focused = true
        XCTAssertTrue(try r.registry.routeMenu("session.new")); XCTAssertEqual(r.shownMain, ["session.new"]); XCTAssertTrue(r.registry.isPopped("s1"))
    }
    func testUnfocusedPopoutDoesNotStealMenu() throws {
        let r = BackendMacAppWindowsTestRig(); _ = try r.registry.open("s1")
        XCTAssertFalse(try r.registry.routeMenu("session.close")); XCTAssertTrue(r.registry.isPopped("s1"))
    }
    func testRestartRestoresPlacementForSameTabUnderNewSessionID() throws {
        let disk = BackendMacAppWindowsTestDisk(), before = BackendMacAppWindowsTestRig(disk: disk)
        _ = try before.registry.open("s1"); before.windows[0].move(.init(x: 2100, y: 200, width: 1000, height: 700)); before.flushScheduled(); before.registry.suspend()
        XCTAssertTrue(before.windows[0].destroyed); XCTAssertFalse(before.events.contains { $0?["kind"].string == "docked" })
        let after = BackendMacAppWindowsTestRig(disk: disk); after.sessions["s1"] = nil; after.sessions["s9"] = after.meta("s9", tab: "tab-one", title: "Session 1")
        XCTAssertEqual(try after.registry.restore(Array(after.sessions.values)), ["s9"])
        XCTAssertEqual(after.windows[0].bounds, .init(x: 2100, y: 200, width: 1000, height: 700))
        XCTAssertEqual(try after.registry.view()["windows"].elements?.first?["displayId"], .number(7))
    }
    func testUnpluggedMonitorFallsBackToPrimary() throws {
        let disk = BackendMacAppWindowsTestDisk(), before = BackendMacAppWindowsTestRig(disk: disk)
        _ = try before.registry.open("s1"); before.windows[0].move(.init(x: 2100, y: 200, width: 1000, height: 700)); before.flushScheduled(); before.registry.suspend()
        let after = BackendMacAppWindowsTestRig(disk: disk); after.displayList = [after.laptop]
        _ = try after.registry.restore(Array(after.sessions.values)); let bounds = after.windows[0].bounds
        XCTAssertGreaterThanOrEqual(bounds.x, 0); XCTAssertLessThanOrEqual(bounds.x + bounds.width, 1512)
        XCTAssertEqual(try after.registry.view()["windows"].elements?.first?["displayId"], .number(1))
    }
    func testClosedWindowDoesNotReturnAfterRestart() throws {
        let disk = BackendMacAppWindowsTestDisk(), before = BackendMacAppWindowsTestRig(disk: disk)
        _ = try before.registry.open("s1"); before.windows[0].close()
        let after = BackendMacAppWindowsTestRig(disk: disk)
        XCTAssertEqual(try after.registry.restore(Array(after.sessions.values)), [])
    }
    func testMainReloadDoesNotRestoreTwice() throws {
        let disk = BackendMacAppWindowsTestDisk(), before = BackendMacAppWindowsTestRig(disk: disk)
        _ = try before.registry.open("s1"); before.registry.suspend()
        let after = BackendMacAppWindowsTestRig(disk: disk)
        _ = try after.registry.restore(Array(after.sessions.values)); _ = try after.registry.restore(Array(after.sessions.values))
        XCTAssertEqual(after.windows.count, 1)
    }
    func testEndedSessionWindowClosesAndForgetsPlacement() throws {
        let r = BackendMacAppWindowsTestRig(); _ = try r.registry.open("s1"); r.registry.sessionEnded("s1")
        XCTAssertTrue(r.windows[0].destroyed); XCTAssertNil(r.events.last ?? nil); XCTAssertEqual(r.disk.file["windows"], .array([]))
    }
    func testAccountReplacementFollowsSameWindowAndReceivesNewOutput() throws {
        let r = BackendMacAppWindowsTestRig(); _ = try r.registry.open("s1"); r.sessions["s1b"] = r.meta("s1b", tab: "tab-one", title: "Session 1")
        r.registry.forward("session:switched", arguments: [.string("s1"), .object([.init("id", .string("s1b"))]), .string("")])
        XCTAssertFalse(r.registry.isPopped("s1")); XCTAssertTrue(r.registry.isPopped("s1b"))
        r.registry.forward("session:data", arguments: [.string("s1b"), .string("new account")])
        XCTAssertTrue(r.windows[0].pushes.contains { $0.channel == "session:data" && $0.arguments.last == .string("new account") })
    }
    func testReplacementMustComeFromWindowThatHoldsSession() throws {
        let r = BackendMacAppWindowsTestRig(); _ = try r.registry.open("s1"); r.sessions["s1b"] = r.meta("s1b", tab: "tab-one", title: "Session 1")
        XCTAssertEqual(r.registry.rekey(ownerID: "wrong", previousID: "s1", nextID: "s1b")["ok"], .bool(false))
        XCTAssertEqual(r.registry.rekey(ownerID: r.windows[0].ownerID, previousID: "s1", nextID: "s1b")["ok"], .bool(true))
        XCTAssertEqual(r.replaced.map(\.0), ["s1"]); XCTAssertEqual(r.replaced.map { $0.1.id }, ["s1b"])
    }
    func testRegistersAllChannelsSelfIdentityAndMainCommandAllowList() async throws {
        let r = BackendMacAppWindowsTestRig(), channels = NativeChannelRegistry()
        _ = try await r.registry.register(on: channels)
        let names = await channels.channels(); XCTAssertEqual(names, ["popout:dock", "popout:focus", "popout:list", "popout:open", "popout:rekey"])
        let main = NativeRPCContext(caller: .nativeApp, ownerID: "main")
        _ = try await channels.invoke("popout:open", context: main, arguments: [.string("s1"), .object([.init("at", .object([.init("x", .number(2500)), .init("y", .number(300))]))])])
        let own = NativeRPCContext(caller: .nativeApp, ownerID: r.windows[0].ownerID)
        let listed = try await channels.invoke("popout:list", context: own, arguments: [])
        XCTAssertEqual(listed["self"], .number(Double(r.windows[0].windowID)))
        _ = try await channels.send("popout:show-main", context: main, arguments: [.string("view.mcp")])
        _ = try await channels.send("popout:show-main", context: main, arguments: [.string("something.else")])
        XCTAssertEqual(r.shownMain, ["view.mcp", nil]); XCTAssertTrue(BackendOSPopoutRules.mainCommands.contains("view.mcp"))
        _ = try await channels.send("popout:labels", context: main, arguments: [.object([.init("s1", .string("Renamed"))])])
        XCTAssertEqual(r.windows[0].windowTitle, "Renamed")
    }
    func testDebounceIs400MillisecondsAndCancelledOnSuspend() throws {
        let r = BackendMacAppWindowsTestRig(); _ = try r.registry.open("s1"); let before = r.writeCount
        r.windows[0].move(.init(x: 2100, y: 200, width: 1000, height: 700))
        XCTAssertEqual(r.scheduled.last?.milliseconds, 400); XCTAssertEqual(r.writeCount, before)
        r.registry.suspend(); let after = r.writeCount; r.flushScheduled()
        XCTAssertEqual(r.writeCount, after)
    }
}

@MainActor final class BackendMacAppWindowsTestDisk { var file = NativeRPCValue.null }
@MainActor final class BackendMacAppWindowsTestWindow: BackendMacAppWindowsHandle {
    struct Push { let channel: String; let arguments: [NativeRPCValue] }
    let windowID: Int, ownerID: String, sessionID: String
    var bounds: BackendOSPopoutRules.Rect, windowTitle: String
    var normalBounds: BackendOSPopoutRules.Rect { bounds }
    var fullScreen = false, minimized = false, focused = false, destroyed = false
    var contentDestroyed: Bool { destroyed }
    var pushes: [Push] = [], listeners: [String: [@MainActor () -> Void]] = [:]
    init(id: Int, session: String, bounds: BackendOSPopoutRules.Rect, title: String) { windowID = id; ownerID = "owner-\(id + 1000)"; sessionID = session; self.bounds = bounds; windowTitle = title }
    func title(_ value: String) { windowTitle = value }
    func fullscreen(_ on: Bool) { fullScreen = on }
    func restore() { minimized = false }
    func show() {}
    func focus() { focused = true }
    func close() { if destroyed { return }; emit("close"); destroyed = true; emit("closed") }
    func send(_ channel: String, arguments: [NativeRPCValue]) { pushes.append(.init(channel: channel, arguments: arguments)) }
    func on(_ event: String, callback: @escaping @MainActor () -> Void) { listeners[event, default: []].append(callback) }
    func emit(_ event: String) { for callback in listeners[event] ?? [] { callback() } }
    func move(_ bounds: BackendOSPopoutRules.Rect) { self.bounds = bounds; emit("move") }
}
@MainActor final class BackendMacAppWindowsTestRig: BackendMacAppWindowsDependencies {
    final class Scheduled { let milliseconds: Int; let run: @MainActor () -> Void; var cancelled = false; init(_ ms: Int, _ run: @escaping @MainActor () -> Void) { milliseconds = ms; self.run = run } }
    let laptop = BackendOSPopoutRules.Display(id: 1, label: "Built-in Retina Display", bounds: .init(x: 0, y: 0, width: 1512, height: 982), workArea: .init(x: 0, y: 38, width: 1512, height: 944))
    let monitor = BackendOSPopoutRules.Display(id: 7, label: "DELL U2723QE", bounds: .init(x: 1512, y: 0, width: 2560, height: 1440), workArea: .init(x: 1512, y: 25, width: 2560, height: 1415))
    let disk: BackendMacAppWindowsTestDisk
    lazy var registry = BackendMacAppWindowsRegistry(dependencies: self)
    var windows: [BackendMacAppWindowsTestWindow] = [], events: [NativeRPCValue?] = [], shownMain: [String?] = [], replaced: [(String, BackendSessionMeta)] = []
    var sessions: [String: BackendSessionMeta] = [:], displayList: [BackendOSPopoutRules.Display] = [], scheduled: [Scheduled] = [], writeCount = 0
    init(disk: BackendMacAppWindowsTestDisk? = nil) {
        self.disk = disk ?? BackendMacAppWindowsTestDisk(); displayList = [laptop, monitor]
        sessions = ["s1": meta("s1", tab: "tab-one", title: "Session 1"), "s2": meta("s2", tab: "tab-two", title: "Session 2"), "copilot": meta("copilot", tab: nil, title: "Hoot")]
    }
    func meta(_ id: String, tab: String?, title: String) -> BackendSessionMeta {
        var input = BackendCreateSessionInput(cwd: "/work/api", provider: "claude"); input.tabKey = tab
        let spawn = BackendSpawnSpec(provider: "claude", command: "/fake/claude", args: [], path: "/fake", tabKey: tab)
        var meta = BackendSessionMeta(id: id, input: input, spawn: spawn); meta.title = title; return meta
    }
    func makeWindow(sessionID: String, bounds: BackendOSPopoutRules.Rect, title: String) -> any BackendMacAppWindowsHandle {
        let window = BackendMacAppWindowsTestWindow(id: windows.count + 100, session: sessionID, bounds: bounds, title: title); windows.append(window); return window
    }
    func displays() -> (all: [BackendOSPopoutRules.Display], primary: BackendOSPopoutRules.Display) { (displayList, laptop) }
    func mainBounds() -> BackendOSPopoutRules.Rect? { .init(x: 60, y: 60, width: 1300, height: 860) }
    func showMain(command: String?) { shownMain.append(command) }
    func session(_ id: String) -> BackendSessionMeta? { sessions[id] }
    func refusal(_ id: String) -> String? { id == "copilot" ? "Hoot stays in the main window." : nil }
    func status(_ id: String) -> String? { "working" }
    func readPlacements() -> NativeRPCValue { disk.file }
    func writePlacements(_ file: NativeRPCValue) { disk.file = file; writeCount += 1 }
    func announce(view: NativeRPCValue, event: NativeRPCValue?) { events.append(event) }
    func announceReplaced(previousID: String, meta: BackendSessionMeta) { replaced.append((previousID, meta)) }
    func schedule(milliseconds: Int, run: @escaping @MainActor () -> Void) -> BackendMacAppWindowsScheduled {
        let entry = Scheduled(milliseconds, run); scheduled.append(entry); return BackendMacAppWindowsScheduled { entry.cancelled = true }
    }
    func flushScheduled() { let ready = scheduled; scheduled = []; for entry in ready where !entry.cancelled { entry.run() } }
    func log(_ message: String, detail: NativeRPCValue) {}
}
