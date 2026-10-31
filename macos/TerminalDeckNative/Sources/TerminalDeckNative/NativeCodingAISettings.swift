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
        Group {
            if app.engineIsUp {
                NativeSettingsPage(sectionId: "agents") {
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

struct NativeCodingAIThisMachine: View {
    @Bindable var store: NativeCodingAIStore
    let hooks: HooksScreenModel
    @State private var renamingId: String?
    @State private var renameText = ""
    @State private var removing: CodingAIAccount?
    /// FINAL-CONNECT (row 35): the model and effort new sessions really start with (Settings › Agents), read-only here.
    @State private var agentDefaults: AGSDefaults?

    var body: some View {
        if let error = store.sectionError ?? store.failure ?? store.accountsError {
            Section { NativeCodingAINotice(tone: .error, text: error) }
        }
        if let error = hooks.error {
            Section {
                NativeCodingAINotice(tone: .error, text: error)
                DeckRetryButton("Try again", autoRetry: true) { Task { await hooks.refresh() } } // autoRetry: re-reads the live-status state
                    .buttonStyle(.bordered)
            }
        }

        if store.prerequisites == nil, store.sectionError == nil {
            Section {
                ForEach(0..<3, id: \.self) { _ in
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Coding AI").font(.headline)
                        Text("Accounts and live status").font(.callout)
                    }
                    .redacted(reason: .placeholder)
                    .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
                }
            }
            .accessibilityLabel("Reading installed coding AIs")
        }

        if let focused = NativeChatAccountFocus.shared.provider {
            Section { HStack { Text("Chat account · " + CodingAICatalog.label(focused)); Spacer(); Button("Show all Coding AIs") { NativeChatAccountFocus.shared.provider = nil } } }
        }
        Section { NativeAccountVaultRecovery(store: store) }

        ForEach((store.prerequisites?.agentsPresent ?? []).filter { NativeChatAccountFocus.shared.provider == nil || $0.id == NativeChatAccountFocus.shared.provider }) { tool in
            providerSection(tool)
        }
        if let prerequisites = store.prerequisites {
            let missing = CodingAICatalog.lookup.filter { agent in
                !prerequisites.agentsPresent.contains(where: { $0.id == agent.id }) && (NativeChatAccountFocus.shared.provider == nil || agent.id == NativeChatAccountFocus.shared.provider)
            }
            if !missing.isEmpty {
                Section("More coding AIs") {
                    ForEach(missing) { agent in
                        // CONNECT-SKILLS: installs here with one click (no terminal), then goes on to sign-in.
                        NativeSettingRow(label: agent.label, help: BackendAIToolInstallText.missing(agent.label)) {
                            NativeAIToolInstallButton(tool: agent.id)
                        }
                    }
                }
            }
        }
        // ACCOUNTS-SPEC §4: the one place that says who uses which account. (11 Oct: it had been
        // added to an accounts view this page no longer uses, so it was never on screen.) Never
        // left out once the accounts are read: with an older background helper it shows read-only
        // and says why.
        if store.accountsLoaded {
            NativeAccountLevelsSection(accounts: store.snapshot.accounts, signIns: store.signIn,
                                       signedOut: Set(store.signIn.filter { $0.value.state == .signedOut }.keys),
                                       defaultID: store.snapshot.defaultId)
        }
        if !store.staleAgents.isEmpty {
            Section("Updates") { NativeCodingAIStaleAgents(store: store) }
        }
        if store.setupWarning != nil || store.setupError != nil {
            Section {
                if let error = store.setupError { NativeCodingAINotice(tone: .error, text: error) }
                if let warning = store.setupWarning { NativeCodingAINotice(tone: .warn, text: warning) }
            }
        }
    }

    private func providerSection(_ tool: CodingAITool) -> some View {
        let provider = store.providerRows.first { $0.id == tool.id }
        let accounts = store.displayedAccounts.filter { $0.provider == tool.id }
        return Section {
            NativeSettingRow(label: "Accounts", help: "Sign-ins this AI can use.") {
                if provider?.canAdd == true {
                    Button("Add account") { store.askForAddAccount(tool.id) }
                        .buttonStyle(.bordered)
                        .disabled(store.busy)
                } else if let note = provider?.note {
                    NativeCodingAIInfo(label: "Accounts", text: note)
                }
            }
            if store.accountsLoading && accounts.isEmpty {
                Text("Reading accounts…").foregroundStyle(.secondary)
            } else if accounts.isEmpty {
                HStack {
                    Text("No accounts yet.").foregroundStyle(.secondary)
                    Spacer()
                    if provider?.canSignIn == true {
                        Button("Sign in") { store.signInInstall(tool.id) }
                            .buttonStyle(.bordered)
                            .disabled(store.busy || !store.canStartSessions)
                    }
                }
            } else {
                ForEach(accounts) { account in
                    NativeCodingAIAccountRow(store: store, account: account,
                                             model: store.row(account),
                                             renamingId: $renamingId,
                                             renameText: $renameText,
                                             removing: $removing)
                }
            }
            NativeLiveStatusSetting(providerId: tool.id, model: hooks)
            // These always said "AI default" though Settings › Agents sets both for new sessions.
            let chosen = agentDefaults?.providers[tool.id]
            NativeSettingRow(label: "Default model", more: defaultNote) {
                HStack(spacing: 8) {
                    Text(chosen?.model.flatMap { $0.isEmpty ? nil : $0 } ?? "The AI's own default").foregroundStyle(.secondary)
                    Button("Change in Agents…") { AppModel.shared.selectSettingsSection("agent-defaults") }.buttonStyle(.link)
                }
            }
            NativeSettingRow(label: "Default effort", more: defaultNote) {
                Text(chosen?.effort.flatMap { $0.isEmpty ? nil : NativeAGSWords.option($0) } ?? "The AI's own default").foregroundStyle(.secondary)
            }
            .task { if agentDefaults == nil { agentDefaults = await Self.readAgentDefaults() } }
        } header: {
            HStack(spacing: 6) {
                NativeCodingAIProviderMark(provider: tool.id, size: 13)
                Text(tool.label)
                Spacer()
                if let version = tool.versionLabel {
                    Text(version).font(.caption).foregroundStyle(.secondary)
                        .help(tool.note ?? version)
                }
            }
        }
    }

    private var defaultNote: String {
        "What new sessions and agents start with, set in Settings › Agents. Nothing set there: the AI's own default."
    }

    /// Settings › Agents' saved defaults (the same read its page makes).
    private static func readAgentDefaults() async -> AGSDefaults? {
        guard let raw = try? NativeRPCValue.fromFoundation(await EngineBridge.shared.invoke("ags:get", [NSNull()])),
              let data = try? raw["defaults"].encodedJSON() else { return nil }
        return try? JSONDecoder().decode(AGSDefaults.self, from: data)
    }
}
