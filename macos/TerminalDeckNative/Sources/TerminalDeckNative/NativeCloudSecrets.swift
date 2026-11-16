import AppKit
import SwiftUI
import Observation
import TerminalDeckBackend
import TerminalDeckNativeCore

/// Everything saved passwords (lane V) need from the real app, as ONE value handed to `NativeCloudApplication.assemble`.
/// Absent = saved passwords are not part of this run: no graph, no tool, no section on the Cloud page and no
/// saved-password domain in the sync core. Fixtures pass none, or their own in-memory one.
struct NativeCloudSecretsLive: Sendable {
    /// This Mac's saved-password key for one account and one device id. In the app: `keychain(appName:)`.
    let keyStore: @Sendable (_ subject: CloudSubject, _ deviceId: String) -> any CloudSecretsLocalKeyPort
    /// The window lane V's sheets attach to.
    let window: @MainActor @Sendable () -> NSWindow?
    /// The app's live owners as lane V's stores, for one identity. `confirmMCPAdd` is V's own "Add this MCP server"
    /// sheet in this Mac's window; nothing else may add a server.
    let stores: @Sendable (_ confirmMCPAdd: @escaping @Sendable (BackendCloudSecretsMCPPendingItem) async -> Bool) async throws -> [any CloudSecretsLogicalStore]
    /// Lane V's check of this Mac's own stores for one identity's policy (`BackendCloudRecoveryLocalStores.lean`):
    /// no account vault, no store switch. After a verified unlock it only checks that the stores open, and says
    /// "blocked" or "key lost" truthfully when they do not.
    let localStores: @Sendable (_ policy: CloudSecretsPolicy) -> BackendCloudRecoveryLocalStores
    /// Kept conflict copies and "already uploaded" marks: one shared instance of each.
    let conflicts: BackendCloudSecretsConflicts
    let known: BackendCloudSecretsKnown
    /// Starts routing the owners' own change events (by source id); the result removes the observers again.
    let changes: @Sendable (_ changed: @escaping @Sendable (_ sourceId: String) -> Void) -> @Sendable () -> Void

    /// The app's key place: the login Keychain, service "<appName> Cloud Secrets", one item per account AND device id,
    /// never a file. Refused in a test process, so no fixture can reach the real Keychain.
    static func keychain(appName: String) throws -> @Sendable (CloudSubject, String) -> any CloudSecretsLocalKeyPort {
        guard !NativeCloudApplication.isTestProcess, !appName.isEmpty else { throw CloudFailure.unsafeConfiguration }
        return { subject, deviceId in BackendCloudSecretsProtectedStore.keychain(appName: appName, subject: subject, deviceId: deviceId) }
    }
}

