import XCTest
import Foundation
import Darwin
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

final class BackendRemoteServeHostTests: XCTestCase {
    func testHelperRequestTerminatesAtBlankAndIgnoresFutureKeys() {
        let query = BackendRemoteServeCredentialParser.parse("protocol=https\r\nhost=github.com\r\npath=org/repo.git\r\ncapability[]=x\r\n\r\nhost=evil.example\n")
        XCTAssertEqual(query?.host, "github.com"); XCTAssertEqual(query?.repo, "org/repo")
        XCTAssertNil(BackendRemoteServeCredentialParser.parse("protocol=https\n\n"))
        XCTAssertNil(BackendRemoteServeCredentialParser.parse("host=" + String(repeating: "x", count: 254)))
        for path in ["../repo.git", "one/two/three.git", "only-one", "-owner/repo"] {
            XCTAssertNil(BackendRemoteServeCredentialParser.parse("host=github.com\npath=\(path)\n\n")?.repo)
        }
    }
    func testCredentialAnswerCannotInjectAdditionalDirectives() {
        XCTAssertEqual(BackendRemoteServeCredentialParser.format(username: "octocat", password: "value"), "username=octocat\npassword=value\n")
        for value in ["a\nb", "a\rb", "a\0b"] { XCTAssertNil(BackendRemoteServeCredentialParser.format(username: "x", password: value)) }
    }
    func testProcessClassificationAndCycles() {
        XCTAssertEqual(BackendRemoteServeCredentialParser.gitSubcommand("/usr/bin/git -C /Users/x/push-service fetch origin"), "fetch")
        XCTAssertEqual(BackendRemoteServeCredentialParser.gitSubcommand("git -c credential.helper=x push origin main"), "push")
        XCTAssertEqual(BackendRemoteServeCredentialParser.classifyOperation(["git push origin", "git fetch origin"]), "write")
        XCTAssertEqual(BackendRemoteServeCredentialParser.classifyOperation(["git fetch origin"]), "read")
        XCTAssertEqual(BackendRemoteServeCredentialParser.classifyOperation([]), "write")
        let table = BackendRemoteServeCredentialParser.parsePSTable("1 0 init\n5 1 git push\ncontinued text\n6 5 helper\n7 7 loop")
        XCTAssertEqual(BackendRemoteServeCredentialParser.ancestry(table, pid: 6), ["helper", "git push"])
        XCTAssertEqual(BackendRemoteServeCredentialParser.ancestry(table, pid: 7), ["loop"])
    }
    func testEnrollmentPortFallbacksAndSSHClassification() {
        XCTAssertEqual(BackendRemoteServeEnrollment.port(environment: [:]), 22)
        XCTAssertEqual(BackendRemoteServeEnrollment.port(environment: ["SSH_CONNECTION": "100.64.0.1 111 100.64.0.2 2222"]), 2222)
        XCTAssertEqual(BackendRemoteServeEnrollment.port(environment: ["TERMINALDECK_SSHD_PORT": "2200", "SSH_CONNECTION": "a b c 2222"]), 2200)
        for raw in ["", "no", "0", "65536", "22.5"] { XCTAssertEqual(BackendRemoteServeEnrollment.port(environment: ["TERMINALDECK_SSHD_PORT": raw]), 22) }
        XCTAssertEqual(BackendRemoteServeSSHVerifier.classify(.init(level: "client-authentication")), .auth)
        XCTAssertEqual(BackendRemoteServeSSHVerifier.classify(.init(code: "ETIMEDOUT")), .timeout)
        XCTAssertEqual(BackendRemoteServeSSHVerifier.classify(.init(message: "Cannot parse privateKey")), .badKey)
        XCTAssertEqual(BackendRemoteServeSSHVerifier.classify(.init(code: "ECONNREFUSED")), .noSSHD)
        let reasons = [BackendRemoteServeEnrollment.refused, BackendRemoteServeEnrollment.badKey, BackendRemoteServeEnrollment.slow,
                      BackendRemoteServeEnrollment.busy, BackendRemoteServeEnrollment.noRoom, BackendRemoteServeEnrollment.notSaved,
                      BackendRemoteServeEnrollment.noSSHD(2222)]
        XCTAssertEqual(Set(reasons).count, reasons.count)
        XCTAssertTrue(BackendRemoteServeEnrollment.noSSHD(2222).contains("TERMINALDECK_SSHD_PORT"))
    }
    func testAbsentSSHTransportReturnsUnavailable() async {
        do { _ = try await BackendRemoteServeSSHVerifier(transport: nil).verify(username: "user", secret: "secret", method: "password", port: 22); XCTFail("Missing verifier must refuse") }
        catch let error as NativeRPCError { XCTAssertEqual(error.code, "unavailable"); XCTAssertFalse(error.message.contains("secret")) }
        catch { XCTFail("Unexpected error type") }
    }
    func testSSHPasswordOffersKeyboardInteractiveAndTimeoutCancelsProbe() async throws {
        let successful = Probe(silent: false)
        let answer = try await BackendRemoteServeSSHVerifier(transport: successful).verify(username: "user", secret: "test-password", method: "password", port: 2222)
        XCTAssertNil(answer)
        let called = await successful.configuration
        XCTAssertEqual(called?.port, 2222); XCTAssertEqual(called?.keyboard, true)
        let silent = Probe(silent: true)
        let timeout = try await BackendRemoteServeSSHVerifier(transport: silent).verify(username: "user", secret: "test-password", method: "password", port: 22, timeoutMilliseconds: 2)
        XCTAssertEqual(timeout, .timeout)
        for _ in 0..<20 { await Task.yield() }
        let cancelled = await silent.cancelled; XCTAssertTrue(cancelled)
    }
    private actor Probe: BackendRemoteServeSSHTransport {
        let silent: Bool
        var configuration: (port: Int, keyboard: Bool)?
        var cancelled = false
        init(silent: Bool) { self.silent = silent }
        func authenticateLoopback(port: Int, username: String, secret: String, method: String, keyboardInteractive: Bool, timeoutMilliseconds: Int) async throws {
            configuration = (port, keyboardInteractive)
            if silent {
                do { try await Task.sleep(for: .seconds(3600)) }
                catch { cancelled = true; throw error }
            }
        }
    }
    func testHostProjectionDropsRepositoriesAndRetainsFlowReason() throws {
        let state: NativeRPCValue = .object([.init("connected", .bool(false)), .init("identity", .null), .init("source", .null),
            .init("appConfigured", .bool(true)), .init("repo", .string("private/repo")), .init("failure", .null),
            .init("pending", .object([.init("userCode", .string("AB-CD")), .init("verificationUri", .string("https://github.com/login/device")), .init("expiresAt", .number(123)), .init("installUrl", .string("drop"))]))])
        let wire = BackendRemoteServeGitHub.wire(state, flowFailure: "You cancelled the GitHub sign-in.")
        XCTAssertEqual(wire["repo"], .missing); XCTAssertEqual(wire["pending"]["installUrl"], .missing)
        XCTAssertEqual(wire["failure"].string, "You cancelled the GitHub sign-in.")
        let connected = BackendRemoteServeGitHub.wire(state.setting("connected", .bool(true)), flowFailure: "old")
        XCTAssertEqual(connected["failure"], .null)
        XCTAssertEqual(BackendRemoteServeLifecycle.wire(.object([]), note: "Restarting.")["running"], .bool(true))
        XCTAssertEqual(try BackendRemoteServeHostRefusals.guest("github.read")?.value["code"].string, "unauthorized")
        XCTAssertEqual(try BackendRemoteServeHostRefusals.guest("browser.windows")?.value["code"].string, "unavailable")
        XCTAssertEqual(try BackendRemoteServeHostRefusals.missing("credential.answer")?.value["message"].string, "Nothing here asked this device for a login.")
    }
    func testSecretAtomicReplaceAndLeftoverSymlink() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("auth.json")
        try BackendRemoteServeSecretFile.write(directory: directory, file: file, contents: Data("first".utf8))
        let target = directory.appendingPathComponent("untouched")
        try Data("sentinel".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(atPath: file.path + ".\(getpid()).tmp", withDestinationPath: target.path)
        try BackendRemoteServeSecretFile.write(directory: directory, file: file, contents: Data("second".utf8))
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "second")
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "sentinel")
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path + ".\(getpid()).tmp"))
    }
}
