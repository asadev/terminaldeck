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
    /// The account the session runs as (`profileId`), when the engine named one.
    public let profileId: String?
    /// Switched to another account without a restart (`homeProfileId` set).
    public let switchedInPlace: Bool
    /// Epoch milliseconds; with `resumed` and `agentSessionId`, what finds its transcript.
    public let createdAt: Double?
    public let resumed: Bool
    public let agentSessionId: String?

    public init(id: String, cwd: String, title: String, provider: String, exitCode: Int?, profileName: String?,
                profileId: String? = nil, switchedInPlace: Bool = false, createdAt: Double? = nil, resumed: Bool = false,
                agentSessionId: String? = nil) {
        self.id = id
        self.cwd = cwd
        self.title = title
        self.provider = provider
        self.exitCode = exitCode
        self.profileName = profileName
        self.profileId = profileId
        self.switchedInPlace = switchedInPlace
        self.createdAt = createdAt
        self.resumed = resumed
        self.agentSessionId = agentSessionId
    }

    /// The same session under another name.
    public func renamed(_ title: String) -> TerminalSessionInfo {
        TerminalSessionInfo(id: id, cwd: cwd, title: title, provider: provider, exitCode: exitCode, profileName: profileName,
                            profileId: profileId, switchedInPlace: switchedInPlace, createdAt: createdAt, resumed: resumed,
                            agentSessionId: agentSessionId)
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
            profileName: (record["profileName"] as? String).flatMap { $0.terminalTrimmed.isEmpty ? nil : $0.terminalTrimmed },
            profileId: TerminalJSON.text(record["profileId"]),
            switchedInPlace: TerminalJSON.text(record["homeProfileId"]) != nil,
            createdAt: TerminalJSON.number(record["createdAt"]),
            resumed: TerminalJSON.bool(record["resumed"]) == true,
            agentSessionId: TerminalJSON.text(record["agentSessionId"]))
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

// MARK: - Model, effort and fast mode (agent:controls:read / agent:controls:apply)

/// One control's reading (`ControlReading`).
public struct TerminalControlReading: Equatable, Sendable {
    public let value: String?
    public let label: String?
    /// Where it was read: "screen", "transcript", "settings" or "env".
    public let source: String?
    public let unavailableReason: String?

    public init(value: String?, label: String?, source: String? = nil, unavailableReason: String? = nil) {
        self.value = value
        self.label = label
        self.source = source
        self.unavailableReason = unavailableReason
    }

    public static let unread = TerminalControlReading(value: nil, label: nil)

    /// Nothing has been read: the chip says "Unknown".
    public var isUnread: Bool { label == nil }

    static func decode(_ raw: Any?) -> TerminalControlReading {
        guard let record = raw as? [String: Any] else { return .unread }
        let source = (record["source"] as? String).flatMap { ["screen", "transcript", "settings", "env"].contains($0) ? $0 : nil }
        return TerminalControlReading(value: record["value"] as? String, label: record["label"] as? String,
                                      source: source, unavailableReason: record["unavailableReason"] as? String)
    }
}

/// One MCP server, as `mcp:list` (or a paired machine's readings) lists it (`McpRow`).
public struct McpRow: Equatable, Sendable, Identifiable {
    public let id: String
    public let name: String
    public let scope: String?
    public let transport: String?
    public let enabled: Bool
    public let disabledReason: String?

    public init(id: String, name: String, scope: String? = nil, transport: String? = nil, enabled: Bool = true, disabledReason: String? = nil) {
        self.id = id
        self.name = name
        self.scope = scope
        self.transport = transport
        self.enabled = enabled
        self.disabledReason = disabledReason
    }

    /// `readServers`: nil when the answer is not a list at all.
    public static func list(_ raw: Any?) -> [McpRow]? {
        guard let entries = raw as? [Any] else { return nil }
        return entries.compactMap { entry in
            guard let server = entry as? [String: Any], let id = server["id"] as? String, let name = server["name"] as? String else { return nil }
            return McpRow(id: id, name: name, scope: server["scope"] as? String, transport: server["transport"] as? String,
                          enabled: TerminalJSON.bool(server["enabled"]) != false,
                          disabledReason: server["disabledReason"] as? String)
        }
    }

