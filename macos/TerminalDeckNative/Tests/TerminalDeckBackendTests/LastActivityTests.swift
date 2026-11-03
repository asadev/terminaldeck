import Foundation
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

/// 1 Nov (Asad, item 58): the phone's Overview "Recent" said "Just now" for a session idle for hours. A session's
/// lastActivityAt is when something really happened inside it (`BackendSessionActivity`), never a refresh, a
/// snapshot, a phone opening it, a resize, or an AI screen repainting itself.
final class LastActivityTests: XCTestCase {
    private func manager() -> BackendPTYManager {
        let manager = BackendPTYManager(inheritedEnvironment: [:], onEvent: { _ in })
        addTeardownBlock { manager.beginShutdown(); _ = await manager.drain(timeoutMilliseconds: 2_000) }
        return manager
    }
    private func until(_ check: () -> Bool) async throws {
        for _ in 0..<150 where !check() { try await Task.sleep(for: .milliseconds(20)) }
    }

    func testTheRules() {
        XCTAssertTrue(BackendSessionActivity.outputCounts(provider: "shell", chat: false, at: 10, redrawUntil: nil))
        XCTAssertFalse(BackendSessionActivity.outputCounts(provider: "shell", chat: false, at: 10, redrawUntil: 20), "its redraw for a new size")
        XCTAssertTrue(BackendSessionActivity.outputCounts(provider: "shell", chat: false, at: 30, redrawUntil: 20))
        for ai in ["claude", "codex", "gemini"] {
            XCTAssertFalse(BackendSessionActivity.outputCounts(provider: ai, chat: false, at: 10, redrawUntil: nil), "\(ai)'s screen repainting")
        }
        XCTAssertFalse(BackendSessionActivity.outputCounts(provider: nil, chat: false, at: 10, redrawUntil: nil))
        for step in ["UserPromptSubmit", "PreToolUse", "PermissionRequest", "Stop", "BeforeAgent", "AfterAgent"] {
            XCTAssertTrue(BackendSessionActivity.hookCounts(step), step)
        }
        XCTAssertFalse(BackendSessionActivity.hookCounts("SessionEnd-ish"))
        XCTAssertEqual(BackendSessionActivity.lastActivityAt(createdAt: 5, live: nil, kept: nil), 5, "nothing known: its start")
        XCTAssertEqual(BackendSessionActivity.lastActivityAt(createdAt: 5, live: nil, kept: 9), 9, "kept from before a restart")
        XCTAssertEqual(BackendSessionActivity.lastActivityAt(createdAt: 5, live: 12, kept: 9), 12)
    }

    /// An AI session printing (its own repaints) and every way the app or a phone reads it leave the time alone;
    /// only its hook steps move it, and only forward.
    func testAnAISessionMovesOnlyOnItsOwnStepsNeverOnSnapshotsOrRefreshes() async throws {
        let manager = manager()
        let meta = try manager.create(.init(cwd: "/tmp", provider: "claude"),
            spawn: .init(provider: "claude", command: "/bin/sh", args: ["-c", "while :; do printf '\\r✻ thinking'; sleep 0.05; done"], path: "/usr/bin:/bin"))
        try await until { (manager.scrollbackText(meta.id) ?? "").contains("thinking") }
        XCTAssertTrue((manager.scrollbackText(meta.id) ?? "").contains("thinking"), "the screen did repaint")
        _ = manager.list(); _ = manager.screen(meta.id); _ = manager.scrollback(meta.id); _ = manager.remount(meta.id)
        _ = try manager.macUsed(meta.id, cols: 90, rows: 30)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertNil(manager.lastActivity(meta.id), "repaints, list, screen, snapshot, remount and a resize are not activity")
        manager.noteActivity(meta.id, at: 1_000)
        XCTAssertEqual(manager.lastActivity(meta.id), 1_000, "a hook step")
        manager.noteActivity(meta.id, at: 500)
        XCTAssertEqual(manager.lastActivity(meta.id), 1_000, "never backwards")
        _ = manager.remount(meta.id); _ = manager.list()
        XCTAssertEqual(manager.lastActivity(meta.id), 1_000)
    }

