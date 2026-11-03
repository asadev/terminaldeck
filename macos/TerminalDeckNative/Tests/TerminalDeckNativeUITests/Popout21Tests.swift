import AppKit
import SwiftUI
import Testing
@testable import TerminalDeckNative
@testable import TerminalDeckNativeCore

/// Private home, inert engine and hidden windows only. One focused run also makes the four frames.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["POPOUT21_TESTS"] == "1"), .serialized)
@MainActor
struct Popout21Tests {
    private func scratchDefaults() throws -> (UserDefaults, String) {
        let name = "popout21-" + UUID().uuidString
        return (try #require(UserDefaults(suiteName: name)), name)
    }

    @Test func pageIdentityAndFallback() throws {
        let (defaults, name) = try scratchDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let store = NativePageWindows(defaults: defaults)
        let agents = try #require(NativePageWindows.page(kind: "panel", id: "agents-org"))
        #expect(agents.id == "agents-all")
        #expect(NativePageWindows.page(kind: "panel", id: "agents") == agents)
        #expect(NativePageWindows.page(kind: "hoot", id: "any-tab")?.isHoot == true)
        #expect(NativePageWindows.page(kind: "session", id: "untouched") == nil)
        store.requested(ScreenRef(kind: .panel, id: "agents-org"))
        #expect(store.contains(ScreenRef(kind: .panel, id: "agents-watch")))
        store.requested(ScreenRef(kind: .panel, id: "overview"))
        #expect(store.fallback() == "tasks")
        store.closed(agents)
        #expect(!store.contains(agents))
    }

    @Test func whenEveryCandidateIsOutMainUsesALandingPage() throws {
        let (defaults, name) = try scratchDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let store = NativePageWindows(defaults: defaults)
        for id in ["overview", "tasks", "agents-all", "memory", "servers"] { store.requested(ScreenRef(kind: .panel, id: id)) }
        #expect(store.fallback() == NativePageWindows.emptyMainID)
        #expect(NativePageWindows.page(kind: "panel", id: store.fallback()) == nil)
        #expect(NativeScreens.detail(kind: "panel", id: store.fallback()) != nil)
    }

    @Test func frameSurvivesRelaunchAndKeepsTheSecondMonitor() throws {
        let (defaults, name) = try scratchDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let ref = ScreenRef(kind: .panel, id: "tasks")
        let frame = NSRect(x: 1720, y: 120, width: 1280, height: 820)
        NativePageWindows(defaults: defaults).saveFrame(ref, frame: frame)
        let relaunched = NativePageWindows(defaults: defaults)
        #expect(relaunched.savedFrame(ref) == frame)
        NSApplication.shared.setActivationPolicy(.prohibited)
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 640, height: 480),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = NSHostingView(rootView: NativeScreenWindowPlacement(ref: ref, store: relaunched))
        window.contentView?.layoutSubtreeIfNeeded()
        // Real screens may differ from the synthetic two-monitor layout used below.
        #expect(window.frame == NativePageWindows.visibleFrame(frame, screens: NSScreen.screens.map(\.visibleFrame)))
        #expect(!window.isVisible)
        let displays = [NSRect(x: 0, y: 0, width: 1512, height: 940), NSRect(x: 1512, y: 0, width: 1920, height: 1080)]
        #expect(NativePageWindows.visibleFrame(frame, screens: displays) == frame)
        let withoutMonitor = NativePageWindows.visibleFrame(frame, screens: [displays[0]])
        #expect(displays[0].contains(withoutMonitor))
        #expect(withoutMonitor.size == frame.size)
    }

