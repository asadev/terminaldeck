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
struct AccountRowLine: View {
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
/// and a menu of the accounts ready to run it (signed in, same AI) — picking one
/// switches this session to it where that can be done, else opens a new session on
/// it; "Add account" at the foot. Everything else lives in Settings › Coding AI.
/// A shell with no agent in it gets "Run …".
struct NativeLocalAccountChip: View {
    let session: NativeTerminalSession
    static let shellAccountHelp = "Claude or another AI started in this shell keeps its own login. To sign in to Claude here, type /login. Choosing an account below opens a new session; this shell stays open."
    static var shellAccountInstructions: some View {
        Text(shellAccountHelp).font(.caption).foregroundStyle(.secondary).padding(8)
            .fixedSize(horizontal: false, vertical: true)
    }

    @State private var snapshot = CodingAIAccountsSnapshot.empty
    @State private var signIn: [String: CodingAISignIn] = [:]
    @State private var loading = true
    @State private var error: String?
    @State private var established: SessionAccountView?
    @State private var armed: ArmedSwitch?
    /// 18 Oct (#416): the waiting switches could not be read; said on the chip, never shown as none.
    @State private var armedUnreadable: String?
    @State private var open = false
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
        .task(id: EngineBridge.shared.isReady) { await NativeChatAccountNames.shared.start() }
        // 12 Oct: the chip's switch is the app's own (NativeAccountSwitch.swift), its dialog shown here.
        .modifier(NativeAccountChipSwitchSheet(sessionId: session.sessionId))
        .onChange(of: agentRunning) { Task { await readSessionAccount(); await loadAccounts() } }
        .onChange(of: NativeCodingAIStore.shared.signIn["system"]?.state) { _, state in
            if usesDefaultClaude, state == .signedIn || state == .signedOut { Task { await loadAccounts() } }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await loadAccounts() }
        }
        // A switch made in place changes the account under the same session: read it again.
        .onChange(of: switchNote?.state) { _, state in
            if state == .done { Task { await readSessionAccount() } }
        }
    }

    private var usesDefaultClaude: Bool {
        if case .known(let provider, _, let id, _, _) = established { return provider == "claude" && id == "system" }
        return info?.provider == "claude" && info?.profileId == "system"
    }

    private var switchNote: AccountSwitchNote? {
        NativeAccountSwitcher.shared.note(for: session.sessionId) ?? AccountSwitchNote.shown(AppModel.shared.tabs?.accountSwitch, for: session.sessionId)
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
            return (profileId ?? dir, email ?? profileName ?? dir, provider)
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
        let knownEmail: String? = { if case .known(_, _, _, _, let email) = established { return email }; return nil }()
        let identity = AccountChipRules.chipIdentity(knownEmail: knownEmail, current: current,
            live: currentId.flatMap { signIn[$0] }?.state == .signedOut ? currentId.flatMap { signIn[$0] } : identityId.flatMap { signIn[$0] })
        let chosen = current.flatMap { ($0.system ?? CodingAIAccountLabels.isSystemAccountId($0.id)) ? nil : $0.name }
        let chosenName = chosen == identity.label ? nil : chosen
        let names = named != nil
        let unnamed: (label: String, detail: String?) = withheld.map { ("Account not known", $0) }
            ?? (established == nil ? ("Checking…", "Reading which account the agent in this session is running as.") : ("No login", nil))
        let mark = names ? (named?.provider ?? listed?.provider) : nil
        let sessionAgent = info?.provider == "shell" ? nil : (named?.provider ?? info?.provider)
        let switching = sessionAgent != nil
        let blocked = NewSessionProviders.isolationNotice(defaultProvider, apiAccountAvailable: rows.contains(where: \.isAPIKey))
        return Button {
            open.toggle()
        } label: {
            AccountChipLabel {
                NativeCodingAIDot(token: names ? listed?.color : nil)
                NativeCodingAIProviderMark(provider: mark, size: 13)
                Text(names ? CodingAIAccountLabels.chatName(NativeChatAccountNames.shared.name(currentId, fallback: listed?.name ?? named?.name ?? identity.label), provider: mark) : unnamed.label)
                    .help(knownEmail ?? identity.detail ?? "")
                    // `is-just-switched`: the name lit in the accent while "Switched to …" shows.
                    .foregroundStyle(switchNote?.lightsTheName == true ? Color.accentColor
                                     : names && identity.verified ? Color.primary : Color.secondary)
                    .animation(.easeOut(duration: 1.6), value: switchNote?.lightsTheName == true)
                if let armed {
                    Text("→ \(armed.accountName)").foregroundStyle(Color.accentColor).help(armed.help)
                } else if let armedUnreadable {
                    Text("→ ?").foregroundStyle(.secondary).help(armedUnreadable)
                }
            }
        }
        .buttonStyle(.plain)
        .help(names ? AccountChipRules.chipHelp(switching: switching, named: true, chosenName: chosenName, identityDetail: identity.detail,
                                                switchedInPlace: info?.switchedInPlace == true)
                    : (unnamed.detail ?? ""))
        .popover(isPresented: $open, arrowEdge: .bottom) {
            // Asad, 11 Oct: "this dropdown on the session should only show ready to use accounts only and add
            // account button only and rest should be handled in settings not here". So: the account this session
            // runs as (ticked), the other signed-in accounts of the same AI, and Add account. Renaming, signed-out
            // logins, the machine name, where the account comes from and who uses what are in Settings › Coding AI.
            // 13 Oct (Asad): every signed-in AI's accounts, grouped by AI: picking another AI's account hands this
            // session over to it in the same tab, with the same conversation.
            let shownCurrent = names ? currentId : nil
            let ready = AccountChipRules.readyRows(rows, signIn: signIn, currentId: shownCurrent, sessionAgent: nil)
                .filter { ["claude", "codex", "gemini"].contains($0.provider ?? "claude") }
            let order = [sessionAgent ?? "claude"] + ["claude", "codex", "gemini"].filter { $0 != (sessionAgent ?? "claude") }
            let groups = order.map { ai in (ai, ready.filter { ($0.provider ?? "claude") == ai }) }.filter { !$0.1.isEmpty }
            let checking = loading || AccountChipRules.stillChecking(rows, signIn: signIn, sessionAgent: nil)
            VStack(alignment: .leading, spacing: 2) {
                if info?.provider == "shell" {
                    Self.shellAccountInstructions
                }
                ForEach(groups, id: \.0) { group in
                    if groups.count > 1 { MenuHead(text: AccountSwitchWords.aiName(group.0)) }
                    ForEach(group.1) { account in
                        row(account, currentId: shownCurrent, switching: switching, blocked: blocked, from: names ? identity.label : unnamed.label)
                    }
                }
                if checking {
                    HStack(spacing: 6) { ProgressView().controlSize(.mini); Text("Checking which accounts are ready…") }
                        .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 8).padding(.vertical, 2)
                } else if ready.filter({ $0.id != shownCurrent }).isEmpty {
                    Text(ready.isEmpty ? "No signed-in account is ready here." : "No other signed-in account.")
                        .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 8).padding(.vertical, 2)
                }
                if let error { Text(error).font(.callout).foregroundStyle(.secondary).padding(8) }
                Divider()
                Button {
                    open = false
                    NativeAccountSwitcher.addAccount(provider: sessionAgent)
                } label: {
                    Label("Add account", systemImage: "plus").padding(.horizontal, 8).padding(.vertical, 4)
                        .frame(maxWidth: .infinity, alignment: .leading).contentShape(.rect)
                }
                .buttonStyle(.plain)
            }
            .padding(6)
            .frame(minWidth: 260, maxWidth: 420, alignment: .leading)
            // Only this session's AI is asked about: the others are never listed here.
            .task { await probe(rows: snapshot.accounts.filter { ["claude", "codex", "gemini"].contains($0.provider ?? "claude") }, force: false) }
        }
    }

    @ViewBuilder
    private func row(_ account: CodingAIAccount, currentId: String?, switching: Bool, blocked: String?, from: String) -> some View {
        let state = signIn[account.id]
        let isCurrent = account.id == currentId
        let login = CodingAIAccountLabels.chatName(NativeChatAccountNames.shared.name(account.id, fallback: account.name), provider: account.provider)
        // Switching: the session's own account is the tick, not a choice. Otherwise (a shell's own agent) a pick
        // opens a new session on that account, unless the default coding tool holds one login only.
        let inert = switching ? isCurrent : blocked != nil
        Button {
            open = false
            if switching, case .local(let id) = session.target {
                // Chosen for this one session: a later "Switch now" on its project or role leaves it alone.
                NativeAccountLevelsModel.markChosen(sessionID: id)
                let title = AppModel.shared.tabs?.tabs.first(where: { $0.id == id })?.title ?? info?.title ?? ""
                NativeAccountSwitcher.shared.ask(sessionId: id, accountId: account.id, title: title, from: from, to: login)
            } else {
                NativeAccountSwitcher.shared.newSession(from: session.sessionId, in: info?.cwd, accountId: account.id, provider: account.provider)
            }
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                AccountRowLine(current: isCurrent, color: account.color, provider: account.provider,
                               login: switching ? login : "New session · \(login)",
                               state: AccountChipRules.stateSummary(state).label)
                if let email = CodingAIAccountLabels.accountLabel(state) ?? CodingAILogins.normalizedEmail(account.name) {
                    Text(email).font(.caption).foregroundStyle(.secondary).padding(.leading, 8)
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(inert)
        .help(!switching && blocked != nil ? AccountChipRules.blockedFoot : !switching ? "Open a new session as \(login). This shell stays open." : isCurrent ? "This session runs as \(login)." : "Use \(login) for this session.")
        .accessibilityAddTraits(isCurrent ? .isSelected : [])
    }

    // MARK: Reading

    private func start() async {
        if subscriptions.isEmpty {
            subscriptions = [
                EngineBridge.shared.on("session:switched") { _ in Task { await readArmed(); await readSessionAccount() } },
                // A switch made in place that did not take puts the session's own account back on the chip.
                EngineBridge.shared.on("session:switch-failed") { _ in Task { await readArmed(); await readSessionAccount() } },
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
        if let id = usesDefaultClaude ? "system" : info?.profileId, let account = snapshot.accounts.first(where: { $0.id == id }) {
            await probe(rows: [account], force: account.system)
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
        do {
            armed = ArmedSwitch.list(try await EngineBridge.shared.invoke("session:switch-armed")).first { $0.sessionId == session.sessionId }
            armedUnreadable = nil
        } catch {
            armed = nil
            armedUnreadable = NativePowerSettings.errorText(error, fallback: "The account changes waiting for your next message could not be read.")
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
        let rows = state.accounts.map(\.asAccount)
        let reports = Dictionary(state.accounts.compactMap { account in account.signIn.map { (account.id, $0) } }, uniquingKeysWith: { first, _ in first })
        let shown = Set(CodingAILogins.oneRowPerEmail(rows, signIn: reports, prefer: state.current?.id).map(\.id))
        accounts = state.accounts.filter { shown.contains($0.id) }
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
        .modifier(NativeAccountChipSwitchSheet(sessionId: session.sessionId))
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
                            NativeAccountSwitcher.shared.openServerShell(from: session.sessionId, serverId: serverId, agentId: login.agentId)
                        }
                    } label: {
                        HStack(spacing: 6) {
                            NativeCodingAIProviderMark(provider: login.agentId, size: 13)
                            Text("New terminal running \(CodingAICatalog.label(login.agentId))\(login.account.map { " — \($0)" } ?? "")")
                        }
                        .padding(.horizontal, 8).padding(.vertical, 4).frame(maxWidth: .infinity, alignment: .leading).contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                }
                Button {
                    open = false
                    NativeAccountSwitcher.manageAccounts()
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
