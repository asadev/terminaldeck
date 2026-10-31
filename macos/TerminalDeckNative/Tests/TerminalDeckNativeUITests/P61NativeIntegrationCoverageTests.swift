import AppKit
import Foundation
import XCTest
import TerminalDeckBackend
import TerminalDeckNativeCore
@testable import TerminalDeckNative

@MainActor
final class P61NativeIntegrationCoverageTests: XCTestCase {
    private var directory: URL!
    private var graph: BackendCompositionRoot!

    override func setUp() async throws {
        _ = NSApplication.shared
        directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent(".build/p61-integration-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        graph = try BackendCompositionRoot(dataRoot: directory, state: NativeStateStore(), environment: [:], home: directory.path)
    }
    override func tearDown() async throws {
        await EngineBridge.shared.disconnectNative()
        try await graph.shutdown()
        try FileManager.default.removeItem(at: directory)
    }

    private func connect(_ handlers: [String: @Sendable (NativeRPCContext, [NativeRPCValue]) async throws -> NativeRPCValue], events: Set<String> = []) async throws {
        for (channel, handler) in handlers { try await graph.registry.register(channel, ownerID: "p61", handler: handler) }
        try await graph.retain(.init(name: "p61", domains: ["p61"], ownerID: "p61", invokes: Set(handlers.keys), events: events, stop: {}))
        await graph.seal()
        try await EngineBridge.shared.configure(native: graph)
    }
    private func wait(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        let deadline = Date().addingTimeInterval(3)
        while !condition(), Date() < deadline { try? await Task.sleep(for: .milliseconds(2)) }
        XCTAssertTrue(condition(), "Fixture did not settle", file: file, line: line)
    }
    private func text(_ session: NativeTerminalSession) -> String {
        (0..<10).compactMap { session.terminal.getTerminal().getScrollInvariantLine(row: $0)?.translateToString(trimRight: true) }.joined(separator: "\n")
    }

    func testLocalAttachOrdersBackfillBeforeLiveOutputAndIgnoresAnotherSessionExit() async throws {
        let id = UUID().uuidString, history = HistoryGate()
        try await connect([
            "session:scrollback": { _, _ in await history.read() },
            "session:list": { _, _ in .array([.object([.init("id", .string(id)), .init("cwd", .string("/fixture")), .init("provider", .string("claude"))])]) },
            "settings:get": { _, _ in .object([]) }, "prefs:get": { _, _ in .object([]) }
        ], events: ["session:data", "session:exit"])
        let terminal = NativeTerminalSession(target: .local(id))
        defer { terminal.shutDown() }
        await history.started()
        try await graph.registry.publish("session:data", arguments: [.string(id), .string("live\r\n")])
        XCTAssertEqual(terminal.terminal.alphaValue, 0)
        await history.release("history\r\n")
        await wait { self.text(terminal).contains("live") }
        let output = text(terminal)
        let old = try XCTUnwrap(output.range(of: "history")), live = try XCTUnwrap(output.range(of: "live"))
        XCTAssertLessThan(old.lowerBound, live.lowerBound)
        try await graph.registry.publish("session:exit", arguments: [.string("other"), .number(8)])
        XCTAssertFalse(terminal.ended)
        try await graph.registry.publish("session:exit", arguments: [.string(id), .number(7)])
        await wait { terminal.ended }
        XCTAssertEqual(terminal.end, .exited(code: 7))
        XCTAssertEqual(terminal.status, .exited)
    }

    func testRemoteAttachReplaysBeforeLiveOutputAndDetachedTerminalCannotType() async throws {
        let calls = RemoteCalls()
        try await connect([
            "machines:attach": { _, args in await calls.add("attach", args); return .null },
            "machines:detach": { _, args in await calls.add("detach", args); return .null },
            "machines:input": { _, args in await calls.add("input", args); return .null },
            "machines:list": { _, _ in .object([.init("machines", .array([])), .init("links", .array([]))]) },
            "settings:get": { _, _ in .object([]) }, "prefs:get": { _, _ in .object([]) }
        ], events: ["machines:output", "machines:state"])
        let terminal = NativeTerminalSession(target: .machine(machineId: "fixture", sessionId: "remote"))
        defer { terminal.shutDown() }
        for (data, replay) in [("replay\r\n", true), ("live\r\n", false)] {
            try await graph.registry.publish("machines:output", arguments: [.object([.init("machineId", .string("fixture")), .init("sessionId", .string("remote")), .init("data", .string(data)), .init("replay", .bool(replay))])])
        }
        await wait { self.text(terminal).contains("live") }
        let output = text(terminal)
        XCTAssertLessThan(try XCTUnwrap(output.range(of: "replay")).lowerBound, try XCTUnwrap(output.range(of: "live")).lowerBound)
        let detached = NativeTerminalSession(target: .local(UUID().uuidString), attached: false)
        defer { detached.shutDown() }
        XCTAssertTrue(detached.ended)
        XCTAssertTrue(detached.removed)
        detached.type(paste: "must not be sent")
        let entries = await calls.values
        XCTAssertFalse(entries.contains { $0.0 == "input" })
    }

    func testHostLossOffersRestartAndResumeWithoutLaunchingAnything() async throws {
        let id = UUID().uuidString
        try await connect(["session:scrollback": { _, _ in .string("") }, "session:list": { _, _ in .array([]) },
                           "settings:get": { _, _ in .object([]) }, "prefs:get": { _, _ in .object([]) }])
        var restarts = 0
        let terminal = NativeTerminalSession(target: .local(id), restart: { restarts += 1 })
        defer { terminal.shutDown() }
        terminal.adoptSessionMetadata(["id": id, "cwd": "/fixture", "provider": "claude"])
        NotificationCenter.default.post(name: .tdSessionHostLost, object: nil, userInfo: ["ids": [id]])
        XCTAssertEqual(terminal.end, .hostLost(agent: true))
        XCTAssertEqual(terminal.end?.notice.action?.id, .relaunch)
        terminal.act(.relaunch)
        XCTAssertEqual(restarts, 1)
    }

    func testAppsLoadFailureIsVisibleAndStoppingCancelsPendingState() async throws {
        try await connect([
            "apps:list": { _, _ in throw NativeRPCError(code: "not-found", message: "Server offline") },
            "apps:capabilities": { _, _ in .object([]) }
        ])
        let model = NativeAppsModel(serverID: "fixture")
        model.start()
        await wait { !model.loading }
        XCTAssertEqual(model.problem, "This app or saved item could not be found. Refresh the page.")
        XCTAssertTrue(model.apps.isEmpty)
        model.stop()
        XCTAssertFalse(model.catalogLoading)
        XCTAssertFalse(model.dataDatabaseLoading)
    }

    func testStoreServiceEnforcesExclusiveOwnershipAndCanReopenAfterStop() async throws {
        let service = NativeStateService(), file = directory.appendingPathComponent("state.json")
        do { try await service.start(stateFile: file, ownership: .readOnly); XCTFail() }
        catch let error as NativeRPCError { XCTAssertEqual(error.code, "store-read-only") }
        try await service.start(stateFile: file)
        let first = try await service.authoritativeStore()
        try await first.setQuitBehavior(.keep)
        try await service.start(stateFile: file)
        do { try await service.start(stateFile: directory.appendingPathComponent("other.json")); XCTFail() }
        catch let error as NativeRPCError { XCTAssertEqual(error.code, "state-root-conflict") }
        await service.stop()
        try await service.start(stateFile: file)
        let reopened = try await service.authoritativeStore()
        let behavior = await reopened.getQuitBehavior()
        XCTAssertEqual(behavior, .keep)
        await service.stop()
    }

    func testConsentReturnKeypadReturnAndEscapeAllRefuseWithoutShowingAWindow() throws {
        _ = NSApplication.shared
        let panel = ConsentPanel(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        defer { panel.close() }
        var refusals = 0
        panel.refuse = { refusals += 1 }
        panel.cancelOperation(nil)
        for code: UInt16 in [36, 76] {
            let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: panel.windowNumber, context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: code))
            panel.keyDown(with: event)
        }
        XCTAssertEqual(refusals, 3)
        XCTAssertFalse(panel.isVisible)
    }
}

private actor RemoteCalls {
    private(set) var values: [(String, [NativeRPCValue])] = []
    func add(_ name: String, _ arguments: [NativeRPCValue]) { values.append((name, arguments)) }
}
private actor HistoryGate {
    private var requestStarted = false
    private var observers: [CheckedContinuation<Void, Never>] = []
    private var answer: CheckedContinuation<NativeRPCValue, Never>?
    func read() async -> NativeRPCValue {
        requestStarted = true
        for observer in observers { observer.resume() }; observers = []
        return await withCheckedContinuation { answer = $0 }
    }
    func started() async { if !requestStarted { await withCheckedContinuation { observers.append($0) } } }
    func release(_ text: String) { answer?.resume(returning: .string(text)); answer = nil }
}
