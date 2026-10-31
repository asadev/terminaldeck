import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers
import TerminalDeckNativeCore

// SRVFILES #120: a server's Files view and Galleries. Everything goes through the server's
// existing SSH sign-in (SFTP for folders and bytes, one read-only `find` for galleries).
// Limits: only the folders the owner allows (default: the sign-in's home folder), never a
// hidden app's folder, and nothing changes on a Look only server.

/// One file or folder as the Files view shows it.
public struct BackendServersFileEntry: Codable, Equatable, Sendable {
    public var name: String, path: String, kind: String
    public var size: Int64?, modified: Double?
    public init(name: String, path: String, kind: String, size: Int64? = nil, modified: Double? = nil) {
        self.name = name; self.path = path; self.kind = kind; self.size = size; self.modified = modified
    }
    public var isFolder: Bool { kind == "folder" }
    public var type: String { isFolder ? "folder" : BackendServersFileTypes.type(of: name) }
    public var wireValue: NativeRPCValue {
        .object([.init("name", .string(name)), .init("path", .string(path)), .init("kind", .string(kind)), .init("type", .string(type)),
                 .init("size", size.map { .number(Double($0)) } ?? .null), .init("modified", modified.map { .number($0 * 1000) } ?? .null)])
    }
}

/// File kinds by name. The galleries use photo, video, audio and document.
public enum BackendServersFileTypes {
    public static let photo: Set<String> = ["jpg", "jpeg", "png", "gif", "webp", "heic", "heif", "bmp", "tif", "tiff", "avif", "svg", "ico"]
    public static let video: Set<String> = ["mp4", "m4v", "mov", "webm", "mkv", "avi", "wmv", "mpg", "mpeg", "3gp"]
    public static let audio: Set<String> = ["mp3", "m4a", "aac", "wav", "flac", "ogg", "oga", "opus", "aif", "aiff", "wma"]
    public static let document: Set<String> = ["pdf", "doc", "docx", "xls", "xlsx", "ppt", "pptx", "odt", "ods", "odp", "rtf", "pages", "numbers", "key", "epub"]
    public static let text: Set<String> = ["txt", "md", "markdown", "log", "csv", "tsv", "ini", "conf", "cfg", "env", "properties", "rst"]
    public static let code: Set<String> = ["swift", "js", "mjs", "cjs", "ts", "tsx", "jsx", "py", "rb", "go", "rs", "java", "kt", "c", "h", "cc", "cpp", "hpp", "cs", "php",
                                           "sh", "bash", "zsh", "fish", "yml", "yaml", "json", "toml", "xml", "html", "htm", "css", "scss", "sql", "lua", "pl", "r", "vue", "svelte", "gradle", "dockerfile", "makefile"]
    public static let archive: Set<String> = ["zip", "tar", "gz", "tgz", "bz2", "xz", "7z", "rar", "zst"]
    public static let galleries = ["photo", "video", "audio", "document"]
    public static func ext(_ name: String) -> String {
        let lower = name.lowercased()
        if lower == "dockerfile" || lower == "makefile" { return lower }
        guard let dot = lower.lastIndex(of: "."), dot != lower.startIndex else { return "" }
        return String(lower[lower.index(after: dot)...])
    }
    public static func type(of name: String) -> String {
        let e = ext(name)
        if photo.contains(e) { return "photo" }; if video.contains(e) { return "video" }; if audio.contains(e) { return "audio" }
        if document.contains(e) { return "document" }; if text.contains(e) { return "text" }; if code.contains(e) { return "code" }
        if archive.contains(e) { return "archive" }
        if name.hasPrefix("."), !name.dropFirst().contains(".") { return "text" }
        return "other"
    }
    public static func extensions(for gallery: String) -> Set<String> {
        switch gallery { case "photo": photo; case "video": video; case "audio": audio; case "document": document; default: [] }
    }
    /// Files an AI app never reads through files_read, wherever they are.
    public static func looksSecret(_ path: String) -> Bool {
        let parts = path.lowercased().split(separator: "/").map(String.init)
        guard let name = parts.last else { return false }
        if parts.dropLast().contains(where: { [".ssh", ".gnupg", ".aws", ".kube", ".docker"].contains($0) }) { return true }
        if name == ".env" || name.hasPrefix(".env.") || name.hasSuffix(".env") { return true }
        if ["id_rsa", "id_ed25519", "id_ecdsa", "id_dsa", ".netrc", ".pgpass", "credentials", "credentials.json", ".git-credentials", ".npmrc", ".pypirc"].contains(name) { return true }
        return [".pem", ".key", ".p12", ".pfx", ".keystore", ".jks"].contains { name.hasSuffix($0) }
    }
}

