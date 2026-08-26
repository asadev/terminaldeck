/**
 * A page from the Mac, on the phone.
 *
 * A `WKWebView` pointed at `http://127.0.0.1:<port>/`, where `PortTunnel` is
 * listening. Not a custom URL scheme and not a string of HTML handed to
 * `loadHTMLString`, and the difference is the feature: on a real loopback origin
 * the page gets same-origin `fetch`, real cookies, service workers and —
 * critically — **WebSockets**, which is what a dev server's hot reload runs on.
 * A scheme handler gets none of that, and a site served through one is a
 * screenshot that stops updating the moment you save a file.
 *
 * ## What this screen owes the user
 *
 * That the page on screen is live, or that it plainly is not. A tunnel can end
 * for three reasons — this phone closed it, the Mac closed it, the connection
 * dropped — and all three leave a rendered page sitting there looking fine. So
 * the header carries the state, and when a tunnel ends the page is replaced
 * rather than left up with a warning over it.
 *
 * ## Inspect mode
 *
 * The other half of why this screen is worth having. Tapping an element while
 * inspecting describes it — a real CSS selector, its tag, whatever a human would
 * read off it — and a sheet takes one sentence about what should change and types
 * both into an agent on the Mac, as **one line**. See `Inspect` for why the line
 * is flattened rather than wrapped, and `InspectScript` for what runs inside the
 * page. It is the desktop's `CapturePanel` feature, from the sofa.
 *
 * ## It is pushed, and the chrome is the platform's
 *
 * This was a `fullScreenCover` and it rose from the bottom edge. Asad: *"it
 * should not come like this up. It should just move like this when we click on
 * localhost page. It comes like this, which is a bit different, feels like a
 * browser opens inside. So give it a native feel, not like this."* It is a
 * `navigationDestination` now — see `MachineBrowserView` — so it slides in from
 * the trailing edge.
 *
 * That was not enough, and he said so again: *"localhost browsing is still not
 * native on iOS."* Two things were left and they were one mistake made twice —
 * this screen had taken over both of the places iOS owns:
 *
 *  - **The left edge belonged to the page.**
 *    `allowsBackForwardNavigationGestures = true` handed the standard back
 *    gesture to the web view's own history, so the single gesture everybody
 *    reaches for to leave a pushed screen quietly did something else. It is off
 *    now — see `BrowserBridge.init` — and page history is a button instead.
 *  - **The navigation bar was hidden**, for a custom row carrying back, reload,
 *    where you are, inspect and Done. The argument for hiding it was real: a
 *    system bar above that row is 94 points of chrome in two rows, with two back
 *    buttons eleven points apart meaning different things. The price was the
 *    whole platform, though — no system chevron, no standard title, and no
 *    interactive pop.
 *
 * **The resolution is Safari's, and it dissolves the conflict rather than
 * picking a side.** The navigation bar stays, so the chevron, the title and the
 * pop gesture are the system's; the browser's own controls live along the
 * **bottom**, which is where iOS has kept browser controls since the first
 * iPhone. The two back buttons are no longer eleven points apart arguing over
 * one meaning — they are at opposite ends of the screen and each is exactly
 * where iOS says its meaning lives: leaving this screen is the chevron top left,
 * going back a page is the chevron bottom left.
 *
 * The **tab bar** is the one bar still turned off in here. *"Pill should be on
 * here… not inside the session and not also inside the localhost page."* A page
 * is the whole reason you are here and it wants the height; the pill sat over
 * the bottom of it pointing somewhere else — and it would now be sitting on the
 * bar this screen needs. It is not turned off in this file: iOS 26 draws it
 * as a floating pill owned by the `TabView` and ignores a `.toolbar` written on
 * a pushed screen, so `DeckTabs` states it and this screen only reports that it
 * is up — `DeckModel.localhostPageIsOpen`. `DeckChrome` holds the rule.
 *
 * ## The bar is `BrowserPageBar` now, and the header traded a line for a control
 *
 * The bottom row used to be a system `UIToolbar` written here, carrying Back,
 * Forward, Reload, Find, Inspect and Done. It was a good toolbar and it was the
 * third different bar in this app under a live page. He counted them:
 *
 * > *"So top, header and footer, tab bar should be same in all type of browsing
 * > windows, including on this phone, including isolated, including the server."*
 *
 * > *"if it is in this phone, I cannot edit the link and make a change and search
 * > it again."*
 *
 * The second sentence is the one this screen could not answer at all. Its
 * address was chosen once, in the sheet that opened it, and after that there was
 * nowhere to type: `/admin` was reachable only by going back out to the list. A
 * window on the machine had had an editable address for two rounds.
 *
 * So this screen mounts the same `BrowserPageBar` those windows mount, with the
 * same two rows — the address and Go, then Back · Forward · Reload · Find ·
 * Inspect · Size — and the toolbar written here is gone. What moved:
 *
 *  - **The address arrived**, as a real field. It is spelled the way the person
 *    who opened it thinks of it — `localhost:3000/admin`, not the random
 *    loopback port this phone bound — and both spellings are accepted back. See
 *    `BrowserChrome.shownAddress`.
 *  - **Done left the bar.** It tore the tunnel down, which is a thing you do to
 *    the window rather than to the page, so it is `Close this window` behind the
 *    `…`. He blessed Done's position — *"last button I think is on its correct
 *    place"* — in a round where the row ended with it; the row is the same
 *    controls under all four kinds of window now, and the one-tap way out was
 *    never that button anyway. The chevron top left leaves this screen and
 *    closes the tunnel exactly as Done did.
 *  - **The header lost its second line and gained the `…`.** The line was the
 *    page title over a mono `http://127.0.0.1:52311/admin  ·  3 connections`.
 *    *"even if we remove the top header of paperclip and all of this basic
 *    information might not be required from the outside. We can just see and
 *    enter."* The address is in the field now, which is better than a label of
 *    it. What took that space is a control rather than a line, which is the
 *    other half of what he asked for:
 *
 *    > *"Maybe we can give some better one header also, not only the bottom, so
 *    > we can have most of the important controls for the flow, for this kind of
 *    > things and whatever we require to get the job done."*
 *
 * ## And then the two of them swapped ends
 *
 * > *"this link should be on the top header instead of bottom just like the
 * > normal browsers. I think on top you should have back button and link only,
 * > and then in the bottom you should have the rest of the options and three dot
 * > in the right side which will open the rest of the options, not upside here.
 * > Three dot should be here where we have right now size, so it can bring the
 * > options from up to down down to up."*
 *
 * This screen — and only this screen — now reads:
 *
 *  - **header**: the system chevron and the address, and nothing else. The field
 *    is `BrowserAddressField` with `place: .header`, mounted as the principal
 *    item, so it is the same control with the same name as the one the bar draws
 *    everywhere else.
 *  - **bar**: Back · Forward · Reload · Find · Inspect · Size · `…`. The `…` is
 *    `BrowserPageBar`'s `more` slot, the same `BrowserWindowActions` that draws it
 *    in a header, told it is standing in a row.
 *
 * The round before this one moved the `…` **up** on *"not only the bottom"*, and
 * this is not that round being undone. That sentence is about a header carrying
 * no control at all; this header carries the address, which is a control and the
 * one he named — and *"on top you should have back button and link only"* then
 * says what else may be up there. Nothing. `BrowserChrome` holds the argument in
 * full, because the same reversal will look like a flip-flop to whoever reads
 * this next.
 *
 * The other three kinds of browser window are **untouched**. He was holding this
 * page when he said it, and said of the terminal in the same breath: *"same way
 * here it is fine because it is terminal, it should be the way I said."* So the
 * arrangement is a named option with a default (`BrowserAddressPlace`,
 * `BrowserMorePlace`) rather than a fork of the shared chrome — the day the same
 * is asked of a machine window, that screen passes `.header` and nothing else in
 * the app has to be found.
 *
 * ## And the `…` opens the page's own settings, exactly as a window's does
 *
 * > *"all of them should be identical, and all of them should have all the
 * > options. Should not be that much of difference in all of them."*
 *
 * For one round it opened a menu with a single item in it, Close — because a page
 * over a tunnel had no settings screen anywhere. It has one now:
 * `MachineWindowSettingsView` takes a `phoneTab:` and draws this page's own
 * cards — what it is, which session to hand it to, a screenshot with a note, the
 * move that opens the same address in the machine's browser, and Close. It was
 * reachable only from the `…` on the **row out on the Browser list**, which is
 * the outside of the window; his sentence is about the inside.
 *
 * So the `…` here pushes that screen and the one-item menu is gone. Close is not
 * lost — it is a card on that screen, and the chevron top left still does the
 * same thing in one tap.
 *
 * The one page that keeps a menu is the prototype `ArtifactView` opens: it is
 * pushed straight at a tunnel with no row on the Browser list, so there is no
 * `BrowserTab` id to carry into those settings and nothing for that screen to
 * draw. See `pageMenu`.
 *
 * ## Two things this screen can do that a picture of a page cannot
 *
 * Both were asked for twice, and both are here rather than on the machine's side
 * for the same reason: **this phone owns the document**.
 *
 * **Size — pinch, and other widths.**
 *
 * > *"they can use the the mode currently we have this machine they can just
 * > browse as phone view and it should have all the by the way views also they
 * > can pinch and zoom also they can see all the different dimensions in
 * > responsive views how it will look like in mobile how it will look like on
 * > Windows so they can have different dimensions also in phone just like
 * > MacBook."*
 *
 * Pinch is `ignoresViewportScaleLimits` on the configuration — every dev server's
 * default template ships `user-scalable=no`, and a browser is exactly the place
 * that override belongs. The sizes are the honest kind: `WebSurface` lays the
 * `WKWebView` out at the device's real **width and height** in points and scales
 * the view to fit, so the page's own media queries fire at that width and its
 * `100vh` is that height, and `PageViewportScript` writes a viewport for the
 * pages that would otherwise be laid out at their own fixed width or at WebKit's
 * 980 default. The choice is remembered per site (`PageWidths`). A window on the
 * machine draws that control greyed with one sentence: it sends pictures, and
 * there is no layout here to change.
 *
 * > *"when i make other frame like desktop or laptop biew it is trying to fit
 * > inside the same given space a sphone instead of giving me less hieght and
 * > like actual laptop dimension"*
 *
 * That is what `DeviceFrame` at the bottom of this file is: the chosen rectangle
 * drawn with its own proportions, edged, on ground, with the pixels said quietly
 * under it — a laptop wide and short, a phone tall and narrow. The round before
 * this one kept the phone's height and only changed the width, which drew a
 * laptop as a tall strip and answered nothing.
 *
 * **The click-flow recorder.**
 *
 * > *"you are giving record flow button in the windows side the server side it
 * > and you are not giving that into the if they are browsing locally in this
 * > machine. So there are so many differences if they both are capable for a
 * > feature why don't they both have."*
 *
 * The round before this left it out on the argument that a flow recorded here is
 * about a page the machine never loaded. That was true of a screenshot and false
 * of a flow — a flow is a list of sentences about the **site's** DOM, and the
 * site is the machine's. `PhoneClickFlow` holds it, `PhoneRecordScript` watches
 * the page, and the rows come out as the same `RecordedStep` the machine's
 * recorder fills, so one list draws both. The card that starts it is on this
 * page's own settings screen, beside the one a machine window has.
 *
 * ## Forward exists because the gesture that used to do it does not
 *
 * `allowsBackForwardNavigationGestures` is one property and it buys two
 * gestures: back on the left edge and **forward on the right**. Turning it off
 * to give the left edge back to the system therefore also took away the only
 * way this screen had of going forward, and a Back button that strands you is
 * worse than no Back button — you tap it once by accident and the page you were
 * reading is unreachable. So Forward is a button beside Back, disabled until
 * there is somewhere to go, which is the pair Safari puts in the same corner.
 * `BrowserBackTests` walks a real history through both of them.
 *
 * That *disabled until there is somewhere to go* is the one thing on this bar a
 * window on the machine cannot copy, and the bar keeps the two apart rather than
 * unifying them: this screen owns a `WKWebView` and knows the answer, a machine
 * window has no history state on the wire at all and passes nil, which the bar
 * reads as *do not grey these*. See `BrowserPageBar.canGoBack`.
 */

