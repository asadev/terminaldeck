import AppKit
import Observation
import SwiftUI
import TerminalDeckBackend
import TerminalDeckNativeCore

// The New session dialog, drawn in Swift — a port of `NewSessionDialog.tsx`
// (with `AddAgentForm.tsx` for "Add a CLI"), same sections in the same order:
// the error and what the resolver changed, Where (only with other machines or
// servers), Project / Folder on <machine> / Folder on <server>, Agent (with
// Add a CLI), Login (with Make default), Remember; footer ⌘↩ to start, Cancel,
// Start session / Open a terminal.
//
// Native project buttons use show(project:) and the existing Swift channels.
// The older page message remains an adapter for older entry points.

/// All side effects are explicit, so model tests never need an app, window or AI.
@MainActor
struct NativeNewSessionEffects {
    enum Mode { case live, fixture }
    var mode: Mode = .fixture
    var invoke: @MainActor (String, [Any?]) async throws -> Any = { _, _ in
        throw NativeNewSessionFailure("Fixture transport is unavailable.")
    }
    var readMemory: @MainActor () -> String? = { nil }
    var readLastFolder: @MainActor () -> String? = { nil }
    var writeMemory: @MainActor (String) throws -> Void = { _ in }
    var writeLastFolder: @MainActor (String) throws -> Void = { _ in }
    var openedLocal: @MainActor ([String: Any]) -> Void = { _ in }
    /// A supplied remote handler must retain projectID and wait for actual creation.
    var startMachine: (@MainActor (String, NewSessionRequest, String) async throws -> String)?
    var openedMachine: (@MainActor (String, String, String) -> Void)?
    var openedServer: (@MainActor (String, String, String, String?, String) -> Void)?
    var captureShell: @MainActor () -> NativeButtonShellCapture? = { nil }
    var shellOutput: @MainActor (String, String) -> Void = { _, _ in }
    var dismiss: @MainActor () -> Void = {}
    var closed: @MainActor () -> Void = {}
    var removedProject: @MainActor (String, [String]) -> Void = { _, _ in }

    // These are the existing renderer keys, with the same bounded per-folder map.
    static let memoryKey = "session-start.defaults.v1"
    /// Also read off the main actor, by a paired phone's New session lists (NativePhoneStart.choices).
    nonisolated static let lastFolderKey = "session-start.lastFolder.v1"
    static var live: Self {
        Self(mode: .live, invoke: { channel, args in
            try await EngineBridge.shared.invoke(channel, args, timeout: 10)
        }, readMemory: { UserDefaults.standard.string(forKey: memoryKey) },
        readLastFolder: { UserDefaults.standard.string(forKey: lastFolderKey) },
        writeMemory: { UserDefaults.standard.set($0, forKey: memoryKey) },
        writeLastFolder: { UserDefaults.standard.set($0, forKey: lastFolderKey) },
        openedLocal: { meta in
            AppModel.shared.buttonActions.created(meta)
            if let id = meta["id"] as? String { AppModel.shared.selectTab(id) }
        }, startMachine: { machine, request, project in
            guard project == PROJProjects.independentID else {
                throw NativeNewSessionFailure("That machine cannot retain the selected project yet. Nothing was started.")
            }
            return try await NativeMachineSessionStart.create(machine: machine, folder: request.cwd, provider: request.provider, created: { row in
                AppModel.shared.buttonActions.machineCreated(machine: machine, session: row.id, title: row.title)
            })
        }, openedMachine: { machine, session, _ in
            AppModel.shared.buttonActions.machineCreated(machine: machine, session: session)
        }, openedServer: { server, name, shell, folder, _ in
            _ = AppModel.shared.buttonActions.adoptServer(server, name: name, shell: shell, folder: folder)
        }, captureShell: { NativeButtonShellCapture() }, shellOutput: { shell, text in
            guard let tab = AppModel.shared.buttonActions.tabs.tabs.first(where: { $0.server?.shellId == shell })?.id else { return }
            let terminal = NativeTerminalSessions.shared.session(for: tab)
            if !text.isEmpty { terminal.terminal.feed(text: text) }
        }, dismiss: { NativeNewSession.close() }, removedProject: { path, ids in
            AppModel.shared.buttonActions.projectRemoved(path, sessions: ids)
        })
    }
}

private struct NativeNewSessionFailure: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// Opens and closes the dialog for the page's `new-session` message.
@MainActor
enum NativeNewSession {
    private static var sheet: NSWindow?
    private static var model: NativeNewSessionModel?
    private static var parentClosing: NSObjectProtocol?

    /// Called by a person pressing New session on a project's page. Fixtures never call this presenter.
    static func show(project: PROJProject?) {
        try? open(project: project)
    }

    /// The one door for a person's New session (the sidebar's "+", a project's page, Open folder…,
    /// the tools): always on the main window, starting where `startFolder` says. A form that is
    /// still on screen is brought forward and kept, never replaced or stacked (#620).
    static func open(folder: String? = nil, project: PROJProject? = nil) throws {
        if sheet?.sheetParent == nil { close() }
        guard sheet?.sheetParent != nil || NativeButtonPresentation.sessionParent != nil else {
            throw NativeRPCError(code: "no-window", message: "Open the main window before starting a session.")
        }
        NativeFront.whenPersonActs("new-session") {
            if let sheet, let shown = sheet.sheetParent {
                shown.makeKeyAndOrderFront(nil)
                return
            }
            close()
            guard let parent = NativeButtonPresentation.sessionParent else {
                NativeCompositionRoot.note("New session was not opened because its main window closed.")
                return
            }
            let effects = NativeNewSessionEffects.live
            let machine = folder?.hasPrefix("machine:") == true ? String(folder!.dropFirst(8)) : nil
            let path = machine == nil ? startFolder(folder, project: project, current: DeckProject.current, last: effects.readLastFolder()) : nil
            let context = NewSessionContext(seq: Int(Date().timeIntervalSince1970 * 1_000), projectPath: path, machineId: machine,
                                            memory: effects.readMemory())
            let projectID = project?.id ?? NativePROJLabels.shared.projects.first { $0.folders.contains(path ?? "") }?.id
            parent.makeKeyAndOrderFront(nil)
            present(NativeNewSessionModel(context: context, projectID: projectID, effects: effects), parent: parent)
        }
    }

    /// Where a new session starts: the asked-for folder, else the project's first folder (none for
    /// independent sessions), else the open project, else the last folder used.
    static func startFolder(_ folder: String?, project: PROJProject?, current: String?, last: String?) -> String? {
        if let folder { return folder }
        if let project { return project.id == PROJProjects.independentID ? nil : project.folders.first }
        if let current, !current.isEmpty { return current }
        let remembered = last?.trimmingCharacters(in: .whitespacesAndNewlines)
        return remembered.flatMap { $0.hasPrefix("/") ? $0 : nil }
    }

