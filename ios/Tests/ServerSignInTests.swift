/**
 * The sign-in as the Add-server screen drives it: a socket, the frame sequence
 * across it, and every way it can end.
 *
 * `SignInLinkTests` covers the driver — the fixed order of `enroll` → `enrolled`
 * → `hello` → `welcome`. This covers the half that did not exist: opening the
 * channel, writing the credential the server minted, dropping the SSH secret,
 * and turning each refusal into a sentence with a next move in it.
 *
 * Driven through a scripted carrier, in the shape `LiveTransportTests` uses.
 * Nothing here is framed, sealed or sent — the sealed channel is covered by the
 * crypto tests and, for real, by the harness against a live relay.
 */

import XCTest
@testable import TerminalDeck

@MainActor
final class ServerSignInTests: XCTestCase {

    // MARK: - Doubles

    private final class ScriptedCarrier: Carrier {
        var onEvent: ((CarrierEvent) -> Void)?
        private(set) var sent: [String] = []
        private(set) var closed = 0
        /// Whether `open` should reach `ready` at all — a server that is not
        /// there accepts nothing.
        var readyOnOpen = true

        func open() {
            guard readyOnOpen else { return }
            onEvent?(.ready)
        }

        func close() { closed += 1 }

        @discardableResult
        func send(_ text: String) -> Bool {
            sent.append(text)
            return true
        }

        func deliver(_ json: String) { onEvent?(.text(json)) }

        func drop(beforeReady: Bool, detail: String?) {
            onEvent?(.closed(CarrierClose(code: -1, detail: detail, beforeReady: beforeReady)))
        }
    }

    private final class MemoryStore: CredentialStore {
        var records: [String: StoredCredential] = [:]
        private let keys = StaticKeyPair.generate()
        private(set) var saves = 0

        func all() -> [StoredCredential] { Array(records.values) }
        func load(_ hostId: String) -> StoredCredential? { records[hostId] }
        func save(_ credential: StoredCredential) {
            saves += 1
            records[credential.hostId] = credential
        }
        func remove(_ hostId: String) { records[hostId] = nil }
        func clearAll() { records = [:] }
        func deviceKeys() -> StaticKeyPair { keys }
    }

    // MARK: - Fixtures

    private static let hostId = "M9G95TNJT64Q928VW3HVRYDR8J"
    private var address: String {
        let key = Data(repeating: 7, count: 32).base64EncodedString()
        return """
        {"kind":"relay","url":"wss://relay.example","hostId":"\(Self.hostId)","hostKey":"\(key)"}
        """
    }

    private var carrier: ScriptedCarrier!
    private var store: MemoryStore!
    private var flow: ServerSignIn!
    private var adopted: [StoredCredential] = []
    /// The keys the flow dialled with, so the test can prove it spent the
    /// phone's durable identity rather than a throwaway.
    private var dialledWith: StaticKeyPair?

    override func setUp() {
        super.setUp()
        carrier = ScriptedCarrier()
        store = MemoryStore()
        adopted = []
        dialledWith = nil
        flow = ServerSignIn(credentials: store,
                            device: DeviceDescriptor(name: "iPhone", platform: "ios"),
                            makeCarrier: { [weak self] _, keys in
                                self?.dialledWith = keys
                                return self?.carrier ?? ScriptedCarrier()
                            },
                            onSignedIn: { [weak self] record in self?.adopted.append(record) })
    }

    private func submit(method: EnrollMethod = .password, secret: String = "hunter2") {
        flow.submit(address: address, username: "asad", secret: secret, method: method)
    }

    private let enrolled = """
    {"t":"enrolled","deviceId":"dev-9","deviceName":"iPhone","credential":"dev-9.secret"}
    """
    private let welcome = """
    {"t":"welcome","protocol":1,"deviceId":"dev-9","deviceName":"iPhone","token":null,"sessions":[]}
    """

    /// One string field off a frame this side sent. Read as JSON rather than by
    /// `contains`, so a test cannot pass on a substring that happens to appear
    /// in some other field.
    private func field(_ raw: String, _ key: String) -> String? {
        guard let data = raw.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return object[key] as? String
    }

    // MARK: - The happy path

