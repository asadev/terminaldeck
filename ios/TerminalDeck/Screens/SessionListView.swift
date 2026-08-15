/**
 * The root screen: what is running on the Mac.
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
 * ## The connection pill is the most important thing on this screen
 *
 * Every other element assumes the list is current. When it is not, the pill is
 * the only thing saying so, and it says which of the six ways it is not current —
 * connecting, waiting, pending approval, offline — rather than going grey.
 *
 * ## Space, not lines
 *
 * The rows used to be separated by hairlines. They are cards with gaps now, for
 * the reason the design brief gives: whitespace is the layout tool and a divider
 * is what you reach for when space cannot do the job. Here it can.
 */

import SwiftUI

struct SessionListView: View {
    let model: DeckModel

    /// The tunnel the browser sheet is showing. Set by a tap and by nothing
    /// else, which is what makes the tap the consent.
    @State private var browsing: PortTunnel?

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()

            if model.sessions.isEmpty && model.ports.isEmpty {
                empty
            } else {
                list
            }
        }
        .fullScreenCover(item: $browsing) { tunnel in
            LocalhostBrowser(model: model, tunnel: tunnel) {
                browsing = nil
            }
        }
        .onChange(of: browsing == nil) { _, dismissed in
            // Covers the swipe-down as well as the Done button: whichever way
            // the sheet goes away, the port stops being reachable.
            if dismissed { model.closeLocalhost() }
            // And whichever way it goes away, the credential prompt's two
            // possible homes swap over. See `CredentialPromptHost`.
            model.covered = !dismissed
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
                Menu {
                    Button {
                        model.refresh()
                    } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                    .disabled(!model.connection.isLive)

                    Button {
                        model.resume()
                    } label: {
                        Label("Reconnect now", systemImage: "bolt.horizontal")
                    }
                    .disabled(model.connection.isLive)

                    Button {
                        model.addingHost = true
                    } label: {
                        Label("Pair another machine", systemImage: "plus.rectangle.on.rectangle")
                    }
                    .accessibilityIdentifier("sessions.addHost")

                    Button {
                        /*
                         * Deferred by one turn of the run loop.
                         *
                         * Raised in the frame the menu is dismissing in, the
                         * request arrives while a presentation is already in
                         * flight and is dropped, and Rename reads as a dead menu
                         * item. "Pair another machine" two rows up does not have
                         * the problem because a `.sheet` is queued rather than
                         * dropped.
                         *
                         * The alert itself is on `RootView`, not here — see
                         * `DeckModel.renamingHost`.
                         */
                        DispatchQueue.main.async { model.beginRename() }
                    } label: {
                        Label("Rename this machine", systemImage: "pencil")
                    }
                    .disabled(model.current == nil)
                    .accessibilityIdentifier("sessions.rename")

                    // In its own section because these are the items here that
                    // are not about the machine on screen: there is one GitHub
                    // account on this phone and it answers for every machine,
                    // and there is one set of alerts for every machine too.
                    Section {
                        Button {
                            DispatchQueue.main.async { model.showingAlerts = true }
                        } label: {
                            Label("Alerts", systemImage: "bell")
                        }
                        .accessibilityIdentifier("sessions.alerts")

                        Button {
                            DispatchQueue.main.async { model.showingGitHub = true }
                        } label: {
                            Label(gitHubLabel, systemImage: "person.crop.circle")
                        }
                        .accessibilityIdentifier("sessions.github")
                    }

                    if let endpoint = model.endpointSummary {
                        Section("Paired with") { Text(endpoint) }
                    }

                    Button(role: .destructive) {
                        model.unpairCurrent()
                    } label: {
                        // Named, because with several machines paired "unpair
                        // this device" does not say which one is about to go.
                        Label("Forget \(model.current?.label ?? "this machine")", systemImage: "minus.circle")
                    }
                    .accessibilityIdentifier("sessions.unpair")
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

    /// The account, when there is one, so the menu answers "am I connected"
    /// without being opened. A row that only ever read "GitHub account" would
    /// make somebody tap it to find out nothing had changed.
    private var gitHubLabel: String {
        guard let account = model.gitHubAccount else { return "Connect GitHub" }
        return "GitHub: @\(account.login)"
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
            if !model.connection.isLive {
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
                }

                alertsOffer

                // Under the sessions and above the ports, because it is a note
                // about the sessions. Put at the very bottom it sat under a
                // screen's worth of localhost rows on a busy machine and read as
                // a footnote about those instead.
                scopeNote
                localhost
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
     * The Mac's dev servers, one tap from being on this phone.
     *
     * Absent rather than empty when the desktop does not offer the capability,
     * and absent when it does and nothing is listening — a header over no rows
     * is a promise the Mac has not made. Nothing here is typed and nothing is
     * configured: the desktop already knows what is running, so the phone shows
     * it and a tap opens it.
     */
    @ViewBuilder
    private var localhost: some View {
        if model.canBrowseLocalhost && !model.ports.isEmpty {
            SectionHeader(text: "Running on the \(model.hostPlatform.noun)")
            ForEach(model.ports) { entry in
                Button {
                    // The tap *is* the consent: no sheet asking whether to
                    // allow it, because nothing was reachable until now and
                    // closing the page makes it unreachable again.
                    browsing = model.openLocalhost(port: entry.port)
                } label: {
                    PortRow(entry: entry)
                }
                .buttonStyle(RowButtonStyle())
                .accessibilityIdentifier("port.\(entry.port)")
            }
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
     */
    private var empty: some View {
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
 */
private struct RowButtonStyle: ButtonStyle {
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

    private var statusLine: String {
        var parts = [session.status]
        if let code = session.exitCode { parts.append("exit \(code)") }
        // Nothing is printed when the desktop did not timestamp the row; see
        // `lastActivity` in `WireCodec` for why the field is read rather than
        // declared.
        if let at = lastActivity { parts.append(Self.ago(at)) }
        return parts.joined(separator: " · ")
    }

    private static func ago(_ epochMilliseconds: Double) -> String {
        let seconds = Date().timeIntervalSince1970 - epochMilliseconds / 1000
        if seconds < 60 { return "just now" }
        if seconds < 3600 { return "\(Int(seconds / 60))m ago" }
        if seconds < 86_400 { return "\(Int(seconds / 3600))h ago" }
        return "\(Int(seconds / 86_400))d ago"
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

private struct SectionHeader: View {
    let text: String

    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 11, weight: .semibold))
            .kerning(0.6)
            .foregroundStyle(Theme.faint)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, 4)
            .padding(.top, 14)
            .padding(.bottom, 2)
    }
}

/**
 * One listening port.
 *
 * The port number is the identity — it is what the person typed into their
 * terminal and what the URL will say — so it leads. The process name is beside
 * it because "node" and "python3" are how you tell two of them apart, and it is
 * omitted rather than guessed at when the Mac could not name it.
 */
private struct PortRow: View {
    let entry: LocalPort

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "globe")
                .font(.system(size: 15))
                .foregroundStyle(Theme.secondary)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 3) {
                // Mono because it is data — a port is a number somebody typed
                // and will type again — and it leads because it is the identity
                // of the row.
                Text("localhost:\(String(entry.port))")
                    .font(.system(size: 15, weight: .medium, design: .monospaced))
                    .foregroundStyle(Theme.primary)
                    .lineLimit(1)
                if !entry.guessed {
                    Text(entry.process)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.faint)
                        .lineLimit(1)
                }
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
}

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
 */
private struct HostSwitcher: View {
    let model: DeckModel

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
                Button {
                    model.addingHost = true
                } label: {
                    Label("Pair another machine", systemImage: "plus")
                }
                .accessibilityIdentifier("host.add")
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
                    ConnectionPill(state: model.connection)
                }
            }
            .accessibilityIdentifier("host.switcher")
            .accessibilityLabel("Machine: \(model.current?.label ?? "none"). \(model.hosts.count) paired.")
        } else {
            VStack(spacing: 1) {
                Text(Brand.name)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Theme.primary)
                ConnectionPill(state: model.connection)
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
 * The connection, in three words and a colour.
 *
 * Green only for `online`. Everything else is amber or grey and says what it is,
 * because the failure this whole app has to avoid is looking connected when it
 * is not — a person who trusts a green dot will type Ctrl+C into a dead socket
 * and walk away believing the job stopped.
 */
struct ConnectionPill: View {
    let state: ConnectionState

    var body: some View {
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
        .accessibilityIdentifier("connection.pill")
        .accessibilityLabel("Connection: \(state.label). \(state.detail)")
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
