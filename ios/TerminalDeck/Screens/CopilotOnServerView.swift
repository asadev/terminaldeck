/**
 * The Copilot tab, on a machine that has no copilot — and is not going to get
 * one.
 *
 * > *"copilot should be always there when we are with server — copilot should
 * > automatically come there. When we are with desktop then only it is
 * > optional."*
 *
 * The pill shows unconditionally for a headless host, which is the half of that
 * sentence `DeckModel.showsCopilotTab` owns. This file is the other half: **what
 * is behind it**.
 *
 * ## This screen is the fallback, not the destination
 *
 * > *"copilot page should be always landing in a copilot session according to
 * > the settings of the copilot — either in an existing session if there is any,
 * > or it should start a new. But it should be always a chat to land with,
 * > terminal and chat mode too."*
 *
 * So the Copilot tab **lands somebody in a conversation** — `land()` below
 * pushes it onto `copilotRoute`, and `TerminalScreen` brings it up as the chat
 * because it is on this stack. What is written here is everything that is left
 * when that cannot happen. It is a screen people should usually not see, and it
 * still has to be worth seeing.
 *
 * ## It never asks. It starts, and then it writes down where.
 *
 * The second half of that sentence — *"or it should start a new"* — was
 * deliberately not implemented for a round, because a tab is reached by accident
 * and a session on a server spends real money. The round after that put the
 * start behind a setup somebody had to complete first, and drew a two-row chooser
 * until they had. He looked at that and said the same thing a third time:
 *
 * > *"the copilot page will directly land into some session — not to a selection
 * > and something on the page. It is still not that way… Because it should
 * > directly start a session on whatever the selected folder for it is. When we
 * > go to copilot it should just start the session; if there is already an
 * > existing session it should start from there where we left, and if not then
 * > it should create itself and start from the beginning. I told the exact same
 * > also before."*
 *
 * **There is no chooser.** The rule is three lines and none of them is a
 * question:
 *
 *  1. A session in the copilot's folder is running → land in it.
 *  2. None is running → start one in that folder and land in it.
 *  3. No folder has ever been chosen → start one in **whatever the machine
 *     itself would use** — a plain `create` with no folder — and record the
 *     `cwd` it comes back with as the copilot's folder. From then on 1 and 2
 *     apply unchanged.
 *
 * So the folder is still a real, per-machine, changeable setting; it lives on
 * `CopilotControlView` with a picker beside it. What changed is that it is
 * **discovered by first use rather than demanded up front**, and that is what
 * answers the objection the gate existed for. The danger was never the spend on
 * its own — it was a folder guessed and then silently kept, so that a machine
 * came to have a copilot somewhere nobody had chosen and nobody could see. The
 * first thing the tab does after starting is write down what it actually used.
 *
 * `CopilotSetupBook` holds that record — on the phone, per machine, because
 * `SERVER_SETTINGS` is a two-key allowlist and the desktop's own `copilot.home`
 * is deliberately unwritable over any wire.
 *
 * The safety properties that were argued for the earlier rounds all survive,
 * because none of them was the gate: **one start per visit** (`attemptedStart`),
 * **a failed start says why and does not retry itself**
 * (`CopilotOnServer.startNeverLanded`), **nothing sent over a dead socket**, and
 * **the honest empty state** for a machine that cannot start sessions at all.
 *
 * ## Three rounds got it here, and the middle ones are worth keeping
 *
 * It began as two rows that changed tab. He looked at that and said:
 *
 * > *"the copilot page has two options — to redirect to the session page or
 * > menu — but it doesn't make any sense. It should be just having an option to
 * > start the copilot, or chat to the copilot, or start the session or something
 * > like that, instead of just redirecting to the other pages. And copilot
 * > should have a consistent connection and all of this stuff."*
 *
 * The fault is worth naming precisely rather than merely fixed: a row reading
 * *"Sessions — start one and run your agent in it"* on a screen that then only
 * **selects the Sessions tab** is a promise kept by somebody else. It is the app
 * pointing at itself. Nothing below points anywhere; every row does its own
 * thing and ends in the result.
 *
 * ## The acts, and why each one is an act
 *
 *  - **Start a session.** `HostLink.createSession(in:)` — the same call the
 *    plus in the session list's toolbar makes. It sets `openWhenCreated`, so the
 *    machine's `created` frame runs `DeckModel.open(session:on:)`, and because
 *    this tab is selected that pushes the terminal onto `copilotRoute` rather
 *    than the session list's stack. So the tap ends in the new session with the
 *    agent's first prompt on screen and **Back** returning here. That property
 *    is `DeckModel.open(session:)`'s, written down there and relied on here.
 *  - **Choose a folder to start in.** `FolderPickerView`, presented from this
 *    screen so the answer can be **kept** — `RootView`'s copy of the picker
 *    starts a session and throws the path away, which is right for the session
 *    list and wrong for a folder the copilot will keep using. The one surviving
 *    row that is a question, and it survives only because it is the **only**
 *    row drawn when the grant list is empty, which is exactly the rule
 *    `SessionListView`'s empty state already keeps: a phone that has been shared
 *    nothing cannot start a session anywhere, and *Choose a folder* is the one
 *    press that changes that. A fresh server pairing lands in precisely that
 *    state.
 *  - **Open the agent that is already running here.** `DeckModel.open(session:)`
 *    on the very session `land()` would have opened by itself — one call,
 *    `copilotSession`, so the row and the landing can never name two different
 *    sessions. It is the way back in for somebody who came back out, and it is a
 *    real conversation rather than a signpost to one.
 *
 * A **composer** stood here for one round, between `HostLink.askAgent` arriving
 * and the tab learning to land. It is gone, and its own argument is why: the tab
 * now opens `SessionChatView`, which has a field of its own, so the only way to
 * reach a second field for the same session would be to leave that chat and type
 * at it from above. Two fields, one session. Worse, the landing fires the moment
 * a dropped connection returns, so a half-typed line in that field would be
 * carried off the screen by a navigation nobody asked for. `askAgent` is still
 * the right method and inspect mode's `sendToAgent` is untouched; this screen
 * simply no longer has a question that needs either.
 *
 * ## "Chat to the copilot", answered honestly
 *
 * **A copilot conversation is not reachable on a server, and it is declined on
 * purpose in three places rather than merely missing from one.**
 *
 *  - `src/headless/cli.ts`, `NO_COPILOT_HERE`: *"the copilot's tools only run in
 *    the desktop app, so no Copilot appears on a device paired to a server, of
 *    either kind."*
 *  - `src/headless/host.ts` declines to pass a `copilot` at all, and says why it
 *    is not simply wired: `registerDeckControlIpc` wants an `ipcMain` and an
 *    approver `WebContents`, because an `alter`-tier confirmation is a dialog in
 *    a window and **there is no window there**. Its own conclusion is the rule
 *    this screen obeys — *"passing the layer without its tool server would
 *    therefore draw a fourth pill on the phone whose every Start button refuses,
 *    which is worse than the absence, not better."*
 *  - `src/renderer/copilot/useCopilotMachines.ts` reaches the same answer from
 *    the desktop's side and lists no servers in the copilot's machine switcher,
 *    because *"every server row this switch ever had was a disabled row, which
 *    is the dead control rather than the truth."*
 *
 * So the honest offer is the same capability at a different surface — **an
 * agent in a session on this server** — and the tab now *is* that conversation
 * rather than a way to one. What a server calls a copilot session is a session
 * with the machine's own `agents.defaultProvider` in it, which is *"according to
 * the settings of the copilot"* read literally: `host-core.ts` reaches for that
 * exact field when a `create` frame names no provider.
 *
 * ### The composer waited for a method rather than shipping half of one
 *
 * The first version of this screen had **no field**, and that was correct at the
 * time: neither existing method could send from here. `sendChatMessage(_:into:)`
 * submits properly — the 57-byte paste-threshold measurement and the separate
 * return are in its header — but writes straight into a pty this device may not
 * be attached to, which `server.ts` answers with `unauthorized`.
 * `sendToAgent(_:into:)` solves exactly that half — attach, hold the line, flush
 * on the machine's confirmation, expire after twelve seconds — and deliberately
 * never submits, because it exists for inspect mode where submitting on
 * somebody's behalf is not wanted.
 *
 * `HostLink.askAgent(_:into:)` is the two halves joined, with the return queued
 * as its **own** entry so the gap survives `flushAgentLines`, and the field
 * exists because that method does. A Send button wired to either half alone
 * would have been the exact fault this screen was rewritten to remove, so the
 * gap was reported rather than papered over.
 *
 * ## "Copilot should have a consistent connection"
 *
 * On a desktop the copilot has states that move — `.connecting`, `.connected`,
 * `.notGranted` — and `CopilotView` draws each. On a server it is a permanent
 * absence, and a permanent absence rendered through socket-gated flags reads as
 * a **broken feature**: every capability on `HostLink` is `connection.isLive &&
 * …`, so a phone in a lift watched this screen's rows appear and disappear while
 * nothing about the machine had changed at all.
 *
 * The rule here is one sentence. **Nothing on this screen is drawn from the
 * socket.** It is drawn from what the machine has *said*, which is remembered in
 * `Offer` for as long as the screen is up, and the socket gets exactly one line,
 * five seconds late, through the same `ConnectionNotice` the pill and both
 * banners read — *"a drop says nothing for its first five seconds"*. So a
 * reconnect changes nothing on screen, an outage changes one line, and the
 * sentence about where the copilot lives is derived from `HostKind` and can
 * never move at all.
 *
 * The landing obeys the same rule from the other side: it waits for a live
 * connection rather than pushing a terminal that cannot attach, and it happens
 * by itself when the wire comes back — so an outage delays the destination
 * instead of replacing it with an explanation of why there isn't one.
 *
 * Remembering is the same shape as `ConnectionState.awaitingApproval`, which
 * stays true across the attempts in between for the same reason, and it is
 * deliberately **not** persisted: a remembered yes across a launch would draw a
 * row for a machine that may have been revoked while the phone was asleep, which
 * is the argument `DeckModel.showsCopilotTab` makes about never remembering the
 * pill.
 *
 * ## The gear in the top right, and why the ⓘ below it stayed an ⓘ
 *
 * > *"here on the right top corner you can give a button for all about
 * > copilot."*
 *
 * The `InfoDot` beside *"It lives in the desktop app."* stays and does not grow.
 * It answers one question — **why not here** — and a popover is the right size
 * for one question. What it is the wrong size for is everything the toolbar
 * button opens: the folder the copilot works in, the agent it runs, the devices
 * that reach it, and — at the foot of that screen, behind its own chevron —
 * *what a copilot is at all*. A popover somebody has to scroll is the long
 * description he struck off these screens, with an extra tap in front of it.
 *
 * So the two coexist and neither grows: the dot for the sentence it sits beside,
 * the gear for the controls. `CopilotControlView` carries the argument for the
 * glyph — a gear rather than a second ⓘ, because the landed session already
 * draws one — and for the button being a modifier applied at three call sites
 * rather than written out at each.
 *
 * It matters more here than it reads. This screen is the **fallback** — the tab
 * usually lands somebody straight into a live chat instead — so the state with
 * the least on screen naming what you are talking to is the state this file is
 * not rendering, and the button has to be on both or it goes missing exactly
 * where it is needed.
 *
 * ## The bar is drawn here, so the clearance is back
 *
 * `DeckChrome.showsTabBar(on: .copilot)` was false for a while — *"pill should
 * not be inside the chat box"* — and this scroll view correctly had no
 * clearance. Both halves changed together: the chat box moved to `.session`
 * when the tab started landing in one, and hiding the bar had made this the one
 * tab in the app that could not be left sideways (the screen walk found it,
 * failing to reach Menu from here). The bar is drawn again and the rows at the
 * bottom of this list would sit under it without the clearance.
 *
 * ## No ground of its own
 *
 * `CopilotView.content` is drawn inside a `ZStack` that has already painted
 * `Theme.background`, so this view deliberately paints none: a second opaque
 * layer over the first is one more surface to keep in step for no visible gain.
 */

