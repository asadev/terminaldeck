import AppKit
import Observation
import WebKit
import TerminalDeckNativeCore

/// Everything Settings → Coding AI shows about this machine, and every change
/// it can make — over the same engine channels the web section calls.
///
/// One for the app, so leaving the section and coming back keeps the answers
/// already read (the web keeps its sign-in answers in a module-level store for
/// the same reason). Every visit reads again; every change goes to the engine
/// and the list is read back rather than patched — ids, colours and folders are
/// decided over there.
@MainActor
@Observable
final class NativeCodingAIStore {
    static let shared = NativeCodingAIStore()

    // Where the agents run
    var scope: CodingAIScope = .thisMachine
    private(set) var machines = CodingAIMachinesView.empty

    // What is installed and which agents can hold a login
    private(set) var prerequisites: CodingAIPrerequisites?
    /// The section's own error (a probe of this machine, a write of its profiles file).
    private(set) var sectionError: String?
    private var detected: CodingAIJSON = .null
    private var accountProviders: [CodingAIAccountProviderView] = []
    var providerRows: [CodingAIProviderRow] { CodingAIProviders.rows(detected: detected, fromMain: accountProviders) }

    // Default coding tool
    private(set) var defaultTool: String = CodingAIDefaultTool.fallback
    private(set) var defaultToolLoaded = false

    // Accounts
    private(set) var snapshot = CodingAIAccountsSnapshot.empty
    private(set) var accountsLoading = true
    private(set) var accountsLoaded = false
    private(set) var accountsError: String?
    private(set) var signIn: [String: CodingAISignIn] = [:]
    private(set) var history: [String: CodingAIHistory] = [:]
    private(set) var sessionTitles: [String: [String]] = [:]
    private(set) var sessionIDs: [String: [String]] = [:]
    private(set) var busy = false
    /// The accounts pane's own failure line (a refused rename, sign-out…).
    var failure: String?

    // Agent CLIs too old to sign in
    private(set) var staleAgents: [CodingAIStaleAgent] = []
    private(set) var dismissed: ReadinessDismissed.Map = [:]
    private(set) var upgrading: String?
    private(set) var upgradeResults: [String: (ok: Bool, message: String)] = [:]

    // Setup
    private(set) var setupWarning: String?
    private(set) var setupError: String?

    // The Add-account sheet
    var addingPresented = false
    var addingProvider: String?

    /// The Servers seat and the linked devices, each with its own reads.
    @ObservationIgnored let serversModel = NativeCodingAIServersModel()
    @ObservationIgnored private var deviceModels: [String: NativeCodingAIDeviceModel] = [:]

    /// Bumped when a sign-in was opened in the main window, so the view can bring it forward.
    private(set) var mainWindowRequest = 0
    /// Accounts whose sign-in was opened from here — asked again, past the engine's memo,
    /// the next time this window comes forward.
    @ObservationIgnored private var pendingSignIns: Set<String> = []

    @ObservationIgnored private var listTicket = 0
    @ObservationIgnored private var signInTicket = 0
    @ObservationIgnored private var subscriptions: [EngineSubscription] = []
    @ObservationIgnored private var lastFullRefresh: Date?
    @ObservationIgnored private var engineWait: Task<Void, Never>?

    private init() {}

    var engineReady: Bool { EngineBridge.shared.isReady }

    /// The main window is up and can open a session — which is what signing in is.
    var canStartSessions: Bool { AppModel.shared.canRun }

    /// Signing out runs over the engine, so it is offered whenever the engine is up.
    var canSignOut: Bool { engineReady }

    // MARK: - Reading

    private func call(_ channel: String, _ args: [Any?] = []) async throws -> CodingAIJSON {
        CodingAIJSON(try await EngineBridge.shared.invoke(channel, args))
    }

    /// Everything, as the web section reads on every visit to the pane.
    func refreshAll() {
        guard engineReady else {
            waitForEngine()
            return
        }
        subscribe()
        lastFullRefresh = Date()
        sectionError = nil
        failure = nil
        checkPrerequisites()
        readProviders()
        reloadAccounts()
        readDefaultTool()
        readSessions()
        readMachines()
        readSetup()
        readStaleAgents()
        readDismissed()
    }

