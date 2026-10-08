import Foundation
import Darwin
import TerminalDeckNativeCore

public struct BackendDockerRequest: Sendable {
    public let method: String
    public let path: String
    public let headers: [String: String]
    public let body: Data
    public let timeoutMilliseconds: Int?
    public init(method: String = "GET", path: String, headers: [String: String] = [:], body: Data = Data(), timeoutMilliseconds: Int? = nil) {
        self.method = method; self.path = path; self.headers = headers; self.body = body; self.timeoutMilliseconds = timeoutMilliseconds
    }
}
public struct BackendDockerResponse: Sendable {
    public let status: Int
    public let headers: [String: String]
    public let body: Data
    public init(status: Int, headers: [String: String], body: Data) { self.status = status; self.headers = headers; self.body = body }
}
public struct BackendDockerByteStream: Sendable {
    public let status: Int
    public let headers: [String: String]
    public let data: AsyncThrowingStream<Data, Error>
    public let cancel: @Sendable () -> Void
    public init(status: Int, headers: [String: String], data: AsyncThrowingStream<Data, Error>, cancel: @escaping @Sendable () -> Void) {
        self.status = status; self.headers = headers; self.data = data; self.cancel = cancel
    }
}
public struct BackendDockerDuplex: Sendable {
    public let status: Int
    public let headers: [String: String]
    public let incoming: AsyncThrowingStream<Data, Error>
    public let write: @Sendable (Data) async throws -> Void
    public let close: @Sendable () -> Void
    public init(status: Int, headers: [String: String], incoming: AsyncThrowingStream<Data, Error>, write: @escaping @Sendable (Data) async throws -> Void, close: @escaping @Sendable () -> Void) {
        self.status = status; self.headers = headers; self.incoming = incoming; self.write = write; self.close = close
    }
}
public protocol BackendDockerTransport: Sendable {
    func request(_ request: BackendDockerRequest) async throws -> BackendDockerResponse
    func stream(_ request: BackendDockerRequest) async throws -> BackendDockerByteStream
    func hijack(_ request: BackendDockerRequest) async throws -> BackendDockerDuplex
}

/// Continuous streams have no idle timeout: a quiet events view is a valid stream.
/// Finite requests, initial response headers and all writes have deadlines.
public struct BackendDockerTransportLimits: Sendable {
    public var maximumHeaderBytes = 64 * 1024
    public var maximumBodyBytes = 16 * 1024 * 1024
    public var maximumChunkBytes = 16 * 1024 * 1024
    public var maximumBufferedBytes = 1024 * 1024
    public var maximumReadBytes = 64 * 1024
    public var maximumStreamChunks = 16
    public var openTimeoutMilliseconds = 20_000
    public var requestTimeoutMilliseconds = 30_000
    public var writeTimeoutMilliseconds = 30_000
    public init() {}
    func validate() throws {
        guard maximumHeaderBytes >= 128, maximumHeaderBytes <= 1024 * 1024,
              maximumBodyBytes > 0, maximumBodyBytes <= 64 * 1024 * 1024,
              maximumChunkBytes > 0, maximumChunkBytes <= 64 * 1024 * 1024,
              maximumBufferedBytes >= maximumHeaderBytes, maximumBufferedBytes <= 16 * 1024 * 1024,
              maximumReadBytes > 0, maximumReadBytes <= min(maximumBufferedBytes, 64 * 1024),
              (1...256).contains(maximumStreamChunks),
              (1...120_000).contains(openTimeoutMilliseconds), (1...660_000).contains(requestTimeoutMilliseconds),
              (1...300_000).contains(writeTimeoutMilliseconds) else { throw NativeRPCError.invalidArguments("The Docker transport limits are invalid.") }
    }
    func timeout(for request: BackendDockerRequest) throws -> Int {
        let milliseconds = request.timeoutMilliseconds ?? requestTimeoutMilliseconds
        guard (1...660_000).contains(milliseconds) else { throw NativeRPCError.invalidArguments("The Docker request timeout is outside its bounds.") }
        return milliseconds
    }
}

/// The existing authenticated server owner supplies the duplex. There is no
/// SSH login, process, credential or reconnect implementation in this transport.
public struct BackendDockerHTTPTransport: BackendDockerTransport {
    public typealias Opener = @Sendable () async throws -> any BackendServersDuplex
    private let opener: Opener
    private let host: String
    private let limits: BackendDockerTransportLimits
    public init(opener: @escaping Opener, host: String = "docker", limits: BackendDockerTransportLimits = .init()) {
        self.opener = opener; self.host = host; self.limits = limits
    }

