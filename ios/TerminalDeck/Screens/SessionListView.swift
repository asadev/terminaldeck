/**
 * The Sessions tab: the sessions on the machine, and only those.
 *
 * It used to be the whole app, and the `…` in its corner used to be the only way
 * to reach anything that was not a session. It is one of four tabs now and that
 * menu holds one item — see `DeckTabs.swift` for where the other eight went.
 *
 * ## What left this screen
 *
 * **The ports and the dev servers.** They were two more sections under the
 * sessions, they were longer than the sessions on any real machine, and a
 * heading is not a separation: *"I can already see a big list of local hosts. So
 * it should not be like that… no separate two lists already here and no
 * separation here… Sessions separately and local host separately in the pill
 * side so we know to go to the section."* They are the Localhost tab —
 * `LocalhostListView` — which also owns the page a tap opens.
 *
 * **The copilot row**, pinned above the sessions, which is a pill of its own
 * now: *"a fourth pill, and the copilot goes leftmost."* Its badge went to the
 * pill with it. See `CopilotView`.
 *
 * **Refresh and Reconnect**, which he asked about by name and which turned out
 * to be a duplicate of the pull gesture and an admission that the transport
 * might not reconnect by itself. The evidence for both verdicts is written where
 * the menu is built, below.
 *
 * The one thing that had to be checked in each of those moves is the empty
 * state, which counted the other rows as *something to show* so that a machine
 * with no sessions did not draw "No sessions" over the top of them. With them
 * gone the test is the sessions and nothing else again — except for the one
 * thing that is genuinely new, which is that this phone can now hide sessions
 * from itself.
 *
 * ## Which buttons exist is decided by the wire, not by the design
 *
 * Protocol v1 carries list, attach, input and resize. A desktop that speaks only
 * that gets a list and nothing else — the New Session button is not
 * greyed out, it is absent, because `parseClientMessage` closes the socket on a
 * verb it does not know and a disabled button for a thing the far end can never
 * do is just a smaller lie. It appears when a desktop advertises `create` in its
 * `welcome`. See `WireCapability`.
 *
 * The same rule now decides *where* a session may be started. `welcome.folders`
 * is the list of folders a person granted this particular device on that
 * machine, and the desktop enforces the same array it sends — so the picker
 * offers what will work rather than what this phone could see. A machine that
 * granted nothing gets no button at all and a sentence saying where to fix it.
 *
 * ## The connection pill is the most important thing on this screen — and most
 * of the time it is not on it
 *
 * Every other element assumes the list is current. When it is not, the pill is
 * the only thing saying so, and it says which of the six ways it is not current —
 * connecting, waiting, pending approval, offline — rather than going grey.
 *
 * What changed is *when* it is allowed to say that. A connected phone shows
 * nothing, a launch shows nothing while it dials, and a drop shows nothing for
 * its first five seconds; only an outage that is actually in the person's way
 * gets a pill and a bar. `ConnectionGrace` is the rule and the reasoning, and it
 * is his, in his words. The three places this screen used to key off
 * `connection.isLive` — the pill, the warning bar and the empty state — all read
 * `showsConnectionNotice` now, so they cannot drift apart.
 *
 * ## Space, not lines
 *
 * The rows used to be separated by hairlines. They are cards with gaps now, for
 * the reason the design brief gives: whitespace is the layout tool and a divider
 * is what you reach for when space cannot do the job. Here it can.
 */

import SwiftUI
// For `ConnectionAccessibility` at the foot of this file, which is a `UIView`
// on purpose — see `ConnectionPill`.
import UIKit

struct SessionListView: View {
    let model: DeckModel

    /// What this phone has put away and what it has pulled to the top. Injected
    /// rather than reached for, the same shape `LocalhostListView` takes its
    /// `PortBook`, so a preview or a test can hand in a store of its own.
    var shelf: SessionShelf = .shared

    /**
     * Which session the details sheet is about, if it is up.
     *
     * The machine as well as the session, for the reason `TerminalScreen` names
     * one: ids come from each machine's own session layer and nothing makes them
     * unique across machines, so a sheet holding an id alone would describe
     * whichever machine happened to be current when it was drawn.
     */
    @State private var detailing: SessionRef?

    /// Whether the archived rows are on screen. A flag rather than a route:
    /// this is a reference somebody opens, acts in and closes, like the details
    /// sheet next to it — not a place they are going.
    @State private var showingArchived = false

    /**
     * The session a Close is waiting to be confirmed for.
     *
     * The whole session and not its id, because the alert has to name it and a
     * row can leave the list between the swipe and the answer — a `status` frame
     * reorders this list, and an id resolved at draw time would put a different
     * session's title over a decision about this one. Holding the value means
     * the question that is on screen is the question that was asked.
     */
    @State private var closingSession: RemoteSession?

    private struct SessionRef: Identifiable, Hashable {
        let host: String
        let session: String
        var id: String { "\(host)/\(session)" }
    }

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()

