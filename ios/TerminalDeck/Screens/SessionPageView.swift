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
 * the terminal carries on underneath it. A 1280×800 page on a 393-point phone is
 * 246 points tall; before this it was 246 points of page inside a
 * seven-hundred-point black box.
 *
 * The trade is one extra layout pass on open: the canvas is handed a generous
 * box, reports its real height, and is handed that instead.
 *
 * ## The page comes **over** the terminal. It does not push it down
 *
 * > *"it should not move chat down to come in front or rerminal it should just
 * > expand over it"*
 *
 * It did push it down, and that is what this section replaced. The pane was the
 * first child of a `VStack` whose second child was the session, so opening it
 * took four hundred points off the terminal and shoved the conversation, the
 * composer and everything he was reading down the screen — and folding it shoved
 * them all back. A page arriving is not supposed to move his place in the
 * transcript.
 *
 * So the screen is in two pieces now and only one of them is in the flow:
 *
 *  - **The strip is laid out**, above the session, always, whenever this session
 *    holds a window. It has to be: it is the one control that brings the page
 *    back, and a strip drawn over the terminal would sit on top of the top row of
 *    output for ever.
 *  - **Everything the fold moves — the handover bar and the picture — floats.**
 *    It hangs from under the strip, over the terminal, and takes the terminal's
 *    room without taking its layout. `body` is a `ZStack` with the session
 *    underneath and the page above it, which is why this view is handed the
 *    session as a child rather than sitting beside it.
 *
 * Three things fall out of that, and each of them is a thing that used to be
 * true and is not any more:
 *
 *  - **No `resize` on the wire.** The terminal keeps every row it had, so
 *    opening the page no longer repaints the far end and no longer reflows the
 *    transcript. That was written down here as part of *what a split is*; it was
 *    the cost of the wrong layout rather than the cost of the feature.
 *  - **`.full` is gone from `SessionPagePane`**, along with the last reason this
 *    screen's parent had to know anything about the pane at all. `TerminalScreen`
 *    owned the state because *"the terminal below has to be laid out against the
 *    same answer"*; nothing below is laid out against it any more, so the state
 *    came in here where the rest of it already lived.
 *  - **The chat's composer is reachable while the page is open.** It is at the
 *    bottom of the session, the session still has the whole screen under the
 *    strip, and the keyboard lifts it the way it always did. Under the old stack
 *    a page open over a conversation took the composer off the bottom of the
 *    screen.
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
 * of the hierarchy, because `dismantleUIView` is what sends `browser.unwatch` and
 * one connection is one `watcherId`, so unmounting would stop the pictures for
 * every canvas on this phone rather than only for this one.
 *
 * **What that used to buy, and does not any more.** The line here read *"reopening
 * is instant and already showing the page as it is now, rather than a second of
 * nothing while a screencast is renegotiated"*, and it was the argument for the
 * guard in `askForThePage` that made *Show the page* do nothing at all for three
 * rounds. Showing renegotiates now, always — see `SessionPageAsk` — so reopening
 * is a beat of *Asking for the page…* and then the page. Keeping the canvas
 * mounted still buys the two things that actually matter: the fold does not stop
 * the cast for the other screens, and it does not throw away the frame sink. The
 * bytes are bounded either way by the one-un-acked-frame backpressure the host
 * holds.
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
 *  - **Showing asks.** `show()` re-reads both lists and rebuilds the canvas. A
 *    rebuilt canvas re-adopts the sink and asks for the cast again, which is the
 *    only way back from either half of the failure. (It read *and, when nothing
 *    is arriving for this window, rebuilds the canvas — a page that is arriving
 *    is left alone, so an ordinary unfold is still instant.* That clause is
 *    deleted and it is the whole of the third report; see the round-three
 *    section below and `SessionPageAsk`.)
 *  - **The verb says what pressing it will do.** `SessionPageVerb` is the whole
 *    of it: a fold is offered only while a picture is really arriving, and a
 *    pane that is shown and empty offers *ask for it again* instead. (It had a
 *    fourth state — *offer nothing at all*, on a machine that will not cast —
 *    and the second review deleted it: see the verb's own header for why a strip
 *    whose control comes and goes is the same dead button in a different shape.)
 *  - **The canvas is identified by the window it is showing.**
 *    `WatchSurfaceUIView.target` is a `let` fixed at `init`, and SwiftUI updates
 *    a representable in place rather than rebuilding it — so a session whose
 *    binding moved to a **different** window kept a canvas casting the old one
 *    and dropping every frame for the new one, under a strip naming the new one.
 *    This is the one mount whose surface can change under it; the other two are
 *    handed a fixed window by the screen that pushed them.
 *
 * ## And it still did not open, because the picture was black and so is the ground
 *
 * > *"browser window when it collapse it is not expanding back I can not open it
 * > back once if I close it inside a session in any session even co-pilot or any
 * > other normal session."*
 *
 * Everything above was in the build he filmed that on. The three changes were
 * right and they were not enough, because they all assume that *the pane has
 * height* and *the person can see something* are the same sentence. They are
 * not, and one specific state proves it: a window on `about:blank`.
 *
 * `WatchLink.isCasting` is **not** *a picture is arriving*. It is *a
 * `browser.watch` of ours left and a canvas is registered to draw the answer* —
 * both true the instant the canvas mounts, neither of them a frame. So an
 * unfold gave the stage the generous 440-point box, `WatchStage` filled it with
 * `Color.black` — and the session screen's ground is the **terminal theme's**
 * ground, which on his theme is black, under a terminal that was idle and
 * therefore blank at the top. Four hundred points of black appearing over black.
 * A blank page never repaints, so no frame was ever coming to end it.
 *
 * From the outside: he pressed the one control on the strip, and the screen did
 * not move. Which is *"it is not expanding back"*, exactly, and it is the same
 * complaint as the first round from a different direction — a control whose
 * press cannot be seen.
 *
 * So the rule this pane is now built on is blunter than any of the three above:
 * **every press changes something he can see.**
 *
 *  - `hasPicture` is *a frame has really been drawn*, which is `pageHeight > 0`
 *    and nothing else, because `onPageHeight` is downstream of a real unmasked
 *    frame being laid out. The height is cleared wherever the picture it
 *    describes stops being the current one.
 *  - `SessionPageStage` gives every state that is **not** a picture a plain line,
 *    drawn over the canvas — asking for the page, this window is not being cast,
 *    this machine does not offer its browser for watching, not connected. There
 *    is no state left that draws neither a page nor a sentence.
 *  - The control is never absent and never carries the wrong word: folded is
 *    always *Show the page*, and a pane holding a sentence can always be put
 *    away again.
 *  - The ask itself is visible for two seconds (`markAsking`), because on a
 *    window the machine will not cast the honest answer is *no change* and *no
 *    change* is indistinguishable from a dead button.
 *
 * ## And it still did not open, a third time — the same wrong question, one
 * layer down
 *
 * > *"but it is still not opening after closing"*
 *
 * Photographed: a Google window, the pane open, the words *Asking for the page…*
 * on it and nothing else, ever.
 *
 * The round above is the one that found that `WatchLink.isCasting` is not *there
 * are pixels*. It fixed that where the screen **reads** the state — `hasPicture`
 * — and left the identical assumption standing where the screen **acts** on it,
 * three hundred lines further down:
 *
 *     guard let page = surface?.window, host?.watch.isCasting(page) != true else { return }
 *     recast()
 *
 * That line said: *a cast the wire believes in means there is nothing to ask
 * for*. `isCasting` is `casting.contains(window) && frameHandler != nil`, and a
 * fold changes neither — the canvas stays mounted at zero height precisely so it
 * keeps the sink and keeps the watch. So every press of *Show the page* took the
 * early return: `markAsking()` had already fired, so the sentence appeared, and
 * then nothing was ever asked for again and no frame was ever coming to end it.
 * *Asking for the page…*, permanently, which is the exact screen he sent.
 *
 * The rule now has no condition on it at all. **A press for the page always
 * rebuilds the canvas** — `SessionPageAsk`, which exists as a type for one
 * reason: so that the fact this must never read is visible in its signature and
 * a test can hold it there. The cost is a renegotiation on an ordinary unfold,
 * which is a beat of *Asking for the page…* and then the page; the thing it buys
 * is that there is no state of the wire, of the sink, or of another tab's canvas
 * that can make the one control on this strip do nothing.
 *
 * **The canvas answers for itself too**, and that half is independent of every
 * word above: `WatchRenegotiation` makes a canvas whose box goes to nothing and
 * comes back ask for the cast again, without letting the keyboard — which
 * changes the height on every keystroke and never the width — restart anything.
 * Two guarantees rather than one, because this is the third round on the same
 * sentence and *"I have failed to fix this twice"* is not a thing to answer with
 * one line and a hope.
 *
 * **The Copilot tab is the same screen and needed nothing of its own**, which
 * was checked rather than assumed: `DeckTabs` builds a `TerminalScreen` for the
 * copilot's conversation as the *tab's root* rather than as a pushed screen, and
 * `TerminalScreen.frontmost` already has the branch that says so (`leaveTab !=
 * nil`). The pane is handed the same `frontmost` on both, so the canvas mounts
 * on both. He named the Copilot session because it is the one he had open, not
 * because it behaves differently.
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
 *
 * Those menus carry a second verb now — `HostLink.openMachineWindow(session:)`,
 * which opens a window and binds it in one ask — because *the verb is there* and
 * *there is something under the menu* turned out to be different claims. A
 * machine with its browser closed has no window to bind, so both sections drew
 * nothing at all, which is the walk he recorded from the inside. See
 * `SessionWindowPicker.showsAttach`.
 */

