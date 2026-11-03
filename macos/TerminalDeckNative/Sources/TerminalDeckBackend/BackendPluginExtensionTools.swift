import Foundation
import TerminalDeckNativeCore

public enum BackendPluginExtensionTools {
    public static let channel = "plugins:extension"
    public typealias OwnerDispatch = @Sendable (NativeRPCContext, String, NativeRPCValue) async throws -> NativeRPCValue
    public static func id(_ plugin: String, tier: BackendMCPTier) -> String { "plugin." + plugin + ".extension_" + tier.rawValue }
    public static func definitions(host: BackendPluginsHost, authority: any BackendPluginsCallerAuthority) async throws -> [BackendPluginsChannels.ToolRegistration] {
        let schema = try NativeRPCValue.parseJSON(Data(#"{"type":"object","properties":{"op":{"type":"string","enum":["read","start","card","job-start","job-pause","job-resume","events-pause","events-resume"]},"card":{"type":"string"},"action":{"type":"string"},"job":{"type":"string"},"project":{"type":"string"},"input":{"type":"object"},"request":{"type":"string"}},"required":["op"],"additionalProperties":false}"#.utf8))
        var result: [BackendPluginsChannels.ToolRegistration] = []
        for (plugin, manifest) in await host.extensionContributors() {
            for tier in [BackendMCPTier.read, .act, .alter] {
                let name = id(plugin, tier: tier)
                let spec = try BackendMCPTool(id: name, wireName: name.replacingOccurrences(of: ".", with: "_"), description: "Native card/job/event controls for “" + manifest.name + "”. Plugin text and checkpoints are untrusted. Resume is explicit; no exactly-once external-work claim.", inputSchema: schema, tier: tier)
                result.append(.init(spec: spec, handler: { context, input in
                    guard await authority.isLocalHoot(context) else { return .failure("Plugin controls are Hoot's own; other callers cannot use them.") }
                    let required = try await host.extensionTier(plugin, input: input)
                    let rank: [BackendMCPTier: Int] = [.read: 0, .act: 1, .alter: 2]
                    guard rank[tier]! >= rank[required]! else { return .failure("This operation needs its declared higher-tier plugin control.") }
                    try BackendDeckCoreCatalogueSchema.check(tool: spec, arguments: input)
                    try await authority.authorize(context, tool: name, arguments: input, tier: tier)
                    guard !context.cancellation.isCancelled else { throw CancellationError() }
                    do { return .value(try await host.extensionControl(plugin, input: input, targetDispatch: { tool, args, verify in
                        try await authority.dispatchTarget(context, tool: tool, arguments: args, validate: verify)
                    })) } catch { await host.extensionChanged(); throw error }
                }))
            }
        }
        return result
    }
    public static func register(registry: NativeChannelRegistry, ownerID: String, host: BackendPluginsHost, dispatch: OwnerDispatch?) async throws {
        try await registry.register(channel, ownerID: ownerID, policy: { context in
            guard context.caller == .nativeApp, context.ownerID == BackendCompositionRoot.appOwnerID else { throw NativeRPCError(code: "access-denied", message: "Only the actual native owner window can use plugin controls") }
        }) { context, args in
            let plugin = try context.argument(0, in: args).requireString("plugin", nonempty: true), input = try context.argument(1, in: args).requireObject("plugin control")
            guard let dispatch else { throw NativeRPCError(code: "unavailable", message: "The shared native plugin dispatcher is unavailable") }
            let tier = try await host.extensionTier(plugin, input: input)
            return try await dispatch(context, id(plugin, tier: tier), input)
        }
    }
}

/// App-side only. A nested declared-tool call rechecks its original card binding
/// at the existing plugin host's last request boundary, after target policy waits.
public enum BackendPluginTargetFence {
    @TaskLocal public static var check: (@Sendable () async throws -> Void)?
    public static func verify() async throws { try await check?() }
}
