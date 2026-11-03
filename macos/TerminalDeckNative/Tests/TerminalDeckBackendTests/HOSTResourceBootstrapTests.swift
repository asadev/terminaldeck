import Foundation
import Darwin
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

final class HOSTResourceBootstrapTests: XCTestCase, @unchecked Sendable {
    override func setUpWithError() throws {
    }
    private struct Fixture: Sendable {
        var root: URL
        var paths: BackendHOSTPaths
        var manager: BackendPTYManager
        var host: BackendHOSTProtocol.Hello
        var dto: BackendHOSTConfiguration
    }
    private func fixture() throws -> Fixture {
        let root = URL(fileURLWithPath: "/tmp", isDirectory: true).resolvingSymlinksInPath().appendingPathComponent("tdh-boot-" + UUID().uuidString)
        let data = root.appendingPathComponent("data"), home = root.appendingPathComponent("home")
        for folder in [data, home] { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let paths = try BackendHOSTPaths(dataDirectory: data); _ = try paths.secret(create: true)
        let version = paths.directory.appendingPathComponent("bootstrap-v1")
        try BackendHOSTFiles.privateDirectory(version)
        let helper = version.appendingPathComponent("TerminalDeckNativeHelper")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/usr/bin/true"), to: helper); XCTAssertEqual(chmod(helper.path, 0o700), 0)
        let config = try BackendAccountConfiguration(dataDirectory: data, homeDirectory: home, appName: "HOST Scratch Bootstrap", appID: "terminaldeck",
            helperExecutable: helper, inheritedEnvironment: ["HOME": home.path, "USER": "bootstrap-fixture", "UNCHANGED_VALUE": "private fixture value"])
        let tool = try BackendMCPTool(id: "fixture.read", wireName: "fixture_read", description: "Owned bootstrap read.",
            inputSchema: .object([.init("type", .string("object")), .init("properties", .object([]))]), tier: .read)
        return .init(root: root, paths: paths, manager: BackendPTYManager(inheritedEnvironment: [:], onEvent: { _ in }),
            host: .init(protocolVersion: BackendHOSTProtocol.version, hostVersion: "bootstrap-v1", hostPID: getpid(), instance: UUID()),
            dto: try .init(configuration: config, tools: [tool]))
    }
    private func validationFactory(_ fixture: Fixture) -> BackendHOSTRuntime.ResourceFactory {
        BackendHOSTResourceFactory.make(paths: fixture.paths, manager: fixture.manager, nativeAccountOwnerDisabled: true,
            makeHookCoordinator: { _ in .observerOnlyForTesting() }, peerBelongs: { peer, root in peer == root },
            callbacks: .init(verifyClaims: { _ in throw BackendHOSTFailure.unavailable }, confirmDescendants: { _ in throw BackendHOSTFailure.unavailable },
                metadataChanged: { _ in }, additionalContext: { _ in throw BackendHOSTFailure.unavailable }),
            vaultCipher: HOSTBootstrapCipher(), brokerFactory: { config, profiles, vault in
                try await BackendAccountBroker.offline(configuration: config, profiles: profiles, vault: vault,
                    runner: { _, _ in .init(code: 44, stdout: "", stderr: "") })
            })
    }
    func testInvalidEnvironmentRefusesBeforeOpeningAccountOrHookOwners() async throws {
        let fixture = try fixture(), make = validationFactory(fixture)
        var dto = fixture.dto; dto.environment["bad\0name"] = "value"
        do { _ = try await make(JSONEncoder().encode(dto), fixture.host); XCTFail("Invalid private env must be refused.") } catch {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.paths.directory.deletingLastPathComponent().appendingPathComponent("profiles.json").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.paths.directory.deletingLastPathComponent().appendingPathComponent("hook/hook.sock").path))
    }
    func testSymlinkPinnedHelperRefusesBeforeResourceMutation() async throws {
        let fixture = try fixture(), make = validationFactory(fixture)
        let helper = fixture.paths.directory.appendingPathComponent("bootstrap-v1/TerminalDeckNativeHelper")
        try FileManager.default.removeItem(at: helper); XCTAssertEqual(symlink("/usr/bin/true", helper.path), 0)
        do { _ = try await make(JSONEncoder().encode(fixture.dto), fixture.host); XCTFail("A helper symlink cannot be pinned.") } catch {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.paths.directory.deletingLastPathComponent().appendingPathComponent(".host-account-authority.json").path))
    }

    #if TD_HOST_INTEGRATED
    private func owner(_ fixture: Fixture, confirmDescendants: (@Sendable (String) async throws -> Bool)? = nil) async throws -> BackendHOSTResources {
        let make = BackendHOSTResourceFactory.makeUsingAppRelay(paths: fixture.paths, manager: fixture.manager, nativeAccountOwnerDisabled: true,
            makeHookCoordinator: { BackendSessionHookCoordinator(hostedReceiver: $0) }, peerBelongs: BackendSessionHookCoordinator.hostedPeerBelongs,
            confirmDescendants: confirmDescendants ?? { id in fixture.manager.pidOf(id) == nil }, metadataChanged: { _ in },
            vaultCipher: HOSTBootstrapCipher(), brokerFactory: { config, profiles, vault in
                try await BackendAccountBroker.offline(configuration: config, profiles: profiles, vault: vault,
                    runner: { _, _ in .init(code: 44, stdout: "", stderr: "") })
            })
        let owner = try await make(JSONEncoder().encode(fixture.dto), fixture.host)
        addTeardownBlock { try await owner.stop() }
        return owner
    }
    func testDirectActualResourceGraphPinsHelperAndKeepsEndpointAndFilesAcrossDetach() async throws {
        let fixture = try fixture(), owner = try await owner(fixture)
        XCTAssertEqual(owner.accounts.configuration.helperExecutable.lastPathComponent, "TerminalDeckNativeHelper")
        XCTAssertEqual(owner.accounts.configuration.helperExecutable.deletingLastPathComponent().lastPathComponent, fixture.host.hostVersion)
        XCTAssertEqual(owner.accounts.configuration.inheritedEnvironment, fixture.dto.environment)
        let prepared = try await owner.mcp.sessionTools.prepare(serverName: "deck-control", allowed: ["fixture.read"], projectRoot: fixture.root.path)
        try await owner.mcp.sessionTools.bind(prepared.id, sessionID: UUID().uuidString)
        let file = URL(fileURLWithPath: try XCTUnwrap(prepared.arguments.last)), before = try Data(contentsOf: file)
        let endpoint = try await owner.mcp.start(); let hook = try await owner.hooks.endpoint()
        await owner.detachApp()
        let afterEndpoint = try await owner.mcp.start(), afterHook = try await owner.hooks.endpoint()
        XCTAssertEqual(afterEndpoint.url, endpoint.url); XCTAssertEqual(afterHook.socketPath, hook.socketPath)
        XCTAssertEqual(try Data(contentsOf: file), before)
        let ready = await owner.readiness(); XCTAssertFalse(ready.taskAndReceiverClaims)
    }
    func testDisconnectedOrMissingControlHandlerNeverMarksClaimsReady() async throws {
        let fixture = try fixture(), owner = try await owner(fixture)
        let payload = try NativeRPCValue.object([.init("ids", .array([]))]).encodedJSON()
        do { _ = try await owner.invoke("resources.adopted", payload: payload); XCTFail("Disconnected app must not imply adoption.") } catch {}
        let app = try BackendHOSTAppRelayClient(paths: fixture.paths, host: fixture.host, handler: { _ in .failure("No scratch MCP call expected.") })
        addTeardownBlock { app.detach() }
        do { _ = try await owner.invoke("resources.adopted", payload: payload); XCTFail("Unsupported control handler must not imply adoption.") } catch {}
        let ready = await owner.readiness(); XCTAssertFalse(ready.taskAndReceiverClaims)
    }
    func testActualPrivateControlVerifierRequiredAndAbsentFromMcpCatalogue() async throws {
        let fixture = try fixture(), owner = try await owner(fixture), calls = HOSTBootstrapClaimCalls()
        let app = try BackendHOSTAppRelayClient(paths: fixture.paths, host: fixture.host, handler: { _ in .failure("No scratch MCP call expected.") })
        addTeardownBlock { app.detach() }
        BackendHOSTResourceFactory.installAppControls(client: app, controls: .init(verifyClaims: { sessions, cancellation in
            guard !cancellation.isCancelled else { throw CancellationError() }; calls.hit(); return sessions.isEmpty
        }, hookContext: { _, _ in nil }, openLink: { _, _, _ in throw BackendHOSTFailure.unavailable }))
        _ = try await owner.invoke("resources.adopted", payload: NativeRPCValue.object([.init("ids", .array([]))]).encodedJSON())
        let ready = await owner.readiness(); XCTAssertTrue(ready.taskAndReceiverClaims); XCTAssertEqual(calls.count, 1)
        let tools = try await owner.mcp.endpoint.catalogue(); XCTAssertEqual(tools.map(\.id), ["fixture.read"])
        XCTAssertFalse(tools.contains { $0.id == "claims.verify" || $0.id == "hooks.context" || $0.id == "hooks.open" })
    }
    // #80 (18 Oct): a session that ends while a helper it started still runs keeps its seat and files only until the
    // helper has gone; the exit is tried again (here on the next exit), not dropped until the whole host stops.
    func testExitWithARunningHelperIsReleasedOnceTheHelperEnds() async throws {
        let fixture = try fixture(), helperGone = HOSTBootstrapFlag()
        let owner = try await owner(fixture, confirmDescendants: { id in helperGone.value && fixture.manager.pidOf(id) == nil })
        let spawn = BackendSpawnSpec(provider: "shell", command: "/bin/sh", args: ["-c", "read line"], path: "/usr/bin:/bin")
        let first = try fixture.manager.create(.init(cwd: fixture.root.path, provider: "shell"), spawn: spawn)
        let prepared = try await owner.mcp.sessionTools.prepare(serverName: "deck-control", allowed: ["fixture.read"], projectRoot: fixture.root.path)
        try await owner.mcp.sessionTools.bind(prepared.id, sessionID: first.id)
        try fixture.manager.write(first.id, data: "end\n")
        let ended = await eventually { fixture.manager.pidOf(first.id) == nil }
        XCTAssertTrue(ended)
        try await Task.sleep(nanoseconds: 300_000_000)
        let heldWhileHelperRuns = await owner.mcp.sessionTools.count
        XCTAssertEqual(heldWhileHelperRuns, 1)
        helperGone.set()
        let second = try fixture.manager.create(.init(cwd: fixture.root.path, provider: "shell"), spawn: spawn)
        try fixture.manager.write(second.id, data: "end\n")
        let released = await eventually { await owner.mcp.sessionTools.count == 0 }
        XCTAssertTrue(released, "the earlier exit was never released")
    }
    private func eventually(_ condition: @Sendable () async -> Bool) async -> Bool {
        for _ in 0..<100 { if await condition() { return true }; try? await Task.sleep(nanoseconds: 50_000_000) }
        return false
    }
    #endif
}
private final class HOSTBootstrapFlag: @unchecked Sendable {
    private let lock = NSLock(); private var on = false
    func set() { lock.withLock { on = true } }; var value: Bool { lock.withLock { on } }
}
private final class HOSTBootstrapClaimCalls: @unchecked Sendable {
    private let lock = NSLock(); private var total = 0
    func hit() { lock.withLock { total += 1 } }; var count: Int { lock.withLock { total } }
}
private struct HOSTBootstrapCipher: BackendAccountVaultCipher {
    private static let prefix = Data("HOST-bootstrap-fixture:".utf8)
    func available() -> Bool { true }
    func prepareForWrites(existingVault: Bool) throws {}
    func encrypt(_ text: String, existingVault: Bool) throws -> Data { Self.prefix + Data(Data(text.utf8).reversed()) }
    func decrypt(_ data: Data) throws -> String {
        guard data.starts(with: Self.prefix) else { throw BackendAccountFailure("Invalid scratch ciphertext.") }
        return String(decoding: Data(data.dropFirst(Self.prefix.count).reversed()), as: UTF8.self)
    }
}
