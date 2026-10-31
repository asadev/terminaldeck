import Foundation
@preconcurrency import Network

public enum BackendServersSetupTunnelResult: Sendable {
    case opened(BackendServersSetupTunnel)
    case taken(String)
    case refused(String)
}

/// Raw OAuth redirect bytes, loopback on both ends at the identical port.
/// Nothing here parses, stores, logs or types an authorization code.
public final class BackendServersSetupTunnel: @unchecked Sendable {
    public let port: Int
    private let lock = NSLock()
    private let listener: NWListener
    private let queue: DispatchQueue
    private var closed = false
    private var carried = false
    private var pipes: [UUID: BackendServersSetupTunnelPipe] = [:]
    private var carrying: [CheckedContinuation<Bool, Never>] = []
    private var closing: [CheckedContinuation<Void, Never>] = []
    private var stopConnectionWatch: (@Sendable () -> Void)?
    private init(port: Int, listener: NWListener, queue: DispatchQueue) { self.port = port; self.listener = listener; self.queue = queue }

    public static func open(port: Int, connection: any BackendServersConnection) async -> BackendServersSetupTunnelResult {
        guard (1...65_535).contains(port), let endpointPort = NWEndpoint.Port(rawValue: UInt16(port)) else { return .refused("The sign-in did not name a usable port.") }
        do {
            let parameters = NWParameters.tcp
            parameters.allowLocalEndpointReuse = false
            parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: endpointPort)
            let listener = try NWListener(using: parameters)
            let queue = DispatchQueue(label: "native.servers.setup-tunnel.\(port)")
            let tunnel = BackendServersSetupTunnel(port: port, listener: listener, queue: queue)
            tunnel.stopConnectionWatch = connection.onClose { [weak tunnel] in tunnel?.close() }
            listener.newConnectionHandler = { [weak tunnel] local in
                guard let tunnel else { local.cancel(); return }
                tunnel.accept(local, connection: connection)
            }
            return await withCheckedContinuation { continuation in
                let once = BackendServersSetupTunnelOpenOnce(continuation)
                listener.stateUpdateHandler = { [weak tunnel] state in
                    switch state {
                    case .ready: if let tunnel { once.finish(.opened(tunnel)) }
                    case .failed(let error):
                        tunnel?.close()
                        if case .posix(.EADDRINUSE) = error { once.finish(.taken("Something on this computer is already using that.")) }
                        else { once.finish(.refused(error.localizedDescription)) }
                    case .cancelled: once.finish(.refused("The sign-in connection closed before the port was ready."))
                    default: break
                    }
                }
                listener.start(queue: queue)
            }
        } catch { return .refused(error.localizedDescription) }
    }

    /// Retains the pool reference until cancellation or connection loss, rather
    /// than returning a listener whose authenticated transport was released.
    public static func open(serverId: String, port: Int, connections: BackendServersConnections) async -> BackendServersSetupTunnelResult {
        await withCheckedContinuation { continuation in
            let once = BackendServersSetupTunnelOpenOnce(continuation)
            Task {
                do {
                    try await connections.withConnection(serverId) { connection in
                        let result = await open(port: port, connection: connection)
                        once.finish(result)
                        if case .opened(let tunnel) = result { await tunnel.waitForClosed() }
                    }
                } catch { once.finish(.refused(error.localizedDescription)) }
            }
        }
    }
    private func accept(_ local: NWConnection, connection: any BackendServersConnection) {
        let permitted = lock.withLock { () -> Bool in
            guard !closed else { return false }; carried = true; return true
        }
        guard permitted else { local.cancel(); return }
        let waiters = lock.withLock { let waiters = carrying; carrying.removeAll(); return waiters }
        for waiter in waiters { waiter.resume(returning: true) }
        let id = UUID()
        Task { [weak self] in
            guard let self else { local.cancel(); return }
            do {
                let channel = try await connection.forward(host: "127.0.0.1", port: self.port)
                let pipe = BackendServersSetupTunnelPipe(local: local, channel: channel, queue: self.queue) { [weak self] in
                    self?.lock.withLock { self?.pipes[id] = nil }
                }
                let kept = self.lock.withLock { () -> Bool in guard !self.closed else { return false }; self.pipes[id] = pipe; return true }
                if kept { pipe.start() } else { pipe.close() }
            } catch { local.cancel() }
        }
    }
    public func waitForCarried() async -> Bool {
        await withCheckedContinuation { continuation in
            let immediate = lock.withLock { () -> Bool? in
                if carried { return true }; if closed { return false }; carrying.append(continuation); return nil
            }
            if let immediate { continuation.resume(returning: immediate) }
        }
    }
    private func waitForClosed() async {
        await withCheckedContinuation { continuation in
            let immediate = lock.withLock { () -> Bool in if closed { return true }; closing.append(continuation); return false }
            if immediate { continuation.resume() }
        }
    }
    public func close() {
        let state = lock.withLock { () -> ([BackendServersSetupTunnelPipe], [CheckedContinuation<Bool, Never>], [CheckedContinuation<Void, Never>], (@Sendable () -> Void)?) in
            guard !closed else { return ([], [], [], nil) }; closed = true
            let state = (Array(pipes.values), carrying, closing, stopConnectionWatch)
            pipes.removeAll(); carrying.removeAll(); closing.removeAll(); stopConnectionWatch = nil; return state
        }
        // Open sockets first: an accepted browser request must not outlive the
        // port or the SSH lease and hang at a half-open endpoint.
        for pipe in state.0 { pipe.close() }; listener.cancel(); state.3?()
        for waiter in state.1 { waiter.resume(returning: false) }; for waiter in state.2 { waiter.resume() }
    }
    deinit { close() }
}

