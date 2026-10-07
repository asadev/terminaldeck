import Foundation
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

/// All fixture paths are beneath a fresh temporary root. This fixture never
/// creates a cipher, starts a broker/helper, or asks the real Keychain.
struct BackendFoundationTestsAccountsFixture: Sendable {
    let root: URL
    let configuration: BackendAccountConfiguration
    let state: NativeStateStore
    let profiles: BackendAccountProfileStore

    init(rawProfiles: NativeRPCValue? = nil, environment: [String: String] = [:]) throws {
        let temporaryRoot = FileManager.default.temporaryDirectory.appendingPathComponent("td-foundation-accounts-" + UUID().uuidString)
        do {
            let data = temporaryRoot.appendingPathComponent("data"), home = temporaryRoot.appendingPathComponent("home")
            try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
            if let rawProfiles { try rawProfiles.encodedJSON().write(to: data.appendingPathComponent("profiles.json")) }
            let config = try BackendAccountConfiguration(dataDirectory: data, homeDirectory: home, appName: "Terminal Deck Fixture", appID: "terminaldeck", helperExecutable: temporaryRoot.appendingPathComponent("never-run-helper"), inheritedEnvironment: environment)
            let stateStore = try NativeStateStore(file: data.appendingPathComponent("state.json"), ownership: .exclusive, clock: { 1_000 })
            let profileStore = try BackendAccountProfileStore(configuration: config, stateStore: stateStore)
            root = temporaryRoot; configuration = config; state = stateStore; profiles = profileStore
        } catch {
            try? FileManager.default.removeItem(at: temporaryRoot)
            throw error
        }
    }
    func cleanup() async {
        await profiles.close()
        await state.close()
        try? FileManager.default.removeItem(at: root)
    }
    func profile(_ id: String, provider: String = "claude", system: Bool = false) -> BackendAccountProfile {
        .init(id: id, name: id, provider: provider, configDir: configuration.profilesRoot.appendingPathComponent(id).path, system: system, color: "--accent", createdAt: 1, lastUsedAt: nil, loginStore: nil, keptSlots: nil)
    }
    func create(_ name: String, provider: String = "claude", directory: String? = nil) async throws -> BackendAccountProfile {
        try await profiles.create(name: name, provider: provider, configDir: directory, vaultManaged: false)
    }
    func disk() throws -> NativeRPCValue {
        try .parseJSON(Data(contentsOf: configuration.dataDirectory.appendingPathComponent("profiles.json")))
    }
}

func BackendFoundationTestsAccountsWithFixture<T>(raw: NativeRPCValue? = nil, environment: [String: String] = [:], _ body: (BackendFoundationTestsAccountsFixture) async throws -> T) async throws -> T {
    let fixture = try BackendFoundationTestsAccountsFixture(rawProfiles: raw, environment: environment)
    do { let result = try await body(fixture); await fixture.cleanup(); return result }
    catch { await fixture.cleanup(); throw error }
}

func BackendFoundationTestsAccountsObject(_ fields: [(String, NativeRPCValue)]) -> NativeRPCValue {
    .object(fields.map { .init($0.0, $0.1) })
}
func BackendFoundationTestsAccountsRawProfile(_ id: String, name: String? = nil, provider: String = "claude", directory: String? = nil, system: Bool = false) -> NativeRPCValue {
    BackendFoundationTestsAccountsObject([("id", .string(id)), ("name", .string(name ?? id)), ("provider", .string(provider)), ("configDir", .string(directory ?? "/tmp/foundation-profiles/" + id)), ("system", .bool(system)), ("createdAt", .number(1))])
}
func BackendFoundationTestsAccountsRaw(_ fields: [(String, NativeRPCValue)] = []) -> NativeRPCValue {
    BackendFoundationTestsAccountsObject([("version", .number(1)), ("profiles", .array([BackendFoundationTestsAccountsRawProfile("work"), BackendFoundationTestsAccountsRawProfile("personal")]))] + fields)
}

func BackendFoundationTestsAccountsExpectError(_ fragment: String, file: StaticString = #filePath, line: UInt = #line, _ work: () async throws -> Void) async {
    do { try await work(); XCTFail("Expected refusal containing: " + fragment, file: file, line: line) }
    catch { XCTAssertTrue(error.localizedDescription.contains(fragment), "Expected source refusal containing '\(fragment)', got '\(error.localizedDescription)'", file: file, line: line) }
}

/// Reload a deliberately malformed/old profile fixture with the real store.
func BackendFoundationTestsAccountsWithReloadedProfiles<T>(_ fixture: BackendFoundationTestsAccountsFixture, bytes: Data, _ body: (BackendAccountProfileStore) async throws -> T) async throws -> T {
    await fixture.profiles.close()
    try bytes.write(to: fixture.configuration.dataDirectory.appendingPathComponent("profiles.json"))
    let reloaded = try BackendAccountProfileStore(configuration: fixture.configuration, stateStore: fixture.state)
    do { let result = try await body(reloaded); await reloaded.close(); return result }
    catch { await reloaded.close(); throw error }
}
