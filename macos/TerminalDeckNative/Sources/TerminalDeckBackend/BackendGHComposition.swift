import Foundation
import TerminalDeckNativeCore

/// Additive wiring bundle. Construct once beside the current GitHub owner,
/// with its same authenticator, tool runner and project store.
public struct BackendGHComposition: Sendable {
    public let service: BackendGHWorkspaceService
    public let logs: BackendGHLogChannels
    private let repositoryService: BackendGitHubService
    public init(authenticator: BackendGitHubAuthenticator, repositoryService: BackendGitHubService,
                tools: any BackendGitHubToolRunning, environment: [String: String], registry: NativeChannelRegistry,
                addProject: @escaping @Sendable (String) async throws -> NativeRPCValue) {
        self.repositoryService = repositoryService
        let clone = BackendGHCloneService(auth: authenticator, tools: tools, environment: environment, addProject: addProject)
        let workspace = BackendGHWorkspaceService(authenticator: authenticator, tools: tools, environment: environment,
            clone: { request in try await clone.clone(request) })
        service = workspace
        logs = BackendGHLogChannels(service: workspace, registry: registry)
    }

    public func register(registry: NativeChannelRegistry, ownerID: String) async throws {
        try await BackendGHChannels.register(registry: registry, ownerID: ownerID, service: service)
        do { try await logs.register(ownerID: ownerID) }
        catch {
            await registry.removeHandler(BackendGHChannels.channel, ownerID: ownerID)
            for channel in BackendGHLogChannels.channels { await registry.removeHandler(channel, ownerID: ownerID) }
            await logs.shutdown()
            throw error
        }
    }

    public func shutdown() async { await logs.shutdown() }

    public func definitions(access: BackendDeckToolsAppAccess) throws -> [BackendDeckToolsDefinition] {
        try BackendGHMCPTools.definitions(service: service, access: access, repoForFolder: { [repositoryService] path in
            let value = await repositoryService.resolveRepo(path)
            guard let name = value["nameWithOwner"].string, !name.isEmpty else {
                throw NativeRPCError(code: "not-granted", message: "This project's GitHub repository could not be verified. Open the project in the app and check its remote.")
            }
            return name
        })
    }
}
