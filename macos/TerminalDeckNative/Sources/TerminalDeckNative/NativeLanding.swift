import AppKit
import Observation
import TerminalDeckBackend
import TerminalDeckNativeCore
@preconcurrency import SwiftTerm

// The New session page (Asad, 14 Nov 05:25): the app opens on it, like Claude's and Codex's own apps. One box he can
// type into at once, with the project, the AI and that AI's options already set the way HE last started a session on
// this Mac. 05:27: the page is not a session. Opening it, changing a choice or leaving it creates nothing anywhere;
// the session is made at the moment he sends his first message, with the choices as they stand then.

/// What the person last started on this Mac, with the names to draw it before anything is read. Local only
/// (this Mac's own defaults; it is not part of the Cloud).
struct NativeLastStart: Codable, Equatable, Sendable {
    var folder: String?
    var projectID: String?
    var projectName: String?
    var provider: String
    var providerName: String?
    var account: String?
    var accountName: String?
    var model: String?
    var modelName: String?
    var effort: String?
    var chat: Bool
    var agentID: String?
    var agentName: String?
    /// "Before it changes files", when he changed it under the box (nil: the app's own start for new sessions).
    var permission: String? = nil
}

/// The page's small local values: the last start, the unsent text and where the app opens.
enum NativeLandingMemory {
    static let lastStartKey = "landing.lastStart.v1"
    static let draftKey = "landing.draft.v1"

    static func lastStart(_ defaults: UserDefaults = .standard) -> NativeLastStart? {
        guard let data = defaults.data(forKey: lastStartKey) else { return nil }
        return try? JSONDecoder().decode(NativeLastStart.self, from: data)
    }
    static func remember(_ start: NativeLastStart, _ defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(start) else { return }
        defaults.set(data, forKey: lastStartKey)
    }
    static func draft(_ defaults: UserDefaults = .standard) -> String { defaults.string(forKey: draftKey) ?? "" }
    static func keepDraft(_ text: String, _ defaults: UserDefaults = .standard) {
        let kept = String(text.prefix(64 * 1024))
        if kept.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { defaults.removeObject(forKey: draftKey) }
        else { defaults.set(kept, forKey: draftKey) }
    }
}

/// Settings › General › "When Terminal Deck opens". The setting lives in the app's settings (tools can change it with
/// settings_write); this Mac keeps a copy so the very first frame can follow it without asking anything.
/// Owner, 15 Nov: the Overview page is gone; the choices are New session (default), Hoot chat, Where I left off.
enum NativeLandingOpensOn: String, CaseIterable, Sendable {
    case newSession = "new-session", hoot = "hoot", leftOff = "left-off"
    static let settingID = "general.whenOpens"
    static let mirrorKey = "landing.opensOn.v1"
    /// The retired choice an older build saved. It opens New session now.
    static let retiredOverview = "overview"

    /// A saved value, old ones included ("overview" reads as New session).
    init?(stored: String) {
        if stored == Self.retiredOverview { self = .newSession; return }
        self.init(rawValue: stored)
    }
    static func current(_ defaults: UserDefaults = .standard) -> Self {
        defaults.string(forKey: mirrorKey).flatMap(Self.init(stored:)) ?? .newSession
    }
    static func mirror(_ value: String?, _ defaults: UserDefaults = .standard) {
        guard let value, let known = Self(stored: value) else { return }
        defaults.set(known.rawValue, forKey: mirrorKey)
    }
}

/// Keyboard focus for the page's box. The box takes the keyboard only for a new ticket, and tickets are given ONLY at
/// launch and when the person asks for a new session (hard rule after text landed in the wrong place). A tool, an AI,
/// a session starting or the page drawing again never gives one.
@MainActor @Observable
final class NativeLandingFocus {
    static let shared = NativeLandingFocus()
    private(set) var ticket = 0
    @ObservationIgnored private(set) var used = 0
    init() {}
    func personAsked() { ticket += 1 }
    /// True once per ticket: the box that asks first takes the keyboard.
    func take() -> Bool {
        guard ticket > used else { return false }
        used = ticket
        return true
    }
}

/// The app's own folder in his home, named in this one place (Owner, 14 Nov: a session with no project never runs in his
/// home folder). The project-folders lane puts `Projects/<name>` beside `Independent`.
enum NativeLandingPlaces {
    /// The Terminal Deck folder: the one chosen in Settings on this Mac (project folders), else `~/Terminal Deck`.
    /// A caller naming its own home (tests) always gets `<home>/Terminal Deck`.
    static func base(home: String? = nil) -> URL {
        if home == nil, let chosen = BackendProjectFolders.installed?.configuredBase { return URL(fileURLWithPath: chosen, isDirectory: true) }
        return BackendProjectFolders.defaultBase(home: home ?? NSHomeDirectory())
    }
    static func independent(home: String? = nil) -> URL {
        base(home: home).appendingPathComponent("Independent", isDirectory: true)
    }
    /// The folder a session with no project runs in, made on first use.
    static func ensureIndependent(home: String? = nil) throws -> String {
        let folder = independent(home: home)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.path
    }
    static func folderExists(_ path: String) -> Bool {
        var directory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &directory) && directory.boolValue
    }
}

/// What the RUNNING session host can start (Owner's Mac mini keeps an older host across app installs: never restarted
/// without his word). Read from the host's own hello (`BackendHOSTProtocol.Hello.chosenStartPermission`), live, never
/// from this app's bundle: after a reconnect to another helper the answer follows it.
@MainActor
enum NativeLandingHost {
    /// THE SWITCH. 14 Nov: off (a restored "Ask first" session lost it). 15 Nov review item 3 ("Bypass permission is not
    /// clickable"): ON. The session starts in the mode he picks (explicit start, R73's one exception) wherever the running
    /// host says it can (`chosenStartPermission` in its hello). After a restore, the open chat's pill shows the mode the
    /// session REALLY runs (`NativeSessionModeTruth`), not the one it started with; keeping a stricter mode across a
    /// restore needs the host change written in the seat note 2026-11-15-new-session-review (not made: no host change).
    static let pickOffered = true