import SwiftUI

struct CopilotOnServerView: View {
    let model: DeckModel
    /// Named rather than read off `model.current`, for the reason every screen
    /// on this tab names its machine: the switcher in the title can move
    /// underneath, and a screen that followed it would explain one machine while
    /// standing under another machine's name.
    let hostID: String

    /**
     * What this machine has said it can do, since this screen came up.
     *
     * The whole of *"copilot should have a consistent connection"* is in this
     * one `@State`. See the header: the capabilities it mirrors are all
     * `connection.isLive && …`, and a row drawn straight off one of them leaves
     * and returns on every blink.
     */
    @State private var offer = CopilotOnServer.Offer()

    /// The last agent this server named as the one a fresh session starts with,
    /// kept for the same reason. `ServerSettingsLink.welcomed` clears its rows
    /// on every welcome and re-reads a moment later, so a reconnect would
    /// otherwise take the agent's name off the Start row and put it back.
    @State private var agent: String?

    /// A refusal this screen caused and must therefore explain. `HostLink`'s own
    /// `lastError` is `private(set)`, and its sentence for a refused `create` is
    /// *"cannot start sessions from the phone"* — true of a guest and wrong for
    /// the case that actually reaches it here, which is a machine that has gone
    /// away. See `CopilotOnServer.refusal`.
    @State private var refusal: String?