    @Test func existingWindowIsReusedWithoutActivatingIt() throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let (defaults, name) = try scratchDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let store = NativePageWindows(defaults: defaults)
        let ref = ScreenRef(kind: .panel, id: "tasks")
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 1280, height: 820),
                              styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        #expect(!store.focus(ref))
        store.requested(ref, bringForward: false); store.prepareToOpen(ref); store.shown(ref, in: window)
        #expect(store.focus(ref, bringForward: false))
        #expect(!window.isVisible)
        #expect(!NSApplication.shared.isActive)
        #expect(window.styleMask.contains(.resizable))
        store.closed(ref)
        #expect(!store.focus(ref))
    }

    @Test func releasingAPageOutsideUsesTheExistingDragPath() {
        let ref = ScreenRef(kind: .panel, id: "tasks")
        var opened: [NativePaneItem] = []
        let drag = NativePaneDragSpace(openWindow: { opened.append($0) })
        drag.finish(item: .page(ref), title: "Tasks", pointer: .init(x: -100, y: -100), outside: true)
        #expect(opened == [.page(ref)])
        #expect(!drag.isDragging)
        drag.finish(item: .page(ref), title: "Tasks", pointer: .zero, outside: false)
        #expect(opened.count == 1)
    }

    @Test func settingsSectionUsesItsOwnScreenRoute() throws {
        let ref = ScreenRef(kind: .panel, id: "settings:appearance")
        let url = try #require(ref.url(engineURL: URL(string: "http://127.0.0.1:4100/")!))
        let items = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        #expect(items.contains(URLQueryItem(name: "settings", value: "1")))
        #expect(items.contains(URLQueryItem(name: "section", value: "appearance")))
        #expect(!items.contains { $0.name == "screen" })
        #expect(ScreenRef.decodeList(ScreenRef.encodeList([ref])) == [ref])
    }

    @Test func moveCarriesStateAndUsesOneScreenModelAndRestoresOpenPages() throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let env = ProcessInfo.processInfo.environment
        let dataPath = try #require(env["TD_NATIVE_DATA_DIR"])
        #expect(dataPath.hasPrefix("/private/tmp/td-glitch-popout21-"))
        let resources = URL(fileURLWithPath: dataPath).deletingLastPathComponent().appendingPathComponent("resources")
        for relative in NativeWebAssets.required {
            let file = resources.appendingPathComponent(relative)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data().write(to: file)
        }
        let refs = [ScreenRef(kind: .panel, id: "tasks"), ScreenRef(kind: .panel, id: "agents-all"),
                    ScreenRef(kind: .panel, id: "hoot", isHoot: true)]
        UserDefaults.standard.set(ScreenRef.encodeList(refs), forKey: "openScreenWindows")
        try AppModel.prepareForUITests(configuration: EngineConfiguration(
            source: .nativeOnly(try NativeWebAssets.discover(resources: resources)), dataRoot: URL(fileURLWithPath: dataPath)))
        let app = AppModel.shared
        // Hoot's window is not reopened at launch (Asad, 3 Nov: Hoot stays closed until the person opens it).
        let reopened = refs.filter { !$0.isHoot }
        #expect(app.takeScreensToRestore() == reopened)
        #expect(app.takeScreensToRestore().isEmpty)
        #expect(app.currentScreen?.id == "overview")
        refs.forEach { NativePageWindows.shared.closed($0) }
        let work = MyWorkModel.shared
        work.view.filters.search = "release"
        work.view.groupBy = .priority
        work.saveView(named: "Other monitor")
        let savedView = work.activeViewID
        UserDefaults.standard.set("org", forKey: "AGFRAME.view")
        UserDefaults.standard.set("scratch-project", forKey: "AGFRAME.project")
        UserDefaults.standard.set("critic", forKey: "AGFRAME.search21")
        app.select("agents-all")
        #expect(app.currentScreen?.id == "agents-all")
        app.movePageToWindow(refs[1])
        #expect(app.currentScreen?.id != "agents-all")
        #expect(app.takePendingScreens() == [refs[1]])
        for ref in refs {
            app.movePageToWindow(ref, bringForward: false)
            #expect(NativePageWindows.shared.keepsCurrentFocus(ref))
            let screen = app.attachScreen(ref)
            #expect(NativePageWindows.shared.keepsCurrentFocus(ref))
            #expect(screen.ref == ref)
            #expect(app.attachScreen(ref) === screen)
            #expect(NativeScreens.detail(kind: ref.screenKind, id: ref.id) != nil)
            let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 800, height: 600),
                                  styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            let host = NSView(frame: .init(x: 0, y: 0, width: 800, height: 600))
            screen.web.webView.frame = host.bounds
            host.addSubview(screen.web.webView)
            let focus = Popout21FocusTarget(frame: .init(x: 0, y: 0, width: 200, height: 40))
            host.addSubview(focus)
            window.contentView = host
            #expect(window.makeFirstResponder(focus))
            screen.web.onReady?()
            #expect(window.firstResponder === focus)
            #expect(!window.isVisible)
            screen.web.webView.removeFromSuperview()
            window.close()
        }
        #expect(MyWorkModel.shared.view.filters.search == "release")
        #expect(MyWorkModel.shared.view.groupBy == .priority)
        #expect(MyWorkModel.shared.activeViewID == savedView)
        #expect(UserDefaults.standard.string(forKey: "AGFRAME.view") == "org")
        #expect(UserDefaults.standard.string(forKey: "AGFRAME.project") == "scratch-project")
        #expect(UserDefaults.standard.string(forKey: "AGFRAME.search21") == "critic")
        #expect(Set(ScreenRef.decodeList(UserDefaults.standard.data(forKey: "openScreenWindows"))) == Set(reopened))
        #expect(NativePageWindows.returnPageID(refs[1]) == "agents-org")
        app.isTerminating = true
        refs.forEach(app.detachScreen)
        #expect(Set(ScreenRef.decodeList(UserDefaults.standard.data(forKey: "openScreenWindows"))) == Set(reopened))
        app.isTerminating = false
        app.selectSettingsSection("appearance")
        let setting = ScreenRef(kind: .panel, id: "settings:appearance")
        app.movePageToWindow(setting, bringForward: false)
        #expect(app.settingsSelection != "appearance")
        #expect(app.takePendingScreens().contains(setting))
        NativePageWindows.shared.closed(setting)
        #expect(!NSApplication.shared.isActive)
    }

    @Test func productionToolbarsRenderLightAndDark() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let output = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["POPOUT21_OUTPUT"]))
        #expect(output.lastPathComponent.hasSuffix(".noindex"))
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let (defaults, name) = try scratchDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let fixture = TASKSRenderFixture()
        let projects = TKTasksProjectScope.renderFixture(projects: fixture.projects, selectedProjectID: "td")
        let work = MyWorkModel(defaults: defaults, importPage: false, fixtureFavorites: [])
        work.view = TasksViewState()
        work.view.filters.search = ""
        let agents = AGTAgentsStore.shared
        let saved = agents.fixture
        agents.fixture = TasksState(agents: [])
        defer { agents.fixture = saved }
        var frames = 0
        for dark in [false, true] {
            let suffix = dark ? "dark" : "light"
            let tasks = NativeUIGTasksWorkView(model: work, state: projects.scoped(fixture.state), now: fixture.now, projects: projects)
                .padding(24).frame(width: 1280, height: 820, alignment: .topLeading).background(.background)
            try await TASKSHiddenRender.render(tasks, size: .init(width: 1280, height: 820), dark: dark,
                to: output.appendingPathComponent("Tasks-\(suffix).png"))
            try await TASKSHiddenRender.render(AGFRAMEAgentsPage(mode: .all, live: false)
                .frame(width: 1280, height: 820).background(.background), size: .init(width: 1280, height: 820), dark: dark,
                to: output.appendingPathComponent("Agents-\(suffix).png"))
            frames += 2
        }
        #expect(frames == 4)
        #expect(!NSApplication.shared.isActive)
        print("POPOUT21: four production Tasks/Agents frames; hidden renders only")
    }
}

@MainActor
private final class Popout21FocusTarget: NSView {
    override var acceptsFirstResponder: Bool { true }
}
