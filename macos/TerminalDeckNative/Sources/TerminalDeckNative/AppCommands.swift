import SwiftUI
import WebKit
import TerminalDeckNativeCore

/// The Electron app's menu-bar commands, in the native menu bar (the table is
/// `AppCommandCatalog`). Page commands go to the main page as
/// `tdNative.run('menu-command', '<id>')`; a command the page does not take beeps.
struct AppCommands: Commands {
    let model: AppModel

    var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            item(AppCommandCatalog.about)
        }
        // ⌘Q quits even with a sheet or dialog up, as TS did (NativeQuit).
        CommandGroup(replacing: .appTermination) {
            Button("Quit " + ((Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String) ?? ProcessInfo.processInfo.processName)) { NativeQuit.terminate() }
                .keyboardShortcut("q")
        }
        CommandGroup(after: .appSettings) {
            items(.app)
        }
        CommandGroup(after: .newItem) {
            items(.file)
        }
        CommandGroup(after: .sidebar) {
            items(.view)
        }
        CommandGroup(replacing: .help) {
            items(.help)
        }
    }

    @ViewBuilder
    private func items(_ menu: AppMenuCommand.Menu) -> some View {
        ForEach(AppCommandCatalog.commands(in: menu), id: \.title) { command in
            if command.dividerBefore { Divider() }
            item(command)
        }
    }

    private func item(_ command: AppMenuCommand) -> some View {
        Button(command.title) { AppCommandRunner.perform(command, model: model) }
            .menuShortcut(command)
    }
}

private extension View {
    @ViewBuilder
    func menuShortcut(_ command: AppMenuCommand) -> some View {
        if let key = command.key, let character = key.first {
            keyboardShortcut(KeyEquivalent(character), modifiers: command.shift ? [.command, .shift] : .command)
        } else {
            self
        }
    }
}

@MainActor
enum AppCommandRunner {
    static func perform(_ command: AppMenuCommand, model: AppModel) {
        if case .page(let id) = command.action, !UIGMemoryVisibility.showsCommand(id) { NSSound.beep(); return }
        switch command.action {
        case .page(let id) where id == "view.browser" && BrowserTabsHook.provider != nil:
            // Lane BR: View ▸ Browser is "New browser tab" (App.tsx view.browser). The page's own
            // answer makes a tab the native browser does not hold ("This browser tab is closed").
            model.newBrowserTab()
        case .page:
            guard model.canRun, let script = command.script else { NSSound.beep(); return }
            let log = model.engine.log
            let title = command.title
            model.web.webView.evaluateJavaScript(script) { result, error in
                if let error = error as NSError? {
                    if error.domain == WKErrorDomain, error.code == WKError.Code.javaScriptResultTypeIsUnsupported.rawValue { return }
                    log.note("menu \(title) failed: \(error.localizedDescription)")
                    return
                }
                // `run` answers false for a command the page does not take.
                if let taken = result as? Bool, !taken { NSSound.beep() }
            }
        case .zoom(let direction):
            guard let webView = frontWebView(model: model) else { NSSound.beep(); return }
            webView.pageZoom = AppCommandCatalog.zoom(from: Double(webView.pageZoom), direction: direction)
        case .openURL(let address):
            if let url = URL(string: address) { NSWorkspace.shared.open(url) }
        }
    }

    /// The web view in the window in front: the one with the keyboard, else the first
    /// one in that window, else the main page.
    private static func frontWebView(model: AppModel) -> WKWebView? {
        if let window = NSApp.keyWindow {
            var view = window.firstResponder as? NSView
            while let current = view {
                if let webView = current as? WKWebView { return webView }
                view = current.superview
            }
            if let content = window.contentView, let found = firstWebView(in: content) { return found }
        }
        return model.web.webView
    }

    private static func firstWebView(in view: NSView) -> WKWebView? {
        if let webView = view as? WKWebView { return webView }
        for child in view.subviews {
            if let found = firstWebView(in: child) { return found }
        }
        return nil
    }
}
