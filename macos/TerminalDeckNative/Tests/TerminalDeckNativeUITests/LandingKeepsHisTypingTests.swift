import AppKit
import SwiftUI
import XCTest
@preconcurrency import SwiftTerm
@testable import TerminalDeckNative
@testable import TerminalDeckNativeCore
import TerminalDeckBackend

/// Owner, 14 Nov: his typing never lands in the wrong place. Real windows, real key events, the real New session page
/// (NSHostingView, its NSTextView box), a real terminal view, and the real AppModel (inert engine, no server, no WebKit
/// load) with its real main-page web view:
/// - the page takes the keyboard only at launch and when he asks for New session; a tool starting a session never;
/// - he sends, switches to another session and keeps typing: his keyboard and his view stay put, words typed after
///   Return stay in the box;
/// - the hidden web page loading, reloading by itself and coming back after a (simulated) web-process crash never takes
///   his keyboard or changes the page or session he is on.
/// Also the launch number: how long until the first frame he can type into.
@MainActor
final class LandingKeepsHisTypingTests: XCTestCase {
    final class HisWindow: NSWindow {
        override var isKeyWindow: Bool { true }
        override var canBecomeKey: Bool { true }
    }
    @MainActor final class Bytes: TerminalViewDelegate {
        var bytes = [UInt8]()
        nonisolated func send(source: TerminalView, data: ArraySlice<UInt8>) { MainActor.assumeIsolated { bytes += data } }
        nonisolated func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {}
        nonisolated func setTerminalTitle(source: TerminalView, title: String) {}
        nonisolated func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
        nonisolated func scrolled(source: TerminalView, position: Double) {}
        nonisolated func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
        var text: String { String(decoding: bytes, as: UTF8.self) }
    }
    final class AppBox { var app: AppModel? }

    private let his = "55555555-5555-4555-8555-555555555555"
    private let other = "66666666-6666-4666-8666-666666666666"

    private func type(_ characters: String, into window: NSWindow, keyCode: UInt16 = 0) {
        for character in characters {
            for kind in [NSEvent.EventType.keyDown, .keyUp] {
                if let event = NSEvent.keyEvent(with: kind, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                windowNumber: window.windowNumber, context: nil, characters: String(character),
                                                charactersIgnoringModifiers: String(character), isARepeat: false, keyCode: keyCode) {
                    window.sendEvent(event)
                }
            }
        }
    }

    // Integrator: RunLoop.current.run is unavailable from async code (Swift 6); a synchronous helper keeps the same spin.
    private static func spin(_ seconds: TimeInterval) { RunLoop.current.run(until: Date().addingTimeInterval(seconds)) }

    private func settle(_ host: NSView?) async {
        for _ in 0..<6 {
            host?.layoutSubtreeIfNeeded()
            await Task.yield()
            Self.spin(0.02)
        }
    }

    private func box(in window: NSWindow) -> NSTextView? {
        func find(_ view: NSView) -> NSTextView? {
            if let text = view as? NSTextView, text.accessibilityIdentifier() == "landing.box" { return text }
            for child in view.subviews { if let found = find(child) { return found } }
            return nil
        }
        return window.contentView.flatMap(find)
    }

