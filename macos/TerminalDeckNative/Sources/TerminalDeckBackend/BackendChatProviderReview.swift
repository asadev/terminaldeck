import Foundation
import TerminalDeckNativeCore

/// Review targets are sent as provider operations, never rewritten into a prompt.
public enum BackendChatProviderReview {
    public typealias Request = @Sendable (String, NativeRPCValue) async throws -> NativeRPCValue

    public static func invoke(operation: String, arguments: NativeRPCValue, provider: HootChatProvider,
                              conversation: String?, cwd: String, request: Request) async throws -> NativeRPCValue {
        guard provider == .codex else { throw NativeRPCError(code: "unavailable", message: "This provider has no verified native review protocol.") }
        guard ["review", "review/start", "start"].contains(operation) else { throw NativeRPCError.invalidArguments("Unknown review action.") }
        guard let conversation, !conversation.isEmpty else { throw NativeRPCError(code: "unavailable", message: "Start the provider conversation before reviewing it.") }
        let target = try target(arguments)
        let result = try await request("review/start", .object([.init("threadId", .string(conversation)),
            .init("delivery", .string("inline")), .init("target", target)]))
        return result.setting("target", target).setting("cwd", .string(cwd)).setting("provider", .string(provider.rawValue))
    }

    public static func target(_ arguments: NativeRPCValue) throws -> NativeRPCValue {
        let source = arguments["target"].fields == nil ? arguments : arguments["target"]
        let kind = source["type"].string ?? source["scope"].string ?? arguments["target"].string ?? "uncommittedChanges"
        func string(_ key: String, limit: Int = 16_384) throws -> String {
            let value = try source[key].requireString(key, nonempty: true)
            guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  value.utf8.count <= limit, !value.contains("\0") else { throw NativeRPCError.invalidArguments("Invalid review \(key).") }
            return value
        }
        switch kind {
        case "uncommitted", "uncommittedChanges": return .object([.init("type", .string("uncommittedChanges"))])
        case "baseBranch", "branch": return .object([.init("type", .string("baseBranch")), .init("branch", .string(try string("branch", limit: 1024)))])
        case "commit":
            let sha = try string("sha", limit: 64)
            guard (4...64).contains(sha.count), sha.allSatisfy({ $0.isHexDigit && $0.isASCII }) else { throw NativeRPCError.invalidArguments("Choose a commit hash to review.") }
            return .object([.init("type", .string("commit")), .init("sha", .string(sha))])
        case "custom": return .object([.init("type", .string("custom")), .init("instructions", .string(try string("instructions")))])
        default: throw NativeRPCError.invalidArguments("Choose uncommitted changes, a base branch, a commit, or custom instructions.")
        }
    }

    /// Installed Codex schema emits enteredReviewMode/exitedReviewMode items. Keep the exact output;
    /// any structured findings inside it then reach the existing app finding/file navigation.
    public static func records(_ notification: NativeRPCValue, conversation: String) -> [HootChatRecord] {
        let params = notification["params"], item = params["item"]
        guard params["threadId"].string == conversation,
              notification["method"].string == "item/completed",
              ["enteredReviewMode", "exitedReviewMode"].contains(item["type"].string ?? "") else { return [] }
        let id = item["id"].string ?? "", text = item["review"].string ?? ""
        var fields: [NativeRPCValue.Field] = [.init("reviewOutput", item), .init("reviewPhase", item["type"])]
        if item["type"].string == "exitedReviewMode", text.utf8.count <= 2_097_152,
           let decoded = try? NativeRPCValue.parseJSON(Data(text.utf8)), decoded["findings"].elements != nil {
            fields.append(.init("findings", decoded["findings"]))
        }
        // A single record avoids duplicating structured findings in the app index.
        return [.init(.session, id: id, value: .object(fields))]
    }
}
