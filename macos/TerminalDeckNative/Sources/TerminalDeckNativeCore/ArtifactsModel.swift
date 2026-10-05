import Foundation

// The Artifacts page's data, as the engine answers `artifacts:list` and
// `artifacts:changes` (src/main/artifacts.ts) — the same shapes the web page
// mirrors in src/renderer/components/ArtifactsPanel.tsx. Decoding is forgiving:
// one malformed row is dropped, never the whole list.

/// Which transcripts a scan reads: this folder's own, or every session that wrote into it.
public enum ArtifactScope: String, Equatable, Sendable, CaseIterable {
    case project, all
}

/// Which half of the record the page shows: files an agent wrote whole, or ones it only edited.
public enum ArtifactScopeKind: String, Equatable, Sendable, CaseIterable {
    case made, changed
}

public struct ArtifactOnDisk: Equatable, Sendable {
    public let bytes: Int
    public let modifiedAt: Double
    public init(bytes: Int, modifiedAt: Double) {
        self.bytes = bytes
        self.modifiedAt = modifiedAt
    }
}

public struct Artifact: Equatable, Identifiable, Sendable, Decodable {
    /// Project-relative, forward slashes.
    public let relPath: String
    public let name: String
    /// Milliseconds since 1970, as the engine sends them.
    public let firstAt: Double
    public let lastAt: Double
    public let writes: Int
    public let edits: Int
    public let lastChars: Int
    public let lastTool: String
    public let sessionIds: [String]
    /// nil when the file is no longer on disk.
    public let onDisk: ArtifactOnDisk?

    public var id: String { relPath }

    public init(relPath: String, name: String? = nil, firstAt: Double = 0, lastAt: Double = 0,
                writes: Int = 0, edits: Int = 0, lastChars: Int = 0, lastTool: String = "",
                sessionIds: [String] = [], onDisk: ArtifactOnDisk? = nil) {
        self.relPath = relPath
        self.name = name.flatMap(\.nonEmpty) ?? ArtifactRules.lastComponent(relPath)
        self.firstAt = firstAt
        self.lastAt = lastAt
        self.writes = writes
        self.edits = edits
        self.lastChars = lastChars
        self.lastTool = lastTool
        self.sessionIds = sessionIds
        self.onDisk = onDisk
    }

    enum CodingKeys: String, CodingKey {
        case relPath, name, firstAt, lastAt, writes, edits, lastChars, lastTool, sessionIds, onDisk
    }
    enum DiskKeys: String, CodingKey { case bytes, modifiedAt }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard let relPath = c.lossyString(.relPath), !relPath.isEmpty else {
            throw DecodingError.dataCorruptedError(forKey: .relPath, in: c, debugDescription: "artifact without a path")
        }
        var onDisk: ArtifactOnDisk?
        if let disk = try? c.nestedContainer(keyedBy: DiskKeys.self, forKey: .onDisk),
           let bytes = disk.lossyNumber(.bytes) {
            onDisk = ArtifactOnDisk(bytes: Int(bytes), modifiedAt: disk.lossyNumber(.modifiedAt) ?? 0)
        }
        self.init(
            relPath: relPath,
            name: c.lossyString(.name),
            firstAt: c.lossyNumber(.firstAt) ?? 0,
            lastAt: c.lossyNumber(.lastAt) ?? 0,
            writes: Int(c.lossyNumber(.writes) ?? 0),
            edits: Int(c.lossyNumber(.edits) ?? 0),
            lastChars: Int(c.lossyNumber(.lastChars) ?? 0),
            lastTool: c.lossyString(.lastTool) ?? "",
            sessionIds: c.lossyStrings(.sessionIds),
            onDisk: onDisk)
    }
}

public struct ArtifactSession: Equatable, Identifiable, Sendable, Decodable {
    public let sessionId: String
    public let at: Double
    public let files: Int

    public var id: String { sessionId }

    public init(sessionId: String, at: Double, files: Int) {
        self.sessionId = sessionId
        self.at = at
        self.files = files
    }

    enum CodingKeys: String, CodingKey { case sessionId, at, files }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard let id = c.lossyString(.sessionId), !id.isEmpty else {
            throw DecodingError.dataCorruptedError(forKey: .sessionId, in: c, debugDescription: "session without id")
        }
        self.init(sessionId: id, at: c.lossyNumber(.at) ?? 0, files: Int(c.lossyNumber(.files) ?? 0))
    }
}

