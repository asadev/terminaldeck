/**
 * The tab bar, and the things about it that a screenshot would not catch.
 *
 * Most of `DeckTabs` is layout, and layout is checked by looking at it. What is
 * checked here is the state underneath, because every one of these has the same
 * failure shape — a tap that appears to do nothing — and every one is invisible
 * in a code review:
 *
 *  1. **Which tabs there are.** Sessions, Localhost, Settings. Both halves of
 *     that changed in one recording: the localhost list came off the session
 *     list and became a tab, and the Machines tab went inside Settings. The two
 *     are easy to half-do — a `Tab` case with no tab drawn for it, or a tab drawn
 *     for a case nothing selects — and neither half fails anything else.
 *  2. **A session opened from anywhere lands on the tab that can show it.** A
 *     notification tap, a deep link and a dev-server row on the Localhost tab can
 *     all ask for a session while another tab is on screen. The route is pushed
 *     onto the Sessions stack; without moving the selection it is pushed
 *     somewhere nobody is looking.
 *  3. **Machines is reachable, and reaching it twice does not stack it.**
 *  4. **Rename names a machine.** The Machines screen renames a row, and a row is
 *     very often not the machine on screen. This used to take no argument at all
 *     and always meant "the current one", which on that screen would rename the
 *     wrong computer — the sort of thing found a week later by somebody tapping
 *     "Work PC" and getting their Mac.
 *  5. **Cancel forgets which row it was.** A stale id left behind is a Save on
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

    // MARK: - Which tabs there are

    /**
     * Three tabs, and which three.
     *
     * Enumerated rather than asserted one at a time, so that adding a fourth
     * without drawing it — or drawing one nothing can select — is a failure here
     * rather than a tab bar somebody notices on a phone.
     *
     * Both changes in this list are his, from one recording, and they pull in
     * opposite directions if you take them literally: *"let's bring four icons in
     * the pill"* while adding Localhost to the three that existed, and then
     * *"maybe this machines thing can go inside the settings this page overall…
     * This is a better design"* a minute later. Only one of those can be built.
     * The second is the one he called better, and it is the one here.
     */
    func testTheTabsAreSessionsLocalhostAndSettings() {
        XCTAssertEqual(DeckModel.Tab.allCases, [.sessions, .localhost, .settings])
    }

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

    /**
     * And from the Localhost tab in particular, which is the new way to arrive
     * here.
     *
     * A dev-server row offers the session its server is running in, and that row
     * is on the Localhost tab now rather than on the session list. So this is a
     * tap on one tab asking for a screen on another — the case the rule above was
     * written for, arriving from a place that did not exist when it was written.
     */
    func testOpeningASessionFromTheLocalhostTabSwitchesToSessions() {
        model.tab = .localhost
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
        model.tab = .localhost
        model.open(session: "not a session id", on: Self.macId)

        XCTAssertEqual(model.tab, .localhost)
        XCTAssertTrue(model.route.isEmpty)
    }

    // MARK: - Machines, inside Settings

    /**
     * The machines are reachable, and reaching them puts the person on the tab
     * whose stack they are pushed onto.
     *
     * The same failure shape as a session opened from the wrong tab, one screen
     * over: a route appended to the Settings stack while Sessions is on screen is
     * a screen pushed behind somebody's back.
     */
    func testShowingTheMachinesLandsOnSettings() {
        model.tab = .sessions
        model.showMachines()

        XCTAssertEqual(model.tab, .settings)
        XCTAssertEqual(model.settingsRoute, [.machines])
    }

    /// Asking twice does not stack two copies of the screen, which would need two
    /// taps of Back to leave.
    func testShowingTheMachinesTwiceDoesNotStackThem() {
        model.showMachines()
        model.showMachines()

        XCTAssertEqual(model.settingsRoute, [.machines])
    }

    /// The two stacks are two stacks. A session must not appear under the gear
    /// icon, and the machines must not appear under the terminal one.
    func testTheSettingsStackAndTheSessionStackAreSeparate() {
        model.showMachines()
        model.open(session: "01J8ZC4T9K5Q2V7XW3NHRF6MBD", on: Self.macId)

        XCTAssertEqual(model.tab, .sessions)
        XCTAssertEqual(model.route.count, 1, "the session is on the Sessions stack")
        XCTAssertEqual(model.settingsRoute, [.machines],
                       "and Settings still has the machines where it left them")
    }

    // MARK: - What is on top of each tab

    /**
     * The tab bar's other half.
     *
     * `DeckChromeTests` pins *whether a surface keeps the bar*. This pins *which
     * surface a tab is showing*, and both have to be right: a pushed terminal
     * still reported as `.sessions` gets a correct answer about the wrong screen
     * — which is a pill over a terminal again, with every other test green.
     *
     * It is worth a test rather than being obvious because the third one is not
     * a path at all. The localhost page is `@State` inside `LocalhostListView`,
     * so this end of it is a flag the browser sets, and a flag can be left set.
     */
    func testEachTabReportsWhatIsOnTopOfIt() {
        XCTAssertEqual(model.sessionsSurface, .sessions)
        XCTAssertEqual(model.localhostSurface, .localhost)
        XCTAssertEqual(model.settingsSurface, .settings)

        model.open(session: "01J8ZC4T9K5Q2V7XW3NHRF6MBD", on: Self.macId)
        XCTAssertEqual(model.sessionsSurface, .session, "a terminal is pushed on Sessions")

        model.localhostPageIsOpen = true
        XCTAssertEqual(model.localhostSurface, .localhostPage)

        model.showMachines()
        XCTAssertEqual(model.settingsSurface, .machines)
    }

    /**
     * The copilot is on the Sessions stack, and the tab bar knows it.
     *
     * Two things at once, and both are the sort that fail silently. Opening the
     * copilot from Settings or from Localhost has to move the selection, or the
     * screen is pushed onto a stack nobody is looking at and the tap reads as
     * having done nothing. And the surface has to report `.copilot` rather than
     * `.session`, because `DeckChrome` is then answering correctly about the
     * wrong screen — a pill floating over a composer, with every other test
     * green.
     */
    func testTheCopilotOpensOnTheSessionsTabAndIsItsOwnSurface() {
        model.tab = .settings
        model.openCopilot(on: Self.macId)

        XCTAssertEqual(model.tab, .sessions)
        XCTAssertEqual(model.route.last, .copilot(host: Self.macId))
        XCTAssertEqual(model.sessionsSurface, .copilot)
        XCTAssertFalse(DeckChrome.showsTabBar(on: model.sessionsSurface))
    }

    /// Asking twice does not stack two copies of a live conversation, which
    /// would take two taps of Back to leave and would look like the first tap
    /// having done nothing.
    func testOpeningTheCopilotTwiceDoesNotStackIt() {
        model.openCopilot(on: Self.macId)
        model.openCopilot(on: Self.macId)

        XCTAssertEqual(model.route, [.copilot(host: Self.macId)])
    }

    /**
     * A session opened from the copilot goes **on top of** it rather than
     * replacing it.
     *
     * That is the other half of "why does this session exist" being one tap in
     * either direction: Back from the terminal has to land on the conversation
     * that started it, not on the session list.
     */
    func testASessionOpenedFromTheCopilotLeavesTheCopilotUnderneath() {
        model.openCopilot(on: Self.macId)
        model.open(session: "01J8ZC4T9K5Q2V7XW3NHRF6MBD", on: Self.macId)

        XCTAssertEqual(model.route, [.copilot(host: Self.macId),
                                     .session(host: Self.macId, id: "01J8ZC4T9K5Q2V7XW3NHRF6MBD")])
        XCTAssertEqual(model.sessionsSurface, .session)
    }

    /**
     * Switching machines pops a copilot belonging to the machine being left.
     *
     * One conversation per machine, keyed by device on the far end — so a
     * copilot screen that survived a switch would be showing one machine's run
     * under another machine's name, with a composer that sends to neither. The
     * same rule `select` already applies to a terminal, extended to the case it
     * did not know about.
     */
    func testSwitchingMachinesPopsTheOtherMachinesCopilot() {
        model.openCopilot(on: Self.macId)
        model.select(Self.pcId)

        XCTAssertTrue(model.route.isEmpty,
                      "the Mac's copilot must not stay on screen under the PC's name")
    }

    /// And each of them goes back when what was on top of it does. A bar that
    /// stayed hidden after the screen it was hidden for had gone would strand
    /// somebody on one tab.
    func testEachTabGoesBackToItselfWhenTheDetailIsPopped() {
        model.open(session: "01J8ZC4T9K5Q2V7XW3NHRF6MBD", on: Self.macId)
        model.localhostPageIsOpen = true
        model.showMachines()

        model.route.removeAll()
        model.localhostPageIsOpen = false
        model.settingsRoute.removeAll()

        XCTAssertEqual(model.sessionsSurface, .sessions)
        XCTAssertEqual(model.localhostSurface, .localhost)
        XCTAssertEqual(model.settingsSurface, .settings)
    }

    /// The two hidden surfaces are hidden and the rest are not, joined up: this
    /// is the sentence he said, expressed against the model rather than against
    /// the enum.
    func testTheBarIsHiddenExactlyInsideASessionAndInsideAPage() {
        model.open(session: "01J8ZC4T9K5Q2V7XW3NHRF6MBD", on: Self.macId)
        model.localhostPageIsOpen = true
        model.showMachines()

        XCTAssertFalse(DeckChrome.showsTabBar(on: model.sessionsSurface))
        XCTAssertFalse(DeckChrome.showsTabBar(on: model.localhostSurface))
        XCTAssertTrue(DeckChrome.showsTabBar(on: model.settingsSurface),
                      "Machines keeps the bar — it is one of the three he named")
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
