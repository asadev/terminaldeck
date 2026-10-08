import Foundation
import TerminalDeckNativeCore

/// HTTP framing only. Docker's binary log framing belongs to BackendDockerStreams.
enum BackendDockerHTTP {
    static let delimiter = Data([13, 10, 13, 10])
    static let newline = Data([13, 10])

    static func protocolError(_ message: String = "Docker sent an invalid HTTP response.") -> NativeRPCError {
        .init(code: "docker-protocol", message: message)
    }
    static func overflow() -> NativeRPCError {
        .init(code: "docker-stream-overflow", message: "Docker sent more data than this view can safely hold. Close it and open it again.")
    }
    static func cancelled() -> NativeRPCError { .init(code: "cancelled", message: "The Docker connection was closed.") }
    static func safeError(_ error: Error) -> NativeRPCError {
        if error is CancellationError { return cancelled() }
        // Providers may attach SSH stderr even to a familiar error code. Keep
        // only the code; neither their message nor their details cross this seam.
        if let known = error as? NativeRPCError {
            switch known.code {
            case "docker-protocol": return protocolError()
            case "docker-stream-overflow": return overflow()
            case "docker-not-found": return .init(code: known.code, message: "Docker is not available on this connection.")
            case "docker-permission": return .init(code: known.code, message: "This account cannot use Docker on this connection.")
            case "cancelled": return cancelled()
            case "invalid-arguments": return .invalidArguments("The Docker request or connection settings are invalid.")
            default: break
            }
        }
        return .init(code: "unavailable", message: "The existing Docker connection stopped or could not be opened.")
    }

    static func token(_ text: String) -> Bool {
        !text.isEmpty && text.utf8.allSatisfy { byte in
            (48...57).contains(byte) || (65...90).contains(byte) || (97...122).contains(byte) || "!#$%&'*+-.^_`|~".utf8.contains(byte)
        }
    }

    static func encode(_ request: BackendDockerRequest, limits: BackendDockerTransportLimits, hijack: Bool, host: String = "docker") throws -> Data {
        try limits.validate()
        guard ["docker", "localhost:2019", "127.0.0.1:2019", "[::1]:2019"].contains(host) else {
            throw NativeRPCError.invalidArguments("The private server HTTP host is invalid.")
        }
        guard token(request.method), request.path.hasPrefix("/"), !request.path.hasPrefix("//"),
              request.path.utf8.allSatisfy({ (33...126).contains($0) && $0 != 35 }),
              request.body.count <= limits.maximumBodyBytes else {
            throw NativeRPCError.invalidArguments("The Docker HTTP request is invalid or too large.")
        }
        var headers: [String: String] = [:]
        for (name, value) in request.headers {
            let key = name.lowercased()
            guard token(name), headers[key] == nil,
                  value.utf8.allSatisfy({ $0 == 9 || (32...126).contains($0) }),
                  !["content-length", "transfer-encoding", "host", "connection", "upgrade"].contains(key) else {
                // Framing and destination come from this transport, never a caller.
                if ["connection", "upgrade"].contains(key), hijack,
                   (key == "connection" && value.lowercased() == "upgrade" || key == "upgrade" && value.lowercased() == "tcp") { continue }
                throw NativeRPCError.invalidArguments("A Docker HTTP header is invalid or changes connection framing.")
            }
            headers[key] = value
        }
        headers["host"] = host
        headers["content-length"] = String(request.body.count)
        headers["connection"] = hijack ? "Upgrade" : "close"
        if hijack { headers["upgrade"] = "tcp" }
        if !request.body.isEmpty, headers["content-type"] == nil { headers["content-type"] = "application/json" }
        var head = "\(request.method) \(request.path) HTTP/1.1\r\n"
        for key in headers.keys.sorted() { head += "\(key): \(headers[key]!)\r\n" }
        head += "\r\n"
        guard head.utf8.count <= limits.maximumHeaderBytes else { throw NativeRPCError.invalidArguments("The Docker HTTP request headers are too large.") }
        var bytes = Data(head.utf8); bytes.append(request.body); return bytes
    }

