import Foundation
import TerminalDeckNativeCore

/// Holds what the Receiver's two install steps share (the GitHub workspace is
/// assembled after tasks, and tools are installed after both).
public actor BackendRCVCompositionBox {
    public static let shared = BackendRCVCompositionBox()
    public private(set) var service: BackendRCVService?
    private var github: (any BackendGHWorkspaceServing)?
    public func set(service: BackendRCVService?) { self.service = service }
    public func set(github: (any BackendGHWorkspaceServing)?) { self.github = github }
    public func gitHub() -> (any BackendGHWorkspaceServing)? { github }
}

public extension BackendCompositionRoot {
    /// Step 1 (INT2, in `installTasksAndRoutines` once `local` and `config` exist):
    /// the encrypted store, the service, the page channels, the relay link and the
    /// feed for Terminal Deck's own events. Starts nothing that runs on its own.
    ///
    /// Never fails the app: it does not throw, touches no storage or Keychain at
    /// launch, and any later failure leaves only the Receiver "unavailable" with a
    /// reason and Try again (05:28 release blocker).
    @discardableResult
    func installReceiver(tasks: BackendTaskLocalService, configuration: BackendTaskConfiguration, sessions: BackendCompositionSessions,
                         appName: String, hook: @escaping @Sendable (RCVEvent) async -> Void = { _ in }) async -> BackendRCVService? {
        let owner = "native-composition:receiver"
        let folder = dataRoot.appendingPathComponent("receiver", isDirectory: true)
        let persistence = try? BackendTaskPersistence(directory: folder, ownership: state.ownership)
        // Its own Keychain item, created on the first save; never the Electron safe-storage item.
        let store = BackendRCVStore(persistence: persistence, cipher: BackendRCVKeychainCipher(appName: appName),
                                    failure: persistence == nil ? "The Receiver's folder could not be opened." : nil)
        let lifecycle = sessions.lifecycle, manager = sessions.manager, registry = self.registry
        let box = BackendRCVCompositionBox.shared
        let dispatch = BackendRCVProductionDispatch(tasks: tasks, configuration: configuration,
            defaultProject: { FileManager.default.homeDirectoryForCurrentUser.path },
            aiSessions: {
                manager.list().filter { $0.exitCode == nil && AGSCapabilities.providers.contains($0.provider) }
                    .map { RCVChoice(id: $0.id, name: $0.title.isEmpty ? $0.provider : $0.title) }
            },
            write: { id, text in try await lifecycle.write(sessionID: id, data: text) },
            github: { await box.gitHub() })
        let service = BackendRCVService(store: store, dispatch: dispatch, relayBase: { BackendRCVWire.httpBase(BackendRelayAddress.resolve()) },
            changed: { try? await registry.publish(BackendRCVRegistration.changedEvent, arguments: [], ownerID: BackendCompositionRoot.appOwnerID) },
            hook: hook)
        do {
            try await BackendRCVRegistration.installChannels(registry: registry, service: service, ownerID: owner)
            await BackendRCVRelayLink.shared.install(service)
            await BackendRCVFeed.shared.install(service)
            await box.set(service: service)
            try await retain(.init(name: "receiver", domains: ["receiver"], ownerID: owner,
                invokes: Set(BackendRCVRegistration.operations.map { "receiver:" + $0 }), sends: [], events: [BackendRCVRegistration.changedEvent],
                stop: { [registry] in
                    await BackendRCVRelayLink.shared.install(nil); await BackendRCVFeed.shared.install(nil)
                    await box.set(service: nil); await service.stop(); await registry.removeOwner(owner)
                }))
        } catch {
            await BackendRCVRelayLink.shared.install(nil); await BackendRCVFeed.shared.install(nil)
            await box.set(service: nil); await service.stop(); await registry.removeOwner(owner)
            return nil
        }
        return service
    }

    /// Step 2 (INT2, in the deck tools install right after `installINT2HootChatTools`):
    /// the ten `receiver_*` MCP tools through the same policy door every app tool uses.
    /// Never fails the app either: without a Receiver there are simply no Receiver tools,
    /// and while it is unavailable every tool answers with the reason.
    func installReceiverTools(access: BackendDeckToolsAppAccess, joins: BackendCompositionProductionBindings,
                              github: (any BackendGHWorkspaceServing)?) async {
        await BackendRCVCompositionBox.shared.set(github: github)
        guard let service = await BackendRCVCompositionBox.shared.service else { return }
        let owner = "native.receiver-tools"
        do {
            let definitions = try BackendRCVRegistration.definitions(service: service, access: access)
            let area = try BackendDeckToolsSupport.area(id: "receiver", definitions: definitions)
            let bundle = try BackendDeckCoreAreaIntegration.bundle(area: area, metadata: definitions.map(\.catalogueMetadata),
                                                                  policies: definitions.map { joins.nativePolicy($0) })
            try joins.replaceContributions(owner: owner, [bundle], policiesWrapped: true)
            try await mcp.replaceTools(ownerID: owner, tools: definitions.map { ($0.spec, $0.handler) })
            try await retain(.init(name: "receiver-tools", domains: ["receiver-tools"], ownerID: owner, invokes: [], stop: { [mcp] in
                await mcp.removeTools(ownerID: owner)
                try joins.replaceContributions(owner: owner, [], policiesWrapped: true)
            }))
        } catch {
            await mcp.removeTools(ownerID: owner)
            try? joins.replaceContributions(owner: owner, [], policiesWrapped: true)
        }
    }
}

public extension BackendRCVWire {
    /// `wss://relay.example` → `https://relay.example` (where senders post).
    static func httpBase(_ relay: String?) -> String? {
        guard let relay, var components = URLComponents(string: relay), let host = components.host, !host.isEmpty else { return nil }
        components.scheme = components.scheme == "ws" ? "http" : "https"
        components.path = ""; components.query = nil; components.fragment = nil
        return components.string
    }
}
