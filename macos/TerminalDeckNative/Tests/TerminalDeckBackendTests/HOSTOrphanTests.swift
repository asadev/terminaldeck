import Foundation
import Darwin
import XCTest
@testable import TerminalDeckBackend

final class HOSTOrphanTests: XCTestCase, @unchecked Sendable {
    override func setUpWithError() throws {
    }

    private func fixture() throws -> (URL, BackendHOSTOrphanInventory, HOSTOrphanFakeKernel, String) {
        let directory = URL(fileURLWithPath: "/tmp", isDirectory: true).resolvingSymlinksInPath().appendingPathComponent("tdh-orphans-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let fake = HOSTOrphanFakeKernel()
        fake.put(fake.identity(9_000, parent: 1, group: 9_000, started: 100))
        fake.put(fake.identity(4_001, parent: 9_000, group: 4_001, started: 101))
        let inventory = try BackendHOSTOrphanInventory(directory: directory.appendingPathComponent("journal"), hostPID: 9_000, kernel: fake.kernel)
        let session = UUID().uuidString.lowercased()
        try inventory.record(sessionID: session, hostPID: 9_000, pid: 4_001)
        return (directory, inventory, fake, session)
    }
    func testJournalContainsOnlyOwnedIdentitiesAndIsPrivate() throws {
        let (directory, inventory, _, session) = try fixture()
        let file = directory.appendingPathComponent("journal/inventory.json")
        let data = try Data(contentsOf: file)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["version", "sessions"])
        let entries = try XCTUnwrap(object["sessions"] as? [[String: Any]])
        XCTAssertEqual(Set(try XCTUnwrap(entries.first).keys), ["sessionID", "owner", "rootPID", "processes"])
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("environment"))
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("secret"))
        var info = stat(); XCTAssertEqual(lstat(file.path, &info), 0); XCTAssertEqual(info.st_mode & 0o777, 0o600)
        XCTAssertEqual(try inventory.list().first?.record.sessionID, session)
    }
    func testLiveOriginalHostIsNeverStopped() async throws {
        let (_, inventory, fake, session) = try fixture()
        XCTAssertEqual(try inventory.list().first?.state, .liveOwner)
        do { _ = try await inventory.stop(sessionID: session); XCTFail("The live owner must be retained.") }
        catch BackendHOSTOrphanFailure.liveOwner {}
        XCTAssertTrue(fake.signals.isEmpty)
    }
    func testRecoveredPidReuseNeverReceivesASignal() async throws {
        let (_, inventory, fake, session) = try fixture()
        fake.remove(9_000)
        fake.put(fake.identity(4_001, parent: 1, group: 4_001, started: 200))
        let status = try XCTUnwrap(inventory.list().first)
        XCTAssertEqual(status.state, .identityChanged); XCTAssertEqual(status.replacedPIDs, [4_001])
        let proof = try await inventory.stop(sessionID: session)
        XCTAssertTrue(proof.clean); XCTAssertEqual(proof.replacedPIDs, [4_001]); XCTAssertTrue(fake.signals.isEmpty)
        XCTAssertNotNil(try fake.kernel.inspect(4_001))
    }
    func testPidReuseBetweenInspectionAndSignalIsRejectedByIdentityDelivery() async throws {
        let (_, inventory, fake, session) = try fixture()
        fake.remove(9_000)
        fake.replaceAtSignal = fake.identity(4_001, parent: 1, group: 4_001, started: 200)
        let proof = try await inventory.stop(sessionID: session)
        XCTAssertTrue(proof.clean); XCTAssertEqual(proof.replacedPIDs, [4_001]); XCTAssertTrue(fake.signals.isEmpty)
    }
    func testCapturedDescendantSurvivesSetsidAndIsRecoveredWithoutGroupSignals() async throws {
        let (_, inventory, fake, session) = try fixture()
        let child = fake.identity(4_002, parent: 4_001, group: 4_001, started: 102)
        fake.put(child); try inventory.observeDescendants(sessionID: session)
        var daemon = child; daemon.parentPID = 1; daemon.groupID = 4_002
        fake.put(daemon); fake.remove(9_000)
        let proof = try await inventory.stop(sessionID: session)
        XCTAssertTrue(proof.clean); XCTAssertEqual(Set(proof.signalledPIDs), [4_001, 4_002])
        XCTAssertTrue(fake.signals.allSatisfy { $0.pid > 1 })
        XCTAssertEqual(Set(fake.signals.filter { $0.signal == SIGKILL }.map(\.pid)), [4_001, 4_002])
    }
    func testUnobservedDaemonIsNeverGuessedFromAReusedParentOrGroup() async throws {
        let (_, inventory, fake, session) = try fixture()
        fake.put(fake.identity(4_099, parent: 1, group: 4_001, started: 102)); fake.remove(9_000)
        let proof = try await inventory.stop(sessionID: session)
        XCTAssertTrue(proof.clean); XCTAssertNotNil(try fake.kernel.inspect(4_099))
        XCTAssertFalse(fake.signals.contains { $0.pid == 4_099 })
        XCTAssertTrue(proof.coverage.contains("before observation"))
    }
    func testUnreadableKernelIdentityKeepsJournalAndSignalsNothing() async throws {
        let (directory, inventory, fake, session) = try fixture()
        fake.remove(9_000); fake.denied.insert(4_001)
        do { _ = try await inventory.stop(sessionID: session); XCTFail("Unreadable ownership must refuse recovery.") }
        catch {}
        XCTAssertTrue(fake.signals.isEmpty)
        XCTAssertFalse(try inventory.forgetProvenGone(sessionID: session).clean)
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("journal/inventory.json").path))
    }
    func testJournalReloadRetainsCapturedIdentityAcrossHostCrash() throws {
        let (directory, inventory, fake, session) = try fixture()
        fake.remove(9_000)
        let reloaded = try BackendHOSTOrphanInventory(directory: directory.appendingPathComponent("journal"), hostPID: 9_000, kernel: fake.kernel)
        XCTAssertEqual(try reloaded.list().first?.record, try inventory.list().first?.record)
        XCTAssertEqual(try reloaded.list().first?.state, .recoverable)
        XCTAssertEqual(try reloaded.list().first?.record.sessionID, session)
    }
    func testRecordRejectsForeignParentAndDifferentSessionIdentityBeforePersistence() throws {
        let (_, inventory, fake, session) = try fixture()
        fake.put(fake.identity(4_002, parent: 77, group: 4_002, started: 102))
        XCTAssertThrowsError(try inventory.record(sessionID: UUID().uuidString, hostPID: 9_000, pid: 4_002))
        fake.put(fake.identity(4_003, parent: 9_000, group: 4_003, started: 102))
        XCTAssertThrowsError(try inventory.record(sessionID: session, hostPID: 9_000, pid: 4_003))
        XCTAssertEqual(try inventory.list().count, 1)
    }
    /// HOSTLOST (9 Oct): a corrupt journal is kept (set aside, never deleted, nothing signalled) and
    /// no longer stops the host from starting — that left Asad unable to start Terminal Deck at all.
    func testCorruptJournalIsSetAsideWithoutDeletionAndTheHostStarts() throws {
        let (directory, _, fake, _) = try fixture()
        let journal = directory.appendingPathComponent("journal"), file = journal.appendingPathComponent("inventory.json")
        try BackendHOSTFiles.atomicWrite(Data("invalid".utf8), to: file)
        let inventory = try BackendHOSTOrphanInventory(directory: journal, hostPID: 9_000, kernel: fake.kernel)
        XCTAssertNotNil(inventory.loadNotice); XCTAssertTrue(try inventory.list().isEmpty); XCTAssertTrue(fake.signals.isEmpty)
        let aside = try XCTUnwrap(FileManager.default.contentsOfDirectory(atPath: journal.path).first { $0.hasPrefix("inventory.json.unreadable-") })
        XCTAssertEqual(try Data(contentsOf: journal.appendingPathComponent(aside)), Data("invalid".utf8))
    }
    func testMatchingZombieProvesOwnedRootGoneWithoutSignal() throws {
        let (_, inventory, fake, session) = try fixture()
        fake.remove(9_000)
        var zombie = try XCTUnwrap(fake.kernel.inspect(4_001)); zombie.zombie = true
        fake.put(zombie)
        XCTAssertTrue(try inventory.forgetProvenGone(sessionID: session).clean)
        XCTAssertTrue(fake.signals.isEmpty)
    }

    #if TD_HOST_PTY_GATE_INTEGRATED
    private func gateScratch() throws -> URL {
        let root = URL(fileURLWithPath: "/tmp", isDirectory: true).resolvingSymlinksInPath().appendingPathComponent("tdh-gate-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }
    func testPreExecCallbackPersistsInventoryBeforeAnyProgramSideEffect() async throws {
        let root = try gateScratch(), marker = root.appendingPathComponent("executed")
        let inventory = try BackendHOSTOrphanInventory(directory: root.appendingPathComponent("journal"))
        let session = UUID().uuidString.lowercased(), ownerPID = getpid(), finished = expectation(description: "inventoried child exits")
        let queue = DispatchQueue(label: "host.gate.success")
        let process = try BackendPTYProcess.spawn(command: "/bin/sh", args: ["-c", "printf released > \"$1\"", "host-gate", marker.path],
            environment: ["PATH": "/usr/bin:/bin"], cwd: root.path, cols: 80, rows: 24, queue: queue, beforeExec: { pid in
                XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
                try inventory.record(sessionID: session, hostPID: ownerPID, pid: pid)
                XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("journal/inventory.json").path))
                XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
            })
        queue.sync { process.onExit = { _ in finished.fulfill() }; process.start() }
        await fulfillment(of: [finished], timeout: 5)
        XCTAssertEqual(try String(contentsOf: marker, encoding: .utf8), "released")
        XCTAssertTrue(try inventory.forgetProvenGone(sessionID: session).clean)
    }
    func testThrowingPreExecCallbackReapsOnlyItsNewChildWithoutExecutingProgram() throws {
        let root = try gateScratch(), marker = root.appendingPathComponent("must-not-execute"), captured = HOSTGatePID()
        let sibling = Process(); sibling.executableURL = URL(fileURLWithPath: "/bin/sleep"); sibling.arguments = ["20"]
        try sibling.run()
        defer { if sibling.isRunning { sibling.terminate() }; sibling.waitUntilExit() }
        XCTAssertThrowsError(try BackendPTYProcess.spawn(command: "/bin/sh", args: ["-c", "printf wrong > \"$1\"", "host-gate", marker.path],
            environment: ["PATH": "/usr/bin:/bin"], cwd: root.path, cols: 80, rows: 24, queue: DispatchQueue(label: "host.gate.failure"), beforeExec: { pid in
                captured.set(pid)
                throw BackendHOSTOrphanFailure.invalid("Fixture inventory refuses release.")
            }))
        let pid = try XCTUnwrap(captured.value)
        var status: Int32 = 0
        XCTAssertEqual(waitpid(pid, &status, WNOHANG), -1); XCTAssertEqual(errno, ECHILD)
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path)); XCTAssertTrue(sibling.isRunning)
    }
    func testChildDeathDuringCallbackCannotSendSIGPIPEToHost() throws {
        let root = try gateScratch(), marker = root.appendingPathComponent("must-not-execute"), captured = HOSTGatePID()
        XCTAssertThrowsError(try BackendPTYProcess.spawn(command: "/bin/sh", args: ["-c", "printf wrong > \"$1\"", "host-gate", marker.path],
            environment: ["PATH": "/usr/bin:/bin"], cwd: root.path, cols: 80, rows: 24, queue: DispatchQueue(label: "host.gate.child-death"), beforeExec: { pid in
                captured.set(pid)
                guard Darwin.kill(pid, SIGKILL) == 0 else { throw BackendHOSTOrphanFailure.kernel("kill owned gate fixture", errno) }
                // Keep the zombie unreaped, so the spawn catch still owns its
                // reserved PID/group while the release writer returns EPIPE.
                var info = siginfo_t()
                guard waitid(P_PID, id_t(pid), &info, WEXITED | WNOWAIT) == 0 else { throw BackendHOSTOrphanFailure.kernel("await owned gate fixture", errno) }
            }))
        XCTAssertNotNil(captured.value); XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    }
    func testChildSetupFailureDoesNotCallInventoryCallback() throws {
        let root = try gateScratch(), captured = HOSTGatePID()
        XCTAssertThrowsError(try BackendPTYProcess.spawn(command: "/bin/sh", args: ["-c", "exit 0"], environment: [:],
            cwd: root.appendingPathComponent("missing").path, cols: 80, rows: 24, queue: DispatchQueue(label: "host.gate.cwd"), beforeExec: { captured.set($0) }))
        XCTAssertNil(captured.value)
    }
    #endif
}

