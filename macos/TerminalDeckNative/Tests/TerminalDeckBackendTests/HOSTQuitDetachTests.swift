// QUIT (9 Oct 2026): every app close except the explicit "Quit and Stop Everything" leaves
// the session host's processes running. Incident: a SIGTERM quit of 0.20.2-local ran the
// full stop and ended a kept zsh. Real processes, real host server/client, owned /tmp scratch.
#if TD_HOST_INTEGRATED
import Foundation
import Darwin
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

final class HOSTQuitDetachTests: XCTestCase, @unchecked Sendable {
    // MARK: The close rule (NativeSVResident.intercept asks it)

    func testOnlyExplicitStopEverythingEndsKeptSessions() {
        XCTAssertEqual(NativeSVQuitRule.close(explicitStop: true, decided: true, updating: false, inAppSessions: 0), .stopEverything)
        XCTAssertEqual(NativeSVQuitRule.close(explicitStop: true, decided: false, updating: true, inAppSessions: 2), .stopEverything)
        // Cmd+Q / window close / Dock Quit with only kept sessions: immediate, no question.
        XCTAssertEqual(NativeSVQuitRule.close(explicitStop: false, decided: false, updating: false, inAppSessions: 0), .detach)
        // Signal, logout, scripted quit, the question already answered: never a (second) question.
        XCTAssertEqual(NativeSVQuitRule.close(explicitStop: false, decided: true, updating: false, inAppSessions: 3), .detach)
        // "Keep and update": an update quit is never talked out of.
        XCTAssertEqual(NativeSVQuitRule.close(explicitStop: false, decided: false, updating: true, inAppSessions: 3), .detach)
        // In-app sessions and nobody decided yet: today's question, about those only.
        XCTAssertEqual(NativeSVQuitRule.close(explicitStop: false, decided: false, updating: false, inAppSessions: 2), .decideInApp)
    }

    func testScriptedQuitIsPromptFreeButTheDockQuitIsThePersons() {
        XCTAssertTrue(NativeSVQuitRule.scriptedQuit(senderBundleID: nil, senderIsSelf: false)) // osascript
        XCTAssertTrue(NativeSVQuitRule.scriptedQuit(senderBundleID: "com.apple.shortcuts", senderIsSelf: false))
        XCTAssertFalse(NativeSVQuitRule.scriptedQuit(senderBundleID: "com.apple.dock", senderIsSelf: false))
        XCTAssertFalse(NativeSVQuitRule.scriptedQuit(senderBundleID: nil, senderIsSelf: true))
    }

    func testQuestionCountsAndStopsOnlyInAppSessions() {
        let question = NativeSVQuitRule.question(liveSessions: 1, keptByHost: 3)
        XCTAssertEqual(question.message, "One session is still running.")
        XCTAssertTrue(question.detail.contains("3 other sessions are kept by Terminal Deck's background session host"))
        XCTAssertTrue(question.detail.contains("Quit and Stop Everything"))
        XCTAssertEqual(NativeSVQuitRule.buttons(keptByHost: 3), ["Keep Them Running", "Stop Them", "Cancel"])
        // No kept sessions: the question and buttons are exactly today's.
        XCTAssertEqual(NativeSVQuitRule.buttons(keptByHost: 0), NativeSVQuitRule.buttons)
        XCTAssertEqual(NativeSVQuitRule.question(liveSessions: 2, keptByHost: 0).detail, NativeSVQuitRule.question(liveSessions: 2).detail)
        // Answer indices are unchanged (0 keep, 1 stop, 2 cancel).
        XCTAssertEqual(NativeSVQuitRule.answer(buttonIndex: 1), .stop)
    }

    // MARK: The shutdown mechanism (BackendCompositionSessions.shutdown runs exactly this order)

