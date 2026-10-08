import Foundation
import TerminalDeckNativeCore

/// Parsers follow Docker's documented framing and resource calculations:
/// https://docs.docker.com/reference/api/engine/version/v1.47/
/// https://docs.docker.com/reference/cli/docker/container/stats/
/// https://raw.githubusercontent.com/moby/moby/v27.5.1/docs/api/v1.47.yaml
/// Nothing here opens a connection, reconnects, or polls.
public enum BackendDockerStreams {
    public static let maximumChunkBytes = 1_048_576
    public static let maximumFrameBytes = 1_048_576
    public static let maximumJSONLineBytes = 1_048_576
    public static let maximumQueuedRecords = 32
    public static let maximumRecordsPerChunk = 1_024

    public struct LogRecord: Equatable, Sendable {
        public let source: String
        public let text: String
        public var value: NativeRPCValue {
            .object([.init("source", .string(source)), .init("text", .string(text))])
        }
    }

    /// Holds only an incomplete UTF-8 suffix. Invalid bytes use the usual
    /// replacement character; a valid character split between reads survives.
    public struct UTF8Decoder: Sendable {
        private var pending = Data()
        public init() {}
        public mutating func consume(_ bytes: Data) -> String {
            pending.append(bytes)
            guard !pending.isEmpty else { return "" }
            let suffix = Array(pending.suffix(4))
            var keep = 0
            if let lead = suffix.lastIndex(where: { $0 & 0xc0 != 0x80 }) {
                let byte = suffix[lead]
                let expected: Int
                switch byte {
                case 0xc2...0xdf: expected = 2
                case 0xe0...0xef: expected = 3
                case 0xf0...0xf4: expected = 4
                default: expected = 1
                }
                let available = suffix.count - lead
                if expected > available { keep = available }
            }
            let complete = pending.count - keep
            let result = String(decoding: pending.prefix(complete), as: UTF8.self)
            pending = Data(pending.suffix(keep))
            return result
        }
        public mutating func finish() -> String {
            defer { pending.removeAll(keepingCapacity: false) }
            return String(decoding: pending, as: UTF8.self)
        }
    }

    /// Byte matching preserves terminal escape sequences and arbitrary bytes.
    /// A matching prefix stays private until it is complete or disambiguated.
    /// Longest-match handling also protects secrets sharing a common prefix.
    public struct SecretMasker: Sendable {
        private let candidates: [UInt8: [[UInt8]]]
        private var pending: [UInt8] = []
        private static let replacement = Array("••••••".utf8)
        public init(secretValues: [String]) throws {
            let unique = Set(secretValues.filter { !$0.isEmpty })
            guard unique.count <= 1_024 else { throw BackendDockerStreams.overflow("Too many secret values to protect this stream.") }
            var total = 0
            var groups: [UInt8: [[UInt8]]] = [:]
            for secret in unique {
                let bytes = Array(secret.utf8)
                guard bytes.count <= 16_384 else { throw BackendDockerStreams.overflow("A secret value is too large to protect this stream.") }
                total += bytes.count
                guard total <= 1_048_576 else { throw BackendDockerStreams.overflow("Secret values exceed the stream safety limit.") }
                groups[bytes[0], default: []].append(bytes)
            }
            candidates = groups.mapValues { $0.sorted { $0.count > $1.count } }
        }
        public mutating func consume(_ bytes: Data) throws -> Data {
            guard bytes.count <= BackendDockerStreams.maximumChunkBytes else { throw BackendDockerStreams.overflow("Docker sent a stream chunk that is too large.") }
            pending.append(contentsOf: bytes)
            let result = drain(final: false)
            guard result.count <= 4_194_304 else { throw BackendDockerStreams.overflow("Masked Docker output exceeded its safety limit.") }
            return result
        }
        public mutating func finish() -> Data { drain(final: true) }
        private mutating func drain(final: Bool) -> Data {
            var result: [UInt8] = []
            var index = 0
            while index < pending.count {
                var match: [UInt8]?
                var partial = false
                for secret in candidates[pending[index]] ?? [] {
                    let available = pending.count - index
                    let count = min(secret.count, available)
                    guard pending[index..<(index + count)].elementsEqual(secret.prefix(count)) else { continue }
                    if secret.count > available { partial = true; break }
                    match = secret; break
                }
                if partial && !final { break }
                // On EOF a longer incomplete candidate may still contain a
                // complete shorter secret, which must remain masked.
                if partial && final {
                    match = (candidates[pending[index]] ?? []).first {
                        $0.count <= pending.count - index && pending[index..<(index + $0.count)].elementsEqual($0)
                    }
                }
                if let match { result.append(contentsOf: Self.replacement); index += match.count }
                else { result.append(pending[index]); index += 1 }
            }
            pending = Array(pending.dropFirst(index))
            return Data(result)
        }
    }

