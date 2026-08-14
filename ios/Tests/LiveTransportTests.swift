/**
 * The three answers a desktop can give to `hello` that are not "yes".
 *
 * These are the states the old transport could not express, and they are the
 * difference between a phone that says "go and approve this device" and one
 * that says "the desktop refused you" to somebody standing next to the Mac.
 * They are also the states that are hardest to reach against a real server on
 * purpose — a revoked device, a spent pairing code, a version mismatch — so
 * they are driven here through a scripted carrier instead.
 *
 * The live path is covered elsewhere and for real: `UITests/` runs against
 * `ios/Harness/run.sh host`, which is the actual relay and the actual sealed
 * channel. Nothing in this file would catch a framing bug, and nothing there
 * would catch the pending/refused distinction reliably.
 */

import XCTest
@testable import TerminalDeck

@MainActor
final class LiveTransportTests: XCTestCase {

    // MARK: - Doubles

    /// A carrier whose far end is this test. Nothing is encoded, framed or sent.
    private final class ScriptedCarrier: Carrier {
        var onEvent: ((CarrierEvent) -> Void)?
        private(set) var sent: [String] = []
        private(set) var opened = 0
        private(set) var closed = 0

        func open() {
            opened += 1
            // Ready on the next turn of the loop, like a real socket.
            onEvent?(.ready)
        }

        func close() {
            closed += 1
        }

        @discardableResult
        func send(_ text: String) -> Bool {
            sent.append(text)
            return true
        }

        func deliver(_ json: String) {
            onEvent?(.text(json))
        }

        func drop(beforeReady: Bool = false, code: Int = 1000, detail: String? = nil) {
            onEvent?(.closed(CarrierClose(code: code, detail: detail, beforeReady: beforeReady)))
        }
    }

    /**
     * A one-machine store, in memory.
     *
     * Still one machine on purpose: these tests are about what a *transport*
     * does with the three refusals, and a transport only ever speaks to one
     * host. That the store can hold several is `CredentialStoreTests`'
     * business, and mixing the two would test the collection twice and the
     * refusals once.
     */
    private final class MemoryStore: CredentialStore {
        var stored: StoredCredential?
        private let keys = StaticKeyPair.generate()
        private(set) var cleared = 0

        init(_ credential: StoredCredential?) {
            stored = credential
        }

        func all() -> [StoredCredential] { [stored].compactMap { $0 } }
        func load(_ hostId: String) -> StoredCredential? {
            stored?.hostId == hostId ? stored : nil
        }
        func save(_ credential: StoredCredential) { stored = credential }
        func remove(_ hostId: String) {
            guard stored?.hostId == hostId else { return }
            cleared += 1
            stored = nil
        }
        func clearAll() {
            cleared += 1
            stored = nil
        }
        func deviceKeys() -> StaticKeyPair { keys }
    }

    /// The one machine every test here talks to.
    private static let hostId = "M9G95TNJT64Q928VW3HVRYDR8J"

    private var carrier: ScriptedCarrier!
    private var store: MemoryStore!
    private var transport: LiveTransport!
    private var events: [TransportEvent] = []

    private func start(kind: StoredCredential.Kind = .device) {
        carrier = ScriptedCarrier()
        store = MemoryStore(StoredCredential(
            endpoint: .relay(url: URL(string: "wss://relay.example")!,
                             hostId: Self.hostId,
                             hostKey: Data(repeating: 3, count: 32)),
            token: kind == .pairing ? "pairing-token" : "device.credential",
            kind: kind,
            deviceId: "d-1",
            deviceName: "iPhone",
            pairedAt: Date()))
        // A backoff of milliseconds: these tests are about which state is
        // entered, not about how long the wait is. `BackoffTests` owns that.
        transport = LiveTransport(
            hostId: Self.hostId,
            device: DeviceDescriptor(name: "iPhone", platform: "iOS 26"),
            credentials: store,
            backoff: Backoff(options: BackoffOptions(firstMs: 1, maxMs: 2, factor: 1, jitter: 0),
                             random: { 0 }),
            makeCarrier: { [carrier] _, _ in carrier! })
        events = []
        transport.onEvent = { [weak self] in self?.events.append($0) }
        transport.start()
    }

    private func welcome(token: String?, sessions: String = "[]", capabilities: String? = nil) -> String {
        let tokenField = token.map { "\"\($0)\"" } ?? "null"
        let extra = capabilities.map { ",\"capabilities\":\($0)" } ?? ""
        return """
        {"t":"welcome","protocol":1,"deviceId":"d-1","deviceName":"iPhone",\
        "token":\(tokenField),"sessions":\(sessions)\(extra)}
        """
    }

