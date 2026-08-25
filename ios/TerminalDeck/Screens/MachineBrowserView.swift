/**
 * **The Browser tab.** The windows open in the machine's browser, one row each,
 * and nothing else on the screen.
 *
 * ## What he objected to, and it was not any single control
 *
 * The tab had just been rebuilt so that the machine's own windows and this
 * phone's localhost tunnels shared one screen: an address bar at the top, a
 * strip of open tunnel tabs under it, six grouped sections of listening ports,
 * a segmented Shared/Isolated control, and a row leading to the windows. Every
 * one of those was argued for on its own. Together they were a dumping ground:
 *
 * > *"when I say something to add for the browser, it should not be like
 * > isolated and other things that you added in the browser page — things should
 * > not be mixed in the list of browsing windows. The home page of the browser
 * > should be for the open browser windows, and we should be able just to see
 * > only the open windows, and then we can just click on any of them. Even the
 * > localhost thing should be folded somewhere else… On the full page view it
 * > should be only about the open windows… And the home page is not for the
 * > multiple kinds of stuff — it should be smooth, simple."*
 *
 * So this screen draws **one kind of row**. A window. Tapping it opens the
 * window. There is no second kind of thing on it, no control that configures
 * something, and no card explaining anything.
 *
 * ## Where the rest of it went, and why each of them went there
 *
 *  - **Localhost** — the ports and the dev servers — is inside the `+`, as the
 *    addresses this machine is already serving. See below: it was a screen of
 *    its own for exactly one round and that was the second complaint.
 *  - **Opening a window** is the `+`, which raises `NewWindowSheet`. The
 *    address field and the Shared/Isolated picker were a card sitting at the top
 *    of this list, on screen at all times whether or not anybody was opening
 *    anything — *"isolated and other things that you added in the browser
 *    page"*. Isolation is a property of the window being made, so it is part of
 *    the act of making one and it is nowhere else on this screen. It is still
 *    convertible afterwards, on the window's own settings.
 *  - **Everything about one window** — its address, its page verbs, shared or
 *    isolated, its profile, which session owns it, the screenshot, the recorder
 *    — is inside the window: *"settings of per window, how to connect to it, how
 *    to make it shared or isolated, all of these things should be inside of the
 *    window."* See `MachineWindowView` and `MachineWindowSettingsView`.
 *  - **This phone's own browser chrome** — history, site data, saved logins — is
 *    on the `…`. All three are about pages loaded through a tunnel in this
 *    phone's web view; none of them is a page and none is a window, and a `…` is
 *    where a screen keeps the things that are neither. **Browser profiles** is
 *    beside them and is the machine's side of the same split: a profile is the
 *    Chromium partition the machine's windows run in.
 *
 * ## And then it was two pages, which was the next thing wrong with it
 *
 * The round after the one above put localhost behind the `…` as a screen of its
 * own — and that screen had an address bar, a strip of open tabs and a list of
 * ports, so the Browser tab became two browsers with a menu between them. He
 * read it:
 *
 * > *"now here you still kept localhost as a separate page inside the page, and
 * > the browser as a separate page in the page. So I wanted it to be like ONE
 * > page where I can start a new window."*
 *
 * So there is one page, and the question that settles what goes on it is *what
 * kind of thing is this*:
 *
 *  - **A port is an address.** `localhost:3000` is something you type into an
 *    address bar, so the ports are inside the `+`, under the field, as
 *    suggestions for it — `PortSuggestions`, whose header carries the argument
 *    and everything the old screen had that came with it.
 *  - **A page open on this phone is a window.** It used to live in a strip of
 *    tabs on that second screen, so somebody who had opened one had two places to
 *    look depending on which machine had drawn the pixels. It is a row on this
 *    list now, marked *On this phone*, and tapping it goes back to it.
 *  - **Everything else was a setting**, and settings are what a `…` is for.
 *
 * The `+` is the one place a window is started and it can start all three kinds:
 * a window on the machine, an isolated one, or a page here over a tunnel. The
 * destination is one control on that sheet, because *where does this open* is one
 * question.
 *
 * ## What is left on a row, and it is only what you do to a window from outside
 *
 * > *"from the outside we can just make it archive, close, or connect to any
 * > session, or things from three dots and all the relevant stuff."*
 *
 * Three verbs, and the `…` carries exactly those three. Watch and Screenshot
 * used to be here and are not: both are things you do *to the page*, and the
 * page is what opening the row gives you.
 *
 * The swipe carries the same set minus the one that needs a choice. Attaching
 * names a session, and a swipe action is a button with no room to ask — so the
 * gesture carries Detach, which is the half of the binding that needs no choice,
 * and the picker stays in the menu.
 *
 * ## Every row has that `…`, and on some of them most of it is greyed
 *
 * > *"Okay, this one is attached to this session. Maybe this is the difference,
 * > and this one is not attached to anyone. But **there is no way to attach this
 * > one too**. So it should be the same case, or all the options should be
 * > available at least."*
 *
 * Only a window row used to have a menu, because only a window row has an id and
 * every verb in the `browser.window.*` family is addressed by one — the codec
 * refuses an empty `id` on all five of them. That is still true and it is no
 * longer a reason to draw nothing: a row with no `…` beside a row with one says
 * *this page is second class* and does not say why. So the menu is on all three
 * kinds, the items that cannot be sent are drawn dead under one line naming the
 * reason, and the one verb in that set that is real — closing a page this phone
 * is holding, which is this phone's own socket — is live. See `rowMenu`.
 *
 * ## And then greying the attach was still not what he asked for
 *
 * > *"And these three dots, we should have this attachment thing for all of
 * > them, properly working, and the same way on the sessions side also."*
 *
 * A reason under a dead control is better than a control that is simply missing,
 * and it is not *working*. For the machine's own front tab there is nothing to
 * be done — the host refuses an empty window id at the parser, so the row stays
 * dead with its reason. For a page **this phone** is holding there was something
 * to be done, and it needed one field on the wire: `browser.window.open` now
 * carries a session, and the host binds the new window before it answers. So
 * that row's attach opens the same address in the machine's browser and hands
 * *that* window to the session, in one ask.
 *
 * The wording says so plainly, because it is not the page he is looking at: this
 * phone's own web view cannot be reached by an agent and never will be. See
 * `pageItems` and `attachOnMachine`.
 *
 * ## And there is no icon on any of them
 *
 * > *"why they have two different icons also sometimes, like in the left… **This
 * > should be just one browser icon only, browser one, or there should be no icon
 * > at all actually. It's not required. Everybody knows this is browser window,
 * > these are browsers.**"*
 *
 * Each row kind had a glyph and two of them changed under him: the surface row's
 * swapped between `macwindow` and a green broadcast while the page was being
 * cast, and the window row's went red while a recording was running. A glyph that
 * changes is making a claim, and every claim those were making is already made in
 * words by the marks under the title — `Live`, `Recording`, `On this phone`.
 * There is no icon column at all now, and no constant one either, because he gave
 * the reason as well as the instruction.
 *
 * ## The two capabilities are negotiated separately, so this list survives either
 *
 * `browser.control` (`MachineBrowserWire.capability`) and `watch`
 * (`WireCapability.watch`) are independent — `RemoteEndpointOptions` advertises
 * the first from `machineBrowser` and the second from `screencast`, two
 * different fields with two different absent-is-the-switch spreads, withheld on
 * two different grants — so all four combinations are real:
 *
 *  - **control and watch** — the ordinary shape of a machine of his own. The
 *    rows are the windows; a window the host also lists as a surface opens onto
 *    its own live picture.
 *  - **control, no watch** — the state every shipped build was in until this
 *    wave: the frames had been on the wire since wave 3 and neither shell passed
 *    a `screencast` engine. The rows are the windows, they open onto the
 *    window's controls, and nothing on this screen mentions a cast.
 *  - **watch, no control** — the rows are the surfaces, and they open the same
 *    window screen every other row opens, with everything that cannot be sent
 *    greyed and a reason on it. The `+` is **absent**, not disabled:
 *    `browser.window.open` is a `browser.control` verb and a field that could
 *    only ever be refused is not a control, it is a promise. So is the archive,
 *    and `WindowShelf`'s header says why.
 *  - **neither** — one line. This is a tab, so it cannot be hidden the way a row
 *    could; what it must not do is draw controls that would be refused.
 *
 * ## The two lists are joined on the window's own id, which is why they can be
 *
 * A surface is named by the **shell tab id** — the same string `MachineWindow.id`
 * carries and the same one `browser.window.go`, `.act`, `.bind` and `.shot` all
 * address — chosen in `screencast-host.ts` precisely so *"the two lists can be
 * joined without a second mapping"*. `B1`/`B2` could not have been it: a slot is
 * a name inside **one session**, and two sessions each holding two windows both
 * have a `B1`.
 *
 * Both directions of mismatch happen and both are drawn honestly:
 *
 *  - **A surface no window claims.** On a server, `''` is the drive's own tab —
 *    where a page opened from the localhost address bar lands. `openTab` mints
 *    it no shell id, so it is in no window list at all. It is a row of its own,
 *    first, because it is usually the page somebody just asked for.
 *  - **A window no surface claims.** A window opened from the `+` on a server
 *    holds no binding row, so `castWindows` cannot see it; it is drivable and
 *    not watchable, and `src/headless/host.ts` records that as the honest state
 *    rather than a row that refuses on the tap.
 *
 * A window on both lists appears once. That is what the shared id buys.
 *
 * ## Nothing here is optimistic
 *
 * Every verb answers with `browser.window.rows`. Bind a window and it comes back
 * carrying `B1`; close one and it is gone. No row is removed here and no badge
 * is drawn ahead of the machine agreeing to it — the same rule the six panels
 * follow. Archive is the one exception and it is not on the wire at all: it is
 * this phone's own list, so it takes effect immediately, which is what every
 * archive on this phone does.
 *
 * ## Why this is a `List` when the screens either side of it are `ScrollView`s
 *
 * Swipe actions. *"We can swipe them left and right and we can have options
 * there to delete or close… just like WhatsApp has the chats."* `.swipeActions`
 * exists only inside a `List`, and a hand-rolled drag is a swipe that is not the
 * system's — no rubber band at the limit, no interaction with the back gesture
 * at the left edge, a different depth from every other app on the phone. The
 * cards survive it: the row background is cleared and the fill comes from the
 * row's own rounded surface.
 */

import SwiftUI

struct MachineBrowserView: View {
    let model: DeckModel

    /// The windows this phone keeps off the list. Injected rather than reached
    /// for, the same shape `PortSuggestions` takes its `PortBook` and
    /// `SessionListView` its `SessionShelf`, so a test can hand in a store of
    /// its own.
    var shelf: WindowShelf = .shared

    /**
     * What is being pushed, as a value rather than as a `NavigationLink` in each
     * row.
     *
     * Two reasons, and the second decided it. A `NavigationLink` used as a
     * `List` row is given the system's own disclosure chevron, and these rows
     * already end in a `…` — a chevron *after* the menu glyph reads as a second
     * control rather than as an accessory. And a swipe action cannot be a link
     * at all, so anything that has to be reachable from both a tap and a
     * gesture needs one line of navigation both can call.
     */
    @State private var pushing: MachineBrowserDestination?

    /// Whether the sheet that opens a window is up. See `NewWindowSheet`.
    @State private var opening = false

    /**
     * The tunnel this phone is showing, and the page inside it.
     *
     * These three were the deleted localhost screen's and came here with the rest of
     * localhost, because a page loaded in this phone's own web view is one of
     * the windows this list is about — see the header. `browsing` holds the live
     * `PortTunnel`, and holding it in this view's state is what keeps the socket
     * alive for exactly as long as the page is up.
     *
     * `browsingPath` is beside it rather than on `PortTunnel`, because a tunnel
     * is a port and knows nothing about pages: the same tunnel serves every path
     * on that origin, and a second open at a different path on a port already
     * tunnelled would be one socket and two claims about what it was for.
     */
    @State private var browsing: PortTunnel?
    @State private var browsingPath = "/"
    /// Which tab the page on top belongs to, or nil while the list is showing.
    /// Held beside `browsing` rather than derived from it: a tunnel is shared by
    /// every tab on that port, so it cannot say which of them is open.
    @State private var currentTabID: String?

