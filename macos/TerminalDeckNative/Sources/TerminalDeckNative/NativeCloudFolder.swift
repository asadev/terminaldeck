import Foundation
import Darwin
import TerminalDeckBackend
import TerminalDeckNativeCore

/// Lane L3, slice 1: his Cloud folder on this Mac (`~/Terminal Deck Cloud`). Made by itself the first time Cloud runs
/// here for an account, and added to Finder's sidebar; after that it is never made again by itself (a folder that is
/// gone later is said on the Cloud page, with "Make it again" making it again). Never in a test process.
enum NativeCloudFolder {
    /// The running identity's folder owner, for the Cloud page and the tools. nil while not built.
    @MainActor static var current: BackendCloudFolder? {
        didSet {
            guard let current else { return }
            Task {
                await current.setDeleteRuleGate(deleteRuleIsOpen)
                await current.setDeleteRuleAnnounced(deleteRuleAnnounced)
            }
        }
    }
    /// Review 15 Nov (MUST 4): has this device announced it understands the delete rule? A store that is not ready
    /// answers yes (the safe reading: an arriving removal without its about-record keeps the file).
    nonisolated static func deleteRuleAnnounced(_ device: String) async -> Bool {
        guard let store = await MainActor.run(body: { DeckMemoryCenter.shared.isReady ? DeckMemoryCenter.shared.store as? DeckMemoryStore : nil }) else { return true }
        return await store.cloudDeleteRuleAnnounced(device: device)
    }
    /// Reuses L0's account-computer gate (including Windows' explicit none announcement).
    nonisolated static func deleteRuleIsOpen() async -> Bool {
        guard let store = await MainActor.run(body: { DeckMemoryCenter.shared.isReady ? DeckMemoryCenter.shared.store as? DeckMemoryStore : nil }) else { return false }
        return await store.cloudDeleteRuleIsOpen()
    }

    /// `<dataRoot>/cloud-folder.json`: that the folder was made on this Mac once (this Mac only, never sent).
    static func ledger(_ dataRoot: URL) -> URL { dataRoot.appendingPathComponent("cloud-folder.json") }

    /// Makes the folder the first time (and puts it in Finder's sidebar). Returns the folder. Never makes it again later:
    /// a Mac whose folder was removed or whose disk is not connected must not get an empty folder that looks like
    /// "he removed everything" (the owner never infers that anyway; this keeps the page's line honest).
    static func prepare(dataRoot: URL) -> URL {
        let folder = CloudFolderFormat.defaultFolder()
        guard !NativeCloudApplication.isTestProcess else { return folder }
        let ledgerFile = ledger(dataRoot)
        guard !FileManager.default.fileExists(atPath: ledgerFile.path) else { return folder }
        var info = stat()
        if lstat(folder.path, &info) != 0 {
            do { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false) }
            catch { CloudSyncDiagnostics.shared.info("cloud folder: the Cloud folder could not be made in your home folder; tried again at the next start"); return folder }
        }
        addToSidebar(folder)
        let made = ["madeAt": ISO8601DateFormatter().string(from: Date()), "path": folder.path]
        if let data = try? JSONSerialization.data(withJSONObject: made, options: [.sortedKeys]) { try? data.write(to: ledgerFile, options: .atomic) }
        CloudSyncDiagnostics.shared.info("cloud folder: made Terminal Deck Cloud in your home folder and added it to Finder's sidebar")
        return folder
    }

    /// Finder's sidebar (Favorites), through the system's shared-file-list functions looked up at run time (they are
    /// deprecated but still the only way; if they are gone nothing happens and the folder is simply not in the sidebar).
    static func addToSidebar(_ folder: URL) {
        typealias Create = @convention(c) (CFAllocator?, CFString, UnsafeRawPointer?) -> UnsafeMutableRawPointer?
        typealias Insert = @convention(c) (UnsafeMutableRawPointer, UnsafeMutableRawPointer?, CFString?, UnsafeMutableRawPointer?, CFURL, CFDictionary?, CFArray?) -> UnsafeMutableRawPointer?
        guard let handle = dlopen("/System/Library/Frameworks/CoreServices.framework/CoreServices", RTLD_LAZY),
              let createSymbol = dlsym(handle, "LSSharedFileListCreate"), let insertSymbol = dlsym(handle, "LSSharedFileListInsertItemURL"),
              let favoritesSymbol = dlsym(handle, "kLSSharedFileListFavoriteItems"), let lastSymbol = dlsym(handle, "kLSSharedFileListItemLast") else { return }
        let create = unsafeBitCast(createSymbol, to: Create.self), insert = unsafeBitCast(insertSymbol, to: Insert.self)
        let favorites = favoritesSymbol.assumingMemoryBound(to: Unmanaged<CFString>.self).pointee.takeUnretainedValue()
        let last = lastSymbol.assumingMemoryBound(to: UnsafeMutableRawPointer?.self).pointee
        guard let list = create(nil, favorites, nil) else { return }
        defer { Unmanaged<AnyObject>.fromOpaque(list).release() }
        if let item = insert(list, last, nil, nil, folder as CFURL, nil, nil) { Unmanaged<AnyObject>.fromOpaque(item).release() }
    }

    /// One line for every AI session: where his Cloud folder is (only when it exists on this Mac).
    static func ready(folder: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    /// The tools' view of the running owner.
    static func toolActions() -> BackendCloudFolderTools.Actions {
        BackendCloudFolderTools.Actions(
            status: {
                guard let owner = await MainActor.run(body: { current }) else { return nil }
                let counts = (try? await owner.counts()) ?? (files: 0, bytes: 0)
                var waiting: [String] = []
                if let lines = try? await owner.coverage() { waiting = lines.flatMap(\.blockedReasons) }
                return .init(path: owner.folder.path, files: counts.files, bytes: counts.bytes, waiting: waiting)
            },
            add: { path in
                guard let owner = await MainActor.run(body: { current }) else { throw BackendCloudFolderTools.signedOut }
                return try await owner.add(URL(fileURLWithPath: path)).path
            },
            inProject: { path in
                guard let registry = BackendPROJRegistry.installed, let projects = try? await registry.projects() else { return false }
                let target = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
                return projects.flatMap(\.folders).contains { folder in
                    let root = URL(fileURLWithPath: folder).resolvingSymlinksInPath().standardizedFileURL.path
                    return target == root || target.hasPrefix(root + "/")
                }
            })
    }
}