/// Builds one identity's saved passwords inside the account assembly. Returns nothing (and leaves the sync core
/// without any saved-password domain) when a part is missing: absent, never half-built.
enum NativeCloudSecretsAssembly {
    static func attach(_ live: NativeCloudSecretsLive, subject: CloudSubject, registration: CloudDeviceRegistration,
                       identity: BackendCloudAccountIdentity, control: BackendCloudSecretsControl, gate: BackendCloudSecretsGate,
                       now: @escaping @Sendable () -> Int64, outbox: any CloudOutboxPort, dataRoot: URL,
                       engine: BackendCloudSecretsEngineParts, sink: BackendCloudSecretsEventSink,
                       automatic: CloudSecretsAutoTrust? = nil) async -> BackendCloudSecretsGraph? {
        let local = live.keyStore(subject, registration.deviceId)
        let policy = gate.policy(now: now)
        let window = live.window
        // Lane V's entry point: the native sheets, the recovery coordinator and the saved-passwords content port.
        // The old "Start new saved passwords" with a sign-in ticket is not in this version (that path can only refuse);
        // "Start again" when nobody can open the copy needs no ticket (`resetSilently`).
        let made = await MainActor.run {
            let parts = NativeCompositionCloudSecrets.make(subject: subject, device: registration, keys: identity, local: local, control: control,
                policy: policy, parent: window, resetTicket: { throw CloudFailure.unavailable })
            return (recovery: parts.recovery, content: parts.content, interaction: parts.interaction)
        }
        let interaction = made.interaction
        await made.recovery.use(automatic: automatic)
        // Gap 1 (14 Nov): one plain line per state change in the app's log, beside the `cloud sign-in:` lines.
        let log = NativeCloudSecretsAssembly.log
        await made.recovery.use(log: log)
        #if DEBUG
        // Proof P3's scratch plan only: lane V's coordinator accepts production's issuer alone; the permit re-checks
        // the plan's conditions itself (scratch data folder, the exact TEST service, an issuer that is not
        // production's) and then admits that ONE issuer. A release build compiles neither the type nor this call.
        if let plan = NativeCloudScratch.active,
           let permit = CloudSecretsScratchPermit(dataRoot: dataRoot, base: plan.base, issuer: plan.issuer) {
            await made.recovery.adopt(scratch: permit)
        }
        #endif
        // This Mac's own stores, before any secret is read: an earlier build's route is taken up (nothing otherwise).
        let migration = live.localStores(policy)
        try? await migration.resume()
        guard let offered = try? await live.stores({ item in await interaction.confirmMCPAdd(item) }) else { return nil }
        let kept = BackendCloudSecretsLean.admitted(offered)
        guard !kept.isEmpty else { return nil }
        let conflicts = live.conflicts
        // Slice 2: his passkey as the spare key (offered only where the app carries its associated domain).
        var passkey: (any CloudSecretsPasskeyPort)?
        if automatic != nil { passkey = await MainActor.run { NativeCloudPasskey() } }
        guard let graph = try? BackendCloudSecretsGraph(recovery: made.recovery, content: made.content, policy: policy, gate: gate,
            local: local, deviceId: registration.deviceId, outbox: outbox, stores: kept,
            retainConflict: { try await conflicts.retain($0) }, known: live.known,
            restoreLocalStores: { try await migration.recoverAfterVerifiedCloudUnlock() },
            localStanding: { await migration.standing() },
            changed: { Task { @MainActor in NativeCloudSecrets.shared.reload() } }, turnsOnBySelf: true,
            startAgainAvailable: automatic != nil, automatic: automatic, passkey: passkey,
            spareOfferWait: BackendCloudSecretsGraph.randomSpareOfferWait, log: log) else { return nil }
        // Before the sync core is first needed: its saved-password domains and the content port that seals them.
        engine.set(domains: BackendCloudSecretsLean.domains(kept), content: made.content)
        sink.listen { event in Task { await graph.event(event) } }
        let stop = live.changes { sourceId in Task { await graph.sourceChanged(sourceId) } }
        await graph.observing(stop)
        let statusCache = sink.statusCache
        statusCache.use(log: log)
        await MainActor.run { NativeCloudSecrets.shared.statusCache = statusCache; NativeCloudSecrets.shared.attach(graph) }
        return graph
    }
    /// The app's log, as the account's own `cloud sign-in:` lines ("[native <time>] graph: cloud passwords: …").
    /// Nothing in a test process.
    static let log = CloudSecretsLog { line in
        Task { @MainActor in NativeCloudAccount.log(line) }
    }
    /// Sign-out or a closed gate: nothing of this identity's saved passwords stays reachable.
    static func seal(_ graph: BackendCloudSecretsGraph, sink: BackendCloudSecretsEventSink) async {
        sink.listen(nil)
        await graph.seal()
        await MainActor.run { NativeCloudSecrets.shared.detach(graph) }
    }
}