            /*
             * "Nothing to show" is the sessions this list would **draw**.
             *
             * The test used to be compound — the sessions *and* the copilot row
             * pinned above them, and before that the ports and the dev servers.
             * Both of those have moved off this screen: the ports to their own
             * tab, and the copilot to its own pill. So it is the sessions and
             * nothing else again, and the empty state has nothing underneath it
             * to draw over.
             *
             * `listed` rather than `model.sessions`, and that is the one thing
             * this line has to get right now: a machine whose every session has
             * been archived has sessions and an empty list, and drawing rows
             * that are not there — or hiding the empty state behind rows that
             * are hidden — are the two ways to be wrong about it. The archived
             * ones are reachable from the menu, which is why this is allowed to
             * say the list is empty rather than having to qualify it.
             */
            if listed.isEmpty {
                empty
            } else {
                list
            }
        }
        /*
         * Everything the wire says about one session.
         *
         * A sheet rather than a second navigation destination, because it is a
         * reference somebody opens, reads and closes — not a place they are
         * going. Reached by a long press here and by a named item in the
         * session's own menu, which is the pair this app already uses for
         * "quick, if you know it" and "findable, if you do not".
         */
        .sheet(item: $detailing) { ref in
            SessionDetailView(model: model,
                              hostID: ref.host,
                              sessionID: ref.session,
                              open: {
                                  detailing = nil
                                  model.open(session: ref.session, on: ref.host)
                              },
                              dismiss: { detailing = nil })
        }
        /*
         * The rows this phone has put away.
         *
         * A sheet rather than a push, for the same reason the details sheet is
         * one: it is opened, acted in and closed. Opening a session from it goes
         * through the same two-step the details sheet uses — take the sheet down
         * first, then navigate — because a push that happens behind a modal is a
         * screen nobody sees arriving.
         */
        .sheet(isPresented: $showingArchived) {
            ArchivedSessionsView(sessions: archived,
                                 machine: model.current?.label ?? "this machine",
                                 unarchive: { id in
                                     shelf.setArchived(false, host: hostId, session: id)
                                 },
                                 open: { id in
                                     showingArchived = false
                                     model.open(session: id, on: hostId)
                                 },
                                 dismiss: { showingArchived = false })
        }
        /*
         * The confirmation he asked for, in the platform's own words for it.
         *
         * *"Close the session (with a confirmation)."* A system alert rather
         * than an inline strip in the row, and this is the one place in the app
         * where that is the right answer: the swipe has already covered the row
         * it is about, an alert is modal so it cannot be scrolled away from
         * mid-decision, and iOS draws a `.destructive` role in the platform's
         * own red at the platform's own weight — which people read faster than
         * anything this app could compose.
         *
         * Three lines, and each carries a different fact. The title names the
         * session, so a list of eight `agent` rows cannot produce a decision
         * about the wrong one. The message says what happens on the machine and
         * that it does not come back. The buttons say *close* rather than *yes*
         * — a confirm dialog whose affirmative is "OK" is one people answer
         * without reading the question above it.
         *
         * `presenting:` carries the whole session, so the title is drawn from
         * the value that was swiped and not from a lookup that could resolve
         * against a list the machine has reordered in between.
         */
        .alert("Close \(closingSession?.title ?? "this session")?",
               isPresented: Binding(get: { closingSession != nil },
                                    set: { if !$0 { closingSession = nil } }),
               presenting: closingSession) { session in
            Button("Close session", role: .destructive) {
                model.closeSession(session.id)
                closingSession = nil
            }
            .accessibilityIdentifier("close.confirm")
            Button("Cancel", role: .cancel) { closingSession = nil }
        } message: { _ in
            Text("The session stops on \(model.current?.label ?? "the machine") and does not come back. "
                 + "Anything it was part-way through stops there.")
        }
        .navigationTitle(Brand.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            // The connection goes in the title rather than in a leading item:
            // a `ToolbarItem` next to a centred title gets squeezed to its
            // minimum width, and the pill came out as a single letter in a
            // circle — a status indicator that cannot be read is worse than
            // none, because it looks like it is telling you something.
            ToolbarItem(placement: .principal) { HostSwitcher(model: model) }
            ToolbarItemGroup(placement: .topBarTrailing) {
                if model.canStartSomewhere { newSession }
                /*
                 * One item, and it used to be nine.
                 *
                 * Everything that was about a *machine* — pair another, rename,
                 * forget, which endpoint this is — is on the Machines screen,
                 * and everything that was about the *app* — the GitHub account,
                 * the alert switches — is on Settings, which is also where that
                 * screen is reached from now. Neither is repeated here.
                 * Asad, on the desktop's equivalent: *"options is having all of
                 * the things that we already have here and there. So let's keep
                 * everything separate rather than having everything on one
                 * page."*
                 *
                 * ## Refresh and Reconnect are gone, and here is what they did
                 *
                 * He asked both questions and both answers are *nothing a person
                 * needs a button for*.
                 *
                 * **Refresh** — *"what does it actually do?"* — called
                 * `DeckModel.refresh()`, which sends one `list` frame to the
                 * machine. **The pull gesture on this list sends the identical
                 * frame**, and has since before the menu item existed: see
                 * `.refreshable` below. So it was a second control for a gesture
                 * the platform already owns, in a menu, two taps away, and he
                 * named the replacement himself: *"pull-to-refresh would be the
                 * natural gesture."*
                 *
                 * **Reconnect now** — *"I don't know why we need it. What will
                 * it actually do?"* — called `resume()`, which realigns the
                 * heartbeat and drops the pending backoff on every machine. The
                 * app already does that by itself in all three of the situations
                 * where it matters, and each is wired somewhere this file can
                 * name: coming back to the foreground (`TerminalDeckApp`'s scene
                 * phase), the network route changing (`NetworkWatch`), and the
                 * schedule itself, which is capped at twenty seconds
                 * (`Backoff.reconnect`). A button whose whole job is "do the
                 * thing that is about to happen anyway" is, as he put it, an
                 * admission that it might not.
                 *
                 * The one place a manual retry still earns its place is the
                 * empty state's **Try again**, and the difference is the moment:
                 * it is drawn only when the socket is genuinely down *and* not
                 * currently trying, which is the one screen where somebody is
                 * looking at nothing and deserves something to press.
                 *
                 * What is left is a *place* rather than an action — the rows
                 * this phone has put away. It stays in the menu even when there
                 * are none, because the screen behind it is where the swipe
                 * gesture is explained, and a control that appears only after
                 * you have already discovered the thing it explains is no help
                 * to the person who has not.
                 */
                Menu {
                    Button {
                        showingArchived = true
                    } label: {
                        Label(archivedLabel, systemImage: "archivebox")
                    }
                    .accessibilityIdentifier("sessions.archived")
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .accessibilityLabel("More")
                .accessibilityIdentifier("sessions.more")
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) { banners }
    }

    // MARK: - Pieces

    /**
     * The New Session control: one tap when there is one answer, a menu when
     * there is a real choice.
     *
     * There used to be a text field here asking for a title. There is no title
     * on the wire any more: every session in this product is named after its
     * folder, by the Mac, and a phone-chosen name would have been the one tab on
     * the desktop that meant something different from all the others.
     *
     * ## Where the folders come from
     *
     * From the machine, when it says: `welcome.folders` is the list a person
     * granted *this device* on that desktop, kept current by a pushed `folders`
     * frame, and it is the same array the Mac enforces against — so nothing in
     * this menu can offer a tap that gets refused. When the machine is old
     * enough not to have said, the list falls back to the working directories
     * already on this screen, which is what it always was.
     *
     * A machine that granted this device *nothing* is a different case again,
     * and it is not this control's job: the button is absent, and `empty` says
     * why. See `DeckModel.canStartSomewhere`.
     */
    @ViewBuilder
    private var newSession: some View {
        if model.startableFolders.isEmpty && !model.canPickFolders {
            Button {
                model.createSession(in: nil)
            } label: {
                Image(systemName: "plus")
            }
            .accessibilityLabel("New session")
            .accessibilityIdentifier("sessions.new")
        } else {
            Menu {
                Button {
                    model.createSession(in: nil)
                } label: {
                    Label("New session", systemImage: "plus")
                }
                // Identified, because the toolbar button above it is *labelled*
                // "New session" too — it is the same action, said once for a
                // screen reader and once in a menu. A query on the words matches
                // both and cannot be tapped: "multiple matching elements found",
                // which is how two UI tests failed against a host that offered
                // any folders at all.
                .accessibilityIdentifier("sessions.newDefault")
                Section("In a folder") {
                    ForEach(model.startableFolders, id: \.self) { folder in
                        Button {
                            model.createSession(in: folder)
                        } label: {
                            Label(folderName(folder), systemImage: "folder")
                        }
                        // By the folder's own path, because the label is its
                        // last component and two projects called `web` under
                        // different parents are one label and two rows.
                        .accessibilityIdentifier("sessions.newIn.\(folder)")
                    }
                    /*
                     * And the folders this machine did not think to offer.
                     *
                     * Last in the section rather than first: the rows above are
                     * one tap and this one is a screen, so somebody whose folder
                     * is already listed never has to walk past a browser to
                     * reach it. It is also the only row here on a bare server,
                     * where the list above is the account's home and nothing
                     * else — which is the complaint this answers.
                     *
                     * Drawn only where the machine offered `folders.pick`, which
                     * it does for one of the owner's own devices. A guest sees
                     * the section it always saw.
                     */
                    if model.canPickFolders {
                        Button {
                            model.showingFolderPicker = true
                        } label: {
                            Label("Choose a folder…", systemImage: "folder.badge.plus")
                        }
                        .accessibilityIdentifier("sessions.pickFolder")
                    }
                }
            } label: {
                Image(systemName: "plus")
            }
            .accessibilityLabel("New session")
            .accessibilityIdentifier("sessions.new")
        }
    }

    /// The folder's own name. A full path does not fit in a menu row and the
    /// last component is what the desktop titles the session after anyway.
    private func folderName(_ path: String) -> String {
        let name = (path as NSString).lastPathComponent
        return name.isEmpty ? path : name
    }

    @ViewBuilder
    private var banners: some View {
        VStack(spacing: 0) {
            /*
             * The yellow bar, and the rule about when it is allowed to appear.
             *
             * `showsConnectionNotice` rather than `!connection.isLive`, which is
             * what this was and which is why the app opened onto a warning every
             * single time: the first frame of a launch is `.offline`, the second
             * is `.connecting`, and both of them drew this. `ConnectionGrace`
             * has the whole rule; the short version is that a connection is only
             * worth a bar once it has been in the way for five seconds.
             */
            if model.showsConnectionNotice {
                Banner(text: model.connection.detail, tone: .warning)
            }
            if let error = model.lastError {
                Banner(text: error, tone: .warning)
                    .onTapGesture { model.dismissError() }
            }
            /*
             * What happened while the app was asleep.
             *
             * Neutral rather than a warning, because nothing is wrong: it is the
             * honest answer to a phone that cannot be woken by a machine. See
             * `DeckModel.awayReport`. Tapping dismisses it, like the error above
             * — the sessions it is about are in the list underneath.
             */
            if let report = model.awayReport {
                Banner(text: report, tone: .neutral)
                    .onTapGesture { model.dismissAwayReport() }
                    .accessibilityIdentifier("sessions.awayReport")
            }
        }
    }

    /// Which machine these rows belong to. Archives and pins are stored against
    /// it, so a phone paired with two machines does not hide one's sessions
    /// because of a swipe on the other. See `SessionShelf`.
    private var hostId: String { model.current?.id ?? "" }

    /// The rows this screen draws, and the rows it is holding back. One call
    /// rather than three predicates the view could get out of step with itself
    /// — see `SessionShelf.split`, which is where the ordering rule lives and
    /// where it is tested without a simulator.
    private var shelved: (listed: [RemoteSession], archived: [RemoteSession]) {
        shelf.split(model.sessions, host: hostId)
    }

    private var listed: [RemoteSession] { shelved.listed }
    private var archived: [RemoteSession] { shelved.archived }

    /// What the menu item says. The count is the point of the row: an archive
    /// nobody can see the size of is a place people stop opening.
    private var archivedLabel: String {
        archived.isEmpty ? "Archived" : "Archived (\(archived.count))"
    }

    /**
     * The list, laid out with space rather than with lines — and it is a `List`
     * now, because that is the only thing on iOS that swipes.
     *
     * Asad: *"swipe left/right on a session row should reveal buttons,
     * WhatsApp-style… when we will have a lot of sessions we will not like to
     * have all of them over here."* And on what the gesture used to do: *"swipe
     * currently just opens the session, which tapping already does. It's
     * nonsense to keep this feature."* He was right about that in a precise way
     * — the old body was a `ScrollView` of `NavigationLink`s, so a horizontal
     * drag was just a sloppy tap, which is the worst kind of gesture: it looks
     * like it did something.
     *
     * `.swipeActions` exists only inside a `List`, and hand-rolling a drag was
     * never an option — no rubber band at the limit, no interaction with the
     * back gesture at the left edge, and a different depth from every other app
     * on the phone. `LocalhostListView` made this exact trade one screen over
     * and its header argues it; the cards survive the change because the row
     * background is cleared and the fill comes from `RowButtonStyle` as before.
     *
     * ## A button rather than a `NavigationLink`
     *
     * Inside a `List`, a `NavigationLink` draws the system's own disclosure
     * chevron beside whatever it is given — and `SessionRow` already draws one,
     * so the rows came out with two. `model.open(session:)` appends the identical
     * route, which is what the link was doing, and it is the shape every other
     * card in this app already uses.
     */
    private var list: some View {
        List {
            /*
             * There was a **Resume** card here, pinned above the list: the
             * session this phone last looked at, tinted, with *"Where you were
             * last"* under it. It is deleted, in his words, 2026-08-20:
             *
             *   > *"in the application, resume the top thing, resume session
             *   > thing where you were last time — I think that's not required."*
             *
             * He is right, and the reason it looked useful is the reason it was
             * not: the session it named is *already in the list below*, usually
             * at the top of it, because the list is sorted by what did something
             * most recently. So the card was a second control for the same row,
             * one line higher, in the one colour this screen reserves for the
             * single action worth suggesting.
             *
             * What it remembered is not deleted with it — `lastOpenedKey` still
             * records the session, because inspect mode reads it to decide where
             * a described element is sent. That is a use nobody has to see.
             */
            ForEach(listed) { session in
                Button {
                    model.open(session: session.id)
                } label: {
                    SessionRow(session: session,
                               lastActivity: model.lastActivity[session.id],
                               pinned: shelf.isPinned(host: hostId, session: session.id))
                }
                .buttonStyle(RowButtonStyle())
                .accessibilityIdentifier("session.\(session.id)")
                /*
                 * The shortcut to the details sheet.
                 *
                 * A long press rather than a second control on the row: the
                 * row's whole job is to open the session, and a row with two
                 * tap targets on a phone is a row people hit the wrong half
                 * of. It is deliberately not the *only* way in — the same
                 * screen is a named item inside the session, and it is on the
                 * trailing swipe below, where somebody who has never
                 * long-pressed anything will find it.
                 */
                .contextMenu {
                    Button {
                        detailing = SessionRef(host: hostId, session: session.id)
                    } label: {
                        Label("Details", systemImage: "info.circle")
                    }
                    .accessibilityIdentifier("session.details")
                }
                .plainRow()
                .swipeActions(edge: .leading, allowsFullSwipe: false) {
                    pinAction(session)
                }
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    // Close first, then Archive, then Details — destructive,
                    // reversible, harmless, reading outward from the edge. It is
                    // the platform's own order and it is also the order of how
                    // much each one costs to get wrong.
                    closeAction(session)
                    archiveAction(session)
                    detailsAction(session)
                }
            }

            // Not `.plainRow()`-ed from here: it is a `@ViewBuilder` that is very
            // often an `EmptyView`, and a modifier applied to one of those still
            // makes a row — an empty, 44-point-tall row with a separator, in the
            // middle of the list. The modifier is inside its `if` instead.
            alertsOffer

            /*
             * There was a footnote here — *"Only sessions started in Terminal
             * Deck are listed…"* — under every populated list, on every launch,
             * forever. It is gone, under the rule he restated on 2026-08-20:
             *
             *   > *"don't put any single statement in anywhere… We want
             *   > simplicity. Let the smart people use it."*
             *
             * The sentence itself survives in exactly one place, which is the
             * one place it is genuinely required: the **empty** state, where
             * "nothing is listed" is the whole screen and the reason for it is
             * the only useful thing to say. A list with sessions in it does not
             * need a note explaining which sessions are in it.
             */

            // Room for the pill that floats over this list. See `TabBarClearance`.
            TabBarClearance()
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .environment(\.defaultMinListRowHeight, 0)
        .refreshable {
            model.refresh()
            // The pull gesture needs something to hold on to or it snaps back
            // before the answer arrives and reads as having done nothing. It is
            // also the *only* refresh on this screen now — see the toolbar for
            // what was in the menu and why it is not any more.
            try? await Task.sleep(for: .milliseconds(450))
        }
    }

    /**
     * The leading swipe: pin, which is the "move" he asked for.
     *
     * `SessionShelf` argues the naming at length. In one line: there is nowhere
     * on a phone for a session to move *to* — it is a shell in a folder chosen
     * when it was started — and what somebody dragging a row in a list of forty
     * wants is that row at the top, which is what this does and what the
     * platform calls it.
     *
     * `allowsFullSwipe: false` on both edges, deliberately, exactly as on the
     * localhost list: a full swipe fires the first action on release, and
     * "archive the session I was reaching for" is not a thing to do by accident
     * with a thumb.
     */
    @ViewBuilder
    private func pinAction(_ session: RemoteSession) -> some View {
        let pinned = shelf.isPinned(host: hostId, session: session.id)
        Button {
            shelf.setPinned(!pinned, host: hostId, session: session.id)
        } label: {
            Label(pinned ? "Unpin" : "Pin", systemImage: pinned ? "pin.slash" : "pin.fill")
        }
        .tint(Theme.accent)
        .accessibilityIdentifier("session.swipe.pin.\(session.id)")
    }

    /**
     * Close, which is the action this gesture was asked for and the one it went
     * a week without.
     *
     * ## What was missing, and what it took to stop missing it
     *
     * This doc comment used to argue that the action could not exist. It was
     * right at the time: protocol v1 carried list, attach, detach, input, resize
     * and create plus the named extensions, none of them ended a session, and
     * `SessionAccess` on the desktop had no method to call — a gap on both sides
     * of the wire rather than a frame nobody had wired up. Two fakes were
     * available and both were refused. Typing `exit` or a Ctrl-C into the pty is
     * not closing a session: a full-screen agent CLI ignores both, the row
     * stays, and the button works *sometimes*, which is worse than not being
     * there. A Close that only archived would be a label describing something
     * else, which is the complaint this whole review is built around.
     *
     * The shape it named is the shape that shipped — a `close` capability, a
     * `{t:'close', id}` frame, and an optional `SessionAccess.close` the
     * capability is derived from, exactly as `create` works.
     *
     * ## Why it is conditional, and why that is not a greyed-out button
     *
     * `model.canCloseSessions` is the capability, and a machine that never
     * advertised it gets no Close at all rather than a disabled one — the rule
     * this whole screen follows, argued in the file header about New Session.
     * It matters more here than anywhere: this is the only control in the app
     * whose effect cannot be undone, so a Close whose outcome depends on
     * something the person cannot see would be the worst possible thing to
     * offer them.
     *
     * ## Red, and it asks
     *
     * Red because something on the machine ends — the exact opposite claim from
     * Archive's orange below, which changes nothing but this phone's own list.
     * And it opens the alert rather than acting: `role: .destructive` on a swipe
     * button is *styling*, not a confirmation, and a full swipe is disabled on
     * this edge precisely because a thumb should not be able to finish this.
     */
    @ViewBuilder
    private func closeAction(_ session: RemoteSession) -> some View {
        if model.canCloseSessions {
            Button(role: .destructive) {
                // Deferred by one turn of the run loop, the same as the details
                // sheet below and the rename alerts elsewhere in this app:
                // presenting from inside a swipe handler while the row is still
                // animating back leaves the alert with no presenter, and the
                // press does nothing at all.
                DispatchQueue.main.async { closingSession = session }
            } label: {
                Label("Close", systemImage: "xmark.circle.fill")
            }
            /*
             * Tinted explicitly, and it took a screenshot to find out why it has
             * to be.
             *
             * `role: .destructive` on a swipe button is red *by default* — and
             * only by default. This screen sits under a `.tint(Theme.accent)`,
             * and an ambient tint wins, so the first build of this rendered a
             * blue Close sitting beside an orange Archive: the one action that
             * ends somebody's work was the only one wearing the app's ordinary
             * accent. Nothing in the build log says so and the code reads
             * correctly; it was visible in the first frame the simulator took.
             */
            .tint(Theme.critical)
            .accessibilityIdentifier("session.swipe.close.\(session.id)")
        }
    }

    /**
     * The trailing swipe's second action.
     *
     * Orange rather than red, and that is a claim about what it does: nothing on
     * the machine changes. The session keeps running, keeps producing output and
     * can still raise an alert; what changes is that this phone stops drawing
     * it. The screen behind the menu says so in a sentence, because an archive
     * that people believed was a stop would be worse than no archive at all —
     * and with Close sitting next to it in red, the distinction between the two
     * is now something the colours themselves make.
     */
    @ViewBuilder
    private func archiveAction(_ session: RemoteSession) -> some View {
        Button {
            shelf.setArchived(true, host: hostId, session: session.id)
        } label: {
            Label("Archive", systemImage: "archivebox.fill")
        }
        .tint(Theme.warning)
        .accessibilityIdentifier("session.swipe.archive.\(session.id)")
    }

    /// And the same sheet the long press opens. On the swipe as well because a
    /// long press is a gesture people either know or never find, and this screen
    /// now teaches the swipe anyway.
    @ViewBuilder
    private func detailsAction(_ session: RemoteSession) -> some View {
        Button {
            // Deferred by one turn of the run loop, the same as the rename alerts
            // elsewhere in this app: presenting from inside a swipe handler while
            // the row is still animating back leaves the sheet with no presenter.
            DispatchQueue.main.async {
                detailing = SessionRef(host: hostId, session: session.id)
            }
        } label: {
            Label("Details", systemImage: "info.circle")
        }
        .tint(Theme.neutralAction)
        .accessibilityIdentifier("session.swipe.details.\(session.id)")
    }

    /// The empty state's second half, and now the only place this sentence is
    /// said at all — the footnote it used to share with is deleted; see the note
    /// where it stood.
    ///
    /// It used to end "in Terminal or VS Code", and the review took that out by
    /// name: *"we don't need to mention VS Code because it's another one… but VS
    /// will be a specific thing."* The sentence is about a **category** — any
    /// program that is not this one — so naming two members of that category
    /// both under-describes it (nothing is said about Ghostty, iTerm, a
    /// JetBrains IDE or a bare ssh) and reads as an endorsement of the two that
    /// were named. "Your own terminal or editor" is the whole category in four
    /// words, and it stays true when the next editor ships.
    static let onlyItsOwnSessions =
        "Only sessions started in \(Brand.name) are listed — it cannot see one you are running "
        + "in your own terminal or editor."

    /**
     * The one place this app mentions notifications before somebody goes looking.
     *
     * Shown only while iOS has **never been asked** — so it disappears for good
     * the moment the question is answered either way, and there is no second
     * preference remembering that it was dismissed. That is the whole trick:
     * the state that hides it belongs to the system rather than to this app,
     * which is why it cannot come back and nag.
     *
     * Quiet on purpose. It is a card like the others rather than an accented
     * one, because the accent on this screen belongs to Resume — a screen where
     * two things are blue has no accent at all.
     *
     * Below the sessions rather than above them: somebody who opened the app to
     * look at a session should reach their session first.
     */
    @ViewBuilder
    private var alertsOffer: some View {
        if model.alertPermission == .notAsked && !model.sessions.isEmpty {
            Button {
                model.showingAlerts = true
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "bell")
                        .font(.system(size: 15))
                        .foregroundStyle(Theme.secondary)
                        .frame(width: 18)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Get told when a session needs you")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(Theme.primary)
                        Text("Alerts are off")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.faint)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.faint)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 13)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(RowButtonStyle())
            .accessibilityIdentifier("sessions.alertsOffer")
            .plainRow(top: 11)
        }
    }

    /**
     * The screen when there is nothing to list — which is the screen people see
     * when something is wrong, and therefore the one the app is judged on.
     *
     * Four different situations reach it and each gets its own sentence and its
     * own action, because "no sessions" said over a dead socket is a lie by
     * omission, "no sessions" said over a machine that granted this phone no
     * folders sends someone looking for a bug that is a setting, and "no
     * sessions" said over a machine whose sessions this phone has itself
     * archived is a screen blaming the machine for a swipe.
     *
     * ## And a fourth, which says nothing at all
     *
     * The first seconds of a launch, before there is an answer. The three
     * sentences below are all wrong there — "No sessions" is a claim nobody has
     * checked, and "Connecting" is the yellow-thing complaint written larger —
     * so what is drawn is a spinner. Asad: *"otherwise it will just load, so they
     * will not even feel that it takes time for connecting."* Once the grace
     * period is over the honest sentence takes over; see `ConnectionGrace`.
     */
    @ViewBuilder
    private var empty: some View {
        if !model.connection.isLive && !model.showsConnectionNotice {
            ProgressView()
                .controlSize(.large)
                .tint(Theme.secondary)
                .accessibilityIdentifier("sessions.loading")
        } else {
            settledEmpty
        }
    }

    private var settledEmpty: some View {
        ContentUnavailableView {
            Label(emptyTitle, systemImage: emptyIcon)
        } description: {
            Text(emptyDetail)
        } actions: {
            if !model.connection.isLive && !model.connection.isTrying {
                /*
                 * The one manual retry left in the app, and the reason it
                 * survived the cull that took Reconnect out of the menu.
                 *
                 * The menu item was drawn over a working list and meant "do the
                 * thing that is about to happen anyway". This is drawn only when
                 * the socket is down *and* nothing is currently trying, which is
                 * the one moment somebody is looking at a screen with nothing on
                 * it — and a screen with nothing on it and nothing to press is
                 * how people conclude an app is broken.
                 */
                Button("Try again") { model.resume() }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.accent)
            } else if everythingIsArchived {
                // Not a New Session button. There is nothing wrong here and
                // nothing to start — the sessions exist, this phone put them
                // away, and the fix is the place they were put.
                Button("Show archived") { showingArchived = true }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.accent)
                    .accessibilityIdentifier("sessions.showArchivedFromEmpty")
            } else if model.hasNoGrantedFolders && model.canPickFolders && model.connection.isLive {
                /*
                 * Nothing has been shared with this phone — and this phone can
                 * go and find a folder itself.
                 *
                 * This is the case the screen previously had no button for at
                 * all: the sentence said to open the settings on the machine,
                 * and a headless server has no settings to open. The one action
                 * that actually works is the one that is now on screen.
                 */
                Button("Choose a folder") { model.showingFolderPicker = true }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.accent)
                    .accessibilityIdentifier("sessions.pickFolderFromEmpty")
            } else if model.canStartSomewhere && model.connection.isLive {
                // The empty state is where a first session gets started, so the
                // action is here as well as in the toolbar — the toolbar's plus
                // is a 24pt target in a corner, and this is the moment the
                // screen is asking to be used.
                Button("New session") { model.createSession(in: nil) }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.accent)
                    .accessibilityIdentifier("sessions.newFromEmpty")
            }
        }
    }

    /// Whether the list is empty *because of this phone* rather than because of
    /// the machine. Read by all three halves of the empty state, so they cannot
    /// disagree about which situation they are describing.
    private var everythingIsArchived: Bool {
        model.connection.isLive && !model.sessions.isEmpty && listed.isEmpty
    }

    private var emptyTitle: String {
        if !model.connection.isLive { return model.connection.label }
        if everythingIsArchived { return "All archived" }
        return model.hasNoGrantedFolders ? "No folders shared" : "No sessions"
    }

    private var emptyIcon: String {
        if !model.connection.isLive { return "bolt.horizontal.circle" }
        if everythingIsArchived { return "archivebox" }
        return model.hasNoGrantedFolders ? "folder.badge.questionmark" : "terminal"
    }

    private var emptyDetail: String {
        if !model.connection.isLive { return model.connection.detail }
        if everythingIsArchived {
            // The count, because the number is the fact somebody is missing, and
            // the second sentence because the whole risk of an archive is
            // somebody believing it stopped something.
            let count = archived.count
            return "\(count == 1 ? "One session is" : "\(count) sessions are") archived on this phone. "
                + "They are all still running on \(model.current?.label ?? "the machine")."
        }
        if model.hasNoGrantedFolders {
            /*
             * Named where the fix is — and where that is depends on whether this
             * phone can reach the machine's folders itself.
             *
             * The sentence used to send everybody to "the settings on the Mac",
             * which is a real screen on a desktop and **nothing at all** on a
             * headless server: there is no window to open it in. Somebody
             * holding a phone against a rented Linux box was told to go and do
             * something that could not be done, which is worse than being told
             * nothing.
             */
            let whose = model.current?.label ?? "That machine"
            if model.canPickFolders {
                return "\(whose) has not shared any folders with this phone yet. "
                    + "Choose one with the button below."
            }
            return "\(whose) has not shared any folders with this "
                + "phone yet. Open the settings on \(model.theMachine) and choose which "
                + "folders it may start sessions in."
        }
        // Not "the Mac has nothing running", which is the sentence that was here
        // and is very often false — the Mac may well be running an agent, just
        // not one this app started. See `scopeNote`.
        return "Nothing has been started on \(model.theMachine) yet. "
            + Self.onlyItsOwnSessions
    }
}

