import Foundation
import TerminalDeckNativeCore

/// A separate contribution to the EXISTING MCP server and core gate. The
/// original deck-tools registrar checks an exact historical catalogue and
/// therefore cannot accept the additional GitHub ids.
public enum BackendGHRegistration {
    public static let ownerID = "backend.github-workspace"
    @discardableResult
    public static func install(root: BackendCompositionRoot, composition: BackendGHComposition,
                               bindings: BackendCompositionProductionBindings,
                               access: BackendDeckToolsAppAccess,
                               repositoryService: BackendGitHubService) async throws -> BackendDeckCoreCatalogueBundle {
        let definitions = try composition.definitions(access: access)
        let policies = try definitions.map { definition in
            let name = String(definition.spec.id.dropFirst("github.".count))
            guard let operation = BackendGHOperation(rawValue: name) else {
                throw NativeRPCError.invalidArguments("The GitHub contribution contains an unknown action.")
            }
            let lookup: BackendGHMCPTools.RepoForFolder = { path in
                let repo = await repositoryService.resolveRepo(path)
                guard let name = repo["nameWithOwner"].string else {
                    throw NativeRPCError(code: "not-granted", message: "The project's GitHub repository could not be verified. Check its remote in the app.")
                }
                return name
            }
            return try BackendGHMCPPolicy.decorate(bindings.nativePolicy(definition), scopePrecheck: { arguments, context in
                try await bindings.withPolicyContext(context) {
                    _ = try await bindings.contexts.invoke(handler: { native, args in
                        try await BackendGHMCPTools.precheck(operation: operation, arguments: args,
                            context: native, access: access, repoForFolder: lookup)
                        return .value(.null)
                    }, arguments: arguments, context: context)
                }
            })
        }
        let area = try BackendDeckToolsSupport.area(id: "github-workspace", definitions: definitions)
        let bundle = try BackendDeckCoreAreaIntegration.bundle(area: area,
            metadata: definitions.map(\.catalogueMetadata), policies: policies)
        try await composition.register(registry: root.registry, ownerID: ownerID)
        do {
            try bindings.replaceContributions(owner: ownerID, [bundle], policiesWrapped: true)
            try await root.mcp.replaceTools(ownerID: ownerID, tools: definitions.map { ($0.spec, $0.handler) })
            try await root.retain(.init(name: "github-workspace", domains: ["github-workspace"], ownerID: ownerID,
                invokes: Set([BackendGHChannels.channel] + BackendGHLogChannels.channels),
                events: [BackendGHLogChannels.event], stop: {
                    await composition.shutdown()
                    await root.mcp.removeTools(ownerID: ownerID)
                    try bindings.replaceContributions(owner: ownerID, [], policiesWrapped: true)
                }))
            return bundle
        } catch {
            await composition.shutdown()
            await root.mcp.removeTools(ownerID: ownerID)
            try? bindings.replaceContributions(owner: ownerID, [], policiesWrapped: true)
            for channel in [BackendGHChannels.channel] + BackendGHLogChannels.channels {
                await root.registry.removeHandler(channel, ownerID: ownerID)
            }
            throw error
        }
    }
}
