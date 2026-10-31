import Foundation
import TerminalDeckNativeCore

/// Deck Memory, the Agents side (MEMORY-SPEC §3b): several hands on one seat.
/// A seat can be filled by more than one session at once ("Commander is running 3 database
/// fixers"). Every hand starts from the same seat memory and writes back into it; each has its
/// own job. This is the one place that numbers hands. L8 HOST joins a session when it fills a
/// seat and leaves when it stops; M1's stamp carries the number and the job from here.
public actor BackendAGTHands {
    public static let shared = BackendAGTHands()

    public struct Hand: Sendable, Equatable, Identifiable {
        public var id: String { sessionID }
        public var seat: DeckMemoryOwner
        /// 1, 2, 3… The lowest free number on the seat, kept for as long as the session fills it.
        public var number: Int
        public var sessionID: String
        /// The piece of work this hand holds, in one line ("" until it is known).
        public var job: String
        public var taskID: String?
        public var startedAt: Date
        public init(seat: DeckMemoryOwner, number: Int, sessionID: String, job: String, taskID: String?, startedAt: Date) {
            self.seat = seat; self.number = number; self.sessionID = sessionID; self.job = job; self.taskID = taskID; self.startedAt = startedAt
        }
    }

    private var hands: [String: Hand] = [:]
    /// A hand that was asked for and has not started yet: it already counts towards the cap.
    private var reserved: [String: (seat: DeckMemoryOwner, at: Date)] = [:]
    /// A helper's task that is about to be made: (agent, its job) → the helper seat's role. The session
    /// can start before the task record carries the role, so the seat is known from here first.
    private var expectedHelpers: [(agent: String, title: String, role: String, at: Date)] = []
    private var watchers: [UUID: AsyncStream<Void>.Continuation] = [:]
    private var taskTitle: (@Sendable (String) async -> String?)?
    private var closed: (@Sendable (DeckMemoryOwner) async -> Void)?

    /// The app's composition gives the task's title (a hand's job) and what to do when a seat empties.
    public func bind(taskTitle: @escaping @Sendable (String) async -> String?, seatEmptied: @escaping @Sendable (DeckMemoryOwner) async -> Void) {
        self.taskTitle = taskTitle; self.closed = seatEmptied
    }

    /// A session fills a seat. Calling it again for the same session keeps its number and updates its job.
    @discardableResult
    public func join(sessionID: String, seat: DeckMemoryOwner, job: String?, taskID: String?) async -> Hand {
        var title = job?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if title.isEmpty, let taskID, let taskTitle { title = await taskTitle(taskID) ?? "" }
        title = String(title.replacingOccurrences(of: "\n", with: " ").prefix(200))
        if let taskID { reserved[taskID] = nil }
        if var known = hands[sessionID], known.seat == seat {
            if !title.isEmpty { known.job = title }
            if let taskID { known.taskID = taskID }
            if known != hands[sessionID] { hands[sessionID] = known; changed() }
            return known
        }
        let old = hands[sessionID]?.seat
        let taken = Set(hands.values.filter { $0.seat == seat && $0.sessionID != sessionID }.map(\.number))
        var number = 1
        while taken.contains(number) { number += 1 }
        let hand = Hand(seat: seat, number: number, sessionID: sessionID, job: title, taskID: taskID, startedAt: Date())
        hands[sessionID] = hand
        changed()
        if let old, old != seat { await emptied(old) }
        return hand
    }
    /// The session closed, or stopped filling a seat.
    public func leave(sessionID: String) async {
        guard let hand = hands.removeValue(forKey: sessionID) else { return }
        changed()
        await emptied(hand.seat)
    }
    private func emptied(_ seat: DeckMemoryOwner) async {
        guard !hands.values.contains(where: { $0.seat == seat }) else { return }
        await closed?(seat)
    }

    public func hand(sessionID: String) -> Hand? { hands[sessionID] }
    /// In hand order.
    public func hands(seat: DeckMemoryOwner) -> [Hand] { hands.values.filter { $0.seat == seat }.sorted { $0.number < $1.number } }
    public func all() -> [Hand] { hands.values.sorted { ($0.seat.key, $0.number) < ($1.seat.key, $1.number) } }

    /// Called BEFORE the helper's task is made, so its session never lands on the agent's own seat.
    public func expectHelper(agent: String, title: String, role: String) {
        expectedHelpers.removeAll { $0.at < Date().addingTimeInterval(-600) }
        expectedHelpers.append((agent, title, role, Date()))
    }
    /// The helper seat a task of this agent with this title runs on, when one is expected.
    public func helperRole(agent: String?, title: String?) -> String? {
        guard let agent, let title else { return nil }
        return expectedHelpers.last { $0.agent == agent && $0.title == title && $0.at > Date().addingTimeInterval(-600) }?.role
    }

    /// A hand was asked for (a task was made for it): it counts until its session joins or 10 minutes pass.
    public func reserve(taskID: String, seat: DeckMemoryOwner) { reserved[taskID] = (seat, Date()); changed() }
    public func release(taskID: String) { if reserved.removeValue(forKey: taskID) != nil { changed() } }
    private func waiting(_ match: (DeckMemoryOwner) -> Bool) -> Int {
        let cutoff = Date().addingTimeInterval(-600)
        reserved = reserved.filter { $0.value.at > cutoff }
        return reserved.values.filter { match($0.seat) }.count
    }
    /// Hands on one seat, the ones still starting included.
    public func count(seat: DeckMemoryOwner) -> Int { hands.values.filter { $0.seat == seat }.count + waiting { $0 == seat } }
    /// Agent hands in one project (`nil`: outside any project), the ones still starting included.
    public func count(project: String?) -> Int {
        let inProject: (DeckMemoryOwner) -> Bool = { $0.category == .agent && $0.projectID == project }
        return hands.values.filter { inProject($0.seat) }.count + waiting(inProject)
    }

    /// Why one more hand cannot be added; nil when it can. The caps come from the category template.
    public func refusal(adding seat: DeckMemoryOwner, perSeat: Int, perProject: Int, seatTitle: String) -> String? {
        let onSeat = count(seat: seat)
        if onSeat >= max(1, perSeat) {
            return "\(seatTitle) already has \(onSeat) hand\(onSeat == 1 ? "" : "s"), the limit for one seat (\(max(1, perSeat))). Change it in Templates if you want more."
        }
        let inProject = count(project: seat.projectID)
        if seat.category == .agent, inProject >= max(1, perProject) {
            return "This project already has \(inProject) agent hands at work, its limit (\(max(1, perProject))). Change it in Templates if you want more."
        }
        return nil
    }

    /// Every change from now on (a hand joined, left, or its job changed).
    public nonisolated func changes() -> AsyncStream<Void> {
        AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let id = UUID()
            Task { await self.watch(id, continuation) }
            continuation.onTermination = { _ in Task { await self.unwatch(id) } }
        }
    }
    private func watch(_ id: UUID, _ continuation: AsyncStream<Void>.Continuation) { watchers[id] = continuation }
    private func unwatch(_ id: UUID) { watchers[id] = nil }
    private func changed() { for watcher in watchers.values { watcher.yield(()) } }

    /// For checks only.
    func reset() { hands = [:]; reserved = [:]; expectedHelpers = [] }
}

