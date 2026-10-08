import Foundation
import AppKit
import TerminalDeckNativeCore

/// title-bar.ts's Mac branch. Windows overlays and CSS colour arithmetic are
/// not applicable to AppKit. Existing AppAppearance/Theme remain the models.
public enum BackendMacAppWindowsTitleBar {
    public static let trafficLightX = 14.0, trafficLightY = 12.0
    public static func resolveAppearance(_ preference: TerminalPreferences.Theme, systemPrefersDark: Bool) -> AppAppearance {
        preference == .system ? (systemPrefersDark ? .dark : .light) : (preference == .dark ? .dark : .light)
    }
    public static var chrome: NativeRPCValue {
        .object([.init("titleBarStyle", .string("hiddenInset")), .init("trafficLightPosition", .object([.init("x", .number(trafficLightX)), .init("y", .number(trafficLightY))]))])
    }
    public static func overlay(dimmed: Bool = false) -> NativeRPCValue { .null }
    public static let usesWindowControlsOverlay = false
    @MainActor public static func apply(to window: NSWindow) {
        window.styleMask.insert(.fullSizeContentView); window.titleVisibility = .hidden; window.titlebarAppearsTransparent = true
        positionTrafficLights(in: window)
    }
    @MainActor public static func positionTrafficLights(in window: NSWindow) {
        guard !window.styleMask.contains(.fullScreen), let close = window.standardWindowButton(.closeButton), let parent = close.superview else { return }
        let origin = close.frame.origin
        for kind in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            guard let button = window.standardWindowButton(kind), button.superview === parent else { continue }
            let dx = button.frame.minX - origin.x
            button.setFrameOrigin(NSPoint(x: trafficLightX + dx, y: parent.isFlipped ? trafficLightY : parent.bounds.height - trafficLightY - button.frame.height))
        }
    }
    @MainActor public static func applyAppearance(_ preference: AppAppearance, to window: NSWindow) {
        switch preference { case .followMac: window.appearance = nil; case .dark: window.appearance = NSAppearance(named: .darkAqua); case .light: window.appearance = NSAppearance(named: .aqua) }
    }
}

@MainActor public protocol BackendMacAppWindowsMenuHost: AnyObject {
    func install(_ menu: NSMenu) throws
    func setAbout(name: String, version: String)
    func sendMain(command: String) async throws -> Bool
    func openExternal(_ url: URL) async throws
    func performRole(_ role: String) async throws
    func failed(_ error: Error)
}

