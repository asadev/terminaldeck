/**
 * One session, full screen.
 *
 * Attaches on appear and detaches on disappear. Detaching matters: the desktop
 * fans output out to every attached client, and a phone that never says it has
 * gone keeps a session pushing bytes at a socket nobody is reading.
 *
 * The keyboard is not raised automatically. A terminal that grabs the keyboard
 * on entry covers half of the thing the person came to look at, and the usual
 * reason to open this screen from a phone is to read what an agent has been
 * doing, not to type at it. Tapping the terminal, or the keyboard button in the
 * toolbar, raises it — and the key bar comes with it.
 *
 * ## What happens when the connection drops here
 *
 * The banner appears, `send` starts refusing rather than buffering, and the
 * terminal keeps showing what it already had — which is honest, because that
 * output really did arrive. What it must not do is accept keystrokes into a
 * socket that is gone, so the toolbar's keyboard button goes away with the
 * connection and the key bar's keys refuse through the same path as typing.
 * When the socket comes back the model re-attaches by itself; the button here is
 * for the case where the user wants to force a fresh replay.
 */

import SwiftUI

struct TerminalScreen: View {
    let model: DeckModel
    /**
     * Which machine this session belongs to.
     *
     * Named rather than inferred from "whichever host is current". Session ids
     * come from each machine's own session layer and nothing makes them unique
     * across machines, so a screen that resolved its session against the current
     * host would attach to the wrong machine's session the moment the ids
     * happened to collide — and would silently show a *different* session rather
     * than failing.
     */
    let hostID: String
    let sessionID: String

    /// The phone's colour scheme, held so the letterbox around the emulator is
    /// painted in the same ground the emulator is and repaints with it. A stored
    /// property rather than a reach for `.shared` inside `body`, because
    /// `@Observable` only re-runs a body that *read* the object.
    var themes: TerminalThemeStore = .shared

    @State private var title: String?
    @State private var toast: String?
    /// Bumped by every message so an earlier one's dismissal cannot take a later
    /// one off the screen. Without it a pinch — which changes the text size
    /// several times in a second — leaves the last size on screen for a fraction
    /// of the time it should be, because the first message's timer clears it.
    @State private var toastGeneration = 0
    /// Which picker is up, if any. One `@State` rather than two booleans, so the
    /// impossible state — both sheets at once — cannot be expressed.
    @State private var picking: Picking?
    /// The find bar's state, built on first appearance because it needs the
    /// bridge, and kept across rebuilds because the term is worth keeping.
    @State private var find: FindSession?
    /// The file the share sheet is showing, if any. Written at the moment Share
    /// is chosen — see `ShareOutput`.
    @State private var sharing: SharedFile?
    /// Whether the details sheet is up: the folder this session runs in, its
    /// agent, its status and the machine it is on. See `SessionDetailView`.
    @State private var showingDetails = false
    /// Whether the control cluster is up — model, effort, fast mode, permission.
    /// See `SessionControlsView`. Only offered when an agent is drawing this
    /// session, the same rule the desktop's own cluster keeps.
    @State private var showingControls = false
    /**
     * Whether this session is being read as a conversation rather than as a
     * terminal.
     *
     * The two are the same session and the same socket — chat mode is a
     * different *view*, not a second channel — so switching costs nothing on
     * the far machine and a message typed in one appears in the other.
     *
     * The terminal is not rebuilt on the way back: `TerminalHostView` hands
     * back `bridge.container`, a UIView the bridge owns, so taking it out of
     * the hierarchy and putting it back keeps the emulator and its scrollback.
     */
    @State private var chatMode = false

    /**
     * A file chosen on the phone in chat mode, waiting for a press.
     *
     * The terminal's own menu items send the moment the picker closes, which is
     * right there: the picker *was* the press. A conversation has a composer, and
     * *"if we send the files we can have a preview and kind of things when we are
     * on chat mode"* — so in chat mode the file is staged here first, drawn by
     * the composer, and sent by a second press. Cleared either way, and the
     * staged copy in this app's temporary directory is deleted on a discard
     * because nothing downstream will: `FileUpload` deletes it when a transfer
     * ends, and a file that was never sent has no transfer.
     */
    @State private var staged: PickedFile?
    /// One of the machine's files, opened from a path in the conversation.
    @State private var reading: FileReading?
    /// Whether the note about what a transcript can and cannot show is up. See
    /// `SessionChatView`'s header for the whole of it.
    @State private var showingChatNote = false

    /// The two ways in. Both run out of process; see `FilePickers.swift`.
    private enum Picking: String, Identifiable {
        case photos
        case files
        var id: String { rawValue }
    }

    /// Identifiable so the reader is presented by *item*: presenting by a
    /// boolean with the path in a second variable opens the sheet a frame before
    /// the path is set, and `FileTextView` reads its path once, on appear.
    private struct FileReading: Identifiable {
        let path: String
        var id: String { path }
    }

    /// A written transcript, on its way to the share sheet. Identifiable so the
    /// sheet is presented by *item*: presenting by boolean would open the sheet
    /// a frame before the file existed.
    private struct SharedFile: Identifiable {
        let url: URL
        let subject: String
        var id: String { url.path }
    }

