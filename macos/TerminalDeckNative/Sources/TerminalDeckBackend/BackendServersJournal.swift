import Foundation
import Darwin
import TerminalDeckNativeCore

/// The local recovery record is distinct from summary.ts's server-side text.
/// No I/O occurs before an explicit journal operation on the supplied root.
public actor BackendServersFileJournal: BackendServersWayBackJournal {
    public let file: URL
    private let directory: URL
    private let policy: BackendServersStoragePolicy
    private var rows: [String: BackendServersWayBack] = [:]
    private var loaded = false
    public init(storageDirectory: URL, policy: BackendServersStoragePolicy) {
        // Not standardizedFileURL: it rewrites /private/var to /var, a symlink the no-symlink rule below would then refuse.
        directory = URL(fileURLWithPath: storageDirectory.path, isDirectory: true); self.policy = policy
        file = directory.appendingPathComponent("server-waybacks.json")
    }
    private struct Envelope: Codable { let version: Int; let rows: [String: BackendServersWayBack] }
    /// Reads row by row, so one record that no longer reads costs only that record (U1).
    private struct SavedEnvelope: Decodable { let version: Int; let rows: [String: SavedRow] }
    private struct SavedRow: Decodable {
        let value: BackendServersWayBack?
        init(from decoder: Decoder) throws { value = try? BackendServersWayBack(from: decoder) }
    }
    /// U1: set when the file could not be read and not even a copy of it could be kept; nothing is written over it.
    private var blocked: String?
    private func key(_ server: String, _ card: String) -> String { server + " " + card }
    private func load() throws {
        guard !loaded else { return }; try policy.requireRead()
        try rejectLinks(file)
        blocked = nil
        if FileManager.default.fileExists(atPath: file.path) {
            let values = try file.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            var damaged = true
            if values.isRegularFile == true, (values.fileSize ?? Int.max) <= 4 * 1024 * 1024,
               let value = try? JSONDecoder().decode(SavedEnvelope.self, from: Data(contentsOf: file)), value.version == 1 {
                rows = value.rows.compactMapValues(\.value); damaged = rows.count != value.rows.count
            }
            // Invalid/unreadable records do not offer a guessed rollback, and are kept as a .damaged copy before
            // the next write; without that copy nothing is written and the next use reads the file again.
            if damaged, DamagedFile.keepCopy(of: file) == nil {
                blocked = DamagedFile.sentence("The saved Go back records", copy: nil); return
            }
        }
        loaded = true
    }
    private func rejectLinks(_ file: URL) throws {
        var item = file
        while item.path != "/" {
            if (try? FileManager.default.destinationOfSymbolicLink(atPath: item.path)) != nil { throw NativeRPCError(code: "unsafe-path", message: "The server recovery record contains a symbolic link.") }
            item.deleteLastPathComponent()
        }
    }
    private func persist(_ next: [String: BackendServersWayBack]) throws {
        try policy.requireWrite(); try rejectLinks(file)
        if let blocked { throw NativeRPCError(code: "journal-unreadable", message: blocked) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        var bytes = try encoder.encode(Envelope(version: 1, rows: next)); bytes.append(10)
        try BackendRemoteServeSecretFile.write(directory: directory, file: file, contents: bytes)
        let descriptor = Darwin.open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw NativeRPCError(code: "journal-flush", message: "The server recovery directory could not be opened for its durable write.") }
        defer { Darwin.close(descriptor) }
        guard Darwin.fsync(descriptor) == 0 else { throw NativeRPCError(code: "journal-flush", message: "The server recovery directory could not be flushed, so no server update was allowed.") }
        rows = next
    }
    public func get(serverId: String, cardId: String) throws -> BackendServersWayBack? { try load(); return rows[key(serverId, cardId)] }
    public func put(serverId: String, cardId: String, record: BackendServersWayBack) throws {
        try load(); var next = rows; next[key(serverId, cardId)] = record; try persist(next)
    }
    public func clear(serverId: String, cardId: String) throws {
        try load(); var next = rows; next[key(serverId, cardId)] = nil; try persist(next)
    }
    public func forgetServer(_ serverId: String) throws {
        try load(); try persist(rows.filter { !$0.key.hasPrefix(serverId + " ") })
    }
}