    /// `rowDetail`: the reason it is off, or what was read of it.
    public var detail: String {
        if let disabledReason, !disabledReason.isEmpty { return disabledReason }
        return [scope, transport].compactMap { $0 }.joined(separator: " · ")
    }
}

/// What `agent:controls:read` answers (`SessionReadings`).
public struct TerminalControls: Equatable, Sendable {
    public let model: TerminalControlReading
    public let effort: TerminalControlReading
    public let fast: TerminalControlReading
    public let permission: TerminalControlReading
    public let live: Bool
    /// An agent CLI is in the foreground of the session (`agent.running`); nil when not said.
    public let agentRunning: Bool
    public let agentSaid: Bool
    public let canType: Bool
    public let gateReason: String?
    /// A paired machine's own MCP list, carried on its readings; nil when it sent none.
    public let connectors: [McpRow]?

    public init(model: TerminalControlReading, effort: TerminalControlReading, fast: TerminalControlReading = .unread,
                permission: TerminalControlReading = .unread, live: Bool, agentRunning: Bool, agentSaid: Bool = true,
                canType: Bool, gateReason: String?, connectors: [McpRow]? = nil) {
        self.model = model
        self.effort = effort
        self.fast = fast
        self.permission = permission
        self.live = live
        self.agentRunning = agentRunning
        self.agentSaid = agentSaid
        self.canType = canType
        self.gateReason = gateReason
        self.connectors = connectors
    }

    public static func decode(_ raw: Any?) -> TerminalControls? {
        guard let record = raw as? [String: Any] else { return nil }
        let gate = record["gate"] as? [String: Any]
        let agent = record["agent"] as? [String: Any]
        let running = TerminalJSON.bool(agent?["running"])
        return TerminalControls(
            model: .decode(record["model"]),
            effort: .decode(record["effort"]),
            fast: .decode(record["fast"]),
            permission: .decode(record["permission"]),
            live: TerminalJSON.bool(record["live"]) == true,
            agentRunning: running == true,
            agentSaid: running != nil,
            canType: TerminalJSON.bool(gate?["canType"]) == true,
            gateReason: gate?["reason"] as? String,
            connectors: record["connectors"] == nil ? nil : McpRow.list(record["connectors"]))
    }

    public func reading(_ control: String) -> TerminalControlReading {
        switch control {
        case "model": return model
        case "effort": return effort
        case "fast": return fast
        default: return permission
        }
    }

    /// The same readings with one control's replaced — what an apply answers with.
    public func with(_ control: String, _ reading: TerminalControlReading) -> TerminalControls {
        TerminalControls(model: control == "model" ? reading : model, effort: control == "effort" ? reading : effort,
                         fast: control == "fast" ? reading : fast, permission: control == "permission" ? reading : permission,
                         live: live, agentRunning: agentRunning, agentSaid: agentSaid, canType: canType,
                         gateReason: gateReason, connectors: connectors)
    }

    /// Why a control cannot be changed right now, or nil when it can (`blockedFor`,
    /// after the wiring and foreign-agent checks).
    public func blocked(_ reading: TerminalControlReading) -> String? {
        if let reason = reading.unavailableReason, !reason.isEmpty { return reason }
        if !canType { return gateReason ?? "This session cannot be typed into right now, so nothing was sent." }
        return nil
    }

    /// Whether the header offers model and effort at all: an agent is running in
    /// the session, or it was started as Claude Code. A plain shell gets neither,
    /// as `SessionControls` draws nothing for `running === 'shell'`.
    public func shown(provider: String?) -> Bool {
        agentRunning || provider == "claude"
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
    /// A caption drawn above this row (`ControlOption.group`).
    public let group: String?

    public init(id: String, label: String, hint: String? = nil, group: String? = nil) {
        self.id = id
        self.label = label
        self.hint = hint
        self.group = group
    }
}

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
        .init(id: "claude-opus-4-8", label: "Opus 4.8", group: "Earlier models"),
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
