import Darwin
import Foundation

/// An AF_UNIX fixture only: it never listens on a TCP port or uses a real Docker socket.
/// Blocking fixture I/O uses owned native threads, independent of Swift/GCD's
/// cooperative test workers. Explicit stop joins their bounded teardown.
final class DKTUnixHTTPServer: @unchecked Sendable {
    let socketPath: String
    private let handler: @Sendable (DKTHTTPRequest) -> DKTHTTPResponse
    private let lock = NSLock()
    private let listenerFinished = DispatchGroup()
    private let peersFinished = DispatchGroup()
    private var listener: Int32 = -1
    private var clients: [UUID: Int32] = [:]
    private var history: [DKTHTTPRequest] = []
    private var historyBytes = 0
    private var terminalInput: [Data] = []
    private var started = false
    private var stopped = false
    private var privateDirectory: String?
    private var createdDirectory = false
    private var directoryIdentity: (device: dev_t, inode: ino_t)?
    private var socketIdentity: (device: dev_t, inode: ino_t)?

    init(socketPath: String? = nil, handler: @escaping @Sendable (DKTHTTPRequest) -> DKTHTTPResponse) {
        if let socketPath { self.socketPath = socketPath }
        else {
            let directory = DKTUnixSocketPath.temporaryRoot + "/dkt-" + UUID().uuidString.lowercased()
            self.socketPath = directory + "/http.sock"
            self.privateDirectory = directory
        }
        self.handler = handler
    }

    var requests: [DKTHTTPRequest] { lock.withLock { history } }
    var activeConnectionCount: Int { lock.withLock { clients.count } }
    var hijackedBytes: [Data] { lock.withLock { terminalInput } }

