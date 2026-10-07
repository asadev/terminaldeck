import Foundation
@preconcurrency import Network
import TerminalDeckNativeCore

/// Before activate, every incoming socket is rejected. This private sink is
/// unique to one remote lease, so no port or identity from another lease can be
/// routed into its endpoint. window-reach owns the bind-proof and activation.
final class BackendServersSSHReverseLease: BackendServersReverseForward, @unchecked Sendable {
    typealias Command = @Sendable (String, String) async throws -> BackendServersRunResult
    private let lock = NSLock(), queue = DispatchQueue(label: "native.servers.reverse", qos: .userInitiated)
    private let listener: NWListener, command: Command
    private let closed = BackendServersSSHEvents<Bool>(retainBeforeSubscription: true, replayLatest: true)
    private var target: BackendServersReverseTarget?, stopped = false, specification = "", remotePort = 0
    private var streams: [UUID: (NWConnection, NWConnection)] = [:]
    var port: Int { lock.withLock { remotePort } }
    private init(listener: NWListener, command: @escaping Command) { self.listener = listener; self.command = command }
    static func prepare(requestedPort: Int, command: @escaping Command) async throws -> BackendServersSSHReverseLease {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        let listener = try NWListener(using: parameters), service = BackendServersSSHReverseLease(listener: listener, command: command)
        let ready = BackendServersSSHOnce<UInt16>()
        listener.newConnectionHandler = { [weak service] in service?.accepted($0) }
        listener.stateUpdateHandler = { state in switch state { case .ready: if let port = listener.port?.rawValue { ready.finish(.success(port)) }; case .failed(let error): ready.finish(.failure(error)); case .cancelled: ready.finish(.failure(CancellationError())); default: break } }
        listener.start(queue: service.queue)
        let deadline = Task { do { try await Task.sleep(for: .milliseconds(5000)); ready.finish(.failure(NativeRPCError(code: "unavailable", message: "The private reverse endpoint did not bind in time."))); listener.cancel() } catch {} }
        defer { deadline.cancel() }
        do {
            let local = try await withTaskCancellationHandler { try await ready.value() } onCancel: { listener.cancel() }
            let specification = "127.0.0.1:\(requestedPort):127.0.0.1:\(local)"
            let answer = try await command("forward", specification)
            guard answer.code == 0 else { throw BackendServersProblem("not-allowed", "This server would not open a path back to this computer.") }
            let allocated = requestedPort == 0 ? Int(answer.stdout.trimmingCharacters(in: .whitespacesAndNewlines)) : requestedPort
            guard let allocated, (1...65535).contains(allocated) else { throw NativeRPCError(code: "unavailable", message: "The server did not name the reverse endpoint it opened.") }
            service.lock.withLock { service.remotePort = allocated; service.specification = "127.0.0.1:\(allocated):127.0.0.1:\(local)" }
            try Task.checkCancellation(); return service
        } catch { service.close(); throw error }
    }
    func activate(target: BackendServersReverseTarget) async throws {
        switch target {
        case .tcp(let host, let port): guard ["127.0.0.1", "::1"].contains(host), (1...65535).contains(port) else { throw NativeRPCError.invalidArguments("The local endpoint must be loopback.") }
        case .unix(let path): guard path.hasPrefix("/"), !path.contains("\0") else { throw NativeRPCError.invalidArguments("The local hook endpoint needs an absolute socket path.") }
        }
        try lock.withLock { guard !stopped, remotePort > 0 else { throw CancellationError() }; self.target = target }
    }
    private func accepted(_ incoming: NWConnection) {
        let selected: BackendServersReverseTarget? = lock.withLock { !stopped && streams.count < 16 ? target : nil }
        guard let selected else { incoming.cancel(); return }
        let outgoing: NWConnection
        switch selected {
        case .tcp(let host, let port): outgoing = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: UInt16(port))!, using: .tcp)
        case .unix(let path): outgoing = NWConnection(to: .unix(path: path), using: .tcp)
        }
        let id = UUID(), added = lock.withLock { if stopped || streams.count >= 16 || target == nil { return false }; streams[id] = (incoming, outgoing); return true }
        guard added else { incoming.cancel(); outgoing.cancel(); return }
        incoming.start(queue: queue)
        Task { [weak self] in guard let self else { return }; do { try await Self.ready(outgoing, queue: queue); async let toLocal: Void = Self.pump(incoming, into: outgoing); async let toRemote: Void = Self.pump(outgoing, into: incoming); _ = try await (toLocal, toRemote) } catch {}; drop(id) }
    }
    private func drop(_ id: UUID) { let pair = lock.withLock { streams.removeValue(forKey: id) }; pair?.0.cancel(); pair?.1.cancel() }
    func onClose(_ callback: @escaping @Sendable () -> Void) -> BackendServersUnsubscribe { closed.listen { _ in callback() } }
    func close() {
        let old = lock.withLock { () -> ([(NWConnection, NWConnection)], String, Bool) in guard !stopped else { return ([], "", false) }; stopped = true; target = nil; let previous = Array(streams.values); streams = [:]; return (previous, specification, true) }
        guard old.2 else { return }; listener.cancel(); for pair in old.0 { pair.0.cancel(); pair.1.cancel() }; closed.send(true)
        if !old.1.isEmpty { let command = command, specification = old.1; Task { _ = try? await command("cancel", specification) } }
    }
    static func pump(_ input: NWConnection, into output: NWConnection) async throws {
        while true {
            let part: (Data, Bool) = try await withCheckedThrowingContinuation { continuation in
                input.receive(minimumIncompleteLength: 1, maximumLength: 24576) { bytes, _, complete, error in if let error { continuation.resume(throwing: error) } else { continuation.resume(returning: (bytes ?? Data(), complete)) } }
            }
            if !part.0.isEmpty { try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in output.send(content: part.0, completion: .contentProcessed { error in if let error { continuation.resume(throwing: error) } else { continuation.resume() } }) } }
            if part.1 { try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in output.send(content: nil, isComplete: true, completion: .contentProcessed { error in if let error { continuation.resume(throwing: error) } else { continuation.resume() } }) }; return }
        }
    }
    static func ready(_ connection: NWConnection, queue: DispatchQueue) async throws {
        let gate = BackendServersSSHOnce<Bool>()
        connection.stateUpdateHandler = { state in switch state { case .ready: gate.finish(.success(true)); case .failed(let error): gate.finish(.failure(error)); case .cancelled: gate.finish(.failure(CancellationError())); default: break } }
        connection.start(queue: queue)
        let deadline = Task { do { try await Task.sleep(for: .milliseconds(5000)); gate.finish(.failure(CancellationError())); connection.cancel() } catch {} }; defer { deadline.cancel() }
        _ = try await withTaskCancellationHandler { try await gate.value() } onCancel: { connection.cancel(); gate.finish(.failure(CancellationError())) }
    }
    deinit { close() }
}