/// What the Cloud page shows of saved passwords and the presses it passes on. Empty while no identity's saved
/// passwords are wired (signed out, Cloud not allowed, or not part of this build): the section is then absent.
@MainActor @Observable
final class NativeCloudSecrets {
    static let shared = NativeCloudSecrets()
    private(set) var page: BackendCloudSecretsPage?
    private(set) var busy = false
    /// "Start again" waits out 5 seconds behind Undo (the page's Undo pattern); nothing is sent before.
    private(set) var startingAgain = false
    @ObservationIgnored private var startAgainTask: Task<Void, Never>?
    /// Review blocker 4: a press on the stricter switch or on "Start again" right after the app's own remote input
    /// is refused at the moment of the press (judged by the press event's own time), as the trust presses are.
    private(set) var refusedLine: String?
    @ObservationIgnored var pressAllowed: @MainActor () -> Bool = {
        NativeCloudSheetGuard.pagePressAllowed(remote: NativeCloudSheetGuard.shared.remote, at: NativeCloudSheetGuard.pressTime())
    }
    /// The shown page with the Undo wait folded in.
    var shown: BackendCloudSecretsPage? {
        guard var page else { return nil }
        page.startingAgain = startingAgain
        if let refusedLine { page.problem = refusedLine }
        return page
    }
    @ObservationIgnored private(set) var graph: BackendCloudSecretsGraph?
    /// The kept `/secrets/status` answer (14 Nov): his opening the page, a press, Check again and Sync now read fresh.
    @ObservationIgnored var statusCache: BackendCloudSecretsStatusCache?
    @ObservationIgnored private var loading: Task<Void, Never>?
    /// The existing "Allow login store" action (Settings › Coding AIs uses the same channel).
    @ObservationIgnored var allowLoginStoreAction: @MainActor () async -> Void = {
        _ = try? await EngineBridge.shared.invoke("profiles:vault-recover", [])
    }
    init() {}
    /// Gap 1b: the Cloud tools register saved passwords' tools the moment a graph attaches (set by `NativeCompositionCloud`).
    @ObservationIgnored var attached: (@MainActor () -> Void)?
    func attach(_ graph: BackendCloudSecretsGraph) { self.graph = graph; reload(); attached?() }
    func detach(_ graph: BackendCloudSecretsGraph) {
        guard self.graph === graph else { return }
        statusCache?.invalidate(); statusCache = nil
        loading?.cancel(); loading = nil
        startAgainTask?.cancel(); startAgainTask = nil; startingAgain = false
        self.graph = nil; page = nil; busy = false
        // Project secret files: nothing of this identity stays readable through the status or the Code page.
        if let files = BackendProjectSecretFilesHolder.shared.store { Task { await files.use(keys: nil) } }
        BackendProjectSecretFilesHolder.shared.store = nil
    }
    /// Reads the state again. Called when the page opens, after a press and when the service says something changed.
    /// `fresh`: his own look (the page opening, Check again, Sync now) asks the service; any other reload (the graph's
    /// own change notes) uses the kept answer, so nothing that repeats by itself reaches the service.
    func reload(fresh: String? = nil) {
        guard let graph else { page = nil; return }
        if let fresh { statusCache?.invalidate(fresh) }
        loading?.cancel()
        loading = Task { [weak self] in
            let next = await graph.page()
            let keep = BackendProjectSecretFilesHolder.shared.stateRoot.map { BackendProjectSecretFilesStore.keepsOnThisMac(stateRoot: $0) }
            guard !Task.isCancelled, let self, self.graph === graph else { return }
            self.page = next
            self.keepProjectSecretsHere = keep
        }
    }
    private func press(_ work: @escaping @Sendable (BackendCloudSecretsGraph) async -> Void) {
        guard let graph, !busy else { return }
        statusCache?.invalidate("your press")
        busy = true; refusedLine = nil
        Task { [weak self] in
            await work(graph)
            self?.busy = false
            self?.reload()
        }
    }
    func perform(_ action: BackendCloudSecretsGraph.Action, approvalId: String? = nil) {
        press { await $0.perform(action, approvalId: approvalId) }
    }
    /// "Start again": 5 seconds with Undo, then the fresh Cloud copy from this Mac (his logins here stay).
    func startAgain() {
        guard graph != nil, !busy, !startingAgain else { return }
        guard pressAllowed() else { refusedLine = BackendCloudSecretsWords.pressRefused; return }
        refusedLine = nil
        startingAgain = true
        startAgainTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled, let self, self.startingAgain else { return }
            self.startingAgain = false; self.startAgainTask = nil
            self.perform(.startAgain)
        }
    }
    func undoStartAgain() { startAgainTask?.cancel(); startAgainTask = nil; startingAgain = false }
    /// The stricter setting's switch: the owner's press on this page only.
    func setAskOnNewDevice(_ value: Bool) {
        guard pressAllowed() else { refusedLine = BackendCloudSecretsWords.pressRefused; return }
        refusedLine = nil
        press { await $0.setAskOnNewDevice(value) }
    }
    /// 15 Nov: "Keep saved passwords and secret files off my phones" (off by default), his own press on this page only.
    func setPhonesOff(_ value: Bool) {
        guard pressAllowed() else { refusedLine = BackendCloudSecretsWords.pressRefused; return }
        refusedLine = nil
        press { await $0.setPhonesOff(value) }
    }
    /// Gap 2: "Make a passkey spare key", his own press on this page only (refused right after remote control).
    func makeSpare() {
        guard pressAllowed() else { refusedLine = BackendCloudSecretsWords.pressRefused; return }
        refusedLine = nil
        press { await $0.perform(.makeSpare) }
    }
    /// PASSWORDS-5: "Make my spare key again", his own press on this page only (refused right after remote control).
    func repairSpare() {
        guard pressAllowed() else { refusedLine = BackendCloudSecretsWords.pressRefused; return }
        refusedLine = nil
        press { await $0.perform(.repairSpare) }
    }
    /// Project secret files' stricter setting ("Keep project secret files on this Mac only", default off). nil = not
    /// part of this run. His press on this page only, refused right after remote control.
    private(set) var keepProjectSecretsHere: Bool?
    /// Review 14 Nov (F9): set when the switch could not be saved; the switch then shows as not changed.
    private(set) var keepProjectSecretsLine: String?
    func setKeepProjectSecretsHere(_ value: Bool) {
        guard pressAllowed() else { refusedLine = BackendCloudSecretsWords.pressRefused; return }
        refusedLine = nil
        // Saved first and read back; only then does the switch move. Never silently.
        guard let root = BackendProjectSecretFilesHolder.shared.stateRoot,
              (try? BackendProjectSecretFilesStore.saveKeepOnThisMac(value, stateRoot: root)) != nil else {
            keepProjectSecretsLine = BackendProjectSecretFilesWords.keepNotSaved
            return
        }
        keepProjectSecretsLine = nil
        keepProjectSecretsHere = value
        // Switched off: what waited is placed and this Mac's files are sent at once.
        press { graph in await graph.sourceChanged(BackendProjectSecretFilesRules.sourceId) }
    }
    /// "Sync now" on the Cloud page: saved passwords send what changed at the same moment (no timer of their own).
    func syncNow() {
        guard let graph else { return }
        statusCache?.invalidate("sync now")
        Task { await graph.syncNow() }
    }
    /// The person has seen the items that were closed on this Mac without being applied.
    func dismissNotices() { press { await $0.dismissNotices() } }
    func addWaiting(_ id: String) { press { await $0.addWaiting(id) } }
    func dismissWaiting(_ id: String) { press { await $0.dismissWaiting(id) } }
    func allowLoginStore() {
        let allow = allowLoginStoreAction
        press { graph in
            await allow()
            await graph.catchUp()
        }
    }
    /// The sign-out guard's first question (R5). No saved passwords wired for this identity: no key is held.
    nonisolated static func keyHeld() async -> Bool {
        guard let graph = await MainActor.run(body: { NativeCloudSecrets.shared.graph }) else { return false }
        return await graph.keyHeld()
    }
    /// Design B4: this Mac was signed out by another device; its saved-passwords keys go (never his data).
    nonisolated static func forgetKeysAfterRemoteSignOut() async {
        guard let graph = await MainActor.run(body: { NativeCloudSecrets.shared.graph }) else { return }
        await graph.forgetKeysAfterRemoteSignOut()
    }
    /// The sign-out guard's question (R5). No saved passwords wired for this identity: not confirmed.
    nonisolated static func recoveryWordsConfirmed() async throws -> Bool {
        guard let graph = await MainActor.run(body: { NativeCloudSecrets.shared.graph }) else { return false }
        return try await graph.recoveryWordsConfirmed()
    }
    /// The last-device warning's fact: this older account has recovery words on file (they can open the copy again).
    nonisolated static func recoveryWordsOnFile() async -> Bool {
        guard let graph = await MainActor.run(body: { NativeCloudSecrets.shared.graph }) else { return false }
        return await graph.recoveryWordsOnFile()
    }
}