    func testOrdinaryShutdownDetachesKeptSessionAndStopsOnlyInAppSession() async throws {
        let fixture = try await Fixture.make(self)
        defer { fixture.close() }
        // App quit: detach first, then the ordinary stop of everything the app still owns.
        XCTAssertTrue(fixture.app.prepareShutdown(stopHosted: false))
        fixture.app.beginShutdown()
        let drained = await fixture.app.drain(); XCTAssertTrue(drained)
        XCTAssertNil(fixture.app.pidOf(fixture.local.id))
        XCTAssertEqual(Darwin.kill(fixture.localPID, 0), -1); XCTAssertEqual(errno, ESRCH)
        // The kept process never noticed: same PID, still running in its host.
        XCTAssertEqual(Darwin.kill(fixture.keptPID, 0), 0)
        XCTAssertEqual(fixture.helper.pidOf(fixture.kept.id), fixture.keptPID)
        // The next app launch reattaches the same PID, replays its output and keeps talking to it.
        let next = try BackendHOSTClient(paths: fixture.paths); defer { next.detach() }
        XCTAssertEqual(try next.snapshot(fixture.kept.id)?.pid, fixture.keptPID)
        try next.write(fixture.kept.id, bytes: Data("after-quit\n".utf8))
        let resumed = expectation(description: "replay and new output from the same kept PID")
        let seen = HOSTQuitOutput(expected: ["kept-before", "after-quit"], ready: resumed)
        try next.attach(onSnapshot: { seen.receive($0.replay) }, onEvent: { seen.receive($0.text ?? "") }, onReady: {}, onDisconnect: {})
        await fulfillment(of: [resumed], timeout: 8)
        try next.stopAll()
        let helperDrained = await fixture.helper.drain(); XCTAssertTrue(helperDrained)
    }

    func testExplicitStopEverythingStopsKeptSession() async throws {
        let fixture = try await Fixture.make(self)
        defer { fixture.close() }
        XCTAssertFalse(fixture.app.prepareShutdown(stopHosted: true))
        fixture.app.beginShutdown()
        let drained = await fixture.app.drain(); XCTAssertTrue(drained)
        let helperDrained = await fixture.helper.drain(timeoutMilliseconds: 5_000); XCTAssertTrue(helperDrained)
        XCTAssertNil(fixture.helper.pidOf(fixture.kept.id)); XCTAssertNil(fixture.app.pidOf(fixture.local.id))
        XCTAssertEqual(Darwin.kill(fixture.keptPID, 0), -1); XCTAssertEqual(errno, ESRCH)
    }

    private struct Fixture {
        let root: URL, paths: BackendHOSTPaths, helper: BackendPTYManager, server: BackendHOSTServer
        let client: BackendHOSTClient, app: BackendPTYManager
        let kept: BackendSessionMeta, keptPID: Int32, local: BackendSessionMeta, localPID: Int32
        func close() { client.detach(); server.stopListening(); helper.beginShutdown(); app.beginShutdown() }

        static func make(_ test: XCTestCase) async throws -> Fixture {
            let root = URL(fileURLWithPath: "/tmp", isDirectory: true).resolvingSymlinksInPath().appendingPathComponent("tdh-live-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
            test.addTeardownBlock { try? FileManager.default.removeItem(at: root) }
            let paths = try BackendHOSTPaths(dataDirectory: root); _ = try paths.secret(create: true)
            // The session host side (the launchd helper's manager in the product).
            let helper = BackendPTYManager(inheritedEnvironment: [:], onEvent: { _ in })
            let server = try BackendHOSTServer(paths: paths, hostVersion: "quit-fixture-v1", manager: helper,
                launch: { try helper.hostCreate($0) }, snapshot: { helper.hostSnapshot($0) }, onIdle: {})
            // The app side: its own manager with the host attached, exactly as NativeCompositionINT2HOSTCore does.
            let client = try BackendHOSTClient(paths: paths)
            let app = BackendPTYManager(inheritedEnvironment: ["HOME": root.path, "LANG": "en_US.UTF-8"], onEvent: { _ in })
            let bridge = BackendHOSTManagerBridge(client: client,
                write: { try client.write($0, bytes: $1, expectedCreatedAt: $2) },
                drain: { try await client.drain(timeoutMilliseconds: $0) },
                setWatched: { try client.setWatched($0) }, stampIndependent: { $0.ownerIndependent = true })
            let ready = XCTestExpectation(description: "app attached to the host")
            try app.installHOSTFrontend(bridge, ready: { ready.fulfill() }, disconnected: {})
            await test.fulfillment(of: [ready], timeout: 5)
            let echo = "while IFS= read -r line; do printf '%s\\n' \"$line\"; done"
            let kept = try app.createHOST(BackendCreateSessionInput(cwd: root.path, provider: "shell"),
                spawn: BackendSpawnSpec(provider: "shell", command: "/bin/sh", args: ["-c", "printf 'kept-before\\n'; " + echo], path: "/usr/bin:/bin", env: [:]),
                context: BackendLaunchContext(), machineID: "", independent: true)
            let local = try app.create(BackendCreateSessionInput(cwd: root.path, provider: "shell"),
                spawn: BackendSpawnSpec(provider: "shell", command: "/bin/sh", args: ["-c", "printf 'in-app\\n'; " + echo], path: "/usr/bin:/bin", env: [:]))
            let keptPID = try XCTUnwrap(helper.pidOf(kept.id)), localPID = try XCTUnwrap(app.pidOf(local.id))
            XCTAssertTrue(app.isHostedSession(kept.id)); XCTAssertFalse(app.isHostedSession(local.id))
            XCTAssertEqual(app.localSessionCount(), 1)
            return .init(root: root, paths: paths, helper: helper, server: server, client: client, app: app,
                         kept: kept, keptPID: keptPID, local: local, localPID: localPID)
        }
    }