/**
 * A `List` row that still looks like a card.
 *
 * Three modifiers that always travel together, and getting any one of them wrong
 * undoes the screen: the row background has to be cleared or every card sits on
 * a white slab, the separator has to go or the gap between cards has a line
 * through it, and the insets have to be stated or the system's own leading inset
 * puts the first card 20 points further in than the banner above it.
 *
 * Five points top and bottom, so two neighbouring rows leave the ten-point gap
 * this screen had when it was a `LazyVStack`. `LocalhostListView` open-codes the
 * same three lines for the same reason; this is written once here because the
 * session list has five kinds of row and open-coding it five times is how one of
 * them ends up two points taller than the others.
 */
extension View {
    func plainRow(top: CGFloat = 5, bottom: CGFloat = 5) -> some View {
        listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets(top: top, leading: 16, bottom: bottom, trailing: 16))
    }
}

/**
 * A row that answers a finger.
 *
 * `.plain` leaves a `NavigationLink` looking identical before, during and after
 * a press, which on a list where every row navigates is a screen full of
 * controls that all look inert. This is the smallest honest response: the card
 * lightens and settles back by 1%, fast enough not to be a transition and slow
 * enough to be seen.
 *
 * Internal rather than private, and shared by every card in the app — the
 * sessions, the ports, the dev servers and the machines. It was copied verbatim
 * onto the Machines screen once already under a second name, which is how two
 * lists end up pressing differently.
 */