import SwiftUI
import WebKit

struct LocalhostBrowser: View {
    let model: DeckModel
    let tunnel: PortTunnel
    /**
     * What to ask that origin for, first.
     *
     * `"/"` for every row on the list, which is what a tap on a port has always
     * meant. Anything else comes from the address bar at the top of that screen
     * — see `LocalhostAddress` — and it is the reason that bar exists at all:
     * the thing somebody is working on is very often at `/admin` rather than at
     * the root, and until there was somewhere to type a path there was no way to
     * reach it from this app at all. The bar was a `+` and a sheet when this was
     * written; it is a field on the screen now, which changes where the string
     * comes from and nothing about what is done with it here.
     *
     * Resolved against the tunnel's own URL rather than concatenated, so the
     * loopback literal the tunnel actually managed to bind is kept — it is
     * `127.0.0.1` on most phones and `[::1]` where the v4 bind lost a race, and
     * a hand-built string would guess the wrong one about one time in a hundred.
     */
    var path: String = "/"
    /// The phone's own browsing history. Injected rather than reached for, the
    /// same way `PortSuggestions` takes its `PortBook`.
    var history: BrowserHistory = .shared
    /**
     * The click flows this phone is holding, one per tab.
     *
     * > *"you are giving record flow button in the windows side the server side
     * > it and you are not giving that into the if they are browsing locally in
     * > this machine. So there are so many differences if they both are capable
     * > for a feature why don't they both have."*
     *
     * The card that starts and stops it is on this page's own settings screen —
     * the same card a machine window has — and it reaches the same store from
     * there. This screen's job is the half only it can do: the web view is here,
     * so the listening happens here. See `PhoneClickFlow` for why the reason this
     * was left out last round was the wrong reason.
     */
    var flow: PhoneClickFlow = .shared
    /// Which size each site was last looked at in. Injected on the same terms.
    var widths: PageWidths = .shared
    /**
     * The tab this page is in, if it is in one.
     *
     * Nil is a real case and stays supported — `DevServerReport` pushes this
     * screen straight at a tunnel without going through the strip — so every use
     * below is guarded rather than forced. When it is set, the two `onChange`
     * hooks that already feed the history feed the strip as well, which is what
     * makes a pill read *"admin"* instead of *"localhost:3000"* forever.
     */
    var tabID: String?
    /**
     * **One line to say when this page arrives, or nil.**
     *
     * > *"when it is automatically opening in this phone, I am not sure now if
     * > this opens in this phone or it is open in the other device in the server
     * > side. There is no clarity."*
     *
     * A window opened from the Browser tab's `+` on the **machine** leaves a
     * banner on the list, because that is the screen the sheet dismisses back
     * onto. This destination has no such moment: the page is pushed in the same
     * turn as the press, so a sentence left on the list behind it is one nobody
     * will ever look at. The screen that has to say it is this one, and it says
     * it in the toast it already draws for the acts that are silent by nature —
     * a copy, a picture sent to an agent.
     *
     * A **value handed in**, rather than this screen working it out. Every page
     * here is on this phone, so a line derived locally would fire on every
     * arrival including a tab somebody is simply going back to — and telling
     * somebody what they just pressed is noise, not clarity.
     * `MachineBrowserView.landing` is the one place that decides, and it decides
     * by which door was used: `openHere` sets it, `resume` clears it.
     *
     * Nil for the one caller that pushes this screen straight at a tunnel with no
     * tab behind it — `ArtifactView` — which is the same caller `tabID` is nil
     * for, and for the same reason: it is a preview, not a window somebody opened.
     */
    var announce: String?
    let dismiss: () -> Void

    @State private var browser = BrowserBridge()
    @State private var toast: String?

    /// The find session, while the bar is up. Nil is closed — there is no
    /// separate `isFinding` flag, because two properties that must agree about
    /// one thing are two properties that eventually will not.
    @State private var find: BrowserFindSession?

    /**
     * What is in the address field.
     *
     * **Seeded, never bound** — the same rule `MachineWindowView` follows and for
     * the same reason, which on this screen is if anything sharper: everything
     * this feature exists to look at is a dev server, every dev server serves a
     * single-page app, and every route change in one rewrites the URL. A two-way
     * binding would retype the field under a thumb mid-word and send half of what
     * was typed joined to half of where the page went.
     */
    @State private var address = ""
    /// Whether somebody is in the field, so a navigation does not re-seed it
    /// under them. Owned by `BrowserPageBar` and mirrored here.
    @State private var editing = false
    /**
     * Whether the bar is in its typing row. Never true on this screen, and it is
     * passed anyway rather than being made optional on the bar.
     *
     * That row exists for a **canvas** — a picture of a machine's page, which has
     * to be told a keystroke is coming and announces its own responder back. A
     * page on this phone is a real `WKWebView`: tapping a field in it raises the
     * keyboard the way tapping a field raises the keyboard anywhere, and there is
     * nothing for the bar to say about it.
     */
    @State private var typing = false

    /// Why the last thing typed into the address was not opened, or nil. This
    /// phone's own refusal — a `file:` URL, a port out of range, a port that is
    /// not the one this page is on.
    @State private var refused: String?

    /// Whether this page's own settings are pushed. A `Bool` rather than a
    /// destination value because there is exactly one thing this screen pushes,
    /// which is the same shape `MachineWindowView` uses for the same control.
    @State private var showingSettings = false

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()

            VStack(spacing: 0) {
                // The one outcome a redraw cannot show: an address this phone
                // refused before it ever reached the page. The same banner, in
                // the same place, as the one over a window on the machine.
                if let refused {
                    Banner(text: refused, tone: .warning)
                        .accessibilityIdentifier("localhost.refused")
                }

                /*
                 * The load bar sits under the navigation bar, which is where a
                 * browser has always put it and is now the only place it can go:
                 * this screen has no header of its own to hang it off any more.
                 * A page coming over a phone connection to a laptop is not
                 * instant, and a tap that shows nothing for two seconds reads as
                 * a dead tap.
                 */
                if browser.loading {
                    ProgressView()
                        .progressViewStyle(.linear)
                        .tint(Theme.accent)
                        .accessibilityIdentifier("localhost.loading")
                }

                if browser.inspecting {
                    inspectHint
                    Divider().overlay(Theme.hairline)
                }

                content
            }

