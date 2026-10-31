import Foundation

// AGT: every AI agent running on this Mac, in any app. Pure detection over a
// process snapshot and a few small files, so it is testable with fixture trees.
// The backend gathers the snapshot read-only (libproc); nothing here controls,
// types into or signals another app's process.

/// One process as the scanner saw it.
public struct AGTProcess: Equatable, Sendable {
    public var pid: Int32, ppid: Int32
    /// Short name (comm), e.g. "claude", "node", "zsh".
    public var name: String
    /// Executable path, when readable.
    public var path: String
    /// Arguments (argv), only gathered for agent candidates and their wrappers.
    public var args: [String]
    public var cwd: String?
    /// Seconds since 1970.
    public var startedAt: Double
    /// Total CPU seconds used so far.
    public var cpuSeconds: Double?
    /// Open files worth knowing (Codex holds its conversation files open).
    public var openFiles: [String]
    public init(pid: Int32, ppid: Int32, name: String, path: String = "", args: [String] = [], cwd: String? = nil,
                startedAt: Double = 0, cpuSeconds: Double? = nil, openFiles: [String] = []) {
        self.pid = pid; self.ppid = ppid; self.name = name; self.path = path; self.args = args; self.cwd = cwd
        self.startedAt = startedAt; self.cpuSeconds = cpuSeconds; self.openFiles = openFiles
    }
}

/// The app an agent runs in.
public struct AGTHostApp: Equatable, Sendable {
    public var name: String
    /// The outermost .app bundle, for its icon; nil for a process with no app (ssh, tmux, launchd).
    public var bundlePath: String?
    /// The app's own process, to bring it forward.
    public var pid: Int32?
    public var isTerminalDeck: Bool
    public init(name: String, bundlePath: String? = nil, pid: Int32? = nil, isTerminalDeck: Bool = false) {
        self.name = name; self.bundlePath = bundlePath; self.pid = pid; self.isTerminalDeck = isTerminalDeck
    }
}

/// Claude Code's own record of a running session (~/.claude/sessions/<pid>.json).
public struct AGTClaudeSessionFile: Equatable, Sendable {
    public var sessionID: String, cwd: String?, status: String?, name: String?, entrypoint: String?
    /// Seconds since 1970, to refuse a stale file left by an earlier process with the same pid.
    public var processStart: Double?
    public init(sessionID: String, cwd: String? = nil, status: String? = nil, name: String? = nil, entrypoint: String? = nil, processStart: Double? = nil) {
        self.sessionID = sessionID; self.cwd = cwd; self.status = status; self.name = name; self.entrypoint = entrypoint; self.processStart = processStart
    }
    public static func parse(_ data: Data) -> AGTClaudeSessionFile? {
        guard let value = try? NativeRPCValue.parseJSON(data, maximumBytes: 64 * 1024), let id = value["sessionId"].string else { return nil }
        var start: Double?
        if let raw = value["procStart"].string {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "EEE MMM d HH:mm:ss yyyy"
            start = formatter.date(from: raw.split(separator: " ", omittingEmptySubsequences: true).joined(separator: " "))?.timeIntervalSince1970
        }
        return .init(sessionID: id, cwd: value["cwd"].string, status: value["status"].string, name: value["name"].string,
                     entrypoint: value["entrypoint"].string, processStart: start)
    }
}

/// What the end of a conversation file says: the last message, the model, and whether a tool is waiting.
public struct AGTTranscriptTail: Equatable, Sendable {
    public var lastLine: String?
    public var lastSpeaker: String?
    public var lastAt: Double?
    public var model: String?
    /// A tool call with no result yet (often a permission question).
    public var pendingTool: Bool
    public var sessionID: String?
    public var cwd: String?
    public init(lastLine: String? = nil, lastSpeaker: String? = nil, lastAt: Double? = nil, model: String? = nil,
                pendingTool: Bool = false, sessionID: String? = nil, cwd: String? = nil) {
        self.lastLine = lastLine; self.lastSpeaker = lastSpeaker; self.lastAt = lastAt; self.model = model
        self.pendingTool = pendingTool; self.sessionID = sessionID; self.cwd = cwd
    }

