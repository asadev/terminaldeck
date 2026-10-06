import SwiftUI
import TerminalDeckNativeCore

/// A server's Advanced panel (`ServerAdvanced.tsx`), behind its own button: what
/// the server is, what could not be found out, how you sign in, its identity,
/// letting Hoot act on it for an hour, whether its terminals may drive browser
/// windows here, what to call it, and forgetting it.
struct NativeServerAdvanced: View {
    let server: CodingAIServer
    let extra: CodingAIServer.Extra
    let state: ServerRoomState?
    let now: Double
    let onRename: (String) -> Void
    let onForget: () -> Void
    let onGrant: (Double) -> Void
    let onRevoke: () -> Void
    let onDrivesWindows: (Bool) -> Void
    @State private var open = false
    @State private var confirmForget = false
    @State private var name: String?

    var body: some View {
        if !open {
            Button("Advanced") { open = true }
        } else {
            VStack(alignment: .leading, spacing: 12) {
                Button("Hide advanced") { open = false }

                heading("What this server is")
                let facts = state?.view?.facts
                fact("System", ServerAdvancedText.factLine(facts?["os"], say: { $0.string ?? "" }, none: "It did not say."))
                fact("Its own name for itself", ServerAdvancedText.factLine(facts?["hostname"], say: { $0.string ?? "" }, none: "It did not say."))
                fact("Signed in as", ServerAdvancedText.factLine(facts?["user"], say: { $0.string ?? "" }, none: "It did not say."))
                fact("Accepting connections", ServerAdvancedText.factLine(facts?["listeners"], say: ServerAdvancedText.listenersLine, none: "Nothing."))
                fact("Installs software with", ServerAdvancedText.factLine(facts?["packageManager"], say: { $0.string ?? "" }, none: "Nothing we recognise."))
                NativeSettingsProse(text: "Installing updates is not something this app does — there is no way to undo it, and everything here has a way back.")

                if let cannot = state?.view?.cannot, !cannot.isEmpty {
                    heading("What we could not find out")
                    ForEach(cannot.indices, id: \.self) { index in
                        fact(cannot[index].what, cannot[index].why)
                    }
                }

                heading("How you sign in")
                fact("Name you sign in with", server.username)
                fact("Kept on this computer", ServerAdvancedText.credentialLine(extra.credential))
                NativeSettingsProse(text: "To sign in a different way, forget this server below and add it again. Nothing on the server changes either way.")

                heading("This server's identity")
                NativeSettingsProse(text: "Every server has one, and it does not change. If it ever does, this app stops and says so rather than signing in — the whole point is that it cannot be waved past. You can compare what is below against the server itself, because every other tool prints the same thing.")
                fact("Identity", ServerAdvancedText.identityLine(extra.fingerprint))

                grantPanel

                heading("Its terminals can open and drive browser windows here")
                let allowed = extra.drivesWindows
                NativeSettingsProse(text: allowed
                    ? "On, because you added this server yourself. An agent in a terminal on this server can open browser windows here and act on the ones you attach — nothing else in the browser, and nothing you did not hand it."
                    : "Off, because you turned it off. Terminals on this server cannot open a browser window here or act on one you attach, and nothing on this machine asks them to.")
                NativeSettingsProse(text: "\(allowed ? "Untick it" : "Tick it") to \(allowed ? "keep" : "let") this server’s terminals \(allowed ? "out of the browser here" : "into the browser here"). It works with Claude Code; Codex and Gemini have no setting this app can add to a command you type yourself.")
                Toggle("Sessions on \(server.name) may act on browser windows here", isOn: Binding(get: { allowed }, set: onDrivesWindows))
                    .toggleStyle(.checkbox)

                heading("What to call it here")
                HStack {
                    TextField("What to call this server", text: Binding(get: { name ?? server.name }, set: { name = $0 }))
                        .textFieldStyle(.roundedBorder)
                        .accessibilityLabel("What to call this server")
                    let typed = (name ?? server.name).trimmingCharacters(in: .whitespacesAndNewlines)
                    Button("Save") { onRename(typed) }
                        .disabled(typed.isEmpty)
                }

                heading("Forget this server")
                if confirmForget {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("This removes \(server.name) from this list and forgets the sign-in kept on this computer. Nothing on the server changes, and you can add it again with the same details.")
                            .fixedSize(horizontal: false, vertical: true)
                        HStack {
                            Button("Forget it", role: .destructive, action: onForget)
                            Button("Cancel") { confirmForget = false }
                        }
                    }
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.08)))
                } else {
                    Button("Forget it", role: .destructive) { confirmForget = true }
                }
            }
        }
    }

    /// `ServerCopilotGrant`.
    @ViewBuilder private var grantPanel: some View {
        heading("Let Hoot use this server")
        NativeSettingsProse(text: "Off unless you turn it on, and then only for this one server and only for a while. It covers the named actions on that server’s page and nothing else at all — not the terminal, not the sign-in, not forgetting it.")
        NativeSettingsProse(text: "Without it Hoot can still look, and has to ask you before it changes anything.")
        if let grant = state?.grant, grant.expiresAt > now {
            HStack(spacing: 10) {
                Text(ServerAdvancedText.allowedFor(grant, now: now))
                Button("Stop allowing it", action: onRevoke)
            }
        } else {
            Button("Allow it for an hour") { onGrant(ServerAdvancedText.grantMs) }
        }
    }

    private func heading(_ text: String) -> some View {
        Text(text)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.top, 4)
            .accessibilityAddTraits(.isHeader)
    }

    private func fact(_ label: String, _ value: String) -> some View {
        LabeledContent(label) {
            Text(value)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
    }
}
