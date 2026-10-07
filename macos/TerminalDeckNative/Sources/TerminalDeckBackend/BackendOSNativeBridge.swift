import Foundation
import Darwin
import Security
@preconcurrency import Network
import TerminalDeckNativeCore

/// native-shell/bridge-server.ts in Swift. Optional compatibility transport for
/// remaining WKWebView screens; native SwiftUI callers use the same dispatcher
/// in process. It owns no domain state and never starts Node or Electron.
public actor BackendOSNativeBridge {
    /// Injectable byte transport for the same production parser/router. Tests
    /// supply immediate fake reads/writes; production wraps real NWConnection.
    public final class Connection: @unchecked Sendable {
        public typealias Read = @Sendable (Data?, Bool, Error?) -> Void
        public typealias Written = @Sendable (Error?) -> Void
        private let reader: @Sendable (Int, Int, @escaping Read) -> Void
        private let writer: @Sendable (Data?, @escaping Written) -> Void
        private let startAction: @Sendable () -> Void, cancelAction: @Sendable () -> Void
        private let observeAction: @Sendable (@escaping @Sendable () -> Void) -> Void
        public init(read: @escaping @Sendable (Int, Int, @escaping Read) -> Void,
                    write: @escaping @Sendable (Data?, @escaping Written) -> Void,
                    start: @escaping @Sendable () -> Void = {}, cancel: @escaping @Sendable () -> Void,
                    observeClose: @escaping @Sendable (@escaping @Sendable () -> Void) -> Void = { _ in }) {
            reader = read; writer = write; startAction = start; cancelAction = cancel; observeAction = observeClose
        }
        fileprivate convenience init(_ raw: NWConnection, queue: DispatchQueue) {
            self.init(read: { minimum, maximum, completion in raw.receive(minimumIncompleteLength: minimum, maximumLength: maximum) { bytes, _, complete, error in completion(bytes, complete, error) } },
                      write: { bytes, completion in raw.send(content: bytes, completion: .contentProcessed { completion($0) }) },
                      start: { raw.start(queue: queue) }, cancel: { raw.cancel() },
                      observeClose: { close in raw.stateUpdateHandler = { state in if case .failed = state { close() }; if case .cancelled = state { close() } } })
        }
        fileprivate func receive(minimumIncompleteLength: Int, maximumLength: Int, completion: @escaping Read) { reader(minimumIncompleteLength, maximumLength, completion) }
        fileprivate func send(content: Data?, completion: @escaping Written) { writer(content, completion) }
        fileprivate func start() { startAction() }
        fileprivate func cancel() { cancelAction() }
        fileprivate func observeClose(_ callback: @escaping @Sendable () -> Void) { observeAction(callback) }
    }
    public struct NetworkBindings: Sendable {
        public struct Listener: Sendable {
            public let port: Int
            public let close: @Sendable () -> Void
            public init(port: Int, close: @escaping @Sendable () -> Void) { self.port = port; self.close = close }
        }
        public let listen: @Sendable (Int, @escaping @Sendable (Connection) -> Void) async throws -> Listener
        public init(listen: @escaping @Sendable (Int, @escaping @Sendable (Connection) -> Void) async throws -> Listener) { self.listen = listen }
    }
    public struct Endpoint: Sendable {
        public let port: Int; public let token: String
        public var origin: String { "http://127.0.0.1:\(port)" }
        public var url: String { origin + "/?t=" + token }
        public var readyLine: String { "TD_NATIVE_READY " + url }
    }
    public struct Options: Sendable {
        public let rendererDirectory: URL; public let shimFile: URL; public let portFile: URL?
        public let maximumBodyBytes: Int; public let maximumQueuedBytes: Int; public let keepAlive: Duration
        public let network: NetworkBindings?, token: String?
        public let scheduleKeepAlive: @Sendable (Duration, @escaping @Sendable () -> Void) -> BackendOSTimer
        public let onClient: @Sendable () async throws -> Void
        public let log: @Sendable (String) -> Void
        public init(rendererDirectory: URL, shimFile: URL, portFile: URL? = nil, maximumBodyBytes: Int = 64 * 1024 * 1024,
                    maximumQueuedBytes: Int = 32 * 1024 * 1024, keepAlive: Duration = .seconds(15),
                    network: NetworkBindings? = nil, token: String? = nil,
                    scheduleKeepAlive: @escaping @Sendable (Duration, @escaping @Sendable () -> Void) -> BackendOSTimer = BackendOSNativeBridge.scheduleKeepAlive,
                    onClient: @escaping @Sendable () async throws -> Void = {}, log: @escaping @Sendable (String) -> Void = { _ in }) {
            self.rendererDirectory = rendererDirectory; self.shimFile = shimFile; self.portFile = portFile
            self.maximumBodyBytes = maximumBodyBytes; self.maximumQueuedBytes = maximumQueuedBytes; self.keepAlive = keepAlive
            self.network = network; self.token = token; self.scheduleKeepAlive = scheduleKeepAlive
            self.onClient = onClient; self.log = log
        }
    }
    public static let cookieName = "td_native", tokenHeader = "x-td-token"
    public static let contentSecurityPolicy = "default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; font-src 'self' data:; img-src 'self' data:; connect-src 'self'; frame-ancestors 'none'"
    private let options: Options
    private let dispatcher: BackendOSTraceDispatcher
    private let ownPorts: BackendDevOwnPorts
    private let context: NativeRPCContext
    private let queue = DispatchQueue(label: "terminaldeck.native.compatibility-http", qos: .userInitiated)
    private var listener: NWListener?
    private var injectedListener: NetworkBindings.Listener?
    private var generation = UUID()
    private var starting: CheckedContinuation<Int, Error>?
    private var endpoint: Endpoint?
    private var connections: [UUID: Connection] = [:]
    private var requestTasks: [UUID: Task<Void, Never>] = [:]
    private struct Stream { let connection: Connection; var queued: Int }
    private var streams: [UUID: Stream] = [:]
    private var heartbeat: BackendOSTimer?
    private var stopped = false

    public init(options: Options, dispatcher: BackendOSTraceDispatcher, ownPorts: BackendDevOwnPorts, ownerID: String) throws {
        guard options.rendererDirectory.isFileURL, options.rendererDirectory.path.hasPrefix("/"),
              options.shimFile.isFileURL, options.shimFile.path.hasPrefix("/"), options.maximumBodyBytes > 0,
              options.maximumQueuedBytes > 0, options.keepAlive > .zero else {
            throw NativeRPCError.invalidArguments("The native bridge needs absolute asset paths and positive transport limits.")
        }
        self.options = options; self.dispatcher = dispatcher; self.ownPorts = ownPorts
        context = .init(caller: .nativeApp, ownerID: ownerID)
    }
    public func start() async throws -> Endpoint {
        if let endpoint { return endpoint }
        guard !stopped, listener == nil, injectedListener == nil else { throw NativeRPCError(code: "unavailable", message: "The native bridge is already starting or has stopped.") }
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw NativeRPCError(code: "random", message: "The native bridge could not create its private token.") }
        let token = options.token ?? Data(bytes).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: options.rendererDirectory.path, isDirectory: &isDirectory), isDirectory.boolValue else { throw NativeRPCError(code: "assets-missing", message: "The renderer has not been built: out/renderer/index.html is missing.") }
        let preferred = options.portFile.flatMap(Self.rememberedPort)
        let port: Int
        do { port = try await listen(preferred ?? 0) }
        catch {
            guard preferred != nil, Self.busy(error) else { throw error }
            options.log("port \(preferred!) is taken, so the bridge is served on another one (saved pages start over there)")
            port = try await listen(0)
        }
        let result = Endpoint(port: port, token: token); endpoint = result
        await ownPorts.claim(port)
        if let file = options.portFile, preferred != port {
            do {
                let temp = URL(fileURLWithPath: file.path + ".\(getpid()).tmp")
                try Data("\(port)\n".utf8).write(to: temp)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temp.path)
                guard rename(temp.path, file.path) == 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
            } catch { options.log("could not remember port \(port): \(error.localizedDescription)") }
        }
        heartbeat = options.scheduleKeepAlive(options.keepAlive) { [weak self] in Task { await self?.keepAlive() } }
        return result
    }
    private static func busy(_ error: Error) -> Bool {
        if let error = error as? NWError, case .posix(let code) = error { return code == .EADDRINUSE || code == .EACCES }
        return false
    }
    private func listen(_ port: Int) async throws -> Int {
        if let network = options.network {
            let listener = try await network.listen(port) { [weak self] connection in Task { await self?.accept(connection) } }
            guard (1...65535).contains(listener.port) else { listener.close(); throw NativeRPCError(code: "unavailable", message: "The native bridge transport returned an invalid port.") }
            injectedListener = listener; return listener.port
        }
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: port == 0 ? .any : .init(rawValue: UInt16(port))!)
        let listener = try NWListener(using: parameters)
        self.listener = listener; generation = UUID(); let id = generation
        listener.stateUpdateHandler = { [weak self] state in Task { await self?.changed(state, generation: id) } }
        let queue = self.queue
        listener.newConnectionHandler = { [weak self] connection in Task { await self?.accept(Connection(connection, queue: queue)) } }
        do {
            return try await withCheckedThrowingContinuation { continuation in starting = continuation; listener.start(queue: queue) }
        } catch { listener.cancel(); self.listener = nil; throw error }
    }
    private func changed(_ state: NWListener.State, generation: UUID) {
        guard generation == self.generation else { return }
        switch state {
        case .ready:
            guard let port = listener?.port?.rawValue else { return }
            starting?.resume(returning: Int(port)); starting = nil
        case .failed(let error): starting?.resume(throwing: error); starting = nil; options.log("the listener reported: \(error.localizedDescription)")
        case .cancelled: starting?.resume(throwing: NativeRPCError(code: "closed", message: "The native bridge listener closed.")); starting = nil
        default: break
        }
    }
    private func accept(_ connection: Connection) {
        guard !stopped, endpoint != nil else { connection.cancel(); return }
        let id = UUID(); connections[id] = connection
        connection.observeClose { [weak self] in Task { await self?.drop(id) } }
        connection.start()
        requestTasks[id] = Task { [weak self] in await self?.handle(connection, id: id) }
    }
    private struct Request: Sendable { let method: String; let path: String; let headers: [String: String]; let body: Data }
    private struct Refusal: Error { let status: Int; let message: String }
    private func handle(_ connection: Connection, id: UUID) async {
        defer { requestTasks[id] = nil }
        do {
            let request = try await read(connection)
            try Task.checkCancellation()
            await route(request, connection: connection, id: id)
        } catch let error as Refusal {
            if error.status == 403 { await reply(connection, id: id, status: 403, body: Data("Forbidden.".utf8)) }
            else { await reply(connection, id: id, status: error.status, body: Self.errorBody(error.message), contentType: "application/json; charset=utf-8") }
        }
        catch { await reply(connection, id: id, status: 500, body: Data("The bridge could not answer that.".utf8)); options.log("a request failed: \(error.localizedDescription)") }
    }
    private func read(_ connection: Connection) async throws -> Request {
        var buffer = Data()
        let marker = Data("\r\n\r\n".utf8)
        while buffer.range(of: marker) == nil {
            if buffer.count > 16 * 1024 { throw Refusal(status: 431, message: "The HTTP headers are too large.") }
            buffer.append(try await receive(connection))
        }
        guard let end = buffer.range(of: marker) else { throw Refusal(status: 400, message: "The HTTP request is malformed.") }
        guard buffer.distance(from: buffer.startIndex, to: end.lowerBound) <= 16 * 1024 else { throw Refusal(status: 431, message: "The HTTP headers are too large.") }
        guard let head = String(data: buffer[..<end.lowerBound], encoding: .utf8) else { throw Refusal(status: 400, message: "The HTTP request is malformed.") }
        let lines = head.components(separatedBy: "\r\n"), first = lines[0].split(separator: " ").map(String.init)
        guard first.count == 3, first[1].hasPrefix("/"), first[2].hasPrefix("HTTP/1.") else { throw Refusal(status: 400, message: "The HTTP request is malformed.") }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { throw Refusal(status: 400, message: "The HTTP headers are malformed.") }
            let key = line[..<colon].lowercased(), value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            guard key.range(of: #"^[a-z0-9!#$%&'*+.^_`|~-]+$"#, options: .regularExpression) != nil, headers[key] == nil, !value.contains("\0") else { throw Refusal(status: 400, message: "The HTTP headers are malformed.") }
            headers[key] = value
        }
        // Authentication precedes body allocation: foreign pages cannot make
        // this control plane retain a 64 MiB body while being refused.
        guard let endpoint, Self.originAllowed(headers: headers, port: endpoint.port), Self.authorized(path: first[1], headers: headers, token: endpoint.token) else { throw Refusal(status: 403, message: "Forbidden.") }
        var body = Data(buffer[end.upperBound...]); buffer = Data()
        if headers["transfer-encoding"] != nil {
            guard headers["transfer-encoding"]?.lowercased() == "chunked", headers["content-length"] == nil else { throw Refusal(status: 400, message: "The HTTP body framing is malformed.") }
            body = try await chunks(connection, initial: body)
        } else {
            let text = headers["content-length"] ?? "0"
            guard text.range(of: #"^[0-9]+$"#, options: .regularExpression) != nil, let length = Int(text) else { throw Refusal(status: 400, message: "The HTTP body framing is malformed.") }
            guard length <= options.maximumBodyBytes else { throw Refusal(status: 413, message: "The request body is over the \(options.maximumBodyBytes)-byte limit.") }
            while body.count < length { body.append(try await receive(connection)) }
            guard body.count == length else { throw Refusal(status: 400, message: "The bridge does not carry pipelined requests.") }
        }
        return Request(method: first[0], path: first[1], headers: headers, body: body)
    }
    private func chunks(_ connection: Connection, initial: Data) async throws -> Data {
        var incoming = initial, body = Data(); let lineEnd = Data("\r\n".utf8)
        while true {
            while incoming.range(of: lineEnd) == nil {
                guard incoming.count <= 1024 else { throw Refusal(status: 400, message: "The HTTP chunk framing is malformed.") }
                incoming.append(try await receive(connection))
            }
            let end = incoming.range(of: lineEnd)!
            guard let line = String(data: incoming[..<end.lowerBound], encoding: .utf8), let token = line.components(separatedBy: ";").first,
                  !token.isEmpty, token.range(of: #"^[0-9a-fA-F]+$"#, options: .regularExpression) != nil,
                  let length = Int(token, radix: 16) else { throw Refusal(status: 400, message: "The HTTP chunk framing is malformed.") }
            incoming.removeSubrange(..<end.upperBound)
            guard length <= options.maximumBodyBytes - body.count else { throw Refusal(status: 413, message: "The request body is over the \(options.maximumBodyBytes)-byte limit.") }
            if length == 0 {
                // A zero chunk is followed by trailers and an empty line.
                while !incoming.starts(with: lineEnd) && incoming.range(of: Data("\r\n\r\n".utf8)) == nil {
                    guard incoming.count <= 16 * 1024 else { throw Refusal(status: 431, message: "The HTTP trailers are too large.") }
                    incoming.append(try await receive(connection))
                }
                if let trailersEnd = incoming.range(of: Data("\r\n\r\n".utf8)), incoming.distance(from: incoming.startIndex, to: trailersEnd.lowerBound) > 16 * 1024 {
                    throw Refusal(status: 431, message: "The HTTP trailers are too large.")
                }
                return body
            }
            while incoming.count < length + 2 { incoming.append(try await receive(connection)) }
            guard incoming.subdata(in: length..<(length + 2)) == lineEnd else { throw Refusal(status: 400, message: "The HTTP chunk framing is malformed.") }
            body.append(incoming.prefix(length)); incoming.removeFirst(length + 2)
        }
    }
    private func receive(_ connection: Connection) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, complete, error in
                if let error { continuation.resume(throwing: error) }
                else if let data, !data.isEmpty { continuation.resume(returning: data) }
                else { continuation.resume(throwing: NativeRPCError(code: "closed", message: complete ? "The native bridge client closed." : "The native bridge read returned no bytes.")) }
            }
        }
    }
    private func route(_ request: Request, connection: Connection, id: UUID) async {
        let pathname = String(request.path.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)[0])
        if pathname.hasPrefix("/__td/") {
            if pathname == "/__td/invoke" && request.method == "POST" { await call(request, connection: connection, id: id, send: false); return }
            if pathname == "/__td/send" && request.method == "POST" { await call(request, connection: connection, id: id, send: true); return }
            if pathname == "/__td/send-sync" { await reply(connection, id: id, status: 501, body: Self.errorBody("This app’s preload never uses sendSync, so the bridge does not carry it."), contentType: "application/json; charset=utf-8"); return }
            if pathname == "/__td/events" && request.method == "GET" {
                streams[id] = Stream(connection: connection, queued: 0)
                let head = Self.headers(status: 200, extras: ["Content-Type": "text/event-stream; charset=utf-8", "Connection": "keep-alive", "X-Accel-Buffering": "no"])
                connection.send(content: Data((head + ": connected\n\n").utf8), completion: { [weak self] error in if error != nil { Task { await self?.drop(id) } } })
                // Source native-shell/index uses hydrateOnce for this callback.
                do { try await options.onClient() } catch { options.log("a client hook threw: \(error.localizedDescription)") }
                // Detect a closed peer without polling or holding its resources.
                connection.receive(minimumIncompleteLength: 1, maximumLength: 1) { [weak self] _, _, _ in Task { await self?.drop(id) } }
                return
            }
            if pathname == "/__td/shim.js" && ["GET", "HEAD"].contains(request.method) {
                guard (try? options.shimFile.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else {
                    await reply(connection, id: id, status: 404, body: Data("The native shim has not been built: out/native-web/shim.js is missing. Build the native web bundle first.".utf8)); return
                }
                await replyFile(connection, id: id, file: options.shimFile, contentType: "text/javascript; charset=utf-8", headOnly: request.method == "HEAD"); return
            }
            await reply(connection, id: id, status: 404, body: Data("Not found.".utf8)); return
        }
        guard ["GET", "HEAD"].contains(request.method) else { await reply(connection, id: id, status: 405, body: Data("Method not allowed.".utf8), extras: ["Allow": "GET, HEAD"]); return }
        if pathname == "/" || pathname == "/index.html" {
            guard let html = try? String(contentsOf: options.rendererDirectory.appendingPathComponent("index.html"), encoding: .utf8) else { await reply(connection, id: id, status: 500, body: Data("The renderer has not been built: out/renderer/index.html is missing.".utf8)); return }
            guard let injected = Self.injectShim(html) else { await reply(connection, id: id, status: 500, body: Data("The renderer’s index.html has no <head> to load the shim from.".utf8)); return }
            var extras = ["Content-Security-Policy": Self.contentSecurityPolicy]
            if let endpoint, pathname == "/", Self.bootstrap(path: request.path, token: endpoint.token) { extras["Set-Cookie"] = "td_native=\(endpoint.token); HttpOnly; SameSite=Strict; Path=/" }
            await reply(connection, id: id, status: 200, body: Data(injected.utf8), contentType: "text/html; charset=utf-8", headOnly: request.method == "HEAD", extras: extras); return
        }
        let root = options.rendererDirectory.standardizedFileURL.resolvingSymlinksInPath()
        guard let candidate = Self.staticPath(root: root, pathname: pathname) else { await reply(connection, id: id, status: 404, body: Data("Not found.".utf8)); return }
        let real = candidate.resolvingSymlinksInPath()
        guard real.path.hasPrefix(root.path + "/"), (try? real.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { await reply(connection, id: id, status: 404, body: Data("Not found.".utf8)); return }
        await replyFile(connection, id: id, file: real, contentType: Self.contentType(for: real), headOnly: request.method == "HEAD")
    }
    private func call(_ request: Request, connection: Connection, id: UUID, send: Bool) async {
        let contentType = request.headers["content-type"]?.components(separatedBy: ";").first?.trimmingCharacters(in: .whitespaces).lowercased()
        guard contentType == "application/json" else { await reply(connection, id: id, status: 415, body: Self.errorBody("The body must be sent as application/json."), contentType: "application/json; charset=utf-8"); return }
        let call: (String, [NativeRPCValue])
        do { call = try Self.parseCall(request.body) }
        catch { await reply(connection, id: id, status: 400, body: Self.errorBody(error.localizedDescription), contentType: "application/json; charset=utf-8"); return }
        let caller = NativeRPCContext(caller: .nativeApp, ownerID: context.ownerID)
        if send {
            do { try await dispatcher.send(channel: call.0, arguments: call.1, context: caller) }
            catch { options.log("a send listener on \(call.0) threw: \(error.localizedDescription)") }
            await reply(connection, id: id, status: 204, body: Data()); return
        }
        let answer: NativeRPCValue
        do { answer = .object([.init("ok", .bool(true)), .init("value", try await dispatcher.invoke(channel: call.0, arguments: call.1, context: caller))]) }
        catch { answer = .object([.init("ok", .bool(false)), .init("error", .string(error.localizedDescription))]) }
        await reply(connection, id: id, status: 200, body: (try? answer.encodedJSON()) ?? Self.errorBody("The answer could not be turned into JSON."), contentType: "application/json; charset=utf-8")
    }
    public func clientCount() -> Int { streams.count }
    /// Source's boolean means accepted by at least one connected stream, not
    /// proof that a screen drew the event. Bytes retain their $bytes envelope.
    @discardableResult public func emit(channel: String, arguments: [NativeRPCValue]) -> Bool {
        guard !stopped, !streams.isEmpty else { return false }
        let value: NativeRPCValue = .object([.init("channel", .string(channel)), .init("args", .array(arguments))])
        guard let json = try? value.encodedJSON() else { options.log("a push on \(channel) could not be turned into JSON"); return false }
        let frame = Data("data: ".utf8) + json + Data("\n\n".utf8)
        return writeStreams(frame)
    }
    private func keepAlive() { _ = writeStreams(Data(": keep-alive\n\n".utf8)) }
    private func writeStreams(_ frame: Data) -> Bool {
        var sent = false
        for id in Array(streams.keys) {
            guard var stream = streams[id] else { continue }
            if stream.queued > options.maximumQueuedBytes {
                options.log("an event stream fell too far behind and was dropped"); drop(id); continue
            }
            stream.queued += frame.count; streams[id] = stream
            stream.connection.send(content: frame, completion: { [weak self] error in Task { await self?.written(id, count: frame.count, failed: error != nil) } })
            sent = true
        }
        return sent
    }
    private func written(_ id: UUID, count: Int, failed: Bool) {
        if failed { drop(id); return }
        // Read, then write back: `streams[id]?.queued = …streams[id]…` evaluates its right side inside
        // the dictionary's modify access and trapped as an exclusivity conflict on the first keep-alive.
        guard var stream = streams[id] else { return }
        stream.queued = max(0, stream.queued - count); streams[id] = stream
    }
    private func drop(_ id: UUID) {
        streams[id] = nil; requestTasks.removeValue(forKey: id)?.cancel()
        connections.removeValue(forKey: id)?.cancel()
    }
    public func close() async {
        guard !stopped else { return }; stopped = true
        heartbeat?.cancel(); heartbeat = nil; listener?.cancel(); listener = nil
        injectedListener?.close(); injectedListener = nil
        starting?.resume(throwing: NativeRPCError(code: "closed", message: "The native bridge stopped before serving.")); starting = nil
        for id in Array(connections.keys) { drop(id) }
        if let endpoint { await ownPorts.release(endpoint.port) }; endpoint = nil
    }
    private func reply(_ connection: Connection, id: UUID, status: Int, body: Data,
                       contentType: String = "text/plain; charset=utf-8", headOnly: Bool = false, extras: [String: String] = [:]) async {
        var headers = extras; headers["Content-Type"] = contentType; headers["Content-Length"] = String(body.count); headers["Connection"] = "close"
        let data = Data(Self.headers(status: status, extras: headers).utf8) + (headOnly ? Data() : body)
        await withCheckedContinuation { continuation in connection.send(content: data, completion: { _ in continuation.resume() }) }
        drop(id)
    }
    private func replyFile(_ connection: Connection, id: UUID, file: URL, contentType: String, headOnly: Bool) async {
        guard let handle = try? FileHandle(forReadingFrom: file), let size = (try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize else {
            await reply(connection, id: id, status: 404, body: Data("Not found.".utf8)); return
        }
        defer { try? handle.close(); drop(id) }
        do {
            try await write(connection, Data(Self.headers(status: 200, extras: ["Content-Type": contentType, "Content-Length": String(size), "Cache-Control": "no-cache", "Connection": "close"]).utf8))
            guard !headOnly else { return }
            while let data = try handle.read(upToCount: 64 * 1024), !data.isEmpty { try Task.checkCancellation(); try await write(connection, data) }
        } catch { /* headers are already sent; close a failed asset stream */ }
    }
    private func write(_ connection: Connection, _ data: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            })
        }
    }
    public static func scheduleKeepAlive(_ interval: Duration, fire: @escaping @Sendable () -> Void) -> BackendOSTimer {
        let task = Task { while !Task.isCancelled { do { try await Task.sleep(for: interval) } catch { return }; fire() } }
        return .init { task.cancel() }
    }
    private static func headers(status: Int, extras: [String: String]) -> String {
        let reason = [200: "OK", 204: "No Content", 400: "Bad Request", 403: "Forbidden", 404: "Not Found", 405: "Method Not Allowed", 413: "Content Too Large", 415: "Unsupported Media Type", 431: "Request Header Fields Too Large", 500: "Internal Server Error", 501: "Not Implemented"][status] ?? "Error"
        var fields = ["X-Content-Type-Options": "nosniff", "Referrer-Policy": "no-referrer", "Cache-Control": "no-store"]
        for (key, value) in extras { fields[key] = value }
        return "HTTP/1.1 \(status) \(reason)\r\n" + fields.keys.sorted().map { "\($0): \(fields[$0]!)\r\n" }.joined() + "\r\n"
    }
    private static func errorBody(_ message: String) -> Data { (try? NativeRPCValue.object([.init("ok", .bool(false)), .init("error", .string(message))]).encodedJSON()) ?? Data() }
    public static func failedLine(_ reason: String) -> String {
        let flat = reason.replacingOccurrences(of: #"[\r\n]+"#, with: " ", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
        return "TD_NATIVE_FAILED " + (flat.isEmpty ? "unknown reason" : flat)
    }
    public static func rememberedPort(_ file: URL) -> Int? {
        guard let raw = try? String(contentsOf: file, encoding: .utf8), let value = Double(raw.trimmingCharacters(in: .whitespacesAndNewlines)),
              value.isFinite, value.rounded(.towardZero) == value, value >= 1024, value <= 65535 else { return nil }
        return Int(value)
    }
    public static func originAllowed(headers: [String: String], port: Int) -> Bool {
        let host = "127.0.0.1:\(port)", origin = "http://" + host
        if headers["host"] != host { return false }
        if let from = headers["origin"], from != origin { return false }
        if let site = headers["sec-fetch-site"], site != "same-origin" && site != "none" { return false }
        return true
    }
    private static func sameSecret(_ given: String?, _ token: String) -> Bool {
        guard let given else { return false }; let a = Array(given.utf8), b = Array(token.utf8)
        guard a.count == b.count else { return false }; var different: UInt8 = 0
        for index in a.indices { different |= a[index] ^ b[index] }; return different == 0
    }
    public static func bootstrap(path: String, token: String) -> Bool {
        let split = path.components(separatedBy: "?")
        guard split.first == "/", split.count > 1,
              let components = URLComponents(string: "http://127.0.0.1/?" + split.dropFirst().joined(separator: "?")) else { return false }
        return sameSecret(components.queryItems?.first(where: { $0.name == "t" })?.value, token)
    }
    public static func authorized(path: String, headers: [String: String], token: String) -> Bool {
        if bootstrap(path: path, token: token) || sameSecret(headers[tokenHeader], token) { return true }
        for part in (headers["cookie"] ?? "").components(separatedBy: ";") {
            let split = part.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            if split.count == 2, split[0].trimmingCharacters(in: .whitespaces) == cookieName,
               sameSecret(split[1].trimmingCharacters(in: .whitespaces), token) { return true }
        }
        return false
    }
    public static func parseCall(_ body: Data) throws -> (String, [NativeRPCValue]) {
        let raw: NativeRPCValue
        do { raw = try NativeRPCValue.parseJSON(body, decodeBytes: true) }
        catch { throw NativeRPCError.malformed("The body is not JSON.") }
        guard raw.fields != nil else { throw NativeRPCError.malformed("The body must be an object.") }
        guard let channel = raw["channel"].string, channel.utf16.count <= 200, NativeChannelRegistry.isBridgeChannel(channel) else { throw NativeRPCError.malformed("That is not a channel the bridge carries.") }
        guard raw["args"] == .missing || raw["args"].elements != nil else { throw NativeRPCError.malformed("`args` must be an array.") }
        return (channel, raw["args"].elements ?? [])
    }
    public static func staticPath(root: URL, pathname: String) -> URL? {
        guard let decoded = pathname.removingPercentEncoding, decoded.hasPrefix("/"), !decoded.contains("\0"), !decoded.contains("\\"),
              !decoded.components(separatedBy: "/").contains("..") else { return nil }
        let relative = decoded.split(separator: "/").filter { $0 != "." }.joined(separator: "/")
        let candidate = root.appendingPathComponent(relative).standardizedFileURL
        guard candidate.path == root.path || candidate.path.hasPrefix(root.path + "/") else { return nil }; return candidate
    }
    public static func injectShim(_ html: String) -> String? {
        guard let range = html.range(of: #"<head(\s[^>]*)?>"#, options: [.regularExpression, .caseInsensitive]) else { return nil }
        return String(html[..<range.upperBound]) + "\n    <script src=\"/__td/shim.js\"></script>" + String(html[range.upperBound...])
    }
    public static func contentType(for file: URL) -> String {
        ["html": "text/html; charset=utf-8", "js": "text/javascript; charset=utf-8", "mjs": "text/javascript; charset=utf-8", "css": "text/css; charset=utf-8",
         "json": "application/json; charset=utf-8", "map": "application/json; charset=utf-8", "txt": "text/plain; charset=utf-8", "svg": "image/svg+xml",
         "png": "image/png", "jpg": "image/jpeg", "jpeg": "image/jpeg", "gif": "image/gif", "webp": "image/webp", "avif": "image/avif", "ico": "image/x-icon",
         "woff": "font/woff", "woff2": "font/woff2", "ttf": "font/ttf", "otf": "font/otf", "wasm": "application/wasm", "mp3": "audio/mpeg", "wav": "audio/wav",
         "ogg": "audio/ogg", "mp4": "video/mp4", "webm": "video/webm"][file.pathExtension.lowercased()] ?? "application/octet-stream"
    }
}