    /// True when `body` was the dialog's message (WebBridge.receive's lane B line).
    static func accept(_ body: Any, from bridge: WebBridge) -> Bool {
        guard let context = NewSessionContext.parse(body) else { return false }
        show(context, bridge: bridge)
        return true
    }

    private static func show(_ context: NewSessionContext, bridge: WebBridge) {
        if let model, let sheet, sheet.isVisible || sheet.sheetParent != nil {
            // The same opening again (the servers arriving late) only updates it.
            if model.context.seq == context.seq {
                model.update(context)
                return
            }
            close()
        }
        guard let parent = bridge.webView.window else { return }
        let made = NativeNewSessionModel(context: context, bridge: bridge)
        present(made, parent: parent)
    }

    static func present(_ made: NativeNewSessionModel, parent: NSWindow) {
        NativeFront.whenPersonActs("new-session") {
            let host = NSHostingController(rootView: NativeNewSessionDialog(model: made))
            host.sizingOptions = [.preferredContentSize]
            let window = NSWindow(contentViewController: host)
            window.styleMask = [.titled]
            window.title = "New session"
            made.window = window
            model = made
            sheet = window
            parent.beginSheet(window)
            // The window under the form can close by itself (a pop-out whose session ended): forget the
            // form with it, or the sidebar's "+" would think it is still open (#106).
            if let parentClosing { NotificationCenter.default.removeObserver(parentClosing) }
            parentClosing = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: parent, queue: .main) { _ in
                MainActor.assumeIsolated { if sheet === window { close() } }
            }
            made.load()
        }
    }

    static var isOpen: Bool { model != nil }
    static func submitForTool() async throws {
        guard let model, model.canStart else { throw NativeNewSessionFailure("Open the new session form and choose its folder first.") }
        await model.submitNative()
        if let error = model.error { throw NativeRPCError(code: "refused", message: error) }
    }
    static func cancelForTool() throws {
        guard let model else { throw NativeNewSessionFailure("The new session form is not open.") }
        guard !model.starting else { throw NativeNewSessionFailure("The session is still starting. Wait for it to finish.") }
        model.cancel()
    }

    static func close() {
        if let parentClosing { NotificationCenter.default.removeObserver(parentClosing); self.parentClosing = nil }
        guard let sheet else { return }
        sheet.sheetParent?.endSheet(sheet)
        sheet.orderOut(nil)
        self.sheet = nil
        model = nil
    }
}

@MainActor
@Observable
final class NativeNewSessionModel {
    private(set) var context: NewSessionContext
    @ObservationIgnored weak var window: NSWindow?
    @ObservationIgnored private weak var bridge: WebBridge?
    @ObservationIgnored private let effects: NativeNewSessionEffects

    // Choices
    var selectedPath: String?
    var selectedProjectID: String?
    private var fixtureProjects: [PROJProject]?
    private var fixtureProviders: [NewSessionProviderRow]?
    var registeredProjects: [PROJProject] { fixtureProjects ?? NativePROJLabels.shared.projects }
    var projectLoadError: String? { fixtureProjects == nil ? NativePROJLabels.shared.error : nil }
    var isRenderFixture: Bool { effects.mode == .fixture }
    var selectedMachine: String?
    var selectedServer: String?
    var serverPath: String?
    var chosenProvider: String?
    var chosenProfileId: String?
    var chosenModelId: String?
    struct ModelChoice: Identifiable { let id: String; let name: String }
    private(set) var modelCatalog: [String: [ModelChoice]] = [:]
    private(set) var modelsLoading = false
    var modelChoices: [ModelChoice] { modelCatalog[chosenAgent?.provider ?? decided?.provider ?? ""] ?? [] }
    var canChooseModel: Bool { chosenAgent == nil && (chatMode || decided?.provider == "claude") && !modelChoices.isEmpty }
    func chooseProvider(_ id: String) {
        chosenAgentID = nil
        chosenProvider = id
        chosenModelId = nil
        if let picked = chosenProfileId, let account = snapshot.accounts.first(where: { $0.id == picked }),
           let provider = account.provider, provider != id { chosenProfileId = nil }
        resolveDefaultProfile()
    }
    private func readModelCatalog() async {
        modelsLoading = true; defer { modelsLoading = false }
        guard let value = try? await call("hoot:ready:read", [false]) else { return }
        for provider in ["claude", "codex", "gemini"] {
            modelCatalog[provider] = (value["catalog"][provider]["models"].array ?? []).compactMap { row in
                guard let id = row["id"].text else { return nil }
                return ModelChoice(id: id, name: row["name"].text ?? id)
            }
        }
    }
    var remember = true
    /// Chat or Terminal for an AI session (Asad, 13 Oct). Opens on the person's last choice; whatever they choose
    /// here is the choice next time, and for every quick new session (+, ⌘T) meanwhile.
    var chatMode = true
    /// Only Claude Code, Codex and Gemini can run as a chat, and only on this Mac. With an agent chosen, its own AI.
    var canChat: Bool { here && server == nil && NewSessionChatMode.providers.contains(chosenAgent?.provider ?? decided?.provider ?? "") }
    /// Every saved agent (`tasks:state`): the Agent menu lists the chosen project's lead and agents.
    private(set) var teamAgents: [NewSessionTeamAgent] = []
    /// The agent the session starts as (its seat, memory, AI and account); nil: no agent, a plain session.
    var chosenAgentID: String?
    var currentProject: PROJProject? { registeredProjects.first { $0.id == projectIdentityID && $0.id != PROJProjects.independentID } }
    /// The chosen project's lead first, then its other agents.
    var projectAgents: [NewSessionTeamAgent] { NewSessionTeamAgent.forProject(teamAgents, project: currentProject) }
    var chosenAgent: NewSessionTeamAgent? { chosenAgentID.flatMap { id in projectAgents.first { $0.id == id } } }
    /// The Agent menu's pick (Asad, 13 Oct): the agent's own project folder is the path.
    func chooseAgent(_ id: String?) {
        chosenAgentID = id
        if id != nil, let project = currentProject, !project.folders.contains(where: { TaskProjects.within(selectedPath ?? "", $0) }) {
            selectedPath = project.folders.first
        }
    }
    var filter = ""

    // What the engine said
    private(set) var projects: [NewSessionProject] = []
    private(set) var detected: CodingAIJSON = .null
    private(set) var snapshot = CodingAIAccountsSnapshot.empty
    private(set) var defaultProvider: String?
    private(set) var defaultProfileId: String?
    /// The chosen project's "Default coding AI" (Project settings › Coding AI), read when the project changes.
    private(set) var projectProvider: String?
    private(set) var memory = NewSessionMemory()
    private(set) var signIn: CodingAISignIn?
    private(set) var accountSignIns: [String: CodingAISignIn] = [:]
    private(set) var added: [NewSessionCustomAgent] = []

    var error: String?
    private(set) var warning: String?
    private(set) var createdSessionID: String?
    private(set) var loading = false
    private(set) var starting = false
    private(set) var browsing = false
    var confirmRemove: String?