/// A short-lived helper seat sits under its parent seat: `<parent role>--helper-<n>`.
public enum BackendAGTHelperSeats {
    public static let marker = "--helper-"
    public static func isHelper(_ seat: DeckMemoryOwner) -> Bool { seat.roleID?.contains(marker) == true }
    /// The seat a helper seat folds back into.
    public static func parent(of seat: DeckMemoryOwner) -> DeckMemoryOwner? {
        guard case .role(let project, let role) = seat, let range = role.range(of: marker) else { return nil }
        return .role(project: project, role: String(role[..<range.lowerBound]))
    }
    /// The next free helper seat under `parent` (a role seat), given the helper seats that exist.
    public static func next(under parent: DeckMemoryOwner, existing: [DeckMemoryOwner]) -> DeckMemoryOwner? {
        guard case .role(let project, let role) = parent, !role.contains(marker) else { return nil }
        let taken = Set(existing.compactMap { seat -> Int? in
            guard case .role(let p, let r) = seat, p == project, r.hasPrefix(role + marker) else { return nil }
            return Int(r.dropFirst((role + marker).count))
        })
        var number = 1
        while taken.contains(number) { number += 1 }
        let slug = String((role + marker + String(number)).suffix(64))
        return .role(project: project, role: slug)
    }
}

