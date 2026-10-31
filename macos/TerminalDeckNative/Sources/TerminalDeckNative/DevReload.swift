import SwiftUI
#if DEBUG
import AppKit
import Darwin
import TerminalDeckBackend
import TerminalDeckNativeCore
import WebKit
#endif

/// Live reload for the dev copy ("Terminal Deck Dev", `macos/dev/devloop.sh`).
///
/// Debug builds only. A release build compiles `devReloadable()` to nothing, so the
/// shipped app is unchanged. In the dev copy, `devloop.sh` names the injection
/// library (InjectionLite, github.com/johnno1962/InjectionLite) in Info.plist; it is
/// loaded once, watches the Swift sources and swaps a saved file's new code into the
/// running app. Each window root then gets a new identity, so every view's body runs
/// again with the new code (like a page reload, in about a second).
extension View {
    func devReloadable() -> some View {
        #if DEBUG
        modifier(DevReloadRoot())
        #else
        self
        #endif
    }
}

#if DEBUG
@MainActor
final class DevReload: ObservableObject {
    static let shared = DevReload()
    /// Set at launch by the composition: runs one background turn with Hoot and returns its answer (or why not).
    nonisolated(unsafe) static var hootTest: (@Sendable (String) async -> String)?
    /// Takes the builders' old test exchanges out of the visible chat. Returns one plain line on what it did.
    nonisolated(unsafe) static var hootTidy: (@Sendable () async -> String)?
    /// Measures Hoot's records fence this many times in a row and says how many times it was not held.
    nonisolated(unsafe) static var fenceProbe: (@Sendable (Int) async -> String)?
    /// Turn-id prefixes the tidy request named (the builders' scratch tasks), besides the dev test door's own turns.
    nonisolated(unsafe) static var hootTidyTurns: [String] = []
    @Published private(set) var generation = 0

    /// The dev doors' lock (#612). devloop.sh gives each launch a secret (TD_DEV_INVOKE_TOKEN, and the same in the dev
    /// data folder's `dev-invoke-token` for its scripts). Every door's object is JSON {"token": …, plus its own fields};
    /// one without this launch's secret is ignored, so no other program on the Mac (not even a sandboxed one) can drive
    /// the app. No secret at launch: every door stays shut.
    nonisolated static let launchToken = ProcessInfo.processInfo.environment[NativeLaunchSwitches.devInvokeToken] ?? ""
    /// Answers and pictures are written only in here: `dev-out` in the dev copy's own data folder.
    nonisolated static let outFolder: URL? = ProcessInfo.processInfo.environment[NativeLaunchSwitches.dataFolder].flatMap {
        $0.hasPrefix("/") ? URL(fileURLWithPath: $0).appendingPathComponent("dev-out", isDirectory: true) : nil
    }

    /// The request a dev notification carries, or nil when its token is missing or wrong.
    nonisolated static func request(_ text: String?, token: String = DevReload.launchToken) -> [String: Any]? {
        guard !token.isEmpty, let text,
              let ask = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
              let given = ask["token"] as? String, given == token else { return nil }
        return ask
    }
    /// Where an answer may go: a file directly or deeper inside the dev folder, after resolving links and "..".
    nonisolated static func output(_ path: Any?, folder: URL? = DevReload.outFolder) -> URL? {
        guard let path = path as? String, path.hasPrefix("/"), let folder else { return nil }
        let root = folder.standardizedFileURL.resolvingSymlinksInPath().path
        let file = URL(fileURLWithPath: path).standardizedFileURL
        let parent = file.deletingLastPathComponent().resolvingSymlinksInPath().path
        guard !file.lastPathComponent.isEmpty, parent == root || parent.hasPrefix(root + "/") else { return nil }
        return URL(fileURLWithPath: parent).appendingPathComponent(file.lastPathComponent)
    }

