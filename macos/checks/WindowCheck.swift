import AppKit
import ObjectiveC
import SwiftUI
import WebKit
import TerminalDeckNativeCore

// Offscreen window check — runs the app's real scenes (TerminalDeckScenes) and real
// AppModel against a fake engine that serves a test page, and proves that screen
// windows actually open and load, through every path the user has:
// the right-click menus (sidebar row, toolbar tab), the page's own pop-out message,
// and reopening at launch. Nothing is shown and nothing takes focus: the process may
// not activate, every window it orders in is fully transparent and ignores the
// mouse, menus are read through AppKit's own menu(for:) and never displayed, and
// buttons are pressed through accessibility. Run it with macos/checks/window-check.sh.

extension NSWindow {
    /// Swapped in for -[NSWindow orderWindow:relativeTo:], through which every window is shown.
    @objc dynamic func windowCheck_order(_ place: NSWindow.OrderingMode, relativeTo other: Int) {
        alphaValue = 0
        ignoresMouseEvents = true
        hasShadow = false
        windowCheck_order(place, relativeTo: other) // the original, after the swap
    }

    static func makeEveryWindowInvisible() {
        guard let original = class_getInstanceMethod(NSWindow.self, #selector(NSWindow.order(_:relativeTo:))),
              let invisible = class_getInstanceMethod(NSWindow.self, #selector(NSWindow.windowCheck_order(_:relativeTo:)))
        else { fatalError("cannot hide windows — refusing to run visibly") }
        method_exchangeImplementations(original, invisible)
    }
}

@main
struct WindowCheckApp: App {
    @NSApplicationDelegateAdaptor(CheckDelegate.self) private var delegate
    var body: some Scene { TerminalDeckScenes(model: AppModel.shared) }
}

@MainActor
final class CheckDelegate: NSObject, NSApplicationDelegate {
    private var failures = 0

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSWindow.makeEveryWindowInvisible()
        NSApplication.shared.setActivationPolicy(.prohibited) // never activates, no Dock icon
        NSWindow.allowsAutomaticWindowTabbing = false
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppModel.shared.startEngine()
        Task { await run() }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        AppModel.shared.isTerminating = true
        return .terminateNow
    }

    func applicationWillTerminate(_ notification: Notification) {
        AppModel.shared.shutdown()
    }

    // MARK: Helpers

    private func check(_ ok: Bool, _ what: String) {
        print("\(ok ? "PASS" : "FAIL")  \(what)")
        fflush(stdout)
        if !ok { failures += 1 }
    }

    private func waitFor(_ seconds: Double, _ condition: () async -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return await condition()
    }

    private func waitFor(_ seconds: Double, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return condition()
    }

    private func windows(titled prefix: String) -> [NSWindow] {
        NSApplication.shared.windows.filter { $0.isVisible && $0.title.hasPrefix(prefix) }
    }

    private var mainWindow: NSWindow? {
        NSApplication.shared.windows.first { $0.isVisible && $0.title == "Main" }
    }

    /// The main page posts a message, exactly as the web app would.
    private func pagePosts(_ json: String) {
        AppModel.shared.web.webView.evaluateJavaScript("window.webkit.messageHandlers.tdNative.postMessage(\(json))")
    }

    /// What the main page's window.tdNative.run has received.
    private func commandsRun() async -> [String] {
        let json = try? await AppModel.shared.web.webView.evaluateJavaScript("JSON.stringify(window.__ran || [])") as? String
        return (json.flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String] }) ?? []
    }

    private func allViews(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(allViews)
    }

    /// The context menu AppKit would show for a right-click at `point` (window
    /// coordinates) — built exactly as for a real click, but never displayed.
    private func contextMenu(in window: NSWindow, at point: NSPoint) -> NSMenu? {
        guard let frameView = window.contentView?.superview,
              let event = NSEvent.mouseEvent(with: .rightMouseDown, location: point, modifierFlags: [],
                                             timestamp: ProcessInfo.processInfo.systemUptime,
                                             windowNumber: window.windowNumber, context: nil,
                                             eventNumber: 0, clickCount: 1, pressure: 1)
        else { return nil }
        var responder: NSResponder? = frameView.hitTest(point)
        while let current = responder {
            if let view = current as? NSView, let menu = view.menu(for: event) {
                menu.delegate?.menuNeedsUpdate?(menu)
                menu.update()
                return menu
            }
            responder = current.nextResponder
        }
        return nil
    }

    private func choose(_ title: String, in menu: NSMenu?) -> Bool {
        guard let menu, let index = menu.items.firstIndex(where: { $0.title == title }) else { return false }
        menu.performActionForItem(at: index)
        return true
    }

    /// A left click delivered straight to the window (the mouse-up is queued first,
    /// so the button's own tracking loop finds it).
    private func click(_ window: NSWindow, at point: NSPoint) {
        func event(_ type: NSEvent.EventType) -> NSEvent? {
            NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                               timestamp: ProcessInfo.processInfo.systemUptime,
                               windowNumber: window.windowNumber, context: nil,
                               eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0)
        }
        guard let down = event(.leftMouseDown), let up = event(.leftMouseUp) else { return }
        NSApplication.shared.postEvent(up, atStart: false)
        window.sendEvent(down)
    }

    /// Presses the element whose accessibility label is `label`, as VoiceOver would.
    private func press(_ label: String, in window: NSWindow) -> Bool {
        press(label, under: window)
    }

    private func press(_ label: String, under root: Any) -> Bool {
        func search(_ element: Any, depth: Int) -> NSAccessibilityElementProtocol? {
            guard depth < 40, let node = element as? NSObject else { return nil }
            if let el = node as? NSAccessibilityElementProtocol,
               (node.value(forKey: "accessibilityLabel") as? String) == label { return el }
            let children = (node.value(forKey: "accessibilityChildren") as? [Any]) ?? []
            for child in children { if let hit = search(child, depth: depth + 1) { return hit } }
            return nil
        }
        guard let target = search(root, depth: 0) as? NSObject else { return false }
        if let pressable = target as? NSAccessibilityProtocol { return pressable.accessibilityPerformPress() }
        let press = NSSelectorFromString("accessibilityPerformPress")
        guard target.responds(to: press) else { return false }
        _ = target.perform(press)
        return true
    }

    /// Every accessibility label under `element` (for a failure message).
    private func labels(_ element: Any, depth: Int = 0) -> [String] {
        guard depth < 40, let node = element as? NSObject else { return [] }
        let own = (node.value(forKey: "accessibilityLabel") as? String).map { [$0] } ?? []
        let children = (node.value(forKey: "accessibilityChildren") as? [Any]) ?? []
        return own + children.flatMap { labels($0, depth: depth + 1) }
    }

    // MARK: The checks

    private func run() async {
        let model = AppModel.shared

        check(await waitFor(20) { model.pageReady }, "main window: engine started, page loaded and said ready")
        check(await waitFor(5) { mainWindow != nil }, "main window: title comes from the page")
        check(await waitFor(3) { await self.commandsRun().contains("native-screens:session,browser") },
              "main window: after ready, the page is told which screens native draws")
        guard let main = mainWindow else { return finish() }
        try? await Task.sleep(for: .seconds(1)) // let the sidebar and toolbar lay out

        // 1. Reopening what was open at the last quit (seeded by the script).
        check(await waitFor(10) { !windows(titled: "screen=panel id=memory").isEmpty },
              "restore: the panel window open at last quit came back and loaded")
        if let screenWindow = windows(titled: "screen=panel id=memory").first,
           let screenPage = allViews(screenWindow.contentView!).compactMap({ $0 as? WKWebView }).first {
            let ran = (try? await screenPage.evaluateJavaScript("JSON.stringify(window.__ran)")) as? String ?? ""
            check(ran.contains("native-screens:session,browser"), "screen window: its page is told which screens native draws too")
        } else {
            check(false, "screen window: found its page")
        }

        // 2. Sidebar right-click ▸ Open in New Window (on the Hoot row, the first one).
        if let table = allViews(main.contentView!.superview!).compactMap({ $0 as? NSTableView }).first {
            var opened = false
            for row in 0..<table.numberOfRows {
                let rect = table.convert(table.rect(ofRow: row), to: nil)
                let menu = contextMenu(in: main, at: NSPoint(x: rect.midX, y: rect.midY))
                let titles = menu?.items.map(\.title) ?? []
                if titles.contains("Open in New Window") && !titles.contains("Close Session") {
                    opened = choose("Open in New Window", in: menu)
                    break
                }
            }
            check(opened, "sidebar: right-click menu offers Open in New Window")
            check(await waitFor(10) { windows(titled: "screen=panel id=hoot").count == 1 },
                  "sidebar: Open in New Window opened the Hoot window and it loaded")
        } else {
            check(false, "sidebar: found the sidebar list")
        }

        // 3. Tab right-click ▸ Open in New Window (the strip lives in the toolbar).
        let strip = allViews(main.contentView!.superview!)
            .filter { String(describing: type(of: $0)).contains("ToolbarItemHostingView") }
            .map { ($0, $0.convert($0.bounds, to: nil)) }
            .max { $0.1.width < $1.1.width }
        if let (_, rect) = strip, rect.width > 200 {
            let menu = contextMenu(in: main, at: NSPoint(x: rect.minX + 40, y: rect.midY))
            check(menu?.items.contains { $0.title == "Open in New Window" } == true,
                  "tab: right-click menu offers Open in New Window (menu: \(menu?.items.map(\.title) ?? []))")
            _ = choose("Open in New Window", in: menu)
            check(await waitFor(10) { windows(titled: "screen=session id=t1").count == 1 },
                  "tab: Open in New Window opened the session window and it loaded")
        } else {
            check(false, "tab: found the tab strip in the toolbar")
        }

        // 4. The page's own pop-out: {type:'open-window'}.
        pagePosts(#"{type:'open-window', kind:'panel', id:'tasks', title:'Tasks'}"#)
        check(await waitFor(10) { windows(titled: "screen=panel id=tasks").count == 1 },
              "open-window message: a panel window opened and loaded /?screen=panel&id=tasks")
        pagePosts(#"{type:'open-window', kind:'session', id:'s 1&x+y', title:'claude'}"#)
        check(await waitFor(10) { windows(titled: "screen=session id=s 1&x+y").count == 1 },
              "open-window message: a session window opened with its id intact")

        // 5. The same screen again focuses the one window, never a second.
        pagePosts(#"{type:'open-window', kind:'panel', id:'tasks', title:'Tasks'}"#)
        try? await Task.sleep(for: .seconds(1.5))
        check(windows(titled: "screen=panel id=tasks").count == 1, "same screen again: still exactly one window")
        check(windows(titled: "screen=panel id=tasks").first?.title.contains("token=ok") == true,
              "screen URL carries the engine's token")

        // 6. The strip itself. A process that may not come forward has no accessibility
        //    tree, so these are real mouse clicks sent straight to the invisible window,
        //    where the strip's own layout puts things.
        if let (_, rect) = strip {
            main.makeKey()
            click(main, at: tabPoint(1, in: rect))                       // tab t2
            try? await Task.sleep(for: .milliseconds(300))
            click(main, at: buttonPoint(0, in: rect))                    // new terminal
            try? await Task.sleep(for: .milliseconds(300))
            click(main, at: buttonPoint(1, in: rect))                    // globe
            try? await Task.sleep(for: .milliseconds(500))
        }
        let ran = await commandsRun()
        check(ran.contains("select-tab:t2"), "clicking a tab sends select-tab")
        check(ran.contains("new-terminal-tab"), "the new-terminal button sends new-terminal-tab")
        check(FakeBrowserTabs.shared.list.map(\.id) == ["b1"] && !ran.contains("new-browser-tab"),
              "the globe makes a native browser tab (the page is not asked) (ran: \(ran))")
        check(await waitFor(3) { NativeStub.isShowing("browser/b1") && model.stripTabs?.tabs.last?.id == "b1" },
              "the new browser tab joins the strip after the session tabs, selected and on show")

        // 7. Native screens. NativeScreensStub.swift stands in for the real switchboard
        //    here: ("session","t1"), ("panel","browser") and Settings "general".
        await nativeScreens(main: main, strip: strip?.1)

        // 8. Closing a screen window drops only that window; the engine keeps running.
        windows(titled: "screen=panel id=tasks").first?.close()
        try? await Task.sleep(for: .milliseconds(500))
        check(windows(titled: "screen=panel id=tasks").isEmpty && model.engine.isRunning,
              "closing a screen window leaves the engine running")
        let remembered = ScreenRef.decodeList(UserDefaults.standard.data(forKey: "openScreenWindows"))
        check(remembered.contains(ScreenRef(kind: .panel, id: "memory")) && !remembered.contains(ScreenRef(kind: .panel, id: "tasks")),
              "open windows are remembered for next launch (closed ones are not)")

        finish()
    }

    /// Where tab `index` sits in the strip, with the strip's current number of tabs.
    private func tabPoint(_ index: Int, in strip: NSRect) -> NSPoint {
        let count = AppModel.shared.stripTabs?.tabs.count ?? 0
        let width = CGFloat(TabStripMetrics.tabWidth(count: count, available: Double(strip.width - 2 * TabStripLayout.buttonWidth - 4)))
        return NSPoint(x: strip.minX + CGFloat(index) * (width + 2) + width / 2, y: strip.midY)
    }

    /// The new-terminal (0) and globe (1) buttons, right after the tabs.
    private func buttonPoint(_ index: Int, in strip: NSRect) -> NSPoint {
        let count = AppModel.shared.stripTabs?.tabs.count ?? 0
        let width = TabStripMetrics.tabWidth(count: count, available: Double(strip.width - 2 * TabStripLayout.buttonWidth - 4))
        let afterTabs = strip.minX + CGFloat(TabStripMetrics.contentWidth(count: count, tabWidth: width)) + 2
        return NSPoint(x: afterTabs + CGFloat(index) * (TabStripLayout.buttonWidth + 2) + TabStripLayout.buttonWidth / 2, y: strip.midY)
    }

    private func nativeScreens(main: NSWindow, strip: NSRect?) async {
        let model = AppModel.shared
        let webView = model.web.webView
        // The session window from step 3 shows a test screen too; close it so the
        // counts below are the main window's alone.
        for window in NSApplication.shared.windows where window.isVisible && window.title.hasPrefix("screen=session id=t1") { window.close() }
        try? await Task.sleep(for: .milliseconds(500))
        _ = try? await webView.evaluateJavaScript("window.__marker = 42; true")

        check(model.visibleSidebar?.item(id: "browser") == nil, "browser: no separate Browser row in the sidebar")
        guard let strip else { return check(false, "native: found the tab strip") }

        func clickRow(_ id: String) async { // what the sidebar List's selection binding calls
            model.select(id)
            try? await Task.sleep(for: .milliseconds(300))
        }
        func clickTab(_ index: Int) async {
            click(main, at: tabPoint(index, in: strip))
            try? await Task.sleep(for: .milliseconds(300))
        }
        func pageHasFocus() -> Bool {
            guard let responder = main.firstResponder as? NSView else { return false }
            return responder === webView || responder.isDescendant(of: webView)
        }
        func activeTabs() -> [String] { model.stripTabs?.tabs.filter(\.active).map(\.id) ?? [] }

        await clickRow("tasks")
        check(await waitFor(3) { !NativeStub.anyShowing && model.currentScreen?.id == "tasks" },
              "native: a screen with no native version (Tasks) shows the page")
        check(pageHasFocus(), "native: the page has keyboard focus while it shows")

        await clickTab(0) // t1
        check(await waitFor(3) { NativeStub.isShowing("session/t1") }, "native: a session tab with a native screen shows it")
        check((await commandsRun()).contains("select-tab:t1"), "native: the page still hears select-tab")

        await clickTab(2) // b1
        check(await waitFor(3) { NativeStub.isShowing("browser/b1") && !NativeStub.isShowing("session/t1") },
              "browser: selecting a browser tab shows the native browser")
        check(!(await commandsRun()).contains("select-tab:b1"), "browser: the page is not told about native browser tabs")
        check(activeTabs() == ["b1"] && model.listSelection == nil, "browser: exactly one tab looks selected (b1)")
        check(webView.window === main, "native: the page stays alive underneath")
        check(!pageHasFocus(), "native: keyboard focus leaves the hidden page")
        _ = try? await webView.evaluateJavaScript("sendSidebar(); sendTabs(); true")
        try? await Task.sleep(for: .milliseconds(500))
        check(NativeStub.isShowing("browser/b1"), "browser: a sidebar update from the page does not knock the browser tab off screen")

        // A dialog the page opens comes in front of the native screen, then goes back.
        func pageIsInFront() -> Bool {
            guard let frameView = main.contentView?.superview else { return false }
            let page = webView.convert(webView.bounds, to: nil)
            let hit = frameView.hitTest(NSPoint(x: page.midX, y: page.midY))
            return hit === webView || (hit?.isDescendant(of: webView) ?? false)
        }
        check(!pageIsInFront(), "page dialog: before it opens, the native screen is in front")
        pagePosts("{type:'page-modal', open:true}")
        check(await waitFor(3) { pageIsInFront() && NativeStub.isShowing("browser/b1") },
              "page dialog: open, the page is in front and the native screen stays mounted underneath")
        check(pageHasFocus(), "page dialog: keyboard focus goes to the dialog")
        pagePosts("{type:'page-modal', open:false}")
        check(await waitFor(3) { !pageIsInFront() && NativeStub.isShowing("browser/b1") },
              "page dialog: closed, the native screen is back in front")
        check(await waitFor(2) { !pageHasFocus() }, "page dialog: keyboard focus leaves the hidden page again")

        // Right-click ▸ Open in New Window on the browser tab.
        let menu = contextMenu(in: main, at: tabPoint(2, in: strip))
        check(choose("Open in New Window", in: menu), "browser: its tab offers Open in New Window")
        check(await waitFor(5) { windows(titled: "Start Page").count == 1 && NativeStub.isShowing("browser/b1") },
              "browser: the tab opens in a native window of its own")
        check(!(model.stripTabs?.tabs.contains { $0.id == "b1" } ?? true) && NativeStub.isShowing("session/t1"),
              "browser: it leaves the strip meanwhile; the main window shows the page's tab again")
        windows(titled: "Start Page").first?.close()
        check(await waitFor(3) { model.stripTabs?.tabs.contains { $0.id == "b1" } == true },
              "browser: closing its window puts the tab back in the strip")
        let remembered = ScreenRef.decodeList(UserDefaults.standard.data(forKey: "openScreenWindows"))
        check(!remembered.contains { $0.kind == .browser }, "browser: its window is not reopened at launch")

        // Close Tab (the ✕ shows on hover; the menu's item does the same).
        try? await Task.sleep(for: .milliseconds(600)) // let the strip lay the tab back in
        let closeMenu = contextMenu(in: main, at: tabPoint(2, in: strip))
        if !choose("Close Tab", in: closeMenu) { print("      menu at b1: \(closeMenu?.items.map(\.title) ?? [])") }
        check(await waitFor(3) { FakeBrowserTabs.shared.list.isEmpty && model.stripTabs?.tabs.count == 2 },
              "browser: Close Tab closes the native tab")

        // A tab the browser opens itself (⌘T inside it, a link opened in a new tab).
        let opened = FakeBrowserTabs.shared.simulateBrowserOpensTab()
        check(await waitFor(3) { NativeStub.isShowing("browser/\(opened)") && activeTabs() == [opened] },
              "browser: a tab the browser opens itself comes forward")
        // Closing the browser tab on show: its neighbour comes forward; the last hands back to the page.
        model.newBrowserTab()
        let newest = FakeBrowserTabs.shared.list.last?.id ?? ""
        model.closeTab(newest)
        check(await waitFor(3) { activeTabs() == [opened] && NativeStub.isShowing("browser/\(opened)") },
              "browser: closing the tab on show brings its neighbour forward")
        model.closeTab(opened)
        check(await waitFor(3) { !NativeStub.anyShowing || NativeStub.isShowing("session/t1") },
              "browser: closing the last one hands back to the page's tab")

        await clickRow("tasks")
        check(await waitFor(3) { !NativeStub.anyShowing }, "native: back to Tasks, the page shows again")
        check((try? await webView.evaluateJavaScript("window.__marker")) as? Int == 42,
              "native: the page was kept, never reloaded")
        check(await waitFor(2) { pageHasFocus() }, "native: keyboard focus returns to the page")

        // Settings: ⌘, asks the page; the page answers with the URL; the window opens.
        model.requestSettings()
        check(await waitFor(10) { NativeStub.isShowing("settings/general") }, "native: Settings shows a section's native version")
        model.selectSettingsSection("hoot") // what clicking the row does
        check(await waitFor(3) { !NativeStub.isShowing("settings/general") }, "native: a section without one shows the page")
        let settingsRan = (try? await model.settingsWeb.webView.evaluateJavaScript("JSON.stringify(window.__ran)")) as? String ?? ""
        check(settingsRan.contains("settings-section:hoot"), "native: the Settings page still hears settings-section")
        // Close Settings (titled after its selected section, now Hoot).
        NSApplication.shared.windows.first { $0.isVisible && $0.title == "Hoot" }?.close()
    }

    private func finish() {
        print(failures == 0 ? "ALL PASSED" : "\(failures) FAILED")
        fflush(stdout)
        exit(failures == 0 ? 0 : 1) // the fake engine sees its stdin close and stops
    }
}
