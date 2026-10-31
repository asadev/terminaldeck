import SwiftUI
import TerminalDeckNativeCore

/// "Add account": which agent, which address, then Sign in — which opens a
/// session on that agent in the main window, where its own login runs.
///
/// The same three steps and the same refusals as the web popup
/// (`AddAccountDialog.tsx`): an agent that cannot take another login cannot be
/// chosen, an address already on this machine is refused, and one added before
/// whose sign-in never finished is finished instead of added twice.
struct NativeCodingAIAddAccountSheet: View {
    @Bindable var store: NativeCodingAIStore
    @Environment(\.dismiss) private var dismiss
    @State private var draft = ""
    @State private var clicked: String?
    @State private var connection = "subscription"
    @FocusState private var emailFocused: Bool

    var body: some View {
        let rows = store.providerRows
        let chosen = CodingAIProviders.chosen(rows, selected: clicked)
        let problem = CodingAIProviders.agentProblem(rows, chosen?.id)
        let already = chosen.flatMap { CodingAILogins.holding(store.snapshot.accounts, signIn: store.signIn, provider: $0.id, address: draft) }
        let unfinished = chosen.flatMap { store.canStartSessions ? CodingAILogins.awaiting(store.snapshot.accounts, signIn: store.signIn, provider: $0.id, address: draft) : nil }
        // Claude and Codex sign in from here with no terminal (the app runs their own sign-in and the
        // browser opens); the address is optional for them, the account names itself from the email it
        // signs in with. Gemini still signs in inside a session.
        let drives = NativeAccountSignInModel.canDrive(chosen?.id)
        let canSignIn = drives || store.canStartSessions
        let blocked = store.busy || (!drives && draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) || chosen == nil
            || !canSignIn || problem != nil || (already != nil && unfinished == nil)
        // "Use the login already on this Mac": that AI's own install is signed in here as this address.
        let macLogin = chosen.flatMap { row in
            store.snapshot.accounts.first { $0.system && ($0.provider ?? "claude") == row.id }.flatMap { store.signIn[$0.id]?.account }
        }

        VStack(alignment: .leading, spacing: 0) {
            Text("Add account")
                .font(.title3.weight(.semibold))
                .padding([.horizontal, .top], 20)
                .padding(.bottom, 12)

            Picker("Connection", selection: $connection) {
                Text("Sign in (subscription)").tag("subscription")
                Text("API key").tag("api-key")
            }.pickerStyle(.segmented).padding(.horizontal, 20).padding(.bottom, 8)

            if connection == "api-key" {
                NativeAPIAccountEditor(provider: chosen?.id ?? store.addingProvider ?? "claude") {
                    store.addingPresented = false
                }
            } else {

            Form {
                Section("Which agent is this a login for?") {
                    ForEach(rows) { row in
                        agentRow(row, selected: chosen?.id == row.id)
                    }
                }

                Section(drives ? "Which email address? (optional)" : "Which email address?") {
                    if drives, let macLogin, !macLogin.isEmpty, draft.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() != macLogin.lowercased() {
                        Label("Already signed in on this Mac: \(macLogin)", systemImage: "laptopcomputer")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    TextField("Email address", text: $draft, prompt: Text("you@example.com"))
                        .labelsHidden()
                        .textContentType(.emailAddress)
                        .autocorrectionDisabled()
                        .focused($emailFocused)
                        .accessibilityLabel("Email address for the new account")
                        .onChange(of: draft) { _, text in
                            if text.count > CodingAILogins.maxNameLength { draft = String(text.prefix(CodingAILogins.maxNameLength)) }
                        }
                        .onSubmit { if !blocked { submit(chosen: chosen, unfinished: unfinished) } }
                }

                Section {
                    HStack(spacing: 4) {
                        Text(drives ? "Press Sign in: your browser opens \(chosen?.label ?? "the AI")’s own sign-in page. Approve there and it finishes by itself."
                                    : "Sign in, in the terminal that opens.")
                            .fixedSize(horizontal: false, vertical: true)
                        NativeCodingAIInfo(label: "Signing in", text: drives ? Self.drivenNote : Self.signingInNote)
                    }
                    if unfinished != nil {
                        NativeCodingAINotice(tone: .info, text: "You started adding this one already. Sign in to finish it.")
                    } else if already != nil {
                        NativeCodingAINotice(tone: .warn, text: "That is the same account as \(already?.name ?? macLogin ?? "the login on this Mac"). Choose it from the account menu.")
                    }
                    if let problem {
                        VStack(alignment: .leading, spacing: 4) {
                            NativeCodingAINotice(tone: .warn, text: problem.text)
                            // CONNECT-SKILLS: its row above carries the Install button (no terminal command).
                        }
                    }
                    if !rows.isEmpty && chosen == nil {
                        NativeCodingAINotice(tone: .warn, text: "No agent on this machine can hold a second login.")
                    }
                    if chosen != nil && !canSignIn {
                        NativeCodingAINotice(tone: .warn, text: "This window cannot open a session, so there is nothing here to sign in with.")
                    }
                }
            }
            .formStyle(.grouped)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(store.busy ? "Opening…" : "Sign in") {
                    submit(chosen: chosen, unfinished: unfinished)
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(blocked)
            }
            .padding(20)
            }
        }
        .frame(width: 460)
        .frame(minHeight: 520)
        .onAppear {
            draft = ""
            clicked = store.addingProvider
            emailFocused = true
        }
    }

    private func agentRow(_ row: CodingAIProviderRow, selected: Bool) -> some View {
        // CONNECT-SKILLS: a missing AI's row carries its Install button beside it (outside the row's own
        // button, which stays greyed until the AI is there); once installed the row is chosen for Sign in.
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            agentChoice(row, selected: selected)
            if !row.available, ["claude", "codex", "gemini"].contains(row.id) {
                NativeAIToolInstallButton(tool: row.id) { store.refreshAll(); clicked = row.id }
            }
        }
    }

