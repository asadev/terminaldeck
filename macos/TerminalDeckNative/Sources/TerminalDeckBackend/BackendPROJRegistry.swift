import Foundation
import TerminalDeckNativeCore

/// One persisted registry. Reads do not create files or migrate the person's data.
/// Review fix F (15 Nov, Decker): where the projects' delete owner takes a removal made in the app or by its tool, so
/// it goes EVERYWHERE under the delete rule (Bin 30 days). Empty = no account bound: removed here as before.
public final class BackendPROJDeleteRuleSlot: @unchecked Sendable {
    private let lock = NSLock()
    private var remover: (@Sendable (String) async throws -> Bool)?
    public init() {}
    public func set(_ remover: (@Sendable (String) async throws -> Bool)?) { lock.withLock { self.remover = remover } }
    var current: (@Sendable (String) async throws -> Bool)? { lock.withLock { remover } }
}

public actor BackendPROJRegistry {
    /// Review fix F: the projects' delete owner registers here (BackendCloudLeanProjects).
    public nonisolated let deleteRule = BackendPROJDeleteRuleSlot()
    private struct State: Codable {
        var projects: [PROJProject]
        var activeProjectID: String?
    }
    /// The saved file read project by project, so one entry that no longer reads costs only that entry (U1).
    private struct SavedFile: Decodable {
        var projects: [SavedRow]
        var activeProjectID: String?
    }
    private struct SavedRow: Decodable {
        let project: PROJProject?
        init(from decoder: Decoder) throws { project = try? PROJProject(from: decoder) }
    }
    public static let maximumFileBytes = 1_048_576
    private var cloudArchive: BackendCloudBrainAgentsArchive?
    private var cloudImporting = false, cloudCaptureFailed = false
    private var cloudRootsAccount: CloudBrainAgentsAccount?
    private var cloudRoots: [String: [String: String]] = [:]
    private var cloudMapped: [String: String] = [:]
    private var cloudPublished = Set<CloudBrainProjectRoot>()
    private let fileURL: URL
    private let writable: Bool
    private let changeNotice: @Sendable (NativeRPCValue) async -> Void
    /// Lane A2 lean (review M2): told when a project gains its FIRST folder on this Mac by any path. Each answers
    /// false once its owner is gone and is then dropped.
    private var cloudLeanFolderWatchers: [Int: @Sendable () async -> Bool] = [:]
    private var cloudLeanNextWatcher = 0
    /// Set by `persist` when a project went from no folder to a folder; cleared when the watchers were told.
    private var cloudLeanFolderGained = false
    private var loaded = false
    /// U1: why some saved projects are missing; `blocked` when not even a copy of the file could be kept.
    private var problem: String?, blocked = false
    /// A new install has Independent only; the person's own projects come from the saved file.
    private var state = State(projects: [PROJProjects.independent], activeProjectID: nil)
    public init(fileURL: URL, writable: Bool = true, changed: @escaping @Sendable (NativeRPCValue) async -> Void = { _ in }) {
        self.fileURL = fileURL; self.writable = writable; self.changeNotice = changed
    }
    /// The registry's one change point: every save, selection, removal and lead change of this registry ends here,
    /// after `persist`. Lane A2's lean projects owner is told when a project gained its first folder, so memory that
    /// waited for it is placed whichever screen or tool added the folder (review M2).
    private func changed(_ value: NativeRPCValue) async {
        await changeNotice(value)
        guard cloudLeanFolderGained else { return }
        cloudLeanFolderGained = false
        var gone: [Int] = []
        for (number, watcher) in cloudLeanFolderWatchers.sorted(by: { $0.key < $1.key }) {
            if !(await watcher()) { gone.append(number) }
        }
        for number in gone { cloudLeanFolderWatchers[number] = nil }
    }
    /// Lane A2 lean: `watcher` runs after any change that gave a project its first folder; it answers false when its
    /// owner is gone. Display and memory placement only: it must start no work.
    public func cloudLeanWhenFolderAdded(_ watcher: @escaping @Sendable () async -> Bool) {
        cloudLeanFolderWatchers[cloudLeanNextWatcher] = watcher
        cloudLeanNextWatcher += 1
    }
    /// Where project logos live: `project-logos` beside the registry file, in the app's data folder (as the screen keeps them).
    public nonisolated var logoDirectory: URL { fileURL.deletingLastPathComponent().appendingPathComponent(BackendPROJLogos.folderName, isDirectory: true) }
    private static func text(_ value: String, maximum: Int, optional: Bool = false) -> Bool {
        value.utf8.count <= maximum && !value.contains("\0") && (optional || !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }
    private static func validate(_ project: PROJProject) throws {
        guard PROJProjects.isValidID(project.id),
              text(project.name, maximum: 256), text(project.icon, maximum: 128), text(project.colour, maximum: 64, optional: true),
              text(project.logo, maximum: 200, optional: true), !project.logo.contains("/"), !project.logo.hasPrefix("."),
              AGTSeats.isValidLead(project.lead), text(project.leadName, maximum: 200, optional: true),
              project.folders.count <= 32,
              project.folders.allSatisfy({ text($0, maximum: 4096) && $0.hasPrefix("/") }) else {
            throw NativeRPCError.invalidArguments("Use a project id up to 128 letters, numbers or dashes, starting with a lowercase letter or number; a name, icon and at most 32 full folder paths are also needed.")
        }
    }
    private func load() throws {
        guard !loaded else { return }
        do {
            if let saved = try Self.read(fileURL) {
                state = saved.state
                if saved.skipped > 0 { keepDamaged("\(saved.skipped == 1 ? "One saved project" : "\(saved.skipped) saved projects") could not be read and \(saved.skipped == 1 ? "is" : "are") left out. ") }
            }
        } catch {
            // U1: a registry that does not read at all leaves Independent only, and is kept before anything is saved.
            keepDamaged("")
        }
        loaded = true
        PROJProjects.publishRegistered(state.projects)
    }
    private func keepDamaged(_ lead: String) {
        let copy = DamagedFile.keepCopy(of: fileURL)
        problem = lead + DamagedFile.sentence("The saved project list", copy: copy); blocked = copy == nil
        NSLog("[projects] %@", problem ?? "")
    }
    /// Why some saved projects are missing, until the next save.
    public func loadProblem() -> String? { try? load(); return problem }
    /// At app start, before sessions and memory: the saved projects become the live list at once (read only;
    /// the registry itself loads the same file again later). A missing or unreadable file leaves Independent only.
    public static func publishSaved(fileURL: URL) {
        guard let saved = try? read(fileURL) else { return }
        PROJProjects.publishRegistered(saved.state.projects)
    }
    /// The saved registry, checked and normalised, with how many entries were left out because they do not
    /// read (U1: a bad entry costs only itself); nil when there is no file.
    private static func read(_ fileURL: URL) throws -> (state: State, skipped: Int)? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        do {
            let handle = try FileHandle(forReadingFrom: fileURL)
            defer { try? handle.close() }
            let bytes = try handle.read(upToCount: Self.maximumFileBytes + 1) ?? Data()
            guard bytes.count <= Self.maximumFileBytes else { throw NativeRPCError.invalidArguments("The project registry is too large to read.") }
            let saved = try JSONDecoder().decode(SavedFile.self, from: bytes)
            var decoded = State(projects: [], activeProjectID: saved.activeProjectID)
            for row in saved.projects {
                // At most 256 projects, room for Independent always left.
                guard let project = row.project, (try? Self.validate(project)) != nil, !decoded.projects.contains(where: { $0.id == project.id }),
                      project.id == PROJProjects.independentID || decoded.projects.filter({ $0.id != PROJProjects.independentID }).count < 255 else { continue }
                decoded.projects.append(project)
            }
            let skipped = saved.projects.count - decoded.projects.count
            if !decoded.projects.contains(where: { $0.id == PROJProjects.independentID }) { decoded.projects.append(PROJProjects.independent) }
            for index in decoded.projects.indices {
                decoded.projects[index].folders = Array(Set(decoded.projects[index].folders.map(PROJProjects.normalize))).sorted()
                if decoded.projects[index].colour.isEmpty {
                    decoded.projects[index].colour = decoded.projects[index].id == PROJProjects.independentID
                        ? PROJProjects.independent.colour : PROJProjects.colours[index % PROJProjects.colours.count]
                }
            }
            if let active = decoded.activeProjectID, !Self.text(active, maximum: 128) || !decoded.projects.contains(where: { $0.id == active }) {
                decoded.activeProjectID = nil
            }
            return (decoded, skipped)
        }
    }
    public func requireWritable() throws {
        guard writable else { throw NativeRPCError(code: "read-only", message: "Project settings are read-only in this app.") }
    }
    private func persist(_ next: State) throws {
        try requireWritable()
        if blocked { throw NativeRPCError(code: "projects-unreadable", message: problem ?? DamagedFile.sentence("The saved project list", copy: nil)) }
        guard next.projects.count <= 256 else { throw NativeRPCError.invalidArguments("The registry supports at most 256 projects.") }
        let bytes = try JSONEncoder().encode(next)
        guard bytes.count <= Self.maximumFileBytes else { throw NativeRPCError.invalidArguments("The project registry is too large to save.") }
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try bytes.write(to: fileURL, options: .atomic)
        let hadFolder = Set(state.projects.filter { !$0.folders.isEmpty }.map { $0.id })
        if next.projects.contains(where: { !$0.folders.isEmpty && !hadFolder.contains($0.id) }) { cloudLeanFolderGained = true }
        state = next; problem = nil
        PROJProjects.publishRegistered(next.projects)
        cloudCaptureWritten()
    }
    // MARK: Cloud (lane A2). Folders travel as stable rootIds; absolute paths stay on this Mac (design D4, finding 11).
    public func cloudAttach(_ account: CloudBrainAgentsAccount) throws {
        if cloudArchive == nil { cloudArchive = .init(ownerDirectory: fileURL.deletingLastPathComponent(), namespace: "projects", domains: ["projects"]) }
        try cloudArchive!.attach(account)
        if cloudRootsAccount != account {
            cloudRootsAccount = account; cloudRoots = [:]; cloudPublished = []; cloudMapped = [:]
            if let value = try cloudRootsStore().read("roots.json") {
                for row in value["roots"].elements ?? [] {
                    guard let project = row["projectId"].string, let root = row["rootId"].string, UUID(uuidString: root) != nil,
                          let path = row["path"].string, path.hasPrefix("/") else { throw CloudFailure.invalidRequest }
                    cloudRoots[project, default: [:]][path] = root
                }
            }
        }
    }
    public func cloudDetach() { cloudArchive?.detach(); cloudRootsAccount = nil; cloudRoots = [:]; cloudPublished = []; cloudMapped = [:] }
    private func cloudRootsStore() throws -> BackendTaskPersistence {
        guard let account = cloudRootsAccount else { throw CloudFailure.gateClosed }
        return try .init(directory: try account.directory(owner: fileURL.deletingLastPathComponent(), namespace: "projects"), ownership: .exclusive)
    }
    /// A rootId is assigned once per (project, folder) on the Mac that first registered the folder, and learned
    /// from the shared record on every other Mac. It is never derived from the path or the device.
    private func cloudAssignRoots(_ projects: [PROJProject]) throws {
        var next = cloudRoots
        for project in projects { for folder in project.folders where next[project.id]?[folder] == nil { next[project.id, default: [:]][folder] = UUID().uuidString.lowercased() } }
        try cloudSaveRoots(next)
    }
    private func cloudSaveRoots(_ next: [String: [String: String]]) throws {
        guard next != cloudRoots else { return }
        let rows = next.keys.sorted().flatMap { project in (next[project] ?? [:]).keys.sorted().map { path in
            NativeRPCValue.object([.init("projectId", .string(project)), .init("rootId", .string(next[project]![path]!)), .init("path", .string(path))]) } }
        try cloudRootsStore().write("roots.json", value: .object([.init("v", .number(1)), .init("roots", .array(rows))]))
        cloudRoots = next
    }
    /// The built-in Independent project exists on every Mac; only a changed one is shared.
    private static func cloudRecords(_ projects: [PROJProject]) -> [CloudBrainAgentsRecord] {
        projects.filter { $0 != PROJProjects.independent }.map { .init(domain: "projects", id: $0.id, value: $0.wireValue, projectID: $0.id) }
    }
    private func cloudShape() -> CloudBrainAgentsShape {
        let roots = cloudRoots, mapped = cloudMapped, current = state.projects
        return CloudBrainAgentsShape(show: { op, payload in
            guard payload["id"].string == op.entityId, !payload.has("folders") else { throw CloudFailure.invalidRequest }
            let existing = current.first { $0.id == op.entityId }
            var folders: [String] = []
            for root in payload["roots"].elements ?? [] {
                guard let root = root.string, UUID(uuidString: root) != nil else { throw CloudFailure.invalidRequest }
                if let path = mapped[op.entityId + "\n" + root] ?? roots[op.entityId]?.first(where: { $0.value == root })?.key { folders.append(path) }
            }
            var local = payload.removing("roots").setting("folders", .array(folders.map(NativeRPCValue.string)))
            // A session lead names a process on its origin Mac; this Mac keeps its own lead.
            if payload["lead"].string?.hasPrefix("session:") == true {
                local = local.setting("lead", .string(existing?.lead ?? "")).setting("leadName", .string(existing?.leadName ?? ""))
            }
            var project = try JSONDecoder().decode(PROJProject.self, from: local.encodedJSON())
            project.folders = Array(Set(project.folders.map(PROJProjects.normalize))).sorted()
            try Self.validate(project)
            return project.wireValue
        }, share: { local in
            guard let id = local["id"].string else { throw CloudFailure.invalidRequest }
            guard let folders = local["folders"].elements else { return local }
            let ids = try folders.map { folder -> NativeRPCValue in
                guard let path = folder.string, let root = roots[id]?[path] else { throw CloudFailure.unavailable }
                return .string(root)
            }
            return local.removing("folders").setting("roots", .array(ids))
        })
    }
    private func cloudCaptureWritten() {
        guard !cloudImporting, cloudArchive?.attached == true else { return }
        do {
            try cloudAssignRoots(state.projects)
            try cloudArchive!.capture(Self.cloudRecords(state.projects), sourceID: "project-registry", complete: true, shape: cloudShape())
        } catch { cloudCaptureFailed = true }
    }
    private static let cloudBlocked = ["Dashboards and project logo bytes are not exported by this adapter."]
    public func cloudProjectInventory() throws -> [CloudCoverage] {
        let records = Self.cloudRecords((try Self.read(fileURL))?.state.projects ?? [])
        let failed = cloudCaptureFailed ? ["A save on this Mac could not be recorded for the Cloud yet; the next save or snapshot records it."] : []
        return [try BackendCloudBrainAgentsSupport.coverage(row: "I11", sourceID: "project-registry", records: records,
            blocked: Self.cloudBlocked + failed, attention: cloudArchive?.attention() ?? [])]
    }
    /// From the saved file (what was written), never from an unsaved in-memory change (finding 14).
    public func cloudProjectSnapshot(cut: CloudSnapshotCut) throws -> CloudBrainAgentsExport {
        try load()
        guard cloudArchive?.attached == true else { throw CloudFailure.gateClosed }
        let saved = (try Self.read(fileURL))?.state.projects ?? []
        try cloudAssignRoots(saved)
        try cloudArchive!.capture(Self.cloudRecords(saved), sourceID: "project-registry", complete: true, shape: cloudShape())
        cloudCaptureFailed = false
        return .init(operations: try cloudArchive!.ownOperations(), coverage: try cloudProjectInventory())
    }
    /// Root ids named by Cloud records, so the adapter can look their folders up in the per-device path map first.
    public func cloudWantedRoots(_ incoming: [CloudOperation]) throws -> [String] {
        var wanted = Set<String>()
        let heads = (cloudArchive?.ledger.map { ledger in ledger.keys.flatMap { ledger.heads($0) } } ?? []) + incoming
        for op in heads where op.domain == "projects" {
            for root in op.payload.raw["roots"].elements ?? [] { if let root = root.string { wanted.insert(op.entityId + "\n" + root) } }
        }
        return wanted.sorted()
    }
    public func cloudSetMappedPaths(_ paths: [String: String]) { cloudMapped = paths.filter { $0.value.hasPrefix("/") } }
    /// Every registered folder of this Mac with its stable rootId (tasks use it; the path map publishes it).
    public func cloudProjectRoots() throws -> [CloudBrainProjectRoot] {
        try load()
        if cloudRootsAccount != nil, writable { try cloudAssignRoots(state.projects) }
        return state.projects.flatMap { project in project.folders.compactMap { folder in
            cloudRoots[project.id]?[folder].map { CloudBrainProjectRoot(projectID: project.id, rootID: $0, path: folder) } } }
    }
    public func cloudUnpublishedRoots() throws -> [CloudBrainProjectRoot] { try cloudProjectRoots().filter { !cloudPublished.contains($0) } }
    public func cloudMarkPublished(_ root: CloudBrainProjectRoot) { cloudPublished.insert(root) }
    public func cloudProjectImport(_ operations: [CloudOperation]) throws -> [CloudItemResult] {
        try requireWritable(); try load(); guard problem == nil else { throw CloudFailure.unavailable }
        guard cloudArchive?.attached == true else { throw CloudFailure.gateClosed }
        cloudImporting = true
        defer { cloudImporting = false }
        let current = Dictionary(Self.cloudRecords(state.projects).map { ($0.key, $0.value.raw) }, uniquingKeysWith: { first, _ in first })
        let rootsByOp = cloudRootsByOperation(operations)
        let results = try cloudArchive!.importing(operations, current: { current[$0] }, shape: cloudShape(), validate: { self.cloudValidate($0) },
            write: { try self.cloudWrite($0, rootsByOp: rootsByOp) })
        return results
    }
    public func cloudProjectRefresh() throws -> Int {
        try requireWritable(); try load(); guard problem == nil else { throw CloudFailure.unavailable }
        guard cloudArchive?.attached == true else { throw CloudFailure.gateClosed }
        cloudImporting = true
        defer { cloudImporting = false }
        let current = Dictionary(Self.cloudRecords(state.projects).map { ($0.key, $0.value.raw) }, uniquingKeysWith: { first, _ in first })
        let rootsByOp = cloudRootsByOperation([])
        return try cloudArchive!.refresh(current: { current[$0] }, shape: cloudShape(), validate: { self.cloudValidate($0) },
            write: { try self.cloudWrite($0, rootsByOp: rootsByOp) })
    }
    /// The registry's 256-project limit refuses only the records that do not fit, never the batch (finding 15).
    private func cloudValidate(_ items: [CloudBrainAgentsProjection]) -> [String: String] {
        var count = state.projects.count, refusals: [String: String] = [:]
        for item in items where item.image != nil && !state.projects.contains(where: { $0.id == item.entityID }) {
            if count >= 256 { refusals[item.key] = "this Mac already has the most projects it can hold" } else { count += 1 }
        }
        return refusals
    }
    /// Read before the import starts: the write step must not touch the ledger while the ledger runs the import.
    private func cloudRootsByOperation(_ incoming: [CloudOperation]) -> [String: [String]] {
        var result: [String: [String]] = [:]
        let retained: [CloudOperation] = cloudArchive?.ledger.map { Array($0.operations.values) } ?? []
        for op in retained + incoming where op.domain == "projects" {
            result[op.opId] = (op.payload.raw["roots"].elements ?? []).compactMap(\.string)
        }
        return result
    }
    private func cloudWrite(_ items: [CloudBrainAgentsProjection], rootsByOp: [String: [String]]) throws -> [String: NativeRPCValue?] {
        var next = state, roots = cloudRoots
        for item in items {
            guard let image = item.image else { continue }
            let project = try JSONDecoder().decode(PROJProject.self, from: image.encodedJSON())
            if let index = next.projects.firstIndex(where: { $0.id == project.id }) { next.projects[index] = project } else { next.projects.append(project) }
            // Learn the shared rootIds for the folders this Mac mapped, so the next save shares the same roots.
            for root in rootsByOp[item.operationID] ?? [] {
                if let path = cloudMapped[project.id + "\n" + root] { roots[project.id, default: [:]][PROJProjects.normalize(path)] = root }
            }
        }
        // Atomic owner write, without select/lead callbacks or any task sweep.
        if next.projects != state.projects { try persist(next) }
        try cloudSaveRoots(roots)
        let after = Dictionary(Self.cloudRecords(state.projects).map { ($0.key, $0.value.raw) }, uniquingKeysWith: { first, _ in first })
        return Dictionary(items.map { ($0.key, after[$0.key]) }, uniquingKeysWith: { first, _ in first })
    }
    public func cloudProjectRetained(_ operations: [CloudOperation]) throws -> Bool { try cloudArchive?.retained(operations) ?? false }
    public func cloudProjectVersions() throws -> [CloudOperation] { try cloudArchive?.revisions() ?? [] }
    public func cloudProjectOwnChanges(after: String?, limit: Int) throws -> [CloudOperation] { guard let cloudArchive else { throw CloudFailure.gateClosed }; return try cloudArchive.ownChanges(after: after, limit: limit) }
    public func cloudProjectCursor() throws -> String? { guard let cloudArchive else { throw CloudFailure.gateClosed }; return try cloudArchive.cursor() }
    public func cloudProjectSaveCursor(_ value: String) throws { guard cloudArchive != nil else { throw CloudFailure.gateClosed }; try cloudArchive!.saveCursor(value) }
    public func cloudProjectNotices() -> AsyncStream<Void> {
        guard cloudArchive != nil else { return AsyncStream { $0.finish() } }
        return cloudArchive!.notices()
    }
    // MARK: Cloud, lean first version (lane A2, `BackendCloudLeanProjects`). A project's folders are this Mac's own:
    // they never travel and nothing from the Cloud adds, removes or reorders one. Costs nothing while Cloud is off.
    /// Every saved project, or an error while the saved list is damaged (nothing may then count as removed).
    public func cloudLeanProjects() throws -> [PROJProject] {
        try load()
        if problem != nil { throw CloudFailure.unavailable }
        return state.projects
    }
    /// The project exactly as `cloudLeanWrite` would store it: this Mac's own folders (none for a project new here)
    /// and a colour when none came. Writes nothing.
    public func cloudLeanPlan(_ incoming: PROJProject) throws -> PROJProject {
        try requireWritable(); try load()
        if problem != nil { throw CloudFailure.unavailable }
        let existing = state.projects.first { $0.id == incoming.id }
        guard existing != nil || state.projects.count < 256 else { throw NativeRPCError.invalidArguments("This Mac already has the most projects it can hold.") }
        var project = incoming
        project.folders = existing?.folders ?? []
        if project.colour.isEmpty {
            project.colour = existing?.colour ?? PROJProjects.colours[state.projects.filter { $0.id != PROJProjects.independentID }.count % PROJProjects.colours.count]
        }
        try Self.validate(project)
        return project
    }
    /// Stores a project that arrived from the Cloud: one atomic save, no change notice, no selection change, no lead sweep.
    public func cloudLeanWrite(_ incoming: PROJProject) throws {
        let project = try cloudLeanPlan(incoming)
        var next = state
        if let index = next.projects.firstIndex(where: { $0.id == project.id }) { next.projects[index] = project } else { next.projects.append(project) }
        if next.projects != state.projects { try persist(next) }
    }
    /// Delete rule (projects "Everywhere" / an arriving removal / "Remove from this Mac"): removes the project's ENTRY
    /// from this Mac's list and nothing else. One atomic save: no change notice, no lead sweep, no session closed, no
    /// task touched, and no folder or file read, moved or deleted. This Mac's folder map for the project (its
    /// rootIds in `roots.json`) is kept, so a later put back finds the same folders.
    public func cloudDeleteEntryOnly(_ id: String) throws {
        try requireWritable(); try load()
        if problem != nil { throw CloudFailure.unavailable }
        guard id != PROJProjects.independentID else { throw CloudFailure.invalidRequest }
        var next = state
        next.projects.removeAll { $0.id == id }
        if next.activeProjectID == id { next.activeProjectID = nil }
        if next.projects != state.projects || next.activeProjectID != state.activeProjectID { try persist(next) }
    }
    /// Delete rule put back: adds the project's ENTRY again exactly as this Mac kept it (its own folder map from this
    /// Mac's Bin copy; never a folder from another device). One atomic save: no change notice, no lead sweep, no
    /// session started or closed, and no folder or file touched.
    public func cloudPutBackEntryOnly(_ incoming: PROJProject) throws {
        try requireWritable(); try load()
        if problem != nil { throw CloudFailure.unavailable }
        guard incoming.id != PROJProjects.independentID else { throw CloudFailure.invalidRequest }
        let index = state.projects.firstIndex { $0.id == incoming.id }
        guard index != nil || state.projects.count < 256 else {
            throw NativeRPCError.invalidArguments("This Mac already has the most projects it can hold.")
        }
        var project = incoming
        project.folders = Array(Set(project.folders.map(PROJProjects.normalize))).sorted()
        try Self.validate(project)
        var next = state
        if let index { next.projects[index] = project } else { next.projects.append(project) }
        if next.projects != state.projects { try persist(next) }
    }
    // MARK: Project folders (`BackendProjectFolders`): this Mac's own folders, never sent.
    /// Gives a project that has NO folder on this Mac the folder the app just made for it. Saved through the ordinary
    /// change point (the side panel, boot files and memory hear of it as of a folder he added). False, and nothing
    /// written, when the project is gone or already has a folder (his choice stands).
    public func placeFolder(projectID: String, folder: String) async throws -> Bool {
        try requireWritable(); try load()
        if problem != nil { throw CloudFailure.unavailable }
        guard projectID != PROJProjects.independentID, let index = state.projects.firstIndex(where: { $0.id == projectID }),
              state.projects[index].folders.isEmpty else { return false }
        var next = state
        next.projects[index].folders = [PROJProjects.normalize(folder)]
        try Self.validate(next.projects[index])
        try persist(next)
        await changed(try snapshot())
        return true
    }
    /// "Use another folder": the project's folder on this Mac becomes `folder`, and only it (the list is kept sorted on
    /// every save and read, so keeping other folders would let one of them show first instead of his choice). No
    /// folder on disk is touched. Two projects never share one folder.
    public func useFolder(projectID: String, folder: String) async throws -> PROJProject {
        try requireWritable(); try load()
        guard projectID != PROJProjects.independentID, let index = state.projects.firstIndex(where: { $0.id == projectID }) else {
            throw NativeRPCError.invalidArguments("Choose a project from the project list.")
        }
        let path = PROJProjects.normalize(folder)
        if let other = state.projects.first(where: { $0.id != projectID && $0.folders.contains { PROJProjects.normalize($0) == path } }) {
            throw NativeRPCError.invalidArguments("This folder is already the folder of \(other.name). Choose another one.")
        }
        var next = state, project = state.projects[index]
        project.folders = [path]
        try Self.validate(project)
        next.projects[index] = project
        try persist(next)
        await changed(try snapshot())
        return project
    }
    public func projects() throws -> [PROJProject] { try load(); return state.projects }
    public func activeProjectID() throws -> String? { try load(); return state.activeProjectID }
    public func snapshot() throws -> NativeRPCValue {
        try load()
        return .object([.init("projects", .array(state.projects.map(\.wireValue))), .init("activeProjectId", state.activeProjectID.map(NativeRPCValue.string) ?? .null)])
    }
    public func resolve(projectID: String?, folder: String?) throws -> String {
        try load(); return PROJProjects.resolve(projectID: projectID, folder: folder, projects: state.projects)
    }
    public func select(_ projectID: String?) async throws -> NativeRPCValue {
        try requireWritable(); try load()
        if let projectID, !state.projects.contains(where: { $0.id == projectID }) { throw NativeRPCError.invalidArguments("Choose a project from project_registry_list, or null for all projects.") }
        var next = state; next.activeProjectID = projectID; try persist(next)
        let result = try snapshot(); await changed(result); return result
    }
    /// Remove an empty registry entry only. A project with folders or a lead must be kept.
    public func removeEmpty(_ id: String) async throws -> NativeRPCValue {
        try requireWritable(); try load()
        guard id != PROJProjects.independentID, let project = state.projects.first(where: { $0.id == id }),
              project.folders.isEmpty, project.lead.isEmpty else {
            throw NativeRPCError.invalidArguments("Only an empty project without a lead can be removed.")
        }
        // Review fix F: through the delete rule when an account is bound (everywhere; his folders and files stay).
        if let remover = deleteRule.current, try await remover(id) {
            try load(); let value = try snapshot(); await changed(value); return value
        }
        try load()
        var next = state; next.projects.removeAll { $0.id == id }
        if next.activeProjectID == id { next.activeProjectID = nil }
        try persist(next); let value = try snapshot(); await changed(value); return value
    }
    public func save(_ project: PROJProject) async throws -> NativeRPCValue {
        try requireWritable(); try load(); try Self.validate(project)
        var next = state, normalized = project
        normalized.folders = Array(Set(project.folders.map(PROJProjects.normalize))).sorted()
        if normalized.colour.isEmpty {
            normalized.colour = state.projects.first { $0.id == project.id }?.colour
                ?? PROJProjects.colours[state.projects.filter { $0.id != PROJProjects.independentID }.count % PROJProjects.colours.count]
        }
        if let index = next.projects.firstIndex(where: { $0.id == project.id }) { next.projects[index] = normalized }
        else { next.projects.append(normalized) }
        try persist(next); let result = normalized.wireValue
        await changed(try snapshot()); return result
    }
    /// Deck Memory: one lead per project (`agent:<id>` / `session:<id>`), or nil for none.
    /// Independent never has a lead. An agent or session leads at most one project.
    public func setLead(projectID: String, lead: String?, leadName: String?) async throws -> NativeRPCValue {
        try requireWritable(); try load()
        guard projectID != PROJProjects.independentID, let index = state.projects.firstIndex(where: { $0.id == projectID }) else {
            throw NativeRPCError.invalidArguments("Choose a project from project_registry_list. Independent has no lead.")
        }
        let value = lead ?? ""
        guard AGTSeats.isValidLead(value), Self.text(leadName ?? "", maximum: 200, optional: true) else {
            throw NativeRPCError.invalidArguments("A lead is agent:<agent id>, session:<session id>, or null for none.")
        }
        var next = state
        if !value.isEmpty {
            for other in next.projects.indices where other != index && next.projects[other].lead == value {
                next.projects[other].lead = ""; next.projects[other].leadName = ""
            }
        }
        next.projects[index].lead = value
        next.projects[index].leadName = value.isEmpty ? "" : (leadName ?? "")
        try persist(next); let result = next.projects[index].wireValue
        await changed(try snapshot())
        Task { await BackendAGTLeadSeats.shared?.sweep() }   // tasks the seat holds go to whoever fills it now
        return result
    }
    /// The app's one registry, set by composition (agent removal clears a lead through it).
    private static let installedLock = NSLock()
    nonisolated(unsafe) private static var installedRegistry: BackendPROJRegistry?
    public static var installed: BackendPROJRegistry? {
        get { installedLock.withLock { installedRegistry } }
        set { installedLock.withLock { installedRegistry = newValue } }
    }
    /// A project whose lead is a saved agent that no longer exists gets no lead (the lead seat keeps its
    /// memory, so it shows as vacant with memory). Returns the projects changed.
    @discardableResult
    public func clearLeads(whereAgentIsGone gone: @Sendable (String) -> Bool) async throws -> [String] {
        try load()
        var next = state, changed: [String] = []
        for index in next.projects.indices {
            let lead = next.projects[index].lead
            guard lead.hasPrefix("agent:"), gone(String(lead.dropFirst("agent:".count))) else { continue }
            next.projects[index].lead = ""; next.projects[index].leadName = ""; changed.append(next.projects[index].id)
        }
        guard !changed.isEmpty else { return [] }
        try persist(next); await self.changed(try snapshot())
        Task { await BackendAGTLeadSeats.shared?.sweep() }
        return changed
    }
    /// Filters arbitrary rows and backfills returned projectId only. Explicit IDs win.
    public func filter(_ rows: [NativeRPCValue], projectID: String?, folderKey: String = "folder") throws -> [NativeRPCValue] {
        try load()
        if let projectID, !state.projects.contains(where: { $0.id == projectID }) { throw NativeRPCError.invalidArguments("Unknown project id.") }
        return rows.compactMap { row in
            if row["projectScope"].string == "all" { return row.setting("projectName", .string("Every project")) }
            let folder = row[folderKey].string ?? row["sourceDirectory"].string ?? row["defaultProject"].string ?? row["startIn"].string ?? row["project"].string ?? row["cwd"].string ?? row["root"].string
            let explicit = row["projectIdInferred"].bool == true ? nil : row["projectId"].string ?? row["projectID"].string
            let id = PROJProjects.resolve(projectID: explicit, folder: folder, projects: state.projects)
            return projectID == nil || id == projectID ? row.setting("projectId", .string(id)).setting("projectName", .string(PROJProjects.name(for: id, projects: state.projects))) : nil
        }
    }
}
