import SwiftUI
import TerminalDeckBackend
import TerminalDeckNativeCore

/// App-wide coding AI settings. Servers and devices keep their own settings.
struct NativeCodingAISettings: View {
    @State private var store = NativeCodingAIStore.shared
    @State private var hooks = HooksScreenModel()
    @Environment(\.openWindow) private var openWindow
    @Environment(\.controlActiveState) private var activeState
    private let app = AppModel.shared

    var body: some View {
        // Read here so the page follows it: a sign-in that could not start (no sheet is up for it).
        let signInProblem = NativeAccountSignInModel.shared.active == nil ? NativeAccountSignInModel.shared.problem : nil
        let ownLogin = NativeAccountSignInModel.shared.confirmingOwnLogin
        let ownAI = CodingAICatalog.label(ownLogin?.provider ?? "claude")
        Group {
            if app.engineIsUp {
                DeckSettingsScaffold(title: "Coding AIs") {
                    NativeCodingAIThisMachine(store: store, hooks: hooks)
                }
            } else {
                ContentUnavailableView("Terminal Deck isn't running",
                                       systemImage: "exclamationmark.triangle",
                                       description: Text("Use Try Again in the main window."))
            }
        }
        .onAppear {
            store.scope = .thisMachine
            store.refreshAll()
        }
        .task { if app.engineIsUp { await hooks.refresh() } }
        .onDisappear { store.screenLeft(); NativeChatAccountFocus.shared.provider = nil }
        .onChange(of: app.engineIsUp) { _, up in
            if up {
                store.refreshAll()
                Task { await hooks.refresh() }
            }
        }
        .onChange(of: activeState) { _, state in
            if state == .key {
                store.windowCameForward()
                Task { await hooks.refresh() }
            }
        }
        .onChange(of: store.mainWindowRequest) { _, _ in
            let open = openWindow
            NativeFront.whenPersonActs("main") { open(id: "main") }
        }
        .sheet(isPresented: $store.addingPresented) {
            NativeCodingAIAddAccountSheet(store: store)
        }
        // The progress of a sign-in started here (Add account, Sign in, Sign in again).
        .sheet(item: Bindable(NativeAccountSignInModel.shared).active) { _ in
            NativeAccountSignInSheet(model: NativeAccountSignInModel.shared, accounts: store.snapshot.accounts)
        }
        // 4 Nov: Sign in on this Mac's own login opens the AI's own sign-in in the browser (never a new chat), after
        // saying plainly that it is the Mac's login, which the Terminal uses too.
        .confirmationDialog("Sign in to \(ownAI) on this Mac?",
                            isPresented: Binding(get: { ownLogin != nil }, set: { if !$0 { NativeAccountSignInModel.shared.confirmingOwnLogin = nil } }),
                            titleVisibility: .visible) {
            Button("Sign In on This Mac") { NativeAccountSignInModel.shared.confirmOwnLogin() }
            Button("Cancel", role: .cancel) { NativeAccountSignInModel.shared.confirmingOwnLogin = nil }
        } message: {
            Text("This is \(ownAI)’s own login on this Mac, not one Terminal Deck keeps. Your browser opens \(ownAI)’s sign-in page. The account you approve there is used by your Terminal and every app that uses \(ownAI) on this Mac, and by the sessions here that use this login.")
        }
        // A sign-in that could not start says why and what to do (11 Oct, item 25: it said nothing).
        .alert("The sign-in was not started",
               isPresented: Binding(get: { signInProblem != nil }, set: { if !$0 { NativeAccountSignInModel.shared.problem = nil } })) {
            // CONNECT-SKILLS: the AI is not installed. Install it here, then the same sign-in starts again.
            if let tool = signInProblem.flatMap(NativeAIToolInstallModel.missingTool(in:)) {
                Button("Install \(CodingAICatalog.label(tool))") {
                    let again = NativeAccountSignInModel.shared.retry
                    NativeAccountSignInModel.shared.problem = nil
                    NativeAIToolInstallModel.shared.install(tool) {
                        if let again { again() } else { NativeAIToolInstallModel.continueToSignIn(tool) }
                    }
                }
                Button("Not now", role: .cancel) { NativeAccountSignInModel.shared.problem = nil }
            } else {
                Button("OK") { NativeAccountSignInModel.shared.problem = nil }
            }
        } message: { Text(signInProblem ?? "") }
    }
}

