import XCTest
import Foundation
@testable import TerminalDeckBackend
import TerminalDeckNativeCore

final class BackendRemoteServeHostPortTailnetStatusTests: XCTestCase {
    private typealias F = BackendRemoteServeHostPortTailnetFixture
    func testExactReadyProjectionUsesThisNodeAndStripsTrailingDNSDot() throws {
        let status = BackendRemoteServeTailnet.status(try F.ran(F.raw()), binary: F.binary)
        XCTAssertEqual(status, .object([.init("ready", .bool(true)), .init("address", .string("100.86.107.119")), .init("address6", .string("fd7a:115c:a1e0::fd39:6b77")),
            .init("dnsName", .string("deck-mac.taild0abcd.ts.net")), .init("hostName", .string("deck-mac")), .init("tailnetName", .string("owner@example.com")),
            .init("magicDnsSuffix", .string("taild0abcd.ts.net")), .init("magicDns", .bool(true)), .init("certsAvailable", .bool(false)), .init("binary", .string(F.binary))]))
        XCTAssertFalse(status["dnsName"].string!.hasSuffix(".")); XCTAssertFalse(status.compact.contains("taile59277"))
        XCTAssertEqual(BackendRemoteServeTailnet.parseStatus(try F.raw(), binary: F.binary)["hostName"], .string("deck-mac"))
    }
    func testIPv4SelectionIgnoresIPv6AndLANAddressesInAnyPosition() throws {
        let raw = try F.raw(), node = raw["Self"]
        let v6First = raw.setting("Self", node.setting("TailscaleIPs", .array([.string("fd7a:115c:a1e0::fd39:6b77"), .string("100.86.107.119")])))
        let lanFirst = raw.setting("Self", node.setting("TailscaleIPs", .array([.string("192.168.1.5"), .string("100.86.107.119")])))
        XCTAssertEqual(BackendRemoteServeTailnet.parseStatus(v6First, binary: F.binary)["address"], .string("100.86.107.119"))
        XCTAssertEqual(BackendRemoteServeTailnet.parseStatus(lanFirst, binary: F.binary)["address"], .string("100.86.107.119"))
    }
    func testIPv4AndIPv6StrictParsersRejectLookalikesAndPublicRanges() {
        for ip in ["100.86.107.119", "100.64.0.1", "100.127.255.254"] { XCTAssertTrue(BackendRemoteServeTailnet.isAddress(ip), ip) }
        for ip in ["192.168.1.5", "100.128.0.1", "100.63.255.255", "10.0.0.1", "100.64.0.", "100.64.0.0x1", "100.64.0.1e2", "100.64.0. 1", "100.64.0.1\n", "100.064.0.1", ""] { XCTAssertFalse(BackendRemoteServeTailnet.isAddress(ip), ip) }
        for ip in ["fd7a:115c:a1e0::fd39:6b77", "FD7A:115C:A1E0:0:0:0:FD39:6B77"] { XCTAssertTrue(BackendRemoteServeTailnet.isAddress6(ip), ip) }
        for ip in ["2a01:4f8:c17:beef::1", "fd7a:115c:a1e1::1", "::1", "fd00::1", "not-an-address"] { XCTAssertFalse(BackendRemoteServeTailnet.isAddress6(ip), ip) }
    }
    func testPublicIPv6IsWithheldWhileTailnetIPv4RemainsServeable() throws {
        let raw = try F.raw(), node = raw["Self"]
        let changed = raw.setting("Self", node.setting("TailscaleIPs", .array([.string("100.86.107.119"), .string("2a01:4f8:c17:beef::1")])))
            .setting("TailscaleIPs", .array([.string("100.86.107.119"), .string("2a01:4f8:c17:beef::1")]))
        let status = BackendRemoteServeTailnet.parseStatus(changed, binary: F.binary)
        XCTAssertEqual(status["address"], .string("100.86.107.119")); XCTAssertEqual(status["address6"], .null); XCTAssertFalse(status.compact.contains("2a01"))
    }
    func testCertificateAvailabilityAndMagicDNSRespectTailnetSwitches() throws {
        let raw = try F.raw(), on = raw.setting("CertDomains", .array([.string(F.dns)]))
        XCTAssertEqual(BackendRemoteServeTailnet.parseStatus(raw, binary: F.binary)["certsAvailable"], .bool(false))
        XCTAssertEqual(BackendRemoteServeTailnet.parseStatus(on, binary: F.binary)["certsAvailable"], .bool(true))
        let noMagic = raw.setting("CurrentTailnet", raw["CurrentTailnet"].setting("MagicDNSEnabled", .bool(false)))
        let status = BackendRemoteServeTailnet.parseStatus(noMagic, binary: F.binary)
        XCTAssertEqual(status["ready"], .bool(true)); XCTAssertEqual(status["address"], .string("100.86.107.119")); XCTAssertEqual(status["dnsName"], .string("")); XCTAssertEqual(status["magicDns"], .bool(false))
    }
    func testBlockedStatesNeverExposeStaleAddressAndWarningIsNotTheCause() throws {
        let raw = try F.raw()
        for (backend, expected) in [("Stopped", "stopped"), ("NeedsLogin", "logged-out"), ("NeedsMachineAuth", "needs-approval"), ("Starting", "starting"), ("NoState", "starting")] {
            let result = BackendRemoteServeTailnet.status(try F.ran(raw.setting("BackendState", .string(backend))), binary: F.binary)
            XCTAssertEqual(result["ready"], .bool(false)); XCTAssertEqual(result["state"], .string(expected)); XCTAssertEqual(result["detail"], .missing); XCTAssertFalse(result.compact.contains("100.86.107.119"))
        }
        let unfamiliar = BackendRemoteServeTailnet.parseStatus(raw.setting("BackendState", .string("SomethingNew")), binary: F.binary)
        XCTAssertEqual(unfamiliar["state"], .string("unreadable")); XCTAssertEqual(unfamiliar["detail"], .string("Tailscale reported backend state SomethingNew."))
        let empty = raw.setting("Self", raw["Self"].setting("TailscaleIPs", .array([]))).setting("TailscaleIPs", .array([]))
        XCTAssertEqual(BackendRemoteServeTailnet.parseStatus(empty, binary: F.binary)["state"], .string("no-address"))
    }
    func testMissingDaemonBinaryMalformedJSONAndAuthURLRedaction() {
        let daemon = BackendRemoteServeTailnet.status(.init(stderr: "failed to connect to local Tailscale service; is Tailscale running?\n", code: 1))
        XCTAssertEqual(daemon["ready"], .bool(false)); XCTAssertEqual(daemon["state"], .string("not-running")); XCTAssertEqual(daemon["detail"], .string("failed to connect to local Tailscale service; is Tailscale running?"))
        XCTAssertEqual(BackendRemoteServeTailnet.status(.init(code: -1, spawnError: "ENOENT"))["state"], .string("not-installed"))
        XCTAssertEqual(BackendRemoteServeTailnet.status(.init(stdout: "tailscale: unknown flag --json", code: 1))["state"], .string("unreadable"))
        let truncated = "{\n  \"Version\": \"1.98.9\",\n  \"TUN\": true,\n  \"BackendState\": \"NeedsLogin\",\n  \"HaveNodeKey\": false,\n  \"AuthURL\": \"https://login.tailscale.com/a/6f21c9d4e8b7\",\n  \"TailscaleIPs\": null,\n  \"Self\": {"
        let status = BackendRemoteServeTailnet.status(.init(stdout: truncated, code: 1))
        XCTAssertEqual(status["ready"], .bool(false)); XCTAssertEqual(status["state"], .string("unreadable")); XCTAssertFalse(status.compact.contains("6f21c9d4e8b7")); XCTAssertTrue(status["detail"].string!.contains("[redacted]"))
    }
    func testAllEightReasonsAreActionableAndReachable() throws {
        let raw = try F.raw()
        let statuses = [
            BackendRemoteServeTailnet.status(.init(code: -1, spawnError: "ENOENT")),
            BackendRemoteServeTailnet.status(.init(stderr: "failed to connect", code: 1)),
            BackendRemoteServeTailnet.parseStatus(raw.setting("BackendState", .string("NeedsLogin")), binary: ""),
            BackendRemoteServeTailnet.parseStatus(raw.setting("BackendState", .string("Stopped")), binary: ""),
            BackendRemoteServeTailnet.parseStatus(raw.setting("BackendState", .string("NeedsMachineAuth")), binary: ""),
            BackendRemoteServeTailnet.parseStatus(raw.setting("BackendState", .string("Starting")), binary: ""),
            BackendRemoteServeTailnet.parseStatus(raw.setting("Self", raw["Self"].setting("TailscaleIPs", .array([]))), binary: ""),
            BackendRemoteServeTailnet.status(.init(stdout: "not json", code: 1))]
        XCTAssertEqual(Set(statuses.compactMap { $0["state"].string }), Set(BackendRemoteServeTailnet.reasons.keys))
        for (state, reason) in BackendRemoteServeTailnet.reasons {
            XCTAssertTrue(reason.hasSuffix("."), state); XCTAssertGreaterThan(reason.count, 60, state)
            XCTAssertNotNil(reason.range(of: #"install |open |click |approve |give it |run .|switch it off"#, options: [.regularExpression, .caseInsensitive]), state)
            XCTAssertNotNil(reason.range(of: #"menu bar|Applications|https://|terminal"#, options: .regularExpression), state)
        }
    }
    func testConcurrentStatusCacheForceAndThreeSecondExpiryUseFakeClock() async {
        let clock = F.Clock(), runner = F.Runner(clock: clock)
        let service = BackendRemoteServeTailnet(runner: runner, environment: [:], loginPath: { "/usr/bin" }, clock: { clock.now() })
        async let first = service.status(); async let second = service.status()
        let pair = await (first, second); XCTAssertEqual(pair.0, pair.1); XCTAssertEqual(pair.0["address"], .string("100.86.107.119"))
        _ = await service.status(); let cached = await runner.statuses(); XCTAssertEqual(cached, 1)
        _ = await service.status(force: true); let forced = await runner.statuses(); XCTAssertEqual(forced, 2)
        clock.advance(2999); _ = await service.status(); let beforeBoundary = await runner.statuses(); XCTAssertEqual(beforeBoundary, 2)
        clock.advance(1); _ = await service.status(); let expired = await runner.statuses(); XCTAssertEqual(expired, 3)
    }
}