    /// The engine said it is up a moment before the bridge has its address: try again shortly.
    private func waitForEngine() {
        guard engineWait == nil else { return }
        engineWait = Task {
            for _ in 0..<40 {
                try? await Task.sleep(for: .milliseconds(250))
                if Task.isCancelled { break }
                if engineReady {
                    engineWait = nil
                    refreshAll()
                    scopeShown(scope)
                    return
                }
            }
            engineWait = nil
        }
    }

    /// One device's logins, kept while the screen is open.
    func deviceModel(_ id: String) -> NativeCodingAIDeviceModel {
        if let model = deviceModels[id] { return model }
        let model = NativeCodingAIDeviceModel(deviceId: id)
        deviceModels[id] = model
        return model
    }

    /// A seat came on screen: the Servers seat connects only while it is shown,
    /// and a device is asked about its logins each time its seat is chosen.
    func scopeShown(_ scope: CodingAIScope) {
        guard engineReady else { return }
        if scope == .servers {
            serversModel.start()
        } else {
            serversModel.stop()
        }
        if case .device(let id) = scope, let device = machines.devices.first(where: { $0.id == id }), device.online {
            deviceModel(id).load(sessionId: device.sessions.first?.id)
        }
    }

    /// The section left the screen: hang up on every server it opened.
    func screenLeft() {
        serversModel.stop()
    }

    /// The window came forward: read what can have changed behind it.
    func windowCameForward() {
        guard engineReady else { return }
        if let last = lastFullRefresh, Date().timeIntervalSince(last) < 1 { return }
        let pending = pendingSignIns
        pendingSignIns = []
        reloadAccounts(forcing: pending)
        readSessions()
        readMachines()
    }

    private func subscribe() {
        guard subscriptions.isEmpty else { return }
        let bridge = EngineBridge.shared
        // The bridge dispatches on the main actor.
        subscriptions = [
            bridge.on("machines:state") { [weak self] args in
                guard let self else { return }
                self.machines = CodingAIMachinesView.parse(CodingAIJSON(args.first))
                self.scope = self.scope.after(devices: self.machines.devices)
            },
            bridge.on("remote:connections") { [weak self] _ in self?.readMachines() },
            bridge.on("session:created") { [weak self] _ in self?.readSessions() },
            bridge.on("session:exit") { [weak self] _ in self?.readSessions() },
            bridge.on("session:removed") { [weak self] _ in self?.readSessions() },
            bridge.on("session:renamed") { [weak self] _ in self?.readSessions() },
            // A stored value changed somewhere else (the copilot, a paired device).
            bridge.on("prefs:changed") { [weak self] _ in self?.readDefaultTool() },
            bridge.on("settings:changed") { [weak self] _ in self?.readDefaultTool() },
        ]
    }

    func checkPrerequisites() {
        Task {
            do {
                let raw = try await call("prereq:check")
                prerequisites = CodingAIPrerequisites.parse(raw)
            } catch {
                sectionError = CodingAIErrorText.from(error, fallback: "Could not check which agents are installed.")
            }
        }
    }

    private func readProviders() {
        Task {
            // Reset on open: the last visit's answers are how an account gets added for an
            // agent that has since been uninstalled.
            detected = .null
            accountProviders = []
            async let found = try? call("providers:detect")
            async let said = try? call("profiles:account-providers")
            let (foundValue, saidValue) = await (found, said)
            detected = foundValue ?? .null
            accountProviders = saidValue.map(CodingAIAccountProviderView.parse) ?? []
        }
    }

    /// The list, then each account's sign-in (and where its conversations are).
    func reloadAccounts(forcing: Set<String> = []) {
        listTicket += 1
        let mine = listTicket
        accountsLoading = true
        Task {
            do {
                let raw = try await call("profiles:list")
                guard mine == listTicket else { return }
                let next = CodingAIAccountsParse.snapshot(raw)
                snapshot = next
                accountsError = nil
                accountsLoading = false
                accountsLoaded = true
                checkSignIns(next.accounts, forcing: forcing)
                readHistory(next.accounts)
            } catch {
                guard mine == listTicket else { return }
                accountsError = CodingAIErrorText.from(error, fallback: "Could not read your accounts.")
                accountsLoading = false
            }
        }
    }

