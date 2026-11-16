import Foundation
import Darwin
import TerminalDeckNativeCore

/// The witness's answer for one file that has gone from the disk.
/// Owner's rule (14 Nov 2026): a file removed by hand goes from that device only; a file removed by an AI
/// goes everywhere (into the 30-day Bin). `cannotKnow` must be treated exactly like `byHand` by every engine:
/// a wrong "by an AI" removes something from all his devices, a wrong "by hand" loses nothing.
public enum BackendAIDeleteVerdict: Equatable, Sendable {
    /// `session` is Terminal Deck's own session id; `agentName` is the seat/agent or session name for the Bin
    /// line ("Removed by an AI on <Mac>"); `since` is when that AI command started.
    case byAI(session: String, agentName: String, since: Date)
    case byHand
    /// The witness was not listening for part of the time span (app not running, records already tidied away).
    case cannotKnow
    public var removedEverywhere: Bool { if case .byAI = self { return true } else { return false } }
}

/// Remembers, per Terminal Deck session, the recent AI commands that can remove files (a removing shell
/// command, the AI's own delete tool, or a patch's Delete/Move lines), with only the paths they name (never the
/// command text), and answers one question for the sync engines: was this vanished file removed by an AI
/// command running inside a Terminal Deck session on this Mac?
///
/// Fed only by hook events the session coordinator has already ACCEPTED (they come from that session's own
/// process tree). "By an AI" needs both a time overlap AND a link between the command and the path; see
/// `verdict`. Kept in memory with a small file (`ai-delete-witness.json`) so a restart mid-command still knows.
public final class BackendAIDeleteWitness: @unchecked Sendable {
    /// Slack on both ends of a command window. Hooks reach the app over a local socket in milliseconds and use
    /// the same clock as the engines, but an engine stamps "last seen" / "found gone" after its own scan or after
    /// an FSEvents batch (macOS coalesces events for about a second), so 2 s covers those lags without letting an
    /// unrelated command a minute away count.
    public static let tolerance: TimeInterval = 2
    /// A window with no end (end event lost, app restarted, background command) counts as running for at most
    /// this long after it started.
    public static let maxOpen: TimeInterval = 3600
    /// Records are kept a day; a question about an older span is `cannotKnow` if nothing matches.
    public static let keep: TimeInterval = 86_400
    static let maxWindows = 1000
    public static let fileName = "ai-delete-witness.json"
    static let fileVersion = 3

    struct Cover: Codable, Equatable {
        enum Kind: String, Codable { case path, pattern, folder }
        var kind: Kind
        var value: String
        /// The command also removes what is inside it (recursive rm, mv of a folder, find).
        var subtree: Bool
        /// `find … -name/-iname P -delete`: only entries whose own name matches P (fnmatch, as find does).
        var name: String? = nil
        var caseless: Bool? = nil
    }

    struct Window: Codable, Equatable {
        var session: String
        var provider: String
        var agentName: String
        var tool: String
        var toolUseID: String?
        /// A short hash used only to pair a start with its end; the command text itself is never kept.
        var key: String
        var start: Double
        var end: Double?
        var background: Bool
        var covers: [Cover]
        /// One tool call, persisted with its paths so every engine uses the same Bin group after a restart.
        var group: String
        var sessionName: String?
        var seatName: String?
        /// A script's effects cannot be read from shell targets. Never infer an AI deletion from it.
        var uncertain: Bool
        /// The AI asked him for permission and the command has not been seen running (no end event yet). It
        /// never counts: a refused or denied command removed nothing. Cleared only by a successful end event.
        var pending: Bool? = nil
        /// An end event arrived for it (it ran).
        var ran: Bool? = nil
        /// Only the end event was seen (start lost or before this run): it marks its linked paths cannot-know
        /// and never makes anything "by an AI".
        var startUnseen: Bool? = nil
    }

    private struct Saved: Codable { var version: Int; var windows: [Window] }

    private let lock = NSLock()
    private let file: URL?
    private let home: String
    private var windows: [Window] = []
    /// When this run started listening. Events from before (app not running) were never seen.
    public let listeningSince: Date

    public init(dataRoot: URL?, home: String = NSHomeDirectory(), now: Date = Date()) {
        file = dataRoot?.appendingPathComponent(Self.fileName)
        self.home = home; listeningSince = now
        // Version 1 did not distinguish git/build/script covers; version 2 still held Write/Edit covers, rmdir
        // covers over folder contents and hour-backdated end-only windows. Reusing either could remove files
        // everywhere, so only version 3 is read (older spans answer cannotKnow).
        if let file, let data = try? Data(contentsOf: file), data.count < 4 * 1024 * 1024,
           let saved = try? JSONDecoder().decode(Saved.self, from: data), saved.version == Self.fileVersion {
            windows = saved.windows
            prune(now: now.timeIntervalSince1970)
        }
    }

    // MARK: The process-wide instance (the engines read it)

    private static let registry = NSLock()
    nonisolated(unsafe) private static var installed: BackendAIDeleteWitness?
    public static var current: BackendAIDeleteWitness? { registry.withLock { installed } }
    public static func install(_ witness: BackendAIDeleteWitness?) { registry.withLock { installed = witness } }

