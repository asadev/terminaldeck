/**
 * The browser window a session is holding, brought to the session — over the
 * terminal, and foldable out of the way without letting go of anything.
 *
 * ## What was asked for
 *
 * Asad, photographing a live page streaming from his server onto a phone, the
 * page across the top third and four hundred points of black underneath it:
 *
 * > *"Let's give terminal here in black area available down here, to watch what
 * > the session is doing — or keep it in both ways. Maybe in the browser side we
 * > can see the window… But generally, whenever we are talking to terminal,
 * > terminal will directly open it up in there inside the session — I mean it
 * > will show it, or like bring another window up there and show how it is
 * > working on it and all of this, and the person can just minimize it from some
 * > button and it will go back to the browser page. And they can just see, okay
 * > Claude is working on this page and that, and Claude can ask for the input to
 * > put password and put email and then he can continue… it can just quickly pop
 * > up this browser window inside the terminal and the other person can just put
 * > his details, log in and stuff, and then it will fold back and then it can
 * > keep going and continue the process. Something like that — just like the way
 * > we have in desktop site."*
 *
 * Two halves that turn out to be one surface. *The terminal in the black area*
 * and *the page inside the session* are the same picture read from opposite
 * ends: a page across the top, the session underneath it. This file is that
 * picture, and it lives on the session screen for a reason that is not a
 * preference — see below.
 *
 * ## Why the composite lives here and not on the Browser tab
 *
 * The terminal is a **single `UIView`**. `TerminalBridge.container` is built once
 * per session and `TerminalHostView.makeUIView` hands that same view back to
 * whoever asks, so a second screen mounting it does not get a copy — it takes it,
 * out of the first screen's hierarchy, and the first screen has no way to notice
 * or to ask for it back (its `makeUIView` has already run and will not run
 * again). One session, one emulator, one place it can be drawn.
 *
 * So the page goes to the terminal rather than the terminal going to the page,
 * and the Browser tab's window screen — which cannot mount an emulator — gets the
 * other thing it can honestly offer: it says which session holds the window and
 * takes you there in one tap. `MachineWindowView` carries that half and the
 * argument for it.
 *
 * ## There is no letterbox left to fill
 *
 * The black area is not decorated, it is **deleted**. `WatchStage` reports the
 * height the picture is actually drawn at (`WatchSurface.onPageHeight`) and this
 * view sizes the canvas to exactly that, so the page ends where the page ends and
 * the terminal starts on the next point down. A 1280×800 page on a 393-point
 * phone is 246 points tall; before this it was 246 points of page inside a
 * seven-hundred-point black box.
 *
 * The trade is one extra layout pass on open — the canvas is handed a generous
 * box, reports its real height, and is handed that instead — and one `resize` on
 * the wire, because the terminal genuinely does have fewer rows now. Both are
 * what a split is.
 *
 * ## What makes it come up on its own, and what could not
 *
 * *"Whenever we are talking to terminal, terminal will directly open it up in
 * there."* The trigger is **a window becoming bound to this session**, which is a
 * real act by a real agent (`browser.window.bind`, or a session's own
 * `browser.open`) and not a heuristic. It opens once per window; minimising it
 * records that window id, so it never fights somebody who has put it away.
 *
 * The phone hears about it, and the frame that tells it is not the obvious one.
 * `browser.window.rows` — the list this pane reads the binding off — is **only
 * ever an answer**: it is built in `remote/browser-control.ts` and sent from the
 * single request dispatch in `remote/server.ts`, and there is no fan-out for it
 * beside `tellSessions`, `tellSurfaces` and `tellRoster`. So a window attached to
 * a session on the machine changes nothing this phone is holding.
 *
 * What *is* pushed on that same event is `browser.surfaces.rows`. Every binding
 * change runs `publish()`, and both `main/index.ts` and `headless/host.ts`
 * subscribe to it with `remote.server.surfacesChanged()` — deliberately outside
 * the set-moved gate the `window.holds` announcements sit behind, so a
 * navigation gets one too. `WatchLink.receive` already takes an unsolicited
 * strip without matching a rid.
 *
 * So the strip changing is the event, and `browser.windows` is the one small
 * question asked when it does: *the machine's browser moved — is one of those
 * windows mine now?* No timer and no poll: *"events, not polling — they make the
 * system heavier."* Two cheaper events are hung off the same answer for the cases
 * the strip cannot cover — the screen appearing, and the socket coming back,
 * after which nothing has been replayed.
 *
 * One gate is worth knowing about: `tellSurfaces` is refused to a connection that
 * may not watch, so on a machine that offers no cast this pane is told nothing
 * and asks nothing. That is the right shape — there would be no picture to open.
 *
 * ## *"Claude can ask for the input"* — the half that had no answer
 *
 * `browser.handover` is the agent saying *I need a person for this one*: a login
 * wall, a two-factor code, a card number. Every step of it was written for
 * somebody already holding the mouse. It curtains the cast, so every watcher
 * gets `masked: true` with the agent's sentence and **no pixels**, and input is
 * refused at the source — *"the person has this page right now"*, said to the
 * person. The one surface that could answer was the only one told it may not.
 *
 * Three frames close that, and this pane is where they are drawn:
 *
 *  - `browser.handover.state` — host→client, an answer and **also a push** to
 *    every connection watching that window when the state moves. `asking` is
 *    whether a person is being waited on; `prompt` is the agent's own sentence;
 *    `mine` is the one per-connection field, because *whether I may type* is not
 *    a property of the page.
 *  - `browser.handover.take` — this phone saying *that person is me*. It does
 *    not weaken the curtain and does not move the baton off `human`: every agent
 *    command stays refused and every **other** watcher stays curtained. What
 *    changes is scoped to this connection, so the pixels arrive unmasked and the
 *    taps are dispatched — which is why nothing in the canvas or the input path
 *    below had to change at all. `WatchSurfaceUIView` already refuses a masked
 *    frame and already drives an unmasked one; the claim is what decides which
 *    of the two this device is sent.
 *  - `browser.handover.done` — hand it back, and say which of the two things
 *    that means. **Done, carry on** returns the baton and the agent's blocked
 *    call resolves; **Stop — I'll take over** ends the drive. They are two
 *    buttons that say those two things, not a button and a cancel, because they
 *    end in two different places and a person choosing between them is choosing
 *    between two outcomes rather than between doing a thing and not doing it.
 *    (The desktop's own wording for the second is *"I'll take it from here"*;
 *    it is four words shorter here because two primary-width buttons on a
 *    393-point phone clipped it — see `handoverBar`.)
 *
 * **The second phone.** Two devices can watch one window and only one can be
 * holding it, so the frame carries two booleans rather than one: `mine` is
 * whether *this* connection holds it and `taken` is whether **anybody** does.
 * Together they are three states and no inference — claimable, yours, somebody
 * else's. `taken` was not on the frame when this pane was first built; it was
 * derived here from the shape of the pushes, which worked and was still the
 * wrong thing to ship, because a state this end had guessed at was the only
 * thing standing between a blocked agent and the person who could unblock it.
 * A device that is not holding the page and is looking at one that is taken
 * gets a sentence and no control at all.
 *
 * ## Folding, while somebody is being waited on
 *
 * The bar sits **outside** the part that folds — between the strip and the
 * canvas, so a fold takes the picture to zero height and leaves the question,
 * the agent's sentence and the buttons exactly where they were. That is the
 * whole of *"a handover in progress must not be silently foldable into
 * invisibility"*, and it is worth being clear that the alternative — refusing to
 * fold at all while a handover is outstanding — was rejected for a specific
 * reason: **the thing the person needs to type is often in the terminal.** A
 * two-factor code the agent has just printed, a token from a previous step, the
 * email address the session was started with. A pane that pinned the page open
 * would be a pane that hides the answer to its own question.
 *
 * Two moves do open it on their own, and only two: the question **arriving**,
 * and this device **taking** it. The first is the one interruption this feature
 * is allowed — the agent has stopped and is waiting, which is not the same as a
 * surface reopening itself over a conversation somebody is reading. The second
 * is not an interruption at all: a page you have just claimed and cannot see is
 * a claim that cannot be answered.
 *
 * **Leaving the screen does not hand it back.** There is no `done` on
 * `onDisappear`, because both of the things `done` can mean are answers, and
 * walking away is not one of them — sending *carry on* would tell the agent the
 * login was finished and sending *stop* would kill the drive. What the wire does
 * carry is the connection: a phone that goes away takes its grant with it, which
 * is the host's business and not a sentence this end should be inventing.
 *
 * ## Minimise does not stop anything
 *
 * *"The person can just minimize it… and then it will fold back and then it can
 * keep going."* Folding is about what is on his screen and nothing else: the
 * window stays open, the binding stays, the agent carries on, **and the cast keeps
 * running** — the canvas stays mounted at zero height rather than being taken out
 * of the hierarchy, because `dismantleUIView` is what sends `browser.unwatch`.
 * That costs frames for a picture nobody is looking at, and it buys the thing the
 * fold is for: reopening is instant and already showing the page as it is now,
 * rather than a second of nothing while a screencast is renegotiated. The bytes
 * are bounded either way by the one-un-acked-frame backpressure the host holds.
 *
 * ## Folding is ours. The cast is not, and that is what came apart
 *
 * > *"When we are inside here to a terminal where we have the window. So if we
 * > close it, we cannot open it. If I click on it, it is not opening. So this
 * > should be working properly, so I can at least open it. Here chat is working,
 * > but other one, when the situation is different, then it is not working."*
 *
 * Photographed: the strip drawn with the globe and the chevron pointing **down**
 * — so the pane is `.split` and believes it is showing something — and nothing
 * underneath it. Pressing the chevron did nothing he could see, and the label
 * beside it went on offering to *fold the page away* over an empty space.
 *
 * The fold was never the broken half. What came apart is that **this pane owns
 * the fold and does not own the cast**: `WatchLink` holds one frame sink, one
 * connection is one `watcherId` on the host, and three screens can mount a
 * canvas. The walk that produces the photograph is looking at the same window on
 * the Browser tab and coming back. `MachineWindowView` mounts its own canvas,
 * which adopts the sink; leaving that tab dismantles it, and
 * `WatchSurfaceUIView.tearDown` then does two unconditional things — it sends
 * `browser.unwatch` for the window, which is this phone's only watcher and so
 * stops the cast outright, and, being the sink's owner, it sets the sink to nil.
 * This pane's canvas never moved: its `didMoveToWindow` has already fired and
 * its width has not changed, so nothing calls `startWatching` again and nothing
 * re-adopts. It is mounted, on screen, blind, and the machine has been told to
 * stop. Leaving the session and coming back rebuilt it and hid the whole thing,
 * which is exactly the walk he should not have had to find.
 *
 * `show()` used to be two lines that moved `pane` back to `.split`. Against a
 * cast that is over that is a state change and nothing else — which is precisely
 * *"if I click on it, it is not opening."*
 *
 * Three things changed, and none of them touch what folding means:
 *
 *  - **Showing asks.** `show()` re-reads both lists and, when nothing is
 *    arriving for this window, rebuilds the canvas. A rebuilt canvas re-adopts
 *    the sink and asks for the cast again, which is the only way back from
 *    either half of the failure. A page that *is* arriving is left alone, so an
 *    ordinary unfold is still instant.
 *  - **The verb says what pressing it will do.** `SessionPageVerb` is the whole
 *    of it: a fold is offered only while a picture is really arriving, a pane
 *    that is shown and empty offers *ask for it again* instead, and a machine
 *    that will not cast at all offers nothing and lets the sentence under the
 *    strip be the answer.
 *  - **The canvas is identified by the window it is showing.**
 *    `WatchSurfaceUIView.target` is a `let` fixed at `init`, and SwiftUI updates
 *    a representable in place rather than rebuilding it — so a session whose
 *    binding moved to a **different** window kept a canvas casting the old one
 *    and dropping every frame for the new one, under a strip naming the new one.
 *    This is the one mount whose surface can change under it; the other two are
 *    handed a fixed window by the screen that pushed them.
 *
 * ## A session holding no window shows nothing at all — and that took two goes
 *
 * > *"There is also no way to connect a browser window to this specific session,
 * > if you can see."*
 *
 * That was true, and the first answer to it was a bar drawn across the top of
 * every session that held no window: *Attach a browser window*, with the
 * machine's open windows behind it. He filmed the result and it is the opposite
 * complaint:
 *
 * > *"So now if I enter into any session, this comes here that on top the attach
 * > window is coming. If it is not connected to anyone, so it should stay clean.
 * > Even if I go to Copilot, which has no browser window attached, it is also
 * > showing something attached. If something is attached, then we can open it
 * > here also, so which doesn't make any sense because it does not have anything
 * > to do with this specific browser. It is not even linked to it."*
 *
 * Both halves of that are right. The bar was on **every** session on the machine
 * at once, because the list behind it is the **machine's** and nothing about it
 * is this session's — so it read as a claim about this session and was a claim
 * about the browser. And it was drawn on the Copilot tab too, which renders this
 * same screen, over a conversation that has never had a page in it.
 *
 * So the bar is deleted. This pane draws the window a session **holds** and
 * nothing else, ever: a strip when there is one, and no height at all when there
 * is not.
 *
 * **Nothing was lost with it.** The verb it pressed — `HostLink.bindMachineWindow`
 * — is now on the two `…` menus somebody already opens to act on a session: the
 * session row's on the Sessions tab (`SessionListView`) and the session's own
 * inside the terminal (`TerminalScreen`). Both build their list through
 * `SessionWindowPicker` below, so the three screens that can attach a window
 * cannot come to say different things about the same one. The difference is that
 * a menu is opened by somebody who wants it, and a bar is drawn at somebody who
 * did not ask.
 */