            if let toast {
                VStack {
                    Spacer()
                    Text(toast)
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.primary)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(.ultraThinMaterial, in: Capsule())
                        .padding(.bottom, 28)
                        .accessibilityIdentifier("localhost.toast")
                        .accessibilityAddTraits(.updatesFrequently)
                }
                .transition(.opacity)
                .allowsHitTesting(false)
            }
        }
        /*
         * The find bar is **inset** rather than floated over the page, and that
         * is the difference between this and the terminal's.
         *
         * A terminal is a fixed grid the wire owns: covering its last line is
         * survivable because the machine will redraw it. A page is a document
         * the person is reading, and a bar over its last line hides the thing
         * they were searching for at the moment they find it. So the page is
         * given a shorter rectangle and reflows into it.
         */
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if let find, find.isOpen {
                BrowserFindBar(find: find) { closeFind() }
            }
        }
        /*
         * The browser's bar, under the find bar and under everything.
         *
         * Stated **after** the find inset on purpose: bottom insets stack
         * outwards, so the one written last is the one nearest the bottom edge.
         * The page's own controls belong against the edge and the find bar rides
         * above them, which is also the order Safari puts them in.
         */
        .safeAreaInset(edge: .bottom, spacing: 0) { bar }
        /*
         * The system's navigation bar, stated rather than left to inherit — and
         * now carrying nothing but the chevron and one line of title.
         *
         * `.toolbar(.hidden, for: .navigationBar)` used to be here and its removal
         * is what *"still not native"* was about; see the file header. What came
         * off since is the **principal view**, a two-line block naming the page
         * over a mono `http://127.0.0.1:52311/admin  ·  3 connections`:
         *
         * > *"even if we remove the top header of paperclip and all of this basic
         * > information might not be required from the outside. We can just see
         * > and enter."*
         *
         * So the header is the chevron, the title, and nothing — which is exactly
         * what a window on the machine has, and *"top, header and footer… should
         * be same in all type of browsing windows."* `navigationTitle` alone does
         * all three jobs the principal view was splitting: it draws the name, it
         * names the back button on the screen that pushed this one, and it is what
         * VoiceOver reads.
         */
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        /*
         * **The header is the chevron and the address. Nothing else is up here.**
         *
         * > *"this link should be on the top header instead of bottom just like
         * > the normal browsers. I think on top you should have back button and
         * > link only, and then in the bottom you should have the rest of the
         * > options and three dot in the right side which will open the rest of
         * > the options, not upside here."*
         *
         * Two changes in one sentence, and they are two halves of one shape:
         *
         *  - the **address** moved up out of the bar and is the principal item
         *    here, beside the chevron — `BrowserAddressField` with
         *    `place: .header`, which is the same field with the same name and the
         *    same keyboard that the bar draws on every other kind of window;
         *  - the **`…`** came down off this bar and is the last slot in the row
         *    under the page. See `bar`.
         *
         * The principal slot rather than a leading item beside the chevron: a
         * leading item is sized to its content and a nav bar packs them from the
         * edge, so an address would be as long as whatever URL the page last
         * reported and would jump about as it navigated. The principal slot is
         * the space between the two ends, which is what a browser puts an address
         * in.
         *
         * `navigationTitle` below stays even though nothing draws it here any
         * more. It is still the name of the back button on the screen that pushed
         * this one, and it is still what VoiceOver reads for the screen — two
         * jobs a principal view does not do and nobody sees break.
         *
         * The round before this one put the `…` up here on *"not only the bottom,
         * so we can have most of the important controls for the flow"*, and this
         * is not that being undone: the header carries a control, and it is the
         * one he named. See `BrowserChrome` for the whole of that argument.
         */
        .toolbar {
            ToolbarItem(placement: .principal) { addressField }
        }
        .navigationDestination(isPresented: $showingSettings) {
            if let tabID {
                MachineWindowSettingsView(model: model, windowID: "",
                                          pushed: true, phoneTab: tabID)
            }
        }
        /*
         * **Leave when the page does.**
         *
         * Close now lives on the settings screen pushed on top of this one, and
         * pressing it there tears the tunnel down without popping anything —
         * `MachineWindowSettingsView` deliberately dismisses nothing, because
         * popping a screen out from under a thumb is worse than drawing the
         * closed state.
         *
         * So this is the watcher that does it, and it is the same one
         * `MachineWindowView` has kept for a window on the machine: when the tab
         * stops being listed, the page is over and the screen goes with it. Not
         * optimistic — nothing is dismissed on the press, only when the store
         * really has dropped the tab — and it cannot fire for the preview route,
         * where `tabID` is nil from the start and `onChange` therefore never sees
         * a change.
         *
         * `dismiss` rather than `dismiss()` from the environment: the closure this
         * screen was handed is what also clears the pushed value on the list
         * behind it, and popping without it would leave that list holding a
         * tunnel nobody is looking at.
         */
        .onChange(of: tabIsGone) { was, gone in
            guard gone, !was else { return }
            // The flow goes with the window. It is held per tab and the tab is
            // over, so keeping it would be holding a list of clicks nobody can
            // reach — the machine's recorder loses its steps with the view for
            // the same reason. Before the dismiss rather than after, because
            // after it this closure's `tabID` names a row that is already gone.
            if let tabID { flow.forget(tab: tabID) }
            dismiss()
        }
        // Presented off a flag rather than off the capture itself. `.sheet(item:)`
        // tears the sheet down and builds a new one whenever the identity changes,
        // and Wider/Narrower change the capture on every press — which would make
        // the correction control dismiss and re-present the sheet it lives in.
        .sheet(isPresented: Binding(get: { browser.capture != nil },
                                    set: { if !$0 { browser.clearCapture() } })) {
            if let capture = browser.capture {
                InspectSheet(
                    capture: capture,
                    targets: model.agentTargets,
                    target: Binding(get: { model.agentTarget }, set: { model.agentTarget = $0 }),
                    step: { browser.step($0) },
                    send: { line, session in
                        let sentence = model.sendToAgent(line, into: session)
                        show(sentence)
                        return sentence
                    },
                    dismiss: { browser.clearCapture() },
                )
            }
        }
        .onChange(of: tunnel.phase) { _, phase in
            // The load waits for the listener. Pointing a web view at a port
            // nothing is bound to yet gets a connection-refused page cached
            // against that URL, and the reload after it looks like the site is
            // broken rather than like it was early.
            if case let .live(url) = phase { browser.load(first(url)) }
            seed()
        }
        /*
         * The page on screen, written down on this phone.
         *
         * **Two signals rather than one**, and that is the correctness argument
         * rather than a style: a document has no title until it has loaded, and
         * in between `WKWebView` still reports the *previous* page's. Recording
         * the pair together would file every new URL under the name of the page
         * before it — a history that is confidently wrong, which is worse than
         * one that is briefly untitled. See `BrowserHistory`.
         */
        .onChange(of: browser.address) { _, address in
            history.record(address: address, host: model.current?.id ?? "")
            if let tabID { model.browserTabs.note(address: address, for: tabID, machine: model) }
            // And the field follows the page — unless somebody is in it. That
            // guard is the whole of `seed`; see it for why a single-page app
            // makes it load-bearing rather than tidy.
            seed()
        }
        .onChange(of: browser.title) { _, title in
            history.retitle(address: browser.address, title: title, host: model.current?.id ?? "")
            if let tabID { model.browserTabs.retitle(title, for: tabID, machine: model) }
        }
        /*
         * **The page moved, so the flow gets a line and the width gets re-applied.**
         *
         * Stated as its own hook rather than folded into the history one above,
         * because the two make different claims and one of them is about a page
         * that has not finished being one. `flow.at` is told where the view is on
         * every navigation whether or not anything is recording — a recording
         * started later still has to be able to say where it began — and it
         * writes a `navigate` step only while one is running. The address is this
         * app's own view of the web view, never the page's claim about itself,
         * which is the rule `browser-steps.ts` is emphatic about.
         *
         * The size is re-applied because a **document** navigation replaces the
         * document, and with it the viewport meta this app wrote into the last
         * one. `BrowserBridge` re-applies on `didCommit` as well, which is the
         * earlier of the two and the one that catches it before layout; this
         * catches the same-document route changes a single-page app makes, where
         * `didCommit` never fires.
         */
        .onChange(of: browser.address) { _, address in
            if let tabID { flow.at(tab: tabID, url: address) }
            browser.setPageSize(chosenSize)
        }
        /*
         * **The recorder is turned on and off from a card this screen cannot
         * see.**
         *
         * It lives on `MachineWindowSettingsView`, pushed on top of this screen,
         * and it calls `PhoneClickFlow` directly — so what reaches here is a
         * change in an `@Observable` store rather than a call. Watching the store
         * is what lets the two stay strangers: the card knows nothing about a web
         * view and this screen knows nothing about a card.
         */
        .onChange(of: recording) { _, on in
            browser.setRecording(on)
        }
        /*
         * **The chosen size, applied to the page.**
         *
         * Two halves and they are not the same mechanism. The view's own width
         * and height are `WebSurface`'s job — the `WKWebView` is genuinely laid
         * out at 1280 × 800 points and the *view* is scaled to fit, which no CSS
         * in the document can see. This hook is the other half: the viewport
         * instruction for pages that declare a fixed width of their own or none
         * at all, which WebKit would otherwise lay out at 320 or at 980 whatever
         * size the view is. See `PageWidths` for why both halves are needed and
         * which pages each one reaches.
         */
        .onChange(of: chosenSize) { _, size in
            browser.setPageSize(size)
        }
        .onAppear {
            // The tab first: it is what a recorded step is filed under, and a
            // click that arrived before the bridge knew the tab would be dropped
            // rather than mis-filed.
            browser.attach(tab: tabID, flow: flow)
            if case let .live(url) = tunnel.phase { browser.load(first(url)) }
            seed()
            browser.setPageSize(chosenSize)
            browser.setRecording(recording)
            // Last, and only when there is one: whose browser drew this page. See
            // `announce` — it is set by the act of opening and not by coming
            // back, so this fires on the arrival he could not read and on no
            // other.
            if let announce { show(announce) }
        }
        .onDisappear {
            // The handler holds the page's only way back into this app, and the
            // controller holds the handler. Neither should outlive the screen.
            browser.tearDown()
        }
        // No `.credentialPrompt` here any more, and its absence is the point.
        // This screen used to carry its own copy because a cover has no ancestor
        // that can present a sheet; a pushed screen is inside the hierarchy
        // `RootView` presents from, so the one copy up there reaches it. Two
        // copies of a sheet bound to the same optional is how one question gets
        // asked twice.
    }

    /**
     * The first page: the tunnel's origin with `path` resolved against it.
     *
     * `URL(string:relativeTo:)` rather than string concatenation, so that the
     * loopback literal the tunnel bound is preserved and a query or a fragment
     * survives. It returns nil for a path it cannot parse — which cannot happen
     * for anything `LocalhostAddress` produced, since that only ever emits a
     * string it built from a parsed `URL` — and the fallback is the origin
     * itself, because a page at the root of the right server is a far better
     * answer than nothing at all.
     *
     * `.absoluteURL` because a relative `URL` keeps its base, and `WKWebView`
     * will load one perfectly well while `webView.url` reads back as the
     * relative form — which the header above this screen would then print as the
     * address.
     */
    private func first(_ origin: URL) -> URL {
        resolve(path, against: origin)
    }

    /// The same resolution, for a path that came out of the address field rather
    /// than off the row that opened this screen. Written once because a `/admin`
    /// tapped in a list and a `/admin` typed into the bar must land in the same
    /// place, and two spellings of this is how they would stop.
    private func resolve(_ path: String, against origin: URL) -> URL {
        guard path != "/", let resolved = URL(string: path, relativeTo: origin) else { return origin }
        return resolved.absoluteURL
    }

    /// Copy, paste and "sent to an agent" are silent by nature; without this the
    /// buttons feel broken even when they worked. Two and a half seconds, the
    /// same as the terminal screen's.
    private func show(_ message: String) {
        withAnimation { toast = message }
        Task {
            try? await Task.sleep(for: .seconds(2.5))
            withAnimation { toast = nil }
        }
    }

    // MARK: - Chrome

    /**
     * The bar every browser window in this app has, under the page it belongs to.
     *
     * `BrowserPageBar`, the same view `MachineWindowView` mounts. There is no bar
     * written on this screen any more, and that is the point of the round it
     * arrived in: *"top, header and footer, tab bar should be same in all type of
     * browsing windows, including on this phone, including isolated, including
     * the server."*
     *
     * **One row on this screen**, because the address is up in the navigation bar
     * (`addressIn: .header`) and the `…` has come down into the row after Size
     * (`more`). See this file's header for the sentence that did that and for why
     * the other three windows keep the two-row bar.
     *
     * The prefix is `localhost`, unchanged, so every control keeps the name it
     * had — `localhost.back`, `localhost.reload`, `localhost.inspect`. The one
     * name that goes is `localhost.done`: that verb is the `Close this window`
     * card on this page's own settings screen, behind the `…`, under
     * `browser.phone.page.close`. `localhost.settings` is the `…` itself and it
     * has kept its name through both of its moves — up into the header and back
     * down to the end of this row.
     *
     * ## What this screen answers that a machine window cannot, and the reverse
     *
     *  - **Back and Forward are real.** This screen owns the `WKWebView`, so
     *    `canGoBack` and `canGoForward` are its live history — through KVO, which
     *    is what made them work for the `pushState` navigations a dev server makes
     *    constantly. A machine window has no history on the wire and passes nil,
     *    which the bar reads as *do not grey these*. Both truths are kept; neither
     *    is guessed.
     *  - **Reload really does stop.** `BrowserBridge.reload` calls `stopLoading`
     *    while a load is in flight, so the glyph that becomes an ✕ does what the
     *    ✕ says. A machine window has no stop verb on the wire at all.
     *  - **Find is live here and only here.** It needs the document rather than a
     *    picture of it, which is why it is greyed with a reason on the other
     *    screen. Inspect works on both now — the machine answers a tap over the
     *    wire — but the two are still passed differently, because here it is a
     *    script inside the page and there it is a frame on a wire.
     *
     * `whyNoFind` and `whyNoInspect` are passed as nil rather than left at their
     * defaults: those defaults say *this page is on the machine*, which would be
     * a lie printed over a closed tunnel.
     */
    private var bar: some View {
        BrowserPageBar(
            id: "localhost",
            address: $address,
            editing: $editing,
            typing: $typing,
            placeholder: "Address or search",
            go: isLive ? go : nil,
            /*
             * **This bar draws no address.** It is up in the navigation bar on
             * this screen — *"on top you should have back button and link only"* —
             * and `addressField` above is the one that draws it. Two copies of
             * one field over one page would be worse than the bar he asked to
             * have emptied.
             */
            addressIn: .header,
            back: isLive ? { browser.goBack() } : nil,
            forward: isLive ? { browser.goForward() } : nil,
            reload: isLive ? { browser.reload() } : nil,
            // No canvas on this screen: the keyboard belongs to a real web view
            // and comes up when a field in the page is tapped.
            page: nil,
            canGoBack: browser.canGoBack,
            canGoForward: browser.canGoForward,
            loading: browser.loading,
            stop: isLive ? { browser.reload() } : nil,
            find: isLive ? toggleFind : nil,
            finding: find?.isOpen == true,
            inspect: isLive ? { browser.setInspecting(!browser.inspecting) } : nil,
            inspecting: browser.inspecting,
            size: isLive ? pageSize : nil,
            /*
             * **And the `…` is the last slot in that row, not a trailing item up
             * in the header.**
             *
             * > *"in the bottom you should have the rest of the options and three
             * > dot in the right side which will open the rest of the options,
             * > not upside here. Three dot should be here where we have right now
             * > size, so it can bring the options from up to down down to up."*
             *
             * The right-hand end of the row — the place Size was holding while
             * Size was the last thing in it — with Size one slot to its left.
             * Nothing was dropped to make room: *"the rest of the options"* is
             * every page verb, and what he named was a position.
             *
             * The same two answers as before about what it opens: a page with a
             * row on the Browser list pushes its own settings screen, and the one
             * route that has no row — a prototype `ArtifactView` pushes straight
             * at a tunnel — gets the short list. Only one of them is ever handed
             * over, and `BrowserPageBar` builds the control from this screen's own
             * prefix, so it is still `localhost.settings` after the move.
             */
            more: BrowserPageMore(open: settingsPush,
                                  menu: settingsPush == nil ? pageMenu : nil),
            )
    }

    /**
     * The address, up in the navigation bar beside the chevron.
     *
     * > *"this link should be on the top header instead of bottom just like the
     * > normal browsers."*
     *
     * The same view the bar draws on every other kind of browser window, told
     * where it is standing — so it is still `localhost.address`, still seeded
     * rather than bound, still on a URL keyboard with no autocapitalisation, and
     * still submitted by the keyboard's own Go key. `BrowserAddressField` carries
     * the whole of that; what `place: .header` changes is the shape it wears to
     * fit between a chevron and the edge of the screen.
     *
     * `go` is gated on `isLive` exactly as the bar's was. A tunnel that is still
     * opening cannot be navigated, and the field draws itself read-only rather
     * than taking a cursor that would go nowhere — which is the same answer this
     * screen has always given, in a different place.
     */
    private var addressField: some View {
        BrowserAddressField(id: "localhost",
                            address: $address,
                            editing: $editing,
                            placeholder: "Address or search",
                            go: isLive ? go : nil,
                            place: .header)
    }

    /**
     * The Size control, on the one kind of browser window that can honour it.
     *
     * > *"they can pinch and zoom also they can see all the different dimensions
     * > in responsive views how it will look like in mobile how it will look like
     * > on Windows so they can have different dimensions also in phone just like
     * > MacBook."*
     *
     * This screen owns a real `WKWebView`, so both halves are real: the width is
     * a width the page is genuinely laid out at — its media queries fire — and
     * the zoom is the web view's own magnification, the same one a pinch drives.
     * A window on the machine gets the greyed glyph and
     * `BrowserChrome.sizeIsLocal`, which says why in one sentence.
     *
     * `whyNoSize: nil` for the same reason `whyNoFind` and `whyNoInspect` are
     * nil here: the default sentence says *this page is on the machine*, which
     * would be a lie printed over a closed tunnel.
     */
    private var pageSize: BrowserPageSize {
        BrowserPageSize(
            size: chosenSize,
            choose: { widths.choose($0, for: site) },
            zoomIn: { browser.zoom(by: 1.25) },
            zoomOut: { browser.zoom(by: 0.8) },
            actualSize: { browser.actualSize() })
    }

    /**
     * The size this page is being looked at in, and the site it is remembered
     * against.
     *
     * Both read live off the store on every redraw rather than being held in
     * `@State`, which is what makes the choice survive this screen being rebuilt
     * — a tunnel reconnecting does that — and what makes it apply to the next
     * window opened on the same site. See `PageWidths` for why the memory is per
     * site rather than per URL, which is the one place a literal reading of *per
     * page* would have made the feature forget itself on the first link.
     */
    private var chosenSize: PageSize { widths.size(for: site) }

    private var site: String {
        let raw = browser.address.isEmpty
            ? (origin.map { resolve(path, against: $0).absoluteString } ?? "")
            : browser.address
        return PageWidths.site(raw, machinePort: tunnel.port)
    }

    /// Whether the recorder is running on this page. False for the preview route,
    /// which has no tab to key a recording on — see `pageMenu` for what that
    /// route is and why it has no settings screen either.
    private var recording: Bool {
        guard let tabID else { return false }
        return flow.isRecording(tab: tabID)
    }

    /**
     * What the `…` at the end of the row does on a page that has a row on the
     * Browser list: it pushes that page's own settings, exactly as a machine
     * window's does.
     *
     * > *"all of them should have all the options. Should not be that much of
     * > difference in all of them."*
     *
     * Nil for the one route that has no row — `ArtifactView` pushes this screen
     * straight at a tunnel to preview a prototype, so there is no `BrowserTab` id
     * and `MachineWindowSettingsView` would have nothing to resolve. That page
     * gets `pageMenu` instead.
     */
    private var settingsPush: (() -> Void)? {
        guard tabID != nil else { return nil }
        return { showingSettings = true }
    }

    /**
     * Whether the tab this screen is drawing has stopped being listed.
     *
     * Read live off the store rather than captured, for the same reason
     * `MachineWindowView` looks its window up on every redraw: a value taken when
     * the screen was pushed would go on saying whatever was true then. False for
     * the preview route, which has no tab and can therefore never lose one.
     */
    private var tabIsGone: Bool {
        guard let tabID else { return false }
        return model.browserTabs.tab(tabID) == nil
    }

    /**
     * What the `…` opens on the one page with no settings screen behind it.
     *
     * **Not** a page on the Browser tab. Every one of those has a `BrowserTab`
     * row, so its `…` pushes `MachineWindowSettingsView` and this is never
     * reached — see `settingsPush`, and see the file header for why a one-item
     * menu stopped being the right answer the moment that screen existed.
     *
     * What is left is the prototype `ArtifactView` previews: pushed straight at a
     * tunnel, with no row on any list, so there is no tab id to carry into those
     * settings and nothing for them to draw. For that page a menu is the right
     * size and a screen would be a page of white space.
     *
     * The verb is the old Done, which on that route means *come back to the
     * artifact* — the closure the screen was handed. Nothing is lost by it being
     * two taps: closing the screen **is** the teardown, so the chevron top left
     * has always done exactly this in one.
     *
     * The fact is the connection count, which used to be the second line of the
     * header and is the honest signal that something is still talking: a
     * hot-reload socket holds one open with nothing on screen changing. Only when
     * there is more than one, because *"1 connection open"* under every page is
     * the sort of line he means by *"remove this full shit."*
     */
    private var pageMenu: BrowserPageMenu {
        BrowserPageMenu(
            note: tunnel.streams > 1 ? "\(tunnel.streams) connections open" : nil,
            items: [
                BrowserPageMenu.Item(
                    id: "localhost.close",
                    title: "Close this window",
                    icon: "xmark.circle",
                    // Closing the view is the whole of the teardown: the listener
                    // goes, the Mac's socket goes, and the port is unreachable
                    // again until it is tapped.
                    act: dismiss),
            ])
    }

    /**
     * Why the bar is greyed, or nil while the page is really there.
     *
     * A tunnel that is opening and a tunnel that has closed are both *this page
     * cannot be asked for anything*, and they are different sentences because
     * they call for different things from the person reading them: one is
     * *wait* and the other is *this is over*. The machine is named in both,
     * because somebody with two paired needs to know which one the port is on.
     */
    private var whyLimited: String? {
        switch tunnel.phase {
        case .opening:
            return "Port \(tunnel.port) on \(model.theMachine) is still opening."
        case .live:
            return nil
        case .ended:
            return "Port \(tunnel.port) on \(model.theMachine) is closed, so there is nothing "
                + "left to send this page."
        }
    }

    /**
     * What inspect mode is waiting for, said once, at the top of the page.
     *
     * At the top rather than beside the control that turned it on, which is now
     * at the bottom: this is a sentence about *the page*, the page is what the
     * eye is on, and a notice under the navigation bar is where iOS puts a
     * sentence about what the screen is currently doing. The control says its
     * own state where it lives — the glyph is filled while inspecting — so
     * neither end of the screen is silent about it.
     */
    private var inspectHint: some View {
        HStack(spacing: 6) {
            Image(systemName: "hand.tap")
                .font(.system(size: 10))
            Text("Tap anything on the page to describe it.")
                .font(.system(size: 11))
            Spacer(minLength: 0)
        }
        .foregroundStyle(Theme.accent)
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface)
        .accessibilityIdentifier("localhost.inspectHint")
    }

    @ViewBuilder
    private var content: some View {
        switch tunnel.phase {
        case .opening:
            waiting("Opening port \(tunnel.port) on \(model.theMachine)…")
        case .live:
            ZStack {
                DeviceFrame(browser: browser, size: chosenSize)
                if let failure = browser.failure {
                    // The tunnel is up and the *page* failed, which is a
                    // different sentence from the tunnel having gone: the dev
                    // server may simply have restarted.
                    unavailable(title: "That page did not load", detail: failure) {
                        Button("Try again") { browser.reload() }
                    }
                }
            }
        case let .ended(detail):
            unavailable(title: "Port \(tunnel.port) is closed", detail: detail) {
                Button("Close") { dismiss() }
            }
        }
    }

    private func waiting(_ text: String) -> some View {
        VStack(spacing: 12) {
            ProgressView().tint(Theme.accent)
            Text(text)
                .font(.system(size: 13))
                .foregroundStyle(Theme.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func unavailable(
        title: String,
        detail: String,
        @ViewBuilder actions: () -> some View,
    ) -> some View {
        ContentUnavailableView {
            Label(title, systemImage: "bolt.horizontal.circle")
        } description: {
            Text(detail)
        } actions: {
            actions()
        }
        .background(Theme.background)
    }

    private var isLive: Bool {
        if case .live = tunnel.phase { return true }
        return false
    }

    /**
     * Open the find bar on the page that is actually on screen.
     *
     * The session is made **here and now** rather than held for the life of the
     * screen, because it binds to a `WKWebView` and this screen's web view is
     * rebuilt when the tunnel changes underneath it. A session made once at
     * `init` would, after a reconnect, be searching a view that is no longer
     * being drawn — which fails as "no matches" on a page whose text is right
     * there, the worst shape a search can fail in.
     */
    private func openFind() {
        let session = BrowserFindSession(webView: browser.webView)
        session.open()
        find = session
    }

    /// Close it, and take the highlight with it. `WKWebView` keeps the previous
    /// match highlighted after a find bar goes away, so a dismissal that only
    /// hid the bar would leave a page marked up by a search nobody can see.
    private func closeFind() {
        find?.close()
        find = nil
    }

    private func toggleFind() {
        if find?.isOpen == true { closeFind() } else { openFind() }
    }

    // MARK: - The address

    /**
     * The line somebody typed, worked out and then opened.
     *
     * > *"if it is in this phone, I cannot edit the link and make a change and
     * > search it again."*
     *
     * The classification is `LocalhostAddress.classify` — the same pure function
     * the new-window sheet and the machine window's own field call — so
     * `google.com`, `https://…`, `/admin`, `3000` and *what is my ip* mean the
     * same thing in every field in this app. What differs is only where the
     * answer is opened, and on this screen the answer to all of them is **this
     * web view**, because this web view *is* the browser here.
     *
     * The one case that has to be refused rather than opened is another port on
     * the machine. Each port is its own tunnel with its own listener, opened by
     * the screen that owns the list; this screen holds exactly one and cannot
     * mint a second without leaving a socket nobody closes. So it says so plainly
     * and points at the list, rather than silently doing nothing or — worse —
     * loading `localhost:5173` against *this* phone, where nothing is listening.
     *
     * Both spellings of this page's own port are accepted: the machine's, which
     * is what the field shows and what he thinks in, and the loopback port this
     * phone bound, which is what a paste of the raw address contains.
     *
     * ## The one reading this screen adds
     *
     * A line that begins with `/` is a **path on the page you are standing on**.
     * `classify` cannot know that: it reads `/admin` as a line with no host in it
     * and searches the web for it, which is the right answer in the new-window
     * sheet — where nothing is open yet — and a baffling one in a field attached
     * to a page. Resolved against the page's *current* address rather than
     * against the tunnel's root, because that is what a relative path means in
     * every browser and because a page that has walked somewhere else is no
     * longer at the address this window opened on.
     */
    private func go(_ typed: String) {
        guard let origin else { return }
        if typed.hasPrefix("/") {
            let base = URL(string: browser.address) ?? origin
            open(URL(string: typed, relativeTo: base)?.absoluteURL)
            return
        }
        switch LocalhostAddress.classify(typed) {
        case let .tunnel(port, path):
            guard port == tunnel.port || port == origin.port else {
                refused = "Port \(port) is not the one this page is on. Open it from the "
                    + "Browser list and it gets a window of its own."
                return
            }
            open(resolve(path, against: origin))
        case let .page(url):
            open(URL(string: secure(url, typed: typed)))
        case let .search(_, url):
            open(URL(string: url))
        case let .refused(why):
            refused = why
        }
    }

    /**
     * A site typed without a scheme is asked for over https, not http.
     *
     * `LocalhostAddress` puts `http://` in front of a bare hostname because that
     * is what the **machine's** browser wants — it follows the redirect to https
     * itself, and it is not governed by App Transport Security. This web view is,
     * and the exception this app declares is for `127.0.0.1` and nothing else, on
     * purpose: *"an exception on a name is an exception on whatever that resolver
     * decides it means."*
     *
     * So without this, typing `google.com` here would not reach Google. It would
     * reach iOS's refusal — *"iOS refused to load this page over plain HTTP"* —
     * which reads as the app being broken rather than as the address being
     * spelled without an s.
     *
     * Two things are deliberately left alone:
     *
     *  - **Anything typed with a scheme.** Somebody who wrote `http://` meant it
     *    and gets the honest refusal rather than a silent redirection to a
     *    different origin than the one they asked for.
     *  - **An address literal**, `192.168.1.5:8080` and the like. Those are the
     *    dev servers on the same Wi-Fi that `NSAllowsLocalNetworking` exists for;
     *    they are plain HTTP by nature, they load correctly as typed, and https
     *    would break every one of them.
     */
    private func secure(_ url: String, typed: String) -> String {
        guard !typed.contains("://"), url.hasPrefix("http://"),
              let host = URL(string: url)?.host(),
              !BrowserChrome.isLoopback(host), !isAddressLiteral(host) else { return url }
        return "https://" + url.dropFirst("http://".count)
    }

    /// A host that is a number rather than a name — a dotted quad, or a bracketed
    /// IPv6. Nothing clever: what it is separating is *a site somebody typed the
    /// name of* from *a box on this Wi-Fi*.
    private func isAddressLiteral(_ host: String) -> Bool {
        if host.hasPrefix("[") { return true }
        return host.allSatisfy { $0.isNumber || $0 == "." }
    }

    /// Point the web view at it, and clear whatever the last refusal said. Nil is
    /// the case `classify` cannot really produce — every URL it emits it built
    /// from a parsed one — and it is refused rather than force-unwrapped, because
    /// a crash is a worse answer to a strange paste than a sentence.
    private func open(_ url: URL?) {
        guard let url else {
            refused = "That is not an address this phone can open."
            return
        }
        refused = nil
        browser.load(url)
    }

    /// The tunnel's own origin while it is up. Nil is *not open yet* or *closed*,
    /// and both are states where there is nothing to resolve a typed path against.
    private var origin: URL? {
        if case let .live(url) = tunnel.phase { return url }
        return nil
    }

    /**
     * Fill the field from the page, unless somebody is using it.
     *
     * The guard is the whole function, and on this screen it is sharper than
     * anywhere else in the app: everything this feature exists to look at is a
     * dev server, every dev server serves a single-page app, and every route
     * change in one rewrites the URL. Without the guard the field is retyped
     * mid-word and what gets sent is half of what was typed joined to half of
     * where the page went.
     *
     * Before the first page has loaded there is no `browser.address` to seed
     * from, so the tunnel's own origin with the opening path resolved against it
     * stands in — the field says where it is going rather than being blank for
     * the second it takes to get there.
     */
    private func seed() {
        guard !editing else { return }
        let raw = browser.address.isEmpty
            ? (origin.map { resolve(path, against: $0).absoluteString } ?? "")
            : browser.address
        let line = BrowserChrome.shownAddress(raw, machinePort: tunnel.port)
        guard !line.isEmpty, line != address else { return }
        address = line
    }

    /// What the window is called: the page's own title, the address until it has
    /// one, and the port until there is even that. One rule for every kind of
    /// browser window — see `BrowserChrome.pageTitle`.
    private var title: String {
        BrowserChrome.pageTitle(title: browser.title,
                                address: BrowserChrome.shownAddress(browser.address,
                                                                    machinePort: tunnel.port),
                                fallback: "localhost:\(tunnel.port)")
    }
}

/* -------------------------------------------------------------------------- */
/* The web view                                                                */
/* -------------------------------------------------------------------------- */

/**
 * The `WKWebView` and everything it reports back.
 *
 * Held outside the SwiftUI view for the same reason `TerminalBridge` is: a
 * `UIViewRepresentable` is recreated on every state change, and a web view
 * rebuilt mid-load starts the page again from the top.
 *
 * ## The navigation delegate is not enough, and that was the Back button bug
 *
 * `WKNavigationDelegate` fires for **document** navigations. It does not fire
 * for a same-document one — a fragment, a `pushState`, a `replaceState` — and
 * those are not an edge case here, they are the normal case: the whole point of
 * this screen is looking at a dev server, every modern dev server serves a
 * single-page app, and every route change in one is `pushState`. Each of those
 * *does* add an entry to the back-forward list, so `webView.canGoBack` becomes
 * true — and this object never asked again, so its own `canGoBack` stayed false
 * and the button stayed disabled however deep into the site you clicked.
 *
 * `canGoBack`, `title` and `url` are all KVO-compliant on `WKWebView` and none
 * of the three is reliably delivered by the delegate for those navigations, so
 * all three are observed. The delegate callbacks stay: they carry `loading` and
 * the failures, which KVO does not, and they re-arm the inspect script on a new
 * document.
 */
@MainActor
@Observable
final class BrowserBridge: NSObject, WKNavigationDelegate {

    private(set) var title = ""
    private(set) var address = ""
    private(set) var loading = false
    private(set) var canGoBack = false
    private(set) var canGoForward = false
    /// A sentence for the failure overlay, or nil. Cleared on the next attempt.
    private(set) var failure: String?

    /// Whether taps describe elements instead of driving the page.
    private(set) var inspecting = false
    /// The element the last tap described, or nil. Drives the sheet.
    private(set) var capture: ElementCapture?

    /**
     * Which tab's flow a recorded click belongs to, or nil for the preview route.
     *
     * Set by the screen on appear rather than passed to `init`, because this
     * object is `@State` and a `@State` initialiser cannot see the view's own
     * properties. Nil is a real case that stays supported — `ArtifactView` pushes
     * this screen straight at a tunnel with no row on any list — and a click that
     * arrives with no tab is dropped rather than filed somewhere plausible.
     */
    private(set) var tab: String?

    /// Where a recorded click goes. Held rather than reached for, so the store a
    /// screen was given is the store its clicks land in — the same seam
    /// `LocalhostBrowser.flow` is, carried one layer down.
    private var flow: PhoneClickFlow = .shared

    /// The recorder's own state, mirrored here so a new document can be re-armed
    /// without asking the store. The store is still the truth; this is what the
    /// delegate reads at a moment when the screen is not being redrawn.
    private(set) var recording = false

    /// The size the page is being laid out at, kept for the same reason: a new
    /// document arrives with no viewport of ours in it and has to be told again.
    private(set) var pageSize: PageSize = .fit

    let webView: WKWebView

    /**
     * The world the inspect script and its message handler live in.
     *
     * `.defaultClient` rather than `.page`, so the tunnelled site can neither
     * call `__terminaldeck` nor reach `webkit.messageHandlers` — in the page's
     * own world neither exists. See the header of `InspectScript`.
     */
    private static let world = WKContentWorld.defaultClient

    /**
     * The KVO registrations, held so they outlive `init` and die with this
     * object.
     *
     * `NSKeyValueObservation` unregisters itself when it is deallocated, which
     * is the whole reason this is the modern spelling rather than
     * `addObserver(_:forKeyPath:…)`: a `WKWebView` outliving an observer that
     * never removed itself is a crash, not a leak.
     */
    private var observations: [NSKeyValueObservation] = []

    override init() {
        let configuration = WKWebViewConfiguration()
        // The default, persistent store, deliberately: a dev server that logs
        // you in with a cookie should keep you logged in between taps, and an
        // ephemeral store would make every open a fresh browser.
        configuration.websiteDataStore = .default()
        configuration.allowsInlineMediaPlayback = true
        /*
         * **Pinch works on every page, including the ones that forbid it.**
         *
         * > *"they can pinch and zoom"*
         *
         * `WKWebView` honours a page's own `user-scalable=no` by default, and
         * that meta is on more or less every app-shaped site and every dev
         * server's default template — it is what stops a phone zooming a native
         * feeling web app by accident. On a **browser** it is the wrong default:
         * the entire reason for looking at a page here is to examine it, and a
         * page that cannot be zoomed on a six-inch screen cannot be examined at
         * all. Safari has the same override behind *Request Desktop Website*.
         *
         * It has to be set on the configuration rather than on the view, so it is
         * here rather than beside the other view properties below: a
         * `WKWebViewConfiguration` is copied at `init` and changes to it
         * afterwards reach nothing.
         */
        configuration.ignoresViewportScaleLimits = true
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        webView.navigationDelegate = self
        /*
         * **The left edge is the system's, not this page's.**
         *
         * `true` here is what made the screen feel wrong — *"localhost browsing
         * is still not native on iOS"* — and it is worth being precise about
         * why, because on its own the setting is perfectly reasonable and it is
         * what a browser wants.
         *
         * On iOS the swipe from the left edge means one thing everywhere:
         * **go back up the navigation stack**. This screen is pushed, so that
         * gesture is how somebody leaves it — and with this property on, WebKit
         * installs its own edge recognisers and wins, so the gesture instead
         * walked the *page's* history and the screen would not leave at all.
         * The one gesture nobody has to be taught was the one that did something
         * unexpected, which is a worse outcome than the gesture not existing.
         *
         * So page history is a pair of buttons in the bottom toolbar and the
         * edges belong to the platform. Stated as `false` rather than left to
         * the default: this is a decision, `LocalhostChromeTests` pins it, and a
         * missing line is indistinguishable from a line nobody thought about.
         */
        webView.allowsBackForwardNavigationGestures = false
        webView.isOpaque = false
        webView.backgroundColor = .black
        webView.scrollView.backgroundColor = .black

        /*
         * Injected at document start on every page, including the ones a
         * single-page app pushes and the ones a redirect lands on. The script
         * defines its functions and stops; nothing observes the page until
         * `enable` is called, so the cost on a page nobody is inspecting is one
         * closure that ran once.
         */
        let controller = webView.configuration.userContentController
        controller.addUserScript(WKUserScript(source: InspectScript.source,
                                              injectionTime: .atDocumentStart,
                                              forMainFrameOnly: true,
                                              in: Self.world))
        /*
         * The click recorder, on the same terms and in the same world.
         *
         * A second script rather than more of the first, because the two must be
         * able to run at different times and one of them **cancels** the events
         * it sees while the other must never touch them — see
         * `PhoneRecordScript`. Like the inspector it defines its functions and
         * stops; nothing is observed until `enable` is called, so the cost on a
         * page nobody is recording is one closure that ran once.
         */
        controller.addUserScript(WKUserScript(source: PhoneRecordScript.source,
                                              injectionTime: .atDocumentStart,
                                              forMainFrameOnly: true,
                                              in: Self.world))
        /*
         * And the viewport hook, which writes nothing into any document until a
         * width other than this phone's has been chosen. See `PageViewportScript`
         * for why it is document-start rather than something evaluated later: a
         * viewport that arrives after layout is a viewport the page has already
         * been laid out without.
         */
        controller.addUserScript(WKUserScript(source: PageViewportScript.source,
                                              injectionTime: .atDocumentStart,
                                              forMainFrameOnly: true,
                                              in: Self.world))
        // Weak, through a proxy. `WKUserContentController` retains its handlers,
        // and the controller belongs to the web view this object owns — so
        // registering `self` directly is a cycle that keeps a web view, its
        // process and its page alive for the life of the app.
        controller.add(ScriptRelay(self), contentWorld: Self.world, name: InspectScript.messageHandler)
        controller.add(ScriptRelay(self), contentWorld: Self.world,
                       name: PhoneRecordScript.messageHandler)

        watchNavigationState()
    }

    /**
     * Watch the three things the navigation delegate cannot be trusted for.
     *
     * `canGoBack` is the one that was a bug — see the type's header — and
     * `title` and `url` are here because they go stale in exactly the same
     * moment and for exactly the same reason: a single-page app that routes with
     * `pushState` changes all three and tells the delegate nothing, so the
     * header would keep naming the page somebody left two taps ago.
     * `canGoForward` joined them when Forward became a button rather than a
     * right-edge swipe, and it would have had the identical bug for the
     * identical reason had it been read anywhere else.
     *
     * **Any of the four re-reads all four**, rather than each observer
     * updating only its own property. That is deliberate and it is what makes
     * this robust rather than merely correct-looking: these are four
     * notifications about one event, WebKit does not promise they arrive
     * together or in an order, and a `canGoBack` notification that is coalesced
     * away on some future release would otherwise silently bring back the exact
     * bug this exists to fix. Re-reading four properties is free; being wrong
     * about the Back button is what he noticed.
     *
     * `[weak self]` in every block. The observations are owned by this object
     * and observe a view this object owns, so a strong capture would be a cycle
     * holding a web content process open after the screen has gone.
     */
    private func watchNavigationState() {
        // `.initial` so the properties start out agreeing with a web view that
        // may already have been handed a page — not the case today, and a
        // cheaper guarantee than remembering it never will be.
        let options: NSKeyValueObservingOptions = [.initial, .new]
        observations = [
            webView.observe(\.canGoBack, options: options) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.refreshNavigationState() }
            },
            webView.observe(\.canGoForward, options: options) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.refreshNavigationState() }
            },
            webView.observe(\.title, options: options) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.refreshNavigationState() }
            },
            webView.observe(\.url, options: options) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.refreshNavigationState() }
            },
        ]
    }

    /**
     * Copy what the web view currently says into what this screen draws.
     *
     * Cheap enough to call on every signal — three property reads and three
     * assignments, and `@Observable` only publishes the ones that changed.
     *
     * The address falls back to what it was rather than to empty: `url` is nil
     * for the moment between a `stopLoading` and the next load, and a header
     * that blanked its own address in that window would read as the page having
     * gone when nothing has happened at all.
     */
    private func refreshNavigationState() {
        canGoBack = webView.canGoBack
        canGoForward = webView.canGoForward
        title = webView.title ?? ""
        address = webView.url?.absoluteString ?? address
    }

    /// Drop the page's only route back into this app. Called when the screen goes.
    func tearDown() {
        setInspecting(false)
        // The recorder comes down with the screen even though the *flow* does
        // not: the steps live in `PhoneClickFlow` and are still there when the
        // page is opened again, but a page that is no longer on screen is not a
        // page anybody is clicking, and a listener left on it would be a listener
        // on a document nobody can see.
        setRecording(false)
        let controller = webView.configuration.userContentController
        controller.removeScriptMessageHandler(forName: InspectScript.messageHandler,
                                              contentWorld: Self.world)
        controller.removeScriptMessageHandler(forName: PhoneRecordScript.messageHandler,
                                              contentWorld: Self.world)
        webView.stopLoading()
        // Before the web view is released rather than after: an observation left
        // registered against a deallocated object is the classic KVO crash, and
        // this screen is torn down every time somebody closes a page.
        observations = []
    }

    func load(_ url: URL) {
        failure = nil
        // No caching between opens. A dev server's whole job is to have changed
        // since last time, and a phone that shows yesterday's bundle because
        // `WKWebView` had it on disk is the single most confusing thing this
        // feature could do.
        webView.load(URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData))
    }

    func reload() {
        failure = nil
        if loading {
            webView.stopLoading()
            return
        }
        webView.reloadFromOrigin()
    }

    func goBack() {
        if webView.canGoBack { webView.goBack() }
    }

    /// The other half of the pair. Guarded the same way and for the same reason:
    /// the button is disabled when there is nowhere to go, and a method that
    /// silently did nothing when called anyway would make a future bug in that
    /// binding invisible.
    func goForward() {
        if webView.canGoForward { webView.goForward() }
    }

    // MARK: - The tab, the recorder and the width

    /// Which flow this page's clicks belong to, and which store holds it. See
    /// `tab`.
    func attach(tab: String?, flow: PhoneClickFlow = .shared) {
        self.tab = tab
        self.flow = flow
    }

    /**
     * Start or stop watching what is done to the page.
     *
     * The source is evaluated before `enable` for the reason `SavedLogins.install`
     * gives about its own script: a `WKUserScript` is injected at the *start of
     * the next document*, so a view already showing a page would not be watched
     * until somebody navigated away from it and back. The script's own
     * `if (window.__terminaldeckRecord) return` makes the double-install a no-op
     * on every page that gets both.
     */
    func setRecording(_ on: Bool) {
        recording = on
        guard on else {
            run("window.__terminaldeckRecord && window.__terminaldeckRecord.disable()")
            return
        }
        webView.evaluateJavaScript(PhoneRecordScript.source, in: nil, in: Self.world) { _ in }
        run("window.__terminaldeckRecord && window.__terminaldeckRecord.enable()")
    }

    /**
     * Lay the page out at another size.
     *
     * This is only the **viewport** half — the half that reaches a page which
     * declares a fixed width of its own, or none. The other half is the web
     * view's real width and height and belongs to the view (`WebSurface`),
     * because a document cannot be told about those and does not need to be: it
     * simply is that big. See `PageWidths`.
     */
    func setPageSize(_ size: PageSize) {
        pageSize = size
        webView.evaluateJavaScript(PageViewportScript.source, in: nil, in: Self.world) { _ in }
        run(PageViewportScript.apply(size))
    }

    /**
     * Magnify what is on screen, the way a pinch does.
     *
     * `scrollView.zoomScale` rather than `pageZoom`, and the difference is the
     * whole point of keeping these two features apart. `pageZoom` reflows: it
     * changes how many CSS pixels the viewport holds, which is exactly what
     * `PageSize` is for and would quietly make the chosen size a lie — a page
     * asked for 1440 and zoomed to 80% would be laid out at 1800. Magnification
     * leaves the layout alone and makes the result bigger, which is what a person
     * examining a laptop layout on a phone actually wants.
     *
     * Clamped to the scroll view's own bounds rather than to numbers of ours:
     * WebKit derives those from the page's viewport, and a scale outside them is
     * one it would refuse anyway.
     */
    func zoom(by factor: CGFloat) {
        let scroller = webView.scrollView
        let wanted = scroller.zoomScale * factor
        scroller.setZoomScale(clampZoom(wanted), animated: true)
    }

    /// Back to one page pixel per point. Not `1` blindly: on a page WebKit has
    /// decided cannot be zoomed out that far, one is outside the bounds and
    /// setting it would be silently ignored rather than clamped.
    func actualSize() {
        webView.scrollView.setZoomScale(clampZoom(1), animated: true)
    }

    private func clampZoom(_ value: CGFloat) -> CGFloat {
        let scroller = webView.scrollView
        return min(max(value, scroller.minimumZoomScale), scroller.maximumZoomScale)
    }

    // MARK: - Inspecting

    func setInspecting(_ on: Bool) {
        inspecting = on
        if !on { capture = nil }
        run(on ? "window.__terminaldeck.enable()" : "window.__terminaldeck.disable()")
    }

    /// Walk the ancestor chain. +1 towards the document, -1 back to the tap.
    func step(_ delta: Int) {
        run("window.__terminaldeck.step(\(delta))")
    }

    /// The sheet was dismissed. The highlight goes with it, because a box left
    /// on an element nothing is asking about any more is a claim that it is.
    func clearCapture() {
        capture = nil
        run("window.__terminaldeck.clear()")
    }

    private func run(_ script: String) {
        // The script is defined at document start, so the only window in which
        // this can fail is a page mid-navigation — where the next `didFinish`
        // re-arms it anyway. Errors are dropped rather than surfaced: a page
        // that is being replaced is not a fault the user can act on.
        webView.evaluateJavaScript(script, in: nil, in: Self.world) { _ in }
    }

    /**
     * A payload from the page-side script.
     *
     * The URL is read off the web view rather than taken from the message, for
     * the same reason `browser-tab.ts` reads it off the `WebContents`: a payload
     * that could name its own page could tell the agent it is editing a different
     * site than it is. Everything else goes through `Inspect.parseCapture`, which
     * refuses rather than repairs.
     */
    fileprivate func received(_ body: Any) {
        guard inspecting else { return }
        guard let parsed = Inspect.parseCapture(body, url: webView.url?.absoluteString ?? address) else { return }
        capture = parsed
    }

    /**
     * A payload from the page-side **recorder**.
     *
     * The URL is read off the web view here too, and for the same reason: a
     * payload that could name its own page could write a flow that says it was
     * recorded on a site it was not. `PhoneClickFlow.note` refuses rather than
     * repairs, and drops anything that arrives while nothing is recording — which
     * happens for real, in the window between the store being turned off and the
     * page-side listeners coming down.
     */
    fileprivate func recorded(_ body: Any) {
        guard let tab, recording else { return }
        flow.note(body, url: webView.url?.absoluteString ?? address, tab: tab)
    }

    // MARK: - WKNavigationDelegate

    nonisolated func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        MainActor.assumeIsolated { sync(loading: true) }
    }

    /**
     * The new document exists and its document-start scripts have run.
     *
     * This is where the width is re-applied, and the reason it is here rather
     * than only in `didFinish` is layout: a viewport that arrives after the page
     * has finished loading is a viewport the page has already been laid out
     * without, and the result is a visible re-flow — or, on a page that measures
     * itself once on load, no re-flow at all and a layout that is quietly wrong.
     */
    nonisolated func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        MainActor.assumeIsolated {
            if pageSize != .fit { setPageSize(pageSize) }
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        MainActor.assumeIsolated {
            failure = nil
            sync(loading: false)
            // A new document is a new copy of the script, with `active` false and
            // no listeners. Without this, inspect mode silently stops working the
            // first time a dev server hot-reloads a route change — which is the
            // most common thing that happens on the page being inspected.
            if inspecting { run("window.__terminaldeck.enable()") }
            // The recorder has exactly the same problem and it is worse there: a
            // recording that quietly stopped collecting after the first
            // navigation would hand somebody a flow that is missing everything
            // they did after step one, and look complete.
            if recording { setRecording(true) }
            if pageSize != .fit { setPageSize(pageSize) }
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        MainActor.assumeIsolated { fail(error) }
    }

    nonisolated func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error,
    ) {
        MainActor.assumeIsolated { fail(error) }
    }

    private func fail(_ error: Error) {
        sync(loading: false)
        let code = (error as NSError).code
        // -999 is "a load was replaced by another load", which happens on every
        // redirect and on `stopLoading`. Reporting it puts an error on screen
        // for a page that is working.
        guard code != NSURLErrorCancelled else { return }
        failure = sentence(for: error)
    }

    /**
     * A sentence, never `localizedDescription`.
     *
     * The failure that actually happens here is the dev server having
     * restarted, and Foundation calls that *"Could not connect to the
     * server"* — true, and it points at the wrong machine. Whoever reads it on
     * a phone has to know the tunnel is fine and the thing at the far end is
     * not.
     */
    private func sentence(for error: Error) -> String {
        switch (error as NSError).code {
        case NSURLErrorCannotConnectToHost, NSURLErrorNetworkConnectionLost:
            return "The server on the machine did not answer. It may be restarting."
        case NSURLErrorTimedOut:
            return "The machine took too long to answer."
        case NSURLErrorAppTransportSecurityRequiresSecureConnection:
            return "iOS refused to load this page over plain HTTP."
        default:
            return "The page could not be loaded."
        }
    }

    /// The delegate's half: whether a document navigation is in flight. The
    /// title, the address and `canGoBack` are not touched here any more — they
    /// are observed, because the delegate is silent for the same-document
    /// navigations a dev server makes constantly. See the type's header.
    private func sync(loading: Bool) {
        self.loading = loading
    }
}

