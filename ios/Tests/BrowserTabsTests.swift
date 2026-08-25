/**
 * The tab list, and the one rule in it that can be got wrong.
 *
 * A tunnel binds the machine's own port number on this phone's loopback and a
 * second one on the same number cannot exist — see `PortTunnel.bind`. So tabs on
 * one port share a tunnel, and the question every one of these tests is really
 * asking is *when does the socket close*: closing one of two tabs on port 3000
 * must not take the page in the other one down with it, and closing the last one
 * must not leave a listener on this phone and a socket on somebody's machine
 * with nothing looking at either.
 *
 * `BrowserTabs` answers it by deriving the set of ports its tabs need after
 * every change rather than by keeping a count, and these prove the derivation
 * against a machine that is a dictionary — no socket, no host, no simulator.
 */

import XCTest
@testable import TerminalDeck

@MainActor
final class BrowserTabsTests: XCTestCase {

    /// A wire that carries everything and answers nothing. The tunnels in these
    /// tests never leave `.opening`, which is all this file needs of them: what
    /// is being proven is which of them exist.
    private final class TabWire: TunnelWire {
        @discardableResult
        func send(_ message: ClientMessage) -> Bool { true }
    }

    /// One machine, as `BrowserTabs` sees it. Records every open and every close
    /// it is asked for, which is how "asked once for two tabs" is stated.
    private final class FakeMachine: TunnelSource {
        var hostId: String
        var refuses = false
        private(set) var opened: [Int] = []
        private(set) var closed: [Int] = []

        private let wire = TabWire()
        private var tunnels: [Int: PortTunnel] = [:]

        init(hostId: String) { self.hostId = hostId }

        /// Idempotent per port, the same as `HostLink.openLocalhost`: a port it
        /// already holds a live tunnel for hands that one back.
        func openLocalhost(port: Int) -> PortTunnel? {
            opened.append(port)
            guard !refuses else { return nil }
            if let existing = tunnels[port], !existing.hasEnded { return existing }
            // An hour, so nothing in this file races the twenty-second deadline
            // a real tunnel arms. The seam exists for exactly this.
            let tunnel = PortTunnel(port: port, wire: wire, openTimeout: 3_600)
            tunnels[port] = tunnel
            tunnel.start()
            return tunnel
        }

        func closeLocalhost(port: Int) {
            closed.append(port)
            tunnels[port]?.stop()
            tunnels.removeValue(forKey: port)
        }
    }

    // MARK: - The shared tunnel

    func testTwoTabsOnOnePortAreOneTunnel() {
        let machine = FakeMachine(hostId: "mac")
        let tabs = BrowserTabs()

        guard let root = tabs.open(port: 3000, machine: machine),
              let admin = tabs.open(port: 3000, path: "/admin", machine: machine) else {
            return XCTFail("both pages should have opened")
        }

        XCTAssertNotEqual(root.id, admin.id, "two pages, two tabs")
        XCTAssertEqual(tabs.count(onPort: 3000, of: machine), 2)
        XCTAssertEqual(tabs.openTunnels, 1, "one port, one tunnel")
        XCTAssertEqual(machine.opened, [3000], "the machine is asked once, not twice")
        XCTAssertTrue(tabs.tunnel(for: root) === tabs.tunnel(for: admin))
    }

    func testClosingOneOfTwoLeavesTheOtherPageUp() {
        let machine = FakeMachine(hostId: "mac")
        let tabs = BrowserTabs()
        guard let root = tabs.open(port: 3000, machine: machine),
              let admin = tabs.open(port: 3000, path: "/admin", machine: machine) else {
            return XCTFail("both pages should have opened")
        }

        tabs.close(root, machine: machine)

        XCTAssertEqual(tabs.count(onPort: 3000, of: machine), 1)
        XCTAssertEqual(tabs.openTunnels, 1)
        XCTAssertTrue(machine.closed.isEmpty, "the port is still wanted")
        XCTAssertNotNil(tabs.tunnel(for: admin), "the surviving tab still has its page")
    }

