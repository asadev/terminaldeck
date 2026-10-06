import SwiftUI
import TerminalDeckNativeCore

// The account chip on a session's bar (`AccountChip.tsx`) and its two cousins
// for a session somewhere else (`MachineAccountChip.tsx`, `ServerAccountChip.tsx`).
// The page still owns what a press starts — a new session, a switch (with lane S's
// native confirm), a new server terminal, Settings → Accounts — through its
// commands; these read the accounts and draw the menu.

private struct ChipChevron: View {
    var body: some View {
        Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold)).foregroundStyle(.secondary)
    }
}

/// `folder-chip-button account-chip-button`.
private struct AccountChipLabel<Content: View>: View {
    @ViewBuilder let content: () -> Content
    var body: some View {
        HStack(spacing: 5) {
            content()
            ChipChevron()
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .padding(.horizontal, 4)
        .padding(.vertical, 2)
        .contentShape(.rect)
    }
}

/// One row of an account menu: the tick, the account's colour, its agent and its login.
private struct AccountRowLine: View {
    let current: Bool
    let color: String?
    let provider: String?
    let login: String
    var state: String?

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "checkmark").font(.caption.weight(.semibold)).opacity(current ? 1 : 0).frame(width: 12)
            NativeCodingAIDot(token: color)
            NativeCodingAIProviderMark(provider: provider, size: 13)
            Text(login).lineLimit(1).truncationMode(.middle).help(login)
            Spacer(minLength: 12)
            if let state { Text(state).font(.caption).foregroundStyle(.secondary) }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .contentShape(.rect)
    }
}

private struct MenuHead: View {
    let text: String
    var note: (label: String, text: String)?
    var body: some View {
        HStack(spacing: 4) {
            Text(text).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            if let note { NativeCodingAIInfo(label: note.label, text: note.text) }
        }
        .padding(.horizontal, 8)
        .padding(.top, 4)
    }
}

// MARK: - A session on this Mac

/// `AccountChip`: which account the session runs as (read off the agent itself),
/// and a menu of this Mac's accounts — picking one switches this session to it
/// where that can be done, else opens a new session on it; each row renames in
/// place; "Add account" at the foot. A shell with no agent in it gets "Run …".
struct NativeLocalAccountChip: View {
    let session: NativeTerminalSession

    @State private var snapshot = CodingAIAccountsSnapshot.empty
    @State private var signIn: [String: CodingAISignIn] = [:]
    @State private var loading = true
    @State private var error: String?
    @State private var established: SessionAccountView?
    @State private var armed: ArmedSwitch?
    @State private var open = false
    @State private var editing: (id: String, draft: String)?
    @State private var failure: String?
    @State private var saving = false
    @State private var subscriptions: [EngineSubscription] = []

    private var info: TerminalSessionInfo? { session.info }
    private var agentRunning: Bool? { session.controlsState.agentRunning }
    /// The agent a new session here would run (`general.defaultProvider`).
    private var defaultProvider: String? { NativeSettingsValues.shared.string("general.defaultProvider").nilIfEmpty }

    var body: some View {
        let mode = AccountChipRules.mode(hasSession: true, agentRunning: agentRunning)
        Group {
            switch mode {
            case .run:
                if let run = AccountChipRules.runCommand(defaultProvider) { runButton(run) }
            case .account:
                accountChip
            case .none:
                EmptyView()
            }
        }
        // "Switching to …", then "Switched to …" (`machine-switch-host`): under the
        // chip, from its end, for as long as the page's switcher says so.
        .overlay(alignment: .bottomTrailing) {
            if let note = switchNote {
                NativeAccountSwitchNote(note: note)
                    .fixedSize()
                    .alignmentGuide(.trailing) { $0[.leading] }
                    .alignmentGuide(.bottom) { $0[.top] - 4 }
            }
        }
        .task(id: session.sessionId) { await start() }
        .onChange(of: agentRunning) { Task { await readSessionAccount() } }
        // A switch made in place changes the account under the same session: read it again.
        .onChange(of: switchNote?.state) { _, state in
            if state == .done { Task { await readSessionAccount() } }
        }
    }

    private var switchNote: AccountSwitchNote? {
        AccountSwitchNote.shown(AppModel.shared.tabs?.accountSwitch, for: session.sessionId)
    }

