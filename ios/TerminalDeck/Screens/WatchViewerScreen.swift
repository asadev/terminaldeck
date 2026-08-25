/**
 * The one live canvas in this app, and the screen that mounts it for a page no
 * window claims.
 *
 * ## There is exactly one canvas, and that is a rule rather than a layout choice
 *
 * `WatchLink` holds **one** frame sink — *"a phone screen is one surface"* — and
 * `WatchSurfaceUIView.tearDown()` sets `watch.frameHandler = nil` and sends
 * `browser.unwatch` **unconditionally**, without checking whether the sink is
 * still its own. So two canvases alive at once is not a question of taste, it is
 * a defect generator: the second to mount steals the frames, and the first to
 * unmount stops the cast and unregisters the survivor — which then sits frozen
 * with no way to re-register, because its `didMoveToWindow` has already fired
 * and its width has not changed, so nothing calls `startWatching` again.
 *
 * `WatchStage` exists so that this rule has one place to be stated and two
 * places to be obeyed. It is a thin wrapper over `WatchSurface` on purpose: what
 * it carries is not layout, it is the invariant.
 *
 * The two mounts are:
 *
 *  - **`MachineWindowView`** — any page on the machine that is being cast, which
 *    since this round includes the machine's own front tab. Every row on the
 *    Browser tab opens that screen; see its header for why there is no longer a
 *    second kind of browser window.
 *  - **`WatchViewerScreen`**, below — the same picture reached from **Settings**,
 *    through `WatchSurfacesView`, which is handed a `WatchLink` and no model.
 *
 * A push from either one lands on a screen that mounts no canvas of its own, so
 * the stack can never hold two.
 *
 * ## This screen used to be the video he was complaining about
 *
 * > *"if I open a browser window it feels like a streaming, exactly — and if I
 * > open any one it feels like just like a video. I cannot click inside, I cannot
 * > touch the URL and things."*
 *
 * It is worth being exact about which screen that was, because the fix is not
 * where it looked. On a **server** — his own WSL box — a page opened from the
 * Browser tab's `+` with an address in it goes through `web.open`, which
 * `src/headless/host.ts` backs with `browserDrive.open({ url, isolate: false })`.
 * That lands in the drive's **own front slot**, and `openTab` mints that slot no
 * shell id, so it appears in `browser.surfaces` under the empty window name and
 * in **no** `browser.window.rows` entry. Which means: every page he opened from
 * the `+` arrived here, on the screen that had no address bar on it, rather than
 * on `MachineWindowView` which has had one all along.
 *
 * The old header argued that was correct — *"no address, no Back, no Close:
 * every one of those is a `browser.control` verb addressed by window id."* Back
 * and Close, yes. **The address, no.** `web.open` navigates that exact slot: it
 * is how the page got here in the first place, and sending a second one moves
 * this page rather than opening another. So this screen has an address field and
 * a Reload that re-opens what the surface reports.
 *
 * ## Which is not the same as *any* surface, and that distinction is measured
 *
 * `web.open` is honest about **the front tab only**. On a headless host it is
 * `browserDrive.open({ isolate: false })` into the drive's own slot — this page.
 * On the desktop it is `openAppLink(mainWindow…)`, a new tab in the app's own
 * browser. So on a surface that is a real window, typing an address would move a
 * *different* page, which is worse than a field that will not move this one. That
 * case draws the address **read-only**, at the machine's last word on it.
 *
 * ## Back and Forward are drawn, and they are dead
 *
 * They used to be left out on the rule about never drawing a control that cannot
 * act. He put the two screens side by side and read the result as two products —
 * *"it should be the same case, or all the options should be available at
 * least"* — so a verb this page cannot be asked for is greyed in its own place
 * with the reason on the ⓘ beside the address. Nothing has become sendable: the
 * desktop's history is not on this wire and a surface with no window id could not
 * be named in a `browser.window.act` even if it were.
 *
 * ## And this screen's header is a chevron and a title, with nothing beside them
 *
 * Every other browser window carries a `…` in the header now — *"not only the
 * bottom, so we can have most of the important controls"* — and it is drawn only
 * where it opens something. This screen is the one that has nothing: a page the
 * machine is casting without owning has no settings screen, because every card
 * on one is addressed by a window id and this page has none. So there is no
 * trailing button here and no line explaining its absence, which is the same
 * rule the bar follows for a control that would have led nowhere.
 *
 * Typing is not a control on this bar at all any more. *"If we just click inside
 * and type from our keyboard, it should work… I should not have to have this
 * separate button of keyboard."* A tap on the picture raises the system keyboard
 * on the canvas itself — `WatchSurfaceUIView.onTap` — and the bar's job is to
 * say so while it is up. See `BrowserPageBar`.
 */