/// Source menu behavior, using existing AppMenuCommand/AppCommandCatalog for
/// every previously catalogued command. Native system roles keep responder
/// dispatch, Edit/Window contents, Services and the app's normal quit teardown.
@MainActor public final class BackendMacAppWindowsMenu: NSObject {
    public static let hiddenCommandsChannel = "menu:hidden-commands", commandChannel = "menu:command"
    public static let gated: Set<String> = ["view.browser", "pane.split", "view.swarm"]
    private let host: any BackendMacAppWindowsMenuHost
    private let route: @MainActor (String) throws -> Bool
    private let version: String
    private var hidden: Set<String> = []
    private var subscription: NativeRPCSubscription?
    public init(host: any BackendMacAppWindowsMenuHost, version: String, route: @escaping @MainActor (String) throws -> Bool = { _ in false }) {
        self.host = host; self.version = version; self.route = route; super.init()
    }
    public static let hidesMenuBar = false
    public static func commandsFrom(_ value: NativeRPCValue) -> Set<String> { Set((value.elements ?? []).compactMap(\.string).filter { !$0.isEmpty }) }
    public func build() throws { try host.install(template()); host.setAbout(name: "Terminal Deck", version: version) }
    public func updateHidden(_ value: NativeRPCValue) throws {
        let next = Self.commandsFrom(value); if next == hidden { return }; hidden = next; try host.install(template())
    }
    public func register(on registry: NativeChannelRegistry, ownerID: String = "native-application-menu",
                         policy: @escaping NativeChannelRegistry.Policy = BackendOSNativeCaller.only) async throws {
        await subscription?.cancelAndWait(); subscription = nil
        try build()
        subscription = try await registry.onSend(Self.hiddenCommandsChannel, ownerID: ownerID, policy: policy) { [weak self] _, arguments in
            guard let self else { throw NativeRPCError(code: "unavailable", message: "The native application menu is unavailable.") }
            try await self.updateHidden(arguments.first ?? .missing)
        }
    }
    public func stop() async { await subscription?.cancelAndWait(); subscription = nil }
    @discardableResult public func dispatch(_ command: String) async throws -> Bool {
        guard UIGMemoryVisibility.showsCommand(command) else {
            throw NativeRPCError(code: "unavailable", message: UIGMemoryVisibility.unavailableTitle)
        }
        if try route(command) { return true }
        return try await host.sendMain(command: command)
    }
    @objc private func chosen(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? String else { return }
        Task { @MainActor in
            do {
                if value.hasPrefix("role:") { try await host.performRole(String(value.dropFirst(5))) }
                else if value.hasPrefix("url:"), let url = URL(string: String(value.dropFirst(4))) { try await host.openExternal(url) }
                else { _ = try await dispatch(value) }
            } catch { host.failed(error) }
        }
    }
    private func known(_ id: String) -> AppMenuCommand {
        if case .page(let wanted) = AppCommandCatalog.about.action, wanted == id { return AppCommandCatalog.about }
        if let found = AppCommandCatalog.all.first(where: { if case .page(let wanted) = $0.action { wanted == id } else { false } }) { return found }
        // Source commands already installed by AppScenes' system groups.
        switch id {
        case "project.open": return .init(.file, "Open Project…", key: "o", .page(id))
        case "session.new": return .init(.file, "New Session", key: "t", .page(id))
        case "app.preferences": return .init(.app, "Settings…", key: ",", .page(id))
        case "session.popOut": return .init(.file, "Move Session to New Window", .page(id))
        case "session.dock": return .init(.file, "Move Session Back to Main Window", .page(id))
        default: return .init(.view, "Toggle Sidebar", key: "b", .page("view.sidebar"))
        }
    }
    private func addCommand(_ menu: NSMenu, _ id: String, keyOverride: String? = nil) {
        guard UIGMemoryVisibility.showsCommand(id) else { return }
        if Self.gated.contains(id) && hidden.contains(id) { return }
        let command = known(id), item = NSMenuItem(title: command.title, action: #selector(chosen(_:)), keyEquivalent: keyOverride ?? command.key ?? "")
        item.keyEquivalentModifierMask = command.shift ? [.command, .shift] : [.command]; item.target = self; item.representedObject = id
        menu.addItem(item)
    }
    private func role(_ menu: NSMenu, _ name: String, title: String, key: String = "", modifiers: NSEvent.ModifierFlags = .command, selector: String? = nil, nativeTarget: AnyObject? = nil) {
        let item = NSMenuItem(title: title, action: selector.map(NSSelectorFromString) ?? #selector(chosen(_:)), keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers; item.representedObject = "role:" + name; item.target = selector == nil ? self : nativeTarget
        menu.addItem(item)
    }
    private func top(_ root: NSMenu, _ title: String, role: String? = nil) -> NSMenu {
        let menu = NSMenu(title: title), item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.representedObject = role; item.submenu = menu; root.addItem(item); return menu
    }
    public func template() -> NSMenu {
        let root = NSMenu(title: "Terminal Deck"), app = top(root, "Terminal Deck")
        addCommand(app, "app.about"); app.addItem(.separator()); addCommand(app, "app.preferences"); addCommand(app, "app.shortcuts"); app.addItem(.separator())
        let services = NSMenuItem(title: "Services", action: nil, keyEquivalent: ""); services.representedObject = "role:services"; services.submenu = NSMenu(title: "Services"); app.addItem(services)
        app.addItem(.separator())
        role(app, "hide", title: "Hide Terminal Deck", key: "h", selector: "hide:", nativeTarget: NSApplication.shared)
        role(app, "hideOthers", title: "Hide Others", key: "h", modifiers: [.command, .option], selector: "hideOtherApplications:", nativeTarget: NSApplication.shared)
        role(app, "unhide", title: "Show All", selector: "unhideAllApplications:", nativeTarget: NSApplication.shared)
        app.addItem(.separator()); role(app, "quit", title: "Quit Terminal Deck", key: "q", selector: "terminate:", nativeTarget: NSApplication.shared)
        let file = top(root, "File")
        addCommand(file, "project.open"); file.addItem(.separator()); addCommand(file, "session.new"); addCommand(file, "session.newDialog"); addCommand(file, "session.close", keyOverride: "w")
        file.addItem(.separator()); addCommand(file, "session.popOut"); addCommand(file, "session.dock")
        let edit = top(root, "Edit", role: "editMenu")
        role(edit, "undo", title: "Undo", key: "z", selector: "undo:"); role(edit, "redo", title: "Redo", key: "z", modifiers: [.command, .shift], selector: "redo:"); edit.addItem(.separator())
        for (name, key) in [("cut", "x"), ("copy", "c"), ("paste", "v"), ("selectAll", "a")] { role(edit, name, title: name == "selectAll" ? "Select All" : name.capitalized, key: key, selector: name + ":") }
        let view = top(root, "View")
        for id in ["view.terminal", "view.overview", "view.browser"] { addCommand(view, id) }; view.addItem(.separator())
        for id in ["view.sidebar", "pane.split", "view.swarm"] { addCommand(view, id) }; view.addItem(.separator())
        for id in ["app.palette", "app.quickOpen", "panel.search", "app.inspector"] { addCommand(view, id) }; view.addItem(.separator())
        role(view, "reload", title: "Reload", key: "r"); role(view, "toggleDevTools", title: "Toggle Developer Tools", key: "i", modifiers: [.command, .option])
        role(view, "resetZoom", title: "Actual Size", key: "0"); role(view, "zoomIn", title: "Zoom In", key: "+"); role(view, "zoomOut", title: "Zoom Out", key: "-")
        role(view, "togglefullscreen", title: "Enter Full Screen", key: "f", modifiers: [.command, .control], selector: "toggleFullScreen:")
        let windows = top(root, "Window", role: "windowMenu")
        role(windows, "minimize", title: "Minimize", key: "m", selector: "performMiniaturize:"); role(windows, "zoom", title: "Zoom", selector: "performZoom:"); windows.addItem(.separator())
        role(windows, "front", title: "Bring All to Front", selector: "arrangeInFront:", nativeTarget: NSApplication.shared)
        let help = top(root, "Help", role: "help")
        addCommand(help, "app.help"); addCommand(help, "app.setup"); help.addItem(.separator())
        let issue = NSMenuItem(title: "Report an Issue", action: #selector(chosen(_:)), keyEquivalent: ""); issue.target = self; issue.representedObject = "url:https://github.com/"; help.addItem(issue)
        return root
    }
}

/// NSApplication's live menu owner. The page/SwiftUI command and WebKit role
/// operations are required callbacks to the existing app owner, never no-ops.
@MainActor public final class BackendMacAppWindowsNativeMenuHost: BackendMacAppWindowsMenuHost {
    private let send: @MainActor (String) async throws -> Bool
    private let roleAction: @MainActor (String) async throws -> Void
    private let failure: @MainActor (Error) -> Void
    public private(set) var aboutName = "", aboutVersion = ""
    public init(sendMain: @escaping @MainActor (String) async throws -> Bool,
                performRole: @escaping @MainActor (String) async throws -> Void, failed: @escaping @MainActor (Error) -> Void) {
        send = sendMain; roleAction = performRole; failure = failed
    }
    public func install(_ menu: NSMenu) throws {
        NSApplication.shared.mainMenu = menu
        NSApplication.shared.windowsMenu = menu.items.first { ($0.representedObject as? String) == "windowMenu" }?.submenu
        NSApplication.shared.helpMenu = menu.items.first { ($0.representedObject as? String) == "help" }?.submenu
        NSApplication.shared.servicesMenu = menu.items.first?.submenu?.items.first { ($0.representedObject as? String) == "role:services" }?.submenu
    }
    public func setAbout(name: String, version: String) { aboutName = name; aboutVersion = version }
    public func sendMain(command: String) async throws -> Bool { try await send(command) }
    public func openExternal(_ url: URL) async throws {
        guard NSWorkspace.shared.open(url) else { throw NativeRPCError(code: "unavailable", message: "The system browser could not open the issue-report page.") }
    }
    public func performRole(_ role: String) async throws { try await roleAction(role) }
    public func failed(_ error: Error) { failure(error) }
}
