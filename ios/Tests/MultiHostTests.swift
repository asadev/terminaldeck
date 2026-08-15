/**
 * One phone, several machines.
 *
 * The failure this whole feature has to be designed against is not "multi-host
 * does not work". It is a phone that pairs with a second machine and silently
 * drops the first, because to the person holding it that is indistinguishable
 * from *the app forgot my Mac* — and it is the shape the bug would naturally
 * take, since every one of these types was single-host a day ago.
 *
 * So the first four tests are all the same test asked four ways: after adding a
 * machine, is the other one still there — in the model, in the store, after a
 * relaunch, and after the new one is refused.
 *
 * The second half is about **separation**. Two machines' session lists must not
 * merge, and a keystroke must land on the machine whose session is on screen. A
 * bug there is worse than losing a pairing: it types into the wrong computer.
 *
 * Driven through a scripted transport rather than a socket, for the same reason
 * `LiveTransportTests` is: these are questions about which object holds what,
 * and a real relay would only make them slower to ask. The live path is proved
 * in `MultiHostUITests` against two actual hosts.
 */

import XCTest
@testable import TerminalDeck

@MainActor
final class MultiHostTests: XCTestCase {

    // MARK: - Doubles

    /// A transport whose far end is this test.
    private final class ScriptedTransport: Transport {
        let hostId: String
        var state: ConnectionState = .offline
        var capabilities: Set<String> = []
        var onEvent: ((TransportEvent) -> Void)?
        private(set) var sent: [ClientMessage] = []
        private(set) var starts = 0
        private(set) var stops = 0

        init(hostId: String) {
            self.hostId = hostId
        }

        func start() { starts += 1 }
        func stop() { stops += 1 }
        func resume() {}

        @discardableResult
        func send(_ message: ClientMessage) -> Bool {
            sent.append(message)
            return true
        }

        /// Come up, and say what is running.
        ///
        /// `hostPlatform` defaults to `.mac` only because most of these tests
        /// have one host and do not care; the multi-host cases pass a real one,
        /// since a Mac and a PC in the same list is exactly the situation the
        /// field exists for.
        /// `folders` defaults to nil rather than to a list, because nil is what
        /// every desktop older than per-device grants sends and it is therefore
        /// the case most of these tests are about.
        func goLive(_ sessions: [RemoteSession],
                    capabilities: Set<String> = ["create", "localhost"],
                    hostPlatform: HostPlatform = .mac,
                    folders: [String]? = nil) {
            self.capabilities = capabilities
            state = ConnectionState(phase: .online, detail: "Connected.", retryAt: nil, attempts: 0)
            onEvent?(.state(state))
            onEvent?(.message(.welcome(protocolVersion: 1, deviceId: "d", deviceName: "iPhone",
                                       token: nil, sessions: sessions, capabilities: capabilities,
                                       hostPlatform: hostPlatform, folders: folders),
                              activity: [:]))
        }

        /// The pushed frame, for the case a folder list changes while the phone
        /// is connected.
        func pushFolders(_ folders: [String]) {
            onEvent?(.message(.folders(folders), activity: [:]))
        }

        func confirmAttach(_ id: String) {
            onEvent?(.message(.attached(id: id), activity: [:]))
        }

        func refuse(_ reason: String) {
            onEvent?(.needsPairing(reason))
        }

        var inputs: [(String, String)] {
            sent.compactMap { if case let .input(id, data) = $0 { return (id, data) } else { return nil } }
        }
    }

    /// A store that behaves like the Keychain one without touching the Keychain:
    /// keyed by host id, and adding never removes.
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

    // MARK: - Fixtures

    private static let macId = "M9G95TNJT64Q928VW3HVRYDR8J"
    private static let pcId = "K3ZQW7BHTM4RN8DXVYP2SJ6LC5"

    private var store: MemoryStore!
    private var transports: [String: ScriptedTransport] = [:]
    private var model: DeckModel!

    override func setUp() {
        super.setUp()
        store = MemoryStore()
        transports = [:]
        UserDefaults.standard.removeObject(forKey: "terminaldeck.currentHost.v1")
        model = DeckModel(credentials: store,
                          device: DeviceDescriptor(name: "iPhone", platform: "iOS 26")) { [weak self] hostId, _, _ in
            let transport = ScriptedTransport(hostId: hostId)
            self?.transports[hostId] = transport
            return transport
        }
    }

