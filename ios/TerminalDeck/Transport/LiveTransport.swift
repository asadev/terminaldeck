/**
 * The real connection: a carrier, the JSON protocol on top of it, and the
 * reconnect schedule around both.
 *
 * This replaces the `WebSocketTransport` that was written against the tailnet
 * server and never run. What it adds beyond a socket is the three states the
 * old one could not express, all of which come from the desktop answering a
 * `hello` in ways that are not "yes":
 *
 *  - **Paired, not approved.** The Mac requires a human to approve a new device
 *    (`device-auth.ts`: "Pairing alone is not trust"). The desktop's answer is a
 *    `welcome` that carries the durable credential, followed by an `error`
 *    frame and a close. That is not a failure and must not be shown as one; the
 *    reconnect schedule becomes the poll for approval.
 *  - **Refused for good.** A revoked device, or a pairing code that was already
 *    spent. Retrying makes it worse — the desktop counts failed attempts and
 *    locks a device out for fifteen minutes — so this stops and hands the app
 *    back to the pairing screen.
 *  - **The wrong protocol version.** Retrying cannot help; only an update can.
 *
 * ## Telling those apart without guessing
 *
 * The desktop spends the same `unauthorized` code on "this device is not
 * approved" and on "attach to that session before typing into it". Reading the
 * second as the first tore down a live session in the browser client and put a
 * pairing instruction on screen over it. The difference is not in the code and
 * not in the words: **a refusal closes the socket and an in-session error does
 * not**. So an `unauthorized` frame is held rather than acted on, and what
 * happens next decides what it meant.
 *
 * The one signal that needs no waiting is a `welcome` carrying a non-null
 * `token`. `server.ts` sends that shape only on the path where pairing
 * succeeded and the device was *not* admitted, so it is a reliable "you are
 * pending" — the state goes straight there instead of flashing "Connected" for
 * the few milliseconds before the refusal lands.
 */

import Foundation

@MainActor
final class LiveTransport: Transport {

    /// A pong crosses a relay in milliseconds. Ten seconds is a dead socket.
    private static let pongGrace: TimeInterval = 10
    /// The desktop closes an unauthenticated socket after eight seconds, so this
    /// only ever fires against something that is not the desktop — a captive
    /// portal, or a middlebox holding a connection open and saying nothing.
    private static let handshakeTimeout: TimeInterval = 20
    /// How long an unrefuted `welcome`-with-a-token stays "pending" before it is
    /// believed. See the note in `handle`.
    private static let refusalGrace: TimeInterval = 2

    private(set) var state: ConnectionState = .offline {
        didSet { if state != oldValue { onEvent?(.state(state)) } }
    }

    private(set) var capabilities: Set<String> = []

    var onEvent: ((TransportEvent) -> Void)?

    /// Which machine this transport is for. Every credential lookup names it,
    /// so a transport can never spend one host's token on another's socket.
    let hostId: String

    private let device: DeviceDescriptor
    private let credentials: CredentialStore
    private let backoff: Backoff
    private let makeCarrier: (DeckEndpoint, StaticKeyPair) -> Carrier

    private var carrier: Carrier?
    private var stopped = true
    private var greeted = false
    private var awaitingPong = false
    /// The device is paired but not approved, and every reconnect from here is a
    /// poll for that approval. Held separately from `state.phase` because
    /// `connect` overwrites the phase with `.connecting`, which is how the
    /// browser client once lost the one sentence telling the user to go and
    /// press the button, half a second after showing it.
    private var awaitingApproval = false
    private var approvalDetail = "Waiting for approval on the desktop."
    /// Whether the Mac has answered *on this attempt* — a frame that decoded,
    /// which for a relay endpoint means the sealed channel opened and the far
    /// end therefore holds the Mac's static private key.
    private var macAnswered = false
    /// The same fact about the attempt that has just ended, kept so the next
    /// connect can tell "polling for approval" from "still cannot reach it".
    private var macAnsweredLastAttempt = false
    /// An `unauthorized` frame that has not yet been shown to mean anything.
    private var heldRefusal: (code: ProtocolErrorCode, message: String)?
    /// Bumped on every connect so a timer armed by a dead socket does nothing.
    private var generation = 0

    init(hostId: String,
         device: DeviceDescriptor,
         credentials: CredentialStore,
         backoff: Backoff = Backoff(),
         makeCarrier: @escaping (DeckEndpoint, StaticKeyPair) -> Carrier = LiveTransport.defaultCarrier) {
        self.hostId = hostId
        self.device = device
        self.credentials = credentials
        self.backoff = backoff
        self.makeCarrier = makeCarrier
    }

