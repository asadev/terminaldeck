import Foundation
import TerminalDeckNativeCore

/// A view is attached to a recorded call, never a caller-supplied server or HTML document.
public actor BackendChatMCPApps {
    @TaskLocal static var phoneAccessCheck: (@Sendable () async throws -> Void)?
    public struct Conversation: Sendable {
        public let rows: [HootChatRow]
        public let project: String?
        public let provider: String
        public let agentID: String?
        public init(rows: [HootChatRow], project: String?, provider: String, agentID: String? = nil) {
            self.rows = rows; self.project = project; self.provider = provider; self.agentID = agentID
        }
    }
    public typealias Read = @Sendable (String) async throws -> Conversation
    public typealias Inventory = @Sendable (String?) async throws -> [NativeRPCValue]
    public typealias ServerOperation = @Sendable (String, String?, String, NativeRPCValue) async throws -> NativeRPCValue
    public typealias Consent = @Sendable (String, String, NativeRPCValue) async throws -> Bool
    private struct ViewKey: Hashable { let session: String; let row: String; let view: String }
    private struct Lifecycle { let source: String; var ready: Bool; var touched: Date }
    private struct Transfer { let id: String; let bytes: Data; let kind: String; let created: Date }
    private var phoneTransfers: [String: Transfer] = [:]
    private var views: [ViewKey: Lifecycle] = [:]
    private let restoreResult: (@Sendable (String, String) async throws -> NativeRPCValue)?
    private let read: Read
    private let servers: Inventory
    private let inventory: ServerOperation
    private let resource: ServerOperation
    private let call: ServerOperation
    private let consent: Consent
    private let openLink: @Sendable (URL) async throws -> Bool
    public init(read: @escaping Read, servers: @escaping Inventory, inventory: @escaping ServerOperation,
                resource: @escaping ServerOperation, call: @escaping ServerOperation, consent: @escaping Consent,
                openLink: @escaping @Sendable (URL) async throws -> Bool,
                restoreResult: (@Sendable (String, String) async throws -> NativeRPCValue)? = nil) {
        self.restoreResult = restoreResult
        self.read = read; self.servers = servers; self.inventory = inventory; self.resource = resource
        self.call = call; self.consent = consent; self.openLink = openLink
    }
    /// Explicit provider identity stays exact. A namespaced call retains its entire
    /// name with an empty server until configured namespaces and inventories resolve it.
    public static func toolIdentity(_ row: HootChatRow) -> (server: String, tool: String, input: NativeRPCValue)? {
        let input = row.value["input"], name = row.value["name"].string ?? ""
        // This field is written by the typed provider decoders. Input and output are untrusted content.
        let identified = row.value["mcpCall"]
        if !identified.isNullish {
            guard identified["invalid"].bool != true, let server = identified["server"].string, !server.isEmpty,
                  let tool = identified["tool"].string, !tool.isEmpty else { return nil }
            let arguments = input.string.flatMap { try? NativeRPCValue.parseJSON(Data($0.utf8)) } ?? input
            return (server, tool, arguments.fields == nil ? .object([]) : arguments)
        }
        if name.hasPrefix("mcp__"), name.dropFirst(5).contains("__") {
            return ("", name, input)
        }
        // Calls via the app's own mcp.call retain their original server and tool arguments.
        if ["mcp.call", "mcp_call"].contains(name), let server = input["id"].string ?? input["serverId"].string,
           let tool = input["tool"].string ?? input["name"].string { return (server, tool, input["arguments"]) }
        return nil
    }
    private struct Attachment {
        let conversation: Conversation
        let row: HootChatRow
        let server: NativeRPCValue
        let tool: NativeRPCValue
        let input: NativeRPCValue
    }
    private func attachment(_ session: String, rowID: String) async throws -> Attachment? {
        let conversation = try await read(session)
        guard let row = conversation.rows.first(where: { $0.id == rowID }), row.kind == .toolCall,
              let identity = Self.toolIdentity(row) else { return nil }
        let configured = try await servers(conversation.project)
        let namedCall = row.value["name"].string ?? ""
        let candidates: [(server: NativeRPCValue, tool: String)]
        if identity.server.isEmpty {
            candidates = configured.compactMap { server in
                guard let name = server["name"].string, !name.isEmpty else { return nil }
                let prefix = "mcp__" + name + "__"
                guard identity.tool.hasPrefix(prefix) else { return nil }
                let tool = String(identity.tool.dropFirst(prefix.count))
                return tool.isEmpty ? nil : (server, tool)
            }
        } else {
            let found = configured.filter { $0["id"].string == identity.server || $0["name"].string == identity.server }
            // Explicit provider metadata must not cross between same-named user/project servers.
            guard found.count == 1 else { return nil }
            guard let server = found.first else { return nil }
            // A namespaced recorded name and typed provenance must name the same call.
            if namedCall.hasPrefix("mcp__") {
                guard let name = server["name"].string,
                      namedCall == "mcp__" + name + "__" + identity.tool else { return nil }
            }
            candidates = [(server, identity.tool)]
        }
        // The namespace must identify one configured server before reading any inventory.
        // A missing tool on another same-named server cannot prove which server ran the call.
        guard candidates.count == 1 else { return nil }
        var matches: [(server: NativeRPCValue, tool: NativeRPCValue)] = []
        for candidate in candidates {
            guard let id = candidate.server["id"].string, candidate.server["enabled"].bool != false else { return nil }
            let policy = BackendMcpPolicy.load().servers[candidate.server["name"].string ?? ""] ?? .init()
            guard policy.on(client: conversation.provider, agentID: conversation.agentID) else { return nil }
            let listing = try await inventory(id, conversation.project, "", .object([]))
            let tools = (listing["tools"].elements ?? []).filter { $0["name"].string == candidate.tool }
            // Count every exact inventory match before checking UI or permission metadata:
            // a disabled/no-UI match still makes the recorded namespace ambiguous.
            matches += tools.map { (candidate.server, $0) }
        }
        guard matches.count == 1, let match = matches.first else { return nil }
        let server = match.server, tool = match.tool
        let policy = BackendMcpPolicy.load().servers[server["name"].string ?? ""] ?? .init()
        guard policy.on(client: conversation.provider, agentID: conversation.agentID),
              !policy.toolsOff.contains(tool["name"].string ?? ""), Self.uiURI(tool) != nil else { return nil }
        return Attachment(conversation: conversation, row: row, server: server, tool: tool, input: identity.input)
    }
    public static func uiURI(_ tool: NativeRPCValue) -> String? {
        guard let uri = tool["_meta"]["ui"]["resourceUri"].string, let url = URL(string: uri),
              url.scheme == "ui", !uri.contains("\0"), uri.utf8.count <= 4096 else { return nil }
        return uri
    }
    public static func html(_ result: NativeRPCValue, uri: String) throws -> String {
        guard result["ok"].bool != false else { throw NativeRPCError(code: "unavailable", message: result["error"].string ?? "The app could not be read.") }
        let body = result.has("result") ? result["result"] : result
        guard let item = body["contents"].elements?.first(where: {
            $0["uri"].string == uri && $0["mimeType"].string == "text/html;profile=mcp-app"
        }) else { throw NativeRPCError(code: "unavailable", message: "The server did not return an MCP App document.") }
        let html = item["text"].string ?? item["blob"].string.flatMap { Data(base64Encoded: $0) }.flatMap { String(data: $0, encoding: .utf8) }
        guard let html, html.utf8.count <= 2_097_152 else { throw NativeRPCError(code: "unavailable", message: "The app document is missing or too large.") }
        return html
    }
    public func document(session: String, rowID: String) async throws -> NativeRPCValue {
        guard let app = try await attachment(session, rowID: rowID), app.row.value["finished"].bool == true,
              let uri = Self.uiURI(app.tool), let id = app.server["id"].string else { return .null }
        let answer = try await resource(id, app.conversation.project, uri, .object([]))
        return .object([.init("type", .string("mcpApp")), .init("rowId", .string(rowID)), .init("resourceUri", .string(uri)),
            .init("html", .string(try Self.html(answer, uri: uri))), .init("tool", app.tool), .init("input", app.input),
            .init("result", Self.toolResult(app.row.value["output"]))])
    }
    public func sourceDocument(session: String, rowID: String) async throws -> NativeRPCValue {
        let conversation = try await read(session)
        guard let row = conversation.rows.first(where: { $0.id == rowID }),
              [.toolCall, .toolResult].contains(row.kind), row.value.has("output") else { return .null }
        if Self.toolIdentity(row) != nil {
            let app = try await document(session: session, rowID: rowID)
            if !app.isNullish {
                if Self.toolResult(row.value["output"]).fields != nil, let restoreResult {
                    let restored = try await restoreResult(session, rowID)
                    return app.setting("result", restored)
                }
                return app
            }
        }
        let result = try await restoreResult?(session, rowID) ?? Self.toolResult(row.value["output"])
        return .object([.init("type", .string("toolResult")), .init("rowId", .string(rowID)), .init("result", result)])
    }
    /// Pages the complete document envelope, so large input/results cannot defeat the HTML limit.
    public func phoneDocument(session: String, rowID: String, owner: String, offset: Int = 0, documentID: String? = nil) async throws -> NativeRPCValue {
        let key = owner + "\n" + session + "\n" + rowID
        if let documentID {
            guard let transfer = phoneTransfers[key + "\n" + documentID], transfer.id == documentID,
                  Date().timeIntervalSince(transfer.created) < 600 else {
                throw NativeRPCError(code: "stale", message: "The app transfer expired. Read it again from the start.")
            }
            let conversation = try await read(session)
            guard let row = conversation.rows.first(where: { $0.id == rowID }) else {
                throw NativeRPCError(code: "stale", message: "The source chat changed.")
            }
            if ![HootChatKind.user, .message, .textDelta].contains(row.kind) {
                guard [.toolCall, .toolResult].contains(row.kind), row.value.has("output") else { throw NativeRPCError(code: "stale", message: "The source chat changed.") }
            }
            return try Self.transferPage(transfer.bytes, kind: transfer.kind, id: transfer.id, offset: offset)
        }
        guard offset == 0 else { throw NativeRPCError.invalidArguments("Continue this app transfer using its documentId.") }
        let conversation = try await read(session)
        guard let row = conversation.rows.first(where: { $0.id == rowID }) else {
            throw NativeRPCError(code: "stale", message: "That message is not in the source chat.")
        }
        let value: NativeRPCValue
        if [HootChatKind.user, .message, .textDelta].contains(row.kind), let original = row.value["text"].string {
            let text = try await BackendChatMarkdownImages.resolve(original, folder: conversation.project, access: Self.phoneAccessCheck)
            value = .object([.init("type", .string("richMessage")), .init("rowId", .string(rowID)),
                .init("text", .string(text)), .init("blocks", ChatMarkdown.renderedBlocks(text, streaming: row.kind == .textDelta))])
        } else { value = try await sourceDocument(session: session, rowID: rowID) }
        return try stashPhonePayload(value, kind: "app", key: key)
    }
    public func phoneBridge(session: String, rowID: String, owner: String, message: NativeRPCValue, viewID: String) async throws -> NativeRPCValue {
        let answer = await bridge(session: session, rowID: rowID, message: message, viewID: viewID)
        return try stashPhonePayload(answer, kind: "messages", key: owner + "\n" + session + "\n" + rowID)
    }
    private func stashPhonePayload(_ value: NativeRPCValue, kind: String, key: String) throws -> NativeRPCValue {
        let bytes = try value.encodedJSON()
        guard bytes.count <= 8_388_608 else { throw NativeRPCError(code: "too-large", message: "The app data is too large to send to this phone.") }
        phoneTransfers = phoneTransfers.filter { Date().timeIntervalSince($0.value.created) < 600 }
        if phoneTransfers.count >= 32, let oldest = phoneTransfers.min(by: { $0.value.created < $1.value.created })?.key { phoneTransfers[oldest] = nil }
        let transfer = Transfer(id: UUID().uuidString, bytes: bytes, kind: kind, created: Date())
        phoneTransfers[key + "\n" + transfer.id] = transfer
        return try Self.transferPage(bytes, kind: kind, id: transfer.id, offset: 0)
    }
    static func transferPage(_ bytes: Data, kind: String, id: String, offset: Int) throws -> NativeRPCValue {
        guard offset >= 0, offset <= bytes.count else { throw NativeRPCError.invalidArguments("The app offset is outside its document.") }
        let whole = bytes.count <= 32_768 && offset == 0
        let end = whole ? bytes.count : min(bytes.count, offset + 24_576)
        var page = NativeRPCValue.object([.init("payloadKind", .string(kind)), .init("documentId", .string(id)),
            .init("encoding", .string("base64-json")), .init("offset", .number(Double(offset))), .init("total", .number(Double(bytes.count))),
            .init("nextOffset", end < bytes.count ? .number(Double(end)) : .null)])
        if whole { page = page.setting(kind, try NativeRPCValue.parseJSON(bytes)) }
        else { page = page.setting(kind, kind == "messages" ? .array([]) : .null).setting("documentChunk", .string(bytes.subdata(in: offset..<end).base64EncodedString())) }
        return page
    }
    /// The existing read tools can append these to their Markdown blocks without exposing a new action door.
    public func renderedBlocks(session: String) async throws -> NativeRPCValue {
        let conversation = try await read(session)
        var blocks: [NativeRPCValue] = []
        for row in conversation.rows where row.kind == .toolCall && row.value["finished"].bool == true && Self.toolIdentity(row) != nil {
            do {
                let document = try await document(session: session, rowID: row.id)
                guard let html = document["html"].string else { continue }
                blocks.append(.object([.init("rowId", .string(row.id)), .init("type", .string("mcpApp")),
                    .init("source", .string(html)), .init("resourceUri", document["resourceUri"])]))
            } catch {
                blocks.append(.object([.init("rowId", .string(row.id)), .init("type", .string("mcpApp")),
                    .init("error", .string(error.localizedDescription))]))
            }
        }
        return .array(blocks)
    }
    public static func toolResult(_ value: NativeRPCValue) -> NativeRPCValue {
        if let text = value.string, let parsed = try? NativeRPCValue.parseJSON(Data(text.utf8)) { return toolResult(parsed) }
        if value["result"].fields != nil { return toolResult(value["result"]) }
        if value.fields != nil { return value }
        if value.elements != nil { return .object([.init("content", value)]) }
        return .object([.init("content", .array([.object([.init("type", .string("text")), .init("text", .string(value.string ?? value.compact))])]))])
    }
    public static func notification(_ method: String, _ params: NativeRPCValue) -> NativeRPCValue {
        .object([.init("jsonrpc", .string("2.0")), .init("method", .string(method)), .init("params", params)])
    }
    /// A batch lets the sealed view send tool input/result only after the guest's initialized notification.
    public func bridge(session: String, rowID: String, message: NativeRPCValue, viewID: String = "default") async -> NativeRPCValue {
        let id = message["id"]
        func reply(_ value: NativeRPCValue) -> NativeRPCValue { .array([.object([.init("jsonrpc", .string("2.0")), .init("id", id), .init("result", value)])]) }
        do {
            guard message["jsonrpc"].string == "2.0", let method = message["method"].string,
                  let app = try await attachment(session, rowID: rowID), let serverID = app.server["id"].string else {
                throw NativeRPCError(code: "access-denied", message: "That tool view is no longer available.")
            }
            try await Self.phoneAccessCheck?()
            let key = ViewKey(session: session, row: rowID, view: viewID)
            let now = Date()
            views = views.filter { now.timeIntervalSince($0.value.touched) < 1800 }
            if views.count >= 256, views[key] == nil, let oldest = views.min(by: { $0.value.touched < $1.value.touched })?.key { views[oldest] = nil }
            let source = serverID + "\n" + (app.tool["name"].string ?? "") + "\n" + (Self.uiURI(app.tool) ?? "") + "\n" + app.input.compact
            if method != "ui/initialize" {
                guard var lifecycle = views[key], lifecycle.source == source else {
                    views[key] = nil
                    throw NativeRPCError(code: "not-initialized", message: "Initialize this chat app before using its bridge.")
                }
                guard method == "ui/notifications/initialized" || lifecycle.ready else {
                    throw NativeRPCError(code: "not-initialized", message: "Finish this chat app's initialization before using its bridge.")
                }
                lifecycle.touched = now; views[key] = lifecycle
            }
            let params = message["params"]
            switch method {
            case "ui/initialize":
                guard ["2026-01-26", "2025-06-18"].contains(params["protocolVersion"].string ?? "") else {
                    throw NativeRPCError.invalidArguments("Unsupported MCP App protocol version.")
                }
                guard !id.isNullish else { throw NativeRPCError.invalidArguments("Initialization needs a request id.") }
                views[key] = Lifecycle(source: source, ready: false, touched: now)
                return reply(.object([.init("protocolVersion", .string("2026-01-26")),
                    .init("hostInfo", .object([.init("name", .string("terminaldeck")), .init("version", .string("1.0"))])),
                    .init("hostCapabilities", .object([.init("serverTools", .object([])), .init("serverResources", .object([])), .init("openLinks", .object([]))])),
                    .init("hostContext", .object([.init("displayMode", .string("inline")), .init("availableDisplayModes", .array([.string("inline")]))]))]))
            case "ui/notifications/initialized":
                guard views[key]?.ready != true else { return .array([]) }
                views[key]?.ready = true
                var notifications = [Self.notification("ui/notifications/tool-input", .object([.init("arguments", app.input)]))]
                if app.row.value["finished"].bool == true { notifications.append(Self.notification("ui/notifications/tool-result", Self.toolResult(app.row.value["output"]))) }
                return .array(notifications)
            case "ping": return reply(.object([]))
            case "tools/call":
                let tool = try params["name"].requireString("tool", nonempty: true)
                let listing = try await inventory(serverID, app.conversation.project, "", .object([]))
                guard listing["tools"].elements?.contains(where: { $0["name"].string == tool }) == true else { throw NativeRPCError.invalidArguments("This server does not offer that tool.") }
                let policy = BackendMcpPolicy.load().servers[app.server["name"].string ?? ""] ?? .init()
                guard !policy.toolsOff.contains(tool), params["arguments"].isNullish || params["arguments"].fields != nil else { throw NativeRPCError(code: "access-denied", message: "That tool is switched off or its input is invalid.") }
                let args = params["arguments"].isNullish ? .object([]) : params["arguments"]
                guard try await consent(session, "mcp.call", .object([.init("serverId", .string(serverID)), .init("tool", .string(tool)), .init("arguments", args)])) else { throw NativeRPCError(code: "access-denied", message: "The tool call was not approved.") }
                try await Self.phoneAccessCheck?()
                guard views[key]?.ready == true, views[key]?.source == source else { throw NativeRPCError(code: "stale", message: "The chat app was reloaded while approval was open.") }
                // Re-read after consent, so a rewind, closed session, or changed policy invalidates it.
                guard try await attachment(session, rowID: rowID) != nil else { throw NativeRPCError(code: "stale", message: "The source chat changed.") }
                let currentPolicy = BackendMcpPolicy.load().servers[app.server["name"].string ?? ""] ?? .init()
                guard currentPolicy.on(client: app.conversation.provider, agentID: app.conversation.agentID), !currentPolicy.toolsOff.contains(tool) else {
                    throw NativeRPCError(code: "access-denied", message: "That tool's access changed while approval was open.")
                }
                try Task.checkCancellation()
                let result = try await call(serverID, app.conversation.project, tool, args)
                if result["ok"].bool == false { throw NativeRPCError(code: "unavailable", message: result["error"].string ?? "The tool call failed.") }
                return reply(result.has("result") ? result["result"] : result)
            case "resources/read":
                let uri = try params["uri"].requireString("resource", nonempty: true)
                guard uri.hasPrefix("ui://") else { throw NativeRPCError(code: "access-denied", message: "This view can read only UI resources from its server.") }
                let result = try await resource(serverID, app.conversation.project, uri, .object([]))
                if result["ok"].bool == false { throw NativeRPCError(code: "unavailable", message: result["error"].string ?? "The resource could not be read.") }
                return reply(result.has("result") ? result["result"] : result)
            case "ui/open-link":
                guard let text = params["url"].string, text.utf8.count <= 4096, let url = URL(string: text),
                      ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil,
                      try await consent(session, "mcp.open-link", .object([.init("url", .string(text))])) else {
                    return reply(.object([.init("isError", .bool(true))]))
                }
                try await Self.phoneAccessCheck?()
                guard views[key]?.ready == true, views[key]?.source == source,
                      let current = try await attachment(session, rowID: rowID), current.input == app.input,
                      current.server["id"] == app.server["id"], Self.uiURI(current.tool) == Self.uiURI(app.tool) else {
                    throw NativeRPCError(code: "stale", message: "The source chat changed while link approval was open.")
                }
                try Task.checkCancellation()
                return reply(.object([.init("isError", .bool(!(try await openLink(url))))]))
            case "ui/notifications/size-changed", "notifications/message": return .array([])
            default: throw NativeRPCError(code: "method-not-found", message: "This app view does not support that request.")
            }
        } catch {
            guard !id.isNullish else { return .array([]) }
            return .array([.object([.init("jsonrpc", .string("2.0")), .init("id", id), .init("error", .object([
                .init("code", .number((error as? NativeRPCError)?.code == "method-not-found" ? -32601 : -32000)),
                .init("message", .string(error.localizedDescription))]))])])
        }
    }
}