/**
 * The page, drawn in the shape of the device it is being looked at on.
 *
 * > *"when i make other frame like desktop or laptop biew it is trying to fit
 * > inside the same given space a sphone instead of giving me less hieght and
 * > like actual laptop dimension"*
 *
 * This is the answer to that sentence, and it is a view rather than a modifier
 * because there are three things on screen at once and only one of them is the
 * page: the **ground** the device sits on, the **frame** with its edge, and the
 * quiet line under it that says the pixels. A desktop browser's device toolbar
 * draws exactly these three, and it draws them because a rectangle floating with
 * no edge on the same colour as the page reads as a layout that broke rather
 * than as a laptop.
 *
 * ## Nothing at all in the default state
 *
 * At *This phone* there is no ground, no edge and no caption — the web surface
 * is the whole space, byte-for-byte what this screen drew before any of this
 * existed. That matters more than it looks: the default is the state every
 * person is in every time they open a page, and a border of ours around it would
 * be this feature charging rent on people who never used it.
 *
 * ## The scale is one number, and it is capped at life size
 *
 * `PageFit` does the arithmetic and is tested on its own, because it is the
 * whole of *"like actual laptop dimension"*: one factor for both axes so the
 * proportions survive, the smaller of the two ratios so the rectangle fits on
 * the axis that binds first, and never above 1 so a 320-wide phone does not get
 * blown up bigger than the phone in his hand.
 *
 * ## Why the caption is not a second line under a control
 *
 * *"you are also putting so much of a description under the title of that
 * thing…"* — the standing correction, and this is not an instance of it. The
 * caption is not under a control and it is not a description: it is the
 * measurement of the object above it, `1280 × 800`, in the place every device
 * toolbar puts it. There is no control on this screen it could be sitting under;
 * the control is the Size menu in the bar, and its rows are titles.
 */
