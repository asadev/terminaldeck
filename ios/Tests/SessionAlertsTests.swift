/**
 * Being told that a machine needs you.
 *
 * The feature is worth having only if it is *quiet*: an app that buzzes for
 * everything is one people turn off in a week, at which point it is worth
 * nothing at all. So most of these tests are about what is **not** raised — a
 * session that was already waiting before this phone connected, a session
 * starting work, a status the desktop invented that this build has never seen,
 * and the session the person is looking at right now.
 *
 * The second half drives the whole path through `DeckModel` with a scripted
 * transport, because the routing rules — suppress what is on screen, summarise a
 * catch-up, honour the switches — live there and are the part that decides
 * whether somebody's phone buzzes in a meeting.
 */

import XCTest
@testable import TerminalDeck

@MainActor
final class SessionAlertsTests: XCTestCase {

    private func session(_ id: String, _ status: String, exitCode: Int? = nil) -> RemoteSession {
        RemoteSession(id: id, title: "daftar", cwd: "/Users/asad/daftar", provider: "claude",
                      status: status, exitCode: exitCode)
    }

    // MARK: - Transitions

    /// The first list seeds and says nothing. A session that was already waiting
    /// before this phone heard of the machine did not just start waiting.
    func testTheFirstListIsSilent() {
        let alerts = SessionAlerts()
        let raised = alerts.observe(hostId: "mac", hostName: "MacBook",
                                    sessions: [session("a", "waiting"), session("b", "working")])
        XCTAssertEqual(raised, [])
    }

    func testASessionThatStopsAndWaitsIsWorthTelling() {
        let alerts = SessionAlerts()
        _ = alerts.observe(hostId: "mac", hostName: "MacBook", sessions: [session("a", "working")])

        let raised = alerts.observe(hostId: "mac", hostName: "MacBook", sessions: [session("a", "waiting")])

        XCTAssertEqual(raised.count, 1)
        XCTAssertEqual(raised.first?.kind, .needsYou)
        XCTAssertEqual(raised.first?.title, "daftar")
        XCTAssertEqual(raised.first?.body, "Waiting for you on MacBook.")
    }

    /// `input` means the same thing to a person as `waiting` — the agent has
    /// stopped and is asking. Both are the alert; neither re-fires as the other.
    func testWaitingAndInputAreOneEvent() {
        let alerts = SessionAlerts()
        _ = alerts.observe(hostId: "mac", hostName: "MacBook", sessions: [session("a", "working")])
        XCTAssertEqual(alerts.observe(hostId: "mac", hostName: "MacBook",
                                      sessions: [session("a", "input")]).count, 1)

        let again = alerts.observe(hostId: "mac", hostName: "MacBook", sessions: [session("a", "waiting")])

        XCTAssertEqual(again, [], "one stop, one alert — not one per word the desktop uses for it")
    }

    func testFinishingIsWorthTellingQuietly() {
        let alerts = SessionAlerts()
        _ = alerts.observe(hostId: "mac", hostName: "MacBook", sessions: [session("a", "working")])

        let raised = alerts.observe(hostId: "mac", hostName: "MacBook", sessions: [session("a", "completed")])

        XCTAssertEqual(raised.first?.kind, .finished)
        XCTAssertEqual(raised.first?.body, "Finished on MacBook.")
    }

    func testANonZeroExitSaysWhatItWas() {
        let alerts = SessionAlerts()
        _ = alerts.observe(hostId: "mac", hostName: "MacBook", sessions: [session("a", "working")])

        let raised = alerts.observe(hostId: "mac", hostName: "MacBook",
                                    sessions: [session("a", "exited", exitCode: 1)])

        XCTAssertEqual(raised.first?.body, "Stopped on MacBook — exit 1.")
    }

