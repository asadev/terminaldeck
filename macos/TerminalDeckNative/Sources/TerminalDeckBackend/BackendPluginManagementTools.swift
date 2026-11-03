import Foundation
import TerminalDeckNativeCore

/// Management remains discoverable with zero/disabled plugins. Native owner
/// controls and Hoot use this same dispatcher and the original consent owner.
public enum BackendPluginManagementTools {
    public static let ids: Set<String> = ["plugins.state", "plugins.change", "plugins.open_folder"]
    public static func definitions(host: BackendPluginsHost, authority: any BackendPluginsCallerAuthority) throws -> [BackendPluginsChannels.ToolRegistration] {
        let change = try NativeRPCValue.parseJSON(Data(#"{"type":"object","properties":{"op":{"type":"string","enum":["allow","enable","remove"]},"id":{"type":"string"},"enabled":{"type":"boolean"},"capabilities":{"type":"array","items":{"type":"string"}},"projects":{"type":"array","items":{"type":"string"}}},"required":["op","id"],"additionalProperties":false}"#.utf8))
        let empty = try NativeRPCValue.parseJSON(Data(#"{"type":"object","properties":{},"additionalProperties":false}"#.utf8))
        return try [("plugins.state", BackendMCPTier.read), ("plugins.change", .alter), ("plugins.open_folder", .act)].map { id, tier in
            let spec = try BackendMCPTool(id: id, wireName: id.replacingOccurrences(of: ".", with: "_"), description: "Read plugin history or use the original plugin consent/enable/remove owner. Does not start a child while reading history.", inputSchema: id == "plugins.change" ? change : empty, tier: tier)
            return .init(spec: spec, handler: { context, args in
                guard await authority.isLocalHoot(context) else { return .failure("Plugin management belongs to the owner/Hoot, not external keys or worker sessions.") }
                try BackendDeckCoreCatalogueSchema.check(tool: spec, arguments: args)
                try await authority.authorize(context, tool: id, arguments: args, tier: tier)
                guard !context.cancellation.isCancelled else { throw CancellationError() }
                if id == "plugins.state" { return .value(await host.state()) }
                if id == "plugins.open_folder" { try await host.openFolder(); return .value(.object([.init("opened", .bool(true))])) }
                let plugin = try args["id"].requireString("plugin", nonempty: true)
                switch args["op"].string {
                case "allow": return .value(await host.allow(plugin, input: args.removing("op").removing("id")))
                case "enable": guard let enabled = args["enabled"].bool else { throw NativeRPCError.invalidArguments("enabled must be on or off") }; return .value(await host.setEnabled(plugin, enabled))
                case "remove": return .value(await host.remove(plugin))
                default: throw NativeRPCError.invalidArguments("Unknown plugin management operation")
                }
            })
        }
    }
}