    private init() {
        // InjectionLite posts this after it has loaded a recompiled file.
        NotificationCenter.default.addObserver(forName: Notification.Name("INJECTION_BUNDLE_NOTIFICATION"),
                                               object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { DevReload.shared.generation += 1 }
        }
        let info = Bundle.main.infoDictionary ?? [:]
        if let library = info["TDDevInjectionLibrary"] as? String, !library.isEmpty {
            if dlopen(library, RTLD_NOW) == nil {
                NSLog("[devloop] could not load %@: %@", library, String(cString: dlerror()))
            } else {
                NSLog("[devloop] live reload on: %@", library)
            }
        }
        if let folder = DevReload.outFolder {
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        // `devloop.sh shot FILE`: a picture of the main window without bringing the app
        // forward (works behind other windows and in Stage Manager's side strip). {"out": "<dev-out>/….png"}.
        DistributedNotificationCenter.default().addObserver(forName: Notification.Name("TerminalDeckDevSnapshot"),
                                                            object: nil, queue: .main) { note in
            guard let ask = DevReload.request(note.object as? String), let url = DevReload.output(ask["out"]) else { return }
            MainActor.assumeIsolated { DevReload.snapshot(to: url) }
        }
        // Dev copy only: give Hoot one test request from code as a BACKGROUND turn: nothing is typed into
        // the window and nothing shows in the person's chat (the diary stamps it "dev-test", never the person).
        // {"text": "…"}.
        DistributedNotificationCenter.default().addObserver(forName: Notification.Name("TerminalDeckDevHootSay"),
                                                            object: nil, queue: .main) { note in
            guard let text = DevReload.request(note.object as? String)?["text"] as? String, !text.isEmpty else { return }
            Task {
                guard let ask = DevReload.hootTest else { NSLog("[devloop] Hoot test: Hoot is not wired yet"); return }
                NSLog("[devloop] Hoot test answer: %@", await ask(text))
            }
        }
        // Dev copy only: the builders' way to run one of the app's own calls from a test script, so a check can
        // use the real path (create a scratch task, read its comments) without clicking in the window.
        // {"channel": "...", "args": [...], "out": "<dev-out>/answer.json"}.
        DistributedNotificationCenter.default().addObserver(forName: Notification.Name("TerminalDeckDevInvoke"),
                                                            object: nil, queue: .main) { note in
            guard let ask = DevReload.request(note.object as? String), let channel = ask["channel"] as? String,
                  let out = DevReload.output(ask["out"]) else { return }
            let args = ask["args"] as? [Any] ?? []
            Task { @MainActor in
                var answer: [String: Any]
                do { answer = ["ok": true, "value": try await EngineBridge.shared.invoke(channel, args)] }
                catch { answer = ["ok": false, "error": error.localizedDescription] }
                let data = (try? JSONSerialization.data(withJSONObject: answer, options: [.fragmentsAllowed, .sortedKeys])) ?? Data(#"{"ok":false,"error":"the answer could not be written as JSON"}"#.utf8)
                try? data.write(to: out, options: .atomic)
            }
        }
        // Dev copy only: the window's own buttons as a check presses them, so a check can arrange the window (split,
        // panes, tabs, browser tabs) without clicking in it or bringing it forward. {"action": …, "id": …, "value": …,
        // "out": "<dev-out>/answer.json"}. action: a window_buttons action (the tool's own path); "click-tab" (the strip's
        // click), "open-in-split" (the tab menu's Open in Split View), "close-tab" (its ✕), "pane" (id: pane.split,
        // pane.focusLeft…, as ⌘D and ⌘⌥← do), or "browser" (a new browser tab on the address in value). The answer
        // carries the panes and the strip.
        DistributedNotificationCenter.default().addObserver(forName: Notification.Name("TerminalDeckDevWindow"),
                                                            object: nil, queue: .main) { note in
            guard let ask = DevReload.request(note.object as? String), let action = ask["action"] as? String,
                  let out = DevReload.output(ask["out"]) else { return }
            let id = ask["id"] as? String ?? "", value = ask["value"] as? String ?? ""
            Task { @MainActor in
                let model = AppModel.shared
                var answer: [String: Any] = ["ok": true]
                switch action {
                case "browser":
                    answer["tab"] = NativeBrowserTabs.shared.create(url: URL(string: value)).id
                case "click-tab": model.selectTab(id)
                case "close-tab": model.closeTab(id)
                case "open-in-split":
                    if let tab = model.stripTabs?.tabs.first(where: { $0.id == id }) { model.openTabInSplit(tab) } else { answer = ["ok": false, "error": "no such tab"] }
                case "pane": answer["ok"] = model.runPaneCommand(id)
                default:
                    do {
                        let outcome = await model.runButtonForTool(try NativeButtonActions.command(action, id: id, value: value)).value
                        answer = ["ok": outcome.succeeded, "message": outcome.succeeded ? "" : outcome.message]
                    } catch { answer = ["ok": false, "error": error.localizedDescription] }
                }
                try? await Task.sleep(for: .milliseconds(300)) // the queued button and the window settle
                answer["window"] = model.buttonActions.paneSummary()
                answer["tabs"] = (model.stripTabs?.tabs ?? []).map { ["id": $0.id, "title": $0.title, "kind": $0.kind, "active": $0.active] }
                answer["screen"] = model.currentScreen.map { $0.kind + "/" + $0.id } ?? ""
                let data = (try? JSONSerialization.data(withJSONObject: answer, options: [.sortedKeys])) ?? Data(#"{"ok":false}"#.utf8)
                try? data.write(to: out, options: .atomic)
            }
        }
        // Dev copy only: measure the records fence N times ({"text": "N"}) to catch a miss with its details in the log.
        DistributedNotificationCenter.default().addObserver(forName: Notification.Name("TerminalDeckDevFenceProbe"),
                                                            object: nil, queue: .main) { note in
            guard let ask = DevReload.request(note.object as? String) else { return }
            let count = Int(ask["text"] as? String ?? "") ?? 50
            Task { NSLog("[devloop] fence probe x%d: %@", count, await DevReload.fenceProbe?(count) ?? "not wired yet") }
        }
        // {"text": "bg:…,bg:…"}.
        DistributedNotificationCenter.default().addObserver(forName: Notification.Name("TerminalDeckDevHootTidy"),
                                                            object: nil, queue: .main) { note in
            guard let ask = DevReload.request(note.object as? String) else { return }
            DevReload.hootTidyTurns = (ask["text"] as? String ?? "").components(separatedBy: ",").filter { $0.hasPrefix("bg:") }
            Task { NSLog("[devloop] Hoot chat tidy: %@", await DevReload.hootTidy?() ?? "Hoot is not wired yet") }
        }
        // Dev copy only: open or close one of Hoot's "where we are" topics through the real memory store
        // ({"text": "open|Title|Text"} or {"text": "close|Title"}). Used to prove a clean desk still carries the open topics.
        DistributedNotificationCenter.default().addObserver(forName: Notification.Name("TerminalDeckDevHootTopic"),
                                                            object: nil, queue: .main) { note in
            guard let parts = (DevReload.request(note.object as? String)?["text"] as? String)?.components(separatedBy: "|"), parts.count >= 2 else { return }
            Task {
                do {
                    if parts[0] == "open", parts.count >= 3 {
                        let topic = try await DeckMemory.store.updateTopic(.hoot, title: parts[1], body: parts[2...].joined(separator: "|"), stamp: nil)
                        NSLog("[devloop] Hoot topic saved: %@", topic.id)
                    } else if parts[0] == "close" {
                        let topic = try await DeckMemory.store.setTopic(.hoot, id: DeckMemoryOwner.slug(parts[1]), open: false)
                        NSLog("[devloop] Hoot topic closed: %@", topic.id)
                    }
                } catch { NSLog("[devloop] Hoot topic failed: %@", error.localizedDescription) }
            }
        }
        // The dev copy keeps Hoot's menu-bar island off, so only the real app shows one.
        if info["TDDevHideIsland"] as? Bool == true {
            for delay in [1.0, 4.0, 10.0] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                    if IslandController.shared.isShown { IslandController.shared.setShown(false) }
                }
            }
        }
    }

    private static func snapshot(to url: URL) {
        let windows = NSApp.windows.filter { $0.isVisible && $0.contentView != nil && $0.frame.width > 300 }
        guard let view = (windows.first { $0.identifier?.rawValue == "main" } ?? windows.first)?.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        // In the window's own appearance, so dynamic colours (a terminal's paper) come out as they show.
        view.effectiveAppearance.performAsCurrentDrawingAppearance { view.cacheDisplay(in: view.bounds, to: rep) }
        layerPicture(view, to: url.deletingPathExtension().appendingPathExtension("layers.png"))
        // A web page draws in WebKit's own process, so the picture above leaves it blank: each page on show is laid
        // over its place from its own snapshot, and where every page sits is written beside the picture (…-pages.json).
        let all = webViews(in: view)
        let pages = all.filter { $0.window != nil && !$0.isHiddenOrHasHiddenAncestor && $0.alphaValue > 0.01 && $0.visibleRect.width > 1 }
        let census: [[String: Any]] = all.map { page in
            let frame = page.convert(page.bounds, to: view)
            return ["url": page.url?.absoluteString ?? "", "inWindow": page.window != nil, "hidden": page.isHiddenOrHasHiddenAncestor,
                    "alpha": page.alphaValue, "frame": [frame.minX, frame.minY, frame.width, frame.height],
                    "visible": [page.visibleRect.width, page.visibleRect.height]]
        }
        let terminals: [[String: Any]] = terminalContainers(in: view).map { box in
            let frame = box.convert(box.bounds, to: view)
            func colour(_ value: CGColor?) -> String { value.flatMap { NSColor(cgColor: $0)?.usingColorSpace(.sRGB) }.map { String(format: "#%02x%02x%02x a%.2f", Int($0.redComponent * 255), Int($0.greenComponent * 255), Int($0.blueComponent * 255), $0.alphaComponent) } ?? "none" }
            return ["terminal": true, "inWindow": box.window != nil, "hidden": box.isHiddenOrHasHiddenAncestor,
                    "frame": [frame.minX, frame.minY, frame.width, frame.height], "superview": String(describing: type(of: box.superview as Any)),
                    "boxLayer": colour(box.layer?.backgroundColor), "termLayer": colour(box.terminal.layer?.backgroundColor),
                    "termNative": colour(box.terminal.nativeBackgroundColor.cgColor), "termHidden": box.terminal.isHidden,
                    "termAlpha": box.terminal.alphaValue, "appearance": box.effectiveAppearance.name.rawValue,
                    "termFrame": [box.terminal.frame.minX, box.terminal.frame.minY, box.terminal.frame.width, box.terminal.frame.height]]
        }
        let slots: [[String: Any]] = slotViews(in: view).map { slot in
            let frame = slot.convert(slot.bounds, to: view)
            return ["slot": true, "inWindow": slot.window != nil, "frame": [frame.minX, frame.minY, frame.width, frame.height],
                    "holds": slot.container?.superview === slot, "container": slot.container != nil,
                    "containerWindow": slot.container?.window != nil]
        }
        try? JSONSerialization.data(withJSONObject: census + terminals + slots, options: [.prettyPrinted]).write(to: url.deletingPathExtension().appendingPathExtension("census.json"), options: .atomic)
        Task { @MainActor in
            let size = view.bounds.size
            let picture = NSImage(size: size)
            picture.addRepresentation(rep)
            var notes: [[String: Any]] = []
            let composed = NSImage(size: size)
            composed.lockFocus()
            picture.draw(in: NSRect(origin: .zero, size: size))
            for page in pages {
                let frame = page.convert(page.bounds, to: view)
                let shot = await withCheckedContinuation { (done: CheckedContinuation<NSImage?, Never>) in
                    page.takeSnapshot(with: nil) { image, _ in done.resume(returning: image) }
                }
                let flipped = view.isFlipped ? NSRect(x: frame.minX, y: size.height - frame.maxY, width: frame.width, height: frame.height) : frame
                shot?.draw(in: flipped)
                notes.append(["url": page.url?.absoluteString ?? "", "frame": [frame.minX, frame.minY, frame.width, frame.height],
                              "visible": [page.visibleRect.width, page.visibleRect.height], "superview": String(describing: type(of: page.superview as Any))])
            }
            composed.unlockFocus()
            if let tiff = composed.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
               let png = bitmap.representation(using: .png, properties: [:]) {
                let side = url.deletingPathExtension().appendingPathExtension("pages.json")
                try? JSONSerialization.data(withJSONObject: notes, options: [.prettyPrinted]).write(to: side, options: .atomic)
                try? png.write(to: url, options: .atomic)
            }
        }
    }

    /// The same window drawn from its layers (what Core Animation holds), beside the picture: layer-drawn parts the
    /// picture above can leave out (a terminal's paper, a list's rows) come out here as they are on screen.
    private static func layerPicture(_ view: NSView, to url: URL) {
        guard let layer = view.layer, let space = CGColorSpace(name: CGColorSpace.sRGB) else { return }
        let scale = view.window?.backingScaleFactor ?? 2, size = view.bounds.size
        guard let context = CGContext(data: nil, width: Int(size.width * scale), height: Int(size.height * scale), bitsPerComponent: 8,
                                      bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        context.scaleBy(x: scale, y: scale)
        if layer.isGeometryFlipped { context.translateBy(x: 0, y: size.height); context.scaleBy(x: 1, y: -1) }
        view.effectiveAppearance.performAsCurrentDrawingAppearance { layer.render(in: context) }
        guard let image = context.makeImage() else { return }
        let bitmap = NSBitmapImageRep(cgImage: image)
        try? bitmap.representation(using: .png, properties: [:])?.write(to: url, options: .atomic)
    }

    private static func slotViews(in view: NSView) -> [DeckTerminalSlot] {
        if let slot = view as? DeckTerminalSlot { return [slot] }
        return view.subviews.flatMap { slotViews(in: $0) }
    }

    private static func terminalContainers(in view: NSView) -> [DeckTerminalContainer] {
        if let box = view as? DeckTerminalContainer { return [box] }
        return view.subviews.flatMap { terminalContainers(in: $0) }
    }

    private static func webViews(in view: NSView) -> [WKWebView] {
        if let web = view as? WKWebView { return [web] }
        return view.subviews.flatMap { webViews(in: $0) }
    }
}

private struct DevReloadRoot: ViewModifier {
    @ObservedObject private var reload = DevReload.shared
    func body(content: Content) -> some View {
        content.id(reload.generation)
    }
}
#endif