struct RowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay {
                // `Theme.pressed` rather than white: on paper a white wash over
                // a near-white card is nothing at all, so this row would have
                // had no press state in the light appearance while looking
                // perfectly correct in the dark one. See `Ink.pressed`.
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(configuration.isPressed ? Theme.pressed : .clear)
            }
            .scaleEffect(configuration.isPressed ? 0.99 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/* -------------------------------------------------------------------------- */
/* Rows                                                                        */
/* -------------------------------------------------------------------------- */

/**
 * One session.
 *
 * The type is the hierarchy. The name is the thing you are looking for, so it
 * is the largest and the brightest; the folder underneath is **data**, so it is
 * mono and dimmed, truncated from the *head* because the end of a path is what
 * identifies it; the status line is a sentence about the row rather than the row
 * itself, so it is quieter than both.
 */
private struct SessionRow: View {
    let session: RemoteSession
    let lastActivity: Double?
    /// Whether this phone has pulled the row to the top. Drawn, because a list
    /// that reorders itself with nothing to explain why is a list somebody
    /// assumes is sorting by something they cannot see.
    let pinned: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            StatusDot(status: session.status)
                .padding(.top, 7)

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Text(session.title)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(Theme.primary)
                        .lineLimit(1)
                    if pinned {
                        // Faint and small: it is a mark on the row rather than a
                        // second thing to read, and the accent on this screen
                        // belongs to Resume.
                        Image(systemName: "pin.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(Theme.faint)
                            .accessibilityLabel("Pinned")
                    }
                }

                Text(session.cwd)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(Theme.faint)
                    .lineLimit(1)
                    .truncationMode(.head)

                HStack(spacing: 8) {
                    Chip(text: session.provider)
                    Text(statusLine)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.secondary)
                        .lineLimit(1)
                }
                .padding(.top, 1)
            }

            Spacer(minLength: 0)

            Image(systemName: "chevron.right")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.faint)
                .padding(.top, 4)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    /// Both halves come from `SessionDetails`, which is also what the details
    /// sheet prints. Two copies of "what is this session doing" is two answers
    /// that drift, and the row and the sheet are the two places somebody would
    /// notice — they can be on screen a second apart.
    ///
    /// Nothing is printed for the time when the desktop did not timestamp the
    /// row; see `lastActivity` in `WireCodec` for why that field is read rather
    /// than declared.
    private var statusLine: String {
        var parts = [SessionDetails.statusLine(session)]
        if let line = SessionDetails.activityLine(lastActivity) { parts.append(line) }
        return parts.joined(separator: " · ")
    }
}

