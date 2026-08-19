/**
 * The tab bar, and the things about it that a screenshot would not catch.
 *
 * Most of `DeckTabs` is layout, and layout is checked by looking at it. What is
 * checked here is the state underneath, because every one of these has the same
 * failure shape — a tap that appears to do nothing — and every one is invisible
 * in a code review:
 *
 *  1. **Which tabs there are, and in which order.** Copilot, Sessions,
 *     Localhost, Settings. Every one of those has moved at least once: the
 *     localhost list came off the session list and became a tab, the Machines
 *     tab went inside Settings, and the copilot went from a pinned row on the
 *     session list to the leftmost pill. Each move is easy to half-do — a `Tab`
 *     case with no tab drawn for it, or a tab drawn for a case nothing selects —
 *     and neither half fails anything else. The **order** is asserted as well as
 *     the membership, because he named it: *"Copilot · Sessions · Localhost ·
 *     Settings"*, with the copilot leftmost, and a bar with the right four pills
 *     in the wrong order is a bar somebody's thumb has to relearn.
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

    /**
     * Put one machine's copilot into the state a phone paired as **his** is in.
     *
     * The two frames the desktop actually sends, in order — the `welcome` that
     * carries a `copilot` object because this device is one of his, and the
     * `copilot.grant` that answers the hello and opens the connection — rather
     * than a back door on `CopilotLink`. A helper that reached past the wire
     * could put the link in a combination the desktop cannot produce, and the
     * property under test here is *what the tab bar does about a real machine*.
     *
     * There is no third frame. It used to redeem a six-digit code and store a
     * credential; both went on 2026-08-19, so the whole of "connecting the
     * copilot" is now the welcome arriving with the field in it.
     */
    private func giveCopilot(to host: HostLink) {
        let grant = CopilotGrant(read: true, act: true, alter: false)
        host.copilot.welcomed(capabilities: [Copilot.capability],
                              connection: CopilotConnection(stated: true, linked: true,
                                                            open: false, grant: grant))
        host.copilot.apply(pushed: CopilotConnection(stated: true, linked: true,
                                                     open: true, grant: grant))
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
     * Four tabs, which four, and in what order.
     *
     * Enumerated rather than asserted one at a time, so that adding a fifth
     * without drawing it — or drawing one nothing can select — is a failure here
     * rather than a tab bar somebody notices on a phone.
     *
     * `allCases` follows declaration order, which is also the order `DeckTabs`
     * writes them into the `TabView`, so this pins the arrangement he asked for
     * and not merely the membership: *"a fourth pill, and the copilot goes
     * leftmost — Copilot · Sessions · Localhost · Settings."*
     *
     * This is the third answer to "how many pills" and it is the one that ships.
     * *"Let's bring four icons in the pill"* came first, with Localhost added to
     * the three that existed; *"maybe this machines thing can go inside the
     * settings this page overall… this is a better design"* took one off a
     * minute later; and this took the copilot off the session list and made it
     * the first. Each supersedes the one before it, and the last statement wins
     * — the earlier arguments are recorded on `DeckModel.Tab` rather than
     * re-run here.
     */
    func testTheTabsAreCopilotSessionsLocalhostAndSettings() {
        XCTAssertEqual(DeckModel.Tab.allCases, [.copilot, .sessions, .localhost, .settings])
        XCTAssertEqual(DeckModel.Tab.allCases.first, .copilot, "he asked for it leftmost")
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
        XCTAssertEqual(model.copilotSurface, .copilot)
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
     * The copilot is a tab, and asking for it selects that tab rather than
     * pushing anything.
     *
     * It used to be a route on the Sessions stack, pushed from a pinned row.
     * The failure to guard against is the one that survived the move: something
     * that asks for *a machine's* copilot — a deep link, a notification, a row
     * on another screen — has to land on the conversation itself, not on
     * whatever terminal happened to be pushed over it the last time the tab was
     * looked at. A tab keeps its stack across selections, which is right for a
     * thumb on the pill and wrong here.
     */
    func testOpeningTheCopilotSelectsItsTabAndShowsTheConversation() {
        model.tab = .settings
        model.open(session: "01J8ZC4T9K5Q2V7XW3NHRF6MBD", on: Self.macId)
        model.tab = .copilot
        model.open(session: "01J8ZC4T9K5Q2V7XW3NHRF6MBE", on: Self.macId)
        XCTAssertFalse(model.copilotRoute.isEmpty, "a terminal is pushed over the conversation")

        model.openCopilot(on: Self.macId)

        XCTAssertEqual(model.tab, .copilot)
        XCTAssertTrue(model.copilotRoute.isEmpty, "asking for the copilot lands on the copilot")
        XCTAssertEqual(model.copilotSurface, .copilot)
    }

    /**
     * The copilot draws no tab bar, and neither does a terminal pushed over it.
     *
     * *"Pill should not be inside the chat box."* Both surfaces the copilot's
     * own stack can be showing are hidden ones, and the second is worth
     * asserting beside the first because it is the case a `copilotSurface` bug
     * would silently get right — a stack that failed to notice a push would
     * answer `.copilot`, and `.copilot` is now also hidden. The equality on the
     * surface itself is what makes this test able to fail for the real reason.
     */
    func testNeitherTheCopilotNorATerminalOverItDrawsTheBar() {
        XCTAssertEqual(model.copilotSurface, .copilot)
        XCTAssertFalse(DeckChrome.showsTabBar(on: model.copilotSurface),
                       "either we will type or we will use the pill")

        model.tab = .copilot
        model.open(session: "01J8ZC4T9K5Q2V7XW3NHRF6MBD", on: Self.macId)
        XCTAssertEqual(model.copilotSurface, .session)
        XCTAssertFalse(DeckChrome.showsTabBar(on: model.copilotSurface),
                       "the pill was covering the bottom rows of the terminal")
    }

    // MARK: - The fourth pill, and the way home

    /**
     * **Three pills on a machine with no copilot for this phone, four on one
     * that has it.**
     *
     * *"If the copilot is not connecting, this icon should not be inside the
     * pill — then it will be three icon pill. Otherwise if the copilot is
     * connected, then four icon pill, automatically, like that way."* And what
     * decides it, since 2026-08-19: *"if we are connecting as my device copilot
     * automatically comes, if we connect as guest then copilot don't come."*
     *
     * Driven through the model rather than through `CopilotAccess` directly,
     * because the failure this guards against is not the enum getting the answer
     * wrong — `CopilotPillTests` walks every case of that — but the bar asking
     * the wrong machine. `showsCopilotTab` reads `current`, and a phone paired
     * with two machines has two answers: it can be his own device on one and a
     * guest on the other, which is exactly the arrangement the second half of
     * this case stands for.
     */
    func testThePillAppearsOnlyForAMachineWhoseCopilotIsThisPhones() throws {
        model.select(Self.macId)
        XCTAssertFalse(model.showsCopilotTab,
                       "before any welcome there is nothing to draw a fourth pill from")

        let mac = try XCTUnwrap(model.host(Self.macId))
        giveCopilot(to: mac)
        XCTAssertTrue(model.showsCopilotTab, "and four once the welcome says so")

        // The other machine has its own answer, and switching to it must give
        // that answer rather than the one that happened to be on screen.
        model.select(Self.pcId)
        XCTAssertFalse(model.showsCopilotTab,
                       "no copilot on the PC for this phone — the pill belongs to the machine")
    }

    /**
     * **A copilot that disconnects underneath somebody keeps its pill.**
     *
     * The clause that is not in the sentence he said, and the reason it is here:
     * SwiftUI would drop the whole tab, and with it the screen the person is
     * reading, landing them on some other tab with no explanation of what just
     * happened. A tab that vanishes underneath somebody is worse than one that
     * stays and explains — `CopilotView` draws the disconnected state, which
     * says what happened and where the remedy is.
     *
     * And it goes on the next tap somewhere else, which is the first moment
     * removing it costs nobody anything.
     */
    func testAPillIsNotPulledOutFromUnderSomebodyStandingOnIt() throws {
        let mac = try XCTUnwrap(model.host(Self.macId))
        model.select(Self.macId)
        giveCopilot(to: mac)
        model.show(.copilot)
        XCTAssertTrue(model.showsCopilotTab)

        mac.copilot.forget()
        XCTAssertFalse(mac.copilotAccess.isConnected, "the machine dropped it")
        XCTAssertTrue(model.showsCopilotTab,
                      "the tab somebody is standing on must not be deleted underneath them")

        model.show(.sessions)
        XCTAssertFalse(model.showsCopilotTab, "and it goes the moment they leave")
    }

    /**
     * **Back goes where they came from**, and the session list is the fallback.
     *
     * *"There should be a back button to go back on home."* Home is the session
     * list for somebody who tapped the pill from the session list, and it is
     * Localhost for somebody who tapped it while reading their ports — a chevron
     * that always landed on the sessions would teleport a third of the people
     * who press it.
     *
     * The first case is the one that makes the fallback matter: `tab` set
     * directly, by a deep link or a notification, records nothing, and Back has
     * to land somewhere real anyway. It is asserted before the others because
     * `homeTab` is sticky by design — it holds the last recorded answer rather
     * than being cleared on the way out — so a fresh model is the only place the
     * default itself is observable.
     */
    func testBackFromTheCopilotReturnsToWhereItWasEnteredFrom() {
        // The fallback first, while nothing has been recorded: a `tab` set
        // directly — a deep link, a notification — still has to leave somebody
        // somewhere real.
        model.tab = .copilot
        model.leaveCopilot()
        XCTAssertEqual(model.tab, .sessions, "the fallback is the screen the app opens on")

        model.show(.localhost)
        model.show(.copilot)
        model.leaveCopilot()
        XCTAssertEqual(model.tab, .localhost)

        model.show(.settings)
        model.show(.copilot)
        model.leaveCopilot()
        XCTAssertEqual(model.tab, .settings)
    }

    /// Re-entering the copilot must not record the copilot as its own way home.
    /// A tap on a pill that is already selected would otherwise leave Back
    /// pointing at the screen it is drawn on, which is a button that does
    /// nothing on the one screen with no other way out.
    func testEnteringTheCopilotTwiceDoesNotMakeBackPointAtItself() {
        model.show(.localhost)
        model.show(.copilot)
        model.show(.copilot)
        model.openCopilot(on: Self.macId)

        model.leaveCopilot()
        XCTAssertEqual(model.tab, .localhost)
    }

    /**
     * **There is nowhere in Settings to connect the copilot, and there is not
     * meant to be.**
     *
     * This case used to be `testTheCopilotConnectionScreenIsReachableFromAnywhereInSettings`,
     * pushing `SettingsRoute.copilot` and landing on a six-digit field —
     * *"actually connecting copilot should be in the settings."* Then the
     * ceremony went: *"instead of giving mobile app separate connection for
     * copilot just make it like if we are connecting as my device copilot
     * automatically comes."*
     *
     * What is asserted instead is the shape that replaced it. Settings has one
     * destination, Machines — which is also the honest place for anything to do
     * with what kind of device this is — and it still keeps the tab bar when
     * pushed, which is the property the old case was quietly covering.
     */
    func testSettingsHasOneDestinationAndItKeepsTheBar() {
        model.tab = .sessions
        model.showMachines()

        XCTAssertEqual(model.tab, .settings)
        XCTAssertEqual(model.settingsRoute, [.machines])
        XCTAssertEqual(model.settingsSurface, .machines,
                       "anything pushed on Settings keeps the bar, like Machines does")

        model.showMachines()
        XCTAssertEqual(model.settingsRoute, [.machines], "asking twice does not stack two copies")
    }

    /**
     * A session opened **from the copilot** stays on the copilot's stack.
     *
     * That is the other half of "why does this session exist" being one tap in
     * either direction: Back from the terminal has to land on the conversation
     * that started it. Pushing it onto the Sessions tab instead would move the
     * person to another tab and lose the thread, which is worse than it sounds —
     * they would then have to remember which of four pills they came from.
     */
    func testASessionOpenedFromTheCopilotStaysOnTheCopilotsStack() {
        model.tab = .copilot
        model.open(session: "01J8ZC4T9K5Q2V7XW3NHRF6MBD", on: Self.macId)

        XCTAssertEqual(model.tab, .copilot, "it must not jump to another tab")
        XCTAssertEqual(model.copilotRoute, [.session(host: Self.macId, id: "01J8ZC4T9K5Q2V7XW3NHRF6MBD")])
        XCTAssertTrue(model.route.isEmpty, "and nothing is pushed onto the Sessions stack")
    }

    /**
     * Switching machines pops a terminal on the copilot's stack too.
     *
     * The conversation itself needs no popping — the tab redraws for whichever
     * machine is current — but a session pushed over it belongs to the machine
     * being left, and leaving it up would show one machine's output under
     * another machine's name. `select` already did this for the Sessions stack;
     * the copilot's stack is the one it did not know about.
     */
    func testSwitchingMachinesPopsATerminalOnTheCopilotStack() {
        model.tab = .copilot
        model.open(session: "01J8ZC4T9K5Q2V7XW3NHRF6MBD", on: Self.macId)
        model.select(Self.pcId)

        XCTAssertTrue(model.copilotRoute.isEmpty,
                      "the Mac's terminal must not stay on screen under the PC's name")
    }

    /// And the two stacks stay separate, which is the whole reason there are
    /// two: a session opened from the list must not appear under the copilot,
    /// and one opened from the copilot must not appear under the list.
    func testTheTwoSessionStacksDoNotLeakIntoEachOther() {
        model.tab = .sessions
        model.open(session: "01J8ZC4T9K5Q2V7XW3NHRF6MBD", on: Self.macId)
        model.tab = .copilot
        model.open(session: "01J8ZC4T9K5Q2V7XW3NHRF6MBE", on: Self.macId)

        XCTAssertEqual(model.route, [.session(host: Self.macId, id: "01J8ZC4T9K5Q2V7XW3NHRF6MBD")])
        XCTAssertEqual(model.copilotRoute, [.session(host: Self.macId, id: "01J8ZC4T9K5Q2V7XW3NHRF6MBE")])
        XCTAssertEqual(model.openSession?.id, "01J8ZC4T9K5Q2V7XW3NHRF6MBE",
                       "what is on screen is whatever the current tab has pushed")
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