    /// Whether this phone's own browsing history is up. See `BrowserHistoryView`.
    @State private var showingHistory = false

    /**
     * What was just asked for, while the answer is on its way.
     *
     * Only ever set for the one verb on this screen that does **not** answer
     * with the window list: `web.open`. Everything else redraws the list and the
     * list is its own confirmation — *"nothing here is optimistic"* — but a page
     * opened in the machine's own browser produces `web.opened`, which
     * `HostLink` deliberately swallows (*"the confirmation is the machine"*),
     * and lands in a slot the surface list only reports when it is next asked.
     * So for a second or two there is a press with nothing on screen to show for
     * it, which is the definition of a control that reads as dead.
     */
    @State private var asked: String?

    /// The machine these windows belong to. Read every time rather than held:
    /// `DeckModel`'s own rule is that a screen must never keep a `HostLink`
    /// across a switch.
    private var host: HostLink? { model.current }

    private var state: MachineBrowserState? { host?.machineBrowser }

    /// What to call the machine in a sentence somebody reads. A name rather
    /// than "the machine", because somebody with two paired has to know which
    /// one is about to grow a window.
    private var machineName: String { model.current?.label ?? model.theMachine }

    /// Which machine's list this is. The archive is stored against it, so a
    /// phone paired with two does not hide one machine's window because of a
    /// swipe on the other.
    private var hostId: String { host?.id ?? "" }

    /// Whether this machine will let this phone drive its browser — open a
    /// window, navigate it, bind it, photograph it, record it.
    private var canDrive: Bool { host?.canDriveBrowser == true }

    /**
     * Whether it will cast one back.
     *
     * `WatchLink.offered` reads the welcome's capability set and nothing else,
     * so the connection is asked separately here — the same pairing
     * `HostLink.canDriveBrowser` makes in one expression. A capability from the
     * welcome of a socket that has since gone is a permission nobody can use.
     */
    private var canWatch: Bool { model.connection.isLive && host?.watch.offered == true }

    private var surfaces: [BrowserSurfaceRow] { canWatch ? (host?.watch.surfaces ?? []) : [] }

    /// The cast of one window, when the machine is offering one. An id match and
    /// nothing cleverer — see the header.
    private func surface(for window: MachineWindow) -> BrowserSurfaceRow? {
        surfaces.first { $0.window == window.id }
    }

    /// The machine's windows, minus the ones this phone has put away.
    private var windows: [MachineWindow] {
        shelf.split(state?.windows ?? [], host: hostId).listed
    }

    /// How many of the machine's current windows are archived, for the menu item
    /// that opens them. Measured against the live list rather than the store —
    /// see `WindowShelf.archivedCount`.
    private var archivedCount: Int {
        shelf.archivedCount(state?.windows ?? [], host: hostId)
    }

    /// The pages this phone is holding open in its own web view, over a tunnel
    /// to one of the machine's ports. Windows too — see the header — and the
    /// only ones on this list whose pixels are being drawn by this phone.
    private var phonePages: [BrowserTab] { model.browserTabs.tabs(on: model) }

    /**
     * The one list.
     *
     * Surfaces only, on a machine that offers no control — they are all there is
     * to list. Otherwise the windows, each carrying the machine's surface for it
     * when there is one, preceded by any surface **no window claims**: on a
     * server that is the drive's own tab, which is in no window list at all. A
     * window on both lists appears once, because both are keyed on the same id.
     *
     * The phone's own pages come last, because they are the ones that are not on
     * the machine, and last is where a list puts the thing that is a little to
     * one side of its subject.
     */
    private var rows: [MachineBrowserRow] {
        let mine = phonePages.map { MachineBrowserRow.page($0) }
        guard canDrive else { return surfaces.map { .surface($0) } + mine }
        let open = windows
        let claimed = Set(open.map(\.id))
        let unclaimed = surfaces.filter { !claimed.contains($0.window) }
        return unclaimed.map { .surface($0) } + open.map { .window($0, cast: surface(for: $0)) } + mine
    }

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()