    func testClosingTheLastTabOnAPortClosesItsTunnel() {
        let machine = FakeMachine(hostId: "mac")
        let tabs = BrowserTabs()
        guard let root = tabs.open(port: 3000, machine: machine),
              let admin = tabs.open(port: 3000, path: "/admin", machine: machine) else {
            return XCTFail("both pages should have opened")
        }

        tabs.close(root, machine: machine)
        tabs.close(admin, machine: machine)

        XCTAssertEqual(tabs.openTunnels, 0)
        XCTAssertEqual(machine.closed, [3000], "closed once, when the last tab went")
        XCTAssertTrue(tabs.tabs(on: machine).isEmpty)
    }

    func testDifferentPortsAreDifferentTunnels() {
        let machine = FakeMachine(hostId: "mac")
        let tabs = BrowserTabs()
        guard let dev = tabs.open(port: 3000, machine: machine),
              let api = tabs.open(port: 8080, machine: machine) else {
            return XCTFail("both pages should have opened")
        }

        XCTAssertEqual(tabs.openTunnels, 2)
        XCTAssertEqual(machine.opened, [3000, 8080])
        XCTAssertFalse(tabs.tunnel(for: dev) === tabs.tunnel(for: api))

        tabs.close(api, machine: machine)
        XCTAssertEqual(machine.closed, [8080], "only the port that lost its last tab")
        XCTAssertNotNil(tabs.tunnel(for: dev))
    }

    func testClosingEveryTabClosesEveryTunnel() {
        let machine = FakeMachine(hostId: "mac")
        let tabs = BrowserTabs()
        tabs.open(port: 3000, machine: machine)
        tabs.open(port: 3000, path: "/admin", machine: machine)
        tabs.open(port: 8080, machine: machine)

        tabs.closeAll(machine: machine)

        XCTAssertEqual(tabs.openTunnels, 0)
        XCTAssertEqual(machine.closed.sorted(), [3000, 8080])
    }

    // MARK: - One page, one tab

    func testTheSamePageTwiceIsTheSameTab() {
        let machine = FakeMachine(hostId: "mac")
        let tabs = BrowserTabs()

        let first = tabs.open(port: 3000, machine: machine)
        let again = tabs.open(port: 3000, path: "/", machine: machine)

        XCTAssertEqual(first?.id, again?.id, "five taps on a port row are one tab")
        XCTAssertEqual(tabs.tabs(on: machine).count, 1)
    }

    // MARK: - A tab follows its page

    func testATabFollowsItsPageButNeverLeavesItsPort() {
        let machine = FakeMachine(hostId: "mac")
        let tabs = BrowserTabs()
        guard let tab = tabs.open(port: 3000, machine: machine) else {
            return XCTFail("the page should have opened")
        }

        tabs.note(address: "http://127.0.0.1:3000/admin?tab=orders", for: tab.id, machine: machine)
        XCTAssertEqual(tabs.tab(tab.id)?.path, "/admin?tab=orders")

        // A port this tab's tunnel is not bound to. Ignored rather than followed.
        tabs.note(address: "http://127.0.0.1:5173/", for: tab.id, machine: machine)
        XCTAssertEqual(tabs.tab(tab.id)?.path, "/admin?tab=orders")
        XCTAssertEqual(tabs.tab(tab.id)?.port, 3000)
    }

    func testTheLabelIsTheAddressUntilThePageSaysOtherwise() {
        let machine = FakeMachine(hostId: "mac")
        let tabs = BrowserTabs()
        guard let tab = tabs.open(port: 3000, machine: machine) else {
            return XCTFail("the page should have opened")
        }

        XCTAssertEqual(tab.label, "localhost:3000")

        // WebKit blanks the title on every navigation before the new document
        // sets its own. Taken literally, the strip would flicker.
        tabs.retitle("   ", for: tab.id, machine: machine)
        XCTAssertEqual(tabs.tab(tab.id)?.label, "localhost:3000")

        tabs.retitle("Orders · Admin", for: tab.id, machine: machine)
        XCTAssertEqual(tabs.tab(tab.id)?.label, "Orders · Admin")
    }

    // MARK: - Two machines, one port number

