import Foundation
import TerminalDeckNativeCore

/// Lane L3, slice 2 (14 Nov): ONE file engine owner (`BackendCloudFolder`) for every kind that travels as files of a
/// folder: the Cloud folder (`~/Terminal Deck Cloud`, row I24) and his artifacts (an app-private store, row I23). What
/// differs between them is only this description: the row, the source, the keeper's kind, the words on the page, and
/// which files are counted as items. The engine's lean mode, the removals brake, the gate, the limits, the
/// "never sent back" adoption and the sweep guard are the owner's own code, shared as they are.
public struct CloudFileKind: Sendable {
    public let inventoryRow: String
    /// The engine's source id: record keys are `file/<sourceId>/<path>`.
    public let sourceId: String
    /// The keeper's kind for this kind's versions and Bin (`BackendCloudContents.Kind` raw value).
    public let keeperKind: String
    /// The name in log lines ("Cloud folder", "Artifacts").
    public let label: String
    /// "Every Mac understands" feature name and format (`DeckMemoryStore.cloudFeatureAnnounce`).
    public let feature: String
    public let format: Int
    public let maximumFileBytes: Int64
    public let maximumFolderBytes: Int64
    /// Files counted as items on the page (an artifact's small description file is not one). The Cloud folder counts all.
    public let listed: @Sendable (String) -> Bool
    /// True when every file is an item (the Cloud folder): its answers carry no separate counts.
    public let listsAll: Bool
    public let words: CloudFileKindWords

    /// The kind's own path rule; nil = the Cloud folder's (`CloudFolderRules.refusal`).
    public let pathRule: (@Sendable (String) -> CloudFolderSkip?)?
    /// Bytes this Mac may send of this kind a day; nil = no cap of ours (project folders, Asad 19 Nov: "don't worry
    /// about cloud limits").
    public let dailySendBytes: Int64?
    /// False: this kind keeps sending when the account's room is low (the service answers if it is really full).
    public let obeysRoomFloor: Bool
    /// The most files one look carries; past it the look is not reliable (nothing is inferred) and the rest waits.
    public let maximumFiles: Int
    /// The most bytes one look records; the rest goes in the next looks (a first upload of gigabytes goes in steps, so the
    /// Mac and the other kinds' sends are never held up). nil = no pacing.
    public let bytesPerLook: Int64?
    /// Seconds between the owner's looks (2 for the Cloud folder; longer for a large tree).
    public let lookSeconds: UInt64
    /// The private copy is an APFS clone of the file (no extra disk space) instead of a second set of bytes.
    public let clonesCopies: Bool

    public var domain: String { CloudBrainFilesFormat.domain(inventoryRow) }
    /// The same path rules for both kinds (hidden, temporary, links' names, package folders, the never-send list).
    public func refusal(_ relative: String) -> CloudFolderSkip? { pathRule?(relative) ?? (pathRule == nil ? CloudFolderRules.refusal(relative) : nil) }

    public init(inventoryRow: String, sourceId: String, keeperKind: String, label: String, feature: String, format: Int,
                maximumFileBytes: Int64, maximumFolderBytes: Int64, listed: @escaping @Sendable (String) -> Bool = { _ in true },
                listsAll: Bool = true, words: CloudFileKindWords, pathRule: (@Sendable (String) -> CloudFolderSkip?)? = nil,
                dailySendBytes: Int64? = CloudFolderFormat.dailySendBytes, obeysRoomFloor: Bool = true,
                maximumFiles: Int = CloudFolderFormat.maximumFiles, bytesPerLook: Int64? = nil, lookSeconds: UInt64 = 2, clonesCopies: Bool = false) {
        self.inventoryRow = inventoryRow; self.sourceId = sourceId; self.keeperKind = keeperKind; self.label = label
        self.feature = feature; self.format = format; self.maximumFileBytes = maximumFileBytes; self.maximumFolderBytes = maximumFolderBytes
        self.listed = listed; self.listsAll = listsAll; self.words = words
        self.pathRule = pathRule; self.dailySendBytes = dailySendBytes; self.obeysRoomFloor = obeysRoomFloor
        self.maximumFiles = maximumFiles; self.bytesPerLook = bytesPerLook; self.lookSeconds = lookSeconds; self.clonesCopies = clonesCopies
    }

