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
        let honours = await NativeLandingHost.honoursChosenStart()
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
            // The mode the phone shows, passed at the start (the agent's AI), as for a plain AI below.
            try chooseStart(mode, provider: input.provider ?? "claude", into: &input, hostHonours: honours)
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
        // "Before it changes files", passed AT the start (never set afterwards), as the Mac's New session page does it.
        try chooseStart(mode, provider: provider, into: &input, hostHonours: honours)
        if let account = choices.account {
            let accounts = CodingAIAccountsParse.snapshot(CodingAIJSON((try await invoke("profiles:list", [])).foundation)).accounts
            guard accounts.contains(where: { $0.id == account && ($0.provider ?? "claude") == provider }) else {
                throw NativeRPCError(code: "unavailable", message: "That account is not one of this Mac's \(name(provider)) logins. Pick it again.")
            }
            input.profileId = account
        }
        return input
    }

    /// The New session page's mapping (lane/landing-like-chat, `NativeLandingModel.startPermissionValue` and its
    /// start): the chosen mode as this AI's own CLI value, checked against what the AI has, passed as the session's
    /// `permissionMode` AND as the explicit `chosenStartPermission` the launcher starts in (Chat and Terminal alike).
    /// No choice: nothing is set, the session starts as every new session does (Bypass, R73).
    /// The phone follows the Mac's page, one rule, one switch (lead's decision 14 Nov; `chats.choices.modeAtStart` is
    /// `NativeLandingHost.honoursChosenStart()`): when this Mac cannot start in a chosen mode, Bypass (or no pick) goes
    /// through as before and a stricter mode is REFUSED with `bypassOnly`, never started weaker than the phone shows.
    /// (No phone build sends a mode on a start today: both strip it, `ChatsLink.allowed`, R73.) An AI without a start
    /// mode (a Shell, an added tool): any mode is ignored, as before.
    static func chooseStart(_ mode: BackendHOOTSIMPermissionMode?, provider: String, into input: inout BackendCreateSessionInput,
                            hostHonours: Bool) throws {
        guard let mode, BackendTAGLaunchArguments.newSessionPermission(provider: provider) != nil else { return }
        guard hostHonours else {
            guard mode == .bypass else { throw NativeRPCError(code: "unavailable", message: bypassOnly) }
            return
        }
        guard let ai = HootChatProvider(rawValue: provider) else { return }
        let cli = mode.cliMode(provider: ai)
        guard AGSCapabilities.permissionModes(provider: provider).contains(cli) else {
            throw NativeRPCError(code: "unavailable", message: "\(name(provider)) cannot start in that \u{201C}Before it changes files\u{201D} choice. Choose another.")
        }
        input.permissionMode = cli
        input.chosenStartPermission = cli
    }

    static let bypassOnly = "This Mac starts new sessions in Bypass. Change it in the session after it starts."

    /// The Mac's own New session default folder is made on first use, also when a phone starts there first.
    static func prepareFolder(_ folder: String) {
        guard URL(fileURLWithPath: folder).standardizedFileURL.path == NativeLandingPlaces.independent().standardizedFileURL.path else { return }
        _ = try? NativeLandingPlaces.ensureIndependent()
    }

    /// 14 Nov (`start.text`): a phone's first message into the session it just started. A Chat says it; a Terminal
    /// gets it typed only at the AI's own empty prompt (`NativeLandingTerminal.deliver`, the New session page's rule),
    /// through the session's own input (never this Mac's keyboard or clipboard), as the session's REAL paste setting
    /// takes a paste (`typing`), then Return on its own. Two minutes without that prompt, or a multi-line text for a
    /// program that has not switched bracketed paste on (its line breaks would each press Return): not typed (false).
    static func deliverFirst(_ job: BackendPhoneStartText.Job, manager: BackendPTYManager, invoke: Invoke) async -> Bool {
        if job.chat {
            do { _ = try await invoke("session:chat:say", [.string(job.sessionID), .string(job.text)]); return true }
            catch { return false }
        }
        let id = job.sessionID, held = Held()
        let typed = await NativeLandingTerminal.deliver(provider: job.provider, text: job.text,
            read: { NativePhoneStart.reading(manager, id) },
            type: { text in
                guard let data = NativePhoneStart.typing(text, provider: job.provider, bracketed: manager.bracketedPaste(id)) else { held.refused = true; return }
                _ = try? manager.write(id, data: data)
            },
            submit: { if !held.refused { _ = try? manager.write(id, data: "\r") } },
            pause: { try? await Task.sleep(for: .milliseconds(250)) })
        return await MainActor.run { typed && !held.refused }
    }

    /// Whether `deliverFirst` held its text back at the prompt (set and read on the main actor only).
    @MainActor private final class Held { var refused = false; nonisolated init() {} }

    /// What is typed for a first message, as the session's paste setting takes it: bracketed when the program switched
    /// bracketed paste on; a single line plainly when it did not; a multi-line text then nil (not sent). Unknown (a
    /// session host older than the remount): Claude, Codex and Gemini prompts always switch it on (as before); any
    /// other program counts as off.
    static func typing(_ text: String, provider: String, bracketed: Bool?) -> String? {
        let on = bracketed ?? ["claude", "codex", "gemini"].contains(provider)
        if on { return TerminalText.pasteData(text, bracketed: true) }
        guard !text.contains(where: { $0 == "\n" || $0 == "\r" || $0 == "\r\n" }) else { return nil }
        return TerminalText.pasteData(text, bracketed: false)
    }

    /// A session's status and screen as this Mac's session manager holds them (no window needed: the phone owns it).
    static func reading(_ manager: BackendPTYManager, _ id: String) -> (status: TerminalStatus?, screen: String) {
        guard manager.list().contains(where: { $0.id == id }) else { return (.exited, "") }
        let screen = manager.screen(id) ?? ""
        let status = manager.knownStatus(id).flatMap { TerminalStatus(rawValue: $0.rawValue) }
            ?? (screen.isEmpty ? nil : TerminalStatus(rawValue: BackendSessionClassifier.classify(viewport: screen).rawValue))
        return (status, screen)
    }

    /// The New session lists exactly as this Mac's own New session page offers them, for the page AND the phones
    /// (14 Nov, phones ask 5): `choices` filled by `NativeLandingModels.filled` (the live list, else a running chat's
    /// list, else the last list seen here, else Claude Code's aliases; with the default model and effort named). Before
    /// this the phones were sent `choices` alone, whose Claude list is empty when the live catalogue has none (his own
    /// Claude Code sign-in), so their New session said "Default model" with no model rows.
    @MainActor
    static func newSessionLists(folder: String?, invoke: @escaping Invoke, defaults: UserDefaults = .standard,
                                cliDefault: @escaping NativeLandingModels.CLIDefault = NativeLandingModels.cliDefault,
                                extras: @escaping NativeLandingModels.Extras = NativeLandingModels.claudeExtras) async -> NativeRPCValue {
        let lists = await choices(folder: folder, invoke: invoke)
        return await NativeLandingModels.filled(lists, invoke: { try await invoke($0, $1) }, defaults: defaults, cliDefault: cliDefault,
                                                extras: extras)
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
        // 15 Nov review (items 6-7: "They should come here as with name, not with their Gmail"; "All dark gray, why?"):
        // each login by the NAME he gave it (`accountName`), its address apart ("email", shown only where two share a
        // name) and its real state ("state": ready / signIn / limit / unknown) for the one mark that means something.
        // "name" stays the field the phones read; its value is now the name instead of the address.
        let limited = await limitReached(invoke: invoke)
        let accounts: [NativeRPCValue] = saved.filter { copies[$0.id] == nil }.compactMap { account in
            let provider = account.provider ?? "claude"
            guard known.contains(provider) else { return nil }
            let signIn = signIns[account.id]
            var fields: [NativeRPCValue.Field] = [.init("id", .string(account.id)), .init("name", .string(accountName(account, signIn))),
                .init("provider", .string(provider)),
                .init("state", .string(accountState(signIn, limited: limited.contains(account.id) || (CodingAIAccountLabels.isGenerated(account) && limited.contains(provider == "claude" ? "system" : "system:" + provider)))))]
            if let email = CodingAILogins.normalizedEmail(CodingAIAccountLabels.accountLabel(signIn) ?? signIn?.remembered) { fields.append(.init("email", .string(email))) }
            return .object(fields)
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
        // Whether a start's "Before it changes files" pick is honoured: the Mac page's own switch (`chooseStart`).
        fields.append(.init("modeAtStart", .bool(await NativeLandingHost.honoursChosenStart())))
        // The folder the Mac's own New session dialog would open on (its last folder); the phone uses it only
        // when this phone may start there.
        // 14 Nov (phones ask 1): with no last folder, the Mac's own New session default (`~/Terminal Deck/Independent`,
        // made on first use: `prepareFolder` at the start), never the first shared project. The chats feature still
        // sends it only to a device that may start there (the person's own; a guest only if its grants hold it).
        if let last = UserDefaults.standard.string(forKey: NativeNewSessionEffects.lastFolderKey), last.hasPrefix("/") {
            fields.append(.init("defaultFolder", .string(last)))
        } else {
            fields.append(.init("defaultFolder", .string(NativeLandingPlaces.independent().path)))
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

    /// A login as a person named it: the name he gave it (an API key's too); this Mac's own install by what it is ("Your
    /// own Claude Code install"); only a login nobody named shows its address. A saved "name" that is itself an address
    /// (logins named after their sign-in) is the live address instead: an old one may be stale.
    static func accountName(_ account: CodingAIAccount, _ signIn: CodingAISignIn?) -> String {
        if account.isAPIKey { return account.name }
        if CodingAIAccountLabels.hasChosenName(account) {
            return account.name.contains("@") ? CodingAIAccountLabels.accountLabel(signIn) ?? account.name : account.name
        }
        if CodingAIAccountLabels.isGenerated(account) {
            if account.provider == "codex", signIn?.state == .signedIn, signIn?.plan == "ChatGPT" { return "ChatGPT" }
            return "Your own " + (CodingAICatalog.agent(account.provider ?? "claude")?.label ?? name(account.provider ?? "claude")) + " install"
        }
        return CodingAIAccountLabels.accountLabel(signIn) ?? account.name
    }

    /// One word for what a login can do now: "ready" (signed in), "signIn" (needs him to sign in), "limit" (its usage
    /// limit is reached), "unknown" (not checked yet: no mark).
    static func accountState(_ signIn: CodingAISignIn?, limited: Bool) -> String {
        if signIn?.state == .signedOut { return "signIn" }
        if limited { return "limit" }
        return signIn?.state == .signedIn ? "ready" : "unknown"
    }

    /// The logins whose 5-hour or weekly usage reading is at its limit (the same reading Settings shows as "5 hours 100%").
    /// This Mac's own install reads as "system" (Claude) or "system:<ai>".
    private static func limitReached(invoke: Invoke) async -> Set<String> {
        guard let raw = try? await invoke("usage:read", []) else { return [] }
        var ids = Set<String>()
        for reading in raw["readings"].elements ?? [] {
            guard reading["used"]["kind"].string == "reported", let fraction = reading["used"]["fraction"].number, fraction >= 1,
                  let provider = reading["account"]["provider"].string else { continue }
            ids.insert(reading["account"]["id"].string ?? (provider == "claude" ? "system" : "system:" + provider))
        }
        return ids
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
