/**
 * The sentences the session sheet prints, and the row above it.
 *
 * Both screens draw the same three facts and they are on screen a second apart —
 * a row in the list, then the sheet a long press away — so two implementations
 * of "what is this session doing" would be two answers somebody could see
 * disagree. `SessionDetails` is the one implementation; this is what holds it to
 * what it says.
 *
 * Two of the three have a case that is easy to get backwards:
 *
 *  - **An exit code of 0 is a fact, not an absence.** `exit 0` and `exit 1` are
 *    the two things somebody actually wants off a finished session, and a
 *    truthiness check on the code drops exactly the good one.
 *  - **No timestamp is not "just now".** The desktop has the value and does not
 *    put it on the wire yet, so nil is the *normal* answer today. Printing
 *    anything for it would be inventing a fact about somebody's session.
 */

import XCTest
@testable import TerminalDeck

final class SessionDetailsTests: XCTestCase {

    private func session(status: String, exitCode: Int? = nil, cwd: String = "/Users/a/app") -> RemoteSession {
        RemoteSession(id: "01J8ZC4T9K5Q2V7XW3NHRF6MBD", title: "app", cwd: cwd,
                      provider: "claude", status: status, exitCode: exitCode)
    }

    // MARK: - Status

    func testARunningSessionReadsAsItsStatusAlone() {
        XCTAssertEqual(SessionDetails.statusLine(session(status: "working")), "working")
    }

    /// The status vocabulary belongs to the desktop and is free-form on the
    /// wire. A build of the desktop newer than this app will send a word that is
    /// not in today's list, and the honest thing to do with it is print it.
    func testAStatusThisAppHasNeverHeardOfIsPrintedRatherThanDropped() {
        XCTAssertEqual(SessionDetails.statusLine(session(status: "rebasing")), "rebasing")
    }

    func testAFinishedSessionCarriesItsExitCode() {
        XCTAssertEqual(SessionDetails.statusLine(session(status: "exited", exitCode: 1)),
                       "exited · exit 1")
    }

    /// The case a truthiness check would lose, and the one people are looking
    /// for: a job that finished cleanly.
    func testExitZeroIsPrinted() {
        XCTAssertEqual(SessionDetails.statusLine(session(status: "exited", exitCode: 0)),
                       "exited · exit 0")
    }

    // MARK: - Last activity

    /// Nil is the normal answer today — see the header. It must produce no line
    /// at all rather than a plausible one.
    func testNoTimestampPrintsNothing() {
        XCTAssertNil(SessionDetails.activityLine(nil))
        XCTAssertNil(SessionDetails.activityLine(0))
        XCTAssertNil(SessionDetails.activityLine(-1))
    }

    func testTheBoundariesReadTheWayAPersonWouldSayThem() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        func line(secondsAgo: Double) -> String? {
            SessionDetails.activityLine((now.timeIntervalSince1970 - secondsAgo) * 1000, now: now)
        }

        XCTAssertEqual(line(secondsAgo: 0), "just now")
        XCTAssertEqual(line(secondsAgo: 59), "just now")
        XCTAssertEqual(line(secondsAgo: 60), "1m ago")
        XCTAssertEqual(line(secondsAgo: 3_599), "59m ago")
        XCTAssertEqual(line(secondsAgo: 3_600), "1h ago")
        XCTAssertEqual(line(secondsAgo: 86_399), "23h ago")
        XCTAssertEqual(line(secondsAgo: 86_400), "1d ago")
    }

    /// A machine whose clock is ahead of this phone's produces a negative
    /// interval. "-3m ago" is worse than the vaguest true answer.
    func testAClockThatIsAheadDoesNotProduceANegativeAge() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertEqual(SessionDetails.activityLine((now.timeIntervalSince1970 + 600) * 1000, now: now),
                       "just now")
    }

    // MARK: - Folder names

    func testTheFolderNameIsTheLastComponent() {
        XCTAssertEqual(SessionDetails.folderName("/Users/asad/Projects/terminaldeck"), "terminaldeck")
        XCTAssertEqual(SessionDetails.folderName("/Users/asad/Projects/terminaldeck/"), "terminaldeck")
    }

    /**
     * The machine on the other end is as likely to be a Windows PC as a Mac.
     *
     * `NSString.lastPathComponent` knows only about `/`, so a backslash path
     * comes back as its own whole self — which on a phone row is a full path
     * where a project name should be, truncated to nothing useful.
     */
    func testAWindowsPathIsSplitOnItsOwnSeparator() {
        XCTAssertEqual(SessionDetails.folderName(#"C:\Users\asad\Projects\app"#), "app")
        XCTAssertEqual(SessionDetails.folderName(#"C:\Users\asad\Projects\app\"#), "app")
    }

    /// A path with nothing in it has no name to give, and the honest fallback is
    /// the thing itself rather than an empty row.
    func testAPathWithNoComponentsFallsBackToItself() {
        XCTAssertEqual(SessionDetails.folderName("/"), "/")
        XCTAssertEqual(SessionDetails.folderName(""), "")
    }

    /// The dev-server row names the same folders as the sheet. One
    /// implementation, so they cannot disagree about a Windows path.
    func testTheDevServerRowNamesFoldersTheSameWay() {
        XCTAssertEqual(DevServerRow.folderName(#"C:\src\web"#), SessionDetails.folderName(#"C:\src\web"#))
        XCTAssertEqual(DevServerRow.folderName("/srv/web"), "web")
    }
}
