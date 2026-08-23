/**
 * Signing this phone into a server, over a socket this object opens itself.
 *
 * ## What was missing, and what this is
 *
 * `SignInLink.swift` has been the tested client half of `enroll` since wave 1 —
 * the fixed frame sequence, driven, with no socket of its own. Its header says
 * so plainly: *"it does not open the socket, and it does not know how the sealed
 * channel to a first-contact host was established — that is the rendezvous
 * layer's problem, and a real one."* Nothing in the app ever solved that
 * problem, so the driver had no caller and the phone had no way to sign in to
 * anything. That is the whole of the gap 0.10.0 shipped with.
 *
 * This is the missing half: it takes a **server address** (see
 * `ServerAddress.swift` for why a host id alone cannot start a handshake), opens
 * a sealed relay channel to it with **this phone's own device key**, drives
 * `SignIn` across it, and writes the credential the server mints.
 *
 * ## The device key, not a throwaway
 *
 * `RendezvousLookup` dials with a throwaway pair, deliberately, because nothing
 * at the far end of a rendezvous stores who dialled. The opposite is true here.
 * `enroll.ts` binds the minted device row to `connection.peerPublicKey` — the
 * handshake's key — and `device-auth.ts` refuses any later handshake from a key
 * it does not know. So a sign-in run on a throwaway key would mint a device this
 * phone can never present again: a screen that says "signed in" over a machine
 * that will refuse the next connection. The durable key is the identity being
 * enrolled, so the durable key is what dials.
 *
 * ## Why it reconnects instead of keeping the socket
 *
 * The exchange ends on a `welcome`, which means this socket is *already* an
 * authenticated session. It is still torn down, and the machine is brought up
 * again through the ordinary `HostLink`. Keeping it would mean a second, special
 * path into every screen in the app — one live socket that did not come from a
 * `LiveTransport` and has none of its reconnect, heartbeat or credential
 * handling — for the sake of one round trip. Pairing has always taken the same
 * shape (`DeckModel.pairAsync` writes the record and starts the link), and this
 * matching it is what keeps the end state of the two doors identical.
 *
 * The welcome is still waited for rather than skipped. Stopping at `enrolled`
 * would be saving a credential nothing has ever spent, and calling that success.
 *
 * ## The secret is used and dropped
 *
 * The SSH password or key is held for exactly as long as the exchange, and
 * `forgetSecret` runs on every path out of it — success, refusal, timeout,
 * cancel. It is never written to the Keychain, to `UserDefaults`, or to any
 * store: what replaces it is the minted device credential, which is the point of
 * the whole ceremony. The server does the same on its side — `enroll.ts`: *"the
 * secret is used for the one probe and referenced nowhere after."*
 */

import Foundation
import Observation

@MainActor
@Observable
final class ServerSignIn {

    /**
     * What is happening, in the only five states this can honestly be in.
     *
     * The three middle ones are separate because they fail differently and a
     * person can act on the difference: nothing answering at the address is not
     * the same as a server that answered and is checking a password against its
     * own sshd, which is not the same as one that has minted a credential and is
     * being asked to honour it.
     */
    enum Phase: Equatable {
        /// Nothing in flight. The form is the screen.
        case editing
        /// Opening the socket and running the sealed handshake.
        case reaching
        /// `enroll` is out; the server is checking the login against its own sshd.
        case verifying
        /// It minted a credential; this is the `hello` that spends it.
        case joining
        /// Done. The machine is in the list and its sessions are usable.
        case signedIn(hostId: String, name: String)
        case failed(Failure)
    }

    /**
     * A refusal a person can do something about.
     *
     * Two fields rather than one sentence, because the headline is what went
     * wrong and the advice is what to do next, and collapsing them produces the
     * paragraph this product does not put on screens. Never a spinner that ends
     * nowhere: every path out of `reaching`, `verifying` and `joining` lands on
     * one of these or on `signedIn`.
     */
    struct Failure: Equatable {
        let headline: String
        let advice: String
    }

