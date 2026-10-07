import Foundation
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

@MainActor private final class BackendHootFakeCancel: BackendHootCancellation {
    var cancelled = false
    func cancel() { cancelled = true }
}
@MainActor private final class BackendHootFakeClock {
    struct Job { let at: Double; let run: @MainActor () -> Void; let token: BackendHootFakeCancel }
    var now = 0.0, jobs: [Job] = []
    func schedule(_ run: @escaping @MainActor () -> Void, _ ms: Int) -> any BackendHootCancellation {
        let token = BackendHootFakeCancel(); jobs.append(.init(at: now + Double(ms), run: run, token: token)); return token
    }
    func advance(_ ms: Double) {
        let end = now + ms
        while let due = jobs.enumerated().filter({ !$0.element.token.cancelled && $0.element.at <= end }).min(by: { $0.element.at < $1.element.at }) {
            let job = jobs.remove(at: due.offset); now = job.at; job.run()
        }; now = end
    }
}
@MainActor private final class BackendHootFakeIsland: BackendHootIslandSurface {
    let ownerID = "42"
    var destroyed = false, focused = false, bounds = CGRect.zero
    var placed: [CGRect] = [], sent: [(String, [NativeRPCValue])] = [], ignoring: [Bool] = [], menus: [[BackendHootMenuAction]] = []
    var events: [String: @MainActor () -> Void] = [:], focuses = 0, blurs = 0, visible = false
    func setBounds(_ bounds: CGRect) { self.bounds = bounds; placed.append(bounds) }
    func showInactive() { visible = true }
    func focus() { focuses += 1; emit("focus") }
    func blur() { blurs += 1; emit("blur") }
    func destroy() { destroyed = true }
    func ignoreMouseEvents(_ ignore: Bool) { ignoring.append(ignore) }
    func send(_ channel: String, arguments: [NativeRPCValue]) { sent.append((channel, arguments)) }
    func menu(_ actions: [BackendHootMenuAction]) { menus.append(actions) }
    func on(_ event: String, action: @escaping @MainActor () -> Void) { events[event] = action }
    func emit(_ event: String) { if event == "focus" { focused = true }; if event == "blur" { focused = false }; events[event]?() }
}
@MainActor private final class BackendHootFakeCatcher: BackendHootCatcherSurface {
    let ownerID = "77"
    var destroyed = false, bounds = CGRect.zero, ignoring: [Bool] = []
    func setBounds(_ bounds: CGRect) { self.bounds = bounds }
    func showInactive() { }
    func ignoreMouseEvents(_ ignore: Bool) { ignoring.append(ignore) }
    func destroy() { destroyed = true }
}
@MainActor private final class BackendHootMenuRig {
    let clock = BackendHootFakeClock(), surface = BackendHootFakeIsland(), catcher = BackendHootFakeCatcher()
    var settings: [String: NativeRPCValue] = [:], said: [(String, String)] = [], shown: [String] = [], opened: [String?] = []
    var watched: [(String, String?)] = [], watcher: BackendHootFakeCancel?, update: (@MainActor ([NativeRPCValue], Bool) -> Void)?
    var own = BackendHootMenuSessionState(status: "running", sessionID: "hoot-1", cwd: "/copilot", agentSessionID: "agent-1")
    var sessions = [IslandSessionRow(id: "hoot-1", label: "copilot", status: "working"), IslandSessionRow(id: "s1", label: "api", status: "working"), IslandSessionRow(id: "s2", label: "web", status: "idle")]
    var place = BackendHootIslandPlace(display: CGRect(x: 0, y: 0, width: 1920, height: 1080), barHeight: 30)
    var theme = "dark", reads = 0, quits = 0, changes = 0
    var failSay = false, failStart = false
    lazy var bar = BackendHootMenuBar(.init(
        makeIsland: { self.surface }, makeCatcher: { self.catcher }, place: { self.place },
        read: { self.settings[$0] ?? .missing }, write: { patch in for f in patch.fields ?? [] { self.settings[f.key] = f.value } },
        hoot: { self.reads += 1; return self.own }, startHoot: { @MainActor () async throws -> String? in
            if self.failStart { throw NativeRPCError(code: "unavailable", message: "Start unavailable.") }
            self.own.status = "running"; self.own.sessionID = "hoot-1"; return nil
        }, say: { id, text in
            if self.failSay { throw NativeRPCError(code: "unavailable", message: "PTY unavailable.") }; self.said.append((id, text))
        }, watchChat: { cwd, id, update in
            self.watched.append((cwd, id)); self.update = update; let token = BackendHootFakeCancel(); self.watcher = token; return token
        }, sessions: { self.sessions }, isHoot: { $0 == "hoot-1" },
        showSession: { self.shown.append($0) }, openApp: { self.opened.append($0) }, quit: { self.quits += 1 },
        shownChanged: { self.changes += 1 }, appearance: { self.theme },
        schedule: { self.clock.schedule($0, $1) }, now: { self.clock.now }))
}

