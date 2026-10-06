import Foundation

// Which session a native terminal is, wherever it runs, and what is known about
// the machine it runs on — the page's `workspace-tabs.ts` ids, `machines/types.ts`
// views and `shell/session-end.ts` notices, restated for the native screens.

/// One session as the page's tab ids name it.
public enum SessionTarget: Hashable, Sendable {
    /// A pty on this Mac (its id is a UUID).
    case local(String)
    /// A session on one of his paired machines (`machine <machineId> <sessionId>`).
    case machine(machineId: String, sessionId: String)
    /// A shell on a server (`server <serverId> <shellKey>`).
    case server(serverId: String, shellKey: String)

    public init?(tabId id: String) {
        if UUID(uuidString: id) != nil {
            self = .local(id)
        } else if let (a, b) = Self.pair(id, prefix: "machine ") {
            self = .machine(machineId: a, sessionId: b)
        } else if let (a, b) = Self.pair(id, prefix: "server ") {
            self = .server(serverId: a, shellKey: b)
        } else {
            return nil
        }
    }

    /// The tab id this target is drawn under (`machineTabId` / `serverTabId`).
    public var tabId: String {
        switch self {
        case .local(let id): return id
        case .machine(let machine, let session): return "machine \(machine) \(session)"
        case .server(let server, let key): return "server \(server) \(key)"
        }
    }

    public var machineId: String? {
        if case .machine(let id, _) = self { return id }
        return nil
    }

    /// `readMachineTabId` / `readServerTabId`: the first space after the prefix splits the two.
    private static func pair(_ id: String, prefix: String) -> (String, String)? {
        guard id.hasPrefix(prefix) else { return nil }
        let rest = id.dropFirst(prefix.count)
        guard let cut = rest.firstIndex(of: " "), cut != rest.startIndex,
              rest.index(after: cut) != rest.endIndex else { return nil }
        return (String(rest[..<cut]), String(rest[rest.index(after: cut)...]))
    }
}

// MARK: - Servers

/// What the page's tabs state carries for a terminal on a server — `ServerSessionPane`'s
/// own props: where to open it, what to run once it opens, and the shell id once open.
public struct ServerTabInfo: Equatable, Sendable, Decodable {
    public let serverId: String
    public let serverName: String
    public let shellKey: String
    public let startIn: String?
    public let run: String?
    public let shellId: String?

    public init(serverId: String, serverName: String, shellKey: String, startIn: String?, run: String?, shellId: String?) {
        self.serverId = serverId
        self.serverName = serverName
        self.shellKey = shellKey
        self.startIn = startIn
        self.run = run
        self.shellId = shellId
    }
}

/// `ShellFrames`: output that arrives before the shell's own id is known is held
/// (up to 256 KB) and handed over, filtered to that shell, once it is.
public struct ShellFrames: Sendable {
    public static let mostHeldBytes = 256 * 1024
    private var held: [(shellId: String, data: String)]? = []
    private var bytes = 0
    private var id: String?
    private let cap: Int

    public init(cap: Int = ShellFrames.mostHeldBytes) { self.cap = cap }

    /// A chunk from any shell: what to write now ("" when it is held or not this one's).
    public mutating func arrived(shellId: String, data: String) -> String {
        if let id { return shellId == id ? data : "" }
        if held != nil, bytes < cap {
            held?.append((shellId, data))
            bytes += data.utf16.count
        }
        return ""
    }

    /// The shell opened (or did not): what was held for it, in order.
    public mutating func settled(_ shellId: String?) -> String {
        let kept = held ?? []
        held = nil
        id = shellId
        guard let shellId else { return "" }
        return kept.filter { $0.shellId == shellId }.map(\.data).joined()
    }

    /// Nothing will open: stop holding.
    public mutating func give() { held = nil }
}

// MARK: - Paired machines (`machines:list` / `machines:state`)

/// One session on a paired machine (`RemoteSession`).
public struct RemoteSessionFacts: Equatable, Sendable {
    public let id: String
    public let title: String
    public let cwd: String
    public let provider: String
    public let status: String
    public let exitCode: Int?
}

/// A machine's link (`MachineLinkState`), as much as a session's screen reads.
public struct MachineLinkFacts: Equatable, Sendable {
    public enum State: String, Sendable { case offline, connecting, awaitingApproval = "awaiting-approval", online, error }
    public let id: String
    public let state: State
    public let reason: String?
    /// Epoch milliseconds of the next automatic try, or nil.
    public let retryAt: Double?
    public let sessions: [RemoteSessionFacts]