import SwiftUI

/// How much of the session screen the page has.
enum SessionPagePane: Equatable {
    /// A strip and nothing else. The cast is still running; see the file header.
    case minimised
    /// The page at its own height, the terminal underneath it.
    case split
    /**
     * The page having the whole screen. **Nothing produces this any more.**
     *
     * > *"This button is like not working the way I was expecting. This is
     * > something else. We do not need actually this part. We do not need this
     * > to be coming down like with black page."*
     *
     * The verb that set it is deleted — see `strip` — so the pane is only ever
     * `.split` or `.minimised`. The case is kept rather than removed because
     * `TerminalScreen` decides whether to draw the terminal at all from
     * `pagePane != .full`; with nothing able to reach this, that test is always
     * true, the terminal is always underneath the page, and there is no black
     * left for a fold to expose.
     */
    case full
}

struct SessionPageView: View {
    let model: DeckModel
    let hostID: String
    let sessionID: String

    /**
     * Whether the session screen holding this is the one being looked at.
     *
     * Passed in rather than worked out here, because `TerminalScreen.frontmost`
     * already knows — it is the property that exists because *"switching back to
     * a tab whose stack already has a screen on it fires nothing."* It gates the
     * canvas, not the strip: see `WatchStage.mounted` for why two canvases on two
     * tabs is a defect rather than a waste.
     */
    let frontmost: Bool