    /// The machine, or nil when it has just been unpaired out from under this
    /// screen. Every use below tolerates that rather than force-unwrapping: an
    /// unpair while a terminal is open is a real sequence, not an impossible one.
    private var host: HostLink? { model.host(hostID) }
    private var bridge: TerminalBridge { host?.bridge(for: sessionID) ?? model.bridge(for: sessionID) }
    private var session: RemoteSession? { host?.session(sessionID) }
    private var connection: ConnectionState { host?.connection ?? .offline }
    /// Read from the machine rather than computed here, so this screen and the
    /// session list under it cannot disagree about whether the connection is
    /// worth mentioning. See `HostLink.notice`.
    private var showsConnectionNotice: Bool { host?.notice.isShowing ?? false }

    var body: some View {
        ZStack {
            // The chosen scheme's ground, not the app's — see
            // `TerminalPalette.dynamicBackground`.
            Color(TerminalPalette.dynamicBackground(themes.selected)).ignoresSafeArea()

            /*
             * Two things want the bottom sixty points of this screen and only
             * one of them may have it, so the two levers are deliberately
             * different levers.
             *
             * This modifier refuses the **container** inset, which on iOS 26 is
             * where the floating tab pill's band lives. Inside a session there is
             * no pill — `DeckChrome` decides it and `DeckTabs` states it at the
             * `TabView` — and without this the space would still be reserved for
             * a bar nothing draws. *"Inside the session we don't need the pill."*
             *
             * What it must not also refuse is the **home indicator**, which is a
             * fact about the hardware rather than a piece of this app's chrome.
             * It did, once, and he reported it: *"at the bottom we cannot see
             * some stuff because of the mobile's round corners and the
             * running-agents things… leave a little space when the keyboard is
             * off."* That half is now `TerminalContainerView`'s, which is a
             * UIKit view sitting against the real bottom edge and therefore the
             * one thing here that can measure the indicator rather than guess at
             * it. Read its header before touching either lever; deleting one of
             * them re-creates one of the two bugs.
             *
             * `.container` and not `.all`: keyboard avoidance is a separate
             * region and this screen wants it. It is what lifts the terminal
             * above the keyboard, and it is also what makes the inset below
             * disappear while somebody is typing.
             */
            if chatMode, let bar = host?.bar {
                SessionChatView(bar: bar,
                                // The session this screen is drawing, handed in
                                // rather than read off the bar. The bar follows
                                // one session per machine and two of these
                                // screens can be alive at once, so "the bar's
                                // session" and "this screen's session" are two
                                // different facts and the chat view is only
                                // allowed to draw the conversation when they
                                // agree. See `SessionBarLink.release`.
                                sessionID: sessionID,
                                // The folder the agent's relative paths are
                                // relative to. The machine's own answer, never
                                // this app's guess — absent until it has sent
                                // one, and then a relative path gets no chip.
                                cwd: session?.cwd,
                                reload: { reclaimBar() },
                                // Absent for a guest device: `files` is
                                // owner-only, so a path chip on one of those
                                // could open nothing but a refusal.
                                openFile: host?.canReadFiles == true ? { reading = FileReading(path: $0) } : nil,
                                attach: host?.canSendFiles == true ? { pick($0) } : nil,
                                attachment: attachment,
                                send: connection.isLive ? { message in
                                    host?.sendChatMessage(message, into: sessionID)
                                } : nil)
            } else {
                TerminalHostView(bridge: bridge)
                    .ignoresSafeArea(.container, edges: .bottom)
            }

            // Over the terminal rather than above it. See `FindBar`: inserting
            // it into the layout would take rows off the session, which is a
            // `resize` on the wire and a repaint on the far end — for a bar
            // whose whole purpose is to leave the output alone while you read
            // it.
            if let find, find.isOpen {
                VStack(spacing: 0) {
                    FindBar(find: find) { closeFind() }
                    Spacer(minLength: 0)
                }
                .transition(.move(edge: .top).combined(with: .opacity))
            }

            if let toast {
                VStack {
                    Spacer()
                    Text(toast)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Theme.primary)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        // A material rather than a fill: this floats over the
                        // terminal's own output and has to stay legible against
                        // whatever happens to be underneath it.
                        .background(.ultraThinMaterial, in: Capsule())
                        .padding(.bottom, 28)
                        // Named so a UI test can find it, and because a
                        // transient message is worth announcing to VoiceOver
                        // rather than leaving as a flash of text.
                        .accessibilityIdentifier("terminal.toast")
                        .accessibilityAddTraits(.updatesFrequently)
                }
                .transition(.opacity)
                .allowsHitTesting(false)
            }
        }
        .navigationTitle(title ?? session?.title ?? "Session")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) { header }
            ToolbarItemGroup(placement: .topBarTrailing) {
                /*
                 * The glyph is the **destination**, not the current mode.
                 *
                 * His correction rather than a preference, and it reverses what
                 * was built the first time: *"chat icon should be when I am on
                 * the terminal mode. And when I am on the chat mode, then it
                 * should show the terminal icon."* So the icon always names
                 * where the press goes.
                 *
                 * Absent — not disabled — when this machine cannot read a
                 * transcript at all, and absent again when it has looked and
                 * found none for this folder. Both are real states (a session
                 * running a shell, a desktop older than the capability) and the
                 * alternative is a button that opens an empty screen with
                 * nothing on it to say why.
                 */
                if showsModeButton {
                    Button {
                        toggleMode()
                    } label: {
                        Image(systemName: chatMode ? "terminal" : "bubble.left.and.bubble.right")
                    }
                    .accessibilityLabel(chatMode ? "Back to the terminal"
                                                 : "Read this session as a conversation")
                    .accessibilityIdentifier("terminal.mode")
                }

                /*
                 * The one `i` on this screen, and only while the conversation is
                 * the thing on it.
                 *
                 * *"remove this full shit — I don't want long descriptions
                 * anywhere. Just if somewhere it's very required, give the i
                 * icon."* It is required here for one reason: a chat view that
                 * shows an agent's prose and none of its tool calls looks like a
                 * chat view that has lost half the conversation, and the honest
                 * answer — the desktop's parser removed them before the frame
                 * was built — cannot be inferred from anything on screen. Three
                 * lines, behind a glyph, read once.
                 */
                if chatMode {
                    Button {
                        showingChatNote = true
                    } label: {
                        Image(systemName: "info.circle")
                    }
                    .accessibilityLabel("What this view shows")
                    .accessibilityIdentifier("chat.note")
                    .popover(isPresented: $showingChatNote) {
                        chatNote
                            .presentationCompactAdaptation(.popover)
                    }
                }

                Menu {
                    /*
                     * Find, at the top, because on a phone it is the thing this
                     * menu is opened for most.
                     *
                     * Deferred by one turn of the run loop for the same reason
                     * Rename is on the session list: raised in the frame the
                     * menu is dismissing in, the focus request that raises the
                     * keyboard arrives while a presentation is in flight and is
                     * dropped — the bar appears with no keyboard under it and
                     * reads as a field that will not accept typing.
                     */
                    Button {
                        DispatchQueue.main.async { openFind() }
                    } label: {
                        Label("Find in output", systemImage: "magnifyingglass")
                    }
                    .accessibilityIdentifier("terminal.find")

                    /*
                     * Where this session runs, what it runs as, and on which
                     * machine — the desktop's folder and account chips, which
                     * have no room to be chips on a phone.
                     *
                     * Named in the menu as well as reachable by a long press on
                     * the list row, because a gesture nobody is told about is a
                     * feature nobody has. Deferred by a turn of the run loop for
                     * the same reason Find above it is: a presentation asked for
                     * in the frame a menu is dismissing in is dropped.
                     */
                    Button {
                        DispatchQueue.main.async { showingDetails = true }
                    } label: {
                        Label("Session details", systemImage: "info.circle")
                    }
                    .accessibilityIdentifier("terminal.details")

                    /*
                     * Model, effort, fast mode, permission — the desktop's
                     * control cluster, which has no room to be inline chips on a
                     * phone. Shown only when an agent is drawing this session
                     * (`clusterShown`): a model menu over a plain shell is the
                     * defect the desktop's own cluster withdraws itself for, and
                     * over an older desktop that never advertised `controls` the
                     * reading never arrives so this stays hidden.
                     */
                    if showsControlsButton {
                        Button {
                            DispatchQueue.main.async { showingControls = true }
                        } label: {
                            Label("Model & effort", systemImage: "slider.horizontal.3")
                        }
                        .accessibilityIdentifier("terminal.controls")
                    }

                    Divider()

                    /*
                     * Copy Screen, and deliberately *only* Copy Screen.
                     *
                     * There was a "Copy Selection" item here and it had to go,
                     * because it could never do what it said. SwiftTerm clears
                     * its selection on a touch outside the terminal, so reaching
                     * this menu at all destroys the selection on the way — the
                     * item opened, correctly reported that nothing was selected,
                     * and left the pasteboard untouched. Measured on a live
                     * session: the whole screen was selected in one screenshot
                     * and the pasteboard's change count did not move.
                     *
                     * Copying a *selection* therefore lives in the two places a
                     * selection survives, and both of them are *inside* the
                     * terminal: the system callout that a long press puts over
                     * the selection itself, and the `copy` key in the key grid,
                     * which is the terminal's own `inputView`. Both are
                     * exercised in `ClipboardAndTransferUITests`.
                     */
                    Button {
                        show(host?.copyScreen(from: sessionID) ?? "Nothing to copy.")
                    } label: {
                        Label("Copy Screen", systemImage: "doc.on.doc")
                    }
                    .accessibilityIdentifier("terminal.copyScreen")
                    Button {
                        host?.paste(into: sessionID)
                    } label: {
                        Label("Paste", systemImage: "doc.on.clipboard")
                    }
                    .disabled(!connection.isLive)
                    .accessibilityIdentifier("terminal.paste")

                    /*
                     * Share, which is the other half of Copy rather than a
                     * second one: Copy takes the screen, this takes the whole
                     * scrollback as a file. See `ShareOutput` for why a file and
                     * not a string.
                     */
                    Button {
                        DispatchQueue.main.async { shareOutput() }
                    } label: {
                        Label("Share output", systemImage: "square.and.arrow.up")
                    }
                    .accessibilityIdentifier("terminal.share")

                    Divider()

                    /*
                     * Text size: two ordinary items with the size in their
                     * labels, rather than a submenu or a section.
                     *
                     * The tidier shapes were tried — "Text size ▸" with two
                     * steps inside it, and a `Section` whose header carried the
                     * size — and both cost a tap for nothing: a step is a thing
                     * people do two or three times in a row while deciding, and
                     * a submenu doubles every one of them. The size reads fine
                     * in the label, which is where the eye already is.
                     */
                    Button {
                        step(TextSize.larger(bridge.textSize))
                    } label: {
                        Label("Bigger text — \(TextSize.label(bridge.textSize))",
                              systemImage: "textformat.size.larger")
                    }
                    .disabled(!TextSize.canGoLarger(bridge.textSize))
                    .accessibilityIdentifier("terminal.textLarger")

                    Button {
                        step(TextSize.smaller(bridge.textSize))
                    } label: {
                        Label("Smaller text — \(TextSize.label(bridge.textSize))",
                              systemImage: "textformat.size.smaller")
                    }
                    .disabled(!TextSize.canGoSmaller(bridge.textSize))
                    .accessibilityIdentifier("terminal.textSmaller")

                    // Absent rather than disabled when the Mac cannot receive
                    // one: a control that can only produce a refusal is not a
                    // control. See `DeckModel.canSendFiles`.
                    if host?.canSendFiles == true {
                        Divider()
                        Button {
                            picking = .photos
                        } label: {
                            Label("Send Photo or Video", systemImage: "photo")
                        }
                        .accessibilityIdentifier("terminal.sendPhoto")
                        Button {
                            picking = .files
                        } label: {
                            Label("Send File", systemImage: "doc")
                        }
                        .accessibilityIdentifier("terminal.sendFile")
                    }

                    Divider()
                    Button {
                        host?.reattach(sessionID)
                        show("Re-attaching…")
                    } label: {
                        Label("Re-attach", systemImage: "arrow.clockwise")
                    }
                    .disabled(!connection.isLive)
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .accessibilityLabel("Session actions")
                .accessibilityIdentifier("terminal.actions")

                Button {
                    // Toggle rather than raise: the same button has to put it
                    // away again.
                    if bridge.isFocused { bridge.blur() } else { bridge.focus() }
                } label: {
                    Image(systemName: "keyboard")
                }
                .disabled(!connection.isLive)
                .accessibilityLabel("Toggle keyboard")
                .accessibilityIdentifier("terminal.keyboard")
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            VStack(spacing: 0) {
                if showsConnectionNotice {
                    /*
                     * The one thing this screen must never do is look connected
                     * when it is not. The banner is the honest half of that;
                     * `send` refusing rather than buffering is the other, and
                     * *that* half is unconditional — it is keyed off
                     * `connection.isLive` and always has been.
                     *
                     * What the grace period changes is only whether the bar is
                     * drawn, and the reason it is safe to leave a two-second drop
                     * undrawn here is the same reason it is safe on the list: the
                     * keys stop working either way, and a bar that flashes on
                     * every reconnect teaches people to ignore it — which is
                     * worse than not having it at the moment it matters. See
                     * `ConnectionGrace`.
                     */
                    Banner(text: connection.detail, tone: .warning)
                }
                if let upload = host?.upload {
                    // Under the connection banner rather than over the terminal:
                    // the point of watching an upload from a phone is to keep
                    // reading the session while it runs.
                    UploadRow(upload: upload) { host?.clearUpload() }
                }
                /*
                 * The session's own row: usage, context, account.
                 *
                 * Here rather than in the navigation bar because the bar is the
                 * *machine* and its actions, and these three are about the one
                 * session on screen. It draws nothing until an answer arrives
                 * and nothing ever if the machine does not answer `usage` and
                 * `account`, so a desktop older than those capabilities gets a
                 * screen that is exactly what it was — not a row explaining
                 * what it is missing.
                 *
                 * Above both modes, because these are facts about the session
                 * and not about which way it is being read.
                 */
                if let bar = host?.bar { SessionBarView(bar: bar) }
            }
        }
        // Out-of-process pickers. Nothing in this app reads the photo library, so
        // neither of these prompts for anything — see `FilePickers.swift`.
        .sheet(item: $picking) { which in
            switch which {
            case .photos:
                PhotoPicker { picked in
                    picking = nil
                    hand(picked)
                }
                .ignoresSafeArea()
            case .files:
                DocumentPicker { picked in
                    picking = nil
                    hand(picked)
                }
                .ignoresSafeArea()
            }
        }
        .sheet(item: $sharing) { file in
            ShareSheet(url: file.url, subject: file.subject)
        }
        /*
         * One of the machine's files, reached from a path in the conversation.
         *
         * A sheet rather than a push, and that is forced rather than preferred:
         * a push needs a case on `DeckModel.Route`, the route enum both stacks
         * are driven by, and a second destination on this screen's stack would
         * be a navigation state the copilot's stack has to agree about too.
         * `FileTextView` is the same screen `FilesView` pushes — one reader, so
         * a file read from a chat message and the same file read from the folder
         * browser cannot disagree about whether it is text.
         */
        .sheet(item: $reading) { file in
            NavigationStack {
                FileTextView(model: model, path: file.path)
                    .toolbar {
                        ToolbarItem(placement: .topBarLeading) {
                            Button("Done") { reading = nil }
                                .accessibilityIdentifier("chat.file.done")
                        }
                    }
            }
        }
        // No `open` handed in: this sheet was raised from inside the session, so
        // a button leading to the screen underneath it would be furniture.
        .sheet(isPresented: $showingDetails) {
            SessionDetailView(model: model,
                              hostID: hostID,
                              sessionID: sessionID,
                              open: nil,
                              dismiss: { showingDetails = false })
        }
        .sheet(isPresented: $showingControls) {
            if let controls = host?.controls {
                SessionControlsView(controls: controls, dismiss: { showingControls = false })
                    .presentationDetents([.medium, .large])
            }
        }
        .onAppear {
            bridge.onTitle = { title = $0 }
            bridge.onCopy = { show(host?.copy(from: sessionID) ?? "Nothing to copy.") }
            bridge.onPaste = { host?.paste(into: sessionID) }
            // A tap into the terminal destroys the selection SwiftTerm is using
            // as the match highlight, so a find bar left standing would be
            // counting matches that are no longer on screen. Tapping in means
            // "I want to type here", and that is the end of the search.
            bridge.onTapped = { closeFind() }
            // The size can change from a gesture as well as from the menu, and
            // a pinch has no other confirmation than the number.
            bridge.onTextSizeChanged = { show(TextSize.label($0)) }
            // A terminal built before the person changed the size catches up
            // here. `setTextSize` is a no-op when it already agrees, which
            // matters: setting the font at all soft-resets the emulator.
            bridge.applyStoredTextSize()
            if find == nil { find = FindSession(terminal: bridge) }
            // Before the attach, because the attach is what starts the churn
            // this tells the model to discount. See `DeckModel.watchedGrace`.
            model.watchingSession(sessionID, on: hostID)
            host?.attach(sessionID)
            // After the attach, because the three questions it asks are about a
            // session this socket has been told is on screen.
            host?.bar.follow(sessionID)
            // The control cluster over the same session — model, effort, fast
            // mode, permission — read the same way and over the same attach.
            host?.controls.follow(sessionID)
            // Last, because it turns the conversation on and the read behind
            // that is about a session the two calls above have just pointed the
            // bar at.
            landChatFirstOnTheCopilotStack()
        }
        .onDisappear {
            bridge.onCopy = nil
            bridge.onPaste = nil
            bridge.onTapped = nil
            bridge.onTextSizeChanged = nil
            // The hold on mouse reporting belongs to a bar that is on screen.
            // Leaving the session without closing the find bar would leave it
            // held, and a finger would stop driving vim in that session.
            find?.close()
            host?.detach(sessionID)
            /*
             * Nothing about this session is worth holding once its screen has
             * gone: a ring from a session nobody is looking at is a ring that
             * will be wrong by the time anybody does.
             *
             * **Named, rather than a bare `forget()`.** There is one bar per
             * machine and two of these screens can be alive at once — the
             * Sessions stack's and the Copilot stack's — and a tab swap fires
             * the arriving screen's `onAppear` without ever firing the leaving
             * screen's `onDisappear`. So this callback runs at moments when the
             * bar has already been pointed at somebody else, and wiping it then
             * is what left the chat view empty for the whole life of the screen
             * that *is* being looked at. `SessionBarLink.release` carries the
             * measured trace.
             */
            host?.bar.release(sessionID)
            // The same rule at the call site rather than inside the control
            // cluster, which is another lane's file: the cluster is one object
            // per machine too, and a screen that has gone must not clear a
            // reading another screen is drawing from.
            if host?.controls.sessionID == sessionID { host?.controls.forget() }
            chatMode = false
            // A file chosen and then abandoned. The copy the picker staged in
            // this app's temporary directory is deleted here because nothing
            // else would: `FileUpload` only deletes it when a transfer ends.
            discardStaged()
            // The moment the grace period is measured from: whatever the desktop
            // decides about this session in the next few seconds is the tail of
            // what he was just watching, not news.
            model.stoppedWatchingSession(sessionID, on: hostID)
        }
        /*
         * This screen came back in front, with no lifecycle callback to say so.
         *
         * Measured, and it is the whole reason this modifier exists: switching
         * back to a tab whose stack already has a screen on it fires **nothing**
         * — not `onAppear`, not `onDisappear` on the tab being left. So the only
         * signal that this screen is the one being looked at is the state the
         * `TabView` and the two `NavigationStack`s are themselves driven by. See
         * `frontmost`, and `SessionBarLink.release` for the trace.
         */
        .onChange(of: frontmost) { _, front in
            guard front else { return }
            reclaimBar()
        }
        // No tab bar in here — *"inside the session we don't need the pill"* —
        // and the modifier that hides it is **not** on this screen. It was, and
        // it did nothing: on iOS 26.5 the pill stayed drawn over the bottom rows
        // of a live terminal. `DeckTabs` states it at the `TabView`, which is
        // what owns the floating bar; `DeckChrome` holds the rule.
    }

    // MARK: - Mode

    /**
     * Whether the conversation can be reached from here at all.
     *
     * Four facts and every one of them load bearing: a live socket, a machine
     * that said it can read a transcript, and — once it has answered — that it
     * found one. The fourth is the way back: the button stays while the chat is
     * on screen even if the answer says there is no transcript, because a screen
     * with no way off it is worse than a button that does nothing new.
     */
    private var showsModeButton: Bool {
        guard connection.isLive, host?.bar.canReadChat == true else { return false }
        if chatMode { return true }
        return host?.bar.transcript != false
    }

    /**
     * Whether the control cluster is worth offering.
     *
     * A live socket, a machine that advertised `controls`, and — the honest half
     * — a reading that says an agent is drawing this session (`clusterShown`). A
     * model menu over a plain shell acts on nothing, so the button is simply not
     * there rather than opening onto a sheet that explains why it is empty.
     */
    private var showsControlsButton: Bool {
        guard connection.isLive, let controls = host?.controls, controls.offered else { return false }
        return SessionControls.clusterShown(controls.reading)
    }

    /**
     * Whether this screen is the one being looked at.
     *
     * Derived from the same three pieces of state the `TabView` and its two
     * `NavigationStack`s are driven by, because SwiftUI will not say. Measured on
     * the simulator against this app's exact shape — a `TabView` of two stacks
     * with a screen pushed on each — switching tabs fires the arriving screen's
     * `onAppear` and never the leaving screen's `onDisappear`, and switching
     * *back* fires nothing at all. So there is no lifecycle callback that means
     * "you are in front again", and the top of the selected tab's stack is the
     * fact itself rather than a signal about it.
     *
     * Settings and Localhost cannot have a session pushed on them, so the two
     * stacks below are the whole of it.
     */
    private var frontmost: Bool {
        let top = model.tab == .copilot ? model.copilotRoute.last : model.route.last
        return top == .session(host: hostID, id: sessionID)
    }

    /**
     * Point the machine's one bar back at this screen, and re-ask what it needs.
     *
     * Runs when this screen becomes the frontmost one and when the conversation
     * is opened. Both are the moments at which the bar can be following a
     * different session than the screen in front of somebody's eyes — the other
     * tab's `TerminalScreen` claimed it on *its* `onAppear` and this one had no
     * callback to claim it back.
     *
     * **`frontmost` is a guard and not a nicety.** Both `TerminalScreen`s are
     * alive at once and both watch the bar, so a screen that re-claimed it
     * whenever it saw the bar move would fight the other one for it: the
     * copilot's screen claims on its `onAppear`, the sessions screen sees the
     * change and claims it back, and the copilot's chat view sees *that* and
     * claims again — a loop with a `chat.read` in it. Only one screen can be at
     * the top of the selected tab's stack, so only one can be in here.
     *
     * Cheap on the far side: the three questions behind the bar are memory reads
     * and a bounded tail of a file the agent is already writing.
     */
    private func reclaimBar() {
        guard frontmost, let host else { return }
        if host.bar.sessionID != sessionID { host.bar.follow(sessionID) }
        if host.controls.sessionID != sessionID { host.controls.follow(sessionID) }
        guard chatMode else { return }
        host.bar.chatting = true
        host.bar.askChat(tail: false)
    }

    /// Swap the pane. Split from `enterChat` because there is now a second way
    /// into the conversation — arriving on the copilot's stack — and a landing
    /// that called `toggle` would turn the chat *off* for anybody who reached
    /// this screen with it already on.
    private func toggleMode() {
        if chatMode {
            chatMode = false
            host?.bar.stopChatting()
        } else {
            enterChat()
        }
    }

    /**
     * Show the conversation, and ask for it.
     *
     * The re-claim comes first and it is not defensive tidying: this is the
     * press he was making when the screen came up empty. The bar is one object
     * per machine, the other tab's terminal may have pointed it at its own
     * session, and `SessionBarLink.askChat` returns at its `guard let sessionID`
     * when the bar has been left with none — so the frame never left, no answer
     * ever came, and pressing the toggle again did the same nothing. Claiming
     * the bar before asking is what makes the press recover the screen rather
     * than repeat the failure.
     */
    private func enterChat() {
        chatMode = true
        host?.bar.chatting = true
        // The keyboard belongs to the terminal it was raised over. Leaving it up
        // would put the composer under it with the conversation squeezed into
        // whatever is left.
        bridge.blur()
        // Claimed here, **asked for by the view as it appears.** Both halves have
        // to happen and doing both here would do them twice: turning the mode on
        // is what creates `SessionChatView`, whose `onAppear` calls `reload`, so
        // a read fired here as well would put two `chat.read` frames on the wire
        // for one press and answer the same question with the same rows.
        if host?.bar.sessionID != sessionID { host?.bar.follow(sessionID) }
    }

    /**
     * **The copilot tab is a conversation; the Sessions tab is a terminal.**
     *
     * > *"copilot page should be always landing in a copilot session according
     * > to the settings of the copilot — either in an existing session if there
     * > is any, or it should start a new. But it should be always a chat to land
     * > with, terminal and chat mode too."*
     *
     * A terminal reached through the copilot comes up as the chat; the same
     * terminal reached from the session list comes up as a terminal, unchanged.
     * `DeckModel.open(session:)` already draws that line — a session opened from
     * the copilot stays on the copilot's stack so Back lands on the conversation
     * that started it — and this is the same fact read at the other end. The
     * selected tab is the test rather than the route, because a tab's stack is
     * only ever on screen while that tab is selected, and `model.tab` is one read
     * instead of a search through `copilotRoute`.
     *
     * ## Two guards, and both are exits rather than niceties
     *
     * `showsModeButton` refuses to draw the toggle when the socket is down or the
     * machine cannot serve a transcript. Forcing the chat on in either state
     * would therefore be a mode **with no way out of it** — the person would be
     * looking at an empty conversation with no button back to the terminal they
     * came for. That is the fault `DeckSurface.copilot` records having made once
     * already with the tab bar, and it is not worth re-making for a default.
     *
     * So a machine that cannot answer `chat.read`, and a session opened while the
     * connection is down, both land in the terminal. Both are honest: there is no
     * conversation to show in either case.
     *
     * It runs on **every** appearance rather than once, which is the mirror of
     * `onDisappear` setting `chatMode = false`. Appear decides, disappear
     * resets — so the mode never leaks from one visit to the next, and it never
     * leaks between the two tabs that can both be showing a terminal.
     */
    private func landChatFirstOnTheCopilotStack() {
        guard model.tab == .copilot else { return }
        guard connection.isLive, host?.bar.canReadChat == true else { return }
        enterChat()
    }

    // MARK: - Find, share, size

    private func openFind() {
        let session = find ?? FindSession(terminal: bridge)
        find = session
        withAnimation(.easeOut(duration: 0.18)) { session.open() }
    }

    private func closeFind() {
        guard let find, find.isOpen else { return }
        withAnimation(.easeOut(duration: 0.18)) { find.close() }
    }

    /**
     * Write what the terminal is holding and hand it to the share sheet.
     *
     * Written here rather than when the menu was built, because the session is
     * still printing while the menu is open — a file composed a frame earlier
     * would be missing the last thing that happened, which is very often the
     * reason somebody is sharing it.
     */
    private func shareOutput() {
        let text = bridge.scrollbackText()
        guard !text.isEmpty else {
            show("There is no output to share.")
            return
        }
        let name = ShareOutput.fileName(session: title ?? session?.title ?? "session")
        guard let url = ShareOutput.write(text, named: name) else {
            show("That could not be written to a file.")
            return
        }
        sharing = SharedFile(url: url, subject: title ?? session?.title ?? "Session output")
    }

    /// One step of the text size, applied and remembered. The toast comes from
    /// the bridge's own callback, so a pinch and this button say the same thing.
    private func step(_ size: CGFloat) {
        bridge.setTextSize(size)
        TextSize.save(bridge.textSize)
    }

    private var header: some View {
        VStack(spacing: 2) {
            Text(title ?? session?.title ?? "Session")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.primary)
                .lineLimit(1)
            HStack(spacing: 5) {
                if let session {
                    StatusDot(status: session.status)
                    // Mono, because a status is a word the desktop chose from a
                    // fixed vocabulary rather than a sentence this app wrote.
                    Text(session.status)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Theme.faint)
                } else {
                    Text(connection.label)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Theme.faint)
                }
            }
        }
        /*
         * The one element that says *a session is on screen*, on every machine.
         *
         * `terminal.mode` is drawn only where the machine serves a transcript
         * and `terminal.details` lives behind the overflow, so neither can tell
         * a landed screen from an unlanded one on a host without chat — which is
         * exactly the case `CopilotLandingUITests` walks.
         */
        .accessibilityIdentifier("session.header")
    }

    /// Copy and paste are silent by nature; without this the buttons feel
    /// broken even when they worked.
    ///
    /// Two and a half seconds, which is the shortest anyone has measured people
    /// reliably reading a four-word message — and long enough that a UI test
    /// polling for it does not race the animation that dismissed the menu.
    private func show(_ message: String) {
        toastGeneration += 1
        let generation = toastGeneration
        withAnimation { toast = message }
        Task {
            try? await Task.sleep(for: .seconds(2.5))
            // Only the message that scheduled this dismissal may take it away.
            guard generation == toastGeneration else { return }
            withAnimation { toast = nil }
        }
    }

    /// A picker came back. Nil means the user cancelled, which is not an error
    /// and must not produce a message.
    private func hand(_ picked: PickedFile?) {
        guard let picked else { return }
        // In the terminal the picker *was* the press, and the file goes. In the
        // conversation there is a composer to put it in front of first — see
        // `staged`, and `SessionChatView.staged(_:)` for what is drawn.
        if chatMode {
            discardStaged()
            staged = picked
        } else {
            host?.send(picked, into: sessionID)
        }
    }

    /// Raise a picker from the composer's paperclip. The same two the terminal's
    /// own menu raises, through the same `@State` and the same sheet.
    private func pick(_ source: ChatAttachSource) {
        // Deferred by a turn of the run loop for the reason Find and Session
        // details are: a presentation asked for in the frame a menu is
        // dismissing in is dropped.
        DispatchQueue.main.async {
            picking = source == .photos ? .photos : .files
        }
    }

    /// What the composer draws above the field, or nil when nothing is staged.
    /// `send` is withheld while a transfer is already running, because
    /// `HostLink.send` refuses a second one and a button that can only be
    /// refused is not a button.
    private var attachment: ChatAttachment? {
        guard let staged else { return nil }
        let busy = host?.upload != nil
        return ChatAttachment(file: staged,
                              send: busy ? nil : {
                                  host?.send(staged, into: sessionID)
                                  // Handed over: `FileUpload` owns the staged
                                  // copy from here and deletes it when the
                                  // transfer ends, whichever way it ends.
                                  self.staged = nil
                              },
                              discard: { discardStaged() })
    }

    /// Drop what was staged, and the copy the picker made with it. Nothing else
    /// will: `FileUpload` deletes the temporary file when a transfer ends, and a
    /// file that was never sent has no transfer to end.
    private func discardStaged() {
        if let staged, staged.temporary { try? FileManager.default.removeItem(at: staged.url) }
        staged = nil
    }

    /**
     * What a transcript view can and cannot show, in three lines behind the `i`.
     *
     * Each line is a fact about the wire rather than about this app. The middle
     * one is the one people need: the tool calls are not withheld by the phone,
     * they are removed by `src/main/chat-transcript.ts` before the frame is
     * built — *"This module throws all of that away and keeps the prose, because
     * the chat view exists precisely to hide it."* The terminal, one press away,
     * has all of it.
     */
    private var chatNote: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Code, patches and file paths are drawn from the text.")
            Text("Tool calls are not in the transcript this machine sends. The terminal has them.")
            Text("A path opens as text. Images cannot be fetched from the machine.")
        }
        .font(.system(size: 13))
        .foregroundStyle(Theme.primary)
        .padding(16)
        .frame(maxWidth: 320, alignment: .leading)
        .accessibilityIdentifier("chat.note.body")
    }
}

