/**
 * **The settings of one browser window — one screen, one title, one order of
 * cards, whichever machine is drawing the pixels.**
 *
 * > *"When we click on three dots then we can see the settings — per window
 * > also, inside the window: settings of per window, how to connect to it, how
 * > to make it shared or isolated, all of these things should be inside of the
 * > window."*
 *
 * That sentence is what this file is for. The Browser tab's home lists windows
 * and nothing else; a row's `…` carries only what you do to a window from
 * outside it; and everything *about* a window is here.
 *
 * ## What he said the second time, which is what this round rebuilt
 *
 * > *"on Windows side so we have two separate kind of pages Windows page,
 * > windows settings and page settings both are like for the browser window I
 * > don't know why do you call one of them as page one of them as window since
 * > they both do the same thing … if it is open in local in this machine it is
 * > like page setting and if it is open in other server machine it calls as
 * > window it should not be like that"*
 *
 * > *"why do we even have two different than different versions of the browser
 * > settings and page setting kind of thing window setting thing. Why not like
 * > one name title should be same everything"*
 *
 * He is right and the two screens were not even close to each other. A window on
 * the machine drew *Window settings* over Isolation, Session, Screenshot, Click
 * flow, Close. A page on this phone drew *Page settings* over This page,
 * Session, Screenshot, Open somewhere else, Close — a different name, a
 * different first card, a card in the middle that existed nowhere else, and no
 * recorder at all. A page the machine casts without listing as a window drew a
 * third thing again: three cards, two of them a paragraph of apology.
 *
 * **So there is one screen now.** One title. Six cards, in this order, on every
 * shape a browser window can come in:
 *
 *  1. **Window** — what it is, where it is drawn, and what state it is in.
 *  2. **Privacy** — whose cookies it gets: Shared, or Private.
 *  3. **Session** — which agent can drive it.
 *  4. **Screenshot** — photograph it, and hand the picture to a session.
 *  5. **Click flow** — record what is clicked on it.
 *  6. **Close** — end it.
 *
 * A card that cannot act on this particular window is **greyed in its place**,
 * with the reason on its section's ⓘ — never missing, and never a paragraph on
 * the screen. `cards` is six calls in a fixed order and each of those six
 * switches inside itself, which is the structural guarantee: there is no branch
 * of this file that can draw a differently shaped screen from another branch,
 * because there is no branch that decides which cards exist.
 *
 * **Privacy is the one card with a shape it is not drawn on**, and that
 * exception is argued where it is made — see `privacyCard`. In one line: a page
 * this phone is drawing is not in the machine's browser, so there is no jar to
 * move it between, and everything that card used to hold on that shape was two
 * rows that opened a *new* window somewhere else.
 *
 * ## The words are the ones every browser already uses
 *
 * > *"lets make only one name as browser and window identical to normal
 * > standards for browser everything else too"*
 *
 * *Isolated* was this codebase's word for a throwaway profile and it was never
 * anybody else's: Safari and Firefox both say **Private**. So does this screen
 * now — the state, the button, the marks and every sentence on an ⓘ. A window
 * with no page in it is **Untitled** rather than the literal `about:blank`, the
 * screen is **Window settings** whatever it is showing, and attaching is
 * **Attach to a session**.
 *
 * **The wire is untouched.** `MachineWindow.isolated` is a `Bool` on the frame,
 * `Act.isolate` is a verb the host parses, and the identifiers under these
 * controls keep the names the suites already ask for. Renaming any of those to
 * fix an English word would be a protocol change and a suite that skips instead
 * of failing. What changed is what he reads.
 *
 * ## Nothing on this screen opens a window somewhere else any more
 *
 * > *"we also dont need extra options of openinig new window like this way like
 * > open islolated and other from inside a window"*
 *
 * His screenshot of this screen, on a page this phone was drawing, had four rows
 * on it that all did the same thing: *Open on DESKTOP-DDGMNCV*, *Open isolated*,
 * *Attach a window*, *Attach an isolated window*. Every one of them made a
 * **new** window somewhere else, on a screen that is about **this** window. The
 * two openers are gone, the two attaches are one row — **Attach to a session** —
 * and the honest thing still happens underneath it, said once on the Session
 * card's ⓘ rather than spelled out as a second row.
 *
 * Nothing he can do disappeared with them. Making a new window is the `+` on the
 * Browser tab, which offers all three destinations including a private one, and
 * the row menus out on that list still attach.
 *
 * ## Where the page really is, is one line rather than a different screen
 *
 * A page this phone is drawing is not a window in the machine's browser, and
 * that fact changes what four of these cards can do. It is said once, as a mark
 * on the Window card — **On this phone** — and after that it is a reason on the
 * ⓘ of whichever card it limits. It is not a different title, a different order,
 * or a card that only that shape has.
 *
 * ## Every row is a title, and that is all
 *
 * > *"you are giving too much space to the options to the features so all the
 * > list and drop downs becoming too bigger because the you are also putting so
 * > much of a description under the title of that thing under the title of the
 * > feature instead of just i button or nothing maybe so they have becomes too
 * > big you should compact all the features or buttons and without losing any of
 * > them"*
 *
 * > *"many of the even buttons. Are so much of confusing I can't understand what
 * > they mean"*
 *
 * Every row on this screen used to carry a second grey line explaining it —
 * *"Signed in the way DESKTOP-DDGMNCV is."*, *"Signed into nothing, and
 * forgotten when the window closes."*, *"The page stays open here, untouched.
 * What the session gets is …"*. He read those and could not tell the options
 * apart, which is the tell: a row that needs a sentence is a row with the wrong
 * name on it.
 *
 * So a row is its title and nothing else, the title is three or four words he
 * can point at, and the sentence that used to sit under it is on the section's
 * ⓘ where it can be read once by whoever wants it. Nothing was deleted — every
 * fact those lines carried is on an ⓘ, and the ⓘ is also the VoiceOver hint of
 * the control it belongs to, so nothing was lost for a screen reader either.
 *
 * ## The four shapes a browser window comes in, and why they are shapes and not
 * screens
 *
 * `WindowShape` resolves them once, at the top, off the live model:
 *
 *  - **A window on the machine.** Everything works.
 *  - **A page this phone is drawing** over a tunnel — `phoneTab` carries the
 *    tab's id and `windowID` is empty, because there is no window on the machine
 *    to name. It is the one shape with no Privacy card: it is not in that
 *    browser, so it is neither shared nor private and there is nothing to
 *    convert. Everything else is real on it, including the recorder — see below
 *    — and Attach opens the same address over there and binds that window.
 *  - **A page the machine is casting that its window list does not name** — the
 *    machine's own front tab, which `openTab` mints no shell id for. Most
 *    `browser.window.*` verbs are addressed by a window id and
 *    `src/main/remote/protocol.ts` refuses an empty one on every member of that
 *    family, so those cards are greyed. Attaching is the exception and it took
 *    two rounds to see: `browser.window.open` takes an **address** and carries a
 *    session, so this page's own address opens a new window over there and binds
 *    *that*.
 *  - **A page this phone had, that has since been closed.** One line, because
 *    nothing pops this screen.
 *
 * ## The recorder follows a page on this phone now
 *
 * > *"you are giving record flow button in the windows side the server side it
 * > and you are not giving that into the if they are browsing locally in this
 * > machine. So there are so many differences if they both are capable for a
 * > feature why don't they both have."*
 *
 * The last round argued the click recorder could not follow: it is the machine's
 * recorder (`src/main/browser-steps.ts`) watching the machine's own browser. The
 * premise was true and the conclusion was wrong — the phone owns a real
 * `WKWebView`, so the phone can watch its own page. `PhoneClickFlow` does that
 * and this screen draws it through exactly the same step rows the machine's
 * recorder gets, so the two look identical because they *are* the same list.
 *
 * ## A screen that contradicted itself, and how it was allowed to
 *
 * His screenshot of *Window settings* has the banner **"This machine's browser
 * cannot record a click flow."** with a live blue **"Record the click flow"**
 * eleven points underneath it. One of the two was lying, and it was the button.
 *
 * The mechanism, traced end to end: this screen asks `browser.window.steps` on
 * appear. A host with no recorder answers that — and `record.on`/`record.off` —
 * with `rows("This machine's browser cannot record a click flow.")`
 * (`src/main/remote/browser-control.ts`, and the headless host says the same
 * sentence). That lands as `MachineBrowserState.notice`, which the banner draws.
 * The card underneath was drawn unconditionally, because nothing on the wire
 * says *this machine has a recorder* — there is no capability field for it, and
 * a refusal only exists as a sentence in a notice.
 *
 * So the sentence is what this screen listens to. `recorderRefused` latches the
 * moment the machine says it, the card greys with that reason on its ⓘ, and the
 * banner stops repeating a fact that is now attached to the control it is about.
 * Matching a sentence across the wire is a real coupling and it is written down
 * rather than hidden: the phrase is one constant, it is matched as a substring
 * so the host may reword the rest of the line, and the honest fix is a capability
 * field — which is not this lane's file to add.
 *
 * ## The two screenshots are deliberately not one control
 *
 * > *"creating a screenshot and sending it to the session, whatever session we
 * > want to send."*
 *
 * Photographing a window to **look at it here** and photographing it to **hand
 * it to an agent** are different acts with different outcomes: the first answers
 * with a picture and the second answers with the window list and a notice,
 * because the picture went to the session rather than to the phone. Collapsing
 * them into one button with a destination picker behind it would make the common
 * case — look at it — a two-step, and would hide the fact that the interesting
 * case is the one where this phone receives nothing at all.
 *
 * ## It holds an id, never a window
 *
 * Every verb on this family answers with the **whole** window list, so a
 * `MachineWindow` captured when this screen appeared is stale the moment
 * anything on it is pressed — a binding made here would leave the slot badge
 * showing the old answer. The id is stable and the row is looked up on every
 * redraw. The same rule is why `phoneTab` is a tab **id**: a tab's title and
 * path move under it as the page navigates.
 *
 * Nothing here dismisses itself except Close on a page this phone owns — see
 * `closeCard`. `MachineWindowView` owns the single watcher that pops the pair of
 * screens when a machine window leaves the list. One watcher, because two would
 * race to pop the same stack.
 */

import SwiftUI
import UIKit
import WebKit

struct MachineWindowSettingsView: View {
    let model: DeckModel
    let windowID: String
    /// Whether this is its own screen, pushed from the `…` on a window that is
    /// being cast — or the body of the window's screen, on one that is not. It
    /// decides the title and the banner and **nothing else**: the cards are the
    /// same six either way, which is the whole of *"one name title should be
    /// same everything"*.
    let pushed: Bool

    /**
     * The page **this phone** is drawing, when that is what these settings are
     * about. Nil for every window on the machine.
     *
     * A tab **id**, never the tab, for the same reason `windowID` is an id and
     * not a `MachineWindow`: a tab's title and path move under it as the page
     * navigates, and a value captured when this screen appeared would name the
     * page somebody left two taps ago. It is resolved on every redraw.
     */
    var phoneTab: String? = nil

