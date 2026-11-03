#if DEBUG
import AppKit
import SwiftUI
import XCTest
import TerminalDeckNativeCore
import TerminalDeckBackend
@testable import TerminalDeckNative

/// Apply in the SETTINGSViewTests target. Never launch a product/test app.
@MainActor
final class SETTINGSOffscreenRenderTests: XCTestCase {
    func testAllSettingsAndKeyEditorInLightAndDark() async throws {
        #if DEBUG
        let environment = ProcessInfo.processInfo.environment
        // This marker is supplied only after GLITCH's resource override is compiled
        // and reviewed. Environment paths alone do not prove that override exists.
        guard environment["SETTINGS_RENDER_TESTS"] == "1", let dataPath = environment["TD_NATIVE_DATA_DIR"],
              dataPath.hasPrefix("/private/tmp/td-glitch-") else {
            throw XCTSkip("SETTINGS_RENDER_TESTS=1 plus a scratch .noindex TD_NATIVE_DATA_DIR enables offscreen renders.")
        }
        let source = URL(fileURLWithPath: #filePath)
        let macos = source.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let output = macos.appendingPathComponent("design-2026-10-10/built.noindex", isDirectory: true)
        XCTAssertEqual(output.lastPathComponent, "built.noindex")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let fixture = SETTINGSFixture(directory: URL(fileURLWithPath: dataPath))
        let graph = try await fixture.root()
        try await EngineBridge.shared.configure(native: graph)
        // An inert AppModel fixture (no OS bridge, no engine): placeholder web assets in scratch.
        let resources = URL(fileURLWithPath: dataPath).deletingLastPathComponent().appendingPathComponent("resources", isDirectory: true)
        for relative in NativeWebAssets.required {
            let file = resources.appendingPathComponent(relative)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            if !FileManager.default.fileExists(atPath: file.path) { try Data().write(to: file) }
        }
        try AppModel.prepareForUITests(configuration: EngineConfiguration(
            source: .nativeOnly(try NativeWebAssets.discover(resources: resources)), dataRoot: URL(fileURLWithPath: dataPath)))
        _ = AppModel.shared
        let values = NativeSettingsValues.shared
        values.beginOffscreenFixture()
        let previousScreenRead = NativeIslandSettingsAccess.readScreen
        let previousScreenSet = NativeIslandSettingsAccess.setScreen
        NativeIslandSettingsAccess.readScreen = { CodingAIJSON.parse(#"{"showOn":{"mode":"main"},"screens":[{"id":"fixture-builtin","name":"Built-in display","builtIn":true},{"id":"fixture-external","name":"Studio Display","builtIn":false}]}"#) }
        NativeIslandSettingsAccess.setScreen = { _ in CodingAIJSON.parse(#"{"showOn":{"mode":"main"},"screens":[]}"#) }
        do {
            let coding = NativeCodingAIStore.shared
            coding.refreshAll()
            values.start()
            let hooks = HooksScreenModel()
            await hooks.refresh()
            var baseFrames = 0
            var scrollFrames = 0
            for item in NativeSettingsNavigation.items {
                for dark in [false, true] {
                    let view = NativeSettingsShell(selection: .constant(item.id)) { selected in
                        self.detail(selected, coding: coding, hooks: hooks)
                    }
                    scrollFrames += try render(view, dark: dark, size: NSSize(width: 760, height: 560),
                        name: item.id, output: output)
                    baseFrames += 1
                    // The window's minimum size: nothing may squeeze or clip.
                    _ = try render(view, dark: dark, size: NSSize(width: 680, height: 440),
                        name: item.id + "-min", output: output)
                }
            }
            let snapshot = try await fixture.answer("ai-apps:state", [])
            let state = try XCTUnwrap(AiAppsState.from(CodingAIJSON(snapshot.foundation)))
            let key = try XCTUnwrap(state.keys.first)
            for dark in [false, true] {
                let model = AiAppsSettingsModel()
                model.state = state
                let editor = NativeAIKeySettingsEditor(key: key, state: state, model: model, done: {})
                scrollFrames += try render(editor, dark: dark, size: NSSize(width: 560, height: 520), name: "ai-key-editor", output: output)
                baseFrames += 1
            }
            XCTAssertEqual(baseFrames, 30, "14 actual settings panes and one shared key editor, both appearances.")
            print("SETTINGS_RENDER_CAPTURED base=\(baseFrames) scroll=\(scrollFrames) " + ISO8601DateFormatter().string(from: Date()))
        } catch {
            NativeIslandSettingsAccess.readScreen = previousScreenRead
            NativeIslandSettingsAccess.setScreen = previousScreenSet
            await values.endOffscreenFixture()
            await EngineBridge.shared.disconnectNative()
            await graph.registry.shutdown()
            throw error
        }
        NativeIslandSettingsAccess.readScreen = previousScreenRead
        NativeIslandSettingsAccess.setScreen = previousScreenSet
        await values.endOffscreenFixture()
        await EngineBridge.shared.disconnectNative()
        await graph.registry.shutdown()
        #else
        throw XCTSkip("Offscreen fixture support is DEBUG-only. No render attempted.")
        #endif
    }

    /// Returns the number of additional lower-page captures, excluding the base frame.
    private func render<V: View>(_ view: V, dark: Bool, size: NSSize, name: String, output: URL) throws -> Int {
        let host = NSHostingView(rootView: view.environment(\.colorScheme, dark ? .dark : .light)
            .frame(width: size.width, height: size.height))
        host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        host.frame = NSRect(origin: .zero, size: size)
        // A real window that is never ordered on screen: same layout path as the app.
        let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: -20000, y: -20000), size: size),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = host.appearance
        window.contentView = host
        defer { window.contentView = nil }
        settle(host)
        let prefix = "SETTINGS-" + name + "-" + (dark ? "dark" : "light")
        try capture(host, output.appendingPathComponent(prefix + ".png"))
        let scrolls = descendants(host).compactMap { $0 as? NSScrollView }.filter { $0.bounds.width > 300 }
        guard let scroll = scrolls.max(by: { ($0.documentView?.bounds.height ?? 0) < ($1.documentView?.bounds.height ?? 0) }),
              let document = scroll.documentView, document.bounds.height > scroll.contentView.bounds.height + 1 else {
            print("SETTINGS \(name): base only; content fits or no AppKit scroll view found")
            return 0
        }
        let end = max(0, document.bounds.height - scroll.contentView.bounds.height)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: document.isFlipped ? end : 0))
        scroll.reflectScrolledClipView(scroll.contentView)
        settle(host)
        try capture(host, output.appendingPathComponent(prefix + "-scroll.png"))
        return 1
    }
    private func settle(_ host: NSView) {
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))
        host.layoutSubtreeIfNeeded()
    }
    private func descendants(_ view: NSView) -> [NSView] { view.subviews.flatMap { [$0] + descendants($0) } }
    private func capture(_ host: NSView, _ file: URL) throws {
        XCTAssertEqual(file.deletingLastPathComponent().lastPathComponent, "built.noindex")
        let image = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: image)
        let data = try XCTUnwrap(image.representation(using: .png, properties: [:]))
        try data.write(to: file)
        XCTAssertGreaterThan(image.pixelsWide, 0)
        XCTAssertGreaterThan(image.pixelsHigh, 0)
        print("Captured \(file.lastPathComponent): \(image.pixelsWide)x\(image.pixelsHigh)")
    }
    @ViewBuilder private func detail(_ section: String, coding: NativeCodingAIStore, hooks: HooksScreenModel) -> some View {
        if section == "agents" {
            NativeSettingsPage(sectionId: section) { NativeCodingAIThisMachine(store: coding, hooks: hooks) }
        } else if section == "island" {
            NativeIslandSettings()
        } else if section == "agent-defaults" {
            NativeSettingsPage(sectionId: section) { NativeAGSDefaultsSettingsSections() }
        } else if let screen = NativeScreens.settings(sectionId: section) {
            screen
        } else {
            ContentUnavailableView("Missing settings view", systemImage: "gearshape")
        }
    }
}

#endif
