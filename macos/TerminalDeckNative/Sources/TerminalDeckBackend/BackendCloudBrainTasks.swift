import Foundation
import os
import TerminalDeckNativeCore

public enum BackendCloudBrainTasks {
  /// `projects` names task folders by projectId/rootId (finding 11); without it tasks keep only their historical path.
  public static func adapter(owner: BackendTaskStore, account: CloudBrainAgentsAccount, projects: BackendPROJRegistry?) -> CloudBrainAgentsAdapter {
    @Sendable func roots() async throws {
      guard let projects else { return }
      try await projects.cloudAttach(account)
      await owner.cloudSetProjectRoots(try await projects.cloudProjectRoots())
    }
    return .init(row: "I12", domains: ["tasks"], owner: .init(
      inventory: { try await owner.cloudAttach(account); return try await owner.cloudTaskInventory() },
      snapshot: { cut in try await owner.cloudAttach(account); try await roots(); return try await owner.cloudTaskSnapshot(cut: cut) },
      apply: { incoming in try await owner.cloudAttach(account); try await roots(); return try await owner.cloudTaskImport(incoming) },
      retained: { try await owner.cloudTaskRetained($0) },
      ownChanges: { try await owner.cloudTaskOwnChanges(after: $0, limit: $1) },
      cursor: { try await owner.cloudTaskCursor() },
      saveCursor: { try await owner.cloudTaskSaveCursor($0) },
      notices: { await owner.cloudTaskNotices() },
      detach: { await owner.cloudDetach() }))
  }
}

