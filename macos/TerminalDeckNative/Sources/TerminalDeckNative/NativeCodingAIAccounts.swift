import SwiftUI
import TerminalDeckNativeCore

/// What one account row of Settings › Coding AIs shows (owner, 15 Nov; DESIGN.md section 6): the account by its NAME,
/// a 7 pt state dot, the plan as secondary text, and everything else (e-mail, state line, usage, sessions, notes) in
/// the info popover. A signed-out login is said here ONCE, as this row's orange state.
struct NativeCodingAIAccountFacts: Equatable {
    enum Dot: Equatable { case ready, needsAction, checking }
    var name: String
    var plan: String?
    var dot: Dot
    /// The one orange word when he must act ("Needs sign-in"); nil otherwise (the plan shows instead).
    var state: String?
    var info: String

    static let needsSignIn = "Needs sign-in"
    static let needsAttention = "Needs attention"
    static let keyNotWorking = "Key not working"

    /// The name a row is headed with: the chosen name, else the part of the signed-in address before "@", else what
    /// the login is ("This Mac's own Claude Code login"). The full address only in the popover.
    static func name(_ account: CodingAIAccount, _ signIn: CodingAISignIn?) -> String {
        if CodingAIAccountLabels.hasChosenName(account) { return account.name }
        if account.isAPIKey { return account.name }
        if let address = CodingAIAccountLabels.accountLabel(signIn) { return CodingAIAccountLabels.chatName(address, provider: account.provider) }
        return CodingAIAccountLabels.rowLabel(account, signIn)
    }

    static func make(account: CodingAIAccount, signIn: CodingAISignIn?, model: CodingAIAccountRowModel,
                     usage: String? = nil, apiStatus: String? = nil, keptCopies: Int = 0) -> NativeCodingAIAccountFacts {
        let dot: Dot
        var state: String?
        if account.isAPIKey {
            dot = account.apiCheckState == "invalid" ? .needsAction : .ready
            if dot == .needsAction { state = keyNotWorking }
        } else if model.state == .signedOut {
            dot = .needsAction; state = needsSignIn
        } else if model.problem != nil {
            dot = .needsAction; state = needsAttention
        } else if model.state == .signedIn {
            dot = .ready
        } else {
            dot = .checking
        }
        let plan: String? = account.isAPIKey ? "API key" : (signIn?.state == .signedIn ? (signIn?.plan ?? "Subscription") : nil)
        var lines: [String] = []
        if let address = CodingAIAccountLabels.accountLabel(signIn) ?? CodingAILogins.normalizedEmail(signIn?.remembered) { lines.append(address) }
        lines.append(account.isAPIKey ? (apiStatus ?? "API key") : model.stateLine)
        var marks: [String] = []
        if model.defaultBadge { marks.append("Default") }
        if model.ownInstallBadge { marks.append("Your own install") }
        if model.keptBadge { marks.append("Kept in this app") }
        if !marks.isEmpty { lines.append(marks.joined(separator: " · ")) }
        if let usage, !usage.isEmpty, model.showsUsage { lines.append(usage) }
        if account.isAPIKey { lines.append("Usage and reported cost appear in each chat.") }
        for line in [model.lastLogin, model.sessions, model.duplicate, model.problem?.text, model.signOutNote] {
            if let line, !line.isEmpty { lines.append(line) }
        }
        if keptCopies > 0 { lines.append("A second copy of this account is kept by the app. Remove it from this row's menu.") }
        if !model.note.isEmpty { lines.append(model.note) }
        return .init(name: name(account, signIn), plan: plan, dot: dot, state: state, info: lines.joined(separator: "\n\n"))
    }
}

/// The 7 pt dot: green signed in, orange he must act, grey while the AI has not answered.
struct NativeCodingAIStateDot: View {
    let dot: NativeCodingAIAccountFacts.Dot
    var body: some View {
        Circle().fill(dot == .ready ? Color.green : dot == .needsAction ? DeckTokens.warn : Color(nsColor: .tertiaryLabelColor))
            .frame(width: DeckSettingsLook.stateDot, height: DeckSettingsLook.stateDot)
            .accessibilityLabel(dot == .ready ? "Signed in" : dot == .needsAction ? "Needs you" : "Checking")
    }
}