/// "Add a hand" and "ask for hands". A lead (or Hoot, where a project has no lead, or the
/// person) adds a hand: one more session on the same seat with its own job, started through the
/// task engine with the playbook's defaults. An agent asks; its lead decides.
public struct BackendAGTHandsService: Sendable {
    nonisolated(unsafe) private static var current: BackendAGTHandsService?
    private static let lock = NSLock()
    /// Set once by the app's composition; the Agents screens and the tools use the same one.
    public static var shared: BackendAGTHandsService? {
        get { lock.withLock { current } }
        set { lock.withLock { current = newValue } }
    }

    public struct Dependencies: Sendable {
        public var projects: BackendAGTMemoryOwners.Projects
        public var agent: @Sendable (String) async throws -> NativeRPCValue?
        public var saveAgent: @Sendable (NativeRPCValue) async throws -> Void
        /// Makes the local task (title, instructions, assignee, project, useWorkspace) and returns its id.
        public var createTask: @Sendable (NativeRPCValue, _ by: String) async throws -> String
        public var patchTask: @Sendable (_ id: String, NativeRPCValue) async throws -> Void
        public var nudge: @Sendable () async -> Void
        /// Running sessions: id, title, project id.
        public var sessions: @Sendable () async -> [(id: String, title: String, project: String)]
        /// Types a line into a running session (a lead that is a session).
        public var tell: @Sendable (_ sessionID: String, _ text: String) async throws -> Void
        public var memory: @Sendable () -> any DeckMemoryStoring
        public init(projects: @escaping BackendAGTMemoryOwners.Projects, agent: @escaping @Sendable (String) async throws -> NativeRPCValue?,
                    saveAgent: @escaping @Sendable (NativeRPCValue) async throws -> Void,
                    createTask: @escaping @Sendable (NativeRPCValue, String) async throws -> String,
                    patchTask: @escaping @Sendable (String, NativeRPCValue) async throws -> Void, nudge: @escaping @Sendable () async -> Void,
                    sessions: @escaping @Sendable () async -> [(id: String, title: String, project: String)],
                    tell: @escaping @Sendable (String, String) async throws -> Void,
                    memory: @escaping @Sendable () -> any DeckMemoryStoring = { DeckMemory.store }) {
            self.projects = projects; self.agent = agent; self.saveAgent = saveAgent; self.createTask = createTask
            self.patchTask = patchTask; self.nudge = nudge; self.sessions = sessions; self.tell = tell; self.memory = memory
        }
    }
    private let deps: Dependencies
    private let hands: BackendAGTHands
    public init(_ deps: Dependencies, hands: BackendAGTHands = .shared) { self.deps = deps; self.hands = hands }

    /// The task-record field that puts a task's session on a helper seat instead of the agent's own.
    public static let taskSeatField = "agtSeat"

