/**
 * Everything the machine is serving, and everything it could serve — folded off
 * the Browser tab's home and onto a screen of its own.
 *
 * ## Why it is one row down a menu now
 *
 * It was the Browser tab itself: this list, with an address bar above it, a
 * strip of open tunnel tabs under that, and a row at the foot leading to the
 * machine's own browser windows. Asad read the result:
 *
 * > *"things should not be mixed in the list of browsing windows. The home page
 * > of the browser should be for the open browser windows… Even the localhost
 * > thing should be folded somewhere else — whatever the available whole
 * > localhost addresses are, in three dots maybe, or somewhere else."*
 *
 * So the tab's home is the windows (`MachineBrowserView`) and this is behind its
 * `…`. **Not** a row at the foot of that list, which was the other option and is
 * the same mistake in a smaller font: a row that is not a window, in a list of
 * windows, is exactly the mixing being complained about. A menu is somewhere
 * else, which is what he asked for.
 *
 * What came *with* it is the part worth noticing. History, site data and saved
 * logins used to sit in the tab's `…`, and all three are about pages this phone
 * loaded **through a tunnel, in its own web view** — none of them is about a
 * window on the machine. They are on this screen's own `…` now, beside the
 * thing they are about. The machine's Chromium **profiles** went the other way
 * and stayed on the home, because that is the partition the machine's windows
 * run in.
 *
 * ## The rest of this screen is unchanged, and here is why it is shaped this way
 *
 * Asad, opening the phone app: *"I can already see a big list of local hosts. So
 * it should not be like that… we need to fold it in a better way"*, and then the
 * three things that would fix it — rename them, categorise them, and *"I don't
 * see any kind of option here to make anyone up or make anyone activated"*.
 *
 * The list he was looking at was rendered inline underneath the sessions, every
 * row a process name: `localhost:2019 wslrelay`, `localhost:2222 wslrelay`,
 * `localhost:3100 wslrelay`, `localhost:6666 AgentService`.
 *
 * ### 1. It is grouped, from facts
 *
 * `PortCatalog` holds the rules and the reasoning. The short version is that
 * every group is derived from something the wire carries — a process name, a
 * proven dev-server port, the socket this phone is connected on — and the three
 * groups that are noise start folded rather than hidden.
 *
 * ### 2. Rows can be named, and naming one promotes it
 *
 * `PortBook` holds the names, on this phone, against the machine and the port.
 * A named port is lifted to the top group, which is the whole of *"we can keep
 * some in the list and we can keep some folded"* — one gesture, one meaning.
 *
 * ### 3. The dev servers are here too, and they are the Start button
 *
 * The port list can only ever say what is *already* running. `DevServerSection`
 * is the other half — a project whose server is not up is a row with a Start on
 * it — and this is the screen both halves belong on, because they answer the
 * same question. A dev server that is `ready` is joined to its own port row
 * rather than drawn beside it; see `PortCatalog`.
 *
 * ## Why this is a `List` when every other screen in the app is a `ScrollView`
 *
 * Swipe actions. Asad asked for them on both lists — *"we hold a finger or we
 * keep a finger drag left to right… we need to have any action"* — and
 * `.swipeActions` exists only inside a `List`. Hand-rolling a drag would have
 * given a swipe that is not the system's: no rubber band at the limit, no
 * interaction with the back gesture at the left edge, and a different depth from
 * every other app on the phone. The cards survive the change — a clear row
 * background and the same rounded fill — so the screen looks like the rest of
 * the app and behaves like iOS.
 *
 * ## There is no Stop, and it is not an oversight
 *
 * A dev server runs in an **ordinary session** — the desktop opens a shell in
 * the project folder and types the command into it — so stopping one is Ctrl-C
 * in that session, which is why the wire has no stop verb to send. What this
 * screen will not do is type the interrupt blindly from a swipe: the desktop
 * decides a folder is `ready` and only stops saying so when the *session* exits,
 * which a Ctrl-C into a shell does not do. The row would go on offering an
 * address for a server that had gone — the one thing `DevServerReport` says a
 * client of that frame must never display. So the action opens the session, with
 * the interrupt one key away on the accessory bar, and the honest fix is a stop
 * verb on the desktop.
 */

import SwiftUI
import UIKit

struct LocalhostPortsView: View {
    let model: DeckModel
    /// The phone's own names for these ports. Injected rather than reached for,
    /// so a preview or a test can hand in a store of its own.
    var book: PortBook = .shared

    /// The tunnel the browser is showing. Set by a tap and by nothing else,
    /// which is what makes the tap the consent — see `ClientMessage.tunnelOpen`.
    @State private var browsing: PortTunnel?

    /**
     * The path the browser should ask the machine for once its tunnel is up.
     *
     * Beside `browsing` rather than on `PortTunnel`, because a tunnel is a port
     * and knows nothing about pages: the same tunnel serves every path on that
     * origin, and a second open at a different path on a port already tunnelled
     * would be one socket and two claims about what it was for.
     *
     * `"/"` for every row on this screen, which is what a tap on a port has
     * always meant. Anything else comes from the address field, which is the
     * only place in the app a path can be typed.
     */
    @State private var browsingPath = "/"

    /// What is in the address bar at the top of this screen. The bar is always
    /// on screen here, so there is no "is it up" to track — see `addressBar`.
    @State private var address = ""
    /// Why the last thing typed was not opened, or nil. Drawn under the field —
    /// see `LocalhostAddress.Typed.refused`, which writes whole sentences
    /// precisely because this is the only place they are shown.
    @State private var addressNotice: String?

