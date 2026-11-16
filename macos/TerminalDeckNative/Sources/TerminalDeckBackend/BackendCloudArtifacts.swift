import Foundation
import TerminalDeckNativeCore

/// Lane L3, slice 2 (owner, 14 Nov: "everything arrives on any machine", artifacts included): an artifact made on one
/// Mac (a page, a report, a picture: whatever the Artifacts page lists) is on his other Macs' Artifacts pages too, with
/// its name, project, the agent that made it and the date, and opens there.
///
/// How: the Cloud folder's owner (`BackendCloudFolder`, the same file engine in lean mode, the same gate,
/// limits, adoption and sweep guard) runs a second time with `CloudFileKind.artifacts` over an app-private STORE:
///
///     <cloud>/<subject>/artifacts-files/<project id>/<path inside the project>          the artifact's bytes
///     <cloud>/<subject>/artifacts-files/<project id>/<path inside the project>.tdabout  its description (name, project,
///                                                                                       made by, made at, type, Mac)
///
/// This actor feeds the store from the Artifacts page's own list (`feed`): a copy of each artifact inside a project
/// folder, never a file outside the catalogue, never one over 25 MB, never one that is or holds a secret by the app's
/// own rules. His project folders are only READ; nothing that arrives is ever written into them. What arrives lands in
/// the store only, where the Artifacts page lists it and opens it.
///
/// Project-file disappearance and catalogue aging never remove a stored artifact. A by-hand store disappearance is
/// a local mark; an explicit page/tool removal or witnessed AI command travels through the owner's intent and Bin.
/// Project originals are never removed. The person's Bin can restore the artifact and its description together.
public enum CloudArtifactsFormat {
    public static let inventoryRow = "I23"
    public static var domain: String { CloudBrainFilesFormat.domain(inventoryRow) }
    /// "This Mac understands artifacts records" (`DeckMemoryStore.cloudFeatureAnnounce`).
    public static let feature = "artifacts"
    public static let format = 1
    /// Owner's numbers (14 Nov): 25 MB per artifact; 1 GB for all artifacts together. The daily 200 MB, the 3 GB room
    /// floor, 6 versions a day and the 2 GB disk floor are the Cloud folder's own, shared.
    public static let maximumFileBytes: Int64 = 25_000_000
    public static let maximumStoreBytes: Int64 = 1_000_000_000
    /// The description file beside each artifact in the store.
    public static let aboutSuffix = ".tdabout"
    public static func isAbout(_ path: String) -> Bool { path.hasSuffix(aboutSuffix) }
    /// The store path of one artifact: `<project id>/<path inside the project>`. nil for anything that is not a plain
    /// path inside a project (an outside file, a walk with `..`, a project id that is not one plain name).
    public static func storePath(projectId: String, relPath: String) -> String? {
        guard !ArtifactRules.isOutside(relPath), !isAbout(relPath), !projectId.isEmpty, !projectId.contains("/"),
              CloudBootFilesRules.parts(projectId)?.count == 1, CloudBootFilesRules.cleanRelative(relPath) else { return nil }
        let path = projectId + "/" + relPath
        guard CloudBootFilesRules.cleanRelative(path), let parts = CloudBootFilesRules.parts(path), parts.count >= 2 else { return nil }
        return path
    }
    /// Files whose words are read before they travel (pages, documents, data). Pictures, recordings and PDFs are not
    /// text and are not read.
    static let textEndings: Set<String> = ["html", "htm", "md", "markdown", "txt", "json", "csv", "tsv", "xml", "svg", "yaml", "yml",
                                            "js", "mjs", "css", "log", "rtf", "tex", "ipynb", "sql", "sh", "toml", "ini"]
    /// True when the artifact holds a secret by the app's own rules (`BackendSharedRedact.containsKnownSecret`).
    public static func holdsSecret(_ relPath: String, _ bytes: Data) -> Bool {
        guard textEndings.contains(ArtifactRules.extensionOf(relPath)) else { return false }
        return BackendSharedRedact.containsKnownSecret(String(decoding: bytes, as: UTF8.self))
    }

