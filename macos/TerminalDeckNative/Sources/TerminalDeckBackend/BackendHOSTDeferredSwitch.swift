import Foundation
import Darwin
import TerminalDeckNativeCore

/// The pending register belongs to the host, not an app attachment. Only the
/// existing Claude broker-seat switch is performed here; no CLI is spawned.
public actor BackendHOSTDeferredSwitch {
    public struct Row: Codable, Sendable {
        public enum Phase: String, Codable, Sendable { case queued, applying, awaitingReread, cancelling, confirmed }
        public var sessionID: String
        public var pid: Int32
        public var targetID: String
        public var targetName: String
        public var previousID: String
        public var phase: Phase
        public var requestedAt: Date
        public var afterSequence: UInt64
    }
    public enum Event: Sendable {
        case pending(Row), confirmed(BackendSessionMeta), failed(sessionID: String, message: String), cleared(sessionID: String)
    }
    struct Operations: Sendable {
        var dataRoot: URL
        var sessions: @Sendable () -> [BackendSessionMeta]
        var pid: @Sendable (String) -> Int32?
        var profile: @Sendable (String) async throws -> BackendAccountProfile?
        var seat: @Sendable (String) async -> BackendAccountSeatSnapshot?
        var sequence: @Sendable () async -> UInt64
        var dependencies: @Sendable () async -> BackendAccountSwitchInPlace.Dependencies
        var retarget: @Sendable (String, String) async throws -> Bool
        var setAccount: @Sendable (String, BackendAccountIdentity, String?) -> BackendSessionMeta?
        var markUsed: @Sendable (String, String) async throws -> Void
        var observeLookup: @Sendable (@escaping @Sendable (BackendAccountCredentialLookup) -> Void) async -> UUID?
        var removeLookup: @Sendable (UUID) async -> Void
        var observeProcess: @Sendable (@escaping @Sendable (BackendSessionEvent) -> Void) -> NativeRPCSubscription?
    }
    private struct Nudge: Sendable { var path: String; var device: dev_t; var inode: ino_t }
    private struct Pending: Sendable {
        var token: UUID
        var row: Row
        var target: BackendAccountProfile
        var seat: BackendAccountSeatSnapshot
        var directory: String?
        var applied = false
        var cancelRequested = false
        var nudge: Nudge?
        var early: BackendAccountCredentialLookup?
    }
    private let operations: Operations
    private let changed: @Sendable (Event) -> Void
    private var pending: [String: Pending] = [:]
    private var work: [String: Task<Row?, Never>] = [:]
    private var entrants: Set<String> = []
    private var lookupObserver: UUID?
    private var processObserver: NativeRPCSubscription?
    private var observing = false
    private var observerTask: Task<UUID?, Never>?
    private var stopped = false
    /// 13 Oct: why the last immediate switch of a session was refused, for the caller that asked.
    private var refusals: [String: String] = [:]

    public init(accountService: BackendHOSTAccountService, manager: BackendPTYManager, changed: @escaping @Sendable (Event) -> Void) {
        operations = Operations(dataRoot: accountService.configuration.dataDirectory, sessions: { manager.list() }, pid: { manager.pidOf($0) },
            profile: { try await accountService.accounts.profiles.find($0) }, seat: { await accountService.accounts.broker.seatSnapshot(sessionID: $0) },
            sequence: { await accountService.accounts.broker.credentialSequence() },
            dependencies: { await accountService.accounts.broker.switchInPlaceDependencies() },
            retarget: { try await accountService.retarget(sessionID: $0, accountID: $1) },
            setAccount: { manager.setAccount($0, account: $1, home: $2) }, markUsed: { try await accountService.accounts.profiles.markUsed(id: $0, projectPath: $1) },
            observeLookup: { listener in await accountService.accounts.broker.onCredentialLookup(listener) },
            removeLookup: { await accountService.accounts.broker.removeCredentialLookupListener($0) },
            observeProcess: { listener in manager.remoteServeObserve { listener($0.event) } })
        self.changed = changed
    }
    init(operations: Operations, changed: @escaping @Sendable (Event) -> Void) { self.operations = operations; self.changed = changed }

    public func request(sessionID: String, targetID: String, status: BackendSessionStatus, deferUntilIdle: Bool) async throws -> Row {
        guard !stopped, pending[sessionID] == nil, work[sessionID] == nil, entrants.insert(sessionID).inserted else {
            throw BackendSessionFailure.unsupported("This session is already changing account, or the app is closing. Try again in a moment.")
        }
        defer { _ = entrants.remove(sessionID) }
        await attachObservers()
        guard let meta = operations.sessions().first(where: { $0.id == sessionID && $0.exitCode == nil }),
              let pid = operations.pid(sessionID) else { throw BackendSessionFailure.missingSession }
        guard meta.provider == "claude" else {
            throw BackendSessionFailure.unsupported("Only a Claude session can change account while it runs. Nothing was changed.")
        }
        guard let target = try await operations.profile(targetID), target.provider == "claude" else {
            throw BackendSessionFailure.unsupported("That account is not a Claude account on this Mac any more. Pick another one.")
        }
        guard !BackendSessionSwitchCoordinator.requiresAccountReplacement(sourceID: meta.profileId, targetID: target.id) else {
            throw BackendSessionSwitchNoSeat(sessionID: sessionID)
        }
        guard let seat = await operations.seat(sessionID), seat.processPID == pid, let previous = seat.servingAccountID,
              operations.pid(sessionID) == pid else { throw BackendSessionSwitchNoSeat(sessionID: sessionID) }
        guard previous != target.id else { throw BackendSessionFailure.unsupported("This session is already running as that account.") }
        if let directory = seat.storeDirectory { try validateDirectory(directory) }
        let sequence = await operations.sequence(), phase: Row.Phase = deferUntilIdle && status == .working ? .queued : .applying
        guard !stopped, operations.pid(sessionID) == pid else { throw BackendSessionFailure.closed }
        let row = Row(sessionID: sessionID, pid: pid, targetID: target.id, targetName: target.name, previousID: previous,
            phase: phase, requestedAt: Date(), afterSequence: sequence)
        pending[sessionID] = Pending(token: UUID(), row: row, target: target, seat: seat, directory: seat.storeDirectory)
        changed(.pending(row))
        if phase == .queued { return row }
        refusals[sessionID] = nil
        if let done = await launchWork(sessionID) { return done }
        // 13 Oct: a refused switch said "Switched to …" and then quietly went back. It says why instead.
        if let why = refusals.removeValue(forKey: sessionID) { throw BackendSessionFailure.unsupported(why) }
        return row
    }
    public func noteStatus(sessionID: String, status: BackendSessionStatus) async {
        guard !stopped, pending[sessionID]?.row.phase == .queued,
              [.idle, .waiting, .completed].contains(status) else { return }
        _ = await launchWork(sessionID)
        // A queued switch has no caller waiting for its refusal; the `.failed` event already said it (#415).
        refusals[sessionID] = nil
    }
    public func noteLookup(_ event: BackendAccountCredentialLookup) async {
        guard var value = pending[event.sessionID], !value.cancelRequested, event.accountID == value.row.targetID,
              event.sequence > value.row.afterSequence, event.deliveredAt >= value.row.requestedAt,
              event.processPID == value.row.pid, operations.pid(event.sessionID) == value.row.pid,
              BackendAccountProfile.loginSlot(event.slot) || event.slot == "keychain:Claude Code" else { return }
        guard value.row.phase != .queued else { return }
        if !value.applied { value.early = event; pending[event.sessionID] = value; return }
        guard let seat = await operations.seat(event.sessionID), seat.processPID == value.row.pid,
              seat.servingAccountID == value.row.targetID, pending[event.sessionID]?.token == value.token,
              pending[event.sessionID]?.cancelRequested == false else { return }
        guard let meta = operations.setAccount(event.sessionID, value.target.identity, value.seat.launchAccountID) else {
            await processExited(sessionID: event.sessionID); return
        }
        pending[event.sessionID] = nil
        clearNudge(value.nudge)
        do { try await operations.markUsed(value.target.id, meta.cwd) }
        catch { changed(.failed(sessionID: event.sessionID, message: "The new login was served, but its usage record could not be saved.")) }
        changed(.confirmed(meta))
    }
    public func list() -> [Row] { pending.values.map(\.row).sorted { $0.requestedAt < $1.requestedAt } }
    public func cancel(sessionID: String) async throws {
        guard var value = pending[sessionID] else { return }
        if value.row.phase == .queued { pending[sessionID] = nil; changed(.cleared(sessionID: sessionID)); return }
        value.cancelRequested = true; value.row.phase = .cancelling; pending[sessionID] = value; changed(.pending(value.row))
        if let task = work[sessionID] { _ = await task.value }
        if let remaining = pending[sessionID] { try await revert(remaining) }
    }
    public func processExited(sessionID: String) async {
        refusals[sessionID] = nil
        guard let value = pending.removeValue(forKey: sessionID) else { return }
        clearNudge(value.nudge); changed(.cleared(sessionID: sessionID))
    }
    /// Explicit host stop only. App detach deliberately never invokes this.
    /// 18 Oct (#415): every pending switch is cancelled on its own, so one that cannot be put back never leaves
    /// the rest half-switched, and the listeners always go. The first refusal is answered after all of that.
    public func stop() async throws {
        stopped = true
        var first: Error?
        for id in Array(pending.keys) {
            do { try await cancel(sessionID: id) } catch { if first == nil { first = error } }
        }
        refusals.removeAll()
        if let lookupObserver { await operations.removeLookup(lookupObserver) }; lookupObserver = nil
        if let processObserver { await processObserver.cancelAndWait() }; processObserver = nil
        if let first { throw first }
    }
    private func launchWork(_ id: String) async -> Row? {
        if let existing = work[id] { return await existing.value }
        guard let value = pending[id], !value.cancelRequested else { return nil }
        let task = Task { await self.apply(id, token: value.token) }
        work[id] = task
        let result = await task.value; work[id] = nil; return result
    }
    private func apply(_ id: String, token: UUID) async -> Row? {
        guard !stopped, var value = pending[id], value.token == token, !value.cancelRequested, operations.pid(id) == value.row.pid else { return nil }
        let sequence = await operations.sequence()
        guard let latest = pending[id], latest.token == token, !latest.cancelRequested, operations.pid(id) == latest.row.pid else { return nil }
        value = latest; value.row.phase = .applying; value.row.requestedAt = Date(); value.row.afterSequence = sequence
        pending[id] = value; changed(.pending(value.row))
        var dependencies = await operations.dependencies()
        let originalRetarget = dependencies.retarget
        dependencies.retarget = { [weak self] session, account in
            guard let self, await self.mayRetarget(id, token: token) else { return false }
            return await originalRetarget(session, account)
        }
        let result = await BackendAccountSwitchInPlace.switchInPlace(sessionID: id,
            account: .init(id: value.target.id, name: value.target.name, configDir: value.target.configDir), dependencies: dependencies)
        switch result {
        case .refused(let reason):
            if pending[id]?.token == token { pending[id] = nil; refusals[id] = reason; changed(.failed(sessionID: id, message: reason)) }
            return nil
        case .switched(let nudged, let path, _):
            let nudge = nudged == .created ? path.flatMap { nudgeIdentity($0, directory: value.directory) } : nil
            guard var actual = pending[id], actual.token == token, operations.pid(id) == actual.row.pid else { clearNudge(nudge); return nil }
            actual.applied = true; actual.nudge = nudge; actual.row.phase = actual.cancelRequested ? .cancelling : .awaitingReread
            pending[id] = actual
            if actual.cancelRequested {
                do { try await revert(actual) } catch { changed(.failed(sessionID: id, message: "The account change could not yet be reverted. It remains pending.")) }
                return actual.row
            }
            changed(.pending(actual.row))
            if let early = actual.early { await noteLookup(early) }
            var answer = actual.row
            if pending[id] == nil { answer.phase = .confirmed }
            return answer
        }
    }
    private func mayRetarget(_ id: String, token: UUID) async -> Bool {
        guard let value = pending[id], value.token == token, !value.cancelRequested, !stopped,
              operations.pid(id) == value.row.pid, let seat = await operations.seat(id), seat.processPID == value.row.pid else { return false }
        if let directory = value.directory { do { try validateDirectory(directory) } catch { return false } }
        return true
    }
    private func revert(_ value: Pending) async throws {
        let id = value.row.sessionID
        guard pending[id]?.token == value.token else { return }
        if operations.pid(id) == value.row.pid, value.applied {
            if let directory = value.directory { try validateDirectory(directory) }
            guard try await operations.retarget(id, value.row.previousID) else { throw BackendSessionFailure.unsupported("The previous login could not be put back yet. Try again in a moment.") }
            if let directory = value.directory { _ = BackendAccountSwitchInPlace.nudge(directory) }
        }
        guard pending[id]?.token == value.token else { return }
        pending[id] = nil; clearNudge(value.nudge); changed(.cleared(sessionID: id))
    }
    private func attachObservers() async {
        guard !observing, !stopped else { return }
        let task: Task<UUID?, Never>
        if let existing = observerTask { task = existing }
        else {
            let operations = operations
            task = Task { [weak self] in await operations.observeLookup { [weak self] event in Task { await self?.noteLookup(event) } } }
            observerTask = task
        }
        let token = await task.value
        guard !stopped else { if let token { await operations.removeLookup(token) }; observerTask = nil; return }
        guard !observing else { return }
        observing = true; observerTask = nil; lookupObserver = token
        processObserver = operations.observeProcess { [weak self] event in
            Task {
                switch event {
                case .status(let id, let status): await self?.noteStatus(sessionID: id, status: status)
                case .exit(let id, _), .removed(let id, _): await self?.processExited(sessionID: id)
                case .data: break
                }
            }
        }
    }
    private func validateDirectory(_ path: String) throws {
        let root = operations.dataRoot.standardizedFileURL.resolvingSymlinksInPath()
        let target = URL(fileURLWithPath: path)
        guard BackendAccountFiles.descendant(target.path, root: root.path), target.path == target.resolvingSymlinksInPath().path else {
            throw BackendSessionFailure.unsupported("This session keeps its login in a folder the app does not own, so nothing was changed.")
        }
        var info = stat()
        guard lstat(target.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR, info.st_uid == geteuid() else {
            throw BackendSessionFailure.unsupported("This session keeps its login in a folder another user owns, so nothing was changed.")
        }
        let file = target.appendingPathComponent(BackendAccountSwitchInPlace.nudgeFile)
        if lstat(file.path, &info) == 0 {
            guard info.st_mode & S_IFMT == S_IFREG, info.st_uid == geteuid() else { throw BackendSessionFailure.unsupported("This session's login file is not one the app can use, so nothing was changed.") }
        } else if errno != ENOENT { throw BackendSessionFailure.unsupported("This session's login file could not be checked, so nothing was changed.") }
    }
    private func nudgeIdentity(_ path: String, directory: String?) -> Nudge? {
        guard let directory, (directory as NSString).appendingPathComponent(BackendAccountSwitchInPlace.nudgeFile) == path,
              (try? validateDirectory(directory)) != nil else { return nil }
        var info = stat()
        guard lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == geteuid() else { return nil }
        return .init(path: path, device: info.st_dev, inode: info.st_ino)
    }
    private func clearNudge(_ nudge: Nudge?) {
        guard let nudge else { return }; var info = stat()
        guard lstat(nudge.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == geteuid(),
              info.st_dev == nudge.device, info.st_ino == nudge.inode else { return }
        _ = BackendAccountSwitchInPlace.clearNudge(nudge.path)
    }
}