/// Lane L3 (14 Nov): this Mac's OWN tasks in the Cloud (row I12), on the one record rule: title, state, text, labels,
/// dates, its project and its comments travel; per field the newest wins; comments merge one by one, so two Macs adding
/// comments both keep theirs; a joining Mac's first copy loses and the value replaced is kept.
/// What never travels: who a task is assigned to, its running session, its folder path and everything else the signed
/// task table marks "this Mac" (a task arrives on another device stopped and unassigned: nothing starts from the Cloud).
/// Tasks from a CONNECTED task system (iLoop and the like, every task whose `local` is not true) are that system's data:
/// each Mac gets them from the system itself, so they are never sent and never applied from the Cloud.
///
/// Tasks everywhere (15 Nov 2026, owner: "every small thing to be synced"), while the delete rule's gate is open:
/// who a task is assigned to, its parent/child and review links, its board, page details (checklists, subtasks,
/// comments, files that are links, activity, time) and which Mac works it also travel. An arriving assignment is
/// INFORMATION: it never starts a session, wakes an agent or changes the task's state here (the arriving-assignment
/// guard in `compose`). The connections to connected task systems travel too (their tokens only inside saved
/// passwords); each Mac fetches the system's tasks itself.
public actor BackendCloudKindsTasks: CloudBrainRecordOwner, CloudDeleteOwning {
    public static let domain = "tasks"
    public static let inventoryRow = "I12"
    public static let sourceID = "task-list"
    public static let table = CloudBrainMergeTables.tasksEverywhere(CloudBrainMergeTables.recordsDeleteRule(CloudBrainMergeTables.task, partner: "place"))
    public static let kind = CloudBrainRecordKind(prefix: "task:", table: table, listedValues: ["title"])
    /// A connected task system's connection (connected-tasks.json), never its token.
    public static let systemKind = CloudBrainRecordKind(prefix: "task-system:", table: CloudBrainMergeTables.taskSystem, listedValues: ["name"])
    /// A CRM task link (task-config.json), name and on/off only: shown on the other Macs as a plain line.
    public static let linkKind = CloudBrainRecordKind(prefix: "task-link:", table: CloudBrainMergeTables.taskLink, listedValues: ["name"])
    /// A task a CRM task link sent to this Mac, shown on his other Macs as a read-only, never-started copy.
    public static let crmKind = CloudBrainRecordKind(prefix: "crm-task:", table: CloudBrainMergeTables.crmTask, listedValues: ["title"])
    public static let localKey = "local"
    /// The project a task belongs to, kept on this Mac when the project has no folder here yet (never sent).
    static let refField = "cloudProjectRef"
    /// The name of the Mac working the task (from the device list), on this Mac only; the card shows it.
    public static let workingOnNameField = "workingOnName"
    /// Parts of a task's page details that stay on the Mac that has them: delivery receipts of comments to agent
    /// sessions here, the repeat schedule (the Mac holding it makes the next copy, which then travels) and reminders
    /// (they fire on the Mac they were set on). Uploaded files stay too (their bytes are in this Mac's task folder).
    public static let detailLocalKeys = ["commentMeta", "reminders", "routine", "recurrenceRule", "routineError", "routineVersion", "occurrences", "nextId"]
    public static let exclusions = [
        "Tasks a connected task system (for example iLoop) sends to one Mac's own address stay on that Mac; your other devices show which Mac has them. Connected systems your Macs read themselves are connected on every Mac.",
        "Who a task is assigned to travels, but a task is worked on one Mac only: on your other devices it never starts by itself, and its card says which Mac is working on it.",
        "Files you uploaded into a task, its reminders and its repeat schedule stay on the Mac that has them.",
        "A task that needs your approval needs it on every Mac; a copy saying it does not never turns approval off here.",
    ]
    public static let waitsForProject = "Waits until its project is on this Mac."
    public static let connectedSystem = "This task belongs to a connected task system; this Mac gets it from that system."
    public static let workedHereLine = "This task is being worked on this Mac; who it is assigned to changes here when that work stops."

    private let store: BackendTaskStore
    private nonisolated let deletes: RecordsDeleteLedger
    private let projects: @Sendable () async -> [BackendCloudKindsProject]?
    private let display: @Sendable () async -> Void
    private let kept: BackendCloudKindsKept?
    private var localDelete: (@Sendable (String, CloudDeleteActor) async throws -> Void)?
    private var receiving: [String: (device: String, at: Int64)] = [:]
    private nonisolated let settle: BackendCloudKindsSettle
    /// Connected task systems this Mac reads itself, and this Mac's CRM task links (nil: not part of this run).
    private var systems: BackendConnectedTasksService?
    private var links: BackendTaskConfiguration?
    /// Whether the last pass read each list whole (only then can a missing one be a removal).
    private var systemsRead = false, linksRead = false, crmRead = false
    /// Tasks whose new fields this Mac may send (see `speaks`); once true it stays true.
    private var speaking = Set<String>()
    /// The plain lines about CRM task links that live on another device, for the Tasks page.
    public static let elsewhere = BackendCloudKindsElsewhere()

    public init(store: BackendTaskStore, projects: @escaping @Sendable () async -> [BackendCloudKindsProject]?,
                display: @escaping @Sendable () async -> Void = {}, kept: BackendCloudKindsKept? = nil,
                settle: BackendCloudKindsSettle = .init(quiet: 0, now: { 0 })) {
        self.deletes = store.recordDeletes
        self.store = store; self.projects = projects; self.display = display; self.kept = kept; self.settle = settle
    }

    // MARK: the shared form of a task

    /// The project a task on this Mac belongs to: the project it names itself (`projectId`, as the task list shows
    /// it), else the project whose folder holds the task's folder (the longest match), else the project it arrived
    /// with while that project has no folder here. Independent is no project.
    static func projectRef(_ row: NativeRPCValue, _ projects: [BackendCloudKindsProject]) -> NativeRPCValue? {
        if let id = row["projectId"].string, PROJProjects.isValidID(id) {
            return id == PROJProjects.independentID ? nil : .object([.init("projectId", .string(id))])
        }
        if let path = row["project"].string, !path.isEmpty {
            var best: (id: String, length: Int)?
            for project in projects {
                for folder in project.folders where !folder.isEmpty && (path == folder || path.hasPrefix(folder.hasSuffix("/") ? folder : folder + "/")) {
                    if best == nil || folder.count > best!.length { best = (project.id, folder.count) }
                }
            }
            if let best { return .object([.init("projectId", .string(best.id))]) }
        }
        if let id = row[refField]["projectId"].string, !id.isEmpty { return .object([.init("projectId", .string(id))]) }
        return nil
    }
    static func note(_ element: NativeRPCValue) -> NativeRPCValue {
        guard let fields = element.fields else { return element }
        return .object(fields.filter { CloudBrainMergeTables.noteKeys.contains($0.key) })
    }
    /// What travels of one task row: the signed table's travelling fields, where it is (list or Trash), its project.
    /// `everywhere`: the gate is open AND this Mac may send the new fields of this task (`speaks`); otherwise the
    /// record keeps the form an older Mac reads. `own`: this Mac's device id (names the Mac working the task).
    static func shared(_ row: NativeRPCValue, place: String, projects: [BackendCloudKindsProject],
                       everywhere: Bool = false, own: String? = nil) -> NativeRPCValue {
        var value = CloudBrainRecordAdapter.travelling(row, table: table).removing("place").removing("projectRef")
        value = value.setting("place", .string(place))
        if let ref = projectRef(row, projects) { value = value.setting("projectRef", ref) }
        if let notes = row["notes"].elements { value = value.setting("notes", .array(notes.map(note))) }
        if everywhere {
            if row["detail"].fields != nil { value = value.setting("detail", sharedDetail(row["detail"])) }
            // Which Mac works it: this one while a session (or Hoot's turn) for it runs here; a mark naming this Mac
            // is cleared (as null, so the clearing travels) once that work is over; another Mac's mark is kept.
            if let own, !own.isEmpty {
                if workedHere(row) { value = value.setting("workingOn", .string(own)) }
                else if let other = value["workingOn"].string, other != own {}
                else { value = value.setting("workingOn", .null) }
            }
        } else {
            for field in CloudBrainMergeTables.taskEverywhereFields { value = value.removing(field) }
        }
        return CloudBrainRecordAdapter.travelling(value, table: table)
    }
    static func isUpload(_ attachment: NativeRPCValue) -> Bool { attachment["kind"].string == "upload" }
    /// A scheduled comment not delivered yet stays on its Mac until it is posted (its delivery runs there).
    static func waitingComment(_ comment: NativeRPCValue, meta: NativeRPCValue) -> Bool {
        guard let id = comment["id"].string else { return false }
        return !meta[id]["scheduledFor"].isNullish && meta[id]["deliveredAt"].isNullish
    }
    /// A task's page details as they travel: without `detailLocalKeys`, uploaded files and comments still scheduled.
    static func sharedDetail(_ detail: NativeRPCValue) -> NativeRPCValue {
        guard detail.fields != nil else { return detail }
        var out = detail
        for key in detailLocalKeys { out = out.removing(key) }
        if let files = detail["attachments"].elements { out = out.setting("attachments", .array(files.filter { !isUpload($0) })) }
        if let comments = detail["comments"].elements {
            let meta = detail["commentMeta"]
            out = out.setting("comments", .array(comments.filter { !waitingComment($0, meta: meta) }))
        }
        return out
    }
    /// The page details this Mac stores for arriving ones: the arriving parts, plus this Mac's own local parts.
    static func mergedDetail(_ incoming: NativeRPCValue, existing: NativeRPCValue?) -> NativeRPCValue {
        guard let existing, existing.fields != nil else { return incoming }
        var out = incoming.fields != nil ? incoming : .object([])
        for key in detailLocalKeys where existing.has(key) { out = out.setting(key, existing[key]) }
        let uploads = (existing["attachments"].elements ?? []).filter(isUpload)
        if !uploads.isEmpty { out = out.setting("attachments", .array((out["attachments"].elements ?? []) + uploads)) }
        let meta = existing["commentMeta"]
        let waiting = (existing["comments"].elements ?? []).filter { waitingComment($0, meta: meta) }
        if !waiting.isEmpty {
            let ids = Set((out["comments"].elements ?? []).compactMap { $0["id"].string })
            out = out.setting("comments", .array((out["comments"].elements ?? []) + waiting.filter { !ids.contains($0["id"].string ?? "") }))
        }
        return out
    }
    /// Live state of work on a Mac: a session (or Hoot's turn) for the task runs here.
    static func workedHere(_ row: NativeRPCValue?) -> Bool {
        guard let row else { return false }
        return (!row["sessionId"].isNullish || row["hootTurnOpen"].bool == true) && row["result"].isNullish && row["stopped"].bool != true
    }
    /// Two shared values that differ only in `updatedAt` (touched by every save) are the same for settling.
    static func sameSettled(_ a: NativeRPCValue, _ b: NativeRPCValue) -> Bool {
        CloudBrainRecordAdapter.equal(a.removing("updatedAt"), b.removing("updatedAt"))
    }
    static func identity(_ id: String) -> (key: String, external: String)? {
        guard id.hasPrefix(localKey + ":") else { return nil }
        let external = String(id.dropFirst(localKey.count + 1))
        return external.isEmpty ? nil : (localKey, external)
    }
    /// The full row this Mac stores for a shared value: an existing row keeps everything that is this Mac's own; a new
    /// one is inert (stopped, unassigned) with its folder from the project's folder here, if any.
    /// `open`: the delete rule's gate is open, so the new fields (`taskEverywhereFields`) are taken; a new field the
    /// value does not carry never removes this Mac's own (an older copy simply does not know it).
    static func compose(_ value: NativeRPCValue, existing: NativeRPCValue?, projects: [BackendCloudKindsProject],
                        open: Bool = false) -> (row: NativeRPCValue, trash: Bool) {
        var row: NativeRPCValue
        if let existing { row = existing } else {
            row = .object([.init(localKey, .bool(true)), .init("assignee", .object([.init("kind", .string("none"))])), .init("sessionId", .null),
                .init("process", .string("stopped")), .init("stopped", .bool(true)), .init("project", .string(""))])
        }
        let everywhere = Set(CloudBrainMergeTables.taskEverywhereFields)
        for (name, kind) in table.classes.sorted(by: { $0.key < $1.key }) where kind != .thisMac && name != "place" && name != "projectRef" {
            if kind == .identity, let existing, existing.has(name) { continue }
            if everywhere.contains(name) {
                guard open, value.has(name) else { continue }
                row = row.setting(name, name == "detail" ? mergedDetail(value[name], existing: existing?["detail"]) : value[name])
                continue
            }
            row = value.has(name) ? row.setting(name, value[name]) : row.removing(name)
        }
        row = arrivingAssignmentGuard(row, existing: existing)
        // The project: the task names it (`projectId`, what the task list files it under) and takes the project's
        // folder on this Mac. FAULT 15 Nov (MacBook, 9 of 10 tasks under the wrong project): the folder was set only
        // on first arrival or a project change, so a task that arrived before its project had a folder here kept ""
        // forever. Now an empty folder is filled whenever the project has one here (also `fillFolders`).
        let current = existing.flatMap { projectRef($0, projects)?["projectId"].string }
        if let id = value["projectRef"]["projectId"].string, !id.isEmpty {
            row = row.setting(refField, .object([.init("projectId", .string(id))])).setting("projectId", .string(id))
            let folder = projects.first { $0.id == id }?.folders.first ?? ""
            if current != id || (row["project"].string ?? "").isEmpty { row = row.setting("project", .string(folder)) }
        } else {
            row = row.removing(refField)
            // Moved out of its project on another device: it is no longer filed (or worked) under that project here.
            // Only from a Mac on this build (gate open): an older Mac cannot name a project kept by id alone.
            if open, current != nil { row = row.setting("projectId", .string(PROJProjects.independentID)).setting("project", .string("")) }
        }
        // CLOUD-KINDS-3: a task new to this Mac gets what every newly created task gets (`BackendTaskStore.putNow`):
        // an unassigned local task may be put under his approval here.
        if existing == nil, PCDecisions.eligible(row), row["assignee"]["kind"].string == "none" { row = row.setting("decisionEligible", .bool(true)) }
        return (row, value["place"].string == "trash")
    }

    /// THE ARRIVING-ASSIGNMENT GUARD (tasks everywhere, 15 Nov). A task is worked on ONE Mac. Every way the app starts
    /// work on a task (the engine's queue `pumpQueue`, a decision release, a lead seat's sweep, start after setup, a
    /// restart continuation) needs the task's own `stopped` to be off and its `process` queued/setup; both are this
    /// Mac's own fields and never travel. When who a task is assigned to arrives from another device and differs from
    /// what this Mac has (and no work for it runs here), the task is made inert here: stopped, nothing queued, no
    /// question or Hoot turn open. A person on this Mac can still start it here himself (reply, retry, reassign).
    static func arrivingAssignmentGuard(_ row: NativeRPCValue, existing: NativeRPCValue?) -> NativeRPCValue {
        if let existing {
            guard !workedHere(existing),
                  existing["assignee"] != row["assignee"] || existing["mainAssignee"] != row["mainAssignee"] else { return row }
        }
        var inert = row.setting("stopped", .bool(true)).setting("questionOpen", .bool(false)).setting("hootTurnOpen", .bool(false))
            .removing("awaitingSetup")
        if ["queued", "setup", "running"].contains(inert["process"].string ?? "") || existing == nil { inert = inert.setting("process", .string("stopped")) }
        return inert
    }

    private func rows() async throws -> [String: (place: String, row: NativeRPCValue)] {
        var result: [String: (place: String, row: NativeRPCValue)] = [:]
        for entry in try await store.cloudKindsTasks() {
            guard let id = entry.row["id"].string else { continue }
            result[Self.kind.entity(id)] = (entry.place, entry.row)
        }
        return result
    }
    public func count() async -> Int? {
        guard let all = try? await store.cloudKindsTasks() else { return nil }
        return all.filter { $0.place == "tasks" }.count
    }

    // MARK: CloudBrainRecordOwner

    public func cloudRecords() async throws -> [String: NativeRPCValue] {
        var all = try await rows()
        let known = await projects() ?? []
        if await fillFolders(all, known: known) { all = try await rows() }
        var current: [String: NativeRPCValue] = [:]
        let open = await deletes.isOpen()
        let own = deletes.ownDevice()
        for (entity, entry) in all {
            let row = RecordsDeleteLedger.wireRow(entry.row, open: open)
            current[entity] = Self.shared(row, place: entry.place, projects: known, everywhere: open && speaks(entity), own: own)
        }
        if open {
            current.merge(await connectionRecords()) { first, _ in first }
            current.merge(await crmRecords(known: known, own: own)) { first, _ in first }
        } else { systemsRead = false; linksRead = false; crmRead = false }
        return settle.pass(current, same: Self.sameSettled)
    }

    /// May this Mac send the new fields of this task (`RecordsDeleteLedger.speaks`)? Once yes, always yes.
    private func speaks(_ entity: String) -> Bool {
        if speaking.contains(entity) { return true }
        guard deletes.speaks(entity, domain: Self.domain) else { return false }
        speaking.insert(entity)
        return true
    }
    private func markSpeaks(_ entity: String) {
        guard !speaking.contains(entity) else { return }
        speaking.insert(entity)
        try? deletes.markSpeaks(entity)
    }

    /// The folder fault, for tasks already here: a task filed under a project (it arrived with it) whose folder is
    /// empty takes the project's folder on this Mac as soon as the project has one. Only this Mac's own fields
    /// change (`project`, `projectId`), so nothing is sent; the Tasks page is refreshed.
    private func fillFolders(_ all: [String: (place: String, row: NativeRPCValue)], known: [BackendCloudKindsProject]) async -> Bool {
        var wrote = false
        for (_, entry) in all where (entry.row["project"].string ?? "").isEmpty {
            guard let id = entry.row[Self.refField]["projectId"].string, !id.isEmpty,
                  let folder = known.first(where: { $0.id == id })?.folders.first, !folder.isEmpty else { continue }
            var row = entry.row.setting("project", .string(folder))
            if row["projectId"].isNullish { row = row.setting("projectId", .string(id)) }
            if (try? await store.cloudKindsWrite(row, trash: entry.place == "trash")) != nil { wrote = true }
        }
        if wrote { await display() }
        return wrote
    }

    // MARK: connected task systems and CRM task links

    /// Hands the owner this Mac's connected task systems and CRM task links (composition, once). The person removing
    /// a connection here marks that removal to travel.
    public func setConnectedSystems(_ service: BackendConnectedTasksService?, links config: BackendTaskConfiguration?) async {
        systems = service; links = config
        let ledger = deletes
        await service?.setCloudRemoved { id in try? ledger.save("purged:" + BackendCloudKindsTasks.systemKind.entity(id), .bool(true)) }
        refreshElsewhere()
    }
    static func systemShared(_ row: NativeRPCValue) -> NativeRPCValue {
        var value = row
        if row["projectIdInferred"].bool == true { value = value.removing("projectId") }
        return CloudBrainRecordAdapter.travelling(value, table: systemKind.table)
    }
    static func linkShared(_ row: NativeRPCValue) -> NativeRPCValue {
        var value = NativeRPCValue.object([.init("keyId", row["keyId"])])
        if let name = row["name"].string { value = value.setting("name", .string(String(name.prefix(60)))) }
        value = value.setting("enabled", .bool(row["enabled"].bool == true))
        return CloudBrainRecordAdapter.travelling(value, table: linkKind.table)
    }
    static func elsewhereKey(_ entity: String) -> String { "elsewhere:" + entity }
    /// This Mac's connections and CRM links, and the links of other Macs held as they arrived (so this Mac never
    /// reports those changed or gone).
    private func connectionRecords() async -> [String: NativeRPCValue] {
        var out: [String: NativeRPCValue] = [:]
        systemsRead = false; linksRead = false
        if let systems, let rows = try? await systems.cloudConnectionRows() {
            systemsRead = true
            for row in rows { if let id = row["id"].string { out[Self.systemKind.entity(id)] = Self.systemShared(row) } }
        }
        if let links, let rows = try? await links.connectionViews() {
            linksRead = true
            for row in rows { if let key = row["keyId"].string, !key.isEmpty { out[Self.linkKind.entity(key)] = Self.linkShared(row) } }
        }
        for held in (try? deletes.savedAll(prefix: Self.elsewhereKey(Self.linkKind.prefix))) ?? [] {
            let entity = String(held.key.dropFirst(Self.elsewhereKey("").count))
            if out[entity] == nil { out[entity] = held.value["value"] }
        }
        return out
    }
    /// The plain lines for the Tasks page: one per CRM task link that sends its tasks to another Mac.
    private func refreshElsewhere() {
        let held = (try? deletes.savedAll(prefix: Self.elsewhereKey(Self.linkKind.prefix))) ?? []
        Self.elsewhere.set(held.compactMap { row -> String? in
            guard row.value["value"]["enabled"].bool != false else { return nil }
            let name = row.value["value"]["name"].string.flatMap { $0.isEmpty ? nil : $0 } ?? "A connected CRM"
            let mac = row.value["mac"].string.flatMap { $0.isEmpty ? nil : $0 } ?? RecordsDeleteLedger.unknownMac
            return "\(name) sends its tasks to \(mac) only, so they are not in this list. Open them on \(mac)."
        }.sorted())
    }
    private func systemPlan(_ id: String, cloud: NativeRPCValue?) async throws -> CloudBrainRecordPlan {
        guard let systems else { return .init(store: nil, waiting: Self.systemsNotHere) }
        guard let rows = try? await systems.cloudConnectionRows() else {
            throw CloudRecordRefusal(reason: "The connected task systems on this Mac cannot be read right now.")
        }
        let mine = rows.first { $0["id"].string == id }.map(Self.systemShared)
        guard let cloud else { return .init(store: nil) }
        guard await deletes.isOpen() else { return .init(store: mine) }
        guard cloud["id"].string == id, id.hasPrefix("cts-"), let address = cloud["url"].string, let url = URL(string: address),
              (try? BackendConnectedTasksClient.checkEndpoint(url)) != nil else {
            return .init(store: mine, waiting: Self.systemAddressRefused)
        }
        return .init(store: Self.systemShared(cloud))
    }
    private func linkPlan(_ key: String, entity: String, cloud: NativeRPCValue?) async throws -> CloudBrainRecordPlan {
        let ownRows = try? await links?.connectionViews()
        if let own = ownRows?.first(where: { $0["keyId"].string == key }) { return .init(store: Self.linkShared(own)) }
        let held = try deletes.saved(Self.elsewhereKey(entity))?["value"]
        guard let cloud else { return .init(store: nil) }
        guard await deletes.isOpen() else { return .init(store: held) }
        return .init(store: Self.linkShared(cloud))
    }
    // MARK: read-only copies of CRM tasks (the lead's decision, 15 Nov: every number and every list the same)

    static func copyKey(_ entity: String) -> String { "copy:" + entity }
    /// The shared form of a CRM task this Mac receives: its task fields, the CRM's name, this Mac as its home.
    static func crmShared(_ row: NativeRPCValue, projects: [BackendCloudKindsProject], own: String?, system: String?) -> NativeRPCValue {
        var value = shared(row, place: "tasks", projects: projects, everywhere: true, own: own)
        value = CloudBrainRecordAdapter.travelling(value.merging(CloudBrainRecordAdapter.travelling(row, table: crmKind.table)), table: crmKind.table)
        if let notes = row["notes"].elements { value = value.setting("notes", .array(notes.map(note))) }
        if row["detail"].fields != nil { value = value.setting("detail", sharedDetail(row["detail"])) }
        if let own { value = value.setting("homeMac", .string(own)) }
        if let system, !system.isEmpty { value = value.setting("systemName", .string(String(system.prefix(60)))) }
        return value
    }
    /// The CRM tasks this Mac receives (sent as they are), and the copies held here, reported exactly as they
    /// arrived so a copy never sends a change of its own.
    private func crmRecords(known: [BackendCloudKindsProject], own: String?) async -> [String: NativeRPCValue] {
        crmRead = false
        guard let rows = try? await store.cloudLinkedTasks() else { return [:] }
        let names = await linkNames()
        var out: [String: NativeRPCValue] = [:]
        for row in rows {
            guard let id = row["id"].string, let key = row["keyId"].string, key != Self.localKey else { continue }
            let entity = Self.crmKind.entity(id)
            if !row[BackendTaskStore.copyField].isNullish {
                if let held = try? deletes.saved(Self.copyKey(entity)) { out[entity] = held }
            } else {
                out[entity] = Self.crmShared(row, projects: known, own: own, system: names[key])
            }
        }
        crmRead = true
        return out
    }
    private func linkNames() async -> [String: String] {
        var names: [String: String] = [:]
        for link in (try? await links?.connectionViews()) ?? [] {
            if let key = link["keyId"].string, let name = link["name"].string { names[key] = name }
        }
        return names
    }
    private func crmPlan(_ id: String, entity: String, cloud: NativeRPCValue?) async throws -> CloudBrainRecordPlan {
        let rows: [NativeRPCValue]
        do { rows = try await store.cloudLinkedTasks() } catch { throw CloudRecordRefusal(reason: "The task list on this Mac cannot be read right now.") }
        let row = rows.first { $0["id"].string == id }
        // This Mac receives the task itself: the CRM's own copy here wins, always.
        if let row, row[BackendTaskStore.copyField].isNullish {
            let key = row["keyId"].string ?? ""
            return .init(store: Self.crmShared(row, projects: await projects() ?? [], own: deletes.ownDevice(), system: await linkNames()[key]))
        }
        let held = try deletes.saved(Self.copyKey(entity))
        guard let cloud else { return .init(store: nil) }
        guard await deletes.isOpen() else { return .init(store: held) }
        guard let key = cloud["keyId"].string, key != Self.localKey, let external = cloud["externalTaskId"].string,
              cloud["id"].string == id, id == key + ":" + external else {
            return .init(store: held, waiting: Self.crmNotReadable)
        }
        return .init(store: CloudBrainRecordAdapter.travelling(cloud, table: Self.crmKind.table))
    }
    private func crmWrite(_ id: String, entity: String, value: NativeRPCValue, expecting: NativeRPCValue?) async throws {
        let rows = try await store.cloudLinkedTasks()
        let existing = rows.first { $0["id"].string == id }
        if let existing, existing[BackendTaskStore.copyField].isNullish { return }
        let before = try deletes.saved(Self.copyKey(entity))
        guard CloudBrainRecordAdapter.equal(before, expecting) else {
            throw CloudRecordRefusal(reason: "This task changed on this Mac while a change from another device was being applied; it is applied on the next try.")
        }
        let known = await projects() ?? [], own = deletes.ownDevice()
        let home = value["homeMac"].string ?? receiving[entity]?.device ?? ""
        let mac = await deletes.macName(home)
        let system = value["systemName"].string.flatMap { $0.isEmpty ? nil : $0 } ?? "its CRM"
        // Inert by construction: not local, unassigned work never starts here (the same guard as arriving assignments).
        var row = CloudBrainRecordAdapter.travelling(value, table: Self.crmKind.table)
            .setting(Self.localKey, .bool(false)).setting("sessionId", .null).setting("process", .string("stopped"))
            .setting(BackendTaskStore.copyField, .object([.init("device", .string(home)), .init("mac", .string(mac)), .init("system", .string(system))]))
        if let ref = value["projectRef"]["projectId"].string, !ref.isEmpty {
            row = row.setting("projectId", .string(ref)).setting(Self.refField, .object([.init("projectId", .string(ref))]))
                .setting("project", .string(known.first { $0.id == ref }?.folders.first ?? ""))
        } else { row = row.setting("project", .string("")) }
        if let device = value["workingOn"].string, !device.isEmpty, device != own {
            row = row.setting(Self.workingOnNameField, .string(await deletes.macName(device)))
        }
        row = Self.arrivingAssignmentGuard(row, existing: nil)
        do { try await store.cloudKindsWriteCopy(row) }
        catch let error as NativeRPCError { throw CloudRecordRefusal(reason: "Not applied on this Mac: " + error.message) }
        let held = CloudBrainRecordAdapter.travelling(value, table: Self.crmKind.table)
        try deletes.save(Self.copyKey(entity), held)
        settle.wrote(entity, held)
    }
    public static let crmNotReadable = "This task from a connected CRM cannot be read safely on this Mac."
    public static let systemsNotHere = "Connected task systems are not part of this Mac's app yet."
    public static let systemAddressRefused = "The address of this connected task system is not one this Mac can use (it must start with https://)."

    public func cloudPlan(entity: String, cloud: NativeRPCValue?) async throws -> CloudBrainRecordPlan {
        if let id = Self.crmKind.id(of: entity) { return try await crmPlan(id, entity: entity, cloud: cloud) }
        if let id = Self.systemKind.id(of: entity) { return try await systemPlan(id, cloud: cloud) }
        if let key = Self.linkKind.id(of: entity) { return try await linkPlan(key, entity: entity, cloud: cloud) }
        guard let id = Self.kind.id(of: entity) else { throw CloudRecordRefusal(reason: "This is not a task record.") }
        let all: [String: (place: String, row: NativeRPCValue)]
        do { all = try await rows() } catch { throw CloudRecordRefusal(reason: "The task list on this Mac cannot be read right now.") }
        guard let known = await projects() else { throw CloudRecordRefusal(reason: "The project list on this Mac cannot be read right now.") }
        let existing = all[entity]
        let open = await deletes.isOpen()
        let own = deletes.ownDevice()
        let mine = existing.map { Self.shared(RecordsDeleteLedger.wireRow($0.row, open: open), place: $0.place, projects: known,
                                              everywhere: open && speaks(entity), own: own) }
        // A purge applies only over Trash. A live local edit stays visible.
        guard let cloud else { return .init(store: existing?.place == "trash" ? nil : mine) }
        // Lead decision 2: a task this Mac aged out of its own Trash is not placed back into that Trash. A task put
        // back on another device (no longer in Trash there) arrives normally.
        if existing == nil, cloud["place"].string == "trash", try deletes.saved(RecordsDeleteLedger.agedKey(entity)) != nil {
            return .init(store: nil)
        }
        guard let identity = Self.identity(id), cloud["keyId"].string == identity.key, cloud["externalTaskId"].string == identity.external,
              cloud["id"].string == id else {
            return .init(store: mine, waiting: Self.connectedSystem)
        }
        if let projectID = cloud["projectRef"]["projectId"].string, !projectID.isEmpty, !known.contains(where: { $0.id == projectID }) {
            return .init(store: mine, waiting: Self.waitsForProject)
        }
        if cloud["place"].string == "trash" { try RecordsDeleteLedger.validate(cloud) }
        var next = cloud, held: [String: String] = [:]
        func hold(_ name: String, _ reason: String) {
            held[name] = reason
            next = mine?.has(name) == true ? next.setting(name, mine![name]) : next.removing(name)
        }
        if cloud.has("taskType"), !cloud["taskType"].isNullish, !CloudBrainMergeTables.taskTypes.contains(cloud["taskType"].string ?? "") {
            hold("taskType", "The kind of task set on another device is not one this Mac knows.")
        }
        if let model = cloud["model"].string, !model.isEmpty, !CloudBrainMergeTables.isValidModel(model) {
            hold("model", "The model set on another device is not one this Mac can use.")
        }
        if !["tasks", "trash"].contains(cloud["place"].string ?? "tasks") { hold("place", "Where the task is kept is not one this Mac knows.") }
        // CLOUD-KINDS-3 (Decker): the safe direction travels. "Needs your approval" arrives and is applied; an arriving
        // "no approval needed" never removes approval this Mac has.
        if cloud["decisionRequired"].bool != true, mine?["decisionRequired"].bool == true {
            hold("decisionRequired", "Approval for this task stays on until you turn it off on this Mac.")
        }
        if !CloudBrainMerge.mayApply(.shrink, before: mine?["tokenBudget"], after: cloud["tokenBudget"]) {
            hold("tokenBudget", "A larger spending limit for this task is never taken from another device.")
        }
        // Tasks everywhere: while work for this task runs on THIS Mac, an assignment made on another device waits (the
        // session here keeps the agent it was started for); it is taken once that work stops.
        if open, Self.workedHere(existing?.row), cloud.has("assignee") || cloud.has("mainAssignee"),
           cloud["assignee"] != mine?["assignee"] || cloud["mainAssignee"] != mine?["mainAssignee"] {
            hold("assignee", Self.workedHereLine); hold("mainAssignee", Self.workedHereLine)
        }
        if let notes = cloud["notes"].elements {
            var merged = notes.map(Self.note)
            // The shared list keeps the newest 100 comments; older ones still on this Mac are kept here, never dropped.
            if notes.count >= 100, let local = existing?.row["notes"].elements {
                let ids = Set(merged.map(CloudBrainMerge.elementID))
                let older = local.map(Self.note).filter { !ids.contains(CloudBrainMerge.elementID($0)) }
                merged = (older + merged).sorted { ($0["at"].number ?? 0) < ($1["at"].number ?? 0) }
            }
            next = next.setting("notes", .array(merged))
        }
        // Exactly what this Mac will hold after the write, so the write is never sent back as a change of its own.
        // A copy carrying the new fields makes this Mac speak for them from then on (`cloudWrite`).
        let composed = Self.compose(next, existing: existing?.row, projects: known, open: open)
        let everywhere = open && (speaks(entity) || Self.carriesNewFields(cloud))
        let stored = Self.shared(composed.row, place: composed.trash ? "trash" : "tasks", projects: known, everywhere: everywhere, own: own)
        return .init(store: stored, held: held)
    }
    static func carriesNewFields(_ value: NativeRPCValue) -> Bool {
        CloudBrainMergeTables.taskEverywhereFields.contains { value.has($0) }
    }
    public func cloudWrite(entity: String, value: NativeRPCValue, expecting: NativeRPCValue?) async throws {
        if let id = Self.crmKind.id(of: entity) { return try await crmWrite(id, entity: entity, value: value, expecting: expecting) }
        if let id = Self.systemKind.id(of: entity) { return try await systemWrite(id, entity: entity, value: value, expecting: expecting) }
        if Self.linkKind.id(of: entity) != nil { return try await linkWrite(entity, value: value, expecting: expecting) }
        let all = try await rows()
        guard let known = await projects() else { throw CloudRecordRefusal(reason: "The project list on this Mac cannot be read right now.") }
        let existing = all[entity]
        let open = await deletes.isOpen()
        let own = deletes.ownDevice()
        let before = existing.map { Self.shared(RecordsDeleteLedger.wireRow($0.row, open: open), place: $0.place, projects: known,
                                                everywhere: open && speaks(entity), own: own) }
        guard CloudBrainRecordAdapter.equal(before, expecting) else {
            throw CloudRecordRefusal(reason: "This task changed on this Mac while a change from another device was being applied; it is applied on the next try.")
        }
        var value = value
        if value["place"].string == "trash", value["deletedGroup"].string == nil {
            let who = try await deletes.arriving(value, entity: entity, device: receiving[entity]?.device ?? "", at: Int64(value["deletedAt"].number ?? Double(receiving[entity]?.at ?? deletes.now())))
            value = value.merging(RecordsDeleteLedger.metadata(who.intent(place: entity, scope: .everywhere), macName: who.macName))
        }
        var composed = Self.compose(value, existing: existing?.row, projects: known, open: open)
        // The card on this Mac names the Mac working the task, from the device list (never an id on the page).
        if open, let device = composed.row["workingOn"].string, !device.isEmpty, device != own {
            composed.row = composed.row.setting(Self.workingOnNameField, .string(await deletes.macName(device)))
        } else {
            composed.row = composed.row.removing(Self.workingOnNameField)
        }
        do { try await store.cloudKindsWrite(composed.row, trash: composed.trash) }
        catch let error as NativeRPCError { throw CloudRecordRefusal(reason: "Not applied on this Mac: " + error.message) }
        if open, Self.carriesNewFields(value) { markSpeaks(entity) }
        if !composed.trash { try deletes.clearSaved(RecordsDeleteLedger.agedKey(entity)) }
        if let before, !CloudBrainRecordAdapter.equal(before, value) { kept?.keep(record: entity, value: before) }
        settle.wrote(entity, Self.shared(RecordsDeleteLedger.wireRow(composed.row, open: open), place: composed.trash ? "trash" : "tasks", projects: known,
                                         everywhere: open && speaks(entity), own: own))
    }
    private func systemWrite(_ id: String, entity: String, value: NativeRPCValue, expecting: NativeRPCValue?) async throws {
        guard let systems else { throw CloudRecordRefusal(reason: Self.systemsNotHere) }
        let before = try await systems.cloudConnectionRows().first { $0["id"].string == id }.map(Self.systemShared)
        guard CloudBrainRecordAdapter.equal(before, expecting) else {
            throw CloudRecordRefusal(reason: "This connection changed on this Mac while a change from another device was being applied; it is applied on the next try.")
        }
        do { try await systems.cloudPutConnection(value) }
        catch let error as NativeRPCError { throw CloudRecordRefusal(reason: "Not applied on this Mac: " + error.message) }
        if let after = try await systems.cloudConnectionRows().first(where: { $0["id"].string == id }) { settle.wrote(entity, Self.systemShared(after)) }
    }
    private func linkWrite(_ entity: String, value: NativeRPCValue, expecting: NativeRPCValue?) async throws {
        let before = try deletes.saved(Self.elsewhereKey(entity))?["value"]
        guard CloudBrainRecordAdapter.equal(before, expecting) else {
            throw CloudRecordRefusal(reason: "This connection changed on this Mac while a change from another device was being applied; it is applied on the next try.")
        }
        let shared = Self.linkShared(value)
        let mac = await deletes.macName(receiving[entity]?.device ?? "")
        try deletes.save(Self.elsewhereKey(entity), .object([.init("value", shared), .init("mac", .string(mac))]))
        settle.wrote(entity, shared)
        refreshElsewhere()
    }
    public func cloudImported(_ entities: [String]) async { await display() }
    public func cloudContext() async -> String {
        guard let known = await projects() else { return "projects:?" }
        return "projects:" + known.map(\.id).sorted().joined(separator: ",")
    }

    public nonisolated func adapter(store: CloudBrainAgentsStore, account: CloudBrainAgentsAccount, origins: CloudBrainRecordOrigins) throws -> CloudBrainRecordAdapter {
        try deletes.bind(store: store, account: account)
        return try CloudBrainRecordAdapter(domain: Self.domain, inventoryRow: Self.inventoryRow, sourceId: Self.sourceID, kinds: [Self.kind, Self.systemKind, Self.linkKind, Self.crmKind], store: store,
            account: account, owner: self, origins: origins, exclusions: Self.exclusions)
    }
    public func setLocalDelete(_ remove: @escaping @Sendable (String, CloudDeleteActor) async throws -> Void) { localDelete = remove }
    /// `serviceTime`: the sync engine's service clock (`engine.serviceTime()`), nil while it is not known. The Trash
    /// ages by it alone, on this Mac only (lead decision 2); without it nothing ages.
    public nonisolated func configureDeleteRule(gate: @escaping @Sendable () async -> Bool, macNames: @escaping @Sendable (String) async -> String,
                                                serviceTime: (@Sendable () -> Int64?)? = nil) {
        deletes.configure(gate: gate, macNames: macNames, serviceTime: serviceTime)
    }
    public func cloudPendingRemovals() async throws -> [String] { try deletes.pending(prefix: "task:") }
    public func cloudMissing(entity: String, last: NativeRPCValue) async throws -> CloudBrainRecordMissing {
        // A CRM task this Mac received that is gone from its whole, readable list: its copies go. A copy here is never
        // the source of a removal.
        if Self.crmKind.id(of: entity) != nil {
            let copy = try deletes.saved(Self.copyKey(entity)) != nil
            return crmRead && !copy ? .remove(metadata: nil) : .keep
        }
        // A connected task system: only one the person removed here (`setCloudRemoved`), read whole this pass.
        if Self.systemKind.id(of: entity) != nil {
            let removed = try deletes.saved("purged:" + entity) != nil
            return systemsRead && removed ? .remove(metadata: nil) : .keep
        }
        // A CRM task link of this Mac that is gone from its whole, readable list (one of another Mac is never missing).
        if Self.linkKind.id(of: entity) != nil {
            let another = try deletes.saved(Self.elsewhereKey(entity)) != nil
            return linksRead && !another ? .remove(metadata: nil) : .keep
        }
        guard try deletes.saved("purged:" + entity) != nil else { return .keep }
        return .remove(metadata: nil)
    }
    public func cloudRestoring(entity: String) async throws -> Bool { try deletes.restoring(entity) }
    public func cloudCaptured(entity: String, removed: Bool) async throws { try deletes.captured(entity, removed: removed) }
    public func cloudReceiving(entity: String, device: String, at: Int64) async { receiving[entity] = (device, at) }
    public func cloudRemove(entity: String, expecting: NativeRPCValue?, removal: NativeRPCValue, device: String, at: Int64) async throws {
        if let id = Self.crmKind.id(of: entity) {
            // Only ever the copy; a task this Mac receives itself is the CRM's and is never removed from the Cloud.
            guard try deletes.saved(Self.copyKey(entity)) != nil else { return }
            try await store.cloudKindsRemoveCopy(id)
            try deletes.clearSaved(Self.copyKey(entity))
            await display()
            return
        }
        if let id = Self.systemKind.id(of: entity) {
            guard let systems else { return }
            let before = try await systems.cloudConnectionRows().first { $0["id"].string == id }.map(Self.systemShared)
            guard CloudBrainRecordAdapter.equal(before, expecting) else { throw CloudRecordRefusal(reason: "This connection changed while its removal arrived.") }
            try await systems.cloudRemoveConnection(id)
            return
        }
        if Self.linkKind.id(of: entity) != nil {
            try deletes.clearSaved(Self.elsewhereKey(entity))
            refreshElsewhere()
            return
        }
        guard let id = Self.kind.id(of: entity) else { throw CloudFailure.invalidRequest }
        let rows = try await rows()
        guard let existing = rows[entity], existing.place == "trash" else { return }
        let known = await projects() ?? []
        let open = await deletes.isOpen()
        let before = Self.shared(RecordsDeleteLedger.wireRow(existing.row, open: open), place: existing.place, projects: known,
                                 everywhere: open && speaks(entity), own: deletes.ownDevice())
        guard CloudBrainRecordAdapter.equal(before, expecting) else { throw CloudRecordRefusal(reason: "This task changed while its purge arrived.") }
        try await store.cloudKindsPurge(id)
    }
    public func deleteItems(_ items: [CloudDeleteItem], scope: CloudDeleteScope, by actor: CloudDeleteActor) async throws -> CloudBinGroup {
        var removed: [CloudDeleteItem] = []
        for item in items {
            let id = Self.kind.id(of: item.id) ?? item.id
            guard let row = try await store.byID(id), row.isLocal else { continue }
            if let remove = localDelete ?? deletes.taskDeleter() { try await remove(id, actor) }
            else { try await store.moveToTrash(id, deletedBy: actor) }
            removed.append(.init(id: Self.kind.entity(id), kind: "task", name: row.value["title"].string ?? item.name))
        }
        return .init(id: actor.group, by: actor.by, macName: actor.macName, session: actor.session, agent: actor.agent, at: actor.at, items: removed)
    }
    public func bringBack(_ items: [CloudDeleteItem], to: CloudBringBackDestination) async throws -> [CloudDeleteItem] {
        for item in items { _ = try await store.restore(Self.kind.id(of: item.id) ?? item.id) }
        return items
    }
    /// "Put back all" (lead decision 4): every item is tried; one that fails never stops the rest. The answer names
    /// what came back and what did not.
    public func putBackAll(_ group: String) async throws -> RecordsPutBackAnswer {
        guard let found = try await binGroups().first(where: { $0.id == group }) else { return .init(restored: [], notRestored: []) }
        var restored: [CloudDeleteItem] = [], failed: [CloudDeleteItem] = []
        for item in found.items {
            do { _ = try await store.restore(Self.kind.id(of: item.id) ?? item.id); restored.append(item) }
            catch { failed.append(item) }
        }
        return .init(restored: restored, notRestored: failed)
    }
    public func notHere() async throws -> [CloudNotHereItem] { [] }
    public func binGroups() async throws -> [CloudBinGroup] {
        var result: [(CloudDeleteItem, CloudDeleteActor)] = []
        await deletes.refreshOwnName()
        let local = deletes.actor(by: "me")
        for row in try await store.inTrash() where row.isLocal {
            let entity = Self.kind.entity(row.id)
            let actor: CloudDeleteActor
            if row.value["deletedGroup"].string == nil {
                let at = Int64(row.value["deletedAt"].number ?? 0)
                actor = .init(by: .person, mac: local.mac, macName: local.macName, at: at, group: "before:" + local.mac + ":" + String(at / 86_400_000))
            } else if UUID(uuidString: row.value["deletedGroup"].string ?? "") != nil {
                // Lead decision 6: a row whose attribution does not read is left out (one line, never its text).
                do {
                    actor = try await deletes.arriving(row.value, entity: entity, device: row.value["deletedOn"].string ?? "", at: Int64(row.value["deletedAt"].number ?? 0))
                } catch {
                    RecordsDeleteLedger.skippedRow("task")
                    continue
                }
            } else {
                let name = row.value["deletedMacName"].string ?? RecordsDeleteLedger.unknownMac
                actor = .init(by: .person, mac: row.value["deletedOn"].string ?? "", macName: name,
                    at: Int64(row.value["deletedAt"].number ?? 0), group: row.value["deletedGroup"].string ?? "")
            }
            result.append((.init(id: entity, kind: "task", name: row.value["title"].string ?? "Task"), actor))
        }
        return RecordsDeleteLedger.groups(result)
    }
    public func putBackGroup(_ group: String) async throws -> [CloudDeleteItem] { try await putBackAll(group).restored }
    public func deleteForGood(_ items: [CloudDeleteItem]) async throws {
        for item in items { try await store.purgeTrash(Self.kind.id(of: item.id) ?? item.id) }
    }

}