    /// Used by exactly one control — Close, on a page this phone is drawing.
    /// See `closeCard` for why that one and nothing else.
    @Environment(\.dismiss) private var dismiss

    /// The picture this phone took of its own page, and how that went. See
    /// `PhonePageShot` at the foot of this file for why the phone has to render
    /// the page again rather than photograph the one it was showing.
    @State private var phoneShot = PhonePageShot()

    /// What the last press asked for, held for a moment because the act it
    /// describes leaves nothing on this screen to look at. The same two and a
    /// half seconds every other silent act in this app holds a line for; it is a
    /// record of the **ask**, never a claim about an answer.
    @State private var sentLine: String?

    /// The optional line that travels with a screenshot handed to a session.
    /// Cleared on send, unlike an address field: it describes *that* picture, so
    /// leaving it standing would attach last shot's sentence to the next one.
    @State private var shotNote = ""

    /// The decoded picture, held rather than decoded in `body`.
    ///
    /// `UIImage(data:)` on a full-page PNG is milliseconds, and `body` runs on
    /// every keystroke in the note field — so decoding there is a decode per
    /// character for a picture that has not changed. Refreshed from the stamp
    /// below, which is cheap to compare; `MachineShot` is `Equatable` over its
    /// raw `Data`, so watching the value itself would be a byte-for-byte compare
    /// of a megabyte on every redraw.
    @State private var picture: UIImage?

    /**
     * Whether **this machine** has told us its browser has no click recorder.
     *
     * The fix for the screen that contradicted itself — see the file header for
     * the whole trace. There is no capability on the wire that says *this
     * machine can record*; the only evidence is the sentence the host puts in
     * `browser.window.rows.notice` when it refuses `record.on`, `record.off` or
     * `browser.window.steps`. This screen asks for steps on appear, so on a host
     * with no recorder that refusal arrives within one round trip of the screen
     * opening — which is exactly what his screenshot caught, with the banner
     * saying it and the button below still lit.
     *
     * It **latches** rather than tracking the notice, because a notice is
     * transient: the next plain window list clears it, and a card that ungreyed
     * itself a second later would be the same contradiction with a delay on it.
     * Reset when the machine changes, because it is a fact about one machine.
     */
    @State private var recorderRefused = false

    private var host: HostLink? { model.current }
    private var state: MachineBrowserState? { host?.machineBrowser }
    private var window: MachineWindow? { state?.windows.first { $0.id == windowID } }
    /// The cast of this page, when the machine is offering one. The only thing
    /// that exists for the machine's own front tab, which is in no window list —
    /// resolved here the same way `MachineWindowView` resolves it, off the live
    /// list rather than passed in, because the strip is pushed when it moves.
    private var surface: BrowserSurfaceRow? {
        host?.watch.surfaces.first { $0.window == windowID }
    }
    private var sessions: [WindowSession] { state?.sessions ?? [] }

    /// The tab these settings are about, resolved live. Nil once it has been
    /// closed, which is a real state this screen draws rather than a fault.
    private var tab: BrowserTab? { phoneTab.flatMap { model.browserTabs.tab($0) } }

    /// What to call the machine in a sentence somebody reads.
    private var machineName: String { model.current?.label ?? model.theMachine }

    /// Whether this machine will let this phone drive its browser at all. The
    /// gate on everything that opens a window over there.
    private var canDrive: Bool { host?.canDriveBrowser == true }

    /**
     * The sessions a picture can be handed to.
     *
     * `agentTargets` rather than the `sessions` list above, and the difference
     * matters here: that list comes off `browser.window.rows` and exists only on
     * a machine offering `browser.control`, while handing a file to a terminal
     * needs nothing of the sort. A phone that can tunnel to a machine with no
     * browser at all can still photograph the page and send it.
     */
    private var agentSessions: [RemoteSession] { host?.agentTargets ?? [] }

    /// What the machine's recorder collected for this window.
    private var steps: [RecordedStep] { host?.machineSteps[windowID] ?? [] }

    /// The recorder that watches a page **this phone** is drawing. The seam W6
    /// is built across: this file draws the card, `PhoneClickFlow` owns the
    /// watching, and both sides speak in `RecordedStep` so the rows below are
    /// literally the same rows the machine's flow gets.
    private var phoneFlow: PhoneClickFlow { .shared }

    /// Whether this machine will cast a window back at all — a different
    /// capability from the one every control here is gated on, negotiated in a
    /// different field of `RemoteEndpointOptions`. Asked of the connection as
    /// well as of the welcome, the way `HostLink.canDriveBrowser` is.
    private var canWatch: Bool { model.connection.isLive && host?.watch.offered == true }

    /// The last picture, if it is a picture of **this** window. One shot is held
    /// per machine, so a screenshot taken of another window while this screen was
    /// open would otherwise be drawn here under this window's name.
    private var shot: MachineShot? {
        guard let held = host?.machineShot, held.id == windowID else { return nil }
        return held
    }

    /// Identity of the held shot, for change detection. See `picture`.
    private var shotStamp: String? {
        shot.map { "\($0.id)@\($0.at)" }
    }

    /**
     * The phrase every host uses when it has no click recorder.
     *
     * `src/main/remote/browser-control.ts` and `src/headless/machine-browser.ts`
     * both answer *"This machine's browser cannot record a click flow."* — one
     * sentence, written twice, and nothing else on the wire carries the fact.
     * Matched as a **substring** rather than compared whole, so a host that
     * reworded the rest of the line still greys the card rather than silently
     * going back to a lit button over a banner denying it.
     */
    private static let noRecorderPhrase = "cannot record a click flow"

    /**
     * The machine's last word, minus the one sentence this screen now says in a
     * better place.
     *
     * A banner repeating *the browser cannot record a click flow* over a card
     * that is already greyed with that reason on its ⓘ is the same fact twice,
     * and it is the half of his screenshot that was telling the truth. The
     * control is where the fact belongs; the banner keeps everything else.
     */
    private var visibleNotice: String? {
        guard let notice = state?.notice, !notice.isEmpty else { return nil }
        if recorderRefused, notice.localizedCaseInsensitiveContains(Self.noRecorderPhrase) {
            return nil
        }
        return notice
    }

    /**
     * Which of the four shapes this is, decided once.
     *
     * Resolved at the top and handed to all six cards, rather than each card
     * asking the model its own question. That is what makes *"one name title
     * should be same everything"* structural instead of a promise: a card cannot
     * disagree with another card about what it is looking at, and nothing below
     * can add a seventh card for one shape only.
     */
    private enum WindowShape {
        /// A window in the machine's browser. Everything works.
        case machine(MachineWindow)
        /// A page this phone is drawing over a tunnel.
        case phone(BrowserTab)
        /// A page the machine is casting that its window list does not name —
        /// the machine's own front tab, most of the time.
        case cast(BrowserSurfaceRow)
        /// A page this phone had, closed while this screen was up.
        case gone
        /// Nothing has landed yet. Not the same answer as *nothing is there*.
        case unknown
    }

    private var windowShape: WindowShape {
        if phoneTab != nil { return tab.map { WindowShape.phone($0) } ?? .gone }
        if let window { return .machine(window) }
        if let surface { return .cast(surface) }
        return .unknown
    }

    var body: some View {
        screen
            .onAppear {
                /*
                 * Steps have no push and are not carried on the window list, so
                 * the only way to know what a recording has collected is to ask.
                 * Asked on arrival rather than only when a recording stops,
                 * because a window may already have been recording for ten
                 * minutes before anybody opened this screen.
                 *
                 * Not for a page this phone is drawing: that flow is
                 * `PhoneClickFlow`'s, held in this app, and `windowID` is the
                 * empty string, which the host refuses at the parser on every
                 * member of this family. Asking anyway would put a frame on the
                 * wire whose only possible answer is a refusal.
                 */
                if phoneTab == nil { host?.readMachineSteps(windowID) }
                noteRecorder(state?.notice)
                refreshPicture()
            }
            /*
             * A recording that has just stopped has steps worth reading, and
             * nothing else will say so: `.record.off` answers with the window
             * list, which carries `recording: false` and not a single step.
             * Watched as a transition rather than polled — the flag going false
             * is the event.
             */
            .onChange(of: window?.recording) { was, now in
                if was == true && now == false { host?.readMachineSteps(windowID) }
            }
            // The only way this phone ever learns the machine has no recorder.
            // See `recorderRefused`.
            .onChange(of: state?.notice) { _, now in noteRecorder(now) }
            // A different machine is a different browser, and its own answer
            // about whether it can record.
            .onChange(of: host?.id) { _, _ in recorderRefused = false }
            .onChange(of: shotStamp) { _, _ in refreshPicture() }
    }

    /// Latch the machine's refusal, if that is what it just said.
    private func noteRecorder(_ notice: String?) {
        guard let notice, notice.localizedCaseInsensitiveContains(Self.noRecorderPhrase) else {
            return
        }
        recorderRefused = true
    }