/// Lexical path helpers (the server's own realpath decides symlinks).
public enum BackendServersFilePaths {
    public static func normalise(_ path: String) -> String {
        var parts: [Substring] = []
        for part in path.split(separator: "/", omittingEmptySubsequences: true) {
            if part == "." { continue }
            if part == ".." { if !parts.isEmpty { parts.removeLast() }; continue }
            parts.append(part)
        }
        return "/" + parts.joined(separator: "/")
    }
    public static func join(_ folder: String, _ name: String) -> String { folder == "/" ? "/" + name : folder + "/" + name }
    public static func parent(_ path: String) -> String { let p = (path as NSString).deletingLastPathComponent; return p.isEmpty ? "/" : p }
    public static func inside(_ path: String, _ root: String) -> Bool { root == "/" || path == root || path.hasPrefix(root + "/") }
    public static func inside(_ path: String, roots: [String]) -> Bool { roots.contains { inside(path, $0) } }
    /// Path components under whichever root holds it.
    public static func relative(_ path: String, roots: [String]) -> [String] {
        guard let root = roots.filter({ inside(path, $0) }).max(by: { $0.count < $1.count }) else { return [] }
        return String(path.dropFirst(root == "/" ? 1 : root.count)).split(separator: "/").map(String.init)
    }
    public static func validName(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && !name.contains("/") && name.utf8.count <= 255 && !name.unicodeScalars.contains { $0.value < 32 || $0.value == 127 }
    }
}

/// What the Files view needs from a server. The live one rides the SSH sign-in; tests use a fake.
public protocol BackendServersFilesTransport: Sendable {
    func home(_ server: String) async throws -> String
    func realpath(_ server: String, _ path: String) async throws -> String
    func list(_ server: String, _ path: String) async throws -> [BackendServersFileEntry]
    func stat(_ server: String, _ path: String) async throws -> BackendServersFileEntry
    func read(_ server: String, _ path: String, from: Int, length: Int) async throws -> (bytes: Data, size: Int)
    func download(_ server: String, _ path: String, to local: URL) async throws -> Int
    func rename(_ server: String, _ from: String, _ to: String) async throws
    func delete(_ server: String, _ path: String, folder: Bool) async throws
    func upload(_ server: String, local: URL, folder: String) async throws -> String
    /// Read-only search by file extension under `roots`, skipping folders named in `skip`.
    func scan(_ server: String, roots: [String], skip: [String], extensions: [String], limit: Int,
              progress: @escaping @Sendable (Int, Int64) -> Void) async throws -> (entries: [BackendServersFileEntry], complete: Bool)
    /// Seconds of audio/video or pages of a PDF, using the server's own read-only tools. nil = unknown.
    func measure(_ server: String, _ path: String, type: String) async throws -> Double?
    /// A small JPEG made by the server's own ffmpeg/convert, read-only. nil = none there.
    func serverThumbnail(_ server: String, _ path: String, type: String) async throws -> Data?
    func close(_ server: String) async
}

/// The owner's per-server "Folders it may open". nil = the sign-in's home folder.
public final class BackendServersFolderLimits: @unchecked Sendable {
    public static let fileName = "files-folders.json", maximumFolders = 32
    private let file: URL, dataRoot: URL, policy: BackendServersStoragePolicy, lock = NSLock()
    private var cache: [String: [String]]?
    public init(dataRoot: URL, policy: BackendServersStoragePolicy) { self.dataRoot = dataRoot; self.policy = policy; file = dataRoot.appendingPathComponent(Self.fileName) }
    private func load() -> [String: [String]] {
        if let cache { return cache }
        var map: [String: [String]] = [:]
        if policy.mayRead, let bytes = try? Data(contentsOf: file), bytes.count <= 256 * 1024, let raw = try? NativeRPCValue.parseJSON(bytes, maximumBytes: 256 * 1024) {
            for field in raw["servers"].fields ?? [] { map[field.key] = Self.clean((field.value.elements ?? []).compactMap(\.string)) }
        }
        cache = map; return map
    }
    public static func clean(_ paths: [String]) -> [String] {
        var out: [String] = []
        for raw in paths {
            let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, text.utf8.count <= 4096, !text.unicodeScalars.contains(where: { $0.value < 32 }) else { continue }
            let value = text == "~" ? "~" : text.hasPrefix("~/") ? "~/" + BackendServersFilePaths.normalise(String(text.dropFirst(2))).dropFirst() : BackendServersFilePaths.normalise(text)
            if !out.contains(value) { out.append(value) }
            if out.count >= maximumFolders { break }
        }
        return out
    }
    public func folders(_ server: String) -> [String]? { lock.withLock { load()[server] } }
    public func set(_ server: String, _ paths: [String]?) throws {
        try lock.withLock {
            try policy.requireWrite()
            var map = load()
            if let paths, !paths.isEmpty { map[server] = Self.clean(paths) } else { map[server] = nil }
            try write(map)
        }
    }
    /// Drops servers that were removed from this app.
    public func keepOnly(_ ids: Set<String>) {
        lock.withLock {
            let map = load(); let kept = map.filter { ids.contains($0.key) }
            if kept.count != map.count, policy.mayWrite { try? write(kept) }
        }
    }
    private func write(_ map: [String: [String]]) throws {
        let value = NativeRPCValue.object([.init("version", .number(1)), .init("servers", .object(map.keys.sorted().map { .init($0, .array(map[$0]!.map(NativeRPCValue.string))) }))])
        try FileManager.default.createDirectory(at: dataRoot, withIntermediateDirectories: true)
        try BackendRemoteServeSecretFile.write(directory: dataRoot, file: file, contents: value.encodedJSON())
        cache = map
    }
}

/// A gallery index, cached per server so a scan is only repeated on request.
public struct BackendServersGalleryIndex: Codable, Equatable, Sendable {
    public var serverId: String, scannedAt: Double, roots: [String], complete: Bool
    public var entries: [BackendServersFileEntry]
    public var measured: [String: Double]
    public init(serverId: String, scannedAt: Double, roots: [String], complete: Bool, entries: [BackendServersFileEntry], measured: [String: Double] = [:]) {
        self.serverId = serverId; self.scannedAt = scannedAt; self.roots = roots; self.complete = complete; self.entries = entries; self.measured = measured
    }
}