/// What one "Put back all" press brought back and what it could not, by item (pages show the names only).
public struct RecordsPutBackAnswer: Sendable, Equatable {
    public let restored: [CloudDeleteItem]
    public let notRestored: [CloudDeleteItem]
    public init(restored: [CloudDeleteItem], notRestored: [CloudDeleteItem]) { self.restored = restored; self.notRestored = notRestored }
    /// One plain line, names only: "Put back: Reviewer, Writer. Not put back: Planner."
    public var line: String {
        var parts: [String] = []
        if !restored.isEmpty { parts.append("Put back: " + restored.map(\.name).joined(separator: ", ") + ".") }
        if !notRestored.isEmpty { parts.append("Not put back: " + notRestored.map(\.name).joined(separator: ", ") + ".") }
        return parts.isEmpty ? "Nothing to put back." : parts.joined(separator: " ")
    }
}

/// The Tasks page's plain lines about CRM task links that send their tasks to another Mac (read by the task state).
public final class BackendCloudKindsElsewhere: @unchecked Sendable {
    private let lock = NSLock()
    private var current: [String] = []
    public init() {}
    public var lines: [String] { lock.withLock { current } }
    func set(_ lines: [String]) { lock.withLock { current = lines } }
}

/// The record owners' bookkeeping, not another Bin. Bytes live in the existing keeper (agents/projects)
/// or tasks.json's Trash. The lock also orders adapter binding with owner reads; no lock is held across await.
final class RecordsDeleteLedger: @unchecked Sendable {
    private let lock = NSLock()
    private var root: URL?
    private var opened: BackendCloudBrainFilesDatabase?
    private var keeper: BackendCloudVersionKeeper?
    private var link: (CloudBrainAgentsStore, CloudBrainAgentsAccount)?
    private var taskDelete: (@Sendable (String, CloudDeleteActor) async throws -> Void)?
    private var gate: @Sendable () async -> Bool = { false }
    private var macNames: @Sendable (String) async -> String = { _ in RecordsDeleteLedger.unknownMac }
    /// Review A2 / lead decision 2: the SERVICE clock only (nil while it is not known). The Trash and the keeper Bin
    /// age by it; until it is known nothing ages at all, so a Mac with a wrong clock can empty nothing.
    private var serviceTime: (@Sendable () -> Int64?)?
    /// Review A7 / lead decision 5: this Mac's name from the device list (the composition's `macNames`), cached;
    /// never `Host.current()`, which can block for seconds.
    private var ownName: String?
    static let unknownMac = "another device"
    static let thisMac = "this Mac"
    static let log = Logger(subsystem: "dev.terminaldeck.app", category: "records-delete")
    init(root: URL? = nil) { self.root = root }
    func setTaskDeleter(_ remove: @escaping @Sendable (String, CloudDeleteActor) async throws -> Void) {
        lock.withLock { taskDelete = remove }
    }
    func taskDeleter() -> (@Sendable (String, CloudDeleteActor) async throws -> Void)? { lock.withLock { taskDelete } }
    func bind(store: CloudBrainAgentsStore, account: CloudBrainAgentsAccount) throws {
        try lock.withLock {
            let next = store.file.deletingLastPathComponent().appendingPathComponent("records-delete")
            // Owners with local persistence keep their state across sign-in/offline deletes. Binding must
            // never hide an existing intent or Bin. Owners without local persistence use the account's folder.
            if root == nil { root = next }
            let destination = BackendCloudVersionKeeper(root: BackendCloudVersionKeeper.root(besideStateRoot: store.file.deletingLastPathComponent()))
            let location = try db().first("SELECT path,migrated FROM record_delete_keeper_location WHERE id=1")
            let fallbackRoot = BackendCloudVersionKeeper.root(besideStateRoot: root!)
            let fallback: BackendCloudVersionKeeper?
            if location?.int(1) != 1, FileManager.default.fileExists(atPath: fallbackRoot.appendingPathComponent("versions.sqlite").path), fallbackRoot != destination.root {
                fallback = BackendCloudVersionKeeper(root: fallbackRoot)
            } else { fallback = nil }
            if link == nil, let keeper = fallback {
                // A first-ever offline delete used the keeper before an account existed. Copy its owned store
                // for safety, then copy its rows into the account's EXISTING keeper. Delete nothing in migration.
                if FileManager.default.fileExists(atPath: keeper.root.path) {
                    let safety = keeper.root.deletingLastPathComponent().appendingPathComponent("versions-before-records-" + UUID().uuidString.lowercased())
                    try FileManager.default.copyItem(at: keeper.root, to: safety)
                }
                for kind in ["agent", "project"] {
                    for row in try keeper.versions(kind: kind) {
                        guard let bytes = keeper.content(kind: kind, sha256: row.sha256) else { throw CloudFailure.unavailable }
                        _ = try destination.keep(kind: kind, itemKey: row.itemKey, name: row.name, place: row.place, at: row.at,
                            device: row.device, content: bytes, now: row.keptUntil - CloudBinGroup.retentionMilliseconds)
                    }
                    for row in try keeper.binAll(kind: kind) {
                        guard let bytes = keeper.content(kind: kind, sha256: row.sha256) else { throw CloudFailure.unavailable }
                        _ = try destination.binPut(kind: kind, itemKey: row.itemKey, name: row.name, place: row.place, path: row.path,
                            removedAt: row.removedAt, device: row.device, content: bytes, shown: row.shown,
                            now: row.keptUntil - CloudBinGroup.retentionMilliseconds)
                    }
                }
            }
            try db().run("INSERT OR REPLACE INTO record_delete_keeper_location(id,path,migrated) VALUES (1,?,1)", [.text(destination.root.path)])
            keeper = destination
            link = (store, account)
        }
    }
    func configure(gate: @escaping @Sendable () async -> Bool, macNames: @escaping @Sendable (String) async -> String,
                   serviceTime: (@Sendable () -> Int64?)? = nil) {
        lock.withLock {
            self.gate = gate; self.macNames = macNames
            if let serviceTime { self.serviceTime = serviceTime }
        }
    }
    /// The service clock now, or nil while it is not known (then nothing ages).
    func serviceNow() -> Int64? { let read = lock.withLock { serviceTime }; return read?() }
    func isOpen() async -> Bool { await refreshOwnName(); let read = lock.withLock { gate }; return await read() }
    func macName(_ device: String) async -> String {
        let read = lock.withLock { macNames }
        return await read(device)
    }
    /// Reads this Mac's own name from the device list once more (every capture pass and every delete).
    func refreshOwnName() async {
        guard let device = lock.withLock({ link?.1.deviceID }) else { return }
        let name = await macName(device)
        guard !name.isEmpty, name != Self.unknownMac else { return }
        lock.withLock { ownName = name }
    }
    func ownMacName() -> String { lock.withLock { ownName } ?? Self.thisMac }
    /// Who is deleting, with this Mac's name freshly read from the device list.
    func currentActor(by: String = BackendTaskActor.current) async -> CloudDeleteActor {
        await refreshOwnName()
        return actor(by: by)
    }
    func actor(by: String = BackendTaskActor.current) -> CloudDeleteActor {
        let (context, name) = lock.withLock { (link, ownName) }
        let person = by == "me" || BackendTaskActor.deviceActorName(by) != nil
        return .init(by: person ? .person : .ai, mac: context?.1.deviceID ?? "this-mac",
            macName: name ?? Self.thisMac, session: nil,
            agent: person ? nil : (by == "hoot" ? "Hoot" : BackendTaskActor.appActorName(by)), at: context?.0.clock.read() ?? Int64(BackendTaskValues.time()), group: UUID().uuidString.lowercased())
    }
    func now() -> Int64 { lock.withLock { link?.0.clock.read() ?? Int64(BackendTaskValues.time()) } }
    /// This Mac's device id in the account, nil before the adapter is bound.
    func ownDevice() -> String? { lock.withLock { link?.1.deviceID } }
    /// Tasks everywhere: may this Mac send the new fields of `entity`? Yes for a record with no history yet (made
    /// here, never synced) and for one whose first revision this Mac made; for a record another Mac made, only once
    /// this Mac has applied a copy of it carrying those fields (`markSpeaks`). So a Mac never sends its inert local
    /// "stopped, unassigned" as if the person had changed them when the gate first opens.
    func speaks(_ entity: String, domain: String) -> Bool {
        if (try? saved("speaks:" + entity)) != nil { return true }
        let context = lock.withLock { link }
        guard let context, let key = try? CloudBrainRecordKey(domain: domain, entity: entity),
              let graph = try? context.0.graph(key) else { return false }
        if graph.nodes.isEmpty { return true }
        let roots = graph.nodes.values.filter { $0.parents.isEmpty }
        let first = roots.filter { !$0.baseline }.min { $0.time < $1.time } ?? roots.min { $0.time < $1.time }
        guard first?.device == context.1.deviceID else { return false }
        try? markSpeaks(entity)
        return true
    }
    func markSpeaks(_ entity: String) throws { try save("speaks:" + entity, .bool(true)) }
    /// Saved values whose key starts with `prefix` (bookkeeping only).
    func savedAll(prefix: String) throws -> [(key: String, value: NativeRPCValue)] {
        try lock.withLock {
            try db().rows("SELECT entity, value FROM record_delete_saved WHERE substr(entity, 1, length(?)) = ? ORDER BY entity",
                          [.text(prefix), .text(prefix)]).map { row in (key: row.text(0), value: try NativeRPCValue.parseJSON(row.data(1) ?? Data())) }
        }
    }
    private func db() throws -> BackendCloudBrainFilesDatabase {
        if let opened { return opened }
        guard let root else { throw CloudFailure.gateClosed }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let db = try BackendCloudBrainFilesDatabase(path: root.appendingPathComponent("state.sqlite").path, engineTables: false)
        _ = try CloudDeleteState(files: db)
        try db.exec("CREATE TABLE IF NOT EXISTS record_delete_saved(entity TEXT PRIMARY KEY, value BLOB NOT NULL, restoring INTEGER NOT NULL DEFAULT 0); CREATE TABLE IF NOT EXISTS record_delete_seen(entity TEXT PRIMARY KEY, at INTEGER NOT NULL); CREATE TABLE IF NOT EXISTS record_delete_keeper_location(id INTEGER PRIMARY KEY CHECK(id=1),path TEXT NOT NULL,migrated INTEGER NOT NULL)")
        opened = db
        return db
    }
    private func bin() throws -> BackendCloudVersionKeeper {
        // Another record owner may have completed the one offline-to-account migration on this shared state.
        let location = try db().first("SELECT path FROM record_delete_keeper_location WHERE id=1")?.string(0)
        let known = location.map { URL(fileURLWithPath: $0) }
        if let keeper, known == nil || keeper.root == known { return keeper }
        guard let root else { throw CloudFailure.gateClosed }
        let state = link?.0.file.deletingLastPathComponent() ?? root
        let keeper = BackendCloudVersionKeeper(root: known ?? BackendCloudVersionKeeper.root(besideStateRoot: state))
        self.keeper = keeper
        return keeper
    }
    func pending(prefix: String) throws -> [String] {
        try lock.withLock { try db().rows("SELECT place FROM cloud_delete_intents ORDER BY place").map { $0.text(0) }.filter { $0.hasPrefix(prefix) } }
    }
    func hasHistory(_ entity: String, domain: String) throws -> Bool {
        let context = lock.withLock { link }
        guard let context else { return false }
        return try !context.0.graph(CloudBrainRecordKey(domain: domain, entity: entity)).nodes.isEmpty
    }
    func intent(_ entity: String) throws -> CloudDeleteIntent? { try lock.withLock { try CloudDeleteState(files: db()).intent(at: entity) } }
    func saveIntent(_ intent: CloudDeleteIntent) throws { try lock.withLock { try CloudDeleteState(files: db()).putIntent(intent) } }
    func clearIntent(_ entity: String) throws { try lock.withLock { try CloudDeleteState(files: db()).clearIntent(at: entity) } }
    func mark(_ entity: String) throws -> CloudDeleteMark? { try lock.withLock { try CloudDeleteState(files: db()).mark(at: entity) } }
    func mark(_ entity: String, _ mark: CloudLocalMark, at: Int64) throws {
        try lock.withLock { try CloudDeleteState(files: db()).putMark(.init(place: entity, mark: mark, at: at)) }
    }
    func marks() throws -> [CloudDeleteMark] { try lock.withLock { try CloudDeleteState(files: db()).marks() } }
    func clearMark(_ entity: String) throws { try lock.withLock { try CloudDeleteState(files: db()).clearMark(at: entity) } }
    func save(_ entity: String, _ value: NativeRPCValue, restoring: Bool = false) throws {
        try lock.withLock { try saveUnlocked(entity, value, restoring: restoring) }
    }
    private func saveUnlocked(_ entity: String, _ value: NativeRPCValue, restoring: Bool) throws {
        let bytes = try value.encodedJSON()
        try db().run("INSERT INTO record_delete_saved(entity,value,restoring) VALUES (?,?,?) ON CONFLICT(entity) DO UPDATE SET value=excluded.value, restoring=MAX(record_delete_saved.restoring, excluded.restoring)", [.text(entity), .blob(bytes), .int(restoring ? 1 : 0)])
    }
    /// A new delete is never a put back: a put-back flag left from before it is dropped (lead decision 1).
    func clearRestoring(_ entity: String) throws {
        try lock.withLock { try db().run("UPDATE record_delete_saved SET restoring=0 WHERE entity=?", [.text(entity)]) }
    }
    func rememberVersion(_ entity: String, _ value: NativeRPCValue) throws {
        try lock.withLock {
            let bytes = try value.encodedJSON(), now = nowUnlocked()
            _ = try bin().keep(kind: "agent", itemKey: entity, name: "Agent instructions", place: nil, at: now,
                device: link?.1.deviceID ?? "this-mac", content: bytes, now: now)
        }
    }
    func seen(_ entity: String, at: Int64) throws {
        try lock.withLock { try db().run("INSERT OR REPLACE INTO record_delete_seen(entity,at) VALUES (?,?)", [.text(entity), .int(at)]) }
    }
    func lastSeen(_ entity: String) throws -> Date? {
        try lock.withLock { try db().first("SELECT at FROM record_delete_seen WHERE entity=?", [.text(entity)]).map { Date(timeIntervalSince1970: Double($0.int(0)) / 1000) } }
    }
    func captured(_ entity: String, removed: Bool) throws {
        try lock.withLock {
            try db().run("UPDATE record_delete_saved SET restoring=0 WHERE entity=?", [.text(entity)])
            if removed {
                try CloudDeleteState(files: db()).clearIntent(at: entity)
                try db().run("DELETE FROM record_delete_saved WHERE entity=?", [.text("purged:" + entity)])
                if try CloudDeleteState(files: db()).mark(at: entity) == nil {
                    try db().run("DELETE FROM record_delete_saved WHERE entity=?", [.text(entity)])
                }
            }
        }
    }
    func saved(_ entity: String) throws -> NativeRPCValue? {
        try lock.withLock {
            guard let row = try db().first("SELECT value FROM record_delete_saved WHERE entity=?", [.text(entity)]) else { return nil }
            return try NativeRPCValue.parseJSON(row.data(0) ?? Data())
        }
    }
    func clearSaved(_ entity: String) throws {
        try lock.withLock { try db().run("DELETE FROM record_delete_saved WHERE entity=?", [.text(entity)]) }
    }
    func restoring(_ entity: String) throws -> Bool {
        try lock.withLock { try db().first("SELECT restoring FROM record_delete_saved WHERE entity=?", [.text(entity)])?.int(0) == 1 }
    }
    func merged(_ entity: String, table: CloudBrainMergeTable) throws -> CloudBrainMergeView? {
        let context = lock.withLock { link }
        guard let context else { return nil }
        return try context.0.view(CloudBrainRecordKey(domain: table.domain, entity: entity), table: table)
    }
    func removalSeen(_ entity: String, group: String, table: CloudBrainMergeTable) throws -> Bool {
        guard let view = try merged(entity, table: table), view.fields["deletedGroup"]?.string == group else { return false }
        return !view.exists || view.conflicts.contains { $0.field == CloudBrainMerge.existsField && $0.value.bool == false }
    }
    func newest(_ entity: String, table: CloudBrainMergeTable) throws -> NativeRPCValue? {
        let context = lock.withLock { link }
        guard let context else { return nil }
        let key = try CloudBrainRecordKey(domain: table.domain, entity: entity)
        guard let view = try context.0.view(key, table: table), view.exists else { return nil }
        return view.shown()
    }
    func priorValues(_ entity: String, table: CloudBrainMergeTable) throws -> [NativeRPCValue] {
        try lock.withLock {
            try bin().versions(itemKey: entity).compactMap { row in
                guard let bytes = try bin().content(kind: row.kind, sha256: row.sha256) else { return nil }
                return try NativeRPCValue.parseJSON(bytes)
            }
        }
    }
    func binnedValue(_ entity: String) throws -> NativeRPCValue? {
        try lock.withLock {
            guard let row = try bin().bin(itemKey: entity), let bytes = try bin().content(kind: row.kind, sha256: row.sha256) else { return nil }
            return try NativeRPCValue.parseJSON(bytes).removing("deleteActor")
        }
    }

