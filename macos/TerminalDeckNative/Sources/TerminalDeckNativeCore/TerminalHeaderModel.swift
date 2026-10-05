import Foundation

// The slim header above a native session terminal: what the web pane's header
// (`PaneBar` → StatusDot, SessionTitle, FolderTitle, AccountChip, SessionControls)
// says that matters, decoded from what the engine answers.

/// One session as `session:list` answers it (`SessionMeta`), as much as the header reads.
public struct TerminalSessionInfo: Equatable, Sendable {
    public let id: String
    public let cwd: String
    public let title: String
    public let provider: String
    public let exitCode: Int?
    public let profileName: String?

    public init(id: String, cwd: String, title: String, provider: String, exitCode: Int?, profileName: String?) {
        self.id = id
        self.cwd = cwd
        self.title = title
        self.provider = provider
        self.exitCode = exitCode
        self.profileName = profileName
    }

    /// One `SessionMeta`. Nil without an id; everything else is forgiving.
    public static func decode(_ raw: Any?) -> TerminalSessionInfo? {
        guard let record = raw as? [String: Any], let id = TerminalJSON.text(record["id"]) else { return nil }
        return TerminalSessionInfo(
            id: id,
            cwd: record["cwd"] as? String ?? "",
            title: record["title"] as? String ?? "",
            provider: TerminalJSON.text(record["provider"]) ?? "shell",
            exitCode: TerminalJSON.int(record["exitCode"]),
            profileName: (record["profileName"] as? String).flatMap { $0.terminalTrimmed.isEmpty ? nil : $0.terminalTrimmed })
    }

    /// This session out of a whole `session:list` answer.
    public static func find(_ id: String, in list: Any?) -> TerminalSessionInfo? {
        (list as? [Any] ?? []).lazy.compactMap(decode).first { $0.id == id }
    }

    /// The folder's own name, as the header shows it (the whole path is the tooltip).
    public var folderName: String {
        let path = TerminalText.normalisePath(cwd)
        guard !path.isEmpty else { return "" }
        let last = path.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last.map(String.init)
        return last ?? path
    }

    public var agentName: String { TerminalAgent.name(provider) }
}

public enum TerminalAgent {
    /// The agent's name as the app labels it (`agent-catalog.ts`).
    public static func name(_ provider: String) -> String {
        switch provider {
        case "claude": return "Claude Code"
        case "codex": return "Codex CLI"
        case "gemini": return "Gemini CLI"
        case "shell", "": return "Shell"
        default:
            guard provider.hasPrefix("custom:") else { return provider }
            let slug = provider.dropFirst("custom:".count)
            let words = slug.split(whereSeparator: { $0 == "-" || $0 == "_" }).map { $0.prefix(1).uppercased() + $0.dropFirst() }
            return words.isEmpty ? "Custom agent" : words.joined(separator: " ")
        }
    }
}

/// A session's live state (`SessionStatus`), and the word the dot means (`StatusDot`).
public enum TerminalStatus: String, Equatable, Sendable {
    case idle, working, waiting, input, completed, exited

    public static func parse(_ raw: Any?) -> TerminalStatus? {
        (raw as? String).flatMap(TerminalStatus.init(rawValue:))
    }

    public var label: String {
        switch self {
        case .idle, .waiting: return "Ready"
        case .working: return "Working"
        case .input: return "Needs input"
        case .completed: return "Completed"
        case .exited: return "Exited"
        }
    }
}

/// What the header draws, from the session record, the rail's own label and the live status.
public struct TerminalHeader: Equatable, Sendable {
    public let title: String
    public let folder: String
    public let folderPath: String
    public let agent: String
    public let account: String?
    public let status: TerminalStatus