    /// How much room the page has, owned by the screen so the terminal under it
    /// can be laid out against the same number.
    @Binding var pane: SessionPagePane

    /// The window this pane has already offered, so it is offered once. Nil until
    /// something has been shown.
    @State private var shown: String?
    /// The window that was put away by hand. It does not come back on its own —
    /// a surface that reopens itself over a conversation somebody is reading is
    /// the interruption this feature has to avoid being.
    @State private var folded: String?
    /// The height the canvas says the picture is. Zero until the first frame, and
    /// `stageHeight` hands out the generous box in the meantime so the fit lands
    /// on the width rather than on the guess.
    @State private var pageHeight: CGFloat = 0

    /**
     * Bumped to build a new canvas, and joined with the surface name to identify
     * the one on screen.
     *
     * Both reasons are in the file header. A canvas is the only thing that can
     * re-adopt `WatchLink.frameHandler` and the only thing that asks for a cast,
     * so *ask for the page again* has to be a rebuild rather than a frame — and
     * `WatchSurfaceUIView.target` is fixed at `init`, so a surface that changes
     * name under a live canvas has to be a rebuild too.
     *
     * Safe in either order SwiftUI does it in. Building the new canvas first
     * leaves the old one no longer the sink's owner, so its `tearDown` keeps its
     * hands off the sink, and its `browser.unwatch` still lands before the new
     * canvas's `browser.watch`: a freshly made `UIView` has zero bounds when
     * `didMoveToWindow` fires, so `startWatching` no-ops there and sends from the
     * layout pass instead, which is after the update the old one was dismantled
     * in. Dismantling first is the trivial order and needs no argument.
     */
    @State private var recastToken = 0

    private var host: HostLink? { model.host(hostID) }

    /// The window bound to this session, if the machine has said there is one.
    /// Derived on every redraw rather than captured: `browser.window.rows` is the
    /// whole list each time, and a value held from an earlier answer would go on
    /// naming a window that had been closed or rebound.
    private var window: MachineWindow? {
        host?.machineBrowser?.windows.first { $0.session == sessionID }
    }

    /// The cast of that window, when the machine is offering one. A window can
    /// exist and not be castable — a server lists a window opened from the
    /// phone's own `+` under `browser.window.rows` and not under
    /// `browser.surfaces` — and the strip is drawn either way, because knowing
    /// which page the agent is on is worth saying even with no picture.
    private var surface: BrowserSurfaceRow? {
        guard model.connection.isLive, host?.watch.offered == true, let id = window?.id else { return nil }
        return host?.watch.surfaces.first { $0.window == id }
    }

    /**
     * Whether a picture is actually arriving for this pane right now.
     *
     * Not *is there a row for it* — that is `surface`, and a row is exactly what
     * was still true in the photograph with nothing under the strip. This is the
     * pair of facts a frame has to get through to reach the screen: a
     * `browser.watch` of ours still standing, and a canvas registered to draw
     * what comes back. `WatchLink.isCasting` holds both, and says why neither is
     * enough on its own.
     */
    private var showing: Bool {
        guard let page = surface?.window else { return false }
        return host?.watch.isCasting(page) == true
    }

