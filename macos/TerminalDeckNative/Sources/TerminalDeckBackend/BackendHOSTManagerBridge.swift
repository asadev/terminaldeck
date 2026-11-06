import Foundation
import TerminalDeckNativeCore

/// Frontend transport only. The helper remains the only PTY/parser/replay
/// owner. This source is staged outside the product until INT2 applies wiring.
public final class BackendHOSTManagerBridge: @unchecked Sendable {
    public typealias Write = @Sendable (String, Data, Double?) throws -> Void
    public typealias Drain = @Sendable (Int) async throws -> Bool
    private let client: BackendHOSTClient
    private let writeInput: Write
    private let waitForDrain: Drain
    private let watch: @Sendable (Bool) throws -> Void
    private let stampIndependent: @Sendable (inout BackendHOSTProtocol.Launch) -> Void
    private let lock = NSLock()
    private var owned: Set<String> = []
    private var localChats: Set<String> = []
    private var rows: [String: BackendSessionMeta] = [:]
    private var order: [String] = []
    private var epochs: [String: UInt64] = [:]
    private var exited: [String: Int] = [:]
    private var removed: Set<String> = []
    /// 22 Oct: a finished job's history the app is opening again. Its next snapshot is let back in once,
    /// even after this bridge saw the row removed (every other late snapshot still never resurrects a row).
    private var readmitting: Set<String> = []
    private var attached = false, detached = false
    private var sequence: UInt64 = 0
    private var failures: [String] = []
    private struct Delivery: Sendable {
        let snapshot: @Sendable (BackendHOSTProtocol.Snapshot) -> Void
        let event: @Sendable (BackendHOSTProtocol.Event) -> Void
        let disconnected: @Sendable () -> Void
    }
    private var delivery: Delivery?
    private var peers: [BackendHOSTManagerBridge] = []
    /// SCROLL (9 Oct): the last visible screen per session, valid until that session's next
    /// output/exit/removal. Readers between two outputs share one viewport request.
    private var screens: [String: (generation: UInt64, text: String, at: UInt64)] = [:]
    private var screenFetching: Set<String> = []
    /// At most one host screen request per session per quarter second, however many readers ask;
    /// a helper already running from an older build still answers each one with a full snapshot.
    static let screenFreshness: UInt64 = 250_000_000
    private var outputGeneration: [String: UInt64] = [:]
    /// HOSTLOST (9 Oct): called once with the live sessions this bridge owned when its host died
    /// or was replaced. Their ledger entries are left alone, so the next launch resumes them.
    private var hostLostHandler: (@Sendable ([String]) -> Void)?
    public private(set) var hostLost = false
    public func onHostLost(_ handler: @escaping @Sendable ([String]) -> Void) {
        let peersNow = lock.withLock { () -> [BackendHOSTManagerBridge] in hostLostHandler = handler; return peers }
        for peer in peersNow { peer.onHostLost(handler) }
    }
    public var anyHostLost: Bool { lock.withLock { hostLost || peers.contains { $0.hostLost } } }
    /// L8 (11 Oct): told once when this bridge's host is gone for good (not a transient drop), live sessions
    /// or not, so the app can start a new host and reconnect without a restart.
    private var hostGoneHandler: (@Sendable () -> Void)?
    public func onHostGone(_ handler: (@Sendable () -> Void)?) { lock.withLock { hostGoneHandler = handler } }
    /// After `client.adopt`: the sessions of the dead host are let go (their tabs already show "host lost" and
    /// their saved entries stay, so they can be resumed), then the SAME delivery is attached to the new host.
    /// Returns the ids that were let go.
    /// The sessions this bridge still counts as running (before a reattach: the ones the dead host took).
    public func liveIDs() -> [String] { lock.withLock { order.filter { rows[$0]?.exitCode == nil && !removed.contains($0) } } }
    @discardableResult
    public func reattach(ready: @escaping @Sendable () -> Void) throws -> [String] {
        let (callbacks, gone, next) = try lock.withLock { () throws -> (Delivery, [String], UInt64) in
            guard !detached, let delivery else { throw BackendHOSTFailure.unavailable }
            let gone = order.filter { rows[$0]?.exitCode == nil && !removed.contains($0) }
            owned.removeAll(); rows.removeAll(); order.removeAll(); epochs.removeAll(); exited.removeAll(); removed.removeAll(); readmitting.removeAll()
            screens.removeAll(); screenFetching.removeAll(); outputGeneration.removeAll(); attached = false; hostLost = false
            return (delivery, gone, sequence)
        }
        // The app learns they ended (their process died with the host), so nothing still counts them as running.
        for (offset, id) in gone.enumerated() { callbacks.event(.init(sequence: next &+ UInt64(offset + 1), event: .exit(id: id, exitCode: -1))) }
        try attach(snapshot: callbacks.snapshot, event: callbacks.event, ready: ready, disconnected: callbacks.disconnected)
        return gone
    }
    private func checkHostAfterDisconnect() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            // A short, bounded check (startup-style, no resident polling): a few hellos over about 3 s.
            for attempt in 0..<6 {
                guard let self, !self.lock.withLock({ self.detached }) else { return }
                if self.client.sameHostAnswers() { return } // the same host: a transient drop, nothing lost
                if attempt < 5 { Thread.sleep(forTimeInterval: 0.5) }
            }
            guard let self else { return }
            if let gone = self.lock.withLock({ self.detached ? nil : self.hostGoneHandler }) { gone() }
            let (lost, handler) = self.lock.withLock { () -> ([String], (@Sendable ([String]) -> Void)?) in
                guard !detached, !hostLost else { return ([], nil) }
                let live = order.filter { rows[$0]?.exitCode == nil && !removed.contains($0) }
                guard !live.isEmpty else { return ([], nil) } // an idle host leaving on its own lost nothing
                hostLost = true
                return (live, hostLostHandler)
            }
            if !lost.isEmpty { handler?(lost) }
        }
    }
    public init(client: BackendHOSTClient, write: @escaping Write, drain: @escaping Drain,
                setWatched: @escaping @Sendable (Bool) throws -> Void,
                stampIndependent: @escaping @Sendable (inout BackendHOSTProtocol.Launch) -> Void) {
        self.client = client; writeInput = write; waitForDrain = drain; watch = setWatched; self.stampIndependent = stampIndependent
    }
    /// Receivers must enqueue onto the concrete manager queue without waiting
    /// on it. A manager operation may be waiting on this client receipt.
    public func attach(snapshot: @escaping @Sendable (BackendHOSTProtocol.Snapshot) -> Void,
                       event: @escaping @Sendable (BackendHOSTProtocol.Event) -> Void,
                       ready: @escaping @Sendable () -> Void,
                       disconnected: @escaping @Sendable () -> Void) throws {
        lock.withLock { delivery = .init(snapshot: snapshot, event: event, disconnected: disconnected) }
        try client.attach(onSnapshot: { [weak self] value in
            guard let self else { return }
            let deliver = lock.withLock { () -> Bool in
                guard !detached, !localChats.contains(value.session.id) else { return false }
                if removed.contains(value.session.id) {
                    guard readmitting.remove(value.session.id) != nil else { return false }
                    removed.remove(value.session.id)
                }
                owned.insert(value.session.id)
                epochs[value.session.id, default: 0] &+= 1
                if rows[value.session.id] == nil { order.append(value.session.id) }
                rows[value.session.id] = value.session; sequence = max(sequence, value.sequence); return true
            }
            if deliver { snapshot(value) }
        }, onEvent: { [weak self] value in
            guard let self else { return }
            let deliver = lock.withLock { () -> Bool in
                guard !detached, !localChats.contains(value.id), !removed.contains(value.id) else { return false }; sequence = max(sequence, value.sequence); owned.insert(value.id)
                outputGeneration[value.id, default: 0] &+= 1 // any event can change the visible screen
                if value.kind == .removed { screens[value.id] = nil }
                if value.kind == .exit || value.kind == .removed { epochs[value.id, default: 0] &+= 1 }
                if value.kind == .exit { exited[value.id] = value.exitCode ?? -1; rows[value.id]?.exitCode = value.exitCode }
                if value.kind == .removed {
                    removed.insert(value.id); rows[value.id] = nil; order.removeAll { $0 == value.id }
                    owned.remove(value.id); epochs[value.id] = nil; exited[value.id] = nil
                    outputGeneration[value.id] = nil; screenFetching.remove(value.id)
                }
                return true
            }
            if deliver { event(value) }
        }, onReady: { [weak self] in
            guard let self else { return }
            let deliver = lock.withLock { () -> Bool in guard !detached else { return false }; attached = true; return true }
            if deliver { ready() }
        }, onDisconnect: { [weak self] in
            guard let self else { return }; lock.withLock { attached = false }; disconnected()
            checkHostAfterDisconnect()
        })
    }
    /// Retains the old core helper while a separate agents namespace owns new
    /// managed sessions. App attachment never replaces either process owner.
    public func addPeer(_ peer: BackendHOSTManagerBridge, ready: @escaping @Sendable () -> Void) throws {
        guard peer !== self else { throw BackendHOSTFailure.invalid("A helper cannot peer with itself.") }
        let callbacks = try lock.withLock { () throws -> Delivery in
            guard !detached, let delivery, !peers.contains(where: { $0 === peer }) else { throw BackendHOSTFailure.unavailable }
            peers.append(peer); return delivery
        }
        if let handler = lock.withLock({ hostLostHandler }) { peer.onHostLost(handler) }
        try peer.attach(snapshot: callbacks.snapshot, event: callbacks.event, ready: ready, disconnected: callbacks.disconnected)
    }
    private func peer(_ id: String) -> BackendHOSTManagerBridge? {
        let values = lock.withLock { peers }; return values.first { $0.owns(id) }
    }
    public func owns(_ id: String) -> Bool { !lock.withLock { localChats.contains(id) } && (lock.withLock { owned.contains(id) } || peer(id) != nil) }
    public func preferLocalChat(_ id: String, _ local: Bool) {
        let children = lock.withLock { () -> [BackendHOSTManagerBridge] in
            if local { localChats.insert(id) } else { localChats.remove(id) }
            return peers
        }
        for child in children { child.preferLocalChat(id, local) }
    }
    /// Before the app opens a finished job's kept history again in the helper (`chats.open`): that one snapshot is
    /// accepted even when it follows the row's removal. Peers get the same mark; only the owner's snapshot arrives.
    public func readmit(_ id: String) {
        let values = lock.withLock { () -> [BackendHOSTManagerBridge] in if !detached { readmitting.insert(id) }; return peers }
        client.readmit(id)
        for peer in values { peer.readmit(id) }
    }
    public func list() -> [BackendSessionMeta] {
        let current = lock.withLock { (order.filter { !localChats.contains($0) }.compactMap { rows[$0] }, peers) }
        return current.0 + current.1.flatMap { $0.list() }
    }
    public func currentSequence() -> UInt64 { lock.withLock { sequence } }
    public func pid(_ id: String) -> Int32? { if let peer = peer(id) { return peer.pid(id) }; return client.cachedPID(id) }
    /// The visible screen, never a full snapshot (SCROLL, 9 Oct): cached until the session's next
    /// event; one cheap viewport request otherwise.
    public func screen(_ id: String) throws -> String? {
        guard owns(id) else { return nil }
        if let peer = peer(id) { return try peer.screen(id) }
        let now = DispatchTime.now().uptimeNanoseconds
        let generation = lock.withLock { () -> UInt64? in
            let current = outputGeneration[id, default: 0]
            guard attached, !detached, let cached = screens[id] else { screenFetching.insert(id); return current }
            if cached.generation == current { return nil }                                   // nothing new since
            if now &- cached.at < Self.screenFreshness || screenFetching.contains(id) { return nil } // recent enough / one already asking
            screenFetching.insert(id); return current
        }
        guard let generation else { return lock.withLock { screens[id]?.text } }
        defer { lock.withLock { _ = screenFetching.remove(id) } }
        guard let text = try client.viewport(id) else { return nil }
        lock.withLock { if !detached, !removed.contains(id) { screens[id] = (generation, text, DispatchTime.now().uptimeNanoseconds) } }
        return text
    }
    /// The status from the event stream, without asking the helper (27 Oct: listing sessions for a phone asked
    /// for a full snapshot, raw tail included, of every session without a status yet).
    public func cachedStatus(_ id: String) -> BackendSessionStatus? {
        guard owns(id) else { return nil }
        if let peer = peer(id) { return peer.cachedStatus(id) }
        return client.cachedStatus(id)
    }
    public func snapshot(_ id: String, remount: Bool = false) throws -> BackendHOSTProtocol.Snapshot? {
        guard owns(id) else { return nil }
        if let peer = peer(id) { return try peer.snapshot(id, remount: remount) }
        return try client.snapshot(id, remount: remount) // actual helper viewport/replay, never parsed here
    }
    /// Only the resolved launcher can invoke this; raw manager.create cannot
    /// classify deferred owners or construct an authenticated resolved launch.
    public func create(input: BackendCreateSessionInput, spawn: BackendSpawnSpec,
                       inheritedEnvironment: [String: String], openShim: (directory: String, browser: String)?, context: BackendLaunchContext,
                       machineID: String?, independent: Bool) throws -> BackendSessionMeta {
        guard independent, lock.withLock({ attached && !detached }), input.taskID == nil,
              context.deviceBoundary == nil, context.appFenceID == nil, !context.isAppComposed,
              input.agentSettings == nil, input.taskProject == nil, input.originApp == nil,
              input.origin == nil || input.origin == .user,
              input.originRoutineId == nil, input.originRunId == nil else {
            throw BackendSessionFailure.missingCapability("an owner-independent ordinary host launch")
        }
        let id = UUID().uuidString.lowercased()
        var launch = try BackendHOSTProtocol.Launch(id: id, input: input, spawn: spawn,
            inheritedEnvironment: inheritedEnvironment, openShim: openShim, context: context, machineID: machineID)
        // Root's core admission field is stamped by the protected resolved
        // launch seam; this default-source bridge has no unapplied API dependency.
        launch.accountHandle = nil; launch.mcpLeaseIDs = nil
        stampIndependent(&launch)
        spawn.beforeExposure?(id) // stable id, before remote child exec/exposure
        let epoch = lock.withLock { () -> UInt64 in owned.insert(id); return epochs[id, default: 0] }
        // Keep ownership on failed/uncertain replies. A newer snapshot/terminal
        // event wins over a create reply; it must never resurrect a removed row.
        let result = try client.create(launch)
        return try record(result: result, id: id, epoch: epoch)
    }
    #if TD_HOST_ACCOUNT_BRIDGE
    public func createManaged(input: BackendCreateSessionInput, spawn: BackendSpawnSpec,
        inheritedEnvironment: [String: String], openShim: (directory: String, browser: String)?, context: BackendLaunchContext,
        accountHandle: String?, leaseIDs: [UUID], machineID: String) throws -> BackendSessionMeta {
        guard lock.withLock({ attached && !detached }), input.chat == true || (input.taskID == nil && input.taskProject == nil),
              context.deviceBoundary == nil, context.appFenceID == nil, !context.isAppComposed,
              input.chat == true || (input.originApp == nil && input.originRoutineId == nil && input.originRunId == nil) else { throw BackendHOSTFailure.unavailable }
        let id = UUID().uuidString.lowercased()
        var launch = try BackendHOSTProtocol.Launch(id: id, input: input, spawn: spawn, inheritedEnvironment: inheritedEnvironment,
            openShim: openShim, context: context, machineID: machineID)
        launch.ownerIndependent = false; launch.accountHandle = accountHandle; launch.mcpLeaseIDs = leaseIDs
        spawn.beforeExposure?(id)
        let epoch = lock.withLock { () -> UInt64 in owned.insert(id); return epochs[id, default: 0] }
        let result = try client.create(launch)
        return try record(result: result, id: id, epoch: epoch)
    }
    public func createManagedAsync(input: BackendCreateSessionInput, spawn: BackendSpawnSpec,
        inheritedEnvironment: [String: String], openShim: (directory: String, browser: String)?, context: BackendLaunchContext,
        accountHandle: String?, leaseIDs: [UUID], machineID: String) async throws -> BackendSessionMeta {
        guard lock.withLock({ attached && !detached }), input.chat == true || (input.taskID == nil && input.taskProject == nil),
              context.deviceBoundary == nil, context.appFenceID == nil, !context.isAppComposed,
              input.chat == true || (input.originApp == nil && input.originRoutineId == nil && input.originRunId == nil) else { throw BackendHOSTFailure.unavailable }
        let id = UUID().uuidString.lowercased()
        var launch = try BackendHOSTProtocol.Launch(id: id, input: input, spawn: spawn, inheritedEnvironment: inheritedEnvironment,
            openShim: openShim, context: context, machineID: machineID)
        launch.ownerIndependent = false; launch.accountHandle = accountHandle; launch.mcpLeaseIDs = leaseIDs
        spawn.beforeExposure?(id)
        let epoch = lock.withLock { () -> UInt64 in owned.insert(id); return epochs[id, default: 0] }
        let result = try await client.createAsync(launch)
        return try record(result: result, id: id, epoch: epoch)
    }
    #endif
    private func record(result: BackendSessionMeta, id: String, epoch: UInt64) throws -> BackendSessionMeta {
        try lock.withLock {
            guard !removed.contains(id) else { throw BackendSessionFailure.missingSession }
            if epochs[id, default: 0] != epoch {
                if let current = rows[id] { return current }
                guard let code = exited[id] else { throw BackendSessionFailure.missingSession }
                var terminal = result; terminal.exitCode = code
                if !order.contains(id) { order.append(id) }; rows[id] = terminal; return terminal
            }
            if rows[id] == nil { order.append(id) }; rows[id] = result; return result
        }
    }
    public func write(_ id: String, bytes: Data, expectedCreatedAt: Double?) throws { if let peer = peer(id) { try peer.write(id, bytes: bytes, expectedCreatedAt: expectedCreatedAt); return }; try writeInput(id, bytes, expectedCreatedAt) }
    public func writeAsync(_ id: String, bytes: Data, expectedCreatedAt: Double?) async throws {
        if let peer = peer(id) { try await peer.writeAsync(id, bytes: bytes, expectedCreatedAt: expectedCreatedAt); return }
        try await client.writeAsync(id, bytes: bytes, expectedCreatedAt: expectedCreatedAt)
    }
    public func resize(_ id: String, cols: Int, rows: Int) throws {
        if let peer = peer(id) { try peer.resize(id, cols: cols, rows: rows); return }
        defer { lock.withLock { outputGeneration[id, default: 0] &+= 1 } } // a reflow changes the screen without output
        try client.resize(id, cols: cols, rows: rows)
    }
    public func rename(_ id: String, title: String) -> Bool {
        if let peer = peer(id) { return peer.rename(id, title: title) }
        do { return try client.rename(id, title: title) } catch { note(error); return false }
    }
    public func setAccount(_ id: String, account: BackendAccountIdentity, home: String?) -> BackendSessionMeta? {
        if let peer = peer(id) { return peer.setAccount(id, account: account, home: home) }
        do { return try client.setAccount(id, account: account, home: home) } catch { note(error); return nil }
    }
    public func setConversation(_ id: String, conversation: String) {
        if let peer = peer(id) { peer.setConversation(id, conversation: conversation); return }
        do { try client.setConversation(id, conversation: conversation) } catch { note(error) }
    }
    public func remove(_ id: String, reason: BackendRemovalReason) {
        if let peer = peer(id) { peer.remove(id, reason: reason); return }
        do { try client.remove(id, reason: reason) } catch { note(error) }
    }
    public func stopAll() { for peer in lock.withLock({ peers }) { peer.stopAll() }; do { try client.stopAll() } catch { note(error) } }
    public func drain(timeoutMilliseconds: Int) async -> Bool {
        for peer in lock.withLock({ peers }) { if !(await peer.drain(timeoutMilliseconds: timeoutMilliseconds)) { return false } }
        do { return try await waitForDrain(timeoutMilliseconds) } catch { note(error); return false }
    }
    public func setWatched(_ value: Bool) { for peer in lock.withLock({ peers }) { peer.setWatched(value) }; do { try watch(value) } catch { note(error) } }
    public func detach() { let values = lock.withLock { () -> [BackendHOSTManagerBridge] in detached = true; attached = false; return peers }; for peer in values { peer.detach() }; client.detach() }
    public func failureMessages() -> [String] { lock.withLock { failures } }
    private func note(_ error: Error) { lock.withLock { failures.append(error.localizedDescription); if failures.count > 16 { failures.removeFirst() } } }
}
