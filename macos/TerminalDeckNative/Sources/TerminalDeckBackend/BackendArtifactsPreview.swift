import Foundation
import Darwin
import Security
@preconcurrency import Network
import TerminalDeckNativeCore

/// artifact-preview.ts: loopback-only project file previews, separate from
/// Safari/browser capture. Four roots, 20-minute idle expiry, token door,
/// canonical/descriptor path confinement, HEAD/ranges and 64-KB streaming.
/// Construction doesn't bind a port or read files.
public actor BackendArtifactsPreview {
    public struct Handle: Sendable {
        public let port: Int; public let secret: String
        public var wireValue: NativeRPCValue { .object([.init("port", .number(Double(port))), .init("secret", .string(secret))]) }
    }
    private let authority: BackendFilesystemAuthority
    private let announce: @Sendable (Int) async throws -> Void
    private final class Entry: @unchecked Sendable {
        let root: String; let secret: String; let context: NativeRPCContext
        var handle: Handle?; var transport: Transport?; var links: [String: String] = [:]
        var used = Date(); var idle: Task<Void, Never>?
        init(root: String, secret: String, context: NativeRPCContext) { self.root = root; self.secret = secret; self.context = context }
    }
    private var live: [String: Entry] = [:]
    private var starting: [String: Task<Handle, any Error>] = [:]
    public init(authority: BackendFilesystemAuthority, ownPorts: BackendDevOwnPorts,
                announce: @escaping @Sendable (Int) async throws -> Void) {
        self.authority = authority; self.announce = announce
        // Content previews intentionally aren't claimed as control-plane ports:
        // an authorized phone must be able to tunnel this token-protected page.
    }
    public func serve(root: String, context: NativeRPCContext) async throws -> Handle {
        let actual = try await authority.authorize(root, context: context).path
        if let entry = live[actual], let handle = entry.handle { touch(entry); return handle }
        if let task = starting[actual] { return try await task.value }
        let task = Task { try await self.open(root: actual, context: context) }
        starting[actual] = task; defer { starting[actual] = nil }
        return try await task.value
    }
    private func open(root: String, context: NativeRPCContext) async throws -> Handle {
        if live.count >= 4, let oldest = live.values.min(by: { $0.used < $1.used }) { await close(oldest.root) }
        var bytes = [UInt8](repeating: 0, count: 12)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw NativeRPCError(code: "preview", message: "A private preview URL could not be generated") }
        let secret = Data(bytes).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        let entry = Entry(root: root, secret: secret, context: context)
        let transport = Transport { [weak self, weak entry] request in
            guard let self, let entry else { return .empty(404) }
            return await self.answer(entry, request)
        }
        entry.transport = transport
        let port: Int
        do { port = try await transport.start(); try Task.checkCancellation() }
        catch { transport.stop(); throw error }
        if live.count >= 4, let oldest = live.values.min(by: { $0.used < $1.used }) { await close(oldest.root) }
        let handle = Handle(port: port, secret: secret); entry.handle = handle; live[root] = entry
        touch(entry)
        do {
            try await announce(port); try Task.checkCancellation()
            guard live[root] === entry else { throw CancellationError() }
        } catch { await close(root); throw error }
        return handle
    }
    public func link(root: String, token: String, relative: String) throws {
        guard !relative.hasPrefix("/"), !relative.contains("\0"), !relative.split(separator: "/").contains("..") else { throw NativeRPCError.invalidArguments("A preview link must remain project-relative") }
        let key = URL(fileURLWithPath: root).standardizedFileURL.resolvingSymlinksInPath().path
        live[key]?.links[token] = relative
    }
    public func current(root: String) -> Handle? { live[URL(fileURLWithPath: root).standardizedFileURL.resolvingSymlinksInPath().path]?.handle }
    public func stop(root: String) async {
        let key = URL(fileURLWithPath: root).standardizedFileURL.resolvingSymlinksInPath().path
        starting.removeValue(forKey: key)?.cancel()
        await close(key)
    }
    public func stopAll() async {
        starting.values.forEach { $0.cancel() }; starting.removeAll()
        for root in Array(live.keys) { await close(root) }
    }
    private func close(_ root: String) async {
        guard let entry = live.removeValue(forKey: root) else { return }
        entry.idle?.cancel(); entry.transport?.stop()
    }
    private func touch(_ entry: Entry) {
        entry.used = Date(); entry.idle?.cancel()
        entry.idle = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(20 * 60)) } catch { return }
            await self?.close(entry.root)
        }
    }
    private func answer(_ entry: Entry, _ request: Transport.Request) async -> Transport.Response {
        touch(entry)
        guard ["GET", "HEAD"].contains(request.method) else { return .empty(405) }
        guard request.target.utf8.count <= 2_048 else { return .empty(414) }
        let target = String(request.target.prefix { $0 != "?" && $0 != "#" })
        let door = "/" + entry.secret + "/~/"
        if target.hasPrefix(door) {
            guard let token = String(target.dropFirst(door.count)).removingPercentEncoding, let name = entry.links[token] else { return .empty(404) }
            let segments = name.split(separator: "/").map { String($0).addingPercentEncoding(withAllowedCharacters: Self.segmentCharacters) ?? "" }.joined(separator: "/")
            return .redirect("/" + entry.secret + "/" + segments)
        }
        guard let segments = Self.segments(target), segments.first == entry.secret else { return .empty(404) }
        var relative = segments.dropFirst().joined(separator: "/")
        do {
            var resolved = try await authority.resolve(root: entry.root, relative: relative, context: entry.context)
            if (try? resolved.path.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                relative += (relative.isEmpty ? "" : "/") + "index.html"
                resolved = try await authority.resolve(root: entry.root, relative: relative, context: entry.context)
            }
            let descriptor = try BackendFilesystemAuthority.openStable(resolved)
            var info = stat()
            guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { Darwin.close(descriptor); return .empty(404) }
            let size = Int64(info.st_size), range = Self.range(request.headers["range"], size: size)
            if case .unsatisfiable = range { Darwin.close(descriptor); return .rangeFailure(size) }
            let start: Int64, end: Int64, status: Int
            switch range { case .whole: start = 0; end = size - 1; status = 200; case .bytes(let a, let b): start = a; end = b; status = 206; case .unsatisfiable: Darwin.close(descriptor); return .rangeFailure(size) }
            let length = size == 0 ? 0 : end - start + 1
            var headers = ["Content-Type": Self.contentType(resolved.path.pathExtension), "Cache-Control": "no-store", "Accept-Ranges": "bytes", "X-Content-Type-Options": "nosniff", "Content-Length": String(length)]
            if status == 206 { headers["Content-Range"] = "bytes \(start)-\(end)/\(size)" }
            if request.method == "HEAD" || length == 0 { Darwin.close(descriptor); return .init(status: status, headers: headers, descriptor: nil, offset: 0, remaining: 0) }
            return .init(status: status, headers: headers, descriptor: descriptor, offset: start, remaining: length)
        } catch { return .empty(404) }
    }
    public static func segments(_ target: String) -> [String]? {
        guard target.hasPrefix("/") else { return nil }; var result: [String] = []
        for raw in target.dropFirst().split(separator: "/") {
            guard let decoded = String(raw).removingPercentEncoding, ![".", ".."].contains(decoded), !decoded.contains("\0"), !decoded.contains("/"), !decoded.contains("\\") else { return nil }
            result.append(decoded)
        }
        return result
    }
    public enum Range: Sendable { case whole, bytes(Int64, Int64), unsatisfiable }
    public static func range(_ header: String?, size: Int64) -> Range {
        guard let header, header.hasPrefix("bytes=") else { return .whole }
        let value = String(header.dropFirst(6)).trimmingCharacters(in: .whitespaces)
        if value.contains(",") { return .whole }
        guard let dash = value.firstIndex(of: "-") else { return .unsatisfiable }
        let first = String(value[..<dash]), last = String(value[value.index(after: dash)...])
        if first.isEmpty { guard let suffix = Int64(last), suffix > 0 else { return .unsatisfiable }; return .bytes(max(0, size - suffix), size - 1) }
        guard let start = Int64(first), start >= 0, start < size else { return .unsatisfiable }
        if last.isEmpty { return .bytes(start, size - 1) }
        guard let end = Int64(last), end >= start else { return .unsatisfiable }; return .bytes(start, min(end, size - 1))
    }
    private static let segmentCharacters = CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn: "/?#%"))
    private static func contentType(_ suffix: String) -> String {
        let types = ["html":"text/html; charset=utf-8", "htm":"text/html; charset=utf-8", "xhtml":"application/xhtml+xml; charset=utf-8", "css":"text/css; charset=utf-8", "js":"text/javascript; charset=utf-8", "mjs":"text/javascript; charset=utf-8", "json":"application/json; charset=utf-8", "map":"application/json; charset=utf-8", "txt":"text/plain; charset=utf-8", "md":"text/plain; charset=utf-8", "csv":"text/plain; charset=utf-8", "xml":"text/xml; charset=utf-8", "svg":"image/svg+xml", "png":"image/png", "jpg":"image/jpeg", "jpeg":"image/jpeg", "gif":"image/gif", "webp":"image/webp", "avif":"image/avif", "bmp":"image/bmp", "ico":"image/x-icon", "heic":"image/heic", "pdf":"application/pdf", "mp4":"video/mp4", "m4v":"video/mp4", "mov":"video/quicktime", "webm":"video/webm", "mp3":"audio/mpeg", "m4a":"audio/mp4", "wav":"audio/wav", "aac":"audio/aac", "flac":"audio/flac", "woff":"font/woff", "woff2":"font/woff2", "ttf":"font/ttf", "otf":"font/otf"]
        return types[suffix.lowercased()] ?? "application/octet-stream"
    }

    private final class Transport: @unchecked Sendable {
        struct Request: Sendable { let method: String; let target: String; let headers: [String: String] }
        struct Response: Sendable {
            let status: Int; let headers: [String: String]; let descriptor: Int32?; let offset: Int64; let remaining: Int64
            static func empty(_ code: Int) -> Self {
                var headers = ["Cache-Control":"no-store", "Content-Length":"0"]
                if code == 405 { headers["Allow"] = "GET, HEAD" }
                return .init(status: code, headers: headers, descriptor: nil, offset: 0, remaining: 0)
            }
            static func redirect(_ path: String) -> Self { .init(status: 302, headers: ["Location":path, "Cache-Control":"no-store", "Content-Length":"0"], descriptor: nil, offset: 0, remaining: 0) }
            static func rangeFailure(_ size: Int64) -> Self { .init(status: 416, headers: ["Content-Range":"bytes */\(size)", "Cache-Control":"no-store", "Content-Length":"0"], descriptor: nil, offset: 0, remaining: 0) }
        }
        private let handler: @Sendable (Request) async -> Response
        private let queue = DispatchQueue(label: "dev.terminaldeck.native.artifact-preview", qos: .utility)
        private var listener: NWListener?; private var pending: CheckedContinuation<Int, any Error>?; private var peers: [UUID: Peer] = [:]
        init(handler: @escaping @Sendable (Request) async -> Response) { self.handler = handler }
        func start() async throws -> Int {
            try await withCheckedThrowingContinuation { continuation in
                queue.async { [self] in
                    do {
                        let parameters = NWParameters.tcp; parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
                        let listener = try NWListener(using: parameters); self.listener = listener; pending = continuation
                        listener.stateUpdateHandler = { [weak self] state in
                            guard let self, let pending = self.pending else { return }
                            if case .ready = state, let port = self.listener?.port { self.pending = nil; pending.resume(returning: Int(port.rawValue)) }
                            else if case .failed = state { self.pending = nil; pending.resume(throwing: NativeRPCError(code: "preview", message: "The loopback preview listener could not start")); self.listener?.cancel() }
                        }
                        listener.newConnectionHandler = { [weak self] connection in
                            guard let self, self.peers.count < 64 else { connection.cancel(); return }
                            let id = UUID(), peer = Peer(connection: connection, queue: self.queue, handler: self.handler) { [weak self] in self?.peers[id] = nil }
                            self.peers[id] = peer; peer.start()
                        }
                        listener.start(queue: queue)
                    } catch { continuation.resume(throwing: error) }
                }
            }
        }
        func stop() { queue.async { [self] in listener?.cancel(); listener = nil; if let pending { self.pending = nil; pending.resume(throwing: CancellationError()) }; let values = Array(peers.values); peers.removeAll(); values.forEach { $0.close() } } }
        private final class Peer: @unchecked Sendable {
            private let connection: NWConnection; private let queue: DispatchQueue; private let handler: @Sendable (Request) async -> Response; private let ended: @Sendable () -> Void
            private var bytes = Data(); private var task: Task<Void, Never>?; private var descriptor: Int32?; private var offset: Int64 = 0; private var remaining: Int64 = 0; private var closed = false; private var dispatched = false
            init(connection: NWConnection, queue: DispatchQueue, handler: @escaping @Sendable (Request) async -> Response, ended: @escaping @Sendable () -> Void) { self.connection = connection; self.queue = queue; self.handler = handler; self.ended = ended }
            func start() {
                connection.stateUpdateHandler = { [weak self] state in switch state { case .ready: self?.receive(); case .failed, .cancelled: self?.close(); default: break } }
                queue.asyncAfter(deadline: .now() + .seconds(10)) { [weak self] in if self?.dispatched == false { self?.close() } }
                connection.start(queue: queue)
            }
            func close() { guard !closed else { return }; closed = true; task?.cancel(); if let descriptor { Darwin.close(descriptor); self.descriptor = nil }; connection.stateUpdateHandler = nil; connection.cancel(); ended() }
            private func receive() {
                connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [weak self] data, _, done, error in
                    guard let self, !self.closed else { return }
                    if let data { self.bytes.append(data) }
                    guard self.bytes.count <= 16 * 1024 else { self.close(); return }
                    if let range = self.bytes.range(of: Data([13,10,13,10])), !self.dispatched {
                        self.dispatched = true
                        let lines = String(decoding: self.bytes[..<range.lowerBound], as: UTF8.self).components(separatedBy: "\r\n"), first = (lines.first ?? "").split(separator: " ").map(String.init)
                        guard first.count == 3 else { self.close(); return }
                        var headers: [String:String] = [:]
                        for line in lines.dropFirst() { if let colon = line.firstIndex(of: ":") { let name = String(line[..<colon]).lowercased(); guard headers[name] == nil else { self.close(); return }; headers[name] = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces) } }
                        let request = Request(method: first[0], target: first[1], headers: headers)
                        self.task = Task { [weak self] in
                            guard let self else { return }
                            let response = await self.handler(request)
                            self.queue.async { [weak self] in
                                if let self { self.send(response) }
                                else if let descriptor = response.descriptor { Darwin.close(descriptor) }
                            }
                        }
                    } else if error != nil || done { self.close() } else { self.receive() }
                }
            }
            private func send(_ response: Response) {
                guard !closed else { if let fd = response.descriptor { Darwin.close(fd) }; return }
                descriptor = response.descriptor; offset = response.offset; remaining = response.remaining
                let reasons = [200:"OK",206:"Partial Content",302:"Found",404:"Not Found",405:"Method Not Allowed",414:"URI Too Long",416:"Range Not Satisfiable"]
                let header = "HTTP/1.1 \(response.status) \(reasons[response.status] ?? "Error")\r\n" + response.headers.map { "\($0.key): \($0.value)\r\n" }.joined() + "Connection: close\r\n\r\n"
                connection.send(content: Data(header.utf8), completion: .contentProcessed { [weak self] error in if error != nil { self?.close() } else { self?.chunk() } })
            }
            private func chunk() {
                guard !closed, remaining > 0, let descriptor else { close(); return }
                var buffer = [UInt8](repeating: 0, count: Int(min(remaining, 64 * 1024)))
                let count = buffer.withUnsafeMutableBytes { pread(descriptor, $0.baseAddress!, $0.count, off_t(offset)) }
                guard count > 0 else { close(); return }
                offset += Int64(count); remaining -= Int64(count)
                connection.send(content: Data(buffer.prefix(count)), completion: .contentProcessed { [weak self] error in if error != nil { self?.close() } else { self?.chunk() } })
            }
        }
    }
}