    /// THE call for the sync engines. `lastSeen`: when the file was last known to be on disk; `goneAt`: when it
    /// was found gone. No witness running means `cannotKnow` (= by hand).
    public static func verdict(path: String, lastSeen: Date, goneAt: Date, now: Date = Date()) -> BackendAIDeleteVerdict {
        current?.verdict(path: path, lastSeen: lastSeen, goneAt: goneAt, now: now) ?? .cannotKnow
    }

    // MARK: Answering

    /// By an AI only when BOTH hold:
    /// 1. time: an AI command window on this Mac (start .. end, or .. now / start + `maxOpen` while open)
    ///    overlaps [lastSeen, goneAt], each side widened by `tolerance`;
    /// 2. link: the command names the path (exact, or a glob that matches it), or names a folder above it and
    ///    removes recursively, or (only when the removing command's targets cannot be read from its text:
    ///    variables or substitutions in targets of plain rm/rmdir/unlink/trash/find -delete/mv) the command
    ///    ran in that folder or a folder above it. Git/build tools never count; scripts are unknown.
    /// A bare time overlap is never enough: he may be deleting in Finder while an AI works elsewhere.
    /// Among several matches the strongest link wins, then the latest start.
    public func verdict(path: String, lastSeen: Date, goneAt: Date, now: Date = Date()) -> BackendAIDeleteVerdict {
        assessment(path: path, lastSeen: lastSeen, goneAt: goneAt, now: now).verdict
    }

    /// Keep the verdict and its exact winning command together; equal session/start times are not an identity.
    func assessment(path: String, lastSeen: Date, goneAt: Date, now: Date) -> (verdict: BackendAIDeleteVerdict, window: Window?) {
        let target = Self.normalize(path)
        guard target.hasPrefix("/") else { return (.cannotKnow, nil) }
        let from = min(lastSeen, goneAt).timeIntervalSince1970, to = max(lastSeen, goneAt).timeIntervalSince1970
        let clock = now.timeIntervalSince1970
        let snapshot = lock.withLock { windows }
        var best: (strength: Int, window: Window)?
        var uncertain = false, unseenLink = false
        for window in snapshot {
            // Asked for permission and never seen running: refused, denied, or not run yet. Never counts.
            if window.pending == true { continue }
            let end = window.end ?? min(clock, window.start + Self.maxOpen)
            guard window.start - Self.tolerance <= to, end + Self.tolerance >= from else { continue }
            if window.uncertain { uncertain = true }
            let strength = window.covers.map { Self.strength($0, target) }.max() ?? 0
            guard strength > 0 else { continue }
            // Its start is unknown, so its time cannot be matched: cannot know, never by an AI.
            if window.startUnseen == true { unseenLink = true; continue }
            if let current = best, (current.strength, current.window.start, current.window.session) >= (strength, window.start, window.session) { continue }
            best = (strength, window)
        }
        // A script supplies no path evidence; an independently named target still counts as before.
        if let best, !uncertain || best.strength > 1 {
            return (.byAI(session: best.window.session, agentName: best.window.agentName, since: Date(timeIntervalSince1970: best.window.start)), best.window)
        }
        if uncertain || unseenLink { return (.cannotKnow, nil) }
        // Not listening for part of the span, or the span is older than what is kept: say so (engines treat it as by hand).
        if from < listeningSince.timeIntervalSince1970 || from < clock - Self.keep { return (.cannotKnow, nil) }
        return (.byHand, nil)
    }

    // MARK: Feeding