    /// Whether a cast could be had at all: a live connection to a machine that
    /// offers its browser for watching. Nothing on this strip may offer an act
    /// that would be dropped at the door.
    private var castable: Bool {
        model.connection.isLive && host?.watch.offered == true
    }

    /// The one thing the strip offers, out of the three facts that decide it.
    /// See `SessionPageVerb`.
    private var verb: SessionPageVerb {
        SessionPageVerb.verb(folded: pane == .minimised, showing: showing, castable: castable)
    }

    /**
     * The handover outstanding on the page this pane is showing, if there is
     * one.
     *
     * Keyed off the **surface** rather than the window, because that is the name
     * the watch wire uses for this page and the name a `take` has to be
     * addressed by. No surface means this machine is not casting the window,
     * which also means nothing here could be claimed: the far end refuses a
     * claim from a connection that may not already watch, and a bar offering one
     * would be a control that cannot act.
     */
    private var handover: BrowserHandover? {
        guard let page = surface?.window else { return nil }
        return host?.watch.handover(page)
    }

    var body: some View {
        Group {
            if let window {
                pageStack(window)
            } else {
                /*
                 * Nothing at all, taking no height, **always** — not only on a
                 * machine with no window to give.
                 *
                 * > *"If it is not connected to anyone, so it should stay clean.
                 * > Even if I go to Copilot, which has no browser window
                 * > attached, it is also showing something attached."*
                 *
                 * There was a second branch here that drew an attach bar over any
                 * session while the machine had windows open. It is deleted; the
                 * file header has the whole argument and where the verb went.
                 *
                 * The view stays in the tree at zero height rather than being
                 * removed, because the reads below are what notice a window
                 * becoming this session's — a pane that unmounted itself when
                 * there was nothing to draw would be a pane that never found out
                 * there was.
                 */
                Color.clear.frame(height: 0)
            }
        }
        .onAppear {
            reread()
            // The list may already be here — `HostLink` keeps the last answer for
            // the machine — and `onChange` does not fire for a value that was
            // already set. Without this, arriving at a session that has held a
            // window all along would show the strip and never offer the page.
            offer(window?.id)
        }
        // The socket coming back. The window list is not replayed on reconnect,
        // so this is the only thing that would notice a window bound while the
        // phone was away.
        .onChange(of: model.connection.isLive) { _, live in if live { reread() } }
        /*
         * **The machine's browser moved.**
         *
         * `browser.surfaces.rows` is pushed unsolicited on every binding change
         * and every navigation — see the file header for the two subscriptions
         * that do it — and it is the only frame on this wire that says so. It
         * carries no session, so it cannot answer *whose* window this is; what it
         * can do is say that the answer has changed, which is exactly when the
         * one small `browser.windows` question is worth asking.
         *
         * Only the windows are asked for here, never the strip: asking for the
         * strip in answer to the strip arriving is a loop, and the strip is
         * already the freshest thing this phone holds.
         */
        .onChange(of: host?.watch.surfaces) { _, _ in host?.readMachineWindows() }
        .onChange(of: window?.id) { _, id in offer(id) }
        /*
         * **The agent has stopped and is waiting for a person, or this device
         * has just taken it.**
         *
         * The only two moves that open a folded pane by themselves, and each is
         * argued in the file header. Transitions rather than states — `asking`
         * that was already true when this screen appeared does not re-open a
         * page somebody has deliberately put away a second time, because the bar
         * is on screen either way and nothing is hidden by leaving the fold
         * alone.
         */
        .onChange(of: handover) { was, now in
            /*
             * **The page stopped being this device's.**
             *
             * Handed back either way, or taken away — and the keyboard has to go
             * with it. It does not go on its own: the canvas holds the responder
             * until something tells it not to, so after a hand-back the system
             * keyboard stayed up over a page that had just been curtained again. Half a phone screen
             * offering to type into something that refuses every keystroke at
             * the source. Photographed on the harness run; it is the one of the
             * four defects that is a stale grant rather than a layout.
             *
             * Checked before the opening rules below, because losing the page is
             * not a reason to open anything.
             */
            if SessionHandover.lostThePage(was: was, now: now) { stopTyping() }

            guard let now else { return }
            let arrived = now.asking && was?.asking != true
            let taken = now.mine && was?.mine != true
            guard arrived || taken, pane == .minimised else { return }
            show()
        }
        .onDisappear { stopTyping() }
    }

    // MARK: - The pane

    @ViewBuilder
    private func pageStack(_ window: MachineWindow) -> some View {
        VStack(spacing: 0) {
            strip(window)
            // Above the canvas and outside it, which is what makes a fold unable
            // to hide it — see the file header. `stage` is the only thing whose
            // height the pane changes.
            if let handover, let page = surface?.window {
                handoverBar(handover, page: page)
            }
            stage
            Rectangle()
                .fill(Theme.hairline)
                .frame(height: 0.5)
        }
    }

