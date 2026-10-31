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
            ContentView(model: model).devReloadable().background(NativeMainWindowLauncher())
        }
        .defaultLaunchBehavior(.presented)
        .defaultSize(width: 1280, height: 820)
        .windowResizability(.contentMinSize)
        // Slim header, like the Electron app: title on the toolbar's own line.
        .windowToolbarStyle(.unifiedCompact)
        .commands {
            SidebarCommands() // View ▸ Show/Hide Sidebar (⌃⌘S), the system's own
            AppCommands(model: model) // lane I: the Electron app's menu commands (AppCommands.swift)
            // One window, one engine: File ▸ New Window becomes New Session.
            CommandGroup(replacing: .newItem) {
                Button("New Session") { model.newSession() }
                    .keyboardShortcut("t")
                Button("New Project…") { model.openProject() }
                    .keyboardShortcut("n", modifiers: [.command, .shift])
                Button("Open Folder…") { model.openFolder() }
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
            SettingsWindow(model: model).devReloadable().background(NativeMainWindowLauncher())
        }
        .defaultSize(width: DeckTokens.Metrics.settingsSize.width, height: DeckTokens.Metrics.settingsSize.height)
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
        .windowToolbarStyle(.unifiedCompact)
        .commandsRemoved()
        .restorationBehavior(.disabled)

        // Exactly one Devices window, same look and size as Settings; opened or focused from the side panel.
        Window("Devices", id: DevicesWindow.sceneID) {
            DevicesWindow(model: model).devReloadable().background(NativeMainWindowLauncher())
        }
        .defaultSize(width: DeckTokens.Metrics.settingsSize.width, height: DeckTokens.Metrics.settingsSize.height)
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
        .windowToolbarStyle(.unifiedCompact)
        .commandsRemoved()
        .restorationBehavior(.disabled)

        // Any panel or session in its own window: one window per screen (opening
        // the same screen again focuses it). Reopened on launch by AppModel, which
        // remembers them itself, so the system's restoration is off here.
        WindowGroup(for: ScreenRef.self) { $ref in
            ScreenWindow(ref: ref, model: model).devReloadable().background(NativeMainWindowLauncher())
        }
        .defaultSize(width: 960, height: 680)
        .windowToolbarStyle(.unifiedCompact)
        .commandsRemoved()
        .restorationBehavior(.disabled)

        WindowGroup("Settings", id: ObjectWindows.sceneID, for: ObjectRef.self) { $ref in
            ObjectWindow(ref: ref).devReloadable().background(NativeMainWindowLauncher())
        }
        .defaultSize(width: DeckTokens.Metrics.objectSize.width, height: DeckTokens.Metrics.objectSize.height)
        .defaultWindowPlacement { content, _ in
            WindowPlacement(size: content.sizeThatFits(.unspecified))
        }
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unifiedCompact)
        .windowResizability(.contentMinSize)
        .commandsRemoved()
        .restorationBehavior(.disabled)
    }
}

/// Every restored scene can reopen the one main scene, even when it was closed.
private struct NativeMainWindowLauncher: View {
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Color.clear.onAppear {
            NativeLaunchWindow.openMain = { openWindow(id: "main") } // front-ok: scene opener; NativeLaunchWindowRule controls invocation
        }
    }
}