    private func runButton(_ run: (label: String, command: String)) -> some View {
        Button {
            guard !session.ended, agentRunning == false, case .local(let id) = session.target else { return }
            EngineBridge.shared.send("session:write", [id, run.command])
        } label: {
            HStack(spacing: 4) {
                Text("❯")
                Text("Run \(run.label)")
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 4)
            .padding(.vertical, 2)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(session.ended)
        .help(session.ended ? "This session has ended — nothing can be started in it"
                            : "Start \(run.label) in this session. Types the command for you, in this terminal.")
    }

    private var accountChip: some View {
        let known: (id: String, name: String, provider: String?)? = {
            guard case .known(let provider, let dir, let profileId, let profileName, let email) = established else { return nil }
            return (profileId ?? dir, profileName ?? email ?? dir, provider)
        }()
        let withheld: String? = { if case .withheld(let why) = established { return why }; return nil }()
        let recorded: (id: String, name: String, provider: String?)? =
            info?.profileId.map { ($0, info?.profileName ?? $0, info?.provider) }
        let named = known ?? recorded
        let currentId = named?.id
        let rows = AccountChipRules.oneRowPerLogin(snapshot.accounts, signIn: signIn, prefer: currentId)
        let listed = currentId.flatMap { id in rows.first { $0.id == id } }
        let current = currentId.map { (id: $0, name: listed?.name ?? named?.name ?? $0, system: listed?.system as Bool?) }
        let identityId: String? = { if case .known(_, _, nil, _, _) = established { return nil }; return currentId }()
        let identity = AccountChipRules.identity(current, identityId.flatMap { signIn[$0] })
        let chosen = current.flatMap { ($0.system ?? CodingAIAccountLabels.isSystemAccountId($0.id)) ? nil : $0.name }
        let chosenName = chosen == identity.label ? nil : chosen
        let names = named != nil
        let unnamed: (label: String, detail: String?) = withheld.map { ("Account not known", $0) }
            ?? (established == nil ? ("Checking…", "Reading which account the agent in this session is running as.") : ("No login", nil))
        let mark = names ? (named?.provider ?? listed?.provider) : nil
        let sessionAgent = info?.provider == "shell" ? nil : (named?.provider ?? info?.provider)
        let switching = sessionAgent != nil
        let foreign = switching && rows.contains { $0.provider != sessionAgent }
        let fixed = AccountChipRules.fixedNote(hasSession: true, showAccount: true, switching: switching,
                                               sessionAgent: sessionAgent, sessionProvider: info?.provider)
        let blocked = NewSessionProviders.isolationNotice(defaultProvider)
        return Button {
            open.toggle()
        } label: {
            AccountChipLabel {
                NativeCodingAIDot(token: names ? listed?.color : nil)
                NativeCodingAIProviderMark(provider: mark, size: 13)
                Text(names ? identity.label : unnamed.label)
                    // `is-just-switched`: the name lit in the accent while "Switched to …" shows.
                    .foregroundStyle(switchNote?.lightsTheName == true ? Color.accentColor
                                     : names && identity.verified ? Color.primary : Color.secondary)
                    .animation(.easeOut(duration: 1.6), value: switchNote?.lightsTheName == true)
                if let armed {
                    Text("→ \(armed.accountName)").foregroundStyle(Color.accentColor).help(armed.help)
                }
            }
        }
        .buttonStyle(.plain)
        .help(names ? AccountChipRules.chipHelp(switching: switching, named: true, chosenName: chosenName, identityDetail: identity.detail,
                                                switchedInPlace: info?.switchedInPlace == true)
                    : (unnamed.detail ?? ""))
        .popover(isPresented: $open, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 2) {
                MenuHead(text: snapshot.machine.nilIfEmpty ?? "This Mac",
                         note: foreign ? ("Which accounts can run this session", AccountChipRules.foreignNote(TerminalAgent.name(sessionAgent ?? "")))
                             : fixed.map { ("What picking an account does here", $0) })
                if !switching, let blocked { Text(blocked).font(.caption).foregroundStyle(.secondary).padding(.horizontal, 8) }
                ForEach(rows) { account in
                    row(account, currentId: names ? currentId : nil, switching: switching, sessionAgent: sessionAgent, blocked: blocked)
                }
                if let failure, editing == nil { Text(failure).font(.caption).foregroundStyle(.red).padding(.horizontal, 8) }
                if rows.isEmpty {
                    Text(loading ? "Reading your accounts…" : "No accounts to choose from.").font(.callout).foregroundStyle(.secondary).padding(8)
                }
                if let error { Text(error).font(.callout).foregroundStyle(.secondary).padding(8) }
                if !switching, blocked != nil {
                    Text(AccountChipRules.blockedFoot).font(.caption).foregroundStyle(.secondary).padding(.horizontal, 8)
                }
                Divider()
                Button {
                    open = false
                    AppModel.shared.web.run(.addAccount)
                } label: {
                    Text("Add account").padding(.horizontal, 8).padding(.vertical, 4).frame(maxWidth: .infinity, alignment: .leading).contentShape(.rect)
                }
                .buttonStyle(.plain)
            }
            .padding(6)
            .frame(minWidth: 300, maxWidth: 420, alignment: .leading)
            .task { await probe(rows: snapshot.accounts, force: false) }
        }
    }

