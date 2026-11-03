import XCTest
import Foundation
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

final class BackendRemoteServeTailnetTests: XCTestCase {
    private func running() -> NativeRPCValue {
        .object([.init("BackendState", .string("Running")), .init("Self", .object([
            .init("DNSName", .string("mac.tail.test.")), .init("HostName", .string("mac")),
            .init("TailscaleIPs", .array([.string("192.168.1.5"), .string("100.64.0.1"), .string("fd7a:115c:a1e0::1")]))])),
            .init("CurrentTailnet", .object([.init("Name", .string("owner")), .init("MagicDNSEnabled", .bool(true))])), .init("CertDomains", .null)])
    }
    func testOnlyTailnetAddressesAreAcceptedAndStoppedMapIsNotReady() {
        for value in ["100.64.0.", "100.064.0.1", "100.64.0.0x1", "100.64.0.1e2", "100.128.0.1", "100.64.0.1\n"] { XCTAssertFalse(BackendRemoteServeTailnet.isAddress(value), value) }
        XCTAssertTrue(BackendRemoteServeTailnet.isAddress("100.127.255.254"))
        XCTAssertTrue(BackendRemoteServeTailnet.isAddress6("FD7A:115C:A1E0:0:0:0:FD39:6B77"))
        for value in ["::1", "fd7a:115c:a1e1::1", "2a01:4f8::1", "fd7a:115c:a1e0::1%en0"] { XCTAssertFalse(BackendRemoteServeTailnet.isAddress6(value)) }
        let ready = BackendRemoteServeTailnet.parseStatus(running(), binary: "/bin/tailscale")
        XCTAssertEqual(ready["address"].string, "100.64.0.1"); XCTAssertEqual(ready["dnsName"].string, "mac.tail.test")
        XCTAssertEqual(ready["certsAvailable"], .bool(false))
        XCTAssertEqual(BackendRemoteServeTailnet.directPlan(ready)["url"].string, "https://mac.tail.test:8443/")
        XCTAssertEqual(BackendRemoteServeTailnet.directPlan(ready.setting("magicDns", .bool(false)))["ok"], .bool(false))
        let stopped = BackendRemoteServeTailnet.parseStatus(running().setting("BackendState", .string("Stopped")), binary: "")
        XCTAssertEqual(stopped["ready"], .bool(false)); XCTAssertEqual(stopped["address"], .missing)
    }
    func testWarningsAreSeparateAndMalformedStatusRedactsLoginCapability() throws {
        let json = String(decoding: try running().encodedJSON(), as: UTF8.self)
        XCTAssertEqual(BackendRemoteServeTailnet.status(.init(stdout: json, stderr: "version warning"))["ready"], .bool(true))
        let broken = #"{"AuthURL":"https://login.tailscale.com/a/private-token","Self": {"#
        let result = BackendRemoteServeTailnet.status(.init(stdout: broken, code: 1))
        XCTAssertEqual(result["state"].string, "unreadable")
        XCTAssertFalse(result["detail"].string!.contains("private-token"))
        XCTAssertTrue(result["detail"].string!.contains("[redacted]"))
        XCTAssertEqual(BackendRemoteServeTailnet.status(.init(code: -1, spawnError: "ENOENT"))["state"].string, "not-installed")
    }
    func testServeEnablePromptWinsOverHTTPSURLAndWarningsDoNotBecomeURL() {
        let prompt = "Serve is not enabled on your tailnet.\nhttps://login.tailscale.com/f/serve?node=example\n"
        let disabled = BackendRemoteServeTailscale.readOutput(stdout: prompt, stderr: "")
        XCTAssertEqual(disabled?["ok"], .bool(false))
        XCTAssertTrue(disabled?["message"].string?.contains("Turn it on at https://login.tailscale.com/f/serve") == true)
        XCTAssertNil(BackendRemoteServeTailscale.readOutput(stdout: "", stderr: "warning https://example.com"))
        XCTAssertEqual(BackendRemoteServeTailscale.readOutput(stdout: "https://mac.tail.test:8443/\n", stderr: "")?["url"].string, "https://mac.tail.test:8443/")
        let result = BackendRemoteServeTailnet.certificateResult(dns: "mac.tail.test", certPath: "/tmp/c", keyPath: "/tmp/k", result: .init(stderr: "HTTPS must be enabled", code: 1))
        XCTAssertEqual(result["reason"].string, "https-disabled")
    }
    func testConcurrentStatusUsesSingleCallAndForceRefreshes() async {
        let runner = CountRunner(json: String(decoding: try! running().encodedJSON(), as: UTF8.self))
        let tailnet = BackendRemoteServeTailnet(runner: runner, environment: [:], loginPath: { "/usr/bin" })
        async let first = tailnet.status(); async let second = tailnet.status()
        let values = await (first, second); XCTAssertEqual(values.0, values.1)
        _ = await tailnet.status()
        let count = await runner.calls; XCTAssertEqual(count, 1)
        _ = await tailnet.status(force: true)
        let forced = await runner.calls; XCTAssertEqual(forced, 2)
    }
    private actor CountRunner: BackendRemoteServeCommandExecuting {
        let json: String; var calls = 0
        init(json: String) { self.json = json }
        func run(executable: String, arguments: [String], environment: [String: String], timeoutMilliseconds: Int, maximumBytes: Int, stopWhen: (@Sendable (String, String) -> Bool)?) async -> BackendRemoteServeCommandResult {
            if arguments == ["tailscale"] { return .init(stdout: "/usr/bin/true\n") }
            calls += 1; await Task.yield(); return .init(stdout: json, stderr: "version warning")
        }
    }
}
