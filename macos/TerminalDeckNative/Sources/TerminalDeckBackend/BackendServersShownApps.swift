import Foundation
import TerminalDeckNativeCore

/// Per-server "Show only these apps" (item 98 follow-up). A server can also run apps that are
/// not ours (another team's CRM on the same box). When the owner picks a list, every other
/// container is hidden everywhere: the server page, Docker screens and every AI/MCP read.
/// nil = show all (the default). The saved list lives in servers.json (BackendServersStore);
/// this process-wide mirror lets the Docker service and the servers coordinator filter
/// without new dependencies. Names the server has reported are remembered for the picker.
public final class BackendServersShownApps: @unchecked Sendable {
    public static let shared = BackendServersShownApps()
    public static let maximumNames = 256
    private let lock = NSLock()
    private var shown: [String: Set<String>] = [:]
    private var seen: [String: [String]] = [:]

    public init() {}

    /// Container names arrive as "/name" from Docker and "name" elsewhere.
    public static func normalise(_ name: String) -> String {
        var value = name.trimmingCharacters(in: .whitespacesAndNewlines)
        while value.hasPrefix("/") { value.removeFirst() }
        return String(value.prefix(255))
    }
    public static func clean(_ names: [String]) -> [String] {
        var out: [String] = []
        for name in names.map(normalise) where !name.isEmpty && !out.contains(name) {
            out.append(name)
            if out.count >= maximumNames { break }
        }
        return out.sorted()
    }

    public func set(_ serverID: String, _ names: [String]?) {
        lock.withLock { shown[serverID] = names.map { Set(Self.clean($0)) } }
    }
    public func replaceAll(_ map: [String: [String]?]) {
        lock.withLock {
            shown = [:]
            for (id, names) in map { if let names { shown[id] = Set(Self.clean(names)) } }
        }
    }
    /// nil means every app is shown.
    public func shownNames(_ serverID: String) -> Set<String>? { lock.withLock { shown[serverID] } }
    public func isShown(_ serverID: String, name: String) -> Bool {
        guard let names = shownNames(serverID) else { return true }
        return names.contains(Self.normalise(name))
    }
    public func noteSeen(_ serverID: String, names: [String]) {
        let cleaned = Self.clean(names)
        lock.withLock { seen[serverID] = Self.clean((seen[serverID] ?? []) + cleaned) }
    }
    /// For the owner's picker only (it includes hidden names). Never return this to an AI caller.
    public func seenNames(_ serverID: String) -> [String] { lock.withLock { seen[serverID] ?? [] } }

    /// The one place server measurements are cut down: hidden containers never reach a card,
    /// a fact, a cached view or a tool reply.
    public func apply(_ facts: BackendServersFacts) -> BackendServersFacts {
        if let rows = facts.containers.value { noteSeen(facts.serverId, names: rows.map(\.name)) }
        guard shownNames(facts.serverId) != nil, case .yes(let rows, let at, let how) = facts.containers else { return facts }
        var copy = facts
        copy.containers = .yes(rows.filter { isShown(facts.serverId, name: $0.name) }, measuredAt: at, how: how)
        return copy
    }

    /// SETTINGS-TRUTH row 98: Terminal Deck's own apps on a server obey the same list. Every Apps channel (the
    /// screens and the apps.* AI tools both go through them) checks the app it names; `name` reads the app's saved
    /// name, nil when no such app exists yet (creating one is not refused here).
    public func requireShown(serverID: String, appID: String?, name: () async -> String?) async throws {
        guard let appID, !appID.isEmpty, shownNames(serverID) != nil, let found = await name() else { return }
        guard isShown(serverID, name: found) else { throw NativeRPCError(code: "access-denied", message: Self.hiddenRefusal) }
    }
    /// The app list cut down the same way (rows carry their saved `name`).
    public func shownRows(_ serverID: String, _ rows: NativeRPCValue) -> NativeRPCValue {
        guard shownNames(serverID) != nil, let items = rows.elements else { return rows }
        return .array(items.filter { isShown(serverID, name: $0["name"].string ?? "") })
    }

    public static let hiddenRefusal = "That app is hidden on this server. Only the apps chosen in the server's settings can be seen or used here."
    public static let viewRefusal = "This server shows only chosen apps, so this Docker view is off: it could show apps that are hidden."
}