    /// Ask each account's agent whether it is signed in. `forcing` skips the engine's memo.
    private func checkSignIns(_ accounts: [CodingAIAccount], forcing: Set<String> = [], forceAll: Bool = false) {
        guard !accounts.isEmpty else { return }
        signInTicket += 1
        let mine = signInTicket
        for account in accounts where forceAll || forcing.contains(account.id) || signIn[account.id] == nil {
            signIn[account.id] = .checking
        }
        for account in accounts {
            if account.isAPIKey {
                signIn[account.id] = CodingAISignIn(state: account.apiConfigured ? .signedIn : .signedOut, plan: "API key", detail: NativeAPIAccounts.status(account))
                continue
            }
            let refresh = forceAll || forcing.contains(account.id)
            Task {
                let view: CodingAISignIn
                do {
                    let raw = try await call("profiles:signin", [account.id, ["refresh": refresh]])
                    view = CodingAIAccountsParse.signIn(raw)
                } catch {
                    view = CodingAISignIn(state: .unknown,
                                          detail: CodingAIErrorText.from(error, fallback: "This account’s sign-in state could not be read."))
                }
                guard mine == signInTicket else {
                    // A late answer is still a true one about that account.
                    if signIn[account.id] == nil || signIn[account.id] == .checking { signIn[account.id] = view }
                    return
                }
                signIn[account.id] = view
            }
        }
    }

    private func readHistory(_ accounts: [CodingAIAccount]) {
        for account in accounts where history[account.id] == nil {
            Task {
                guard let raw = try? await call("accounts:history-state", [account.id]),
                      let view = CodingAIAccountsParse.history(raw) else { return }
                history[account.id] = view
            }
        }
    }

    private func refreshHistory(_ id: String) {
        Task {
            guard let raw = try? await call("accounts:history-state", [id]),
                  let view = CodingAIAccountsParse.history(raw) else { return }
            history[id] = view
        }
    }

    func readDefaultTool() {
        Task {
            async let settings = try? call("settings:get")
            async let preferences = try? call("prefs:get")
            let (settingsValue, preferencesValue) = await (settings, preferences)
            guard NativeSettingsValues.shared.saveState != .saving else { return }
            defaultTool = CodingAIDefaultTool.current(settings: settingsValue ?? .null, preferences: preferencesValue ?? .null)
            defaultToolLoaded = true
        }
    }

    func readSessions() {
        Task {
            guard let raw = try? await call("session:list") else { return }
            sessionTitles = CodingAISessions.titlesByAccount(raw)
            sessionIDs = CodingAISessions.idsByAccount(raw)
        }
    }

    func readMachines() {
        Task {
            guard let raw = try? await call("machines:list") else { return }
            machines = CodingAIMachinesView.parse(raw)
            scope = scope.after(devices: machines.devices)
        }
    }

    private func readSetup() {
        Task {
            do {
                let raw = try await call("setup:status")
                if CodingAISetupNotice.readable(raw) {
                    setupWarning = CodingAISetupNotice.warning(raw)
                    setupError = nil
                } else {
                    setupWarning = nil
                    setupError = "The setup check answered with something this build cannot read."
                }
            } catch {
                setupError = CodingAIErrorText.from(error, fallback: "Could not check what is installed on this machine.")
            }
        }
    }

    /// Read the agent CLIs that are too old to sign in, again — for any screen that
    /// shows `NativeCodingAIStaleAgents(store: .shared)` (Readiness, as well as here).
    func refreshStaleAgents() {
        guard engineReady else { return }
        readStaleAgents()
        readDismissed()
    }

    private func readStaleAgents() {
        Task {
            guard let raw = try? await call("browser-signin:agents") else { return }
            staleAgents = CodingAIStaleAgent.parse(raw)
        }
    }

    private func readDismissed() {
        NativePageChoices.adopting(ReadinessDismissed.key, from: .settings) { [weak self] value in
            self?.dismissed = ReadinessDismissed.parse(value)
        }
    }

    // MARK: - Default coding tool

