import Foundation
import TerminalDeckNativeCore

/// Actual native remote-screen/conversation collector, supplied once by app
/// composition. It must consume the machine pushes, never a second PTY owner.
public struct BackendMachineMCPWatch: Sendable {
    public let screen: @Sendable (String, String) async throws -> NativeRPCValue?
    public let attached: @Sendable (String, String) async -> Bool
    public let conversation: @Sendable (String) async -> NativeRPCValue
    public let changed: @Sendable (String, Int) async throws -> Bool
    public let replied: @Sendable (String, String?, Int) async throws -> Bool
    public init(screen: @escaping @Sendable (String, String) async throws -> NativeRPCValue?, attached: @escaping @Sendable (String, String) async -> Bool,
                conversation: @escaping @Sendable (String) async -> NativeRPCValue, changed: @escaping @Sendable (String, Int) async throws -> Bool,
                replied: @escaping @Sendable (String, String?, Int) async throws -> Bool) { self.screen = screen; self.attached = attached; self.conversation = conversation; self.changed = changed; self.replied = replied }
}
public struct BackendMachineMCPAccess: Sendable {
    public let rpcContext: @Sendable (BackendMCPCallContext) async throws -> NativeRPCContext
    public let authorize: @Sendable (BackendMCPCallContext, String, NativeRPCValue, BackendMCPTier) async throws -> Void
    public let startedByYou: @Sendable (BackendMCPCallContext, String) async -> Bool
    public let noteStarted: @Sendable (BackendMCPCallContext, String) async -> Void
    public let requireLocalMachineAuthority: @Sendable (BackendMCPCallContext, NativeRPCContext) async throws -> Void
    public init(rpcContext: @escaping @Sendable (BackendMCPCallContext) async throws -> NativeRPCContext,
                authorize: @escaping @Sendable (BackendMCPCallContext, String, NativeRPCValue, BackendMCPTier) async throws -> Void,
                startedByYou: @escaping @Sendable (BackendMCPCallContext, String) async -> Bool,
                noteStarted: @escaping @Sendable (BackendMCPCallContext, String) async -> Void,
                requireLocalMachineAuthority: @escaping @Sendable (BackendMCPCallContext, NativeRPCContext) async throws -> Void) {
        self.rpcContext = rpcContext; self.authorize = authorize; self.startedByYou = startedByYou; self.noteStarted = noteStarted; self.requireLocalMachineAuthority = requireLocalMachineAuthority
    }
}