    /**
     * **One title, for every shape.**
     *
     * > *"Why not like one name title should be same everything"*
     *
     * It said *Window settings* over a window on the machine and *Page settings*
     * over a page on this phone, which is the split he read as two products. It
     * is a browser window either way — the list calls all three kinds a window,
     * the row's menu says *Close window*, and the card at the foot of this
     * screen says *Close this window*. So the title is the plain one that is
     * true of all of them and it does not branch.
     *
     * Only drawn when this is a screen of its own. Inline,
     * `MachineWindowView` has already named the window and a second title would
     * overwrite it with a less useful one.
     */
    @ViewBuilder
    private var screen: some View {
        if pushed {
            /*
             * The machine's last word, and it is drawn **only here** when this
             * is a screen of its own.
             *
             * The one outcome no redraw can show is a picture that went to a
             * session rather than to this phone — and the control that does that
             * is on this screen, so the sentence has to be on this screen too.
             * Pushed over the live page, the window's own banner is underneath
             * and invisible; inline, that banner is directly above these cards
             * and a second copy would be the same line twice.
             */
            VStack(spacing: 0) {
                if let notice = visibleNotice {
                    Banner(text: notice, tone: .neutral)
                        .accessibilityIdentifier("browser.machine.window.settingsNotice")
                }
                content
            }
            .background(Theme.background)
            .navigationTitle("Window settings")
            .navigationBarTitleDisplayMode(.inline)
        } else {
            content
        }
    }

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                cards
                TabBarClearance()
            }
            .padding(.horizontal, 16)
            .padding(.top, pushed ? 12 : 4)
            .padding(.bottom, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollBounceBehavior(.basedOnSize)
        .scrollDismissesKeyboard(.interactively)
    }

    /**
     * **The six cards, in one order, for every shape.**
     *
     * This is the answer to *"why do we even have two different than different
     * versions of the browser settings and page setting"*, and it is written as
     * six unconditional calls on purpose. There is no `if` here that could grow
     * a seventh card for one shape, and no branch that could reorder them: each
     * card is handed the shape and decides internally whether it can act — and
     * where it cannot, it draws itself greyed with the reason on its own ⓘ
     * rather than disappearing.
     *
     * One card takes itself off one shape and does it **inside itself**, which
     * is the same guarantee read from the other side: `privacyCard` is still
     * called here, unconditionally, in second place. What it draws for a page on
     * this phone is nothing, for the reason its own header gives. The order
     * cannot be rearranged from here and a card cannot be added from here, which
     * is what stops the two screens drifting apart again.
     *
     * The two states that are not a window at all are the exceptions and they
     * are exceptions to *there being a window*, not to the order: a page that
     * has been closed has nothing to configure, and a list that has not landed
     * is not the same answer as an empty one.
     */
    @ViewBuilder
    private var cards: some View {
        switch windowShape {
        case .gone:
            /*
             * Closed while this screen was up — usually by the Close card,
             * because nothing else pops this screen.
             *
             * `MachineWindowView` owns the one watcher that pops a window's pair
             * of screens when the machine stops listing it, and there is no such
             * watcher for a tab this phone owns. Saying the page is gone is
             * better than popping out from under a thumb.
             */
            SchemeSectionCaption("Window")
            SchemeGroup {
                plainNote("This page is closed.", id: "browser.phone.page.gone")
            }
        case .unknown:
            ProgressView()
                .controlSize(.regular)
                .frame(maxWidth: .infinity)
                .padding(.top, 40)
                .accessibilityIdentifier("browser.machine.window.settingsLoading")
        default:
            windowCard
            privacyCard
            sessionCard
            screenshotCard
            clickFlowCard
            closeCard
        }
    }

    /* ---- 1. what this window is -------------------------------------------- */

    /**
     * **The one card that says which window this is, and where it is drawn.**
     *
     * It replaces three different first cards: a page on this phone had *This
     * page* with a title, an address and a mark; a cast with no window row had
     * *This page* with a paragraph of apology under it; and a window on the
     * machine had **nothing at all** — it opened straight onto Isolation, so the
     * two screens did not even begin the same way.
     *
     * Three facts, in the same three places every time: the window's name, its
     * address, and a row of marks. The marks are where *"if it is open in local
     * in this machine"* is said — one word-sized capsule, **On this phone** or
     * **On DESKTOP-X** — rather than a second screen with a second name.
     *
     * ## And the sentence about watching is a mark now
     *
     * A window the machine will not cast used to get its own card and its own
     * grey line: *"This machine is not offering this window for watching."* It
     * was drawn only in the inline shape, which meant the screen behind the `…`
     * and the screen you land on when there is no `…` had a card between them
     * that differed. It is **No live picture** here, on the same row as
     * everything else this window is, and the reason is on this card's ⓘ.
     *
     * Drawn only where it answers a question somebody is holding — an inline
     * screen on a machine that casts other windows. A host that never offered a
     * cast (every shipped build before this wave, and the public demo box, which
     * passes no `screencast` engine on purpose) is not withholding anything, and
     * a mark about a cast there is an apology for a feature that was never on
     * the table.
     */
    @ViewBuilder
    private var windowCard: some View {
        SchemeSectionCaption("Window", about: "this window", info: windowInfo)

        SchemeGroup {
            VStack(alignment: .leading, spacing: 4) {
                Text(windowTitle)
                    .font(.system(size: 16))
                    .foregroundStyle(Theme.primary)
                    .lineLimit(1)
                    .accessibilityIdentifier(idPrefix + ".title")

                if !windowAddress.isEmpty {
                    Text(windowAddress)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(Theme.faint)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        /*
                         * `.url` and not `.address`. `BrowserPageBar` names its
                         * editable field `\(id).address`, and on a window the
                         * machine will not cast that bar and these cards are the
                         * **same screen** — two elements answering to one
                         * identifier, one a text field and one a label. A query
                         * that did not also filter by element type would pick
                         * whichever the tree happened to hand back first.
                         */
                        .accessibilityIdentifier(idPrefix + ".url")
                }

                HStack(spacing: 6) {
                    ForEach(windowMarks, id: \.text) { mark in
                        MachineWindowMark(text: mark.text, tone: mark.tone)
                            .accessibilityIdentifier(mark.id)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.top, 2)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 13)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// A capsule on the Window card. `id` so a mark that is a *state* — being
    /// watched, not being cast — can be asserted, which a sentence in a
    /// `ContentUnavailableView` never could.
    private struct WindowMark {
        let text: String
        let tone: Color
        let id: String
    }

    /// What this window is called. The page's own title wherever there is one,
    /// for the reason `MachineWindow.label` prefers it: *Untitled* tells nobody
    /// which of their windows they are looking at.
    private var windowTitle: String {
        switch windowShape {
        // `WindowNames`, never `window.label`. `label` answers the literal
        // `about:blank` for a window with no page in it — jargon, and the same
        // six characters for every blank window, so the title of these settings
        // would not say which window they are the settings of. `WindowNames` is
        // the one rule for that name in this app and the Browser tab's row calls
        // the same function, so a window is not `about:blank` on one screen and
        // Untitled on the next.
        case let .machine(window): return WindowNames.name(window)
        case let .phone(tab): return tab.label
        case let .cast(surface): return MachineBrowserText.surfaceLabel(surface)
        case .gone, .unknown: return ""
        }
    }

    /// Where it is, as an address. Empty is a real answer — a blank window has
    /// none — and the row is simply not drawn rather than showing a placeholder
    /// in the line that says *where you are*.
    private var windowAddress: String {
        switch windowShape {
        // `label` rather than the title drawn above, deliberately: `label` is
        // `title.isEmpty ? url : title`, so this is empty exactly when the
        // window has no title of its own — which is the case a blank window is.
        // Comparing against `WindowNames.name` instead would draw `about:blank`
        // under *Untitled*, because the name differs from the url by
        // construction. The Browser tab's row makes the same comparison.
        case let .machine(window): return window.url == window.label ? "" : window.url
        case let .phone(tab): return phoneAddress(tab)
        case let .cast(surface): return surface.url
        case .gone, .unknown: return ""
        }
    }

    /**
     * The facts a settings screen cannot leave implicit, as capsules.
     *
     * Whose renderer draws it comes first and is on every shape, because that is
     * the difference he asked to stop being a different screen. The rest are
     * states somebody can be left in without meaning to — a recording running, a
     * window signed into nothing, a page being watched — which is exactly what
     * the row on the Browser tab marks and for the same reason.
     *
     * **And the first capsule's words are `MachineBrowserText`'s now**, not two
     * literals here. That list had only ever drawn one half of the pair — *On
     * this phone* on a tunnel row, nothing at all on a machine's — and the round
     * that gave it the other half (*"there is no clarity"*) is the round that
     * made a drift between this screen and the row that opens it possible for the
     * first time. See `MachineBrowserText.onMachine`.
     */
    private var windowMarks: [WindowMark] {
        var marks: [WindowMark] = []
        switch windowShape {
        case let .machine(window):
            marks.append(WindowMark(text: MachineBrowserText.onMachine(machineName),
                                    tone: Theme.secondary,
                                    id: "browser.machine.window.where"))
            if let slot = window.slot {
                marks.append(WindowMark(text: slot, tone: Theme.accent,
                                        id: "browser.machine.window.slot"))
            }
            if surface?.live == true {
                marks.append(WindowMark(text: "Live", tone: Theme.positive,
                                        id: "browser.machine.window.live"))
            }
            if window.isolated {
                // **Private**, and the identifier stays `isolatedMark`. The word
                // is what he reads; the identifier is what a suite asks for, and
                // a renamed identifier is a case that skips rather than fails.
                marks.append(WindowMark(text: "Private", tone: Theme.secondary,
                                        id: "browser.machine.window.isolatedMark"))
            }
            if window.recording {
                marks.append(WindowMark(text: "Recording", tone: Theme.critical,
                                        id: "browser.machine.window.recordingMark"))
            }
            /*
             * The line that used to be a card of its own, and only in one of the
             * two shapes of this screen. See the card's header: it is drawn only
             * where the question *why am I looking at settings instead of at the
             * page* actually exists.
             */
            if !pushed && canWatch && surface == nil {
                marks.append(WindowMark(text: "No live picture", tone: Theme.faint,
                                        id: "browser.machine.window.notWatchable"))
            }
        case let .phone(tab):
            marks.append(WindowMark(text: MachineBrowserText.onThisPhone,
                                    tone: Theme.secondary,
                                    id: "browser.phone.page.where"))
            if phoneFlow.isRecording(tab: tab.id) {
                marks.append(WindowMark(text: "Recording", tone: Theme.critical,
                                        id: "browser.phone.page.recordingMark"))
            }
        case let .cast(surface):
            marks.append(WindowMark(text: MachineBrowserText.onMachine(machineName),
                                    tone: Theme.secondary,
                                    id: "browser.machine.window.where"))
            if surface.live {
                marks.append(WindowMark(text: "Live", tone: Theme.positive,
                                        id: "browser.machine.window.live"))
            }
        case .gone, .unknown:
            break
        }
        return marks
    }

    /**
     * The ⓘ on the Window card: everything the old first cards said in prose.
     *
     * Nothing here is new writing. It is the paragraph that used to sit under
     * *This page*, the sentence that used to be its own card about watching, and
     * the id explanation that used to head three greyed rows — collected behind
     * one dot, on the card whose subject they all are.
     */
    private var windowInfo: String {
        switch windowShape {
        case .machine:
            var text = "A window in \(machineName)'s browser. It uses \(machineName)'s cookies "
                + "and whatever it is signed into, unless it is private."
            if !pushed && canWatch && surface == nil {
                text += "\n\n\(machineName) is not offering this window for watching, which is why "
                    + "these settings are the screen rather than a live picture. It is a real "
                    + "state and not a fault: a server offers its own front tab and the windows "
                    + "its sessions hold, and one opened from the + here can be driven without "
                    + "being watched."
            }
            return text
        case .phone:
            return "This page is drawn by this app, over a tunnel to \(machineName). It is not a "
                + "window in \(machineName)'s browser, so it has its own cookies and its own "
                + "logins — someone signed into a dev server here may not be signed in over "
                + "there.\n\nEverything on this screen works on it. Where a control has to act "
                + "inside \(machineName)'s browser, it opens this same address there as a new "
                + "window and acts on that one — the page here is never moved or changed."
        case .cast:
            let which = windowID.isEmpty
                ? "This is \(machineName)'s own tab rather than one of its windows."
                : "\(machineName) is casting this page and its window list does not name it."
            // The clause about typing an address is kept for the empty-id case
            // and only for it. The machine's own front tab is where a page
            // opened from the phone's address bar lands, so an address really is
            // one of the two things it takes; a cast the window list simply
            // cannot be joined to takes only the watching, and saying otherwise
            // would be a sentence offering a control that is not there.
            let takes = windowID.isEmpty
                ? "Watching it and typing an address are what it does take."
                : "Watching it is what it does take."
            return which + " The machine names each of its windows with an id, and closing, "
                + "photographing, recording and making one private are all addressed by that id — "
                + "so none of those can be sent for this page.\n\n" + takes
                + " Its address can still be opened on \(machineName) as a new window, and that "
                + "window has an id and can be attached to a session."
        case .gone, .unknown:
            return ""
        }
    }

    /// The identifier family this shape's controls belong to. Two prefixes and
    /// not three: a page this phone draws is its own family because
    /// `LocalhostUITests` reaches `browser.phone.page.close` by name, and both
    /// machine shapes have always shared `browser.machine.window.`.
    private var idPrefix: String {
        if case .phone = windowShape { return "browser.phone.page" }
        return "browser.machine.window"
    }

    /* ---- 2. shared or private ---------------------------------------------- */

    /**
     * **Whose cookies this window gets: Shared, or Private.**
     *
     * *"Making a browsing session into an isolated or shared one."*
     *
     * ## The word is Private, because that is the word browsers use
     *
     * > *"lets make only one name as browser and window identical to normal
     * > standards for browser everything else too"*
     *
     * *Isolated* is this codebase's word for a profile signed into nothing and
     * thrown away afterwards, and it was never anybody else's. Safari says
     * Private, Firefox says Private, Chrome says Incognito — not one of them says
     * isolated. So somebody who has used a browser already knows what a private
     * window is, and had to be taught what an isolated one was. The caption is
     * **Privacy**, the two states are **Shared** and **Private**, and the button
     * is **Make private** or **Make shared**.
     *
     * The `Bool` on the wire is still `isolated` and the verb the host parses is
     * still `Act.isolate`, deliberately: renaming those would be a protocol
     * change to fix an English word, and it would land in a build where the
     * desktop is not being rebuilt in the same batch. The identifier under the
     * button is still `browser.machine.window.isolation` for the same class of
     * reason — a renamed identifier is a suite that skips instead of failing.
     *
     * ## And this card is drawn only where it is a real toggle
     *
     * > *"we also dont need extra options of openinig new window like this way
     * > like open islolated and other from inside a window"*
     *
     * On a page **this phone** is drawing, this card used to hold two rows —
     * *Open on DESKTOP-DDGMNCV* and *Open isolated* — and neither was about the
     * window in front of him. Both made a **new** window somewhere else, from a
     * screen whose entire subject is this one. He counted them together with the
     * two on the Session card that did the same thing and asked for all four to
     * go.
     *
     * Taking them out leaves this card with nothing to draw on that shape, and
     * that is not a gap to be filled: a page on this phone is not in the
     * machine's browser at all, so there is no jar to move it between and no
     * state here to report. So on that one shape the card is **absent** rather
     * than greyed.
     *
     * That is a deliberate departure from this screen's own rule — *a card that
     * cannot act is greyed in its place, never missing* — and it is made here and
     * nowhere else. The rule exists so that a control somebody is hunting for is
     * never silently gone. There is no control here to hunt for: a greyed *Make
     * private* over a page that was never in that browser would be a control
     * invented so that a card could keep its slot, which is the same dishonesty
     * the rule was written against, pointing the other way.
     *
     * A cast the machine's window list does not name keeps the card, greyed.
     * That page really **is** in the machine's browser — it is that browser's own
     * front tab — and the only thing between it and this verb is a window id the
     * host refuses when it is empty. A control that exists and cannot be sent is
     * exactly what greying is for.
     *
     * ## The word on the button is the destination, not the state
     *
     * A button saying *Private* beside a label saying *Shared* is two readings of
     * one word and somebody presses it to find out which. So the label is where
     * this window is and the button is where it goes.
     */
    @ViewBuilder
    private var privacyCard: some View {
        switch windowShape {
        case let .machine(window):
            privacyCaption

            SchemeGroup {
                HStack(spacing: 10) {
                    Text(window.isolated ? "Private" : "Shared")
                        .font(.system(size: 16))
                        .foregroundStyle(Theme.primary)
                    /*
                     * The profile as a capsule rather than as a second line
                     * under the state. It is a **name** — the Chromium partition
                     * this window runs in — and a name beside the state reads at
                     * a glance, where the same name underneath it read as one
                     * more grey explanation.
                     */
                    if let profile = window.profile, !profile.isEmpty, !window.isolated {
                        MachineWindowMark(text: profile, tone: Theme.secondary)
                    }
                    Spacer(minLength: 8)
                    Button {
                        host?.actOnMachineWindow(windowID, window.isolated ? .share : .isolate)
                    } label: {
                        Text(window.isolated ? "Make shared" : "Make private")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(Theme.accent)
                            .padding(.vertical, 4)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("browser.machine.window.isolation")
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 13)
            }

        case .cast:
            /*
             * Greyed rather than absent, which is the opposite call from the
             * one the next case makes for a page on this phone. The difference
             * is not a preference, it is whether the control exists at all: this
             * page **is** in the machine's browser and could be made private if
             * the machine had given it an id, so the control is real and cannot
             * be sent. A page on this phone is not in that browser, so there is
             * nothing there to grey.
             */
            privacyCaption

            SchemeGroup {
                deadRow("Make private", icon: "eye.slash",
                        id: "browser.machine.window.isolation",
                        why: "This page has no window id for the machine to address.")
            }

        case .phone, .gone, .unknown:
            EmptyView()
        }
    }

    /// The caption, written once so the two shapes that draw this card cannot
    /// come to head it differently. `about:` is what the ⓘ answers to —
    /// `info.private-windows` — and it changed with the word, because the dot is
    /// read by its label and there is no suite outside this file asking for it.
    private var privacyCaption: some View {
        SchemeSectionCaption("Privacy", about: "private windows", info: privacyInfo)
    }

    /// The ⓘ on Privacy: the difference between the two jars, and — where the
    /// card is greyed — why. One string, because a control's reason and a
    /// section's explanation are the same sentence read from two directions.
    ///
    /// There is no `.phone` branch, and its absence is the point: that shape
    /// draws no card, so a sentence written for it would be an explanation
    /// nobody can reach. The two shapes left are the two that draw it.
    private var privacyInfo: String {
        let jars = "A shared window uses \(machineName)'s own profile — its cookies and whatever "
            + "it is signed into. A private one gets a partition of its own, and that partition "
            + "is thrown away when the window closes."
        switch windowShape {
        case .cast:
            return "The machine names each of its windows with an id and addresses this by it. "
                + "This page is one the machine's window list does not name, so it cannot be "
                + "moved between jars from here.\n\n" + jars
        case .machine, .phone, .gone, .unknown:
            return jars
        }
    }

    /* ---- 3. which session owns it ------------------------------------------ */

    /**
     * **Which agent can drive this window** — *"how to connect to it"*, the
     * headline of this screen and the reason this family exists at all.
     *
     * > *"We don't have an option to connect any browsing window to any session,
     * > so the session knows which browsing window it is working on."*
     *
     * A bound window gets a slot name — `B1`, `B2` — and the session's tools
     * address it by that name, which is why the slot is drawn as an identifier
     * rather than as a status: it is the word appearing in that agent's
     * transcript.
     *
     * ## One row, called Attach to a session, on every shape
     *
     * > *"lets make only one name as browser and window identical to normal
     * > standards for browser everything else too"*
     *
     * > *"we also dont need extra options of openinig new window like this way
     * > like open islolated and other from inside a window"*
     *
     * This card carried **two** attach rows on the two shapes that cannot bind
     * the page they are about — *Attach a window* and *Attach an isolated
     * window* — and they were two of the four rows he counted on one screen that
     * each made a new window somewhere else. They were built a round earlier for
     * a good reason: choosing the shared window silently was this screen deciding
     * whose cookies the page an agent is about to drive gets.
     *
     * The reason was right and the shape was wrong. A settings screen for **this**
     * window is not where a person picks what kind of window to make; the `+` on
     * the Browser tab is, and it still offers all three destinations including a
     * private one. So there is one row here, it is called **Attach to a session**
     * on every shape of this screen and on every row menu out on the list, and it
     * hands over an ordinary window in the machine's own browser.
     *
     * ## What happens underneath it is said once, on the ⓘ
     *
     * An agent cannot reach this app's own web view and never will, and it cannot
     * address a page the machine's window list does not name. So on those two
     * shapes the row does the honest thing: `browser.window.open` takes an
     * **address** and carries a session, so this page's own address opens a
     * window over there and the host binds *that* one before it answers. One ask,
     * and the row lands already wearing its slot.
     *
     * That is a real difference from binding the page in front of him and it is
     * not hidden — it is the first paragraph of this card's ⓘ, which is where the
     * whole explanation of the act lives. It is **not** a second row. A row that
     * has to describe itself is a row with the wrong name, and *"the page here
     * does not move"* is a fact about one act rather than a choice between two.
     */
    @ViewBuilder
    private var sessionCard: some View {
        SchemeSectionCaption("Session", about: "attaching a window to a session", info: sessionInfo)

        SchemeGroup {
            switch windowShape {
            case let .machine(window):
                if let slot = window.slot {
                    HStack(spacing: 10) {
                        MachineWindowMark(text: slot, tone: Theme.accent)
                        Text(MachineBrowserText.owner(window) ?? "A session")
                            .font(.system(size: 16))
                            .foregroundStyle(Theme.primary)
                            .lineLimit(1)
                        Spacer(minLength: 8)
                        Button {
                            host?.bindMachineWindow(windowID, to: nil)
                        } label: {
                            Text("Detach")
                                .font(.system(size: 14, weight: .medium))
                                .foregroundStyle(Theme.critical)
                                .padding(.vertical, 4)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityHint("The session stops being able to reach this window")
                        .accessibilityIdentifier("browser.machine.window.detach")
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 13)

                    rowDivider(inset: 16)
                }

                /*
                 * **Attach to a session**, whether or not one already holds it.
                 *
                 * It read *Attach to another session* on a bound window, which is
                 * a second name for one control decided by a state — the same
                 * shape of thing as *Page settings* beside *Window settings*, one
                 * size down. The row above already says which session holds it
                 * and offers Detach, so *another* was carrying nothing this card
                 * had not already said, at the cost of a word that has to be
                 * read.
                 */
                if sessions.isEmpty {
                    deadRow("Attach to a session", icon: "link",
                            id: "browser.machine.window.attach", why: sessionInfo)
                } else {
                    sessionMenuRow("Attach to a session",
                                   icon: "link",
                                   id: "browser.machine.window.attach",
                                   hint: "Hands this window to a session. It gets a slot name — "
                                       + "B1, B2 — and that session's tools address it by that "
                                       + "name.",
                                   chosen: window.session) { session in
                        host?.bindMachineWindow(windowID, to: session)
                    }
                }

            case let .phone(tab):
                attachRow(id: "browser.phone.page.attach", address: phoneAddress(tab))

            case let .cast(surface):
                attachRow(id: "browser.machine.window.attach",
                          address: MachineBrowserText.reopenable(surface.url))

            case .gone, .unknown:
                EmptyView()
            }
        }
    }

    /**
     * The one row that hands a session a window at this page's address, for the
     * two shapes that cannot bind the page they are about.
     *
     * One builder rather than two copies, because the two shapes reached it a
     * round apart and the copies had already drifted into describing the same act
     * with different words.
     *
     * `address` is optional for the one case that really has nothing to re-open —
     * a blank tab, `about:blank`, or one of Chromium's own `chrome://` screens,
     * none of which the machine's `normalizeUrl` will take
     * (`src/main/browser-url.ts` keeps `ALLOWED_PROTOCOLS` at `http` and
     * `https`).
     *
     * `isolated: false`, and that is now a decision made once rather than a
     * choice taken away. The window this makes is an ordinary one in the
     * machine's own browser, which is what somebody standing at that machine
     * would get; a private one is still one tap away on the `+`, which is where
     * a person chooses what kind of window to make.
     */
    @ViewBuilder
    private func attachRow(id: String, address: String?) -> some View {
        if canDrive, !sessions.isEmpty, let address {
            sessionMenuRow("Attach to a session", icon: "link", id: id,
                           hint: "Opens this address on \(machineName) as a window and hands that "
                               + "window to the session. The page here does not move.",
                           chosen: nil) { session in
                host?.openMachineWindow(url: address, isolated: false, session: session)
            }
        } else {
            deadRow("Attach to a session", icon: "link", id: id, why: sessionInfo)
        }
    }

    /**
     * The ⓘ on Session: what a binding is, what the attach really does on a page
     * the machine is not holding, and — where the row is greyed — which of the
     * three things it needs is missing.
     *
     * The three reasons are asked in the order they stop the move, so the answer
     * is the one that is actually true of this machine and this page rather than
     * a general apology. That ordering is the correction from two rounds ago: one
     * sentence about window ids used to head a greyed attach, and it was the
     * reason an attach that was perfectly possible never got built.
     *
     * The first paragraph is where the second row went. *Attach an isolated
     * window* is gone from the glass, and what it was really telling him — that
     * this is a **new** window in the machine's browser, with the machine's
     * cookies, and that the page in front of him is untouched — is said here
     * once, in full, instead of being implied by the existence of two rows.
     */
    private var sessionInfo: String {
        let slots = "A bound window gets a slot name — B1, B2 — and the session's tools address "
            + "it by that name. A session that already holds three windows names the next one B4."
        switch windowShape {
        case .machine:
            return sessions.isEmpty
                ? "Nothing is running on \(machineName) to attach this window to.\n\n" + slots
                : slots
        case .phone, .cast:
            let what = "An agent cannot reach the page you are looking at — it is drawn here, in "
                + "this app, or it is a page \(machineName)'s window list does not name. So "
                + "attaching opens this same address in \(machineName)'s browser and hands that "
                + "window to the session. The page here stays open and untouched; there will be "
                + "two pages on that address afterwards, and the one over there has "
                + "\(machineName)'s cookies, so it may not be signed in the way this one is.\n\n"
            if !canDrive {
                return what + "\(machineName) is not offering its browser to this phone, so no "
                    + "window can be opened there to attach.\n\n" + slots
            }
            if case let .cast(surface) = windowShape, MachineBrowserText.reopenable(surface.url) == nil {
                return what + "This tab has no web address to open again — a blank tab has "
                    + "nothing to re-open.\n\n" + slots
            }
            if sessions.isEmpty {
                return what + "Nothing is running on \(machineName) to attach a window to.\n\n"
                    + slots
            }
            return what + slots
        case .gone, .unknown:
            return slots
        }
    }

    /* ---- 4. what it looks like --------------------------------------------- */

    /**
     * **Photograph it, and choose who gets the photograph** — the same card, in
     * the same place, on every shape.
     *
     * > *"creating a screenshot and sending it to the session, whatever session
     * > we want to send."*
     *
     * Two controls, because they have two outcomes — see the file header. The
     * note travels only with the second, so the field is drawn only where there
     * is a session to send to; a field whose contents can never leave the phone
     * is a control that cannot act.
     *
     * ## The two halves are photographed by two different machines
     *
     * On a window in the machine's browser this is `browser.window.shot` and the
     * machine takes the picture. On a page this phone is drawing there is no
     * such verb to lean on — that page is not in that browser — so this phone
     * does both halves itself, and the consequence is said on the ⓘ rather than
     * discovered: it loads the address again in a web view of its own, so what
     * comes back is the page as it loads now, not the scroll position or the
     * half-filled form left behind. See `PhonePageShot`.
     *
     * ## How a picture from this phone gets into a session
     *
     * The sentence goes first, through `sendToAgent`, which attaches the session
     * when this phone has not opened it — and that ordering is load-bearing
     * rather than tidy: `HostLink.send(_:into:)` drops the landed path in silence
     * for a session with no bridge, so a picture sent to a session nobody had
     * opened would upload perfectly and arrive nowhere. The file follows, and its
     * path lands in that same prompt when the upload finishes. Nothing is
     * submitted — the same rule every other *sent to an agent* path in this app
     * follows, and the reason there is no newline anywhere in it.
     */
    @ViewBuilder
    private var screenshotCard: some View {
        SchemeSectionCaption("Screenshot", about: "photographing this window", info: screenshotInfo)

        SchemeGroup {
            switch windowShape {
            case .machine:
                if !sessions.isEmpty {
                    noteField(id: "browser.machine.window.shotNote")
                    rowDivider(inset: 16)
                }

                shotStrip(shoot: { host?.shotMachineWindow(windowID) },
                          shootID: "browser.machine.window.shot",
                          shootHint: "Takes a picture of this window and shows it here",
                          canShoot: true,
                          sendID: "browser.machine.window.shotTo",
                          sendHint: "Uploads the picture to that session",
                          canSend: !sessions.isEmpty,
                          targets: sessions.map {
                              ShotTarget(id: $0.id, title: MachineBrowserText.sessionRow($0))
                          },
                          send: { send(to: $0) })

                if let picture {
                    rowDivider(inset: 16)
                    /*
                     * Drawn at whatever width the card gives it, aspect kept.
                     *
                     * A machine's window is far wider than a phone, so this is a
                     * thumbnail of a desktop page and it is deliberately not
                     * zoomable: the point of looking at it here is *did the page
                     * do the thing*, and the point of the control beside it is
                     * that the agent gets the full-size picture rather than this
                     * phone squinting at one.
                     */
                    pictureRow(picture, of: windowTitle, at: shot?.at,
                               id: "browser.machine.window.picture")
                }

            case let .phone(tab):
                if canSendShot {
                    noteField(id: "browser.phone.page.shotNote")
                    rowDivider(inset: 16)
                }

                shotStrip(shoot: { Task { await takePhoneShot(tab) } },
                          shootID: "browser.phone.page.shot",
                          shootHint: "Takes a picture of this page and shows it here",
                          canShoot: phoneShot.phase != .working,
                          sendID: "browser.phone.page.shotTo",
                          sendHint: phoneShot.png == nil
                              ? "Take the picture first — there is nothing to send yet"
                              : "Uploads the picture and types its name into that session",
                          canSend: canSendShot && phoneShot.png != nil,
                          targets: agentSessions.map { ShotTarget(id: $0.id, title: $0.title) },
                          send: { sendPhoneShot(to: $0, tab: tab) })

                switch phoneShot.phase {
                case .working:
                    rowDivider(inset: 16)
                    HStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        Text("Loading the page to photograph it…")
                            .font(.system(size: 14))
                            .foregroundStyle(Theme.faint)
                            .accessibilityIdentifier("browser.phone.page.shotWorking")
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 15)
                case let .failed(why):
                    rowDivider(inset: 16)
                    plainNote(why, id: "browser.phone.page.shotFailed")
                case .idle:
                    EmptyView()
                }

                if let taken = phoneShot.image {
                    rowDivider(inset: 16)
                    pictureRow(taken, of: tab.label, at: phoneShot.takenAt,
                               id: "browser.phone.page.picture")
                }

                if let sentLine {
                    rowDivider(inset: 16)
                    plainNote(sentLine, id: "browser.phone.page.sent")
                }

            case .cast:
                shotStrip(shoot: {}, shootID: "browser.machine.window.shot",
                          shootHint: screenshotInfo, canShoot: false,
                          sendID: "browser.machine.window.shotTo", sendHint: screenshotInfo,
                          canSend: false, targets: [], send: { _ in })

            case .gone, .unknown:
                EmptyView()
            }
        }
    }

    /// One place a picture can be sent, as a named value rather than a tuple.
    /// A `ForEach` needs an `Identifiable` element or a key path, and Swift has
    /// no key path to a tuple label — so a two-field struct is not ceremony
    /// here, it is the only shape that compiles.
    private struct ShotTarget: Identifiable {
        let id: String
        let title: String
    }

    /// Whether a picture taken here has anywhere to go. Both halves are real
    /// conditions: a machine that will not take a file, and a machine with
    /// nothing running to hand one to.
    private var canSendShot: Bool { model.canSendFiles && !agentSessions.isEmpty }

    /// The ⓘ on Screenshot. Where the card is greyed, the reason is the whole of
    /// it — a control that cannot act owes the sentence, and this is where the
    /// sentence lives now.
    private var screenshotInfo: String {
        switch windowShape {
        case .machine:
            return "The machine photographs the whole window and sends the picture here. Sent to "
                + "a session instead, the file lands on \(machineName) and its name is typed into "
                + "that session with your note — press Return there to send it."
        case .phone:
            return "This phone takes the picture itself. It loads the address again in a web view "
                + "of its own and photographs that — so what you get is the page as it loads now, "
                + "not the scroll position or the half-filled form you left behind. It is the "
                + "same signed-in browser, so a page you are logged into is photographed logged "
                + "in.\n\nSent to a session, the picture is uploaded to \(machineName) and its "
                + "file name is typed into that session with your note. Press Return there to "
                + "send it."
        case .cast:
            return "The machine photographs a window by its id, and this page is one the "
                + "machine's window list does not name — so there is no window for it to "
                + "photograph. Attaching to a session, above, opens this address on "
                + "\(machineName) as a window, and that window has an id and can be photographed."
        case .gone, .unknown:
            return ""
        }
    }

    /// The note that travels with a picture handed to a session. One row, one
    /// placeholder, no explanation under it — the ⓘ above says where the note
    /// ends up.
    private func noteField(id: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "text.bubble")
                .font(.system(size: 17, weight: .light))
                .foregroundStyle(Theme.faint)
                .frame(width: 24, height: 26)
            TextField("Note (optional)", text: $shotNote)
                .textFieldStyle(.plain)
                .font(.system(size: 15))
                .foregroundStyle(Theme.primary)
                .submitLabel(.done)
                .accessibilityIdentifier(id)
        }
        .padding(.leading, 16)
        .padding(.trailing, 12)
        .padding(.vertical, 10)
    }

    /**
     * The two buttons, side by side, in the same shape on every kind of window.
     *
     * `canSend` false draws the Send half **greyed rather than absent**, which is
     * the round's rule and a change from the code this replaces: the machine's
     * window drew no Send control at all when the machine had no sessions, so
     * the card was one button wide there and two buttons wide next door. A
     * screen whose card changes width between shapes is the *"two different
     * versions"* complaint in miniature.
     */
    private func shotStrip(shoot: @escaping () -> Void,
                           shootID: String,
                           shootHint: String,
                           canShoot: Bool,
                           sendID: String,
                           sendHint: String,
                           canSend: Bool,
                           targets: [ShotTarget],
                           send: @escaping (String) -> Void) -> some View {
        HStack(spacing: 0) {
            Button(action: shoot) {
                stripLabel("camera", "Screenshot", lit: canShoot)
            }
            .buttonStyle(.plain)
            .disabled(!canShoot)
            .accessibilityHint(shootHint)
            .accessibilityIdentifier(shootID)

            Menu {
                ForEach(targets) { target in
                    Button {
                        send(target.id)
                    } label: {
                        Label(target.title, systemImage: "terminal")
                    }
                }
            } label: {
                stripLabel("paperplane", "Send to a session", lit: canSend)
            }
            .disabled(!canSend || targets.isEmpty)
            .accessibilityLabel("Send to a session")
            .accessibilityHint(sendHint)
            .accessibilityIdentifier(sendID)
        }
        .padding(.vertical, 12)
    }

    private func stripLabel(_ icon: String, _ title: String, lit: Bool) -> some View {
        VStack(spacing: 5) {
            Image(systemName: icon)
                .font(.system(size: 17, weight: .medium))
            Text(title)
                .font(.system(size: 11))
        }
        .foregroundStyle(lit ? Theme.accent : Theme.faint)
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
    }

    /// The picture, and when it was taken. One row shape for both photographers,
    /// so a picture from the machine and a picture from this phone are drawn
    /// identically — which is the whole argument of this round applied to a
    /// thing nobody would think to check.
    private func pictureRow(_ image: UIImage, of name: String, at when: Double?,
                            id: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(uiImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(maxWidth: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(Theme.hairline))
                .accessibilityLabel("Screenshot of \(name.isEmpty ? "this window" : name)")
                .accessibilityIdentifier(id)

            if let line = SessionDetails.activityLine(when) {
                Text("Taken \(line)")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.faint)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
    }

    /* ---- 5. what it recorded ----------------------------------------------- */

    /**
     * **The click flow — on the phone's own pages too, and greyed where the
     * machine says it cannot.**
     *
     * Two of his sentences meet on this card and they pull in opposite
     * directions, which is why it is the one that had to be rebuilt rather than
     * trimmed.
     *
     * ## The first: if both can do it, both get it
     *
     * > *"you are giving record flow button in the windows side the server side
     * > it and you are not giving that into the if they are browsing locally in
     * > this machine. So there are so many differences if they both are capable
     * > for a feature why don't they both have."*
     *
     * The last round left this card out of a page this phone draws, and wrote
     * the reason on the screen: the recorder is the machine's
     * (`src/main/browser-steps.ts`), watching the machine's own browser, and
     * there is nothing for it to watch here. Every word of that is true about
     * *the machine's* recorder and none of it is a reason the phone cannot have
     * one — the phone owns a real `WKWebView` and can watch its own page.
     * `PhoneClickFlow` does exactly that, and this card draws it through the same
     * `stepRow` the machine's flow uses, so the two lists are not merely similar,
     * they are the same rows.
     *
     * ## The second: a screen may not contradict itself
     *
     * His screenshot of this screen has the banner *"This machine's browser
     * cannot record a click flow."* with a live blue **Record the click flow**
     * directly under it. The banner was the machine's answer to the
     * `browser.window.steps` this screen sends on appear; the button was drawn
     * unconditionally, because nothing on the wire says whether a machine has a
     * recorder. So the button was lit over a sentence denying it, and pressing it
     * would have produced the same sentence again.
     *
     * `recorderRefused` closes that: the moment the machine says it, the row
     * greys and the reason moves onto this card's ⓘ, where it belongs — attached
     * to the control it is about instead of floating at the top of the screen.
     * The banner stops repeating it, because a fact said twice on one screen is
     * how somebody ends up trusting neither copy.
     *
     * ## Reading what was collected
     *
     * The machine's steps are not on the window list and there is no push for
     * them, so they are asked for on arrival, again the moment a recording
     * stops, and on the control beside the toggle — the honest answer for a flow
     * that is still growing while somebody is looking at it. This phone's own
     * flow needs none of that: it is in this process, `PhoneClickFlow` is
     * `@Observable`, and the rows arrive as they are collected. What that half
     * gets instead is **Clear**, which the machine has no verb for.
     */
    @ViewBuilder
    private var clickFlowCard: some View {
        SchemeSectionCaption("Click flow", about: "recording a click flow", info: clickFlowInfo)

        SchemeGroup {
            switch windowShape {
            case let .machine(window):
                if recorderRefused {
                    deadRow("Record the click flow", icon: "record.circle",
                            id: "browser.machine.window.record", why: clickFlowInfo)
                } else {
                    HStack(spacing: 12) {
                        Button {
                            host?.actOnMachineWindow(windowID,
                                                     window.recording ? .recordOff : .recordOn)
                        } label: {
                            recordLabel(on: window.recording)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("browser.machine.window.record")

                        Spacer(minLength: 8)

                        if window.recording {
                            MachineWindowMark(text: "Recording", tone: Theme.critical)
                                .accessibilityHidden(true)
                        }

                        Button {
                            host?.readMachineSteps(windowID)
                        } label: {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(Theme.faint)
                                .frame(width: 34, height: 30)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Read the steps again")
                        .accessibilityIdentifier("browser.machine.window.steps.refresh")
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)

                    stepList(steps, recording: window.recording,
                             prefix: "browser.machine.window")
                }

            case let .phone(tab):
                let running = phoneFlow.isRecording(tab: tab.id)
                let collected = phoneFlow.steps(tab: tab.id)

                HStack(spacing: 12) {
                    Button {
                        if running { phoneFlow.stop(tab: tab.id) } else { phoneFlow.start(tab: tab.id) }
                    } label: {
                        recordLabel(on: running)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("browser.phone.page.record")

                    Spacer(minLength: 8)

                    if running {
                        MachineWindowMark(text: "Recording", tone: Theme.critical)
                            .accessibilityHidden(true)
                    }

                    /*
                     * Clear rather than the machine half's refresh, and both are
                     * one glyph in the same slot so the two cards read as one
                     * control set. There is nothing to re-read here — the flow is
                     * in this process and `PhoneClickFlow` is `@Observable`, so
                     * the rows arrive as they are collected — and there *is*
                     * something to throw away, which the machine has no verb for.
                     */
                    Button {
                        phoneFlow.clear(tab: tab.id)
                    } label: {
                        Image(systemName: "trash")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(Theme.faint.opacity(collected.isEmpty ? 0.4 : 1))
                            .frame(width: 34, height: 30)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(collected.isEmpty)
                    .accessibilityLabel("Clear the steps")
                    .accessibilityIdentifier("browser.phone.page.steps.clear")
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)

                stepList(collected, recording: running, prefix: "browser.phone.page")

            case .cast:
                deadRow("Record the click flow", icon: "record.circle",
                        id: "browser.machine.window.record", why: clickFlowInfo)

            case .gone, .unknown:
                EmptyView()
            }
        }

        /*
         * The cut, for the same reason and with the same limit as the window
         * list's: `WireCodec.recordedSteps` takes a `prefix` and keeps no record
         * of what it dropped, so this can say there may be more and cannot say
         * how many. The host caps its own side as well — see `MAX_STEPS` in
         * `src/main/browser-steps.ts` — which is the cap somebody would actually
         * hit first. Only the machine's flow crosses a wire, so only the
         * machine's flow can be cut by one.
         */
        if case .machine = windowShape, steps.count >= MachineBrowserWire.maxSteps {
            HStack(spacing: 6) {
                Text("Showing the first \(MachineBrowserWire.maxSteps)")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.faint)
                InfoDot(
                    about: "the step limit",
                    text: "This phone draws \(MachineBrowserWire.maxSteps) steps of a flow. The "
                        + "recording on the machine is not truncated by what is shown here.")
            }
            .padding(.top, 12)
            .padding(.leading, 4)
            .accessibilityIdentifier("browser.machine.window.stepsCapped")
        }
    }

    /// The word on the recorder, which is the verb and never the state. *Stop
    /// recording* while it runs, because a button labelled with what is already
    /// happening is one somebody presses to find out.
    private func recordLabel(on: Bool) -> some View {
        HStack(spacing: 9) {
            Image(systemName: on ? "stop.circle" : "record.circle")
                .font(.system(size: 19, weight: .light))
                .frame(width: 24)
            Text(on ? "Stop recording" : "Record the click flow")
                .font(.system(size: 16))
        }
        .foregroundStyle(on ? Theme.critical : Theme.accent)
        .contentShape(Rectangle())
    }

    /// The steps of one flow, whoever collected them. Identical rows for the two
    /// recorders — the point of W6 is that they are the same feature, and a list
    /// that looked different would say they were not.
    @ViewBuilder
    private func stepList(_ collected: [RecordedStep], recording: Bool, prefix: String) -> some View {
        if !collected.isEmpty {
            let first = collected.first?.at ?? 0
            ForEach(collected) { step in
                rowDivider(inset: 16)
                stepRow(step, from: first, prefix: prefix)
            }
        } else if recording {
            rowDivider(inset: 16)
            plainNote("Nothing yet.", id: prefix + ".noSteps")
        }
    }

    /// The ⓘ on Click flow. On a machine that has refused, the refusal is the
    /// first thing in it — which is the whole of W8: the reason moves from a
    /// banner floating above the screen onto the control it is about.
    private var clickFlowInfo: String {
        let what = "A recording collects what is clicked, typed and submitted on the page, in "
            + "order, so a flow can be handed to an agent as steps rather than as a description."
        switch windowShape {
        case .machine:
            return recorderRefused
                ? "\(machineName)'s browser cannot record a click flow — it is running without a "
                    + "recorder, so there is nothing to switch on.\n\n" + what
                : what
        case .phone:
            /*
             * Deliberately says what is true of *any* recorder living in this
             * process and nothing about how `PhoneClickFlow` schedules itself.
             * A sentence on a screen that guesses at another lane's behaviour is
             * how this file ended up with a card that contradicted a banner.
             */
            return what + "\n\nThis page is drawn by this app, so this app is what watches it. "
                + "The steps stay on this phone — nothing is sent to \(machineName) — until you "
                + "clear them."
        case .cast:
            return "The machine's recorder is addressed by a window id, and this page is one the "
                + "machine's window list does not name — so a recording cannot be started for it. "
                + "Attaching to a session, above, opens this address on \(machineName) as a "
                + "window, and that window can be recorded.\n\n" + what
        case .gone, .unknown:
            return what
        }
    }

    /* ---- 6. and the end of it ---------------------------------------------- */

    /**
     * **Close the window, from inside it** — last, alone, and away from
     * everything else on the screen, because it is the one control here that
     * ends something.
     *
     * It is also on the home's row — on the `…` and on the swipe — which is not
     * a duplicate: closing a window you are looking at and closing one from a
     * list are two different moments, and the list's whole point is not having
     * to open a window to deal with it. It is the **same words** in both places
     * — *Close window* — for the same reason the settings screen has one title.
     *
     * ## One of these dismisses and the rest do not, and that took a failure
     *
     * A machine window does not dismiss on the press. `MachineWindowView` watches
     * for the window leaving the machine's list and pops both screens then — one
     * watcher, because two would race to pop the same stack.
     *
     * A page **this phone** owns has no such watcher, and leaving it out was
     * measured against a live host: pressing Close left him standing on a
     * settings screen reading *"This page is closed"* with the page still
     * underneath it, because `LocalhostBrowser`'s tab watcher pops the page and
     * cannot pop what is stacked on top of it. Nothing appeared to happen. The
     * live case `testClosingTheViewLeavesNoPageBehind` failed on exactly that,
     * twice. So this screen goes first and the watcher below takes the page with
     * it — two pops, both caused by his own press, landing him back on the
     * Browser list where he started.
     */
    @ViewBuilder
    private var closeCard: some View {
        SchemeSectionCaption("Close", about: "closing this window", info: closeInfo)

        SchemeGroup {
            switch windowShape {
            case let .machine(window):
                // `WindowNames.name`, never the raw label: a hint that says
                // *Closes about:blank* is the jargon this round took off the
                // glass, spoken out loud where nobody proof-reads it.
                closeRow(id: "browser.machine.window.close",
                         hint: "Closes \(WindowNames.name(window)) in \(machineName)'s browser") {
                    host?.actOnMachineWindow(windowID, .close)
                }
            case let .phone(tab):
                closeRow(id: "browser.phone.page.close",
                         hint: "Closes this page and the tunnel it was using, on this phone") {
                    model.browserTabs.close(tab, machine: model)
                    if pushed { dismiss() }
                }
            case .cast:
                deadRow("Close window", icon: "xmark.circle",
                        id: "browser.machine.window.close", why: closeInfo)
            case .gone, .unknown:
                EmptyView()
            }
        }
    }

    private func closeRow(id: String, hint: String, act: @escaping () -> Void) -> some View {
        Button(action: act) {
            HStack(spacing: 12) {
                Image(systemName: "xmark.circle")
                    .font(.system(size: 19, weight: .light))
                    .frame(width: 24)
                // **Close window**, word for word what the row's `…` out on the
                // Browser tab says, because they are the same act from two
                // places and a browser has exactly one name for it. It read
                // *Close this window* here, which is one more of the small
                // second names this round is taking out.
                Text("Close window")
                    .font(.system(size: 16))
                Spacer(minLength: 0)
            }
            .foregroundStyle(Theme.critical)
            .padding(.horizontal, 16)
            .padding(.vertical, 13)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint(hint)
        .accessibilityIdentifier(id)
    }

    /// The ⓘ on Close. Short on the two shapes where the button works, because a
    /// verb that does what it says needs no essay; the whole reason on the one
    /// where it cannot.
    private var closeInfo: String {
        switch windowShape {
        case .machine:
            return "Closes this window in \(machineName)'s browser. Anything unsaved on the page "
                + "goes with it."
        case .phone:
            return "Closes this page on this phone and the tunnel it was using. Nothing on "
                + "\(machineName) is closed."
        case .cast:
            return "The machine closes a window by its id, and this page is one the machine's "
                + "window list does not name — so there is no window here for it to close."
        case .gone, .unknown:
            return ""
        }
    }

    // MARK: - Rows

    /**
     * **One live row: an icon, a name, and nothing else.**
     *
     * The shape every control on this screen collapsed into this round. It used
     * to carry a `meaning` as a second grey line — *"Signed in the way
     * DESKTOP-DDGMNCV is."* — and that line is what he was reading when he said
     * the rows *"have becomes too big"* and that he *"can't understand what they
     * mean"*. Two lines of explanation do not make a row clearer; a better name
     * does, and the explanation goes to the section's ⓘ.
     *
     * The sentence survives as the **hint**, which is where VoiceOver expects the
     * explanation of a control anyway, so nothing was lost for a screen reader
     * when it came off the glass.
     */
    private func actionRow(_ title: String, icon: String, id: String, hint: String,
                           act: @escaping () -> Void) -> some View {
        Button(action: act) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 17, weight: .light))
                    .foregroundStyle(Theme.accent)
                    .frame(width: 24)
                Text(title)
                    .font(.system(size: 16))
                    .foregroundStyle(Theme.accent)
                    .lineLimit(1)
                Spacer(minLength: 8)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 13)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint(hint)
        .accessibilityIdentifier(id)
    }

    /**
     * One row that names a place and hands the session picker over when pressed.
     *
     * The row is a **name**; which session gets it is the menu behind it. The
     * label is set explicitly and that is not decoration: the trap
     * `NewWindowSheet.destinationRow` measured is that a control holding two
     * `Text`s is read by VoiceOver as both of them joined, so the row answers to
     * a sentence rather than to its own name and a test asking for the name
     * reports it missing while it sits plainly on screen. There is one `Text`
     * here now, which is the same fix arrived at from the other direction — the
     * explicit label stays so a second one can never reopen the hole.
     */
    private func sessionMenuRow(_ title: String, icon: String, id: String, hint: String,
                                chosen: String?,
                                pick: @escaping (String) -> Void) -> some View {
        Menu {
            ForEach(sessions) { session in
                Button {
                    pick(session.id)
                } label: {
                    Label(MachineBrowserText.sessionRow(session),
                          systemImage: session.id == chosen ? "checkmark" : "terminal")
                }
            }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 17, weight: .light))
                    .foregroundStyle(Theme.accent)
                    .frame(width: 24)
                Text(title)
                    .font(.system(size: 16))
                    .foregroundStyle(Theme.accent)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Theme.faint)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 13)
            .contentShape(Rectangle())
        }
        .accessibilityLabel(title)
        .accessibilityHint(hint)
        .accessibilityIdentifier(id)
    }

    /**
     * A control in its place, greyed, with the reason on the hint and on the
     * section's ⓘ above it.
     *
     * `.disabled(true)` rather than a button that answers with a sentence: a
     * control that replies instead of acting is still a control that did not do
     * what it says. Which is where every one of these ends up now — the reason
     * is the ⓘ of the card it is in, so a greyed row is never silent and never a
     * paragraph.
     */
    private func deadRow(_ title: String, icon: String, id: String, why: String) -> some View {
        Button {} label: {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 17, weight: .light))
                    .frame(width: 24)
                Text(title)
                    .font(.system(size: 16))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .foregroundStyle(Theme.faint)
            .padding(.horizontal, 16)
            .padding(.vertical, 13)
        }
        .buttonStyle(.plain)
        .disabled(true)
        .accessibilityHint(why)
        .accessibilityIdentifier(id)
    }

    /**
     * One step: when, what, and to what.
     *
     * The offset is relative to the first step rather than a clock time, because
     * a flow is read as a sequence — *click, type, click, submit* — and the
     * useful question about step nine is how long after step one it happened. For
     * the machine's recorder `at` is the machine's main-process clock in epoch
     * milliseconds, stamped there rather than by the page: *"the page never gets
     * to stamp its own steps"* (`src/main/browser-steps.ts`). `PhoneClickFlow`
     * stamps its own the same way and in the same unit, which is what lets one
     * row draw both.
     */
    private func stepRow(_ step: RecordedStep, from first: Double, prefix: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(offset(step, from: first))
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Theme.faint)
                .frame(width: 44, alignment: .trailing)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    MachineWindowMark(text: step.kind, tone: Theme.secondary)
                    if let detail = step.detail, !detail.isEmpty {
                        Text(detail)
                            .font(.system(size: 14))
                            .foregroundStyle(Theme.primary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                if let value = step.value, !value.isEmpty {
                    Text(value)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.secondary)
                        .lineLimit(1)
                }
                if let selector = step.selector, !selector.isEmpty {
                    // Truncated in the middle: a selector's two ends are the tag
                    // and the thing that makes it unique, and the wrapper chain
                    // between them is the part nobody reads on a phone.
                    Text(selector)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Theme.faint)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("\(prefix).step.\(step.index)")
    }

    /// `+1.2s` from the start of the flow, and nothing at all when either stamp
    /// is missing — a step drawn as `+0.0s` because the machine sent no time is
    /// a number somebody would read as a fact.
    private func offset(_ step: RecordedStep, from first: Double) -> String {
        guard step.at > 0, first > 0, step.at >= first else { return "" }
        let seconds = (step.at - first) / 1000
        guard seconds.isFinite else { return "" }
        return seconds < 10 ? String(format: "+%.1fs", seconds) : "+\(Int(seconds))s"
    }

    /**
     * A line of prose as a row inside a card. Four of them left on this screen,
     * and every one is a **state** rather than an explanation — the page is
     * closed, nothing has been collected yet, that picture failed, that picture
     * has been sent.
     *
     * The identifier goes on the **text**, never on the card around it: an
     * `accessibilityIdentifier` on a container makes that container an
     * accessibility element and everything inside it stops existing — measured
     * on iOS 26.4, and written down in `TabNavigation.swift`.
     */
    private func plainNote(_ text: String, id: String) -> some View {
        Text(text)
            .font(.system(size: 14))
            .foregroundStyle(Theme.faint)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 16)
            .padding(.vertical, 15)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityIdentifier(id)
    }

    /// 16 rather than a list row's 52: the rows in these cards have no icon
    /// column to line a divider up under.
    private func rowDivider(inset: CGFloat) -> some View {
        Rectangle()
            .fill(Theme.hairline)
            .frame(height: 0.5)
            .padding(.leading, inset)
    }

    // MARK: - Actions

    /// The address this page is on, as the machine would have to be given it.
    /// `String(port)` and never the `Int` interpolated: a port dropped straight
    /// into a Swift string is formatted with the locale's grouping separator and
    /// comes out as `localhost:3,000`.
    private func phoneAddress(_ tab: BrowserTab) -> String {
        "http://localhost:\(String(tab.port))\(tab.path)"
    }

    /**
     * Photograph this page.
     *
     * The tunnel first, because a tab can be parked: switching machines releases
     * every socket this phone was holding, and the tab waits as a row. `resume`
     * re-binds the port, and then there is a wait for it to actually come up.
     *
     * That wait is bounded and it only runs because somebody pressed a button —
     * it is not a poller. Twelve seconds is well past `PortTunnel`'s own dial,
     * and every path out of it ends in either a picture or a sentence.
     */
    private func takePhoneShot(_ tab: BrowserTab) async {
        guard let url = await liveURL(for: tab) else {
            phoneShot.fail("This phone could not reach \(machineName) on that port, so there was "
                      + "nothing to photograph.")
            return
        }
        await phoneShot.take(url: url)
    }

    /// Where the page actually lives right now: the tunnel's own origin with the
    /// tab's current path resolved against it. The origin is used as the machine
    /// bound it — `127.0.0.1` on most phones and `[::1]` where the v4 bind lost a
    /// race — rather than rebuilt from a guess, which is the same rule
    /// `LocalhostBrowser` follows.
    private func liveURL(for tab: BrowserTab) async -> URL? {
        guard let current = model.browserTabs.resume(tab, machine: model),
              let tunnel = model.browserTabs.tunnel(for: current) else { return nil }
        for _ in 0 ..< 80 {
            if tunnel.hasEnded { return nil }
            if case let .live(origin) = tunnel.phase {
                guard current.path != "/",
                      let resolved = URL(string: current.path, relativeTo: origin)
                else { return origin }
                return resolved.absoluteURL
            }
            // Cancellation checked rather than left to `try?`, which swallows it
            // and turns the wait into a tight loop for the rest of its twelve
            // seconds — the screen going away is exactly when that happens.
            if Task.isCancelled { return nil }
            try? await Task.sleep(for: .milliseconds(150))
        }
        return nil
    }

    /**
     * Hand the picture to a session: the sentence, then the file.
     *
     * See the card's own header for why that order is not a preference. The note
     * is flattened through `Inspect.oneLine` — the one function in this app that
     * decides what a line typed into somebody's shell may contain — and the field
     * is cleared, because a note describes *that* picture and leaving it standing
     * would attach last shot's sentence to the next one.
     */
    private func sendPhoneShot(to session: String, tab: BrowserTab) {
        guard let png = phoneShot.png, !png.isEmpty else { return }
        let name = "page-\(String(tab.port))-\(Int(Date().timeIntervalSince1970)).png"
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        do {
            try png.write(to: file)
        } catch {
            say("That picture could not be saved, so it was not sent.")
            return
        }

        var opening = "A screenshot of \(phoneAddress(tab)) taken on my phone"
        let note = Inspect.oneLine(shotNote.trimmingCharacters(in: .whitespacesAndNewlines))
        if !note.isEmpty { opening += " — \(note)" }
        opening += ": "

        _ = model.sendToAgent(opening, into: session)
        model.send(PickedFile(url: file, name: name, size: png.count, temporary: true),
                   into: session)
        shotNote = ""
        say("Sent. Press Return in that session to send it.")
    }

    /// Hand the machine's picture to a session. The confirmation is the
    /// machine's own answer — the window list comes back carrying the notice,
    /// which the banner above draws — so nothing is said here.
    private func send(to session: String) {
        let line = shotNote.trimmingCharacters(in: .whitespacesAndNewlines)
        host?.shotMachineWindow(windowID, to: session, note: line.isEmpty ? nil : line)
        shotNote = ""
    }

    /// Hold a line for two and a half seconds, the same as every other silent
    /// act in this app.
    ///
    /// Only the picture uses it, and only because sending one is the one act on
    /// this screen with no answer to redraw from: the upload runs on this phone
    /// and the machine says nothing back about it. Everything else here is a
    /// `browser.window.*` verb whose answer is the window list and the banner
    /// above, so nothing else is allowed to print a sentence ahead of it.
    private func say(_ line: String) {
        withAnimation { sentLine = line }
        Task {
            try? await Task.sleep(for: .seconds(2.5))
            withAnimation { sentLine = nil }
        }
    }

    private func refreshPicture() {
        guard let data = shot?.png, !data.isEmpty else {
            picture = nil
            return
        }
        picture = UIImage(data: data)
    }
}


