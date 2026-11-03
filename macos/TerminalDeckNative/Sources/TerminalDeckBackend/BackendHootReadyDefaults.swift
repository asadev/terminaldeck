import Foundation
import TerminalDeckNativeCore

public struct BackendHootReadySelection: Sendable {
    public let provider: HootChatProvider
    public let profile: BackendAccountProfile?
    public let ready: Bool
    public let preferences: HootReadyPreferences
    public let accounts: NativeRPCValue
    public var permissionMode: String? = nil
    /// The account Hoot's row in Settings › Coding AIs › Who uses what names for this AI (the orchestrator seat),
    /// whether or not it is signed in right now. The account dropdown on Hoot's popover writes that same row.
    public var seatAccountID: String? = nil
    /// The installed CLIs' model pickers (BackendHootModelSource) and Codex's larger window for the chosen model.
    public var catalog: NativeRPCValue = .null
    public var codexMaxWindow: Int? = nil
    /// The mode the host answers prompts by: this chat's override, else the saved choice.
    public var permissionPolicy: String? { permissionMode ?? preferences.permissionMode }
    /// Claude's host-answered prompts refuse --permission-mode bypassPermissions, so Bypass launches
    /// Claude in acceptEdits and the host approves every other prompt itself (no card).
    static func launchMode(_ mode: String?, provider: HootChatProvider) -> String? {
        provider == .claude && mode == "bypassPermissions" ? "acceptEdits" : mode
    }
    public var wireValue: NativeRPCValue {
        .object([.init("catalog", catalog), .init("provider", .string(provider.rawValue)), .init("profileId", profile.map { .string($0.id) } ?? .null),
                 .init("ready", .bool(ready)), .init("choices", preferences.wireValue), .init("accounts", accounts),
                 .init("permissionMode", permissionMode.map(NativeRPCValue.string) ?? .null)])
    }
    /// No model/effort overrides means the selected CLI keeps its own defaults.
    public var launchSettings: AGSAgentSettings {
        var window = preferences.contextWindow
        if (window == nil || window == "standard"), HootModelCatalog.supportsOneMillion(provider: provider, model: preferences.model) { window = "1m" }
        var tokens = provider == .codex && window == "max" ? codexMaxWindow : nil
        if provider == .codex, tokens == nil, let max = codexMaxWindow { tokens = min(1_000_000, max) }
        return .init(provider: provider.rawValue,
              model: HootModelCatalog.launchModel(provider: provider, model: preferences.model, contextWindow: window),
              effort: preferences.effort ?? AGSCapabilities.defaultEffort(provider: provider.rawValue), permissionMode: Self.launchMode(permissionMode ?? preferences.permissionMode, provider: provider),
              contextWindow: tokens,
              fastMode: provider == .claude ? preferences.fastMode : nil)
    }
    public func launchPlan(privateDirectory: URL, installedHelp: String) throws -> BackendAGSLaunchPlan {
        try BackendAGSLaunch.plan(launchSettings, privateDirectory: privateDirectory, installedHelp: installedHelp, knownServers: [])
    }
}