    private func agentChoice(_ row: CodingAIProviderRow, selected: Bool) -> some View {
        Button {
            clicked = row.id
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(selected ? Color.accentColor : Color.secondary)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        NativeCodingAIProviderMark(provider: row.id, size: 13)
                        Text(row.label)
                        if let tag = row.tag { NativeCodingAIBadge(text: tag, quiet: true) }
                    }
                    if !row.available, row.install != nil {
                        Text("Not installed on this Mac yet.").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!row.canAdd)
        .opacity(row.canAdd ? 1 : 0.55)
        .help(row.canAdd ? "" : (row.note ?? "Not available."))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func submit(chosen: CodingAIProviderRow?, unfinished: CodingAIAccount?) {
        let email = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let chosen else { return }
        if NativeAccountSignInModel.canDrive(chosen.id) {
            // No terminal: this sheet closes and the sign-in's own progress shows on the Accounts page.
            dismiss()
            store.addingPresented = false
            if let unfinished { NativeAccountSignInModel.shared.start(account: unfinished, email: email.contains("@") ? email : nil) }
            else { NativeAccountSignInModel.shared.addAndSignIn(provider: chosen.id, name: email, email: email.contains("@") ? email : nil) }
            return
        }
        guard !email.isEmpty else { return }
        // Closed on the way: the sign-in opens in the main window.
        dismiss()
        store.addingPresented = false
        if let unfinished {
            store.signIn(unfinished)
            return
        }
        store.signInToNewAccount(name: email, provider: chosen.id)
    }

    static let drivenNote = "Terminal Deck runs the AI’s own sign-in for this account’s separate folder. Your password goes only to the AI’s own sign-in page in your browser. Approve there; if the page shows a code, paste it into the field that appears."
    static let signingInNote = "A session starts on that agent and it asks you to log in. Your password goes only to the agent’s own sign-in page; the login it hands back is kept by this app, encrypted, so switching to this account later needs no sign-in. The agent signs in whoever your browser is signed in as — if that is another account, sign out there first. Its conversations are kept with your own install where the agent allows it, so one started under this account can be continued under another."
}
