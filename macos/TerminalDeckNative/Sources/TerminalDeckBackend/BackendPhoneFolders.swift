import Foundation
import TerminalDeckNativeCore

/// "Other folder…" on a paired phone (26 Oct 2026, Asad: "no folder selection properly"): the remote `folders.pick`
/// capability. Every native Mac declared it and none served it, so a phone could only start in the folders the Mac
/// listed. This answers `folders.browse` with one folder's sub-folders, the shape the phone's folder picker reads
/// (`folders.entries`).
///
/// The owner's own device (`reach.unrestricted`) may walk any folder, as the Mac's own New session dialog can; a
/// guest walks only inside the folders it was given, and never above them. Starting a session in the folder chosen
/// is the ordinary `create` / `chats.new`, which checks the same reach again.
public struct BackendPhoneFolders: Sendable {
    public static let messages: Set<String> = ["folders.browse"]
    /// The most entries one answer carries.
    static let maxEntries = 500
    private let home: String

    public init(home: String) { self.home = home }

    public func feature() -> BackendRemoteHostFeature {
        .init(capability: "folders.pick", messageTypes: Self.messages, policy: .grantedDevice) { message, context in
            [try self.browse(message["path"].string, reach: context.reach)]
        }
    }

    func browse(_ requested: String?, reach: BackendRemoteDeviceReach) throws -> BackendRemoteServerMessage {
        let start = requested ?? (reach.unrestricted ? home : (reach.folders.first ?? home))
        guard start.hasPrefix("/") else { throw NativeRPCError(code: "bad-message", message: "Choose a folder by its full path.") }
        let path = Self.resolved(start)
        // The given folders resolved the same way, so a guest whose folder is reached through a link (or
        // /tmp → /private/tmp) is let into its own folder and the "Shared" marks match.
        let roots = reach.folders.map(Self.resolved)
        guard allowed(path, reach.unrestricted, roots) else {
            throw NativeRPCError(code: "unauthorized", message: "This Mac does not share that folder with this device.")
        }
        var isFolder: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isFolder), isFolder.boolValue else {
            throw NativeRPCError(code: "unavailable", message: "That folder is not on this Mac any more.")
        }
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: path)) ?? [])
            .filter { !$0.hasPrefix(".") }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        var entries: [NativeRPCValue] = []
        for name in names {
            let full = (path as NSString).appendingPathComponent(name)
            var folder: ObjCBool = false
            guard FileManager.default.fileExists(atPath: full, isDirectory: &folder), folder.boolValue,
                  !name.hasSuffix(".app"), !name.hasSuffix(".photoslibrary") else { continue }
            entries.append(.object([.init("name", .string(name)), .init("path", .string(full)),
                .init("readable", .bool(FileManager.default.isReadableFile(atPath: full))),
                .init("granted", .bool(roots.contains { Self.same($0, Self.resolved(full)) }))]))
            if entries.count >= Self.maxEntries { break }
        }
        let up = path == "/" ? nil : (path as NSString).deletingLastPathComponent
        let parent: NativeRPCValue = up.map { allowed($0, reach.unrestricted, roots) ? .string($0) : .null } ?? .null
        return try .init(.folderEntries, fields: [.init("path", .string(path)), .init("parent", parent), .init("entries", .array(entries))])
    }

    /// The owner's device anywhere; a guest only inside the folders it was given (both sides already resolved).
    private func allowed(_ path: String, _ unrestricted: Bool, _ roots: [String]) -> Bool {
        unrestricted || roots.contains { root in
            Self.same(root, path) || path.hasPrefix(Self.trimmed(root) == "/" ? "/" : Self.trimmed(root) + "/")
        }
    }

    /// A folder as the disk has it: `..` and `.` gone, links followed.
    static func resolved(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
    }

    static func trimmed(_ path: String) -> String { path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path }
    static func same(_ a: String, _ b: String) -> Bool { trimmed(a) == trimmed(b) }
}
