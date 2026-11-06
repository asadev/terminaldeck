import CoreVideo
import Foundation
import Security
import TerminalDeckNativeCore

/// Private, signed-process-only transport. Neither the daemon nor its GUI agent has a shell or arbitrary-file verb.
@objc public protocol BackendMacReachRPC {
    func request(_ command: String, id: String, payload: Data, reply: @escaping (Data?, String?) -> Void)
    func cancel(_ id: String)
}

public enum BackendMacReachSigning {
    /// Derive the requirement from the keeper's existing stable identifier and signing team. Ad-hoc builds fail closed.
    public static func requirements() throws -> (app: String, helper: String) {
        var code: SecCode?, staticCode: SecStaticCode?, info: CFDictionary?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
              SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
              SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let info = info as? [String: Any], let team = info[kSecCodeInfoTeamIdentifier as String] as? String,
              let identifier = info[kSecCodeInfoIdentifier as String] as? String,
              [team, identifier].allSatisfy({ !$0.isEmpty && $0.range(of: "^[A-Za-z0-9.-]+$", options: .regularExpression) != nil }) else {
            throw NativeRPCError(code: "not-signed", message: "Access before sign-in needs the signed release app.")
        }
        let app = identifier.hasSuffix(".session-host") ? String(identifier.dropLast(".session-host".count)) : identifier
        let base = "anchor apple generic and certificate leaf[subject.OU] = \"\(team)\" and identifier = "
        return (base + "\"\(app)\"", base + "\"\(app).session-host\"")
    }
}

/// One connection also acts as the app's lease: the boot host serves only after this signed app lets go.
public final class BackendMacReachClient: @unchecked Sendable {
    private let connection: NSXPCConnection
    public let id = UUID()
    public init(connection: NSXPCConnection) { self.connection = connection }
    public convenience init() throws {
        let requirement = try BackendMacReachSigning.requirements().helper
        let connection = NSXPCConnection(machServiceName: MacReach.daemonLabel, options: .privileged)
        connection.setCodeSigningRequirement(requirement)
        connection.remoteObjectInterface = NSXPCInterface(with: BackendMacReachRPC.self)
        connection.resume()
        self.init(connection: connection)
    }
    deinit { connection.invalidate() }
    public func close() { connection.invalidate() }
    public func request(_ command: String, payload: Data = Data(), timeout: Double = 8) async throws -> Data {
        var bytes = payload
        var limit = timeout
        let attempt = command == "password" ? BackendMacSignInAttempt.current ?? BackendMacSignInAttempt() : nil
        if let attempt {
            try attempt.check()
            bytes = try NativeRPCValue.parseJSON(payload).setting("expiresAt", .number(min(attempt.expiresAt, ProcessInfo.processInfo.systemUptime + timeout))).encodedJSON()
            limit = min(timeout, max(0, attempt.expiresAt - ProcessInfo.processInfo.systemUptime))
        }
        let id = UUID().uuidString, once = Reply()
        let cancellation = attempt?.whenCancelled {
            if once.finish(.failure(BackendMacSignInAttempt.failure)) { self.cancel(id) }
        }
        defer { if let cancellation { attempt?.removeCancellation(cancellation) } }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                once.begin(continuation)
                guard !Task.isCancelled else { once.finish(.failure(BackendMacSignInAttempt.failure)); return }
                guard let proxy = connection.remoteObjectProxyWithErrorHandler({ _ in
                    if once.finish(.failure(NativeRPCError(code: "helper-unreachable", message: "The Mac access helper is unavailable. Check Devices → Device access → General on your Mac."))) { self.cancel(id) }
                }) as? BackendMacReachRPC else {
                    once.finish(.failure(NativeRPCError(code: "helper-unreachable", message: "The Mac access helper is unavailable.")))
                    return
                }
                proxy.request(command, id: id, payload: bytes) { data, problem in
                    if let data { once.finish(.success(data)) }
                    else { once.finish(.failure(NativeRPCError(code: "helper-unavailable", message: problem ?? "The Mac access helper could not answer."))) }
                }
                let deadline = Task { [limit] in
                    do { try await Task.sleep(for: .seconds(limit)) } catch { return }
                    if once.finish(.failure(NativeRPCError(code: "helper-timeout", message: "The Mac access helper did not answer in time. Try again."))) {
                        self.cancel(id)
                    }
                }
                once.setDeadline(deadline)
            }
        } onCancel: {
            if once.finish(.failure(BackendMacSignInAttempt.failure)) { self.cancel(id) }
        }
    }
    private func cancel(_ id: String) {
        (connection.remoteObjectProxyWithErrorHandler { _ in } as? BackendMacReachRPC)?.cancel(id)
    }
    public func value(_ command: String, _ value: NativeRPCValue = .object([])) async throws -> NativeRPCValue {
        let data = try await request(command, payload: value.encodedJSON())
        return data.isEmpty ? .object([]) : try NativeRPCValue.parseJSON(data, maximumBytes: 1_048_576)
    }
    private final class Reply: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Data, Error>?
        private var result: Result<Data, Error>?
        private var deadline: Task<Void, Never>?
        func begin(_ continuation: CheckedContinuation<Data, Error>) {
            let ready: Result<Data, Error>? = lock.withLock { if let result { return result }; self.continuation = continuation; return nil }
            if let ready { continuation.resume(with: ready) }
        }
        func setDeadline(_ task: Task<Void, Never>) {
            let finished = lock.withLock { if result != nil { return true }; deadline = task; return false }
            if finished { task.cancel() }
        }
        @discardableResult func finish(_ answer: Result<Data, Error>) -> Bool {
            let pair: (CheckedContinuation<Data, Error>?, Task<Void, Never>?)? = lock.withLock {
                guard result == nil else { return nil }
                result = answer
                let value = (continuation, deadline); continuation = nil; deadline = nil
                return value
            }
            guard let pair else { return false }
            pair.1?.cancel(); pair.0?.resume(with: answer)
            return true
        }
    }
}

