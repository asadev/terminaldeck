import Foundation

/// Chat tool verbs, directions and access rules are data, shared by every caller.
public enum SessionChatToolPolicy {
    public struct Operation: Sendable {
        public let name: String
        public let directions: [String]
        public let ownerDirections: [String]
        public let ownerRefusal: String?
        public var isPanel: Bool { !directions.isEmpty }
        public func direction(_ arguments: NativeRPCValue) throws -> String {
            let direction = arguments[name == "attachments" ? "attachmentAction" : "direction"].string ?? "read"
            guard !isPanel || directions.contains(direction) else { throw NativeRPCError.invalidArguments("Choose a supported chat action.") }
            return direction
        }
        public func changes(_ arguments: NativeRPCValue) throws -> Bool {
            if !isPanel { return !["read", "turn", "options", "files"].contains(name) || !arguments["options"].isNullish }
            return try direction(arguments) != "read" || (["find", "detail"].contains(name) && arguments["query"].string != nil)
                || (name == "draft" && arguments["text"].string != nil)
        }
        public func refusal(_ arguments: NativeRPCValue, local: Bool) throws -> String? {
            guard !local, try ownerDirections.contains(direction(arguments)) else { return nil }
            return ownerRefusal
        }
    }
    public static let operations: [Operation] = [
        .init(name: "read", directions: [], ownerDirections: [], ownerRefusal: nil),
        .init(name: "say", directions: [], ownerDirections: [], ownerRefusal: nil),
        .init(name: "stop", directions: [], ownerDirections: [], ownerRefusal: nil),
        .init(name: "stop-job", directions: [], ownerDirections: [], ownerRefusal: nil),
        .init(name: "children", directions: ["read", "stop"], ownerDirections: [], ownerRefusal: nil),
        .init(name: "answer", directions: [], ownerDirections: [], ownerRefusal: nil),
        .init(name: "options", directions: [], ownerDirections: [], ownerRefusal: nil),
        .init(name: "turn", directions: [], ownerDirections: [], ownerRefusal: nil),
        .init(name: "files", directions: [], ownerDirections: [], ownerRefusal: nil),
        .init(name: "mention", directions: [], ownerDirections: [], ownerRefusal: nil),
        .init(name: "history", directions: ["read", "previous", "next", "insert"], ownerDirections: [], ownerRefusal: nil),
        .init(name: "find", directions: ["read", "previous", "next", "open", "close"], ownerDirections: [], ownerRefusal: nil),
        .init(name: "attachments", directions: ["read", "add", "remove", "validate", "send"], ownerDirections: [], ownerRefusal: nil),
        .init(name: "recovery", directions: ["read", "retry", "compact"], ownerDirections: [], ownerRefusal: nil),
        .init(name: "draft", directions: ["read"], ownerDirections: [], ownerRefusal: nil),
        .init(name: "export", directions: ["read", "copy"], ownerDirections: ["copy"], ownerRefusal: "Read the export text instead; clipboard copying belongs to the Mac owner."),
        .init(name: "shortcuts", directions: ["read", "open", "close"], ownerDirections: [], ownerRefusal: nil),
        .init(name: "detail", directions: ["read", "open", "close", "previous", "next", "copy"], ownerDirections: ["copy"], ownerRefusal: "Read the export text instead; clipboard copying belongs to the Mac owner."),
        .init(name: "sources", directions: ["read", "open", "close"], ownerDirections: ["open", "close"], ownerRefusal: "Opening local instruction editors belongs to the Mac owner."),
        .init(name: "skills", directions: ["read", "open", "close", "insert"], ownerDirections: ["read", "open", "close", "insert"], ownerRefusal: "Use skills_list and skills_preview under your existing project grant; the Chat discovery panel belongs to the Mac owner."),
        .init(name: "connections", directions: ["read", "open", "close"], ownerDirections: ["read", "open", "close"], ownerRefusal: "The integration management panel belongs to the Mac owner; use your existing scoped integration tools."),
        .init(name: "artifacts", directions: ["read", "open", "close"], ownerDirections: ["open", "close"], ownerRefusal: "Opening sources on the Mac belongs to its owner; read the indexed destinations instead."),
        .init(name: "account", directions: ["read", "open", "close"], ownerDirections: ["open", "close"], ownerRefusal: "Opening this Mac’s account settings belongs to its owner."),
        .init(name: "diagnostics", directions: ["read", "open", "close", "copy"], ownerDirections: ["open", "close", "copy"], ownerRefusal: "Opening diagnostics or copying its brief on this Mac belongs to its owner."),
        .init(name: "context", directions: ["read", "open", "close"], ownerDirections: [], ownerRefusal: nil),
        .init(name: "limits", directions: ["read", "open", "close", "retry", "refresh"], ownerDirections: ["read", "open", "close", "retry", "refresh"], ownerRefusal: "Hoot’s selected-account limits belong to the Mac owner."),
        .init(name: "review", directions: ["read", "open", "close", "insert", "reveal"], ownerDirections: ["open", "close", "reveal"], ownerRefusal: "Opening review destinations on this Mac belongs to its owner."),
        .init(name: "side", directions: ["read", "open", "close", "prepare", "copy"], ownerDirections: ["open", "close", "prepare", "copy"], ownerRefusal: "The separate side-question draft belongs to the Mac owner."),
        .init(name: "editor-context", directions: ["read", "open", "close", "insert"], ownerDirections: ["read", "open", "close", "insert"], ownerRefusal: "Open editor buffers belong to the Mac owner; use your existing scoped file tools."),
        .init(name: "goals", directions: ["read", "open", "close", "insert"], ownerDirections: ["read", "open", "close", "insert"], ownerRefusal: "Use scoped tasks_goals tools; this panel reads the Mac owner’s goals."),
        .init(name: "routines", directions: ["read", "open", "close", "prepare"], ownerDirections: ["read", "open", "close", "prepare"], ownerRefusal: "Use existing scoped routines tools; preparing editors on this Mac belongs to its owner."),
        .init(name: "voice", directions: ["read", "open", "close", "speak", "listen", "stop"], ownerDirections: ["read", "open", "close", "speak", "listen", "stop"], ownerRefusal: "Mac speech playback and microphone dictation belong to the Mac owner."),
    ]
    public static func operation(_ name: String) throws -> Operation {
        guard let operation = operations.first(where: { $0.name == name }) else { throw NativeRPCError.invalidArguments("Choose a supported chat action.") }
        return operation
    }
}