    /// One accepted hook event. `session` is the session's directory row (for the agent or session name).
    /// `at` overrides the receive time (tests).
    public func accept(_ event: BackendSessionHookEvent, session row: NativeRPCValue?, at: Date? = nil) {
        guard let session = event.sessionID else { return }
        let time = (at ?? event.receivedAt).timeIntervalSince1970
        switch event.event {
        case "PreToolUse", "BeforeTool":
            guard let tool = event.toolName, let reading = Self.reading(tool: tool, input: event.payload["tool_input"], cwd: event.cwd, home: home) else { return }
            let id = Self.toolUseID(event)
            let window = Window(session: session, provider: event.provider, agentName: Self.agentName(row, provider: event.provider), tool: tool,
                                toolUseID: id, key: reading.key, start: time, end: nil, background: reading.background, covers: reading.covers,
                                group: UUID().uuidString, sessionName: Self.sessionName(row), seatName: Self.seatName(row), uncertain: reading.uncertain)
            mutate(time) { windows in
                // Its permission ask arrived first and already holds the (pending) window.
                if Self.openMatch(windows, session: session, tool: tool, id: id, key: reading.key, pendingOnly: true) != nil { return }
                windows.append(window)
            }
        case "PermissionRequest":
            // He is asked before the command runs; until an end event shows it ran, it removed nothing.
            guard let tool = event.toolName, let reading = Self.reading(tool: tool, input: event.payload["tool_input"], cwd: event.cwd, home: home) else { return }
            let id = Self.toolUseID(event)
            let window = Window(session: session, provider: event.provider, agentName: Self.agentName(row, provider: event.provider), tool: tool,
                                toolUseID: id, key: reading.key, start: time, end: nil, background: reading.background, covers: reading.covers,
                                group: UUID().uuidString, sessionName: Self.sessionName(row), seatName: Self.seatName(row), uncertain: reading.uncertain, pending: true)
            mutate(time) { windows in
                if let match = Self.openMatch(windows, session: session, tool: tool, id: id, key: reading.key) { windows[match].pending = true }
                else { windows.append(window) }
            }
        case "Notification":
            // Gemini asks for tool permission through a Notification without naming the call: hold the newest
            // command of that session that has not been seen running.
            let kind = (event.payload["notification_type"].string ?? "").lowercased()
            guard ["toolpermission", "permission_prompt"].contains(kind) else { return }
            let touches = lock.withLock { windows.contains { $0.session == session && $0.end == nil && $0.ran != true } }
            guard touches else { return }
            mutate(time) { windows in
                if let index = windows.indices.last(where: { windows[$0].session == session && windows[$0].end == nil && windows[$0].ran != true }) {
                    windows[index].pending = true
                }
            }
        case "PostToolUse", "PostToolUseFailure", "AfterTool":
            guard let tool = event.toolName, let reading = Self.reading(tool: tool, input: event.payload["tool_input"], cwd: event.cwd, home: home) else { return }
            let id = Self.toolUseID(event)
            let name = Self.agentName(row, provider: event.provider)
            let failed = event.event == "PostToolUseFailure"
            mutate(time) { windows in
                if let match = Self.openMatch(windows, session: session, tool: tool, id: id, key: reading.key) {
                    windows[match].ran = true
                    // A failure after a permission ask may be the refusal itself: it stays not-counted.
                    if !failed { windows[match].pending = nil }
                    // A background command outlives its tool call: it stays open until the session ends or `maxOpen`.
                    if !windows[match].background { windows[match].end = time }
                } else {
                    // The start was never seen (app restarted, event lost): when it ran is unknown, so its paths are
                    // cannot-know. Never a backdated "by an AI" window.
                    let start = max(listeningSince.timeIntervalSince1970, time - Self.maxOpen)
                    windows.append(Window(session: session, provider: event.provider, agentName: name, tool: tool, toolUseID: id, key: reading.key,
                                          start: min(start, time), end: time, background: reading.background, covers: reading.covers,
                                          group: UUID().uuidString, sessionName: Self.sessionName(row), seatName: Self.seatName(row), uncertain: false,
                                          ran: true, startUnseen: true))
                }
            }
        case "Stop", "StopFailure", "AfterAgent":
            close(session: session, at: time, background: false)
        case "SessionEnd":
            close(session: session, at: time, background: true)
        default: return
        }
    }

    /// The session exited or was removed: nothing it started through its tool calls is counted after this.
    public func sessionEnded(_ session: String, at: Date = Date()) {
        close(session: session, at: at.timeIntervalSince1970, background: true)
    }

    /// The open window this event belongs to: same session and tool, by tool-use id when it has one, else by key.
    static func openMatch(_ windows: [Window], session: String, tool: String, id: String?, key: String, pendingOnly: Bool = false) -> Int? {
        let open = windows.indices.filter { windows[$0].session == session && windows[$0].end == nil && windows[$0].tool == tool && (!pendingOnly || windows[$0].pending == true) }
        return id.flatMap { id in open.first { windows[$0].toolUseID == id } } ?? open.first { windows[$0].key == key }
    }

    private func close(session: String, at time: Double, background: Bool) {
        let touches = lock.withLock { windows.contains { $0.session == session && $0.end == nil && (background || !$0.background) } }
        guard touches else { return }
        mutate(time) { windows in
            for index in windows.indices where windows[index].session == session && windows[index].end == nil && (background || !windows[index].background) {
                windows[index].end = time
            }
        }
    }

    private func mutate(_ time: Double, _ change: (inout [Window]) -> Void) {
        lock.withLock {
            change(&windows)
            prune(now: time) // event time: deterministic, and equal to the wall clock in the app
            save()
        }
    }

    /// Caller holds the lock (or is the initializer).
    private func prune(now: Double) {
        windows.removeAll { ($0.end ?? $0.start + Self.maxOpen) < now - Self.keep }
        if windows.count > Self.maxWindows { windows.removeFirst(windows.count - Self.maxWindows) }
    }

    /// Caller holds the lock.
    private func save() {
        guard let file, let data = try? JSONEncoder().encode(Saved(version: Self.fileVersion, windows: windows)) else { return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard (try? data.write(to: file, options: .atomic)) != nil else { return }
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }

    static func toolUseID(_ event: BackendSessionHookEvent) -> String? {
        (event.payload["tool_use_id"].string ?? event.payload["call_id"].string).flatMap { $0.isEmpty ? nil : $0 }
    }

    static func agentName(_ row: NativeRPCValue?, provider: String) -> String {
        for key in ["agent", "name"] {
            if let value = row?[key].string?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty { return value }
        }
        switch provider {
        case "claude": return "Claude Code"
        case "codex": return "Codex"
        case "gemini": return "Gemini"
        default: return provider
        }
    }

    static func sessionName(_ row: NativeRPCValue?) -> String? {
        // The actual session directory calls its display name `title`; never fall back to its routing id.
        for value in [row?["title"].string, row?["name"].string] {
            if let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return value }
        }
        return nil
    }

    static func seatName(_ row: NativeRPCValue?) -> String? {
        for value in [row?["agent"].string, row?["seat"]["name"].string] {
            if let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               !["claude", "claude code", "codex", "gemini"].contains(value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()) { return value }
        }
        return nil
    }

