import Foundation
import TerminalDeckNativeCore

public struct BackendHootChatSetup: Codable, Sendable {
    private enum CodingKeys: String, CodingKey { case cwd, session, expectedTools, instructions }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        cwd = try c.decode(String.self, forKey: .cwd)
        session = try NativeRPCValue.parseJSON(c.decode(Data.self, forKey: .session))
        expectedTools = try c.decode([String: Set<String>].self, forKey: .expectedTools)
        instructions = try c.decode(String.self, forKey: .instructions)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(cwd, forKey: .cwd); try c.encode(session.encodedJSON(), forKey: .session)
        try c.encode(expectedTools, forKey: .expectedTools); try c.encode(instructions, forKey: .instructions)
    }
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
    public var carryHistory = false
    /// Full backend-only execution evidence; never forwarded as a public journal/snapshot field.
    public var executionEvidence: NativeRPCValue?
}

/// The installed Codex app-server and Gemini ACP protocols over the same pipes.
/// It owns no process, account, UI, permissions or second conversation store.
public struct BackendHootChatRPC: Sendable {
    public let provider: HootChatProvider
    private let setup: BackendHootChatSetup
    private enum Phase: Sendable { case idle, hello, session, catalog, catalogWait, ready }
    private var phase = Phase.idle
    private var helloID = "", sessionRequestID = "", catalogID = ""
    /// A saved conversation the CLI no longer has ("no rollout found") is replaced by a fresh
    /// one, once, silently: never a loop, never a raw error in Hoot's chat.
    private var resumeFellBack = false
    private var promptID: String?, interruptID: String?
    private var promptOwner: String?
    /// Server goals/realtime can start a turn without any client turn/start request.
    private var providerOwnedTurn = false
    private var planningTurn = false
    private var requestedSession: String?, sessionID: String?, providerTurnID: String?
    private var catalog: [String: NativeRPCValue] = [:]
    private var cursors: Set<String> = []
    private var toolRows: [String: NativeRPCValue] = [:]
    private var retiredTurns: Set<String> = []
    private var retiredTurnOrder: [String] = []
    private var turnOwners: [String: String] = [:]
    private var turnOrder: [String] = []
    private var hookOwners: [String: String] = [:]
    private var hookOrder: [String] = []
    private var earlyNotices: [NativeRPCValue] = []
    private var earlyTurnNotices: [NativeRPCValue] = []
    private var images = false, embeddedContext = false
    public var attachmentLimits: ChatAttachmentLimits {
        .init(provider: provider.rawValue, images: provider == .codex || images, documents: provider == .gemini && embeddedContext)
    }
    private var skillsID: String?
    private var skills: [String: NativeRPCValue] = [:]
    private var codexModel: String?
    private var compactID: String?
    private var childThreads: Set<String> = []
    private var completedChildThreads: Set<String> = []
    private var completedChildOrder: [String] = []
    private func knowsChild(_ id: String) -> Bool { childThreads.contains(id) || completedChildThreads.contains(id) }
    private mutating func updateChild(_ id: String, running: Bool) {
        if running {
            completedChildThreads.remove(id); completedChildOrder.removeAll { $0 == id }
            childThreads.insert(id)
        } else {
            childThreads.remove(id)
            // A completed child may resume or spawn a descendant; retain only recent identities.
            if completedChildThreads.insert(id).inserted {
                completedChildOrder.append(id)
                if completedChildOrder.count > 256 { completedChildThreads.remove(completedChildOrder.removeFirst()) }
            }
        }
    }
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
        let params = provider == .codex ? Self.object([("clientInfo", client),
            ("capabilities", Self.object([("experimentalApi", .bool(true))]))]) :
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
        if let skillsID, id == skillsID {
            self.skillsID = nil
            if row["error"].isNullish { skills = BackendCodexChatCommands.skills(row["result"], cwd: setup.cwd) }
            var update = BackendHootChatRPCUpdate()
            update.records = [commandRecord()]
            return update
        }
        if id == helloID && phase == .hello {
            try requireSuccess(row)
            if provider == .gemini {
                guard row["result"]["protocolVersion"].number == 1 else { throw unavailable("Gemini returned an unsupported ACP version.") }
                let capabilities = row["result"]["agentCapabilities"]
                images = capabilities["promptCapabilities"]["image"].bool == true
                embeddedContext = capabilities["promptCapabilities"]["embeddedContext"].bool == true
                if !setup.instructions.isEmpty && !embeddedContext { throw unavailable("Gemini cannot receive Hoot's composed instruction context.") }
                if requestedSession != nil && capabilities["loadSession"].bool != true {
                    requestedSession = nil; resumeFellBack = true
                }
                if !setup.expectedTools.isEmpty && capabilities["mcpCapabilities"]["http"].bool != true { throw unavailable("Gemini cannot attach Hoot's HTTP tools.") }
            }
            phase = .session; sessionRequestID = helloID + ":session"
            var params = setup.session.setting("cwd", .string(setup.cwd))
            if provider == .gemini, !params.has("mcpServers") { params = params.setting("mcpServers", .array([])) }
            if let requestedSession { params = params.setting(provider == .codex ? "threadId" : "sessionId", .string(requestedSession)) }
            let method = provider == .codex ? (requestedSession == nil ? "thread/start" : "thread/resume") : (requestedSession == nil ? "session/new" : "session/load")
            var result = BackendHootChatRPCUpdate()
            result.carryHistory = resumeFellBack
            if provider == .codex { result.send.append(Self.request("initialized")) }
            result.send.append(Self.request(method, id: .string(sessionRequestID), params: params)); return result
        }
        if id == sessionRequestID && phase == .session {
            // A sign-in problem is the person's to fix and must stay in front of them: never a fresh conversation, never a retry.
            if !row["error"].isNullish, Self.needsSignIn(errorText(row)) {
                throw NativeRPCError(code: "sign-in-required", message: "Hoot needs you to sign in again to \(provider == .codex ? "Codex" : "Gemini"). Open Settings › Coding AIs, sign in, then send your message again.")
            }
            // Only a saved conversation the CLI really no longer has is replaced by a fresh one (once, silently).
            if !row["error"].isNullish, let lost = requestedSession, !resumeFellBack, Self.conversationGone(errorText(row)) {
                resumeFellBack = true; requestedSession = nil
                NSLog("[native Hoot] the CLI could not resume conversation %@ (%@); starting a fresh one", lost, errorText(row))
                sessionRequestID = helloID + ":session-new"
                var params = setup.session.setting("cwd", .string(setup.cwd))
                if provider == .gemini, !params.has("mcpServers") { params = params.setting("mcpServers", .array([])) }
                var result = BackendHootChatRPCUpdate()
                result.carryHistory = true
                result.send.append(Self.request(provider == .codex ? "thread/start" : "session/new", id: .string(sessionRequestID), params: params))
                return result
            }
            try requireSuccess(row)
            let received = provider == .codex ? row["result"]["thread"]["id"] : row["result"]["sessionId"]
            // ACP load may return only its modes/configOptions; its request ID is authoritative.
            let actual = received.string ?? (provider == .gemini ? requestedSession : nil)
            guard let actual, !actual.isEmpty, actual.utf8.count <= 512 else { throw unavailable("The CLI returned no conversation ID.") }
            guard requestedSession == nil || actual == requestedSession else { throw unavailable("The CLI resumed a different conversation.") }
            sessionID = actual
            var update = BackendHootChatRPCUpdate()
            update.records = [.init(.session, value: Self.object([("sessionId", .string(actual)), ("sessionTreeId", row["result"]["thread"]["sessionId"])]))]
            if provider == .codex {
                update.executionEvidence = BackendChatOwnedTerminals.executionEvidence(row["result"], conversation: actual,
                    source: requestedSession == nil ? "thread/start" : "thread/resume")
            }
            if let policy = BackendChatProviderPolicy.resolvedSession(row["result"], provider: provider, conversation: actual,
                source: requestedSession == nil ? "thread/start" : "thread/resume") {
                update.records.append(.init(.session, value: Self.object([("effectivePolicy", policy)])))
            }
            if provider == .codex, let receipt = BackendChatProviderPolicy.instructionReceipt(row["result"], conversation: actual,
                source: requestedSession == nil ? "thread/start" : "thread/resume") {
                update.records.append(.init(.session, value: Self.object([("instructionReceipt", receipt)])))
            }
            if provider == .codex && !setup.expectedTools.isEmpty { update.send = [catalogRequest()] }
            else { phase = .ready; update.ready = true }
            if provider == .codex {
                codexModel = row["result"]["model"].string ?? setup.session["model"].string
                skillsID = helloID + ":skills"
                update.records.append(commandRecord())
                update.send.append(Self.request("skills/list", id: .string(skillsID!),
                    params: Self.object([("cwds", .array([.string(setup.cwd)]))])))
            }
            let notices = earlyNotices; earlyNotices = []
            for notice in notices { update.records += try notification(notice).records }
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
                self.promptID = nil; providerTurnID = nil; compactID = nil
                update.records = [.text(.error, errorText(row)), .init(.completed)]
            } else if compactID == id {
                // This is only an acknowledgement. Completion arrives as thread/compacted.
                return update
            } else if provider == .gemini {
                self.promptID = nil
                if row["result"]["stopReason"].string == "cancelled" {
                    update.records.append(.init(.interrupted, value: Self.object([("stopReason", row["result"]["stopReason"])])))
                }
                update.records.append(.init(.completed, value: row["result"]))
            } else if let turn = row["result"]["turn"]["id"].string {
                providerTurnID = turn; rememberTurn(turn, owner: promptOwner ?? promptID)
                let notices = earlyTurnNotices; earlyTurnNotices = []
                for notice in notices { update.records += try notification(notice).records }
            }
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
    private func commandRecord() -> HootChatRecord {
        .init(.session, value: Self.object([("commands", BackendCodexChatCommands.menu(model: codexModel, skills: skills))]))
    }
    /// Native review is a foreground turn: its reply and all later items must use the same
    /// lifecycle tracking as a normal prompt, including interruption and stale-turn rejection.
    public mutating func review(arguments: NativeRPCValue, id: String) throws -> NativeRPCValue {
        guard provider == .codex, phase == .ready, let sessionID, promptID == nil, providerTurnID == nil, !providerOwnedTurn else {
            throw unavailable("The Codex conversation is not ready for a review.")
        }
        let target = try BackendChatProviderReview.target(arguments)
        promptID = id; promptOwner = id; providerTurnID = nil; toolRows = [:]; planningTurn = false
        return Self.request("review/start", id: .string(id), params: Self.object([
            ("threadId", .string(sessionID)), ("delivery", .string("inline")), ("target", target)]))
    }
    public mutating func user(_ text: String, attachments: [NativeRPCValue], id: String, commandText: String? = nil, ownerTurnID: String? = nil) throws -> NativeRPCValue {
        guard phase == .ready, let sessionID, promptID == nil, providerTurnID == nil, !providerOwnedTurn else { throw unavailable("Hoot's RPC conversation is not ready for another message.") }
        promptOwner = ownerTurnID ?? id
        var content = [Self.object([("type", .string("text")), ("text", .string(text))])]
        planningTurn = provider == .codex && BackendCodexChatCommands.split(commandText ?? text)?.name == "plan"
        var collaboration: NativeRPCValue?
        if provider == .codex, let codexModel {
            collaboration = Self.object([("mode", .string("default")), ("settings", Self.object([("model", .string(codexModel))]))])
        }
        if provider == .codex, let command = BackendCodexChatCommands.split(commandText ?? text) {
            if ["compact", "review"].contains(command.name) {
                guard attachments.isEmpty else { throw NativeRPCError.invalidArguments("Send attachments in a normal message.") }
                if command.name == "compact", !command.arguments.isEmpty { throw NativeRPCError.invalidArguments("Use /compact without arguments.") }
                promptID = id; providerTurnID = nil; toolRows = [:]
                if command.name == "compact" {
                    compactID = id
                    return Self.request("thread/compact/start", id: .string(id), params: Self.object([("threadId", .string(sessionID))]))
                }
                let target = command.arguments.isEmpty ? Self.object([("type", .string("uncommittedChanges"))]) :
                    Self.object([("type", .string("custom")), ("instructions", .string(command.arguments))])
                return Self.request("review/start", id: .string(id), params: Self.object([("threadId", .string(sessionID)), ("target", target)]))
            }
            if command.name == "init" {
                content[0] = Self.object([("type", .string("text")), ("text", .string(text + "\n\nCreate an AGENTS.md file with instructions for this project. Inspect the project first and preserve any existing instructions. " + command.arguments))])
            } else if command.name == "plan", let codexModel {
                collaboration = Self.object([("mode", .string("plan")), ("settings", Self.object([("model", .string(codexModel))]))])
                content[0] = Self.object([("type", .string("text")), ("text", .string(text + "\n\n" + (command.arguments.isEmpty ? "Plan the next task. Ask what to plan if needed." : command.arguments)))])
            } else if let skill = skills[command.name] {
                content[0] = Self.object([("type", .string("text")), ("text", .string(text + "\n\n$" + command.name + " " + command.arguments))])
                content.append(Self.object([("type", .string("skill")), ("name", .string(command.name)), ("path", skill["path"])]))
            }
        }
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
        var params = Self.object([(provider == .codex ? "threadId" : "sessionId", .string(sessionID)),
                                  (provider == .codex ? "input" : "prompt", .array(content))])
        if let collaboration { params = params.setting("collaborationMode", collaboration) }
        return Self.request(provider == .codex ? "turn/start" : "session/prompt", id: .string(id), params: params)
    }
    /// Encoding-only preview for Send now's interrupt-then-send path. Clearing an active
    /// turn on this value copy never changes or sends a request on the live adapter.
    public func previewUser(_ text: String, attachments: [NativeRPCValue], id: String, commandText: String? = nil) throws -> NativeRPCValue {
        var preview = self
        preview.promptID = nil; preview.providerTurnID = nil; preview.providerOwnedTurn = false
        return try preview.user(text, attachments: attachments, id: id, commandText: commandText)
    }
    public mutating func interrupt() throws -> NativeRPCValue {
        guard let sessionID, promptID != nil || providerOwnedTurn else { throw NativeRPCError.invalidArguments("Hoot has no active RPC turn.") }
        if provider == .gemini { return Self.request("session/cancel", params: Self.object([("sessionId", .string(sessionID))])) }
        guard let providerTurnID else { throw unavailable("Codex has not acknowledged this turn yet.") }
        let id = UUID().uuidString; interruptID = id
        return Self.request("turn/interrupt", id: .string(id), params: Self.object([("threadId", .string(sessionID)), ("turnId", .string(providerTurnID))]))
    }
    public func steer(_ text: String, attachments: [NativeRPCValue], id: String) throws -> NativeRPCValue {
        guard provider == .codex, phase == .ready, promptID != nil || providerOwnedTurn, let sessionID, let providerTurnID else {
            throw unavailable("Codex has not acknowledged an active turn to steer yet.")
        }
        var input = [Self.object([("type", .string("text")), ("text", .string(text)), ("text_elements", .array([]))])]
        for attachment in attachments {
            let source = attachment["source"]
            guard attachment["type"].string == "image", let media = source["media_type"].string,
                  let data = source["data"].string else { throw NativeRPCError.invalidArguments("Codex steering accepts image attachments only.") }
            input.append(Self.object([("type", .string("image")), ("url", .string("data:\(media);base64,\(data)"))]))
        }
        return Self.request("turn/steer", id: .string(id), params: Self.object([
            ("threadId", .string(sessionID)), ("expectedTurnId", .string(providerTurnID)), ("input", .array(input))]))
    }
    private func matches(_ params: NativeRPCValue) -> Bool {
        (provider == .codex ? params["threadId"].string : params["sessionId"].string) == sessionID && sessionID != nil
    }
    private func matchesTurn(_ params: NativeRPCValue) -> Bool {
        matches(params) && (promptID != nil || providerOwnedTurn) && providerTurnID != nil && (params["turnId"].string ?? params["turn"]["id"].string) == providerTurnID
    }
    private mutating func rememberTurn(_ id: String, owner: String) {
        if turnOwners[id] == nil { turnOrder.append(id) }
        turnOwners[id] = owner
        if turnOrder.count > 256 { turnOwners.removeValue(forKey: turnOrder.removeFirst()) }
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
        let kind = BackendChatElicitation.requestKind(Self.object([("subtype", .string(method)), ("input", params)]))
        // Request kind only: tool arguments, form answers and authentication links can contain secrets.
        NSLog("[native chat] provider=%@ request=%@ kind=%@", provider.rawValue, method, kind)
        update.records = [.init(.approval, id: id, value: Self.object([
            ("requestId", .string(id)), ("rpcId", rawID), ("subtype", .string(method)), ("requestKind", .string(kind)), ("name", .string(name ?? method)),
            ("input", params), ("toolId", provider == .gemini ? params["toolCall"]["toolCallId"] : params["itemId"])]))]
        return update
    }
    public func answer(_ request: HootChatRecord, allowed: Bool, answers: NativeRPCValue = .object([])) throws -> NativeRPCValue {
        let input = request.value["input"], method = request.value["subtype"].string ?? "", id = request.value["rpcId"]
        guard matches(input), phase == .ready, !id.isNullish else { throw unavailable("This CLI question no longer belongs to Hoot.") }
        try BackendChatApproval.validate(request.value, allowed: allowed, answers: answers)
        let scope = answers["scope"].string ?? BackendChatApproval.defaultScope(request.value)
        let result: NativeRPCValue
        if provider == .gemini {
            let kind = allowed ? "allow_once" : "reject_once"
            if BackendChatApproval.validGeminiOptions(request.value),
               let choice = input["options"].elements?.first(where: { allowed ? $0["optionId"].string == scope : $0["kind"].string == kind })?["optionId"].string {
                result = Self.object([("outcome", Self.object([("outcome", .string("selected")), ("optionId", .string(choice))]))])
            } else if !allowed { result = Self.object([("outcome", Self.object([("outcome", .string("cancelled"))]))]) }
            else { throw unavailable("Gemini did not offer a one-use approval; no persistent permission was granted.") }
        } else if method == "item/permissions/requestApproval" {
            result = Self.object([("permissions", allowed ? input["permissions"] : .object([])), ("scope", .string(allowed && scope == "session" ? "session" : "turn"))])
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
                guard input["mode"].isNullish || input["mode"].string == "form", answers.fields != nil else {
                    throw NativeRPCError.invalidArguments("This tool server needs a supported form and structured answers.")
                }
                for key in input["requestedSchema"]["required"].elements?.compactMap(\.string) ?? [] {
                    guard answers.has(key) else { throw NativeRPCError.invalidArguments("Answer Hoot's \(key) field first.") }
                }
            }
            if allowed, input["mode"].string == "url", BackendChatElicitation.authURL(request.value) == nil {
                throw NativeRPCError.invalidArguments("This tool server sent an invalid authentication link.")
            }
            result = Self.object([("action", .string(allowed ? "accept" : "decline")), ("content", allowed && input["mode"].string != "url" ? answers : .null)])
        } else {
            guard ["item/commandExecution/requestApproval", "item/fileChange/requestApproval"].contains(method) else { throw NativeRPCError.invalidArguments("Unknown Hoot approval method.") }
            result = Self.object([("decision", BackendChatApproval.codexDecision(request.value, allowed: allowed, scope: scope))])
        }
        return Self.object([("jsonrpc", .string("2.0")), ("id", id), ("result", result)])
    }
    private mutating func notification(_ row: NativeRPCValue) throws -> BackendHootChatRPCUpdate {
        let method = row["method"].string ?? "", params = row["params"]
        if provider == .codex {
            let notices = ["hook/started", "hook/completed", "warning", "guardianWarning"]
            if phase == .session, sessionID == nil, notices.contains(method), params["threadId"].string != nil {
                if earlyNotices.count < 64 { earlyNotices.append(row) }; return .init()
            }
            if ["warning", "guardianWarning", "configWarning"].contains(method) {
                guard params["threadId"].isNullish || matches(params) else { return .init() }
                let text = params["message"].string ?? params["summary"].string
                guard let text else { return .init() }
                var update = BackendHootChatRPCUpdate()
                update.records = [.init(.session, value: Self.object([("warning", .string(text)),
                    ("providerWarning", params.setting("sourceEvent", .string(method))), ("eventTurnId", .string(""))]))]
                return update
            }
            if ["hook/started", "hook/completed"].contains(method) {
                guard matches(params), let id = params["run"]["id"].string, !id.isEmpty else { return .init() }
                let owner: String
                if let turn = params["turnId"].string {
                    guard let known = turnOwners[turn] else {
                        if providerTurnID == nil, earlyTurnNotices.count < 64 { earlyTurnNotices.append(row) }
                        return .init()
                    }; owner = known
                    if let previous = hookOwners[id], previous != owner { return .init() }
                } else { owner = hookOwners[id] ?? "" }
                if method == "hook/started" {
                    if hookOwners[id] == nil { hookOrder.append(id) }
                    hookOwners[id] = owner
                    if hookOrder.count > 512 { hookOwners.removeValue(forKey: hookOrder.removeFirst()) }
                }
                var record = HootChatProviderRecords.hook(params["run"], source: method)
                record = .init(record.kind, id: record.messageID, value: record.value.setting("eventTurnId", .string(owner))
                    .setting("providerSessionId", params["threadId"]).setting("providerTurnId", params["turnId"]))
                var update = BackendHootChatRPCUpdate(); update.records = [record]
                return update
            }
            if method == "model/rerouted" {
                guard matches(params), let turn = params["turnId"].string else { return .init() }
                guard let owner = turnOwners[turn] else {
                    if providerTurnID == nil, earlyTurnNotices.count < 64 { earlyTurnNotices.append(row) }
                    return .init()
                }
                guard
                      let record = HootChatProviderRecords.modelReceipt(params["toModel"], session: params["threadId"],
                        turn: params["turnId"], source: method) else { return .init() }
                var update = BackendHootChatRPCUpdate()
                update.records = [.init(.session, value: record.value.setting("eventTurnId", .string(owner))
                    .setting("modelReroute", params))]
                return update
            }
        }
        if provider == .codex, method == "mcpServerStatus/updated", phase == .catalogWait,
           (matches(params) || (params["threadId"].isNullish && setup.expectedTools[params["name"].string ?? ""] != nil)) {
            catalog = [:]; cursors = []
            var update = BackendHootChatRPCUpdate(); update.send = [catalogRequest()]; return update
        }
        if provider == .codex, method == "thread/started", let root = sessionID,
           let parent = params["thread"]["parentThreadId"].string ?? params["thread"]["source"]["subAgent"]["thread_spawn"]["parent_thread_id"].string, parent == root || knowsChild(parent),
           let thread = params["thread"]["id"].string, !thread.isEmpty, thread != root {
            updateChild(thread, running: true)
            var update = BackendHootChatRPCUpdate()
            var task = ChatChildTasks.codexAgent(thread, status: "running", title: params["thread"]["agentNickname"].string, parentThreadId: parent)
            for key in ["source", "agentPath", "agentRole", "agentNickname", "senderThreadId"] where !params["thread"][key].isNullish { task = task.setting(key, params["thread"][key]) }
            update.records = [.init(.session, value: Self.object([("childTask", task)]))]
            return update
        }
        if provider == .codex, ["turn/started", "turn/completed"].contains(method), let thread = params["threadId"].string, knowsChild(thread) {
            var update = BackendHootChatRPCUpdate()
            let status = method == "turn/started" ? "running" : params["turn"]["status"].string ?? "completed"
            updateChild(thread, running: method == "turn/started")
            update.records = [.init(.session, value: Self.object([("childTask", ChatChildTasks.codexAgent(thread, status: status))]))]
            return update
        }
        guard matches(params) else { return .init() }
        var update = BackendHootChatRPCUpdate()
        if provider == .codex {
            if method == "mcpServerStatus/updated" && phase == .catalogWait { catalog = [:]; cursors = []; update.send = [catalogRequest()]; return update }
            if method == "thread/compacted", compactID != nil {
                compactID = nil; promptID = nil; providerTurnID = nil
                update.records = [.text(.message, "Conversation compacted."), .init(.completed)]
                return update
            }
            if method == "turn/started" {
                // A confirmed resume can start its goal while required MCP discovery is still
                // pending. Track that work without marking the catalogue/handshake ready.
                guard phase == .ready || phase == .catalog || phase == .catalogWait,
                      let turn = params["turn"]["id"].string, !turn.isEmpty,
                      turn.utf8.count <= 512, !turn.contains(where: { $0.isWhitespace || $0 == "\0" }), !retiredTurns.contains(turn) else { return update }
                if let promptID {
                    guard providerTurnID == nil || providerTurnID == turn else { return update }
                    providerTurnID = turn; rememberTurn(turn, owner: promptOwner ?? promptID)
                    let notices = earlyTurnNotices; earlyTurnNotices = []
                    for notice in notices { update.records += try notification(notice).records }
                } else if providerTurnID == nil, !providerOwnedTurn, params["turn"]["status"].string == "inProgress" {
                    let owner = "provider:" + turn
                    providerTurnID = turn; providerOwnedTurn = true; promptOwner = owner
                    planningTurn = false; toolRows = [:]; compactID = nil
                    rememberTurn(turn, owner: owner)
                    update.records = [.init(.session, value: Self.object([("providerTurnStarted", Self.object([
                        ("providerSessionId", params["threadId"]), ("providerTurnId", .string(turn)),
                        ("turnId", .string(owner)), ("origin", .string("provider")), ("source", .string(method))]))]))]
                    let notices = earlyTurnNotices; earlyTurnNotices = []
                    for notice in notices { update.records += try notification(notice).records }
                }
                return update
            }
            if method == "thread/tokenUsage/updated" {
                // Deck Memory: how much is in view after this step (Codex's own numbers).
                let usage = params["tokenUsage"], last = usage["last"]
                let tokens = last["totalTokens"].number ?? ((last["inputTokens"].number ?? 0) + (last["outputTokens"].number ?? 0))
                if tokens > 0 { update.records = [.init(.session, value: Self.object([("deskUsage", Self.object([("tokens", .number(tokens)), ("window", usage["modelContextWindow"])]))]))] }
                let total = usage["total"].fields != nil
                let figures = ChatReportedUsage.metrics(total ? usage["total"] : last)
                if !(figures.fields ?? []).isEmpty {
                    update.records.append(.init(.session, value: Self.object([("cliUsage", figures.setting("scope", .string(total ? "Conversation total" : "Latest request")))])))
                }
                return update
            }
            // Child lifecycle can arrive after its parent's foreground turn has ended.
            if ["item/started", "item/completed"].contains(method), params["item"]["type"].string == "subAgentActivity" {
                for task in ChatChildTasks.codexAgents(params["item"]) where task["threadId"].string != sessionID {
                    if let thread = task["threadId"].string {
                        updateChild(thread, running: ChatChildTasks.running(task))
                    }
                    update.records.append(.init(.session, value: Self.object([("childTask", task)])))
                }
                return update
            }
            let fileNotice = ["turn/diff/updated", "item/fileChange/patchUpdated", "item/fileChange/outputDelta"].contains(method)
            let fileOwner = params["turnId"].string.flatMap { turnOwners[$0] }
            guard matchesTurn(params) || fileNotice && fileOwner != nil else { return update }
            let review = BackendChatProviderReview.records(row, conversation: sessionID ?? "")
            if !review.isEmpty { update.records = review; return update }
            switch method {
            case "item/fileChange/patchUpdated":
                if let changes = params["changes"].elements {
                    update.records = [.init(.toolCall, id: params["itemId"].string ?? "", value: Self.object([
                        ("name", .string("fileChange")), ("input", Self.object([("changes", .array(changes)), ("sourceEvent", .string(method))]))]))]
                }
            case "item/fileChange/outputDelta":
                update.records = [.init(.toolResult, id: params["itemId"].string ?? "", value: Self.object([
                    ("output", params["delta"]), ("partial", .bool(true)), ("sourceEvent", .string(method))]))]
            case "turn/diff/updated":
                guard let diff = params["diff"].string else { break }
                let changes = HootChatProviderRecords.unifiedChanges(diff)
                if !changes.isEmpty {
                    update.records = [.init(.toolCall, id: "turn-diff:" + (params["turnId"].string ?? ""), value: Self.object([
                        ("name", .string("fileChange")), ("input", Self.object([("changes", .array(changes)),
                            ("sourceEvent", .string(method)), ("aggregate", .bool(true))]))]))]
                } else {
                    update.records = [.init(.session, value: Self.object([("providerDiff", Self.object([
                        ("sourceEvent", .string(method)), ("diff", diff.utf8.count <= 2_097_152 ? .string(diff) : .null),
                        ("bytes", .number(Double(diff.utf8.count))), ("filesUnresolved", .bool(true))]))]))]
                }
            case "item/reasoning/summaryPartAdded", "item/reasoning/summaryTextDelta":
                update.records = [.init(.session, value: Self.object([("reasoning", Self.object([
                    ("id", params["itemId"]), ("part", params["summaryIndex"]),
                    ("phase", .string(method.hasSuffix("summaryTextDelta") ? "delta" : "start")), ("text", params["delta"])]))]))]
            case "turn/plan/updated":
                update.records = [.init(.session, value: Self.object([("todoPlan", params["plan"]), ("explanation", params["explanation"])]))]
            case "item/agentMessage/delta": update.records = [.text(.textDelta, id: params["itemId"].string ?? "", params["delta"].string ?? "")]
            case "item/plan/delta":
                update.records = [.init(.textDelta, id: params["itemId"].string ?? "", value: Self.object([("text", params["delta"]), ("planReview", .bool(true))]))]
            case "item/started", "item/completed":
                let item = params["item"], id = item["id"].string ?? "", done = method == "item/completed"
                if item["type"].string == "reasoning" {
                    let summary = (item["summary"].elements ?? []).compactMap(\.string).joined(separator: "\n\n")
                    update.records = [.init(.session, value: Self.object([("reasoning", Self.object([
                        ("id", .string(id)), ("phase", .string(done ? "full" : "start")), ("text", .string(summary))]))]))]
                } else if ["agentMessage", "plan"].contains(item["type"].string ?? "") {
                    if done { update.records = [.init(.message, id: id, value: Self.object([("text", item["text"]), ("planReview", .bool(planningTurn || item["type"].string == "plan"))]))] }
                } else if ["commandExecution", "mcpToolCall", "fileChange", "webSearch", "collabAgentToolCall", "dynamicToolCall"].contains(item["type"].string ?? "") {
                    let name = item["tool"].string ?? item["command"].string ?? item["type"].string ?? "Tool"
                    update.records = [.init(.toolCall, id: id, value: Self.object([("name", .string(name)), ("input", item)]))]
                    for task in ChatChildTasks.codexAgents(item) where task["threadId"].string != sessionID {
                        if let thread = task["threadId"].string {
                            updateChild(thread, running: ChatChildTasks.running(task))
                        }
                        update.records.append(.init(.session, value: Self.object([("childTask", task)])))
                    }
                    if done { update.records.append(.init(.toolResult, id: id, value: Self.object([("output", item["result"].isNullish ? item["aggregatedOutput"] : item["result"]), ("status", item["status"]), ("isError", .bool(item["status"].string == "failed")), ("exitCode", item["exitCode"])]))) }
                }
            case "item/commandExecution/outputDelta": update.records = [.init(.toolResult, id: params["itemId"].string ?? "", value: Self.object([("output", params["delta"]), ("partial", .bool(true))]))]
            case "turn/completed":
                if params["turn"]["status"].string == "failed" { update.records.append(.text(.error, params["turn"]["error"]["message"].string ?? "Codex's turn failed.")) }
                if params["turn"]["status"].string == "interrupted" {
                    update.records.append(.init(.interrupted, value: Self.object([
                        ("stopReason", params["turn"]["error"]["message"].string.map(NativeRPCValue.string) ?? .string("interrupted")),
                        ("providerTurnId", params["turn"]["id"]), ("providerStop", params["turn"])])))
                }
                update.records.append(.init(.completed, value: params["turn"]))
                if let providerTurnID, retiredTurns.insert(providerTurnID).inserted {
                    retiredTurnOrder.append(providerTurnID)
                    if retiredTurnOrder.count > 256 { retiredTurns.remove(retiredTurnOrder.removeFirst()) }
                }
                promptID = nil; providerTurnID = nil; compactID = nil; providerOwnedTurn = false; promptOwner = nil
            case "error": update.records = [.text(.error, params["error"]["message"].string ?? "Codex reported an error.")]
            default: break
            }
            if fileNotice, let fileOwner {
                update.records = update.records.map { .init($0.kind, id: $0.messageID, value: $0.value.setting("eventTurnId", .string(fileOwner))) }
            }
        } else if method == "session/update", params["update"]["sessionUpdate"].string == "available_commands_update" {
            // The "/" menu: the commands Gemini itself offers (ACP), whenever it tells them.
            let offered = (params["update"]["availableCommands"].elements ?? []).compactMap { row -> NativeRPCValue? in
                guard let name = row["name"].string, !name.isEmpty else { return nil }
                return Self.object([("name", .string(name)), ("description", row["description"]), ("argumentHint", row["input"]["hint"])])
            }
            update.records = [.init(.session, value: Self.object([("commands", .array(offered))]))]
        } else if method == "session/update", promptID != nil {
            let body = params["update"], kind = body["sessionUpdate"].string
            switch kind {
            case "agent_message_chunk":
                if let text = body["content"]["text"].string { update.records = [.text(.textDelta, id: promptID ?? "", text)] }
            case "tool_call", "tool_call_update":
                guard let id = body["toolCallId"].string else { throw NativeRPCError.malformed("Gemini tool step has no ID.") }
                let previous = toolRows[id] ?? .object([]), current = previous.merging(body); toolRows[id] = current
                let changes = HootChatProviderRecords.acpChanges(current["content"])
                let input = changes.isEmpty ? (current["rawInput"].isNullish ? current["content"] : current["rawInput"]) :
                    Self.object([("changes", .array(changes)), ("providerInput", current["rawInput"]), ("sourceEvent", .string("session/update/diff"))])
                update.records = [.init(.toolCall, id: id, value: Self.object([("name", changes.isEmpty ? current["title"] : .string("fileChange")), ("input", input)]))]
                if ["completed", "failed"].contains(current["status"].string ?? "") {
                    update.records.append(.init(.toolResult, id: id, value: Self.object([("output", current["rawOutput"].isNullish ? current["content"] : current["rawOutput"]), ("status", current["status"]), ("isError", .bool(current["status"].string == "failed"))])))
                }
            default: break
            }
        }
        return update
    }
    /// "no rollout found for thread id …", "session not found": the CLI no longer has the saved conversation.
    static func conversationGone(_ message: String) -> Bool {
        let text = message.lowercased()
        return ["no rollout found", "not found", "no such", "does not exist", "unknown thread", "unknown session", "no conversation", "missing rollout"].contains { text.contains($0) }
            && !needsSignIn(message)
    }
    /// The CLI says the account is not signed in (or its sign-in ran out).
    static func needsSignIn(_ message: String) -> Bool {
        let text = message.lowercased()
        return ["authentication", "authenticate", "unauthorized", "unauthenticated", "not logged in", "not signed in", "log in", "login", "sign in", "api key", "credential", "401"].contains { text.contains($0) }
    }
    private func requireSuccess(_ row: NativeRPCValue) throws {
        guard row["error"].isNullish, row.has("result") else { throw unavailable(errorText(row)) }
    }
    private func errorText(_ row: NativeRPCValue) -> String { row["error"]["message"].string ?? "Hoot's CLI request failed." }
    private func unavailable(_ text: String) -> NativeRPCError { .init(code: "unavailable", message: text) }
}