/* -------------------------------------------------------------------------- */
/* Photographing a page this phone is drawing                                 */
/* -------------------------------------------------------------------------- */

/**
 * A picture of a page this phone is holding, taken by this phone.
 *
 * `browser.window.shot` photographs a window in the **machine's** browser, and a
 * page opened over a tunnel is not in that browser: it is a `WKWebView` in this
 * app, on a real loopback origin. So the picture has to be taken here, and the
 * question is which web view takes it.
 *
 * ## Why it loads the page again instead of photographing the one he was reading
 *
 * The obvious answer is the web view `LocalhostBrowser` owns — and it does not
 * exist by the time anybody is on this screen. That view is `@State` on the
 * pushed page, so leaving the page tears it down along with its web content
 * process; the settings are reached from the row, with the page not on screen.
 * Keeping a page alive in the background so that a button on another screen
 * could photograph it would mean every tunnelled page in the app going on
 * running scripts, holding sockets and burning battery for a control almost
 * nobody presses.
 *
 * So this loads the same address again, in a web view of its own, and
 * photographs that. **The consequence is real and is said on screen**: what
 * comes back is the page as it loads now, not the scroll position or the
 * half-filled form that was on it. What is *not* lost is the sign-in —
 * `.default()` is the same persistent store `BrowserBridge` uses, so a dev
 * server that logged him in with a cookie photographs logged in.
 *
 * ## Why the view is put in the window, at one per cent alpha
 *
 * A `WKWebView` that is in no window has no reason to paint, and `takeSnapshot`
 * on a detached one is a coin toss that comes back blank on some builds. There
 * is nothing to be gained by finding out which build this is on his phone. So it
 * goes into the key window behind everything, invisible but real, with touches
 * off and hidden from accessibility so it cannot swallow a tap or appear in a
 * UI test's tree — and it is taken out again the moment the picture is in hand.
 * Nothing of it outlives the press.
 *
 * ## Every path out of it ends in a picture or a sentence
 *
 * A page that never finishes loading, one that fails, one whose snapshot comes
 * back nil: three different outcomes and each gets its own plain line. A camera
 * button that goes quiet is the dead control this whole screen exists to stop
 * being.
 */
