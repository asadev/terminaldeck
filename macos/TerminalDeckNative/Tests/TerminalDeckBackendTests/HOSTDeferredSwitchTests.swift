import Foundation
import Darwin
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

final class HOSTDeferredSwitchTests: XCTestCase, @unchecked Sendable {
    override func setUpWithError() throws {
    }
    private func fixture(provider: String = "claude", reachable: Bool = true) throws -> (BackendHOSTDeferredSwitch, HOSTSwitchFixture, HOSTSwitchEvents) {
        let root = URL(fileURLWithPath: "/tmp", isDirectory: true).resolvingSymlinksInPath().appendingPathComponent("tdh-switch-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let state = try HOSTSwitchFixture(root: root, provider: provider, reachable: reachable), events = HOSTSwitchEvents()
        return (.init(operations: state.operations, changed: { events.append($0) }), state, events)
    }
    func testAPIAccountsCannotEnterTheSubscriptionBrokerSwitchEvenWithASeat() async throws {
        let api = "api-key-" + String(repeating: "a", count: 24)
        for sourceAPI in [false, true] {
            let (owner, state, events) = try fixture()
            if sourceAPI { state.setProfileID(api) }
            do {
                _ = try await owner.request(sessionID: state.id, targetID: sourceAPI ? "target" : api, status: .waiting, deferUntilIdle: false)
                XCTFail("API accounts need the existing replacement offer")
            } catch { XCTAssertTrue(BackendSessionSwitchNoSeat.recognizes(error)) }
            XCTAssertTrue(state.retargets.isEmpty); XCTAssertEqual(events.confirmedCount, 0)
            let pending = await owner.list(); XCTAssertTrue(pending.isEmpty)
            XCTAssertFalse(FileManager.default.fileExists(atPath: state.nudge.path))
            XCTAssertEqual(state.metadata.profileId, sourceAPI ? api : "previous")
        }
    }
    func testSamePidMetadataChangesOnlyAfterProvenTargetReread() async throws {
        let (owner, state, events) = try fixture()
        let row = try await owner.request(sessionID: state.id, targetID: "target", status: .waiting, deferUntilIdle: false)
        XCTAssertEqual(row.phase, .awaitingReread); XCTAssertEqual(state.metadata.profileId, "previous")
        XCTAssertEqual(state.metadata.agentSessionId, "same-conversation"); XCTAssertEqual(state.pid, 4_321)
        await owner.noteLookup(state.lookup())
        let remaining = await owner.list(); XCTAssertTrue(remaining.isEmpty)
        XCTAssertEqual(state.metadata.profileId, "target"); XCTAssertEqual(state.metadata.homeProfileId, "previous")
        XCTAssertEqual(state.metadata.agentSessionId, "same-conversation"); XCTAssertEqual(state.pid, 4_321)
        XCTAssertEqual(events.confirmedCount, 1)
        XCTAssertEqual(state.usedAccount, "target", "the keeper remembers the login for this project after it is actually used")
    }
    /// 13 Oct: a refused immediate switch used to come back as the row it started from, and the app said
    /// "Switched to …" before quietly going back. It now says why, and nothing is left pending.
    func testRefusedImmediateSwitchSaysWhyAndLeavesNothingPending() async throws {
        let (owner, state, _) = try fixture(reachable: false)
        do { _ = try await owner.request(sessionID: state.id, targetID: "target", status: .waiting, deferUntilIdle: false); XCTFail("A refused switch is not a switch.") }
        catch { XCTAssertEqual(error.localizedDescription, "Target’s login cannot be reached from here right now, so this session was left as it is.") }
        let rows = await owner.list(); XCTAssertTrue(rows.isEmpty); XCTAssertTrue(state.retargets.isEmpty)
        XCTAssertEqual(state.metadata.profileId, "previous")
    }
    func testStaleSequenceTimestampAndWrongPidCannotConfirm() async throws {
        let (owner, state, _) = try fixture()
        _ = try await owner.request(sessionID: state.id, targetID: "target", status: .waiting, deferUntilIdle: false)
        await owner.noteLookup(state.lookup(sequence: 10))
        await owner.noteLookup(state.lookup(at: .distantPast))
        await owner.noteLookup(state.lookup(pid: 4_322))
        await owner.noteLookup(state.lookup(account: "other"))
        let pending = await owner.list(); XCTAssertEqual(pending.count, 1); XCTAssertEqual(state.metadata.profileId, "previous")
        await owner.noteLookup(state.lookup())
        XCTAssertEqual(state.metadata.profileId, "target")
    }
    func testQueuedChangeSurvivesReadsAndStartsOnlyAtIdleBoundary() async throws {
        let (owner, state, _) = try fixture()
        let row = try await owner.request(sessionID: state.id, targetID: "target", status: .working, deferUntilIdle: true)
        XCTAssertEqual(row.phase, .queued); XCTAssertTrue(state.retargets.isEmpty)
        let snapshot = try JSONEncoder().encode(await owner.list())
        XCTAssertFalse(snapshot.isEmpty)
        await owner.noteStatus(sessionID: state.id, status: .input)
        let queued = await owner.list(); XCTAssertEqual(queued.first?.phase, .queued); XCTAssertTrue(state.retargets.isEmpty)
        await owner.noteStatus(sessionID: state.id, status: .completed)
        let applied = await owner.list(); XCTAssertEqual(applied.first?.phase, .awaitingReread)
        XCTAssertEqual(state.retargets, ["target"]); XCTAssertEqual(state.metadata.profileId, "previous")
    }
    func testCancelQueuedChangeDoesNotRetargetOrNudge() async throws {
        let (owner, state, _) = try fixture()
        _ = try await owner.request(sessionID: state.id, targetID: "target", status: .working, deferUntilIdle: true)
        try await owner.cancel(sessionID: state.id)
        let rows = await owner.list(); XCTAssertTrue(rows.isEmpty); XCTAssertTrue(state.retargets.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: state.nudge.path))
    }
    func testCancelAwaitingRereadRestoresPreviousSeatAndClearsOnlyCreatedNudge() async throws {
        let (owner, state, _) = try fixture()
        _ = try await owner.request(sessionID: state.id, targetID: "target", status: .waiting, deferUntilIdle: false)
        XCTAssertTrue(FileManager.default.fileExists(atPath: state.nudge.path))
        try await owner.cancel(sessionID: state.id)
        XCTAssertEqual(state.retargets, ["target", "previous"]); XCTAssertEqual(state.metadata.profileId, "previous")
        XCTAssertFalse(FileManager.default.fileExists(atPath: state.nudge.path))
        await owner.noteLookup(state.lookup()); XCTAssertEqual(state.metadata.profileId, "previous")
    }
    func testCallerChangedNudgeContentIsPreservedOnCancel() async throws {
        let (owner, state, _) = try fixture()
        _ = try await owner.request(sessionID: state.id, targetID: "target", status: .waiting, deferUntilIdle: false)
        let replacement = Data("fixture-updated-value\n".utf8)
        try replacement.write(to: state.nudge)
        try await owner.cancel(sessionID: state.id)
        XCTAssertEqual(try Data(contentsOf: state.nudge), replacement)
    }
    func testExistingNudgeFileIsNeverDeletedBySwitch() async throws {
        let (owner, state, _) = try fixture()
        let original = Data("fixture-existing-value\n".utf8); try original.write(to: state.nudge)
        _ = try await owner.request(sessionID: state.id, targetID: "target", status: .waiting, deferUntilIdle: false)
        await owner.noteLookup(state.lookup())
        XCTAssertEqual(try Data(contentsOf: state.nudge), original)
    }
    func testSymlinkCredentialTriggerRefusedBeforeRetarget() async throws {
        let (owner, state, _) = try fixture()
        let outside = state.root.appendingPathComponent("outside"); try Data("untouched".utf8).write(to: outside)
        XCTAssertEqual(symlink(outside.path, state.nudge.path), 0)
        do { _ = try await owner.request(sessionID: state.id, targetID: "target", status: .waiting, deferUntilIdle: false); XCTFail("Unsafe nudge must refuse before retarget.") }
        catch {}
        XCTAssertTrue(state.retargets.isEmpty); XCTAssertEqual(try Data(contentsOf: outside), Data("untouched".utf8))
    }
    func testUnsupportedProviderHasNoReplacementOrInPlaceMutation() async throws {
        let (owner, state, _) = try fixture(provider: "codex")
        do { _ = try await owner.request(sessionID: state.id, targetID: "target", status: .waiting, deferUntilIdle: false); XCTFail("Unsupported replacement needs the existing app launch plan.") }
        catch BackendSessionFailure.unsupported {}
        XCTAssertTrue(state.retargets.isEmpty)
    }
    func testProcessExitAndExplicitStopClearPendingChoices() async throws {
        let (owner, state, _) = try fixture()
        _ = try await owner.request(sessionID: state.id, targetID: "target", status: .working, deferUntilIdle: true)
        await owner.processExited(sessionID: state.id)
        let exited = await owner.list(); XCTAssertTrue(exited.isEmpty)
        _ = try await owner.request(sessionID: state.id, targetID: "target", status: .working, deferUntilIdle: true)
        try await owner.stop()
        let stopped = await owner.list(); XCTAssertTrue(stopped.isEmpty)
    }
    /// 18 Oct (#415): one switch whose old login cannot be put back never stops the others being cancelled, and the
    /// listeners always go; the refusal is still answered.
    func testStopCancelsEverySwitchEvenWhenOneCannotBePutBack() async throws {
        let root = URL(fileURLWithPath: "/tmp", isDirectory: true).resolvingSymlinksInPath().appendingPathComponent("tdh-switch-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        for name in ["a", "b"] { try FileManager.default.createDirectory(at: root.appendingPathComponent(name), withIntermediateDirectories: false) }
        let a = try HOSTSwitchFixture(root: root.appendingPathComponent("a"), provider: "claude")
        let b = try HOSTSwitchFixture(root: root.appendingPathComponent("b"), provider: "claude")
        let byID = [a.id: a, b.id: b], removed = HOSTSwitchCount(), stuck = a.id
        var operations = a.operations
        operations.dataRoot = root
        operations.sessions = { [a.metadata, b.metadata] }
        operations.pid = { byID[$0]?.pid }
        operations.seat = { id in await byID[id]?.operations.seat(id) }
        operations.setAccount = { id, account, home in byID[id]?.operations.setAccount(id, account, home) }
        // Putting the old login back fails for one session only.
        operations.retarget = { id, account in
            guard let fixture = byID[id], account != "previous" || id != stuck else { return false }
            return try await fixture.operations.retarget(id, account)
        }
        operations.observeLookup = { _ in UUID() }
        operations.removeLookup = { _ in removed.add() }
        let owner = BackendHOSTDeferredSwitch(operations: operations, changed: { _ in })
        for fixture in [a, b] { _ = try await owner.request(sessionID: fixture.id, targetID: "target", status: .waiting, deferUntilIdle: false) }
        do { try await owner.stop(); XCTFail("The refused put-back is answered.") } catch {}
        let left = await owner.list()
        XCTAssertEqual(left.map(\.sessionID), [a.id], "only the session that could not be put back is still pending")
        XCTAssertEqual(b.retargets.last, "previous")
        XCTAssertEqual(removed.value, 1, "the listener is removed even though stop failed")
    }
}

private final class HOSTSwitchCount: @unchecked Sendable {
    private let lock = NSLock(); private var count = 0
    func add() { lock.withLock { count += 1 } }
    var value: Int { lock.withLock { count } }
}

private final class HOSTSwitchFixture: @unchecked Sendable {
    let root: URL
    let directory: URL
    let id = UUID().uuidString
    let pid: Int32 = 4_321
    private let lock = NSLock()
    private var meta: BackendSessionMeta
    private var serving = "previous"
    private var changes: [String] = []
    var metadata: BackendSessionMeta { lock.withLock { meta } }
    func setProfileID(_ id: String) { lock.withLock { meta.profileId = id } }
    private var used: [String: String] = [:]
    var usedAccount: String? { lock.withLock { used[meta.cwd] } }
    var retargets: [String] { lock.withLock { changes } }
    var nudge: URL { directory.appendingPathComponent(BackendAccountSwitchInPlace.nudgeFile) }
    let reachable: Bool
    init(root: URL, provider: String, reachable: Bool = true) throws {
        self.root = root; self.reachable = reachable; directory = root.appendingPathComponent("owned-store")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let input = BackendCreateSessionInput(cwd: root.path, provider: provider)
        let spawn = BackendSpawnSpec(provider: provider, command: "/bin/false", args: [], path: "/usr/bin:/bin",
            profile: .init(id: "previous", name: "Previous"), agentSessionId: "same-conversation")
        meta = .init(id: id, input: input, spawn: spawn)
    }
    func lookup(sequence: UInt64 = 11, at: Date = Date(), pid: Int32 = 4_321, account: String = "target") -> BackendAccountCredentialLookup {
        .init(sessionID: id, accountID: account, slot: BackendAccountSwitchInPlace.loginSlot, processPID: pid, sequence: sequence, deliveredAt: at)
    }
    private func retarget(_ account: String) -> Bool { lock.withLock { serving = account; changes.append(account); return true } }
    private var seat: BackendAccountSeatSnapshot {
        lock.withLock { .init(sessionID: id, launchAccountID: "previous", servingAccountID: serving, storeDirectory: directory.path, processPID: pid) }
    }
    var operations: BackendHOSTDeferredSwitch.Operations {
        .init(dataRoot: root, sessions: { [self] in [metadata] }, pid: { [self] session in session == id ? pid : nil },
            profile: { [self] account in .init(id: account, name: account == "target" ? "Target" : "Previous", provider: "claude", configDir: directory.path,
                system: false, color: "", createdAt: 0, lastUsedAt: nil) },
            seat: { [self] session in session == id ? seat : nil }, sequence: { 10 },
            dependencies: { [self] in
                .init(seat: { [self] _ in .init(launchAccountID: "previous", launchDirectory: directory.path, storeDirectory: directory.path) },
                    source: { [reachable] _ in reachable ? .vault : nil }, adopting: { _, _ in false }, held: { _ in true }, keep: { _, _, _ in true }, keychain: nil,
                    user: "scratch", retarget: { [self] _, account in retarget(account) }, launchDir: { $0.storeDirectory })
            }, retarget: { [self] _, account in retarget(account) },
            setAccount: { [self] _, account, home in lock.withLock { meta.profileId = account.id; meta.profileName = account.name; meta.homeProfileId = home == account.id ? nil : home; return meta } },
            markUsed: { [self] account, project in lock.withLock { used[project] = account } }, observeLookup: { _ in nil }, removeLookup: { _ in }, observeProcess: { _ in nil })
    }
}
private final class HOSTSwitchEvents: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [BackendHOSTDeferredSwitch.Event] = []
    func append(_ event: BackendHOSTDeferredSwitch.Event) { lock.withLock { events.append(event) } }
    var confirmedCount: Int { lock.withLock { events.filter { if case .confirmed = $0 { return true }; return false }.count } }
}
