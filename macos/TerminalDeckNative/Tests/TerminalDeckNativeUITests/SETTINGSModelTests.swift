import Foundation
import XCTest
import TerminalDeckNativeCore
import TerminalDeckBackend
@testable import TerminalDeckNative

/// All fixtures are in memory. These tests do not initialize an application.
@MainActor
final class SETTINGSModelTests: XCTestCase {
    func testSectionOrder() async {
        XCTAssertEqual(NativeSettingsNavigation.items.map(\.id), ["general", "appearance", "notifications", "island", "agents", "ai-apps", "agent-defaults", "browser", "tasks", "features", "plugins", "advanced", "help"])
    }
    func testMacHidesSeparateFoldedPages() async {
        XCTAssertTrue(NativeSettingsNavigation.items.filter { ["power", "scraping", "linux"].contains($0.id) }.isEmpty)
    }
    func testLegacyLinksReachFoldedDestination() async {
        XCTAssertEqual(NativeSettingsNavigation.canonical("power"), "general")
        XCTAssertEqual(NativeSettingsNavigation.canonical("scraping"), "browser")
        XCTAssertEqual(NativeSettingsNavigation.canonical("linux"), "general")
    }
    func testRenamesKeepStableIds() async {
        XCTAssertEqual(NativeSettingsNavigation.item("agents")?.title, "Coding AIs")
        XCTAssertEqual(NativeSettingsNavigation.item("ai-apps")?.title, "Outside AI apps")
        XCTAssertEqual(NativeSettingsNavigation.item("features")?.title, "Voice")
        XCTAssertEqual(NativeSettingsNavigation.item("help")?.title, "About")
    }
    func testSearchFindsFoldedCapturePreferences() async {
        XCTAssertEqual(NativeSettingsNavigation.matching("CAPTURE").map(\.id), ["browser"])
    }
    func testLiveStatusReadsProviderAndListenerStates() async throws {
        try await withFixture { _, model in
            XCTAssertEqual(model.statuses?.count, 3)
            XCTAssertEqual(model.server?.running, true)
            XCTAssertNil(model.error)
        }
    }
    func testTurnOnReadsSavedHookStateBack() async throws {
        try await withFixture { _, model in
            await model.install("codex")
            XCTAssertEqual(model.statuses?.first { $0.id == "codex" }?.state, .complete)
            XCTAssertEqual(model.results["codex"]?.ok, true)
            XCTAssertNil(model.busy)
        }
    }
    func testTurnOffReadsRemainingForeignHookCount() async throws {
        try await withFixture { _, model in
            await model.remove("claude")
            let claude = model.statuses?.first { $0.id == "claude" }
            XCTAssertEqual(claude?.state, HookInstallState.none)
            XCTAssertEqual(claude?.foreignHooks, 2)
            XCTAssertNil(model.busy)
        }
    }
    func testFailedHookChangeKeepsConfirmedState() async throws {
        try await withFixture { fixture, model in
            await model.install("codex")
            await fixture.refuse(true)
            await model.remove("codex")
            XCTAssertEqual(model.results["codex"]?.ok, false)
            XCTAssertEqual(model.statuses?.first { $0.id == "codex" }?.state, .complete)
            XCTAssertNil(model.busy)
        }
    }
    func testUnreadableHookSettingsAreRefused() async throws {
        try await withFixture { _, model in
            await model.install("gemini")
            XCTAssertEqual(model.results["gemini"]?.ok, false)
            XCTAssertEqual(model.statuses?.first { $0.id == "gemini" }?.state, .error)
        }
    }
    func testIslandDefaultLookWidthAndQuietState() async {
        let model = NativeIslandSettingsModel(fixtureValues: [:])
        XCTAssertEqual(model.look, "app")
        XCTAssertEqual(model.width, "standard")
        XCTAssertEqual(model.quiet, "small")
        XCTAssertTrue(model.enabled)
    }
    func testIslandUnknownWidthFallsBack() async {
        let model = NativeIslandSettingsModel(fixtureValues: [NativeIslandSettingsModel.widthKey: .string("unknown")])
        XCTAssertEqual(model.width, "standard")
    }

    private func withFixture(_ work: @MainActor (SETTINGSFixture, HooksScreenModel) async throws -> Void) async throws {
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("SETTINGS-model-" + UUID().uuidString + ".noindex")
        let fixture = SETTINGSFixture(directory: scratch)
        let graph = try await fixture.root()
        try await EngineBridge.shared.configure(native: graph)
        let model = HooksScreenModel()
        await model.refresh()
        do {
            try await work(fixture, model)
        } catch {
            await EngineBridge.shared.disconnectNative()
            await graph.registry.shutdown()
            throw error
        }
        await EngineBridge.shared.disconnectNative()
        await graph.registry.shutdown()
    }
}
