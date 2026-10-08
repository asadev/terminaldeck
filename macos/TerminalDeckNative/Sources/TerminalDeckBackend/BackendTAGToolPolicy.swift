import Foundation

/// A profile narrows the serving catalogue before a caller token is issued.
/// CLI pre-approval alone does not establish an MCP allow-list.
public enum BackendTAGToolPolicy {
    public static func covers(_ rule: String, tool: String) -> Bool {
        if rule == tool { return true }
        guard rule.hasPrefix("mcp__"), !rule.dropFirst("mcp__".count).contains("__") else { return false }
        return tool.hasPrefix(rule + "__")
    }
    public static func intersection(_ before: [String], _ after: [String]) -> [String] {
        var result: [String] = []
        for name in before where after.contains(where: { covers($0, tool: name) }) { if !result.contains(name) { result.append(name) } }
        for name in after where before.contains(where: { covers($0, tool: name) }) { if !result.contains(name) { result.append(name) } }
        return result
    }
    public static let taskTools: Set<String> = Set(["tasks.local", "tasks.local_change", "tasks.delegate", "tasks.review", "tasks.verify", "tasks.comment", "tasks.get"].flatMap { [$0, $0.replacingOccurrences(of: ".", with: "_")] })
    public static func sessionNames(taskID: String?) -> Set<String> {
        taskID == nil ? BackendOrdinarySessionToolGrant.names : BackendOrdinarySessionToolGrant.names.union(taskTools)
    }
    public static func permits(server: String, id: String, wire: String, allowed: [String]?, denied: [String]) -> Bool {
        RNMHootMCPCompatibility.profilePermits(server: server, id: id, wire: wire, allowed: allowed, denied: denied)
    }
    public static func filter(_ names: Set<String>, server: String, allowed: [String]?, denied: [String]) -> Set<String> {
        Set(names.filter { name in permits(server: server, id: name, wire: name.replacingOccurrences(of: ".", with: "_"), allowed: allowed, denied: denied) })
    }
}
