import SwiftUI
import TerminalDeckNativeCore

/// Coding AI · Account · Model · Effort · Context window · Before it changes files.
/// Every change saves at once and Hoot uses it on its next message.
/// `quick` (the sliders popover, Asad 12 Oct): only the account, the model, the context window in use as a plain line,
/// effort and "Before it changes files"; which Coding AI and its setup stay on Hoot's profile.
struct HootBrainRows: View {
    @Bindable var brain: ROUTINESHootBrainModel
    var compact = false
    var quick = false
    var body: some View {
        Group {
            if !quick {
                row("Coding AI", help: "Claude Code, Codex or Gemini.") {
                    NativeHootProviderSelection(provider: Binding(get: { brain.chosenProvider }, set: brain.selectProvider),
                        disabled: !brain.loaded || brain.busy)
                }
            }
            // ACCOUNTS: every signed-in account of every Coding AI in one list, like a session's account chip (Asad, 12 Oct).
            row("Account", help: "The account Hoot uses. Choosing one of another Coding AI switches Hoot to it, and the chat carries on.") {
                HootAccountMenu(brain: brain)
            }
            row("Model", help: "Choose a real model from the selected Coding AI. Account lists all your Coding AI accounts.") {
                Menu {
                    if brain.catalogue.isEmpty {
                        // Nothing loaded live: only the model in use (retried next time the menu opens).
                        Button(brain.currentLabel) { }.disabled(true)
                    } else {
                        ForEach(brain.featuredModels, id: \.id) { model in
                            Button { brain.selectModel(model.id) } label: {
                                if model.id == brain.selectedID { Label(brain.title(model), systemImage: "checkmark") } else { Text(brain.title(model)) }
                            }
                        }
                        if !brain.moreModels.isEmpty {
                            Menu("More models") {
                                ForEach(brain.moreModels, id: \.id) { model in
                                    Button { brain.selectModel(model.id) } label: {
                                        if model.id == brain.selectedID { Label(model.name, systemImage: "checkmark") } else { Text(model.name) }
                                    }
                                }
                            }
                        }
                    }
                } label: { DeckRowLabel(brain.modelLabel, image: DeckRowIcon.provider(brain.chosenProvider)).labelStyle(.titleAndIcon) }.fixedSize()
            }
            if !quick, let fast = brain.fastMode {
                row("Fast mode", help: "Claude Code's faster answers for this account.") {
                    Toggle("Fast mode", isOn: Binding(get: { fast }, set: brain.selectFastMode)).labelsHidden().toggleStyle(.switch)
                }
            }
            if !brain.chatEfforts.isEmpty, !brain.chatEffort.isEmpty {
                // The Faster ↔ Smarter slider (with Ultracode and the AI shimmer) that used to sit
                // under the message box: effort lives here now (Asad, 10 Oct).
                HootEffortSlider(levels: brain.chatEfforts, recommended: brain.chatRecommended, selected: brain.chatEffort,
                                 onChange: brain.selectEffort)
            }
            row("Before it changes files", help: "Hoot asks you first by default.") {
                Picker("Before it changes files", selection: Binding(get: { brain.permissionWord }, set: brain.selectPermission)) {
                    Text("Asks first").tag("ask")
                    Text("Edits on its own").tag("edit")
                    Text("Plans only").tag("plan")
                    Divider()
                    Text("Bypass permissions").tag("bypass")
                }.labelsHidden().fixedSize()
            }
            if let problem = brain.problem {
                HStack { ROUTINESNotice(tone: .error, text: problem); DeckRetryButton { brain.reload() } }
            } else if let status = brain.status { Text(status).font(.caption).foregroundStyle(.secondary) }
        }
        // Never greyed while a choice saves: it applies in the background (no flash).
        .disabled(!brain.loaded)
    }
    /// The same short words as the message box everywhere ("Extra", not "Extra high").
    static func effortName(_ id: String) -> String { HootComposerModel.effortName(id) }
    @ViewBuilder private func row<C: View>(_ label: String, help: String, @ViewBuilder control: () -> C) -> some View {
        let content = control()
        if compact {
            LabeledContent(label) { content }.help(help)
        } else {
            NativeSettingRow(label: label, help: help) { content }
        }
    }
}

