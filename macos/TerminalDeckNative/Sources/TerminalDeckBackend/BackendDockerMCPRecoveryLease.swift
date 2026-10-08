import Foundation
import TerminalDeckNativeCore

/// Transport lifetime only, never permission. The trusted issuer checks the
/// actual accepted write receipt BEFORE acquire and exposes this object only to
/// sealed recovery plans. This actor never re-resolves caller authority.
public actor BackendDockerMCPRecoveryLease {
    private let pool: BackendServersConnections
    private let room: BackendServersCoordinator
    private let pin: BackendServersConnectionLease
    private let serverLifetime: UInt64
    private let connection: any BackendServersConnection
    private let deadline: Double
    private let monotonic: @Sendable () -> Double
    private let dropped = BackendDockerMCPRecoveryDropped()
    private var closed = false
    private var connectionObserver: BackendServersUnsubscribe?
    private var channels: [UUID: BackendDockerMCPRecoveryByteChannel] = [:]
    private var opens: [UUID: Task<any BackendServersDuplex, Error>] = [:]
    private var commands: [UUID: Task<BackendServersRunResult, Error>] = [:]

    private init(pool: BackendServersConnections, room: BackendServersCoordinator,
                 pin: BackendServersConnectionLease, lifetime: UInt64,
                 connection: any BackendServersConnection, deadline: Double,
                 monotonic: @escaping @Sendable () -> Double) {
        self.pool = pool; self.room = room; self.pin = pin; serverLifetime = lifetime
        self.connection = connection; self.deadline = deadline; self.monotonic = monotonic
    }

    public static func acquire(servers: BackendServersFeature, serverID: String,
                               lifetimeSeconds: Double) async throws -> BackendDockerMCPRecoveryLease {
        try await acquire(pool: servers.connections, room: servers.room, serverID: serverID,
                          lifetimeSeconds: lifetimeSeconds, monotonic: { ProcessInfo.processInfo.systemUptime })
    }

    /// Same real pool/room seam, with an injected monotonic clock for tests.
    static func acquire(pool: BackendServersConnections, room: BackendServersCoordinator,
                        serverID: String, lifetimeSeconds: Double,
                        monotonic: @escaping @Sendable () -> Double) async throws -> BackendDockerMCPRecoveryLease {
        try Task.checkCancellation()
        let start = monotonic()
        guard !serverID.isEmpty, serverID != "local", !serverID.contains("\0"),
              lifetimeSeconds.isFinite, (1...3900).contains(lifetimeSeconds), start.isFinite,
              (start + lifetimeSeconds).isFinite else { throw unavailable("The recovery transport lifetime is invalid.") }
        let lifetime = room.serverLifetime(serverID)
        try await room.requireLiveServer(serverID, lifetime: lifetime)
        let pin = try await pool.acquireLease(serverID)
        var transferred = false
        do {
            guard await pool.isCurrent(pin) else { throw unavailable("The recovery server connection changed while being captured.") }
            let connection = try await pool.withConnection(pin) { $0 }
            guard await pool.isCurrent(pin) else { throw unavailable("The recovery server connection changed while being captured.") }
            try await room.requireLiveServer(serverID, lifetime: lifetime)
            try Task.checkCancellation()
            let owner = BackendDockerMCPRecoveryLease(pool: pool, room: room, pin: pin, lifetime: lifetime,
                connection: connection, deadline: start + lifetimeSeconds, monotonic: monotonic)
            transferred = true
            await owner.observeConnectionClose()
            do { try await owner.requireCurrent() }
            catch { await owner.close(); throw error }
            return owner
        } catch {
            if !transferred { await pool.release(pin) }
            if error is CancellationError { throw error }
            throw unavailable("The pinned recovery server connection is unavailable.")
        }
    }

    private func observeConnectionClose() {
        let dropped = self.dropped
        connectionObserver = connection.onClose { [weak self] in
            dropped.mark()
            Task { await self?.close() }
        }
    }

    public func requireCurrent() async throws {
        try Task.checkCancellation()
        guard locallyCurrent else { await close(); throw Self.unavailable("The pinned recovery transport has expired or closed.") }
        do {
            try await room.requireLiveServer(pin.serverID, lifetime: serverLifetime)
            guard await pool.isCurrent(pin) else { throw Self.unavailable("The recovery connection generation is no longer current.") }
        } catch {
            await close()
            if Task.isCancelled { throw CancellationError() }
            throw Self.unavailable("The captured server was forgotten, stopped or replaced. Recovery cannot reconnect.")
        }
        try Task.checkCancellation()
        guard locallyCurrent else { await close(); throw Self.unavailable("The pinned recovery transport has expired or closed.") }
    }

    private var locallyCurrent: Bool {
        let now = monotonic()
        return !closed && !dropped.isDropped && now.isFinite && now < deadline
    }
    fileprivate func bounded(_ request: BackendDockerRequest) async throws -> BackendDockerRequest {
        try await requireCurrent()
        let remainingSeconds = deadline - monotonic()
        guard remainingSeconds.isFinite, remainingSeconds > 0 else {
            await close(); throw Self.unavailable("The pinned recovery transport has expired.")
        }
        let remaining = Int(min(3_900_000, max(1, (remainingSeconds * 1000).rounded(.down))))
        return .init(method: request.method, path: request.path, headers: request.headers, body: request.body,
                     timeoutMilliseconds: min(request.timeoutMilliseconds ?? BackendServersConnections.commandTimeoutMilliseconds, remaining))
    }

    public func execute(command: String, stdin: Data?, timeoutMilliseconds: Int,
                        maximumOutputBytes: Int) async throws -> BackendServersRunResult {
        guard !command.isEmpty, !command.contains("\0"), timeoutMilliseconds > 0,
              maximumOutputBytes > 0, maximumOutputBytes <= BackendServersConnections.maximumOutputBytes,
              (stdin?.count ?? 0) <= BackendServersConnections.maximumOutputBytes else {
            throw NativeRPCError.invalidArguments("The recovery command bounds are invalid.")
        }
        try await requireCurrent()
        let remainingSeconds = deadline - monotonic()
        guard remainingSeconds.isFinite, remainingSeconds > 0 else {
            await close(); throw Self.unavailable("The pinned recovery transport has expired.")
        }
        let remaining = Int(min(3_900_000, max(1, (remainingSeconds * 1000).rounded(.down))))
        let connection = self.connection
        let id = UUID()
        let work = Task {
            try Task.checkCancellation()
            return try await connection.exec(command: command, stdin: stdin,
                timeoutMilliseconds: min(timeoutMilliseconds, remaining), maximumOutputBytes: maximumOutputBytes)
        }
        commands[id] = work
        defer { commands[id] = nil }
        do {
            let result = try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
            try await requireCurrent()
            return result
        } catch {
            work.cancel()
            if error is CancellationError || Task.isCancelled { throw CancellationError() }
            throw Self.unavailable("The pinned recovery command could not complete.")
        }
    }

    public nonisolated func dockerTransport() -> any BackendDockerTransport {
        let transport = BackendDockerSSHTransport(openDialStdio: { [weak self] command in
            guard command == BackendDockerSSHTransport.command, let self else { throw Self.unavailable("The recovery Docker byte connection is unavailable.") }
            return try await self.openByteChannel(caddy: false)
        })
        return BackendDockerMCPRecoveryCheckedTransport(lease: self, transport: transport)
    }
    public nonisolated func caddyTransport() -> any BackendDockerTransport {
        let transport = BackendDockerHTTPTransport(opener: { [weak self] in
            guard let self else { throw Self.unavailable("The recovery private address connection is unavailable.") }
            return try await self.openByteChannel(caddy: true)
        }, host: "127.0.0.1:2019")
        return BackendDockerMCPRecoveryCheckedTransport(lease: self, transport: transport)
    }

    private func openByteChannel(caddy: Bool) async throws -> any BackendServersDuplex {
        try await requireCurrent()
        let connection = self.connection, id = UUID()
        let work = Task<any BackendServersDuplex, Error> {
            try Task.checkCancellation()
            if caddy { return try await connection.forward(host: "127.0.0.1", port: 2019) }
            return try await connection.dockerDialStdio()
        }
        opens[id] = work
        defer { opens[id] = nil }
        let raw: any BackendServersDuplex
        do { raw = try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() } }
        catch {
            work.cancel()
            if error is CancellationError || Task.isCancelled { throw CancellationError() }
            throw Self.unavailable("The pinned recovery byte channel could not open.")
        }
        do { try await requireCurrent() }
        catch { raw.close(); throw error }
        let channel = BackendDockerMCPRecoveryByteChannel(raw) { [weak self] in Task { await self?.removeChannel(id) } }
        channels[id] = channel
        if channel.isClosed { channels[id] = nil; throw Self.unavailable("The recovery byte channel closed before it could be used.") }
        return channel
    }
    private func removeChannel(_ id: UUID) { channels[id] = nil }

    public func close() async {
        guard !closed else { return }
        closed = true
        let observer = connectionObserver; connectionObserver = nil; observer?()
        let commands = Array(self.commands.values), opens = Array(self.opens.values), channels = Array(self.channels.values)
        self.commands.removeAll(); self.opens.removeAll(); self.channels.removeAll()
        for work in commands { work.cancel() }
        for work in opens { work.cancel() }
        for channel in channels { channel.close() }
        // Release only this reference. The pool owns master teardown when the
        // last reference goes away; another caller's lease remains untouched.
        await pool.release(pin)
    }

    private nonisolated static func unavailable(_ message: String) -> NativeRPCError { .init(code: "unavailable", message: message) }

    deinit {
        connectionObserver?()
        for work in commands.values { work.cancel() }
        for work in opens.values { work.cancel() }
        for channel in channels.values { channel.close() }
        if !closed {
            let ownerPool = self.pool, heldPin = self.pin
            Task { await ownerPool.release(heldPin) }
        }
    }
}

