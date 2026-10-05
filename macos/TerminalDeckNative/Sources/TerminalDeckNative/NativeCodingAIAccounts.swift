import SwiftUI
import TerminalDeckNativeCore

/// The accounts on this machine: the Add accounts menu, the stale-CLI warning,
/// and the two runs — Signed in, Not signed in or not installed — with one list
/// per agent inside each (the unanswered rows first, under no heading).
struct NativeCodingAIAccountsSections: View {
    @Bindable var store: NativeCodingAIStore
    @State private var renamingId: String?
    @State private var renameText = ""
    @State private var removing: CodingAIAccount?

    var body: some View {
        Section {
            if let error = store.failure ?? store.accountsError {
                NativeCodingAINotice(tone: .error, text: error)
            }
            if store.sectionError == nil {
                NativeCodingAIAddAccountsButton(store: store)
            }
            NativeCodingAIStaleAgents(store: store)
            if store.snapshot.accounts.isEmpty && store.accountsLoaded && !store.accountsLoading {
                Text("No accounts yet.")
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Accounts")
        }
        .alert("Remove this account?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
               presenting: removing) { account in
            Button("Remove", role: .destructive) { store.remove(account) }
            Button("Keep it", role: .cancel) {}
        } message: { account in
            let model = store.row(account)
            Text([model.removeConfirm, model.removeCost].compactMap { $0 }.joined(separator: "\n\n"))
        }

        ForEach(store.runs) { run in
            Section {
                ForEach(run.groups) { group in
                    HStack(spacing: 6) {
                        NativeCodingAIProviderMark(provider: group.provider, size: 13)
                        Text(group.label)
                    }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .accessibilityAddTraits(.isHeader)

                    ForEach(group.accounts) { account in
                        NativeCodingAIAccountRow(
                            store: store,
                            account: account,
                            model: store.row(account),
                            renamingId: $renamingId,
                            renameText: $renameText,
                            removing: $removing)
                    }
                }
            } header: {
                if let title = run.title { Text(title) }
            }
        }
    }
}

/// One account: its dot, the login it is, its state with an ⓘ, and what can be done.
struct NativeCodingAIAccountRow: View {
    @Bindable var store: NativeCodingAIStore
    let account: CodingAIAccount
    let model: CodingAIAccountRowModel
    @Binding var renamingId: String?
    @Binding var renameText: String
    @Binding var removing: CodingAIAccount?
    @FocusState private var nameFocused: Bool

    var body: some View {
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
        .padding(.vertical, 2)
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(model.label)
                    .textSelection(.enabled)
                if model.defaultBadge { NativeCodingAIBadge(text: "Default") }
                if model.ownInstallBadge { NativeCodingAIBadge(text: "Your own install", quiet: true) }
                if model.keptBadge { NativeCodingAIBadge(text: "Kept in this app", quiet: true) }
            }
            HStack(spacing: 5) {
                NativeCodingAIStateMark(state: model.state.rawValue)
                Text(model.stateLine)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                NativeCodingAIInfo(label: model.label, text: model.note)
            }
            .font(.callout)
            if let sessions = model.sessions {
                Text(sessions)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let duplicate = model.duplicate {
                blocked(duplicate)
            }
            if let problem = model.problem {
                VStack(alignment: .leading, spacing: 3) {
                    blocked(problem.text)
                    if let install = problem.install { NativeCodingAICommand(text: install) }
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
            if model.offersSignIn {
                Button("Sign in") { store.signIn(account) }
                    .disabled(store.busy)
            }
            if model.offersSignOut {
                Button("Sign out") { store.signOut(account) }
                    .disabled(store.busy)
            }
            if model.hasMenu {
                Menu {
                    if model.offersUseByDefault {
                        Button("Use by default") { store.makeDefault(account) }
                    }
                    if model.offersRenameRemove {
                        Button("Rename…") {
                            renameText = account.name
                            renamingId = account.id
                        }
                        Divider()
                        Button("Remove…", role: .destructive) { removing = account }
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
                if let url = row.url.flatMap(URL.init(string:)) {
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
        let showing = store.staleAgents.filter { !store.dismissed.isDismissed($0.dismissalId) }
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
                    if working {
                        Text("Upgrading. This runs your own package manager and can take a few minutes.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if let result = store.upgradeResults[row.command] {
                        Text(result.message)
                            .font(.caption)
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
                Text(CodingAIDismissed.hiddenLine(hidden))
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