    func start() throws {
        try lock.withLock {
            guard !started, !stopped else { throw DKTHTTPServerError.alreadyStarted }
            var address = sockaddr_un()
            let pathBytes = Array(socketPath.utf8)
            var descriptor: Int32 = -1
            var bound = false
            do {
                _ = try DKTUnixSocketPath.validateLexical(socketPath)
                if let privateDirectory {
                    // Only our generated leaf is created. Validate its existing
                    // root first, then resolve the new parent after mkdir.
                    try DKTUnixSocketPath.validateExistingParent(of: privateDirectory)
                    guard mkdir(privateDirectory, 0o700) == 0 else { throw DKTHTTPServerError.systemCall("mkdir", errno) }
                    createdDirectory = true
                    var directoryInformation = stat()
                    guard lstat(privateDirectory, &directoryInformation) == 0,
                          directoryInformation.st_mode & S_IFMT == S_IFDIR else {
                        throw DKTHTTPServerError.systemCall("lstat directory", errno)
                    }
                    directoryIdentity = (directoryInformation.st_dev, directoryInformation.st_ino)
                    guard chmod(privateDirectory, 0o700) == 0 else { throw DKTHTTPServerError.systemCall("chmod directory", errno) }
                }
                try DKTUnixSocketPath.validateExistingParent(of: socketPath)
                descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
                guard descriptor >= 0 else { throw DKTHTTPServerError.systemCall("socket", errno) }
                address.sun_family = sa_family_t(AF_UNIX)
                address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
                withUnsafeMutableBytes(of: &address.sun_path) { buffer in
                    buffer.copyBytes(from: pathBytes)
                    buffer[pathBytes.count] = 0
                }
                let bindResult = withUnsafePointer(to: &address) { pointer in
                    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                    }
                }
                guard bindResult == 0 else { throw DKTHTTPServerError.systemCall("bind", errno) }
                bound = true
                var information = stat()
                guard lstat(socketPath, &information) == 0 else { throw DKTHTTPServerError.systemCall("lstat", errno) }
                socketIdentity = (information.st_dev, information.st_ino)
                guard chmod(socketPath, 0o600) == 0 else { throw DKTHTTPServerError.systemCall("chmod", errno) }
                guard Darwin.listen(descriptor, 16) == 0 else { throw DKTHTTPServerError.systemCall("listen", errno) }
                guard fcntl(descriptor, F_SETFL, O_NONBLOCK) == 0 else { throw DKTHTTPServerError.systemCall("fcntl", errno) }
                let listeningDescriptor = descriptor
                listener = descriptor
                started = true
                let finished = listenerFinished
                finished.enter()
                Thread.detachNewThread { [weak self] in
                    Thread.current.name = "DKT Unix listener"
                    defer {
                        if let server = self { server.finishListener(listeningDescriptor) }
                        else { Darwin.close(listeningDescriptor) }
                        finished.leave()
                    }
                    while let server = self {
                        if !autoreleasepool(invoking: { server.acceptCycle(listeningDescriptor) }) { break }
                    }
                }
            } catch {
                if descriptor >= 0 { Darwin.close(descriptor) }
                if bound { cleanupSocket() }
                cleanupDirectory()
                throw error
            }
        }
    }

    func stop() { stop(waitForWorkers: true) }

    private func stop(waitForWorkers: Bool) {
        lock.withLock {
            stopped = true
            if listener >= 0 { _ = Darwin.shutdown(listener, SHUT_RDWR); listener = -1 }
            // Workers own close(). Holding the lock prevents a descriptor reuse race.
            for descriptor in clients.values { _ = Darwin.shutdown(descriptor, SHUT_RDWR) }
            cleanupSocket()
            cleanupDirectory()
        }
        if waitForWorkers {
            let deadline = DispatchTime.now() + 2
            _ = listenerFinished.wait(timeout: deadline)
            _ = peersFinished.wait(timeout: deadline)
        }
    }

    // The final weak listener reference may be released on that same thread.
    // Never join the current thread during deinitialization.
    deinit { stop(waitForWorkers: false) }

    private func finishListener(_ descriptor: Int32) {
        lock.withLock {
            if listener == descriptor { listener = -1 }
            Darwin.close(descriptor)
        }
    }

    private func acceptCycle(_ descriptor: Int32) -> Bool {
        guard lock.withLock({ !stopped && listener == descriptor }) else { return false }
        var event = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
        let ready = Darwin.poll(&event, 1, 100)
        if ready < 0 { return errno == EINTR }
        if ready == 0 { return true }
        if event.revents & Int16(POLLHUP | POLLERR | POLLNVAL) != 0 { return false }
        acceptAvailable(descriptor)
        return true
    }

    private func cleanupSocket() {
        guard let identity = socketIdentity else { return }
        var information = stat()
        if lstat(socketPath, &information) == 0,
           information.st_dev == identity.device, information.st_ino == identity.inode,
           information.st_mode & S_IFMT == S_IFSOCK { _ = Darwin.unlink(socketPath) }
        socketIdentity = nil
    }

    private func cleanupDirectory() {
        // rmdir cannot remove somebody else's files, unlike recursive fixture cleanup.
        guard createdDirectory, let privateDirectory, let identity = directoryIdentity else { return }
        var information = stat()
        guard lstat(privateDirectory, &information) == 0, information.st_dev == identity.device,
              information.st_ino == identity.inode, information.st_mode & S_IFMT == S_IFDIR else { return }
        if Darwin.rmdir(privateDirectory) == 0 { createdDirectory = false; directoryIdentity = nil }
    }

    private func acceptAvailable(_ descriptor: Int32) {
        while true {
            let accepted = lock.withLock { () -> (UUID, Int32)? in
                guard !stopped, listener == descriptor else { return nil }
                let client = Darwin.accept(descriptor, nil, nil)
                guard client >= 0 else { return nil }
                guard clients.count < 16 else { Darwin.close(client); return (UUID(), -1) }
                var noSignal: Int32 = 1
                _ = setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
                guard fcntl(client, F_SETFL, O_NONBLOCK) == 0 else { Darwin.close(client); return (UUID(), -1) }
                let id = UUID()
                clients[id] = client
                peersFinished.enter()
                return (id, client)
            }
            guard let (id, client) = accepted else { return }
            guard client >= 0 else { continue }
            Thread.detachNewThread { [self] in
                Thread.current.name = "DKT Unix peer"
                defer {
                    lock.withLock { clients[id] = nil; Darwin.close(client) }
                    peersFinished.leave()
                }
                autoreleasepool { serve(client) }
            }
        }
    }

    private func serve(_ descriptor: Int32) {
        let reader = DKTHTTPReader(descriptor: descriptor)
        do {
            let request = try reader.request()
            let recorded = lock.withLock { () -> Bool in
                let size = request.body.count + request.target.utf8.count
                    + request.headers.reduce(0) { $0 + $1.key.utf8.count + $1.value.utf8.count }
                guard history.count < 1_024, size <= 8 * 1_024 * 1_024 - historyBytes else { return false }
                history.append(request)
                historyBytes += size
                return true
            }
            guard recorded else {
                try write(.json(["message": "The test fixture request history reached its bounded limit"], statusCode: 503),
                          to: descriptor, method: request.method)
                return
            }
            try write(handler(request), to: descriptor, method: request.method)
        } catch let DKTHTTPServerError.invalidRequest(status) {
            try? write(.json(["message": "Malformed or oversized HTTP request"], statusCode: status), to: descriptor, method: "GET")
        } catch {
            // Peer closure/timeouts are expected cancellation paths. No request or secret is logged.
        }
    }

    private func write(_ response: DKTHTTPResponse, to descriptor: Int32, method: String) throws {
        guard response.streamChunks.count <= 16_384, response.body.count <= 8 * 1_024 * 1_024,
              response.streamChunks.reduce(0, { $0 + $1.count }) <= 8 * 1_024 * 1_024 - response.body.count else {
            throw DKTHTTPServerError.invalidRequest(500)
        }
        var headers = response.headers.reduce(into: [String: String]()) { $0[$1.key.lowercased()] = $1.value }
        let hijacked = response.statusCode == 101 && headers["upgrade"] != nil
        let noBody = method == "HEAD" || response.statusCode == 204 || response.statusCode == 304
        let chunked = !hijacked && !noBody && (!response.streamChunks.isEmpty || response.holdOpen || headers["transfer-encoding"]?.lowercased() == "chunked")
        headers["connection"] = hijacked ? "Upgrade" : "close"
        if hijacked { headers["transfer-encoding"] = nil; headers["content-length"] = nil }
        else if chunked { headers["transfer-encoding"] = "chunked"; headers["content-length"] = nil }
        else { headers["transfer-encoding"] = nil; headers["content-length"] = String(noBody && method != "HEAD" ? 0 : response.body.count) }
        var head = "HTTP/1.1 \(response.statusCode) \(Self.reason(response.statusCode))\r\n"
        for (key, value) in headers.sorted(by: { $0.key < $1.key }) {
            guard !key.contains("\r"), !key.contains("\n"), !value.contains("\r"), !value.contains("\n") else {
                throw DKTHTTPServerError.invalidRequest(500)
            }
            head += "\(key): \(value)\r\n"
        }
        head += "\r\n"
        try Self.send(Data(head.utf8), descriptor: descriptor)
        guard !noBody else { return }
        if hijacked {
            guard response.body.count + response.streamChunks.reduce(0, { $0 + $1.count }) <= 8 * 1_024 * 1_024 else {
                throw DKTHTTPServerError.invalidRequest(500)
            }
            try Self.send(response.body, descriptor: descriptor)
            for part in response.streamChunks { try Self.send(part, descriptor: descriptor); usleep(1_000) }
            if response.holdOpen { try holdUntilClosed(descriptor, captureInput: true) }
            return
        }
        if chunked {
            let parts = (response.body.isEmpty ? [] : [response.body]) + response.streamChunks
            guard parts.count <= 16_384, parts.reduce(0, { $0 + $1.count }) <= 8 * 1_024 * 1_024 else {
                throw DKTHTTPServerError.invalidRequest(500)
            }
            for part in parts where !part.isEmpty {
                try Self.send(Data((String(part.count, radix: 16) + "\r\n").utf8), descriptor: descriptor)
                try Self.send(part, descriptor: descriptor)
                try Self.send(Data("\r\n".utf8), descriptor: descriptor)
                // Distinct HTTP chunks test fragmented headers/payloads without relying on recv boundaries.
                usleep(1_000)
            }
            if response.holdOpen { try holdUntilClosed(descriptor) }
            else { try Self.send(Data("0\r\n\r\n".utf8), descriptor: descriptor) }
        } else { try Self.send(response.body, descriptor: descriptor) }
    }

    private func holdUntilClosed(_ descriptor: Int32, captureInput: Bool = false) throws {
        let deadline = Date().addingTimeInterval(30)
        var received = 0
        var bytes = [UInt8](repeating: 0, count: 4_096)
        while Date() < deadline, !lock.withLock({ stopped }) {
            var event = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
            let result = Darwin.poll(&event, 1, 100)
            if result < 0 { if errno == EINTR { continue }; return }
            if result > 0 {
                if event.revents & Int16(POLLHUP | POLLERR | POLLNVAL) != 0 { return }
                let amount = bytes.withUnsafeMutableBytes { Darwin.recv(descriptor, $0.baseAddress, $0.count, 0) }
                if amount == 0 { return }
                // A stream does not accept another request or an unbounded upload.
                if amount > 0 {
                    guard captureInput else { return }
                    received += amount
                    guard received <= 1_024 * 1_024 else { return }
                    let part = Data(bytes.prefix(amount))
                    guard lock.withLock({ () -> Bool in
                        guard terminalInput.count < 1_024 else { return false }
                        terminalInput.append(part)
                        return true
                    }) else { return }
                    continue
                }
                if errno != EINTR, errno != EAGAIN, errno != EWOULDBLOCK { return }
            }
        }
    }

    static func send(_ bytes: Data, descriptor: Int32) throws {
        let deadline = Date().addingTimeInterval(3)
        try bytes.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else { return }
            var offset = 0
            while offset < buffer.count {
                let written = Darwin.send(descriptor, base.advanced(by: offset), buffer.count - offset, 0)
                if written > 0 { offset += written; continue }
                if written < 0, errno == EINTR { continue }
                if written < 0, errno == EAGAIN || errno == EWOULDBLOCK {
                    guard Date() < deadline else { throw DKTHTTPServerError.timedOut }
                    var event = pollfd(fd: descriptor, events: Int16(POLLOUT), revents: 0)
                    _ = Darwin.poll(&event, 1, 100)
                    continue
                }
                throw DKTHTTPServerError.disconnected
            }
        }
    }

    private static func reason(_ status: Int) -> String {
        switch status {
        case 101: "Switching Protocols"
        case 200: "OK"
        case 201: "Created"
        case 204: "No Content"
        case 304: "Not Modified"
        case 400: "Bad Request"
        case 401: "Unauthorized"
        case 403: "Forbidden"
        case 404: "Not Found"
        case 409: "Conflict"
        case 413: "Content Too Large"
        case 431: "Request Header Fields Too Large"
        case 500: "Internal Server Error"
        case 503: "Service Unavailable"
        default: "Fixture Response"
        }
    }
}

