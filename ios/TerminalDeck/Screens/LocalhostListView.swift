/**
 * Everything the machine is serving, and everything it could serve, on one
 * screen that is not a wall.
 *
 * Asad, opening the phone app: *"I can already see a big list of local hosts. So
 * it should not be like that… we need to fold it in a better way"*, and then the
 * three things that would fix it — rename them, categorise them, and *"I don't
 * see any kind of option here to make anyone up or make anyone activated"*.
 *
 * The list he was looking at was rendered inline underneath the sessions, every
 * row a process name: `localhost:2019 wslrelay`, `localhost:2222 wslrelay`,
 * `localhost:3100 wslrelay`, `localhost:6666 AgentService`. It is its own screen
 * now, and three things happen to it on the way here.
 *
 * ## 1. It is grouped, from facts
 *
 * `PortCatalog` holds the rules and the reasoning. The short version is that
 * every group is derived from something the wire carries — a process name, a
 * proven dev-server port, the socket this phone is connected on — and the three
 * groups that are noise start folded rather than hidden.
 *
 * ## 2. Rows can be named, and naming one promotes it
 *
 * `PortBook` holds the names, on this phone, against the machine and the port.
 * A named port is lifted to the top group, which is the whole of *"we can keep
 * some in the list and we can keep some folded"* — one gesture, one meaning.
 *
 * ## 3. The dev servers are here too, and they are the Start button
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

struct LocalhostListView: View {
    let model: DeckModel
    /// The phone's own names for these ports. Injected rather than reached for,
    /// so a preview or a test can hand in a store of its own.
    var book: PortBook = .shared

    /// The tunnel the browser is showing. Set by a tap and by nothing else,
    /// which is what makes the tap the consent — see `ClientMessage.tunnelOpen`.
    @State private var browsing: PortTunnel?

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

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()

            if sections.isEmpty {
                empty
            } else {
                list
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
             * The same control the session list puts in its title, and for the
             * same reason: these are *one machine's* ports, and with several
             * paired that is not a question this screen may leave open. It also
             * carries the connection pill, so a list that has gone stale says so
             * here rather than only on the tab next door.
             *
             * With a single machine it falls back to the screen's own name
             * rather than the product's — see `HostSwitcher.singleHostTitle`.
             */
            ToolbarItem(placement: .principal) {
                HostSwitcher(model: model, singleHostTitle: "Localhost")
            }
            ToolbarItem(placement: .topBarTrailing) {
                SwiftUI.Button {
                    model.refresh()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(!model.connection.isLive)
                .accessibilityLabel("Refresh")
                .accessibilityIdentifier("localhost.refresh")
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
            LocalhostBrowser(model: model, tunnel: tunnel) { browsing = nil }
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
         * mid-presentation is an alert that closes itself. One alert, at the top,
         * holding the port it is about.
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
            if let port = row.port {
                Button {
                    beginRename(port: port)
                } label: {
                    Label("Rename", systemImage: "pencil")
                }
                .tint(Theme.accent)
                .accessibilityIdentifier("port.swipe.rename.\(String(port))")
            }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            secondAction(row)
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
            .tint(Theme.surfaceHigh)
            .accessibilityIdentifier("devserver.swipe.session.\(row.dev?.folder ?? id)")

        case let .copyAddress(port):
            Button {
                copyAddress(port)
            } label: {
                Label("Copy", systemImage: "doc.on.doc")
            }
            .tint(Theme.surfaceHigh)
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
     * The one paragraph on the screen, and it is one sentence.
     *
     * Asad on the desktop's settings, in the same recording: *"we don't need this
     * much of big descriptions under each."* What earns a line here is the rule
     * nothing else on screen states — that naming a port is what moves it up —
     * because a folded group is otherwise a thing somebody has to discover twice.
     */
    private var footnote: some View {
        Text("Groups are worked out from the process holding each port. Naming one moves it to "
             + "the top of the list.")
            .font(.system(size: 12))
            .foregroundStyle(Theme.faint)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 14)
            .padding(.bottom, 24)
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 20))
            .accessibilityIdentifier("localhost.footnote")
    }

    /**
     * Nothing to show, and which of the three reasons it is.
     *
     * A machine that does not offer the capability at all is a different fact
     * from one that offers it and is serving nothing, and both are different from
     * a socket that is down — saying "nothing is running" over a dead connection
     * is a claim nobody checked.
     */
    private var empty: some View {
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
        return "Nothing on the \(model.hostPlatform.noun) is serving a page right now."
    }

    // MARK: - Actions

    private func open(port: Int) {
        // The tap *is* the consent: no sheet asking whether to allow it, because
        // nothing was reachable until now and closing the page makes it
        // unreachable again.
        browsing = model.openLocalhost(port: port)
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
/* Rows and chrome                                                             */
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
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
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
            Image(systemName: name == nil ? "globe" : "tag.fill")
                .font(.system(size: 15))
                .foregroundStyle(name == nil ? Theme.secondary : Theme.accent)
                .frame(width: 18)

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
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.white.opacity(configuration.isPressed ? 0.06 : 0))
            }
            .scaleEffect(configuration.isPressed ? 0.99 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}
