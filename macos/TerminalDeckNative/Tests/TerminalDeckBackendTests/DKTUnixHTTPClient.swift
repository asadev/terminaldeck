import Darwin
import Foundation

struct DKTHTTPClientReply: Sendable {
    let statusCode: Int
    let headers: [String: String]
    let body: Data
    let chunks: [Data]
    let wireData: Data
}

/// A bounded synchronous fixture client. Call it only with a private fixture's socketPath.
/// Finite replies only; production stream cancellation is tested through its transport seam.
enum DKTUnixHTTPClient {
    static func open(socketPath: String) throws -> DKTUnixHTTPConnection {
        .init(descriptor: try connect(socketPath: socketPath))
    }

    static func request(socketPath: String, method: String = "GET", target: String,
                        headers: [String: String] = [:], body: Data = Data()) throws -> DKTHTTPClientReply {
        guard !method.isEmpty, !method.contains(where: { $0.isWhitespace }), target.hasPrefix("/"),
              !target.contains("\r"), !target.contains("\n") else { throw DKTHTTPServerError.invalidRequest(400) }
        var fields = headers.reduce(into: [String: String]()) { $0[$1.key.lowercased()] = $1.value }
        fields["host"] = fields["host"] ?? "dkt-fixture"
        fields["connection"] = "close"
        fields["content-length"] = String(body.count)
        fields["transfer-encoding"] = nil
        var text = "\(method) \(target) HTTP/1.1\r\n"
        for (key, value) in fields.sorted(by: { $0.key < $1.key }) {
            guard !key.contains("\r"), !key.contains("\n"), !value.contains("\r"), !value.contains("\n") else {
                throw DKTHTTPServerError.invalidRequest(400)
            }
            text += "\(key): \(value)\r\n"
        }
        var wire = Data((text + "\r\n").utf8)
        wire.append(body)
        return try rawExchange(socketPath: socketPath, request: wire, method: method)
    }

    static func rawExchange(socketPath: String, request: Data, timeout: TimeInterval = 3,
                            method: String = "GET") throws -> DKTHTTPClientReply {
        guard timeout > 0, timeout <= 10, request.count <= 2 * 1_024 * 1_024 else { throw DKTHTTPServerError.invalidRequest(413) }
        let descriptor = try connect(socketPath: socketPath)
        defer { _ = Darwin.shutdown(descriptor, SHUT_RDWR); Darwin.close(descriptor) }
        try DKTUnixHTTPServer.send(request, descriptor: descriptor)
        let deadline = Date().addingTimeInterval(timeout)
        var incoming = Data()
        var bytes = [UInt8](repeating: 0, count: 8_192)
        while true {
            guard Date() < deadline else { throw DKTHTTPServerError.timedOut }
            let amount = bytes.withUnsafeMutableBytes { Darwin.recv(descriptor, $0.baseAddress, $0.count, 0) }
            if amount == 0 { break }
            if amount > 0 {
                guard incoming.count <= 8 * 1_024 * 1_024 - amount else { throw DKTHTTPServerError.invalidRequest(413) }
                incoming.append(contentsOf: bytes.prefix(amount))
                continue
            }
            if errno == EINTR { continue }
            guard errno == EAGAIN || errno == EWOULDBLOCK else { throw DKTHTTPServerError.disconnected }
            var event = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
            _ = Darwin.poll(&event, 1, 50)
        }
        return try decode(incoming, method: method)
    }