    public static func oneLine(_ text: String) -> String? {
        let line = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty }
        return line.map { $0.count > 200 ? String($0.prefix(199)) + "…" : $0 }
    }
    public static func time(_ value: NativeRPCValue) -> Double? {
        guard let raw = value.string else { return value.number }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: raw) { return date.timeIntervalSince1970 * 1000 }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: raw).map { $0.timeIntervalSince1970 * 1000 }
    }

    /// Claude Code's .jsonl: the last user or assistant text, the model, an open tool call.
    public static func claude(_ lines: [Substring]) -> AGTTranscriptTail {
        var tail = AGTTranscriptTail(), open = Set<String>()
        for line in lines {
            guard let raw = try? NativeRPCValue.parseJSON(Data(line.utf8), maximumBytes: 2 * 1024 * 1024) else { continue }
            if tail.sessionID == nil { tail.sessionID = raw["sessionId"].string }
            if let cwd = raw["cwd"].string { tail.cwd = cwd }
            guard ["user", "assistant"].contains(raw["type"].string), raw["isSidechain"].bool != true, raw["isMeta"].bool != true else { continue }
            if let model = raw["message"]["model"].string, model != "<synthetic>" { tail.model = model }
            let content = raw["message"]["content"]
            var text = content.string
            for block in content.elements ?? [] {
                switch block["type"].string {
                case "text": if let value = block["text"].string, !value.isEmpty { text = value }
                case "tool_use": if let id = block["id"].string { open.insert(id) }
                case "tool_result": if let id = block["tool_use_id"].string { open.remove(id) }
                default: break
                }
            }
            if let text, let line = oneLine(text), !line.hasPrefix("<") {
                tail.lastLine = line
                tail.lastSpeaker = raw["type"].string == "user" ? "You" : "Agent"
                tail.lastAt = time(raw["timestamp"])
            }
        }
        tail.pendingTool = !open.isEmpty
        return tail
    }

    /// Codex's rollout .jsonl: session meta, turn model, last message, open function call.
    public static func codex(_ lines: [Substring]) -> AGTTranscriptTail {
        var tail = AGTTranscriptTail(), open = Set<String>()
        for line in lines {
            guard let raw = try? NativeRPCValue.parseJSON(Data(line.utf8), maximumBytes: 2 * 1024 * 1024) else { continue }
            let payload = raw["payload"]
            switch raw["type"].string {
            case "session_meta":
                tail.sessionID = payload["id"].string ?? tail.sessionID
                tail.cwd = payload["cwd"].string ?? tail.cwd
            case "turn_context":
                if let model = payload["model"].string { tail.model = model }
                if let cwd = payload["cwd"].string { tail.cwd = cwd }
            case "response_item":
                switch payload["type"].string {
                case "message":
                    let role = payload["role"].string
                    guard role == "user" || role == "assistant" else { continue }
                    let text = (payload["content"].elements ?? []).compactMap { $0["text"].string }.last
                    if let text, let line = oneLine(text), !line.hasPrefix("<") {
                        tail.lastLine = line; tail.lastSpeaker = role == "user" ? "You" : "Agent"; tail.lastAt = time(raw["timestamp"])
                    }
                case "function_call", "custom_tool_call", "local_shell_call":
                    if let id = payload["call_id"].string { open.insert(id) }
                case "function_call_output", "custom_tool_call_output":
                    if let id = payload["call_id"].string { open.remove(id) }
                default: break
                }
            default: break
            }
        }
        tail.pendingTool = !open.isEmpty
        return tail
    }
}

/// One agent running somewhere on this Mac.
public struct AGTDeviceAgent: Identifiable, Equatable, Sendable {
    public var id: String
    public var pid: Int32
    /// claude, codex or gemini.
    public var ai: String
    public var app: AGTHostApp
    public var model: String?
    public var project: String
    public var sessionID: String?
    public var title: String?
    public var transcriptPath: String?
    public var state: AWWatchState
    /// Seconds since 1970.
    public var startedAt: Double
    /// Percent of one core over the last interval; nil until measured twice.
    public var cpuPercent: Double?
    public var lastLine: String?
    public var lastAt: Double?
    /// The process that started it, when that is an agent too (e.g. Claude running Codex).
    public var startedBy: String?