private final class HOSTGatePID: @unchecked Sendable {
    private let lock = NSLock()
    private var pid: Int32?
    var value: Int32? { lock.withLock { pid } }
    func set(_ value: Int32) { lock.withLock { pid = value } }
}

// HOSTLOST (9 Oct 2026): Asad's dead agents host left a journal of ~2,000 descendant PIDs, many later
// reused by unrelated processes; the new host's recovery then refused configure forever.
extension HOSTOrphanTests {
    func testExitedDescendantsAreForgottenSoTheJournalStaysSmall() throws {
        let (directory, inventory, fake, session) = try fixture()
        for pid in Int32(5_000)..<5_200 { fake.put(fake.identity(pid, parent: 4_001, group: 4_001, started: 102)) }
        try inventory.observeDescendants(sessionID: session)
        XCTAssertEqual(try inventory.list().first?.record.processes.count, 201)
        for pid in Int32(5_000)..<5_150 { fake.remove(pid) }                                            // exited
        for pid in Int32(5_150)..<5_175 { fake.put(fake.identity(pid, parent: 1, group: pid, started: 999)) } // PID reused
        try inventory.observeDescendants(sessionID: session)
        let kept = try XCTUnwrap(inventory.list().first?.record.processes.map(\.pid)).sorted()
        XCTAssertEqual(kept, [4_001] + Array(Int32(5_175)..<5_200))
        let journal = try String(contentsOf: directory.appendingPathComponent("journal/inventory.json"), encoding: .utf8)
        XCTAssertFalse(journal.contains("5000")); XCTAssertFalse(journal.contains("5150"))
    }
    func testThousandsOfReusedPidsInADeadHostsJournalNeverBlockRecovery() async throws {
        let (_, inventory, fake, session) = try fixture()
        for pid in Int32(10_000)..<12_000 { fake.put(fake.identity(pid, parent: 4_001, group: 4_001, started: 102)) }
        try inventory.observeDescendants(sessionID: session)
        XCTAssertEqual(try inventory.list().first?.record.processes.count, 2_001)
        // The host dies; every recorded PID is later reused by someone else's process.
        fake.remove(9_000)
        for pid in Int32(10_000)..<12_000 { fake.put(fake.identity(pid, parent: 1, group: pid, started: 5_000)) }
        fake.put(fake.identity(4_001, parent: 1, group: 4_001, started: 5_000))
        let status = try XCTUnwrap(inventory.list().first)
        XCTAssertEqual(status.state, .identityChanged)
        let proof = try await inventory.stop(sessionID: session)
        XCTAssertTrue(proof.clean); XCTAssertTrue(fake.signals.isEmpty, "a reused PID is never signalled")
        XCTAssertTrue(try inventory.list().isEmpty)
    }
    func testAnUnverifiableOrphanIsAbandonedAsANoticeNeverAWall() async throws {
        let (_, inventory, fake, session) = try fixture()
        fake.remove(9_000); fake.denied = [4_001]
        do { _ = try await inventory.stop(sessionID: session); XCTFail("unverifiable identities are never signalled") } catch {}
        XCTAssertEqual(try inventory.abandon(sessionID: session), [4_001])
        XCTAssertTrue(try inventory.list().isEmpty); XCTAssertTrue(fake.signals.isEmpty)
    }
    /// 18 Oct (#180, #436): a forgotten descendant's watch goes with it, and a watch-driven capture is
    /// written a moment later in one write instead of at once.
    func testForgottenDescendantReleasesItsWatchAndWatchCapturesAreWrittenTogether() throws {
        let (directory, inventory, fake, session) = try fixture()
        let file = directory.appendingPathComponent("journal/inventory.json")
        fake.put(fake.identity(5_001, parent: 4_001, group: 4_001, started: 102))
        try inventory.observeDescendants(sessionID: session)
        XCTAssertTrue(try String(contentsOf: file, encoding: .utf8).contains("5001"), "Explicit observation still writes at once")
        XCTAssertTrue(fake.watching(5_001))
        fake.remove(5_001)                                                          // exited
        fake.put(fake.identity(5_002, parent: 4_001, group: 4_001, started: 103))   // a new short command
        fake.fire(4_001)
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline, fake.watching(5_001) { Thread.sleep(forTimeInterval: 0.01) }
        XCTAssertFalse(fake.watching(5_001), "The exited descendant's watch is cancelled")
        XCTAssertTrue(fake.watching(5_002))
        XCTAssertFalse(try String(contentsOf: file, encoding: .utf8).contains("5002"), "The capture's write waits for the coalescing moment")
        while Date() < deadline, !(try String(contentsOf: file, encoding: .utf8).contains("5002")) { Thread.sleep(forTimeInterval: 0.02) }
        let journal = try String(contentsOf: file, encoding: .utf8)
        XCTAssertTrue(journal.contains("5002")); XCTAssertFalse(journal.contains("5001"))
    }
    func testAnUnreadableJournalIsSetAsideAndTheHostStarts() throws {
        let directory = URL(fileURLWithPath: "/tmp", isDirectory: true).resolvingSymlinksInPath().appendingPathComponent("tdh-orphans-" + UUID().uuidString)
        let journal = directory.appendingPathComponent("journal")
        try FileManager.default.createDirectory(at: journal, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        chmod(journal.path, 0o700)
        let file = journal.appendingPathComponent("inventory.json")
        FileManager.default.createFile(atPath: file.path, contents: Data("{not json".utf8), attributes: [.posixPermissions: 0o600])
        let fake = HOSTOrphanFakeKernel(); fake.put(fake.identity(9_000, parent: 1, group: 9_000, started: 100))
        let inventory = try BackendHOSTOrphanInventory(directory: journal, hostPID: 9_000, kernel: fake.kernel)
        XCTAssertNotNil(inventory.loadNotice); XCTAssertTrue(try inventory.list().isEmpty)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: journal.path).contains { $0.hasPrefix("inventory.json.unreadable-") })
    }
}

