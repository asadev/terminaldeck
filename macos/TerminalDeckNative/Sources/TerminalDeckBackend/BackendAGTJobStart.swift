import Foundation
import TerminalDeckNativeCore

/// Deck Memory, the Agents side: "starting work clean" (MEMORY-SPEC §3).
/// When a lead or an agent gets a NEW job it starts from its SEAT's memory (card and the notes
/// that fit that job), not from yesterday's chat. The card and open topics are laid down by the
/// session's own start hook (L8 HOST); this adds the job's relevant notes to the brief and tells
/// the task engine to use a fresh conversation. A seat with no card yet changes nothing.
public struct BackendAGTJobStart: Sendable {
    public struct Plan: Sendable, Equatable {
        public var owner: DeckMemoryOwner
        /// lead / agent.
        public var category: String
        /// True: no resumed conversation and no reused open session for this job.
        public var cleanDesk: Bool
        /// Appended to the task brief ("" when there is nothing to add).
        public var brief: String
    }
    public typealias Store = @Sendable () -> any DeckMemoryStoring

    /// Set once by the app's composition; nil keeps the task engine exactly as it was.
    nonisolated(unsafe) private static var current: BackendAGTJobStart?
    private static let lock = NSLock()
    public static var shared: BackendAGTJobStart? {
        get { lock.withLock { current } }
        set { lock.withLock { current = newValue } }
    }

    private let projects: BackendAGTMemoryOwners.Projects
    private let store: Store
    public init(projects: @escaping BackendAGTMemoryOwners.Projects, store: @escaping Store = { DeckMemory.store }) {
        self.projects = projects; self.store = store
    }

    public static let reportForm = "Report back in this form: done or not · the result in three lines · proof · what you need. Long output stays in this session."

    /// The plan for one task about to start for `agent` (a stored profile row). Nil: leave the launch alone.
    public func plan(agent: NativeRPCValue, title: String, details: String) async -> Plan? {
        guard let id = agent["id"].string, !id.isEmpty else { return nil }
        let projects = await projects()
        let seat = AGTSeats.seat(agentID: id, seat: agent["seat"].string, projectID: Self.projectID(of: agent, projects: projects), projects: projects)
        let owner = seat.owner
        // Memory has to be there before the desk is cleared: without a card the old chat is all it has.
        let memory = store()
        guard let card = try? await memory.card(owner), card.exists else {
            guard seat.category == .lead else { return nil }
            return .init(owner: owner, category: seat.category.rawValue, cleanDesk: false, brief: Self.agentDecision)
        }
        let query = Self.query(title: title, details: details)
        var hits: [DeckMemorySearchHit] = []
        if !query.isEmpty {
            hits = (try? await memory.search(.init(query, owner: owner, kinds: [.note, .topic], limit: 8)))?.hits ?? []
            // A lead and a permanent agent also see their project's notes.
            if hits.count < 8, let project = owner.projectID ?? Self.projectID(of: agent, projects: projects), project != PROJProjects.independentID {
                let more = (try? await memory.search(.init(query, owner: .project(project), kinds: [.note], limit: 8 - hits.count)))?.hits ?? []
                hits += more.filter { extra in !hits.contains { $0.id == extra.id } }
            }
        }
        let root = await memory.location().root.path
        return .init(owner: owner, category: seat.category.rawValue, cleanDesk: true,
                     brief: Self.brief(category: seat.category, hits: hits, memoryRoot: root, ownerFolder: owner.folder))
    }

    /// The words a search runs on: the title first, then the start of the details.
    public static func query(title: String, details: String) -> String {
        let text = (title + " " + details.prefix(400)).replacingOccurrences(of: "\n", with: " ")
        return String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(500))
    }

    /// What is added to the brief. Short on purpose: titles, one line each and the file to read.
    public static func brief(category: AGTCategory, hits: [DeckMemorySearchHit], memoryRoot: String, ownerFolder: String) -> String {
        var lines = ["", "", "## From your memory", "",
                     "You start this job on a clean desk: this role's card and open topics are at the top of this session, and yesterday's chat is not here. The role's memory folder is \(memoryRoot)/\(ownerFolder); it belongs to the role, so write for whoever holds this role next."]
        if hits.isEmpty {
            lines += ["No saved note matches this job yet. Read the project's files for the facts."]
        } else {
            lines += ["", "Notes that look relevant to this job (read a file when you need the detail):"]
            let day = DateFormatter(); day.dateFormat = "d MMM yyyy"; day.locale = Locale(identifier: "en_GB")
            for hit in hits.prefix(8) {
                let snippet = hit.snippet.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
                var line = "- " + day.string(from: hit.labels.date) + " · " + hit.labels.type + " · " + hit.title
                if !snippet.isEmpty { line += ": " + String(snippet.prefix(220)) }
                if let path = hit.path { line += " (" + memoryRoot + "/" + path + ")" }
                lines.append(line)
            }
        }
        lines += ["", "Remember the why from your notes; check exact facts (what is installed, what shipped) at the source, never from memory.",
                  reportForm]
        if category == .lead {
            lines.append("You lead this project: hand work to its agents, read their reports, and report to Hoot in the same form.")
            lines.append(agentDecision)
        }
        return lines.joined(separator: "\n")
    }
    private static let agentDecision = "Before starting another agent, decide whether delegation is needed, which existing named agent fits and what bounded result it should return. Read Terminal Deck's built-in start-an-agent skill before delegating; use the existing skill reader or its bundled SKILL.md. Do not duplicate work an agent already owns."

    private static func projectID(of row: NativeRPCValue, projects: [PROJProject]) -> String? {
        let explicit = row["projectIdInferred"].bool == true ? nil : row["projectId"].string
        return PROJProjects.resolve(projectID: explicit, folder: row["sourceDirectory"].string ?? row["sourceFile"].string ?? row["defaultProject"].string, projects: projects)
    }
}
