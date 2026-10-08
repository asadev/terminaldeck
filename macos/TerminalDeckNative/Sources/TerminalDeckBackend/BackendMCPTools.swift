import Foundation
import CryptoKit
import TerminalDeckNativeCore

public enum BackendMCPImplementation: String, Sendable, Hashable { case native, suppliedSourceBridge }
public enum BackendMCPTier: String, Sendable, Hashable { case read, act, alter }

/// Source handler identity/schema, never an invented skill/tool inventory.
public struct BackendMCPTool: Sendable {
    public let id: String
    public let wireName: String
    public let description: String
    public let inputSchema: NativeRPCValue
    public let tier: BackendMCPTier
    public let advertised: Bool
    public let implementation: BackendMCPImplementation
    public init(id: String, wireName: String, description: String, inputSchema: NativeRPCValue,
                tier: BackendMCPTier, advertised: Bool = true, implementation: BackendMCPImplementation = .native) throws {
        guard !id.isEmpty, !wireName.isEmpty, inputSchema.fields != nil else {
            throw BackendSessionFailure.invalidInput("A registered MCP tool needs its real identity and object input schema.")
        }
        self.id = id; self.wireName = wireName; self.description = description
        self.inputSchema = inputSchema; self.tier = tier; self.advertised = advertised
        self.implementation = implementation
    }
    public var wireValue: NativeRPCValue {
        .object([.init("name", .string(wireName)), .init("description", .string(description)), .init("inputSchema", inputSchema)])
    }
}

public struct BackendMCPToolReply: Sendable {
    public let content: [NativeRPCValue]
    public let structuredContent: NativeRPCValue?
    public let isError: Bool
    public init(content: [NativeRPCValue], structuredContent: NativeRPCValue? = nil, isError: Bool = false) {
        self.content = content; self.structuredContent = structuredContent; self.isError = isError
    }
    public static func value(_ value: NativeRPCValue) -> Self {
        Self(content: [.object([.init("type", .string("text")), .init("text", .string(value.compact))])],
             structuredContent: value.fields == nil ? nil : value)
    }
    public static func failure(_ message: String) -> Self {
        Self(content: [.object([.init("type", .string("text")), .init("text", .string(message))])], isError: true)
    }
    var wireValue: NativeRPCValue {
        var fields: [NativeRPCValue.Field] = [.init("content", .array(content)), .init("isError", .bool(isError))]
        if let structuredContent { fields.append(.init("structuredContent", structuredContent)) }
        return .object(fields)
    }
}

/// An outstanding consent/forwarded call is cancelled when its caller or HTTP
/// request goes away. Bridges must subscribe and cancel their own request too.
public final class BackendMCPCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var observers: [UUID: @Sendable () -> Void] = [:]
    public init() {}
    public var isCancelled: Bool { lock.withLock { cancelled } }
    public func observe(_ callback: @escaping @Sendable () -> Void) -> UUID {
        let id = UUID()
        let already = lock.withLock { if cancelled { return true }; observers[id] = callback; return false }
        if already { callback() }
        return id
    }
    public func removeObserver(_ id: UUID) { lock.withLock { observers[id] = nil } }
    public func cancel() {
        let callbacks: [@Sendable () -> Void] = lock.withLock {
            guard !cancelled else { return [] }
            cancelled = true; let result = Array(observers.values); observers.removeAll(); return result
        }
        for callback in callbacks { callback() }
    }
}

public struct BackendMCPCallerGrant: Sendable {
    public let attended: Bool
    public let allowedTools: Set<String>
    public let allowedTiers: Set<BackendMCPTier>
    public let projectRoot: String?
    /// Backend-owned task launch scope, never supplied by MCP call arguments.
    public let taskProject: String?
    /// Consulted anew for every call, never frozen at token creation.
    public let permitted: @Sendable () async -> Bool
    public init(attended: Bool, allowedTools: Set<String>, allowedTiers: Set<BackendMCPTier>,
                projectRoot: String? = nil, taskProject: String? = nil, permitted: @escaping @Sendable () async -> Bool = { true }) {
        self.attended = attended; self.allowedTools = allowedTools; self.allowedTiers = allowedTiers
        self.projectRoot = projectRoot; self.taskProject = taskProject; self.permitted = permitted
    }
}