    private func caps(_ category: DeckMemoryCategory) async -> (seat: Int, project: Int) {
        if let template = try? await deps.memory().template(category) { return (template.handsPerSeat, template.handsPerProject) }
        return (DeckMemoryTemplate.defaultHandsPerSeat(category), DeckMemoryTemplate.defaultHandsPerProject(category))
    }
    private func title(_ seat: DeckMemoryOwner, agentName: String) async -> String {
        if let info = try? await deps.memory().owners().first(where: { $0.owner == seat }), !info.name.isEmpty { return info.name }
        return seat.roleID.map(AGTSeats.title(forRole:)) ?? agentName
    }

    /// One more hand on the agent's seat (or, with `helper`, the first hand on a new short-lived
    /// helper seat under it), with its own job. Refused above the template's cap.
    public func addHand(agentID: String, job: String, details: String, helper: Bool, by: String) async throws -> NativeRPCValue {
        let job = job.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !job.isEmpty else { throw NativeRPCError.invalidArguments("Say what this hand should do, in one line.") }
        guard let row = try await deps.agent(agentID), let id = row["id"].string else { throw NativeRPCError.invalidArguments("Choose one of your saved agents.") }
        guard row["status"].string != "archived" else { throw NativeRPCError.invalidArguments("That agent is archived.") }
        let projects = await deps.projects()
        let explicit = row["projectIdInferred"].bool == true ? nil : row["projectId"].string
        let home = PROJProjects.resolve(projectID: explicit, folder: row["sourceDirectory"].string ?? row["sourceFile"].string ?? row["defaultProject"].string, projects: projects)
        let own = AGTSeats.seat(agentID: id, seat: row["seat"].string, projectID: home, projects: projects).owner
        let name = row["name"].string ?? id
        var seat = own
        var helperTitle: String?
        if helper {
            let parent = AGTSeats.roleSeat(agentID: id, seat: row["seat"].string, projectID: home).owner
            let existing = ((try? await deps.memory().owners()) ?? []).map(\.owner) + (await hands.all()).map(\.seat)
            guard let made = BackendAGTHelperSeats.next(under: parent, existing: existing) else {
                throw NativeRPCError.invalidArguments("A helper cannot have helpers of its own.")
            }
            helperTitle = await title(parent, agentName: name) + " helper"
            seat = made
        }
        let limit = await caps(seat.category ?? .agent)
        let seatTitle = helper ? (helperTitle ?? "The helper seat") : await title(seat, agentName: name)
        if let refusal = await hands.refusal(adding: seat, perSeat: limit.seat, perProject: limit.project, seatTitle: seatTitle) {
            throw NativeRPCError(code: "hands-limit", message: refusal)
        }
        if helper, let parent = BackendAGTHelperSeats.parent(of: seat) {
            _ = try? await deps.memory().ensureOwner(seat, name: helperTitle, parent: parent)
        }
        // The task engine starts one session per task up to the agent's own limit: raise it to cover this hand, inside the cap.
        // 0 (or none saved) is "No limit" there, so it is never lowered to a number here.
        let busy = (await hands.all()).filter { $0.seat == own || BackendAGTHelperSeats.parent(of: $0.seat) == own }.count
        let allowed = Int(row["maxConcurrent"].number ?? 0)
        let needed = min(max(1, limit.project), max(allowed, busy + 1))
        if allowed > 0, allowed < needed { try await deps.saveAgent(row.setting("maxConcurrent", .number(Double(needed)))) }
        // The playbook's standing instructions for this kind of job go into the brief. Its AI, model, effort and
        // permission are applied at launch by the task engine (PLAYBOOK-SEATS: playbook row, then the agent's own
        // settings, then the app defaults), the same way for every agent job.
        var brief = details
        let leadOwner: DeckMemoryOwner = seat.projectID.flatMap { project in
            projects.first { $0.id == project }.flatMap(AGTSeats.lead(of:)) != nil ? DeckMemoryOwner.lead(project) : nil
        } ?? .hoot
        if let line = try? await deps.memory().playbookRow(leadOwner, job: job) {
            let standing = line.instructions.trimmingCharacters(in: .whitespacesAndNewlines)
            if !standing.isEmpty { brief += (brief.isEmpty ? "" : "\n\n") + "## Standing instructions for this kind of job\n\n" + standing }
        }
        let title = String(job.prefix(300))
        // agtHand: its own session, never the session another hand (or an earlier job) has open.
        var input = NativeRPCValue.object([.init("title", .string(title)), .init("instructions", .string(brief)),
                                           .init("assignee", .string(id)), .init("agtHand", .bool(true))])
        if helper, let role = seat.roleID { input = input.setting(Self.taskSeatField, .string(role)) }
        if let folder = row["defaultProject"].string, !folder.isEmpty { input = input.setting("project", .string(folder)) }
        if helper, let role = seat.roleID { await hands.expectHelper(agent: id, title: title, role: role) }
        // A second hand on code works in its own folder, so two hands never write over each other.
        let second = await hands.count(seat: seat) >= 1
        if second { input = input.setting("useWorkspace", .bool(true)) }
        let taskID = try await deps.createTask(input, by)
        await hands.reserve(taskID: taskID, seat: seat)
        if helper, let role = seat.roleID { try await deps.patchTask(taskID, .object([.init(Self.taskSeatField, .string(role))])) }
        await deps.nudge()
        return .object([.init("task", .string(taskID)), .init("agent", .string(id)), .init("seat", .string(seat.key)),
                        .init("seatTitle", .string(seatTitle)), .init("job", .string(job)), .init("helper", .bool(helper)),
                        .init("ownFolder", .bool(second)), .init("handsOnSeat", .number(Double(await hands.count(seat: seat)))),
                        .init("limit", .number(Double(limit.seat)))])
    }