private final class HOSTOrphanFakeKernel: @unchecked Sendable {
    struct Delivery: Sendable { var pid: Int32; var signal: Int32 }
    private let lock = NSLock()
    private var values: [Int32: BackendHOSTOrphanIdentity] = [:]
    private var deliveries: [Delivery] = []
    var denied: Set<Int32> = []
    var replaceAtSignal: BackendHOSTOrphanIdentity?
    var signals: [Delivery] { lock.withLock { deliveries } }
    private var watches: [Int32: @Sendable () -> Void] = [:]
    func watching(_ pid: Int32) -> Bool { lock.withLock { watches[pid] != nil } }
    func fire(_ pid: Int32) { lock.withLock { watches[pid] }?() }
    func identity(_ pid: Int32, parent: Int32, group: Int32, started: UInt64) -> BackendHOSTOrphanIdentity {
        var words = [UInt32](repeating: 0, count: 8); words[1] = geteuid(); words[5] = UInt32(pid); words[7] = UInt32(started)
        return .init(pid: pid, parentPID: parent, groupID: group, uid: geteuid(), startedSeconds: started, startedMicroseconds: 42, auditWords: words)
    }
    func put(_ identity: BackendHOSTOrphanIdentity) { lock.withLock { values[identity.pid] = identity } }
    func remove(_ pid: Int32) { lock.withLock { _ = values.removeValue(forKey: pid) } }
    var kernel: BackendHOSTOrphanKernel {
        .init(inspect: { [self] pid in
            try lock.withLock {
                if denied.contains(pid) { throw BackendHOSTOrphanFailure.kernel("inspect fixture", EPERM) }
                return values[pid]
            }
        }, children: { [self] parent in lock.withLock { values.values.filter { $0.parentPID == parent }.map(\.pid) } },
        signal: { [self] expected, signal in
            lock.withLock {
                if let replacement = replaceAtSignal { values[replacement.pid] = replacement; replaceAtSignal = nil }
                guard let actual = values[expected.pid], actual.sameProcess(as: expected), actual.auditWords == expected.auditWords else { return false }
                deliveries.append(.init(pid: actual.pid, signal: signal))
                if signal == SIGKILL { values[actual.pid] = nil }
                else if signal == SIGSTOP { var stopped = actual; stopped.stopped = true; values[actual.pid] = stopped }
                else if signal == SIGCONT { var resumed = actual; resumed.stopped = false; values[actual.pid] = resumed }
                return true
            }
        }, sleep: {}, watch: { [self] pid, changed in
            lock.withLock { watches[pid] = changed }
            return BackendHOSTOrphanWatch { [self] in lock.withLock { _ = watches.removeValue(forKey: pid) } }
        }, ownPID: 9_000)
    }
}