    /**
     * Whether this visit has already put somebody in a session.
     *
     * A one-shot latch for the life of this navigation stack, and it is what
     * stops the landing being a **trap**: without it, popping back out of the
     * conversation would re-run the push on the next frame and there would be no
     * way to reach this screen at all. Somebody who came back out meant to come
     * back out, and what they get is the screen with the rows on it.
     *
     * It is deliberately not reset when the connection returns or the tab is
     * re-selected. Re-selecting the tab does not need it — `copilotRoute` still
     * holds the session, so the pill lands back in the conversation on its own,
     * which is the tab-stack behaviour every other tab already has.
     */
    @State private var landed = false

    /// A `create` is on the wire and nothing has come back yet. Only ever true
    /// for the automatic start — a press has the row's own dimming to say it was
    /// received, and this exists because an automatic one has nothing on screen
    /// at all between the frame going and the session arriving.
    @State private var starting = false

    /**
     * This visit has already tried to start one, whatever came of it.
     *
     * **The latch that stops the loop.** `land()` runs on every change of a key
     * that includes the session list and the connection, so a start that fails —
     * a machine that took the folder back, a `create` that is never answered —
     * would otherwise be re-sent on the next frame, and again, for as long as
     * somebody stood on the screen. One attempt per visit, and what a person
     * gets after it is a sentence saying what happened and a row to press.
     */
    @State private var attemptedStart = false

    /// The folder picker, presented here rather than through
    /// `DeckModel.showingFolderPicker`. That flag has one callback, in
    /// `RootView`, and it starts a session and nothing else; this screen has to
    /// record the answer before it starts anything.
    @State private var picking = false

    /// This phone's record of what was decided about this machine's copilot —
    /// the folder, and whether this tab may start one. See `CopilotSetupBook`
    /// for why it is held here and not written to the machine.
    var book: CopilotSetupBook = .shared

    private var host: HostLink? { model.host(hostID) }

