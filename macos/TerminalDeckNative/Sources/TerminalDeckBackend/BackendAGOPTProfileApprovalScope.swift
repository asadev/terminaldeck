import Foundation
import TerminalDeckNativeCore

/// Trusted domain code uses this only while applying proven profile narrowing.
/// No RPC argument or key setting can activate it; widening uses the inbox.
public enum BackendAGOPTProfileApprovalScope {
    @TaskLocal public static var narrowing = false
    public static func permitsNarrowing(tool: String, arguments: NativeRPCValue, caller: BackendDeckCoreSecurityCaller) -> Bool {
        guard narrowing, caller.kind == .key, caller.tasks, caller.keyID != nil else { return false }
        if ["tasks.agents", "tasks_agents"].contains(tool) {
            return ["save", "save-many"].contains(arguments["do"].string ?? "")
        }
        let field = arguments["field"].string ?? ""
        let publicFields = Set(BackendAGOPTProfileFields.profile.keys).union(BackendAGOPTProfileFields.efficiency.keys).union(["mcp_servers"])
        if tool == "agents.settings_set" {
            return arguments["id"].string?.isEmpty == false && arguments.has("value") && publicFields.contains(field)
        }
        if tool == "agents.budget_set" {
            return arguments["id"].string?.isEmpty == false && arguments.has("value") &&
                ["monthly_token_budget", "monthly_budget_usd", "warn_percent", "on_exhaustion", "per_task_token_budget"].contains(field)
        }
        return false
    }
}
