import Foundation
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

final class GeminiAPIAccountProfilesTests: XCTestCase, @unchecked Sendable {
    private let apiID = "api-key-" + String(repeating: "a", count: 24)
    private func withRuntime(_ body: (BackendF4Runtime) async throws -> Void) async throws {
        let root = try BackendF4Runtime.makeRoot().resolvingSymlinksInPath()
        let r = try await BackendF4Runtime.wire(root: root, environment: ["USER": "me",
            "GEMINI_CLI_SYSTEM_SETTINGS_PATH": root.appendingPathComponent("system-settings.json").path,
            "GEMINI_CLI_SYSTEM_DEFAULTS_PATH": root.appendingPathComponent("system-defaults.json").path])
        do { try await body(r) } catch { await r.dispose(removeRoot: true); throw error }
        await r.dispose(removeRoot: true)
    }
    /// The same profiles:create route used by the hosted API service's access.create callback.
    private func create(_ r: BackendF4Runtime) async throws -> BackendAccountProfile {
        let raw = try await r.rpc.invoke("profiles:create", args: [.string(apiID), .object([
            .init("provider", .string("gemini")), .init("configDir", .string(r.configuration.accountLoginsRoot.appendingPathComponent("api-gemini").path))
        ])], context: BackendF4Runtime.context)
        return try JSONDecoder().decode(BackendAccountProfile.self, from: raw.encodedJSON())
    }

    func testGeminiAPIBootstrapSaveReloadAndResolutionKeepTheIsolatedAccount() async throws { try await withRuntime { r in
        let created = try await create(r), store = await r.profiles
        let profile = try await store.rename(id: created.id, name: "Gemini API")
        let record = try BackendAPIAccountRecord(profile: profile, appName: r.configuration.appName, kind: .gemini, baseURL: nil, model: "fixture-model")
        try record.save(); try BackendAPIAccountCLI.configure(record)
        XCTAssertFalse(BackendAccountStrategies.supportsAccounts("gemini"), "OAuth keeps its existing one-login rule")
        let raw = try await r.rpc.invoke("profiles:resolve", args: [.object([
            .init("sessionProfileId", .string(profile.id)), .init("provider", .string("gemini"))
        ])], context: BackendF4Runtime.context)
        XCTAssertEqual(raw["id"].string, profile.id)
        try await store.setLevel(.app, provider: "gemini", id: profile.id)
        await store.close()
        let reloaded = try BackendAccountProfileStore(configuration: r.configuration, stateStore: r.state)
        do {
            let restored = try await reloaded.resolve(sessionProfileID: nil, projectPath: nil, provider: "gemini")
            XCTAssertEqual(restored.id, profile.id); XCTAssertEqual(restored.configDir, profile.configDir)
            XCTAssertEqual(try BackendAPIAccountRecord.read(restored), record)
            let list = try await reloaded.list(provider: "gemini")
            XCTAssertEqual(list.map(\.id), ["system:gemini", profile.id])
            try await reloaded.setLevel(.app, provider: "gemini", id: nil)
            let own = try await reloaded.resolve(sessionProfileID: nil, projectPath: nil, provider: "gemini")
            XCTAssertEqual(own.id, "system:gemini")
        } catch { await reloaded.close(); throw error }
        await reloaded.close()
    } }

    func testOrdinaryGeminiAndUnsafeAPIProfilesRemainRejected() async throws { try await withRuntime { r in
        let store = await r.profiles
        for (name, provider, directory) in [
            ("Another Google login", "gemini", r.configuration.accountLoginsRoot.appendingPathComponent("ordinary").path),
            (apiID, "gemini", r.root.appendingPathComponent("outside").path),
            (apiID, "shell", r.configuration.accountLoginsRoot.appendingPathComponent("shell-api").path)
        ] {
            do { _ = try await store.create(name: name, provider: provider, configDir: directory, vaultManaged: false); XCTFail("An unverified account route was accepted") }
            catch { let snapshot = try await store.snapshot(); XCTAssertTrue(snapshot.profiles.isEmpty) }
        }
        let good = try await create(r)
        let unsafe = BackendAccountProfile(id: "api-key-" + String(repeating: "b", count: 24), name: "Outside", provider: "gemini",
            configDir: r.root.appendingPathComponent("outside").path, system: false, color: "", createdAt: 0)
        let ordinary = BackendAccountProfile(id: "ordinary-google", name: "OAuth", provider: "gemini",
            configDir: r.configuration.accountLoginsRoot.appendingPathComponent("ordinary").path, system: false, color: "", createdAt: 0)
        await store.close()
        let values = try [good, unsafe, ordinary].map { try NativeRPCValue.parseJSON(JSONEncoder().encode($0)) }
        try NativeRPCValue.object([.init("profiles", .array(values))]).encodedJSON().write(to: r.configuration.dataDirectory.appendingPathComponent("profiles.json"))
        let reloaded = try BackendAccountProfileStore(configuration: r.configuration, stateStore: r.state)
        do {
            let snapshot = try await reloaded.snapshot(); XCTAssertEqual(snapshot.profiles.map(\.id), [good.id])
            do { _ = try await reloaded.resolve(sessionProfileID: unsafe.id, projectPath: nil, provider: "gemini"); XCTFail("A rejected API ID fell back to the machine's login") }
            catch { XCTAssertTrue(error.localizedDescription.contains("No other account was used")) }
        } catch { await reloaded.close(); throw error }
        await reloaded.close()
    } }

