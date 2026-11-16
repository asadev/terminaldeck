import Foundation
import TerminalDeckNativeCore

/// Lane L3 slice 2, reworked by the delete rule's lane L6 (15 Nov): the artifacts that travel. An AI lists them (made
/// here or on another device) and opens one by reading its file, as it does local ones (reads free). Deleting one is
/// `cloud_delete` (kind Artifacts, the id below as place): everywhere, into the Bin for 30 days, no question. The Bin is
/// the person's: this tool never lists it, and `cloud.artifacts_remove` / `cloud.artifacts_put_back` are retired
/// (`BackendCloudManagerTools.retiredIDs`). One family, supplied whole or not at all.
public enum BackendCloudArtifactsTools {
    public static let listID = "cloud.artifacts"
    public static let pageIDs: Set<String> = [listID]

    public struct Listed: Sendable {
        public let items: [CloudArtifactItem]
        /// Device id -> the Mac's name.
        public let macs: [String: String]
        public let waiting: [String]
        /// `bin` is accepted from callers built before the delete rule and dropped: no answer lists the Bin.
        public init(items: [CloudArtifactItem], bin: [CloudFolderKept] = [], macs: [String: String], waiting: [String]) {
            self.items = items; self.macs = macs; self.waiting = waiting
        }
    }
    public struct Actions: Sendable {
        public var list: @Sendable () async -> Listed?
        public init(list: @escaping @Sendable () async -> Listed?) { self.list = list }
        /// The form built before the delete rule: `remove` and `putBack` are dropped, never called by any tool
        /// (a delete goes through `cloud_delete` and its owner; putting back is the person's, by hand).
        public init(list: @escaping @Sendable () async -> Listed?, remove: @escaping @Sendable (String) async throws -> Bool,
                    putBack: @escaping @Sendable (String) async throws -> Bool) {
            self.list = list
        }
        public static let none = Actions(list: { nil })
    }
    public static let signedOut = NativeRPCError(code: "unavailable", message: "Artifacts do not travel on this Mac yet (signed out, or still starting).")

    static let specs: [(id: String, tier: BackendMCPTier, title: String, description: String, schema: String)] = [
        (listID, .read, "Artifacts on all devices",
         "The person's artifacts that travel between their devices (pages, reports, pictures), made on this Mac or another: each with id, name, project, who made it, which Mac, when, size and path (read the file at path to open it), and anything waiting. To delete one from every device, use cloud_delete with kind Artifacts and the artifact's name (or its id as place): it goes to the Bin for 30 days and only the person can put it back. Nothing in the Bin is listed: the Bin is the person's.",
         #"{"type":"object","properties":{},"additionalProperties":false}"#),
    ]

    public static func definitions(access: BackendDeckToolsAppAccess, actions: Actions) throws -> [BackendDeckToolsDefinition] {
        try specs.map { entry in
            let spec = try BackendMCPTool(id: entry.id, wireName: entry.id.replacingOccurrences(of: ".", with: "_"), description: entry.description,
                                          inputSchema: NativeRPCValue.parseJSON(Data(entry.schema.utf8)), tier: entry.tier)
            return BackendDeckToolsDefinition(spec: spec, title: entry.title, index: entry.title + " (Artifacts in your Cloud).") { context, args in
                try await BackendDeckToolsSupport.reply {
                    guard context.allowedTools.contains(spec.id) || context.allowedTools.contains(spec.wireName), context.allowedTiers.contains(entry.tier) else {
                        throw NativeRPCError(code: "not-granted", message: "This caller cannot use the artifacts tools.")
                    }
                    return .value(try await run(spec.id, args, access: access, context: context, actions: actions))
                }
            }
        }
    }

    static func day(_ ms: Int64) -> String { ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: Double(ms) / 1000)) }

    static func run(_ id: String, _ args: NativeRPCValue, access: BackendDeckToolsAppAccess, context: BackendMCPCallContext, actions: Actions) async throws -> NativeRPCValue {
        switch id {
        case listID:
            try await access.authorize(context, id, args, .read, "See the artifacts on all your devices", false)
            guard let listed = await actions.list() else { throw signedOut }
            // The files lane's description sidecars are provenance, never an artifact.
            let items: [NativeRPCValue] = listed.items.filter { !BackendCloudManagerTools.isSidecar($0.path) && !BackendCloudManagerTools.isSidecar($0.relPath) }.map { item in
                BackendDeckToolsSupport.object([
                    ("id", .string(item.path)), ("name", .string(item.name)), ("project", item.project.map(NativeRPCValue.string) ?? .null),
                    ("madeBy", item.madeBy.map(NativeRPCValue.string) ?? .null),
                    ("mac", item.device.map { .string(listed.macs[$0.lowercased()] ?? "Another of your devices") } ?? .null),
                    ("madeAt", .string(day(item.createdAt))), ("changedAt", .string(day(item.changedAt))), ("type", .string(item.type)),
                    ("bytes", .number(Double(item.bytes))), ("path", .string(item.url.path))])
            }
            return BackendDeckToolsSupport.object([("artifacts", .array(items)), ("waiting", .array(listed.waiting.map(NativeRPCValue.string)))])
        default:
            throw NativeRPCError.invalidArguments("Unknown artifacts tool.")
        }
    }
}