    /**
     * The canvas, at the height the picture actually needs.
     *
     * Kept in the hierarchy while minimised — at zero height — because taking it
     * out is what sends `browser.unwatch`, and folding must not stop the cast.
     * `WatchSurfaceUIView.startWatching` guards on the **width**, which a height
     * of zero does not change, so nothing is renegotiated on the way down or on
     * the way back up.
     */
    @ViewBuilder
    private var stage: some View {
        if let watch = host?.watch, let surface {
            WatchStage(watch: watch,
                       window: surface.window,
                       mounted: frontmost,
                       onPageHeight: { pageHeight = $0 },
                       // This screen has the bar, so the card must not print the
                       // agent's sentence a second time — measured on a 393-point
                       // phone, where the two of them between them were most of
                       // the screen. Only while there is a bar: a curtain raised
                       // by a password box with no question behind it still gets
                       // the whole sentence, because there is nothing else to
                       // read it from.
                       sentenceIsDrawnAbove: handover != nil)
                // The canvas's identity, which is a correctness thing and not a
                // hint — see `recastToken`. The surface name is in it because
                // `WatchSurfaceUIView` fixes its target at `init` and this is the
                // one mount whose surface can change under it; the token is in it
                // because rebuilding is how a stopped cast is asked for again.
                .id("\(surface.window)#\(recastToken)")
                .frame(height: stageHeight)
                .clipped()
                .accessibilityIdentifier("session.page.stage")
        } else if pane != .minimised || verb == .nothing {
            /*
             * A window this machine will not cast. Not an error and not rare: a
             * server mints a window through `openForSession(NO_SESSION)` and
             * detaches it in the same breath, so it holds no binding row and
             * `castWindows` cannot see it. The strip above still names the page
             * the agent is on, which is the part worth knowing; this says why
             * there is no picture rather than leaving a black box that looks
             * like a cast that has stalled.
             *
             * Drawn through a fold as well when there is no verb, because then
             * there is nothing to unfold *to* and no control to unfold it with: a
             * strip alone over a machine that will not cast is a person left with
             * a header and no way to find out why. Everywhere else a fold still
             * takes this away with everything else.
             */
            Text(host?.watch.offered == true
                 ? "This machine is not casting that window."
                 : "This machine does not offer its browser for watching.")
                .font(.system(size: 13))
                .foregroundStyle(Theme.faint)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
                .padding(.vertical, 18)
                .frame(maxWidth: .infinity)
                .accessibilityIdentifier("session.page.nocast")
        }
    }

    /// How tall the canvas is drawn. Zero folds it away without unmounting it;
    /// otherwise it is the page's own height, capped so the terminal never
    /// disappears by accident under a very tall page. `.full` is unreachable —
    /// see `SessionPagePane` — and is answered with the same height rather than
    /// with the screen, so that even an impossible pane cannot bring the black
    /// area back.
    private var stageHeight: CGFloat? {
        switch pane {
        case .minimised: return 0
        case .split, .full: return pageHeight > 0 ? min(pageHeight, SessionPageRoom.splitCap) : SessionPageRoom.splitCap
        }
    }

    // MARK: - The strip

    /**
     * Who is on screen, and the one thing that can be done about it.
     *
     * > *"Only this drop-down is required, like which can bring it to this state
     * > with the back panel, but this black area thing is not required. So just
     * > keep it simple."*
     *
     * There were three verbs here and two of them are gone. The **expand** put
     * the pane in `.full`, which took the terminal off the screen and left the
     * page sitting on the black area he was pointing at — *"we do not need this
     * to be coming down like with black page."* The **keyboard** raised the
     * system keyboard on the canvas, and the canvas does that itself now on a
     * tap: *"if we just click inside and type from our keyboard, it should work…
     * I should not have to have this separate button of keyboard."* See
     * `WatchSurfaceUIView.onTap`.
     *
     * What is left is the fold, which is the one he asked to keep — and it is no
     * longer drawn as a fold whatever the state underneath it. *"If I click on
     * it, it is not opening."* The chevron said *fold the page away* over an
     * empty space, so the one control on the strip was describing a state rather
     * than an act; `SessionPageVerb` decides which of the three acts is true
     * here, and draws nothing when none of them is.
     */
    private func strip(_ window: MachineWindow) -> some View {
        HStack(spacing: 10) {
            Image(systemName: pane == .minimised ? "macwindow" : "globe")
                .font(.system(size: 15))
                .foregroundStyle(Theme.accent)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 1) {
                Text(window.label.isEmpty ? "Browser window" : window.label)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Theme.primary)
                    .lineLimit(1)
                if let site = MachineBrowserText.site(window.url) {
                    Text(site)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.faint)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            // The whole label is the way back up, which is what a minimised
            // thing on every desktop does. It is not the only way — the button is
            // a real one beside it — so this is a bigger target for the same act
            // rather than a control hidden in a label. It carries whichever of
            // the two *bring the page back* verbs is on offer and never the fold:
            // a page is put away deliberately, with the button.
            .contentShape(Rectangle())
            .onTapGesture {
                switch verb {
                case .show: show()
                case .askAgain: askForThePage()
                case .fold, .nothing: break
                }
            }
            .accessibilityIdentifier("session.page.title")

            /*
             * One identifier for one control, whichever verb it is carrying.
             * `session.page.fold` names the place on the strip rather than the
             * act — it is the only control there has ever been — and the label
             * beside it is what says which act it is, which is also how a test
             * tells them apart.
             */
            switch verb {
            case .show:
                button("Show the page", "chevron.up", id: "session.page.fold") { show() }
            case .fold:
                button("Fold the page away", "chevron.down", id: "session.page.fold") { fold() }
            case .askAgain:
                button("Ask for the page again", "arrow.clockwise", id: "session.page.fold") {
                    askForThePage()
                }
            case .nothing:
                // Nothing. The sentence under the strip says why there is no
                // picture, and a chevron beside it would be a second control that
                // cannot act.
                EmptyView()
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(Theme.surface)
    }

    private func button(_ label: String, _ icon: String,
                        id: String, act: @escaping () -> Void) -> some View {
        Button(action: act) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Theme.accent)
                .frame(width: 34, height: 30)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityIdentifier(id)
    }

    // MARK: - The handover

