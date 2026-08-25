/**
 * The settings of one window: whose cookies it gets, which session owns it, what
 * it looks like, and what it recorded.
 *
 * > *"When we click on three dots then we can see the settings — per window
 * > also, inside the window: settings of per window, how to connect to it, how
 * > to make it shared or isolated, all of these things should be inside of the
 * > window."*
 *
 * That sentence is the whole specification of this file. The Browser tab's home
 * lists windows and nothing else; a row's `…` carries only what you do to a
 * window from outside it — close, archive, connect to a session; and everything
 * *about* a window is here, reached from inside the window.
 *
 * ## Two placements, one implementation
 *
 * `pushed` says which. On a window the machine is casting, `MachineWindowView`
 * is the live page and this is a screen behind the `…` on its bar. On a window
 * it will not cast, there is no page to be, so this **is** the body of that
 * screen. The same cards either way — a settings screen that dropped a control
 * because of how it was reached would be two products.
 *
 * The one thing that differs is the line at the top. Where this is the body, it
 * says the machine is not offering this window for watching, because that is why
 * you are looking at cards instead of at a page. Where it is pushed, the page is
 * one Back away and saying so would be noise.
 *
 * And it says it **only when the machine advertises `watch` at all**. A host that
 * never offered a cast — every shipped build before this wave, and the public
 * demo box, which passes no `screencast` engine on purpose — is not withholding
 * anything, and a sentence about a cast there is an apology for a feature that
 * was never on the table.
 *
 * ## And the third shape: a page the machine has no window row for
 *
 * `MachineWindowView` is the one browser-window screen now — the machine's own
 * front tab opens it too — so the `…` on its bar reaches this screen for a page
 * that is in `browser.surfaces` and in no window list at all. Every control here
 * is a `browser.window.*` verb addressed by a window id, and
 * `src/main/remote/protocol.ts` refuses an empty one on every member of that
 * family, so for that page not one of them can be put on the wire.
 *
 * It gets the two controls he named, drawn **dead with the reason**, rather than
 * a screen with nothing on it:
 *
 * > *"there is no way to attach this one too. So it should be the same case, or
 * > all the options should be available at least."*
 *
 * Isolation, the screenshot and the click flow are named in that reason and are
 * not drawn, and that is not the rule being bent twice: each of those cards is
 * built out of a **fact** — shared or isolated, which profile, whether a
 * recording is running — that the machine has never reported for a page with no
 * window row. A dead button is honest; a card labelled *Shared* about a page
 * nobody said that of is invented data.
 *
 * ## And the fourth shape: a page **this phone** is drawing
 *
 * > *"all of them should be identical, and all of them should have all the
 * > options. Should not be that much of difference in all of them."*
 *
 * A page opened over a tunnel had no settings screen at all. Its row on the
 * Browser tab opened the page; the page had no `…`; and everything a window on
 * the machine could be asked for was simply somewhere that kind of window did
 * not go. Reached now from that row's `…` — `phoneTab` carries the tab's id and
 * `windowID` is empty, because there is no window on the machine to name.
 *
 * The rule for it is the rule for the shape above, applied honestly rather than
 * defensively: work out which controls can **really** act on a page this phone
 * renders, and build those. Four can — attach (by opening the same address on
 * the machine and binding *that* window), photograph with a note and hand it to
 * a session, open it in the machine's browser, and close it. One cannot: the
 * click-flow recorder is the machine's, watching the machine's own browser, so
 * it is left out with the reason on the ⓘ rather than drawn dead. See
 * `phonePageCards`.
 *
 * ## What is deliberately not here
 *
 * The address and the four page verbs. They are on `MachineWindowView`'s bar,
 * where a browser keeps them and where the page they act on is. Drawing them
 * here as well would be two sets of the same four buttons on two screens, which
 * is exactly how the Browser tab ended up with two lists of one thing.
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
 * The session picker is therefore on that card rather than a screen away, which
 * is what his sentence asks for: *whatever session we want to send*.
 *
 * ## It holds an id, never a window
 *
 * Every verb on this family answers with the **whole** window list, so a
 * `MachineWindow` captured when this screen appeared is stale the moment
 * anything on it is pressed — a binding made here would leave the slot badge
 * showing the old answer. The id is stable and the row is looked up on every
 * redraw.
 *
 * Nothing here dismisses itself either, including Close: `MachineWindowView`
 * owns the single watcher that pops the pair of them when the window leaves the
 * machine's list. One watcher, because two would race to pop the same stack.
 */

import SwiftUI
import UIKit
import WebKit

struct MachineWindowSettingsView: View {
    let model: DeckModel
    let windowID: String
    /// Whether this is its own screen, pushed from the `…` on a window that is
    /// being cast — or the body of the window's screen, on one that is not. See
    /// the header.
    let pushed: Bool

