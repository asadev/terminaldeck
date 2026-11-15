import Foundation
import TerminalDeckNativeCore

/// Lane L3 (CLOUD-CONTRACTS-1114 §6): the Cloud folder's tools. AIs read and write the folder itself at local speed
/// (its path is in their context); these two only say where it is and copy something into it. Deleting is
/// `cloud_delete` (delete rule, lane L6): everywhere, into the Bin for 30 days, no question. One family, supplied
/// whole or not at all (`BackendDeckToolsRegistration.expectedIDs`).
public enum BackendCloudFolderTools {
    public static let folderID = "cloud.folder"
    public static let addID = "cloud.folder_add"
    public static let pageIDs: Set<String> = [folderID, addID]

    public struct Status: Sendable {
        public let path: String
        public let files: Int
        public let bytes: Int64
        public let waiting: [String]
        public init(path: String, files: Int, bytes: Int64, waiting: [String]) { self.path = path; self.files = files; self.bytes = bytes; self.waiting = waiting }
    }
    public struct Actions: Sendable {
        public var status: @Sendable () async -> Status?
        /// Copies `path` into the folder; returns the new path.
        public var add: @Sendable (_ path: String) async throws -> String
        /// True when `path` is inside one of his projects' folders (no question then).
        public var inProject: @Sendable (_ path: String) async -> Bool
        public init(status: @escaping @Sendable () async -> Status?, add: @escaping @Sendable (String) async throws -> String,
                    inProject: @escaping @Sendable (String) async -> Bool) {
            self.status = status; self.add = add; self.inProject = inProject
        }
        public static let none = Actions(status: { nil }, add: { _ in throw signedOut }, inProject: { _ in false })
    }
    /// Inside a project, a copy larger than this asks him too.
    public static let askAbove: Int64 = 50_000_000
    /// Files (never through a link) and their size at `path`: one file, or everything inside a folder.
    static func measure(_ path: String) -> (files: Int, bytes: Int64) {
        let fm = FileManager.default
        guard let values = try? URL(fileURLWithPath: path).resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey]) else { return (0, 0) }
        if values.isSymbolicLink == true { return (0, 0) }
        guard values.isDirectory == true else { return (1, Int64(values.fileSize ?? 0)) }
        var files = 0, bytes: Int64 = 0
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey]
        if let walk = fm.enumerator(at: URL(fileURLWithPath: path), includingPropertiesForKeys: keys, options: [], errorHandler: { _, _ in true }) {
            for case let url as URL in walk {
                guard let item = try? url.resourceValues(forKeys: Set(keys)), item.isRegularFile == true else { continue }
                files += 1; bytes += Int64(item.fileSize ?? 0)
            }
        }
        return (files, bytes)
    }
    /// "1 file, 2 MB" / "12 files, 340 KB".
    static func sizeWords(_ size: (files: Int, bytes: Int64)) -> String {
        (size.files == 1 ? "1 file, " : "\(size.files) files, ") + ByteCountFormatter.string(fromByteCount: size.bytes, countStyle: .file)
    }
    public static let signedOut = NativeRPCError(code: "unavailable", message: "Your Cloud folder is not set up on this Mac yet (signed out, or still starting).")

    static let specs: [(id: String, tier: BackendMCPTier, title: String, description: String, schema: String)] = [
        (folderID, .read, "Where the Cloud folder is",
         "The person's Cloud folder on this Mac (a normal folder; whatever is in it is on all their devices): its path, how many files travel and their size, and anything waiting. Read and write files in it directly; files up to 25 MB travel; hidden files, links, package folders and key or sign-in files stay on this Mac. To delete a file from it on every device, use cloud_delete with kind Cloud folder and the file's path inside the folder as name: it goes to the Bin for 30 days and only the person can put it back. " + BackendCloudManagerTools.ruleWords,
         #"{"type":"object","properties":{},"additionalProperties":false}"#),
        (addID, .alter, "Copy into the Cloud folder",
         "Copies a file or folder (path) into the top of the person's Cloud folder, under a free name, so it reaches all their devices. Returns the new path. A path outside the person's projects asks the person first.",
         #"{"type":"object","properties":{"path":{"type":"string"}},"required":["path"],"additionalProperties":false}"#),
    ]

    public static func definitions(access: BackendDeckToolsAppAccess, actions: Actions) throws -> [BackendDeckToolsDefinition] {
        try specs.map { entry in
            let spec = try BackendMCPTool(id: entry.id, wireName: entry.id.replacingOccurrences(of: ".", with: "_"), description: entry.description,
                                          inputSchema: NativeRPCValue.parseJSON(Data(entry.schema.utf8)), tier: entry.tier)
            return BackendDeckToolsDefinition(spec: spec, title: entry.title, index: entry.title + " (Cloud folder).") { context, args in
                try await BackendDeckToolsSupport.reply {
                    guard context.allowedTools.contains(spec.id) || context.allowedTools.contains(spec.wireName), context.allowedTiers.contains(entry.tier) else {
                        throw NativeRPCError(code: "not-granted", message: "This caller cannot use the Cloud folder tools.")
                    }
                    return .value(try await run(spec.id, args, access: access, context: context, actions: actions))
                }
            }
        }
    }

    static func run(_ id: String, _ args: NativeRPCValue, access: BackendDeckToolsAppAccess, context: BackendMCPCallContext, actions: Actions) async throws -> NativeRPCValue {
        switch id {
        case folderID:
            try await access.authorize(context, id, args, .read, "See where the Cloud folder is", false)
            guard let status = await actions.status() else { throw signedOut }
            return BackendDeckToolsSupport.object([("path", .string(status.path)), ("files", .number(Double(status.files))),
                                                   ("bytes", .number(Double(status.bytes))), ("waiting", .array(status.waiting.map(NativeRPCValue.string)))])
        case addID:
            guard let raw = args["path"].string?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty, !raw.contains("\0") else {
                throw NativeRPCError.invalidArguments("Give path: the file or folder to copy into the Cloud folder.")
            }
            let path = (raw as NSString).expandingTildeInPath
            guard path.hasPrefix("/") else { throw NativeRPCError.invalidArguments("Give the full path (starting with / or ~).") }
            let name = URL(fileURLWithPath: path).lastPathComponent
            // Review 14 Nov (point 10): the question says how many files and how big.
            let size = measure(path)
            let sentence = "Copy “\(name)” (" + sizeWords(size) + ") into your Cloud folder, so it is on all your devices"
            // Inside one of his projects: no question (the same as an AI writing the folder itself), unless it would add
            // more than 50 MB. Anything else: he is asked.
            if await actions.inProject(path), size.bytes <= askAbove { try await access.authorize(context, id, args, .act, sentence, false) }
            else { try await access.authorize(context, id, args, .alter, sentence, true) }
            guard !context.cancellation.isCancelled else { throw CancellationError() }
            let made = try await actions.add(path)
            let value = BackendDeckToolsSupport.object([("path", .string(made))])
            try await access.record(context, id, args, value)
            return value
        default:
            throw NativeRPCError.invalidArguments("Unknown Cloud folder tool.")
        }
    }
}