    // MARK: Reading one tool call (paths only)

    struct Reading: Equatable { var covers: [Cover]; var background: Bool; var key: String; var uncertain = false }

    static let shellTools: Set<String> = ["bash", "shell", "exec_command", "local_shell", "shell_command", "unified_exec", "run_shell_command", "container.exec"]
    /// Only tools that delete. Write/Edit/MultiEdit/NotebookEdit/write_file/replace/edit_file/create_file never
    /// remove a file: naming a path they changed would turn his own later Finder delete into "by an AI".
    static let deleteTools: Set<String> = ["delete_file", "remove_file", "deletefile", "removefile", "delete_path", "remove_path"]

    static func deleteTool(_ name: String) -> Bool {
        // MCP tools arrive as mcp__<server>__<tool>.
        deleteTools.contains(name) || deleteTools.contains { name.hasPrefix("mcp__") && name.hasSuffix("__" + $0) }
    }
    static let patchTools: Set<String> = ["apply_patch", "applypatch"]

    /// nil when this tool call cannot remove a file this witness can link to a path.
    static func reading(tool: String, input: NativeRPCValue, cwd: String?, home: String) -> Reading? {
        let name = tool.lowercased()
        var base = cwd.map { normalize(expand($0, home: home)) }.flatMap { $0.hasPrefix("/") ? $0 : nil }
        for key in ["workdir", "dir_path", "directory", "cwd"] {
            guard let value = input[key].string, !value.isEmpty else { continue }
            let expanded = expand(value, home: home)
            base = expanded.hasPrefix("/") ? normalize(expanded) : base.map { normalize($0 + "/" + expanded) }
            break
        }
        if shellTools.contains(name) {
            guard let command = commandText(input) else { return nil }
            let parsed = shellCovers(command, cwd: base, home: home, depth: 0)
            guard !parsed.covers.isEmpty || parsed.uncertain else { return nil }
            let background = parsed.background || input["run_in_background"].bool == true || input["is_background"].bool == true
            return Reading(covers: parsed.covers, background: background, key: hash(name + "\u{0}" + command), uncertain: parsed.uncertain)
        }
        if deleteTool(name) {
            for key in ["file_path", "notebook_path", "absolute_path", "path", "filePath"] {
                guard let value = input[key].string, !value.isEmpty, let resolved = resolve(value, cwd: base, home: home) else { continue }
                return Reading(covers: [Cover(kind: .path, value: resolved, subtree: false)], background: false, key: hash(name + "\u{0}" + resolved))
            }
            return nil
        }
        if patchTools.contains(name) {
            let text = input["patch"].string ?? input["input"].string ?? input["command"].string
                ?? input["command"].elements?.compactMap(\.string).first(where: { $0.contains("*** Begin Patch") })
            guard let text else { return nil }
            var covers: [Cover] = [], updating: String?
            for raw in text.split(whereSeparator: \.isNewline) {
                let line = raw.trimmingCharacters(in: .whitespaces)
                if let path = line.dropPrefix("*** Delete File:") {
                    if let resolved = resolve(path.trimmingCharacters(in: .whitespaces), cwd: base, home: home) { covers.append(.init(kind: .path, value: resolved, subtree: false)) }
                } else if let path = line.dropPrefix("*** Update File:") {
                    updating = resolve(path.trimmingCharacters(in: .whitespaces), cwd: base, home: home)
                } else if line.hasPrefix("*** Move to:"), let moved = updating {
                    covers.append(.init(kind: .path, value: moved, subtree: false))
                } else if line.hasPrefix("*** Add File:") { updating = nil }
            }
            guard !covers.isEmpty else { return nil }
            return Reading(covers: covers, background: false, key: hash(name + "\u{0}" + text))
        }
        return nil
    }

    /// The stand-in path for one user-scope MCP server (never a real file; only an exact command names it).
    public static func mcpUserServerPath(_ name: String) -> String { "/.terminal-deck-mcp-servers/user/" + name }
    /// The server a `claude mcp remove` removes from his user list: literal name, user scope or none. nil otherwise.
    static func mcpRemoved(_ args: [Word]) -> String? {
        guard args.count >= 3, args[0].text == "mcp", args[1].text == "remove" else { return nil }
        var rest = args.dropFirst(2), scope: String?, name: Word?
        while let word = rest.first {
            rest = rest.dropFirst()
            if word.text == "--" { name = rest.first; break }
            if word.text == "-s" || word.text == "--scope" { scope = rest.first?.text; rest = rest.dropFirst(); continue }
            if word.text.hasPrefix("--scope=") { scope = String(word.text.dropFirst(8)); continue }
            if word.text.hasPrefix("-") { continue }
            name = word; break
        }
        guard let name, !name.dynamic, !name.glob, scope == nil || scope == "user",
              name.text.range(of: "^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$", options: .regularExpression) != nil else { return nil }
        return name.text
    }

