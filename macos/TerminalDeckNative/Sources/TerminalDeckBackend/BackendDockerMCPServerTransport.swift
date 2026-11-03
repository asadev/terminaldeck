import Foundation
import TerminalDeckNativeCore

/// Existing connection implementations without byte-command support refuse;
/// test doubles and alternate transports never fall back to a second SSH stack.
extension BackendServersConnection {
    public func dockerDialStdio() async throws -> any BackendServersDuplex {
        throw NativeRPCError(code: "unavailable", message: "This server connection cannot open Docker's byte transport.")
    }
}

extension BackendServersConnections {
    /// Caddy's administrative API is reachable only on the server's loopback.
    public func caddyAdmin(_ serverID: String) async throws -> any BackendServersDuplex {
        let lease = try await acquireLease(serverID)
        do {
            let channel = try await withConnection(serverID) { try await $0.forward(host: "127.0.0.1", port: 2019) }
            if Task.isCancelled { channel.close(); throw CancellationError() }
            return BackendDockerMCPHeldDuplex(channel) { [weak self] in Task { await self?.release(lease) } }
        } catch {
            release(lease)
            if error is CancellationError { throw error }
            throw NativeRPCError(code: "unavailable", message: "The server's private address-manager connection could not be opened.")
        }
    }
    public func dockerDialStdio(_ serverID: String) async throws -> any BackendServersDuplex {
        let lease = try await acquireLease(serverID)
        do {
            let channel = try await withConnection(serverID) { try await $0.dockerDialStdio() }
            if Task.isCancelled { channel.close(); throw CancellationError() }
            return BackendDockerMCPHeldDuplex(channel) { [weak self] in
                Task { await self?.release(lease) }
            }
        } catch {
            release(lease)
            if error is CancellationError { throw error }
            throw NativeRPCError(code: "unavailable", message: "Docker's server connection could not be opened.")
        }
    }
}

/// Retain the existing server lease only for the request/visible stream.
private final class BackendDockerMCPHeldDuplex: BackendServersDuplex, @unchecked Sendable {
    private let channel: any BackendServersDuplex
    private let lock = NSLock()
    private var release: (@Sendable () -> Void)?
    private var ended: BackendServersUnsubscribe?
    init(_ channel: any BackendServersDuplex, release: @escaping @Sendable () -> Void) {
        self.channel = channel; self.release = release
        ended = channel.onClose { [weak self] in self?.finish() }
    }
    private func finish() {
        let callback = lock.withLock { let old = release; release = nil; return old }
        callback?()
    }
    func onBytes(_ listener: @escaping @Sendable (Data) -> Void) -> BackendServersUnsubscribe { channel.onBytes(listener) }
    func onEnd(_ listener: @escaping @Sendable () -> Void) -> BackendServersUnsubscribe { channel.onEnd(listener) }
    func onClose(_ listener: @escaping @Sendable () -> Void) -> BackendServersUnsubscribe { channel.onClose(listener) }
    func write(_ bytes: Data) async throws { try await channel.write(bytes) }
    func end() async throws { try await channel.end() }
    func pause() { channel.pause() }
    func resume() { channel.resume() }
    func close() { channel.close(); finish() }
    deinit { ended?(); channel.close(); finish() }
}
