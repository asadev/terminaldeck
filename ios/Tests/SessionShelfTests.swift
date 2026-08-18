/**
 * The two swipe gestures, as rules rather than as a screen.
 *
 * Asad asked for buttons under a swiped session row — *"close the session (with
 * a confirmation), archive, move. When we will have a lot of sessions we will
 * not like to have all of them over here"* — and this is the half of that which
 * can be checked without a phone: what archiving and pinning do to a list, what
 * they do to each other, and what survives a relaunch.
 *
 * ## Why the ordering is here and not in the view
 *
 * Because it is the part with a wrong answer. Which rows are drawn and in what
 * order is three interacting rules — pinned first in pin order, archived not at
 * all, everything else in the machine's order — and a view that answered it with
 * three predicates inline would be a view whose empty state and whose list could
 * disagree about whether there was anything to show. `SessionShelf.split` is one
 * call with one answer, so this file is where the rules are settled.
 *
 * Every case runs against a `UserDefaults` suite of its own. A test that used
 * the standard defaults would archive sessions on whatever machine the suite
 * happened to run on, which is a test that changes the app it is testing.
 */

import XCTest
@testable import TerminalDeck

final class SessionShelfTests: XCTestCase {

    private var defaults: UserDefaults!
    private var suiteName: String!
    private var shelf: SessionShelf!

    private static let mac = "M9G95TNJT64Q928VW3HVRYDR8J"
    private static let pc = "K3ZQW7BHTM4RN8DXVYP2SJ6LC5"

    override func setUp() {
        super.setUp()
        suiteName = "shelf.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        shelf = SessionShelf(defaults: defaults)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    private func session(_ id: String, status: String = "idle") -> RemoteSession {
        RemoteSession(id: id, title: id, cwd: "/work/\(id)", provider: "shell", status: status, exitCode: nil)
    }

    private var three: [RemoteSession] { [session("a"), session("b"), session("c")] }

    // MARK: - Archive

    /// The row leaves the list and turns up in the other half of the answer.
    /// Both halves matter: a row that vanished from one without appearing in the
    /// other would be a delete.
    func testArchivingTakesARowOffTheListAndPutsItSomewhere() {
        shelf.setArchived(true, host: Self.mac, session: "b")

        let split = shelf.split(three, host: Self.mac)
        XCTAssertEqual(split.listed.map(\.id), ["a", "c"])
        XCTAssertEqual(split.archived.map(\.id), ["b"])
    }

    /// And it comes back. An archive that could not be undone is a delete with a
    /// friendlier word on it, and there is nothing on this phone that can delete
    /// a session.
    func testUnarchivingPutsTheRowBackWhereItWas() {
        shelf.setArchived(true, host: Self.mac, session: "b")
        shelf.setArchived(false, host: Self.mac, session: "b")

        XCTAssertEqual(shelf.split(three, host: Self.mac).listed.map(\.id), ["a", "b", "c"],
                       "back in the machine's own order, not appended to the end")
        XCTAssertTrue(shelf.split(three, host: Self.mac).archived.isEmpty)
    }

    /**
     * One machine's archive does not reach another's.
     *
     * The failure this prevents is invisible until somebody owns two computers:
     * session ids come from each machine's own session layer and nothing makes
     * them unique across machines, so a store keyed on the id alone would hide a
     * row on the Mac because of a swipe on the PC — and the row would look, to
     * the person holding the phone, as though the machine had lost a session.
     */
    func testArchivingIsPerMachine() {
        shelf.setArchived(true, host: Self.mac, session: "b")

        XCTAssertEqual(shelf.split(three, host: Self.pc).listed.map(\.id), ["a", "b", "c"])
        XCTAssertTrue(shelf.split(three, host: Self.pc).archived.isEmpty)
    }

    // MARK: - Pin

    /// Pinned rows lead, and everything else keeps the order the machine sent.
    func testPinningMovesARowToTheTop() {
        shelf.setPinned(true, host: Self.mac, session: "c")

        XCTAssertEqual(shelf.split(three, host: Self.mac).listed.map(\.id), ["c", "a", "b"])
    }

    /**
     * Two pins keep **the order they were pinned in**, newest first.
     *
     * This is the whole point of the gesture and it is the thing a naive
     * implementation gets wrong: re-sorting the pinned rows by the machine's own
     * order would throw away the one statement the person was making, which is
     * which of the two they want to look at first.
     */
    func testThePinnedRowsAreInPinOrderAndNotTheMachinesOrder() {
        shelf.setPinned(true, host: Self.mac, session: "a")
        shelf.setPinned(true, host: Self.mac, session: "c")

        XCTAssertEqual(shelf.split(three, host: Self.mac).listed.map(\.id), ["c", "a", "b"],
                       "the most recently pinned row is the one at the top")
    }

    func testUnpinningPutsTheRowBackInTheMachinesOrder() {
        shelf.setPinned(true, host: Self.mac, session: "c")
        shelf.setPinned(false, host: Self.mac, session: "c")

        XCTAssertEqual(shelf.split(three, host: Self.mac).listed.map(\.id), ["a", "b", "c"])
    }

    // MARK: - The two states contradict each other