private struct DeviceFrame: View {
    let browser: BrowserBridge
    let size: PageSize

    var body: some View {
        GeometryReader { geo in
            drawn(in: geo.size)
                .frame(width: geo.size.width, height: geo.size.height)
        }
    }

    /**
     * Framed or full-bleed, and the branch is the size itself.
     *
     * `PageFit` returns nil exactly when the choice is *This phone*, so this
     * `if let` is the only place the two states are told apart — a second test
     * of `size.device == .fit` somewhere else is how one of them comes to
     * disagree with the other.
     */
    @ViewBuilder
    private func drawn(in box: CGSize) -> some View {
        if let fit = PageFit(size, in: box) {
            VStack(spacing: 6) {
                Spacer(minLength: 0)
                WebSurface(browser: browser, layout: fit.layout)
                    .frame(width: fit.drawn.width, height: fit.drawn.height)
                    .clipShape(Self.edge)
                    /*
                     * The lift is a plate **behind** the page, not a filter over
                     * it. `.shadow` applied to a `UIViewRepresentable` asks UIKit
                     * to composite a live-rendering `WKWebView` layer through an
                     * offscreen pass, which is the kind of thing that is either
                     * expensive or quietly dropped depending on the OS — and this
                     * page is being scrolled and pinched while it is on screen. A
                     * rounded plate under it is neither, and it also fills the
                     * frame's interior so a document that paints no background of
                     * its own reads as a blank screen rather than as a hole.
                     *
                     * The edge and the lift are both needed and neither alone
                     * does it: a border with no lift is a table cell, and a
                     * shadow with no border disappears against a page whose own
                     * background is near-white.
                     */
                    .background(
                        Self.edge
                            .fill(Theme.surface)
                            .shadow(color: .black.opacity(0.16), radius: 9, x: 0, y: 3)
                    )
                    .overlay(Self.edge.strokeBorder(Theme.hairline, lineWidth: 1))
                    // A container rather than a decoration: the frame's drawn
                    // rectangle is the claim this round is judged on, and
                    // `LocalhostUITests` reads it back off the screen and asks
                    // whether a laptop came out laptop shaped. `.contain` leaves
                    // the page inside reachable, which the pinch case needs.
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel("Page frame")
                    .accessibilityIdentifier("localhost.pageFrame")
                // The measurement comes off the fit rather than off `size`, so
                // the number under the frame is the rectangle the frame was
                // actually built from and cannot drift from it by a rounding or
                // by somebody adding a clamp later.
                Text(PageSize.pixels(fit.layout))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Theme.faint)
                    .accessibilityIdentifier("localhost.pageFrame.measure")
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // The tinted ground. `Theme.background` is the app's raised shade
            // rather than the page's own white, which is the difference between
            // a device sitting on a desk and a page with a hairline drawn on it.
            .background(Theme.background)
        } else {
            WebSurface(browser: browser, layout: nil)
        }
    }

