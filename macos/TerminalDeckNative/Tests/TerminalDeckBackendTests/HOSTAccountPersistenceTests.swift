import Foundation
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

final class HOSTAccountPersistenceTests: XCTestCase, @unchecked Sendable {
    override func setUpWithError() throws {
    }
    private func fixture() throws -> (URL, BackendAccountConfiguration) {
        let root = URL(fileURLWithPath: "/tmp", isDirectory: true).resolvingSymlinksInPath().appendingPathComponent("tdh-acct-" + UUID().uuidString)
        for name in ["data", "home"] { try FileManager.default.createDirectory(at: root.appendingPathComponent(name), withIntermediateDirectories: true) }
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let configuration = try BackendAccountConfiguration(dataDirectory: root.appendingPathComponent("data"), homeDirectory: root.appendingPathComponent("home"),
            appName: "HOST Scratch Accounts", appID: "terminaldeck", helperExecutable: root.appendingPathComponent("unused-helper"),
            inheritedEnvironment: ["HOME": root.appendingPathComponent("home").path, "USER": "host-fixture"])
        return (root, configuration)
    }
    private func service(_ configuration: BackendAccountConfiguration) async throws -> BackendHOSTAccountService {
        try await BackendHOSTAccountService.start(configuration: configuration, nativeAccountOwnerDisabled: true,
            vaultCipher: HOSTAccountFixtureCipher(), brokerFactory: { configuration, profiles, vault in
                try await BackendAccountBroker.offline(configuration: configuration, profiles: profiles, vault: vault,
                    runner: { _, _ in .init(code: 44, stdout: "", stderr: "") })
            })
    }
    func testUnreleasedNativeOwnerRefusesBeforeAnyAccountMutation() async throws {
        let (_, configuration) = try fixture()
        do {
            _ = try await BackendHOSTAccountService.start(configuration: configuration, nativeAccountOwnerDisabled: false)
            XCTFail("A second account owner must be refused.")
        } catch {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: configuration.dataDirectory.appendingPathComponent("profiles.json").path))
    }
    func testHostAuthorityNeverTakesTheAppsPrimaryStateWriter() async throws {
        let (_, configuration) = try fixture()
        let primary = try NativeStateStore(file: configuration.dataDirectory.appendingPathComponent("state.json"), ownership: .exclusive)
        let owner = try await service(configuration)
        XCTAssertNotEqual(owner.authority.file, primary.file)
        _ = try await primary.setPreferences(.object([.init("hostProof", .bool(true))]))
        let preferences = await primary.getPreferences(); XCTAssertEqual(preferences["hostProof"].bool, true)
        try await owner.stop(afterProcessDrain: true); await primary.close()
    }
    func testDetachKeepsReservationBrokerAndExactAccountEnvironment() async throws {
        let (root, configuration) = try fixture(), owner = try await service(configuration)
        let input = BackendCreateSessionInput(cwd: root.path, provider: "claude")
        let provider = BackendProviderSpec(id: "claude", command: "/bin/cat", args: [], resumeArgs: [])
        let wire = try await owner.resolve(input: input, provider: provider, loginPath: "/usr/bin:/bin", scope: nil)
        let before = await owner.counts(); XCTAssertEqual(before.pending, 1)
        await owner.detachApp()
        let after = await owner.counts(); XCTAssertEqual(after.pending, 1)
        let broker = await owner.accounts.broker, active = await broker.isActive(); XCTAssertTrue(active)
        XCTAssertNotNil(wire.environment[configuration.socketEnvironment])
        XCTAssertNotNil(wire.environment[configuration.ticketEnvironment])
        XCTAssertEqual(wire.launch.environment, wire.environment)
        XCTAssertEqual(wire.launch.removeEnvironment, Set(wire.removeEnvironment))
        await owner.abandon(wire.handle); try await owner.stop(afterProcessDrain: true)
    }
    func testSecondAppResolverUsesSameHostReservationAndSessionPid() async throws {
        let (root, configuration) = try fixture(), owner = try await service(configuration)
        let paths = try BackendHOSTPaths(dataDirectory: configuration.dataDirectory); _ = try paths.secret(create: true)
        let manager = BackendPTYManager(inheritedEnvironment: configuration.inheritedEnvironment, onEvent: { _ in })
        let server = try BackendHOSTServer(paths: paths, hostVersion: "account-fixture", manager: manager,
            launch: { $0.metadata }, snapshot: { _ in nil }, onIdle: {}, resource: { method, payload in try await owner.invoke(method, payload: payload, manager: manager) })
        defer { server.stopListening(); manager.beginShutdown() }
        let first = try await BackendHOSTAccountResolver(client: BackendHOSTClient(paths: paths))
        let input = BackendCreateSessionInput(cwd: root.path, provider: "claude"), provider = BackendProviderSpec(id: "claude", command: "/bin/cat", args: [], resumeArgs: [])
        let account = try await first.resolve(input, provider: provider, loginPath: "/usr/bin:/bin", context: .init())
        let meta = try manager.create(input, spawn: .init(provider: "claude", command: "/bin/cat", args: [], path: account.path,
            env: account.environment, removeEnv: account.removeEnvironment, profile: account.profile, homeProfileId: account.homeProfileID))
        let pid = try XCTUnwrap(manager.pidOf(meta.id)); try await first.bind(account, session: meta)
        await owner.detachApp()
        let replacement = try await BackendHOSTAccountResolver(client: BackendHOSTClient(paths: paths))
        try await replacement.bind(account, session: meta) // Same handle, idempotent.
        XCTAssertEqual(manager.pidOf(meta.id), pid)
        let broker = await owner.accounts.broker, seat = await broker.seatSnapshot(sessionID: meta.id)
        XCTAssertEqual(seat?.processPID, pid)
        manager.beginShutdown(); let drained = await manager.drain(); XCTAssertTrue(drained)
        await replacement.exited(sessionID: meta.id); try await owner.stop(afterProcessDrain: drained)
    }
    func testUnconfirmedDrainCannotDestroyAccountLeases() async throws {
        let (_, configuration) = try fixture(), owner = try await service(configuration)
        do { try await owner.stop(afterProcessDrain: false); XCTFail("Stop without drain must fail.") } catch {}
        let broker = await owner.accounts.broker, active = await broker.isActive(); XCTAssertTrue(active)
        try await owner.stop(afterProcessDrain: true); let closed = await broker.isActive(); XCTAssertFalse(closed)
    }
}

/// Scratch-only reversible fixture cipher; never selected by production.
private struct HOSTAccountFixtureCipher: BackendAccountVaultCipher {
    private static let prefix = Data("HOST-fixture:".utf8)
    func available() -> Bool { true }
    func prepareForWrites(existingVault: Bool) throws {}
    func encrypt(_ text: String, existingVault: Bool) throws -> Data { Self.prefix + Data(Data(text.utf8).reversed()) }
    func decrypt(_ data: Data) throws -> String {
        guard data.starts(with: Self.prefix) else { throw BackendAccountFailure("Invalid scratch ciphertext.") }
        return String(decoding: Data(data.dropFirst(Self.prefix.count).reversed()), as: UTF8.self)
    }
}