    /// The session ending after it completed is one ending, not two.
    func testCompletedThenExitedIsNotASecondAlert() {
        let alerts = SessionAlerts()
        _ = alerts.observe(hostId: "mac", hostName: "MacBook", sessions: [session("a", "working")])
        _ = alerts.observe(hostId: "mac", hostName: "MacBook", sessions: [session("a", "completed")])

        let raised = alerts.observe(hostId: "mac", hostName: "MacBook",
                                    sessions: [session("a", "exited", exitCode: 0)])

        XCTAssertEqual(raised, [])
    }

    /// Starting work is the app doing what it was told. Being buzzed about it is
    /// how notifications get turned off.
    func testStartingWorkIsNotNews() {
        let alerts = SessionAlerts()
        _ = alerts.observe(hostId: "mac", hostName: "MacBook", sessions: [session("a", "idle")])

        let raised = alerts.observe(hostId: "mac", hostName: "MacBook", sessions: [session("a", "working")])

        XCTAssertEqual(raised, [])
    }

    /// The status vocabulary belongs to the desktop and a newer build may add to
    /// it. An unknown word produces no alert rather than a guessed one.
    func testAStatusThisBuildHasNeverHeardOfIsNotAnEvent() {
        let alerts = SessionAlerts()
        _ = alerts.observe(hostId: "mac", hostName: "MacBook", sessions: [session("a", "working")])

        let raised = alerts.observe(hostId: "mac", hostName: "MacBook",
                                    sessions: [session("a", "rebasing-the-universe")])

        XCTAssertEqual(raised, [])
    }

    /// A session that appears already waiting is not an event either: it is
    /// either one this phone just started, or one somebody made on the desktop.
    func testANewSessionIsNotAnEventEvenIfItArrivesWaiting() {
        let alerts = SessionAlerts()
        _ = alerts.observe(hostId: "mac", hostName: "MacBook", sessions: [session("a", "working")])

        let raised = alerts.observe(hostId: "mac", hostName: "MacBook",
                                    sessions: [session("a", "working"), session("b", "waiting")])

        XCTAssertEqual(raised, [])
    }

    /// Two machines, two histories. Session ids are unique per host and nothing
    /// makes them unique across hosts, so a flat map would let one machine's
    /// session shadow the other's and report the wrong machine's work.
    func testTwoMachinesDoNotShareOneMemory() {
        let alerts = SessionAlerts()
        _ = alerts.observe(hostId: "mac", hostName: "MacBook", sessions: [session("a", "working")])
        _ = alerts.observe(hostId: "pc", hostName: "Work PC", sessions: [session("a", "idle")])

        let fromPC = alerts.observe(hostId: "pc", hostName: "Work PC", sessions: [session("a", "waiting")])

        XCTAssertEqual(fromPC.count, 1)
        XCTAssertEqual(fromPC.first?.hostName, "Work PC")
        XCTAssertEqual(alerts.lastKnownStatus(host: "mac", session: "a"), "working",
                       "the Mac's memory must not have been touched")
    }

    func testForgettingAMachineForgetsItsSessions() {
        let alerts = SessionAlerts()
        _ = alerts.observe(hostId: "mac", hostName: "MacBook", sessions: [session("a", "working")])

        alerts.forget(hostId: "mac")

        // Re-pairing seeds again rather than announcing everything at once.
        XCTAssertEqual(alerts.observe(hostId: "mac", hostName: "MacBook",
                                      sessions: [session("a", "waiting")]), [])
    }

    // MARK: - The away sentence

    func testTheAwaySentenceCounts() {
        let waiting = SessionAlert(hostId: "m", hostName: "MacBook", sessionId: "a",
                                   sessionTitle: "daftar", kind: .needsYou, exitCode: nil)
        let done = SessionAlert(hostId: "m", hostName: "MacBook", sessionId: "b",
                                sessionTitle: "site", kind: .finished, exitCode: nil)

        XCTAssertEqual(AwayReport.sentence(for: [waiting]),
                       "While you were away: 1 session needs you.")
        XCTAssertEqual(AwayReport.sentence(for: [waiting, waiting, done]),
                       "While you were away: 2 sessions need you, 1 finished.")
        XCTAssertEqual(AwayReport.sentence(for: [done, done]),
                       "While you were away: 2 finished.")
        XCTAssertNil(AwayReport.sentence(for: []))
    }