/// The row as drawn (also by the pictures): dot, name (i), the plan or the orange state at the right, then "…".
struct NativeCodingAIAccountLine<Menu: View>: View {
    let facts: NativeCodingAIAccountFacts
    @ViewBuilder var menu: () -> Menu
    var body: some View {
        HStack(spacing: DeckTokens.Spacing.s12) {
            DeckSettingsRowLabel(title: facts.name, leading: AnyView(NativeCodingAIStateDot(dot: facts.dot)
                                    .frame(width: DeckSettingsLook.rowTile, height: DeckSettingsLook.rowTile)),
                                 info: facts.info)
            Spacer(minLength: DeckTokens.Spacing.s8)
            if let state = facts.state {
                Text(state).font(DeckSettingsLook.rowTitle).foregroundStyle(DeckTokens.warn).lineLimit(1)
            } else if let plan = facts.plan {
                Text(plan).font(DeckSettingsLook.rowTitle).foregroundStyle(.secondary).lineLimit(1)
            }
            menu()
        }
        .padding(.horizontal, DeckSettingsLook.rowPadding)
        .frame(maxWidth: .infinity, minHeight: DeckSettingsLook.rowHeight, alignment: .leading)
        .accessibilityElement(children: .contain)
    }
}

/// The "…" of a row: one borderless ellipsis that opens a menu.
enum NativeSettingsMoreGlyph {
    static let glyph = "ellipsis"
    static let size: CGFloat = 13
}

struct NativeSettingsMoreMenu<Items: View>: View {
    let label: String
    @ViewBuilder var items: () -> Items
    var body: some View {
        // SP-1 (15 Nov): the plain three dots, 13 pt, secondary (a circled mark read as a minus sign). Drawn by SwiftUI
        // (button-style menu, plain) so the secondary colour holds.
        Menu { items() } label: {
            Image(systemName: NativeSettingsMoreGlyph.glyph).font(.system(size: NativeSettingsMoreGlyph.size)).foregroundStyle(.secondary)
                .frame(width: 22, height: 22).contentShape(.rect)
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
        .accessibilityLabel("More for \(label)")
    }
}

/// One account of Settings › Coding AIs. Every action the old row had is in its "…" menu: Sign in again, Sign out,
/// Rename, Check key / Edit key (API keys), Install (when the AI is missing), Remove copy, Remove.
struct NativeCodingAIAccountRow: View {
    @State private var confirmMacSignOut = false
    @State private var editingKey = false
    @Bindable var store: NativeCodingAIStore
    let account: CodingAIAccount
    let model: CodingAIAccountRowModel
    @Binding var renamingId: String?
    @Binding var renameText: String
    @Binding var removing: CodingAIAccount?
    @FocusState private var nameFocused: Bool

    private var facts: NativeCodingAIAccountFacts {
        NativeCodingAIAccountFacts.make(account: account, signIn: store.signIn[account.id], model: model,
                                        usage: NativeAccountLevelsModel.shared.usage[account.id],
                                        apiStatus: account.isAPIKey ? (NativeAPIAccounts.shared.busy.contains(account.id) ? "Checking…" : NativeAPIAccounts.status(account)) : nil,
                                        keptCopies: store.copies(of: account).count)
    }

