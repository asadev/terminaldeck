import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

final class APIAccountPolicyTests: XCTestCase {
    private func fixture(_ kind: BackendAPIAccountRecord.Kind = .anthropic, endpoint: String? = nil, model: String? = nil,
                         appName: String = "API Account Fixture") throws -> (URL, BackendAccountProfile, BackendAPIAccountRecord) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("api-account-fixture-" + UUID().uuidString)
        let home = root.appendingPathComponent("account-logins/api-home")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let profile = BackendAccountProfile(id: "api-key-" + String(repeating: "a", count: 24), name: "check API fixture", provider: kind.provider,
            configDir: home.path, system: false, color: "--accent", createdAt: 0)
        let record = try BackendAPIAccountRecord(profile: profile, appName: appName, kind: kind, baseURL: endpoint, model: model)
        return (root, profile, record)
    }
    func testSavedAccountContainsOnlyAReferenceAndNonSecretMetadata() throws {
        let (root, profile, record) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try record.save()
        XCTAssertEqual(try BackendAPIAccountRecord.read(profile), record)
        let encoded = try JSONEncoder().encode(record)
        XCTAssertFalse(String(decoding: encoded, as: UTF8.self).contains("fixture-private-credential"))
        let reference = BackendAPIAccountEnvironment.reference(record)
        XCTAssertEqual(reference[BackendAPIAccountRecord.referenceVariable], record.reference)
        XCTAssertNil(reference["ANTHROPIC_API_KEY"])
        let expanded = try BackendAPIAccountEnvironment.expand(reference, command: "/owned/claude", readKey: { _ in "fixture-private-credential" })
        XCTAssertEqual(expanded.values["ANTHROPIC_API_KEY"], "fixture-private-credential")
        XCTAssertEqual(expanded.values["CLAUDE_CODE_SUBPROCESS_ENV_SCRUB"], "1") // review sessions-security #2
        XCTAssertNil(record.shellNote)
        XCTAssertNil(expanded.values[BackendAPIAccountRecord.referenceVariable])
        XCTAssertEqual(try JSONEncoder().encode(record), encoded)
    }
    func testGeminiAPIAccountStatesItsShellLimitAndGatewayTokenAlsoScrubs() throws {
        let (root, _, gemini) = try fixture(.gemini)
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertEqual(gemini.shellNote, BackendAPIAccountRecord.geminiShellNote)
        let (tokenRoot, _, token) = try fixture(.anthropicToken)
        defer { try? FileManager.default.removeItem(at: tokenRoot) }
        try token.save()
        let expanded = try BackendAPIAccountEnvironment.expand(BackendAPIAccountEnvironment.reference(token), command: "/owned/claude", readKey: { _ in "fixture-key" })
        XCTAssertEqual(expanded.values["CLAUDE_CODE_SUBPROCESS_ENV_SCRUB"], "1")
    }
    func testOtherLaunchesStripAPIKeysButKeepExistingOAuthVaultBindings() throws {
        let env = ["ANTHROPIC_API_KEY": "dummy-api", "OPENAI_API_KEY": "dummy-openai", "CLAUDE_CODE_OAUTH_TOKEN": "dummy-oauth",
                   "CLAUDE_SECURESTORAGE_CONFIG_DIR": "/owned/vault", "PATH": "/usr/bin"]
        let result = try BackendAPIAccountEnvironment.expand(env, command: "/owned/claude")
        XCTAssertNil(result.values["ANTHROPIC_API_KEY"]); XCTAssertNil(result.values["OPENAI_API_KEY"])
        XCTAssertEqual(result.values["CLAUDE_CODE_OAUTH_TOKEN"], "dummy-oauth")
        XCTAssertEqual(result.values["CLAUDE_SECURESTORAGE_CONFIG_DIR"], "/owned/vault")
        XCTAssertNil(result.secret)
    }
    /// 17 Oct: a session's own Claude Code updater broke the shared global install. No launch may update its CLI.
    func testEveryLaunchEnvironmentTurnsOffTheCLIsOwnUpdater() throws {
        let (root, _, record) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try record.save()
        let plain = try BackendAPIAccountEnvironment.expand(["PATH": "/usr/bin", "DISABLE_AUTOUPDATER": "0"], command: "/owned/claude")
        XCTAssertEqual(plain.values["DISABLE_AUTOUPDATER"], "1")
        let account = try BackendAPIAccountEnvironment.expand(BackendAPIAccountEnvironment.reference(record), command: "/owned/claude", readKey: { _ in "fixture-key" })
        XCTAssertEqual(account.values["DISABLE_AUTOUPDATER"], "1")
    }
    func testWrongHomeAndNonProviderCommandCannotReadAKey() throws {
        let (root, _, record) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try record.save()
        var env = BackendAPIAccountEnvironment.reference(record)
        env["CLAUDE_CONFIG_DIR"] = "/another/account"
        var reads = 0
        XCTAssertThrowsError(try BackendAPIAccountEnvironment.expand(env, command: "/owned/claude", readKey: { _ in reads += 1; return "fixture-key" }))
        XCTAssertThrowsError(try BackendAPIAccountEnvironment.expand(BackendAPIAccountEnvironment.reference(record), command: "/bin/env", readKey: { _ in reads += 1; return "fixture-key" }))
        XCTAssertEqual(reads, 0)
    }
    func testRoutingOverridesCannotRedirectAnAccountKey() throws {
        let (root, _, record) = try fixture(endpoint: "https://api.example.invalid")
        defer { try? FileManager.default.removeItem(at: root) }
        try record.save()
        var env = BackendAPIAccountEnvironment.reference(record)
        env["ANTHROPIC_BASE_URL"] = "https://wrong.example.invalid"; env["ANTHROPIC_AUTH_TOKEN"] = "other-credential"
        let result = try BackendAPIAccountEnvironment.expand(env, command: "/owned/claude", readKey: { _ in "fixture-key" })
        XCTAssertEqual(result.values["ANTHROPIC_BASE_URL"], record.baseURL)
        XCTAssertNil(result.values["ANTHROPIC_AUTH_TOKEN"])
    }
    func testCredentialScopeChangesWithEndpointButNotWithModel() throws {
        let (root, profile, first) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = try BackendAPIAccountRecord(profile: profile, appName: first.appName, kind: .anthropic, baseURL: nil, model: "other-model")
        let endpoint = try BackendAPIAccountRecord(profile: profile, appName: first.appName, kind: .anthropic, baseURL: "https://api.example.invalid", model: nil)
        XCTAssertEqual(first.credentialScope, model.credentialScope)
        XCTAssertNotEqual(first.credentialScope, endpoint.credentialScope)
        let dev = try BackendAPIAccountRecord(profile: profile, appName: "API Fixture Dev", kind: .anthropic, baseURL: nil, model: nil)
        XCTAssertNotEqual(first.keychainService, dev.keychainService)
    }
    func testCodexConfigurationHasKeyringOnlyAndNeverEmbedsTheCredential() throws {
        let (root, _, record) = try fixture(.compatible, endpoint: "https://models.example.invalid/v1", model: "vendor/model")
        defer { try? FileManager.default.removeItem(at: root) }
        try BackendAPIAccountCLI.configure(record)
        let text = try String(contentsOf: record.home.appendingPathComponent("config.toml"), encoding: .utf8)
        XCTAssertTrue(text.contains("cli_auth_credentials_store = \"keyring\""))
        XCTAssertTrue(text.contains("forced_login_method = \"api\""))
        XCTAssertTrue(text.contains("env_key = \"" + BackendAPIAccountRecord.customKeyVariable + "\""))
        XCTAssertTrue(text.contains("model = \"vendor/model\""))
        XCTAssertFalse(text.contains("fixture-private-credential"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: record.home.appendingPathComponent("auth.json").path))
    }
    func testLocalConnectionNeverReadsOrInjectsAKey() throws {
        let (root, _, record) = try fixture(.compatibleLocal, endpoint: "http://127.0.0.1:12345/v1", model: "local-model")
        defer { try? FileManager.default.removeItem(at: root) }
        try record.save()
        var reads = 0
        let expanded = try BackendAPIAccountEnvironment.expand(BackendAPIAccountEnvironment.reference(record), command: "/owned/codex", readKey: { _ in reads += 1; return "unused" })
        XCTAssertEqual(reads, 0); XCTAssertNil(expanded.secret)
        let request = try BackendAPIAccountCheck.request(record, key: nil)
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
    }
    func testGeminiSettingsAndKeyStayInItsOwnAccountEnvironment() throws {
        let (root, _, record) = try fixture(.gemini)
        defer { try? FileManager.default.removeItem(at: root) }
        try record.save(); try BackendAPIAccountCLI.configure(record)
        var environment = BackendAPIAccountEnvironment.reference(record)
        environment["OPENAI_API_KEY"] = "other-account"; environment["GOOGLE_APPLICATION_CREDENTIALS"] = "/other-account/credential.json"
        let result = try BackendAPIAccountEnvironment.expand(environment, command: "/owned/gemini", readKey: { _ in "fixture-gemini-key" })
        XCTAssertEqual(result.values["GEMINI_API_KEY"], "fixture-gemini-key")
        XCTAssertEqual(result.values["GEMINI_CLI_HOME"], record.configDirectory)
        XCTAssertNil(result.values["OPENAI_API_KEY"])
        XCTAssertNil(result.values["GOOGLE_APPLICATION_CREDENTIALS"])
        let settings = try String(contentsOf: record.home.appendingPathComponent(".gemini/settings.json"), encoding: .utf8)
        XCTAssertTrue(settings.contains("gemini-api-key")); XCTAssertFalse(settings.contains("fixture-gemini-key"))
        let check = try BackendAPIAccountCheck.request(record, key: "fixture-gemini-key")
        XCTAssertEqual(check.url?.path, "/v1beta/models")
        XCTAssertEqual(check.value(forHTTPHeaderField: "x-goog-api-key"), "fixture-gemini-key")
        XCTAssertFalse(check.url!.absoluteString.contains("fixture-gemini-key"))
    }
    func testCompatibleAndGatewayRequestsUseOnlyTheirChosenCredentialRoute() throws {
        for kind in [BackendAPIAccountRecord.Kind.compatible, .anthropicToken] {
            let (root, _, record) = try fixture(kind, endpoint: "https://gateway.example.invalid/v1", model: "vendor/model")
            defer { try? FileManager.default.removeItem(at: root) }
            try record.save()
            let result = try BackendAPIAccountEnvironment.expand(BackendAPIAccountEnvironment.reference(record), command: "/owned/" + kind.provider,
                readKey: { _ in "fixture-gateway-key" })
            XCTAssertEqual(result.values[kind == .compatible ? BackendAPIAccountRecord.customKeyVariable : "ANTHROPIC_AUTH_TOKEN"], "fixture-gateway-key")
            XCTAssertNil(result.values["OPENAI_API_KEY"]); XCTAssertNil(result.values["ANTHROPIC_API_KEY"])
            let check = try BackendAPIAccountCheck.request(record, key: "fixture-gateway-key")
            XCTAssertEqual(check.url?.path, "/v1/models")
            XCTAssertEqual(check.value(forHTTPHeaderField: "Authorization"), "Bearer fixture-gateway-key")
        }
    }
    func testWorkspaceIDAddsTheCheckHeaderOnlyWhenSet() throws {
        let (root, profile, plain) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertNil(try BackendAPIAccountCheck.request(plain, key: "fixture-key").value(forHTTPHeaderField: "anthropic-workspace-id"))
        let scoped = try BackendAPIAccountRecord(profile: profile, appName: plain.appName, kind: .anthropic, baseURL: nil, model: nil, workspaceID: "wrkspc_01ABC")
        XCTAssertEqual(try BackendAPIAccountCheck.request(scoped, key: "fixture-key").value(forHTTPHeaderField: "anthropic-workspace-id"), "wrkspc_01ABC")
        XCTAssertNil(try BackendAPIAccountRecord(profile: profile, appName: plain.appName, kind: .anthropic, baseURL: nil, model: nil, workspaceID: "").workspaceID)
        XCTAssertThrowsError(try BackendAPIAccountRecord(profile: profile, appName: plain.appName, kind: .anthropic, baseURL: nil, model: nil, workspaceID: "abc"))
    }
    func testWorkspaceIDReachesTheSessionOnlyWhenSet() throws {
        let (root, profile, plain) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try plain.save()
        let ambient = BackendAPIAccountEnvironment.reference(plain).merging(["ANTHROPIC_CUSTOM_HEADERS": "x-other: 1"]) { a, _ in a }
        XCTAssertNil(try BackendAPIAccountEnvironment.expand(ambient, command: "/owned/claude", readKey: { _ in "fixture-key" }).values["ANTHROPIC_CUSTOM_HEADERS"])
        let scoped = try BackendAPIAccountRecord(profile: profile, appName: plain.appName, kind: .anthropic, baseURL: nil, model: nil, workspaceID: "wrkspc_01ABC")
        try scoped.save()
        XCTAssertEqual(try BackendAPIAccountRecord.read(profile)?.workspaceID, "wrkspc_01ABC")
        let values = try BackendAPIAccountEnvironment.expand(BackendAPIAccountEnvironment.reference(scoped), command: "/owned/claude", readKey: { _ in "fixture-key" }).values
        XCTAssertEqual(values["ANTHROPIC_CUSTOM_HEADERS"], "anthropic-workspace-id: wrkspc_01ABC")
    }
    func testModelListCheckKeepsCredentialsOutOfURLsAndClassifiesWithoutEchoingErrors() throws {
        let (root, _, record) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let request = try BackendAPIAccountCheck.request(record, key: "fixture-private-credential")
        XCTAssertEqual(request.url?.path, "/v1/models")
        XCTAssertFalse(request.url!.absoluteString.contains("fixture-private-credential"))
        XCTAssertEqual(BackendAPIAccountCheck.classify(status: 401, body: Data()), "invalid")
        XCTAssertEqual(BackendAPIAccountCheck.classify(status: 403, body: Data()), "no-access")
        XCTAssertEqual(BackendAPIAccountCheck.classify(status: 200, body: Data("{\"data\":[]}".utf8)), "valid")
        XCTAssertEqual(BackendAPIAccountCheck.classify(status: 200, body: Data("<html>sign in</html>".utf8)), "no-access")
        // U108 #169: the provider's own reason is kept with the state.
        let workspace = Data(#"{"type":"error","error":{"type":"invalid_request_error","message":"anthropic-workspace-id header is required\nfor this key"}}"#.utf8)
        XCTAssertEqual(BackendAPIAccountCheck.classify(status: 400, body: workspace), "no-access")
        XCTAssertEqual(BackendAPIAccountCheck.detail(status: 400, body: workspace), "anthropic-workspace-id header is required for this key")
        XCTAssertEqual(BackendAPIAccountCheck.detail(status: 400, body: Data(#"{"error":{"code":400,"message":"API key expired. Please renew the API key."}}"#.utf8)), "API key expired. Please renew the API key.")
        XCTAssertEqual(BackendAPIAccountCheck.detail(status: 403, body: Data()), "The provider answered 403.")
        XCTAssertNil(BackendAPIAccountCheck.detail(status: 200, body: Data("{\"data\":[]}".utf8)))
    }
    func testFragmentedOutputRedactsBeforeAnyConsumerReceivesIt() {
        let secret = "fixture-private-credential"
        let filter = BackendAPISecretStream(secret)
        var result = Data()
        for byte in ("before " + secret + " after").utf8 { result.append(filter.feed(Data([byte]))) }
        result.append(filter.finish())
        XCTAssertEqual(String(decoding: result, as: UTF8.self), "before [redacted] after")
        XCTAssertFalse(String(decoding: result, as: UTF8.self).contains(secret))
    }

    // 18 Oct (#219): an API account that could not be made leaves no empty folder behind.
    func testFailedAddLeavesNoAccountFolder() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("api-account-add-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let configuration = try BackendAccountConfiguration(dataDirectory: root.appendingPathComponent("data"), homeDirectory: root.appendingPathComponent("home"),
            appName: "API Account Fixture", appID: "terminaldeck", helperExecutable: URL(fileURLWithPath: "/usr/bin/true"), inheritedEnvironment: [:])
        let service = BackendAPIAccountService(configuration: configuration, access: .init(
            find: { _, _ in nil }, list: { _ in [] },
            create: { _, _, _, _ in throw BackendAccountFailure("Fixture: the account store refused.") },
            rename: { _, _, _ in throw BackendAccountFailure("unused") }, remove: { _, _ in .null }), authorizeMutation: { _ in })
        do {
            _ = try await service.invoke("profiles:api:add", args: [.object([.init("name", .string("Work")), .init("kind", .string("openai"))])],
                                         context: NativeRPCContext(caller: .nativeApp, ownerID: "api-account-test"))
            XCTFail("The refused account must not be added.")
        } catch {}
        let left = (try? FileManager.default.contentsOfDirectory(atPath: configuration.accountLoginsRoot.path)) ?? []
        XCTAssertTrue(left.filter { $0.hasPrefix("api-") }.isEmpty, "left behind: \(left)")
    }
    // 18 Oct (#521): a Codex API account logs Codex in once per key, not at every start.
    func testCodexAPILoginRunsOncePerKeyRevision() async throws {
        let (root, _, record) = try fixture(.openai)
        defer { try? FileManager.default.removeItem(at: root) }
        let bin = root.appendingPathComponent("bin"), codex = bin.appendingPathComponent("codex")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        // A login here would fail: a launch that skips it succeeds.
        try Data("#!/bin/sh\nexit 1\n".utf8).write(to: codex)
        XCTAssertEqual(chmod(codex.path, 0o700), 0)
        try BackendAccountFiles.writeAtomic(JSONEncoder().encode(BackendAPIAccountCLI.Receipt(executable: codex.path, revision: record.credentialRevision)),
            to: record.home.appendingPathComponent(BackendAPIAccountCLI.receiptName))
        try await BackendAPIAccountCLI.prepare(record, path: bin.path, inherited: [:])
        var changed = record
        changed.credentialRevision += 1
        do { try await BackendAPIAccountCLI.prepare(changed, path: bin.path, inherited: [:]); XCTFail("A new key must log Codex in again.") } catch {}
    }
}
