import Foundation

/// Business decisions are separate from an AI's tool permission mode.
public enum PCDecisions {
    public static let ownerActions: Set<String> = ["policy", "bind", "create", "changes", "approve", "approve-start", "reject", "release"]
    public static let actions: Set<String> = ownerActions.union(["get", "draft", "comment", "submit"])
    public static let scopeKeys = ["title", "instructions", "project", "projectId", "assignee", "mainAssignee", "handedFrom", "stopped", "archivedAt", "completedAt", "model", "effort", "decisionEpoch", "decisionPolicyID", "decisionID"]
    public static let protectedKeys = ["decisionRequired", "decisionPolicyID", "decisionID", "decisionEpoch", "decisionEligible", "decisionCreateRequest"]
    public static func requires(_ value: NativeRPCValue) -> Bool { value["decisionRequired"].bool == true || !value["decisionPolicyID"].isNullish || !value["decisionID"].isNullish }
    public static func eligible(_ value: NativeRPCValue) -> Bool {
        value["local"].bool == true && value["keyId"].string == "local" && value["crmThreadOf"].isNullish && value["crmTaskId"].isNullish && value["externalThreadId"].isNullish
    }
    public static func next(_ state: String, action: String) throws -> String {
        switch action {
        case "draft": return "draft"
        case "submit" where state == "draft": return "submitted"
        case "approve", "approve-start": if state == "submitted" { return "approved" }
        case "changes" where state == "submitted" || state == "approved": return "changes-requested"
        case "reject" where state == "submitted" || state == "approved": return "rejected"
        case "release" where state == "approved": return "approved"
        case "comment": return state
        default: break
        }
        throw NativeRPCError(code: "decision-transition", message: "This proposal cannot do that from its current state. Refresh first.")
    }
    public static func count(_ value: NativeRPCValue, key: String) throws -> Int {
        guard let n = value.number, n.isFinite, n >= 0, n <= 1_000_000_000, n.rounded(.down) == n else { throw NativeRPCError.invalidArguments(key + " must be a whole revision number.") }
        return Int(n)
    }
    public static func text(_ value: NativeRPCValue, label: String, limit: Int, required: Bool = true) throws -> String {
        let text = value.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard (!required || !text.isEmpty), text.utf8.count <= limit, !text.contains("\0") else { throw NativeRPCError.invalidArguments(label + " is missing or too long.") }
        return text
    }
}
