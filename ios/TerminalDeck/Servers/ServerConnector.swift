/**
 * The phone's server connector: sign in, look, install, start, stop — the whole
 * of what the desktop's `ServersPanel` does, on a phone, over the phone's own
 * SSH connection.
 *
 * ## The requirement, in his words
 *
 * > *"I want it to work exactly like it works for MacBook. Say no MacBook or
 * > Windows exists at all — a user only has a server and a phone… The steps
 * > should be: first they log in to the server. Then all the server-related
 * > stuff comes up… Then it checks whether the headless Terminal Deck already
 * > exists on that server. If it exists, it brings it up and asks you to
 * > connect. If it does not exist, it gives the option to install."*
 *
 * That is the order this object executes and the order `ServerDetailView` draws.
 * There is no step in it where somebody is handed a command to go and type
 * somewhere else, and the one that used to exist is deleted rather than moved.
 *
 * ## Nothing is held open, and nothing is polled
 *
 * His standing rule: **events, not polling** — *"they make the system
 * heavier."* A connection is opened for a piece of work and closed when it ends,
 * so a server nobody is looking at costs this phone nothing. The consequence,
 * which must not be "fixed" with a timer: **what is on screen can be stale, and
 * the age is shown instead of hidden.** That is the desktop's answer too, in
 * `connection.ts`.
 *
 * The one thing that is held is the session belonging to a server whose page is
 * open — {@link open} keeps it while the screen that asked for it is up and
 * {@link release} drops it — because install, start and look are three round
 * trips somebody makes in a row, and re-running a handshake between them would
 * be three sign-ins for one visit.
 */

import Foundation
import LocalAuthentication
// For `TimeAmount`, which is how `SSHSession` spells a deadline. Nothing else
// here touches NIO — the SSH client is the only thing that does.
import NIOCore
import Observation

/**
 * Something that went wrong with one server, as two sentences a screen prints.
 *
 * It was `SSHProblem` directly, and stopped being able to be: a credential
 * behind Face ID can now fail for reasons that have nothing to do with SSH —
 * a cancelled prompt, a sensor locked out, an enrolment that changed — and
 * reporting those as *"that sign-in was refused"* would send somebody to check a
 * password that is perfectly correct. The headline/advice pair is `SSHProblem`'s
 * own shape, so nothing above this had to learn a new one.
 */
struct ServerTrouble: Error, Equatable {
    var headline: String
    var advice: String

    init(headline: String, advice: String) {
        self.headline = headline
        self.advice = advice
    }

    init(_ problem: SSHProblem) {
        headline = problem.headline
        advice = problem.advice
    }
}

/// What a look at one server came back with. Everything is stamped, because
/// nothing here refreshes on its own.
struct ServerView: Equatable {
    var facts: ServerFacts
    var host: HostLook
    var measuredAt: Date
}

/// Where an install has got to. The desktop's `HostState`, with its own words.
struct ServerInstallState: Equatable {
    enum Step: Equatable {
        case idle, checking, staging, installing, service, removing, done, failed
    }

    var step: Step = .idle
    /// The one line under the output. Written here, never in a view.
    var line = ""
    /// The server's own words when something failed. Shown behind a disclosure.
    var detail = ""
    /// Every step that has finished, in order, each already a sentence.
    var done: [String] = []
    /// What the installer printed, as it printed it.
    var output = ""

    var isBusy: Bool {
        switch step {
        case .checking, .staging, .installing, .service, .removing: return true
        case .idle, .done, .failed: return false
        }
    }
}

@MainActor
@Observable
final class ServerConnector {

    /// The most installer output kept. Enough to see what failed, bounded so a
    /// build that decides to print a line a second cannot become this app's heap.
    private static let maxOutputBytes = 256 * 1024

    /// How long an install gets before this side stops believing it is running.
    /// The desktop's ceiling, and it is generous for a reason: a server with no
    /// Node fetches a runtime, and node-pty compiles.
    private static let installTimeout: TimeAmount = .minutes(12)

    private let store: ServerStore

    /**
     * Face ID / Touch ID, held here because this is the one object that reads a
     * credential.
     *
     * Every route to a server's password goes through {@link secret}, so putting
     * the gate anywhere else would mean a second place that can forget to ask.
     */
    let biometry: BiometricGate