    /// The one place that decides which pipe a stored endpoint means.
    static func defaultCarrier(_ endpoint: DeckEndpoint, _ keys: StaticKeyPair) -> Carrier {
        switch endpoint {
        case let .relay(_, _, hostKey):
            return RelayCarrier(url: endpoint.socketURL, hostKey: hostKey, deviceKeys: keys)
        case .direct:
            return DirectCarrier(url: endpoint.socketURL)
        }
    }

    // MARK: - Transport

    func start() {
        guard stopped else { return }
        stopped = false
        connect()
    }

    func stop() {
        stopped = true
        awaitingApproval = false
        macAnswered = false
        macAnsweredLastAttempt = false
        heldRefusal = nil
        generation &+= 1
        dropCarrier()
        state = .offline
    }

    func resume() {
        guard !stopped else { return }
        // A refused credential and a version mismatch do not become true again
        // because the phone came out of a pocket, and the desktop locks a device
        // out after repeated failures, so retrying one is actively harmful.
        switch state.phase {
        case .rejected, .incompatible, .connecting:
            return
        case .online:
            // NOT a no-op, which is what this used to be, and the bug was
            // invisible because the code that did nothing looked correct: the
            // connection is already up, so there is nothing to reconnect.
            //
            // Except that `.online` was established before the app was
            // suspended, and nothing about being suspended is reported to a
            // socket. iOS hands the app back exactly the state it had, including
            // a `carrier` whose TCP connection a carrier NAT reclaimed while the
            // phone was in a pocket. The heartbeat is the only thing that would
            // notice, and `realign` had just pushed its next tick a full interval
            // away — so the badge read **Connected**, on nothing, for up to
            // thirty-five seconds. That is the app lying about the one thing it
            // must never lie about.
            //
            // So: doubt it, say so, and ask.
            probe()
            return
        default:
            break
        }
        backoff.reset()
        connect()
    }

    /**
     * Ask the far end to prove it is still there, now.
     *
     * The state stays `.online` — the session and the carrier are still there and
     * are probably fine — and this stops *claiming* to be verified until an
     * answer arrives. That is the whole job: honesty about the badge.
     *
     * It deliberately arms **no deadline of its own**. Tearing a connection down
     * belongs to the heartbeat and to nothing else; giving this its own ten-second
     * grace added a second, more trigger-happy killer that fired whenever the app
     * came forward on a busy phone and the pong was merely slow — turning a
     * working session into a reconnect for no reason. The unanswered ping is not
     * lost: `beat` finds `awaitingPong` still true on the next tick and ends the
     * connection then, which is the path that has always owned this decision.
     * Until it does, the pill reads "Checking" rather than "Connected", which is
     * the true statement in the meantime.
     */
    private func probe() {
        guard carrier != nil, state.phase == .online else { return }
        state.verified = false
        // Coming to the foreground runs both `Heartbeat.realign`, which beats
        // every host, and each host's own `resume`. Without this the second one
        // sends a duplicate ping into a question already asked — two radio
        // payloads per host per foreground, which is precisely the waste the
        // shared tick exists to avoid.
        guard !awaitingPong else { return }
        awaitingPong = true
        send(.ping)
    }

    @discardableResult
    func send(_ message: ClientMessage) -> Bool {
        guard let carrier, state.phase == .online else { return false }
        return carrier.send(WireCodec.encode(message))
    }

    // MARK: - Connection

