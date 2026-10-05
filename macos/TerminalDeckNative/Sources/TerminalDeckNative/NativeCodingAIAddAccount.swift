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
    @FocusState private var emailFocused: Bool

    var body: some View {
        let rows = store.providerRows
        let chosen = CodingAIProviders.chosen(rows, selected: clicked)
        let problem = CodingAIProviders.agentProblem(rows, chosen?.id)
        let already = chosen.flatMap { CodingAILogins.holding(store.snapshot.accounts, signIn: store.signIn, provider: $0.id, address: draft) }
        let unfinished = chosen.flatMap { store.canStartSessions ? CodingAILogins.awaiting(store.snapshot.accounts, signIn: store.signIn, provider: $0.id, address: draft) : nil }
        let canSignIn = store.canStartSessions
        let blocked = store.busy || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || chosen == nil
            || !canSignIn || problem != nil || (already != nil && unfinished == nil)

        VStack(alignment: .leading, spacing: 0) {
            Text("Add account")
                .font(.title3.weight(.semibold))
                .padding([.horizontal, .top], 20)
                .padding(.bottom, 12)

            Form {
                Section("Which agent is this a login for?") {
                    ForEach(rows) { row in
                        agentRow(row, selected: chosen?.id == row.id)
                    }
                }

                Section("Which email address?") {
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
                        Text("Sign in, in the terminal that opens.")
                        NativeCodingAIInfo(label: "Signing in", text: Self.signingInNote)
                    }
                    if unfinished != nil {
                        NativeCodingAINotice(tone: .info, text: "You started adding this one already. Sign in to finish it.")
                    } else if already != nil {
                        NativeCodingAINotice(tone: .warn, text: "This \(chosen?.label ?? "agent") login is already on this computer. Use it from the account menu — a second copy would only be another sign-in for the same login.")
                    }
                    if let problem {
                        VStack(alignment: .leading, spacing: 4) {
                            NativeCodingAINotice(tone: .warn, text: problem.text)
                            if let install = problem.install {
                                HStack(spacing: 4) {
                                    Text("Install it with").font(.callout)
                                    NativeCodingAICommand(text: install)
                                }
                            }
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
        .frame(width: 460)
        .frame(minHeight: 520)
        .onAppear {
            draft = ""
            clicked = store.addingProvider
            emailFocused = true
        }
    }

    private func agentRow(_ row: CodingAIProviderRow, selected: Bool) -> some View {
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
                    if !row.available, let install = row.install {
                        NativeCodingAICommand(text: install)
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
        guard !email.isEmpty, let chosen else { return }
        // Closed on the way: the sign-in opens in the main window.
        dismiss()
        store.addingPresented = false
        if let unfinished {
            store.signIn(unfinished)
            return
        }
        store.signInToNewAccount(name: email, provider: chosen.id)
    }

    static let signingInNote = "A session starts on that agent and it asks you to log in. Your password goes only to the agent’s own sign-in page; the login it hands back is kept by this app, encrypted, so switching to this account later needs no sign-in. The agent signs in whoever your browser is signed in as — if that is another account, sign out there first. Its conversations are kept with your own install where the agent allows it, so one started under this account can be continued under another."
}