    private(set) var servers: [StoredServer] = []
    /// The last look at each server, by server id. Absent means never looked.
    private(set) var views: [String: ServerView] = [:]
    /// Which servers have something in flight, so a screen can disable its buttons.
    private(set) var working: Set<String> = []
    /// The last failure per server, shown until something else happens.
    private(set) var problems: [String: ServerTrouble] = [:]
    private(set) var installs: [String: ServerInstallState] = [:]

    /// Sessions belonging to open pages. See the header.
    @ObservationIgnored private var sessions: [String: SSHSession] = [:]

    /// `biometry` is optional rather than a default argument because
    /// `BiometricGate` is `@MainActor` and a default is evaluated in the
    /// caller's context — which is not always this one. Built here instead,
    /// where the isolation is already established.
    init(store: ServerStore = ServerStore(), biometry: BiometricGate? = nil) {
        self.store = store
        self.biometry = biometry ?? BiometricGate()
        servers = store.all()
    }

    /* --------------------------------------------------------- signing in -- */

    /// Where an attempt to add a server has got to.
    enum LoginPhase: Equatable {
        case editing
        /// Opening the socket and checking the server's identity.
        case reaching
        /// Signed in; asking the server what it is and what is on it.
        case looking
        case added(StoredServer)
        case failed(headline: String, advice: String)
    }

    private(set) var login: LoginPhase = .editing

    var isSigningIn: Bool {
        switch login {
        case .reaching, .looking: return true
        default: return false
        }
    }

    func resetLogin() {
        login = .editing
    }

    /**
     * Sign in to a server for the first time.
     *
     * The port is a real question and not a detail: Asad's own machine listens
     * on **2222**, and a form that quietly assumed 22 told him his server was
     * off. Empty means 22 and says so on the field.
     *
     * The host key is taken on trust the first time — there is nothing to
     * compare it against yet — and written down. Every connection after this one
     * is checked against it, and a server that answers with a different key is
     * refused before a password is offered.
     */
    func signIn(name: String,
                address: String,
                port: Int?,
                username: String,
                secret: String,
                kind: ServerCredentialKind) async {
        guard !isSigningIn else { return }
        let cleanAddress = address.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanUser = username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanAddress.isEmpty else {
            login = .failed(headline: "That sign-in needs an address.",
                            advice: "The name or number you would put after `ssh` — a hostname or "
                                + "an IP address.")
            return
        }
        guard !cleanUser.isEmpty else {
            login = .failed(headline: "That sign-in needs a username.",
                            advice: "The account you would use to sign in to that server.")
            return
        }
        // Not trimmed: a password may legitimately begin or end with a space,
        // and a private key ends with a newline that is part of the format.
        guard !secret.isEmpty else {
            login = .failed(
                headline: kind == .password ? "That sign-in needs a password." : "That sign-in needs a key.",
                advice: kind == .password
                    ? "The password for that account on that server."
                    : "Paste the private key for that account, including its BEGIN and END lines.")
            return
        }
        let realPort = port ?? ServerStore.defaultPort
        guard realPort >= 1, realPort <= 65535 else {
            login = .failed(headline: ServerDraftProblem.badPort.sentence,
                            advice: "Whoever set the server up will know which port it listens on.")
            return
        }

        login = .reaching
        let auth: SSHAuthMethod = kind == .password ? .password(secret) : .key(secret)
        do {
            let session = try await SSHSession.open(address: cleanAddress,
                                                    port: realPort,
                                                    username: cleanUser,
                                                    auth: auth,
                                                    expect: nil)
            login = .looking
            let view = try await measure(session)
            let server = try store.add(name: name,
                                       address: cleanAddress,
                                       port: realPort,
                                       username: cleanUser,
                                       secret: secret,
                                       kind: kind,
                                       hostKey: session.hostKey)
            sessions[server.id] = session
            views[server.id] = view
            servers = store.all()
            login = .added(server)
        } catch let problem as SSHProblem {
            login = .failed(headline: problem.headline, advice: problem.advice)
        } catch let problem as ServerDraftProblem {
            login = .failed(headline: problem.sentence, advice: "")
        } catch {
            login = .failed(headline: "That sign-in did not finish.",
                            advice: String(describing: error))
        }
    }

    /* -------------------------------------------------------------- looking -- */