    private(set) var phase: Phase = .editing

    /// Whether something is in flight. Drives the button, and the guard that
    /// stops a second tap starting a second socket.
    var isBusy: Bool {
        switch phase {
        case .reaching, .verifying, .joining: return true
        case .editing, .signedIn, .failed: return false
        }
    }

    /**
     * The wait before the sealed channel is declared dead.
     *
     * Longer than the socket's own 20-second request timeout, so that a relay
     * that accepts and never answers is reported by the carrier's own words
     * rather than by this stopwatch — the carrier knows things this does not,
     * such as whether it got far enough to put a handshake on the wire.
     */
    private static let reachTimeout: TimeInterval = 25

    /**
     * The wait for an answer to `enroll`.
     *
     * Generous on purpose. The server's answer is a real SSH login against its
     * own sshd — `ssh-verify.ts` — behind a two-probe gate, and a phone that
     * gave up at ten seconds would report a working server as broken every time
     * somebody else was signing in at the same moment.
     */
    private static let verifyTimeout: TimeInterval = 45

    private let credentials: CredentialStore
    private let device: DeviceDescriptor
    private let makeCarrier: (DeckEndpoint, StaticKeyPair) -> Carrier
    private let onSignedIn: (StoredCredential) -> Void

    private var carrier: Carrier?
    private var driver: SignIn?
    private var endpoint: DeckEndpoint?
    /// Held for the length of the exchange and nothing longer. See the header.
    private var secret = ""
    /// The code on the last `error` frame, kept because `SignIn` collapses an
    /// error to its sentence and the code is what says whether this server
    /// *refused* the login or cannot offer sign-in at all.
    private var refusalCode: ProtocolErrorCode?
    /// Bumped on every attempt, so a timer armed by an abandoned one does nothing.
    private var generation = 0

    /// `makeCarrier` is the one seam for the network: the tests drive this
    /// against a scripted carrier rather than a relay.
    init(credentials: CredentialStore,
         device: DeviceDescriptor,
         makeCarrier: @escaping (DeckEndpoint, StaticKeyPair) -> Carrier = LiveTransport.defaultCarrier,
         onSignedIn: @escaping (StoredCredential) -> Void) {
        self.credentials = credentials
        self.device = device
        self.makeCarrier = makeCarrier
        self.onSignedIn = onSignedIn
    }

    // MARK: - Driving one sign-in

    /**
     * Sign in, or say why not.
     *
     * The three refusals before a socket is opened are all about the form, and
     * each is answered on the form rather than by dialling something that cannot
     * work: an address that does not parse, a missing username, a missing
     * secret. Only after those does anything touch the network.
     */
    func submit(address: String, username: String, secret: String, method: EnrollMethod) {
        guard !isBusy else { return }

        let endpoint: DeckEndpoint
        switch ServerAddress.parse(address) {
        case let .failure(error):
            phase = .failed(Failure(headline: "That server address was not readable.",
                                    advice: error.detail))
            return
        case let .success(parsed):
            endpoint = parsed
        }

        let account = username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !account.isEmpty else {
            phase = .failed(Failure(
                headline: "That sign-in needs a username.",
                advice: "The account you would use to SSH into that server."))
            return
        }
        // Not trimmed. A password may legitimately begin or end with a space,
        // and a private key ends with a newline that is part of the format.
        guard !secret.isEmpty else {
            phase = .failed(Failure(
                headline: method == .password ? "That sign-in needs a password." : "That sign-in needs a key.",
                advice: method == .password
                    ? "The password for that account on that server."
                    : "Paste the private key for that account, including its BEGIN and END lines."))
            return
        }

        generation &+= 1
        let epoch = generation
        self.endpoint = endpoint
        self.secret = secret
        refusalCode = nil
        phase = .reaching

        let carrier = makeCarrier(endpoint, credentials.deviceKeys())
        self.carrier = carrier
        carrier.onEvent = { [weak self] event in
            guard let self, self.generation == epoch else { return }
            switch event {
            case .ready:
                self.opened(account: account, method: method)
            case let .text(text):
                self.received(text)
            case let .closed(close):
                self.closed(close)
            }
        }
        carrier.open()

        after(Self.reachTimeout, epoch: epoch) { [weak self] in
            guard let self, case .reaching = self.phase else { return }
            self.fail(Failure(
                headline: "That server did not answer.",
                advice: "The address was reached and nothing on the other end replied. Check the "
                    + "server is awake and running \(Brand.name), then try again."))
        }
    }

