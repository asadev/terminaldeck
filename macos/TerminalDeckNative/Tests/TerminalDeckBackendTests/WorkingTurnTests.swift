import Foundation
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

/// 2 Nov 2026 (lane/working-turn): a busy agent session said "Working" for ~70 ms, then "Idle", every 1 to 4 s, so the
/// Memory page, Agents page, desk lines and the phone list mostly said Idle while it worked. A hooked AI session is now
/// Working from its turn's start to its end. `testScriptedAgentTurn...` is the before/after: a stand-in Claude screen
/// (spinner every 0.1 s, no sign the screen reader knows, like Claude Code 2.1) with the real PTY, lifecycle, memory
/// engine and store; the raw screen reading is what the shipped app showed before.
final class WorkingTurnTests: XCTestCase, @unchecked Sendable {
    typealias Turn = BackendSessionTurn
    private let timing = BackendSessionTurn.Timing()

    // MARK: The turn rules

    func testInputKinds() {
        XCTAssertEqual(Turn.Input("\u{1b}"), .interrupt)
        XCTAssertEqual(Turn.Input("\u{03}"), .interrupt)
        XCTAssertEqual(Turn.Input("\u{1b}[27u"), .interrupt, "Esc in the kitty keyboard protocol")
        XCTAssertEqual(Turn.Input("\u{1b}[I"), .other, "a focus report")
        XCTAssertEqual(Turn.Input("\u{1b}[<35;10;5M"), .other, "a mouse report")
        XCTAssertEqual(Turn.Input("\u{1b}[A"), .other, "an arrow key is not typing")
        XCTAssertEqual(Turn.Input("hello"), .typing)
        XCTAssertEqual(Turn.Input("hello\r"), .submit)
        XCTAssertEqual(Turn.Input("\r"), .submit)
    }

    func testHookMapping() {
        XCTAssertEqual(Turn.status(provider: "claude", event: "UserPromptSubmit", sessionProvider: "claude"), .working)
        XCTAssertEqual(Turn.status(provider: "claude", event: "PostToolUse", sessionProvider: "claude"), .working)
        XCTAssertEqual(Turn.status(provider: "claude", event: "Stop", sessionProvider: "claude"), .completed)
        XCTAssertEqual(Turn.status(provider: "claude", event: "PermissionRequest", sessionProvider: "claude"), .input)
        XCTAssertEqual(Turn.status(provider: "codex", event: "Stop", sessionProvider: "codex"), .completed)
        XCTAssertEqual(Turn.status(provider: "gemini", event: "BeforeAgent", sessionProvider: "gemini"), .working)
        XCTAssertEqual(Turn.status(provider: "claude", event: "SessionEnd", sessionProvider: "shell"), .waiting)
        XCTAssertNil(Turn.status(provider: "claude", event: "CwdChanged", sessionProvider: "claude"))
    }

    /// 3 Nov: Claude's 60-second "waiting for your input" reminder is not a question (it held the host restart).
    func testClaudeNotificationIsAQuestionOnlyWhenItsKindAsks() {
        func notification(_ kind: String?) -> BackendSessionStatus? {
            Turn.status(provider: "claude", event: "Notification", sessionProvider: "claude", notificationType: kind)
        }
        XCTAssertNil(notification("idle_prompt"), "the idle reminder leaves a finished turn finished")
        XCTAssertNil(notification("auth_success"))
        XCTAssertNil(notification("agent_completed"))
        XCTAssertEqual(notification("permission_prompt"), .input)
        XCTAssertEqual(notification("elicitation_dialog"), .input)
        XCTAssertEqual(notification("agent_needs_input"), .input)
        XCTAssertEqual(notification(nil), .input, "an older CLI without a kind keeps the old meaning")
        XCTAssertEqual(Turn.status(provider: "gemini", event: "Notification", sessionProvider: "gemini", notificationType: "idle_prompt"), .input,
                       "only Claude's kinds are read")
        var turn = Turn(status: .working, at: 0)
        turn.hook(.completed, at: 1_000)
        if let next = notification("idle_prompt") { turn.hook(next, at: 61_000) }
        XCTAssertEqual(turn.status, .completed)
    }