    /**
     * Ask a server what it is, and whether the host is on it.
     *
     * Two scripts and two round trips on one connection, in the order a person
     * reads the page in: the machine first, the host second.
     */
    func look(_ id: String) async {
        guard let server = store.load(id), !working.contains(id) else { return }
        working.insert(id)
        problems[id] = nil
        defer { working.remove(id) }
        do {
            let session = try await open(server)
            views[id] = try await measure(session)
            var updated = server
            updated.lastConnectedAt = Date()
            store.save(updated)
            servers = store.all()
        } catch let trouble as ServerTrouble {
            // A lock that refused, or an enrolment that changed. Not an SSH
            // failure and not reported as one — see `secret(for:)`.
            problems[id] = trouble
        } catch let problem as SSHProblem {
            problems[id] = ServerTrouble(problem)
            drop(id)
        } catch {
            problems[id] = ServerTrouble(.lost)
            drop(id)
        }
    }

    private func measure(_ session: SSHSession) async throws -> ServerView {
        let facts = try await session.run(ProbeScripts.server)
        let host = try await session.run(ProbeScripts.host)
        return ServerView(facts: ServerProbe.read(facts.stdout),
                          host: HostProbe.read(host.stdout),
                          measuredAt: Date())
    }

    /* ------------------------------------------------------------ installing -- */

    /**
     * Put the headless host on a server, as five steps somebody watches happen.
     *
     * Check, stage, install, start, look again — the desktop's order, minus its
     * upload of a tarball. The desktop carries the package inside itself; a
     * phone cannot carry a Node package it does not build, so it sends the
     * installer and **names what that installer is to fetch**, which is
     * `ServerScripts.hostPackage`: this app's own release tarball at
     * `Brand.version`, from the release its build was cut from. Not the npm
     * registry — that route installed 0.6.1 under a 0.10 app and dead-ended at
     * the connect step with every one of these five saying success. See the
     * argument on `hostPackage` itself.
     *
     * This is also the way *back* from an out-of-date host: the same five steps
     * over an already-open session, which is why the card's refusal for a host
     * too old to print an address now offers this rather than naming a desktop.
     */
    func install(_ id: String) async {
        guard let server = store.load(id), !working.contains(id) else { return }
        working.insert(id)
        defer { working.remove(id) }

        var state = ServerInstallState()
        func step(_ next: ServerInstallState.Step, _ line: String) {
            state.step = next
            state.line = line
            installs[id] = state
        }
        func fail(_ line: String, _ detail: String = "") {
            state.step = .failed
            state.line = line
            state.detail = detail
            installs[id] = state
        }

        step(.checking, "Checking what \(server.name) has.")
        do {
            let session = try await open(server)
            let look = HostProbe.read(try await session.run(ProbeScripts.host).stdout)
            if let refusal = HostProbe.whyNot(look.room) {
                fail(refusal)
                return
            }
            state.done.append(
                HostProbe.usableNode(look.room)
                    ? "\(server.name) has Node \(look.room.node) and npm, so no runtime is needed."
                    : "\(server.name) has no Node 22 or newer, so the installer will fetch one and "
                        + "check it against the checksum Node published for it.")

            guard let installer = Self.installerScript() else {
                fail("This copy of the app does not carry the installer, so there is nothing here "
                    + "to install from.")
                return
            }

            step(.staging, "Copying the installer to \(server.name).")
            let staged = ServerScripts.stageInstaller(installer)
            let put = try await session.run(staged.script)
            let path = put.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            guard put.code == 0, !path.isEmpty else {
                fail("The installer could not be written to \(server.name).",
                     put.stderr.isEmpty ? "It ended with \(put.code)." : put.stderr)
                return
            }
            state.done.append("Copied the installer to \(path).")

            step(.installing,
                 "Installing \(Brand.name) \(Brand.version) on \(server.name). "
                     + "This takes a minute or two.")
            let ran = try await session.stream(
                command: ServerScripts.runInstaller(at: path),
                stdin: nil,
                timeout: Self.installTimeout
            ) { [weak self] chunk in
                // Already on the main queue — `SSHSession.stream` puts it there,
                // in order — so this is a statement about isolation rather than
                // a hop of its own.
                MainActor.assumeIsolated { self?.appendOutput(id, chunk) }
            }
            state.output = installs[id]?.output ?? state.output
            guard ran.code == 0 else {
                fail("The host could not be installed on \(server.name).",
                     "The installer ended with \(ran.code). Its own output is above.")
                return
            }

            let after = HostProbe.read(try await session.run(ProbeScripts.host).stdout)
            guard after.host.isInstalled else {
                fail("The install finished and there is no \(Brand.id) command on this server.")
                return
            }
            state.done.append(
                "Installed \(after.host.version.isEmpty ? "the host" : after.host.version) at "
                    + "\(after.host.command).")

            step(.service, "Setting it to start on its own.")
            state.done.append(await arrangeStart(session: session, look: after))

            // Deliberately not `try`. The install is finished and said so; a
            // look that fails after it would otherwise report a working install
            // as a failed one, which is the worst of the four possible answers.
            views[id] = try? await measure(session)
            state.step = .done
            state.line = "\(server.name) is a machine of its own now."
            installs[id] = state
        } catch let trouble as ServerTrouble {
            fail(trouble.headline, trouble.advice)
        } catch let problem as SSHProblem {
            fail(problem.headline, problem.advice)
            drop(id)
        } catch {
            fail("The install did not finish.", String(describing: error))
            drop(id)
        }
    }