    // Add a CLI
    var addingAgent = false
    var draft = NewSessionAgentDraft()
    var problems: [String: String] = [:]
    private(set) var agentBusy = false

    @ObservationIgnored private var profileTicket = 0
    @ObservationIgnored private var signInTicket = 0

    init(context: NewSessionContext, bridge: WebBridge? = nil, projectID: String? = nil,
         effects: NativeNewSessionEffects? = nil) {
        self.context = context
        self.bridge = bridge
        let dependencies = effects ?? (bridge == nil ? NativeNewSessionEffects() : .live)
        var effects = dependencies
        if let bridge {
            effects.closed = { [weak bridge] in
                bridge?.webView.evaluateJavaScript("window.tdNewSession && window.tdNewSession.run('close')", completionHandler: nil)
            }
        }
        self.effects = effects
        selectedPath = context.projectPath
        selectedProjectID = projectID
        selectedMachine = context.machineId
        memory = NewSessionMemory.parse(context.memory ?? dependencies.readMemory())
    }

    func update(_ context: NewSessionContext) {
        self.context = context
    }

    #if DEBUG
    /// Hidden renders supply their own rows and never load the person's engine.
    func configureRenderFixture(projects: [PROJProject], providers: [NewSessionProviderRow] = []) {
        guard isRenderFixture else { return }
        fixtureProjects = projects
        fixtureProviders = providers
        self.projects = projects.flatMap { $0.folders.map { NewSessionProject(path: $0) } }
    }
    #endif

    // MARK: Derived

    var providerRows: [NewSessionProviderRow] { fixtureProviders ?? NewSessionProviders.rows(detected: detected, added: added) }

    var resolution: NewSessionResolution {
        NewSessionStart.resolve(
            providers: NewSessionStartProvider.from(providerRows, apiProviders: Set(snapshot.accounts.filter(\.isAPIKey).compactMap(\.provider))),
            profiles: snapshot.accounts.map { NewSessionStartProfile(id: $0.id, name: $0.name, system: $0.system, provider: $0.provider) },
            memory: memory, defaultProvider: defaultProvider, defaultProfileId: defaultProfileId,
            projectPath: selectedPath, provider: chosenProvider, profileId: chosenProfileId, resume: false, projectProvider: projectProvider)
    }

    var decided: NewSessionRequest? { resolution.request }
    var profileNotice: String? {
        NewSessionProviders.isolationNotice(decided?.provider, apiAccountAvailable: snapshot.accounts.contains { $0.isAPIKey && $0.provider == decided?.provider })
    }

    var machine: NewSessionMachine? { selectedMachine.flatMap { id in context.machines.first { $0.id == id } } }
    var server: NewSessionServer? { selectedServer.flatMap { id in context.servers.first { $0.id == id } } }
    var here: Bool { machine == nil && server == nil }

    var projectName: String {
        return registeredProjects.first { $0.id == projectIdentityID }?.name
            ?? selectedPath.map { URL(fileURLWithPath: $0).lastPathComponent }
            ?? "Independent"
    }

    var projectIdentityID: String {
        selectedProjectID ?? PROJProjects.resolve(projectID: nil, folder: selectedPath, projects: registeredProjects)
    }

    func chooseProject(_ project: PROJProject) {
        selectedProjectID = project.id
        if project.id == PROJProjects.independentID { selectedPath = nil }
        else if !project.folders.contains(where: { TaskProjects.within(selectedPath ?? "", $0) }) {
            selectedPath = project.folders.first
        }
        // Asad, 13 Oct: picking a project picks its lead, every time, until the Agent menu is changed (no lead: no agent).
        chosenAgentID = NewSessionTeamAgent.lead(teamAgents, project: project)?.id
    }

    var shortlist: (filtering: Bool, shown: [NewSessionProject], hidden: Int) {
        if let machine {
            return (false, machine.folders.map { NewSessionProject(path: $0) }, 0)
        }
        return NewSessionProjects.shortlist(projects, filter: filter)
    }

    var loginAccounts: [CodingAIAccount] {
        CodingAILogins.oneRowPerEmail(snapshot.accounts, signIn: accountSignIns, prefer: chosenProfileId ?? decided?.profileId)
    }

    func chooseLogin(_ id: String) {
        let previous = chosenAgent?.provider ?? decided?.provider
        chosenProfileId = id.isEmpty ? nil : id
        // A personal account choice cannot be ignored by the named-agent launch
        // route, which always owns its account. Show the plain-session choice.
        if !id.isEmpty { chosenAgentID = nil }
        if let account = snapshot.accounts.first(where: { $0.id == id }), let provider = account.provider,
           providerRows.contains(where: { $0.id == provider && $0.available }) {
            if previous != provider { chosenModelId = nil }
            chosenProvider = provider
            if account.isAPIKey, let model = account.apiModel { chosenModelId = model }
        }
    }

    private func readAccountIdentities() async {
        // The system email must come from the AI's own status, never its generated name.
        for account in snapshot.accounts {
            if let raw = try? await call("profiles:signin", [account.id, ["provider": account.provider ?? "claude", "refresh": false]]) {
                accountSignIns[account.id] = CodingAIAccountsParse.signIn(raw)
            }
        }
    }

    var activeProfile: CodingAIAccount? { snapshot.accounts.first { $0.id == decided?.profileId } }
    /// The start was refused because its Claude login is signed out (BackendAccountLaunchAdapter.signedOutRefusal).
    var needsClaudeChoice: Bool { error?.contains(BackendDefaultClaudeLogin.chooseMarker) == true }
    var refusedSignedOut: Bool { error?.contains(BackendAccountLaunchAdapter.notSignedInMarker) == true }
    /// Sign in to the login that was refused: an app-kept one through the app's own sign-in, this Mac's own Claude
    /// Code from its row in Settings › Coding AIs.
    @MainActor func signInRefusedAccount() {
        let account = activeProfile
        NativeChatAccount.openSettings(provider: account?.provider ?? chosenProvider ?? "claude")
        if let account, !account.system, NativeAccountSignInModel.canDrive(account.provider) { NativeAccountSignInModel.shared.start(account: account) }
    }

    var loginHint: String? {
        NewSessionLogin.hint(signIn, optionLabel: activeProfile.map { NewSessionLogin.optionLabel($0, selectedId: decided?.profileId, report: signIn) })
    }

    var canMakeDefault: Bool {
        decided?.profileId != nil && profileNotice == nil && activeProfile != nil
            && !NewSessionLogin.isDefault(activeProfile, defaultId: snapshot.defaultId)
    }

    var canStart: Bool { !loading && !starting && createdSessionID == nil && (server != nil || decided != nil) }

    // MARK: Loading (the page dialog's effects)