    /// Saved through the Settings values like every other row — to the preferences
    /// store, then handed to the main window the way the Settings page hands every
    /// save back — so its next session uses it.
    func setDefaultTool(_ value: String) {
        guard value != defaultTool else { return }
        defaultTool = value
        NativeSettingsValues.shared.save([CodingAIDefaultTool.settingId: .string(value)])
    }

    // MARK: - Primary account

    func choosePrimary(_ id: String) {
        guard id != CodingAIPrimaryAccount.selected(defaultId: snapshot.defaultId) else { return }
        snapshot.defaultId = id
        Task {
            do {
                let raw = try await call("profiles:set-default", [id])
                if raw["profiles"].array != nil { snapshot = CodingAIAccountsParse.snapshot(raw) }
                NativeCodingAIPages.announceAccountsChanged()
            } catch {
                sectionError = CodingAIErrorText.from(error, fallback: "Could not change the default profile.")
                reloadAccounts()
            }
        }
    }

    // MARK: - Account rows

    /// Every change goes to the engine and the list is read again.
    private func run(_ channel: String, _ args: [Any?], failed: String) {
        busy = true
        failure = nil
        Task {
            do {
                _ = try await call(channel, args)
                busy = false
                reloadAccounts()
                NativeCodingAIPages.announceAccountsChanged()
            } catch {
                busy = false
                failure = CodingAIErrorText.from(error, fallback: failed)
            }
        }
    }

    func makeDefault(_ account: CodingAIAccount) {
        run("profiles:set-default", [account.id], failed: "Could not change the default account.")
    }

    func remove(_ account: CodingAIAccount, closingSessions: Bool = false) {
        let open = closingSessions ? sessionIDs[account.id] ?? [] : []
        if account.isAPIKey { NativeAPIAccounts.shared.remove(account.id, closing: open); return }
        guard !open.isEmpty else { run("profiles:delete", [account.id], failed: "Could not remove that account."); return }
        busy = true
        failure = nil
        Task {
            do {
                _ = try await Self.closeThenRemove(open) { try await call("profiles:delete", [account.id]) }
                busy = false
                reloadAccounts()
                readSessions()
                NativeCodingAIPages.announceAccountsChanged()
            } catch {
                busy = false
                readSessions()
                failure = CodingAIErrorText.from(error, fallback: "Could not remove that account.")
            }
        }
    }