public struct BackendMCPCallContext: Sendable {
    public let sessionID: String
    public let machineID: String
    public let projectRoot: String?
    public let attended: Bool
    public let allowedTools: Set<String>
    public let allowedTiers: Set<BackendMCPTier>
    public let cancellation: BackendMCPCancellation
}

public struct BackendMCPEndpointDescription: Sendable {
    public let url: URL
    public let implementation: BackendMCPImplementation
    public init(url: URL, implementation: BackendMCPImplementation) throws {
        guard url.scheme == "http", ["127.0.0.1", "localhost", "::1"].contains(url.host ?? ""),
              let port = url.port, (1...65_535).contains(port), url.path == "/mcp",
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil else {
            throw BackendSessionFailure.invalidInput("A session MCP endpoint must be the supplied listening loopback /mcp endpoint.")
        }
        self.url = url; self.implementation = implementation
    }
}

public struct BackendMCPRegistration: Sendable { public let id: UUID; public init(id: UUID) { self.id = id } }

public protocol BackendMCPToolEndpoint: BackendLaunchCapability {
    func description() async throws -> BackendMCPEndpointDescription?
    func catalogue() async throws -> [BackendMCPTool]
    /// A token is a secret argument, never a wire/UI result. Registration must
    /// finish in the actual serving caller table before a config is handed out.
    func register(token: String, grant: BackendMCPCallerGrant) async throws -> BackendMCPRegistration
    func bind(_ registration: BackendMCPRegistration, sessionID: String, machineID: String) async throws
    func revoke(_ registration: BackendMCPRegistration) async
}

/// Honest transition bridge: every operation is supplied by the live serving
/// endpoint. No guessed address, no local token table posing as a remote one.
public struct BackendSuppliedMCPBridge: BackendMCPToolEndpoint, Sendable {
    public let readiness: BackendLaunchReadiness
    private let describe: @Sendable () async throws -> BackendMCPEndpointDescription?
    private let tools: @Sendable () async throws -> [BackendMCPTool]
    private let registerCaller: @Sendable (String, BackendMCPCallerGrant) async throws -> BackendMCPRegistration
    private let bindCaller: @Sendable (BackendMCPRegistration, String, String) async throws -> Void
    private let revokeCaller: @Sendable (BackendMCPRegistration) async -> Void
    public init(readiness: BackendLaunchReadiness,
                description: @escaping @Sendable () async throws -> BackendMCPEndpointDescription?,
                catalogue: @escaping @Sendable () async throws -> [BackendMCPTool],
                register: @escaping @Sendable (String, BackendMCPCallerGrant) async throws -> BackendMCPRegistration,
                bind: @escaping @Sendable (BackendMCPRegistration, String, String) async throws -> Void,
                revoke: @escaping @Sendable (BackendMCPRegistration) async -> Void) {
        self.readiness = readiness; describe = description; tools = catalogue
        registerCaller = register; bindCaller = bind; revokeCaller = revoke
    }
    public func description() async throws -> BackendMCPEndpointDescription? {
        guard readiness == .ready else { throw BackendSessionFailure.missingCapability("the supplied MCP endpoint bridge") }
        return try await describe()
    }
    public func catalogue() async throws -> [BackendMCPTool] { try await tools() }
    public func register(token: String, grant: BackendMCPCallerGrant) async throws -> BackendMCPRegistration { try await registerCaller(token, grant) }
    public func bind(_ registration: BackendMCPRegistration, sessionID: String, machineID: String) async throws { try await bindCaller(registration, sessionID, machineID) }
    public func revoke(_ registration: BackendMCPRegistration) async { await revokeCaller(registration) }
}

