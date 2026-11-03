import Foundation
import TerminalDeckBackend
import TerminalDeckNativeCore

/// A phone's New session (iOS batch 1): the same choices as this Mac's own New session dialog — the folder's
/// project agent (seat), the AI, its model and effort, the permission mode, the account, Chat or Terminal — turned
/// into this Mac's launch input, and the lists that form offers. The device's folder boundary is applied by the
/// caller, exactly as for a plain phone `create`.
enum NativePhoneStart {
    typealias Invoke = @Sendable (_ channel: String, _ arguments: [NativeRPCValue]) async throws -> NativeRPCValue

    /// The launch input for a phone's start. `chat`: true for `chats.new`; for `create`, an explicit false (a
    /// terminal) only, so a phone cannot start a Chat around the chat providers check.
    static func input(_ request: BackendRemoteCreateRequest, chat: Bool?, invoke: Invoke,
                      specs: BackendTaskPersistence?) async throws -> BackendCreateSessionInput {
        let choices = request.choices
        let mode = choices.permissionMode.flatMap(BackendHOOTSIMPermissionMode.init(rawValue:))
        if let agentID = choices.agent {
            // As that agent: its seat, memory, AI and account (its saved record), in the phone's folder.
            let saved = try await invoke("tasks:state", [])
            guard let agent = saved["agents"].elements?.first(where: { $0["id"].string == agentID && $0["status"].string != "archived" }) else {
                throw NativeRPCError(code: "unavailable", message: "That agent is no longer saved on this Mac. Pick it again.")
            }
            let project = PROJProjects.resolve(projectID: nil, folder: request.cwd)
            var input = try BackendAgentSessionInput.make(agent: agent, folder: request.cwd,
                projectID: project == PROJProjects.independentID ? nil : project, chat: chat, specs: specs)
            input.cols = request.cols; input.rows = request.rows
            return input
        }
        var input = BackendCreateSessionInput(cwd: request.cwd, provider: request.provider)
        input.cols = request.cols; input.rows = request.rows
        if let chat { input.chat = chat }
        guard choices.model != nil || choices.effort != nil || mode != nil || choices.account != nil else { return input }
        guard let provider = request.provider, let ai = HootChatProvider(rawValue: provider) else {
            throw NativeRPCError(code: "unavailable", message: "A model, effort, permission or account is chosen for Claude, Codex or Gemini. Choose one of them first.")
        }
        if let model = choices.model {
            let plain = model.hasPrefix(provider + ":") ? String(model.dropFirst(provider.count + 1)) : model
            guard !["default", "auto", ""].contains(plain.lowercased()) else { throw NativeRPCError(code: "unavailable", message: "Choose a model by name.") }
            input.model = plain
        }
        if let effort = choices.effort {
            guard AGSCapabilities.efforts(provider: provider).contains(effort) else {
                throw NativeRPCError(code: "unavailable", message: "\(name(provider)) has no effort level called \(effort).")
            }
            input.effort = effort
        }
        // R73: no start-mode choice; a new session starts in bypass (the launcher sets it). `mode` is not applied.
        _ = mode
        if let account = choices.account {
            let accounts = CodingAIAccountsParse.snapshot(CodingAIJSON((try await invoke("profiles:list", [])).foundation)).accounts
            guard accounts.contains(where: { $0.id == account && ($0.provider ?? "claude") == provider }) else {
                throw NativeRPCError(code: "unavailable", message: "That account is not one of this Mac's \(name(provider)) logins. Pick it again.")
            }
            input.profileId = account
        }
        return input
    }