    /**
     * The rename alert, as two plain properties rather than one optional.
     *
     * The same shape — and the same reason — as `DeckModel.renamingHost`. A
     * computed `Binding(get: { target != nil }, set: { if !$0 { target = nil } })`
     * is dismissed within a second of appearing on this screen, because every
     * paired machine holds a socket and the model publishes constantly: each
     * rebuild runs that setter and nils the value out from under the
     * presentation. A real `@State` Bool has nothing to run.
     */
    @State private var renaming = false
    @State private var renamePort: Int?
    @State private var renameText = ""

    @State private var toast: String?

    /// Whether the history sheet is up. See `BrowserHistoryView`.
    @State private var showingHistory = false

    /// Which tab the page on top belongs to, or nil while the list is showing.
    /// Held beside `browsing` rather than derived from it: a tunnel is shared by
    /// every tab on that port, so it cannot say which of them is open.
    @State private var currentTabID: String?

    /// Focus for the address field, so the strip's `+` can raise the keyboard.
    @FocusState private var addressFocused: Bool

    private var currentTab: BrowserTab? {
        currentTabID.flatMap { model.browserTabs.tab($0) }
    }

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()

            VStack(spacing: 0) {
                /*
                 * The machine's last word, on the screen it was said to.
                 *
                 * `lastError` is one line per machine and the session list was
                 * the only screen drawing it — so a Start pressed on a
                 * dev-server row here, or a page the machine would not open, was
                 * answered on a tab nobody was looking at. A press whose refusal
                 * is invisible is a press that reads as dead.
                 *
                 * The same banner and the same tap to dismiss, over one string:
                 * two screens draw it and only one of them is ever on top.
                 */
                if let error = model.lastError {
                    Banner(text: error, tone: .warning)
                        .onTapGesture { model.dismissError() }
                        .accessibilityIdentifier("localhost.error")
                }

                /*
                 * The address bar, on the screen rather than behind a `+`.
                 *
                 * *"we should have only one which will be called browser… where
                 * we can browse the localhost, we can type."* Typing was already
                 * possible and it was two taps and a modal away, which is not
                 * what anybody means by a browser. A browser has a bar at the
                 * top; this is that bar, and it moved down here with the rest of
                 * localhost rather than being deleted — *"even the localhost
                 * thing should be folded somewhere else"*, not thrown away.
                 *
                 * It stays above the empty state as well as above the list,
                 * which is the case it is most needed in: a machine serving
                 * nothing is exactly when somebody wants to type a port they
                 * know is coming up.
                 */
                addressBar

                /*
                 * **The open pages, as a strip.**
                 *
                 * > *"this browser in the mobile side is not full option like
                 * > macOS browser… it should have all those options, to start a
                 * > new window and all of this stuff."*
                 *
                 * Directly under the bar, which is where every browser puts it,
                 * and absent entirely when nothing is open — see
                 * `BrowserTabStrip`. The `+` clears the field and raises the
                 * keyboard rather than opening a blank page, because a tab with
                 * no address is a tab with nothing in it.
                 */
                BrowserTabStrip(
                    tabs: model.browserTabs.tabs(on: model),
                    current: currentTab,
                    select: { resume($0) },
                    close: { closeTab($0) },
                    new: {
                        address = ""
                        addressNotice = nil
                        addressFocused = true
                    }
                )

                if let notice = model.browserTabs.notice {
                    Banner(text: notice, tone: .warning)
                        .accessibilityIdentifier("browser.tabs.notice")
                }

                if sections.isEmpty { empty } else { list }
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
                        .accessibilityIdentifier("localhost.list.toast")
                        .accessibilityAddTraits(.updatesFrequently)
                }
                .transition(.opacity)
                .allowsHitTesting(false)
            }
        }
        .navigationTitle("Localhost")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            /*
             * **One menu, not three glyphs.**
             *
             * History, the site-data screen and the saved logins arrived from
             * three different lanes and all three wanted this corner. Controls
             * eleven points apart, in the slot a thumb goes to without looking,
             * is the same mistake `LocalhostBrowser` argues against about its
             * two back buttons — so they are one `…` with three named rows, and
             * adding a fourth later costs a line rather than a redesign.
             *
             * All three are **this phone's** browser: its history of tunnelled
             * pages, its web view's site data, its Keychain. They were on the
             * Browser tab's own `…` while this screen was that tab; they came
             * down here with it, because the thing they are about is here. The
             * machine's Chromium profiles stayed up there, beside the machine's
             * windows, for the same reason in reverse.
             */
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
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
                     * **Saved logins.**
                     *
                     * One half of the split Asad drew: *"whatever cannot be
                     * linked, it can be only here also — like password saving —
                     * that can be native only for this application, for that
                     * server only specific."* A password this phone's own web
                     * view captured cannot be pushed into the machine's browser
                     * and should not be, so it lives in this phone's Keychain,
                     * keyed per machine. The other half — the machine's own
                     * profiles, named and switched over the wire — is on the
                     * Browser tab's home, with the windows those profiles run.
                     */
                    NavigationLink {
                        SavedLoginsView(host: hostId, machine: model.theMachine)
                    } label: {
                        Label("Saved logins", systemImage: "key")
                    }
                    .accessibilityIdentifier("browser.logins")
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .accessibilityLabel("More")
                .accessibilityIdentifier("localhost.more")
            }
        }
        /*
         * A push, not a cover.
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
        /*
         * Attached to the screen, never inside the `.toolbar` builder — that
         * view is rebuilt whenever the machine pushes anything, and a sheet
         * bound to it is dismissed out from under a thumb. The same rule this
         * file already follows for its rename alert.
         */
        .sheet(isPresented: $showingHistory) {
            BrowserHistoryView(host: hostId, machine: model.theMachine) { port, path in
                open(port: port, path: path)
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
         * Presented from the screen rather than from the row.
         *
         * A `.alert` attached inside a `ForEach` is attached to a view that is
         * rebuilt whenever the desktop pushes anything — a `ports` frame, a
         * `dev.state`, a session status — and an alert whose host disappears
         * mid-presentation is an alert that closes itself. One alert, at the
         * top, holding the port it is about.
         */
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

    // MARK: - What is on the screen

    /// Which machine these ports belong to. Names are stored against it, so a
    /// phone paired with two machines does not show one's names over the other's.
    private var hostId: String { model.current?.id ?? "" }

    /// What the machine says is listening, and nothing when it has not offered
    /// to say. A machine speaking plain v1 has no `ports` frame at all.
    private var ports: [LocalPort] { model.canBrowseLocalhost ? model.ports : [] }

    /// The projects this machine will discuss. A separate capability from the
    /// one above, and they genuinely come apart — see `HostLink.canUseDevServers`.
    private var devServers: [DevServerReport] { model.canUseDevServers ? model.devServers : [] }

    /**
     * The names this phone holds for the ports on screen, read once as a snapshot.
     *
     * Handed to `PortCatalog` as plain data rather than as a closure over the
     * store, so the catalog stays a pure function over values — which is what
     * lets every grouping rule be pinned by a test with no simulator, no host and
     * no `UserDefaults`, and keeps the store out of a callback the catalog would
     * otherwise be calling back into.
     */
    private var names: [Int: String] {
        guard !hostId.isEmpty else { return [:] }
        var found: [Int: String] = [:]
        for entry in ports {
            if let name = book.name(host: hostId, port: entry.port) { found[entry.port] = name }
        }
        // A `ready` dev server's port is nameable too, even on a machine that
        // does not offer the port list at all: the address came off `dev.state`.
        for report in devServers where report.status == .ready {
            guard let port = report.port else { continue }
            if let name = book.name(host: hostId, port: port) { found[port] = name }
        }
        return found
    }

    private var sections: [LocalhostSection] {
        PortCatalog.sections(ports: ports,
                             devServers: devServers,
                             appPorts: PortCatalog.appPorts(for: model.current?.credential.endpoint),
                             names: names)
    }

    private var list: some View {
        List {
            ForEach(sections) { section in
                Section {
                    if !book.isFolded(host: hostId, category: section.category) {
                        ForEach(section.rows) { row in
                            rowView(row)
                        }
                    }
                } header: {
                    SectionToggle(category: section.category,
                                  count: section.rows.count,
                                  folded: book.isFolded(host: hostId, category: section.category)) {
                        guard !hostId.isEmpty else { return }
                        book.setFolded(!book.isFolded(host: hostId, category: section.category),
                                       host: hostId,
                                       category: section.category)
                    }
                }
            }

            footnote

            // Room for the pill that floats over this list. See `TabBarClearance`.
            TabBarClearance()
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        // Rendered first at the default, which put 55 points between one group's
        // last row and the next group's header — on a screen whose whole purpose
        // is fitting more of a long list into one glance, three folded groups ate
        // a third of the phone. Fourteen is the gap the session list's cards
        // already use between sections.
        .listSectionSpacing(14)
        .refreshable {
            model.refresh()
            // The pull gesture needs something to hold on to or it snaps back
            // before the answer arrives and reads as having done nothing. The
            // same 450ms the session list waits.
            try? await Task.sleep(for: .milliseconds(450))
        }
    }

    /**
     * One row, whichever kind it is, with the same two swipes on both.
     *
     * The dev-server half is `DevServerRow` unchanged — it already draws all five
     * states and the reasoning for each is in `DevServerSection.swift`, and a
     * second row type saying the same things in a slightly different order is how
     * two screens end up disagreeing about what `failed` looks like.
     */
    @ViewBuilder
    private func rowView(_ row: LocalhostRow) -> some View {
        Group {
            if let dev = row.dev {
                DevServerRow(report: dev,
                             name: row.name,
                             canTunnel: model.canBrowseLocalhost,
                             start: { model.startDevServer(in: dev.folder) },
                             openPort: { open(port: $0) },
                             openSession: { model.open(session: $0) })
            } else if let entry = row.entry {
                SplitRow(identifier: "port.\(String(entry.port))") {
                    open(port: entry.port)
                } label: {
                    PortRow(entry: entry, name: row.name)
                } trailing: {
                    portMenu(entry: entry, named: row.name != nil)
                }
            }
        }
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
        .listRowInsets(EdgeInsets(top: 5, leading: 16, bottom: 5, trailing: 16))
        // `allowsFullSwipe: false` on both edges, deliberately. A full swipe
        // fires the first action on release, and the two first actions here are
        // "rename" and "start a process on somebody's computer" — neither is a
        // thing to do by accident with a thumb.
        .swipeActions(edge: .leading, allowsFullSwipe: false) {
            leadingActions(row)
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            /*
             * Destructive first, reading outward from the screen edge — the
             * platform's own order and also the order of how much each one costs
             * to get wrong, the same argument the session list makes about
             * Close, Archive and Details. Clearing a name is the only thing on a
             * port row that takes something away, so it is the only thing that
             * can be at the edge.
             */
            clearNameAction(row)
            secondAction(row)
        }
    }

    /**
     * The harmless edge, and it carries the same two verbs the `…` does.
     *
     * > *"we can swipe them left and right and we can have options there to
     * > delete or close the options or archive and things, just like WhatsApp
     * > has the chats."*
     *
     * Rename was here already. **Open on the machine** is the menu's own first
     * item and the only one that does anything on the far computer, and it was
     * reachable only by finding a 44-point glyph at the end of a row — which is
     * the gesture this whole change exists to replace. Its words come from
     * `DeckModel.openThereVerb` rather than being written twice: on a desktop
     * this puts a tab on that computer's screen and on a server the page lands
     * in the server's own Chromium, and one sentence cannot be true of both.
     *
     * Gated on exactly what the menu row is gated on — `canOpenPagesThere`,
     * which a machine withholds from a guest — so the swipe can never draw a
     * button the menu would have refused to draw.
     */
    @ViewBuilder
    private func leadingActions(_ row: LocalhostRow) -> some View {
        if let port = row.port {
            Button {
                beginRename(port: port)
            } label: {
                Label(row.name == nil ? "Name" : "Rename", systemImage: "pencil")
            }
            .tint(Theme.accent)
            .accessibilityLabel(row.name == nil ? "Name this port" : "Rename this port")
            .accessibilityIdentifier("port.swipe.rename.\(String(port))")

            if model.canOpenPagesThere {
                Button {
                    model.openOnMachine("http://localhost:\(String(port))/")
                    // Said here, because the confirmation is a tab appearing on
                    // a screen the person may not be looking at. Without it, a
                    // press that worked perfectly is indistinguishable from one
                    // that did nothing.
                    show(model.openedThere("localhost:\(String(port))"))
                } label: {
                    Label("Open there", systemImage: "arrow.up.forward.app")
                }
                .tint(Theme.neutralAction)
                .accessibilityLabel(model.openThereVerb)
                .accessibilityIdentifier("port.swipe.openThere.\(String(port))")
            }
        }
    }

    /**
     * Give the port its number back.
     *
     * The menu's destructive row, on the gesture. Not *delete*: nothing on the
     * machine changes and the port stays in the list — it goes back to being
     * called by the process holding it, and drops out of the top group it was
     * promoted into. Drawn only on a row that has a name, which is the same
     * condition the menu row is drawn on, so it can never be a button that
     * clears nothing.
     */
    @ViewBuilder
    private func clearNameAction(_ row: LocalhostRow) -> some View {
        if let port = row.port, row.name != nil {
            Button(role: .destructive) {
                book.setName(nil, host: hostId, port: port)
            } label: {
                Label("Clear name", systemImage: "tag.slash")
            }
            /*
             * Tinted explicitly, and it took a screenshot to find out why it has
             * to be: `role: .destructive` on a swipe button is red *by default*
             * and only by default. This screen sits under the app's accent, an
             * ambient tint wins, and the first build of the session list's own
             * Close came out blue beside an orange Archive. Nothing in the build
             * log says so and the code reads correctly.
             */
            .tint(Theme.critical)
            .accessibilityLabel("Clear the name on this port")
            .accessibilityIdentifier("port.swipe.clear.\(String(port))")
        }
    }

    /**
     * The trailing swipe: the row's *other* action, and there is only ever one.
     *
     * For a dev server it is the state's own verb — start it, or go to the
     * session it is running in. For a plain port there is nothing to start: the
     * desktop has no way to launch "the thing that was on 2019", because a port
     * is the outcome of a command in a folder and neither of those is knowable
     * from a number. So that row gets the useful thing instead, which is the
     * address on the clipboard.
     */
    @ViewBuilder
    private func secondAction(_ row: LocalhostRow) -> some View {
        // Which action it is lives in `PortCatalog.secondAction`, so the answer
        // to "what does start do in each of the five states" is a value a unit
        // test can read rather than a branch inside a view body that only a
        // paired phone with a project on the far machine could exercise.
        switch PortCatalog.secondAction(for: row) {
        case let .start(folder):
            Button {
                model.startDevServer(in: folder)
            } label: {
                Label("Start", systemImage: "play.fill")
            }
            .tint(Theme.positive)
            .accessibilityLabel("Start the dev server in \(folder)")
            .accessibilityIdentifier("devserver.swipe.start.\(folder)")

        case let .retry(folder):
            // Not a Start drawn as though nothing had happened. `dev.start`
            // re-reads the folder from disk, so a `package.json` fixed since the
            // failure is picked up rather than the old answer being replayed.
            Button {
                model.startDevServer(in: folder)
            } label: {
                Label("Try again", systemImage: "play.fill")
            }
            .tint(Theme.positive)
            .accessibilityLabel("Start the dev server in \(folder) again")
            .accessibilityIdentifier("devserver.swipe.retry.\(folder)")

        case let .openSession(id):
            // Labelled for what it does. It is also how a dev server is stopped
            // — Ctrl-C is on the key bar in there — and calling the button
            // "Stop" would be naming it after the thing the *next* tap does.
            // See this file's header.
            Button {
                model.open(session: id)
            } label: {
                Label("Session", systemImage: "terminal")
            }
            .tint(Theme.neutralAction)
            .accessibilityLabel("Open the session this server is running in")
            .accessibilityIdentifier("devserver.swipe.session.\(row.dev?.folder ?? id)")

        case let .copyAddress(port):
            Button {
                copyAddress(port)
            } label: {
                Label("Copy", systemImage: "doc.on.doc")
            }
            .tint(Theme.neutralAction)
            .accessibilityLabel("Copy this port's address")
            .accessibilityIdentifier("port.swipe.copy.\(String(port))")

        case .none:
            EmptyView()
        }
    }

    /**
     * The three dots he asked for, on the rows that have room for it.
     *
     * *"maybe three dots and more options and stuff like that"*. It is on the
     * port rows and not on the dev-server rows because those already spend their
     * trailing edge on a state-specific control — a terminal button while a
     * server is up, Try again after one failed — and a second control beside it
     * would be the duplication he objected to on the desktop. Everything a
     * dev-server row can do is on its swipe.
     */
    private func portMenu(entry: LocalPort, named: Bool) -> some View {
        Menu {
            /*
             * Open it **over there**, which is the other half of this screen.
             *
             * Tapping the row already opens the page *here*, through a tunnel,
             * and that is the right answer for reading a dev server on a train.
             * This is the half he asked for in the same breath: *"a browser
             * started from the phone must run on the machine you are inside — a
             * live link or a localhost link both open on the connected
             * machine."* The phone is driving rather than viewing.
             *
             * First in the menu, because it is the only item here that does
             * something on the far machine; renaming and copying are about this
             * phone. Drawn only when the machine advertised `web`, which it
             * withholds from a guest device — so this is never a control that
             * discovers it does not work.
             *
             * Its **words** come from `DeckModel.openThereVerb` rather than
             * being written here, because they are not the same sentence on both
             * kinds of machine. On a desktop this puts a tab on that computer's
             * screen; on a server there is no screen and the page lands in the
             * server's own Chromium instead. "Open on DESKTOP-DDGMNCV" was true
             * of one and nonsense on the other, and he said so.
             */
            if model.canOpenPagesThere {
                Button {
                    model.openOnMachine("http://localhost:\(String(entry.port))/")
                    show(model.openedThere("localhost:\(String(entry.port))"))
                } label: {
                    Label(model.openThereVerb, systemImage: "arrow.up.forward.app")
                }
                .accessibilityIdentifier("port.menu.openThere")
            }

            Button {
                beginRename(port: entry.port)
            } label: {
                Label(named ? "Rename" : "Name this port", systemImage: "pencil")
            }
            .accessibilityIdentifier("port.menu.rename")

            if named {
                Button(role: .destructive) {
                    book.setName(nil, host: hostId, port: entry.port)
                } label: {
                    // Not "delete": nothing on the machine changes and the port
                    // stays in the list. It goes back to being called by the
                    // process holding it.
                    Label("Clear name", systemImage: "tag.slash")
                }
                .accessibilityIdentifier("port.menu.clear")
            }

            Button {
                copyAddress(entry.port)
            } label: {
                Label("Copy address", systemImage: "doc.on.doc")
            }
            .accessibilityIdentifier("port.menu.copy")
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.faint)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .accessibilityLabel("Actions for port \(String(entry.port))")
        .accessibilityIdentifier("port.more.\(String(entry.port))")
    }

    /**
     * The rule nothing else on screen states, behind the ⓘ.
     *
     * Asad, twice: *"we don't need this much of big descriptions under each"* and
     * *"just if somewhere it's very required, give the i icon."* Naming a port is
     * what moves it up, and a folded group is otherwise a thing somebody has to
     * discover twice — so the rule stays and the paragraph does not.
     */
    private var footnote: some View {
        HStack(spacing: 6) {
            Text("Named ports come first")
                .font(.system(size: 12))
                .foregroundStyle(Theme.faint)
            InfoDot(
                about: "Groups",
                text: "Groups are worked out from the process holding each port. "
                    + "Naming one moves it to the top of the list."
            )
        }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 14)
            .padding(.bottom, 24)
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 20))
            .accessibilityIdentifier("localhost.footnote")
    }

    /**
     * Nothing to show, and which of the four reasons it is.
     *
     * A machine that does not offer the capability at all is a different fact
     * from one that offers it and is serving nothing, and both are different from
     * a socket that is down — saying "nothing is running" over a dead connection
     * is a claim nobody checked.
     *
     * ## And a fourth, which says nothing at all
     *
     * The first seconds of a launch. This screen read `connection.isLive`, so it
     * opened on the word **Connecting** every single time — the first frame of a
     * launch is `.offline` and the second is `.connecting` — which is the
     * yellow-thing complaint written larger: *"let it give a few seconds; after
     * five seconds if it is still not connected, then show. Otherwise it will
     * just load, so they will not even feel that it takes time for connecting."*
     *
     * `showsConnectionNotice` is the one property that rule lives in.
     * `SessionListView` puts its banner, its pill and its empty state all on it
     * so the three cannot drift; this screen was the one place still asking the
     * socket directly, and a screen that flashes a warning the tab next door has
     * decided not to show is two answers to one question. A spinner until the
     * grace period is over, and the honest sentence after it. See
     * `ConnectionGrace`.
     */
    @ViewBuilder
    private var empty: some View {
        if !model.connection.isLive && !model.showsConnectionNotice {
            ProgressView()
                .controlSize(.large)
                .tint(Theme.secondary)
                // The `ContentUnavailableView` below fills the space it is given;
                // a bare spinner does not, and would sit tucked under the address
                // bar with the rest of the screen empty beneath it.
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityIdentifier("localhost.loading")
        } else {
            settledEmpty
        }
    }

    private var settledEmpty: some View {
        ContentUnavailableView {
            Label(emptyTitle, systemImage: "globe")
        } description: {
            Text(emptyDetail)
        } actions: {
            if !model.connection.isLive && !model.connection.isTrying {
                Button("Try again") { model.resume() }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.accent)
            }
        }
        .accessibilityIdentifier("localhost.empty")
    }

    private var emptyTitle: String {
        if !model.connection.isLive { return model.connection.label }
        return "Nothing is listening"
    }

    private var emptyDetail: String {
        if !model.connection.isLive { return model.connection.detail }
        if !model.canBrowseLocalhost && !model.canUseDevServers {
            return "\(model.current?.label ?? "That machine") is running a version of the desktop "
                + "app that cannot share its ports with a phone."
        }
        return "Nothing on \(model.theMachine) is serving a page right now."
    }

    // MARK: - Actions

    private func open(port: Int, path: String = "/") {
        // The tap *is* the consent: no sheet asking whether to allow it, because
        // nothing was reachable until now and closing the page makes it
        // unreachable again.
        //
        // Through the store rather than straight at `openLocalhost`, so the page
        // lands in a tab and the strip above knows about it. The store is what
        // refuses a thirteenth tab and what hands back the *existing* tab when
        // this address is already open — five taps on the port 3000 row are one
        // page, not five.
        guard let tab = model.browserTabs.open(port: port, path: path, machine: model) else { return }
        browsingPath = tab.path
        currentTabID = tab.id
        browsing = model.browserTabs.tunnel(for: tab)
    }

    /// Go back to a tab from the strip. `resume` may have to re-open a tunnel
    /// the machine dropped while the page was parked, which is why it is not a
    /// plain `tunnel(for:)`.
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
     * The address bar. One field, and it decides where what you typed belongs.
     *
     * A port or a localhost address is a **tunnel**: the page loads in a real
     * `WKWebView` on a real loopback origin, so it gets cookies, service workers
     * and the WebSocket a dev server's hot reload runs on. That is the good path
     * and it is unchanged.
     *
     * Anything else — a site on the internet — used to be **refused**, with a
     * paragraph explaining that it would load on the phone rather than on the
     * machine. That was true and it was the wrong conclusion: the machine has a
     * browser, this app can already open a page in it (`web.open`) and can
     * already cast it back (`watch`). So a real URL opens *there* and appears on
     * the Browser tab's home, in the list of the machine's windows.
     *
     * ## Why it is shaped like the rows under it rather than like a search field
     *
     * The radius is the cards' 20 and the glyph is the row glyph — 19 point,
     * light, in the same 24-point column — so the bar's magnifier sits on the
     * same vertical line as every port's globe, and the two sections read as one
     * screen instead of as a control bolted above a list. It was 14-point radius
     * with a 13-point regular glyph, which is SF Symbols' default and therefore
     * what every iOS app that has not thought about it looks like: the exact
     * complaint the row icons were changed for.
     *
     * The height is fixed at 48 whether or not the clear button is there. Both
     * ends of the row carry the same 28-point box, so a field that grows a
     * button the moment somebody types does not also grow five points taller
     * under their thumb.
     */
    private var addressBar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 19, weight: .light))
                    .foregroundStyle(Theme.faint)
                    .frame(width: 24, height: 28)
                TextField("localhost:3000, or a site to open on the machine", text: $address)
                    .textFieldStyle(.plain)
                    // Every one of these is load-bearing: a URL keyboard puts
                    // the slash and the dot under a thumb, autocapitalisation
                    // would send "Localhost", autocorrect "local host", and the
                    // `.URL` content type stops iOS offering a contact's name.
                    .keyboardType(.URL)
                    .textContentType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.go)
                    .onSubmit(openTyped)
                    .font(.system(size: 15, design: .monospaced))
                    .foregroundStyle(Theme.primary)
                    .accessibilityIdentifier("browser.address")
                    .focused($addressFocused)
                if !address.isEmpty {
                    Button {
                        address = ""
                        addressNotice = nil
                    } label: {
                        // The glyph stays small and the target does not. A
                        // 14-point image is the whole hit area of a `Button` in
                        // SwiftUI, and 14 points is not something anybody hits
                        // on a moving train — 28 is the biggest box that leaves
                        // the bar the same height as an empty one.
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 15))
                            .foregroundStyle(Theme.faint)
                            .frame(width: 28, height: 28)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear")
                }
            }
            // Sixteen leading, so the glyph starts where a row's glyph starts:
            // the cards are inset 16 from the screen and their content another
            // 16 inside that. Ten trailing, because the clear button's own box
            // carries the other six.
            .padding(.leading, 16)
            .padding(.trailing, 10)
            .padding(.vertical, 10)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(Theme.hairline))

            if let addressNotice {
                Text(addressNotice)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.warning)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 8)
                    // Four, which is 20 from the screen edge once the outer
                    // padding is added — the column the section headers and the
                    // footnote sit in. This is a sentence *about* the screen
                    // rather than a row on it, and it lines up with the app's
                    // other ones instead of with the card above it.
                    .padding(.horizontal, 4)
                    .accessibilityIdentifier("browser.address.notice")
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 12)
    }

    /**
     * Open whatever is in the address field. There are three things it can be
     * and none of them is a dead end.
     *
     * > *"browsers should browse any normal Google or any web internet website
     * > also… So it shouldn't say that it cannot browse, because before I failed
     * > to browse. So this browser is not only for local, it is for internet
     * > also… So it should work seamless for everything."*
     *
     * The decision is `LocalhostAddress.classify` and it is not made here: it is
     * a pure function over a `String` with its own tests, because the same three
     * cases are typed into the `+` on the Browser tab's home and two copies of a
     * rule about what `google.com` means is how one of them ends up searching
     * for it.
     *
     * What is left for this function is the half that needs a machine in scope:
     * which capability each case needs, and what to say when the machine has not
     * got it.
     *
     *  - **A port** is a tunnel, in this phone's own web view. On a host that
     *    will not tunnel but will open pages, it opens *there* instead — the same
     *    act the port menu offers by name — rather than doing nothing.
     *  - **A page** and **a search** are the same verb with different words on
     *    the confirmation: `web.open`, which puts it in the machine's own
     *    browser. On a server that lands in the drive's own slot, which is a row
     *    of `browser.surfaces` — so it appears on the Browser tab's home and can
     *    be watched and driven. That is the whole of *"it will be actually
     *    browsing on the server side; here it will be presenting that."*
     *  - **A refusal** is a sentence about the line that was typed — a scheme
     *    this app will not open, a port out of range — and never about the
     *    machine's abilities.
     *
     * The field is cleared **only on success**, and a refusal leaves both the
     * text and the sentence under it: a mistyped address is one character away
     * from working, and a field that empties itself throws the other twenty
     * characters away to punish a typo.
     *
     * ## The refusal he hit, and why it is gone
     *
     * `CAPABILITY.web` is advertised only when `RemoteEndpointOptions.openUrl` is
     * a function — `src/main/remote/server.ts`, `if (name === CAPABILITY.web)
     * return typeof options.openUrl === 'function'` — and the headless host
     * passed none, so `canOpenPages` was false and this function printed a
     * sentence about a machine that could not open pages. The host passes one
     * now. The sentence survives for the case it was always true of, and it
     * names the command rather than describing a limitation, so somebody reading
     * it on a phone has something to do next.
     */
    private func openTyped() {
        let typed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !typed.isEmpty else { return }

        switch LocalhostAddress.classify(typed) {
        case let .tunnel(port, path):
            addressNotice = nil
            guard model.canBrowseLocalhost else {
                // The port is real and this phone cannot reach it. The machine
                // can, and opening it there is the same act the port menu offers
                // by name — so it is what the bar does rather than nothing.
                guard model.canOpenPages else {
                    addressNotice = "\(machineName) cannot put its own ports on a phone, and "
                        + "cannot open a page on its own screen either."
                    return
                }
                openThere("http://localhost:\(String(port))\(path)",
                          saying: "Opening on \(machineName)")
                return
            }
            open(port: port, path: path)

        case let .page(url):
            guard model.canOpenPages else {
                addressNotice = cannotOpenPages
                return
            }
            openThere(url, saying: "Opening on \(machineName)")

        case let .search(query, url):
            guard model.canOpenPages else {
                addressNotice = cannotOpenPages
                return
            }
            // The words rather than the URL, because the URL is a Google search
            // address and nobody reading a toast wants to parse one.
            openThere(url, saying: "Searching for \(query) on \(machineName)")

        case let .refused(why):
            addressNotice = why
        }
    }

    /// What this machine is called, in a sentence. Its own name when it has one,
    /// because somebody with two paired needs to know which one answered.
    private var machineName: String { model.current?.label ?? model.theMachine }

    /**
     * The one sentence about the machine rather than about the typed line.
     *
     * It names the command instead of describing a limitation, because the
     * remedy is real: a headless host grows this the moment it has a browser to
     * grow it with, and that is one command on the machine.
     */
    private var cannotOpenPages: String {
        "\(machineName) cannot open pages in a browser of its own yet"
            + (model.hostKind == .headless
               ? " — run \"\(Brand.id) browser install\" on it."
               : ".")
    }

    /**
     * Ask the machine to open a page on its own screen, and say so.
     *
     * The confirmation matters more here than anywhere else in the app: what
     * happens is a tab appearing on a screen in another room — or, on a server,
     * a row appearing on a screen one tap away — so without a sentence a press
     * that worked perfectly is indistinguishable from one that did nothing.
     */
    private func openThere(_ url: String, saying line: String) {
        addressNotice = nil
        model.openPageOnMachine(url)
        // Cleared, unlike a refusal: this went somewhere. What would be left in
        // the field is the address of a page that is already open over there.
        address = ""
        show(line)
    }

    private func beginRename(port: Int) {
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
        return "localhost:\(String(port)) on \(model.current?.label ?? "this machine")"
    }

    private func copyAddress(_ port: Int) {
        let address = "http://localhost:\(String(port))"
        UIPasteboard.general.string = address
        show("Copied \(address)")
    }

    /// Copying is silent by nature; without this the action feels broken even
    /// when it worked. Two and a half seconds, the same as the browser's.
    private func show(_ message: String) {
        withAnimation { toast = message }
        Task {
            try? await Task.sleep(for: .seconds(2.5))
            withAnimation { toast = nil }
        }
    }
}