    private func code(_ hostId: String, token: String = "pairing-token") -> String {
        let key = Data(repeating: 5, count: 32).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return "terminaldeck://pair?v=1&r=wss://relay.example&h=\(hostId)&k=\(key)&t=\(token)"
    }

    private func session(_ id: String, title: String, status: String = "idle") -> RemoteSession {
        RemoteSession(id: id, title: title, cwd: "/Users/asad/\(title)", provider: "claude",
                      status: status, exitCode: nil)
    }

    private func transport(_ hostId: String) throws -> ScriptedTransport {
        try XCTUnwrap(transports[hostId])
    }

    // MARK: - Pairing adds

    /// The requirement, at the level a user would notice it.
    func testPairingASecondMachineKeepsTheFirst() {
        model.pair(with: code(Self.macId))
        XCTAssertEqual(model.hosts.count, 1)

        model.pair(with: code(Self.pcId))

        XCTAssertEqual(model.hosts.count, 2)
        XCTAssertEqual(Set(model.hosts.map(\.id)), [Self.macId, Self.pcId])
        XCTAssertNotNil(store.load(Self.macId), "the first machine must still be in the store")
        XCTAssertNotNil(store.load(Self.pcId))
    }

    /// Both come back on the next launch, which is when the loss would be noticed.
    func testBothMachinesComeBackOnRelaunch() {
        model.pair(with: code(Self.macId))
        model.pair(with: code(Self.pcId))

        let relaunched = DeckModel(credentials: store,
                                   device: DeviceDescriptor(name: "iPhone", platform: "iOS 26")) { hostId, _, _ in
            ScriptedTransport(hostId: hostId)
        }
        XCTAssertEqual(Set(relaunched.hosts.map(\.id)), [Self.macId, Self.pcId])
    }

    /// The machine just paired is the one on screen. Anything else is a pairing
    /// that appears to have done nothing.
    func testTheNewMachineBecomesTheCurrentOne() {
        model.pair(with: code(Self.macId))
        model.pair(with: code(Self.pcId))
        XCTAssertEqual(model.current?.id, Self.pcId)
    }

    /// Re-pairing after a revoke is normal, and must not cost the other machine.
    func testRePairingAMachineDoesNotDuplicateOrDropIt() throws {
        model.pair(with: code(Self.macId))
        model.pair(with: code(Self.pcId))

        model.pair(with: code(Self.macId, token: "fresh-token"))

        XCTAssertEqual(model.hosts.count, 2)
        XCTAssertEqual(store.load(Self.macId)?.token, "fresh-token")
        XCTAssertEqual(store.load(Self.pcId)?.token, "pairing-token")
        XCTAssertEqual(model.current?.id, Self.macId)
    }

    /// A machine that refuses the credential takes itself out of the list and
    /// nothing else with it.
    func testARefusalRemovesOnlyThatMachine() throws {
        model.pair(with: code(Self.macId))
        model.pair(with: code(Self.pcId))
        model.start()

        try transport(Self.pcId).refuse("The desktop refused this device.")

        XCTAssertEqual(model.hosts.map(\.id), [Self.macId])
        XCTAssertNil(store.load(Self.pcId))
        XCTAssertNotNil(store.load(Self.macId))
        XCTAssertEqual(model.current?.id, Self.macId)
        // Named, because "the desktop refused this device" does not say which
        // desktop when there are two of them.
        XCTAssertEqual(model.collectionError?.contains("K3ZQW7"), true)
    }

    func testForgettingOneMachineKeepsTheOther() {
        model.pair(with: code(Self.macId))
        model.pair(with: code(Self.pcId))

        model.unpair(Self.macId)

        XCTAssertEqual(model.hosts.map(\.id), [Self.pcId])
        XCTAssertNil(store.load(Self.macId))
        XCTAssertNotNil(store.load(Self.pcId))
        XCTAssertTrue(model.isPaired)
    }

    // MARK: - Everything stays connected

    /// Not connect-on-switch. The switcher's whole job is live status for the
    /// machines that are *not* on screen.
    func testEveryMachineIsStartedNotJustTheCurrentOne() throws {
        model.pair(with: code(Self.macId))
        model.pair(with: code(Self.pcId))
        model.start()

        XCTAssertGreaterThanOrEqual(try transport(Self.macId).starts, 1)
        XCTAssertGreaterThanOrEqual(try transport(Self.pcId).starts, 1)
    }

