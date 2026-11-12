import Foundation

/// Every Claude / Codex session Terminal Deck starts knows it runs inside Terminal Deck and opens phones
/// through Terminal Deck's own panel (ANDROID lane, 10 Oct). Asad: "they must already know about where
/// they are running ... always priority to use terminal deck's own feature first". Two layers:
/// a short standing note (Claude --append-system-prompt, Codex developer_instructions), and for Claude
/// a private PreToolUse hook (its own --settings file in the app's storage, never his settings or his
/// project) that stops `open -a Simulator`, `xcrun simctl boot/install/launch/openurl`, `emulator -avd`
/// and adb installs/launches, and says which Terminal Deck tool does it inside the session instead.
public enum BackendANDROIDSessionPhoneNote {
    public static let tool = "mcp__deck-control__devices_open_app"

    /// CONNECT-SKILLS: plus the line naming Terminal Deck's built-in skills (empty when this copy has none).
    public static var note: String { phoneNote + BackendBuiltInSkills.sessionLine() }
    public static let phoneNote = """
    You are running inside Terminal Deck (a Mac app). This session has a phone panel beside it that shows an \
    iOS Simulator or Android emulator. To open, install or test an app on a phone, call the \(tool) tool \
    (platform ios|android, app = bundle id/package or "settings", installPath = .app/.apk, url): it starts the \
    device headless and shows it in this session's panel. Then use the deck-control devices_* tools (screenshot, \
    tap, type, tree) to see and drive it. Never run `open -a Simulator`, `xcrun simctl boot`, or `emulator -avd` \
    yourself: they open windows outside Terminal Deck. \(browserLine)
    """

    /// Codex has no deck-control tools here (only Claude sessions get them): keep phones headless.
    public static var codexNote: String { codexPhoneNote + BackendBuiltInSkills.sessionLine() }
    public static let codexPhoneNote = """
    You are running inside Terminal Deck (a Mac app) whose session has a phone panel that shows an iOS \
    Simulator or Android emulator. Keep phones headless: use `xcrun simctl` (boot/install/launch/openurl) and \
    `adb`, and start Android emulators with `-no-window`. Never run `open -a Simulator` or open an emulator \
    window: Terminal Deck shows the device in this session's panel. \(browserLine)
    """

    /// APPMGMT (8 Nov): an AI that starts the installed Google Chrome makes macOS tell the person "TerminalDeckNativeHelper
    /// was prevented from modifying apps" (Chrome hard-links its own program; macOS blames the keeper, the top of the tree).
    /// Guidance only, for Claude, Codex and Gemini alike: no tool is blocked or hidden (Asad, 4 Nov).
    public static let browserLine = "For web pages prefer Terminal Deck's own browser tools (deck-control browser_*) or Playwright's bundled " +
        "Chromium; if you launch the installed Google Chrome (Playwright channel 'chrome' or executablePath /Applications/Google Chrome.app), " +
        "pass --disable-features=MacAppCodeSignClone, or macOS blocks it and warns the person."

    /// The hook: reads Claude's PreToolUse JSON on stdin; denies phone-window commands with the way to do it here.
    static let script = """
    #!/bin/zsh -f
    # Terminal Deck: phones open in this session's panel, never in Simulator.app or an emulator window.
    input=$(cat)
    if print -r -- "$input" | /usr/bin/grep -Eq 'open +(-[a-zA-Z]+ +)*-a +[^a-zA-Z]*Simulator|Simulator\\.app|xcrun +simctl +(boot|install|launch|openurl)|(^|[ /"])emulator +(-avd|@)|adb( +-s +[^ ]+)? +(install|shell +(am +start|monkey))'; then
      reason='Terminal Deck shows phones in this session'"'"'s own phone panel. Do not open Simulator.app or an emulator window, and do not boot/install/launch with simctl, emulator or adb. Call the \(tool) tool instead (platform ios|android; app = bundle id/package or settings; installPath = .app/.apk; url): it starts the device headless, shows it in this session'"'"'s panel and opens the app. Then use the deck-control devices_* tools to see and drive it.'
      print -r -- '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"'"$reason"'"}}'
    fi
    exit 0
    """

    /// Claude's extra launch arguments: the note (unless a system-prompt file already carries it) and the
    /// private hook settings (unless the launch already has its own --settings).
    public static func claudeArguments(storageRoot: URL, existing: [String]) -> [String] {
        var arguments: [String] = []
        if !existing.contains("--append-system-prompt"), !existing.contains("--append-system-prompt-file") {
            arguments += ["--append-system-prompt", note]
        }
        if !existing.contains("--settings"), let settings = try? hookSettings(storageRoot: storageRoot) {
            arguments += ["--settings", settings.path]
        }
        return arguments
    }

    /// The app's own copy of the hook and its settings file (rewritten when its text changes).
    static func hookSettings(storageRoot: URL) throws -> URL {
        let folder = storageRoot.appendingPathComponent("session-phone", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let hook = folder.appendingPathComponent("phone-guard.zsh"), settings = folder.appendingPathComponent("claude-settings.json")
        let body = Data(script.utf8)
        if (try? Data(contentsOf: hook)) != body { try body.write(to: hook, options: .atomic) }
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: hook.path)
        let json: [String: Any] = ["hooks": ["PreToolUse": [["matcher": "Bash", "hooks": [["type": "command", "command": "/bin/zsh -f " + quoted(hook.path), "timeout": 10]]]]]]
        let data = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
        if (try? Data(contentsOf: settings)) != data { try data.write(to: settings, options: .atomic) }
        return settings
    }

    /// A combined system-prompt file: a task agent's own instructions, then the note.
    static func combined(_ text: String, id: String, storageRoot: URL) throws -> URL {
        let folder = storageRoot.appendingPathComponent("session-phone", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let file = folder.appendingPathComponent("instructions-" + id + ".md")
        try Data((text + "\n\n" + note).utf8).write(to: file, options: .atomic)
        return file
    }

    private static func quoted(_ path: String) -> String { "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'" }
}
