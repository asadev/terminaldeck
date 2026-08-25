/**
 * The gate behind the one swipe action that destroys something.
 *
 * Asad asked for the gesture across every list in the app — *"if we click, like
 * we have a list of browsers or sessions, we can swipe them left and right and
 * we can have options there to delete or close the options or archive and
 * things, just like WhatsApp has the chats"* — and most of what that produced is
 * layout, which is looked at rather than asserted. `SwipeActionsUITests` drives
 * the gestures on a real phone against a real machine.
 *
 * One thing in it is not layout, and it is the thing that would be worst to get
 * wrong: **Close is drawn only when the machine at the other end has said it can
 * close a session.** That rule is `HostLink.canCloseSessions`, it is read
 * directly by `SessionListView.closeAction`, and until this file it had no test
 * at all — the two suites that mention the capability drive it through a
 * simulator, so a machine that withholds `close` was never once modelled.
 *
 * ## Why an ungated Close is worse than a missing one
 *
 * Every other swipe action in this app is either reversible (Archive, Pin) or a
 * reference (Details, About). Close is neither: it ends somebody's work on a
 * computer that is not in the room. So the rule this app follows everywhere —
 * absent rather than disabled, because a disabled control for a thing the far
 * end can never do is a smaller lie — matters more here than anywhere, and the
 * two ways to break it are worth pinning separately:
 *
 *  - A machine that never advertised `close` must not be offered the action.
 *    `parseClientMessage` closes the socket on a verb it does not know, so the
 *    press would not fail politely; it would drop the connection.
 *  - A machine that *did* advertise it but is **offline** must not be offered it
 *    either. The capability outlives the socket in memory, so reading it alone
 *    would draw a red button over a dead connection — and a press there is the
 *    exact case the method's own guard calls out as indistinguishable from
 *    having destroyed something.
 *
 * Driven through a scripted transport rather than a socket, for the reason
 * `MultiHostTests` gives about its own: these are questions about what one
 * object decides from what it has been told, and a relay would only make them
 * slower to ask.
 */

import XCTest
@testable import TerminalDeck

@MainActor
final class SwipeActionsTests: XCTestCase {

    // MARK: - Doubles

    /// A transport whose far end is this test. It records rather than sends, so
    /// "the app did not put a frame on the wire" is a thing that can be asserted
    /// rather than inferred from nothing happening.
    private final class ScriptedTransport: Transport {
        var state: ConnectionState = .offline
        var capabilities: Set<String> = []
        var onEvent: ((TransportEvent) -> Void)?
        private(set) var sent: [ClientMessage] = []

        func start() {}
        func stop() {}
        func resume() {}

        @discardableResult
        func send(_ message: ClientMessage) -> Bool {
            sent.append(message)
            return true
        }

        /// Come up, advertising exactly what it was given and nothing else.
        func goLive(advertising: Set<String>) {
            capabilities = advertising
            say(ConnectionState(phase: .online, detail: "Connected.", retryAt: nil, attempts: 0))
        }

        /// Drop, **keeping** the capabilities. That is what a real transport does
        /// — the list it learned from `welcome` is still in memory after the
        /// socket goes — and it is the half of this that a fixture resetting them
        /// on the way down would quietly make untestable.
        func drop() {
            say(ConnectionState(phase: .waiting, detail: "Connection lost.", retryAt: nil, attempts: 1))
        }

        func say(_ state: ConnectionState) {
            self.state = state
            onEvent?(.state(state))
        }

        var closes: [String] {
            sent.compactMap { if case let .close(id) = $0 { return id } else { return nil } }
        }
    }

    private final class MemoryStore: CredentialStore {
        private var records: [String: StoredCredential] = [:]
        private let keys = StaticKeyPair.generate()

        func all() -> [StoredCredential] { Array(records.values) }
        func load(_ hostId: String) -> StoredCredential? { records[hostId] }
        func save(_ credential: StoredCredential) { records[credential.hostId] = credential }
        func remove(_ hostId: String) { records.removeValue(forKey: hostId) }
        func clearAll() { records = [:] }
        func deviceKeys() -> StaticKeyPair { keys }
    }

    // MARK: - The rule

    /// A machine that says it can close sessions gets the action.
    func testAMachineThatAdvertisesCloseOffersTheAction() {
        let (link, transport) = machine()
        transport.goLive(advertising: [WireCapability.create, WireCapability.close])

        XCTAssertTrue(link.canCloseSessions,
                      "the swipe's Close is drawn from exactly this")
    }