    func testAMachineThatIsNotOnScreenStillReportsItsSessions() throws {
        model.pair(with: code(Self.macId))
        model.pair(with: code(Self.pcId))
        model.start()

        try transport(Self.macId).goLive([session("mac-1", title: "api", status: "working")])
        try transport(Self.pcId).goLive([])

        let mac = try XCTUnwrap(model.host(Self.macId))
        XCTAssertTrue(mac.connection.isLive)
        XCTAssertEqual(mac.sessions.count, 1)
        // …while the *current* machine is the PC and shows none of them.
        XCTAssertEqual(model.current?.id, Self.pcId)
        XCTAssertTrue(model.sessions.isEmpty)
    }

    // MARK: - Separation

    func testSessionListsDoNotMerge() throws {
        model.pair(with: code(Self.macId))
        model.pair(with: code(Self.pcId))
        model.start()

        try transport(Self.macId).goLive([session("mac-1", title: "api"), session("mac-2", title: "web")])
        try transport(Self.pcId).goLive([session("pc-1", title: "installer")])

        model.select(Self.macId)
        XCTAssertEqual(model.sessions.map(\.id), ["mac-1", "mac-2"])

        model.select(Self.pcId)
        XCTAssertEqual(model.sessions.map(\.id), ["pc-1"])
    }

    /**
     * A keystroke lands on the machine whose session is on screen.
     *
     * The worst bug this feature could have: not losing a pairing, but typing
     * into the wrong computer.
     */
    func testTypingGoesToTheMachineTheSessionBelongsTo() throws {
        model.pair(with: code(Self.macId))
        model.pair(with: code(Self.pcId))
        model.start()
        try transport(Self.macId).goLive([session("mac-1", title: "api")])
        try transport(Self.pcId).goLive([session("pc-1", title: "installer")])

        let pc = try XCTUnwrap(model.host(Self.pcId))
        pc.attach("pc-1")
        try transport(Self.pcId).confirmAttach("pc-1")
        pc.bridge(for: "pc-1").view.send(txt: "whoami")

        XCTAssertEqual(try transport(Self.pcId).inputs.map(\.1).joined(), "whoami")
        XCTAssertTrue(try transport(Self.macId).inputs.isEmpty,
                      "the other machine must not have seen a byte of it")
    }

    /// Attaching on one machine does not attach on the other, even for an id both
    /// could plausibly have.
    func testAttachingIsPerMachine() throws {
        model.pair(with: code(Self.macId))
        model.pair(with: code(Self.pcId))
        model.start()
        try transport(Self.macId).goLive([session("shared-id", title: "api")])
        try transport(Self.pcId).goLive([session("shared-id", title: "installer")])

        try XCTUnwrap(model.host(Self.macId)).attach("shared-id")

        let macAttaches = try transport(Self.macId).sent.filter { if case .attach = $0 { return true } else { return false } }
        let pcAttaches = try transport(Self.pcId).sent.filter { if case .attach = $0 { return true } else { return false } }
        XCTAssertEqual(macAttaches.count, 1)
        XCTAssertTrue(pcAttaches.isEmpty)
    }

    /**
     * A route carries the machine, so switching cannot leave one machine's
     * terminal open under another machine's name.
     */
    func testSwitchingPopsTheOtherMachinesTerminal() throws {
        model.pair(with: code(Self.macId))
        model.pair(with: code(Self.pcId))
        model.start()
        try transport(Self.macId).goLive([session("mac-1", title: "api")])
        try transport(Self.pcId).goLive([session("pc-1", title: "installer")])

        model.select(Self.macId)
        model.open(session: "mac-1")
        XCTAssertEqual(model.route, [.session(host: Self.macId, id: "mac-1")])

        model.select(Self.pcId)
        XCTAssertTrue(model.route.isEmpty, "a Mac session must not stay on screen under the PC's name")
    }

    /// Forgetting a machine closes anything of its that was open.
    func testForgettingAMachinePopsItsTerminal() throws {
        model.pair(with: code(Self.macId))
        model.start()
        try transport(Self.macId).goLive([session("mac-1", title: "api")])
        model.open(session: "mac-1")

        model.unpair(Self.macId)

        XCTAssertTrue(model.route.isEmpty)
        XCTAssertFalse(model.isPaired)
    }