            VStack(spacing: 0) {
                /*
                 * What the last verb did, in the machine's own words.
                 *
                 * Set by a verb and cleared by the next plain list, so it is
                 * gone by the time anybody comes back to this screen — which is
                 * why it is drawn from the frame rather than held in state here.
                 * It carries the outcomes the list cannot show by redrawing: a
                 * refused address, a window the machine would not open.
                 */
                if let asked {
                    Banner(text: asked, tone: .neutral)
                        .accessibilityIdentifier("browser.windows.asked")
                } else if let notice = state?.notice, !notice.isEmpty {
                    Banner(text: notice, tone: .neutral)
                        .accessibilityIdentifier("browser.windows.notice")
                }

                content
            }
        }
        // The tab's own name, and it stays the nav bar's identity even though
        // the principal item below draws the machine switcher over it.
        .navigationTitle("Browser")
        .navigationBarTitleDisplayMode(.inline)
        /*
         * **No identifier on the container.**
         *
         * An `accessibilityIdentifier` on a `ScrollView`, a `VStack` or a
         * `ZStack` makes that container an accessibility *element* and
         * everything inside it stops existing — measured on iOS 26.4 and written
         * down in `TabNavigation.swift`, where a text field plainly on screen
         * could not be found because the stack around it carried the screen's
         * name.
         */
        /*
         * Read on every appearance rather than once. Neither family pushes on
         * its own after the first answer, and what they answer moves for reasons
         * this phone never hears about — somebody at the machine opening a tab,
         * a session binding a window of its own. The held list is deliberately
         * not cleared first, so a re-read redraws under the rows already on
         * screen instead of blanking a list somebody is looking at.
         */
        .onAppear { read() }
        // A different machine is a different browser, and a different archive.
        .onChange(of: host?.id) { _, _ in read() }
        .toolbar { toolbar }
        /*
         * Presented from the screen rather than from inside the `.toolbar`
         * builder. That view is rebuilt whenever the machine pushes anything —
         * a `ports` frame, a session status — and a sheet bound to it is
         * dismissed out from under a thumb. The same rule the ports screen
         * follows for its rename alert.
         */
        .sheet(isPresented: $opening, onDismiss: read) {
            NewWindowSheet(model: model,
                           machine: model.current?.label ?? model.theMachine,
                           openThere: openWindow,
                           openHere: openHere)
        }
        /*
         * This phone's own browsing history. A sheet rather than a push, the way
         * it was on the localhost screen, and presented from here rather than
         * from inside the `.toolbar` builder for the same reason the one above
         * is: that view is rebuilt whenever the machine pushes anything.
         */
        .sheet(isPresented: $showingHistory) {
            BrowserHistoryView(host: hostId, machine: model.theMachine) { port, path in
                openHere(port, path)
            }
        }
        /*
         * A page on this phone, over a tunnel — a push, not a cover.
         *
         * *"it should not come like this up. It should just move like this when
         * we click on localhost page. It comes like this, which is a bit
         * different, feels like a browser opens inside. So give it a native
         * feel, not like this."* A `fullScreenCover` rises from the bottom edge
         * because that is what iOS does for a modal — something interrupting
         * you. A page on your own machine is where the tap was going.
         *
         * `item:` rather than a value on a path: the thing navigated to is a
         * live `PortTunnel` with a socket under it, and holding it in this
         * view's state is what keeps it alive for exactly as long as the screen
         * is up. Its `Hashable` conformance is identity — see `DeckChrome.swift`
         * — so the page is not torn down and rebuilt when the tunnel goes from
         * `opening` to `live`.
         */
        .navigationDestination(item: $browsing) { tunnel in
            LocalhostBrowser(model: model, tunnel: tunnel, path: browsingPath, tabID: currentTabID) {
                browsing = nil
                currentTabID = nil
            }
        }
        .onChange(of: browsing == nil) { _, dismissed in
            // Covers the back swipe and the back button as well as Done:
            // whichever way the page goes away, the port stops being reachable.
            // A gesture that left the tunnel open would leave the machine
            // serving to a phone that is no longer looking.
            if dismissed { model.closeLocalhost() }
            // And whichever way it goes, the tab bar comes back. The bar belongs
            // to the `TabView` rather than to this screen — see
            // `DeckModel.localhostPageIsOpen` for why that is a flag and not a
            // modifier on the page itself.
            model.localhostPageIsOpen = !dismissed
        }
        /*
         * **One destination, because he counted the kinds and there were two.**
         *
         * > *"this one is the one with the full view. But with the full view, at
         * > least it should have all the options… In iMatch, one of them has
         * > different menu options here in the bottom, the tab menu, and this one
         * > has different only reload, nothing else. So why they are two different
         * > type… it should be the same case, or all the options should be
         * > available at least."*
         *
         * A `.window` row pushed `MachineWindowView` — address, Back, Forward,
         * Reload, a `…` — and a `.surface` row pushed `WatchViewerScreen`, which
         * had a picture and one Reload. Both are pages in the same browser on the
         * same machine; what separated them was whether the host had minted a
         * shell tab id for the slot, which is not a thing anybody holding a phone
         * can see or should have to.
         *
         * So both push the same screen, and it holds the difference one control
         * at a time — the front tab's Back is greyed with the reason on it rather
         * than missing. `MachineWindowView` takes the surface's own name as its
         * id, `""` and all: that is what `browser.surfaces` calls the machine's
         * front tab, and the screen resolves both lists off it live.
         *
         * `WatchViewerScreen` is still the canvas mount for the Settings route,
         * which has a `WatchLink` and no model. Nothing here reaches it.
         *
         * ## The second case is not a second kind of browser window
         *
         * A page **this phone** is drawing has a screen already — it is the page
         * itself, one tap on the row. What it did not have is anywhere to keep
         * its settings, so the `…` reaches them here. It goes straight to the
         * settings rather than to a window screen because there is no address bar
         * and no Back to draw: the four page verbs belong to the web view, and
         * the web view is what the row opens. See `MachineWindowSettingsView`,
         * which draws that page's own shape.
         */
        .navigationDestination(item: $pushing) { destination in
            switch destination {
            case let .window(id):
                MachineWindowView(model: model, windowID: id)
            case let .phonePage(id):
                MachineWindowSettingsView(model: model, windowID: "", pushed: true, phoneTab: id)
            }
        }
    }

    /**
     * Both reads, together, because both feed the same list and a screen that
     * refreshed one of them would redraw half a list. Each guards itself on its
     * own capability, so this is a no-op on a machine offering neither.
     *
     * `watch.read()` rather than `ensureRead()`, and that is not a tidy-up.
     * `ensureRead`'s once-per-connection guard left this list frozen at whatever
     * the machine had when the *first* screen opened, so arriving here a second
     * time showed a stale strip — a page opened from the address bar, or a window
     * a session opened while the phone was elsewhere, was simply missing.
     *
     * The strip is also **pushed** now, by `RemoteEndpoint.surfacesChanged` off
     * the binding store on both shells, which is what makes the list live while
     * somebody is standing on it. This read is what makes it right on arrival:
     * a push only reaches a phone that was already connected when the window
     * moved, and the first frame of a screen cannot wait for the next change.
     */
    private func read() {
        host?.readMachineWindows()
        host?.watch.read()
    }

    /**
     * Open one, through the door that produces the thing the person asked for.
     *
     * > *"browsers should browse any normal Google or any web internet website
     * > also. But it will be actually browsing on the server side; here it will
     * > be presenting that."*
     *
     * ## Always `browser.window.open` — and why the old split is gone
     *
     * > *"there is no way to attach this one too. So it should be the same case,
     * > or all the options should be available at least. Now maybe I can
     * > directly connect from the session side. Let's try. But there is also no
     * > way to connect a browser window to this specific session."*
     *
     * This used to send a **shared** window through `web.open` instead, and the
     * reason written here was that a `browser.window.open` window was *"drivable,
     * and not watchable"* — `castWindows` in `src/headless/host.ts` could not see
     * it. **That stopped being true.** `castWindows` now folds
     * `machineBrowser.castable()` into the strip (`src/headless/host.ts`), and
     * `castable()` is derived from `list()` itself (`src/headless/machine-browser.ts`),
     * so every window this door mints is in `browser.surfaces` as well. Both
     * halves of his sentence are served by one verb now.
     *
     * What the old door cost him is the whole of the complaint above. `web.open`
     * lands the page in the drive's **own front slot**, which reports
     * `window: ""` — and an empty window id is refused by `browser.window.bind`,
     * `.act`, `.shot` and `.steps` in `src/main/remote/protocol.ts`. So a page
     * opened from `+` could be watched and driven and **nothing else**: it could
     * not be attached to a session, detached, closed or archived. That is exactly
     * the row he filmed beside one that could do all four, and asked why they
     * were two different things.
     *
     * So there is no split any more. Shared or isolated, a window opened here is
     * an ordinary window with an id, and everything that can be done to one of
     * them can be done to it.
     *
     * ## And why the list is re-read afterwards
     *
     * `web.open` answers `web.opened`, which `HostLink` deliberately swallows —
     * *"the confirmation is the machine"* — and the surface list has no
     * unsolicited push. So the row arrives on the next read, and there are three:
     * the sheet's own dismissal (`onDismiss: read`), one more when the sentence
     * this press puts on screen comes down (see `say`), and every later return to
     * this tab. The drive is asynchronous, which is why the sentence exists at
     * all: without it a press that worked perfectly has nothing on screen for a
     * second or two, and the honest fix is a `surfacesChanged` push on the host
     * rather than a fourth read here.
     */
    private func openWindow(_ url: String?, isolated: Bool) {
        host?.openMachineWindow(url: url, isolated: isolated)
        guard let url else { return }
        say("Opening \(shortened(url)) on \(model.current?.label ?? model.theMachine)")
    }

    /**
     * Open a page this phone is holding **on the machine**, and hand that window
     * to a session — one ask, one answer.
     *
     * > *"And these three dots, we should have this attachment thing for all of
     * > them, properly working."*
     *
     * ## Why this could not be done before, in one sentence
     *
     * `browser.window.open` answered with the window list and threw the new
     * window's own id away, so there was nothing to pass to
     * `browser.window.bind` afterwards — and a second ask would have had to
     * guess which of the rows that came back was the one it had just made. The
     * open carries the session now and the host binds before it answers, so the
     * row lands already wearing its slot.
     *
     * ## The address is rebuilt rather than remembered
     *
     * `http://localhost:<port><path>` off the tab's **current** values, because
     * a tab follows its page: somebody who opened `/` and clicked through to
     * `/admin` means `/admin`. `String(port)` and never the `Int` interpolated —
     * a port dropped straight into a Swift string is formatted with the locale's
     * grouping separator and comes out as `localhost:3,000`.
     *
     * ## And the sentence is careful on purpose
     *
     * Nothing about the page on this phone changes. A second window opens on the
     * machine at the same address, with the machine's cookies and the machine's
     * logins, and *that* is what the session gets. Saying "attached" without
     * saying which page would be the app claiming the phone's own web view had
     * been handed over, which is not a thing that can happen.
     *
     * The banner is a record of the **ask**, exactly as `openWindow`'s is, and
     * the machine's own answer replaces it — `browser.window.rows` comes back
     * carrying the bind notice, which is the confirmation that counts.
     */
    private func attachOnMachine(_ tab: BrowserTab, to session: String) {
        host?.openMachineWindow(url: "http://localhost:\(String(tab.port))\(tab.path)",
                                isolated: false,
                                session: session)
        say("Opening localhost:\(String(tab.port)) in \(machineName)'s browser and attaching that "
            + "window to the session. The page open here does not move.")
    }

    /**
     * Open one of the machine's ports **here** — in this phone's own web view,
     * over a tunnel.
     *
     * The third destination the new-window sheet offers, and the one that is not
     * a window on the machine at all. It is worth keeping and it was never worth
     * a screen of its own: the page loads on a real loopback origin, so it gets
     * cookies, a service worker and the WebSocket a dev server's hot reload runs
     * on — none of which a picture of somebody else's browser can give you.
     *
     * The tap *is* the consent: no sheet asking whether to allow it, because
     * nothing was reachable until now and closing the page makes it unreachable
     * again.
     *
     * Through the store rather than straight at `openLocalhost`, so the page
     * lands in a tab that this list can then draw. The store is what refuses a
     * thirteenth tab and what hands back the *existing* tab when this address is
     * already open — five taps on the port 3000 row are one page, not five.
     */
    private func openHere(_ port: Int, _ path: String) {
        guard let tab = model.browserTabs.open(port: port, path: path, machine: model) else { return }
        browsingPath = tab.path
        currentTabID = tab.id
        browsing = model.browserTabs.tunnel(for: tab)
    }

    /// Go back to a page this phone already has open. `resume` may have to
    /// re-open a tunnel the machine dropped while the page was parked, which is
    /// why it is not a plain `tunnel(for:)`.
    private func resume(_ tab: BrowserTab) {
        guard let live = model.browserTabs.resume(tab, machine: model) else { return }
        browsingPath = live.path
        currentTabID = live.id
        browsing = model.browserTabs.tunnel(for: live)
    }

    /// Close one. If it was the page on top, come back to the list — a pushed
    /// view over a tunnel that has just been torn down draws a dead page.
    private func closeTab(_ tab: BrowserTab) {
        let wasOpen = tab.id == currentTabID
        model.browserTabs.close(tab, machine: model)
        if wasOpen {
            currentTabID = nil
            browsing = nil
        }
    }

    /**
     * Hold a line on screen until the list can speak for itself.
     *
     * Two and a half seconds, the same as the toast on the localhost screen. It
     * exists because opening a page is asynchronous on the far side — the ask is
     * accepted long before Chromium has a document — so without a sentence the
     * press reads as dead.
     *
     * **It no longer re-reads at the end of it.** It used to, because
     * `browser.surfaces` documented itself as *"also pushed unsolicited when the
     * strip changes"* and nothing on the host sent that push, so a page opened
     * from this field was in the list only the next time the list was asked for.
     * `RemoteEndpoint.surfacesChanged` is that push, and both shells now fire it
     * off the binding store — so the row arrives on its own, usually before this
     * sentence has finished. A timed read on top of a push is a poll with extra
     * steps, and it would race the push to draw the same list twice.
     */
    private func say(_ line: String) {
        withAnimation { asked = line }
        Task {
            try? await Task.sleep(for: .seconds(2.5))
            withAnimation { asked = nil }
        }
    }

    /// The host and nothing else, because the banner is one line on a phone and
    /// a search URL is two hundred characters of query.
    private func shortened(_ url: String) -> String {
        URLComponents(string: url)?.host ?? url
    }

    // MARK: - The bar at the top

    /**
     * Two controls in one pill on the trailing edge, `+` then `…` inside it.
     *
     * > *"This plus button and three dots thing — which I said it will stay on
     * > left and three dot will be on right — what I meant is they should stay
     * > together like before, but like both will be on right side, one pill. But
     * > inside the pill, three dot will be on right side and plus button will be
     * > on left side. For inside the terminal page, and browser thing when we
     * > browse that, like in the page before we open."*
     *
     * The round before this read his earlier *"the plus button should be left
     * and three dots should be on the right side"* as the two **edges** of the
     * navigation bar and put the `+` on `.topBarLeading`. Left and right meant
     * left and right of each other, inside the capsule the pair had shared all
     * along, and the sentence above is him saying so. So both are back in one
     * `ToolbarItemGroup` at the trailing edge: a group is what iOS 26 draws as a
     * single piece of glass, and the split is what turned it into two.
     *
     * They stay two controls rather than folding the `+` into the menu because
     * they are not two of a kind. `PortSuggestions`' own history argues against two glyphs
     * eleven points apart in one corner and is right about the pair it has —
     * History and a site-data screen are both *somewhere else to go*. A `+` and a
     * `…` are the pair every list app on this phone ships: one is the screen's
     * single primary verb, the other is everything else.
     *
     * `SessionListView`'s toolbar is the same shape in the same order, and has
     * to be: he named the two screens in one breath both times he complained
     * about them, and the cost of the tabs disagreeing is paid by a thumb that
     * has already committed.
     */
    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        /*
         * The machine switcher, and the connection pill under it.
         *
         * *Which machine's windows are these* is exactly as open a question as
         * which machine's sessions, and with several paired it is not one this
         * screen may leave unanswered. It also carries the pill, so a list that
         * has gone stale says so here rather than only on the tab next door.
         */
        ToolbarItem(placement: .principal) {
            HostSwitcher(model: model, singleHostTitle: "Browser")
        }

        /*
         * The `+` is conditional and the group around it is not, which is the
         * way round it has to be: a group whose body resolves to nothing still
         * occupies the bar as an empty capsule, and the `…` below is drawn on
         * every machine, so the group always has something in it.
         *
         * Absent — not disabled — on a machine that offers only the cast:
         * `browser.window.open` is a `browser.control` verb, and a control that
         * could only ever be refused is one this app does not draw. A machine
         * that can only be watched therefore gets a pill with the `…` alone in
         * it, which is what the Sessions tab does with the same rule.
         */
        ToolbarItemGroup(placement: .topBarTrailing) {
            if canDrive {
                Button {
                    opening = true
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("Open a window")
                .accessibilityIdentifier("browser.new")
            }

            Menu {
                /*
                 * **This phone's own browser**, which is what these three are
                 * and all they are.
                 *
                 * There was a *Localhost* row here that pushed a whole second
                 * browser — its own address bar, its own tab strip, its own
                 * port list — and it is gone: *"you still kept localhost as a
                 * separate page inside the page… I wanted it to be like ONE page
                 * where I can start a new window."* The ports went into the
                 * new-window sheet, where an address is chosen; the pages this
                 * phone has open went into the list; and these three came back up
                 * here, which is where they were before that screen existed.
                 *
                 * All three are about pages this phone loaded **in its own web
                 * view over a tunnel**: its history of them, its web view's site
                 * data, its Keychain. None of them is a page and none of them is
                 * a window, so none of them is on the list — a `…` is where a
                 * screen keeps the things that are neither. The machine's own
                 * Chromium profiles are further down this same menu, and the
                 * split is deliberate: that is the partition the machine's
                 * windows run in, and these are this phone's.
                 */
                Button {
                    showingHistory = true
                } label: {
                    Label("History", systemImage: "clock.arrow.circlepath")
                }
                .accessibilityIdentifier("browser.history")

                NavigationLink {
                    BrowserDataView()
                } label: {
                    Label("Site data and zoom", systemImage: "slider.horizontal.3")
                }
                .accessibilityIdentifier("browser.data")

                /*
                 * One half of the split Asad drew: *"whatever cannot be linked,
                 * it can be only here also — like password saving — that can be
                 * native only for this application, for that server only
                 * specific."* A password this phone's own web view captured
                 * cannot be pushed into the machine's browser and should not be,
                 * so it lives in this phone's Keychain, keyed per machine.
                 */
                NavigationLink {
                    SavedLoginsView(host: hostId, machine: model.theMachine)
                } label: {
                    Label("Saved logins", systemImage: "key")
                }
                .accessibilityIdentifier("browser.logins")

                /*
                 * Where an archived window comes back from, and it is drawn even
                 * when the list behind it is empty — that screen's empty state is
                 * where somebody who has not found the gesture ends up, and it is
                 * the only place the gesture is named. `ArchivedSessionsView`
                 * makes the same argument about the same word.
                 *
                 * Only on a machine this phone can drive, because that is the
                 * only kind of row the archive applies to — see `WindowShelf`.
                 */
                if canDrive {
                    NavigationLink {
                        ArchivedWindowsView(model: model, shelf: shelf)
                    } label: {
                        Label(archivedCount == 0 ? "Archived" : "Archived (\(String(archivedCount)))",
                              systemImage: "archivebox")
                    }
                    .accessibilityIdentifier("browser.archived")
                }

                /*
                 * **The machine's** Chromium partitions — its cookies and what it
                 * is signed into — which is what every window on this list is
                 * running in. It stays on this screen while this phone's own
                 * history, site data and saved logins went with localhost: those
                 * three are about pages loaded in *this phone's* web view over a
                 * tunnel, and none of them is about a window on the machine.
                 *
                 * Negotiated under `browser.profiles`, which a host withholds on
                 * its own, so the row is absent rather than empty.
                 */
                if model.canUseMachineProfiles {
                    NavigationLink {
                        MachineProfilesView(model: model)
                    } label: {
                        Label("Browser profiles", systemImage: "person.2")
                    }
                    .accessibilityIdentifier("browser.profiles")
                }
            } label: {
                // Bare, for the reason `SessionListView` gives at the same
                // control: the capsule around the pair is the affordance on iOS
                // 26, the `+` sharing it is a bare glyph, and a ringed `…` beside
                // it reads as a badge stuck to the end of the pill rather than as
                // the second of two controls.
                Image(systemName: "ellipsis")
            }
            .accessibilityLabel("More")
            .accessibilityIdentifier("browser.more")
        }
    }

    // MARK: - What is on the screen

    @ViewBuilder
    private var content: some View {
        if !canDrive && !canWatch {
            unavailable
        } else if canDrive && state == nil {
            // Nothing yet. A spinner rather than an empty state, because *not
            // known* and *nothing there* are different answers and only one of
            // them is worth a sentence.
            ProgressView()
                .controlSize(.regular)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityIdentifier("browser.windows.loading")
        } else if rows.isEmpty {
            empty
        } else {
            list
        }
    }

    /**
     * Neither capability, and which of the two reasons it is.
     *
     * A machine that is simply not connected yet is not a machine refusing
     * anything, and the first frames of a launch are `.offline` then
     * `.connecting` — so a screen reading the socket directly opens on a warning
     * every single time. *"Let it give a few seconds; after five seconds if it
     * is still not connected, then show. Otherwise it will just load, so they
     * will not even feel that it takes time for connecting."*
     * `DeckModel.showsConnectionNotice` is the one property that rule lives in,
     * and the session list and the ports screen both read it, so all three
     * cannot drift.
     */
    @ViewBuilder
    private var unavailable: some View {
        if !model.connection.isLive && !model.showsConnectionNotice {
            ProgressView()
                .controlSize(.large)
                .tint(Theme.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityIdentifier("browser.windows.connecting")
        } else {
            ContentUnavailableView {
                Label(model.connection.isLive ? "No browser here" : model.connection.label,
                      systemImage: "macwindow")
            } description: {
                Text(model.connection.isLive
                     ? "\(model.current?.label ?? model.theMachine) is not offering its browser to "
                        + "this phone."
                     : model.connection.detail)
            } actions: {
                if !model.connection.isLive && !model.connection.isTrying {
                    Button("Try again") { model.resume() }
                        .buttonStyle(.borderedProminent)
                        .tint(Theme.accent)
                }
            }
            .accessibilityIdentifier("browser.windows.unavailable")
        }
    }

    /**
     * Nothing open, and the way in is the `+` that is on the bar above this.
     *
     * A full empty state rather than the one-line card this screen used to draw,
     * and it is the change that made the card unnecessary: the opener was a
     * permanent card at the top of the list, so an empty state under it would
     * have been an apology under a control. The `+` is in the bar now, always on
     * screen, so the space is free — and the action here is the same sheet, so
     * somebody who has not yet found the glyph is not stuck.
     */
    private var empty: some View {
        ContentUnavailableView {
            Label(canDrive ? "Nothing open" : "Nothing to watch", systemImage: "macwindow")
        } description: {
            Text(canDrive
                 ? "No window is open in \(model.theMachine)'s browser."
                 : "\(model.current?.label ?? model.theMachine) is not offering a window to watch.")
        } actions: {
            if canDrive {
                Button("Open a window") { opening = true }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.accent)
                    .accessibilityIdentifier("browser.windows.empty.open")
            }
        }
        .accessibilityIdentifier("browser.windows.empty")
    }

    private var list: some View {
        List {
            ForEach(rows) { row in
                rowView(row)
            }

            capped

            // Room for the pill that floats over this list. See `TabBarClearance`.
            TabBarClearance()
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .refreshable {
            read()
            // The pull gesture needs something to hold on to or it snaps back
            // before the answer arrives and reads as having done nothing. The
            // same 450ms the two lists next door wait.
            try? await Task.sleep(for: .milliseconds(450))
        }
    }

    /**
     * The cut, said out loud — *"a silent cut reads as that is all of them"*.
     *
     * From the count the machine sent rather than from landing on the cap.
     * `WireCodec.machineWindows` keeps `sent` for exactly this: inferring
     * truncation from `count >= maxWindows` over-reports by one frame in the
     * case where the machine has exactly forty, and says *the first 40* about a
     * list that is all of them.
     */
    @ViewBuilder
    private var capped: some View {
        if let notDrawn = state?.notDrawn, notDrawn > 0 {
            HStack(spacing: 6) {
                Text("\(String(notDrawn)) more not shown")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.faint)
                InfoDot(
                    about: "the window limit",
                    text: "This phone draws \(String(MachineBrowserWire.maxWindows)) windows. The "
                        + "machine may have more open, and every one of them still works at the "
                        + "machine itself.")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 12)
            .padding(.bottom, 4)
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 20))
            .accessibilityIdentifier("browser.windows.capped")
        }
    }

    // MARK: - One row

    @ViewBuilder
    private func rowView(_ row: MachineBrowserRow) -> some View {
        Group {
            switch row {
            case let .window(window, cast):
                windowRow(window, cast: cast, sessions: state?.sessions ?? [])
            case let .surface(surface):
                surfaceRow(surface)
            case let .page(tab):
                pageRow(tab)
            }
        }
        .plainRow()
        /*
         * **Trailing only, and the leading edge is deliberately empty.**
         *
         * The leading edge is where a row keeps a harmless verb, and this row no
         * longer has one: Watch and Screenshot were on it and both moved inside
         * the window, because both are things you do to the page rather than to
         * the window. Drawing something there to keep the gesture symmetrical
         * would mean inventing a verb, and the empty edge is the honest answer —
         * a drag that way rubber-bands, which is what iOS does for a row with no
         * leading action anywhere on the phone.
         *
         * `allowsFullSwipe: false`, and on this edge it is not a preference: a
         * full swipe fires the first action on release, and the first action
         * here closes somebody's browser window.
         */
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            trailingActions(row)
        }
    }

    /**
     * One window: the whole row opens it, and the trailing `…` does the rest
     * without opening it.
     *
     * Two sibling controls rather than one nested inside the other. A `Button`
     * inside another button's label is a hit-testing coin toss in SwiftUI, and
     * the coin here would decide between opening a window and closing it — the
     * same argument `MachineProfilesView` makes about its Clear, and the same
     * resolution: the row's own button takes everything the menu does not,
     * `contentShape` and all, so the row stays a row rather than a name-sized
     * target.
     *
     * ## There is no icon on it, and that is his sentence rather than a trim
     *
     * > *"why they have two different icons also sometimes, like in the left. If
     * > I go to Google, I come back, it shows different one. It will show the
     * > other one again. If I go to this one, now both are same. So they keep
     * > changing. **This should be just one browser icon only, browser one, or
     * > there should be no icon at all actually. It's not required. Everybody
     * > knows this is browser window, these are browsers.**"*
     *
     * There was a `macwindow` glyph here that went red while a recording was
     * running, and one on the surface row that swapped to a green broadcast glyph
     * while the page was being cast. He read the swap as the app being unable to
     * make up its mind about what the row *was* — which is fair, because a glyph
     * that changes is a glyph making a claim, and the claim it was making is one
     * the marks below the title already make in words. So the column is gone from
     * every row on this list, not replaced with a constant globe: a list of
     * browser windows does not need each line to say *browser window*.
     *
     * ## What a row says out loud
     *
     * Four facts, because each is a thing somebody can be wrong about while
     * moving quickly: which session owns it (the slot badge is the name that
     * session's tools call it by), whether it is isolated, whether **somebody is
     * watching it right now**, and **whether it is recording**. Two of those are
     * states a page can be left in without anybody meaning to, so they are marks
     * on the row rather than things you learn by opening it — and with the glyph
     * gone they are the only place either is said, which is what they were
     * already for.
     *
     * *Being watched* is `BrowserSurfaceRow.live` and never *there is a surface
     * for it*: on a desktop every pane is castable, so a mark drawn from
     * castability would sit on every row and distinguish nothing.
     */
    private func windowRow(_ window: MachineWindow, cast: BrowserSurfaceRow?,
                           sessions: [WindowSession]) -> some View {
        HStack(spacing: 0) {
            Button {
                pushing = .window(window.id)
            } label: {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(window.label)
                            .font(.system(size: 16))
                            .foregroundStyle(Theme.primary)
                            .lineLimit(1)
                        if !window.url.isEmpty && window.url != window.label {
                            Text(window.url)
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundStyle(Theme.faint)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        marks(window, streaming: cast?.live == true)
                    }
                    Spacer(minLength: 8)
                    if window.loading {
                        ProgressView().controlSize(.small)
                    }
                }
                .padding(.leading, 16)
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(MachineRowButtonStyle())
            // One sentence rather than the five `Text`s a stack of marks reads
            // by default: the marks only mean anything attached to the window
            // they are on.
            .accessibilityLabel(MachineBrowserText.spoken(window, streaming: cast?.live == true))
            .accessibilityHint("Opens this window")
            /*
             * `row`, not `window`, and the prefix matters.
             *
             * Every control on the window's own screens is named
             * `browser.machine.window.…`, so naming the rows the same way would
             * make a prefix query for "a window row" match a control on the
             * screen that row pushes. A test written against that passes on the
             * wrong screen.
             */
            .accessibilityIdentifier("browser.machine.row.\(window.id)")

            rowMenu(.window(window, cast: cast), sessions: sessions)
                // Four, so the `…` does not sit against the card's rounded
                // corner. The same inset the port rows give their trailing slot.
                .padding(.trailing, 4)
        }
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    /**
     * A page in the machine's browser that its window list does not name.
     *
     * Two of them exist. On a machine offering no `browser.control` at all,
     * every row is one. On a server, `''` is one even beside a full window list:
     * it is the drive's own tab — where a page opened from the localhost address
     * bar lands — and `openTab` mints it no shell id, so no `browser.window.rows`
     * entry names it.
     *
     * ## It is the same row as a window's now, and that is the whole point
     *
     * > *"In iMatch, one of them has different menu options here in the bottom,
     * > the tab menu, and this one has different only reload, nothing else. So why
     * > they are two different type… it should be the same case, or all the
     * > options should be available at least."*
     *
     * It had no `…`, on the argument that every verb behind that menu is
     * addressed by a window id and this row has none — *"a glyph opening a menu
     * with nothing in it is worse than no glyph."* The premise is still true and
     * the conclusion was wrong: what somebody reads off a row with no menu beside
     * a row with one is that the app can do less for this page than for that one
     * and will not say why. So the menu is here, with the same four items, and
     * the ones that cannot be sent are greyed under a line naming the reason. See
     * `rowMenu`.
     *
     * The glyph is gone with every other row's — *"there should be no icon at all
     * actually"* — and it is this row's glyph he was watching change: it was a
     * green broadcast when the page was being cast and a `macwindow` when it was
     * not. That fact is not lost with it. `Live` is a mark under the title, which
     * is where the window rows have always said it, and it is drawn from
     * `surface.live` exactly as the glyph was.
     *
     * The chevron goes for the reason the window rows never had one: a `…` and a
     * chevron eleven points apart read as two controls, and only one of them is.
     */
    private func surfaceRow(_ surface: BrowserSurfaceRow) -> some View {
        HStack(spacing: 0) {
            Button {
                pushing = .window(surface.window)
            } label: {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(MachineBrowserText.surfaceLabel(surface))
                            .font(.system(size: 16))
                            .foregroundStyle(Theme.primary)
                            .lineLimit(1)
                        if !surface.url.isEmpty {
                            Text(surface.url)
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundStyle(Theme.faint)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        if surface.live {
                            HStack(spacing: 6) {
                                MachineWindowMark(text: "Live", tone: Theme.positive)
                                Spacer(minLength: 0)
                            }
                            .padding(.top, 1)
                        }
                    }
                    Spacer(minLength: 8)
                }
                .padding(.leading, 16)
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(MachineRowButtonStyle())
            .accessibilityLabel(surface.live
                                ? "\(MachineBrowserText.surfaceLabel(surface)), being watched"
                                : MachineBrowserText.surfaceLabel(surface))
            .accessibilityHint("Opens this window")
            // `front` rather than the empty name it actually wears: an identifier
            // ending in a bare dot is one nobody reading a failure can tell from a
            // truncated string, and the front tab is the one surface whose name is
            // documented as empty rather than missing.
            .accessibilityIdentifier(surface.window.isEmpty
                                     ? "browser.machine.surface.front"
                                     : "browser.machine.surface.\(surface.window)")

            /*
             * No session list handed in, and that is the honest shape rather
             * than a saving. The rows would draw and the verb behind them would
             * be refused before it left this phone — see `rowMenu` — so a picker
             * here would be a choice that ends in nothing. One greyed line
             * saying the page has no id to bind is the whole truth.
             */
            rowMenu(.surface(surface), sessions: [])
                .padding(.trailing, 4)
        }
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    /**
     * A page **this phone** has open, over a tunnel to one of the machine's
     * ports.
     *
     * It is a window and it belongs on the list of windows, which is the whole of
     * *"ONE page where I can start a new window"*: a page opened on this phone
     * used to live in a strip of tabs on a second screen, so a person who had
     * opened one had two places to look for it depending on which machine had
     * drawn the pixels. Whose renderer it is is a *fact about* the window and it
     * is on the row — the mark says **On this phone** — rather than being a
     * reason to keep a second list.
     *
     * It has the same `…` as every other row, and most of what is on it is
     * **live** now. Attaching opens this same address in the machine's browser and
     * hands that window to the session — one ask, because `browser.window.open`
     * carries the session — and the menu says exactly that rather than implying
     * the page moved. Closing is real and is on the swipe as well. Its own
     * settings are a row on the menu, because a page this phone draws has no `…`
     * of its own to keep them behind. Archive is the one item still greyed, under
     * its own reason: the archive is this phone's list of the **machine's**
     * windows, and there is no entry here to hide. See `pageItems`.
     *
     * The `iphone` glyph went with every other row's icon: *"there should be no
     * icon at all actually. It's not required."* Whose renderer draws this page is
     * still on the row, as the **On this phone** mark, which is where it was
     * already said in words.
     */
    private func pageRow(_ tab: BrowserTab) -> some View {
        HStack(spacing: 0) {
            Button {
                resume(tab)
            } label: {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        // `label`, never `title`: a document has no title until
                        // it has loaded, and a row that said nothing for the
                        // first two seconds of every page would look broken.
                        Text(tab.label)
                            .font(.system(size: 16))
                            .foregroundStyle(Theme.primary)
                            .lineLimit(1)
                        Text("localhost:\(String(tab.port))\(tab.path == "/" ? "" : tab.path)")
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(Theme.faint)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        HStack(spacing: 6) {
                            MachineWindowMark(text: "On this phone", tone: Theme.secondary)
                            Spacer(minLength: 0)
                        }
                        .padding(.top, 1)
                    }
                    Spacer(minLength: 8)
                }
                .padding(.leading, 16)
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(MachineRowButtonStyle())
            .accessibilityLabel("\(tab.label), on this phone")
            .accessibilityHint("Opens this page again")
            .accessibilityIdentifier("browser.machine.page.\(tab.id)")

            /*
             * The machine's sessions, handed in where they used to be withheld.
             *
             * They were `[]` here because every verb behind this `…` was a
             * `browser.window.*` addressed by an id this page has not got, so a
             * picker would have been a choice ending in nothing. That stopped
             * being true of attaching: `browser.window.open` carries the session
             * now, so choosing one opens this same address on the machine and
             * binds *that* window in one move. See `pageItems`.
             */
            rowMenu(.page(tab), sessions: state?.sessions ?? [])
                .padding(.trailing, 4)
        }
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    /**
     * The facts a row cannot leave implicit.
     *
     * The slot first, because it is the name the bound session's own tools call
     * this window by — somebody reading an agent's transcript sees `B1`, and
     * this is the only place on the phone that says which window that is.
     */
    @ViewBuilder
    private func marks(_ window: MachineWindow, streaming: Bool) -> some View {
        if window.isBound || window.isolated || window.recording || streaming {
            HStack(spacing: 6) {
                if let slot = window.slot {
                    MachineWindowMark(text: slot, tone: Theme.accent)
                    if let owner = MachineBrowserText.owner(window) {
                        Text(owner)
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.secondary)
                            .lineLimit(1)
                    }
                }
                if streaming {
                    MachineWindowMark(text: "Live", tone: Theme.positive)
                }
                if window.isolated {
                    MachineWindowMark(text: "Isolated", tone: Theme.secondary)
                }
                if window.recording {
                    MachineWindowMark(text: "Recording", tone: Theme.critical)
                }
                Spacer(minLength: 0)
            }
            .padding(.top, 1)
        }
    }

    /**
     * What you do to a window **without opening it**, on every row of this list.
     *
     * > *"from the outside we can just make it archive, close, or connect to any
     * > session."*
     *
     * Watch and Screenshot were on this menu and are gone: both act on the page,
     * and the page is what a tap on the row gives you. What is left is the set
     * that makes sense with the window still shut, which is the same set the
     * swipe carries — minus attaching, which needs a *choice* of session and a
     * swipe action is a button with nowhere to ask.
     *
     * ## One function, because two rows on the same list with different menus is
     * what he read as two products
     *
     * > *"Okay, this one is attached to this session. Maybe this is the
     * > difference, and this one is not attached to anyone. But **there is no way
     * > to attach this one too**. So it should be the same case, or all the
     * > options should be available at least."*
     *
     * Only a `.window` row had a menu. The other two carry no window id — the
     * machine's own front tab is minted none, and a page this phone is holding
     * over a tunnel is not in that browser at all — and every verb here is
     * addressed by one: `src/main/remote/protocol.ts` refuses an empty `id` on
     * `browser.window.bind`, `.act`, `.go`, `.shot` and `.steps` alike, and
     * `WindowShelf.setArchived` refuses one too. So the old rule was *no id, no
     * menu*.
     *
     * The rule now is that the menu is the same on every row and an item that
     * cannot be sent is **greyed under a line saying why**, so the answer to *why
     * can I do this to that one and not to this one* is on the screen instead of
     * being something you work out by comparing two rows.
     *
     * ## And then greying it was not enough either
     *
     * > *"we should have this attachment thing for all of them, **properly
     * > working**."*
     *
     * A reason under a dead control is honest and it is still a dead control. So
     * one of the two greyed rows stopped being one: `browser.window.open` carries
     * a session now, and a page this phone is holding can be opened on the
     * machine and bound in a single ask. The machine's own front tab cannot —
     * there is no address to re-open and no id to bind — so that row keeps its
     * reason. See `pageItems` and `surfaceItems`, which is why the three shapes
     * are three builders under one `Menu` rather than one branch with an `else`.
     *
     * Closing a page this phone holds was already real — it is this phone's own
     * socket — and is drawn live, where the destructive item goes.
     *
     * The session rows carry how many windows that session already holds,
     * because that is what decides whether the new binding is called `B1` or
     * `B4`.
     *
     * Destructive last, which is where iOS puts it in a menu, and the reverse of
     * the swipe's order — a swipe reads outward from the screen edge and a menu
     * reads down the list, so the two agree about which verb is furthest from an
     * accident.
     */
    @ViewBuilder
    private func rowMenu(_ row: MachineBrowserRow, sessions: [WindowSession]) -> some View {
        Menu {
            switch row {
            case let .window(window, _):
                windowItems(window, sessions: sessions)
            case let .surface(surface):
                surfaceItems(surface)
            case let .page(tab):
                pageItems(tab, sessions: sessions)
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.faint)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .accessibilityLabel("Actions for \(rowName(row))")
        .accessibilityIdentifier("browser.machine.more.\(menuName(row))")
    }

    /**
     * A window on the machine. Every verb here is real and every one of them is
     * addressed by the window's own id.
     */
    @ViewBuilder
    private func windowItems(_ window: MachineWindow, sessions: [WindowSession]) -> some View {
        // Absent, not empty, when the machine has no sessions: a heading over
        // nothing is a section that exists to look furnished, and every row
        // under it would be a control that cannot act.
        if !sessions.isEmpty {
            Section("Attach to a session") {
                ForEach(sessions) { session in
                    Button {
                        host?.bindMachineWindow(window.id, to: session.id)
                    } label: {
                        Label(MachineBrowserText.sessionRow(session),
                              systemImage: session.id == window.session
                                  ? "checkmark" : "terminal")
                    }
                }
            }
        }

        if window.isBound {
            Button {
                host?.bindMachineWindow(window.id, to: nil)
            } label: {
                Label("Detach", systemImage: "minus.circle")
            }
        }

        Button {
            shelf.setArchived(true, host: hostId, window: window.id)
        } label: {
            Label("Archive", systemImage: "archivebox")
        }

        Button(role: .destructive) {
            host?.actOnMachineWindow(window.id, .close)
        } label: {
            Label("Close window", systemImage: "xmark")
        }
    }

    /**
     * A page in the machine's browser its window list does not name, and the one
     * row on this list where **nothing** can be sent.
     *
     * The machine's own front tab wears `''` as its name and the host's parser
     * refuses an empty `id` on every member of the `browser.window.*` family —
     * `bind`, `act`, `go`, `shot`, `steps` — so there is no verb to make live
     * here and no honest way to invent one. Every item is greyed under the one
     * line that says why. This is the row the page rows below **stopped** being.
     */
    @ViewBuilder
    private func surfaceItems(_ surface: BrowserSurfaceRow) -> some View {
        Section(whyNoWindowVerbs(surface)) {
            deadItem("Attach to a session", "terminal")
            deadItem("Archive", "archivebox")
            deadItem("Close window", "xmark")
        }
    }

    /**
     * A page **this phone** is drawing, over a tunnel — and attaching it is now
     * a real thing to press.
     *
     * > *"And these three dots, we should have this attachment thing for all of
     * > them, properly working, and the same way on the sessions side also."*
     *
     * ## What the greyed row used to say, and why the reason was the wrong one
     *
     * This row's *Attach to a session* was dead under the line *"Open on this
     * phone, not in the machine's browser"*. That sentence is true and it was
     * being used as an excuse: it explains why **this** page cannot be bound and
     * says nothing about the thing he actually wants, which is an agent driving
     * the page he is looking at.
     *
     * `browser.window.open` can carry a session now. So the row opens the same
     * address in the machine's browser and binds that new window in **one** ask —
     * which is the move that was impossible before, because the old open threw
     * the new window's id away and there was nothing left to bind.
     *
     * ## And the wording says what really happens, because it is not the same page
     *
     * The phone's own web view is not reachable by an agent and never will be:
     * the page is rendered here, its cookies are this app's, and its service
     * worker is this app's. What gets attached is a **new window on the
     * machine**, at the same address, with the machine's cookies — it may not
     * even be signed in the same way. So the section is named for what it does
     * rather than for what it would be nice if it did, and the banner the press
     * puts up says the page here does not move. A sentence implying otherwise
     * would be the same defect in a different place.
     *
     * ## Archive stays greyed, and it is a different fact
     *
     * The archive is this phone's list of the **machine's** windows — see
     * `WindowShelf`, which refuses an empty id and keys everything by the shell
     * tab id the machine minted. A page this phone is holding has no entry to
     * hide, and closing it is free and one tap. That is its own reason and it
     * gets its own line rather than being folded under the attach one.
     */
    @ViewBuilder
    private func pageItems(_ tab: BrowserTab, sessions: [WindowSession]) -> some View {
        if canDrive && !sessions.isEmpty {
            Section("Open on \(machineName) and attach") {
                ForEach(sessions) { session in
                    Button {
                        attachOnMachine(tab, to: session.id)
                    } label: {
                        Label(MachineBrowserText.sessionRow(session), systemImage: "terminal")
                    }
                }
            }
        } else {
            Section(whyNoAttach) {
                deadItem("Attach to a session", "terminal")
            }
        }

        Button {
            pushing = .phonePage(tab.id)
        } label: {
            Label("Page settings", systemImage: "slider.horizontal.3")
        }

        Section("Archiving is for the machine's own windows") {
            deadItem("Archive", "archivebox")
        }

        Button(role: .destructive) {
            closeTab(tab)
        } label: {
            Label("Close window", systemImage: "xmark")
        }
    }

    /// Why a page this phone is holding cannot be opened on the machine and
    /// attached, when it cannot. Two different facts, and only one of them is
    /// something he can do anything about.
    private var whyNoAttach: String {
        canDrive
            ? "Nothing is running on \(machineName) to attach it to"
            : "\(machineName) is not offering its browser to this phone"
    }

    /**
     * An item in its place, greyed, with the reason above it in the section's own
     * header.
     *
     * The reason is on the section rather than on each item because it is one
     * fact about the row — *this page is not a window on the machine* — and three
     * copies of it would be three places for it to drift, as well as three lines
     * of grey text in a menu meant to be read at a glance.
     */
    private func deadItem(_ title: String, _ icon: String) -> some View {
        Button {} label: {
            Label(title, systemImage: icon)
        }
        .disabled(true)
    }

    /**
     * Why a cast the window list does not name can carry no window verb, in one
     * line.
     *
     * Two answers and each is a different fact, so neither is a general apology:
     * the machine's own tab was never given an id, and a cast no window row
     * claims cannot be joined to a window.
     *
     * It takes a surface rather than a row now. It used to answer for a page on
     * this phone as well, and that third answer is gone with the greyed row it
     * was written under: attaching one of those is a live control, and the one
     * item still dead on it — Archive — has a reason of its own that has nothing
     * to do with window ids. See `pageItems`.
     */
    private func whyNoWindowVerbs(_ surface: BrowserSurfaceRow) -> String {
        // The second is worded off **this list** rather than off the machine's,
        // because a window archived on this phone is one the machine still lists
        // and this screen deliberately does not. Either way the join a window
        // verb needs is not here.
        surface.window.isEmpty
            ? "The machine's own tab — it has no window id to address"
            : "No window row for this page on this list"
    }

    /// What the `…` is *for*, spoken. The row's own name, which is the only thing
    /// that tells two of these apart when they are read one after another.
    private func rowName(_ row: MachineBrowserRow) -> String {
        switch row {
        case let .window(window, _): return window.label
        case let .surface(surface): return MachineBrowserText.surfaceLabel(surface)
        case let .page(tab): return tab.label
        }
    }

    /// The identifier's tail. `front` for the machine's own tab, for the reason
    /// its row gives: an identifier ending in a bare dot is one nobody reading a
    /// failure can tell from a truncated string.
    private func menuName(_ row: MachineBrowserRow) -> String {
        switch row {
        case let .window(window, _): return window.id
        case let .surface(surface): return surface.window.isEmpty ? "front" : surface.window
        case let .page(tab): return "page.\(tab.id)"
        }
    }

    // MARK: - The swipe

    /**
     * Close, Archive, Detach — destructive first, reading outward from the
     * screen edge.
     *
     * The platform's own order, and also the order of how much each one costs to
     * get wrong: Close ends a window on somebody's machine, Detach takes a
     * session's access away from one, and Archive changes nothing but this
     * phone's list.
     *
     * Close and Archive are in the same positions and the same tints the session
     * list uses, deliberately. That gesture is learned once and used on every
     * list in the app, and a swipe that put Archive in a different slot on a
     * different list is one people stop trusting — `ArchivedSessionsView` makes
     * the same argument about the edge its own undo sits on.
     *
     * Close is tinted explicitly and that took a screenshot to learn:
     * `role: .destructive` on a swipe button is red *by default* and only by
     * default, so under an ambient `.tint` the one action that ends something
     * comes out wearing the app's ordinary accent while the reversible one
     * beside it is orange. Nothing in a build log says so.
     */
    @ViewBuilder
    private func trailingActions(_ row: MachineBrowserRow) -> some View {
        if case let .window(window, _) = row {
            Button(role: .destructive) {
                host?.actOnMachineWindow(window.id, .close)
            } label: {
                Label("Close", systemImage: "xmark.circle.fill")
            }
            .tint(Theme.critical)
            .accessibilityLabel("Close \(window.label)")
            .accessibilityIdentifier("browser.machine.swipe.close.\(window.id)")

            Button {
                shelf.setArchived(true, host: hostId, window: window.id)
            } label: {
                Label("Archive", systemImage: "archivebox.fill")
            }
            .tint(Theme.warning)
            .accessibilityLabel("Archive \(window.label)")
            .accessibilityHint("Takes the row off this list. The window stays open on the machine.")
            .accessibilityIdentifier("browser.machine.swipe.archive.\(window.id)")

            if window.isBound {
                Button {
                    host?.bindMachineWindow(window.id, to: nil)
                } label: {
                    Label("Detach", systemImage: "minus.circle")
                }
                .tint(Theme.neutralAction)
                .accessibilityLabel("Detach \(window.label) from its session")
                .accessibilityIdentifier("browser.machine.swipe.detach.\(window.id)")
            }
        }

        /*
         * A page this phone is holding. Close is the only verb it has and it is
         * in the same slot, with the same tint, as Close on a machine's window —
         * the gesture is learned once and used on every row of this list, and the
         * two mean the same thing from where a thumb is standing even though one
         * ends a window on a computer in another room and the other closes a
         * socket this phone opened.
         *
         * No Archive: the archive is this phone's own list of the *machine's*
         * windows, and closing a page it opened itself is free and reversible in
         * one tap from the sheet.
         */
        if case let .page(tab) = row {
            Button(role: .destructive) {
                closeTab(tab)
            } label: {
                Label("Close", systemImage: "xmark.circle.fill")
            }
            .tint(Theme.critical)
            .accessibilityLabel("Close \(tab.label)")
            .accessibilityIdentifier("browser.machine.swipe.closePage.\(tab.id)")
        }
    }
}

/* -------------------------------------------------------------------------- */
/* Opening one                                                                 */
/* -------------------------------------------------------------------------- */

/**
 * Start a window: where it should go, whose renderer draws it, and whose cookies
 * it gets.
 *
 * ## This is the one page, and that is what he asked for
 *
 * > *"now here you still kept localhost as a separate page inside the page, and
 * > the browser as a separate page in the page. So I wanted it to be like ONE
 * > page where I can start a new window."*
 *
 * The Browser tab was two browsers. The home listed the machine's windows and
 * had a `+`; one row down the `…` was a second screen with its own address bar,
 * its own strip of open tabs and a long list of the machine's ports. Two address
 * bars, two lists, two ideas of what a window is — and a menu between them.
 *
 * There is one now. The home is the windows — the machine's, and the ones this
 * phone is holding over a tunnel — and **this** is where a new one is started.
 * The ports are in it, as what they are: the addresses this machine is already
 * serving. `PortSuggestions` carries them and its header carries the argument.
 *
 * ## Three destinations, chosen first, because it is the question the rest hangs on
 *
 * *Where does this window open* has three real answers on a machine that offers
 * everything, and they were previously spread across two screens and a swipe
 * action:
 *
 *  - **Machine** — the machine's own browser, in its own profile, with its
 *    cookies and whatever it is signed into. Watchable and drivable from the
 *    phone.
 *  - **Isolated** — the machine's browser with a partition of its own, thrown
 *    away when the window closes. A login typed into a window that turned out to
 *    be shared is already in the machine's cookie jar by the time anybody thinks
 *    to convert it, so the choice has to exist before the window does. It is
 *    still convertible afterwards, on the window's own settings.
 *  - **This phone** — a tunnel, and the page loads in this phone's own web view
 *    on a real loopback origin, so it gets cookies, a service worker and the
 *    WebSocket a dev server's hot reload runs on. Only the machine's own ports
 *    can be reached this way, which is a fact about what a tunnel is rather than
 *    a restriction chosen here.
 *
 * A destination is **absent**, not disabled, where the machine withholds the
 * capability it rides: no `ports` frame means no tunnel, and no `web` means the
 * machine cannot be sent a page at all. A control that could only ever be
 * refused is one this app does not draw.
 *
 * They were three segments of a `.segmented` Picker sitting inside the address
 * card, under the field and directly above the list of the machine's web
 * servers, and he read exactly what that placement said:
 *
 * > *"when we start a new session, this feels like a filter, not like a
 * > selection of this specific one. Maybe it could be like a different kind of
 * > choice, maybe up there, not under the bar or something."*
 *
 * They are a card of their own above the field now, one row each with a line
 * saying what that choice means. See `destination` for the whole argument,
 * including why each row has to stay a plain one-tap Button.
 *
 * ## Which door a machine window goes through, and it is not a detail
 *
 * Two verbs can put a page in the machine's browser and the difference was
 * measured in the host's own source. `MachineBrowserView.openWindow` holds that
 * argument; what matters here is that this sheet hands it a URL and an isolation
 * flag and lets it choose.
 *
 * ## The profile is deliberately not offered
 *
 * `browser.window.open` takes one and this sheet never sends it. Which profile
 * the machine's browser is using is `MachineProfilesView`'s question, it is
 * negotiated under a **different** capability — `browser.profiles`, which a host
 * can withhold on its own — and a picker here would be a control that is empty
 * or absent for reasons nothing on this sheet could explain. The window opens in
 * whichever profile the machine is on, which is what somebody standing at that
 * machine would get.
 *
 * ## And the field takes an address **or a search**, because a browser does
 *
 * > *"browsers should browse any normal Google or any web internet website
 * > also… So it should work seamless for everything."*
 *
 * `google.com`, `https://news.ycombinator.com`, `localhost:3000/admin` and
 * `what is my ip` are four different things and none of them needs a mode
 * chosen. `LocalhostAddress.classify` decides which, once, as a tested pure
 * function — the same one the two address bars under a live page call, so no
 * field in this app can come to a different conclusion about what `google.com`
 * means.
 *
 * A line this app will not open — a `file:` URL, a port out of range, a site
 * asked for on a phone that can only tunnel — is a sentence **under the field**,
 * and the sheet stays up. Dismissing on a refusal would throw away what was
 * typed to punish a typo, and dismissing silently would be a press that reported
 * success for nothing.
 */
private struct NewWindowSheet: View {
    let model: DeckModel
    /// What to call the machine in the sentences on this sheet. A name rather
    /// than "the machine", because somebody with two paired needs to know which
    /// one is about to grow a window.
    let machine: String
    /// Open it over there: the resolved URL and the isolation choice. Nil is a
    /// real choice — a blank window on the machine — which is why Open is never
    /// disabled.
    let openThere: (String?, Bool) -> Void
    /// Open it here, in this phone's own web view: a port on the machine and the
    /// path to ask it for.
    let openHere: (Int, String) -> Void

    /// Where a window opens. See the header.
    private enum Place: Hashable { case machine, isolated, phone }

    @State private var address = ""
    @State private var place: Place = .machine
    /// Why the last press did not open anything, or nil. Drawn under the field,
    /// which is the only place it is shown.
    @State private var notice: String?
    /// A copy happened, and copying is silent by nature.
    @State private var toast: String?
    /**
     * The rename alert, as two plain properties rather than one optional.
     *
     * The same shape — and the same reason — as `DeckModel.renamingHost`. A
     * computed `Binding(get: { target != nil }, set: …)` is dismissed within a
     * second of appearing, because every paired machine holds a socket and the
     * model publishes constantly: each rebuild runs that setter and nils the
     * value out from under the presentation. A real `@State` Bool has nothing to
     * run.
     *
     * It is presented from the **sheet** rather than from a row inside the
     * suggestion list, for the same reason: an alert attached inside a `ForEach`
     * that redraws on every `ports` frame is an alert that closes itself.
     */
    @State private var renaming = false
    @State private var renamePort: Int?
    @State private var renameText = ""

    @FocusState private var typing: Bool

    @Environment(\.dismiss) private var dismiss

    private var book: PortBook { .shared }
    private var hostId: String { model.current?.id ?? "" }

    /// Whether this phone can be handed one of the machine's ports at all.
    private var canTunnel: Bool { model.canBrowseLocalhost }
    /// Whether the machine will take a page. Both doors need it in one direction
    /// or another: `web.open` is gated on it, and `browser.window.open` on
    /// `browser.control`, which the tab already checked before drawing the `+`.
    private var canOpenThere: Bool { model.canOpenPages || model.current?.canDriveBrowser == true }

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.background.ignoresSafeArea()

                VStack(alignment: .leading, spacing: 0) {
                    header
                    suggestions
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
                            .accessibilityIdentifier("browser.open.toast")
                            .accessibilityAddTraits(.updatesFrequently)
                    }
                    .transition(.opacity)
                    .allowsHitTesting(false)
                }
            }
            .navigationTitle("New window")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                        .accessibilityIdentifier("browser.open.cancel")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Open") { go() }
                        .fontWeight(.semibold)
                        .accessibilityIdentifier("browser.open.go")
                }
            }
            // The keyboard, without a tap. This sheet exists to be typed into
            // and it is raised by a press that already said so.
            .onAppear { typing = true }
            .alert("Name this port", isPresented: $renaming) {
                TextField("Name", text: $renameText)
                    .accessibilityIdentifier("port.rename.field")
                Button("Save") { commitRename() }
                    .accessibilityIdentifier("port.rename.save")
                Button("Cancel", role: .cancel) { renamePort = nil }
            } message: {
                Text(renameMessage)
            }
        }
    }

    // MARK: - Where it opens, then what to open

    /**
     * The destination first, the address under it.
     *
     * That order is the correction. *Where does this go* is the question the
     * sheet has to settle before anything typed into the field means anything —
     * a port opens on the machine or over a tunnel depending on it, and a search
     * cannot go through a tunnel at all — so it reads first and it is answered
     * first.
     */
    private var header: some View {
        VStack(alignment: .leading, spacing: 0) {
            destination
            addressCard
        }
        .padding(.horizontal, 16)
        .padding(.top, 4)
    }

    /**
     * **Where the window opens, as a choice of three things rather than as a
     * filter over the list below.**
     *
     * > *"when we start a new session, this feels like a filter, not like a
     * > selection of this specific one. Maybe it could be like a different kind
     * > of choice, maybe up there, not under the bar or something."*
     *
     * He was reading a `.segmented` Picker that sat **inside** the address card,
     * under the field, under a hairline, directly on top of a list of the
     * machine's web servers. Every part of that placement said *filter*: a
     * segmented control is the shape iOS uses for scoping a list, it was
     * touching the list it appeared to scope, and the three words on it —
     * Machine, Isolated, This phone — read as three kinds of port to show. It was
     * not a filter. It was the single most consequential choice on the sheet: it
     * decides whose cookies the page gets and which machine renders it.
     *
     * So it is a card of its own, above the field, with a caption naming what is
     * being chosen and one line under each option saying what that choice means.
     * Three rows, one tap each, the selected one obvious. It is the same shape
     * `TerminalThemeView` uses to choose a colour scheme, which is this app's
     * pattern for *pick exactly one of these, and here is what each one is*.
     *
     * ## Each row is a plain Button, and that is load-bearing rather than a style
     *
     * `TabNavigation.openLocalhostList` taps `buttons["This phone"]` and
     * `SessionPageUITests` taps `buttons["Isolated"]`, both with **no** second
     * tap, and both checks were soft. Built as a `Menu`, the first tap would open
     * a menu instead of choosing, nothing would fail, and fifteen suites later
     * windows would quietly be opening in his **real** Chromium profile instead
     * of a throwaway one. So each destination stays a one-tap `Button` carrying
     * exactly the label those suites press, the selected one wears
     * `.isSelected`, and both helpers now assert that the selection landed.
     *
     * ## The identifier is on the card, and the card has to say it contains things
     *
     * `.accessibilityIdentifier` on a container makes that container an
     * accessibility *element* and everything inside it stops existing — measured
     * on iOS 26.4 and written down in `TabNavigation.swift`. The three rows must
     * stay findable, so the card is marked `.accessibilityElement(children:
     * .contain)` as well. `browser.open.isolation` is kept as the name: it is
     * the same choice it always was, and a renamed identifier is a suite that
     * skips instead of failing.
     *
     * ## Absent, not disabled — and absent altogether where there is one option
     *
     * A destination the machine will not serve is not drawn: no `ports` frame
     * means no tunnel, and no `web` means the machine cannot be sent a page at
     * all. `places.count > 1` is the gate on the card itself — a control with one
     * option is not a control, it is a label — and where there is only one, that
     * destination is stated as the line it would have carried, so the sheet never
     * goes silent about where the window is going.
     */
    @ViewBuilder
    private var destination: some View {
        if places.count > 1 {
            SchemeSectionCaption(
                "Open in",
                about: "where a window opens",
                info: "A window on \(machine) uses its own profile — its cookies and whatever it "
                    + "is signed into. An isolated one gets a partition of its own, and that "
                    + "partition is thrown away when the window closes. A window on this phone is "
                    + "a tunnel: the page loads here, in this app's own web view, on a real "
                    + "loopback origin — so it keeps cookies and a dev server's hot reload works. "
                    + "Only \(machine)'s own ports can be reached that way.")

            SchemeGroup {
                ForEach(places, id: \.self) { option in
                    if option != places.first {
                        Rectangle()
                            .fill(Theme.hairline)
                            .frame(height: 0.5)
                            .padding(.leading, 52)
                    }
                    destinationRow(option)
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("browser.open.isolation")
        } else if let only = places.first {
            // One destination is not a choice, and the sentence it would have
            // carried is still owed: a window appearing on a screen in another
            // room is the kind of press that otherwise looks like it did nothing.
            Text(meaning(of: only))
                .font(.system(size: 12))
                .foregroundStyle(Theme.faint)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 12)
                .padding(.horizontal, 4)
                .accessibilityIdentifier("browser.open.destination")
        }
    }

    /**
     * One destination: its glyph, its name, and what choosing it means.
     *
     * The label is set explicitly to the destination's own name and nothing
     * else. Left to SwiftUI, a button holding two `Text`s is read as both of them
     * joined — *"Isolated, opens in the machine's browser signed into nothing…"* —
     * and `buttons["Isolated"]` stops matching, which is the silent failure this
     * whole card is written to avoid. The sentence is the hint instead, which is
     * where VoiceOver expects the explanation of a control anyway.
     */
    private func destinationRow(_ option: Place) -> some View {
        let chosen = place == option
        return Button {
            place = option
            // A refusal belongs to the destination that refused. Leaving *"This
            // phone can only open the machine's own ports"* standing after a tap
            // on Machine would be a warning about a state nobody is in any more.
            notice = nil
        } label: {
            HStack(spacing: 12) {
                Image(systemName: glyph(of: option))
                    .font(.system(size: 19, weight: .light))
                    .foregroundStyle(chosen ? Theme.accent : Theme.faint)
                    .frame(width: 24, height: 28)
                VStack(alignment: .leading, spacing: 3) {
                    Text(name(of: option))
                        .font(.system(size: 16, weight: chosen ? .semibold : .regular))
                        .foregroundStyle(Theme.primary)
                    Text(meaning(of: option))
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.faint)
                        .fixedSize(horizontal: false, vertical: true)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 8)
                Image(systemName: chosen ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 17))
                    .foregroundStyle(chosen ? Theme.accent : Theme.faint)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(name(of: option))
        .accessibilityHint(meaning(of: option))
        .accessibilityAddTraits(chosen ? [.isSelected] : [])
    }

    /**
     * The address, and only the address.
     *
     * **No leading glyph.** There was one and it mirrored the destination —
     * globe, eye-slash, iPhone — which was the only signal of that choice while
     * the choice lived under the field. With a card of its own above saying the
     * same thing three ways at once, the glyph is a fourth copy that moves when
     * nothing here has changed. *"There should be no icon at all actually. It's
     * not required."*
     *
     * The notice under it is about **what was typed** and nothing else. It used
     * to share this slot with the sentence naming the destination, so a refusal
     * replaced the one line saying where the window was going. They are two views
     * now, and the destination's line lives with the destination.
     */
    private var addressCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            SchemeSectionCaption(
                "Address",
                about: "opening a window",
                info: "A web address opens on the machine; anything that is not an address is "
                    + "searched for. A port opens that port. Leave it empty for a blank window.")

            SchemeGroup {
                HStack(spacing: 12) {
                    // Every one of these is load-bearing, and each was learned on
                    // the localhost address bar: a URL keyboard puts the slash
                    // and the dot under a thumb, autocapitalisation would send
                    // "Localhost", autocorrect "local host", and the `.URL`
                    // content type stops iOS offering a contact's name.
                    TextField("Address or search", text: $address)
                        .textFieldStyle(.plain)
                        .keyboardType(.URL)
                        .textContentType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .submitLabel(.go)
                        .onSubmit(go)
                        .focused($typing)
                        .font(.system(size: 15, design: .monospaced))
                        .foregroundStyle(Theme.primary)
                        // `browser.address`, which is what this app's one address
                        // field has been called since there was one. It moved
                        // here when the second browser was deleted; the name did
                        // not change, because it is still the same field.
                        .accessibilityIdentifier("browser.address")
                    if !address.isEmpty {
                        Button {
                            address = ""
                            notice = nil
                        } label: {
                            // The glyph stays small and the target does not. 28
                            // is the biggest box that leaves the row the same
                            // height as one with no clear button in it.
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 15))
                                .foregroundStyle(Theme.faint)
                                .frame(width: 28, height: 28)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Clear")
                        .accessibilityIdentifier("browser.open.address.clear")
                    }
                }
                .padding(.leading, 16)
                .padding(.trailing, 10)
                .padding(.vertical, 12)
            }

            if let notice {
                Text(notice)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.warning)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 10)
                    .padding(.horizontal, 4)
                    .accessibilityIdentifier("browser.open.notice")
            }
        }
    }

    /// The destinations this machine actually offers, in the order they are
    /// drawn. Never fewer than one — the tab draws no `+` at all on a machine
    /// that offers neither door.
    private var places: [Place] {
        var out: [Place] = []
        if canOpenThere { out.append(.machine); out.append(.isolated) }
        if canTunnel { out.append(.phone) }
        return out.isEmpty ? [.machine] : out
    }

    /**
     * The word on the row, and it is the word the suites press.
     *
     * `Machine`, `Isolated`, `This phone` — unchanged from the segmented control
     * these rows replaced, deliberately. Two UI suites reach for two of them by
     * name, and a tidier word here would make both of those skip in silence.
     */
    private func name(of place: Place) -> String {
        switch place {
        case .machine: return "Machine"
        case .isolated: return "Isolated"
        case .phone: return "This phone"
        }
    }

    /// The glyph each destination already wore, kept exactly: they were the
    /// address field's leading icon, which mirrored this choice.
    private func glyph(of place: Place) -> String {
        switch place {
        case .machine: return "globe"
        case .isolated: return "eye.slash"
        case .phone: return "iphone"
        }
    }

    /// One plain line per destination — what you get, not how it works. The
    /// mechanism is on the caption's info dot for anybody who wants it.
    private func meaning(of place: Place) -> String {
        switch place {
        case .machine:
            return "Opens in \(machine)'s own browser, signed in the way \(machine) is."
        case .isolated:
            return "Opens in \(machine)'s browser signed into nothing, and forgets everything "
                + "when the window closes."
        case .phone:
            return "Opens here on this phone, over a tunnel to \(machine). Only \(machine)'s own "
                + "ports."
        }
    }

    // MARK: - The suggestions

    /**
     * The ports, under the field, as the addresses this machine is serving.
     *
     * Tapping one is the same act as typing it — the row and the field go to the
     * same destination, which is the test that says this is where a port belongs
     * rather than on a screen of its own.
     */
    private var suggestions: some View {
        PortSuggestions(
            model: model,
            book: book,
            choose: { port, path in open(port: port, path: path) },
            otherWay: otherWay,
            rename: beginRename,
            said: show)
    }

    /**
     * The row menu's alternative destination — the *other* place a port can go,
     * for the one page that wants to go there without changing the control above.
     *
     * Nil when there is only one place to put it, which is the honest answer on
     * a machine that will not tunnel or will not take a page.
     */
    private var otherWay: (label: String, act: (Int) -> Void)? {
        if place == .phone {
            guard canOpenThere else { return nil }
            return (model.openThereVerb, { port in
                openThere("http://localhost:\(String(port))/", false)
                dismiss()
            })
        }
        guard canTunnel else { return nil }
        return ("Open on this phone", { port in
            openHere(port, "/")
            dismiss()
        })
    }

    // MARK: - Actions

    /**
     * Work out what was typed, and open it — or say why not, and stay.
     *
     * The classification is `LocalhostAddress.classify` and nothing about it is
     * decided here; what is decided here is what a **port** means, which is
     * whatever the control above says. Beyond that nothing is validated: the
     * machine checks every address through the same gate an untrusted link goes
     * through — *a client is not something a machine gets to trust about what it
     * opens* — so a URL that parses here is still one the far side may refuse,
     * and it says so in the notice the window list carries.
     */
    private func go() {
        let typed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !typed.isEmpty else {
            guard place != .phone else {
                // A blank tunnel is not a thing to ask for: a tunnel is a port,
                // and there is no port here to open.
                notice = "A window on this phone needs one of \(machine)'s ports."
                return
            }
            // A blank window on the machine is a real thing to ask for, and it
            // is the one case with no address to resolve.
            openThere(nil, place == .isolated)
            dismiss()
            return
        }

        switch LocalhostAddress.classify(typed) {
        case let .tunnel(port, path):
            open(port: port, path: path)
        case let .page(url):
            openOnMachine(url)
        case let .search(_, url):
            openOnMachine(url)
        case let .refused(why):
            notice = why
        }
    }

    /// A port, wherever the control says ports go.
    private func open(port: Int, path: String) {
        if place == .phone {
            openHere(port, path)
        } else {
            openThere("http://localhost:\(String(port))\(path)", place == .isolated)
        }
        dismiss()
    }

    /// A site on the internet, which only the machine can reach for this app: a
    /// tunnel dials the machine's *own* loopback, so there is nowhere on this
    /// phone for a public address to go.
    private func openOnMachine(_ url: String) {
        guard place != .phone else {
            notice = "This phone can only open \(machine)'s own ports. Choose Machine to open a "
                + "site on the internet."
            return
        }
        openThere(url, place == .isolated)
        dismiss()
    }

    private func beginRename(_ port: Int) {
        renamePort = port
        renameText = book.name(host: hostId, port: port) ?? ""
        // Deferred by one turn of the run loop, the same as the Machines tab's
        // rename: raising an alert from inside a swipe action's handler while
        // the row is still animating back leaves the alert with no presenter.
        DispatchQueue.main.async { renaming = true }
    }

    private func commitRename() {
        guard let port = renamePort else { return }
        book.setName(renameText, host: hostId, port: port)
        renamePort = nil
    }

    private var renameMessage: String {
        guard let port = renamePort else { return "" }
        // `String(port)`, never string interpolation of the Int: a port
        // interpolated into a `Text` is formatted with the locale's grouping
        // separator and comes out as "localhost:3,000".
        return "localhost:\(String(port)) on \(machine)"
    }

    /// Two and a half seconds, the same as every other line this app holds on
    /// screen for something that leaves nothing behind.
    private func show(_ message: String) {
        withAnimation { toast = message }
        Task {
            try? await Task.sleep(for: .seconds(2.5))
            withAnimation { toast = nil }
        }
    }
}
/* -------------------------------------------------------------------------- */
/* Rows and words                                                              */
/* -------------------------------------------------------------------------- */

