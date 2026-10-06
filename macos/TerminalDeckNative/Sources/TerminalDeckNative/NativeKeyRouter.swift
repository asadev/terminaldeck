import AppKit
@preconcurrency import SwiftTerm
import TerminalDeckNativeCore
import WebKit

/// The app's keyboard shortcuts (keymap.ts) while a native view has the keyboard.
/// The page listens on its own window, so it hears nothing once a native screen,
/// a native terminal or a native field has focus. This hears those keys in the
/// main window, reads them with the same table and rules (Core `Keymap.resolve`),
/// and hands the command to the page to run — the page still decides what it does.
/// ⌘1–9 picks a tab, as the page does. Keys the web page has focus for, keys a
/// menu item owns, and keys while a sheet or native dialog is up go by untouched;
/// in a native terminal only the chords that steal from a terminal are taken, and
/// its own chords (find, clear, copy) stay the terminal's.
@MainActor
enum NativeKeyRouter {
    private static var monitor: Any?

    static func install(_ model: AppModel) {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let used = MainActor.assumeIsolated { route(event, model: model) }
            return used ? nil : event
        }
    }

    private static func route(_ event: NSEvent, model: AppModel) -> Bool {
        let page = model.web.webView
        guard model.canRun, let window = event.window, window === page.window, window.isKeyWindow,
              window.attachedSheet == nil, model.dialogs.isEmpty else { return false }
        let responder = window.firstResponder
        if let view = responder as? NSView, view === page || view.isDescendant(of: page) { return false }

        let flags = event.modifierFlags
        let press = KeyStroke(key: Keymap.token(keyCode: event.keyCode, characters: event.charactersIgnoringModifiers),
                             meta: flags.contains(.command), ctrl: flags.contains(.control),
                             alt: flags.contains(.option), shift: flags.contains(.shift))
        if menuClaims(event) { return false }

        if let digit = Keymap.tabDigit(press) {
            guard let tabs = model.stripTabs?.tabs, digit <= tabs.count else { return false }
            model.selectTab(tabs[digit - 1].id)
            return true
        }

        let scope: KeyScope = inTerminal(responder) ? .terminal : .global
        guard let binding = Keymap.resolve(press, scope: scope), binding.scope == .global,
              binding.id != "session.jump" else { return false }
        run(binding.id, on: page)
        return true
    }

    private static func run(_ id: String, on page: WKWebView) {
        let argument = (try? JSONSerialization.data(withJSONObject: [id])).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        page.evaluateJavaScript("window.tdNative && window.tdNative.run('\(AppCommandCatalog.pageCommand)', ...\(argument))") { result, _ in
            if let taken = result as? Bool, !taken { NSSound.beep() }
        }
    }

    private static func inTerminal(_ responder: NSResponder?) -> Bool {
        var view = responder as? NSView
        while let current = view {
            if current is TerminalView { return true }
            view = current.superview
        }
        return false
    }

    /// A menu item with this key equivalent runs it itself (⌘T, ⌘O, ⌘, …).
    private static func menuClaims(_ event: NSEvent) -> Bool {
        guard let menu = NSApp.mainMenu, let typed = event.charactersIgnoringModifiers?.lowercased(), !typed.isEmpty else { return false }
        let wanted = event.modifierFlags.intersection([.command, .shift, .option, .control])
        return claims(menu, typed: typed, flags: wanted)
    }

    private static func claims(_ menu: NSMenu, typed: String, flags: NSEvent.ModifierFlags) -> Bool {
        for item in menu.items {
            if let submenu = item.submenu, claims(submenu, typed: typed, flags: flags) { return true }
            guard !item.keyEquivalent.isEmpty, item.isEnabled else { continue }
            var mask = item.keyEquivalentModifierMask.intersection([.command, .shift, .option, .control])
            var key = item.keyEquivalent
            if key != key.lowercased() { mask.insert(.shift); key = key.lowercased() }
            if key == typed && mask == flags { return true }
        }
        return false
    }
}