    private func connect() {
        generation &+= 1
        let epoch = generation
        dropCarrier()
        greeted = false
        awaitingPong = false
        heldRefusal = nil
        macAnswered = false

        guard let credential = credentials.load(hostId) else {
            // Nothing to connect with. The app routes to the pairing screen off
            // the same emptiness, so this only has to be honest and stop.
            state = ConnectionState(phase: .rejected,
                                    detail: "This device is not paired with that machine.",
                                    retryAt: nil, attempts: backoff.attempts)
            return
        }

        // While waiting for approval the reconnects *are* the poll, and flipping
        // the banner to "Connecting…" every few seconds would bury the
        // instruction the user needs to read. But that only holds while the Mac
        // is actually answering: if the last attempt never reached it, saying
        // "waiting for approval" describes a conversation that is not happening.
        if awaitingApproval && macAnsweredLastAttempt {
            state = ConnectionState(phase: .pending, detail: approvalDetail,
                                    retryAt: nil, attempts: backoff.attempts,
                                    awaitingApproval: true)
        } else {
            state = ConnectionState(phase: .connecting, detail: "Connecting…",
                                    retryAt: nil, attempts: backoff.attempts,
                                    awaitingApproval: awaitingApproval)
        }

        let carrier = makeCarrier(credential.endpoint, credentials.deviceKeys())
        self.carrier = carrier
        carrier.onEvent = { [weak self] event in
            guard let self, self.generation == epoch, !self.stopped else { return }
            switch event {
            case .ready:
                // Nothing is sent before the far end has authenticated itself,
                // which for a relay endpoint means after the sealed handshake.
                _ = carrier.send(WireCodec.encode(WireCodec.hello(token: credential.token, device: self.device)))
            case let .text(text):
                self.handle(text, credential: credential)
            case let .closed(close):
                self.closed(close)
            }
        }
        carrier.open()

        after(Self.handshakeTimeout, epoch: epoch) { [weak self] in
            guard let self, !self.greeted else { return }
            self.fail("The connection opened but the desktop never answered.")
        }
    }

    private func handle(_ raw: String, credential: StoredCredential) {
        guard case let .ok(message, activity) = WireCodec.decode(raw) else {
            // Not fatal on its own — a message type added on the desktop side
            // arrives here as garbage until this app is updated, and dropping it
            // is better than dropping the session.
            return
        }

        // A frame that decoded is proof the far end is the Mac: on a relay
        // endpoint it arrived through the sealed channel, so whoever sent it
        // holds the Mac's static private key. Recorded here rather than at the
        // socket's open, because a socket opening proves only that something
        // accepted a connection.
        macAnswered = true
        // And proof it is *still* there, which is a different claim and the one
        // the pill makes. Any sealed frame will do — a pong, a line of output, a
        // session list. It does not have to be the answer to our own question.
        state.verified = true

        if case let .welcome(version, deviceId, deviceName, token, _, advertised, _, _, _, _) = message {
            guard version == Wire.protocolVersion else {
                fatal(.incompatible,
                      "The desktop speaks protocol \(version) and this app speaks \(Wire.protocolVersion). "
                        + "Update whichever is older.")
                return
            }
            capabilities = advertised
            greeted = true
            backoff.reset()

            if let token {
                // Swap immediately. The pairing token is single-use and already
                // spent; reconnecting with it would be refused and would count
                // against the desktop's failed-attempt limiter.
                let stored = credential.redeemed(token: token, deviceId: deviceId, deviceName: deviceName)
                credentials.save(stored)
                onEvent?(.credential(stored))

                // `server.ts` sends this shape only when pairing succeeded and
                // the device was *not* admitted, so the pending state is known
                // now rather than after the refusal arrives.
                awaitingApproval = true
                approvalDetail = "Paired. Approve this device on the desktop."
                state = ConnectionState(phase: .pending, detail: approvalDetail,
                                        retryAt: nil, attempts: backoff.attempts,
                                        awaitingApproval: true)
                let epoch = generation
                after(Self.refusalGrace, epoch: epoch) { [weak self] in
                    // If no refusal followed, this was a desktop rotating a
                    // credential on a live connection rather than a pairing.
                    guard let self, self.awaitingApproval, self.carrier != nil else { return }
                    self.awaitingApproval = false
                    self.goOnline()
                }
                onEvent?(.message(message, activity: activity))
                return
            }

            awaitingApproval = false
            goOnline()
            onEvent?(.message(message, activity: activity))
            return
        }

        if case let .error(code, text) = message {
            switch code {
            case .unauthenticated, .unauthorized:
                // Held, not acted on: whether this is a refusal or an in-session
                // complaint is decided by whether the socket closes next. See
                // the header.
                heldRefusal = (code, text)
                if code == .unauthorized && greeted {
                    // An in-session refusal is about one action and belongs next
                    // to it. If a close follows, `closed` overrides this.
                    onEvent?(.message(message, activity: activity))
                }
                return
            case .version:
                fatal(.incompatible, text.isEmpty ? "The desktop refused this client’s protocol version." : text)
                return
            default:
                break
            }
        }

        if case .pong = message {
            awaitingPong = false
            return
        }

        onEvent?(.message(message, activity: activity))
    }

    private func goOnline() {
        state = ConnectionState(phase: .online, detail: "Connected.", retryAt: nil, attempts: 0)
        startHeartbeat()
    }

    // MARK: - Closing