/// Settings › Coding AIs (owner, 15 Nov; DESIGN.md section 6): one group per INSTALLED AI, titled with its mark and
/// name (version in the info). Rows: each account by its name with its state dot, plan and "…" menu; "+ Add account";
/// then Live status, Default model, Default effort. "Which account agents use ›" opens the long list on its own page,
/// and a signed-out login is said once, on its own account row.
struct NativeCodingAIThisMachine: View {
    @Bindable var store: NativeCodingAIStore
    let hooks: HooksScreenModel
    @State private var renamingId: String?
    @State private var renameText = ""
    @State private var removing: CodingAIAccount?
    /// FINAL-CONNECT (row 35): the model and effort new sessions really start with (Settings › Agents).
    @State private var agentDefaults: AGSDefaults?
    @Environment(\.deckSettingsOpen) private var open

    var body: some View {
        if let error = store.sectionError ?? store.failure ?? store.accountsError {
            DeckSettingsGroup { DeckSettingsProblem(text: error) }
        }
        if let error = hooks.error {
            DeckSettingsGroup {
                DeckSettingsRow(error, stateColor: DeckTokens.warn) {
                    DeckRetryButton("Try again", autoRetry: true) { Task { await hooks.refresh() } }
                }
            }
        }
        if store.prerequisites == nil, store.sectionError == nil {
            DeckSettingsGroup {
                ForEach(0..<2, id: \.self) { _ in DeckSettingsRow("Coding AI", state: "Signed in").redacted(reason: .placeholder) }
            }
            .accessibilityLabel("Reading installed coding AIs")
        }
        if let focused = NativeChatAccountFocus.shared.provider {
            DeckSettingsGroup {
                DeckSettingsRow("Chat account · " + CodingAICatalog.label(focused)) {
                    Button("Show all") { NativeChatAccountFocus.shared.provider = nil }
                }
            }
        }
        NativeAccountVaultRecovery(store: store)

        ForEach(Self.installed(store.prerequisites?.agentsPresent ?? [], focus: NativeChatAccountFocus.shared.provider)) { tool in
            providerGroup(tool)
        }
        if store.accountsLoaded {
            DeckSettingsGroup {
                DeckSettingsLinkRow(title: Self.whichAccountTitle) { open(NativeSettingsNavigation.whichAccountID) }
            }
        }
        if let prerequisites = store.prerequisites, NativeChatAccountFocus.shared.provider == nil {
            let missing = CodingAICatalog.lookup.filter { agent in !prerequisites.agentsPresent.contains(where: { $0.id == agent.id }) }
            if !missing.isEmpty {
                // Never a group for an AI that is not installed: one row offers the install (then its sign-in).
                DeckSettingsGroup {
                    DeckSettingsRow(Self.installAnotherTitle,
                                    state: missing.contains { NativeAIToolInstallModel.shared.progress[$0.id]?.state == "running" } ? "Installing…" : nil) {
                        Menu("Install") {
                            ForEach(missing) { agent in
                                Button(agent.label) {
                                    NativeAIToolInstallModel.shared.install(agent.id) { NativeAIToolInstallModel.continueToSignIn(agent.id) }
                                }
                            }
                        }
                        .fixedSize()
                    }
                }
            }
        }
        if !store.staleAgents.isEmpty {
            DeckSettingsGroup("Updates") {
                ForEach(store.staleAgents.filter { !ReadinessDismissed.isDismissed(store.dismissed, scope: ReadinessDismissed.machineScope, id: $0.dismissalId) }) { row in
                    DeckSettingsRow([row.command, row.version ?? ""].filter { !$0.isEmpty }.joined(separator: " ") + " is too old to sign in",
                                    info: row.advicePieces.map { $0.text }.joined(), stateColor: DeckTokens.warn) {
                        Menu(store.upgrading == row.command ? "Upgrading…" : "Upgrade it") {
                            Button("Upgrade it") { store.upgrade(row) }
                            Button("Dismiss") { store.dismiss(row) }
                        } primaryAction: { store.upgrade(row) }
                        .fixedSize().disabled(store.upgrading == row.command)
                    }
                    if let result = store.upgradeResults[row.command], !result.ok { DeckSettingsProblem(text: result.message) }
                }
                let hidden = store.staleAgents.count - store.staleAgents.filter { !ReadinessDismissed.isDismissed(store.dismissed, scope: ReadinessDismissed.machineScope, id: $0.dismissalId) }.count
                if hidden > 0 {
                    DeckSettingsButtonRow(title: "Show dismissed updates", info: ReadinessDismissed.hiddenLine(hidden)) { store.bringBackDismissed() }
                }
            }
        }
        if let line = store.setupError ?? store.setupWarning {
            DeckSettingsGroup { DeckSettingsProblem(text: line) }
        }
    }