public struct ArtifactList: Equatable, Sendable, Decodable {
    public let root: String
    public let scope: ArtifactScope
    public var artifacts: [Artifact]
    public var sessions: [ArtifactSession]
    public let sessionsScanned: Int
    public let outsideProject: Int
    public let truncated: Bool
    public let cancelled: Bool
    public let tookMs: Double

    public init(root: String, scope: ArtifactScope = .project, artifacts: [Artifact] = [], sessions: [ArtifactSession] = [],
                sessionsScanned: Int = 0, outsideProject: Int = 0, truncated: Bool = false,
                cancelled: Bool = false, tookMs: Double = 0) {
        self.root = root
        self.scope = scope
        self.artifacts = artifacts
        self.sessions = sessions
        self.sessionsScanned = sessionsScanned
        self.outsideProject = outsideProject
        self.truncated = truncated
        self.cancelled = cancelled
        self.tookMs = tookMs
    }

    enum CodingKeys: String, CodingKey {
        case root, scope, artifacts, sessions, sessionsScanned, outsideProject, truncated, cancelled, tookMs
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            root: c.lossyString(.root) ?? "",
            scope: c.lossyString(.scope) == "all" ? .all : .project,
            artifacts: c.lossyArray(.artifacts),
            sessions: c.lossyArray(.sessions),
            sessionsScanned: Int(c.lossyNumber(.sessionsScanned) ?? 0),
            outsideProject: Int(c.lossyNumber(.outsideProject) ?? 0),
            truncated: c.lossyFlag(.truncated) ?? false,
            cancelled: c.lossyFlag(.cancelled) ?? false,
            tookMs: c.lossyNumber(.tookMs) ?? 0)
    }
}

public enum ArtifactAction: String, Equatable, Sendable {
    case write, edit
}

public struct ArtifactChange: Equatable, Sendable, Decodable {
    public let at: Double
    public let sessionId: String
    public let action: ArtifactAction
    public let tool: String
    /// What the call replaced. Empty on a write.
    public let before: String
    /// What the call put in.
    public let after: String
    public let replaceAll: Bool
    /// Either side was cut by the engine (24,000 characters a side).
    public let clipped: Bool

    public init(at: Double, sessionId: String = "", action: ArtifactAction, tool: String = "",
                before: String = "", after: String = "", replaceAll: Bool = false, clipped: Bool = false) {
        self.at = at
        self.sessionId = sessionId
        self.action = action
        self.tool = tool
        self.before = before
        self.after = after
        self.replaceAll = replaceAll
        self.clipped = clipped
    }

    enum CodingKeys: String, CodingKey { case at, sessionId, action, tool, before, after, replaceAll, clipped }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard let raw = c.lossyString(.action), let action = ArtifactAction(rawValue: raw) else {
            throw DecodingError.dataCorruptedError(forKey: .action, in: c, debugDescription: "change without an action")
        }
        self.init(
            at: c.lossyNumber(.at) ?? 0,
            sessionId: c.lossyString(.sessionId) ?? "",
            action: action,
            tool: c.lossyString(.tool) ?? "",
            before: c.lossyString(.before) ?? "",
            after: c.lossyString(.after) ?? "",
            replaceAll: c.lossyFlag(.replaceAll) ?? false,
            clipped: c.lossyFlag(.clipped) ?? false)
    }
}

public struct ArtifactHistory: Equatable, Sendable, Decodable {
    public let root: String
    public let relPath: String
    /// Most recent first.
    public let changes: [ArtifactChange]
    public let totalChanges: Int
    public let truncated: Bool
    public let cancelled: Bool
    public let tookMs: Double

    public init(root: String, relPath: String, changes: [ArtifactChange], totalChanges: Int? = nil,
                truncated: Bool = false, cancelled: Bool = false, tookMs: Double = 0) {
        self.root = root
        self.relPath = relPath
        self.changes = changes
        self.totalChanges = totalChanges ?? changes.count
        self.truncated = truncated
        self.cancelled = cancelled
        self.tookMs = tookMs
    }