    static func commandText(_ input: NativeRPCValue) -> String? {
        if let text = input["command"].string ?? input["cmd"].string, !text.isEmpty { return text }
        guard let parts = (input["command"].elements ?? input["cmd"].elements)?.compactMap(\.string), !parts.isEmpty else { return nil }
        // Codex's argv form: ["bash", "-lc", "<script>"] carries the script as one element.
        if parts.count >= 3, ["bash", "sh", "zsh", "dash"].contains((parts[0] as NSString).lastPathComponent),
           parts[1].hasPrefix("-"), parts[1].contains("c") { return parts[2] }
        return parts.map { "'" + $0.replacingOccurrences(of: "'", with: "'\\''") + "'" }.joined(separator: " ")
    }

    // MARK: Shell text -> covers

    struct Word: Equatable {
        var text = "", pattern = ""
        var glob = false, dynamic = false
    }
    struct Chunk: Equatable {
        var words: [Word]; var background: Bool
        /// Inside ( ) : a subshell, whose cd does not reach later commands.
        var grouped = false
    }

    /// Splits on unquoted ; && || | & newline ( ); drops redirections and comments; keeps each word's literal
    /// text, its fnmatch pattern (quoted glob characters escaped), and whether it holds a glob or anything the
    /// shell would expand ($VAR, $(...), backticks, braces), which this witness never guesses.
    static func chunks(_ source: String) -> [Chunk] {
        let chars = Array(source)
        var result: [Chunk] = [], words: [Word] = [], word: Word?, redirectTarget = false, index = 0, depth = 0
        func endWord() {
            if let current = word { if redirectTarget { redirectTarget = false } else { words.append(current) } }
            word = nil
        }
        func endChunk(_ background: Bool) {
            endWord(); redirectTarget = false
            if !words.isEmpty { result.append(Chunk(words: words, background: background, grouped: depth > 0)) }
            words = []
        }
        func literal(_ ch: Character) {
            if word == nil { word = Word() }
            word!.text.append(ch)
            if "*?[]\\".contains(ch) { word!.pattern.append("\\") }
            word!.pattern.append(ch)
        }
        func peek(_ offset: Int) -> Character? { index + offset < chars.count ? chars[index + offset] : nil }
        /// Reads a $(...), ${...} or backtick span as one dynamic run.
        func dynamicSpan() {
            if word == nil { word = Word() }
            word!.dynamic = true
            let open = chars[index]
            if open == "`" {
                index += 1
                while index < chars.count, chars[index] != "`" { index += 1 }
                return
            }
            guard let next = peek(1), next == "(" || next == "{" else { word!.text.append("$"); return }
            let close: Character = next == "(" ? ")" : "}"
            var depth = 0
            index += 1
            while index < chars.count {
                if chars[index] == next { depth += 1 } else if chars[index] == close { depth -= 1; if depth == 0 { return } }
                index += 1
            }
        }
        while index < chars.count {
            let ch = chars[index]
            switch ch {
            case " ", "\t": endWord()
            case "\n", ";": endChunk(false)
            case "(": endChunk(false); depth += 1
            case ")": endChunk(false); depth = max(0, depth - 1)
            case "&":
                if peek(1) == "&" { endChunk(false); index += 1 }
                else if peek(1) == ">" { endWord(); redirectTarget = true; index += 1; if peek(1) == ">" { index += 1 } }
                else { endChunk(true) }
            case "|":
                endChunk(false)
                if peek(1) == "|" || peek(1) == "&" { index += 1 }
            case ">", "<":
                if let current = word, !current.text.isEmpty, current.text.allSatisfy(\.isNumber), current.pattern == current.text { word = nil } else { endWord() }
                if peek(1) == ch { index += 1 }
                if peek(1) == "&" { index += 1 }
                redirectTarget = true
            case "#" where word == nil:
                while index + 1 < chars.count, chars[index + 1] != "\n" { index += 1 }
            case "'":
                if word == nil { word = Word() }
                index += 1
                while index < chars.count, chars[index] != "'" { literal(chars[index]); index += 1 }
            case "\"":
                if word == nil { word = Word() }
                index += 1
                while index < chars.count, chars[index] != "\"" {
                    if chars[index] == "\\", let next = peek(1), "\"\\$`".contains(next) { index += 1; literal(chars[index]) }
                    else if chars[index] == "$" || chars[index] == "`" { dynamicSpan() }
                    else { literal(chars[index]) }
                    index += 1
                }
            case "\\":
                if let next = peek(1) { index += 1; if next != "\n" { literal(next) } }
            case "$", "`": dynamicSpan()
            case "{", "}":
                if word == nil { word = Word() }
                word!.dynamic = true; word!.text.append(ch); word!.pattern.append(ch)
            case "*", "?", "[", "]":
                if word == nil { word = Word() }
                if ch != "]" { word!.glob = true }
                word!.text.append(ch); word!.pattern.append(ch)
            default: literal(ch)
            }
            index += 1
        }
        endChunk(false)
        return result
    }

