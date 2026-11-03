import Foundation
import XCTest
import TerminalDeckBackend
import TerminalDeckNativeCore
@testable import TerminalDeckNative

/// Private bridge and in-memory state; no AppModel, app launch or real account.
@MainActor
final class AppearancePreferences21Tests: XCTestCase {
    func testCommittedPreferenceWritesRepaintWithoutOpeningSettings() async throws {
        try await withFixture { fixture in
            var painted: [AppAppearance] = []
            let binding = NativeAppearancePreferences(bridge: fixture.bridge) { painted.append($0) }
            // AppModel subscribes before composition has connected its bridge.
            binding.start()
            binding.start()
            try await fixture.bridge.configure(native: fixture.graph)
            await binding.synchronize()
            XCTAssertEqual(painted, [.dark])
            for theme in ["light", "dark", "system"] {
                // This is the real committed writer used by MCP settings.write.
                let saved = try await fixture.state.writePreferencesAsync(.object([.init("theme", .string(theme))]))
                XCTAssertEqual(saved["theme"], .string(theme))
            }
            XCTAssertEqual(painted, [.dark, .light, .dark, .followMac])
            binding.stop()
        }
    }

    func testBridgeReconnectAndBindingRestartKeepOneLiveListener() async throws {
        try await withFixture { fixture in
            var painted: [AppAppearance] = []
            let binding = NativeAppearancePreferences(bridge: fixture.bridge) { painted.append($0) }
            binding.start()
            try await fixture.bridge.configure(native: fixture.graph)
            _ = try await fixture.state.writePreferencesAsync(.object([.init("theme", .string("light"))]))
            await fixture.bridge.disconnectNative()
            _ = try await fixture.state.writePreferencesAsync(.object([.init("theme", .string("dark"))]))
            XCTAssertEqual(painted, [.light])
            try await fixture.bridge.configure(native: fixture.graph)
            await binding.synchronize()
            XCTAssertEqual(painted, [.light, .dark])
            binding.stop()
            _ = try await fixture.state.writePreferencesAsync(.object([.init("theme", .string("light"))]))
            XCTAssertEqual(painted, [.light, .dark])
            binding.start()
            _ = try await fixture.state.writePreferencesAsync(.object([.init("theme", .string("system"))]))
            XCTAssertEqual(painted, [.light, .dark, .followMac])
            binding.stop()
        }
    }

    func testInvalidEventsDoNotResetConfirmedAppearance() async throws {
        try await withFixture { fixture in
            var painted: [AppAppearance] = []
            let binding = NativeAppearancePreferences(bridge: fixture.bridge) { painted.append($0) }
            binding.start()
            try await fixture.bridge.configure(native: fixture.graph)
            _ = try await fixture.state.writePreferencesAsync(.object([.init("theme", .string("light"))]))
            for value in [NativeRPCValue.null, .string("dark"), .object([]), .object([.init("theme", .string("unknown"))])] {
                try await fixture.graph.registry.publish("prefs:changed", arguments: [value])
            }
            XCTAssertEqual(painted, [.light])
            binding.stop()
        }
    }

    func testNewPreferenceEventWinsOverSlowInitialRead() async throws {
        let read = AppearancePreferences21ReadGate()
        try await withFixture(read: read) { fixture in
            var painted: [AppAppearance] = []
            let binding = NativeAppearancePreferences(bridge: fixture.bridge) { painted.append($0) }
            binding.start()
            try await fixture.bridge.configure(native: fixture.graph)
            let initial = Task { await binding.synchronize() }
            await read.waitUntilStarted()
            _ = try await fixture.state.writePreferencesAsync(.object([.init("theme", .string("light"))]))
            await read.finish(.object([.init("theme", .string("dark"))]))
            await initial.value
            XCTAssertEqual(painted, [.light])
            binding.stop()
        }
    }

    private func withFixture(read: AppearancePreferences21ReadGate? = nil,
                             _ work: @MainActor (AppearancePreferences21Fixture) async throws -> Void) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("td-appearance21-" + UUID().uuidString)
        let store = NativeStateStore()
        let graph = try BackendCompositionRoot(dataRoot: directory, state: store,
            environment: ["HOME": directory.path, "PATH": "/nonexistent"], home: directory.path)
        let state = await BackendCompositionState.make(store: store, settings: graph.settings,
            dataRoot: directory, registry: graph.registry, copilotRoot: { _ in directory.appendingPathComponent("hoot").path })
        try await graph.registry.register("prefs:get", ownerID: "appearance21-fixture") { _, _ in
            if let read { return await read.value() }
            return await store.getPreferences()
        }
        try await graph.retain(.init(name: "appearance21-fixture", domains: ["appearance21-fixture"],
            ownerID: "appearance21-fixture", invokes: ["prefs:get"], events: ["prefs:changed"], stop: {}))
        let fixture = AppearancePreferences21Fixture(graph: graph, state: state, bridge: EngineBridge())
        do { try await work(fixture) }
        catch {
            await fixture.bridge.disconnectNative()
            await state.stop()
            await graph.registry.shutdown()
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
        await fixture.bridge.disconnectNative()
        await state.stop()
        await graph.registry.shutdown()
        try? FileManager.default.removeItem(at: directory)
    }
}

private struct AppearancePreferences21Fixture {
    let graph: BackendCompositionRoot
    let state: BackendCompositionState
    let bridge: EngineBridge
}

private actor AppearancePreferences21ReadGate {
    private var waiting: CheckedContinuation<NativeRPCValue, Never>?
    private var started: [CheckedContinuation<Void, Never>] = []

    func value() async -> NativeRPCValue {
        await withCheckedContinuation { continuation in
            waiting = continuation
            for observer in started { observer.resume() }
            started = []
        }
    }
    func waitUntilStarted() async {
        guard waiting == nil else { return }
        await withCheckedContinuation { started.append($0) }
    }
    func finish(_ value: NativeRPCValue) {
        waiting?.resume(returning: value)
        waiting = nil
    }
}