    /// An agent asks for more hands (or a helper). It goes to its project's lead; with no lead
    /// (or a lead that is not running) it goes to Hoot. Nothing is started here: the lead decides.
    public func requestHands(fromSession sessionID: String, count: Int, job: String, why: String, helper: Bool) async throws -> NativeRPCValue {
        guard let asking = await hands.hand(sessionID: sessionID) else {
            throw NativeRPCError.invalidArguments("Only an agent working in a seat can ask for hands.")
        }
        // #23: one line each, no control characters: this text is typed into the lead's terminal.
        let job = BackendAGTLeadSeats.flat(job, 600), why = BackendAGTLeadSeats.flat(why, 1_200)
        guard !job.isEmpty else { throw NativeRPCError.invalidArguments("Say what the extra hands should do, in one line.") }
        let wanted = min(max(count, 1), 6)
        let projects = await deps.projects()
        let project = asking.seat.projectID.flatMap { id in projects.first { $0.id == id } }
        let seatTitle = await title(asking.seat, agentName: "An agent")
        let limit = await caps(.agent)
        let room = max(0, limit.seat - (await hands.count(seat: asking.seat)))
        let what = helper ? "a helper on a short-lived seat under it" : "\(wanted) more hand\(wanted == 1 ? "" : "s") on its seat"
        let text = "\(seatTitle) (hand \(asking.number)" + (asking.job.isEmpty ? "" : ", working on \"\(asking.job)\"") + ") asks for \(what). "
            + "The job: \(job). " + (why.isEmpty ? "" : "Why: \(why). ")
            + "Room left on that seat: \(room) of \(limit.seat). You decide. To start one, call agents_add_hand with the agent"
            + (asking.taskID == nil ? "" : " of task \(asking.taskID!)") + ", one distinct job per hand" + (helper ? ", helper true" : "") + "."
        return try await deliver(toLeadOf: project, title: "Hands wanted: " + String(job.prefix(200)), text: text)
    }

