import Foundation
import Dispatch
import Darwin
import Security
import TerminalDeckNativeCore

public struct BackendAppDeviceEngineError: Error, LocalizedError, Sendable {
    public let message: String
    public let code: String
    public let recoverable: Bool
    public init(_ message: String, code: String, recoverable: Bool) { self.message = message; self.code = code; self.recoverable = recoverable }
    public var errorDescription: String? { message }
}
public protocol BackendAppDeviceByteTransport: Sendable {
    var incoming: AsyncThrowingStream<Data, any Error> { get }
    func send(_ bytes: Data) async throws
    func close()
}
/// Native Unix socket transport. Requests are written through one serial queue;
/// incoming stream buffering preserves every video packet in receive order.
public final class BackendAppDeviceUnixTransport: BackendAppDeviceByteTransport, @unchecked Sendable {
    public let incoming: AsyncThrowingStream<Data, any Error>
    private let continuation: AsyncThrowingStream<Data, any Error>.Continuation
    private let queue = DispatchQueue(label: "terminaldeck.device-engine.socket", qos: .userInteractive)
    private let descriptor: Int32
    private var source: DispatchSourceRead?
    private var closed = false
    private init(descriptor: Int32) {
        self.descriptor = descriptor
        var sink: AsyncThrowingStream<Data, any Error>.Continuation!
        incoming = AsyncThrowingStream { sink = $0 }; continuation = sink
        var timeout = timeval(tv_sec: 10, tv_usec: 0)
        _ = setsockopt(descriptor, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var yes: Int32 = 1
        _ = setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout<Int32>.size))
        let reader = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
        source = reader
        reader.setEventHandler { [weak self] in self?.readAvailable() }
        reader.setCancelHandler { Darwin.close(descriptor) }
        reader.resume()
    }
    public static func connect(path: String) throws -> BackendAppDeviceUnixTransport {
        var address = sockaddr_un(); address.sun_family = sa_family_t(AF_UNIX); address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let bytes = Array(path.utf8) + [UInt8(0)]
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { throw BackendAppSessionError("The simulator socket path is too long.") }
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw BackendAppSessionError("The simulator socket could not be created.") }
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        let count = socklen_t(MemoryLayout<sockaddr_un>.size)
        let answer = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, count) } }
        guard answer == 0 else { Darwin.close(fd); throw BackendAppSessionError("The simulator socket is not ready.") }
        return BackendAppDeviceUnixTransport(descriptor: fd)
    }
    private func readAvailable() {
        var bytes = [UInt8](repeating: 0, count: 64 * 1024)
        while !closed {
            let n = bytes.withUnsafeMutableBytes { Darwin.recv(descriptor, $0.baseAddress, $0.count, MSG_DONTWAIT) }
            if n > 0 { continuation.yield(Data(bytes.prefix(n))); continue }
            if n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) { return }
            if n < 0 && errno == EINTR { continue }
            finish(error: n == 0 ? nil : BackendAppSessionError(String(cString: strerror(errno)))); return
        }
    }
    public func send(_ bytes: Data) async throws {
        try await withCheckedThrowingContinuation { (answer: CheckedContinuation<Void, any Error>) in
            queue.async { [self] in
                guard !closed else { answer.resume(throwing: BackendAppSessionError("The simulator engine closed the connection.")); return }
                do {
                    try bytes.withUnsafeBytes { raw in
                        var offset = 0
                        while offset < raw.count {
                            let n = Darwin.send(descriptor, raw.baseAddress!.advanced(by: offset), raw.count - offset, 0)
                            if n < 0 && errno == EINTR { continue }
                            guard n > 0 else { throw BackendAppSessionError("The simulator engine closed the connection.") }
                            offset += n
                        }
                    }
                    answer.resume()
                } catch { finish(error: error); answer.resume(throwing: error) }
            }
        }
    }
    private func finish(error: (any Error)?) {
        guard !closed else { return }; closed = true
        if let error { continuation.finish(throwing: error) } else { continuation.finish() }
        _ = Darwin.shutdown(descriptor, SHUT_RDWR); source?.cancel(); source = nil
    }
    public func close() { queue.async { [self] in finish(error: nil) } }
}
private final class BackendAppDeviceOwnedProcess: @unchecked Sendable {
    let process: Process
    let folder: URL
    private let lock = NSLock()
    private var words = ""
    init(engine: BackendAppDeviceEngine, deviceID: String, environment: [String: String], token: String) throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("tdsim-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        process = Process(); let input = Pipe(), errors = Pipe()
        process.executableURL = URL(fileURLWithPath: engine.core)
        process.arguments = ["serve", "--socket", folder.appendingPathComponent("core.sock").path, "--token-fd", "0", "--parent-pid", String(getpid()), "--idle-timeout", "120", "--device-id", deviceID]
        process.environment = environment.merging(engine.environment) { _, new in new }
        process.standardInput = input; process.standardOutput = FileHandle.nullDevice; process.standardError = errors
        errors.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard let self else { return }
            if data.isEmpty { handle.readabilityHandler = nil; return }
            self.lock.lock(); self.words = String((self.words + String(decoding: data, as: UTF8.self)).suffix(800)); self.lock.unlock()
        }
        do { try process.run(); try input.fileHandleForWriting.write(contentsOf: Data(token.utf8)); try input.fileHandleForWriting.close() }
        catch { if process.isRunning { process.terminate() }; try? FileManager.default.removeItem(at: folder); throw error }
    }
    func lastWords() -> String { lock.lock(); defer { lock.unlock() }; return words.trimmingCharacters(in: .whitespacesAndNewlines) }
    func stop() {
        if process.isRunning { process.terminate() }
        let child = process
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 3) { if child.isRunning { Darwin.kill(child.processIdentifier, SIGKILL) } }
        try? FileManager.default.removeItem(at: folder)
    }
}
public enum BackendAppDeviceClientEvent: Sendable {
    case jpeg(Data), config(Data), picture(Data), closed(String)
}
public struct BackendAppDeviceScreenshot: Sendable {
    public let png: Data
    public let width: Double
    public let height: Double
    public init(png: Data, width: Double, height: Double) { self.png = png; self.width = width; self.height = height }
}
public actor BackendAppDeviceCoreClient {
    public static let protocolVersion = 4
    public nonisolated let events: AsyncStream<BackendAppDeviceClientEvent>
    private let emit: AsyncStream<BackendAppDeviceClientEvent>.Continuation
    private let transport: any BackendAppDeviceByteTransport
    private let clock: any BackendAppSessionClock
    private var owned: BackendAppDeviceOwnedProcess?
    private var reader = BackendAppDeviceFrameReader()
    private struct Pending {
        let continuation: CheckedContinuation<NativeRPCValue, any Error>
        let timeout: Task<Void, Never>
    }
    private var pending: [String: Pending] = [:]
    private var loop: Task<Void, Never>?
    private var sendTail: Task<Void, Never>?
    private var closed = false
    private var pngWaiter: AsyncThrowingStream<Data, any Error>.Continuation?
    private var shotBusy = false
    private var shotQueue: [CheckedContinuation<Void, Never>] = []
    public init(transport: any BackendAppDeviceByteTransport, clock: any BackendAppSessionClock = BackendAppSessionSystemClock()) {
        self.transport = transport; self.clock = clock
        var sink: AsyncStream<BackendAppDeviceClientEvent>.Continuation!
        events = AsyncStream { sink = $0 }; emit = sink
    }
    public static func timeout(for method: String) -> Int {
        switch method {
        case "accessibility.enableXCTestProvider": 45_000
        case "capture.start", "device.orientation.set": 30_000
        case "capture.screenshot": 20_000
        default: 10_000
        }
    }
    public static func attach(transport: any BackendAppDeviceByteTransport, token: String, codec: String = "mjpeg", maxFrameRate: Int = 30,
                              maxWidth: Int? = nil, maxHeight: Int? = nil, clock: any BackendAppSessionClock = BackendAppSessionSystemClock()) async throws -> BackendAppDeviceCoreClient {
        let client = BackendAppDeviceCoreClient(transport: transport, clock: clock)
        await client.begin()
        do { try await client.hello(token: token, codec: codec, rate: maxFrameRate, width: maxWidth, height: maxHeight); return client }
        catch { await client.shutDown(error.localizedDescription); throw error }
    }
    public static func attach(socketPath: String, token: String, codec: String = "mjpeg", maxFrameRate: Int = 30,
                              maxWidth: Int? = nil, maxHeight: Int? = nil, clock: any BackendAppSessionClock = BackendAppSessionSystemClock()) async throws -> BackendAppDeviceCoreClient {
        let deadline = clock.now().addingTimeInterval(5)
        while clock.now() < deadline {
            try Task.checkCancellation()
            if let transport = try? BackendAppDeviceUnixTransport.connect(path: socketPath) {
                return try await attach(transport: transport, token: token, codec: codec, maxFrameRate: maxFrameRate, maxWidth: maxWidth, maxHeight: maxHeight, clock: clock)
            }
            try await clock.sleep(milliseconds: 30)
        }
        throw BackendAppSessionError("The simulator engine did not start in time.")
    }
    public static func start(engine: BackendAppDeviceEngine, deviceID: String, environment: [String: String], codec: String = "mjpeg", maxFrameRate: Int = 30, clock: any BackendAppSessionClock = BackendAppSessionSystemClock()) async throws -> BackendAppDeviceCoreClient {
        var random = [UInt8](repeating: 0, count: 32)
        guard random.withUnsafeMutableBytes({ SecRandomCopyBytes(kSecRandomDefault, $0.count, $0.baseAddress!) }) == errSecSuccess else { throw BackendAppSessionError("The simulator token could not be generated.") }
        let token = random.map { String(format: "%02x", $0) }.joined()
        let owned = try BackendAppDeviceOwnedProcess(engine: engine, deviceID: deviceID, environment: environment, token: token)
        do {
            let deadline = clock.now().addingTimeInterval(10)
            while clock.now() < deadline {
                try Task.checkCancellation()
                guard owned.process.isRunning else { throw BackendAppSessionError("The simulator engine stopped before it was ready.") }
                if let transport = try? BackendAppDeviceUnixTransport.connect(path: owned.folder.appendingPathComponent("core.sock").path) {
                    let client = BackendAppDeviceCoreClient(transport: transport, clock: clock); await client.adopt(owned); await client.begin()
                    do { try await client.hello(token: token, codec: codec, rate: maxFrameRate, width: nil, height: nil); return client }
                    catch { await client.shutDown(error.localizedDescription); throw error }
                }
                try await clock.sleep(milliseconds: 30)
            }
            throw BackendAppSessionError("The simulator engine did not start in time.")
        } catch { owned.stop(); throw error }
    }
    private func adopt(_ owned: BackendAppDeviceOwnedProcess) { self.owned = owned }
    private func begin() {
        guard loop == nil else { return }
        let stream = transport.incoming
        loop = Task { [weak self] in
            do {
                for try await chunk in stream { guard let self else { return }; await self.receive(chunk) }
                await self?.shutDown("The simulator engine closed the connection.")
            } catch { await self?.shutDown(error.localizedDescription) }
        }
    }
    private func hello(token: String, codec: String, rate: Int, width: Int?, height: Int?) async throws {
        var params = BackendAppDeviceParsing.object([("token", .string(token)), ("codecs", .array([.string(codec)])), ("maxFrameRate", .number(Double(rate)))])
        if let width, width != 0 { params = params.setting("maxWidth", .number(Double(width))) }
        if let height, height != 0 { params = params.setting("maxHeight", .number(Double(height))) }
        _ = try await request("hello", params: params)
    }
    public func isClosed() -> Bool { closed }
    public func lastWords() -> String { owned?.lastWords() ?? "" }
    private func receive(_ bytes: Data) {
        do {
            for frame in try reader.push(bytes) {
                switch frame.kind {
                case BackendAppDeviceFrames.response:
                    guard let raw = try? JSONSerialization.jsonObject(with: frame.payload), let value = try? NativeRPCValue.fromFoundation(raw), let id = value["id"].string,
                          let waiting = pending.removeValue(forKey: id) else { continue }
                    waiting.timeout.cancel()
                    if value["error"].fields != nil {
                        waiting.continuation.resume(throwing: BackendAppDeviceEngineError(value["error"]["message"].string ?? "The simulator engine refused that.", code: value["error"]["code"].string ?? "ENGINE_ERROR", recoverable: value["error"]["recoverable"].bool == true))
                    } else { waiting.continuation.resume(returning: value["result"]) }
                case BackendAppDeviceFrames.jpeg: emit.yield(.jpeg(frame.payload))
                case BackendAppDeviceFrames.h264Config: emit.yield(.config(frame.payload))
                case BackendAppDeviceFrames.h264Data: emit.yield(.picture(frame.payload))
                case BackendAppDeviceFrames.png: pngWaiter?.yield(frame.payload); pngWaiter?.finish(); pngWaiter = nil
                default: break
                }
            }
        } catch { shutDown(error.localizedDescription) }
    }
    public func request(_ method: String, params: NativeRPCValue = .object([]), timeoutMilliseconds: Int? = nil) async throws -> NativeRPCValue {
        guard !closed else { throw BackendAppSessionError("The simulator engine is not running.") }
        try Task.checkCancellation()
        let id = UUID().uuidString, timeout = timeoutMilliseconds ?? Self.timeout(for: method)
        let body = try BackendAppDeviceParsing.object([("id", .string(id)), ("protocolVersion", .number(4)), ("method", .string(method)), ("params", params)]).encodedJSON()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let timer = Task { [weak self, clock] in
                    do { try await clock.sleep(milliseconds: timeout) } catch { return }
                    await self?.expire(id, method: method)
                }
                pending[id] = Pending(continuation: continuation, timeout: timer)
                let before = sendTail
                sendTail = Task { [weak self, transport] in
                    await before?.value
                    do { try await transport.send(BackendAppDeviceFrames.encode(kind: BackendAppDeviceFrames.request, payload: body)) }
                    catch { await self?.shutDown(error.localizedDescription) }
                }
            }
        } onCancel: { Task { await self.cancel(id) } }
    }
    private func cancel(_ id: String) { if let waiter = pending.removeValue(forKey: id) { waiter.timeout.cancel(); waiter.continuation.resume(throwing: CancellationError()) } }
    private func expire(_ id: String, method: String) {
        pending.removeValue(forKey: id)?.continuation.resume(throwing: BackendAppDeviceEngineError("The simulator did not answer in time (\(method)).", code: "TIMEOUT", recoverable: true))
    }
    public func screenshot() async throws -> BackendAppDeviceScreenshot {
        if shotBusy { await withCheckedContinuation { shotQueue.append($0) } } else { shotBusy = true }
        defer { if shotQueue.isEmpty { shotBusy = false } else { shotQueue.removeFirst().resume() } }
        try Task.checkCancellation()
        var sink: AsyncThrowingStream<Data, any Error>.Continuation!
        let png = AsyncThrowingStream<Data, any Error> { sink = $0 }; pngWaiter = sink
        let timer = Task { [weak self, clock] in
            do { try await clock.sleep(milliseconds: 25_000) } catch { return }
            await self?.expirePNG()
        }
        defer { timer.cancel(); pngWaiter?.finish(); pngWaiter = nil }
        let meta = try await request("capture.screenshot")
        var iterator = png.makeAsyncIterator()
        guard let bytes = try await iterator.next() else { throw BackendAppSessionError("The screenshot did not arrive.") }
        return .init(png: bytes, width: BackendAppDeviceParsing.number(meta["width"]), height: BackendAppDeviceParsing.number(meta["height"]))
    }
    private func expirePNG() { pngWaiter?.finish(throwing: BackendAppDeviceEngineError("The screenshot did not arrive.", code: "TIMEOUT", recoverable: true)); pngWaiter = nil }
    private func shutDown(_ reason: String) {
        guard !closed else { return }; closed = true
        for waiter in pending.values { waiter.timeout.cancel(); waiter.continuation.resume(throwing: BackendAppSessionError(reason)) }
        pending.removeAll(); pngWaiter?.finish(throwing: BackendAppSessionError(reason)); pngWaiter = nil
        transport.close(); owned?.stop(); owned = nil; emit.yield(.closed(reason)); emit.finish(); loop?.cancel(); loop = nil
    }
    public func close() async {
        guard !closed else { return }
        _ = try? await request("server.shutdown", timeoutMilliseconds: 2_000)
        shutDown("Closed.")
    }
}