    /// The running session helper, as far as the pick is concerned.
    enum Helper: Equatable { case none, notReady, hello(chosenStartPermission: Int?) }

    /// True: a session can start in the page's explicit "Before it changes files" pick. False: every new session starts
    /// in Bypass (R73), so the page offers no pick and shows Bypass.
    static func honoursChosenStart() -> Bool { honours(offered: pickOffered, helper: running()) }

    /// The rule, apart from the live helper (checks call it with their own values).
    nonisolated static func honours(offered: Bool, helper: Helper) -> Bool {
        guard offered else { return false }
        switch helper {
        case .none: return true // no helper: this build's own launcher starts the sessions
        case .notReady: return false // starting, gone or reconnecting: never show a stricter mode than would start
        case .hello(let flag): return flag == 1
        }
    }

    private static func running() -> Helper {
        #if TD_HOST_ACCOUNT_BRIDGE && TD_HOST_INTEGRATED
        guard let managed = NativeCompositionINT2HOSTManaged.current else { return .none }
        guard let agents = managed.managedClient, agents.isConnected else { return .notReady }
        return .hello(chosenStartPermission: agents.hello.chosenStartPermission)
        #else
        return .none
        #endif
    }
}

/// The one door to the page.
@MainActor
enum NativeLanding {
    /// The side panel id of the page (a native-only place, like Servers or a project's page).
    static let pageID = "new-session-page"
    static let model = NativeLandingModel(effects: .live)
    private static var settingsWatch: EngineSubscription?

    /// The person asked for a new session (menu, ⌘T, the side panel's +, a project's New session, Open folder…).
    static func show(folder: String? = nil, project: PROJProject? = nil) throws {
        guard NativeButtonPresentation.sessionParent != nil else {
            throw NativeRPCError(code: "no-window", message: "Open the main window before starting a session.")
        }
        NativeFront.whenPersonActs("new-session") {
            if folder != nil || project != nil { model.prefill(folder: folder, project: project) }
            NativeButtonPresentation.sessionParent?.makeKeyAndOrderFront(nil)
            NativeLandingFocus.shared.personAsked()
            AppModel.shared.select(pageID)
        }
    }

    /// A tool asked for a new session: the page gets that folder ready, unseen, keyboard untouched; never while he is
    /// on the page or has words in its box.
    static func prepare(folder: String?) {
        model.prepareForTool(folder: folder, onScreen: AppModel.shared.landingOnScreen)
    }

    /// The session helper changed under the app (a reconnect): the page re-reads what it can start.
    static func hostChanged() { model.refreshHost() }

    /// The engine is up: read the lists, and keep this Mac's copy of "When Terminal Deck opens" current.
    static func engineReady() {
        model.engineReady()
        Task { await mirrorSetting() }
        if settingsWatch == nil {
            settingsWatch = EngineBridge.shared.on("settings:changed") { _ in Task { @MainActor in await mirrorSetting() } }
        }
    }

    private static func mirrorSetting() async {
        guard let raw = try? await EngineBridge.shared.invoke("settings:get") as? [String: Any],
              let values = raw["values"] as? [String: Any] else { return }
        NativeLandingOpensOn.mirror(values[NativeLandingOpensOn.settingID] as? String)
    }
}

@MainActor @Observable
final class NativeLandingModel {
    @MainActor struct Effects {
        var invoke: @MainActor (String, [NativeRPCValue]) async throws -> NativeRPCValue = { _, _ in
            throw NativeRPCError(code: "unavailable", message: "Not connected.")
        }
        var ready: @MainActor () -> Bool = { false }
        var choices: @MainActor (String?) async -> NativeRPCValue = { _ in .null }
        var defaults: UserDefaults = .standard
        var projects: @MainActor () -> [PROJProject] = { [] }
        /// A new session goes into the side panel, quietly.
        var addQuietly: @MainActor ([String: Any]) -> Void = { _ in }
        /// The New session page is still what the window shows.
        var onScreen: @MainActor () -> Bool = { false }
        /// Show the session (only while the page is still on screen: he is waiting for it there).
        var show: @MainActor (String) -> Void = { _ in }
        /// A Terminal session's first message (session, AI, text): typed only at the AI's own prompt.
        var typeWhenReady: @MainActor (String, String, String) -> Void = { _, _, _ in }
        var browse: @MainActor () async -> String? = { nil }
        var exists: @MainActor (String) -> Bool = { NativeLandingPlaces.folderExists($0) }
        /// The folder a session with no project runs in (never his home folder).
        var defaultFolder: @MainActor () throws -> String = { try NativeLandingPlaces.ensureIndependent() }
        var pause: @MainActor () async -> Void = { try? await Task.sleep(for: .milliseconds(250)) }
        /// The running session host starts a session in the page's explicit pick (`NativeLandingHost`). False (the
        /// safe default): Bypass shows, display-only, and nothing explicit is sent.
        var hostHonoursPick: @MainActor () -> Bool = { false }

        /// The window's side of a start, for this app model (the live one, or a test's inert one).
        static func wired(to app: AppModel) -> Effects {
            var effects = Effects()
            effects.addQuietly = { [weak app] meta in app?.buttonActions.created(meta) }
            effects.onScreen = { [weak app] in app?.landingOnScreen == true }
            effects.show = { [weak app] id in app?.selectTab(id) }
            return effects
        }

        static var live: Effects {
            var effects = wired(to: AppModel.shared)
            effects.invoke = { try await EngineBridge.shared.invokeNativeValue($0, $1) }
            effects.ready = { EngineBridge.shared.isReady }
            effects.choices = { folder in
                // The model and effort always named, even with no live list (NativeLandingModels); the phones get the
                // same lists through the same call.
                await NativePhoneStart.newSessionLists(folder: folder, invoke: { channel, args in
                    try await EngineBridge.shared.invokeNativeValue(channel, args)
                })
            }
            effects.projects = { NativePROJLabels.shared.projects }
            effects.hostHonoursPick = { NativeLandingHost.honoursChosenStart() }
            effects.typeWhenReady = { id, provider, text in NativeLandingTerminal.typeWhenReady(id, provider: provider, text) }
            effects.browse = {
                guard let picked = try? await EngineBridge.shared.invoke("project:pick") as? String, !picked.isEmpty else { return nil }
                return picked
            }
            return effects
        }
    }

