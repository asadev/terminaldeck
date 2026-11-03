import Foundation
import TerminalDeckBackend
import TerminalDeckNativeCore

extension NativeCompositionProduction {
    func installPROJAgentScanning(configuration: BackendTaskConfiguration, taskAuthority: BackendTaskToolAuthority) async throws {
        let owner = "native-composition:project-agent-scan", registry = root.registry, mcp = root.mcp
        let authority = try wired(self.authority, "authority"), joins = self.joins
        let projects: BackendPROJAgentScanning.Projects = {
            return try await Self.registeredProjects(registry: registry, context: authority.localContext())
        }
        let spec = try await BackendPROJAgentScanning.register(server: mcp, ownerID: owner,
            configuration: configuration, projects: projects, authority: taskAuthority)
        let registered = try await mcp.registrations().first(where: { $0.0.id == spec.id }).unwrapPROJScan()
        let metadata = BackendDeckCoreCatalogueMetadata(tool: spec, title: "Read agent folders", index: spec.description)
        try joins.replaceContributions(owner: owner, [try .init(metadata: [metadata], policies: [joins.mcpPolicy(metadata, handler: registered.1)])], policiesWrapped: true)
        let channel = "tasks:agents-scan"
        try await registry.register(channel, ownerID: owner, policy: { try authority.requireLocalUI($0) }) { context, args in
            try await BackendPROJAgentScanning.scan(context.argument(0, in: args), projects: projects(),
                configuration: configuration, authorizeFolder: { _ in })
        }
        try await root.retain(.init(name: "project-agent-scan", domains: ["project-agent-scan"], ownerID: owner,
            invokes: [channel], sends: [], events: [], stop: {
                try? joins.replaceContributions(owner: owner, [], policiesWrapped: true)
                await registry.removeOwner(owner); await mcp.removeTools(ownerID: owner)
            }))
    }
}

private extension Optional {
    func unwrapPROJScan() throws -> Wrapped {
        guard let value = self else { throw NativeRPCError(code: "unavailable", message: "Agent scanning could not be registered.") }
        return value
    }
}