    /// The rail's label wins ("Session 2"), because the header and the row are one
    /// session under one name; then the session's own title; then the folder.
    public static func make(info: TerminalSessionInfo?, railTitle: String?, status: TerminalStatus?, ended: Bool) -> TerminalHeader {
        let rail = railTitle?.terminalTrimmed ?? ""
        let own = info?.title.terminalTrimmed ?? ""
        let folder = info?.folderName ?? ""
        let title = !rail.isEmpty ? rail : !own.isEmpty ? own : !folder.isEmpty ? folder : "Session"
        return TerminalHeader(
            title: title,
            folder: folder,
            folderPath: info?.cwd ?? "",
            agent: info?.agentName ?? "",
            account: info?.profileName,
            status: ended ? .exited : (status ?? .idle))
    }
}

// MARK: - Model and effort (agent:controls:read / agent:controls:apply)

/// One control's reading (`ControlReading`).
public struct TerminalControlReading: Equatable, Sendable {
    public let value: String?
    public let label: String?
    public let unavailableReason: String?

    public init(value: String?, label: String?, unavailableReason: String? = nil) {
        self.value = value
        self.label = label
        self.unavailableReason = unavailableReason
    }

    public static let unread = TerminalControlReading(value: nil, label: nil)

    static func decode(_ raw: Any?) -> TerminalControlReading {
        guard let record = raw as? [String: Any] else { return .unread }
        return TerminalControlReading(value: record["value"] as? String, label: record["label"] as? String,
                                      unavailableReason: record["unavailableReason"] as? String)
    }
}

/// What `agent:controls:read` answers (`SessionReadings`), as much as the header uses.
public struct TerminalControls: Equatable, Sendable {
    public let model: TerminalControlReading
    public let effort: TerminalControlReading
    public let live: Bool
    /// An agent CLI is in the foreground of the session (`agent.running`).
    public let agentRunning: Bool
    public let canType: Bool
    public let gateReason: String?

    public init(model: TerminalControlReading, effort: TerminalControlReading, live: Bool, agentRunning: Bool,
                canType: Bool, gateReason: String?) {
        self.model = model
        self.effort = effort
        self.live = live
        self.agentRunning = agentRunning
        self.canType = canType
        self.gateReason = gateReason
    }

    public static func decode(_ raw: Any?) -> TerminalControls? {
        guard let record = raw as? [String: Any] else { return nil }
        let gate = record["gate"] as? [String: Any]
        let agent = record["agent"] as? [String: Any]
        return TerminalControls(
            model: .decode(record["model"]),
            effort: .decode(record["effort"]),
            live: TerminalJSON.bool(record["live"]) == true,
            agentRunning: TerminalJSON.bool(agent?["running"]) == true,
            canType: TerminalJSON.bool(gate?["canType"]) == true,
            gateReason: gate?["reason"] as? String)
    }

    /// Whether the header offers model and effort at all: an agent is running in
    /// the session, or it was started as Claude Code. A plain shell gets neither,
    /// as `SessionControls` draws nothing for `running === 'shell'`.
    public func shown(provider: String?) -> Bool {
        agentRunning || provider == "claude"
    }

    /// Why a control cannot be changed right now, or nil when it can (`blockedFor`).
    public func blocked(_ reading: TerminalControlReading) -> String? {
        if let reason = reading.unavailableReason, !reason.isEmpty { return reason }
        if !canType { return gateReason ?? "This session cannot be typed into right now, so nothing was sent." }
        return nil
    }
}

/// What `agent:controls:apply` answers.
public struct TerminalControlResult: Equatable, Sendable {
    public let ok: Bool
    public let message: String
    public let reading: TerminalControlReading

    public static func decode(_ raw: Any?) -> TerminalControlResult {
        guard let record = raw as? [String: Any] else {
            return TerminalControlResult(ok: false, message: "No answer from the session.", reading: .unread)
        }
        return TerminalControlResult(ok: TerminalJSON.bool(record["ok"]) == true,
                                     message: record["message"] as? String ?? "",
                                     reading: .decode(record["reading"]))
    }
}

/// One row of a control's menu (`ControlOption`).
public struct TerminalControlOption: Equatable, Sendable, Identifiable {
    public let id: String
    public let label: String
    public let hint: String?