    /**
     * Pinning something archived brings it back.
     *
     * The two states cannot both be true — a row cannot be at the top of a list
     * it is absent from — and the resolution has to be the one that leaves the
     * person looking at what they just asked for. Pinning is a statement that the
     * row matters; the only honest response is to draw it.
     */
    func testPinningAnArchivedRowUnarchivesIt() {
        shelf.setArchived(true, host: Self.mac, session: "b")
        shelf.setPinned(true, host: Self.mac, session: "b")

        let split = shelf.split(three, host: Self.mac)
        XCTAssertEqual(split.listed.map(\.id), ["b", "a", "c"])
        XCTAssertTrue(split.archived.isEmpty)
        XCTAssertFalse(shelf.isArchived(host: Self.mac, session: "b"))
    }

    /**
     * And archiving something pinned drops the pin.
     *
     * The mirror, and it is not symmetric decoration: a stale pin left behind
     * would make a later unarchive jump the row to the top of the list for a
     * reason nobody could see, weeks after the gesture that caused it.
     */
    func testArchivingAPinnedRowDropsThePin() {
        shelf.setPinned(true, host: Self.mac, session: "c")
        shelf.setArchived(true, host: Self.mac, session: "c")
        shelf.setArchived(false, host: Self.mac, session: "c")

        XCTAssertFalse(shelf.isPinned(host: Self.mac, session: "c"))
        XCTAssertEqual(shelf.split(three, host: Self.mac).listed.map(\.id), ["a", "b", "c"])
    }

    // MARK: - What the screen is told

    /**
     * The count is measured against the sessions the machine is **currently**
     * listing, not against the store.
     *
     * A machine that has been restarted has archived ids for sessions that no
     * longer exist, and a badge counting those opens onto an empty screen — the
     * classic "3" on a folder with nothing in it. Nothing prunes the store when
     * a session disappears, deliberately, because a socket that dropped
     * mid-refresh would otherwise erase somebody's archive; so the pruning
     * happens where it is safe, which is at the moment of counting.
     */
    func testTheCountIgnoresArchivedSessionsTheMachineNoLongerLists() {
        shelf.setArchived(true, host: Self.mac, session: "b")
        shelf.setArchived(true, host: Self.mac, session: "gone")

        XCTAssertEqual(shelf.archivedCount(three, host: Self.mac), 1)
        XCTAssertEqual(shelf.archived(host: Self.mac), ["b", "gone"],
                       "the record survives — a machine that comes back brings its row with it")
    }

    /// A machine nobody has swiped on pays for nothing: the same array back, in
    /// the same order, and no copy of the list built to answer it.
    func testAnUntouchedMachineGetsItsListBackUnchanged() {
        let split = shelf.split(three, host: Self.mac)
        XCTAssertEqual(split.listed, three)
        XCTAssertTrue(split.archived.isEmpty)
    }

    /// No host means no shelf. Nothing is paired at that moment, and writing
    /// under an empty key would attach one machine's archive to the next machine
    /// that fails to identify itself.
    func testNothingIsStoredAgainstAnEmptyHost() {
        shelf.setArchived(true, host: "", session: "b")
        shelf.setPinned(true, host: "", session: "c")

        XCTAssertEqual(shelf.split(three, host: "").listed, three)
        XCTAssertTrue(shelf.archived(host: "").isEmpty)
    }

    // MARK: - It survives a relaunch

    /**
     * Both lists come back, in order, from a second instance reading the same
     * defaults.
     *
     * This is what makes the gesture worth using at all. An archive that lasted
     * until the app was next killed would be a gesture people learn not to
     * trust, and the list he complained about would be long again by morning.
     */
    func testBothListsSurviveARelaunch() {
        shelf.setArchived(true, host: Self.mac, session: "b")
        shelf.setPinned(true, host: Self.mac, session: "c")
        shelf.setPinned(true, host: Self.pc, session: "a")

        let reopened = SessionShelf(defaults: defaults)
        XCTAssertEqual(reopened.split(three, host: Self.mac).listed.map(\.id), ["c", "a"])
        XCTAssertEqual(reopened.split(three, host: Self.mac).archived.map(\.id), ["b"])
        XCTAssertEqual(reopened.split(three, host: Self.pc).listed.map(\.id), ["a", "b", "c"])
    }

    /**
     * The store is bounded, oldest dropped first.
     *
     * There is no moment at which this store learns that a session is gone for
     * good, so nothing can be cleaned up on an event; the bound is what stops a
     * machine that churns through sessions for a year from growing this without
     * limit. Oldest first because the newest archive is the one somebody might
     * still be looking for.
     */
    func testTheArchiveIsBoundedAndDropsTheOldestFirst() {
        for index in 0 ..< (SessionShelf.maxPerHost + 5) {
            shelf.setArchived(true, host: Self.mac, session: "s\(index)")
        }

        let ids = shelf.archived(host: Self.mac)
        XCTAssertEqual(ids.count, SessionShelf.maxPerHost)
        XCTAssertEqual(ids.first, "s5", "the first five archived are the five that were dropped")
        XCTAssertEqual(ids.last, "s\(SessionShelf.maxPerHost + 4)")
    }
}