    /// Folders that travel with a project (Asad, 19 Nov: "everything should travel ... including actually pictures and
    /// everything don't worry about cloud limits"): row I26, every top-level folder of every project on this Mac, under
    /// one domain; a record's path is `<project key>/<folder>/<path in it>` (`CloudProjectFoldersRules`).
    public static let projectFolders = CloudFileKind(
        inventoryRow: CloudProjectFoldersRules.inventoryRow, sourceId: "projects", keeperKind: "projectFolders", label: "Project folders",
        feature: CloudProjectFoldersRules.feature, format: CloudProjectFoldersRules.format,
        maximumFileBytes: .max, maximumFolderBytes: .max,
        words: CloudFileKindWords(
            gate: { CloudFolderFormat.gateLine($0).replacingOccurrences(of: "Cloud folder", with: "project folders") },
            roomLow: "", full: "", dayFull: "", busy: { CloudFolderFormat.busyLine($0) }, diskLow: CloudFolderFormat.diskLowLine,
            tooLarge: { _ in "" }, secret: { _ in "" }, spelling: { CloudFolderFormat.spellingLine($0) }, clash: { CloudFolderFormat.clashLine($0) },
            folderMissing: "A project's folder is not on this Mac. Nothing was removed from your other devices.",
            exclusions: CloudProjectFoldersRules.exclusions,
            safetyCopyFailed: "project folders: the safety copy could not be made, so nothing in them is replaced or removed by sync yet. It tries again by itself."),
        pathRule: { CloudProjectFoldersRules.refusal($0) }, dailySendBytes: nil, obeysRoomFloor: false,
        maximumFiles: 2_000_000, bytesPerLook: 256 * 1_048_576, lookSeconds: 10, clonesCopies: true)

    /// The Cloud folder, exactly as slice 1 built it (every value and line is the one it had).
    public static let cloudFolder = CloudFileKind(
        inventoryRow: CloudFolderFormat.inventoryRow, sourceId: "folder", keeperKind: "cloudFolder", label: "Cloud folder",
        feature: CloudFolderFormat.feature, format: CloudFolderFormat.format,
        maximumFileBytes: CloudFolderFormat.maximumFileBytes, maximumFolderBytes: CloudFolderFormat.maximumFolderBytes,
        words: CloudFileKindWords(
            gate: { CloudFolderFormat.gateLine($0) }, roomLow: CloudFolderFormat.roomLowLine, full: CloudFolderFormat.folderFullLine,
            dayFull: CloudFolderFormat.dayFullLine, busy: { CloudFolderFormat.busyLine($0) }, diskLow: CloudFolderFormat.diskLowLine,
            tooLarge: { CloudFolderFormat.tooLargeLine($0) }, secret: { CloudFolderFormat.secretLine($0) }, spelling: { CloudFolderFormat.spellingLine($0) },
            clash: { CloudFolderFormat.clashLine($0) },
            folderMissing: "Your Cloud folder is not on this Mac. Nothing was removed from your other devices.",
            exclusions: CloudFolderFormat.exclusions,
            safetyCopyFailed: "cloud folder: the safety copy of the Cloud folder could not be made, so nothing in it is replaced or removed by sync yet. It tries again by itself."))

