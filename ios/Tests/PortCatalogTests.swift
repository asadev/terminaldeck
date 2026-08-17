/**
 * How a wall of ports becomes a few groups, and the ways that could be
 * confidently wrong.
 *
 * Every case here is a rule from `PortCatalog`'s table, pinned so that the next
 * person to "improve" the grouping has to argue with a failing test rather than
 * with a comment. Three of them are the ones that matter:
 *
 *  - **One row per server.** A dev server this phone started arrives twice —
 *    once from `dev.state` as a folder, once from `ports` as `node` on a number
 *    — and a screen that draws both is a screen where starting something makes
 *    two rows appear. The join is the proven port and nothing else.
 *  - **Nothing is inferred from a port number.** There is no table saying 3000
 *    is Next and 5173 is Vite, because a port is a number a person chose.
 *    `dev-ports.ts` refuses to make that guess and this must not make it on the
 *    desktop's behalf.
 *  - **The app's own socket is not a dev server.** On a direct endpoint the
 *    desktop's listener is a `node` process on a port this phone is *connected
 *    to*, and without the check it lands under "Web servers" — a row that opens
 *    the thing that drew it.
 */

import XCTest
@testable import TerminalDeck

final class PortCatalogTests: XCTestCase {

    // MARK: - Fixtures

    private func port(_ number: Int, _ process: String, guessed: Bool = false) -> LocalPort {
        LocalPort(port: number, process: process, guessed: guessed)
    }

    private func dev(_ folder: String,
                     _ status: DevServerStatus,
                     port: Int? = nil,
                     sessionId: String? = nil) -> DevServerReport {
        DevServerReport(folder: folder, status: status, script: "dev", command: "npm run dev",
                        sessionId: sessionId, port: port,
                        url: port.map { "http://localhost:\($0)" }, note: nil, message: nil)
    }

    private func rows(_ sections: [LocalhostSection], _ category: PortCategory) -> [LocalhostRow] {
        sections.first { $0.category == category }?.rows ?? []
    }

    // MARK: - Grouping

    /**
     * The list he was actually looking at, sorted.
     *
     * Three `wslrelay` and one `AgentService` are named processes that are not
     * web runtimes, so they are noise; the `node` is not. The point of the case
     * is the *shape* of the answer — the interesting one is on its own in an
     * open group and the four he could not tell apart are in a closed one —
     * rather than any single row.
     */
    func testTheRecordedListSplitsTheOneServerFromTheFourThatAreNoise() {
        let sections = PortCatalog.sections(
            ports: [port(2019, "wslrelay"), port(2222, "wslrelay"), port(3100, "wslrelay"),
                    port(6666, "AgentService"), port(5173, "node")],
            devServers: [])

        XCTAssertEqual(sections.map(\.category), [.web, .other])
        XCTAssertEqual(rows(sections, .web).compactMap(\.port), [5173])
        XCTAssertEqual(rows(sections, .other).compactMap(\.port), [2019, 2222, 3100, 6666])
        XCTAssertFalse(PortCategory.web.foldedByDefault)
        XCTAssertTrue(PortCategory.other.foldedByDefault)
    }

    /// A port nothing could name is its own answer, not a service with a dull
    /// name. `guessed` is the desktop saying "it answers and I could not say
    /// who", which is a different thing to be told.
    func testAPortWithNoOwnerIsUnidentifiedRatherThanOther() {
        let sections = PortCatalog.sections(ports: [port(8931, "unknown", guessed: true)],
                                            devServers: [])
        XCTAssertEqual(sections.map(\.category), [.unnamed])
    }

    /**
     * No port number means anything on its own.
     *
     * 3000 held by something that is not a known runtime is not a web server,
     * and 61234 held by `node` is. The number is never consulted — except
     * against `appPorts`, which is a fact about *this connection* rather than a
     * convention.
     */
    func testTheNumberNeverDecidesTheGroup() {
        let sections = PortCatalog.sections(
            ports: [port(3000, "rustdesk"), port(61234, "node")],
            devServers: [])
        XCTAssertEqual(rows(sections, .other).compactMap(\.port), [3000])
        XCTAssertEqual(rows(sections, .web).compactMap(\.port), [61234])
    }

