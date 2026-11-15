import Foundation
import TerminalDeckBackend
import TerminalDeckNativeCore

/// 15 Nov review item 3: the permission pill shows the mode a session REALLY runs in, wherever it is shown.
///
/// Why it can differ: the New session page starts a session in his pick by name (`chosenStartPermission`; for
/// "Ask first" that is `--permission-mode default`). The session host saves the launch's `permissionMode` but not that
/// it was passed by name, so a RESTORED (or resumed) chat is relaunched with no mode flag for "Ask first"
/// (`BackendSessionChats.withChoices`: "default" is only passed when marked explicit). Claude Code then runs its own
/// setting (`permissions.defaultMode`, e.g. "bypassPermissions" on the owner's Macs), while the host still reports
/// "Ask first". Keeping the stricter mode needs a host change (seat note 2026-11-15-new-session-review, not made
/// tonight: no session-host change). Until then the app corrects what it shows, from facts it can read:
/// - only a Claude chat that was restored or resumed (`resumed`), reported as "Ask first",
/// - and only until he changes the mode in that chat himself (a live change is applied to the running CLI: trusted),
/// - shows Claude Code's own default mode for that session (its settings, project then user, as Claude Code reads
///   them), with a note saying why.
/// Codex passes "Ask first" as a flag on every launch and needs no correction.
enum NativeSessionModeTruth {
    static let changedKey = "sessionModeTruth.changedHere.v1"
    /// The note the answer carries when the shown mode was corrected.
    static let note = "This session was restored. It runs with Claude's own setting, not the one it started with. Choose a mode here to set it again."

    /// The pure rule. `reported`: the host's `permissionMode` (HootPermissionMode raw value). `ownDefault`: the CLI's own
    /// default mode value ("bypassPermissions", "acceptEdits", "plan", "default"), nil when it sets none.
    static func shown(reported: String?, provider: String, resumed: Bool, changedHere: Bool, ownDefault: String?) -> String? {
        guard provider == "claude", resumed, !changedHere, reported == HootPermissionMode.ask.rawValue, let ownDefault else { return nil }
        // Claude Code's values, read as the chat's own reading of them (`BackendHootReadyDefaults.chatMode`).
        let real: HootPermissionMode
        switch ownDefault {
        case "plan": real = .plan
        case "acceptEdits": real = .changes
        case "bypassPermissions": real = .bypass
        default: real = .ask
        }
        return real == .ask ? nil : real.rawValue
    }

    /// The host's answer, corrected by the rule (nil facts: unchanged).
    static func corrected(_ answer: NativeRPCValue, provider: String?, resumed: Bool, changedHere: Bool, ownDefault: String?) -> NativeRPCValue {
        guard let provider, let mode = shown(reported: answer["permissionMode"].string, provider: provider, resumed: resumed,
                                             changedHere: changedHere, ownDefault: ownDefault) else { return answer }
        return answer.setting("permissionMode", .string(mode)).setting("permissionNote", .string(note))
    }

    /// Claude Code's own default mode for a session in `cwd` with config folder `configDir` (nil: ~/.claude), in Claude
    /// Code's order: the project's local settings, the project's settings, then the user's. Read-only, bounded.
    static func claudeOwnDefault(cwd: String?, configDir: String?) -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var files: [String] = []
        if let cwd, cwd.hasPrefix("/") { files += [cwd + "/.claude/settings.local.json", cwd + "/.claude/settings.json"] }
        files.append((configDir.flatMap { $0.isEmpty ? nil : $0 } ?? home + "/.claude") + "/settings.json")
        for file in files {
            guard let size = (try? FileManager.default.attributesOfItem(atPath: file))?[.size] as? Int, size <= 1_048_576,
                  let data = FileManager.default.contents(atPath: file),
                  let mode = (try? NativeRPCValue.parseJSON(data))?["permissions"]["defaultMode"].string, !mode.isEmpty else { continue }
            return mode
        }
        return nil
    }

    // MARK: He changed the mode in that chat (this Mac's own record; bounded)

    static func changedHere(_ id: String, defaults: UserDefaults = .standard) -> Bool {
        (defaults.stringArray(forKey: changedKey) ?? []).contains(id)
    }
    static func noteChanged(_ id: String, defaults: UserDefaults = .standard) {
        var ids = (defaults.stringArray(forKey: changedKey) ?? []).filter { $0 != id }
        ids.append(id)
        defaults.set(Array(ids.suffix(400)), forKey: changedKey)
    }
}