    /// The installer's own words, as they arrive, with a ceiling. The tail is
    /// kept rather than the head: what failed is at the end.
    private func appendOutput(_ id: String, _ chunk: String) {
        var current = installs[id] ?? ServerInstallState()
        current.output += chunk
        if current.output.utf8.count > Self.maxOutputBytes {
            current.output = String(current.output.suffix(Self.maxOutputBytes / 2))
        }
        installs[id] = current
    }

    /**
     * Make it start on its own, and say what was actually arranged.
     *
     * Three outcomes and all three are said out loud, because the difference
     * between them is the difference between a machine that is there tomorrow
     * and one that is not. The third is not a failure of the install and is not
     * reported as one: a container has no init by design, and a host running now
     * is what somebody pressed the button for.
     */
    private func arrangeStart(session: SSHSession, look: HostLook) async -> String {
        if look.room.systemdUser {
            let unit = try? await session.run(ServerScripts.service(command: look.host.command))
            if let unit, unit.code == 0 {
                return unit.stdout.contains("linger yes")
                    ? "It runs as a systemd user service and keeps running when you log out."
                    : "It runs as a systemd user service. It will stop when your last login on this "
                        + "server ends — running `sudo loginctl enable-linger $(id -un)` once on "
                        + "that server is what stops that."
            }
            // Fall through rather than fail: a unit that would not install is a
            // reason to start it another way, not a reason to leave a working
            // install switched off.
        }
        let started = try? await session.run(
            ServerScripts.startDirect(command: look.host.command))
        return started?.code == 0
            ? "This server has no systemd user manager, so it was started directly. It is running "
                + "now and will not come back on its own after a reboot."
            : "It is installed and not running. Starting it is the button above."
    }

    /* ------------------------------------------------------------ removing -- */