    public func request(_ request: BackendDockerRequest) async throws -> BackendDockerResponse {
        let timeout = try limits.timeout(for: request)
        let wire = try BackendDockerHTTP.encode(request, limits: limits, hijack: false, host: host)
        let source = try await open()
        let timer = deadline(source, milliseconds: timeout)
        defer { timer.cancel(); source.close() }
        return try await withTaskCancellationHandler {
            do {
                try await sendRequest(wire, source: source)
                let exchange = BackendDockerHTTPExchange(source: source, limits: limits)
                let (head, _) = try await exchange.readHead(method: request.method, hijack: false)
                var body = Data()
                while let piece = try await exchange.next() {
                    guard piece.count <= limits.maximumBodyBytes - body.count else { throw BackendDockerHTTP.overflow() }
                    body.append(piece)
                }
                try Task.checkCancellation()
                return .init(status: head.status, headers: head.headers, body: body)
            } catch { throw BackendDockerHTTP.safeError(error) }
        } onCancel: { source.close() }
    }

    public func stream(_ request: BackendDockerRequest) async throws -> BackendDockerByteStream {
        let result = try await streaming(request, hijack: false)
        if Task.isCancelled { result.source.close(); throw BackendDockerHTTP.cancelled() }
        return .init(status: result.head.status, headers: result.head.headers, data: result.data, cancel: { result.source.close() })
    }
    public func hijack(_ request: BackendDockerRequest) async throws -> BackendDockerDuplex {
        let result = try await streaming(request, hijack: true)
        if Task.isCancelled { result.source.close(); throw BackendDockerHTTP.cancelled() }
        let maximum = limits.maximumReadBytes
        let writeTimeout = limits.writeTimeoutMilliseconds
        return .init(status: result.head.status, headers: result.head.headers, incoming: result.data, write: { bytes in
            guard result.upgraded else { throw NativeRPCError(code: "unavailable", message: "Docker did not open this terminal connection.") }
            guard bytes.count <= maximum else { throw NativeRPCError.invalidArguments("The Docker terminal input is too large.") }
            let timer = self.deadline(result.source, milliseconds: writeTimeout)
            defer { timer.cancel() }
            do { try await result.source.write(bytes) } catch { throw BackendDockerHTTP.safeError(error) }
        }, close: { result.source.close() })
    }

    private struct BackendDockerHTTPStreaming: Sendable {
        let head: BackendDockerHTTPHead
        let upgraded: Bool
        let data: AsyncThrowingStream<Data, Error>
        let source: BackendDockerHTTPSource
    }
    private func streaming(_ request: BackendDockerRequest, hijack: Bool) async throws -> BackendDockerHTTPStreaming {
        let timeout = try limits.timeout(for: request)
        let wire = try BackendDockerHTTP.encode(request, limits: limits, hijack: hijack, host: host)
        let source = try await open()
        let timer = deadline(source, milliseconds: timeout)
        let exchange = BackendDockerHTTPExchange(source: source, limits: limits)
        let head: BackendDockerHTTPHead, upgraded: Bool
        do {
            (head, upgraded) = try await withTaskCancellationHandler {
                try await sendRequest(wire, source: source)
                let result = try await exchange.readHead(method: request.method, hijack: hijack)
                try Task.checkCancellation(); return result
            } onCancel: { source.close() }
        } catch { timer.cancel(); source.close(); throw BackendDockerHTTP.safeError(error) }
        timer.cancel()
        let (stream, continuation) = AsyncThrowingStream<Data, Error>.makeStream(bufferingPolicy: .bufferingOldest(limits.maximumStreamChunks))
        continuation.onTermination = { _ in source.close() }
        let successful = (200...299).contains(head.status) || upgraded
        let bound = limits.maximumBodyBytes
        // Failed HTTP responses are bounded finite bodies, preserving the status
        // for the typed client without turning server text into an error message.
        let failureTimer = successful ? nil : deadline(source, milliseconds: timeout)
        Task {
            defer { failureTimer?.cancel(); source.close() }
            do {
                var count = 0
                while let piece = try await exchange.next() {
                    if !successful {
                        guard piece.count <= bound - count else { throw BackendDockerHTTP.overflow() }
                        count += piece.count
                    }
                    switch continuation.yield(piece) {
                    case .enqueued: break
                    case .dropped: throw BackendDockerHTTP.overflow()
                    case .terminated: return
                    @unknown default: throw BackendDockerHTTP.overflow()
                    }
                }
                continuation.finish()
            } catch { continuation.finish(throwing: BackendDockerHTTP.safeError(error)) }
        }
        return .init(head: head, upgraded: upgraded, data: stream, source: source)
    }