    // MARK: L8 (11 Oct): a held Hoot lease must not fail the hand-over

    /// Asad's real app: Hoot, started at launch, held an account lease in the session host; every close of
    /// the app got "not safe to detach". The app now ends that holder first and asks again for a moment.
    func testAHeldHootLeaseIsEndedBeforeTheHostIsAskedAndTheHandOverSucceeds() async throws {
        final class Host: @unchecked Sendable {
            let lock = NSLock(); var hootAlive = true, asked = 0, goneAfter = 2
            func endHoot() { lock.withLock { hootAlive = false } }
            // The host sees an ended process as gone a moment later (here: on the third question).
            func readiness() -> BackendHOSTKeepDetachReadiness.Answer {
                lock.withLock { asked += 1; return .init(safeToDetach: !hootAlive && asked > goneAfter, claimsAdopted: true) }
            }
        }
        let host = Host()
        BackendHOSTKeepDetachPreparation.register("hoot") { host.endHoot() }
        defer { BackendHOSTKeepDetachPreparation.register("hoot", nil) }
        await BackendHOSTKeepDetachPreparation.run()
        XCTAssertFalse(host.hootAlive)
        try await BackendHOSTKeepDetachReadiness.wait(read: { host.readiness() }, pause: { _ in })
        XCTAssertEqual(host.asked, 3)
    }

    func testAHolderThatNeverGoesIsRefusedWithItsReasonAfterABoundedWait() async {
        var asked = 0
        do {
            try await BackendHOSTKeepDetachReadiness.wait(tries: 5, read: { asked += 1; return .init(safeToDetach: false, claimsAdopted: true) }, pause: { _ in })
            XCTFail("a host that never says safe must refuse the hand-over")
        } catch { XCTAssertTrue(error.localizedDescription.contains("app-owned process"), error.localizedDescription) }
        XCTAssertEqual(asked, 5)
    }

    func testUnadoptedClaimsAreRefusedAtOnceWithTheirOwnReason() async {
        var asked = 0
        do {
            try await BackendHOSTKeepDetachReadiness.wait(read: { asked += 1; return .init(safeToDetach: false, claimsAdopted: false) }, pause: { _ in })
            XCTFail("unadopted claims must refuse")
        } catch { XCTAssertTrue(error.localizedDescription.contains("claims"), error.localizedDescription) }
        XCTAssertEqual(asked, 1)
    }
}

private final class HOSTQuitOutput: @unchecked Sendable {
    private let lock = NSLock(); private var text = "", complete = false
    private let expected: [String], ready: XCTestExpectation
    init(expected: [String], ready: XCTestExpectation) { self.expected = expected; self.ready = ready }
    func receive(_ part: String) {
        let done = lock.withLock { () -> Bool in
            guard !complete else { return false }; text += part
            if expected.allSatisfy({ text.contains($0) }) { complete = true; return true }; return false
        }
        if done { ready.fulfill() }
    }
}
#endif
