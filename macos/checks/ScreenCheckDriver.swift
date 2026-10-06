import AppKit
import SwiftUI
import WebKit
import TerminalDeckNativeCore

// On-screen check against the REAL engine — the app's real scenes, screens and
// AppModel, with a different bundle id and its own data folder, driven from outside
// through a command folder (macos/checks/screen-check.sh). It never activates: no
// Dock icon, it cannot come to the front, so its windows open BEHIND what the person
// is using and are captured with `screencapture -l <window>`. Input is real AppKit
// events delivered to its own windows; nothing is posted to the system.

@main
struct ScreenCheckApp: App {
    @NSApplicationDelegateAdaptor(ScreenCheckDelegate.self) private var delegate
    var body: some Scene { TerminalDeckScenes(model: AppModel.shared) }
}

@MainActor
final class ScreenCheckDelegate: NSObject, NSApplicationDelegate {
    private var signalSources: [any DispatchSourceSignal] = []

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.prohibited) // never in front, never takes focus
        NSWindow.allowsAutomaticWindowTabbing = false
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        for sig in [SIGTERM, SIGINT, SIGHUP] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler { MainActor.assumeIsolated { NSApplication.shared.terminate(nil) } }
            source.resume()
            signalSources.append(source)
        }
        AppModel.shared.startEngine()
        IslandController.shared.start()
        // IntentsLaunch is left out: it would tell Siri about a test app.
        ScreenCheckDriver.shared.start()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        AppModel.shared.isTerminating = true
        return .terminateNow
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationWillTerminate(_ notification: Notification) {
        AppModel.shared.shutdown()
    }
}

@MainActor
final class ScreenCheckDriver {
    static let shared = ScreenCheckDriver()
    private let dir = URL(fileURLWithPath: ProcessInfo.processInfo.environment["SC_DIR"] ?? NSTemporaryDirectory() + "sc")
    private var timer: Timer?
    private var busy = false
    private var lastMenu: NSMenu?

