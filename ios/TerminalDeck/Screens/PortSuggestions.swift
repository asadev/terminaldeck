/**
 * The addresses this machine is already serving, offered where an address is
 * being chosen — inside the sheet that opens a window, and nowhere else.
 *
 * ## Why there is no longer a Localhost screen
 *
 * There was one, and it was the second of the two pages he was pointing at:
 *
 * > *"When we come to the browser page — now here you still kept localhost as a
 * > separate page inside the page, and the browser as a separate page in the
 * > page. So I wanted it to be like ONE page where I can start a new window."*
 *
 * The round before this had moved localhost off the Browser tab's home and
 * behind its `…` as a pushed screen of its own, on the strength of his earlier
 * *"even the localhost thing should be folded somewhere else."* Folded somewhere
 * else it was — into a **second browser**: that screen had its own address bar,
 * its own strip of open tabs, its own history and its own site-data screens, so
 * the Browser tab was two browsers with a menu between them. Fold and *separate
 * page* turned out to be different things, and this is him saying which one he
 * meant.
 *
 * ## So what is a port, once there is only one page?
 *
 * It is an **address**, and nothing else. `localhost:3000` is a thing you type
 * into an address bar; a list of them is a list of suggestions for that bar. It
 * is not a second list of windows and it is not a settings screen, and both of
 * those are what it had grown into.
 *
 * So the ports are here: under the field in the one place a window is started,
 * as the addresses this machine can offer. Tapping one is the same act as typing
 * it, which is the test that says this is the right place for it — the row and
 * the field do the same thing to the same destination, and neither is a mode.
 *
 * ## Nothing the old screen carried was dropped, and here is where each went
 *
 *  - **The names.** `PortBook` is unchanged, the rename alert is raised by the
 *    sheet (an alert attached inside a `List` that redraws on every `ports`
 *    frame is an alert that dismisses itself — see `NewWindowSheet`), and a
 *    named port is still promoted to the top group. Naming a suggestion is the
 *    one gesture that changes what a list of forty numbers is worth.
 *  - **The groups.** `PortCatalog.sections` is unchanged and so are the three
 *    that start folded. A sheet is a smaller space than a screen, which makes
 *    the folding matter more rather than less.
 *  - **The dev servers.** A project whose server is not up is still a row with a
 *    Start on it, joined to its own port row once it is. The port list can only
 *    ever say what is *already* running, and half of choosing an address is
 *    starting the thing that will answer it.
 *  - **The tunnel** — a page loaded in this phone's own web view, on a real
 *    loopback origin, with cookies and the WebSocket a hot reload runs on — is
 *    the sheet's third destination. It is a choice about *where the window
 *    opens*, which is exactly what that sheet is for, and it stopped needing a
 *    screen of its own the moment it became one.
 *  - **This phone's own browser chrome** — its history, its site data, its saved
 *    logins — went to the Browser tab's `…`, where it was before the localhost
 *    screen existed. All three are settings about this phone's web view; none of
 *    them is a page, and none of them belongs in the flow that opens one.
 *
 * ## Why this is a `List` inside a sheet
 *
 * Swipe actions. *"we can swipe them left and right and we can have options
 * there to delete or close the options or archive and things, just like WhatsApp
 * has the chats."* `.swipeActions` exists only inside a `List`, and a hand-rolled
 * drag is a swipe that is not the system's — no rubber band at the limit, a
 * different depth from every other app on the phone. The cards survive it: the
 * row background is cleared and the fill comes from the row's own rounded
 * surface.
 */

import SwiftUI
import UIKit

struct PortSuggestions: View {
    let model: DeckModel
    /// The phone's own names for these ports. Injected rather than reached for,
    /// so a preview or a test can hand in a store of its own.
    var book: PortBook = .shared

    /**
     * A port was chosen. The **sheet** decides what that means — a window in the
     * machine's own browser, an isolated one, or a tunnel into this phone's web
     * view — because that is the question its destination control answers.
     *
     * This view deliberately does not know. A suggestion list that decided where
     * its own rows opened would be a second opinion about the thing the control
     * above it is for, and two answers to one question is how the old screen and
     * the old sheet came to disagree about what a port meant.
     */
    let choose: (Int, String) -> Void

    /// The row menu's alternative: what the *other* destination is called and
    /// what it does. Nil when there is only one place a port can go — a machine
    /// that will not tunnel, or one that will not open pages of its own.
    let otherWay: (label: String, act: (Int) -> Void)?

    /// Raise the rename alert for a port. Owned by the sheet for the reason its
    /// own comment gives.
    let rename: (Int) -> Void

    /// Say something happened that leaves nothing on screen — a copy.
    let said: (String) -> Void

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

    var body: some View {
        if sections.isEmpty { empty } else { list }
    }

