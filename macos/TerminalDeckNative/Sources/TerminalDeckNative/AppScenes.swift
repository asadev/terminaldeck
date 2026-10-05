import SwiftUI
import TerminalDeckNativeCore

/// Every window the app has. Kept apart from the `@main` App so the offscreen
/// window check (`macos/checks/`) runs exactly these scenes.
struct TerminalDeckScenes: Scene {
    let model: AppModel

    var body: some Scene {
        // The one main window (a `Window`, so it is never duplicated and the
        // Window menu can bring it back if it is closed while others stay open).
        Window("Terminal Deck", id: "main") {
            ContentView(model: model)
        }
        .defaultSize(width: 1280, height: 820)
        // Slim header, like the Electron app: title on the toolbar's own line.
        .windowToolbarStyle(.unifiedCompact)
        .commands {
            SidebarCommands() // View ▸ Show/Hide Sidebar (⌃⌘S), the system's own
            AppCommands(model: model) // lane I: the Electron app's menu commands (AppCommands.swift)
            // One window, one engine: File ▸ New Window becomes New Session.
            CommandGroup(replacing: .newItem) {
                Button("New Session") { model.newSession() }
                    .keyboardShortcut("t")
                Button("Open Project…") { model.openProject() }
                    .keyboardShortcut("o")
            }
            // ⌘, asks the page, which answers with `open-settings` and the URL to show.
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") { model.requestSettings() }
                    .keyboardShortcut(",")
            }
        }

        // Exactly one Settings window; opened (or brought forward) only on the page's say-so.
        Window("Settings", id: SettingsWindow.sceneID) {
            SettingsWindow(model: model)
        }
        .defaultSize(width: 900, height: 620)
        .windowToolbarStyle(.unifiedCompact)
        .commandsRemoved()
        .restorationBehavior(.disabled)

        // Any panel or session in its own window: one window per screen (opening
        // the same screen again focuses it). Reopened on launch by AppModel, which
        // remembers them itself, so the system's restoration is off here.
        WindowGroup(for: ScreenRef.self) { $ref in
            ScreenWindow(ref: ref, model: model)
        }
        .defaultSize(width: 960, height: 680)
        .windowToolbarStyle(.unifiedCompact)
        .commandsRemoved()
        .restorationBehavior(.disabled)
    }
}
