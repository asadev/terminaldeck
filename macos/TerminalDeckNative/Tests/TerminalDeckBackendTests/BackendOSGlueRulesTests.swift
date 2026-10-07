import Foundation
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

final class BackendOSGlueRulesTests: XCTestCase {
    func testBridgeRefusesRebindingCrossSiteAndWrongToken() {
        let headers = ["host": "127.0.0.1:9123", "origin": "http://127.0.0.1:9123", "sec-fetch-site": "same-origin"]
        XCTAssertTrue(BackendOSNativeBridge.originAllowed(headers: headers, port: 9123))
        for changed in [["host": "evil.example:9123"], ["host": "localhost:9123"], ["host": "127.0.0.1:9123", "origin": "null"], ["host": "127.0.0.1:9123", "sec-fetch-site": "cross-site"]] {
            XCTAssertFalse(BackendOSNativeBridge.originAllowed(headers: changed, port: 9123))
        }
        XCTAssertTrue(BackendOSNativeBridge.authorized(path: "/?t=abc", headers: [:], token: "abc"))
        XCTAssertTrue(BackendOSNativeBridge.authorized(path: "/assets/a.js", headers: ["cookie": "other=1; td_native=abc"], token: "abc"))
        XCTAssertTrue(BackendOSNativeBridge.authorized(path: "/", headers: ["x-td-token": "abc"], token: "abc"))
        XCTAssertFalse(BackendOSNativeBridge.authorized(path: "/?t=wrong", headers: [:], token: "abc"))
        XCTAssertFalse(BackendOSNativeBridge.authorized(path: "/assets/a.js?t=abc", headers: [:], token: "abc"))
    }
    func testBridgeAssetPathCannotEscapeAndShimIsFirst() {
        let root = URL(fileURLWithPath: "/renderer")
        XCTAssertEqual(BackendOSNativeBridge.staticPath(root: root, pathname: "/assets/a.js")?.path, "/renderer/assets/a.js")
        for path in ["/../secret", "/assets/..%2f..%2fsecret", "/assets/%2E%2E%5Csecret", "/%00/x", "/%E0%A4%A", "/a\\b"] {
            XCTAssertNil(BackendOSNativeBridge.staticPath(root: root, pathname: path), path)
        }
        XCTAssertEqual(BackendOSNativeBridge.injectShim("<HEAD lang=\"x\"><script src=\"a.js\"></script></HEAD>"), "<HEAD lang=\"x\">\n    <script src=\"/__td/shim.js\"></script><script src=\"a.js\"></script></HEAD>")
        XCTAssertNil(BackendOSNativeBridge.injectShim("<html><body></body></html>"))
    }
    func testBridgeCallRulesAndByteEnvelope() throws {
        let good = try BackendOSNativeBridge.parseCall(Data(#"{"channel":"echo:it","args":[{"$bytes":"aGk="}]}"#.utf8))
        XCTAssertEqual(good.0, "echo:it"); XCTAssertEqual(good.1, [.bytes(Data("hi".utf8))])
        XCTAssertEqual(try BackendOSNativeBridge.parseCall(Data(#"{"channel":"a:b"}"#.utf8)).1, [])
        for body in ["not JSON", "[]", #"{"channel":"error"}"#, #"{"channel":"-x"}"#, #"{"channel":"a:b","args":"x"}"#, #"{"channel":"ELECTRON_x"}"#] {
            XCTAssertThrowsError(try BackendOSNativeBridge.parseCall(Data(body.utf8)), body)
        }
        XCTAssertEqual(BackendOSNativeBridge.failedLine("port\nwas taken\r\n"), "TD_NATIVE_FAILED port was taken")
        XCTAssertEqual(BackendOSNativeBridge.failedLine(""), "TD_NATIVE_FAILED unknown reason")
    }
    func testInheritedRunRemovedButPersonalEnvironmentKept() {
        let source = ["HOME": "/Users/me", "CLAUDECODE": "1", "CLAUDE_CONFIG_DIR": "/other/profile", "TERMINALDECK_ACCOUNT_TICKET": "secret",
                      "ANTHROPIC_BASE_URL": "https://example.invalid", "PATH": "/other/shim:/other/account-vault-shim:/ours/shim:/tools/shim:/usr/bin"]
        let answer = BackendOSInheritedEnvironment.scrub(source, ownUserData: "/ours", isAppDataDirectory: { ["/other", "/ours"].contains($0) })
        XCTAssertNil(answer.environment["CLAUDECODE"]); XCTAssertNil(answer.environment["CLAUDE_CONFIG_DIR"]); XCTAssertNil(answer.environment["TERMINALDECK_ACCOUNT_TICKET"])
        XCTAssertEqual(answer.environment["PATH"], "/ours/shim:/tools/shim:/usr/bin")
        XCTAssertEqual(answer.environment["ANTHROPIC_BASE_URL"], "https://example.invalid")
        XCTAssertFalse(answer.removed.joined().contains("secret"))
        let personal = BackendOSInheritedEnvironment.scrub(["CLAUDE_CONFIG_DIR": "/personal"], ownUserData: "/ours")
        XCTAssertEqual(personal.environment["CLAUDE_CONFIG_DIR"], "/personal")
    }
    func testFirstClientRestoresOnlyOnce() async throws {
        actor Count { var count = 0; func bump() { count += 1 }; func value() -> Int { count } }
        let count = Count(), hydration = BackendOSHydration()
        for _ in 0..<3 { await hydration.firstClient { await count.bump() } }
        let value = await count.value(); XCTAssertEqual(value, 1)
    }
    func testMacPlatformNamesOnlyAndRealTailscaleLocations() {
        let spec = BackendOSPlatform.loginEnvironmentNamesSpec(environment: ["SHELL": "/bin/bash"])
        XCTAssertEqual(spec.command, "/bin/bash"); XCTAssertEqual(spec.arguments.first, "-lic")
        XCTAssertTrue(spec.arguments[1].contains("=.*/")); XCTAssertFalse(spec.arguments[1].contains("for "))
        XCTAssertEqual(BackendOSPlatform.parseEnvironmentNames("PATH\r\nHOME\n-----BEGIN CERTIFICATE-----\n9LIVES\n"), ["PATH", "HOME"])
        XCTAssertEqual(BackendOSPlatform.machineName("office.LOCAL"), "office")
        XCTAssertEqual(BackendOSPlatform.machineName(" office "), "office")
        XCTAssertEqual(BackendOSPlatform.tailscaleCandidates, ["/opt/homebrew/bin/tailscale", "/usr/local/bin/tailscale", "/Applications/Tailscale.app/Contents/MacOS/Tailscale", "/usr/bin/tailscale"])
        XCTAssertTrue(BackendOSPlatform.profileIsolation["isolated"].bool == true)
        XCTAssertTrue(BackendOSPlatform.profileIsolation["note"].string?.contains("does not sign it out") == true)
    }
}

@MainActor
final class BackendOSTeardownRulesTests: XCTestCase {
    func testNewestKeyWinsAndLateRegistrationRuns() {
        let registry = BackendOSTeardowns(); var old = 0, new = 0, late = 0
        registry.on(owner: "window", key: "cost") { old += 1 }
        registry.on(owner: "window", key: "cost") { new += 1 }
        XCTAssertEqual(registry.pending(owner: "window"), ["cost"])
        registry.destroy(owner: "window"); registry.destroy(owner: "window")
        registry.on(owner: "window", key: "cost") { late += 1 }
        XCTAssertEqual(old, 0); XCTAssertEqual(new, 1); XCTAssertEqual(late, 1)
    }
    func testThrowingCallbackDoesNotPreventOtherResourcesClosing() {
        var reports = 0, closed = 0
        let registry = BackendOSTeardowns { _ in reports += 1 }
        registry.on(owner: "window", key: "bad") { throw NativeRPCError(code: "test", message: "failed") }
        registry.on(owner: "window", key: "good") { closed += 1 }
        registry.destroy(owner: "window"); XCTAssertEqual(reports, 1); XCTAssertEqual(closed, 1)
        XCTAssertEqual(registry.pending(owner: "window"), [])
    }
}
