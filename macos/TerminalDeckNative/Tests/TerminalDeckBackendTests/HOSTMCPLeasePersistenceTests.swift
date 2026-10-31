import Foundation
import Darwin
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

final class HOSTMCPLeasePersistenceTests: XCTestCase, @unchecked Sendable {
    override func setUpWithError() throws {
    }
    private struct Fixture: Sendable {
        let root: URL, paths: BackendHOSTPaths
        let host: BackendHOSTProtocol.Hello
        let owner: BackendHOSTMCPPersistence
    }
    private func fixture() async throws -> Fixture {
        let root = URL(fileURLWithPath: "/tmp", isDirectory: true).resolvingSymlinksInPath().appendingPathComponent("tdh-lease-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let paths = try BackendHOSTPaths(dataDirectory: root); _ = try paths.secret(create: true)
        let host = BackendHOSTProtocol.Hello(protocolVersion: BackendHOSTProtocol.version, hostVersion: "lease-fixture", hostPID: getpid(), instance: UUID())
        let relay = try BackendHOSTAppRelayServer(paths: paths, host: host)
        let owner = try BackendHOSTMCPPersistence(server: BackendNativeMCPServer(), relay: relay, userData: root, sessionsDrained: { true })
        addTeardownBlock { try await owner.stopAfterSessionsDrained() }
        let schema: NativeRPCValue = .object([.init("type", .string("object")), .init("properties", .object([]))])
        let browser = try BackendMCPTool(id: "browser.read", wireName: "browser_read", description: "Scratch lease read.", inputSchema: schema, tier: .read)
        let project = try BackendMCPTool(id: "project.read", wireName: "project_read", description: "Scratch project read.", inputSchema: schema, tier: .read)
        try await owner.installTools([browser, project]); _ = try await owner.start()
        return .init(root: root, paths: paths, host: host, owner: owner)
    }
    private func ordinary(_ fixture: Fixture) async throws -> BackendPreparedToolLease {
        let value = try await fixture.owner.prepareOrdinary(restricting: nil, deniedTools: [])
        return try XCTUnwrap(value)
    }
    private func refused(_ action: () async throws -> Void) async {
        do { try await action(); XCTFail("Changed or invalid lease ownership must be refused.") } catch {}
    }
    private func definition(_ fixture: Fixture) throws -> BackendHOSTProjectDefinition {
        // Config-only fixture. These tests never execute a stdio child.
        let spec = try BackendProjectMCPServerSpec(name: "staysfixed", command: "/usr/bin/true", arguments: ["scratch-config-only"],
            environment: ["PRESERVED_ARGUMENT_ENV": "value with spaces"], implementation: .suppliedSourceBridge)
        return try .init(.stdio(root: fixture.root.path, server: spec))
    }
    func testPreExecAndPostCreateExactBindShareOneActualCaller() async throws {
        let fixture = try await fixture(), lease = try await ordinary(fixture), session = UUID().uuidString
        let before = try Data(contentsOf: URL(fileURLWithPath: lease.arguments.last!))
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<12 { group.addTask { try await fixture.owner.bindPrepared(lease.id, sessionID: session, machineID: "scratch-machine") } }
            try await group.waitForAll()
        }
        let projection = await fixture.owner.projection()
        XCTAssertEqual(projection.callerCount, 1); XCTAssertEqual(projection.leaseCount, 1)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: lease.arguments.last!)), before)
        await refused { try await fixture.owner.bindPrepared(lease.id, sessionID: session, machineID: "different-machine") }
        await refused { try await fixture.owner.bindPrepared(lease.id, sessionID: UUID().uuidString, machineID: "scratch-machine") }
    }
    func testRapidExitReceiptAcknowledgesWithoutRestoringDeletedCallerOrConfig() async throws {
        let fixture = try await fixture(), lease = try await ordinary(fixture), session = UUID().uuidString
        try await fixture.owner.bindPrepared(lease.id, sessionID: session, machineID: "same-machine")
        await fixture.owner.releasePrepared(sessionID: session)
        try await fixture.owner.bindPrepared(lease.id, sessionID: session, machineID: "same-machine")
        let projection = await fixture.owner.projection()
        XCTAssertEqual(projection.callerCount, 0); XCTAssertEqual(projection.leaseCount, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: lease.arguments.last!))
        await refused { try await fixture.owner.bindPrepared(lease.id, sessionID: session, machineID: "other-machine") }
    }
    func testActualAGSFilesBindAfterPreExecKeepRealMachineAndSurviveDetach() async throws {
        let fixture = try await fixture(), lease = try await fixture.owner.reserveAgentSettingsFiles(), session = UUID().uuidString
        let bytes = Data("{\"scratch\":true}".utf8), file = lease.directory.appendingPathComponent("ags-claude.json")
        try await lease.write([file.lastPathComponent: bytes])
        let attrs = try FileManager.default.attributesOfItem(atPath: file.path)
        XCTAssertEqual((attrs[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        try await fixture.owner.bindPrepared(lease.id, sessionID: session, machineID: "real-ags-machine")
        try await lease.bind(session); try await lease.bind(session)
        let app = try BackendHOSTAppRelayClient(paths: fixture.paths, host: fixture.host, handler: { _ in .failure("No fixture tool call.") })
        app.detach()
        XCTAssertEqual(try Data(contentsOf: file), bytes)
        await refused { try await fixture.owner.bindPrepared(lease.id, sessionID: session, machineID: "") }
        await refused { try await lease.write(["ags-after-bind.json": bytes]) }
        await fixture.owner.releasePrepared(sessionID: session)
        try await lease.bind(session)
        XCTAssertFalse(FileManager.default.fileExists(atPath: lease.directory.path))
    }
    func testAGSPathTraversalDuplicateWriteAndUnknownLeaseRefuse() async throws {
        let fixture = try await fixture(), lease = try await fixture.owner.reserveAgentSettingsFiles()
        let bytes = Data("{}".utf8)
        await refused { try await lease.write(["ags-../escape.json": bytes]) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("escape.json").path))
        try await lease.write(["ags-settings.json": bytes])
        await refused { try await lease.write(["ags-settings.json": bytes]) }
        await refused { try await fixture.owner.writeAgentSettingsFiles(UUID(), files: ["ags-unknown.json": bytes]) }
        await lease.abandon()
        XCTAssertFalse(FileManager.default.fileExists(atPath: lease.directory.path))
    }
    func testOriginalResolvedProjectSpecKeepsConfigAndEnvironmentAcrossDetach() async throws {
        let fixture = try await fixture(), definition = try definition(fixture), session = UUID().uuidString
        let value = try await fixture.owner.prepareProject(definition: definition, provider: "claude", cwd: fixture.root.path, loginPath: "/usr/bin:/bin", machineID: "project-machine")
        let lease = try XCTUnwrap(value), file = URL(fileURLWithPath: try XCTUnwrap(lease.arguments.last))
        let bytes = try Data(contentsOf: file), config = try await fixture.owner.projectAgentSettingsConfiguration(lease.id)
        XCTAssertEqual(config["staysfixed"]["command"].string, definition.command)
        XCTAssertEqual(config["staysfixed"]["args"].elements?.compactMap(\.string), definition.arguments)
        XCTAssertEqual(config["staysfixed"]["env"]["PRESERVED_ARGUMENT_ENV"].string, "value with spaces")
        try await fixture.owner.bindPrepared(lease.id, sessionID: session, machineID: "project-machine")
        let app = try BackendHOSTAppRelayClient(paths: fixture.paths, host: fixture.host, handler: { _ in .failure("No fixture tool call.") })
        app.detach()
        try await fixture.owner.bindPrepared(lease.id, sessionID: session, machineID: "project-machine")
        XCTAssertEqual(try Data(contentsOf: file), bytes)
        await refused { try await fixture.owner.bindPrepared(lease.id, sessionID: session, machineID: "wrong-machine") }
        await fixture.owner.releasePrepared(sessionID: session)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        let projection = await fixture.owner.projection(); XCTAssertEqual(projection.leaseCount, 0)
    }
    func testProjectCanonicalCodexAndGeminiFormsPreserveActualDefaults() async throws {
        let fixture = try await fixture(), definition = try definition(fixture)
        let codexValue = try await fixture.owner.prepareProject(definition: definition, provider: "codex", cwd: fixture.root.path, loginPath: "/usr/bin:/bin", machineID: "codex-machine")
        let codex = try XCTUnwrap(codexValue)
        XCTAssertTrue(codex.arguments.contains("mcp_servers.staysfixed.tool_timeout_sec=900")); XCTAssertTrue(codex.readableFiles.isEmpty)
        await fixture.owner.abandonPrepared(codex.id)
        let defaults = fixture.root.appendingPathComponent("gemini-defaults.json")
        try Data("{\"theme\":\"scratch-theme\",\"mcpServers\":{\"administrator\":{\"command\":\"/usr/bin/true\"}}}".utf8).write(to: defaults)
        let geminiValue = try await fixture.owner.prepareProject(definition: definition, provider: "gemini", cwd: fixture.root.path, loginPath: "/usr/bin:/bin", machineID: "gemini-machine",
            inheritedEnvironment: ["GEMINI_CLI_SYSTEM_DEFAULTS_PATH": defaults.path])
        let gemini = try XCTUnwrap(geminiValue), path = try XCTUnwrap(gemini.environment["GEMINI_CLI_SYSTEM_DEFAULTS_PATH"])
        let config = try NativeRPCValue.parseJSON(Data(contentsOf: URL(fileURLWithPath: path)))
        XCTAssertEqual(config["theme"].string, "scratch-theme")
        XCTAssertEqual(config["mcpServers"]["administrator"]["command"].string, "/usr/bin/true")
        XCTAssertEqual(config["mcpServers"]["staysfixed"]["timeout"].number, 900_000)
        await fixture.owner.abandonPrepared(gemini.id)
        XCTAssertEqual(try NativeRPCValue.parseJSON(Data(contentsOf: defaults))["theme"].string, "scratch-theme")
    }
    func testProjectUnsupportedPartialGrantMissingOwnerAndWrongRootNeverBroaden() async throws {
        let fixture = try await fixture(), definition = try definition(fixture)
        await refused { _ = try await fixture.owner.prepareProject(provider: "claude", cwd: fixture.root.path, loginPath: "/usr/bin", machineID: "m") }
        await refused { _ = try await fixture.owner.prepareProject(definition: definition, provider: "claude", cwd: "/usr/bin", loginPath: "/usr/bin", machineID: "m") }
        await refused { _ = try await fixture.owner.prepareProject(definition: definition, provider: "claude", cwd: fixture.root.path, loginPath: "/usr/bin", allowedTools: ["mcp__staysfixed__one_tool"], machineID: "m") }
        let denied = try await fixture.owner.prepareProject(definition: definition, provider: "claude", cwd: fixture.root.path, loginPath: "/usr/bin", deniedTools: ["mcp__staysfixed"], machineID: "m")
        XCTAssertNil(denied)
        let projection = await fixture.owner.projection(); XCTAssertEqual(projection.callerCount, 0); XCTAssertEqual(projection.leaseCount, 0)
    }
    func testRegisteredProjectUsesRealCallerTableExactMachineAndOriginalTaskScope() async throws {
        let fixture = try await fixture(), receipt = HOSTLeaseCallReceipt(), session = UUID().uuidString
        let launcher = try BackendNativeMCPStdioLauncher(command: "/usr/bin/true", argumentsPrefix: ["scratch-config-only"])
        let source = HOSTLeaseProjectSource(definition: .registeredEndpoint(root: fixture.root.path, serverName: "staysfixed", endpoint: fixture.owner.endpoint,
            toolNames: ["project.read"], stdioLauncher: launcher))
        try await fixture.owner.configureProjectTools(source: source, inheritedEnvironment: [:])
        let value = try await fixture.owner.prepareProject(provider: "claude", cwd: fixture.root.path, loginPath: "/usr/bin:/bin", taskID: "scratch-task",
            taskProject: fixture.root.path, machineID: "original-project-machine")
        let lease = try XCTUnwrap(value), config = try await fixture.owner.projectAgentSettingsConfiguration(lease.id)
        let args = try XCTUnwrap(config["staysfixed"]["args"].elements?.compactMap(\.string))
        let tokenFile = URL(fileURLWithPath: try XCTUnwrap(args.last)), token = try String(contentsOf: tokenFile, encoding: .utf8)
        try await fixture.owner.bindPrepared(lease.id, sessionID: session, machineID: "original-project-machine")
        let app = try BackendHOSTAppRelayClient(paths: fixture.paths, host: fixture.host, handler: { call in receipt.store(call); return .value(.object([])) })
        addTeardownBlock { app.detach() }
        let result = try await call(fixture, token: token, name: "project_read")
        XCTAssertEqual(result["result"]["isError"].bool, false)
        XCTAssertEqual(receipt.call?.context.machineID, "original-project-machine")
        XCTAssertEqual(receipt.call?.context.sessionID, session); XCTAssertEqual(receipt.call?.taskProject, fixture.root.path)
        XCTAssertEqual(receipt.call?.context.projectRoot, fixture.root.path)
        XCTAssertEqual(receipt.call?.context.allowedTools, ["project.read", "project_read"])
        await fixture.owner.releasePrepared(sessionID: session)
        let projection = await fixture.owner.projection(); XCTAssertEqual(projection.callerCount, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: tokenFile.path))
    }
    private func heldProject(_ fixture: Fixture, gate: HOSTLeaseBindGate, entered: XCTestExpectation) async throws -> BackendPreparedProjectTools {
        let endpoint = fixture.owner.endpoint
        let bridge = BackendTestMCPEndpoint(readiness: endpoint.readiness,
            description: { try await endpoint.description() }, catalogue: { try await endpoint.catalogue() },
            register: { token, grant in try await endpoint.register(token: token, grant: grant) },
            bind: { registration, session, machine in
                entered.fulfill(); await gate.wait()
                try await endpoint.bind(registration, sessionID: session, machineID: machine)
            }, revoke: { registration in await endpoint.revoke(registration) })
        let launcher = try BackendNativeMCPStdioLauncher(command: "/usr/bin/true", argumentsPrefix: ["scratch-config-only"])
        try await fixture.owner.configureProjectTools(source: HOSTLeaseProjectSource(definition: .registeredEndpoint(root: fixture.root.path,
            serverName: "staysfixed", endpoint: bridge, toolNames: ["project.read"], stdioLauncher: launcher)), inheritedEnvironment: [:])
        let value = try await fixture.owner.prepareProject(provider: "claude", cwd: fixture.root.path, loginPath: "/usr/bin", machineID: "held-machine")
        return try XCTUnwrap(value)
    }
    func testCancelledInFlightBindWaitsForRealBindThenRevokesWithoutReceiptResurrection() async throws {
        let fixture = try await fixture(), gate = HOSTLeaseBindGate(), entered = expectation(description: "real bind entered")
        let lease = try await heldProject(fixture, gate: gate, entered: entered), session = UUID().uuidString
        let operation = Task { try await fixture.owner.bindPrepared(lease.id, sessionID: session, machineID: "held-machine") }
        await fulfillment(of: [entered], timeout: 5)
        operation.cancel(); await gate.release()
        await refused { try await operation.value }
        let projection = await fixture.owner.projection()
        XCTAssertEqual(projection.callerCount, 0); XCTAssertEqual(projection.leaseCount, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: lease.arguments.last!))
        await refused { try await fixture.owner.bindPrepared(lease.id, sessionID: session, machineID: "held-machine") }
    }
    func testExplicitAbandonInvalidatesSuccessfulBindReceipt() async throws {
        let fixture = try await fixture(), lease = try await ordinary(fixture), session = UUID().uuidString
        try await fixture.owner.bindPrepared(lease.id, sessionID: session, machineID: "m")
        await fixture.owner.abandonPrepared(lease.id)
        await refused { try await fixture.owner.bindPrepared(lease.id, sessionID: session, machineID: "m") }
        let projection = await fixture.owner.projection(); XCTAssertEqual(projection.callerCount, 0); XCTAssertEqual(projection.leaseCount, 0)
    }
    #if TD_HOST_INTEGRATED
    private struct RPCFixture: Sendable {
        let root: URL, client: BackendHOSTClient, owner: BackendHOSTResources
        let source: HOSTLeaseProjectSource
    }
    private func rpcFixture() async throws -> RPCFixture {
        let root = URL(fileURLWithPath: "/tmp", isDirectory: true).resolvingSymlinksInPath().appendingPathComponent("tdh-lrpc-" + UUID().uuidString)
        let data = root.appendingPathComponent("data"), home = root.appendingPathComponent("home")
        for directory in [data, home] { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let paths = try BackendHOSTPaths(dataDirectory: data); _ = try paths.secret(create: true)
        let version = paths.directory.appendingPathComponent("lease-rpc-v1")
        try BackendHOSTFiles.privateDirectory(version)
        let helper = version.appendingPathComponent("TerminalDeckNativeHelper")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/usr/bin/true"), to: helper); XCTAssertEqual(chmod(helper.path, 0o700), 0)
        let configuration = try BackendAccountConfiguration(dataDirectory: data, homeDirectory: home, appName: "HOST Scratch Lease RPC", appID: "terminaldeck",
            helperExecutable: helper, inheritedEnvironment: ["HOME": home.path, "USER": "lease-rpc-fixture"])
        let tool = try BackendMCPTool(id: "browser.read", wireName: "browser_read", description: "Scratch RPC lease read.",
            inputSchema: .object([.init("type", .string("object")), .init("properties", .object([]))]), tier: .read)
        let manager = BackendPTYManager(inheritedEnvironment: [:], onEvent: { _ in })
        let host = BackendHOSTProtocol.Hello(protocolVersion: BackendHOSTProtocol.version, hostVersion: "lease-rpc-v1", hostPID: getpid(), instance: UUID())
        let factory = BackendHOSTResourceFactory.makeUsingAppRelay(paths: paths, manager: manager, nativeAccountOwnerDisabled: true,
            makeHookCoordinator: { BackendSessionHookCoordinator(hostedReceiver: $0) }, peerBelongs: BackendSessionHookCoordinator.hostedPeerBelongs,
            confirmDescendants: { id in manager.pidOf(id) == nil }, metadataChanged: { _ in }, vaultCipher: HOSTLeaseScratchCipher(),
            brokerFactory: { configuration, profiles, vault in
                try await BackendAccountBroker.offline(configuration: configuration, profiles: profiles, vault: vault,
                    runner: { _, _ in .init(code: 45, stdout: "", stderr: "") })
            })
        let owner = try await factory(JSONEncoder().encode(BackendHOSTConfiguration(configuration: configuration, tools: [tool])), host)
        addTeardownBlock { try await owner.stop() }
        let server = try BackendHOSTServer(paths: paths, hostVersion: host.hostVersion, manager: manager,
            launch: { _ in throw BackendHOSTFailure.unavailable }, snapshot: { _ in nil }, onIdle: {},
            resource: { operation, payload in try await owner.invoke(operation, payload: payload) })
        addTeardownBlock { server.stopListening() }
        let client = try BackendHOSTClient(paths: paths); addTeardownBlock { client.detach() }
        let spec = try BackendProjectMCPServerSpec(name: "staysfixed", command: "/usr/bin/true", arguments: ["scratch-config-only"],
            environment: ["SAVED_ENV": "exact private config value"], implementation: .suppliedSourceBridge)
        return .init(root: root, client: client, owner: owner, source: .init(definition: .stdio(root: root.path, server: spec)))
    }
    func testAuthenticatedActualResourceDispatcherAGSProxyWritesAndDetachKeepsFiles() async throws {
        let fixture = try await rpcFixture(), proxy = try await BackendHOSTToolLeaseProxy(client: fixture.client)
        let ordinary = try await proxy.prepareOrdinary()
        let config = try await proxy.agentSettingsConfiguration(ordinary.id)
        XCTAssertEqual(config["deck-control"]["type"].string, "http")
        let lease = try await proxy.reserveAgentSettingsFiles(), file = lease.directory.appendingPathComponent("ags-rpc.json"), bytes = Data("{\"rpc\":true}".utf8)
        try await lease.write([file.lastPathComponent: bytes])
        XCTAssertEqual(try Data(contentsOf: file), bytes)
        await refused { try await lease.write([file.lastPathComponent: bytes]) }
        await proxy.stop(); fixture.client.detach()
        XCTAssertEqual(try Data(contentsOf: file), bytes)
        XCTAssertTrue(FileManager.default.fileExists(atPath: ordinary.arguments.last!))
        let projection = await fixture.owner.mcp.projection(); XCTAssertEqual(projection.callerCount, 1); XCTAssertEqual(projection.leaseCount, 2)
    }
    func testAuthenticatedActualResourceDispatcherProjectProxyPreservesOriginalSpecAndGeminiDefaults() async throws {
        let fixture = try await rpcFixture(), defaults = fixture.root.appendingPathComponent("defaults.json")
        try Data("{\"theme\":\"from-administrator\"}".utf8).write(to: defaults)
        let proxy = try await BackendHOSTProjectToolProxy(client: fixture.client, source: fixture.source, machineID: "rpc-original-machine",
            inheritedEnvironment: ["GEMINI_CLI_SYSTEM_DEFAULTS_PATH": defaults.path])
        let value = try await proxy.prepare(provider: "gemini", cwd: fixture.root.path, loginPath: "/usr/bin:/bin")
        let lease = try XCTUnwrap(value), file = URL(fileURLWithPath: try XCTUnwrap(lease.environment["GEMINI_CLI_SYSTEM_DEFAULTS_PATH"]))
        let original = try Data(contentsOf: file), config = try await proxy.agentSettingsConfiguration(lease.id)
        XCTAssertEqual(config["staysfixed"]["args"].elements?.compactMap(\.string), ["scratch-config-only"])
        XCTAssertEqual(config["staysfixed"]["env"]["SAVED_ENV"].string, "exact private config value")
        XCTAssertEqual(try NativeRPCValue.parseJSON(original)["theme"].string, "from-administrator")
        await proxy.stop(); fixture.client.detach()
        XCTAssertEqual(try Data(contentsOf: file), original)
        let projection = await fixture.owner.mcp.projection(); XCTAssertEqual(projection.leaseCount, 1)
    }
    #endif
    private func call(_ fixture: Fixture, token: String, name: String) async throws -> NativeRPCValue {
        let endpoint = try await fixture.owner.start()
        var request = URLRequest(url: endpoint.url); request.httpMethod = "POST"
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try NativeRPCValue.object([.init("jsonrpc", .string("2.0")), .init("id", .string(UUID().uuidString)),
            .init("method", .string("tools/call")), .init("params", .object([.init("name", .string(name)), .init("arguments", .object([]))]))]).encodedJSON()
        let (data, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        return try NativeRPCValue.parseJSON(data)
    }
}
private actor HOSTLeaseBindGate {
    private var open = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if open { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func release() {
        open = true; let pending = waiters; waiters.removeAll(); for waiter in pending { waiter.resume() }
    }
}
private struct HOSTLeaseProjectSource: BackendProjectMCPSource {
    let readiness: BackendLaunchReadiness = .ready
    let definition: BackendProjectMCPDefinition
    func resolve(cwd: String, provider: String, loginPath: String) async throws -> BackendProjectMCPDefinition? { definition }
}
private final class HOSTLeaseCallReceipt: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: BackendHOSTAppRelayCall?
    var call: BackendHOSTAppRelayCall? { lock.withLock { stored } }
    func store(_ value: BackendHOSTAppRelayCall) { lock.withLock { stored = value } }
}
private struct HOSTLeaseScratchCipher: BackendAccountVaultCipher {
    private static let prefix = Data("HOST-lease-scratch-fixture:".utf8)
    func available() -> Bool { true }
    func prepareForWrites(existingVault: Bool) throws {}
    func encrypt(_ text: String, existingVault: Bool) throws -> Data { Self.prefix + Data(Data(text.utf8).reversed()) }
    func decrypt(_ data: Data) throws -> String {
        guard data.starts(with: Self.prefix) else { throw BackendAccountFailure("Invalid scratch ciphertext.") }
        return String(decoding: Data(data.dropFirst(Self.prefix.count).reversed()), as: UTF8.self)
    }
}