    /// The New session form's lists for a folder: the AIs this Mac can start (each with its live models and
    /// effort levels, and whether it runs as a Chat), its accounts, and the folder's project agents (lead first).
    static func choices(folder: String?, invoke: Invoke) async -> NativeRPCValue {
        async let readyRead = try? invoke("hoot:ready:read", [.bool(false)])
        async let detectedRead = try? invoke("providers:detect", [])
        async let profilesRead = try? invoke("profiles:list", [])
        async let teamRead = try? invoke("tasks:state", [])
        async let prefsRead = try? invoke("prefs:get", [])
        let ready = await readyRead ?? .null, detected = await detectedRead ?? .null
        let profiles = await profilesRead ?? .null, team = await teamRead ?? .null, prefs = await prefsRead ?? .null
        let project = PROJProjects.resolve(projectID: nil, folder: folder)
        // The project's own default AI (Settings › Projects), then the app's: as the Mac's dialog decides it.
        let projectAI = project == PROJProjects.independentID ? nil
            : (try? await invoke("project-settings:get", [.object([.init("projectId", .string(project))])]))?["values"]["defaultCodingAI"].string

        var providers: [NativeRPCValue] = [], defaults: [String: String] = [:]
        let rows = NewSessionProviders.rows(detected: CodingAIJSON(detected.foundation), added: [])
        // 28 Oct (phone review: "Shell" twice, both ticked): the catalogue has Shell too; it is added once, below.
        var seen = Set<String>()
        for row in rows where row.available && row.id != "shell" && BackendRemoteServeSessionCreate.knownProvider(row.id) != nil && seen.insert(row.id).inserted {
            var fields: [NativeRPCValue.Field] = [.init("id", .string(row.id)), .init("name", .string(name(row.id))),
                .init("chat", .bool(BackendCreateSessionInput.chatProviders.contains(row.id))),
                .init("models", .array(models(ready["catalog"][row.id]))),
                .init("efforts", .array(AGSCapabilities.efforts(provider: row.id).map(NativeRPCValue.string)))]
            // The login Settings › Who uses what gives this folder for this AI (profiles:effective, then resolve).
            if let login = await defaultLogin(provider: row.id, folder: folder, invoke: invoke) {
                fields.append(.init("defaultAccount", .string(login))); defaults[row.id] = login
            }
            providers.append(.object(fields))
        }
        // A plain terminal is always there: the shell this Mac opens.
        providers.append(.object([.init("id", .string("shell")), .init("name", .string("Shell")), .init("chat", .bool(false)),
                                  .init("models", .array([])), .init("efforts", .array([]))]))
        let known = Set(providers.compactMap { $0["id"].string })
        // One row per login, named as the Mac's own New session dialog names it: the same live sign-in facts
        // (profiles:signin) and the same rule, each AI's start login kept (Reviewer 28 Oct, SHOULD 1).
        let saved = CodingAIAccountsParse.snapshot(CodingAIJSON(profiles.foundation)).accounts
        let signIns = await signInFacts(saved, invoke: invoke)
        var copies: [String: CodingAIAccount] = [:]
        for provider in Set(saved.map { $0.provider ?? "claude" }) {
            let mine = saved.filter { ($0.provider ?? "claude") == provider }
            copies.merge(CodingAILogins.duplicates(mine, signIn: signIns, prefer: defaults[provider])) { held, _ in held }
        }
        let accounts: [NativeRPCValue] = saved.filter { copies[$0.id] == nil }.compactMap { account in
            let provider = account.provider ?? "claude"
            guard known.contains(provider) else { return nil }
            return .object([.init("id", .string(account.id)), .init("name", .string(CodingAIAccountLabels.profileLoginLabel(account, signIns[account.id]))),
                            .init("provider", .string(provider))])
        }
        let agents = NewSessionTeamAgent.forProject(NewSessionTeamAgent.parse(CodingAIJSON(team.foundation)),
            project: PROJProjects.defaults.first { $0.id == project && $0.id != PROJProjects.independentID })
            .map { agent -> NativeRPCValue in .object([.init("id", .string(agent.id)), .init("name", .string(agent.name)),
                .init("provider", .string(agent.provider)), .init("lead", .bool(agent.isLead))]) }
        // 2 Nov (web v1): an independent saved agent whose home folder is this folder works here too (Send instructions
        // from its profile); `input` already starts any saved agent by id in the device's folder.
        let here = folder.map { URL(fileURLWithPath: $0).standardizedFileURL.path }
        let listed = Set(agents.compactMap { $0["id"].string })
        let homed: [NativeRPCValue] = here == nil ? [] : (team["agents"].elements ?? []).compactMap { row in
            guard let id = row["id"].string, !id.isEmpty, !listed.contains(id), row["status"].string != "archived",
                  (row["projectId"].string ?? PROJProjects.independentID) == PROJProjects.independentID,
                  let home = row["defaultProject"].string, URL(fileURLWithPath: home).standardizedFileURL.path == here else { return nil }
            let provider = row["claudeAgent"].string != nil ? "claude" : (row["provider"].string ?? "claude")
            return .object([.init("id", .string(id)), .init("name", .string(row["name"].string ?? id)), .init("provider", .string(provider)), .init("lead", .bool(false))])
        }
        var fields: [NativeRPCValue.Field] = [.init("providers", .array(providers)), .init("accounts", .array(accounts)), .init("agents", .array(agents + homed))]
        if let preferred = [projectAI, prefs["defaultProvider"].string].compactMap({ $0 }).first(where: known.contains) {
            fields.append(.init("defaultProvider", .string(preferred)))
        }
        // Chat unless the person last chose a terminal (the Mac dialog's remembered Open as).
        fields.append(.init("openAs", .string(prefs[NewSessionChatMode.preference].string == "terminal" ? "terminal" : "chat")))
        // The folder the Mac's own New session dialog would open on (its last folder); the phone uses it only
        // when this phone may start there.
        if let last = UserDefaults.standard.string(forKey: NativeNewSessionEffects.lastFolderKey), last.hasPrefix("/") {
            fields.append(.init("defaultFolder", .string(last)))
        }
        return .object(fields)
    }