    public struct LogParser: Sendable {
        private struct Output: Sendable {
            var masker: SecretMasker
            var decoder = UTF8Decoder()
            mutating func consume(_ bytes: Data) throws -> String { decoder.consume(try masker.consume(bytes)) }
            mutating func finish() -> String { decoder.consume(masker.finish()) + decoder.finish() }
        }
        private let tty: Bool
        private let frameLimit: Int
        private var pending = Data()
        private var stdout: Output
        private var stderr: Output
        private var console: Output
        public init(tty: Bool, secretValues: [String] = [], maximumFrameBytes: Int = BackendDockerStreams.maximumFrameBytes) throws {
            guard maximumFrameBytes > 0 && maximumFrameBytes <= BackendDockerStreams.maximumFrameBytes else {
                throw NativeRPCError.invalidArguments("The Docker frame limit is invalid.")
            }
            self.tty = tty; frameLimit = maximumFrameBytes
            let masker = try SecretMasker(secretValues: secretValues)
            stdout = Output(masker: masker); stderr = Output(masker: masker); console = Output(masker: masker)
        }
        public mutating func consume(_ bytes: Data) throws -> [LogRecord] {
            guard bytes.count <= BackendDockerStreams.maximumChunkBytes else { throw BackendDockerStreams.overflow("Docker sent a log chunk that is too large.") }
            if tty { return records(source: "console", text: try console.consume(bytes)) }
            guard pending.count + bytes.count <= frameLimit + 8 + BackendDockerStreams.maximumChunkBytes else {
                throw BackendDockerStreams.overflow("Docker log framing exceeded its buffer limit.")
            }
            pending.append(bytes)
            var result: [LogRecord] = []
            while pending.count >= 8 {
                let header = Array(pending.prefix(8))
                guard header[1...3].allSatisfy({ $0 == 0 }), header[0] <= 2 else {
                    throw BackendDockerStreams.protocolError("Docker sent an invalid log frame header.")
                }
                let count = header[4...7].reduce(0) { ($0 << 8) | Int($1) }
                guard count <= frameLimit else { throw BackendDockerStreams.overflow("Docker sent a log frame that is too large.") }
                guard pending.count >= 8 + count else { break }
                let payload = Data(pending.dropFirst(8).prefix(count))
                pending = Data(pending.dropFirst(8 + count))
                if header[0] == 2 { result += records(source: "stderr", text: try stderr.consume(payload)) }
                else { result += records(source: "stdout", text: try stdout.consume(payload)) }
                guard result.count <= BackendDockerStreams.maximumRecordsPerChunk else { throw BackendDockerStreams.overflow("Docker sent too many log records in one chunk.") }
            }
            return result
        }
        public mutating func finish() throws -> [LogRecord] {
            guard pending.isEmpty else { throw BackendDockerStreams.protocolError("The Docker log stream ended inside a frame.") }
            if tty { return records(source: "console", text: console.finish()) }
            return records(source: "stdout", text: stdout.finish()) + records(source: "stderr", text: stderr.finish())
        }
        private func records(source: String, text: String) -> [LogRecord] {
            guard !text.isEmpty else { return [] }
            // Bound each queued text record while preserving UTF-8 characters.
            let bytes = Data(text.utf8)
            var decoder = UTF8Decoder()
            var records: [LogRecord] = []
            var offset = 0
            while offset < bytes.count {
                let end = min(offset + 65_536, bytes.count)
                let part = decoder.consume(Data(bytes[offset..<end]))
                if !part.isEmpty { records.append(LogRecord(source: source, text: part)) }
                offset = end
            }
            let tail = decoder.finish()
            if !tail.isEmpty { records.append(LogRecord(source: source, text: tail)) }
            return records
        }
    }

