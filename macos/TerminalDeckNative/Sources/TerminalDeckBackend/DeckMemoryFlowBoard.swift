import Foundation
import TerminalDeckNativeCore

/// Fills the shared board straight from the app's own events: a session started, is
/// working, went idle, waits for the person, stopped; a task changed; Hoot is busy.
/// No AI. Pure: an event goes in, the board changes to write come out, and a change that
/// would write the same thing again is left out.
public struct DeckMemoryFlowBoard: Sendable {
    public struct Session: Sendable, Equatable {
        public var id: String
        public var title: String
        public var provider: String
        public var stamp: DeckMemoryStamp
        /// working | input | completed | idle | waiting | exited | started
        public var status: String
        public var exitCode: Int?
        public init(id: String, title: String, provider: String, stamp: DeckMemoryStamp, status: String = "started", exitCode: Int? = nil) {
            self.id = id; self.title = title; self.provider = provider; self.stamp = stamp; self.status = status; self.exitCode = exitCode
        }
    }
    public struct Changes: Sendable {
        public var updates: [DeckMemoryBoardUpdate] = []
        /// Rows that leave the board (they stay in the database).
        public var archive: [String] = []
        /// True when these updates only move a session between working and quiet (and its project's and seat's counts
        /// with it). They are written once the state has held (`DeckMemoryFlowEngine.settleBoard`), never at once.
        public var settle = false
    }
    /// The states a busy session flips between, many times a minute while an agent works. "input" (it asks the
    /// person) and "exited" are never settled: they are written at once, like every other change.
    public static let settlingStates: Set<String> = ["working", "idle", "completed", "waiting"]
    public private(set) var sessions: [String: Session] = [:]
    private var sent: [String: String] = [:]
    /// Rows whose "waits for you" line the app itself wrote (a permission, a question on screen).
    private var ownWaiting = Set<String>()
    private var tasks: Set<String> = []
    /// Seats that have a row: the stamp their last session carried (for the seat's row once no session is open).
    private var seats: [String: DeckMemoryStamp] = [:]
    /// The seat's own title as the person gave it ("iOS engineer"), by seat key.
    private var seatNames: [String: String] = [:]
    /// Who is hired into a seat right now, by seat key (from the app's own agent list).
    private var hires: [String: String] = [:]
    private let projectName: @Sendable (String) -> String?
    /// The project a task belongs to: the id the task carries, else the project its folder lies in.
    /// The same rule a session's row uses, so one project is one project on the board.
    private let projectOf: @Sendable (_ projectID: String?, _ folder: String) -> String

    public init(projectName: @escaping @Sendable (String) -> String? = { _ in nil },
                projectOf: @escaping @Sendable (String?, String) -> String = { PROJProjects.resolve(projectID: $0, folder: $1) }) {
        self.projectName = projectName; self.projectOf = projectOf
    }

    public static func doing(_ status: String, exitCode: Int? = nil) -> String {
        switch status {
        case "started": return "Started"
        case "working": return "Working"
        case "input": return "Waiting for you"
        case "completed": return "Finished its turn"
        case "exited": return (exitCode ?? 0) == 0 ? "Stopped" : "Stopped with an error (code \(exitCode ?? 0))"
        default: return "Idle"
        }
    }
    /// True while any known session is working (the tidy-up waits for a quiet app).
    public var anyWorking: Bool { sessions.values.contains { $0.status == "working" } }

    public mutating func sessionSeen(_ session: Session) -> Changes {
        var next = session
        if let known = sessions[session.id] {
            // A second sighting (a restored session, a re-read list) keeps the state already known.
            if session.status == "started" { next.status = known.status; next.exitCode = known.exitCode }
        }
        sessions[session.id] = next
        return rows(for: next)
    }
    public mutating func sessionStatus(id: String, status: String) -> Changes {
        guard var session = sessions[id], session.status != status else { return Changes() }
        let settles = Self.settlingStates.contains(session.status) && Self.settlingStates.contains(status)
        session.status = status
        if status != "exited" { session.exitCode = nil }
        sessions[id] = session
        var changes = rows(for: session)
        changes.settle = settles
        return changes
    }
    public mutating func sessionExited(id: String, code: Int) -> Changes {
        guard var session = sessions[id] else { return Changes() }
        session.status = "exited"; session.exitCode = code; sessions[id] = session
        return rows(for: session)
    }
    public mutating func sessionRenamed(id: String, title: String) -> Changes {
        guard var session = sessions[id], session.title != title else { return Changes() }
        session.title = title; sessions[id] = session
        return rows(for: session)
    }
    /// The app learned who the session belongs to (a lead was set, an agent was hired into the seat).
    public mutating func sessionStamped(id: String, stamp: DeckMemoryStamp) -> Changes {
        guard var session = sessions[id], session.stamp != stamp else { return Changes() }
        session.stamp = stamp; sessions[id] = session
        sent[DeckMemoryFlowNames.sessionRow(id)] = nil
        return rows(for: session)
    }
    public mutating func sessionRemoved(id: String) -> Changes {
        guard let session = sessions.removeValue(forKey: id) else { return Changes() }
        var changes = Changes()
        let row = DeckMemoryFlowNames.sessionRow(id)
        sent[row] = nil
        changes.archive.append(row)
        changes.updates += related(to: session)
        return changes
    }

