import SwiftUI

/// Which screens are drawn in Swift instead of by the page.
///
/// The main window and the Settings window show the page by default. A screen
/// that has a native version answers here, and the window shows it instead —
/// keeping the page alive underneath, so switching back loses nothing. A screen
/// with no line here simply stays the page, so a half-built native screen is
/// never shown: its lane adds its line when it works.
///
/// Each native screen lives in its own file and talks to the engine through
/// `EngineBridge`. Add one `case` per screen; keep the cases in this order.
enum NativeScreens {
    /// The main window's detail for the selected item: `kind` and `id` as the
    /// page sends them in its `sidebar` / `tabs` state (`'session'`, `'panel'`,
    /// `'hoot'`, `'browser'`). Nil keeps the page.
    /// What the page stops mounting underneath, as it names them — told after every
    /// page `ready` (`tdNative.run('native-screens', registered)`). One entry per case
    /// below, in the same order: add the id here when you add the case.
    static let registered: [String] = [
        "session",     // ("session", local id): NativeTerminalScreen — the page draws remote sessions elsewhere
        "browser",     // ("browser", tab id): NativeBrowserScreen
        "simulators",  // ("panel", "simulators"): NativeSimulatorScreen
        "artifacts",   // ("panel", "artifacts"): NativeArtifactsScreen
    ]

    @MainActor
    static func detail(kind: String, id: String) -> AnyView? {
        switch (kind, id) {
        case ("session", let sessionId) where NativeTerminalScreen.handles(sessionId): return AnyView(NativeTerminalScreen(sessionId: sessionId))
        case ("browser", let tabId): return AnyView(NativeBrowserScreen(tabId: tabId))
        case ("panel", "simulators"): return AnyView(NativeSimulatorScreen())
        case ("panel", "artifacts"): return AnyView(NativeArtifactsScreen())
        default:
            return nil
        }
    }

    /// The Settings window's detail for a section id, as the page sends it in
    /// `settings-sections`. Nil keeps the page.
    @MainActor
    static func settings(sectionId: String) -> AnyView? {
        switch sectionId {
        case "agents": return AnyView(NativeCodingAISettings())
        default:
            return nil
        }
    }
}
