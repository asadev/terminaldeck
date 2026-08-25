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
 *  - **Localhost** — the ports, the dev servers, the tunnel address bar and the
 *    tab strip — is `LocalhostPortsView`, one row down the `…`. Behind the menu
 *    rather than as a row at the foot of this list, and that is the whole of his
 *    sentence: *"things should not be mixed in the list of browsing windows."*
 *    A row at the bottom of a list of windows that is not a window is precisely
 *    the mixing he was pointing at; a menu is somewhere else, which is what he
 *    asked for.
 *  - **Opening a window** is the `+`, which raises `OpenWindowSheet`. The
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
 *  - **This phone's own browser chrome** — history, site data, saved logins —
 *    went with localhost, because all three are about pages loaded through a
 *    tunnel in this phone's web view and none of them is about a window on the
 *    machine. **Browser profiles** stayed here: a profile is the machine's
 *    Chromium partition, which is what these windows run in.
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
 *  - **watch, no control** — the rows are the surfaces, each going straight to
 *    the cast. The `+` is **absent**, not disabled: `browser.window.open` is a
 *    `browser.control` verb and a field that could only ever be refused is a
 *    control this app does not draw. So is the archive, and `WindowShelf`'s
 *    header says why.
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
    /// for, the same shape `LocalhostPortsView` takes its `PortBook` and
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

    /// Whether the sheet that opens a window is up. See `OpenWindowSheet`.
    @State private var opening = false

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

    /**
     * The one list.
     *
     * Surfaces only, on a machine that offers no control — they are all there is
     * to list. Otherwise the windows, each carrying the machine's surface for it
     * when there is one, preceded by any surface **no window claims**: on a
     * server that is the drive's own tab, which is in no window list at all. A
     * window on both lists appears once, because both are keyed on the same id.
     */
    private var rows: [MachineBrowserRow] {
        guard canDrive else { return surfaces.map { .surface($0) } }
        let open = windows
        let claimed = Set(open.map(\.id))
        let unclaimed = surfaces.filter { !claimed.contains($0.window) }
        return unclaimed.map { .surface($0) } + open.map { .window($0, cast: surface(for: $0)) }
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
            OpenWindowSheet(machine: model.current?.label ?? model.theMachine, open: openWindow)
        }
        .navigationDestination(item: $pushing) { destination in
            switch destination {
            case let .window(id):
                MachineWindowView(model: model, windowID: id)
            case let .surface(name):
                /*
                 * A page the machine will cast and no window claims — a server's
                 * own front tab, or every row on a machine that casts without
                 * offering control. Straight to the pixels, because watching it
                 * is the only verb it has.
                 *
                 * Resolved from the live surface list rather than from a row
                 * captured at push time: a window that closed between the tap
                 * and the push has no surface, and a viewer pointed at a name
                 * the host no longer knows waits forever for a frame.
                 */
                if let watch = host?.watch, let row = surfaces.first(where: { $0.window == name }) {
                    WatchViewerScreen(watch: watch, surface: row, chrome: model)
                }
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
     * Two verbs can put a page in the machine's browser and they are not
     * interchangeable. The difference was **measured in the host's own source**,
     * not guessed:
     *
     *  - `browser.window.open` mints a window through
     *    `openForSession(NO_SESSION)` and detaches it in the same breath, so on
     *    a **server** it holds no binding row and `castWindows` in
     *    `src/headless/host.ts` cannot see it. That file says so itself: *"the
     *    honest state is that they are listed by `browser.window.rows` and not
     *    by `browser.surfaces`."* Drivable, and not watchable.
     *  - `web.open` is backed by `openUrl`, which calls
     *    `browserDrive.open({ url, isolate: false })` and hands the page to the
     *    drive's own front slot — and that slot **is** a `browser.surfaces` row.
     *    So the page can be watched and driven, which is the half of his
     *    sentence the other door cannot do.
     *
     * `openUrl` was wired on the headless host *for this exact complaint*; its
     * comment quotes him. So a shared window goes through it, which is also
     * semantically exact: `isolate: false` **is** shared, the same profile and
     * the same cookies. An isolated one has no choice — only
     * `browser.window.open` can make a partition — and on a server that window is
     * honest about not being castable, in one line on its own screen.
     *
     * A machine that drives its browser but never advertised `web` falls back to
     * `browser.window.open`, because a control that refuses is worse than one
     * that does slightly less than it could.
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
        guard let url, !isolated, model.canOpenPages else {
            host?.openMachineWindow(url: url, isolated: isolated)
            return
        }
        model.openPageOnMachine(url)
        say("Opening \(shortened(url)) on \(model.current?.label ?? model.theMachine)")
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
     * Two controls, on opposite edges, and the sides are his.
     *
     * > *"On the sessions page the plus button is on one side and the three dots
     * > is on the other side, and on the browser page the three dots is on one
     * > side and the plus button is on another side. In both, the plus button
     * > should be left and three dots should be on the right side."*
     *
     * So the `+` is `.topBarLeading` and the `…` is `.topBarTrailing`, and the
     * session list is being moved to match in the same build. Two tabs that
     * disagree about which corner makes something is worse than either choice,
     * because the cost is paid by a thumb that has already committed.
     *
     * They are two controls rather than one menu because they are not two of a
     * kind. `LocalhostPortsView` argues against two glyphs eleven points apart
     * in one corner and is right about the pair it has — History and a site-data
     * screen are both *somewhere else to go*. A `+` and a `…` at opposite ends
     * are the pair every list app on this phone ships: one is the screen's
     * single primary verb, the other is everything else.
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
         * Absent — not disabled — on a machine that offers only the cast:
         * `browser.window.open` is a `browser.control` verb, and a control that
         * could only ever be refused is one this app does not draw.
         */
        if canDrive {
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    opening = true
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("Open a window")
                .accessibilityIdentifier("browser.new")
            }
        }

        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                /*
                 * **Localhost, folded away.**
                 *
                 * *"Even the localhost thing should be folded somewhere else —
                 * whatever the available whole localhost addresses are, in three
                 * dots maybe, or somewhere else."* Here rather than as a row at
                 * the foot of the list, because a row that is not a window, in a
                 * list of windows, is the mixing the whole change exists to
                 * undo.
                 *
                 * Drawn whether or not this machine will serve a port: the
                 * screen behind it says which of the four reasons it has nothing
                 * to show, and a menu item that appears and disappears with a
                 * capability is one nobody can learn the position of.
                 */
                NavigationLink {
                    LocalhostPortsView(model: model)
                } label: {
                    Label("Localhost", systemImage: "network")
                }
                .accessibilityIdentifier("browser.localhost")

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
                Image(systemName: "ellipsis.circle")
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
     * ## What a row says out loud
     *
     * Four facts, because each is a thing somebody can be wrong about while
     * moving quickly: which session owns it (the slot badge is the name that
     * session's tools call it by), whether it is isolated, whether **somebody is
     * watching it right now**, and **whether it is recording**. Two of those are
     * states a page can be left in without anybody meaning to, so they are marks
     * on the row rather than things you learn by opening it.
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
                    Image(systemName: "macwindow")
                        .font(.system(size: 19, weight: .light))
                        .foregroundStyle(window.recording ? Theme.critical : Theme.secondary)
                        .frame(width: 24)
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

            rowMenu(window, sessions: sessions)
                // Four, so the `…` does not sit against the card's rounded
                // corner. The same inset the port rows give their trailing slot.
                .padding(.trailing, 4)
        }
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    /**
     * A page that can be watched and cannot be driven.
     *
     * Two of them exist. On a machine offering no `browser.control` at all,
     * every row is one. On a server, `''` is one even beside a full window list:
     * it is the drive's own tab — where a page opened from the localhost address
     * bar lands — and `openTab` mints it no shell id, so no `browser.window.rows`
     * entry names it.
     *
     * No `…` and no swipe either way: every verb behind that menu is a
     * `browser.control` verb addressed by window id, and this row has no window
     * id to address. A glyph opening a menu with nothing in it is worse than no
     * glyph. The row is the one thing that can be done with this page — watch it
     * — so the row does it, and the chevron says the tap goes somewhere.
     */
    private func surfaceRow(_ surface: BrowserSurfaceRow) -> some View {
        Button {
            pushing = .surface(surface.window)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: surface.live ? "dot.radiowaves.left.and.right" : "macwindow")
                    .font(.system(size: 19, weight: .light))
                    .foregroundStyle(surface.live ? Theme.positive : Theme.secondary)
                    .frame(width: 24)
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
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.faint)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(MachineRowButtonStyle())
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .accessibilityLabel(MachineBrowserText.surfaceLabel(surface))
        .accessibilityHint("Watches this window and sends your taps to it")
        // `front` rather than the empty name it actually wears: an identifier
        // ending in a bare dot is one nobody reading a failure can tell from a
        // truncated string, and the front tab is the one surface whose name is
        // documented as empty rather than missing.
        .accessibilityIdentifier(surface.window.isEmpty
                                 ? "browser.machine.surface.front"
                                 : "browser.machine.surface.\(surface.window)")
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
     * The three verbs you do to a window **without opening it**, and nothing
     * else.
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
     * The session rows carry how many windows that session already holds,
     * because that is what decides whether the new binding is called `B1` or
     * `B4`.
     *
     * Destructive last, which is where iOS puts it in a menu, and the reverse of
     * the swipe's order — a swipe reads outward from the screen edge and a menu
     * reads down the list, so the two agree about which verb is furthest from an
     * accident.
     */
    private func rowMenu(_ window: MachineWindow, sessions: [WindowSession]) -> some View {
        Menu {
            // Absent, not empty, when the machine has no sessions: a heading
            // over nothing is a section that exists to look furnished, and every
            // row under it would be a control that cannot act.
            if !sessions.isEmpty {
                Section("Attach to a session") {
                    ForEach(sessions) { session in
                        Button {
                            host?.bindMachineWindow(window.id, to: session.id)
                        } label: {
                            Label(MachineBrowserText.sessionRow(session),
                                  systemImage: session.id == window.session ? "checkmark" : "terminal")
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
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.faint)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .accessibilityLabel("Actions for \(window.label)")
        .accessibilityIdentifier("browser.machine.more.\(window.id)")
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
    }
}

/* -------------------------------------------------------------------------- */
/* Opening one                                                                 */
/* -------------------------------------------------------------------------- */

/**
 * Open a window on the machine: where it should go, and whose cookies it gets.
 *
 * ## Why this is a sheet and not a card on the list
 *
 * It was a card on the list — an address field and a Shared/Isolated segmented
 * control, permanently at the top of the windows, argued for on the grounds that
 * *"a machine with nothing open needs a control, not an apology."* He read the
 * result and named it: *"it should not be like isolated and other things that
 * you added in the browser page — things should not be mixed in the list of
 * browsing windows."*
 *
 * The card's argument survives; only its place was wrong. The way in is the `+`
 * in the bar, which is on screen at all times and does not take a fifth of the
 * list to say so, and the empty state's own button raises this same sheet — so a
 * machine with nothing open still opens onto a control.
 *
 * ## And why isolation belongs *here* rather than on a window
 *
 * It is a property of the window at the moment it is made. A login typed into a
 * window that turned out to be shared is already in the machine's cookie jar by
 * the time anybody thinks to convert it, so the choice has to be available
 * before the window exists. It is still convertible in both directions
 * afterwards — that control is on the window's own settings, where every other
 * per-window setting is.
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
 * function — the same one the localhost address bar calls, so the two fields
 * cannot come to different conclusions about what `google.com` means.
 *
 * The one thing that is decided **here** rather than there is what a *port*
 * means from this sheet. On the localhost screen a port is a tunnel, viewed on
 * the phone; on a sheet titled *Open a window* it is a page for the machine's
 * own browser, at `http://localhost:<port>`. Both are what their control says
 * it does, which is why neither is a mode.
 *
 * A line this app will not open — a `file:` URL, a port out of range — is a
 * sentence **under the field**, and the sheet stays up. Dismissing on a refusal
 * would throw away what was typed to punish a typo, and dismissing silently
 * would be a press that reported success for nothing.
 */
private struct OpenWindowSheet: View {
    /// What to call the machine in the one sentence on this sheet. A name rather
    /// than "the machine", because somebody with two paired needs to know which
    /// one is about to grow a window.
    let machine: String
    /// The resolved URL and the isolation choice. Nil is a real choice — a blank
    /// window on the machine — which is why Open is never disabled.
    let open: (String?, Bool) -> Void

    @State private var address = ""
    @State private var isolated = false
    /// Why the last press did not open anything, or nil. Drawn under the field,
    /// which is the only place it is shown.
    @State private var notice: String?
    @FocusState private var typing: Bool

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.background.ignoresSafeArea()

                VStack(alignment: .leading, spacing: 0) {
                    SchemeSectionCaption(
                        "Address",
                        about: "opening a window",
                        info: "A web address opens on the machine; anything that is not an address "
                            + "is searched for. A port opens that port on the machine. Leave it "
                            + "empty for a blank window.\n\nA shared window uses the machine's own "
                            + "profile — its cookies and whatever it is signed into. An isolated "
                            + "one gets a partition of its own, and that partition is thrown away "
                            + "when the window closes.")

                    SchemeGroup {
                        HStack(spacing: 12) {
                            Image(systemName: isolated ? "eye.slash" : "globe")
                                .font(.system(size: 19, weight: .light))
                                .foregroundStyle(Theme.faint)
                                .frame(width: 24, height: 28)
                            // Every one of these is load-bearing, and each was
                            // learned on the localhost address bar: a URL
                            // keyboard puts the slash and the dot under a thumb,
                            // autocapitalisation would send "Localhost",
                            // autocorrect "local host", and the `.URL` content
                            // type stops iOS offering a contact's name.
                            // Two words, because the field is monospaced at 15
                            // point and anything longer is an ellipsis on the
                            // narrowest phone. What it leaves out — that an
                            // empty field is a blank window — is on the ⓘ above,
                            // which is where a rule that is not a hint belongs.
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
                                .accessibilityIdentifier("browser.open.address")
                            if !address.isEmpty {
                                Button {
                                    address = ""
                                    notice = nil
                                } label: {
                                    // The glyph stays small and the target does
                                    // not. 28 is the biggest box that leaves the
                                    // row the same height as one with no clear
                                    // button in it.
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
                        .padding(.vertical, 10)

                        Rectangle()
                            .fill(Theme.hairline)
                            .frame(height: 0.5)
                            .padding(.leading, 16)

                        HStack(spacing: 12) {
                            Picker("Window", selection: $isolated) {
                                Text("Shared").tag(false)
                                Text("Isolated").tag(true)
                            }
                            .pickerStyle(.segmented)
                            .labelsHidden()
                            .accessibilityIdentifier("browser.open.isolation")
                        }
                        .padding(.horizontal, 16)
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
                    } else {
                        // The one sentence on this sheet, because a window
                        // appearing on a screen in another room is the kind of
                        // press that otherwise looks like it did nothing.
                        Text("Opens in \(machine)'s own browser.")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.faint)
                            .padding(.top, 10)
                            .padding(.horizontal, 4)
                    }

                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 16)
                .padding(.top, 4)
            }
            .navigationTitle("Open a window")
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
        }
    }

    /**
     * Work out what was typed, and open it — or say why not, and stay.
     *
     * The classification is `LocalhostAddress.classify` and nothing about it is
     * decided here; what is decided here is that a **port** typed into this
     * sheet is a page on the machine rather than a tunnel, which is what the
     * title of the sheet says it does.
     *
     * Beyond that nothing is validated: the machine checks every address through
     * the same gate an untrusted link goes through — *a client is not something
     * a machine gets to trust about what it opens* — so a URL that parses here
     * is still one the far side may refuse, and it says so in the notice the
     * window list carries.
     */
    private func go() {
        let typed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !typed.isEmpty else {
            // A blank window is a real thing to ask for, and it is the one case
            // with no address to resolve.
            open(nil, isolated)
            dismiss()
            return
        }

        switch LocalhostAddress.classify(typed) {
        case let .tunnel(port, path):
            open("http://localhost:\(String(port))\(path)", isolated)
        case let .page(url):
            open(url, isolated)
        case let .search(_, url):
            open(url, isolated)
        case let .refused(why):
            notice = why
            return
        }
        dismiss()
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
    /// A page the phone can only watch — see `surfaceRow`.
    case surface(BrowserSurfaceRow)

    var id: String {
        switch self {
        case let .window(window, _): return "window:\(window.id)"
        case let .surface(surface): return "surface:\(surface.window)"
        }
    }
}

/// What a row pushes. A value rather than a `NavigationLink`, so a row whose
/// trailing corner is a second control can still navigate from a plain closure —
/// see `pushing`.
private enum MachineBrowserDestination: Hashable, Identifiable {
    /// A window's own screen: the live picture when the machine casts it, the
    /// address, the page verbs, and the `…` that carries everything else.
    case window(String)
    /// Straight to the cast, for a page no window claims.
    case surface(String)

    var id: String {
        switch self {
        case let .window(id): return "window:\(id)"
        case let .surface(name): return "surface:\(name)"
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