/* -------------------------------------------------------------------------- */
/* Rows                                                                        */
/* -------------------------------------------------------------------------- */

/**
 * A section header that is also the fold control.
 *
 * The whole header is the hit target rather than the chevron beside it, because
 * a 13pt chevron is not a touch target and the row is already the shape of one.
 * The count is on it for the same reason the switcher carries a session count: a
 * folded group has to be worth opening before anybody opens it, and *"Other
 * services · 9"* answers that where *"Other services ›"* does not.
 */
private struct SectionToggle: View {
    let category: PortCategory
    let count: Int
    let folded: Bool
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 8) {
                Image(systemName: category.glyph)
                    .font(.system(size: 11, weight: .semibold))
                Text(category.title.uppercased())
                    .font(.system(size: 11, weight: .semibold))
                    .kerning(0.6)
                Text(String(count))
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Theme.faint)
                Spacer(minLength: 8)
                Image(systemName: folded ? "chevron.right" : "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
            }
            .foregroundStyle(Theme.secondary)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .textCase(nil)
        .listRowBackground(Theme.background)
        .listRowInsets(EdgeInsets(top: 8, leading: 20, bottom: 2, trailing: 20))
        .accessibilityIdentifier("localhost.section.\(category.rawValue)")
        .accessibilityLabel("\(category.title), \(count). \(folded ? "Folded" : "Open").")
    }
}

