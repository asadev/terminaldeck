/**
 * **Add a server** — the screen 0.10.0 shipped without.
 *
 * ## The complaint this answers
 *
 * *"I don't see any option there to pair it with server as I explained multiple
 * times in a big details how I want it to be but I don't see a difference."* He
 * is right, and the reason was not laziness: 0.10.0 shipped the entire `enroll`
 * wire — frames, host verifier, driver, roster — and no screen on any phone
 * client, because a phone opening a *first* connection needs the machine's
 * X25519 public key to run the handshake and a host id is a hash. There was
 * nothing valid to put in a form. `ServerAddress.swift` is the thing that was
 * missing; this is the form.
 *
 * ## Why it is a second door rather than a second mode of pairing
 *
 * Pairing is six digits read off a machine **somebody is standing at**. A server
 * is a machine nobody is standing at — that is what makes it a server — so there
 * is no screen to read a code from and no human to press Approve. The door for
 * one is a code; the door for the other is a login that machine already trusts,
 * checked against its own sshd. Two doors, both ending in exactly the same
 * place: a `StoredCredential` in the Keychain and a machine in the list.
 *
 * ## What is on the screen and what is behind an ⓘ
 *
 * Three fields and a button. Everything that would have been a paragraph — what
 * a server address is, that it carries no secret, what the key field will and
 * will not accept — is behind an ⓘ beside the thing it is about, which is the
 * rule this product's screens follow.
 *
 * ## No camera
 *
 * A QR scan is not offered, and that is deliberate rather than missing.
 * `NSCameraUsageDescription` was removed from `Support/Info.plist` when the QR
 * pairing path was deleted, and nothing in this binary opens the camera. Adding
 * a scanner for this one field would put a permission prompt — and an App Review
 * question — in front of every user of the app for a convenience that a paste
 * already covers. If a scanner comes back it comes back for the whole app, not
 * for this screen.
 *
 * ## Every state ends somewhere
 *
 * `ServerSignIn.Phase` has no state that spins forever: the reach and the verify
 * both carry deadlines, a refusal carries the server's own sentence, and each
 * failure is a headline with the next move under it. The form comes back
 * underneath a failure rather than replacing it, so fixing one field is one tap
 * rather than starting again.
 */

import SwiftUI
import UIKit

struct AddServerView: View {
    let model: DeckModel

    /**
     * Leaving, and whether a machine arrived.
     *
     * The flag is what lets the **Pair another machine** sheet — which presents
     * this one — close itself on a sign-in and stay up on a cancel. Without it
     * that screen would have to guess from `model.isPaired`, which is already
     * true every time it is on screen.
     */
    let close: (_ added: Bool) -> Void

    @State private var address = ""
    @State private var username = ""
    @State private var secret = ""
    @State private var method: EnrollMethod = .password
    @FocusState private var focused: Field?

    private enum Field: Hashable { case address, username, secret }