    /**
     * The page **this phone** is drawing, when that is what these settings are
     * about. Nil for every window on the machine.
     *
     * A tab **id**, never the tab, for the same reason `windowID` is an id and
     * not a `MachineWindow`: a tab's title and path move under it as the page
     * navigates, and a value captured when this screen appeared would name the
     * page somebody left two taps ago. It is resolved on every redraw.
     *
     * A default so the two existing call sites in `MachineWindowView` are
     * untouched — the same shape `MachineBrowserView` uses for its `shelf`.
     */
    var phoneTab: String? = nil

    /// The picture this phone took of its own page, and how that went. See
    /// `PhonePageShot` at the foot of this file for why the phone has to render
    /// the page again rather than photograph the one it was showing.
    @State private var shot = PhonePageShot()

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
    private var steps: [RecordedStep] { host?.machineSteps[windowID] ?? [] }

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

    var body: some View {
        screen
            .onAppear {
                // Steps have no push and are not carried on the window list, so
                // the only way to know what a recording has collected is to ask.
                // Asked on arrival rather than only when a recording stops,
                // because a window may already have been recording for ten
                // minutes before anybody opened this screen.
                //
                // Not for a page this phone is drawing: there is no recorder on
                // it and `windowID` is the empty string, which the host refuses
                // at the parser on every member of this family. Asking anyway
                // would put a frame on the wire whose only possible answer is a
                // refusal.
                if phoneTab == nil { host?.readMachineSteps(windowID) }
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
            .onChange(of: shotStamp) { _, _ in refreshPicture() }
    }

    /// The title belongs to whichever screen this is. Pushed, it names what is
    /// behind the `…`; inline, `MachineWindowView` has already named the window
    /// and a second title would overwrite it with a less useful one.
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
                if let notice = state?.notice, !notice.isEmpty {
                    Banner(text: notice, tone: .neutral)
                        .accessibilityIdentifier("browser.machine.window.settingsNotice")
                }
                content
            }
            .background(Theme.background)
            .navigationTitle(phoneTab == nil ? "Window settings" : "Page settings")
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

    @ViewBuilder
    private var cards: some View {
        if phoneTab != nil {
            phonePageCards
        } else if let window {
            notWatchable
            isolationCard(window)
            sessionCard(window)
            screenshotCard
            recordingCard(window)
            closeCard(window)
        } else if surface != nil {
            noWindowCards
        } else {
            ProgressView()
                .controlSize(.regular)
                .frame(maxWidth: .infinity)
                .padding(.top, 40)
                .accessibilityIdentifier("browser.machine.window.settingsLoading")
        }
    }

    /* ---- a page this phone is drawing ------------------------------------- */

    /**
     * The settings of a page **this phone** is holding open over a tunnel.
     *
     * > *"all of them should be identical, and all of them should have all the
     * > options. Should not be that much of difference in all of them."*
     *
     * A page like this used to have no settings screen at all: the row on the
     * Browser tab opened the page, the page had no `…`, and everything a window
     * on the machine could be asked for was simply somewhere this kind of window
     * did not go. So the comparison he was making — this row can do four things,
     * that row can do one — was true, and the honest fix is not to grey four rows
     * here. It is to work out which of them can **really** be done for a page
     * this phone renders, and to build those.
     *
     * Four can:
     *
     *  - **Attach to a session.** Not this page — an agent cannot reach this
     *    app's own web view and never will. Attaching opens the same address in
     *    the machine's browser and binds *that* window, in one ask, and the card
     *    says so in a sentence rather than implying the page moved.
     *  - **Screenshot, with a note, sent to a session.** This phone renders the
     *    page, so this phone can photograph it. See `PhonePageShot`.
     *  - **Open in the machine's browser** — the honest analogue of the
     *    isolation row. There is no shared-or-isolated to convert here because
     *    the page is not in that browser at all; what there is is the move to
     *    put it there, which is the same one the new-window sheet offers.
     *  - **Close this window.** It was already real.
     *
     * One cannot, and it is left out rather than greyed: the **click-flow
     * recorder** is the machine's recorder watching the machine's own browser
     * (`src/main/browser-steps.ts`), and there is nothing for it to watch here.
     * A dead Record button would be a control that can never work in any state,
     * which is worse than an absence with a reason — so the reason is on the ⓘ
     * at the top of the screen, and it names the move that gets him a recording:
     * open the page over there.
     *
     * Nothing here is optimistic. The attach and the open both answer with the
     * whole window list, which redraws the Browser tab and carries the machine's
     * own notice; the two acts that leave nothing behind — a picture starting to
     * upload — hold a line for two and a half seconds saying what was asked, the
     * same way every other silent act in this app does.
     */
    @ViewBuilder
    private var phonePageCards: some View {
        if let tab {
            phoneIdentityCard(tab)
            phoneSessionCard(tab)
            phoneScreenshotCard(tab)
            phoneOtherWayCard(tab)
            phoneCloseCard(tab)
        } else {
            /*
             * Closed while this screen was up — usually by the Close card below,
             * because nothing pops this screen.
             *
             * `MachineWindowView` owns the one watcher that pops a window's pair
             * of screens when the machine stops listing it, and there is no such
             * watcher for a tab this phone owns. Saying the page is gone is
             * better than popping out from under a thumb, and it is what the rest
             * of this file already does.
             */
            SchemeSectionCaption("This page")

            SchemeGroup {
                plainNote("This page is closed. It is not open on this phone any more.",
                          id: "browser.phone.page.gone")
            }
        }
    }

