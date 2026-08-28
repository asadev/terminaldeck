/**
 * One server, from the phone — what it is, what it is running, and the four
 * verbs that manage the host on it.
 *
 * ## The order on the screen is the order he described
 *
 * > *"Then all the server-related stuff comes up — what's running, what's not,
 * > everything about that server, just like the MacBook application. Then it
 * > checks whether the headless Terminal Deck already exists on that server. If
 * > it exists, it brings it up and asks you to connect. If it does not exist, it
 * > gives the option to install — you click, it installs, then you can connect,
 * > and disconnect if you want."*
 *
 * The host card is first because it is the thing with buttons on it and the
 * reason somebody opened this page; the machine underneath it is what the page
 * is *about*. Both come from the same two round trips, taken together, so
 * nothing on the page is newer than anything else on it and the age is stated
 * once at the bottom.
 *
 * ## No control is drawn hopefully
 *
 * §4.1 of `SERVERS-DESIGN.md`: *"a control that cannot act is removed, or
 * disabled with a stated reason. Never drawn hopefully."* So Install is absent
 * when `whyNot` has an answer and that answer is on screen instead; Start is
 * absent when it is already running; Connect is absent when the host has no
 * address to dial and the reason is printed where the button was.
 *
 * ## Nothing here polls
 *
 * The page measures once when it opens and again when somebody pulls it down.
 * A live page would be a timer per server, which is the thing his rule bans —
 * so what is drawn is stamped with when it was measured, and the age is shown
 * rather than hidden.
 */

import SwiftUI

struct ServerDetailView: View {
    let model: DeckModel
    let serverId: String

    @State private var confirmingForget = false

    /// The name being typed, while the rename alert is up. Empty when it is not.
    @State private var renamingTo: String?

    private var connector: ServerConnector { model.serverConnector }
    private var server: StoredServer? { connector.server(serverId) }
    private var view: ServerView? { connector.views[serverId] }
    private var install: ServerInstallState { connector.installs[serverId] ?? ServerInstallState() }
    private var isWorking: Bool { connector.working.contains(serverId) }

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if let server {
                        head(server)
                        if let problem = connector.problems[serverId] {
                            failure(problem)
                        }
                        /*
                         * The same card the login screen shows, not a second
                         * drawing of it.
                         *
                         * Install, start, connect and disconnect used to be
                         * written out twice — once here and once wherever else
                         * somebody needed them — which is how two screens end up
                         * disagreeing about what a server can do. `HostStepCard`
                         * is the one implementation; this page and the step
                         * after a login both render it.
                         */
                        HostStepCard(model: model, serverId: serverId)

                        /*
                         * **Manage the host over the relay** — "the relay is the
                         * network."
                         *
                         * The card above reaches this server over its SSH address,
                         * which for Asad is a Tailscale name that goes offline on
                         * its own — and then it reports the box as unreachable
                         * while every session on it still runs over the public
                         * relay. This card is the other road: when the server is a
                         * connected machine, its status and its restart/stop go
                         * over the relay, independent of the SSH address. It draws
                         * nothing when the machine is not connected or is an older
                         * host that does not speak the verb, so an SSH-only server
                         * is exactly as it was — and `HostStepCard` withholds its
                         * own SSH Restart/Stop row when this one is live, so there
                         * are never two.
                         */
                        if let hostId = server.linkedHostId, let link = model.host(hostId) {
                            HostRelayControlView(host: link)
                        }

                        // **Connect GitHub, right here on the server.**
                        //
                        // > *"As soon as we connect the server and the application, for headless
                        // > also we give the option to connect GitHub there — connect server, then
                        // > app, then GitHub, so it's linked there. The host owns it, not the phone."*
                        //
                        // The card draws itself and reads its own state; it renders nothing until the
                        // machine is connected and advertises `github`, so it is safe to place here.
                        // `model.host` resolves the live link once the server has become a machine —
                        // `linkedHostId` is set by `ServerConnector.markConnected`.
                        if let hostId = server.linkedHostId, let link = model.host(hostId) {
                            ConnectGitHubView(host: link)
                        }

                        signInCard(server)
                        if let view {
                            machineCard(view.facts)
                            runningCard(view.facts)
                            measured(view.measuredAt)
                        } else if !isWorking {
                            Text("Nothing has been measured on this server yet. Pull down to look.")
                                .font(.system(size: 13))
                                .foregroundStyle(Theme.faint)
                        }
                        forgetRow(server)
                    } else {
                        Text("This server is not on this phone any more.")
                            .font(.system(size: 14))
                            .foregroundStyle(Theme.secondary)
                    }