    private struct Providers: BackendProviderLaunchResolver {
        let command: String
        let readiness: BackendLaunchReadiness = .ready
        func loginPath() async throws -> String { "/usr/bin:/bin" }
        func resolve(_ input: BackendCreateSessionInput, loginPath: String) async throws -> BackendProviderSpec {
            .init(id: "gemini", command: command, args: [], resumeArgs: [])
        }
    }
    private final class FactsProbe: BackendAppSessionCommandExecuting, @unchecked Sendable {
        private let lock = NSLock()
        private var values: [[String: String]] = []
        var environments: [[String: String]] { lock.withLock { values } }
        func run(_ command: String, arguments: [String], environment: [String: String], cwd: String, timeoutMilliseconds: Int, maximumBytes: Int) async -> BackendAppSessionCommandResult {
            lock.withLock { values.append(environment) }
            return .init(stdout: "Gemini CLI --model --sandbox", exitCode: 0)
        }
        func detach(_ command: String, arguments: [String], environment: [String: String], cwd: String) async throws { XCTFail("An account facts read must not launch an agent") }
    }
    func testGeminiAPIFactsReadOnlyItsSelectedConfigRoot() async throws { try await withRuntime { r in
        let profile = try await create(r), store = await r.profiles
        let record = try BackendAPIAccountRecord(profile: profile, appName: r.configuration.appName, kind: .gemini, baseURL: nil, model: nil)
        try record.save(); try BackendAPIAccountCLI.configure(record)
        let binary = r.root.appendingPathComponent("gemini-fixture")
        try Data("#!/bin/sh\nexit 97\n".utf8).write(to: binary)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
        let probe = FactsProbe()
        let facts = BackendAGSSelectedAccountFacts(providers: Providers(command: binary.path), profiles: store, configuration: r.configuration, projectRoot: { $0 }, command: probe)
        var input = BackendCreateSessionInput(cwd: r.root.path, provider: "gemini"); input.profileId = profile.id
        let snapshot = try await facts.capture(input, context: .init())
        XCTAssertEqual(snapshot.account.id, profile.id)
        XCTAssertEqual(snapshot.environment["GEMINI_CLI_HOME"], profile.configDir)
        XCTAssertEqual(probe.environments.count, 1)
        XCTAssertEqual(probe.environments.first?["GEMINI_CLI_HOME"], profile.configDir)
        XCTAssertNil(snapshot.environment["GEMINI_API_KEY"], "Facts do not expose the credential")
    } }

    func testMissingOrInvalidGeminiAPIRecordCannotFallBackToTheMachineLogin() async throws { try await withRuntime { r in
        let profile = try await create(r)
        var input = BackendCreateSessionInput(cwd: r.root.path, provider: "gemini"); input.profileId = profile.id
        let spec = BackendProviderSpec(id: "gemini", command: "/never-run/gemini", args: [], resumeArgs: [])
        for bytes in [Data?](arrayLiteral: nil, Data("invalid settings".utf8)) {
            if let bytes { try bytes.write(to: URL(fileURLWithPath: profile.configDir).appendingPathComponent(BackendAPIAccountRecord.fileName)) }
            do { _ = try await r.adapter.resolve(input, provider: spec, loginPath: "/usr/bin:/bin", context: .init()); XCTFail("An incomplete API account launched") }
            catch { XCTAssertFalse(error.localizedDescription.isEmpty) }
        }
        let store = await r.profiles
        do { _ = try await store.resolve(sessionProfileID: "api-key-" + String(repeating: "f", count: 24), projectPath: nil, provider: "gemini"); XCTFail("A missing API account fell back to system") }
        catch { XCTAssertTrue(error.localizedDescription.contains("No other account was used")) }
    } }
}