    @ViewBuilder
    private func row(_ account: CodingAIAccount, currentId: String?, switching: Bool, sessionAgent: String?, blocked: String?) -> some View {
        let state = signIn[account.id]
        let isCurrent = account.id == currentId
        let login = CodingAIAccountLabels.profileLoginLabel(account, state)
        if let edit = editing, edit.id == account.id {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    NativeCodingAIDot(token: account.color)
                    TextField("", text: Binding(get: { edit.draft }, set: { editing = (account.id, String($0.prefix(60))) }))
                        .textFieldStyle(.roundedBorder)
                        .disabled(saving)
                        .accessibilityLabel("New name for \(login)")
                        .onSubmit { save(account) }
                        .onExitCommand {
                            editing = nil
                            failure = nil
                        }
                }
                .padding(.horizontal, 8)
                if let failure { Text(failure).font(.caption).foregroundStyle(.red).padding(.horizontal, 8) }
            }
        } else {
            let inert = switching ? (account.provider != sessionAgent || isCurrent || state?.state == .signedOut) : blocked != nil
            HStack(spacing: 2) {
                Button {
                    open = false
                    if switching, case .local(let id) = session.target {
                        AppModel.shared.web.run(.switchAccount(sessionId: id, accountId: account.id))
                    } else {
                        AppModel.shared.web.run(.newSessionAs(projectPath: info?.cwd, accountId: account.id, provider: account.provider))
                    }
                } label: {
                    AccountRowLine(current: isCurrent, color: account.color, provider: account.provider, login: login,
                                   state: AccountChipRules.stateSummary(state).label)
                }
                .buttonStyle(.plain)
                .disabled(inert)
                .accessibilityAddTraits(isCurrent ? .isSelected : [])
                if let inherited = CodingAIAccountText.inheritedInstallNote(account, snapshot.inherited) {
                    NativeCodingAIInfo(label: "where \(login) keeps its login", text: inherited)
                }
                Button("Rename") {
                    failure = nil
                    editing = (account.id, account.name)
                }
                .buttonStyle(.borderless)
                .font(.caption)
                .help("Rename \(login)")
            }
        }
    }

    // MARK: Reading

    private func start() async {
        if subscriptions.isEmpty {
            subscriptions = [
                EngineBridge.shared.on("session:switched") { _ in Task { await readArmed() } },
                EngineBridge.shared.on("session:switch-failed") { _ in Task { await readArmed() } },
            ]
        }
        await readSessionAccount()
        await readArmed()
        await loadAccounts()
    }

    private func loadAccounts() async {
        loading = true
        do {
            snapshot = CodingAIAccountsParse.snapshot(CodingAIJSON(try await EngineBridge.shared.invoke("profiles:list")))
            error = nil
        } catch {
            self.error = NativePowerSettings.errorText(error, fallback: "Your accounts could not be read.")
        }
        loading = false
        // The account named on the chip is asked about whether or not the menu is open.
        if let id = info?.profileId, let account = snapshot.accounts.first(where: { $0.id == id }) {
            await probe(rows: [account], force: false)
        }
    }

    private func probe(rows: [CodingAIAccount], force: Bool) async {
        for account in rows where force || signIn[account.id] == nil {
            signIn[account.id] = .checking
            let raw = try? await EngineBridge.shared.invoke("profiles:signin", [account.id, ["refresh": force]])
            signIn[account.id] = raw.map { CodingAIAccountsParse.signIn(CodingAIJSON($0)) }
                ?? CodingAISignIn(state: .unknown, detail: "This account’s sign-in state could not be read.")
        }
    }

    private func readSessionAccount() async {
        guard case .local(let id) = session.target else { return }
        do {
            established = SessionAccountView.decode(try await EngineBridge.shared.invoke("session:account", [id]))
        } catch {
            established = .withheld(NativePowerSettings.errorText(error, fallback: "This session’s account could not be read."))
        }
    }

    private func readArmed() async {
        let list = ArmedSwitch.list(try? await EngineBridge.shared.invoke("session:switch-armed"))
        armed = list.first { $0.sessionId == session.sessionId }
    }

    private func save(_ account: CodingAIAccount) {
        guard let typed = editing?.draft else { return }
        saving = true
        failure = nil
        Task {
            do {
                _ = try await EngineBridge.shared.invoke("profiles:rename", [account.id, typed])
                editing = nil
                NativeCodingAIPages.announceAccountsChanged()
                await loadAccounts()
            } catch {
                failure = NativePowerSettings.errorText(error, fallback: "That name could not be saved.")
            }
            saving = false
        }
    }
}

