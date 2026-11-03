import Foundation
import TerminalDeckNativeCore
import Darwin

/// One private journal and one writer. record() must finish before releasing
/// the PTY child's pre-exec gate. No process is signalled by initialization/list.
public final class BackendHOSTOrphanInventory: @unchecked Sendable {
    private struct Journal: Codable { var version: Int; var sessions: [BackendHOSTOrphanRecord] }
    private let queue = DispatchQueue(label: "dev.terminaldeck.host.orphan-inventory")
    private let key = DispatchSpecificKey<UInt8>()
    private let kernel: BackendHOSTOrphanKernel
    private let ownerPID: Int32
    private let file: URL
    private var records: [String: BackendHOSTOrphanRecord] = [:]
    private var watches: [String: [Int32: BackendHOSTOrphanWatch]] = [:]
    private var problems: [String: String] = [:]
    private var stopping: Set<String> = []
    /// 18 Oct (#436): watch-driven captures share one write a moment later; record() and explicit
    /// observation still write at once (the pre-exec record must be durable before exec).
    private var pendingPersist: DispatchWorkItem?
    private var unsaved: Set<String> = []
    static let coalesceDelay: DispatchTimeInterval = .milliseconds(500)
    /// Set when a previous journal had to be set aside at start (HOSTLOST).
    public private(set) var loadNotice: String?
    /// Processes still running under this host's sessions (a safety bound, not a session count). 22 Oct: records of
    /// sessions whose processes are all proven gone are forgotten first, so finished sessions never fill it.
    private let maximumProcesses: Int
    static let defaultProcessBudget = 4_096

    public convenience init(directory: URL, hostPID: Int32 = getpid(), kernel: BackendHOSTOrphanKernel = .live) throws {
        try self.init(directory: directory, hostPID: hostPID, kernel: kernel, processBudget: Self.defaultProcessBudget)
    }
    init(directory: URL, hostPID: Int32, kernel: BackendHOSTOrphanKernel, processBudget: Int) throws {
        guard directory.isFileURL, directory.path.hasPrefix("/"), !directory.path.contains("\0"),
              hostPID > 1, hostPID == kernel.ownPID else { throw BackendHOSTOrphanFailure.invalid("Invalid owned recovery directory or host identity.") }
        self.kernel = kernel; ownerPID = hostPID; file = directory.appendingPathComponent("inventory.json"); maximumProcesses = processBudget
        queue.setSpecific(key: key, value: 1)
        try BackendHOSTFiles.privateDirectory(directory)
        var info = stat()
        if lstat(file.path, &info) == 0 {
            do {
                let bytes = try BackendHOSTFiles.readPrivate(file, maximum: 8 * 1024 * 1024)
                let journal = try JSONDecoder().decode(Journal.self, from: bytes)
                // 22 Oct (Asad): no session-count limit; the journal's own size bound (8 MB above) still applies.
                guard journal.version == 1 else {
                    throw BackendHOSTOrphanFailure.invalid("The owned recovery journal has an unsupported version or size.")
                }
                for record in journal.sessions {
                    try Self.validate(record)
                    guard records[record.sessionID] == nil else { throw BackendHOSTOrphanFailure.invalid("The recovery journal contains duplicate sessions.") }
                    records[record.sessionID] = record
                }
                guard records.values.reduce(0, { $0 + $1.processes.count }) <= maximumProcesses else { throw BackendHOSTOrphanFailure.budget }
            } catch {
                // HOSTLOST: an unreadable or oversized journal must never stop the host from starting.
                // It is set aside (nothing is signalled), and the host starts with an empty record.
                records = [:]
                let aside = directory.appendingPathComponent("inventory.json.unreadable-" + String(Int(Date().timeIntervalSince1970)))
                _ = rename(file.path, aside.path)
                loadNotice = "The previous host's process record could not be read and was set aside (" + aside.lastPathComponent + "). No process was stopped."
            }
        } else if errno != ENOENT { throw BackendHOSTOrphanFailure.kernel("read the private recovery journal", errno) }
    }