    private func call(_ channel: String, _ args: [Any?] = []) async throws -> CodingAIJSON {
        let answer = CodingAIJSON(try await effects.invoke(channel, args))
        if answer.bool == false || answer["ok"].bool == false {
            // #618: the server's own refusal ("key missing") is the reason shown, not a generic sentence.
            let said = [answer["message"].text, answer["sentence"].text].compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }.first { !$0.isEmpty }
            throw NativeNewSessionFailure(said ?? "That change could not be made. Please try again.")
        }
        return answer
    }

    /// CONNECT-SKILLS: an AI was installed from this dialog: read the AIs again and choose it.
    func providersChanged(choose id: String) {
        Task {
            detected = (try? await call("providers:detect")) ?? detected
            chosenProvider = id
        }
    }

    func load() {
        guard !isRenderFixture else { return }
        NativePROJLabels.shared.start()
        loading = true
        Task {
            defer { loading = false }
            async let recent = try? call("projects:list")
            async let providers = try? call("providers:detect")
            async let agents = try? call("agents:list")
            async let preferences = try? call("prefs:get")
            async let accounts = try? call("profiles:list")
            async let team = try? call("tasks:state")
            projects = NewSessionProjects.parse(await recent ?? .null)
            detected = await providers ?? .null
            added = NewSessionCustomAgent.parse(await agents ?? .null)
            let stored = await preferences ?? .null
            chatMode = stored[NewSessionChatMode.preference].string != "terminal"   // chat unless they last chose a terminal
            let id = stored["defaultProvider"].string
            defaultProvider = NewSessionProviders.isProviderId(id) ? id : "claude"
            snapshot = CodingAIAccountsParse.snapshot(await accounts ?? .null)
            teamAgents = NewSessionTeamAgent.parse(await team ?? .null)
            // The project the dialog opened on picks its lead too.
            if chosenAgentID == nil, let project = currentProject { chosenAgentID = NewSessionTeamAgent.lead(teamAgents, project: project)?.id }
            // Only now is the default AI known: asked earlier, the login row showed Claude's account for every default.
            resolveDefaultProfile()
            Task { await readAccountIdentities() }
            Task { await readModelCatalog() }
            if bridge == nil { await loadNativeContext() }
        }
    }

    private func loadNativeContext() async {
        async let machineReply = try? call("machines:list")
        async let serverReply = try? call("servers:list")
        async let sessionReply = try? call("session:list")
        let machines = await machineReply ?? .null
        let servers = await serverReply ?? .null
        let sessions = await sessionReply ?? .null
        var counts: [String: Int] = [:]
        for row in sessions.array ?? [] where row["exitCode"].isNull {
            if let path = row["cwd"].text { counts[path, default: 0] += 1 }
        }
        var offeredMachines: [NewSessionMachine] = []
        if effects.startMachine != nil, effects.openedMachine != nil {
            let names = Dictionary((machines["machines"].array ?? []).compactMap { row -> (String, String)? in
                guard let id = row["id"].text else { return nil }
                return (id, row["name"].text ?? id)
            }, uniquingKeysWith: { first, _ in first })
            for link in machines["links"].array ?? [] where link["state"].string == "online" {
                guard let id = link["id"].text,
                      (link["capabilities"].array ?? []).contains(where: { $0.string == "create" }) else { continue }
                offeredMachines.append(.init(id: id, name: names[id] ?? id,
                    folders: (link["folders"].array ?? []).compactMap(\.text)))
            }
        }
        let offeredServers: [NewSessionServer] = effects.openedServer == nil ? [] : (servers.array ?? []).compactMap { row in
            guard let id = row["id"].text else { return nil }
            return .init(id: id, name: row["name"].text ?? id)
        }
        context = NewSessionContext(seq: context.seq, projectPath: context.projectPath,
            machineId: context.machineId, machines: offeredMachines,
            hereName: CodingAIScopes.hereName(machines["here"].string ?? ""), servers: offeredServers,
            liveSessions: counts, memory: context.memory)
    }

    /// `profiles:resolve` for the chosen folder: which login a session there gets by default.
    func resolveDefaultProfile() {
        profileTicket += 1
        let mine = profileTicket
        let path = selectedPath
        Task {
            // FINAL-CONNECT (rows 61/62): the account Settings › Who uses what gives this folder (session → seat →
            // project → app), not an older per-folder memory: changing a level changes what New session starts.
            let provider = chosenProvider ?? defaultProvider ?? "claude"
            let effective = try? await call("profiles:effective", [["provider": provider, "projectPath": path as Any? ?? NSNull()]])
            var answer: CodingAIJSON?
            if effective?["accountId"].string == nil { answer = try? await call("profiles:resolve", [["projectPath": path as Any? ?? NSNull()]]) }
            guard mine == profileTicket else { return }
            defaultProfileId = effective?["accountId"].string ?? answer.flatMap { CodingAIAccountsParse.account($0)?.id }
            let project = projectIdentityID
            let settings = project == PROJProjects.independentID || isRenderFixture ? nil
                : try? await effects.invoke("project-settings:get", [["projectId": project]]) as? [String: Any]
            guard mine == profileTicket else { return }
            projectProvider = ((settings?["values"] as? [String: Any])?["defaultCodingAI"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        }
    }

    /// `profiles:signin` for the decided login, unless it does not apply.
    func checkSignIn() {
        signInTicket += 1
        let mine = signInTicket
        guard let profileId = decided?.profileId, let provider = decided?.provider, profileNotice == nil else {
            signIn = nil
            return
        }
        Task {
            let answer = try? await call("profiles:signin", [profileId, ["provider": provider]])
            guard mine == signInTicket else { return }
            signIn = answer.flatMap(NewSessionLogin.signIn)
            if let signIn { accountSignIns[profileId] = signIn }
        }
    }

    // MARK: Actions

    func chooseHere() {
        selectedMachine = nil
        selectedServer = nil
        selectedPath = context.projectPath
    }

    func choose(machine: NewSessionMachine) {
        selectedMachine = machine.id
        selectedServer = nil
        selectedPath = machine.folders.first
    }

    func choose(server: NewSessionServer) {
        selectedServer = server.id
        selectedMachine = nil
        serverPath = nil
    }

    func browse() {
        browsing = true
        window?.alphaValue = 0 // the page dialog hides while the folder panel is up
        Task {
            defer {
                browsing = false
                window?.alphaValue = 1
            }
            do {
                let picked = try await call("project:pick")
                guard let path = picked.string, !path.isEmpty else { return }
                projects = NewSessionProjects.with(projects, path)
                selectedPath = path
            } catch {
                self.error = "Could not open the folder picker."
            }
        }
    }

    func remove(_ path: String) {
        Task { await removeNative(path) }
    }

    func removeNative(_ path: String) async {
        confirmRemove = nil
        error = nil
        do {
            let ids = try await Self.removeFolder(path, invoke: effects.invoke)
            effects.removedProject(path, ids)
            projects.removeAll { $0.path == path }
            if selectedPath == path { selectedPath = nil }
        } catch { self.error = "That folder could not be removed. Its remaining sessions and folder were kept." }
    }

    static func removeFolder(_ path: String, invoke: @MainActor (String, [Any?]) async throws -> Any) async throws -> [String] {
        guard !path.isEmpty else { throw NativeNewSessionFailure("Choose a folder first.") }
        func checked(_ channel: String, _ args: [Any?]) async throws -> Any {
            let result = try await invoke(channel, args)
            if result as? Bool == false || (result as? [String: Any])?["ok"] as? Bool == false {
                throw NativeNewSessionFailure("That folder could not be removed. Its remaining sessions and folder were kept.")
            }
            return result
        }
        guard let sessions = try await checked("session:list", []) as? [[String: Any]] else {
            throw NativeNewSessionFailure("The sessions list could not be read. The folder was kept.")
        }
        var ids: [String] = []
        for row in sessions where NewSessionPaths.normalize(row["cwd"] as? String ?? "") == NewSessionPaths.normalize(path) {
            if let id = row["id"] as? String {
                _ = try await checked("session:kill", [id]); ids.append(id)
            }
        }
        _ = try await checked("projects:remove", [path])
        return ids
    }

    func addAgent() {
        guard !agentBusy else { return }
        agentBusy = true
        Task {
            defer { agentBusy = false }
            do {
                switch NewSessionAddAgent.outcome(try await call("agents:add", [draft.json])) {
                case .problems(let said):
                    problems = said
                case .added(let id):
                    added = NewSessionCustomAgent.parse((try? await call("agents:list")) ?? .null)
                    detected = (try? await call("providers:detect")) ?? .null
                    chosenProvider = id
                    draft = NewSessionAgentDraft()
                    problems = [:]
                    addingAgent = false
                }
            } catch {
                problems = ["command": (error as? EngineWireError)?.description ?? "That agent could not be added."]
            }
        }
    }

    func removeAgent(_ id: String) {
        Task {
            _ = try? await call("agents:remove", [id])
            added = NewSessionCustomAgent.parse((try? await call("agents:list")) ?? .null)
            if chosenProvider == id { chosenProvider = nil }
        }
    }

    func makeDefaultLogin() {
        guard let profileId = decided?.profileId else { return }
        Task {
            do {
                _ = try await call("profiles:set-default", [profileId])
                snapshot = CodingAIAccountsParse.snapshot(try await call("profiles:list"))
            } catch {
                self.error = (error as? EngineWireError)?.description ?? "Could not change the default login."
            }
        }
    }

    func edit(_ field: String, _ value: String) {
        switch field {
        case "label": draft.label = String(value.prefix(NewSessionAddAgent.maxLabel))
        case "description": draft.description = String(value.prefix(NewSessionAddAgent.maxDescription))
        case "command": draft.command = value
        case "args": draft.args = value
        default: draft.resumeArgs = value
        }
        problems[field] = nil
    }

    func submit() {
        Task { await submitNative() }
    }

    /// Directly awaitable by stub tests. A returned session is never started twice.
    func submitNative() async {
        guard canStart else { return }
        let identity = projectIdentityID
        starting = true
        error = nil; warning = nil
        defer { starting = false }
        do {
            if let server {
                guard selectedProjectID == nil || selectedProjectID == PROJProjects.independentID else {
                    throw NativeNewSessionFailure("This server's terminal route cannot retain the selected project yet.")
                }
                let capture = effects.captureShell()
                defer { capture?.stop() }
                guard let open = effects.openedServer else { throw NativeNewSessionFailure("This build cannot open a native server tab with the selected project yet.") }
                let answer = try await call("servers:shell:open", [server.id, 100, 30, serverPath as Any? ?? NSNull()])
                guard answer["ok"].bool == true, let id = answer["shellId"].text else {
                    throw NativeNewSessionFailure(answer["message"].text ?? "The server did not open a terminal.")
                }
                guard !id.isEmpty, capture?.ended.contains(id) != true else {
                    throw NativeNewSessionFailure("That server terminal ended while it was opening. Please try again.")
                }
                createdSessionID = id
                open(server.id, server.name, id, serverPath, identity)
                effects.shellOutput(id, capture?.take(id) ?? "")
                effects.dismiss()
                effects.closed()
                return
            }
            guard let request = decided else { return }
            if profileNotice == nil, let picked = chosenProfileId, request.profileId != picked {
                throw NativeNewSessionFailure("The chosen account is no longer available. Choose an account before starting.")
            }
            if let machine {
                guard let start = effects.startMachine, let open = effects.openedMachine else {
                    throw NativeNewSessionFailure("That machine cannot retain the selected project yet. Nothing was started.")
                }
                let id = try await start(machine.id, request, selectedProjectID == nil ? PROJProjects.independentID : identity)
                guard !id.isEmpty else { throw NativeNewSessionFailure("No new session appeared on that machine.") }
                createdSessionID = id
                open(machine.id, id, identity)
                effects.dismiss()
                effects.closed()
                return
            }
            // This form asks for no first message. Do not send one before login.
            var input: [String: Any] = ["cwd": request.cwd, "projectId": identity,
                "provider": request.provider, "resume": request.resume,
                "profileId": request.profileId as Any? ?? NSNull(), "cols": request.cols, "rows": request.rows]
            let permissionProvider = chosenAgent?.provider ?? request.provider
            let permission = BackendTAGLaunchArguments.newSessionPermission(provider: permissionProvider)
            if let permission { input["permissionMode"] = permission }
            // Said every time, so this session is exactly what the switch showed.
            let asChat = canChat && chatMode
            input["chat"] = asChat
            if chosenAgent == nil, request.provider == "claude", let model = chosenModelId { input["model"] = model }
            let raw: Any
            if let agent = chosenAgent {
                // As that agent: its seat, memory, AI and account (the engine reads its saved record).
                raw = try await effects.invoke("session:start-agent", [agent.id, identity, request.cwd, asChat, permission as Any? ?? NSNull()])
            } else {
                raw = try await effects.invoke("session:create", [input])
            }
            guard let meta = raw as? [String: Any], let id = meta["id"] as? String, !id.isEmpty else {
                throw NativeNewSessionFailure("The session did not return an ID. Check the sessions list before trying again.")
            }
            createdSessionID = id
            var notes: [String] = []
            if asChat, chosenAgent == nil, let model = chosenModelId {
                let options: [String: Any] = ["model": request.provider + ":" + model]
                do { _ = try await call("session:chat:options", [id, options]) }
                catch { notes.append("Its selected model could not be applied: " + error.localizedDescription) }
            }
            effects.openedLocal(meta)
            // The choice made here is the one next time (only an AI session has the switch).
            if canChat {
                do { _ = try await call("prefs:set", [[NewSessionChatMode.preference: asChat ? "chat" : "terminal"]]) }
                catch { notes.append("Its Chat or Terminal choice could not be remembered.") }
            }
            if meta["projectId"] as? String != identity { notes.append("Its project label could not be confirmed.") }
            do { _ = try await call("projects:add", [request.cwd]) }
            catch { notes.append("Its folder could not be added to the recent list.") }
            if remember {
                // Only an account picked by hand is remembered for this folder; otherwise Settings decides next time.
                var kept = request
                if chosenProfileId == nil { kept.profileId = nil }
                memory = memory.remembering(kept)
                do { try effects.writeMemory(memory.json) }
                catch { notes.append("Its choices could not be remembered.") }
            }
            do { try effects.writeLastFolder(request.cwd) }
            catch { notes.append("Its folder could not be remembered.") }
            if notes.isEmpty {
                effects.dismiss()
                effects.closed()
            } else {
                warning = "Session started. " + notes.joined(separator: " ")
            }
        } catch { self.error = error.localizedDescription }
    }

    func cancel() {
        if starting { return }
        effects.dismiss()
        effects.closed()
    }

}

// MARK: - The dialog

struct NativeNewSessionDialog: View {
    @State private var choosingClaudeLogin = false
    @Bindable var model: NativeNewSessionModel

    var body: some View {
        VStack(spacing: 0) {
            Text(model.addingAgent ? "Add a CLI" : "New session")
                .font(.title3.weight(.semibold))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.top, 16)
                .padding(.bottom, 10)

            ScrollView {
                Group {
                    if model.addingAgent {
                        NativeAddAgentForm(model: model)
                    } else {
                        form
                    }
                }
                .disabled(model.starting)
                .padding(.horizontal, 20)
                .padding(.bottom, 16)
            }
            .frame(minHeight: 0, maxHeight: 390)

            Divider()
            footer
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
        }
        .frame(width: 600)
        .frame(minHeight: 0, maxHeight: 490)
        .onChange(of: model.selectedPath) { model.resolveDefaultProfile() }
        .onChange(of: model.decided?.profileId) { model.checkSignIn() }
        .onChange(of: model.decided?.provider) { model.checkSignIn() }
        .onChange(of: model.profileNotice) { model.checkSignIn() }
    }

    // MARK: Footer

    @ViewBuilder private var footer: some View {
        HStack(spacing: 10) {
            if model.addingAgent {
                Spacer()
                // Back to the list, not out of the dialog.
                Button("Back") {
                    model.addingAgent = false
                    model.problems = [:]
                }
                Button(model.agentBusy ? "Checking…" : "Add CLI") { model.addAgent() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.agentBusy)
            } else if model.createdSessionID != nil {
                Text("Session started").font(.callout).foregroundStyle(.secondary)
                Spacer()
                Button("Done") { model.cancel() }.buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            } else {
                Text("⌘↩ to start").font(.callout).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { model.cancel() }
                    .keyboardShortcut(.cancelAction)
                Button(model.starting ? "Starting…" : model.server == nil ? "Start session" : "Open a terminal") { model.submit() }
                    .keyboardShortcut(.return, modifiers: .command)
                    .buttonStyle(.borderedProminent)
                    .disabled(!model.canStart)
            }
        }
        .background {
            // Esc closes the whole dialog in both views, as the page modal does.
            Button("") { model.cancel() }.keyboardShortcut(.cancelAction).hidden()
        }
    }

    // MARK: Form

    private var form: some View {
        VStack(alignment: .leading, spacing: 12) {
            if model.loading { ProgressView("Loading choices…").font(.callout) }
            if let error = model.error {
                Text(error).foregroundStyle(.red).font(.callout)
                // 29 Oct: a signed-out login is offered its Sign in right here, never a bare "Not logged in" later.
                if model.needsClaudeChoice {
                    Button("Switch…") { choosingClaudeLogin = true }
                        .sheet(isPresented: $choosingClaudeLogin) {
                            NativeClaudeLoginChoice(accounts: model.snapshot.accounts.filter {
                                !$0.system && $0.provider == "claude" && model.accountSignIns[$0.id]?.state == .signedIn
                            }) { account in
                                model.chooseLogin(account.id)
                                choosingClaudeLogin = false
                            }
                        }
                }
                if model.refusedSignedOut {
                    Button("Sign in\u{2026}") { model.signInRefusedAccount() }
                        .accessibilityIdentifier("newSession.signIn")
                }
            }
            if let warning = model.warning {
                Label(warning, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.secondary)
            }
            // What is wrong, and what the resolver quietly changed — at the top.
            if model.server == nil, let problem = model.resolution.problem {
                Text(problem).font(.callout).foregroundStyle(.orange)
            }
            if model.server == nil, !model.resolution.notices.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(model.resolution.notices) { notice in
                        Text(notice.message).font(.callout).foregroundStyle(.secondary)
                    }
                }
            }

            projectIdentitySection
            if !model.context.machines.isEmpty || !model.context.servers.isEmpty {
                whereSection
            }
            if model.here, let path = model.selectedPath {
                HStack(spacing: 12) {
                    Label(path, systemImage: "folder").font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Button("Choose folder") { model.browse() }.buttonStyle(.bordered).disabled(model.browsing)
                }
            } else { projectSection }
            // With an agent chosen, its own AI and account are used: the AI list stays out of the way.
            if model.server == nil { agentSection }
            if model.server == nil, model.canChooseModel { modelSection }
            if model.canChat { modeSection }
            if model.here {
                loginSection
                Toggle("Remember these choices for \(model.projectName)", isOn: $model.remember)
                    .toggleStyle(.checkbox)
            }
        }
    }

    private var projectIdentitySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                NativeNewSessionHeading("Project")
                Spacer()
                // Value picker seam: replace this menu with the shared ProjectPicker.
                Menu {
                    ForEach(model.registeredProjects.filter { $0.id != PROJProjects.independentID }) { project in
                        // The shared row: logo or letter tile, kept visible in a menu on macOS 27.
                        Button { model.chooseProject(project) } label: { DeckRowLabel.project(project) }
                    }
                    Divider()
                    if let independent = model.registeredProjects.first(where: { $0.id == PROJProjects.independentID }) {
                        Button { model.chooseProject(independent) } label: { DeckRowLabel.independent }
                    }
                    Divider()
                    Button("Choose folder…") { model.browse() }
                } label: {
                    Label { Text(model.projectName) } icon: {
                        Image(nsImage: ProjectLogos.menuImage(model.registeredProjects.first { $0.id == model.projectIdentityID },
                                                              name: model.projectName))
                    }
                }
                .menuStyle(.borderedButton)
                .fixedSize()
                .accessibilityLabel("Project for the new session")
            }
            if let problem = model.projectLoadError {
                Text(problem).font(.callout).foregroundStyle(.secondary)
            }
            if model.here, !model.projectAgents.isEmpty { agentChoice }
        }
    }

    /// Asad, 13 Oct: after a project is picked, its lead and agents; the lead is picked with the project.
    private var agentChoice: some View {
        HStack {
            NativeNewSessionHeading("Agent")
            Spacer()
            Menu {
                Button("No agent (plain session)") { model.chooseAgent(nil) }
                Divider()
                ForEach(model.projectAgents) { agent in
                    Button(agent.isLead ? agent.name + " (lead)" : agent.name) { model.chooseAgent(agent.id) }
                }
            } label: {
                Text(model.chosenAgent.map { $0.isLead ? $0.name + " (lead)" : $0.name } ?? "No agent (plain session)")
            }
            .menuStyle(.borderedButton)
            .fixedSize()
            .accessibilityLabel("Agent for the new session")
        }
    }

    private var whereSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            NativeNewSessionHeading("Where")
            VStack(spacing: 6) {
                NativeNewSessionChoice(selected: model.here, action: model.chooseHere) {
                    Text(model.context.hereName)
                }
                ForEach(model.context.machines) { row in
                    NativeNewSessionChoice(selected: model.machine?.id == row.id, action: { model.choose(machine: row) }) {
                        Image(systemName: "laptopcomputer").foregroundStyle(.secondary)
                        Text(row.name)
                    }
                }
                ForEach(model.context.servers) { row in
                    NativeNewSessionChoice(selected: model.server?.id == row.id, action: { model.choose(server: row) }) {
                        Text(row.name)
                    }
                }
            }
            if let server = model.server {
                Text("A terminal on \(server.name). An agent and a login are programs on this Mac, so neither is asked for here.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private var projectSection: some View {
        if let server = model.server {
            VStack(alignment: .leading, spacing: 8) {
                NativeNewSessionHeading("Folder on \(server.name)")
                // The server's own folder picker (lane G, NativeServerFolderPicker.swift).
                if model.isRenderFixture {
                    TextField("Folder", text: Binding(get: { model.serverPath ?? "" }, set: { model.serverPath = $0 }))
                        .textFieldStyle(.roundedBorder)
                } else {
                    NativeServerFolderPicker(serverId: server.id, serverName: server.name, path: $model.serverPath)
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    NativeNewSessionHeading(model.machine.map { "Folder on \($0.name)" } ?? "Folder")
                    Spacer()
                    // Browse opens this machine's file panel, so it is absent on another machine.
                    if model.machine == nil {
                        Button("Browse…") { model.browse() }
                            .buttonStyle(.link)
                            .disabled(model.browsing)
                    }
                }
                let list = model.shortlist
                if list.filtering {
                    TextField("Filter \(model.projects.count) folders", text: $model.filter)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityLabel("Filter projects")
                        .onSubmit { model.submit() }
                }
                if list.shown.isEmpty {
                    Text(emptyLine).font(.callout).foregroundStyle(.secondary)
                } else {
                    VStack(spacing: 4) {
                        ForEach(list.shown) { project in
                            NativeNewSessionProjectRow(project: project,
                                                       selected: project.path == model.selectedPath,
                                                       liveSessions: model.context.sessions(in: project.path),
                                                       confirming: model.confirmRemove == project.path,
                                                       model: model)
                        }
                    }
                }
                if list.hidden > 0 {
                    Text("\(list.hidden) more — narrow the filter, or Browse.").font(.callout).foregroundStyle(.secondary)
                }
                if let path = model.selectedPath, !list.shown.contains(where: { $0.path == path }) {
                    Text(path).font(.callout.monospaced()).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle).help(path)
                }
            }
        }
    }

    private var emptyLine: String {
        if let machine = model.machine {
            return "\(machine.name) is not sharing any folder with this one yet. Choose one there, in its remote access settings."
        }
        return model.filter.trimmingCharacters(in: .whitespaces).isEmpty
            ? "No recent projects. Browse for a folder to run the session in."
            : "No folder matches that. Browse for one instead."
    }

    private var agentSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            // "AI": the Agent menu above is the project's team (Asad, 13 Oct); this list is the Coding AI.
            NativeNewSessionHeading("AI")
            let primary = model.providerRows.filter { ["claude", "codex"].contains($0.id) && $0.available }
            if primary.count > 1 {
                Picker("Coding AI", selection: Binding(get: { model.chosenAgent?.provider ?? model.decided?.provider ?? "claude" }, set: { model.chooseProvider($0) })) {
                    ForEach(primary) { row in Text(row.id == "claude" ? "Claude" : "Codex").tag(row.id) }
                }.pickerStyle(.segmented).labelsHidden()
            }
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: 8) {
                ForEach(model.providerRows.filter { $0.available && (primary.count < 2 || !["claude", "codex"].contains($0.id)) }) { row in
                    NativeNewSessionAgentCard(row: row, selected: row.id == model.decided?.provider, model: model)
                }
                if model.here {
                    Button { model.addingAgent = true } label: {
                        HStack(alignment: .top, spacing: 10) {
                            Text("+").font(.title3).frame(width: 16)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Add a CLI").fontWeight(.medium)
                                Text("Any other command-line agent on this machine.").font(.callout).foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                        .padding(10)
                        .contentShape(.rect)
                        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var modelSection: some View {
        HStack {
            NativeNewSessionHeading("Model")
            Spacer()
            Menu {
                ForEach(model.modelChoices) { choice in
                    Button { model.chosenModelId = choice.id } label: {
                        if model.chosenModelId == choice.id { Label(choice.name, systemImage: "checkmark") }
                        else { Text(choice.name) }
                    }
                }
            } label: { Text(model.modelChoices.first { $0.id == model.chosenModelId }?.name ?? "Choose model") }
            .menuStyle(.borderedButton).fixedSize()
        }
    }

    /// Chat or Terminal, for an AI session (Asad, 13 Oct: "give a switch on each new session").
    private var modeSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                NativeNewSessionHeading("Open as")
                Spacer()
                Picker("Open as", selection: $model.chatMode) {
                    Text("Chat").tag(true)
                    Text("Terminal").tag(false)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .accessibilityLabel("Open the session as a chat or a terminal")
            }
        }
    }

    private var loginSection: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Login").fontWeight(.medium)
                if let line = model.profileNotice ?? model.loginHint {
                    Text(line).font(.callout).foregroundStyle(.secondary)
                        .help(NewSessionLogin.line(model.signIn) ?? "")
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer()
            // ACCOUNTS-SPEC §4: accounts are assigned in one place. This picker still chooses the
            // account for this one new session; who uses what by default is set in Settings.
            Button("Change defaults in Settings…") {
                AppModel.shared.requestSettings()
                AppModel.shared.selectSettingsSection("agents")
            }.buttonStyle(.link)
            Picker("Login", selection: Binding(get: { model.decided?.profileId ?? "" },
                                               set: { model.chooseLogin($0) })) {
                if model.decided?.profileId == nil {
                    Text(model.profileNotice != nil ? "Not applicable" : "The agent’s own login").tag("")
                }
                ForEach(model.loginAccounts) { account in
                    Text(CodingAIAccountLabels.profileLoginLabel(account, model.accountSignIns[account.id]))
                        .tag(account.id)
                }
            }
            .labelsHidden()
            .fixedSize()
            .disabled(model.profileNotice != nil || model.snapshot.accounts.isEmpty)
        }
    }
}