    static let whichAccountTitle = "Which account agents use"
    /// SP-1 (15 Nov): "Default model" names the real model ("Fable 5.2"): the one chosen in Settings › Agents, else
    /// the AI's own default. "Default" only while neither is known.
    static func defaultModelWords(chosen: String?, cliDefault: String?) -> String {
        let id = NativeLandingModels.usable(chosen) ?? NativeLandingModels.usable(cliDefault)
        return id.map { NativeLandingModels.name($0.split(separator: ":").last.map(String.init) ?? $0) } ?? "Default"
    }
    static let installAnotherTitle = "Another coding AI"

    /// The AIs that get a group: installed ones only, in the app's order (a chat's focus shows its AI alone).
    static func installed(_ present: [CodingAITool], focus: String?) -> [CodingAITool] {
        present.filter { focus == nil || $0.id == focus }
    }

    private func providerGroup(_ tool: CodingAITool) -> some View {
        let provider = store.providerRows.first { $0.id == tool.id }
        let accounts = store.displayedAccounts.filter { $0.provider == tool.id }
        let chosen = agentDefaults?.providers[tool.id]
        return VStack(alignment: .leading, spacing: DeckSettingsLook.groupTitleGap) {
            NativeCodingAIGroupTitle(provider: tool.id, title: tool.label,
                                     info: [tool.versionLabel, tool.note, provider?.canAdd == true ? nil : provider?.note]
                                        .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n\n"))
            DeckSettingsGroup {
                if store.accountsLoading && accounts.isEmpty {
                    DeckSettingsRow("Reading accounts…").redacted(reason: .placeholder)
                }
                ForEach(accounts) { account in
                    NativeCodingAIAccountRow(store: store, account: account, model: store.row(account),
                                             renamingId: $renamingId, renameText: $renameText, removing: $removing)
                }
                if provider?.canAdd == true {
                    DeckSettingsButtonRow(title: "+ Add account") { store.askForAddAccount(tool.id) }.disabled(store.busy)
                } else if accounts.isEmpty, provider?.canSignIn == true {
                    DeckSettingsButtonRow(title: "Sign in") { store.signInInstall(tool.id) }
                        .disabled(store.busy || (!store.canStartSessions && !CodingAILogins.appSignsIn(tool.id)))
                }
            }
            Color.clear.frame(height: DeckSettingsLook.groupGap - DeckSettingsLook.groupTitleGap)
            DeckSettingsGroup {
                NativeLiveStatusRow(providerId: tool.id, model: hooks)
                DeckSettingsLinkRow(title: "Default model", value: Self.defaultModelWords(chosen: chosen?.model, cliDefault: NativeLandingModels.cliDefault(tool.id).model)) {
                    NativeAGSPageChoice.shared.provider = tool.id; open("agent-defaults")
                }
                DeckSettingsLinkRow(title: "Default effort", value: chosen?.effort.flatMap { $0.isEmpty ? nil : NativeAGSWords.option($0) } ?? "Default") {
                    NativeAGSPageChoice.shared.provider = tool.id; open("agent-defaults")
                }
            }
            .task { if agentDefaults == nil { agentDefaults = await Self.readAgentDefaults() } }
        }
    }

    /// Settings › Agents' saved defaults (the same read its page makes).
    private static func readAgentDefaults() async -> AGSDefaults? {
        guard let raw = try? NativeRPCValue.fromFoundation(await EngineBridge.shared.invoke("ags:get", [NSNull()])),
              let data = try? raw["defaults"].encodedJSON() else { return nil }
        return try? JSONDecoder().decode(AGSDefaults.self, from: data)
    }
}

/// A coding AI's group title: its mark and name, 13 pt semibold, with its version behind the (i).
struct NativeCodingAIGroupTitle: View {
    let provider: String
    let title: String
    var info: String = ""
    var body: some View {
        HStack(spacing: DeckSettingsLook.infoGap) {
            NativeCodingAIProviderMark(provider: provider, size: DeckSettingsLook.groupMark)
            Text(title).font(DeckSettingsLook.groupTitle).foregroundStyle(.primary)
            if !info.isEmpty { DeckSettingsInfoButton(label: title, text: info) }
        }
        .padding(.horizontal, DeckSettingsLook.rowPadding)
        .accessibilityAddTraits(.isHeader)
    }
}

/// "Live status" as one kit row: the switch, its explanation in the (i); a state he must act on in orange at the
/// right ("Fix it" when the hook is stale or partial). Same actions as `NativeLiveStatusSetting`.
struct NativeLiveStatusRow: View {
    let providerId: String
    let model: HooksScreenModel
    @State private var confirmingRemoval = false
    private var status: HookProviderStatus? { model.statuses?.first { $0.id == providerId } }

