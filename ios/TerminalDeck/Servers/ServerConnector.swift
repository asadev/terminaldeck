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
        case idle, checking, staging, installing, service, done, failed
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
        case .checking, .staging, .installing, .service: return true
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
     * upload of a tarball. The desktop carries the package because the npm name
     * used to be a placeholder with no `bin` entry; the registry now carries a
     * real one, so the phone sends the installer and lets it fetch what it was
     * written to fetch. What the phone cannot do is carry a Node package it does
     * not build, and it does not have to.
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

    /* ------------------------------------------------------------ the lock -- */

    /**
     * Put this server's sign-in behind Face ID / Touch ID, or take it back out.
     *
     * Returns nil on success and a sentence on failure — never a bare bool. Every
     * way this can fail is something a person did or something their phone is,
     * and each of them has to reach the screen intact: a cancelled prompt, a
     * sensor with nothing enrolled on it, a phone with no passcode.
     */
    @discardableResult
    func setBiometricLock(_ on: Bool, for id: String) async -> String? {
        guard let server = store.load(id) else { return nil }
        let availability = biometry.look()
        if on, !availability.isReady { return availability.refusal }

        // Turning it **on** needs an authentication too, and that is deliberate
        // rather than ceremony: it proves the person switching it on is the
        // person the sensor will be checking for afterwards.
        var context: LAContext?
        switch await biometry.unlock(reason: on
            ? "Lock the sign-in for \(server.name)"
            : "Unlock the sign-in for \(server.name)") {
        case let .unlocked(ready):
            context = ready
        case .cancelled:
            return nil // Not a failure. Nothing changed and nothing is said.
        case let .lockedOut(kind):
            return "\(kind.name ?? "Biometric unlock") is locked after too many attempts. Unlock "
                + "this iPhone with its passcode once and it comes back."
        case let .notEnrolled(kind):
            return BiometryAvailability.notEnrolled(kind).refusal
        case .unavailable:
            return BiometryAvailability.unavailable.refusal
        case let .failed(said):
            return said
        }

        do {
            try store.setBiometricLock(on, for: id, context: context)
            servers = store.all()
            // The held session was opened with the credential as it was; nothing
            // about it is wrong, and dropping it would cost a handshake for a
            // change that did not touch the connection.
            if !on { biometry.forget() }
            return nil
        } catch let problem as ServerStore.LockProblem {
            servers = store.all()
            return problem.sentence
        } catch {
            return String(describing: error)
        }
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
     * The password or key for one server, through the lock when there is one.
     *
     * The single door to a credential in this app. A server with
     * `biometricLock` off reads straight out of the Keychain as it always did; a
     * locked one goes through `BiometricGate` first, and the authenticated
     * context is handed to the Keychain so the read behind the prompt does not
     * raise a second one.
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
                        + "more and you can turn it back on.")
            }
            return secret
        case .cancelled:
            throw ServerTrouble(
                headline: "\(availability.name) was cancelled.",
                advice: "Nothing was sent. Press the button again to try, or turn "
                    + "\(availability.name) off for this server on its own page and type the "
                    + "password instead.")
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
                advice: "It was when this server was locked. Set it up again in Settings, or log in "
                    + "to this server once and turn the lock off.")
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