// MARK: - Parts

/// A saved agent as the New session dialog's Agent menu lists it.
struct NewSessionTeamAgent: Identifiable, Equatable {
    let id: String
    let name: String
    let projectID: String
    let provider: String
    var isLead = false

    static func parse(_ state: CodingAIJSON) -> [NewSessionTeamAgent] {
        (state["agents"].array ?? []).compactMap { row in
            guard let id = row["id"].string, !id.isEmpty, row["status"].string != "archived" else { return nil }
            return .init(id: id, name: row["name"].string ?? id, projectID: row["projectId"].string ?? "",
                         provider: row["claudeAgent"].string != nil ? "claude" : (row["provider"].string ?? "claude"))
        }
    }
    /// The project's lead when it is a saved agent.
    static func lead(_ agents: [NewSessionTeamAgent], project: PROJProject) -> NewSessionTeamAgent? {
        guard let lead = AGTSeats.lead(of: project), lead.kind == .agent else { return nil }
        return agents.first { $0.id == lead.id }.map { var found = $0; found.isLead = true; return found }
    }
    /// The project's lead first, then its other agents by name.
    static func forProject(_ agents: [NewSessionTeamAgent], project: PROJProject?) -> [NewSessionTeamAgent] {
        guard let project else { return [] }
        let lead = lead(agents, project: project)
        let others = agents.filter { $0.projectID == project.id && $0.id != lead?.id }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        return (lead.map { [$0] } ?? []) + others
    }
}

