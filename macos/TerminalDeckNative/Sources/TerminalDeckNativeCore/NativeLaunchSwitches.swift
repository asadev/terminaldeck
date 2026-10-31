import Foundation

/// Every launch-environment switch the app reads, in one place. Each one is for checks,
/// proofs, renders or the development copy: the installed app needs none of them, and
/// nothing in the app sets one. Read them through these names, never as loose strings.
public enum NativeLaunchSwitches {
    /// A private data folder (an absolute path) for checks and the development copy.
    public static let dataFolder = "TD_NATIVE_DATA_DIR"
    /// "1": offscreen UI-test fixtures, allowed only with a private home and data folder.
    public static let uiTest = "TD_NATIVE_UI_TEST"
    /// "1": scratch quit proofs; SIGUSR1 asks the app to quit the scripted way.
    public static let quitProof = "TD_NATIVE_QUIT_PROOF"
    /// "1": writes the sealed route list beside the data, for coverage checks on scratch data.
    public static let dumpRoutes = "TD_NATIVE_DUMP_ROUTES"
    /// "1": never shows macOS's own permission questions (development copy and renders).
    public static let noSystemPrompts = "TD_NO_SYSTEM_PROMPTS"
    /// "1": sessions run inside the app without the session keeper; the app's notice says so.
    public static let hostDisabled = "TD_HOST_DISABLED"
    /// "1": emergency override that keeps Hoot's ready defaults and setup off.
    public static let hootDisabled = "TD_HOOT_DISABLED"
    /// "1": never writes the coding AIs' own hook settings.
    public static let agentConfigReadOnly = "TD_AGENT_CONFIG_READONLY"
    /// The development copy's per-launch secret for its dev doors (devloop.sh sets it).
    public static let devInvokeToken = "TD_DEV_INVOKE_TOKEN"
    /// A folder holding Deck Memory's meaning model instead of the bundled one.
    public static let memoryModelFolder = "TD_DECKMEMORY_EMBEDDING_DIR"
    /// A folder holding the built-in skills instead of the bundled ones.
    public static let builtInSkillsFolder = "TD_BUILT_IN_SKILLS_DIR"
}
