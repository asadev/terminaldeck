import Foundation

public struct NativeTranscriptHomeScope: Sendable {
    public let home: String
    public let folder: String
    public init(home: String, folder: String) { self.home = home; self.folder = folder }
}

/// Installed by app assembly, never accepted as options from page requests.
public struct NativeTranscriptScope: Sendable {
    public var configDirectory: String
    /// Additional account stores come only from the authenticated profile owner.
    public var additionalConfigDirectories: [String]
    /// Nil is the source owner-wide view; an empty list grants no project.
    public var projectFolders: [String]?
    public var deviceHomesRoot: String?
    public var homeScopes: [NativeTranscriptHomeScope]
    public var maximumDirectoryEntries: Int
    public init(configDirectory: String, deviceHomesRoot: String? = nil,
                homeScopes: [NativeTranscriptHomeScope] = [], maximumDirectoryEntries: Int = 10_000,
                additionalConfigDirectories: [String] = [], projectFolders: [String]? = nil) {
        self.configDirectory = configDirectory; self.deviceHomesRoot = deviceHomesRoot
        self.additionalConfigDirectories = additionalConfigDirectories; self.projectFolders = projectFolders
        self.homeScopes = homeScopes; self.maximumDirectoryEntries = max(1, maximumDirectoryEntries)
    }
    public static func environment(_ environment: [String: String] = ProcessInfo.processInfo.environment) -> Self {
        let override = environment["CLAUDE_CONFIG_DIR"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let home = environment["HOME"] ?? FileManager.default.homeDirectoryForCurrentUser.path
        return Self(configDirectory: override.isEmpty ? URL(fileURLWithPath: home).appendingPathComponent(".claude").path : override)
    }
}

public struct NativeTranscriptFile: Sendable {
    public let path: String
    public let sessionID: String
    public let createdAt: Double
    public let modifiedAt: Double
    public let bytes: Int64
    public var wireValue: [String: Any] {
        ["path": path, "sessionId": sessionID, "createdAt": createdAt, "modifiedAt": modifiedAt, "bytes": bytes]
    }
}

public enum NativeTranscriptPaths {
    public enum Failure: Error, LocalizedError {
        case pathRequired, outsideStore, directoryBudget, unreadableDirectory
        public var errorDescription: String? {
            switch self {
            case .pathRequired: return "chat: a transcript path or project folder is required."
            case .outsideStore: return "chat: refusing to read outside the approved transcript stores."
            case .directoryBudget: return "The transcript directory exceeds its entry budget. Select an exact transcript instead."
            case .unreadableDirectory: return "The transcript store exists but its directory could not be read."
            }
        }
    }

    public static func resolved(_ path: String) -> String { URL(fileURLWithPath: path).standardizedFileURL.path }
    public static func canonical(_ path: String) -> String { URL(fileURLWithPath: resolved(path)).resolvingSymlinksInPath().path }
    public static func isDescendant(_ path: String, of root: String) -> Bool {
        let root = resolved(root)
        return resolved(path).hasPrefix(root == "/" ? "/" : root + "/") && resolved(path) != root
    }
    public static func encodeProjectPath(_ cwd: String) -> String {
        resolved(cwd).unicodeScalars.map { scalar in
            let value = scalar.value
            return (65...90).contains(value) || (97...122).contains(value) || (48...57).contains(value) ? String(scalar) : "-"
        }.joined()
    }
    public static func projectSpellings(_ cwd: String) -> [String] {
        let literal = resolved(cwd), real = canonical(cwd)
        return literal == real ? [literal] : [literal, real]
    }