private final class DKTHTTPReader {
    private let descriptor: Int32
    private let deadline = Date().addingTimeInterval(5)
    private var buffer = Data()
    private let maximumBody = 1_024 * 1_024

    init(descriptor: Int32) { self.descriptor = descriptor }

    func request() throws -> DKTHTTPRequest {
        let head = try through(Data("\r\n\r\n".utf8), limit: 32_768, status: 431)
        guard let text = String(data: head, encoding: .utf8), !text.contains("\0") else { throw DKTHTTPServerError.invalidRequest(400) }
        let rows = text.components(separatedBy: "\r\n")
        let words = (rows.first ?? "").split(separator: " ", omittingEmptySubsequences: false)
        guard words.count == 3, words[2] == "HTTP/1.1" || words[2] == "HTTP/1.0",
              Self.token(String(words[0])), words[1].hasPrefix("/"), !words[1].contains("#"),
              !words[1].utf8.contains(where: { $0 < 33 || $0 == 127 }) else {
            throw DKTHTTPServerError.invalidRequest(400)
        }
        var headers: [String: String] = [:]
        guard rows.count <= 129 else { throw DKTHTTPServerError.invalidRequest(431) }
        for row in rows.dropFirst() {
            guard let colon = row.firstIndex(of: ":") else { throw DKTHTTPServerError.invalidRequest(400) }
            let name = String(row[..<colon]).lowercased()
            let value = row[row.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            guard Self.token(name), !value.contains("\r"), !value.contains("\n"),
                  !value.unicodeScalars.contains(where: { $0.value < 32 && $0.value != 9 || $0.value == 127 }) else {
                throw DKTHTTPServerError.invalidRequest(400)
            }
            if headers[name] != nil {
                guard name != "content-length", name != "transfer-encoding", name != "host" else { throw DKTHTTPServerError.invalidRequest(400) }
                headers[name]! += ", " + value
            } else { headers[name] = value }
        }
        guard words[2] != "HTTP/1.1" || !(headers["host"] ?? "").isEmpty else { throw DKTHTTPServerError.invalidRequest(400) }
        guard headers["transfer-encoding"] == nil || headers["content-length"] == nil else { throw DKTHTTPServerError.invalidRequest(400) }
        if let transfer = headers["transfer-encoding"], transfer.lowercased() != "chunked" { throw DKTHTTPServerError.invalidRequest(400) }
        var length = 0
        if let lengthText = headers["content-length"] {
            guard !lengthText.isEmpty, lengthText.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }), let parsed = Int(lengthText) else { throw DKTHTTPServerError.invalidRequest(400) }
            guard parsed <= maximumBody else { throw DKTHTTPServerError.invalidRequest(413) }
            length = parsed
        }
        if headers["expect"]?.lowercased() == "100-continue" {
            try DKTUnixHTTPServer.send(Data("HTTP/1.1 100 Continue\r\n\r\n".utf8), descriptor: descriptor)
        }
        let body: Data
        if headers["transfer-encoding"] == nil { body = try take(length) }
        else { body = try chunkedBody() }
        return .init(method: String(words[0]), target: String(words[1]), headers: headers, body: body)
    }

    private func chunkedBody() throws -> Data {
        var body = Data()
        for _ in 0..<16_384 {
            let sizeLine = try through(Data("\r\n".utf8), limit: 8_192, status: 400)
            guard let sizeText = String(data: sizeLine, encoding: .utf8)?.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false).first,
                  !sizeText.isEmpty, sizeText.utf8.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }),
                  let size = Int(sizeText, radix: 16) else { throw DKTHTTPServerError.invalidRequest(400) }
            guard size <= maximumBody - body.count else { throw DKTHTTPServerError.invalidRequest(413) }
            if size == 0 {
                var trailerBytes = 0
                for _ in 0..<128 {
                    let trailer = try through(Data("\r\n".utf8), limit: 8_192, status: 431)
                    trailerBytes += trailer.count + 2
                    guard trailerBytes <= 32_768 else { throw DKTHTTPServerError.invalidRequest(431) }
                    if trailer.isEmpty { return body }
                    guard let line = String(data: trailer, encoding: .utf8), let colon = line.firstIndex(of: ":"),
                          Self.token(String(line[..<colon])),
                          !["content-length", "transfer-encoding", "host"].contains(String(line[..<colon]).lowercased()) else {
                        throw DKTHTTPServerError.invalidRequest(400)
                    }
                }
                throw DKTHTTPServerError.invalidRequest(431)
            }
            body.append(try take(size))
            guard try take(2) == Data("\r\n".utf8) else { throw DKTHTTPServerError.invalidRequest(400) }
        }
        throw DKTHTTPServerError.invalidRequest(413)
    }

    private func through(_ delimiter: Data, limit: Int, status: Int) throws -> Data {
        while true {
            if let range = buffer.range(of: delimiter) {
                guard buffer.distance(from: buffer.startIndex, to: range.lowerBound) <= limit else { throw DKTHTTPServerError.invalidRequest(status) }
                let value = Data(buffer[..<range.lowerBound])
                buffer.removeSubrange(buffer.startIndex..<range.upperBound)
                return value
            }
            guard buffer.count <= limit + delimiter.count else { throw DKTHTTPServerError.invalidRequest(status) }
            try receive()
        }
    }

    private func take(_ length: Int) throws -> Data {
        while buffer.count < length { try receive() }
        let value = Data(buffer.prefix(length))
        buffer.removeFirst(length)
        return value
    }

    private func receive() throws {
        var bytes = [UInt8](repeating: 0, count: 8_192)
        while true {
            guard Date() < deadline else { throw DKTHTTPServerError.timedOut }
            let read = bytes.withUnsafeMutableBytes { Darwin.recv(descriptor, $0.baseAddress, $0.count, 0) }
            if read > 0 { buffer.append(contentsOf: bytes.prefix(read)); return }
            if read == 0 { throw DKTHTTPServerError.disconnected }
            if errno == EINTR { continue }
            guard errno == EAGAIN || errno == EWOULDBLOCK else { throw DKTHTTPServerError.disconnected }
            var event = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
            _ = Darwin.poll(&event, 1, 100)
        }
    }

    private static func token(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.allSatisfy { byte in
            (48...57).contains(byte) || (65...90).contains(byte) || (97...122).contains(byte) || Array("!#$%&'*+-.^_`|~".utf8).contains(byte)
        }
    }
}
