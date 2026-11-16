import Foundation
import TerminalDeckNativeCore

/// Lane A2, lean first version (cloud-lean-v1.md item 7): the LIST OF PROJECTS arrives on a second Mac.
/// What travels of a project: its id, name, icon and colour, and its lead when that is an agent (design v2 Appendix A).
/// NEVER a folder path: a project's folders are this Mac's own map from the project to folders the person chose
/// here, kept in this Mac's registry and never sent, read or changed by the Cloud. A project that arrives and is not
/// on this Mac is added to the project list with no folder; in the app (`folders` set) it then gets its own folder by
/// itself at `<Terminal Deck folder>/Projects/<name>` (project folders, 14 Nov), made on this Mac and never sent.
/// Not registered by itself: lane A's wiring builds it (see macos/night/codex/cloud-adapters-wiring.md).
public actor BackendCloudLeanProjects: CloudBrainRecordOwner, CloudDeleteOwning {
    public static let domain = "projects"
    public static let inventoryRow = "I11"
    public static let sourceID = "project-registry"
    public static let kind = CloudBrainRecordKind(prefix: "project:", table: CloudBrainMergeTables.recordsDeleteRule(CloudBrainMergeTables.project), listedValues: ["name"])
    public static let exclusions = [
        "Project folders are chosen on each device and are never sent.",
        "Project logo pictures, dashboards and a lead that is a live session stay on this Mac in this version.",
    ]
    /// A project on this Mac that has no folder here yet. "Choose a folder on this Mac" is the one thing offered for it
    /// in this version: the row carries its id and name, and nothing to fetch it from.
    public struct NeedsFolder: Sendable, Equatable {
        public let id: String
        public let name: String
    }
    /// Ids of this Mac's projects (arrived or made here, with or without a folder). The memory resolver answers from
    /// it without waiting.
    final class Confirmed: @unchecked Sendable {
        private let lock = NSLock()
        private var ids: Set<String> = []
        /// Replaces the set; true when a project is in it that was not before (a project became known here).
        func set(_ next: Set<String>) -> Bool { lock.withLock { defer { ids = next }; return !next.subtracting(ids).isEmpty } }
        func contains(_ id: String) -> Bool { lock.withLock { ids.contains(id) } }
    }

    private nonisolated let deletes: RecordsDeleteLedger
    private var removeEntry: (@Sendable (String) async throws -> Void)?
    private var restoreEntry: (@Sendable (PROJProject) async throws -> Void)?
    private let registry: BackendPROJRegistry
    private let display: @Sendable () async -> Void
    private let memory: @Sendable () async -> Void
    /// Y2 (13 Nov): true while the device-trust setting is "Automatically, with my account" (the default): a project
    /// lead chosen on the account's own trusted device is applied with no click. false ("Ask me for each new device")
    /// or nil (cannot be read): the lead waits and is listed, as before.
    private let fullAccess: @Sendable () async -> Bool?
    /// Project folders (owner, 14 Nov): a project on this Mac with no folder here gets its own folder by itself, at
    /// `<Terminal Deck folder>/Projects/<name>`. nil (tests of the record rule alone): projects stay without a folder.
    private let folders: BackendProjectFolders?
    private nonisolated let confirmed = Confirmed()
    private var watching = false

    /// `display`: refreshes the project list on screen after an import. Display only: it must reach screens and
    /// nothing else (not the task engine's change hub, and not the app-wide "tasks:changed" channel, which other parts
    /// of the app also listen to); lane A passes `BackendCloudLeanRecords.displayEvent`.
    /// `memory`: asks lane A's memory to place what waited for a project. Called once each time a project gains its
    /// first folder or arrives through Cloud (G: the record alone places memory), by ANY path: the registry's own
    /// change point tells this owner, and every capture pass checks again (review M2).
    public init(registry: BackendPROJRegistry, display: @escaping @Sendable () async -> Void = {}, memory: @escaping @Sendable () async -> Void = {},
                fullAccess: @escaping @Sendable () async -> Bool? = { false }, folders: BackendProjectFolders? = nil,
                deleteStateRoot: URL? = nil, removeEntry: (@Sendable (String) async throws -> Void)? = nil,
                restoreEntry: (@Sendable (PROJProject) async throws -> Void)? = nil) {
        self.deletes = RecordsDeleteLedger(root: deleteStateRoot); self.removeEntry = removeEntry; self.restoreEntry = restoreEntry
        self.registry = registry; self.display = display; self.memory = memory; self.fullAccess = fullAccess; self.folders = folders
        // Review fix F (Decker): the app's Remove and the project_registry.remove_empty tool go through this owner.
        registry.deleteRule.set { [weak self] id in
            guard let self else { return false }
            return try await self.removeByApp(id)
        }
    }
    /// Review fix F: a project removed in the app or by its tool = EVERYWHERE under the delete rule (in the Bin 30 days,
    /// no question). Only the list entry goes; his folders and files on every Mac stay. false = no account bound yet.
    public func removeByApp(_ id: String) async throws -> Bool {
        guard deletes.ownDevice() != nil, id != PROJProjects.independentID else { return false }
        let actor = await deletes.currentActor()
        let group = try await deleteItems([.init(id: Self.kind.entity(id), kind: "project", name: "Project")], scope: .everywhere, by: actor)
        return !group.items.isEmpty
    }

    /// One plain line: no control character, no line break, within the length this Mac's registry accepts.
    static func plainLine(_ value: String, maximum: Int, optional: Bool = false) -> Bool {
        let odd = value.unicodeScalars.contains { $0.properties.generalCategory == .control || $0 == "\u{2028}" || $0 == "\u{2029}" }
        return value.utf8.count <= maximum && !odd && (optional || !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }
    /// A name from another device as one plain line this Mac can show: control characters and line breaks become
    /// spaces, trimmed, at most 256 bytes; nothing left is "Project".
    static func plainName(_ name: String) -> String {
        var scalars = String.UnicodeScalarView()
        for scalar in name.unicodeScalars {
            let odd = scalar.properties.generalCategory == .control || scalar == "\u{2028}" || scalar == "\u{2029}"
            scalars.append(odd ? " " : scalar)
        }
        var result = String(scalars).split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
        while result.utf8.count > 256 { result.removeLast() }
        result = result.trimmingCharacters(in: .whitespacesAndNewlines)
        return result.isEmpty ? "Project" : result
    }
    /// What travels of a project. A folder is never in it; a lead that is a live session of this Mac is not either.
    static func record(_ project: PROJProject) -> NativeRPCValue {
        var fields: [NativeRPCValue.Field] = [.init("id", .string(project.id)), .init("name", .string(project.name)),
            .init("icon", .string(project.icon)), .init("colour", .string(project.colour))]
        if !project.lead.hasPrefix("session:") {
            fields.append(.init("lead", .string(project.lead)))
            fields.append(.init("leadName", .string(project.leadName)))
        }
        return .object(fields)
    }
    private static func travelling(_ project: PROJProject) -> NativeRPCValue {
        CloudBrainRecordAdapter.travelling(record(project), table: kind.table)
    }
    /// The Independent project as shipped exists on every Mac; only a changed one is a record (design v2 Appendix B).
    private static func isSeed(_ project: PROJProject) -> Bool {
        let seed = PROJProjects.independent
        return project.id == seed.id && project.name == seed.name && project.icon == seed.icon && project.colour == seed.colour && project.lead.isEmpty
    }
    /// What this Mac holds of a project as a record: nothing for a project it does not have, or for the shipped seed.
    private static func kept(_ project: PROJProject?) -> NativeRPCValue? {
        guard let project, !isSeed(project) else { return nil }
        return travelling(project)
    }
    /// The resolver's set of projects with a folder here. True when it grew; the caller then asks memory to place
    /// what waited (once per growth). The first refresh after start counts as growth: the resolver answered nothing
    /// before it, so memory lane A tried to place at start is tried again.
    private func refresh(_ projects: [PROJProject]) -> Bool {
        // G (13 Nov, owner's rule "sign in once and everything follows"): memory lives in the app's own memory folder,
        // never in a project folder, so it follows as soon as the project RECORD is on this Mac. No folder choice
        // and no click (before, 40,728 memory rows waited on the joining MacBook for a folder nobody was asked for).
        // Only files written INTO a project folder (boot files) wait for a folder; that is the boot-files owner's.
        confirmed.set(Set(projects.map { $0.id }))
    }
    /// MAC-NEXT-7: this Mac's project list (arrived records included) read into the memory resolver's set NOW, before
    /// memory's first release. Before, the set filled only at the first capture pass, so the release at launch found
    /// every arrived project unknown, logged its rows as kept for projects "on no device here", and did the work twice.
    public func confirmProjects() async {
        if let projects = try? await registry.cloudLeanProjects() { _ = refresh(projects) }
    }
    /// Asks the registry to say when a project gains its first folder, whichever screen or tool added it.
    private func watch() async {
        guard !watching else { return }
        watching = true
        await registry.cloudLeanWhenFolderAdded { [weak self] in
            guard let self else { return false }
            await self.folderAdded()
            return true
        }
    }
    private func folderAdded() async {
        guard let projects = try? await registry.cloudLeanProjects() else { return }
        if refresh(projects) { await memory() }
    }

    // MARK: CloudBrainRecordOwner

    public func cloudRecords() async throws -> [String: NativeRPCValue] {
        await watch()
        // Every look (and the first one after launch) gives a folder to a project that has none here yet. The folder
        // is this Mac's own and is not in the record, so this sends nothing.
        await folders?.placeMissing()
        let projects = try await registry.cloudLeanProjects()
        if refresh(projects) { await memory() }
        var result: [String: NativeRPCValue] = [:]
        for project in projects where !Self.isSeed(project) {
            let entity = Self.kind.entity(project.id)
            if try deletes.mark(entity) == nil { result[entity] = Self.record(project) }
        }
        return result
    }
    public func cloudPlan(entity: String, cloud: NativeRPCValue?) async throws -> CloudBrainRecordPlan {
        guard let id = Self.kind.id(of: entity) else { throw CloudRecordRefusal(reason: "This is not a project record.") }
        let projects: [PROJProject]
        do { projects = try await registry.cloudLeanProjects() }
        catch { throw CloudRecordRefusal(reason: "The saved project list on this Mac cannot be read right now.") }
        let current = projects.first { $0.id == id }
        let kept = Self.kept(current)
        if let mark = try deletes.mark(entity), mark.mark == .notOnThisMac || cloud == nil {
            return .init(store: nil, waiting: mark.mark.title)
        }
        guard let cloud else { return .init(store: nil) }
        guard PROJProjects.isValidID(id) else { return .init(store: kept, waiting: "This project's id is not one this Mac can use.") }
        let binned = try deletes.binnedValue(entity).map { try JSONDecoder().decode(PROJProject.self, from: $0.encodedJSON()) }
        var project = current ?? binned ?? PROJProject(id: id, name: "")
        var held: [String: String] = [:]
        func line(_ key: String, maximum: Int, optional: Bool = false) -> String? {
            guard let value = cloud[key].string, Self.plainLine(value, maximum: maximum, optional: optional) else { return nil }
            return value
        }
        if cloud.has("name") {
            if let name = line("name", maximum: 256) { project.name = name }
            else {
                held["name"] = "The name set on another device is not one plain line."
                // Project folders (14 Nov): a project NEW to this Mac is never left out because of its name (one odd
                // name must not make a whole project disappear). It arrives under the plain form of that name (line
                // breaks and control characters made spaces); the original stays held and listed, and is never sent.
                if current == nil { project.name = Self.plainName(cloud["name"].string ?? "") }
            }
        }
        if cloud.has("icon") {
            if let icon = line("icon", maximum: 128) { project.icon = icon } else { held["icon"] = "The icon set on another device is not one this Mac can show." }
        }
        if cloud.has("colour") {
            if let colour = line("colour", maximum: 64, optional: true) { project.colour = colour } else { held["colour"] = "The colour set on another device is not one this Mac can show." }
        }
        // The lead decides which agent may direct the project's agents. With full access (Y2, the default setting) the
        // lead chosen on the account's own device is taken; with "Ask me for each new device" only "no lead" (narrower)
        // is taken and another lead waits. A lead that is a live session of this Mac is this Mac's own.
        let full = await fullAccess() == true
        if cloud.has("lead"), !project.lead.hasPrefix("session:"), let theirs = cloud["lead"].string, theirs != project.lead {
            if theirs.isEmpty {
                project.lead = ""; project.leadName = ""
            } else if full, Self.plainLine(theirs, maximum: 200) {
                project.lead = theirs
                project.leadName = line("leadName", maximum: 200, optional: true) ?? ""
            } else {
                held["lead"] = "A project lead chosen on another device is not applied here. Choose the lead on this Mac."
                held["leadName"] = held["lead"]
            }
        } else if cloud["lead"].string == project.lead, let leadName = line("leadName", maximum: 200, optional: true) {
            project.leadName = leadName
        }
        // A project new to this Mac always has a name this Mac can show (`plainName`), so it is never left out.
        if current == nil, project.name.isEmpty { project.name = Self.plainName("") }
        let planned: PROJProject
        do { planned = try await registry.cloudLeanPlan(project) }
        catch let error as NativeRPCError { throw CloudRecordRefusal(reason: error.message) }
        catch { throw CloudRecordRefusal(reason: "The saved project list on this Mac cannot take this project right now.") }
        return .init(store: Self.travelling(planned), held: held)
    }
    public func cloudWrite(entity: String, value: NativeRPCValue, expecting: NativeRPCValue?) async throws {
        guard let id = Self.kind.id(of: entity), let name = value["name"].string else { throw CloudFailure.invalidRequest }
        let projects = try await registry.cloudLeanProjects()
        let current = projects.first { $0.id == id }
        let mark = try deletes.mark(entity)
        let before = mark == nil ? Self.kept(current) : nil
        guard CloudBrainRecordAdapter.equal(before, expecting) else {
            throw CloudRecordRefusal(reason: "This project changed on this Mac while a change from another device was being applied; it is applied on the next try.")
        }
        let binned = try deletes.binnedValue(entity).map { try JSONDecoder().decode(PROJProject.self, from: $0.encodedJSON()) }
        var project = current ?? binned ?? PROJProject(id: id, name: name)
        project.name = name
        if let icon = value["icon"].string { project.icon = icon }
        if let colour = value["colour"].string { project.colour = colour }
        if value.has("lead") {
            project.lead = value["lead"].string ?? ""
            project.leadName = value["leadName"].string ?? ""
        }
        // This Mac's registry refusing it (the 256-project cap, a damaged list) is "cannot apply this one", not
        // "broken" (review should-fix 2): the sync core parks this record and the pack moves on.
        if mark?.mark == .onlyOnThisMac, let current {
            try deletes.keepReplacement(kind: "project", entity: entity, name: current.name, value: current.wireValue)
        }
        // Lead decision 1: a project deleted here whose removal has not been sent yet is never brought back from its
        // Bin copy by an arriving change; the removal is captured first and the merge then decides by ancestry.
        if current == nil, binned != nil, try deletes.intent(entity) != nil {
            throw CloudRecordRefusal(reason: "This project was removed on this Mac and its removal is being sent; the change from another device is looked at again after it.")
        }
        do {
            if current == nil, binned != nil {
                guard let restoreEntry else { throw CloudRecordRefusal(reason: "The project registry restore writer has not been connected.") }
                try await restoreEntry(project)
                try deletes.takeBin(entity)
            } else { try await registry.cloudLeanWrite(project) }
        }
        catch let error as NativeRPCError { throw CloudRecordRefusal(reason: "Not applied on this Mac: " + error.message) }
        if mark?.mark == .onlyOnThisMac { try deletes.clearMark(entity); try deletes.takeBin(entity) }
        let after = try await registry.cloudLeanProjects()
        if refresh(after) { await memory() }
    }
    public func cloudImported(_ entities: [String]) async {
        // A project that just arrived gets its folder at once, before the screens redraw (it shows with its folder).
        await folders?.placeMissing()
        await display()
    }
    /// Y2: a change of the device-trust setting, and the first pass after a launch, look at held leads again.
    public func cloudContext() async -> String {
        switch await fullAccess() {
        case true?: return "access:full"
        case false?: return "access:ask"
        case nil: return "access:?"
        }
    }

    // MARK: this Mac's folders

    /// Projects on this Mac without a folder here: the project list shows each as "Choose a folder on this Mac".
    public func needingFolder() async throws -> [NeedsFolder] {
        let projects = try await registry.projects()
        return projects.filter { $0.id != PROJProjects.independentID && $0.folders.isEmpty }.map { NeedsFolder(id: $0.id, name: $0.name) }
    }
    /// The person chose a folder for a project on this Mac, in this Mac's own window (never a tool call, never the
    /// Cloud). It is stored in this Mac's registry only, and memory that waited for the project is placed (through the
    /// registry's change point, as for a folder added on the Projects page).
    @discardableResult
    public func chooseFolder(projectID: String, folder: String) async throws -> PROJProject {
        let path = PROJProjects.normalize(folder)
        var directory: ObjCBool = false
        guard path.hasPrefix("/"), FileManager.default.fileExists(atPath: path, isDirectory: &directory), directory.boolValue else {
            throw NativeRPCError.invalidArguments("Choose a folder that exists on this Mac.")
        }
        let projects = try await registry.projects()
        guard projectID != PROJProjects.independentID, var project = projects.first(where: { $0.id == projectID }) else {
            throw NativeRPCError.invalidArguments("Choose a project from the project list.")
        }
        await watch()
        if !project.folders.contains(path) { project.folders.append(path) }
        // The person's own save: this Mac's ordinary path, with its ordinary change notice.
        _ = try await registry.save(project)
        let after = try await registry.cloudLeanProjects()
        if refresh(after) { await memory() }
        return project
    }
    /// For lane A's memory (`DeckMemoryStore.cloudSetProjectResolver`): memory scoped to a project is placed under the
    /// SAME id once that project is on this Mac (G: arrived or made here; no folder needed). Answered from memory.
    public nonisolated func memoryResolver() -> DeckMemoryCloudProjectResolver {
        let confirmed = self.confirmed
        return { incoming, _ in confirmed.contains(incoming) ? incoming : nil }
    }
    /// Two rules as one resolver: the first that knows the project answers (lane A's lean rule, then this one).
    public static func combined(_ first: @escaping DeckMemoryCloudProjectResolver, _ second: @escaping DeckMemoryCloudProjectResolver) -> DeckMemoryCloudProjectResolver {
        { incoming, origin in first(incoming, origin) ?? second(incoming, origin) }
    }
    /// The adapter for this owner and one signed-in account. Lane A's wiring registers it through
    /// `CloudBrainRecordActivation`; nothing here registers itself.
    public nonisolated func adapter(store: CloudBrainAgentsStore, account: CloudBrainAgentsAccount, origins: CloudBrainRecordOrigins) throws -> CloudBrainRecordAdapter {
        try deletes.bind(store: store, account: account)
        return try CloudBrainRecordAdapter(domain: Self.domain, inventoryRow: Self.inventoryRow, sourceId: Self.sourceID, kinds: [Self.kind], store: store,
            account: account, owner: self, origins: origins, exclusions: Self.exclusions)
    }
    /// `serviceTime`: the sync engine's service clock (`engine.serviceTime()`); the keeper Bin ages by it only.
    public nonisolated func configureDeleteRule(gate: @escaping @Sendable () async -> Bool, macNames: @escaping @Sendable (String) async -> String,
                                                serviceTime: (@Sendable () -> Int64?)? = nil) {
        deletes.configure(gate: gate, macNames: macNames, serviceTime: serviceTime)
    }
    public func setEntryWriters(remove: @escaping @Sendable (String) async throws -> Void,
                                restore: @escaping @Sendable (PROJProject) async throws -> Void) {
        removeEntry = remove; restoreEntry = restore
    }
    private func removeProjectEntry(_ id: String) async throws {
        // Without a writer of its own, the registry's entry-only removal (what the app connects anyway).
        guard let removeEntry else { try await registry.cloudDeleteEntryOnly(id); return }
        try await removeEntry(id)
    }
    /// J-4: only the registry entry is hidden. Its complete folder map is saved locally for Bring back.
    public func removeFromThisMac(_ id: String) async throws {
        guard id != PROJProjects.independentID, let project = try await registry.cloudLeanProjects().first(where: { $0.id == id }) else { throw CloudFailure.invalidRequest }
        let entity = Self.kind.entity(id)
        try deletes.save(entity, project.wireValue)
        try deletes.clearIntent(entity)
        try deletes.mark(entity, .notOnThisMac, at: deletes.now())
        do { try await removeProjectEntry(id) }
        catch { try deletes.clearMark(entity); throw error }
        _ = refresh(try await registry.cloudLeanProjects())
        await display()
    }
    public func cloudLocalOnly(entity: String) async throws -> Bool { try deletes.mark(entity) != nil }
    public func cloudRestoring(entity: String) async throws -> Bool { try deletes.restoring(entity) }
    public func cloudCaptured(entity: String, removed: Bool) async throws { try deletes.captured(entity, removed: removed) }
    public func cloudPendingRemovals() async throws -> [String] { try deletes.pending(prefix: "project:") }
    public func cloudRemovalBase(entity: String) async throws -> NativeRPCValue? { try deletes.saved(entity) }
    public func cloudMissing(entity: String, last: NativeRPCValue) async throws -> CloudBrainRecordMissing {
        guard let intent = try deletes.intent(entity) else { return .keep }
        let open = await deletes.isOpen()
        let name = await deletes.macName(intent.mac)
        return .remove(metadata: open && UUID(uuidString: intent.group) != nil ? RecordsDeleteLedger.metadata(intent, macName: name) : nil)
    }
    public func cloudTombstone(entity: String, removal: NativeRPCValue, device: String, at: Int64) async throws {
        guard let mark = try deletes.mark(entity), let saved = try deletes.saved(entity) else { return }
        let actor = try await deletes.arriving(removal, entity: entity, device: device, at: at)
        try deletes.putBin(kind: "project", entity: entity, name: saved["name"].string ?? "Project", value: saved, actor: actor)
        if mark.mark == .onlyOnThisMac, removal["deletedScope"].string != CloudDeleteScope.cloud.rawValue,
           let id = Self.kind.id(of: entity) {
            do { try await removeProjectEntry(id) }
            catch let error as NativeRPCError { throw CloudRecordRefusal(reason: error.message) }
            try deletes.clearMark(entity)
            _ = refresh(try await registry.cloudLeanProjects())
            await display()
        }
    }
    public func cloudRemove(entity: String, expecting: NativeRPCValue?, removal: NativeRPCValue, device: String, at: Int64) async throws {
        guard let id = Self.kind.id(of: entity), id != PROJProjects.independentID else { throw CloudFailure.invalidRequest }
        let projects = try await registry.cloudLeanProjects()
        guard let project = projects.first(where: { $0.id == id }) else { return }
        guard CloudBrainRecordAdapter.equal(Self.kept(project), expecting) else { throw CloudRecordRefusal(reason: "This project changed while its removal arrived.") }
        let actor = try await deletes.arriving(removal, entity: entity, device: device, at: at)
        try deletes.putBin(kind: "project", entity: entity, name: project.name, value: project.wireValue, actor: actor)
        try deletes.save(entity, project.wireValue)
        if removal["deletedScope"].string == CloudDeleteScope.cloud.rawValue {
            try deletes.mark(entity, .onlyOnThisMac, at: actor.at)
        } else {
            do { try await removeProjectEntry(id) }
            catch let error as NativeRPCError { throw CloudRecordRefusal(reason: error.message) }
            _ = refresh(try await registry.cloudLeanProjects())
        }
    }
    public func deleteItems(_ items: [CloudDeleteItem], scope: CloudDeleteScope, by actor: CloudDeleteActor) async throws -> CloudBinGroup {
        if scope == .cloud, !(await deletes.isOpen()) { throw NativeRPCError.invalidArguments(CloudDeleteWords.cloudNeedsUpdatedMacs) }
        var removed: [CloudDeleteItem] = []
        for item in items {
            let id = Self.kind.id(of: item.id) ?? item.id
            guard id != PROJProjects.independentID, let project = try await registry.cloudLeanProjects().first(where: { $0.id == id }) else { continue }
            let entity = Self.kind.entity(id)
            try deletes.putBin(kind: "project", entity: entity, name: project.name, value: project.wireValue, actor: actor)
            try deletes.save(entity, project.wireValue)
            try deletes.clearRestoring(entity)
            try deletes.saveIntent(actor.intent(place: entity, scope: scope))
            if scope == .cloud { try deletes.mark(entity, .onlyOnThisMac, at: actor.at) }
            else {
                do { try await removeProjectEntry(id); try deletes.clearMark(entity) }
                catch { try deletes.clearIntent(entity); throw error }
            }
            removed.append(.init(id: entity, kind: "project", name: project.name))
        }
        _ = refresh(try await registry.cloudLeanProjects())
        await display()
        return .init(id: actor.group, by: actor.by, macName: actor.macName, session: actor.session, agent: actor.agent, at: actor.at, items: removed)
    }
    public func bringBack(_ items: [CloudDeleteItem], to: CloudBringBackDestination) async throws -> [CloudDeleteItem] {
        var restored: [CloudDeleteItem] = []
        for item in items {
            guard let id = Self.kind.id(of: item.id), let saved = try deletes.saved(item.id) else { continue }
            let current = try await registry.cloudLeanProjects().first { $0.id == id }
            var project = try JSONDecoder().decode(PROJProject.self, from: saved.encodedJSON())
            let newest = try deletes.newest(item.id, table: Self.kind.table)
            if to == .thisMac, newest == nil, try deletes.hasHistory(item.id, domain: Self.domain) { continue }
            if to == .thisMac, let newest {
                project.name = newest["name"].string ?? project.name
                project.icon = newest["icon"].string ?? project.icon
                project.colour = newest["colour"].string ?? project.colour
                project.lead = newest["lead"].string ?? project.lead
                project.leadName = newest["leadName"].string ?? project.leadName
            } else if let current { project = current }
            // save restores the local folder MAP. It never reads, writes or removes anything in those folders.
            _ = try await registry.save(project)
            try deletes.clearMark(item.id); try deletes.clearIntent(item.id)
            try deletes.save(item.id, project.wireValue, restoring: to == .cloud)
            if to == .cloud { try deletes.takeBin(item.id) }
            restored.append(item)
        }
        _ = refresh(try await registry.cloudLeanProjects())
        await display()
        return restored
    }
    public func notHere() async throws -> [CloudNotHereItem] {
        try deletes.marks().compactMap { mark in
            guard Self.kind.id(of: mark.place) != nil, let saved = try deletes.saved(mark.place) else { return nil }
            return .init(item: .init(id: mark.place, kind: "project", name: saved["name"].string ?? "Project"), mark: mark.mark, at: mark.at)
        }
    }
    public func binGroups() async throws -> [CloudBinGroup] {
        RecordsDeleteLedger.groups(try deletes.binRows(kind: "project").map { ($0.item, $0.actor) })
    }
    public func putBackGroup(_ group: String) async throws -> [CloudDeleteItem] { try await putBackAll(group).restored }
    /// "Put back all" (lead decision 4): every item is tried; one that fails never stops the rest. The answer names
    /// what came back and what did not.
    public func putBackAll(_ group: String) async throws -> RecordsPutBackAnswer {
        var restored: [CloudDeleteItem] = [], failed: [CloudDeleteItem] = []
        for row in try deletes.binRows(kind: "project") where row.actor.group == group {
            do {
                try deletes.save(row.item.id, row.value)
                guard try await bringBack([row.item], to: .cloud).count == 1 else { throw CloudFailure.unavailable }
                try deletes.takeBin(row.item.id)
                restored.append(row.item)
            } catch { failed.append(row.item) }
        }
        return .init(restored: restored, notRestored: failed)
    }
    public func deleteForGood(_ items: [CloudDeleteItem]) async throws {
        for item in items {
            try deletes.takeBin(item.id, permanently: true)
            if try deletes.mark(item.id) == nil { try deletes.clearSaved(item.id) }
        }
    }

}