    /// Docker emits stats and events as a sequence of newline-terminated JSON
    /// objects. A final complete object without a newline is accepted at EOF.
    public struct JSONLineParser: Sendable {
        private let limit: Int
        private var pending = Data()
        public init(maximumLineBytes: Int = BackendDockerStreams.maximumJSONLineBytes) throws {
            guard maximumLineBytes > 0 && maximumLineBytes <= BackendDockerStreams.maximumJSONLineBytes else {
                throw NativeRPCError.invalidArguments("The Docker JSON line limit is invalid.")
            }
            limit = maximumLineBytes
        }
        public mutating func consume(_ bytes: Data) throws -> [NativeRPCValue] {
            guard bytes.count <= BackendDockerStreams.maximumChunkBytes else { throw BackendDockerStreams.overflow("Docker sent a JSON chunk that is too large.") }
            // Process each line before adding more data, so multiple small
            // lines in one read cannot evade or trigger the per-line bound.
            var result: [NativeRPCValue] = []
            var start = bytes.startIndex
            for newline in bytes.indices where bytes[newline] == 10 {
                let part = bytes[start..<newline]
                guard pending.count + part.count <= limit else { throw BackendDockerStreams.overflow("Docker sent a JSON line that is too large.") }
                pending.append(contentsOf: part)
                if let object = try parsePending() { result.append(object) }
                guard result.count <= BackendDockerStreams.maximumRecordsPerChunk else { throw BackendDockerStreams.overflow("Docker sent too many JSON records in one chunk.") }
                start = bytes.index(after: newline)
            }
            guard pending.count + bytes[start...].count <= limit else { throw BackendDockerStreams.overflow("Docker sent a JSON line that is too large.") }
            pending.append(contentsOf: bytes[start...])
            return result
        }
        public mutating func finish() throws -> [NativeRPCValue] { try parsePending().map { [$0] } ?? [] }
        private mutating func parsePending() throws -> NativeRPCValue? {
            defer { pending.removeAll(keepingCapacity: true) }
            if pending.allSatisfy({ $0 == 32 || $0 == 9 || $0 == 13 }) { return nil }
            do {
                let value = try NativeRPCValue.parseJSON(pending, maximumBytes: limit)
                guard value.fields != nil else { throw BackendDockerStreams.protocolError("Docker sent a JSON record that is not an object.") }
                return value
            } catch { throw BackendDockerStreams.protocolError("Docker sent an invalid JSON stream record.") }
        }
    }

    public struct StatsParser: Sendable {
        private var previousCPU: NativeRPCValue = .missing
        public init() {}
        public mutating func record(_ raw: NativeRPCValue) throws -> NativeRPCValue {
            guard raw.fields != nil, raw["cpu_stats"].fields != nil, raw["memory_stats"].fields != nil else {
                throw BackendDockerStreams.protocolError("Docker sent an incomplete resource statistics record.")
            }
            let cpu = raw["cpu_stats"]
            let previous = raw["precpu_stats"].fields != nil ? raw["precpu_stats"] : previousCPU
            defer { previousCPU = cpu }
            let cpuDelta = max(0, BackendDockerStreams.number(cpu["cpu_usage"]["total_usage"]) - BackendDockerStreams.number(previous["cpu_usage"]["total_usage"]))
            let systemDelta = max(0, BackendDockerStreams.number(cpu["system_cpu_usage"]) - BackendDockerStreams.number(previous["system_cpu_usage"]))
            let online = cpu["online_cpus"].number ?? Double(cpu["cpu_usage"]["percpu_usage"].elements?.count ?? 0)
            let previousPresent = previous["cpu_usage"]["total_usage"].number != nil && previous["system_cpu_usage"].number != nil
            let percent = previousPresent && systemDelta > 0 && cpuDelta > 0 && online > 0 ? cpuDelta / systemDelta * online * 100 : 0
            let memory = raw["memory_stats"]
            let usage = BackendDockerStreams.number(memory["usage"])
            let cache = memory["stats"]["total_inactive_file"].number ?? memory["stats"]["inactive_file"].number ?? memory["stats"]["cache"].number ?? 0
            // Invalid cache counters must not make used memory negative.
            let used = cache >= 0 && cache < usage ? usage - cache : usage
            let limit = BackendDockerStreams.number(memory["limit"])
            let networks = raw["networks"].fields?.map(\.value) ?? []
            let io = raw["blkio_stats"]["io_service_bytes_recursive"].elements ?? []
            var fields: [NativeRPCValue.Field] = [
                .init("cpuPercent", .number(percent.isFinite ? percent : 0)),
                .init("memoryBytes", .number(used)), .init("memoryLimitBytes", .number(limit)),
                .init("memoryPercent", .number(limit > 0 ? used / limit * 100 : 0)),
                .init("networkRxBytes", .number(networks.reduce(0) { $0 + BackendDockerStreams.number($1["rx_bytes"]) })),
                .init("networkTxBytes", .number(networks.reduce(0) { $0 + BackendDockerStreams.number($1["tx_bytes"]) })),
                .init("blockReadBytes", .number(io.filter { $0["op"].string?.lowercased() == "read" }.reduce(0) { $0 + BackendDockerStreams.number($1["value"]) })),
                .init("blockWriteBytes", .number(io.filter { $0["op"].string?.lowercased() == "write" }.reduce(0) { $0 + BackendDockerStreams.number($1["value"]) }))
            ]
            if let pids = raw["pids_stats"]["current"].number, pids >= 0 { fields.append(.init("pids", .number(pids))) }
            return .object(fields)
        }
    }

