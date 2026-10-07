import Foundation
import Darwin

/// The whole store.ts domain has one owner. Do not enable native writes while
/// the Node Store still owns state.json; read-only is the construction default.
public actor NativeStateStore {
    public enum Ownership: Equatable, Sendable { case readOnly, exclusive, memory }
    public enum PersistencePolicy: Equatable, Sendable {
        /// Native callers receive a strict save failure and retain the last
        /// committed state. Source-compatible logging remains available below.
        case throwAndRollback
        /// store.ts keeps the new memory value and logs a failed persistence.
        case sourceCompatible
    }
    public enum QuitBehavior: String, Sendable { case ask, keep, stop }
    public typealias ProjectsListener = @Sendable ([String]) throws -> Void

    public static let defaults: NativeRPCValue = .object([
        .init("version", .number(1)), .init("projects", .array([])),
        .init("preferences", .object([.init("theme", .string("dark")), .init("defaultProvider", .string("claude")),
            .init("restoreSessions", .bool(true)), .init("notifyOnComplete", .bool(true))])),
        .init("openSessions", .array([])),
    ])

    public nonisolated let file: URL?
    public nonisolated let ownership: Ownership
    private let failurePolicy: PersistencePolicy
    private let clock: @Sendable () -> Double
    private let report: @Sendable (NativeRPCError) -> Void
    private var lease: NativeStateWriterLease?
    private var state: NativeRPCValue
    private var projectsListeners: [(id: UUID, listener: ProjectsListener)] = []
    private var snapshotListeners: [(id: UUID, listener: @Sendable (NativeRPCValue) -> Void)] = []
    private var ledger: NativeOpenSessionLedger?
    private var closed = false

    public init(file: URL, ownership: Ownership = .readOnly, failurePolicy: PersistencePolicy = .throwAndRollback,
                clock: @escaping @Sendable () -> Double = { Date().timeIntervalSince1970 * 1000 },
                report: @escaping @Sendable (NativeRPCError) -> Void = { _ in }) throws {
        self.file = file.standardizedFileURL
        self.ownership = ownership; self.failurePolicy = failurePolicy; self.clock = clock; self.report = report
        if ownership == .exclusive { lease = try NativeStateWriterLease(file: file.standardizedFileURL) }
        state = Self.load(file: file.standardizedFileURL, report: report)
    }

    /// Pure in-memory construction for assembled previews or the combined gate.
    public init(initialState: NativeRPCValue = NativeStateStore.defaults, failurePolicy: PersistencePolicy = .throwAndRollback,
                clock: @escaping @Sendable () -> Double = { Date().timeIntervalSince1970 * 1000 },
                report: @escaping @Sendable (NativeRPCError) -> Void = { _ in }) {
        file = nil; ownership = .memory; self.failurePolicy = failurePolicy; self.clock = clock; self.report = report
        state = Self.migrating(initialState)
    }

    public func getState() -> NativeRPCValue { state }
    /// Register and seed atomically on this actor. The composition's synchronous
    /// readers project this same owner; they never maintain another disk writer.
    public func observeSnapshot(_ listener: @escaping @Sendable (NativeRPCValue) -> Void) -> NativeRPCSubscription {
        let id = UUID(); snapshotListeners.append((id, listener)); listener(state)
        return NativeRPCSubscription(id: id) { [weak self] in await self?.removeSnapshotListener(id) }
    }
    private func removeSnapshotListener(_ id: UUID) { snapshotListeners.removeAll { $0.id == id } }
    public func getPreferences() -> NativeRPCValue { state["preferences"] }
    public func getQuitBehavior() -> QuitBehavior {
        switch state["quitBehavior"].string { case "keep": .keep; case "stop": .stop; default: .ask }
    }
    public func setQuitBehavior(_ behavior: QuitBehavior) throws { try commit(state.setting("quitBehavior", .string(behavior.rawValue))) }

    @discardableResult
    public func setPreferences(_ patch: NativeRPCValue) throws -> NativeRPCValue {
        let preferences = state["preferences"].merging(try patch.requireObject("preferences patch"))
        try commit(state.setting("preferences", preferences))
        return preferences
    }

    public func getProjects() -> [NativeRPCValue] {
        Self.sortedProjects(state["projects"].elements ?? [])
    }
    public nonisolated static func sortedProjects(_ rows: [NativeRPCValue]) -> [NativeRPCValue] {
        // Stable descending sort, with the same neutral comparison as JS when
        // an old/hand-edited record lacks a usable lastOpenedAt.
        var projects = rows
        for index in projects.indices.dropFirst() {
            var cursor = index
            while cursor > 0, let a = Self.sortTimestamp(projects[cursor]["lastOpenedAt"]),
                  let b = Self.sortTimestamp(projects[cursor - 1]["lastOpenedAt"]), a > b {
                projects.swapAt(cursor, cursor - 1); cursor -= 1
            }
        }
        return projects
    }

    @discardableResult
    public func addProject(_ path: String) throws -> NativeRPCValue {
        try writable()
        var projects = state["projects"].elements ?? []
        if let index = projects.firstIndex(where: { $0["path"].string == path }) {
            projects[index] = projects[index].setting("lastOpenedAt", .number(clock()))
            try commit(state.setting("projects", .array(projects)))
            return projects[index]
        }
        let project = NativeRPCValue.object([.init("path", .string(path)), .init("lastOpenedAt", .number(clock()))])
        projects.append(project)
        try commit(state.setting("projects", .array(projects)))
        announceProjects()
        return project
    }

    public func removeProject(_ path: String) throws {
        let before = state["projects"].elements ?? []
        let after = before.filter { $0["path"].string != path }
        try commit(state.setting("projects", .array(after)))
        if after.count != before.count { announceProjects() }
    }

    public func onProjectsChanged(_ listener: @escaping ProjectsListener) -> NativeRPCSubscription {
        let id = UUID()
        projectsListeners.append((id: id, listener: listener))
        return NativeRPCSubscription(id: id) { [weak self] in await self?.removeProjectsListener(id) }
    }
    private func removeProjectsListener(_ id: UUID) { projectsListeners.removeAll { $0.id == id } }
    private func announceProjects() {
        let paths = (state["projects"].elements ?? []).compactMap { $0["path"].string }
        for entry in projectsListeners {
            do { try entry.listener(paths) } catch { report(.wrapping(error)) }
        }
    }

    public func getOpenSessions() -> [NativeRPCValue] { state["openSessions"].elements ?? [] }
    public func setOpenSessions(_ sessions: [NativeRPCValue]) throws { try commit(state.setting("openSessions", .array(sessions))) }
    public func getAccountLimit(_ configDir: String) -> NativeRPCValue {
        let value = state["accountLimits"][configDir]
        return value == .missing ? .null : value
    }

    @discardableResult
    public func setAccountLimit(_ configDir: String, patch: NativeRPCValue) throws -> NativeRPCValue {
        let map = state["accountLimits"].fields == nil ? NativeRPCValue.object([]) : state["accountLimits"]
        let fact = map[configDir].merging(try patch.requireObject("account limit patch")).setting("at", .number(clock()))
        try commit(state.setting("accountLimits", map.setting(configDir, fact)))
        return fact
    }
    public func forgetAccountLimit(_ configDir: String) throws {
        try writable()
        guard state["accountLimits"].has(configDir) else { return }
        try commit(state.setting("accountLimits", state["accountLimits"].removing(configDir)))
    }
    public func setWindowBounds(_ bounds: NativeRPCValue) throws {
        guard bounds.isNullish || bounds.fields != nil else { throw NativeRPCError.invalidArguments("Window bounds must be an object, null or missing") }
        try commit(state.setting("windowBounds", bounds))
    }

    /// Starting the ledger is a separate assembly choice, exactly like the
    /// original host-core constructor. It migrates anonymous tabs once and
    /// persists pending recovery before any new live session can flush.
    public func startSessionLedger() throws {
        try writable()
        guard ledger == nil else { return }
        let next = try NativeOpenSessionLedger(saved: getOpenSessions())
        try commit(state.setting("openSessions", .array(next.snapshot())))
        ledger = next
    }
    public func ledgerNote(_ id: String, saved: NativeRPCValue) throws { try changeLedger { try $0.note(id, saved: saved) } }
    public func ledgerUpdate(_ id: String, patch: NativeRPCValue) throws { try changeLedger { try $0.update(id, patch: patch) } }
    public func ledgerForget(_ id: String) throws { try changeLedger { $0.forget(id) } }
    public func ledgerDropPending() throws { try changeLedger { $0.dropPending() } }
    public func ledgerTouch(_ id: String) throws {
        guard var next = ledger else { throw ledgerUnavailable() }
        next.touch(id, at: clock()); ledger = next
    }
    public func ledgerGet(_ id: String) throws -> NativeRPCValue { guard let ledger else { throw ledgerUnavailable() }; return ledger.get(id) ?? .null }
    public func ledgerEntries() throws -> [NativeOpenSessionLedger.Entry] { guard let ledger else { throw ledgerUnavailable() }; return ledger.entries() }
    public func ledgerFlush() throws {
        guard let ledger else { throw ledgerUnavailable() }
        if !ledger.isFrozen { try commit(state.setting("openSessions", .array(ledger.snapshot()))) }
    }
    public func ledgerFreeze() throws { guard var next = ledger else { throw ledgerUnavailable() }; next.freeze(); ledger = next }
    public func heldSessions() throws -> [NativeHeldSession] { guard let ledger else { throw ledgerUnavailable() }; return ledger.heldSessions() }
    @discardableResult
    public func holdSession(_ saved: NativeRPCValue, reason: String, pick: Bool = false) throws -> NativeHeldSession {
        var result: NativeHeldSession?
        let at = clock()
        try changeLedger { result = try $0.hold(saved, reason: reason, pick: pick, at: at) }
        guard let result else { throw ledgerUnavailable() }
        return result
    }
    public func failHeldSession(_ key: String, reason: String) throws { let at = clock(); try changeLedger { $0.failHeld(key, reason: reason, at: at) } }
    @discardableResult
    public func releaseHeldSession(_ key: String) throws -> Bool {
        var released = false
        try changeLedger { released = $0.releaseHeld(key) }
        return released
    }
    private func changeLedger(_ change: (inout NativeOpenSessionLedger) throws -> Void) throws {
        try writable()
        guard var next = ledger else { throw ledgerUnavailable() }
        let previous = next.snapshot(), previousHeld = next.heldSessions()
        try change(&next)
        let snapshot = next.snapshot()
        guard snapshot != previous || next.heldSessions() != previousHeld else { return }
        if !next.isFrozen { try commit(state.setting("openSessions", .array(snapshot))) }
        ledger = next
    }
    private func ledgerUnavailable() -> NativeRPCError { .init(code: "ledger-uninitialized", message: "Start the native session ledger before changing recovery records") }

    public func reloadReadOnly() throws {
        guard ownership == .readOnly, let file else { throw NativeRPCError(code: "ownership", message: "Only a read-only store can reload another owner's file") }
        state = Self.load(file: file, report: report)
        for entry in snapshotListeners { entry.listener(state) }
    }
    public func close() { closed = true; projectsListeners = []; snapshotListeners = []; lease = nil }

    private func writable() throws {
        guard !closed else { throw NativeRPCError(code: "closed", message: "The native state store is closed") }
        guard ownership == .memory || ownership == .exclusive && lease != nil else {
            throw NativeRPCError(code: "store-read-only", message: "The native state store is read-only. Transfer every Store method from the Node owner before enabling native writes.")
        }
    }
    private func commit(_ next: NativeRPCValue) throws {
        try writable()
        do {
            if let file, ownership == .exclusive { try NativeStateWriterLease.write(try next.encodedJSON(pretty: true), to: file) }
            state = next
        } catch {
            let failure = NativeRPCError(code: "persistence", message: "Could not save native state: \(error.localizedDescription)")
            report(failure)
            if failurePolicy == .sourceCompatible { state = next } else { throw failure }
        }
        for entry in snapshotListeners { entry.listener(state) }
    }
    private static func load(file: URL, report: @Sendable (NativeRPCError) -> Void) -> NativeRPCValue {
        guard FileManager.default.fileExists(atPath: file.path) else { return defaults }
        do { return migrating(try NativeRPCValue.parseJSON(Data(contentsOf: file), maximumBytes: 16_777_216)) }
        catch { report(.init(code: "state-load", message: "State could not be read; defaults are active: \(error.localizedDescription)")); return defaults }
    }
    private static func sortTimestamp(_ value: NativeRPCValue) -> Double? {
        switch value {
        case .number(let number): return number.isFinite ? number : nil
        case .null: return 0
        case .bool(let boolean): return boolean ? 1 : 0
        case .string(let string):
            let text = string.trimmingCharacters(in: .whitespacesAndNewlines)
            if text.isEmpty { return 0 }
            if text.hasPrefix("0x") || text.hasPrefix("0X") { return UInt64(text.dropFirst(2), radix: 16).map(Double.init) }
            return Double(text).flatMap { $0.isFinite ? $0 : nil }
        case .array(let values):
            if values.isEmpty { return 0 }
            if values.count == 1 { return sortTimestamp(values[0]) }
            return nil
        default: return nil
        }
    }
    public static func migrating(_ raw: NativeRPCValue) -> NativeRPCValue {
        guard raw.fields != nil else { return defaults }
        var result = defaults.merging(raw)
        result = result.setting("preferences", defaults["preferences"].merging(raw["preferences"]))
        result = result.setting("projects", raw["projects"].elements.map(NativeRPCValue.array) ?? .array([]))
        result = result.setting("openSessions", raw["openSessions"].elements.map(NativeRPCValue.array) ?? .array([]))
        let facts = raw["accountLimits"]
        let validFacts = facts.fields?.allSatisfy { $0.value.fields != nil || $0.value.elements != nil } == true
        return result.setting("accountLimits", validFacts ? facts : .object([]))
    }
}