    /// Host's parent-after-fork callback: root must still be blocked before exec.
    public func record(sessionID: String, hostPID: Int32, pid: Int32, renewalFolder: String? = nil) throws {
        try serialized {
            guard UUID(uuidString: sessionID) != nil, hostPID == ownerPID, pid != ownerPID,
                  let owner = try kernel.inspect(ownerPID), owner.valid, !owner.zombie,
                  let root = try kernel.inspect(pid), root.valid, !root.zombie,
                  root.parentPID == ownerPID, root.groupID == pid,
                  let ownerAfter = try kernel.inspect(ownerPID), ownerAfter.sameProcess(as: owner) else {
                throw BackendHOSTOrphanFailure.invalid("The child could not be proven to belong to this host's original PTY group.")
            }
            if let existing = records[sessionID] {
                guard existing.owner.sameProcess(as: owner), existing.rootPID == pid,
                      existing.processes.first(where: { $0.pid == pid })?.sameProcess(as: root) == true else {
                    throw BackendHOSTOrphanFailure.invalid("An owned session id cannot be reused for another process.")
                }
                return
            }
            // 22 Oct (Asad): no session-count limit. At the process bound, records whose processes are all
            // proven gone are forgotten first; only processes still running can refuse a launch.
            if processCount >= maximumProcesses { forgetEnded(keeping: sessionID) }
            guard processCount < maximumProcesses else { throw BackendHOSTOrphanFailure.budget }
            let value = BackendHOSTOrphanRecord(sessionID: sessionID, owner: owner, rootPID: pid, processes: [root], renewalFolder: renewalFolder)
            records[sessionID] = value
            do { try persist() }
            catch { records[sessionID] = nil; throw error }
            installWatches(sessionID)
        }
    }

    /// Event-driven fork/exec capture; also called immediately before root stop.
    public func observeDescendants(sessionID: String) throws {
        try serialized {
            try captureDescendants(sessionID, durable: true)
            installWatches(sessionID)
        }
    }
    public func observationProblem(sessionID: String) -> String? { serialized { problems[sessionID] } }

    public func list() throws -> [BackendHOSTOrphanRecovery] {
        serialized { records.values.sorted { $0.sessionID < $1.sessionID }.map(recovery) }
    }

    /// Recovery is for a dead/replaced host only. Freeze exact identities,
    /// discover still-provable children, then kill each identity individually.
    /// No negative process-group signal or bare-PID kill is ever used.
    public func stop(sessionID: String) async throws -> BackendHOSTOrphanProof {
        try await stop(sessionID: sessionID, currentOwner: false)
    }

    /// The actual current helper may stop descendants of its own roots before
    /// exiting. This does not authorize a replacement host to stop a live owner.
    public func stopOwned(sessionID: String) async throws -> BackendHOSTOrphanProof {
        try await stop(sessionID: sessionID, currentOwner: true)
    }

