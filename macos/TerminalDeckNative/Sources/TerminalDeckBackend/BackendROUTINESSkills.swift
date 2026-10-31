import Foundation
import CryptoKit
import TerminalDeckNativeCore

/// Reuses the project registry, task profiles and the signed community installer.
/// No agent process or skill script ever runs during discovery or installation.
public actor BackendROUTINESSkills {
    public typealias CurrentScope = @Sendable () async throws -> BackendROUTINESSkillsScope
    public struct Dependencies: Sendable {
        public let projects: @Sendable () async throws -> [PROJProject]
        public let profiles: @Sendable () async throws -> [NativeRPCValue]
        public let catalogue: @Sendable () async throws -> NativeRPCValue
        public let install: @Sendable (String, NativeRPCValue) async throws -> NativeRPCValue
        public let remove: @Sendable (String) async throws -> NativeRPCValue
        public let ownedSkill: @Sendable (String) async throws -> NativeRPCValue?
        public let renameOwnedSkill: (@Sendable (String, String, BackendROUTINESSkillsEffectGuard) async throws -> Void)?
        public let changeSkill: (@Sendable (String, String, Bool, String?) async throws -> NativeRPCValue)?
        public let guardedInstall: (@Sendable (String, NativeRPCValue, BackendROUTINESSkillsEffectGuard) async throws -> NativeRPCValue)?
        public let guardedRemove: (@Sendable (String, BackendROUTINESSkillsEffectGuard) async throws -> NativeRPCValue)?
        public let guardedChangeSkill: (@Sendable (String, String, Bool, String?, BackendROUTINESSkillsEffectGuard) async throws -> NativeRPCValue)?
        public init(projects: @escaping @Sendable () async throws -> [PROJProject],
                    profiles: @escaping @Sendable () async throws -> [NativeRPCValue],
                    catalogue: @escaping @Sendable () async throws -> NativeRPCValue,
                    install: @escaping @Sendable (String, NativeRPCValue) async throws -> NativeRPCValue,
                    remove: @escaping @Sendable (String) async throws -> NativeRPCValue,
                    ownedSkill: @escaping @Sendable (String) async throws -> NativeRPCValue? = { _ in nil },
                    changeSkill: (@Sendable (String, String, Bool, String?) async throws -> NativeRPCValue)? = nil,
                    renameOwnedSkill: (@Sendable (String, String, BackendROUTINESSkillsEffectGuard) async throws -> Void)? = nil,
                    guardedInstall: (@Sendable (String, NativeRPCValue, BackendROUTINESSkillsEffectGuard) async throws -> NativeRPCValue)? = nil,
                    guardedRemove: (@Sendable (String, BackendROUTINESSkillsEffectGuard) async throws -> NativeRPCValue)? = nil,
                    guardedChangeSkill: (@Sendable (String, String, Bool, String?, BackendROUTINESSkillsEffectGuard) async throws -> NativeRPCValue)? = nil) {
            self.projects = projects; self.profiles = profiles
            self.catalogue = catalogue; self.install = install; self.remove = remove
            self.ownedSkill = ownedSkill; self.renameOwnedSkill = renameOwnedSkill
            self.changeSkill = changeSkill
            self.guardedInstall = guardedInstall; self.guardedRemove = guardedRemove; self.guardedChangeSkill = guardedChangeSkill
        }
    }
    public struct Root: Sendable {
        public let folder: URL, source: String, builtIn: Bool
        public init(folder: URL, source: String, builtIn: Bool = false) { self.folder = folder; self.source = source; self.builtIn = builtIn }
    }
    private let dependencies: Dependencies
    private let sharedRoots: [Root]
    private let home: URL
    private let versions: BackendSkillVersions?
    private let writable: Bool
    private var mutating = false
    private static func effective(_ scope: BackendROUTINESSkillsScope, projectRoot: String?) -> BackendROUTINESSkillsScope {
        projectRoot.map { .init(roots: scope.roots, projectRoot: $0) } ?? scope
    }
    private static func effectGuard(scope: BackendROUTINESSkillsScope, path: String, current: CurrentScope?) -> BackendROUTINESSkillsEffectGuard {
        .init {
            let latest: BackendROUTINESSkillsScope
            if let current { latest = try await current() } else { latest = scope }
            guard latest == scope else { throw NativeRPCError(code: "approval-stale", message: "The caller's folders changed before the skill could be changed.") }
            try latest.require(path); try Task.checkCancellation()
        }
    }
    public init(dependencies: Dependencies, sharedRoots: [Root], home: URL, writable: Bool, versions: BackendSkillVersions? = nil) {
        self.dependencies = dependencies; self.sharedRoots = sharedRoots; self.home = home; self.writable = writable; self.versions = versions
    }
    private func requireWritable() throws {
        guard writable else { throw NativeRPCError(code: "read-only", message: "Skills cannot be changed by this app copy.") }
    }
    private func begin() throws {
        try requireWritable()
        guard !mutating else { throw NativeRPCError(code: "busy", message: "Another skill change is saving. Try again when it finishes.") }
        mutating = true
    }
    private static func read(_ file: URL, maximum: Int = 262_144) throws -> String {
        let properties = try file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .isSymbolicLinkKey])
        guard properties.isRegularFile == true, properties.isSymbolicLink != true, (properties.fileSize ?? 0) <= maximum else {
            throw NativeRPCError(code: "skill-file-refused", message: "The skill file must be a regular text file under 256 KB.")
        }
        let handle = try FileHandle(forReadingFrom: file); defer { try? handle.close() }
        let data = try handle.read(upToCount: maximum + 1) ?? Data()
        guard data.count <= maximum else { throw NativeRPCError(code: "skill-file-refused", message: "The skill file is too large.") }
        return String(decoding: data, as: UTF8.self)
    }
    private static func inside(_ child: URL, _ parent: URL) -> Bool {
        let root = parent.resolvingSymlinksInPath().standardizedFileURL.path
        let path = child.resolvingSymlinksInPath().standardizedFileURL.path
        return path == root || path.hasPrefix(root + "/")
    }
    private static func projectSkillRoot(_ path: String) throws -> URL {
        let project = URL(fileURLWithPath: path).standardizedFileURL
        let claude = project.appendingPathComponent(".claude"), skills = claude.appendingPathComponent("skills")
        for directory in [claude, skills] {
            if FileManager.default.fileExists(atPath: directory.path), (try directory.resourceValues(forKeys: [.isSymbolicLinkKey])).isSymbolicLink == true {
                throw NativeRPCError(code: "skill-folder-refused", message: "The project's skills folder must stay inside its project.")
            }
        }
        guard inside(skills, project) else { throw NativeRPCError(code: "skill-folder-refused", message: "The project's skills folder points outside its project.") }
        return skills
    }
    private func scan(root: Root, project: PROJProject?, warnings: inout [String]) throws -> [ROUTINESSkill] {
        guard FileManager.default.fileExists(atPath: root.folder.path) else { return [] }
        let dirs = try FileManager.default.contentsOfDirectory(at: root.folder, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles])
        var result: [ROUTINESSkill] = []
        for folder in dirs.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }).prefix(1000) {
            guard Self.inside(folder, root.folder), (try? folder.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
            if FileManager.default.fileExists(atPath: folder.appendingPathComponent(BackendSkillsMirror.marker).path) { continue }
            let file = folder.appendingPathComponent("SKILL.md")
            guard FileManager.default.fileExists(atPath: file.path), Self.inside(file, folder) else { continue }
            guard let text = try? Self.read(file) else { warnings.append("Could not read " + folder.lastPathComponent + " in " + root.source + "."); continue }
            let name = SkillCommandNames.headerName(text) ?? folder.lastPathComponent
            let summary = (try? BackendAppAgentInventory.frontMatter(text, key: "description")) ?? ""
            let category = (try? BackendAppAgentInventory.frontMatter(text, key: "category")) ?? "Code"
            result.append(.init(id: folder.standardizedFileURL.path, name: name, summary: summary,
                                category: category, projectID: project?.id, source: root.source, folder: folder.path, builtIn: root.builtIn))
        }
        return result
    }
    public func installed(projectID: String? = nil, projectRoot: String? = nil, scope inputScope: BackendROUTINESSkillsScope = .owner) async throws -> [ROUTINESSkill] {
        try await discovery(projectID: projectID, projectRoot: projectRoot, scope: inputScope).rows
    }
    private func discovery(projectID: String? = nil, projectRoot: String? = nil, scope inputScope: BackendROUTINESSkillsScope = .owner) async throws -> (rows: [ROUTINESSkill], warnings: [String]) {
        let scope = Self.effective(inputScope, projectRoot: projectRoot)
        var warnings: [String] = []
        var rows: [ROUTINESSkill] = []
        for project in try await dependencies.projects() where projectID == nil || projectID == project.id {
            for folder in project.folders {
                if scope.allows(URL(fileURLWithPath: folder).appendingPathComponent(".claude/skills").path) {
                    do { rows += try scan(root: .init(folder: Self.projectSkillRoot(folder), source: project.name + " · .claude/skills"), project: project, warnings: &warnings) }
                    catch { warnings.append("Could not read skills in " + project.name + ".") }
                }
                for relative in [".agents/skills", ".codex/skills", ".gemini/skills"] {
                    let root = URL(fileURLWithPath: folder).appendingPathComponent(relative)
                    guard scope.allows(root.path), Self.inside(root, URL(fileURLWithPath: folder)) else { continue }
                    do { rows += try scan(root: .init(folder: root, source: project.name + " · " + relative), project: project, warnings: &warnings) }
                    catch { warnings.append("Could not read " + relative + " in " + project.name + ".") }
                }
            }
        }
        for root in sharedRoots {
            guard scope.allows(root.folder.path) else { continue }
            do {
                if root.folder.standardizedFileURL == home.appendingPathComponent(".claude/skills").standardizedFileURL { _ = try Self.projectSkillRoot(home.path) }
                rows += try scan(root: root, project: nil, warnings: &warnings)
            }
            catch { warnings.append("Could not read " + root.source + " skills.") }
        }
        var seen = Set<String>()
        var unique = rows.filter { seen.insert($0.id).inserted }
        for row in unique {
            let folder = URL(fileURLWithPath: row.folder)
            guard let mirror = BackendSkillsMirror.counterpart(of: folder),
                  FileManager.default.fileExists(atPath: mirror.appendingPathComponent(BackendSkillsMirror.marker).path),
                  BackendSkillsMirror.instructionsDiffer(folder) else { continue }
            if !writable || !scope.allows(mirror.path) || BackendSkillsMirror.mirror(folder) == nil {
                warnings.append("The Codex/Gemini copy of " + row.name + " needs refreshing; its instructions differ.")
            }
        }
        for index in unique.indices { unique[index].catalogueID = try await dependencies.ownedSkill(unique[index].folder)?["id"].string }
        return (unique.sorted { ($0.projectID ?? "", $0.name, $0.id) < ($1.projectID ?? "", $1.name, $1.id) }, warnings)
    }
    public func list(installed onlyInstalled: Bool? = nil, projectID: String? = nil, projectRoot: String? = nil, scope: BackendROUTINESSkillsScope = .owner) async throws -> NativeRPCValue {
        let installed: [ROUTINESSkill]
        let warnings: [String]
        if onlyInstalled == false { installed = []; warnings = [] }
        else { let found = try await discovery(projectID: projectID, projectRoot: projectRoot, scope: scope); installed = found.rows; warnings = found.warnings }
        var catalogue = NativeRPCValue.object([])
        if onlyInstalled != true {
            catalogue = try await dependencies.catalogue()
            if let message = catalogue["problem"].string, !message.isEmpty { throw NativeRPCError(code: "catalogue-unavailable", message: message) }
            catalogue = catalogue.setting("items", .array((catalogue["items"].elements ?? []).filter { $0["kind"].string == "skill" }))
        }
        return .object([.init("skills", .array(installed.map(\.wire))), .init("catalogue", catalogue), .init("warnings", .array(warnings.map(NativeRPCValue.string)))])
    }
    /// A skill by its folder (exact) or by its name. Several copies can share a name (a "recover" skill in two projects):
    /// for agents, the copy in the agents' own project wins, else the copy for every project; anything still unclear
    /// is refused with the copies listed, never answered with the wrong one or with "no longer installed".
    private func skill(_ id: String, scope: BackendROUTINESSkillsScope = .owner, forAgents agentIDs: [String] = [], rows scannedRows: [ROUTINESSkill]? = nil, profiles savedProfiles: [NativeRPCValue]? = nil, projects savedProjects: [PROJProject]? = nil) async throws -> ROUTINESSkill {
        if id.hasPrefix("/") { try scope.require(id) }
        let rows: [ROUTINESSkill]
        if let scannedRows { rows = scannedRows } else { rows = try await installed(scope: scope) }
        if let exact = rows.first(where: { $0.id == id }) { return exact }
        // New project folders have not reached the registry yet. The same finite folder grant applies.
        if id.hasPrefix("/"), id.contains("/.claude/skills/") {
            let folder = URL(fileURLWithPath: id).standardizedFileURL
            let root = folder.deletingLastPathComponent()
            guard root.lastPathComponent == "skills" else { throw NativeRPCError.invalidArguments("Name a skill folder.") }
            _ = try Self.projectSkillRoot(root.deletingLastPathComponent().deletingLastPathComponent().path)
            var warnings: [String] = []
            if let row = try scan(root: .init(folder: root, source: "This project"), project: nil, warnings: &warnings).first(where: { $0.id == folder.path }) { return row }
        }
        let named = rows.filter { $0.name == id }
        guard !named.isEmpty else { throw NativeRPCError(code: "missing-skill", message: "That skill is no longer installed.") }
        // The person's own copy wins over a built-in one with the same name (Terminal Deck's or Codex's).
        func pick(_ copies: [ROUTINESSkill]) -> ROUTINESSkill? {
            if copies.count == 1 { return copies[0] }
            let own = copies.filter { !$0.builtIn }
            return own.count == 1 ? own[0] : nil
        }
        if let row = pick(named) { return row }
        if !agentIDs.isEmpty {
            let profiles: [NativeRPCValue], projects: [PROJProject]
            if let savedProfiles { profiles = savedProfiles } else { profiles = try await dependencies.profiles() }
            if let savedProjects { projects = savedProjects } else { projects = try await dependencies.projects() }
            let homes = Set(agentIDs.compactMap { agent in profiles.first { $0["id"].string == agent } }.map {
                PROJProjects.resolve(projectID: $0["projectId"].string, folder: $0["defaultProject"].string, projects: projects)
            })
            if homes.count == 1, let home = homes.first {
                let own = named.filter { $0.projectID == home }
                if let row = pick(own) { return row }
                if own.isEmpty, let row = pick(named.filter { $0.projectID == nil }) { return row }
            }
        }
        let places = named.map { $0.source + ": " + $0.id }
        throw NativeRPCError(code: "ambiguous-skill", message: "More than one skill is called \(id). Name it by its folder instead: " + places.joined(separator: "; ") + ".")
    }
    /// Adds the exact selected folders to the internal approval plan. A moved
    /// project/agent/skill changes this plan, even when its id stays the same.
    public func scoped(_ args: NativeRPCValue, channel: String, projectRoot: String? = nil,
                       scope inputScope: BackendROUTINESSkillsScope = .owner, readScope: BackendROUTINESSkillsScope? = nil) async throws -> NativeRPCValue {
        let scope = Self.effective(inputScope, projectRoot: projectRoot)
        let selectedReads = (channel == "skills:assign" || channel == "skills:unassign") ? (readScope ?? scope) : scope
        guard scope.roots != [] else { throw NativeRPCError(code: "not-granted", message: "This caller has no current folder access.") }
        var plan = args
        if channel == "skills:install" || channel == "skills:create" {
            let target = try await destination(projectID: args["project"].string, scope: scope)
            plan = plan.setting("targetFolder", .string(BackendROUTINESSkillsScope.canonical(target.path)))
        }
        if let id = args["skill"].string {
            let agents = (channel == "skills:assign" || channel == "skills:unassign") ? (args["agentIds"].elements ?? []).compactMap(\.string) : []
            let row = try await skill(id, scope: selectedReads, forAgents: agents)
            try selectedReads.require(row.folder)
            plan = plan.setting("skillFolder", .string(BackendROUTINESSkillsScope.canonical(row.folder)))
            if channel.hasPrefix("skills:version"), let versions {
                let source = URL(fileURLWithPath: row.folder)
                let state = try await versions.info(source: source, selected: args["version"].string)
                plan = plan.setting("versionCurrentDigest", state["currentDigest"])
                if let digest = state["selected"]["digest"].string { plan = plan.setting("versionDigest", .string(digest)) }
                if channel == "skills:version_adopt" {
                    try scope.require(source.deletingLastPathComponent().path)
                    if let mirror = BackendSkillsMirror.counterpart(of: source) {
                        try scope.require(mirror.path); try scope.require(mirror.deletingLastPathComponent().path)
                        plan = plan.setting("versionMirror", .string(BackendROUTINESSkillsScope.canonical(mirror.path)))
                    }
                }
            }
            if channel == "skills:rename" {
                let name = try renameName(row, requested: args["name"].string)
                let target = URL(fileURLWithPath: row.folder).deletingLastPathComponent().appendingPathComponent(name)
                try scope.require(target.path)
                if let mirror = BackendSkillsMirror.counterpart(of: target) { try scope.require(mirror.path) }
                if let mirror = BackendSkillsMirror.counterpart(of: URL(fileURLWithPath: row.folder)) { try scope.require(mirror.path) }
                let profiles = try await renameProfiles(row, scope: scope)
                let body = try Self.read(URL(fileURLWithPath: row.folder).appendingPathComponent("SKILL.md"))
                plan = plan.setting("name", .string(name)).setting("fingerprint", .string(SHA256.hash(data: Data(body.utf8)).map { String(format: "%02x", $0) }.joined()))
                    .setting("renameAgents", .array(profiles.map { .object([.init("id", $0["id"]), .init("folder", $0["defaultProject"])]) }))
            }
        }
        if channel == "skills:assign" || channel == "skills:unassign" {
            let profiles = try await dependencies.profiles()
            var folders: [NativeRPCValue] = []
            for id in (args["agentIds"].elements ?? []).compactMap(\.string) {
                guard let profile = profiles.first(where: { $0["id"].string == id }) else { throw NativeRPCError(code: "missing-agent", message: "That saved agent no longer exists.") }
                let folder = profile["defaultProject"].string
                if scope.roots != nil || scope.projectRoot != nil {
                    guard let folder else { throw NativeRPCError(code: "not-granted", message: "This independent agent has no folder in the caller's grant.") }
                    try scope.require(folder)
                }
                folders.append(.object([.init("id", .string(id)), .init("folder", folder.map { .string(BackendROUTINESSkillsScope.canonical($0)) } ?? .null)]))
            }
            plan = plan.setting("agentFolders", .array(folders))
        }
        return plan
    }
    public func preview(_ id: String, projectRoot: String? = nil, scope inputScope: BackendROUTINESSkillsScope = .owner) async throws -> NativeRPCValue {
        let scope = Self.effective(inputScope, projectRoot: projectRoot)
        let row = try await skill(id, scope: scope), folder = URL(fileURLWithPath: row.folder)
        try scope.require(folder.path)
        let text = try Self.read(folder.appendingPathComponent("SKILL.md"))
        let fileList = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles])
        var files: [NativeRPCValue] = []
        while let file = fileList?.nextObject() as? URL, files.count < 300 {
            guard Self.inside(file, folder), (try? file.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true else { fileList?.skipDescendants(); continue }
            if (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
                files.append(.string(String(file.path.dropFirst(folder.path.count + 1))))
            }
        }
        let profiles = try await dependencies.profiles().filter { profile in
            guard (profile["skills"].elements ?? []).contains(.string(row.name)) else { return false }
            if scope.roots != nil || scope.projectRoot != nil { guard let folder = profile["defaultProject"].string, scope.allows(folder) else { return false } }
            return true
        }.map { profile in
            var publicFields = NativeRPCValue.object([])
            for key in ["id", "name", "icon", "projectId"] { if !profile[key].isNullish { publicFields = publicFields.setting(key, profile[key]) } }
            return publicFields
        }
        var result = row.wire.setting("markdown", .string(text)).setting("files", .array(files)).setting("agents", .array(profiles))
        if let versions {
            do { result = result.setting("versionState", try await versions.info(source: folder)) }
            catch { result = result.setting("versionProblem", .string(error.localizedDescription)) }
        }
        return result
    }
    public func assign(_ id: String, agentIDs: [String], assigned: Bool, projectRoot: String? = nil,
                       scope inputScope: BackendROUTINESSkillsScope = .owner, readScope: BackendROUTINESSkillsScope? = nil,
                       currentScope: CurrentScope? = nil) async throws -> NativeRPCValue {
        let scope = Self.effective(inputScope, projectRoot: projectRoot)
        let selectedReads = readScope ?? scope
        try begin(); defer { mutating = false }
        guard dependencies.changeSkill != nil || dependencies.guardedChangeSkill != nil else { throw NativeRPCError(code: "unavailable", message: "The task owner cannot safely update a skill in this build.") }
        if currentScope != nil, dependencies.guardedChangeSkill == nil { throw NativeRPCError(code: "unavailable", message: "The task owner cannot recheck this caller's current grant.") }
        let copies = try await installed(scope: selectedReads), profiles = try await dependencies.profiles(), projects = try await dependencies.projects()
        let row = try await skill(id, scope: selectedReads, forAgents: agentIDs, rows: copies, profiles: profiles, projects: projects)
        guard !agentIDs.isEmpty, agentIDs.count <= 300, Set(agentIDs).count == agentIDs.count,
              agentIDs.allSatisfy({ id in profiles.contains { $0["id"].string == id } }) else {
            throw NativeRPCError.invalidArguments("Choose saved agents from the Agents page.")
        }
        var saved: [NativeRPCValue] = []
        for id in agentIDs {
            guard let current = profiles.first(where: { $0["id"].string == id }) else { throw NativeRPCError(code: "missing-agent", message: "That agent was removed.") }
            if assigned {
                let targets = current["provider"].string.map { [$0] } ?? SkillCommandNames.ais
                try SkillCommandNames.require(row.name, targets: targets)
                try SkillCommandNames.require(URL(fileURLWithPath: row.folder).lastPathComponent, targets: targets)
            }
            let agentProject = PROJProjects.resolve(projectID: current["projectId"].string, folder: current["defaultProject"].string, projects: projects)
            let matching = copies.filter { $0.name == row.name }
            let preferred = matching.first { $0.projectID == agentProject } ?? matching.first { $0.projectID == nil }
            if assigned, let preferred, preferred.id != row.id {
                throw NativeRPCError(code: "skill-copy-conflict", message: "This agent uses the copy of this named skill in its own project. Give it that copy instead.")
            }
            let folder = current["defaultProject"].string
            if scope.roots != nil || scope.projectRoot != nil {
                guard let folder else { throw NativeRPCError(code: "not-granted", message: "This independent agent has no folder in the caller's grant.") }
                try scope.require(folder)
            }
            try selectedReads.require(row.folder)
            let boundary = try folder.flatMap { try scope.boundary(for: $0) }
            let guardAtOwner = Self.effectGuard(scope: scope, path: folder ?? row.folder, current: currentScope)
            try await guardAtOwner.verify()
            let changed: NativeRPCValue
            if currentScope != nil, let guarded = dependencies.guardedChangeSkill { changed = try await guarded(id, row.name, assigned, boundary, guardAtOwner) }
            else if let change = dependencies.changeSkill { changed = try await change(id, row.name, assigned, boundary) }
            else { throw NativeRPCError(code: "unavailable", message: "The agent's skill writer is unavailable.") }
            var summary = NativeRPCValue.object([])
            for key in ["id", "name", "icon", "projectId"] { if !changed[key].isNullish { summary = summary.setting(key, changed[key]) } }
            saved.append(summary.setting("skill", .string(row.name)).setting("assigned", .bool(assigned)))
        }
        return .object([.init("ok", .bool(true)), .init("agents", .array(saved))])
    }
    private func destination(projectID: String?, projectRoot: String? = nil, scope inputScope: BackendROUTINESSkillsScope = .owner) async throws -> URL {
        let scope = Self.effective(inputScope, projectRoot: projectRoot)
        guard let projectID else {
            let result = try Self.projectSkillRoot(home.path)
            try scope.require(result.path); return result
        }
        guard let project = try await dependencies.projects().first(where: { $0.id == projectID }), let path = project.folders.first else {
            throw NativeRPCError.invalidArguments("Choose a project with a folder, or Every project.")
        }
        let result = try Self.projectSkillRoot(path)
        try scope.require(result.path)
        return result
    }
    public func install(_ id: String, projectID: String?, projectRoot: String? = nil,
                        scope inputScope: BackendROUTINESSkillsScope = .owner, currentScope: CurrentScope? = nil,
                        expectedFolder: String? = nil) async throws -> NativeRPCValue {
        let scope = Self.effective(inputScope, projectRoot: projectRoot)
        try begin(); defer { mutating = false }
        let catalogue = try await dependencies.catalogue()
        guard let row = catalogue["items"].elements?.first(where: { $0["id"].string == id && $0["kind"].string == "skill" }) else {
            throw NativeRPCError(code: "missing-skill", message: "The Skills store no longer lists that skill.")
        }
        guard (row["agents"].elements ?? []).contains(.string("claude")) else {
            throw NativeRPCError(code: "incompatible-skill", message: "This skill does not support the project's Claude skills folder.")
        }
        let target = try await destination(projectID: projectID, scope: scope)
        if let expectedFolder, BackendROUTINESSkillsScope.canonical(target.path) != expectedFolder { throw NativeRPCError(code: "approval-stale", message: "The selected project's folder changed. Ask again.") }
        let base = target.deletingLastPathComponent().deletingLastPathComponent()
        let guardAtOwner = Self.effectGuard(scope: scope, path: target.path, current: currentScope)
        try await guardAtOwner.verify()
        let boundary = try scope.boundary(for: target.path)
        let choice = NativeRPCValue.object([.init("agents", .array([.string("claude")])), .init("folder", .string(base.path)), .init("projectRoot", boundary.map(NativeRPCValue.string) ?? .null)])
        let before = BackendSkillsMirror.folders(in: target)
        let result: NativeRPCValue
        if currentScope != nil, let guarded = dependencies.guardedInstall { result = try await guarded(id, choice, guardAtOwner) }
        else {
            guard currentScope == nil else { throw NativeRPCError(code: "unavailable", message: "The installer cannot recheck this caller's current grant.") }
            result = try await dependencies.install(id, choice)
        }
        guard result["ok"].bool == true else { throw NativeRPCError(code: "install-failed", message: result["message"].string ?? "The skill was not installed.") }
        // TRUTH-B: Codex and Gemini read `.agents/skills`, not `.claude/skills`: they get a marked copy.
        for added in BackendSkillsMirror.folders(in: target).subtracting(before).sorted() { BackendSkillsMirror.mirror(target.appendingPathComponent(added)) }
        return result
    }
    public func create(name: String, summary: String, category: String, markdown: String, projectID: String?, projectRoot: String? = nil,
                       scope inputScope: BackendROUTINESSkillsScope = .owner, currentScope: CurrentScope? = nil,
                       expectedFolder: String? = nil) async throws -> NativeRPCValue {
        let scope = Self.effective(inputScope, projectRoot: projectRoot)
        try begin(); defer { mutating = false }
        guard ROUTINESSkillsRules.safeName(name), !summary.isEmpty, summary.utf8.count <= 2000,
              !summary.contains("\n"), !summary.contains("\r"), !category.contains("\n"), !category.contains("\r"),
              category.utf8.count <= 80, !markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, markdown.utf8.count <= 200_000 else {
            throw NativeRPCError.invalidArguments("Use a short skill name, a one-line description and instructions under 200 KB.")
        }
        try SkillCommandNames.require(name)
        let root = try await destination(projectID: projectID, scope: scope), target = root.appendingPathComponent(name)
        if let expectedFolder, BackendROUTINESSkillsScope.canonical(root.path) != expectedFolder { throw NativeRPCError(code: "approval-stale", message: "The selected project's folder changed. Ask again.") }
        guard !FileManager.default.fileExists(atPath: target.path), Self.inside(target, root) else { throw NativeRPCError(code: "skill-exists", message: "A skill with that folder name already exists.") }
        try await Self.effectGuard(scope: scope, path: target.path, current: currentScope).verify()
        _ = try Self.projectSkillRoot(root.deletingLastPathComponent().deletingLastPathComponent().path)
        try scope.require(target.path)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
        do {
            // JSON quoted values are valid YAML strings and cannot escape the header.
            func quoted(_ value: String) throws -> String { String(decoding: try JSONEncoder().encode(value), as: UTF8.self) }
            let body = "---\nname: \(try quoted(name))\ndescription: \(try quoted(summary))\ncategory: \(try quoted(category))\n---\n\n" + markdown + "\n"
            try Data(body.utf8).write(to: target.appendingPathComponent("SKILL.md"), options: .atomic)
            BackendSkillsMirror.mirror(target)   // TRUTH-B: Codex and Gemini get it too
        } catch { try? FileManager.default.removeItem(at: target); throw error }
        return .object([.init("ok", .bool(true)), .init("folder", .string(target.path))])
    }
    private func renameName(_ row: ROUTINESSkill, requested: String?) throws -> String {
        guard !row.builtIn else { throw NativeRPCError(code: "built-in-skill", message: "This skill is built in and cannot be renamed here.") }
        let base = requested ?? SkillCommandNames.suggestion(row.name)
        try SkillCommandNames.require(base)
        guard ROUTINESSkillsRules.safeName(base) else { throw NativeRPCError.invalidArguments("Use a short skill name with letters, numbers, dots, dashes or underscores.") }
        let root = URL(fileURLWithPath: row.folder).deletingLastPathComponent()
        if requested != nil { return base }
        var name = base, suffix = 2
        while FileManager.default.fileExists(atPath: root.appendingPathComponent(name).path) {
            name = String(base.prefix(70)) + "-" + String(suffix); suffix += 1
        }
        return name
    }
    private func renameProfiles(_ row: ROUTINESSkill, scope: BackendROUTINESSkillsScope) async throws -> [NativeRPCValue] {
        var result: [NativeRPCValue] = []
        let rows = try await installed(scope: .owner), profiles = try await dependencies.profiles(), projects = try await dependencies.projects()
        for profile in profiles where (profile["skills"].elements ?? []).contains(.string(row.name)) {
            guard let id = profile["id"].string else { continue }
            // A name shared by two projects must only change the selected copy's users.
            let selected = try await skill(row.name, scope: .owner, forAgents: [id], rows: rows, profiles: profiles, projects: projects)
            guard selected.folder == row.folder else { continue }
            if let folder = profile["defaultProject"].string { try scope.require(folder) }
            else if scope.roots != nil { throw NativeRPCError(code: "not-granted", message: "An agent using this skill has no folder in your grant.") }
            result.append(profile)
        }
        return result
    }
    public func rename(_ id: String, name requested: String? = nil, scope: BackendROUTINESSkillsScope = .owner,
                       currentScope: CurrentScope? = nil, fingerprint: String? = nil) async throws -> NativeRPCValue {
        try begin(); defer { mutating = false }
        let row = try await skill(id, scope: scope), name = try renameName(row, requested: requested)
        let folder = URL(fileURLWithPath: row.folder), target = folder.deletingLastPathComponent().appendingPathComponent(name)
        try scope.require(target.path)
        if let mirror = BackendSkillsMirror.counterpart(of: target) { try scope.require(mirror.path) }
        if let mirror = BackendSkillsMirror.counterpart(of: folder) { try scope.require(mirror.path) }
        let body = try Self.read(folder.appendingPathComponent("SKILL.md"))
        if let fingerprint, fingerprint != SHA256.hash(data: Data(body.utf8)).map({ String(format: "%02x", $0) }).joined() {
            throw NativeRPCError(code: "approval-stale", message: "The skill changed before it could be renamed. Try again.")
        }
        let profiles = try await renameProfiles(row, scope: scope)
        let effect = Self.effectGuard(scope: scope, path: folder.path, current: currentScope)
        if !profiles.isEmpty, dependencies.changeSkill == nil && dependencies.guardedChangeSkill == nil {
            throw NativeRPCError(code: "unavailable", message: "The agents using this skill cannot be updated safely in this build.")
        }
        if currentScope != nil, !profiles.isEmpty, dependencies.guardedChangeSkill == nil {
            throw NativeRPCError(code: "unavailable", message: "The agent writer cannot recheck your folder access.")
        }
        let owned = try await dependencies.ownedSkill(row.folder) != nil
        if owned && dependencies.renameOwnedSkill == nil { throw NativeRPCError(code: "unavailable", message: "The Store cannot safely rename this installation in this build.") }
        // Do not replace a person's own shared skill. Marked copies follow the rename.
        if let mirror = BackendSkillsMirror.counterpart(of: target), FileManager.default.fileExists(atPath: mirror.path) {
            throw NativeRPCError(code: "skill-exists", message: "A shared skill already uses that name. Choose another name.")
        }
        func change(_ profile: NativeRPCValue, _ skill: String, _ assigned: Bool) async throws {
            let id = try profile["id"].requireString("id", nonempty: true)
            let boundary = try profile["defaultProject"].string.map { try scope.boundary(for: $0) } ?? scope.projectRoot
            if let guarded = dependencies.guardedChangeSkill { _ = try await guarded(id, skill, assigned, boundary, effect) }
            else if let change = dependencies.changeSkill { try await effect.verify(); _ = try await change(id, skill, assigned, boundary) }
        }
        var changed: [NativeRPCValue] = []
        do {
            for profile in profiles {
                changed.append(profile)
                try await change(profile, row.name, false)
                try await change(profile, name, true)
            }
            try await effect.verify()
            guard try Self.read(folder.appendingPathComponent("SKILL.md")) == body else {
                throw NativeRPCError(code: "approval-stale", message: "The skill changed while its agents were being updated. Try again.")
            }
            if owned { try await dependencies.renameOwnedSkill!(folder.path, name, effect) }
            else { _ = try BackendSkillRenameFiles.move(folder: folder, name: name) }
        } catch {
            var restored = true
            for profile in changed.reversed() {
                do {
                    if !(profile["skills"].elements ?? []).contains(.string(name)) { try await change(profile, name, false) }
                    try await change(profile, row.name, true)
                } catch { restored = false }
            }
            if !restored { throw NativeRPCError(code: "rename-incomplete", message: "The skill was not renamed, but some agent choices could not be restored. Check the agents using it.") }
            throw error
        }
        BackendSkillsMirror.unmirror(folder)
        BackendSkillsMirror.mirror(target)
        if let versions {
            do { try await versions.retarget(from: folder, to: target) }
            catch { throw NativeRPCError(code: "rename-history-incomplete", message: "The skill was renamed to " + target.path + ", but its saved history could not be retargeted: " + error.localizedDescription) }
        }
        return .object([.init("ok", .bool(true)), .init("folder", .string(target.path)), .init("name", .string(name)),
                        .init("message", .string("Renamed /\(row.name) to /\(name)."))])
    }
    public func remove(_ id: String, projectRoot: String? = nil,
                       scope inputScope: BackendROUTINESSkillsScope = .owner, currentScope: CurrentScope? = nil) async throws -> NativeRPCValue {
        let scope = Self.effective(inputScope, projectRoot: projectRoot)
        try begin(); defer { mutating = false }
        let row = try await skill(id, scope: scope)
        guard !row.builtIn else {
            let owner = row.source == BackendBuiltInSkills.codexSource ? "Codex" : "Terminal Deck"
            throw NativeRPCError(code: "built-in-skill", message: "This skill is built into \(owner) and cannot be removed here.")
        }
        // Installer-owned trees go through its ledger and checksum protection.
        if let record = try await dependencies.ownedSkill(row.folder) {
            try scope.require(row.folder)
            let ownedRoot = record["root"].string ?? ""
            let payloadDirectories = (record["writes"].elements ?? []).filter { $0["kind"].string == "dir" && $0["path"].string != ownedRoot }.compactMap { $0["path"].string }
            guard payloadDirectories == [row.folder], !(record["writes"].elements ?? []).contains(where: { $0["kind"].string == "block" || $0["kind"].string == "server" }) else {
                throw NativeRPCError(code: "remove-scope-refused", message: "This older installation also owns files outside this skill folder. Remove it from its original Store controls.")
            }
            guard (record["writes"].elements ?? []).allSatisfy({ write in
                guard let path = write["path"].string else { return false }
                return Self.inside(URL(fileURLWithPath: path), URL(fileURLWithPath: row.folder)) || Self.inside(URL(fileURLWithPath: path), URL(fileURLWithPath: ownedRoot))
            }) else { throw NativeRPCError(code: "remove-scope-refused", message: "The installation owns files outside the selected skill and its retained download.") }
            let key: String
            if let instance = record["installationID"].string { key = instance } else { key = try record["id"].requireString("id", nonempty: true) }
            let guardAtOwner = Self.effectGuard(scope: scope, path: row.folder, current: currentScope)
            try await guardAtOwner.verify()
            let result: NativeRPCValue
            if currentScope != nil, let guarded = dependencies.guardedRemove { result = try await guarded(key, guardAtOwner) }
            else {
                guard currentScope == nil else { throw NativeRPCError(code: "unavailable", message: "The installer cannot recheck this caller's current grant.") }
                result = try await dependencies.remove(key)
            }
            guard result["ok"].bool == true else { throw NativeRPCError(code: "remove-failed", message: result["message"].string ?? "The skill was not removed.") }
            BackendSkillsMirror.unmirror(URL(fileURLWithPath: row.folder))
            return result
        }
        let folder = URL(fileURLWithPath: row.folder)
        try await Self.effectGuard(scope: scope, path: folder.path, current: currentScope).verify()
        guard (try? folder.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true else {
            throw NativeRPCError(code: "skill-file-refused", message: "A linked skill folder cannot be removed here. Show it in Finder instead.")
        }
        BackendSkillsMirror.unmirror(folder)   // TRUTH-B: Codex's and Gemini's copy goes with it
        try FileManager.default.removeItem(at: folder)
        return .object([.init("ok", .bool(true))])
    }
    public func call(_ channel: String, _ input: NativeRPCValue, projectRoot: String? = nil,
                     scope inputScope: BackendROUTINESSkillsScope = .owner, readScope: BackendROUTINESSkillsScope? = nil,
                     currentScope: CurrentScope? = nil) async throws -> NativeRPCValue {
        let scope = Self.effective(inputScope, projectRoot: projectRoot)
        let args = try await scoped(input, channel: channel, scope: scope, readScope: readScope)
        switch channel {
        case "skills:list": return try await list(installed: args["installed"].bool, projectID: args["projectID"].string, scope: scope)
        case "skills:preview": return try await preview(try args["skill"].requireString("skill", nonempty: true), scope: scope)
        case "skills:versions", "skills:version_save", "skills:version_check", "skills:version_adopt":
            guard let versions else { throw NativeRPCError(code: "unavailable", message: "The private skill version store is unavailable in this copy.") }
            let row = try await skill(try args["skill"].requireString("skill", nonempty: true), scope: scope)
            let source = URL(fileURLWithPath: row.folder)
            if channel == "skills:versions" { return try await versions.info(source: source, selected: args["version"].string) }
            try begin(); defer { mutating = false }
            let dependencies = self.dependencies
            var touched = [source.path]
            if channel == "skills:version_adopt" {
                touched.append(source.deletingLastPathComponent().path)
                if let mirror = BackendSkillsMirror.counterpart(of: source) { touched += [mirror.path, mirror.deletingLastPathComponent().path] }
            }
            let paths = touched.map { ($0, BackendROUTINESSkillsScope.canonical($0)) }
            let effect = BackendROUTINESSkillsEffectGuard {
                if channel == "skills:version_adopt" {
                    guard !row.builtIn, row.catalogueID == nil, try await dependencies.ownedSkill(source.path) == nil else {
                        throw NativeRPCError(code: "protected-skill-version", message: "Built-in, shipped and Store-owned skills can be saved and checked, but adoption is protected here. Use their owner controls; the installation ledger is unchanged.")
                    }
                }
                // Ownership may suspend. Refresh grants AFTER it, then validate
                // every actual source, staging parent and mirror in one boundary.
                let latest = try await currentScope?() ?? scope
                guard latest == scope else { throw NativeRPCError(code: "approval-stale", message: "Folder access changed before the version could be saved. Refresh and ask again.") }
                for (path, canonical) in paths {
                    guard BackendROUTINESSkillsScope.canonical(path) == canonical else { throw NativeRPCError(code: "approval-stale", message: "A selected skill folder moved before the change.") }
                    try latest.require(path)
                }
                try Task.checkCancellation()
            }
            switch channel {
            case "skills:version_save": return try await versions.snapshot(source: source, label: args["label"].requireString("label", nonempty: true), expected: args["expectedDigest"].requireString("expectedDigest", nonempty: true), guard: effect)
            case "skills:version_check": return try await versions.check(source: source, version: args["version"].requireString("version", nonempty: true), guard: effect)
            default: return try await versions.adopt(source: source, version: args["version"].requireString("version", nonempty: true), expected: args["expectedDigest"].requireString("expectedDigest", nonempty: true), guard: effect)
            }
        case "skills:assign", "skills:unassign":
            guard let ids = args["agentIds"].elements, ids.allSatisfy({ $0.string != nil }) else { throw NativeRPCError.invalidArguments("agentIds must be an array of saved agent ids.") }
            return try await assign(try args["skill"].requireString("skill", nonempty: true), agentIDs: ids.compactMap(\.string), assigned: channel == "skills:assign", scope: scope, readScope: readScope, currentScope: currentScope)
        case "skills:install": return try await install(try args["id"].requireString("id", nonempty: true), projectID: args["project"].string, scope: scope, currentScope: currentScope, expectedFolder: input["targetFolder"].string)
        case "skills:create": return try await create(name: try args["name"].requireString("name", nonempty: true), summary: try args["summary"].requireString("summary", nonempty: true), category: args["category"].string ?? "Code", markdown: try args["markdown"].requireString("markdown", nonempty: true), projectID: args["project"].string, scope: scope, currentScope: currentScope, expectedFolder: input["targetFolder"].string)
        case "skills:rename": return try await rename(try args["skill"].requireString("skill", nonempty: true), name: args["name"].string, scope: scope, currentScope: currentScope, fingerprint: input["fingerprint"].string ?? args["fingerprint"].string)
        case "skills:remove": return try await remove(try args["skill"].requireString("skill", nonempty: true), scope: scope, currentScope: currentScope)
        default: throw NativeRPCError(code: "unknown-channel", message: "Unknown Skills operation: " + channel)
        }
    }
    public static let channels = ["skills:versions", "skills:version_save", "skills:version_check", "skills:version_adopt", "skills:list", "skills:preview", "skills:assign", "skills:unassign", "skills:install", "skills:create", "skills:rename", "skills:remove"]
    public static func register(registry: NativeChannelRegistry, ownerID: String, service: BackendROUTINESSkills,
                                policy: @escaping NativeChannelRegistry.Policy) async throws {
        for channel in channels {
            try await registry.register(channel, ownerID: ownerID, policy: policy) { context, args in
                let result = try await service.call(channel, context.argument(0, in: args))
                // Every listener (the Skills page listens as the app's window, not as this owner): no ownerID.
                if channel != "skills:list" && channel != "skills:preview" && channel != "skills:versions" { try await registry.publish("skills:changed", arguments: []) }
                return result
            }
        }
    }
}
