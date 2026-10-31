import AppKit
import Foundation
import Testing
import TerminalDeckNativeCore
@testable import TerminalDeckNative

/// Real AppModel/button integration in a private, inert UI fixture.
/// No engine start, scene, window, host or production data is involved.
@Suite(.serialized)
@MainActor
struct HistoryContentRouting21Tests {
    @Test func movedHootFallbackYieldsToExplicitFinishedHistoryToolSelection() async throws {
        let env = ProcessInfo.processInfo.environment
        #expect(env["TD_NATIVE_UI_TEST"] == "1")
        let dataPath = try #require(env["TD_NATIVE_DATA_DIR"])
        let homePath = try #require(env["CFFIXED_USER_HOME"])
        #expect(dataPath.hasPrefix("/private/tmp/td-glitch-history-route21-"))
        #expect(homePath.hasPrefix("/private/tmp/td-glitch-history-route21-"))
        let data = URL(fileURLWithPath: dataPath).resolvingSymlinksInPath().standardizedFileURL
        let home = URL(fileURLWithPath: homePath).resolvingSymlinksInPath().standardizedFileURL
        let owned = home.deletingLastPathComponent()
        let privateTemp = URL(fileURLWithPath: "/private/tmp").resolvingSymlinksInPath().standardizedFileURL
        // Stop before any defaults/model access if the runner did not isolate home/data.
        try #require(env["TD_NATIVE_UI_TEST"] == "1" && dataPath.hasPrefix("/private/tmp/td-glitch-history-route21-")
            && homePath.hasPrefix("/private/tmp/td-glitch-history-route21-")
            && owned.lastPathComponent.hasPrefix("td-glitch-history-route21-")
            && owned.deletingLastPathComponent() == privateTemp
            && data.deletingLastPathComponent() == owned && data.lastPathComponent == "data"
            && home.lastPathComponent == "home"
            && URL(fileURLWithPath: NSHomeDirectory()).resolvingSymlinksInPath().standardizedFileURL == home)
        let resources = data.deletingLastPathComponent().appendingPathComponent("resources")
        for relative in NativeWebAssets.required {
            let file = resources.appendingPathComponent(relative)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data().write(to: file)
        }
        NSApplication.shared.setActivationPolicy(.prohibited)
        UserDefaults.standard.removeObject(forKey: "openScreenWindows")
        try AppModel.prepareForUITests(configuration: .init(source: .nativeOnly(try NativeWebAssets.discover(resources: resources)),
                                                           dataRoot: data))
        let app = AppModel.shared
        #expect(app.isUITestFixture)
        #expect(app.engine.phase == .idle)
        let hoot = ScreenRef(kind: .panel, id: "hoot", isHoot: true)
        defer { NativePageWindows.shared.closed(hoot) }
        app.buttonActions.ingest(SidebarState(groups: [.init(id: "main", title: nil, items: [
            .init(id: "hoot", title: "Hoot", kind: .hoot), .init(id: "overview", title: "Overview", kind: .panel)
        ])], projects: [], selectedId: "hoot"))
        app.buttonActions.followNativeSelection("hoot")
        app.applyButtonState()
        #expect(app.currentScreen?.kind == "hoot")
        app.movePageToWindow(hoot, bringForward: false)
        #expect(app.takePendingScreens() == [hoot])
        #expect(NativePageWindows.shared.keepsCurrentFocus(hoot))
        #expect(app.currentScreen?.id == "overview")

        // This rejected request must not take away the usable page left by Hoot.
        let refused = await app.runButtonForTool(.selectTab("missing-history")).value
        #expect(refused == .refused("That session or page is no longer open."))
        #expect(app.currentScreen?.id == "overview")
        #expect(app.buttonActions.problem == nil)
        let id = "11111111-1111-4111-8111-111111111111"
        let wire = NativeRPCValue.object([.init("id", .string(id)), .init("title", .string("Finished lead history")),
            .init("cwd", .string(data.deletingLastPathComponent().appendingPathComponent("work").path)),
            .init("chat", .bool(true)), .init("exitCode", .number(0))])
        let parsed = try NativeRPCValue.parseJSON(wire.encodedJSON())
        app.buttonActions.openedHistory(try #require(parsed.foundation as? [String: Any]))
        let selected = await app.runButtonForTool(.selectTab(id)).value

        #expect(selected == .completed)
        #expect(app.buttonActions.tabs.activeID == id)
        #expect(app.sidebar?.selectedId == id)
        // The inert engine intentionally stays idle. Since R71, hidden session
        // tabs cannot become the current screen until the engine is ready.
        // Check the real native selection here; no live engine is needed.
        #expect(app.tabs?.activeID == id)
        #expect(app.visibleTabs == nil)
        #expect(app.currentScreen?.kind == "hoot")
        #expect(app.buttonActions.problem == nil)
        #expect(app.engine.phase == .idle)
        #expect(!NSApplication.shared.isActive)
        #expect(NSApplication.shared.windows.isEmpty)
    }
}