    struct Choice: Identifiable, Equatable { let id: String; let name: String }
    struct AI: Identifiable, Equatable {
        let id: String
        let name: String
        let chat: Bool
        var models: [Choice] = []
        var efforts: [String] = []
        var defaultAccount: String?
        /// What this AI runs when no model / effort is chosen (NativeLandingModels), when it says.
        var defaultModel: String? = nil
        var defaultEffort: String? = nil
    }
    /// A login, by the name he gave it. `email` shows (small, grey) only where two logins of one AI share a name;
    /// `state` is its one mark: nothing while it can run, orange when it needs him (sign in, or its limit is reached).
    struct Account: Identifiable, Equatable {
        enum State: String, Equatable { case ready, signIn, limit, unknown }
        let id: String; let name: String; let provider: String
        var email: String? = nil
        var state: State = .unknown
        /// It needs him before it can run: the only rows with a mark.
        var needsHim: Bool { state == .signIn || state == .limit }
        var stateWords: String? { switch state { case .signIn: "Needs sign-in"; case .limit: "Limit reached"; default: nil } }
    }
    struct Agent: Identifiable, Equatable {
        let id: String; let name: String; let provider: String; let lead: Bool
        /// The model and effort the agent's own settings give it (nil: it leaves that open). Read for the page only
        /// (`NativeLandingModels.filled`, from its saved record, as `BackendAgentSessionInput.make` launches it).
        var model: String? = nil
        var effort: String? = nil
        /// Its own "Before it changes files" (this AI's CLI value: "default", "plan", …), when its settings give one.
        var permission: String? = nil
    }

    // The choices, as they stand. folder nil: no project (the app's own Independent folder).
    private(set) var folder: String? = nil
    private(set) var projectID: String = PROJProjects.independentID
    private(set) var projectName: String = "Independent"
    private(set) var provider: String = "claude"
    private(set) var account: String? = nil
    private(set) var model: String? = nil
    private(set) var effort: String? = nil
    private(set) var chat: Bool = true
    private(set) var agentID: String? = nil { didSet { if agentID != oldValue { pickedForAgent = false } } }
    /// He picked "Before it changes files" since the agent was chosen: his pick, not the agent's own, is what starts.
    private(set) var pickedForAgent = false
    /// "Before it changes files" as he set it in the line under the box; nil: the app's start for new sessions
    /// (`BackendTAGLaunchArguments.newSessionPermission`, Bypass for Claude, Codex and Gemini).
    private(set) var permission: HootPermissionMode? = nil
    /// What the running session host can start (re-read at engine start, each list read, each send and each reconnect).
    private(set) var hostHonoursPick = false
    /// Files added with the box's "+": sent with the first message.
    var attachments: [HootComposerAttachment] = []
    var text: String = "" { didSet { if text != oldValue { NativeLandingMemory.keepDraft(text, effects.defaults) } } }

    // The lists, once read for the folder as it stands.
    private(set) var ais: [AI] = []
    private(set) var accounts: [Account] = []
    private(set) var agents: [Agent] = []
    private(set) var loaded = false
    private(set) var sending = false
    var problem: String? = nil

    @ObservationIgnored let effects: Effects
    @ObservationIgnored private let remembered: NativeLastStart?
    @ObservationIgnored private var loadTicket = 0
    @ObservationIgnored private var loading = false
    /// Bumped by his own Agent pick: a list arriving later never replaces it with the project's lead.
    @ObservationIgnored private var agentEpoch = 0
    @ObservationIgnored private var defaultProvider: String? = nil
    /// The installed AIs and added CLIs: read once per engine start, not per project chosen.
    @ObservationIgnored private var installed: (detected: NativeRPCValue, added: NativeRPCValue)? = nil
    /// How long a Return waits for the app and his choices (40 × 250 ms).
    static let holdSteps = 40

    init(effects: Effects) {
        self.effects = effects
        let last = NativeLandingMemory.lastStart(effects.defaults)
        remembered = last
        if let last {
            provider = last.provider; account = last.account; model = last.model
            effort = last.effort; chat = last.chat; agentID = last.agentID
            permission = last.permission.flatMap(HootPermissionMode.init(rawValue:))
            // A folder that is gone falls back to the app's own folder, silently.
            if let kept = last.folder, effects.exists(kept) {
                folder = kept
                projectID = last.projectID ?? PROJProjects.independentID
                projectName = last.projectName ?? URL(fileURLWithPath: kept).lastPathComponent
            }
        } else {
            // First run: his most recent folder (the last one the old form used), else the app's own folder.
            let lastFolder = effects.defaults.string(forKey: NativeNewSessionEffects.lastFolderKey)
                .flatMap { $0.hasPrefix("/") && effects.exists($0) ? $0 : nil }
            folder = lastFolder
            let registry = effects.projects()
            let id = PROJProjects.resolve(projectID: nil, folder: lastFolder, projects: registry)
            projectID = id
            projectName = registry.first { $0.id == id && id != PROJProjects.independentID }?.name
                ?? lastFolder.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "Independent"
        }
        text = NativeLandingMemory.draft(effects.defaults)
        hostHonoursPick = effects.hostHonoursPick()
    }

    /// Re-reads what the running session host can start.
    func refreshHost() {
        let now = effects.hostHonoursPick()
        if now != hostHonoursPick { hostHonoursPick = now }
    }

    // MARK: What the page draws

