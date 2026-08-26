/**
 * One window of the machine's browser — **the window itself**, with a browser's
 * bar under it and everything else behind its `…`. Every row on the Browser tab
 * that is a page on the machine opens this, and there is no second kind.
 *
 * ## There used to be two kinds of browser window, and he counted them
 *
 * > *"this one is the one with the full view. But with the full view, at least it
 * > should have all the options. If I am even opening this one here, look, now
 * > here it is different. Now we have two windows. In iMatch, one of them has
 * > different menu options here in the bottom, the tab menu, and this one has
 * > different only reload, nothing else. So why they are two different type…
 * > **it should be the same case, or all the options should be available at
 * > least.**"*
 *
 * The two he was holding were a `.window` row — this screen, with an address,
 * Back, Forward, Reload and a `…` — and a `.surface` row, which opened
 * `WatchViewerScreen`: a picture, an address only where `web` was offered, and a
 * single Reload. Both are pages in the same browser on the same machine, and the
 * thing that made them different is invisible from a phone: one of them is named
 * by a shell tab id and the other is the drive's own front slot, which
 * `openTab` mints no id for.
 *
 * So the Browser tab pushes this screen for both, and this screen holds the
 * difference instead of the list doing it. `windowID` is `""` for the machine's
 * own front tab, which is a name and not a missing value — the same empty string
 * `browser.surfaces` calls it by. What that page can and cannot be asked for is
 * on `bar` and on `whyLimited`, and the answer to *cannot* is a greyed control
 * with a sentence behind it rather than a control that is not there.
 *
 * `WatchViewerScreen` still exists and is still the one canvas mount for a
 * surface reached from **Settings**, where there is no model behind it and no
 * window list to join against. Nothing on the Browser tab reaches it.
 *
 * ## What this screen used to be, and why it is the page now
 *
 * It was a stack of cards: a Live row that pushed a viewer, an address, four
 * page verbs, an isolation control, the session binding, two screenshots and the
 * click recorder. Every one of those is still reachable and only one of them is
 * on this screen. Asad, after the Browser tab was rebuilt:
 *
 * > *"we should be able just to see only the open windows, and then we can just
 * > click on any of them… When we click on three dots then we can see the
 * > settings — per window also, inside the window: settings of per window, how
 * > to connect to it, how to make it shared or isolated, all of these things
 * > should be inside of the window."*
 *
 * Tapping a window gives you the window. Its settings are behind a `…` **on this
 * screen** — the trailing item in its header — which is the sentence's second
 * half, *inside of the window*, and they are `MachineWindowSettingsView`.
 *
 * ## One way: a session opens a window, a window never opens a session
 *
 * Under the page there was a row naming the session this window belongs to,
 * with a chevron into that session's terminal — and the way back out of the
 * terminal was another button onto this same page. He walked the loop and
 * called it *"too complicated"*: *"this page should be purely for only browser,
 * not for terminal too. Terminal is only here, and only terminal is giving the
 * browser window too. But browser side, it should not give the terminal window
 * too."* The full quote, and what else stood in that space, are on `stage`.
 *
 * So nothing on the Browser tab reaches a session any more — not this screen,
 * not the list behind it. The reverse direction is untouched and is the half he
 * wants: a session opens the browser window it is bound to, in `SessionPageView`.
 * Which session owns a window is still on the window — it is a window setting
 * behind the header's `…`, in `MachineWindowSettingsView`, where attaching and
 * detaching already live.
 *
 * ## Two shapes, because the two capabilities come apart
 *
 * `browser.control` (drive it) and `watch` (see it) are negotiated in different
 * fields of `RemoteEndpointOptions` and withheld on different grants, so a
 * machine can offer either without the other and this screen has to be honest in
 * both directions:
 *
 *  - **The machine is casting this window** — the body is the live picture,
 *    full-bleed, and the `…` in the header leads to the settings. This is the
 *    ordinary shape.
 *  - **It is not** — the body *is* the settings, and there is no `…` in the
 *    header, because a control leading to the screen you are already looking at
 *    is the worst kind of dead control. A line at the top of it says the machine
 *    is not offering this window for watching, and only when the machine
 *    advertises `watch` at all: on a host that never offered a cast, a sentence
 *    about one is an apology for a feature that was never on the table.
 *
 * The second case is not an error and it is not rare. A server lists a window
 * opened from the Browser tab's `+` under `browser.window.rows` and **not**
 * under `browser.surfaces`: it is minted through `openForSession(NO_SESSION)`
 * and detached in the same breath, so it holds no binding row and `castWindows`
 * cannot see it. `src/headless/host.ts` records that as the honest state — *"a
 * row that refuses when it is tapped"* being the thing it is avoiding.
 *
 * ## What the machine's own front tab can and cannot be asked, measured
 *
 * Every verb in the `browser.window.*` family is addressed by a window id, and
 * `src/main/remote/protocol.ts` refuses an **empty** one on every single member
 * of it — `go`, `act`, `bind`, `shot`, `steps` each open with
 * `rawId === '' → bad(…)`. So for the front tab, Back, Forward, Reload, attaching
 * to a session, detaching, the screenshot, the recorder and Close are not
 * *withheld* by this app: they cannot be put on the wire at all. The settings
 * screen behind the `…` is still opened for it — that screen is where those
 * controls are drawn dead with the reason, which is what *"all the options
 * should be available at least"* asks for — so nothing here may say the
 * settings cannot be opened. See `whyLimited`.
 *
 * What it **can** be asked is `web.open`, and only because of where that verb
 * lands. On a headless host `openUrl` is `browserDrive.open({ url, isolate:
 * false })`, which is the drive's own slot — the same page this screen is
 * showing — so typing an address moves this page rather than opening a second
 * one. That is the address bar, and Reload is the same call with the address the
 * surface reports.
 *
 * It is deliberately **not** offered for a surface with a real id that no window
 * row claims. `web.open` on the desktop is `openAppLink(mainWindow…)`, a new tab
 * in the app's own browser, and on a server it is the front slot: either way it
 * would move a *different* page than the one on screen. A control that acts on
 * something else is worse than one that is greyed out, so that case draws the
 * address read-only and says why.
 *
 * ## Whether it can be watched is an exact id match, never a guess
 *
 * A surface is named by the **shell tab id** — the same string this screen is
 * addressed by, chosen in `screencast-host.ts` so *"the two lists can be joined
 * without a second mapping"*. So the question is asked against what the machine
 * actually listed, and a viewer is never pointed at a name the host does not
 * know (which would be a canvas waiting forever for a frame nobody is sending).
 *
 * ## It holds an id, never a window
 *
 * Every verb on this family answers with the **whole** window list, so a
 * `MachineWindow` captured when this screen was pushed is stale the moment
 * anything on it is pressed. The id is stable and the row is looked up on every
 * redraw, which is also what makes the close case free: the window leaves the
 * list and this screen leaves the stack.
 *
 * ## The address field is seeded, not bound
 *
 * A two-way binding to the window's URL would fight the page: every navigation
 * pushes a new address and would rewrite the field under a thumb mid-word. So it
 * is seeded once and re-seeded on a real navigation **only while nobody is
 * typing**, which is the one rule that makes an address bar over a wire behave
 * like an address bar.
 *
 * ## Why the bar carries the page verbs and the settings screen does not
 *
 *
 * Because they are the same four verbs and drawing them twice is how two screens
 * end up disagreeing. They belong with the address, and the address belongs
 * under the page — that is what a browser is. What is left for the settings is
 * everything that is *about the window* rather than about the page it happens to
 * be showing: the jar its cookies land in, the session that owns it, the picture
 * and the recorder. That is also the line the `…` is on the other side of, which
 * is why it sits in the header rather than in the row of page verbs:
 *
 * > *"Maybe we can give some better one header also, not only the bottom, so we
 * > can have most of the important controls for the flow."*
 *
 * ## And why the bar itself is not written here any more
 *
 * `WatchViewerScreen` — the screen a page with **no window id** used to land on,
 * which on a server is where most of what the phone opens actually goes — had a
 * keyboard glyph and nothing else on it. Two screens showing a live page, with
 * two different amounts of browser on them, and the smaller one is the one he
 * was looking at when he said a window *"feels like just like a video… I cannot
 * touch the URL"*. The bar is `BrowserPageBar` and it is written once because
 * the Settings route still draws it over a surface with no model behind it.
 *
 * A verb a given page cannot honestly be asked for is passed as `nil` **with a
 * reason** now, and the bar draws it greyed in its own place rather than leaving
 * a gap: *"it should be the same case, or all the options should be available at
 * least."* A `nil` reason is the old behaviour and is what the Settings route
 * uses, where there is nothing to explain.
 */

