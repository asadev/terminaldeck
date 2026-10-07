import Foundation
import Darwin
import TerminalDeckNativeCore

public struct BackendBrowserProfile: Sendable, Equatable {
    public let id: String
    public var name: String
    public let createdAt: Double
    public var avatar: String
    public var isDefault: Bool { id == "default" }
    /// Kept as a compatibility field only. WebKit uses a persistent store UUID.
    public var partition: String { isDefault ? "persist:terminaldeck-browser" : "persist:terminaldeck-browser-" + id }
    public var wireValue: NativeRPCValue {
        .object([.init("id", .string(id)), .init("name", .string(name)), .init("partition", .string(partition)),
            .init("createdAt", .number(createdAt)), .init("isDefault", .bool(isDefault)), .init("avatar", .string(avatar))])
    }
    public var toolValue: NativeRPCValue { wireValue.removing("partition").removing("id").setting("profile", .string(id)) }
}

public struct BackendBrowserProfileState: Sendable {
    public let profiles: [BackendBrowserProfile]
    public let activeID: String
    public let retiringIDs: Set<String>
    public init(profiles: [BackendBrowserProfile], activeID: String, retiringIDs: Set<String> = []) {
        self.profiles = profiles; self.activeID = activeID; self.retiringIDs = retiringIDs
    }
    public var wireValue: NativeRPCValue {
        .object([.init("profiles", .array(profiles.map(\.wireValue))), .init("activeId", .string(activeID))])
    }
    public var toolProfiles: NativeRPCValue { .array(profiles.map { $0.toolValue.setting("on", .bool($0.id == activeID)) }) }
    public func resolve(_ named: String?) throws -> BackendBrowserProfile {
        guard let named, !named.isEmpty else {
            guard !retiringIDs.contains(activeID) else { throw NativeRPCError(code: "profile-retiring", message: "The active browser profile is being deleted. Choose another profile.") }
            guard let active = profiles.first(where: { $0.id == activeID }) else { throw NativeRPCError(code: "profile-missing", message: "The active browser profile is missing.") }
            return active
        }
        if let byID = profiles.first(where: { $0.id == named }) {
            guard !retiringIDs.contains(byID.id) else { throw NativeRPCError(code: "profile-retiring", message: "This browser profile is being deleted.") }; return byID
        }
        let wanted = named.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard let byName = profiles.first(where: { $0.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == wanted }) else {
            throw NativeRPCError.invalidArguments("There is no browser profile called \(named).")
        }
        guard !retiringIDs.contains(byName.id) else { throw NativeRPCError(code: "profile-retiring", message: "This browser profile is being deleted.") }
        return byName
    }
}