    /// 18 Oct (#89, #527): Close them and remove ends the account's open sessions, then removes it, asking again for
    /// a few seconds while the refusal still names a session whose agent is finishing.
    static func closeThenRemove<T>(_ sessions: [String], remove: () async throws -> T) async throws -> T {
        for id in sessions { _ = try? await EngineBridge.shared.invoke("session:kill", [id]) }
        var attempt = 0
        while true {
            do { return try await remove() }
            catch where !sessions.isEmpty && attempt < 20 && CodingAIAccountInUse.isRefusal(CodingAIErrorText.from(error, fallback: "")) {
                attempt += 1
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
    }

    func rename(_ account: CodingAIAccount, to typed: String) {
        guard let name = CodingAILogins.normalizeName(typed, current: account.name) else { return }
        busy = true
        failure = nil
        Task {
            do {
                _ = try await call("profiles:rename", [account.id, name])
                busy = false
                reloadAccounts()
                NativeCodingAIPages.announceAccountsChanged()
            } catch {
                busy = false
                failure = CodingAIErrorText.from(error, fallback: "Could not rename that account.")
            }
        }
    }

    /// Sign in: open a session on this account's own agent, in the main window,
    /// where the agent's own login flow runs. This app never touches a credential.
    @discardableResult
    func signIn(_ account: CodingAIAccount) -> Bool {
        let request = CodingAILogins.signInRequest(account)
        guard startSession(profileId: request.profileId, provider: request.provider) else {
            failure = "Terminal Deck’s main window isn’t open, so there is nowhere to sign in yet."
            return false
        }
        pendingSignIns.insert(account.id)
        return true
    }

    /// The install login of one agent — what the menu's Sign in opens a session on.
    func signInInstall(_ provider: String) {
        guard let account = snapshot.accounts.first(where: { $0.provider == provider && $0.system }) else { return }
        signIn(account)
    }

    func signOut(_ account: CodingAIAccount) {
        busy = true
        failure = nil
        Task {
            do {
                let raw = try await call("profiles:signout", [account.id])
                busy = false
                let answer = CodingAIAccountsParse.outcome(raw)
                // The row settles from the probe, not the press.
                reloadAccounts(forcing: [account.id])
                NativeCodingAIPages.announceAccountsChanged()
                if !answer.ok, !answer.message.isEmpty { failure = answer.message }
            } catch {
                busy = false
                failure = CodingAIErrorText.from(error, fallback: "Could not sign that account out.")
            }
        }
    }

    /// Add the account and open its sign-in as one act; take it back if no session can open.
    func signInToNewAccount(name: String, provider: String) {
        busy = true
        failure = nil
        Task {
            defer {
                busy = false
                reloadAccounts()
            }
            guard canStartSessions else {
                failure = "This window cannot open a session, so there is nothing to sign in with."
                return
            }
            let created: CodingAIJSON
            do {
                created = try await call("profiles:create", [name, ["provider": provider]])
            } catch {
                failure = CodingAIErrorText.from(error, fallback: "Could not add that account.")
                return
            }
            guard let id = CodingAIAccountsParse.createdId(created) else {
                failure = "Could not add that account."
                return
            }
            // Shared history from the first moment, before the session writes anything.
            // A refusal is a preference, not a failure.
            _ = try? await call("accounts:history-share", [id])
            NativeCodingAIPages.announceAccountsChanged()
            if startSession(profileId: id, provider: provider) {
                pendingSignIns.insert(id)
                history[id] = nil
                refreshHistory(id)
            } else {
                _ = try? await call("profiles:delete", [id, ["deleteFiles": true]])
                NativeCodingAIPages.announceAccountsChanged()
                failure = "Could not open a session to sign in, so the account was not kept."
            }
        }
    }

    /// `start-session` on the settings relay: the main window opens it exactly as it
    /// does for the Settings page, and is brought forward.
    private func startSession(profileId: String, provider: String?) -> Bool {
        guard canStartSessions else { return false }
        let script = CodingAIPageScripts.relay(CodingAIPageScripts.startSessionMessage(profileId: profileId, provider: provider))
        guard NativeCodingAIPages.evaluate(script, in: .settings) || NativeCodingAIPages.evaluate(script, in: .main) else { return false }
        mainWindowRequest += 1
        return true
    }

    func askForAddAccount(_ provider: String?) {
        addingProvider = provider
        addingPresented = true
    }

    /// Hook from `WebBridge.receive` (lane G): an `open-settings` message carrying
    /// `action: 'add-account'` — the account chip's Add account. The message still
    /// opens the Settings window on Coding AI as usual; this opens the Add-account
    /// sheet there, on this machine's accounts. It shows the moment the section is
    /// on screen (now, or once the Settings page has said which section is open).
    static func noteSettingsRequest(_ body: Any) {
        guard let request = CodingAISettingsRequest.parse(CodingAIJSON(body)) else { return }
        shared.scope = .thisMachine
        shared.askForAddAccount(request.provider)
    }

    // MARK: - Stale agent CLIs

    /// FINAL-CONNECT (row 36): "Upgrade it" now upgrades, through the route that installed it (the one-click installer).
    func upgrade(_ row: CodingAIStaleAgent) {
        guard ["claude", "codex", "gemini"].contains(row.command) else {
            upgradeResults[row.command] = (false, "Update " + row.command + " the way it was installed. " + row.advice); return
        }
        upgrading = row.command
        upgradeResults[row.command] = nil
        NativeAIToolInstallModel.shared.install(row.command, upgrade: true) { [weak self] in self?.upgradeFinished(row) }
        Task { @MainActor [weak self] in
            // The installer's own end ("installed", "failed" or "needs") is what this row says.
            for _ in 0..<1_800 {
                try? await Task.sleep(for: .seconds(1))
                guard let self, self.upgrading == row.command else { return }
                let progress = NativeAIToolInstallModel.shared.progress[row.command]
                if let progress, ["failed", "needs"].contains(progress.state) {
                    self.upgradeResults[row.command] = (false, progress.message); self.upgrading = nil; return
                }
            }
        }
    }
    private func upgradeFinished(_ row: CodingAIStaleAgent) {
        let progress = NativeAIToolInstallModel.shared.progress[row.command]
        upgradeResults[row.command] = (true, progress?.message ?? "Updated.")
        upgrading = nil
        readStaleAgents()
    }

    func dismiss(_ row: CodingAIStaleAgent) {
        changeDismissed { ReadinessDismissed.dismiss($0, scope: ReadinessDismissed.machineScope, id: row.dismissalId) }
    }

    func bringBackDismissed() {
        changeDismissed { ReadinessDismissed.restoreAll($0, scope: ReadinessDismissed.machineScope) }
    }

    /// Written over what the app holds now, in the app's settings (#70): the readiness rows keep
    /// their own (per-project) entries in the same map, and must not be overwritten.
    private func changeDismissed(_ edit: @escaping (ReadinessDismissed.Map) -> ReadinessDismissed.Map) {
        NativePageChoices.adopting(ReadinessDismissed.key, from: .settings) { [weak self] value in
            let next = edit(ReadinessDismissed.parse(value))
            NativePageChoices.write(ReadinessDismissed.key, ReadinessDismissed.serialize(next))
            self?.dismissed = next
        }
    }

    // MARK: - Derived

    var addAccountsFacts: CodingAIAddAccounts.Facts {
        CodingAIAddAccounts.facts(prerequisites: prerequisites, providerRows: providerRows, accounts: snapshot.accounts, signIn: signIn)
    }

    var displayedAccounts: [CodingAIAccount] { CodingAILogins.oneRowPerEmail(snapshot.accounts, signIn: signIn) }
    var runs: [CodingAIAccountRun] { CodingAIAccountRuns.runs(displayedAccounts, signIn: signIn) }
    func copies(of account: CodingAIAccount) -> [CodingAIAccount] {
        CodingAILogins.copies(of: account, accounts: snapshot.accounts, signIn: signIn)
    }

    func removeCopy(_ account: CodingAIAccount) {
        busy = true; failure = nil
        Task {
            do {
                let answer = try await call("profiles:remove-copy", [account.id])
                guard answer["removed"].isTrue else { throw NativeRPCError(code: "account-copy", message: "The copy was not removed. Try Remove copy again.") }
                busy = false
                reloadAccounts()
                NativeCodingAIPages.announceAccountsChanged()
            } catch {
                busy = false
                failure = CodingAIErrorText.from(error, fallback: "The copy could not be removed. Its history stays on disk; try Remove copy again.")
            }
        }
    }

    func row(_ account: CodingAIAccount) -> CodingAIAccountRowModel {
        CodingAIAccountRowModel.make(
            account: account, snapshot: snapshot, signIn: signIn, history: history,
            providerRows: providerRows, sessionTitles: sessionTitles[account.id],
            canStartSessions: canStartSessions, canSignOut: canSignOut)
    }
}

/// The two pages the native screen speaks to — see `CodingAIPageScripts`.
@MainActor
enum NativeCodingAIPages {
    enum Page { case main, settings }

    private static func webView(_ page: Page) -> WKWebView? {
        let bridge = page == .main ? AppModel.shared.web : AppModel.shared.settingsWeb
        return bridge.origin == nil ? nil : bridge.webView
    }

    /// Run a script in a page. False when that page is not loaded.
    @discardableResult
    static func evaluate(_ script: String, in page: Page, answer: (@MainActor (String?) -> Void)? = nil) -> Bool {
        guard let view = webView(page) else {
            answer?(nil)
            return false
        }
        view.evaluateJavaScript(script) { value, _ in
            let text = value as? String
            MainActor.assumeIsolated { answer?(text) }
        }
        return true
    }

    /// Every account list in both pages reads again — the session chips included.
    static func announceAccountsChanged() {
        evaluate(CodingAIPageScripts.announceAccountsChanged, in: .main)
        evaluate(CodingAIPageScripts.announceAccountsChanged, in: .settings)
    }
}
