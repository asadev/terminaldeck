import Foundation
import TerminalDeckNativeCore

/// Lane L4, "Your Cloud" as a file manager: what the page and its tools may do with this Mac's memory files. Every path
/// is a place inside the memory folder that the page got from the store itself; each one is checked again here (no
/// "..", no link, inside the folder). Nothing here talks to the network: a change is an ordinary change of the memory
/// folder, which the memory's own Cloud capture sends like any other.
extension DeckMemoryStore {
    /// The largest text the page shows when an item or a version is opened.
    public static let cloudFileTextLimit = 262_144

    /// The text of one memory file, for reading on the page (at most 256 KB). nil when it is not on this Mac.
    public func cloudFileText(_ path: String) -> String? {
        guard let file = try? DeckMemoryCloudSchema.safePath(path, root: root), let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: Self.cloudFileTextLimit) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: The page's changes: ONE Bin, ONE delete path (Memory seat, one rule phase 2)
    //
    // Every change the page and its tools make to memory goes through the memory store's one-rule functions
    // (`DeckMemoryStoreOneRule.swift`): scoped deletes use CloudDeleteOwning; legacy Remove = `memoryRemove`.
    // Put back = `memoryPutBack`, Use this version =
    // `memoryUseVersion` (ids from `memoryVersions`), Empty Bin = `memoryEmptyBin`, Clean up = `memoryCleanUpVersions`.
    // Bring back / Put in Cloud again use the same owner's persistent marks and revision ancestry.
    // Newer is decided by the Cloud's revision order only, never by a file date. The page's earlier archive-based
    // Remove and `cloudFilesDelete` (which decided by file dates) are gone.

    /// "Remove": the place is written into the page's "deleted places" FIRST (refused when that cannot be saved), then
    /// the store writes the delete intent and keeper copy, then sends the compatible Everywhere removal.
    @discardableResult
    public func cloudFileRemove(_ path: String, fromAI: Bool) async throws -> DeckMemoryBinItem {
        _ = try DeckMemoryCloudSchema.safePath(path, root: root)
        try cloudRememberDeleted([path])
        do { return try await memoryRemove(path: path, fromAI: fromAI) }
        catch { cloudForgetDeleted([path]); throw error }
    }
    /// "Put back": out of the Bin, the newest version on every Mac. The place is a row in use again.
    @discardableResult
    public func cloudFilePutBack(_ path: String) async throws -> DeckMemoryPutBackResult {
        _ = try DeckMemoryCloudSchema.safePath(path, root: root)
        let back = try await memoryPutBack(path: path)
        cloudForgetDeleted([path])
        return back
    }
    /// "Use this version": `versionId` is a kept version's id from `memoryVersions(path:)`.
    public func cloudFileUseVersion(item: String, versionId: String) async throws {
        _ = try DeckMemoryCloudSchema.safePath(item, root: root)
        try await memoryUseVersion(path: item, versionId: versionId)
        cloudForgetDeleted([item])
    }
    /// "Empty Bin" (owner only): every Bin place is written into the "deleted places" FIRST (refused when that cannot be
    /// saved), then the store empties the Bin here and, once every Mac understands it, on every Mac.
    @discardableResult
    public func cloudFileEmptyBin() async throws -> Int {
        let places = Set(try cloudKeeper().binAll(kind: Self.oneRuleKind).map(\.path))
        if !places.isEmpty { try cloudRememberDeleted(places) }
        return try await memoryEmptyBin()
    }
    /// "Clean up" (owner only): kept earlier texts go; nothing in the memory folder is touched, so no place is deleted.
    @discardableResult
    public func cloudFileCleanUp() async throws -> Int { try await memoryCleanUpVersions() }

    /// Where this Mac keeps the places it removed: beside the app's other data, never in the memory folder (which travels).
    var cloudFilesDeletedFile: URL? { dataRoot?.appendingPathComponent("memory-cloud-files-deleted.json") }
    /// The places this Mac removed, and those its Bin holds (removed here or on another device): never a row in use again
    /// while no file is at that place (their Cloud records stay; the Cloud keeps every version).
    public func cloudFilesDeleted() -> Set<String> {
        var places = memoryRemovedPlaces()
        if let file = cloudFilesDeletedFile, let data = try? Data(contentsOf: file), let list = try? JSONDecoder().decode([String].self, from: data) {
            // A place with a file in it again (put back, or a newer edit from another device) is a row again.
            places.formUnion(list.filter { path in
                guard let url = try? DeckMemoryCloudSchema.safePath(path, root: root) else { return true }
                return !FileManager.default.fileExists(atPath: url.path)
            })
        }
        return places
    }
    /// Saves the list with `paths` added. THROWS when it cannot be saved: the caller then changes nothing.
    func cloudRememberDeleted(_ paths: Set<String>) throws {
        guard let file = cloudFilesDeletedFile else { throw DeckMemoryError(.io, "This Mac's list of removed places could not be saved, so nothing was changed.") }
        var held: Set<String> = []
        if let data = try? Data(contentsOf: file), let list = try? JSONDecoder().decode([String].self, from: data) { held = Set(list) }
        guard !paths.isSubset(of: held) else { return }
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(held.union(paths).sorted()).write(to: file, options: .atomic)
        } catch { throw DeckMemoryError(.io, "This Mac's list of removed places could not be saved, so nothing was changed.") }
    }
    /// A place in use again leaves the list (best effort: a file at the place always wins over the list).
    func cloudForgetDeleted(_ paths: Set<String>) {
        guard let file = cloudFilesDeletedFile, let data = try? Data(contentsOf: file), let list = try? JSONDecoder().decode([String].self, from: data) else { return }
        let kept = Set(list).subtracting(paths)
        guard kept.count != list.count else { return }
        if let encoded = try? JSONEncoder().encode(kept.sorted()) { try? encoded.write(to: file, options: .atomic) }
    }
}