/// The six source machine-tools.ts identities and their real native handlers.
/// Registration needs the existing consent/log/ownership and watcher services.
public enum BackendMachineMCP {
    private struct Definition: Sendable { let id: String; let tier: BackendMCPTier; let fields: [String: String]; let required: [String]; let verbs: [String] }
    public static func startedKey(_ machineID: String, _ sessionID: String) -> String { "machine:\(machineID):\(sessionID)" }
    public static func register(server: BackendNativeMCPServer, registry: NativeChannelRegistry, watch: BackendMachineMCPWatch, access: BackendMachineMCPAccess) async throws -> [String] {
        let entries = try await contribution(registry: registry, watch: watch, access: access)
        try await server.replaceTools(ownerID: "native-machines-mcp", tools: entries)
        return entries.map { $0.0.id }
    }
    public static func contribution(registry: NativeChannelRegistry, watch: BackendMachineMCPWatch, access: BackendMachineMCPAccess) async throws -> [(BackendMCPTool, BackendNativeMCPServer.Handler)] {
        let definitions = [
            Definition(id: "machines.look", tier: .read, fields: ["machineId":"string", "sessionId":"string"], required: [], verbs: []),
            Definition(id: "machines.session", tier: .act, fields: ["machineId":"string", "do":"string", "sessionId":"string", "folder":"string", "agent":"string", "text":"string", "submit":"boolean", "keys":"array", "title":"string", "control":"string", "value":"string", "loginId":"string"], required: ["machineId", "do"], verbs: ["start", "send", "keys", "stop", "rename", "set", "switch-login", "watch"]),
            Definition(id: "machines.copilot", tier: .act, fields: ["machineId":"string", "do":"string", "text":"string", "messages":"integer", "waitSeconds":"integer"], required: ["machineId", "do"], verbs: ["read", "say", "start"]),
            Definition(id: "machines.ports", tier: .act, fields: ["machineId":"string", "do":"string", "port":"integer", "url":"string"], required: ["machineId", "do"], verbs: ["list", "refresh", "open-here", "close-here", "open-there"]),
            Definition(id: "machines.upload", tier: .act, fields: ["machineId":"string", "do":"string", "path":"string", "folder":"string"], required: ["machineId", "do"], verbs: ["send", "cancel"]),
            Definition(id: "machines.manage", tier: .alter, fields: ["machineId":"string", "do":"string", "code":"string", "name":"string", "allowed":"boolean", "loginId":"string"], required: ["do"], verbs: ["pair", "show-code", "cancel-code", "connect", "disconnect", "rename", "forget", "allow-windows", "restart-host", "stop-host", "sign-in", "sign-out", "github-connect", "github-cancel", "github-disconnect"]),
        ]
        // Checked per call, not here: in the full graph the deck-tools catalogue owns these six ids
        // before the machine registration (shared mode) installs the channels they call.
        var contribution: [(BackendMCPTool, BackendNativeMCPServer.Handler)] = []
        for definition in definitions {
            let properties = definition.fields.keys.sorted().map { key -> NativeRPCValue.Field in
                var value = NativeRPCValue.object([.init("type", .string(definition.fields[key]!))])
                if key == "do" { value = value.setting("enum", .array(definition.verbs.map(NativeRPCValue.string))) }
                if key == "keys" { value = value.setting("items", .object([.init("type", .string("string"))])) }
                if key == "agent" { value = value.setting("enum", .array(["claude", "codex", "gemini", "shell"].map(NativeRPCValue.string))) }
                if key == "control" { value = value.setting("enum", .array(BackendRemoteProtocol.controlIDs.map(NativeRPCValue.string))) }; return .init(key, value)
            }
            let schema = NativeRPCValue.object([.init("type", .string("object")), .init("properties", .object(properties)), .init("required", .array(definition.required.map(NativeRPCValue.string))), .init("additionalProperties", .bool(false))])
            let spec = try BackendMCPTool(id: definition.id, wireName: definition.id.replacingOccurrences(of: ".", with: "_"), description: description(definition.id), inputSchema: schema, tier: definition.tier)
            let handler: BackendNativeMCPServer.Handler = { caller, args in
                guard await registry.has("machines:list") else { throw NativeRPCError(code: "machine-mcp-dependency", message: "The native machine channels are not registered") }
                try validate(args, definition: definition)
                let rpc = try await access.rpcContext(caller)
                guard rpc.caller == .page, caller.machineID.isEmpty else { throw NativeRPCError(code: "machine-local-only", message: "Machine MCP calls require their authenticated local caller; a device cannot use this computer as a hop") }
                try await access.requireLocalMachineAuthority(caller, rpc)
                let machine = args["machineId"].string ?? "", session = args["sessionId"].string ?? "", verb = args["do"].string ?? ""
                if definition.id == "machines.session" && verb != "start" { _ = try args["sessionId"].requireString("sessionId", nonempty: true) }
                if !machine.isEmpty {
                    let current = try await registry.invoke("machines:list", context: rpc, arguments: [])
                    guard current["machines"].elements?.contains(where: { $0["id"].string == machine }) == true else { throw NativeRPCError(code: "unknown-machine", message: "There is no paired machine with that id. Use machines.look first.") }
                    if !session.isEmpty { guard current["links"].elements?.first(where: { $0["id"].string == machine })?["sessions"].elements?.contains(where: { $0["id"].string == session }) == true else { throw NativeRPCError(code: "unknown-session", message: "That machine has no visible session with that id") } }
                }
                var tier = definition.tier
                if definition.id == "machines.upload" && verb == "send" { tier = .alter }
                if definition.id == "machines.session" && !["start", "watch", "rename"].contains(verb) {
                    let own = await access.startedByYou(caller, startedKey(machine, session))
                    if !own || verb == "switch-login" || verb == "set" && args["control"].string == "permission" { tier = .alter }
                }
                guard caller.allowedTiers.contains(tier), !caller.cancellation.isCancelled else { throw NativeRPCError(code: "access-denied", message: "The caller cannot perform this machine action") }
                try await access.authorize(caller, definition.id, args, tier)
                let result = try await NativeCompositionCallContext.$rpc.withValue(rpc) {
                    try await run(definition.id, args: args, rpc: rpc, caller: caller, registry: registry, watch: watch, access: access)
                }
                return .value(result)
            }
            contribution.append((spec, handler))
        }
        return contribution
    }
    private static func run(_ tool: String, args: NativeRPCValue, rpc: NativeRPCContext, caller: BackendMCPCallContext,
                            registry: NativeChannelRegistry, watch: BackendMachineMCPWatch, access: BackendMachineMCPAccess) async throws -> NativeRPCValue {
        @Sendable func call(_ channel: String, _ values: [NativeRPCValue] = []) async throws -> NativeRPCValue { try Task.checkCancellation(); return try await registry.invoke(channel, context: rpc, arguments: values) }
        func text(_ key: String) throws -> String { try args[key].requireString(key, nonempty: true) }
        func number(_ key: String, _ range: ClosedRange<Int>, default fallback: Int? = nil) throws -> Int {
            if args[key] == .missing, let fallback { return fallback }; guard let value = args[key].number, value.isFinite, value.rounded() == value, value >= Double(range.lowerBound), value <= Double(range.upperBound) else { throw NativeRPCError.invalidArguments("\(key) is outside its integer bounds") }; return Int(value)
        }
        let machine = args["machineId"].string ?? "", session = args["sessionId"].string ?? "", verb = args["do"].string ?? ""
        let view = try await call("machines:list"), records = view["machines"].elements ?? [], links = view["links"].elements ?? []
        let record = records.first { $0["id"].string == machine }, link = links.first { $0["id"].string == machine }
        let sessions = link?["sessions"].elements ?? [], target = sessions.first { $0["id"].string == session }
        if !machine.isEmpty && record == nil { throw NativeRPCError(code: "unknown-machine", message: "There is no paired machine with that id. Use machines.look first.") }
        if !session.isEmpty && target == nil { throw NativeRPCError(code: "unknown-session", message: "That computer has no visible session with that id") }
        func result(_ fields: [NativeRPCValue.Field]) -> NativeRPCValue { .object([.init("machineId", .string(machine))] + fields) }
        if tool == "machines.look" {
            if machine.isEmpty { return .object([.init("thisComputer", view["here"]), .init("machines", .array(try await rows(view, caller: caller, access: access))), .init("cannotPairNow", view["blocked"])]) }
            if session.isEmpty {
                var row = try await rows(view, caller: caller, access: access).first { $0["id"].string == machine } ?? .object([])
                if link?["state"].string == "online" { for (channel, key) in [("machines:host:read", "host"), ("machines:logins:read", "logins"), ("machines:github:read", "github")] { let answer = try await call(channel, [.string(machine)]); row = row.setting(key, answer == .null ? .string("did not answer") : answer) } }
                else { row = row.setting("note", .string("That machine is not connected, so it cannot be asked anything right now.")) }; return row
            }
            guard let target else { throw NativeRPCError.invalidArguments("A session was not named") }
            var value = sessionRow(target).setting("machineId", .string(machine)).setting("machine", record?["name"] ?? .string(machine)).setting("startedByYou", .bool(await access.startedByYou(caller, startedKey(machine, session))))
            value = value.setting("screen", try await watch.screen(machine, session) ?? .null)
            value = value.setting("controls", try await call("machines:controls:read", [.string(machine), .string(session)]))
            value = value.setting("login", try await call("machines:account:read", [.string(machine), .string(session)]))
            value = value.setting("usage", .object([.init("plan", try await call("machines:usage:read", [.string(machine), .string(session), .string("plan"), .bool(false)])), .init("context", try await call("machines:usage:read", [.string(machine), .string(session), .string("context"), .bool(false)]))])); return value
        }
        if tool == "machines.session" {
            _ = try text("machineId")
            if verb == "start" {
                let before = Set(sessions.compactMap { $0["id"].string })
                let next = try await waitState(registry, milliseconds: 15000, predicate: { view in view["links"].elements?.first(where: { $0["id"].string == machine })?["sessions"].elements?.contains(where: { !before.contains($0["id"].string ?? "") }) == true }) { try assertOK(await call("machines:create", [.string(machine), args["folder"], args["agent"]])) }
                let created = next?["links"].elements?.first(where: { $0["id"].string == machine })?["sessions"].elements?.first { !before.contains($0["id"].string ?? "") }
                guard let created, let id = created["id"].string else { return result([.init("sessionId", .null), .init("note", .string("The request was sent, but no new session appeared within 15 seconds. Read the machine's sessions and allowed folders before trying again."))]) }
                await access.noteStarted(caller, startedKey(machine, id)); return sessionRow(created).setting("machineId", .string(machine)).setting("startedByYou", .bool(true))
            }
            _ = try text("sessionId"); guard let target else { throw NativeRPCError.invalidArguments("A visible remote session is required") }
            switch verb {
            case "send", "keys":
                guard target["exitCode"] == .null else { throw NativeRPCError.invalidArguments("That session has exited; there is nothing to type into") }
                let write: @Sendable (String) async throws -> Void = { data in try assertOK(await call("machines:send", [.string(machine), .string(session), .string(data)])) }
                if verb == "send" { try await BackendDeckCoreTyping.typeLine(write: write, text: BackendDeckCoreCatalogueRules.sanitizeSendText(text("text")), submit: args["submit"].bool != false) }
                else { try await BackendDeckCoreTyping.pressKeys(write: write, keys: BackendDeckCoreTyping.resolveKeys(args["keys"])) }; return result([.init("sessionId", .string(session)), .init("sent", .bool(true))])
            case "stop": try assertOK(await call("machines:close", [.string(machine), .string(session)])); return result([.init("sessionId", .string(session)), .init("stopRequested", .bool(true))])
            case "rename": try assertOK(await call("machines:session:rename", [.string(machine), .string(session), .string(args["title"].string ?? "")])); return result([.init("sessionId", .string(session)), .init("renameRequested", .bool(true))])
            case "set": let answer = try await call("machines:controls:apply", [.string(machine), .string(session), args["control"], args["value"]]); try assertOK(answer); return answer
            case "switch-login":
                let answer = try await call("machines:account:switch", [.string(machine), .string(session), .string(text("loginId"))]); try assertOK(answer)
                if let next = answer["session"].string, await access.startedByYou(caller, startedKey(machine, session)) { await access.noteStarted(caller, startedKey(machine, next)) }
                return result([.init("sessionId", answer["session"]), .init("previousSessionId", .string(session)), .init("message", answer["message"])])
            default:
                if !(await watch.attached(machine, session)) { try assertOK(await call("machines:attach", [.string(machine), .string(session), .number(120), .number(30)])) }
                return result([.init("sessionId", .string(session)), .init("watching", .bool(true)), .init("note", .string("machines.look with this sessionId shows the actual screen received here."))])
            }
        }
        if tool == "machines.ports" {
            switch verb {
            case "open-here": let answer = try await call("machines:reach", [.string(machine), .number(Double(number("port", 1...65535)))]); try assertOK(answer); return answer
            case "close-here": return result([.init("port", args["port"]), .init("closed", try await call("machines:reach:close", [.string(machine), .number(Double(number("port", 1...65535)))]))])
            case "open-there": let url = try text("url"); try assertOK(await call("machines:open", [.string(machine), .string(url)])); return result([.init("url", .string(url)), .init("opened", .bool(true))])
            default:
                if verb == "refresh" { _ = try await waitState(registry, milliseconds: 6000, predicate: { $0["links"].elements?.contains(where: { $0["id"].string == machine }) == true }) { try assertOK(await call("machines:ports", [.string(machine)])) } }
                let current = try await call("machines:list"); return result([.init("ports", current["links"].elements?.first(where: { $0["id"].string == machine })?["ports"] ?? .array([]))])
            }
        }
        if tool == "machines.upload" {
            if verb == "cancel" { return result([.init("cancelled", try await call("machines:upload:cancel", [.string(machine)]))]) }
            let answer = try await call("machines:upload", [.string(machine), .string(text("path")), args["folder"]]); try assertOK(answer); return answer
        }
        if tool == "machines.copilot" {
            let limit = try number("messages", 1...100, default: 20)
            if verb == "start" { try assertOK(await call("machines:copilot:start", [.string(machine)])) }
            else {
                let before = await watch.conversation(machine), waiting = Task { try await watch.changed(machine, 3000) }
                do { try assertOK(await call("machines:copilot:attach", [.string(machine)])); _ = try await call("machines:copilot:refresh", [.string(machine)]); if before["changedAt"] == .null || before["changedAt"] == .missing { _ = try await waiting.value } else { waiting.cancel() } }
                catch { waiting.cancel(); throw error }
            }
            var said: String?, answered: Bool?
            if verb == "say" {
                let text = try BackendDeckCoreCatalogueRules.sanitizeSendText(text("text")), before = await watch.conversation(machine)
                try assertOK(await call("machines:copilot:say", [.string(machine), .string(text)])); said = text
                let wait = try number("waitSeconds", 0...120, default: 0); if wait > 0 { answered = try await watch.replied(machine, before["messages"].elements?.last?["id"].string, wait * 1000) }
            }
            let current = await watch.conversation(machine)
            var value = result([.init("state", current["state"]), .init("run", current["run"]), .init("messages", .array(Array((current["messages"].elements ?? []).suffix(limit))))])
            if let said { value = value.setting("said", .string(said)) }; if let answered { value = value.setting("answered", .bool(answered)) }; return value
        }
        if verb == "show-code" { let answer = try await call("machines:code"); try assertOK(answer); return .object([.init("code", answer["code"]["token"]), .init("expiresAt", answer["code"]["expiresAt"]), .init("note", .string("Type this on the other computer's Machines list. It works once."))]) }
        if verb == "cancel-code" { return try await call("machines:code:cancel") }
        if verb == "pair" { let answer = try await call("machines:pair", [.string(text("code"))]); try assertOK(answer); return .object([.init("paired", .bool(true)), .init("machineId", answer["offer"]["hostId"]), .init("name", answer["offer"]["name"])]) }
        _ = try text("machineId")
        let channels = ["connect":"machines:connect", "disconnect":"machines:disconnect", "rename":"machines:rename", "forget":"machines:forget", "allow-windows":"machines:drive-windows", "restart-host":"machines:host:restart", "stop-host":"machines:host:stop", "sign-in":"machines:logins:signin", "sign-out":"machines:logins:signout", "github-connect":"machines:github:connect", "github-cancel":"machines:github:cancel", "github-disconnect":"machines:github:disconnect"]
        guard let channel = channels[verb] else { throw NativeRPCError.invalidArguments("Unknown machine management action") }
        var values: [NativeRPCValue] = [.string(machine)]
        if verb == "rename" { values.append(.string(try text("name"))) }; if verb == "allow-windows" { guard let allowed = args["allowed"].bool else { throw NativeRPCError.invalidArguments("allowed must be a boolean") }; values.append(.bool(allowed)) }
        if verb == "sign-in" || verb == "sign-out" { values.append(.string(try text("loginId"))) }
        let answer = try await call(channel, values)
        if channel.hasPrefix("machines:logins:") { try assertOK(answer) }
        if verb == "forget" { return result([.init("forgotten", .bool(!(answer["machines"].elements ?? []).contains(where: { $0["id"].string == machine })))]) }
        return answer
    }
    private static func assertOK(_ value: NativeRPCValue) throws { guard value.bool == true || value["ok"].bool == true else { throw NativeRPCError(code: "machine-refused", message: value["message"].string ?? "That machine could not be asked to perform the action") } }
    private static func rows(_ view: NativeRPCValue, caller: BackendMCPCallContext, access: BackendMachineMCPAccess) async throws -> [NativeRPCValue] {
        var rows: [NativeRPCValue] = []
        for record in view["machines"].elements ?? [] {
            let id = record["id"].string ?? "", link = view["links"].elements?.first { $0["id"].string == id }
            var sessions: [NativeRPCValue] = []
            for session in link?["sessions"].elements ?? [] { sessions.append(sessionRow(session).setting("startedByYou", .bool(await access.startedByYou(caller, startedKey(id, session["id"].string ?? ""))))) }
            rows.append(.object([.init("id", .string(id)), .init("name", record["name"]), .init("platform", record["platform"]), .init("state", link?["state"] ?? .string("offline")), .init("online", .bool(link?["state"].string == "online")), .init("why", link?["reason"] ?? .null), .init("sessions", .array(sessions)), .init("folders", link?["folders"] ?? .null), .init("ports", link?["ports"] ?? .array([])), .init("sharesCopilot", .bool(link != nil && link?["copilot"] != .null)), .init("hostVersion", link?["hostVersion"] ?? .string("")), .init("lastConnectedAt", record["lastConnectedAt"])]))
        }; return rows
    }
    private static func sessionRow(_ row: NativeRPCValue) -> NativeRPCValue { .object([.init("id", row["id"]), .init("title", row["title"]), .init("folder", row["cwd"]), .init("agent", row["provider"]), .init("status", row["status"]), .init("exitCode", row["exitCode"])]) }
    private static func waitState(_ registry: NativeChannelRegistry, milliseconds: Int, predicate: @escaping @Sendable (NativeRPCValue) -> Bool,
                                  after: @escaping @Sendable () async throws -> Void) async throws -> NativeRPCValue? {
        let events = try await registry.events("machines:state", ownerID: "machine-mcp-wait-" + UUID().uuidString)
        return try await withThrowingTaskGroup(of: NativeRPCValue?.self) { group in
            group.addTask { for try await event in events { if let value = event.arguments.first, predicate(value) { return value } }; return nil }
            group.addTask { try await Task.sleep(for: .milliseconds(milliseconds)); return nil }
            defer { group.cancelAll() }; try await after(); return try await group.next() ?? nil
        }
    }
    private static func validate(_ args: NativeRPCValue, definition: Definition) throws {
        _ = try args.requireObject("machine tool arguments")
        for field in args.fields ?? [] {
            guard let type = definition.fields[field.key] else { throw NativeRPCError.invalidArguments("Unknown machine tool argument") }
            let valid = type == "string" ? field.value.string != nil : type == "boolean" ? field.value.bool != nil : type == "array" ? field.value.elements != nil : field.value.number.map { $0.isFinite && $0.rounded() == $0 } == true
            guard valid else { throw NativeRPCError.invalidArguments("\(field.key) has the wrong type") }
        }
        for key in definition.required { _ = try args[key].requireString(key, nonempty: true) }
        if !definition.verbs.isEmpty, !definition.verbs.contains(args["do"].string ?? "") { throw NativeRPCError.invalidArguments("Unknown machine tool action") }
        if args["sessionId"] != .missing && args["machineId"] == .missing { throw NativeRPCError.invalidArguments("sessionId requires machineId") }
    }
    private static func description(_ id: String) -> String {
        ["machines.look":"List the actual paired computers, or one machine/session's host, logins, GitHub, received screen, controls and usage.", "machines.session":"Start, send printable text or keys, stop, rename, set controls, switch login or watch a visible session on a paired machine.", "machines.copilot":"Read, start or talk to the assistant that the other machine actually granted to this connection.", "machines.ports":"List/refresh a remote computer's ports, open or close an approved local tunnel, or open a URL there.", "machines.upload":"Send an authorized local file to the paired computer with checksum verification, or cancel its active transfer.", "machines.manage":"Pair, show/withdraw codes, manage saved machines/window grants, host lifecycle, agent logins or GitHub on that machine."][id]!
    }
}