    public init(id: String, pid: Int32, ai: String, app: AGTHostApp, model: String?, project: String, sessionID: String?, title: String?,
                transcriptPath: String?, state: AWWatchState, startedAt: Double, cpuPercent: Double?, lastLine: String?, lastAt: Double?,
                startedBy: String? = nil) {
        self.id = id; self.pid = pid; self.ai = ai; self.app = app; self.model = model; self.project = project; self.sessionID = sessionID
        self.title = title; self.transcriptPath = transcriptPath; self.state = state; self.startedAt = startedAt; self.cpuPercent = cpuPercent
        self.lastLine = lastLine; self.lastAt = lastAt; self.startedBy = startedBy
    }

    public var aiLabel: String { AGTDirectory.providerLabel(ai) }
    public var resumeCommand: String? {
        guard let sessionID else { return nil }
        let folder = project.isEmpty ? "" : "cd " + AGTDeviceDetect.shellQuote(project) + " && "
        switch ai {
        case "claude": return folder + "claude --resume " + sessionID
        case "codex": return folder + "codex resume " + sessionID
        default: return nil
        }
    }
    public var displayName: String {
        if let title, !title.isEmpty { return title }
        let folder = AGTDirectory.projectName(project)
        return folder.isEmpty ? aiLabel : "\(aiLabel) · \(folder)"
    }

    public func wireValue(includeText: Bool) -> NativeRPCValue {
        func text(_ value: String?) -> NativeRPCValue { value.map(NativeRPCValue.string) ?? .null }
        return .object([.init("id", .string(id)), .init("pid", .number(Double(pid))), .init("ai", .string(ai)), .init("aiLabel", .string(aiLabel)),
            .init("app", .string(app.name)), .init("appPath", text(app.bundlePath)), .init("appPid", app.pid.map { .number(Double($0)) } ?? .null),
            .init("source", .string(app.isTerminalDeck ? "terminal-deck" : "other")), .init("model", text(model)),
            .init("project", .string(project)), .init("sessionId", text(sessionID)), .init("title", text(title)), .init("name", .string(displayName)),
            .init("state", .string(state.rawValue)), .init("startedAt", .number(startedAt * 1000)),
            .init("cpuPercent", cpuPercent.map(NativeRPCValue.number) ?? .null),
            .init("lastLine", includeText ? text(lastLine) : .null), .init("lastAt", lastAt.map(NativeRPCValue.number) ?? .null),
            .init("resumeCommand", text(resumeCommand)), .init("startedBy", text(startedBy)),
            .init("readable", .bool(transcriptPath != nil))])
    }
    public static func decode(_ value: NativeRPCValue) -> AGTDeviceAgent? {
        guard let id = value["id"].string, let ai = value["ai"].string, let pid = value["pid"].number else { return nil }
        return AGTDeviceAgent(id: id, pid: Int32(pid), ai: ai,
            app: AGTHostApp(name: value["app"].string ?? "Unknown app", bundlePath: value["appPath"].string,
                            pid: value["appPid"].number.map { Int32($0) }, isTerminalDeck: value["source"].string == "terminal-deck"),
            model: value["model"].string, project: value["project"].string ?? "", sessionID: value["sessionId"].string,
            title: value["title"].string, transcriptPath: value["readable"].bool == true ? "" : nil,
            state: value["state"].string.flatMap(AWWatchState.init(rawValue:)) ?? .unknown,
            startedAt: (value["startedAt"].number ?? 0) / 1000, cpuPercent: value["cpuPercent"].number,
            lastLine: value["lastLine"].string, lastAt: value["lastAt"].number, startedBy: value["startedBy"].string)
    }
}

/// How agents are found in a process snapshot.
public enum AGTDeviceDetect {
    public enum Mode: Equatable, Sendable { case session, engine }
    public struct Candidate: Equatable, Sendable { public var process: AGTProcess; public var ai: String; public var mode: Mode }