    /// Someone mentioned a VACANT seat that still holds memory (the @ list offers it, greyed): ask
    /// the project's lead (Hoot where there is no lead, or the lead is not running) to fill it.
    /// Nothing is hired here: the lead decides, and the next hire in that seat inherits its memory.
    public func requestFill(seat: DeckMemoryOwner, note: String, by: String) async throws -> NativeRPCValue {
        guard seat.category == .agent || seat.category == .lead else { throw NativeRPCError.invalidArguments("Choose an agent seat or a lead seat.") }
        let projects = await deps.projects()
        let project = seat.projectID.flatMap { id in projects.first { $0.id == id } }
        let info = try? await deps.memory().owners().first { $0.owner == seat }
        let name = info.flatMap { $0.name.isEmpty ? nil : $0.name } ?? seat.roleID.map(AGTSeats.title(forRole:)) ?? "The lead seat"
        var holds: [String] = []
        if let info {
            if info.notes > 0 { holds.append("\(info.notes) note\(info.notes == 1 ? "" : "s")") }
            if info.topics > 0 { holds.append("\(info.topics) topic\(info.topics == 1 ? "" : "s")") }
        }
        let note = note.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\n", with: " ")
        let text = "The seat \"\(name)\"" + (project.map { " on \($0.name)" } ?? "") + " is vacant and still holds its memory"
            + (holds.isEmpty ? "" : " (" + holds.joined(separator: ", ") + ")") + ". \(by) asks for it to be filled"
            + (note.isEmpty ? "." : ": \(note)") + " Whoever is hired into this seat inherits that memory, on any AI or model. "
            + "Decide who fills it (a new agent, or an existing one moved into the role \"\(seat.roleID ?? "lead")\"), or say why it stays empty."
        // A vacant LEAD seat has no lead to ask: Hoot decides.
        let ask = seat.category == .lead ? nil : project
        var reply = try await deliver(toLeadOf: ask, title: "Fill the vacant seat: " + String(name.prefix(200)), text: text)
        reply = reply.setting("seat", .string(seat.key)).setting("seatTitle", .string(name))
        return reply
    }

    /// To the project's lead: a task for a lead that is a saved agent, a typed line for a lead that
    /// is a running session; with no lead (or a lead that is not running) a task for Hoot.
    private func deliver(toLeadOf project: PROJProject?, title: String, text: String) async throws -> NativeRPCValue {
        if let project, let lead = AGTSeats.lead(of: project) {
            if lead.kind == .agent {
                let taskID = try await deps.createTask(.object([.init("title", .string(title)),
                    .init("instructions", .string(text)), .init("assignee", .string(lead.id))]), "agent")
                await deps.nudge()
                return .object([.init("sentTo", .string("lead")), .init("name", .string(lead.name)), .init("task", .string(taskID))])
            }
            let running = await deps.sessions()
            if let session = running.first(where: { $0.id == lead.id }) ?? running.first(where: { $0.project == project.id && $0.title.caseInsensitiveCompare(lead.name) == .orderedSame }) {
                // Typed into a running terminal: one flat line (a newline or carriage return would be a second command).
                try await deps.tell(session.id, "[Terminal Deck] " + BackendAGTLeadSeats.flat(text, 4_000))
                return .object([.init("sentTo", .string("lead")), .init("name", .string(lead.name)), .init("session", .string(session.id))])
            }
        }
        // No lead, or the lead is not running: Hoot assigns directly.
        let taskID = try await deps.createTask(.object([.init("title", .string(title)),
            .init("instructions", .string(text)), .init("assignee", .string("hoot"))]), "agent")
        await deps.nudge()
        return .object([.init("sentTo", .string("hoot")), .init("name", .string("Hoot")), .init("task", .string(taskID))])
    }

    /// Every hand at work, for the tools: seat, number, job, session.
    public func list() async -> NativeRPCValue {
        .object([.init("hands", .array(await hands.all().map { hand in
            .object([.init("seat", .string(hand.seat.key)), .init("hand", .number(Double(hand.number))), .init("job", .string(hand.job)),
                     .init("session", .string(hand.sessionID)), .init("task", hand.taskID.map(NativeRPCValue.string) ?? .null)])
        }))])
    }
}