/// A real native catalogue/caller/dispatch owner. The network transport below
/// calls this same actor. Registered handlers must preserve their actual consent
/// and action-log gate; a supplied Node handler can be used while it is ported.
public actor BackendNativeMCPServer: BackendMCPToolEndpoint {
    public typealias Handler = @Sendable (BackendMCPCallContext, NativeRPCValue) async throws -> BackendMCPToolReply
    public nonisolated let readiness: BackendLaunchReadiness = .ready
    private struct Entry: Sendable {
        let digest: Data
        let grant: BackendMCPCallerGrant
        var sessionID: String?
        var machineID = ""
        let cancellation: BackendMCPCancellation
    }
    private var callers: [UUID: Entry] = [:]
    private var tools: [String: (spec: BackendMCPTool, handler: Handler)] = [:]
    private var aliases: [String: String] = [:]
    private var toolOwners: [String: String] = [:]
    private var catalogueRefresh: [String: @Sendable () async throws -> Void] = [:]
    private var transport: BackendMCPHTTPTransport?
    private var listening: BackendMCPEndpointDescription?
    private var epoch = 0
    private var starting: (epoch: Int, task: Task<BackendMCPEndpointDescription, any Error>)?
    private struct RequestKey: Hashable { let caller: UUID; let requestID: String }
    private var requests: [RequestKey: BackendMCPCancellation] = [:]

    public init() {}
    public func registerTool(_ spec: BackendMCPTool, ownerID: String? = nil, handler: @escaping Handler) throws {
        guard aliases[spec.id] == nil, aliases[spec.wireName] == nil else {
            throw BackendSessionFailure.invalidInput("An MCP tool name is already registered.")
        }
        tools[spec.id] = (spec, handler); aliases[spec.id] = spec.id; aliases[spec.wireName] = spec.id
        toolOwners[spec.id] = ownerID
    }
    /// Validate the whole contribution before replacing it. Removed plugin
    /// names disappear without resetting unrelated areas or caller grants.
    public func replaceTools(ownerID: String, tools contribution: [(BackendMCPTool, Handler)]) throws {
        guard !ownerID.isEmpty else { throw BackendSessionFailure.invalidInput("An MCP area needs an owner.") }
        let retained = tools.filter { toolOwners[$0.key] != ownerID }
        var nextAliases: [String: String] = [:]
        for (id, entry) in retained {
            nextAliases[entry.spec.id] = id; nextAliases[entry.spec.wireName] = id
        }
        var next = retained
        for (spec, handler) in contribution {
            guard next[spec.id] == nil, nextAliases[spec.id] == nil, nextAliases[spec.wireName] == nil else {
                throw BackendSessionFailure.invalidInput("An MCP tool name is already registered.")
            }
            next[spec.id] = (spec, handler); nextAliases[spec.id] = spec.id; nextAliases[spec.wireName] = spec.id
        }
        toolOwners = toolOwners.filter { $0.value != ownerID }
        for (spec, _) in contribution { toolOwners[spec.id] = ownerID }
        tools = next; aliases = nextAliases
    }
    public func removeTools(ownerID: String) {
        let removed = Set(toolOwners.filter { $0.value == ownerID }.map(\.key))
        tools = tools.filter { !removed.contains($0.key) }
        aliases = aliases.filter { !removed.contains($0.value) }
        toolOwners = toolOwners.filter { $0.value != ownerID }
    }
    public func setCatalogueRefresh(ownerID: String, refresh: (@Sendable () async throws -> Void)?) {
        catalogueRefresh[ownerID] = refresh
    }
    /// Inert area builders may collect their real factories into a temporary
    /// non-listening server, then atomically contribute the handlers here.
    /// Which contribution owns a tool id (composition ownership proofs, e.g. shared machine tools).
    public func ownerOf(_ id: String) -> String? { toolOwners[id] }
    public func registrations() -> [(BackendMCPTool, Handler)] {
        tools.values.sorted { $0.spec.id < $1.spec.id }.map { ($0.spec, $0.handler) }
    }
    public func description() -> BackendMCPEndpointDescription? {
        guard let listening else { return nil }
        let mode: BackendMCPImplementation = tools.values.contains { $0.spec.implementation == .suppliedSourceBridge } ? .suppliedSourceBridge : .native
        return try? BackendMCPEndpointDescription(url: listening.url, implementation: mode)
    }
    public func catalogue() async throws -> [BackendMCPTool] {
        for owner in catalogueRefresh.keys.sorted() {
            guard let refresh = catalogueRefresh[owner] else { continue }
            do { try await refresh() }
            catch { removeTools(ownerID: owner); throw error }
        }
        return tools.values.map(\.spec).sorted { $0.id < $1.id }
    }
    public func start() async throws -> BackendMCPEndpointDescription {
        if let listening = description() { return listening }
        if let starting { return try await starting.task.value }
        guard !tools.isEmpty else { throw BackendSessionFailure.missingCapability("the real registered MCP tool handlers") }
        let current = epoch
        let task = Task { try await self.openTransport(epoch: current) }
        starting = (current, task)
        defer { if starting?.epoch == current { starting = nil } }
        return try await task.value
    }
    private func openTransport(epoch: Int) async throws -> BackendMCPEndpointDescription {
        let transport = BackendMCPHTTPTransport { [weak self] request, cancellation in
            guard let self else { return .empty(503) }
            return await self.respond(request, cancellation: cancellation)
        }
        let port = try await transport.start()
        guard epoch == self.epoch, !Task.isCancelled else { transport.stop(); throw BackendSessionFailure.closed }
        let mode: BackendMCPImplementation = tools.values.contains { $0.spec.implementation == .suppliedSourceBridge } ? .suppliedSourceBridge : .native
        let description = try BackendMCPEndpointDescription(url: URL(string: "http://127.0.0.1:\(port)/mcp")!, implementation: mode)
        self.transport = transport; listening = description
        return description
    }
    public func stop() async {
        epoch += 1; starting?.task.cancel(); starting = nil
        listening = nil
        for entry in callers.values { entry.cancellation.cancel() }
        for request in requests.values { request.cancel() }
        requests.removeAll()
        callers.removeAll()
        transport?.stop(); transport = nil
    }
    public func register(token: String, grant: BackendMCPCallerGrant) throws -> BackendMCPRegistration {
        guard listening != nil, token.utf8.count == 64, token.range(of: #"^[0-9a-f]{64}$"#, options: .regularExpression) != nil,
              !grant.allowedTools.isEmpty else { throw BackendSessionFailure.invalidInput("The session MCP caller is not ready for registration.") }
        let id = UUID()
        callers[id] = Entry(digest: Data(SHA256.hash(data: Data(token.utf8))), grant: grant,
            cancellation: BackendMCPCancellation())
        return BackendMCPRegistration(id: id)
    }
    public func bind(_ registration: BackendMCPRegistration, sessionID: String, machineID: String) throws {
        guard !sessionID.isEmpty, var entry = callers[registration.id], !entry.cancellation.isCancelled else {
            throw BackendSessionFailure.invalidInput("The pending MCP caller expired before its session could bind.")
        }
        entry.sessionID = sessionID; entry.machineID = machineID; callers[registration.id] = entry
    }
    public func revoke(_ registration: BackendMCPRegistration) { callers.removeValue(forKey: registration.id)?.cancellation.cancel() }

    private func matching(_ authorization: String?) -> UUID? {
        guard let authorization else { return nil }
        let offered = authorization.hasPrefix("Bearer ") ? String(authorization.dropFirst(7)) : authorization
        guard offered.utf8.count <= 256 else { return nil }
        let digest = Data(SHA256.hash(data: Data(offered.utf8)))
        var found: UUID?
        // Compare every digest, with no early exit or prefix/length comparison.
        for (id, entry) in callers {
            var difference: UInt8 = 0
            for (a, b) in zip(digest, entry.digest) { difference |= a ^ b }
            if difference == 0 && found == nil { found = id }
        }
        return found
    }

    private func respond(_ request: BackendMCPHTTPTransport.Request, cancellation: BackendMCPCancellation) async -> BackendMCPHTTPTransport.Response {
        guard let listening else { return .empty(503) }
        let hosts = ["127.0.0.1:\(listening.url.port!)", "localhost:\(listening.url.port!)"]
        guard request.path == "/mcp", request.headers["origin"] == nil,
              hosts.contains(request.headers["host"]?.lowercased() ?? "") else { return .empty(403) }
        guard request.method == "POST" else { return .empty(405) }
        guard let callerID = matching(request.headers["authorization"]), let entry = callers[callerID] else { return .empty(401) }
        guard let envelope = try? NativeRPCValue.parseJSON(request.body, maximumBytes: 256 * 1024),
              envelope["jsonrpc"].string == "2.0", let method = envelope["method"].string else { return .empty(400) }
        let id = envelope["id"]
        if method == "notifications/cancelled" {
            requests[RequestKey(caller: callerID, requestID: envelope["params"]["requestId"].compact)]?.cancel()
            return .empty(202)
        }
        if id == .missing { return .empty(202) }
        func result(_ value: NativeRPCValue) -> BackendMCPHTTPTransport.Response {
            .json(.object([.init("jsonrpc", .string("2.0")), .init("id", id), .init("result", value)]))
        }
        switch method {
        case "initialize":
            let requested = envelope["params"]["protocolVersion"].string ?? "2025-06-18"
            let version = ["2024-11-05", "2025-03-26", "2025-06-18"].contains(requested) ? requested : "2025-06-18"
            return result(.object([.init("protocolVersion", .string(version)), .init("capabilities", .object([.init("tools", .object([]))])),
                .init("serverInfo", .object([.init("name", .string("deck-control")), .init("version", .string("1.0.0"))]))]))
        case "ping": return result(.object([]))
        case "tools/list":
            guard await entry.grant.permitted(), callers[callerID] != nil else { return .empty(401) }
            let current: [BackendMCPTool]
            do { current = try await catalogue() }
            catch {
                return .json(.object([.init("jsonrpc", .string("2.0")), .init("id", id),
                    .init("error", .object([.init("code", .number(-32603)), .init("message", .string("The live tool catalogue is unavailable."))]))]))
            }
            guard await entry.grant.permitted(), callers[callerID] != nil else { return .empty(401) }
            let allowed = current.filter { BackendUIGMemoryDiscovery.showsTool($0) && $0.advertised && (RNMHootMCPCompatibility.permits($0.id, granted: entry.grant.allowedTools) || RNMHootMCPCompatibility.permits($0.wireName, granted: entry.grant.allowedTools)) }
            return result(.object([.init("tools", .array(allowed.sorted { $0.id < $1.id }.map(\.wireValue)))]))
        case "tools/call":
            let name = envelope["params"]["name"].string ?? ""
            guard RNMHootMCPCompatibility.permits(name, granted: entry.grant.allowedTools), let canonical = aliases[name], let tool = tools[canonical] else {
                return result(BackendMCPToolReply.failure("No tool called \(name).").wireValue)
            }
            guard let sessionID = entry.sessionID, entry.grant.allowedTiers.contains(tool.spec.tier) else {
                return result(BackendMCPToolReply.failure("This caller is not permitted to use that tool.").wireValue)
            }
            let scope = BackendMCPCancellation()
            let requestKey = RequestKey(caller: callerID, requestID: id.compact)
            guard requests[requestKey] == nil else { return .empty(400) }
            requests[requestKey] = scope
            let callerWatch = entry.cancellation.observe { scope.cancel() }
            let requestWatch = cancellation.observe { scope.cancel() }
            defer {
                requests[requestKey] = nil
                entry.cancellation.removeObserver(callerWatch); cancellation.removeObserver(requestWatch)
            }
            // Register cancellation before the first await: revocation/cancel
            // may arrive while the dynamic permission source is answering.
            guard await entry.grant.permitted(), callers[callerID] != nil, !scope.isCancelled else {
                return result(BackendMCPToolReply.failure("This caller is not permitted to use that tool.").wireValue)
            }
            let context = BackendMCPCallContext(sessionID: sessionID, machineID: entry.machineID,
                projectRoot: entry.grant.projectRoot, attended: entry.grant.attended,
                allowedTools: entry.grant.allowedTools, allowedTiers: entry.grant.allowedTiers, cancellation: scope)
            do {
                let arguments = envelope["params"]["arguments"] == .missing ? NativeRPCValue.object([]) : envelope["params"]["arguments"]
                let operation = Task { try await tool.handler(context, arguments) }
                let cancelOperation = scope.observe { operation.cancel() }
                defer { scope.removeObserver(cancelOperation) }
                let answer = try await operation.value
                guard !scope.isCancelled else { return result(BackendMCPToolReply.failure("The caller went away.").wireValue) }
                return result(answer.wireValue)
            } catch {
                return result(BackendMCPToolReply.failure(scope.isCancelled ? "The caller went away." : "The registered tool could not complete its request.").wireValue)
            }
        default:
            return .json(.object([.init("jsonrpc", .string("2.0")), .init("id", id),
                .init("error", .object([.init("code", .number(-32601)), .init("message", .string("Method not found"))]))]))
        }
    }
}