    static func head(_ bytes: Data) throws -> BackendDockerHTTPHead {
        guard let text = String(data: bytes, encoding: .isoLatin1) else { throw protocolError() }
        let lines = text.components(separatedBy: "\r\n")
        guard let statusLine = lines.first else { throw protocolError() }
        guard statusLine.utf8.allSatisfy({ $0 == 9 || $0 >= 32 && $0 != 127 }) else { throw protocolError() }
        let parts = statusLine.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count >= 2, ["HTTP/1.0", "HTTP/1.1"].contains(String(parts[0])),
              parts[1].count == 3, parts[1].utf8.allSatisfy({ (48...57).contains($0) }),
              let status = Int(parts[1]), (100...599).contains(status) else { throw protocolError() }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() where !line.isEmpty {
            guard let separator = line.firstIndex(of: ":") else { throw protocolError() }
            let name = String(line[..<separator]).lowercased()
            let value = String(line[line.index(after: separator)...]).trimmingCharacters(in: .whitespaces)
            guard token(name), value.utf8.allSatisfy({ $0 == 9 || $0 >= 32 && $0 != 127 }),
                  headers[name] == nil else { throw protocolError("Docker sent duplicate or invalid response headers.") }
            headers[name] = value
        }
        return .init(status: status, headers: headers)
    }
}

struct BackendDockerHTTPHead: Sendable {
    let status: Int
    let headers: [String: String]
}

