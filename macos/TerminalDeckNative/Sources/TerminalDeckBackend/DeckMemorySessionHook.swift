import Foundation
import CryptoKit
import TerminalDeckNativeCore

/// L8 HOST · Deck Memory (11 Oct 2026): what a terminal session is handed at launch so the APP keeps its memory.
///
/// Everything lives in the app's own data folder (`<data>/session-memory/`), never in the person's
/// `~/.claude/settings.json`, `~/.codex`, `~/.gemini` or a project file:
/// ```
/// deck-memory-hook            the hook program (zsh -f, no network, a few milliseconds)
/// events/<stamp>-<event>.json one file per hook call; the app watches this folder (no polling)
/// sessions/<session id>/      start.md (card + topics + notes), prompt.md (per-message lines), owner.json, state.json
/// settings/<hash>.json        the ONE merged Claude --settings file of a launch (its own flags + these hooks)
/// ```
/// The hook knows its session from `TERMINALDECK_SESSION_ID`, which every session the app starts already has.
public enum DeckMemorySessionHook {
    public static let folderName = "session-memory"
    public static func root(dataRoot: URL) -> URL { dataRoot.appendingPathComponent(folderName, isDirectory: true) }
    public static func events(_ root: URL) -> URL { root.appendingPathComponent("events", isDirectory: true) }
    public static func session(_ root: URL, _ id: String) -> URL { root.appendingPathComponent("sessions", isDirectory: true).appendingPathComponent(id, isDirectory: true) }
    public static func script(_ root: URL) -> URL { root.appendingPathComponent("deck-memory-hook") }

    /// Hook events as the script names them, and the CLI event each one is wired to.
    public static let claudeEvents: [(cli: String, name: String, timeout: Int)] = [
        ("SessionStart", "session-start", 10), ("UserPromptSubmit", "prompt", 5), ("Stop", "stop", 5), ("PreCompact", "pre-compact", 20),
    ]
    public static let codexEvents: [(cli: String, name: String, timeout: Int)] = [
        ("SessionStart", "session-start", 10), ("UserPromptSubmit", "prompt", 5), ("Stop", "stop", 5),
    ]
    public static let geminiEvents: [(cli: String, name: String, timeout: Int)] = [
        ("SessionStart", "session-start", 10), ("BeforeAgent", "prompt", 5), ("AfterAgent", "stop", 5),
    ]