    /**
     * Take it off that server again, and say what is left.
     *
     * ## Why this exists at all
     *
     * Because the install card promised it: *"It goes into your home folder on
     * that server, needs no administrator access, and can be taken off again
     * from here."* That sentence was on screen for a build in which no verb on
     * this side could remove anything — the phone had install, start and stop,
     * and the way back was a desktop. A promise a product cannot keep is worse
     * than a missing feature, and the desktop had already argued the case in
     * `host.ts`'s own header: *"If we want to uninstall we can uninstall."*
     *
     * ## The confirmation is the caller's
     *
     * `HostProbe.removeConsequence` is the sentence shown before the press, and
     * `alsoData` is the answer to it. By the time this runs the question has
     * been asked, so this does the work and reports it rather than asking
     * again — the desktop's `ServerHosts.uninstall` splits it the same way and
     * for the same reason.
     *
     * ## What is deliberately left alone
     *
     * This phone's own record of the machine. The host is gone from that
     * server, but the machine row and its pairing are this app's, not that
     * server's, and `removeConsequence` says so in as many words rather than
     * quietly reaching into somebody's Machines list. What *is* re-read is the
     * survey, because the card is drawn from it and the card must not still be
     * offering Stop for a program that is not there.
     */
    func uninstall(_ id: String, alsoData: Bool) async {
        guard let server = store.load(id),
              let look = views[id]?.host,
              look.host.isInstalled,
              !working.contains(id)
        else { return }
        working.insert(id)
        problems[id] = nil
        defer { working.remove(id) }

        var state = ServerInstallState()
        state.step = .removing
        state.line = "Stopping it and taking it off \(server.name)."
        installs[id] = state

        do {
            let session = try await open(server)
            let ran = try await session.run(
                ServerScripts.remove(command: look.host.command,
                                     dataDir: look.host.dataDir,
                                     alsoData: alsoData))
            guard ran.code == 0 else {
                state.step = .failed
                state.line = "That could not be removed from \(server.name)."
                // The server's own words, and the exit code when it had none.
                // The one refusal with a shape worth reading is the `$HOME`
                // guard in `ServerScripts.remove`: "not ours to remove", for a
                // host somebody else installed for everyone on that machine.
                let said = ran.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                state.detail = said.isEmpty ? "It ended with \(ran.code)." : said
                installs[id] = state
                return
            }
            state.done = [
                "The host program is gone, and its service with it.",
                alsoData
                    ? "\(look.host.dataDir) is gone too, so any device paired to it will need pairing "
                        + "again."
                    : "\(look.host.dataDir) was left alone — the devices paired to it and the folders "
                        + "each of them may use are still there for a later install.",
            ]
            state.step = .done
            state.line = "It was removed from \(server.name)."
            installs[id] = state
            // `try?`, for the reason `install` gives: the removal is finished
            // and has said so, and a survey that fails a moment later must not
            // turn a completed removal into a failed one. The card falls back
            // to "nothing has been looked at on this server yet" and its Check
            // button, which is a true thing to say about a phone that has just
            // lost its connection.
            views[id] = try? await measure(session)
        } catch let trouble as ServerTrouble {
            state.step = .failed
            state.line = trouble.headline
            state.detail = trouble.advice
            installs[id] = state
        } catch let problem as SSHProblem {
            state.step = .failed
            state.line = problem.headline
            state.detail = problem.advice
            installs[id] = state
            drop(id)
        } catch {
            state.step = .failed
            state.line = "That removal did not finish."
            state.detail = String(describing: error)
            installs[id] = state
            drop(id)
        }
    }

    /* --------------------------------------------------------- start & stop -- */

    func start(_ id: String) async {
        await control(id, running: true)
    }

    func stop(_ id: String) async {
        await control(id, running: false)
    }

    private func control(_ id: String, running: Bool) async {
        guard let server = store.load(id), let look = views[id]?.host, !working.contains(id) else {
            return
        }
        working.insert(id)
        problems[id] = nil
        defer { working.remove(id) }
        do {
            let session = try await open(server)
            let script = running
                ? ServerScripts.start(command: look.host.command,
                                      hasUnit: !look.host.unit.isEmpty,
                                      systemdUser: look.room.systemdUser)
                : ServerScripts.stop(command: look.host.command, hasUnit: !look.host.unit.isEmpty)
            _ = try await session.run(script)
            if running {
                /*
                 * **Started is not reachable**, and the difference is the whole
                 * of the bug this closes.
                 *
                 * Both start scripts return the instant the daemon is forked —
                 * `systemctl start` by design, `nohup` by definition — while
                 * the thing a phone actually needs is a *relay dial* that has
                 * not happened yet. So the survey below read a `status` with no
                 * address block, `canConnect` answered false, and "start it and
                 * connect" started it and connected to nothing, silently.
                 *
                 * `ServerScripts.address` is the wait, and it is the host's own
                 * — it knows how old the daemon is and stops waiting when the
                 * answer cannot improve. Its result is ignored on purpose; what
                 * this call buys is the seconds, and the survey on the next
                 * line is what reads the answer.
                 *
                 * `try?`, not `try`: an older host has no `address` verb, and a
                 * host that will not start has already failed in a way the
                 * survey reports properly. Neither is a reason to throw away a
                 * measurement that would have said so.
                 *
                 * `working` still holds `id` for all of this — deliberately, so
                 * the spinner on the card is still turning while the wait
                 * happens rather than the card sitting still and looking done.
                 */
                _ = try? await session.run(ServerScripts.address(command: look.host.command))
            }
            views[id] = try await measure(session)
        } catch let trouble as ServerTrouble {
            problems[id] = trouble
        } catch let problem as SSHProblem {
            problems[id] = ServerTrouble(problem)
            drop(id)
        } catch {
            problems[id] = ServerTrouble(.lost)
            drop(id)
        }
    }

    /* ----------------------------------------------------------- connecting -- */

