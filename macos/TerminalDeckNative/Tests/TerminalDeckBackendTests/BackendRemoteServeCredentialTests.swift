import XCTest
import Foundation
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

final class BackendRemoteServeCredentialTests: XCTestCase {
    private let body = Data("protocol=https\nhost=github.com\npath=org/repo.git\n\n".utf8)
    func testHostCredentialIsNeverGivenToGuestAndEndedGrantsStopWorking() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let desk = BackendRemoteServeCredentials(directory: directory, hostCredential: { .init(username: "host", password: "test-token") })
        await desk.serve(ownDevice: { $0 == "mine" })
        let mine = try await desk.openGuestSession(deviceID: "mine"), guest = try await desk.openGuestSession(deviceID: "guest")
        let headers = ["host": "127.0.0.1:123", BackendRemoteServeCredentials.credentialHeader: mine.key]
        let answer = await desk.handleHTTP(method: "POST", path: "/credential", headers: headers, body: body)
        XCTAssertEqual(answer.status, 200); XCTAssertEqual(String(decoding: answer.body, as: UTF8.self), "username=host\npassword=test-token\n")
        let refused = await desk.request(key: guest.key, text: String(decoding: body, as: UTF8.self))
        XCTAssertTrue(refused.contains("not shared with other devices")); XCTAssertFalse(refused.contains("test-token"))
        await desk.started(key: mine.key, sessionID: "session")
        await desk.sessionEnded("session")
        let ended = await desk.handleHTTP(method: "POST", path: "/credential", headers: headers, body: body)
        XCTAssertEqual(ended.status, 403)
        await desk.stop()
    }
    func testHTTPEndpointGuardsAndPerSessionEnvironmentSecrets() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let desk = BackendRemoteServeCredentials(directory: directory)
        let first = try await desk.openGuestSession(deviceID: "a"), second = try await desk.openGuestSession(deviceID: "a")
        XCTAssertNotEqual(first.key, second.key)
        let headers = ["host": "attacker.example", BackendRemoteServeCredentials.credentialHeader: first.key]
        let rebound = await desk.handleHTTP(method: "POST", path: "/credential", headers: headers, body: body)
        XCTAssertEqual(rebound.status, 403)
        let method = await desk.handleHTTP(method: "GET", path: "/credential", headers: [:], body: Data())
        XCTAssertEqual(method.status, 405)
        let badPath = await desk.handleHTTP(method: "POST", path: "/else", headers: [:], body: Data())
        XCTAssertEqual(badPath.status, 404)
        let valid = ["host": "localhost", BackendRemoteServeCredentials.credentialHeader: first.key]
        let tooBig = await desk.handleHTTP(method: "POST", path: "/credential", headers: valid, body: Data(repeating: 65, count: 16385))
        XCTAssertEqual(tooBig.status, 413)
        let noAccount = await desk.request(key: first.key, text: String(decoding: body, as: UTF8.self))
        XCTAssertTrue(noAccount.contains("No GitHub account is connected"))
        let helper = first.environment.set["GIT_ASKPASS"]!
        let script = try String(contentsOfFile: helper, encoding: .utf8)
        XCTAssertFalse(script.contains(first.key)); XCTAssertTrue(script.contains("TERMINALDECK_CREDENTIAL_KEY"))
        await desk.forget("a")
        let revoked = await desk.handleHTTP(method: "POST", path: "/credential", headers: valid, body: body)
        XCTAssertEqual(revoked.status, 403)
        await desk.stop()
    }
    func testRealLoopbackEndpointRefusesReboundHost() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let desk = BackendRemoteServeCredentials(directory: directory)
        let grant = try await desk.openGuestSession(deviceID: "a")
        let address = await desk.address()
        let url = try XCTUnwrap(address.flatMap(URL.init(string:)))
        var request = URLRequest(url: url); request.httpMethod = "POST"; request.httpBody = body
        request.setValue("attacker.example", forHTTPHeaderField: "Host")
        request.setValue(grant.key, forHTTPHeaderField: BackendRemoteServeCredentials.credentialHeader)
        let (_, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 403)
        await desk.stop()
    }
}