    static let removers: Set<String> = ["rm", "rmdir", "unlink", "trash", "trash-put", "srm", "shred", "rimraf", "del", "del-cli"]
    static let flatRemovers: Set<String> = ["unlink", "shred"]
    static let wrappers: Set<String> = ["sudo", "command", "builtin", "exec", "nohup", "time", "nice", "setsid", "caffeinate", "noglob", "env", "doas"]
    static let detachers: Set<String> = ["nohup", "setsid", "disown"]
    static let cleaners: Set<String> = ["make", "gmake", "cargo", "go", "swift", "xcodebuild", "gradle", "gradlew", "mvn", "dotnet", "flutter", "npm", "yarn", "pnpm", "bun", "ant"]
    static let interpreters: Set<String> = ["python", "python3", "node", "perl", "ruby", "osascript", "deno", "php"]
    /// rmdir is not here: it removes only empty folders, so its hidden targets can never justify claiming files.
    static let folderFallback: Set<String> = ["rm", "unlink", "trash", "mv"]
    /// Words that make what follows conditional or grouped; a cd behind them cannot be followed.
    static let keywords: Set<String> = ["if", "then", "else", "elif", "while", "until", "do", "!", "{"]
    static let shells: Set<String> = ["bash", "sh", "zsh", "dash"]

    static func script(verb: String) -> Bool {
        interpreters.contains(verb) || verb.hasPrefix("python") ||
            ["sh", "bash", "zsh", "py", "js", "mjs", "cjs", "rb", "pl", "php", "swift"].contains((verb as NSString).pathExtension)
    }

    static func shellCovers(_ command: String, cwd start: String?, home: String, depth: Int) -> (covers: [Cover], background: Bool, uncertain: Bool) {
        var covers: [Cover] = [], background = false, uncertain = false, cwd = start
        for chunk in chunks(command) {
            var words = chunk.words[...]
            var detached = chunk.background
            // Leading assignments and wrappers (`sudo`, `env A=b`, `nohup`, `nice -n 5` ...).
            while let first = words.first {
                let name = (first.text as NSString).lastPathComponent
                if !first.dynamic, first.text.range(of: "^[A-Za-z_][A-Za-z0-9_]*=", options: .regularExpression) != nil { words = words.dropFirst(); continue }
                guard !first.dynamic, wrappers.contains(name) else { break }
                if detachers.contains(name) { detached = true }
                words = words.dropFirst()
                if name == "nice", words.first?.text == "-n" { words = words.dropFirst(2) }
                while let flag = words.first, flag.text.hasPrefix("-"), flag.text != "-" { words = words.dropFirst() }
            }
            // `then cd x`, `{ cd x; }`, `do cd x`: the cd may or may not happen, so the folder is unknown from here.
            if let first = words.first, keywords.contains(first.text) {
                if let verb = words.drop(while: { keywords.contains($0.text) }).first?.text, ["cd", "pushd", "popd"].contains(verb) { cwd = nil }
                continue
            }
            guard let first = words.first else { continue }
            if first.dynamic { continue } // The program itself is not known: never guess.
            let verb = (first.text as NSString).lastPathComponent
            let args = Array(words.dropFirst())
            if detachers.contains(verb) { background = true; continue }
            if verb == "cd" || verb == "pushd" || verb == "popd" {
                // Followed only when certain: never through popd, `cd -`, a pushd rotation, a variable or glob, or a
                // cd inside ( ) whose effect ends with the subshell. Unknown = nothing claimed through cwd.
                let operands = args.filter { !$0.text.hasPrefix("-") || $0.text == "-" }
                if verb == "popd" || chunk.grouped { cwd = nil; continue }
                if let target = operands.first {
                    let unsure = target.text == "-" || target.text.hasPrefix("+") || target.glob || target.dynamic
                    cwd = unsure ? nil : resolve(target.text, cwd: cwd, home: home)
                } else {
                    cwd = verb == "cd" ? normalize(home) : nil   // a bare pushd swaps with the stack
                }
                continue
            }
            if ["bash", "sh", "zsh", "dash"].contains(verb), depth < 3,
               let flag = args.firstIndex(where: { $0.text.hasPrefix("-") && !$0.text.hasPrefix("--") && $0.text.contains("c") }),
               flag + 1 < args.count, !args[flag + 1].dynamic {
                let inner = shellCovers(args[flag + 1].text, cwd: cwd, home: home, depth: depth + 1)
                covers += inner.covers
                uncertain = uncertain || inner.uncertain
                if (inner.background || detached) && (!inner.covers.isEmpty || inner.uncertain) { background = true }
                continue
            }
            // Keys travel (review N1): an AI's own `claude mcp remove <name>` (user scope, or no scope given) names that
            // one MCP server, as a stand-in path. Only this exact command counts; Claude Code's own writes to its
            // settings file never do.
            if verb == "claude", let name = mcpRemoved(args) {
                covers.append(.init(kind: .path, value: mcpUserServerPath(name), subtree: false))
                if detached { background = true }
                continue
            }
            // Scripts and inline code can remove arbitrary paths, including outside cwd. Keep only uncertainty.
            if Self.script(verb: verb) || shells.contains(verb) ||
                (verb == "swift" && args.first(where: { !$0.text.hasPrefix("-") })?.text.hasSuffix(".swift") == true) ||
                (!removers.contains(verb) && !cleaners.contains(verb) && !["git", "mv", "find", "rsync", "xargs", "npx", "pnpx", "bunx"].contains(verb) && first.text.contains("/")) {
                uncertain = true
                if detached { background = true }
                continue
            }
            let found = classify(verb: verb, args: args, cwd: cwd, home: home, depth: depth)
            if !found.isEmpty {
                covers += found
                if detached { background = true }
            }
        }
        var unique: [Cover] = []
        for cover in covers where !unique.contains(cover) { unique.append(cover) }
        return (unique, background, uncertain)
    }

