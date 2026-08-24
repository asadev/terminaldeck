/**
 * **The** login screen. One of them, now.
 *
 * ## What was wrong, in his words
 *
 * > *"I think it has 2 pages for server login, another inside a server login
 * > page, but a little bit different. It should be only ONE full option,
 * > whatever the difference is between them."*
 *
 * He was looking at a real thing. There were two: `AddServerView`, which asked
 * for a **server address** and had no port field at all, and this one, which
 * asked for an address, a **port**, a username and a secret. The second was
 * reached from a line at the foot of the first, so the app carried two forms
 * with the same four labels, two submit buttons spelled *Sign in* and *Log in*,
 * and two code paths — and which one somebody met depended on the route they
 * took. Worse, the door that opened first was the one with no port on it, and
 * his own server listens on **2222**: the field that would have made it work was
 * on the screen he never reached.
 *
 * ## What replaced them
 *
 * One form, carrying the union: address, port, username, password or key, and
 * the fingerprint receipt. One name, one button, one screen — reached from the
 * gate, from the machines list and from the pairing screen alike.
 * `AddServerView.swift` is **deleted**, not left unreferenced.
 *
 * ## The address field takes either thing, and says which it got
 *
 * The two screens existed because there are genuinely two ways to reach a
 * machine, and both are still here — they were never two *screens*, they were
 * two things that can be in one field:
 *
 *  - a hostname or IP, which is an ordinary SSH login to a bare server; or
 *  - the **server address** a host that is already running prints — a
 *    130-character block carrying a relay, a host id and a key — for a machine
 *    somebody sent you the address of and that you have no SSH login for.
 *
 * `ServerAddress.parse` decides, because the block announces itself and a
 * hostname cannot be mistaken for one. The person is told which was recognised,
 * under the field, before they press anything. The fork is in the transport
 * where it belongs, not in the navigation.
 *
 * ## The key field is a field
 *
 * It was a paste-only pill reporting *"412 characters"*, and a character count
 * cannot tell a whole key from one whose seven lines were flattened into one.
 * It is a real multi-line field now, and what is printed under it is
 * `PrivateKeyReadback` — the line count, whether BEGIN and END are both there,
 * and whether **the reader that is about to sign with it** could read it.
 *
 * ## The step after the login is part of the login
 *
 * > *"Right after logging in we need to have the step for checking/installing
 * > headless Terminal Deck."*
 *
 * So a successful login does not close this screen. It becomes a receipt with
 * three things on it: what the server proved itself with, the offer of Face ID
 * for next time, and `HostStepCard` — the check, the install, the start and the
 * connect, in that order, on the screen somebody is already standing on.
 */

import SwiftUI

struct ServerLoginView: View {
    let model: DeckModel

    /**
     * Whether this screen **is** the window rather than a sheet over one.
     *
     * The gate — a phone with no machine and no server — leads with this screen
     * now rather than with a pairing code, so it has no Cancel and its secondary
     * door is pairing rather than nothing. *"Say no MacBook or any Windows
     * exists at all — a user only has a server and a phone."*
     */
    var isGate = false

    /// Leaving, and the server that arrived — nil on a cancel, and nil for the
    /// address door, which ends in a machine rather than a server row.
    var close: ((StoredServer?) -> Void)?

    @State private var address = ""
    @State private var port = ""
    @State private var username = ""
    @State private var secret = ""
    @State private var method: EnrollMethod = .password
    @FocusState private var focused: Field?

    /**
     * The four things somebody types, as one type.
     *
     * It is doing two jobs at once and that is deliberate: it is the value
     * `@FocusState` holds, and it is the `.id` each field carries inside the
     * scroll view. One case means one field means one place to scroll to, so
     * "which field has focus" and "where on the form is it" can never disagree.
     * `.secret` is the password field or the key field, whichever the picker is
     * showing — never both at once, so the id stays unique.
     */
    private enum Field: Hashable { case address, port, username, secret }

    private var connector: ServerConnector { model.serverConnector }

    /// What is in the address field, as this screen understands it. Recomputed
    /// rather than stored: a stored answer is one that can disagree with the
    /// field it describes.
    private var pastedAddress: Bool {
        if case .success = ServerAddress.parse(address) { return true }
        return false
    }

