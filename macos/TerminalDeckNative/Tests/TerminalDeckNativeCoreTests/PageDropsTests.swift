import Foundation
import Testing
@testable import TerminalDeckNativeCore

@Suite("Drop payload")
struct PageDropsTests {
    @Test func onlyRealFilePathsEachOnce() {
        let urls = [
            URL(fileURLWithPath: "/Users/me/a.txt"),
            URL(string: "https://example.com/b.txt")!,
            URL(fileURLWithPath: "/Users/me/x/../a.txt"),
            URL(fileURLWithPath: "/Users/me/My Folder", isDirectory: true),
        ]
        #expect(DropPayload.paths(from: urls) == ["/Users/me/a.txt", "/Users/me/My Folder"])
    }

    @Test func manyFilesAreCapped() {
        let urls = (0..<800).map { URL(fileURLWithPath: "/tmp/f\($0)") }
        #expect(DropPayload.paths(from: urls).count == DropPayload.maxPaths)
    }

    @Test func pointIsInCSSPixels() {
        #expect(DropPayload.cssPoint(x: 200, y: 100, zoom: 2) == (100, 50))
        #expect(DropPayload.cssPoint(x: 15.4, y: 9.6, zoom: 1) == (15, 10))
        #expect(DropPayload.cssPoint(x: 10, y: 10, zoom: 0) == (10, 10))
        #expect(DropPayload.cssPoint(x: 10, y: 10, zoom: .nan) == (10, 10))
    }

    @Test func scriptCarriesPathsAndPoint() {
        let script = DropPayload.script(paths: ["/Users/me/a \"b\".txt", "/tmp/c"], x: 12, y: 30)
        #expect(script == "window.tdNative && window.tdNative.run('drop-paths', {\"paths\":[\"/Users/me/a \\\"b\\\".txt\",\"/tmp/c\"],\"x\":12,\"y\":30})")
        #expect(DropPayload.script(paths: [], x: 0, y: 0) == nil)
    }
}

@Suite("App menu commands")
struct AppCommandsTests {
    @Test func noShortcutIsUsedTwiceOrTakenFromTheSystem() {
        let shortcuts = AppCommandCatalog.all.compactMap(\.shortcut)
        #expect(Set(shortcuts).count == shortcuts.count)
        #expect(Set(shortcuts).isDisjoint(with: AppCommandCatalog.reservedShortcuts))
        #expect(Set(AppCommandCatalog.all.map(\.title)).count == AppCommandCatalog.all.count)
    }

    @Test func everyElectronMenuCommandIsHereOrNamedElsewhere() {
        // src/main/menu.ts, every `send('…')`.
        let electron: Set<String> = [
            "app.about", "app.preferences", "app.shortcuts", "project.open", "session.new", "session.newDialog",
            "session.close", "session.popOut", "session.dock", "app.help", "app.setup", "view.terminal",
            "view.overview", "view.browser", "view.sidebar", "pane.split", "view.swarm", "app.palette",
            "app.quickOpen", "panel.search", "app.inspector",
        ]
        // Already native: ⌘, ⌘O ⌘T are the scene's own; the sidebar is the system's (⌃⌘S);
        // a session's own window is the tab strip's "Open in New Window".
        let elsewhere: Set<String> = ["app.preferences", "project.open", "session.new", "view.sidebar",
                                      "session.popOut", "session.dock"]
        var here = Set<String>()
        for command in AppCommandCatalog.all + [AppCommandCatalog.about] {
            if case .page(let id) = command.action { here.insert(id) }
        }
        #expect(here.union(elsewhere) == electron)
        #expect(here.isDisjoint(with: elsewhere))
    }

    @Test func electronShortcutsAreKept() {
        func shortcut(_ id: String) -> String? {
            AppCommandCatalog.all.first { $0.action == .page(id) }?.shortcut
        }
        #expect(shortcut("app.shortcuts") == "⌘/")
        #expect(shortcut("session.newDialog") == "⇧⌘T")
        #expect(shortcut("pane.split") == "⌘D")
        #expect(shortcut("view.swarm") == "⌘\\")
        #expect(shortcut("app.palette") == "⌘K")
        #expect(shortcut("app.quickOpen") == "⌘P")
        #expect(shortcut("panel.search") == "⇧⌘F")
        #expect(shortcut("app.inspector") == "⇧⌘I")
    }

    @Test func pageCommandScript() {
        let palette = AppCommandCatalog.all.first { $0.action == .page("app.palette") }
        #expect(palette?.script == "window.tdNative && window.tdNative.run('menu-command', \"app.palette\")")
        #expect(AppCommandCatalog.all.first { $0.action == .zoom(1) }?.script == nil)
    }

    @Test func zoomStepsLikeABrowser() {
        #expect(AppCommandCatalog.zoom(from: 1, direction: 1) == 1.1)
        #expect(AppCommandCatalog.zoom(from: 1, direction: -1) == 0.9)
        #expect(AppCommandCatalog.zoom(from: 1.05, direction: 1) == 1.1)
        #expect(AppCommandCatalog.zoom(from: 1.05, direction: -1) == 1)
        #expect(AppCommandCatalog.zoom(from: 3, direction: 1) == 3)
        #expect(AppCommandCatalog.zoom(from: 0.5, direction: -1) == 0.5)
        #expect(AppCommandCatalog.zoom(from: 2.5, direction: 0) == 1)
        #expect(AppCommandCatalog.zoom(from: .nan, direction: 1) == 1.1)
    }
}
