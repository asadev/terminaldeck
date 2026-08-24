/**
 * **The step right after logging in**: is the headless host on this server, and
 * what happens next.
 *
 * ## The requirement
 *
 * > *"Right after logging in we need to have the step for checking/installing
 * > headless Terminal Deck."*
 *
 * > *"Then it checks whether the headless Terminal Deck already exists on that
 * > server. If it exists, it brings it up and asks you to connect. If it does
 * > not exist, it gives the option to install — you click, it installs, then you
 * > can connect, and disconnect if you want."*
 *
 * ## Why it is one view and not two implementations
 *
 * It is drawn in two places — under a fresh login, and on a server's own page —
 * and those two used to be separate code. That is the same fault as the two
 * login screens one level up: two drawings of one thing, which drift, and where
 * a person meets whichever the route they took happened to reach. So there is
 * one card, `ServerDetailView` renders it, and the login screen renders the same
 * one with `justLoggedIn` set, which changes the lead-in sentence and nothing
 * else about what any button does.
 *
 * ## No control is drawn hopefully
 *
 * §4.1 of `SERVERS-DESIGN.md`. Install is absent when `HostProbe.whyNot` has an
 * answer, and that answer is on screen where the button would have been. Connect
 * is absent when the host has no address to dial, and `HostProbe.connectRefusal`
 * says why. Start is absent when it is already running. Nothing here is a button
 * that would fail if pressed.
 *
 * ## Never a command to copy
 *
 * There is no `curl … | sh` on this card and there is not going to be. *"I don't
 * want that command."* The phone holds a real SSH connection to this server; if
 * something can be installed, this app installs it, watched, with the server's
 * own output when it goes wrong.
 */

import SwiftUI

struct HostStepCard: View {
    let model: DeckModel
    let serverId: String
    /// True on the login screen, where this is a *step* somebody has just
    /// arrived at rather than a standing card on a page they came back to.
    var justLoggedIn = false

    @State private var showingOutput = false

    private var connector: ServerConnector { model.serverConnector }
    private var server: StoredServer? { connector.server(serverId) }
    private var look: HostLook? { connector.views[serverId]?.host }
    private var install: ServerInstallState { connector.installs[serverId] ?? ServerInstallState() }
    private var isWorking: Bool { connector.working.contains(serverId) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header

            if let look {
                Text(HostProbe.line(look.host))
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("server.hostLine")
                if let reach = HostProbe.reachLine(look.host) {
                    Text(reach)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.faint)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else if isWorking {
                Text("Looking at what is on this server.")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.faint)
                    .accessibilityIdentifier("server.hostLine")
            } else {
                Text("Nothing has been looked at on this server yet.")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.faint)
                    .accessibilityIdentifier("server.hostLine")
                action("Check this server", "arrow.clockwise",
                       identifier: "server.check", disabled: false) {
                    Task { await connector.look(serverId) }
                }
            }

            if install.step != .idle { progress }

            if let server, let look {
                controls(server: server, host: look.host, room: look.room)
            }