    /// A plain shell's output counts, but not its redraw for a new size (a phone or this Mac taking it).
    func testAShellsOutputCountsButItsRedrawForANewSizeDoesNot() async throws {
        let manager = manager()
        let meta = try manager.create(.init(cwd: "/tmp", provider: "shell"),
            spawn: .init(provider: "shell", command: "/bin/sh", args: ["-c", "trap 'echo resized' WINCH; while :; do sleep 0.05; done"], path: "/usr/bin:/bin"))
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertTrue(try manager.macUsed(meta.id, cols: 70, rows: 20), "the program was given a new size")
        try await until { (manager.scrollbackText(meta.id) ?? "").contains("resized") }
        XCTAssertTrue((manager.scrollbackText(meta.id) ?? "").contains("resized"), "it did redraw")
        XCTAssertNil(manager.lastActivity(meta.id), "a redraw for a new size is not activity")
        let before = Date().timeIntervalSince1970 * 1000
        try await Task.sleep(for: .milliseconds(Int(BackendSessionActivity.redrawQuietMilliseconds) + 100))
        _ = try manager.macUsed(meta.id, cols: 70, rows: 20) // same size: nothing redraws
        kill(try XCTUnwrap(manager.pidOf(meta.id)), SIGWINCH) // the shell prints by itself, outside any resize
        try await until { manager.lastActivity(meta.id) != nil }
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(manager.lastActivity(meta.id)), before, "its own output counts")
    }

    func testActivityChangesReachTheListenerForTheLedger() async throws {
        let manager = manager(), heard = Heard()
        manager.onActivity { id, at in heard.add(id, at) }
        let meta = try manager.create(.init(cwd: "/tmp", provider: "claude"),
            spawn: .init(provider: "claude", command: "/bin/cat", args: [], path: "/usr/bin:/bin"))
        manager.noteActivity(meta.id, at: 2_000); manager.noteActivity(meta.id, at: 1_000)
        XCTAssertEqual(heard.values, [meta.id + "@2000.0"])
    }

    /// The ledger keeps it across app restarts; every app start re-notes the helper's sessions, which is not activity.
    func testTheLedgerKeepsItForwardOnlyAndThroughAReNote() throws {
        var ledger = try NativeOpenSessionLedger(saved: [])
        try ledger.note("s1", saved: .object([.init("tabKey", .string("t1")), .init("lastSeenAt", .number(100))]))
        XCTAssertTrue(ledger.markActivity("s1", at: 50))
        XCTAssertFalse(ledger.markActivity("s1", at: 40), "never backwards")
        XCTAssertFalse(ledger.markActivity("unknown", at: 60))
        try ledger.note("s1", saved: .object([.init("tabKey", .string("t1")), .init("lastSeenAt", .number(9_999))]))
        XCTAssertEqual(ledger.get("s1")?[NativeOpenSessionLedger.activityKey].number, 50, "an app start's re-note keeps it")
        let restarted = try NativeOpenSessionLedger(saved: ledger.snapshot())
        var next = restarted
        try next.note("s1", saved: .object([.init("tabKey", .string("t1"))]))
        XCTAssertEqual(next.get("s1")?[NativeOpenSessionLedger.activityKey].number, 50, "kept across a restart")
    }

    /// 2 Nov (item 65): his iPresent and iMatch Backend sessions had their last turns on 1 Nov before the install
    /// that started keeping the time, so the phone showed their start ("2d ago"). Such a session reads its last
    /// real turn from its own transcript; a resume that only touches the file or adds other entries does not count.
    func testASessionWithNoKeptTimeReadsItsLastTurnFromItsOwnTranscript() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("td-act-" + UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let account = root.appendingPathComponent("account-logins/one"), home = root.appendingPathComponent(".claude")
        let id = "b35abc33-03a5-4e4b-8819-c462584aa573", cwd = "/Users/someone/i.Present"
        let folder = account.appendingPathComponent("projects/-Users-someone-i-Present")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let lines = [
            #"{"type":"user","timestamp":"2026-11-01T04:30:00.000Z","message":{"role":"user","content":"hello"}}"#,
            #"{"type":"assistant","timestamp":"2026-11-01T04:35:10.500Z","message":{"role":"assistant","content":[]}}"#,
            #"{"type":"user","timestamp":"2026-11-01T04:36:42.214Z","message":{"role":"user","content":"last"}}"#,
            #"{"type":"system","timestamp":"2026-11-02T00:10:00.000Z","subtype":"resume"}"#,
            #"{"type":"queue-operation","timestamp":"2026-11-02T00:11:00.000Z"}"#,
            "not json",
        ]
        try Data(lines.joined(separator: "\n").utf8).write(to: folder.appendingPathComponent(id + ".jsonl"))
        let saved = NativeRPCValue.object([.init("cwd", .string(cwd)), .init("provider", .string("claude")), .init("agentSessionId", .string(id))])
        let at = try XCTUnwrap(BackendSessionActivity.transcriptActivity(saved: saved, configDirectories: [home.path, account.path]))
        XCTAssertEqual(at, ISO8601DateFormatter().date(from: "2026-11-01T04:36:42Z")!.timeIntervalSince1970 * 1000 + 214, accuracy: 1)
        XCTAssertNil(BackendSessionActivity.transcriptActivity(saved: saved.setting("provider", .string("codex")), configDirectories: [account.path]))
        XCTAssertNil(BackendSessionActivity.transcriptActivity(saved: saved.setting("agentSessionId", .string("../x")), configDirectories: [account.path]))
        XCTAssertNil(BackendSessionActivity.transcriptActivity(saved: saved, configDirectories: [home.path]), "no transcript there")
    }

    /// 2 Nov (install-24 final check F2): a dev or scratch copy gives Claude CLAUDE_CONFIG_DIR=<data>/agent-homes/claude;
    /// its transcripts are read from there too, besides ~/.claude and every saved account login.
    func testEveryClaudeHomeTheAppConfiguresIsRead() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("LA-homes-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("home"), devData = root.appendingPathComponent("dev-data")
        try FileManager.default.createDirectory(at: devData.appendingPathComponent("account-logins/acct-1"), withIntermediateDirectories: true)
        // The environment the dev copy's sessions get (BackendScratchAgentHomes, as BackendCompositionSuppliers sets it).
        let environment = BackendScratchAgentHomes.environment([NativeLaunchSwitches.dataFolder: devData.path], home: home,
                                                               bundleID: BackendDevCopy.bundleID)
        let scratchClaude = try XCTUnwrap(environment["CLAUDE_CONFIG_DIR"])
        XCTAssertEqual(scratchClaude, devData.appendingPathComponent("agent-homes/claude").path)
        let homes = BackendSessionActivity.claudeHomes(home: home, dataRoot: devData, sessionEnvironment: environment)
        XCTAssertEqual(homes, [scratchClaude, home.appendingPathComponent(".claude").path, devData.appendingPathComponent("account-logins/acct-1").path])
        // The installed app (no override): ~/.claude and the account logins, as before.
        XCTAssertEqual(BackendSessionActivity.claudeHomes(home: home, dataRoot: devData, sessionEnvironment: [:]),
                       [home.appendingPathComponent(".claude").path, devData.appendingPathComponent("account-logins/acct-1").path])
        // A restored chat whose transcript is only in the scratch home now reads its last turn, not its start time.
        let cwd = "/Users/someone/dev", id = "0b1c2d3e-4f50-6172-8394-a5b6c7d8e9f0"
        let folder = URL(fileURLWithPath: scratchClaude).appendingPathComponent("projects/-Users-someone-dev")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(#"{"type":"assistant","timestamp":"2026-11-02T05:47:56.487Z","message":{"role":"assistant","content":[]}}"#.utf8)
            .write(to: folder.appendingPathComponent(id + ".jsonl"))
        let saved = NativeRPCValue.object([.init("cwd", .string(cwd)), .init("provider", .string("claude")), .init("agentSessionId", .string(id))])
        let at = try XCTUnwrap(BackendSessionActivity.transcriptActivity(saved: saved, configDirectories: homes))
        XCTAssertEqual(at, ISO8601DateFormatter().date(from: "2026-11-02T05:47:56Z")!.timeIntervalSince1970 * 1000 + 487, accuracy: 1)
    }

    #if TD_HOST_INTEGRATED
    /// 2 Nov (item 65): his sessions are Claude Code terminals run by the session host (keeper). Typing into one from
    /// this Mac (session:write -> lifecycle -> manager -> the keeper) moves its time; the keeper's own output does not.
    func testTypingIntoAKeeperHostedTerminalMovesItsTime() async throws {
        let root = URL(fileURLWithPath: "/tmp", isDirectory: true).resolvingSymlinksInPath().appendingPathComponent("tdh-act-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let paths = try BackendHOSTPaths(dataDirectory: root); _ = try paths.secret(create: true)
        let helper = BackendPTYManager(inheritedEnvironment: [:], onEvent: { _ in })
        let server = try BackendHOSTServer(paths: paths, hostVersion: "activity-fixture", manager: helper,
            launch: { try helper.hostCreate($0) }, snapshot: { helper.hostSnapshot($0) }, onIdle: {})
        let client = try BackendHOSTClient(paths: paths)
        let app = BackendPTYManager(inheritedEnvironment: ["HOME": root.path, "LANG": "en_US.UTF-8"], onEvent: { _ in })
        let bridge = BackendHOSTManagerBridge(client: client, write: { try client.write($0, bytes: $1, expectedCreatedAt: $2) },
            drain: { try await client.drain(timeoutMilliseconds: $0) }, setWatched: { try client.setWatched($0) },
            stampIndependent: { $0.ownerIndependent = true })
        let ready = XCTestExpectation(description: "attached")
        try app.installHOSTFrontend(bridge, ready: { ready.fulfill() }, disconnected: {})
        await fulfillment(of: [ready], timeout: 5)
        defer { client.detach(); server.stopListening(); helper.beginShutdown(); app.beginShutdown() }
        let heard = Heard(); app.onActivity { id, at in heard.add(id, at) }
        // A Claude-like program: it repaints by itself and echoes what it is sent.
        let input = BackendCreateSessionInput(cwd: root.path, cols: 100, rows: 30, provider: "claude")
        let hosted = try app.createHOST(input, spawn: BackendSpawnSpec(provider: "claude", command: "/bin/sh",
            args: ["-c", "while :; do printf '\\r* idle'; /bin/sleep 0.05; done & cat"], path: "/usr/bin:/bin", env: [:]),
            context: BackendLaunchContext(), machineID: "", independent: true)
        for _ in 0..<100 where !helper.scrollback(hosted.id).contains("idle") { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(helper.scrollback(hosted.id).contains("idle"), "the hosted program is repainting")
        XCTAssertNil(app.lastActivity(hosted.id), "a hosted AI repainting itself is not activity")
        let before = Date().timeIntervalSince1970 * 1000
        try app.write(hosted.id, data: "fix the login page\r")
        for _ in 0..<100 where !helper.scrollback(hosted.id).contains("fix the login") { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(helper.scrollback(hosted.id).contains("fix the login"), "the typing reached the keeper's program")
        let at = try XCTUnwrap(app.lastActivity(hosted.id), "typing into a keeper-hosted terminal moves its time")
        XCTAssertGreaterThanOrEqual(at, before)
        XCTAssertEqual(heard.values.count, 1, "and reaches the ledger listener")
        try client.stopAll(); _ = await helper.drain()
    }
    #endif

    /// Review install-24 S6: the transcript read runs off the remote-host actor (other devices' messages are answered
    /// meanwhile), and two replies asking at once still read each session's record only once.
    func testTheTranscriptReadRunsOffTheHostAndOncePerSession() async throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("td-seen-" + UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let state = NativeStateStore()
        try await state.startSessionLedger()
        try await state.ledgerNote("s1", saved: .object([.init("tabKey", .string("t1"))]))
        let trust = BackendRemoteTrustStore(directory: directory.appendingPathComponent("remote"))
        let host = BackendRemoteHost(trust: trust, manager: manager(), state: state, home: directory.path,
            hostName: "Test", appVersion: "test", privateRoots: [])
        let gate = ReadGate()
        await host.setRecordedActivity { _ in gate.read() }
        async let first = host.ledgerSeen()
        async let second = host.ledgerSeen()
        try await until { gate.reads >= 1 }
        let answered = Heard()
        Task { await host.setConnectionsHandler(nil); answered.add("answered", 0) }
        try await until { !answered.values.isEmpty }
        XCTAssertFalse(answered.values.isEmpty, "the host answers other messages while a transcript is being read")
        gate.open()
        let (a, b) = await (first, second)
        XCTAssertEqual(a["s1"], 42); XCTAssertEqual(b["s1"], 42)
        XCTAssertEqual(gate.reads, 1, "one read per session, even for two replies at once")
        let again = await host.ledgerSeen()
        XCTAssertEqual(again["s1"], 42); XCTAssertEqual(gate.reads, 1, "never read again in this run")
        await trust.close()
    }

    private final class ReadGate: @unchecked Sendable {
        private let lock = NSLock(), opened = DispatchSemaphore(value: 0); private var count = 0
        var reads: Int { lock.withLock { count } }
        func read() -> Double? { lock.withLock { count += 1 }; opened.wait(); opened.signal(); return 42 }
        func open() { opened.signal() }
    }

    private final class Heard: @unchecked Sendable {
        private let lock = NSLock(); private var items: [String] = []
        func add(_ id: String, _ at: Double) { lock.withLock { items.append(id + "@" + String(at)) } }
        var values: [String] { lock.withLock { items } }
    }
}