import SwiftUI

/**
 * The canvas, and the fact that there is only ever one of it.
 *
 * Everything about painting, acking and gestures is `WatchSurfaceUIView`'s; this
 * is the SwiftUI face of it plus the black ground a letterboxed desktop page
 * needs. Black rather than `Theme.background`: the bars either side of a 16:10
 * page scaled into a phone are not part of the app's paper, and a page's own
 * white against a light theme's white would make the page's edges invisible.
 */
struct WatchStage: View {
    let watch: WatchLink
    /// The surface name — `""` for a server's front tab, else the shell tab id
    /// the window list uses. See `MachineBrowserView` on why that id is the join.
    let window: String

    /**
     * Whether the screen holding this stage is the one being looked at.
     *
     * The other half of the one-canvas rule, and the half that was missing. The
     * rule above says two canvases must not both hold the sink; this says two
     * must not both be **built**, which is the thing a screen can actually
     * control. Three screens can mount a stage now — a window on the Browser
     * tab, the surface viewer, and the page inside a session — and they sit on
     * different tabs, where *"switching back to a tab whose stack already has a
     * screen on it fires nothing"* (`TerminalScreen.frontmost`, measured). So a
     * screen left behind on another tab would otherwise keep a canvas alive,
     * keep a `browser.watch` running, and keep taking frames that nobody can see.
     *
     * False draws the black ground and nothing else, which is also what stops the
     * cast: `dismantleUIView` runs and sends `browser.unwatch`. A tab you are not
     * looking at costs the wire nothing.
     */
    var mounted: Bool = true

    /// Told how tall the picture is, so a screen can hand the rest of its height
    /// to something else instead of drawing a letterbox. See
    /// `WatchSurface.onPageHeight`.
    var onPageHeight: ((CGFloat) -> Void)?

    /**
     * Set by a screen that is itself drawing the agent's sentence, so the lock
     * card says the lock and a short line instead of the same sentence again.
     *
     * Defaults false, and the default is the safe one: the two mounts that have
     * no bar never set it and keep the full sentence, which on those screens is
     * the only sentence there is. See `WatchSurface.sentenceIsDrawnAbove`.
     */
    var sentenceIsDrawnAbove = false

    var body: some View {
        ZStack {
            Color.black
            if mounted {
                WatchSurface(watch: watch, window: window,
                             onPageHeight: onPageHeight,
                             sentenceIsDrawnAbove: sentenceIsDrawnAbove)
            }
        }
    }

    /**
     * Tell the canvas to put the keyboard away.
     *
     * The one direction left: raising it is the canvas's own answer to a tap on
     * the page — *"it should just come up from down"* — and what a screen still
     * knows is when typing has to stop, because leaving, folding and handing the
     * page back are all facts up here and none of them are on the wire.
     *
     * The hand-off is a static plus a notification rather than a call, because
     * the thing that has to receive it is a `UIView` inside a
     * `UIViewRepresentable` and the sender is a SwiftUI value type with no
     * reference to it. The view reads and clears the command on the next runloop
     * tick.
     *
     * Written once here rather than in each screen that has to end typing: two
     * copies of a three-line hand-off is how one of them ends up posting without
     * setting the command.
     */
    static func post(_ command: WatchCommand, to window: String) {
        WatchSurface.pending = command
        NotificationCenter.default.post(name: WatchSurface.commandNote, object: window)
    }
}