/// Settings → Cloud → Saved passwords. Shown only while this identity's saved passwords are wired.
struct NativeCloudSecretsSection: View {
    let model: NativeCloudSecrets
    /// His page rule (pinned 14 Nov): the row is a name, ONE state and at most one control; no explanatory sentences.
    /// Saved passwords are on by default and open by themselves; "Use recovery words" exists only on older accounts
    /// that have words, inside the one control.
    /// Owner, 15 Nov (DESIGN.md section 3): ONE group of switches; every explaining sentence (what is not carried yet,
    /// the passkey spare, where they were last opened, this Mac only) goes into the rows' info buttons. Only a state he
    /// must act on stays as a line (a problem in orange, items closed without being applied, an approval, a waiting item).
    static func savedPasswordsInfo(_ page: BackendCloudSecretsPage) -> String? {
        let lines = page.notSaved + page.openedOn + [page.spareMade, page.spareNote, page.spareReplaced].compactMap { $0 }
        return lines.isEmpty ? nil : lines.joined(separator: "\n\n")
    }
    static func askInfo(_ page: BackendCloudSecretsPage) -> String? {
        let lines = [page.askThisMacOnly ? BackendCloudSecretsWords.askThisMacOnly : nil,
                     page.askOffElsewhere ? BackendCloudSecretsWords.askStillOnHere : nil].compactMap { $0 }
        return lines.isEmpty ? nil : lines.joined(separator: "\n\n")
    }