    private func window() -> HisWindow {
        let window = HisWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: 1200, height: 760), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSView(frame: NSRect(x: 0, y: 0, width: 1200, height: 760))
        window.orderBack(nil)
        return window
    }

    private func terminal(in window: NSWindow) -> (DeckTerminalView, Bytes) {
        let view = DeckTerminalView(frame: NSRect(x: 0, y: 0, width: 480, height: 240), font: .monospacedSystemFont(ofSize: 13, weight: .regular))
        let bytes = Bytes()
        view.eventDelegate = bytes
        let slot = DeckTerminalSlot(container: DeckTerminalContainer(terminal: view))
        slot.frame = NSRect(x: 710, y: 0, width: 480, height: 400)
        window.contentView?.addSubview(slot)
        slot.layoutSubtreeIfNeeded()
        return (view, bytes)
    }

    /// The real AppModel over an inert engine (as Restart1112HeldActionTests builds it): no server, no WebKit load.
    private func makeApp(sessions: [[String: Any]] = []) async throws -> AppModel {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("td-landing-app-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let box = AppBox()
        // `sessions`: what session:list answers (the running sessions the app knows at launch).
        let actions = NativeButtonActions(effects: .init(invoke: { channel, _ in channel == "session:list" ? sessions as Any : NSNull() as Any },
            presentSession: { _ in }, confirm: { _ in false },
            changed: { box.app?.applyButtonState() }))
        let resources = root.appendingPathComponent("resources")
        for name in NativeWebAssets.required {
            let file = resources.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data().write(to: file)
        }
        let engine = EngineController(configuration: .init(source: .nativeOnly(try NativeWebAssets.discover(resources: resources)), dataRoot: root))
        engine.nativeStarter = { URL(string: "http://127.0.0.1:1/")! }
        engine.start()
        for _ in 0..<10 {
            if case .ready = engine.phase { break }
            await Task.yield()
        }
        let app = AppModel(restartFixture: engine, buttons: actions)
        box.app = app
        return app
    }

    private func rail(_ selected: String?) -> SidebarState {
        SidebarState(groups: [SidebarGroup(id: "pages", title: nil, items: [SidebarItem(id: "artifacts", title: "Artifacts", kind: .panel)])],
            projects: [SidebarProject(id: "/work/imatch", title: "iMatch", expanded: true, sessions: [
                SidebarItem(id: his, title: "His session", kind: .session), SidebarItem(id: other, title: "Other", kind: .session)])],
            selectedId: selected, project: "/work/imatch")
    }
    private func strip(_ active: String) -> TabsState {
        TabsState(tabs: [TabItem(id: his, title: "His session", kind: "session", active: active == his, closable: true),
                         TabItem(id: other, title: "Other", kind: "session", active: active == other, closable: true)],
                  canNewTerminal: true, canNewBrowser: true)
    }

    // MARK: Launch, a tool, his own New session

    func testHisKeysStayInHisSessionWhenAToolStartsOne() async throws {
        let suite = "td-landing-window-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var effects = NativeLandingModel.Effects()
        effects.defaults = defaults
        effects.projects = { [LandingNewSessionTests.work, PROJProjects.independent] }
        effects.exists = { $0.hasPrefix("/work/") }
        let page = NativeLandingModel(effects: effects), focus = NativeLandingFocus()
        let window = window()
        defer { window.close() }

        // 1. Launch: the first frame of the page, with nothing behind it (no engine: `ready` is false), takes his keys.
        focus.personAsked()
        let started = ProcessInfo.processInfo.systemUptime
        let host = NSHostingView(rootView: NativeLandingPage(model: page, focus: focus).frame(width: 700, height: 760))
        host.frame = NSRect(x: 0, y: 0, width: 700, height: 760)
        window.contentView?.addSubview(host)
        var waited = 0
        while box(in: window).map({ window.firstResponder === $0 }) != true, waited < 200 {
            host.layoutSubtreeIfNeeded(); await Task.yield(); Self.spin(0.005); waited += 1
        }
        let firstFrameMS = (ProcessInfo.processInfo.systemUptime - started) * 1000
        let field = try XCTUnwrap(box(in: window))
        XCTAssertTrue(window.firstResponder === field, "at launch the keyboard is in the page's box")
        print(String(format: "LANDING-FIRST-FRAME-MS: %.0f (waits for: nothing; engine not started)", firstFrameMS))
        XCTAssertLessThan(firstFrameMS, 1_500)
        type("hi", into: window)
        XCTAssertEqual(page.text, "hi")

        // 2. He goes to his session and types there.
        let (terminal, bytes) = terminal(in: window)
        XCTAssertTrue(window.makeFirstResponder(terminal))
        type("abc", into: window)

        // 3. While he types: a tool starts a session (quiet tab) and presses New session; the page's lists arrive and
        //    it draws again. None of it may move his keyboard.
        final class Count { var presented = 0 }
        let count = Count()
        let actions = NativeButtonActions(effects: .init(invoke: { _, _ in NSNull() }, presentSession: { _ in count.presented += 1 },
            prepareSession: { page.prepareForTool(folder: $0, onScreen: false) }, confirm: { _ in true }))
        actions.ingest(SidebarState(groups: [], projects: [SidebarProject(id: "/work/imatch", title: "iMatch", expanded: true, sessions: [])], selectedId: nil))
        actions.created(["id": "44444444-4444-4444-8444-444444444444", "cwd": "/work/imatch", "title": "Started by a tool"])
        _ = await actions.runForTool(.newSession).value
        _ = await actions.runForTool(.newSessionIn("/work/imatch")).value
        page.apply(LandingNewSessionTests.lists(), detected: LandingNewSessionTests.detected, added: .null, pickLead: true)
        await settle(host)
        type("def", into: window)
        await settle(host)
        type("g", into: window)

        XCTAssertEqual(count.presented, 0, "a tool never shows the page")
        XCTAssertTrue(window.firstResponder === terminal, "his keyboard stayed in his session")
        XCTAssertEqual(bytes.text, "abcdefg", "every key he typed reached his session")
        XCTAssertEqual(page.text, "hi", "nothing he typed landed on the page")
        XCTAssertEqual(page.folder, nil, "words in the box: the tool did not change his page")
        XCTAssertTrue(actions.sidebar.projects.first?.sessions.contains { $0.id == "44444444-4444-4444-8444-444444444444" } == true)
        XCTAssertNotEqual(actions.sidebar.selectedId, "44444444-4444-4444-8444-444444444444", "the tool's session is not chosen for him")

        // 4. He asks for a new session himself: now, and only now, the box takes the keyboard again.
        focus.personAsked()
        await settle(host)
        XCTAssertTrue(window.firstResponder === box(in: window), "his own New session puts the keyboard in the box")
        type("!", into: window)
        XCTAssertEqual(page.text, "hi!")
        XCTAssertEqual(bytes.text, "abcdefg")
    }

    // MARK: He sends, then goes elsewhere before the session is made (review blocker 2), through AppModel

    func testHeSendsSwitchesAndKeepsTypingNothingMovesHim() async throws {
        let app = try await makeApp()
        app.web.onMessage?(.tabs(strip(his)))
        app.web.onMessage?(.sidebar(rail(his)))
        app.select(NativeLanding.pageID)
        XCTAssertTrue(app.landingOnScreen)

        let engine = LandingNewSessionTests.Engine(), gate = LandingGate()
        let suite = "td-landing-send-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var effects = LandingNewSessionTests.effects(engine, defaults: defaults)
        let wired = NativeLandingModel.Effects.wired(to: app)
        effects.addQuietly = wired.addQuietly; effects.onScreen = wired.onScreen; effects.show = wired.show
        effects.invoke = { channel, args in
            engine.calls.append((channel, args))
            if channel == "session:create" { return await gate.wait() }
            return .bool(true)
        }
        let page = NativeLandingModel(effects: effects), focus = NativeLandingFocus()
        page.apply(LandingNewSessionTests.lists(), detected: LandingNewSessionTests.detected, added: .null, pickLead: false)

        let window = window()
        defer { window.close() }
        focus.personAsked()
        let host = NSHostingView(rootView: NativeLandingPage(model: page, focus: focus).frame(width: 700, height: 760))
        host.frame = NSRect(x: 0, y: 0, width: 700, height: 760)
        window.contentView?.addSubview(host)
        await settle(host)
        let (terminal, bytes) = terminal(in: window)
        XCTAssertTrue(window.firstResponder === box(in: window))

        type("Fix it", into: window)
        type("\r", into: window, keyCode: 36) // Return: sent
        for _ in 0..<200 where !engine.calls.contains(where: { $0.0 == "session:create" }) { await settle(nil) }
        XCTAssertTrue(page.sending)
        type(" more", into: window)          // typed after Return, still in the box
        app.selectTab(his)                   // he goes to his session
        XCTAssertTrue(window.makeFirstResponder(terminal))
        type("xyz", into: window)

        let made = "77777777-7777-4777-8777-777777777777"
        gate.open(.object([.init("id", .string(made)), .init("cwd", .string("/work/imatch")), .init("title", .string("Fix it"))]))
        for _ in 0..<200 where page.sending { await settle(host) }
        await app.buttonActions.waitForRestartFixture()
        type("!", into: window)

        XCTAssertFalse(page.sending)
        XCTAssertEqual(app.sidebarSelection, his, "his view stayed on his session")
        XCTAssertEqual(app.currentScreen?.id, his)
        XCTAssertTrue(window.firstResponder === terminal, "his keyboard stayed in his session")
        XCTAssertEqual(bytes.text, "xyz!")
        XCTAssertEqual(page.text.trimmingCharacters(in: .whitespaces), "more", "words typed after Return were kept")
        XCTAssertTrue(app.buttonActions.tabs.tabs.contains { $0.id == made }, "the new session is in the side panel and the strip")
        XCTAssertNotEqual(app.tabs?.activeID, made, "but not chosen for him")
        XCTAssertEqual(engine.calls.filter { $0.0 == "session:create" }.count, 1)
    }

    // MARK: The hidden web page loads, reloads and recovers from a crash (review item 5), through AppModel

    func testThePageLoadingReloadingAndRecoveringNeverTakesHisKeyboardOrHisPage() async throws {
        let app = try await makeApp()
        app.web.onMessage?(.tabs(strip(his)))
        app.web.onMessage?(.sidebar(rail(his)))
        XCTAssertEqual(app.currentScreen?.id, his)

        let window = window()
        defer { window.close() }
        app.web.webView.frame = NSRect(x: 0, y: 0, width: 700, height: 760)
        window.contentView?.addSubview(app.web.webView)
        let (terminal, bytes) = terminal(in: window)
        XCTAssertTrue(window.makeFirstResponder(terminal))
        type("a", into: window)

        // The launch's first load, while he is already typing in his session.
        app.web.onReady?()
        type("b", into: window)
        // The page reloads by itself, then again as WebBridge does after its web process ended (onReloading, then the
        // reloaded page's memory: another page and another tab, then ready). WebBridge's crash handler itself needs a
        // loaded origin, so its two callbacks are driven here in its order.
        for round in ["reload", "crash"] {
            app.web.onReloading?()
            app.web.onMessage?(.sidebar(rail("artifacts")))
            app.web.onMessage?(.tabs(strip(other)))
            app.web.onReady?()
            await settle(nil)
            await app.buttonActions.waitForRestartFixture()
            type(round == "reload" ? "c" : "d", into: window)
            XCTAssertTrue(window.firstResponder === terminal, "\(round): his keyboard stayed in his session")
            XCTAssertEqual(app.sidebarSelection, his, "\(round): his page did not change")
            XCTAssertEqual(app.currentScreen?.id, his, "\(round): his session is still on show")
        }
        XCTAssertEqual(bytes.text, "abcd", "every key reached his session")
    }

    /// LANDING-3 A: an event becomes AppKit's "current event" the way a real one does (queued, then taken off the queue).
    private func makeCurrent(_ event: NSEvent) -> NSEvent? {
        NSApp.postEvent(event, atStart: true)
        return NSApp.nextEvent(matching: NSEvent.EventTypeMask(type: event.type), until: Date(timeIntervalSinceNow: 1), inMode: .default, dequeue: true)
    }

    /// LANDING-3 A: a tool's select switching the view to a page the web view draws, and the page opening a dialog by
    /// itself, never pull his keys into the page; his own click on a web page still gives it the keyboard.
    func testAToolOrAPageDialogNeverTakesHisKeysButHisClickDoes() async throws {
        _ = NSApplication.shared
        let app = try await makeApp()
        let webPage = "web-drawn-page"
        var state = rail(his)
        state.groups = [SidebarGroup(id: "pages", title: nil, items: [SidebarItem(id: "artifacts", title: "Artifacts", kind: .panel),
                                                                      SidebarItem(id: webPage, title: "A web page", kind: .panel)])]
        app.web.onMessage?(.tabs(strip(his)))
        app.web.onMessage?(.sidebar(state))
        let window = window()
        defer { window.close() }
        app.web.webView.frame = NSRect(x: 0, y: 0, width: 700, height: 760)
        window.contentView?.addSubview(app.web.webView)
        let (terminal, bytes) = terminal(in: window)
        XCTAssertTrue(window.makeFirstResponder(terminal))
        app.web.onReady?()
        func typeAsHim(_ character: String) {
            for kind in [NSEvent.EventType.keyDown, .keyUp] {
                guard let event = NSEvent.keyEvent(with: kind, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber, context: nil, characters: character, charactersIgnoringModifiers: character,
                    isARepeat: false, keyCode: 0), let current = makeCurrent(event) else { XCTFail("no event"); return }
                window.sendEvent(current)
            }
        }
        typeAsHim("a")

        // A tool switches what is shown to the web page (window_buttons select), then the page reports a dialog open.
        let outcome = await app.runButtonForTool(.select(webPage)).value
        XCTAssertEqual(outcome, .completed)
        XCTAssertEqual(app.currentScreen?.id, webPage)
        XCTAssertTrue(app.webPageOnScreen)
        app.nativeScreenShown(false) // what ContentView does when the shown screen becomes the page
        app.web.onMessage?(.pageModal(open: true))
        app.nativeScreenShown(false) // and when the page reports its dialog
        typeAsHim("b")
        XCTAssertTrue(window.firstResponder === terminal, "the tool and the page's dialog left his keyboard where he was typing")
        XCTAssertEqual(bytes.text, "ab", "every key reached his session")

        // His own click on the web page gives it the keyboard.
        let click = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: NSPoint(x: 100, y: 100), modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
        XCTAssertNotNil(makeCurrent(click))
        app.nativeScreenShown(false)
        let responder = window.firstResponder as? NSView
        XCTAssertTrue(responder === app.web.webView || responder?.isDescendant(of: app.web.webView) == true, "his click puts the keyboard in the page")
    }

    // MARK: Opening on New session with sessions running (Owner, 14 Nov: the Mac mini, 4 sessions kept alive, showed
    // "Session 1 – ClaudeCRM" two minutes after the install restart), through AppModel

    func testNewSessionOpeningStaysWhateverThePageRemembersOrReopens() async throws {
        let app = try await makeApp()
        app.setOpensOnForTests(.newSession)
        XCTAssertTrue(app.landingOnScreen, "the first frame is the New session page")
        // The first load: the page's memory, with a remembered selected session among the running ones.
        app.web.onMessage?(.tabs(strip(his)))
        app.web.onMessage?(.sidebar(rail(his)))
        app.web.onReady?()
        await app.buttonActions.waitForRestartFixture()
        XCTAssertEqual(app.currentScreen?.id, NativeLanding.pageID, "after the first load the New session page is shown")
        // The reopen step: the sessions are put back and the page's automatic choice moves to another, twice over.
        for picked in [other, his] {
            app.web.onMessage?(.sidebar(rail(picked)))
            app.web.onMessage?(.tabs(strip(picked)))
            await app.buttonActions.waitForRestartFixture()
            XCTAssertEqual(app.currentScreen?.id, NativeLanding.pageID, "the reopened sessions stay in the side panel")
            XCTAssertEqual(app.windowTitle, "New session")
        }
        XCTAssertNotNil(app.sidebar?.item(id: his), "the sessions are in the side panel")
        // He chooses a session himself: he goes there, and the page's later rail never brings the New session page back.
        app.selectTab(other)
        await app.buttonActions.waitForRestartFixture()
        XCTAssertEqual(app.currentScreen?.id, other)
        app.web.onMessage?(.sidebar(rail(other)))
        app.web.onMessage?(.tabs(strip(other)))
        await app.buttonActions.waitForRestartFixture()
        XCTAssertEqual(app.currentScreen?.id, other, "once he has acted he stays where he is")
        XCTAssertFalse(app.landingOnScreen)
    }

    func testWhereILeftOffOpensTheRememberedSession() async throws {
        let app = try await makeApp()
        app.setOpensOnForTests(.leftOff)
        app.web.onMessage?(.tabs(strip(his)))
        app.web.onMessage?(.sidebar(rail(his)))
        app.web.onReady?()
        await app.buttonActions.waitForRestartFixture()
        XCTAssertEqual(app.currentScreen?.id, his, "Where I left off: the remembered session")
        XCTAssertFalse(app.landingOnScreen)
    }

    /// Owner, 14 Nov: the window title names what the window shows: the page's name on a page (Cloud over a session
    /// the hidden page still shows read "Session 1 – ClaudeCRM"), the session's on a session. LANDING-FIX-2: macOS draws
    /// "title – subtitle"; the page name stands alone ("Cloud", not "Cloud – ClaudeCRM"), a project's name follows only a
    /// session of that project. On every page the strip keeps the open sessions, in order, with none selected.
    func testTheWindowTitleFollowsThePage() async throws {
        let app = try await makeApp()
        var state = rail(his)
        state.groups = [SidebarGroup(id: "pages", title: nil, items: [SidebarItem(id: "artifacts", title: "Artifacts", kind: .panel),
                                                                      SidebarItem(id: "tasks", title: "Tasks", kind: .panel)])]
        app.web.onMessage?(.tabs(strip(his)))
        app.web.onMessage?(.sidebar(state))
        app.web.onReady?()
        // The hidden web page's own heading: the session it last showed and that session's project.
        app.web.onMessage?(.title("Session 1", subtitle: "ClaudeCRM"))
        await app.buttonActions.waitForRestartFixture()
        func shown() -> String { app.windowSubtitle.isEmpty ? app.windowTitle : app.windowTitle + " – " + app.windowSubtitle }
        func noSessionSelected(_ page: String) {
            XCTAssertEqual(app.stripTabs?.tabs.map(\.id), [his, other], "\(page): the sessions stay, in their order")
            XCTAssertFalse(app.stripTabs?.tabs.contains(where: \.active) ?? true, "\(page): no session is the open tab")
            XCTAssertFalse(app.stripShowsWhatIsOnShow, "\(page): the title names the page beside the strip")
        }
        XCTAssertEqual(shown(), "His session – iMatch", "a session: its name and its project's")
        XCTAssertTrue(app.stripShowsWhatIsOnShow)

        app.select(Sidebar21Pages.cloudID)
        await app.buttonActions.waitForRestartFixture()
        XCTAssertEqual(app.currentScreen?.id, Sidebar21Pages.cloudID)
        XCTAssertEqual(shown(), "Cloud"); noSessionSelected("Cloud")
        app.select("tasks")
        await app.buttonActions.waitForRestartFixture()
        XCTAssertEqual(app.currentScreen?.id, "tasks")
        XCTAssertEqual(shown(), "Tasks"); noSessionSelected("Tasks")
        app.select(Sidebar21Pages.projectsID)
        await app.buttonActions.waitForRestartFixture()
        XCTAssertEqual(shown(), "Projects"); noSessionSelected("Projects")
        app.select(NativeLanding.pageID)
        await app.buttonActions.waitForRestartFixture()
        XCTAssertEqual(shown(), "New session"); noSessionSelected("New session")
        app.selectTab(other)
        await app.buttonActions.waitForRestartFixture()
        XCTAssertEqual(shown(), "Other – iMatch")
        XCTAssertEqual(app.stripTabs?.tabs.filter(\.active).map(\.id), [other])
    }

    /// LANDING-FIX-3 (the Mac mini after a restart: the strip showed "Session 1" of four until he visited a page): four
    /// running sessions known at launch are all in the strip, in their order, none open, while New session shows.
    func testFourRunningSessionsAreInTheStripAtLaunchWhileNewSessionShows() async throws {
        let third = "77777777-7777-4777-8777-777777777777", fourth = "88888888-8888-4888-8888-888888888888"
        let ids = [his, other, third, fourth]
        let app = try await makeApp(sessions: ids.enumerated().map { index, id in
            ["id": id, "title": "Session \(index + 1)", "cwd": "/work/imatch", "provider": "claude"] })
        app.setOpensOnForTests(.newSession)
        // The page itself knows one tab at first (its automatic choice), and the rail.
        app.web.onMessage?(.tabs(TabsState(tabs: [TabItem(id: his, title: "Session 1", kind: "session", active: true, closable: true)],
                                           canNewTerminal: true, canNewBrowser: true)))
        app.web.onMessage?(.sidebar(rail(his)))
        app.web.onReady?()
        for _ in 0..<40 where (app.stripTabs?.tabs.count ?? 0) < 4 { await settle(nil) }
        XCTAssertEqual(app.stripTabs?.tabs.map(\.id), ids, "every running session, in order, without visiting a page")
        XCTAssertFalse(app.stripTabs?.tabs.contains(where: \.active) ?? true, "none is the open tab")
        XCTAssertTrue(app.landingOnScreen, "the New session page stays")
        XCTAssertEqual(app.windowTitle, "New session")
    }

    /// LANDING-FIX-3: the project's own name ("CRM"), never its folder's ("ClaudeCRM"), wherever the project is named.
    func testTheProjectIsNamedByItsOwnName() async throws {
        let store = SIDEBARProjectStore.shared, before = store.projects
        defer { store.projects = before }
        store.projects = [PROJProject(id: "crm", name: "CRM", folders: ["/work/ClaudeCRM"]), PROJProjects.independent]
        let app = try await makeApp()
        let named = "99999999-9999-4999-8999-999999999999", folderNamed = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
        app.web.onMessage?(.tabs(TabsState(tabs: [
            TabItem(id: named, title: "Session 1", kind: "session", active: true, closable: true),
            TabItem(id: folderNamed, title: "ClaudeCRM", kind: "session", active: false, closable: true)], canNewTerminal: true, canNewBrowser: true)))
        app.web.onMessage?(.sidebar(SidebarState(groups: [], projects: [SidebarProject(id: "/work/ClaudeCRM", title: "ClaudeCRM", expanded: true, sessions: [
            SidebarItem(id: named, title: "Session 1", kind: .session), SidebarItem(id: folderNamed, title: "ClaudeCRM", kind: .session)])],
            selectedId: named, project: "/work/ClaudeCRM")))
        app.web.onReady?()
        await app.buttonActions.waitForRestartFixture()
        func shown() -> String { app.windowSubtitle.isEmpty ? app.windowTitle : app.windowTitle + " – " + app.windowSubtitle }
        XCTAssertEqual(shown(), "Session 1 – CRM")
        XCTAssertEqual(app.stripTabs?.tabs.map(\.title), ["Session 1", "CRM"], "a session named after the folder reads as the project")
        app.selectTab(folderNamed)
        await app.buttonActions.waitForRestartFixture()
        XCTAssertEqual(shown(), "CRM", "never \"CRM – CRM\"")
        // The side panel's row: the same rule; a name he gave stays as given.
        let row = SidebarItem(id: folderNamed, title: "ClaudeCRM", kind: .session)
        let rows = SIDEBARProjectStore(defaults: UserDefaults(suiteName: "td-landing-rows-\(UUID().uuidString)")!)
        rows.projects = store.projects
        rows.sessionProjects[folderNamed] = (projectID: nil, cwd: "/work/ClaudeCRM")
        XCTAssertEqual(SIDEBARSessionLine.title(row, store: rows), "CRM")
        XCTAssertEqual(NativeProjectNames.sessionTitle("ClaudeCRM", folder: "/work/ClaudeCRM/src"), "ClaudeCRM", "a subfolder is not the project")
        XCTAssertEqual(NativeProjectNames.sessionTitle("Notes", folder: "/elsewhere/Notes"), "Notes", "a folder of no project keeps its name")
        // LANDING-FIX-4: the side panel's Projects list names a project's folder by the project.
        XCTAssertEqual(NativeProjectNames.folderRowName("/work/ClaudeCRM", registry: store.projects), "CRM")
        XCTAssertEqual(NativeProjectNames.folderRowName("/work/ClaudeCRM/", registry: store.projects), "CRM")
        XCTAssertEqual(NativeProjectNames.folderRowName("/work/ClaudeCRM/src", registry: store.projects), "src", "a subfolder opened on its own")
        XCTAssertEqual(NativeProjectNames.folderRowName("/work/Notes", registry: store.projects), "Notes", "a plain folder")
    }

    /// Owner, 15 Nov: "Hoot chat can be an option to always land". Hoot's chat opens once the engine is up, once per
    /// launch; a reload never jumps him back to it.
    func testHootChatOpeningRunsOncePerLaunch() async throws {
        let app = try await makeApp()
        app.setOpensOnForTests(.hoot)
        XCTAssertNotEqual(app.sidebarSelection, NativeLanding.pageID, "Hoot chat: not the New session page")
        app.web.onMessage?(.tabs(strip(his)))
        app.web.onMessage?(.sidebar(rail(his)))
        await app.buttonActions.waitForRestartFixture()
        XCTAssertEqual(app.currentScreen?.kind, "hoot", "the app opens on Hoot's chat when he chose it")
        app.selectTab(his)
        await app.buttonActions.waitForRestartFixture()
        XCTAssertEqual(app.sidebarSelection, his)
        app.web.onReloading?()
        app.web.onMessage?(.sidebar(rail(his)))
        app.web.onMessage?(.tabs(strip(his)))
        app.web.onReady?()
        await app.buttonActions.waitForRestartFixture()
        XCTAssertEqual(app.sidebarSelection, his, "a reload never jumps him to Hoot")
        XCTAssertNotEqual(app.currentScreen?.kind, "hoot")
    }

    /// Owner, 15 Nov: the Overview page is gone. The hidden page's own Overview (its memory, its ⌘⇧D) is never shown:
    /// its memory changes nothing, his press opens the current project's page, or New session with no project.
    /// The retired Overview is never shown (Owner, 15 Nov). Proved WITHOUT starting the app's model: starting the real
    /// AppModel in the test runner reaches the OS bridge, which has no app bundle there (integrator's run, 15 Nov: the
    /// whole UI test process stopped at NativeOSBridge). So: the stand-in rules themselves, the saved "opens on" value,
    /// and the three places in the app's model and screens that turn every way in into the stand-in.
    func testTheRetiredOverviewIsNeverShown() throws {
        // Every way in lands on the stand-in: no project open = the New session page.
        XCTAssertEqual(SHELLRoutes.overviewStandIn(current: nil), NativeLanding.pageID, "no project: New session")
        XCTAssertNotEqual(SHELLRoutes.overviewStandIn(current: nil), SHELLRoutes.retiredOverview)
        // An older build's saved "opens on: Overview" opens New session.
        XCTAssertEqual(NativeLandingOpensOn(stored: NativeLandingOpensOn.retiredOverview), .newSession)
        XCTAssertFalse(NativeLandingOpensOn.allCases.map(\.rawValue).contains(SHELLRoutes.retiredOverview), "no longer a choice")
        let package = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        func source(_ name: String) throws -> String {
            try String(contentsOf: package.appendingPathComponent("Sources/TerminalDeckNative/" + name), encoding: .utf8)
        }
        let app = try source("AppModel.swift")
        // A select (his press, a tool, an old link) never selects it: it opens the stand-in.
        XCTAssertTrue(app.contains("if id == SHELLRoutes.retiredOverview { select(SHELLRoutes.overviewStandIn()); return }"))
        // The hidden page's own Overview (its memory, its ⌘⇧D) is never adopted as the selection.
        let adopt = try XCTUnwrap(app.range(of: "if filtered.selectedId == SHELLRoutes.retiredOverview {"))
        let branch = String(app[adopt.lowerBound...].prefix(1_200))
        XCTAssertTrue(branch.contains("select(SHELLRoutes.overviewStandIn())"))
        XCTAssertTrue(branch.contains("return"))
        XCTAssertFalse(branch.components(separatedBy: "return").first?.contains("sidebarSelection = filtered.selectedId") ?? true,
                       "never a selection")
        // Asked to draw it anyway: the New session page is drawn.
        XCTAssertTrue(try source("NativeScreens.swift").contains(
            "case (\"panel\", SHELLRoutes.retiredOverview): return SHELLRoutes.detail(kind: \"panel\", id: NativeLanding.pageID)"))
    }
}