    /// The covers one simple command creates; empty when it does not remove anything.
    static func classify(verb: String, args: [Word], cwd: String?, home: String, depth: Int, allowFallback: Bool = true) -> [Cover] {
        func nonFlags(_ words: [Word]) -> [Word] {
            var out: [Word] = [], ended = false
            for word in words {
                if !ended, word.text == "--", !word.dynamic { ended = true; continue }
                if !ended, word.text.hasPrefix("-"), word.text.count > 1 { continue }
                out.append(word)
            }
            return out
        }
        func wide(_ at: String?) -> [Cover] { at.map { [Cover(kind: .folder, value: $0, subtree: true)] } ?? [] }
        /// Only plain shell removals may use cwd when the targets cannot be read. Wrappers like xargs cannot.
        func targets(_ operands: [Word], subtree: Bool, at: String?, fallback: Bool = false) -> [Cover] {
            var out: [Cover] = []
            for word in operands {
                if word.dynamic { return out + (fallback && allowFallback ? wide(at) : []) }
                guard let cover = cover(word, cwd: at, home: home, subtree: subtree) else { return out + (fallback && allowFallback ? wide(at) : []) }
                out.append(cover)
            }
            return out
        }
        let flags = args.filter { $0.text.hasPrefix("-") && !$0.text.hasPrefix("--") }.map(\.text)
        let recursive = flags.contains { $0.contains("r") || $0.contains("R") } || args.contains { $0.text == "--recursive" }
        switch verb {
        case _ where removers.contains(verb):
            // rmdir removes only an empty folder: the folder itself, never what was inside it.
            let subtree = !flatRemovers.contains(verb) && verb != "rmdir" && (verb != "rm" || recursive)
            let found = targets(nonFlags(args), subtree: subtree, at: cwd, fallback: folderFallback.contains(verb))
            // rmdir never removes a file: a wildcard pattern (notes/*, */) would match files, so keep written-out paths only.
            return verb == "rmdir" ? found.filter { $0.kind == .path } : found
        case "mv":
            let operands = nonFlags(args)
            if args.contains(where: { $0.text == "-t" || $0.text.hasPrefix("--target-directory") }) {
                return targets(Array(operands.dropFirst()), subtree: true, at: cwd, fallback: true)
            }
            guard operands.count >= 2 else { return [] }
            return targets(Array(operands.dropLast()), subtree: true, at: cwd, fallback: true)
        case "xargs":
            var rest = args[...]
            while let word = rest.first, word.text.hasPrefix("-") {
                rest = rest.dropFirst()
                if ["-n", "-I", "-L", "-P", "-d", "-E", "-s", "-J"].contains(word.text) { rest = rest.dropFirst() }
            }
            guard let inner = rest.first, !inner.dynamic else { return [] }
            // Fixed targets can be read; the unknown targets on stdin cannot justify a cwd fallback.
            return classify(verb: (inner.text as NSString).lastPathComponent, args: Array(rest.dropFirst()), cwd: cwd, home: home, depth: depth, allowFallback: false)
        case "npx", "pnpx", "bunx":
            guard let inner = args.first(where: { !$0.text.hasPrefix("-") }), let at = args.firstIndex(of: inner), !inner.dynamic else { return [] }
            return classify(verb: (inner.text as NSString).lastPathComponent, args: Array(args[(at + 1)...]), cwd: cwd, home: home, depth: depth, allowFallback: false)
        case "find":
            let texts = args.map(\.text)
            let removing = texts.contains("-delete") || texts.indices.contains { index in
                ["-exec", "-execdir", "-ok", "-okdir"].contains(texts[index]) && index + 1 < texts.count
                    && (removers.contains((texts[index + 1] as NSString).lastPathComponent) || (texts[index + 1] as NSString).lastPathComponent == "mv")
            }
            guard removing else { return [] }
            let starts = Array(args.prefix { !$0.text.hasPrefix("-") && $0.text != "(" && $0.text != "!" })
            let fallback = texts.contains("-delete")
            if fallback, let found = findName(args) {
                // Only entries named like the pattern count (the start folders as written, or cwd when hidden).
                func named(_ covers: [Cover]) -> [Cover] { covers.map { var c = $0; c.subtree = true; c.name = found.name; c.caseless = found.caseless ? true : nil; return c } }
                if starts.isEmpty { return named(allowFallback ? wide(cwd) : []) }
                return named(targets(starts, subtree: true, at: cwd, fallback: true))
            }
            return starts.isEmpty ? (fallback && allowFallback ? wide(cwd) : []) : targets(starts, subtree: true, at: cwd, fallback: fallback)
        case "rsync":
            let texts = args.map(\.text)
            let deleting = texts.contains { $0.hasPrefix("--delete") }, moving = texts.contains("--remove-source-files")
            guard deleting || moving else { return [] }
            let operands = nonFlags(args)
            guard let destination = operands.last, !destination.text.contains(":") else { return [] }
            var out: [Cover] = []
            if deleting { out += targets([destination], subtree: true, at: cwd) }
            if moving { out += targets(Array(operands.dropLast()), subtree: true, at: cwd) }
            return out
        case "git":
            // Git owns its side effects, including instruction files removed by a branch switch or clean.
            return []
        case _ where cleaners.contains(verb):
            return []
        default:
            return []
        }
    }