import SwiftUI

struct MachineWindowView: View {
    let model: DeckModel

    /// Which window. See the header for why this is an id and not the window —
    /// and why `""` is a name rather than a missing one: it is the machine's own
    /// front tab, which `browser.surfaces` lists under exactly that.
    let windowID: String

    @State private var address = ""
    /// Whether the field has been filled from the window at least once. A window
    /// whose row has not landed yet has no URL to seed with, and seeding from
    /// the empty string would look like an address bar that cleared itself.
    @State private var seeded = false
    /// Whether somebody is in the address field, so a navigation does not
    /// rewrite it under a thumb. Owned by `BrowserPageBar` and mirrored here.
    @State private var editing = false

    /// Whether the bar is in its keys mode — which is also whether the canvas is
    /// holding the system keyboard, because the two are the same act. One bar
    /// with two jobs rather than two bars, which over a full-bleed canvas is the
    /// difference between a browser and a control panel.
    @State private var typing = false

    /// Whether the window's settings are pushed. A `Bool` rather than a
    /// destination value because there is exactly one thing this screen pushes.
    @State private var showingSettings = false

    /// Why the last thing typed was not sent, or nil — a `file:` URL, a port out
    /// of range. The machine's own refusals arrive on `state?.notice`; this is
    /// the half this phone decided.
    @State private var refused: String?

    /**
     * Whether a tap on the picture describes what is under it instead of
     * pressing it.
     *
     * The same mode the page on this phone has had, on the window that could not
     * have it — *"in the page, if I click on something, I don't have something
     * to, some option to specifically inspect one piece."* Held here rather than
     * in the canvas because it is the bar's state as much as the canvas's: the
     * dashed-box glyph fills while it is on, and the hint under the header says
     * what a tap will now do.
     *
     * Turned off by leaving the screen, and by the window closing under us. It is
     * deliberately **not** turned off by the sheet being put away: the next thing
     * anybody wants after describing one element is to describe the one beside
     * it, and making them press Inspect again between every two taps would be the
     * mode fighting the work.
     */
    @State private var inspecting = false