import SwiftUI

/**
 * How much of the session screen the page has.
 *
 * **There were three of these and there are two.** The third was `.full` — the
 * page having the whole screen — and the verb that set it was deleted a round
 * ago:
 *
 * > *"This button is like not working the way I was expecting. This is something
 * > else. We do not need actually this part. We do not need this to be coming
 * > down like with black page."*
 *
 * The case itself outlived the verb for one reason: `TerminalScreen` decided
 * whether to draw the terminal at all from `pagePane != .full`. That test is
 * gone with the layout it belonged to — the page floats over the session now and
 * the session is never not drawn — so nothing reads it, nothing can reach it,
 * and a state nothing can reach is a state somebody will eventually write code
 * against by mistake.
 */
enum SessionPagePane: Equatable {
    /// A strip and nothing else. The cast is still running; see the file header.
    case minimised
    /// The page at its own height, floating over the session.
    case split
}

struct SessionPageView<Session: View>: View {
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

    /**
     * **The session itself, drawn underneath the page.**
     *
     * The terminal, or the conversation — this view neither knows nor cares
     * which, and `TerminalScreen.sessionBody` is the one thing that does. It is
     * a child rather than a sibling because of the whole of *"it should not move
     * chat down… it should just expand over it"*: a sibling in a stack is a
     * thing the page's height is subtracted from, and the only way to be **over**
     * something in SwiftUI is to be in a stack with it.
     *
     * It is drawn on every path through `body`, including the one where this
     * session holds no window at all — which is nearly every session, nearly all
     * the time. Nothing about a page is drawn there and nothing about the session
     * changes; this view is a pane above a session and a passthrough otherwise.
     */
    private let sessionBelow: Session

    /**
     * How much room the page has.
     *
     * **It moved in here**, and the note it replaces said why it used to live on
     * `TerminalScreen`: *"the terminal below has to be laid out against the same
     * answer."* That was true while the two were siblings in a stack. The page
     * floats over the session now, the session's box is the same whether the pane
     * is open or folded, and nothing outside this file reads this — so the state
     * belongs with the four other pieces of state that decide what the pane is
     * doing, rather than one screen away from them.
     *
     * `.split` as the starting value rather than `.minimised`: nothing at all is
     * drawn until a window is bound to this session, so this is only ever read
     * after something has decided there is a page — and the first thing a page
     * should do is be visible.
     */
    @State private var pane: SessionPagePane = .split

    /// The window this pane has already offered, so it is offered once. Nil until
    /// something has been shown.
    @State private var shown: String?
    /// The window that was put away by hand. It does not come back on its own —
    /// a surface that reopens itself over a conversation somebody is reading is
    /// the interruption this feature has to avoid being.
    @State private var folded: String?
    /**
     * The height the canvas says the picture is. Zero until the first frame has
     * really been drawn, and `canvasHeight` hands out the generous box in the
     * meantime so the fit lands on the width rather than on the guess.
     *
     * It is also the **only honest answer to *are there pixels on this stage***,
     * which is what it became after the second review. `WatchLink.isCasting` is
     * *we asked for a cast and something is registered to draw it* — it is set
     * the moment `browser.watch` leaves and says nothing about whether a frame
     * ever came back. `onPageHeight` is fired from `WatchSurfaceUIView.announce`,
     * which is downstream of a real unmasked frame being laid out. So a stage
     * whose `pageHeight` is zero has drawn nothing, whatever the wire thinks.
     *
     * Reset wherever the picture stops being the one this number describes — a
     * new window, a rebuilt canvas — because a stale height is exactly how a
     * blank stage came to be treated as a picture.
     */
    @State private var pageHeight: CGFloat = 0

    /**
     * A question of ours in flight, for as long as it takes to be visible.
     *
     * > *"browser window when it collapse it is not expanding back I can not
     * > open it back once if I close it inside a session in any session."*
     *
     * The press that asks for the page can be answered by *nothing changing*:
     * on a window the machine will not cast, `askForThePage()` sends two small
     * questions and the answers say what the screen already said. A control
     * whose press produces no change on the screen is a dead control, whatever
     * it did on the wire — that is the whole of the complaint above — so the
     * ask itself is drawn: for two seconds the stage says it is asking, and
     * then it says what it found.
     *
     * A one-shot and not a poll. It cannot be cleared by an answer landing,
     * because the answer to *what has the browser got* is very often byte-equal
     * to the last one and `onChange` does not fire for a value that did not
     * move — which would leave *Asking for the page…* on the screen for ever.
     */
    @State private var asking = false

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

    /**
     * Written out rather than left to the memberwise one, because the session is
     * handed over as a `@ViewBuilder` and the four `@State` properties above must
     * not appear in the signature. `session:` is a trailing closure at every call
     * site, so what a reader sees is a page with a session inside it.
     */
    init(model: DeckModel, hostID: String, sessionID: String, frontmost: Bool,
         @ViewBuilder session: () -> Session) {
        self.model = model
        self.hostID = hostID
        self.sessionID = sessionID
        self.frontmost = frontmost
        self.sessionBelow = session()
    }

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

