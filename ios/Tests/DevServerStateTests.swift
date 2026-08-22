/**
 * What the phone does with a `dev.state`, and when it asks for one.
 *
 * `DevServerWireTests` covers the frame. This is the layer above it — the one
 * that decides what is on screen — and every case here is a way a row could be
 * confidently wrong while every frame was decoded correctly.
 *
 * ## The one that matters most: replace, never merge
 *
 * The fields on a report are not independent. `port` and `url` exist only on
 * `ready`, `message` only on `failed`. Folding a new state into an old one
 * therefore leaves a dead address under a live row — the protocol calls it the
 * one genuinely wrong thing a client of this frame can display, and the failure
 * on screen is a phone offering to open `localhost:5173` for a server that died
 * a minute ago. It is enforced by the shape of the storage rather than by care,
 * and this file is what stops somebody making it careful again.
 *
 * ## The rest
 *
 *  - **Asking is subscribing.** The desktop pushes changes only to connections
 *    that asked about a folder, and the subscription belongs to the *socket*. A
 *    reconnect that did not ask again would leave every row frozen at whatever
 *    it said before the drop, with no timer anywhere to notice.
 *  - **Eight, because the desktop subscribes eight.** A ninth folder gets one
 *    reply and then silence, which is a row that says `starting` forever.
 *  - **`no-dev-script` is never a row.** It means there is nothing to press and
 *    never will be; a row for one could only carry a button that gets refused.
 *  - **A drop clears them.** A spinner nobody is going to update is a screen
 *    lying about what a machine is doing.
 */

import XCTest
@testable import TerminalDeck

@MainActor
final class DevServerStateTests: XCTestCase {

    // MARK: - Doubles

    /// A transport whose far end is this test. The same shape `MultiHostTests`
    /// uses; kept local rather than shared because the two files script
    /// different conversations and a shared double grows options for both.
    private final class ScriptedTransport: Transport {
        var state: ConnectionState = .offline
        var capabilities: Set<String> = []
        var onEvent: ((TransportEvent) -> Void)?
        private(set) var sent: [ClientMessage] = []
        /// Set to make `send` refuse, which is what a real transport does when
        /// the socket is down — it never queues.
        var accepts = true

        func start() {}
        func stop() {}
        func resume() {}

        @discardableResult
        func send(_ message: ClientMessage) -> Bool {
            guard accepts else { return false }
            sent.append(message)
            return true
        }

        func goLive(capabilities: Set<String> = ["create", "localhost", "devserver"],
                    folders: [String]? = nil,
                    sessions: [RemoteSession] = []) {
            self.capabilities = capabilities
            state = ConnectionState(phase: .online, detail: "Connected.", retryAt: nil, attempts: 0)
            onEvent?(.state(state))
            onEvent?(.message(.welcome(protocolVersion: 1, deviceId: "d", deviceName: "iPhone",
                                       token: nil, sessions: sessions, capabilities: capabilities,
                                       hostPlatform: .mac, hostName: nil, folders: folders, copilot: .silent, appVersion: nil, hostKind: .unknown),
                              activity: [:]))
        }

        func drop() {
            state = ConnectionState(phase: .waiting, detail: "Reconnecting.", retryAt: nil, attempts: 1)
            onEvent?(.state(state))
        }

        func push(_ report: DevServerReport) {
            onEvent?(.message(.devState(report), activity: [:]))
        }

        func pushFolders(_ folders: [String]) {
            onEvent?(.message(.folders(folders), activity: [:]))
        }

        /// Every folder this connection has been asked about, in order.
        var asked: [String] {
            sent.compactMap { if case let .devStatus(folder) = $0 { return folder } else { return nil } }
        }