            connecting
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    /* --------------------------------------------------------------- head -- */

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "shippingbox")
                .font(.system(size: 13))
                .foregroundStyle(Theme.secondary)
            Text(justLoggedIn ? "\(Brand.name) on this server" : Brand.name)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.primary)
                .accessibilityIdentifier("server.hostTitle")
            Spacer(minLength: 0)
            if isWorking || install.isBusy {
                ProgressView().controlSize(.small).tint(Theme.accent)
            }
        }
    }

    /* ----------------------------------------------------------- controls -- */

    @ViewBuilder
    private func controls(server: StoredServer, host: HostOnServer, room: HostRoom) -> some View {
        if !host.isInstalled {
            if let refusal = HostProbe.whyNot(room) {
                stated(refusal)
            } else {
                action("Install it on this server", "arrow.down.circle",
                       identifier: "server.install",
                       disabled: install.isBusy || isWorking) {
                    Task { await connector.install(serverId) }
                }
                Text("It goes into your home folder on that server, needs no administrator access, "
                     + "and can be taken off again from here. Nothing is copied and pasted "
                     + "anywhere — this app runs it over the connection you just made.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.faint)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } else if let hostId = server.linkedHostId, model.host(hostId) != nil {
            HStack(spacing: 10) {
                action("Disconnect", "link.badge.plus", identifier: "server.disconnect",
                       disabled: false, compact: true) {
                    model.unpair(hostId)
                    connector.markDisconnected(serverId)
                }
                if host.running == .yes {
                    action("Stop", "stop.circle", identifier: "server.stop",
                           disabled: isWorking, compact: true) {
                        Task { await connector.stop(serverId) }
                    }
                }
            }
        } else if host.running != .yes {
            /*
             * **Start and connect**, one button, because that is the sentence.
             *
             * *"If it exists, it brings it up and asks you to connect."* Two
             * presses with a wait between them is what this was, and the wait
             * has nothing in it for the person to decide — a host that is
             * installed and stopped, on a screen where somebody just asked to
             * use it, is going to be started. Stop is still its own control on
             * the server's page for whoever wants only that.
             */
            action("Start it and connect", "play.circle",
                   identifier: "server.startConnect", disabled: isWorking) {
                Task {
                    await connector.bringUp(serverId)
                    // Only when starting it actually produced something to dial.
                    // A host takes a moment to reach its relay, and the card
                    // redraws into the refusal below when it has not yet.
                    await connect()
                }
            }
        } else if connector.canConnect(serverId) {
            action("Connect", "link", identifier: "server.connect",
                   disabled: model.serverSignIn.isBusy || isWorking) {
                Task { await connect() }
            }
            if justLoggedIn {
                Text("Connecting signs this phone in to the host running on that server, so it "
                     + "appears in your machines and its sessions open on the Sessions tab.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.faint)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 10) {
                action("Stop", "stop.circle", identifier: "server.stop",
                       disabled: isWorking, compact: true) {
                    Task { await connector.stop(serverId) }
                }
                Spacer(minLength: 0)
            }
        } else if let refusal = HostProbe.connectRefusal(host) {
            /*
             * Running, and nothing to dial yet.
             *
             * Almost always the few seconds a freshly started host spends
             * reaching its relay — which is exactly the gap the "start it and
             * connect" button lands in. So the refusal comes with a way to ask
             * again rather than a sentence and a dead end: this screen has no
             * pull-to-refresh of its own, and telling somebody to wait without
             * giving them the button is telling them to close the app.
             */
            stated(refusal)
            HStack(spacing: 10) {
                action("Look again", "arrow.clockwise", identifier: "server.check",
                       disabled: isWorking, compact: true) {
                    Task { await connector.look(serverId) }
                }
                action("Stop", "stop.circle", identifier: "server.stop",
                       disabled: isWorking, compact: true) {
                    Task { await connector.stop(serverId) }
                }
                Spacer(minLength: 0)
            }
        }
    }

    /**
     * Connect, through the same door the app has always had.
     *
     * The credential is read through the lock — see `ServerConnector.secret` —
     * so a Face ID prompt happens here, and a refused or cancelled one lands as
     * a stated problem rather than as a button that did nothing.
     */
    private func connect() async {
        // Asked before the Keychain is touched: a host with no address to dial
        // has nothing to unlock a credential *for*, and prompting for Face ID
        // and then doing nothing is the worst shape this screen could take.
        guard connector.canConnect(serverId),
              let ticket = await connector.connectTicket(serverId) else { return }
        model.serverSignIn.submit(address: ticket.address,
                                  username: ticket.username,
                                  secret: ticket.secret,
                                  method: ticket.method)
    }

    /* ------------------------------------------------------- what it says -- */

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
     * The install, as it happens — the finished steps, the current line, and the
     * server's own output when something goes wrong.
     *
     * The failure detail is the installer's, verbatim, never a sentence this app
     * invents about a script it did not write.
     */
    @ViewBuilder
    private var progress: some View {
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
                    .accessibilityIdentifier("server.installDetail")
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

    /* -------------------------------------------------------------- parts -- */

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

    /// A sentence shown **in place of** a control — never a dash, never an empty
    /// row, and never a button that would fail if pressed.
    private func stated(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(Theme.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityIdentifier("server.hostRefusal")
    }
}