public struct BackendServersFilesRefusal: Error, LocalizedError, Sendable {
    public let code: String, sentence: String
    public init(_ code: String, _ sentence: String) { self.code = code; self.sentence = sentence }
    public var errorDescription: String? { sentence }
}

/// The Files view and galleries for every server. Construction is inert.
public actor BackendServersFiles {
    public typealias Check = @Sendable (BackendServersCaller, BackendServersAuthorization) async throws -> Void
    public static let outside = "That is outside the folders this server lets Terminal Deck open. The owner can add folders in the server's settings (Access → Folders it may open)."
    public static let hidden = "That folder belongs to an app that is hidden on this server, so it can't be opened here."
    public static let lookOnly = "This server is set to Look only, so its files can be looked at and downloaded but not renamed, deleted or added to."
    public static let ownerOnly = "Only the person at this Mac can do that."
    public static let pageSize = 200, maxPage = 1000, uiReadCap = 4 * 1024 * 1024, aiReadCap = 256 * 1024
    public static let previewFileCap: Int64 = 1024 * 1024 * 1024, previewCacheCap: Int64 = 1024 * 1024 * 1024
    public static let thumbCacheCap: Int64 = 200 * 1024 * 1024, scanLimit = 100_000
    public static let skipAlways = ["node_modules", ".git", ".cache", ".npm", ".cargo", ".rustup", ".venv", "__pycache__", "proc"]

    public nonisolated let limits: BackendServersFolderLimits
    private let store: BackendServersStore, transport: any BackendServersFilesTransport, check: Check
    private let cacheRoot: URL, previewRoot: URL, downloads: URL
    private let publish: @Sendable (String, NativeRPCValue) async -> Void
    private let shownApps: BackendServersShownApps
    private let now: @Sendable () -> Double
    private var roots: [String: [String]] = [:]
    /// When a remembered `roots` answer missed a folder; it is looked up again `rootsRetry` seconds later (#507).
    private var partialRoots: [String: Double] = [:]
    static let rootsRetry: Double = 30
    private var listings: [String: (at: Double, entries: [BackendServersFileEntry])] = [:]
    private var indexes: [String: BackendServersGalleryIndex] = [:]
    private var scans: [String: Task<BackendServersGalleryIndex, Error>] = [:]
    private var thumbWrites = 0

    public init(store: BackendServersStore, transport: any BackendServersFilesTransport, dataRoot: URL, policy: BackendServersStoragePolicy,
                downloads: URL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads"),
                check: @escaping Check, publish: @escaping @Sendable (String, NativeRPCValue) async -> Void = { _, _ in },
                now: @escaping @Sendable () -> Double = { Date().timeIntervalSince1970 }, shownApps: BackendServersShownApps = .shared) {
        self.shownApps = shownApps
        self.store = store; self.transport = transport; self.check = check; self.publish = publish; self.now = now; self.downloads = downloads
        limits = BackendServersFolderLimits(dataRoot: dataRoot, policy: policy)
        cacheRoot = dataRoot.appendingPathComponent("files-cache", isDirectory: true)
        previewRoot = cacheRoot.appendingPathComponent("preview", isDirectory: true)
        try? FileManager.default.removeItem(at: previewRoot)
    }

    // MARK: limits

    private func server(_ id: String) throws -> BackendServersStoredServer {
        guard let row = try store.get(id) else { throw BackendServersFilesRefusal("unknown-server", "This app does not know a server by that name.") }
        return row
    }
    /// The real folders this server may open, resolved on the server.
    public func allowedRoots(_ id: String) async throws -> [String] {
        _ = try server(id)
        if let known = roots[id], partialRoots[id].map({ now() - $0 < Self.rootsRetry }) ?? true { return known }
        let home = BackendServersFilePaths.normalise(try await transport.home(id))
        var out: [String] = [], failed = false
        for raw in limits.folders(id) ?? ["~"] {
            let lexical = raw == "~" ? home : raw.hasPrefix("~/") ? BackendServersFilePaths.normalise(home + "/" + raw.dropFirst(2)) : raw
            guard let real = try? await transport.realpath(id, lexical) else { failed = true; continue }
            if !out.contains(real) { out.append(BackendServersFilePaths.normalise(real)) }
        }
        // #507: a lookup that missed a folder (a brief drop, or a folder made later) is asked again after a while, and
        // an empty one every time, instead of being remembered until the app restarts.
        if out.isEmpty { roots[id] = nil } else { roots[id] = out; partialRoots[id] = failed ? now() : nil }
        return out
    }
    /// Folder names of apps hidden by "Show only these apps". Compose folders are matched by
    /// project name only when no shown app shares it.
    public nonisolated static func hiddenFolders(_ id: String, shown filter: BackendServersShownApps = .shared) -> Set<String> {
        guard let shown = filter.shownNames(id) else { return [] }
        func candidates(_ name: String) -> Set<String> {
            var out: Set<String> = [name.lowercased()]
            var parts = name.lowercased().split(whereSeparator: { $0 == "-" || $0 == "_" }).map(String.init)
            if let last = parts.last, Int(last) != nil { parts.removeLast(); out.insert(parts.joined(separator: "-")) }
            if parts.count >= 2 { out.insert(parts.dropLast().joined(separator: "-")); out.insert(parts.dropLast().joined(separator: "_")) }
            return out.filter { $0.count >= 3 }
        }
        let kept = shown.reduce(into: Set<String>()) { $0.formUnion(candidates($1)) }
        let hiddenNames = Set(filter.seenNames(id)).subtracting(shown)
        return hiddenNames.reduce(into: Set<String>()) { $0.formUnion(candidates($1)) }.subtracting(kept)
    }
    private func isHidden(_ path: String, roots: [String], hidden: Set<String>) -> Bool {
        guard !hidden.isEmpty else { return false }
        return BackendServersFilePaths.relative(path, roots: roots).contains { hidden.contains($0.lowercased()) }
    }
    /// The real path of `raw`, refused when it is outside the allowed folders or hidden.
    public func resolve(_ id: String, _ raw: String) async throws -> String {
        let allowed = try await allowedRoots(id)
        guard let first = allowed.first else { throw BackendServersFilesRefusal("outside", "None of the folders this server may open exist on it. Check the server's settings.") }
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let lexical = text.isEmpty || text == "~" ? first : text.hasPrefix("~/") ? BackendServersFilePaths.normalise(first + "/" + text.dropFirst(2))
            : text.hasPrefix("/") ? BackendServersFilePaths.normalise(text) : BackendServersFilePaths.normalise(first + "/" + text)
        guard BackendServersFilePaths.inside(lexical, roots: allowed) else { throw BackendServersFilesRefusal("outside", Self.outside) }
        let real = BackendServersFilePaths.normalise(try await transport.realpath(id, lexical))
        guard BackendServersFilePaths.inside(real, roots: allowed) else { throw BackendServersFilesRefusal("outside", Self.outside) }
        guard !isHidden(real, roots: allowed, hidden: Self.hiddenFolders(id, shown: shownApps)) else { throw BackendServersFilesRefusal("hidden", Self.hidden) }
        return real
    }
    public func setFolders(_ id: String, _ paths: [String]?, caller: BackendServersCaller) async throws -> NativeRPCValue {
        guard caller.kind == .nativeUI else { throw BackendServersFilesRefusal("access-denied", "Only the person at this Mac can choose which folders a server may open.") }
        try await check(caller, .init(operation: "servers:files:folders:set", serverId: id, tier: .alter))
        let cleaned = paths.map(BackendServersFolderLimits.clean) ?? []
        let home = BackendServersFilePaths.normalise(try await transport.home(id))
        for path in cleaned where path != "~" {
            let lexical = path.hasPrefix("~/") ? BackendServersFilePaths.normalise(home + "/" + path.dropFirst(2)) : path
            guard (try? await transport.stat(id, lexical))?.isFolder == true else { throw BackendServersFilesRefusal("no-such-folder", "There is no folder at \(path) on this server.") }
        }
        try limits.set(id, cleaned.isEmpty ? nil : cleaned)
        roots[id] = nil; listings = listings.filter { !$0.key.hasPrefix(id + "|") }
        return try await folders(id, caller: caller)
    }
    public func folders(_ id: String, caller: BackendServersCaller) async throws -> NativeRPCValue {
        try await check(caller, .init(operation: "servers:files:folders", serverId: id, tier: .read))
        let saved = limits.folders(id)
        let resolved = (try? await allowedRoots(id)) ?? []
        return .object([.init("serverId", .string(id)), .init("saved", saved.map { .array($0.map(NativeRPCValue.string)) } ?? .null),
                        .init("roots", .array(resolved.map(NativeRPCValue.string))), .init("lookOnly", .bool(try server(id).isLookOnly))])
    }

    // MARK: reading

    public func list(_ id: String, path: String, query: String = "", sort: String = "name", descending: Bool = false,
                     offset: Int = 0, limit: Int = pageSize, fresh: Bool = false, caller: BackendServersCaller) async throws -> NativeRPCValue {
        try await check(caller, .init(operation: "servers:files:list", serverId: id, tier: .read))
        let folder = try await resolve(id, path)
        let allowed = try await allowedRoots(id), hidden = Self.hiddenFolders(id, shown: shownApps)
        let key = id + "|" + folder
        var entries: [BackendServersFileEntry]
        if !fresh, let cached = listings[key], now() - cached.at < 20 { entries = cached.entries }
        else {
            entries = try await transport.list(id, folder).filter { $0.name != "." && $0.name != ".." }
            if listings.count > 32 { listings.removeAll() }
            listings[key] = (now(), entries)
        }
        if !hidden.isEmpty { entries = entries.filter { !isHidden($0.path, roots: allowed, hidden: hidden) } }
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if !q.isEmpty { entries = entries.filter { $0.name.lowercased().contains(q) } }
        entries = Self.sorted(entries, by: sort, descending: descending)
        let start = max(0, min(offset, entries.count)), count = max(1, min(limit, Self.maxPage))
        let page = Array(entries[start..<min(entries.count, start + count)])
        let root = allowed.filter { BackendServersFilePaths.inside(folder, $0) }.max { $0.count < $1.count } ?? folder
        return .object([.init("ok", .bool(true)), .init("serverId", .string(id)), .init("path", .string(folder)), .init("root", .string(root)),
                        .init("roots", .array(allowed.map(NativeRPCValue.string))),
                        .init("parent", folder == root ? .null : .string(BackendServersFilePaths.parent(folder))),
                        .init("entries", .array(page.map(\.wireValue))), .init("total", .number(Double(entries.count))),
                        .init("offset", .number(Double(start))), .init("more", .bool(start + page.count < entries.count)),
                        .init("lookOnly", .bool(try server(id).isLookOnly))])
    }
    nonisolated static func sorted(_ entries: [BackendServersFileEntry], by sort: String, descending: Bool) -> [BackendServersFileEntry] {
        entries.sorted { a, b in
            if a.isFolder != b.isFolder { return a.isFolder }
            let order: ComparisonResult
            switch sort {
            case "size": order = (a.size ?? 0) == (b.size ?? 0) ? a.name.localizedStandardCompare(b.name) : (a.size ?? 0) < (b.size ?? 0) ? .orderedAscending : .orderedDescending
            case "date": order = (a.modified ?? 0) == (b.modified ?? 0) ? a.name.localizedStandardCompare(b.name) : (a.modified ?? 0) < (b.modified ?? 0) ? .orderedAscending : .orderedDescending
            case "kind": order = a.type == b.type ? a.name.localizedStandardCompare(b.name) : a.type.compare(b.type)
            default: order = a.name.localizedStandardCompare(b.name)
            }
            return descending ? order == .orderedDescending : order == .orderedAscending
        }
    }
    public func info(_ id: String, path: String, caller: BackendServersCaller) async throws -> BackendServersFileEntry {
        try await check(caller, .init(operation: "servers:files:info", serverId: id, tier: .read))
        let real = try await resolve(id, path)
        var entry = try await transport.stat(id, real)
        entry.path = real; entry.name = (real as NSString).lastPathComponent
        return entry
    }
    /// A bounded window of bytes. AI apps get at most 256 KB and never a secret-looking file.
    public func read(_ id: String, path: String, from: Int, length: Int, caller: BackendServersCaller) async throws -> (bytes: Data, size: Int, path: String) {
        try await check(caller, .init(operation: "servers:files:read", serverId: id, tier: .read))
        let real = try await resolve(id, path)
        if caller.kind != .nativeUI, BackendServersFileTypes.looksSecret(real) {
            throw BackendServersFilesRefusal("secret", "That looks like a key or password file, so AI apps can't read it. The person at this Mac can preview it on the server's Files page.")
        }
        let cap = caller.kind == .nativeUI ? Self.uiReadCap : Self.aiReadCap
        let answer = try await transport.read(id, real, from: max(0, from), length: max(0, min(length, cap)))
        return (answer.bytes, answer.size, real)
    }
    /// A whole-file copy for Quick Look, in a size-capped cache that is emptied on close.
    public func fetchForPreview(_ id: String, path: String, caller: BackendServersCaller) async throws -> URL {
        guard caller.kind == .nativeUI else { throw BackendServersFilesRefusal("access-denied", Self.ownerOnly) }
        let entry = try await info(id, path: path, caller: caller)
        guard !entry.isFolder else { throw BackendServersFilesRefusal("folder", "That is a folder.") }
        let size = entry.size ?? 0
        guard size <= Self.previewFileCap else { throw BackendServersFilesRefusal("too-big", "This file is too big to preview. Download it instead.") }
        try FileManager.default.createDirectory(at: previewRoot, withIntermediateDirectories: true)
        Self.trim(previewRoot, keepUnder: Self.previewCacheCap - size)
        let folder = previewRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let local = folder.appendingPathComponent(Self.safeLocalName(entry.name))
        do { _ = try await transport.download(id, entry.path, to: local) } catch { try? FileManager.default.removeItem(at: folder); throw error }
        return local
    }
    public nonisolated func releasePreview(_ local: String) {
        let url = URL(fileURLWithPath: local).standardizedFileURL
        let root = previewRoot.standardizedFileURL.path
        guard url.path.hasPrefix(root + "/") else { return }
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }
    /// Saves one file into ~/Downloads under a free name. Only on the owner's click.
    public func download(_ id: String, path: String, caller: BackendServersCaller) async throws -> URL {
        guard caller.kind == .nativeUI else { throw BackendServersFilesRefusal("access-denied", Self.ownerOnly) }
        let entry = try await info(id, path: path, caller: caller)
        guard !entry.isFolder else { throw BackendServersFilesRefusal("folder", "Folders can't be downloaded. Open it and download the files you need.") }
        try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
        let target = Self.freeName(in: downloads, Self.safeLocalName(entry.name))
        _ = try await transport.download(id, entry.path, to: target)
        return target
    }
    nonisolated static func safeLocalName(_ name: String) -> String {
        let cleaned = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-").trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmed = cleaned.hasPrefix(".") ? "_" + cleaned.dropFirst() : cleaned
        return trimmed.isEmpty ? "download" : String(trimmed.prefix(200))
    }
    nonisolated static func freeName(in folder: URL, _ name: String) -> URL {
        let base = (name as NSString).deletingPathExtension, ext = (name as NSString).pathExtension
        var candidate = folder.appendingPathComponent(name), n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = folder.appendingPathComponent(ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)"); n += 1
        }
        return candidate
    }
    nonisolated static func trim(_ folder: URL, keepUnder cap: Int64) {
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]
        guard let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: keys) else { return }
        var files: [(URL, Int64, Date)] = []
        for case let url as URL in walker {
            guard let v = try? url.resourceValues(forKeys: Set(keys)), v.isRegularFile == true else { continue }
            files.append((url, Int64(v.fileSize ?? 0), v.contentModificationDate ?? .distantPast))
        }
        var total = files.reduce(Int64(0)) { $0 + $1.1 }
        for file in files.sorted(by: { $0.2 < $1.2 }) where total > max(0, cap) {
            try? FileManager.default.removeItem(at: file.0); total -= file.1
        }
    }

    // MARK: changes (Look and change only, each one approved)

    private func requireChange(_ id: String, _ operation: String, _ arguments: NativeRPCValue, caller: BackendServersCaller) async throws {
        guard try !server(id).isLookOnly else { throw BackendServersFilesRefusal("look-only", Self.lookOnly) }
        try await check(caller, .init(operation: operation, serverId: id, tier: .alter, arguments: arguments))
        guard try !server(id).isLookOnly else { throw BackendServersFilesRefusal("look-only", Self.lookOnly) }
    }
    public func rename(_ id: String, path: String, to newName: String, caller: BackendServersCaller) async throws -> String {
        guard BackendServersFilePaths.validName(newName) else { throw BackendServersFilesRefusal("bad-name", "Choose a name without a slash.") }
        let real = try await resolve(id, path)
        guard !(try await allowedRoots(id)).contains(real) else { throw BackendServersFilesRefusal("root", "An allowed folder itself can't be renamed here.") }
        let target = BackendServersFilePaths.join(BackendServersFilePaths.parent(real), newName)
        guard BackendServersFilePaths.inside(target, roots: try await allowedRoots(id)) else { throw BackendServersFilesRefusal("outside", Self.outside) }
        try await requireChange(id, "servers:files:rename", .object([.init("path", .string(real)), .init("to", .string(target))]), caller: caller)
        if (try? await transport.stat(id, target)) != nil { throw BackendServersFilesRefusal("exists", "Something called \(newName) is already in that folder.") }
        try await transport.rename(id, real, target)
        forget(id); return target
    }
    public func delete(_ id: String, path: String, caller: BackendServersCaller) async throws {
        let real = try await resolve(id, path)
        guard !(try await allowedRoots(id)).contains(real) else { throw BackendServersFilesRefusal("root", "An allowed folder itself can't be deleted here.") }
        let entry = try await transport.stat(id, real)
        try await requireChange(id, "servers:files:delete", .object([.init("path", .string(real))]), caller: caller)
        try await transport.delete(id, real, folder: entry.isFolder)
        forget(id)
    }
    public func upload(_ id: String, local: URL, folder: String, caller: BackendServersCaller) async throws -> String {
        let target = try await resolve(id, folder)
        guard (try await transport.stat(id, target)).isFolder else { throw BackendServersFilesRefusal("not-folder", "Files can only be added into a folder.") }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: local.path, isDirectory: &isDirectory), !isDirectory.boolValue else { throw BackendServersFilesRefusal("no-file", "That file is not there any more.") }
        let size = (try? FileManager.default.attributesOfItem(atPath: local.path)[.size] as? NSNumber)?.int64Value ?? 0
        guard size <= 2 * 1024 * 1024 * 1024 else { throw BackendServersFilesRefusal("too-big", "That file is larger than 2 GB.") }
        try await requireChange(id, "servers:files:upload", .object([.init("from", .string(local.path)), .init("folder", .string(target))]), caller: caller)
        let placed = try await transport.upload(id, local: local, folder: target)
        forget(id); return placed
    }
    private func forget(_ id: String) { listings = listings.filter { !$0.key.hasPrefix(id + "|") } }

    // MARK: galleries

    private func indexFile(_ id: String) -> URL { cacheRoot.appendingPathComponent(Self.folderName(id), isDirectory: true).appendingPathComponent("gallery.json") }
    private func thumbFolder(_ id: String) -> URL { cacheRoot.appendingPathComponent(Self.folderName(id), isDirectory: true).appendingPathComponent("thumbs", isDirectory: true) }
    nonisolated static func folderName(_ id: String) -> String {
        let safe = id.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_" }
        return safe && !id.isEmpty && id.count <= 80 ? id : Data(SHA256.hash(data: Data(id.utf8))).map { String(format: "%02x", $0) }.joined()
    }
    private func loadIndex(_ id: String) -> BackendServersGalleryIndex? {
        if let index = indexes[id] { return index }
        guard let bytes = try? Data(contentsOf: indexFile(id)), let index = try? JSONDecoder().decode(BackendServersGalleryIndex.self, from: bytes), index.serverId == id else { return nil }
        indexes[id] = index; return index
    }
    private func saveIndex(_ index: BackendServersGalleryIndex) {
        indexes[index.serverId] = index
        let file = indexFile(index.serverId)
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let bytes = try? JSONEncoder().encode(index) { try? bytes.write(to: file, options: .atomic) }
    }
    /// Removes caches of servers that are no longer in this app.
    public func sweepRemovedServers() {
        guard let known = try? Set(store.list().map(\.id)) else { return }
        limits.keepOnly(known)
        let keep = Set(known.map(Self.folderName)).union(["preview"])
        for url in (try? FileManager.default.contentsOfDirectory(at: cacheRoot, includingPropertiesForKeys: nil)) ?? [] where !keep.contains(url.lastPathComponent) {
            try? FileManager.default.removeItem(at: url)
        }
        indexes = indexes.filter { known.contains($0.key) }
    }
    /// Scans the allowed folders for every gallery type, on request only.
    public func scan(_ id: String, caller: BackendServersCaller) async throws -> BackendServersGalleryIndex {
        try await check(caller, .init(operation: "servers:files:gallery:scan", serverId: id, tier: .read))
        sweepRemovedServers()
        if let running = scans[id] { return try await running.value }
        let allowed = try await allowedRoots(id)
        guard !allowed.isEmpty else { throw BackendServersFilesRefusal("outside", "None of the folders this server may open exist on it.") }
        let hidden = Self.hiddenFolders(id, shown: shownApps)
        let exts = BackendServersFileTypes.galleries.flatMap { BackendServersFileTypes.extensions(for: $0) }.sorted()
        let transport = self.transport, publish = self.publish, started = now()
        let task = Task<BackendServersGalleryIndex, Error> {
            // #509: progress goes out in order from one task (only the newest count waits), and all of it before the
            // scan's own last word, so the "found so far" count never goes back.
            let (counts, feed) = AsyncStream<(Int, Int64)>.makeStream(bufferingPolicy: .bufferingNewest(1))
            let sender = Task {
                for await (count, bytes) in counts {
                    await publish("servers:files:scan", .object([.init("serverId", .string(id)), .init("found", .number(Double(count))), .init("bytes", .number(Double(bytes))), .init("done", .bool(false))]))
                }
            }
            let found: (entries: [BackendServersFileEntry], complete: Bool)
            do {
                found = try await transport.scan(id, roots: allowed, skip: Self.skipAlways + hidden.sorted(), extensions: exts, limit: Self.scanLimit) { count, bytes in
                    feed.yield((count, bytes))
                }
                feed.finish(); await sender.value
            } catch {
                feed.finish(); await sender.value
                throw error
            }
            let entries = found.entries.filter { BackendServersFilePaths.inside($0.path, roots: allowed) }
            return BackendServersGalleryIndex(serverId: id, scannedAt: started, roots: allowed, complete: found.complete, entries: entries)
        }
        scans[id] = task
        defer { scans[id] = nil }
        var index = try await task.value
        index.entries = index.entries.filter { !isHidden($0.path, roots: allowed, hidden: hidden) && BackendServersFileTypes.galleries.contains($0.type) }
        index.measured = loadIndex(id)?.measured.filter { key, _ in index.entries.contains { $0.path == key } } ?? [:]
        saveIndex(index)
        let total = index.entries.reduce(Int64(0)) { $0 + ($1.size ?? 0) }
        await publish("servers:files:scan", .object([.init("serverId", .string(id)), .init("found", .number(Double(index.entries.count))), .init("bytes", .number(Double(total))), .init("done", .bool(true))]))
        return index
    }
    public func gallery(_ id: String, type: String, query: String = "", sort: String = "date", descending: Bool = true, group: String = "none",
                        offset: Int = 0, limit: Int = 300, scanIfMissing: Bool = false, caller: BackendServersCaller) async throws -> NativeRPCValue {
        guard BackendServersFileTypes.galleries.contains(type) else { throw BackendServersFilesRefusal("bad-type", "type must be one of photo, video, audio, document.") }
        try await check(caller, .init(operation: "servers:files:gallery", serverId: id, tier: .read))
        var index = loadIndex(id)
        if index == nil, scanIfMissing { index = try await scan(id, caller: caller) }
        let scanning = scans[id] != nil
        guard let index else {
            return .object([.init("ok", .bool(true)), .init("serverId", .string(id)), .init("type", .string(type)), .init("scanned", .bool(false)), .init("scanning", .bool(scanning)),
                            .init("items", .array([])), .init("total", .number(0)), .init("bytes", .number(0)), .init("counts", .object([]))])
        }
        let allowed = try await allowedRoots(id), hidden = Self.hiddenFolders(id, shown: shownApps)
        let usable = index.entries.filter { BackendServersFilePaths.inside($0.path, roots: allowed) && !isHidden($0.path, roots: allowed, hidden: hidden) }
        var counts: [NativeRPCValue.Field] = []
        for kind in BackendServersFileTypes.galleries {
            let rows = usable.filter { $0.type == kind }
            counts.append(.init(kind, .object([.init("count", .number(Double(rows.count))), .init("bytes", .number(Double(rows.reduce(Int64(0)) { $0 + ($1.size ?? 0) })))])))
        }
        var rows = usable.filter { $0.type == type }
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if !q.isEmpty { rows = rows.filter { $0.path.lowercased().contains(q) } }
        rows = Self.sorted(rows, by: sort, descending: descending)
        func label(_ entry: BackendServersFileEntry) -> String {
            if group == "folder" {
                let parent = BackendServersFilePaths.parent(entry.path)
                let home = allowed.first ?? ""
                return parent == home ? "~" : parent.hasPrefix(home + "/") ? "~/" + parent.dropFirst(home.count + 1) : parent
            }
            if group == "month", let m = entry.modified {
                let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM"; return f.string(from: Date(timeIntervalSince1970: m))
            }
            return ""
        }
        if group == "folder" { rows = rows.enumerated().sorted { a, b in let la = label(a.element), lb = label(b.element); return la == lb ? a.offset < b.offset : la.localizedStandardCompare(lb) == .orderedAscending }.map(\.element) }
        if group == "month" { rows.sort { ($0.modified ?? 0) > ($1.modified ?? 0) } }
        let start = max(0, min(offset, rows.count)), count = max(1, min(limit, Self.maxPage))
        let page = rows[start..<min(rows.count, start + count)].map { entry -> NativeRPCValue in
            var value = entry.wireValue.setting("folder", .string(BackendServersFilePaths.parent(entry.path)))
            if group != "none" { value = value.setting("group", .string(label(entry))) }
            if let measured = index.measured[entry.path] { value = value.setting(type == "document" ? "pages" : "seconds", .number(measured)) }
            return value
        }
        return .object([.init("ok", .bool(true)), .init("serverId", .string(id)), .init("type", .string(type)), .init("scanned", .bool(true)), .init("scanning", .bool(scanning)),
                        .init("scannedAt", .number(index.scannedAt * 1000)), .init("complete", .bool(index.complete)),
                        .init("items", .array(page)), .init("total", .number(Double(rows.count))), .init("offset", .number(Double(start))),
                        .init("more", .bool(start + page.count < rows.count)),
                        .init("bytes", .number(Double(rows.reduce(Int64(0)) { $0 + ($1.size ?? 0) }))), .init("counts", .object(counts))])
    }
    /// Duration or page count for one gallery file, kept in the index.
    public func measure(_ id: String, path: String, caller: BackendServersCaller) async throws -> Double? {
        let entry = try await info(id, path: path, caller: caller)
        if let known = loadIndex(id)?.measured[entry.path] { return known }
        guard ["audio", "video", "document"].contains(entry.type) else { return nil }
        guard let value = try await transport.measure(id, entry.path, type: entry.type) else { return nil }
        if var index = loadIndex(id) { index.measured[entry.path] = value; saveIndex(index) }
        return value
    }
    /// A local JPEG thumbnail for a photo or video, cached with a size cap.
    public func thumbnail(_ id: String, path: String, caller: BackendServersCaller) async throws -> URL? {
        guard caller.kind == .nativeUI else { throw BackendServersFilesRefusal("access-denied", Self.ownerOnly) }
        let entry = try await info(id, path: path, caller: caller)
        guard entry.type == "photo" || entry.type == "video" else { return nil }
        let key = Data(SHA256.hash(data: Data("\(entry.path)|\(entry.size ?? -1)|\(entry.modified ?? -1)".utf8))).prefix(16).map { String(format: "%02x", $0) }.joined()
        let folder = thumbFolder(id), file = folder.appendingPathComponent(key + ".jpg"), none = folder.appendingPathComponent(key + ".none")
        if FileManager.default.fileExists(atPath: file.path) { return file }
        if FileManager.default.fileExists(atPath: none.path) { return nil }
        var jpeg: Data?
        let size = Int(entry.size ?? 0)
        if entry.type == "photo", size > 0, size <= 8 * 1024 * 1024, BackendServersFileTypes.ext(entry.name) != "svg" {
            var bytes = Data()
            while bytes.count < size {
                let chunk = try await transport.read(id, entry.path, from: bytes.count, length: min(2 * 1024 * 1024, size - bytes.count))
                if chunk.bytes.isEmpty { break }; bytes.append(chunk.bytes)
            }
            jpeg = BackendServersThumbnails.make(from: bytes, maxPixels: 360)
        }
        if jpeg == nil { jpeg = try? await transport.serverThumbnail(id, entry.path, type: entry.type) }
        if jpeg == nil, entry.type == "photo", size > 8 * 1024 * 1024 {
            // Big photos often carry a small preview in their first bytes.
            if let head = try? await transport.read(id, entry.path, from: 0, length: 1024 * 1024) { jpeg = BackendServersThumbnails.make(from: head.bytes, maxPixels: 360, embeddedOnly: true) }
        }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        guard let jpeg else { FileManager.default.createFile(atPath: none.path, contents: Data()); return nil }
        try jpeg.write(to: file, options: .atomic)
        thumbWrites += 1
        if thumbWrites % 40 == 0 { Self.trimThumbs(cacheRoot) }
        return file
    }
    nonisolated static func trimThumbs(_ cacheRoot: URL) {
        for server in (try? FileManager.default.contentsOfDirectory(at: cacheRoot, includingPropertiesForKeys: nil)) ?? [] where server.lastPathComponent != "preview" {
            trim(server.appendingPathComponent("thumbs", isDirectory: true), keepUnder: thumbCacheCap / 4)
        }
    }
    public func closeServer(_ id: String) async { roots[id] = nil; forget(id); await transport.close(id) }
}


public enum BackendServersThumbnails {
    public static func make(from bytes: Data, maxPixels: Int, embeddedOnly: Bool = false) -> Data? {
        guard let source = CGImageSourceCreateWithData(bytes as CFData, nil) else { return nil }
        let options: [CFString: Any] = [kCGImageSourceThumbnailMaxPixelSize: maxPixels, kCGImageSourceCreateThumbnailWithTransform: true,
                                        embeddedOnly ? kCGImageSourceCreateThumbnailFromImageIfAbsent : kCGImageSourceCreateThumbnailFromImageAlways: true]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.78] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return out as Data
    }
}