private final class BackendServersSetupTunnelOpenOnce: @unchecked Sendable {
    private let lock = NSLock(); private var continuation: CheckedContinuation<BackendServersSetupTunnelResult, Never>?
    init(_ continuation: CheckedContinuation<BackendServersSetupTunnelResult, Never>) { self.continuation = continuation }
    func finish(_ result: BackendServersSetupTunnelResult) { let old = lock.withLock { let old = continuation; continuation = nil; return old }; old?.resume(returning: result) }
}

private final class BackendServersSetupTunnelPipe: @unchecked Sendable {
    private let local: NWConnection; private let channel: any BackendServersDuplex; private let queue: DispatchQueue
    private let done: @Sendable () -> Void; private let lock = NSLock(); private var closed = false
    private var subscriptions: [@Sendable () -> Void] = []
    init(local: NWConnection, channel: any BackendServersDuplex, queue: DispatchQueue, done: @escaping @Sendable () -> Void) {
        self.local = local; self.channel = channel; self.queue = queue; self.done = done
    }
    func start() {
        subscriptions = [
            channel.onBytes { [weak self] bytes in
                guard let self else { return }; self.channel.pause()
                self.local.send(content: bytes, completion: .contentProcessed { [weak self] error in
                    guard let self else { return }; if error != nil { self.close() } else { self.channel.resume() }
                })
            },
            channel.onEnd { [weak self] in
                self?.local.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { [weak self] error in
                    if error != nil { self?.close() }
                })
            },
            channel.onClose { [weak self] in self?.close() }
        ]
        local.stateUpdateHandler = { [weak self] state in
            switch state { case .ready: self?.receive(); case .failed, .cancelled: self?.close(); default: break }
        }
        local.start(queue: queue)
    }
    private func receive() {
        guard !lock.withLock({ closed }) else { return }
        local.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] bytes, _, ended, error in
            guard let self else { return }
            if error != nil { self.close(); return }
            Task {
                do {
                    if let bytes, !bytes.isEmpty { try await self.channel.write(bytes) }
                    if ended { try await self.channel.end() } else { self.receive() }
                } catch { self.close() }
            }
        }
    }
    func close() {
        let should = lock.withLock { if closed { return false }; closed = true; return true }
        guard should else { return }; local.cancel(); channel.close(); for stop in subscriptions { stop() }; subscriptions.removeAll(); done()
    }
}