    /// 12, not the app's usual 20. A card's radius on a rectangle drawn at 0.29
    /// would eat the corners of the page inside it; 12 reads as a bezel at every
    /// scale in the list.
    private static let edge = RoundedRectangle(cornerRadius: 12, style: .continuous)
}

/**
 * The page, at whatever size it is being looked at.
 *
 * The representable's own view is a plain container rather than the `WKWebView`
 * itself, and that is the whole of how the size feature is built. The container
 * puts the web view inside it at the chosen **layout** size and scales it to
 * fit. A `UIView` transform is not something the document can see — it is not a
 * CSS transform, it changes no property the page can read, and `window.innerWidth`
 * inside a 1280-point web view is 1280 no matter what its superview does with
 * the result.
 *
 * That is the difference between this and the cheap version of the feature, and
 * it is the difference he would notice in a second: scale a phone layout up and
 * you have a phone layout in bigger letters, which answers nothing about how the
 * page behaves on a laptop.
 */
private struct WebSurface: UIViewRepresentable {
    let browser: BrowserBridge
    /// The CSS rectangle to lay the page out in, or nil for this phone's own — in
    /// which case nothing here is touched and the view is the size it always was.
    var layout: CGSize?

    func makeUIView(context: Context) -> ScaledPageView {
        ScaledPageView(browser.webView)
    }

