#if TD_HOST_ACCOUNT_BRIDGE && TD_HOST_INTEGRATED && TD_HOST_PTY_GATE_INTEGRATED
import Foundation
import Darwin
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

final class HOSTManagedAgentIntegrationTests: XCTestCase, @unchecked Sendable {
    override func setUpWithError() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["TD_WIP"]?.contains("HOST") == true, "WIP HOST")
    }
    func testManagedClaudeLikeAgentKeepsActualMcpConfigCallerAndPidAfterAppKill() async throws {
        let package = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let products = package.appendingPathComponent(".build/debug", isDirectory: true)
        let helper = products.appendingPathComponent("HOSTSessionHelper"), fakeApp = products.appendingPathComponent("HOSTScratchApp"), agent = products.appendingPathComponent("HOSTMCPAgent")
        for binary in [helper, fakeApp, agent] { XCTAssertTrue(FileManager.default.isExecutableFile(atPath: binary.path), "Fresh scratch product missing: " + binary.lastPathComponent) }
        let root = URL(fileURLWithPath: "/tmp", isDirectory: true).resolvingSymlinksInPath().appendingPathComponent("tdh-live-" + UUID().uuidString, isDirectory: true)
        let home = root.appendingPathComponent("home", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let paths = try BackendHOSTPaths(dataDirectory: root, namespace: "agents")
        let plan = try BackendHOSTLaunchAgent(paths: paths, version: "managed-proof-v1", launchAgentsDirectory: root.appendingPathComponent("agents-plists"))
        var active: BackendHOSTClient?
        defer {
            try? active?.stopAll(); active?.detach()
            let cleanup = Process(); cleanup.executableURL = URL(fileURLWithPath: "/bin/launchctl")
            cleanup.arguments = ["bootout", "gui/" + String(geteuid()) + "/" + plan.label]
            cleanup.standardOutput = FileHandle.nullDevice; cleanup.standardError = FileHandle.nullDevice
            try? cleanup.run(); cleanup.waitUntilExit()
        }
        let result: BackendHOSTLaunchAgent.Result
        do { result = try await plan.connectOrStart(sourceHelper: helper) }
        catch {
            let file = paths.directory.appendingPathComponent("scratch-helper-error.log")
            let detail = (try? String(contentsOf: file, encoding: .utf8)) ?? "No owned helper diagnostic was produced."
            // Owned scratch helper emits only its generic private-start failure.
            throw BackendHOSTFailure.invalid("Owned scratch launchd startup failed: " + error.localizedDescription + " " + String(detail.suffix(2_048)))
        }
        let client: BackendHOSTClient
        switch result { case .started(let value), .attached(let value, _): client = value }
        active = client
        _ = try await client.resource("orphans.retry", arguments: .object([]))
        let configuration = try BackendAccountConfiguration(dataDirectory: root, homeDirectory: home,
            appName: "HOST Managed Scratch", appID: "terminaldeck", helperExecutable: plan.helper,
            inheritedEnvironment: ["HOME": home.path, "PATH": "/usr/bin:/bin", "USER": "managed-scratch"])
        let tool = try BackendMCPTool(id: "browser.read", wireName: "browser_read", description: "Owned scratch read.",
            inputSchema: .object([.init("type", .string("object")), .init("properties", .object([]))]), tier: .read)
        try await BackendHOSTBootstrap.configure(client: client, configuration: .init(configuration: configuration, tools: [tool]))
        func launchApp() throws -> (Process, Pipe, XCTestExpectation) {
            let app = Process(), output = Pipe(); app.executableURL = fakeApp; app.arguments = [root.path, "agents"]
            app.standardOutput = output; app.standardError = FileHandle.nullDevice
            let exited = XCTestExpectation(description: "managed fake app exit observed"), cleanupExited = XCTestExpectation(description: "owned managed fake app cleanup exit observed")
            app.terminationHandler = { _ in exited.fulfill(); cleanupExited.fulfill() }
            try app.run()
            addTeardownBlock {
                if app.isRunning { XCTAssertEqual(Darwin.kill(app.processIdentifier, SIGKILL), 0) }
                await self.fulfillment(of: [cleanupExited], timeout: 5)
                XCTAssertFalse(app.isRunning)
            }
            return (app, output, exited)
        }
        let (firstApp, firstOutput, firstExit) = try launchApp(), firstReady = expectation(description: "first app attaches MCP relay")
        DispatchQueue.global().async { if !firstOutput.fileHandleForReading.availableData.isEmpty { firstReady.fulfill() } }
        await fulfillment(of: [firstReady], timeout: 5)
        let profiles = try NativeRPCValue.parseJSON(Data(contentsOf: root.appendingPathComponent("profiles.json")))["profiles"]
        let profileID = try XCTUnwrap(profiles.elements?.first?["id"].string)
        var input = BackendCreateSessionInput(cwd: root.path, provider: "claude"); input.profileId = profileID
        let resolver = try await BackendHOSTAccountResolver(client: client)
        let account = try await resolver.resolve(input, provider: .init(id: "claude", command: agent.path, args: [], resumeArgs: []), loginPath: "/usr/bin:/bin", context: .init())
        let tools = try await BackendHOSTToolLeaseProxy(client: client)
        let maybePrepared = try await tools.prepareOrdinary(restricting: nil, deniedTools: [])
        let prepared = try XCTUnwrap(maybePrepared)
        let configFile = URL(fileURLWithPath: try XCTUnwrap(prepared.arguments.last)), originalBytes = try Data(contentsOf: configFile)
        let launchID = UUID().uuidString.lowercased()
        var launch = try BackendHOSTProtocol.Launch(id: launchID, input: input,
            spawn: .init(provider: "claude", command: agent.path, args: prepared.arguments, path: account.path,
                env: account.environment, removeEnv: account.removeEnvironment, profile: account.profile, homeProfileId: account.homeProfileID),
            inheritedEnvironment: configuration.inheritedEnvironment, context: .init(), machineID: "managed-scratch")
        launch.accountHandle = account.reservationID; launch.mcpLeaseIDs = [prepared.id]
        let meta = try client.create(launch), pid = try XCTUnwrap(client.snapshot(meta.id)?.pid)
        try await resolver.bind(account, session: meta)
        try await tools.bind(prepared.id, sessionID: meta.id, machineID: "managed-scratch")
        let before = expectation(description: "agent uses actual config before kill"), trace = HOSTManagedAgentTrace(expected: ["MCP_CONFIG_READY", "MCP_OK probe-before"], ready: before)
        try client.attach(onSnapshot: { trace.receive($0.replay) }, onEvent: { trace.receive($0.text ?? "") }, onReady: {}, onDisconnect: {})
        try client.write(meta.id, bytes: Data("probe-before\n".utf8)); await fulfillment(of: [before], timeout: 8)
        XCTAssertEqual(Darwin.kill(firstApp.processIdentifier, SIGKILL), 0)
        await fulfillment(of: [firstExit], timeout: 5)
        guard !firstApp.isRunning else { throw BackendHOSTFailure.invalid("The owned killed managed fake app did not report its exit.") }
        XCTAssertEqual(firstApp.terminationReason, .uncaughtSignal); XCTAssertEqual(firstApp.terminationStatus, SIGKILL)
        let unavailable = expectation(description: "disconnected tool fails clearly while CLI lives"), down = HOSTManagedAgentTrace(expected: ["MCP_UNAVAILABLE probe-down"], ready: unavailable)
        try client.attach(onSnapshot: { down.receive($0.replay) }, onEvent: { down.receive($0.text ?? "") }, onReady: {}, onDisconnect: {})
        try client.write(meta.id, bytes: Data("probe-down\n".utf8)); await fulfillment(of: [unavailable], timeout: 8)
        XCTAssertEqual(try client.snapshot(meta.id)?.pid, pid); XCTAssertEqual(try Data(contentsOf: configFile), originalBytes)
        let (_, secondOutput, _) = try launchApp(), secondReady = expectation(description: "new app attaches same relay")
        DispatchQueue.global().async { if !secondOutput.fileHandleForReading.availableData.isEmpty { secondReady.fulfill() } }
        await fulfillment(of: [secondReady], timeout: 5)
        let replacement = try BackendHOSTClient(paths: paths); defer { replacement.detach() }
        XCTAssertEqual(replacement.hello.hostPID, client.hello.hostPID); XCTAssertEqual(try replacement.snapshot(meta.id)?.pid, pid)
        let resumed = expectation(description: "same PID uses same config after app relaunch"), after = HOSTManagedAgentTrace(expected: ["MCP_CONFIG_READY", "MCP_OK probe-before", "MCP_OK probe-after"], ready: resumed)
        try replacement.attach(onSnapshot: { after.receive($0.replay) }, onEvent: { after.receive($0.text ?? "") }, onReady: {}, onDisconnect: {})
        try replacement.write(meta.id, bytes: Data("probe-after\n".utf8)); await fulfillment(of: [resumed], timeout: 8)
        XCTAssertEqual(try Data(contentsOf: configFile), originalBytes)
        try replacement.stopAll(); XCTAssertNil(try replacement.snapshot(meta.id)?.pid)
        // The helper releases the session's private config when it records the process exit;
        // under heavy machine load that can land just after stopAll's reply (QUIT, 9 Oct: 3 of
        // 6 loaded full runs). Still required, within a bound — never skipped.
        let removedBy = Date().addingTimeInterval(5)
        while FileManager.default.fileExists(atPath: configFile.path), Date() < removedBy { try await Task.sleep(for: .milliseconds(50)) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: configFile.path))
    }
}
private final class HOSTManagedAgentTrace: @unchecked Sendable {
    private let lock = NSLock(); private var text = "", complete = false
    private let expected: [String], ready: XCTestExpectation
    init(expected: [String], ready: XCTestExpectation) { self.expected = expected; self.ready = ready }
    func receive(_ data: String) {
        let done = lock.withLock { () -> Bool in
            guard !complete else { return false }; text += data
            if expected.allSatisfy({ text.contains($0) }) { complete = true; return true }; return false
        }
        if done { ready.fulfill() }
    }
}
#endif