    /**
     * Whether there are really pixels on this stage — which is **not** the same
     * question as `showing`, and the second review is what taught it.
     *
     * > *"browser window when it collapse it is not expanding back I can not
     * > open it back once if I close it inside a session in any session even
     * > co-pilot or any other normal session."*
     *
     * Photographed: a session holding a window on `about:blank`, the strip drawn
     * with the chevron pointing **up** — so the pane was folded and the control
     * was the way back — and pressing it changed nothing he could see.
     *
     * Everything in that state was working as written. `isCasting` was true (a
     * `browser.watch` had left and a canvas held the sink), so unfolding gave the
     * stage the generous 440-point box, and `WatchStage` fills its box with
     * `Color.black` before it draws anything. **The session screen's ground is
     * the terminal theme's ground, which on his theme is black**, and the top of
     * an idle terminal is blank. So the unfold painted a black rectangle over
     * black, with no words in it, and the only thing that moved was empty
     * terminal sliding down. From the outside that is indistinguishable from a
     * button that does nothing — and a page on `about:blank` never repaints, so
     * no frame was ever going to arrive to end it.
     *
     * The fix is not to guess better about the wire. It is to stop drawing a
     * blank box as if it were a page: with no frame drawn, the stage says in one
     * line what is happening (`SessionPageStage`), and the line is the thing that
     * changes when he presses.
     */
    private var hasPicture: Bool { showing && pageHeight > 0 }