    /**
     * What a connect needs, or nil when this server cannot be connected to yet.
     *
     * The connect itself is `ServerSignIn` — the door that already exists, over
     * the relay, spending the same SSH login this phone already holds. Nothing
     * new is invented for it: the host verifies that login against its own sshd
     * and mints a device credential, exactly as it does for an address somebody
     * pasted.
     */
    func connectTicket(_ id: String) async -> (address: String, username: String,
                                               secret: String, method: EnrollMethod)? {
        guard let server = store.load(id),
              let host = views[id]?.host.host,
              !host.address.isEmpty
        else { return nil }
        // Through the lock, like every other read. A cancelled prompt lands as a
        // stated problem on the page rather than as a Connect button that did
        // nothing at all — which is the dead control this product does not ship.
        do {
            let secret = try await secret(for: server)
            problems[id] = nil
            return (host.address, server.username, secret,
                    server.credential == .key ? .key : .password)
        } catch let trouble as ServerTrouble {
            problems[id] = trouble
            return nil
        } catch let problem as SSHProblem {
            problems[id] = ServerTrouble(problem)
            return nil
        } catch {
            problems[id] = ServerTrouble(headline: "That sign-in could not be read.",
                                         advice: String(describing: error))
            return nil
        }
    }

    /// Whether a Connect can even be offered without a prompt-and-fail: the same
    /// two questions `connectTicket` asks before it touches the Keychain.
    func canConnect(_ id: String) -> Bool {
        guard let host = views[id]?.host.host else { return false }
        return !host.address.isEmpty && store.load(id) != nil
    }

    /* ------------------------------------------------------------ bring up -- */

    /**
     * Start the host if it is here and not running, then look again.
     *
     * *"If it exists, it brings it up and asks you to connect."* Two verbs
     * somebody would otherwise press in sequence, joined — because the screen
     * that offers this is the one immediately after a login, where the person
     * has said what they want and should not have to press Start, wait, read,
     * and then press Connect.
     */
    func bringUp(_ id: String) async {
        guard let look = views[id]?.host, look.host.isInstalled else { return }
        // `start` does not return until the host has been asked for its address,
        // so by the time this does, `views[id]` either has one to dial or the
        // server has said why it never will. That is what makes the caller's
        // next line — a connect — worth writing. See `control`.
        if look.host.running != .yes { await start(id) }
    }

    /// Remember which machine row this server became, so the page can say
    /// "connected" and disconnect without signing in again.
    func markConnected(_ id: String, hostId: String) {
        guard var server = store.load(id) else { return }
        server.linkedHostId = hostId
        server.lastConnectedAt = Date()
        store.save(server)
        servers = store.all()
    }

    func markDisconnected(_ id: String) {
        guard var server = store.load(id) else { return }
        server.linkedHostId = nil
        store.save(server)
        servers = store.all()
    }

    /* --------------------------------------------------------------- rest -- */

    func rename(_ id: String, to name: String) {
        guard var server = store.load(id) else { return }
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        server.name = String(clean.prefix(64))
        store.save(server)
        servers = store.all()
    }

    /// Forget a server here. Nothing on the far end changes — this phone stops
    /// holding its address and its sign-in, and that is all.
    func forget(_ id: String) {
        drop(id)
        store.forget(id)
        views[id] = nil
        problems[id] = nil
        installs[id] = nil
        servers = store.all()
    }

    func server(_ id: String) -> StoredServer? {
        servers.first { $0.id == id }
    }

    /// Drop the session belonging to a page that has closed.
    func release(_ id: String) {
        drop(id)
    }

    /* ------------------------------------------------------------- inside -- */