    public init(id: String, state: State, reason: String?, retryAt: Double?, sessions: [RemoteSessionFacts]) {
        self.id = id
        self.state = state
        self.reason = reason
        self.retryAt = retryAt
        self.sessions = sessions
    }

    public func session(_ id: String) -> RemoteSessionFacts? { sessions.first { $0.id == id } }
}

/// What `machines:list` answers and `machines:state` pushes (`MachinesView`).
public struct MachinesSnapshot: Equatable, Sendable {
    /// Machine id → its name.
    public let names: [String: String]
    public let links: [String: MachineLinkFacts]

    public static let empty = MachinesSnapshot(names: [:], links: [:])

    public init(names: [String: String], links: [String: MachineLinkFacts]) {
        self.names = names
        self.links = links
    }

    public static func decode(_ raw: Any?) -> MachinesSnapshot? {
        guard let view = raw as? [String: Any] else { return nil }
        var names: [String: String] = [:]
        for machine in view["machines"] as? [Any] ?? [] {
            guard let record = machine as? [String: Any], let id = TerminalJSON.text(record["id"]) else { continue }
            names[id] = record["name"] as? String ?? id
        }
        var links: [String: MachineLinkFacts] = [:]
        for link in view["links"] as? [Any] ?? [] {
            guard let record = link as? [String: Any], let id = TerminalJSON.text(record["id"]) else { continue }
            let state = (record["state"] as? String).flatMap(MachineLinkFacts.State.init(rawValue:)) ?? .offline
            let sessions: [RemoteSessionFacts] = (record["sessions"] as? [Any] ?? []).compactMap { raw in
                guard let s = raw as? [String: Any], let sid = TerminalJSON.text(s["id"]) else { return nil }
                return RemoteSessionFacts(id: sid, title: s["title"] as? String ?? "", cwd: s["cwd"] as? String ?? "",
                                          provider: s["provider"] as? String ?? "", status: s["status"] as? String ?? "",
                                          exitCode: TerminalJSON.int(s["exitCode"]))
            }
            links[id] = MachineLinkFacts(id: id, state: state, reason: record["reason"] as? String,
                                         retryAt: TerminalJSON.number(record["retryAt"]), sessions: sessions)
        }
        return MachinesSnapshot(names: names, links: links)
    }
}

// MARK: - A session that is over (`session-end.ts`)

/// Why a session's screen is a photograph.
public enum SessionEnd: Equatable, Sendable {
    /// The process finished; nil when nothing said with which code.
    case exited(code: Int?)
    /// A shell on a server: the channel closed and why is not knowable here.
    case shellGone(server: String)
    /// That machine is not answering; redialled unless `retryAt` is nil.
    case machineAway(machine: String, why: String?, retryAt: Double?)
    case machineDialling(machine: String)
    case machineStopped(machine: String)
    case machineUnapproved(machine: String)
    case neverOpened(why: String)

    /// `endOfLocalSession`.
    public static func ofLocal(exitCode: Int?) -> SessionEnd? {
        exitCode.map { .exited(code: $0) }
    }

    /// `endOfMachineSession`: read off the link, and off the session once the link is up.
    public static func ofMachineSession(machine: String, link: MachineLinkFacts?, session: RemoteSessionFacts?) -> SessionEnd? {
        guard let link else { return .machineStopped(machine: machine) }
        switch link.state {
        case .offline: return .machineStopped(machine: machine)
        case .connecting: return .machineDialling(machine: machine)
        case .awaitingApproval: return .machineUnapproved(machine: machine)
        case .error: return .machineAway(machine: machine, why: link.reason, retryAt: link.retryAt)
        case .online:
            guard let session, let code = session.exitCode else { return nil }
            return .exited(code: code)
        }
    }

