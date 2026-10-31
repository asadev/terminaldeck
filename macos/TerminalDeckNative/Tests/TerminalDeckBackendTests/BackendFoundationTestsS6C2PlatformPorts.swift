import Foundation
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

/// platform/ports.test.ts. Skipped (Windows-only): netstat/tasklist parsing,
/// windowsOwners, portScanKind, NETSTAT/TASKLIST spelling, TCPv6 label.
/// The macOS lsof parsers are private (REQ S6-C2-1), so those cases sit behind
/// `S6_PORTS_SEAM`; remove the #if once the seam lands.
final class BackendFoundationTestsS6C2PlatformPorts: XCTestCase {
    // ports.ts own-ports claim set (BackendDevOwnPorts): out-of-range ports are refused.
    func testS6C2OwnPortsRefuseNonPorts() async {
        let own = BackendDevOwnPorts()
        await own.claim(0); await own.claim(70_000); await own.claim(8443); await own.claim(3000); await own.release(3000)
        let ports = await own.ports()
        XCTAssertEqual(ports, [8443])
    }

    // ports.test.ts:79 "four spellings" (dialer half): non-loopback hosts and out-of-range ports are never dialled.
    func testS6C2DialerRefusesNonLoopbackAndNonPorts() async {
        let a = await BackendDevDialer.dial(port: 0, host: "127.0.0.1", timeoutMilliseconds: 50)
        let b = await BackendDevDialer.dial(port: 70_000, host: "127.0.0.1", timeoutMilliseconds: 50)
        let c = await BackendDevDialer.dial(port: 3000, host: "192.168.1.9", timeoutMilliseconds: 50)
        XCTAssertFalse(a); XCTAssertFalse(b); XCTAssertFalse(c)
    }

    private typealias D = BackendDevPortDiscovery
    private static let lsofColumns = """
    COMMAND     PID  USER   FD   TYPE             DEVICE SIZE/OFF NODE NAME
    rapportd    713 apple   13u  IPv4 0xf2f295526132df51      0t0  TCP *:53397 (LISTEN)
    rapportd    713 apple   14u  IPv6  0x17db11441368b6b      0t0  TCP *:53397 (LISTEN)
    Macky       738 apple   29u  IPv4 0xb610e039e25a1641      0t0  TCP 192.168.101.223:60293 (LISTEN)
    Macky       738 apple   33u  IPv4 0x98d34c40d068135d      0t0  TCP 100.86.107.119:60296 (LISTEN)
    ControlCe   745 apple   11u  IPv4 0xbde47004fa22dcfb      0t0  TCP *:5000 (LISTEN)
    Python    15193 apple    3u  IPv4 0x824d8e1ea27154f5      0t0  TCP 127.0.0.1:8931 (LISTEN)
    node      92487 apple   16u  IPv6 0x7f3d3a1318a297ed      0t0  TCP [::1]:5199 (LISTEN)
    node      99468 apple   33u  IPv6 0x5aba6d7d820af189      0t0  TCP *:8081 (LISTEN)

    """
    private func tuples(_ owners: [D.Owner]) -> [String] { owners.map { "\($0.port)|\($0.name)|\($0.ipv6 ? 6 : 4)" } }