    /**
     * **One list, no headings.**
     *
     * > *"this other services and web services should not be like separate lists,
     * > it should be one list — we can just see here they are, inside the pill,
     * > like it is SSH, Python, whatever it is, node or what."*
     *
     * The grouping was answering a question the rows already answer. Every row
     * carries the process that is holding the port under its address — `node`,
     * `python3`, `ssh` — so *Web servers 5 ›* above four `node` rows and *Other
     * services 1 ›* above one `ssh` row was the same fact printed twice, once as
     * a heading and once per row, and it cost two chips, two counts, two
     * chevrons and a fold state per machine to print it the second time.
     *
     * The **order** is what the categories are still for, and that survives:
     * `PortCatalog.sections` hands them back most-interesting first — named,
     * dev servers, web servers, the app itself, other, unidentified — so the
     * flattening keeps that ranking and simply stops drawing a line between the
     * bands. Noise sinks rather than hides, which is the better half of what the
     * folding was doing anyway.
     */
    private var list: some View {
        List {
            Section {
                ForEach(sections.flatMap(\.rows)) { row in
                    rowView(row)
                }
            }

            footnote
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        // Rendered first at the default, which put 55 points between one group's
        // last row and the next group's header — on a list whose whole purpose is
        // fitting more of a long one into a glance, three folded groups ate a
        // third of the space. Fourteen is the gap the session list's cards
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
                             openPort: { choose($0, "/") },
                             openSession: { model.open(session: $0) })
            } else if let entry = row.entry {
                SplitRow(identifier: "port.\(String(entry.port))") {
                    choose(entry.port, "/")
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
                    rename(port)
                } label: {
                    Label(row.name == nil ? "Name" : "Rename", systemImage: "pencil")
                }
                .tint(Theme.accent)
                .accessibilityLabel(row.name == nil ? "Name this port" : "Rename this port")
                .accessibilityIdentifier("port.swipe.rename.\(String(port))")
            }
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
             * and only by default. This list sits under the app's accent, an
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
     *
     * The first item is the **other** destination, and it is the one thing on
     * this menu that is not about this phone's own bookkeeping. It exists because
     * the sheet's control is a setting and this is a one-off: somebody opening
     * everything on the machine still occasionally wants one page in the phone's
     * own web view, and changing the control and changing it back is three taps
     * to the menu's one. It is never the same act as tapping the row — that would
     * be a menu item that duplicates the thing it hangs off.
     */
    private func portMenu(entry: LocalPort, named: Bool) -> some View {
        Menu {
            if let otherWay {
                Button {
                    otherWay.act(entry.port)
                } label: {
                    Label(otherWay.label, systemImage: "arrow.up.forward.app")
                }
                .accessibilityIdentifier("port.menu.otherWay")
            }

            Button {
                rename(entry.port)
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
     * Nothing to suggest, and which of the four reasons it is.
     *
     * A machine that does not offer the capability at all is a different fact
     * from one that offers it and is serving nothing, and both are different from
     * a socket that is down — saying "nothing is running" over a dead connection
     * is a claim nobody checked.
     *
     * ## And a fourth, which says nothing at all
     *
     * The first seconds of a launch. This list read `connection.isLive`, so it
     * opened on the word **Connecting** every single time — the first frame of a
     * launch is `.offline` and the second is `.connecting` — which is the
     * yellow-thing complaint written larger: *"let it give a few seconds; after
     * five seconds if it is still not connected, then show. Otherwise it will
     * just load, so they will not even feel that it takes time for connecting."*
     *
     * `showsConnectionNotice` is the one property that rule lives in.
     * `SessionListView` puts its banner, its pill and its empty state all on it
     * so the three cannot drift. A spinner until the grace period is over, and
     * the honest sentence after it. See `ConnectionGrace`.
     */
    @ViewBuilder
    private var empty: some View {
        if !model.connection.isLive && !model.showsConnectionNotice {
            ProgressView()
                .controlSize(.large)
                .tint(Theme.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityIdentifier("localhost.loading")
        } else {
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
        return "Nothing on \(model.theMachine) is serving a page right now. Type an address above."
    }

    private func copyAddress(_ port: Int) {
        let address = "http://localhost:\(String(port))"
        UIPasteboard.general.string = address
        said("Copied \(address)")
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
 *
 * ## It is a chip now, and not a grey line across the sheet
 *
 * > *"these buttons down there are also like old type of styling I think this
 * > styling can be much better."*
 *
 * He said it about the foot of the New window sheet, in the same twelve minutes
 * as the same complaint in more words about the bar under a page: *"this bar
 * looks like very classic style and old and not according to the overall design
 * system… maybe a smooth cool beautiful box maybe round corners or something
 * which looks like latest shapes and overall applications design system."* The
 * bar became one inset card in that round. These were left as they were, and they
 * were the last thing on this sheet still drawn in the platform's plain-list
 * register: a grey uppercase label stretched from margin to margin with a bare
 * chevron pinned to the far end — the shape iOS gives a `Section` header, which
 * is a **caption**, over a stack of them that are **controls**.
 *
 * That mismatch is the whole defect and it is not only a matter of taste. A
 * label that folds a group is a control, and nothing about the old drawing said
 * so: no fill, no edge, nothing that moves under a thumb, and the one glyph that
 * hinted at it sitting 300 points away from the words it belonged to. Three of
 * these groups **start folded**, so on most machines the first thing this sheet
 * asks somebody to find is a control it had drawn as a caption.
 *
 * So it hugs its own words instead of spanning the sheet, it sits on a raised
 * surface with a 14-point corner and a hairline, and it presses. That is the
 * app's own character everywhere else — *tinted ground, floating cards, 20pt
 * radii, monoline icons* — at the size a header can carry: the rows under it are
 * 20-point cards on the same ground, and a chip a third of their width cannot be
 * mistaken for one of them.
 *
 * ## What was kept exactly, and why each one had to be
 *
 *  - **The identifier.** `localhost.section.<category>` is pressed by name in
 *    `LocalhostGroupingUITests`, tapped by the three suites that photograph this
 *    sheet (`ReviewScreensUITests`, `AppearanceShotsUITests`,
 *    `ReleaseShotsUITests` all open every folded group before the shutter), and
 *    asserted **absent** from the Browser tab's home by `MachineBrowserUITests`.
 *    A renamed identifier is a case that skips instead of failing.
 *  - **A `Button`.** Those suites ask for `app.buttons["localhost.section.other"]`
 *    and tap it; anything XCUITest does not classify as a button is a query that
 *    matches nothing and a fold that is never exercised. `SectionChipButtonStyle`
 *    is a `ButtonStyle` — it changes what a button looks like when pressed and
 *    nothing about what it is — which is why the press state could be added
 *    without touching that.
 *  - **The spoken label,** *"Other services, 9. Folded."* — `LocalhostGroupingUITests`
 *    asserts the word **Open** appears in it after a tap, which is how it knows
 *    the fold landed rather than merely that a tap was accepted.
 *  - **The words and the count.** Nothing is said differently; this is the round
 *    where *"simplify" means reorganize, never delete* is about pixels.
 *
 * The count moved inside a tinted capsule — `MachineWindowMark`'s shape, the same
 * word-in-a-capsule the Browser tab's rows wear — rather than being given a
 * second grey to be told apart by, and it keeps its monospace, which is where
 * this app's terminal character comes from and the reason `9` and `12` line up
 * down a column of headers.
 */
private struct SectionToggle: View {
    let category: PortCategory
    let count: Int
    let folded: Bool
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 8) {
                // Monoline, and one weight lighter than the words beside it: a
                // filled 11-point glyph at semibold is a blob at this size. The
                // same treatment the row glyphs in this file were given.
                Image(systemName: category.glyph)
                    .font(.system(size: 12, weight: .regular))
                    .foregroundStyle(Theme.secondary)
                // Exactly `SchemeSectionCaption`'s type — 11, semibold, kerned
                // 0.6 — because that caption is drawn twice on this same sheet,
                // over **Open in** and over **Address**, and a third heading
                // family a hundred points below them is how one sheet comes to
                // look like two.
                Text(category.title.uppercased())
                    .font(.system(size: 11, weight: .semibold))
                    .kerning(0.6)
                    .foregroundStyle(Theme.secondary)
                // `MachineWindowMark`'s shape — 11 semibold in a tinted capsule
                // at radius 5 — drawn here rather than reused, for the one
                // difference that matters: the digits stay **monospaced**, so a
                // column of headers reading 5, 9 and 12 lines up instead of
                // drifting a point per glyph. `String(count)` and never the `Int`
                // interpolated: a number dropped into a Swift string is formatted
                // with the locale's grouping separator, and a machine with a
                // thousand ports open would say `1,000`.
                Text(String(count))
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Theme.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Theme.secondary.opacity(0.14),
                                in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                Image(systemName: folded ? "chevron.right" : "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Theme.faint)
                    // Held to the width of the wider of the two glyphs, so the
                    // chip does not change size by a point and a half each time
                    // somebody folds it.
                    .frame(width: 12)
            }
            .padding(.leading, 12)
            .padding(.trailing, 10)
            .padding(.vertical, 8)
            .background(Theme.surfaceHigh,
                        in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Theme.hairline, lineWidth: 0.5))
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(SectionChipButtonStyle())
        // Leading rather than filling the row: the chip is the control and the
        // space beside it is the sheet's ground, which is what stops a header
        // from reading as one more card in the list under it.
        .frame(maxWidth: .infinity, alignment: .leading)
        .textCase(nil)
        .listRowBackground(Theme.background)
        .listRowInsets(EdgeInsets(top: 10, leading: 20, bottom: 4, trailing: 20))
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

/**
 * The chip's press state, at the chip's own radius.
 *
 * `.plain` is what the header wore, and a `.plain` button is one that looks
 * identical before, during and after a press — which on a control that had no
 * fill and no edge either meant nothing on this sheet ever said *this word is a
 * button*. It is `PortRowButtonStyle`'s trade at 14 points instead of 20: the
 * ink tint rather than a white wash, because a white wash over a near-white
 * surface is invisible on paper, and a scale small enough to feel rather than
 * see. See `RowButtonStyle`.
 */
private struct SectionChipButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(configuration.isPressed ? Theme.pressed : .clear)
            }
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
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
