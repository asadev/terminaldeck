/**
 * Where this phone has been on one machine, and the way back to any of it.
 *
 * *"search history and cookies and all of this. Everything that Mac side had."*
 *
 * The store behind it is `BrowserHistory`, and its header carries the argument
 * for why a visit is a port and a path rather than a URL string. This file is
 * the screen: a searchable list of pages, newest first, where a tap hands the
 * caller a port and a path and a swipe forgets a row.
 *
 * ## It cannot open anything, and that is deliberate
 *
 * Opening a page needs a tunnel — `tunnel.open` on the wire, a listener bound on
 * this phone's loopback, a `PortTunnel` held alive for exactly as long as the
 * page is up — and every one of those things belongs to `LocalhostPortsView`,
 * which owns `browsing` and closes it again when the page is popped. A history
 * screen that dialled its own tunnel would be a second owner of the same socket
 * and the two would disagree about when to close it.
 *
 * So this hands back a choice and dismisses, the way `FolderPickerView` hands
 * back a folder and lets the caller decide what starting one means. The pair it
 * returns is exactly the pair `LocalhostPortsView.open(port:path:)` takes.
 *
 * ## One machine's history, said out loud
 *
 * The store is keyed per machine because a port number means nothing on its own,
 * and a screen that quietly showed one machine's rows while another was
 * connected would offer a tap that opens something else entirely. This screen is
 * therefore about the machine named in `machine`: it says so in the footnote,
 * and Clear says so in the sentence it asks before it does anything.
 *
 * ## Search is the platform's, even though the address bar next door is not
 *
 * `LocalhostPortsView` draws its own address bar, and the reasoning there is
 * sound — it is an *address* bar, it needs a URL keyboard with autocorrect off,
 * and it is content sitting above a list rather than chrome. None of that is
 * true here. A field that filters the list under it is precisely what
 * `.searchable` is, and taking the platform's one buys the scroll-to-reveal, the
 * Cancel button, the keyboard dismissal and the placement every other iOS app
 * uses — the same trade `LocalhostBrowser` made when it gave the navigation bar
 * back to the system.
 */

import SwiftUI

struct BrowserHistoryView: View {
    /// Which machine's history this is — `DeckEndpoint.hostId`, the same key
    /// `PortBook` stores names against.
    let host: String
    /// What to call that machine in a sentence. A name rather than "the
    /// machine", because somebody with two paired needs to know which one they
    /// are about to clear — the same reason `ArchivedSessionsView` takes one.
    let machine: String
    /// Injected rather than reached for, so a preview or a test can hand in a
    /// store of its own. See `PortBook` for why this can be a default argument.
    var history: BrowserHistory = .shared
    /// Called with the port on the machine and the path to ask it for. The
    /// caller opens it — this screen has no tunnel and cannot.
    let chose: (Int, String) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var query = ""
    @State private var clearing = false

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.background.ignoresSafeArea()
                content
            }
            .navigationTitle("History")
            .navigationBarTitleDisplayMode(.inline)
            // Always on show rather than hidden until the list is dragged down.
            // A history is searched far more often than it is scrolled — that is
            // the whole reason the store keeps two hundred rows and the screen
            // does not paginate — so the field it is searched with should not be
            // something people have to discover.
            .searchable(text: $query,
                        placement: .navigationBarDrawer(displayMode: .always),
                        prompt: "Search history")
            // An address is not a sentence: capitalising it sends `Localhost`
            // and correcting it sends `local host`, neither of which matches a
            // single row. The same three lines the address bar next door carries
            // for the same reason.
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .accessibilityIdentifier("history.done")
                }
                /*
                 * Clear, along the bottom and at the leading end — where Safari
                 * has kept it for as long as Safari has had a history screen,
                 * and the same argument `LocalhostBrowser` made for moving its
                 * own controls down there: this is a browser, and iOS puts a
                 * browser's controls at the bottom of the phone.
                 *
                 * Drawn only when there is something to clear. A permanently
                 * disabled button on an empty screen is chrome pretending to be
                 * a control.
                 */
                if !all.isEmpty {
                    ToolbarItemGroup(placement: .bottomBar) {
                        Button("Clear", role: .destructive) { clearing = true }
                            .accessibilityIdentifier("history.clear")
                        Spacer()
                    }
                }
            }
            /*
             * It asks, and the sentence names the machine.
             *
             * Clearing cannot be undone and it is the one control on this screen
             * that touches more than one row — but the reason it asks is
             * narrower than that: the store is keyed per machine, so this wipes
             * *this* machine's rows and leaves the others standing. Somebody who
             * believes they have just cleared their browsing history and has not
             * is worse off than somebody who was asked a question.
             */
            .confirmationDialog("Clear the history for \(machine)?",
                                isPresented: $clearing,
                                titleVisibility: .visible) {
                Button("Clear it", role: .destructive) { history.clear(host: host) }
                Button("Keep it", role: .cancel) {}
            } message: {
                Text("Only this machine's pages are forgotten, and only on this phone. "
                     + "Nothing on \(machine) changes, and you stay signed in to anything "
                     + "you were signed in to.")
            }
        }
    }

    // MARK: - What is on the screen

    /// Everything, for the two decisions that are about the history rather than
    /// about the search: whether to draw a Clear at all, and which of the two
    /// empty states is the true one.
    private var all: [BrowserHistory.Visit] { history.visits(host: host) }

    private var rows: [BrowserHistory.Visit] { history.visits(host: host, matching: query) }

    /**
     * Two empty states, because they are two different facts.
     *
     * *Nothing has been opened yet* is about the machine and needs the sentence
     * that says how a row gets here. *Nothing matches* is about the four
     * characters somebody just typed, and the platform already writes that one —
     * with the search text in it, which is the half that makes it read as an
     * answer rather than as a broken screen.
     */
    @ViewBuilder
    private var content: some View {
        if all.isEmpty {
            empty
        } else if rows.isEmpty {
            ContentUnavailableView.search(text: query)
        } else {
            list
        }
    }

    private var list: some View {
        List {
            ForEach(rows) { visit in
                Button {
                    // The caller opens it. This screen goes away first so the
                    // page it asked for arrives on the screen underneath rather
                    // than behind a sheet nobody dismissed.
                    chose(visit.port, visit.path)
                    dismiss()
                } label: {
                    HistoryRow(visit: visit)
                }
                .buttonStyle(RowButtonStyle())
                .accessibilityIdentifier("history.row.\(visit.id)")
                .plainRow()
                /*
                 * Orange, not red, and the app has already settled why.
                 *
                 * `SessionListView` reserves red for the one thing that ends
                 * work on the machine and gives orange to Archive, which changes
                 * nothing but this phone's own list. Forgetting a row is the
                 * second kind: the page is still there, still being served, and
                 * opening it again puts the row straight back. Red here would be
                 * this screen claiming a weight it does not have.
                 *
                 * Tinted explicitly because an ambient `.tint` wins over a
                 * swipe button's own colour — the bug that once rendered a blue
                 * Close beside an orange Archive, and was only ever visible in a
                 * screenshot.
                 *
                 * `allowsFullSwipe: false`, as on every other list in this app.
                 * There is one action here and finishing it by accident is
                 * cheap, but a gesture that behaves differently on two screens
                 * is a gesture nobody trusts.
                 */
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    Button {
                        history.forget(visit, host: host)
                    } label: {
                        Label("Forget", systemImage: "eraser.fill")
                    }
                    .tint(Theme.warning)
                    .accessibilityIdentifier("history.swipe.forget.\(visit.id)")
                }
            }

            footnote.plainRow(top: 18, bottom: 28)
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .environment(\.defaultMinListRowHeight, 0)
    }

    private var empty: some View {
        ContentUnavailableView {
            Label("Nothing opened yet", systemImage: "clock.arrow.circlepath")
        } description: {
            Text("Pages you open on \(machine) are remembered here, so you can get back to one "
                 + "without knowing which port it was on.")
        }
        .accessibilityIdentifier("history.empty")
    }

    /**
     * The honest sentence at the foot, and it is the same kind
     * `ArchivedSessionsView` ends with.
     *
     * The risk this screen carries is somebody assuming it is the machine's
     * browsing history — that what they open from the sofa is being written down
     * on their Mac, or that clearing this clears something over there. Neither is
     * true and neither could be: nothing in this feature is on the wire. So the
     * screen says which phone the list belongs to, in the place people arrive
     * when they wonder where a row came from.
     */
    private var footnote: some View {
        Text("This list is on this phone only, and it is \(machine)'s pages alone. Nothing here "
             + "was sent to \(machine), and clearing it leaves that machine's own browser "
             + "untouched.")
            .font(.system(size: 12))
            .foregroundStyle(Theme.faint)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 4)
            .accessibilityIdentifier("history.footnote")
    }
}