    // The page's lines (plain words; names only, never a path or a code).
    public static let fullLine = "Your artifacts in the Cloud hold more than 1 GB. New and changed artifacts stay on this Mac until there is room."
    /// The one shared line (the 200 MB is the Cloud folder's and artifacts' together).
    public static var dayFullLine: String { CloudFolderFormat.dayFullLine }
    public static func busyLine(_ count: Int) -> String {
        count == 1 ? "1 artifact changed more than 6 times today. It is sent once it has been still for an hour."
                   : "\(count) artifacts changed more than 6 times today. Each is sent once it has been still for an hour."
    }
    public static let roomLowLine = "Your Cloud account has less than 3 GB of room left, so artifacts are not sent. Memory and everything else keep travelling."
    public static let diskLowLine = "This Mac has less than 2 GB free, so artifacts from your other devices wait until there is more room."
    public static func tooLargeLine(_ count: Int) -> String {
        count == 1 ? "1 artifact larger than 25 MB stays on this Mac (artifacts up to 25 MB travel)."
                   : "\(count) artifacts larger than 25 MB stay on this Mac (artifacts up to 25 MB travel)."
    }
    public static func secretNameLine(_ names: [String]) -> String {
        (names.count == 1 ? "1 artifact stays on this Mac because it is, or holds, a key, password or sign-in: "
                          : "\(names.count) artifacts stay on this Mac because they are, or hold, a key, password or sign-in: ")
            + CloudFolderFormat.names(names) + "."
    }
    public static func spellingLine(_ names: [String]) -> String {
        (names.count == 1 ? "1 artifact stays on this Mac because its name is spelled with separate accent marks: "
                          : "\(names.count) artifacts stay on this Mac because their names are spelled with separate accent marks: ")
            + CloudFolderFormat.names(names) + "."
    }
    public static func clashLine(_ names: [String]) -> String {
        (names.count == 1 ? "1 artifact stays apart because its name is a file on one Mac and a folder on another: "
                          : "\(names.count) artifacts stay apart because their names are a file on one Mac and a folder on another: ")
            + CloudFolderFormat.names(names) + "."
    }
    public static func gateLine(_ macs: [String]) -> String {
        "Artifacts are not sent yet: " + BackendCloudContentsWords.list(Array(Set(macs)).sorted())
            + (macs.count == 1 ? " has" : " have") + " not updated Terminal Deck or " + (macs.count == 1 ? "has" : "have") + " Cloud off."
    }
    public static let exclusions = [
        "Artifacts made outside a project's folder stay on this Mac.",
        "Keys, environment and sign-in files, and artifacts that hold a key or password, never travel.",
        "Hidden and temporary files stay on this Mac."
    ]
    /// "From MacBook Pro": the quiet line on the Artifacts page for an artifact another Mac made.
    public static func fromLine(_ mac: String) -> String { "From " + mac }
}

/// The description that travels beside each artifact (a few hundred bytes; changes only when its name, project or
/// maker changes). Never a path outside the project, never a session id.
public struct CloudArtifactAbout: Codable, Sendable, Equatable {
    public var v = 1
    public var name: String
    public var project: String
    public var projectId: String
    /// The agent or session that made it ("Reviewer", "Hoot"); nil when not known.
    public var madeBy: String?
    /// When it was first made (ms).
    public var createdAt: Int64
    /// "Web page", "Document", "Image" (`ArtifactRules.kindOf`).
    public var type: String
    /// The Mac that made it (device id; the page says the Mac's name).
    public var device: String
    public init(name: String, project: String, projectId: String, madeBy: String?, createdAt: Int64, type: String, device: String) {
        self.name = name; self.project = project; self.projectId = projectId; self.madeBy = madeBy; self.createdAt = createdAt
        self.type = type; self.device = device
    }
    /// Equal apart from the Mac that wrote it (so another Mac never rewrites a description only to put its own id in).
    func sameAs(_ other: CloudArtifactAbout) -> Bool {
        name == other.name && project == other.project && projectId == other.projectId && madeBy == other.madeBy
            && createdAt == other.createdAt && type == other.type
    }
}