    /// What the stage says when it has no picture to show. `asked` is a question
    /// of ours outstanding — either one this screen has just sent, or a cast the
    /// wire believes is running — and `SessionPageStage` turns the four facts
    /// into the one line that is true.
    private var stageState: SessionPageStage {
        SessionPageStage.stage(hasPicture: hasPicture,
                               asked: asking || showing,
                               live: model.connection.isLive,
                               offered: host?.watch.offered == true)
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

    /**
     * The strip, the page hanging under it, and the session under both.
     *
     * > *"it should not move chat down to come in front or rerminal it should
     * > just expand over it"*
     *
     * ## One stack, and only one thing in it is in the flow
     *
     * **The strip.** It has to be: it is the one control that brings the page
     * back, and a strip drawn over the terminal would sit on top of the top row
     * of output for ever. It is the same height whether the pane is open, folded
     * or carrying a question, so the session's box is decided once — when a
     * window becomes this session's — and never again. The transcript does not
     * reflow, the emulator sends no `resize`, and his place in the output is where
     * he left it.
     *
     * **Everything the fold moves floats.** `floatingPage` is in a `ZStack` with
     * the session, anchored to the top of it, which is the top of the space under
     * the strip. Opening the page draws it down over the terminal; folding rolls
     * it back up under the strip. Nothing underneath moves either way. That is
     * what the sentence above asks for and it is the whole of the layout change:
     * the pane used to be a **sibling** above the session, so every point it took
     * was a point off the terminal.
     *
     * ## The session is in one place, in every state
     *
     * `sessionBelow` is drawn from the same position in the tree whether this
     * session holds a window or not, which is deliberate rather than tidy. The
     * obvious shape is *a page over a session, or a session* — two branches — and
     * SwiftUI reads those as two different places: a window binding mid-session
     * would take `TerminalHostView` out of one hierarchy and put it into another.
     * That is survivable (`makeUIView` hands back `bridge.container`, a view the
     * bridge owns, so the emulator and its scrollback come with it) and it is
     * still churn on the one view a person is reading, at the exact moment an
     * agent has just done something. So the stack is always the stack and the
     * strip is what comes and goes.
     *
     * ## A session holding no window shows nothing at all
     *
     * > *"If it is not connected to anyone, so it should stay clean. Even if I go
     * > to Copilot, which has no browser window attached, it is also showing
     * > something attached."*
     *
     * No strip, no hairline, no floating half, not a point of height — this is
     * `sessionBelow` and nothing else, which is nearly every session nearly all of
     * the time. There was a bar here that offered to go and get a window; it is
     * deleted, and the file header has the argument and where the verb went.
     *
     * The **view** stays in the tree either way, because the reads below are what
     * notice a window becoming this session's: a pane that took itself out when
     * there was nothing to draw would be a pane that never found out there was.
     *
     * ## The keyboard, and the one case that is still tight
     *
     * The session owns the whole box under the strip, so a conversation's composer
     * sits at the bottom of the box rather than at the bottom of whatever the page
     * left over — which is why it is reachable with a page open at all. Under the
     * old stack a page took four hundred points off the top and the composer went
     * off the bottom edge with them.
     *
     * What is still tight, said rather than pretended about: the picture keeps its
     * own height when the keyboard comes up, so on the shortest phones a page
     * standing at the full `SessionPageRoom.splitCap` and a keyboard up together
     * leave the bottom of the picture behind the keyboard. It is anchored at the
     * **top**, so what is behind the keyboard is the bottom of the page and not
     * its address or its first field; and the cap is only ever reached by a page
     * taller than it is wide, which a desktop-width render rarely is. The old
     * stack had the same ceiling and spent it on the terminal instead.
     */
    var body: some View {
        VStack(spacing: 0) {
            if let window {
                strip(window)
                // The strip's own bottom edge, drawn whatever is beneath it — the
                // page when it is open, the terminal when it is not.
                Rectangle()
                    .fill(Theme.hairline)
                    .frame(height: 0.5)
            }
            ZStack(alignment: .top) {
                sessionBelow
                // Gated on the window and not left to draw nothing on its own: a
                // session with no window has no surface either, and the stage
                // would answer *this window is not being cast* about a window
                // that does not exist.
                if window != nil {
                    floatingPage
                }
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

    /**
     * The half that floats: the handover bar, the picture, and the line that
     * stands in for the picture when there is not one.
     *
     * The bar is above the canvas and **outside the part that folds**, which is
     * what makes a fold unable to hide a question somebody is being asked — see
     * the file header. That was true when this was a stack over the terminal and
     * it is still true now that it is a stack over the terminal: what changed is
     * where the terminal is, not where the bar is.
     *
     * The bottom hairline is drawn only when there is something above it to
     * finish. Folded, with no question outstanding, this whole stack is zero
     * points tall and must be exactly that — a hairline left drawn would be a
     * stray line lying across the top row of the terminal, and the terminal is
     * what is there when the page is not.
     */
    @ViewBuilder
    private var floatingPage: some View {
        VStack(spacing: 0) {
            if let handover, let page = surface?.window {
                handoverBar(handover, page: page)
            }
            stage
            if handover != nil || stageHasHeight {
                Rectangle()
                    .fill(Theme.hairline)
                    .frame(height: 0.5)
            }
        }
    }

    /// Whether the stage is drawing anything — a canvas with room in it, or the
    /// one line that says why there is no canvas. Folded, it is neither, and the
    /// floating half has to come to nothing rather than to nearly nothing.
    private var stageHasHeight: Bool {
        canvasHeight > 0 || (pane != .minimised && stageState.line != nil)
    }

    /**
     * The picture, or the one line that says why there is not one — and never
     * neither.
     *
     * Kept in the hierarchy while minimised — at zero height — because taking it
     * out is what sends `browser.unwatch`, and folding must not stop the cast.
     * Nothing is renegotiated on the way **down**: `WatchRenegotiation` asks
     * about the render width, which a height of zero does not change, and about a
     * box *arriving*, which a box going away is not.
     *
     * On the way back up it does ask again, and that is the round-three change
     * rather than an accident of this one. A canvas that has had no box has no
     * way of knowing whether the cast it was watching is still running or whether
     * another tab's canvas took the frame sink out from under it while nobody
     * could see. Both of those really happen, both leave this view mounted and
     * blind, and neither of them moves a single width.
     *
     * ## Why the sentence is a layer over the canvas rather than a branch beside it
     *
     * The old shape was an `if let surface … else …`: a canvas when the machine
     * listed the window as castable, a sentence when it did not. That draws the
     * one state it could not see — **listed, watched, and blank** — as four
     * hundred and forty points of `Color.black` with nothing in it, which is the
     * screen he photographed and the reason he says the control does not work.
     * See `hasPicture` for the whole walk.
     *
     * So the two are stacked instead of chosen between. The canvas is mounted
     * whenever the machine has a surface for this window — it has to be, it is
     * the only thing that can ask for a cast or adopt the frame sink — and the
     * sentence is drawn on top of it for exactly as long as nothing has been
     * painted. A frame lands, `pageHeight` moves off zero, the sentence goes.
     *
     * Nothing is drawn at all through a fold, whatever the state: the strip's
     * control is now never absent (`SessionPageVerb`), so a folded pane always
     * has a way back to the sentence and never needs it drawn through the fold.
     */
    @ViewBuilder
    private var stage: some View {
        ZStack {
            if let watch = host?.watch, let surface {
                WatchStage(watch: watch,
                           window: surface.window,
                           mounted: frontmost,
                           onPageHeight: { pageHeight = $0 },
                           // This screen has the bar, so the card must not print
                           // the agent's sentence a second time — measured on a
                           // 393-point phone, where the two of them between them
                           // were most of the screen. Only while there is a bar:
                           // a curtain raised by a password box with no question
                           // behind it still gets the whole sentence, because
                           // there is nothing else to read it from.
                           sentenceIsDrawnAbove: handover != nil)
                    // The canvas's identity, which is a correctness thing and not
                    // a hint — see `recastToken`. The surface name is in it
                    // because `WatchSurfaceUIView` fixes its target at `init` and
                    // this is the one mount whose surface can change under it; the
                    // token is in it because rebuilding is how a stopped cast is
                    // asked for again.
                    .id("\(surface.window)#\(recastToken)")
                    .frame(height: canvasHeight)
                    .clipped()
                    .accessibilityIdentifier("session.page.stage")
            }

            /*
             * One plain line, and it is the thing that moves when he presses.
             *
             * Every state that is not a picture has words now — a machine that
             * will not cast, a window it will not cast, a cast that has been
             * asked for and produced nothing yet, a socket that has gone. The
             * identifier stays `session.page.nocast` because that is what the
             * suites already reach for, and the sentence behind it has simply
             * stopped being only about a machine that refuses.
             */
            if pane != .minimised, let line = stageState.line {
                Text(line)
                    .font(.system(size: 13))
                    /*
                     * Read against whatever is actually behind it, which is two
                     * different grounds. Over a canvas holding room for a cast
                     * that has not arrived, the ground is `WatchStage`'s
                     * `Color.black` — deliberately black rather than the app's
                     * paper, so that a page's own white has an edge — and
                     * `Theme.faint` is a grey chosen against the app's paper. On
                     * a light theme that pairing is a grey line on black that
                     * fails exactly where this line matters most: a stage with no
                     * picture in it is the one place somebody is being told
                     * something rather than shown it.
                     */
                    // Spelled as RGB, not as a white tint. `AppearanceTests`
                    // bans the white-tint shorthand because it is the smell of
                    // a colour that forgot to adapt — and this one is meant not
                    // to (and is written without naming the shorthand, because
                    // that test reads text and cannot tell a mention from a use):
                    // it sits on the canvas's own dark plate in both themes. It
                    // is the same #e6e8ec the curtain card uses two files over,
                    // for the same reason.
                    .foregroundStyle(canvasHeight > 0
                                     ? Color(red: 0.902, green: 0.910, blue: 0.925)
                                     : Theme.faint)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 18)
                    /*
                     * Something to sit on, but only where it is sitting on the
                     * canvas. The one state that draws this line **over a picture**
                     * is a socket that has gone — the frame on screen is the last
                     * one that arrived and everything on it is as stale as the
                     * connection — and a bare line of text laid over a web page is
                     * indistinguishable from something the page itself is saying.
                     * Under a strip with no canvas under it there is nothing to
                     * separate it from, and a plate there would be a box drawn
                     * around one sentence.
                     */
                    .background {
                        if canvasHeight > 0 {
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(Color.black.opacity(0.62))
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .accessibilityIdentifier("session.page.nocast")
            }
        }
        /*
         * A ground under the sentence, for the state where the sentence is the
         * whole of the pane.
         *
         * It did not need one while this stack sat above the terminal: the space
         * it took was the screen's own ground and the line was the only thing in
         * it. The page floats over the terminal now, so a line with nothing behind
         * it would be a sentence of the app's laid across live output — the same
         * defect the plate over the canvas already exists to prevent, one layer
         * out. `Theme.surface` is the strip's own fill, so the two read as one
         * piece of chrome hanging under the strip rather than as a caption that
         * has landed on the terminal.
         *
         * Only where there is no canvas. A canvas paints its own black, the plate
         * above handles a line drawn over a picture, and a folded pane has
         * nothing at all here and must keep having nothing.
         */
        .background {
            if canvasHeight == 0 { Theme.surface }
        }
    }

    /**
     * How tall the canvas is drawn.
     *
     * Zero folds it away without unmounting it, and zero again where nothing is
     * being sent at all — a canvas that is not casting has no picture to hold
     * room for, and the sentence beside it is what takes the height instead. A
     * cast that **is** running gets the page's own height once a frame has been
     * measured, and the generous box until then, because the fit needs a box
     * taller than the answer or it lands on the height and letterboxes the sides.
     *
     * That generous box is also why the sentence is drawn over the canvas rather
     * than under it: while a cast is being waited on, the stage is 440 points of
     * black, and 440 points of black with no words in it is the screen he
     * photographed.
     *
     * Whatever this answers, it is 440 points **over** the session and never 440
     * points taken off it — see `body`. The cap is what stops a tall page
     * from covering the terminal rather than what stops it from squeezing it.
     */
    private var canvasHeight: CGFloat {
        guard pane != .minimised, showing else { return 0 }
        return pageHeight > 0 ? min(pageHeight, SessionPageRoom.splitCap) : SessionPageRoom.splitCap
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
                // Named by the one rule that names windows anywhere in this
                // app, so the strip and the menu that attached it cannot come to
                // call the same window two different things. See `WindowNames`.
                Text(WindowNames.name(window))
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Theme.primary)
                    .lineLimit(1)
                /*
                 * The site, and **only where the name above is not already
                 * saying it.**
                 *
                 * This is the one second line in this file that stays, and it
                 * stays because it is not a description of the feature — it is
                 * the line somebody reads before deciding whether to type a
                 * password into a page an agent brought them, which is why
                 * `MachineBrowserText.site` names the host and nothing else.
                 *
                 * What it does drop is the case where it was the same fact
                 * twice: a window with no title of its own is *named* by its
                 * address, so drawing the host underneath it was a strip two
                 * lines tall to say one thing — *"you should compact all the
                 * features or buttons and without losing any of them."*
                 */
                if let site = MachineBrowserText.site(window.url),
                   !WindowNames.name(window).lowercased().contains(site.lowercased()) {
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
                case .fold: break
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
                button(SessionPageVerb.showLabel, "chevron.up", id: "session.page.fold") { show() }
            case .fold:
                button(SessionPageVerb.hideLabel, "chevron.down", id: "session.page.fold") { fold() }
            case .askAgain:
                button(SessionPageVerb.askLabel, "arrow.clockwise", id: "session.page.fold") {
                    askForThePage()
                }
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
        // A different window is a different picture, and the height of the last
        // one is not a fact about this one. Left standing, it is a stage that
        // claims to be showing something before a single frame of the new window
        // has arrived — see `hasPicture`.
        pageHeight = 0
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
     * Ask, and be seen to ask.
     *
     * The flag is the whole difference between a control that works and one that
     * looks broken, on the one machine state where the answer is *no change*: a
     * window the machine will not cast answers both questions below with what
     * the screen was already saying, so without this the press moves nothing at
     * all. Two seconds is long enough to read a line and short enough that the
     * pane is never left claiming to be asking after it has been answered.
     *
     * It is not a retry and not a timer that does anything: nothing is re-sent
     * when it ends, the line simply goes back to whatever is true.
     */
    private func markAsking() {
        withAnimation(.easeOut(duration: 0.15)) { asking = true }
        Task {
            try? await Task.sleep(for: .seconds(2))
            withAnimation(.easeOut(duration: 0.15)) { asking = false }
        }
    }

    /**
     * Ask the machine for this page again — all three questions, every time.
     *
     * > *"but it is still not opening after closing"*
     *
     * `reread()` is for the shape where the window is not in the strip at all:
     * the answer lands, `surface` stops being nil, and the canvas is built for the
     * first time by the ordinary redraw. `recast()` is for the shape where the row
     * is there and nothing is arriving — the cast was stopped, or the sink was
     * taken by a canvas that has since gone — and only a new canvas can undo
     * either of those.
     *
     * **There is no longer a condition on the second one**, and the line that was
     * here is the whole of the sentence above:
     *
     *     guard let page = surface?.window, host?.watch.isCasting(page) != true else { return }
     *
     * It was written for *"reopening is instant and already showing the page as it
     * is now"*, which is a real thing to want and was being bought with a fact
     * that does not mean what it was being read as. `isCasting` is *a
     * `browser.watch` of ours left and something is registered to draw the
     * answer*. A fold changes neither — the canvas is kept mounted at zero height
     * on purpose — so on every press of *Show the page* this returned early,
     * having already put *Asking for the page…* on the screen, and nothing was
     * ever asked for. On a page that does not repaint no frame was coming to end
     * it either. That is his photograph, exactly.
     *
     * `SessionPageAsk` is the rule now, and it is a type rather than a straight
     * line of code so the thing it must never read is written into its signature
     * and pinned by a test. The price is real and small: an ordinary unfold now
     * renegotiates, so it is a beat of the asking line and then the page, rather
     * than the page instantly. A beat is a fair trade for a control that cannot
     * be dead.
     */
    private func askForThePage() {
        markAsking()
        reread()
        switch SessionPageAsk.canvas(isCasting: showing) {
        case .rebuildIt:
            recast()
        }
    }

    /// Build a new canvas for this surface. See `recastToken` for why a rebuild
    /// is the act, and why it is safe in either order SwiftUI does it in.
    private func recast() {
        // The height belongs to the canvas being replaced. Carried across, it
        // would say *there is a picture* about a canvas that has not drawn one
        // yet, which is the reading that let a blank stage pass for a page.
        pageHeight = 0
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
 * What a browser window is **called**, everywhere in this app.
 *
 * ## The two windows he could not tell apart
 *
 * > *"we have one section saying attach a browser window where we see all the
 * > browser windows with their name then we see open window for this session
 * > open one signed into nothing which is so much of confusing i don't understand
 * > what is what and what are the differences… why don't we just simply have the
 * > name of the search of browsing windows we can just simply click on one of
 * > them and that's it."*
 *
 * Photographed above that sentence: a menu whose first three rows were
 * `about:blank`, `Google`, `about:blank`. Two of them were the same six
 * characters of jargon, and nothing on the screen said which was which — so the
 * list was not a list of windows, it was a guess with a checkmark somewhere in
 * it.
 *
 * `MachineWindow.label` is `title.isEmpty ? url : title`, which is right for a
 * page that has a title and wrong in exactly one place: a window with no page in
 * it yet. `about:blank` is the browser's own word for *nothing*, it is not
 * English, and every blank window on a machine wears it identically.
 *
 * ## The rule
 *
 *  1. **The page's own title**, whenever it has one. A person who opened it will
 *     recognise it, which is the whole job.
 *  2. **Its address**, until it has a title. Ugly and specific, and specific is
 *     what a menu row is for.
 *  3. **"Untitled"** for the ones that are not on a page at all — no address,
 *     `about:blank`, a new-tab screen. It is the word every browser already uses
 *     for a page with no name, it is English, and a person can point at it.
 *  4. **A number, only where the same name appears twice in the same list.**
 *     *Untitled 1*, *Untitled 2*, in the order the machine lists them — which is
 *     the order they are drawn in, on this menu and on the Browser tab, because
 *     both are drawing the one `browser.window.rows` answer.
 *
 * Numbering is decided against the **whole row** rather than the name, so a
 * window already told apart by the session holding it is not also numbered: two
 * blank windows on two different sessions read *Untitled · deploy* and
 * *Untitled · build*, which is two names and not a collision.
 *
 * ## It was *"Empty window"*, and the word is his
 *
 * > *"lets make only one name as browser and window identical to normal
 * > standards for browser everything else too"*
 *
 * *Empty window* was invented here. It was accurate and it was ours, and this app
 * is a browser on a phone — every word on it should be a word somebody has
 * already read in Safari or Chrome. *Untitled* is that word, and it is the same
 * rename as *Private* for an isolated window and *Window settings* for a window's
 * own screen: one vocabulary, borrowed rather than coined.
 *
 * The one thing it costs is that a page really can be **called** Untitled — a
 * blank document in an editor is, most of the time. Rule 4 is what makes that
 * survivable: two rows that read the same are numbered whatever made them the
 * same, so an untitled page and an empty window in one list come out *Untitled 1*
 * and *Untitled 2* rather than as a name a person cannot resolve.
 *
 * ## Why this is its own type
 *
 * *"Whatever you choose must be the same word everywhere the app names windows."*
 * A window is named in three places — this menu, the strip over the session, and
 * the Browser tab's own list — and all three call in here. The last of them was
 * the one written down as an outstanding half-application, reading
 * `MachineWindow.label` directly so that a blank window was our word in a session
 * and `about:blank` on the Browser tab; `MachineBrowserView` calls
 * `WindowNames.name` now, which is what makes this the one rule rather than the
 * one rule and an exception.
 */
enum WindowNames {

    /// What a window with no page in it is called. Not `about:blank`, which is
    /// the browser's word for *nothing* and is the same six characters for every
    /// one of them — and not a word of ours either: *Untitled* is what a browser
    /// already calls a page that has not said its name.
    static let blank = "Untitled"

    /**
     * The addresses that mean *this window is not on a page*.
     *
     * Matched exactly and lower-cased rather than by prefix: `about:blank` is a
     * real value on the wire, and a prefix test on `about:` would silently rename
     * `about:preferences` — a page somebody deliberately opened — to *Empty
     * window*.
     */
    private static let nowhere: Set<String> = [
        "", "about:blank", "about:newtab", "about:blank#blocked",
        "chrome://newtab/", "chrome://new-tab-page/", "edge://newtab/",
    ]

    /// What one window is called, with nothing else on screen beside it. The
    /// strip over a session uses this: it draws one window and a number would be
    /// a number out of nowhere.
    static func name(_ window: MachineWindow) -> String {
        let title = window.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !title.isEmpty { return title }
        let url = window.url.trimmingCharacters(in: .whitespacesAndNewlines)
        return nowhere.contains(url.lowercased()) ? blank : url
    }

    /**
     * What it is called **in a list beside the others**, which is where the same
     * name twice stops being a cosmetic problem.
     *
     * The number is its place among the windows sharing its name, from one, in
     * the order the machine gave them. Not the slot (`B1`) — a slot is the name
     * the *agent's* tools use for a window and exists only for a bound one, so
     * half a list would be numbered and the other half named after something he
     * has never seen. Order is the thing both he and the list already agree on.
     *
     * `same` is walked rather than indexed into `windows` so that a window that
     * is not in the list it is being named against — which should not happen and
     * is not worth a crash — comes back with its plain name.
     */
    static func name(_ window: MachineWindow, in windows: [MachineWindow]) -> String {
        let mine = name(window)
        let same = windows.filter { name($0) == mine }
        guard same.count > 1, let place = same.firstIndex(where: { $0.id == window.id }) else {
            return mine
        }
        return "\(mine) \(place + 1)"
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
 * There are two `…` menus that go and get a window for a session — the session
 * row's on the Sessions tab and the session's own inside the terminal — and this
 * pane, which draws the one it ends up holding. Three screens, one question. The
 * bar these replaced was a fourth, written inline, and the wording on it had
 * **already** drifted from the Browser tab's: it named the window and its owner
 * where the other named the session and its window count. Nobody could see that,
 * because the two are never on screen together.
 *
 * So the decisions live here: which windows may be offered at all, whether a row
 * is the one this session already holds, and what the row says. Each is a
 * sentence or a rule rather than a layout, and `SessionPageTests` pins all three
 * without a simulator.
 *
 * ## It is a list of windows. That is all it is
 *
 * > *"then we see open window for this session open one signed into nothing which
 * > is so much of confusing i don't understand what is what and what are the
 * > differences then we see open again on this specific desktop the page here
 * > stays then we see another name of the window so why they are like so much of
 * > confusing saying words why don't we just simply have the name of the search
 * > of browsing windows we can just simply click on one of them and that's it why
 * > it's too confusing to use."*
 *
 * What he was reading, in one section, in this order: three window names, then
 * *Open a window for this session*, then *Open one signed into nothing*, then a
 * section header reading *Open again on DESKTOP-DDGMNCV — the page here stays*,
 * then another window name. Five of those eight rows were sentences arguing with
 * each other about profiles and about which end a page lives on, wedged between
 * the names he came to press.
 *
 * Every one of those sentences was true and each had a reason. They are still
 * true; they are simply not written on the rows any more:
 *
 *  - **The private window is gone from this menu.** Not because the word is long
 *    — *Private* is the shortest row in the app — but because *which profile* is
 *    a decision made where a window is **made**, and this section is a list of
 *    windows that already exist. It is not lost: the Browser tab's `+` offers it
 *    on the New window sheet, which is where somebody choosing a partition
 *    already is. The row here opens a window the ordinary way.
 *  - **The phone-page header is gone.** Its rows join the one flat list under
 *    their own names, and the fact it carried — *the page here stays* — moves to
 *    the row's accessibility hint and to the sentence the phone puts up after the
 *    press, which is where it is read once instead of scanned every time.
 *
 * What is left is: the windows, by name, one tap each, a checkmark on the one
 * this session holds, and — after a divider, at the end — one row that makes a
 * new one.
 *
 * ## Everything the machine has open, minus nothing
 *
 * A window another session holds is still one this session can be handed — the
 * rule the Browser tab's own menu already follows, where the row reads *"Attach
 * to another session"* rather than refusing. What that means in practice is that
 * attaching **moves** it, and silently, so the row has to say who has it now.
 * That is the whole of `row(_:among:session:)`: a name, and the holder after it
 * when somebody else is the holder. It survives the compacting because it is not
 * prose — it is half of the window's identity, it is two words, and dropping it
 * would make one tap quietly take a page off another agent.
 *
 * ## An empty list is not a reason to draw nothing — and that is a correction
 *
 * This used to end: *"empty on a machine that will not be driven, so the section
 * is absent rather than drawn dead."* Both menus read that as **absent whenever
 * the list is empty**, and the two conditions are not the same condition. A
 * machine that will not be driven can offer nothing, which is right. A machine
 * that *will* be driven and simply has no browser window open right now can
 * offer plenty — it can open one — and that is the ordinary state of a laptop,
 * and it is the exact state he was sitting in:
 *
 * > *"here we also don't have anything, like inside here, in the three dots, we
 * > should have the options to click on something, and then all the folders will
 * > come up, maybe here also. So we can connect the browser, whichever browser we
 * > want to connect into the session."*
 *
 * He opened the `…`, found nothing under it, and had to leave for the Browser
 * tab and open a window before the session's own menu had anything in it. That
 * is the walk the menu was added to delete, so the rule is now split in two:
 * `showsAttach(canDrive:)` decides whether the section exists at all — the
 * machine, and nothing about its windows — and `attachable` decides which
 * already-open windows go in it. A section with no window in it still has the
 * row that opens one.
 *
 * ## The three things a session can be handed, and they are one flat list
 *
 *  1. **A window the machine already has open** — `attachable`, bound by
 *     `bindMachineWindow`. Free, instant, and it *moves* the window off whoever
 *     had it, which is why the row says so.
 *  2. **A page this phone is already showing** — `phonePages`, opened again on
 *     the machine at the same address and bound in one ask. This is the honest
 *     half: the phone's own web view cannot be handed to an agent, ever. What the
 *     session gets is a *second* window, on the machine, with the machine's
 *     cookies and the machine's logins — which may not even be signed in the same
 *     way. Nothing on the row says so any more, because a row is a name; every
 *     string that *is* read at length still says it.
 *  3. **A new window, opened for this session** — `newWindow`, one row at the end
 *     after a divider. One ask: `openMachineWindow(session:)` makes the host open
 *     the window and bind it *before* it answers, because an open answers with
 *     the window list and a client that had to pick its own new row out of that
 *     list races every other open in flight. `browser-control.ts` checks the
 *     session is really running first and refuses in a sentence if it is not, so
 *     a window is never left on somebody's screen for a session that does not
 *     exist.
 */
enum SessionWindowPicker {

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

    /// The name and the holder, before anything is done about two rows saying the
    /// same thing. Split out so the numbering below can be decided against the
    /// row a person actually reads rather than against the name inside it.
    private static func plain(_ window: MachineWindow, session: String) -> String {
        let name = WindowNames.name(window)
        guard let holder = holder(window, session: session) else { return name }
        return "\(name) · \(holder)"
    }

    /**
     * The row: the window, and who it would be taken from.
     *
     * Numbered only where the row would otherwise be **identical** to another
     * one in the same list — which is the state that made the menu unusable:
     * *"we see another name of the window"*, two of them reading `about:blank`
     * before either of them had a name a person could read,
     * and nothing to choose between them. The number goes on the name rather
     * than at the end, so a numbered row still reads as a name followed by its
     * holder.
     */
    static func row(_ window: MachineWindow, among windows: [MachineWindow],
                    session: String) -> String {
        let mine = plain(window, session: session)
        let same = windows.filter { plain($0, session: session) == mine }
        guard same.count > 1, let place = same.firstIndex(where: { $0.id == window.id }) else {
            return mine
        }
        let numbered = "\(WindowNames.name(window)) \(place + 1)"
        guard let holder = holder(window, session: session) else { return numbered }
        return "\(numbered) · \(holder)"
    }

    // MARK: - Whether the section exists at all

    /**
     * Whether *Attach a browser window* is drawn.
     *
     * **The machine, and nothing about its windows.** This is the whole of the
     * correction in the header above, and it is one line because the defect was
     * one line: both menus tested `!attachable(...).isEmpty`, so on a machine
     * with no browser window open — an ordinary laptop, most of the time — the
     * `…` he opened had nothing under it, and the only way to get a window onto
     * a session was to leave for the Browser tab first.
     *
     * A drivable machine can always be asked for a new window, so there is
     * always something honest to put here. A machine that will not be driven
     * still gets nothing: every row in this section ends in a frame that machine
     * refuses at the source, and this app does not draw a control that can only
     * produce a refusal.
     */
    static func showsAttach(canDrive: Bool) -> Bool { canDrive }

    // MARK: - Opening a new one for this session

    /**
     * The one row that makes a window instead of borrowing one.
     *
     * Two words. It was *"Open a window for this session"* with *"Open one signed
     * into nothing"* under it, and he read both out as the point where the menu
     * stopped making sense — a row explaining what it is for, beside a second row
     * disagreeing with it about a profile, in a list whose other rows are names.
     *
     * The section header already says these rows attach a browser window, and the
     * divider above this one already says it is not one of the machine's. What is
     * left for the row itself to carry is what it makes, which is a new window.
     *
     * No address: the New window sheet's Open is not disabled for an empty field
     * either, because a blank window is a real thing to want — it is the browser,
     * waiting, on the machine, already belonging to this session. Wherever the
     * agent sends it next is one `go` away.
     */
    static let newWindow = "New window"

    /// What the row means, in one line, for a screen reader and for anybody who
    /// holds the row down. A hint is read on request and is not drawn, which is
    /// the only reason a sentence is allowed to survive anywhere near this menu.
    static func newWindowMeaning(machine: String) -> String {
        "Opens a window in \(machine)'s own browser, signed in the way \(machine) is."
    }

    /// What the phone says while the machine is opening it. The machine's own
    /// answer replaces it — `browser.window.rows` comes back carrying the bind
    /// notice, which is the confirmation that counts.
    static func opening(machine: String) -> String {
        "Opening a window on \(machine) and attaching it to this session."
    }

    // MARK: - A page this phone is already showing

    /**
     * The pages this phone has open **on this machine**.
     *
     * > *"And these three dots, we should have this attachment thing for all of
     * > them, properly working, and the same way on the sessions side also."*
     *
     * The Browser tab's row menu can do this now; the sessions side could not do
     * it at all, and the sessions side is where he was looking when he said it.
     *
     * Filtered by host on the way through, and that is not belt-and-braces.
     * `BrowserTabs.tabs(on:)` answers for whichever machine is **current**, and
     * a session screen is opened for a named machine — `TerminalScreen.hostID`
     * exists precisely because session ids are not unique across machines. On
     * the one frame where those two disagree, an unfiltered list would offer to
     * open another machine's `localhost:3000` on this one, which is a different
     * program's page handed to an agent with no way to tell.
     */
    static func phonePages(_ tabs: [BrowserTab], on host: String, canDrive: Bool) -> [BrowserTab] {
        guard canDrive, !host.isEmpty else { return [] }
        return tabs.filter { $0.host == host }
    }

    /**
     * The address the machine has to be given.
     *
     * `String(port)` and never the `Int` interpolated: a port dropped straight
     * into a Swift string is formatted with the locale's grouping separator and
     * comes out as `localhost:3,000`. Measured, and the third copy of this
     * expression in the app to be caught by it.
     */
    static func address(_ tab: BrowserTab) -> String {
        "http://localhost:\(String(tab.port))\(tab.path)"
    }

    /**
     * The row: the page, by whatever it calls itself.
     *
     * `label` is the page's own title, or its address until it has one — and the
     * address is the fallback rather than *Untitled* on purpose. `WindowNames`
     * calls a window with nothing in it Untitled because a window on the machine
     * really can be on no page at all; a page open on this phone is always at an
     * address somebody typed, and *Untitled* over three of his own dev servers
     * would tell him which of them he was looking at exactly as well as
     * `about:blank` did. Ugly and specific beats tidy and identical, which is the
     * same rule `WindowNames` follows for a window that has an address and no
     * title.
     */
    static func phoneRow(_ tab: BrowserTab) -> String { tab.label }

    /**
     * What pressing one of those rows means — on the **hint**, and no longer over
     * the rows.
     *
     * There was a section header here reading *"Open again on DESKTOP-DDGMNCV —
     * the page here stays"*, and he read it out as one of the things he could not
     * understand. It was carrying a fact this feature must never get wrong: the
     * page on the phone does not move and cannot — it is drawn here, its cookies
     * are this app's, and no agent can reach it. What opens is a second window,
     * on the machine, at the same address.
     *
     * The fact is kept and the header is not. It is on the row's hint, and it is
     * in `openingPhonePage`, which is what the phone says **after** the press —
     * read once, deliberately, rather than scanned over a list of names every
     * time the menu opens.
     */
    static func phoneMeaning(machine: String) -> String {
        "Opens this page again in \(machine)'s browser and attaches that window to this session. "
            + "The page open here does not move."
    }

    /// What the phone says while that is happening. Longer than a row because it
    /// is read once, after a press, rather than scanned in a menu.
    static func openingPhonePage(_ tab: BrowserTab, machine: String) -> String {
        "Opening localhost:\(String(tab.port)) in \(machine)'s browser and attaching that window "
            + "to this session. The page open here does not move."
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
    /// There is something in the pane. Pressing puts it away and stops nothing:
    /// the window stays open, the binding stays, the agent carries on, the cast
    /// keeps running.
    case fold
    /// The pane is shown and nothing is arriving. Pressing asks the machine for
    /// the page again, which is the way back from a cast something else stopped
    /// **without leaving the session** — leaving and coming back always rebuilt
    /// the canvas, and finding that out is not a thing to make somebody do.
    case askAgain

    /// The three words, in one place, because a test can only tell the acts
    /// apart by reading the label: one identifier carries all three.
    static let showLabel = "Show the page"
    static let hideLabel = "Hide the page"
    static let askLabel = "Ask for the page again"

    static func verb(folded: Bool, showing: Bool, castable: Bool) -> SessionPageVerb {
        /*
         * **Folded is always *show*, with no exception left.**
         *
         * There was one: a machine that would never cast anything answered
         * `.nothing`, the strip drew no control at all, and the sentence was
         * drawn through the fold instead. The argument was that there is nothing
         * to unfold *to*. It is wrong twice over, and he found both halves.
         *
         * The first is that a pane holding a sentence and no control is a header
         * he cannot get past — the sentence cannot be put away, and the strip he
         * is looking at has stopped offering the one thing a strip offers.
         *
         * The second is what he actually filmed. `castable` is
         * `isLive && watch.offered`, both of which move on their own: a socket
         * that has just dropped takes the control off a pane he folded a second
         * ago, so the way back up disappears and comes back on its own, which
         * from the outside is a button that has stopped working. *"I can not
         * open it back once if I close it."*
         *
         * So the fold is always reversible. Unfolding onto no picture is not a
         * dead end any more, because the stage now says what is happening in a
         * line — `SessionPageStage` — and that line is a real change on the
         * screen.
         */
        if folded { return .show }
        /*
         * Shown, with a cast running: the fold. Shown with none: *ask again*
         * where the machine could still answer, and the fold where it will not,
         * because on that machine there is nothing to ask **and the sentence in
         * the pane still has to be closable**. An unfoldable pane and an
         * un-foldable one are the same defect from opposite ends.
         */
        if showing { return .fold }
        return castable ? .askAgain : .fold
    }
}

/**
 * What a press for the page does about the canvas — and the one fact it is not
 * allowed to read.
 *
 * > *"but it is still not opening after closing"*
 *
 * ## Why this is a type with one case in it
 *
 * This is the third round on that sentence and the second time the same wrong
 * idea has been fixed in one place and left standing in another. The idea is
 * that `WatchLink.isCasting` means *there is a picture*. It does not: it is *a
 * `browser.watch` of ours left, and something registered to draw the answer* —
 * both true the instant a canvas mounts, and both still true through a fold,
 * because the canvas is deliberately kept mounted at zero height so the fold does
 * not stop the cast.
 *
 * Round two found that where the pane **reads** state and answered it with
 * `hasPicture`. It did not look at where the pane **acts**, and there the same
 * fact was standing as a guard in front of `recast()`:
 *
 *     guard let page = surface?.window, host?.watch.isCasting(page) != true else { return }
 *
 * Which is why *Show the page* put the words *Asking for the page…* on the screen
 * and then asked for nothing at all, for ever, on a page that had no reason to
 * repaint.
 *
 * So the rule is not written as a line inside a method any more. It takes
 * `isCasting` and **never reads it**, on purpose, so that the parameter list says
 * what the rule refuses to depend on and `SessionPageTests` can hold it there
 * across both values. A future round that decides some picture is worth leaving
 * alone has to add a case, which breaks the `switch` at the one call site and
 * fails a test whose name says what he asked for — rather than quietly reusing a
 * fact that has already cost him three reports.
 *
 * ## What it costs, said plainly
 *
 * An unfold renegotiates the cast now, so there is a beat of the asking line
 * before the picture instead of the picture being there already. That beat is
 * what *"reopening is instant"* used to buy, and it was being bought with a
 * guarantee this feature turned out not to have. A control that always works and
 * is sometimes half a second slow is not a trade — it is the only one of the two
 * that is worth shipping.
 */
enum SessionPageAsk: Equatable {
    /// Build a new canvas. It is the only thing that re-adopts
    /// `WatchLink.frameHandler` and the only thing that sends a fresh
    /// `browser.watch`, and a fresh watch is the only way pixels come back for a
    /// page that has no reason to repaint.
    case rebuildIt

    /// `isCasting` is taken and deliberately not read. See the header — the
    /// parameter is the point of the function.
    static func canvas(isCasting: Bool) -> SessionPageAsk { .rebuildIt }
}

/**
 * What the stage says when there is no picture in it.
 *
 * > *"browser window when it collapse it is not expanding back I can not open it
 * > back once if I close it inside a session in any session even co-pilot or any
 * > other normal session."*
 *
 * The one thing that had no words. `SessionPageVerb` decides what the control
 * does; this decides what the space under it says, and until the second review
 * that space could be four hundred and forty points of `Color.black` — over a
 * terminal whose own ground is black, on his theme, under an idle session. He
 * pressed, the app changed state correctly, and the screen did not move.
 *
 * Four facts, four lines, and no state without one:
 *
 *  - **A socket that has gone.** Said first, ahead even of a picture: a page
 *    frozen on the last frame that arrived is worth being told about, because
 *    everything on it is as stale as the connection.
 *  - **A picture.** No line at all — the page is the answer.
 *  - **A machine that does not offer its browser for watching.** Nothing about
 *    this window; the capability is simply not on the wire.
 *  - **A window that is not being cast.** Ordinary rather than exceptional: a
 *    server mints a window through `openForSession(NO_SESSION)` and detaches it
 *    in the same breath, so it holds no binding row and `castWindows` cannot see
 *    it. The strip above still names the page the agent is on, which is the part
 *    worth knowing.
 *  - **A question of ours in flight.** Either a cast the wire believes is
 *    running, or a press two seconds old — see `SessionPageView.markAsking` for
 *    why a press has to be visible even when the answer is *no change*.
 *
 * A decision and not a layout, so it is pinned in `SessionPageTests` without a
 * simulator: every line here is the difference between a person knowing why
 * there is no page and a person deciding the app is broken.
 */
enum SessionPageStage: Equatable {
    case picture
    case asking
    case notCast
    case noWatching
    case offline

    static func stage(hasPicture: Bool, asked: Bool, live: Bool, offered: Bool) -> SessionPageStage {
        if !live { return .offline }
        if hasPicture { return .picture }
        if !offered { return .noWatching }
        return asked ? .asking : .notCast
    }

    /// The line, or nothing at all where the page is its own answer.
    var line: String? {
        switch self {
        case .picture: return nil
        case .asking: return "Asking for the page…"
        case .notCast: return "This window is not being cast."
        case .noWatching: return "This machine does not offer its browser for watching."
        case .offline: return "Not connected to this machine."
        }
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
 * leaves ten rows of terminal visible on the shortest phone this app supports,
 * which is the number that matters: a split where the terminal has vanished is
 * not a split, it is a page with a strip on it. *Visible* rather than *left* —
 * the page floats over the session now, so the terminal keeps every row it had
 * and this decides how many of them are covered.
 */
private enum SessionPageRoom {
    static let splitCap: CGFloat = 440
}