    /**
     * Read through, never copied.
     *
     * The flow belongs to the model for the reason `GitHubAccountView`'s does:
     * this exchange runs a real SSH login on the far machine and takes as long
     * as that takes, and a flow owned by a sheet dies on the button somebody
     * presses when the screen has not caught up yet.
     */
    private var flow: ServerSignIn { model.serverSignIn }

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.background.ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        switch flow.phase {
                        case let .signedIn(_, name):
                            signedIn(name)
                        case .reaching, .verifying, .joining:
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
            .navigationTitle("Add a server")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    /*
                     * Three words for three situations, because this button
                     * does a different thing in each.
                     *
                     * "Done" once there is a machine — a Cancel there would
                     * read as undoing the sign-in it just finished. "Close"
                     * while something is in flight, because that is all it
                     * does: the flow belongs to the model and keeps running.
                     * "Cancel" only where nothing has happened yet. Two
                     * buttons both saying Cancel, one of which abandons an
                     * attempt and one of which does not, is the kind of pair
                     * somebody taps the wrong half of.
                     */
                    Button(leaveLabel) { leave() }
                        .accessibilityIdentifier("addServer.done")
                }
            }
        }
        .tint(Theme.accent)
    }

    private var isFinished: Bool {
        if case .signedIn = flow.phase { return true }
        return false
    }

    private var leaveLabel: String {
        if isFinished { return "Done" }
        return flow.isBusy ? "Close" : "Cancel"
    }

    /**
     * Leaving.
     *
     * Nothing in flight is cancelled on the way out — the sign-in belongs to the
     * model and finishes on its own, and there is a Cancel *inside* the working
     * state for somebody who has actually changed their mind. What is dropped is
     * the secret typed into this screen, which has already been spent by the
     * time anything gets here and has no reason to survive the view.
     */
    private func leave() {
        secret = ""
        let added = isFinished
        // Back to the form, so reopening this screen offers a sign-in rather
        // than the receipt for the last one.
        if added { flow.edit() }
        close(added)
    }

    /* ----------------------------------------------------------------- form -- */

    @ViewBuilder
    private var form: some View {
        if case let .failed(failure) = flow.phase {
            VStack(alignment: .leading, spacing: 6) {
                Text(failure.headline)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.warning)
                    .accessibilityIdentifier("addServer.errorHeadline")
                Text(failure.advice)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("addServer.errorAdvice")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .padding(.bottom, 20)
        }

        /*
         * The paste control sits **beside the label, not inside the field**.
         *
         * It was inside it, on the trailing edge, and the first real address
         * pasted into it ran underneath the pill — a server address is one
         * unbroken 130-character token and a monospaced wrap does not respect a
         * sibling's width the way the layout implied it would. Rendered, seen,
         * moved. The field now owns its whole row, which is what a field
         * holding four wrapped lines of base64 needs.
         */
        HStack(spacing: 6) {
            Text("Server address")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.faint)
                .textCase(.uppercase)
            InfoDot(about: "server addresses",
                    text: "A server prints this. It carries three things — where to meet it, which "
                        + "machine it is, and the key that proves it is that machine — and no password "
                        + "or token, so it is safe to send yourself. Paste the whole block.")
            Spacer(minLength: 0)
            /*
             * The **system** paste control, not a button that reads the
             * pasteboard.
             *
             * `UIPasteboard.general.string` is a read of another app's
             * clipboard, and since iOS 16 every one of those puts an *Allow
             * Paste* alert in front of the person — on the one screen where
             * pasting is the entire interaction, and for the one thing they
             * were told to copy. `PasteButton` is the control that hands the
             * string over with no prompt at all, because the tap *is* the
             * consent. Trimmed on the way in for the same reason the field is:
             * a copied block usually arrives with a newline on the end.
             */
            PasteButton(payloadType: String.self) { items in
                guard let text = items.first?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !text.isEmpty else { return }
                address = text
            }
            .labelStyle(.titleOnly)
            .buttonBorderShape(.capsule)
            // Tinted with the accent rather than a surface colour. A
            // `PasteButton` derives its label's ink from its tint, so tinting
            // it with the panel grey produced a grey capsule with near-white
            // text — a control that read as disabled, photographed in light
            // mode before this line existed.
            .tint(Theme.accent)
            .controlSize(.small)
            .accessibilityIdentifier("addServer.paste")
        }
        .padding(.bottom, 8)

        TextField("wss://relay… + host id + key", text: $address, axis: .vertical)
            .lineLimit(2...6)
            .font(.system(size: 13, design: .monospaced))
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .keyboardType(.asciiCapable)
            .foregroundStyle(Theme.primary)
            .focused($focused, equals: .address)
            .accessibilityIdentifier("addServer.address")
            .padding(.horizontal, 12)
            .padding(.vertical, 11)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Theme.hairline, lineWidth: 1)
            }

        fieldLabel("Username", about: "the username",
                   note: "The account you would use to SSH into that server. The server checks it "
                       + "against its own SSH — this app never sees whether it was right, only that "
                       + "the server said so.")
            .padding(.top, 22)

        TextField("root, ubuntu, asad…", text: $username)
            .font(.system(size: 15))
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            // No `textContentType`. Declaring this `.username` beside a
            // `.password` field is the shape AutoFill reads as an account for
            // *this app*, which it is not — the account belongs to the server.
            // It does not stop the save offer, which nothing does; see the note
            // on the field below.
            .foregroundStyle(Theme.primary)
            .focused($focused, equals: .username)
            .padding(.horizontal, 12)
            .padding(.vertical, 11)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Theme.hairline, lineWidth: 1)
            }
            .accessibilityIdentifier("addServer.username")

        fieldLabel("How you sign in", about: "the two ways in",
                   note: "Whichever that account already accepts. A key must be an unencrypted "
                       + "private key — one with a passphrase on it cannot be used here, because "
                       + "nothing on this screen can ask you for the passphrase on the server's "
                       + "behalf. \(Brand.name) keeps neither: what it keeps is the credential the "
                       + "server mints in exchange for it, which that server can revoke on its own.")
            .padding(.top, 22)

        Picker("How you sign in", selection: $method) {
            Text("Password").tag(EnrollMethod.password)
            Text("Private key").tag(EnrollMethod.key)
        }
        .pickerStyle(.segmented)
        .onChange(of: method) { _, _ in
            // The two fields hold different things and one is never the other.
            // Carrying a typed password into the key field would be offering to
            // send a password as a private key.
            secret = ""
            // And the keyboard goes with it. Choosing **Private key** replaces
            // the field below with a paste control, so a keyboard left standing
            // is one covering the Sign in button with nothing left to type
            // into — photographed on the simulator with the key already in.
            focused = nil
        }
        .accessibilityIdentifier("addServer.method")

        if method == .password {
            /*
             * **iOS will offer to save this password, and nothing here can stop
             * it.** Measured, not assumed.
             *
             * The alert is *Save Password?*, raised by AutoFill the moment the
             * sign-in is submitted, offering to write an SSH password into the
             * iCloud Keychain — where it syncs to every device on the account.
             * Four shapes of this field were built and photographed on the
             * simulator against a real host, and every one of them raised it:
             * with `.username`/`.password` declared, with no content type at
             * all, with `.textContentType(.oneTimeCode)` — the documented
             * opt-out — and with a `UITextField` in a `UIViewRepresentable`
             * carrying `.oneTimeCode` directly, where the opt-out is supposed
             * to apply. On iOS 26.5 the heuristic fires for any secure field.
             *
             * So the field is the simple one again, the UIKit detour is deleted
             * rather than left in carrying a comment that claims a fix it does
             * not deliver, and **the screen's closing line was rewritten to be
             * true either way**: it says what this app keeps, not what the
             * phone does. The offer is the person's to answer, and the first
             * button on it is Not Now.
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
                .accessibilityIdentifier("addServer.password")
        } else {
            keyField
        }

        Button {
            focused = nil
            flow.submit(address: address, username: username, secret: secret, method: method)
        } label: {
            Text("Sign in")
                .font(.system(size: 17, weight: .semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 13)
                // The whole pill takes the touch, not the word in the middle of
                // it — see the note on the same trap in `GitHubAccountView`.
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(canSubmit ? Theme.onAccent : Theme.secondary)
        .background(Theme.accent.opacity(canSubmit ? 1 : 0.28),
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .disabled(!canSubmit)
        .padding(.top, 24)
        .accessibilityIdentifier("addServer.submit")

        installFooter
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
     * multi-line string into a single-line field is how a key arrives at the
     * server with its newlines eaten — which fails as *"that sign-in was
     * refused"*, sending somebody to check a password that was never the
     * problem. So the key is taken from the clipboard whole and what is shown is
     * a count, not the bytes. Nothing on this screen ever renders it.
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
                // The system control again — see the note on the address field.
                // Nothing here reads the pasteboard; the tap hands the string
                // over, which is also why no *Allow Paste* alert appears over a
                // screen whose whole job is a paste.
                PasteButton(payloadType: String.self) { items in
                    guard let text = items.first, !text.isEmpty else { return }
                    secret = text
                }
                .labelStyle(.titleOnly)
                .buttonBorderShape(.capsule)
                .tint(Theme.accent)
                .controlSize(.small)
                .accessibilityIdentifier("addServer.pasteKey")
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
                    // On the label, never on the row around it: an identifier on
                    // a container makes the container the accessibility element
                    // and everything inside it stops existing. See the note in
                    // `UITests/TabNavigation.swift`, which cost a night.
                    .accessibilityIdentifier("addServer.keyReady")
                Spacer(minLength: 0)
                Button("Clear") { secret = "" }
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.accent)
                    .accessibilityIdentifier("addServer.clearKey")
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

    /**
     * The one-line install, for a machine that has no host on it yet.
     *
     * The same fallback the browser client shows and for the same reason: this
     * phone has no SSH client linked into it, so it cannot install a host on a
     * bare box itself. Saying so, with the command to run, is the honest version
     * of a screen that would otherwise refuse an address that does not exist yet
     * and explain nothing.
     */
    @ViewBuilder
    private var installFooter: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("No \(Brand.name) on that machine yet?")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.faint)
                .textCase(.uppercase)

            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(installCommand)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(Theme.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Button("Copy") { UIPasteboard.general.string = installCommand }
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.accent)
                    .accessibilityIdentifier("addServer.copyInstall")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .padding(.top, 28)
    }

    /* -------------------------------------------------------------- working -- */

    /**
     * The three waits, each named.
     *
     * Not one spinner captioned "Signing in…". Reaching a server, waiting on its
     * SSH check, and spending the credential it minted fail in different ways
     * and take different lengths of time, and somebody watching a phone for
     * fifteen seconds is entitled to know which of the three is happening.
     */
    @ViewBuilder
    private var working: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                ProgressView().controlSize(.small).tint(Theme.accent)
                Text(workingHeadline)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Theme.primary)
                    .accessibilityIdentifier("addServer.working")
            }
            Text(workingDetail)
                .font(.system(size: 13))
                .foregroundStyle(Theme.secondary)
                .fixedSize(horizontal: false, vertical: true)

            // Said because it is not obvious and because the alternative is
            // somebody pressing Close at the twelve-second mark and believing
            // they have stopped something. The sign-in belongs to the model —
            // the same fault, and the same fix, as the GitHub device flow.
            Text("Closing this screen does not stop it.")
                .font(.system(size: 12))
                .foregroundStyle(Theme.faint)

            // "Stop", not a second Cancel. This one abandons the attempt;
            // the one in the toolbar merely leaves the screen, and the line
            // above says so.
            Button("Stop") { flow.cancel() }
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Theme.accent)
                .padding(.top, 4)
                .accessibilityIdentifier("addServer.cancelSignIn")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 24)
    }

    private var workingHeadline: String {
        switch flow.phase {
        case .reaching: return "Reaching that server"
        case .verifying: return "Checking that login"
        case .joining: return "Signing this phone in"
        default: return ""
        }
    }

    private var workingDetail: String {
        switch flow.phase {
        case .reaching:
            return "Opening a sealed channel to it. Nothing has been sent yet."
        case .verifying:
            return "The server is checking the username and password against its own SSH. "
                + "It does not answer until that comes back."
        case .joining:
            return "It accepted the login and issued this phone a credential. This is the phone "
                + "presenting it."
        default:
            return ""
        }
    }

    /* ------------------------------------------------------------- finished -- */

    private func signedIn(_ name: String) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 20))
                    .foregroundStyle(Theme.positive)
                Text(name)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(Theme.primary)
                    .accessibilityIdentifier("addServer.signedIn")
            }

            Text("Signed in and connecting. It is in your machines now, and its sessions are on the "
                 + "Sessions tab.")
                .font(.system(size: 14))
                .foregroundStyle(Theme.secondary)
                .fixedSize(horizontal: false, vertical: true)

            /*
             * Said out loud because it is the property that makes signing in
             * from a phone safe at all — and worded as a claim about **this
             * app** rather than about the phone.
             *
             * It used to read "the password you typed was not kept", which is
             * what this code does and is not what somebody sees: iOS raises its
             * own *Save Password?* offer on submit and cannot be talked out of
             * it (see the note on the field). Somebody who tapped Save would
             * then read a sentence telling them the opposite had happened.
             */
            Text("\(Brand.name) did not keep your password. What it stores is the credential the "
                 + "server issued, which that server can revoke on its own.")
                .font(.system(size: 12))
                .foregroundStyle(Theme.faint)
                .fixedSize(horizontal: false, vertical: true)

            Button {
                leave()
            } label: {
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
            .accessibilityIdentifier("addServer.open")
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
