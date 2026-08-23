/**
 * **Log in to a server** — the door Asad asked for, and the one this app had on
 * the Mac and not on the phone.
 *
 * ## What was wrong with the screen this replaces
 *
 * `AddServerView` asks for a **server address**: a 130-character token that only
 * a *running* headless host prints. It is a real door and it stays — see the
 * note at the bottom of this file — but it is the second one, because it cannot
 * be the first: a bare server has no host on it, so it prints nothing, so there
 * is nothing to paste. The old screen's answer to that was a footer saying *"no
 * Terminal Deck on that machine yet?"* with a `curl … | sh` to copy, and his
 * verdict on it is the reason this file exists:
 *
 * > *"Right now on iOS the add-server page tells us: if you don't have a server
 * > yet, copy this command and paste it there — curl … terminaldeck install. **I
 * > don't want that command.** The steps should be: first they log in to the
 * > server."*
 *
 * So: address, port, username, and a password or a key. The four things anybody
 * who has ever been given a server already has, and nothing else — no token to
 * fetch first, no command to run somewhere else, no host that has to exist
 * before this screen works.
 *
 * ## The port is a field, and it is the one with a history
 *
 * The desktop's form shipped without one, defaulted to 22, and the one machine
 * Asad tried to add listens on **2222** — so the app told him *"That address did
 * not answer. The server may be off, or something in between may be blocking
 * it"* about a number it had chosen without telling him. There was no route out
 * of that: nothing on screen mentioned a port, so nothing on screen could be
 * corrected. It is here, empty, optional, and it says on its face that empty
 * means 22.
 *
 * ## Every state ends somewhere
 *
 * Three phases and none of them spins forever: reaching the server, asking it
 * what it is, and then either a server on the list or a headline with the next
 * move under it. The form comes back *underneath* a failure rather than being
 * replaced by it, so fixing one field is one tap rather than starting again.
 */

import SwiftUI

struct ServerLoginView: View {
    let model: DeckModel
    /// Leaving, and the server that arrived — nil on a cancel. The caller uses
    /// it to push straight to the server's own page, which is where the sign-in
    /// was going.
    let close: (StoredServer?) -> Void

    @State private var address = ""
    @State private var port = ""
    @State private var username = ""
    @State private var secret = ""
    @State private var method: EnrollMethod = .password
    /// Whether the **other** door is up — see `addressDoor`.
    @State private var pastingAnAddress = false
    @FocusState private var focused: Field?

    private enum Field: Hashable { case address, port, username, secret }

    private var connector: ServerConnector { model.serverConnector }