                    // Pushed from Settings, so it keeps the bar and owes it room.
                    TabBarClearance()
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 32)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .refreshable { await connector.look(serverId) }
        }
        .navigationTitle(server?.name ?? "Server")
        .navigationBarTitleDisplayMode(.inline)
        /*
         * Rename, which the app could already do and offered nowhere.
         *
         * `ServerConnector.rename` has existed since servers did and had no
         * caller anywhere in the app — so the name a server was given at the
         * login screen was the name it kept forever. Asad, holding a list of
         * them: *"I am not able to edit the name of this account and I don't
         * know where it belongs to… I should be able to edit the account, delete
         * and add."* Delete is the row at the bottom and add is the login
         * screen; this is the third.
         *
         * On this page rather than in the list, beside the address it belongs to
         * and beside Forget, so the two things somebody does to a server they
         * are looking at are in the same place.
         */
        .toolbar {
            if let server {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        renamingTo = server.name
                    } label: {
                        Label("Rename", systemImage: "pencil")
                    }
                    .accessibilityIdentifier("server.rename")
                }
            }
        }
        .alert("Rename this server",
               isPresented: Binding(get: { renamingTo != nil },
                                    set: { if !$0 { renamingTo = nil } })) {
            TextField("Name", text: Binding(get: { renamingTo ?? "" },
                                            set: { renamingTo = $0 }))
                .textInputAutocapitalization(.words)
                .accessibilityIdentifier("server.renameField")
            // Save first so it is the default action a return key presses.
            Button("Save") {
                if let name = renamingTo { connector.rename(serverId, to: name) }
                renamingTo = nil
            }
            Button("Cancel", role: .cancel) { renamingTo = nil }
        } message: {
            // What the name is *for*, because the answer is not obvious and he
            // said so: it is this phone's label and nothing on the server reads
            // it. `rename` already refuses an empty one and caps it at 64.
            Text("This is the name on this phone. Nothing on the server changes.")
        }
        .task {
            if connector.views[serverId] == nil { await connector.look(serverId) }
        }
        .onDisappear { connector.release(serverId) }
        .onChange(of: signInHostId) { _, hostId in
            // The connect runs through the sign-in flow the app already has, so
            // this is where its result is written down — see `HostStepCard`.
            if let hostId { connector.markConnected(serverId, hostId: hostId) }
        }
    }

    /// The machine id the shared sign-in flow ended on, or nil while it has not.
    private var signInHostId: String? {
        if case let .signedIn(hostId, _) = model.serverSignIn.phase { return hostId }
        return nil
    }

    /* ----------------------------------------------------------------- head -- */

    /**
     * One line, not two.
     *
     * It was the address on one line and *"signed in as root"* under it, with
     * the same address already in the navigation bar above both — three prints
     * of one fact on a screen 390 points wide. Photographed against a real
     * server, which is the only way that kind of thing is ever noticed. What is
     * left is the line somebody would actually type: `root@host`, with the port
     * when it is not 22.
     */
    private func head(_ server: StoredServer) -> some View {
        HStack(spacing: 6) {
            Text("\(server.username)@\(server.where_)")
                .font(.system(size: 14, design: .monospaced))
                .foregroundStyle(Theme.secondary)
                .textSelection(.enabled)
                .lineLimit(1)
                .truncationMode(.middle)
                .accessibilityIdentifier("server.where")
            if let key = server.hostKey {
                InfoDot(about: "this server's identity",
                        text: "It proved itself with \(key.algorithm) \(key.fingerprint). Every "
                            + "connection is checked against that, and a server answering with "
                            + "a different key is refused before your password is offered.")
            }
            Spacer(minLength: 0)
        }
    }

    private func failure(_ problem: ServerTrouble) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(problem.headline)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.warning)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("server.problem")
            Text(problem.advice)
                .font(.system(size: 13))
                .foregroundStyle(Theme.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    /* ------------------------------------------------------- the sign-in -- */

    /**
     * How this phone gets back in.
     *
     * There was a Face ID switch on this card and it has gone up a level. It
     * locked *this server's* password, which meant a prompt on every connection
     * to it — and since the app reconnects to its last server as it opens, that
     * was a prompt on every launch. Asad: *"I wanted this face lock actually not
     * just for one specific server — make it for the overall application."* One
     * switch now, on the main Settings page, locking the app rather than a
     * credential: see `AppLockSection`.
     *
     * What is left is the true statement this card was always making underneath
     * the switch — where the sign-in is kept. It is in this iPhone's Keychain,
     * marked to this device and never synced, exactly as it was before the
     * switch existed and exactly as it is after.
     */
    private func signInCard(_ server: StoredServer) -> some View {
        card {
            Text("Getting back in")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.primary)
            Text(server.credential == .key
                 ? "This phone holds a private key for \(server.username)@\(server.address), in "
                     + "the Keychain."
                 : "This phone holds the password for \(server.username)@\(server.address), in "
                     + "the Keychain.")
                .font(.system(size: 12))
                .foregroundStyle(Theme.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /* --------------------------------------------------------- the machine -- */

    private func machineCard(_ facts: ServerFacts) -> some View {
        card {
            Text("This server")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.primary)
            factRow("System", facts.os)
            factRow("Kernel", facts.kernel)
            factRow("Architecture", facts.arch)
            factRow("Name", facts.hostname)
            factRow("Signed in as", facts.user)
            factRow("This sign-in", facts.privilege, map: Self.privilegeWord)
            factRow("Starts things with", facts.initSystem)
            factRow("Containers", facts.containerRuntime, absent: "none")
            factRow("Installs software with", facts.packageManager, absent: "no package manager")
            factRow("Web server", facts.webServer, absent: "none")

            if let cpus = facts.cpus.value {
                plain("Processors", "\(cpus)")
            }
            if let disk = facts.disk.value, disk.totalKb > 0 {
                plain("Disk", "\(Self.gb(disk.usedKb)) of \(Self.gb(disk.totalKb)) used")
            }
            if let memory = facts.memory.value, memory.totalKb > 0 {
                plain("Memory", "\(Self.gb(memory.totalKb - memory.freeKb)) of "
                    + "\(Self.gb(memory.totalKb)) in use")
            }
            if let load = facts.load1.value {
                plain("Load", String(format: "%.2f", load))
            }
            if let uptime = facts.uptimeSeconds.value {
                plain("Up for", Self.spell(uptime))
            }
        }
    }

    /* ---------------------------------------------------- what is running -- */

    @ViewBuilder
    private func runningCard(_ facts: ServerFacts) -> some View {
        card {
            Text("What is running")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.primary)

            switch facts.services {
            case let .yes(services, _):
                let running = services.filter { $0.isRunning }
                Text("\(running.count) of \(services.count) services are running.")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.secondary)
                    .accessibilityIdentifier("server.serviceCount")
                ForEach(running.prefix(12)) { service in
                    row(service.name, service.detail.isEmpty ? service.state : service.detail)
                }
                if running.count > 12 {
                    Text("and \(running.count - 12) more.")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.faint)
                }
            case .no:
                Text("This server keeps nothing running of its own.")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.secondary)
            case let .cannot(why):
                stated(why)
            }

            if case let .yes(containers, _) = facts.containers, !containers.isEmpty {
                divider
                Text("Containers")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.primary)
                ForEach(containers.prefix(12)) { container in
                    row(container.name, container.status.isEmpty ? container.image : container.status)
                }
            }

            if case let .yes(rows, _) = facts.listeners, !rows.isEmpty {
                let listeners = Self.tidy(rows)
                divider
                Text("Listening")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.primary)
                ForEach(listeners.prefix(14)) { listener in
                    row("port \(listener.port)",
                        listener.program.isEmpty ? listener.address : listener.program)
                }
            } else if case let .cannot(why) = facts.listeners {
                divider
                stated(why)
            }

            if case let .yes(sites, _) = facts.siteNames, !sites.isEmpty {
                divider
                Text("Web addresses this server answers to")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.primary)
                ForEach(sites.prefix(12), id: \.self) { site in
                    Text(site)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(Theme.secondary)
                        .textSelection(.enabled)
                }
            }
        }
    }

    /* --------------------------------------------------------------- parts -- */

    private func measured(_ at: Date) -> some View {
        Text("Measured \(Self.ago(at)). Nothing here refreshes on its own — pull down to look again.")
            .font(.system(size: 12))
            .foregroundStyle(Theme.faint)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("server.measured")
    }

    private func forgetRow(_ server: StoredServer) -> some View {
        Button(role: .destructive) {
            confirmingForget = true
        } label: {
            Text("Forget this server")
                .font(.system(size: 15, weight: .medium))
                // Red, not amber. > "This forget-server, like a yellow button,
                // it should be like red so it is clear." It takes the server off
                // this phone, so it is the red kind — the same call the machine
                // Forget already makes, and what the app's own rule reserves red
                // for: the thing that takes something away.
                .foregroundStyle(Theme.critical)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 12)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("server.forget")
        .confirmationDialog("Forget \(server.name)?",
                            isPresented: $confirmingForget,
                            titleVisibility: .visible) {
            Button("Forget it", role: .destructive) { connector.forget(serverId) }
            Button("Keep it", role: .cancel) {}
        } message: {
            Text("Nothing on that server changes. This phone stops holding its address and its "
                 + "sign-in.")
        }
    }

    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private var divider: some View {
        Rectangle()
            .fill(Theme.hairline)
            .frame(height: 1)
            .padding(.vertical, 2)
    }

    private func action(_ title: String,
                        _ symbol: String,
                        identifier: String,
                        disabled: Bool,
                        compact: Bool = false,
                        act: @escaping () -> Void) -> some View {
        Button(action: act) {
            HStack(spacing: 8) {
                Image(systemName: symbol)
                    .font(.system(size: 14, weight: .semibold))
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                if !compact { Spacer(minLength: 0) }
            }
            .frame(maxWidth: compact ? nil : .infinity)
            .padding(.horizontal, compact ? 14 : 12)
            .padding(.vertical, 11)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(disabled ? Theme.secondary : Theme.onAccent)
        .background(Theme.accent.opacity(disabled ? 0.28 : 1),
                    in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .disabled(disabled)
        .accessibilityIdentifier(identifier)
    }

    /// A sentence shown **in place of** a control or a value — never a dash, and
    /// never an empty row. `facts.ts`: a dash reads as zero, and that is the
    /// moment a card starts lying.
    private func stated(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(Theme.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func factRow(_ title: String,
                         _ fact: Fact<String>,
                         absent: String = "none",
                         map: ((String) -> String)? = nil) -> some View {
        Group {
            switch fact {
            case let .yes(value, _):
                plain(title, map?(value) ?? value)
            case .no:
                plain(title, absent)
            case let .cannot(why):
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.faint)
                    Text(why)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func plain(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(title)
                .font(.system(size: 12))
                .foregroundStyle(Theme.faint)
            Spacer(minLength: 8)
            Text(value)
                .font(.system(size: 13))
                .foregroundStyle(Theme.primary)
                .multilineTextAlignment(.trailing)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func row(_ name: String, _ detail: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(name)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(Theme.primary)
            Spacer(minLength: 8)
            Text(detail)
                .font(.system(size: 11))
                .foregroundStyle(Theme.faint)
                .lineLimit(1)
                .truncationMode(.tail)
        }
    }

    /**
     * The listening ports, in the order a person reads them and without the
     * doubles.
     *
     * A server that answers on both IPv4 and IPv6 prints **two** rows for one
     * open port — `0.0.0.0 22 sshd` and `[::] 22 sshd` — and the page drew them
     * both, so a real machine read as *"port 53, port 8787, port 22, port 53"*
     * and looked like a bug in this app. It is not a bug in the probe: both
     * bindings are real and the reader is right to report them. It is a
     * presentation question, and the answer is the port, once, with what is
     * holding it. Seen in a photograph of a real server; nothing else would have
     * shown it.
     *
     * Sorted by port number, numerically — 22 before 443 before 8787, not the
     * order `ss` happened to print, and not the string order that puts 2019
     * before 22.
     */
    private static func tidy(_ listeners: [ListenerFact]) -> [ListenerFact] {
        var seen = Set<String>()
        let unique = listeners.filter { seen.insert("\($0.port)/\($0.program)").inserted }
        return unique.sorted { (Int($0.port) ?? 0, $0.program) < (Int($1.port) ?? 0, $1.program) }
    }

    /* --------------------------------------------------------------- words -- */

    private static func privilegeWord(_ raw: String) -> String {
        switch raw {
        case "yes": return "is the administrator"
        case "sudo-nopasswd": return "can become the administrator"
        case "sudo-password": return "can become the administrator with a password"
        case "no": return "is an ordinary account"
        default: return raw
        }
    }

    private static func gb(_ kb: Int) -> String {
        let gigabytes = Double(kb) / 1024 / 1024
        if gigabytes >= 10 { return "\(Int(gigabytes.rounded())) GB" }
        if gigabytes >= 1 { return String(format: "%.1f GB", gigabytes) }
        return "\(kb / 1024) MB"
    }

    private static func spell(_ seconds: Int) -> String {
        let days = seconds / 86400
        if days >= 1 { return days == 1 ? "1 day" : "\(days) days" }
        let hours = seconds / 3600
        if hours >= 1 { return hours == 1 ? "1 hour" : "\(hours) hours" }
        let minutes = max(1, seconds / 60)
        return minutes == 1 ? "1 minute" : "\(minutes) minutes"
    }

    private static func ago(_ at: Date) -> String {
        let seconds = Int(Date().timeIntervalSince(at))
        if seconds < 60 { return "just now" }
        return "\(spell(seconds)) ago"
    }
}