// MARK: - A session on a paired machine

/// `MachineAccountChip`: the far machine's account for this session, and its other
/// accounts of the same agent — picking one switches the session over there. Absent
/// when that machine's build says nothing about accounts.
struct NativeMachineAccountChip: View {
    let session: NativeTerminalSession
    @State private var current: MachineAccount?
    @State private var accounts: [MachineAccount] = []
    @State private var busy = false
    @State private var problem: String?
    @State private var open = false

    var body: some View {
        Group {
            if current != nil || !accounts.isEmpty {
                HStack(spacing: 6) {
                    chip
                    if let problem {
                        Text(problem).font(.caption).foregroundStyle(.red).lineLimit(1).help(problem)
                    }
                }
            }
        }
        .task(id: session.sessionId) { await read() }
    }

    private var chip: some View {
        let identity = AccountChipRules.identity(current.map { ($0.id, $0.name, $0.system) }, current?.signInOrNotReported)
        let named = current != nil && (identity.verified || identity.label == current?.name)
        return Button {
            if !open { Task { await read() } }
            open.toggle()
        } label: {
            AccountChipLabel {
                NativeCodingAIDot(token: current?.color)
                NativeCodingAIProviderMark(provider: current?.provider, size: 13)
                Text(current == nil ? "No login" : identity.label)
            }
        }
        .buttonStyle(.plain)
        .help(current == nil ? "" : named ? "Account: \(identity.label)." : "\(identity.label).")
        .popover(isPresented: $open, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 2) {
                MenuHead(text: AccountChipRules.menuHead)
                ForEach(accounts) { account in
                    let isCurrent = account.id == current?.id
                    let foreign = current?.provider != nil && account.provider != nil && account.provider != current?.provider
                    Button {
                        open = false
                        pick(account.id)
                    } label: {
                        AccountRowLine(current: isCurrent, color: account.color, provider: account.provider,
                                       login: CodingAIAccountLabels.profileLoginLabel(account.asAccount, account.signInOrNotReported))
                    }
                    .buttonStyle(.plain)
                    .disabled(isCurrent || foreign || busy)
                }
            }
            .padding(6)
            .frame(minWidth: 260, alignment: .leading)
        }
    }

    private func read() async {
        guard case .machine(let machineId, let sessionId) = session.target,
              let state = MachineAccount.state(try? await EngineBridge.shared.invoke("machines:account:read", [machineId, sessionId])) else { return }
        current = state.current
        accounts = state.accounts
    }

    private func pick(_ accountId: String) {
        guard case .machine(let machineId, let sessionId) = session.target else { return }
        busy = true
        problem = nil
        Task {
            let raw = try? await EngineBridge.shared.invoke("machines:account:switch", [machineId, sessionId, accountId])
            busy = false
            let answer = MachineAccount.switchAnswer(raw)
            guard answer.ok else {
                show(problem: answer.message.isEmpty ? "That account could not be used." : answer.message)
                return
            }
            if let next = answer.session, next != sessionId {
                AppModel.shared.select("machine \(machineId) \(next)")
            }
            await read()
        }
    }

    /// The one sentence this chip ever draws, and it clears itself.
    private func show(problem text: String) {
        problem = text
        Task {
            try? await Task.sleep(for: .seconds(8))
            if problem == text { problem = nil }
        }
    }
}