    var body: some View {
        if let page = model.shown {
            DeckSettingsGroup("Saved passwords") {
                DeckSettingsRow("Saved passwords", info: Self.savedPasswordsInfo(page), state: BackendCloudSecretsWords.state(page)) {
                    control(page)
                }
                // The owner's stricter setting (off by default): its own row, shown where this Mac holds the key.
                if let ask = page.askOnNewDevice {
                    DeckSettingsToggleRow(BackendCloudSecretsWords.askMeSwitch, info: Self.askInfo(page),
                                          isOn: Binding(get: { ask }, set: { model.setAskOnNewDevice($0) }))
                    // 15 Nov: his phones get saved passwords and secret files by default; the stricter way, off by default.
                    if let phonesOff = page.phonesOff {
                        DeckSettingsToggleRow("Keep off my phones and browsers", info: BackendCloudSecretsWords.phonesOffSwitch + ".",
                                              isOn: Binding(get: { phonesOff }, set: { model.setPhonesOff($0) }))
                    }
                    // Project secret files (14 Nov): the stricter way, off by default, on this Mac only.
                    if let keep = model.keepProjectSecretsHere {
                        DeckSettingsToggleRow(BackendProjectSecretFilesWords.keepSwitch, info: BackendProjectSecretFilesWords.keepSwitchDetail,
                                              isOn: Binding(get: { keep }, set: { model.setKeepProjectSecretsHere($0) }))
                        if let line = model.keepProjectSecretsLine { DeckSettingsProblem(text: line) }
                    }
                }
                if let problem = page.problem ?? (page.turnOnFailed ? BackendCloudSecretsWords.stepNotFinished : nil) {
                    DeckSettingsProblem(text: problem)
                }
                ForEach(page.gaps, id: \.self) { gap in DeckSettingsProblem(text: gap) }
                // Items from another device that were closed here without being applied (lane V's count and reason).
                if !page.skipped.isEmpty {
                    DeckSettingsRow(page.skipped.first ?? "", info: page.skipped.count > 1 ? page.skipped.joined(separator: "\n\n") : nil) {
                        Button("OK") { model.dismissNotices() }
                    }
                }
                // PASSWORDS-5 point 4: a second passkey made here while the spare was being made, with the one repair.
                if let warning = page.spareWarning {
                    DeckSettingsRow(warning, stateColor: DeckTokens.warn) {
                        // The one repair (service 7750c816e): his press only.
                        if page.canRepairSpare { Button(BackendCloudSecretsWords.repairSpare) { model.repairSpare() } }
                    }
                }
                if page.spareMade == nil, page.canMakeSpare {
                    // Gap 2: while no spare exists and the passkey works here; his press only.
                    DeckSettingsRow("Passkey spare key") { Button(BackendCloudSecretsWords.makeSpare) { model.makeSpare() } }
                }
                ForEach(page.approvals) { approval in
                    DeckSettingsRow(BackendCloudSecretsWords.approval) {
                        Button("Review…") { model.perform(.openApproval, approvalId: approval.id) }
                    }
                }
                ForEach(page.waiting) { item in
                    DeckSettingsRow(item.title) {
                        HStack(spacing: DeckTokens.Spacing.s8) {
                            if !item.removed { Button("Add…") { model.addWaiting(item.id) } }
                            Button("Dismiss") { model.dismissWaiting(item.id) }
                        }
                    }
                }
            }
            .disabled(model.busy)
        }
    }
    /// The ONE control for the state, or none.
    enum Control: Equatable { case none, turnOn, startAgain, undoStartAgain, openWithPasskey, ask, askAgain, askOrWords, allowLoginStore, checkAgain }
    static func control(for page: BackendCloudSecretsPage) -> Control {
        if page.startingAgain { return .undoStartAgain }
        switch page.standing {
        case .notSetUp: return page.problem != nil || page.turnOnFailed ? .turnOn : .none
        case .locked, .startedAnew:
            // Slice 2: his passkey opens the copy that is there (nothing is lost), before any "Start again".
            if page.opensWithPasskey, page.cannotOpen || page.waitsForClick { return .openWithPasskey }
            if page.cannotOpen { return page.startAgainAvailable ? .startAgain : .none }
            if page.opensBySelf { return .none }
            return page.offersRecoveryWords ? .askOrWords : .ask
        case .waitingForCloud: return .askAgain
        case .loginStoreBlocked: return .allowLoginStore
        case .unknown, .cannotCheck: return .checkAgain
        // No "Allow login store": it cannot bring back a key that is gone. The ordinary unlock stays only while this
        // Mac holds no Cloud key and the account has saved passwords in Cloud (lane V S-A1).
        case .keyLost:
            guard !page.cloudKeyHere, page.cloudSetUp else { return .none }
            return page.offersRecoveryWords ? .askOrWords : .ask
        case .protected: return page.couldNotCheck ? .checkAgain : .none
        case .keyBlocked: return .none
        }
    }
    @ViewBuilder private func control(_ page: BackendCloudSecretsPage) -> some View {
        switch Self.control(for: page) {
        case .none: EmptyView()
        case .turnOn: Button("Turn on") { model.perform(.setup) }
        case .startAgain: Button("Start again") { model.startAgain() }
        case .undoStartAgain: Button(BackendCloudFilesWords.undo) { model.undoStartAgain() }
        case .openWithPasskey: Button(BackendCloudSecretsWords.openWithPasskey) { model.perform(.openWithPasskey) }
        case .ask: Button("Ask another device") { model.perform(.requestDevice) }
        case .askAgain: Button("Ask another device again") { model.perform(.requestDevice) }
        case .askOrWords:
            Menu("Open") {
                Button("Ask another device") { model.perform(.requestDevice) }
                Button("Use recovery words") { model.perform(.recover) }
            }
            .fixedSize()
        case .allowLoginStore: Button("Allow login store") { model.allowLoginStore() }
        case .checkAgain: Button("Check again") { model.reload(fresh: "your press") }
        }
    }
}