    /// The `-name`/`-iname` pattern of a find expression that is a plain AND of tests. nil (folder rule, J-2)
    /// when there is none, it is hidden ($VAR), or -o / ! / -not / , could widen what is removed.
    static func findName(_ args: [Word]) -> (name: String, caseless: Bool)? {
        let texts = args.map(\.text)
        guard !texts.contains(where: { ["-o", "-or", "!", "-not", ",", "-prune"].contains($0) }) else { return nil }
        guard let index = texts.firstIndex(where: { $0 == "-name" || $0 == "-iname" }), index + 1 < args.count,
              !args[index + 1].dynamic, !args[index + 1].text.isEmpty, !args[index + 1].text.contains("/") else { return nil }
        return (args[index + 1].text, texts[index] == "-iname")
    }

    static func cover(_ word: Word, cwd: String?, home: String, subtree: Bool) -> Cover? {
        guard !word.dynamic else { return nil }
        if !word.glob {
            guard let resolved = resolve(word.text, cwd: cwd, home: home) else { return nil }
            return Cover(kind: .path, value: resolved, subtree: subtree)
        }
        // A glob: the literal folder in front of it is escaped into the pattern, so a `[` in his folder names
        // stays literal.
        var pattern = word.pattern
        if pattern.hasPrefix("~/") { pattern = escape(normalize(home)) + String(pattern.dropFirst()) }
        else if !pattern.hasPrefix("/") { guard let cwd else { return nil }; pattern = escape(cwd) + "/" + pattern }
        while pattern.hasSuffix("/") && pattern.count > 1 { pattern.removeLast() }
        return Cover(kind: .pattern, value: pattern, subtree: subtree)
    }

    // MARK: Linking

    /// 3 = names the path; 2 = names a folder above it and removes recursively; 1 = ran in a folder above it
    /// with targets the text does not show; 0 = no link.
    static func strength(_ cover: Cover, _ path: String) -> Int {
        if let name = cover.name {
            // find -name: the entry's own name must match; then the start folder link decides (never above 2).
            guard fnmatch(name, (path as NSString).lastPathComponent, cover.caseless == true ? FNM_CASEFOLD : 0) == 0 else { return 0 }
            var plain = cover; plain.name = nil; plain.caseless = nil
            return min(strength(plain, path), 2)
        }
        switch cover.kind {
        case .path:
            if path == cover.value { return 3 }
            return cover.subtree && within(path, cover.value) ? 2 : 0
        case .pattern:
            if matches(cover.value, path) { return 3 }
            guard cover.subtree else { return 0 }
            var ancestor = (path as NSString).deletingLastPathComponent
            while ancestor.count > 1 {
                if matches(cover.value, ancestor) { return 2 }
                ancestor = (ancestor as NSString).deletingLastPathComponent
            }
            return 0
        case .folder:
            return path == cover.value || within(path, cover.value) ? 1 : 0
        }
    }

    static func within(_ path: String, _ folder: String) -> Bool {
        folder == "/" ? path.hasPrefix("/") && path != "/" : path.hasPrefix(folder + "/")
    }

    static func matches(_ pattern: String, _ path: String) -> Bool {
        fnmatch(pattern, path, FNM_PATHNAME) == 0
    }

    static func escape(_ literal: String) -> String {
        var out = ""
        for ch in literal { if "*?[]\\".contains(ch) { out.append("\\") }; out.append(ch) }
        return out
    }

    // MARK: Paths

    static func expand(_ path: String, home: String) -> String {
        if path == "~" { return home }
        if path.hasPrefix("~/") { return home + String(path.dropFirst()) }
        return path
    }

    static func resolve(_ raw: String, cwd: String?, home: String) -> String? {
        let text = expand(raw, home: home)
        if text.hasPrefix("~") { return nil } // ~otheruser
        if text.hasPrefix("/") { return normalize(text) }
        guard let cwd, cwd.hasPrefix("/") else { return nil }
        return normalize(cwd + "/" + text)
    }

    /// Absolute, `.`/`..` folded, no trailing slash, and the `/private` twins of /tmp, /var and /etc folded so
    /// a command's path and an engine's path compare equal.
    public static func normalize(_ path: String) -> String {
        guard path.hasPrefix("/") else { return path }
        var parts: [Substring] = []
        for part in path.split(separator: "/", omittingEmptySubsequences: true) {
            if part == "." { continue }
            if part == ".." { if !parts.isEmpty { parts.removeLast() }; continue }
            parts.append(part)
        }
        var out = "/" + parts.joined(separator: "/")
        for twin in ["/private/tmp", "/private/var", "/private/etc"] where out == twin || out.hasPrefix(twin + "/") {
            out = String(out.dropFirst("/private".count))
        }
        return out
    }

    /// FNV-1a: pairs a start with its end without keeping the command text.
    static func hash(_ text: String) -> String {
        var value: UInt64 = 0xcbf29ce484222325
        for byte in text.utf8 { value ^= UInt64(byte); value = value &* 0x100000001b3 }
        return String(value, radix: 16)
    }
}

private extension String {
    func dropPrefix(_ prefix: String) -> String? { hasPrefix(prefix) ? String(dropFirst(prefix.count)) : nil }
}
