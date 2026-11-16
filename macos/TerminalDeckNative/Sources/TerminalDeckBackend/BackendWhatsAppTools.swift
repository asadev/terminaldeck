import Foundation
import TerminalDeckNativeCore

/// WhatsApp agents' tools (DESIGN-WHATSAPP.md section 6; every feature ships with its tools). Reading is free; adding,
/// removing, renaming and replacing a key ask him first; moving a receiver and sending ask him unless the call comes from
/// the place that WhatsApp agent is received. A key (`apiKey`) is taken as an argument by `add` and `replace_key` only and is never
/// in an answer, an error or the action log (`redactArgs`).
public enum BackendWhatsAppTools {
    public static let agentsID = "whatsapp.agents", addID = "whatsapp.add", removeID = "whatsapp.remove", renameID = "whatsapp.rename"
    public static let replaceKeyID = "whatsapp.replace_key", receiveID = "whatsapp.receive", sendID = "whatsapp.send"
    public static let sendingID = "whatsapp.sending"
    public static let pageIDs: Set<String> = [agentsID, addID, removeID, renameID, replaceKeyID, receiveID, sendID, sendingID]

    public struct Actions: Sendable {
        public var engine: @Sendable () async -> BackendWhatsAppAgents?
        public init(engine: @escaping @Sendable () async -> BackendWhatsAppAgents?) { self.engine = engine }
        public static let none = Actions(engine: { nil })
    }
    public static let notReady = NativeRPCError(code: "unavailable", message: "WhatsApp agents are not ready on this computer yet.")