/**
 * The progress row for a file on its way to the Mac.
 *
 * Three things are on it and each one earns its place: **where the file is going**,
 * which the Mac names before a byte moves and which is the only chance to notice
 * it is the wrong machine; **how far it has got**, drawn from acknowledgements so
 * it measures the Mac rather than this phone's read speed; and **Cancel**, because
 * an upload that stalls on a train has to be stoppable from here — the alternative
 * is force-quitting the app, which leaves the Mac holding a partial file.
 */
private struct UploadRow: View {
    let upload: FileUpload
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 13))
                .foregroundStyle(tint)

            VStack(alignment: .leading, spacing: 3) {
                Text(upload.name)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(detail)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Theme.faint)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if case .sending = upload.phase {
                    ProgressView(value: upload.fraction)
                        .progressViewStyle(.linear)
                        .tint(tint)
                }
            }

            Spacer(minLength: 8)

            Button(action: onDismiss) {
                Image(systemName: running ? "xmark.circle.fill" : "xmark")
                    .font(.system(size: running ? 18 : 13, weight: .semibold))
                    .foregroundStyle(Theme.faint)
            }
            // Two words rather than one, because the same button stops a transfer
            // and dismisses a finished one, and VoiceOver should not call those
            // the same thing.
            .accessibilityLabel(running ? "Cancel the upload" : "Dismiss")
            .accessibilityIdentifier("upload.dismiss")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .background(.ultraThinMaterial)
        .accessibilityIdentifier("upload.row")
        // The bar moves on its own; VoiceOver should be told rather than left to
        // poll a label that changes eleven times a second.
        .accessibilityElement(children: .combine)
        .accessibilityValue(detail)
    }

    private var running: Bool {
        switch upload.phase {
        case .opening, .sending, .finishing: return true
        case .landed, .failed: return false
        }
    }

    /// The sentence under the name. It is never the same in two states, which is
    /// how a stalled upload is told apart from a slow one.
    private var detail: String {
        switch upload.phase {
        case .opening:
            return "Asking the machine where to put it…"
        case let .sending(path):
            return "\(byteSize(upload.acked)) of \(byteSize(upload.size)) → \(path)"
        case .finishing:
            return "Checking it arrived intact…"
        case let .landed(path):
            return "Landed at \(path)"
        case let .failed(reason):
            return reason
        }
    }

    private var icon: String {
        switch upload.phase {
        case .opening, .sending, .finishing: return "arrow.up.circle"
        case .landed: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.triangle.fill"
        }
    }

    /// The product's own semantic colours rather than SwiftUI's `.green` and
    /// `.orange`, which are a different green and a different orange from the
    /// ones every other status in this app uses.
    private var tint: Color {
        switch upload.phase {
        case .landed: return Theme.positive
        case .failed: return Theme.critical
        default: return Theme.accent
        }
    }
}