    // MARK: - Through the model

    /// A transport whose far end is this test. The same shape `MultiHostTests`
    /// uses, cut down to what these cases drive.
    private final class ScriptedTransport: Transport {
        var state: ConnectionState = .offline
        var capabilities: Set<String> = []
        var onEvent: ((TransportEvent) -> Void)?

        func start() {}
        func stop() {}
        func resume() {}

        @discardableResult
        func send(_ message: ClientMessage) -> Bool { true }

        func goLive(_ sessions: [RemoteSession]) {
            state = ConnectionState(phase: .online, detail: "Connected.", retryAt: nil, attempts: 0)
            onEvent?(.state(state))
            onEvent?(.message(.welcome(protocolVersion: 1, deviceId: "d", deviceName: "iPhone",
                                       token: nil, sessions: sessions, capabilities: ["create"],
                                       hostPlatform: .mac, folders: nil),
                              activity: [:]))
        }

        func push(_ sessions: [RemoteSession]) {
            onEvent?(.message(.sessions(sessions), activity: [:]))
        }

        func status(_ id: String, _ status: String) {
            onEvent?(.message(.status(id: id, status: status), activity: [:]))
        }
    }

    private final class MemoryStore: CredentialStore {
        private var records: [String: StoredCredential] = [:]
        private let keys = StaticKeyPair.generate()

        func all() -> [StoredCredential] { records.values.sorted { $0.pairedAt < $1.pairedAt } }
        func load(_ hostId: String) -> StoredCredential? { records[hostId] }
        func save(_ credential: StoredCredential) { records[credential.hostId] = credential }
        func remove(_ hostId: String) { records.removeValue(forKey: hostId) }
        func clearAll() { records = [:] }
        func deviceKeys() -> StaticKeyPair { keys }
    }

    /// Stands in for `UNUserNotificationCenter`, which in a simulator would put a
    /// permission prompt in front of the test run.
    private final class RecordingAlerts: AlertPresenting {
        var presented: [SessionAlert] = []
        var answer: AlertPermission = .allowed

        func permission() async -> AlertPermission { answer }
        func request() async -> AlertPermission { answer }
        func present(_ alert: SessionAlert) { presented.append(alert) }
    }

    private static let macId = "M9G95TNJT64Q928VW3HVRYDR8J"

    /**
     * The fake rendezvous, and the code that finds it.
     *
     * A code carries no address any more — the QR and the link that used to
     * carry one are gone — so pairing is a lookup followed by a connection.
     * Stubbing the lookup is what keeps this suite off the network; the
     * derivation itself is checked in `RendezvousTests` against the desktop's
     * own vectors.
     */
    private static let pairingCode = "482913"

    private func offer(_ hostId: String) -> MachineOffer {
        MachineOffer(relayURL: URL(string: "wss://relay.example")!,
                     hostId: hostId,
                     hostKey: Data(repeating: 5, count: 32))
    }


    private var transport: ScriptedTransport!
    private var presenter: RecordingAlerts!
    private var model: DeckModel!

    /*
     * `async`, and that is a consequence of the format rather than a style
     * choice: six digits carry no address, so pairing is a rendezvous lookup
     * followed by a connection, and `pair(with:)` starts a task. A synchronous
     * `setUp` would return before the machine existed and every case below would
     * run against an unpaired model.
     */
    override func setUp() async throws {
        try await super.setUp()
        UserDefaults.standard.removeObject(forKey: "terminaldeck.currentHost.v1")
        AlertSettings.needsYou = true
        AlertSettings.finished = true
        transport = ScriptedTransport()
        presenter = RecordingAlerts()
        let transport = transport!
        let macId = Self.macId
        model = DeckModel(credentials: MemoryStore(),
                          device: DeviceDescriptor(name: "iPhone", platform: "iOS 26"),
                          alerts: presenter,
                          lookup: { [weak self] typed in
                              typed == Self.pairingCode ? self?.offer(macId) : nil
                          }) { _, _, _ in transport }
        await model.pairAsync(with: Self.pairingCode)
        model.start()
    }