    private func closed(_ close: CarrierClose) {
        carrier = nil

        if let refusal = heldRefusal {
            heldRefusal = nil
            let sentence = refusal.message.isEmpty ? "The desktop refused this device." : refusal.message
            let credential = credentials.load(hostId)

            // A pairing token that was refused is spent, wrong, or expired, and
            // nothing about waiting fixes it. A *device* credential refused
            // while unapproved is the normal pending case.
            let pairingFailed = refusal.code == .unauthenticated
                || credential == nil
                || credential?.kind == .pairing

            if pairingFailed {
                credentials.remove(hostId)
                fatal(.rejected, sentence)
                onEvent?(.needsPairing(sentence))
                return
            }

            awaitingApproval = true
            approvalDetail = sentence
            scheduleRetry(sentence)
            return
        }

        scheduleRetry(closeReason(close, greeted: greeted))
    }

    /// A failure this side detected.
    private func fail(_ detail: String) {
        dropCarrier()
        scheduleRetry(detail)
    }

    /// A failure retrying cannot fix.
    private func fatal(_ phase: ConnectionPhase, _ detail: String) {
        generation &+= 1
        dropCarrier()
        awaitingApproval = false
        state = ConnectionState(phase: phase, detail: detail, retryAt: nil, attempts: backoff.attempts)
    }

    private func scheduleRetry(_ detail: String) {
        // Every path to a retry comes through here, so this is the one place
        // that can guarantee there is never more than one in flight.
        generation &+= 1
        let epoch = generation
        dropCarrier()
        macAnsweredLastAttempt = macAnswered
        let delay = backoff.next()
        let retryAt = Date().addingTimeInterval(delay)
        /*
         * Which of the two waits this is.
         *
         * `.pending` is a claim about the Mac — that it answered and said "not
         * yet" — so it is only made when the Mac did answer on this attempt.
         * When it did not, the phase is the ordinary `.waiting` and the detail
         * is the real reason the attempt failed, while `awaitingApproval` stays
         * true so the app keeps the approval screen rather than dropping the
         * user into an empty session list.
         *
         * The version-byte bug is the case this exists for: every handshake
         * failed, no attempt ever reached the Mac, and the old code answered
         * that with "Paired. Approve this device on the Mac." forever.
         */
        if awaitingApproval && macAnswered {
            state = ConnectionState(phase: .pending, detail: approvalDetail,
                                    retryAt: retryAt, attempts: backoff.attempts,
                                    awaitingApproval: true)
        } else {
            state = ConnectionState(phase: .waiting, detail: detail,
                                    retryAt: retryAt, attempts: backoff.attempts,
                                    awaitingApproval: awaitingApproval)
        }
        after(delay, epoch: epoch) { [weak self] in
            guard let self, !self.stopped else { return }
            self.connect()
        }
    }

    // MARK: - Heartbeat

    /**
     * Join the app's single tick rather than starting a timer.
     *
     * Every paired machine holds a socket and every socket needs the keepalive,
     * so N hosts on N private timers would be N chances per cycle to wake the
     * radio for the same traffic. See `Heartbeat` for the numbers.
     */
    private func startHeartbeat() {
        awaitingPong = false
        Heartbeat.shared.join(self) { [weak self] in self?.beat() }
    }

    private func beat() {
        guard carrier != nil, state.phase == .online else { return }
        // A tick that arrives while the previous pong is still outstanding is
        // the answer: nothing came back in a whole interval, which is more than
        // twice the grace this used to allow.
        if awaitingPong {
            fail("The connection stopped answering.")
            return
        }
        awaitingPong = true
        send(.ping)
        let epoch = generation
        after(Self.pongGrace, epoch: epoch) { [weak self] in
            guard let self, self.awaitingPong else { return }
            self.fail("The connection stopped answering.")
        }
    }

    // MARK: - Plumbing

    /// A delay that cancels itself when the connection it belongs to is gone.
    /// Comparing the epoch rather than holding a cancellable is what stops a
    /// timer armed before a reconnect from tearing down the socket after it.
    private func after(_ delay: TimeInterval, epoch: Int, _ body: @escaping @MainActor () -> Void) {
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self, self.generation == epoch, !self.stopped else { return }
            body()
        }
    }

    private func dropCarrier() {
        // Left before the socket goes, always: a member whose transport is dead
        // would keep the shared timer alive with nothing to check on.
        Heartbeat.shared.leave(self)
        guard let carrier else { return }
        self.carrier = nil
        carrier.onEvent = nil
        carrier.close()
    }
}
