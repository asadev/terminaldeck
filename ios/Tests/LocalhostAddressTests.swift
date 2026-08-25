/**
 * What the address fields accept, and what they make of it.
 *
 * Two functions, and the split is the point. `parse` answers the narrow question
 * the tunnel needs — *is this one of this machine's own ports* — and its cases
 * are the first half of this file, unchanged. `classify` is the decision both
 * address fields actually make, and it is the second half.
 *
 * > *"browsers should browse any normal Google or any web internet website
 * > also. But it will be actually browsing on the server side; here it will be
 * > presenting that. So it shouldn't say that it cannot browse, because before I
 * > failed to browse… So it should work seamless for everything."*
 *
 * Seamless is a claim about a rule, and a rule is a thing a test can hold. Every
 * shape below is one somebody types: a port, a bare host with no scheme, a
 * search phrase, a scheme this app will not open. The interesting ones are the
 * two that are **not URLs at all** under `URLComponents` — `3000` and
 * `localhost:3000` — and the two that look like each other and are not:
 * `google.com` and `git`.
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

    // MARK: - classify: which of three things is this

    private func kind(_ text: String) -> LocalhostAddress.Typed {
        LocalhostAddress.classify(text)
    }

    /**
     * **The one he was refused.** A bare host, no scheme, no `www`.
     *
     * Nobody types the scheme. The refusal he hit came from the machine never
     * advertising `web` — `CAPABILITY.web` is gated on
     * `RemoteEndpointOptions.openUrl` being a function and the headless host
     * passed none — but the phone still has to hand the far side a string every
     * gate over there accepts: `isNavigationAllowed` in `browser-url.ts` runs
     * `new URL`, and `new URL('google.com')` throws.
     */
    func testABareHostIsAPageOnTheMachine() {
        XCTAssertEqual(kind("google.com"), .page("http://google.com"))
        XCTAssertEqual(kind("www.bbc.co.uk"), .page("http://www.bbc.co.uk"))
        XCTAssertEqual(kind("terminaldeck.dev/docs"), .page("http://terminaldeck.dev/docs"))
    }

    /// A scheme that is already there is kept, and lowercased on the way out so
    /// one page is one string however it was typed.
    func testASchemeIsKeptAndNormalised() {
        XCTAssertEqual(kind("https://news.ycombinator.com"), .page("https://news.ycombinator.com"))
        XCTAssertEqual(kind("HTTP://GOOGLE.COM"), .page("http://google.com"))
    }

    /// A host with a port is a host even when it has one label — nobody writes a
    /// port on a search term — and a LAN address is a page rather than a tunnel,
    /// because the tunnel dials the machine's own loopback and that is somewhere
    /// else.
    func testAPortOnAHostMakesItAHost() {
        XCTAssertEqual(kind("192.168.1.5:8080"), .page("http://192.168.1.5:8080"))
        XCTAssertEqual(kind("build-box:9000"), .page("http://build-box:9000"))
    }

    /// The machine's own ports still go through the tunnel, and `classify` hands
    /// that answer straight back from `parse` so there is one opinion about which
    /// names are this machine's.
    func testThisMachinesOwnPortsAreStillTheTunnel() {
        XCTAssertEqual(kind("3000"), .tunnel(port: 3000, path: "/"))
        XCTAssertEqual(kind(":5173"), .tunnel(port: 5173, path: "/"))
        XCTAssertEqual(kind("localhost:3000/admin"), .tunnel(port: 3000, path: "/admin"))
        XCTAssertEqual(kind("127.0.0.2:8080"), .tunnel(port: 8080, path: "/"))
    }

    /**
     * **Anything that is not an address is a search**, which is the half that
     * makes the field seamless.
     *
     * A browser that answered *"that is not an address this phone can read"* to a
     * question is the flat refusal this whole change exists to delete. A space is
     * the giveaway — a URL percent-encodes one — and a single label with no dot
     * and no port is a word.
     */
    func testWordsAreASearchRatherThanARefusal() {
        for words in ["what is my ip", "swift concurrency", "git", "readme", "1.2.3"] {
            guard case let .search(query, url) = kind(words) else {
                return XCTFail("\(words) should be a search, not \(kind(words))")
            }
            XCTAssertEqual(query, words, "the words are kept for the sentence that confirms it")
            XCTAssertTrue(url.hasPrefix(LocalhostAddress.searchBase), "\(url) should be a search")
        }
    }

    /// The query survives the round trip. A search for `a+b c` that arrived as
    /// `a b c` would be a silent change to what somebody asked for, which is
    /// worse than a refusal.
    func testASearchIsEncodedRatherThanFlattened() {
        guard case let .search(_, url) = kind("swift & objc") else {
            return XCTFail("that should be a search")
        }
        XCTAssertFalse(url.contains(" "), "a URL cannot carry a raw space")
        XCTAssertTrue(url.contains("%26"), "the ampersand has to survive as data: \(url)")
    }

    /**
     * A scheme this app will not open is refused, and the check has to happen
     * **before** anything reads the string as a host — otherwise
     * `file:///etc/passwd` becomes the host `file` and is opened as a page.
     *
     * And it must not fire on `localhost:3000`, whose "scheme" is `localhost`:
     * that is the single most likely thing anybody types here. `browser-url.ts`
     * has the same trap and the same expression for it.
     */
    func testOnlyHttpAndHttpsAreOpened() {
        for text in ["file:///etc/passwd", "ws://example.com/socket", "javascript:alert(1)"] {
            guard case .refused = kind(text) else {
                return XCTFail("\(text) should be refused, not \(kind(text))")
            }
        }
        XCTAssertEqual(kind("localhost:3000"), .tunnel(port: 3000, path: "/"),
                       "`localhost` is a host wearing a scheme's clothes")
    }

    /// A number that is not a port is a refusal about the number rather than a
    /// search for it: somebody who typed `70000` meant a port and wants to know.
    func testAnImpossiblePortIsRefusedRatherThanSearched() {
        guard case .refused = kind("70000") else {
            return XCTFail("70000 should be refused, not \(kind("70000"))")
        }
    }

    /// A loopback name with no port keeps its question, because *"Which port?"*
    /// is a question with an answer somebody can type — and searching the web
    /// for the word `localhost` is not what they meant.
    func testALoopbackNameWithNoPortStillAsksWhichPort() {
        guard case let .refused(why) = kind("localhost") else {
            return XCTFail("localhost alone should be refused, not \(kind("localhost"))")
        }
        XCTAssertTrue(why.lowercased().contains("port"), "it should ask for the port: \(why)")
    }

    /// A paste that went wrong, or one smuggling a second target past the eye.
    /// Refused rather than searched, because the honest reading is that the
    /// input is damaged — the same check `browser-url.ts` makes on the host.
    func testAControlCharacterIsRefused() {
        guard case .refused = kind("google.com\u{0}evil.example") else {
            return XCTFail("a control character should be refused")
        }
    }

    /// Nothing typed is a sentence rather than a search for the empty string.
    func testAnEmptyLineIsASentence() {
        guard case let .refused(why) = kind("   ") else {
            return XCTFail("an empty line should be refused")
        }
        XCTAssertGreaterThan(why.count, 20, "refused with too little to act on")
    }
}
