import Darwin
import Foundation
import TerminalDeckNativeCore

/// Project folders on a Mac (owner, 14 Nov 2026: "sign in once and everything follows"). A project this Mac knows but
/// has no folder for (it came from his Cloud) gets one BY ITSELF at `<Terminal Deck folder>/Projects/<project name>`,
/// with no question and no click. What the Cloud carries for the project (instruction files, agents, memory, tasks)
/// then lands as it does on a Mac that has the project. Code is never fetched here: the folder holds only what the
/// Cloud carries until he presses "Get the code".
///
/// The rules, all on this Mac only (nothing here travels; the folder path never leaves this Mac):
/// - A project that already has a folder on this Mac is never touched: nothing moves, nothing is copied.
/// - A folder is made ONCE per project. A folder he later moves, deletes or replaces is not made again (the project
///   then shows its calm "not on this Mac" state with "Use another folder"). If the project list loses a project's
///   folder while it is still there, the project is pointed at it again.
/// - The name is the project's name made safe for a folder. A place that is already taken (a folder or file that is not
///   this project's, or another project's folder) is never written into: the next free plain name is used ("Deck 2").
/// - Renaming the project later does not rename or move its folder.
/// - A folder is only ever made (never emptied, overwritten or deleted), and only inside the Terminal Deck folder.
/// - A Mac that cannot write keeps one calm line and tries again a few minutes later.
public actor BackendProjectFolders {
    /// The base folder's name in the home folder, and the projects folder inside it.
    public static let baseName = "Terminal Deck"
    public static let projectsName = "Projects"
    /// How long a Mac that could not write (or a project whose folder could not be made) waits before trying again.
    public static let retrySeconds: Double = 300
    public static let fileName = "project-folders.json"
    /// A folder name's limit in UTF-8 bytes (APFS allows 255; room is left for " 99").
    public static let maximumNameBytes = 200
    /// How many plain names are tried per project ("Deck" … "Deck 99") before it waits and tries again later.
    public static let maximumTries = 99

    /// The default Terminal Deck folder: `~/Terminal Deck`.
    public static func defaultBase(home: String = NSHomeDirectory()) -> URL {
        URL(fileURLWithPath: home, isDirectory: true).appendingPathComponent(baseName, isDirectory: true)
    }

    /// One project as the Settings row, the project page and the tools show it: a name, a folder and two plain facts.
    public struct Row: Sendable, Equatable {
        public let projectID: String
        public let name: String
        /// nil: no folder on this Mac yet.
        public let folder: String?
        /// The folder is there (false = it was moved or deleted; the project shows "Use another folder").
        public let onThisMac: Bool
        /// The app made this folder for a project that came from the Cloud.
        public let madeByApp: Bool
    }

    /// What this Mac keeps (never sent): the chosen base, and each project's folder recorded here, by project id.
    struct Saved: Codable, Equatable {
        struct Made: Codable, Equatable {
            var path: String
            /// The project was pointed at the folder. False only while a save to the project list is still to happen.
            var attached: Bool
            /// false: a folder he chose ("Use another folder"); nil or true: made by the app.
            var byApp: Bool?
            var madeByApp: Bool { byApp != false && !path.isEmpty }
        }
        var base: String?
        var made: [String: Made] = [:]
    }

    /// Read by the Code page and the new-session page without waiting for this actor.
    final class Mirror: @unchecked Sendable {
        private let lock = NSLock()
        private var base: String?
        private var made: Set<String> = []
        func set(base: String?, made: Set<String>) { lock.withLock { self.base = base; self.made = made } }
        func baseNow() -> String? { lock.withLock { base } }
        func madeByApp(_ path: String) -> Bool { lock.withLock { made.contains(PROJProjects.normalize(path)) } }
    }

    /// Why a folder change stops: the whole pass (the disk or the place), or only this project's name.
    private enum Stop: Error { case disk(Error), notConnected }

    private let file: URL
    private let registry: BackendPROJRegistry
    private let home: String
    /// Folders no project and no Terminal Deck folder may point into (the app's own data folder).
    private let protected: [String]
    private let now: @Sendable () -> Double
    private var saved: Saved
    private var retryAt: Double = 0
    /// A project whose folder could not be made for a reason of its own waits; the others go on.
    private var skipUntil: [String: Double] = [:]
    private var line: String?
    private nonisolated let mirror = Mirror()

    /// `file`: this Mac's own record, beside the project list (`<data folder>/project-folders.json`).
    /// `home`: the home folder the default Terminal Deck folder sits in (a scratch folder in tests).
    /// `protected`: the app's own data folder (and any other folder of the app's that must never become a project's).
    public init(file: URL, registry: BackendPROJRegistry, home: String = NSHomeDirectory(), protected: [String] = [],
                now: @escaping @Sendable () -> Double = { Date().timeIntervalSince1970 }) {
        self.file = file; self.registry = registry; self.home = home; self.protected = protected; self.now = now
        let read = (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode(Saved.self, from: $0) } ?? Saved()
        saved = read
        mirror.set(base: read.base, made: Self.madePaths(read))
    }
    private static func madePaths(_ saved: Saved) -> Set<String> {
        Set(saved.made.values.filter(\.madeByApp).map { PROJProjects.normalize($0.path) })
    }

    // MARK: the app's one copy (like `BackendPROJRegistry.installed`)

    private static let installedLock = NSLock()
    nonisolated(unsafe) private static var installedFolders: BackendProjectFolders?
    public static var installed: BackendProjectFolders? {
        get { installedLock.withLock { installedFolders } }
        set { installedLock.withLock { installedFolders = newValue } }
    }
    /// The Terminal Deck folder chosen in Settings while it is there; nil for the default, or while its drive is not
    /// connected (new sessions with no project then start in `~/Terminal Deck/Independent`). Answered without waiting.
    public nonisolated var configuredBase: String? {
        guard let chosen = mirror.baseNow(), Self.isDirectory(chosen) else { return nil }
        return chosen
    }
    /// True when the app made this folder for a project that came from the Cloud. Answered without waiting.
    public nonisolated func madeByApp(_ path: String) -> Bool { mirror.madeByApp(path) }
    /// The home folder this owner works in, and the Terminal Deck folder (chosen or default), without waiting; for
    /// `BackendProjectCode`'s rule that a repository at or above either is never a project's code.
    public nonisolated var homeFolder: String { home }
    public nonisolated var terminalDeckFolder: String { mirror.baseNow() ?? Self.defaultBase(home: home).path }

    /// Code page: the app-made folder still holds only what the Cloud puts there (instruction files, the AI tools' own
    /// folders, Finder's .DS_Store). Anything else he or a session made there means it is his work, not "not here yet".
    public static let cloudOnlyNames: Set<String> = ["CLAUDE.md", "AGENTS.md", "GEMINI.md", "CLAUDE.local.md", ".claude", ".agents",
                                                     ".codex", ".gemini", ".mcp.json", ".DS_Store"]
    public static func holdsOnlyCloudFiles(_ path: String) -> Bool {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: path) else { return false }
        return names.allSatisfy { cloudOnlyNames.contains($0) }
    }

    // MARK: names

    /// The project's name as a folder name: none of `/ \ : ? * " < > |` (other disk formats refuse them), no control
    /// character, no leading dot, trimmed, at most `maximumNameBytes` UTF-8 bytes. A name that leaves nothing is "Project".
    public static func safeName(_ name: String) -> String {
        var scalars = String.UnicodeScalarView()
        let refused: Set<Unicode.Scalar> = ["/", "\\", ":", "?", "*", "\"", "<", ">", "|"]
        for scalar in name.unicodeScalars {
            if refused.contains(scalar) { scalars.append("-"); continue }
            if scalar.properties.generalCategory == .control || scalar == "\u{2028}" || scalar == "\u{2029}" { scalars.append(" "); continue }
            scalars.append(scalar)
        }
        var result = String(scalars).trimmingCharacters(in: .whitespacesAndNewlines)
        while result.hasPrefix(".") { result = String(result.dropFirst()).trimmingCharacters(in: .whitespacesAndNewlines) }
        while result.utf8.count > maximumNameBytes { result.removeLast() }
        result = result.trimmingCharacters(in: .whitespacesAndNewlines)
        while result.hasSuffix(".") { result.removeLast() }
        return result.isEmpty ? "Project" : result
    }
    /// The plain names tried in order: "Deck", "Deck 2", "Deck 3"… Never an id or a code.
    public static func candidates(_ name: String) -> [String] {
        let safe = safeName(name)
        return [safe] + (2...maximumTries).map { "\(safe) \($0)" }
    }

    // MARK: which folders may be used

    /// A folder as an approval line shows it: the whole path, with the home folder as "~".
    public static func shortPath(_ path: String, home: String = NSHomeDirectory()) -> String {
        let full = PROJProjects.normalize(path)
        return full == home ? "~" : full.hasPrefix(home + "/") ? "~" + full.dropFirst(home.count) : full
    }

    /// The folder with every link resolved (a link named "Work" that points into ~/Library is judged as ~/Library).
    static func resolved(_ path: String) -> String {
        guard let real = Darwin.realpath(path, nil) else { return PROJProjects.normalize(path) }
        defer { free(real) }
        return String(cString: real)
    }
    private static func inside(_ path: String, _ folder: String) -> Bool {
        path == folder || path.hasPrefix(folder.hasSuffix("/") ? folder : folder + "/")
    }
    /// Why this folder may not become a project's folder or the Terminal Deck folder, in one plain line; nil when it may.
    /// The same rule for his own folder choice and for a tool.
    /// The check runs on the folder with links resolved, and `use`/`setBase` save that same resolved folder, so a link
    /// re-pointed later never moves a project. Nonisolated: the older `project_registry.save` tool asks it too.
    public nonisolated func refusal(_ folder: String) -> String? {
        Self.refusal(folder, home: home, protected: protected)
    }
    /// The same rule for a caller with no project-folders owner at hand (the real home folder, no protected folders).
    public static func refusal(_ folder: String, home: String = NSHomeDirectory(), protected: [String] = []) -> String? {
        let path = resolved(folder)
        let mine = "Choose a folder of your own: this one belongs to macOS, the app or your settings."
        if path == "/" || path == "/Volumes" { return mine }
        for system in ["/System", "/Library", "/usr", "/bin", "/sbin", "/etc", "/private", "/var", "/tmp", "/dev", "/Applications", "/cores", "/opt"]
            where inside(path, system) { return mine }
        var homes = Set([resolved(home), resolved(NSHomeDirectory())])
        homes.remove("/")
        for folder in homes {
            // The home folder itself, and every folder above it.
            if inside(folder, path) { return "Choose a folder inside your home folder, not the home folder itself." }
            guard inside(path, folder), path != folder else { continue }
            let parts = String(path.dropFirst(folder.count + 1)).split(separator: "/").map(String.init)
            let first = parts.first ?? ""
            if first.hasPrefix(".") { return mine }
            if first == "Library" {
                // His cloud folders live in ~/Library: iCloud Drive (Mobile Documents) and Dropbox, Google Drive,
                // OneDrive (CloudStorage). Folders INSIDE them are his; the two places themselves are not.
                let cloud = parts.count >= 3 && (parts[1] == "Mobile Documents" || parts[1] == "CloudStorage")
                if !cloud { return mine }
            }
        }
        for folder in protected where !folder.isEmpty && inside(path, resolved(folder)) { return mine }
        return nil
    }

    // MARK: the place

    /// The Terminal Deck folder: the one chosen in Settings, else `~/Terminal Deck`.
    public func base() -> URL {
        if let chosen = saved.base, chosen.hasPrefix("/") { return URL(fileURLWithPath: chosen, isDirectory: true) }
        return Self.defaultBase(home: home)
    }
    public func projectsFolder() -> URL { base().appendingPathComponent(Self.projectsName, isDirectory: true) }

    /// At app start (owner: "installing the app makes the Terminal Deck folder with Projects inside"): makes the
    /// default Terminal Deck folder with Projects inside, or Projects inside a chosen one that is there. Never touches
    /// anything already there and never makes a chosen folder whose drive is not connected.
    public func prepare() {
        if saved.base != nil, !Self.isDirectory(base().path) { return }
        try? FileManager.default.createDirectory(at: projectsFolder(), withIntermediateDirectories: true)
    }

    /// Settings › "Terminal Deck folder", by a folder choice he started himself (or a tool, under the same approval
    /// rules as its neighbours). Only a folder that already exists is taken; nothing is made, moved or copied. New
    /// project folders are made in it from now on; folders already made stay where they are. A folder named Projects
    /// (for example `…/Terminal Deck/Projects`) is taken as the Projects folder itself, never `Projects/Projects`.
    public func setBase(_ folder: String) throws -> String {
        let given = PROJProjects.normalize(folder)
        guard given.hasPrefix("/"), Self.isDirectory(given) else { throw NativeRPCError.invalidArguments("Choose a folder that exists on this Mac.") }
        if let refused = refusal(given) { throw NativeRPCError.invalidArguments(refused) }
        // The folder that was judged is the folder saved: links resolved.
        var path = Self.resolved(given)
        let parent = (path as NSString).deletingLastPathComponent
        if (path as NSString).lastPathComponent == Self.projectsName, refusal(parent) == nil { path = parent }
        var next = saved
        next.base = path == Self.resolved(Self.defaultBase(home: home).path) || path == PROJProjects.normalize(Self.defaultBase(home: home).path) ? nil : path
        try write(next)
        retryAt = 0; skipUntil = [:]; line = nil
        return base().path
    }

    /// The one calm line while folders could not be made (the disk is full, the place cannot be written, the drive is
    /// not connected, or one project's name could not be used), else nil.
    public func problem() -> String? { line }

    /// Every project of this Mac except Independent, with its folder here.
    public func rows() async throws -> [Row] {
        let projects = try await registry.projects()
        return projects.filter { $0.id != PROJProjects.independentID }.map { project in
            let folder = project.folders.first
            return Row(projectID: project.id, name: project.name, folder: folder, onThisMac: folder.map(Self.isDirectory) ?? false,
                       madeByApp: folder.map { mirror.madeByApp($0) } ?? false)
        }
    }

    // MARK: making folders

    /// Gives every project of this Mac that has no folder here its folder, then points the project at it. A folder
    /// recorded for the project that is still there is used again (the project list was reset); otherwise one is made,
    /// once. Called after Cloud records arrive and on every look of the project list's Cloud owner; cheap when there is
    /// nothing to do. One project whose folder cannot be made never holds up the others. Returns the projects that got
    /// a folder now.
    @discardableResult
    public func placeMissing() async -> [Row] {
        let time = now()
        guard time >= retryAt else { return [] }
        guard let projects = try? await registry.projects() else { return [] }
        let used = Set(projects.flatMap(\.folders).map { PROJProjects.normalize($0).lowercased() })
        let pending = projects.filter { project in
            guard project.id != PROJProjects.independentID, PROJProjects.isValidID(project.id), project.folders.isEmpty,
                  (skipUntil[project.id] ?? 0) <= time else { return false }
            guard let entry = saved.made[project.id], entry.attached else { return true }
            // Made (or chosen) before and still there: the project list lost it, so it is pointed at it again.
            return !entry.path.isEmpty && Self.isDirectory(entry.path) && !used.contains(PROJProjects.normalize(entry.path).lowercased())
        }.sorted { $0.name == $1.name ? $0.id < $1.id : $0.name < $1.name }
        guard !pending.isEmpty else { return [] }
        var placed: [Row] = [], troubled: String?
        do {
            for project in pending {
                let path: String
                do {
                    if let entry = saved.made[project.id], entry.attached { path = entry.path }
                    else {
                        guard let made = try makeFolder(for: project, used: used) else {
                            // Every plain name is taken: wait, and try this one again later (no flood of tries).
                            skipUntil[project.id] = time + Self.retrySeconds
                            troubled = troubled ?? "The folder for \(project.name) could not be made on this Mac (every name for it is taken). Tried again in a few minutes."
                            continue
                        }
                        path = made
                    }
                } catch let stop as Stop { throw stop }
                catch {
                    // About this project only: it waits; the others carry on.
                    skipUntil[project.id] = time + Self.retrySeconds
                    troubled = troubled ?? "The folder for \(project.name) could not be made on this Mac (the folder could not be made). Tried again in a few minutes."
                    continue
                }
                // The project list is saved through its ordinary change point, so the side panel, boot files and
                // memory hear of the new folder as they do for one he added himself. The folder is not part of what
                // travels, so nothing goes up because of it.
                do {
                    var next = saved
                    if try await registry.placeFolder(projectID: project.id, folder: path) {
                        next.made[project.id] = .init(path: path, attached: true, byApp: saved.made[project.id]?.byApp)
                        placed.append(Row(projectID: project.id, name: project.name, folder: path, onThisMac: true,
                                          madeByApp: next.made[project.id]?.madeByApp == true))
                    } else {
                        // He gave it a folder meanwhile: his choice stands; the empty folder made here is left as it is.
                        next.made[project.id]?.attached = true
                    }
                    try write(next)
                } catch {
                    throw Stop.disk(error)
                }
            }
        } catch Stop.notConnected {
            notConnected()
            return placed
        } catch Stop.disk(let error) {
            fail(error, name: pending.first { p in !placed.contains { $0.projectID == p.id } }?.name ?? pending[0].name)
            return placed
        } catch {
            return placed
        }
        line = troubled
        return placed
    }

    /// The Projects folder, made when missing. A chosen Terminal Deck folder that is not there is never made (its
    /// drive is not connected); the default one is.
    private func projectsParent() throws -> URL {
        let base = base()
        if saved.base != nil, !Self.isDirectory(base.path) { throw Stop.notConnected }
        let parent = projectsFolder()
        do { try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true) }
        catch { throw Stop.disk(error) }
        return parent
    }

    /// Makes the project's own folder and returns its path; reuses the folder made for it on an earlier try that did
    /// not finish. A taken place (a folder, a file or a link of his) is never written into: the next plain name is
    /// tried. A name the disk refuses (too long, a character it cannot hold) falls back to "Project", "Project 2" …
    /// A disk-wide refusal (full, read-only, no permission) stops the pass.
    private func makeFolder(for project: PROJProject, used: Set<String>) throws -> String? {
        if let earlier = saved.made[project.id], !earlier.attached, Self.isDirectory(earlier.path) { return earlier.path }
        let parent = try projectsParent()
        var lists = [Self.candidates(project.name)]
        var index = 0
        while index < lists.count {
            let names = lists[index]; index += 1
            nameRefused: for name in names {
                let path = PROJProjects.normalize(parent.appendingPathComponent(name, isDirectory: true).path)
                if used.contains(path.lowercased()) || saved.made.values.contains(where: { $0.path.lowercased() == path.lowercased() }) { continue }
                // mkdir fails when anything already sits there (folder, file or link), so his things are never taken over.
                if Darwin.mkdir(path, 0o755) == 0 {
                    var next = saved
                    next.made[project.id] = .init(path: path, attached: false, byApp: true)
                    do { try write(next) } catch { _ = Darwin.rmdir(path); throw Stop.disk(error) }
                    return path
                }
                let code = errno
                switch code {
                case EEXIST: continue
                case ENAMETOOLONG, EINVAL, EILSEQ:
                    // The disk refuses this NAME: the plain fallback "Project", "Project 2" … (once).
                    if lists.count == 1, Self.safeName(project.name) != "Project" { lists.append(Self.candidates("Project")) }
                    break nameRefused
                case ENOSPC, EDQUOT, EROFS, EACCES, EPERM: throw Stop.disk(POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO))
                default: throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
                }
            }
        }
        return nil
    }

    private func fail(_ error: Error, name: String) {
        retryAt = now() + Self.retrySeconds
        let underlying = ((error as NSError).userInfo[NSUnderlyingErrorKey] as? NSError)
        let code: Int32? = (error as? POSIXError)?.code.rawValue
            ?? (underlying?.domain == NSPOSIXErrorDomain ? underlying.map { Int32($0.code) } : nil)
        let why: String
        switch code {
        case ENOSPC?, EDQUOT?: why = "the disk is full"
        case EACCES?, EPERM?, EROFS?: why = "this Mac does not allow writing there"
        default: why = "the folder could not be made"
        }
        line = "The folder for \(name) could not be made on this Mac (\(why)). Tried again in a few minutes."
        NSLog("[project folders] %@", line ?? "")
    }
    private func notConnected() {
        retryAt = now() + Self.retrySeconds
        line = base().path.hasPrefix("/Volumes/") ? "The drive with your Terminal Deck folder is not connected."
            : "Your Terminal Deck folder is not on this Mac any more. Choose it again in Settings › General."
    }

    // MARK: "Use another folder"

    /// Points the project at a folder he chose (by his own folder choice, or a tool under the usual approval). The
    /// folder must already exist and be one a project may use (never a system, app or settings folder, never another
    /// project's folder): nothing is made, moved, copied or deleted, and the folder used before stays on disk.
    public func use(projectID: String, folder: String) async throws -> Row {
        let given = PROJProjects.normalize(folder)
        guard given.hasPrefix("/"), Self.isDirectory(given) else { throw NativeRPCError.invalidArguments("Choose a folder that exists on this Mac.") }
        if let refused = refusal(given) { throw NativeRPCError.invalidArguments(refused) }
        // The folder that was judged is the folder saved and used: links resolved (a link re-pointed later moves nothing).
        let real = Self.resolved(given), path = real
        if let other = try await registry.projects().first(where: { $0.id != projectID && $0.folders.contains { Self.resolved($0) == real } }) {
            throw NativeRPCError.invalidArguments("This folder is already the folder of \(other.name). Choose another one.")
        }
        let project = try await registry.useFolder(projectID: projectID, folder: path)
        // From now on this project's folder is his choice; it is pointed at again if the project list is ever reset.
        var next = saved
        next.made[projectID] = .init(path: path, attached: true, byApp: mirror.madeByApp(path) ? true : false)
        try? write(next)
        skipUntil[projectID] = nil
        return Row(projectID: project.id, name: project.name, folder: path, onThisMac: true, madeByApp: mirror.madeByApp(path))
    }

    // MARK: this Mac's record

    private func write(_ next: Saved) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(next)
        try data.write(to: file, options: .atomic)
        saved = next
        mirror.set(base: next.base, made: Self.madePaths(next))
    }

    static func isDirectory(_ path: String) -> Bool {
        var directory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &directory) && directory.boolValue
    }
}

