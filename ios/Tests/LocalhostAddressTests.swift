/**
 * What the `+` on the Localhost tab accepts, and what it refuses.
 *
 * Asad: *"the `+` starts a new browsing window here too"*, and *"a live link and
 * a localhost link both open on the connected machine, not in a phone web view
 * pretending."* Half of that ships and half of it is refused on purpose;
 * `LocalhostAddress` carries the argument and this pins both halves, because a
 * refusal that quietly became an "open it on the phone instead" would be
 * precisely the pretending he named, and nothing else in the app would notice.
 *
 * The shapes below are the ones people actually type, in the order they type
 * them. Two of them — a bare number and `localhost:3000` — are not URLs at all
 * under `URLComponents`, which is the reason this is a parser rather than a
 * two-line wrapper around `URL`.
 */

import XCTest
@testable import TerminalDeck

final class LocalhostAddressTests: XCTestCase {

    private func parsed(_ text: String) -> LocalhostAddress.Parsed {
        LocalhostAddress.parse(text)
    }

    private func refusal(_ text: String) -> String? {
        if case let .refused(why) = parsed(text) { return why }
        return nil
    }

    // MARK: - The shapes that work

    /// A bare number, which is what somebody who already knows their port types.
    func testABareNumberIsAPortOnTheMachine() {
        XCTAssertEqual(parsed("3000"), .address(port: 3000, path: "/"))
        XCTAssertEqual(parsed(" 8080 "), .address(port: 8080, path: "/"))
        XCTAssertEqual(parsed(":5173"), .address(port: 5173, path: "/"),
                       "the colon is a habit, not a mistake")
    }

    func testTheLoopbackNamesAreAllTheSameMachine() {
        for host in ["localhost", "127.0.0.1", "[::1]", "LOCALHOST"] {
            XCTAssertEqual(parsed("\(host):3000"), .address(port: 3000, path: "/"),
                           "\(host) is this machine")
        }
    }

    /// `127.0.0.0/8` in full, because two projects sharing a port bind to
    /// `127.0.0.2` and the desktop's own scan reports whatever it finds on the
    /// loopback interface rather than only the canonical address.
    func testTheWholeLoopbackRangeCounts() {
        XCTAssertEqual(parsed("127.0.0.2:3000"), .address(port: 3000, path: "/"))
        XCTAssertEqual(parsed("127.13.9.1:3000"), .address(port: 3000, path: "/"))
    }

    /**
     * A path, which is the reason this field exists.
     *
     * Every row on the list opens `/`, and the thing being worked on is very
     * often not at `/`. Until there was somewhere to type one, `localhost:3000
     * /admin` was unreachable from this app entirely.
     */
    func testAPathIsKept() {
        XCTAssertEqual(parsed("localhost:3000/admin"), .address(port: 3000, path: "/admin"))
    }

    /**
     * Including its trailing slash, which is not cosmetic.
     *
     * `URL.path` normalises `/a/b/` to `/a/b` and the first version of this
     * parser used it, so this case is a regression guard rather than a
     * hypothetical: a directory URL and a file URL resolve relative assets from
     * different places, so the page would have loaded and its stylesheet would
     * have 404ed — which on a phone reads as "the app broke my dev server".
     */
    func testATrailingSlashSurvives() {
        XCTAssertEqual(parsed("http://localhost:3000/a/b/"), .address(port: 3000, path: "/a/b/"))
    }

    /// And so are the two things that hang off a path. A dev server's route is
    /// very often a query or a fragment, and dropping either silently would open
    /// the right site at the wrong place.
    func testAQueryAndAFragmentAreKept() {
        XCTAssertEqual(parsed("localhost:3000/x?tab=2"), .address(port: 3000, path: "/x?tab=2"))
        XCTAssertEqual(parsed("localhost:3000/x#top"), .address(port: 3000, path: "/x#top"))
    }

    func testAnExplicitSchemeIsFine() {
        XCTAssertEqual(parsed("http://127.0.0.1:4173"), .address(port: 4173, path: "/"))
        XCTAssertEqual(parsed("https://localhost:8443"), .address(port: 8443, path: "/"),
                       "a dev server with a self-signed certificate is still on this machine")
    }

    // MARK: - The refusals

    /**
     * A site on the internet is refused, and the sentence names it.
     *
     * This is the decision the whole module is about. Opening a live link *on
     * the machine* would mean driving the desktop's own browser from a paired
     * device, which `src/main/deck-control/browser-tools.ts` refuses at every one
     * of its five tools because a phone that can make somebody's Mac open a page
     * and raise a banner asking for a password, inside their own trusted app
     * chrome, is a remote phishing primitive with the best possible disguise.
     * Loading it in the phone's web view instead would look identical and be a
     * lie about where it ran.
     *
     * So the refusal is the feature. The host is named in it because the person
     * typed a perfectly good address and the reason it did not open is about
     * *where the page would have come from* rather than about what they typed.
     */
    func testASiteOnTheInternetIsRefusedByName() {
        let why = refusal("https://example.com")
        XCTAssertNotNil(why)
        XCTAssertTrue(why?.contains("example.com") == true, "the sentence names what was typed")
        XCTAssertNotNil(refusal("example.com:3000"), "a port does not make it this machine")
        XCTAssertNotNil(refusal("192.168.1.4:3000"),
                        "the machine's own LAN address is still not its loopback")
    }

    /// A host with no port cannot be dialled: the tunnel is opened *to a port*,
    /// and guessing 80 would open something nobody asked for.
    func testAHostWithNoPortIsRefused() {
        XCTAssertNotNil(refusal("localhost"))
        XCTAssertNotNil(refusal("http://127.0.0.1/admin"))
    }

    func testAPortOutsideTheRangeIsRefused() {
        XCTAssertNotNil(refusal("0"))
        XCTAssertNotNil(refusal("70000"))
        XCTAssertNotNil(refusal("localhost:99999"))
    }

    func testAnEmptyFieldIsRefusedRatherThanOpeningSomething() {
        XCTAssertNotNil(refusal(""))
        XCTAssertNotNil(refusal("   "))
    }

    /// Not http or https, so not a page. `file:` and `ws:` both parse perfectly
    /// well as URLs and neither is a thing a web view should be pointed at from
    /// a field labelled "open a page".
    func testOtherSchemesAreRefused() {
        XCTAssertNotNil(refusal("file:///etc/passwd"))
        XCTAssertNotNil(refusal("ws://localhost:3000"))
    }

    /**
     * Every refusal is a sentence somebody can act on.
     *
     * The whole complaint this review is built around is controls that do not
     * say what they are doing, and a field that answered "invalid" would be the
     * same failure one screen over. Twenty characters is a low bar deliberately
     * — it is here to catch a code or a single word slipping in, not to police
     * the wording.
     */
    func testEveryRefusalExplainsItself() {
        for text in ["", "localhost", "70000", "https://example.com", "file:///tmp"] {
            let why = refusal(text)
            XCTAssertNotNil(why, "\(text) should be refused")
            XCTAssertGreaterThan(why?.count ?? 0, 20, "\(text) refused with too little to act on")
        }
    }
}