/// The tools: `agents.hands` (read), `agents.add_hand` (asks first), `agents.request_hands` (an agent asks its lead).
public enum BackendAGTHandsMCP {
    public static let ids = ["agents.hands", "agents.add_hand", "agents.request_hands"]

    public static func install(server: BackendNativeMCPServer, ownerID: String, authority: BackendTaskToolAuthority,
                               service: @escaping @Sendable () -> BackendAGTHandsService?) async throws {
        let s = NativeRPCValue.object([.init("type", .string("string"))])
        let b = NativeRPCValue.object([.init("type", .string("boolean"))])
        let n = NativeRPCValue.object([.init("type", .string("integer")), .init("minimum", .number(1)), .init("maximum", .number(6))])
        func schema(_ properties: [(String, NativeRPCValue)], required: [String]) -> NativeRPCValue {
            .object([.init("type", .string("object")), .init("properties", .object(properties.map { .init($0.0, $0.1) })),
                     .init("required", .array(required.map(NativeRPCValue.string))), .init("additionalProperties", .bool(false))])
        }
        let tools: [(String, BackendMCPTier, String, NativeRPCValue)] = [
            ("agents.hands", .read, "Every hand at work: the seat it fills, its hand number, its job in one line and its session. A seat can have several hands at once.", schema([], required: [])),
            ("agents.add_hand", .act, "Add a hand: one more session on an agent's seat, with its own distinct job, started with the usual defaults. For a lead (or Hoot where a project has no lead). helper true starts it on a short-lived helper seat under that agent's seat; its notes fold back when it closes. Refused above the limit set in the Agent template. Runs at once when the calling AI's permission mode allows it; the action is logged.",
             schema([("agent", s), ("job", s), ("details", s), ("helper", b)], required: ["agent", "job"])),
            ("agents.request_hands", .act, "For an agent at work: ask your lead (or Hoot, where your project has no lead) for more hands on your seat, or for a helper. Nothing starts until the lead decides.",
             schema([("count", n), ("job", s), ("why", s), ("helper", b)], required: ["job"])),
        ]
        for (id, tier, description, input) in tools {
            let spec = try BackendMCPTool(id: id, wireName: id.replacingOccurrences(of: ".", with: "_"), description: description, inputSchema: input, tier: tier)
            try await server.registerTool(spec, ownerID: ownerID) { caller, args in
                guard caller.allowedTiers.contains(tier) else { throw NativeRPCError(code: "not-granted", message: "This caller cannot do that with agents.") }
                guard let service = service() else { throw NativeRPCError(code: "unavailable", message: "Agents are still starting.") }
                try await authority.requireTasks(caller)
                try Task.checkCancellation(); guard !caller.cancellation.isCancelled else { throw CancellationError() }
                switch id {
                case "agents.hands":
                    try await authority.authorize(caller, id, args, .read)
                    return .value(await service.list())
                case "agents.add_hand":
                    let agent = try args["agent"].requireString("agent", nonempty: true), job = try args["job"].requireString("job", nonempty: true)
                    try await authority.authorize(caller, id, args, .act)
                    return .value(try await service.addHand(agentID: agent, job: job, details: args["details"].string ?? "",
                                                            helper: args["helper"].bool == true, by: try await authority.actorName(caller)))
                default:
                    let session = caller.sessionID
                    guard !session.isEmpty else { throw NativeRPCError.invalidArguments("Only an agent working in a session can ask for hands.") }
                    let job = try args["job"].requireString("job", nonempty: true)
                    // #320: the same gate as add_hand (change limit and the agent's own tool rules) before anything is sent.
                    try await authority.authorize(caller, id, args, .act)
                    return .value(try await service.requestHands(fromSession: session, count: Int(args["count"].number ?? 1), job: job,
                                                                 why: args["why"].string ?? "", helper: args["helper"].bool == true))
                }
            }
        }
    }
}