    static func base(_ path: String) -> String { (path as NSString).lastPathComponent.lowercased() }
    /// claude.exe (Claude Code's npm-installed native binary) reads as claude.
    static func stem(_ path: String) -> String {
        let name = base(path)
        return name.hasSuffix(".exe") ? String(name.dropLast(4)) : name
    }

    /// claude / codex / gemini, directly or as a node script; engines and helpers sorted out.
    public static func classify(_ process: AGTProcess) -> Candidate? {
        let name = stem(process.path.isEmpty ? process.name : process.path)
        let first = process.args.first.map(stem) ?? ""
        var ai: String?
        var rest = Array(process.args.dropFirst())
        for word in ["claude", "codex", "gemini"] where name == word || first == word { ai = word }
        if ai == nil, ["node", "bun", "deno"].contains(name) || ["node", "bun", "deno"].contains(first) {
            // A JS launcher: the script decides (…/claude-code/cli.js, …/bin/codex.js, …/gemini-cli/…).
            let script = rest.first { !$0.hasPrefix("-") } ?? ""
            let lower = script.lowercased()
            if lower.contains("claude-code") || base(script) == "claude" { ai = "claude" }
            else if lower.contains("@openai/codex") || base(script) == "codex" || base(script) == "codex.js" { ai = "codex" }
            else if lower.contains("gemini-cli") || base(script) == "gemini" { ai = "gemini" }
            if ai != nil, let index = rest.firstIndex(of: script) { rest = Array(rest[(index + 1)...]) }
        }
        guard let ai else { return nil }
        let words = Set(rest)
        // Helpers that are not agents: MCP servers, cloud execution relays, sandbox hosts.
        if words.contains("mcp") && (words.contains("serve") || words.contains("mcp-server")) { return nil }
        if ai == "codex", words.contains("exec-server") || words.contains("mcp-server") || words.contains("proto") { return nil }
        if ai == "codex", words.contains("app-server") { return Candidate(process: process, ai: ai, mode: .engine) }
        return Candidate(process: process, ai: ai, mode: .session)
    }

    /// The app it runs in: the first ancestor inside an .app bundle (the outermost bundle names it),
    /// or Terminal Deck's own session host.
    public static func hostApp(of pid: Int32, in byPID: [Int32: AGTProcess]) -> AGTHostApp {
        var current = byPID[pid]?.ppid ?? 1, steps = 0, sawTmux = false
        while current > 1, let process = byPID[current], steps < 64 {
            steps += 1
            let path = process.path
            if path.contains("/terminaldeck/host/") || path.contains("Terminal Deck.app/") || base(path).hasPrefix("terminaldeck") {
                return AGTHostApp(name: "Terminal Deck", bundlePath: path.range(of: "Terminal Deck.app").map { String(path[..<$0.upperBound]) }, pid: process.pid, isTerminalDeck: true)
            }
            if let range = path.range(of: ".app/") {
                let bundle = String(path[..<range.lowerBound]) + ".app"
                let name = ((bundle as NSString).lastPathComponent as NSString).deletingPathExtension
                return AGTHostApp(name: friendly(name), bundlePath: bundle, pid: topProcess(of: bundle, from: process, in: byPID), isTerminalDeck: false)
            }
            if ["tmux", "screen", "zellij"].contains(base(process.name)) || ["tmux", "screen", "zellij"].contains(base(path)) { sawTmux = true }
            if ["sshd", "sshd-session"].contains(base(path)) || base(process.name) == "sshd" { return AGTHostApp(name: "SSH session") }
            current = process.ppid
        }
        return AGTHostApp(name: sawTmux ? "tmux" : "No app (background)")
    }

    /// The app's main process (the highest ancestor still inside the same bundle).
    static func topProcess(of bundle: String, from process: AGTProcess, in byPID: [Int32: AGTProcess]) -> Int32 {
        var best = process, steps = 0
        while let parent = byPID[best.ppid], parent.path.hasPrefix(bundle + "/"), steps < 32 { best = parent; steps += 1 }
        return best.pid
    }