    /**
     * The agent has stopped and is waiting for a person — and this is the way in.
     *
     * Four states, and each of them is a different sentence rather than the same
     * sentence with a control enabled or disabled:
     *
     *  - **Nobody has answered yet.** The agent's own words, and one button that
     *    says *I'll do it*. This is the whole feature: the person holding the
     *    phone becomes the person the handover was waiting for.
     *  - **This device has it.** The pixels are already live and the taps
     *    already land — nothing here made that happen, the host stopped
     *    curtaining this connection — so what is left is the two ways out, and
     *    they say what they do.
     *  - **Somebody else answered it** — `taken` and not `mine`. A sentence and
     *    no control at all. Not a disabled button and not a demoted one: the
     *    only thing a second device could do from here is reach into a page
     *    somebody is typing a password into, which is precisely what the far end
     *    refuses and what `taken` was added to the frame to prevent.
     *  - **A claim was refused.** The machine's own sentence, and the claim
     *    becomes *Try again* — this end does not know whether the refusal was
     *    permanent, and the likeliest one is a race.
     *
     * Drawn on `Theme.surface` like the strip above it, so the two read as one
     * piece of chrome over the page rather than a banner that has landed on top
     * of it.
     */
    @ViewBuilder
    private func handoverBar(_ state: BrowserHandover, page: String) -> some View {
        let busy = host?.watch.isAwaiting(page) == true
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                Image(systemName: state.mine ? "hand.raised.fill" : "person.badge.key.fill")
                    .font(.system(size: 12))
                Text(SessionHandover.headline(state))
                    .font(.system(size: 12, weight: .semibold))
                    .accessibilityIdentifier("session.page.handover.state")
                Spacer(minLength: 0)
            }
            .foregroundStyle(state.mine ? Theme.positive : Theme.warning)

            if !state.prompt.isEmpty {
                // The agent's own sentence, drawn whole rather than on one line:
                // it is the instruction — *sign in with the account you use for
                // billing* — and a truncated instruction is not one.
                Text(state.prompt)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.primary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("session.page.handover.prompt")
            }

            if let refusal = state.refusal {
                Text(refusal)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.warning)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("session.page.handover.refusal")
            }

            switch SessionHandover.offer(state) {
            case .handBack:
                HStack(spacing: 8) {
                    act("Done — carry on", filled: true, busy: busy,
                        id: "session.page.handover.carryon") {
                        host?.watch.handBack(window: page, carryOn: true)
                    }
                    /*
                     * *"I'll take it from here"* on the desktop, and shortened
                     * here because two primary-width buttons on a 393-point
                     * phone cannot hold that sentence — it shipped clipped to
                     * *"Stop — I'll take it from h…"*, which is a button whose
                     * last word is missing on the one control that ends a drive.
                     * The meaning is what has to survive rather than the
                     * wording, and *take over* is the same meaning in four
                     * fewer words. `minimumScaleFactor` below is the guard for
                     * the narrower phones this still has to fit on.
                     */
                    act("Stop — I'll take over", filled: false, busy: busy,
                        id: "session.page.handover.stop") {
                        host?.watch.handBack(window: page, carryOn: false)
                    }
                }
                /*
                 * There was a line here — *"tap the field on the page, then the
                 * keyboard button above"* — because the app could not raise the
                 * keyboard by itself and the person had to be told the order.
                 * The button it named is gone and the order with it: *"if we just
                 * click inside and type from our keyboard, it should work."*
                 * Tapping the field is now the whole gesture, so the instruction
                 * would be telling somebody to do what they have just done.
                 */
            case .elsewhere:
                // Nothing. The sentence above is the whole answer, and there is
                // deliberately no way from here to reach into a page somebody
                // else is typing a password into.
                EmptyView()
            case .claim, .retry:
                act(SessionHandover.offer(state) == .retry ? "Try again" : "I'll do it",
                    filled: true, busy: busy, id: "session.page.handover.take") {
                    host?.watch.take(window: page)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface)
        .overlay(alignment: .top) {
            Rectangle().fill(Theme.hairline).frame(height: 0.5)
        }
        /*
         * A **container**, and that word is load-bearing.
         *
         * `.accessibilityIdentifier` on a stack is applied to every leaf inside
         * it and *overrides* an identifier the leaf gave itself — so with this
         * modifier alone the bar's own controls all came out of the tree
         * identified `session.page.handover`: the button that answers the
         * handover, the two that hand it back, the headline and the agent's
         * sentence, every one of them, four elements wearing one name.
         *
         * Measured on 2026-08-25, from the accessibility snapshot XCTest
         * collected on a live phone:
         *
         *     Button, …, identifier: 'session.page.handover', label: 'I'll do it'
         *     StaticText, …, identifier: 'session.page.handover', label: 'The agent needs you on this page'
         *
         * So `app.buttons["session.page.handover.take"]` matched nothing while
         * the button was plainly on screen and hittable. Nothing was wrong with
         * the feature and there was no way to drive it from a test.
         *
         * `children: .contain` makes this an accessibility *container* rather
         * than an element: the identifier lands on the container, and each
         * control below keeps the one it declared. Nothing about what VoiceOver
         * reads changes — an identifier is never spoken.
         */
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("session.page.handover")
    }


    /// One button in the bar. `filled` is the answer the person is most likely
    /// to want; `busy` is an answer of ours already in flight, which is the one
    /// state where a second tap would be a second, possibly opposite, reply.
    private func act(_ label: String, filled: Bool, busy: Bool,
                     id: String, run: @escaping () -> Void) -> some View {
        Button(action: run) {
            Text(label)
                .font(.system(size: 13, weight: filled ? .semibold : .medium))
                .lineLimit(2)
                .minimumScaleFactor(0.85)
                .multilineTextAlignment(.center)
                .foregroundStyle(filled ? Theme.onAccent : Theme.accent)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .padding(.horizontal, 10)
                .background(filled ? Theme.accent : Theme.surfaceHigh)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(busy)
        .opacity(busy ? 0.5 : 1)
        .accessibilityIdentifier(id)
    }

    // MARK: - Acts

    /**
     * A window has become this session's, or has stopped being it.
     *
     * Opened once per window id. `folded` is what makes the offer dismissible:
     * putting a page away is remembered against the window it was, so the same
     * page never reappears by itself, and a **different** window — a new page the
     * agent has just attached — is a new fact and is offered again.
     */
    private func offer(_ id: String?) {
        guard let id else {
            shown = nil
            /*
             * Back to `.split`, which is the state a page should arrive in.
             * Nothing is drawn at all while there is no window — the pane takes
             * no height — so this only ever decides how the next one comes up.
             */
            pane = .split
            return
        }
        guard id != shown else { return }
        shown = id
        guard id != folded else { return }
        withAnimation(.easeOut(duration: 0.2)) { pane = .split }
    }

    /**
     * Put the picture away. Nothing else.
     *
     * It does not stop the cast (see the file header), and it does not hand back
     * a handover: the bar is drawn outside the folded part precisely so that
     * folding is about screen room and never about the baton. Somebody who has
     * claimed a login and folds the page to read a code out of the terminal
     * still holds it, still sees the two ways to hand it back, and comes back to
     * the page already showing what it shows now.
     */
    private func fold() {
        stopTyping()
        folded = window?.id
        withAnimation(.easeOut(duration: 0.18)) { pane = .minimised }
    }

    /**
     * Bring the picture back — and make sure there is one to bring.
     *
     * > *"So if we close it, we cannot open it. If I click on it, it is not
     * > opening."*
     *
     * This was two lines that moved `pane`, on the assumption that a surface
     * folded away is a surface still arriving. The file header has the walk that
     * makes that false — one sink, one `watcherId`, three screens that can mount
     * a canvas — and what matters here is that unfolding and asking are one act
     * now, so the chevron can never again be a state change against a dead cast.
     */
    private func show() {
        folded = nil
        withAnimation(.easeOut(duration: 0.18)) { pane = .split }
        askForThePage()
    }

    /**
     * Ask the machine for this page again.
     *
     * Two questions, because *there is no picture* has two shapes and they are
     * answered in different places. `reread()` is for the shape where the window
     * is not in the strip at all: the answer lands, `surface` stops being nil,
     * and the canvas is built for the first time by the ordinary redraw.
     * `recast()` is for the shape where the row is there and nothing is arriving
     * — the cast was stopped, or the sink was taken by a canvas that has since
     * gone — and only a new canvas can undo either of those.
     *
     * A page that **is** arriving is left alone, which is what keeps an ordinary
     * unfold instant: *"reopening is instant and already showing the page as it
     * is now."* Nothing is renegotiated for a picture that is on screen.
     */
    private func askForThePage() {
        reread()
        guard let page = surface?.window, host?.watch.isCasting(page) != true else { return }
        recast()
    }

    /// Build a new canvas for this surface. See `recastToken` for why a rebuild
    /// is the act, and why it is safe in either order SwiftUI does it in.
    private func recast() {
        recastToken += 1
    }

    /**
     * Put the keyboard away, wherever the reason came from.
     *
     * Unconditional now, rather than guarded on a flag this screen used to keep.
     * The keyboard is raised by a tap on the page — *"if we just click inside and
     * type from our keyboard, it should work"* — so this screen is no longer the
     * thing that knows whether one is up, and asking would be answering from a
     * copy. `.endTyping` on a canvas that is not holding it resigns nothing,
     * which is what lets the three callers — the fold, the screen leaving, and
     * the page ceasing to be this device's — say what they mean without checking
     * first.
     *
     * Which leaves the keystrokes where they belong: the page and the terminal
     * below it cannot both be first responder, and tapping the terminal takes it
     * back through `TerminalScreen`'s own `onTapped`.
     */
    private func stopTyping() {
        guard let page = surface?.window else { return }
        WatchStage.post(.endTyping, to: page)
    }

    /**
     * Ask what the machine's browser has open.
     *
     * Both lists, because the two answer different halves and neither is pushed:
     * `browser.window.rows` says which window this session holds, and
     * `browser.surfaces` says whether it can be cast. Each is one small frame and
     * each is refused at the source on a machine that does not offer the
     * capability, so nothing is sent to a machine that would not answer.
     */
    private func reread() {
        host?.readMachineWindows()
        host?.watch.read()
    }
}