    private static func connect(socketPath: String) throws -> Int32 {
        var address = sockaddr_un()
        let bytes = Array(socketPath.utf8)
        try DKTUnixSocketPath.validateExistingParent(of: socketPath)
        var information = stat()
        guard lstat(socketPath, &information) == 0, information.st_mode & S_IFMT == S_IFSOCK else { throw DKTHTTPServerError.invalidSocketPath }
        let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw DKTHTTPServerError.systemCall("socket", errno) }
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { pointer in pointer.copyBytes(from: bytes); pointer[bytes.count] = 0 }
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else { let failure = errno; Darwin.close(descriptor); throw DKTHTTPServerError.systemCall("connect", failure) }
        var noSignal: Int32 = 1
        _ = setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
        guard fcntl(descriptor, F_SETFL, O_NONBLOCK) == 0 else {
            let failure = errno; Darwin.close(descriptor); throw DKTHTTPServerError.systemCall("fcntl", failure)
        }
        return descriptor
    }

    private static func decode(_ wire: Data, method: String) throws -> DKTHTTPClientReply {
        var remaining = wire
        var status = 0
        var headers: [String: String] = [:]
        while true {
            guard let delimiter = remaining.range(of: Data("\r\n\r\n".utf8)),
                  remaining.distance(from: remaining.startIndex, to: delimiter.lowerBound) <= 32_768,
                  let head = String(data: remaining[..<delimiter.lowerBound], encoding: .utf8) else {
                throw DKTHTTPServerError.invalidRequest(400)
            }
            let rows = head.components(separatedBy: "\r\n")
            let words = (rows.first ?? "").split(separator: " ")
            guard words.count >= 2, words[0] == "HTTP/1.1", let code = Int(words[1]) else { throw DKTHTTPServerError.invalidRequest(400) }
            status = code
            headers = [:]
            for row in rows.dropFirst() {
                guard let colon = row.firstIndex(of: ":") else { throw DKTHTTPServerError.invalidRequest(400) }
                headers[String(row[..<colon]).lowercased()] = row[row.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            }
            remaining = Data(remaining[delimiter.upperBound...])
            if status >= 100, status < 200, status != 101 { continue }
            break
        }
        if method == "HEAD" || status == 204 || status == 304 {
            guard remaining.isEmpty else { throw DKTHTTPServerError.invalidRequest(400) }
            return .init(statusCode: status, headers: headers, body: Data(), chunks: [], wireData: wire)
        }
        if headers["transfer-encoding"]?.lowercased() == "chunked" {
            var chunks: [Data] = []
            var body = Data()
            for _ in 0..<16_384 {
                guard let ending = remaining.range(of: Data("\r\n".utf8)),
                      let line = String(data: remaining[..<ending.lowerBound], encoding: .utf8),
                      let size = Int(line.split(separator: ";", maxSplits: 1).first ?? "", radix: 16), size >= 0 else {
                    throw DKTHTTPServerError.invalidRequest(400)
                }
                remaining = Data(remaining[ending.upperBound...])
                if size == 0 {
                    guard remaining == Data("\r\n".utf8) else { throw DKTHTTPServerError.invalidRequest(400) }
                    return .init(statusCode: status, headers: headers, body: body, chunks: chunks, wireData: wire)
                }
                guard size <= 8 * 1_024 * 1_024 - body.count, remaining.count >= size + 2 else { throw DKTHTTPServerError.invalidRequest(413) }
                let chunk = Data(remaining.prefix(size))
                guard Data(remaining.dropFirst(size).prefix(2)) == Data("\r\n".utf8) else { throw DKTHTTPServerError.invalidRequest(400) }
                chunks.append(chunk)
                body.append(chunk)
                remaining.removeFirst(size + 2)
            }
            throw DKTHTTPServerError.invalidRequest(413)
        }
        if let length = headers["content-length"] {
            guard let count = Int(length), count == remaining.count else { throw DKTHTTPServerError.invalidRequest(400) }
        }
        return .init(statusCode: status, headers: headers, body: remaining, chunks: [], wireData: wire)
    }
}

/// Raw bytes for stream/hijack tests, with explicit closure and a bounded read deadline.
final class DKTUnixHTTPConnection: @unchecked Sendable {
    private let lock = NSLock()
    private var descriptor: Int32

    fileprivate init(descriptor: Int32) { self.descriptor = descriptor }

    func write(_ bytes: Data) throws {
        try lock.withLock {
            guard descriptor >= 0 else { throw DKTHTTPServerError.disconnected }
            try DKTUnixHTTPServer.send(bytes, descriptor: descriptor)
        }
    }

    func readSome(timeout: TimeInterval = 3) throws -> Data {
        try lock.withLock {
            guard descriptor >= 0 else { throw DKTHTTPServerError.disconnected }
            guard timeout > 0, timeout <= 10 else { throw DKTHTTPServerError.timedOut }
            let deadline = Date().addingTimeInterval(timeout)
            var bytes = [UInt8](repeating: 0, count: 8_192)
            while Date() < deadline {
                let count = bytes.withUnsafeMutableBytes { Darwin.recv(descriptor, $0.baseAddress, $0.count, 0) }
                if count > 0 { return Data(bytes.prefix(count)) }
                if count == 0 { return Data() }
                if errno == EINTR { continue }
                guard errno == EAGAIN || errno == EWOULDBLOCK else { throw DKTHTTPServerError.disconnected }
                var event = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
                _ = Darwin.poll(&event, 1, 50)
            }
            throw DKTHTTPServerError.timedOut
        }
    }

    func close() {
        lock.withLock {
            guard descriptor >= 0 else { return }
            _ = Darwin.shutdown(descriptor, SHUT_RDWR)
            Darwin.close(descriptor)
            descriptor = -1
        }
    }

    deinit { close() }
}