/// 22 Oct (Asad, "remove this 128 limit"): the process record has no session-count limit, and finished
/// sessions never fill its process bound.
extension HOSTOrphanTests {
    func testRecordsMoreSessionsThanTheOldLimitAndReloadsThemAll() throws {
        let (directory, inventory, fake, _) = try fixture()
        for index in 0..<140 {
            let pid = Int32(5_000 + index)
            fake.put(fake.identity(pid, parent: 9_000, group: pid, started: 101))
            try inventory.record(sessionID: UUID().uuidString.lowercased(), hostPID: 9_000, pid: pid)
        }
        XCTAssertEqual(try inventory.list().count, 141)
        let reloaded = try BackendHOSTOrphanInventory(directory: directory.appendingPathComponent("journal"), hostPID: 9_000, kernel: fake.kernel)
        XCTAssertNil(reloaded.loadNotice)
        XCTAssertEqual(try reloaded.list().count, 141)
    }
    func testProcessBoundForgetsEndedSessionsBeforeRefusing() throws {
        let directory = URL(fileURLWithPath: "/tmp", isDirectory: true).resolvingSymlinksInPath().appendingPathComponent("tdh-orphans-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let fake = HOSTOrphanFakeKernel()
        fake.put(fake.identity(9_000, parent: 1, group: 9_000, started: 100))
        let inventory = try BackendHOSTOrphanInventory(directory: directory.appendingPathComponent("journal"), hostPID: 9_000, kernel: fake.kernel, processBudget: 3)
        var sessions: [String] = []
        func start(_ pid: Int32) throws {
            fake.put(fake.identity(pid, parent: 9_000, group: pid, started: 101))
            let id = UUID().uuidString.lowercased(); try inventory.record(sessionID: id, hostPID: 9_000, pid: pid); sessions.append(id)
        }
        for pid: Int32 in [5_001, 5_002, 5_003] { try start(pid) }
        fake.remove(5_001); fake.remove(5_002)          // two sessions ended
        try start(5_004)                                 // the bound is reached: the ended ones are forgotten first
        XCTAssertEqual(Set(try inventory.list().map(\.record.sessionID)), [sessions[2], sessions[3]])
        try start(5_005)
        // Three processes really running: that is the only thing the bound still refuses.
        XCTAssertThrowsError(try start(5_006)) { error in
            guard case BackendHOSTOrphanFailure.budget = error else { return XCTFail("Expected the process bound, got \(error)") }
        }
        XCTAssertTrue(fake.signals.isEmpty)
    }
}