@MainActor
@Observable
final class PhonePageShot {

    /// Where a capture is. `.failed` carries the sentence rather than a code,
    /// because the only reader is a line of text on a card.
    enum Phase: Equatable {
        case idle
        case working
        case failed(String)
    }

    private(set) var phase: Phase = .idle
    /// The decoded picture, for the card. Held rather than decoded in a view
    /// body — the same reason `MachineWindowSettingsView.picture` is held.
    private(set) var image: UIImage?
    /// The bytes, for the upload. Kept beside the image rather than re-encoded
    /// from it: a re-encode is a second PNG that is not the one on screen.
    private(set) var png: Data?
    /// Epoch milliseconds, the stamp `MachineShot.at` uses, so both screens can
    /// hand it to `SessionDetails.activityLine` and get the same words.
    private(set) var takenAt: Double?

    /**
     * The size the page is photographed at.
     *
     * A phone-shaped viewport, because that is the shape it was being read in. A
     * desktop-width picture of a responsive site is a picture of a layout he
     * never saw, and the whole point of showing an agent this page is that it is
     * the page in front of him.
     */
    static let viewport = CGSize(width: 390, height: 844)

    /// How long the page has to load. Deliberately longer than a dev server's
    /// worst first compile and short enough that nobody is still waiting.
    static let deadline: Duration = .seconds(20)

