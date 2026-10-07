import Foundation
import XCTest
@testable import TerminalDeckBackend
import TerminalDeckNativeCore

@MainActor
final class BackendGitHubAuthenticatorTests: XCTestCase {
    private let token = "gho_fixtureOnly12345678901234567890"
    private func directory() throws -> URL { let path = FileManager.default.temporaryDirectory.appendingPathComponent("BackendGitHubTests-" + UUID().uuidString); try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true); return path }
    private func make(directory: URL, environment: [String: String] = [:], http: any BackendGitHubHTTPFetching, tools: any BackendGitHubToolRunning = BackendGitHubFixtureTools(), registration: BackendGitHubAppRegistration = .shipping, sleep: @escaping @Sendable (Double) async throws -> Void = { _ in }) throws -> BackendGitHubAuthenticator {
        try BackendGitHubAuthenticator(dataDirectory: directory, environment: environment, registration: registration, http: http, tools: tools, now: { 0 }, sleep: sleep,
            resolveRepo: { _ in BackendGitHubRules.ref(host: "github.com", owner: "a", name: "b", remote: "origin") },
            resolveBranch: { _ in BackendGitHubRules.object([("name", .string("main")), ("detached", .bool(false)), ("head", .null)]) })
    }
    private func workingHTTP(token: String) -> BackendGitHubFixtureHTTP {
        BackendGitHubFixtureHTTP { call in
            if call.url.hasSuffix("/login/device/code") { return .init(status: 200, body: #"{"device_code":"fixture-device","user_code":"E9EE-04C7","expires_in":899,"interval":5}"#) }
            if call.url.hasSuffix("/login/oauth/access_token") { return .init(status: 200, body: "{\"access_token\":\"\(token)\",\"expires_in\":28800}") }
            if call.url.hasSuffix("/user") { return .init(status: 200, body: #"{"login":"fixture-user","html_url":"https://github.com/fixture-user"}"#, headers: ["X-OAuth-Scopes": "repo, read:org"]) }
            if call.url.contains("/user/installations/") { return .init(status: 200, body: #"{"total_count":1,"repositories":[{"full_name":"a/b"}]}"#) }
            if call.url.contains("/user/installations?") { return .init(status: 200, body: #"{"installations":[{"id":42,"repository_selection":"selected"}]}"#) }
            return .init(status: 200, body: #"[{"full_name":"a/b"}]"#)
        }
    }
    func testNoRegistrationRefusesBeforeNetwork() async throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let http = BackendGitHubFixtureHTTP { _ in throw NativeRPCError(code: "unexpected", message: "No request allowed") }
        let auth = try make(directory: dir, http: http, registration: .absent)
        let failure = await auth.connect(), calls = await http.calls()
        XCTAssertEqual(failure["kind"].string, "auth-unavailable"); XCTAssertTrue(calls.isEmpty)
        let status = await auth.status(); XCTAssertFalse(status["connected"].bool ?? true); XCTAssertEqual(status["appConfigured"].bool, false)
    }
    func testDeviceFlowStoresSameSchemaWithRestrictedModeAndNoScope() async throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let http = workingHTTP(token: token), waits = BackendGitHubWaitRecorder()
        let auth = try make(directory: dir, http: http, sleep: { await waits.record($0) })
        let prompt = await auth.connect(); XCTAssertEqual(prompt["userCode"].string, "E9EE-04C7"); XCTAssertEqual(prompt["expiresAt"].number, 899_000)
        let status = await auth.awaitConnect(cwd: "/fixture/project")
        XCTAssertEqual(status["connected"].bool, true); XCTAssertEqual(status["source"].string, "device-flow"); XCTAssertEqual(status["credentialKind"].string, "github-app"); XCTAssertEqual(status["branch"]["name"].string, "main"); XCTAssertEqual(status["pending"], .null)
        let file = dir.appendingPathComponent("github/auth.json"), stored = try NativeRPCValue.parseJSON(Data(contentsOf: file))
        XCTAssertEqual(stored["clientKind"].string, "github-app"); XCTAssertEqual(stored["version"].number, 1); XCTAssertEqual(stored["expiresAt"].number, 28_800_000)
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        XCTAssertFalse(status.compact.contains(token)); XCTAssertEqual(status["scopes"], .array([.string("repo"), .string("read:org")]))
        let calls = await http.calls(), delays = await waits.values()
        XCTAssertEqual(calls.first?.body, "client_id=Iv23limkNV4N6mChRl60"); XCTAssertFalse(calls.first?.body?.contains("scope") ?? true); XCTAssertEqual(delays, [5000])
    }
    func testSlowDownIsMandatory() async throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let flowHTTP = BackendGitHubPollingFixture(token: token), waits = BackendGitHubWaitRecorder()
        let auth = try make(directory: dir, http: flowHTTP, sleep: { await waits.record($0) })
        _ = await auth.connect(); _ = await auth.awaitConnect()
        let delays = await waits.values(); XCTAssertEqual(delays, [5000, 10000, 10000])
    }
    func testEnvironmentWinsAndCannotBeDisconnected() async throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let auth = try make(directory: dir, environment: ["GH_TOKEN": token], http: workingHTTP(token: token), tools: BackendGitHubFixtureTools(token: "different-fixture"))
        let state = await auth.status(), toolToken = await auth.toolToken(), credential = await auth.gitCredential()
        XCTAssertEqual(state["source"].string, "environment"); XCTAssertEqual(state["credentialKind"].string, "oauth"); XCTAssertEqual(state["disconnect"], .null); XCTAssertNil(toolToken); XCTAssertEqual(credential?.password, token)
        let stripped = BackendGitHubAuthenticator.probeEnvironment(["GH_TOKEN": token, "GITHUB_TOKEN": token, "GH_ENTERPRISE_TOKEN": token, "GITHUB_ENTERPRISE_TOKEN": token, "HOME": "/fixture/home"])
        XCTAssertEqual(stripped["HOME"], "/fixture/home"); XCTAssertFalse(stripped.values.contains(token))
    }
    func testLegacyOAuthCredentialUsesAccountEndpoint() async throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        try BackendAccountFiles.writeAtomic(Data("{\"version\":1,\"token\":\"\(token)\",\"login\":\"fixture-user\"}".utf8), to: dir.appendingPathComponent("github/auth.json"))
        let http = workingHTTP(token: token), auth = try make(directory: dir, http: http)
        let state = await auth.status(), calls = await http.calls()
        XCTAssertEqual(state["credentialKind"].string, "oauth"); XCTAssertTrue(calls.contains { $0.url == BackendGitHubRepositories.accountURL("github.com") }); XCTAssertFalse(calls.contains { $0.url.contains("installations") })
    }
    func testExpiredCredentialRemovedBeforeNetworkAndFallsThrough() async throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        try BackendAccountFiles.writeAtomic(Data("{\"token\":\"\(token)\",\"expiresAt\":0,\"clientKind\":\"github-app\"}".utf8), to: dir.appendingPathComponent("github/auth.json"))
        let http = BackendGitHubFixtureHTTP { _ in throw NativeRPCError(code: "unexpected", message: "No request expected") }, auth = try make(directory: dir, http: http)
        let state = await auth.status(), calls = await http.calls()
        XCTAssertEqual(state["expiredCredentialRemoved"].bool, true); XCTAssertEqual(state["connected"].bool, false); XCTAssertTrue(calls.isEmpty); XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("github/auth.json").path))
    }
    func testAccessFailureDoesNotDisconnectAndIsNotCached() async throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let http = BackendGitHubFixtureHTTP { call in call.url.hasSuffix("/user") ? .init(status: 200, body: #"{"login":"fixture-user"}"#) : .init(status: 500, body: "failed") }
        let auth = try make(directory: dir, environment: ["GH_TOKEN": token], http: http)
        let first = await auth.status(), second = await auth.status(), calls = await http.calls()
        XCTAssertEqual(first["connected"].bool, true); XCTAssertEqual(second["access"]["kind"].string, "error"); XCTAssertEqual(calls.filter { $0.url.hasSuffix("/user") }.count, 2)
    }
    func testWorkingStateAndAccessAreCachedSeparately() async throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let http = workingHTTP(token: token), auth = try make(directory: dir, environment: ["GH_TOKEN": token], http: http)
        _ = await auth.status(); _ = await auth.status(); _ = await auth.status(refresh: true)
        let calls = await http.calls(); XCTAssertEqual(calls.filter { $0.url.hasSuffix("/user") }.count, 2); XCTAssertEqual(calls.filter { $0.url.contains("/user/repos?") }.count, 1)
    }
    func testFlowRefusalSurvivesStatus() async throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let http = BackendGitHubFixtureHTTP { call in call.url.hasSuffix("/device/code") ? .init(status: 200, body: #"{"device_code":"fixture","user_code":"A-B"}"#) : .init(status: 200, body: #"{"error":"access_denied"}"#) }
        let auth = try make(directory: dir, http: http)
        _ = await auth.connect(); let state = await auth.awaitConnect(); XCTAssertEqual(state["failure"]["kind"].string, "auth-declined")
        let status = await auth.status(foldFlowFailure: true); XCTAssertEqual(status["failure"]["kind"].string, "auth-declined")
    }
    func testCancelAndDisconnectLeaveNoStoredCredential() async throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let sleeper = BackendGitHubParitySleeper()
        let cancelled = try make(directory: dir, http: workingHTTP(token: token), sleep: { try await sleeper.sleep($0) })
        _ = await cancelled.connect(); await sleeper.waitForCount(1); let cancelledState = await cancelled.cancelConnect()
        XCTAssertEqual(cancelledState["pending"], .null); XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("github/auth.json").path))
        let auth = try make(directory: dir, http: workingHTTP(token: token))
        _ = await auth.connect(); _ = await auth.awaitConnect()
        let disconnected = await auth.disconnect(), toolToken = await auth.toolToken()
        XCTAssertEqual(disconnected["connected"].bool, false); XCTAssertNil(toolToken); XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("github/auth.json").path))
    }
    func testChannelsAndTypedBadPath() async throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let tools = BackendGitHubFixtureTools(), service = BackendGitHubService(environment: [:], tools: tools), registry = NativeChannelRegistry()
        let auth = try make(directory: dir, http: workingHTTP(token: token), tools: tools)
        let subscription = try await BackendGitHubChannels.register(registry: registry, ownerID: "fixture", service: service, auth: auth)
        let channels = await registry.channels(); XCTAssertEqual(channels, BackendGitHubChannels.channels.sorted())
        for channel in ["github:overview", "github:refresh", "github:repo"] {
            let result = try await registry.invoke(channel, context: .init(caller: .nativeApp, ownerID: "fixture"), arguments: [.string("../etc")]); XCTAssertEqual(result["kind"].string, "error")
        }
        await subscription.cancelAndWait()
    }
}

