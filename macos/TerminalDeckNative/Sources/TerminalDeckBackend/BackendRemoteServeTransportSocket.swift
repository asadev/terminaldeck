import Foundation
@preconcurrency import Network
import TerminalDeckNativeCore

/// The host chooses a literal from a fresh scan. Network input never supplies a host.
public enum BackendRemoteServeTransportLoopback: String, Sendable, Hashable {
    case ipv4 = "127.0.0.1", ipv6 = "::1"
    public static func candidates(ipv4: Bool?, ipv6: Bool?) -> [Self] {
        guard let ipv4, let ipv6 else { return [.ipv4, .ipv6] }
        if ipv4 && ipv6 { return [.ipv4, .ipv6] }
        return ipv6 ? [.ipv6] : [.ipv4]
    }
}

public struct BackendRemoteServeTransportRead: Sendable {
    public let data: Data
    public let ended: Bool
    public init(data: Data, ended: Bool = false) { self.data = data; self.ended = ended }
}

/// A write completes only when the socket accepted the bytes. Flushing sends all
/// queued writes before FIN; cancelling a tunnel discards them immediately.
public protocol BackendRemoteServeTransportSocket: Sendable {
    func ready(timeoutMilliseconds: Int) async throws
    func read(maximumBytes: Int) async throws -> BackendRemoteServeTransportRead
    func write(_ bytes: Data) async throws
    func flushAndClose(lingerMilliseconds: Int) async
    func discard()
}
public protocol BackendRemoteServeTransportSocketFactory: Sendable {
    func probe(port: Int, host: BackendRemoteServeTransportLoopback, timeoutMilliseconds: Int) async -> Bool
    func connect(port: Int, host: BackendRemoteServeTransportLoopback) throws -> any BackendRemoteServeTransportSocket
}

public struct BackendRemoteServeTransportTCPFactory: BackendRemoteServeTransportSocketFactory {
    public init() {}
    public func probe(port: Int, host: BackendRemoteServeTransportLoopback, timeoutMilliseconds: Int) async -> Bool {
        await BackendDevDialer.dial(port: port, host: host.rawValue, timeoutMilliseconds: timeoutMilliseconds)
    }
    public func connect(port: Int, host: BackendRemoteServeTransportLoopback) throws -> any BackendRemoteServeTransportSocket {
        guard (1...65_535).contains(port), let endpoint = NWEndpoint.Port(rawValue: UInt16(port)) else {
            throw NativeRPCError.invalidArguments("The tunnel port is invalid")
        }
        return BackendRemoteServeTransportTCPSocket(host: host, port: endpoint)
    }
}

private final class BackendRemoteServeTransportTCPSocket: BackendRemoteServeTransportSocket, @unchecked Sendable {
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "terminaldeck.native.remote.host-tunnel", qos: .userInitiated)
    private let readiness = BackendRemoteServeTransportGate<Void>()
    private let ended = BackendRemoteServeTransportGate<Void>()
    init(host: BackendRemoteServeTransportLoopback, port: NWEndpoint.Port) {
        let options = NWProtocolTCP.Options()
        options.noDelay = true
        connection = NWConnection(host: host == .ipv6 ? .ipv6(.loopback) : .ipv4(.loopback), port: port,
                                  using: NWParameters(tls: nil, tcp: options))
        connection.stateUpdateHandler = { [readiness, ended] state in
            switch state {
            case .ready: readiness.finish(.success(()))
            case .failed(let error): readiness.finish(.failure(error)); ended.finish(.success(()))
            case .cancelled: readiness.finish(.failure(CancellationError())); ended.finish(.success(()))
            default: break
            }
        }
        connection.start(queue: queue)
    }
    func ready(timeoutMilliseconds: Int) async throws {
        let timer = Task { [connection, readiness] in
            do { try await Task.sleep(for: .milliseconds(max(1, timeoutMilliseconds))) }
            catch { return }
            if readiness.finish(.failure(NativeRPCError(code: "tunnel-dial", message: "The loopback dial timed out"))) { connection.cancel() }
        }
        defer { timer.cancel() }
        try await readiness.wait()
    }
    func read(maximumBytes: Int) async throws -> BackendRemoteServeTransportRead {
        // Do not cancel the connection when the read task is cancelled: a
        // half-close still owes the peer its queued writes. The close owns it.
        try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: maximumBytes) { [ended] data, _, complete, error in
                if complete || error != nil { ended.finish(.success(())) }
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume(returning: .init(data: data ?? Data(), ended: complete)) }
            }
        }
    }
    func write(_ bytes: Data) async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                connection.send(content: bytes, completion: .contentProcessed { error in
                    if let error { continuation.resume(throwing: error) } else { continuation.resume() }
                })
            }
        } onCancel: { self.discard() }
    }
    func flushAndClose(lingerMilliseconds: Int) async {
        let accepted = BackendRemoteServeTransportGate<Void>()
        let timer = Task { [connection, ended, accepted] in
            do { try await Task.sleep(for: .milliseconds(max(1, lingerMilliseconds))) } catch { return }
            ended.finish(.success(())); accepted.finish(.success(())); connection.cancel()
        }
        // Queuing a FIN is not proof the peer received the response. Leave the
        // socket alive until peer EOF/closure, or the source five-second cap.
        connection.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { [ended, accepted] error in if error != nil { ended.finish(.success(())) }; accepted.finish(.success(())) })
        _ = try? await accepted.wait()
        _ = try? await ended.wait()
        timer.cancel(); connection.cancel()
    }
    func discard() { ended.finish(.success(())); connection.cancel() }
    deinit { connection.cancel() }
}

/// One completion for readiness/linger, including callbacks arriving before wait.
private final class BackendRemoteServeTransportGate<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<Value, Error>?
    private var continuation: CheckedContinuation<Value, Error>?
    @discardableResult func finish(_ value: Result<Value, Error>) -> Bool {
        lock.lock()
        guard result == nil else { lock.unlock(); return false }
        result = value; let pending = continuation; continuation = nil; lock.unlock()
        pending?.resume(with: value); return true
    }
    func wait() async throws -> Value {
        try Task.checkCancellation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { pending in
                lock.lock()
                if let result { lock.unlock(); pending.resume(with: result) }
                else { continuation = pending; lock.unlock() }
            }
        } onCancel: { self.finish(.failure(CancellationError())) }
    }
}