/// A bounded copy of the agent's newest frame. No images or input are ever persisted by this transport.
public enum BackendMacReachPixels {
    public static let maximumBytes = 24 * 1_024 * 1_024
    public static func encode(_ buffer: CVPixelBuffer, capturedAt: Double) throws -> Data {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer), stride = CVPixelBufferGetBytesPerRow(buffer)
        guard CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_32BGRA,
              width > 0, width <= 2560, height > 0, height <= 2560, stride >= width * 4,
              stride <= maximumBytes / height, let address = CVPixelBufferGetBaseAddress(buffer) else { throw invalid }
        return try PropertyListSerialization.data(fromPropertyList: ["width": width, "height": height, "stride": stride,
            "time": capturedAt, "pixels": Data(bytes: address, count: stride * height)], format: .binary, options: 0)
    }
    public static func decode(_ data: Data) throws -> BackendPhoneDevicePixels {
        guard data.count <= maximumBytes + 4096,
              let value = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let width = value["width"] as? Int, let height = value["height"] as? Int,
              let stride = value["stride"] as? Int, let time = value["time"] as? Double, time.isFinite,
              let bytes = value["pixels"] as? Data, width > 0, width <= 2560, height > 0, height <= 2560,
              stride >= width * 4, stride <= maximumBytes / height, bytes.count == stride * height else { throw invalid }
        var buffer: CVPixelBuffer?
        let attributes: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary]
        guard CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, attributes as CFDictionary, &buffer) == kCVReturnSuccess,
              let buffer else { throw invalid }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let target = CVPixelBufferGetBaseAddress(buffer) else { throw invalid }
        let targetStride = CVPixelBufferGetBytesPerRow(buffer)
        bytes.withUnsafeBytes { source in
            guard let address = source.baseAddress else { return }
            for row in 0..<height { memcpy(target.advanced(by: row * targetStride), address.advanced(by: row * stride), width * 4) }
        }
        return .init(buffer, capturedAt: time)
    }
    private static var invalid: NativeRPCError { .init(code: "screen-frame", message: "The Mac screen frame could not be read.") }
}

/// The current signed agent, looked up for every frame so LoginWindow can hand over to Aqua.
public struct BackendMacReachScreenAgent: Sendable {
    public let id: UUID
    public let request: @Sendable (String, NativeRPCValue, Double) async throws -> Data
    public init(id: UUID, request: @escaping @Sendable (String, NativeRPCValue, Double) async throws -> Data) {
        self.id = id; self.request = request
    }
    public init(client: BackendMacReachClient) {
        id = client.id
        request = { command, value, timeout in try await client.request(command, payload: value.encodedJSON(), timeout: timeout) }
    }
}