    /// *"Server"*, from the machine's own answer rather than from the fact that
    /// this file is only rendered for one kind. `HostKind.noun` reads "machine"
    /// for a host too old to have said, which is true of both and singles out
    /// neither — and is the right word if this screen is ever shown for one.
    private var noun: String { host?.hostKind.noun ?? "server" }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                headline
                wire
                acts
                notice
                // The tab draws its bar again — see the note above — and the
                // last row of this list would sit under it without this.
                TabBarClearance()
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        /*
         * The gear in the top right, which is the whole of *"here on the right top
         * corner you can give a button for all about copilot."*
         *
         * `CopilotView` owns this navigation bar — this screen is rendered
         * inside its `ZStack` — and a `.toolbar` written here still lands in it,
         * because SwiftUI gathers toolbar items from the whole hierarchy under a
         * navigation container. Nothing collides: that screen's only trailing
         * item is its overflow menu, and the menu is drawn only when this phone
         * may watch a copilot, which is never true on the branch that renders
         * this file.
         *
         * See `AboutCopilotView` for why the destination is a push rather than a
         * sheet, and why the placement lives in a modifier instead of six lines
         * copied into each of the three screens this tab can be showing.
         */
        .copilotControlsButton(model: model, hostID: hostID)
        // `initial` so the first frame is a measurement rather than an empty
        // screen that fills in. The key is every fact `learn()` reads, joined,
        // because `onChange` compares values and these are four booleans and a
        // string that have to be watched together.
        .onChange(of: heard, initial: true) { learn() }
        /*
         * **A task rather than an `onChange`, and it waits before it navigates.**
         *
         * Separate from `learn` and watching a different set of facts, because
         * this one navigates. What it took three measured runs to learn is that
         * navigating *early* does not work at all: the append reaches
         * `DeckModel` — traced, `copilotRoute` went to 1 — and SwiftUI then
         * reverts it, because a `NavigationStack`'s path written while the tab
         * is still transitioning onto screen is clobbered by the stack's own
         * settling. The screen sat on *Open the conversation* with `route=0` and
         * `landed=1`, and pressing that row — the identical call, a moment later
         * — pushed correctly every time. The difference was never the call.
         *
         * `.task(id:)` gives the wait a lifetime: it is cancelled when the key
         * moves and when this screen goes, so a landing that is no longer wanted
         * never happens, and there is no timer to cancel by hand.
         */
        .task(id: reachable) { await landWhenTheStackWillTakeIt() }
        /*
         * A start that never lands, said out loud rather than spun on forever.
         *
         * `.task(id:)` rather than a held `Task`: it is cancelled and restarted
         * when `starting` moves and cancelled when this screen goes, which is
         * exactly the lifetime this timer wants and is one line instead of three
         * places to remember to cancel in.
         */
        .task(id: starting) {
            guard starting else { return }
            try? await Task.sleep(nanoseconds: UInt64(CopilotOnServer.startSeconds * 1_000_000_000))
            guard !Task.isCancelled, starting else { return }
            starting = false
            refusal = CopilotOnServer.startNeverLanded(noun: noun)
        }
        .sheet(isPresented: $picking) {
            FolderPickerView(model: model, action: .choose) { folder in
                // Recorded **before** the session is asked for, so a machine
                // that refuses the `create` still leaves the copilot pointed
                // where somebody said. The row that comes back is then a retry
                // rather than the same question again.
                book.setFolder(folder, host: hostID)
                begin(in: folder)
            }
        }
    }

    // MARK: - Where the copilot lives, and what this machine is

    /**
     * Two lines and a ⓘ, and that is the entire explanation.
     *
     * It was three blocks, one of them a two-line paragraph defining what a
     * copilot is. His rule, said twice in one recording and the one most often
     * broken while fixing something else: *"here you have a very long
     * description… Remove this full shit. I don't want any kind of long
     * descriptions anywhere. Just if somewhere it's very required, give the i
     * icon."* So the definition is gone — somebody who tapped a sparkle knows
     * what they tapped — and what is left answers the two questions a person
     * standing here actually has, one line each: **what this machine is**, and
     * **where the copilot is instead**.
     *
     * Both are derived from `HostKind`, which arrives in the `welcome` and does
     * not move afterwards, so this is the part of the screen that is guaranteed
     * never to flicker. Nothing here is a verb: everything pressable is in the
     * card below, so an eye looking for a way forward has one place to look.
     */
    private var headline: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: "sparkles")
                    .font(.system(size: 22, weight: .light))
                    .foregroundStyle(Theme.faint)
                    .frame(width: 24)
                Text("No copilot on this \(noun)")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(Theme.primary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("copilot.onServer.title")
                Spacer(minLength: 0)
            }

            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text("It lives in the desktop app.")
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("copilot.onServer.where")
                InfoDot(about: "no copilot here", text: Self.why)
                Spacer(minLength: 0)
            }
        }
        .padding(.top, 8)
    }

    /**
     * The whole reason, kept in one place and said the way the host says it.
     *
     * The first two sentences are `NO_COPILOT_HERE` from `src/headless/cli.ts`,
     * in this app's voice rather than copied — Swift cannot import it, so this is
     * its mirror and not its second source, the same arrangement `Brand` has with
     * `src/shared/brand.ts`.
     *
     * The **third** sentence exists only on the phone, and it is the one this
     * screen was written for. The desktop's `.notOffered` state names the guest
     * case, correctly, because on a desktop it is one of the two things the
     * absence can mean. Here it is neither, and somebody carrying the desktop's
     * explanation over would go and re-pair a phone that was paired right. So
     * the guest question is closed out loud instead of left open.
     *
     * The **fourth** closes the question this round was about — *why can I not
     * just talk to it here* — because that is the next thing somebody asks and
     * the answer is not "not yet", it is a tool boundary. An agent in a session
     * is where the same work happens, which is what the card underneath offers.
     */
    private static let why =
        "The copilot's tools are the desktop app's own — its session list, its transcripts, its "
        + "settings — and a server has no app for them to drive. So no copilot appears on a device "
        + "paired to a server. It is not about how this phone was paired: a server has none for "
        + "any device, of either kind. An agent running in a session here is the same work at a "
        + "different surface, and that is what this screen starts."

    // MARK: - The socket, once and late

    /**
     * The one line on this screen that is about *now*.
     *
     * Read through `ConnectionNotice`, which is the object the toolbar pill and
     * both banners read, so this screen cannot disagree with them about whether
     * this is a moment worth mentioning. Five seconds of grace is his number:
     * comfortably longer than a relay dial or a lift, comfortably shorter than
     * the point somebody decides the app is broken.
     *
     * Drawn above the card rather than below it because it is the reason those
     * rows are dim, and a reason that arrives after the press is not a reason.
     */
    @ViewBuilder
    private var wire: some View {
        if let host, let line = CopilotOnServer.wireLine(host.connection, showing: host.notice.isShowing) {
            HStack(spacing: 8) {
                Image(systemName: "bolt.horizontal.circle")
                    .font(.system(size: 14))
                Text(line)
                    .font(.system(size: 13))
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .foregroundStyle(Theme.warning)
            .padding(.top, 16)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("copilot.onServer.wire")
        }
    }

    // MARK: - What can be done from here

    /**
     * The card, which is only ever seen when the tab could not do its job.
     *
     * > *"the copilot page will directly land into some session — not to a
     * > selection and something on the page. It is still not that way… Because
     * > it should directly start a session on whatever the selected folder for
     * > it is."*
     *
     * **The two-row chooser is gone.** It was drawn before a folder had ever been
     * chosen, and it is precisely the *"selection and something on the page"* he
     * is objecting to — a question standing between somebody and the thing they
     * tapped the pill for. What replaced it is not a smaller question: the tab
     * starts in the machine's own folder and writes down where that turned out to
     * be, so the folder is still a real, visible, changeable setting on
     * `CopilotControlView` — **discovered by first use rather than demanded up
     * front.**
     *
     * So this card has four states and three of them are consequences rather than
     * choices:
     *
     *  - **Starting.** A line. The conversation replaces this screen when the
     *    machine answers; there is nothing to press in the meantime.
     *  - **Somebody came back out.** The way back in, naming the folder.
     *  - **A start did not happen.** `notice` says why, and this is the row that
     *    tries again — the retry `attemptedStart` deliberately does not do by
     *    itself.
     *  - **The machine will refuse a plain start.** The one case where a press is
     *    genuinely required rather than merely offered, and it survives for that
     *    reason alone. `CopilotOnServer.start` decides it: a grant list that is
     *    **present and empty** is a person having shared nothing with this device,
     *    every `create` without a folder is refused, and the only thing that can
     *    work is naming a folder. One row, not two, and it is the one that works.
     *
     * An empty card under a caption is furniture describing nothing, so a machine
     * that can do none of the four gets the headline and the wire line and no
     * card at all — the first seconds of a first connection, or a phone opened
     * while its server is off.
     */
    @ViewBuilder
    private var acts: some View {
        let folder = book.folder(host: hostID)
        let running = CopilotOnServer.copilotSession(in: host?.sessions ?? [], folder: folder)
        let plain = CopilotOnServer.start(offer: offer, granted: host?.granted)
        // The one row that is a question, and only where nothing else can work.
        let mustPick = !plain.now && plain.inAFolder && running == nil && !starting
        let canRetry = attemptedStart && !starting && running == nil && plain.now

        if starting || running != nil || canRetry || mustPick {
            VStack(alignment: .leading, spacing: 0) {
                caption("The copilot on this \(noun)")
                card {
                    if starting {
                        HStack(spacing: 12) {
                            ProgressView()
                                .controlSize(.small)
                                .tint(Theme.faint)
                                .frame(width: 24)
                            Text(CopilotOnServer.startingLine(folder: folder))
                                .font(.system(size: 16))
                                .foregroundStyle(Theme.primary)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                        .accessibilityIdentifier("copilot.onServer.starting")
                    } else if let running {
                        act(title: "Open the conversation",
                            detail: "\(ServerSettingsText.providerLabel(running.provider)) in "
                                + "\(SessionDetails.folderName(running.cwd)).",
                            icon: "bubble.left.and.bubble.right",
                            id: "ask") { model.open(session: running.id, on: hostID) }
                    } else if canRetry {
                        act(title: folder.map { "Start it in \(SessionDetails.folderName($0))" }
                                ?? "Start a session",
                            detail: startDetail,
                            icon: "arrow.clockwise",
                            id: "retry") { begin(in: folder) }
                    } else if mustPick {
                        act(title: "Choose a folder to start in",
                            detail: "This \(noun) is not sharing one with this phone yet.",
                            icon: "folder.badge.plus",
                            id: "startIn") { pickFolder() }
                    }
                }
            }
        }
    }

    /**
     * What will be in the session this button starts, named rather than implied.
     *
     * `agents.defaultProvider` is a setting the **server** owns, and it is what
     * `host-core.ts` reaches for when a `create` frame names no provider:
     * `input.provider ?? store().getPreferences().defaultProvider`. So this is
     * not a guess about what a session usually contains — it is the same value
     * the machine is about to act on, and it is what makes *"start a session"* a
     * truthful answer to *"start the copilot"* rather than a change of subject.
     *
     * A server that has not said gets the plain sentence. Naming an agent this
     * app has not been told about would be the one thing worse than not naming
     * one: the row would read *Claude Code* over a machine that starts a shell.
     */
    private var startDetail: String {
        CopilotOnServer.agentSentence(provider: agent) ?? "A shell on this \(noun), and its agent in it."
    }

    // MARK: - Landing

    /**
     * Put somebody in the conversation — and start one if that is what was asked
     * for.
     *
     * > *"copilot page should be always landing in a copilot session according
     * > to the settings of the copilot — either in an existing session if there
     * > is any, or it should start a new. But it should be always a chat to land
     * > with, terminal and chat mode too."*
     *
     * > *"if there is no session it will start a new session, and if there is
     * > already a previous session going on it will just continue from there."*
     *
     * ## The half that used to be refused, and why it is not any more
     *
     * This method used to do the first clause and deliberately not the second.
     * The argument was good and is worth keeping written down: a session on a
     * server runs `agents.defaultProvider` — a real agent, spending real money —
     * the Copilot pill is drawn **unconditionally** on a headless host so the tab
     * is one mis-tap away at all times, and nothing here undoes a spawn.
     *
     * What that argument was missing is that it applies to a tab **that has not
     * been set up**. Asad has overruled it for one that has, and the overrule is
     * exact: he chooses the folder, on purpose, once — and after that a tab that
     * asks him the same question every visit is the defect. So the `.start` case
     * exists and is reachable **only** through a record somebody's finger made.
     * `CopilotSetupBook` holds it, `CopilotOnServer.landing` reads it, and a
     * machine with nothing in it starts nothing however reachable it is.
     *
     * The three guards that survive unchanged, because they are about whether
     * this can work rather than about whether it should:
     *
     *  - **Already landed.** A one-shot per navigation stack. Without it,
     *    popping back out of the conversation re-pushes it on the next frame and
     *    this screen becomes unreachable — a trap, not a default.
     *  - **Not connected.** A pushed terminal cannot attach over a dead socket,
     *    and `TerminalScreen` will not raise the chat without a live connection
     *    because its way back to the terminal is hidden there. The landing
     *    happens by itself when the wire comes back.
     *  - **Already attempted.** One start per visit, so a refusal is a sentence
     *    rather than a loop. See `attemptedStart`.
     *
     * The push itself is not made here for a started session: `createSession`
     * sets `openWhenCreated`, and `DeckModel` opens what the machine made on the
     * `created` frame — the same road the Start row has always taken.
     */
    /**
     * Ask to land, and keep asking until the stack actually takes it.
     *
     * ## Why this is a loop and not a call
     *
     * A `NavigationStack`'s path written while its tab is still transitioning on
     * screen is **silently discarded**. Measured over four runs against a real
     * machine: `DeckModel.open` reached its append every time — traced, with
     * `copilotRoute` going to 1 — and a moment later the screen was still the
     * root with `route=0` on it. Pressing *Open the conversation*, which is the
     * identical call from a finger a few seconds later, pushed correctly every
     * time. The call was never wrong; only its moment was.
     *
     * A single delay was tried first and is the wrong shape: it is a guess about
     * how long a transition takes on a device nobody has measured, and it fails
     * silently in the direction that matters — a slow first frame means the tab
     * asks a question he has already said it must not ask.
     *
     * So this asks, looks at whether the route took, and asks again. Bounded, so
     * a machine that genuinely will not open the session stops rather than
     * spinning; and `land()` itself decides afresh each time, so a session that
     * ended underneath, or a device that lost its connection, falls out through
     * the ordinary rules rather than through this loop.
     *
     * `.task(id:)` owns the lifetime: leaving the screen or a change in
     * `reachable` cancels it, so a landing nobody wants any more never happens.
     */
    private func landWhenTheStackWillTakeIt() async {
        for attempt in 0 ..< CopilotOnServer.landingTries {
            // The first wait is the long one — it is the transition itself. The
            // rest are short because by then the only question is whether the
            // last ask survived.
            try? await Task.sleep(for: .milliseconds(attempt == 0 ? 300 : 180))
            guard !Task.isCancelled else { return }
            land()
            // The route holding what was asked for is the only proof that the
            // push took. Anything else — a `.stay`, a start in flight — ends the
            // loop too, because both are answers rather than a lost push.
            if !model.copilotRoute.isEmpty || starting || attemptedStart || !landed { return }
            // The ask was made and thrown away. Let the next turn make it again.
            landed = false
        }
    }

    private func land() {
        guard let host else { return }
        /*
         * **Only while this tab is the one on screen.**
         *
         * Measured, and it is the reason this screen sat on a row saying *Open
         * the conversation* while a session was running: a `TabView` builds
         * every tab's content, so this view is created — and `onChange(initial:
         * true)` fires — before `DeckModel.tab` has become `.copilot`.
         * `DeckModel.open(session:on:)` reads that flag to choose a stack, so
         * the landing pushed the terminal onto the **Sessions** stack, set the
         * one-shot latch, and left this screen showing a row for a session it
         * had already opened somewhere else. On screen: `landed=1 route=0`.
         *
         * The tab is in `reachable` too, so becoming the copilot's tab is itself
         * a reason to re-evaluate — without that this guard would turn one
         * mis-timed landing into no landing at all.
         */
        guard model.tab == .copilot else { return }
        switch CopilotOnServer.landing(in: host.sessions,
                                       connection: host.connection,
                                       setup: book.setup(host: hostID),
                                       already: landed,
                                       attempted: attemptedStart,
                                       canStart: host.canStartSomewhere,
                                       plainStartTaken: CopilotOnServer
                                           .start(offer: offer, granted: host.granted).now) {
        case .stay:
            return
        case let .open(sessionID):
            landed = true
            starting = false
            // Written down before the push, not after, because the push replaces
            // this screen and whatever runs after it runs on a view that is on
            // its way out.
            adopt(sessionID, on: host)
            model.open(session: sessionID, on: hostID)
        case let .start(folder):
            // Set before the frame goes, not after: a `create` refused
            // synchronously would otherwise leave the latch open and the next
            // redraw would send another.
            attemptedStart = true
            starting = true
            refusal = nil
            host.createSession(in: folder)
        }
    }

    /**
     * **Write down where the copilot actually is.**
     *
     * This is the half of the correction that makes the other half safe. The tab
     * starts without asking, in the machine's own folder, and this runs the
     * instant it lands in what came back — so the answer to *where does my
     * copilot work* exists, on a row, with a picker beside it, before anybody
     * could think to ask. A folder **guessed and silently kept** was the real
     * objection to starting unasked; a folder discovered and immediately recorded
     * is not that.
     *
     * It writes only when nothing is recorded, and that guard is doing more than
     * it looks. With a folder set, `copilotSession` matches **only** a session in
     * it, so a landing can only ever be a session in the recorded folder — the
     * write would be a no-op. Without one, the landing is the first agent session
     * on the machine, which is either the one this tab just started or one that
     * was already running and is now, correctly, what this machine's copilot is.
     *
     * The narrow race worth naming rather than defending against: a `create` in
     * flight and an unrelated agent session appearing from another device in the
     * same instant. The tab lands in the older of the two and records its folder
     * — which is still *the folder the copilot is in*, and is one press on the
     * control screen from being whatever somebody would rather it were.
     */
    private func adopt(_ sessionID: String, on host: HostLink) {
        guard book.folder(host: hostID) == nil else { return }
        guard let landed = host.sessions.first(where: { $0.id == sessionID }) else { return }
        book.setFolder(landed.cwd, host: hostID)
    }

    /// The facts `land()` reads, as one value `onChange` can compare. Separate
    /// from `heard` because this one moves the screen: joining them would re-run
    /// a navigation every time a capability flag settled.
    ///
    /// Every agent session's id rather than only the first, because the session
    /// this tab starts has to be noticed arriving beside ones that were already
    /// there — a key carrying only the first would not change when one did.
    private var reachable: String {
        guard let host else { return "-" }
        let setup = book.setup(host: hostID)
        return [model.tab == .copilot ? "1" : "0",
                host.connection.isLive ? "1" : "0",
                host.canStartSomewhere ? "1" : "0",
                CopilotOnServer.agentSessions(host.sessions).map(\.id).joined(separator: ","),
                setup?.folder ?? "",
                setup?.startOnOpen == true ? "1" : "0"].joined(separator: "|")
    }

    // MARK: - Doing it

    /**
     * Start one, and say something true if the machine will not.
     *
     * The guard is here rather than left to `HostLink.createSession`, which has
     * one for the case it was written for — a phone that may not start sessions
     * at all — and whose sentence, *"cannot start sessions from the phone"*, is
     * wrong for the case that reaches it from this screen. The row is only drawn
     * for a machine that has said it can, so a refusal here means the machine
     * has gone away or the folders were taken back while somebody was reading.
     */
    private func begin(in folder: String?) {
        guard let host else { return }
        guard host.canStartSomewhere else {
            refusal = CopilotOnServer.refusal(host.connection, noun: noun)
            return
        }
        refusal = nil
        // A hand-pressed start counts as this visit's attempt, so the automatic
        // one cannot fire behind it and put a second agent on the machine.
        attemptedStart = true
        starting = true
        host.createSession(in: folder)
    }


    /**
     * Raise the folder picker, which records the folder and then starts in it.
     *
     * Presented from this screen rather than through
     * `DeckModel.showingFolderPicker`. That flag has exactly one callback, in
     * `RootView`, and it does one thing — `model.createSession(in: folder)` —
     * with the answer thrown away afterwards. The copilot's setup needs the
     * answer kept, which is the split `FolderPickerView` already documents about
     * itself: *"the picker's job is to answer which folder, and the same answer
     * will be worth having the day something other than a new session needs
     * one."* This is that day.
     *
     * `FolderPickerView` browses `model.current`, and this tab only ever renders
     * for the current machine — `CopilotTabScreen` builds it from `model.current`
     * — but the check is written rather than assumed, because the cost of it
     * being wrong is a picker walking one machine's disks under another's name.
     */
    private func pickFolder() {
        guard let host, host.id == model.currentHostId else { return }
        guard host.canPickFolders else {
            refusal = CopilotOnServer.refusal(host.connection, noun: noun)
            return
        }
        refusal = nil
        picking = true
    }

    /// The facts `learn()` reads, as one value `onChange` can compare. Four
    /// booleans and a string watched together, because acting on any one of them
    /// alone would leave the other four a frame behind.
    private var heard: String {
        guard let host else { return "-" }
        return [host.canStartSomewhere ? "1" : "0",
                host.canPickFolders ? "1" : "0",
                wireAgent ?? ""].joined(separator: "|")
    }

    /// What this machine currently says its default agent is, or nil while it
    /// has not said. Nil is *not yet* and never *none*, which is why `learn()`
    /// only ever overwrites `agent` with something.
    private var wireAgent: String? {
        host?.serverSettings.rows?.first { $0.key == .defaultProvider }?.value
    }

    /// Take everything the machine has said and keep it. See the header: this is
    /// the whole of the consistency rule, and it is monotonic on purpose — a
    /// socket that dropped has not made the machine less capable.
    private func learn() {
        guard let host else { return }
        // Idempotent and cheap; the link refuses a second read on the same
        // connection itself, and re-arms on each welcome — which is why this is
        // called on every change rather than once in `onAppear`.
        host.serverSettings.ensureRead()
        offer.heard(canStart: host.canStartSomewhere, canPick: host.canPickFolders)
        if let named = wireAgent, !named.isEmpty { agent = named }
    }

    // MARK: - What this screen caused

    /// A refusal, under the row that caused it. The same place and the same
    /// metrics `ServerSettingsSection` puts the server's own notice, so the two
    /// read as one app. `Theme.warning` rather than that section's
    /// `Theme.critical`: a failed `settings.apply` is a change somebody asked
    /// for that did not happen, and nothing here is destroyed or wrong with the
    /// machine — it is out of reach.
    @ViewBuilder
    private var notice: some View {
        if let refusal {
            Text(refusal)
                .font(.system(size: 12))
                .foregroundStyle(Theme.warning)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 4)
                .padding(.top, 8)
                .accessibilityIdentifier("copilot.onServer.notice")
        }
    }

    // MARK: - Rows

    /**
     * One thing this screen does.
     *
     * A `Button` rather than a `NavigationLink`, because every one of these ends
     * in a frame going to the machine rather than in a push this side can make.
     * The chevron stays: in this app a row without one is a row that leads
     * nowhere, and all three of these end somewhere — two in a terminal that
     * `DeckModel.open(session:)` pushes onto this tab's own stack, one in a
     * sheet `RootView` presents.
     *
     * `dead` is the graced answer and not the live one. A row that greyed the
     * instant a socket blinked would be the flicker this screen was rewritten to
     * remove; a row still lit five seconds into a real outage would be a control
     * that cannot act. `ConnectionNotice` is where the app already decides which
     * of those two moments it is in.
     */
    private func act(title: String,
                     detail: String,
                     icon: String,
                     id: String,
                     go: @escaping () -> Void) -> some View {
        let dead = host?.notice.isShowing == true && host?.connection.isLive != true
        return Button(action: go) {
            HStack(spacing: 12) {
                // Monoline: 19pt light in a 24pt column, which is the metric
                // every row in the settings surfaces uses. See `SettingsRowBody`.
                Image(systemName: icon)
                    .font(.system(size: 19, weight: .light))
                    .foregroundStyle(Theme.secondary)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 16))
                        .foregroundStyle(Theme.primary)
                    Text(detail)
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.faint)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.faint)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // `.plain` does not dim a disabled label, so the dimming is stated. The
        // row has to *look* unavailable as well as be unavailable, or a press
        // that does nothing is indistinguishable from a press that was missed.
        .opacity(dead ? 0.4 : 1)
        .disabled(dead)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title). \(detail)")
        .accessibilityIdentifier("copilot.onServer.\(id)")
    }

    // MARK: - Its own chrome

    /*
     * Drawn here rather than borrowed, and that is not a preference.
     *
     * `SectionCaption`, `SettingsGroup` and `SettingsDivider` are **private to
     * `DeckTabs.swift`** — a screen that reached for them would have to live in
     * that file, which is the argument `MachineDetailView` and `AppLockScreen`
     * both make about the same three names. These are the same shapes at the
     * same metrics: 11pt kerned caption, a `Theme.surface` card at radius 20, and
     * a hairline inset to the label rather than to the card's edge.
     */
    private func caption(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .kerning(0.6)
            .foregroundStyle(Theme.faint)
            .textCase(.uppercase)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, 4)
            .padding(.top, 24)
            .padding(.bottom, 8)
    }

    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(spacing: 0) { content() }
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private var line: some View {
        Rectangle()
            .fill(Theme.hairline)
            .frame(height: 0.5)
            .padding(.leading, 16)
    }
}