    func testItEnrollsThenSaysHelloAndKeepsTheCredential() {
        submit()
        XCTAssertEqual(flow.phase, .verifying)

        // Opens with enroll, carrying the login.
        let first = carrier.sent.first ?? ""
        XCTAssertEqual(field(first, "t"), "enroll", "sent: \(carrier.sent)")
        XCTAssertEqual(field(first, "username"), "asad")
        XCTAssertEqual(field(first, "secret"), "hunter2")
        XCTAssertEqual(field(first, "method"), "password")

        carrier.deliver(enrolled)
        XCTAssertEqual(flow.phase, .joining, "the mint is its own state; it fails differently")

        // The credential becomes an ordinary hello on the same socket.
        let second = carrier.sent.last ?? ""
        XCTAssertEqual(field(second, "t"), "hello")
        XCTAssertEqual(field(second, "token"), "dev-9.secret")

        carrier.deliver(welcome)

        guard case let .signedIn(hostId, _) = flow.phase else {
            return XCTFail("expected signedIn, got \(flow.phase)")
        }
        XCTAssertEqual(hostId, Self.hostId)

        // Written to the store — the machine is paired whether or not anything
        // is looking at the screen a moment later.
        let saved = store.load(Self.hostId)
        XCTAssertEqual(saved?.token, "dev-9.secret")
        XCTAssertEqual(saved?.kind, .device)
        XCTAssertEqual(saved?.deviceId, "dev-9")
        XCTAssertEqual(adopted.map(\.hostId), [Self.hostId], "the collection is told exactly once")
        XCTAssertEqual(carrier.closed, 1, "the socket is handed back to the ordinary transport")
    }

    /**
     * The welcome is waited for, not assumed.
     *
     * Stopping at `enrolled` would be storing a credential nothing has ever
     * spent and calling it success — and the whole reason the driver sends a
     * `hello` on the same socket is to prove the mint is honoured.
     */
    func testTheMintAloneIsNotASignIn() {
        submit()
        carrier.deliver(enrolled)
        XCTAssertNil(store.load(Self.hostId))
        XCTAssertTrue(adopted.isEmpty)
    }

    /**
     * The device key, not a throwaway.
     *
     * `enroll.ts` binds the minted row to the handshake key and `device-auth.ts`
     * refuses any later handshake from a key it does not know, so a sign-in run
     * on a throwaway pair would mint a device this phone can never present
     * again.
     */
    func testItDialsWithThisPhonesDurableKey() {
        submit()
        XCTAssertEqual(dialledWith?.publicKey, store.deviceKeys().publicKey)
    }

    /// A machine signed into a second time keeps the name its owner gave it, and
    /// does not become a second row.
    func testSigningInAgainKeepsTheNameAndTheRow() {
        store.save(StoredCredential(
            endpoint: .relay(url: URL(string: "wss://relay.example")!,
                             hostId: Self.hostId, hostKey: Data(repeating: 7, count: 32)),
            token: "old", kind: .device, deviceId: "dev-1", deviceName: "iPhone",
            pairedAt: Date(timeIntervalSince1970: 1), nickname: "The box"))

        submit()
        carrier.deliver(enrolled)
        carrier.deliver(welcome)

        XCTAssertEqual(store.records.count, 1)
        XCTAssertEqual(store.load(Self.hostId)?.nickname, "The box")
        XCTAssertEqual(store.load(Self.hostId)?.token, "dev-9.secret")
    }

    // MARK: - The secret

    /**
     * The SSH secret is spent and dropped.
     *
     * What replaces it is the credential the server minted, which is the point
     * of the ceremony: the server can revoke that on its own, and nothing on
     * this phone is a copy of somebody's login.
     */
    func testTheSecretIsNotKeptAfterASignIn() {
        submit()
        carrier.deliver(enrolled)
        carrier.deliver(welcome)
        XCTAssertFalse(store.records.values.contains { $0.token == "hunter2" })
        for record in store.records.values {
            let encoded = try? JSONEncoder().encode(record)
            let text = encoded.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            XCTAssertFalse(text.contains("hunter2"), "the secret must not reach the store")
        }
    }

    func testTheSecretIsDroppedOnARefusalToo() {
        submit()
        carrier.deliver("""
        {"t":"error","code":"unauthorized","message":"That sign-in was refused."}
        """)
        XCTAssertTrue(store.records.isEmpty)
    }

    // MARK: - The refusals, each with a next move

    func testAWrongLoginIsSaidInTheServersOwnWords() {
        submit()
        carrier.deliver("""
        {"t":"error","code":"unauthorized","message":"That sign-in was refused. Check the username."}
        """)
        guard case let .failed(failure) = flow.phase else { return XCTFail("expected a refusal") }
        XCTAssertEqual(failure.headline, "That sign-in was refused.")
        XCTAssertEqual(failure.advice, "That sign-in was refused. Check the username.")
        XCTAssertNil(store.load(Self.hostId))
    }

    /// A demo box, or a build with sign-in switched off. Not a wrong password,
    /// and saying so would send somebody to check one that was never read.
    func testAServerThatDoesNotOfferSignIn() {
        submit()
        carrier.deliver("""
        {"t":"error","code":"unavailable","message":"Sign-in is not available on this machine."}
        """)
        guard case let .failed(failure) = flow.phase else { return XCTFail("expected a refusal") }
        XCTAssertEqual(failure.headline, "That server does not offer sign-in.")
    }