    func testAStatusFrameRaisesAnAlert() {
        transport.goLive([session("a", "working")])

        transport.status("a", "waiting")

        XCTAssertEqual(presenter.presented.count, 1)
        XCTAssertEqual(presenter.presented.first?.kind, .needsYou)
        XCTAssertEqual(presenter.presented.first?.sessionId, "a")
    }

    /**
     * Not the session on screen, while the app is on screen.
     *
     * Somebody watching a terminal does not need a banner over it saying the
     * thing they are watching has happened.
     */
    func testTheSessionBeingLookedAtDoesNotInterrupt() {
        transport.goLive([session("a", "working")])
        model.open(session: "a", on: Self.macId)

        transport.status("a", "waiting")

        XCTAssertEqual(presenter.presented, [])
    }

    /// The same session with the phone in a pocket is exactly what people want
    /// to be told about.
    func testTheSameSessionDoesInterruptWhenTheAppIsAway() {
        transport.goLive([session("a", "working")])
        model.open(session: "a", on: Self.macId)
        model.isForeground = false

        transport.status("a", "waiting")

        XCTAssertEqual(presenter.presented.count, 1)
    }

    /// A different session on the same machine still interrupts — it is not the
    /// one being watched.
    func testAnotherSessionStillInterrupts() {
        transport.goLive([session("a", "working"), session("b", "working")])
        model.open(session: "a", on: Self.macId)

        transport.push([session("a", "working"), session("b", "waiting")])

        XCTAssertEqual(presenter.presented.count, 1)
        XCTAssertEqual(presenter.presented.first?.sessionId, "b")
    }

    func testTheSwitchesDecideWhatIsWorthSaying() {
        AlertSettings.finished = false
        transport.goLive([session("a", "working"), session("b", "working")])

        transport.push([session("a", "completed"), session("b", "waiting")])

        XCTAssertEqual(presenter.presented.count, 1, "only the one that is asking")
        XCTAssertEqual(presenter.presented.first?.kind, .needsYou)
    }

    func testBothSwitchesOffMeansSilence() {
        AlertSettings.needsYou = false
        AlertSettings.finished = false
        transport.goLive([session("a", "working")])

        transport.status("a", "waiting")

        XCTAssertEqual(presenter.presented, [])
    }

    /**
     * A reconnect while the app is open is a catch-up, not four banners.
     *
     * The first list after a connection comes back describes things that already
     * happened. With the app in front of somebody, that is a line of text at the
     * top of the list; with the app away, it is still a notification, because
     * then it is the only way they will hear.
     */
    func testACatchUpWhileTheAppIsOpenIsASentenceRatherThanBanners() {
        transport.goLive([session("a", "working"), session("b", "working")])

        // The socket came back with both sessions changed while it was down.
        transport.goLive([session("a", "waiting"), session("b", "completed")])

        XCTAssertEqual(presenter.presented, [], "a catch-up must not fire banners at somebody who is looking")
        XCTAssertEqual(model.awayReport, "While you were away: 1 session needs you, 1 finished.")
    }

    func testACatchUpWhileTheAppIsAwayStillNotifies() {
        transport.goLive([session("a", "working")])
        model.isForeground = false

        transport.goLive([session("a", "waiting")])

        XCTAssertEqual(presenter.presented.count, 1)
        XCTAssertNil(model.awayReport)
    }

    func testTheAwayReportCanBeDismissed() {
        transport.goLive([session("a", "working")])
        transport.goLive([session("a", "waiting")])
        XCTAssertNotNil(model.awayReport)

        model.dismissAwayReport()

        XCTAssertNil(model.awayReport)
    }
}