    /// SessionStart and UserPromptSubmit: whatever the hook prints is added to the conversation by the CLI.
    static let scriptText = #"""
    #!/bin/zsh -f
    # Terminal Deck memory hook.  Usage: deck-memory-hook <event>   (the CLI's hook JSON arrives on stdin)
    # It files the event for the app (a local file, no network) and prints what the app prepared for this session.
    zmodload zsh/datetime 2>/dev/null
    event=$1; root=${0:A:h}; sid=${TERMINALDECK_SESSION_ID:-}
    [[ -n $sid && $sid =~ '^[0-9A-Za-z-]+$' ]] || exit 0
    dir=$root/sessions/$sid
    input=$(cat 2>/dev/null); [[ $input == \{* ]] || input=null
    stamp=${EPOCHREALTIME:-$(date +%s)}; name=${stamp/./}-$$-$event
    mkdir -p $root/events 2>/dev/null
    print -r -- "{\"event\":\"$event\",\"session\":\"$sid\",\"at\":$stamp,\"name\":\"$name\",\"input\":$input}" > $root/events/.$name.tmp 2>/dev/null \
      && mv -f $root/events/.$name.tmp $root/events/$name.json 2>/dev/null
    case $event in
      session-start)
        # The app writes start.md the moment the session exists; a just-started CLI may get here first.
        # A session the app never prepared (no folder at all) is not waited for.
        [[ -d $dir ]] && for i in {1..25}; do [[ -e $dir/start.md ]] && break; sleep 0.1; done
        [[ -s $dir/start.md ]] && cat $dir/start.md ;;
      prompt)
        [[ -s $dir/prompt.md ]] && cat $dir/prompt.md ;;
      pre-compact)
        # Safety net: give the app a moment to save the open topics and lay down a fresh start.md first.
        for i in {1..80}; do [[ -e $dir/ack-$name ]] && break; sleep 0.1; done
        rm -f $dir/ack-$name 2>/dev/null ;;
    esac
    exit 0
    """#

    /// Write (or refresh) the hook program. Returns its path.
    @discardableResult public static func install(root: URL) throws -> URL {
        let manager = FileManager.default
        for folder in [root, events(root), root.appendingPathComponent("sessions", isDirectory: true), root.appendingPathComponent("settings", isDirectory: true)] {
            try manager.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        let file = script(root), body = Data((scriptText + "\n").utf8)
        if (try? Data(contentsOf: file)) != body { try body.write(to: file, options: .atomic) }
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
        return file
    }

    static func quoted(_ path: String) -> String { "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'" }
    static func command(_ root: URL, _ event: String) -> String { "/bin/zsh -f " + quoted(script(root).path) + " " + event }

    /// `{"SessionStart":[{"hooks":[{"type":"command","command":…,"timeout":…}]}], …}` in the CLI's own settings shape.
    static func hooks(root: URL, events: [(cli: String, name: String, timeout: Int)], milliseconds: Bool = false) -> [String: Any] {
        var out: [String: Any] = [:]
        for event in events {
            out[event.cli] = [["hooks": [["type": "command", "command": command(root, event.name), "timeout": event.timeout * (milliseconds ? 1000 : 1)] as [String: Any]]] as [String: Any]]
        }
        return out
    }

    /// Later keys win, except `hooks`, where each event's lists are joined (the launch's own hooks keep running).
    static func merged(_ base: [String: Any], _ extra: [String: Any]) -> [String: Any] {
        var out = base
        for (key, value) in extra {
            if key == "hooks", let old = out[key] as? [String: Any], let new = value as? [String: Any] {
                var hooks = old
                for (event, list) in new { hooks[event] = ((hooks[event] as? [Any]) ?? []) + ((list as? [Any]) ?? []) }
                out[key] = hooks
            } else if key == "permissions", let old = out[key] as? [String: Any], let new = value as? [String: Any] {
                // Rule lists (allow / deny / ask) are joined without repeats; other permission keys: later wins.
                var permissions = old
                for (name, rule) in new {
                    if let added = rule as? [String], let had = permissions[name] as? [String] { permissions[name] = had + added.filter { !had.contains($0) } }
                    else { permissions[name] = rule }
                }
                out[key] = permissions
            } else { out[key] = value }
        }
        return out
    }
    static func json(_ value: String) -> [String: Any]? {
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let data: Data? = text.hasPrefix("{") ? Data(text.utf8) : (text.hasPrefix("/") ? try? Data(contentsOf: URL(fileURLWithPath: text)) : nil)
        guard let data, data.count <= 2 * 1024 * 1024 else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
    static func store(_ object: [String: Any], root: URL, prefix: String, beside: URL? = nil) throws -> URL {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        let hash = SHA256.hash(data: data).prefix(8).map { String(format: "%02x", $0) }.joined()
        // L8 (11 Oct): a settings file that carries a private value of this launch (Gemini's copy of the app's
        // tool token) is written beside the file it was built from, in that launch's own folder, so it goes when
        // the launch's files go; never kept in the shared settings folder.
        let file = (beside ?? root.appendingPathComponent("settings", isDirectory: true)).appendingPathComponent(prefix + "-" + hash + ".json")
        if (try? Data(contentsOf: file)) != data { try data.write(to: file, options: .atomic) }
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        return file
    }

    /// Claude Code takes ONE `--settings`. Every `--settings` the launch already carries (agent settings,
    /// Ultracode, the phone guard) is folded together with the memory hooks into one private file, and the
    /// launch gets that single flag. If any existing value cannot be read, the launch is left exactly as it was.
    /// FORK-TASKS / L8 (11 Oct): a session the task engine started for a task answers through the task tools.
    /// The owner giving the task is his yes to exactly these on that one task (`BackendTaskAssignmentConsent`,
    /// enforced by the APP on every call: the session's own task, the reviewer's own verdict). Claude Code's
    /// own permission list cannot look at a tool's arguments, so here the same tools are only spared Claude
    /// Code's second question inside the agent's session, where nobody is watching. `tools_run` and
    /// `tools_describe` are in the list because, with the tool index on, the task tools are reached through
    /// them; every tool run that way is still checked by the app as before (anything wider asks on screen).
    public static func taskToolRules(server: String = "deck-control") -> [String] {
        // The one allowance list for every AI (BackendSessionAppTools); here in Claude Code's rule form.
        BackendSessionAppTools.taskAllowance().map { "mcp__" + server + "__" + $0 }
    }

    public static func claudeArguments(_ arguments: [String], root: URL, taskSession: Bool = false) -> [String] {
        var settings: [String: Any] = [:], rest: [String] = [], index = 0
        while index < arguments.count {
            if arguments[index] == "--settings", index + 1 < arguments.count {
                guard let value = json(arguments[index + 1]) else { return arguments }
                settings = merged(settings, value); index += 2; continue
            }
            if arguments[index].hasPrefix("--settings=") {
                guard let value = json(String(arguments[index].dropFirst("--settings=".count))) else { return arguments }
                settings = merged(settings, value); index += 1; continue
            }
            rest.append(arguments[index]); index += 1
        }
        settings = merged(settings, ["hooks": hooks(root: root, events: claudeEvents)])
        if taskSession { settings = merged(settings, ["permissions": ["allow": taskToolRules()]]) }
        guard let file = try? store(settings, root: root, prefix: "claude") else { return arguments }
        return rest + ["--settings", file.path]
    }

    /// Where a Codex or Gemini session finds its memory: a pointer added to its standing instructions.
    public static func pointer(root: URL) -> String {
        let file = root.appendingPathComponent("sessions").path + "/$TERMINALDECK_SESSION_ID/start.md"
        return "Terminal Deck keeps your long-term memory (your card, your open topics and recent notes) outside this chat. "
            + "Before your first answer, read it: run `cat \"\(file)\"`. "
            + "If that file is empty or missing you have no memory card for this session; carry on normally. "
            + "Trust what it says over your own recollection, and keep your open topic notes current when a topic moves."
    }

    /// Codex: the pointer rides in `developer_instructions` (added to the one the launch already has, or its own).
    /// Its hooks (SessionStart / UserPromptSubmit / Stop) are passed inline only when `withHooks` is on, because
    /// Codex asks the person to trust new hooks once; turn end is otherwise taken from the session's status.
    public static func codexArguments(_ arguments: [String], root: URL, withHooks: Bool) -> [String] {
        var out = arguments
        let note = BackendNativeInstructions.tomlString("\n\n" + pointer(root: root))   // "\"…\""
        let inner = String(note.dropFirst().dropLast())
        if let index = out.firstIndex(where: { $0.hasPrefix("developer_instructions=\"") && $0.hasSuffix("\"") }) {
            out[index] = String(out[index].dropLast()) + inner + "\""
        } else {
            out += ["-c", "developer_instructions=" + BackendNativeInstructions.tomlString(pointer(root: root))]
        }
        if withHooks {
            out += ["-c", "features.hooks=true"]
            for event in codexEvents {
                out += ["-c", "hooks.\(event.cli)=[{hooks=[{type=\"command\",command=" + BackendNativeInstructions.tomlString(command(root, event.name)) + ",timeout=\(event.timeout)}]}]"]
            }
        }
        return out
    }

    /// Gemini: a private system-settings file for this child process only (merged with one the launch already
    /// set), carrying the SessionStart / BeforeAgent / AfterAgent hooks. Returns the environment to add.
    public static func geminiEnvironment(existing: [String: String], root: URL) -> [String: String] {
        let key = "GEMINI_CLI_SYSTEM_SETTINGS_PATH"
        var settings: [String: Any] = [:]
        if let path = existing[key], !path.isEmpty {
            guard let value = json(path) else { return [:] }
            settings = value
        }
        settings = merged(settings, ["hooks": hooks(root: root, events: geminiEvents, milliseconds: true)])
        let beside = existing[key].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0).deletingLastPathComponent() }
        guard let file = try? store(settings, root: root, prefix: "gemini", beside: settings["mcpServers"] == nil ? nil : beside) else { return [:] }
        return [key: file.path]
    }
}