/// One artifact as the Artifacts page lists it (from the page's own catalogue).
public struct CloudArtifactEntry: Sendable, Equatable {
    public let projectId: String
    public let projectName: String
    /// The project folder the catalogue read it from.
    public let root: String
    public let relPath: String
    public let name: String
    public let madeBy: String?
    public let createdAt: Int64
    public init(projectId: String, projectName: String, root: String, relPath: String, name: String, madeBy: String?, createdAt: Int64) {
        self.projectId = projectId; self.projectName = projectName; self.root = root; self.relPath = relPath; self.name = name
        self.madeBy = madeBy; self.createdAt = createdAt
    }
}

/// One artifact in the store (made here or on another device), as the Artifacts page and the tools show it.
public struct CloudArtifactItem: Sendable, Equatable, Identifiable {
    /// The store path (`<project id>/<path inside the project>`). Never shown.
    public let path: String
    public let projectId: String
    public let relPath: String
    public let name: String
    public let project: String?
    public let madeBy: String?
    public let createdAt: Int64
    public let changedAt: Int64
    public let type: String
    public let bytes: Int64
    /// Device id of the Mac that made it; nil when its description has not arrived (yet).
    public let device: String?
    /// The file to open (inside the app's own store).
    public let url: URL
    public var id: String { path }
    public init(path: String, projectId: String, relPath: String, name: String, project: String?, madeBy: String?, createdAt: Int64,
                changedAt: Int64, type: String, bytes: Int64, device: String?, url: URL) {
        self.path = path; self.projectId = projectId; self.relPath = relPath; self.name = name; self.project = project; self.madeBy = madeBy
        self.createdAt = createdAt; self.changedAt = changedAt; self.type = type; self.bytes = bytes; self.device = device; self.url = url
    }
}