@MainActor @Observable
final class ROUTINESHootBrainModel {
    typealias Invoke = @MainActor (String, [Any?]) async throws -> CodingAIJSON
    /// The live app shares one brain between Settings → Hoot and the quick popover.
    static let shared = ROUTINESHootBrainModel()
    var provider = ""
    var profile = ""
    var model = ""
    var effort = ""
    var permissionMode = ""
    var contextWindow = "standard"
    var effectiveProvider = "claude"
    var accounts: [CodingAIJSON] = []
    var models: [String: [String]] = [:]
    var busy = false
    var loaded = false
    var problem: String?
    var status: String?
    @ObservationIgnored private let invoke: Invoke
    @ObservationIgnored private var generation = 0

    /// The one shared, observed copy of Hoot's chat choices (the composer uses the same one).
    @ObservationIgnored let choices: HootChatChoices
    /// Model, effort and permission go through Hoot's chat model: a permission change (Bypass
    /// included) applies mid-turn; model and effort wait for the turn to end, silently.
    @ObservationIgnored private let queue: NativeHootChatModel?
    private var router: NativeHootChatModel { queue ?? .shared }
    var chatRecommended: String?
    @ObservationIgnored private var choicesObserver: UUID?
    init(snapshot: CodingAIJSON? = nil, invoke: @escaping Invoke = { channel, args in
        CodingAIJSON(try await EngineBridge.shared.invoke(channel, args))
    }, choices: HootChatChoices = .shared, queue: NativeHootChatModel? = nil) {
        self.invoke = invoke; self.choices = choices; self.queue = queue
        if let snapshot { accept(snapshot); loaded = true }
    }
    var chosenProvider: String { provider.isEmpty ? effectiveProvider : provider }
    /// The account Hoot really uses now (the saved pick, else the one the app chose for it).
    var effectiveProfile = ""
    var currentAccountID: String { profile.isEmpty ? effectiveProfile : profile }
    var currentAccountName: String {
        if let named = accounts.first(where: { $0["id"].string == currentAccountID && ($0["provider"].string ?? "claude") == chosenProvider })?["name"].string, !named.isEmpty { return named }
        return currentAccountID.isEmpty ? "This Mac's own login" : "Saved account (unavailable)"
    }
    struct AccountChoice: Identifiable, Equatable { let id: String, name: String }
    struct AccountGroup: Equatable { let provider: String, title: String, accounts: [AccountChoice] }
    /// Every account that is ready (installed and signed in), of every Coding AI, grouped by AI; the one in use always shows.
    var accountGroups: [AccountGroup] {
        let titles = ["claude": "Claude Code", "codex": "Codex", "gemini": "Gemini"]
        return ["claude", "codex", "gemini"].compactMap { provider in
            var seen = Set<String>(), emails = Set<String>()
            let available = accounts.filter { ($0["provider"].string ?? "claude") == provider }.sorted {
                ($0["id"].string == currentAccountID) && ($1["id"].string != currentAccountID)
            }
            let rows = available.compactMap { row -> AccountChoice? in
                guard let id = row["id"].string, seen.insert(id).inserted else { return nil }
                let current = provider == chosenProvider && id == currentAccountID
                guard current || (row["signedIn"].isTrue && row["installed"].bool != false) else { return nil }
                let name = row["name"].string.flatMap { $0.isEmpty ? nil : $0 } ?? id
                if let email = CodingAILogins.normalizedEmail(name), !emails.insert(email).inserted { return nil }
                return AccountChoice(id: id, name: name)
            }
            return rows.isEmpty ? nil : AccountGroup(provider: provider, title: titles[provider] ?? provider, accounts: rows)
        }
    }
    /// The context window Hoot's model works with, when it is really known: Claude's 1M (the [1m] model it launches),
    /// else what the CLI itself reported on Hoot's last answer, else the window the installed CLI lists for the model.
    var measuredWindow: Int?
    var measuredProvider: String?
    var appliedWindow: Int? {
        if chosenProvider == "claude", contextWindow == "1m", oneMillionAvailable { return 1_000_000 }
        if let measuredWindow, measuredWindow > 0, measuredProvider == chosenProvider { return measuredWindow }
        guard chosenProvider != "claude", let id = selectedID, let picked = catalogue.first(where: { $0.id == id }) else { return nil }
        return contextWindow == "max" ? (picked.maxContextWindow ?? picked.contextWindow) : picked.contextWindow
    }
    var appliedWindowLabel: String? { appliedWindow.map { Self.tokens($0) + " tokens" } }
    /// An account of this AI, or of another (which switches Hoot to that AI; the chat carries on). The account is
    /// written to Hoot's row in Settings › Coding AIs › Who uses what (the orchestrator seat): one place, the same row
    /// the Settings table shows (SETTINGS-TRUTH line 74). Hoot uses it from its next message.
    func selectAccount(_ id: String, provider value: String) {
        guard loaded, !busy else { return }
        busy = true; status = nil; problem = nil
        Task {
            do {
                _ = try await invoke("profiles:set-level", [["kind": "seat", "key": "orchestrator"], value, id])
                busy = false
                guard value != chosenProvider else { effectiveProfile = id; savedNote(); refreshQuietly(); return }
                switchProvider(value)
            } catch {
                busy = false
                problem = CodingAIErrorText.from(error, fallback: "Couldn't change Hoot's account.")
            }
        }
    }
    /// What the CLI reported on Hoot's last answer (the chat's own reading), read without waiting on anything.
    func readMeasuredWindow() {
        Task {
            guard let value = try? await invoke("hoot:chat:read", [NSNull(), 1]) else { return }
            measuredWindow = value["window"].number.map { Int($0) }
            measuredProvider = value["provider"].string
        }
    }
    var chatProvider: HootChatProvider { HootChatProvider(rawValue: chosenProvider) ?? .claude }
    var providerAccounts: [CodingAIJSON] { accounts.filter { $0["provider"].string == chosenProvider } }
    var modelChoices: [String] { models[chosenProvider] ?? [] }
    struct PickerModel: Equatable { let id: String, name: String, efforts: [String], contextWindow: Int?, maxContextWindow: Int?, oneMillion: Bool }
    /// From the installed CLI where it says (Codex's own list), else the maintained list.
    var catalogs: [String: [PickerModel]] = [:]
    var catalogue: [PickerModel] { catalogs[chosenProvider] ?? [] }
    var featured: [String: [String]] = [:]
    var defaults: [String: String?] = [:]
    var current: [String: String?] = [:]
    var fastAvailable: [String: Bool] = [:]
    /// The account's own Claude Code Fast mode (its settings), shown when Hoot has no choice of its own saved.
    var fastAccountOn: [String: Bool] = [:]
    var fastOn: Bool?
    var featuredModels: [PickerModel] { let ids = featured[chosenProvider] ?? []; return ids.isEmpty ? catalogue : catalogue.filter { ids.contains($0.id) } }
    var moreModels: [PickerModel] { let ids = Set(featured[chosenProvider] ?? []); return ids.isEmpty ? [] : catalogue.filter { !ids.contains($0.id) } }
    var defaultID: String? {
        if let id = defaults[chosenProvider] ?? nil, !["default", "auto", ""].contains(id.lowercased().replacingOccurrences(of: "[1m]", with: "")), catalogue.contains(where: { $0.id == id }) { return id }
        return catalogue.first?.id
    }
    /// The chosen model, or the account default when Hoot follows the AI's own choice.
    var selectedID: String? {
        if chatModel.hasPrefix(chosenProvider + ":") {
            let id = String(chatModel.dropFirst(chosenProvider.count + 1))
            if !["default", "auto", ""].contains(id.lowercased().replacingOccurrences(of: "[1m]", with: "")) { return id }
        }
        return ["default", "auto", ""].contains(model.lowercased().replacingOccurrences(of: "[1m]", with: "")) ? defaultID : model
    }
    func title(_ m: PickerModel) -> String { m.name }
    var currentLabel: String { modelLabel }
    /// Shown only when Claude Code reports Fast mode for this account.
    var fastMode: Bool? { fastAvailable[chosenProvider] == true ? (fastOn ?? fastAccountOn[chosenProvider] ?? false) : nil }
    /// Through Hoot's chat model and the shared choices, like effort: the composer and island show it at once (U91).
    func selectFastMode(_ on: Bool) { fastOn = on; router.changeFastMode(on); savedNote() }
    var selectedModel: PickerModel? { catalogue.first { $0.id == model } }
    /// No model is saved for this AI: it uses its own choice (the model it picks by itself).
    var followsAIModel: Bool { model.isEmpty }
    var modelLabel: String {
        if let id = selectedID, id != "default" { return catalogue.first { $0.id == id }?.name ?? id }
        if let value = current[chosenProvider] ?? nil, value != "default" { return value }
        return "Choose model"
    }
    var efforts: [String] { selectedModel?.efforts ?? AGSCapabilities.efforts(provider: chosenProvider) }
    var oneMillionAvailable: Bool { HootModelCatalog.supportsOneMillion(provider: chatProvider, model: model.isEmpty ? nil : model) }
    static func tokens(_ n: Int) -> String { n >= 1_000_000 ? "\(n / 1_000_000)M" : "\(n / 1_000)K" }
    var contextChoices: [(id: String, label: String)] {
        if chosenProvider == "claude" && oneMillionAvailable { return [("standard", "Standard"), ("1m", "1M")] }
        if chosenProvider == "codex", let base = selectedModel?.contextWindow, let max = selectedModel?.maxContextWindow, max > base {
            return [("standard", "Standard · " + Self.tokens(base)), ("max", "Largest · " + Self.tokens(max))]
        }
        return [("standard", selectedModel?.contextWindow.map { "Set by the model · " + Self.tokens($0) } ?? "Set by the model")]
    }
    var contextHelp: String {
        contextChoices.count > 1 ? "A larger window keeps more of the chat in view and uses more tokens."
            : chosenProvider == "claude" ? "Choose Opus or Sonnet for a 1M window." : "This model has one context size."
    }
    /// The provider's own permission words, shown as three plain choices.
    static func cliMode(_ word: String, provider: String) -> String? {
        switch word {
        case "edit": return provider == "codex" ? "workspace-write" : provider == "gemini" ? "auto_edit" : "acceptEdits"
        case "plan": return provider == "codex" ? "read-only" : "plan"
        case "bypass": return provider == "codex" ? "danger-full-access" : provider == "gemini" ? "yolo" : "bypassPermissions"
        default: return nil
        }
    }
    var permissionWord: String {
        switch permissionMode {
        case "acceptEdits", "workspace-write", "auto_edit": return "edit"
        case "plan", "read-only": return "plan"
        case "bypassPermissions", "danger-full-access", "yolo": return "bypass"
        default: return "ask"
        }
    }
    func load() {
        guard !loaded else { return }
        reload()
    }
    @ObservationIgnored private var settingsWatch: EngineSubscription?
    func reload() {
        // Live both ways: every writer (the composer, the island, here) goes through the one
        // shared HootChatChoices, and every view observes it, so changes show at once.
        if choicesObserver == nil {
            choicesObserver = choices.addObserver { [weak self] value in
                self?.acceptChat(CodingAIJSON(value.foundation ?? [:])); self?.refreshQuietly()
            }
        }
        loadChatOptions()
        readMeasuredWindow()
        generation += 1; let mine = generation; problem = nil
        Task {
            try? await Task.sleep(for: .seconds(10))
            guard generation == mine, !loaded, problem == nil else { return }
            generation += 1
            problem = "Hoot's AI choices took too long to read. Try Again."
        }
        Task {
            do {
                let value = try await invoke("hoot:ready:read", [])
                guard generation == mine else { return }
                accept(value); loaded = true; problem = nil
            } catch {
                guard generation == mine else { return }
                problem = CodingAIErrorText.from(error, fallback: "Couldn't read Hoot's AI.")
            }
        }
    }
    /// Re-read the saved choices without the loading/timeout state.
    func refreshQuietly() {
        Task { if let value = try? await invoke("hoot:ready:read", []) { accept(value) } }
    }
    func selectProvider(_ value: String) {
        guard !busy, value != chosenProvider else { return }
        switchProvider(value)
    }
    /// H20b: each Coding AI keeps the person's own permission choice (Bypass included) when Hoot
    /// switches away and back; a choice is only ever handed to the AI it was made for. The backend
    /// keeps it with Hoot's saved choices (hoot.permission.<ai>) and brings it back when the save
    /// names none, so there is no second copy here to go stale or get lost (U91).
    private func switchProvider(_ value: String) {
        save(provider: value, profile: "", model: "", effort: "", permission: "", context: "standard")
    }
    func selectModel(_ value: String) {
        let next = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !next.isEmpty else { return }
        chatModel = chosenProvider + ":" + next
        router.changeModel(chatModel)
        savedNote()
    }
    /// Effort and model go through hoot:chat:options, the one setting the composer uses too.
    var chatEffort = ""
    var chatEfforts: [String] = []
    var chatModel = ""
    func selectEffort(_ value: String) { chatEffort = value; router.changeEffort(value); savedNote() }
    func loadChatOptions() {
        Task { await choices.reload() }
    }
    private func acceptChat(_ value: CodingAIJSON) {
        chatEffort = value["effort"].string ?? chatEffort
        chatEfforts = value["efforts"].array?.compactMap(\.string) ?? chatEfforts
        chatModel = value["model"].string ?? chatModel
        chatRecommended = value["recommendedEffort"].string
    }
    private func changeChat(_ patch: [String: Any]) {
        guard !busy else { return }
        busy = true; status = nil; problem = nil
        Task {
            defer { busy = false }
            do {
                acceptChat(CodingAIJSON(try await choices.change(patch).foundation ?? [:]))
                status = "Saved. Hoot uses it from its next message."
            } catch { problem = CodingAIErrorText.from(error, fallback: "Couldn't change Hoot's choice.") }
        }
    }
    func selectContextWindow(_ value: String) { save(context: value) }
    func selectPermission(_ word: String) {
        let mode: HootPermissionMode = word == "edit" ? .changes : word == "plan" ? .plan : word == "bypass" ? .bypass : .ask
        permissionMode = Self.cliMode(word, provider: chosenProvider) ?? ""
        router.changePermission(mode); savedNote()
    }
    private func savedNote() { problem = nil; status = "Saved. Hoot uses it from its next message." }
    private func save(provider: String? = nil, profile: String? = nil, model: String? = nil, effort: String? = nil,
                      permission: String? = nil, context: String? = nil, fast: Bool? = nil) {
        guard loaded, !busy else { return }
        busy = true; status = nil; problem = nil
        let p = provider ?? self.provider, a = profile ?? self.profile, m = model ?? self.model, e = effort ?? self.effort
        let pm = permission ?? permissionMode, c = context ?? contextWindow
        let choices: [String: Any] = ["provider": p.isEmpty ? NSNull() : p as Any, "profileId": a.isEmpty ? NSNull() : a as Any,
            "model": m, "effort": e, "permissionMode": pm, "contextWindow": c,
            "fastMode": (fast ?? fastOn).map { $0 as Any } ?? NSNull()]
        Task {
            defer { busy = false }
            do {
                accept(try await invoke("hoot:ready:save", [choices]))
                status = "Saved. Hoot uses it from its next message."
                // Provider, account, permission, context and Fast mode reach the composer too.
                await self.choices.reload()
            } catch { problem = CodingAIErrorText.from(error, fallback: "Couldn't save Hoot's AI.") }
        }
    }
    private func accept(_ value: CodingAIJSON) {
        effectiveProvider = value["provider"].string ?? "claude"
        effectiveProfile = value["profileId"].string ?? ""
        let choices = value["choices"]
        provider = choices["provider"].string ?? ""
        profile = choices["profileId"].string ?? ""
        model = choices["model"].string ?? ""
        effort = choices["effort"].string ?? ""
        permissionMode = choices["permissionMode"].string ?? ""
        contextWindow = choices["contextWindow"].string ?? "standard"
        accounts = value["accounts"].array ?? []
        for id in ["claude", "codex", "gemini"] {
            let picker = value["catalog"][id]
            catalogs[id] = (picker["models"].array ?? []).compactMap { row in
                guard let mid = row["id"].string else { return nil }
                return PickerModel(id: mid, name: row["name"].string ?? mid, efforts: row["efforts"].array?.compactMap(\.string) ?? [],
                                   contextWindow: row["contextWindow"].number.map(Int.init), maxContextWindow: row["maxContextWindow"].number.map(Int.init),
                                   oneMillion: row["oneMillion"].isTrue)
            }
            featured[id] = picker["featured"].array?.compactMap(\.string) ?? []
            defaults[id] = picker["defaultModel"].string; current[id] = picker["current"].string
            fastAvailable[id] = picker["fastMode"]["available"].isTrue
            fastAccountOn[id] = picker["fastMode"]["on"].isTrue
        }
        fastOn = choices["fastMode"].isNull ? nil : choices["fastMode"].bool
        for id in ["claude", "codex", "gemini"] {
            models[id] = value["models"][id].array?.compactMap(\.string) ?? []
        }
    }
}