    private var needsPairing: String? {
        for event in events {
            if case let .needsPairing(reason) = event { return reason }
        }
        return nil
    }

    // MARK: - Hello

    func testSaysHelloOnlyOnceTheCarrierIsReady() {
        start()
        XCTAssertEqual(carrier.sent.count, 1)
        XCTAssertTrue(carrier.sent[0].contains("\"t\":\"hello\""))
        XCTAssertTrue(carrier.sent[0].contains("device.credential"))
    }

    func testAWelcomeWithoutATokenIsSimplyConnected() {
        start()
        carrier.deliver(welcome(token: nil))
        XCTAssertEqual(transport.state.phase, .online)
        XCTAssertEqual(transport.state.detail, "Connected.")
    }

    func testCapabilitiesAreReadOffTheWelcome() {
        start()
        carrier.deliver(welcome(token: nil, capabilities: "[\"create\",\"\",\"nonsense\"]"))
        XCTAssertTrue(transport.capabilities.contains(WireCapability.create))
        XCTAssertFalse(transport.capabilities.contains(""))
    }

    func testADesktopWithNoCapabilitiesFieldOffersNothing() {
        start()
        carrier.deliver(welcome(token: nil))
        XCTAssertTrue(transport.capabilities.isEmpty)
    }

    // MARK: - Paired, not approved

    func testAWelcomeCarryingATokenMeansPendingRatherThanConnected() {
        start(kind: .pairing)
        carrier.deliver(welcome(token: "d-1.durable"))

        // `server.ts` sends that shape only when pairing succeeded and the
        // device was *not* admitted. Reading it as success would flash
        // "Connected" over a device that cannot see a single session.
        XCTAssertEqual(transport.state.phase, .pending)
        XCTAssertEqual(store.stored?.token, "d-1.durable")
        XCTAssertEqual(store.stored?.kind, .device, "the pairing token is spent and must not be retried")
    }