/// Whether saved passwords are part of this run. Switched on for 0.22.0 after proof P3 (the same rule as the memory
/// rows); they still run only for a signed-in, allow-listed account. In a debug build the scratch plan can only add.
enum NativeCloudSecretsSwitch {
    static let proven = true
    /// Owner's decision (14 Nov): a new device of his account gets the key from any of his online devices with no
    /// code and no click. ON since the service keeps and returns the requesting device's signature (td-cloud 2fb865f1)
    /// and the review's four conditions hold (PASSWORDS-2). The kill switch: false = the clicked comparison with its
    /// codes, exactly as before, and no "Start again".
    static let automaticHandOver = true
    static var on: Bool { proven || NativeCloudScratch.active?.passwords == true }
}

/// Keys travel (Security seat, 15 Nov 2026): the API-account service, set where the session host's sign-in owner is made
/// (one line there); read each time saved passwords ask, so a reconnect's new service is used.
@MainActor
enum NativeCloudKeysOwners {
    /// 15 Nov fix: until it is set the API store answers "locked" (ask again shortly). Before, nothing asked again:
    /// the start-up save that ran before the session helper connected stayed failed ("Some saved items are not in
    /// Cloud") and the API keys reached the sealed list only on the 10-minute rhythm. Now its arrival saves the
    /// saved passwords again and runs the sealed round at once.
    static var apiAccounts: BackendAPIAccountService? {
        didSet {
            guard apiAccounts != nil, oldValue !== apiAccounts else { return }
            NativeCloudKeysOwners.ownerReady()
        }
    }
    static func ownerReady() {
        let graph = NativeCloudSecrets.shared.graph
        Task {
            await graph?.syncNow()
            await MainActor.run { NativeCloudShelf.shared.sealedSoon() }
        }
    }
}

