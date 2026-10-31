import Foundation
import CryptoKit
import Darwin
import Network
import Security
import TerminalDeckNativeCore

/// Injected clock shared by the notification queue, subscription outbox and detector.
public protocol BackendDeckCoreEventsClock: Sendable {
    func now() -> Double
    func schedule(after milliseconds: Double, _ run: @escaping @Sendable () -> Void) -> UUID
    func cancel(_ handle: UUID)
}

public final class BackendDeckCoreEventsRealClock: BackendDeckCoreEventsClock, @unchecked Sendable {
    private let lock = NSLock()
    private var timers: [UUID: DispatchWorkItem] = [:]
    public init() {}
    public func now() -> Double { Date().timeIntervalSince1970 * 1_000 }
    public func schedule(after milliseconds: Double, _ run: @escaping @Sendable () -> Void) -> UUID {
        let id = UUID()
        let item = DispatchWorkItem { [weak self] in
            guard let self, self.lock.withLock({ self.timers.removeValue(forKey: id) != nil }) else { return }
            run()
        }
        lock.withLock { timers[id] = item }
        DispatchQueue.global().asyncAfter(deadline: .now() + max(milliseconds, 0) / 1_000, execute: item)
        return id
    }
    public func cancel(_ handle: UUID) { lock.withLock { timers.removeValue(forKey: handle)?.cancel() } }
}

/// Work an actor starts from outside its own isolation (a clock timer's hop
/// back onto the actor, a webhook post and its completion). Each task is
/// recorded synchronously when it is started, so `awaitIdle()` can await the
/// real tasks, including a timer that fired just now, instead of yielding and
/// hoping. Source parity: the TS fake clocks run a timer's callback inline and
/// the tests then settle its promise chain (notify-hub.test.ts:51-69,
/// mcp-events.test.ts:94-96); this is the Swift equivalent of that settle.
public final class BackendDeckCoreEventsWork: @unchecked Sendable {
    private let lock = NSLock()
    private var tasks: [UUID: Task<Void, Never>] = [:]
    public init() {}
    public func start(_ run: @escaping @Sendable () async -> Void) {
        let id = UUID()
        // Inserted under the lock, so the task's own removal (which takes the
        // lock) can never run before it is recorded.
        lock.withLock { tasks[id] = Task { await run(); self.finish(id) } }
    }
    private func finish(_ id: UUID) { lock.withLock { _ = tasks.removeValue(forKey: id) } }
    /// Awaits every recorded task, and the ones they start, until none is left. Never polls.
    public func awaitIdle() async {
        while true {
            let running = lock.withLock { Array(tasks.values) }
            if running.isEmpty { return }
            for task in running { await task.value }
        }
    }
}