/**
 * A page the machine is casting, reached from **Settings** — the one route left
 * that has a `WatchLink` and no model behind it.
 *
 * The Browser tab does not push this any more. Every row there is a browser
 * window as far as anybody using it is concerned, so every row opens
 * `MachineWindowView` — including the machine's own front tab, which used to
 * come here and was the screen with one Reload on it that he compared against a
 * window and called two different types.
 *
 * Full-bleed, which is the only size at which a desktop page is a thing a
 * fingertip can hit, with the browser's own bar under it. What that bar carries
 * is decided by what this page can honestly be asked to do; see the file header
 * and `BrowserPageBar`.
 */
struct WatchViewerScreen: View {
    let watch: WatchLink
    let surface: BrowserSurfaceRow

    /**
     * The model, when whoever pushed this has one — and it is optional for a
     * reason rather than out of convenience.
     *
     * It carries two things now. The first is `DeckModel.localhostPageIsOpen`,
     * the flag the `TabView` reads to decide whether its floating pill is drawn
     * over what is on top of the Browser tab. *"Pill should be on here only on
     * the homepage or machines or settings"* — a cast page is the whole thing you
     * came for and the pill would sit over the bottom of it, pointing somewhere
     * else. `DeckChrome` holds that rule and explains why the flag exists at all:
     * a `.toolbar(.hidden, for: .tabBar)` written on a pushed screen has **no
     * effect** on iOS 26, measured.
     *
     * The second is the address bar: `web.open` is a model verb
     * (`openPageOnMachine`), so a screen with no model has no way to navigate.
     * That is not a hypothetical — `WatchSurfacesView`, reached from a
     * `DeckModel.SettingsRoute`, is handed only a `WatchLink`, and it is now the
     * *only* route to this screen.
     *
     * Nil no longer means **no field**. The address is drawn read-only there,
     * with the reason on the ⓘ beside it: *"This one is the one that should be
     * everywhere."* Where you are is the one thing a page owes you, and a model
     * this screen was not handed is not a reason to keep it.
     */
    var chrome: DeckModel?

    /// What is in the address field. Seeded from the surface, never bound to it —
    /// see `MachineWindowView.seed` for why that distinction is the whole of
    /// whether an address bar over a wire behaves like one.
    @State private var address = ""
    @State private var seeded = false
    @State private var editing = false
    @State private var typing = false
    /// Why the last thing typed was not opened, or nil. This screen has no
    /// window list to carry a machine's refusal, so the sentence is drawn here.
    @State private var notice: String?

    /**
     * Whether typing an address moves **this** page.
     *
     * Two conditions and both are needed. `web` is negotiated on its own, so a
     * machine can cast without offering it. And the verb behind the field is
     * `web.open`, which lands in the drive's own slot — the front tab, the one
     * surface whose window name is empty — so on any other surface it would move
     * a page that is not the one on screen. See the file header.
     */
    private var canNavigate: Bool { surface.window.isEmpty && chrome?.canOpenPages == true }

    /**
     * Why the dead controls on the bar are dead. Never nil on this screen: Back
     * and Forward cannot be sent for any surface, so there is always something to
     * explain.
     *
     * The machine is named where this screen knows which one it is. Reached from
     * Settings there is no model and therefore no name, and *the machine* is the
     * honest noun rather than a guess at which of the paired ones this is.
     */
    private var whyLimited: String {
        let name = chrome.map { $0.current?.label ?? $0.theMachine } ?? "The machine"
        if canNavigate {
            return "This is \(name)'s own tab rather than one of its windows. The machine names a "
                + "window with an id and this page has none, so Back and Forward cannot be "
                + "addressed to it.\n\nTyping an address still moves this page: that is a different "
                + "verb, and it lands in this same tab."
        }
        return "\(name) is casting this page and nothing on this bar can be sent to it. The address "
            + "is what the machine last reported for the page."
    }

    /**
     * Whether the tab this screen is on is the one being looked at.
     *
     * The one-canvas rule, applied from the outside — see `WatchStage.mounted`.
     * A screen pushed on the Browser tab stays alive when somebody switches tabs
     * (no lifecycle callback fires), so without this it would keep a canvas and a
     * `browser.watch` running behind a session screen that has its own.
     *
     * The `nil` model is the one path this cannot answer: `WatchSurfacesView`
     * reaches this screen from a Settings route and is handed only a `WatchLink`.
     * That branch stays mounted, which leaves one crossing — a page open in
     * Settings while a session opens its own — that the canvas itself survives
     * rather than avoids: `WatchSurfaceUIView.owner` makes the teardown
     * identity-guarded, so the later mount wins and the earlier one is not left
     * registered with a dead closure.
     */
    private var mounted: Bool { chrome.map { $0.tab == .localhost } ?? true }