    /**
     * The password or key for one server — and, for anyone who has one, the last
     * time a per-server lock ever asks.
     *
     * The single door to a credential in this app. **Nothing turns a per-server
     * lock on any more**: the offer after a login and the switch on the server's
     * page are both gone, because putting one server's password behind the
     * sensor is what made this app ask for a face every time it opened. The lock
     * is at the front door now — one switch in Settings, `AppLock`.
     *
     * What survives here is the read path, and it survives for exactly one
     * reason: a phone that ran the previous build may be holding a credential
     * with a `SecAccessControl` on it right now, and a build that simply stopped
     * knowing about that would be a phone that can no longer open its own
     * server. So a locked item is still read through `BiometricGate`, the
     * authenticated context is still handed to the Keychain so the read behind
     * the prompt raises no second sheet — **and then the lock is lifted**, using
     * the context already in hand, so it costs no extra prompt and never happens
     * again. The secret stays exactly where it was: same Keychain item, same
     * account, `WhenUnlockedThisDeviceOnly`, never synced. Only the access
     * control comes off, and it comes off because the person asked for that in
     * as many words: *"If it is that way then remove the face lock."*
     *
     * Every outcome throws something a screen can print. **Cancelled is not a
     * refusal** — somebody who dismisses the sheet gets a sentence saying so and
     * the button they pressed is still there, which is the difference between a
     * choice and a dead end.
     */
    private func secret(for server: StoredServer) async throws -> String {
        guard server.isBiometricLocked else {
            guard let plain = store.secret(for: server.id) else { throw SSHProblem.signInRefused }
            return plain
        }
        let availability = biometry.look()
        switch await biometry.unlock(reason: "Unlock the sign-in for \(server.name)") {
        case let .unlocked(context):
            guard let secret = store.secret(for: server.id, context: context) else {
                /*
                 * Authenticated, and the item still would not come back.
                 *
                 * That is what `.biometryCurrentSet` looks like after somebody
                 * adds a face or a finger: the Enclave drops the item rather
                 * than handing it to an enrolment it was not locked to. It is
                 * the protection working, and the only way out is the password
                 * once — so that is what it says, instead of "refused".
                 */
                throw ServerTrouble(
                    headline: "That sign-in is no longer readable on this iPhone.",
                    advice: "\(availability.name) was locked to the faces and fingers enrolled when "
                        + "you turned it on, and that set has changed. Log in to this server once "
                        + "more — nothing will lock it again.")
            }
            /*
             * The one-time lift. Free, because the authentication that just
             * happened is still valid: `setBiometricLock(false:)` re-reads the
             * item with this same context and writes it back without the access
             * control, so there is no second prompt. A failure is swallowed
             * deliberately — the secret is in hand and the connection should
             * proceed; the lift is simply retried the next time, and until then
             * the behaviour is exactly what it was.
             */
            try? store.setBiometricLock(false, for: server.id, context: context)
            servers = store.all()
            biometry.forget()
            return secret
        case .cancelled:
            throw ServerTrouble(
                headline: "\(availability.name) was cancelled.",
                advice: "Nothing was sent. Press the button again — this sign-in was locked by an "
                    + "older build of this app, and unlocking it once takes the lock off for good.")
        case let .lockedOut(kind):
            let name = kind.name ?? "Biometric unlock"
            throw ServerTrouble(
                headline: "\(name) is locked.",
                advice: "Too many attempts failed. Unlock this iPhone with its passcode once and it "
                    + "comes back — the passcode also works on the prompt itself.")
        case let .notEnrolled(kind):
            let name = kind.name ?? "Biometric unlock"
            throw ServerTrouble(
                headline: "\(name) is not set up any more.",
                advice: "It was when an older build of this app locked this sign-in. Set it up "
                    + "again in Settings, or log in to this server once and the lock is gone.")
        case .unavailable:
            throw ServerTrouble(
                headline: "This iPhone cannot unlock that sign-in.",
                advice: "Its passcode still can — the prompt offers it. If it does not appear, log "
                    + "in to this server again.")
        case let .failed(said):
            throw ServerTrouble(headline: "That unlock did not finish.", advice: said)
        }
    }

    private func open(_ server: StoredServer) async throws -> SSHSession {
        if let live = sessions[server.id], live.isOpen { return live }
        sessions[server.id] = nil
        let secret = try await secret(for: server)
        let session = try await SSHSession.open(
            address: server.address,
            port: server.port,
            username: server.username,
            auth: server.credential == .key ? .key(secret) : .password(secret),
            expect: server.hostKey?.fingerprint)
        sessions[server.id] = session
        return session
    }

    private func drop(_ id: String) {
        sessions[id]?.close()
        sessions[id] = nil
    }

    /**
     * The installer, read out of the app bundle.
     *
     * `scripts/install-headless.sh` itself, referenced by `project.yml` rather
     * than copied into `ios/` — one file, one source, and a change to the
     * installer reaches the phone in the same commit it reaches the desktop.
     */
    private static func installerScript() -> String? {
        guard let url = Bundle.main.url(forResource: "install-headless", withExtension: "sh"),
              let text = try? String(contentsOf: url, encoding: .utf8)
        else { return nil }
        return text
    }
}