    /// Give up on an exchange in flight. The screen's Cancel, and the only thing
    /// that stops a sign-in early.
    func cancel() {
        guard isBusy else { return }
        forgetSecret()
        generation &+= 1
        teardown()
        phase = .editing
    }

    /// Put the form back after a refusal, so the person can fix one field rather
    /// than being left on a dead end.
    func edit() {
        guard !isBusy else { return }
        phase = .editing
    }

    // MARK: - The exchange

    private func opened(account: String, method: EnrollMethod) {
        guard case .reaching = phase else { return }
        phase = .verifying

        let driver = SignIn(send: { [weak self] message in
            _ = self?.carrier?.send(WireCodec.encode(message))
        }, onOutcome: { [weak self] outcome in
            self?.settle(outcome)
        })
        self.driver = driver
        driver.start(SignInInput(username: account, secret: secret, method: method, device: device))

        let epoch = generation
        after(Self.verifyTimeout, epoch: epoch) { [weak self] in
            guard let self else { return }
            switch self.phase {
            case .verifying, .joining:
                self.fail(Failure(
                    headline: "That server has not finished checking the sign-in.",
                    advice: "It checks the login against its own SSH, and that has not come back. "
                        + "Try again in a moment."))
            default:
                return
            }
        }
    }

    private func received(_ raw: String) {
        guard case let .ok(message, _) = WireCodec.decode(raw) else {
            // A frame this build cannot read is dropped rather than fatal: the
            // driver ignores everything before the welcome anyway, and a message
            // type added on the server side must not end a sign-in.
            return
        }
        // Read before the driver sees it, because the driver keeps the sentence
        // and throws the code away — and the code is the difference between a
        // wrong password and a server that has no sign-in to offer.
        if case let .error(code, _) = message { refusalCode = code }
        if case .enrolled = message, case .verifying = phase { phase = .joining }
        driver?.receive(message)
    }

    private func settle(_ outcome: SignInOutcome) {
        switch outcome {
        case let .ok(token, deviceId, deviceName):
            guard let endpoint else { return }
            // A machine signed into twice keeps the name its owner gave it, the
            // same rule a re-pair follows.
            let existing = credentials.load(endpoint.hostId)
            let stored = StoredCredential(endpoint: endpoint,
                                          token: token,
                                          kind: .device,
                                          deviceId: deviceId,
                                          deviceName: deviceName,
                                          pairedAt: existing?.pairedAt ?? Date(),
                                          nickname: existing?.nickname,
                                          hostName: existing?.hostName)
            // Written before anything is said on screen. A screen that reported
            // success ahead of the write would be a machine that vanishes when
            // the app is killed a second later — with a device row on the server
            // that nothing can ever present again.
            credentials.save(stored)
            forgetSecret()
            generation &+= 1
            teardown()
            phase = .signedIn(hostId: stored.hostId, name: stored.label)
            onSignedIn(stored)

        case let .failed(message):
            fail(refusal(message))
        }
    }