/**
 * One row of the one list.
 *
 * Two cases rather than one struct with two optionals, because they are not two
 * halves of a thing that sometimes has both: on a machine offering control every
 * row is a window, and on a machine offering only the cast every row is a
 * surface. A struct with `window: MachineWindow?` and `surface: BrowserSurfaceRow?`
 * would make "both nil" and "both set" expressible states that the screen would
 * then have to decide about in a view body.
 */
private enum MachineBrowserRow: Identifiable {
    /**
     * A window the phone can drive, carrying the machine's surface for it when
     * there is one.
     *
     * The whole surface rather than a `Bool`, and the difference is a badge that
     * would otherwise be on every row. *Castable* and *being cast right now* are
     * two facts: on a desktop every pane is in `castWindows`, so a mark drawn
     * from "there is a surface" would sit on all of them and distinguish nothing
     * — *"no quantity spam, no free emphasis."*
     */
    case window(MachineWindow, cast: BrowserSurfaceRow?)
    /// A page in the machine's browser that its window list does not name — see
    /// `surfaceRow`.
    case surface(BrowserSurfaceRow)
    /// A page **this phone** is holding open over a tunnel — see `pageRow`.
    case page(BrowserTab)

    var id: String {
        switch self {
        case let .window(window, _): return "window:\(window.id)"
        case let .surface(surface): return "surface:\(surface.window)"
        case let .page(tab): return "page:\(tab.id)"
        }
    }
}