    /// Each login's live sign-in facts, read as the Mac's New session dialog reads them (cached; never a refresh).
    private static func signInFacts(_ accounts: [CodingAIAccount], invoke: Invoke) async -> [String: CodingAISignIn] {
        // The group is awaited before this returns, so the reader never outlives the call.
        await withoutActuallyEscaping(invoke) { invoke in await withTaskGroup(of: (String, CodingAISignIn?).self) { group in
            for account in accounts.prefix(64) {
                group.addTask {
                    let raw = try? await invoke("profiles:signin", [.string(account.id),
                        .object([.init("provider", .string(account.provider ?? "claude")), .init("refresh", .bool(false))])])
                    return (account.id, raw.flatMap { $0.fields == nil ? nil : CodingAIAccountsParse.signIn(CodingAIJSON($0.foundation)) })
                }
            }
            var facts: [String: CodingAISignIn] = [:]
            for await (id, fact) in group { if let fact { facts[id] = fact } }
            return facts
        } }
    }

    /// The account this folder starts an AI with, as the Mac's dialog resolves it.
    private static func defaultLogin(provider: String, folder: String?, invoke: Invoke) async -> String? {
        let path: NativeRPCValue = folder.map(NativeRPCValue.string) ?? .null
        if let effective = (try? await invoke("profiles:effective", [.object([.init("provider", .string(provider)), .init("projectPath", path)])]))?["accountId"].string {
            return effective
        }
        guard let resolved = try? await invoke("profiles:resolve", [.object([.init("projectPath", path)])]) else { return nil }
        guard let account = CodingAIAccountsParse.account(CodingAIJSON(resolved.foundation)), (account.provider ?? "claude") == provider else { return nil }
        return account.id
    }

    /// One AI's live models, as the Mac's New session dialog lists them (the live catalogue; featured, then older).
    private static func models(_ live: NativeRPCValue) -> [NativeRPCValue] {
        let rows = live["models"].elements ?? []
        let listed = ((live["featured"].elements ?? []) + (live["more"].elements ?? [])).compactMap(\.string)
        let ordered = listed.isEmpty ? rows : listed.compactMap { id in rows.first { $0["id"].string == id } }
        var seen = Set<String>()
        return ordered.compactMap { row in
            guard let id = row["id"].string, !["default", "auto", ""].contains(id.lowercased().replacingOccurrences(of: "[1m]", with: "")),
                  seen.insert(id).inserted else { return nil }
            return .object([.init("id", .string(id)), .init("name", .string(row["name"].string ?? id))])
        }
    }

    /// A start from the person's own phone (Full control) is this Mac's last folder too, as a start from its New
    /// session dialog is (27 Oct walk, g): the dialog and the phone's form open there next. A guest's folder never is.
    static func rememberFolder(_ folder: String, defaults: UserDefaults = .standard) {
        guard folder.hasPrefix("/"), !folder.contains("\0"), !folder.contains(where: { $0.isNewline }), folder.utf8.count <= 1024 else { return }
        defaults.set(folder, forKey: NativeNewSessionEffects.lastFolderKey)
    }

    static func name(_ provider: String) -> String {
        switch provider { case "claude": "Claude"; case "codex": "Codex"; case "gemini": "Gemini"; case "shell": "Shell"; default: provider.capitalized }
    }
}