public enum BackendDeckCoreEventsSupport {
    public static let retryDelays: [Double] = [5_000, 30_000, 120_000]
    public static func object(_ fields: [(String, NativeRPCValue)]) -> NativeRPCValue { .object(fields.map { .init($0.0, $0.1) }) }
    public static func nullable(_ string: String?) -> NativeRPCValue { string.map(NativeRPCValue.string) ?? .null }
    public static func number(_ value: Double?) -> NativeRPCValue { value.map(NativeRPCValue.number) ?? .null }
    public static func iso(_ milliseconds: Double) -> String {
        let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: Date(timeIntervalSince1970: milliseconds / 1_000))
    }
    public static func random(_ count: Int) throws -> Data { try BackendRemoteTrustStorage.random(count) }
    public static func base64URL(_ value: Data) -> String { BackendRemoteTrustStorage.base64URL(value) }
    public static func digest(_ text: String, length: Int) -> String { String(base64URL(Data(SHA256.hash(data: Data(text.utf8)))).prefix(length)) }
    public static func equal(_ a: String, _ b: String) -> Bool { BackendRemoteTrustStorage.equal(Data(a.utf8), Data(b.utf8)) }
    public static func utf16Slice(_ text: String, length: Int, fromEnd: Bool = false) -> String {
        let units = Array(text.utf16)
        return String(decoding: fromEnd ? Array(units.suffix(length)) : Array(units.prefix(length)), as: UTF16.self)
    }
    public static func cap(_ text: String, max: Int, fromEnd: Bool = false) -> NativeRPCValue {
        let trimmed = text.replacingOccurrences(of: #"\s+$"#, with: "", options: .regularExpression)
        let truncated = trimmed.utf16.count > max
        let sliced = utf16Slice(trimmed, length: max, fromEnd: fromEnd)
        return object([("text", .string(truncated ? (fromEnd ? "…" + sliced : sliced + "…") : trimmed)), ("truncated", .bool(truncated))])
    }
    public static func read(_ file: URL?) throws -> NativeRPCValue? {
        guard let file, FileManager.default.fileExists(atPath: file.path) else { return nil }
        return try NativeRPCValue.parseJSON(Data(contentsOf: file))
    }
    public static func write(_ state: NativeRPCValue, file: URL?) throws {
        guard let file else { return }
        // Reuse the native atomic, exclusive, 0600 writer rather than introduce another secret-file implementation.
        try BackendRemoteTrustStorage.write(state, file: file)
    }
}

public enum BackendDeckCoreEventsWebhook {
    public static let secretPrefix = "whsec_"
    public static let replayWindowSeconds = 300.0
    public static func newSecret() throws -> String { secretPrefix + (try BackendDeckCoreEventsSupport.random(32)).base64EncodedString() }
    public static func sign(secret: String, id: String, timestamp: Double, body: String) -> String {
        let encoded = secret.hasPrefix(secretPrefix) ? String(secret.dropFirst(secretPrefix.count)) : secret
        let bytes = Data(base64Encoded: encoded, options: .ignoreUnknownCharacters) ?? Data()
        let stamp = String(format: "%.0f", timestamp)
        let mac = HMAC<SHA256>.authenticationCode(for: Data("\(id).\(stamp).\(body)".utf8), using: SymmetricKey(data: bytes))
        return "v1," + Data(mac).base64EncodedString()
    }
    public static func headers(secret: String, id: String, timestamp: Double, body: String) -> [String: String] {
        ["webhook-id": id, "webhook-timestamp": String(format: "%.0f", timestamp), "webhook-signature": sign(secret: secret, id: id, timestamp: timestamp, body: body)]
    }
    /// nil is verified; every signature is compared, including during secret rotation.
    public static func verify(secret: String, headers: [String: String], body: String, nowSeconds: Double) -> String? {
        guard let id = headers["webhook-id"], !id.isEmpty, let stamp = headers["webhook-timestamp"], !stamp.isEmpty,
              let signatures = headers["webhook-signature"], !signatures.isEmpty else { return "missing" }
        let timestamp = Double(stamp.trimmingCharacters(in: .whitespacesAndNewlines)) ?? .nan
        guard timestamp.isFinite, timestamp.rounded(.towardZero) == timestamp, abs(nowSeconds - timestamp) <= replayWindowSeconds else { return "stale" }
        let expected = Data(base64Encoded: String(sign(secret: secret, id: id, timestamp: timestamp, body: body).dropFirst(3))) ?? Data()
        var match = false
        for entry in signatures.split(separator: " ") where entry.hasPrefix("v1,") {
            let offered = Data(base64Encoded: String(entry.dropFirst(3)), options: .ignoreUnknownCharacters) ?? Data()
            if BackendRemoteTrustStorage.equal(offered, expected) { match = true }
        }
        return match ? nil : "mismatch"
    }
    public static func urlProblem(_ raw: String) -> String? {
        guard let url = URL(string: raw), let scheme = url.scheme, let host = url.host else { return "That is not a web address." }
        if url.user != nil || url.password != nil { return "Leave the user name and password out of the address." }
        if scheme.lowercased() == "https" { return nil }
        if scheme.lowercased() == "http", ["localhost", "127.0.0.1", "[::1]", "::1"].contains(host.lowercased()) { return nil }
        return "Use an https:// address. Plain http:// is only allowed to this Mac (localhost)."
    }
}