    private var web: WKWebView?
    private var watcher: PageLoadWatcher?

    /// Give up before anything is loaded, with a sentence of the caller's own.
    /// Used for the case this object cannot see: no tunnel to load through.
    func fail(_ why: String) {
        phase = .failed(why)
    }

    func take(url: URL) async {
        release()
        phase = .working
        image = nil
        png = nil
        takenAt = nil

        let configuration = WKWebViewConfiguration()
        // The same persistent store `BrowserBridge` uses, deliberately: this has
        // to photograph the page as he is signed into it, and an ephemeral store
        // would photograph a logged-out stranger's view of his own dev server.
        configuration.websiteDataStore = .default()
        configuration.allowsInlineMediaPlayback = true

        let view = WKWebView(frame: CGRect(origin: .zero, size: Self.viewport),
                             configuration: configuration)
        view.isOpaque = true
        view.backgroundColor = .white
        view.scrollView.backgroundColor = .white
        view.isUserInteractionEnabled = false
        view.alpha = 0.01
        view.isAccessibilityElement = false
        view.accessibilityElementsHidden = true
        // The left edge is the system's everywhere in this app, and a view
        // nobody can touch has no business installing edge recognisers anyway.
        view.allowsBackForwardNavigationGestures = false
        mount(view)
        web = view

        if let failure = await load(view, url) {
            release()
            phase = .failed(failure)
            return
        }

        /*
         * A beat between "the document finished" and the photograph.
         *
         * `didFinish` fires when loading is done, not when the first frame has
         * been painted — a page whose fonts or hero image land on the next
         * runloop turn photographs as a white rectangle. 400ms is far more than
         * a paint and far less than anybody notices, and `afterScreenUpdates`
         * below covers the rest.
         */
        try? await Task.sleep(for: .milliseconds(400))

        guard let picture = await snapshot(view) else {
            release()
            phase = .failed("That page could not be photographed. Opening it here and trying "
                            + "again usually works.")
            return
        }
        guard let bytes = picture.pngData() else {
            release()
            phase = .failed("That picture could not be saved.")
            return
        }

        image = picture
        png = bytes
        takenAt = Date().timeIntervalSince1970 * 1000
        phase = .idle
        release()
    }

