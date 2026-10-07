import Foundation
@preconcurrency import Network
import TerminalDeckNativeCore

public struct BackendDeckCoreSecurityHTTPRequest: Sendable {
    public let method: String
    public let path: String
    public let headers: [String: String]
    public let body: Data
    public let remoteAddress: String
    public init(method: String, path: String, headers: [String: String], body: Data, remoteAddress: String = "127.0.0.1") {
        self.method = method; self.path = path; self.body = body; self.remoteAddress = remoteAddress
        self.headers = Dictionary(headers.map { ($0.key.lowercased(), $0.value) }, uniquingKeysWith: { _, newer in newer })
    }
}
public struct BackendDeckCoreSecurityHTTPResponse: Sendable {
    public let status: Int
    public let body: Data
    public let headers: [String: String]
    public init(status: Int, body: Data, headers: [String: String] = ["content-type": "application/json"]) { self.status = status; self.body = body; self.headers = headers }
    public static func empty(_ status: Int) -> Self { .init(status: status, body: Data()) }
    public static func json(_ value: NativeRPCValue, status: Int = 200) -> Self {
        guard let data = try? value.encodedJSON() else { return .empty(500) }; return .init(status: status, body: data)
    }
}
public struct BackendDeckCoreSecurityEndpoint: Sendable {
    public let port: Int
    /// Backend-only per-run secrets. Never put this struct into an IPC response.
    public let token: String
    public let unattendedToken: String
    public let url: URL
    public let callers: BackendDeckCoreSecurityCallerTable
}
public protocol BackendDeckCoreSecurityTaskHTTP: Sendable {
    func answer(method: String, path: String, authorization: String?, body: String) async throws -> BackendDeckCoreSecurityHTTPResponse
}
public typealias BackendDeckCoreSecurityHTTPHandler = @Sendable (BackendDeckCoreSecurityHTTPRequest, BackendMCPCancellation) async -> BackendDeckCoreSecurityHTTPResponse
public protocol BackendDeckCoreSecurityListening: Sendable {
    func start(port: Int) async throws -> Int
    func stop() async
}
public typealias BackendDeckCoreSecurityListenerFactory = @Sendable (@escaping BackendDeckCoreSecurityHTTPHandler) -> any BackendDeckCoreSecurityListening

public enum BackendDeckCoreSecurityMCPEra: String, Sendable { case legacy, modern }
/// The transport factory is backend-owned. Product peers must keep their
/// handlers behind the same control gate; neither the factory nor raw results
/// can be supplied by tool arguments or a remote caller.
public protocol BackendDeckCoreSecurityMCPExchangePeer: Sendable {
    var serverInfo: NativeRPCValue { get }
    func answer(method: String, parameters: NativeRPCValue, cancellation: BackendMCPCancellation) async throws -> NativeRPCValue
    func close() async
}
public typealias BackendDeckCoreSecurityMCPExchangeFactory = @Sendable (BackendDeckCoreSecurityMCPEra) -> any BackendDeckCoreSecurityMCPExchangePeer