    private static func entries(_ directory: String, limit: Int) throws -> [URL] {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory, isDirectory: &isDirectory), isDirectory.boolValue else { return [] }
        guard let enumerator = FileManager.default.enumerator(at: URL(fileURLWithPath: directory),
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey, .creationDateKey],
            options: [.skipsSubdirectoryDescendants]) else { throw Failure.unreadableDirectory }
        var result: [URL] = []
        for case let url as URL in enumerator {
            guard result.count < limit else { throw Failure.directoryBudget }
            result.append(url)
        }
        return result
    }

    public static func configDirectories(_ scope: NativeTranscriptScope) throws -> [String] {
        var directories = ([scope.configDirectory] + scope.additionalConfigDirectories).map(resolved)
        if let root = scope.deviceHomesRoot {
            for home in try entries(root, limit: scope.maximumDirectoryEntries) {
                let values = try? home.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                guard values?.isDirectory == true, values?.isSymbolicLink != true else { continue }
                let config = home.appendingPathComponent(".claude").path
                if FileManager.default.fileExists(atPath: config), isDescendant(canonical(config), of: canonical(home.path)) {
                    directories.append(resolved(config))
                }
            }
        }
        var seen = Set<String>()
        return directories.filter { seen.insert($0).inserted }
    }

    public static func projectDirectories(_ cwd: String, scope: NativeTranscriptScope) throws -> [String] {
        try projectDirectories(cwd, scope: scope, configs: configDirectories(scope))
    }
    private static func projectDirectories(_ cwd: String, scope: NativeTranscriptScope, configs: [String]) throws -> [String] {
        let asked = resolved(cwd)
        if let permitted = scope.projectFolders {
            guard permitted.contains(where: { resolved($0) == asked || canonical($0) == canonical(cwd) }) else { throw Failure.outsideStore }
        }
        let configs = configs.filter { directory in
            let scoped = scope.homeScopes.first { resolved(URL(fileURLWithPath: $0.home).appendingPathComponent(".claude").path) == resolved(directory) }
            return scoped == nil || resolved(scoped!.folder) == asked
        }
        var seen = Set<String>(), result: [String] = []
        for config in configs {
            for spelling in projectSpellings(cwd) {
                let path = URL(fileURLWithPath: config).appendingPathComponent("projects").appendingPathComponent(encodeProjectPath(spelling)).path
                if seen.insert(path).inserted { result.append(path) }
            }
        }
        return result
    }

    public static func approvedRoots(_ scope: NativeTranscriptScope) throws -> [String] {
        try configDirectories(scope).map { canonical(URL(fileURLWithPath: $0).appendingPathComponent("projects").path) }
    }

    private struct Access {
        let roots: [String]
        let directories: [String]?
        init(_ scope: NativeTranscriptScope, configs: [String]) throws {
            roots = configs.map { canonical(URL(fileURLWithPath: $0).appendingPathComponent("projects").path) }
            directories = try scope.projectFolders.map { permitted in
                try permitted.flatMap { try projectDirectories($0, scope: scope, configs: configs) }.map(canonical)
            }
        }
        func check(_ path: String) throws -> String {
            guard !path.isEmpty else { throw Failure.pathRequired }
            let real = canonical(path)
            guard URL(fileURLWithPath: resolved(path)).pathExtension == "jsonl",
                  roots.contains(where: { isDescendant(real, of: $0) }),
                  directories?.contains(where: { isDescendant(real, of: $0) }) != false else { throw Failure.outsideStore }
            return real
        }
    }
    public static func assertTranscript(_ path: String, scope: NativeTranscriptScope) throws -> String {
        try Access(scope, configs: configDirectories(scope)).check(path)
    }

    public static func listTranscripts(_ directory: String, scope: NativeTranscriptScope) throws -> [NativeTranscriptFile] {
        try listTranscripts(directory, scope: scope, access: Access(scope, configs: configDirectories(scope)))
    }
    /// 28 Oct (CPU): one conversation's own transcript in `directory`, under the same checks a listing makes, without
    /// listing and checking every other conversation in the folder (a session that knows its conversation needs only it).
    public static func transcript(named id: String, in directory: String, scope: NativeTranscriptScope) throws -> NativeTranscriptFile? {
        guard id.range(of: "^[A-Za-z0-9_-]{1,128}$", options: .regularExpression) != nil else { return nil }
        let url = URL(fileURLWithPath: directory).appendingPathComponent(id + ".jsonl")
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let access = try Access(scope, configs: configDirectories(scope))
        guard let path = try? access.check(url.path),
              let values = try? URL(fileURLWithPath: path).resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey, .creationDateKey]),
              values.isRegularFile == true else { return nil }
        let modified = (values.contentModificationDate?.timeIntervalSince1970 ?? 0) * 1000
        let born = (values.creationDate?.timeIntervalSince1970 ?? 0) * 1000
        return NativeTranscriptFile(path: path, sessionID: id, createdAt: born > 0 && born <= modified ? born : modified,
            modifiedAt: modified, bytes: Int64(values.fileSize ?? 0))
    }
    private static func listTranscripts(_ directory: String, scope: NativeTranscriptScope, access: Access) throws -> [NativeTranscriptFile] {
        var files: [NativeTranscriptFile] = []
        for url in try entries(directory, limit: scope.maximumDirectoryEntries) where url.pathExtension == "jsonl" {
            guard let path = try? access.check(url.path),
                  let values = try? URL(fileURLWithPath: path).resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey, .creationDateKey]),
                  values.isRegularFile == true else { continue }
            let modified = (values.contentModificationDate?.timeIntervalSince1970 ?? 0) * 1000
            let born = (values.creationDate?.timeIntervalSince1970 ?? 0) * 1000
            files.append(NativeTranscriptFile(path: path, sessionID: url.deletingPathExtension().lastPathComponent,
                createdAt: born > 0 && born <= modified ? born : modified, modifiedAt: modified, bytes: Int64(values.fileSize ?? 0)))
        }
        return files.sorted { $0.modifiedAt > $1.modifiedAt }
    }

    public static func newest(_ cwd: String, scope: NativeTranscriptScope) throws -> NativeTranscriptFile? {
        let configs = try configDirectories(scope), access = try Access(scope, configs: configs)
        var newest: NativeTranscriptFile?
        for directory in try projectDirectories(cwd, scope: scope, configs: configs) {
            for file in try listTranscripts(directory, scope: scope, access: access) where newest == nil || file.modifiedAt > newest!.modifiedAt { newest = file }
        }
        return newest
    }
}
