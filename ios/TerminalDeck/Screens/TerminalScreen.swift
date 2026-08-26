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
 * doing, not to type at it. **Tapping the terminal raises it** — and the key bar
 * comes with it.
 *
 * That tap is the only way in now. There was a keyboard button in this toolbar
 * and he took it off both of this screen's readings at once: *"we don't need
 * keyboard button also, even in terminal pages, even on copilot pages, because
 * when we click inside the chat keyboard comes anyway. So we don't need on top
 * of the page inside the pill separately sitting there."* In chat mode that is
 * simply true — the composer is a text field and raises the keyboard the way
 * every text field on the phone does. In the terminal the button was a second
 * control for a gesture the surface underneath it already answers, and `onAppear`
 * below now makes that answer this app's own rather than the library's: the tap
 * is wired to `focus()` there, because SwiftTerm's own tap-to-focus sits behind
 * a `require(toFail:)` and has been measured not to fire under the Simulator.
 * Read that comment before touching either half.
 *
 * ## What happens when the connection drops here
 *
 * The banner appears, `send` starts refusing rather than buffering, and the
 * terminal keeps showing what it already had — which is honest, because that
 * output really did arrive. What it must not do is accept keystrokes into a
 * socket that is gone, and that refusal is in `send` itself: the key bar's keys
 * go through the same path as typing and are refused with it. The keyboard still
 * comes up over a dead session, and that is not a regression from the button
 * being disabled while the socket was down — a tap on the terminal always raised
 * it regardless, so the disabled button was only ever the *second* way in being
 * closed while the first stayed open. Refusing at `send` is the honest place:
 * the keys are drawn, they are pressed, and nothing is invented.
 * When the socket comes back the model re-attaches by itself; Re-attach in the
 * menu is for the case where the user wants to force a fresh replay.
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

    /**
     * How to leave, when there is nothing to leave *to*.
     *
     * Non-nil means this screen is the **root of a tab** rather than a screen
     * pushed onto one — which is what the Copilot tab became when its
     * intermediate page was deleted: *"This page needs to go. It should directly
     * land in terminal or chat mode."* A stack root has no chevron of its own and
     * no pop gesture, so without this the one tab in the app you land in would be
     * the one you could not get out of.
     *
     * It carries the *action* rather than a `Bool`, because where "back" goes is
     * not this screen's to know: `DeckModel.leaveCopilot` returns to whichever
     * tab the copilot was entered from, and somebody who tapped the pill while
     * reading their ports means Localhost by *home*.
     *
     * It decides **whether this screen draws a chevron at all**, and nothing
     * else about the bar. It used to decide which side the mode toggle and the
     * terminal's `…` sat on as well; it does not any more, because those two now
     * sit in one pill on the trailing edge whichever stack this screen is built
     * from — *"this go-back pill should be separate and the other two should be
     * on right side exactly like this page. This terminal homepage."* The
     * `.toolbar` below carries the whole of that.
     */
    var leaveTab: (() -> Void)?

    /// The phone's colour scheme, held so the letterbox around the emulator is
    /// painted in the same ground the emulator is and repaints with it. A stored
    /// property rather than a reach for `.shared` inside `body`, because
    /// `@Observable` only re-runs a body that *read* the object.
    /**
     * Whether this screen is the **copilot's own conversation** rather than a
     * session somebody started.
     *
     * Only `DeckTabs` knows — the same screen is built from two stacks and the
     * copilot's is the one that passes `leaveTab` — and it is stated rather than
     * inferred from `leaveTab != nil`, so a second tab root later cannot quietly
     * inherit a row that was meant for one screen.
     */
    var isCopilot = false

    var themes: TerminalThemeStore = .shared

    @State private var title: String?
    /// How wide the screen this session is drawn on is, measured by the ground
    /// in `body`. Held because the one element on this screen that cannot ask a
    /// layout for its own room is the navigation bar's title, and it is the one
    /// element that has to know. See `titleWidth`.
    @State private var screenWidth: CGFloat = 0
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
    /// Whether the rename box is up, and the name being typed into it. Held here
    /// rather than on the session so the draft survives the machine resending
    /// its list underneath the alert.
    @State private var renaming = false
    @State private var typedName = ""

    /*
     * **How much room the page has is not this screen's business any more.**
     *
     * There was a `pagePane` here, owned by this screen rather than by the pane,
     * for one stated reason: *"the terminal below has to be laid out against the
     * same answer"* — the two were siblings in a `VStack` and *"give the page the
     * screen"* meant not drawing the terminal at all.
     *
     * > *"it should not move chat down to come in front or rerminal it should
     * > just expand over it"*
     *
     * The page floats over the session now, so nothing here is laid out against
     * it, nothing here reads it, and the state went where the other five pieces
     * of the pane's state already live. See `SessionPageView.pane`.
     */


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
            //
            // It reports the screen's width out as well. This is the one view on
            // the screen that is the screen — it ignores the safe area and fills
            // whatever is left — so it is the honest place to read the number the
            // title's cap is derived from. See `titleWidth`.
            Color(TerminalPalette.dynamicBackground(themes.selected))
                .ignoresSafeArea()
                .background(
                    GeometryReader { frame in
                        Color.clear
                            .onAppear { screenWidth = frame.size.width }
                            .onChange(of: frame.size.width) { _, width in
                                screenWidth = width
                            }
                    }
                )

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
            /*
             * **The `i` that used to sit beside the mode toggle is gone, and so
             * is the note behind it.**
             *
             * > *"why do we have this i button, it is completely extra, the
             * > information button, remove this."*
             *
             * It was three lines saying what a transcript can and cannot show,
             * and the middle one was the only one that carried something the
             * screen could not: an agent's tool calls are not withheld by this
             * phone, they are removed by the desktop before the frame is built —
             * `src/main/chat-transcript.ts`, *"This module throws all of that
             * away and keeps the prose, because the chat view exists precisely
             * to hide it."*
             *
             * That fact is now written down and nowhere drawn. It belongs in the
             * code rather than on the screen: it is a fact about the wire, it is
             * true of every session on every machine, it never changes, and a
             * person reads it once and never needs it again — which is the exact
             * shape of the thing he has now twice told this app to stop putting
             * in front of him. `SessionChatView`'s own header carries the whole
             * argument for whoever wonders why a fold does not open.
             *
             * The other two lines are visible in the view itself: code and
             * patches are drawn as code and patches, and a path is a chip that
             * opens the machine's reader. Nothing was lost by deleting a caption
             * that described what was already on screen.
             */
            /*
             * **The browser window this session is holding, over whichever way
             * the session is being read.**
             *
             * > *"Generally, whenever we are talking to terminal, terminal will
             * > directly open it up in there inside the session — I mean it will
             * > show it… and the person can just minimize it from some button and
             * > it will go back."*
             *
             * > *"it should not move chat down to come in front or rerminal it
             * > should just expand over it"*
             *
             * **The session is inside it now.** It was a sibling underneath it —
             * two children of a `VStack`, so every point the page took was a
             * point off the terminal, the transcript reflowed on every open and
             * every fold, and the composer at the bottom of a conversation went
             * off the bottom of the screen when a page arrived. The only way to
             * be *over* something in SwiftUI is to be in a stack with it, so the
             * pane is handed `sessionBody` and puts the page above it. What that
             * costs here is one closure; what it buys is that this screen has
             * nothing left to say about how much room the page has.
             *
             * `frontmost` is the one thing this screen still has to supply and the
             * pane cannot work out: a canvas left alive on a tab nobody is looking
             * at is the two-canvas defect `WatchStage` exists to prevent, and a
             * tab swap fires no lifecycle callback on the tab being left.
             *
             * Over **both** modes. A conversation is where the copilot tab lands,
             * and *"Claude is working on this page"* is exactly as true of a chat
             * as of a terminal — more so, because a conversation is where an agent
             * says it needs something.
             *
             * It draws nothing at all — not a strip, not a point of height — when
             * this session holds no window, which is almost always. Then this is
             * `sessionBody` and nothing else.
             */
            SessionPageView(model: model,
                            hostID: hostID,
                            sessionID: sessionID,
                            frontmost: frontmost) {
                sessionBody
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
            /*
             * **Back on its own at the leading edge; the other two in one pill at
             * the trailing edge. Both stacks.**
             *
             * > *"On this chat mode, switch this button and these three dots — I
             * > ask you to keep these two in the right side, on top right corner,
             * > not in one pill with the go back. So this go-back pill should be
             * > separate and the other two should be on right side exactly like
             * > this page. This terminal homepage."*
             *
             * > *"But also in the terminal page, if we go inside a session, they
             * > are in left side. These two should be three dot and messaging
             * > button should be on right side here too."*
             *
             * Two readings, one arrangement. He said it of the copilot's
             * conversation and then, unprompted, of the same screen reached from
             * the session list — so there is no branch here on which stack built
             * this screen, and there had better never be one again.
             *
             * ## They were on the left, and this is why they came back
             *
             * A round ago the whole cluster sat in the leading group, on *"move
             * three dots and switch on left now"*, and that instruction was
             * itself settling something worse: the copilot's conversation drew
             * its chevron, the mode toggle and the `…` in one pill on the left
             * while the same screen reached from the Sessions tab drew the last
             * two on the right. One screen, two arrangements, decided by which
             * tab somebody came from.
             *
             * That half of it survives — the two stacks still draw the same bar.
             * What has changed is which edge they agree on, and both of his
             * reasons are visible on the screen it replaced: the Terminal home
             * page's `[+ ⋯]` is the corner a thumb has already learned, and a
             * chevron sharing a capsule with two more controls made a leading
             * cluster wide enough to shove the title off centre and truncate it
             * — *"Open Google in brow…"*, photographed. See `titleWidth`.
             *
             * So the styling is `SessionListView`'s rather than this screen's
             * own: one `ToolbarItemGroup`, because a group is what iOS 26 draws
             * as a single piece of glass and two groups is what draws two, and
             * bare glyphs inside it rather than ringed ones.
             *
             * The `…` keeps the rule it was given a round ago rather than being
             * given a new one: it is drawn only in terminal mode, because every
             * item under it acts on the emulator. Moving it right does not make
             * Find, Copy Screen or Paste mean anything on a conversation.
             */
            if let leaveTab {
                /*
                 * A `ToolbarItem` and not a group, which is the whole of *"this
                 * go-back pill should be separate"*: one item is one control and
                 * has nothing to share a capsule with.
                 *
                 * Drawn only on a tab root, because there is nothing above a root
                 * to pop. A pushed session already has the stack's own chevron in
                 * exactly this spot, which is why the leading edge reads the same
                 * on both stacks without this file arranging it.
                 */
                ToolbarItem(placement: .topBarLeading) {
                    Button(action: leaveTab) {
                        Image(systemName: "chevron.backward")
                            .font(.system(size: 17, weight: .semibold))
                    }
                    .accessibilityLabel("Back")
                    .accessibilityIdentifier("copilot.back")
                }
            }
            ToolbarItemGroup(placement: .topBarTrailing) { sessionControls }
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
        /*
         * The whole page is the terminal's, not the app's — the bar over it
         * included.
         *
         * *"My header should be also dark black. Other than the buttons, that top
         * header should be also dark black, everything should be black, not just
         * base colour."* The ground was already the scheme's — the `Color` at the
         * top of this `ZStack` — and the band above it was the system's own bar
         * over `Theme.surface`, which on the default scheme photographed as
         * `#ffffff` sitting on `#e8e8e8` with a hard edge across the screen at 148
         * points.
         *
         * **Here, and not four modifiers up where it was first written.** An
         * appearance stated for a subtree reaches what is already inside it and
         * nothing added afterwards, so above the `.safeAreaInset` it left the row
         * over the terminal resolving `Theme` against the *phone* while the
         * terminal under it took the scheme — photographed as a dark chip row on
         * cream paper. Below the sheets it would follow a detail sheet or a file
         * reader out of the session, and those are the app's own screens.
         *
         * On the screen and not in `DeckTabs` because it belongs to the screen
         * rather than to a stack: the same screen is pushed from Sessions and from
         * Copilot, and stating it once is what stops those two bars diverging. See
         * `TerminalChrome` for which colour comes from where, and for the one
         * surface it cannot reach.
         */
        .terminalChrome(themes.selected)
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
        // No `open` handed in: this sheet was raised from inside the session, so
        // a button leading to the screen underneath it would be furniture.
        .sheet(isPresented: $showingDetails) {
            SessionDetailView(model: model,
                              hostID: hostID,
                              sessionID: sessionID,
                              open: nil,
                              dismiss: { showingDetails = false })
        }
        /*
         * One line, one answer — the same alert the Sessions list draws, and for
         * the same reasons. An empty field is allowed through: it is how the
         * machine is told to go back to the folder's own name.
         */
        .alert("Rename \(session?.title ?? "this session")", isPresented: $renaming) {
            TextField("Name", text: $typedName)
                .textInputAutocapitalization(.words)
                .accessibilityIdentifier("terminal.rename.field")
            Button("Save") { host?.renameSession(sessionID, to: typedName) }
                .accessibilityIdentifier("terminal.rename.save")
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Every device signed in here sees the new name. "
                 + "Leave it empty to go back to the folder's own name.")
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
            /*
             * A tap into the terminal means *I want to type here*, and with the
             * toolbar's keyboard button deleted it is the only thing that says
             * so. Two consequences, in the order they happen.
             *
             * **It raises the keyboard, from here rather than from the
             * library.** SwiftTerm's own `singleTap` already does this — its
             * last branch is `becomeFirstResponder()` when the view has not got
             * focus — but that recogniser is behind `require(toFail:)` on the
             * double tap, and `MultiHostUITests` has a measured note saying the
             * tap did not focus the view under the Simulator at all: *"the
             * characters were never typed, nothing was sent, and the failure
             * arrived twenty seconds later as 'the machine on the other end did
             * not echo what was typed'."* That was survivable while a button
             * stood next to it and it is not now, so the app states it itself,
             * through the recogniser `TerminalGestures` installs with
             * `cancelsTouchesInView` false and no failure requirement.
             *
             * **Only when the view has not already got focus**, which is
             * SwiftTerm's own rule copied deliberately. A program that has
             * turned mouse reporting on is being *clicked* rather than typed at,
             * and a keyboard that came up over the bottom half of vim on every
             * tap would be this app breaking a session it is meant to be
             * carrying. The first tap raises it; the rest are the program's.
             *
             * **It ends the search.** A tap destroys the selection SwiftTerm is
             * using as the match highlight, so a find bar left standing would be
             * counting matches that are no longer on screen.
             */
            bridge.onTapped = {
                if !bridge.isFocused { _ = bridge.focus() }
                closeFind()
            }
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
            askWhatTheMachinesBrowserHasOpen()
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
            // The same rule for the other holder of that flag. A selection made
            // with a finger holds the highlight against output for as long as it
            // is on screen — and this screen is not on screen. See
            // `TerminalBridge.holdSelection`.
            bridge.dropSelection()
            /*
             * **Left, not detached.** *"If I go back, if I come back, it should
             * not do this refresh thing, it should stay."*
             *
             * A detach here is what made coming back a full wipe and replay: the
             * machine answers the next `attach` with `attached`, and that frame
             * is what resets the emulator and re-sends the whole scrollback.
             * `HostLink.leaveSession` defers the detach by half a minute and
             * `attach` cancels it, so a trip to the session list and back costs
             * nothing on the wire and nothing on the screen. Somebody who really
             * has gone is let go exactly as before.
             */
            host?.leaveSession(sessionID)
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

    // MARK: - The session itself

    /**
     * The session, read whichever way it is being read.
     *
     * Lifted out of `body` when the page pane went in over it, because it has to
     * be one nameable thing to be handed to something else — it is
     * `SessionPageView`'s child now, drawn underneath the page rather than beside
     * it.
     *
     * **Its box does not change when the page opens.** That is the whole of *"it
     * should not move chat down… it should just expand over it"*: the only thing
     * ever taken off this is the strip, and the strip is the same height whether
     * the page is open, folded, or carrying a question. So the transcript does
     * not reflow, the emulator sends no `resize`, and a conversation's composer
     * stays where a thumb left it.
     *
     * Nothing inside has changed. The two readings are the same session and the
     * same socket, so switching costs nothing on the far machine and a message
     * typed in one appears in the other.
     */
    private var sessionBody: some View {
        TerminalHostView(bridge: bridge)
            .ignoresSafeArea(.container, edges: .bottom)
    }

    /// The two controls this screen owns — the mode toggle and then the
    /// terminal's `…`, which is the order `SessionListView` puts `+` and `…` in
    /// and the order he read them out in. Kept out of the toolbar body above so
    /// that block is about placement and this one is about contents.
    @ViewBuilder
    private var sessionControls: some View {
                /*
                 * **The `…` is the terminal's menu, so it is drawn where the
                 * terminal is.**
                 *
                 * Every item under it acts on the emulator: Find searches its
                 * buffer, Copy Screen copies its grid, Paste types into it, the
                 * text-size steps change its font, Share writes out its
                 * scrollback. In chat mode the emulator is not on screen — it is
                 * still alive, still attached, still scrolling behind the
                 * conversation — so each of those either acts invisibly or, in
                 * Find's case, opens a bar counting matches nobody can see. A
                 * control that cannot be seen to act is the same defect as one
                 * that cannot act.
                 *
                 * It is also what he asked for, on the screen he was looking at
                 * when he asked. The copilot tab lands in a conversation, and of
                 * that bar: *"Keep only three dot settings and chat switching
                 * button in the copilot."* With this gated on the mode, a landed
                 * copilot chat carries the chevron on its own at the left and the
                 * toggle alone in the pill at the right — and the `…` joins it in
                 * that pill the moment somebody switches into the terminal.
                 *
                 * Gated on the **mode** rather than on `model.tab == .copilot`,
                 * which was the other candidate. Keying it to the tab would take
                 * Paste, Re-attach and the text size off a copilot terminal that
                 * a person had deliberately switched *into* — a screen with a
                 * real emulator on it and nothing to drive it with — and would
                 * leave the same dead menu on the Sessions tab's chat. The mode
                 * is the fact that decides whether these items have anything
                 * visible to act on.
                 */
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
                    /*
                     * **Not on the copilot either.**
                     *
                     * > *"when we click on three dots and then Session details when
                     * > we are in copilot, let's not give that there — anything that
                     * > is more about a generic session."*
                     *
                     * That sheet answers *which session is this*: its folder, its
                     * agent, when it started, which account it is on. Every one of
                     * those is a fact about a session somebody chose to start, and
                     * the copilot is not one — it is the copilot, in its own folder,
                     * on the machine's own account, for as long as the machine is
                     * up. What is worth knowing about it lives on its own settings
                     * page, which is a different page for a different thing.
                     */
                    if !isCopilot {
                        Button {
                            DispatchQueue.main.async { showingDetails = true }
                        } label: {
                            Label("Session details", systemImage: "info.circle")
                        }
                        .accessibilityIdentifier("terminal.details")
                    }

                    /*
                     * Model, effort, fast mode, permission — the desktop's
                     * control cluster, which has no room to be inline chips on a
                     * phone. Shown only when an agent is drawing this session
                     * (`clusterShown`): a model menu over a plain shell is the
                     * defect the desktop's own cluster withdraws itself for, and
                     * over an older desktop that never advertised `controls` the
                     * reading never arrives so this stays hidden.
                     */
                    /*
                     * **A name of his own on this session.**
                     *
                     * > *"I said before, for being able to rename sessions."*
                     *
                     * Here as well as on the list, because this is the screen a
                     * person is standing on when they decide a session needs a
                     * name — they have just read what is in it. The same verb and
                     * the same alert either way; `SessionListView` carries the
                     * reasoning for the shape.
                     */
                    /*
                     * **Not on the copilot.**
                     *
                     * > *"right now when we are inside the session of copilot we
                     * > can still do the rename session kind of things. Let's give
                     * > copilot a little bit of its own respect, its own things —
                     * > don't give rename session inside the copilot, because it
                     * > will always be the name we choose for copilot to have,
                     * > just like we do in the Mac application."*
                     *
                     * The copilot is not one of the sessions; it is *the copilot*,
                     * and its name is the one thing about it that is the same on
                     * every machine and every screen. A rename here would let one
                     * phone give it a private name that nothing else calls it.
                     */
                    if host?.canRenameSessions == true, !isCopilot {
                        Button {
                            // Deferred for the reason every other presentation on
                            // this menu is: raising a sheet in the frame a menu is
                            // dismissing in is a press that does nothing.
                            DispatchQueue.main.async {
                                typedName = session?.title ?? ""
                                renaming = true
                            }
                        } label: {
                            Label("Rename session", systemImage: "pencil")
                        }
                        .accessibilityIdentifier("terminal.rename")
                    }

                    if showsControlsButton {
                        Button {
                            DispatchQueue.main.async { showingControls = true }
                        } label: {
                            Label("Model & effort", systemImage: "slider.horizontal.3")
                        }
                        .accessibilityIdentifier("terminal.controls")
                    }

                    /*
                     * **Copy the screen, Paste and Share all the output are gone.**
                     *
                     * > *"these three also needs to go from drop down from all
                     * > sessions types."*
                     *
                     * All three had already been narrowed once — Copy Selection
                     * was deleted because reaching this menu destroys the
                     * selection on the way, and the two survivors were renamed so
                     * they differed by the one word that decides their scope. He
                     * looked at the result and took the whole group out, which is
                     * the honest end of that line: none of the three is something
                     * a person reaches a menu for on a phone.
                     *
                     * **Nothing is lost from the app.** Copying a selection is
                     * the system callout a long press puts over the terminal, and
                     * the `copy` key in the key grid — both inside the terminal,
                     * where the selection lives, and both exercised in
                     * `ClipboardAndTransferUITests`. Pasting is the key bar's own
                     * paste and the system callout. The scrollback as a file is
                     * `ShareOutput`, which is still built and still reachable
                     * from the session's details.
                     */

                    /*
                     * **There is no Bigger text / Smaller text here any more.**
                     *
                     * They were two ordinary items with the size in their
                     * labels — *"Bigger text — 12 pt"* — and he read them out of
                     * this menu, on this screen, and said where they go:
                     *
                     * > *"this bigger and smaller should be going to inside the
                     * > settings page for the all of the terminals with one
                     * > setting we can just change this for overall appearance
                     * > page should be there in the settings and from there we
                     * > can change colors text size and everything for all of
                     * > them."*
                     *
                     * The size was **already** one setting for the whole phone
                     * rather than one per session — `TextSize` is a single
                     * defaults key and always was. That is not what he was
                     * reading. A control that lives inside one session's menu
                     * says *this session*, whatever the storage does, and there
                     * is no way to say otherwise inside a menu row. So the rows
                     * are gone rather than relabelled, and Settings →
                     * Appearance is the one place the size is set, next to the
                     * colours, for every terminal on the phone.
                     *
                     * **Nothing here got slower.** The gesture is still on this
                     * screen: pinching the terminal changes the same setting,
                     * which is the fast path people already try, and the toast
                     * that names the new size is still wired to it below. What
                     * went is a menu of controls that had to be re-opened
                     * between every press.
                     */

                    /*
                     * **Sending is back on this menu, and that is his answer to
                     * having tried it the other way.**
                     *
                     * > *"can we give media and file button in the bar that comes
                     * > with keyboard for special buttons instead of dropdown?"* —
                     * > and then, having used it: *"I think keep photo and file
                     * > button back in the drop down, it was more easier to
                     * > understand and use."*
                     *
                     * They kept their words on the keys panel, where a cap says
                     * `photo` in eleven points and nothing says what it sends or
                     * where it goes. Here each row is a sentence with a glyph, in
                     * the one place on this screen a person already looks for the
                     * things a session can do. The keys panel keeps the keys.
                     *
                     * Absent rather than disabled when the machine cannot receive
                     * one: a control that can only produce a refusal is not a
                     * control. See `DeckModel.canSendFiles`.
                     */
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

                    /*
                     * > *"the reattach button is not clearly clear that what
                     * > does it means maybe we can just rename it to restart or
                     * > something or restart session."*
                     *
                     * *Re-attach* names the wire — this phone re-subscribing to a
                     * session's output — which is a thing nobody outside this
                     * code has a word for. What a person means by pressing it is
                     * *give me this session again, working*.
                     */
                    /*
                     * **There is no Restart row, and that is his decision.**
                     *
                     * It arrived as a rename of *Re-attach* — *"maybe we can just
                     * rename it to restart or something"* — and the verb under it
                     * stayed `reattach`, which only drops this phone's
                     * subscription to the output and takes it again. On a healthy
                     * session nothing visibly happens, so he read it as a dead
                     * button: *"it is showing restart and it is not doing
                     * anything."*
                     *
                     * What he wanted instead was a flow: save the conversation,
                     * wait for the save to finish, then start a fresh empty
                     * session in the same folder — and he gated it himself:
                     *
                     * > *"if the save-session command is native for Claude then we
                     * > will use it; if it is just me using this kind of command
                     * > then we will not use it, because it will be useless for
                     * > others."*
                     *
                     * It is not native. None of Claude Code, Codex or Gemini has a
                     * save-this-conversation command; his `session-save` is a skill
                     * in his own folder, and sending it to a stranger's agent would
                     * type an unknown command into their terminal. Told that, he
                     * said *"lets remove restart completely in that case"* — so the
                     * row is gone rather than shipping the half of it that works.
                     *
                     * Nothing was protecting anything: all three agents write their
                     * own transcript as they go, and a session can be started fresh
                     * from the list's `+` in the same folder whenever he wants one.
                     *
                     * ## Except on the copilot, where it is the only way
                     *
                     * > *"keep restart for copilot only."*
                     *
                     * A session has a list with a `+` on it and a Delete beside
                     * every row; the copilot has neither. Its conversation *is* the
                     * tab, there is no row for it — he had it taken off the list
                     * this same evening — and nothing anywhere else starts a new
                     * one. So this is where a fresh copilot comes from, and the
                     * tab picks the new session up on its own: `tabSession` finds
                     * the copilot by its **folder**, not by an id, so ending one
                     * and starting another in the same place is invisible to the
                     * stack this screen is standing in.
                     */
                    if isCopilot {
                        Button {
                            restartCopilot()
                        } label: {
                            Label("Restart session", systemImage: "arrow.clockwise")
                        }
                        .disabled(!connection.isLive || host?.canCreateSessions != true)
                        .accessibilityIdentifier("terminal.restart")
                    }

                    /*
                     * **Last, and that is his measurement rather than a taste.**
                     *
                     * > *"attach a browser window should be last thing in the
                     * > drop down because they can be too many so they can just
                     * > keep scrolling but they will not have to scroll all the
                     * > way for the all the browser windows to reach the basic
                     * > options."*
                     *
                     * It is the one section here whose length is not this app's
                     * to decide — it is however many windows the machine's
                     * browser has open — so anything under it is however far
                     * down that list happens to reach today. Everything above it
                     * is a fixed number of rows.
                     */
                    attachSection
                } label: {
                    // `ellipsis` and not `ellipsis.circle`, which is what it
                    // wore while it stood in the leading group. *"Exactly
                    // like this page. This terminal homepage"* — and there
                    // the capsule is the affordance and the glyphs inside it
                    // are bare, so a ringed `…` reads as a badge stuck to the
                    // right-hand end of the pill rather than as the second of
                    // two controls. `SessionListView` carries the same note
                    // over `sessions.more`.
                    Image(systemName: "ellipsis")
                }
                .accessibilityLabel("Session actions")
                .accessibilityIdentifier("terminal.actions")
    }

    /**
     * **Attach a browser window to this session, from inside the session.**
     *
     * > *"here we also don't have anything, like inside here, in the three dots,
     * > we should have the options to click on something, and then all the folders
     * > will come up, maybe here also. So we can connect the browser, whichever
     * > browser we want to connect into the session."*
     *
     * The verb is `HostLink.bindMachineWindow`, which is the one the Browser
     * tab's window settings press and the one the session row's `…` presses.
     * Nothing is invented here; what was missing was a place to press it from
     * while you are sitting in the session watching an agent that needs a page.
     *
     * ## It is a list of windows now, and nothing else
     *
     * > *"we have one section saying attach a browser window where we see all the
     * > browser windows with their name then we see open window for this session
     * > open one signed into nothing which is so much of confusing i don't
     * > understand what is what and what are the differences then we see open
     * > again on this specific desktop the page here stays then we see another
     * > name of the window so why they are like so much of confusing saying words
     * > why don't we just simply have the name of the search of browsing windows
     * > we can just simply click on one of them and that's it."*
     *
     * Everything he listed there was a row that was a **sentence** sitting
     * between rows that were **names**. So the section is one flat list of names
     * — the machine's windows, then the pages this phone is showing, each under
     * its own name — with a checkmark on the one this session already holds, and
     * one row after a divider that makes a new window.
     *
     * Nothing was dropped except the words. The private window moved out — not
     * for its length, *Private* is the shortest row in the app, but because
     * *which profile* is a decision made where a window is **made**, and the
     * Browser tab's `+` has always offered it there; the *"the page here stays"*
     * header moved onto the rows' hints and the sentence the toast puts up after
     * the press.
     * `SessionWindowPicker` carries the whole argument and both menus read it, so
     * the two cannot drift into saying different things about the same window.
     *
     * ## It shipped drawing nothing, which is the same complaint again
     *
     * The first version of this section was `if !windows.isEmpty`. On a machine
     * with a browser window already open it was exactly right, and on every
     * other machine it was the screen he filmed: the `…`, opened, with nothing
     * under it. That is the ordinary state — a laptop with the browser closed —
     * and it is the state he was in when he recorded the sentence above. The
     * only way out of it was the walk this menu exists to delete: leave the
     * session, go to the Browser tab, open a window, come back.
     *
     * So the section is drawn whenever the machine will be **driven**
     * (`SessionWindowPicker.showsAttach`), and it always ends with the row that
     * opens a new one. An empty machine now answers the press instead of being a
     * dead end.
     *
     * ## And three rules that did not change
     *
     *  - **Absent, not disabled.** A machine that will not be driven refuses
     *    every one of these frames at the source, so nothing is drawn at all.
     *  - **The one this session holds wears a checkmark**, rather than being left
     *    out. A picker that hides the current answer is one somebody presses again
     *    to find out.
     *  - **A window another session holds says so**, because attaching **moves**
     *    it and moves it silently. `SessionWindowPicker.row` is that half of the
     *    name, and it is the same one the session row's menu says.
     *
     * ## And this is the way back from Disconnect
     *
     * > *"One [close button] which will just remove this from this page but
     * > window will not die. Window will stay there in the window side here… As
     * > soon as we talk about it and want to bring it back we can bring it from
     * > here back to the page from the three dots."*
     *
     * The strip's Disconnect is the first half and this section is the second,
     * and it already worked in the sense that the window really does come back
     * into this list — it lists every window the machine has and asks nothing
     * about who owns them. What it did not do is make the window he means easy
     * to see: it came back as one name among however many, in the machine's own
     * order, wearing the same frame as the rest. So the window this session let
     * go of is **first**, with a *come back* arrow instead of a frame, and
     * `HostLink.releasedWindows` is the one fact that makes that possible.
     * `SessionWindowPicker.attachable` owns the rule and the session row's menu
     * reads the same one.
     *
     * A bind is also what pops `SessionPageView` open over the terminal, because
     * the answer to a bind is the window list and that pane opens the moment it
     * finds a window that is this session's. That is the point of pressing this,
     * not a side effect to suppress.
     */
    @ViewBuilder
    private var attachSection: some View {
        if SessionWindowPicker.showsAttach(canDrive: canDriveBrowser) {
            // Read once and handed to the rows, because the row text is
            // decided **against the list**: two windows with the same name
            // are told apart by their place in it. See `WindowNames`.
            let windows = attachableWindows
            Section("Attach a browser window") {
                ForEach(windows) { window in
                    Button {
                        host?.bindMachineWindow(window.id, to: sessionID)
                    } label: {
                        Label(SessionWindowPicker.row(window, among: windows, session: sessionID),
                              systemImage: icon(for: window))
                    }
                    // Nothing on the hint for an ordinary window — its name is
                    // the whole of it. The one this session let go of gets the
                    // one sentence, where it is read on request rather than
                    // drawn over a list of names.
                    .accessibilityHint(returning(window) ? SessionWindowPicker.justLeftMeaning : "")
                }

                // In the same flat list and under its own name — no header over
                // it, because a header over two of eight rows is the thing he was
                // reading out. What it means is on the hint and in the toast.
                ForEach(phonePages) { tab in
                    Button {
                        openOnMachine(tab)
                    } label: {
                        Label(SessionWindowPicker.phoneRow(tab), systemImage: "iphone")
                    }
                    .accessibilityHint(SessionWindowPicker.phoneMeaning(machine: machineName))
                }

                // No rule above it. *"Don't keep a separator between already
                // open window and open new window button"* — the section already
                // has a name over it saying these are browser windows, and a line
                // inside it splits one list of windows into two lists of windows.
                newWindowRow
            }
        }
    }

    /// The row that makes a window rather than borrowing one — one row, at the
    /// end of the same list, wearing the same glyph as every row above it. Two
    /// words on it: everything it means is on the hint and in the sentence the
    /// phone puts up after the press.
    private var newWindowRow: some View {
        Button {
            host?.openMachineWindow(isolated: false, session: sessionID)
            show(SessionWindowPicker.opening(machine: machineName))
        } label: {
            /*
             * > *"it should not give it this big sentence, and it should have the
             * > same icon like other ones like above. Make the same icon also for
             * > this and just say New window — because it is already explaining up
             * > there too, like these are browser windows, so we have a title for
             * > this section."*
             *
             * *New browser window* beside `globe.badge.chevron.backward` wrapped
             * onto two lines and was the only row in the section with a compound
             * glyph, so the row that makes a window looked like a different kind
             * of thing from the windows above it. The word *browser* is already on
             * the section header; the glyph is `icon(for:)`'s ordinary one. What
             * is left is the verb.
             */
            /*
             * > *"before the New window it is showing a window icon — instead it
             * > should show the plus icon so they can understand it properly. We
             * > have it actually in some sessions… the icon of the session page
             * > should be for the sessions also."*
             *
             * `SessionListView`'s copy of this row already wore the plus and this
             * one did not, so the same act had two glyphs depending on which
             * screen it was pressed from. It is the window shape the rows above it
             * wear, with a plus on it — the same object, marked as the one that
             * does not exist yet.
             */
            Label(SessionWindowPicker.newWindow, systemImage: "macwindow.badge.plus")
        }
        .accessibilityHint(SessionWindowPicker.newWindowMeaning(machine: machineName))
    }

    /**
     * End the copilot's conversation and start a fresh one in the same folder.
     *
     * No save step, and that is his call rather than an omission — see the note
     * over the row. The gap between the two is the machine's round trip for the
     * close: asked for together, some hosts answer the create first and the tab
     * resolves onto a session that is about to be ended.
     *
     * `cwd` and not the setup book's folder, so this starts the new one exactly
     * where the old one was actually running. If the machine has never said, it
     * says so instead of guessing at home.
     */
    private func restartCopilot() {
        guard let host else { return }
        guard let folder = session?.cwd, !folder.isEmpty else {
            show("This machine has not said which folder the copilot is in.")
            return
        }
        show("Starting a fresh conversation…")
        host.closeSession(sessionID)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            host.createSession(in: folder)
        }
    }

    /// Open a page this phone is holding on the machine, and hand that window to
    /// this session — one ask, and a sentence saying which page did *not* move.
    private func openOnMachine(_ tab: BrowserTab) {
        host?.openMachineWindow(url: SessionWindowPicker.address(tab),
                                isolated: false,
                                session: sessionID)
        show(SessionWindowPicker.openingPhonePage(tab, machine: machineName))
    }

    /// The machine's open windows, or nothing at all where nothing may be
    /// offered. `SessionWindowPicker` owns the rule so this screen and the
    /// session row cannot come to disagree about it — including the order, now
    /// that one of them can be lifted to the top. See `justLeftWindow`.
    private var attachableWindows: [MachineWindow] {
        SessionWindowPicker.attachable(host?.machineBrowser?.windows,
                                       canDrive: canDriveBrowser,
                                       justLeft: justLeftWindow)
    }

    /// The window this session was holding until Disconnect was pressed on the
    /// strip, if the machine still has it. The way back from *"window will stay
    /// there in the window side"* to *"we can bring it back… from the three
    /// dots"*; `HostLink.releasedWindows` carries the whole argument.
    private var justLeftWindow: String? { host?.releasedWindow(for: sessionID) }

    /// Whether this row is that window.
    private func returning(_ window: MachineWindow) -> Bool {
        SessionWindowPicker.justLeft(window, justLeft: justLeftWindow, session: sessionID)
    }

    /// Three states, three glyphs, and no words: the one this session holds
    /// wears a checkmark, the one it just let go wears a *come back* arrow, and
    /// every other window wears a window frame.
    private func icon(for window: MachineWindow) -> String {
        if SessionWindowPicker.holds(window, session: sessionID) { return "checkmark" }
        return returning(window) ? "arrow.uturn.backward" : "macwindow"
    }

    /**
     * The pages this phone has open on **this session's** machine.
     *
     * `browserTabs.tabs(on: model)` answers for whichever machine is current,
     * and this screen is opened for a named one — see `hostID`, which exists
     * because session ids are not unique across machines. The picker filters by
     * host on the way through, so the one frame where those two disagree offers
     * nothing rather than offering another machine's `localhost:3000`.
     */
    private var phonePages: [BrowserTab] {
        SessionWindowPicker.phonePages(model.browserTabs.tabs(on: model),
                                       on: hostID,
                                       canDrive: canDriveBrowser)
    }

    /// Whether this session's machine will let this phone drive its browser.
    /// Read once and shared, because four things below key off it and a screen
    /// where three of them agreed and one did not is a menu that half exists.
    private var canDriveBrowser: Bool { host?.canDriveBrowser == true }

    /// What this session's machine is called in a sentence. The host's own
    /// label, not the current machine's — this screen can be pushed for a
    /// machine that is no longer the one on the switcher.
    private var machineName: String { host?.label ?? model.theMachine }

    /**
     * Ask what the machine's browser has open, once, on the way in.
     *
     * `browser.window.rows` is **answer-only**: it is built for a request and
     * there is no push for it anywhere on this wire, so a menu that did not ask
     * would be empty the first time it was opened, every time.
     *
     * Guarded on nothing having landed yet, because the pane above this screen
     * asks too — `SessionPageView` reads it on appear and again on every
     * `browser.surfaces.rows` push, which is the frame that says the machine's
     * browser moved. That covers a window opened while somebody sits here. This
     * is the first answer, and the guard is what keeps the two from sending the
     * same small question twice on every arrival.
     *
     * It is written here rather than left to the pane on purpose: a menu whose
     * contents depend on a side effect in a **different view** is a menu that
     * empties itself the day somebody edits that view.
     */
    private func askWhatTheMachinesBrowserHasOpen() {
        guard host?.machineBrowser == nil else { return }
        host?.readMachineWindows()
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
        /*
         * **A tab's root is frontmost when nothing is pushed over it.**
         *
         * The rule below reads the top of the selected tab's *stack*, which is
         * exactly right for a screen that was pushed and silently wrong for one
         * that is the tab's own content: `copilotRoute` is empty then, so the top
         * is `nil`, so this answered false for the screen a person was looking
         * at. `reclaimBar()` guards on it, so `askChat` was never sent and the
         * Copilot tab opened on a **conversation with no messages in it** — the
         * bar following the right session, `chatting` on, a live socket, no
         * error, and `transcript` never answered because no frame ever left.
         *
         * Measured rather than reasoned: the same session was photographed on
         * both builds a minute apart with `bar=… msgs=… tr=… err=…` drawn on
         * screen. Pushed: `msgs=2 tr=y`. As the tab's root: `msgs=0 tr=?`.
         * Nothing else differed.
         */
        if leaveTab != nil { return model.tab == .copilot && model.copilotRoute.isEmpty }
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

    /*
     * **There is no `step` here any more.**
     *
     * It applied one press of the menu's Bigger/Smaller text and saved the
     * result, and it went with them — see the note in the `…` menu above. The
     * pinch does not need it: `TerminalGestures` drives `setTextSize` directly
     * while the fingers are moving and calls `TextSize.save` once when they
     * lift, which is also the one post that tells every other terminal on the
     * phone. See `TextSize`.
     */

    /**
     * The session's name, and what it is doing under it.
     *
     * > *"Maybe the name of the session can come a little bit down so it can be
     * > readable… it will be folded with three dots, but it should stay
     * > centralized. It should not move according to the buttons top of it."*
     *
     * Three things in one sentence and each one is a line below. It is **folded
     * with three dots** rather than shrunk or wrapped, because a name that has
     * run out of room is still a name and the front of it is the part that says
     * which session this is. It **stays centralized** — the cap is what does
     * that and `titleWidth` is the argument for it. And it gets a little more
     * room between the two lines than it had, which is the readable part: at two
     * points of spacing the status sat against the underside of the name and the
     * pair read as one squashed block rather than as a title with a state under
     * it. Four, plus a couple of points top and bottom, is as much as an inline
     * bar has to give — it is forty-four points tall and it clips rather than
     * grows.
     */
    private var header: some View {
        VStack(spacing: 4) {
            Text(title ?? session?.title ?? "Session")
                .font(.system(size: 15, weight: .semibold))
                /*
                 * The scheme's ink, not the app's.
                 *
                 * `Theme.primary` is measured against the app's own paper, and
                 * this bar is not on the app's paper any more. On Pure Black with
                 * the phone in light it is `#1a1a1a` on `#000000` — a title that
                 * is there and cannot be read. The scheme's `foreground` is what
                 * the emulator draws ordinary output in three points below, on
                 * exactly this colour, so it is the one value that is guaranteed
                 * to be the pairing whoever wrote the scheme intended. See
                 * `TerminalChrome`.
                 */
                .foregroundStyle(TerminalChrome.ink(themes.selected))
                .lineLimit(1)
                .truncationMode(.tail)
            HStack(spacing: 5) {
                if let session {
                    StatusDot(status: session.status)
                    // Mono, because a status is a word the desktop chose from a
                    // fixed vocabulary rather than a sentence this app wrote.
                    // The dot keeps `Theme.statusColor`: working, waiting and
                    // exited are meanings rather than decoration, and a scheme
                    // that repainted them would be a scheme that changed what
                    // the screen says.
                    Text(session.status)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(TerminalChrome.dimInk(themes.selected))
                } else {
                    Text(connection.label)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(TerminalChrome.dimInk(themes.selected))
                }
            }
        }
        .frame(maxWidth: titleWidth)
        .padding(.vertical, 2)
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

    /**
     * How wide the title is allowed to be — which is what keeps it centred.
     *
     * > *"It should not move according to the buttons top of it."*
     *
     * A navigation bar centres its title on the **bar**, and then slides it out
     * of the way of whichever button group it would otherwise run into. So an
     * uncapped title grows until it meets the trailing pill and is pushed left
     * by it, and the drift he photographed is exactly that much: a name reading
     * *"Open Google in brow…"* sitting nearer the chevron than the middle of the
     * screen, moved there by two controls that have nothing to do with it.
     *
     * Capping it at twice the distance from the middle of the screen to the
     * inside edge of that pill is what makes the two facts agree. At that width
     * the title clears **both** groups, so the bar has no reason to move it and
     * it stays where it was centred — and it stays there when the pill loses a
     * control, which is the other half of *"it should not move according to the
     * buttons"*: the toggle comes and goes with the machine's answer about
     * transcripts, and a title that re-centred each time would twitch.
     *
     * It folds sooner than it strictly has to on a wide phone. That is the trade
     * he named rather than a cost this works around: *"it will be folded with
     * three dots, but it should stay centralized."*
     *
     * `pill` is the trailing group's own width from the edge of the screen —
     * sixteen points of bar margin, two controls at the forty-four point touch
     * target, and the capsule's padding around them. The floor covers the frame
     * before the first measurement lands, when `screenWidth` is still zero.
     */
    private var titleWidth: CGFloat {
        let pill: CGFloat = 116
        return max(132, screenWidth - pill * 2)
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
        // The picker *was* the press, so the file goes.
        host?.send(picked, into: sessionID)
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
