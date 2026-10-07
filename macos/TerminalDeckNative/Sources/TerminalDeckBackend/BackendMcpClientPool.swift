import Foundation
import TerminalDeckNativeCore

public struct BackendMcpClientTimeouts: Sendable {
    public let connect: Int; public let list: Int; public let call: Int; public let close: Int
    public init(overrides: NativeRPCValue = .object([])) {
        func duration(_ key: String, _ fallback: Int) -> Int {
            guard let n = overrides[key].number, n > 0, n < Double(Int.max) else { return fallback }; return max(1, Int(n))
        }
        connect = duration("connectMs", 20_000); list = duration("listMs", 15_000); call = duration("callMs", 60_000); close = duration("closeMs", 3_000)
    }
}

public actor BackendMcpClientPool {
    public typealias Factory = @Sendable (NativeRPCValue, [String: String]) throws -> any BackendMcpClientTransport
    private struct Live: Sendable { let token: UUID; let transport: any BackendMcpClientTransport; var status: NativeRPCValue; var intentionalClose = false; var toolMetadata: [String: NativeRPCValue] = [:] }
    private let configuration: BackendMcpClientConfiguration
    private let loginPath: @Sendable () async throws -> String
    private let factory: Factory
    private let timeouts: BackendMcpClientTimeouts
    private let outputValidator: (any BackendMcpClientOutputValidating)?
    private let scheduler: any BackendMcpClientDeadlineScheduling
    private var live: [String: Live] = [:]
    private var opening: [String: Task<NativeRPCValue, Never>] = [:]
    private var publish: @Sendable (NativeRPCValue) async -> Void
    public init(configuration: BackendMcpClientConfiguration, loginPath: @escaping @Sendable () async throws -> String,
                timeouts: BackendMcpClientTimeouts = .init(), factory: Factory? = nil,
                outputValidator: (any BackendMcpClientOutputValidating)? = nil, scheduler: any BackendMcpClientDeadlineScheduling = BackendMcpClientDispatchScheduler(), onStatus: @escaping @Sendable (NativeRPCValue) async -> Void = { _ in }) {
        self.configuration = configuration; self.loginPath = loginPath; self.timeouts = timeouts
        self.factory = factory ?? { try BackendMcpClientStdioTransport(server: $0, environment: $1, scheduler: scheduler) }
        self.outputValidator = outputValidator; self.scheduler = scheduler; publish = onStatus
    }
    public func setStatusSink(_ sink: @escaping @Sendable (NativeRPCValue) async -> Void) { publish = sink }
    public static func initial(_ server: NativeRPCValue) -> NativeRPCValue {
        server.merging(.object([.init("state", .string("idle")), .init("error", .null), .init("serverInfo", .null), .init("capabilities", .array([])), .init("instructions", .null), .init("pid", .null), .init("connectedAt", .null), .init("stderr", .string(""))]))
    }
    public func statuses(_ servers: [NativeRPCValue]) -> [NativeRPCValue] {
        servers.map { server in
            guard let held = live[server["id"].string ?? ""] else { return Self.initial(server) }
            return held.status.merging(server)
        }
    }
    public func status(_ id: String) -> NativeRPCValue? { live[id]?.status }
    public func connect(_ server: NativeRPCValue) async -> NativeRPCValue {
        let id = server["id"].string ?? ""
        if let task = opening[id] { return await task.value }
        if let held = live[id], held.status["state"].string == "ready" { return held.status }
        let task = Task { await self.open(server) }; opening[id] = task
        let result = await task.value; opening[id] = nil; return result
    }
    private func open(_ server: NativeRPCValue) async -> NativeRPCValue {
        let id = server["id"].string ?? "", name = server["name"].string ?? ""
        if live[id] != nil { _ = await disconnect(id) }
        if let unsupported = server["unsupported"].string {
            let failed = Self.initial(server).setting("state", .string("failed")).setting("error", .string(unsupported)); await publish(failed); return failed
        }
        var status = Self.initial(server).setting("state", .string("connecting")); await publish(status)
        let token = UUID(); var transport: (any BackendMcpClientTransport)?
        do {
            let configuration = self.configuration, loginPath = self.loginPath, factory = self.factory, timeouts = self.timeouts, scheduler = self.scheduler
            let created = try await BackendMcpClientDeadline.run(timeouts.connect, label: "Connecting to " + name, scheduler: scheduler) {
                var env = configuration.environment; let path = try await loginPath()
                for field in server["env"].fields ?? [] { if let value = field.value.string { env[field.key] = value } }
                if server["env"]["PATH"].string == nil { env["PATH"] = path }
                return try factory(server, env)
            }
            transport = created; live[id] = Live(token: token, transport: created, status: status)
            let initialize = try await BackendMcpClientDeadline.run(timeouts.connect, label: "Connecting to " + name, scheduler: scheduler) {
                try await created.start(stderr: { [weak self] text in Task { await self?.stderr(id, token: token, text: text) } }, closed: { [weak self] in Task { await self?.closed(id, token: token) } })
                return try await created.request("initialize", params: .object([.init("protocolVersion", .string("2025-11-25")), .init("capabilities", .object([])), .init("clientInfo", .object([.init("name", .string("terminaldeck")), .init("version", .string("0.1.0"))]))]), timeout: timeouts.connect, label: "Connecting to " + name)
            }
            guard ["2024-10-07", "2024-11-05", "2025-03-26", "2025-06-18", "2025-11-25"].contains(initialize["protocolVersion"].string ?? ""), initialize["capabilities"].fields != nil,
                  initialize["serverInfo"]["name"].string != nil, initialize["serverInfo"]["version"].string != nil else { throw BackendMcpClientValue.error("Invalid MCP initialize result.") }
            try await created.notify("notifications/initialized", params: .object([]))
            guard var entry = live[id], entry.token == token, !entry.intentionalClose else { throw BackendMcpClientValue.error("Not connected.") }
            status = entry.status.setting("state", .string("ready")).setting("error", .null)
                .setting("serverInfo", .object([.init("name", initialize["serverInfo"]["name"]), .init("version", initialize["serverInfo"]["version"])]))
                .setting("capabilities", BackendMcpClientValue.strings((initialize["capabilities"].fields ?? []).map(\.key)))
                .setting("instructions", initialize["instructions"].string.flatMap { $0.isEmpty ? nil : $0 }.map(NativeRPCValue.string) ?? .null)
                .setting("pid", created.pid.map { .number(Double($0)) } ?? .null).setting("connectedAt", .number(Date().timeIntervalSince1970 * 1000))
            if !created.stderrTail.isEmpty { status = status.setting("stderr", .string(created.stderrTail)) }
            entry.status = status; live[id] = entry; await publish(status); return status
        } catch {
            if var entry = live[id], entry.token == token { entry.intentionalClose = true; status = entry.status; live[id] = entry }
            if let transport { await forceClose(transport) }
            if let transport, !transport.stderrTail.isEmpty { status = status.setting("stderr", .string(transport.stderrTail)) }
            if live[id]?.token == token { live[id] = nil }
            let failed = status.setting("state", .string("failed")).setting("error", .string(error.localizedDescription)).setting("pid", .null)
            await publish(failed); return failed
        }
    }
    private func stderr(_ id: String, token: UUID, text: String) {
        guard var entry = live[id], entry.token == token, !entry.intentionalClose else { return }
        let old = entry.status["stderr"].string ?? ""
        // JS strings count UTF-16 units. Decode a tail without splitting valid scalars.
        entry.status = entry.status.setting("stderr", .string(String(decoding: (old + text).utf16.suffix(8_000), as: UTF16.self))); live[id] = entry
    }
    private func closed(_ id: String, token: UUID) async {
        guard let entry = live[id], entry.token == token, !entry.intentionalClose, entry.status["state"].string == "ready" else { return }
        var status = entry.status.setting("state", .string("closed")).setting("error", entry.status["error"].isNullish ? .string("The server exited.") : entry.status["error"]).setting("pid", .null)
        if !entry.transport.stderrTail.isEmpty { status = status.setting("stderr", .string(entry.transport.stderrTail)) }
        live[id] = nil; await publish(status)
    }
    private func forceClose(_ transport: any BackendMcpClientTransport) async {
        let timeout = timeouts.close
        _ = try? await BackendMcpClientDeadline.run(timeout, label: "Closing the connection", scheduler: scheduler) { await transport.close(); return true }
    }
    public func disconnect(_ id: String) async -> NativeRPCValue? {
        guard var entry = live.removeValue(forKey: id) else { return nil }; entry.intentionalClose = true
        await forceClose(entry.transport)
        let status = entry.status.setting("state", .string("idle")).setting("pid", .null).setting("connectedAt", .null).setting("error", .null); await publish(status); return status
    }
    public func disconnectAll() async {
        let work = Array(opening.values); for task in work { _ = await task.value }
        for id in Array(live.keys) { _ = await disconnect(id) }
    }
    private func require(_ id: String) throws -> Live {
        guard let entry = live[id], entry.status["state"].string == "ready" else { throw BackendMcpClientValue.error("Not connected.") }; return entry
    }
    public static func capPayload(_ value: NativeRPCValue) -> (NativeRPCValue, Bool) {
        guard let bytes = try? value.encodedJSON(), let text = String(data: bytes, encoding: .utf8) else { return (.object([.init("note", .string("The result could not be serialised."))]), true) }
        let count = text.utf16.count, limit = 512 * 1024
        if count <= limit { return (value, false) }
        return (.object([.init("note", .string("The result was \(count) characters; showing the first \(limit).")), .init("preview", .string(String(decoding: text.utf16.prefix(limit), as: UTF16.self)))]), true)
    }
    public func call(_ server: NativeRPCValue, method: String, params: NativeRPCValue, label: String, tool: Bool = false) async -> NativeRPCValue {
        let started = Date(); var error: String?, value: NativeRPCValue = .null, truncated = false
        let status = await connect(server)
        if status["state"].string != "ready" { error = status["error"].string ?? "Not connected." }
        else {
            do {
                let entry = try require(server["id"].string ?? ""), timeout = tool ? timeouts.call : timeouts.list
                let capability = method.hasPrefix("tools/") ? "tools" : method.hasPrefix("resources/") ? "resources" : "prompts"
                if !(entry.status["capabilities"].elements ?? []).contains(.string(capability)) { throw BackendMcpClientValue.error("Server does not support \(capability) (required for \(method))") }
                let metadata = entry.toolMetadata[params["name"].string ?? ""]
                if method == "tools/call", metadata?["execution"]["taskSupport"].string == "required" {
                    throw BackendMcpClientRPCFailure(code: -32600, message: "Tool \"\(params["name"].string ?? "")\" requires task-based execution. Use client.experimental.tasks.callToolStream() instead.")
                }
                let outputValidator = self.outputValidator
                let answer = try await BackendMcpClientDeadline.run(timeout, label: label, scheduler: scheduler) {
                    let raw = try await entry.transport.request(method, params: params, timeout: timeout, label: label)
                    let answer = try BackendMcpClientValidation.result(raw, method: method)
                    if method == "tools/call", let schema = metadata?["outputSchema"], !schema.isNullish {
                        if answer["structuredContent"] == .missing && answer["isError"].bool != true {
                            throw BackendMcpClientRPCFailure(code: -32600, message: "Tool \(params["name"].string ?? "") has an output schema but did not return structured content")
                        }
                        if answer["structuredContent"] != .missing {
                            guard let outputValidator else { throw BackendMcpClientValue.error("MCP tool output schema validation is unavailable.") }
                            if let why = try await outputValidator.validate(schema: schema, value: answer["structuredContent"]) {
                                throw BackendMcpClientRPCFailure(code: -32602, message: "Structured content does not match the tool's output schema: " + why)
                            }
                        }
                    }
                    return answer
                }
                (value, truncated) = Self.capPayload(answer)
            } catch let failure { error = failure.localizedDescription }
        }
        return .object([.init("ok", .bool(error == nil)), .init("result", value), .init("error", BackendMcpClientValue.optional(error)), .init("durationMs", .number(max(0, Date().timeIntervalSince(started) * 1000).rounded(.down))), .init("truncated", .bool(truncated))])
    }
    public func inventory(_ server: NativeRPCValue) async -> NativeRPCValue {
        let id = server["id"].string ?? "", status = await connect(server)
        var inventory = NativeRPCValue.object([.init("serverId", .string(id)), .init("tools", .array([])), .init("resources", .array([])), .init("resourceTemplates", .array([])), .init("prompts", .array([])), .init("errors", .object([])), .init("status", status)])
        if status["state"].string != "ready" { return inventory }
        guard let entry = live[id], entry.status["state"].string == "ready" else { return inventory.setting("errors", .object([.init("server", .string("The server exited before it could be listed."))])).setting("status", status.setting("state", .string("closed"))) }
        let caps = Set((status["capabilities"].elements ?? []).compactMap(\.string)), timeout = timeouts.list
        for (capability, key, method) in [("tools", "tools", "tools/list"), ("resources", "resources", "resources/list"), ("resources", "resourceTemplates", "resources/templates/list"), ("prompts", "prompts", "prompts/list")] where caps.contains(capability) {
            do {
                let items = try await BackendMcpClientDeadline.run(timeout, label: "Listing " + key, scheduler: scheduler) {
                    var values: [NativeRPCValue] = [], seen = Set<String>(); var cursor: String?
                    for _ in 0..<50 {
                        let params = cursor.map { NativeRPCValue.object([.init("cursor", .string($0))]) } ?? .object([])
                        let page = try await entry.transport.request(method, params: params, timeout: timeout, label: "Listing " + key)
                        guard let rows = page[key].elements else { throw BackendMcpClientValue.error("Invalid MCP \(key) listing.") }
                        for row in rows { try BackendMcpClientValidation.listing(row, section: key) }
                        if key == "tools" { await self.cacheToolMetadata(id, token: entry.token, rows: rows) }
                        values += rows.map { Self.inventoryItem($0, section: key) }
                        guard let next = page["nextCursor"].string, !next.isEmpty else { break }
                        if !seen.insert(next).inserted { break }; cursor = next
                    }
                    return values
                }
                inventory = inventory.setting(key, .array(items))
            } catch {
                let notFound = (error as? BackendMcpClientRPCFailure)?.code == -32601 || error.localizedDescription.contains("-32601")
                if !notFound { inventory = inventory.setting("errors", inventory["errors"].setting(key, .string(error.localizedDescription))) }
            }
        }
        return inventory.setting("status", live[id]?.status ?? status)
    }
    private func cacheToolMetadata(_ id: String, token: UUID, rows: [NativeRPCValue]) {
        guard var entry = live[id], entry.token == token else { return }
        // The SDK replaces its metadata cache after each listTools page.
        entry.toolMetadata = Dictionary(rows.map { ($0["name"].string!, $0) }, uniquingKeysWith: { _, next in next }); live[id] = entry
    }
    private static func inventoryItem(_ raw: NativeRPCValue, section: String) -> NativeRPCValue {
        var value = NativeRPCValue.object([.init("name", raw["name"]), .init("title", raw["title"].string.flatMap { $0.isEmpty ? nil : $0 }.map(NativeRPCValue.string) ?? .null), .init("description", raw["description"].string.flatMap { $0.isEmpty ? nil : $0 }.map(NativeRPCValue.string) ?? .null)])
        if section == "tools" { return value.setting("inputSchema", raw["inputSchema"].isNullish ? .null : raw["inputSchema"]).setting("outputSchema", raw["outputSchema"].isNullish ? .null : raw["outputSchema"]) }
        if section == "prompts" { return value.setting("arguments", .array((raw["arguments"].elements ?? []).map { .object([.init("name", $0["name"]), .init("description", $0["description"].string.flatMap { $0.isEmpty ? nil : $0 }.map(NativeRPCValue.string) ?? .null), .init("required", .bool($0["required"].bool == true))]) })) }
        value = value.setting(section == "resourceTemplates" ? "uriTemplate" : "uri", raw[section == "resourceTemplates" ? "uriTemplate" : "uri"])
        return value.setting("mimeType", raw["mimeType"].string.flatMap { $0.isEmpty ? nil : $0 }.map(NativeRPCValue.string) ?? .null)
    }
}