    func testSwitchingMachinesParksTabsRatherThanLosingThem() {
        let mac = FakeMachine(hostId: "mac")
        let pc = FakeMachine(hostId: "pc")
        let tabs = BrowserTabs()

        guard let onMac = tabs.open(port: 3000, machine: mac) else {
            return XCTFail("the Mac's page should have opened")
        }
        XCTAssertEqual(tabs.openTunnels, 1)

        // The PC's own 3000 is a different server that wants the same socket on
        // this phone. Only one of them can have it.
        guard let onPC = tabs.open(port: 3000, machine: pc) else {
            return XCTFail("the PC's page should have opened")
        }
        XCTAssertEqual(tabs.openTunnels, 1, "one machine's tunnels at a time")
        XCTAssertNotNil(tabs.tunnel(for: onPC))
        XCTAssertNil(tabs.tunnel(for: onMac), "parked, not closed")
        XCTAssertEqual(tabs.tabs(on: mac).count, 1, "the Mac's tab is still there")

        // And switching back re-binds it.
        XCTAssertNotNil(tabs.resume(onMac, machine: mac))
        XCTAssertNotNil(tabs.tunnel(for: onMac))
        XCTAssertNil(tabs.tunnel(for: onPC))
        XCTAssertEqual(mac.opened, [3000, 3000])
    }

    func testOneMachinesTabsAreNeverTheOthers() {
        let mac = FakeMachine(hostId: "mac")
        let pc = FakeMachine(hostId: "pc")
        let tabs = BrowserTabs()

        tabs.open(port: 3000, machine: mac)
        tabs.open(port: 5173, machine: pc)

        XCTAssertEqual(tabs.tabs(on: mac).map(\.port), [3000])
        XCTAssertEqual(tabs.tabs(on: pc).map(\.port), [5173])
    }

    // MARK: - Refusals

    func testATunnelThatEndedIsOpenedAgainRatherThanHandedOut() {
        let machine = FakeMachine(hostId: "mac")
        let tabs = BrowserTabs()
        guard let tab = tabs.open(port: 3000, machine: machine) else {
            return XCTFail("the page should have opened")
        }

        // The machine closed it, or the socket dropped. Either way the tab is
        // still a tab and the page is still somewhere to go back to.
        tabs.tunnel(for: tab)?.stop()
        XCTAssertNil(tabs.tunnel(for: tab))

        XCTAssertNotNil(tabs.resume(tab, machine: machine))
        XCTAssertNotNil(tabs.tunnel(for: tab))
        XCTAssertEqual(machine.opened, [3000, 3000])
    }

    func testNoTabIsMadeForAPageTheMachineRefused() {
        let machine = FakeMachine(hostId: "mac")
        machine.refuses = true
        let tabs = BrowserTabs()

        XCTAssertNil(tabs.open(port: 3000, machine: machine))
        XCTAssertTrue(tabs.tabs(on: machine).isEmpty, "a tab whose page can never load is a dead row")
        XCTAssertEqual(tabs.openTunnels, 0)
        // The machine wrote its own sentence into `lastError`; this one stays
        // quiet rather than saying the same thing twice.
        XCTAssertNil(tabs.notice)
    }

    func testTheCapIsARefusalAndNotAnEviction() {
        let machine = FakeMachine(hostId: "mac")
        let tabs = BrowserTabs()
        for index in 0..<BrowserTabs.capacity {
            XCTAssertNotNil(tabs.open(port: 3000, path: "/\(String(index))", machine: machine))
        }

        XCTAssertNil(tabs.open(port: 3000, path: "/one-too-many", machine: machine))
        XCTAssertNotNil(tabs.notice)
        XCTAssertEqual(tabs.tabs(on: machine).count, BrowserTabs.capacity,
                       "nobody's page is thrown away to make room")
    }

    func testAnAbsurdPathIsRefusedRatherThanCut() {
        let machine = FakeMachine(hostId: "mac")
        let tabs = BrowserTabs()
        let long = "/" + String(repeating: "a", count: BrowserHistory.maxPathLength + 1)

        XCTAssertNil(tabs.open(port: 3000, path: long, machine: machine))
        XCTAssertNotNil(tabs.notice)
        XCTAssertTrue(tabs.tabs(on: machine).isEmpty)
    }
}