    /// The runtime list is matched as a prefix, because the same runtime is
    /// spelled several ways by the two scanners — `python` on a Mac and
    /// `python3` on the next machine along.
    func testTheRuntimeNameIsMatchedAsAPrefixAndCaseInsensitively() {
        XCTAssertTrue(PortCatalog.isWebRuntime("python3"))
        XCTAssertTrue(PortCatalog.isWebRuntime("Python"))
        XCTAssertTrue(PortCatalog.isWebRuntime("node"))
        XCTAssertFalse(PortCatalog.isWebRuntime("wslrelay"))
        XCTAssertFalse(PortCatalog.isWebRuntime("AgentService"))
        // Not a substring match: a process merely containing "node" is not a
        // runtime, and "nodemon" being one is a coincidence rather than a rule.
        XCTAssertFalse(PortCatalog.isWebRuntime("supernode"))
    }

    // MARK: - The desktop's own ports

    /**
     * The socket this phone is talking on is not offered as somebody's dev
     * server.
     *
     * The process is `node` — a headless desktop is a Node process — so without
     * the endpoint check this row is indistinguishable from a Vite server and
     * lands in the group that is open by default.
     */
    func testThePortThisPhoneIsConnectedOnIsTheAppsOwn() {
        let endpoint = DeckEndpoint.direct(url: URL(string: "http://10.0.0.4:8443")!)
        let sections = PortCatalog.sections(ports: [port(8443, "node"), port(5173, "node")],
                                            devServers: [],
                                            appPorts: PortCatalog.appPorts(for: endpoint))
        XCTAssertEqual(rows(sections, .app).compactMap(\.port), [8443])
        XCTAssertEqual(rows(sections, .web).compactMap(\.port), [5173])
    }

    /// A URL with no port is on its scheme's default, which is a fact about the
    /// URL. A relay endpoint knows nothing — the desktop dials out to meet this
    /// phone, so which local port it bound never crosses the wire — and the
    /// honest answer there is to claim no ports at all rather than to fall back
    /// to the product's default number, which would be a guess.
    func testAppPortsComeFromTheEndpointAndOnlyWhenItKnows() {
        XCTAssertEqual(PortCatalog.appPorts(for: .direct(url: URL(string: "https://pc.local")!)), [443])
        XCTAssertEqual(PortCatalog.appPorts(for: .direct(url: URL(string: "http://pc.local")!)), [80])
        XCTAssertEqual(PortCatalog.appPorts(for: .relay(url: URL(string: "wss://relay.example")!,
                                                        hostId: "H", hostKey: Data())), [])
        XCTAssertEqual(PortCatalog.appPorts(for: nil), [])
    }

    /// Windows names the process after the executable, with `.exe` already taken
    /// off by `parseTasklist` — so the desktop half of this product appears
    /// under its own display name and is recognised by it.
    func testTheProductsOwnBinaryIsRecognisedByName() {
        XCTAssertTrue(PortCatalog.isOwnProcess(Brand.name))
        XCTAssertTrue(PortCatalog.isOwnProcess(Brand.name.replacingOccurrences(of: " ", with: "")))
        XCTAssertTrue(PortCatalog.isOwnProcess(Brand.id))
        XCTAssertFalse(PortCatalog.isOwnProcess("node"))

        let sections = PortCatalog.sections(ports: [port(52001, Brand.name)], devServers: [])
        XCTAssertEqual(sections.map(\.category), [.app])
    }

    // MARK: - Dev servers

    /**
     * A running dev server is one row, and it is the project's row.
     *
     * The port list and `dev.state` both describe it. Drawing both would put
     * `myproject` and `localhost:5173 node` on screen as two different things,
     * which is the duplication that makes a list stop being trustworthy.
     */
    func testAReadyDevServerSwallowsItsOwnPortRow() {
        let sections = PortCatalog.sections(
            ports: [port(5173, "node"), port(3000, "node")],
            devServers: [dev("/Users/a/shop", .ready, port: 5173, sessionId: "s1")])

        XCTAssertEqual(rows(sections, .devServer).count, 1)
        let merged = rows(sections, .devServer)[0]
        XCTAssertEqual(merged.dev?.folder, "/Users/a/shop")
        // The port row is not gone, it is *inside* the merged row — the address
        // and the process name are still what the row prints underneath.
        XCTAssertEqual(merged.entry?.port, 5173)
        // The other node server is untouched: only the proven port is claimed.
        XCTAssertEqual(rows(sections, .web).compactMap(\.port), [3000])
    }