public struct BackendDeckCoreEventsCallbackAnswer: Sendable {
    public let status: Int
    public let body: String
    public init(status: Int, body: String) { self.status = status; self.body = body }
}
public struct BackendDeckCoreEventsCallbackRefused: Error, LocalizedError, Sendable {
    public let reason: String
    public let message: String
    public let code: String?
    public init(reason: String, message: String, code: String? = nil) { self.reason = reason; self.message = message; self.code = code }
    public var errorDescription: String? { message }
}
public typealias BackendDeckCoreEventsCallbackPost = @Sendable (String, [String: String], String) async throws -> BackendDeckCoreEventsCallbackAnswer
public typealias BackendDeckCoreEventsWebhookPost = @Sendable (String, [String: String], String) async throws -> Int

/// Like response.on('data') in the source: the cumulative byte count never
/// resets, and no chunk after crossing the answer cap is retained.
struct BackendDeckCoreEventsAnswerBuffer {
    private(set) var bytesSeen = 0
    private(set) var data = Data()
    mutating func append(_ bytes: Data) {
        bytesSeen += bytes.count
        if bytesSeen <= BackendDeckCoreEventsCallback.maximumAnswerBytes { data.append(bytes) }
    }
}

public enum BackendDeckCoreEventsCallback {
    public static let timeoutMilliseconds = 10_000
    public static let maximumAnswerBytes = 8 * 1024
    private static func bytes(_ address: String, family: Int32) -> [UInt8]? {
        var result = [UInt8](repeating: 0, count: family == AF_INET ? 4 : 16)
        let code = result.withUnsafeMutableBytes { inet_pton(family, address, $0.baseAddress) }
        return code == 1 ? result : nil
    }
    private static func within(_ value: [UInt8], network: String, prefix: Int, family: Int32) -> Bool {
        guard let base = bytes(network, family: family) else { return false }
        for bit in 0..<prefix { let mask = UInt8(1 << (7 - bit % 8)); if value[bit / 8] & mask != base[bit / 8] & mask { return false } }
        return true
    }
    public static func isPublicAddress(_ address: String) -> Bool {
        if let value = bytes(address, family: AF_INET) {
            let blocked: [(String, Int)] = [("0.0.0.0",8),("10.0.0.0",8),("100.64.0.0",10),("127.0.0.0",8),("169.254.0.0",16),("172.16.0.0",12),("192.0.0.0",24),("192.0.2.0",24),("192.88.99.0",24),("192.168.0.0",16),("198.18.0.0",15),("198.51.100.0",24),("203.0.113.0",24),("224.0.0.0",4),("240.0.0.0",4)]
            return !blocked.contains { within(value, network: $0.0, prefix: $0.1, family: AF_INET) }
        }
        guard let value = bytes(address, family: AF_INET6) else { return false }
        let groups = stride(from: 0, to: 16, by: 2).map { UInt16(value[$0]) << 8 | UInt16(value[$0 + 1]) }
        func publicV4(_ high: UInt16, _ low: UInt16) -> Bool { isPublicAddress("\(high >> 8).\(high & 255).\(low >> 8).\(low & 255)") }
        if groups[0...4].allSatisfy({ $0 == 0 }), groups[5] == 0xffff || groups[5] == 0 {
            if groups[5] == 0 && groups[6] == 0 { return false }
            return publicV4(groups[6], groups[7])
        }
        if groups[0] == 0x64, groups[1] == 0xff9b, groups[2...5].allSatisfy({ $0 == 0 }) { return publicV4(groups[6], groups[7]) }
        if groups[0] == 0x2002 { return publicV4(groups[1], groups[2]) }
        let blocked: [(String, Int)] = [("::",128),("::1",128),("100::",64),("2001::",23),("2001:db8::",32),("fc00::",7),("fe80::",10),("fec0::",10),("ff00::",8)]
        return !blocked.contains { within(value, network: $0.0, prefix: $0.1, family: AF_INET6) }
    }
    public static func urlProblem(_ raw: String) -> String? {
        guard let url = URL(string: raw), url.scheme != nil else { return "The callback is not a web address." }
        if let port = url.port, !(1...65_535).contains(port) { return "The callback is not a web address." }
        if url.scheme?.lowercased() != "https" { return "The callback has to be an https:// address." }
        if url.user != nil || url.password != nil { return "The callback address cannot carry a user name or password." }
        guard var host = url.host, !host.isEmpty else { return "The callback address has no host." }
        host = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if bytes(host, family: AF_INET) != nil || bytes(host, family: AF_INET6) != nil { return isPublicAddress(host) ? nil : "The callback has to be a public internet address." }
        var name = host.lowercased(); if name.hasSuffix(".") { name.removeLast() }
        if name == "localhost" || [".localhost", ".local", ".internal", ".home.arpa"].contains(where: name.hasSuffix) || !name.contains(".") { return "The callback has to be a public internet address." }
        return nil
    }
    /// Every resolved address is checked before choosing a pinned connection address.
    public static func publicLookup(_ hostname: String, resolve: (@Sendable (String) throws -> [String])? = nil) throws -> [String] {
        let values: [String]
        if let resolve { values = try resolve(hostname) }
        else { values = try systemLookup(hostname) }
        guard !values.isEmpty, values.allSatisfy(isPublicAddress) else {
            throw BackendDeckCoreEventsCallbackRefused(reason: "not_public", message: "\(hostname) does not resolve to a public internet address", code: "ENOTPUBLIC")
        }
        return values
    }
    private static func systemLookup(_ hostname: String) throws -> [String] {
        var hints = addrinfo(); hints.ai_family = AF_UNSPEC; hints.ai_socktype = SOCK_STREAM
        var list: UnsafeMutablePointer<addrinfo>?
        let code = getaddrinfo(hostname, nil, &hints, &list)
        guard code == 0 else { throw BackendDeckCoreEventsCallbackRefused(reason: "connection_refused", message: String(cString: gai_strerror(code))) }
        defer { if let list { freeaddrinfo(list) } }
        var values: [String] = [], cursor = list
        while let item = cursor {
            var name = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(item.pointee.ai_addr, item.pointee.ai_addrlen, &name, socklen_t(name.count), nil, 0, NI_NUMERICHOST) == 0 { values.append(String(cString: name)) }
            cursor = item.pointee.ai_next
        }
        return values
    }
    public static func post(_ raw: String, _ headers: [String: String], _ body: String) async throws -> BackendDeckCoreEventsCallbackAnswer {
        if let problem = urlProblem(raw) { throw BackendDeckCoreEventsCallbackRefused(reason: "not_public", message: problem) }
        guard let url = URL(string: raw), let host = url.host?.trimmingCharacters(in: CharacterSet(charactersIn: "[]")) else { throw BackendDeckCoreEventsCallbackRefused(reason: "not_public", message: "The callback address has no host.") }
        return try await withCheckedThrowingContinuation { continuation in
            // Deadline includes DNS resolution, TCP, TLS, send and reading the answer.
            let operation = BackendDeckCoreEventsPinnedPost(continuation: continuation)
            operation.start(url: url, host: host, headers: headers, body: body)
        }
    }
    /// Ordinary owner-configured webhooks may target HTTPS or HTTP loopback.
    public static func webhookPost(_ raw: String, _ headers: [String: String], _ body: String) async throws -> Int {
        guard let url = URL(string: raw) else { throw NativeRPCError.invalidArguments("That is not a web address.") }
        let config = URLSessionConfiguration.ephemeral; config.timeoutIntervalForRequest = 10; config.timeoutIntervalForResource = 10
        let session = URLSession(configuration: config, delegate: BackendDeckCoreEventsNoRedirect(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: url); request.httpMethod = "POST"; request.httpBody = Data(body.utf8); request.setValue("application/json", forHTTPHeaderField: "content-type")
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        let (_, response) = try await session.data(for: request)
        return (response as? HTTPURLResponse)?.statusCode ?? 0
    }
}

private final class BackendDeckCoreEventsNoRedirect: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) { completionHandler(nil) }
}