/// A dot that pulses while a session is doing something, because the difference
/// between "working" and "waiting for you" is the thing people open this app to
/// find out.
struct StatusDot: View {
    let status: String

    @State private var breathing = false

    var body: some View {
        Circle()
            .fill(Theme.statusColor(status))
            .frame(width: 8, height: 8)
            .opacity(status == "working" && breathing ? 0.35 : 1)
            .animation(status == "working"
                       ? .easeInOut(duration: 0.9).repeatForever(autoreverses: true)
                       : .default,
                       value: breathing)
            .onAppear { breathing = true }
    }
}

// The `SectionHeader` that used to live here is gone with the two sections it
// captioned. It only ever labelled "Dev servers" and "Running on the Mac", both
// of which are the Localhost tab now — and that screen groups its rows with a
// header that folds, which is a different control rather than this one moved.
// A section this screen no longer has does not need a caption kept for it.

private struct Chip: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .medium, design: .monospaced))
            .foregroundStyle(Theme.secondary)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Theme.surfaceHigh, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
    }
}

/* -------------------------------------------------------------------------- */
/* The switcher                                                                */
/* -------------------------------------------------------------------------- */

/**
 * Which machine is on screen, and every other one this phone is paired with.
 *
 * In the title, where the app's name used to be. That is the trade this feature
 * makes and it is the right way round: the product's name is the same on every
 * screen and tells nobody anything, whereas *which machine am I typing into* is
 * the one question a phone paired with several of them must never leave open.
 * With a single machine the app's name comes back, because a picker with one row
 * in it is furniture.
 *
 * Every row carries a live dot. That is the whole reason every host stays
 * connected rather than connecting on demand: a switcher that shows "offline"
 * for the machines it has not dialled yet would be reporting the *app's* state
 * instead of the machines', and the point of pairing several is knowing which of
 * them is busy without opening it.
 *
 * Internal, because the Localhost tab puts the same control in its own title.
 * *Which machine's ports are these* is exactly as open a question as which
 * machine's sessions, and it must not be answered by two controls that can
 * disagree — one of them showing the connection while the other does not is a
 * screen where you cannot tell whether the list is current.
 *
 * The `Brand.name` fallback with a single machine is written for the session
 * list, which is the app's first screen. On any other screen it is a title
 * saying nothing, so the fallback is a parameter.
 */