    /// His artifacts (row I23): the app's own store of them, `CloudArtifactsFormat`.
    public static let artifacts = CloudFileKind(
        inventoryRow: CloudArtifactsFormat.inventoryRow, sourceId: "artifacts", keeperKind: "artifacts", label: "Artifacts",
        feature: CloudArtifactsFormat.feature, format: CloudArtifactsFormat.format,
        maximumFileBytes: CloudArtifactsFormat.maximumFileBytes, maximumFolderBytes: CloudArtifactsFormat.maximumStoreBytes,
        listed: { !CloudArtifactsFormat.isAbout($0) }, listsAll: false,
        words: CloudFileKindWords(
            gate: { CloudArtifactsFormat.gateLine($0) }, roomLow: CloudArtifactsFormat.roomLowLine, full: CloudArtifactsFormat.fullLine,
            dayFull: CloudArtifactsFormat.dayFullLine, busy: { CloudArtifactsFormat.busyLine($0) }, diskLow: CloudArtifactsFormat.diskLowLine,
            tooLarge: { CloudArtifactsFormat.tooLargeLine($0) }, secret: { CloudArtifactsFormat.secretNameLine($0) }, spelling: { CloudArtifactsFormat.spellingLine($0) },
            clash: { CloudArtifactsFormat.clashLine($0) },
            folderMissing: "Your artifacts kept for your other devices are not on this Mac. Nothing was removed from your other devices.",
            exclusions: CloudArtifactsFormat.exclusions,
            safetyCopyFailed: "artifacts: the safety copy of the artifacts kept for your other devices could not be made, so none is replaced or removed by sync yet. It tries again by itself."))
}

/// The plain lines one kind says on the Cloud page (names and plain words only).
public struct CloudFileKindWords: Sendable {
    public let gate: @Sendable ([String]) -> String
    public let roomLow: String
    public let full: String
    public let dayFull: String
    public let busy: @Sendable (Int) -> String
    public let diskLow: String
    public let tooLarge: @Sendable (Int) -> String
    public let secret: @Sendable ([String]) -> String
    public let spelling: @Sendable ([String]) -> String
    public let clash: @Sendable ([String]) -> String
    public let folderMissing: String
    public let exclusions: [String]
    public let safetyCopyFailed: String
    public init(gate: @escaping @Sendable ([String]) -> String, roomLow: String, full: String, dayFull: String, busy: @escaping @Sendable (Int) -> String,
                diskLow: String, tooLarge: @escaping @Sendable (Int) -> String, secret: @escaping @Sendable ([String]) -> String,
                spelling: @escaping @Sendable ([String]) -> String, clash: @escaping @Sendable ([String]) -> String, folderMissing: String,
                exclusions: [String], safetyCopyFailed: String) {
        self.gate = gate; self.roomLow = roomLow; self.full = full; self.dayFull = dayFull; self.busy = busy; self.diskLow = diskLow
        self.tooLarge = tooLarge; self.secret = secret; self.spelling = spelling; self.clash = clash; self.folderMissing = folderMissing
        self.exclusions = exclusions; self.safetyCopyFailed = safetyCopyFailed
    }
}

/// Lane L3 slice 2: the ONE daily send budget of the file kinds on this Mac (owner's numbers: 200 MB a day per Mac,
/// the Cloud folder and artifacts together). A small file beside the identity's Cloud state; a new day (on the Cloud's
/// clock) starts at 0. Without one (the folder's own tests), each owner keeps its own count, as slice 1 did.
public final class CloudDayBudget: @unchecked Sendable {
    /// One lock for every budget object (open files, 15 Nov: the shelf books its file pieces in the same file as the
    /// folder and artifacts, from its own object), so no count is lost between them.
    private static let lock = NSLock()
    private let file: URL
    public init(file: URL) { self.file = file }
    private struct Held: Codable { var day: Int64; var sent: Int64 }
    private func read() -> Held? { (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode(Held.self, from: $0) } }
    private func write(_ held: Held) {
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        if let data = try? JSONEncoder().encode(held) { try? data.write(to: file, options: .atomic) }
    }
    /// Bytes sent today by every file kind of this Mac.
    public func sent(day: Int64) -> Int64 { Self.lock.withLock { read().flatMap { $0.day == day ? $0.sent : nil } ?? 0 } }
    public func add(_ bytes: Int64, day: Int64) {
        Self.lock.withLock {
            let held = read().flatMap { $0.day == day ? $0 : nil } ?? Held(day: day, sent: 0)
            write(Held(day: day, sent: held.sent + bytes))
        }
    }
}