    private func open() async throws -> BackendDockerHTTPSource {
        if Task.isCancelled { throw BackendDockerHTTP.cancelled() }
        let gate = BackendServersSSHOnce<any BackendServersDuplex>()
        let lifecycle = BackendDockerOpenLifecycle()
        let task = Task {
            do {
                let socket = try await opener()
                if lifecycle.accept(socket) { gate.finish(.success(socket)) }
                else { socket.close() }
            } catch { gate.finish(.failure(BackendDockerHTTP.safeError(error))) }
        }
        let timer = Task {
            do { try await Task.sleep(for: .milliseconds(limits.openTimeoutMilliseconds)) } catch { return }
            lifecycle.close(); task.cancel()
            gate.finish(.failure(NativeRPCError(code: "unavailable", message: "Docker did not open a connection in time.")))
        }
        defer { timer.cancel() }
        let socket = try await withTaskCancellationHandler { try await gate.value() } onCancel: {
            lifecycle.close(); task.cancel(); gate.finish(.failure(BackendDockerHTTP.cancelled()))
        }
        if Task.isCancelled { socket.close(); throw BackendDockerHTTP.cancelled() }
        return BackendDockerHTTPSource(socket: socket, limits: limits)
    }
    private func deadline(_ source: BackendDockerHTTPSource, milliseconds: Int) -> Task<Void, Never> {
        Task {
            do { try await Task.sleep(for: .milliseconds(milliseconds)) } catch { return }
            source.fail(NativeRPCError(code: "unavailable", message: "Docker did not finish the request in time."))
        }
    }
    private func sendRequest(_ bytes: Data, source: BackendDockerHTTPSource) async throws {
        // A long server operation may justify a long response deadline. It
        // does not justify retaining a blocked request writer for that long.
        let timer = deadline(source, milliseconds: limits.writeTimeoutMilliseconds)
        defer { timer.cancel() }
        try await source.write(bytes)
    }
}

public struct BackendDockerSSHTransport: BackendDockerTransport {
    public static let command = "docker system dial-stdio"
    public typealias DialStdioOpener = @Sendable (_ command: String) async throws -> any BackendServersDuplex
    private let http: BackendDockerHTTPTransport
    public init(openDialStdio: @escaping DialStdioOpener, limits: BackendDockerTransportLimits = .init()) {
        http = .init(opener: { try await openDialStdio(Self.command) }, limits: limits)
    }
    public func request(_ request: BackendDockerRequest) async throws -> BackendDockerResponse { try await http.request(request) }
    public func stream(_ request: BackendDockerRequest) async throws -> BackendDockerByteStream { try await http.stream(request) }
    public func hijack(_ request: BackendDockerRequest) async throws -> BackendDockerDuplex { try await http.hijack(request) }
}

/// Only the trusted local target resolver supplies this path. Constructing the
/// transport does not discover, connect to or change Docker.
public struct BackendDockerLocalTransport: BackendDockerTransport {
    private let http: BackendDockerHTTPTransport
    public init(socketPath: String, limits: BackendDockerTransportLimits = .init()) {
        http = .init(opener: {
            try Self.requireSocket(socketPath)
            // Native acquisition and parser delivery are separate limits.
            // Network's Unix endpoint must drain a normal bounded receive batch;
            // HTTPSource.take() still delivers the configured small read pieces.
            let socket = BackendDockerUnixSocket(path: socketPath, maximumReadBytes: min(64 * 1024, limits.maximumBufferedBytes))
            do { try await socket.ready(); return socket } catch { socket.close(); throw error }
        }, limits: limits)
    }
    public func request(_ request: BackendDockerRequest) async throws -> BackendDockerResponse { try await http.request(request) }
    public func stream(_ request: BackendDockerRequest) async throws -> BackendDockerByteStream { try await http.stream(request) }
    public func hijack(_ request: BackendDockerRequest) async throws -> BackendDockerDuplex { try await http.hijack(request) }

