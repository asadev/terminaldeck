/**
 * The tab bar, and the three things about it that a screenshot would not catch.
 *
 * Most of `DeckTabs` is layout, and layout is checked by looking at it. What is
 * checked here is the state underneath, because all three of these have the same
 * failure shape — a tap that appears to do nothing — and all three are invisible
 * in a code review:
 *
 *  1. **A session opened from anywhere lands on the tab that can show it.** A
 *     notification tap, a deep link and the Machines tab can all ask for a
 *     session while another tab is on screen. The route is pushed onto the
 *     Sessions stack; without moving the selection it is pushed somewhere nobody
 *     is looking.
 *  2. **Rename names a machine.** The Machines tab renames a row, and a row is
 *     very often not the machine on screen. This used to take no argument at all
 *     and always meant "the current one", which on the new screen would rename
 *     the wrong computer — the sort of thing found a week later by somebody
 *     tapping "Work PC" and getting their Mac.
 *  3. **Cancel forgets which row it was.** A stale id left behind is a Save on
 *     the next rename landing on the machine somebody cancelled out of.
 */

import XCTest
@testable import TerminalDeck

@MainActor
final class DeckTabsTests: XCTestCase {

    // MARK: - Doubles

    /// A transport that does nothing. These tests are about the model's own
    /// bookkeeping; `MultiHostTests` is where the wire is scripted.
    private final class SilentTransport: Transport {
        var state: ConnectionState = .offline
        var capabilities: Set<String> = []
        var onEvent: ((TransportEvent) -> Void)?
        func start() {}
        func stop() {}
        func resume() {}
        @discardableResult func send(_ message: ClientMessage) -> Bool { true }
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

    private static let macId = "M9G95TNJT64Q928VW3HVRYDR8J"
    private static let pcId = "K3ZQW7BHTM4RN8DXVYP2SJ6LC5"

    private var store: MemoryStore!
    private var model: DeckModel!

    override func setUp() {
        super.setUp()
        store = MemoryStore()
        UserDefaults.standard.removeObject(forKey: "terminaldeck.currentHost.v1")
        store.save(credential(Self.macId, nickname: "MacBook"))
        store.save(credential(Self.pcId, nickname: "Work PC"))
        model = DeckModel(credentials: store,
                          device: DeviceDescriptor(name: "iPhone", platform: "iOS 26"),
                          lookup: { _ in nil }) { _, _, _ in SilentTransport() }
    }

    private func credential(_ hostId: String, nickname: String) -> StoredCredential {
        StoredCredential(endpoint: .relay(url: URL(string: "wss://relay.example")!,
                                          hostId: hostId,
                                          hostKey: Data(repeating: 5, count: 32)),
                         token: "t",
                         kind: .device,
                         deviceId: "d",
                         deviceName: "iPhone",
                         pairedAt: Date(timeIntervalSince1970: hostId == Self.macId ? 1 : 2),
                         nickname: nickname)
    }

    // MARK: - Which tab

    /// The app opens on the sessions, which is what it is for.
    func testTheAppStartsOnSessions() {
        XCTAssertEqual(model.tab, .sessions)
    }

    /**
     * Opening a session moves to the tab whose stack the route is pushed onto.
     *
     * The failure without this is silent and complete: the terminal is on the
     * navigation stack, the stack belongs to Sessions, and the person is looking
     * at Settings. Nothing appears to have happened, and going to Sessions later
     * lands them in a terminal they did not ask for.
     */
    func testOpeningASessionFromAnotherTabSwitchesToSessions() {
        model.tab = .settings
        model.open(session: "01J8ZC4T9K5Q2V7XW3NHRF6MBD", on: Self.macId)

        XCTAssertEqual(model.tab, .sessions)
        XCTAssertEqual(model.route.last,
                       .session(host: Self.macId, id: "01J8ZC4T9K5Q2V7XW3NHRF6MBD"))
    }

    /// A session id that is not one is refused, and refusing it must not drag the
    /// person off the tab they were on to show them nothing. (A space, because
    /// `SessionID` allows hyphens and underscores — "not-a-session-id" is a
    /// perfectly well-formed id and would have made this test pass for the wrong
    /// reason.)
    func testAnInvalidSessionLinkChangesNothing() {
        model.tab = .machines
        model.open(session: "not a session id", on: Self.macId)

        XCTAssertEqual(model.tab, .machines)
        XCTAssertTrue(model.route.isEmpty)
    }

    // MARK: - Renaming a row

    /// The machine the alert was raised for is the machine that gets the name,
    /// not whichever one happens to be selected.
    func testRenamingARowRenamesThatRowAndNotTheCurrentMachine() throws {
        model.select(Self.macId)
        XCTAssertEqual(model.current?.id, Self.macId)

        model.beginRename(Self.pcId)
        XCTAssertTrue(model.renamingHost)
        XCTAssertEqual(model.renameText, "Work PC", "the field starts at the name it is editing")

        model.renameText = "Studio PC"
        model.commitRename()

        XCTAssertEqual(try XCTUnwrap(model.host(Self.pcId)).label, "Studio PC")
        XCTAssertEqual(try XCTUnwrap(model.host(Self.macId)).label, "MacBook",
                       "the machine on screen was not the one being renamed")
        XCTAssertFalse(model.renamingHost)
    }

    /// The overflow menu's Rename — the one that means "this machine" — still
    /// means the machine on screen.
    func testRenameWithNoRowNamedStillMeansTheCurrentMachine() throws {
        model.select(Self.pcId)
        model.beginRename()
        model.renameText = "Rebuilt PC"
        model.commitRename()

        XCTAssertEqual(try XCTUnwrap(model.host(Self.pcId)).label, "Rebuilt PC")
        XCTAssertEqual(try XCTUnwrap(model.host(Self.macId)).label, "MacBook")
    }

    /// Cancelling drops the row it was about. Without this the next Save lands on
    /// the machine somebody backed out of renaming.
    func testCancellingARenameForgetsWhichMachineItWasAbout() throws {
        model.select(Self.macId)
        model.beginRename(Self.pcId)
        model.cancelRename()
        XCTAssertFalse(model.renamingHost)

        model.beginRename()
        model.renameText = "Air"
        model.commitRename()

        XCTAssertEqual(try XCTUnwrap(model.host(Self.macId)).label, "Air")
        XCTAssertEqual(try XCTUnwrap(model.host(Self.pcId)).label, "Work PC",
                       "the cancelled rename must not leak into the next one")
    }

    /// Renaming something that is not paired does nothing rather than raising an
    /// alert over a machine that has just been forgotten from another screen.
    func testRenamingAMachineThatIsGoneDoesNothing() {
        model.beginRename("QQQQQQQQQQQQQQQQQQQQQQQQQQ")
        XCTAssertFalse(model.renamingHost)
    }
}