    enum CodingKeys: String, CodingKey { case root, relPath, changes, totalChanges, truncated, cancelled, tookMs }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let changes: [ArtifactChange] = c.lossyArray(.changes)
        self.init(
            root: c.lossyString(.root) ?? "",
            relPath: c.lossyString(.relPath) ?? "",
            changes: changes,
            totalChanges: c.lossyNumber(.totalChanges).map { Int($0) },
            truncated: c.lossyFlag(.truncated) ?? false,
            cancelled: c.lossyFlag(.cancelled) ?? false,
            tookMs: c.lossyNumber(.tookMs) ?? 0)
    }
}

/// What a scan's answer means for the page — `scanOutcome` in the web panel.
public enum ArtifactsAnswer<Value: Equatable & Sendable>: Equatable, Sendable {
    case done(Value)
    /// The engine stopped the scan (another one on the same channel took its place).
    case cancelled
    /// A sentence to put on screen.
    case failed(String)

    /// The words the web page shows for a scan that did not finish.
    public var failureMessage: String? {
        switch self {
        case .done: return nil
        case .cancelled: return ArtifactRules.cancelledMessage
        case .failed(let message): return message
        }
    }
}

/// Reading the engine's answers (Foundation values, as `EngineBridge.invoke` returns them).
public enum ArtifactsWire {
    public static let listChannel = "artifacts:list"
    public static let changesChannel = "artifacts:changes"
    public static let readChannel = "fs:read"
    public static let sessionsChannel = "session:list"

    /// The request body of `artifacts:list`.
    public static func listRequest(cwd: String, scope: ArtifactScope) -> [String: Any] {
        ["cwd": cwd, "scope": scope.rawValue]
    }

    /// The request body of `artifacts:changes`.
    public static func changesRequest(cwd: String, relPath: String, scope: ArtifactScope) -> [String: Any] {
        ["cwd": cwd, "relPath": relPath, "scope": scope.rawValue]
    }

    public static func list(_ value: Any) -> ArtifactsAnswer<ArtifactList> { answer(value) }
    public static func history(_ value: Any) -> ArtifactsAnswer<ArtifactHistory> { answer(value) }

    static func answer<T: Decodable & Equatable & Sendable>(_ value: Any) -> ArtifactsAnswer<T> {
        guard let dict = value as? [String: Any] else { return .failed(unreadable) }
        if dict["ok"] as? Bool != true {
            if dict["error"] as? String == "cancelled" { return .cancelled }
            let message = (dict["message"] as? String)?.nonEmpty ?? (dict["error"] as? String)?.nonEmpty
            return .failed(message ?? unreadable)
        }
        guard JSONSerialization.isValidJSONObject(dict),
              let data = try? JSONSerialization.data(withJSONObject: dict),
              let decoded = try? JSONDecoder().decode(T.self, from: data)
        else { return .failed(unreadable) }
        return .done(decoded)
    }

    static let unreadable = "The engine’s answer could not be read."

    /// From `session:list`: each session's conversation id → its name, to put a
    /// name on a session chip (the web's `sessionNames`).
    public static func sessionNames(_ value: Any) -> [String: String] {
        guard let rows = value as? [Any] else { return [:] }
        var names: [String: String] = [:]
        for case let row as [String: Any] in rows {
            let id = (row["agentSessionId"] as? String) ?? ""
            let title = (row["title"] as? String) ?? ""
            if !id.isEmpty, !title.isEmpty { names[id] = title }
        }
        return names
    }
}

// MARK: Forgiving decoding helpers (this file's own; the shared ones live in SidebarModel.swift)

extension KeyedDecodingContainer {
    /// A number, or a numeric string; nil for null/missing/other.
    func lossyNumber(_ key: Key) -> Double? {
        if let d = try? decodeIfPresent(Double.self, forKey: key) { return d.isFinite ? d : nil }
        if let s = try? decodeIfPresent(String.self, forKey: key), let d = Double(s), d.isFinite { return d }
        return nil
    }

    /// Every string element; anything else is skipped. Missing → [].
    func lossyStrings(_ key: Key) -> [String] {
        guard var list = try? nestedUnkeyedContainer(forKey: key) else { return [] }
        var out: [String] = []
        while !list.isAtEnd {
            if let s = try? list.decode(String.self) {
                out.append(s)
            } else if (try? list.decode(SkipAny.self)) == nil {
                break
            }
        }
        return out
    }
}

/// Consumes one element of any shape, so a bad element can be stepped over.
private struct SkipAny: Decodable {
    init(from decoder: any Decoder) throws {}
}