/// Native profile metadata and history. Construction neither reads nor writes.
/// The app must explicitly open its selected root, and supply exclusive writer
/// ownership plus actual WebKit data removal before enabling mutations.
public actor BackendBrowserProfiles {
    public typealias RequireWriter = @Sendable () throws -> Void
    public typealias DeleteWebsiteData = @Sendable (String) async throws -> Void
    public nonisolated let dataRoot: URL
    private let requireWriter: RequireWriter
    private let deleteWebsiteData: DeleteWebsiteData
    private var opened = false
    private var profiles: [BackendBrowserProfile] = [BackendBrowserProfiles.defaultProfile]
    private var activeID = "default"
    private var retiring: Set<String> = []
    private var visits: [BrowserVisit] = []
    private var pendingHistory: Task<Void, Never>?
    private var historyDirty = false
    private var lastHistoryFailure: String?
    public init(dataRoot: URL, requireWriter: @escaping RequireWriter,
                deleteWebsiteData: @escaping DeleteWebsiteData) throws {
        try BackendBrowserProfilesFiles.validateRoot(dataRoot)
        self.dataRoot = dataRoot.standardizedFileURL
        self.requireWriter = requireWriter; self.deleteWebsiteData = deleteWebsiteData
    }
    public func open() throws {
        guard !opened else { return }
        if let bytes = try BackendBrowserProfilesFiles.read(dataRoot.appendingPathComponent("browser-profiles.json"), maximum: 1024 * 1024),
           let raw = try? NativeRPCValue.parseJSON(bytes) {
            var read: [BackendBrowserProfile] = []
            for row in raw["profiles"].elements ?? [] {
                guard let id = row["id"].string, Self.validID(id), !read.contains(where: { $0.id == id }) else { continue }
                read.append(BackendBrowserProfile(id: id, name: Self.cleanName(row["name"].string, fallback: id == "default" ? "Default" : "Profile"),
                    createdAt: row["createdAt"].number ?? 0, avatar: Self.cleanAvatar(row["avatar"].string ?? "")))
            }
            if !read.contains(where: \.isDefault) { read.insert(Self.defaultProfile, at: 0) }
            profiles = read
            activeID = read.contains(where: { $0.id == raw["activeId"].string }) ? (raw["activeId"].string ?? "default") : "default"
        }
        if let bytes = try BackendBrowserProfilesFiles.read(dataRoot.appendingPathComponent("browser-history.json"), maximum: 8 * 1024 * 1024),
           let raw = try? NativeRPCValue.parseJSON(bytes) {
            visits = (raw["entries"].elements ?? []).compactMap { row in
                // TS uses profileId. The earlier Core encoder used profileID.
                guard let id = row["profileId"].string ?? row["profileID"].string, !id.isEmpty,
                      let url = BrowserHistory.visitable(row["url"].string ?? "") else { return nil }
                let count = row["visits"].number ?? 1
                return BrowserVisit(profileID: id, url: url, title: BrowserHistory.cleanTitle(row["title"].string ?? ""),
                    visitedAt: row["visitedAt"].number ?? 0, visits: Int(min(Double(Int.max / 2), max(1, count.rounded(.down)))))
            }
            visits = Array(visits.sorted { $0.visitedAt > $1.visitedAt }.prefix(BrowserHistory.maxEntries))
        }
        opened = true
    }
    public func state() throws -> BackendBrowserProfileState { try requireOpen(); return .init(profiles: profiles, activeID: activeID, retiringIDs: retiring) }
    public func requireProfile(_ id: String) throws {
        try requireOpen()
        guard !retiring.contains(id) else { throw NativeRPCError(code: "profile-retiring", message: "This browser profile is being deleted. New pages and operations are temporarily refused.") }
        guard profiles.contains(where: { $0.id == id }) else { throw NativeRPCError.invalidArguments("The browser profile does not exist.") }
    }
    public func create(name: String?) throws -> BackendBrowserProfile {
        try requireOpen(); try requireWriter()
        let made = BackendBrowserProfile(id: UUID().uuidString.lowercased(), name: Self.cleanName(name, fallback: "Profile \(profiles.count + 1)"),
            createdAt: Date().timeIntervalSince1970 * 1000, avatar: "")
        try persist(profiles + [made], active: activeID); return made
    }
    public func rename(id: String, name: String) throws -> BackendBrowserProfileState {
        try requireProfile(id); var next = profiles
        if let i = next.firstIndex(where: { $0.id == id }) { next[i].name = Self.cleanName(name, fallback: next[i].name) }
        try persist(next, active: activeID); return try state()
    }
    public func avatar(id: String, avatar: String) throws -> BackendBrowserProfileState {
        try requireProfile(id); var next = profiles
        if let i = next.firstIndex(where: { $0.id == id }) { next[i].avatar = Self.cleanAvatar(avatar) }
        try persist(next, active: activeID); return try state()
    }
    public func activate(id: String) throws -> BackendBrowserProfileState {
        try requireProfile(id); try persist(profiles, active: id); return try state()
    }
    public func delete(id: String) async throws -> BackendBrowserProfileState {
        try requireProfile(id); try requireWriter()
        guard id != "default" else { throw NativeRPCError.invalidArguments("The default profile cannot be deleted.") }
        retiring.insert(id)
        defer { retiring.remove(id) }
        // Keep a named profile if WebKit removal fails. A success must represent
        // actual data removal, rather than metadata hiding an uncleared store.
        try await deleteWebsiteData(id)
        try Task.checkCancellation()
        guard profiles.contains(where: { $0.id == id }) else { throw NativeRPCError(code: "profile-missing", message: "The deleting profile no longer exists.") }
        try persist(profiles.filter { $0.id != id }, active: activeID == id ? "default" : activeID)
        retiring.remove(id)
        return try state()
    }
    @discardableResult
    public func remember(profileID: String, url: String, title: String = "", at: Double = Date().timeIntervalSince1970 * 1000) throws -> Bool {
        try requireOpen()
        if profileID.isEmpty { return false } // isolated tabs never persist
        try requireProfile(profileID)
        guard BrowserHistory.visitable(url) != nil else { return false }
        try requireWriter(); visits = BrowserHistory.note(visits, profileID: profileID, url: url, title: title, at: at)
        scheduleHistory(); return true
    }
    public func retitle(profileID: String, url: String, title: String) throws {
        try requireProfile(profileID); try requireWriter()
        let next = BrowserHistory.retitle(visits, profileID: profileID, url: url, title: title)
        if next != visits { visits = next; scheduleHistory() }
    }
    public func history(profileID: String, query: String = "", limit: Int = 500) throws -> [BrowserVisit] {
        try requireProfile(profileID)
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return Array(visits.filter { $0.profileID == profileID && (needle.isEmpty || $0.url.lowercased().contains(needle) || $0.title.lowercased().contains(needle)) }
            .sorted { $0.visitedAt > $1.visitedAt }.prefix(max(0, min(5000, limit))))
    }
    public func suggest(profileID: String, typed: String) throws -> [BrowserVisit] {
        try requireProfile(profileID); return BrowserHistory.suggest(visits, profileID: profileID, typed: typed)
    }
    public func forget(profileID: String, url: String) throws -> [BrowserVisit] {
        try requireProfile(profileID); try requireWriter(); visits = BrowserHistory.forget(visits, profileID: profileID, url: url)
        scheduleHistory(); return try history(profileID: profileID)
    }
    public func clearHistory(profileID: String) throws -> [BrowserVisit] {
        try requireProfile(profileID); try requireWriter(); visits = BrowserHistory.clear(visits, profileID: profileID)
        scheduleHistory(); return []
    }
    public func flushHistory() throws {
        pendingHistory?.cancel(); pendingHistory = nil
        guard opened, historyDirty else { return }
        try requireWriter()
        let raw = NativeRPCValue.object([.init("version", .number(1)), .init("entries", .array(visits.map(Self.visitValue)))])
        do {
            try BackendBrowserProfilesFiles.write(try raw.encodedJSON(), to: dataRoot.appendingPathComponent("browser-history.json"))
            historyDirty = false; lastHistoryFailure = nil
        } catch { lastHistoryFailure = "The browser history could not be saved."; throw error }
    }
    public func historyWriteFailure() -> String? { lastHistoryFailure }
    public func close() throws {
        guard retiring.isEmpty else { throw NativeRPCError(code: "profile-retiring", message: "Wait for profile deletion to finish before closing its metadata store.") }
        try flushHistory(); opened = false; visits = []; profiles = [Self.defaultProfile]; activeID = "default"
    }
    private func requireOpen() throws {
        guard opened else { throw NativeRPCError(code: "browser-not-open", message: "Open the browser profile store explicitly before using it.") }
    }
    private func persist(_ next: [BackendBrowserProfile], active: String) throws {
        try requireWriter()
        let value = BackendBrowserProfileState(profiles: next, activeID: active).wireValue.setting("version", .number(1))
        try BackendBrowserProfilesFiles.write(try value.encodedJSON(pretty: true), to: dataRoot.appendingPathComponent("browser-profiles.json"))
        profiles = next; activeID = active
    }
    private func scheduleHistory() {
        historyDirty = true
        guard pendingHistory == nil else { return }
        pendingHistory = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(400)); try Task.checkCancellation() } catch { return }
            await self?.scheduledHistoryWrite()
        }
    }
    private func scheduledHistoryWrite() { pendingHistory = nil; do { try flushHistory() } catch { lastHistoryFailure = "The browser history could not be saved." } }
    private static let defaultProfile = BackendBrowserProfile(id: "default", name: "Default", createdAt: 0, avatar: "")
    public static func normalizedID(_ id: String) -> String { id.isEmpty ? "default" : id }
    public static func validID(_ id: String) -> Bool {
        id == "default" || id.range(of: #"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$"#, options: .regularExpression) != nil
    }
    private static func cleanName(_ value: String?, fallback: String) -> String {
        let flat = (value ?? "").replacingOccurrences(of: #"[\x00-\x1f\x7f]"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
        return flat.isEmpty ? fallback : String(flat.prefix(40))
    }
    private static func cleanAvatar(_ value: String) -> String {
        let clean = value.replacingOccurrences(of: #"[\x00-\x1f\x7f]"#, with: "", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
        return clean.unicodeScalars.first.map(String.init) ?? ""
    }
    public static func visitValue(_ visit: BrowserVisit) -> NativeRPCValue {
        .object([.init("profileId", .string(visit.profileID)), .init("url", .string(visit.url)), .init("title", .string(visit.title)),
            .init("visitedAt", .number(visit.visitedAt)), .init("visits", .number(Double(visit.visits)))])
    }
}

/// Constants-only path construction; no profile or remote identifier becomes a
/// path. O_NOFOLLOW refuses symlink targets, and rename keeps writes atomic.
enum BackendBrowserProfilesFiles {
    static func validateRoot(_ root: URL) throws {
        guard root.isFileURL, root.path.hasPrefix("/"), !root.path.contains("\0") else { throw NativeRPCError.invalidArguments("Browser storage needs an explicit absolute app data root.") }
    }
    static func read(_ file: URL, maximum: Int) throws -> Data? {
        let fd = Darwin.open(file.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        if fd < 0 {
            if errno == ENOENT { return nil }
            throw NativeRPCError(code: "browser-storage-read", message: "The browser storage file could not be opened safely.")
        }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        var metadata = stat()
        guard fstat(fd, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFREG, metadata.st_size >= 0, metadata.st_size <= maximum else {
            throw NativeRPCError(code: "browser-storage-size", message: "The browser storage file is not a supported regular file.")
        }
        let data = try handle.read(upToCount: maximum + 1) ?? Data()
        guard data.count <= maximum else { throw NativeRPCError(code: "browser-storage-size", message: "The browser storage file exceeds its size limit.") }
        return data
    }
    static func write(_ data: Data, to file: URL, secret: Bool = false) throws {
        let parent = file.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let temporary = parent.appendingPathComponent(".\(file.lastPathComponent).\(UUID().uuidString).tmp")
        let fd = Darwin.open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
        guard fd >= 0 else { throw NativeRPCError(code: "browser-storage-write", message: "The browser storage file could not be created safely.") }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close(); try? FileManager.default.removeItem(at: temporary) }
        try handle.write(contentsOf: data)
        guard fsync(fd) == 0, fchmod(fd, 0o600) == 0, rename(temporary.path, file.path) == 0 else {
            throw NativeRPCError(code: "browser-storage-write", message: "The browser storage file could not be saved.")
        }
        let directoryFD = Darwin.open(parent.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        if directoryFD >= 0 { _ = fsync(directoryFD); _ = Darwin.close(directoryFD) }
    }
}