/// An advisory lock prevents two native actors/processes claiming the same
/// file. Node does not participate: assembly must explicitly stop its owner.
private final class NativeStateWriterLease: @unchecked Sendable {
    private static let owners = NativeStateOwnerSet()
    private let descriptor: Int32
    private let ownerKey: String
    init(file: URL) throws {
        let key = file.deletingLastPathComponent().resolvingSymlinksInPath().appendingPathComponent(file.lastPathComponent).path
        guard Self.owners.acquire(key) else {
            throw NativeRPCError(code: "store-owner-conflict", message: "Another native state writer already owns this data directory")
        }
        var acquired = false
        defer { if !acquired { Self.owners.release(key) } }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let lock = file.path + ".native-owner.lock"
        let fd = Darwin.open(lock, O_WRONLY | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw Self.failure("open native state ownership lock") }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            Darwin.close(fd)
            throw NativeRPCError(code: "store-owner-conflict", message: "Another native state writer already owns this data directory")
        }
        descriptor = fd
        ownerKey = key
        acquired = true
    }
    deinit { flock(descriptor, LOCK_UN); Darwin.close(descriptor); Self.owners.release(ownerKey) }

    static func write(_ data: Data, to file: URL) throws {
        let temporary = file.path + ".\(getpid()).\(UUID().uuidString).tmp"
        let descriptor = Darwin.open(temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw failure("create atomic state temporary file") }
        var closed = false
        defer { if !closed { Darwin.close(descriptor) }; Darwin.unlink(temporary) }
        try data.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else { return }
            var offset = 0
            while offset < buffer.count {
                let amount = Darwin.write(descriptor, base.advanced(by: offset), buffer.count - offset)
                if amount < 0, errno == EINTR { continue }
                guard amount > 0 else { throw failure("write atomic state data") }
                offset += amount
            }
        }
        guard Darwin.fsync(descriptor) == 0 else { throw failure("flush atomic state data") }
        let closeStatus = Darwin.close(descriptor)
        closed = true
        guard closeStatus == 0 else { throw failure("close atomic state data") }
        guard Darwin.rename(temporary, file.path) == 0 else { throw failure("replace native state atomically") }
        let directory = Darwin.open(file.deletingLastPathComponent().path, O_RDONLY | O_CLOEXEC)
        if directory >= 0 { _ = Darwin.fsync(directory); Darwin.close(directory) }
    }
    static func failure(_ action: String) -> NativeRPCError { .init(code: "filesystem", message: "Could not \(action): \(String(cString: strerror(errno)))") }
}

private final class NativeStateOwnerSet: @unchecked Sendable {
    private let lock = NSLock()
    private var files: Set<String> = []
    func acquire(_ file: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return files.insert(file).inserted
    }
    func release(_ file: String) { lock.lock(); files.remove(file); lock.unlock() }
}
