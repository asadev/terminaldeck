import Foundation
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

@MainActor final class BackendGitHubParityAuth: XCTestCase {
    private let token = "gho_16C7e42F292c6912E7710c838347Ae178B4a", cliToken = "gho_ZZZZe42F292c6912E7710c838347Ae178B4a"
    private func repo() -> NativeRPCValue { BackendGitHubRules.ref(host: "github.com", owner: "asadev", name: "terminaldeck", remote: "origin") }
    private func make(_ dir: URL, env: [String: String] = [:], tools: any BackendGitHubToolRunning = BackendGitHubParityCLI(installed: false), http: any BackendGitHubHTTPFetching,
                      registration: BackendGitHubAppRegistration = .init(clientID: "Iv23liTESTAPP", slug: "test-deck"), clock: BackendGitHubParityClock = .init(), sleeper: BackendGitHubParitySleeper = .init(immediate: true), repo: NativeRPCValue? = nil, branch: NativeRPCValue = .null) throws -> BackendGitHubAuthenticator {
        let reference = repo ?? self.repo()
        return try BackendGitHubAuthenticator(dataDirectory: dir, environment: env, registration: registration, http: http, tools: tools, now: { clock.now() }, sleep: { try await sleeper.sleep($0) }, resolveRepo: { _ in reference }, resolveBranch: { _ in branch })
    }
    private func successfulHTTP(scopes: String? = "repo, read:org, notifications", accessStatus: Int = 200) -> BackendGitHubParityHTTP {
        let user = #"{"login":"asadev","name":"Asad","html_url":"https://github.com/asadev","avatar_url":"https://avatars.githubusercontent.com/u/1?v=4"}"#
        return BackendGitHubParityHTTP { call in
            if call.url.hasSuffix("/user") { return .init(status: 200, body: user, headers: scopes.map { ["X-OAuth-Scopes": $0] } ?? [:]) }
            if accessStatus != 200 { return .init(status: accessStatus, body: #"{"message":"API rate limit exceeded"}"#, headers: ["X-RateLimit-Remaining": "0"]) }
            if call.url.contains("/user/installations/") { return .init(status: 200, body: #"{"total_count":1,"repositories":[{"full_name":"asadev/terminaldeck"}]}"#) }
            if call.url.contains("/user/installations?") { return .init(status: 200, body: #"{"total_count":1,"installations":[{"id":42,"repository_selection":"selected"}]}"#) }
            return .init(status: 200, body: #"[{"full_name":"asadev/terminaldeck","name":"terminaldeck","owner":{"login":"asadev"},"html_url":"https://github.com/asadev/terminaldeck","private":false,"default_branch":"main","pushed_at":"2026-08-16T00:46:23Z","permissions":{"push":true}}]"#)
        }
    }
    private func flowHTTP(pending: Int = 0, finalError: String? = nil, expiresIn: Double? = nil, slowDown: Bool = false) -> BackendGitHubParityHTTP {
        let token = self.token, polls = BackendGitHubParityCounter()
        return BackendGitHubParityHTTP { call in
            if call.url.hasSuffix("/login/device/code") { return .init(status: 200, body: #"{"device_code":"2fac6982365140b262ba16cd354dd8fbeb8b11f1","user_code":"E874-5342","verification_uri":"https://github.com/login/device","expires_in":899,"interval":5}"#) }
            if call.url.hasSuffix("/login/oauth/access_token") {
                let seen = await polls.increment()
                if slowDown && seen == 1 { return .init(status: 200, body: #"{"error":"slow_down","interval":10}"#) }
                if seen <= pending { return .init(status: 200, body: #"{"error":"authorization_pending","error_description":"The authorization request is still pending."}"#) }
                if let finalError { return .init(status: 200, body: BackendGitHubParityObject([("error", .string(finalError))]).compact) }
                var fields: [(String, NativeRPCValue)] = [("access_token", .string(token)), ("scope", .string("repo"))]
                if let expiresIn { fields.append(("expires_in", .number(expiresIn))) }
                return .init(status: 200, body: BackendGitHubParityObject(fields).compact)
            }
            if call.url.hasSuffix("/user") { return .init(status: 200, body: #"{"login":"asadev","name":"Asad","html_url":"https://github.com/asadev"}"#, headers: ["X-OAuth-Scopes": "repo, read:org, notifications"]) }
            if call.url.contains("/installations/") { return .init(status: 200, body: #"{"total_count":1,"repositories":[{"full_name":"asadev/terminaldeck"}]}"#) }
            if call.url.contains("/installations?") { return .init(status: 200, body: #"{"installations":[{"id":42,"repository_selection":"selected"}]}"#) }
            return .init(status: 200, body: #"[{"full_name":"asadev/terminaldeck"}]"#)
        }
    }
    private func seed(_ dir: URL, kind: String? = nil, expiry: Double? = nil) throws {
        var fields: [(String, NativeRPCValue)] = [("version", .number(1)), ("host", .string("github.com")), ("token", .string(token)), ("login", .string("asadev")), ("scopes", .array([.string("repo"), .string("notifications")])), ("obtainedAt", .number(0))]
        if let kind { fields.append(("clientKind", .string(kind))) }; if let expiry { fields.append(("expiresAt", .number(expiry))) }
        try BackendAccountFiles.writeAtomic(try BackendGitHubParityObject(fields).encodedJSON(), to: dir.appendingPathComponent("github/auth.json"))
    }
    func testScopeParsingAndReportedHeaderWithoutRequestedPermissionJudgement() async throws {
        XCTAssertEqual(BackendGitHubAuthenticator.parseScopes("admin:public_key, gist, read:org, repo"), ["admin:public_key", "gist", "read:org", "repo"])
        XCTAssertEqual(BackendGitHubAuthenticator.parseScopes(nil), []); XCTAssertEqual(BackendGitHubAuthenticator.parseScopes(""), [])
        let dir = try BackendGitHubParityDirectory("scope"); defer { try? FileManager.default.removeItem(at: dir) }
        let auth = try make(dir, tools: BackendGitHubParityCLI(token: cliToken), http: successfulHTTP(scopes: "admin:public_key, gist, read:org, repo")), state = await auth.status()
        XCTAssertEqual(state["scopes"], .array([.string("admin:public_key"), .string("gist"), .string("read:org"), .string("repo")]))
        XCTAssertEqual(state["scopesReported"].bool, true); XCTAssertFalse(state.has("missingScopes")); XCTAssertEqual(state["failure"], .null)
    }
    func testSixStatesHaveDifferentFixesAndFolderFailureDoesNotDisconnect() async throws {
        let dir = try BackendGitHubParityDirectory("states"); defer { try? FileManager.default.removeItem(at: dir) }
        let missing = try make(dir, http: successfulHTTP()), missingState = await missing.status()
        XCTAssertEqual(missingState["connected"].bool, false); XCTAssertEqual(missingState["ghInstalled"].bool, false); XCTAssertEqual(missingState["failure"]["kind"].string, "not-authenticated"); XCTAssertEqual(missingState["failure"]["action"], .null); XCTAssertTrue(missingState["failure"]["message"].string!.contains("not needed"))
        let loggedOut = try make(dir, tools: BackendGitHubParityCLI(), http: successfulHTTP()), loggedOutState = await loggedOut.status()
        XCTAssertEqual(loggedOutState["connected"].bool, false); XCTAssertEqual(loggedOutState["ghInstalled"].bool, true); XCTAssertEqual(loggedOutState["failure"]["kind"].string, "not-authenticated"); XCTAssertEqual(loggedOutState["failure"]["action"].string, "gh auth login")
        let signed = try make(dir, tools: BackendGitHubParityCLI(token: cliToken), http: successfulHTTP(scopes: "admin:public_key, gist, read:org, repo")), signedState = await signed.status()
        XCTAssertEqual(signedState["connected"].bool, true); XCTAssertEqual(signedState["source"].string, "gh-cli"); XCTAssertEqual(signedState["identity"]["login"].string, "asadev"); XCTAssertEqual(signedState["scopesReported"].bool, true); XCTAssertEqual(signedState["credentialKind"].string, "oauth"); XCTAssertEqual(signedState["failure"], .null); XCTAssertTrue(signedState["disconnect"].string!.contains("terminal"))
        let folder = try make(dir, tools: BackendGitHubParityCLI(token: cliToken), http: successfulHTTP()), folderState = await folder.status(cwd: "/tmp/project")
        XCTAssertEqual(folderState["connected"].bool, true); XCTAssertEqual(folderState["repo"], repo()); XCTAssertEqual(folderState["scopes"], .array([.string("repo"), .string("read:org"), .string("notifications")]))
        for (kind, message) in [("not-a-repo", "This folder is not a git repository."), ("no-github-remote", "None of this repository’s remotes point at GitHub.")] {
            let failure = BackendGitHubRules.failure(kind, message, kind == "not-a-repo" ? "git init" : "git remote add github <url>"), auth = try make(dir, tools: BackendGitHubParityCLI(token: cliToken), http: successfulHTTP(), repo: failure), state = await auth.status(cwd: "/tmp/project")
            XCTAssertEqual(state["connected"].bool, true); XCTAssertEqual(state["failure"], .null); XCTAssertEqual(state["repo"], failure)
        }
    }
    func testDisconnectedStateSentencesStayDistinct() async throws {
        let dir = try BackendGitHubParityDirectory("sentences"); defer { try? FileManager.default.removeItem(at: dir) }
        var sentences: [String] = []
        let noCLI = try make(dir, http: successfulHTTP()), noState = await noCLI.status(); sentences.append(noState["failure"]["message"].string!)
        let loggedOut = try make(dir, tools: BackendGitHubParityCLI(), http: successfulHTTP()), outState = await loggedOut.status(); sentences.append(outState["failure"]["message"].string!)
        for (status, body, env) in [(401, #"{"message":"Bad credentials"}"#, false), (403, #"{"message":"API rate limit exceeded"}"#, false), (500, "upstream is sad", false), (401, #"{"message":"Bad credentials"}"#, true)] {
            let http = BackendGitHubParityHTTP { _ in .init(status: status, body: body) }
            let auth = try make(dir, env: env ? ["GH_TOKEN": cliToken] : [:], tools: BackendGitHubParityCLI(token: cliToken), http: http), state = await auth.status()
            XCTAssertEqual(state["connected"].bool, false); XCTAssertNotEqual(state["failure"], .null); sentences.append(state["failure"]["message"].string!)
        }
        XCTAssertEqual(Set(sentences).count, 6); XCTAssertFalse(sentences.contains { $0.lowercased().hasPrefix("failed") })
    }
    func testFailedLoginIsRereadAndSuccessfulConnectionCacheIsReal() async throws {
        let dir = try BackendGitHubParityDirectory("cache"); defer { try? FileManager.default.removeItem(at: dir) }
        let cli = BackendGitHubParityCLI(), auth = try make(dir, tools: cli, http: successfulHTTP())
        let before = await auth.status(); XCTAssertEqual(before["connected"].bool, false); XCTAssertEqual(before["failure"]["kind"].string, "not-authenticated")
        await cli.setToken(cliToken); let after = await auth.status(); XCTAssertEqual(after["connected"].bool, true); XCTAssertEqual(after["source"].string, "gh-cli")
        let http = successfulHTTP(), working = try make(dir, tools: BackendGitHubParityCLI(token: cliToken), http: http)
        _ = await working.status(); _ = await working.status(); let calls = await http.calls(); XCTAssertEqual(calls.filter { $0.url.hasSuffix("/user") }.count, 1)
        let failedHTTP = successfulHTTP(accessStatus: 500), failedAccess = try make(dir, tools: BackendGitHubParityCLI(token: cliToken), http: failedHTTP)
        let first = await failedAccess.status(), second = await failedAccess.status(), failedCalls = await failedHTTP.calls()
        XCTAssertEqual(first["connected"].bool, true); XCTAssertEqual(second["connected"].bool, true); XCTAssertEqual(failedCalls.filter { $0.url.hasSuffix("/user") }.count, 2)
    }
    func testEnvironmentWinsStoredCredentialAndCLIIsReused() async throws {
        let dir = try BackendGitHubParityDirectory("precedence"); defer { try? FileManager.default.removeItem(at: dir) }; try seed(dir)
        let auth = try make(dir, env: ["GH_TOKEN": cliToken], tools: BackendGitHubParityCLI(token: token), http: successfulHTTP()), state = await auth.status()
        XCTAssertEqual(state["source"].string, "environment"); XCTAssertEqual(state["disconnect"], .null)
        let tokenFromTool = await auth.toolToken(); XCTAssertNil(tokenFromTool)
        let stored = try make(dir, http: successfulHTTP()), storedToken = await stored.toolToken(); XCTAssertEqual(storedToken, token)
        let empty = try BackendGitHubParityDirectory("cli"); defer { try? FileManager.default.removeItem(at: empty) }
        let cli = try make(empty, tools: BackendGitHubParityCLI(token: cliToken), http: successfulHTTP()), cliState = await cli.status(); XCTAssertEqual(cliState["source"].string, "gh-cli"); XCTAssertEqual(cliState["connected"].bool, true)
    }
    func testProbeEnvironmentStripsAllFourTokenVariablesAndPreservesIdentity() {
        let env = BackendGitHubAuthenticator.probeEnvironment(["GH_TOKEN": cliToken, "GITHUB_TOKEN": cliToken, "GH_ENTERPRISE_TOKEN": cliToken, "GITHUB_ENTERPRISE_TOKEN": cliToken, "HOME": "/Users/asad", "PATH": "/opt/homebrew/bin:/usr/bin"])
        XCTAssertFalse(env.values.contains(cliToken)); for key in ["GH_TOKEN", "GITHUB_TOKEN", "GH_ENTERPRISE_TOKEN", "GITHUB_ENTERPRISE_TOKEN"] { XCTAssertNil(env[key]) }
        XCTAssertEqual(env["HOME"], "/Users/asad"); XCTAssertEqual(env["PATH"], "/opt/homebrew/bin:/usr/bin"); XCTAssertEqual(env["LC_ALL"], "C")
    }
    func testPromptIsAvailableBeforeSignInAndCancellationLeavesNothing() async throws {
        let dir = try BackendGitHubParityDirectory("prompt"); defer { try? FileManager.default.removeItem(at: dir) }
        let sleeper = BackendGitHubParitySleeper(), auth = try make(dir, http: flowHTTP(), sleeper: sleeper)
        let prompt = await auth.connect(); await sleeper.waitForCount(1)
        XCTAssertEqual(prompt["userCode"].string, "E874-5342"); XCTAssertEqual(prompt["verificationUri"].string, "https://github.com/login/device")
        for key in ["clientKind", "borrowedClient", "scopes"] { XCTAssertFalse(prompt.has(key)) }
        let pending = await auth.status(); XCTAssertEqual(pending["pending"]["userCode"].string, "E874-5342")
        let cancelled = await auth.cancelConnect(); XCTAssertEqual(cancelled["pending"], .null); XCTAssertEqual(cancelled["connected"].bool, false)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("github/auth.json").path))
    }
    func testNoRegistrationRefusesBeforeNetworkAndNamesBothEscapeRoutes() async throws {
        let dir = try BackendGitHubParityDirectory("unconfigured"); defer { try? FileManager.default.removeItem(at: dir) }
        let http = BackendGitHubParityHTTP { _ in throw NativeRPCError(code: "unexpected", message: "No route may be called") }, auth = try make(dir, http: http, registration: .absent)
        let failure = await auth.connect(), calls = await http.calls()
        XCTAssertEqual(failure["ok"].bool, false); XCTAssertEqual(failure["kind"].string, "auth-unavailable"); XCTAssertTrue(failure["message"].string!.contains("gh auth login")); XCTAssertTrue(failure["message"].string!.contains(BackendGitHubAppRegistration.clientIDEnvironment)); XCTAssertEqual(calls.count, 0)
        let unconfigured = try make(dir, tools: BackendGitHubParityCLI(), http: http, registration: .absent), state = await unconfigured.status()
        XCTAssertEqual(state["appConfigured"].bool, false); XCTAssertEqual(state["installUrl"], .null); XCTAssertEqual(state["failure"]["kind"].string, "not-authenticated"); XCTAssertTrue(state["failure"]["message"].string!.contains("gh auth login")); XCTAssertTrue(state["failure"]["message"].string!.contains(BackendGitHubAppRegistration.clientIDEnvironment))
    }
    func testAuthorizationPendingStorageModeAndSlowDownIntervals() async throws {
        let dir = try BackendGitHubParityDirectory("polling"); defer { try? FileManager.default.removeItem(at: dir) }
        let auth = try make(dir, http: flowHTTP(pending: 3)); _ = await auth.connect(); let state = await auth.awaitConnect(cwd: "/tmp/project")
        XCTAssertEqual(state["connected"].bool, true); XCTAssertEqual(state["source"].string, "device-flow"); XCTAssertEqual(state["identity"]["login"].string, "asadev"); XCTAssertEqual(state["pending"], .null)
        let file = dir.appendingPathComponent("github/auth.json"), attributes = try FileManager.default.attributesOfItem(atPath: file.path), stored = try NativeRPCValue.parseJSON(Data(contentsOf: file))
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600); XCTAssertEqual(stored["login"].string, "asadev"); XCTAssertEqual(stored["clientKind"].string, "github-app")
        let other = try BackendGitHubParityDirectory("slow"); defer { try? FileManager.default.removeItem(at: other) }
        let waits = BackendGitHubParitySleeper(immediate: true), slow = try make(other, http: flowHTTP(slowDown: true), sleeper: waits)
        _ = await slow.connect(); _ = await slow.awaitConnect(); let delays = await waits.values(); XCTAssertEqual(delays, [5000, 10000])
    }
    func testExpiredAndDeclinedFlowsHaveDifferentReasonsAndApp404NamesCheckbox() async throws {
        let dir = try BackendGitHubParityDirectory("flow-errors"); defer { try? FileManager.default.removeItem(at: dir) }
        let expired = try make(dir, http: flowHTTP(finalError: "expired_token")); _ = await expired.connect(); _ = await expired.awaitConnect(); let expiredFailure = await expired.flowFailure()
        let denied = try make(dir, http: flowHTTP(finalError: "access_denied")); _ = await denied.connect(); _ = await denied.awaitConnect(); let deniedFailure = await denied.flowFailure()
        XCTAssertEqual(expiredFailure?["kind"].string, "auth-code-expired"); XCTAssertEqual(deniedFailure?["kind"].string, "auth-declined"); XCTAssertNotEqual(expiredFailure?["message"], deniedFailure?["message"])
        let unavailable = try make(dir, http: BackendGitHubParityHTTP { _ in .init(status: 404, body: #"{"error":"Not Found"}"#) }, registration: .shipping), failure = await unavailable.connect()
        XCTAssertEqual(failure["kind"].string, "auth-unavailable"); XCTAssertTrue(failure["message"].string!.contains("Iv23limkNV4N6mChRl60")); XCTAssertTrue(failure["message"].string!.contains("Enable Device Flow"))
    }
    func testStoredDisconnectAndCLIUserLogoutAreRealDifferentOperations() async throws {
        let dir = try BackendGitHubParityDirectory("disconnect"); defer { try? FileManager.default.removeItem(at: dir) }; try seed(dir)
        let auth = try make(dir, http: successfulHTTP()), after = await auth.disconnect(), storedToken = await auth.toolToken()
        XCTAssertEqual(after["connected"].bool, false); XCTAssertNil(storedToken); XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("github/auth.json").path))
        let cli = BackendGitHubParityCLI(token: cliToken), fromCLI = try make(dir, tools: cli, http: successfulHTTP()), before = await fromCLI.status()
        XCTAssertTrue(before["disconnect"].string!.contains("terminal"))
        let signedOut = await fromCLI.disconnect(), calls = await cli.calls(), logout = calls.first { $0.prefix(2) == ["auth", "logout"] }
        XCTAssertNotNil(logout); XCTAssertTrue(logout!.contains("--user")); XCTAssertTrue(logout!.contains("asadev")); XCTAssertEqual(signedOut["connected"].bool, false)
    }
    func testExpiredStoredCredentialFallsThroughToWorkingCLI() async throws {
        let dir = try BackendGitHubParityDirectory("fallback"); defer { try? FileManager.default.removeItem(at: dir) }; try seed(dir)
        let checked = BackendGitHubParityCounter(), http = BackendGitHubParityHTTP { call in
            if call.url.hasSuffix("/user") { let count = await checked.increment(); return count == 1 ? .init(status: 401, body: #"{"message":"Bad credentials"}"#) : .init(status: 200, body: #"{"login":"asadev"}"#, headers: ["X-OAuth-Scopes": "repo, read:org"]) }
            return .init(status: 200, body: #"[{"full_name":"asadev/terminaldeck"}]"#)
        }, auth = try make(dir, tools: BackendGitHubParityCLI(token: cliToken), http: http), state = await auth.status()
        XCTAssertEqual(state["expiredCredentialRemoved"].bool, true); XCTAssertEqual(state["source"].string, "gh-cli"); XCTAssertEqual(state["connected"].bool, true)
    }
    func testRejectedEnvironmentStoredAndCLITokensNeverLeaveStatusOrScrubbedOutput() async throws {
        let dir = try BackendGitHubParityDirectory("secrets"); defer { try? FileManager.default.removeItem(at: dir) }
        let cliToken = self.cliToken, echoed = BackendGitHubParityHTTP { _ in .init(status: 401, body: "{\"message\":\"Bad credentials for \(cliToken)\"}") }
        let auth = try make(dir, env: ["GH_TOKEN": cliToken], http: echoed), state = await auth.status(cwd: "/tmp/project")
        XCTAssertFalse(state.compact.contains(cliToken)); XCTAssertTrue(state["failure"]["detail"].string!.contains("[redacted]"))
        let scrubbed = await auth.scrubSecrets("gh: HTTP 401 using \(cliToken)"), plain = await auth.scrubSecrets("nothing secret here")
        XCTAssertEqual(scrubbed, "gh: HTTP 401 using [redacted]"); XCTAssertEqual(plain, "nothing secret here")
        let stored = try make(dir, http: flowHTTP()); _ = await stored.connect(); let storedState = await stored.awaitConnect(cwd: "/tmp/project")
        XCTAssertEqual(storedState["connected"].bool, true); XCTAssertFalse(storedState.compact.contains(token))
        let cliHTTP = BackendGitHubParityHTTP { call in call.url.hasSuffix("/user") ? .init(status: 200, body: #"{"login":"asadev"}"#) : .init(status: 500, body: "{\"message\":\"upstream said \(cliToken)\"}") }
        let empty = try BackendGitHubParityDirectory("cli-secret"); defer { try? FileManager.default.removeItem(at: empty) }
        let fromCLI = try make(empty, tools: BackendGitHubParityCLI(token: cliToken), http: cliHTTP), cliState = await fromCLI.status()
        XCTAssertEqual(cliState["connected"].bool, true); XCTAssertFalse(cliState.compact.contains(cliToken)); XCTAssertTrue(cliState["access"]["detail"].string!.contains("[redacted]"))
    }
    func testFlowReasonSurvivesRegisteredStatusChannel() async throws {
        let dir = try BackendGitHubParityDirectory("reason-ipc"); defer { try? FileManager.default.removeItem(at: dir) }
        let auth = try make(dir, http: flowHTTP(finalError: "access_denied")), registry = NativeChannelRegistry(), service = BackendGitHubService(environment: [:], tools: BackendGitHubParityCLI(installed: false))
        let subscription = try await BackendGitHubChannels.register(registry: registry, ownerID: "fixture", service: service, auth: auth); defer { subscription.cancel() }
        _ = try await registry.invoke("github:auth-connect", context: .init(caller: .nativeApp, ownerID: "fixture"), arguments: [])
        _ = try await registry.invoke("github:auth-await", context: .init(caller: .nativeApp, ownerID: "fixture"), arguments: [.string("/tmp/project")])
        let state = try await registry.invoke("github:auth-status", context: .init(caller: .nativeApp, ownerID: "fixture"), arguments: [])
        XCTAssertEqual(state["connected"].bool, false); XCTAssertEqual(state["failure"]["kind"].string, "auth-declined")
    }
    func testAccessSuccessIndependentFailureParallelRequestsAndSeparateCache() async throws {
        let dir = try BackendGitHubParityDirectory("access"); defer { try? FileManager.default.removeItem(at: dir) }
        let http = successfulHTTP(), auth = try make(dir, tools: BackendGitHubParityCLI(token: cliToken), http: http), state = await auth.status(cwd: "/tmp/project")
        XCTAssertEqual(state["connected"].bool, true); XCTAssertEqual(state["access"]["ok"].bool, true); XCTAssertEqual(state["access"]["repos"].elements?.map { $0["nameWithOwner"].string }, ["asadev/terminaldeck"]); XCTAssertEqual(state["access"]["truncated"].bool, false); XCTAssertEqual(state["access"]["atLeast"].number, 1)
        _ = await auth.status(); _ = await auth.status(refresh: true); let calls = await http.calls(); XCTAssertEqual(calls.filter { $0.url == BackendGitHubRepositories.accountURL("github.com") }.count, 1)
        let rateLimited = try make(dir, tools: BackendGitHubParityCLI(token: cliToken), http: successfulHTTP(accessStatus: 403)), rate = await rateLimited.status()
        XCTAssertEqual(rate["connected"].bool, true); XCTAssertEqual(rate["identity"]["login"].string, "asadev"); XCTAssertEqual(rate["access"]["kind"].string, "rate-limited")
        let count = BackendGitHubParityCounter(), both = BackendGitHubParityLatch()
        let parallel = BackendGitHubParityHTTP { call in
            let entered = await count.increment(); if entered >= 2 { await both.release() }; await both.wait()
            return call.url.hasSuffix("/user") ? .init(status: 200, body: #"{"login":"asadev"}"#) : .init(status: 200, body: #"[{"full_name":"asadev/terminaldeck"}]"#)
        }, overlap = try make(dir, tools: BackendGitHubParityCLI(token: cliToken), http: parallel)
        _ = await overlap.status(); let simultaneous = await count.value(); XCTAssertEqual(simultaneous, 2)
    }
    func testFolderBranchAndNoFolderHaveExactNullShapes() async throws {
        let dir = try BackendGitHubParityDirectory("folder"); defer { try? FileManager.default.removeItem(at: dir) }
        let branch = try BackendGitHubParityJSON(#"{"name":"main","detached":false,"head":null}"#), auth = try make(dir, tools: BackendGitHubParityCLI(token: cliToken), http: successfulHTTP(), branch: branch)
        let state = await auth.status(cwd: "/tmp/project"), absent = await auth.status()
        XCTAssertEqual(state["repo"]["nameWithOwner"].string, "asadev/terminaldeck"); XCTAssertEqual(state["branch"], branch)
        XCTAssertEqual(absent["repo"], .null); XCTAssertEqual(absent["branch"], .null)
    }
    func testConsentBodyShippingAppAndRecordedDevicePrompt() async throws {
        let dir = try BackendGitHubParityDirectory("app-consent"); defer { try? FileManager.default.removeItem(at: dir) }
        let http = flowHTTP(), auth = try make(dir, http: http, registration: .shipping)
        _ = await auth.connect(); _ = await auth.awaitConnect(); let calls = await http.calls(), started = calls.first { $0.url.hasSuffix("/login/device/code") }
        XCTAssertEqual(started?.body, "client_id=Iv23limkNV4N6mChRl60"); XCTAssertFalse(started?.body?.contains("scope") ?? true); XCTAssertFalse(started?.body?.contains("read%3Aorg") ?? true); XCTAssertFalse(started?.body?.contains("read:org") ?? true)
        for call in calls { XCTAssertFalse((call.body ?? "").contains("178c6fc778ccc68e1d6a")); XCTAssertFalse(call.url.contains("178c6fc778ccc68e1d6a")) }
        let state = await auth.status(); XCTAssertEqual(state["appConfigured"].bool, true); XCTAssertEqual(state["installUrl"].string, "https://github.com/apps/terminal-deck/installations/new"); XCTAssertFalse(state.has("clientKind")); XCTAssertFalse(state.has("borrowedClient"))
        let capturedDir = try BackendGitHubParityDirectory("captured"); defer { try? FileManager.default.removeItem(at: capturedDir) }
        let sleeper = BackendGitHubParitySleeper(), clock = BackendGitHubParityClock(ISO8601DateFormatter().date(from: "2026-08-16T10:00:00Z")!.timeIntervalSince1970 * 1000)
        let capturedHTTP = BackendGitHubParityHTTP { _ in .init(status: 200, body: #"{"device_code":"3d0cf1759c7e976f0297aa34a35989776b7ae884","user_code":"E9EE-04C7","verification_uri":"https://github.com/login/device","expires_in":899,"interval":5}"#) }
        let captured = try make(capturedDir, http: capturedHTTP, registration: .shipping, clock: clock, sleeper: sleeper), prompt = await captured.connect()
        await sleeper.waitForCount(1); _ = await captured.cancelConnect()
        let expected = BackendGitHubParityObject([("userCode", .string("E9EE-04C7")), ("verificationUri", .string("https://github.com/login/device")), ("expiresAt", .number(clock.now() + 899_000)), ("installUrl", .string("https://github.com/apps/terminal-deck/installations/new"))])
        XCTAssertEqual(prompt, expected); let capturedCalls = await capturedHTTP.calls(); XCTAssertEqual(capturedCalls[0].body, "client_id=Iv23limkNV4N6mChRl60")
    }
    func testEnvironmentAppOverrideNoScopesAndInstallationLink() async throws {
        let dir = try BackendGitHubParityDirectory("override"); defer { try? FileManager.default.removeItem(at: dir) }
        let env = [BackendGitHubAppRegistration.clientIDEnvironment: "Iv23liEXAMPLE", BackendGitHubAppRegistration.slugEnvironment: "terminal-deck"], http = flowHTTP(), auth = try make(dir, env: env, http: http)
        let prompt = await auth.connect(); _ = await auth.awaitConnect(); let calls = await http.calls(), body = calls.first { $0.url.hasSuffix("/device/code") }?.body
        XCTAssertEqual(body, "client_id=Iv23liEXAMPLE"); XCTAssertFalse(body!.contains("scope")); XCTAssertEqual(prompt["userCode"].string, "E874-5342")
        let state = await auth.status(); XCTAssertEqual(state["appConfigured"].bool, true); XCTAssertEqual(state["installUrl"].string, "https://github.com/apps/terminal-deck/installations/new")
    }
    func testLocalExpiryNoNetworkAndLegacyKindsSurviveUntilRejected() async throws {
        let dir = try BackendGitHubParityDirectory("expiry"); defer { try? FileManager.default.removeItem(at: dir) }
        let clock = BackendGitHubParityClock(), seeded = try make(dir, http: flowHTTP(expiresIn: 28_800), clock: clock)
        _ = await seeded.connect(); let connected = await seeded.awaitConnect(); XCTAssertEqual(connected["connected"].bool, true)
        clock.set(8 * 3_600_000 + 60_000)
        let http = successfulHTTP(), expired = try make(dir, http: http, clock: clock), state = await expired.status(), calls = await http.calls()
        XCTAssertEqual(state["connected"].bool, false); XCTAssertEqual(state["expiredCredentialRemoved"].bool, true); XCTAssertEqual(calls.count, 0)
        for kind in [nil, "oauth"] as [String?] {
            let legacyDir = try BackendGitHubParityDirectory("legacy"); defer { try? FileManager.default.removeItem(at: legacyDir) }; try seed(legacyDir, kind: kind)
            let legacyHTTP = successfulHTTP(), legacy = try make(legacyDir, http: legacyHTTP, registration: .shipping), legacyState = await legacy.status(), legacyCalls = await legacyHTTP.calls()
            XCTAssertEqual(legacyState["connected"].bool, true); XCTAssertEqual(legacyState["source"].string, "device-flow"); XCTAssertEqual(legacyState["credentialKind"].string, "oauth"); XCTAssertEqual(legacyState["access"]["ok"].bool, true); XCTAssertTrue(legacyCalls.contains { $0.url == BackendGitHubRepositories.accountURL("github.com") })
        }
        let rejectedDir = try BackendGitHubParityDirectory("legacy-rejected"); defer { try? FileManager.default.removeItem(at: rejectedDir) }; try seed(rejectedDir, kind: "oauth")
        let rejected = try make(rejectedDir, http: BackendGitHubParityHTTP { _ in .init(status: 401, body: #"{"message":"Bad credentials"}"#) }, registration: .shipping), rejectedState = await rejected.status()
        XCTAssertEqual(rejectedState["connected"].bool, false); XCTAssertEqual(rejectedState["expiredCredentialRemoved"].bool, true); XCTAssertFalse(FileManager.default.fileExists(atPath: rejectedDir.appendingPathComponent("github/auth.json").path))
    }
}