/// The AI's side of project folders (owner rule: everything he can do, an AI can do through the app's tools). Reads run
/// freely; "use another folder" and the Terminal Deck folder ask under the same approval rules as the project tools
/// beside them. No tool makes a folder: both changes only point at a folder that already exists.
public enum BackendProjectFoldersTools {
    public static let ids = ["project_folders.list", "project_folders.use", "project_folders.set_base"]

    public static func register(server: BackendNativeMCPServer, folders: BackendProjectFolders, ownerID: String,
                                authorize: @escaping BackendPROJMCP.Authorize) async throws {
        for (spec, handler) in try contribution(folders: folders, authorize: authorize) {
            try await server.registerTool(spec, ownerID: ownerID, handler: handler)
        }
    }

    public static func contribution(folders: BackendProjectFolders, authorize: @escaping BackendPROJMCP.Authorize) throws -> [(BackendMCPTool, BackendNativeMCPServer.Handler)] {
        let text = NativeRPCValue.object([.init("type", .string("string"))])
        let definitions: [(String, BackendMCPTier, String, [(String, NativeRPCValue)], [String])] = [
            ("project_folders.list", .read, "Where each project's folder is on this Mac: the folder, whether it is there, whether the app made it for a project that came from the Cloud, and the Terminal Deck folder new project folders are made in. Read only.", [], []),
            ("project_folders.use", .alter, "Use another folder for a project on this Mac (\"Use another folder\"); it becomes the project's only folder here. The folder must already exist and be the person's own: system folders, ~/Library, hidden folders in the home folder, the app's data and another project's folder are refused. Nothing is made, moved, copied or deleted, and the folder used before stays where it is. Only this Mac changes.", [("projectId", text), ("folder", text)], ["projectId", "folder"]),
            ("project_folders.set_base", .alter, "Choose the Terminal Deck folder on this Mac: new project folders are made in its Projects folder from now on; existing project folders stay where they are. The folder must already exist and be the person's own (the same folders as project_folders_use are refused); a folder named Projects is used as the Projects folder itself.", [("folder", text)], ["folder"]),
        ]
        return try definitions.map { id, tier, description, properties, required in
            let schema = NativeRPCValue.object([.init("type", .string("object")), .init("properties", .object(properties.map { .init($0.0, $0.1) })),
                .init("required", .array(required.map(NativeRPCValue.string))), .init("additionalProperties", .bool(false))])
            let spec = try BackendMCPTool(id: id, wireName: id.replacingOccurrences(of: ".", with: "_"), description: description, inputSchema: schema, tier: tier)
            let handler: BackendNativeMCPServer.Handler = { caller, args in
                try Task.checkCancellation(); guard !caller.cancellation.isCancelled else { throw CancellationError() }
                guard let fields = args.fields, fields.allSatisfy({ field in properties.contains { $0.0 == field.key } }),
                      required.allSatisfy({ args[$0].string?.isEmpty == false }) else {
                    throw NativeRPCError.invalidArguments("A required or extra project folder argument is invalid.")
                }
                guard caller.allowedTiers.contains(tier) else { throw NativeRPCError(code: "not-granted", message: "This caller does not have the requested project access.") }
                try await authorize(caller, id, args, tier)
                try Task.checkCancellation(); guard !caller.cancellation.isCancelled else { throw CancellationError() }
                switch id {
                case "project_folders.list":
                    let rows = try await folders.rows()
                    var fields: [NativeRPCValue.Field] = [.init("terminalDeckFolder", .string(await folders.base().path)),
                        .init("projects", .array(rows.map(Self.value)))]
                    if let problem = await folders.problem() { fields.append(.init("problem", .string(problem))) }
                    return .value(.object(fields))
                case "project_folders.use":
                    let row = try await folders.use(projectID: try args["projectId"].requireString("projectId", nonempty: true),
                                                    folder: try args["folder"].requireString("folder", nonempty: true))
                    return .value(Self.value(row))
                default:
                    let base = try await folders.setBase(try args["folder"].requireString("folder", nonempty: true))
                    return .value(.object([.init("terminalDeckFolder", .string(base))]))
                }
            }
            return (spec, handler)
        }
    }

    public static func value(_ row: BackendProjectFolders.Row) -> NativeRPCValue {
        .object([.init("projectId", .string(row.projectID)), .init("name", .string(row.name)),
                 .init("folder", row.folder.map(NativeRPCValue.string) ?? .null), .init("onThisMac", .bool(row.onThisMac)),
                 .init("madeByApp", .bool(row.madeByApp))])
    }
}