final class BackendHootMenuBarTests: XCTestCase {
    @MainActor func testFixedWindowAndCatcherPlacement() throws {
        let r = BackendHootMenuRig(); try r.bar.apply(); try r.bar.apply()
        XCTAssertEqual(r.surface.bounds, CGRect(x: 426, y: 0, width: 1068, height: 576))
        XCTAssertEqual(r.surface.placed.count, 1); XCTAssertTrue(r.surface.visible)
        r.bar.event("hoot-panel:size", owner: "42", argument: .object([.init("width", .number(110)), .init("height", .number(30))]))
        XCTAssertEqual(r.catcher.bounds, CGRect(x: 905, y: 0, width: 110, height: 30))
        r.bar.event("hoot-panel:focus", owner: "42"); r.bar.event("hoot-panel:close", owner: "42")
        try r.bar.resize(owner: "42", argument: .object([.init("width", .number(820)), .init("height", .number(360))]))
        XCTAssertEqual(r.surface.placed.count, 1)
        r.place.display = CGRect(x: 0, y: 0, width: 2560, height: 1440); r.bar.displaysChanged()
        XCTAssertEqual(r.surface.placed.count, 2); XCTAssertEqual(r.surface.bounds.midX, 1280)
    }
    @MainActor func testEnabledSizeAndNonNumbers() throws {
        let r = BackendHootMenuRig(); XCTAssertTrue(r.bar.menuBarEnabled())
        r.settings[BackendHootMenuBar.menuBarKey] = .bool(false); try r.bar.apply(); XCTAssertFalse(r.surface.visible)
        _ = try r.bar.configure(.object([.init("enabled", .bool(true))])); XCTAssertTrue(r.surface.visible)
        XCTAssertNil(r.bar.rememberedSize())
        try r.bar.resize(owner: "42", argument: .object([.init("width", .number(5000)), .init("height", .number(40))]))
        XCTAssertEqual(r.bar.rememberedSize(), CGSize(width: 960, height: 180))
        try r.bar.resize(owner: "77", argument: .object([.init("width", .number(700)), .init("height", .number(300))]))
        try r.bar.resize(owner: "42", argument: .object([.init("width", .number(.nan)), .init("height", .number(300))]))
        XCTAssertEqual(r.bar.rememberedSize(), CGSize(width: 960, height: 180))
        _ = try r.bar.configure(.object([.init("enabled", .bool(false))])); XCTAssertTrue(r.surface.destroyed); XCTAssertTrue(r.catcher.destroyed)
    }
    @MainActor func testIntentDelaysHoldingAndSenderFence() throws {
        let r = BackendHootMenuRig(); try r.bar.apply()
        r.bar.event("hoot-panel:focus", owner: "wrong"); XCTAssertEqual(r.bar.snapshot()["expanded"], .bool(false))
        r.bar.event("hoot-panel:catch", owner: "77", argument: .string("enter")); r.clock.advance(119)
        XCTAssertEqual(r.bar.snapshot()["expanded"], .bool(false)); r.clock.advance(1)
        XCTAssertEqual(r.bar.snapshot()["expanded"], .bool(true)); XCTAssertEqual(r.surface.focuses, 0)
        r.bar.event("hoot-panel:held", owner: "42", argument: .bool(true))
        r.bar.event("hoot-panel:pointer", owner: "42", argument: .bool(false)); r.clock.advance(1000)
        XCTAssertEqual(r.bar.snapshot()["expanded"], .bool(true))
        r.bar.event("hoot-panel:held", owner: "42", argument: .bool(false)); r.clock.advance(99)
        XCTAssertEqual(r.bar.snapshot()["expanded"], .bool(true)); r.clock.advance(1)
        XCTAssertEqual(r.bar.snapshot()["expanded"], .bool(false)); XCTAssertEqual(r.catcher.ignoring.last, false)
    }
    @MainActor func testEscapeQuietAndFocusGrace() throws {
        let r = BackendHootMenuRig(); try r.bar.apply()
        r.bar.event("hoot-panel:catch", owner: "77", argument: .string("press")); XCTAssertEqual(r.surface.focuses, 1)
        r.surface.emit("blur"); XCTAssertEqual(r.bar.snapshot()["expanded"], .bool(true))
        r.bar.event("hoot-panel:pointer", owner: "42", argument: .bool(false)); r.clock.advance(100)
        XCTAssertEqual(r.bar.snapshot()["expanded"], .bool(false))
        r.bar.event("hoot-panel:catch", owner: "77", argument: .string("press")); r.clock.advance(500); r.surface.emit("blur")
        XCTAssertEqual(r.bar.snapshot()["expanded"], .bool(false))
        r.bar.event("hoot-panel:catch", owner: "77", argument: .string("enter")); r.clock.advance(200)
        XCTAssertEqual(r.bar.snapshot()["expanded"], .bool(false))
        r.bar.event("hoot-panel:catch", owner: "77", argument: .string("leave")); r.bar.event("hoot-panel:catch", owner: "77", argument: .string("enter")); r.clock.advance(120)
        XCTAssertEqual(r.bar.snapshot()["expanded"], .bool(true))
    }
    @MainActor func testOwnSessionCountsMomentCooldownAndTheme() throws {
        let r = BackendHootMenuRig(); r.own.status = "starting"; r.own.sessionID = nil; try r.bar.apply()
        XCTAssertEqual(r.bar.snapshot()["sessions"].elements?.count, 2)
        XCTAssertEqual(r.bar.snapshot()["label"]["text"], .string("2 open · 1 working"))
        XCTAssertEqual(r.bar.showSession("hoot-1")["ok"], .bool(false))
        r.bar.setLabels(.object([.init("s2", .string("Session 2"))])); let reads = r.reads
        r.sessions[2] = .init(id: "s2", label: "web", status: "input"); r.bar.forward("session:status", arguments: []); r.clock.advance(60)
        XCTAssertGreaterThan(r.reads, reads)
        XCTAssertEqual(r.bar.snapshot()["label"]["text"], .string("Session 2 needs you"))
        r.clock.advance(4000); XCTAssertEqual(r.bar.snapshot()["label"]["text"], .string("2 open · 1 working · 1 waiting"))
        r.theme = "light"; r.bar.forward("prefs:changed", arguments: [])
        XCTAssertEqual(r.surface.sent.last?.1.first?["appearance"], .string("light"))
    }
    @MainActor func testMessageSubmissionAndTranscriptLifecycle() async throws {
        let r = BackendHootMenuRig(); try r.bar.apply()
        XCTAssertEqual(r.bar.say(.string("  hello  "))["ok"], .bool(true)); XCTAssertEqual(r.said.first?.0, "hoot-1"); XCTAssertEqual(r.said.first?.1, "hello")
        _ = r.bar.say(.string(String(repeating: "a", count: 5000))); XCTAssertEqual(r.said.last?.1.utf16.count, 4000)
        r.failSay = true; XCTAssertEqual(r.bar.say(.string("hello"))["message"], .string("Hoot did not take that message."))
        r.own.status = "stopped"; XCTAssertEqual(r.bar.say(.string("hello"))["message"], .string("Hoot isn’t running."))
        let started = await r.bar.startHoot(); XCTAssertEqual(started["ok"], .bool(true)); _ = r.bar.openPanel()
        XCTAssertEqual(r.watched.first?.0, "/copilot")
        let rows: [NativeRPCValue] = (0..<20).map { .object([.init("id", .string(String($0))), .init("text", .string("line")), .init("role", .string("agent"))]) }
        r.update?(rows, false); XCTAssertEqual(r.bar.snapshot()["messages"].elements?.count, 12)
        r.update?([rows[19].setting("text", .string("grew"))], false)
        XCTAssertEqual(r.bar.snapshot()["messages"].elements?.last?["text"], .string("grew"))
        r.bar.event("hoot-panel:close", owner: "42"); XCTAssertTrue(r.watcher?.cancelled == true)
    }
    @MainActor func testBackgroundMenuAndOpenSession() throws {
        let r = BackendHootMenuRig(); try r.bar.apply(); r.bar.event("hoot-panel:menu", owner: "77")
        XCTAssertEqual(r.surface.menus.first?.map(\.label), ["Open Terminal Deck", "Settings…", nil, "Quit and Stop All Sessions"])
        r.surface.menus[0][0].run?(); r.surface.menus[0][1].run?(); r.surface.menus[0][3].run?()
        XCTAssertEqual(r.opened.count, 2); XCTAssertEqual(r.opened[1], "hoot-settings"); XCTAssertEqual(r.quits, 1)
        _ = r.bar.openPanel(); XCTAssertEqual(r.bar.showSession("s2")["ok"], .bool(true)); XCTAssertEqual(r.shown, ["s2"])
        XCTAssertEqual(r.bar.snapshot()["expanded"], .bool(false))
    }
    @MainActor func testExactChannelsAndNativeContextFence() async throws {
        let r = BackendHootMenuRig(), registry = NativeChannelRegistry(); try r.bar.apply(); try await r.bar.register(in: registry)
        let channels = await registry.channels()
        XCTAssertEqual(channels, ["hoot-menubar:config", "hoot-menubar:configure", "hoot-menubar:open", "hoot-panel:say", "hoot-panel:show-session", "hoot-panel:snapshot", "hoot-panel:start-hoot"])
        do { _ = try await registry.invoke("hoot-panel:say", context: .init(caller: .pairedDevice, ownerID: "42"), arguments: [.string("hello")]); XCTFail("Remote caller reached local island") } catch { XCTAssertEqual((error as? NativeRPCError)?.code, "access-denied") }
        _ = try await registry.send("hoot-panel:focus", context: .init(caller: .nativeApp, ownerID: "wrong"), arguments: [])
        XCTAssertEqual(r.bar.snapshot()["expanded"], .bool(false))
        _ = try await registry.send("hoot-panel:focus", context: .init(caller: .nativeApp, ownerID: "42"), arguments: [])
        XCTAssertEqual(r.bar.snapshot()["expanded"], .bool(true)); await r.bar.unregister(in: registry)
        XCTAssertTrue(r.surface.destroyed); XCTAssertTrue(r.catcher.destroyed)
    }
}