/// The remembered Chat / Terminal choice for new sessions (the app preference the engine reads too).
enum NewSessionChatMode {
    static let preference = "newSessionMode"
    static let providers: Set<String> = ["claude", "codex", "gemini"]
}

private struct NativeNewSessionHeading: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text).font(.headline)
    }
}

/// A radio card — the same card the Where rows and the Agent rows use.
private struct NativeNewSessionChoice<Content: View>: View {
    let selected: Bool
    var enabled = true
    let action: () -> Void
    @ViewBuilder let content: Content

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(selected ? Color.accentColor : .secondary)
                content
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .contentShape(.rect)
            .background(selected ? Color.accentColor.opacity(0.08) : .clear, in: .rect(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(selected ? Color.accentColor.opacity(0.6) : Color.secondary.opacity(0.25)))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }
}

private struct NativeNewSessionProjectRow: View {
    let project: NewSessionProject
    let selected: Bool
    let liveSessions: Int
    let confirming: Bool
    let model: NativeNewSessionModel

    var body: some View {
        HStack(spacing: 8) {
            NativeNewSessionChoice(selected: selected, action: { model.selectedPath = project.path }) {
                Text(project.name).fontWeight(.medium)
                // The path is the identity — two folders can share a name.
                Text(project.path).font(.callout).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle).help(project.path)
            }
            if confirming {
                HStack(spacing: 6) {
                    Text("Delete \(liveSessions) session\(liveSessions == 1 ? "" : "s")?")
                        .font(.callout).foregroundStyle(.secondary)
                    Button("Remove", role: .destructive) { model.remove(project.path) }
                    Button("Keep") { model.confirmRemove = nil }
                }
                .accessibilityLabel("Remove \(project.name)")
            } else {
                Button("Remove") {
                    if liveSessions > 0 { model.confirmRemove = project.path } else { model.remove(project.path) }
                }
                .help("Remove from this list — the folder is not deleted")
                .accessibilityLabel("Remove \(project.name) from this list")
            }
        }
    }
}