    // :79 :87 :93 splitHostPort + isLocallyReachable, observed through address().
    func testS6C2AddressSplitsHostFromPort() {
        XCTAssertEqual(D.address("*:53397")?.port, 53397)
        XCTAssertEqual(D.address("127.0.0.1:8931")?.port, 8931)
        XCTAssertEqual(D.address("0.0.0.0:135")?.port, 135)
        XCTAssertEqual(D.address("[::1]:5199")?.port, 5199)
        XCTAssertEqual(D.address("[::1]:5199")?.ipv6, true)
        XCTAssertNil(D.address("NAME")); XCTAssertNil(D.address("127.0.0.1:0")); XCTAssertNil(D.address("127.0.0.1:70000"))
        XCTAssertNil(D.address("192.168.101.223:60293")); XCTAssertNil(D.address("100.86.107.119:60296"))
    }
    // :104 :119 :123 which loopback a row is on
    func testS6C2WildcardFamilyAndUnrecognisedDefaultToV4() {
        XCTAssertEqual(D.address("*:1")?.ipv6, false)
        XCTAssertEqual(D.address("[::]:1")?.ipv6, true)
        XCTAssertEqual(D.address("0.0.0.0:1")?.ipv6, false)
        XCTAssertEqual(D.address(":1")?.ipv6, false)
    }
    // :132 :143 :151 :155 :162
    func testS6C2ColumnsFindEveryLocallyReachableListener() {
        let owners = D.parseColumns(Self.lsofColumns)
        XCTAssertEqual(tuples(owners), ["53397|rapportd|4", "53397|rapportd|6", "5000|ControlCe|4", "8931|Python|4", "5199|node|6", "8081|node|6"])
        XCTAssertEqual(owners.filter { $0.port == 53397 || $0.port == 8081 }.map { $0.ipv6 }, [false, true, true])
        XCTAssertFalse(owners.contains { $0.name == "COMMAND" })
        XCTAssertEqual(owners.filter { $0.port == 53397 }.count, 2)
        XCTAssertFalse(owners.contains { $0.port == 60293 || $0.port == 60296 })
    }

    private static let fieldOutput = ["p744", "R1", "crapportd", "f11", "tIPv4", "n*:62092", "f12", "tIPv6", "n*:62092",
        "p751", "R1", "cControlCenter", "f12", "tIPv4", "n*:5000", "p22310", "R22309", "cElectron", "f34", "tIPv4", "n127.0.0.1:9444",
        "p78868", "R1", "cTerminal Deck", "f38", "tIPv4", "n127.0.0.1:8443", ""].joined(separator: "\n")

    // :338 :348
    func testS6C2FieldsReadOneRowPerSocketAndKeepCommandWhole() {
        let rows = D.parseFields(Self.fieldOutput)
        XCTAssertEqual(rows.map { "\($0.port)|\($0.name)|\($0.pid ?? -9)|\($0.parentPID ?? -9)|\($0.ipv6 ? 6 : 4)" },
            ["62092|rapportd|744|1|4", "62092|rapportd|744|1|6", "5000|ControlCenter|751|1|4", "9444|Electron|22310|22309|4", "8443|Terminal Deck|78868|1|4"])
        let names = rows.map { $0.name }
        XCTAssertTrue(names.contains("Terminal Deck")); XCTAssertTrue(names.contains("ControlCenter"))
        XCTAssertFalse(names.contains("Terminal")); XCTAssertFalse(names.contains("ControlCe"))
    }
    // :359 TYPE does not leak to the next socket
    func testS6C2FieldsDoNotInheritPreviousFamily() {
        let rows = D.parseFields(["p1", "R0", "cthing", "f3", "tIPv6", "n[::1]:1", "f4", "n127.0.0.1:2", ""].joined(separator: "\n"))
        XCTAssertEqual(rows.map { "\($0.port)|\($0.ipv6 ? 6 : 4)" }, ["1|6", "2|4"])
    }
    // :370 each process starts clean (parent unknown)
    func testS6C2FieldsStartEachProcessClean() {
        let rows = D.parseFields(["p1", "R7", "cfirst", "f3", "tIPv4", "n127.0.0.1:1", "p2", "csecond", "f4", "tIPv4", "n127.0.0.1:2", ""].joined(separator: "\n"))
        XCTAssertEqual(rows[1].name, "second"); XCTAssertEqual(rows[1].pid, 2); XCTAssertNil(rows[1].parentPID)
    }
    // :376 :381
    func testS6C2FieldsDropUnreachableAndSurviveFileFirstStream() {
        XCTAssertTrue(D.parseFields(["p1", "R0", "cthing", "f3", "tIPv4", "n192.168.1.9:8080", ""].joined(separator: "\n")).isEmpty)
        XCTAssertTrue(D.parseFields(["f3", "tIPv4", "n127.0.0.1:1", ""].joined(separator: "\n")).isEmpty)
        XCTAssertTrue(D.parseFields("").isEmpty)
    }
}