private struct BackendDockerMCPRecoveryCheckedTransport: BackendDockerTransport, Sendable {
    let lease: BackendDockerMCPRecoveryLease
    let transport: any BackendDockerTransport
    func request(_ request: BackendDockerRequest) async throws -> BackendDockerResponse {
        let bounded = try await lease.bounded(request)
        let result = try await transport.request(bounded)
        try await lease.requireCurrent()
        return result
    }
    func stream(_ request: BackendDockerRequest) async throws -> BackendDockerByteStream {
        throw NativeRPCError(code: "unavailable", message: "Recovery uses finite requests; live streams are not part of its sealed plans.")
    }
    func hijack(_ request: BackendDockerRequest) async throws -> BackendDockerDuplex {
        throw NativeRPCError(code: "unavailable", message: "Container terminals are not part of sealed recovery plans.")
    }
}

private final class BackendDockerMCPRecoveryDropped: @unchecked Sendable {
    private let lock = NSLock(); private var gone = false
    var isDropped: Bool { lock.withLock { gone } }
    func mark() { lock.withLock { gone = true } }
}

/// Owns this child only; no method can close the shared authenticated master.
private final class BackendDockerMCPRecoveryByteChannel: BackendServersDuplex, @unchecked Sendable {
    private let raw: any BackendServersDuplex
    private let lock = NSLock()
    private var ended = false
    private var observer: BackendServersUnsubscribe?
    private var didClose: (@Sendable () -> Void)?
    init(_ raw: any BackendServersDuplex, didClose: @escaping @Sendable () -> Void) {
        self.raw = raw; self.didClose = didClose
        let subscription = raw.onClose { [weak self] in self?.finish(closeRaw: false) }
        let endedDuringSubscribe = lock.withLock { if ended { return true }; observer = subscription; return false }
        if endedDuringSubscribe { subscription() }
    }
    var isClosed: Bool { lock.withLock { ended } }
    private func finish(closeRaw: Bool) {
        let callbacks = lock.withLock { () -> (Bool, BackendServersUnsubscribe?, (@Sendable () -> Void)?) in
            guard !ended else { return (false, nil, nil) }; ended = true
            let result = (true, observer, didClose); observer = nil; didClose = nil; return result
        }
        guard callbacks.0 else { return }
        if closeRaw { raw.close() }
        callbacks.1?(); callbacks.2?()
    }
    func onBytes(_ listener: @escaping @Sendable (Data) -> Void) -> BackendServersUnsubscribe { raw.onBytes(listener) }
    func onEnd(_ listener: @escaping @Sendable () -> Void) -> BackendServersUnsubscribe { raw.onEnd(listener) }
    func onClose(_ listener: @escaping @Sendable () -> Void) -> BackendServersUnsubscribe { raw.onClose(listener) }
    func write(_ bytes: Data) async throws { guard !isClosed else { throw CancellationError() }; try await raw.write(bytes) }
    func end() async throws { guard !isClosed else { throw CancellationError() }; try await raw.end() }
    func pause() { raw.pause() }
    func resume() { raw.resume() }
    func close() { finish(closeRaw: true) }
    deinit { finish(closeRaw: true) }
}