    /**
     * A server older than `enroll` does not know the word.
     *
     * It refuses the frame as a bad message rather than as a bad login, and the
     * remedy is an update or a pairing code — not another password.
     */
    func testAServerTooOldToKnowTheWord() {
        submit()
        carrier.deliver("""
        {"t":"error","code":"bad-message","message":"Unknown message."}
        """)
        guard case let .failed(failure) = flow.phase else { return XCTFail("expected a refusal") }
        XCTAssertEqual(failure.headline, "That server is too old to sign a phone in.")
        XCTAssertTrue(failure.advice.contains("pair it with a code"))
    }

    func testAVersionMismatchIsItsOwnAnswer() {
        submit()
        carrier.deliver("""
        {"t":"error","code":"version","message":"This phone app speaks protocol 1."}
        """)
        guard case let .failed(failure) = flow.phase else { return XCTFail("expected a refusal") }
        XCTAssertEqual(failure.headline, "The two ends do not speak the same protocol.")
    }

    /**
     * Nothing there.
     *
     * The carrier's own sentence leads, because it knows whether it reached the
     * relay at all. The advice has to name the other thing a close-before-ready
     * means: a server too old to serve sign-in refuses the handshake outright.
     */
    func testAServerThatIsNotThere() {
        submit()
        carrier.drop(beforeReady: true, detail: "That Mac is not connected to the relay right now.")
        guard case let .failed(failure) = flow.phase else { return XCTFail("expected a failure") }
        XCTAssertEqual(failure.headline, "Could not reach that server.")
        XCTAssertTrue(failure.advice.contains("That Mac is not connected to the relay right now."))
        XCTAssertTrue(failure.advice.contains("too old"))
    }

    func testAServerThatHangsUpPartWayThrough() {
        submit()
        carrier.deliver(enrolled)
        carrier.drop(beforeReady: false, detail: nil)
        guard case let .failed(failure) = flow.phase else { return XCTFail("expected a failure") }
        XCTAssertEqual(failure.headline, "That server hung up part way through.")
        XCTAssertNil(store.load(Self.hostId), "nothing half-written")
    }

    /// A close arriving behind a finished exchange is the socket going away, not
    /// a failure — and must not paint an error over a machine that is in.
    func testACloseAfterSuccessChangesNothing() {
        submit()
        carrier.deliver(enrolled)
        carrier.deliver(welcome)
        carrier.drop(beforeReady: false, detail: "gone")
        guard case .signedIn = flow.phase else { return XCTFail("expected it to stay signed in") }
    }

    // MARK: - The form

    func testAnAddressThatDoesNotParseNeverOpensASocket() {
        flow.submit(address: "123456", username: "asad", secret: "hunter2", method: .password)
        guard case let .failed(failure) = flow.phase else { return XCTFail("expected a refusal") }
        XCTAssertEqual(failure.headline, "That server address was not readable.")
        XCTAssertTrue(carrier.sent.isEmpty)
    }

    func testAMissingUsernameIsAnsweredOnTheForm() {
        flow.submit(address: address, username: "  ", secret: "hunter2", method: .password)
        guard case let .failed(failure) = flow.phase else { return XCTFail("expected a refusal") }
        XCTAssertEqual(failure.headline, "That sign-in needs a username.")
        XCTAssertTrue(carrier.sent.isEmpty)
    }

    func testAMissingKeySaysKeyRatherThanPassword() {
        flow.submit(address: address, username: "asad", secret: "", method: .key)
        guard case let .failed(failure) = flow.phase else { return XCTFail("expected a refusal") }
        XCTAssertEqual(failure.headline, "That sign-in needs a key.")
    }

    /// A password may legitimately begin or end with a space, so the secret is
    /// the one field that is not trimmed.
    func testASecretIsSentExactlyAsTyped() {
        submit(secret: "  spaced  ")
        XCTAssertEqual(field(carrier.sent.first ?? "", "secret"), "  spaced  ")
    }

    func testASecondTapDoesNotOpenASecondSocket() {
        submit()
        let after = carrier.sent.count
        submit()
        XCTAssertEqual(carrier.sent.count, after)
    }

    func testCancelPutsTheFormBackAndClosesTheSocket() {
        submit()
        flow.cancel()
        XCTAssertEqual(flow.phase, .editing)
        XCTAssertEqual(carrier.closed, 1)
        // And a frame arriving from the abandoned socket does nothing.
        carrier.deliver(enrolled)
        XCTAssertEqual(flow.phase, .editing)
    }

    /// A refusal is not a dead end: the form comes back so one field can be
    /// fixed rather than the whole thing started again.
    func testAfterARefusalTheFormComesBack() {
        submit()
        carrier.deliver("""
        {"t":"error","code":"unauthorized","message":"Refused."}
        """)
        flow.edit()
        XCTAssertEqual(flow.phase, .editing)
        submit()
        XCTAssertEqual(flow.phase, .verifying)
    }
}