    var body: some View {
        let needsFix = status.map { $0.state == .stale || $0.state == .partial } ?? false
        let failed = model.results[providerId].flatMap { $0.ok || $0.message.isEmpty ? nil : $0.message }
        let deaf = model.server.map { !$0.running } ?? false
        DeckSettingsRow("Live status", info: info,
                        state: model.busy == providerId ? "Updating…" : needsFix ? HooksRules.stateLabel(status!.state) : deaf ? "Not listening" : failed != nil ? "Did not finish" : nil,
                        stateColor: needsFix || deaf || failed != nil ? DeckTokens.warn : .secondary) {
            HStack(spacing: DeckTokens.Spacing.s8) {
                if needsFix {
                    Button("Fix it") { Task { await model.install(providerId) } }.disabled(model.busy != nil)
                }
                Toggle("Live status", isOn: Binding(get: { status.map(HooksRules.canRemove) ?? false }, set: change))
                    .toggleStyle(.switch).controlSize(.small)
                    .disabled(status == nil || status?.state == .error || model.busy != nil)
            }
        }
        .contextMenu {
            if let status, status.state == .complete {
                Button("Set up again") { Task { await model.install(providerId) } }.disabled(model.busy != nil)
            }
            Button("Refresh") { Task { await model.refresh() } }.disabled(model.refreshing)
        }
        .alert("Turn off live status?", isPresented: $confirmingRemoval) {
            Button("Cancel", role: .cancel) {}
            Button("Turn off", role: .destructive) { Task { await model.remove(providerId) } }
        } message: {
            if let status { Text(HooksRules.removalPromise(file: status.file, backupPath: status.backupPath)) }
        }
    }

    private var info: String {
        var lines = ["Lets its tabs show Working, Waiting for you or Done."]
        if let status {
            lines.append(status.state == .error && !status.message.isEmpty ? status.message : HooksRules.consequence(status.state))
            if let foreign = HooksRules.foreignNote(status) { lines.append(foreign) }
            lines.append(HooksRules.writesFile(status.file))
        } else if model.error == nil {
            lines.append(model.statuses == nil ? "Reading live status…" : "Live status is unavailable for this AI.")
        }
        if let server = model.server, !server.running { lines.append(HooksRules.endpointLine(server)) }
        if let result = model.results[providerId], !result.message.isEmpty { lines.append(result.message) }
        return lines.joined(separator: "\n\n")
    }

    private func change(_ enabled: Bool) {
        guard let status, status.state != .error, model.busy == nil else { return }
        if enabled { Task { await model.install(providerId) } }
        else if HooksRules.canRemove(status) { confirmingRemoval = true }
    }
}