/// A new TLS connection to the checked IP, with the original hostname verified.
private final class BackendDeckCoreEventsPinnedPost: @unchecked Sendable {
    private let queue = DispatchQueue(label: "terminaldeck.mcp-events.callback")
    private var continuation: CheckedContinuation<BackendDeckCoreEventsCallbackAnswer, Error>?
    private var connection: NWConnection?
    private var deadline: DispatchWorkItem?
    private var received = Data()
    private var answer = BackendDeckCoreEventsAnswerBuffer()
    private var status: Int?
    private var length: Int?
    private var chunked = false
    private var chunkSize: Int?
    private var chunkTerminator = false
    private var readBodyBytes = 0
    init(continuation: CheckedContinuation<BackendDeckCoreEventsCallbackAnswer, Error>) { self.continuation = continuation }
    func start(url: URL, host: String, headers: [String: String], body: String) {
        let timer = DispatchWorkItem { self.finish(.failure(BackendDeckCoreEventsCallbackRefused(reason: "timeout", message: "no answer within 10 seconds"))) }
        deadline = timer; queue.asyncAfter(deadline: .now() + 10, execute: timer)
        DispatchQueue.global().async {
            do {
                let addresses = try BackendDeckCoreEventsCallback.publicLookup(host)
                self.queue.async { self.connect(address: addresses[0], url: url, host: host, headers: headers, body: body) }
            } catch { self.queue.async { self.finish(.failure(error)) } }
        }
    }
    private func connect(address: String, url: URL, host: String, headers: [String: String], body: String) {
        guard continuation != nil, let port = NWEndpoint.Port(rawValue: UInt16(url.port ?? 443)) else { return }
        let tls = NWProtocolTLS.Options()
        sec_protocol_options_set_tls_server_name(tls.securityProtocolOptions, host)
        sec_protocol_options_set_verify_block(tls.securityProtocolOptions, { _, trust, complete in
            let value = sec_trust_copy_ref(trust).takeRetainedValue()
            SecTrustSetPolicies(value, SecPolicyCreateSSL(true, host as CFString))
            complete(SecTrustEvaluateWithError(value, nil))
        }, queue)
        let connection = NWConnection(host: NWEndpoint.Host(address), port: port, using: NWParameters(tls: tls, tcp: NWProtocolTCP.Options()))
        self.connection = connection
        let path = (URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedPath ?? "/")
        let target = (path.isEmpty ? "/" : path) + (url.query.map { "?" + $0 } ?? "")
        var lines = ["POST \(target) HTTP/1.1", "Host: \(url.host ?? host)\(url.port.map { ":\($0)" } ?? "")", "Content-Type: application/json", "Content-Length: \(body.utf8.count)", "Connection: close"]
        for (name, value) in headers where !name.contains("\r") && !name.contains("\n") && !value.contains("\r") && !value.contains("\n") { lines.append("\(name): \(value)") }
        let payload = Data((lines.joined(separator: "\r\n") + "\r\n\r\n" + body).utf8)
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                connection.send(content: payload, completion: .contentProcessed { error in
                    if let error { self.finish(.failure(self.classify(error))) } else { self.receive() }
                })
            case .failed(let error): self.finish(.failure(self.classify(error)))
            default: break
            }
        }
        connection.start(queue: queue)
    }
    private func classify(_ error: NWError) -> BackendDeckCoreEventsCallbackRefused {
        if case .tls = error { return .init(reason: "tls_error", message: error.localizedDescription) }
        return .init(reason: "connection_refused", message: error.localizedDescription)
    }
    private func receive() {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { data, _, complete, error in
            if let error { self.finish(.failure(self.classify(error))); return }
            if let data { self.received.append(data) }
            do {
                if try self.parse(complete: complete), let status = self.status {
                    self.finish(.success(.init(status: status, body: String(decoding: self.answer.data, as: UTF8.self))))
                } else { self.receive() }
            } catch { self.finish(.failure(error)) }
        }
    }
    private func parse(complete: Bool) throws -> Bool {
        if status == nil {
            guard let end = received.range(of: Data("\r\n\r\n".utf8)) else {
                guard received.count <= 65_536, !complete else { throw NativeRPCError.malformed("The callback returned no HTTP headers.") }; return false
            }
            let head = String(decoding: received[..<end.lowerBound], as: UTF8.self), lines = head.components(separatedBy: "\r\n")
            guard end.lowerBound <= 65_536 else { throw NativeRPCError.malformed("The callback returned oversized HTTP headers.") }
            guard let first = lines.first, let parsed = Int(first.split(separator: " ").dropFirst().first ?? "") else { throw NativeRPCError.malformed("The callback returned invalid HTTP headers.") }
            status = parsed
            for line in lines.dropFirst() {
                let pair = line.split(separator: ":", maxSplits: 1).map(String.init); guard pair.count == 2 else { continue }
                let value = pair[1].trimmingCharacters(in: .whitespaces)
                if pair[0].lowercased() == "content-length" { length = Int(value) }
                if pair[0].lowercased() == "transfer-encoding", value.lowercased().contains("chunked") { chunked = true }
            }
            received.removeSubrange(..<end.upperBound)
            if (100..<200).contains(parsed) { status = nil; length = nil; chunked = false; return try parse(complete: complete) }
        }
        if chunked {
            while true {
                if chunkTerminator {
                    guard received.count >= 2 else { break }
                    guard received.prefix(2) == Data("\r\n".utf8) else { throw NativeRPCError.malformed("Invalid chunk in callback answer.") }
                    received.removeFirst(2); chunkTerminator = false; chunkSize = nil
                }
                if chunkSize == nil {
                    guard let end = received.range(of: Data("\r\n".utf8)) else {
                        guard received.count <= 8_192 else { throw NativeRPCError.malformed("Invalid chunk in callback answer.") }; break
                    }
                    let text = String(decoding: received[..<end.lowerBound], as: UTF8.self).split(separator: ";").first ?? ""
                    guard let count = Int(text, radix: 16), count >= 0 else { throw NativeRPCError.malformed("Invalid chunk in callback answer.") }
                    received.removeSubrange(..<end.upperBound); if count == 0 { return true }; chunkSize = count
                }
                guard let count = chunkSize, !received.isEmpty else { break }
                let taking = min(count,received.count); append(Data(received.prefix(taking))); received.removeFirst(taking)
                chunkSize = count - taking
                if chunkSize == 0 { chunkTerminator = true }
                else { break }
            }
        } else {
            readBodyBytes += received.count; append(received); received.removeAll(keepingCapacity: true)
            if let length, readBodyBytes >= length { return true }
        }
        if complete {
            guard !chunked, length == nil || readBodyBytes >= length! else { throw NativeRPCError.malformed("The callback closed before its answer was complete.") }
            return true
        }
        return false
    }
    private func append(_ data: Data) { answer.append(data) }
    private func finish(_ result: Result<BackendDeckCoreEventsCallbackAnswer, Error>) {
        guard let continuation else { return }; self.continuation = nil
        deadline?.cancel(); deadline = nil; connection?.stateUpdateHandler = nil; connection?.cancel(); connection = nil
        continuation.resume(with: result)
    }
}