/**
 * Every decision this screen makes, as functions with no view in them.
 *
 * Here for the reason `ServerSettingsLink.merge` and `ConnectionGrace` are
 * pure: the rules below are the ones that can be wrong in a way nobody sees —
 * a row drawn for a machine that will refuse it, a sentence naming an agent
 * that is not there, an outage line over a live connection — and a rule that
 * can only be checked by launching the app onto a real server is a rule that
 * gets checked once. `CopilotOnServerTests` walks all of them.
 */
enum CopilotOnServer {

    /**
     * What this machine has said it can do, remembered rather than sampled.
     *
     * Both flags on `HostLink` that these mirror are `connection.isLive && the
     * capability`, which makes them facts about **now** where this screen needs
     * facts about **the machine**. Monotonic within the life of the screen: a
     * dropped socket has not taken the `create` verb away from a server, and
     * redrawing as though it had is the flicker he asked to be rid of.
     *
     * Not persisted, deliberately — see the header. A yes remembered across a
     * launch is a row drawn for access that may have been revoked while the
     * phone was asleep.
     */
    struct Offer: Equatable {
        /// The machine advertised `create` and this device may start somewhere.
        private(set) var start = false
        /// The machine advertised `folders.pick` for this device.
        private(set) var pickFolders = false

        init(start: Bool = false, pickFolders: Bool = false) {
            self.start = start
            self.pickFolders = pickFolders
        }