    /// What this page is, and where it is being served from. The mark is the
    /// same one the row on the Browser tab wears, so the two screens agree about
    /// which machine is drawing the pixels.
    @ViewBuilder
    private func phoneIdentityCard(_ tab: BrowserTab) -> some View {
        SchemeSectionCaption(
            "This page",
            about: "a page open on this phone",
            info: "This page is drawn by this app, over a tunnel to \(machineName). It is not a "
                + "window in \(machineName)'s browser, so it has its own cookies and its own "
                + "logins.\n\nEverything on this screen works on it except recording a click "
                + "flow. That recorder is \(machineName)'s, and it watches \(machineName)'s own "
                + "browser — it cannot see a page this phone is drawing. Open this address in "
                + "\(machineName)'s browser, below, and the recorder is on that window.")

        SchemeGroup {
            VStack(alignment: .leading, spacing: 4) {
                Text(tab.label)
                    .font(.system(size: 16))
                    .foregroundStyle(Theme.primary)
                    .lineLimit(1)
                    .accessibilityIdentifier("browser.phone.page.title")
                Text(phoneAddress(tab))
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(Theme.faint)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .accessibilityIdentifier("browser.phone.page.address")
                HStack(spacing: 6) {
                    MachineWindowMark(text: "On this phone", tone: Theme.secondary)
                    Spacer(minLength: 0)
                }
                .padding(.top, 2)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 13)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /**
     * *"How to connect to it"*, for a page the machine is not showing.
     *
     * The picker is the same picker the machine's windows get and the verb
     * behind it is the same one — `browser.window.open`, carrying the session so
     * the host binds before it answers. What is different is the sentence under
     * it, and that sentence is the whole reason this control is allowed to
     * exist: the page on this phone does not move, a second window opens on the
     * machine at the same address, and that window has the machine's cookies.
     * Somebody signed into a dev server here may not be signed in over there.
     * A card that said "Attached" and left that out would be the app claiming
     * something it cannot do.
     */
    @ViewBuilder
    private func phoneSessionCard(_ tab: BrowserTab) -> some View {
        SchemeSectionCaption(
            "Session",
            about: "attaching a page to a session",
            info: "A session's agent can drive a window in \(machineName)'s browser. It cannot "
                + "reach a page this phone is drawing — the page is rendered here, in this app."
                + "\n\nSo attaching opens this same address in \(machineName)'s browser and "
                + "attaches that window. It gets a slot name — B1, B2 — and the session's tools "
                + "address it by that name.")

        SchemeGroup {
            if canDrive && !sessions.isEmpty {
                Menu {
                    ForEach(sessions) { session in
                        Button {
                            attachOnMachine(tab, to: session.id)
                        } label: {
                            Label(MachineBrowserText.sessionRow(session), systemImage: "terminal")
                        }
                    }
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "link")
                            .font(.system(size: 17, weight: .light))
                            .foregroundStyle(Theme.accent)
                            .frame(width: 24)
                        Text("Open on \(machineName) and attach")
                            .font(.system(size: 16))
                            .foregroundStyle(Theme.accent)
                        Spacer(minLength: 8)
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Theme.faint)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 13)
                    .contentShape(Rectangle())
                }
                .accessibilityIdentifier("browser.phone.page.attach")

                rowDivider(inset: 16)

                plainNote("The page stays open here, untouched. What the session gets is a new "
                          + "window on \(machineName) at this address, with \(machineName)'s own "
                          + "cookies and logins — it may not be signed in the same way.",
                          id: "browser.phone.page.attachNote")
            } else if canDrive {
                // No control at all rather than a picker with nothing in it: a
                // machine running no sessions has nowhere to bind, and the fix is
                // a session rather than anything on this screen.
                plainNote("No sessions on \(machineName) to attach it to.",
                          id: "browser.phone.page.noSessions")
            } else {
                deadRow("Open on \(machineName) and attach", icon: "link",
                        id: "browser.phone.page.attach",
                        why: "\(machineName) is not offering its browser to this phone, so no "
                            + "window can be opened there to attach.")
            }
        }
    }

    /**
     * Photograph the page, and choose who gets the photograph.
     *
     * The same two controls the machine's windows get, for the same reason —
     * looking at it here and handing it to an agent are different acts with
     * different outcomes — and the same note field, on the same card, because
     * *"creating a screenshot and sending it to the session, whatever session we
     * want to send"* is one move rather than two screens.
     *
     * ## How a picture gets from this phone into a session
     *
     * There is no `browser.window.shot` to lean on: that verb photographs a
     * window in the **machine's** browser and hands the bytes to a session at the
     * machine's end, and this page is not in that browser. So this phone does
     * both halves itself. The sentence goes first, through `sendToAgent`, which
     * attaches the session when this phone has not opened it — and that ordering
     * is load-bearing rather than tidy: `HostLink.send(_:into:)` drops the landed
     * path in silence for a session with no bridge, so a picture sent to a
     * session nobody had opened would upload perfectly and arrive nowhere. The
     * file follows, and its path lands in that same prompt when the upload
     * finishes. Nothing is submitted — the same rule every other "sent to an
     * agent" path in this app follows, and the reason there is no newline
     * anywhere in it.
     */
    @ViewBuilder
    private func phoneScreenshotCard(_ tab: BrowserTab) -> some View {
        SchemeSectionCaption(
            "Screenshot",
            about: "photographing a page on this phone",
            info: "This phone takes the picture itself. It loads the address again in a web view "
                + "of its own and photographs that — so what you get is the page as it loads now, "
                + "not the scroll position or the half-filled form you left behind. It is the "
                + "same signed-in browser, so a page you are logged into is photographed logged "
                + "in.\n\nSent to a session, the picture is uploaded to \(machineName) and its "
                + "file name is typed into that session with your note. Press Return there to "
                + "send it.")

        SchemeGroup {
            if canSendShot {
                HStack(spacing: 12) {
                    Image(systemName: "text.bubble")
                        .font(.system(size: 17, weight: .light))
                        .foregroundStyle(Theme.faint)
                        .frame(width: 24, height: 26)
                    TextField("Note for the session (optional)", text: $shotNote)
                        .textFieldStyle(.plain)
                        .font(.system(size: 15))
                        .foregroundStyle(Theme.primary)
                        .submitLabel(.done)
                        .accessibilityIdentifier("browser.phone.page.shotNote")
                }
                .padding(.leading, 16)
                .padding(.trailing, 12)
                .padding(.vertical, 10)

                rowDivider(inset: 16)
            }

            HStack(spacing: 0) {
                Button {
                    Task { await takePhoneShot(tab) }
                } label: {
                    VStack(spacing: 5) {
                        Image(systemName: "camera")
                            .font(.system(size: 17, weight: .medium))
                        Text("Screenshot")
                            .font(.system(size: 11))
                    }
                    .foregroundStyle(shot.phase == .working ? Theme.faint : Theme.accent)
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(shot.phase == .working)
                .accessibilityHint("Takes a picture of this page and shows it here")
                .accessibilityIdentifier("browser.phone.page.shot")

                if canSendShot {
                    Menu {
                        ForEach(agentSessions) { session in
                            Button {
                                sendPhoneShot(to: session.id, tab: tab)
                            } label: {
                                Label(session.title, systemImage: "terminal")
                            }
                        }
                    } label: {
                        VStack(spacing: 5) {
                            Image(systemName: "paperplane")
                                .font(.system(size: 17, weight: .medium))
                            Text("Send to a session")
                                .font(.system(size: 11))
                        }
                        .foregroundStyle(shot.png == nil ? Theme.faint : Theme.accent)
                        .frame(maxWidth: .infinity)
                        .contentShape(Rectangle())
                    }
                    .disabled(shot.png == nil)
                    .accessibilityLabel("Send a screenshot to a session")
                    .accessibilityHint(shot.png == nil
                                       ? "Take the picture first — there is nothing to send yet"
                                       : "Uploads the picture and types its name into that session")
                    .accessibilityIdentifier("browser.phone.page.shotTo")
                }
            }
            .padding(.vertical, 12)

            switch shot.phase {
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

            if let picture = shot.image {
                rowDivider(inset: 16)
                VStack(alignment: .leading, spacing: 8) {
                    Image(uiImage: picture)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: .infinity)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(Theme.hairline))
                        .accessibilityLabel("Screenshot of \(tab.label)")
                        .accessibilityIdentifier("browser.phone.page.picture")

                    if let line = SessionDetails.activityLine(shot.takenAt) {
                        Text("Taken \(line)")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.faint)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 13)
            }

            if let sentLine {
                rowDivider(inset: 16)
                plainNote(sentLine, id: "browser.phone.page.sent")
            }
        }
    }

    /// Whether a picture has anywhere to go. Both halves are real conditions: a
    /// machine that will not take a file, and a machine with nothing running to
    /// hand one to.
    private var canSendShot: Bool { model.canSendFiles && !agentSessions.isEmpty }

    /**
     * The honest analogue of the isolation row.
     *
     * A window on the machine can be moved between the shared jar and a
     * partition of its own. This page is in neither, because it is not in that
     * browser — so the row that belongs here is the one that puts it there, and
     * the card says what changes when it does. The page on this phone is left
     * exactly as it is; the sheet's own `otherWay` offers the same move from the
     * other end.
     *
     * No sentence of its own on the press. `browser.window.open` answers with the
     * whole window list carrying the machine's own notice, and on this screen
     * that notice is the banner two inches above this card — a second line here
     * would be the same fact twice, and the one written here would be a guess
     * printed before the machine had agreed to anything.
     */
    @ViewBuilder
    private func phoneOtherWayCard(_ tab: BrowserTab) -> some View {
        SchemeSectionCaption(
            "Open somewhere else",
            about: "opening this address on the machine",
            info: "The same address can be opened in \(machineName)'s own browser. That window is "
                + "\(machineName)'s: it uses \(machineName)'s cookies and logins, it can be "
                + "watched and driven from this phone, and it can record a click flow. The page "
                + "here is left exactly as it is — you end up with both.")

        SchemeGroup {
            if canDrive {
                Button {
                    host?.openMachineWindow(url: phoneAddress(tab), isolated: false)
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "globe")
                            .font(.system(size: 19, weight: .light))
                            .frame(width: 24)
                        Text("Open in \(machineName)'s browser")
                            .font(.system(size: 16))
                        Spacer(minLength: 0)
                    }
                    .foregroundStyle(Theme.accent)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 13)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityHint("Opens a second window at this address on \(machineName)")
                .accessibilityIdentifier("browser.phone.page.otherWay")
            } else {
                deadRow("Open in \(machineName)'s browser", icon: "globe",
                        id: "browser.phone.page.otherWay",
                        why: "\(machineName) is not offering its browser to this phone.")
            }
        }
    }

    /**
     * Close the page, from inside its settings.
     *
     * This phone's own socket, so it takes effect immediately and there is no
     * answer to wait for — the one act on this screen that is not a round trip.
     * Nothing is dismissed on the press, for the reason this file's header
     * gives: `phonePageCards` draws the closed state instead, which is honest
     * and does not pop a screen out from under a thumb.
     */
    @ViewBuilder
    private func phoneCloseCard(_ tab: BrowserTab) -> some View {
        SchemeSectionCaption("Window")

        SchemeGroup {
            Button {
                model.browserTabs.close(tab, machine: model)
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "xmark.circle")
                        .font(.system(size: 19, weight: .light))
                        .frame(width: 24)
                    Text("Close this window")
                        .font(.system(size: 16))
                    Spacer(minLength: 0)
                }
                .foregroundStyle(Theme.critical)
                .padding(.horizontal, 16)
                .padding(.vertical, 13)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint("Closes this page and the tunnel it was using, on this phone")
            .accessibilityIdentifier("browser.phone.page.close")
        }
    }

    // MARK: - What a page on this phone can be asked for

    /// The address this page is on, as the machine would have to be given it.
    /// `String(port)` and never the `Int` interpolated: a port dropped straight
    /// into a Swift string is formatted with the locale's grouping separator and
    /// comes out as `localhost:3,000`.
    private func phoneAddress(_ tab: BrowserTab) -> String {
        "http://localhost:\(String(tab.port))\(tab.path)"
    }

    /// Open this address on the machine and hand that window to a session, in
    /// one ask. The confirmation is the machine's own answer — the window list
    /// comes back carrying the bind notice, which the banner above draws.
    private func attachOnMachine(_ tab: BrowserTab, to session: String) {
        host?.openMachineWindow(url: phoneAddress(tab), isolated: false, session: session)
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
            shot.fail("This phone could not reach \(machineName) on that port, so there was "
                      + "nothing to photograph.")
            return
        }
        await shot.take(url: url)
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
        guard let png = shot.png, !png.isEmpty else { return }
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
        say("Sending it. The picture's name is typed into that session — press Return there to "
            + "send it.")
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

    /* ---- a page the machine has no window row for -------------------------- */

    /**
     * The same two controls he named, and they cannot act.
     *
     * > *"there is no way to attach this one too. So it should be the same case,
     * > or all the options should be available at least."*
     *
     * The reason is drawn once, at the top, and both controls under it are dead.
     * That is the shape rather than a hint on each: *why is this page different*
     * is one fact about the page, and repeating it under two buttons is two
     * places for it to drift.
     *
     * The session picker is drawn as a dead row **even where the machine has
     * sessions** — the picker itself would work and the verb behind it would be
     * refused before it left this phone, so offering the choice would be a menu
     * that ends in nothing.
     */
    @ViewBuilder
    private var noWindowCards: some View {
        SchemeSectionCaption(
            "This page",
            about: "a page with no window row",
            info: "The machine names each of its windows with an id, and every window verb — "
                + "attaching to a session, closing, isolating, the screenshot, the click flow — is "
                + "addressed by that id. This page is one the machine's window list does not name, "
                + "so none of those can be sent for it.\n\nIt can still be watched.")

        SchemeGroup {
            plainNote(whyNoWindow, id: "browser.machine.window.noWindowRow")
        }

        SchemeSectionCaption(
            "Session",
            about: "window binding",
            info: "A bound window gets a slot name — B1, B2 — and the session's tools address it by "
                + "that name. The machine addresses the binding by the window's id, which this page "
                + "does not have.")

        SchemeGroup {
            deadRow("Attach to a session", icon: "link",
                    id: "browser.machine.window.attach",
                    why: "This page has no window id for the machine to bind.")
        }

        SchemeSectionCaption("Window")

        SchemeGroup {
            deadRow("Close this window", icon: "xmark.circle",
                    id: "browser.machine.window.close",
                    why: "This page has no window id for the machine to close.")
        }
    }

    /**
     * Which of the two pages with no window row this is, said out loud.
     *
     * The empty id is the machine's **own tab** — the slot `openTab` mints no
     * shell id for, where a page opened from the phone's address bar lands — and
     * it is by far the common one. A non-empty id that no window row names is the
     * other: a cast this list cannot join to a window, which is what a machine
     * offering `watch` without `browser.control` produces. Naming the right one
     * matters because the two have different fixes and only one of them is
     * ordinary.
     */
    private var whyNoWindow: String {
        let name = model.current?.label ?? model.theMachine
        if windowID.isEmpty {
            return "This is \(name)'s own tab rather than one of its windows, so it cannot be "
                + "attached to a session, closed, isolated, photographed or recorded from here. "
                + "Watching it and typing an address are the two things it does take."
        }
        return "\(name) is casting this page and its window list does not name it, so it cannot be "
            + "attached to a session, closed, isolated, photographed or recorded from here. "
            + "Watching it is what it takes."
    }

    /**
     * A control in its place, greyed, with the reason on the hint.
     *
     * `.disabled(true)` rather than a button that answers with a sentence: a
     * control that replies instead of acting is still a control that did not do
     * what it says. The line above the card is where the reason is read; this is
     * what keeps the screen the same screen.
     */
    private func deadRow(_ title: String, icon: String, id: String, why: String) -> some View {
        Button {} label: {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 17, weight: .light))
                    .frame(width: 24)
                Text(title)
                    .font(.system(size: 16))
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

    /* ---- why there is no picture, when there is a reason ------------------- */

    /**
     * One line, drawn only where it answers a question somebody is holding.
     *
     * The question is *why am I looking at settings instead of at the page*, and
     * it only exists in the inline shape on a machine that does cast other
     * windows. See the file header for the two conditions and why each is
     * separate.
     *
     * A sentence rather than a disabled Watch row. It is a real state and not a
     * fault — a server lists a window opened from the phone's own `+` under
     * `browser.window.rows` and not under `browser.surfaces` — and the ⓘ carries
     * the why, so the line itself stays one line.
     */
    @ViewBuilder
    private var notWatchable: some View {
        if !pushed && canWatch {
            SchemeSectionCaption(
                "Live",
                about: "watching a window",
                info: "The machine streams a page as pictures and sends your taps, swipes and typing "
                    + "back to it. Not every window can be streamed: a server offers its own front "
                    + "tab and the windows its sessions hold, and one opened from the + here can be "
                    + "driven without being watched.")

            SchemeGroup {
                plainNote("This machine is not offering this window for watching.",
                          id: "browser.machine.window.notWatchable")
            }
        }
    }

    /* ---- shared or its own jar --------------------------------------------- */

    /**
     * Which jar this window's cookies land in, and the one control that moves it.
     *
     * *"Making a browsing session into an isolated or shared one."* It is
     * convertible in both directions and the word on the button is the
     * destination rather than the state, because the state is already the line
     * beside it — a button saying "Isolated" next to a label saying "Shared" is
     * two readings of the same word and somebody will press it to find out.
     *
     * The choice is also offered at the moment a window is opened, on the
     * Browser tab's `+`, and that is not a duplicate control: a login typed into
     * a window that turned out to be shared is already in the machine's jar by
     * the time anybody thinks to convert it, so the choice has to exist before
     * the window does *and* after.
     */
    @ViewBuilder
    private func isolationCard(_ window: MachineWindow) -> some View {
        SchemeSectionCaption(
            "Isolation",
            about: "isolated windows",
            info: "A shared window uses the machine's own profile — its cookies and whatever it is "
                + "signed into. An isolated one gets a partition of its own, and that partition is "
                + "thrown away when the window closes.")

        SchemeGroup {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(window.isolated ? "Isolated" : "Shared")
                        .font(.system(size: 16))
                        .foregroundStyle(Theme.primary)
                    if let profile = window.profile, !profile.isEmpty, !window.isolated {
                        Text(profile)
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.faint)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                Button {
                    host?.actOnMachineWindow(windowID, window.isolated ? .share : .isolate)
                } label: {
                    Text(window.isolated ? "Make shared" : "Make isolated")
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
    }

    /* ---- which session owns it --------------------------------------------- */

    /**
     * *"How to connect to it"* — the headline of this screen, and the reason
     * this family exists at all.
     *
     * > *"We don't have an option to connect any browsing window to any session,
     * > so the session knows which browsing window it is working on."*
     *
     * The desktop has had this since `src/main/browser-binding.ts`; what the
     * phone lacked was a way to press it. A bound window gets a slot name — `B1`,
     * `B2` — and the session's tools address it by that name, which is why the
     * slot is drawn as an identifier rather than as a status: it is the word
     * appearing in that agent's transcript.
     *
     * It is also on the row's `…` on the home, deliberately, because attaching is
     * one of the three things he named as a thing you do to a window *from the
     * outside*. Both reach the same verb with the same picker.
     */
    @ViewBuilder
    private func sessionCard(_ window: MachineWindow) -> some View {
        SchemeSectionCaption(
            "Session",
            about: "window binding",
            info: "A bound window gets a slot name — B1, B2 — and the session's tools address it by "
                + "that name. A session that already holds three windows names the next one B4.")

        SchemeGroup {
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
            }

            if !sessions.isEmpty {
                if window.isBound { rowDivider(inset: 16) }
                Menu {
                    ForEach(sessions) { session in
                        Button {
                            host?.bindMachineWindow(windowID, to: session.id)
                        } label: {
                            Label(MachineBrowserText.sessionRow(session),
                                  systemImage: session.id == window.session ? "checkmark" : "terminal")
                        }
                    }
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "link")
                            .font(.system(size: 17, weight: .light))
                            .foregroundStyle(Theme.accent)
                            .frame(width: 24)
                        Text(window.isBound ? "Attach to another session" : "Attach to a session")
                            .font(.system(size: 16))
                            .foregroundStyle(Theme.accent)
                        Spacer(minLength: 8)
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Theme.faint)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 13)
                    .contentShape(Rectangle())
                }
                .accessibilityIdentifier("browser.machine.window.attach")
            } else if !window.isBound {
                // No control at all rather than a picker with nothing in it: a
                // machine running no sessions has nowhere to bind, and the fix
                // is a session rather than anything on this screen.
                plainNote("No sessions on the machine.", id: "browser.machine.window.noSessions")
            }
        }
    }

    /* ---- what it looks like ------------------------------------------------ */

    /**
     * Photograph it, and choose who gets the photograph.
     *
     * Two controls, because they have two outcomes — see the file header. The
     * note travels only with the second, so it is drawn only when there is a
     * session to send to; a field whose contents can never leave the phone is a
     * control that cannot act.
     */
    @ViewBuilder
    private var screenshotCard: some View {
        SchemeSectionCaption("Screenshot")

        SchemeGroup {
            if !sessions.isEmpty {
                HStack(spacing: 12) {
                    Image(systemName: "text.bubble")
                        .font(.system(size: 17, weight: .light))
                        .foregroundStyle(Theme.faint)
                        .frame(width: 24, height: 26)
                    TextField("Note for the session (optional)", text: $shotNote)
                        .textFieldStyle(.plain)
                        .font(.system(size: 15))
                        .foregroundStyle(Theme.primary)
                        .submitLabel(.done)
                        .accessibilityIdentifier("browser.machine.window.shotNote")
                }
                .padding(.leading, 16)
                .padding(.trailing, 12)
                .padding(.vertical, 10)

                rowDivider(inset: 16)
            }

            HStack(spacing: 0) {
                Button {
                    host?.shotMachineWindow(windowID)
                } label: {
                    VStack(spacing: 5) {
                        Image(systemName: "camera")
                            .font(.system(size: 17, weight: .medium))
                        Text("Screenshot")
                            .font(.system(size: 11))
                    }
                    .foregroundStyle(Theme.accent)
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityHint("Takes a picture of this window and shows it here")
                .accessibilityIdentifier("browser.machine.window.shot")

                if !sessions.isEmpty {
                    Menu {
                        ForEach(sessions) { session in
                            Button {
                                send(to: session.id)
                            } label: {
                                Label(MachineBrowserText.sessionRow(session), systemImage: "terminal")
                            }
                        }
                    } label: {
                        VStack(spacing: 5) {
                            Image(systemName: "paperplane")
                                .font(.system(size: 17, weight: .medium))
                            Text("Send to a session")
                                .font(.system(size: 11))
                        }
                        .foregroundStyle(Theme.accent)
                        .frame(maxWidth: .infinity)
                        .contentShape(Rectangle())
                    }
                    .accessibilityLabel("Send a screenshot to a session")
                    .accessibilityIdentifier("browser.machine.window.shotTo")
                }
            }
            .padding(.vertical, 12)

            if let picture {
                rowDivider(inset: 16)
                VStack(alignment: .leading, spacing: 8) {
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
                    Image(uiImage: picture)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: .infinity)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(Theme.hairline))
                        .accessibilityLabel("Screenshot of \(window?.label ?? "this window")")
                        .accessibilityIdentifier("browser.machine.window.picture")

                    if let line = SessionDetails.activityLine(shot?.at) {
                        Text("Taken \(line)")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.faint)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 13)
            }
        }
    }

    /* ---- what it recorded -------------------------------------------------- */

    /**
     * The click flow, and the fact that it is running.
     *
     * *"Recording the clicks flow"* is the one control on this screen with a
     * state somebody can walk away from, so it says so twice — the word on the
     * button changes, and a red mark sits beside it — and the row on the Browser
     * tab's home says it a third time. A page quietly collecting every
     * interaction is not something to learn about by opening a screen.
     *
     * `readMachineSteps` is the only way to see what was collected: the steps are
     * not on the window list and there is no push for them. So they are asked for
     * on arrival, again the moment a recording stops, and on the control beside
     * the toggle — which is the honest answer for a flow that is still growing
     * while somebody is looking at it.
     */
    @ViewBuilder
    private func recordingCard(_ window: MachineWindow) -> some View {
        SchemeSectionCaption("Click flow")

        SchemeGroup {
            HStack(spacing: 12) {
                Button {
                    host?.actOnMachineWindow(windowID, window.recording ? .recordOff : .recordOn)
                } label: {
                    HStack(spacing: 9) {
                        Image(systemName: window.recording ? "stop.circle" : "record.circle")
                            .font(.system(size: 19, weight: .light))
                            .frame(width: 24)
                        Text(window.recording ? "Stop recording" : "Record the click flow")
                            .font(.system(size: 16))
                    }
                    .foregroundStyle(window.recording ? Theme.critical : Theme.accent)
                    .contentShape(Rectangle())
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

            if !steps.isEmpty {
                let first = steps.first?.at ?? 0
                ForEach(steps) { step in
                    rowDivider(inset: 16)
                    stepRow(step, from: first)
                }
            } else if window.recording {
                rowDivider(inset: 16)
                plainNote("Nothing yet.", id: "browser.machine.window.noSteps")
            }
        }

        /*
         * The cut, for the same reason and with the same limit as the window
         * list's: `WireCodec.recordedSteps` takes a `prefix` and keeps no record
         * of what it dropped, so this can say there may be more and cannot say
         * how many. The host caps its own side as well — see `MAX_STEPS` in
         * `src/main/browser-steps.ts` — which is the cap somebody would actually
         * hit first.
         */
        if steps.count >= MachineBrowserWire.maxSteps {
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

    /**
     * One step: when, what, and to what.
     *
     * The offset is relative to the first step rather than a clock time, because
     * a flow is read as a sequence — *click, type, click, submit* — and the
     * useful question about step nine is how long after step one it happened.
     * `at` is the machine's main-process clock in epoch milliseconds, stamped
     * there rather than by the page: *"the page never gets to stamp its own
     * steps"* (`src/main/browser-steps.ts`).
     */
    private func stepRow(_ step: RecordedStep, from first: Double) -> some View {
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
        .accessibilityIdentifier("browser.machine.window.step.\(step.index)")
    }

    /* ---- and the end of it ------------------------------------------------- */

    /**
     * Close the window, from inside it.
     *
     * Last, alone, and away from everything else on the screen, because it is
     * the one control here that ends something. It is also on the home's row —
     * on the `…` and on the swipe — which is not a duplicate: closing a window
     * you are looking at and closing one from a list are two different moments,
     * and the list's whole point is not having to open a window to deal with it.
     *
     * Nothing is dismissed on the press. `MachineWindowView` watches for the
     * window leaving the machine's list and pops both screens then — see this
     * file's header on why that watcher is not also here.
     */
    @ViewBuilder
    private func closeCard(_ window: MachineWindow) -> some View {
        SchemeSectionCaption("Window")

        SchemeGroup {
            Button {
                host?.actOnMachineWindow(windowID, .close)
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "xmark.circle")
                        .font(.system(size: 19, weight: .light))
                        .frame(width: 24)
                    Text("Close this window")
                        .font(.system(size: 16))
                    Spacer(minLength: 0)
                }
                .foregroundStyle(Theme.critical)
                .padding(.horizontal, 16)
                .padding(.vertical, 13)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint("Closes \(window.label) in \(model.theMachine)'s browser")
            .accessibilityIdentifier("browser.machine.window.close")
        }
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

    // MARK: - Actions

    private func send(to session: String) {
        let line = shotNote.trimmingCharacters(in: .whitespacesAndNewlines)
        host?.shotMachineWindow(windowID, to: session, note: line.isEmpty ? nil : line)
        shotNote = ""
    }

    private func refreshPicture() {
        guard let data = shot?.png, !data.isEmpty else {
            picture = nil
            return
        }
        picture = UIImage(data: data)
    }

    // MARK: - Chrome

    /**
     * A line of prose as a row inside a card.
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