private struct NativeNewSessionAgentCard: View {
    let row: NewSessionProviderRow
    let selected: Bool
    let model: NativeNewSessionModel
    static func installable(_ id: String) -> Bool { ["claude", "codex", "gemini"].contains(id) }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Button { model.chooseProvider(row.id) } label: {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                        .foregroundStyle(selected ? Color.accentColor : .secondary)
                        .padding(.top, 2)
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text(row.label).fontWeight(.medium)
                            if !row.available {
                                Text("Not installed")
                                    .font(.caption.weight(.medium))
                                    .padding(.horizontal, 6).padding(.vertical, 1)
                                    .background(.quaternary, in: .capsule)
                            }
                        }
                        Text(row.hint).font(.callout).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        if !row.available, row.install != nil, !Self.installable(row.id) {
                            Text(row.install ?? "").font(.callout.monospaced()).textSelection(.enabled)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .disabled(!row.available)
            // CONNECT-SKILLS: install a missing coding AI here; it is then chosen for this session, whose
            // first screen is the AI's own sign-in.
            if !row.available, Self.installable(row.id) {
                NativeAIToolInstallButton(tool: row.id) { model.providersChanged(choose: row.id) }
            }
            if row.isCustom {
                Button("Remove") { model.removeAgent(row.id) }
            }
        }
        .padding(10)
        .opacity(row.available ? 1 : 0.75)
        .background(selected ? Color.accentColor.opacity(0.08) : .clear, in: .rect(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(selected ? Color.accentColor.opacity(0.6) : Color.secondary.opacity(0.25)))
    }
}