/**
 * One page that was open.
 *
 * The same shape as `PortRow` one screen over, and for the same reason it is
 * shaped that way: the identity of the row leads, and which string that is
 * depends on whether the page ever said. A page with a title leads with it and
 * drops the address to the line underneath; a page that never got as far as a
 * title leads with the address in mono, which is the row `PortRow` draws for an
 * unnamed port and therefore something this app's user has already learned to
 * read.
 *
 * The glyph is a globe rather than a clock. Every row on this screen is a page
 * on the machine — the same thing the port rows are — and a clock repeated
 * eighty times would spend the icon column saying what the title bar already
 * says once.
 */
private struct HistoryRow: View {
    let visit: BrowserHistory.Visit

    var body: some View {
        HStack(spacing: 12) {
            // The app's row glyph: monoline at 19, in a 24-point column. See
            // `PortRow` for the argument and the two apps it came from.
            Image(systemName: "globe")
                .font(.system(size: 19, weight: .light))
                .foregroundStyle(Theme.secondary)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 3) {
                if visit.title.isEmpty {
                    Text(visit.address)
                        .font(.system(size: 15, weight: .medium, design: .monospaced))
                        .foregroundStyle(Theme.primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                } else {
                    Text(visit.title)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Theme.primary)
                        .lineLimit(1)

                    Text(visit.address)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(Theme.faint)
                        .lineLimit(1)
                        // From the middle, uniquely on this screen. Elsewhere a
                        // URL is truncated from the head because the scheme is
                        // eleven identical characters — but these addresses have
                        // had the scheme taken off already, so both ends carry
                        // something: the port says *which server* and the tail
                        // says *which page*. Losing either turns two rows into
                        // one.
                        .truncationMode(.middle)
                }
            }

            Spacer(minLength: 8)

            /*
             * When, in the platform's words rather than in ours.
             *
             * `ServerDetailView` has a hand-rolled `ago` and it is a perfectly
             * good six lines; a second copy here would be the third place in
             * this app that decides what *an hour ago* is called, and the first
             * one to disagree would be a bug nobody would think to look for.
             * `.relative` is Foundation's, it is localised, and this screen has
             * no opinion worth having about the wording.
             */
            Text(visit.at.formatted(.relative(presentation: .named)))
                .font(.system(size: 12))
                .foregroundStyle(Theme.faint)
                .lineLimit(1)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
}