// MARK: - A shell on a server

/// `ServerAccountChip`: the coding logins of the account this shell signed in as.
/// Picking one opens a new terminal on the server with that agent running; this one
/// keeps what it has. "Manage sign-ins in Settings" at the foot.
struct NativeServerAccountChip: View {
    let session: NativeTerminalSession
    @State private var signIn: ServerSignIn?
    @State private var open = false
    @State private var subscription: EngineSubscription?

    var body: some View {
        Group {
            if let signIn {
                chip(signIn)
            }
        }
        .task(id: session.shellId) { await read() }
    }

    private func chip(_ signIn: ServerSignIn) -> some View {
        let serverName = session.serverInfo?.serverName ?? ""
        let words = signIn.words(serverName)
        return Button { open.toggle() } label: {
            AccountChipLabel { Text(words.line) }
        }
        .buttonStyle(.plain)
        .help(words.title)
        .popover(isPresented: $open, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 2) {
                MenuHead(text: AccountChipRules.menuHead, note: ("What picking a login does here", ServerSignIn.note))
                if let state = signIn.menuState(serverName) {
                    Text(state).font(.callout).foregroundStyle(.secondary).padding(.horizontal, 8).padding(.vertical, 4)
                }
                ForEach(Array(signIn.logins.enumerated()), id: \.offset) { _, login in
                    Button {
                        open = false
                        if case .server(let serverId, _) = session.target {
                            AppModel.shared.web.run(.openServerShell(serverId: serverId, agentId: login.agentId))
                        }
                    } label: {
                        HStack(spacing: 6) {
                            NativeCodingAIProviderMark(provider: login.agentId, size: 13)
                            Text("New terminal running \(ServerSignIn.agentLabel(login.agentId))\(login.account.map { " — \($0)" } ?? "")")
                        }
                        .padding(.horizontal, 8).padding(.vertical, 4).frame(maxWidth: .infinity, alignment: .leading).contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                }
                Button {
                    open = false
                    AppModel.shared.web.run(.manageAccounts)
                } label: {
                    Text("Manage sign-ins in Settings").padding(.horizontal, 8).padding(.vertical, 4)
                        .frame(maxWidth: .infinity, alignment: .leading).contentShape(.rect)
                }
                .buttonStyle(.plain)
            }
            .padding(6)
            .frame(minWidth: 280, maxWidth: 420, alignment: .leading)
        }
    }

    private func read() async {
        if subscription == nil {
            // A server set up or signed in elsewhere changes the answer.
            subscription = EngineBridge.shared.on("servers:setup:changed") { args in
                let step = (args.first as? [String: Any])?["step"] as? String
                if step == "done" || step == "idle" { Task { await read() } }
            }
        }
        guard let shellId = session.shellId else {
            signIn = nil
            return
        }
        do {
            signIn = ServerSignIn.decode(try await EngineBridge.shared.invoke("servers:shell:account", [shellId]))
        } catch {
            signIn = .cannot("This app could not ask that server.")
        }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

/// `account-switch-note`: a small strong card — the working sentence in grey, or
/// the accent tick and "Switched to …".
struct NativeAccountSwitchNote: View {
    let note: AccountSwitchNote

    var body: some View {
        HStack(spacing: 6) {
            if note.state == .done {
                Image(systemName: "checkmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Color.accentColor)
                    .accessibilityHidden(true)
            }
            Text(note.text)
                .foregroundStyle(note.state == .working ? Color.secondary : Color.primary)
                .lineLimit(1)
        }
        .font(.caption)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .frame(maxWidth: 360, alignment: .leading)
        .background(.regularMaterial, in: .rect(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(.separator, lineWidth: 0.5))
        .shadow(color: .black.opacity(0.18), radius: 6, y: 2)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.updatesFrequently)
    }
}