/// The phone's watch and encoder survive a capture-agent replacement, but never wait forever for a new screen.
public actor BackendMacReachStream: BackendPhoneDeviceStream {
    private let currentAgent: @Sendable () async -> BackendMacReachScreenAgent?
    private let clock: @Sendable () -> Double
    private let progress: @Sendable (String) async -> Void
    private let display: String
    private var opened: BackendMacReachScreenAgent?
    private var startingAt: Double?
    private var phoneDrawsPointer = false
    private var last = 0.0
    private var ended = false
    private var reason = ""
    public init(display: String, agent: @escaping @Sendable () async -> BackendMacReachScreenAgent?,
                clock: @escaping @Sendable () -> Double = { ProcessInfo.processInfo.systemUptime }) {
        self.display = display; currentAgent = agent; self.clock = clock
        progress = MacScreenAvailability.progress
    }
    public init(client: BackendMacReachClient, display: String) {
        self.display = display
        currentAgent = { BackendMacReachScreenAgent(client: client) }
        clock = { ProcessInfo.processInfo.systemUptime }
        progress = MacScreenAvailability.progress
    }
    public func endReason() -> String { reason }
    public func isStarting() async -> Bool { startingAt != nil && !ended }
    public func stop() async {
        ended = true
        let old = opened; opened = nil
        _ = try? await old?.request("close", fields, 1)
    }
    public func drawsPointer(_ phone: Bool) async {
        phoneDrawsPointer = phone
        _ = try? await opened?.request("cursor", fields.setting("phone", .bool(phone)), 1)
    }
    private var fields: NativeRPCValue { .object([.init("id", .string(display))]) }
    private func starting() async {
        if startingAt == nil {
            startingAt = clock()
            await progress("The Mac screen is starting…")
        }
    }
    public func pixels(within seconds: Double) async -> BackendPhoneDevicePixelsAnswer {
        guard !ended, !Task.isCancelled else { return .ended }
        do {
            let agent = await currentAgent()
            if agent?.id != opened?.id || opened == nil {
                await starting()
                let previous = opened
                opened = nil; last = 0
                _ = try? await previous?.request("close", fields, 1)
                guard let agent else { return await waiting(seconds) }
                let remaining = 10 - (clock() - (startingAt ?? clock()))
                guard remaining > 0 else { return await waiting(seconds) }
                _ = try await agent.request("open", fields, min(2, remaining))
                guard !ended, !Task.isCancelled else {
                    _ = try? await agent.request("close", fields, 1)
                    return .ended
                }
                guard await currentAgent()?.id == agent.id else { return await waiting(seconds) }
                opened = agent
                _ = try await agent.request("cursor", fields.setting("phone", .bool(phoneDrawsPointer)), 1)
            }
            guard let opened else { return await waiting(seconds) }
            let remaining = startingAt.map { 10 - (clock() - $0) } ?? 2
            guard remaining > 0 else { return await waiting(seconds) }
            let data = try await opened.request("frame", fields, min(2, remaining))
            guard !ended, !Task.isCancelled else { return .ended }
            guard await currentAgent()?.id == opened.id else {
                await starting(); self.opened = nil
                return await waiting(seconds)
            }
            if data.isEmpty { return await waiting(seconds) }
            let frame = try BackendMacReachPixels.decode(data)
            guard frame.capturedAt != last else { return await waiting(seconds) }
            startingAt = nil; reason = ""
            last = frame.capturedAt
            return .pixels(frame)
        } catch {
            guard !ended, !Task.isCancelled else { return .ended }
            reason = (error as? NativeRPCError)?.message ?? "The Mac screen couldn't start. Try again."
            await starting()
            let previous = opened; opened = nil
            _ = try? await previous?.request("close", fields, 1)
            return await waiting(seconds)
        }
    }
    private func waiting(_ seconds: Double) async -> BackendPhoneDevicePixelsAnswer {
        if let startingAt, clock() - startingAt >= 10 {
            if reason.isEmpty { reason = "The Mac screen couldn't start. Try again." }
            ended = true
            return .ended
        }
        // The existing video pump drives recovery; there is no new background poller.
        try? await Task.sleep(for: .seconds(max(0.02, min(seconds, 0.1))))
        return ended || Task.isCancelled ? .ended : .unchanged
    }
}
