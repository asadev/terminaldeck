import Foundation
import TerminalDeckNativeCore

/// Lane A2, lean first version (cloud-lean-v1.md item 7): the AGENTS and their instruction files arrive on a second
/// Mac, by the field list the Security seat signed (design v2 Appendix A, Ruling 3 and its addendum on names).
///
/// - Travels: an agent's name, role, preferred and avoided tools, model, effort, icon and who it reports to; its
///   instruction text as its own record (`instruction:<agent id>.md`).
/// - Per Mac, never sent: `account`, `creatorKeyId`, `keyInitializedFields`, every path, the check command, the
///   import source and anything else not on the signed list (the adapter sends only listed fields).
/// - Widening fields (the AI, permission mode, tool lists, skills, run limits, an agent switched back on, its
///   project and its seat) are NEVER applied from another device to an agent this Mac already has: they stay as
///   this Mac has them and are listed as waiting on this Mac. A change that only narrows applies.
///   Y2 (13 Nov): that is the STRICT way ("Ask me for each new device"). With the device-trust setting at its default
///   ("Automatically, with my account") every field from the account's own trusted devices applies (`fullAccess`).
/// - FIRST ARRIVAL: an agent this Mac has NEVER had, arriving after the person confirmed this Mac's set-up from
///   the Cloud in this Mac's own window, is created with its project and seat as on the source. Nothing else that
///   could widen it is taken even then (see `mayApply`).
/// - An intended removal travels into the keeper Bin. A concurrent or later edit wins by ancestry and restores
///   the agent with this Mac's own launch settings kept.
/// - Names: one plain line. A name from another device that would CAPTURE mentions meant for someone else is not
///   taken (see `nameProblem`): an agent this Mac already has keeps its name, an agent new to this Mac is not added;
///   both are listed with the reason. A name that only begins with another name ("Memory", "Reviewer" beside
///   "Review") is taken and listed once. Every rename is listed.
/// - Nothing from the Cloud starts work: the write is one save with no change notice, no run, no session, no
///   routine and no notification. Screens refresh through `display` only.
/// Not registered by itself: lane A's wiring builds it (see macos/night/codex/cloud-adapters-wiring.md).
public actor BackendCloudLeanAgents: CloudBrainRecordOwner, CloudDeleteOwning {
    public static let domain = "agents"
    public static let inventoryRow = "I10"
    public static let sourceID = "task-config-agents"
    /// An agent's instruction text: `agent-instructions/<agent id>.md` only (design v2 Appendix A).
    public static let instructionTable = CloudBrainMergeTables.recordsDeleteRule(CloudBrainMergeTable(domain: "agents", version: 1, classes: ["id": .identity, "text": .shared]))
    public static let instructionKind = CloudBrainRecordKind(prefix: "instruction:", suffix: ".md", table: instructionTable)
    /// An agent row; it is applied only after its instruction record has arrived on this Mac.
    public static let agentKind = CloudBrainRecordKind(prefix: "agent:", table: CloudBrainMergeTables.recordsDeleteRule(CloudBrainMergeTables.agent), listedValues: ["name", "model", "effort"],
        requires: { "instruction:" + $0 + ".md" })
    /// Instruction records first: within one moment an agent's text is sent before the agent.
    public static let kinds = [instructionKind, agentKind]
    public static let exclusions = [
        "Each agent's login, permissions, tools, skills and run limits are set on each device; a wider value from another device waits on this Mac. Its project and seat arrive with a new agent; a later change to them waits.",
        "Agent settings kept in the protected settings store, connected task systems and custom agent files are not sent in this version.",
    ]
    static let sharedFields = ["role", "toolsPreferred", "toolsAvoided", "model", "effort", "icon", "reportsTo"]
    static let wideningFields = ["provider", "permissionMode", "allowedTools", "blockedTools", "skillsOff", "toolUseRestrictions", "claudeAgent", "skills",
        "maxConcurrent", "maxRunMinutes", "keepAliveMinutes", "keepAliveUntilClose", "status", "projectId", "seat"]
    /// Names that route mentions to the person or to Hoot (Ruling 3 addendum, 2).
    static let reservedNames = ["hoot", "me"]
    static let waitingReason = "Set on another device. It can widen what this agent may do, so it is not applied here; set it on this Mac if you want it."
    /// An agent this Mac once had, removed here, then changed on another device.
    /// A new agent whose project is not on this Mac (not arrived yet, or not taken here): it is not placed in another.
    /// A new agent that arrived while this Mac's trusted list could not be read: whether its project and seat may be
    /// taken is not known yet, so it is not added until it is (never added without them and left so for ever).
    static let trustUnreadable = "This agent waits until this Mac's list of trusted devices can be read; then it is added, with its project and seat if you confirmed this Mac's set-up."
    static let projectNotHere = "This agent waits for its project, which is not on this Mac yet. It is added with its project and seat when that project is here."

    private nonisolated let deletes: RecordsDeleteLedger
    private var gone: [String: Date] = [:]
    private var removalWaits: [String: String] = [:]
    /// Tests only: runs once the roster has been read in a capture pass, to make a delete land during that pass.
    private var afterRosterRead: (@Sendable () async -> Void)?
    func setAfterRosterRead(_ hook: (@Sendable () async -> Void)?) { afterRosterRead = hook }
    private let witness: CloudDeleteWitnessSlot
    private let now: @Sendable () -> Date
    private let config: BackendTaskConfiguration
    private let display: @Sendable () async -> Void
    private let defaultProvider: @Sendable () async -> String
    private let firstArrivalConfirmed: @Sendable () async -> Bool?
    /// Y2 (13 Nov, the lead's decision under the owner's rule "full access always with the account"): true while this
    /// Mac's device-trust setting is "Automatically, with my account" (the default). Changes from the account's own
    /// trusted devices are then APPLIED IN FULL, widening fields included, with no click; with "Ask me for each new
    /// device" (false) they wait and are listed exactly as before. nil = the setting cannot be read: the strict way.
    private let fullAccess: @Sendable () async -> Bool?
    private let projects: @Sendable () async -> [String]?
    private let historyFile: URL?
    /// Every name each agent has had on this Mac, lower-cased (Ruling 3 addendum, 3).
    private var names: [String: Set<String>]

    /// `historyFile`: where this Mac keeps the names its agents have had (in the app's cloud folder, outside any account).
    /// `defaultProvider`: this Mac's default AI, as the launcher reads it. `display`: refreshes screens, display only
    /// (`BackendCloudLeanRecords.displayEvent`, never the change hub or the app-wide "tasks:changed" channel).
    /// `firstArrivalConfirmed`: true once the person confirmed, in this Mac's own window, the devices this Mac takes
    /// changes from (lane A's "Set up this Mac from your Cloud" sheet, or a Trust press). False (the default) keeps a
    /// new agent's project and seat waiting like every other widening field. NIL while this Mac's trusted list cannot be
    /// read: a new agent then waits whole and the decision is made again when the list reads (review should-fix 3).
    /// `projects`: the ids of this Mac's projects, nil while the list cannot be read. A new agent whose project is not
    /// among them waits whole (it is never placed in another project) and is added once that project is here.
    public init(config: BackendTaskConfiguration, historyFile: URL? = nil, defaultProvider: @escaping @Sendable () async -> String = { "claude" },
                firstArrivalConfirmed: @escaping @Sendable () async -> Bool? = { false },
                fullAccess: @escaping @Sendable () async -> Bool? = { false },
                projects: @escaping @Sendable () async -> [String]? = { nil },
                display: @escaping @Sendable () async -> Void = {}, witness: CloudDeleteWitnessSlot = .shared,
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.witness = witness; self.now = now
        self.deletes = config.recordDeletes
        self.config = config; self.historyFile = historyFile; self.defaultProvider = defaultProvider; self.display = display
        self.firstArrivalConfirmed = firstArrivalConfirmed; self.fullAccess = fullAccess; self.projects = projects
        var loaded: [String: Set<String>] = [:]
        if let historyFile, let data = try? Data(contentsOf: historyFile), let saved = try? JSONDecoder().decode([String: [String]].self, from: data) {
            loaded = saved.mapValues { Set($0) }
        }
        names = loaded
    }

    // MARK: rules (pure)

    static func validID(_ id: String) -> Bool { id.utf8.count <= 40 && id.range(of: #"\A[a-z0-9][a-z0-9-]*\z"#, options: .regularExpression) != nil }
    private static func same(_ a: NativeRPCValue, _ b: NativeRPCValue) -> Bool {
        CloudBrainRecordAdapter.equal(a.isNullish ? NativeRPCValue.null : a, b.isNullish ? NativeRPCValue.null : b)
    }
    /// Why a name from another device is not taken on this Mac, or nil when it may be (Decker's ruling of 12 Nov on the
    /// Security addendum to Ruling 3). A mention is found as text containing "@" + name, so a SHORTER name answers to
    /// a longer one's mentions. The danger is an agent that would capture mentions meant for someone else. After the
    /// one-plain-line filter, and without regard to case, a name is refused when:
    ///  (a) it equals a reserved name (hoot, me) or is the beginning of one: it would answer to @hoot or @me;
    ///  (b) it equals, or is the beginning of, the name of a DIFFERENT agent on this Mac (another id): it would
    ///      answer to that agent's mentions;
    ///  (c) it is a rename (`rename`: this Mac already has the agent) to a name a different agent here has ever had.
    /// A name that only BEGINS WITH a reserved name or with another agent's name ("Memory", "Reviewer" beside "Review")
    /// is accepted: it arrives with the roster it already lives with, and the page says so once (`alsoAnswers`).
    static func nameProblem(_ name: String, agent id: String, others: [String: String], history: [String: Set<String>], rename: Bool) -> String? {
        guard name == name.trimmingCharacters(in: .whitespacesAndNewlines), name.utf16.count <= 60, BackendCloudLeanProjects.plainLine(name, maximum: 240) else {
            return "The name set on another device is not one plain line."
        }
        let lower = name.lowercased()
        for reserved in reservedNames where reserved.hasPrefix(lower) {
            return "The name set on another device would answer to mentions of \"\(reserved)\"."
        }
        for other in others.keys.sorted() where other != id {
            if let theirs = others[other], theirs.lowercased().hasPrefix(lower) {
                return "The name set on another device would answer to mentions of another agent on this Mac (\(theirs))."
            }
        }
        if rename {
            for other in history.keys.sorted() where other != id {
                if history[other]?.contains(lower) == true { return "The name set on another device was once the name of another agent on this Mac." }
            }
        }
        return nil
    }
    /// For a name that was accepted although it begins with a reserved name or with another agent's name on this Mac:
    /// the one line the page shows, for example "'Review' also answers to mentions of 'Reviewer'". nil when none.
    static func alsoAnswers(_ name: String, agent id: String, others: [String: String]) -> String? {
        let lower = name.lowercased()
        var shorter: [String] = []
        for reserved in reservedNames where lower != reserved && lower.hasPrefix(reserved) { shorter.append(reserved) }
        for other in others.keys.sorted() where other != id {
            if let theirs = others[other], !theirs.isEmpty, lower != theirs.lowercased(), lower.hasPrefix(theirs.lowercased()) { shorter.append(theirs) }
        }
        guard !shorter.isEmpty else { return nil }
        return shorter.map { "'" + $0 + "' also answers to mentions of '" + name + "'" }.joined(separator: "; ")
    }
    private static func rank(_ status: NativeRPCValue) -> Int? {
        if status.isNullish { return 2 }
        switch status.string {
        case "active"?: return 2
        case "paused"?: return 1
        case "archived"?: return 0
        default: return nil
        }
    }
    /// What a new agent takes from its source at first arrival, and nothing more.
    /// The seat may take part in choosing which login the agent runs under, but only among THIS Mac's own logins by
    /// THIS Mac's own seat mapping: no login, account or key ever comes from the other Mac (lead's ruling, 13 Nov).
    static let firstArrivalFields: Set<String> = ["projectId", "seat"]
    /// THE RULE for a widening-class field that came from another device (Decker's ruling of 12 Nov on Security's
    /// Ruling 3; the Security seat's first ruling asks ONE confirmation for a first restore on a new Mac, and lane A's
    /// new-Mac sheet, pressed in this Mac's own window, is that confirmation).
    ///
    /// 1. The same value, or a narrower one, always applies.
    /// 2. FIRST ARRIVAL (`firstArrival` true: no agent with this id was EVER on this Mac, and the person confirmed this
    ///    Mac's set-up from the Cloud): the agent's PROJECT and SEAT are taken as on the source, in one step with the
    ///    rest of its record. `local` is then what a fresh agent would launch with on this Mac.
    /// 3. Everything else waits on this Mac, at first arrival too: a permission mode wider than this Mac's default
    ///    (the agent is created at the default), tools or skills added beyond this Mac's defaults, another AI or
    ///    agent definition, run limits above this Mac's, a paused agent switched on. An account never travels at all.
    /// 4. Once the agent is on this Mac, every later change to its project, seat or any other widening field from
    ///    another device waits (`firstArrival` is false from then on).
    /// 0. Y2: with FULL ACCESS (the device-trust setting at its default, "Automatically, with my account") every field
    ///    from the account's own trusted devices applies, at first arrival and later. The sync core applies nothing
    ///    from a device this Mac does not trust, and fields that are this Mac's own (its login, paths) never travel.
    static func mayApply(_ field: String, cloud: NativeRPCValue, local: NativeRPCValue, firstArrival: Bool, defaultProvider: String, fullAccess: Bool = false) -> Bool {
        if fullAccess { return true }
        if narrowerOrEqual(field, cloud: cloud, local: local, defaultProvider: defaultProvider) { return true }
        return firstArrival && firstArrivalFields.contains(field)
    }
    /// May a widening-class value from another device replace this Mac's value? Only when it is the same or narrower.
    /// Anything the comparison does not understand counts as wider (design v2 D10.4). The directions for the tool,
    /// permission and run-limit fields are the app's own (`BackendTAGProfilePolicy.validate`), not a second copy.
    static func narrowerOrEqual(_ field: String, cloud: NativeRPCValue, local: NativeRPCValue, defaultProvider: String) -> Bool {
        let before = local[field], after = cloud
        if same(before, after) { return true }
        switch field {
        case "toolUseRestrictions", "blockedTools", "skillsOff", "allowedTools", "permissionMode", "keepAliveUntilClose", "keepAliveMinutes",
             "maxConcurrent", "maxRunMinutes":
            let input = NativeRPCValue.object([.init(field, after.isNullish ? .null : after)])
            return (try? BackendTAGProfilePolicy.validate(input: input, existing: local)) != nil
        case "provider":
            return (after.string ?? defaultProvider) == (before.string ?? defaultProvider) && (after.isNullish || after.string != nil)
        case "skills":
            guard after.isNullish || after.elements != nil else { return false }
            let had = Set((before.elements ?? []).compactMap { $0.string }), wants = (after.elements ?? []).map { $0.string }
            return wants.allSatisfy { $0.map { had.contains($0) } ?? false }
        case "status":
            guard let was = rank(before), let next = rank(after) else { return false }
            return next <= was
        default:
            // A different login seat, project or agent definition: never from another device.
            return false
        }
    }
    private static func instruction(_ id: String, _ text: String) -> NativeRPCValue {
        .object([.init("id", .string(id)), .init("text", .string(text))])
    }
    private static func travelling(_ row: NativeRPCValue) -> NativeRPCValue {
        CloudBrainRecordAdapter.travelling(row, table: agentKind.table)
    }
    private func remember(_ id: String, _ name: String) {
        guard names[id, default: []].insert(name.lowercased()).inserted, let historyFile else { return }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(names.mapValues { $0.sorted() }) else { return }
        try? FileManager.default.createDirectory(at: historyFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: historyFile, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: historyFile.path)
    }
    private func readRoster() async throws -> [(row: NativeRPCValue, instructions: String)] {
        do { return try await config.cloudLeanRoster() }
        catch { throw CloudRecordRefusal(reason: "The saved agents on this Mac cannot be read right now.") }
    }

    // MARK: CloudBrainRecordOwner

    public func cloudRecords() async throws -> [String: NativeRPCValue] {
        let roster = try await config.cloudLeanRoster()
        if let hook = afterRosterRead { await hook() }
        var result: [String: NativeRPCValue] = [:]
        for entry in roster {
            guard let id = entry.row["id"].string else { continue }
            let entity = Self.instructionKind.entity(id), value = Self.instruction(id, entry.instructions)
            let file = try await config.cloudLeanInstructionURL(id)
            let missing = file.map { !FileManager.default.fileExists(atPath: $0.path) } ?? false
            let previouslyPresent = try deletes.lastSeen(entity) != nil
            let restoring = try deletes.restoring(entity)
            if !missing || !previouslyPresent || restoring {
                if try deletes.mark(entity) != nil, !missing {
                    let newest = try deletes.newest(entity, table: Self.instructionTable)
                    let old = try deletes.priorValues(entity, table: Self.instructionTable)
                    if let newest, entry.instructions != newest["text"].string,
                       old.contains(where: { $0["text"].string == entry.instructions }) {
                        try await config.cloudLeanWrite(row: nil, instructionsFor: id, text: newest["text"].string ?? "")
                        try deletes.clearMark(entity)
                        result[entity] = newest
                    } else { try deletes.clearMark(entity); result[entity] = value }
                } else { result[entity] = value }
                try deletes.save(entity, result[entity] ?? value)
                try deletes.rememberVersion(entity, result[entity] ?? value)
                if !missing { try deletes.seen(entity, at: Int64(now().timeIntervalSince1970 * 1000)) }
                gone[entity] = nil
            }
            let agentEntity = Self.agentKind.entity(id)
            // Lead decision 1 (review A1): the roster above is a snapshot taken before awaits. An agent in it that also
            // has a Bin copy is PUT BACK only when no delete intent exists for it, it is still on this Mac now, and the
            // Bin copy is still the one seen here (checked and taken under one lock). A delete made while this pass
            // runs therefore keeps its Bin copy and its removal travels at the next pass.
            if let group = try deletes.binnedGroup(agentEntity), try deletes.intent(agentEntity) == nil,
               try deletes.intent(entity) == nil, try await config.agent(id) != nil {
                _ = try deletes.takeRestoredBin(agentEntity, also: entity, companionValue: value, group: group)
            }
            result[agentEntity] = entry.row
            if let name = entry.row["name"].string { remember(id, name) }
        }
        return result
    }
    public func cloudPlan(entity: String, cloud: NativeRPCValue?) async throws -> CloudBrainRecordPlan {
        let roster = try await readRoster()
        if Self.instructionKind.id(of: entity) != nil, let cloud { try deletes.rememberVersion(entity, cloud) }
        if let mark = try deletes.mark(entity) { return .init(store: nil, waiting: mark.mark.title) }
        if let id = Self.instructionKind.id(of: entity) {
            if let path = try await config.cloudLeanInstructionURL(id),
               try deletes.lastSeen(entity) != nil,
               !FileManager.default.isReadableFile(atPath: path.deletingLastPathComponent().path) {
                return .init(store: nil, waiting: "Your agent instructions folder is not on this Mac")
            }
            if cloud == nil, let removal = try deletes.merged(entity, table: Self.instructionTable)?.shown(),
               removal["deletedWithAgent"].bool == true, let group = removal["deletedGroup"].string,
               !(try deletes.removalSeen(Self.agentKind.entity(id), group: group, table: Self.agentKind.table)) {
                removalWaits[id] = group
                return .init(store: nil, waiting: "These instructions follow their agent's removal.")
            }
            removalWaits[id] = nil
            return planInstruction(id, cloud: cloud, roster: roster)
        }
        guard let id = Self.agentKind.id(of: entity) else { throw CloudRecordRefusal(reason: "This is not an agent record.") }
        return try await planAgent(id, cloud: cloud, roster: roster)
    }
    private func planInstruction(_ id: String, cloud: NativeRPCValue?, roster: [(row: NativeRPCValue, instructions: String)]) -> CloudBrainRecordPlan {
        let current = roster.first { $0.row["id"].string == id }
        let kept = current.map { Self.instruction(id, $0.instructions) }
        guard let cloud else { return .init(store: nil) }
        guard Self.validID(id) else { return .init(store: kept, waiting: "This instruction file's name is not an agent id this Mac can use.") }
        // The text is written when its agent is on this Mac: a text without its agent is kept, not placed.
        guard current != nil else { return .init(store: nil, waiting: "These instructions wait for their agent to be added on this Mac.") }
        guard let text = cloud["text"].string, text.utf16.count <= 32_000, !text.contains("\0") else {
            return .init(store: kept, held: ["text": "The instructions set on another device are too long for this Mac or are not text."])
        }
        return .init(store: Self.instruction(id, text.trimmingCharacters(in: .whitespacesAndNewlines)))
    }
    private func planAgent(_ id: String, cloud: NativeRPCValue?, roster: [(row: NativeRPCValue, instructions: String)]) async throws -> CloudBrainRecordPlan {
        let current = roster.first { $0.row["id"].string == id }?.row
        let kept = current.map { Self.travelling($0) }
        guard let cloud else { return .init(store: nil) }
        guard Self.validID(id) else { return .init(store: kept, waiting: "This agent's id is not one this Mac can use.") }
        // The merge's existence field already resolved ancestry: a later/concurrent edit wins a removal.
        // A previously removed agent is restored normally; it is restored when ancestry keeps an edit.
        var held: [String: String] = [:]
        let retired = try deletes.binnedValue(Self.agentKind.entity(id))?["row"]
        var row = current ?? (retired?.fields == nil ? nil : retired) ?? NativeRPCValue.object([.init("id", .string(id))])

        // 1. The name decides who an @name mention reaches (Ruling 3 addendum).
        var others: [String: String] = [:]
        for entry in roster {
            if let other = entry.row["id"].string, other != id, let name = entry.row["name"].string { others[other] = name }
        }
        if cloud.has("name"), cloud["name"].string != current?["name"].string {
            let theirs = cloud["name"].string ?? ""
            if let problem = Self.nameProblem(theirs, agent: id, others: others, history: names, rename: current != nil) {
                held["name"] = problem
            } else {
                row = row.setting("name", .string(theirs))
            }
        }
        guard let name = row["name"].string, current != nil || held["name"] == nil else {
            return .init(store: nil, waiting: "This agent is not added on this Mac. " + (held["name"] ?? "It has no name."))
        }
        // A name taken from the Cloud that begins with another name here is listed once, not refused.
        let note = cloud["name"].string == name ? Self.alsoAnswers(name, agent: id, others: others) : nil

        // 2. Plain shared fields: newest wins (the merge decided), listed as changed from another device.
        for field in Self.sharedFields where cloud.has(field) {
            let value = cloud[field]
            if field == "model", let model = value.string, !CloudBrainMergeTables.isValidModel(model) {
                held[field] = "The model set on another device is not a model name this Mac accepts."
                continue
            }
            row = value.isNullish ? row.removing(field) : row.setting(field, value)
        }

        // 3. Widening fields, by the one rule (`mayApply`). An agent new to this Mac is compared with what a fresh
        //    agent would launch with here, and takes its project and seat once the person confirmed this Mac's set-up.
        let fallback = await defaultProvider()
        // First arrival only for an id this Mac has NEVER held (`names` keeps every agent id seen here, at every
        // capture and every Cloud write, and is kept on disk): "not here now" is not "never here".
        let full = await fullAccess() == true
        var firstArrival = false
        if current == nil, names[id] == nil, full {
            // Y2: full access needs no confirmation press: signing in to the account is the confirmation.
            firstArrival = true
        } else if current == nil, names[id] == nil {
            // The trusted list cannot be read now: the agent waits whole, listed; the capture pass decides again once it
            // reads (`cloudContext`), so it is never created without the project and seat it may take.
            guard let confirmed = await firstArrivalConfirmed() else { return .init(store: nil, waiting: Self.trustUnreadable) }
            firstArrival = confirmed
        }
        // Its project must be on this Mac to be taken (review should-fix 1): agents and projects arrive through two
        // adapters in no set order. Until it is here the whole agent waits, and is listed; the capture pass looks
        // again when this Mac's project list changes (`cloudContext`). Still first arrival then: the id stays unheld.
        if firstArrival, let wanted = cloud["projectId"].string, !wanted.isEmpty, wanted != PROJProjects.independentID {
            let here = await projects()
            guard let here, here.contains(wanted) else { return .init(store: nil, waiting: Self.projectNotHere) }
        }
        let base: NativeRPCValue
        if let current { base = current } else if let retired, retired.fields != nil { base = retired } else {
            do { base = try await config.cloudLeanClean(.object([.init("id", .string(id)), .init("name", .string(name))])) }
            catch let error as NativeRPCError { return .init(store: nil, waiting: "This agent is not added on this Mac. " + error.message) }
            catch { throw CloudRecordRefusal(reason: "The saved agents on this Mac cannot take this agent right now.") }
        }
        for field in Self.wideningFields where cloud.has(field) {
            if Self.mayApply(field, cloud: cloud[field], local: base, firstArrival: firstArrival, defaultProvider: fallback, fullAccess: full) {
                row = cloud[field].isNullish ? row.removing(field) : row.setting(field, cloud[field])
                if field == "status" { row = cloud["statusAt"].isNullish ? row.removing("statusAt") : row.setting("statusAt", cloud["statusAt"]) }
            } else {
                held[field] = Self.waitingReason
                if field == "status" { held["statusAt"] = Self.waitingReason }
            }
        }

        // 4. Exactly as a save would store it. What does not fit this Mac is not applied, and is listed.
        do {
            let cleaned = try await config.cloudLeanClean(row)
            return .init(store: Self.travelling(cleaned), held: held, note: note)
        } catch let error as NativeRPCError where error.code != "not-started" {
            guard let current, let kept else { return .init(store: nil, waiting: "This agent is not added on this Mac. " + error.message) }
            var all: [String: String] = [:]
            for field in ["name"] + Self.sharedFields + Self.wideningFields where cloud.has(field) && !Self.same(cloud[field], current[field]) {
                all[field] = held[field] ?? ("Not applied on this Mac: " + error.message)
            }
            return .init(store: kept, held: all)
        } catch {
            throw CloudRecordRefusal(reason: "The saved agents on this Mac cannot take this agent right now.")
        }
    }
    public func cloudWrite(entity: String, value: NativeRPCValue, expecting: NativeRPCValue?) async throws {
        let roster = try await config.cloudLeanRoster()
        let changed = CloudRecordRefusal(reason: "This agent changed on this Mac while a change from another device was being applied; it is applied on the next try.")
        if let id = Self.instructionKind.id(of: entity) {
            let current = roster.first { $0.row["id"].string == id }
            guard let text = value["text"].string, current != nil else { throw CloudFailure.invalidRequest }
            guard CloudBrainRecordAdapter.equal(current.map { Self.instruction(id, $0.instructions) }, expecting) else { throw changed }
            do { try await config.cloudLeanWrite(row: nil, instructionsFor: id, text: text) }
            catch let error as NativeRPCError where error.code != "not-started" { throw Self.refusal(error) }
            return
        }
        guard let id = Self.agentKind.id(of: entity) else { throw CloudFailure.invalidRequest }
        let current = roster.first { $0.row["id"].string == id }?.row
        guard CloudBrainRecordAdapter.equal(current.map { Self.travelling($0) }, expecting) else { throw changed }
        // Lead decision 1: an agent deleted here whose removal has not been sent yet is never brought back from its Bin
        // copy by an arriving change; the removal is captured first and the merge then decides by ancestry.
        if current == nil, try deletes.intent(Self.agentKind.entity(id)) != nil {
            throw CloudRecordRefusal(reason: "This agent was removed on this Mac and its removal is being sent; the change from another device is looked at again after it.")
        }
        // The row as this Mac keeps it (its own fields untouched) with the planned travelling fields, cleaned as a save.
        let retired = try deletes.binnedValue(Self.agentKind.entity(id))?["row"]
        var row = current ?? (retired?.fields == nil ? nil : retired) ?? NativeRPCValue.object([.init("id", .string(id))])
        for name in CloudBrainMergeTables.agent.classes.keys.sorted() where CloudBrainMergeTables.agent.classes[name] != .thisMac {
            row = value.has(name) ? row.setting(name, value[name]) : row.removing(name)
        }
        // This Mac's own rules refusing the row at the last moment (a local rename landed between plan and write, for
        // example "Another agent is already called X") is "cannot apply this one", not "broken" (review should-fix 2):
        // the sync core parks this record and the pack moves on.
        let cleaned: NativeRPCValue
        do {
            cleaned = try await config.cloudLeanClean(row)
            try await config.cloudLeanWrite(row: cleaned, instructionsFor: nil, text: "")
        } catch let error as NativeRPCError where error.code != "not-started" {
            throw Self.refusal(error)
        }
        // Put back only: an agent this Mac held before (a Bin copy here, or an id seen here) gets its text with it. A
        // FIRST arrival leaves its instructions to their own record, as before the delete rule: written here, that
        // record would never be placed on this Mac and its next edit here would travel as a joining copy and lose.
        let binned = try deletes.binnedValue(Self.agentKind.entity(id))
        if current == nil, binned != nil || names[id] != nil {
            let entity = Self.instructionKind.entity(id)
            let newest = try deletes.newest(entity, table: Self.instructionTable)
            let retired = binned
            if let text = newest?["text"].string ?? retired?["text"].string {
                try await config.cloudLeanWrite(row: nil, instructionsFor: id, text: text)
                if newest == nil { try deletes.save(entity, Self.instruction(id, text), restoring: true) }
            }
        }
        if let name = cleaned["name"].string { remember(id, name) }
    }
    static func refusal(_ error: NativeRPCError) -> CloudRecordRefusal {
        CloudRecordRefusal(reason: "Not applied on this Mac: " + error.message + " It is tried again later.")
    }
    public func cloudImported(_ entities: [String]) async { await display() }
    /// What a waiting agent's plan depends on outside its own row: whether the trusted list reads and what it says,
    /// and this Mac's project ids.
    public func cloudContext() async -> String {
        // Y2: a change of the device-trust setting (or the first pass after a launch) looks at held agents again, so
        // what was held under "Ask" is applied by itself under "Automatically, with my account".
        let access: String
        switch await fullAccess() {
        case true?: access = "access:full "
        case false?: access = "access:ask "
        case nil: access = "access:? "
        }
        let trust: String
        switch await firstArrivalConfirmed() {
        case true?: trust = "trust:yes"
        case false?: trust = "trust:no"
        case nil: trust = "trust:?"
        }
        guard let here = await projects() else { return access + trust + " projects:?" }
        let removalContext = removalWaits.keys.sorted().map { id in
            let seen = (try? deletes.removalSeen(Self.agentKind.entity(id), group: removalWaits[id] ?? "", table: Self.agentKind.table)) == true
            return id + (seen ? ":seen" : ":waiting")
        }.joined(separator: ",")
        return access + trust + " removals:" + removalContext + " projects:" + here.sorted().joined(separator: ",")
    }

    /// The adapter for this owner and one signed-in account. Lane A's wiring registers it through
    /// `CloudBrainRecordActivation`; nothing here registers itself.
    public nonisolated func adapter(store: CloudBrainAgentsStore, account: CloudBrainAgentsAccount, origins: CloudBrainRecordOrigins) throws -> CloudBrainRecordAdapter {
        try deletes.bind(store: store, account: account)
        return try CloudBrainRecordAdapter(domain: Self.domain, inventoryRow: Self.inventoryRow, sourceId: Self.sourceID, kinds: Self.kinds, store: store,
            account: account, owner: self, origins: origins, exclusions: Self.exclusions)
    }
    /// `serviceTime`: the sync engine's service clock (`engine.serviceTime()`); the keeper Bin ages by it only.
    public nonisolated func configureDeleteRule(gate: @escaping @Sendable () async -> Bool, macNames: @escaping @Sendable (String) async -> String,
                                                serviceTime: (@Sendable () -> Int64?)? = nil) {
        deletes.configure(gate: gate, macNames: macNames, serviceTime: serviceTime)
    }
    public func cloudLocalOnly(entity: String) async throws -> Bool { try deletes.mark(entity) != nil }
    public func cloudRestoring(entity: String) async throws -> Bool { try deletes.restoring(entity) }
    public func cloudCaptured(entity: String, removed: Bool) async throws { try deletes.captured(entity, removed: removed) }
    public func cloudPendingRemovals() async throws -> [String] {
        try deletes.pending(prefix: "agent:") + deletes.pending(prefix: "instruction:")
    }
    public func cloudRemovalBase(entity: String) async throws -> NativeRPCValue? {
        if Self.agentKind.id(of: entity) != nil { return try deletes.binnedValue(entity)?["row"] }
        if let id = Self.instructionKind.id(of: entity), let saved = try deletes.binnedValue(Self.agentKind.entity(id)) {
            return Self.instruction(id, saved["text"].string ?? "")
        }
        if let id = Self.instructionKind.id(of: entity), let saved = try deletes.binnedValue(entity) {
            return Self.instruction(id, saved["text"].string ?? "")
        }
        return try deletes.saved(entity)
    }
    public func cloudMissing(entity: String, last: NativeRPCValue) async throws -> CloudBrainRecordMissing {
        // A delete intent wins over a put-back flag left from before it (lead decision 1).
        var intent = try deletes.intent(entity)
        if try deletes.mark(entity) != nil || (intent == nil && deletes.restoring(entity)) { return .keep }
        if intent == nil, let id = Self.instructionKind.id(of: entity), let path = try await config.cloudLeanInstructionURL(id) {
            guard try await config.agent(id) != nil, !FileManager.default.fileExists(atPath: path.path) else { return .keep }
            // A missing/unreadable root is never evidence against one instruction file.
            var directory: ObjCBool = false
            let parent = path.deletingLastPathComponent()
            guard FileManager.default.fileExists(atPath: parent.path, isDirectory: &directory), directory.boolValue,
                  FileManager.default.isReadableFile(atPath: parent.path) else { return .keep }
            let now = now()
            guard let first = gone[entity] else { gone[entity] = now; return .keep }
            guard now.timeIntervalSince(first) >= 3 else { return .keep }
            let answer = await witness.who(removed: path, lastSeen: try deletes.lastSeen(entity) ?? first, seenGoneAt: now)
            if case .ai(let session, let agent, _, let group) = answer {
                let local = deletes.actor()
                let actor = CloudDeleteActor(by: .ai, mac: local.mac, macName: local.macName, session: session, agent: agent, at: deletes.now(), group: group)
                try await config.cloudLeanRemoveInstructions(id, previous: last["text"].string ?? "", actor: actor, intended: true)
                intent = actor.intent(place: entity, scope: .everywhere)
            } else {
                try deletes.save(entity, last)
                try deletes.mark(entity, .notOnThisMac, at: deletes.now())
                return .keep
            }
        }
        guard let intent else { return .keep }
        let open = await deletes.isOpen()
        let name = await deletes.macName(intent.mac)
        guard open, UUID(uuidString: intent.group) != nil else { return .remove(metadata: nil) }
        var metadata = RecordsDeleteLedger.metadata(intent, macName: name)
        if let id = Self.instructionKind.id(of: entity),
           try deletes.binRows(kind: "agent").contains(where: { $0.item.id == Self.agentKind.entity(id) && $0.actor.group == intent.group }) {
            metadata = metadata.setting("deletedWithAgent", .bool(true))
        }
        return .remove(metadata: metadata)
    }
    public func cloudTombstone(entity: String, removal: NativeRPCValue, device: String, at: Int64) async throws {
        guard let id = Self.instructionKind.id(of: entity), let saved = try deletes.saved(entity),
              let row = try await config.agent(id) else { return }
        let file = try await config.cloudLeanInstructionURL(id)
        let missing = file.map { !FileManager.default.fileExists(atPath: $0.path) } ?? false
        guard try deletes.mark(entity) != nil || missing else { return }
        let actor = try await deletes.arriving(removal, entity: entity, device: device, at: at)
        if try deletes.binRows(kind: "agent").contains(where: { $0.item.id == Self.agentKind.entity(id) && $0.actor.group == actor.group }) { return }
        try deletes.putBin(kind: "agent", entity: entity, name: (row["name"].string ?? "Agent") + " instructions",
            value: .object([.init("row", row.removing("instructions").removing("instructionsFile")), .init("text", saved["text"]), .init("instructionOnly", .bool(true))]), actor: actor)
    }
    public func cloudRemove(entity: String, expecting: NativeRPCValue?, removal: NativeRPCValue, device: String, at: Int64) async throws {
        if try deletes.mark(entity) != nil { return }
        let roster = try await readRoster()
        let actor = try await deletes.arriving(removal, entity: entity, device: device, at: at)
        if let id = Self.agentKind.id(of: entity) {
            let current = roster.first { $0.row["id"].string == id }
            guard CloudBrainRecordAdapter.equal(current.map { Self.travelling($0.row) }, expecting) else { throw CloudRecordRefusal(reason: "This agent changed while its removal arrived.") }
            if current != nil { try await config.cloudLeanRemoveAgent(id, actor: actor) }
        } else if let id = Self.instructionKind.id(of: entity) {
            guard let current = roster.first(where: { $0.row["id"].string == id }) else { return }
            guard CloudBrainRecordAdapter.equal(Self.instruction(id, current.instructions), expecting) else { throw CloudRecordRefusal(reason: "These instructions changed while their removal arrived.") }
            if removal["deletedWithAgent"].bool == true,
               try deletes.newest(Self.agentKind.entity(id), table: Self.agentKind.table) != nil {
                // The row's ancestry kept an edit. Its bundled instruction removal loses with the row's removal.
                try deletes.save(entity, Self.instruction(id, current.instructions), restoring: true)
                return
            }
            try await config.cloudLeanRemoveInstructions(id, previous: current.instructions, actor: actor)
        }
    }
    public func deleteItems(_ items: [CloudDeleteItem], scope: CloudDeleteScope, by actor: CloudDeleteActor) async throws -> CloudBinGroup {
        var removed: [CloudDeleteItem] = []
        for item in items {
            let id = Self.agentKind.id(of: item.id) ?? item.id
            guard let row = try await config.agent(id) else { continue }
            try await config.removeAgent(id, deletedBy: actor)
            removed.append(.init(id: Self.agentKind.entity(id), kind: "agent", name: row["name"].string ?? item.name))
        }
        return .init(id: actor.group, by: actor.by, macName: actor.macName, session: actor.session, agent: actor.agent, at: actor.at, items: removed)
    }
    public func bringBack(_ items: [CloudDeleteItem], to: CloudBringBackDestination) async throws -> [CloudDeleteItem] {
        for item in items {
            guard let id = Self.instructionKind.id(of: item.id) else { continue }
            let value = try deletes.newest(item.id, table: Self.instructionTable)
            try await config.cloudLeanWrite(row: nil, instructionsFor: id, text: value?["text"].string ?? "")
            try deletes.clearMark(item.id)
        }
        return items
    }
    public func notHere() async throws -> [CloudNotHereItem] {
        var result: [CloudNotHereItem] = []
        let roster = try await readRoster()
        for mark in try deletes.marks() {
            guard let id = Self.instructionKind.id(of: mark.place), let agent = roster.first(where: { $0.row["id"].string == id }) else { continue }
            result.append(.init(item: .init(id: mark.place, kind: "agent", name: (agent.row["name"].string ?? "Agent") + " instructions"), mark: mark.mark, at: mark.at))
        }
        return result
    }
    public func binGroups() async throws -> [CloudBinGroup] {
        RecordsDeleteLedger.groups(try deletes.binRows(kind: "agent").map { ($0.item, $0.actor) })
    }
    public func putBackGroup(_ group: String) async throws -> [CloudDeleteItem] { try await putBackAll(group).restored }
    /// "Put back all" (lead decision 4): the owner's one way back from a large AI delete. Every item is tried; one that
    /// fails never stops the rest, and the answer names what came back and what did not. An agent comes back with
    /// what its delete cleared: who reported to it and the connection identities that named it.
    public func putBackAll(_ group: String) async throws -> RecordsPutBackAnswer {
        var restored: [CloudDeleteItem] = [], failed: [CloudDeleteItem] = []
        for entry in try deletes.binRows(kind: "agent") where entry.actor.group == group {
            do {
                try await putBack(entry.value)
                try deletes.takeBin(entry.item.id)
                restored.append(entry.item)
            } catch { failed.append(entry.item) }
        }
        await display()
        return .init(restored: restored, notRestored: failed)
    }
    private func putBack(_ saved: NativeRPCValue) async throws {
        let row = saved["row"]
        guard let id = row["id"].string else { throw CloudFailure.invalidRequest }
        let only = saved["instructionOnly"].bool == true
        try await config.cloudLeanWrite(row: only ? nil : row, instructionsFor: id, text: saved["text"].string ?? "")
        for entity in [Self.agentKind.entity(id), Self.instructionKind.entity(id)] {
            try deletes.clearIntent(entity); try deletes.clearMark(entity)
            try deletes.save(entity, entity.hasPrefix("agent:") ? .bool(true) : Self.instruction(id, saved["text"].string ?? ""), restoring: true)
        }
        guard !only else { return }
        let reports = (saved["reports"].elements ?? []).compactMap(\.string)
        let identities = (saved["identities"].elements ?? []).compactMap { link -> (keyId: String, field: String)? in
            guard let key = link["keyId"].string, let field = link["field"].string else { return nil }
            return (key, field)
        }
        if !reports.isEmpty || !identities.isEmpty { try await config.cloudLeanRestoreLinks(id, reports: reports, identities: identities) }
    }
    public func deleteForGood(_ items: [CloudDeleteItem]) async throws {
        for item in items {
            try deletes.takeBin(item.id, permanently: true)
            if try deletes.mark(item.id) == nil { try deletes.clearSaved(item.id) }
        }
    }

}