    func testAWorkingTurnHoldsThroughOutputAndEndsOnItsHook() {
        var turn = Turn(status: .waiting, at: 0)
        turn.hook(.working, at: 0)
        for at in stride(from: 0.0, through: 60_000, by: 100) {
            turn.output(at: at)
            XCTAssertNil(turn.settle(now: at, timing: timing, screenAsks: false), "a busy screen never ends the turn")
        }
        XCTAssertEqual(turn.status, .working)
        turn.hook(.completed, at: 60_000)
        XCTAssertNil(turn.due(now: 60_000, timing: timing), "a finished turn needs no watch")
        turn.output(at: 61_000)
        XCTAssertEqual(turn.status, .completed, "a redraw is not a new turn")
    }

    func testATurnWhoseScreenGoesStillWithoutItsHookEnds() {
        var turn = Turn(status: .waiting, at: 0)
        turn.hook(.working, at: 0)
        for at in stride(from: 0.0, through: 5_000, by: 100) { turn.output(at: at) }
        XCTAssertEqual(turn.due(now: 5_000, timing: timing), 8_000)
        XCTAssertNil(turn.settle(now: 12_999, timing: timing, screenAsks: false))
        XCTAssertEqual(turn.settle(now: 13_000, timing: timing, screenAsks: false), .waiting)
        var asking = Turn(status: .working, at: 0)
        XCTAssertEqual(asking.settle(now: 8_000, timing: timing, screenAsks: true), .input, "an approval asked without a hook")
    }

    func testEscEndsTheTurnOnceTheScreenIsStill() {
        var turn = Turn(status: .working, at: 0)
        turn.output(at: 2_000)
        turn.input(.interrupt, at: 2_000)
        turn.output(at: 2_150)                    // Claude: "Interrupted", then nothing
        XCTAssertNil(turn.settle(now: 3_400, timing: timing, screenAsks: false), "not before 1.5 s after the key")
        XCTAssertEqual(turn.settle(now: 3_500, timing: timing, screenAsks: false), .waiting)
        // A screen still busy after the key (the key did not stop it): the turn goes on until the screen is still.
        var busy = Turn(status: .working, at: 0)
        busy.input(.interrupt, at: 1_000)
        for at in stride(from: 1_000.0, through: 6_000, by: 100) { busy.output(at: at) }
        XCTAssertNil(busy.settle(now: 6_000, timing: timing, screenAsks: false))
        XCTAssertEqual(busy.settle(now: 7_000, timing: timing, screenAsks: false), .waiting)
        // A hook after the key: the turn went on.
        var resumed = Turn(status: .working, at: 0)
        resumed.input(.interrupt, at: 1_000); resumed.hook(.working, at: 1_200)
        XCTAssertNil(resumed.settle(now: 3_000, timing: timing, screenAsks: false))
    }

    func testEnterStartsATurnItsHookConfirms() {
        var turn = Turn(status: .completed, at: 0)
        turn.input(.typing, at: 1_000)
        XCTAssertEqual(turn.status, .completed, "typing a message is not a turn")
        turn.input(.submit, at: 2_000)
        XCTAssertEqual(turn.status, .working, "Enter shows Working at once")
        turn.hook(.working, at: 2_300)            // UserPromptSubmit
        XCTAssertNil(turn.settle(now: 6_000, timing: timing, screenAsks: false), "confirmed by its hook")
        // Enter that started nothing (an empty prompt, a menu): back to what it was once its screen is still.
        var empty = Turn(status: .completed, at: 0)
        empty.input(.submit, at: 1_000); empty.output(at: 1_050)
        XCTAssertNil(empty.settle(now: 3_999, timing: timing, screenAsks: false))
        XCTAssertEqual(empty.settle(now: 4_000, timing: timing, screenAsks: false), .completed)
        // Enter while working queues a message: nothing changes.
        var running = Turn(status: .working, at: 0)
        running.input(.submit, at: 500)
        XCTAssertNil(running.settle(now: 5_000, timing: timing, screenAsks: false))
        XCTAssertEqual(running.status, .working)
    }

