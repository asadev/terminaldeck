import AppKit
import TerminalDeckBackend

@MainActor
public struct NativeResidentStatusItems: BackendS3FillStatusItemFactory {
    public init() {}
    public func make(open: @escaping @MainActor () -> Void, stop: @escaping @MainActor (String) -> Void,
                     quitAll: @escaping @MainActor () -> Void) -> any BackendS3FillStatusItemHandle {
        NativeResidentStatusItem(open: open, stop: stop, quitAll: quitAll)
    }
}

@MainActor
private final class NativeResidentStatusItem: NSObject, BackendS3FillStatusItemHandle {
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
