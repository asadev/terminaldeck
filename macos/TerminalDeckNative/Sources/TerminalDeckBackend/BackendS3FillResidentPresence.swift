import AppKit
import Foundation

/// Source resident.ts (`residentMenuItems`, `ResidentPresence`). The same behaviour as
/// BackendOSResidentPresence with the status item behind a factory, so "one icon for the app,
/// never zero while in the background, never two" can be asserted without a real NSStatusItem.
/// O2 edit (NIGHT-REQUESTS): replace the old class with
/// `public typealias BackendOSResidentPresence = BackendS3FillResidentPresence`.
public enum BackendS3FillResidentMenu {
    public enum Row: Equatable, Sendable {
        case heading(String), separator, open(String), session(title: String, id: String), quitAll(String)
        public var label: String {
            switch self {
            case .heading(let text), .open(let text), .quitAll(let text): return text
            case .separator: return "(separator)"
            case .session(let title, _): return title
            }
        }
    }
    public struct Session: Sendable {
        public let id: String, provider: String, cwd: String, exitCode: Int?
        public init(id: String, provider: String, cwd: String, exitCode: Int? = nil) {
            self.id = id; self.provider = provider; self.cwd = cwd; self.exitCode = exitCode
        }
    }
    /// `residentMenuItems`: the sessions' count, Open, one row per live session, Quit and Stop All.
    public static func rows(sessions: [Session]) -> [Row] {
        let live = sessions.filter { $0.exitCode == nil }
        var rows: [Row] = [.heading(live.count == 1 ? "Terminal Deck — 1 session running" : "Terminal Deck — \(live.count) sessions running"),
                           .separator, .open("Open Terminal Deck")]
        if !live.isEmpty {
            rows.append(.separator)
            for session in live {
                let agent = ["claude": "Claude Code", "codex": "Codex CLI", "gemini": "Gemini CLI"][session.provider] ?? session.provider
                rows.append(.session(title: "\(agent) — \(URL(fileURLWithPath: session.cwd).lastPathComponent)", id: session.id))
            }
        }
        rows += [.separator, .quitAll("Quit and Stop All Sessions")]
        return rows
    }
}

@MainActor public protocol BackendS3FillStatusItemHandle: AnyObject {
    func update(toolTip: String, rows: [BackendS3FillResidentMenu.Row])
    func remove()
}
@MainActor public protocol BackendS3FillStatusItemFactory {
    func make(open: @escaping @MainActor () -> Void, stop: @escaping @MainActor (String) -> Void,
              quitAll: @escaping @MainActor () -> Void) -> any BackendS3FillStatusItemHandle
}

@MainActor
public final class BackendS3FillResidentPresence {
    public typealias Session = BackendS3FillResidentMenu.Session
    private let sessions: @MainActor () -> [Session]
    private let open: @MainActor () -> Void, stop: @MainActor (String) -> Void, quitAll: @MainActor () -> Void
    private let represented: @MainActor () -> Bool
    private let factory: any BackendS3FillStatusItemFactory
    private var handle: (any BackendS3FillStatusItemHandle)?
    private var wanted = false
    public init(sessions: @escaping @MainActor () -> [Session], open: @escaping @MainActor () -> Void,
                stop: @escaping @MainActor (String) -> Void, quitAll: @escaping @MainActor () -> Void,
                represented: @escaping @MainActor () -> Bool = { false },
                factory: any BackendS3FillStatusItemFactory = BackendS3FillAppKitStatusItems()) {
        self.sessions = sessions; self.open = open; self.stop = stop; self.quitAll = quitAll
        self.represented = represented; self.factory = factory
    }
    /// True while the app is resident: either Hoot's owl stands for it, or its own icon is up.
    public var visible: Bool { wanted && (represented() || handle != nil) }
    public func show() { wanted = true; refresh() }
    public func hide() { wanted = false; drop() }
    public func refresh() {
        if !wanted || represented() { drop(); return }
        let live = sessions().filter { $0.exitCode == nil }
        let handle = self.handle ?? factory.make(open: open, stop: stop, quitAll: quitAll)
        self.handle = handle
        handle.update(toolTip: live.count == 1 ? "Terminal Deck — 1 session running" : "Terminal Deck — \(live.count) sessions running",
                      rows: BackendS3FillResidentMenu.rows(sessions: sessions()))
    }
    private func drop() { handle?.remove(); handle = nil }
}

@MainActor
public struct BackendS3FillAppKitStatusItems: BackendS3FillStatusItemFactory {
    public init() {}
    public func make(open: @escaping @MainActor () -> Void, stop: @escaping @MainActor (String) -> Void,
                     quitAll: @escaping @MainActor () -> Void) -> any BackendS3FillStatusItemHandle {
        BackendS3FillAppKitHandle(open: open, stop: stop, quitAll: quitAll)
    }
}

@MainActor
private final class BackendS3FillAppKitHandle: NSObject, BackendS3FillStatusItemHandle {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let open: @MainActor () -> Void, stop: @MainActor (String) -> Void, quitAll: @MainActor () -> Void
    init(open: @escaping @MainActor () -> Void, stop: @escaping @MainActor (String) -> Void, quitAll: @escaping @MainActor () -> Void) {
        self.open = open; self.stop = stop; self.quitAll = quitAll
        super.init()
        let icon = NSImage(systemSymbolName: "terminal", accessibilityDescription: "Terminal Deck")
        icon?.isTemplate = true; item.button?.image = icon
    }
    func update(toolTip: String, rows: [BackendS3FillResidentMenu.Row]) {
        item.button?.toolTip = toolTip
        let menu = NSMenu()
        for row in rows {
            switch row {
            case .separator: menu.addItem(.separator())
            case .heading(let text): menu.addItem(NSMenuItem(title: text, action: nil, keyEquivalent: ""))
            case .open(let text): add(menu, text, #selector(openApp))
            case .quitAll(let text): add(menu, text, #selector(quit))
            case .session(let title, let id):
                let parent = NSMenuItem(title: title, action: nil, keyEquivalent: ""), submenu = NSMenu()
                add(submenu, "Open", #selector(openApp)); add(submenu, "Stop This Session", #selector(stopSession)).representedObject = id
                parent.submenu = submenu; menu.addItem(parent)
            }
        }
        item.menu = menu
    }
    func remove() { NSStatusBar.system.removeStatusItem(item) }
    @discardableResult private func add(_ menu: NSMenu, _ title: String, _ action: Selector) -> NSMenuItem {
        let entry = NSMenuItem(title: title, action: action, keyEquivalent: ""); entry.target = self; menu.addItem(entry); return entry
    }
    @objc private func openApp() { open() }
    @objc private func stopSession(_ sender: NSMenuItem) { if let id = sender.representedObject as? String { stop(id) } }
    @objc private func quit() { quitAll() }
}