    static let agentArg = #""agent":{"type":"string","description":"The WhatsApp agent's id or its name as listed by whatsapp_agents."}"#
    static let specs: [(id: String, tier: BackendMCPTier, title: String, description: String, schema: String)] = [
        (agentsID, .read, "WhatsApp agents",
         "The person's WhatsApp agents (each a WhatsApp chat he talks to Terminal Deck through): id, name, state (connected, waiting for his first message, key refused), where it is received (Hoot, an agent, a session, or nowhere), which computer answers it, and when his last message came. Never a key.",
         #"{"type":"object","properties":{},"additionalProperties":false}"#),
        (addID, .alter, "Add a WhatsApp agent",
         "Add one of his WhatsApp agents by the API key he copied in WhatsApp (the agent's chat > Chat info > API key). WhatsApp checks the key first; a refused key adds nothing. Any number, from one or several WhatsApp accounts. The first one is received by Hoot.",
         #"{"type":"object","properties":{"name":{"type":"string"},"apiKey":{"type":"string"}},"required":["apiKey"],"additionalProperties":false}"#),
        (removeID, .alter, "Remove a WhatsApp agent",
         "Remove a WhatsApp agent from Terminal Deck on every computer (its key goes to the saved passwords' Bin for 30 days). The agent itself stays in WhatsApp.",
         "{\"type\":\"object\",\"properties\":{\(agentArg)},\"required\":[\"agent\"],\"additionalProperties\":false}"),
        (renameID, .alter, "Rename a WhatsApp agent",
         "Give a WhatsApp agent another name in Terminal Deck (also the name of its Hoot or agent conversation).",
         "{\"type\":\"object\",\"properties\":{\(agentArg),\"name\":{\"type\":\"string\"}},\"required\":[\"agent\",\"name\"],\"additionalProperties\":false}"),
        (replaceKeyID, .alter, "Replace a WhatsApp agent's key",
         "Give a WhatsApp agent a new API key (after he made a new one in WhatsApp, or when the old one was refused). WhatsApp checks it first.",
         "{\"type\":\"object\",\"properties\":{\(agentArg),\"apiKey\":{\"type\":\"string\"}},\"required\":[\"agent\",\"apiKey\"],\"additionalProperties\":false}"),
        (receiveID, .act, "Where a WhatsApp agent is received",
         "Move a WhatsApp agent to Hoot, one of his agents, one session, or nowhere: from then on his WhatsApp messages go there and every final answer given there goes back to WhatsApp. kind: hoot, agent (id = the agent's id), session (id = the session's id), nowhere. Asks him first unless this call comes from the place that WhatsApp agent is received now.",
         "{\"type\":\"object\",\"properties\":{\(agentArg),\"kind\":{\"type\":\"string\",\"enum\":[\"hoot\",\"agent\",\"session\",\"nowhere\"]},\"id\":{\"type\":\"string\"},\"name\":{\"type\":\"string\"}},\"required\":[\"agent\",\"kind\"],\"additionalProperties\":false}"),
        (sendID, .act, "Send on WhatsApp",
         "Send him one text on a WhatsApp agent (for example: tell him on WhatsApp when the build is done). Only ever to that agent's creator, who is him. Asks him first unless this call comes from the place that WhatsApp agent is received.",
         "{\"type\":\"object\",\"properties\":{\(agentArg),\"text\":{\"type\":\"string\"}},\"required\":[\"agent\",\"text\"],\"additionalProperties\":false}"),
        (sendingID, .act, "Send answers to WhatsApp",
         "Turn a WhatsApp agent's switch on or off: on, every final answer and approval question of the place it is received goes to WhatsApp; off, nothing is sent there and the conversation carries on in Terminal Deck (the agent stays attached; a message he writes from WhatsApp turns it on again). Asks him first unless this call comes from the place that WhatsApp agent is received.",
         "{\"type\":\"object\",\"properties\":{\(agentArg),\"on\":{\"type\":\"boolean\"}},\"required\":[\"agent\",\"on\"],\"additionalProperties\":false}"),
    ]

    public static func definitions(access: BackendDeckToolsAppAccess, actions: Actions) throws -> [BackendDeckToolsDefinition] {
        try specs.map { entry in
            let spec = try BackendMCPTool(id: entry.id, wireName: entry.id.replacingOccurrences(of: ".", with: "_"), description: entry.description,
                                          inputSchema: NativeRPCValue.parseJSON(Data(entry.schema.utf8)), tier: entry.tier)
            return BackendDeckToolsDefinition(spec: spec, title: entry.title, index: entry.title + " (WhatsApp agents).") { context, args in
                try await BackendDeckToolsSupport.reply {
                    guard context.allowedTools.contains(spec.id) || context.allowedTools.contains(spec.wireName), context.allowedTiers.contains(entry.tier) else {
                        throw NativeRPCError(code: "not-granted", message: "This caller cannot use the WhatsApp tools.")
                    }
                    return .value(try await run(spec.id, args, access: access, context: context, actions: actions))
                }
            }
        }
    }

    /// The arguments as the action log and the question keep them: never the key (`apiKey` is also a secret name the
    /// action log hides by itself).
    public static func redacted(_ args: NativeRPCValue) -> NativeRPCValue { args.has("apiKey") ? args.setting("apiKey", .string("[hidden]")) : args }

    static func wire(_ profile: WhatsAppAgentProfile) -> NativeRPCValue {
        let receiver: NativeRPCValue
        switch profile.receiver {
        case .nowhere: receiver = BackendDeckToolsSupport.object([("kind", .string("nowhere"))])
        case .hoot: receiver = BackendDeckToolsSupport.object([("kind", .string("hoot")), ("name", .string("Hoot"))])
        case .agent(let id, let name): receiver = BackendDeckToolsSupport.object([("kind", .string("agent")), ("id", .string(id)), ("name", .string(name))])
        case .session(let id, let name): receiver = BackendDeckToolsSupport.object([("kind", .string("session")), ("id", .string(id)), ("name", .string(name))])
        }
        let state: String = switch profile.state { case .connected: "connected"; case .waiting: "waiting for his first message"; case .refused: "key refused" }
        return BackendDeckToolsSupport.object([
            ("id", .string(profile.id)), ("name", .string(profile.name)), ("state", .string(state)), ("receivedBy", receiver),
            ("sending", .bool(profile.sending)),
            ("answeredBy", profile.answeringComputerName.map(NativeRPCValue.string) ?? .null), ("answeredHere", .bool(profile.answeredHere)),
            ("lastMessage", profile.lastMessageAt.map { .string(ISO8601DateFormatter().string(from: $0)) } ?? .null)])
    }

    static func find(_ engine: BackendWhatsAppAgents, _ args: NativeRPCValue) async throws -> WhatsAppAgentProfile {
        let wanted = try args["agent"].requireString("agent", nonempty: true)
        let all = await engine.agents()
        if let byID = all.first(where: { $0.id == wanted }) { return byID }
        let named = all.filter { $0.name.caseInsensitiveCompare(wanted) == .orderedSame }
        guard named.count == 1, let one = named.first else {
            throw NativeRPCError.invalidArguments(named.isEmpty ? "There is no WhatsApp agent called \(wanted)." : "Two WhatsApp agents are called \(wanted); use its id.")
        }
        return one
    }
    static func receiver(_ args: NativeRPCValue) throws -> WhatsAppReceiver {
        let kind = try args["kind"].requireString("kind", nonempty: true)
        switch kind {
        case "hoot": return .hoot
        case "nowhere": return .nowhere
        case "agent", "session":
            let id = try args["id"].requireString("id", nonempty: true)
            let name = args["name"].string ?? id
            return kind == "agent" ? .agent(id: id, name: name) : .session(id: id, name: name)
        default: throw NativeRPCError.invalidArguments("kind is hoot, agent, session or nowhere.")
        }
    }
    static func plain<T>(_ work: () async throws -> T) async throws -> T {
        do { return try await work() }
        catch let problem as WhatsAppProblem { throw NativeRPCError(code: "refused", message: problem.message) }
    }

    static func run(_ id: String, _ args: NativeRPCValue, access: BackendDeckToolsAppAccess, context: BackendMCPCallContext, actions: Actions) async throws -> NativeRPCValue {
        guard let engine = await actions.engine() else { throw notReady }
        let shown = redacted(args)
        switch id {
        case agentsID:
            try await access.authorize(context, id, shown, .read, "See your WhatsApp agents", false)
            return BackendDeckToolsSupport.object([("agents", .array(await engine.agents().map(wire)))])
        case addID:
            let name = args["name"].string ?? ""
            try await access.authorize(context, id, shown, .alter, "Add the WhatsApp agent " + (name.isEmpty ? "(a new one)" : name), true)
            let key = try args["apiKey"].requireString("apiKey", nonempty: true)
            return wire(try await plain { try await engine.add(name: name, key: key) })
        case removeID:
            let agent = try await find(engine, args)
            try await access.authorize(context, id, shown, .alter, "Remove the WhatsApp agent " + agent.name + " from every computer", true)
            try await plain { try await engine.remove(agent.id) }
            return BackendDeckToolsSupport.object([("removed", .string(agent.name))])
        case renameID:
            let agent = try await find(engine, args), name = try args["name"].requireString("name", nonempty: true)
            try await access.authorize(context, id, shown, .alter, "Rename the WhatsApp agent " + agent.name + " to " + name, true)
            try await plain { try await engine.rename(agent.id, to: name) }
            return BackendDeckToolsSupport.object([("renamed", .string(name))])
        case replaceKeyID:
            let agent = try await find(engine, args)
            try await access.authorize(context, id, shown, .alter, "Give the WhatsApp agent " + agent.name + " a new key", true)
            let key = try args["apiKey"].requireString("apiKey", nonempty: true)
            try await plain { try await engine.replaceKey(agent.id, key: key) }
            return BackendDeckToolsSupport.object([("replaced", .string(agent.name))])
        case receiveID:
            let agent = try await find(engine, args), target = try receiver(args)
            let own = await engine.isFrom(sessionID: context.sessionID, agent: agent.id)
            try await access.authorize(context, id, shown, own ? .act : .alter, "Receive the WhatsApp agent " + agent.name + " in " + target.title, !own)
            try await plain { try await engine.setReceiver(agent.id, target) }
            return wire(await engine.agents().first { $0.id == agent.id } ?? agent)
        case sendID:
            let agent = try await find(engine, args), text = try args["text"].requireString("text", nonempty: true)
            let own = await engine.isFrom(sessionID: context.sessionID, agent: agent.id)
            try await access.authorize(context, id, shown, own ? .act : .alter, "Send on WhatsApp (" + agent.name + "): " + String(text.prefix(200)), !own)
            try await plain { try await engine.send(agent.id, text: text) }
            return BackendDeckToolsSupport.object([("sent", .bool(true))])
        case sendingID:
            let agent = try await find(engine, args)
            guard let on = args["on"].bool else { throw NativeRPCError.invalidArguments("on is true or false.") }
            let own = await engine.isFrom(sessionID: context.sessionID, agent: agent.id)
            try await access.authorize(context, id, shown, own ? .act : .alter,
                                       (on ? "Send answers to WhatsApp (" : "Stop sending answers to WhatsApp (") + agent.name + ")", !own)
            try await plain { try await engine.setSending(on, for: agent.id) }
            return wire(await engine.agents().first { $0.id == agent.id } ?? agent)
        default:
            throw NativeRPCError.invalidArguments("Unknown WhatsApp tool.")
        }
    }
}
