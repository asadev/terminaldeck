import XCTest
import Foundation
@testable import TerminalDeckBackend
import TerminalDeckNativeCore

final class BackendRemoteServeHostPortTailnetCertificateTests: XCTestCase {
    private typealias F = BackendRemoteServeHostPortTailnetFixture
    private func result(_ command: BackendRemoteServeCommandResult) -> NativeRPCValue {
        BackendRemoteServeTailnet.certificateResult(dns: F.dns, certPath: "/tmp/certs/" + F.dns + ".crt", keyPath: "/tmp/certs/" + F.dns + ".key", result: command)
    }
    func testSuccessReturnsTheExactRequestedCertificateAndKeyPaths() {
        XCTAssertEqual(result(.init(stderr: F.warning)), .object([.init("ok", .bool(true)), .init("certPath", .string("/tmp/certs/deck-mac.taild0abcd.ts.net.crt")), .init("keyPath", .string("/tmp/certs/deck-mac.taild0abcd.ts.net.key"))]))
    }
    func testDisabledHTTPSUsesAdminToggleAndKeepsBothCLIWordingsReadable() {
        let modern = result(.init(stderr: F.warning + "500 Internal Server Error: your Tailscale account does not support getting TLS certs\n", code: 1))
        XCTAssertEqual(modern["ok"], .bool(false)); XCTAssertEqual(modern["reason"], .string("https-disabled"))
        XCTAssertTrue(modern["message"].string!.contains("https://login.tailscale.com/admin/dns")); XCTAssertTrue(modern["message"].string!.contains("HTTPS Certificates")); XCTAssertTrue(modern["message"].string!.contains(F.dns))
        XCTAssertTrue(modern["detail"].string!.contains("does not support getting TLS certs"))
        XCTAssertEqual(result(.init(stderr: "HTTPS must be enabled\n", code: 1))["reason"], .string("https-disabled"))
    }
    func testDaemonMissingBinaryTimeoutAndUnfamiliarFailuresStayDistinct() {
        XCTAssertEqual(result(.init(stderr: "failed to connect to local Tailscale service; is Tailscale running?\n", code: 1))["reason"], .string("not-running"))
        XCTAssertEqual(result(.init(code: -1, spawnError: "ENOENT"))["reason"], .string("not-installed"))
        let timeout = result(.init(code: -1)); XCTAssertEqual(timeout["ok"], .bool(false)); XCTAssertTrue(timeout["message"].string!.contains("within two minutes"))
        let unfamiliar = result(.init(stderr: "acme: rate limit exceeded for deck-mac.taild0abcd.ts.net\n", code: 1))
        XCTAssertEqual(unfamiliar["ok"], .bool(false)); XCTAssertEqual(unfamiliar["reason"], .string("failed")); XCTAssertTrue(unfamiliar["detail"].string!.contains("rate limit exceeded")); XCTAssertTrue(unfamiliar["message"].string!.contains("tailscale cert deck-mac.taild0abcd.ts.net"))
    }
    func testEveryCertificateFailureOffersAnActionableSentence() {
        let failures: [BackendRemoteServeCommandResult] = [.init(stderr: "does not support getting TLS certs", code: 1), .init(stderr: "failed to connect", code: 1), .init(code: -1), .init(stderr: "something else", code: 1), .init(code: -1, spawnError: "ENOENT")]
        for command in failures {
            let failed = result(command), message = failed["message"].string ?? ""
            XCTAssertEqual(failed["ok"], .bool(false)); XCTAssertTrue(message.hasSuffix(".")); XCTAssertGreaterThan(message.count, 60)
            XCTAssertNotNil(message.range(of: "try again|Install ", options: .regularExpression))
        }
    }
    func testUnsafeAndEmptyNamesAreRefusedBeforeFilesOrCommands() async {
        let root = F.root(); defer { try? FileManager.default.removeItem(at: root) }
        let runner = F.Runner(), service = BackendRemoteServeTailnet(runner: runner, environment: [:], loginPath: { "/usr/bin" })
        for name in ["../../../../tmp/evil", ""] {
            let failed = await service.ensureCertificate(dns: name, directory: root)
            XCTAssertEqual(failed["ok"], .bool(false)); XCTAssertEqual(failed["reason"], .string("bad-name")); XCTAssertTrue(failed["message"].string!.contains(".ts.net"))
        }
        let calls = await runner.snapshot(); XCTAssertEqual(calls.count, 0); XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }
    func testIssuanceUsesExactPathsMinValidityDeadlineAndProtectedDirectory() async throws {
        let root = F.root(); defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
        let runner = F.Runner(), service = BackendRemoteServeTailnet(runner: runner, environment: [:], loginPath: { "/usr/bin" })
        let answer = await service.ensureCertificate(dns: F.dns, directory: root)
        XCTAssertEqual(answer["ok"], .bool(true))
        let commands = await runner.snapshot().filter { $0.args.first == "cert" }
        XCTAssertEqual(commands.count, 1)
        XCTAssertEqual(commands[0].args, ["cert", "--min-validity", "168h", "--cert-file", root.appendingPathComponent(F.dns + ".crt").path, "--key-file", root.appendingPathComponent(F.dns + ".key").path, F.dns])
        XCTAssertEqual(commands[0].timeout, 120_000)
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: root.path)[.posixPermissions] as? NSNumber)?.intValue, 0o700)
    }
}