    var body: some View {
        Group {
            if renamingId == account.id {
                DeckSettingsRow("Name") { renameForm }
            } else {
                NativeCodingAIAccountLine(facts: facts) { menu }
            }
        }
        .confirmationDialog(model.removeConfirm, isPresented: Binding(get: { removing?.id == account.id }, set: { if !$0 { removing = nil } }),
                            titleVisibility: .visible) {
            Button(model.removeClosesSessions ? "Close them and remove" : "Remove", role: .destructive) {
                removing = nil
                store.remove(account, closingSessions: model.removeClosesSessions)
            }
            Button("Keep it", role: .cancel) { removing = nil }
        } message: { if let cost = model.removeCost { Text(cost) } }
        // This Mac's own login is not the app's: signing it out signs the AI out for the Terminal and every other app
        // too, and the AI starts on its first-run screen again. Never one click.
        .confirmationDialog("Sign \(CodingAICatalog.label(account.provider ?? "claude")) out on this Mac?", isPresented: $confirmMacSignOut) {
            Button("Sign Out on This Mac", role: .destructive) { store.signOut(account) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This is the Mac’s own login, not one Terminal Deck keeps. Your Terminal and every app that uses \(CodingAICatalog.label(account.provider ?? "claude")) on this Mac are signed out too, and it starts with its first-run screen next time.")
        }
        .sheet(isPresented: $editingKey) { NativeAPIAccountEditor(account: account) }
        .onAppear { openRequestedEditor() }
        .onChange(of: NativeAPIAccounts.shared.requestedEditorID) { _, _ in openRequestedEditor() }
    }

    @ViewBuilder private var menu: some View {
        NativeSettingsMoreMenu(label: facts.name) {
            if !account.isAPIKey, model.offersSignIn {
                // Claude and Codex: the app runs the sign-in and the browser opens (no terminal).
                Button(account.lastUsedAt == nil ? "Sign in" : "Sign in again") { NativeAccountSignInModel.shared.open(account, store: store) }
            }
            if !account.isAPIKey, model.offersSignOut {
                Button("Sign out") { if account.system { confirmMacSignOut = true } else { store.signOut(account) } }
            }
            if account.isAPIKey {
                Button(account.apiKind == "compatibleLocal" ? "Check connection" : "Check key") { NativeAPIAccounts.shared.check(account.id) }
                    .disabled(NativeAPIAccounts.shared.busy.contains(account.id))
                Button("Edit key…") { editingKey = true }
            }
            if model.problem?.install != nil {
                // CONNECT-SKILLS: one click instead of a terminal command; then this account's sign-in.
                Button("Install \(CodingAICatalog.label(account.provider ?? "claude"))") {
                    let store = store, account = account
                    NativeAIToolInstallModel.shared.install(account.provider ?? "claude") {
                        if account.isAPIKey { store.refreshAll() } else { NativeAccountSignInModel.shared.open(account, store: store) }
                    }
                }
            }
            if model.offersRename {
                Button("Rename") { renameText = account.name; renamingId = account.id }
            }
            ForEach(store.copies(of: account)) { copy in
                Button("Remove the second copy") { store.removeCopy(copy) }
            }
            if model.offersRenameRemove {
                Divider()
                Button("Remove", role: .destructive) { removing = account }
            }
        }
        .disabled(store.busy)
    }

    private var renameForm: some View {
        HStack(spacing: DeckTokens.Spacing.s8) {
            NativeSessionTextField("Name", text: $renameText)
                .textFieldStyle(.roundedBorder).frame(width: 200)
                .sessionFocused($nameFocused)
                .accessibilityLabel("New name for \(model.label)")
                .onChange(of: renameText) { _, text in
                    if text.count > CodingAILogins.maxNameLength { renameText = String(text.prefix(CodingAILogins.maxNameLength)) }
                }
                .sessionOnSubmit(save)
                .sessionOnExitCommand { renamingId = nil }
            Button("Save", action: save).keyboardShortcut(.defaultAction)
            Button("Cancel") { renamingId = nil }
        }
        .onAppear { nameFocused = true }
    }

    private func save() {
        let typed = renameText
        renamingId = nil
        store.rename(account, to: typed)
    }

    private func openRequestedEditor() {
        guard account.isAPIKey, NativeAPIAccounts.shared.requestedEditorID == account.id else { return }
        editingKey = true
        NativeAPIAccounts.shared.requestedEditorID = nil
    }
}

// MARK: - Add accounts

/// "Add accounts": every agent, in two headed runs; each row does exactly one thing.
struct NativeCodingAIAddAccountsButton: View {
    @Bindable var store: NativeCodingAIStore
    @State private var shown = false

    var body: some View {
        HStack {
            NativeSessionButton {
                shown.toggle()
            } label: {
                Label("Add accounts", systemImage: "plus")
            }
            .popover(isPresented: $shown, arrowEdge: .bottom) {
                menu
                    .padding(12)
                    .frame(width: 380)
            }
            Spacer()
        }
    }