/**
 * A row whose body is one action and whose trailing corner is another.
 *
 * The same two-hit-target shape `MachineRow` and `DevServerRow` use, and for the
 * same reason: one of them is the thing you came to do and the other is the thing
 * you occasionally need. Written here rather than reused from either because both
 * of those bake in their own content.
 *
 * `identifier` lands on the **inner** button rather than on this stack, and that
 * is not a detail: `LocalhostUITests` finds a port with `app.buttons["port.3210"]`
 * and taps it. An identifier on the `HStack` describes a container that XCUITest
 * does not classify as a button, so the query matches nothing and the suite fails
 * with a sentence about a missing dev server.
 *
 * Named `SplitRow` and not `Button`, which is what it was called for about ten
 * minutes: a type called `Button` in this file shadows `SwiftUI.Button`
 * everywhere in it, so every ordinary button on the screen — the alert's Save,
 * the toolbar's refresh — silently resolves to this two-slot thing and fails to
 * compile with an error about a missing `trailing:` argument.
 */
private struct SplitRow<Label: View, Trailing: View>: View {
    let identifier: String
    let action: () -> Void
    @ViewBuilder let label: Label
    @ViewBuilder let trailing: Trailing

    var body: some View {
        HStack(spacing: 0) {
            Button(action: action) { label }
                .buttonStyle(PortRowButtonStyle())
                .accessibilityIdentifier(identifier)
            trailing
                .padding(.trailing, 4)
        }
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}

/**
 * One listening port.
 *
 * The identity of the row leads, and which string that is depends on whether
 * anybody has said. With no name the port number leads, mono, because it is what
 * somebody typed into their terminal and will type again — that is the row this
 * screen has always drawn. With a name, the name leads and the address drops to
 * the line underneath beside the process, so the thing he could not tell apart
 * — four rows of `wslrelay` — becomes four different rows without losing what
 * they are.
 */
private struct PortRow: View {
    let entry: LocalPort
    let name: String?