        mutating func heard(canStart: Bool, canPick: Bool) {
            if canStart { start = true }
            if canPick { pickFolders = true }
        }
    }

    /// Which of the two starting rows are drawn.
    struct Start: Equatable {
        let now: Bool
        let inAFolder: Bool
    }

    /**
     * Which starting rows this machine can honestly offer.
     *
     * The middle case is the one that matters and it is not this screen's
     * invention — it is the rule `SessionListView`'s empty state already keeps.
     * A grant list that is **present and empty** is a person having chosen to
     * share nothing with this device, and `create` in that state is refused by
     * the machine every time; the row that works is the picker, which is how a
     * folder comes to be shared in the first place. A fresh server pairing lands
     * exactly there, so this is the ordinary case on a server rather than an
     * edge of it.
     *
     * `nil` is a machine too old to have said, which is not the same as empty
     * and must not collapse into it: that host enforces against its own open
     * folders and a plain start is right for it. `HostLink.granted` keeps the
     * two apart for this reason.
     */
    static func start(offer: Offer, granted: [String]?) -> Start {
        guard offer.start else { return Start(now: false, inAFolder: false) }
        if granted?.isEmpty == true { return Start(now: false, inAFolder: offer.pickFolders) }
        return Start(now: true, inAFolder: offer.pickFolders)
    }