    /**
     * A dev server that is not up still has a row, and it has no port.
     *
     * This is the whole reason the section is on this screen: the port you want
     * is missing *because the server is not running*, and the answer to that is
     * a Start button rather than an absence.
     */
    func testAProjectThatIsNotRunningIsARowWithNoPort() {
        let sections = PortCatalog.sections(ports: [], devServers: [dev("/Users/a/shop", .idle)])
        let row = rows(sections, .devServer).first
        XCTAssertEqual(row?.dev?.status, .idle)
        XCTAssertNil(row?.port)
        XCTAssertNil(row?.entry)
    }

    /**
     * Only `ready` claims a port.
     *
     * A `failed` report must never carry the address of the server that died —
     * the protocol calls that the one genuinely wrong thing a client of this
     * frame can display — so even a report that somehow arrived with a port on a
     * non-ready status must not swallow the row for whatever is on that port now.
     */
    func testOnlyAReadyReportClaimsAPort() {
        let sections = PortCatalog.sections(
            ports: [port(5173, "node")],
            devServers: [dev("/Users/a/shop", .failed, port: 5173, sessionId: "s1")])

        XCTAssertNil(rows(sections, .devServer).first?.entry)
        XCTAssertEqual(rows(sections, .web).compactMap(\.port), [5173])
    }

    /// `no-dev-script` means there is nothing to press and there never will be
    /// for that folder. `HostLink.devServerRows` already drops it; this drops it
    /// again, because the rule belongs to the protocol rather than to one caller.
    func testAFolderWithNoDevScriptIsNeverARow() {
        let sections = PortCatalog.sections(
            ports: [],
            devServers: [DevServerReport(folder: "/Users/a/plain", status: .noDevScript,
                                         script: nil, command: nil, sessionId: nil,
                                         port: nil, url: nil, note: nil, message: nil)])
        XCTAssertTrue(sections.isEmpty)
    }

    // MARK: - Naming

    /// Naming a port is the promotion. It leaves whatever pile it was derived
    /// into and goes to the top, which is the whole of "keep some in the list".
    func testANamedPortIsLiftedOutOfItsGroup() {
        let sections = PortCatalog.sections(
            ports: [port(6666, "AgentService"), port(2019, "wslrelay")],
            devServers: [],
            names: [6666: "Agent control panel"])

        XCTAssertEqual(sections.map(\.category), [.named, .other])
        XCTAssertEqual(rows(sections, .named).first?.name, "Agent control panel")
        XCTAssertEqual(rows(sections, .other).compactMap(\.port), [2019])
    }

    /// Including a dev server: the name is against the port, so a project whose
    /// server is up and whose port has been named is drawn under the name.
    func testAReadyDevServerOnANamedPortIsAlsoLifted() {
        let sections = PortCatalog.sections(
            ports: [port(5173, "node")],
            devServers: [dev("/Users/a/shop", .ready, port: 5173, sessionId: "s1")],
            names: [5173: "Storefront"])

        XCTAssertEqual(sections.map(\.category), [.named])
        XCTAssertEqual(rows(sections, .named).first?.name, "Storefront")
        XCTAssertEqual(rows(sections, .named).first?.dev?.folder, "/Users/a/shop")
    }

    /// A name for a port that is not listening names nothing. It stays in the
    /// book against the day that port comes back, and it does not conjure a row.
    func testANameForAPortThatIsNotThereDoesNotInventARow() {
        let sections = PortCatalog.sections(ports: [], devServers: [], names: [4321: "Old thing"])
        XCTAssertTrue(sections.isEmpty)
    }

    // MARK: - Start, stop, and the five states

