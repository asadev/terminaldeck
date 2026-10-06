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
        "session",     // ("session", local id): NativeTerminalScreen — lane T
        "machine-session", // ("session", "machine <id> <session>"): NativeTerminalScreen — lane T (page stops mounting MachineSessionPane)
        "server-session",  // ("session", "server <id> <key>"): NativeTerminalScreen — lane T (page stops mounting ServerSessionPane)
        "settings:power",  // settings "power": NativePowerSettings — lane T
        "split",           // lane T: the split window (NativeLayoutScreen; layout in the tabs state)
        "swarm",           // lane T: every session at once (NativeLayoutScreen)
        "browser",     // ("browser", tab id): NativeBrowserScreen
        "simulators",  // ("panel", "simulators"): NativeSimulatorScreen
        "files",       // ("panel", "files"): NativeFilesScreen — lane V
        "git",         // ("panel", "git"): NativeGitScreen — lane V
        "github",      // ("panel", "github"): NativeGitHubScreen — lane V
        "readiness",   // ("panel", "readiness"): NativeReadinessScreen — lane V
        "hooks",       // ("panel", "hooks"): NativeHooksScreen — lane V
        "artifacts",   // ("panel", "artifacts"): NativeArtifactsScreen
        "staysfixed",  // ("panel", "staysfixed"): NativeStaysFixedScreen
        "memory",      // ("panel", "memory"): NativeMemoryScreen
        "mcp",         // ("panel", "mcp"): NativeMcpScreen — lane E2
        "overview",    // ("panel", "overview"): NativeOverviewScreen
        "store",       // ("panel", "store"): NativeStoreScreen (with B's and E2's departments)
        "drive",       // Hoot driving the app: NativeDriveHost (page stops mounting DriveHost and answering `where`)
        "tasks",       // ("panel", "tasks"): NativeTasksScreen (My Work, Goals, CRM tasks, the task popup) — lane I
        "hoot",        // ("hoot", "hoot" or Hoot's tab id): NativeHootScreen — lane R (page stops mounting CopilotView/CopilotRestart)
        "settings:plugins",  // settings "plugins": NativePluginsSettings — settings sections are `settings:<section id>`
        "settings:ai-apps",  // settings "ai-apps": NativeAiAppsSettings
        "settings:features", // settings "features" (Tools): NativeToolsSettings — lane E2
        "settings:copilot",  // settings "copilot" (Hoot): NativeCopilotSettings — lane E2
        "settings:agents",        // settings "agents" (Coding AI): NativeCodingAISettings — lane G
        "settings:general",       // NativeGeneralSettings — lane G
        "settings:notifications", // NativeNotificationsSettings — lane G
        "settings:linux",         // NativeLinuxSettings — lane G
        "settings:appearance",    // NativeAppearanceSettings — lane G
        "settings:advanced",      // NativeAdvancedSettings — lane G
        "settings:help",          // NativeHelpSettings (About at the top) — lane G
        "settings:browser",       // NativeBrowserSettings — lane B
        "settings:scraping",      // NativeScrapingSettings — lane B
        "settings:tasks",         // NativeTasksSettings (task agents, CRM connections) — lane I
        "close-confirm",     // lane S: CloseSessionConfirm as a sheet (NativeAppDialogs.swift; page side native-dialogs.ts)
        "switch-account",    // lane S: SwitchAccountConfirm as a sheet
        "alerts-sheet",      // lane S: the Alerts window as a sheet (the sidebar row stays "alerts")
        "palette",           // lane S: the command palette (NativeCommandPalette.swift)
        "shortcuts",         // lane S: the keyboard shortcuts sheet (NativeShortcutsSheet.swift)
        "help",              // lane S: the Help sheet (NativeHelpPanel.swift; words lent by native-help.ts)
        "onboarding",        // lane S: the first-run screen over the whole window (NativeOnboarding.swift)
        "session-inspector", // lane T: NativeSessionInspector as a sheet (wired by lane S in NativeAppDialogs)
        "feature-offer",     // lane S: FeatureOffer in place of a native screen whose feature is off (NativeFeatureOffer.swift)
        "new-session",       // lane B: NewSessionDialog as a sheet (NativeNewSessionDialog.swift; page side native-new-session.ts)
        "copilot-setup",     // lane B: CopilotSetup as a sheet (NativeCopilotSetup.swift; page side native-dialogs.ts)
        "copilot-consent",   // lane B: CopilotConsent as a sheet (NativeCopilotConsent.swift; page side native-dialogs.ts)
        "island",            // lane B: the island's grown content (NativeIslandContent.swift in lane I's IslandView; page side App.tsx island-snapshot)
        "remote",            // ("panel", "remote"): NativeMachinesScreen (Machines: G's servers + V's devices) — lane E1
        "join-remote",       // lane E1: JoinRemoteDialog as a sheet (NativeJoinRemoteDialog.swift; page side native-dialogs.ts)
    ]

    @MainActor
    static func detail(kind: String, id: String) -> AnyView? {
        switch (kind, id) {
        case (let kind, let id) where NativeLayoutScreen.wants(kind: kind): return AnyView(NativeLayoutScreen(kind: kind, id: id)) // lane T: split / swarm
        case ("session", let sessionId) where NativeTerminalScreen.handles(sessionId): return AnyView(NativeTerminalScreen(sessionId: sessionId))
        case ("browser", let tabId): return AnyView(NativeBrowserScreen(tabId: tabId))
        case ("panel", "simulators"): return AnyView(NativeSimulatorScreen())
        case ("panel", "files"): return AnyView(NativeFilesScreen())
        case ("panel", "git"): return AnyView(NativeGitScreen())
        case ("panel", "github"): return AnyView(NativeGitHubScreen())
        case ("panel", "readiness"): return AnyView(NativeReadinessScreen())
        case ("panel", "hooks"): return AnyView(NativeHooksScreen())
        case ("panel", "artifacts"): return AnyView(NativeArtifactsScreen())
        case ("panel", "staysfixed"): return AnyView(NativeStaysFixedScreen())
        case ("panel", "memory"): return AnyView(NativeMemoryScreen())
        case ("panel", "mcp"): return AnyView(NativeMcpScreen()) // lane E2
        case ("panel", "overview"): return AnyView(NativeOverviewScreen())
        case ("panel", "store"): return AnyView(NativeStoreScreen())
        case ("panel", "tasks"): return AnyView(NativeTasksScreen()) // lane I
        case ("panel", "remote"): return AnyView(NativeMachinesScreen()) // lane E1
        case ("hoot", _): return AnyView(NativeHootScreen()) // lane R: Hoot's window (CopilotView)
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
        case "power": return AnyView(NativePowerSettings()) // lane T
        case "general": return AnyView(NativeGeneralSettings())
        case "notifications": return AnyView(NativeNotificationsSettings())
        case "linux": return AnyView(NativeLinuxSettings())
        case "appearance": return AnyView(NativeAppearanceSettings())
        case "advanced": return AnyView(NativeAdvancedSettings())
        case "help": return AnyView(NativeHelpSettings())
        case "plugins": return AnyView(NativePluginsSettings())
        case "ai-apps": return AnyView(NativeAiAppsSettings())
        case "features": return AnyView(NativeToolsSettings()) // lane E2
        case "copilot": return AnyView(NativeCopilotSettings()) // lane E2
        case "browser": return AnyView(NativeBrowserSettings()) // lane B
        case "scraping": return AnyView(NativeScrapingSettings()) // lane B
        case "tasks": return AnyView(NativeTasksSettings()) // lane I
        default:
            return nil
        }
    }
}
