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
    @State private var showingOutput = false

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
                        hostCard(server)
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
        .task {
            if connector.views[serverId] == nil { await connector.look(serverId) }
        }
        .onDisappear { connector.release(serverId) }
        .onChange(of: signInHostId) { _, hostId in
            // The connect runs through the sign-in flow the app already has, so
            // this is where its result is written down — see `connectButton`.
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

    private func failure(_ problem: SSHProblem) -> some View {
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
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    /* ------------------------------------------------------------ host card -- */

    @ViewBuilder
    private func hostCard(_ server: StoredServer) -> some View {
        let host = view?.host.host
        let room = view?.host.room

        card {
            HStack(spacing: 8) {
                Image(systemName: "shippingbox")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.secondary)
                Text(Brand.name)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.primary)
                Spacer(minLength: 0)
                if isWorking || install.isBusy {
                    ProgressView().controlSize(.small).tint(Theme.accent)
                }
            }

            if let host {
                Text(HostProbe.line(host))
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("server.hostLine")
                if let reach = HostProbe.reachLine(host) {
                    Text(reach)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.faint)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                Text("Looking at what is on this server.")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.faint)
            }

            if install.step != .idle {
                installProgress
            }

            if let host, let room {
                controls(server: server, host: host, room: room)
            }
        }
    }

    @ViewBuilder
    private func controls(server: StoredServer, host: HostOnServer, room: HostRoom) -> some View {
        if !host.isInstalled {
            if let refusal = HostProbe.whyNot(room) {
                stated(refusal)
            } else {
                action("Install it on this server", "arrow.down.circle",
                       identifier: "server.install", disabled: install.isBusy || isWorking) {
                    Task { await connector.install(serverId) }
                }
                Text("It goes into your home folder on that server, needs no administrator access, "
                     + "and can be taken off again from here.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.faint)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } else {
            HStack(spacing: 10) {
                if host.running == .yes {
                    action("Stop", "stop.circle", identifier: "server.stop",
                           disabled: isWorking, compact: true) {
                        Task { await connector.stop(serverId) }
                    }
                } else {
                    action("Start", "play.circle", identifier: "server.start",
                           disabled: isWorking, compact: true) {
                        Task { await connector.start(serverId) }
                    }
                }
                connectButton(server: server, host: host)
            }
            connecting
        }
    }

    /**
     * What Connect is doing, while it does it.
     *
     * The connect runs through `ServerSignIn`, which takes as long as a real SSH
     * login on the far machine takes — and without this the button simply
     * disabled itself and the screen said nothing for fifteen seconds, which is
     * the dead control this product does not ship. Its refusal lands here too:
     * that flow writes a headline and an advice, and the one thing this screen
     * must not do is invent its own wording for a failure it did not see.
     */
    @ViewBuilder
    private var connecting: some View {
        switch model.serverSignIn.phase {
        case .reaching, .verifying, .joining:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small).tint(Theme.accent)
                Text(model.serverSignIn.phase == .verifying
                     ? "It is checking that login against its own SSH."
                     : "Connecting this phone to the host.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.secondary)
            }
            .accessibilityIdentifier("server.connecting")
        case let .failed(failure):
            VStack(alignment: .leading, spacing: 4) {
                Text(failure.headline)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.warning)
                Text(failure.advice)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.secondary)
            }
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityIdentifier("server.connectFailed")
        case .editing, .signedIn:
            EmptyView()
        }
    }

    /**
     * Connect, disconnect, or the reason neither is offered.
     *
     * Connecting is the sign-in door this app already has, spending the same SSH
     * login this phone is already holding: the host checks it against the
     * server's own sshd and mints this phone a device credential. Nothing new is
     * invented for it, which is why a server that has just been connected is
     * indistinguishable from a machine paired with a code.
     */
    @ViewBuilder
    private func connectButton(server: StoredServer, host: HostOnServer) -> some View {
        if let hostId = server.linkedHostId, model.host(hostId) != nil {
            action("Disconnect", "link.badge.plus", identifier: "server.disconnect",
                   disabled: false, compact: true) {
                model.unpair(hostId)
                connector.markDisconnected(serverId)
            }
        } else if let ticket = connector.connectTicket(serverId) {
            action("Connect", "link", identifier: "server.connect",
                   disabled: model.serverSignIn.isBusy, compact: true) {
                model.serverSignIn.submit(address: ticket.address,
                                          username: ticket.username,
                                          secret: ticket.secret,
                                          method: ticket.method)
            }
        } else if let refusal = HostProbe.connectRefusal(host) {
            stated(refusal)
        }
    }

    @ViewBuilder
    private var installProgress: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(install.done, id: \.self) { line in
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.positive)
                        .padding(.top, 2)
                    Text(line)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if !install.line.isEmpty {
                Text(install.line)
                    .font(.system(size: 13, weight: install.step == .failed ? .semibold : .regular))
                    .foregroundStyle(install.step == .failed ? Theme.warning : Theme.primary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("server.installLine")
            }
            if !install.detail.isEmpty {
                Text(install.detail)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !install.output.isEmpty {
                DisclosureGroup(isExpanded: $showingOutput) {
                    // The server's own words, in its own shape. A terminal's
                    // output reflowed into a paragraph is unreadable, so it
                    // scrolls sideways instead.
                    ScrollView(.horizontal, showsIndicators: true) {
                        Text(install.output.suffix(4000))
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(Theme.secondary)
                            .textSelection(.enabled)
                    }
                    .frame(maxHeight: 220)
                } label: {
                    Text("What the installer said")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Theme.accent)
                }
                .accessibilityIdentifier("server.installOutput")
            }
        }
        .padding(.top, 4)
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
                .foregroundStyle(Theme.warning)
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
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
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
                    in: RoundedRectangle(cornerRadius: 11, style: .continuous))
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