    func updateUIView(_ view: ScaledPageView, context: Context) {
        // The size is the only thing that comes through here. Every other change
        // goes through `BrowserBridge`, which owns the web view — reloading from
        // here would restart the page on every redraw.
        view.layout = layout
    }
}

/**
 * A box that holds the web view at one size and draws it at another.
 *
 * ## The height is the device's now, and that is the whole change
 *
 * This used to take the chosen width but keep the **phone's** own height,
 * divided by the scale — so a laptop came out 1280 CSS pixels wide and as tall
 * as an iPhone, a column of laptop-width text that answers nothing about how the
 * page behaves on a laptop. That is the defect he reported.
 *
 * The old expression is deliberately not quoted here. `LocalhostChromeTests`
 * proves it has not come back by grepping this file for it, and a grep cannot
 * tell a quotation from the real thing — three tests were failed by their own
 * comments on the night this was written. The web view is now laid out at the device's real width **and**
 * height, so `100vh` in a laptop frame is 800 CSS px, and the container it sits
 * in has already been sized to the same rectangle by `DeviceFrame`.
 *
 * ## The scale is recomputed here rather than passed in
 *
 * `PageFit` worked it out once already and `DeviceFrame` sized this container
 * with it, so this could take the number as a property. It does not, and takes
 * the smaller of the two ratios of what it actually has: a rounded container is
 * a fraction of a point off the exact ratio, and a scale that came from
 * elsewhere would be the wrong one by that fraction — visible as a hairline of
 * the page clipped along one edge. Derived from `bounds`, the fit is exact by
 * construction, and the two axes agreeing is a test rather than a hope.
 *
 * ## `bounds` and `center`, never `frame`
 *
 * A view's `frame` is undefined while a non-identity transform is on it — UIKit
 * says so outright — and the symptom of getting it wrong is not a crash, it is a
 * page drifting a few points further off-centre on every redraw. So the transform
 * is cleared, the size is set on `bounds`, the transform goes back on, and the
 * position is set with `center`, which is transform-independent.
 */
