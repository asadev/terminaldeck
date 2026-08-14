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
 * ## The connection pill is the most important thing on this screen
 *
 * Every other element assumes the list is current. When it is not, the pill is
 * the only thing saying so, and it says which of the six ways it is not current —
 * connecting, waiting, pending approval, offline — rather than going grey.
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
                if model.canCreateSessions { newSession }
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
     * The folders are the ones already on this screen — the Mac accepts only a
     * folder it is already offering — so nothing here can offer a choice that
     * fails. With none of them, the button does not ask a question it already
     * knows the answer to: it starts a session where the desktop would have.
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
            if !model.connection.isLive {
                Banner(text: model.connection.detail, tone: .warning)
            }
            if let error = model.lastError {
                Banner(text: error, tone: .warning)
                    .onTapGesture { model.dismissError() }
            }
        }
    }

    private var list: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                if let session = model.resumable {
                    ResumeRow(session: session) { model.open(session: session.id) }
                    Divider().overlay(Theme.hairline)
                }
                ForEach(model.sessions) { session in
                    NavigationLink(value: DeckModel.Route.session(host: model.current?.id ?? "",
                                                                  id: session.id)) {
                        SessionRow(session: session, lastActivity: model.lastActivity[session.id])
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("session.\(session.id)")
                    Divider().overlay(Theme.hairline)
                }

                localhost
            }
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
            SectionHeader(text: "Running on the Mac")
            ForEach(model.ports) { entry in
                Button {
                    // The tap *is* the consent: no sheet asking whether to
                    // allow it, because nothing was reachable until now and
                    // closing the page makes it unreachable again.
                    browsing = model.openLocalhost(port: entry.port)
                } label: {
                    PortRow(entry: entry)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("port.\(entry.port)")
                Divider().overlay(Theme.hairline)
            }
        }
    }

    private var empty: some View {
        ContentUnavailableView {
            Label(model.connection.isLive ? "No sessions" : model.connection.label, systemImage: "terminal")
        } description: {
            Text(model.connection.isLive
                 ? "The Mac has nothing running. \(Brand.tagline)."
                 : model.connection.detail)
        } actions: {
            if !model.connection.isLive && !model.connection.isTrying {
                Button("Try again") { model.resume() }
            }
        }
    }
}

/* -------------------------------------------------------------------------- */
/* Rows                                                                        */
/* -------------------------------------------------------------------------- */

/// The session this phone was last looking at, at the top, one tap away.
private struct ResumeRow: View {
    let session: RemoteSession
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            HStack(spacing: 12) {
                Image(systemName: "arrow.uturn.backward.circle.fill")
                    .font(.system(size: 20))
                    .foregroundStyle(Theme.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Resume \(session.title)")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(.white)
                    Text("Where you were last")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.faint)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.faint)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(Theme.accent.opacity(0.08))
    }
}

private struct SessionRow: View {
    let session: RemoteSession
    let lastActivity: Double?

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            StatusDot(status: session.status)
                .padding(.top, 6)

            VStack(alignment: .leading, spacing: 4) {
                Text(session.title)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(.white)
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
                }
            }

            Spacer(minLength: 0)

            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.faint)
                .padding(.top, 4)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
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
            .padding(.horizontal, 16)
            .padding(.top, 18)
            .padding(.bottom, 8)
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
                .foregroundStyle(Theme.accent)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 2) {
                Text("localhost:\(String(entry.port))")
                    .font(.system(size: 15, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white)
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
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.faint)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
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
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 5))
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
                            .foregroundStyle(.white)
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
                    .foregroundStyle(.white)
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

    private var color: Color {
        switch state.phase {
        case .online: return Color(red: 0.30, green: 0.78, blue: 0.42)
        case .connecting, .waiting, .pending: return Color(red: 0.98, green: 0.72, blue: 0.20)
        case .rejected, .incompatible: return Color(red: 0.90, green: 0.35, blue: 0.35)
        case .offline: return Theme.secondary
        }
    }
}

struct Banner: View {
    enum Tone { case neutral, warning }

    let text: String
    let tone: Tone

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: tone == .warning ? "exclamationmark.triangle.fill" : "info.circle")
                .font(.system(size: 11))
            Text(text)
                .font(.system(size: 12))
                .multilineTextAlignment(.leading)
            Spacer(minLength: 0)
        }
        .foregroundStyle(tone == .warning ? Color(red: 0.98, green: 0.78, blue: 0.35) : Theme.secondary)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.hairline).frame(height: 0.5)
        }
    }
}
