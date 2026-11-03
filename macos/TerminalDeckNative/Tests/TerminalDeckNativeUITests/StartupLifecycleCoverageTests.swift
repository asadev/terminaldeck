import AppKit
import WebKit
import XCTest
import TerminalDeckBackend
import TerminalDeckNativeCore
@testable import TerminalDeckNative

/// Runs the app-owned lifecycle in process. No app, host, login, browser profile or real data is opened.
@MainActor
final class StartupLifecycleCoverageTests: XCTestCase {
    private func fixture() throws -> (URL, EngineConfiguration, NativeStateService, NativeCompositionRoot, Calls) {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent(".build/startup-fixture-" + UUID().uuidString)
        for name in NativeWebAssets.required {
            let file = root.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data().write(to: file)
        }
        let service = NativeStateService(), calls = Calls()
        var runtime = NativeCompositionRoot.Runtime()
        runtime.state = service; runtime.environment = [:]; runtime.home = root.path
        runtime.fullGraph = false; runtime.settingsBrowser = nil
        runtime.connect = { _ in calls.values.append("connect") }
        runtime.disconnect = { calls.values.append("disconnect") }
        runtime.appearanceReady = { calls.values.append("appearance") }
        runtime.stopHoot = { calls.values.append("hoot") }
        runtime.removeTranscripts = { _ in calls.values.append("transcripts") }
        runtime.report = { _ in }
        return (root, .init(source: .nativeOnly(try NativeWebAssets.discover(resources: root)),
                            dataRoot: root.appendingPathComponent("data")), service,
                NativeCompositionRoot(runtime: runtime), calls)
    }

    func testStartupSealsRoutesAndToolsAndStopKeepsStoreOpenUntilOwnersDrain() async throws {
        let (root, config, service, composition, calls) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try composition.contribute { graph in
            try await graph.registry.register("fixture:read", ownerID: "fixture") { _, _ in .string("ready") }
            let tool = try BackendMCPTool(id: "fixture.read", wireName: "fixture_read", description: "Read", inputSchema: .object([]), tier: .read)
            try await graph.mcp.replaceTools(ownerID: "fixture", tools: [(tool, { @Sendable _, _ in .value(.string("ready")) })])
            try await graph.retain(.init(name: "fixture", domains: ["fixture"], ownerID: "fixture", invokes: ["fixture:read"], stop: {
                let store = try await service.authoritativeStore()
                try await store.setQuitBehavior(.stop)
            }))
        }
        try await composition.start(configuration: config)
        let graph = try XCTUnwrap(composition.backend)
        let manifest = await graph.manifest()
        XCTAssertTrue(manifest["invoke"].elements?.contains(.string("fixture:read")) == true)
        let tools = try await graph.mcp.catalogue()
        XCTAssertEqual(tools.map(\.id), ["fixture.read"])
        XCTAssertEqual(calls.values, ["connect", "appearance"])
        try await composition.start(configuration: config)
        XCTAssertEqual(calls.values, ["connect", "appearance"], "Repeated start must not connect twice")
        XCTAssertThrowsError(try composition.contribute { _ in })
        do { try await composition.start(configuration: .init(source: config.source, dataRoot: root.appendingPathComponent("other"))); XCTFail() }
        catch let error as NativeRPCError { XCTAssertEqual(error.code, "composition-root-conflict") }
        try await composition.stop()
        XCTAssertNil(composition.backend)
        XCTAssertEqual(calls.values, ["connect", "appearance", "hoot", "transcripts", "disconnect"])
        do { _ = try await service.authoritativeStore(); XCTFail("Store stayed open") }
        catch let error as NativeRPCError { XCTAssertEqual(error.code, "state-unavailable") }
        let saved = try NativeRPCValue.parseJSON(Data(contentsOf: config.engineDataDirectory.appendingPathComponent("state.json")))
        XCTAssertEqual(saved["quitBehavior"], .string("stop"))
        let remainingTools = try await graph.mcp.catalogue()
        XCTAssertTrue(remainingTools.isEmpty)
    }

