import Foundation
import TerminalDeckNativeCore

extension BackendDeckToolsSessionsArea {
    public static let controlValues = BackendDeckToolsSupport.object([
        ("model", .string("a model name from agents.models, such as sonnet or opus, or \"default\"")),
        ("effort", .string("low, medium, high, xhigh, max, ultracode, auto")), ("fast", .string("on, off")),
        ("permission", .string("auto, manual, acceptEdits, plan, bypass")),
    ])
    public static func agentDefinitions(runtime: any BackendDeckToolsSessionsRuntime, agents: any BackendDeckToolsSessionsAgents) throws -> [BackendDeckToolsDefinition] {
        try definitions(module: "agent-tools.ts", runtime: runtime) { entry, context, args in
            let sid = try Rules.optStr(args, "sessionId") ?? "?"
            switch entry.id {
            case "agents.list":
                try await authorize(entry, summary: "List the coding agents", args: args, runtime: runtime, context: context)
                let installed = try await agents.detect(context: context)
                let builtIn: [NativeRPCValue] = [
                    ("claude", "Claude Code", "Anthropic's agentic CLI. Writes transcripts, so token and context tracking work."),
                    ("codex", "Codex CLI", "OpenAI's coding agent. Sign in with a ChatGPT account."),
                    ("gemini", "Gemini CLI", "Google's coding agent."),
                    ("shell", "Shell", "A plain login shell. No agent, no telemetry — just a terminal."),
                ].map { id, label, description in object([("id", .string(id)), ("label", .string(label)), ("description", .string(description)), ("installed", .bool(id == "shell" || installed[id].bool == true))]) }
                let added = try await agents.added(context: context).map { $0.setting("installed", .bool(installed[$0["id"].string ?? ""].bool == true)) }
                return .init(object([("builtIn", .array(builtIn)), ("added", .array(added))]), summary: object([("builtIn", .number(Double(builtIn.count))), ("added", .number(Double(added.count)))]))
            case "agents.add":
                let label = try Rules.str(args, "label"), command = try Rules.str(args, "command"), extra = try Rules.optStr(args, "args")
                try await authorize(entry, summary: "Add an agent called \(label) that runs `\(command)\(extra.map { " " + $0 } ?? "")`", args: args, runtime: runtime, context: context)
                let draft = object([("label", .string(label)), ("command", .string(command)), ("args", .string(extra ?? "")),
                    ("resumeArgs", .string(try Rules.optStr(args, "resumeArgs") ?? "")), ("description", .string(try Rules.optStr(args, "description") ?? ""))])
                let outcome = try await agents.add(draft: draft, context: context)
                guard outcome["ok"].bool == true else {
                    let problems = outcome["problems"].fields?.compactMap { $0.value.string }.filter { !$0.isEmpty }.joined(separator: " ") ?? ""
                    throw refused("the agent was not added: \(problems)")
                }
                let agent = outcome["agent"]
                return .init(object([("added", .bool(true)), ("agent", agent)]), summary: object([("id", agent["id"]), ("command", agent["command"])]))
            case "agents.remove":
                let id = try Rules.str(args, "agentId")
                try await authorize(entry, summary: "Remove the added agent \(id)", args: args, runtime: runtime, context: context)
                // agents-area-live's source prefix gate is retained before the store.
                guard id.hasPrefix("custom:"), try await agents.remove(agentID: id, context: context) else {
                    throw refused("no added agent has the id \(id). Only agents added by hand can be removed; agents.list shows them.")
                }
                return .init(object([("removed", .bool(true)), ("agentId", .string(id))]), summary: object([("agentId", .string(id))]))
            case "agents.controls", "agents.models", "agents.set_control":
                var tier = entry.tier, summary = "Read the agent controls of session \(sid)", control = "", wanted = ""
                if entry.id != "agents.controls" {
                    tier = try await runtime.startedByCaller(sessionID: args["sessionId"].string ?? "", context: context) ? .act : .alter
                    summary = "Open the model picker in session \(sid) and read it"
                }
                if entry.id == "agents.set_control" {
                    control = try Rules.oneOf(args, "control", ["model", "effort", "fast", "permission"])
                    wanted = try Rules.str(args, "value")
                    if control == "permission" { tier = .alter }
                    summary = "Set \(control) to \(wanted) in session \(sid)"
                }
                try await authorize(entry, tier: tier, summary: summary, args: args, runtime: runtime, context: context)
                let held = try await session(Rules.str(args, "sessionId"), runtime: runtime, context: context), id = held["id"].string ?? "", provider = held["provider"].string ?? "", cwd = held["cwd"].string ?? ""
                if entry.id == "agents.controls" {
                    let reading = try await agents.controls(sessionID: id, cwd: cwd, provider: provider, context: context)
                    return .init(object([("sessionId", .string(id))]).merging(reading).setting("accepts", controlValues), summary: object([("sessionId", .string(id)), ("live", reading["live"]), ("model", reading["model"]["value"])]))
                }
                if entry.id == "agents.models" {
                    let found = try await agents.models(sessionID: id, provider: provider, context: context)
                    return .init(object([("sessionId", .string(id))]).merging(found), summary: object([("sessionId", .string(id)), ("models", .number(Double(found["models"].elements?.count ?? 0)))]))
                }
                let request = object([("sessionId", .string(id)), ("cwd", .string(cwd)), ("control", .string(control)), ("value", .string(wanted)), ("provider", .string(provider))])
                let result = try await agents.apply(request: request, context: context)
                return .init(object([("sessionId", .string(id)), ("control", .string(control))]).merging(result), summary: object([("sessionId", .string(id)), ("control", .string(control)), ("value", .string(wanted)), ("ok", result["ok"])]))
            default: throw BackendDeckToolsSupport.unavailable(entry.id)
            }
        }
    }
    static func requireAccount(_ id: String, accounts: any BackendDeckToolsSessionsAccounts, context: BackendMCPCallContext) async throws -> NativeRPCValue {
        guard let account = try await accounts.find(accountID: id, context: context) else { throw refused("there is no account with id \(id) on this computer. accounts.list shows them.") }
        return object([("id", account["id"]), ("name", account["name"]), ("provider", account["provider"])])
    }
    static func namedAccount(_ args: NativeRPCValue, accounts: any BackendDeckToolsSessionsAccounts, context: BackendMCPCallContext) async throws -> String {
        guard let id = try Rules.optStr(args, "accountId") else { return "an account" }
        guard let account = try await accounts.find(accountID: id, context: context) else { return "account \(id)" }
        return "the \(account["provider"].string ?? "") account \(account["name"].string ?? "")"
    }
    static func signInFolder(_ folder: String, runtime: any BackendDeckToolsSessionsRuntime, context: BackendMCPCallContext) async throws -> (cwd: String, device: String?) {
        let caller = try await runtime.caller(context)
        guard caller.kind == .remote else { return (try await knownFolder(folder, runtime: runtime, context: context), nil) }
        let deviceID = caller.deviceID ?? ""
        guard let list = try await runtime.deviceFolders(deviceID: deviceID, context: context) else {
            throw refused("starting a session on behalf of a device is not available on this machine, so this was refused. Tell the person what you would have started and let them start it.")
        }
        let offered = deviceID.isEmpty ? [] : list
        // Mac's sameFolder normalizes separators; it is case-sensitive.
        let asked = URL(fileURLWithPath: folder).standardizedFileURL.path
        guard let granted = offered.first(where: { URL(fileURLWithPath: $0).standardizedFileURL.path == asked }) else {
            throw refused(offered.isEmpty ? "this device has no folders chosen for it, so it cannot start a session anywhere. Nothing was started. Say so, and do not retry — the folders are chosen on the desktop, in Settings." : "this device may only start a session in: \(offered.joined(separator: ", ")). Nothing was started. Use one of those, or say what you would have needed.")
        }
        return (granted, deviceID)
    }
    public static func accountDefinitions(runtime: any BackendDeckToolsSessionsRuntime, accounts: any BackendDeckToolsSessionsAccounts,
                                          sessions: any BackendDeckToolsSessionsSurface) throws -> [BackendDeckToolsDefinition] {
        try definitions(module: "account-tools.ts", runtime: runtime) { entry, context, args in
            switch entry.id {
            case "accounts.list":
                try await authorize(entry, summary: "List the agent accounts", args: args, runtime: runtime, context: context)
                let agent = try Rules.optStr(args, "agent"), project = try Rules.optStr(args, "projectPath")
                var value = object([("accounts", try await accounts.list(agent: agent, context: context)), ("agents", try await accounts.agents(context: context))])
                if let project {
                    let checked = try await knownFolder(project, runtime: runtime, context: context)
                    value = value.setting("newSessionHere", try await accounts.resolve(projectPath: checked, provider: agent, context: context))
                }
                return .init(Rules.withoutSecrets(value), summary: object([("agent", string(agent)), ("projectPath", string(project))]))
            case "accounts.create":
                let name = try Rules.str(args, "name"), agent = try Rules.optStr(args, "agent")
                try await authorize(entry, summary: "Add a \(agent ?? "claude") account called \(name)", args: args, runtime: runtime, context: context)
                return .init(Rules.withoutSecrets(object([("created", try await accounts.create(name: name, provider: agent, context: context))])), summary: object([("agent", string(agent))]))
            case "accounts.set_default":
                let id = try Rules.optStr(args, "accountId"), project = try Rules.optStr(args, "projectPath"), who = id == nil ? "the default login" : try await namedAccount(args, accounts: accounts, context: context)
                try await authorize(entry, summary: project.map { "Make \(who) the default in \($0)" } ?? "Make \(who) the default for new sessions", args: args, runtime: runtime, context: context)
                if let id { _ = try await requireAccount(id, accounts: accounts, context: context) }
                let checked = try await project.mapAsync { try await knownFolder($0, runtime: runtime, context: context) }
                let state = try await accounts.setDefault(accountID: id, projectPath: checked, context: context)
                return .init(Rules.withoutSecrets(object([("accounts", state)])), summary: object([("accountId", string(id)), ("projectPath", string(project))]))
            default:
                var summary = "", name: String?, folder: (cwd: String, device: String?)?
                let named = try await namedAccount(args, accounts: accounts, context: context)
                switch entry.id {
                case "accounts.status": summary = "Check \(named)"
                case "accounts.rename": name = try Rules.str(args, "name"); summary = "Rename \(named) to \(name ?? "?")"
                case "accounts.delete":
                    let files = args["deleteFiles"].bool == true
                    var loses = ""
                    if files, let id = try Rules.optStr(args, "accountId"), let history = try? await accounts.history(accountID: id, context: context) { loses = " " + (history["remove"].string ?? "") }
                    summary = "Delete \(named)\(files ? " and its files on disk." : " (its files stay on disk).")\(loses)"
                case "accounts.sign_in":
                    let raw = try Rules.str(args, "folder"); folder = try await signInFolder(raw, runtime: runtime, context: context)
                    summary = "Start a session in \(raw) to sign in \(named)"
                case "accounts.sign_out": summary = "Sign out \(named)"
                case "accounts.share_history":
                    let share = args["share"].bool != false
                    var said = ""
                    if let id = try Rules.optStr(args, "accountId"), let history = try? await accounts.history(accountID: id, context: context) { said = " " + (history[share ? "share" : "unshare"].string ?? "") }
                    summary = "\(share ? "Share" : "Stop sharing") the conversation history of \(named).\(said)"
                default: throw BackendDeckToolsSupport.unavailable(entry.id)
                }
                try await authorize(entry, summary: summary, args: args, runtime: runtime, context: context)
                let account = try await requireAccount(Rules.str(args, "accountId"), accounts: accounts, context: context), id = account["id"].string ?? ""
                switch entry.id {
                case "accounts.status":
                    let signIn = try await accounts.signInStatus(accountID: id, refresh: Args.optBool(args, "refresh", false), context: context)
                    return .init(Rules.withoutSecrets(object([("account", account), ("status", try await accounts.status(accountID: id, context: context)), ("signIn", signIn), ("history", try await accounts.history(accountID: id, context: context))])), summary: object([("accountId", .string(id))]))
                case "accounts.rename": return .init(Rules.withoutSecrets(object([("renamed", try await accounts.rename(accountID: id, name: name ?? "", context: context))])), summary: object([("accountId", .string(id))]))
                case "accounts.delete": return .init(Rules.withoutSecrets(object([("accountId", .string(id)), ("result", try await accounts.delete(accountID: id, deleteFiles: Args.optBool(args, "deleteFiles", false), context: context))])), summary: object([("accountId", .string(id))]))
                case "accounts.sign_in":
                    guard let folder else { throw BackendDeckToolsSupport.unavailable("The sign-in folder") }
                    let caller = try await runtime.caller(context)
                    var input = BackendCreateSessionInput(cwd: folder.cwd, cols: 120, rows: 30, provider: account["provider"].string)
                    input.profileId = id; input.originRunId = caller.callID; input.origin = caller.kind == .key ? .app : .copilot
                    if caller.kind == .key { input.originApp = caller.keyName ?? "An AI app" }
                    let meta = try await sessions.start(input: input, deviceID: folder.device, context: context), sid = meta["id"].string ?? ""
                    try await runtime.noteStarted(sessionID: sid, context: context)
                    return .init(object([("sessionId", .string(sid)), ("accountId", .string(id)), ("next", .string("the agent is starting in that session. Its sign-in link appears on its screen within a few seconds; read the screen, then hand the link to the person."))]), summary: object([("sessionId", .string(sid)), ("accountId", .string(id))]))
                case "accounts.sign_out":
                    let result = try await accounts.signOut(accountID: id, context: context)
                    return .init(object([("accountId", .string(id)), ("ok", result["ok"]), ("message", result["message"])]), summary: object([("accountId", .string(id)), ("ok", result["ok"])]))
                case "accounts.share_history":
                    let share = try Args.optBool(args, "share", true), result = try await accounts.shareHistory(accountID: id, share: share, context: context)
                    return .init(Rules.withoutSecrets(object([("accountId", .string(id)), ("shared", .bool(share)), ("result", result)])), summary: object([("accountId", .string(id)), ("share", .bool(share))]))
                default: throw BackendDeckToolsSupport.unavailable(entry.id)
                }
            }
        }
    }
}

private extension Optional where Wrapped == String {
    func mapAsync<T>(_ transform: (String) async throws -> T) async rethrows -> T? {
        guard let value = self else { return nil }; return try await transform(value)
    }
}