    #if DEBUG
    /**
     * A login handed in by a test, so the flow can be walked against a **real
     * server** rather than against a mock of one.
     *
     * The same shape `GitHubEndpoints` already uses for its stand-in: DEBUG
     * only, read from the environment, invisible to a release build. It exists
     * because the interesting half of this screen is what happens *after* the
     * password — a real SSH handshake, a real host key, a real probe of a real
     * machine — and none of that can be photographed from a fixture.
     *
     * Four variables, none of which is ever written down: `TD_SERVER_ADDRESS`,
     * `TD_SERVER_PORT`, `TD_SERVER_USER`, and one of `TD_SERVER_PASSWORD` or
     * `TD_SERVER_KEY_BASE64`. They live for the length of one test process and
     * reach nothing else.
     *
     * The key arrives **base64**, and that is not decoration: a private key is
     * forty lines, and a multi-line value does not survive being handed from
     * `xcodebuild` to the test runner to `launchEnvironment` intact. It arrived
     * empty, the Log in button stayed disabled because there was no secret, the
     * tap did nothing, and the walk sat waiting sixty seconds for a screen no
     * button had been pressed to reach. One line goes through.
     */
    private func prefillFromEnvironment() {
        let environment = ProcessInfo.processInfo.environment
        guard let host = environment["TD_SERVER_ADDRESS"], !host.isEmpty else { return }
        address = host
        port = environment["TD_SERVER_PORT"] ?? ""
        username = environment["TD_SERVER_USER"] ?? ""
        if let encoded = environment["TD_SERVER_KEY_BASE64"], !encoded.isEmpty,
           let raw = Data(base64Encoded: encoded, options: [.ignoreUnknownCharacters]),
           let key = String(data: raw, encoding: .utf8) {
            method = .key
            secret = key
        } else if let password = environment["TD_SERVER_PASSWORD"] {
            method = .password
            secret = password
        }
    }
    #endif

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.background.ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        switch connector.login {
                        case let .added(server):
                            signedIn(server)
                        case .reaching, .looking:
                            working
                        case .editing, .failed:
                            form
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 8)
                    .padding(.bottom, 40)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .scrollDismissesKeyboard(.interactively)
            }
            .navigationTitle("Log in to a server")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(leaveLabel) { leave() }
                        .accessibilityIdentifier("serverLogin.done")
                }
            }
        }
        .sheet(isPresented: $pastingAnAddress) {
            AddServerView(model: model) { added in
                pastingAnAddress = false
                // That door ends in a *machine*, not a server row, so there is
                // nothing for this screen to hand back — it simply gets out of
                // the way once the machine is in the list.
                if added { close(nil) }
            }
        }
        .tint(Theme.accent)
        #if DEBUG
        .task { prefillFromEnvironment() }
        #endif
    }

    private var isFinished: Bool {
        if case .added = connector.login { return true }
        return false
    }

    private var leaveLabel: String {
        if isFinished { return "Done" }
        return connector.isSigningIn ? "Close" : "Cancel"
    }

    private func leave() {
        // The secret is spent by the time anything gets here and has no reason
        // to outlive the view.
        secret = ""
        var added: StoredServer?
        if case let .added(server) = connector.login { added = server }
        connector.resetLogin()
        close(added)
    }

    /* ----------------------------------------------------------------- form -- */

    @ViewBuilder
    private var form: some View {
        if case let .failed(headline, advice) = connector.login {
            VStack(alignment: .leading, spacing: 6) {
                Text(headline)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.warning)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("serverLogin.errorHeadline")
                if !advice.isEmpty {
                    Text(advice)
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("serverLogin.errorAdvice")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .padding(.bottom, 20)
        }

        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 0) {
                fieldLabel("Server address", about: "the address",
                           note: "The name or number you would put after `ssh` — `example.com`, or "
                               + "an IP address. It has to be reachable from this phone's network.")
                TextField("example.com", text: $address)
                    .font(.system(size: 15, design: .monospaced))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .foregroundStyle(Theme.primary)
                    .focused($focused, equals: .address)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 11)
                    .background(Theme.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(Theme.hairline, lineWidth: 1)
                    }
                    .accessibilityIdentifier("serverLogin.address")
            }
            VStack(alignment: .leading, spacing: 0) {
                fieldLabel("Port", about: "the port",
                           note: "Leave it empty unless whoever set the server up gave you a "
                               + "number. SSH is usually 22 — but a server that was moved off 22 "
                               + "will not answer on it at all, and that is a failure nothing else "
                               + "on this screen could explain.")
                TextField("22", text: $port)
                    .font(.system(size: 15, design: .monospaced))
                    .keyboardType(.numberPad)
                    .foregroundStyle(Theme.primary)
                    .focused($focused, equals: .port)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 11)
                    .background(Theme.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(Theme.hairline, lineWidth: 1)
                    }
                    .accessibilityIdentifier("serverLogin.port")
            }
            .frame(width: 92)
        }

        fieldLabel("Username", about: "the username",
                   note: "The account you would use to sign in to that server. The server checks it "
                       + "against its own SSH — nothing here decides whether it was right.")
            .padding(.top, 22)

        TextField("root, ubuntu, asad…", text: $username)
            .font(.system(size: 15))
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .foregroundStyle(Theme.primary)
            .focused($focused, equals: .username)
            .padding(.horizontal, 12)
            .padding(.vertical, 11)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Theme.hairline, lineWidth: 1)
            }
            .accessibilityIdentifier("serverLogin.username")

        fieldLabel("How you sign in", about: "the two ways in",
                   note: "Whichever that account already accepts. A key must be an Ed25519 or ECDSA "
                       + "key with no passphrase on it: nothing here can ask you for a passphrase "
                       + "on the server's behalf, and this phone cannot sign with an RSA key. "
                       + "`ssh-keygen -t ed25519` makes one that works.")
            .padding(.top, 22)

        Picker("How you sign in", selection: chosenMethod) {
            Text("Password").tag(EnrollMethod.password)
            Text("Private key").tag(EnrollMethod.key)
        }
        .pickerStyle(.segmented)
        .accessibilityIdentifier("serverLogin.method")

        if method == .password {
            /*
             * iOS will offer to save this password and nothing here can stop it
             * — measured on four shapes of this field, including the documented
             * `.oneTimeCode` opt-out. See the same note in `AddServerView`. The
             * screen's closing line is therefore written about what *this app*
             * keeps, not about what the phone does.
             */
            SecureField("Password", text: $secret)
                .font(.system(size: 15))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .foregroundStyle(Theme.primary)
                .focused($focused, equals: .secret)
                .padding(.horizontal, 12)
                .padding(.vertical, 11)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Theme.hairline, lineWidth: 1)
                }
                .padding(.top, 12)
                .accessibilityIdentifier("serverLogin.password")
        } else {
            keyField
        }

        Button {
            focused = nil
            let name = address.trimmingCharacters(in: .whitespacesAndNewlines)
            Task {
                await connector.signIn(name: name,
                                       address: address,
                                       port: Int(port.trimmingCharacters(in: .whitespaces)),
                                       username: username,
                                       secret: secret,
                                       kind: method == .key ? .key : .password)
            }
        } label: {
            Text("Log in")
                .font(.system(size: 17, weight: .semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 13)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(canSubmit ? Theme.onAccent : Theme.secondary)
        .background(Theme.accent.opacity(canSubmit ? 1 : 0.28),
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .disabled(!canSubmit)
        .padding(.top, 24)
        .accessibilityIdentifier("serverLogin.submit")

        Text("This is an ordinary SSH login, the same one a terminal would make. \(Brand.name) "
             + "keeps it on this phone, in the Keychain, and sends it to nothing but that server.")
            .font(.system(size: 12))
            .foregroundStyle(Theme.faint)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 18)

        addressDoor
    }

    /**
     * The other door, kept and moved rather than removed.
     *
     * `AddServerView` takes a **server address** — the token a host prints once
     * it is running — and signs in through the relay. That is the right door for
     * a case this screen cannot serve: a host already running on a machine you
     * have no SSH login for, whose address somebody sent you. It is second
     * because it cannot be first — a bare server prints nothing — and it is one
     * line rather than a segmented control for the reason `PairingView` gives
     * about its own fork: whoever holds an address knows they hold one, and
     * everybody else should not have to choose before they know which they are.
     */
    @ViewBuilder
    private var addressDoor: some View {
        HStack(spacing: 6) {
            Button("I have a server address instead") { pastingAnAddress = true }
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Theme.accent)
                .accessibilityIdentifier("serverLogin.addressDoor")
            InfoDot(about: "server addresses",
                    text: "A machine already running \(Brand.name) prints one. It carries where to "
                        + "meet it, which machine it is, and the key that proves it — and no "
                        + "password. Use it when somebody sent you one for a machine you have no "
                        + "SSH login for.")
            Spacer(minLength: 0)
        }
        .padding(.top, 20)
    }

    /**
     * The picker's own binding, which clears the secret **in its setter**.
     *
     * `onChange(of: method)` looks like the same thing and is not: it fires for
     * *any* change to the value, including one this code makes. The prefill sets
     * `method = .key` and then the key, and the observer then cleared the key it
     * had just been given — a Log in button that stayed disabled, a tap that did
     * nothing, and a walk that waited out its whole timeout for a screen nothing
     * had been pressed to reach. Watched happening in the simulator.
     *
     * Clearing belongs to the *act*, not to the value: somebody who switches
     * from Password to Private key must not have their typed password sent as a
     * key, and the keyboard has to go with it because the field it was over has
     * been replaced by a paste control.
     */
    private var chosenMethod: Binding<EnrollMethod> {
        Binding(get: { method },
                set: { chosen in
                    guard chosen != method else { return }
                    method = chosen
                    secret = ""
                    focused = nil
                })
    }

    private var canSubmit: Bool {
        !address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !secret.isEmpty
    }

    /**
     * The private key, pasted and never drawn.
     *
     * A `SecureField` is one line and a private key is forty, and pasting a
     * multi-line string into a single-line field is how a key arrives with its
     * newlines eaten — which fails as "that sign-in was refused", sending
     * somebody to check a password that was never the problem.
     */
    @ViewBuilder
    private var keyField: some View {
        if secret.isEmpty {
            HStack(spacing: 10) {
                Image(systemName: "key")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.secondary)
                Text("Private key")
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.secondary)
                Spacer(minLength: 0)
                // The system control: nothing here reads the pasteboard, so no
                // *Allow Paste* alert appears over a screen whose whole job is a
                // paste.
                PasteButton(payloadType: String.self) { items in
                    guard let text = items.first, !text.isEmpty else { return }
                    secret = text
                }
                .labelStyle(.titleOnly)
                .buttonBorderShape(.capsule)
                .tint(Theme.accent)
                .controlSize(.small)
                .accessibilityIdentifier("serverLogin.pasteKey")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Theme.hairline, lineWidth: 1)
            }
            .padding(.top, 12)
        } else {
            HStack(spacing: 10) {
                Image(systemName: "key.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.secondary)
                Text("Private key ready · \(secret.count) characters")
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.primary)
                    .accessibilityIdentifier("serverLogin.keyReady")
                Spacer(minLength: 0)
                Button("Clear") { secret = "" }
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.accent)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 12)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Theme.hairline, lineWidth: 1)
            }
            .padding(.top, 12)
        }
    }

    /* -------------------------------------------------------------- working -- */

    /// Two waits, each named. Reaching a server and asking it what it is fail in
    /// different ways and take different lengths of time.
    @ViewBuilder
    private var working: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                ProgressView().controlSize(.small).tint(Theme.accent)
                Text(workingHeadline)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Theme.primary)
                    .accessibilityIdentifier("serverLogin.working")
            }
            Text(workingDetail)
                .font(.system(size: 13))
                .foregroundStyle(Theme.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 24)
    }

    private var workingHeadline: String {
        if case .looking = connector.login { return "Looking at that server" }
        return "Signing in to that server"
    }

    private var workingDetail: String {
        if case .looking = connector.login {
            return "It accepted the login. This is it being asked what it is, what it is running, "
                + "and whether the host is already on it."
        }
        return "Opening an SSH connection and checking the server's identity before anything is "
            + "sent to it."
    }

    /* ------------------------------------------------------------- finished -- */

    private func signedIn(_ server: StoredServer) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 20))
                    .foregroundStyle(Theme.positive)
                Text(server.name)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(Theme.primary)
                    .accessibilityIdentifier("serverLogin.signedIn")
            }

            /*
             * The fingerprint, shown once and kept.
             *
             * This is the only moment it can be checked: from here on it is what
             * every connection is compared against, and a server answering with a
             * different one is refused before a password is offered. It is
             * printed in the form `ssh-keygen -lf` prints, so it can be checked
             * against any other tool.
             */
            if let key = server.hostKey {
                VStack(alignment: .leading, spacing: 4) {
                    Text("It proved itself with")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Theme.faint)
                        .textCase(.uppercase)
                    Text(key.fingerprint)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(Theme.primary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("serverLogin.fingerprint")
                    Text("\(key.algorithm). Every later connection is checked against this.")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.faint)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }

            Button { leave() } label: {
                Text("Open it")
                    .font(.system(size: 17, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 13)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.onAccent)
            .background(Theme.accent, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .padding(.top, 8)
            .accessibilityIdentifier("serverLogin.open")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 24)
    }

    /* ---------------------------------------------------------------- parts -- */

    private func fieldLabel(_ title: String, about: String, note: String) -> some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.faint)
                .textCase(.uppercase)
            InfoDot(about: about, text: note)
            Spacer(minLength: 0)
        }
        .padding(.bottom, 8)
    }
}
