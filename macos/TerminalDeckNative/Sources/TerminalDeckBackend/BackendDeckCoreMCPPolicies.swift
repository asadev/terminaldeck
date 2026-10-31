import Foundation
import TerminalDeckNativeCore

/// Preserve a provider's real per-call authority wrapper when assembling MCP
/// operations. The contextless source adapter is only the generic fallback.
public enum BackendDeckCoreMCPPolicies {
    public static func resolve(provider: any BackendDeckCoreEventsMCPProvider,
                               supplied: [BackendDeckCoreSecurityToolPolicy]? = nil) throws -> [BackendDeckCoreSecurityToolPolicy] {
        let policies: [BackendDeckCoreSecurityToolPolicy]
        if let supplied { policies = supplied }
        else if let contextual = provider as? BackendCompositionClientsMCPProvider {
            policies = try contextual.policies()
        } else { policies = try BackendDeckCoreEventsTools.mcpPolicies(provider: provider) }

        let source = try BackendDeckCoreEventsToolDefinitions.all().filter { $0["id"].string?.hasPrefix("mcp.") == true }
        let ids = Set(source.compactMap { $0["id"].string })
        guard policies.count == ids.count, Set(policies.map { $0.tool.id }) == ids else {
            throw NativeRPCError.invalidArguments("The MCP contribution must supply every source MCP policy exactly once.")
        }
        for policy in policies {
            guard let row = source.first(where: { $0["id"].string == policy.tool.id }),
                  policy.tool.wireName == row["wire"].string, policy.tool.tier.rawValue == row["tier"].string,
                  policy.tool.inputSchema == row["inputSchema"] else {
                throw NativeRPCError.invalidArguments("The supplied \(policy.tool.id) MCP policy must retain its source identity, tier and schema.")
            }
        }
        return policies
    }
}