/// Uses the real account inventory/sign-in service, without login, a PTY or a model call.
/// INT2 supplies this same owner to composition, the window routes and the driver.
public actor BackendHootReadyDefaults {
    private let settings: BackendAppSettingsStore
    private let profiles: @Sendable (HootChatProvider, String) async throws -> [BackendAccountProfile]
    private let available: @Sendable (HootChatProvider) async throws -> Bool
    private let signedIn: @Sendable (BackendAccountProfile, Bool) async -> Bool
    private let enabled: Bool
    private var conversationPreferences: HootReadyPreferences? { didSet { changes.bump() } }
    private var conversationMode: BackendHOOTSIMPermissionMode = .ask
    /// Where the installed CLIs keep their own model lists (tests pass a scratch home).
    public var modelHome = FileManager.default.homeDirectoryForCurrentUser
    public func setModelHome(_ url: URL) { modelHome = url }
    /// #26: what the live Hoot's per-event check depends on moves this number (see `liveCheck`).
    private let changes = BackendHootChangeCount()
    /// The app's own account files (profiles.json: the accounts and Who uses what), watched for `liveCheck`.
    private let accountFiles: [URL]
    private var accountWatch: BackendHootFileWatch?
    private var settingsWatch: NativeRPCSubscription?
    private var watchingSettings = false
    private var lastLiveCheck: (projectPath: String, change: Int, at: Date, selection: BackendHootReadySelection)?
    /// A sign-in (a login kept in the Keychain or the vault) leaves no file this can watch: the check asks again
    /// after this long, on the next event only.
    static let liveCheckLongest: TimeInterval = 60
    public init(settings: BackendAppSettingsStore, enabled: Bool = HootReadyDefaults.enabled(),
                accountFiles: [URL] = [],
                profiles: @escaping @Sendable (HootChatProvider, String) async throws -> [BackendAccountProfile],
                available: @escaping @Sendable (HootChatProvider) async throws -> Bool,
                signedIn: @escaping @Sendable (BackendAccountProfile, Bool) async -> Bool) {
        self.settings = settings; self.enabled = enabled; self.profiles = profiles; self.available = available; self.signedIn = signedIn
        self.accountFiles = accountFiles
    }
    public init(settings: BackendAppSettingsStore, sessions: BackendCompositionSessions, providers: BackendNativeProviders,
                enabled: Bool = HootReadyDefaults.enabled()) {
        self.settings = settings; self.enabled = enabled
        // The account store keeps profiles.json in the same data folder as the settings (BackendAccountConfiguration).
        accountFiles = [settings.directory.appendingPathComponent("profiles.json")]
        profiles = { provider, folder in
            // ACCOUNTS: the account Hoot's row gives it (seat "orchestrator") comes first.
            let preferred = try await BackendHootAccountSeat.resolve(sessions: sessions, projectPath: folder, provider: provider.rawValue)
            return [preferred] + (try await sessions.profiles.list(provider: provider.rawValue)).filter { $0.id != preferred.id }
        }
        available = { provider in
            let path = try await providers.loginPath()
            return await providers.resolveBinary(provider.rawValue, path: path).runnable != nil
        }
        signedIn = { profile, refresh in
            #if TD_HOST_ACCOUNT_BRIDGE
            do {
                let original = try BackendHOSTProfileScope.requireCurrent()
                let value = try await sessions.signIn.invoke("profiles:signin", args: [.string(profile.id), .object([.init("refresh", .bool(refresh))])], context: original)
                return value["state"].string == "signed-in"
            } catch { return false }
            #else
            return await sessions.signIn.read(profile, refresh: refresh).state == "signed-in"
            #endif
        }
    }
    public func read(projectPath: String, refresh: Bool = false, forConversation: Bool = false) async throws -> BackendHootReadySelection {
        try requireEnabled()
        let inventory = try await inventory(projectPath: projectPath, refresh: refresh)
        return try await selection(projectPath: projectPath, forConversation: forConversation, inventory: inventory)
    }
    /// #26 (3 Nov, Tester): the live Hoot's check for a deliberate change (`BackendHootChatDriver.isAlive`) runs on
    /// every app event the island hears, about two a second while agents work, and each one read every account, its
    /// sign-in and the CLIs' files. The same answer is now kept and given again until something it depends on moves:
    /// Hoot's saved choices (the settings store tells at once), this chat's own options, the app's account file
    /// (watched), or `liveCheckLongest` has passed. It carries no model list: the check never needs one.
    public func liveCheck(projectPath: String) async throws -> BackendHootReadySelection {
        try requireEnabled()
        await startWatching()
        let change = changes.current
        if let kept = lastLiveCheck, kept.projectPath == projectPath, kept.change == change,
           Date().timeIntervalSince(kept.at) < Self.liveCheckLongest { return kept.selection }
        let inventory = try await inventory(projectPath: projectPath, catalog: false)
        let selection = try await selection(projectPath: projectPath, forConversation: true, inventory: inventory)
        lastLiveCheck = (projectPath, change, Date(), selection)
        return selection
    }
    private func startWatching() async {
        if !watchingSettings {
            watchingSettings = true   // before the await: a second check meanwhile adds no second listener
            // Called at once and after every write (patch, reset, project settings), before the write returns.
            settingsWatch = await settings.observeSnapshot { [changes] _ in changes.bump() }
        }
        if accountWatch == nil, !accountFiles.isEmpty {
            accountWatch = BackendHootFileWatch(files: accountFiles) { [changes] _ in changes.bump() }
        }
    }
    private struct Inventory {
        let accounts: NativeRPCValue
        let candidates: [(HootChatProvider, BackendAccountProfile, Bool)]
        let catalog: NativeRPCValue
    }
    private func inventory(projectPath: String, refresh: Bool = false, catalog: Bool = true) async throws -> Inventory {
        var inventory: [NativeRPCValue] = [], candidates: [(HootChatProvider, BackendAccountProfile, Bool)] = []
        for provider in HootReadyDefaults.providerOrder {
            let installed = (try? await available(provider)) == true
            for profile in try await profiles(provider, projectPath) where profile.provider == provider.rawValue {
                let ready: Bool
                if installed { ready = await signedIn(profile, refresh) } else { ready = false }
                candidates.append((provider, profile, ready))
                inventory.append(.object([.init("id", .string(profile.id)), .init("name", .string(profile.name)),
                                          .init("provider", .string(provider.rawValue)), .init("installed", .bool(installed)), .init("signedIn", .bool(ready))]))
            }
        }
        return Inventory(accounts: .array(inventory), candidates: candidates,
            catalog: catalog ? await BackendHootModelSource.liveCatalogue(home: modelHome) : .null)
    }
    private func selection(projectPath: String, forConversation: Bool = false, inventory: Inventory) async throws -> BackendHootReadySelection {
        let saved = await settings.value(HootProviderPreference.key)
        let savedProvider = saved.isNullish ? nil : try HootProviderPreference.resolve(saved)
        let chatPreferences = forConversation ? conversationPreferences : nil
        let explicit = chatPreferences?.provider ?? savedProvider
        let candidates = inventory.candidates
        let provider = explicit ?? candidates.first(where: { $0.2 })?.0 ?? .claude
        // SETTINGS-TRUTH line 74: the account comes from Hoot's row in Who uses what (the orchestrator seat, first in
        // `profiles`). The old per-Hoot saved account (hoot.account.<ai>) is never read, so it cannot win over that row.
        let account = chatPreferences?.profileID
        let matching = candidates.filter { $0.0 == provider }
        let chosen = account.flatMap { id in matching.first { $0.1.id == id } }
            ?? (account == nil ? matching.first(where: { $0.2 }) ?? matching.first : nil)
        var preferences: HootReadyPreferences
        if let chatPreferences { preferences = chatPreferences }
        else { preferences = HootReadyPreferences(provider: explicit, profileID: account,
            model: await settings.value(key("model", provider)).string, effort: await settings.value(key("effort", provider)).string,
            permissionMode: await settings.value(key("permission", provider)).string, contextWindow: await settings.value(key("context", provider)).string,
            fastMode: await settings.value(key("fast", provider)).bool) }
        if preferences.effort == nil || ["", "auto", "default"].contains(preferences.effort ?? "") {
            preferences.effort = AGSCapabilities.defaultEffort(provider: provider.rawValue)
        }
        var selection = BackendHootReadySelection(provider: provider, profile: chosen?.1, ready: chosen?.2 == true, preferences: preferences,
                     accounts: inventory.accounts, permissionMode: forConversation && conversationPreferences != nil ? conversationMode.cliMode(provider: provider) : nil)
        selection.seatAccountID = matching.first?.1.id
        // SETTINGS-TRUTH line 70: the Plans-only / Bypass gate on Hoot's app tools reads this mode; it follows the saved
        // choice from the first read (Hoot's start), not only once a chat view has asked for its options.
        if forConversation, conversationPreferences == nil { conversationMode = Self.chatMode(preferences.permissionMode) }
        selection.catalog = inventory.catalog
        if provider == .codex { selection.codexMaxWindow = BackendHootModelSource.codexMaxWindow(model: preferences.model, home: modelHome) }
        return selection
    }
    /// Reads the saved permission mode at start, so phone and task turns follow it before any chat view opens.
    public func loadSavedMode(projectPath: String) async {
        guard enabled, conversationPreferences == nil else { return }
        _ = try? await read(projectPath: projectPath, forConversation: true)
    }
    /// The per-Hoot account that older builds saved (hoot.account.<ai>) is removed once at start: the account is
    /// Hoot's row in Who uses what. Safe to call again; a settings file without them is left as it is.
    public func removeLegacyAccounts() async {
        var present: [NativeRPCValue.Field] = []
        for provider in HootReadyDefaults.providerOrder {
            let name = key("account", provider)
            if !(await settings.value(name)).isNullish { present.append(.init(name, .null)) }
        }
        guard !present.isEmpty else { return }
        _ = try? await settings.patch(.object(present))
    }
    public var plansOnly: Bool { conversationMode == .plan }
    /// The person chose Bypass for Hoot: its changes in the app go through without a card (except what must always be answered).
    public var bypassOn: Bool { conversationMode == .bypass }
    public var chatMode: BackendHOOTSIMPermissionMode { conversationMode }
    /// This conversation's choices, without changing Settings or another agent.
    /// The caller stops the idle conversation before applying these options.
    public func setChatOptions(_ patch: NativeRPCValue, projectPath: String) async throws -> NativeRPCValue {
        _ = try patch.requireObject("chat options")
        guard Set(patch.fields?.map(\.key) ?? []).isSubset(of: ["permissionMode", "model", "effort", "fastMode"]) else {
            throw NativeRPCError.invalidArguments("Choose this chat's permission mode, model, effort or Fast mode.")
        }
        guard patch["fastMode"].isNullish || patch["fastMode"].bool != nil else { throw NativeRPCError.invalidArguments("Fast mode is on or off.") }
        try requireEnabled()
        let inventory = try await inventory(projectPath: projectPath)
        let current = try await selection(projectPath: projectPath, forConversation: true, inventory: inventory)
        var preferences = conversationPreferences ?? current.preferences
        var mode = conversationMode
        if let selected = patch["permissionMode"].string {
            guard let requested = BackendHOOTSIMPermissionMode(rawValue: selected) else { throw NativeRPCError.invalidArguments("Unknown Hoot permission mode.") }
            mode = requested
        } else if !patch["permissionMode"].isNullish { throw NativeRPCError.invalidArguments("Permission mode must be a string.") }
        if let selected = patch["model"].string {
            let options = await chatOptions(current: current)
            guard options["models"].elements?.contains(where: { $0["id"].string == selected }) == true else {
                throw NativeRPCError.invalidArguments("Choose a model offered by an installed Coding AI.")
            }
            let parts = selected.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2, let provider = HootChatProvider(rawValue: String(parts[0])), !parts[1].isEmpty,
                  current.accounts.elements?.contains(where: { $0["provider"].string == provider.rawValue && $0["installed"].bool == true }) == true else {
                throw NativeRPCError.invalidArguments("Choose an installed Coding AI and model.")
            }
            preferences.provider = provider
            preferences.model = parts[1] == "default" ? nil : String(parts[1])
            if provider != current.provider { preferences.profileID = nil; preferences.effort = nil }
        } else if !patch["model"].isNullish { throw NativeRPCError.invalidArguments("Model must be a string.") }
        let provider = preferences.provider ?? current.provider
        preferences.provider = provider
        if let effort = patch["effort"].string {
            // "default" leaves the CLI's own effort; any other must be one this CLI offers.
            guard effort == "default" || AGSCapabilities.efforts(provider: provider.rawValue).contains(effort) else {
                throw NativeRPCError.invalidArguments("That effort is unavailable for this Coding AI.")
            }
            preferences.effort = effort == "default" ? nil : effort
        } else if !patch["effort"].isNullish { throw NativeRPCError.invalidArguments("Effort must be a string.") }
        try BackendAGSValidation.check(.init(provider: provider.rawValue, model: preferences.model,
                                             effort: preferences.effort, permissionMode: mode.cliMode(provider: provider)))
        // ONE source of truth (Asad: "i changed inside the model but outside is still opus"): the
        // composer writes the same saved Hoot choices the gear popover and Settings → Hoot use;
        // no per-chat copy. Hoot picks them up from its next message.
        var saved = try await selection(projectPath: projectPath, inventory: inventory).preferences
        let savedProvider = saved.provider ?? current.provider
        if patch["model"].string != nil {
            if provider != savedProvider { saved.profileID = nil; saved.effort = nil; saved.permissionMode = nil; saved.contextWindow = nil; saved.fastMode = nil }
            saved.provider = saved.provider == nil && provider == current.provider ? nil : provider
            saved.model = preferences.model
        }
        if patch["effort"].string != nil { saved.effort = preferences.effort }
        // U91: Fast mode goes through this one writer too, so the composer, Settings and the island all hear of it.
        if let fast = patch["fastMode"].bool { saved.fastMode = fast }
        // "Ask first" while switching AI is said out loud, so the AI's own saved choice is not brought back instead.
        if patch["permissionMode"].string != nil { saved.permissionMode = mode == .ask ? (provider != savedProvider ? "default" : nil) : mode.cliMode(provider: provider) }
        let updated = try await save(saved.wireValue, projectPath: projectPath, inventory: inventory)
        conversationPreferences = nil; conversationMode = mode
        return await chatOptions(current: updated)
    }
    /// The saved CLI permission value as the composer's four choices.
    static func chatMode(_ cliMode: String?) -> BackendHOOTSIMPermissionMode {
        switch cliMode ?? "default" {
        case "plan", "read-only": .plan
        case "acceptEdits", "workspace-write", "auto_edit": .changes
        case "bypassPermissions", "danger-full-access", "yolo": .bypass
        default: .ask
        }
    }
    public func checkpointChatOptions() -> NativeRPCValue {
        .object([.init("version", .number(1)), .init("preferences", conversationPreferences?.wireValue ?? .null),
                 .init("permissionMode", .string(conversationMode.rawValue))])
    }
    /// Restore validated, bounded memory state. Saved Settings are never written.
    public func restoreChatOptions(_ checkpoint: NativeRPCValue) throws {
        _ = try checkpoint.requireObject("chat options checkpoint")
        guard Set(checkpoint.fields?.map(\.key) ?? []) == ["version", "preferences", "permissionMode"],
              checkpoint["version"].number == 1, try checkpoint.encodedJSON().count <= 4096,
              let mode = checkpoint["permissionMode"].string.flatMap(BackendHOOTSIMPermissionMode.init(rawValue:)) else {
            throw NativeRPCError.invalidArguments("The chat options checkpoint is invalid.")
        }
        let preferences = checkpoint["preferences"].isNullish ? nil : try HootReadyPreferences(wire: checkpoint["preferences"])
        if let preferences {
            guard let provider = preferences.provider else { throw NativeRPCError.invalidArguments("The chat checkpoint needs its selected Coding AI.") }
            try BackendAGSValidation.check(.init(provider: provider.rawValue, model: preferences.model,
                effort: preferences.effort, permissionMode: mode.cliMode(provider: provider)))
        }
        conversationPreferences = preferences; conversationMode = mode
    }
    public func resetChatOptions() { conversationPreferences = nil; conversationMode = .ask }
    public func chatOptions(projectPath: String) async throws -> NativeRPCValue {
        let current = try await read(projectPath: projectPath, forConversation: true)
        return await chatOptions(current: current)
    }
    private func chatOptions(current: BackendHootReadySelection) async -> NativeRPCValue {
        // The saved choice is the only one: the composer shows exactly what Settings/the popover saved.
        if conversationPreferences == nil { conversationMode = Self.chatMode(current.preferences.permissionMode) }
        let catalog = current.catalog
        var offered: [NativeRPCValue] = []
        for provider in HootReadyDefaults.providerOrder where current.accounts.elements?.contains(where: {
            $0["provider"].string == provider.rawValue && $0["installed"].bool == true
        }) == true {
            let name = provider == .claude ? "Claude Code" : provider == .codex ? "Codex" : "Gemini"
            // Short model names, like Claude's own picker.
            // Only the models loaded live for this account (featured first, then the rest).
            let live = catalog[provider.rawValue]
            let rows = live["models"].elements ?? []
            let order = (live["featured"].elements ?? []) + (live["more"].elements ?? [])
            for id in order.compactMap(\.string) where !offered.contains(where: { $0["id"].string == provider.rawValue + ":" + id }) {
                guard let row = rows.first(where: { $0["id"].string == id }) else { continue }
                offered.append(.object([.init("id", .string(provider.rawValue + ":" + id)), .init("provider", .string(name)), .init("name", .string(row["name"].string ?? id))]))
            }
            if let saved = await settings.value(key("model", provider)).string, !saved.isEmpty,
               !offered.contains(where: { $0["id"].string == provider.rawValue + ":" + saved }) {
                offered.append(.object([.init("id", .string(provider.rawValue + ":" + saved)), .init("provider", .string(name)), .init("name", .string(saved))]))
            }
            if provider == current.provider, let selected = current.preferences.model,
               !offered.contains(where: { $0["id"].string == provider.rawValue + ":" + selected }) {
                offered.append(.object([.init("id", .string(provider.rawValue + ":" + selected)), .init("provider", .string(name)), .init("name", .string(selected))]))
            }
        }
        // No "Default" choice anywhere: an unset choice shows what the CLI really uses.
        let real = Self.cliDefaults(provider: current.provider, configDir: current.profile?.configDir)
        let liveModel = catalog[current.provider.rawValue]["defaultModel"].string ?? catalog[current.provider.rawValue]["current"].string
        let model = current.preferences.model ?? (real.model == "default" ? liveModel ?? real.model : real.model)
        let modelID = current.provider.rawValue + ":" + model
        if model != "default", !offered.contains(where: { $0["id"].string == modelID }) {
            let name = current.provider == .claude ? "Claude Code" : current.provider == .codex ? "Codex" : "Gemini"
            offered.append(.object([.init("id", .string(modelID)), .init("provider", .string(name)), .init("name", .string(Self.shortModelName(model, provider: current.provider)))]))
        }
        return .object([.init("permissionMode", .string(conversationMode.rawValue)),
            .init("catalog", catalog),
            .init("fastMode", current.preferences.fastMode.map(NativeRPCValue.bool) ?? .null),
            .init("model", .string(modelID)),
            .init("models", .array(offered)), .init("ready", .bool(current.ready)),
            .init("effort", .string(current.preferences.effort ?? real.effort)),
            .init("efforts", .array(AGSCapabilities.efforts(provider: current.provider.rawValue).map(NativeRPCValue.string))),
            .init("recommendedEffort", AGSCapabilities.recommendedEffort(provider: current.provider.rawValue, model: model).map(NativeRPCValue.string) ?? .null)])
    }
    /// What the CLI really uses when Hoot leaves model or effort unset: the account's own
    /// settings (Claude settings.json model/effortLevel, Codex config.toml, Gemini settings.json),
    /// else the catalogue's first model and a middle effort.
    public static func cliDefaults(provider: HootChatProvider, configDir: String?) -> (model: String, effort: String) {
        let efforts = AGSCapabilities.efforts(provider: provider.rawValue)
        var model: String?, effort: String?
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        func json(_ path: String) -> NativeRPCValue {
            guard let data = try? BackendAccountFiles.boundedRead(URL(fileURLWithPath: path), maximum: 1_048_576),
                  let value = try? NativeRPCValue.parseJSON(data) else { return .null }
            return value
        }
        switch provider {
        case .claude:
            let settings = json((configDir ?? home + "/.claude") + "/settings.json")
            model = ProcessInfo.processInfo.environment["ANTHROPIC_MODEL"] ?? settings["model"].string
            effort = settings["effortLevel"].string
        case .codex:
            if let data = try? BackendAccountFiles.boundedRead(URL(fileURLWithPath: (configDir ?? home + "/.codex") + "/config.toml"), maximum: 1_048_576),
               let text = String(data: data, encoding: .utf8) {
                for line in text.split(separator: "\n") {
                    let parts = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                    guard parts.count == 2 else { continue }
                    let value = parts[1].trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                    if parts[0] == "model" { model = model ?? value }
                    if parts[0] == "model_reasoning_effort" { effort = effort ?? value }
                }
            }
        case .gemini:
            let settings = json((configDir ?? home + "/.gemini") + "/settings.json")
            model = settings["model"]["name"].string ?? settings["model"].string
        }
        let fallbackModel = HootModelCatalog.models(provider).first?.id ?? "default"
        let fallbackEffort = AGSCapabilities.defaultEffort(provider: provider.rawValue) ?? efforts.last ?? "medium"
        return (model.flatMap { $0.isEmpty ? nil : $0 } ?? fallbackModel,
                effort.flatMap { efforts.contains($0) ? $0 : nil } ?? fallbackEffort)
    }
    /// "claude-opus-5-5" → "Opus 5.5"; Claude Code's alias "opus[1m]" → "Opus 1M" (as Claude Code names it); a
    /// catalogue alias → its catalogue name.
    static func shortModelName(_ id: String, provider: HootChatProvider) -> String {
        let base = id.replacingOccurrences(of: "[1m]", with: ""), million = provider == .claude && id.hasSuffix("[1m]") ? " 1M" : ""
        if let known = HootModelCatalog.models(provider).first(where: { $0.id == base }) { return known.name + million }
        let parts = base.split(separator: "-")
        if parts.count >= 3, parts[0] == "claude" {
            let numbers = parts.dropFirst(2).prefix(2).filter { $0.count <= 2 && $0.allSatisfy(\.isNumber) }
            return parts[1].capitalized + (numbers.isEmpty ? "" : " " + numbers.joined(separator: ".")) + million
        }
        // A bare Claude Code alias ("opus", "sonnet") reads as a name.
        if provider == .claude, !base.isEmpty, !base.contains("-") { return base.capitalized + million }
        return base + million
    }
    /// Full replacement of the selected provider's Hoot choices. Window authority is checked by INT2's route.
    public func save(_ value: NativeRPCValue, projectPath: String) async throws -> BackendHootReadySelection {
        try requireEnabled()
        let inventory = try await inventory(projectPath: projectPath)
        return try await save(value, projectPath: projectPath, inventory: inventory)
    }
    private func save(_ value: NativeRPCValue, projectPath: String, inventory: Inventory) async throws -> BackendHootReadySelection {
        var requested = try HootReadyPreferences(wire: value)
        let current = try await selection(projectPath: projectPath, inventory: inventory), provider = requested.provider ?? current.provider
        // Switching Hoot's AI keeps what the person chose for the AI it switches to (H20b, 11 Oct: Claude Code's Bypass
        // was lost by switching to Codex and back). Only what the request names is changed.
        if provider != current.provider {
            if requested.permissionMode == nil { requested.permissionMode = await settings.value(key("permission", provider)).string }
            if requested.model == nil { requested.model = await settings.value(key("model", provider)).string }
            if requested.effort == nil { requested.effort = await settings.value(key("effort", provider)).string }
            if requested.contextWindow == nil { requested.contextWindow = await settings.value(key("context", provider)).string }
            if requested.fastMode == nil { requested.fastMode = await settings.value(key("fast", provider)).bool }
        }
        if let id = requested.profileID {
            guard inventory.candidates.contains(where: { $0.1.id == id && $0.0 == provider }) else {
                throw NativeRPCError.invalidArguments("That account does not belong to the selected AI.")
            }
        }
        try BackendAGSValidation.check(.init(provider: provider.rawValue, model: requested.model, effort: requested.effort, permissionMode: requested.permissionMode))
        // Hoot offers asks first / edits on its own / plans only / bypass. Bypass is the owner's choice in the window only (MCP refuses it).
        let allowedModes: [HootChatProvider: Set<String>] = [.claude: ["default", "acceptEdits", "plan", "bypassPermissions"],
            .codex: ["default", "workspace-write", "read-only", "danger-full-access"], .gemini: ["default", "auto_edit", "plan", "yolo"]]
        if let mode = requested.permissionMode, allowedModes[provider]?.contains(mode) != true {
            throw NativeRPCError.invalidArguments("Choose asks first, edits on its own, plans only or bypass for Hoot.")
        }
        if requested.contextWindow == "max", provider != .codex || BackendHootModelSource.codexMaxWindow(model: requested.model, home: modelHome) == nil {
            throw NativeRPCError.invalidArguments("That model has no larger context window.")
        }
        if requested.contextWindow == "1m", !HootModelCatalog.supportsOneMillion(provider: provider, model: requested.model) {
            throw NativeRPCError.invalidArguments("That model has no 1M context window. Choose Opus, Fable or Sonnet in Claude Code.")
        }
        if provider == .gemini, requested.effort != nil {
            guard let model = requested.model, model.hasPrefix("gemini-3"), !model.contains("flash-lite") else {
                throw NativeRPCError.invalidArguments("Choose a compatible Gemini 3 model before setting its thinking level.")
            }
        }
        _ = try await settings.patch(.object([
            .init(HootProviderPreference.key, requested.provider.map { .string($0.rawValue) } ?? .null),
            // Never saved any more: Hoot's account is its row in Who uses what (the popover's account list writes that).
            .init(key("account", provider), .null),
            .init(key("model", provider), requested.model.map(NativeRPCValue.string) ?? .null),
            .init(key("effort", provider), requested.effort.map(NativeRPCValue.string) ?? .null),
            .init(key("permission", provider), requested.permissionMode.map(NativeRPCValue.string) ?? .null),
            .init(key("context", provider), requested.contextWindow.map(NativeRPCValue.string) ?? .null),
            .init(key("fast", provider), requested.fastMode.map(NativeRPCValue.bool) ?? .null)]))
        return try await selection(projectPath: projectPath, inventory: inventory)
    }
    private func key(_ field: String, _ provider: HootChatProvider) -> String { "hoot.\(field).\(provider.rawValue)" }
    private func requireEnabled() throws {
        guard enabled else { throw NativeRPCError(code: "unavailable", message: "Hoot defaults are awaiting integration.") }
    }
}