// MARK: - Add a CLI (`AddAgentForm.tsx`)

struct NativeAddAgentForm: View {
    @Bindable var model: NativeNewSessionModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            field("label", "Name", hint: "What the picker and the tab will call it.", mono: false)
            field("command", "Command",
                  hint: "A name on your PATH, or the full path to the program. Just the program — arguments go below.", mono: true)
            field("args", "Arguments", hint: NewSessionAddAgent.argsHint(model.draft.args), mono: true)
            field("resumeArgs", "Arguments to continue the last session",
                  hint: NewSessionAddAgent.resumeHint(model.draft.resumeArgs), mono: true)
            field("description", "Description", hint: "Optional. One line under the name in this list.", mono: false)
            Text(NewSessionAddAgent.note())
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func value(_ field: String) -> String {
        switch field {
        case "label": model.draft.label
        case "description": model.draft.description
        case "command": model.draft.command
        case "args": model.draft.args
        default: model.draft.resumeArgs
        }
    }

    private func field(_ key: String, _ label: String, hint: String, mono: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).fontWeight(.medium)
            TextField("", text: Binding(get: { value(key) }, set: { model.edit(key, $0) }))
                .textFieldStyle(.roundedBorder)
                .font(mono ? .body.monospaced() : .body)
                .autocorrectionDisabled()
                .accessibilityLabel(label)
                .onSubmit { model.addAgent() }
            // The complaint replaces the hint rather than joining it.
            if let problem = model.problems[key] {
                Text(problem).font(.callout).foregroundStyle(.red)
            } else {
                Text(hint).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