    func testFailedContributionDrainsAndRetryUsesFreshOwners() async throws {
        let (root, config, service, composition, calls) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        var attempts = 0
        try composition.contribute { graph in
            attempts += 1
            if attempts == 1 { throw NativeRPCError(code: "fixture-start", message: "First start fails") }
            let installed = await graph.hasInvoke("tailnet:status")
            XCTAssertTrue(installed)
        }
        do { try await composition.start(configuration: config); XCTFail() }
        catch let error as NativeRPCError { XCTAssertEqual(error.code, "fixture-start") }
        XCTAssertNil(composition.backend)
        do { _ = try await service.authoritativeStore(); XCTFail() }
        catch let error as NativeRPCError { XCTAssertEqual(error.code, "state-unavailable") }
        XCTAssertEqual(calls.values, ["hoot", "transcripts", "disconnect"])
        try await composition.start(configuration: config)
        XCTAssertEqual(attempts, 2)
        try await composition.stop()
    }

    func testBlockedStartupCleanupKeepsTheStoreAndRefusesAnotherBootstrapUntilStopSucceeds() async throws {
        let (root, config, service, composition, _) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let drain = FailFirstDrain()
        try composition.contribute { graph in
            try await graph.retain(.init(name: "z-fixture", domains: ["fixture"], ownerID: "fixture", invokes: [], stop: { try await drain.stop() }))
            throw NativeRPCError(code: "fixture-start", message: "Start refused")
        }
        do { try await composition.start(configuration: config); XCTFail() }
        catch let error as NativeRPCError { XCTAssertEqual(error.code, "composition-stop-blocked") }
        XCTAssertNotNil(composition.backend)
        _ = try await service.authoritativeStore()
        do { try await composition.start(configuration: config); XCTFail() }
        catch let error as NativeRPCError { XCTAssertEqual(error.code, "composition-stop-blocked") }
        try await composition.stop()
        XCTAssertNil(composition.backend)
        do { _ = try await service.authoritativeStore(); XCTFail() }
        catch let error as NativeRPCError { XCTAssertEqual(error.code, "state-unavailable") }
    }

    func testUnsupportedEngineNeverOpensTheStore() async throws {
        let (root, _, service, composition, calls) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        do { try await composition.start(configuration: .init(source: .unavailable(.bundledEngine("Fixture has no pages.")), dataRoot: root)); XCTFail() }
        catch let error as NativeRPCError { XCTAssertEqual(error.code, "composition-mode") }
        XCTAssertTrue(calls.values.isEmpty)
        do { _ = try await service.authoritativeStore(); XCTFail() }
        catch let error as NativeRPCError { XCTAssertEqual(error.code, "state-unavailable") }
    }

    func testPageBridgeRejectsForeignOriginsSubframesAndDuplicateReadiness() throws {
        let (root, _, _, _, _) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = NSApplication.shared
        let log = EngineLog(url: root.appendingPathComponent("engine.log"))
        let bridge = WebBridge(log: log, websiteDataStore: .nonPersistent())
        // The refused loopback port sets the real origin policy without an external service.
        bridge.load(URL(string: "http://127.0.0.1:1/")!)
        var ready = 0, messages: [PageMessage] = []
        bridge.onReady = { ready += 1 }; bridge.onMessage = { messages.append($0) }
        for (scheme, host, port, main) in [("http", "example.invalid", 1, true), ("https", "127.0.0.1", 1, true), ("http", "127.0.0.1", 2, true), ("http", "127.0.0.1", 1, false)] {
            bridge.receive(["type": "ready"], isMainFrame: main, scheme: scheme, host: host, port: port)
        }
        XCTAssertEqual(ready, 0)
        for _ in 0..<2 { bridge.receive(["type": "ready"], isMainFrame: true, scheme: "http", host: "127.0.0.1", port: 1) }
        XCTAssertEqual(ready, 1)
        bridge.receive(["type": "title", "value": "Fixture"], isMainFrame: true, scheme: "http", host: "127.0.0.1", port: 1)
        XCTAssertEqual(messages, [.title("Fixture", subtitle: nil)])
        bridge.reset()
        bridge.receive(["type": "ready"], isMainFrame: true, scheme: "http", host: "127.0.0.1", port: 1)
        XCTAssertEqual(ready, 1)
        XCTAssertNil(bridge.origin)
    }

    private final class Calls { var values: [String] = [] }
}

private actor FailFirstDrain {
    private var first = true
    func stop() throws {
        if first { first = false; throw NativeRPCError(code: "fixture-drain", message: "Still draining") }
    }
}
