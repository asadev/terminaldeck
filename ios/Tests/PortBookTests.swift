/**
 * The names this phone gives ports, and the ways they could go to the wrong
 * machine or come back changed.
 *
 * The store is three dictionaries and a `UserDefaults` write, so most of what is
 * worth testing is about the edges rather than the mechanism:
 *
 *  - **Two machines are two namespaces.** A phone paired with a Mac and a
 *    Windows PC is holding two unrelated port 3000s, and the failure to design
 *    against is the Mac's name appearing over the PC's server.
 *  - **The text is bounded on the way in and again on the way out.** A pasted
 *    paragraph would push a card to three lines; a record written by an older
 *    build must not be able to get around the bound either.
 *  - **A fold that matches the default is still written.** A default that later
 *    changes must not silently re-fold a group somebody deliberately opened.
 */

import XCTest
@testable import TerminalDeck

final class PortBookTests: XCTestCase {

    private var suite: String!
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        // A suite of its own per test, so a run cannot rename the ports on the
        // machine it is running from and two cases cannot see each other.
        suite = "terminaldeck.tests.portbook.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    }

    override func tearDown() {
        UserDefaults.standard.removePersistentDomain(forName: suite)
        defaults = nil
        suite = nil
        super.tearDown()
    }

    private func book() -> PortBook {
        PortBook(defaults: defaults)
    }

    // MARK: - Naming

    func testANameIsKeptAgainstOneMachineAndOnePort() {
        let store = book()
        store.setName("Storefront", host: "mac", port: 5173)

        XCTAssertEqual(store.name(host: "mac", port: 5173), "Storefront")
        XCTAssertNil(store.name(host: "mac", port: 3000))
        // The failure this keying exists to prevent: a phone paired with two
        // machines showing one machine's names over the other's ports.
        XCTAssertNil(store.name(host: "pc", port: 5173))
    }

    func testNamesSurviveTheAppBeingRestarted() {
        book().setName("Agent control panel", host: "pc", port: 6666)
        // A second instance over the same defaults is what a relaunch looks like.
        XCTAssertEqual(book().name(host: "pc", port: 6666), "Agent control panel")
    }

    /// Selecting the field and deleting is how somebody undoes a name, and it
    /// must not leave an empty string behind — a row with a name that is nothing
    /// reads as a nameless row that will not go back to showing its port.
    func testClearingIsEmptyWhitespaceOrNil() {
        let store = book()
        for cleared in ["", "   ", "\n"] {
            store.setName("Something", host: "mac", port: 3000)
            store.setName(cleared, host: "mac", port: 3000)
            XCTAssertNil(store.name(host: "mac", port: 3000), "\(cleared.debugDescription) should clear")
        }
        store.setName("Something", host: "mac", port: 3000)
        store.setName(nil, host: "mac", port: 3000)
        XCTAssertNil(store.name(host: "mac", port: 3000))
    }

    /// A pasted paragraph is trimmed and cut. The name in the rename field is
    /// then the name on the row, rather than the row quietly truncating a longer
    /// string every time it is drawn.
    func testTextIsTrimmedStrippedAndCut() {
        XCTAssertEqual(PortBook.clean("  Storefront  "), "Storefront")
        XCTAssertEqual(PortBook.clean("Store\nfront"), "Storefront")
        XCTAssertEqual(PortBook.clean("Store\u{07}front"), "Storefront")
        XCTAssertNil(PortBook.clean("   "))
        XCTAssertNil(PortBook.clean(nil))

        let long = String(repeating: "a", count: PortBook.maxNameLength + 25)
        XCTAssertEqual(PortBook.clean(long)?.count, PortBook.maxNameLength)
    }

    /// The bound is a property of what a row can draw, so a record written by an
    /// older build — or edited by hand in a simulator — is held to it too.
    func testAnOversizedRecordOnDiskIsCutWhenItIsRead() throws {
        let long = String(repeating: "b", count: 400)
        let raw = try JSONSerialization.data(
            withJSONObject: ["names": ["mac": ["5173": long]], "folds": [String: [String: Bool]]()])
        defaults.set(raw, forKey: "terminaldeck.portBook.v1")

        XCTAssertEqual(book().name(host: "mac", port: 5173)?.count, PortBook.maxNameLength)
    }

    /// A machine with no id is a machine nothing is paired with. Writing under an
    /// empty key would put every unpaired phone's names in one bucket, to be
    /// handed to whichever machine is paired next.
    func testNothingIsWrittenWithoutAMachine() {
        let store = book()
        store.setName("Nowhere", host: "", port: 3000)
        XCTAssertNil(store.name(host: "", port: 3000))
    }

    // MARK: - Folding

    /// The starting position: the groups worth reading are open and the noise is
    /// closed. It is a default rather than a rule — see the next case.
    func testTheDefaultFoldIsOpenOnSignalAndClosedOnNoise() {
        let store = book()
        for category in [PortCategory.named, .devServer, .web] {
            XCTAssertFalse(store.isFolded(host: "mac", category: category), "\(category) should start open")
        }
        for category in [PortCategory.app, .other, .unnamed] {
            XCTAssertTrue(store.isFolded(host: "mac", category: category), "\(category) should start closed")
        }
    }

    /**
     * A choice beats the default in both directions, and it is remembered even
     * when it agrees with the default.
     *
     * The second half is the part worth a test: written only when it *differs*,
     * a later change to what a category defaults to would silently re-fold a
     * group somebody had deliberately opened, on a machine where that group is
     * the whole point.
     */
    func testAChoiceIsRememberedPerMachineEvenWhenItMatchesTheDefault() {
        let store = book()
        store.setFolded(false, host: "wsl", category: .other)
        store.setFolded(true, host: "wsl", category: .web)

        XCTAssertFalse(store.isFolded(host: "wsl", category: .other))
        XCTAssertTrue(store.isFolded(host: "wsl", category: .web))
        // Another machine is untouched.
        XCTAssertTrue(store.isFolded(host: "mac", category: .other))

        store.setFolded(true, host: "wsl", category: .other)
        XCTAssertTrue(book().isFolded(host: "wsl", category: .other))
    }
}