/**
 * What the handover bar says and what it offers, from the state alone.
 *
 * Pulled out of the view body rather than written inline, because it is the one
 * decision on this screen that is a decision and not a layout: four states, four
 * different things to draw, and getting it wrong in either direction is a real
 * defect rather than an ugly frame. Offering the claim to a device that cannot
 * have it is a button that will be refused; withholding it from the device that
 * could answer is a blocked agent nobody can unblock. A body is not a place
 * either of those can be pinned; `SessionPageTests` pins them here.
 */
enum SessionHandover {
    /// What the bar offers below the agent's sentence.
    enum Offer: Equatable {
        /// Nobody has answered yet. The primary button — this is the feature.
        case claim
        /// This device asked and the machine said no. The same button, saying
        /// *Try again*, beside the machine's own sentence: this end has no way
        /// to know whether a refusal was permanent, and the likeliest one is a
        /// race.
        case retry
        /// Somebody else answered it. Nothing to press — the far end would
        /// refuse it, and `taken` is a fact from the host rather than a reading
        /// of this end's, so it needs no hedge. There was one while the state
        /// was inferred; it was itself a way for a second person to reach into a
        /// page mid-password, which is the thing `taken` exists to prevent.
        case elsewhere
        /// This device holds it. Two answers, and they say what they do.
        case handBack
    }

    static func offer(_ state: BrowserHandover) -> Offer {
        // `mine` first and unconditionally: a device that holds the page is
        // never offered a way to take it again, whatever else is true of the
        // state — including a refusal left over from before it was granted.
        if state.mine { return .handBack }
        // Then `taken`, which outranks a refusal for the same reason in reverse:
        // if somebody has it, *why this device's last claim failed* is no longer
        // the interesting fact and a `Try again` would be a press that cannot
        // succeed.
        if state.taken { return .elsewhere }
        return state.refusal == nil ? .claim : .retry
    }

    /**
     * The page has stopped being this device's.
     *
     * A rule rather than a comparison, because the case that broke is the one an
     * inline `now.mine == false` misses: handing back **ends the question**, so
     * the next thing this screen sees is not `mine: false`, it is the handover
     * going away entirely. Nil is the ordinary way to lose the page, not the
     * edge case.
     */
    static func lostThePage(was: BrowserHandover?, now: BrowserHandover?) -> Bool {
        was?.mine == true && now?.mine != true
    }