    private static func requireSocket(_ path: String) throws {
        guard path.hasPrefix("/"), !path.utf8.contains(0), path.utf8.count < 104 else {
            throw NativeRPCError.invalidArguments("The local Docker socket path is invalid.")
        }
        // This runs only in the request's opener. Follow provider symlinks like
        // discovery does, without changing the path, permissions or contents.
        // Network.framework can otherwise leave an absent Unix endpoint waiting
        // until the generic connection deadline, losing the useful error code.
        var information = stat()
        guard Darwin.fstatat(AT_FDCWD, path, &information, 0) == 0 else {
            switch errno {
            case ENOENT, ENOTDIR:
                throw NativeRPCError(code: "docker-not-found", message: "No local Docker socket was found.")
            case EACCES, EPERM:
                throw NativeRPCError(code: "docker-permission", message: "This account cannot use the local Docker socket.")
            default:
                throw NativeRPCError(code: "unavailable", message: "The local Docker socket could not be checked.")
            }
        }
        guard information.st_mode & mode_t(S_IFMT) == mode_t(S_IFSOCK) else {
            throw NativeRPCError(code: "docker-not-found", message: "No local Docker socket was found.")
        }
    }
}

private final class BackendDockerOpenLifecycle: @unchecked Sendable {
    private let lock = NSLock()
    private var stopped = false
    private var socket: (any BackendServersDuplex)?
    func accept(_ socket: any BackendServersDuplex) -> Bool { lock.withLock { if stopped { return false }; self.socket = socket; return true } }
    func close() { let old = lock.withLock { stopped = true; let old = socket; socket = nil; return old }; old?.close() }
}