    public static func eventRecord(_ raw: NativeRPCValue, secretValues: [String] = []) throws -> NativeRPCValue {
        guard let type = raw["Type"].string, let action = raw["Action"].string ?? raw["status"].string,
              let id = raw["Actor"]["ID"].string ?? raw["id"].string else {
            throw BackendDockerStreams.protocolError("Docker sent an incomplete event record.")
        }
        let template = try SecretMasker(secretValues: secretValues)
        func safe(_ text: String) throws -> String {
            var masker = template
            return String(decoding: try masker.consume(Data(text.utf8)) + masker.finish(), as: UTF8.self)
        }
        var attributes: [NativeRPCValue.Field] = []
        for field in raw["Actor"]["Attributes"].fields ?? [] {
            guard let text = field.value.string else { continue }
            let lower = field.key.lowercased()
            let parts = lower.split(whereSeparator: { ".-_".contains($0) })
            let url = URLComponents(string: text)
            let sensitive = ["password", "passwd", "secret", "token", "authorization", "credential", "private", "api_key", "apikey", "access_key", "environment", "env", "database_url", "connection_string"].contains { lower.contains($0) }
                || parts.contains(where: { ["key", "keys", "cookie", "auth", "dsn"].contains(String($0)) })
                || url?.password != nil || text.hasPrefix("Bearer ") || text.contains("PRIVATE KEY-----")
            attributes.append(.init(try safe(field.key), .string(sensitive ? "••••••" : try safe(text))))
        }
        return .object([
            .init("type", .string(try safe(type))), .init("action", .string(try safe(action))), .init("id", .string(try safe(id))),
            .init("time", .number(BackendDockerStreams.number(raw["time"]))), .init("timeNano", .number(BackendDockerStreams.number(raw["timeNano"]))), .init("attributes", .object(attributes))
        ])
    }

    public static func logs(response: BackendDockerByteStream, tty: Bool, secretValues: [String] = []) throws -> BackendDockerRecordStream {
        try requireSuccess(response)
        do { return transform(response, parser: LogsAdapter(parser: try LogParser(tty: tty, secretValues: secretValues))) }
        catch { response.cancel(); throw error }
    }
    public static func stats(response: BackendDockerByteStream) throws -> BackendDockerRecordStream {
        try requireSuccess(response)
        return transform(response, parser: StatsAdapter(lines: try JSONLineParser()))
    }
    public static func events(response: BackendDockerByteStream, secretValues: [String] = []) throws -> BackendDockerRecordStream {
        try requireSuccess(response)
        do { _ = try SecretMasker(secretValues: secretValues) }
        catch { response.cancel(); throw error }
        return transform(response, parser: EventsAdapter(lines: try JSONLineParser(), secrets: secretValues))
    }

