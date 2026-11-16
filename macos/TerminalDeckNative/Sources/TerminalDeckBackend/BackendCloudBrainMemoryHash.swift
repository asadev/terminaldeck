import Foundation
import CryptoKit
import TerminalDeckNativeCore
import Darwin

enum BackendCloudBrainMemoryHash {
    static func bytes(_ bytes: Data) -> String { SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined() }
    static func file(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
        var hash = SHA256()
        while let bytes = try handle.read(upToCount: 128 * 1024), !bytes.isEmpty { hash.update(data: bytes) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
    static func synchronize(_ url: URL) throws {
        let file = try FileHandle(forWritingTo: url); defer { try? file.close() }
        try file.synchronize()
        let directory = Darwin.open(url.deletingLastPathComponent().path, O_RDONLY)
        guard directory >= 0 else { throw CocoaError(.fileWriteUnknown) }
        defer { Darwin.close(directory) }
        guard fsync(directory) == 0 else { throw CocoaError(.fileWriteUnknown) }
    }
    static func synchronizeDirectory(_ directory: URL) throws {
        let fd = Darwin.open(directory.path, O_RDONLY)
        guard fd >= 0 else { throw CocoaError(.fileWriteUnknown) }
        defer { Darwin.close(fd) }
        guard fsync(fd) == 0 else { throw CocoaError(.fileWriteUnknown) }
    }
    static func uuid(_ text: String) -> String { shaped(text, version: 0x50) }
    /// 13 Nov blocker (nothing synced): the sync core sends only operation ids in the version-4 layout
    /// (`CloudSyncBytes.transportID`), and every memory and file operation id was made by `uuid` in the version-5 layout,
    /// so the very first record was refused on this Mac (`invalidRequest`) before anything was sent. Operation ids,
    /// revisions and their parents use this one: the same hash, the version-4 layout. Other ids (entities, versions,
    /// snapshots) keep `uuid` unchanged, so nothing already stored on a Mac changes its name.
    static func operationId(_ text: String) -> String { shaped(text, version: 0x40) }
    private static func shaped(_ text: String, version: UInt8) -> String {
        var b = Array(SHA256.hash(data: Data(text.utf8)).prefix(16)); b[6] = (b[6] & 15) | version; b[8] = (b[8] & 63) | 128
        let h = b.map { String(format: "%02x", $0) }.joined()
        return "\(h.prefix(8))-\(h.dropFirst(8).prefix(4))-\(h.dropFirst(12).prefix(4))-\(h.dropFirst(16).prefix(4))-\(h.dropFirst(20))"
    }
    /// True for an id the sync core will send (version-4 layout).
    static func isOperationId(_ id: String) -> Bool { (try? CloudSyncBytes.transportID(id)) != nil }
}

/// Named, intentional local-only exclusions for the Cloud page; they never make a row incomplete (AM9).
public enum BackendCloudBrainMemoryExclusions {
    public static func note(_ inventoryRow: String) -> String? { DeckMemoryCloudSchema.intentionalExclusions[inventoryRow] }
}
