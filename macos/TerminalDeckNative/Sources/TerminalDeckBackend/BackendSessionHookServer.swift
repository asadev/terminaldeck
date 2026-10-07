import Foundation
import Dispatch
import Darwin
import CryptoKit
import TerminalDeckNativeCore

public struct BackendSessionHookEndpoint: Sendable {
    public let socketPath: String
    public let configPath: String
    public let sessionEnvironment: String
    public let appID: String
    public var metadata: NativeRPCValue { .object([.init("running", .bool(true)), .init("socketPath", .string(socketPath)), .init("configPath", .string(configPath))]) }
}

public struct BackendSessionHookOpenAnswer: Sendable {
    public enum Route: String, Sendable { case tab, system }
    public let route: Route
    public let line: String
    public init(route: Route, line: String) { self.route = route; self.line = line }
}

/// macOS source-compatible curl/HTTP hook endpoint. Its token is per-run and
/// lives only in a 0600 curl config. Provider settings contain stable paths.
public final class BackendSessionHookServer: @unchecked Sendable {
    public let endpoint: BackendSessionHookEndpoint
    private let source: any DispatchSourceRead
    private let token: String
    private let coordinator: BackendSessionHookCoordinator
    private let additionalContext: @Sendable (BackendSessionHookEvent) async throws -> String?
    private let openLink: (@Sendable (URL, String?) async throws -> BackendSessionHookOpenAnswer)?
    private let lock = NSLock()
    private var stopped = false
    private var clients = Set<Int32>()
    private static let contexts: [String: Set<String>] = ["claude": ["SessionStart", "UserPromptSubmit", "PostToolUse"],
        "codex": ["SessionStart", "PostToolUse"], "gemini": ["BeforeAgent", "AfterTool"]]
    private struct Request: Sendable { let path: String; let headers: [String: String]; let body: Data }
    public init(configuration: BackendAccountConfiguration, sessionEnvironment: String,
                coordinator: BackendSessionHookCoordinator,
                additionalContext: @escaping @Sendable (BackendSessionHookEvent) async throws -> String?,
                openLink: (@Sendable (URL, String?) async throws -> BackendSessionHookOpenAnswer)? = nil) throws {
        guard sessionEnvironment.range(of: "^[A-Z_][A-Z0-9_]*$", options: .regularExpression) != nil else { throw BackendSessionFailure.invalidInput("The native hook session marker is invalid.") }
        self.coordinator = coordinator; self.additionalContext = additionalContext; self.openLink = openLink
        let directory = configuration.dataDirectory.appendingPathComponent("hook", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var path = directory.appendingPathComponent("hook.sock").path
        if path.utf8.count > 100 {
            let hash = SHA256.hash(data: Data(configuration.dataDirectory.path.utf8)).map { String(format: "%02x", $0) }.joined().prefix(20)
            path = "/tmp/" + configuration.appID + "-hook-" + String(hash) + ".sock"
        }
        token = try BackendAccountFiles.randomHex(bytes: 24)
        endpoint = BackendSessionHookEndpoint(socketPath: path, configPath: directory.appendingPathComponent("hook-endpoint.conf").path,
            sessionEnvironment: sessionEnvironment, appID: configuration.appID)
        var address = try Self.address(path)
        if FileManager.default.fileExists(atPath: path) {
            let probe = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
            guard probe >= 0 else { throw BackendSessionFailure.unsupported("The existing hook endpoint could not be checked.") }
            let connected = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(probe, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
            Darwin.close(probe)
            guard connected != 0 else { throw BackendSessionFailure.unsupported("Another running copy owns this hook endpoint. It was left untouched.") }
            var info = stat()
            guard lstat(path, &info) == 0, (info.st_mode & S_IFMT) == S_IFSOCK, info.st_uid == geteuid(), Darwin.unlink(path) == 0 else {
                throw BackendSessionFailure.unsupported("A stale hook path could not be removed safely.")
            }
        }
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw BackendSessionFailure.unsupported("The native hook socket could not be created.") }
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        let bound = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        guard bound == 0, chmod(path, 0o600) == 0, listen(fd, 16) == 0, fcntl(fd, F_SETFL, O_NONBLOCK) == 0 else {
            Darwin.close(fd); Darwin.unlink(path); throw BackendSessionFailure.unsupported("The native hook socket could not be secured and started.")
        }
        do {
            let config = "unix-socket = \"\(Self.configQuoted(path))\"\nheader = \"x-\(configuration.appID)-token: \(token)\"\n"
            try BackendAccountFiles.writeAtomic(Data(config.utf8), to: URL(fileURLWithPath: endpoint.configPath))
        } catch { Darwin.close(fd); Darwin.unlink(path); throw error }
        source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .global(qos: .utility))
        source.setCancelHandler { Darwin.close(fd) }; source.setEventHandler { [weak self] in self?.accept(fd) }; source.resume()
    }
    private func accept(_ fd: Int32) {
        while true {
            let client = Darwin.accept(fd, nil, nil); if client < 0 { return }
            var user: uid_t = 0, group: gid_t = 0, pid: Int32 = 0, size = socklen_t(MemoryLayout<Int32>.size)
            guard getpeereid(client, &user, &group) == 0, user == geteuid(), getsockopt(client, SOL_LOCAL, LOCAL_PEERPID, &pid, &size) == 0 else { Darwin.close(client); continue }
            lock.lock(); let allowed = !stopped && clients.count < 32; if allowed { clients.insert(client) }; lock.unlock()
            guard allowed else { Darwin.close(client); continue }
            _ = fcntl(client, F_SETFD, FD_CLOEXEC)
            var timeout = timeval(tv_sec: 10, tv_usec: 0), noPipe: Int32 = 1
            _ = setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            _ = setsockopt(client, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            _ = setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noPipe, socklen_t(MemoryLayout<Int32>.size))
            DispatchQueue.global(qos: .utility).async { [self] in
                do { let request = try Self.read(client); Task { [pid] in await respond(request, peerPID: pid, fd: client); finish(client) } }
                catch { Self.send(fd: client, status: 400, body: Data()); finish(client) }
            }
        }
    }
    private func respond(_ request: Request, peerPID: Int32, fd: Int32) async {
        let tokenHeader = "x-" + endpoint.appID + "-token"
        guard Self.sameToken(request.headers[tokenHeader] ?? "", token) else { Self.send(fd: fd, status: 403, body: Data()); return }
        guard Self.hostIsLocal(request.headers["host"]) else { Self.send(fd: fd, status: 403, body: Data()); return }
        let segments = request.path.split(separator: "?").first?.split(separator: "/").map(String.init) ?? []
        if segments == ["open"] {
            let text = String(decoding: request.body, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            let urlText = (try? NativeRPCValue.parseJSON(request.body))?["url"].string ?? text
            let marker = request.headers["x-" + endpoint.appID + "-session"].flatMap { $0.isEmpty ? nil : $0 }
            var answer = BackendSessionHookOpenAnswer(route: .system, line: "Opening this address in the system browser.")
            if let url = URL(string: urlText), ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil,
               let openLink, let opened = try? await openLink(url, marker) { answer = opened }
            let line = answer.line.components(separatedBy: .newlines).joined(separator: " ")
            Self.send(fd: fd, status: 200, body: Data((answer.route.rawValue + "\n" + line + "\n").utf8))
            return
        }
        guard segments.count == 3, segments[0] == "hook", segments[1...].allSatisfy({ $0.range(of: "^[A-Za-z][A-Za-z0-9_-]{0,63}$", options: .regularExpression) != nil }) else { Self.send(fd: fd, status: 404, body: Data()); return }
        let marker = request.headers["x-" + endpoint.appID + "-session"].flatMap { $0.isEmpty ? nil : $0 }
        let event = BackendSessionHookEvent.parse(provider: segments[1], event: segments[2], sessionID: marker, body: request.body,
            environmentHeader: request.headers["x-" + endpoint.appID + "-agent-env"], peerPID: peerPID)
        var body = Data(), status = 204
        if Self.contexts[event.provider]?.contains(event.event) == true,
           let context = try? await additionalContext(event), !context.isEmpty {
            let reply = NativeRPCValue.object([.init("hookSpecificOutput", .object([.init("hookEventName", .string(event.event)), .init("additionalContext", .string(context))]))])
            body = (try? reply.encodedJSON()) ?? Data(); status = 200
        }
        Self.send(fd: fd, status: status, body: body)
        // Subscribers are after the response, so a slow usage consumer cannot
        // hold the user's CLI turn waiting on the hook itself.
        await coordinator.receive(event)
    }
    private static func read(_ fd: Int32) throws -> Request {
        var data = Data(), buffer = [UInt8](repeating: 0, count: 16 * 1024)
        let capacity = buffer.count
        var split: Range<Data.Index>?
        while split == nil {
            let count = Darwin.recv(fd, &buffer, capacity, 0)
            guard count > 0, data.count + count <= 64 * 1024 else { throw BackendSessionFailure.invalidInput("Hook headers are incomplete or too large.") }
            data.append(contentsOf: buffer.prefix(count)); split = data.range(of: Data("\r\n\r\n".utf8))
        }
        let header = String(decoding: data[..<split!.lowerBound], as: UTF8.self).components(separatedBy: "\r\n")
        let first = header[0].split(separator: " ")
        guard first.count == 3, first[0] == "POST", first[2].hasPrefix("HTTP/1.") else { throw BackendSessionFailure.invalidInput("The hook endpoint accepts HTTP POST only.") }
        var headers: [String: String] = [:]
        for line in header.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { throw BackendSessionFailure.invalidInput("A hook header is malformed.") }
            let name = line[..<colon].lowercased(), value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            guard headers[name] == nil else { throw BackendSessionFailure.invalidInput("Duplicate hook headers are refused.") }; headers[name] = value
        }
        guard headers["transfer-encoding"] == nil, let length = Int(headers["content-length"] ?? "0"), length >= 0, length <= 1024 * 1024 else {
            throw BackendSessionFailure.invalidInput("The hook body is unsupported or exceeds 1 MiB.")
        }
        var body = Data(data[split!.upperBound...])
        guard body.count <= length else { throw BackendSessionFailure.invalidInput("The hook request contained trailing data.") }
        while body.count < length {
            let count = Darwin.recv(fd, &buffer, min(capacity, length - body.count), 0)
            guard count > 0 else { throw BackendSessionFailure.invalidInput("The hook body ended early.") }; body.append(contentsOf: buffer.prefix(count))
        }
        return Request(path: String(first[1]), headers: headers, body: body)
    }
    private static func send(fd: Int32, status: Int, body: Data) {
        let reason = [200: "OK", 204: "No Content", 400: "Bad Request", 403: "Forbidden", 404: "Not Found"][status] ?? "Error"
        let bytes = Data("HTTP/1.1 \(status) \(reason)\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n".utf8) + body
        var position = 0
        while position < bytes.count {
            let count = bytes.withUnsafeBytes { Darwin.send(fd, $0.baseAddress?.advanced(by: position), bytes.count - position, 0) }
            guard count > 0 else { return }; position += count
        }
    }
    private static func sameToken(_ left: String, _ right: String) -> Bool {
        let a = Array(left.utf8), b = Array(right.utf8); var difference = UInt64(a.count ^ b.count)
        for i in 0..<max(a.count, b.count) { difference |= UInt64((i < a.count ? a[i] : 0) ^ (i < b.count ? b[i] : 0)) }
        return difference == 0
    }
    private static func configQuoted(_ value: String) -> String { value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") }
    private static func address(_ path: String) throws -> sockaddr_un {
        var address = sockaddr_un(); let bytes = Array(path.utf8CString)
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { throw BackendSessionFailure.invalidInput("The hook socket path is too long.") }
        address.sun_family = sa_family_t(AF_UNIX); address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { output in for i in bytes.indices { output[i] = UInt8(bitPattern: bytes[i]) } }
        return address
    }
    private func finish(_ fd: Int32) { lock.lock(); clients.remove(fd); lock.unlock(); Darwin.close(fd) }
    public func status() -> NativeRPCValue {
        lock.lock(); let running = !stopped; lock.unlock()
        return endpoint.metadata.setting("running", .bool(running))
    }
    public func stop() {
        lock.lock(); guard !stopped else { lock.unlock(); return }; stopped = true; let active = clients; lock.unlock()
        source.cancel(); for fd in active { _ = shutdown(fd, SHUT_RDWR) }; Darwin.unlink(endpoint.socketPath)
        // Config remains stable but no token is kept after the owner stops.
        try? FileManager.default.removeItem(atPath: endpoint.configPath)
    }
    deinit { stop() }
}

extension BackendSessionHookServer {
    /// TS hook-server.ts hostIsLocal: the port is stripped, not matched; no Host is not local.
    static func hostIsLocal(_ host: String?) -> Bool {
        guard let host, !host.isEmpty else { return false }
        let name = host.lowercased().replacingOccurrences(of: #":\d+$"#, with: "", options: .regularExpression)
        return name == "localhost" || name == "127.0.0.1" || name == "[::1]" || name == "::1"
    }
}