    #if DEBUG
    /**
     * A login handed in by a test, so the flow can be walked against a **real
     * server** rather than against a mock of one.
     *
     * DEBUG only, read from the environment, invisible to a release build. It
     * exists because the interesting half of this screen is what happens *after*
     * the password — a real SSH handshake, a real host key, a real probe of a
     * real machine — and none of that can be photographed from a fixture.
     *
     * The key arrives **base64**, and that is not decoration: a private key is
     * seven lines, and a multi-line value does not survive being handed from
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
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 0) {
                            switch stage {
                            case .form:
                                form
                            case .working:
                                working
                            case let .arrived(server):
                                arrived(server)
                            case let .connected(name):
                                connected(name)
                            }
                        }
                        .padding(.horizontal, 20)
                        .padding(.top, 8)
                        .padding(.bottom, 40)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    /*
                     * `.never`, not `.interactively`, and the difference is a
                     * form.
                     *
                     * Interactive dismissal reads a downward touch as the start
                     * of the gesture that puts the keyboard away, which is what
                     * you want in something you scroll and read. This is five
                     * fields somebody fills in order, and a tap from Username
                     * into Password IS a downward touch: it was being taken as
                     * the dismiss gesture and never reaching the field, so the
                     * next keystrokes went nowhere. XCUITest reported it as
                     * "neither element nor any descendant has keyboard focus";
                     * a person just finds that their password did not go in.
                     *
                     * That was the gesture half of the fault. The other half is
                     * geometry, and it is `reveal` below.
                     */
                    .scrollDismissesKeyboard(.never)
                    /*
                     * **And the field that just took focus is moved out from
                     * under the keyboard.**
                     *
                     * Measured on an iPhone 17 Pro: 852 points tall, and the
                     * keyboard with its bar over it takes the bottom ~380. The
                     * password field sits at y=532 with the form scrolled to the
                     * top — under the keyboard, by fifty points. A tap there
                     * lands on the keyboard, and both a test and a person get
                     * the same nothing: XCUITest says "neither element nor any
                     * descendant has keyboard focus", and a person finds their
                     * password did not go in and is given no reason.
                     *
                     * SwiftUI's own keyboard avoidance did not do it — the
                     * `ScrollView` takes the safe-area inset, so the field stops
                     * being *reachable by scrolling*, but nothing scrolls to it.
                     * This does, on every focus change, however focus arrived:
                     * a tap, the bar's Next, or Previous.
                     */
                    .onChange(of: focused) { was, field in
                        guard let field else { return }
                        reveal(field, proxy, keyboardIsArriving: was == nil)
                    }
                }
            }
            /*
             * One headline, not two.
             *
             * Photographed on the gate: an inline navigation title reading "Log
             * in to a server" sitting directly above a headline reading "Log in
             * to your server". Two near-identical sentences stacked, and the
             * navigation bar on the gate has nothing else in it — no Back, no
             * Cancel — so it was a whole bar spent restating the line under it.
             * As a sheet the bar earns its keep, because it carries the button
             * that closes the sheet.
             */
            .navigationTitle(isGate ? "" : "Log in to a server")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                // The gate has nowhere to go back to, so it has no button. A
                // Cancel on the first screen of an app with nothing behind it is
                // a control that cannot act.
                if !isGate {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button(leaveLabel) { leave() }
                            .accessibilityIdentifier("serverLogin.done")
                    }
                }
                keyboardBar
            }
        }
        .tint(Theme.accent)
        #if DEBUG
        .task {
            prefillFromEnvironment()
            /*
             * **Press it too**, when a walk asks for that.
             *
             * `TD_SERVER_AUTOSUBMIT=1`, DEBUG only, beside the prefill and for
             * the same reason: the interesting half of this screen is what
             * happens *after* the button — the handshake, the host key, the
             * probe, the offer of Face ID, the check-and-install step — and none
             * of it can be reached without a finger. With this, the whole flow
             * can be driven by `simctl launch` and photographed, which is the
             * only way to look at it on a machine that cannot afford to run the
             * UI-test host.
             *
             * It presses the button; it does not bypass it. Everything the tap
             * does — the validation, the two transports, the phases — happens
             * exactly as it does for a finger.
             */
            guard ProcessInfo.processInfo.environment["TD_SERVER_AUTOSUBMIT"] == "1",
                  canSubmit else { return }
            submit()
        }
        #endif
    }

    /* --------------------------------------------------------------- stage -- */

    /**
     * Where this screen is, from **both** transports at once.
     *
     * One switch over two flows, because the person is doing one thing. A
     * hostname goes through `ServerConnector`, a pasted server address goes
     * through `ServerSignIn`, and neither of them is a different screen.
     */
    private enum Stage {
        case form
        case working
        /// Signed in to a server over SSH. The check/install step lives here.
        case arrived(StoredServer)
        /// Connected to a host — the end of the address door, and the end of
        /// the SSH door once its Connect has landed.
        case connected(String)
    }

    private var stage: Stage {
        if case let .signedIn(_, name) = model.serverSignIn.phase { return .connected(name) }
        switch connector.login {
        case let .added(server):
            return .arrived(server)
        case .reaching, .looking:
            return .working
        case .editing, .failed:
            return model.serverSignIn.isBusy ? .working : .form
        }
    }

    private var isFinished: Bool {
        switch stage {
        case .arrived, .connected: return true
        case .form, .working: return false
        }
    }

    private var leaveLabel: String {
        if isFinished { return "Done" }
        return connector.isSigningIn || model.serverSignIn.isBusy ? "Close" : "Cancel"
    }

    /**
     * Leaving — and, from the gate, going somewhere rather than nowhere.
     *
     * A sheet hands its server back to `RootView`, which pushes the server's own
     * page. The gate has no presenter to hand anything to, so it does that
     * itself: releasing the window with nothing else said would drop somebody on
     * an empty Sessions tab after they had just logged in to a machine —
     * *"then all the server-related stuff comes up."*
     */
    private func leave() {
        // The secret is spent by the time anything gets here and has no reason
        // to outlive the view.
        secret = ""
        var added: StoredServer?
        if case let .added(server) = connector.login { added = server }
        connector.resetLogin()
        if case .signedIn = model.serverSignIn.phase { model.serverSignIn.edit() }
        if isGate {
            if let added {
                model.show(.settings)
                // Machines under it, not just the server: Back has to land
                // somewhere that makes sense, and the list this server is now on
                // is that place.
                model.settingsRoute = [.machines, .server(added.id)]
            }
            // Released last, so the screen this replaces is already chosen.
            model.holdingTheLoginGate = false
        }
        close?(added)
    }

    /* ------------------------------------------------------------ keyboard -- */

    /**
     * **A bar over the keyboard, and the field it is covering scrolled up.**
     *
     * ## The bug, in one measurement
     *
     * The password field is at y=532 on an iPhone 17 Pro. The phone is 852
     * points tall and the keyboard takes the bottom ~336 of them — ~380 with
     * this bar on top — so everything below y≈472 is under it. The field is not
     * hidden, it is *covered*: it draws, XCUITest finds it, `.tap()` reports
     * success, and the touch lands on a key of the keyboard instead. What comes
     * back is "Neither element nor any descendant has keyboard focus", and what
     * a person gets is a password that did not go in, with nothing on screen
     * saying so. On an iPhone SE, where the frame is 667 points, it is worse:
     * the *username* field goes under too.
     *
     * ## The two halves of the answer
     *
     * A bar, so nobody has to reach a covered field at all — Previous, Next and
     * Done, the ordinary iOS answer to a form. And `reveal`, so the field that
     * took focus is scrolled out from under the keyboard whichever way focus
     * got there, including a finger on a field that *is* visible.
     *
     * Done replaces `serverLogin.portDone`, which existed because a number pad
     * has no return key of its own. It still does not — the same button now
     * gets a finger off every keyboard on the screen rather than off one of
     * them, and a bar that changes its controls per field is a bar people stop
     * reading.
     */
    @ToolbarContentBuilder
    private var keyboardBar: some ToolbarContent {
        ToolbarItemGroup(placement: .keyboard) {
            Button { movePrevious() } label: {
                Image(systemName: "chevron.up")
            }
            .disabled(!canGoPrevious)
            .accessibilityLabel("Previous field")
            .accessibilityIdentifier("serverLogin.keyboardPrevious")

            Button { moveNext() } label: {
                Image(systemName: "chevron.down")
            }
            .disabled(!canGoNext)
            .accessibilityLabel("Next field")
            .accessibilityIdentifier("serverLogin.keyboardNext")

            Spacer()

            Button("Done") { focused = nil }
                .accessibilityIdentifier("serverLogin.keyboardDone")
        }
    }

    /**
     * The fields in the order a finger goes through them — and only the ones
     * somebody can actually type in.
     *
     * The port is dropped when a pasted server address has disabled it. A Next
     * that lands on a disabled field is a Next that looks broken: the keyboard
     * stays up, nothing gets focus, and the next keystroke goes nowhere — which
     * is the fault this whole bar exists to end, reintroduced by the fix for it.
     */
    private var order: [Field] {
        var fields: [Field] = [.address]
        if !pastedAddress { fields.append(.port) }
        fields.append(.username)
        fields.append(.secret)
        return fields
    }

    private var focusedIndex: Int? {
        guard let focused else { return nil }
        return order.firstIndex(of: focused)
    }

    private var canGoPrevious: Bool {
        guard let index = focusedIndex else { return false }
        return index > 0
    }

    private var canGoNext: Bool {
        guard let index = focusedIndex else { return false }
        return index + 1 < order.count
    }

    private func movePrevious() {
        guard let index = focusedIndex, index > 0 else { return }
        focused = order[index - 1]
    }

    private func moveNext() {
        guard let index = focusedIndex, index + 1 < order.count else { return }
        focused = order[index + 1]
    }

    /**
     * Put the focused field where somebody can see it.
     *
     * ## Why it scrolls twice
     *
     * The keyboard takes about a quarter of a second to come up, and until it
     * has, the scroll view's visible height is still the whole screen. A scroll
     * issued now centres the field against a viewport that is about to shrink
     * out from under it — which lands the field roughly where it started. So it
     * is issued twice: once immediately, so the movement happens *with* the
     * keyboard rather than after it and does not read as a jump, and once when
     * the keyboard has landed and the height is true.
     *
     * The second pass runs **only** while the keyboard is on its way up, and
     * that restriction was paid for. Moving between two fields with the
     * keyboard already standing, the height is already true and the extra pass
     * is not a correction but a second animation starting 400ms after the first
     * — which is 400ms after somebody's finger left the field and about when
     * their first character arrives. Measured: tapping Password and typing
     * `hunter2` put **six** characters in the field. A form that eats the first
     * letter of a password is the same complaint as one that eats all of them,
     * only harder to notice.
     *
     * ## Why 0.35 rather than the middle
     *
     * A field's own label sits above it, and centring the field puts the label
     * on the edge or off it. A third of the way down keeps the label, the field
     * and the sentence under the field all in the visible strip — and for the
     * key field, which is up to eighteen lines tall, it keeps the BEGIN line on
     * screen rather than the middle of the base64.
     */
    private func reveal(_ field: Field, _ proxy: ScrollViewProxy, keyboardIsArriving: Bool) {
        let anchor = UnitPoint(x: 0.5, y: 0.35)
        Task { @MainActor in
            /*
             * **After** the focus change has finished, never inside it.
             *
             * Scrolling synchronously from `onChange` puts the scroll view's
             * relayout in the same transaction as the old field resigning first
             * responder, and the keystroke that field had not committed yet is
             * lost in it. Measured, twice, on the walk: `asad` typed into the
             * username and `asa` read back out of it after the finger moved to
             * the password — one character, silently, and only ever the last one
             * before focus moved. A form that eats a letter of somebody's
             * username is a login that fails for a reason nothing on screen
             * explains.
             *
             * A `Task` hop is enough: SwiftUI commits the focus change, and the
             * scroll starts on the next turn of the main actor.
             */
            withAnimation(.easeOut(duration: 0.25)) {
                proxy.scrollTo(field, anchor: anchor)
            }
            guard keyboardIsArriving else { return }
            try? await Task.sleep(nanoseconds: 400_000_000)
            // Focus may have moved on — two taps in quick succession — and the
            // last one is the one that decides where the form sits.
            guard focused == field else { return }
            withAnimation(.easeOut(duration: 0.2)) {
                proxy.scrollTo(field, anchor: anchor)
            }
        }
    }

    /* ----------------------------------------------------------------- form -- */

    @ViewBuilder
    private var form: some View {
        if isGate { gateHeader }

        if let failure = currentFailure {
            VStack(alignment: .leading, spacing: 6) {
                Text(failure.headline)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.warning)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("serverLogin.errorHeadline")
                if !failure.advice.isEmpty {
                    Text(failure.advice)
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

        addressRow
        recognised

        fieldLabel("Username", about: "the username",
                   note: "The account you would use to sign in to that server. The server checks it "
                       + "against its own SSH — nothing here decides whether it was right.")
            .padding(.top, 22)

        TextField("root, ubuntu, asad…", text: $username)
            .font(.system(size: 15))
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            // No `textContentType`. Declaring this `.username` beside a
            // `.password` field is the shape AutoFill reads as an account for
            // *this app*, which it is not — the account belongs to the server.
            .foregroundStyle(Theme.primary)
            .focused($focused, equals: .username)
            .padding(.horizontal, 12)
            .padding(.vertical, 11)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Theme.hairline, lineWidth: 1)
            }
            .accessibilityIdentifier("serverLogin.username")
            .id(Field.username)

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
             * `.oneTimeCode` opt-out, on iOS 26.5. So the field is the simple
             * one, and the screen's closing line is written about what *this
             * app* keeps rather than about what the phone does.
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
                .id(Field.secret)
        } else {
            keyField
        }

        Button {
            focused = nil
            submit()
        } label: {
            Text("Log in")
                .font(.system(size: 17, weight: .semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 13)
                // The whole pill takes the touch, not the word in the middle of
                // it.
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

        pairingDoor
    }

    /**
     * The gate's one sentence.
     *
     * It says what this app needs and does not name a computer, because the
     * person reading it may not own one: *"Say no MacBook or any Windows exists
     * at all — a user only has a server and a phone."* The pairing door is
     * further down, where somebody who does own one will find it.
     */
    private var gateHeader: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Log in to your server")
                .font(.system(size: 26, weight: .semibold))
                .foregroundStyle(Theme.primary)
                .accessibilityIdentifier("serverLogin.title")
            Text("Its address, the account you already use on it, and the password or key that "
                 + "account already accepts. Nothing else has to exist first.")
                .font(.system(size: 14))
                .foregroundStyle(Theme.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.bottom, 22)
    }

    /* -------------------------------------------------------- address + port -- */

    /**
     * The address, full width — and the port on its **own row** under it.
     *
     * They were side by side, and two things were wrong with that in the
     * photograph. The address column was squeezed to two thirds of a 390-point
     * screen, which is not enough for the thing it has to be able to hold: a
     * printed server address is 130 unbroken characters. And the Paste control
     * sat at the top of that narrow column, which put it level with the PORT
     * label and touching it — so the one button on the row read as belonging to
     * the field it was not for.
     *
     * The port getting a row of its own is not a consolation prize. It is the
     * field whose absence made his own server — sshd on **2222** — unreachable
     * from the screen he actually met, and a row with a sentence beside it is
     * harder to miss than a 92-point box in a corner.
     */
    @ViewBuilder
    private var addressRow: some View {
        HStack(spacing: 6) {
            Text("Server address")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.faint)
                .textCase(.uppercase)
            InfoDot(about: "the address",
                    text: "The name or number you would put after `ssh` — `example.com`, "
                        + "or an IP address, reachable from this phone's network. It also "
                        + "takes the whole **server address** block a machine already "
                        + "running \(Brand.name) prints, if somebody sent you one: that "
                        + "carries its own endpoint, so the port is not used with it.")
            Spacer(minLength: 0)
            /*
             * The **system** paste control, not a button that reads the
             * pasteboard. `UIPasteboard.general.string` is a read of another
             * app's clipboard and raises an *Allow Paste* alert; `PasteButton`
             * hands the string over with no prompt, because the tap *is* the
             * consent.
             */
            PasteButton(payloadType: String.self) { items in
                guard let text = items.first?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                      !text.isEmpty else { return }
                address = text
            }
            .labelStyle(.titleOnly)
            .buttonBorderShape(.capsule)
            // Tinted with the accent: a `PasteButton` takes its label's ink from
            // its tint, and the panel grey produced a control that read as
            // disabled.
            .tint(Theme.accent)
            .controlSize(.small)
            .accessibilityIdentifier("serverLogin.pasteAddress")
        }
        .padding(.bottom, 8)

        // Vertical axis so a pasted server address — two or three wrapped lines
        // of base64 — is visible rather than scrolled off the right.
        TextField("example.com", text: $address, axis: .vertical)
            .lineLimit(1...5)
            .font(.system(size: 15, design: .monospaced))
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .keyboardType(.asciiCapable)
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
            .id(Field.address)

        fieldLabel("Port", about: "the port",
                   note: "Leave it empty unless whoever set the server up gave you a "
                       + "number. SSH is usually 22 — but a server that was moved off 22 "
                       + "will not answer on it at all, and that is a failure nothing else "
                       + "on this screen could explain.")
            .padding(.top, 18)

        HStack(alignment: .center, spacing: 12) {
            TextField("22", text: $port)
                .font(.system(size: 15, design: .monospaced))
                .keyboardType(.numberPad)
                .foregroundStyle(pastedAddress ? Theme.faint : Theme.primary)
                .focused($focused, equals: .port)
                .padding(.horizontal, 12)
                .padding(.vertical, 11)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(Theme.hairline, lineWidth: 1)
                }
                // Disabled rather than hidden when a server address is in the
                // field above it: a field that disappears reads as a screen that
                // changed, and the sentence under it already says why.
                .disabled(pastedAddress)
                .frame(width: 96)
                .accessibilityIdentifier("serverLogin.port")
                /*
                 * **A number pad has no return key**, and the shared bar is
                 * what gets a finger off it — `keyboardBar`, above.
                 *
                 * There used to be a Done here and nowhere else, conditioned on
                 * `focused == .port`, on the reasoning that the other keyboards
                 * have return keys of their own. They do, and it was still the
                 * wrong shape: a return key moves the cursor, it does not move
                 * the form, so the field after this one was still under the
                 * keyboard when it got focus. One bar over every keyboard,
                 * carrying Previous and Next as well, is what a form needs.
                 */
                .id(Field.port)

            Text(pastedAddress
                 ? "Not used with a server address."
                 : "Empty means 22.")
                .font(.system(size: 13))
                .foregroundStyle(Theme.faint)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }

    /// What the address field is holding, said before anything is pressed.
    @ViewBuilder
    private var recognised: some View {
        if pastedAddress {
            Label("That is a server address — this phone will meet that machine through its relay, "
                  + "so the port is not used.",
                  systemImage: "checkmark.seal")
                .font(.system(size: 12))
                .foregroundStyle(Theme.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 8)
                .accessibilityIdentifier("serverLogin.recognisedAddress")
        }
    }

    /* ------------------------------------------------------------ the key -- */

    /**
     * The private key, in a field that can hold one.
     *
     * ## Why this is not a `SecureField`
     *
     * A `SecureField` is one line. A private key is seven, and a single-line
     * field eats the newlines between them — the key reaches the server as one
     * run of base64, the handshake fails, and the screen says *"that sign-in was
     * refused"*, which sends somebody to check a password that was never the
     * problem. Measured: the key that comes back out of a secure field is not
     * the key that went in.
     *
     * ## Why it is not the paste-only pill either
     *
     * That was the previous answer and it was half of one. It could take a
     * paste, and all it said afterwards was *"412 characters"* — a number that
     * is the same whether the seven lines survived or were flattened into one.
     * What is under the field now is `PrivateKeyReadback`: how many lines
     * arrived, whether BEGIN and END are both there, and whether **the reader
     * that will sign the handshake** could read the bytes. A key that is not
     * going to work says so here, before the login, in the reader's own words.
     *
     * ## It is visible, and that is the deliberate half
     *
     * A key somebody just pasted into their own phone, on the screen where they
     * are deciding whether the paste worked, is a key they are entitled to look
     * at. Nothing logs it, nothing leaves the device with it but the server it
     * is for, and hiding it would remove the only evidence the paste was whole.
     */
    @ViewBuilder
    private var keyField: some View {
        let readback = PrivateKeyReadback.of(secret)

        HStack(spacing: 6) {
            Text("Private key")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.faint)
                .textCase(.uppercase)
                .accessibilityIdentifier("serverLogin.keyLabel")
            Spacer(minLength: 0)
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
        .padding(.top, 14)
        .padding(.bottom, 8)

        TextField("-----BEGIN OPENSSH PRIVATE KEY-----", text: $secret, axis: .vertical)
            /*
             * Tall enough for the whole key, because the whole key is the point.
             *
             * At 4...12 an ed25519 key wrapped to about thirteen visual lines
             * and the field clipped its **END** line — under a sentence claiming
             * "BEGIN and END are both here". The claim was true and the screen
             * contradicted it, which is worse than saying nothing. Photographed
             * on the simulator with a real key in.
             */
            .lineLimit(4...18)
            .font(.system(size: 12, design: .monospaced))
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            // Not `.asciiCapable`: a key is pasted, and the ASCII keyboard has
            // no newline of its own on a phone.
            .keyboardType(.default)
            .foregroundStyle(Theme.primary)
            .focused($focused, equals: .secret)
            .padding(.horizontal, 12)
            .padding(.vertical, 11)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(readbackTint(readback), lineWidth: 1)
            }
            .accessibilityIdentifier("serverLogin.key")
            .id(Field.secret)

        if let sentence = readback.sentence {
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: readback.isGood ? "checkmark.circle" : "exclamationmark.triangle")
                    .font(.system(size: 12))
                    .foregroundStyle(readback.isGood ? Theme.positive : Theme.warning)
                VStack(alignment: .leading, spacing: 2) {
                    Text(sentence)
                        .font(.system(size: 12))
                        .foregroundStyle(readback.isGood ? Theme.secondary : Theme.warning)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("serverLogin.keyReady")
                    if case let .bad(_, advice) = readback {
                        Text(advice)
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.top, 8)

            Button("Clear") { secret = "" }
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Theme.accent)
                .padding(.top, 4)
                .accessibilityIdentifier("serverLogin.clearKey")
        }
    }

    private func readbackTint(_ readback: PrivateKeyReadback) -> Color {
        switch readback {
        case .nothing: return Theme.hairline
        case .good: return Theme.positive.opacity(0.5)
        case .bad: return Theme.warning.opacity(0.6)
        }
    }

    /* -------------------------------------------------------- the other door -- */

    /**
     * Pairing, kept and moved rather than removed.
     *
     * > *"I want the standard way to sign in used everywhere — server address,
     * > username, password or key."*
     *
     * So it is a line under the login rather than the headline above it. It is
     * not deleted and it is not hidden: somebody standing at their own Mac
     * should find it in one look, and the six digits are still the right door
     * for a machine with a screen and a person in front of it.
     */
    @ViewBuilder
    private var pairingDoor: some View {
        HStack(spacing: 6) {
            Button {
                focused = nil
                // Presented by `RootView` for the reason the login sheet is: a
                // successful pairing moves this phone past the gate, and a sheet
                // owned by the view being torn down goes with it.
                if !isGate { close?(nil) }
                // And the gate stops holding the window: pairing is going to
                // move this phone past it, and a hold left over from a login
                // that failed would pin it here.
                model.holdingTheLoginGate = false
                model.addingHost = true
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: "desktopcomputer")
                        .font(.system(size: 13))
                    Text("Pair with a Mac or Windows PC instead")
                        .font(.system(size: 14, weight: .medium))
                        .multilineTextAlignment(.leading)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.accent)
            .accessibilityIdentifier("serverLogin.pairingDoor")

            InfoDot(about: "pairing",
                    text: "A computer running \(Brand.name) shows a six-digit code, and somebody at "
                        + "it approves this phone. A server has no screen to show a code on and "
                        + "nobody standing at it, which is why the login above is the way in for "
                        + "one.")
            Spacer(minLength: 0)
        }
        .padding(.top, 20)
    }

    /* -------------------------------------------------------------- submit -- */

    /**
     * One button, two transports.
     *
     * A pasted server address goes through `ServerSignIn` — the relay, the
     * sealed channel, the host's own `enroll` — because that is what the block
     * is *for*: a machine with no SSH login this phone holds. Anything else is
     * an ordinary SSH login through `ServerConnector`. The person pressed one
     * button either way, and the sentence under the address field already told
     * them which was recognised.
     */
    private func submit() {
        // Claim the window before anything can succeed. Succeeding is what
        // destroys this screen otherwise — see `DeckModel.holdingTheLoginGate`.
        if isGate { model.holdingTheLoginGate = true }
        let raw = address.trimmingCharacters(in: .whitespacesAndNewlines)
        if pastedAddress {
            model.serverSignIn.submit(address: raw,
                                      username: username,
                                      secret: secret,
                                      method: method)
            return
        }
        Task {
            await connector.signIn(name: raw,
                                   address: raw,
                                   port: Int(port.trimmingCharacters(in: .whitespaces)),
                                   username: username,
                                   secret: secret,
                                   kind: method == .key ? .key : .password)
        }
    }

    /**
     * The picker's own binding, which clears the secret **in its setter**.
     *
     * `onChange(of: method)` looks like the same thing and is not: it fires for
     * *any* change to the value, including one this code makes. The prefill sets
     * `method = .key` and then the key, and the observer then cleared the key it
     * had just been given — a Log in button that stayed disabled and a walk that
     * waited out its whole timeout. Watched happening in the simulator.
     */
    private var chosenMethod: Binding<EnrollMethod> {
        Binding(get: { method },
                set: { chosen in
                    guard chosen != method else { return }
                    method = chosen
                    // The two fields hold different things and one is never the
                    // other. Carrying a typed password into the key field would
                    // be offering to send a password as a private key.
                    secret = ""
                    focused = nil
                })
    }

    private var canSubmit: Bool {
        !address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !secret.isEmpty
    }

    /// Whichever transport last refused, in its own words. Never this screen's
    /// guess about a failure it did not see.
    private var currentFailure: (headline: String, advice: String)? {
        if case let .failed(headline, advice) = connector.login {
            return (headline, advice)
        }
        if case let .failed(failure) = model.serverSignIn.phase {
            return (failure.headline, failure.advice)
        }
        return nil
    }

    /* -------------------------------------------------------------- working -- */

    /// The waits, each named. Reaching a server, being checked by it, and being
    /// signed in fail in different ways and take different lengths of time, and
    /// somebody watching a phone for fifteen seconds is entitled to know which.
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

            if model.serverSignIn.isBusy {
                Text("Closing this screen does not stop it.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.faint)
                Button("Stop") { model.serverSignIn.cancel() }
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Theme.accent)
                    .padding(.top, 4)
                    .accessibilityIdentifier("serverLogin.cancelSignIn")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 24)
    }

    private var workingHeadline: String {
        switch model.serverSignIn.phase {
        case .reaching: return "Reaching that machine"
        case .verifying: return "Checking that login"
        case .joining: return "Signing this phone in"
        default: break
        }
        if case .looking = connector.login { return "Looking at that server" }
        return "Signing in to that server"
    }

    private var workingDetail: String {
        switch model.serverSignIn.phase {
        case .reaching:
            return "Opening a sealed channel to it. Nothing has been sent yet."
        case .verifying:
            return "It is checking the username and the password or key against its own SSH. It "
                + "does not answer until that comes back."
        case .joining:
            return "It accepted the login and issued this phone a credential. This is the phone "
                + "presenting it."
        default: break
        }
        if case .looking = connector.login {
            return "It accepted the login. This is it being asked what it is, what it is running, "
                + "and whether \(Brand.name) is already on it."
        }
        return "Opening an SSH connection and checking the server's identity before anything is "
            + "sent to it."
    }

    /* ------------------------------------------- the step after the login -- */

    /**
     * Logged in — and the next step is on this screen rather than behind it.
     *
     * Three things, in the order they matter: what the server proved itself
     * with, the offer of Face ID for next time, and the check-and-install step.
     * *"Right after logging in we need to have the step for checking/installing
     * headless Terminal Deck."*
     */
    private func arrived(_ server: StoredServer) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 20))
                    .foregroundStyle(Theme.positive)
                Text("Logged in to \(server.name)")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(Theme.primary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("serverLogin.signedIn")
            }

            /*
             * The fingerprint, shown once and kept.
             *
             * This is the only moment it can be checked: from here on it is what
             * every connection is compared against, and a server answering with
             * a different one is refused before a password is offered. Printed
             * in the form `ssh-keygen -lf` prints, so it can be checked against
             * any other tool.
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

            /*
             * **There is no Face ID card here any more, and that is the change
             * of 2026-08-24.**
             *
             * There was one: *"Use Face ID next time?"*, offered the moment a
             * login succeeded, which put that server's password behind the
             * sensor. It was the right offer at the wrong altitude. Because this
             * app reconnects to the server it was last on as it opens, "ask
             * before reading this server's password" turned out to mean "ask
             * every single time the app opens" — Asad: *"I don't want it to come
             * every time when we open the application. If it is that way then
             * remove the face lock. I wanted this face lock actually not just
             * for one specific server — make it for the overall application."*
             *
             * So the lock moved to the front door and became one switch on the
             * main Settings page: `AppLockSection`. Nothing is offered here, on
             * the server's own page, or anywhere else. A credential this phone
             * holds is still in the Keychain, still device-only, and is read the
             * way it always was.
             */
            HostStepCard(model: model, serverId: server.id, justLoggedIn: true)

            if let trouble = connector.problems[server.id] {
                VStack(alignment: .leading, spacing: 4) {
                    Text(trouble.headline)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.warning)
                    Text(trouble.advice)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.secondary)
                }
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("serverLogin.serverProblem")
            }

            // Named for what it does rather than "Done": this leaves the login
            // and opens the server's own page, which is a different thing from
            // finishing the connect above it.
            Button { leave() } label: {
                Text("Open this server")
                    .font(.system(size: 17, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 13)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.primary)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Theme.hairline, lineWidth: 1)
            }
            .accessibilityIdentifier("serverLogin.open")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 12)
        .onChange(of: signedInHostId) { _, hostId in
            // The connect ran through the sign-in flow the app already has, so
            // this is where its result is written down.
            if let hostId { connector.markConnected(server.id, hostId: hostId) }
        }
    }

    private var signedInHostId: String? {
        if case let .signedIn(hostId, _) = model.serverSignIn.phase { return hostId }
        return nil
    }

    /* ------------------------------------------------------------ connected -- */

    private func connected(_ name: String) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 20))
                    .foregroundStyle(Theme.positive)
                Text(name)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(Theme.primary)
                    .accessibilityIdentifier("serverLogin.connected")
            }

            Text("Connected. It is in your machines now, and its sessions are on the Sessions tab.")
                .font(.system(size: 14))
                .foregroundStyle(Theme.secondary)
                .fixedSize(horizontal: false, vertical: true)

            /*
             * Worded as a claim about **this app** rather than about the phone.
             *
             * It used to read "the password you typed was not kept", which is
             * what this code does and is not what somebody sees: iOS raises its
             * own *Save Password?* offer on submit and cannot be talked out of
             * it. Somebody who tapped Save would then read a sentence telling
             * them the opposite had happened.
             */
            Text("\(Brand.name) keeps your sign-in in this iPhone's Keychain and sends it to "
                 + "nothing but that machine.")
                .font(.system(size: 12))
                .foregroundStyle(Theme.faint)
                .fixedSize(horizontal: false, vertical: true)

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
            .accessibilityIdentifier("serverLogin.openMachine")
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