    /// What the bar is about, in the fewest words that are still true. `mine`
    /// first for the same reason: a person holding the page needs to know they
    /// are holding it before they need to know anything else.
    static func headline(_ state: BrowserHandover) -> String {
        switch offer(state) {
        case .handBack: return "You have this page"
        case .elsewhere: return "Another device is answering this"
        case .claim, .retry: return "The agent needs you on this page"
        }
    }
}

/**
 * The windows a session can be handed, and what one row for one says.
 *
 * ## Why this is a type and not two menu bodies
 *
 * > *"here we also don't have anything, like inside here, in the three dots, we
 * > should have the options to click on something, and then all the folders will
 * > come up, maybe here also. So we can connect the browser, whichever browser we
 * > want to connect into the session."*
 *
 * There are now two `…` menus that go and get a window for a session — the
 * session row's on the Sessions tab and the session's own inside the terminal —
 * and this pane, which draws the one it ends up holding. Three screens, one
 * question. The bar these replaced was a fourth, written inline, and the wording
 * on it had **already** drifted from the Browser tab's: it named the window and
 * its owner where the other named the session and its window count. Nobody could
 * see that, because the two are never on screen together.
 *
 * So the decisions live here: which windows may be offered at all, whether a row
 * is the one this session already holds, and what the row says. Each is a
 * sentence or a rule rather than a layout, and `SessionPageTests` pins all three
 * without a simulator.
 *
 * ## Everything the machine has open, minus nothing
 *
 * A window another session holds is still one this session can be handed — the
 * rule the Browser tab's own menu already follows, where the row reads *"Attach
 * to another session"* rather than refusing. What that means in practice is that
 * attaching **moves** it, and silently, so the row has to say who has it now.
 * That is the whole of `row(_:session:)`: a name, and the holder after it when
 * somebody else is the holder.
 *
 * Empty on a machine that will not be driven, so the section is **absent** rather
 * than drawn dead — this app's standing rule for a control that could only ever
 * be refused.
 */
enum SessionWindowPicker {

    /// What a nameless window is called. A machine mints a window before it has
    /// a page, so `label` really can be empty, and a menu row with no words on it
    /// is a row nobody can decide about.
    static let unnamed = "Browser window"

    /**
     * The windows this session could be given.
     *
     * `windows` is nil until a `browser.window.rows` has landed — *not asked
     * yet*, which reads the same here as *nothing open*, because in both cases
     * there is nothing honest to offer.
     */
    static func attachable(_ windows: [MachineWindow]?, canDrive: Bool) -> [MachineWindow] {
        guard canDrive else { return [] }
        return windows ?? []
    }

    /// Whether this is the window the session already holds. It is drawn with a
    /// checkmark rather than left out: a picker that hides the current answer is
    /// one somebody presses again to find out.
    static func holds(_ window: MachineWindow, session: String) -> Bool {
        window.session == session
    }

    /// Who has it **other than this session**, when somebody does. Nil for a
    /// window this session already holds, because "· this session" beside a
    /// checkmark is the same fact said twice.
    static func holder(_ window: MachineWindow, session: String) -> String? {
        guard !holds(window, session: session) else { return nil }
        return MachineBrowserText.owner(window)
    }

    /// The row: the window, and who it would be taken from.
    static func row(_ window: MachineWindow, session: String) -> String {
        let name = window.label.isEmpty ? unnamed : window.label
        guard let holder = holder(window, session: session) else { return name }
        return "\(name) · \(holder)"
    }
}

/**
 * The one thing the strip offers, and why it is a decision rather than a ternary.
 *
 * > *"If I click on it, it is not opening."*
 *
 * It **was** a ternary — folded, or not — and that sentence is what it earned.
 * The pane was `.split`, so the chevron pointed down and read *fold the page
 * away*, while the space under it was empty because the cast had been stopped by
 * a canvas on another tab (the file header has the walk). One control, describing
 * a state, over a thing that was not there.
 *
 * Three facts decide it and only one of them was being read. Pinned out of the
 * view body for the same reason `SessionHandover` is: what is wrong here is not
 * an ugly frame, it is a person pressing something that cannot work, which is
 * the whole complaint this file is answering.
 */
enum SessionPageVerb: Equatable {
    /// The pane is folded. Pressing brings it back — and asks for the cast on the
    /// way, so it is never a state change against a page nobody is sending.
    case show
    /// A picture is arriving. Pressing puts it away and stops nothing: the window
    /// stays open, the binding stays, the agent carries on, the cast keeps
    /// running.
    case fold
    /// The pane is shown and nothing is arriving. Pressing asks the machine for
    /// the page again, which is the way back from a cast something else stopped
    /// **without leaving the session** — leaving and coming back always rebuilt
    /// the canvas, and finding that out is not a thing to make somebody do.
    case askAgain
    /// No cast can be had: this machine does not offer its browser for watching,
    /// or there is no connection to ask over. Nothing is drawn — the sentence
    /// under the strip is the whole answer, and a chevron beside it would be a
    /// second control that cannot act.
    case nothing

    static func verb(folded: Bool, showing: Bool, castable: Bool) -> SessionPageVerb {
        /*
         * Folded first, because a folded pane can nearly always be unfolded and
         * unfolding is also what asks. The exception is a machine that will never
         * cast anything: there is nothing to unfold *to*, so the strip stops
         * offering it and the sentence is drawn through the fold instead — see
         * `stage`.
         */
        if folded { return showing || castable ? .show : .nothing }
        if showing { return .fold }
        return castable ? .askAgain : .nothing
    }
}

/**
 * The most of a session screen a split page may take.
 *
 * A plain number rather than a fraction of the screen, and the reason is the
 * order things happen in: a fraction would have to be measured against the height
 * this pane has been given, which is the very thing the fraction is being used to
 * decide. A cap measured against a page instead is stable — it is only ever
 * reached by a page taller than it is wide, which on a desktop-width render is
 * rare.
 *
 * Four hundred and forty points is a page tall enough to read a form on and still
 * leaves ten rows of terminal on the shortest phone this app supports, which is
 * the number that matters: a split where the terminal has vanished is not a
 * split, it is a page with a strip on it.
 */
private enum SessionPageRoom {
    static let splitCap: CGFloat = 440
}