    private func stop(sessionID: String, currentOwner: Bool) async throws -> BackendHOSTOrphanProof {
        try serialized {
            guard let record = records[sessionID] else { throw BackendHOSTOrphanFailure.missingSession }
            let current = recovery(record)
            if currentOwner {
                guard record.owner.pid == ownerPID, let owner = try kernel.inspect(ownerPID),
                      owner.sameProcess(as: record.owner), !owner.zombie else {
                    throw BackendHOSTOrphanFailure.invalid("Only the original current host may stop its owned descendants.")
                }
            } else if current.state == .liveOwner { throw BackendHOSTOrphanFailure.liveOwner }
            guard current.unverifiedPIDs.isEmpty else { throw BackendHOSTOrphanFailure.invalid("Some owned process identities cannot be verified. They were left alone.") }
            guard stopping.insert(sessionID).inserted else { throw BackendHOSTOrphanFailure.invalid("Recovery is already stopping this session.") }
        }
        defer { serialized { _ = stopping.remove(sessionID) } }
        // Freezing and SIGKILL in the middle of a Claude sign-in renewal signs that login out: wait for it, bounded.
        let folder = serialized { records[sessionID]?.renewalFolder }
        let until = Date().addingTimeInterval(NativeSignInRenewal.patience)
        while NativeSignInRenewal.inProgress(folder), Date() < until { try await Task.sleep(for: .milliseconds(250)) }
        var frozen: [BackendHOSTOrphanIdentity] = [], signalled: Set<Int32> = []
        do {
            // Freezing parents before the next bounded census prevents tracked
            // processes from creating an unlimited tree during teardown.
            for _ in 0..<64 {
                let known = try serialized { () throws -> [BackendHOSTOrphanIdentity] in
                    guard let record = records[sessionID] else { throw BackendHOSTOrphanFailure.missingSession }
                    return record.processes
                }
                for identity in known where !frozen.contains(where: { $0.sameProcess(as: identity) }) {
                    if let actual = try kernel.inspect(identity.pid), actual.sameProcess(as: identity), !actual.zombie {
                        if try kernel.signal(actual, SIGSTOP) { frozen.append(actual) }
                    }
                }
                // Delivery success is not a stopped-state acknowledgement.
                // Wait for the actual kernel state before taking the census.
                var acknowledged = false
                for _ in 0..<20 {
                    var waiting = false
                    for identity in frozen {
                        if let actual = try kernel.inspect(identity.pid), actual.sameProcess(as: identity), !actual.zombie, !actual.stopped { waiting = true }
                    }
                    if !waiting { acknowledged = true; break }
                    try await kernel.sleep()
                }
                guard acknowledged else { throw BackendHOSTOrphanFailure.invalid("Owned processes did not acknowledge the recovery freeze. They were resumed; retry recovery.") }
                let before = known.count
                try observeDescendants(sessionID: sessionID)
                let after = serialized { records[sessionID]?.processes.count ?? 0 }
                if after == before { break }
            }
            // Each delivery rechecks birth identity and uses the current audit
            // token, so exec and PID reuse cannot redirect the kill.
            for identity in frozen.reversed() {
                if try kernel.signal(identity, SIGKILL) { signalled.insert(identity.pid) }
            }
        } catch {
            // A failed freeze/census must not leave a verified survivor stopped.
            for identity in frozen { _ = try? kernel.signal(identity, SIGCONT) }
            throw error
        }
        for _ in 0..<80 {
            let done = serialized { () -> Bool in
                guard let record = records[sessionID] else { return true }
                let current = recovery(record)
                return current.livePIDs.isEmpty && current.unverifiedPIDs.isEmpty
            }
            if done { break }
            try await kernel.sleep()
        }
        return try serialized { try proof(sessionID: sessionID, signalled: signalled) }
    }

    /// Only absence, matching zombies or a different birth identity proves the
    /// previously owned process gone. A read failure never deletes its record.
    public func forgetProvenGone(sessionID: String) throws -> BackendHOSTOrphanProof {
        try serialized { try proof(sessionID: sessionID, signalled: []) }
    }