    var currentAI: AI? { ais.first { $0.id == chosenProvider } }
    /// The AI the session runs: the chosen agent's own, else the chosen AI.
    var chosenProvider: String { chosenAgent?.provider ?? provider }
    var chosenAgent: Agent? { agentID.flatMap { id in agents.first { $0.id == id } } }
    var aiName: String {
        currentAI?.name ?? (remembered?.provider == chosenProvider ? remembered?.providerName : nil) ?? NativePhoneStart.name(chosenProvider)
    }
    var canChat: Bool { currentAI?.chat ?? BackendCreateSessionInput.chatProviders.contains(chosenProvider) }
    var chatOn: Bool { chat && canChat }
    var providerAccounts: [Account] { accounts.filter { $0.provider == chosenProvider } }
    /// Several logins for this AI: the page offers the choice.
    var showsAccount: Bool { providerAccounts.count > 1 }
    var effectiveAccount: String? { account ?? currentAI?.defaultAccount }
    var accountName: String {
        providerAccounts.first { $0.id == effectiveAccount }?.name
            ?? (remembered?.account == effectiveAccount ? remembered?.accountName : nil) ?? "Default account"
    }
    /// The AI's models; his chosen one is always among them, even when the list does not carry it (Owner, 14 Nov:
    /// his last settings are selected, the model included).
    /// LANDING-FIX-4: an agent that brings its own model or effort runs with them (`session:start-agent` takes no
    /// model or effort): the page shows them, not changeable (`agentRuns`). An agent that leaves them open in a Chat
    /// gets the normal choices, applied right after it starts (`session:chat:options`, as a plain chat). In Terminal
    /// nothing can carry a choice to an agent's start, so the page names what it will run with instead.
    var agentBrings: Bool { chosenAgent.map { $0.model != nil || $0.effort != nil } ?? false }
    var choicesOpen: Bool { chosenAgent == nil || (!agentBrings && chatOn) }
    /// What a chosen agent will run with when the choices are not open: "Opus · High" (set by the agent), or
    /// "Fable 5.2 · Extra" (the AI's default, in Terminal). Nil when the normal choices show.
    var agentRuns: String? {
        guard let agent = chosenAgent, !choicesOpen else { return nil }
        let modelPart = (agent.model ?? currentAI?.defaultModel).map { id in currentAI?.models.first { $0.id == id }?.name ?? NativeLandingModels.name(id) }
        let effortPart = (agent.effort ?? currentAI?.defaultEffort).map(HootComposerModel.effortName)
        // LANDING-FIX-6: just the facts, no name inside the line (the agent's own chip sits beside it); who set them is
        // the help text and the accessibility label (`agentRunsHelp`).
        let facts = [modelPart, effortPart].compactMap { $0 }
        return facts.isEmpty ? unknownDefault : facts.joined(separator: " \u{00B7} ")
    }
    /// Who set what the quiet line shows: "Set by Decker", or "Claude's default for this session".
    var agentRunsHelp: String? {
        guard let agent = chosenAgent, agentRuns != nil else { return nil }
        return agentBrings ? "Set by " + agent.name : aiName + "'s default for this session"
    }
    var models: [Choice] {
        guard choicesOpen else { return [] }
        var list = currentAI?.models ?? []
        if let model, chosenProvider == provider, !list.contains(where: { $0.id == model }) {
            list.append(Choice(id: model, name: (remembered?.model == model ? remembered?.modelName : nil) ?? NativeLandingModels.name(model)))
        }
        return list
    }
    /// Shown for every AI that has models or names its default (Shell and an added CLI have neither).
    var showsModel: Bool { choicesOpen && (!models.isEmpty || defaultModelName != nil) }
    /// The model the AI runs when none is chosen, named ("Opus 5.5"); nil when it does not say.
    var defaultModelName: String? {
        guard choicesOpen, let id = currentAI?.defaultModel else { return nil }
        return currentAI?.models.first { $0.id == id }?.name ?? NativeLandingModels.name(id)
    }
    /// The model that will really be used: his choice, else the AI's own default by name.
    var modelName: String {
        guard let model else { return defaultModelName ?? unknownDefault }
        return models.first { $0.id == model }?.name ?? model
    }
    /// The menu's "no choice" row names what that means: "Opus 5.5 (default)".
    var defaultModelLabel: String { defaultModelName.map { $0 + " (default)" } ?? unknownDefault }
    /// LANDING-FIX-3: when the AI does not say which model it runs, the page says whose default it is ("Claude's
    /// default"), never a bare "Default model".
    var unknownDefault: String { aiName + "'s default" }
    var efforts: [String] { choicesOpen ? currentAI?.efforts ?? [] : [] }
    var showsEffort: Bool { choicesOpen && (!efforts.isEmpty || (!loaded && effort != nil)) }
    var defaultEffortName: String? { choicesOpen ? currentAI?.defaultEffort.map(HootComposerModel.effortName) : nil }
    var effortName: String { effort.map(HootComposerModel.effortName) ?? defaultEffortName ?? "Default effort" }
    var defaultEffortLabel: String { defaultEffortName.map { $0 + " (default)" } ?? "Default effort" }
    var agentName: String {
        chosenAgent?.name ?? (remembered?.agentID == agentID && agentID != nil ? remembered?.agentName : nil) ?? "No agent"
    }
    var showsAgent: Bool { !agents.isEmpty || (!loaded && agentID != nil) }
    var registeredProjects: [PROJProject] { effects.projects().filter { $0.id != PROJProjects.independentID } }
    var project: PROJProject? { effects.projects().first { $0.id == projectID && $0.id != PROJProjects.independentID } }
    /// The send arrow is active only when a send would really go (words in the box; a file alone is not enough).
    var canSend: Bool { !sending && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    /// The same rule for the box as it is at the press (the composer asks at Return or the arrow, not at its last draw).
    func canSend(with draft: HootComposerDraft) -> Bool {
        !sending && !draft.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    /// In Chat, the open chat's own limits for files from "+" (`ChatAttachmentLimits`, the same checks); a terminal
    /// takes any file as its path.
    var attachmentLimits: ChatAttachmentLimits? { chatOn ? ChatAttachmentLimits(provider: chosenProvider) : nil }

    // MARK: The chat window's own box and the line under it (HootComposer), as on an open chat

    /// What shows is what starts: a chosen agent's own mode until he picks one, else his pick, else the app's own
    /// start for new sessions (Bypass). Nil: this AI has no modes (Shell, an added CLI).
    /// An older running session host starts every new session in Bypass (R73, an agent's too): then Bypass shows, as
    /// plain words, and his remembered stricter pick stays stored for later, not shown as active.
    var startPermission: HootPermissionMode? {
        guard hasPermissionModes else { return nil }
        guard hostHonoursPick else { return .bypass }
        if !pickedForAgent, let own = agentPermission { return own }
        return permission ?? .bypass
    }
    /// The line under the box can offer a choice (a host that starts in it); else it only says what starts, and why.
    var permissionFixedHelp: String? {
        guard hasPermissionModes, !hostHonoursPick else { return nil }
        return "New sessions start with Bypass permissions on this Mac's session helper. Change it in the chat after your first message."
    }
    /// The pick goes to the start as his explicit choice only when the running host starts in it.
    var sendsChosenStart: Bool { hostHonoursPick && hasPermissionModes }
    /// The chosen agent's own mode, as the line under the box names it.
    var agentPermission: HootPermissionMode? {
        guard let cli = chosenAgent?.permission, let ai = HootChatProvider(rawValue: chosenProvider),
              let mode = BackendHOOTSIMPermissionMode.allCases.first(where: { $0.cliMode(provider: ai) == cli }) else { return nil }
        return HootPermissionMode(rawValue: mode.rawValue)
    }
    /// The mode the line under the box shows.
    var shownPermission: HootPermissionMode { startPermission ?? .ask }
    /// The mode he sees, as this AI's own value for its start; nil for an AI with no modes. Throws when the mode has no
    /// value for this AI: the session does not start (never Bypass in its place).
    func startPermissionValue() throws -> String? {
        guard let mode = startPermission else { return nil }
        guard let ai = HootChatProvider(rawValue: chosenProvider),
              let cli = BackendHOOTSIMPermissionMode(rawValue: mode.rawValue)?.cliMode(provider: ai),
              AGSCapabilities.permissionModes(provider: chosenProvider).contains(cli) else {
            throw NativeRPCError(code: "invalid-arguments", message: "\(aiName) cannot start in \u{201C}\(mode.short)\u{201D}. Choose another \u{201C}Before it changes files\u{201D} under the box. Your message is kept here.")
        }
        return cli
    }
    /// The modes the chosen AI really has, in the composer's order (the permission pill's menu).
    var permissionModes: [HootPermissionMode] { NewSessionPermissionModes.modes(provider: chosenProvider) }
    /// A plain shell or an added CLI has no "Before it changes files" mode.
    var hasPermissionModes: Bool { BackendTAGLaunchArguments.newSessionPermission(provider: chosenProvider) != nil }
    /// The box as the shared composer reads it. Model ids are written "<ai>:<model>" as an open chat writes them;
    /// "<ai>:" is the AI's own default when that model is not in its list.
    var composerDraft: HootComposerDraft {
        var draft = HootComposerDraft()
        draft.text = text
        draft.attachments = attachments
        draft.permissionMode = shownPermission
        let ai = chosenProvider
        if let model { draft.modelID = ai + ":" + model }
        else if let id = currentAI?.defaultModel, models.contains(where: { $0.id == id }) { draft.modelID = ai + ":" + id }
        else { draft.modelID = ai + ":" }
        draft.effort = efforts.isEmpty ? "" : effort ?? currentAI?.defaultEffort ?? "default"
        return draft
    }
    /// What he typed or added in the box (permission, model and effort arrive through their own callbacks).
    func takeFromBox(_ draft: HootComposerDraft) {
        if text != draft.text { text = draft.text }
        if attachments != draft.attachments { attachments = draft.attachments }
    }
    /// The line under the box: this AI's models, its default first when the list does not name it, and its efforts.
    /// Empty while a chosen agent brings its own (the line then says what will run: `agentRuns`).
    var composerCatalogue: HootComposerCatalogue {
        var catalogue = HootComposerCatalogue()
        guard choicesOpen else { return catalogue }
        let ai = chosenProvider
        var rows = models.map { HootComposerModel(id: ai + ":" + $0.id, provider: ai, name: $0.name) }
        let defaultListed = currentAI?.defaultModel.map { id in models.contains { $0.id == id } } ?? false
        if showsModel, !defaultListed { rows.insert(HootComposerModel(id: ai + ":", provider: ai, name: defaultModelName ?? unknownDefault), at: 0) }
        if !rows.isEmpty { catalogue.sections = [HootModelSection(id: ai, name: aiName, featured: rows)] }
        catalogue.efforts = efforts
        return catalogue
    }
    /// A model picked in the line under the box ("<ai>:<model>"; "<ai>:" is the AI's own default).
    func chooseComposerModel(_ id: String) {
        let picked = id.firstIndex(of: ":").map { String(id[id.index(after: $0)...]) } ?? id
        chooseModel(picked.isEmpty ? nil : picked)
    }
    /// Return or the send arrow in the box.
    func sendFromBox(_ draft: HootComposerDraft) {
        takeFromBox(draft)
        send()
    }

    // MARK: Choosing (nothing leaves this page until he sends)

    func chooseProject(_ chosen: PROJProject) {
        projectID = chosen.id
        projectName = chosen.id == PROJProjects.independentID ? "Independent" : chosen.name
        if chosen.id == PROJProjects.independentID { folder = nil }
        else if !chosen.folders.contains(where: { TaskProjects.within(folder ?? "", $0) }) { folder = chosen.folders.first }
        agentID = nil
        reload(pickLead: true)
    }
    func chooseFolder(_ path: String) {
        folder = path
        let registry = effects.projects()
        let id = PROJProjects.resolve(projectID: nil, folder: path, projects: registry)
        projectID = id
        projectName = registry.first { $0.id == id && id != PROJProjects.independentID }?.name ?? URL(fileURLWithPath: path).lastPathComponent
        agentID = nil
        reload(pickLead: true)
    }
    func browse() {
        Task { if let path = await effects.browse() { chooseFolder(path) } }
    }
    func chooseAI(_ id: String) {
        agentID = nil
        guard id != provider else { return }
        provider = id; model = nil; effort = nil
        if let picked = account, accounts.first(where: { $0.id == picked })?.provider != id { account = nil }
    }
    func chooseAccount(_ id: String) { account = id }
    /// A row of the account chip's list. Another account of the same AI keeps the chosen agent (10 Nov: the account
    /// picked here wins over the agent's own); only another AI's account changes the AI (and so drops the agent).
    func pickAccount(_ id: String, of ai: String) {
        if ai != chosenProvider { chooseAI(ai) }
        chooseAccount(id)
    }
    func chooseModel(_ id: String?) { model = id }
    func chooseEffort(_ id: String?) { effort = id }
    func chooseChat(_ on: Bool) { chat = on }
    func choosePermission(_ mode: HootPermissionMode) { permission = mode; pickedForAgent = true }
    func chooseAgent(_ id: String?) { agentID = id; agentEpoch += 1 }

    /// A door that names a folder or project (a project's New session, Open folder…).
    func prefill(folder path: String?, project chosen: PROJProject?) {
        if let chosen { chooseProject(chosen) }
        else if let path { chooseFolder(path) }
    }

    /// A tool's new-session: only while he is not on the page and has nothing in its box.
    func prepareForTool(folder path: String?, onScreen: Bool) {
        guard !onScreen, text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let path, path.hasPrefix("/") else { return }
        chooseFolder(path)
    }

    /// No project: the app's own folder (a remembered folder that is gone comes here too).
    private func useOwnFolder() {
        folder = nil; projectID = PROJProjects.independentID; projectName = "Independent"
    }

    // MARK: Lists

    func engineReady() {
        refreshHost()
        NativePROJLabels.shared.start()
        installed = nil
        reload(pickLead: false)
    }

    func reload(pickLead: Bool) {
        loadTicket += 1
        let mine = loadTicket
        let wanted = folder, epoch = agentEpoch
        loaded = false
        refreshHost()
        Task {
            guard effects.ready() else { return }
            loading = true
            defer { if mine == loadTicket { loading = false } }
            let value = await effects.choices(wanted)
            let lists: (detected: NativeRPCValue, added: NativeRPCValue)
            if let installed { lists = installed } else {
                lists = ((try? await effects.invoke("providers:detect", [])) ?? .null, (try? await effects.invoke("agents:list", [])) ?? .null)
                installed = lists
            }
            let recent = remembered == nil && !loadedOnce ? ((try? await effects.invoke("projects:list", [])) ?? .null) : .null
            guard mine == loadTicket else { return }
            apply(value, detected: lists.detected, added: lists.added, recent: recent, pickLead: pickLead && epoch == agentEpoch)
        }
    }
    @ObservationIgnored private var loadedOnce = false

    func apply(_ value: NativeRPCValue, detected: NativeRPCValue, added: NativeRPCValue, recent: NativeRPCValue = .null, pickLead: Bool) {
        var byID: [String: AI] = [:]
        for row in value["providers"].elements ?? [] {
            guard let id = row["id"].string else { continue }
            byID[id] = AI(id: id, name: row["name"].string ?? NativePhoneStart.name(id), chat: row["chat"].bool == true,
                          models: (row["models"].elements ?? []).compactMap { model in
                              model["id"].string.map { Choice(id: $0, name: model["name"].string ?? $0) } },
                          efforts: (row["efforts"].elements ?? []).compactMap(\.string),
                          defaultAccount: row["defaultAccount"].string,
                          defaultModel: row["defaultModel"].string, defaultEffort: row["defaultEffort"].string)
        }
        // Every AI this Mac can start, the CLIs he added included (the phone's list leaves those out).
        let rows = NewSessionProviders.rows(detected: CodingAIJSON(detected.foundation),
                                            added: NewSessionCustomAgent.parse(CodingAIJSON(added.foundation)))
        var list: [AI] = []
        for row in rows where row.available && !list.contains(where: { $0.id == row.id }) {
            list.append(byID[row.id] ?? AI(id: row.id, name: row.isCustom ? row.label : NativePhoneStart.name(row.id), chat: false))
        }
        for (id, ai) in byID.sorted(by: { $0.key < $1.key }) where !list.contains(where: { $0.id == id }) { list.append(ai) }
        ais = list
        accounts = (value["accounts"].elements ?? []).compactMap { row in
            guard let id = row["id"].string else { return nil }
            return Account(id: id, name: row["name"].string ?? id, provider: row["provider"].string ?? "claude",
                           email: row["email"].string, state: row["state"].string.flatMap(Account.State.init(rawValue:)) ?? .unknown)
        }
        agents = (value["agents"].elements ?? []).compactMap { row in
            guard let id = row["id"].string else { return nil }
            return Agent(id: id, name: row["name"].string ?? id, provider: row["provider"].string ?? "claude", lead: row["lead"].bool == true,
                         model: NativeLandingModels.usable(row["model"].string), effort: NativeLandingModels.usable(row["effort"].string),
                         permission: row["permissionMode"].string.flatMap { $0.isEmpty ? nil : $0 })
        }
        defaultProvider = value["defaultProvider"].string
        // A folder deleted since: the app's own folder instead, silently.
        if let kept = folder, !effects.exists(kept) { useOwnFolder() }
        if remembered == nil && !loadedOnce {
            // First run: the default AI and Chat or Terminal as last chosen; his most recent folder when none is known.
            loadedOnce = true
            if let preferred = defaultProvider, ais.contains(where: { $0.id == preferred }) { provider = preferred }
            chat = value["openAs"].string != "terminal"
            if folder == nil, let first = NewSessionProjects.parse(CodingAIJSON(recent.foundation)).map(\.path)
                .first(where: { $0.hasPrefix("/") && effects.exists($0) }) {
                chooseFolder(first)
                return
            }
        }
        loadedOnce = true
        if !ais.contains(where: { $0.id == provider }), let first = defaultProvider.flatMap({ id in ais.first { $0.id == id } }) ?? ais.first {
            provider = first.id; model = nil; effort = nil
        }
        if pickLead { agentID = agents.first(where: \.lead)?.id }
        else if let id = agentID, !agents.contains(where: { $0.id == id }) { agentID = nil }
        // His remembered model stays chosen even when the list does not carry it (an alias such as "opus", or a list
        // read from another source): it is what he last started with, and the CLI takes it.
        if let effort, let ai = currentAI, !ai.efforts.contains(effort) { self.effort = nil }
        if let account, !accounts.contains(where: { $0.id == account }) { self.account = nil }
        loaded = true
    }

    // MARK: Send: the only moment anything is made

    func send() {
        guard canSend else { return }
        Task { await sendNow() }
    }

    /// His Return is held until the app is up and his choices are checked against the lists (a few seconds at most);
    /// the box stays typeable meanwhile.
    private func waitForChoices() async -> Bool {
        for _ in 0..<Self.holdSteps {
            if effects.ready() && loaded { return true }
            if effects.ready() && !loading { reload(pickLead: false) }
            await effects.pause()
        }
        return effects.ready() && loaded
    }

    func sendNow() async {
        let sent = text
        let files = attachments
        let message = sent.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sending, !message.isEmpty else { return }
        sending = true; problem = nil
        defer { sending = false }
        guard await waitForChoices() else {
            problem = "Terminal Deck is still getting ready. Your message is kept here: press Return again in a moment."
            return
        }
        // Chat: the files from "+" pass the open chat's own checks first (same limits, same words), before anything is
        // made; one it cannot take stops the send with the chat's own line, and nothing is sent without it.
        var blocks: [NativeRPCValue] = []
        if let limits = attachmentLimits, !files.isEmpty {
            do {
                try limits.validateFiles(files.map(\.url))
                blocks = try files.map { try NativeHOOTSIMFeedback.attachment(url: $0.url) }
                try limits.validate(blocks)
            } catch {
                problem = error.localizedDescription
                return
            }
        }
        let created: (id: String, meta: [String: Any], cwd: String, held: Bool)
        do { created = try await create() }
        catch {
            problem = (error as? NativeRPCError)?.message ?? error.localizedDescription
            return
        }
        // Only what was sent leaves the box: anything he typed after Return stays.
        if text.hasPrefix(sent) { text = String(text.dropFirst(sent.count).drop(while: { $0.isNewline })) }
        attachments.removeAll { files.contains($0) }
        remember()
        // In the side panel at once; the window goes to it only if he is still on this page waiting for it.
        effects.addQuietly(created.meta)
        if effects.onScreen() { effects.show(created.id) }
        let asChat = chatOn
        if asChat && created.held {
            // His model or effort did not go on: the message waits in that chat's own box, never sent without them.
            _ = try? await effects.invoke("session:chat:draft", [.string(created.id), .string(message)])
        } else if asChat {
            // Files from the box's "+" go as the chat sends them (the same blocks an open chat's say carries).
            let say: [NativeRPCValue] = blocks.isEmpty ? [.string(created.id), .string(message)] : [.string(created.id), .string(message), .array(blocks)]
            do { _ = try await effects.invoke("session:chat:say", say) }
            catch {
                // Never lost: the message waits in that chat's own box.
                _ = try? await effects.invoke("session:chat:draft", [.string(created.id), .string(message)])
            }
        } else {
            // A terminal takes files as their paths, typed after the words, each one a single quoted argument.
            let typed = files.isEmpty ? message : message + " " + files.map { Self.shellQuoted($0.url.path) }.joined(separator: " ")
            effects.typeWhenReady(created.id, chosenProvider, typed)
        }
        if folder != nil { _ = try? await effects.invoke("projects:add", [.string(created.cwd)]) }
        if canChat { _ = try? await effects.invoke("prefs:set", [.object([.init(NewSessionChatMode.preference, .string(asChat ? "chat" : "terminal"))])]) }
    }

    /// A path typed into a terminal as ONE argument the shell never reads as a command: always in single quotes, a
    /// quote inside written `'\''` (`a;b.txt`, `$(…)`, backticks and `"` stay plain characters).
    nonisolated static func shellQuoted(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// The session, with the choices as they stand (checked: folder exists, agent, model and account in the lists).
    /// `held`: a chat whose model or effort did not go on; its first message is not sent.
    private func create() async throws -> (id: String, meta: [String: Any], cwd: String, held: Bool) {
        if let kept = folder, !effects.exists(kept) { useOwnFolder() }
        // "Before it changes files": the session STARTS in the mode the line under the box shows (Chat and Terminal,
        // a plain AI and an agent alike), as this AI's own value, passed as his explicit pick. A mode with no value
        // for this AI stops here: nothing is made, and it never falls back to Bypass.
        // What the running host can start is read again now. If it changed under the page (a reconnect to an older
        // helper) and the page showed a stricter mode than would start, nothing starts: the line now says Bypass.
        let shown = startPermission
        refreshHost()
        if let shown, shown != .bypass, startPermission != shown {
            throw NativeRPCError(code: "unavailable", message: "This Mac's session helper changed and starts new sessions with Bypass permissions now. Your message is kept here: press Return again to start it that way.")
        }
        let startMode = try startPermissionValue()
        let explicit = sendsChosenStart && startMode != nil
        let cwd = try folder ?? effects.defaultFolder()
        let identity = folder == nil ? PROJProjects.independentID : projectID
        let asChat = chatOn
        // An account of another AI (an agent of that AI was chosen after it) is not sent: the agent's own is used.
        let pickedAccount = account.flatMap { id in accounts.first { $0.id == id }?.provider == chosenProvider ? id : nil }
        let created: NativeRPCValue
        if let agent = chosenAgent {
            created = try await effects.invoke("session:start-agent", [.string(agent.id), .string(identity), .string(cwd), .bool(asChat),
                startMode.map(NativeRPCValue.string) ?? .null, pickedAccount.map(NativeRPCValue.string) ?? .null, .bool(explicit)])
        } else {
            var input = NativeRPCValue.object([.init("cwd", .string(cwd)), .init("projectId", .string(identity)),
                .init("provider", .string(provider)), .init("resume", .bool(false)),
                .init("profileId", pickedAccount.map(NativeRPCValue.string) ?? .null),
                .init("cols", .number(Double(NewSessionStart.cols))), .init("rows", .number(Double(NewSessionStart.rows))),
                .init("chat", .bool(asChat))])
            if let startMode { input = input.setting("permissionMode", .string(startMode)) }
            if explicit, let startMode { input = input.setting("chosenStartPermission", .string(startMode)) }
            if let model { input = input.setting("model", .string(model)) }
            if let effort { input = input.setting("effort", .string(effort)) }
            created = try await effects.invoke("session:create", [input])
        }
        guard let id = created["id"].string, !id.isEmpty, let meta = created.foundation as? [String: Any] else {
            throw NativeRPCError(code: "unavailable", message: "The session did not start. Your message is kept here.")
        }
        // A plain chat, or an agent's chat that leaves model and effort open: his model and effort go on right after the
        // start (the mode already started with the session). If that fails, the first message is held, never sent.
        let chosenModel = model.flatMap { chosenProvider == provider ? $0 : nil }
        let chosenEffort = effort.flatMap { efforts.contains($0) ? $0 : nil }
        var held = false
        if asChat, choicesOpen, chosenModel != nil || chosenEffort != nil {
            var options = NativeRPCValue.object([])
            if let chosenModel { options = options.setting("model", .string(chosenProvider + ":" + chosenModel)) }
            if let chosenEffort { options = options.setting("effort", .string(chosenEffort)) }
            do { _ = try await effects.invoke("session:chat:options", [.string(id), options]) }
            catch { held = true }
        }
        return (id, meta, cwd, held)
    }

    /// A Terminal first message the AI never got ready for: back in the box, after whatever he has typed since.
    func giveBack(_ unsent: String) {
        let mine = text.trimmingCharacters(in: .whitespacesAndNewlines)
        text = mine.isEmpty ? unsent : text + "\n\n" + unsent
        problem = "Your first message was not sent: the AI did not get ready. It is back in the box."
    }

    /// Only a checked, whole start is remembered (send waits for the lists first).
    private func remember() {
        guard loaded else { return }
        let start = NativeLastStart(folder: folder, projectID: folder == nil ? PROJProjects.independentID : projectID,
            projectName: projectName, provider: provider, providerName: ais.first { $0.id == provider }?.name,
            account: account, accountName: account == nil ? nil : accountName, model: model, modelName: model == nil ? nil : modelName,
            effort: effort, chat: chat, agentID: agentID, agentName: chosenAgent?.name, permission: permission?.rawValue)
        NativeLandingMemory.remember(start, effects.defaults)
        if let folder { effects.defaults.set(folder, forKey: NativeNewSessionEffects.lastFolderKey) }
    }
}

/// A Terminal session's first message is typed ONLY at the AI's own prompt: never at the blank start, never at a shell
/// prompt, never into a question, a sign-in or a folder-trust screen. After two minutes it goes back to the page's box.
@MainActor
enum NativeLandingTerminal {
    enum Step: Equatable { case wait, type }

    /// Whether this screen is the AI's own empty prompt (a plain Shell: its own prompt).
    nonisolated static func step(provider: String, status: TerminalStatus?, screen: String) -> Step {
        guard status == .waiting, BackendSessionClassifier.classify(viewport: screen) == .waiting else { return .wait }
        if provider == "shell" { return .type }
        guard case .ready = BackendTaskBriefDelivery.composer(screen), BackendTaskBriefDelivery.setupScreen(screen) == nil else { return .wait }
        let words = screen.lowercased()
        switch provider {
        case "claude": return words.contains("claude") || words.contains("? for shortcuts") ? .type : .wait
        case "codex": return words.contains("codex") ? .type : .wait
        case "gemini": return words.contains("gemini") ? .type : .wait
        default: return .type // an added CLI: its own empty prompt, no shell prompt, no question
        }
    }

    /// Waits for the AI's prompt, types the text, waits briefly for it to show, then presses Return. False: never typed.
    static func deliver(provider: String, text: String, read: @MainActor () -> (status: TerminalStatus?, screen: String),
                        type: @MainActor (String) -> Void, submit: @MainActor () -> Void,
                        pause: @MainActor () async -> Void, attempts: Int = 480) async -> Bool {
        for _ in 0..<attempts {
            let now = read()
            if now.status == .exited { return false }
            if step(provider: provider, status: now.status, screen: now.screen) == .type {
                type(text)
                for _ in 0..<12 {
                    await pause()
                    if let shown = BackendTaskBriefDelivery.promptText(read().screen), BackendTaskBriefDelivery.echoes(shown, line: text) { break }
                }
                submit()
                return true
            }
            await pause()
        }
        return false
    }

    static func typeWhenReady(_ id: String, provider: String, _ text: String) {
        Task {
            let session = NativeTerminalSessions.shared.session(for: id)
            let typed = await deliver(provider: provider, text: text,
                read: { (session.status, viewport(session.terminal.getTerminal())) },
                type: { session.type(paste: $0) },
                submit: { EngineBridge.shared.send("session:write", [id, "\r"]) },
                pause: { try? await Task.sleep(for: .milliseconds(250)) })
            guard !typed else { return }
            NativeLanding.model.giveBack(text)
            session.say("Your first message was not sent: the AI did not get ready. It is back on the New session page.")
        }
    }

    static func viewport(_ terminal: Terminal) -> String {
        (0..<terminal.getDims().rows).compactMap { terminal.getLine(row: $0)?.translateToString(trimRight: true) }.joined(separator: "\n")
    }
}

extension NativeLastStart {
    /// The full form's start, remembered the same way (it is the person's own start on this Mac too).
    @MainActor static func fromForm(cwd: String, projectID: String, projectName: String, provider: String, account: String?,
                                    model: String?, chat: Bool, agentID: String?, agentName: String?) -> NativeLastStart {
        NativeLastStart(folder: cwd, projectID: projectID, projectName: projectName, provider: provider,
                        providerName: NativePhoneStart.name(provider), account: account, accountName: nil, model: model,
                        modelName: nil, effort: nil, chat: chat, agentID: agentID, agentName: agentName)
    }
}