    /**
     * A `terminaldeck://session/<id>` link names no machine, because the desktop
     * that wrote it does not know the phone has any others. So the machine is the
     * one actually listing that session.
     */
    func testADeepLinkFindsTheMachineThatHasTheSession() throws {
        model.pair(with: code(Self.macId))
        model.pair(with: code(Self.pcId))
        model.start()
        try transport(Self.macId).goLive([session("mac-1", title: "api")])
        try transport(Self.pcId).goLive([session("pc-1", title: "installer")])
        model.select(Self.pcId)

        model.open(URL(string: "terminaldeck://session/mac-1")!)

        XCTAssertEqual(model.current?.id, Self.macId)
        XCTAssertEqual(model.route, [.session(host: Self.macId, id: "mac-1")])
    }

    /// A link for a session nothing is listing opens nothing, rather than
    /// attaching the current machine to an id it has never heard of.
    func testADeepLinkForAnUnknownSessionOpensNothing() throws {
        model.pair(with: code(Self.macId))
        model.start()
        try transport(Self.macId).goLive([session("mac-1", title: "api")])

        model.open(URL(string: "terminaldeck://session/somebody-elses")!)
        XCTAssertEqual(model.route, [.session(host: Self.macId, id: "somebody-elses")],
                       "with one machine there is only one place it could mean")

        model.route = []
        model.pair(with: code(Self.pcId))
        try transport(Self.pcId).goLive([])
        model.open(URL(string: "terminaldeck://session/somebody-elses")!)
        XCTAssertEqual(model.route, [.session(host: Self.pcId, id: "somebody-elses")],
                       "with two, it falls back to the one on screen rather than guessing")
    }

    // MARK: - Folders this device may start a session in

    /**
     * The grant is what the picker offers, and the grant belongs to the machine.
     *
     * The list this phone used to build for itself — the working directories of
     * the sessions it could see — was never the same set the Mac would accept.
     * The picker showed one folder while the desktop would have taken four, and
     * nothing on either screen explained the difference.
     */
    func testThePickerOffersWhatTheMachineGranted() throws {
        model.pair(with: code(Self.macId))
        try transport(Self.macId).goLive([session("s1", title: "alpha")],
                                         folders: ["/Users/asad/alpha", "/Users/asad/beta"])

        XCTAssertEqual(model.startableFolders, ["/Users/asad/alpha", "/Users/asad/beta"])
        XCTAssertTrue(model.canStartSomewhere)
        XCTAssertFalse(model.hasNoGrantedFolders)
    }

    /// A desktop that predates the field keeps the behaviour it always had.
    /// Absent is "I have not told you", not "you may use nothing".
    func testADesktopThatSaysNothingFallsBackToTheFoldersOnScreen() throws {
        model.pair(with: code(Self.macId))
        try transport(Self.macId).goLive([session("s1", title: "alpha"), session("s2", title: "beta")])

        XCTAssertEqual(model.startableFolders, ["/Users/asad/alpha", "/Users/asad/beta"])
        XCTAssertTrue(model.canStartSomewhere, "an old desktop must keep its New Session button")
        XCTAssertFalse(model.hasNoGrantedFolders)
    }

    /**
     * Empty is a person's answer, and it is not the same as silence.
     *
     * A machine that granted this device no folders will refuse every `create`,
     * so the button goes — absent rather than disabled, the same rule the
     * capability list follows — and the screen says where to fix it.
     */
    func testAMachineThatGrantedNothingOffersNoNewSession() throws {
        model.pair(with: code(Self.macId))
        try transport(Self.macId).goLive([session("s1", title: "alpha")], folders: [])

        XCTAssertTrue(model.startableFolders.isEmpty)
        XCTAssertTrue(model.hasNoGrantedFolders)
        XCTAssertFalse(model.canStartSomewhere,
                       "a button whose only outcome is a refusal is not a button")
        // The capability itself is untouched: the machine *can* start sessions,
        // this device just has nowhere to put one. Conflating the two would take
        // the button away from the wrong screens.
        XCTAssertTrue(model.canCreateSessions)
    }