    func testAnswerToAQuestionResumesTheTurn() {
        var turn = Turn(status: .working, at: 0)
        turn.hook(.input, at: 1_000)              // PermissionRequest
        XCTAssertNil(turn.due(now: 60_000, timing: timing), "a question waits for the person as long as it takes")
        turn.input(.other, at: 2_000)
        XCTAssertEqual(turn.status, .input, "focus and mouse are not an answer")
        turn.input(.typing, at: 3_000)            // "1" = Yes
        XCTAssertEqual(turn.status, .working)
    }

    // MARK: The lifecycle

    func testFocusMouseAndOutputNoLongerWipeAWorkingTurn() async throws {
        try await withLifecycle(provider: "claude", script: "stty -echo; cat >/dev/null") { lifecycle, id, recorder in
            await lifecycle.noteHook(Self.hook("UserPromptSubmit", id))
            await lifecycle.noteSessionEvent(.data(id: id, text: "✻ Pondering…"))
            await lifecycle.noteSessionEvent(.status(id: id, status: .idle))
            try await lifecycle.write(sessionID: id, data: "\u{1b}[I")
            try await lifecycle.write(sessionID: id, data: "\u{1b}[<35;10;5M")
            try await lifecycle.write(sessionID: id, data: "next idea")
            let status = await lifecycle.status(sessionID: id)
            XCTAssertEqual(status, .working)
            XCTAssertEqual(recorder.accepted, [.working], "no flip to the screen's reading")
            await lifecycle.noteHook(Self.hook("Stop", id))
            XCTAssertEqual(recorder.accepted, [.working, .completed])
        }
    }

    func testAShellsAgentLeavingHandsTheStatusBackToItsScreen() async throws {
        try await withLifecycle(provider: "shell", script: "stty -echo; cat >/dev/null") { lifecycle, id, recorder in
            await lifecycle.noteHook(Self.hook("UserPromptSubmit", id))
            await lifecycle.noteHook(Self.hook("SessionEnd", id))
            XCTAssertEqual(recorder.accepted, [.working, .waiting])
            await lifecycle.noteSessionEvent(.status(id: id, status: .idle))
            let status = await lifecycle.status(sessionID: id)
            XCTAssertEqual(status, .idle, "a plain shell again: its screen decides")
        }
    }

    func testTheWatchEndsATurnWhoseStopNeverCame() async throws {
        try await withLifecycle(provider: "claude", script: "stty -echo; cat >/dev/null") { lifecycle, id, recorder in
            await lifecycle.setTurnTimingForTesting(.init(quiet: 300, interruptQuiet: 100, interruptWait: 150, confirm: 200))
            await lifecycle.noteHook(Self.hook("PreToolUse", id))
            try await Self.until(seconds: 3) { recorder.accepted.last == .waiting }
            XCTAssertEqual(recorder.accepted, [.working, .waiting])
        }
    }

    /// The before/after. Prints both timelines for the result note.
    func testScriptedAgentTurnIsWorkingForTheWholeTurnOnTheBoardToo() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("WorkingTurn-" + UUID().uuidString + ".noindex")
        defer { try? FileManager.default.removeItem(at: base) }
        let store = try await DeckMemoryStore.open(root: base.appendingPathComponent("memory"), dataRoot: base.appendingPathComponent("data"),
                                                   embedder: nil, watch: false, now: { Date() })
        try await store.setValue("0", key: DeckMemoryFlowKeys.tidyOn, owner: nil)
        var dependencies = DeckMemoryFlowEngine.Dependencies(store: { DeckMemoryFlowStoreAdapter(store) }, clock: BackendTaskTimers.realClock,
            stateFile: .init(url: base.appendingPathComponent("flow.json")), runner: DeckMemoryFlowTests.Runner([]), installedAIs: { ["claude"] })
        dependencies.stamp = { id in DeckMemoryStamp(owner: .lead("imatch"), project: "imatch", session: id, agent: "claude") }
        let engine = DeckMemoryFlowEngine(dependencies)
        await engine.start()
        defer { Task { await engine.stop(); await store.close() } }