    /// Hoot's own chat: one row, kind `chat`.
    public mutating func hoot(busy: Bool, waiting: String?) -> Changes {
        var changes = Changes()
        let doing = waiting != nil ? "Waiting for you" : busy ? "Working" : "Idle"
        var line = waiting
        if waiting != nil { ownWaiting.insert(DeckMemoryFlowNames.hootBoardRow) }
        else if ownWaiting.remove(DeckMemoryFlowNames.hootBoardRow) != nil { line = "" }
        let update = DeckMemoryBoardUpdate(id: DeckMemoryFlowNames.hootBoardRow, kind: .chat, stamp: DeckMemoryStamp(owner: .hoot, session: DeckMemoryFlowNames.hootSession, agent: "hoot"),
            title: "Hoot", doing: doing, waitingForUser: line)
        if note(update) { changes.updates.append(update) }
        return changes
    }

    /// The task list as the app publishes it (`tasks:changed`). A task that left the list leaves the board.
    public mutating func tasksChanged(_ views: [NativeRPCValue]) -> Changes {
        var changes = Changes(), present = Set<String>()
        for view in views {
            guard let id = view["id"].string, view["deletedAt"].isNullish, view["archivedAt"].isNullish else { continue }
            present.insert(id)
            // The task's own project id; a task from before projects had ids is placed by its folder.
            // Never the folder path itself: that made one project show as two on the board.
            let folder = view["project"].string ?? "", stated = view["projectId"].string.flatMap { $0.isEmpty ? nil : $0 }
            let project = stated != nil || !folder.isEmpty ? projectOf(stated, folder) : ""
            let status = view["status"].string ?? "", process = view["process"].string ?? ""
            var doing = status.isEmpty ? "Open" : status
            if process == "running" { doing += ", its agent is working" }
            if process == "queued" { doing += ", waiting its turn" }
            let stuck = status.lowercased() == "stuck"
            let update = DeckMemoryBoardUpdate(id: DeckMemoryBoardRow.rowID(.task, id), kind: .task,
                stamp: DeckMemoryStamp(owner: project.isEmpty ? .hoot : .project(project), project: project.isEmpty ? nil : project,
                                       session: view["sessionId"].string, agent: view["assignee"].string),
                title: view["title"].string ?? "Task", doing: doing, waitingForUser: stuck ? "This task is stuck." : "")
            if note(update) { changes.updates.append(update) }
        }
        for gone in tasks.subtracting(present) {
            let row = DeckMemoryBoardRow.rowID(.task, gone)
            sent[row] = nil; changes.archive.append(row)
        }
        tasks = present
        return changes
    }

    private mutating func rows(for session: Session) -> Changes {
        var changes = Changes()
        // The app takes away only the waiting line it put there itself. A line the helper wrote from the
        // conversation ("pick a build number") stays until the helper reads the person's answer.
        let row = DeckMemoryFlowNames.sessionRow(session.id)
        var waiting: String?
        if session.status == "input" { waiting = "Needs your answer in the session (a permission or a question)."; ownWaiting.insert(row) }
        else if ownWaiting.remove(row) != nil { waiting = "" }
        let update = DeckMemoryBoardUpdate(id: DeckMemoryFlowNames.sessionRow(session.id), kind: .session, stamp: session.stamp,
            title: session.title, doing: Self.doing(session.status, exitCode: session.exitCode), waitingForUser: waiting)
        if note(update) { changes.updates.append(update) }
        changes.updates += related(to: session)
        return changes
    }