final class ScaledPageView: UIView {

    private let web: WKWebView

    /// The CSS rectangle to lay out in, or nil for the container's own size.
    var layout: CGSize? {
        didSet {
            guard layout != oldValue else { return }
            setNeedsLayout()
        }
    }

    init(_ web: WKWebView) {
        self.web = web
        super.init(frame: .zero)
        // The web view is owned by `BrowserBridge` and outlives this container,
        // which is rebuilt whenever SwiftUI feels like it. Re-adopting a view
        // that already has a superview is a move rather than a copy, so this is
        // safe on the second and every later mount.
        addSubview(web)
        // Manual layout throughout: `layoutSubviews` below is the only thing that
        // may position this view, and an autoresizing mask would fight it every
        // time the container changed size.
        web.autoresizingMask = []
        web.translatesAutoresizingMaskIntoConstraints = true
        // The page's own background shows through wherever the document does not
        // paint, and inside a frame that is the frame's own interior. Left
        // transparent it would show the tinted ground instead, so a page with no
        // background of its own would look like a hole rather than like a blank
        // screen on a laptop.
        clipsToBounds = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("not from a nib")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let box = bounds.size
        guard box.width > 0, box.height > 0 else { return }

        guard let layout, layout.width > 0, layout.height > 0 else {
            // The ordinary path, and it is byte-for-byte what this screen did
            // before the size control existed: the web view is the container.
            web.transform = .identity
            web.frame = bounds
            return
        }

        let scale = min(box.width / layout.width, box.height / layout.height)
        web.transform = .identity
        web.bounds = CGRect(origin: .zero, size: layout)
        web.transform = CGAffineTransform(scaleX: scale, y: scale)
        // `bounds`, not `box`: a centre is a point in this view's own coordinate
        // space and `box` is only its size. They agree while the origin is zero,
        // which is why this compiled as arithmetic in somebody's head and not in
        // the compiler.
        web.center = CGPoint(x: bounds.midX, y: bounds.midY)
    }
}

/**
 * The message handler, holding its owner weakly.
 *
 * `WKUserContentController` retains every handler added to it, and that
 * controller belongs to the `WKWebView` that `BrowserBridge` owns — so adding
 * the bridge itself makes a cycle, and the symptom is not a leak anybody
 * notices: it is a web content process still running, still holding the
 * tunnelled page, after the screen it belonged to has gone. `tearDown` removes
 * the handler as well; this is the half that survives a path that forgets to.
 */
private final class ScriptRelay: NSObject, WKScriptMessageHandler {
    private weak var bridge: BrowserBridge?

    init(_ bridge: BrowserBridge) {
        self.bridge = bridge
    }

    /**
     * Two scripts post through this, and they are told apart by the **handler
     * name** rather than by a field in the payload.
     *
     * The name is chosen by whoever registered the handler; a field in the body
     * is chosen by whatever posted the message. Only one of those is a fact this
     * side owns, and the whole of this file's security posture is that the page
     * is never allowed to decide what its message is.
     */
    nonisolated func userContentController(
        _ controller: WKUserContentController,
        didReceive message: WKScriptMessage,
    ) {
        let name = message.name
        let body = message.body
        MainActor.assumeIsolated {
            switch name {
            case PhoneRecordScript.messageHandler: bridge?.recorded(body)
            default: bridge?.received(body)
            }
        }
    }
}