/// The app's live owners handed to saved passwords (lane V's wiring, "Lean first version"). Keys travel (15 Nov 2026):
/// `api`, `tasks`, `receiver` and `mcp-user` are bound too, each under the delete rule. Bound before that:
/// `servers` (server passwords and saved SSH keys, each with its server) and `voice`. NOT bound: `mcp-user` (its
/// source reads the person's real Claude Code settings, so proof P3 cannot run it; it needs the clients
/// composition's own writer), `api`, `ssh`, `tasks`, `receiver` (lane V: no owner that can be bound). Each of
/// those is named as not saved on the page and in the tool.
@MainActor
enum NativeCloudSecretsOwners {
    static func live(appName: String, production: NativeCompositionProduction) throws -> NativeCloudSecretsLive? {
        // Without the Servers owner there is no source this version can save: saved passwords stay absent.
        guard let servers = production.serversOwner else { return nil }
        let root = production.root, configuration = production.configuration
        let voice = production.osServices?.voice
        let requireWriter: @Sendable () throws -> Void = { [root] in
            guard root.state.ownership == .exclusive else {
                throw NativeRPCError(code: "read-only", message: "This copy of the app cannot change saved passwords.")
            }
        }
        // Lane V's logical store over the Servers owner's ONE live credentials object and server list.
        let port = servers.cloudSecrets(sourceId: "servers")
        let keys = BackendAccountVaultRecovery(configuration: configuration).cloudLocalKeyOwner()
        let dataRoot = root.dataRoot
        // Project secret files (14 Nov): one more store inside saved passwords (its own domain `project`).
        let secretFiles = NativeProjectSecretFiles.store(production: production, dataRoot: dataRoot, requireWriter: requireWriter)
        // Tasks everywhere (15 Nov): connected task systems' tokens, in the existing task-connection store, sealed like
        // every saved password. Only into a connection this Mac has (the connection itself travels with the tasks).
        let connected = NativeCloudRecordsOwners.connectedTasks
        // Keys travel: API accounts (read when asked), the Receiver's store, and his user-scope MCP servers.
        let apiOwner = BackendCloudKeysLateAPIOwner { await MainActor.run { NativeCloudKeysOwners.apiAccounts } }
        let mcpClaude = production.clients?.mcpClients.map { BackendCloudSecretsClaudeMCP(writer: $0.writer) }
        // Review fix 1 (Decker): a Remove pressed in the app for an API account, MCP server, task token or Receiver source
        // goes through that kind's delete owner: everywhere, in the Bin 30 days, no question.
        BackendCloudKeysRemovals.shared.set { source, id in
            guard let graph = await MainActor.run(body: { NativeCloudSecrets.shared.graph }),
                  let owner = await graph.deleteOwner(sourceId: source) as? BackendProjectSecretFilesSavedDeleteOwner,
                  await owner.canDeleteEverywhere(),
                  let item = try await owner.items().first(where: { $0.id == id }) else { return false }
            let actor = await NativeCloudDeleteNames.personActor()
            _ = try await graph.deleteItems(sourceId: source, items: [item], scope: .everywhere, by: actor)
            return true
        }
        let thisMac: @Sendable () async -> String? = { NativeProjectSecretFiles.deviceName() }
        return NativeCloudSecretsLive(
            keyStore: try NativeCloudSecretsLive.keychain(appName: appName),
            window: { NSApp?.keyWindow ?? NSApp?.mainWindow },
            stores: { _ in
                // Delete rule (L3): saved passwords and the voice key get their sealed Bin (names and dates only).
                let deleteRoot = NativeProjectSecretFiles.stateRoot(dataRoot)   // inside the denied project-secret-files folder
                let deleteGate: @Sendable () async -> Bool = { await NativeProjectSecretFiles.deleteRuleGate() }
                let macName: @Sendable (String) async -> String? = { await NativeProjectSecretFiles.macName($0) }
                let clock: @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) }
                // The sealed Bin ages only on the service clock (never early on a Mac clock that is ahead).
                let serviceClock: @Sendable () async -> Int64? = { await NativeProjectSecretFiles.deleteIdentity()?.at }
                var stores: [any CloudSecretsLogicalStore] = [port.deleteRuleStore(stateRoot: deleteRoot, gate: deleteGate, macName: macName, serviceClock: serviceClock, now: clock)]
                if let voice { stores.append(BackendCloudSecretsSavedDeleteOwners.voice(voice, stateRoot: deleteRoot, gate: deleteGate, macName: macName, serviceClock: serviceClock, now: clock)) }
                stores.append(secretFiles)
                if let connected {
                    let tokens = BackendCloudSecretsTaskStore(sourceId: "tasks", tokens: connected.cloudTokens,
                        connectionIds: { try await connected.cloudConnectionIDs() },
                        insertIfAbsent: { id, token in try await connected.cloudInsertTokenIfAbsent(id, token) },
                        names: { try await connected.cloudConnectionNames() })
                    stores.append(BackendCloudKeysTasks.deleteRuleStore(tokens, stateRoot: deleteRoot, gate: deleteGate,
                        remove: { id, token in try await connected.cloudRemoveTokenIfSame(id, token) },
                        macName: macName, serviceClock: serviceClock, now: clock))
                }
                // Review fix D: this Mac's id and name, so the id it gave up when two Macs agreed on one leaves Cloud.
                let apiIdentity = BackendCloudKeysVanished.identityOnly(device: { await NativeProjectSecretFiles.deleteIdentity()?.mac },
                                                                        deviceName: { NativeProjectSecretFiles.deviceName() })
                stores.append(BackendCloudKeysAPIStore(owner: apiOwner, stateRoot: deleteRoot, thisMac: thisMac)
                    .deleteRuleStore(stateRoot: deleteRoot, gate: deleteGate, macName: macName, serviceClock: serviceClock, vanished: apiIdentity, now: clock))
                stores.append(BackendCloudKeysReceiverStore(store: { await BackendRCVCompositionBox.shared.cloudStore() })
                    .deleteRuleStore(stateRoot: deleteRoot, gate: deleteGate, macName: macName, serviceClock: serviceClock, now: clock))
                // Keys travel, part 2: what each SSH-settings server needs; copies kept in the app's own folder (inside the
                // saved passwords' denied state folder), never in his SSH folder.
                if let sshKeys = servers.cloudSSHKeys(folder: BackendCloudKeysSSHFolder(root: deleteRoot.appendingPathComponent("ssh-travelled", isDirectory: true))) {
                    stores.append(sshKeys.deleteRuleStore(stateRoot: deleteRoot, gate: deleteGate, macName: macName, serviceClock: serviceClock, now: clock))
                }
                if let mcpClaude, let mcp = try? BackendCloudSecretsMCPStore.travelling(claude: mcpClaude, thisMac: thisMac,
                                                                                      requireWriter: requireWriter) {
                    // Review fix 1: `claude mcp remove` outside the app: an AI session's = everywhere, his own = this Mac only.
                    // Review N1: by an AI only when the witness saw that session's own `claude mcp remove <this name>`; a write
                    // to the settings file (Claude Code rewrites it all the time) or anything unclear = his hand.
                    let vanished = BackendCloudKeysVanished(who: { id, seen, gone in
                        await CloudDeleteWitnessSlot.shared.who(removed: URL(fileURLWithPath: BackendAIDeleteWitness.mcpUserServerPath(id)),
                            lastSeen: Date(timeIntervalSince1970: Double(seen) / 1000), seenGoneAt: Date(timeIntervalSince1970: Double(gone) / 1000))
                    }, device: { await NativeProjectSecretFiles.deleteIdentity()?.mac }, deviceName: { NativeProjectSecretFiles.deviceName() })
                    stores.append(mcp.deleteRuleStore(stateRoot: deleteRoot, gate: deleteGate, macName: macName, serviceClock: serviceClock,
                                                      vanished: vanished, now: clock))
                }
                // WhatsApp agents' keys (15 Nov): store "whatsapp", one record per agent, named as he named it.
                stores.append(BackendWhatsAppKeysStore(keeper: NativeWhatsAppEngineBox.shared.keeper(appName: appName), names: { id in
                    await NativeWhatsAppEngineBox.shared.engine?.agents().first { $0.id == id }?.name
                }).deleteRuleStore(stateRoot: deleteRoot, gate: deleteGate, macName: macName, serviceClock: serviceClock, now: clock))
                BackendProjectSecretFilesHolder.shared.store = secretFiles
                return stores
            },
            localStores: { policy in
                BackendCloudRecoveryLocalStores.lean(configuration: configuration, keys: keys, policy: policy, servers: port, voice: voice,
                                                     requireWriter: requireWriter)
            },
            conflicts: BackendCloudSecretsConflicts(dataRoot: dataRoot, requireWriter: requireWriter),
            known: BackendCloudSecretsKnown(dataRoot: dataRoot, requireWriter: requireWriter),
            changes: { changed in
                // The Servers owner tells after each saved or forgotten sign-in. The voice key has no signal of its
                // own: it is captured at start, on "Sync now" and whenever the sync core reconnects.
                port.observe { changed("servers") }
                // A connected task system's token saved here is taken at once.
                if let connected { Task { await connected.setTokenSaved { changed("tasks") } } }
                // A WhatsApp key added or replaced here is taken at once.
                NativeWhatsAppEngineBox.shared.setKeysChanged { changed(BackendWhatsAppKeysStore.source) }
                // Project secret files have no change signal: a look every 10 minutes (plus start and Sync now).
                let looks = NativeProjectSecretFiles.looks(changed)
                // Keys travel: API keys, Receiver secrets and MCP servers have no change signal here either; the same
                // 10-minute look (plus start, Sync now and every reconnect) takes them.
                let keyLooks = Task.detached(priority: .utility) {
                    while !Task.isCancelled {
                        try? await Task.sleep(nanoseconds: 600 * 1_000_000_000)
                        guard !Task.isCancelled else { return }
                        for source in ["api", "receiver", "mcp-user", "ssh", BackendWhatsAppKeysStore.source] { changed(source) }
                    }
                }
                return {
                    port.observe(nil); looks.cancel(); keyLooks.cancel()
                    NativeWhatsAppEngineBox.shared.setKeysChanged(nil)
                    if let connected { Task { await connected.setTokenSaved(nil) } }
                }
            })
    }
}
