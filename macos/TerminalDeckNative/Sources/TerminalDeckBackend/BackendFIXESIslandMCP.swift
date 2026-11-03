import Foundation
import TerminalDeckNativeCore

/// Uses the existing grants, approval door, cancellation and action log.
public enum BackendFIXESIslandMCP {
    public static func definitions(access: BackendDeckToolsAppAccess,
        visible: @escaping @Sendable (BackendMCPCallContext) async throws -> Void,
        read: @escaping @Sendable () async throws -> NativeRPCValue,
        configure: @escaping @Sendable (NativeRPCValue) async throws -> NativeRPCValue) throws -> [BackendDeckToolsDefinition] {
        let specs: [(String, String, String, BackendMCPTier, String)] = [
            ("hoot.island.read", "island_settings_get", "Read Dynamic Island's screen, look, width and quiet setting.", .read,
                #"{"type":"object","properties":{},"additionalProperties":false}"#),
            ("hoot.island.configure", "island_settings_set", "Change Dynamic Island's screen, look, width or quiet setting after asking the person.", .alter,
                #"{"type":"object","properties":{"enabled":{"type":"boolean"},"mode":{"type":"string","enum":["main","builtIn","pointer","named"]},"screenID":{"type":"string"},"screenUUID":{"type":"string"},"showOn":{"type":"object","properties":{"mode":{"type":"string","enum":["main","builtIn","pointer","named"]},"screenUUID":{"type":"string"}},"required":["mode"],"additionalProperties":false},"look":{"type":"string","enum":["app","dark"]},"width":{"type":"string","enum":["compact","standard","wide"]},"whenQuiet":{"type":"string","enum":["small","hide"]}},"additionalProperties":false}"#),
        ]
        return try specs.map { id, wire, description, tier, schema in
            let spec = try BackendMCPTool(id: id, wireName: wire, description: description,
                inputSchema: NativeRPCValue.parseJSON(Data(schema.utf8)), tier: tier)
            let alias = tier == .read ? "hoot_island_read" : "hoot_island_configure"
            return BackendDeckToolsDefinition(spec: spec, title: description, index: description, aliases: [alias]) { context, args in
                guard context.allowedTools.contains(id) || context.allowedTools.contains(wire) || context.allowedTools.contains(alias), context.allowedTiers.contains(tier) else {
                    throw NativeRPCError(code: "access-denied", message: "This caller cannot use Hoot's screen tools.")
                }
                try await visible(context)
                guard !context.cancellation.isCancelled else { throw CancellationError() }
                try await access.authorize(context, id, args, tier, description, tier != .read)
                guard !context.cancellation.isCancelled else { throw CancellationError() }
                try await visible(context)
                let result = try await (tier == .read ? read() : configure(args))
                try await visible(context)
                try await access.record(context, id, args, result)
                return .value(result)
            }
        }
    }
}