    /**
     * **The session this machine's copilot is**, or nil if there is not one.
     *
     * Three conditions on what counts as an agent session at all, and each one
     * removes a lie. **Not exited**, because a finished session has no agent
     * listening. **A provider that is not `shell`**, because a plain shell is not
     * something to ask — the row would open a bare prompt under a button offering
     * a conversation. And **a provider that was named at all**, because the field
     * is free-form and a host that sent nothing has told this app nothing;
     * guessing an agent into that gap is how a row comes to say *Ask Claude Code*
     * over a shell.
     *
     * Then the folder, which is the part this rule gained when the copilot got a
     * setup:
     *
     * > *"Whatever we set in the settings, that copilot will be always on this
     * > folder."*
     *
     * So once a folder has been chosen, **only a session in that folder is the
     * copilot.** An agent running somewhere else on the same machine is somebody
     * else's work, and a tab that landed in it would open a different project's
     * conversation under the copilot's name — and would then never start the one
     * that was asked for, because it would look as though the copilot were
     * already running.
     *
     * With **no** folder — a machine nobody has set up — it is the first agent
     * session, which is what this rule has always answered and is the behaviour
     * a machine keeps until somebody sets it up.
     *
     * One reading of it, used by the landing, by both cards on this screen and by
     * `CopilotControlView`, so none of them can come to disagree about which
     * session the copilot is.
     */
    static func copilotSession(in sessions: [RemoteSession], folder: String?) -> RemoteSession? {
        let agents = agentSessions(sessions)
        guard let folder, !folder.isEmpty else { return agents.first }
        return agents.first { CopilotSetupBook.sameFolder($0.cwd, folder) }
    }

    /**
     * Every session on this machine with an agent listening in it, in the order
     * the machine listed them.
     *
     * The filter is the rule and `copilotSession` is the one reading of it
     * anybody uses, so `land()` and the *Open* row cannot come to disagree about
     * what
     * counts as a copilot session — the failure a second copy of this predicate
     * produces is a tab that lands in one conversation while the row underneath
     * offers another.
     *
     * The machine's own order rather than a sort. It is the order the session
     * list on the Sessions tab shows, and re-sorting would put the same
     * machine's sessions in two orders on two screens, which reads as two
     * different lists of two different things.
     */
    static func agentSessions(_ sessions: [RemoteSession]) -> [RemoteSession] {
        sessions.filter { $0.status != "exited" && !$0.provider.isEmpty && $0.provider != "shell" }
    }

    /// What the Copilot tab should do with somebody who has just opened it.
    enum Landing: Equatable {
        /// Land in this session, and do it now.
        case open(String)
        /**
         * Start one, and land in what comes back.
         *
         * **This case did not exist, and the argument against it is worth
         * keeping.** A session on a server runs a real agent and spends real
         * money; the Copilot pill is drawn unconditionally on a headless host,
         * so the tab is one mis-tap away at all times; and nothing here undoes a
         * spawn. Every word of that is still true, and what answers it is not a
         * gate but two other properties: one attempt per visit, and a folder
         * that is written down rather than guessed.
         *
         * **`nil` is the machine's own folder, and it is not a missing value.**
         * It was non-optional for one round, on the argument that an automatic
         * start with no folder is one nobody would know the location of. That
         * argument is answered rather than overridden: `CopilotOnServerView`
         * records the `cwd` of the session it lands in the moment it lands, so
         * the folder is on the control screen — with a picker beside it — before
         * anybody could ask where it went. What it buys is his actual
         * requirement, that the tab *"directly land into some session — not to a
         * selection and something on the page."*
         */
        case start(folder: String?)
        /// Nothing to do. The screen draws what little it has and waits.
        case stay
    }

