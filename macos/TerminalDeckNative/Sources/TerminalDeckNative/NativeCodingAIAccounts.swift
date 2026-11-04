import SwiftUI
import TerminalDeckNativeCore

/// One account: its dot, the login it is, its state with an ⓘ, and what can be done.
struct NativeCodingAIAccountRow: View {
    @State private var confirmMacSignOut = false
    @State private var keepCopy = false
    @Bindable var store: NativeCodingAIStore
    let account: CodingAIAccount
    let model: CodingAIAccountRowModel
    @Binding var renamingId: String?
    @Binding var renameText: String
    @Binding var removing: CodingAIAccount?
    @FocusState private var nameFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                NativeCodingAIDot(token: account.color)
                    .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }

                if renamingId == account.id {
                    renameForm
                } else {
                    details
                    Spacer(minLength: 8)
                    actions
                }
            }
            // Remove asks on the row itself, with what it would cost.
            if removing?.id == account.id {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(model.removeConfirm).fixedSize(horizontal: false, vertical: true)
                        if let cost = model.removeCost {
                            Text(cost).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Spacer(minLength: 8)
                    Button(model.removeClosesSessions ? "Close them and remove" : "Remove", role: .destructive) {
                        removing = nil
                        store.remove(account, closingSessions: model.removeClosesSessions)
                    }
                    .disabled(store.busy)
                    Button("Keep it") { removing = nil }
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.08)))
            }
        }
        .padding(.vertical, 2)
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(model.label)
                    .textSelection(.enabled)
                NativeCodingAIBadge(text: account.isAPIKey ? "API key" : "Subscription", quiet: true)
                if model.defaultBadge { NativeCodingAIBadge(text: "Default") }
                if model.ownInstallBadge { NativeCodingAIBadge(text: "Your own install", quiet: true) }
                if model.keptBadge { NativeCodingAIBadge(text: "Kept in this app", quiet: true) }
            }
            HStack(spacing: 5) {
                if account.isAPIKey {
                    Image(systemName: account.apiCheckState == "invalid" ? "exclamationmark.triangle" : "key")
                        .foregroundStyle(account.apiCheckState == "invalid" ? DeckTokens.bad : DeckTokens.textSecondary)
                } else { NativeCodingAIStateMark(state: model.state.rawValue) }
                Text(account.isAPIKey ? (NativeAPIAccounts.shared.busy.contains(account.id) ? "Checking..." : NativeAPIAccounts.status(account)) : model.stateLine)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                NativeCodingAIInfo(label: model.label, text: model.note)
            }
            .font(.callout)
            if account.isAPIKey {
                Text("Usage and reported cost appear in each chat. Subscription windows are separate.").font(.caption).foregroundStyle(.secondary)
            } else if model.showsUsage { NativeAccountUsageLine(accountID: account.id) }
            if let last = model.lastLogin {
                Text(last).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
            if let sessions = model.sessions {
                Text(sessions)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let duplicate = model.duplicate {
                blocked(duplicate)
            }
            if !store.copies(of: account).isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    Text("A second copy of this account is kept by the app")
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if !keepCopy {
                        HStack(spacing: 10) {
                            ForEach(store.copies(of: account)) { copy in
                                Button("Remove copy") { store.removeCopy(copy) }
                                    .disabled(store.busy)
                                    .help("Remove the saved login and move its folder to a backup. All history is kept.")
                            }
                            Button("Keep") { keepCopy = true }
                        }.font(.callout)
                    }
                }
            }
            if let problem = model.problem {
                VStack(alignment: .leading, spacing: 3) {
                    blocked(problem.text)
                    // CONNECT-SKILLS: one click instead of a terminal command; then this account's sign-in.
                    if problem.install != nil {
                        let provider = account.provider ?? "claude"
                        NativeAIToolInstallButton(tool: provider) {
                            if account.isAPIKey { store.refreshAll() } else { NativeAccountSignInModel.shared.open(account, store: store) }
                        }
                    }
                }
            }
            if let note = model.signOutNote {
                blocked(note)
            }
        }
    }

    private func blocked(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.orange)
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder private var actions: some View {
        HStack(spacing: 6) {
            if account.isAPIKey { NativeAPIAccountActions(account: account) }
            if !account.isAPIKey, model.offersSignIn {
                // Claude and Codex: the app runs the sign-in and the browser opens (no terminal).
                // The same button is "Sign in again" for an account that was signed out or expired.
                Button(account.lastUsedAt == nil ? "Sign in" : "Sign in again") {
                    NativeAccountSignInModel.shared.open(account, store: store)
                }
                    .disabled(store.busy)
            }
            if !account.isAPIKey, model.offersSignOut {
                // This Mac's own login is not the app's: signing it out signs the AI out for the Terminal
                // and every other app too, and the AI starts on its first-run screen again. Never one click.
                Button("Sign out") { if account.system { confirmMacSignOut = true } else { store.signOut(account) } }
                    .disabled(store.busy)
                    .confirmationDialog("Sign \(CodingAICatalog.label(account.provider ?? "claude")) out on this Mac?", isPresented: $confirmMacSignOut) {
                        Button("Sign Out on This Mac", role: .destructive) { store.signOut(account) }
                        Button("Cancel", role: .cancel) {}
                    } message: {
                        Text("This is the Mac’s own login, not one Terminal Deck keeps. Your Terminal and every app that uses \(CodingAICatalog.label(account.provider ?? "claude")) on this Mac are signed out too, and it starts with its first-run screen next time.")
                    }
            }
            if model.hasMenu {
                Menu {
                    // FINAL-CONNECT (row 62): "Use by default" was a second control for the "Whole Terminal Deck" row of
                    // Who uses what (same value); that row is the one place now.
                    // Every account renames here, this Mac's own login too (no longer on the session's menu).
                    if model.offersRename {
                        Button("Rename") {
                            renameText = account.name
                            renamingId = account.id
                        }
                    }
                    if model.offersRenameRemove {
                        Divider()
                        Button("Remove", role: .destructive) { removing = account }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .disabled(store.busy)
                .accessibilityLabel("More for \(model.label)")
                .help("More for \(model.label)")
            }
        }
    }

    private var renameForm: some View {
        HStack(spacing: 6) {
            TextField("Name", text: $renameText)
                .textFieldStyle(.roundedBorder)
                .focused($nameFocused)
                .accessibilityLabel("New name for \(model.label)")
                .onChange(of: renameText) { _, text in
                    if text.count > CodingAILogins.maxNameLength { renameText = String(text.prefix(CodingAILogins.maxNameLength)) }
                }
                .onSubmit(save)
                .onExitCommand { renamingId = nil }
            Button("Save", action: save)
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            Button("Cancel") { renamingId = nil }
        }
        .onAppear { nameFocused = true }
    }

    private func save() {
        let typed = renameText
        renamingId = nil
        store.rename(account, to: typed)
    }
}

// MARK: - Add accounts

/// "Add accounts": every agent, in two headed runs; each row does exactly one thing.
struct NativeCodingAIAddAccountsButton: View {
    @Bindable var store: NativeCodingAIStore
    @State private var shown = false

    var body: some View {
        HStack {
            Button {
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
                Button("Add account") {
                    shown = false
                    store.askForAddAccount(row.id)
                }
            case .signIn:
                Button("Sign in") {
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
                    Button(working ? "Upgrading…" : "Upgrade it") { store.upgrade(row) }
                        .disabled(working)
                    Button("Dismiss") { store.dismiss(row) }
                        .buttonStyle(.borderless)
                }
            }
        }
        if store.staleAgents.isEmpty == false, hidden > 0 {
            HStack(spacing: 6) {
                Text(ReadinessDismissed.hiddenLine(hidden))
                    .foregroundStyle(.secondary)
                Button("Show it again") { store.bringBackDismissed() }
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
