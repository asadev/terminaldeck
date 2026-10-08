import Foundation
import TerminalDeckNativeCore

public struct BackendHootChatSetup: Sendable {
    public let cwd: String
    public let session: NativeRPCValue
    public let expectedTools: [String: Set<String>]
    public let instructions: String
    public init(cwd: String, session: NativeRPCValue = .object([]), expectedTools: [String: Set<String>] = [:], instructions: String = "") {
        self.cwd = cwd; self.session = session; self.expectedTools = expectedTools; self.instructions = instructions
    }
}

public struct BackendHootChatRPCUpdate: Sendable {
    public var records: [HootChatRecord] = []
    public var send: [NativeRPCValue] = []
    public var ready = false
}

/// The installed Codex app-server and Gemini ACP protocols over the same pipes.
/// It owns no process, account, UI, permissions or second conversation store.
public struct BackendHootChatRPC: Sendable {
    public let provider: HootChatProvider
    private let setup: BackendHootChatSetup
    private enum Phase: Sendable { case idle, hello, session, catalog, catalogWait, ready }
    private var phase = Phase.idle
    private var helloID = "", sessionRequestID = "", catalogID = ""
    private var promptID: String?, interruptID: String?
    private var requestedSession: String?, sessionID: String?, providerTurnID: String?
    private var catalog: [String: NativeRPCValue] = [:]
    private var cursors: Set<String> = []
    private var toolRows: [String: NativeRPCValue] = [:]
    private var retiredTurns: Set<String> = []
    private var images = false, embeddedContext = false
    public init(provider: HootChatProvider, setup: BackendHootChatSetup) {
        self.provider = provider; self.setup = setup
    }
    private static func object(_ fields: [(String, NativeRPCValue)]) -> NativeRPCValue {
        .object(fields.map { .init($0.0, $0.1) })
    }
    public static func request(_ method: String, id: NativeRPCValue? = nil, params: NativeRPCValue = .object([])) -> NativeRPCValue {
        var value = object([("jsonrpc", .string("2.0")), ("method", .string(method)), ("params", params)])
        if let id { value = value.setting("id", id) }; return value
    }
    public mutating func begin(id: String, resume: String?) throws -> NativeRPCValue {
        guard provider != .claude, phase == .idle else { throw NativeRPCError.invalidArguments("Invalid Hoot RPC initialization.") }
        helloID = id; requestedSession = resume; phase = .hello
        let client = Self.object([("name", .string("hoot")), ("version", .string("1"))])
        let params = provider == .codex ? Self.object([("clientInfo", client)]) :
            Self.object([("protocolVersion", .number(1)), ("clientInfo", client), ("clientCapabilities", Self.object([("terminal", .bool(false))]))])
        return Self.request("initialize", id: .string(id), params: params)
    }
    public mutating func receive(_ row: NativeRPCValue) throws -> BackendHootChatRPCUpdate {
        guard row.fields != nil else { throw NativeRPCError.malformed("Expected a Hoot JSON-RPC object.") }
        if row["method"].string != nil {
            if !row["id"].isNullish { return try serverRequest(row) }
            return try notification(row)
        }
        let id = row["id"].string
        if id == helloID && phase == .hello {
            try requireSuccess(row)
            if provider == .gemini {
                guard row["result"]["protocolVersion"].number == 1 else { throw unavailable("Gemini returned an unsupported ACP version.") }
                let capabilities = row["result"]["agentCapabilities"]
                images = capabilities["promptCapabilities"]["image"].bool == true
                embeddedContext = capabilities["promptCapabilities"]["embeddedContext"].bool == true
                if !setup.instructions.isEmpty && !embeddedContext { throw unavailable("Gemini cannot receive Hoot's composed instruction context.") }
                if requestedSession != nil && capabilities["loadSession"].bool != true { throw unavailable("Gemini cannot load this saved session.") }
                if !setup.expectedTools.isEmpty && capabilities["mcpCapabilities"]["http"].bool != true { throw unavailable("Gemini cannot attach Hoot's HTTP tools.") }
            }
            phase = .session; sessionRequestID = helloID + ":session"
            var params = setup.session.setting("cwd", .string(setup.cwd))
            if provider == .gemini, !params.has("mcpServers") { params = params.setting("mcpServers", .array([])) }
            if let requestedSession { params = params.setting(provider == .codex ? "threadId" : "sessionId", .string(requestedSession)) }
            let method = provider == .codex ? (requestedSession == nil ? "thread/start" : "thread/resume") : (requestedSession == nil ? "session/new" : "session/load")
            var result = BackendHootChatRPCUpdate()
            if provider == .codex { result.send.append(Self.request("initialized")) }
            result.send.append(Self.request(method, id: .string(sessionRequestID), params: params)); return result
        }
        if id == sessionRequestID && phase == .session {
            try requireSuccess(row)
            let received = provider == .codex ? row["result"]["thread"]["id"] : row["result"]["sessionId"]
            // ACP load may return only its modes/configOptions; its request ID is authoritative.
            let actual = received.string ?? (provider == .gemini ? requestedSession : nil)
            guard let actual, !actual.isEmpty, actual.utf8.count <= 512 else { throw unavailable("The CLI returned no conversation ID.") }
            guard requestedSession == nil || actual == requestedSession else { throw unavailable("The CLI resumed a different conversation.") }
            sessionID = actual
            var update = BackendHootChatRPCUpdate()
            update.records = [.init(.session, value: Self.object([("sessionId", .string(actual)), ("sessionTreeId", row["result"]["thread"]["sessionId"])]))]
            if provider == .codex && !setup.expectedTools.isEmpty { update.send = [catalogRequest()] }
            else { phase = .ready; update.ready = true }
            return update
        }
        if id == catalogID && phase == .catalog {
            try requireSuccess(row)
            for item in try row["result"]["data"].requireArray("MCP server status") {
                if let name = item["name"].string { catalog[name] = item }
            }
            if let cursor = row["result"]["nextCursor"].string {
                guard cursors.count < 20, cursors.insert(cursor).inserted else { throw unavailable("Codex MCP status pagination did not finish.") }
                var update = BackendHootChatRPCUpdate(); update.send = [catalogRequest(cursor: cursor)]; return update
            }
            for (name, expected) in setup.expectedTools {
                guard let server = catalog[name] else { throw unavailable("Codex did not attach Hoot's \(name) tool server.") }
                if !server["toolsError"].isNullish { throw unavailable("Codex could not load Hoot's \(name) tools.") }
                let state = server["runtimeStatus"].string ?? server["runtimeStatus"]["status"].string
                if state == "starting" { phase = .catalogWait; return .init() }
                if state == "failed" || state == "cancelled" { throw unavailable("Codex's \(name) tool server is \(state ?? "unavailable").") }
                guard expected.isSubset(of: Set(server["tools"].fields?.map(\.key) ?? [])) else { throw unavailable("Codex's Hoot tool catalogue is incomplete.") }
            }
            phase = .ready; var update = BackendHootChatRPCUpdate(); update.ready = true; return update
        }
        if let promptID, id == promptID {
            var update = BackendHootChatRPCUpdate()
            if !row["error"].isNullish {
                self.promptID = nil; providerTurnID = nil
                update.records = [.text(.error, errorText(row)), .init(.completed)]
            } else if provider == .gemini {
                self.promptID = nil
                if row["result"]["stopReason"].string == "cancelled" { update.records.append(.init(.interrupted)) }
                update.records.append(.init(.completed, value: row["result"]))
            } else if let turn = row["result"]["turn"]["id"].string { providerTurnID = turn }
            return update
        }
        if let interruptID, id == interruptID {
            self.interruptID = nil; try requireSuccess(row); return .init()
        }
        return .init() // Late/foreign replies never acquire a request or session.
    }
    private mutating func catalogRequest(cursor: String? = nil) -> NativeRPCValue {
        phase = .catalog; catalogID = UUID().uuidString
        var params = Self.object([("threadId", sessionID.map(NativeRPCValue.string) ?? .null), ("limit", .number(100))])
        if let cursor { params = params.setting("cursor", .string(cursor)) }
        return Self.request("mcpServerStatus/list", id: .string(catalogID), params: params)
    }
    public mutating func user(_ text: String, attachments: [NativeRPCValue], id: String) throws -> NativeRPCValue {
        guard phase == .ready, let sessionID, promptID == nil else { throw unavailable("Hoot's RPC conversation is not ready for another message.") }
        var content = [Self.object([("type", .string("text")), ("text", .string(text))])]
        if provider == .gemini && !setup.instructions.isEmpty {
            content.insert(Self.object([("type", .string("resource")), ("resource", Self.object([
                ("uri", .string("hoot://instructions")), ("mimeType", .string("text/markdown")), ("text", .string(setup.instructions))]))]), at: 0)
        }
        for attachment in attachments {
            let source = attachment["source"], media = source["media_type"].string ?? ""
            guard let data = source["data"].string else { throw NativeRPCError.invalidArguments("Missing Hoot attachment data.") }
            if provider == .codex {
                guard attachment["type"].string == "image" else { throw NativeRPCError.invalidArguments("Codex accepts image attachments here; use a text message for documents.") }
                content.append(Self.object([("type", .string("image")), ("url", .string("data:\(media);base64,\(data)"))]))
            } else if attachment["type"].string == "image" {
                guard images else { throw unavailable("Gemini did not advertise image attachments.") }
                content.append(Self.object([("type", .string("image")), ("data", .string(data)), ("mimeType", .string(media))]))
            } else {
                guard embeddedContext else { throw unavailable("Gemini did not advertise embedded document context.") }
                content.append(Self.object([("type", .string("resource")), ("resource", Self.object([
                    ("uri", .string("hoot://attachment/" + UUID().uuidString)), ("mimeType", .string(media)), ("blob", .string(data))]))]))
            }
        }
        promptID = id; providerTurnID = nil; toolRows = [:]
        return Self.request(provider == .codex ? "turn/start" : "session/prompt", id: .string(id),
            params: Self.object([(provider == .codex ? "threadId" : "sessionId", .string(sessionID)),
                                 (provider == .codex ? "input" : "prompt", .array(content))]))
    }
    public mutating func interrupt() throws -> NativeRPCValue {
        guard let sessionID, promptID != nil else { throw NativeRPCError.invalidArguments("Hoot has no active RPC turn.") }
        if provider == .gemini { return Self.request("session/cancel", params: Self.object([("sessionId", .string(sessionID))])) }
        guard let providerTurnID else { throw unavailable("Codex has not acknowledged this turn yet.") }
        let id = UUID().uuidString; interruptID = id
        return Self.request("turn/interrupt", id: .string(id), params: Self.object([("threadId", .string(sessionID)), ("turnId", .string(providerTurnID))]))
    }
    private func matches(_ params: NativeRPCValue) -> Bool {
        (provider == .codex ? params["threadId"].string : params["sessionId"].string) == sessionID && sessionID != nil
    }
    private func matchesTurn(_ params: NativeRPCValue) -> Bool {
        matches(params) && promptID != nil && providerTurnID != nil && (params["turnId"].string ?? params["turn"]["id"].string) == providerTurnID
    }
    private mutating func serverRequest(_ row: NativeRPCValue) throws -> BackendHootChatRPCUpdate {
        let method = row["method"].string ?? "", params = row["params"], rawID = row["id"]
        guard rawID.string != nil || rawID.number != nil else { throw NativeRPCError.malformed("Invalid CLI request ID.") }
        let supported = provider == .codex ? ["item/commandExecution/requestApproval", "item/fileChange/requestApproval", "item/permissions/requestApproval", "item/tool/requestUserInput", "tool/requestUserInput", "mcpServer/elicitation/request"] : ["session/request_permission"]
        var update = BackendHootChatRPCUpdate()
        let staleTurn = provider == .codex && params["turnId"].string.map { retiredTurns.contains($0) } == true
        guard matches(params), phase == .ready, supported.contains(method), !staleTurn else {
            update.send = [Self.object([("jsonrpc", .string("2.0")), ("id", rawID), ("error", Self.object([("code", .number(-32601)), ("message", .string("Unsupported or out-of-scope Hoot client request."))]))])]
            return update
        }
        let name = provider == .gemini ? params["toolCall"]["title"].string : params["command"].string ?? params["reason"].string
        let id = rawID.compact // Distinguishes the numeric 1 from the string "1".
        update.records = [.init(.approval, id: id, value: Self.object([
            ("requestId", .string(id)), ("rpcId", rawID), ("subtype", .string(method)), ("name", .string(name ?? method)),
            ("input", params), ("toolId", provider == .gemini ? params["toolCall"]["toolCallId"] : params["itemId"])]))]
        return update
    }
    public func answer(_ request: HootChatRecord, allowed: Bool, answers: NativeRPCValue = .object([])) throws -> NativeRPCValue {
        let input = request.value["input"], method = request.value["subtype"].string ?? "", id = request.value["rpcId"]
        guard matches(input), phase == .ready, !id.isNullish else { throw unavailable("This CLI question no longer belongs to Hoot.") }
        let result: NativeRPCValue
        if provider == .gemini {
            let kind = allowed ? "allow_once" : "reject_once"
            if let choice = input["options"].elements?.first(where: { $0["kind"].string == kind })?["optionId"].string {
                result = Self.object([("outcome", Self.object([("outcome", .string("selected")), ("optionId", .string(choice))]))])
            } else if !allowed { result = Self.object([("outcome", Self.object([("outcome", .string("cancelled"))]))]) }
            else { throw unavailable("Gemini did not offer a one-use approval; no persistent permission was granted.") }
        } else if method == "item/permissions/requestApproval" {
            result = Self.object([("permissions", allowed ? input["permissions"] : .object([])), ("scope", .string("turn"))])
        } else if method == "tool/requestUserInput" || method == "item/tool/requestUserInput" {
            if allowed {
                guard answers.fields != nil else { throw NativeRPCError.invalidArguments("Hoot's question answers must be an object.") }
                for question in input["questions"].elements ?? [] {
                    let key = try question["id"].requireString("question id", nonempty: true)
                    guard let values = answers[key]["answers"].elements, !values.isEmpty, values.allSatisfy({ $0.string != nil }) else {
                        throw NativeRPCError.invalidArguments("Answer Hoot's \(question["header"].string ?? key) question first.")
                    }
                }
            }
            result = Self.object([("answers", allowed ? answers : .object([]))])
        } else if method == "mcpServer/elicitation/request" {
            if allowed && input["mode"].string != "url" {
                for key in input["requestedSchema"]["required"].elements?.compactMap(\.string) ?? [] {
                    guard answers.has(key) else { throw NativeRPCError.invalidArguments("Answer Hoot's \(key) field first.") }
                }
            }
            result = Self.object([("action", .string(allowed ? "accept" : "decline")), ("content", allowed ? answers : .null)])
        } else {
            guard ["item/commandExecution/requestApproval", "item/fileChange/requestApproval"].contains(method) else { throw NativeRPCError.invalidArguments("Unknown Hoot approval method.") }
            result = Self.object([("decision", .string(allowed ? "accept" : "decline"))])
        }
        return Self.object([("jsonrpc", .string("2.0")), ("id", id), ("result", result)])
    }
    private mutating func notification(_ row: NativeRPCValue) throws -> BackendHootChatRPCUpdate {
        let method = row["method"].string ?? "", params = row["params"]
        if provider == .codex, method == "mcpServerStatus/updated", phase == .catalogWait,
           (matches(params) || (params["threadId"].isNullish && setup.expectedTools[params["name"].string ?? ""] != nil)) {
            catalog = [:]; cursors = []
            var update = BackendHootChatRPCUpdate(); update.send = [catalogRequest()]; return update
        }
        guard matches(params) else { return .init() }
        var update = BackendHootChatRPCUpdate()
        if provider == .codex {
            if method == "mcpServerStatus/updated" && phase == .catalogWait { catalog = [:]; cursors = []; update.send = [catalogRequest()]; return update }
            if method == "turn/started", promptID != nil {
                if let turn = params["turn"]["id"].string, !retiredTurns.contains(turn) { providerTurnID = turn }
                return update
            }
            guard matchesTurn(params) else { return update }
            switch method {
            case "item/agentMessage/delta": update.records = [.text(.textDelta, id: params["itemId"].string ?? "", params["delta"].string ?? "")]
            case "item/started", "item/completed":
                let item = params["item"], id = item["id"].string ?? "", done = method == "item/completed"
                if item["type"].string == "agentMessage" {
                    if done { update.records = [.text(.message, id: id, item["text"].string ?? "")] }
                } else if ["commandExecution", "mcpToolCall", "fileChange", "webSearch", "collabAgentToolCall", "dynamicToolCall"].contains(item["type"].string ?? "") {
                    let name = item["tool"].string ?? item["command"].string ?? item["type"].string ?? "Tool"
                    update.records = [.init(.toolCall, id: id, value: Self.object([("name", .string(name)), ("input", item)]))]
                    if done { update.records.append(.init(.toolResult, id: id, value: Self.object([("output", item["result"].isNullish ? item["aggregatedOutput"] : item["result"]), ("status", item["status"]), ("isError", .bool(item["status"].string == "failed")), ("exitCode", item["exitCode"])]))) }
                }
            case "item/commandExecution/outputDelta": update.records = [.init(.toolResult, id: params["itemId"].string ?? "", value: Self.object([("output", params["delta"]), ("partial", .bool(true))]))]
            case "turn/completed":
                if params["turn"]["status"].string == "failed" { update.records.append(.text(.error, params["turn"]["error"]["message"].string ?? "Codex's turn failed.")) }
                if params["turn"]["status"].string == "interrupted" { update.records.append(.init(.interrupted)) }
                update.records.append(.init(.completed, value: params["turn"]))
                if let providerTurnID { retiredTurns.insert(providerTurnID) }
                promptID = nil; providerTurnID = nil
            case "error": update.records = [.text(.error, params["error"]["message"].string ?? "Codex reported an error.")]
            default: break
            }
        } else if method == "session/update", promptID != nil {
            let body = params["update"], kind = body["sessionUpdate"].string
            switch kind {
            case "agent_message_chunk":
                if let text = body["content"]["text"].string { update.records = [.text(.textDelta, id: promptID ?? "", text)] }
            case "tool_call", "tool_call_update":
                guard let id = body["toolCallId"].string else { throw NativeRPCError.malformed("Gemini tool step has no ID.") }
                let previous = toolRows[id] ?? .object([]), current = previous.merging(body); toolRows[id] = current
                update.records = [.init(.toolCall, id: id, value: Self.object([("name", current["title"]), ("input", current["rawInput"].isNullish ? current["content"] : current["rawInput"])]))]
                if ["completed", "failed"].contains(current["status"].string ?? "") {
                    update.records.append(.init(.toolResult, id: id, value: Self.object([("output", current["rawOutput"].isNullish ? current["content"] : current["rawOutput"]), ("status", current["status"]), ("isError", .bool(current["status"].string == "failed"))])))
                }
            default: break
            }
        }
        return update
    }
    private func requireSuccess(_ row: NativeRPCValue) throws {
        guard row["error"].isNullish, row.has("result") else { throw unavailable(errorText(row)) }
    }
    private func errorText(_ row: NativeRPCValue) -> String { row["error"]["message"].string ?? "Hoot's CLI request failed." }
    private func unavailable(_ text: String) -> NativeRPCError { .init(code: "unavailable", message: text) }
}
