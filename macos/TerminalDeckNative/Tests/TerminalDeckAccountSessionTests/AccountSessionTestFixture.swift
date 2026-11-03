import Foundation
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

/// Every path belongs to this test. No installed app, real login, helper or Keychain is opened.
struct AccountSessionTestFixture: Sendable {
    let root: URL
    let configuration: BackendAccountConfiguration
    let state: NativeStateStore
    let profiles: BackendAccountProfileStore

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("account-session-" + UUID().uuidString)
        let data = root.appendingPathComponent("data"), home = root.appendingPathComponent("home")
        try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        configuration = try .init(dataDirectory: data, homeDirectory: home, appName: "Account Session Fixture", appID: "terminaldeck",
                                  helperExecutable: root.appendingPathComponent("never-run-helper"), inheritedEnvironment: [:])
        state = try NativeStateStore(file: data.appendingPathComponent("state.json"), ownership: .exclusive)
        profiles = try BackendAccountProfileStore(configuration: configuration, stateStore: state)
    }
    func create(_ name: String, provider: String = "claude") async throws -> BackendAccountProfile {
        try await profiles.create(name: name, provider: provider, configDir: nil, vaultManaged: false)
    }
    func profile(_ id: String) -> BackendAccountProfile {
        .init(id: id, name: id, provider: "claude", configDir: configuration.profilesRoot.appendingPathComponent(id).path,
              system: false, color: "--accent", createdAt: 0)
    }
    func close() async {
        await profiles.close(); await state.close()
        try? FileManager.default.removeItem(at: root)
    }
}

func withAccountSessionFixture(_ body: (AccountSessionTestFixture) async throws -> Void) async throws {
    let fixture = try AccountSessionTestFixture()
    do { try await body(fixture) }
    catch { await fixture.close(); throw error }
    await fixture.close()
}