    /// Load, and answer with the sentence to show or nil for success.
    private func load(_ view: WKWebView, _ url: URL) async -> String? {
        await withCheckedContinuation { continuation in
            let watcher = PageLoadWatcher(deadline: Self.deadline) { failure in
                continuation.resume(returning: failure)
            }
            self.watcher = watcher
            view.navigationDelegate = watcher
            view.load(URLRequest(url: url))
        }
    }

    private func snapshot(_ view: WKWebView) async -> UIImage? {
        let configuration = WKSnapshotConfiguration()
        configuration.rect = CGRect(origin: .zero, size: view.bounds.size)
        // The picture has to include whatever the last runloop turn drew, which
        // is exactly the case the beat above is waiting for.
        configuration.afterScreenUpdates = true
        return await withCheckedContinuation { continuation in
            view.takeSnapshot(with: configuration) { picture, _ in
                continuation.resume(returning: picture)
            }
        }
    }

    /// Behind everything in the key window, invisible, untouchable. See the
    /// header for why it cannot simply live in no window at all.
    private func mount(_ view: UIView) {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = scenes.first(where: { $0.activationState == .foregroundActive }) ?? scenes.first
        guard let window = scene?.keyWindow ?? scene?.windows.first else { return }
        window.insertSubview(view, at: 0)
    }