    /**
     * What the server's refusal means, in words that name the next move.
     *
     * The sentence is the server's own wherever it has one — those are written
     * for a person and `enroll.ts` deliberately collapses a bad password and a
     * rate-limited address into one of them — and the code decides which
     * headline it sits under.
     */
    private func refusal(_ message: String) -> Failure {
        let said = message.isEmpty ? nil : message
        switch refusalCode {
        case .some(.unavailable):
            /*
             * The headline used to read "That server does not offer sign-in",
             * and on 2026-08-22 that sentence was a lie for an entire evening.
             *
             * `unavailable` is not one thing. The host sends it when sign-in is
             * genuinely switched off, when its own sshd did not answer the
             * loopback probe, when it is out of device slots, and when it could
             * not write the new device row. Three of those four are a running
             * server that serves sign-in perfectly — and the one that happened
             * was an sshd on a non-standard port, with the phone insisting the
             * feature was not built into the machine.
             *
             * The wire cannot tell them apart (the code is the same and a fifth
             * error code would print as "unknown" on every shipped client), so
             * the headline says only what is true of all four and the host's own
             * sentence carries the rest. Since 2026-08-23 that sentence names
             * the port it dialled and the variable that moves it.
             */
            return Failure(
                headline: "That server could not sign this device in.",
                advice: said ?? "Pair it with a code from its own screen instead.")
        case .some(.version):
            return Failure(
                headline: "The two ends do not speak the same protocol.",
                advice: said ?? "Update whichever of the app and the server is older.")
        case .some(.badMessage), .some(.tooLarge), .some(.unknownSession), .none:
            // An older server does not know the word `enroll` at all: it refuses
            // the frame as a bad message rather than as a bad login. Saying "that
            // sign-in was refused" there would send somebody to check a password
            // that was never read.
            return Failure(
                headline: "That server is too old to sign a phone in.",
                advice: "It did not recognise the sign-in. Update \(Brand.name) on the server, or "
                    + "pair it with a code from its own screen instead.")
        case .some(.unauthorized), .some(.unauthenticated):
            return Failure(
                headline: "That sign-in was refused.",
                advice: said ?? "Check the username, and the password or key, then try again.")
        }
    }

    private func closed(_ close: CarrierClose) {
        switch phase {
        case .editing, .signedIn, .failed:
            // Either this side hung up on purpose, or the exchange has already
            // settled and this is the socket going away behind it.
            return
        case .reaching, .verifying, .joining:
            break
        }

        if close.beforeReady {
            // The carrier's own sentence, because it knows things this does not
            // — whether it reached the relay at all, and whether the handshake
            // was ever put on the wire. A server older than sign-in refuses the
            // handshake outright (`isKnownDevice` in `server.ts` lets a stranger
            // through only when sign-in is served), so it arrives here rather
            // than as a refusal, and the advice has to name that too.
            fail(Failure(
                headline: "Could not reach that server.",
                advice: (close.detail.map { $0 + " " } ?? "")
                    + "Check the server is awake and running \(Brand.name). A server too old to "
                    + "offer sign-in refuses a first connection the same way — pair that one with a "
                    + "code instead."))
            return
        }

        fail(Failure(
            headline: "That server hung up part way through.",
            advice: (close.detail.map { $0 + " " } ?? "")
                + "Nothing was signed in. Try again."))
    }

    private func fail(_ failure: Failure) {
        forgetSecret()
        generation &+= 1
        teardown()
        phase = .failed(failure)
    }

    /**
     * Drop the SSH secret.
     *
     * Called on every path out of an exchange. Overwritten rather than left to
     * be reassigned later: a `String` this class stops referencing is a `String`
     * whose bytes are wherever the allocator left them, and the honest thing
     * available in Swift is to stop holding it at the first moment it is no
     * longer needed. Nothing else in this app is ever handed it.
     */
    private func forgetSecret() {
        secret = ""
    }

    private func teardown() {
        driver = nil
        carrier?.onEvent = nil
        carrier?.close()
        carrier = nil
    }

    private func after(_ delay: TimeInterval, epoch: Int, _ body: @escaping @MainActor () -> Void) {
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self, self.generation == epoch else { return }
            body()
        }
    }
}