    /**
     * What the trailing swipe offers, state by state.
     *
     * This is the whole "start / stop a server from the phone" contract written
     * down. It is a value rather than a branch inside a view body precisely so
     * that it can be read here — the alternative needs a paired phone, a machine
     * with a project on it, and a dev server that will fail on demand.
     */
    func testTheSecondActionForEachOfTheFiveStates() {
        func row(_ status: DevServerStatus, port: Int? = nil, sessionId: String? = nil) -> LocalhostRow {
            LocalhostRow(entry: nil, dev: dev("/Users/a/shop", status, port: port, sessionId: sessionId),
                         name: nil, category: .devServer)
        }

        XCTAssertEqual(PortCatalog.secondAction(for: row(.idle)),
                       .start(folder: "/Users/a/shop"))
        XCTAssertEqual(PortCatalog.secondAction(for: row(.starting, sessionId: "s1")),
                       .openSession(id: "s1"))
        XCTAssertEqual(PortCatalog.secondAction(for: row(.ready, port: 5173, sessionId: "s1")),
                       .openSession(id: "s1"))
        // A different word, and deliberately not `start`: the row leads to the
        // failure and this is the second press beside it.
        XCTAssertEqual(PortCatalog.secondAction(for: row(.failed)),
                       .retry(folder: "/Users/a/shop"))
        XCTAssertEqual(PortCatalog.secondAction(for: row(.noDevScript)), .none)
    }

    /// The protocol says `starting` and `ready` always carry a session. If one
    /// ever does not, the row draws no control rather than one that leads
    /// nowhere — a button whose only possible outcome is nothing happening reads
    /// as a broken app.
    func testARunningServerWithNoSessionOffersNothingRatherThanADeadButton() {
        let row = LocalhostRow(entry: nil, dev: dev("/Users/a/shop", .ready, port: 5173),
                               name: nil, category: .devServer)
        XCTAssertEqual(PortCatalog.secondAction(for: row), .none)
    }

    /**
     * A plain port gets the clipboard and not a Start.
     *
     * There is no verb on the wire that could start "whatever used to be on
     * 2019" and there cannot be one: a port is the *outcome* of a command in a
     * folder, and neither the command nor the folder is knowable from a number.
     * A Start button here could only ever be refused.
     */
    func testAPlainPortIsOfferedTheClipboardBecauseThereIsNothingToStart() {
        let row = LocalhostRow(entry: port(2019, "wslrelay"), dev: nil, name: nil, category: .other)
        XCTAssertEqual(PortCatalog.secondAction(for: row), .copyAddress(port: 2019))
    }

    // MARK: - Order

    /**
     * Sections come in one fixed order and empty ones are absent.
     *
     * A header over no rows is a promise the machine has not made, and a list
     * whose groups move about between refreshes is one people tap the wrong row
     * in.
     */
    func testSectionsAreOrderedAndEmptyOnesAreAbsent() {
        let sections = PortCatalog.sections(
            ports: [port(2019, "wslrelay"), port(9999, "unknown", guessed: true),
                    port(5173, "node"), port(8443, "node"), port(7000, "Postgres")],
            devServers: [dev("/Users/a/shop", .idle)],
            appPorts: [8443],
            names: [7000: "Database admin"])

        XCTAssertEqual(sections.map(\.category), [.named, .devServer, .web, .app, .other, .unnamed])
    }

    /// Rows keep the order the machine offered them in. The desktop ranks its
    /// ports most-likely-to-be-a-dev-server first and its folders
    /// most-relevant-first; re-sorting here would throw away the only ordering
    /// anybody has an opinion about.
    func testRowsKeepTheOrderTheMachineSentThemIn() {
        let sections = PortCatalog.sections(
            ports: [port(5174, "node"), port(5173, "bun"), port(4200, "deno")],
            devServers: [])
        XCTAssertEqual(rows(sections, .web).compactMap(\.port), [5174, 5173, 4200])
    }

    /// The row identity survives a dev server changing port, which is what stops
    /// a `List` re-animating every row each time the desktop answers. Vite takes
    /// 5174 when 5173 is busy and it is still the same project.
    func testADevServersRowKeepsItsIdentityWhenThePortChanges() {
        let before = PortCatalog.sections(ports: [], devServers: [dev("/Users/a/shop", .idle)])
        let after = PortCatalog.sections(ports: [port(5174, "node")],
                                         devServers: [dev("/Users/a/shop", .ready,
                                                          port: 5174, sessionId: "s1")])
        XCTAssertEqual(before.first?.rows.first?.id, after.first?.rows.first?.id)
    }
}