    /// The group of the delete that put this record in the Bin, or nil when it is not in the Bin.
    func binnedGroup(_ entity: String) throws -> String? {
        try lock.withLock {
            guard let row = try bin().bin(itemKey: entity), let bytes = try bin().content(kind: row.kind, sha256: row.sha256) else { return nil }
            return try NativeRPCValue.parseJSON(bytes)["deleteActor"]["group"].string
        }
    }
    /// Lead decision 1 (review A1): a record found back in its list while its Bin copy exists counts as PUT BACK only
    /// when no delete intent exists for it and the Bin copy is still the one seen (`group`). Checked and taken under one
    /// lock, so a delete made while a sync pass runs keeps its Bin copy and its removal travels.
    func takeRestoredBin(_ entity: String, also companion: String, companionValue: NativeRPCValue, group: String) throws -> Bool {
        try lock.withLock {
            let state = try CloudDeleteState(files: db())
            guard try state.intent(at: entity) == nil, try state.intent(at: companion) == nil,
                  let held = try bin().bin(itemKey: entity), let bytes = try bin().content(kind: held.kind, sha256: held.sha256),
                  try NativeRPCValue.parseJSON(bytes)["deleteActor"]["group"].string == group else { return false }
            try saveUnlocked(entity, .bool(true), restoring: true)
            try saveUnlocked(companion, companionValue, restoring: true)
            try bin().binTake(itemKey: entity, now: nowUnlocked())
            return true
        }
    }
    func keepReplacement(kind: String, entity: String, name: String, value: NativeRPCValue) throws {
        try lock.withLock {
            let at = nowUnlocked()
            _ = try bin().keep(kind: kind, itemKey: entity, name: name, place: nil, at: at,
                device: link?.1.deviceID ?? "this-mac", content: value.encodedJSON(), now: at)
        }
    }
    func putBin(kind: String, entity: String, name: String, value: NativeRPCValue, actor: CloudDeleteActor) throws {
        try lock.withLock {
            if let held = try bin().bin(itemKey: entity), let bytes = try bin().content(kind: held.kind, sha256: held.sha256),
               try NativeRPCValue.parseJSON(bytes)["deleteActor"]["group"].string == actor.group { return }
            let payload = value.setting("deleteActor", try NativeRPCValue.parseJSON(JSONEncoder().encode(actor)))
            _ = try bin().binPut(kind: kind, itemKey: entity, name: name, place: nil, path: entity,
                removedAt: actor.at, device: actor.mac, content: payload.encodedJSON(), shown: true, now: nowUnlocked())
        }
    }
    private func nowUnlocked() -> Int64 { link?.0.clock.read() ?? Int64(BackendTaskValues.time()) }
    func binRows(kind: String) throws -> [(item: CloudDeleteItem, actor: CloudDeleteActor, value: NativeRPCValue)] {
        let service = serviceNow()
        return try lock.withLock {
            // Each Mac ages its own Bin by the service clock only; nothing ages while that clock is not known.
            if let service { _ = try bin().sweepBin(kind: kind, keptUntilBefore: service) }
            return try bin().binList(kind: kind).compactMap { row -> (item: CloudDeleteItem, actor: CloudDeleteActor, value: NativeRPCValue)? in
                // Lead decision 6: one row that does not read is left out (one line, no content); the rest shows.
                do {
                    guard let content = try bin().content(kind: kind, sha256: row.sha256) else { throw CloudFailure.unavailable }
                    let value = try NativeRPCValue.parseJSON(content)
                    let actor = try JSONDecoder().decode(CloudDeleteActor.self, from: value["deleteActor"].encodedJSON())
                    return (CloudDeleteItem(id: row.itemKey, kind: kind, name: row.name), actor, value.removing("deleteActor"))
                } catch {
                    Self.skippedRow(kind)
                    return nil
                }
            }
        }
    }
    static func skippedRow(_ kind: String) {
        log.error("One \(kind, privacy: .public) Bin row could not be read and is left out of the list.")
    }
    func takeBin(_ entity: String, permanently: Bool = false) throws {
        try lock.withLock {
            if permanently { try bin().database().run("DELETE FROM bin WHERE item_key=?", [.text(entity)]) }
            else { try bin().binTake(itemKey: entity, now: nowUnlocked()) }
        }
    }
    static func metadata(_ intent: CloudDeleteIntent, macName: String) -> NativeRPCValue {
        .object([.init("deletedBy", .string(intent.by.rawValue)), .init("deletedOn", .string(intent.mac)),
            .init("deletedGroup", .string(intent.group)), .init("deletedScope", .string(intent.scope.rawValue)),
            .init("deletedTime", .number(Double(intent.at))), .init("deletedMacName", .string(macName)), .init("deletedWithAgent", .bool(false)),
            .init("deletedSession", intent.session.map(NativeRPCValue.string) ?? .null), .init("deletedAgent", intent.agent.map(NativeRPCValue.string) ?? .null)])
    }
    static func clearing(_ row: NativeRPCValue) -> NativeRPCValue {
        CloudBrainMergeTables.recordDeleteFields.reduce(row) { $0.removing($1) }
    }
    static func wireRow(_ row: NativeRPCValue, open: Bool) -> NativeRPCValue {
        guard open, let group = row["deletedGroup"].string, UUID(uuidString: group) != nil else { return clearing(row) }
        return row
    }
    static func validate(_ value: NativeRPCValue) throws {
        // Old records lack attribution. A partial/malformed new removal never becomes Everywhere.
        guard !value["deletedGroup"].isNullish || !value["deletedScope"].isNullish || !value["deletedBy"].isNullish else { return }
        guard let group = value["deletedGroup"].string, UUID(uuidString: group) != nil,
              CloudDeleteBy(rawValue: value["deletedBy"].string ?? "") != nil,
              CloudDeleteScope(rawValue: value["deletedScope"].string ?? "") != nil,
              let device = value["deletedOn"].string, !device.isEmpty,
              let time = value["deletedTime"].number, time.isFinite, time > 0, time < Double(Int64.max) else {
            throw CloudRecordRefusal(reason: "This removal's attribution or scope cannot be read safely.")
        }
    }
    func arriving(_ value: NativeRPCValue, entity: String, device: String, at: Int64) async throws -> CloudDeleteActor {
        try Self.validate(value)
        let mac = value["deletedOn"].string ?? device
        let name: String
        if let held = value["deletedMacName"].string { name = held } else { name = await macName(mac) }
        return .init(by: CloudDeleteBy(rawValue: value["deletedBy"].string ?? "") ?? .person, mac: mac, macName: name,
            session: value["deletedSession"].string, agent: value["deletedAgent"].string,
            at: Int64(value["deletedTime"].number ?? Double(at)), group: value["deletedGroup"].string ?? Self.olderGroup(mac, at))
    }
    /// A task this Mac aged out of its own Trash (local only, never sent).
    static func agedKey(_ entity: String) -> String { "aged:" + entity }
    static func olderGroup(_ mac: String, _ at: Int64) -> String { "older:" + mac + ":" + String(at / 86_400_000) }
    static func groups(_ rows: [(CloudDeleteItem, CloudDeleteActor)]) -> [CloudBinGroup] {
        Dictionary(grouping: rows, by: { $0.1.group }).values.compactMap { rows in
            guard let actor = rows.first?.1 else { return nil }
            return .init(id: actor.group, by: actor.by, macName: actor.macName, session: actor.session, agent: actor.agent,
                at: actor.at, items: rows.map { $0.0 }, era: actor.group.hasPrefix("older:") ? .olderVersion : (actor.group.hasPrefix("before:") ? .beforeNewRule : .current))
        }.sorted { $0.at > $1.at }
    }
}