/// One reader per response, with a bounded buffer across arbitrarily split headers.
actor BackendDockerHTTPExchange {
    private enum BackendDockerHTTPFraming { case empty, length(Int), chunked, eof, raw }
    private let source: BackendDockerHTTPSource
    private let limits: BackendDockerTransportLimits
    private var buffer = Data()
    private var framing: BackendDockerHTTPFraming = .empty
    private var chunkRemaining = 0
    private var needsChunkTerminator = false
    private var chunkFinished = false
    private var eof = false

    init(source: BackendDockerHTTPSource, limits: BackendDockerTransportLimits) { self.source = source; self.limits = limits }

    func readHead(method: String, hijack: Bool) async throws -> (BackendDockerHTTPHead, Bool) {
        var informational = 0
        while true {
            let bytes = try await readUntil(BackendDockerHTTP.delimiter, maximum: limits.maximumHeaderBytes)
            let head = try BackendDockerHTTP.head(bytes)
            source.diagnostic("http-status", count: head.status)
            if (100...199).contains(head.status), head.status != 101 {
                informational += 1
                guard informational <= 4 else { throw BackendDockerHTTP.protocolError("Docker sent too many interim HTTP responses.") }
                continue
            }
            if head.status == 101 {
                guard hijack, head.headers["content-length"] == nil, head.headers["transfer-encoding"] == nil,
                      head.headers["upgrade"]?.lowercased() == "tcp",
                      head.headers["connection"]?.lowercased().split(separator: ",").contains(where: { $0.trimmingCharacters(in: .whitespaces) == "upgrade" }) == true else { throw BackendDockerHTTP.protocolError("Docker sent an invalid terminal upgrade.") }
            }
            let upgraded = hijack && (head.status == 101 || head.status == 200 && head.headers["content-length"] == nil && head.headers["transfer-encoding"] == nil)
            if upgraded { framing = .raw; return (head, true) }
            guard head.status != 101 else { throw BackendDockerHTTP.protocolError("Docker upgraded a request that did not ask for a terminal.") }
            if method.uppercased() == "HEAD" || [204, 304].contains(head.status) { framing = .empty }
            else if let transfer = head.headers["transfer-encoding"] {
                guard head.headers["content-length"] == nil, transfer.lowercased() == "chunked" else { throw BackendDockerHTTP.protocolError("Docker sent ambiguous or unsupported body framing.") }
                framing = .chunked
            } else if let length = head.headers["content-length"] {
                guard !length.isEmpty, length.utf8.allSatisfy({ (48...57).contains($0) }), let count = Int(length) else { throw BackendDockerHTTP.protocolError() }
                framing = .length(count)
                source.diagnostic("http-length", count: count)
            } else { framing = .eof }
            return (head, false)
        }
    }

    func next() async throws -> Data? {
        switch framing {
        case .empty: return nil
        case .length(let remaining):
            guard remaining > 0 else { return nil }
            guard try await fill() else { throw BackendDockerHTTP.protocolError("Docker closed a response before its body was complete.") }
            let piece = take(min(remaining, min(buffer.count, limits.maximumReadBytes)))
            framing = .length(remaining - piece.count); return piece
        case .eof, .raw:
            guard try await fill() else { return nil }
            return take(min(buffer.count, limits.maximumReadBytes))
        case .chunked: return try await nextChunk()
        }
    }

    private func nextChunk() async throws -> Data? {
        if chunkFinished { return nil }
        if needsChunkTerminator {
            try await requireBytes(2)
            guard take(2) == BackendDockerHTTP.newline else { throw BackendDockerHTTP.protocolError("Docker sent an invalid chunk ending.") }
            needsChunkTerminator = false
        }
        if chunkRemaining == 0 {
            let line = try await readUntil(BackendDockerHTTP.newline, maximum: 4096)
            guard let text = String(data: line, encoding: .ascii), line.allSatisfy({ (32...126).contains($0) }) else { throw BackendDockerHTTP.protocolError() }
            let size = text.prefix { $0 != ";" }
            guard !size.isEmpty, size.utf8.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }),
                  let count = Int(size, radix: 16), count <= limits.maximumChunkBytes else { throw BackendDockerHTTP.protocolError("Docker sent an invalid or oversized HTTP chunk.") }
            if count == 0 {
                var trailerBytes = 0
                while true {
                    let trailer = try await readUntil(BackendDockerHTTP.newline, maximum: limits.maximumHeaderBytes - trailerBytes)
                    trailerBytes += trailer.count + 2
                    guard trailerBytes <= limits.maximumHeaderBytes else { throw BackendDockerHTTP.protocolError("Docker sent too many trailer headers.") }
                    if trailer.isEmpty { break }
                    guard let text = String(data: trailer, encoding: .isoLatin1), let colon = text.firstIndex(of: ":"),
                          BackendDockerHTTP.token(String(text[..<colon])),
                          trailer.allSatisfy({ $0 == 9 || $0 >= 32 && $0 != 127 }),
                          !["content-length", "transfer-encoding"].contains(String(text[..<colon]).lowercased()) else { throw BackendDockerHTTP.protocolError("Docker sent an invalid trailer header.") }
                }
                chunkFinished = true; return nil
            }
            chunkRemaining = count
        }
        guard try await fill() else { throw BackendDockerHTTP.protocolError("Docker closed a response inside an HTTP chunk.") }
        let piece = take(min(chunkRemaining, min(buffer.count, limits.maximumReadBytes)))
        chunkRemaining -= piece.count
        if chunkRemaining == 0 { needsChunkTerminator = true }
        return piece
    }

    private func readUntil(_ delimiter: Data, maximum: Int) async throws -> Data {
        guard maximum >= delimiter.count else { throw BackendDockerHTTP.protocolError("Docker sent oversized HTTP headers.") }
        while true {
            if let range = buffer.range(of: delimiter) {
                guard range.upperBound <= maximum else { throw BackendDockerHTTP.protocolError("Docker sent oversized HTTP headers.") }
                let answer = Data(buffer[..<range.lowerBound]); buffer = Data(buffer[range.upperBound...]); return answer
            }
            guard buffer.count < maximum else { throw BackendDockerHTTP.protocolError("Docker sent oversized HTTP headers.") }
            guard !eof, let bytes = try await source.next() else { eof = true; throw BackendDockerHTTP.protocolError("Docker closed the connection before its HTTP response was complete.") }
            guard bytes.count <= limits.maximumBufferedBytes - buffer.count else { throw BackendDockerHTTP.overflow() }
            buffer.append(bytes)
        }
    }
    private func fill() async throws -> Bool {
        if !buffer.isEmpty { return true }
        if eof { return false }
        guard let bytes = try await source.next() else { eof = true; return false }
        buffer = bytes; return true
    }
    private func requireBytes(_ count: Int) async throws {
        while buffer.count < count {
            guard !eof, let bytes = try await source.next() else { eof = true; throw BackendDockerHTTP.protocolError("Docker closed a response inside its HTTP framing.") }
            guard bytes.count <= limits.maximumBufferedBytes - buffer.count else { throw BackendDockerHTTP.overflow() }
            buffer.append(bytes)
        }
    }
    private func take(_ count: Int) -> Data { let piece = Data(buffer.prefix(count)); buffer = Data(buffer.dropFirst(count)); return piece }
}