/// Callback adapter for the existing server duplex, with real backpressure and
/// one pending read. It does not duplicate a server connection or its identity.
final class BackendDockerHTTPSource: @unchecked Sendable {
    private let socket: any BackendServersDuplex
    private let limits: BackendDockerTransportLimits
    private let lock = NSLock()
    private let flow = DispatchQueue(label: "terminaldeck.native.docker.backpressure")
    private var buffer = Data()
    private var pending: CheckedContinuation<Data?, Error>?
    private var writes: [UUID: BackendServersSSHOnce<Void>] = [:]
    private var error: Error?
    private var readingStarted = false
    private var ended = false
    private var stopped = false
    private var subscriptions: [BackendServersUnsubscribe] = []
    private let trace: BackendDockerTrace?
    func diagnostic(_ phase: String, count: Int = 0) { trace?.emit(phase, count: count) }
    init(socket: any BackendServersDuplex, limits: BackendDockerTransportLimits) {
        self.socket = socket; self.limits = limits
        trace = (socket as? BackendDockerUnixSocket)?.trace
        trace?.emit("source-init")
        socket.pause()
        let listeners = [socket.onBytes { [weak self] in self?.receive($0) }, socket.onEnd { [weak self] in self?.end() }, socket.onClose { [weak self] in self?.closedByPeer() }]
        let keep = lock.withLock { if stopped { return false }; subscriptions = listeners; return true }
        // The initial request must be acknowledged before receiving starts.
        // Keep listeners installed for callback adapters with an existing
        // backlog, but do not arm a fresh Unix receive from construction.
        if !keep { for cancel in listeners { cancel() } }
    }
    func next() async throws -> Data? {
        try Task.checkCancellation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let result = lock.withLock { () -> Result<Data?, Error>? in
                    readingStarted = true
                    trace?.emit("read", count: buffer.count, flag: ended)
                    if !buffer.isEmpty { return .success(take()) }
                    if let error { return .failure(error) }
                    if ended { return .success(nil) }
                    guard pending == nil else { return .failure(BackendDockerHTTP.protocolError("Two readers tried to use the same Docker response.")) }
                    pending = continuation; return nil
                }
                updateFlow()
                if let result { continuation.resume(with: result) }
            }
        } onCancel: { self.close() }
    }
    func write(_ bytes: Data) async throws {
        if Task.isCancelled { close(); throw BackendDockerHTTP.cancelled() }
        let id = UUID(), gate = BackendServersSSHOnce<Void>()
        let rejected = lock.withLock { () -> Error? in
            if let error { return error }
            guard writes.count < 16 else { return BackendDockerHTTP.overflow() }
            writes[id] = gate; return nil
        }
        if let rejected {
            if (rejected as? NativeRPCError)?.code == "docker-stream-overflow" { fail(rejected) }
            throw rejected
        }
        let task = Task {
            do {
                if let stopped = lock.withLock({ self.error }) { throw stopped }
                try Task.checkCancellation()
                try await socket.write(bytes); acknowledgeWrite(gate)
            }
            catch { let failure = BackendDockerHTTP.safeError(error); self.fail(failure); gate.finish(.failure(failure)) }
        }
        var acknowledged = false
        defer {
            if !acknowledged { task.cancel() }
            _ = lock.withLock { writes.removeValue(forKey: id) }
        }
        // A provider must close its own resources, but it cannot keep our caller
        // waiting after a deadline by ignoring cancellation or close().
        try await withTaskCancellationHandler { try await gate.value() } onCancel: { self.close(); task.cancel() }
        try Task.checkCancellation()
        acknowledged = true
    }
    private func acknowledgeWrite(_ gate: BackendServersSSHOnce<Void>) {
        // Failure publishes its state under this same lock. An acknowledgement
        // arriving between that publication and failure's gate delivery must
        // preserve the failure instead of turning a timed-out write into success.
        lock.withLock {
            trace?.emit("write-ack", count: error == nil ? 0 : 1)
            if let error { gate.finish(.failure(error)) }
            else { gate.finish(.success(())) }
        }
    }
    private func receive(_ bytes: Data) {
        if bytes.isEmpty { return }
        var waiter: CheckedContinuation<Data?, Error>?
        var piece: Data?
        var overflow = false
        lock.withLock {
            trace?.emit("data", count: bytes.count, flag: stopped)
            guard !stopped, !ended else { return }
            if bytes.count > limits.maximumBufferedBytes - buffer.count { overflow = true; return }
            buffer.append(bytes)
            if let pending { waiter = pending; self.pending = nil; piece = take() }
        }
        if overflow { fail(BackendDockerHTTP.overflow()); return }
        updateFlow()
        if let waiter { waiter.resume(returning: piece) }
    }
    private func updateFlow() {
        // Decide at delivery time. A reader draining the buffer between a
        // callback and pause must not leave a now-empty connection paused.
        flow.async { [weak self] in
            guard let self else { return }
            let shouldPause = lock.withLock { stopped || !readingStarted || buffer.count >= limits.maximumBufferedBytes / 2 }
            if shouldPause { socket.pause() } else { socket.resume() }
        }
    }
    private func take() -> Data { let piece = Data(buffer.prefix(limits.maximumReadBytes)); buffer = Data(buffer.dropFirst(piece.count)); return piece }
    private func end() {
        trace?.emit("read-end")
        let waiter = lock.withLock { () -> CheckedContinuation<Data?, Error>? in ended = true; if !buffer.isEmpty { return nil }; let old = pending; pending = nil; return old }
        waiter?.resume(returning: nil)
    }
    private func closedByPeer() {
        trace?.emit("peer-close")
        if !lock.withLock({ ended || stopped }) {
            // A peer close can follow bytes already delivered by Network.
            // Let framing consume those bytes before observing the read error.
            // Complete Content-Length/chunked replies remain valid; incomplete
            // or EOF-delimited replies still encounter the error after draining.
            fail(NativeRPCError(code: "unavailable", message: "The Docker connection closed unexpectedly."), preservingReceivedBytes: true)
        }
    }
    func fail(_ failure: Error, preservingReceivedBytes: Bool = false) {
        trace?.emit("source-fail", count: preservingReceivedBytes ? 1 : 0)
        let old = lock.withLock { () -> (Bool, CheckedContinuation<Data?, Error>?, [BackendServersUnsubscribe], [BackendServersSSHOnce<Void>]) in
            guard !stopped else {
                if !preservingReceivedBytes { buffer = Data() }
                return (false, nil, [], [])
            }
            stopped = true; error = failure
            if !preservingReceivedBytes { buffer = Data() }
            let waiter = pending, listeners = subscriptions, writers = Array(writes.values)
            pending = nil; subscriptions = []; writes = [:]; return (true, waiter, listeners, writers)
        }
        guard old.0 else { return }
        // Finish cleanup outside the lock before waking the failed request.
        // Its defer cannot perform this close again once stopped is published.
        for cancel in old.2 { cancel() }
        socket.close()
        old.1?.resume(throwing: failure)
        for writer in old.3 { writer.finish(.failure(failure)) }
    }
    func close() { trace?.emit("owner-close"); fail(BackendDockerHTTP.cancelled()) }
    deinit { for cancel in subscriptions { cancel() }; if !stopped { socket.close() } }
}