    /**
     * A machine that speaks only protocol v1 gets a swipe with no Close on it.
     *
     * `create` is advertised here and `close` is not, which is not a contrived
     * pair: the public demo box hands a stranger a shell and withholds the verb
     * that ends one, because starting something there is additive and bounded
     * while ending something is neither. So the two capabilities have to come
     * apart in the model as well as on the wire.
     */
    func testAMachineThatWithholdsCloseIsOfferedNothingToPress() {
        let (link, transport) = machine()
        transport.goLive(advertising: [WireCapability.create])

        XCTAssertTrue(link.canCreateSessions, "it can still start one")
        XCTAssertFalse(link.canCloseSessions,
                       "and the Close swipe must be absent rather than disabled")
    }

    /**
     * And the press that should never have been possible does nothing on the wire.
     *
     * The action is not drawn, so this is the second line of defence rather than
     * the first — but it is the line that matters if the view ever forgets its
     * condition, and it is checked here because the failure mode is silence:
     * `Transport.send` would refuse the frame on its own and say nothing, which
     * after a confirmed press is indistinguishable from having destroyed
     * something. `HostLink.closeSession` therefore refuses it out loud.
     */
    func testClosingOnAMachineThatCannotCloseSendsNothingAndSaysSo() {
        let (link, transport) = machine()
        transport.goLive(advertising: [WireCapability.create])

        link.closeSession("s1")

        XCTAssertTrue(transport.closes.isEmpty,
                      "nothing may reach a machine whose parser would drop the socket on it")
        XCTAssertNotNil(link.lastError, "and the press must not be silent")
    }

    /**
     * A machine that *could* close a session cannot while it is offline.
     *
     * The capability is still in memory after the socket goes — the fixture
     * keeps it on purpose — so a check that read the list alone would draw a red
     * button over a dead connection. It is the connection that decides here, and
     * both halves are asserted in one case because the whole claim is that they
     * are one condition: live *and* advertised.
     */
    func testAnOfflineMachineOffersNoCloseEvenHavingAdvertisedIt() {
        let (link, transport) = machine()
        transport.goLive(advertising: [WireCapability.close])
        XCTAssertTrue(link.canCloseSessions)

        transport.drop()

        XCTAssertTrue(transport.capabilities.contains(WireCapability.close),
                      "the machine has not withdrawn anything; the socket went")
        XCTAssertFalse(link.canCloseSessions,
                       "a Close over a dead connection is a press with no outcome to predict")

        link.closeSession("s1")
        XCTAssertTrue(transport.closes.isEmpty, "and it refuses rather than queueing")
    }

    /**
     * Coming back brings the action back, without a re-pair.
     *
     * The forward direction is the one that gets tested and the return is the one
     * that gets forgotten: a gate that latched shut on the first drop would leave
     * a reconnected phone with a swipe that is permanently one action short, and
     * nothing on screen would explain why.
     */
    func testTheActionComesBackWhenTheMachineDoes() {
        let (link, transport) = machine()
        transport.goLive(advertising: [WireCapability.close])
        transport.drop()
        XCTAssertFalse(link.canCloseSessions)

        transport.goLive(advertising: [WireCapability.close])

        XCTAssertTrue(link.canCloseSessions, "reconnecting is not a re-pair")
        link.closeSession("s1")
        XCTAssertEqual(transport.closes, ["s1"], "and the verb reaches the machine again")
    }

    // MARK: - Fixture

    private func machine() -> (HostLink, ScriptedTransport) {
        let transport = ScriptedTransport()
        let link = HostLink(credential: credential(),
                            credentials: MemoryStore(),
                            device: DeviceDescriptor(name: "iPhone", platform: "iOS 26"),
                            makeTransport: { _, _, _ in transport })
        link.start()
        return (link, transport)
    }

    private func credential() -> StoredCredential {
        StoredCredential(endpoint: .relay(url: URL(string: "wss://relay.example")!,
                                          hostId: "M9G95TNJT64Q928VW3HVRYDR8J",
                                          hostKey: Data(repeating: 5, count: 32)),
                         token: "t",
                         kind: .device,
                         deviceId: "d",
                         deviceName: "iPhone",
                         pairedAt: Date(timeIntervalSince1970: 1),
                         nickname: "MacBook")
    }
}
