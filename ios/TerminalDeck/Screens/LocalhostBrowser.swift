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
 * ## The bar is `BrowserPageBar` now, and the header lost its second line
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
 * Inspect · More — and the toolbar written here is gone. What moved:
 *
 *  - **The address arrived**, as a real field. It is spelled the way the person
 *    who opened it thinks of it — `localhost:3000/admin`, not the random
 *    loopback port this phone bound — and both spellings are accepted back. See
 *    `BrowserChrome.shownAddress`.
 *  - **Done left the bar.** It tore the tunnel down, which is a thing you do to
 *    the window rather than to the page, so it is `Close this window` inside the
 *    `…`. He blessed Done's position — *"last button I think is on its correct
 *    place"* — in a round where the row ended with it; the row is the same six
 *    controls under all three kinds of window now, and the one-tap way out was
 *    never that button anyway. The chevron top left leaves this screen and
 *    closes the tunnel exactly as Done did.
 *  - **The header lost its second line.** It was the page title over a mono
 *    `http://127.0.0.1:52311/admin  ·  3 connections`. *"even if we remove the
 *    top header of paperclip and all of this basic information might not be
 *    required from the outside. We can just see and enter."* The address is in
 *    the field now, which is better than a label of it, and the connection count
 *    is one line inside the `…` — the honest signal that a hot-reload socket is
 *    still talking with nothing on screen changing, kept, and off the top of the
 *    page.
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
     * The tab this page is in, if it is in one.
     *
     * Nil is a real case and stays supported — `DevServerReport` pushes this
     * screen straight at a tunnel without going through the strip — so every use
     * below is guarded rather than forced. When it is set, the two `onChange`
     * hooks that already feed the history feed the strip as well, which is what
     * makes a pill read *"admin"* instead of *"localhost:3000"* forever.
     */
    var tabID: String?
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
        .onAppear {
            if case let .live(url) = tunnel.phase { browser.load(first(url)) }
            seed()
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
     * `BrowserPageBar`, the same view `MachineWindowView` mounts, with the same
     * two rows under it — the address and Go, then Back · Forward · Reload · Find
     * · Inspect · More. There is no bar written on this screen any more, and that
     * is the point of the round: *"top, header and footer, tab bar should be same
     * in all type of browsing windows, including on this phone, including
     * isolated, including the server."*
     *
     * The prefix is `localhost`, unchanged, so every control keeps the name it
     * had — `localhost.back`, `localhost.reload`, `localhost.inspect`. The one
     * name that goes is `localhost.done`: that verb is `Close this window` in the
     * menu now, under `localhost.close`.
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
     *  - **Find and Inspect are live here and only here.** Both need the document
     *    rather than a picture of it, which is why they are greyed with a reason
     *    on the other screen. `whyNoFind` and `whyNoInspect` are passed as nil
     *    rather than left at their defaults: those defaults say *this page is on
     *    the machine*, which would be a lie printed over a closed tunnel.
     */
    private var bar: some View {
        BrowserPageBar(
            id: "localhost",
            address: $address,
            editing: $editing,
            typing: $typing,
            placeholder: "Address or search",
            go: isLive ? go : nil,
            back: isLive ? { browser.goBack() } : nil,
            forward: isLive ? { browser.goForward() } : nil,
            reload: isLive ? { browser.reload() } : nil,
            // No canvas on this screen: the keyboard belongs to a real web view
            // and comes up when a field in the page is tapped.
            page: nil,
            more: nil,
            unavailable: whyLimited,
            canGoBack: browser.canGoBack,
            canGoForward: browser.canGoForward,
            loading: browser.loading,
            stop: isLive ? { browser.reload() } : nil,
            find: isLive ? toggleFind : nil,
            finding: find?.isOpen == true,
            whyNoFind: nil,
            inspect: isLive ? { browser.setInspecting(!browser.inspecting) } : nil,
            inspecting: browser.inspecting,
            whyNoInspect: nil,
            menu: pageMenu)
    }

    /**
     * What the `…` opens on a page this phone is holding open.
     *
     * A menu rather than a screen, because there is no screen: a page over a
     * tunnel has no window on the machine and so nothing that
     * `MachineWindowSettingsView` would have to show. What it has is one verb and
     * one fact.
     *
     * The verb is the old Done. *"Last button I think is on its correct place"*
     * was said of a row that ended with it; the row is now the same six controls
     * under all three kinds of window, and this is the thing that made the phone's
     * row different. Nothing is lost by the move — closing the screen **is** the
     * teardown, so the chevron top left has always done exactly this, and it is
     * still one tap.
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
                WebSurface(browser: browser)
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
        // Weak, through a proxy. `WKUserContentController` retains its handlers,
        // and the controller belongs to the web view this object owns — so
        // registering `self` directly is a cycle that keeps a web view, its
        // process and its page alive for the life of the app.
        controller.add(ScriptRelay(self), contentWorld: Self.world, name: InspectScript.messageHandler)

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
        webView.configuration.userContentController
            .removeScriptMessageHandler(forName: InspectScript.messageHandler, contentWorld: Self.world)
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

    // MARK: - WKNavigationDelegate

    nonisolated func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        MainActor.assumeIsolated { sync(loading: true) }
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

private struct WebSurface: UIViewRepresentable {
    let browser: BrowserBridge

    func makeUIView(context: Context) -> WKWebView {
        browser.webView
    }

    func updateUIView(_ view: WKWebView, context: Context) {
        // Nothing: every change goes through `BrowserBridge`, which owns the
        // view. Reloading from here would restart the page on every redraw.
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

    nonisolated func userContentController(
        _ controller: WKUserContentController,
        didReceive message: WKScriptMessage,
    ) {
        MainActor.assumeIsolated { bridge?.received(message.body) }
    }
}