    /// HOSTLOST: stop tracking a dead host's session that recovery could not prove clean, so it never
    /// blocks this host; returns the PIDs that may still be running (shown as a notice, never signalled).
    public func abandon(sessionID: String) throws -> [Int32] {
        try serialized {
            guard let record = records[sessionID] else { return [] }
            let left = recovery(record).livePIDs + recovery(record).unverifiedPIDs
            records[sessionID] = nil
            do { try persist() } catch { records[sessionID] = record; throw error }
            for watch in watches.removeValue(forKey: sessionID)?.values ?? Dictionary<Int32, BackendHOSTOrphanWatch>().values { watch.cancel() }
            problems[sessionID] = nil
            return left
        }
    }
    private var processCount: Int { records.values.reduce(0) { $0 + $1.processes.count } }
    /// The same proof as `forgetProvenGone`, for every other session: a record with no live and no unreadable
    /// process guards nothing. Anything that might still run is kept. Called only at the process bound.
    private func forgetEnded(keeping sessionID: String) {
        let ended = records.values.filter { $0.sessionID != sessionID }.filter { record in
            let status = recovery(record); return status.livePIDs.isEmpty && status.unverifiedPIDs.isEmpty
        }
        guard !ended.isEmpty else { return }
        let before = records
        for record in ended { records[record.sessionID] = nil }
        do { try persist() } catch { records = before; return }
        for record in ended {
            for watch in watches.removeValue(forKey: record.sessionID)?.values ?? Dictionary<Int32, BackendHOSTOrphanWatch>().values { watch.cancel() }
            problems[record.sessionID] = nil; unsaved.remove(record.sessionID)
        }
    }
    private func recovery(_ record: BackendHOSTOrphanRecord) -> BackendHOSTOrphanRecovery {
        var live: [Int32] = [], replaced: [Int32] = [], unknown: [Int32] = []
        var ownerLive = false
        do {
            if let actual = try kernel.inspect(record.owner.pid), actual.sameProcess(as: record.owner), !actual.zombie { ownerLive = true }
        } catch { unknown.append(record.owner.pid) }
        for expected in record.processes {
            do {
                guard let actual = try kernel.inspect(expected.pid) else { continue }
                if !actual.sameProcess(as: expected) { replaced.append(expected.pid) }
                else if !actual.zombie { live.append(expected.pid) }
            } catch { unknown.append(expected.pid) }
        }
        let state: BackendHOSTOrphanRecovery.State = ownerLive ? .liveOwner : !unknown.isEmpty ? .unverified : !live.isEmpty ? .recoverable : !replaced.isEmpty ? .identityChanged : .gone
        return .init(record: record, state: state, livePIDs: live, replacedPIDs: replaced, unverifiedPIDs: unknown)
    }
    private func proof(sessionID: String, signalled: Set<Int32>) throws -> BackendHOSTOrphanProof {
        guard let record = records[sessionID] else { throw BackendHOSTOrphanFailure.missingSession }
        let status = recovery(record)
        var removed = false
        if status.livePIDs.isEmpty && status.unverifiedPIDs.isEmpty {
            records[sessionID] = nil
            do { try persist() }
            catch { records[sessionID] = record; throw error }
            for watch in watches.removeValue(forKey: sessionID)?.values ?? Dictionary<Int32, BackendHOSTOrphanWatch>().values { watch.cancel() }
            problems[sessionID] = nil; removed = true
        }
        return .init(sessionID: sessionID, recordedPIDs: record.processes.map(\.pid), signalledPIDs: signalled.sorted(),
                     remainingPIDs: status.livePIDs, replacedPIDs: status.replacedPIDs, unverifiedPIDs: status.unverifiedPIDs, inventoryRemoved: removed)
    }
    /// HOSTLOST (9 Oct): the journal kept every short-lived descendant forever (~2,000 PIDs for one
    /// day of Claude sessions), and those PIDs were later reused by unrelated processes. A recorded
    /// descendant that is gone, a zombie, or whose PID now belongs to a different process (birth
    /// identity) is forgotten; the root and anything unreadable are kept.
    private func pruneGone(_ record: inout BackendHOSTOrphanRecord) -> Bool {
        let kept = record.processes.filter { expected in
            guard expected.pid != record.rootPID else { return true }
            do {
                guard let actual = try kernel.inspect(expected.pid) else { return false }
                return actual.sameProcess(as: expected) && !actual.zombie
            } catch { return true }
        }
        defer { record.processes = kept }
        return kept.count != record.processes.count
    }
    private func captureDescendants(_ sessionID: String, durable: Bool) throws {
        guard var record = records[sessionID] else { throw BackendHOSTOrphanFailure.missingSession }
        var offset = 0, changed = pruneGone(&record)
        while offset < record.processes.count {
            let expected = record.processes[offset]; offset += 1
            guard let parent = try kernel.inspect(expected.pid), parent.sameProcess(as: expected), !parent.zombie else { continue }
            let children = try kernel.children(parent.pid)
            for pid in children where !record.processes.contains(where: { $0.pid == pid }) {
                guard let child = try kernel.inspect(pid), child.valid, !child.zombie, child.parentPID == parent.pid,
                      child.startedSeconds > parent.startedSeconds || (child.startedSeconds == parent.startedSeconds && child.startedMicroseconds >= parent.startedMicroseconds),
                      let after = try kernel.inspect(parent.pid), after.sameProcess(as: parent) else { continue }
                if processCount + (record.processes.count - (records[sessionID]?.processes.count ?? 0)) >= maximumProcesses { forgetEnded(keeping: sessionID) }
                guard processCount + (record.processes.count - (records[sessionID]?.processes.count ?? 0)) < maximumProcesses else { throw BackendHOSTOrphanFailure.budget }
                record.processes.append(child); changed = true
            }
        }
        guard changed else { return }
        let original = records[sessionID]; records[sessionID] = record
        if durable {
            do { try persist() } catch { records[sessionID] = original; throw error }
        } else { unsaved.insert(sessionID); schedulePersist() }
        // 18 Oct (#180): a forgotten descendant's watch goes with it (it also kept a reused PID unwatched).
        for (pid, watch) in watches[sessionID] ?? [:] where !record.processes.contains(where: { $0.pid == pid }) {
            watch.cancel(); watches[sessionID]?[pid] = nil
        }
    }
    private func schedulePersist() {
        guard pendingPersist == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            pendingPersist = nil
            do { try persist() }
            catch { for id in unsaved where records[id] != nil { problems[id] = "The recovery journal could not be saved. Recovery is limited to the last saved identities." } }
        }
        pendingPersist = work
        queue.asyncAfter(deadline: .now() + Self.coalesceDelay, execute: work)
    }
    private func installWatches(_ sessionID: String) {
        guard let record = records[sessionID] else { return }
        for identity in record.processes where watches[sessionID]?[identity.pid] == nil {
            if let watch = kernel.watch(identity.pid, { [weak self] in
                guard let self else { return }
                queue.async { [weak self] in
                    guard let self, records[sessionID] != nil else { return }
                    do { try captureDescendants(sessionID, durable: false); installWatches(sessionID) }
                    catch { problems[sessionID] = "Descendant observation could not establish complete ownership. Recovery is limited to recorded identities." }
                }
            }) { watches[sessionID, default: [:]][identity.pid] = watch }
        }
    }
    private func persist() throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(Journal(version: 1, sessions: records.values.sorted { $0.sessionID < $1.sessionID }))
        guard data.count <= 8 * 1024 * 1024 else { throw BackendHOSTOrphanFailure.budget }
        try BackendHOSTFiles.atomicWrite(data, to: file)
        // Rename durability matters before child exec is released.
        let parent = open(file.deletingLastPathComponent().path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard parent >= 0 else { throw BackendHOSTOrphanFailure.kernel("open recovery directory for durability", errno) }
        defer { Darwin.close(parent) }
        guard fsync(parent) == 0 else { throw BackendHOSTOrphanFailure.kernel("flush recovery directory", errno) }
        // Every record is now on disk, so a coalesced write still waiting has nothing left to do.
        pendingPersist?.cancel(); pendingPersist = nil; unsaved.removeAll()
    }
    private static func validate(_ record: BackendHOSTOrphanRecord) throws {
        guard UUID(uuidString: record.sessionID) != nil, record.owner.valid, !record.processes.isEmpty,
              record.processes.count <= defaultProcessBudget, record.processes.allSatisfy(\.valid),
              Set(record.processes.map(\.pid)).count == record.processes.count,
              record.processes.contains(where: { $0.pid == record.rootPID && $0.groupID == record.rootPID && $0.parentPID == record.owner.pid }) else {
            throw BackendHOSTOrphanFailure.invalid("The owned recovery journal is invalid. It was left unchanged.")
        }
    }
    private func serialized<T>(_ operation: () throws -> T) rethrows -> T {
        if DispatchQueue.getSpecific(key: key) != nil { return try operation() }
        return try queue.sync(execute: operation)
    }
    deinit { pendingPersist?.cancel(); for session in watches.values { for watch in session.values { watch.cancel() } } }
}