public actor BackendCloudArtifacts {
    /// The Cloud folder's owner over the artifacts store (`CloudFileKind.artifacts`).
    public nonisolated let owner: BackendCloudFolder
    public nonisolated let store: URL
    let stateRoot: URL
    /// This Mac's device id (lower case).
    public nonisolated let deviceId: String
    private var opened: BackendCloudBrainFilesDatabase?

    /// - `store`: `<cloud>/<subject>/artifacts-files` (the app's own folder; never his projects).
    /// - `stateRoot`: `<cloud>/<subject>/artifacts` (the owner's state is `<stateRoot>/owner`).
    public init(deviceId: String, store: URL, stateRoot: URL, everyMacUnderstands: @escaping @Sendable () async -> Bool,
                freeDisk: (@Sendable () -> Int64?)? = nil,
                now: @escaping @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) }) throws {
        let ownerState = stateRoot.appendingPathComponent("owner", isDirectory: true)
        owner = try BackendCloudFolder(deviceId: deviceId, folder: store, stateRoot: ownerState, kind: .artifacts,
                                       everyMacUnderstands: everyMacUnderstands, freeDisk: freeDisk, now: now)
        self.store = store.standardizedFileURL
        self.stateRoot = stateRoot.standardizedFileURL
        self.deviceId = deviceId.lowercased()
    }

    static let schema = """
        CREATE TABLE IF NOT EXISTS artifacts_fed(path TEXT PRIMARY KEY, bytes INTEGER NOT NULL, modified INTEGER NOT NULL,
            state TEXT NOT NULL, name TEXT NOT NULL);
        """
    /// `state`: "fed" (in the store as of this stamp), "removed" (he removed it; fed again only once it changes),
    /// "large" (over 25 MB), "secret" (is or holds a secret). The last two are said on the page by name or count.
    func database() throws -> BackendCloudBrainFilesDatabase {
        if let opened { return opened }
        try FileManager.default.createDirectory(at: stateRoot, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let made = try BackendCloudBrainFilesDatabase(path: stateRoot.appendingPathComponent("feed.db").path, engineTables: false)
        try made.exec(Self.schema)
        opened = made
        return made
    }

    /// The store, made once when artifacts start on this Mac (never again by itself: a store that is gone later is said
    /// on the Cloud page and "Make it again" makes it again, as the Cloud folder does).
    public func prepareStore() throws {
        let ledger = stateRoot.appendingPathComponent("store-made")
        guard !FileManager.default.fileExists(atPath: ledger.path) else { return }
        try FileManager.default.createDirectory(at: store, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.createDirectory(at: stateRoot, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try Data("1".utf8).write(to: ledger, options: .atomic)
    }

    // MARK: Feeding the store from the Artifacts page's list

    /// Copies each listed artifact that is new or changed since it was last copied into the store. Nothing before this
    /// Mac has read the Cloud; nothing that is or holds a secret; nothing over 25 MB (counted, said on the page); never
    /// a file outside its project folder, through a link, or still being written. Returns how many it copied.
    @discardableResult
    public func feed(_ entries: [CloudArtifactEntry]) async throws -> Int {
        guard try await owner.hasReadCloud() else { return 0 }
        let db = try database()
        var copied = 0
        for entry in entries {
            guard let path = CloudArtifactsFormat.storePath(projectId: entry.projectId, relPath: entry.relPath) else { continue }
            // Never recreate a store file which the person removed or kept local-only, even if its project changes.
            if try await owner.localMark(path: path) != nil { continue }
            let root = URL(fileURLWithPath: entry.root, isDirectory: true).standardizedFileURL
            guard root.path.hasPrefix("/"), let stamp = CloudFolderDisk.stamp(root, entry.relPath) else { continue }
            let held = try db.first("SELECT bytes,modified,state FROM artifacts_fed WHERE path=?", [.text(path)])
            // Unchanged since it was last looked at (copied, removed by him, or kept here): nothing to do.
            if let held, held.int(0) == stamp.bytes, held.int(1) == stamp.modified { continue }
            func mark(_ state: String) throws {
                try db.run("INSERT OR REPLACE INTO artifacts_fed(path,bytes,modified,state,name) VALUES (?,?,?,?,?)",
                           [.text(path), .int(stamp.bytes), .int(stamp.modified), .text(state), .text(entry.name)])
            }
            switch owner.profile.refusal(path) {
            case nil: break
            case .secret?: try mark("secret"); continue
            default: continue
            }
            if stamp.bytes > CloudArtifactsFormat.maximumFileBytes { try mark("large"); continue }
            guard case .file(let bytes) = CloudFolderDisk.read(root, entry.relPath), CloudFolderDisk.stamp(root, entry.relPath) == stamp,
                  Int64(bytes.count) == stamp.bytes else { continue }
            if CloudArtifactsFormat.holdsSecret(entry.relPath, bytes) { try mark("secret"); continue }
            let hash = BackendCloudBrainMemoryHash.bytes(bytes)
            var expecting: String?
            switch CloudFolderDisk.read(store, path) {
            case .blocked: continue
            case .absent: expecting = nil
            case .file(let there):
                let thereHash = BackendCloudBrainMemoryHash.bytes(there)
                if thereHash == hash { try mark("fed"); continue }
                // A copy from another device is in the store and this Mac never copied its own: only a NEWER file of his
                // replaces it (two Macs that both have the project must never send an older file over a newer one).
                if held == nil, let at = CloudFolderDisk.stamp(store, path)?.modified, at >= stamp.modified { try mark("fed"); continue }
                expecting = thereHash
            }
            do { try await owner.storeWrite(path, bytes: bytes, modified: stamp.modified, expecting: expecting) } catch { continue }
            try? await writeAbout(path, entry)
            try mark("fed")
            copied += 1
        }
        return copied
    }
    /// The description beside the artifact, written only when it is new or says something different.
    func writeAbout(_ path: String, _ entry: CloudArtifactEntry) async throws {
        let about = CloudArtifactAbout(name: entry.name, project: entry.projectName, projectId: entry.projectId, madeBy: entry.madeBy,
                                       createdAt: entry.createdAt, type: ArtifactRules.kindOf(entry.relPath), device: deviceId)
        let aboutPath = path + CloudArtifactsFormat.aboutSuffix
        var expecting: String?
        switch CloudFolderDisk.read(store, aboutPath) {
        case .blocked: return
        case .absent: expecting = nil
        case .file(let there):
            if let held = try? JSONDecoder().decode(CloudArtifactAbout.self, from: there), held.sameAs(about) { return }
            expecting = BackendCloudBrainMemoryHash.bytes(there)
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        try await owner.storeWrite(aboutPath, bytes: try encoder.encode(about), modified: nil, expecting: expecting)
    }

    // MARK: What the page and the tools list

    /// Every artifact in the store (made here or on another device), newest change first.
    public func items() throws -> [CloudArtifactItem] {
        let walk = CloudFolderWalk.run(store)
        var made: [CloudArtifactItem] = []
        for (path, entry) in walk.files where !CloudArtifactsFormat.isAbout(path) {
            guard let slash = path.firstIndex(of: "/") else { continue }
            let projectId = String(path[..<slash]), relPath = String(path[path.index(after: slash)...])
            var about: CloudArtifactAbout?
            if case .file(let bytes) = CloudFolderDisk.read(store, path + CloudArtifactsFormat.aboutSuffix) {
                about = try? JSONDecoder().decode(CloudArtifactAbout.self, from: bytes)
            }
            if let held = about, held.projectId != projectId { about = nil }
            made.append(CloudArtifactItem(path: path, projectId: projectId, relPath: relPath, name: about?.name ?? ArtifactRules.lastComponent(relPath),
                                          project: about?.project, madeBy: about?.madeBy, createdAt: about?.createdAt ?? entry.modified,
                                          changedAt: entry.modified, type: about?.type ?? ArtifactRules.kindOf(relPath), bytes: entry.bytes,
                                          device: about?.device, url: store.appendingPathComponent(path)))
        }
        return made.sorted { $0.changedAt != $1.changedAt ? $0.changedAt > $1.changedAt : $0.path < $1.path }
    }
    /// The Cloud page's numbers: artifacts in the store and their size.
    public func counts() throws -> (artifacts: Int, bytes: Int64) {
        let all = try items()
        return (all.count, all.reduce(0) { $0 + $1.bytes })
    }

    // MARK: Explicit page/tool acts and person-only Bin restore

    /// Delete from list is one explicit Everywhere group. The project's original is never touched.
    @discardableResult
    public func remove(path: String, fromAI: Bool = false) async throws -> Bool {
        guard !CloudArtifactsFormat.isAbout(path), case .file = CloudFolderDisk.read(store, path) else { return false }
        let person = await owner.personActor()
        let actor = CloudDeleteActor(by: fromAI ? .ai : .person, mac: person.mac, macName: person.macName,
            at: person.at, group: person.group)
        _ = try await deleteItems([.init(id: path, kind: owner.profile.keeperKind, name: ArtifactRules.lastComponent(path), place: path)], scope: .everywhere, by: actor)
        return true
    }
    /// The store path of one artifact of the catalogue (nil when it is not one that travels).
    public nonisolated func path(projectId: String, relPath: String) -> String? { CloudArtifactsFormat.storePath(projectId: projectId, relPath: relPath) }
    /// Put back from the Bin: the artifact and its description come back in the store and travel again, so it is back
    /// on his other Macs too.
    @discardableResult
    public func putBack(path: String) async throws -> Bool {
        guard try await owner.putBack(path: path) else { return false }
        _ = try? await owner.putBack(path: path + CloudArtifactsFormat.aboutSuffix)
        return true
    }
    /// The Bin of artifacts on this Mac (descriptions are not items). `place` is the project's name when known.
    public func bin(projects: [String: String] = [:]) async throws -> [CloudFolderKept] {
        try await owner.bin().filter { !CloudArtifactsFormat.isAbout($0.path) }.map { kept in
            let projectId = kept.path.split(separator: "/").first.map(String.init) ?? ""
            return CloudFolderKept(path: kept.path, name: kept.name, place: projects[projectId] ?? "A project not on this Mac", at: kept.at,
                                   device: kept.device, bytes: kept.bytes, keptUntil: kept.keptUntil, sha256: kept.sha256)
        }
    }
    /// The page's lines for artifacts: the owner's own (gate, limits, room, disk) and what the feed kept on this Mac.
    public func pageLines() async throws -> [String] {
        var lines = try await owner.pageLines()
        let db = try database()
        let large = Int(try db.first("SELECT COUNT(*) FROM artifacts_fed WHERE state='large'")?.int(0) ?? 0)
        if large > 0 { lines.append(CloudArtifactsFormat.tooLargeLine(large)) }
        let secret = try db.rows("SELECT name FROM artifacts_fed WHERE state='secret' ORDER BY name").map { $0.text(0) }
        if !secret.isEmpty { lines.append(CloudArtifactsFormat.secretNameLine(secret)) }
        return lines
    }
}

public enum BackendCloudArtifactsWords {
    public static func waitingAnswer(_ answer: CloudFolderAnswer, from: String?) -> String? {
        answer.folderMissing ? "Your artifacts folder is not on this Mac" : nil
    }
}

extension BackendCloudArtifacts: CloudDeleteOwning {
    public func deleteItems(_ items: [CloudDeleteItem], scope: CloudDeleteScope, by actor: CloudDeleteActor) async throws -> CloudBinGroup {
        var all = items
        for item in items {
            guard !CloudArtifactsFormat.isAbout(item.id), owner.profile.refusal(item.id) == nil else { throw CloudFailure.invalidRequest }
            let about = item.id + CloudArtifactsFormat.aboutSuffix
            if case .file = CloudFolderDisk.read(store, about) {
                all.append(.init(id: about, kind: owner.profile.keeperKind, name: ArtifactRules.lastComponent(about), place: about))
            }
        }
        let group = try await owner.deleteItems(all, scope: scope, by: actor)
        // Only what was really removed (one item that failed never stops the rest; review 15 Nov).
        let removed = Set(group.items.map(\.id))
        let done = items.filter { removed.contains($0.id) }
        for item in done { try database().run("UPDATE artifacts_fed SET state='removed' WHERE path=?", [.text(item.id)]) }
        return .init(id: group.id, by: group.by, macName: group.macName, session: group.session, agent: group.agent, at: group.at, items: done)
    }
    public func bringBack(_ items: [CloudDeleteItem], to: CloudBringBackDestination) async throws -> [CloudDeleteItem] {
        var all = items
        for item in items {
            let about = item.id + CloudArtifactsFormat.aboutSuffix
            if try await owner.localMark(path: about) != nil || FileManager.default.fileExists(atPath: store.appendingPathComponent(about).path) {
                all.append(.init(id: about, kind: owner.profile.keeperKind, name: ArtifactRules.lastComponent(about), place: about))
            }
        }
        _ = try await owner.bringBack(all, to: to)
        return items
    }
    public func notHere() async throws -> [CloudNotHereItem] { try await owner.notHere() }
    public func binGroups() async throws -> [CloudBinGroup] { try await owner.binGroups() }
    /// Every entry of the group comes back, each artifact's description too (they share the group); one that fails is
    /// named in the log and the rest go on. Answers the artifacts that came back.
    public func putBackGroup(_ group: String) async throws -> [CloudDeleteItem] {
        try await owner.putBackGroup(group).filter { !CloudArtifactsFormat.isAbout($0.id) }
    }
    public func deleteForGood(_ items: [CloudDeleteItem]) async throws {
        var all = items
        for item in items {
            all.append(.init(id: item.id + CloudArtifactsFormat.aboutSuffix, kind: owner.profile.keeperKind, name: item.name, place: item.place))
        }
        try await owner.deleteForGood(all)
    }
}