/// Stateless per-exchange MCP gate. One control actor serves both HTTP roads.
public actor BackendDeckCoreSecurityServer {
    public typealias Listing = @Sendable ([BackendDeckCoreSecurityToolPolicy], BackendDeckCoreSecurityCaller, Set<String>?) throws -> [NativeRPCValue]
    /// Wraps one tools/call around the exact `control.call`, handing over the
    /// grant this exchange already matched and its actual request scope. The
    /// root supplies `BackendCompositionClientsSecurityAuthority.withAuthenticatedGrant`.
    /// It must run `operation` once; only the result that operation produced is
    /// answered (a wrapper cannot substitute or fabricate a result).
    public typealias AuthenticatedExchange = @Sendable (BackendDeckCoreSecurityGrant, BackendMCPCancellation,
        @escaping @Sendable () async -> Void) async throws -> Void
    /// Awaited before tools/list and server/discover (root: `clients.refreshPluginTools()`).
    public typealias BeforeListing = @Sendable () async throws -> Void
    public static let mcpPath = "/mcp"
    public static let serverName = "deck-control"
    public static let maximumBodyBytes = 256 * 1024
    public static let modernRevision = "2026-07-28"
    private static let legacyRevisions = ["2024-11-05", "2025-03-26", "2025-06-18", "2025-11-25"]
    public let control: BackendDeckCoreSecurityControl
    public let keys: BackendDeckCoreSecurityAccessKeyDoor?
    private let ownPorts: BackendDevOwnPorts
    private let listing: Listing
    private let authenticated: AuthenticatedExchange?
    private let beforeListing: BeforeListing?
    private let tasks: (any BackendDeckCoreSecurityTaskHTTP)?
    private var endpoint: BackendDeckCoreSecurityEndpoint?
    private var requestedTransport: (any BackendDeckCoreSecurityListening)?
    private let listenerFactory: BackendDeckCoreSecurityListenerFactory
    private var starting: Task<BackendDeckCoreSecurityEndpoint, Error>?
    private var epoch = 0
    private struct RequestKey: Hashable { let caller: String; let requestID: String }
    private var requests: [RequestKey: BackendMCPCancellation] = [:]
    public init(control: BackendDeckCoreSecurityControl, keys: BackendDeckCoreSecurityAccessKeyDoor? = nil,
                ownPorts: BackendDevOwnPorts, tasks: (any BackendDeckCoreSecurityTaskHTTP)? = nil,
                listenerFactory: @escaping BackendDeckCoreSecurityListenerFactory = { BackendDeckCoreSecurityNativeListening(handler: $0) },
                listing: @escaping Listing = { tools, caller, granted in
                    tools.filter { $0.visible(to: granted, caller: caller) && ($0.tool.advertised || ($0.tool.id == "tools.run" && caller.kind == .key)) }.map { $0.tool.wireValue }
                },
                authenticated: AuthenticatedExchange? = nil, beforeListing: BeforeListing? = nil) {
        self.control = control; self.keys = keys; self.ownPorts = ownPorts; self.tasks = tasks; self.listenerFactory = listenerFactory; self.listing = listing
        self.authenticated = authenticated; self.beforeListing = beforeListing
    }
    public func currentEndpoint() -> BackendDeckCoreSecurityEndpoint? { endpoint }
    public func start(port: Int? = nil, preferredPort: Int? = nil) async throws -> BackendDeckCoreSecurityEndpoint {
        if let endpoint { return endpoint }
        if let starting { return try await starting.value }
        guard port == nil || (0...65_535).contains(port!) else { throw NativeRPCError.invalidArguments("The requested MCP port is invalid.") }
        let version = epoch
        let task = Task { try await self.open(port: port, preferredPort: preferredPort, epoch: version) }
        starting = task
        defer { if epoch == version { starting = nil } }
        return try await task.value
    }
    private func open(port: Int?, preferredPort: Int?, epoch: Int) async throws -> BackendDeckCoreSecurityEndpoint {
        let token = try BackendAccountFiles.randomHex(bytes: 32)
        let unattendedToken = try BackendAccountFiles.randomHex(bytes: 32)
        let callers = BackendDeckCoreSecurityCallerTable()
        try await callers.set(token: token, grant: .init(attended: true, caller: { .local }))
        try await callers.set(token: unattendedToken, grant: .init(attended: false, caller: { .local }))
        // Requests cannot arrive with no credential table, even during listen startup.
        let handler: BackendDeckCoreSecurityHTTPHandler = { [weak self] request, cancellation in
            guard let self else { return .empty(503) }; return await self.respond(request, callers: callers, cancellation: cancellation)
        }
        let wanted = port ?? ((preferredPort ?? 0) > 0 ? preferredPort! : 0)
        let actual: Int
        var requested: (any BackendDeckCoreSecurityListening)?
        if wanted > 0 {
            let listener = listenerFactory(handler)
            do { actual = try await listener.start(port: wanted); requested = listener }
            catch {
                await listener.stop()
                guard port == nil, Self.portMayFallBack(error) else { throw error }
                let fallback = listenerFactory(handler)
                actual = try await fallback.start(port: 0); requested = fallback
            }
        } else {
            let listener = listenerFactory(handler); actual = try await listener.start(port: 0); requested = listener
        }
        guard epoch == self.epoch && !Task.isCancelled else { await requested?.stop(); await callers.clear(); throw BackendSessionFailure.closed }
        let live = BackendDeckCoreSecurityEndpoint(port: actual, token: token, unattendedToken: unattendedToken,
            url: URL(string: "http://127.0.0.1:\(actual)/mcp")!, callers: callers)
        await ownPorts.claim(actual)
        guard epoch == self.epoch && !Task.isCancelled else { await ownPorts.release(actual); await requested?.stop(); await callers.clear(); throw BackendSessionFailure.closed }
        requestedTransport = requested; endpoint = live; return live
    }
    private nonisolated static func portMayFallBack(_ error: Error) -> Bool {
        if case NWError.posix(let code) = error { return code == .EADDRINUSE || code == .EACCES }
        return false
    }
    public func stop() async {
        epoch += 1; let task = starting; starting = nil; task?.cancel()
        if let task { _ = try? await task.value }
        let live = endpoint; endpoint = nil
        for request in requests.values { request.cancel() }; requests.removeAll()
        if let live { await ownPorts.release(live.port); await live.callers.clear() }
        await requestedTransport?.stop(); requestedTransport = nil
    }
    /// Useful for native HTTP tests/adapters; peer guards are part of this method too.
    public func respond(_ request: BackendDeckCoreSecurityHTTPRequest, cancellation: BackendMCPCancellation = .init()) async -> BackendDeckCoreSecurityHTTPResponse {
        guard let endpoint else { return .empty(503) }; return await respond(request, callers: endpoint.callers, cancellation: cancellation)
    }
    private func respond(_ request: BackendDeckCoreSecurityHTTPRequest, callers: BackendDeckCoreSecurityCallerTable,
                         cancellation: BackendMCPCancellation) async -> BackendDeckCoreSecurityHTTPResponse {
        guard Self.isLoopback(request.remoteAddress), Self.hostIsLocal(request.headers["host"]), request.headers["origin"] == nil else { return Self.deny(403) }
        guard request.body.count <= Self.maximumBodyBytes else { return Self.deny(413) }
        let path = String(request.path.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)[0])
        if let tasks, path == "/tasks" || path.hasPrefix("/tasks/") {
            do { return try await tasks.answer(method: request.method, path: path, authorization: request.headers["authorization"], body: request.method == "POST" ? String(decoding: request.body, as: UTF8.self) : "") }
            catch { return Self.deny(500) }
        }
        let pathKey = path.hasPrefix("/mcp/") ? String(path.dropFirst(5)) : nil
        var grant = pathKey == nil ? await callers.match(authorization: request.headers["authorization"]) : nil
        if grant == nil, let keys { grant = await keys.grant(credential: pathKey ?? BackendDeckCoreSecurityCallerTable.bearerOf(request.headers["authorization"]), via: "this-mac", userAgent: request.headers["user-agent"]) }
        guard let grant else { return Self.deny(403) }
        let response: BackendDeckCoreSecurityHTTPResponse
        if path != "/mcp" && !(grant.keyID != nil && pathKey != nil) { response = Self.deny(404) }
        else if request.method != "POST" { response = Self.deny(405) }
        else if let parsed = try? NativeRPCValue.parseJSON(request.body, maximumBytes: Self.maximumBodyBytes) {
            await grant.noteClient(Self.clientNameOf(parsed))
            response = await serve(parsed: parsed, headers: request.headers, grant: grant, cancellation: cancellation)
        } else { response = Self.deny(400) }
        await grant.done(); return response
    }
    /// Same grant, exchange and gate for relay traffic; the relay owns the outer socket.
    public func answerRelay(authorization: String?, pathKey: String?, userAgent: String?, protocolVersion: String?,
                            body: Data, cancellation: BackendMCPCancellation) async -> BackendDeckCoreSecurityHTTPResponse {
        guard let keys, let grant = await keys.grant(credential: pathKey ?? BackendDeckCoreSecurityCallerTable.bearerOf(authorization), via: "internet", userAgent: userAgent, external: cancellation) else { return Self.relayNotFound }
        let response: BackendDeckCoreSecurityHTTPResponse
        do {
            let parsed = try NativeRPCValue.parseJSON(body, maximumBytes: Self.maximumBodyBytes)
            await grant.noteClient(Self.clientNameOf(parsed))
            var headers = ["content-type": "application/json", "accept": "application/json, text/event-stream"]
            if let protocolVersion { headers["mcp-protocol-version"] = protocolVersion }
            headers = Self.withStandardHeaders(headers, parsed: parsed)
            response = await serve(parsed: parsed, headers: headers, grant: grant, cancellation: cancellation)
        } catch { response = Self.rpcError(id: .null, code: -32700, message: "That request was not JSON.", status: 400) }
        await grant.done(); return response
    }
    public func serve(parsed: NativeRPCValue, headers: [String: String], grant: BackendDeckCoreSecurityGrant,
                      cancellation: BackendMCPCancellation) async -> BackendDeckCoreSecurityHTTPResponse {
        // mcp-serve's deliberate listen refusal is outside the SDK entry's header checks.
        let listeningRefusal = Self.isModern(parsed, headers: headers) && parsed["method"].string == "subscriptions/listen"
        if !listeningRefusal {
            if headers["content-type"]?.lowercased().contains("application/json") != true {
                return Self.rpcError(id: .null, code: -32000, message: "Unsupported Media Type: Content-Type must be application/json", status: 415)
            }
            if !Self.isModern(parsed, headers: headers) {
                let accept = headers["accept"] ?? ""
                if !accept.contains("application/json") || !accept.contains("text/event-stream") {
                    return Self.rpcError(id: .null, code: -32000, message: "Not Acceptable: Client must accept both application/json and text/event-stream", status: 406)
                }
            }
        }
        if let messages = parsed.elements {
            guard !messages.isEmpty, !messages.contains(where: { Self.isModern($0, headers: headers) }) else { return Self.rpcError(id: .null, code: -32600, message: "Invalid Request", status: 400) }
            var responses: [NativeRPCValue] = []
            for message in messages { let answer = await exchange(message, headers: headers, grant: grant, cancellation: cancellation)
                if answer.status != 202, let value = try? NativeRPCValue.parseJSON(answer.body) { responses.append(value) }
            }
            return responses.isEmpty ? .empty(202) : .json(.array(responses))
        }
        return await exchange(parsed, headers: headers, grant: grant, cancellation: cancellation)
    }
    /// Generic per-exchange server factory from mcp-serve.ts. The production
    /// overload above retains the concrete deck-control assembly unchanged.
    public nonisolated func serve(parsed: NativeRPCValue, headers: [String: String], cancellation: BackendMCPCancellation,
                                  factory: @escaping BackendDeckCoreSecurityMCPExchangeFactory) async -> BackendDeckCoreSecurityHTTPResponse {
        let modern = Self.isModern(parsed, headers: headers)
        let id = parsed["id"] == .missing ? NativeRPCValue.null : parsed["id"]
        if modern && parsed["method"].string == "subscriptions/listen" { return Self.rpcError(id: id, code: -32601, message: "subscriptions/listen is not offered: this server’s lists do not change.") }
        if headers["content-type"]?.lowercased().contains("application/json") != true { return Self.rpcError(id: .null, code: -32000, message: "Unsupported Media Type: Content-Type must be application/json", status: 415) }
        if !modern {
            let accept = headers["accept"] ?? ""
            if !accept.contains("application/json") || !accept.contains("text/event-stream") { return Self.rpcError(id: .null, code: -32000, message: "Not Acceptable: Client must accept both application/json and text/event-stream", status: 406) }
        }
        let messages = parsed.elements ?? [parsed]
        guard !messages.isEmpty else { return Self.rpcError(id: .null, code: -32600, message: "Invalid Request", status: 400) }
        for message in messages {
            guard message.fields != nil, message["jsonrpc"].string == "2.0", message["method"].string != nil else { return Self.rpcError(id: .null, code: -32600, message: "Invalid Request", status: 400) }
            if parsed.elements != nil && Self.isModern(message, headers: headers) { return Self.rpcError(id: .null, code: -32600, message: "Invalid Request", status: 400) }
            if modern, let refusal = Self.modernValidation(message, headers: headers) { return refusal }
        }
        let peer = factory(modern ? .modern : .legacy)
        var replies: [NativeRPCValue] = []
        for message in messages where message["id"] != .missing {
            let requestID = message["id"], method = message["method"].string ?? ""
            do {
                let operation = Task { try await peer.answer(method: method, parameters: message["params"], cancellation: cancellation) }
                let observer = cancellation.observe { operation.cancel() }
                defer { cancellation.removeObserver(observer) }
                var value = try await operation.value
                if modern {
                    if !value.has("resultType") { value = value.setting("resultType", .string("complete")) }
                    if ["tools/list", "prompts/list", "resources/list", "resources/templates/list", "resources/read", "server/discover"].contains(method) {
                        if value["ttlMs"].number == nil { value = value.setting("ttlMs", .number(0)) }
                        if value["cacheScope"].string == nil { value = value.setting("cacheScope", .string("private")) }
                    }
                    if value["_meta"] == .missing { value = value.setting("_meta", .object([.init("io.modelcontextprotocol/serverInfo", peer.serverInfo)])) }
                    else if value["_meta"].fields != nil && !value["_meta"].has("io.modelcontextprotocol/serverInfo") { value = value.setting("_meta", value["_meta"].setting("io.modelcontextprotocol/serverInfo", peer.serverInfo)) }
                }
                replies.append(.object([.init("jsonrpc", .string("2.0")), .init("id", requestID), .init("result", value)]))
            } catch let error as BackendDeckCoreSecurityProtocolError {
                replies.append(.object([.init("jsonrpc", .string("2.0")), .init("id", requestID), .init("error", .object([.init("code", .number(Double(error.code))), .init("message", .string(error.message)), .init("data", error.data)]))]))
            } catch {
                replies.append(.object([.init("jsonrpc", .string("2.0")), .init("id", requestID), .init("error", .object([.init("code", .number(-32603)), .init("message", .string(error.localizedDescription))]))]))
            }
        }
        await peer.close()
        guard !replies.isEmpty else { return .empty(202) }
        return .json(parsed.elements != nil ? .array(replies) : replies[0])
    }
    private func exchange(_ message: NativeRPCValue, headers: [String: String], grant: BackendDeckCoreSecurityGrant,
                          cancellation: BackendMCPCancellation) async -> BackendDeckCoreSecurityHTTPResponse {
        let id = message["id"]
        guard message.fields != nil, message["jsonrpc"].string == "2.0", let method = message["method"].string,
              id == .missing || id.string != nil || id.number != nil || id == .null else { return Self.rpcError(id: id == .missing ? .null : id, code: -32600, message: "Invalid Request", status: 400) }
        let modern = Self.isModern(message, headers: headers)
        // This intentionally precedes the modern envelope gate, matching mcp-serve.ts.
        if modern && method == "subscriptions/listen" { return Self.rpcError(id: id == .missing ? .null : id, code: -32601, message: "subscriptions/listen is not offered: this server’s lists do not change.") }
        if modern, let error = Self.modernValidation(message, headers: headers) { return error }
        if !modern, let version = headers["mcp-protocol-version"], !Self.legacyRevisions.contains(version) { return Self.rpcError(id: id == .missing ? .null : id, code: -32000, message: "Bad Request: Unsupported protocol version: \(version) (supported versions: \(Self.legacyRevisions.joined(separator: ", ")))", status: 400) }
        if id == .missing {
            if method == "notifications/cancelled" {
                requests[RequestKey(caller: grant.identity, requestID: message["params"]["requestId"].compact)]?.cancel()
            }
            return .empty(202)
        }
        let requestKey = RequestKey(caller: grant.identity, requestID: id.compact)
        guard requests[requestKey] == nil else { return Self.rpcError(id: id, code: -32600, message: "A request with this id is already in flight.", status: 400) }
        let scope = BackendMCPCancellation()
        requests[requestKey] = scope
        let grantWatch = grant.cancellation.observe { scope.cancel() }
        let requestWatch = cancellation.observe { scope.cancel() }
        defer { requests[requestKey] = nil; grant.cancellation.removeObserver(grantWatch); cancellation.removeObserver(requestWatch) }
        func result(_ value: NativeRPCValue) -> BackendDeckCoreSecurityHTTPResponse {
            var wire = value
            if modern {
                wire = wire.setting("resultType", .string("complete"))
                if method == "tools/list" || method == "server/discover" { wire = wire.setting("ttlMs", .number(0)).setting("cacheScope", .string("private")) }
                let info = NativeRPCValue.object([.init("name", .string(Self.serverName)), .init("version", .string("1.0.0"))])
                if wire["_meta"] == .missing { wire = wire.setting("_meta", .object([.init("io.modelcontextprotocol/serverInfo", info)])) }
                else if wire["_meta"].fields != nil && !wire["_meta"].has("io.modelcontextprotocol/serverInfo") { wire = wire.setting("_meta", wire["_meta"].setting("io.modelcontextprotocol/serverInfo", info)) }
            }
            return .json(.object([.init("jsonrpc", .string("2.0")), .init("id", id), .init("result", wire)]))
        }
        let caller = await grant.caller()
        guard !scope.isCancelled && !grant.cancellation.isCancelled else { return Self.deny(403) }
        let capabilities = NativeRPCValue.object([.init("tools", .object([]))]).merging(modern && grant.events != nil ? .object([.init("events", .object([]))]) : .object([]))
        switch method {
        case "initialize":
            if modern { return Self.rpcError(id: id, code: -32020, message: "an initialize request (legacy handshake) was sent with a modern MCP-Protocol-Version header", status: 400) }
            let requested = message["params"]["protocolVersion"].string ?? "2025-06-18"
            let revision = Self.legacyRevisions.contains(requested) ? requested : "2025-11-25"
            return result(.object([.init("protocolVersion", .string(revision)), .init("capabilities", capabilities),
                .init("serverInfo", .object([.init("name", .string(Self.serverName)), .init("version", .string("1.0.0"))])), .init("instructions", .string(Self.instructionsFor(grant: grant, caller: caller)))]))
        case "server/discover":
            guard modern else { return Self.rpcError(id: id, code: -32601, message: "Method not found") }
            // Discover carries no tool rows, so a failed refresh is reported, not fatal here.
            if let beforeListing { do { try await beforeListing() } catch { NSLog("[deck-control] tool refresh before discover failed: %@", error.localizedDescription) } }
            guard !scope.isCancelled && !grant.cancellation.isCancelled else { return Self.deny(403) }
            return result(.object([.init("supportedVersions", .array([.string(Self.modernRevision)])), .init("capabilities", capabilities),
                                  .init("instructions", .string(Self.instructionsFor(grant: grant, caller: caller))), .init("ttlMs", .number(0)), .init("cacheScope", .string("private"))]))
        case "ping": return result(.object([]))
        case "tools/list":
            do {
                // Fail closed: a listing must reflect current plugin code and grants.
                try await beforeListing?()
                guard !scope.isCancelled && !grant.cancellation.isCancelled else { return Self.deny(403) }
                return result(.object([.init("tools", .array(try listing(await control.tools(), caller, grant.tools)))]))
            }
            catch { return Self.rpcError(id: id, code: -32603, message: error.localizedDescription) }
        case "tools/call":
            guard let name = message["params"]["name"].string else { return Self.rpcError(id: id, code: -32602, message: "Invalid tools/call params") }
            // Refuse hidden names before dispatch: no log row revealing the hidden tool.
            if let allowed = grant.tools, !allowed.contains(name) { return result(Self.toolResult(value: .null, error: "no tool called \(name)")) }
            if let policy = await control.policy(named: name), !policy.visible(to: grant.tools, caller: caller) { return result(Self.toolResult(value: .null, error: "no tool called \(name)")) }
            let options = BackendDeckCoreSecurityCallOptions(caller: caller, attended: grant.attended, granted: grant.tools, cancellation: scope)
            let called = await Self.authenticatedCall(grant: grant, scope: scope, wrapper: authenticated) { [control] in
                await control.call(name: name, arguments: message["params"]["arguments"], options: options)
            }
            guard let called else { return result(Self.toolResult(value: .null, error: "the call could not be authenticated for this exchange")) }
            return result(Self.toolResult(value: called.value, error: called.ok ? nil : called.error ?? "the call failed"))
        case "events/list", "events/subscribe", "events/unsubscribe":
            guard modern, let events = grant.events, let keyID = grant.keyID else { return Self.rpcError(id: id, code: -32601, message: "Method not found", status: modern ? 404 : 200) }
            do {
                let value: NativeRPCValue
                if method == "events/list" { value = try await events.list() }
                else if method == "events/subscribe" { value = try await events.subscribe(keyID: keyID, via: grant.via ?? "this-mac", parameters: message["params"]) }
                else { value = try await events.unsubscribe(keyID: keyID, parameters: message["params"]) }
                return result(value)
            } catch let error as BackendDeckCoreSecurityProtocolError { return Self.rpcError(id: id, code: error.code, message: error.message, data: error.data) }
            catch { return Self.rpcError(id: id, code: -32603, message: error.localizedDescription) }
        default: return Self.rpcError(id: id, code: -32601, message: "Method not found", status: modern ? 404 : 200)
        }
    }
    /// Runs `call` at most once, inside the wrapper when one is installed, and
    /// answers only the result that `call` itself produced. A wrapper that
    /// refuses (throws before running it) or never runs it yields nil: no row,
    /// no result. A second invocation by the wrapper runs nothing.
    public nonisolated static func authenticatedCall(grant: BackendDeckCoreSecurityGrant, scope: BackendMCPCancellation,
        wrapper: AuthenticatedExchange?, call: @escaping @Sendable () async -> BackendDeckCoreSecurityCallResult) async -> BackendDeckCoreSecurityCallResult? {
        guard let wrapper else { return await call() }
        let once = BackendDeckCoreSecurityOnceResult()
        do {
            try await wrapper(grant, scope) {
                guard once.claim() else { return }
                once.store(await call())
            }
        } catch {
            if once.result == nil { NSLog("[deck-control] the authenticated exchange refused a call: %@", error.localizedDescription) }
        }
        return once.result
    }
    public nonisolated static func isLoopback(_ address: String) -> Bool { ["127.0.0.1", "::1", "::ffff:127.0.0.1"].contains(address) }
    public nonisolated static func hostIsLocal(_ host: String?) -> Bool {
        guard let host, !host.isEmpty else { return false }
        let name = host.lowercased().replacingOccurrences(of: #":\d+$"#, with: "", options: .regularExpression)
        return ["localhost", "127.0.0.1", "[::1]", "::1"].contains(name)
    }
    public nonisolated static func clientNameOf(_ parsed: NativeRPCValue) -> String? {
        for message in parsed.elements ?? [parsed] {
            let params = message["params"]
            let info = message["method"].string == "initialize" ? params["clientInfo"] : params["_meta"]["io.modelcontextprotocol/clientInfo"]
            if message["method"].string != "initialize" && info == .missing { continue }
            guard let name = info["name"].string else { return nil }; return name + (info["version"].string.map { " " + $0 } ?? "")
        }
        return nil
    }
    public nonisolated static func withStandardHeaders(_ original: [String: String], parsed: NativeRPCValue) -> [String: String] {
        guard parsed.fields != nil, let method = parsed["method"].string, parsed["id"] != .missing else { return original }
        var headers = original; headers["mcp-method"] = headerValue(method)
        if let field = nameFields[method], let name = parsed["params"][field].string { headers["mcp-name"] = headerValue(name) }; return headers
    }
    private nonisolated static let nameFields = ["tools/call": "name", "prompts/get": "name", "resources/read": "uri", "tasks/get": "taskId", "tasks/update": "taskId", "tasks/cancel": "taskId"]
    private nonisolated static func headerValue(_ text: String) -> String {
        text.range(of: #"^[\x21-\x7e](?:[\x20-\x7e]*[\x21-\x7e])?$"#, options: .regularExpression) != nil ? text : "=?base64?" + Data(text.utf8).base64EncodedString() + "?="
    }
    private nonisolated static func decodeHeader(_ text: String) -> String? {
        if text.hasPrefix("=?base64?") {
            guard text.hasSuffix("?="), let data = Data(base64Encoded: String(text.dropFirst(9).dropLast(2))) else { return nil }; return String(data: data, encoding: .utf8)
        }
        return text
    }
    private nonisolated static func isModern(_ parsed: NativeRPCValue, headers: [String: String]) -> Bool {
        parsed["params"]["_meta"].has("io.modelcontextprotocol/protocolVersion") || (headers["mcp-protocol-version"].map { $0 >= modernRevision } ?? false)
    }
    private nonisolated static func modernValidation(_ parsed: NativeRPCValue, headers: [String: String]) -> BackendDeckCoreSecurityHTTPResponse? {
        let id = parsed["id"] == .missing ? NativeRPCValue.null : parsed["id"]
        let meta = parsed["params"]["_meta"]
        if parsed["id"] == .missing {
            let revision = meta["io.modelcontextprotocol/protocolVersion"].string ?? headers["mcp-protocol-version"]
            if meta.has("io.modelcontextprotocol/protocolVersion") && meta["io.modelcontextprotocol/protocolVersion"].string == nil {
                return rpcError(id: id, code: -32602, message: "Invalid _meta envelope for protocol revision 2026-07-28: io.modelcontextprotocol/protocolVersion: expected a protocol version string", status: 400)
            }
            if let revision, revision != modernRevision { return rpcError(id: id, code: -32022, message: "Unsupported protocol version: \(revision)", status: 400) }
            if let header = headers["mcp-protocol-version"], let claim = meta["io.modelcontextprotocol/protocolVersion"].string, header != claim { return rpcError(id: id, code: -32020, message: "MCP-Protocol-Version header disagrees with the body envelope", status: 400) }
            if let header = headers["mcp-method"], decodeHeader(header) != parsed["method"].string { return rpcError(id: id, code: -32020, message: "Mcp-Method header disagrees with the body method", status: 400) }
            return nil
        }
        let versionKey = "io.modelcontextprotocol/protocolVersion", capabilitiesKey = "io.modelcontextprotocol/clientCapabilities"
        if !meta.has(versionKey) {
            let missing = meta.fields == nil ? ["_meta"] : [versionKey, capabilitiesKey].filter { !meta.has($0) }
            let version = headers["mcp-protocol-version"] ?? modernRevision
            return rpcError(id: id, code: -32602, message: "Invalid params: the MCP-Protocol-Version header names protocol revision \(version), but the request is missing the required per-request envelope key(s): \(missing.joined(separator: ", "))", data: .object([.init("envelope", .object([.init("missing", .array(missing.map(NativeRPCValue.string)))]))]), status: 400)
        }
        func envelopeIssue(_ key: String, _ problem: String) -> BackendDeckCoreSecurityHTTPResponse {
            rpcError(id: id, code: -32602, message: "Invalid _meta envelope for protocol revision 2026-07-28: \(key): \(problem)", data: .object([.init("envelope", .object([.init("key", .string(key)), .init("problem", .string(problem))]))]), status: 400)
        }
        if !meta.has(capabilitiesKey) { return envelopeIssue(capabilitiesKey, "missing") }
        guard let revision = meta[versionKey].string else { return envelopeIssue(versionKey, "Invalid input: expected string, received \(typeName(meta[versionKey]))") }
        guard meta[capabilitiesKey].fields != nil else { return envelopeIssue(capabilitiesKey, "Invalid input: expected object, received \(typeName(meta[capabilitiesKey]))") }
        let infoKey = "io.modelcontextprotocol/clientInfo"
        if meta.has(infoKey) {
            let info = meta[infoKey]
            if info.fields == nil { return envelopeIssue(infoKey, "Invalid input: expected object, received \(typeName(info))") }
            for field in ["name", "version"] where info[field].string == nil { return envelopeIssue(infoKey + "." + field, "Invalid input: expected string, received \(typeName(info[field]))") }
            for field in ["title", "websiteUrl", "description"] where info.has(field) && info[field].string == nil { return envelopeIssue(infoKey + "." + field, "Invalid input: expected string, received \(typeName(info[field]))") }
            if info.has("icons") {
                guard let icons = info["icons"].elements else { return envelopeIssue(infoKey + ".icons", "Invalid input: expected array, received \(typeName(info["icons"]))") }
                for (index, icon) in icons.enumerated() {
                    let prefix = infoKey + ".icons.\(index)"
                    if icon.fields == nil { return envelopeIssue(prefix, "Invalid input: expected object, received \(typeName(icon))") }
                    if icon["src"].string == nil { return envelopeIssue(prefix + ".src", "Invalid input: expected string, received \(typeName(icon["src"]))") }
                    if icon.has("mimeType") && icon["mimeType"].string == nil { return envelopeIssue(prefix + ".mimeType", "Invalid input: expected string, received \(typeName(icon["mimeType"]))") }
                    if icon.has("sizes") {
                        guard let sizes = icon["sizes"].elements else { return envelopeIssue(prefix + ".sizes", "Invalid input: expected array, received \(typeName(icon["sizes"]))") }
                        for (position, size) in sizes.enumerated() where size.string == nil { return envelopeIssue(prefix + ".sizes.\(position)", "Invalid input: expected string, received \(typeName(size))") }
                    }
                    if icon.has("theme") && !["light", "dark"].contains(icon["theme"].string ?? "") { return envelopeIssue(prefix + ".theme", "Invalid option: expected one of \"light\"|\"dark\"") }
                }
            }
        }
        let capabilities = meta[capabilitiesKey]
        for field in ["experimental", "sampling", "elicitation", "roots", "extensions"] where capabilities.has(field) {
            let value = capabilities[field], key = capabilitiesKey + "." + field
            if value.fields == nil { return envelopeIssue(key, "Invalid input: expected object, received \(typeName(value))") }
            if field == "experimental" || field == "extensions" {
                for entry in value.fields ?? [] where entry.value.fields == nil { return envelopeIssue(key + "." + entry.key, "Invalid input: expected object, received \(typeName(entry.value))") }
            }
            if field == "sampling" { for name in ["context", "tools"] where value.has(name) && value[name].fields == nil { return envelopeIssue(key + "." + name, "Invalid input: expected object, received \(typeName(value[name]))") } }
            if field == "roots" && value.has("listChanged") && value["listChanged"].bool == nil { return envelopeIssue(key + ".listChanged", "Invalid input: expected boolean, received \(typeName(value["listChanged"]))") }
            if field == "elicitation" {
                for name in ["form", "url"] where value.has(name) && value[name].fields == nil { return envelopeIssue(key + "." + name, "Invalid input: expected object, received \(typeName(value[name]))") }
                if value["form"].has("applyDefaults") && value["form"]["applyDefaults"].bool == nil { return envelopeIssue(key + ".form.applyDefaults", "Invalid input: expected boolean, received \(typeName(value["form"]["applyDefaults"]))") }
            }
        }
        if meta.has("progressToken") && meta["progressToken"].string == nil && meta["progressToken"].number == nil { return envelopeIssue("progressToken", "Invalid input") }
        let logLevelKey = "io.modelcontextprotocol/logLevel"
        if meta.has(logLevelKey) && !["debug", "info", "notice", "warning", "error", "critical", "alert", "emergency"].contains(meta[logLevelKey].string ?? "") { return envelopeIssue(logLevelKey, "Invalid option: expected one of \"debug\"|\"info\"|\"notice\"|\"warning\"|\"error\"|\"critical\"|\"alert\"|\"emergency\"") }
        guard revision == modernRevision else { return rpcError(id: id, code: -32022, message: "Unsupported protocol version: \(revision)", data: .object([.init("requested", .string(revision)), .init("supported", .array([.string(modernRevision)]))]), status: 400) }
        if let header = headers["mcp-protocol-version"], header != revision { return headerMismatch(id: id, header: header, body: "the body envelope names protocol version \(revision) but the MCP-Protocol-Version header names \(header)") }
        if let header = headers["mcp-method"], header != parsed["method"].string { return headerMismatch(id: id, header: header, body: "the body names method \(parsed["method"].string ?? "") but the Mcp-Method header names \(header)") }
        guard parsed["id"] != .missing else { return nil }
        guard headers["mcp-protocol-version"] != nil else { return headerMismatch(id: id, header: "(missing)", body: "the body envelope names protocol version \(revision) but the required MCP-Protocol-Version header is absent") }
        guard headers["mcp-method"] != nil else { return headerMismatch(id: id, header: "(missing)", body: "the body names method \(parsed["method"].string ?? "") but the required Mcp-Method header is absent") }
        if let method = parsed["method"].string, let field = nameFields[method], let name = parsed["params"][field].string {
            guard let raw = headers["mcp-name"] else { return headerMismatch(id: id, header: "(missing)", body: "the body carries params.\(field)=\"\(name)\" but the required Mcp-Name header is absent") }
            let header = raw.trimmingCharacters(in: .whitespaces)
            guard let decoded = decodeHeader(header) else { return headerMismatch(id: id, header: header, body: "the Mcp-Name header carries an invalid Base64 sentinel value") }
            guard decoded == name else { return headerMismatch(id: id, header: header, body: "the body carries params.\(field)=\"\(name)\" but the Mcp-Name header names \"\(decoded)\"") }
        }
        return nil
    }
    private nonisolated static func headerMismatch(id: NativeRPCValue, header: String, body: String) -> BackendDeckCoreSecurityHTTPResponse {
        rpcError(id: id, code: -32020, message: "Bad Request: the request headers and body disagree: " + body,
            data: .object([.init("mismatch", .object([.init("header", .string(header)), .init("body", .string(body))]))]), status: 400)
    }
    private nonisolated static func typeName(_ value: NativeRPCValue) -> String {
        switch value { case .missing: return "undefined"; case .null: return "null"; case .bool: return "boolean"; case .number: return "number"; case .string: return "string"; case .array: return "array"; default: return "object" }
    }
    private nonisolated static func deny(_ status: Int) -> BackendDeckCoreSecurityHTTPResponse { .json(.object([.init("error", .string(status == 404 ? "not found" : "refused"))]), status: status) }
    private nonisolated static func rpcError(id: NativeRPCValue, code: Int, message: String, data: NativeRPCValue = .missing, status: Int = 200) -> BackendDeckCoreSecurityHTTPResponse {
        .json(.object([.init("jsonrpc", .string("2.0")), .init("id", id), .init("error", .object([.init("code", .number(Double(code))), .init("message", .string(message)), .init("data", data)]))]), status: status)
    }
    private nonisolated static var relayNotFound: BackendDeckCoreSecurityHTTPResponse {
        .init(status: 404, body: Data("{\"jsonrpc\":\"2.0\",\"id\":null,\"error\":{\"code\":-32001,\"message\":\"Nothing answered at this address. The computer may be off or not connected, or this link may have been turned off.\"}}".utf8))
    }
    private nonisolated static func toolResult(value: NativeRPCValue, error: String?) -> NativeRPCValue {
        if let error { return .object([.init("content", .array([.object([.init("type", .string("text")), .init("text", .string(error))])])), .init("isError", .bool(true))]) }
        let text = (try? value.encodedJSON(pretty: true)).map { String(decoding: $0, as: UTF8.self) } ?? "null"
        return .object([.init("content", .array([.object([.init("type", .string("text")), .init("text", .string(text))])])), .init("structuredContent", value.fields != nil ? value : .missing)])
    }
    public nonisolated static func instructionsFor(grant: BackendDeckCoreSecurityGrant, caller: BackendDeckCoreSecurityCaller) -> String {
        if caller.kind == .key {
            let act = caller.tiers.contains(.act), alter = caller.tiers.contains(.alter)
            let level = alter ? "it may look, do routine work such as starting and driving sessions, and make bigger changes such as settings" : act ? "it may look and do routine work such as starting and driving sessions, but not change settings or delete anything" : "it may only look: list and read sessions, projects, git changes and alerts"
            let ask = alter && caller.askFirst != false ? " Bigger changes are put to the owner on their Mac or phone first, and refused if nobody answers within 45 seconds." : ""
            let folders = caller.folders.map { $0.isEmpty ? "" : " Sessions can only be started in: \($0.joined(separator: ", "))." } ?? ""
            return "Terminal Deck runs AI coding sessions (Claude Code, Codex, Gemini and plain shells) on its owner's computer, and these tools see and drive it: start a session in one of their projects, send it a message, read what it answered, look at git changes and alerts. Start with sessions_list and projects_list. Many tools are held back to keep this list short — tools_describe lists them by area and gives any one’s arguments, and tools_run calls it. The owner made the key you are using for this app: \(level).\(ask)\(folders) When you are idle, call notifications_wait instead of polling sessions_wait in a loop: it returns as soon as any session you started or sent to finishes a turn, needs input or exits. Every call is written to an activity log the owner reads, under this app’s name."
        }
        if grant.tools != nil { return "Browser windows in Terminal Deck. A window attached to this session is named B1, B2 — open one with browser_open, then browser_read to see what is on it and browser_step to act on it. You can only reach windows attached to this session; being attached is the whole of the permission, and it lasts until the person disconnects it. The first change on a public website is put to them as a confirmation. Every call you make here is written to the action log they can read." }
        return "Tools for seeing and driving Terminal Deck itself: the sessions running in it, the projects it has open, their git state, its alerts and its settings. Reading is always allowed. Starting a session or typing into one you started is allowed and recorded. Changing a setting, or acting on a session the person started, is put to them as a confirmation first and refused if they do not answer. Every call you make here is written to the action log they can read."
    }
}

/// One-shot holder for `authenticatedCall`: claimed once, result stored once.
final class BackendDeckCoreSecurityOnceResult: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false
    private var value: BackendDeckCoreSecurityCallResult?
    func claim() -> Bool { lock.withLock { if claimed { return false }; claimed = true; return true } }
    func store(_ result: BackendDeckCoreSecurityCallResult) { lock.withLock { if value == nil { value = result } } }
    var result: BackendDeckCoreSecurityCallResult? { lock.withLock { value } }
}