    static func friendly(_ name: String) -> String {
        switch name {
        case "Code", "Visual Studio Code": "VS Code"
        case "iTerm": "iTerm2"
        default: name
        }
    }

    public static func shellQuote(_ text: String) -> String {
        text.range(of: #"^[A-Za-z0-9_./-]+$"#, options: .regularExpression) != nil ? text : "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Claude Code's project folder name for a working folder.
    public static func claudeProjectFolder(_ cwd: String) -> String {
        String(cwd.map { $0.isLetter && $0.isASCII || $0.isNumber && $0.isASCII ? $0 : "-" })
    }

    /// The session id given on the command line (--resume X, --session-id X, `codex resume X`).
    public static func sessionArgument(_ args: [String]) -> String? {
        for (index, word) in args.enumerated() {
            for flag in ["--resume", "-r", "--session-id", "--session"] {
                if word == flag, index + 1 < args.count, !args[index + 1].hasPrefix("-") { return args[index + 1] }
                if word.hasPrefix(flag + "=") { return String(word.dropFirst(flag.count + 1)) }
            }
            if word == "resume", index + 1 < args.count, !args[index + 1].hasPrefix("-") { return args[index + 1] }
        }
        return nil
    }

    static func modelArgument(_ args: [String]) -> String? {
        for (index, word) in args.enumerated() {
            if (word == "--model" || word == "-m"), index + 1 < args.count { return args[index + 1] }
            if word.hasPrefix("--model=") { return String(word.dropFirst(8)) }
        }
        return nil
    }

    /// Everything the files around an agent can tell, supplied by the caller (fixtures in tests).
    public struct Files: Sendable {
        public var claudeSession: @Sendable (Int32) -> AGTClaudeSessionFile?
        public var claudeTranscript: @Sendable (_ sessionID: String, _ cwd: String) -> String?
        public var tail: @Sendable (_ path: String, _ ai: String) -> (AGTTranscriptTail, modifiedAt: Double)?
        public init(claudeSession: @escaping @Sendable (Int32) -> AGTClaudeSessionFile?,
                    claudeTranscript: @escaping @Sendable (String, String) -> String?,
                    tail: @escaping @Sendable (String, String) -> (AGTTranscriptTail, modifiedAt: Double)?) {
            self.claudeSession = claudeSession; self.claudeTranscript = claudeTranscript; self.tail = tail
        }
    }

    /// Every agent in the snapshot. `cpu` maps pid to its CPU percent when measured.
    public static func agents(_ processes: [AGTProcess], files: Files, now: Double, cpu: [Int32: Double] = [:]) -> [AGTDeviceAgent] {
        let byPID = Dictionary(processes.map { ($0.pid, $0) }, uniquingKeysWith: { first, _ in first })
        var candidates = processes.compactMap(classify)
        // A launcher (node wrapper) whose child is the same agent is the same agent: keep the child.
        let parentsOfSame = Set(candidates.compactMap { child in
            candidates.contains { $0.process.pid == child.process.ppid && $0.ai == child.ai } ? child.process.ppid : nil
        })
        candidates.removeAll { parentsOfSame.contains($0.process.pid) }
        let candidatePIDs = Dictionary(candidates.map { ($0.process.pid, $0.ai) }, uniquingKeysWith: { first, _ in first })

        var found: [AGTDeviceAgent] = []
        for candidate in candidates {
            let process = candidate.process
            let app = hostApp(of: process.pid, in: byPID)
            var startedBy: String?
            var walker = process.ppid, steps = 0
            while walker > 1, steps < 32, let parent = byPID[walker] {
                if let ai = candidatePIDs[walker], ai != candidate.ai { startedBy = AGTDirectory.providerLabel(ai); break }
                walker = parent.ppid; steps += 1
            }
            let percent = cpu[process.pid]
            func state(tail: AGTTranscriptTail?, modified: Double?, status: String?) -> AWWatchState {
                switch status {
                case "busy": return .working
                case "idle": return tail?.pendingTool == true ? .waiting : .idle
                case .some(let other) where !other.isEmpty: return .waiting
                default: break
                }
                if let percent, percent >= 3 { return .working }
                if let modified, now - modified < 20 { return .working }
                if tail?.pendingTool == true { return .waiting }
                return .idle
            }
            switch candidate.ai {
            case "claude":
                let record = files.claudeSession(process.pid).flatMap { record -> AGTClaudeSessionFile? in
                    // A file from an earlier process that had the same pid is ignored.
                    if let start = record.processStart, process.startedAt > 0, abs(start - process.startedAt) > 5 { return nil }
                    return record
                }
                let cwd = record?.cwd ?? process.cwd ?? ""
                let session = record?.sessionID ?? sessionArgument(process.args)
                let path = session.flatMap { files.claudeTranscript($0, cwd) }
                let read = path.flatMap { files.tail($0, "claude") }
                found.append(AGTDeviceAgent(id: "claude:\(process.pid):\(session ?? "-")", pid: process.pid, ai: "claude", app: app,
                    model: read?.0.model ?? modelArgument(process.args), project: cwd, sessionID: session, title: record?.name,
                    transcriptPath: path, state: state(tail: read?.0, modified: read?.modifiedAt, status: record?.status),
                    startedAt: process.startedAt, cpuPercent: percent, lastLine: read?.0.lastLine, lastAt: read?.0.lastAt, startedBy: startedBy))
            case "codex":
                let rollouts = process.openFiles.filter { $0.contains("/.codex/sessions/") && ($0 as NSString).lastPathComponent.hasPrefix("rollout-") && $0.hasSuffix(".jsonl") }.sorted()
                if rollouts.isEmpty {
                    // An engine with no open conversation is not an agent at work.
                    guard candidate.mode == .session else { continue }
                    let session = sessionArgument(process.args)
                    found.append(AGTDeviceAgent(id: "codex:\(process.pid):\(session ?? "-")", pid: process.pid, ai: "codex", app: app,
                        model: modelArgument(process.args), project: process.cwd ?? "", sessionID: session, title: nil, transcriptPath: nil,
                        state: state(tail: nil, modified: nil, status: nil), startedAt: process.startedAt, cpuPercent: percent,
                        lastLine: nil, lastAt: nil, startedBy: startedBy))
                }
                for path in rollouts {
                    let read = files.tail(path, "codex")
                    let session = read?.0.sessionID ?? codexSessionID(fromFile: path)
                    found.append(AGTDeviceAgent(id: "codex:\(process.pid):\(session ?? path)", pid: process.pid, ai: "codex", app: app,
                        model: read?.0.model ?? modelArgument(process.args), project: read?.0.cwd ?? process.cwd ?? "", sessionID: session,
                        title: nil, transcriptPath: path, state: state(tail: read?.0, modified: read?.modifiedAt, status: nil),
                        startedAt: process.startedAt, cpuPercent: rollouts.count == 1 ? percent : nil, lastLine: read?.0.lastLine,
                        lastAt: read?.0.lastAt, startedBy: startedBy))
                }
            default:
                found.append(AGTDeviceAgent(id: "\(candidate.ai):\(process.pid)", pid: process.pid, ai: candidate.ai, app: app,
                    model: modelArgument(process.args), project: process.cwd ?? "", sessionID: sessionArgument(process.args), title: nil,
                    transcriptPath: nil, state: state(tail: nil, modified: nil, status: nil), startedAt: process.startedAt,
                    cpuPercent: percent, lastLine: nil, lastAt: nil, startedBy: startedBy))
            }
        }
        return found.sorted { a, b in
            func rank(_ s: AWWatchState) -> Int { switch s { case .working: 0; case .waiting: 1; case .queued: 2; case .idle: 3; default: 4 } }
            return rank(a.state) != rank(b.state) ? rank(a.state) < rank(b.state) : a.startedAt > b.startedAt
        }
    }

    /// rollout-2026-10-08T02-20-33-<uuid>.jsonl → the uuid.
    public static func codexSessionID(fromFile path: String) -> String? {
        let name = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        guard name.count > 36 else { return nil }
        let id = String(name.suffix(36))
        return id.range(of: #"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$"#, options: .regularExpression) != nil ? id : nil
    }
}