    func start() {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? "ready \(ProcessInfo.processInfo.processIdentifier)".write(to: dir.appendingPathComponent("ready"), atomically: true, encoding: .utf8)
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
            MainActor.assumeIsolated { ScreenCheckDriver.shared.poll() }
        }
    }

    /// This check runs while the screen may be locked and its windows sit behind
    /// everything, so WebKit would treat every page as hidden and not paint it.
    /// For this test app only: turn WebKit's window-occlusion detection off on every
    /// web view (main page, Settings, screen windows, the island, browser tabs), so
    /// pages paint exactly as they do on screen. The shipping app never does this.
    private var unthrottled = Set<ObjectIdentifier>()
    private func keepPagesPainting() {
        for window in NSApplication.shared.windows {
            guard let root = window.contentView?.superview ?? window.contentView else { continue }
            for case let webView as WKWebView in allViews(root) where !unthrottled.contains(ObjectIdentifier(webView)) {
                unthrottled.insert(ObjectIdentifier(webView))
                if webView.responds(to: NSSelectorFromString("_setWindowOcclusionDetectionEnabled:")) {
                    webView.setValue(false, forKey: "windowOcclusionDetectionEnabled")
                    // WebKit reads that when it works out visibility; make it work it out again.
                    webView.isHidden = true
                    webView.isHidden = false
                }
            }
        }
    }
    private var tick = 0

    /// Every window the app opens is put at the very back the first time it is
    /// seen: on screen (so it renders and can be captured) but behind everything
    /// the person has open. This app can never come to the front anyway.
    private var placed = Set<ObjectIdentifier>()
    private func keepWindowsBehind() {
        for window in NSApplication.shared.windows where String(describing: Swift.type(of: window)) == "AppKitWindow" {
            let id = ObjectIdentifier(window)
            guard !placed.contains(id), window.contentView != nil else { continue }
            placed.insert(id)
            window.orderBack(nil)
        }
    }

    private func poll() {
        tick += 1
        keepWindowsBehind()
        if tick % 5 == 0 { keepPagesPainting() }
        guard !busy, let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return }
        guard let next = names.filter({ $0.hasSuffix(".cmd") }).sorted().first else { return }
        let cmdURL = dir.appendingPathComponent(next)
        let resURL = dir.appendingPathComponent(next.replacingOccurrences(of: ".cmd", with: ".res"))
        let line = (try? String(contentsOf: cmdURL, encoding: .utf8)) ?? ""
        try? FileManager.default.removeItem(at: cmdURL)
        busy = true
        Task { @MainActor in
            let result = await self.run(line.trimmingCharacters(in: .whitespacesAndNewlines))
            try? result.write(to: resURL, atomically: true, encoding: .utf8)
            self.busy = false
        }
    }

    // MARK: Commands

    private func run(_ line: String) async -> String {
        let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
        let verb = parts.first ?? ""
        let rest = parts.count > 1 ? parts[1] : ""
        let args = rest.split(separator: " ").map(String.init)
        let model = AppModel.shared
        switch verb {
        case "windows": return windowsReport()
        case "open":
            return await open(rest)
        case "winid":
            guard let window = window(rest) else { return "error: no window \(rest)" }
            return "\(window.windowNumber)"
        case "family":
            // A window and what is drawn in its own windows on top of it (sheets,
            // popovers, child windows), with frames, for a composite shot.
            guard let window = window(rest) else { return "error: no window \(rest)" }
            var family = [window]
            var queue = [window]
            while let next = queue.popLast() {
                let more = (next.sheets + (next.childWindows ?? [])).filter { $0.isVisible && !family.contains($0) }
                family += more
                queue += more
            }
            return family.map { w in
                let f = w.frame
                return "\(w.windowNumber) \(Int(f.minX)) \(Int(f.minY)) \(Int(f.width)) \(Int(f.height)) \(w.backingScaleFactor)"
            }.joined(separator: "\n")
        case "allwindows":
            return NSApplication.shared.windows.map { w in
                "\(w.windowNumber)\t\(String(describing: Swift.type(of: w)))\t\"\(w.title)\"\tvisible=\(w.isVisible)\tonActiveSpace=\(w.isOnActiveSpace)\toccluded=\(!w.occlusionState.contains(.visible))\t\(w.frame)"
            }.joined(separator: "\n")
        case "screens": return screensReport()
        case "state": return stateReport()
        case "drawn": // who draws what is on show: the main screen, the Settings section, page modals
            let m = AppModel.shared
            let main = m.currentScreen.map { NativeScreens.detail(kind: $0.kind, id: $0.id) != nil ? "native(\($0.kind)/\($0.id))" : "PAGE(\($0.kind)/\($0.id))" } ?? "empty-state(native)"
            let section = m.settingsSelection.map { NativeScreens.settings(sectionId: $0) != nil ? "native(\($0))" : "PAGE(\($0))" } ?? "-"
            return "main=\(main) settings=\(section) pageModal=\(m.pageModalOpen) dialogs=\(m.dialogs.keys.sorted().joined(separator: ","))"
        case "wait": // wait <seconds> (at most 10): let the page and its hand-overs settle
            let seconds = min(10, max(0, Double(args.first ?? "") ?? 1))
            try? await Task.sleep(for: .seconds(seconds))
            return "ok"
        case "browser": return browserReport()
        case "click", "rclick", "hover", "dclick":
            guard args.count >= 3, let window = window(args[0]), let x = Double(args[1]), let y = Double(args[2]) else { return "error: \(verb) <win> <x> <y>" }
            let point = NSPoint(x: x, y: window.frame.height - y)
            switch verb {
            case "click": click(window, point, count: 1); return "ok"
            case "dclick": click(window, point, count: 2); return "ok"
            case "hover":
                send(window, .mouseMoved, point)
                return "ok"
            default:
                lastMenu = contextMenu(window, point)
                return lastMenu.map { "menu: " + $0.items.map { $0.isSeparatorItem ? "—" : $0.title }.joined(separator: " | ") } ?? "no menu"
            }
        case "menu":
            guard let menu = lastMenu, let index = menu.items.firstIndex(where: { $0.title == rest }) else { return "error: no item \(rest)" }
            menu.performActionForItem(at: index)
            return "ok"
        case "drag":
            guard args.count >= 5, let window = window(args[0]) else { return "error: drag <win> x1 y1 x2 y2" }
            let v = args[1...4].compactMap(Double.init)
            guard v.count == 4 else { return "error: numbers" }
            drag(window, from: NSPoint(x: v[0], y: window.frame.height - v[1]), to: NSPoint(x: v[2], y: window.frame.height - v[3]))
            return "ok"
        case "type":
            guard let space = rest.firstIndex(of: " "), let window = window(String(rest[..<space])) else { return "error: type <win> <text>" }
            typeText(window, unescape(String(rest[rest.index(after: space)...])))
            return "ok"
        case "key":
            guard args.count >= 2, let window = window(args[0]) else { return "error: key <win> <combo>" }
            return key(window, args[1]) ? "ok" : "error: unknown key \(args[1])"
        case "orderback":
            // On screen, but behind every other window: never in front of the person.
            guard let window = window(args.first ?? "", includeHidden: true) else { return "error: window" }
            window.orderBack(nil)
            return "ok visible=\(window.isVisible)"
        case "vclick", "vdrag":
            // What AppKit does with a click in a KEY window: the view under it gets
            // mouseDown/mouseUp (and takes the keyboard if it wants it). This app can
            // never be key — it may not come to the front — so AppKit would treat every
            // click as a "first mouse" and swallow it for views that don't accept that.
            guard let window = window(args.first ?? ""), let frameView = window.contentView?.superview else { return "error: window" }
            let v = args.dropFirst().compactMap(Double.init)
            guard (verb == "vclick" && v.count == 2) || (verb == "vdrag" && v.count == 4) else { return "error: numbers" }
            let a = NSPoint(x: v[0], y: window.frame.height - v[1])
            guard let target = frameView.hitTest(a) else { return "nothing there" }
            if target.acceptsFirstResponder { window.makeFirstResponder(target) }
            guard let down = mouse(.leftMouseDown, window, a) else { return "error: event" }
            target.mouseDown(with: down)
            if verb == "vdrag" {
                let b = NSPoint(x: v[2], y: window.frame.height - v[3])
                for i in 1...12 {
                    let t = CGFloat(i) / 12
                    let p = NSPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t + sin(t * .pi) * 30)
                    if let e = mouse(.leftMouseDragged, window, p) { target.mouseDragged(with: e) }
                    try? await Task.sleep(for: .milliseconds(16))
                }
                if let up = mouse(.leftMouseUp, window, b) { target.mouseUp(with: up) }
            } else {
                try? await Task.sleep(for: .milliseconds(60))
                if let up = mouse(.leftMouseUp, window, a) { target.mouseUp(with: up) }
            }
            return "ok → \(String(describing: Swift.type(of: target)))"
        case "hit", "focus":
            guard args.count >= 3, let window = window(args[0]), let x = Double(args[1]), let y = Double(args[2]),
                  let frameView = window.contentView?.superview else { return "error: \(verb) <win> <x> <y>" }
            var chain: [NSView] = []
            var v = frameView.hitTest(NSPoint(x: x, y: window.frame.height - y))
            while let view = v, chain.count < 12 { chain.append(view); v = view.superview }
            if verb == "hit" {
                return chain.map { "\(String(describing: Swift.type(of: $0)))\($0.acceptsFirstResponder ? "*" : "")" }.joined(separator: " ← ")
            }
            // What AppKit does for a click in an active window: the clicked view takes the keyboard.
            guard let target = chain.first(where: \.acceptsFirstResponder) else { return "nothing there takes focus" }
            let ok = window.makeFirstResponder(target)
            return "makeFirstResponder(\(String(describing: Swift.type(of: target)))) = \(ok); now \(window.firstResponder.map { String(describing: Swift.type(of: $0)) } ?? "nil")"
        case "makekey":
            guard let window = window(args.first ?? "") else { return "error: window" }
            window.makeKey()
            return "ok key=\(window.isKeyWindow)"
        case "responder":
            guard let window = window(args.first ?? "") else { return "error: window" }
            var chain: [String] = []
            var r: NSResponder? = window.firstResponder
            while let current = r, chain.count < 8 { chain.append(String(describing: type(of: current))); r = current.nextResponder }
            return chain.joined(separator: " → ")
        case "js":
            guard let space = rest.firstIndex(of: " ") else { return "error: js <main|settings|win> <body>" }
            let target = String(rest[..<space])
            let body = String(rest[rest.index(after: space)...])
            guard let webView = webView(target) else { return "error: no page \(target)" }
            do {
                let value = try await webView.callAsyncJavaScript(body, arguments: [:], in: nil, contentWorld: .page)
                if let value, JSONSerialization.isValidJSONObject(value),
                   let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) {
                    return String(decoding: data, as: UTF8.self)
                }
                return String(describing: value ?? "null")
            } catch {
                return "js error: \(error.localizedDescription)"
            }
        case "jsat":
            // jsat <win> <x> <y> <body>: script in the web view under that point.
            let p = rest.split(separator: " ", maxSplits: 3).map(String.init)
            guard p.count == 4, let window = window(p[0]), let x = Double(p[1]), let y = Double(p[2]),
                  let frameView = window.contentView?.superview else { return "error: jsat <win> <x> <y> <body>" }
            var v = frameView.hitTest(NSPoint(x: x, y: window.frame.height - y))
            while let view = v, !(view is WKWebView) { v = view.superview }
            guard let webView = v as? WKWebView else { return "no web view there" }
            do {
                let value = try await webView.callAsyncJavaScript(p[3], arguments: [:], in: nil, contentWorld: .page)
                let extra = " [\(String(describing: Swift.type(of: webView))) url=\(webView.url?.absoluteString ?? "nil") loading=\(webView.isLoading) hidden=\(webView.isHiddenOrHasHiddenAncestor) frame=\(webView.frame)]"
                if let value, JSONSerialization.isValidJSONObject(value),
                   let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) {
                    return String(decoding: data, as: UTF8.self) + extra
                }
                return String(describing: value ?? "null") + extra
            } catch { return "js error: \(error.localizedDescription)" }
        case "viewshot":
            // The window's own views drawn by AppKit into an image (no window server):
            // shows what SwiftUI/AppKit draws, not web or Metal content.
            guard args.count >= 2, let window = window(args[0]), let view = window.contentView,
                  let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return "error: viewshot <win> <path>" }
            view.cacheDisplay(in: view.bounds, to: rep)
            guard let png = rep.representation(using: .png, properties: [:]) else { return "error: png" }
            try? png.write(to: URL(fileURLWithPath: args[1]))
            return "ok \(rep.pixelsWide)x\(rep.pixelsHigh) alpha=\(window.alphaValue) opaque=\(window.isOpaque)"
        case "bridge":
            // bridge <channel> [json-args]: the engine's answer, as a native screen gets it.
            let p = rest.split(separator: " ", maxSplits: 1).map(String.init)
            guard let channel = p.first else { return "error: bridge <channel>" }
            var callArgs: [Any?] = []
            if p.count > 1, let parsed = try? JSONSerialization.jsonObject(with: Data(p[1].utf8)), let list = parsed as? [Any] {
                callArgs = list.map { Optional($0) }
            }
            do {
                let answer = try await EngineBridge.shared.invoke(channel, callArgs)
                if JSONSerialization.isValidJSONObject(answer),
                   let data = try? JSONSerialization.data(withJSONObject: answer, options: [.sortedKeys]) {
                    return String(String(decoding: data, as: UTF8.self).prefix(1500))
                }
                return String(describing: answer)
            } catch { return "bridge error: \(error)" }
        case "splits":
            guard let window = window(args.first ?? ""), let root = window.contentView else { return "error: window" }
            return allViews(root).compactMap { $0 as? NSSplitView }.map { split in
                "NSSplitView: " + split.arrangedSubviews.map { "\(Int($0.frame.width))x\(Int($0.frame.height))" }.joined(separator: " | ")
            }.joined(separator: "\n")
        case "do":
            return doAction(args)
        case "close":
            window(args.first ?? "")?.close()
            return "ok"
        case "quit":
            NSApplication.shared.terminate(nil)
            return "ok"
        default:
            return "error: unknown command \(verb)"
        }
    }

    /// open <target> — open a screen and answer "<window number>" once it is on show.
    ///   <sidebar id>              a sidebar item: overview, files, artifacts, git, simulators,
    ///                             tasks, memory, staysfixed, store, github, readiness, mcp,
    ///                             remote, hooks, alerts, hoot …     → the main window
    ///   settings:<section id>     general, appearance, notifications, agents, features, browser,
    ///                             scraping, copilot, ai-apps, tasks, plugins, power, advanced, help …
    ///   window:<panel|session|browser>:<id>   a screen in a window of its own
    ///   session                   a fresh local shell session, selected (its tab in the strip)
    private func open(_ target: String) async -> String {
        let model = AppModel.shared
        guard await until(30, { model.pageReady && model.visibleSidebar != nil }) else { return "error: the page never became ready" }
        if target == "session" {
            let folder = (ProcessInfo.processInfo.environment["SC_ROOT"] ?? NSTemporaryDirectory()) + "/project"
            try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
            let made = try? await model.web.webView.callAsyncJavaScript(
                "const m = await window.deck.createSession({cwd: dir, cols: 100, rows: 30, provider: 'shell'}); return m.id",
                arguments: ["dir": folder], in: nil, contentWorld: .page)
            guard let id = made as? String else { return "error: no session was made" }
            // The page lists sessions it adopts at load: reload it, then pick the new one.
            model.web.webView.reload()
            guard await until(30, { model.pageReady && model.stripTabs?.tabs.contains { $0.id == id } == true }) else {
                return "error: the page did not pick up session \(id)"
            }
            model.selectTab(id)
            _ = await until(10, { model.currentScreen?.id == id })
            try? await Task.sleep(for: .seconds(1))
            return mainNumber() + " session=\(id)"
        }
        if target.hasPrefix("settings:") {
            let section = String(target.dropFirst("settings:".count))
            model.requestSettings()
            guard await until(20, { model.settingsReady && !model.settingsSections.isEmpty }) else { return "error: Settings did not open" }
            guard model.settingsSections.contains(where: { $0.id == section }) else {
                return "error: no section \(section) (there are: \(model.settingsSections.map(\.id).joined(separator: " ")))"
            }
            // The page answers its first load with its own selection, which can land after
            // ours: ask both sides, then hold until the section has stayed put for 2 s.
            let ask = "window.tdNative && window.tdNative.run('settings-section', \"\(section)\")"
            model.selectSettingsSection(section)
            _ = try? await model.settingsWeb.webView.evaluateJavaScript(ask)
            var steady = 0
            for _ in 0..<48 where steady < 8 {
                try? await Task.sleep(for: .milliseconds(250))
                if model.settingsSelection == section { steady += 1; continue }
                steady = 0
                model.selectSettingsSection(section)
                _ = try? await model.settingsWeb.webView.evaluateJavaScript(ask)
            }
            guard model.settingsSelection == section else { return "error: Settings kept showing \(model.settingsSelection ?? "nothing")" }
            guard let window = NSApplication.shared.windows.first(where: { $0.isVisible && $0.identifier?.rawValue.hasPrefix(SettingsWindow.sceneID) == true })
                ?? NSApplication.shared.windows.first(where: { $0.isVisible && $0.title == model.settingsTitle }) else { return "error: no Settings window" }
            return "\(window.windowNumber)"
        }
        if target.hasPrefix("window:") {
            let parts = target.split(separator: ":").map(String.init)
            guard parts.count >= 3, let kind = ScreenRef.Kind(rawValue: parts[1]) else { return "error: window:<panel|session|browser>:<id>" }
            let id = parts[2...].joined(separator: ":")
            let before = Set(NSApplication.shared.windows.map(\.windowNumber))
            model.openScreenWindow(ScreenRef(kind: kind, id: id, isHoot: id == "hoot"))
            guard await until(15, { NSApplication.shared.windows.contains { $0.isVisible && !before.contains($0.windowNumber) && String(describing: Swift.type(of: $0)) == "AppKitWindow" } }) else {
                return "error: no window opened"
            }
            try? await Task.sleep(for: .seconds(3))
            let opened = NSApplication.shared.windows.first { $0.isVisible && !before.contains($0.windowNumber) && String(describing: Swift.type(of: $0)) == "AppKitWindow" }
            return opened.map { "\($0.windowNumber)" } ?? "error: no window"
        }
        // A sidebar item.
        guard model.visibleSidebar?.item(id: target) != nil else {
            let ids = model.visibleSidebar?.allItems.map(\.id).joined(separator: " ") ?? "-"
            return "error: no sidebar item \(target) (there are: \(ids))"
        }
        model.select(target)
        if target == "alerts" { // the bell opens the Alerts sheet over what is on show; it is not a place
            guard await until(15, { model.dialogs["alerts-sheet"] != nil }) else { return "error: the Alerts sheet never opened" }
            return mainNumber()
        }
        guard await until(15, { model.currentScreen?.id == target }) else { return "error: \(target) never came on show" }
        try? await Task.sleep(for: .seconds(2)) // let it load and draw
        return mainNumber()
    }

    private func mainNumber() -> String {
        window("main").map { "\($0.windowNumber)" } ?? "error: no main window"
    }

    private func until(_ seconds: Double, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return condition()
    }

    private func doAction(_ args: [String]) -> String {
        let model = AppModel.shared
        guard let action = args.first else { return "error: do <action>" }
        let arg = args.dropFirst().joined(separator: " ")
        switch action {
        case "select": model.select(arg)
        case "tab": model.selectTab(arg)
        case "newbrowser": model.newBrowserTab()
        case "newterminal": model.newTerminalTab()
        case "newsession": model.newSession()
        case "settings": model.requestSettings()
        case "section": model.selectSettingsSection(arg)
        case "window":
            let parts = arg.split(separator: " ", maxSplits: 1).map(String.init)
            guard parts.count == 2, let kind = ScreenRef.Kind(rawValue: parts[0]) else { return "error: do window <panel|session|browser> <id>" }
            model.openScreenWindow(ScreenRef(kind: kind, id: parts[1], isHoot: parts[1] == "hoot"))
        default: return "error: unknown action \(action)"
        }
        return "ok"
    }

    // MARK: Reports

    private func windowsReport() -> String {
        NSApplication.shared.windows.filter(\.isVisible).map { w in
            let f = w.frame
            return "\(w.windowNumber)\t\(type(of: w))\t\"\(w.title)\"\t\(Int(f.minX)),\(Int(f.minY)) \(Int(f.width))x\(Int(f.height))\tscale=\(w.backingScaleFactor)\tlevel=\(w.level.rawValue)\tkey=\(w.isKeyWindow)\tscreen=\(w.screen?.localizedName ?? "-")"
        }.joined(separator: "\n")
    }

    private func screensReport() -> String {
        NSScreen.screens.map { s in
            let notch = s.auxiliaryTopLeftArea != nil || s.safeAreaInsets.top > 0
            return "\(s.localizedName)\tframe=\(s.frame)\tvisible=\(s.visibleFrame)\tscale=\(s.backingScaleFactor)\tsafeTop=\(s.safeAreaInsets.top)\tnotch=\(notch)\tmain=\(s == NSScreen.main)"
        }.joined(separator: "\n")
    }

    private func stateReport() -> String {
        let m = AppModel.shared
        var out: [String] = []
        out.append("engine=\(m.engine.phase) pageReady=\(m.pageReady) canRun=\(m.canRun) title=\"\(m.windowTitle)\" subtitle=\"\(m.windowSubtitle)\"")
        out.append("current=\(m.currentScreen.map { "\($0.kind)/\($0.id)" } ?? "-") listSelection=\(m.listSelection ?? "-") pageModal=\(m.pageModalOpen) dialogs=\(m.dialogs.keys.sorted().joined(separator: ","))")
        if let tabs = m.stripTabs {
            out.append("strip: " + tabs.tabs.map { "\($0.active ? "*" : "")\($0.kind):\($0.id)=\"\($0.title)\"" }.joined(separator: "  ") + "  newTerminal=\(tabs.canNewTerminal) newBrowser=\(tabs.canNewBrowser)")
        } else {
            out.append("strip: none")
        }
        if let sidebar = m.visibleSidebar {
            for group in sidebar.groups {
                out.append("group \(group.id) \"\(group.title ?? "")\": " + group.items.map { "\($0.kind.name):\($0.id)" }.joined(separator: " "))
            }
            for project in sidebar.projects {
                out.append("project \(project.id) expanded=\(project.expanded): " + project.sessions.map { "\($0.id)=\"\($0.title)\"\($0.status.map { " [\($0)]" } ?? "")" }.joined(separator: " "))
            }
        }
        out.append("settings: \(m.settingsSections.map { "\($0.id)\($0.isHoot ? "(hoot)" : "")" }.joined(separator: " ")) selected=\(m.settingsSelection ?? "-") ready=\(m.settingsReady)")
        return out.joined(separator: "\n")
    }

    private func browserReport() -> String {
        (BrowserTabsHook.provider?.browserTabs ?? []).map { "\($0.id)\t\"\($0.title)\"\tloading=\($0.loading)" }.joined(separator: "\n")
    }

    // MARK: Windows and pages

    private func window(_ ref: String, includeHidden: Bool = false) -> NSWindow? {
        let visible = NSApplication.shared.windows.filter { includeHidden || $0.isVisible }
        if ref == "main" { return visible.first { $0.identifier?.rawValue.hasPrefix("main") == true } ?? visible.first { $0.title == AppModel.shared.windowTitle } }
        if ref == "settings" { return visible.first { $0.identifier?.rawValue.hasPrefix(SettingsWindow.sceneID) == true } ?? visible.first { $0.title == AppModel.shared.settingsTitle } }
        if ref == "island" { return visible.first { String(describing: Swift.type(of: $0)) == "IslandPanel" } }
        if let number = Int(ref) { return visible.first { $0.windowNumber == number } }
        return visible.first { $0.title == ref }
    }

    private func webView(_ target: String) -> WKWebView? {
        switch target {
        case "main": return AppModel.shared.web.webView
        case "settings": return AppModel.shared.settingsWeb.webView
        default:
            guard let window = window(target), let root = window.contentView else { return nil }
            return allViews(root).compactMap { $0 as? WKWebView }.first
        }
    }

    private func allViews(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(allViews) }

    // MARK: Events (delivered to our own windows only)

    private func mouse(_ type: NSEvent.EventType, _ window: NSWindow, _ point: NSPoint, count: Int = 1) -> NSEvent? {
        NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                           windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: count,
                           pressure: type == .leftMouseDown || type == .leftMouseDragged ? 1 : 0)
    }

    private func send(_ window: NSWindow, _ type: NSEvent.EventType, _ point: NSPoint) {
        if let event = mouse(type, window, point) { window.sendEvent(event) }
    }

    /// Mouse-up queued first, so a control's tracking loop finds it; WebKit, which has
    /// no tracking loop, gets it from the queue straight after.
    private func click(_ window: NSWindow, _ point: NSPoint, count: Int) {
        for n in 1...count {
            guard let down = mouse(.leftMouseDown, window, point, count: n), let up = mouse(.leftMouseUp, window, point, count: n) else { return }
            NSApplication.shared.postEvent(up, atStart: false)
            window.sendEvent(down)
        }
    }

    private func drag(_ window: NSWindow, from a: NSPoint, to b: NSPoint) {
        guard let down = mouse(.leftMouseDown, window, a) else { return }
        let steps = 12
        for i in 1...steps {
            let t = CGFloat(i) / CGFloat(steps)
            // a gentle curve, so a drawing tool has something to draw
            let p = NSPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t + sin(t * .pi) * 30)
            if let dragged = mouse(.leftMouseDragged, window, p) { NSApplication.shared.postEvent(dragged, atStart: false) }
        }
        if let up = mouse(.leftMouseUp, window, b) { NSApplication.shared.postEvent(up, atStart: false) }
        window.sendEvent(down)
    }

    private func contextMenu(_ window: NSWindow, _ point: NSPoint) -> NSMenu? {
        guard let frameView = window.contentView?.superview, let event = mouse(.rightMouseDown, window, point) else { return nil }
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

    private func unescape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\n", with: "\r").replacingOccurrences(of: "\\r", with: "\r")
            .replacingOccurrences(of: "\\t", with: "\t").replacingOccurrences(of: "\\e", with: "\u{1b}")
    }

    private static let keyCodes: [Character: UInt16] = {
        var map: [Character: UInt16] = [:]
        let rows: [(String, [UInt16])] = [
            ("asdfhgzxcv", [0, 1, 2, 3, 4, 5, 6, 7, 8, 9]), ("bqweryt", [11, 12, 13, 14, 15, 16, 17]),
            ("123465", [18, 19, 20, 21, 22, 23]), ("=97-80]ou[ip", [24, 25, 26, 27, 28, 29, 30, 31, 32, 33, 34, 35]),
            ("lj'k;\\,/nm.", [37, 38, 39, 40, 41, 42, 43, 44, 45, 46, 47]), ("`", [50]),
        ]
        for (chars, codes) in rows { for (c, k) in zip(chars, codes) { map[c] = k } }
        map[" "] = 49; map["\r"] = 36; map["\t"] = 48; map["\u{1b}"] = 53
        return map
    }()

    private func keyEvent(_ window: NSWindow, _ type: NSEvent.EventType, chars: String, code: UInt16, flags: NSEvent.ModifierFlags = []) -> NSEvent? {
        NSEvent.keyEvent(with: type, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                         windowNumber: window.windowNumber, context: nil, characters: chars,
                         charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code)
    }

    private func typeText(_ window: NSWindow, _ text: String) {
        for c in text {
            let lower = Character(c.lowercased())
            let code = Self.keyCodes[lower] ?? Self.keyCodes[c] ?? 0
            let flags: NSEvent.ModifierFlags = c.isUppercase ? [.shift] : []
            if let down = keyEvent(window, .keyDown, chars: String(c), code: code, flags: flags) { window.sendEvent(down) }
            if let up = keyEvent(window, .keyUp, chars: String(c), code: code, flags: flags) { window.sendEvent(up) }
        }
    }

    private func key(_ window: NSWindow, _ combo: String) -> Bool {
        var flags: NSEvent.ModifierFlags = []
        var name = combo
        for (prefix, flag) in [("cmd+", NSEvent.ModifierFlags.command), ("shift+", .shift), ("opt+", .option), ("ctrl+", .control)] {
            while name.hasPrefix(prefix) { flags.insert(flag); name.removeFirst(prefix.count) }
        }
        let special: [String: (String, UInt16)] = [
            "return": ("\r", 36), "escape": ("\u{1b}", 53), "tab": ("\t", 48), "delete": ("\u{7f}", 51), "space": (" ", 49),
            "up": (String(UnicodeScalar(NSUpArrowFunctionKey)!), 126), "down": (String(UnicodeScalar(NSDownArrowFunctionKey)!), 125),
            "left": (String(UnicodeScalar(NSLeftArrowFunctionKey)!), 123), "right": (String(UnicodeScalar(NSRightArrowFunctionKey)!), 124),
        ]
        let (chars, code): (String, UInt16)
        if let s = special[name] { (chars, code) = s }
        else if name.count == 1, let c = name.first, let k = Self.keyCodes[c] { (chars, code) = (name, k) }
        else { return false }
        guard let down = keyEvent(window, .keyDown, chars: chars, code: code, flags: flags),
              let up = keyEvent(window, .keyUp, chars: chars, code: code, flags: flags) else { return false }
        if flags.contains(.command) {
            // Key equivalents: the window's views first, then the menus, as AppKit does.
            if !window.performKeyEquivalent(with: down) { _ = NSApplication.shared.mainMenu?.performKeyEquivalent(with: down) }
        } else if window.performKeyEquivalent(with: down) {
            // NSApplication offers every key-down as a key equivalent first: that is how
            // Return reaches a default button and Esc a cancel button in a sheet.
        } else {
            window.sendEvent(down)
            window.sendEvent(up)
        }
        return true
    }
}
