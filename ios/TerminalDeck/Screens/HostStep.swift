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
 * The rule cuts the other way too, and that is the half this card kept getting
 * wrong: **a refusal that names a way out has to offer it.** A host too old to
 * print an address was told to go and find a desktop, from a card holding an
 * open connection to the very server that needed the newer build. And the
 * install copy promised the thing could be "taken off again from here" while no
 * verb on this side could remove anything. Both are controls now, in the branch
 * where the sentence appears.
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
    /// The remove sheet. `false` is the only state anything else can put it in.
    @State private var confirmingRemove = false

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

            /*
             * **Manage the host on this server**, and **the way back** — one
             * gate, because both are true of an installed host in every state
             * above (running, stopped, connected, or too old to dial), and both
             * belong to the server's own page rather than the login step.
             *
             * Not on the login screen. `justLoggedIn` is somebody two seconds
             * into arriving, who asked to *use* this server; the lifecycle verbs
             * and the destructive Remove are not what that moment is for, and the
             * server's own page is one tap away and is where the desktop keeps
             * Remove too.
             */
            if let look, look.host.isInstalled, !justLoggedIn {
                lifecycleRow(host: look.host)
                removeRow(host: look.host)
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

    /**
     * **Update**, wherever the host is installed and behind.
     *
     * > *"whenever there is a new update for headless… it should show the update
     * > button also next to where we install and we can see we installed it…
     * > so we can just directly update anytime directly from the connected
     * > device."*
     *
     * Drawn above the branch below rather than inside one of its arms, and that
     * placement is the requirement rather than a layout choice: a host can be
     * behind while stopped, while running, while connected and while refusing,
     * and an Update that only appeared in one of those is the dead end this
     * replaces — for one release the only way to get a newer build onto a server
     * was a sentence telling you to go and find a desktop.
     *
     * It runs the same verb Install does. `ServerConnector.install` stages this
     * app's own release tarball over the SSH connection already open and
     * re-surveys afterwards, so *update* and *install* are one code path and
     * cannot drift into two answers about what version a server ends up on.
     *
     * Silent when level or ahead — see `HostProbe.updateAvailable`.
     */
    @ViewBuilder
    private func updateRow(_ host: HostOnServer) -> some View {
        if let newer = HostProbe.updateAvailable(host) {
            VStack(alignment: .leading, spacing: 6) {
                action("Update it to \(newer)", "arrow.up.circle",
                       identifier: "server.update",
                       disabled: install.isBusy || isWorking) {
                    Task { await connector.install(serverId) }
                }
                // The number it is on now, because "update" without it is a
                // button that cannot be judged. Its own version is already on
                // the line above this card; this is the other half of the
                // comparison somebody is being asked to act on.
                Text("This server is on \(host.version). Restarting it is part of the update, so "
                     + "any session it is running ends.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.faint)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("server.updateNote")
            }
        }
    }

    @ViewBuilder
    private func controls(server: StoredServer, host: HostOnServer, room: HostRoom) -> some View {
        updateRow(host)
        if !host.isInstalled {
            if let refusal = HostProbe.whyNot(room) {
                stated(refusal)
            } else {
                action("Install it on this server", "arrow.down.circle",
                       identifier: "server.install",
                       disabled: install.isBusy || isWorking) {
                    Task { await connector.install(serverId) }
                }
                // "Taken off again" is a promise, and for one release it was a
                // promise nothing on this side could keep — there was no remove
                // verb on the phone at all. There is now; it lives on this
                // server's own page rather than on the step somebody has just
                // arrived at, so the sentence names the place instead of
                // saying "here" from a screen that does not draw it.
                Text("It goes into your home folder on that server, needs no administrator access, "
                     + "and can be taken off again from this server’s page. Nothing is copied and "
                     + "pasted anywhere — this app runs it over the connection you just made.")
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
                // Stop lives beside Disconnect only on the login step. On the
                // server's own page the lifecycle row below owns Stop/Start/
                // Restart, so putting one here too would be the duplicate control
                // §4.1 bans — two Stops a person cannot tell apart.
                if host.running == .yes, justLoggedIn {
                    action("Stop", "stop.circle", identifier: "server.stop",
                           disabled: isWorking, compact: true) {
                        Task { await connector.stop(serverId) }
                    }
                }
            }
        } else if host.running != .yes {
            /*
             * **Start and connect**, one button, because that is the sentence —
             * and only on the login step.
             *
             * *"If it exists, it brings it up and asks you to connect."* Two
             * presses with a wait between them is what this was, and the wait
             * has nothing in it for the person to decide — a host that is
             * installed and stopped, on a screen where somebody just asked to
             * use it, is going to be started.
             *
             * On the server's own page it is gone, because that is the page he
             * asked for the separate open/close/restart controls on: there,
             * bringing the host up is the lifecycle row's **Start** below, and
             * **Connect** appears once it is running. Collapsing start-and-
             * connect into one button *and* offering a standalone Start would be
             * two ways to start on one screen — the duplicate §4.1 rules out.
             */
            if justLoggedIn {
                action("Start it and connect", "play.circle",
                       identifier: "server.startConnect", disabled: isWorking) {
                    Task {
                        /*
                         * These two lines only became a sentence when the wait
                         * was put in between them, on the server.
                         *
                         * `bringUp` used to return the moment the daemon forked,
                         * seconds before it reached the relay, so `connect()`
                         * found an empty address, hit its own guard and returned
                         * — a button that started something and then visibly did
                         * nothing. `start` now asks the host for its address
                         * before it re-surveys, and the host holds that answer
                         * until the dial finishes or it knows it will not; see
                         * `ServerScripts.address`.
                         *
                         * The refusal below is still reachable and still
                         * correct: it is what a host too old to print an
                         * address, or one whose relay is off, redraws into.
                         */
                        await connector.bringUp(serverId)
                        await connect()
                    }
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
            // Login step only; the server page's Stop is the lifecycle row below.
            if justLoggedIn {
                HStack(spacing: 10) {
                    action("Stop", "stop.circle", identifier: "server.stop",
                           disabled: isWorking, compact: true) {
                        Task { await connector.stop(serverId) }
                    }
                    Spacer(minLength: 0)
                }
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
            /*
             * **The one refusal that has a button**, and the reason this branch
             * stopped being a dead end.
             *
             * A host too old to print a server address used to get that
             * sentence and nothing else — Install lives in the `!isInstalled`
             * branch, so an *installed* host that nothing could reach had no
             * control on this card at all, and the sentence sent somebody to a
             * desktop. `ServerScripts.hostPackage` fetches this app's own
             * release now, so the phone carries the newer build in the only
             * sense that matters, and `connector.install` re-runs the staged
             * installer over the session that is already open. Nothing else
             * changes: `whyNot` is asked first, so a box that has since lost
             * its compiler gets its own reason rather than a button that would
             * fail two minutes in.
             *
             * A relay that is off or still dialling gets no button here on
             * purpose. Installing repairs neither, and offering it would be a
             * control that acts and changes nothing.
             */
            if HostProbe.needsNewerBuild(host) {
                if let why = HostProbe.whyNot(room) {
                    // Its own identifier, not the refusal's: two sentences are
                    // on this card in this state — why it cannot be dialled,
                    // and why it cannot be repaired — and they are different
                    // facts about the same server.
                    stated(why, identifier: "server.installRefusal")
                } else {
                    action("Install \(Brand.version) on this server", "arrow.down.circle",
                           identifier: "server.install",
                           disabled: install.isBusy || isWorking) {
                        Task { await connector.install(serverId) }
                    }
                }
            }
            HStack(spacing: 10) {
                action("Look again", "arrow.clockwise", identifier: "server.check",
                       disabled: isWorking, compact: true) {
                    Task { await connector.look(serverId) }
                }
                // Stop is the lifecycle row's on the server page; here it would
                // be the second Stop on one screen.
                if justLoggedIn {
                    action("Stop", "stop.circle", identifier: "server.stop",
                           disabled: isWorking, compact: true) {
                        Task { await connector.stop(serverId) }
                    }
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

    /**
     * **Manage the host's lifecycle from the phone** — restart, stop, start —
     * because a headless server has no screen and this is the only place they
     * can be pressed. His words, pinned:
     *
     * > *"we should have one button to restart the terminal deck — if it is not
     * > automatically activated we click restart and it activates it on the
     * > server; if we want to close it we can close, if we want to open we can
     * > open. We cannot do it directly on a headless server, so we need the
     * > control here in the server page to manage whenever it is needed (heavy
     * > CPU, many browser tabs, many sessions)."*
     *
     * State honestly, §4.1: **Restart** whenever it is installed — on a stopped
     * host it is the "it activates it" he described; **Stop** only when it is
     * running (there is nothing to close otherwise); **Start** only when it is
     * not (there is nothing to open otherwise). Each runs over SSH against the
     * host's systemd user unit, so it is independent of the host's protocol
     * version and works against a server this app has never updated — see
     * `ServerConnector.restart` / `.stop` / `.start` and `ServerScripts.restart`.
     * None of them silently no-ops: the header spinner turns while the work is
     * in flight, and a restart that does not come back up is reported by the
     * survey afterwards rather than hidden.
     *
     * This is where Stop and Start live on the server's own page; the connect
     * branches above shed theirs so a person never meets two of the same verb on
     * one screen (the login step keeps its own, where this row is not drawn).
     */
    @ViewBuilder
    private func lifecycleRow(host: HostOnServer) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Manage the host on this server")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.secondary)
                .accessibilityIdentifier("server.lifecycleTitle")
            action("Restart it", "arrow.clockwise.circle",
                   identifier: "server.restart", disabled: isWorking) {
                Task { await connector.restart(serverId) }
            }
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
                Spacer(minLength: 0)
            }
            Text("A server has no screen of its own, so restart, stop and start "
                 + "happen here over the connection this phone already holds.")
                .font(.system(size: 12))
                .foregroundStyle(Theme.faint)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /**
     * Remove, behind a confirmation that states the consequence — and states it
     * as the two answers it actually has.
     *
     * The desktop asks this with a tick box beside a button. A phone sheet is a
     * list of verbs, so the box becomes the second verb: what the host stored
     * on that server — the devices paired to it, the folders each of them may
     * use — is kept by one and taken by the other, and
     * `HostProbe.removeConsequence` names both before anything is pressed.
     *
     * Drawn as a row rather than as one of the filled buttons above, and drawn
     * as the *same* row as "Forget this server" one card below it: the two are
     * the only destructive things on this page, they are a tap apart, and a
     * person has to be able to tell at a glance that they are the same kind of
     * act on two different things — the program on that server, and this
     * phone's record of it. `removeConsequence` is what says which is which.
     */
    @ViewBuilder
    private func removeRow(host: HostOnServer) -> some View {
        let busy = install.isBusy || isWorking
        Button(role: .destructive) {
            confirmingRemove = true
        } label: {
            Text(HostProbe.removeLabel)
                .font(.system(size: 15, weight: .medium))
                // Faint rather than gone while something else is in flight. A
                // removal that started at the same moment as an install would
                // be two scripts racing over one server.
                //
                // Red, not amber, and for the same reason its neighbour "Forget
                // this server" is red now — > "it should be like red so it is
                // clear." The two are a tap apart and the doc above says they
                // must read as the same kind of act; this one takes the host off
                // the server, which is the red kind.
                .foregroundStyle(busy ? Theme.faint : Theme.critical)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 12)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(busy)
        .accessibilityIdentifier("server.remove")
        .confirmationDialog(HostProbe.removeLabel,
                            isPresented: $confirmingRemove,
                            titleVisibility: .visible) {
            Button("Remove it", role: .destructive) {
                Task { await connector.uninstall(serverId, alsoData: false) }
            }
            Button("Remove it and everything it stored", role: .destructive) {
                Task { await connector.uninstall(serverId, alsoData: true) }
            }
            Button("Keep it", role: .cancel) {}
        } message: {
            Text(HostProbe.removeConsequence(host, alsoData: false))
        }
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
    private func stated(_ text: String,
                        identifier: String = "server.hostRefusal") -> some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(Theme.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityIdentifier(identifier)
    }
}