    /**
     * Where the Copilot tab should land, and what it should make to land in.
     *
     * > *"When we go to copilot it should just start the session; if there is
     * > already an existing session it should start from there where we left,
     * > and if not then it should create itself and start from the beginning. I
     * > told the exact same also before."*
     *
     * Read as written, that sentence has **no branch in it for asking**. So the
     * shape below is: land if you can, start if you cannot, and only answer
     * `.stay` for a reason that is about the machine or about a decision
     * somebody made — never because this app has not been told something.
     *
     * The guards, in order, and what each one is:
     *
     *  - **Already landed**, or **not connected**. A one-shot per navigation
     *    stack, so coming back out of the conversation does not re-push it on the
     *    next frame and make this screen unreachable; and a pushed terminal
     *    cannot attach over a dead socket, so a landing over one would be a chat
     *    with no way back to the terminal. Neither is a refusal — both resolve by
     *    themselves.
     *  - **A copilot session exists** — *"if there is already an existing session
     *    it should start from there where we left."* Which session that is
     *    depends on the folder; see `copilotSession`.
     *  - **This machine can start one, and this visit has not tried.** The second
     *    is the loop guard: `land()` runs on every change of a key that includes
     *    the session list and the connection, so a start that produced nothing
     *    would otherwise be re-sent on every redraw for as long as somebody stood
     *    on the screen.
     *  - **The tab has not been quietened.** `isArmed` reads an absent record as
     *    yes — that is the whole of the correction — so this only stops a machine
     *    whose switch somebody deliberately moved.
     *  - **A folder, if one is known.** With one recorded, that is where it
     *    starts. With none, `nil` lets the machine choose and the folder is
     *    written down on arrival.
     *
     * The last guard is the narrow one and it is not a policy: `plainStartTaken`
     * is false when the machine's grant list is **present and empty**, which is a
     * person having chosen to share nothing with this device. `create` with no
     * folder is refused every time in that state — `CopilotOnServer.start` and
     * `SessionListView`'s empty state both already keep this rule — so starting
     * anyway would be one refusal per visit forever. That is the single case
     * where the screen still shows a row, and it shows the *one* row that works.
     */
    static func landing(in sessions: [RemoteSession],
                        connection: ConnectionState,
                        setup: CopilotSetupBook.Setup?,
                        already: Bool,
                        attempted: Bool,
                        canStart: Bool,
                        plainStartTaken: Bool) -> Landing {
        guard !already, connection.isLive else { return .stay }
        if let running = copilotSession(in: sessions, folder: setup?.folder) {
            return .open(running.id)
        }
        guard canStart, !attempted else { return .stay }
        guard setup?.startOnOpen ?? true else { return .stay }
        if let folder = setup?.folder, !folder.isEmpty { return .start(folder: folder) }
        guard plainStartTaken else { return .stay }
        return .start(folder: nil)
    }

    /**
     * How long an automatic start is given before this screen says something.
     *
     * `create` has no answer frame of its own — a session arriving in the list is
     * the answer — so there is nothing to time out on the wire, and the honest
     * thing this end can do is stop claiming to be starting something. Thirty
     * seconds is comfortably longer than a `spawn` and a first prompt on a small
     * rented box, and comfortably shorter than the point somebody decides the app
     * is broken. The same shape of number `ServerSettingsLink.applyTimeout` uses,
     * and for the same reason.
     */
    static let startSeconds: TimeInterval = 30

    /**
     * How many times the tab will ask the stack to open the conversation.
     *
     * Eight, over about a second and a half. Not a poll and not a timeout: every
     * attempt after the first exists only because SwiftUI discarded the last
     * one, which it does while the tab is transitioning on screen and never
     * after. In practice the second attempt is the one that lands; the rest are
     * headroom for a cold first frame on a slower phone than the one this was
     * measured on.
     */
    static let landingTries = 8

    /// What the screen says while a `create` is in flight. Two sentences because
    /// there are two facts: with a folder recorded it can name where; on a first
    /// visit it genuinely does not know yet, and saying so is better than naming
    /// a folder this end has not been told.
    static func startingLine(folder: String?) -> String {
        guard let folder, !folder.isEmpty else { return "Starting a session\u{2026}" }
        return "Starting it in \(SessionDetails.folderName(folder))\u{2026}"
    }

    /// What a start that produced nothing is called. Deliberately not *failed*:
    /// nothing here knows that it failed, only that the session has not appeared,
    /// and it may yet. What it does know is that this screen will not try again
    /// on its own, which is the part somebody needs to be told.
    static func startNeverLanded(noun: String) -> String {
        "That \(noun) has not started a session yet. Nothing else will be sent — press to try again."
    }

    /**
     * What a fresh session will have in it, in the server's own vocabulary, or
     * nil when the server has not said.
     *
     * `shell` is answered rather than dropped: a server whose default is a plain
     * shell has said something true and useful, and a Start row that quietly
     * fell back to a vaguer sentence there would be hiding the one case where
     * *"start the copilot"* is not what the button does.
     */
    static func agentSentence(provider: String?) -> String? {
        guard let provider, !provider.isEmpty else { return nil }
        // No chat is promised for a shell. Chat mode needs a transcript and a
        // bare prompt has none, so `TerminalScreen` keeps its mode button off
        // there and a person who pressed this lands in the terminal — the right
        // screen for a shell, and the wrong thing to have promised a chat about.
        if provider == "shell" { return "Starts a plain shell — no agent, no chat." }
        return "Starts \(ServerSettingsText.providerLabel(provider)) and opens the chat."
    }

    /**
     * The one line this screen says about the wire, or nil for silence.
     *
     * Two guards, and the second is not redundant. `showing` is
     * `ConnectionNotice`'s graced answer and carries the five seconds; the check
     * on the state itself is what stops a notice that has not been recomputed
     * yet from drawing an outage over a connection that is already back. The
     * notice is driven by a timer, so there is a frame where it can be stale,
     * and this screen's whole claim is that it does not say things that are no
     * longer true.
     */
    static func wireLine(_ state: ConnectionState, showing: Bool) -> String? {
        guard showing else { return nil }
        guard !(state.isLive && state.verified) else { return nil }
        return state.detail
    }

    /**
     * Why a press did not do anything, said in terms of what is actually wrong.
     *
     * `ConnectionState.detail` is *"always present, always true"* by its own
     * contract, so an unreachable machine explains itself. The live case is the
     * narrow one: the socket is up and the machine still refused, which for the
     * rows this screen draws means the folders were taken back at the machine
     * between the frame being drawn and the finger landing.
     */
    static func refusal(_ state: ConnectionState, noun: String) -> String {
        state.isLive
            ? "That \(noun) is not sharing a folder with this phone any more."
            : state.detail
    }
}
