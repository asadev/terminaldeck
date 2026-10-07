import XCTest
import Foundation
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

/// Complete credential desk expectations through a fake listener bind. No
/// socket, curl/Git process, clock sleep or live account is used by these ports.
final class BackendRemoteServeCredentialPortTests: XCTestCase {
    private static let request = "protocol=https\nhost=github.com\npath=asadev/terminaldeck.git\n\n"
    private func temporary() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("BackendRemoteServeCredentialPort-" + UUID().uuidString) }
    private func headers(_ key: String, host: String = "127.0.0.1:4321") -> [String: String] {
        ["host": host, BackendRemoteServeCredentials.credentialHeader: key, BackendRemoteServeCredentials.pidHeader: "4242"]
    }
    private func text(_ response: BackendRemoteServeCredentialHTTP.Response) -> String { String(decoding: response.body, as: UTF8.self) }
    func testParserAndAncestryMissingCases() {
        let noPath = BackendRemoteServeCredentialParser.parse("protocol=https\nhost=github.com\n\n")
        XCTAssertEqual(noPath?.protocolName, "https"); XCTAssertNil(noPath?.repo)
        let full = BackendRemoteServeCredentialParser.parse(Self.request)
        XCTAssertEqual(full?.repo, "asadev/terminaldeck")
        XCTAssertNil(BackendRemoteServeCredentialParser.gitSubcommand("/usr/libexec/git-core/git-remote-https origin https://github.com/o/r"))
        XCTAssertNil(BackendRemoteServeCredentialParser.gitSubcommand("node /Users/x/push.js"))
        XCTAssertEqual(BackendRemoteServeCredentialParser.gitSubcommand("git --no-pager push"), "push")
        XCTAssertEqual(BackendRemoteServeCredentialParser.classifyOperation(["git-remote-https origin https://x", "/usr/bin/git fetch origin"]), "read")
        XCTAssertEqual(BackendRemoteServeCredentialParser.classifyOperation(["git clone https://github.com/o/r"]), "read")
        XCTAssertEqual(BackendRemoteServeCredentialParser.classifyOperation(["/bin/zsh -l", "Some.app/Contents/MacOS/Some"]), "write")
        XCTAssertEqual(BackendRemoteServeCredentialParser.ancestry(BackendRemoteServeCredentialParser.parsePSTable("1 0 init\n5 1 git"), pid: 99999), [])
    }
    func testHostAnswersEachRepositoryWithoutDeviceRoundTrip() async throws {
        let dir = temporary(); defer { try? FileManager.default.removeItem(at: dir) }
        let calls = HostCalls()
        let desk = BackendRemoteServeCredentials(directory: dir, hostCredential: { await calls.read() }, bind: { _ in 4321 })
        await desk.serve(ownDevice: { _ in true })
        let grant = try await desk.openGuestSession(deviceID: "device-1")
        let first = await desk.handleHTTP(method: "POST", path: "/credential", headers: headers(grant.key), body: Data(Self.request.utf8))
        let second = await desk.request(key: grant.key, text: "protocol=https\nhost=github.com\npath=asadev/mookhayo.git\n\n")
        XCTAssertEqual(text(first), "username=asadev\npassword=ghp_host\n")
        XCTAssertEqual(second, "username=asadev\npassword=ghp_host\n")
        let count = await calls.count; XCTAssertEqual(count, 2)
        await desk.stop()
    }
    func testMalformedRequestRefusesBeforeReadingToken() async throws {
        let dir = temporary(); defer { try? FileManager.default.removeItem(at: dir) }
        let calls = HostCalls()
        let desk = BackendRemoteServeCredentials(directory: dir, hostCredential: { await calls.read() }, bind: { _ in 4321 })
        let grant = try await desk.openGuestSession(deviceID: "device-1")
        let result = await desk.request(key: grant.key, text: "this is not the git credential protocol\n\n")
        XCTAssertEqual(result, "!That request did not say which host it needed a login for.")
        XCTAssertFalse(result.contains("ghp_host")); let count = await calls.count; XCTAssertEqual(count, 0)
        await desk.stop()
    }
    func testGuestRefusalOwnDeviceAndAbsentLegacyRule() async throws {
        let dir = temporary(); defer { try? FileManager.default.removeItem(at: dir) }
        let calls = HostCalls()
        let desk = BackendRemoteServeCredentials(directory: dir, hostCredential: { await calls.read() }, bind: { _ in 4321 })
        await desk.serve(ownDevice: { $0 == "device-1" })
        let mine = try await desk.openGuestSession(deviceID: "device-1"), guest = try await desk.openGuestSession(deviceID: "device-2")
        let denied = await desk.request(key: guest.key, text: Self.request)
        XCTAssertEqual(denied, "!This machine's GitHub account is not shared with other devices. Push with a token scoped to that one repository.")
        let before = await calls.count; XCTAssertEqual(before, 0)
        let allowed = await desk.request(key: mine.key, text: Self.request)
        XCTAssertTrue(allowed.contains("password=ghp_host"))
        await desk.serve(ownDevice: nil)
        let legacy = await desk.request(key: guest.key, text: Self.request)
        XCTAssertTrue(legacy.contains("password=ghp_host"))
        await desk.stop()
    }
    func testNoHostAccountAndInvalidHostAnswerAreExact() async throws {
        let dir = temporary(); defer { try? FileManager.default.removeItem(at: dir) }
        let desk = BackendRemoteServeCredentials(directory: dir, bind: { _ in 4321 })
        let grant = try await desk.openGuestSession(deviceID: "device-1")
        let noAccount = await desk.request(key: grant.key, text: Self.request)
        XCTAssertEqual(noAccount, "!No GitHub account is connected on this machine. Connect one on the host, then try again.")
        await desk.stop()
        let badDir = temporary(); defer { try? FileManager.default.removeItem(at: badDir) }
        let bad = BackendRemoteServeCredentials(directory: badDir, hostCredential: { .init(username: "octocat", password: "x\nquit=1") }, bind: { _ in 4321 })
        let badGrant = try await bad.openGuestSession(deviceID: "device-1")
        let unusable = await bad.request(key: badGrant.key, text: Self.request)
        XCTAssertEqual(unusable, "!That answer was not usable.")
        await bad.stop()
    }
    func testUnknownEmptyKeyReboundHostMethodAndRoute() async throws {
        let dir = temporary(); defer { try? FileManager.default.removeItem(at: dir) }
        let desk = BackendRemoteServeCredentials(directory: dir, bind: { _ in 4321 })
        let grant = try await desk.openGuestSession(deviceID: "device-1")
        for key in ["", String(repeating: "f", count: 64)] {
            let result = await desk.handleHTTP(method: "POST", path: "/credential", headers: headers(key), body: Data(Self.request.utf8))
            XCTAssertEqual(result.status, 403); XCTAssertEqual(text(result), "not for you\n")
        }
        let rebound = await desk.headerFailure(method: "POST", path: "/credential", headers: headers(grant.key, host: "attacker.example"))
        XCTAssertEqual(rebound?.status, 403)
        let method = await desk.headerFailure(method: "GET", path: "/credential", headers: headers(grant.key))
        XCTAssertEqual(method?.status, 405)
        let route = await desk.headerFailure(method: "POST", path: "/else", headers: headers(grant.key))
        XCTAssertEqual(route?.status, 404)
        for host in ["127.0.0.1:4321", "localhost:4321", "[::1]:4321"] {
            let accepted = await desk.headerFailure(method: "POST", path: "/credential?x=1", headers: headers(grant.key, host: host))
            XCTAssertNil(accepted)
        }
        await desk.stop()
    }
    func testExitedRevokedAndNeverStartedGrantsStopAnswering() async throws {
        let dir = temporary(); defer { try? FileManager.default.removeItem(at: dir) }
        let desk = BackendRemoteServeCredentials(directory: dir, bind: { _ in 4321 })
        let exited = try await desk.openGuestSession(deviceID: "device-1")
        await desk.started(key: exited.key, sessionID: "session-9"); await desk.sessionEnded("session-9")
        let exitedResponse = await desk.headerFailure(method: "POST", path: "/credential", headers: headers(exited.key)); XCTAssertEqual(exitedResponse?.status, 403)
        let revoked = try await desk.openGuestSession(deviceID: "device-2"); await desk.forget("device-2")
        let revokedResponse = await desk.headerFailure(method: "POST", path: "/credential", headers: headers(revoked.key)); XCTAssertEqual(revokedResponse?.status, 403)
        let unstarted = try await desk.openGuestSession(deviceID: "device-3"); await desk.close(key: unstarted.key)
        let abandoned = await desk.headerFailure(method: "POST", path: "/credential", headers: headers(unstarted.key)); XCTAssertEqual(abandoned?.status, 403)
        await desk.stop()
    }
    func testEnvironmentKeysDirectoriesAndSecretFreeHelper() async throws {
        let dir = temporary(); defer { try? FileManager.default.removeItem(at: dir) }
        let desk = BackendRemoteServeCredentials(directory: dir, bind: { _ in 4321 })
        let first = try await desk.openGuestSession(deviceID: "device-1"), again = try await desk.openGuestSession(deviceID: "device-1"), other = try await desk.openGuestSession(deviceID: "device-2")
        XCTAssertNotEqual(first.key, again.key)
        XCTAssertNotEqual(first.environment.set["GIT_CONFIG_GLOBAL"], other.environment.set["GIT_CONFIG_GLOBAL"])
        XCTAssertTrue(first.environment.set["GIT_CONFIG_GLOBAL"]!.contains(BackendRemoteServeCredentials.deviceKey("device-1")))
        let script = try String(contentsOfFile: first.environment.set["GIT_ASKPASS"]!, encoding: .utf8)
        XCTAssertFalse(script.contains(first.key)); XCTAssertFalse(script.contains(first.environment.set["TERMINALDECK_CREDENTIAL_URL"]!))
        XCTAssertTrue(script.contains("TERMINALDECK_CREDENTIAL_URL")); XCTAssertTrue(script.contains("TERMINALDECK_CREDENTIAL_KEY"))
        await desk.stop()
    }
    func testLegacyFramesAndConnectionLossDoNotChangeHostGrant() async throws {
        XCTAssertTrue(BackendRemoteProtocol.capabilities.contains("credential"))
        XCTAssertTrue(BackendRemoteProtocol.capabilities.contains("github"))
        let dir = temporary(); defer { try? FileManager.default.removeItem(at: dir) }
        let desk = BackendRemoteServeCredentials(directory: dir, hostCredential: { .init(username: "asadev", password: "ghp_host") }, bind: { _ in 4321 })
        let grant = try await desk.openGuestSession(deviceID: "device-1")
        for tag in ["credential.ack", "credential.answer", "credential.deny"] {
            let frame = BackendRemoteClientMessage(.object([.init("t", .string(tag)), .init("id", .string("old-request")), .init("username", .string("ignored")), .init("password", .string("ignored"))]))
            await desk.handle(deviceID: "device-1", message: frame)
        }
        await desk.connectionClosed("device-1")
        let answer = await desk.request(key: grant.key, text: Self.request)
        XCTAssertEqual(answer, "username=asadev\npassword=ghp_host\n")
        await desk.stop()
    }
    private actor HostCalls {
        var count = 0
        func read() -> BackendRemoteServeCredentials.Login { count += 1; return .init(username: "asadev", password: "ghp_host") }
    }
}