struct HostSwitcher: View {
    let model: DeckModel
    /// What the title says when there is only one machine and a picker would be
    /// furniture. The product's name on the first screen; the screen's own name
    /// anywhere else.
    var singleHostTitle: String = Brand.name

    var body: some View {
        if model.hasSeveralHosts {
            Menu {
                Section("Machines") {
                    ForEach(model.hosts) { host in
                        Button {
                            model.select(host.id)
                        } label: {
                            // Two lines: the name, and what it is doing. The
                            // second is the reason to look.
                            Label {
                                // `model.label(for:)` and not `host.label`:
                                // two machines with one hostname put two
                                // identical rows in this menu.
                                Text(verbatim: "\(model.label(for: host)) — \(summary(host))")
                            } icon: {
                                Image(systemName: host.id == model.current?.id
                                      ? "checkmark.circle.fill"
                                      : icon(host))
                            }
                        }
                        .accessibilityIdentifier("host.\(host.id)")
                    }
                }
                // No "Pair another machine" here any more. This menu answers
                // *which machine am I typing into*, which is a question worth
                // one tap from the session list; adding one is management, and
                // management is the Machines screen inside Settings. The item
                // was in both places and that is exactly the shape he objected
                // to.
            } label: {
                VStack(spacing: 1) {
                    HStack(spacing: 4) {
                        Text(model.current?.label ?? Brand.name)
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(Theme.primary)
                            .lineLimit(1)
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(Theme.faint)
                    }
                    ConnectionPill(state: model.connection, showing: model.showsConnectionNotice)
                }
            }
            .accessibilityIdentifier("host.switcher")
            .accessibilityLabel("Machine: \(model.current?.label ?? "none"). \(model.hosts.count) paired.")
        } else {
            VStack(spacing: 1) {
                Text(singleHostTitle)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Theme.primary)
                ConnectionPill(state: model.connection, showing: model.showsConnectionNotice)
            }
        }
    }

    /// What the row says about a machine that is not on screen. Sessions when it
    /// is up, because that is the number worth switching for; the connection
    /// state when it is not, because then the session count is history.
    private func summary(_ host: HostLink) -> String {
        guard host.connection.isLive else { return host.connection.label.lowercased() }
        let running = host.sessions.filter { $0.status != "exited" }.count
        if running == 0 { return "nothing running" }
        let working = host.sessions.filter { $0.status == "working" }.count
        let sessions = running == 1 ? "1 session" : "\(running) sessions"
        return working > 0 ? "\(sessions), \(working) working" : sessions
    }

    private func icon(_ host: HostLink) -> String {
        host.connection.isLive ? "circle.fill" : "circle.dotted"
    }
}