    /// `endedNotice`: what happened, whether the work is alive somewhere, and the one press.
    public var notice: SessionEndNotice {
        switch self {
        case .exited(let code):
            let said = (code ?? 0) == 0
                ? "The program running here finished."
                : "The program running here exited with status \(code!)."
            return SessionEndNotice(title: "This session has ended",
                                    detail: said + " What it printed is still above — nothing typed now goes anywhere.",
                                    action: .init(id: .reopen, label: "Start another session here"), alive: false, retryAt: nil)
        case .shellGone(let server):
            return SessionEndNotice(
                title: "This terminal has ended",
                detail: "The shell on \(server) closed. That is either the shell itself ending or \(server) "
                    + "dropping the connection, and this app cannot tell which from here. If the machine is gone, "
                    + "opening another terminal on it will fail too — if it opens, the shell was the thing that ended.",
                action: .init(id: .reopen, label: "Open another terminal on \(server)"), alive: false, retryAt: nil)
        case .machineAway(let machine, let why, let retryAt):
            return SessionEndNotice(
                title: "\(machine) is not answering",
                detail: (why ?? "That machine stopped answering.")
                    + " The session is still running over there — this window just has no way to reach it. "
                    + (retryAt == nil ? "It will reconnect on its own when that machine comes back." : "It is being dialled again."),
                action: retryAt == nil ? .init(id: .redial, label: "Try it now") : nil, alive: true, retryAt: retryAt)
        case .machineDialling(let machine):
            return SessionEndNotice(
                title: "Reconnecting to \(machine)",
                detail: "The link dropped and is being dialled again. Nothing was lost — the session is still running over there, "
                    + "and its screen comes back with the link.",
                action: nil, alive: true, retryAt: nil)
        case .machineStopped(let machine):
            return SessionEndNotice(
                title: "Disconnected from \(machine)",
                detail: "This link was stopped from here, so nothing is being dialled. The session is still running over there "
                    + "and comes back with its screen when you connect again.",
                action: .init(id: .connect, label: "Connect to \(machine)"), alive: true, retryAt: nil)
        case .machineUnapproved(let machine):
            return SessionEndNotice(
                title: "\(machine) has not let this computer in",
                detail: "That machine answered and refused. Somebody has to approve this desktop over there — until they do, "
                    + "nothing typed here reaches it.",
                action: nil, alive: true, retryAt: nil)
        case .neverOpened(let why):
            return SessionEndNotice(title: "This session never started", detail: why,
                                    action: .init(id: .reopen, label: "Try again"), alive: false, retryAt: nil)
        }
    }
}

public struct SessionEndNotice: Equatable, Sendable {
    public enum ActionID: String, Sendable { case reopen, connect, redial }
    public struct Action: Equatable, Sendable {
        public let id: ActionID
        public let label: String
    }
    public let title: String
    public let detail: String
    public let action: Action?
    /// Whether the session is still alive somewhere (the card's accent says so).
    public let alive: Bool
    public let retryAt: Double?

    /// `useCountdown`: "in 4s", "now", or nil when nothing is scheduled.
    public func countdown(nowMs: Double) -> String? {
        guard let retryAt else { return nil }
        let left = Int(((retryAt - nowMs) / 1000).rounded())
        return left <= 0 ? "now" : "in \(left)s"
    }

    /// The detail with " Next try in 4s." when a retry is scheduled.
    public func detail(nowMs: Double) -> String {
        guard let countdown = countdown(nowMs: nowMs) else { return detail }
        return "\(detail) Next try \(countdown)."
    }
}

// MARK: - Files crossing to another machine

public enum TerminalTransfer {
    /// `MAX_PASTE_BYTES`: the most one ⌘V may push into a session on another machine.
    public static let maxPasteBytes = 1024 * 1024
    /// `PASTE_TOO_BIG` (the limit as `byteSize` says it).
    public static let pasteTooBig = "That paste is too big to send — the limit is 1.0 MB."
    public static let noLink = "That went nowhere — this window has no link to that machine right now."
    public static let noFileInDrop = "Nothing in that drop is a file on this machine."

    /// `overPasteCap`, in UTF-8 bytes.
    public static func overPasteCap(_ text: String) -> Bool {
        text.utf8.count > maxPasteBytes
    }

    /// `transferLine`: one short line about a transfer, or "" when there is nothing to say.
    public static func line(name: String, size: Double, sent: Double, phase: String, message: String) -> String {
        if phase == "failed" { return message }
        if phase == "landed" { return "" }
        if phase == "finishing" { return "\(name) — finishing" }
        if size <= 0 { return name }
        let percent = min(100, Int((sent / size * 100).rounded(.down)))
        return "\(name) — \(percent)%"
    }
}