    var body: some View {
        HStack(spacing: 12) {
            // The app's row glyph: monoline at 19, in a 24-point column. It was
            // 15 at regular weight, which is SF Symbols' default and the reason
            // the icons were changed everywhere else — and it left this section
            // three points out of line with the address bar above, on a screen
            // whose whole claim is that the two are one list. See `DeckTabs` for
            // the argument and the two apps it came from.
            Image(systemName: name == nil ? "globe" : "tag.fill")
                .font(.system(size: 19, weight: .light))
                .foregroundStyle(name == nil ? Theme.secondary : Theme.accent)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 3) {
                if let name {
                    Text(name)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Theme.primary)
                        .lineLimit(1)
                } else {
                    Text("localhost:\(String(entry.port))")
                        .font(.system(size: 15, weight: .medium, design: .monospaced))
                        .foregroundStyle(Theme.primary)
                        .lineLimit(1)
                }

                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(Theme.faint)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .accessibilityIdentifier("port.detail.\(String(entry.port))")
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.leading, 16)
        .padding(.vertical, 13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    /**
     * The second line: whatever is left that identifies the row.
     *
     * A named row needs the address back, because the name replaced it. An
     * unnamed row already leads with the address, so the process is the only
     * thing left to say — and it is omitted rather than guessed at when the
     * machine could not name it, which is what `guessed` means.
     */
    private var subtitle: String? {
        let address = "localhost:\(String(entry.port))"
        if name != nil {
            return entry.guessed ? address : "\(address)  ·  \(entry.process)"
        }
        return entry.guessed ? nil : entry.process
    }
}

/// The card's press state. `.plain` would leave a row that opens a page looking
/// identical before, during and after a press — the same trade `SessionListView`
/// and `MachinesView` make, with the corner radius they use.
private struct PortRowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .overlay {
                // See `RowButtonStyle`: a white wash is invisible on paper, so
                // this is the ink tint that flips with the appearance.
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(configuration.isPressed ? Theme.pressed : .clear)
            }
            .scaleEffect(configuration.isPressed ? 0.99 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}