/**
 * What a row pushes. A value rather than a `NavigationLink`, so a row whose
 * trailing corner is a second control can still navigate from a plain closure —
 * see `pushing`.
 *
 * **One case for every page on the machine**, and that is the part that matters.
 * There used to be a `.surface` beside `.window` that went to a different screen
 * with fewer controls on it, which is the thing he read as two kinds of browser
 * window. Every page on the machine goes to `MachineWindowView` now; what it is
 * named by — a shell tab id, or the empty string the front tab wears — is a fact
 * that screen resolves, not a fork here.
 *
 * `.phonePage` is not that fork coming back. It is a page **this phone** is
 * drawing, whose window screen is the page itself; what this pushes is its
 * settings, which is the one thing a row on this list could not reach before.
 */
private enum MachineBrowserDestination: Hashable, Identifiable {
    /// A page on the machine, by the name both lists call it: the live picture
    /// where there is one, the address, the page verbs, and the `…` that carries
    /// everything else.
    case window(String)

    /// The settings of a page this phone is holding over a tunnel, by the tab's
    /// own id. Not a window on the machine and deliberately not drawn as one.
    case phonePage(String)

    var id: String {
        switch self {
        case let .window(id): return "window:\(id)"
        case let .phonePage(id): return "page:\(id)"
        }
    }
}