    public init(id: String, label: String, hint: String? = nil) {
        self.id = id
        self.label = label
        self.hint = hint
    }
}

/// The rows the web header offers before a session has been asked for its own list
/// (`EFFORT_OPTIONS`, `modelOptions(FALLBACK_MODELS)`, `previousModelOptions`).
public enum TerminalControlCatalog {
    public static let effort: [TerminalControlOption] = [
        .init(id: "xhigh", label: "Extra high", hint: "the default here"),
        .init(id: "ultracode", label: "Ultracode", hint: "this session only"),
        .init(id: "max", label: "Max"),
        .init(id: "high", label: "High"),
        .init(id: "medium", label: "Medium"),
        .init(id: "low", label: "Low"),
        .init(id: "auto", label: "Auto"),
    ]

    public static let models: [TerminalControlOption] = [
        .init(id: "opus[1m]", label: "Opus 5 with 1M context", hint: "your account’s default"),
        .init(id: "opus", label: "Opus 5"),
        .init(id: "fable", label: "Fable 5"),
        .init(id: "sonnet", label: "Sonnet 5"),
        .init(id: "haiku", label: "Haiku 4.5"),
        .init(id: "opusplan", label: "Opus in plan mode, else Sonnet"),
    ]

    public static let earlierModels: [TerminalControlOption] = [
        .init(id: "claude-opus-4-8", label: "Opus 4.8"),
        .init(id: "claude-opus-4-5", label: "Opus 4.5"),
        .init(id: "claude-sonnet-4-6", label: "Sonnet 4.6"),
    ]

    /// `displayValue`: the reading's own label, or the word for a read that failed.
    public static func shown(_ reading: TerminalControlReading?, model: Bool) -> String {
        guard let label = reading?.label, !label.terminalTrimmed.isEmpty else { return "Unknown" }
        return model ? shortModelLabel(label) : label
    }

    /// `shortModelLabel`: "Opus 5 with 1M context" → "Opus 5 1M", "Opus in plan mode, else Sonnet" → "Opus Plan".
    public static func shortModelLabel(_ label: String) -> String {
        let text = label.terminalTrimmed
        if let match = text.range(of: #"^(\S+) in plan mode"#, options: [.regularExpression, .caseInsensitive]) {
            let first = text[match].split(separator: " ").first.map(String.init) ?? ""
            return "\(first) Plan"
        }
        let long = text.range(of: "1m", options: .caseInsensitive) != nil
        var name = text
        for pattern in [#"\((?:default|recommended)\)"#, #"\(1m context\)|with 1m context|·\s*1m"#] {
            name = name.replacingOccurrences(of: pattern, with: "", options: [.regularExpression, .caseInsensitive])
        }
        name = name.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression).terminalTrimmed
        return long ? "\(name) 1M" : name
    }

    /// `isCurrent`: the row the reading is on — by id, or by the same model and context window.
    public static func isCurrent(_ reading: TerminalControlReading?, _ option: TerminalControlOption) -> Bool {
        guard let reading, let value = reading.value else { return false }
        if value == option.id { return true }
        guard let shown = reading.label, !shown.terminalTrimmed.isEmpty else { return false }
        let read = modelKey(shown)
        let offered = modelKey(option.label)
        return !read.name.isEmpty && read == offered
    }

    static func modelKey(_ text: String) -> ModelKey {
        let lower = text.lowercased()
        let long = lower.contains("1m")
        var name = lower
        for pattern in [#"\((?:default|recommended)\)"#, #"\(1m context\)|with 1m context|·\s*1m"#] {
            name = name.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
        }
        name = name.replacingOccurrences(of: #"[^a-z0-9. ]+"#, with: " ", options: .regularExpression)
        name = name.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression).terminalTrimmed
        return ModelKey(name: name, long: long)
    }

    struct ModelKey: Equatable {
        let name: String
        let long: Bool
    }
}

fileprivate extension String {
    var terminalTrimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