    func testTheRefusalThatFollowsKeepsTheDesktopsOwnWords() {
        start(kind: .pairing)
        carrier.deliver(welcome(token: "d-1.durable"))
        carrier.deliver(#"{"t":"error","code":"unauthorized","message":"Paired. Approve this device on the Mac, then reconnect."}"#)
        carrier.drop()

        XCTAssertEqual(transport.state.phase, .pending)
        XCTAssertEqual(transport.state.detail, "Paired. Approve this device on the Mac, then reconnect.")
        XCTAssertNotNil(transport.state.retryAt, "the reconnect schedule is the poll for approval")
        XCTAssertNil(needsPairing, "a pending device must not be sent back to the pairing screen")
    }

    func testAnApprovedDeviceThatWasPendingGoesOnline() async throws {
        start()
        carrier.deliver(#"{"t":"error","code":"unauthorized","message":"This device is waiting to be approved."}"#)
        carrier.drop()
        XCTAssertEqual(transport.state.phase, .pending)

        // The poll is the reconnect, so the next attempt has to actually
        // happen: a frame delivered on the dropped socket is ignored, which is
        // the generation check doing its job.
        try await Task.sleep(for: .milliseconds(60))
        XCTAssertEqual(carrier.opened, 2, "the pending state should have retried by itself")

        carrier.deliver(welcome(token: nil, sessions: "[]"))
        XCTAssertEqual(transport.state.phase, .online)
    }

    /**
     * The lie this fixes: an attempt that never reached the Mac, reported as
     * "waiting for approval".
     *
     * Once a device is pending, every reconnect used to be described with the
     * remembered approval sentence no matter what happened to it — so a client
     * whose handshake failed on every attempt (the missing version byte did
     * exactly this) sat on a screen saying a human had only to press a button.
     * The device is still unapproved, so `awaitingApproval` stays true and the
     * app keeps the right screen; what must change is the phase and the words.
     */
    func testAFailureAfterPendingSaysWhatActuallyHappened() async throws {
        start()
        carrier.deliver(#"{"t":"error","code":"unauthorized","message":"Approve this device on the Mac."}"#)
        carrier.drop()
        XCTAssertEqual(transport.state.phase, .pending, "the Mac answered, so this really is pending")
        XCTAssertTrue(transport.state.awaitingApproval)

        // The poll is the reconnect, so the next attempt has to actually happen
        // before it can fail — a drop on the previous socket is ignored.
        try await Task.sleep(for: .milliseconds(60))
        XCTAssertEqual(carrier.opened, 2)

        // And this attempt never gets a frame back: the socket dies before the
        // desktop says anything, which is exactly what a handshake the Mac
        // refuses in silence looks like from here.
        carrier.drop(beforeReady: true, code: -1, detail: "Could not reach that Mac.")

        XCTAssertEqual(transport.state.phase, .waiting,
                       "an attempt that reached nothing must not be called pending")
        XCTAssertEqual(transport.state.detail, "Could not reach that Mac.",
                       "the real reason, not the remembered approval sentence")
        XCTAssertTrue(transport.state.awaitingApproval,
                      "the device is still unapproved, so the approval screen stays")
    }

    /// And the flag is off in the ordinary case, so nothing else routes to that
    /// screen by accident.
    func testAnOrdinaryDisconnectionIsNotAwaitingApproval() {
        start()
        carrier.deliver(welcome(token: nil))
        XCTAssertFalse(transport.state.awaitingApproval)
        carrier.drop(code: 1006)
        XCTAssertEqual(transport.state.phase, .waiting)
        XCTAssertFalse(transport.state.awaitingApproval)
    }

    func testFramesFromASocketThatHasAlreadyDroppedAreIgnored() {
        start()
        carrier.deliver(welcome(token: nil))
        carrier.drop(code: 1006)
        // A late frame from a dead socket must not put the app back online: the
        // socket it came from is gone, and anything it says about sessions is
        // already stale.
        carrier.deliver(welcome(token: nil))
        XCTAssertNotEqual(transport.state.phase, .online)
    }

    // MARK: - Refused for good

    func testASpentPairingCodeSendsTheUserBackToPairing() {
        start(kind: .pairing)
        carrier.deliver(#"{"t":"error","code":"unauthorized","message":"That pairing code is not right."}"#)
        carrier.drop()

        // Nothing about waiting fixes a code that was wrong, expired or already
        // used — and retrying costs the device an attempt against a lockout.
        XCTAssertEqual(transport.state.phase, .rejected)
        XCTAssertEqual(needsPairing, "That pairing code is not right.")
        XCTAssertEqual(store.cleared, 1)
        XCTAssertNil(transport.state.retryAt)
    }

    func testAnUnauthenticatedRefusalClearsTheCredential() {
        start()
        carrier.deliver(#"{"t":"error","code":"unauthenticated","message":"Say hello first."}"#)
        carrier.drop()
        XCTAssertEqual(transport.state.phase, .rejected)
        XCTAssertEqual(store.cleared, 1)
    }

    // MARK: - The refusal that is not one

    func testAnInSessionUnauthorizedDoesNotTearDownTheConnection() {
        start()
        carrier.deliver(welcome(token: nil))
        carrier.deliver(#"{"t":"error","code":"unauthorized","message":"Attach to that session before typing into it."}"#)

        // The desktop spends the same code on this and on "not approved yet".
        // The difference is that this one does not close the socket.
        XCTAssertEqual(transport.state.phase, .online)
        XCTAssertNil(needsPairing)
        var forwarded = false
        for event in events {
            if case let .message(message, _) = event, case .error = message { forwarded = true }
        }
        XCTAssertTrue(forwarded, "it should reach the model as an error about one action")
    }

    // MARK: - Version

    func testAVersionMismatchStopsRatherThanRetries() {
        start()
        carrier.deliver(#"{"t":"welcome","protocol":9,"deviceId":"d","deviceName":"n","token":null,"sessions":[]}"#)
        XCTAssertEqual(transport.state.phase, .incompatible)
        XCTAssertNil(transport.state.retryAt)

        // And coming back to the foreground does not start it up again.
        transport.resume()
        XCTAssertEqual(transport.state.phase, .incompatible)
    }

    // MARK: - Sending

    func testSendRefusesUntilTheWelcomeArrives() {
        start()
        XCTAssertFalse(transport.send(.list), "nothing may be sent before the desktop has answered")
        carrier.deliver(welcome(token: nil))
        XCTAssertTrue(transport.send(.list))
        XCTAssertTrue(carrier.sent.last!.contains("\"t\":\"list\""))
    }

    func testSendRefusesAfterTheSocketDrops() {
        start()
        carrier.deliver(welcome(token: nil))
        carrier.drop(code: 1006)
        XCTAssertFalse(transport.send(.input(id: "s", data: "rm -rf /")),
                       "a keystroke must never be buffered into a socket that is gone")
    }

    func testAConnectionLostBeforeTheWelcomeSaysSoDifferently() {
        start()
        carrier.drop(beforeReady: true, code: -1, detail: "That Mac is not connected to the relay right now.")
        XCTAssertEqual(transport.state.phase, .waiting)
        XCTAssertEqual(transport.state.detail, "That Mac is not connected to the relay right now.")
    }

    func testStoppingIsSilentAndFinal() {
        start()
        carrier.deliver(welcome(token: nil))
        transport.stop()
        XCTAssertEqual(transport.state.phase, .offline)
        XCTAssertGreaterThan(carrier.closed, 0)
        XCTAssertFalse(transport.send(.list))
    }

    func testWithoutACredentialThereIsNothingToTry() {
        start()
        store.stored = nil
        transport.stop()
        transport.start()
        XCTAssertEqual(transport.state.phase, .rejected)
        XCTAssertEqual(carrier.opened, 1, "no socket should be opened without a credential")
    }

    // MARK: - The badge must never claim a connection this app does not have

    /**
     * These are written against an observed failure, not a hypothetical one: the
     * relay reported no guest attached for a sustained forty seconds while the
     * app was showing **Connected**. A phone terminal that lies about being
     * connected is worse than no phone terminal, because somebody types Ctrl+C
     * into stale output and walks away believing the job stopped.
     */

    func testNothingSaysConnectedBeforeTheWelcome() {
        start()
        // The socket is open and `hello` has gone out. Nothing has come back.
        XCTAssertEqual(transport.state.phase, .connecting)
        XCTAssertNotEqual(transport.state.label, "Connected")
        XCTAssertFalse(transport.state.isLive)
    }

    func testAnUnapprovedDeviceIsNotConnected() {
        start(kind: .pairing)
        carrier.deliver(welcome(token: "d-1.durable"))
        XCTAssertEqual(transport.state.phase, .pending)
        XCTAssertNotEqual(transport.state.label, "Connected",
                          "paired-but-unapproved is not connected")
        XCTAssertFalse(transport.state.isLive)
    }

    func testTheBadgeGoesDownWithTheChannel() {
        start()
        carrier.deliver(welcome(token: nil))
        XCTAssertEqual(transport.state.label, "Connected")
        carrier.drop(code: 1006)
        XCTAssertNotEqual(transport.state.label, "Connected")
        XCTAssertFalse(transport.state.isLive)
    }

    /**
     * The forty-second window, closed.
     *
     * Coming back from suspension used to be a no-op while `.online`: the
     * connection was already up, so there was nothing to reconnect. But `.online`
     * was decided before the phone went in a pocket, and nothing tells a socket
     * that a carrier NAT reclaimed its mapping in the meantime. The badge kept
     * saying Connected until the next heartbeat and its grace had both elapsed.
     */
    func testComingBackFromSuspensionDoesNotClaimConnectedUntilItIsChecked() {
        start()
        carrier.deliver(welcome(token: nil))
        XCTAssertEqual(transport.state.label, "Connected")
        let before = carrier.sent.count

        transport.resume()

        XCTAssertEqual(transport.state.phase, .online, "the session is still there; nothing is torn down")
        XCTAssertFalse(transport.state.verified)
        XCTAssertEqual(transport.state.label, "Checking",
                       "an unverified channel must not be described as connected")
        XCTAssertEqual(carrier.sent.count, before + 1, "resuming should ask the far end to prove it")
        XCTAssertTrue(carrier.sent.last?.contains("\"t\":\"ping\"") == true)
    }

    func testAnAnswerFromTheFarEndRestoresTheBadge() {
        start()
        carrier.deliver(welcome(token: nil))
        transport.resume()
        XCTAssertEqual(transport.state.label, "Checking")

        carrier.deliver("{\"t\":\"pong\"}")

        XCTAssertTrue(transport.state.verified)
        XCTAssertEqual(transport.state.label, "Connected")
    }

    /**
     * Any sealed frame counts, not only the answer to our own question.
     *
     * A line of output is as good a proof that the far end is there as a pong is,
     * and on a busy session it arrives first. Requiring specifically a pong would
     * leave the badge saying Checking over a terminal that is visibly printing.
     */
    func testOutputAlsoProvesTheFarEndIsThere() {
        start()
        carrier.deliver(welcome(token: nil))
        transport.resume()
        XCTAssertFalse(transport.state.verified)

        carrier.deliver("{\"t\":\"output\",\"id\":\"s1\",\"data\":\"hello\"}")

        XCTAssertTrue(transport.state.verified)
        XCTAssertEqual(transport.state.label, "Connected")
    }

    func testResumingAFreshConnectionChangesNothing() {
        start()
        carrier.deliver(welcome(token: nil))
        // No suspension in between, so nothing has been sent since the welcome
        // and the state is as verified as it was a moment ago. The probe is
        // still correct — it just must not look like a reconnect.
        transport.resume()
        XCTAssertEqual(carrier.opened, 1, "resuming an online transport must not reopen the socket")
    }
}
