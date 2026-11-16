import XCTest
@testable import TerminalDeckNativeCore
@testable import TerminalDeckBackend

private struct CloudSecretsAppVoiceCipher: BackendOSVoiceEncrypting {
    let password = Data(repeating: 33, count: 32)
    func prepareForWrites(existingVault: Bool) throws {}
    func decrypt(_ blob: Data) throws -> String { try ChromiumSafeStorageCipher.decrypt(blob, password: password) }
    func encrypt(_ text: String, existingVault: Bool) throws -> Data { try ChromiumSafeStorageCipher.encrypt(text, password: password) }
}
private actor CloudSecretsAppNoVoiceHTTP: BackendOSVoiceRequesting {
    var calls = 0
    func post(provider: BackendOSVoiceRules.Provider, key: String, audio: Data, filename: String) throws -> (status: Int, body: String) {
        calls += 1; throw CloudFailure.unavailable
    }
}
private actor CloudSecretsAppNoGitHubTools: BackendGitHubToolRunning {
    var calls = 0
    func run(tool: String, arguments: [String], cwd: String?, environment: [String: String], timeoutMilliseconds: Int, maximumBytes: Int) throws -> BackendGitOutcome {
        calls += 1; throw CloudFailure.unavailable
    }
}
@MainActor
final class CloudSecretsAppOwnersTests: XCTestCase {
    var assertions = 0
    override func tearDown() async throws { print("CloudSecretsAppOwnersTests assertions=\(assertions)") }
    func check(_ value: Bool, file: StaticString = #filePath, line: UInt = #line) {
        assertions += 1; XCTAssertTrue(value, "App owner assertion", file: file, line: line)
    }
    /// A non-expiring sign-in (OAuth app, or a GitHub App without expiring
    /// tokens): safe on two Macs at once.
    func credential(_ token: String, host: String = "github.com") -> NativeRPCValue {
        .object([.init("version", .number(1)), .init("host", .string(host)), .init("token", .string(token)),
            .init("clientKind", .string("oauth")), .init("unknown", .string("preserved"))])
    }
    /// A GitHub App sign-in: eight-hour token plus a one-time renewal token.
    func rotating(_ token: String) -> NativeRPCValue {
        credential(token).setting("clientKind", .string("github-app")).setting("expiresAt", .number(1_800_000_000_000))
            .setting("refreshToken", .string("fixture-refresh")).setting("refreshExpiresAt", .number(1_810_000_000_000))
    }
    func testVoiceOwnerImportReadbackEndpointConflictAndDamagedFilePreservationWithoutNetwork() async throws {
        let f = try BackendFoundationTestsAccountsFixture()
        do {
            let http = CloudSecretsAppNoVoiceHTTP()
            let voice = try BackendOSVoiceService(userData: f.configuration.dataDirectory, store: f.state,
                cipher: CloudSecretsAppVoiceCipher(), http: http, authorize: { _, _ in })
            try await voice.activate()
            let store = BackendCloudSecretsVoiceStore(sourceId: "voice", owner: voice)
            let provider = try XCTUnwrap(BackendOSVoiceRules.provider("groq"))
            let value = BackendCloudSecretsVoiceValue(provider: provider.id, endpoint: provider.endpoint, key: "fixture-voice-key")
            let row = try BackendCloudSecretsRecords.record("voice", "voice", .app, value)
            check(try await store.merge(row) == .applied)
            check(try await store.verify(row, outcome: .applied))
            check(try await store.capture().count == 1)
            let before = try Data(contentsOf: voice.file)
            let conflict = try BackendCloudSecretsRecords.record("voice", "voice", .app,
                BackendCloudSecretsVoiceValue(provider: provider.id, endpoint: provider.endpoint, key: "different-fixture-key"))
            check(try await store.merge(conflict) == .keptBoth)
            check(try Data(contentsOf: voice.file) == before)
            let wrongEndpoint = try BackendCloudSecretsRecords.record("voice", "voice", .app,
                BackendCloudSecretsVoiceValue(provider: provider.id, endpoint: "https://wrong.invalid", key: value.key))
            do { try await store.validate(wrongEndpoint); check(false) } catch { check(true) }
            let damaged = Data("damaged-voice-fixture".utf8)
            try damaged.write(to: voice.file)
            do { _ = try await store.merge(row); check(false) } catch { check(true) }
            check(try Data(contentsOf: voice.file) == damaged)
            check(await http.calls == 0)
            await f.cleanup()
        } catch { await f.cleanup(); throw error }
    }
    func testGitHubSavedOnlyHostBoundAddOnlyAndMalformedFileNeverOverwritten() async throws {
        let f = try BackendFoundationTestsAccountsFixture()
        do {
            let http = BackendGitHubFixtureHTTP { _ in throw CloudFailure.unavailable }, tools = CloudSecretsAppNoGitHubTools()
            let owner = try BackendGitHubAuthenticator(dataDirectory: f.configuration.dataDirectory, environment: [:],
                http: http, tools: tools, resolveRepo: { _ in .null })
            let store = BackendCloudSecretsGitHubStore(sourceId: "github", owner: owner, requireWriter: {})
            let row = try BackendCloudSecretsRecords.record("github", "github:github.com", .app,
                BackendCloudSecretsGitHubValue(host: "github.com", credential: .init(credential("fixture-github-token"))))
            check(try await store.capture().isEmpty)
            check(try await store.merge(row) == .applied)
            check(try await store.verify(row, outcome: .applied))
            check(try await store.capture().count == 1)
            let file = f.configuration.dataDirectory.appendingPathComponent("github/auth.json"), before = try Data(contentsOf: file)
            let conflict = try BackendCloudSecretsRecords.record("github", "github:github.com", .app,
                BackendCloudSecretsGitHubValue(host: "github.com", credential: .init(credential("different-fixture-token"))))
            check(try await store.merge(conflict) == .keptBoth)
            check(try Data(contentsOf: file) == before)
            let wrongHost = try BackendCloudSecretsRecords.record("github", "github:github.com", .app,
                BackendCloudSecretsGitHubValue(host: "wrong.invalid", credential: .init(credential("fixture-github-token", host: "wrong.invalid"))))
            do { try await store.validate(wrongHost); check(false) } catch { check(true) }
            let damaged = Data("not-json-fixture".utf8)
            try damaged.write(to: file)
            do { _ = try await store.merge(row); check(false) } catch { check(true) }
            check(try Data(contentsOf: file) == damaged)
            check(await http.calls().isEmpty)
            check(await tools.calls == 0)
            await f.cleanup()
        } catch { await f.cleanup(); throw error }
    }
    func testGitHubEnvironmentAndCLISecretsAreNeverCapturedOrReplaced() async throws {
        let f = try BackendFoundationTestsAccountsFixture()
        do {
            let http = BackendGitHubFixtureHTTP { _ in throw CloudFailure.unavailable }, tools = CloudSecretsAppNoGitHubTools()
            let owner = try BackendGitHubAuthenticator(dataDirectory: f.configuration.dataDirectory, environment: ["GH_TOKEN": "fixture-environment-only"],
                http: http, tools: tools, resolveRepo: { _ in .null })
            let store = BackendCloudSecretsGitHubStore(sourceId: "github", owner: owner, requireWriter: {})
            check(try await store.capture().isEmpty)
            let row = try BackendCloudSecretsRecords.record("github", "github:github.com", .app,
                BackendCloudSecretsGitHubValue(host: "github.com", credential: .init(credential("fixture-incoming-token"))))
            check(try await store.merge(row) == .keptBoth)
            check(try await store.verify(row, outcome: .keptBoth))
            check(!FileManager.default.fileExists(atPath: f.configuration.dataDirectory.appendingPathComponent("github/auth.json").path))
            check(await http.calls().isEmpty)
            check(await tools.calls == 0)
            await f.cleanup()
        } catch { await f.cleanup(); throw error }
    }
    func testRotatingGitHubSignInNeverTravelsInEitherDirection() async throws {
        let f = try BackendFoundationTestsAccountsFixture()
        do {
            let http = BackendGitHubFixtureHTTP { _ in throw CloudFailure.unavailable }, tools = CloudSecretsAppNoGitHubTools()
            let owner = try BackendGitHubAuthenticator(dataDirectory: f.configuration.dataDirectory, environment: [:],
                http: http, tools: tools, resolveRepo: { _ in .null })
            let store = BackendCloudSecretsGitHubStore(sourceId: "github", owner: owner, requireWriter: {})
            // A local GitHub App sign-in is not exported: copying its one-time
            // renewal token would sign one of the two Macs out.
            let file = f.configuration.dataDirectory.appendingPathComponent("github/auth.json")
            try BackendAccountFiles.writeAtomic(rotating("fixture-local-token").encodedJSON(pretty: true), to: file)
            check(try await store.capture().isEmpty)
            check(try await store.signInOnEachMac())
            // And an incoming one is refused before any writer runs.
            try FileManager.default.removeItem(at: file)
            let row = try BackendCloudSecretsRecords.record("github", "github:github.com", .app,
                BackendCloudSecretsGitHubValue(host: "github.com", credential: .init(rotating("fixture-incoming-token"))))
            do { try await store.validate(row); check(false) } catch { check(true) }
            check(!FileManager.default.fileExists(atPath: file.path))
            check(await http.calls().isEmpty)
            await f.cleanup()
        } catch { await f.cleanup(); throw error }
    }
}