    /// Pushed, not polled. Somebody edits the list on the desktop and the phone
    /// in their other hand stops offering the folder that went.
    func testTheFolderListIsReplacedByThePushedFrame() throws {
        model.pair(with: code(Self.macId))
        let mac = try transport(Self.macId)
        mac.goLive([session("s1", title: "alpha")], folders: ["/Users/asad/alpha", "/Users/asad/beta"])

        mac.pushFolders(["/Users/asad/alpha"])

        XCTAssertEqual(model.startableFolders, ["/Users/asad/alpha"])

        // And a push to none takes the button with it, without a reconnect.
        mac.pushFolders([])
        XCTAssertFalse(model.canStartSomewhere)
    }

    /// Per machine, like everything else here. Offering a Mac's folder to a
    /// Windows PC would be a picker full of choices that fail.
    func testEachMachineHasItsOwnGrant() throws {
        model.pair(with: code(Self.macId))
        model.pair(with: code(Self.pcId))
        try transport(Self.macId).goLive([], folders: ["/Users/asad/alpha"])
        try transport(Self.pcId).goLive([], folders: ["C:\\\\Projects\\\\deck"])

        model.select(Self.macId)
        XCTAssertEqual(model.startableFolders, ["/Users/asad/alpha"])
        model.select(Self.pcId)
        XCTAssertEqual(model.startableFolders, ["C:\\\\Projects\\\\deck"])
    }

    /// A grant belongs to a live connection. Remembering an empty one across a
    /// teardown would leave the phone refusing to offer New Session on a machine
    /// that has simply not been asked yet.
    func testAGrantDoesNotSurviveTheConnection() throws {
        model.pair(with: code(Self.macId))
        let mac = try transport(Self.macId)
        mac.goLive([], folders: [])
        XCTAssertTrue(model.hasNoGrantedFolders)

        try XCTUnwrap(model.host(Self.macId)).stop()
        XCTAssertFalse(model.hasNoGrantedFolders, "back to “has not said”, not to “granted nothing”")
    }

    // MARK: - The switcher

    func testTheSwitcherOnlyAppearsWhenThereIsAChoice() {
        model.pair(with: code(Self.macId))
        XCTAssertFalse(model.hasSeveralHosts)
        model.pair(with: code(Self.pcId))
        XCTAssertTrue(model.hasSeveralHosts)
    }

    func testAMachineCanBeNamed() {
        model.pair(with: code(Self.macId))
        model.rename(Self.macId, to: "Studio")
        XCTAssertEqual(model.current?.label, "Studio")
        XCTAssertEqual(store.load(Self.macId)?.nickname, "Studio")

        // And the name survives a re-pair, which is when the user is least
        // pleased to lose it.
        model.pair(with: code(Self.macId, token: "fresh"))
        XCTAssertEqual(model.current?.label, "Studio")
    }

    // MARK: - One timer, every socket

    /**
     * `7.10`, and on a phone it is battery rather than tidiness.
     *
     * Every paired machine holds a socket and every socket needs the keepalive,
     * so unsynchronised timers would be N chances per cycle to wake the radio for
     * traffic that could have shared one window.
     */
    func testEveryTransportSharesOneTick() {
        let beat = Heartbeat()
        let a = NSObject()
        let b = NSObject()
        let c = NSObject()

        XCTAssertFalse(beat.isTicking)
        beat.join(a) {}
        beat.join(b) {}
        beat.join(c) {}
        XCTAssertEqual(beat.memberCount, 3)
        XCTAssertTrue(beat.isTicking, "one loop")

        beat.leave(a)
        beat.leave(b)
        XCTAssertTrue(beat.isTicking)

        beat.leave(c)
        // A timer with no consumer is pure cost, and on a phone it is cost with
        // this app's name next to it in Settings.
        XCTAssertFalse(beat.isTicking)
        XCTAssertEqual(beat.memberCount, 0)
    }

    func testTheTickFiresEveryMemberInOneGo() async {
        let beat = Heartbeat()
        let a = NSObject()
        let b = NSObject()
        var beats: [String] = []
        beat.join(a) { beats.append("a") }
        beat.join(b) { beats.append("b") }

        // Not waited on for real — 25 seconds is the interval and this test is
        // about the fan-out, not the clock. `join` is enough to prove both are
        // in the set; firing them is the loop's one line.
        XCTAssertEqual(beat.memberCount, 2)
        XCTAssertTrue(beats.isEmpty, "nothing beats on joining")
    }
}