/* -------------------------------------------------------------------------- */
/* Chrome                                                                      */
/* -------------------------------------------------------------------------- */

/**
 * The connection, in three words and a colour — when there is anything worth
 * saying at all.
 *
 * Green only for `online`. Everything else is amber or grey and says what it is,
 * because the failure this whole app has to avoid is looking connected when it
 * is not — a person who trusts a green dot will type Ctrl+C into a dead socket
 * and walk away believing the job stopped.
 *
 * ## Most of the time it draws nothing
 *
 * `showing` comes from `ConnectionGrace`, which holds the whole rule and the
 * reasoning: a connected phone says nothing, a drop says nothing for its first
 * five seconds, and a launch says nothing while it dials. What is left is the
 * case where the connection really is the thing in the person's way.
 *
 * ## Why there is still an element here when nothing is drawn
 *
 * Because *not drawing something* is a decision about a screen, not about the
 * fact. The connection state is still true, still worth answering when asked,
 * and VoiceOver asking "what is this app's connection" is a person asking a
 * question the screen has deliberately stopped shouting — which is exactly the
 * case an accessibility label exists for. So the element is always present and
 * always carries the real state; only its ink is conditional.
 *
 * That it also keeps `connection.pill` queryable for the UI suite is a
 * consequence rather than the reason, but it is a welcome one: nine of those
 * tests wait on this label to know a real desktop is answering.
 *
 * ## And why that element is a UIKit view rather than a SwiftUI modifier
 *
 * Because a claim ten tests depend on has to be checkable, and the SwiftUI
 * version is not — in this process. `.accessibilityElement(children: .ignore)`
 * with a label was tried first and is almost certainly correct on a device, but
 * SwiftUI generates its accessibility elements as part of a render pass driven by
 * an accessibility *client*, and there is none inside a unit test: a hosted view
 * with the pill plainly laid out reports an empty tree through both
 * `accessibilityElements` and `accessibilityElementCount()`. Measured on iOS
 * 26.5, for the visible pill as well as the invisible one — so the failure said
 * nothing at all about the app.
 *
 * A `UIView` that sets `isAccessibilityElement` itself has none of that
 * indirection. It is in the hierarchy the moment it is made, it is what XCUITest
 * walks, and `ConnectionPillTests` can find it by walking `subviews` — which is
 * the difference between a documented intention and a pinned one. The drawing
 * above is then marked `accessibilityHidden`, so there is exactly one element
 * here in both states rather than two that could disagree.
 */