    /// Take it back out, and stop it. A web view left in the window would go on
    /// running the page's scripts and holding the tunnel open for a screen
    /// nobody is looking at.
    private func release() {
        watcher = nil
        guard let view = web else { return }
        view.navigationDelegate = nil
        view.stopLoading()
        view.removeFromSuperview()
        web = nil
    }
}

/**
 * Waits for one page to load, once, and answers exactly once however it ends.
 *
 * The deadline is part of it rather than bolted on outside: a `WKWebView` that
 * is never going to finish — a dev server that accepted the socket and then
 * stopped talking — calls no delegate method at all, so a continuation waiting
 * on the delegate alone waits forever. `answer` is nilled on the first call,
 * which is what makes "finished, then timed out" safe rather than a crash.
 */
@MainActor
private final class PageLoadWatcher: NSObject, WKNavigationDelegate {

    private var answer: ((String?) -> Void)?

    init(deadline: Duration, done: @escaping (String?) -> Void) {
        answer = done
        super.init()
        Task { [weak self] in
            try? await Task.sleep(for: deadline)
            self?.finish("That page did not finish loading, so there was nothing to photograph.")
        }
    }

    private func finish(_ failure: String?) {
        guard let answer else { return }
        self.answer = nil
        answer(failure)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        finish(nil)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        finish("That page could not be loaded, so there was nothing to photograph.")
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
                 withError error: Error) {
        finish("That page could not be reached, so there was nothing to photograph.")
    }
}