        try await withLifecycle(provider: "claude", script: Self.claudeScreen, engine: engine) { lifecycle, id, recorder in
            engine.post(.sessionSeen(.init(id: id, title: "Deck Dev", provider: "claude", project: "imatch")))
            // Behind the session host the hooks arrive this way (BackendSessionTurnFeed), in order.
            let feed = BackendSessionTurnFeed(lifecycle)
            feed.post(Self.hook("SessionStart", id))
            try await Task.sleep(for: .milliseconds(400))
            let start = Self.now()
            try await lifecycle.write(sessionID: id, data: "turn\r")
            try await Task.sleep(for: .milliseconds(150)); feed.post(Self.hook("UserPromptSubmit", id))
            var samples: [(at: Double, accepted: BackendSessionStatus, screen: BackendSessionStatus?, board: String?)] = []
            var tool = 0
            while !(lifecycle.manager.screen(id) ?? "").contains("⏺ Done") {
                let at = Self.now() - start
                if tool == 0, at > 1_000 { feed.post(Self.hook("PreToolUse", id)); tool = 1 }
                if tool == 1, at > 5_000 { feed.post(Self.hook("PostToolUse", id)); tool = 2 }
                let doing = try await store.board(.init(limit: 50)).first { $0.id == "session:" + id }?.doing
                let accepted = await lifecycle.status(sessionID: id)
                samples.append((at, accepted, lifecycle.manager.knownStatus(id), doing))
                XCTAssertLessThan(at, 30_000, "the stand-in screen never finished"); if at > 30_000 { break }
                try await Task.sleep(for: .milliseconds(200))
            }
            let turnEnded = Self.now() - start
            feed.post(Self.hook("Stop", id))
            try await Task.sleep(for: .milliseconds(3_600))
            let finished = try await store.board(.init(limit: 50)).first { $0.id == "session:" + id }?.doing

            let screenWorking = samples.filter { $0.screen == .working }.count
            print(String(format: "WORKING-TURN turn %.1f s, %d samples every 200 ms", turnEnded / 1000, samples.count))
            print("WORKING-TURN before (screen reading, what the shipped app showed): working in \(screenWorking) of \(samples.count) samples; flips \(recorder.rawFlips)")
            print("WORKING-TURN after (accepted): \(recorder.acceptedTimeline)")
            print("WORKING-TURN board: " + samples.map { "\(Int($0.at / 100) * 100) ms \($0.board ?? "-")" }.joined(separator: ", ") + "; after Stop: \(finished ?? "-")")
            print("WORKING-TURN screen reading per sample: " + samples.map { $0.screen?.rawValue ?? "-" }.joined(separator: " "))

            XCTAssertGreaterThan(turnEnded, 6_000)
            XCTAssertTrue(samples.allSatisfy { $0.accepted == .working }, "Working at every moment of the turn")
            let held = samples.filter { $0.at > 3_600 }
            XCTAssertFalse(held.isEmpty)
            XCTAssertTrue(held.allSatisfy { $0.board == "Working" }, "the stored board says Working once it held 3 s, to the end")
            XCTAssertEqual(finished, "Finished its turn")
            let during = recorder.acceptedTimeline.filter { $0.at >= start && $0.at <= start + turnEnded }.map { $0.status }
            XCTAssertEqual(Array(Set(during)), [.working], "no other status was published during the turn")
        }
    }

    func testEscOnTheScriptedAgentEndsItsTurnWithoutAStop() async throws {
        try await withLifecycle(provider: "claude", script: Self.claudeScreen) { lifecycle, id, recorder in
            await lifecycle.noteHook(Self.hook("SessionStart", id))
            let start = Self.now()
            try await lifecycle.write(sessionID: id, data: "short\r")
            await lifecycle.noteHook(Self.hook("UserPromptSubmit", id))
            try await Task.sleep(for: .milliseconds(500))
            try await lifecycle.write(sessionID: id, data: "\u{1b}")
            try await Task.sleep(for: .milliseconds(800))
            let during = await lifecycle.status(sessionID: id)
            XCTAssertEqual(during, .working, "still working right after the key")
            try await Self.until(seconds: 6) { recorder.accepted.last == .waiting }
            let ended = (recorder.acceptedTimeline.last?.at ?? 0) - start
            print(String(format: "WORKING-TURN Esc: key at 0.5 s, the stand-in screen stops 1-2 s after Enter; the turn ended %.1f s after Enter, no Stop", ended / 1000))
            XCTAssertGreaterThanOrEqual(ended, 2_000)
        }
    }

    /// 3 Nov (#26, AI Connectors): Codex now has its PermissionRequest hook installed. A scripted Codex turn (a stand-in
    /// Codex screen through the real PTY and lifecycle, Codex's own hook payloads through the hosted feed) shows
    /// "Waiting for you" the moment the approval is asked; before, it stayed "Working" until the screen had been still 8 s.
    func testACodexApprovalSaysWaitingForYouAtOnce() async throws {
        XCTAssertEqual(Turn.status(provider: "codex", event: "PermissionRequest", sessionProvider: "codex"), .input)
        XCTAssertTrue(BackendSessionHookInstallation.events["codex"]?.contains("PermissionRequest") == true, "the hook Codex is given")
        // before: the same turn without the hook (what an install without it shows)
        var before: BackendSessionStatus?
        try await withLifecycle(provider: "codex", script: Self.codexScreen) { lifecycle, id, recorder in
            let feed = BackendSessionTurnFeed(lifecycle)
            feed.post(Self.codexHook("SessionStart", id))
            try await Task.sleep(for: .milliseconds(300))
            try await lifecycle.write(sessionID: id, data: "run\r")
            feed.post(Self.codexHook("UserPromptSubmit", id)); feed.post(Self.codexHook("PreToolUse", id))
            try await Self.until(seconds: 10) { (lifecycle.manager.screen(id) ?? "").contains("Would you like to run") }
            try await Task.sleep(for: .milliseconds(1_500))
            before = await lifecycle.status(sessionID: id)
            try await lifecycle.write(sessionID: id, data: "y")
        }
        XCTAssertEqual(before, .working, "without the hook the approval waits unseen (until the screen has been still 8 s)")
        // after: Codex calls PermissionRequest right before it asks
        try await withLifecycle(provider: "codex", script: Self.codexScreen) { lifecycle, id, recorder in
            let feed = BackendSessionTurnFeed(lifecycle)
            feed.post(Self.codexHook("SessionStart", id))
            try await Task.sleep(for: .milliseconds(300))
            try await lifecycle.write(sessionID: id, data: "run\r")
            feed.post(Self.codexHook("UserPromptSubmit", id)); feed.post(Self.codexHook("PreToolUse", id))
            try await Self.until(seconds: 10) { (lifecycle.manager.screen(id) ?? "").contains("Would you like to run") }
            let asked = Self.now()
            feed.post(Self.codexHook("PermissionRequest", id))
            try await Self.until(seconds: 1) { recorder.accepted.last == .input }
            let shown = (recorder.acceptedTimeline.last?.at ?? asked) - asked
            try await Task.sleep(for: .milliseconds(1_500))
            let held = await lifecycle.status(sessionID: id)
            XCTAssertEqual(held, .input, "the question stays until the person answers")
            try await lifecycle.write(sessionID: id, data: "y")                 // "1. Yes, proceed (y)"
            let answered = await lifecycle.status(sessionID: id)
            XCTAssertEqual(answered, .working, "an answer resumes the turn")
            feed.post(Self.codexHook("PostToolUse", id))
            try await Self.until(seconds: 10) { (lifecycle.manager.screen(id) ?? "").contains("Ran ls") }
            feed.post(Self.codexHook("Stop", id))
            try await Self.until(seconds: 2) { recorder.accepted.last == .completed }
            print(String(format: "CODEX-APPROVAL before: still %@ 1.5 s after the approval appeared; after: Waiting for you %.0f ms after the hook; statuses %@",
                         before?.rawValue ?? "-", shown, recorder.accepted.map(\.rawValue).joined(separator: " > ")))
            XCTAssertLessThan(shown, 500)
            XCTAssertEqual(recorder.accepted, [.waiting, .working, .input, .working, .completed])
        }
    }

    // MARK: The phone list

    func testThePhoneListShowsTheAcceptedStatusNotTheScreensReading() async throws {
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("WorkingTurnPhone-" + UUID().uuidString + ".noindex")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let trust = BackendRemoteTrustStore(directory: scratch.appendingPathComponent("remote"))
        try await trust.open()
        let manager = BackendPTYManager(inheritedEnvironment: [:], onEvent: { _ in })
        let meta = try manager.create(.init(cwd: "/tmp", provider: "claude"),
            spawn: .init(provider: "claude", command: "/bin/sh", args: ["-c", "stty -echo; cat >/dev/null"], path: "/usr/bin:/bin"))
        let host = BackendRemoteHost(trust: trust, manager: manager, state: NativeStateStore(), home: scratch.path,
                                     hostName: "Working Turn Mac", appVersion: "test", privateRoots: [scratch.path])
        await host.noteAcceptedStatus(meta.id, .working)
        await host.noteSessionEvent(.status(id: meta.id, status: .idle))      // the screen's reading
        var listed = await host.listedStatusForTesting(meta.id)
        XCTAssertEqual(listed, "working")
        await host.noteAcceptedStatus(meta.id, .completed)
        listed = await host.listedStatusForTesting(meta.id)
        XCTAssertEqual(listed, "completed")
        manager.killAll(); _ = await manager.drain()
        await trust.close()
    }

    // MARK: "What changed since your last message" (Memory)

    func testBoardChangesAreTheNewestOldestFirst() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("WorkingTurnBoard-" + UUID().uuidString + ".noindex")
        defer { try? FileManager.default.removeItem(at: base) }
        let store = try await DeckMemoryStore.open(root: base.appendingPathComponent("memory"), dataRoot: base.appendingPathComponent("data"),
                                                   embedder: nil, watch: false, now: { Date() })
        let stamp = DeckMemoryStamp(owner: .lead("imatch"), project: "imatch", session: "s1")
        for step in 0..<8 { _ = try await store.updateBoard(.init(id: "session:s1", kind: .session, stamp: stamp, doing: "step \(step)")) }
        let newest = try await store.boardChanges(since: .distantPast, owner: nil, limit: 3)
        XCTAssertEqual(newest.map(\.row.doing), ["step 5", "step 6", "step 7"], "the newest three, oldest first")
        let all = try await store.boardChanges(since: .distantPast, owner: nil)
        XCTAssertEqual(all.map(\.row.doing), (0..<8).map { "step \($0)" })
        XCTAssertEqual(DeckMemoryStore.boardChangesRead, 2_000)
        await store.close()
    }

    // MARK: Fixtures

    /// Claude Code 2.1 as its screen behaves (2 Nov, measured): a spinner line redrawn every 0.1 s while a turn runs,
    /// none of the signs the screen reader knows, the prompt above a footer; nothing at all once the turn ends.
    static let claudeScreen = #"""
    stty -echo
    draw() { printf '\033[H\033[2J%s\r\n\r\n  ❯ \r\n  ────\r\n  ⏵⏵ auto mode on (shift+tab to cycle)\r\n  Opus 5 · ctx 12 percent\r\n  ~/Deck Dev main\r\n  2 background tasks\r\n  Tip: /tui fullscreen\r\n' "$1"; }
    draw "Ready."
    while IFS= read -r line; do
      case "$line" in
        turn*) n=0; end=$(( $(date +%s) + 8 )); while [ "$(date +%s)" -lt "$end" ]; do draw "✻ Pondering… ($((n/10))s · ↓ $((n*7)) tokens)"; sleep 0.1; n=$((n+1)); done; draw "⏺ Done";;
        short*) n=0; end=$(( $(date +%s) + 2 )); while [ "$(date +%s)" -lt "$end" ]; do draw "✻ Working… ($((n/10))s)"; sleep 0.1; n=$((n+1)); done; draw "⎿ Interrupted · What should Claude do instead?";;
      esac
    done
    """#

    /// Codex 0.159.3's own hook input (its JSON schema names these fields), as its hooks.json command posts it.
    static func codexHook(_ event: String, _ id: String) -> BackendSessionHookEvent {
        var body: [String: Any] = ["hook_event_name": event, "session_id": "019a-codex-thread", "cwd": "/tmp", "model": "gpt-6.1-sol",
                                   "permission_mode": "default", "transcript_path": NSNull(), "turn_id": "turn-1"]
        if ["PreToolUse", "PermissionRequest", "PostToolUse"].contains(event) { body["tool_name"] = "Bash"; body["tool_input"] = ["command": "ls"] }
        return .parse(provider: "codex", event: event, sessionID: id, body: (try? JSONSerialization.data(withJSONObject: body)) ?? Data("{}".utf8),
                      environmentHeader: nil, peerPID: 0)
    }
    /// Codex's screen, enough of it: a working line every 0.1 s, then its approval question, which waits for a key.
    static let codexScreen = #"""
    stty -echo
    draw() { printf '\033[H\033[2J%b\r\n\r\n› \r\n  gpt-6.1-sol · ~/Deck Dev\r\n' "$1"; }
    draw "Ready."
    while IFS= read -r line; do
      case "$line" in
        run*) n=0; while [ $n -lt 6 ]; do draw "• Working ($((n/10))s • esc to interrupt)"; sleep 0.1; n=$((n+1)); done
              draw "Would you like to run the following command?\r\n  $ ls\r\n› 1. Yes, proceed (y)\r\n  2. No, and tell Codex what to do differently (esc)"
              stty -icanon min 1; dd bs=1 count=1 >/dev/null 2>&1; stty icanon
              n=0; while [ $n -lt 5 ]; do draw "• Running ls"; sleep 0.1; n=$((n+1)); done; draw "• Ran ls";;
      esac
    done
    """#

    static func hook(_ event: String, _ id: String) -> BackendSessionHookEvent {
        .parse(provider: "claude", event: event, sessionID: id, body: Data("{}".utf8), environmentHeader: nil, peerPID: 0)
    }
    static func now() -> Double { Date().timeIntervalSince1970 * 1000 }
    static func until(seconds: Double, _ check: @escaping @Sendable () -> Bool) async throws {
        let limit = ContinuousClock.now + .milliseconds(Int(seconds * 1000))
        while !check(), ContinuousClock.now < limit { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(check(), "the expected status did not come")
    }

    /// What the PTY said (raw) and what the lifecycle published (accepted), with times.
    final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var raw: [BackendSessionStatus] = []
        private var published: [(at: Double, status: BackendSessionStatus)] = []
        private var lifecycle: BackendSessionLifecycleCoordinator?
        private var engine: DeckMemoryFlowEngine?
        private let input: AsyncStream<BackendSessionEvent>.Continuation
        init() {
            let (events, input) = AsyncStream<BackendSessionEvent>.makeStream()
            self.input = input
            Task { [weak self] in for await event in events { await self?.current()?.noteSessionEvent(event) } }
        }
        func bind(_ lifecycle: BackendSessionLifecycleCoordinator, engine: DeckMemoryFlowEngine?) { lock.withLock { self.lifecycle = lifecycle; self.engine = engine } }
        private func current() -> BackendSessionLifecycleCoordinator? { lock.withLock { lifecycle } }
        func pty(_ event: BackendSessionEvent) {
            if case .status(_, let status) = event { lock.withLock { raw.append(status) } }
            input.yield(event)
        }
        func lifecycleEvent(_ event: BackendSessionLifecycleEvent) {
            guard case .status(let id, let status, _) = event else { return }
            let engine = lock.withLock { published.append((WorkingTurnTests.now(), status)); return self.engine }
            engine?.post(.sessionStatus(id: id, status: status.rawValue))
        }
        var accepted: [BackendSessionStatus] { lock.withLock { published.map { $0.status } } }
        var acceptedTimeline: [(at: Double, status: BackendSessionStatus)] { lock.withLock { published } }
        var rawFlips: [BackendSessionStatus] { lock.withLock { raw } }
        func finish() { input.finish() }
    }

    private func withLifecycle(provider: String, script: String, engine: DeckMemoryFlowEngine? = nil,
        _ body: (BackendSessionLifecycleCoordinator, String, Recorder) async throws -> Void) async throws {
        let runtime = try await BackendF4Runtime.wire()
        let recorder = Recorder()
        let manager = BackendPTYManager(inheritedEnvironment: [:]) { recorder.pty($0) }
        do {
            let ledger = try await BackendNativeLedger.activate(store: runtime.state)
            let launcher = BackendSessionLauncher(manager: manager, dependencies: try .init(providers: Providers(),
                accounts: runtime.adapter, confinement: Confinement(), instructions: Instructions(), ledger: ledger))
            let endpoint = BackendTestMCPEndpoint(readiness: .ready, description: { nil }, catalogue: { [] },
                register: { _, _ in throw BackendAccountFailure("No tools in this test") }, bind: { _, _, _ in }, revoke: { _ in })
            let launch = try BackendCoordinatedSessionLaunch(launcher: launcher, providers: Providers(),
                sessionTools: try .init(endpoint: endpoint, userData: runtime.configuration.dataDirectory),
                projectTools: try .init(source: ProjectTools(), userData: runtime.configuration.dataDirectory, inheritedEnvironment: [:]),
                reach: BackendBrowserToolReachAdapter(readiness: .ready, reachesDeviceWindows: { _ in false }, hostHoldsWindows: { false }))
            let lifecycle = try BackendSessionLifecycleCoordinator(manager: manager, launch: launch, accounts: runtime.adapter,
                attribution: BackendAccountAttribution(configuration: runtime.configuration, profiles: await runtime.profiles),
                ledger: ledger, store: runtime.state, cleanup: .init(readiness: .ready, release: { _ in }), emit: { recorder.lifecycleEvent($0) })
            recorder.bind(lifecycle, engine: engine)
            let meta = try manager.create(.init(cwd: runtime.root.path, cols: 100, rows: 30, provider: provider),
                spawn: .init(provider: provider, command: "/bin/sh", args: ["-c", script], path: "/usr/bin:/bin"))
            try await Task.sleep(for: .milliseconds(200))
            try await body(lifecycle, meta.id, recorder)
            recorder.finish(); manager.killAll(); _ = await manager.drain()
            await runtime.dispose(removeRoot: true)
        } catch {
            recorder.finish(); manager.killAll(); _ = await manager.drain()
            await runtime.dispose(removeRoot: true); throw error
        }
    }
    private struct Providers: BackendProviderLaunchResolver {
        let readiness: BackendLaunchReadiness = .ready
        func loginPath() async throws -> String { "/usr/bin:/bin" }
        func resolve(_ input: BackendCreateSessionInput, loginPath: String) async throws -> BackendProviderSpec {
            .init(id: "shell", command: "/bin/sh", args: ["-c", "cat >/dev/null"], resumeArgs: [])
        }
    }
    private struct Confinement: BackendConfinementLaunchResolver {
        let readiness: BackendLaunchReadiness = .ready
        func resolve(command: String, args: [String], input: BackendCreateSessionInput,
            account: BackendAccountLaunch, context: BackendLaunchContext) async throws -> BackendConfinedLaunch {
            .init(command: command, args: args)
        }
    }
    private struct Instructions: BackendInstructionLaunchResolver {
        let readiness: BackendLaunchReadiness = .ready
        func arguments(_ input: BackendCreateSessionInput, provider: BackendProviderSpec,
            context: BackendLaunchContext) async throws -> [String] { [] }
    }
    private struct ProjectTools: BackendProjectMCPSource {
        let readiness: BackendLaunchReadiness = .ready
        func resolve(cwd: String, provider: String, loginPath: String) async throws -> BackendProjectMCPDefinition? { nil }
    }
}