    var body: some View {
        ZStack {
            /*
             * The app's paper, **not** black — and this was measured on the
             * simulator rather than reasoned about. A `Color.black` that ignored
             * the safe area painted under the navigation bar as well, and the
             * inline title on it is drawn in the label colour: black on black,
             * so the screen came up with a back chevron and no name on it. The
             * black a letterboxed page needs belongs to `WatchStage`, which is
             * the only thing that should be wearing it.
             */
            Theme.background.ignoresSafeArea()

            VStack(spacing: 0) {
                if let notice {
                    Banner(text: notice, tone: .warning)
                        .accessibilityIdentifier("browser.watch.notice")
                }
                /*
                 * **The letterbox stays here, and that is the answer rather
                 * than a gap.**
                 *
                 * This screen is reached from Settings, with a `WatchLink` and
                 * nothing else — no model, no window list, and therefore no
                 * answer to *whose page is this* that would not be invented here.
                 *
                 * That was true of the surface it used to be pushed for as well,
                 * and for a harder reason: on a server the drive's own front slot
                 * is minted **no shell tab id** at all — it appears in
                 * `browser.surfaces` under the empty window name and in no
                 * `browser.window.rows` entry — and `browser.window.bind` is
                 * addressed by that id. That page is on `MachineWindowView` now,
                 * where the binding is offered and drawn dead with the reason
                 * rather than left out.
                 *
                 * Three things could have gone in the space and each is worse
                 * than black. A session **picker** would be a control that
                 * cannot act — there is nothing to bind. The **most recent**
                 * session would be a guess presented as a fact, on the one
                 * screen whose whole complaint was that it was a video with
                 * nothing real on it. A **line explaining the absence** is an
                 * apology, on a screen somebody opened to look at a page.
                 *
                 * So the page keeps the whole screen, full-bleed, which is also
                 * the only size at which a desktop page is a thing a fingertip
                 * can hit. The black is the shape of a wide page on a tall phone
                 * and nothing is pretending otherwise.
                 */
                WatchStage(watch: watch,
                           window: surface.window,
                           mounted: mounted)
                    .accessibilityIdentifier("browser.watch.stage")
            }
        }
        .navigationTitle(MachineBrowserText.surfaceLabel(surface))
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) { bar }
        .onAppear {
            chrome?.localhostPageIsOpen = true
            seed()
            /*
             * Ask for the strip again, because the address in it is stale the
             * moment the page navigates and **the host has no way to tell us**.
             *
             * `frontTab` in `src/main/screencast-host.ts` records the URL once,
             * at `opened()`, and thereafter answers with the drive's live
             * *origin* when the page has moved off the one it was opened at. So
             * a re-read gets `https://www.iana.org` for a page that is really at
             * `/help/example-domains`, and no read at all keeps showing the
             * address it was opened with. Neither is the page's URL.
             *
             * A read on arrival is what can honestly be done from here: it is the
             * moment the field is seeded, and it costs one small frame. The real
             * fix is on the host and is written down in this lane's report — the
             * front tab has to follow its page's navigations and publish
             * `surfacesChanged` when it does.
             */
            watch.read()
        }
        // Cleared on the way out rather than by whoever comes next, so a Back
        // from anywhere — the chevron, the edge swipe — restores the bar. The
        // keyboard goes with it: a canvas left as first responder behind a
        // dismissed screen is a keyboard nobody can put away.
        .onDisappear {
            chrome?.localhostPageIsOpen = false
            if typing { WatchStage.post(.endTyping, to: surface.window) }
        }
        .onChange(of: surface.url) { _, _ in seed() }
    }

    /**
     * The bar, with every verb in its place and the ones this page cannot be
     * asked for drawn dead.
     *
     * Back and Forward are `nil` and always will be: every history verb on the
     * wire — `browser.window.act` — is addressed by a window id, and
     * `src/main/remote/protocol.ts` refuses an empty one. What has changed is
     * that a `nil` here is now greyed rather than absent, because *"it should be
     * the same case, or all the options should be available at least"*.
     *
     * Reload is `web.open` with the address the surface itself reports, which on
     * the drive's front slot re-navigates the page that is already there — and it
     * is offered on that slot only, for the reason `canNavigate` gives.
     *
     * ## Most of this row is greyed, and two of them say their own line
     *
     * Four controls are dead here on a surface this screen can navigate, and all
     * five on one it cannot.
     *
     * `unavailable` is the fact about **the whole page** and it is the right
     * sentence for Back, Forward and — where there is nothing to send — Reload:
     * nothing on this bar can be addressed to a page the machine has not made a
     * window of, and one sentence covers all three at once.
     *
     * It is the wrong sentence for the other two, and Find and Inspect carry
     * their own — `BrowserChrome`'s defaults, which say the page is on the
     * machine rather than on this phone, a different fact and a truer one for
     * those two controls.
     *
     * ## There is no `…` on this screen at all, and no sentence about one
     *
     * There used to be a sixth slot in the row holding it, greyed, with a line
     * saying what a window's menu normally holds and why this page has none of
     * it. The `…` is a header control now (`BrowserWindowActions`), and it is
     * drawn only where it opens something — so on this screen it is simply not
     * there, and the line went with it.
     *
     * That is not the *"all the options should be available at least"* rule being
     * bent. That rule is about the **row**, which is what he counted: five under
     * a window, five under a page on the phone, five here, with the ones that
     * cannot act greyed in their places. A header with no trailing button is not
     * a gap in a row; it is a screen that has nothing to put there. This is the
     * surface viewer, reached from Settings, showing a page the machine is
     * casting without owning — there is no window to close, no recording to keep
     * and no settings screen behind it, because all three are addressed by a name
     * this page does not have.
     */
    private var bar: some View {
        BrowserPageBar(
            id: "browser.watch",
            address: $address,
            editing: $editing,
            typing: $typing,
            placeholder: "Address or search",
            go: canNavigate ? open : nil,
            back: nil,
            forward: nil,
            reload: canNavigate && !surface.url.isEmpty ? reload : nil,
            page: surface.window,
            unavailable: whyLimited,
            // Find and Inspect are deliberately left at `BrowserPageBar`'s
            // defaults. Those say the page is on the machine and there is nothing
            // on this phone to search or tap into, which is exactly the case
            // here — repeating them in this file would be two more copies of one
            // fact about one wire, and two more places for it to drift.
        )
    }

    /**
     * Work out what was typed and send it to the machine.
     *
     * The classification is `LocalhostAddress.classify` — the same pure function
     * the new-window sheet calls — so `google.com`, `https://…`, `3000` and
     * `what is my ip` all mean here exactly what they mean there. A phone that
     * sent the raw text and hoped would be a phone whose address bar works for
     * URLs and silently fails for everything else.
     */
    private func open(_ typed: String) {
        switch LocalhostAddress.classify(typed) {
        case let .tunnel(port, path):
            // A port typed on a screen showing the machine's own browser is a
            // page for that browser, at its own loopback — the same reading the
            // new-window sheet gives it, and for the same reason: the screen you
            // are on says where it opens.
            send("http://localhost:\(String(port))\(path)")
        case let .page(url):
            send(url)
        case let .search(_, url):
            send(url)
        case let .refused(why):
            notice = why
        }
    }

    private func reload() {
        guard !surface.url.isEmpty else { return }
        send(surface.url)
    }

    private func send(_ url: String) {
        notice = nil
        chrome?.openPageOnMachine(url)
    }

    /**
     * Fill the field from the page, unless somebody is using it.
     *
     * The guard is the whole function. Without it, a page that redirects — or a
     * single-page app that rewrites its own URL, which is most of what anybody
     * points this at — rewrites the field mid-word, and the address that gets
     * sent is half of what was typed with half of where the page went.
     */
    private func seed() {
        guard !editing else { return }
        guard !surface.url.isEmpty else { return }
        guard !seeded || surface.url != address else { return }
        address = surface.url
        seeded = true
    }
}