    /// What just happened with the agent, for a moment. The machine's own
    /// sentences arrive on `state?.notice`; this is the half about a line that
    /// left this phone.
    @State private var said: String?

    /// The height the canvas says the picture is being drawn at. Zero until the
    /// first frame lands. See `stage` for what it is for and
    /// `WatchSurface.onPageHeight` for why the canvas is the thing that knows.
    @State private var pageHeight: CGFloat = 0

    @Environment(\.dismiss) private var dismiss

    private var host: HostLink? { model.current }
    private var state: MachineBrowserState? { host?.machineBrowser }
    /// The window's own row, when the machine lists one. Nil for the machine's
    /// own front tab, which is a page in the same browser and in no window list.
    private var window: MachineWindow? { state?.windows.first { $0.id == windowID } }

    /**
     * Whether this page can be sent a `browser.window.*` verb at all.
     *
     * Both halves are load-bearing and neither implies the other. The machine has
     * to be offering `browser.control`, and this page has to **have a name that
     * family can carry**: every verb in it is addressed by a window id and
     * `src/main/remote/protocol.ts` refuses an empty one on all five, so the
     * machine's own front tab is undrivable however generous the machine is
     * being.
     *
     * Deliberately **not** *is there a row for this id in the window list*. A
     * window whose row has not landed yet is still a window this phone can name,
     * and gating on the row would draw a bar of dead controls for the first frame
     * of every push. A window that has genuinely gone answers with the list and a
     * notice, and `closed` takes the screen off the stack — which is the same way
     * this family reports every other refusal.
     */
    private var drivable: Bool { !windowID.isEmpty && host?.canDriveBrowser == true }

    /**
     * Whether `web.open` lands on **this** page.
     *
     * Only the machine's own front tab, and only where the machine advertised
     * `web`. Anywhere else that verb moves a different page — see the header —
     * and a control that acts on something else is not an address bar.
     */
    private var openable: Bool { windowID.isEmpty && liveSurface != nil && model.canOpenPages }

    /// Whether this machine will cast a window back at all. Asked of the
    /// connection as well as of the welcome, the way `HostLink.canDriveBrowser`
    /// is: a capability from the welcome of a socket that has since gone is a
    /// permission nobody can use.
    private var canWatch: Bool { model.connection.isLive && host?.watch.offered == true }

    /// The cast of *this* window, when the machine is offering one. Derived on
    /// every redraw rather than passed in: `browser.surfaces.rows` is pushed
    /// when the strip moves, and a value captured at push time would go on
    /// saying whatever was true then.
    private var liveSurface: BrowserSurfaceRow? {
        guard canWatch else { return nil }
        return host?.watch.surfaces.first { $0.window == windowID }
    }

    /**
     * The page is gone from a machine that is **still answering** — closed here,
     * closed at the machine, or closed by the session that owned it.
     *
     * Three separate absences and only their conjunction is a closed page. Nil
     * state is *not asked yet*. No window row is the ordinary state of the front
     * tab, so it can only mean *closed* when the machine has stopped casting a
     * surface for it either. And a connection that has dropped is not a page that
     * closed: the lists this reads go stale the moment the socket does, and a
     * screen that popped itself on a blip would take somebody off a page that is
     * still open on their machine.
     */
    private var closed: Bool {
        guard state != nil, model.connection.isLive else { return false }
        return window == nil && liveSurface == nil
    }

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()

