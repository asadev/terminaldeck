import XCTest
@testable import TerminalDeckBackend
import TerminalDeckNativeCore

final class BackendRemoteServeHostPortTailnetServingTests: XCTestCase {
    private typealias F = BackendRemoteServeHostPortTailnetFixture
    private func service(_ runner: F.Runner) -> BackendRemoteServeTailscale {
        .init(tailnet: .init(runner: runner, environment: [:], loginPath: { "/usr/bin" }))
    }
    func testNonAnsweringChildReceivesFifteenSecondBoundAndReturnsTimeout() async {
        let clock = F.Clock(), runner = F.Runner(mode: .timeout, clock: clock), serving = service(runner)
        let result = await serving.serveOn(httpsPort: 8443, localPort: 8443)
        XCTAssertEqual(result["ok"], .bool(false)); XCTAssertEqual(result["message"], .string("Tailscale did not answer within 15 seconds, so the direct tailnet address is not available."))
        let commands = await runner.snapshot().filter { $0.args.contains("--bg") }, killed = await runner.kills()
        XCTAssertEqual(commands.count, 1); XCTAssertEqual(commands[0].timeout, 15_000); XCTAssertGreaterThan(killed, 0); XCTAssertEqual(clock.now(), 15_000)
    }
    func testOffUsesTenSecondDeadlineBecauseStopAwaitsIt() async {
        let runner = F.Runner(), serving = service(runner)
        await serving.serveOff(httpsPort: 8443)
        let commands = await runner.snapshot().filter { $0.args.first == "serve" }
        XCTAssertEqual(commands.count, 1); XCTAssertEqual(commands[0].args, ["serve", "--https=8443", "off"]); XCTAssertEqual(commands[0].timeout, 10_000)
    }
    func testPrintedRefusalStopsWaitingImmediatelyAndCarriesExactEnableLink() async {
        let clock = F.Clock(), runner = F.Runner(mode: .promptStdout, clock: clock), serving = service(runner)
        let result = await serving.serveOn(httpsPort: 8443, localPort: 8443)
        XCTAssertLessThan(clock.now(), 1000); XCTAssertEqual(result["ok"], .bool(false))
        XCTAssertEqual(result["message"], .string("Serve is switched off for this tailnet, so Tailscale will not put a proxy in front of the app. Turn it on at https://login.tailscale.com/f/serve?node=nL3GN8Ypuc11CNTRL, then try again."))
        XCTAssertFalse(result["message"].string!.contains("did not answer"))
        let killed = await runner.kills(); XCTAssertGreaterThan(killed, 0)
    }
    func testAdminEnableURLCannotBeMistakenForProxyAddress() async {
        let runner = F.Runner(mode: .promptStdout), serving = service(runner)
        let result = await serving.serveOn(httpsPort: 8443, localPort: 8443)
        XCTAssertEqual(result["ok"], .bool(false)); XCTAssertNil(result["url"].string)
    }
    func testRefusalOnStderrUsesSameImmediateAnswer() async {
        let clock = F.Clock(), runner = F.Runner(mode: .promptStderr, clock: clock), serving = service(runner)
        let result = await serving.serveOn(httpsPort: 8443, localPort: 8443)
        XCTAssertEqual(result["ok"], .bool(false)); XCTAssertTrue(result["message"].string!.lowercased().contains("serve is switched off")); XCTAssertEqual(clock.now(), 0)
    }
    func testWorkingProxyReturnsPrintedURLAndClearsPortBeforeClaimingIt() async {
        let runner = F.Runner(), serving = service(runner)
        let result = await serving.serveOn(httpsPort: 8443, localPort: 8443)
        XCTAssertEqual(result["ok"], .bool(true)); XCTAssertEqual(result["url"], .string("https://desktop.tailnet.ts.net:8443/"))
        let commands = await runner.snapshot().filter { $0.args.first == "serve" }
        XCTAssertEqual(commands.map(\.args), [["serve", "--https=8443", "off"], ["serve", "--bg", "--https=8443", "http://127.0.0.1:8443"]])
    }
}