struct ConnectionPill: View {
    let state: ConnectionState
    /// Whether the connection is worth drawing. See `ConnectionGrace`.
    let showing: Bool

    var body: some View {
        ZStack {
            if showing {
                pill
            } else {
                // One point, so the overlay below has a frame and the toolbar
                // has something to lay out. Nothing is drawn into it.
                Color.clear.frame(width: 1, height: 1)
            }
        }
        // The ink is decoration; the element below is the identity. Without this
        // there would be two overlapping elements saying the same thing, and
        // VoiceOver would read the connection twice.
        .accessibilityHidden(true)
        .overlay { ConnectionAccessibility(state: state) }
    }

    private var pill: some View {
        HStack(spacing: 5) {
            if state.isTrying {
                ProgressView()
                    .controlSize(.mini)
                    .tint(color)
            } else {
                Circle().fill(color).frame(width: 7, height: 7)
            }
            Text(state.label)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(color)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(color.opacity(0.12), in: Capsule())
    }

    /// What the connection state reads as. One sentence, written once, so the
    /// element and any future reader of it cannot drift.
    static func spoken(_ state: ConnectionState) -> String {
        "Connection: \(state.label). \(state.detail)"
    }

    /// The three semantic colours, from the same set the desktop uses for the
    /// same meanings. Green is not the accent and must not be: the accent means
    /// "this is the action", and a connection is a fact rather than an action.
    private var color: Color {
        switch state.phase {
        case .online: return Theme.positive
        case .connecting, .waiting, .pending: return Theme.warning
        case .rejected, .incompatible: return Theme.critical
        case .offline: return Theme.secondary
        }
    }
}

/**
 * The connection, as a thing that can be asked rather than a thing that is drawn.
 *
 * A bare `UIView` whose whole job is to be one accessibility element. See
 * `ConnectionPill`'s header for why it is UIKit: SwiftUI's own accessibility
 * elements are generated by a render pass that no unit test can drive, so the
 * claim that this element survives the pill being invisible could be written down
 * but not checked. This one is in the view hierarchy the moment it is made.
 *
 * It carries no traits beyond `.staticText` and takes no touches. It is not a
 * control and must not read as one — the connection is a fact, and the actions
 * for a connection that has gone wrong are on the list underneath.
 */
private struct ConnectionAccessibility: UIViewRepresentable {
    let state: ConnectionState

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .clear
        view.isUserInteractionEnabled = false
        view.isAccessibilityElement = true
        view.accessibilityIdentifier = "connection.pill"
        view.accessibilityTraits = .staticText
        return view
    }

    func updateUIView(_ view: UIView, context: Context) {
        view.accessibilityLabel = ConnectionPill.spoken(state)
    }
}

/**
 * The one line that says something is wrong, over the top of whatever is
 * underneath it.
 *
 * On a material rather than a flat fill, and that is the one place this app
 * genuinely wants the system's blur: the banner sits over content that scrolls
 * beneath it, so it has to be legible without being a wall — which is exactly
 * what a material is for. The hairline underneath stays for the same reason: it
 * is the case where space cannot do the job, because there is no space between
 * a floating bar and the thing sliding under it.
 */
struct Banner: View {
    enum Tone { case neutral, warning }

    let text: String
    let tone: Tone

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: tone == .warning ? "exclamationmark.triangle.fill" : "info.circle")
                .font(.system(size: 11))
            Text(text)
                .font(.system(size: 12))
                .multilineTextAlignment(.leading)
            Spacer(minLength: 0)
        }
        .foregroundStyle(tone == .warning ? Theme.warning : Theme.secondary)
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.ultraThinMaterial)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.hairline).frame(height: 0.5)
        }
    }
}
