/**
 * The Sessions tab: the sessions on the machine, and only those.
 *
 * It used to be the whole app, and the `…` in its corner used to be the only way
 * to reach anything that was not a session. It is one of three tabs now and that
 * menu holds two items — see `DeckTabs.swift` for where the other seven went and
 * why there are three tabs rather than five.
 *
 * ## What left this screen
 *
 * The dev servers and the list of ports the machine is already serving. They were
 * two more sections under the sessions, they were longer than the sessions on any
 * real machine, and a heading is not a separation: *"I can already see a big list
 * of local hosts. So it should not be like that… no separate two lists already
 * here and no separation here… Sessions separately and local host separately in
 * the pill side so we know to go to the section."* They are the Localhost tab —
 * `LocalhostListView` — which also owns the page a tap opens.
 *
 * The one thing that had to be checked in the move is the empty state, which
 * used to count ports and dev servers as *something to show* so that a machine
 * with no sessions did not draw "No sessions" over the top of a Start button.
 * With those rows on their own tab there is nothing underneath to be covered, so
 * the test is the sessions and nothing else again.
 *
 * ## Which buttons exist is decided by the wire, not by the design
 *
 * Protocol v1 carries list, attach, input and resize. A desktop that speaks only
 * that gets a list, a refresh and nothing else — the New Session button is not
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

    /**
     * Which session the details sheet is about, if it is up.
     *
     * The machine as well as the session, for the reason `TerminalScreen` names
     * one: ids come from each machine's own session layer and nothing makes them
     * unique across machines, so a sheet holding an id alone would describe
     * whichever machine happened to be current when it was drawn.
     */
    @State private var detailing: SessionRef?

    private struct SessionRef: Identifiable, Hashable {
        let host: String
        let session: String
        var id: String { "\(host)/\(session)" }
    }

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()

            /*
             * The sessions, and nothing else.
             *
             * This used to also count the ports and the dev servers, because
             * they were drawn on this screen: a machine whose projects were all
             * stopped had no sessions and no listening ports, and the screen
             * would have drawn "No sessions" over the top of the Start buttons
             * that were the answer to it. Those rows are the Localhost tab now,
             * so there is nothing under this screen for an empty state to hide.
             */
            if model.sessions.isEmpty {
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
                 * Two items, and it used to be nine.
                 *
                 * Everything that was about a *machine* — pair another, rename,
                 * forget, which endpoint this is — is on the Machines screen,
                 * and everything that was about the *app* — the GitHub account,
                 * the alert switches — is on Settings, which is also where that
                 * screen is reached from now. Neither is repeated here.
                 * Asad, on the desktop's equivalent in the same recording:
                 * *"options is having all of the things that we already have
                 * here and there. So let's keep everything separate rather than
                 * having everything on one page."*
                 *
                 * What is left is the two things that act on *this list*: ask the
                 * machine for it again, and stop waiting out a backoff. Exactly
                 * one of them is ever enabled, which is why they are two items
                 * rather than one — a single "Refresh" that silently meant
                 * "reconnect" when the socket was down would be a button doing a
                 * different thing from the one it names.
                 */
                Menu {
                    Button {
                        model.refresh()
                    } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                    .disabled(!model.connection.isLive)
                    .accessibilityIdentifier("sessions.refresh")

                    Button {
                        model.resume()
                    } label: {
                        Label("Reconnect now", systemImage: "bolt.horizontal")
                    }
                    .disabled(model.connection.isLive)
                    .accessibilityIdentifier("sessions.reconnect")
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
        if model.startableFolders.isEmpty {
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

    /**
     * The list, laid out with space rather than with lines.
     *
     * Every row used to be separated by a hairline. The design brief's rule is
     * that whitespace is the layout tool and a divider is what you reach for
     * when space genuinely cannot do the job — and here it can: a session is a
     * card, cards have gaps between them, and the gap says the same thing a line
     * said while leaving the screen quieter. It also gives each row a shape to
     * respond with when it is pressed, which a row between two lines never had.
     */
    private var list: some View {
        ScrollView {
            LazyVStack(spacing: 10) {
                if let session = model.resumable {
                    ResumeRow(session: session) { model.open(session: session.id) }
                }
                ForEach(model.sessions) { session in
                    NavigationLink(value: DeckModel.Route.session(host: model.current?.id ?? "",
                                                                  id: session.id)) {
                        SessionRow(session: session, lastActivity: model.lastActivity[session.id])
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
                     * screen is a named item inside the session, where somebody
                     * who has never long-pressed anything will find it.
                     */
                    .contextMenu {
                        Button {
                            detailing = SessionRef(host: model.current?.id ?? "", session: session.id)
                        } label: {
                            Label("Details", systemImage: "info.circle")
                        }
                        .accessibilityIdentifier("session.details")
                    }
                }

                alertsOffer

                // Last, and now unambiguously about the list above it. It used
                // to be followed by the dev servers and the port list, which is
                // why it was placed *between* the sessions and those rather than
                // at the foot — a footnote under a screen's worth of localhost
                // rows reads as a footnote about localhost. With those on their
                // own tab the foot is the right place again.
                scopeNote
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 28)
        }
        .scrollBounceBehavior(.basedOnSize)
        .refreshable {
            model.refresh()
            // The pull gesture needs something to hold on to or it snaps back
            // before the answer arrives and reads as having done nothing.
            try? await Task.sleep(for: .milliseconds(450))
        }
    }

    /**
     * What this list does *not* contain, said once and quietly.
     *
     * The list is every session the desktop started, and people reasonably
     * expect it to be every session — they have a Claude running in Terminal.app
     * or in VS Code and they go looking for it here. It is not here and it
     * cannot be: a session is a pty this product owns, and nothing gives it a
     * handle on a process some other program spawned. Saying nothing leaves the
     * only available conclusion being that the app is broken, which is the
     * failure this line exists to prevent.
     *
     * A line at the foot of the list rather than a banner over it, deliberately.
     * The design brief's rule is that motion and emphasis are earned; this is a
     * fact worth having available and not worth interrupting anybody for, so it
     * sits where a footnote sits, in the faint colour, below the last row. The
     * same sentence is the second half of the empty state's description, because
     * an empty list is exactly when somebody is most likely to be looking for a
     * session that was never going to be here.
     */
    private var scopeNote: some View {
        Text(Self.onlyItsOwnSessions)
            .font(.system(size: 12))
            .foregroundStyle(Theme.faint)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 4)
            .padding(.top, 18)
    }

    /// Written once and read in both places it belongs. Two copies of a sentence
    /// is two sentences that drift.
    static let onlyItsOwnSessions =
        "Only sessions started in \(Brand.name) are listed — it cannot see one you are running "
        + "in Terminal or VS Code."

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
            .padding(.top, 6)
            .accessibilityIdentifier("sessions.alertsOffer")
        }
    }

    /**
     * The screen when there is nothing to list — which is the screen people see
     * when something is wrong, and therefore the one the app is judged on.
     *
     * Three different situations reach it and each gets its own sentence and its
     * own action, because "no sessions" said over a dead socket is a lie by
     * omission and "no sessions" said over a machine that granted this phone no
     * folders sends someone looking for a bug that is a setting.
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
                Button("Try again") { model.resume() }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.accent)
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

    private var emptyTitle: String {
        if !model.connection.isLive { return model.connection.label }
        return model.hasNoGrantedFolders ? "No folders shared" : "No sessions"
    }

    private var emptyIcon: String {
        if !model.connection.isLive { return "bolt.horizontal.circle" }
        return model.hasNoGrantedFolders ? "folder.badge.questionmark" : "terminal"
    }

    private var emptyDetail: String {
        if !model.connection.isLive { return model.connection.detail }
        if model.hasNoGrantedFolders {
            // Named where the fix is. The grant is per device and it is edited
            // on the machine, so a sentence that only said "you cannot start a
            // session" would send someone hunting on the wrong screen.
            return "\(model.current?.label ?? "That machine") has not shared any folders with this "
                + "phone yet. Open the settings on the \(model.hostPlatform.noun) and choose which "
                + "folders it may start sessions in."
        }
        // Not "the Mac has nothing running", which is the sentence that was here
        // and is very often false — the Mac may well be running an agent, just
        // not one this app started. See `scopeNote`.
        return "Nothing has been started on the \(model.hostPlatform.noun) yet. "
            + Self.onlyItsOwnSessions
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
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.white.opacity(configuration.isPressed ? 0.06 : 0))
            }
            .scaleEffect(configuration.isPressed ? 0.99 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/* -------------------------------------------------------------------------- */
/* Rows                                                                        */
/* -------------------------------------------------------------------------- */

/**
 * The session this phone was last looking at, at the top, one tap away.
 *
 * The one place on this screen that is allowed to be blue, and that is the
 * accent rule doing its job: there is exactly one action being suggested here,
 * so it is the only thing tinted. Everything below it is a card the same colour
 * as every other card.
 */
private struct ResumeRow: View {
    let session: RemoteSession
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            HStack(spacing: 12) {
                Image(systemName: "arrow.uturn.backward.circle.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(Theme.accent)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Resume \(session.title)")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Theme.primary)
                        .lineLimit(1)
                    Text("Where you were last")
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.secondary)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.faint)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(AccentRowButtonStyle())
    }
}

/// The resume card's own press state. Separate from `RowButtonStyle` because it
/// is the tinted card and a 6% white wash over a blue tint is a different
/// colour from a 6% wash over grey.
private struct AccentRowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(Theme.accent.opacity(configuration.isPressed ? 0.22 : 0.14),
                        in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .scaleEffect(configuration.isPressed ? 0.99 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

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

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            StatusDot(status: session.status)
                .padding(.top, 7)

            VStack(alignment: .leading, spacing: 6) {
                Text(session.title)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Theme.primary)
                    .lineLimit(1)

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
                                Text(verbatim: "\(host.label) — \(summary(host))")
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
