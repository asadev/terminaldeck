import Foundation
import TerminalDeckNativeCore

/// One persisted registry. Reads do not create files or migrate the person's data.
public actor BackendPROJRegistry {
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
    private let fileURL: URL
    private let writable: Bool
    private let changed: @Sendable (NativeRPCValue) async -> Void
    private var loaded = false
    /// U1: why some saved projects are missing; `blocked` when not even a copy of the file could be kept.
    private var problem: String?, blocked = false
    /// A new install has Independent only; the person's own projects come from the saved file.
    private var state = State(projects: [PROJProjects.independent], activeProjectID: nil)
    public init(fileURL: URL, writable: Bool = true, changed: @escaping @Sendable (NativeRPCValue) async -> Void = { _ in }) {
        self.fileURL = fileURL; self.writable = writable; self.changed = changed
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
        state = next; problem = nil
        PROJProjects.publishRegistered(next.projects)
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
