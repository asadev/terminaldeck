import Foundation
import AppKit
import TerminalDeckNativeCore

@MainActor public protocol BackendAppSessionRowBrowserMenu: AnyObject {
    func bindingMenu(sessionID: String, machineID: String) throws -> NSMenu
}

public enum BackendAppSessionRowMenu {
    public struct Item: Sendable, Equatable {
        public let label: String, choice: String?, enabled: Bool, detail: String?, browserSubmenu: Bool
        init(_ label: String, _ choice: String? = nil, enabled: Bool = true, detail: String? = nil, browser: Bool = false) {
            self.label = label; self.choice = choice; self.enabled = enabled; self.detail = detail; browserSubmenu = browser
        }
    }
    public static func items(_ input: NativeRPCValue) -> [Item] {
        let promoted = input["promoted"].bool == true, blocked = input["promoteBlocked"].string.flatMap { $0.isEmpty ? nil : $0 }
        var items = [Item(promoted ? "Fold back into the sidebar" : "Show at the top", "promote", enabled: promoted || blocked == nil, detail: promoted ? nil : blocked)]
        if input["window"].string == "main" { items.append(Item("Move to New Window", "popout")) }
        if input["window"].string == "own" { items += [Item("Show Its Window", "show-window"), Item("Move Back to Main Window", "dock")] }
        if input["copilotTurn"].bool == true { items.append(Item("Started by \(BackendSharedBrand.assistant) — open that turn", "copilot")) }
        if input["browser"].bool != true { items += [Item(""), Item("Connect browser", browser: true)] }
        if input["close"].bool == true { items += [Item(""), Item("Delete", "close")] }
        return items
    }
    @MainActor fileprivate final class Selection: NSObject {
        var value: String?
        @objc func select(_ sender: NSMenuItem) { value = sender.representedObject as? String }
    }
    /// The actual NSMenu and action target are reusable without a window or a
    /// popup. Tests dispatch the same NSMenuItem action that show() uses.
    @MainActor public final class Popup {
        public let menu: NSMenu
        private let target: Selection
        fileprivate init(menu: NSMenu, target: Selection) { self.menu = menu; self.target = target }
        public var value: NativeRPCValue { target.value.map(NativeRPCValue.string) ?? .null }
    }
    @MainActor public static func buildMenu(_ raw: NativeRPCValue, browser: (any BackendAppSessionRowBrowserMenu)?) throws -> Popup? {
        guard let id = raw["sessionId"].string, !id.isEmpty else { return nil }
        let target = Selection(), menu = NSMenu(); menu.autoenablesItems = false
        for spec in items(raw) {
            if spec.label.isEmpty { menu.addItem(.separator()); continue }
            let item = NSMenuItem(title: spec.label, action: spec.choice == nil ? nil : #selector(Selection.select(_:)), keyEquivalent: "")
            item.target = target; item.representedObject = spec.choice; item.isEnabled = spec.enabled; item.toolTip = spec.detail
            if spec.browserSubmenu {
                guard let browser else { throw NativeRPCError(code: "unavailable", message: "The Safari binding menu is unavailable until its app-owned service is connected") }
                item.submenu = try browser.bindingMenu(sessionID: id, machineID: raw["machineId"].string ?? "")
            }
            menu.addItem(item)
            if let detail = spec.detail {
                // AppKit has no Electron sublabel; keep the reason visible at
                // the blocked action rather than relying on a hover tooltip.
                let explanation = NSMenuItem(title: detail, action: nil, keyEquivalent: "")
                explanation.isEnabled = false; menu.addItem(explanation)
            }
        }
        return Popup(menu: menu, target: target)
    }
    @MainActor public static func show(_ raw: NativeRPCValue, window: NSWindow?, browser: (any BackendAppSessionRowBrowserMenu)?) throws -> NativeRPCValue {
        guard let window, let view = window.contentView, let popup = try buildMenu(raw, browser: browser) else { return .null }
        let location = window.convertPoint(fromScreen: NSEvent.mouseLocation)
        _ = popup.menu.popUp(positioning: nil, at: view.convert(location, from: nil), in: view)
        return popup.value
    }
    public static func register(registry: NativeChannelRegistry, ownerID: String,
                                present: @escaping @MainActor @Sendable (NativeRPCValue) throws -> NativeRPCValue) async throws -> [String] {
        try await registry.register("session:row-menu", ownerID: ownerID) { context, args in
            guard context.caller == .nativeApp else { throw NativeRPCError(code: "access-denied", message: "Only the app's own window may open the session menu") }
            return try await present(context.argument(0, in: args))
        }
        return ["session:row-menu"]
    }
}

public enum BackendAppProjectPicker {
    public static func startDirectory(projects: [String], home: String, exists: (String) -> Bool = directoryExists) -> String {
        for path in projects where !path.isEmpty {
            // Node dirname of a bare name is '.', rather than Foundation's cwd.
            guard path.contains("/") else { continue }
            var trimmed = path
            while trimmed.count > 1 && trimmed.hasSuffix("/") { trimmed.removeLast() }
            let parent = (trimmed as NSString).deletingLastPathComponent
            if !parent.isEmpty && parent != "." && exists(parent) { return parent }
        }
        return home
    }
    public static func directoryExists(_ path: String) -> Bool {
        var directory: ObjCBool = false; return FileManager.default.fileExists(atPath: path, isDirectory: &directory) && directory.boolValue
    }
}