struct BackendGitHubFixtureTools: BackendGitHubToolRunning {
    let token: String?
    init(token: String? = nil) { self.token = token }
    func run(tool: String, arguments: [String], cwd: String?, environment: [String: String], timeoutMilliseconds: Int, maximumBytes: Int) async throws -> BackendGitOutcome {
        if arguments.first == "--version", token != nil { return .init(ok: true, stdout: "gh version fixture", stderr: "", missing: false, exitCode: 0, timedOut: false) }
        if arguments.prefix(2) == ["auth", "token"], let token { return .init(ok: true, stdout: token, stderr: "", missing: false, exitCode: 0, timedOut: false) }
        return .init(ok: false, stdout: "", stderr: "spawn gh ENOENT", missing: true, exitCode: 127, timedOut: false)
    }
}
actor BackendGitHubWaitRecorder {
    private var delays: [Double] = []
    func record(_ delay: Double) { delays.append(delay) }
    func values() -> [Double] { delays }
}
actor BackendGitHubPollingFixture: BackendGitHubHTTPFetching {
    let token: String; private var polls = 0
    init(token: String) { self.token = token }
    func fetch(url: String, method: String, headers: [String: String], body: String?, timeoutMilliseconds: Int) async throws -> BackendGitHubHTTPResponse {
        if url.hasSuffix("/device/code") { return .init(status: 200, body: #"{"device_code":"fixture","user_code":"A-B","interval":5}"#) }
        if url.hasSuffix("/access_token") {
            polls += 1
            if polls == 1 { return .init(status: 200, body: #"{"error":"slow_down","interval":10}"#) }
            if polls == 2 { return .init(status: 200, body: #"{"error":"authorization_pending"}"#) }
            return .init(status: 200, body: "{\"access_token\":\"\(token)\"}")
        }
        if url.hasSuffix("/user") { return .init(status: 200, body: #"{"login":"fixture-user"}"#) }
        return .init(status: 200, body: #"{"installations":[]}"#)
    }
}