    /// The project's row and the seat's row follow from their sessions.
    private mutating func related(to session: Session) -> [DeckMemoryBoardUpdate] {
        var updates: [DeckMemoryBoardUpdate] = []
        if let project = session.stamp.project, !project.isEmpty {
            let mine = sessions.values.filter { $0.stamp.project == project && $0.status != "exited" }
            let working = mine.filter { $0.status == "working" }.count, asking = mine.filter { $0.status == "input" }.count
            var parts: [String] = []
            if working > 0 { parts.append(working == 1 ? "1 session working" : "\(working) sessions working") }
            if asking > 0 { parts.append(asking == 1 ? "1 waiting for you" : "\(asking) waiting for you") }
            if parts.isEmpty { parts.append(mine.isEmpty ? "No open sessions" : "Quiet") }
            let update = DeckMemoryBoardUpdate(id: DeckMemoryBoardRow.rowID(.project, project), kind: .project,
                stamp: DeckMemoryStamp(owner: .project(project), project: project), title: projectName(project) ?? project,
                doing: parts.joined(separator: ", "))
            if note(update) { updates.append(update) }
        }
        let owner = session.stamp.owner
        if owner != .hoot, !owner.key.hasPrefix("project:") {
            // A lead's or an agent's seat: what it is doing now, through whichever sessions (hands) fill it.
            seats[owner.key] = DeckMemoryStamp(owner: owner, project: session.stamp.project, agent: session.stamp.agent)
            let update = seatRow(owner)
            if note(update) { updates.append(update) }
        }
        return updates
    }

    /// A lead's or an agent's seat in one row: named as the person named it, and never "vacant" while someone is hired into it.
    private func seatRow(_ owner: DeckMemoryOwner) -> DeckMemoryBoardUpdate {
        let mine = sessions.values.filter { $0.stamp.owner == owner && $0.status != "exited" }.sorted { $0.id < $1.id }
        let doing: String
        if mine.count > 1 {
            let working = mine.filter { $0.status == "working" }.count, asking = mine.filter { $0.status == "input" }.count
            var parts = ["\(mine.count) hands"]
            if working > 0 { parts.append("\(working) working") }
            if asking > 0 { parts.append("\(asking) waiting for you") }
            if working == 0, asking == 0 { parts.append("quiet") }
            doing = parts.joined(separator: ", ")
        } else if let only = mine.first {
            doing = Self.doing(only.status) + " in “" + only.title + "”"
        } else if let hire = hires[owner.key], !hire.isEmpty {
            // Hired but with no session open right now: the seat is filled, its agent is idle.
            doing = "Filled by " + hire + ", idle"
        } else {
            doing = "Vacant (its memory is kept)"
        }
        let stamp = seats[owner.key] ?? DeckMemoryStamp(owner: owner, project: owner.projectID)
        return DeckMemoryBoardUpdate(id: DeckMemoryBoardRow.rowID(.agent, owner.key), kind: .agent, stamp: stamp,
                                     title: seatNames[owner.key] ?? Self.seatTitle(owner), doing: doing)
    }
    /// A seat nobody named yet: its role's slug in plain words ("ios-engineer" → "Ios engineer"), never the raw key.
    static func seatTitle(_ owner: DeckMemoryOwner) -> String {
        let slug = owner.roleID ?? owner.key.split(separator: ":").last.map(String.init) ?? owner.key
        let words = slug.split(separator: "/").last.map(String.init)?.replacingOccurrences(of: "-", with: " ") ?? slug
        return owner.category == .lead ? "Lead" : words.prefix(1).uppercased() + words.dropFirst()
    }

    public func seatName(_ owner: DeckMemoryOwner) -> String? { seatNames[owner.key] }
    /// The app learned a seat's own title: its row carries it from now on.
    public mutating func named(_ owner: DeckMemoryOwner, _ name: String) -> Changes {
        var changes = Changes()
        guard seatNames[owner.key] != name else { return changes }
        seatNames[owner.key] = name
        if seats[owner.key] != nil { let update = seatRow(owner); if note(update) { changes.updates.append(update) } }
        return changes
    }
    /// Who is hired into which seat now (seat key → name). A seat row with no open session follows at once.
    public mutating func hired(_ next: [String: String]) -> Changes {
        var changes = Changes()
        guard hires != next else { return changes }
        hires = next
        for key in seats.keys.sorted() {
            guard let owner = DeckMemoryOwner(key: key) else { continue }
            let update = seatRow(owner)
            if note(update) { changes.updates.append(update) }
        }
        return changes
    }

    /// True when this update says something the board does not have yet.
    private mutating func note(_ update: DeckMemoryBoardUpdate) -> Bool {
        let mark = [update.stamp.owner.key, update.stamp.project ?? "", update.stamp.agent ?? "", update.title ?? "\u{1}", update.doing ?? "\u{1}", update.waitingForUser ?? "\u{1}"].joined(separator: "\u{0}")
        if sent[update.id] == mark { return false }
        sent[update.id] = mark
        return true
    }
}