        var started: [String] {
            sent.compactMap { if case let .devStart(folder) = $0 { return folder } else { return nil } }
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

    // MARK: - Fixtures

    private static let macId = "M9G95TNJT64Q928VW3HVRYDR8J"

    private var store: MemoryStore!
    private var transport: ScriptedTransport!
    private var model: DeckModel!

    override func setUp() {
        super.setUp()
        store = MemoryStore()
        transport = ScriptedTransport()
        UserDefaults.standard.removeObject(forKey: "terminaldeck.currentHost.v1")
        store.save(StoredCredential(endpoint: .relay(url: URL(string: "wss://relay.example")!,
                                                     hostId: Self.macId,
                                                     hostKey: Data(repeating: 5, count: 32)),
                                    token: "t",
                                    kind: .device,
                                    deviceId: "d",
                                    deviceName: "iPhone",
                                    pairedAt: Date(timeIntervalSince1970: 1),
                                    nickname: "MacBook"))
        let scripted = transport!
        model = DeckModel(credentials: store,
                          device: DeviceDescriptor(name: "iPhone", platform: "iOS 26"),
                          lookup: { _ in nil }) { _, _, _ in scripted }
        model.start()
    }

    private func report(_ folder: String,
                        _ status: DevServerStatus,
                        script: String? = "dev",
                        command: String? = "npm run dev",
                        sessionId: String? = nil,
                        port: Int? = nil,
                        url: String? = nil,
                        note: String? = nil,
                        message: String? = nil) -> DevServerReport {
        DevServerReport(folder: folder, status: status, script: script, command: command,
                        sessionId: sessionId, port: port, url: url, note: note, message: message)
    }

    private func host() throws -> HostLink {
        try XCTUnwrap(model.host(Self.macId))
    }

    // MARK: - Replace, never merge

    /**
     * The whole feature in one test.
     *
     * A folder goes `ready` with a port and a url, then the server dies and the
     * desktop pushes `failed`. If anything merged, the phone would still be
     * holding `5173` under a row that says the server is gone — and the Open
     * button it draws would bind a socket and point a web view at nothing.
     */
    func testANewStateReplacesTheOldOneRatherThanMergingIntoIt() throws {
        transport.goLive(folders: ["/p"])
        transport.push(report("/p", .ready, sessionId: "01J8ZC4T9K5Q2V7XW3NHRF6MBD",
                              port: 5173, url: "http://localhost:5173"))
        XCTAssertEqual(try host().devServer(for: "/p")?.port, 5173)

        transport.push(report("/p", .failed, sessionId: "01J8ZC4T9K5Q2V7XW3NHRF6MBD",
                              message: "The dev server exited."))

        let now = try XCTUnwrap(try host().devServer(for: "/p"))
        XCTAssertEqual(now.status, .failed)
        XCTAssertNil(now.port, "a dead row must not keep the port it had when it was alive")
        XCTAssertNil(now.url, "nor the address")
        XCTAssertEqual(now.message, "The dev server exited.")
    }

    /// And the other way round: a `starting` after a `failed` must not still be
    /// carrying the failure's sentence under its spinner.
    func testAStartingRowDoesNotInheritAPreviousFailuresSentence() throws {
        transport.goLive(folders: ["/p"])
        transport.push(report("/p", .failed, message: "No dev script."))
        transport.push(report("/p", .starting, sessionId: "01J8ZC4T9K5Q2V7XW3NHRF6MBD",
                              note: "installing dependencies"))

        let now = try XCTUnwrap(try host().devServer(for: "/p"))
        XCTAssertEqual(now.status, .starting)
        XCTAssertNil(now.message)
        XCTAssertEqual(now.note, "installing dependencies")
    }

    /**
     * The same state twice, which is not a bug on the wire but the design.
     *
     * A `dev.start` is answered directly *and* pushed, because the direct answer
     * is what reaches a client whose request changed nothing while the push is
     * what makes every later change arrive. So the duplicate has to cost
     * nothing, and this is what says so.
     */
    func testTheSameStateArrivingTwiceChangesNothing() throws {
        transport.goLive(folders: ["/p"])
        let ready = report("/p", .ready, sessionId: "01J8ZC4T9K5Q2V7XW3NHRF6MBD",
                           port: 3000, url: "http://localhost:3000")
        transport.push(ready)
        transport.push(ready)

        XCTAssertEqual(try host().devServerRows.count, 1)
        XCTAssertEqual(try host().devServer(for: "/p"), ready)
    }

    // MARK: - Asking, which is subscribing

    func testEveryGrantedFolderIsAskedAboutOnConnecting() throws {
        transport.goLive(folders: ["/a", "/b", "/c"])
        XCTAssertEqual(transport.asked, ["/a", "/b", "/c"])
    }

    /**
     * A reconnect asks again, because the desktop's subscription belongs to the
     * connection that has just been replaced.
     *
     * Without this every row on screen freezes at whatever it said before the
     * drop and nothing on either end will ever correct it — there is no polling
     * in this feature by design, so there is no second chance.
     */
    func testAReconnectAsksAgainBecauseTheSubscriptionWentWithTheSocket() throws {
        transport.goLive(folders: ["/a"])
        XCTAssertEqual(transport.asked, ["/a"])

        transport.drop()
        transport.goLive(folders: ["/a"])

        XCTAssertEqual(transport.asked, ["/a", "/a"], "the new connection has to subscribe for itself")
    }

    /// The desktop subscribes the first eight folders and answers the rest
    /// without watching them. Asking about a ninth would produce one reply and
    /// then a row that never changes again.
    func testNoMoreFoldersAreAskedAboutThanTheDesktopWillPush() throws {
        let folders = (1 ... 12).map { "/p\($0)" }
        transport.goLive(folders: folders)

        XCTAssertEqual(transport.asked.count, HostLink.maxDevFolders)
        XCTAssertEqual(transport.asked, Array(folders.prefix(HostLink.maxDevFolders)),
                       "the ones kept are the ones the desktop offered first")
    }

    /// A machine that never advertised the capability is never asked. Sending a
    /// verb a desktop does not know closes the socket, which reads to somebody
    /// holding the phone as the network dropping.
    func testAMachineThatDoesNotOfferDevServersIsNeverAsked() throws {
        transport.goLive(capabilities: ["create", "localhost"], folders: ["/p"])

        XCTAssertTrue(transport.asked.isEmpty)
        XCTAssertFalse(model.canUseDevServers)
        XCTAssertTrue(model.devServers.isEmpty)
    }

    /**
     * A machine that offers the capability and has said nothing about folders is
     * asked nothing.
     *
     * It should not be reachable — the desktop only advertises `devserver` when
     * it has a per-device folder list to check against — and the reason it is
     * pinned anyway is what happens if it ever is. The New Session picker has a
     * fallback for a machine that never mentioned folders: it builds a list out
     * of the working directories of the sessions on screen, which is right there
     * and wrong here, because this capability is authorised against the grant
     * list and nothing else. Every question about a folder that was never
     * granted comes back as an `unauthorized` error banner on the session list.
     */
    func testAMachineThatHasNotMentionedFoldersIsAskedNothing() throws {
        transport.goLive(folders: nil, sessions: [
            RemoteSession(id: "01J8ZC4T9K5Q2V7XW3NHRF6MBD", title: "app", cwd: "/p",
                          provider: "shell", status: "idle", exitCode: nil),
        ])

        XCTAssertEqual(try host().startableFolders, ["/p"],
                       "the New Session picker still falls back to what it can see")
        XCTAssertTrue(transport.asked.isEmpty, "but nothing is asked about a folder nobody granted")
        XCTAssertNil(model.lastError)
    }

    func testStartingIsRefusedWithASentenceWhenTheMachineCannotDoIt() throws {
        transport.goLive(capabilities: ["create"], folders: ["/p"])
        model.startDevServer(in: "/p")

        XCTAssertTrue(transport.started.isEmpty, "nothing may go on a wire that would refuse it")
        XCTAssertNotNil(model.lastError)
    }

    /// A press that did not reach the socket is a press that did nothing, and
    /// saying so is better than a row that spins over a message never sent.
    func testAStartThatCouldNotBeSentSaysSoRatherThanLookingLikeItWorked() throws {
        transport.goLive(folders: ["/p"])
        transport.accepts = false

        model.startDevServer(in: "/p")

        XCTAssertNil(try host().devServer(for: "/p"))
        XCTAssertNotNil(model.lastError)
    }

    func testStartingPutsTheFolderOnTheWire() throws {
        transport.goLive(folders: ["/p"])
        model.startDevServer(in: "/p")
        XCTAssertEqual(transport.started, ["/p"])
    }

    // MARK: - Which rows exist

    /**
     * A folder whose `package.json` declares no dev script gets no row at all.
     *
     * `no-dev-script` is not `idle`. `idle` means "press this"; this means there
     * is nothing to press and there never will be for this folder, so a row for
     * one could only carry a button whose single possible outcome is a refusal.
     */
    func testAFolderWithNoDevScriptIsNotDrawn() throws {
        transport.goLive(folders: ["/a", "/b"])
        transport.push(report("/a", .noDevScript, script: nil, command: nil))
        transport.push(report("/b", .idle))

        XCTAssertEqual(model.devServers.map(\.folder), ["/b"])
    }

    /// A folder that has not answered yet has no row either. There is nothing
    /// true to say about it until it does.
    func testAFolderThatHasNotAnsweredYetIsNotDrawn() throws {
        transport.goLive(folders: ["/a", "/b"])
        transport.push(report("/b", .idle))

        XCTAssertEqual(model.devServers.map(\.folder), ["/b"])
    }

    /// The rows are in the machine's own order — most relevant first — rather
    /// than in whatever order the answers happened to arrive.
    func testRowsAreDrawnInTheOrderTheMachineOfferedItsFolders() throws {
        transport.goLive(folders: ["/a", "/b", "/c"])
        transport.push(report("/c", .idle))
        transport.push(report("/a", .idle))
        transport.push(report("/b", .idle))

        XCTAssertEqual(model.devServers.map(\.folder), ["/a", "/b", "/c"])
    }

    // MARK: - Losing the connection

    /**
     * A drop clears the rows.
     *
     * They are only true while something is pushing them. A `starting` spinner
     * kept across a drop would run forever describing a moment that has passed,
     * which is precisely the "looks connected when it is not" failure this app
     * is built around avoiding.
     */
    func testTheRowsGoWhenTheConnectionDoes() throws {
        transport.goLive(folders: ["/p"])
        transport.push(report("/p", .starting, sessionId: "01J8ZC4T9K5Q2V7XW3NHRF6MBD",
                              note: "compiling"))
        XCTAssertEqual(model.devServers.count, 1)

        transport.drop()

        XCTAssertTrue(model.devServers.isEmpty)
        XCTAssertFalse(model.canUseDevServers, "and nothing may be started over a dead socket")
    }

    // MARK: - The grant changing underneath

    /**
     * A folder taken away on the desktop loses its row *and* its remembered
     * state.
     *
     * Filtering at the point of drawing would take the row off the screen and
     * leave the state in memory, so a folder granted again a minute later would
     * come back showing whatever it was doing before it was revoked — with no
     * `dev.status` yet sent to say whether that is still true.
     */
    func testAFolderRemovedFromTheGrantLosesItsRememberedState() throws {
        transport.goLive(folders: ["/a", "/b"])
        transport.push(report("/a", .ready, sessionId: "01J8ZC4T9K5Q2V7XW3NHRF6MBD", port: 3000))
        transport.push(report("/b", .idle))

        transport.pushFolders(["/b"])

        XCTAssertEqual(model.devServers.map(\.folder), ["/b"])
        XCTAssertNil(try host().devServer(for: "/a"), "the state went with the grant")
    }

    /// A folder added on the desktop has never been asked about, so the pushed
    /// list is also a cue to ask.
    func testAFolderAddedToTheGrantIsAskedAbout() throws {
        transport.goLive(folders: ["/a"])
        XCTAssertEqual(transport.asked, ["/a"])

        transport.pushFolders(["/a", "/b"])

        XCTAssertEqual(transport.asked, ["/a", "/a", "/b"],
                       "the new folder is asked about; re-asking the known one re-subscribes it")
    }

    // MARK: - Refreshing

    /// Pull-to-refresh asks again — and it is the *only* thing that does, apart
    /// from a new connection. There is no timer: the desktop pushes, and a
    /// client polling a question that is already being answered is the one thing
    /// the frame's own documentation asks clients not to do.
    func testPullingToRefreshAsksAgain() throws {
        transport.goLive(folders: ["/a"])
        model.refresh()
        XCTAssertEqual(transport.asked, ["/a", "/a"])
    }
}