/// Opt-in bounded diagnostics. No response/request bytes, paths or error text.
private final class BackendDockerTrace: @unchecked Sendable {
    private let enabled = ProcessInfo.processInfo.environment["DKE_DOCKER_TRACE"] == "1"
    private let id = String(UUID().uuidString.prefix(8))
    private let lock = NSLock()
    private var sequence = 0
    func emit(_ phase: String, count: Int = 0, flag: Bool = false) {
        guard enabled else { return }
        lock.withLock {
            guard sequence < 48 else { return }; sequence += 1
            FileHandle.standardError.write(Data("DKE-TRACE \(id) \(sequence) \(phase) n=\(count) flag=\(flag)\n".utf8))
        }
    }
}

private final class BackendDockerUnixSocket: BackendServersDuplex, @unchecked Sendable {
    let trace = BackendDockerTrace()
    private let descriptor: Int32
    private let queue = DispatchQueue(label: "terminaldeck.native.docker.unix", qos: .userInitiated)
    private let readiness = BackendServersSSHOnce<Void>()
    private let bytes = BackendServersSSHEvents<Data>()
    private let ending = BackendServersSSHEvents<Bool>(replayLatest: true)
    private let closing = BackendServersSSHEvents<Bool>(replayLatest: true)
    private let maximumReadBytes: Int
    private var reader: DispatchSourceRead?
    private var writer: DispatchSourceWrite?
    // All lifecycle and descriptor operations are serialized on queue.
    private var stopped = false
    private var connected = false
    private var connecting = false
    private var readSuspended = true
    private var writeSuspended = true
    private var readEnded = false
    private var writeEnded = false
    private struct PendingWrite {
        let data: Data?
        var offset = 0
        let continuation: CheckedContinuation<Void, Error>
    }
    private var pendingWrites: [PendingWrite] = []
    init(path: String, maximumReadBytes: Int) {
        self.maximumReadBytes = maximumReadBytes
        descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            readiness.finish(.failure(Self.problem(errno))); stopped = true; return
        }
        let fd = descriptor
        let readSource = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        let writeSource = DispatchSource.makeWriteSource(fileDescriptor: fd, queue: queue)
        reader = readSource; writer = writeSource
        readSource.setEventHandler { [weak self] in self?.receive() }
        writeSource.setEventHandler { [weak self] in self?.writable() }
        readSource.setCancelHandler { Darwin.close(fd) }
        var yes: Int32 = 1
        guard Darwin.setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout<Int32>.size)) == 0,
              Darwin.fcntl(fd, F_SETFL, O_NONBLOCK) == 0,
              Darwin.fcntl(fd, F_SETFD, FD_CLOEXEC) == 0 else {
            let code = errno; queue.async { [self] in terminate(code) }; return
        }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let pathBytes = Array(path.utf8) + [UInt8(0)]
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: pathBytes) }
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if result == 0 {
            connected = true; trace.emit("ready"); readiness.finish(.success(()))
        } else {
            let code = errno
            if code == EINPROGRESS || code == EAGAIN || code == EALREADY {
                connecting = true; writeSuspended = false; writeSource.resume()
            } else { queue.async { [self] in terminate(code) } }
        }
    }
    func ready() async throws { try await withTaskCancellationHandler { try await readiness.value() } onCancel: { self.close() } }
    func onBytes(_ listener: @escaping @Sendable (Data) -> Void) -> BackendServersUnsubscribe { bytes.listen(listener) }
    func onEnd(_ listener: @escaping @Sendable () -> Void) -> BackendServersUnsubscribe { ending.listen { _ in listener() } }
    func onClose(_ listener: @escaping @Sendable () -> Void) -> BackendServersUnsubscribe { closing.listen { _ in listener() } }
    func pause() { queue.async { [self] in
        if !stopped && !readSuspended { readSuspended = true; reader?.suspend() }
    } }
    func resume() { queue.async { [self] in
        if !stopped && connected && !readEnded && readSuspended { readSuspended = false; reader?.resume() }
    } }
    private func receive() {
        guard !stopped, connected, !readSuspended, !readEnded else { return }
        var buffer = [UInt8](repeating: 0, count: maximumReadBytes)
        let count = buffer.withUnsafeMutableBytes { Darwin.recv(descriptor, $0.baseAddress, $0.count, 0) }
        if count > 0 {
            trace.emit("native-read", count: count); bytes.send(Data(buffer.prefix(count)))
        } else if count == 0 {
            readEnded = true; readSuspended = true; reader?.suspend()
            trace.emit("native-read", flag: true); ending.send(true)
        } else {
            let code = errno
            if code != EAGAIN && code != EWOULDBLOCK && code != EINTR { terminate(code) }
        }
    }
    func write(_ data: Data) async throws {
        try await enqueue(data)
    }
    private func enqueue(_ data: Data?) async throws {
        try Task.checkCancellation()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                queue.async { [self] in
                    guard !stopped, connected, !writeEnded else { continuation.resume(throwing: BackendDockerHTTP.cancelled()); return }
                    guard pendingWrites.count < 16 else { continuation.resume(throwing: BackendDockerHTTP.overflow()); return }
                    if data == nil { writeEnded = true }
                    trace.emit("native-send", count: data?.count ?? 0)
                    pendingWrites.append(PendingWrite(data: data, continuation: continuation))
                    drainWrites()
                }
            }
        } onCancel: { self.close() }
    }
    func end() async throws { try await enqueue(nil) }
    private func writable() {
        guard !stopped else { return }
        if connecting {
            var code: Int32 = 0, length = socklen_t(MemoryLayout<Int32>.size)
            guard Darwin.getsockopt(descriptor, SOL_SOCKET, SO_ERROR, &code, &length) == 0 else { terminate(errno); return }
            guard code == 0 else { terminate(code); return }
            connecting = false; connected = true; trace.emit("ready"); readiness.finish(.success(()))
        }
        drainWrites()
    }
    private func drainWrites() {
        guard !stopped, connected else { return }
        while let first = pendingWrites.first {
            if let data = first.data, first.offset < data.count {
                let count = data.withUnsafeBytes { Darwin.send(descriptor, $0.baseAddress!.advanced(by: first.offset), data.count - first.offset, 0) }
                if count > 0 { pendingWrites[0].offset += count; continue }
                let code = errno
                if count < 0 && code == EINTR { continue }
                if count < 0 && (code == EAGAIN || code == EWOULDBLOCK) {
                    if writeSuspended { writeSuspended = false; writer?.resume() }; return
                }
                terminate(count == 0 ? EPIPE : code); return
            }
            if first.data == nil, Darwin.shutdown(descriptor, SHUT_WR) != 0 { terminate(errno); return }
            pendingWrites.removeFirst(); trace.emit("send-ack"); first.continuation.resume()
        }
        if !writeSuspended { writeSuspended = true; writer?.suspend() }
    }
    private static func problem(_ code: Int32) -> NativeRPCError {
        let kind: String
        switch code {
        case ENOENT, ENOTDIR, ECONNREFUSED: kind = "docker-not-found"
        case EACCES, EPERM: kind = "docker-permission"
        default: kind = "unavailable"
        }
        return NativeRPCError(code: kind, message: "The local Docker socket operation could not complete.")
    }
    private func terminate(_ code: Int32) {
        trace.emit("native-error-posix", count: Int(code))
        let failure = Self.problem(code); readiness.finish(.failure(failure)); closeOnQueue(failure)
    }
    func close() { queue.async { [self] in closeOnQueue(BackendDockerHTTP.cancelled()) } }
    private func closeOnQueue(_ failure: Error) {
        guard !stopped else { return }; stopped = true; trace.emit("native-close")
        readiness.finish(.failure(failure))
        let old = pendingWrites; pendingWrites = []
        for write in old { write.continuation.resume(throwing: failure) }
        if readSuspended { readSuspended = false; reader?.resume() }
        if writeSuspended { writeSuspended = false; writer?.resume() }
        writer?.cancel(); reader?.cancel()
        bytes.stop(); closing.send(true)
    }
    deinit {
        if readSuspended { reader?.resume() }
        if writeSuspended { writer?.resume() }
        writer?.cancel(); reader?.cancel()
        if reader == nil && descriptor >= 0 { Darwin.close(descriptor) }
    }
}