    private static func transform<P: BackendDockerRecordParser>(_ response: BackendDockerByteStream, parser: P) -> BackendDockerRecordStream {
        let pair = AsyncThrowingStream<NativeRPCValue, Error>.makeStream(bufferingPolicy: .bufferingOldest(maximumQueuedRecords))
        let lifetime = BackendDockerStreamLifetime(cancelSource: response.cancel)
        pair.continuation.onTermination = { _ in lifetime.cancel() }
        let task = Task {
            var parser = parser
            defer { lifetime.cancel() }
            do {
                for try await bytes in response.data {
                    try Task.checkCancellation()
                    try emit(try parser.consume(bytes), to: pair.continuation)
                }
                try Task.checkCancellation()
                try emit(try parser.finish(), to: pair.continuation)
                pair.continuation.finish()
            } catch { pair.continuation.finish(throwing: safeError(error)) }
        }
        lifetime.install(task)
        return BackendDockerRecordStream(records: pair.stream, cancel: {
            lifetime.cancel()
            pair.continuation.finish(throwing: NativeRPCError(code: "cancelled", message: "The Docker stream was closed."))
        })
    }
    private static func emit(_ values: [NativeRPCValue], to continuation: AsyncThrowingStream<NativeRPCValue, Error>.Continuation) throws {
        for value in values {
            switch continuation.yield(value) {
            case .enqueued: break
            case .dropped: throw BackendDockerStreams.overflow("Docker output exceeded the stream queue limit.")
            case .terminated: throw CancellationError()
            @unknown default: throw BackendDockerStreams.protocolError("The Docker stream could not accept output.")
            }
        }
    }
    private static func requireSuccess(_ response: BackendDockerByteStream) throws {
        guard response.status == 200 else {
            response.cancel()
            throw NativeRPCError(code: response.status == 404 ? "docker-resource-missing" : "docker-api", message: "Docker could not open that stream.")
        }
    }
    static func safeError(_ error: Error) -> NativeRPCError {
        if error is CancellationError { return NativeRPCError(code: "cancelled", message: "The Docker stream was closed.") }
        if let rpc = error as? NativeRPCError {
            let messages = ["docker-protocol": "Docker sent invalid streaming data.",
                            "docker-stream-overflow": "Docker output exceeded the stream safety limit.",
                            "docker-resource-missing": "That Docker resource is no longer available.",
                            "docker-permission": "Docker access was refused.",
                            "docker-not-found": "Docker is not available on that server.",
                            "docker-api": "The Docker connection stopped unexpectedly.",
                            "cancelled": "The Docker stream was closed."]
            if let message = messages[rpc.code] { return NativeRPCError(code: rpc.code, message: message) }
        }
        return NativeRPCError(code: "docker-api", message: "The Docker connection stopped unexpectedly.")
    }
    private static func number(_ value: NativeRPCValue) -> Double { max(0, value.number ?? 0) }
    private static func overflow(_ message: String) -> NativeRPCError { NativeRPCError(code: "docker-stream-overflow", message: message) }
    private static func protocolError(_ message: String) -> NativeRPCError { NativeRPCError(code: "docker-protocol", message: message) }

    private struct LogsAdapter: BackendDockerRecordParser {
        var parser: LogParser
        mutating func consume(_ data: Data) throws -> [NativeRPCValue] { try parser.consume(data).map(\.value) }
        mutating func finish() throws -> [NativeRPCValue] { try parser.finish().map(\.value) }
    }
    private struct StatsAdapter: BackendDockerRecordParser {
        var lines: JSONLineParser
        var stats = StatsParser()
        mutating func consume(_ data: Data) throws -> [NativeRPCValue] { try lines.consume(data).map { try stats.record($0) } }
        mutating func finish() throws -> [NativeRPCValue] { try lines.finish().map { try stats.record($0) } }
    }
    private struct EventsAdapter: BackendDockerRecordParser {
        var lines: JSONLineParser
        let secrets: [String]
        mutating func consume(_ data: Data) throws -> [NativeRPCValue] { try lines.consume(data).map { try BackendDockerStreams.eventRecord($0, secretValues: secrets) } }
        mutating func finish() throws -> [NativeRPCValue] { try lines.finish().map { try BackendDockerStreams.eventRecord($0, secretValues: secrets) } }
    }
}

public struct BackendDockerRecordStream: Sendable {
    public let records: AsyncThrowingStream<NativeRPCValue, Error>
    public let cancel: @Sendable () -> Void
    public init(records: AsyncThrowingStream<NativeRPCValue, Error>, cancel: @escaping @Sendable () -> Void) {
        self.records = records; self.cancel = cancel
    }
}

private protocol BackendDockerRecordParser: Sendable {
    mutating func consume(_ data: Data) throws -> [NativeRPCValue]
    mutating func finish() throws -> [NativeRPCValue]
}

/// Cancellation can race task installation and stream termination. Only the
/// connection closure and Task handle cross threads, guarded by this lock.
private final class BackendDockerStreamLifetime: @unchecked Sendable {
    private let lock = NSLock()
    private var task: Task<Void, Never>?
    private var stopped = false
    private let cancelSource: @Sendable () -> Void
    init(cancelSource: @escaping @Sendable () -> Void) { self.cancelSource = cancelSource }
    func install(_ task: Task<Void, Never>) {
        lock.lock(); let cancelNow = stopped; if !stopped { self.task = task }; lock.unlock()
        if cancelNow { task.cancel() }
    }
    func cancel() {
        lock.lock(); guard !stopped else { lock.unlock(); return }
        stopped = true; let task = task; self.task = nil; lock.unlock()
        task?.cancel(); cancelSource()
    }
}