    private var menu: some View {
        let facts = store.addAccountsFacts
        let rows = CodingAIAddAccounts.rows(facts, canAdd: true, canSignIn: store.canStartSessions)
        let present = store.prerequisites?.agentsPresent ?? []
        return VStack(alignment: .leading, spacing: 10) {
            ForEach([CodingAIAccountRun.Kind.signedIn, .notSignedIn], id: \.self) { run in
                let mine = rows.filter { $0.run == run }
                if !mine.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(CodingAIAccountRun.title(run) ?? "")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        ForEach(mine) { row in
                            menuRow(row, tool: present.first { $0.id == row.id })
                        }
                    }
                }
            }
        }
    }

    private func menuRow(_ row: CodingAIAddAccountsRow, tool: CodingAITool?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            NativeCodingAIProviderMark(provider: row.id, size: 13)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(row.label)
                    if row.installed, let tool, let version = tool.versionLabel {
                        Text(version)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .help(version == CodingAITool.noVersion ? CodingAITool.noVersionHint : "")
                    }
                }
                if !row.logins.isEmpty {
                    Text(row.logins.joined(separator: ", "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            switch row.action {
            case .addAccount:
                NativeSessionButton("Add account") {
                    shown = false
                    store.askForAddAccount(row.id)
                }
            case .signIn:
                NativeSessionButton("Sign in") {
                    shown = false
                    store.signInInstall(row.id)
                }
            case .install:
                // CONNECT-SKILLS: installs here (progress shows in place), then opens its sign-in.
                if ["claude", "codex", "gemini"].contains(row.id) {
                    NativeAIToolInstallButton(tool: row.id)
                } else if let url = row.url.flatMap(URL.init(string:)) {
                    Link("Install", destination: url)
                }
            case .none:
                EmptyView()
            }
            // The one caveat an agent can carry, behind an ⓘ.
            Group {
                if row.installed, let note = tool?.note {
                    NativeCodingAIInfo(label: row.label, text: note)
                } else {
                    Color.clear
                }
            }
            .frame(width: 16)
        }
    }
}

// MARK: - Agent CLIs too old to sign in

struct NativeCodingAIStaleAgents: View {
    @Bindable var store: NativeCodingAIStore

    var body: some View {
        let showing = store.staleAgents.filter { !ReadinessDismissed.isDismissed(store.dismissed, scope: ReadinessDismissed.machineScope, id: $0.dismissalId) }
        let hidden = store.staleAgents.count - showing.count
        ForEach(showing) { row in
            let working = store.upgrading == row.command
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title(row))
                    Text(advice(row))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                    // `agent-cli-detail` / `agent-cli-result`: the advice's size, as on the web (lane B, AgentCliUpdate parity).
                    if working {
                        Text("Upgrading. This runs your own package manager and can take a few minutes.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    if let result = store.upgradeResults[row.command] {
                        Text(result.message)
                            .font(.callout)
                            .foregroundStyle(result.ok ? Color.green : Color.red)
                    }
                }
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 6) {
                    NativeSessionButton(working ? "Upgrading…" : "Upgrade it") { store.upgrade(row) }
                        .disabled(working)
                    NativeSessionButton("Dismiss") { store.dismiss(row) }
                        .buttonStyle(.borderless)
                }
            }
        }
        if store.staleAgents.isEmpty == false, hidden > 0 {
            HStack(spacing: 6) {
                Text(ReadinessDismissed.hiddenLine(hidden))
                    .foregroundStyle(.secondary)
                NativeSessionButton("Show it again") { store.bringBackDismissed() }
                    .buttonStyle(.link)
            }
            .font(.caption)
        }
    }

    private func title(_ row: CodingAIStaleAgent) -> AttributedString {
        var code = AttributedString([row.command, row.version ?? ""].filter { !$0.isEmpty }.joined(separator: " "))
        code.font = .body.monospaced()
        return code + AttributedString(" is too old to sign in")
    }

    private func advice(_ row: CodingAIStaleAgent) -> AttributedString {
        var out = AttributedString()
        for piece in row.advicePieces {
            var part = AttributedString(piece.text)
            if piece.code { part.font = .callout.monospaced() }
            out += part
        }
        return out
    }
}