            VStack(spacing: 0) {
                // The one outcome no redraw can show: a picture that went to a
                // session rather than to this phone, or an address the machine
                // refused. See `HostLink.shotMachineWindow`. This phone's own
                // refusal wins the space when there is one, because it is the
                // answer to the thing that was just typed.
                if let refused {
                    Banner(text: refused, tone: .warning)
                        .accessibilityIdentifier("browser.machine.window.refused")
                } else if let said {
                    // Above the machine's notice, because it is the answer to the
                    // thing that was just pressed and the notice is usually about
                    // the window list having been re-read.
                    Banner(text: said, tone: .neutral)
                        .accessibilityIdentifier("browser.machine.window.said")
                } else if let notice = state?.notice, !notice.isEmpty,
                          !notice.localizedCaseInsensitiveContains("cannot record a click flow") {
                    // The recorder's refusal is the ONE notice this banner does
                    // not draw. It is not news about the last press — it is a
                    // standing fact about the machine, and the Click flow card
                    // below now says it in its own place, greyed with the reason
                    // on its ⓘ. Drawn here as well it read as a contradiction:
                    // *"this machine's browser cannot record a click flow"* over
                    // a live blue **Record the click flow** two inches under it,
                    // which is the screen Asad photographed.
                    Banner(text: notice, tone: .neutral)
                        .accessibilityIdentifier("browser.machine.window.notice")
                }

                /*
                 * The load line, in the one place a browser has ever put it and
                 * the same place the page on this phone puts it — directly under
                 * the navigation bar. *"top, header and footer… should be same in
                 * all type of browsing windows"*, and this is the top: a page
                 * fetching something says so identically whichever kind of window
                 * it is in.
                 *
                 * `MachineWindow.loading` is a real field on the wire, so this is
                 * the machine's own answer rather than a guess made here. What
                 * cannot follow it across is Stop — there is no such verb in
                 * `MachineWindow.Act` — so the bar keeps a live Reload while this
                 * line runs. See `BrowserPageBar.stop`.
                 */
                if window?.loading == true {
                    ProgressView()
                        .progressViewStyle(.linear)
                        .tint(Theme.accent)
                        .accessibilityIdentifier("browser.machine.window.pageLoading")
                }

                /*
                 * What inspect mode is waiting for, in the same place and the same
                 * words the page on this phone puts it — *"all of them should be
                 * identical"* is about this as much as about the controls. At the
                 * top rather than beside the control that turned it on, which is
                 * at the bottom: this is a sentence about the page, and the page
                 * is what the eye is on.
                 *
                 * The verb differs by one word and it has to. On the phone's own
                 * page a tap is answered here; on a machine window it is a
                 * question for the machine, and the answer can be *nothing is
                 * there* or *the page has moved since that picture* — so the hint
                 * says *ask about it* rather than promising a description.
                 */
                if inspecting {
                    inspectHint
                    Divider().overlay(Theme.hairline)
                }

                stage
            }
        }
        // The page's own title, its address until it has one, and the noun only
        // while neither list has landed. One rule for every kind of window — see
        // `BrowserChrome.pageTitle`.
        .navigationTitle(pageTitle)
        .navigationBarTitleDisplayMode(.inline)
        /*
         * **The header carries a control, and it is the only `…` on this screen.**
         *
         * > *"Maybe we can give some better one header also, not only the bottom,
         * > so we can have most of the important controls for the flow, for this
         * > kind of things and whatever we require to get the job done."*
         *
         * The chevron, one line of title, and this. Nothing to read — *"we can
         * just see and enter"* — and the same trailing item on a window, an
         * isolated window, the machine's own front tab and a page on this phone.
         *
         * Drawn only where it opens something. On a window the machine will not
         * cast, `stage` draws `MachineWindowSettingsView` as the **body** of this
         * screen: a `…` there would lead to where you are already standing, so
         * there is none and there is no sentence about one either. The condition
         * is `liveSurface`, which is the same thing `stage` branches on, so the
         * two can never disagree about which shape this screen is in.
         */
        .toolbar {
            if liveSurface != nil {
                ToolbarItem(placement: .topBarTrailing) {
                    BrowserWindowActions(id: "browser.machine.window",
                                         open: { showingSettings = true })
                }
            }
        }
        .safeAreaInset(edge: .bottom) { bar }
        /*
         * The tab bar's floating pill would sit over the bar below, and over the
         * bottom of the page above it. This is the surface `DeckChrome` calls
         * `localhostPage` — *"a page from the machine"*, the whole thing you came
         * for, full height — and `DeckModel.localhostPageIsOpen` is the flag the
         * `TabView` reads. It exists for exactly this and it is set from the two
         * screens that are that surface: the tunnel page, and this.
         *
         * Cleared on the way out rather than by whoever comes next, so a Back
         * from anywhere — the chevron, the edge swipe, a window closing under us
         * — leaves the tab bar restored.
         */
        .onAppear {
            model.localhostPageIsOpen = true
            seed()
            // The surface list, for the one question this screen is shaped by.
            // `read()` rather than `ensureRead()`: nothing pushes
            // `browser.surfaces` unsolicited — `server.ts` has no
            // `surfacesChanged` — so a once-per-connection ask would answer
            // *this window is not castable* about a window that had become
            // castable since. See `WatchLink.read`.
            host?.watch.read()
        }
        .onDisappear {
            model.localhostPageIsOpen = false
            // The keyboard goes with the screen. A canvas left as first
            // responder behind a dismissed view is a keyboard nobody can put
            // away, and the canvas is torn down a moment later anyway.
            if typing, let surface = liveSurface { WatchStage.post(.endTyping, to: surface.window) }
            // And so does inspect mode. `MachinePick` is one static for one
            // canvas, so a screen that walked off still armed would take the
            // first tap on whatever mounts next and turn it into a question
            // about a window nobody is looking at.
            stopInspecting()
        }
        .onChange(of: window?.url) { _, _ in seed() }
        // And the same for a page with no window row: its address moves on the
        // surface list rather than on the window list, and the field has to
        // follow whichever of the two this page is on.
        .onChange(of: liveSurface?.url) { _, _ in seed() }
        /*
         * Leave when the window does.
         *
         * Not optimistic: nothing is dismissed when Close is *pressed*, only
         * when the list comes back without this window in it. The machine is
         * entitled to refuse — a window a session has taken over, one that had
         * already gone — and a screen that popped on the press would leave
         * somebody looking at a list that still has the window in it, wondering
         * which of the two is right.
         *
         * One watcher for both shapes and for the settings screen too: Close
         * lives over there, and this is what pops the pair of them.
         */
        .onChange(of: closed) { _, gone in
            guard gone else { return }
            // The mode goes before the screen does. `dismiss()` is asynchronous
            // enough that a tap landing in between would ask about a window the
            // machine has already told us is gone.
            stopInspecting()
            dismiss()
        }
        .navigationDestination(isPresented: $showingSettings) {
            MachineWindowSettingsView(model: model, windowID: windowID, pushed: true)
        }
        /*
         * The element that was pointed at, in the sheet both browsers share.
         *
         * Presented off a **flag** rather than off the value, for the reason
         * `LocalhostBrowser` gives at its own copy of this line: `.sheet(item:)`
         * tears the sheet down and builds a new one whenever the identity
         * changes, and Wider/Narrower change the element on every press — which
         * would make the correction control dismiss and re-present the sheet it
         * lives in.
         *
         * `picked` is nil for an answer about a *different* window, so a phone
         * with two browser screens on its stack cannot draw the wrong one's
         * element.
         */
        .sheet(isPresented: Binding(get: { picked != nil },
                                    set: { if !$0 { model.clearMachinePick() } })) {
            if let element = picked {
                InspectSheet(
                    element: element,
                    targets: model.agentTargets,
                    target: Binding(get: { model.agentTarget }, set: { model.agentTarget = $0 }),
                    step: stepInspection,
                    send: { line, session in
                        let sentence = model.sendToAgent(line, into: session)
                        say(sentence)
                        return sentence
                    },
                    // A correction on this kind of window is a frame over a wire
                    // and back, and nothing on the sheet moves until it lands.
                    // The page on this phone answers in the same runloop turn and
                    // passes false, which is why this is a parameter rather than
                    // something the sheet works out.
                    pending: asking,
                    dismiss: { model.clearMachinePick() })
            }
        }
    }

    /**
     * The element the machine described, when it is about **this** window.
     *
     * `HostLink` holds one answer and this phone's stack can hold more than one
     * browser screen — a window, its settings, another window reached from a
     * session. Matching on the id is what stops the screen on top drawing an
     * element that belongs to the one underneath it.
     */
    private var picked: InspectedElement? {
        guard let held = model.machinePicked, held.window == windowID else { return nil }
        return held.element
    }

    /// Whether an ask about this window is in flight. Read in two places — the
    /// hint row and the sheet — so it is written once.
    private var asking: Bool { model.pickingInMachineWindow == windowID }

    /**
     * What inspect mode is waiting for, said once, at the top of the page.
     *
     * The same row, the same glyph and the same place as `LocalhostBrowser`'s.
     * *"Should not be that much of difference in all of them."*
     *
     * ## And what it says while an answer is on its way
     *
     * The one difference between the two browsers that is not cosmetic: on the
     * page this phone holds, a tap is answered in the same runloop turn — there
     * is no moment to describe. Here it is a frame over a wire to a machine and
     * back, and on a phone connection that is a second or two with the sheet not
     * yet up and the picture unchanged. A row that went on saying *tap anything*
     * through that would be the screen inviting a second tap while the first was
     * still in flight, which is two asks and one answer somebody has to reconcile.
     *
     * So the row says which of the two states it is in. Every way the ask can
     * fail comes back as a sentence in the banner above this line, and `pickingIn`
     * is cleared by that same frame — so this never outlives the answer, whichever
     * answer it was.
     */
    private var inspectHint: some View {
        HStack(spacing: 6) {
            Image(systemName: asking ? "hourglass" : "hand.tap")
                .font(.system(size: 10))
            Text(asking
                 ? "Asking the machine what that is\u{2026}"
                 : "Tap anything on the page to ask what it is.")
                .font(.system(size: 11))
            Spacer(minLength: 0)
        }
        .foregroundStyle(Theme.accent)
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface)
        .accessibilityIdentifier("browser.machine.window.inspectHint")
    }

    // MARK: - What is on the screen

    /**
     * What this window is called, by the one rule every browser window in this
     * app is named by.
     *
     * It reproduces exactly what two expressions used to say between them —
     * `MachineWindow.label` for a window row, `MachineBrowserText.surfaceLabel`
     * for a cast with no row — and says it once. The fallback is where those two
     * differed: a surface with neither a title nor an address is the machine's
     * own front tab (`""`) or a named slot, and a window whose row has simply not
     * landed yet is not yet anything, so it is the noun.
     */
    private var pageTitle: String {
        BrowserChrome.pageTitle(title: window?.title ?? liveSurface?.title ?? "",
                                address: window?.url ?? liveSurface?.url ?? "",
                                fallback: fallbackName)
    }

    private var fallbackName: String {
        // Never a raw window id. It is a shell tab id — `browser:1756…:3` — and
        // putting one where a person reads a name is the jargon this round
        // exists to delete. `Untitled` is what a browser calls a window it has
        // nothing better to say about; the machine's own tab keeps its own name
        // because *which* tab it is, is the useful fact about it.
        guard window != nil || liveSurface != nil else { return WindowNames.blank }
        return windowID.isEmpty ? "Front tab" : WindowNames.blank
    }

    @ViewBuilder
    private var stage: some View {
        /*
         * **The picture first, and that order is the requirement.**
         *
         * It used to ask `canDriveBrowser` before anything else, which was right
         * while this screen was only ever pushed for a window the phone could
         * drive. It is pushed for the machine's own front tab now, and for a
         * surface on a machine that casts without offering control — and on both
         * of those the first question would have answered *this machine is not
         * offering its browser* over a live picture of that machine's browser.
         *
         * A page that is being cast is a page, whatever else is or is not on
         * offer. What cannot be sent to it is the bar's business, one control at
         * a time, with a reason.
         */
        if let watch = host?.watch, let surface = liveSurface {
            /*
             * **The page, and nothing under it.**
             *
             * This space used to carry the session that owns the window, its
             * live status, and the one tap that opened it — *"Let's give
             * terminal here in black area available down here, to watch what the
             * session is doing."* That tap was a route out of the Browser tab
             * and into the terminal, and it is what he walked into:
             *
             * > *"if we go to browser and if we go back, it is giving like this
             * > now. See, inside, it is taking me to directly terminal. So this
             * > page should be purely for only browser, not for terminal too.
             * > Terminal is only here, and only terminal is giving the browser
             * > window too. But browser side, it should not give the terminal
             * > window too… If I click here, there is again another button to
             * > take me to the same browser back. Then I go back again into the
             * > terminal page, which is too complicated. It should be just when I
             * > come to this browser page, here I should be able to see all the
             * > browsing windows. That's all, very simple."*
             *
             * So the rule is **one-way**, and it is a rule about the tab rather
             * than about this control: a session opens a browser window
             * (`SessionPageView`, which is untouched and is the half he wants),
             * a browser window never opens a session. Nothing on the Browser tab
             * calls `DeckModel.open(session:)` any more.
             *
             * Which session owns this window, and attaching it to another one,
             * are not lost with the row — they are window settings and they are
             * behind the `…` in the header, where the whole binding card already
             * lives: *"settings of per window, how to connect to it, how to make
             * it shared or isolated, all of these things should be inside of the
             * window."* What went is the route, not the fact.
             *
             * The picture is still sized to what the canvas says it is drawing
             * (`WatchSurface.onPageHeight`) rather than stretched over the whole
             * stage, because the canvas's own ground is black and a 1280×800
             * page fitted to a 393-point phone is about 246 points tall. The page
             * ends where it ends and the app's own paper carries down to the bar.
             * Before the first frame the stage takes everything, which is what
             * makes the fit land on the width rather than on a guess; it settles
             * on the next pass.
             */
            GeometryReader { geometry in
                VStack(spacing: 0) {
                    WatchStage(watch: watch,
                               window: surface.window,
                               mounted: model.tab == .localhost,
                               onPageHeight: { pageHeight = $0 })
                        .frame(height: pageHeight > 0
                               ? min(pageHeight, geometry.size.height)
                               : geometry.size.height)
                        .accessibilityIdentifier("browser.machine.window.stage")
                    Spacer(minLength: 0)
                }
                .frame(width: geometry.size.width, height: geometry.size.height)
            }
        } else if host?.canDriveBrowser != true {
            /*
             * Reachable, and not a dead end drawn on purpose. The Browser tab
             * pushes this screen for a machine that advertised `browser.control`
             * or one that is casting a page; what does happen is a machine
             * dropping off — or coming back as a guest — while the screen is
             * already up, and the cast going with it.
             */
            note("This machine is not offering its browser.",
                 id: "browser.machine.window.unavailable")
                .padding(.horizontal, 16)
                .padding(.top, 20)
            Spacer(minLength: 0)
        } else if window != nil {
            MachineWindowSettingsView(model: model, windowID: windowID, pushed: false)
        } else {
            ProgressView()
                .controlSize(.regular)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityIdentifier("browser.machine.window.loading")
        }
    }

    /**
     * The bar a browser has: where the page is, and the things you do to it.
     *
     * Under the page rather than over it, because that is where every browser on
     * this phone puts it and because the top of a cast page is the page's own
     * chrome. It is drawn in both shapes of this screen — the address and the
     * page verbs are about the window, and the window exists whether or not the
     * machine will cast it.
     *
     * `BrowserPageBar` is the bar itself. It was written out of this file when
     * the screen a page with no window id used to land on turned out to be the
     * one he was looking at when he said a window *"feels like just like a
     * video"*: it had no address on it at all. Two screens showing a live page
     * and two different amounts of browser on them is how one of them ends up
     * being the video — and the answer to that, a round later, was to stop having
     * two screens.
     *
     * ## The same five controls on every page, and the reason where one is dead
     *
     * > *"it should be the same case, or all the options should be available at
     * > least."*
     *
     * > *"So top, header and footer, tab bar should be same in all type of
     * > browsing windows, including on this phone, including isolated, including
     * > the server."*
     *
     * The row is Back · Forward · Reload · Find · Inspect · Width, and it is that
     * under a window on the machine, an isolated window on the machine, the
     * machine's own front tab, and a page this phone is holding open over a
     * tunnel. Find and Inspect joined it here from the phone's side, where they
     * work; on this screen Find is drawn greyed with the reason, because a
     * picture of a page has no words on this phone to search.
     *
     * The sixth used to be the `…`. It is the header's now — see the `.toolbar`
     * on `body` and `BrowserChrome` — because *"not only the bottom"* was a
     * sentence about the header being empty, and because the `…` is the one
     * thing in this chrome that acts on the **window** rather than on the page.
     *
     * Which of them can act is decided **per verb from what the wire will
     * carry**, never by leaving a gap:
     *
     *  - **A window this phone can drive** — the address, Back, Forward and
     *    Reload are all `browser.window.*` and all live.
     *  - **The machine's own front tab** — the address and Reload are `web.open`,
     *    which lands in that same slot. Back and Forward are drawn dead: the
     *    codec refuses an empty window id on `browser.window.act`, so there is no
     *    frame this app could send. `whyLimited` is the sentence on the ⓘ.
     *  - **Anything else being cast** — a machine that casts without offering
     *    control, a page no window row claims. Nothing can be sent, the address is
     *    read-only at the machine's last word on it, and all three verbs are dead
     *    with the reason.
     *
     * The bar is absent entirely only where there is neither a window to drive
     * nor a picture to be under: a bar with nothing above it is not a browser's
     * bar.
     */
    @ViewBuilder
    private var bar: some View {
        if drivable || liveSurface != nil {
            BrowserPageBar(
                id: "browser.machine.window",
                address: $address,
                editing: $editing,
                typing: $typing,
                placeholder: "Address or search",
                go: (drivable || openable) ? go : nil,
                back: drivable ? { host?.actOnMachineWindow(windowID, .back) } : nil,
                forward: drivable ? { host?.actOnMachineWindow(windowID, .forward) } : nil,
                reload: reloadVerb,
                page: liveSurface?.window,
                /*
                 * **No history state, and that is deliberately not a `false`.**
                 *
                 * `MachineWindow` carries no `canGoBack`. The desktop's own
                 * back-forward list never comes over this wire, so nil is the only
                 * honest answer and the bar reads it as *do not grey these*. The
                 * page on this phone owns a `WKWebView` and passes the real thing.
                 */
                canGoBack: nil,
                canGoForward: nil,
                loading: window?.loading == true,
                /*
                 * There is no stop verb. `MachineWindow.Act` is back, forward,
                 * reload, close, record on, record off, share and isolate — a
                 * Stop drawn here would be a glyph with no frame to send. The load
                 * line under the header carries the state instead and Reload stays
                 * live, which is the useful half of Stop anyway.
                 */
                stop: nil,
                /*
                 * **Find is still the seam; Inspect has come through it.**
                 *
                 * Find is `nil` and stays `nil`: it reads the words out of a
                 * document *this phone has loaded*, and there is no verb in the
                 * `browser.window.*` family that would ask the machine to look for
                 * us. `BrowserChrome.findIsLocal` is still the sentence.
                 *
                 * Inspect was `nil` for the same-shaped reason and is not any
                 * more. The host answers `browser.window.pick` with the element at
                 * a point — the same facts its own capture popup shows — so this
                 * screen passes the closure the seam was built for and the greyed
                 * glyph becomes a live one. Nothing else about this bar changed,
                 * which is what the seam was for.
                 *
                 * Two conditions, and both are needed. `drivable` is the wire: the
                 * machine has to be offering `browser.control` and this page has
                 * to have a window id that family can carry, because the codec
                 * refuses an empty one. `liveSurface` is the screen: pointing at a
                 * thing needs a picture of the thing to point at, and a window the
                 * machine will not cast draws its settings as its body. Where the
                 * second is missing the sentence is Inspect's own; where the first
                 * is, the bar-wide `unavailable` already says it and a second
                 * paraphrase underneath would be the bar apologising twice.
                 */
                find: nil,
                inspect: (drivable && liveSurface != nil) ? toggleInspecting : nil,
                inspecting: inspecting)
        }
    }

    /**
     * Reload, by whichever of the two doors this page answers to.
     *
     * `browser.window.act` for a window, and for the front tab the same
     * `web.open` its address bar is — sending the address the machine last
     * reported for it, which re-navigates that slot. Nil where the surface has no
     * address yet, because *reload nothing* is not a verb; the bar draws it dead
     * with the rest.
     */
    private var reloadVerb: (() -> Void)? {
        if drivable { return { host?.actOnMachineWindow(windowID, .reload) } }
        guard openable, let url = liveSurface?.url, !url.isEmpty else { return nil }
        return { send(url) }
    }

    /**
     * Why the dead controls on the bar are dead, or nil where none of them are.
     *
     * One sentence for the whole bar rather than one per glyph: the answer is a
     * fact about the page, and three copies of it would be three places for it to
     * drift. Both cases name the machine, because somebody with two paired needs
     * to know which one is refusing.
     *
     * ## One clause was taken out of the first sentence because it was not true
     *
     * It used to end *"…and the window's own settings cannot be addressed to
     * it"*, on the machine's own front tab. The `…` in the header of that exact
     * screen **opens those settings**, and has all along: the front tab is always
     * being cast, so `liveSurface` is never nil for it, so the control is drawn
     * and it works. What the person then reads over there is a screen of controls
     * drawn dead with their own reason, which is the honest answer and is what
     * *"all the options should be available at least"* asks for.
     *
     * A sentence that contradicts the button next to it is worse than no
     * sentence: it teaches somebody not to trust the next one. So the clause is
     * gone, and what is left is only what genuinely cannot be put on this wire —
     * the two history verbs, and pointing at one thing on the page.
     */
    private var whyLimited: String? {
        guard !drivable else { return nil }
        let name = model.current?.label ?? model.theMachine
        if windowID.isEmpty {
            return "This is \(name)'s own tab rather than one of its windows. The machine names a "
                + "window with an id and this page has none, so Back, Forward and pointing at one "
                + "thing on the page cannot be addressed to it."
                + "\n\nTyping an address still moves this page: that is a different verb, and it "
                + "lands in this same tab."
        }
        return "\(name) is casting this page and is not offering its browser to this phone, so "
            + "nothing on this bar can be sent to it. The address is what the machine last "
            + "reported for the page."
    }

    // MARK: - Actions

    /**
     * Send the typed line to this page, having first worked out what it is.
     *
     * The classification is `LocalhostAddress.classify`, the same pure function
     * the new-window sheet calls, so `google.com`, `https://…`, `3000` and `what
     * is my ip` mean the same thing in every field in this app. This field used
     * to hand the machine the raw text and hope: a URL worked, a bare hostname
     * sometimes worked, and a sentence typed into it went nowhere with nothing on
     * screen to say why.
     *
     * One classification for both doors, deliberately. Which verb carries the
     * result is `send`'s question and it is asked after this one, so the front tab
     * and a window can never come to different conclusions about what was typed.
     *
     * A port means a page on the machine's own loopback, which is what a field
     * attached to a window on that machine can only mean.
     */
    private func go(_ typed: String) {
        switch LocalhostAddress.classify(typed) {
        case let .tunnel(port, path):
            send("http://localhost:\(String(port))\(path)")
        case let .page(url):
            send(url)
        case let .search(_, url):
            send(url)
        case let .refused(why):
            refused = why
        }
    }

    /**
     * Out of the two doors, whichever one reaches this page.
     *
     * A window is `browser.window.go`, addressed by its id. The machine's own
     * front tab has no id and is `web.open`, which on a headless host is
     * `browserDrive.open` into the drive's own slot — this page, not a second
     * one. The branch is `drivable` rather than *is the id empty*, because a
     * machine that has stopped offering `browser.control` between the push and
     * the press has an id and no door to send it through; `openable` refuses that
     * case as well, and then the field is not drawn at all.
     *
     * Reached only from the field, and the field is drawn only where one of the
     * two doors is open — so there is no third case here where a press goes
     * nowhere.
     */
    private func send(_ url: String) {
        refused = nil
        if drivable {
            host?.goMachineWindow(windowID, to: url)
        } else {
            model.openPageOnMachine(url)
        }
    }

    // MARK: - Pointing at one thing

    /**
     * Turn the mode on, or off.
     *
     * On: the canvas is told, through `MachinePick`, that a tap on this window's
     * picture is a **question** rather than a click — so nothing is pressed on
     * the far page, exactly as `InspectScript` cancels the click on the page this
     * phone holds. The point it hands back is already in document coordinates.
     *
     * Off: the mode ends and so does whatever was being looked at. Leaving the
     * sheet's element behind would be a description of something nobody is asking
     * about any more, and Wider on it would walk up a chain measured against a
     * page that has since scrolled.
     */
    private func toggleInspecting() {
        if inspecting { return stopInspecting() }
        inspecting = true
        // The window is captured by value and the model by reference; nothing of
        // this `View` struct is. A closure held in a static that reached back into
        // a redrawn screen would be the stale-capture bug `WatchSurface` warns
        // about at `updateUIView`.
        MachinePick.arm(window: windowID) { [model, windowID] x, y in
            model.pickInMachineWindow(windowID, x: x, y: y, up: 0)
        }
    }

    /// End the mode, wherever it is ended from — the control, leaving the screen,
    /// or the window closing under us. Written once because three callers each
    /// doing two things is how one of them ends up doing one.
    private func stopInspecting() {
        guard inspecting || MachinePick.isArmed(window: windowID) else { return }
        inspecting = false
        MachinePick.disarm()
        model.clearMachinePick()
    }

    /**
     * Wider and Narrower, on a window whose ancestors live on the far machine.
     *
     * The same point, asked again with a different `up` — which is why the host
     * takes `up` as a field on the pick rather than as a verb of its own, and why
     * `MachinePick` keeps the point rather than the screen deriving one from the
     * answer. There is nothing in a `browser.window.picked` to re-derive a
     * fingertip's position from.
     *
     * Clamped twice on the way out, and the second clamp is not belt and braces.
     * `MachinePick.step` holds the range and the codec holds it again on the last
     * line before the wire, because the host checks `up` in its **parser** and
     * `server.ts` answers a parse failure by closing the socket. Pressing Wider
     * once too often must cost a greyed button, not somebody's terminals.
     */
    private func stepInspection(_ delta: Int) {
        guard let element = picked, let point = MachinePick.lastPoint else { return }
        let next = MachinePick.step(from: element.depth, by: delta)
        // Nothing to ask about: the answer would be the element already on
        // screen, and a frame that changes nothing is a frame that makes the
        // sheet flash *Asking the machine…* for no reason.
        guard next != element.depth else { return }
        model.pickInMachineWindow(windowID, x: point.x, y: point.y, up: next)
    }

    /// Say something for a moment. The sentence a hand-off to an agent comes back
    /// with is about a line that has left this phone, and the machine's own
    /// notices are about the window list — so it gets its own line rather than
    /// overwriting one of those.
    private func say(_ sentence: String) {
        guard !sentence.isEmpty else { return }
        withAnimation { said = sentence }
        Task {
            try? await Task.sleep(for: .seconds(3))
            withAnimation { said = nil }
        }
    }

    /**
     * Fill the field from the page, unless somebody is using it.
     *
     * The guard is the whole function. Without it, a page that redirects — or a
     * single-page app that rewrites its own URL, which is most of what anybody
     * points this at — rewrites the field mid-word, and the address that gets
     * sent is half of what was typed with half of where the page went.
     *
     * The window's URL where there is a window row, the surface's where there is
     * not: the front tab's address lives on `browser.surfaces.rows` and nowhere
     * else, and a field seeded only from the window list would be empty on every
     * page that arrived through `web.open`.
     */
    private func seed() {
        guard !editing else { return }
        guard let url = window?.url ?? liveSurface?.url, !url.isEmpty else { return }
        guard !seeded || url != address else { return }
        address = url
        seeded = true
    }

    /**
     * A line of prose inside a card of its own, at the insets a row would have.
     *
     * The identifier goes on the **text**, never on the card around it. An
     * `accessibilityIdentifier` on a container makes that container an
     * accessibility element and everything inside it stops existing — measured
     * on iOS 26.4 and written down in `TabNavigation.swift`.
     */
    private func note(_ text: String, id: String) -> some View {
        SchemeGroup {
            Text(text)
                .font(.system(size: 14))
                .foregroundStyle(Theme.faint)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 16)
                .padding(.vertical, 15)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier(id)
        }
    }
}
