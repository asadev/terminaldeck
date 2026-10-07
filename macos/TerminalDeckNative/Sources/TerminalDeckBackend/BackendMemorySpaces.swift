import Foundation
import CryptoKit
import Darwin
import TerminalDeckNativeCore

public struct BackendMemoryAccountStore: Sendable {
    public let provider: String; public let configDir: String; public let name: String
    public init(provider: String, configDir: String, name: String) { self.provider = provider; self.configDir = configDir; self.name = name }
}
public struct BackendMemorySources: Sendable {
    public let stores: [BackendMemoryAccountStore]; public let hootMemory: String?; public let userData: String?
    public init(stores: [BackendMemoryAccountStore], hootMemory: String?, userData: String?) {
        self.stores = stores; self.hootMemory = hootMemory; self.userData = userData
    }
}
public struct BackendMemoryFoundSpace: Sendable {
    public struct Member: Sendable {
        public let folder: String; public let project: String?; public let linked: Bool
    }
    public let space: MemorySpace; public let store: String?
    public let projectsDirs: [String]; public let members: [Member]; public let stores: [String]
    public var id: String { space.id }; public var root: String { space.root }
    public var wire: NativeRPCValue {
        BackendMemoryParsing.object([("id", .string(id)), ("kind", .string(space.kind.rawValue)), ("label", .string(space.label)),
            ("root", .string(root)), ("project", BackendMemoryParsing.optional(space.project)), ("store", BackendMemoryParsing.optional(store)),
            ("sharedWith", BackendMemoryParsing.strings(space.sharedWith)), ("accounts", BackendMemoryParsing.strings(space.accounts)),
            ("projectsDirs", BackendMemoryParsing.strings(projectsDirs)), ("stores", BackendMemoryParsing.strings(stores)),
            ("members", .array(members.map { BackendMemoryParsing.object([("folder", .string($0.folder)), ("project", BackendMemoryParsing.optional($0.project)), ("linked", .bool($0.linked))]) }))])
    }
}
public enum BackendMemorySpaces {
    public static func id(kind: MemorySpaceKind, root: String) -> String {
        kind.rawValue + ":" + SHA256.hash(data: Data(root.utf8)).prefix(6).map { String(format: "%02x", $0) }.joined()
    }
    public static func realDir(_ path: String) -> String? {
        guard let real = try? BackendFilesystemAuthority.canonical(URL(fileURLWithPath: path)),
              (try? real.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { return nil }; return real.path
    }
    static func directory(_ path: String) -> [String] { (try? FileManager.default.contentsOfDirectory(atPath: path)) ?? [] }
    static func joined(_ base: String, _ path: String) -> String { URL(fileURLWithPath: base).appendingPathComponent(path).path }
    static func transcriptFiles(_ folder: String, projectsDir: String) -> [NativeTranscriptFile] {
        let config = URL(fileURLWithPath: projectsDir).deletingLastPathComponent().path
        return (try? NativeTranscriptPaths.listTranscripts(folder, scope: .init(configDirectory: config, maximumDirectoryEntries: Int.max))) ?? []
    }
    public static func projectOfFolder(projectsDir: String, folder: String) -> String? {
        let path = joined(projectsDir, folder)
        var recorded: String?
        for file in transcriptFiles(path, projectsDir: projectsDir).prefix(3) {
            guard let head = try? BackendMemoryFiles.head(file.path, limit: 64 * 1024).text else { continue }
            for line in head.components(separatedBy: "\n") where line.contains("\"cwd\"") {
                if let value = try? NativeRPCValue.parseJSON(Data(line.utf8)), let cwd = value["cwd"].string, !cwd.isEmpty {
                    recorded = cwd
                    break
                }
            }
            if recorded != nil { break }
        }
        if let recorded, NativeTranscriptPaths.encodeProjectPath(recorded) == folder { return recorded }
        if folder.hasPrefix("-") {
            let plain = folder.replacingOccurrences(of: "-", with: "/")
            if NativeTranscriptPaths.encodeProjectPath(plain) == folder, realDir(plain) != nil { return plain }
        }
        return nil
    }
    public static func discover(_ input: BackendMemorySources) -> [BackendMemoryFoundSpace] {
        var byProjects: [String: [BackendMemoryAccountStore]] = [:], projectOrder: [String] = []
        for store in input.stores where store.provider == "claude" {
            guard let real = realDir(joined(store.configDir, "projects")) else { continue }
            if byProjects[real] == nil { projectOrder.append(real) }; byProjects[real, default: []].append(store)
        }
        struct Group { var root: String; var directories: [String] = []; var members: [BackendMemoryFoundSpace.Member] = []; var stores: [BackendMemoryAccountStore] = [] }
        var groups: [String: Group] = [:], order: [String] = []
        for projects in projectOrder { for folder in directory(projects).sorted() {
            let path = joined(projects, folder), memory = joined(path, "memory")
            var info = stat(); guard lstat(memory, &info) == 0, let root = realDir(memory) else { continue }
            let linked = (info.st_mode & S_IFMT) == S_IFLNK || realDir(path).map { $0 != path } == true
            if groups[root] == nil { groups[root] = Group(root: root); order.append(root) }
            var group = groups[root]!
            if !group.directories.contains(projects) { group.directories.append(projects) }
            group.members.append(.init(folder: folder, project: projectOfFolder(projectsDir: projects, folder: folder), linked: linked))
            for store in byProjects[projects] ?? [] where !group.stores.contains(where: { $0.configDir == store.configDir }) { group.stores.append(store) }
            groups[root] = group
        } }
        var claude = order.compactMap { root -> BackendMemoryFoundSpace? in
            guard let group = groups[root] else { return nil }
            let members = group.members.sorted { $0.linked == $1.linked ? $0.folder.localizedCompare($1.folder) == .orderedAscending : !$0.linked }
            guard let owner = members.first else { return nil }
            let label = owner.project.map { URL(fileURLWithPath: $0).lastPathComponent.isEmpty ? $0 : URL(fileURLWithPath: $0).lastPathComponent } ?? owner.folder
            return BackendMemoryFoundSpace(space: .init(id: id(kind: .claudeProject, root: root), kind: .claudeProject, label: label, root: root, project: owner.project,
                sharedWith: members.dropFirst().map { $0.project ?? $0.folder }, accounts: group.stores.map(\.name)), store: group.stores.first?.configDir,
                projectsDirs: group.directories, members: members, stores: group.stores.map(\.configDir))
        }
        claude.sort { $0.space.label.localizedCompare($1.space.label) == .orderedAscending }
        var codex: [String: [BackendMemoryAccountStore]] = [:], codexOrder: [String] = []
        for store in input.stores where store.provider == "codex" {
            guard let root = realDir(joined(store.configDir, "memories")) else { continue }
            if codex[root] == nil { codexOrder.append(root) }; codex[root, default: []].append(store)
        }
        func single(_ kind: MemorySpaceKind, _ root: String, _ label: String, project: String? = nil, accounts: [BackendMemoryAccountStore] = []) -> BackendMemoryFoundSpace {
            .init(space: .init(id: id(kind: kind, root: root), kind: kind, label: label, root: root, project: project, accounts: accounts.map(\.name)),
                store: accounts.first?.configDir, projectsDirs: [], members: [], stores: accounts.map(\.configDir))
        }
        let codexSpaces = codexOrder.map { root in single(.codex, root, codexOrder.count > 1 ? "Codex · " + (codex[root]?.first?.name ?? "") : "Codex", accounts: codex[root] ?? []) }
        let hoot = input.hootMemory.flatMap(realDir).map { [single(.hoot, $0, "Hoot")] } ?? []
        var knowledge: [BackendMemoryFoundSpace] = []
        if let userData = input.userData {
            let base = joined(userData, "knowledge")
            for key in directory(base).sorted() {
                guard let root = realDir(joined(base, key)), let data = try? Data(contentsOf: URL(fileURLWithPath: joined(root, "project.json"))),
                      let parsed = try? NativeRPCValue.parseJSON(data), let project = parsed["project"].string, !project.isEmpty else { continue }
                knowledge.append(single(.knowledge, root, URL(fileURLWithPath: project).lastPathComponent, project: project))
            }
        }
        return hoot + claude + codexSpaces + knowledge
    }
    public static func share(projectsDir: String, from: String, to: String,
                             consent: @Sendable (String, String) async throws -> Bool) async throws -> NativeRPCValue {
        func refused(_ message: String) -> NativeRPCValue { BackendMemoryParsing.object([("ok", .bool(false)), ("message", .string(message))]) }
        guard let projects = realDir(projectsDir) else { return refused("That account has no project history on this machine.") }
        let from = NativeTranscriptPaths.resolved(from), to = NativeTranscriptPaths.resolved(to)
        if from == to { return refused("A folder already reads its own memory.") }
        guard let target = realDir(joined(projects, NativeTranscriptPaths.encodeProjectPath(from) + "/memory")) else { return refused("\(from) has no memory to share yet.") }
        let folder = joined(projects, NativeTranscriptPaths.encodeProjectPath(to)), link = joined(folder, "memory")
        func exists() -> Bool { var info = stat(); return lstat(link, &info) == 0 }
        if exists() { return refused("\(to) already has memory of its own. Nothing was changed.") }
        let detail = "Claude Code sessions in \(to) will read and write the same memory as \(from), from now on. Nothing is copied or deleted; removing the link later undoes it."
        guard (try? await consent("Share this memory?", detail)) == true else { return refused("Not shared. Nothing was changed.") }
        if exists() { return refused("\(to) gained memory of its own while you were asked. Nothing was changed.") }
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: target)
        return BackendMemoryParsing.object([("ok", .bool(true)), ("link", .string(link)), ("target", .string(target))])
    }
}

enum BackendMemoryFiles {
    static func text(_ path: String) throws -> String { String(decoding: try Data(contentsOf: URL(fileURLWithPath: path)), as: UTF8.self) }
    static func head(_ path: String, limit: Int) throws -> (text: String, truncated: Bool) {
        let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path)); defer { try? handle.close() }
        let bytes = try handle.read(upToCount: limit + 1) ?? Data()
        return (String(decoding: bytes.prefix(limit), as: UTF8.self), bytes.count > limit)
    }
    static func info(_ path: String) throws -> (modified: Double, bytes: Double, file: Bool) {
        let info = try FileManager.default.attributesOfItem(atPath: path)
        return ((info[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0, (info[.size] as? NSNumber)?.doubleValue ?? 0, info[.type] as? FileAttributeType == .typeRegular)
    }
    static func version(_ info: (modified: Double, bytes: Double, file: Bool)) -> NativeRPCValue {
        BackendMemoryParsing.object([("modifiedAt", .number(info.modified * 1000)), ("bytes", .number(info.bytes))])
    }
}