/// The card's press state, without the card. `RowButtonStyle` draws its own
/// background, which is wrong for a row whose trailing corner is a second
/// control: the fill has to be behind *both* halves or the menu sits on the
/// screen's paper. The same split the port rows make.
struct MachineRowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .overlay {
                // `Theme.pressed` rather than a white wash: on paper a white wash
                // over a near-white card is nothing at all. See `Ink.pressed`.
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(configuration.isPressed ? Theme.pressed : .clear)
            }
            .scaleEffect(configuration.isPressed ? 0.99 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/**
 * A short word on a row, in a tinted capsule.
 *
 * Small enough that four fit across a phone beside a title, which is the whole
 * constraint: a window can be bound *and* live *and* isolated *and* recording at
 * once, and the row still has to be readable at a glance. The colour is the only
 * thing that separates them and it is doing real work — accent for the slot,
 * because that is an identifier; `positive` for live, because a cast running is
 * a good state and not a warning; `critical` for recording, because it is the
 * one state somebody may not have meant to leave on.
 */
struct MachineWindowMark: View {
    let text: String
    let tone: Color

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(tone)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(tone.opacity(0.14), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            .lineLimit(1)
    }
}

/**
 * The sentences these screens say, in one place so they cannot drift.
 *
 * Pure functions over the wire's own values, deliberately: everything here is a
 * decision about wording rather than about layout, and a decision about wording
 * that lives inside a view body is one nobody can read without the simulator.
 */
enum MachineBrowserText {
    /**
     * A session, and how many windows it already holds.
     *
     * The count is not decoration. The binding store hands a session's tools its
     * windows **by slot name**, so a session that already owns three is one
     * where the next binding becomes `B4` — somebody choosing where to attach a
     * window is choosing what that agent will call it.
     */
    static func sessionRow(_ session: WindowSession) -> String {
        switch session.windows {
        case 0: return session.title
        case 1: return "\(session.title) · 1 window"
        default: return "\(session.title) · \(String(session.windows)) windows"
        }
    }

    /// Who owns a bound window, in whatever the machine gave a name for. The id
    /// is the fallback rather than nothing: an id is ugly and it is still the
    /// thing an agent's transcript is keyed on.
    static func owner(_ window: MachineWindow) -> String? {
        if let title = window.sessionTitle, !title.isEmpty { return title }
        if let id = window.session, !id.isEmpty { return id }
        return nil
    }

    /**
     * What a watchable surface is called.
     *
     * `window` is `''` for whatever is in front and a slot name otherwise, so
     * the empty case is a real thing with a real name rather than a missing
     * value — *the front tab* is what somebody standing at that machine would
     * call it. The page's own title wins when it has one, for the same reason
     * `MachineWindow.label` prefers it: *Untitled* tells nobody which of their
     * windows they are looking at.
     */
    /**
     * The site a page is on — its host, and nothing else.
     *
     * Named rather than shown in full, and the desktop's `DriveBanner` gives the
     * reason this is worth a function: this line is what somebody reads before
     * deciding whether to type a password into a page an agent brought them, and
     * *"a full URL with a hundred characters of query string pushes the host off
     * the end of a single-line strip, which is precisely where somebody would
     * look to check they are not being phished by their own assistant."*
     *
     * Nil for anything that is not a URL with a host in it — a `file:` path, an
     * empty string, a window whose row has not landed. The callers draw nothing
     * for nil rather than a placeholder, because a placeholder in the line that
     * says *where you are* reads as a fact.
     */
    static func site(_ url: String) -> String? {
        guard let parsed = URL(string: url), let host = parsed.host(), !host.isEmpty else { return nil }
        return host
    }

    static func surfaceLabel(_ surface: BrowserSurfaceRow) -> String {
        if !surface.title.isEmpty { return surface.title }
        if !surface.url.isEmpty { return surface.url }
        return surface.window.isEmpty ? "Front tab" : surface.window
    }

    /// The whole row as one sentence, for VoiceOver. The marks are read as words
    /// rather than as four unexplained badges after the title.
    static func spoken(_ window: MachineWindow, streaming: Bool = false) -> String {
        var parts = [window.label]
        if let slot = window.slot {
            parts.append(owner(window).map { "\(slot), \($0)" } ?? slot)
        }
        if streaming { parts.append("being watched") }
        if window.isolated { parts.append("isolated") }
        if window.recording { parts.append("recording") }
        return parts.joined(separator: ", ")
    }
}
